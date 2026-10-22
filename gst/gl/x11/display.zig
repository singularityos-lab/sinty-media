const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const display = @import("../display.zig");
const window = @import("window.zig");

comptime {
    @import("../../abi.zig").check(@This());
}

const X = c.GstGLDisplayX11;
const OX = [*c]X;

var once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;

fn handle(d: [*c]c.GstGLDisplay) callconv(.c) c.guintptr {
    return @intFromPtr(@as(OX, @ptrCast(@alignCast(d)))[0].display);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const x: OX = @ptrCast(@alignCast(o));
    c.g_free(x[0].name);
    if (x[0].foreign_display == 0 and x[0].display != null) {
        _ = c.XSync(x[0].display, 0);
        _ = c.XCloseDisplay(x[0].display);
    }
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GstGLDisplayClass, @ptrCast(@alignCast(k))).get_handle = handle;
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const x: OX = @ptrCast(@alignCast(inst));
    x[0].parent.type = c.GST_GL_DISPLAY_TYPE_X11;
    x[0].foreign_display = 0;
}

pub export fn gst_gl_display_x11_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(display.gst_gl_display_get_type, "GstGLDisplayX11", c.GstGLDisplayX11Class, X, classInit, init, 0);
        }
    }.f);
}

pub fn isX11(p: anytype) bool {
    return gtype.instanceOf(p, gst_gl_display_x11_get_type());
}

const Source = extern struct {
    source: c.GSource,
    pfd: c.GPollFD,
    mask: u32,
    x: OX,
};

fn prepare(s: [*c]c.GSource, timeout: [*c]c.gint) callconv(.c) c.gboolean {
    const src: *Source = @ptrCast(@alignCast(s));
    _ = c.xcb_flush(src.x[0].xcb_connection);
    timeout[0] = -1;
    return 0;
}

fn sourceCheck(s: [*c]c.GSource) callconv(.c) c.gboolean {
    const src: *Source = @ptrCast(@alignCast(s));
    return src.pfd.revents;
}

fn dispatch(s: [*c]c.GSource, cb: c.GSourceFunc, data: c.gpointer) callconv(.c) c.gboolean {
    const src: *Source = @ptrCast(@alignCast(s));
    const r = handleEvent(src.x);
    src.pfd.revents = 0;
    if (cb) |f| _ = f(data);
    return r;
}

var funcs = c.GSourceFuncs{ .prepare = prepare, .check = sourceCheck, .dispatch = dispatch, .finalize = null, .closure_callback = null, .closure_marshal = null };

fn sourceNew(x: OX) ?*c.GSource {
    const conn = x[0].xcb_connection;
    if (!check.that(conn != null, "xcb_event_source_new", "connection != NULL")) return null;
    const s: *Source = @ptrCast(@alignCast(c.g_source_new(&funcs, @sizeOf(Source))));
    s.x = x;
    s.pfd.fd = c.xcb_get_file_descriptor(conn);
    s.pfd.events = c.G_IO_IN | c.G_IO_ERR;
    c.g_source_add_poll(&s.source, &s.pfd);
    return &s.source;
}

fn make() OX {
    const o = c.g_object_new(gst_gl_display_x11_get_type(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    return @ptrCast(@alignCast(o));
}

pub export fn gst_gl_display_x11_new(name: [*c]const u8) OX {
    _ = c._gst_debug_get_category("gldisplay");
    const x = make();
    x[0].name = c.g_strdup(name);
    x[0].display = c.XOpenDisplay(x[0].name);
    if (x[0].display == null) {
        c.gst_object_unref(x);
        return null;
    }
    x[0].xcb_connection = c.XGetXCBConnection(x[0].display);
    if (x[0].xcb_connection == null) {
        c.gst_object_unref(x);
        return null;
    }
    c.XSetEventQueueOwner(x[0].display, c.XCBOwnsEventQueue);
    x[0].parent.event_source = sourceNew(x);
    _ = c.g_source_attach(x[0].parent.event_source, x[0].parent.main_context);
    return x;
}

pub export fn gst_gl_display_x11_new_with_display(dpy: ?*c.Display) OX {
    if (!check.that(dpy != null, "gst_gl_display_x11_new_with_display", "display != NULL")) return null;
    _ = c._gst_debug_get_category("gldisplay");
    const x = make();
    x[0].name = c.g_strdup(c.XDisplayString(dpy));
    x[0].display = dpy;
    x[0].xcb_connection = c.XGetXCBConnection(dpy);
    if (x[0].xcb_connection == null) {
        c.gst_object_unref(x);
        return null;
    }
    x[0].foreign_display = 1;
    return x;
}

fn cmpWindow(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const w: *const window.Win = @ptrCast(@alignCast(a));
    const id: *const c.xcb_window_t = @ptrCast(@alignCast(b));
    return @bitCast(@as(u32, @truncate(w.internal_win_id)) -% id.*);
}

fn findWindow(x: OX, id: c.xcb_window_t) ?*window.Win {
    if (id == 0) return null;
    var wid = id;
    return @ptrCast(@alignCast(display.gst_gl_display_retrieve_window(@ptrCast(x), &wid, cmpWindow)));
}

fn windowFor(x: OX, ev: *c.xcb_generic_event_t) ?*window.Win {
    return switch (ev.response_type & 0x7f) {
        c.XCB_CLIENT_MESSAGE => findWindow(x, @as(*c.xcb_client_message_event_t, @ptrCast(@alignCast(ev))).window),
        c.XCB_CONFIGURE_NOTIFY => findWindow(x, @as(*c.xcb_configure_notify_event_t, @ptrCast(@alignCast(ev))).window),
        c.XCB_EXPOSE => findWindow(x, @as(*c.xcb_expose_event_t, @ptrCast(@alignCast(ev))).window),
        c.XCB_KEY_PRESS, c.XCB_KEY_RELEASE => findWindow(x, @as(*c.xcb_key_press_event_t, @ptrCast(@alignCast(ev))).event),
        c.XCB_BUTTON_PRESS, c.XCB_BUTTON_RELEASE => findWindow(x, @as(*c.xcb_button_press_event_t, @ptrCast(@alignCast(ev))).event),
        c.XCB_MOTION_NOTIFY => findWindow(x, @as(*c.xcb_motion_notify_event_t, @ptrCast(@alignCast(ev))).event),
        else => null,
    };
}

pub fn handleEvent(x: OX) c.gboolean {
    var r: c.gboolean = 1;
    while (true) {
        const ev = c.xcb_poll_for_event(x[0].xcb_connection) orelse break;
        const w = windowFor(x, ev);
        r = if (w) |win| window.handleEvent(win, ev) else 1;
        if (w) |win| c.gst_object_unref(win);
        c.g_free(ev);
    }
    return r;
}
