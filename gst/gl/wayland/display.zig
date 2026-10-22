const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const display = @import("../display.zig");

comptime {
    @import("../../abi.zig").check(@This());
}

const W = c.GstGLDisplayWayland;
const OW = [*c]W;

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn handle(d: [*c]c.GstGLDisplay) callconv(.c) c.guintptr {
    return @intFromPtr(@as(OW, @ptrCast(@alignCast(d)))[0].display);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const w: OW = @ptrCast(@alignCast(o));
    c.g_object_set_data(o, "gst.gl.display.egl", null);
    if (w[0].foreign_display == 0 and w[0].display != null) {
        _ = c.wl_display_flush(w[0].display);
        c.wl_display_disconnect(w[0].display);
    }
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    @as(*c.GstGLDisplayClass, @ptrCast(@alignCast(k))).get_handle = handle;
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const w: OW = @ptrCast(@alignCast(inst));
    w[0].parent.type = c.GST_GL_DISPLAY_TYPE_WAYLAND;
    w[0].foreign_display = 0;
}

pub export fn gst_gl_display_wayland_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(display.gst_gl_display_get_type, "GstGLDisplayWayland", c.GstGLDisplayWaylandClass, W, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(c.gint));
            return t;
        }
    }.f);
}

pub fn isWayland(p: anytype) bool {
    return gtype.instanceOf(p, gst_gl_display_wayland_get_type());
}

fn make() OW {
    const o = c.g_object_new(gst_gl_display_wayland_get_type(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    return @ptrCast(@alignCast(o));
}

pub export fn gst_gl_display_wayland_new(name: [*c]const u8) OW {
    _ = c._gst_debug_get_category("gldisplay");
    const w = make();
    w[0].display = c.wl_display_connect(name);
    if (w[0].display == null) {
        c.gst_object_unref(w);
        return null;
    }
    return w;
}

pub export fn gst_gl_display_wayland_new_with_display(dpy: ?*c.struct_wl_display) OW {
    if (!check.that(dpy != null, "gst_gl_display_wayland_new_with_display", "display != NULL")) return null;
    _ = c._gst_debug_get_category("gldisplay");
    const w = make();
    w[0].display = dpy;
    w[0].foreign_display = 1;
    return w;
}

const Source = extern struct {
    source: c.GSource,
    pfd: c.GPollFD,
    mask: u32,
    display: ?*c.struct_wl_display,
    queue: ?*c.struct_wl_event_queue,
    reading: c.gboolean,
};

fn prepare(s: [*c]c.GSource, timeout: [*c]c.gint) callconv(.c) c.gboolean {
    const src: *Source = @ptrCast(@alignCast(s));
    timeout[0] = -1;
    if (src.reading != 0) c.wl_display_cancel_read(src.display);
    if (src.queue != null) {
        if (c.wl_display_prepare_read_queue(src.display, src.queue) != 0) return 1;
    } else if (c.wl_display_prepare_read(src.display) != 0) return 1;
    src.reading = 1;
    if (c.wl_display_flush(src.display) < 0) c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Failed to flush Wayland connection\n");
    return 0;
}

fn sourceCheck(s: [*c]c.GSource) callconv(.c) c.gboolean {
    const src: *Source = @ptrCast(@alignCast(s));
    src.reading = 0;
    if (src.pfd.revents & c.G_IO_IN != 0) {
        if (c.wl_display_read_events(src.display) == 0) return 1;
    } else {
        c.wl_display_cancel_read(src.display);
    }
    return 0;
}

fn dispatch(s: [*c]c.GSource, cb: c.GSourceFunc, data: c.gpointer) callconv(.c) c.gboolean {
    const src: *Source = @ptrCast(@alignCast(s));
    if (src.queue != null) {
        _ = c.wl_display_dispatch_queue_pending(src.display, src.queue);
    } else {
        _ = c.wl_display_dispatch_pending(src.display);
    }
    src.pfd.revents = 0;
    if (cb) |f| _ = f(data);
    return 1;
}

fn sourceFinalize(s: [*c]c.GSource) callconv(.c) void {
    const src: *Source = @ptrCast(@alignCast(s));
    if (src.reading != 0) c.wl_display_cancel_read(src.display);
    src.reading = 0;
}

var funcs = c.GSourceFuncs{ .prepare = prepare, .check = sourceCheck, .dispatch = dispatch, .finalize = sourceFinalize, .closure_callback = null, .closure_marshal = null };
var debug_done: usize = 0;

pub fn sourceNew(dpy: ?*c.struct_wl_display, queue: ?*c.struct_wl_event_queue) *c.GSource {
    if (c.g_once_init_enter(&debug_done) != 0) {
        _ = c._gst_debug_category_new("glwaylandeventsource", 0, "OpenGL Wayland event source");
        c.g_once_init_leave(&debug_done, 1);
    }
    const s: *Source = @ptrCast(@alignCast(c.g_source_new(&funcs, @sizeOf(Source))));
    s.display = dpy;
    s.queue = queue;
    s.pfd.fd = c.wl_display_get_fd(dpy);
    s.pfd.events = c.G_IO_IN | c.G_IO_ERR;
    c.g_source_add_poll(&s.source, &s.pfd);
    return &s.source;
}
