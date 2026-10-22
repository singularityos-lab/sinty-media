const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const window = @import("../window.zig");
const wdisplay = @import("display.zig");
const xdg = @import("xdg.zig");

const OWin = [*c]c.GstGLWindow;

const Disp = extern struct {
    display: ?*c.struct_wl_display,
    registry: ?*c.struct_wl_registry,
    compositor: ?*c.struct_wl_compositor,
    subcompositor: ?*c.struct_wl_subcompositor,
    shell: ?*c.struct_wl_shell,
    seat: ?*c.struct_wl_seat,
    pointer: ?*c.struct_wl_pointer,
    keyboard: ?*c.struct_wl_keyboard,
    shm: ?*c.struct_wl_shm,
    cursor_theme: ?*c.struct_wl_cursor_theme,
    default_cursor: ?*c.struct_wl_cursor,
    cursor_surface: ?*c.struct_wl_surface,
    xdg_wm_base: ?*anyopaque,
    window: ?*anyopaque,
    serial: u32,
    pointer_x: f64,
    pointer_y: f64,
};

const WinState = extern struct {
    display: ?*Disp,
    queue: ?*c.struct_wl_event_queue,
    surface: ?*c.struct_wl_surface,
    wl_shell_surface: ?*c.struct_wl_shell_surface,
    xdg_surface: ?*anyopaque,
    xdg_toplevel: ?*anyopaque,
    native: ?*c.struct_wl_egl_window,
    foreign_surface: ?*c.struct_wl_surface,
    subsurface: ?*c.struct_wl_subsurface,
    callback: ?*c.struct_wl_callback,
    fullscreen: c_int,
    configured: c_int,
    window_width: c_int,
    window_height: c_int,
    preferred_width: c_int,
    preferred_height: c_int,
    window_x: c_int,
    window_y: c_int,
    render_rect: c.GstVideoRectangle,
};

pub const Win = extern struct {
    parent: c.GstGLWindow,
    display: Disp,
    window: WinState,
    wl_source: ?*c.GSource,
    _reserved: [c.GST_PADDING]c.gpointer,
};

const OW = *Win;

var once: gtype.Once = .{};
var parent: ?*c.GstGLWindowClass = null;

fn wl(w: anytype) OW {
    return @ptrCast(@alignCast(w));
}

pub fn isWayland(w: anytype) bool {
    return gtype.instanceOf(w, typeGet());
}

fn fixed(v: c.wl_fixed_t) f64 {
    return @as(f64, @floatFromInt(v)) / 256.0;
}

fn pointerEnter(data: ?*anyopaque, ptr: ?*c.struct_wl_pointer, serial: u32, _: ?*c.struct_wl_surface, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {
    const w = wl(data);
    w.display.serial = serial;
    const cur = w.display.default_cursor orelse return;
    const img = cur.images[0];
    const buf = c.wl_cursor_image_get_buffer(img);
    c.wl_pointer_set_cursor(ptr, serial, w.display.cursor_surface, @intCast(img[0].hotspot_x), @intCast(img[0].hotspot_y));
    c.wl_surface_attach(w.display.cursor_surface, buf, 0, 0);
    c.wl_surface_damage(w.display.cursor_surface, 0, 0, @intCast(img[0].width), @intCast(img[0].height));
    c.wl_surface_commit(w.display.cursor_surface);
}

fn pointerLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, serial: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
    wl(data).display.serial = serial;
}

fn pointerMotion(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    const w = wl(data);
    w.display.pointer_x = fixed(sx);
    w.display.pointer_y = fixed(sy);
    window.gst_gl_window_send_mouse_event(@ptrCast(w), "mouse-move", 0, w.display.pointer_x, w.display.pointer_y);
}

fn pointerButton(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const w = wl(data);
    window.gst_gl_window_send_mouse_event(@ptrCast(w), if (state == 1) "mouse-button-press" else "mouse-button-release", @bitCast(button), w.display.pointer_x, w.display.pointer_y);
}

fn pointerAxis(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    const w = wl(data);
    const delta = -fixed(value);
    const dx: f64 = if (axis == 1) delta else 0;
    const dy: f64 = if (axis == 1) 0 else delta;
    window.gst_gl_window_send_scroll_event(@ptrCast(w), w.display.pointer_x, w.display.pointer_y, dx, dy);
}

const pointer_listener = blk: {
    var l = std.mem.zeroes(c.struct_wl_pointer_listener);
    l.enter = pointerEnter;
    l.leave = pointerLeave;
    l.motion = pointerMotion;
    l.button = pointerButton;
    l.axis = pointerAxis;
    break :blk l;
};

fn seatCaps(data: ?*anyopaque, seat: ?*c.struct_wl_seat, caps: u32) callconv(.c) void {
    const w = wl(data);
    const d = &w.display;
    const has = caps & c.WL_SEAT_CAPABILITY_POINTER != 0;
    if (has and d.pointer == null) {
        d.pointer = c.wl_seat_get_pointer(seat);
        c.wl_pointer_set_user_data(d.pointer, w);
        _ = c.wl_pointer_add_listener(d.pointer, &pointer_listener, w);
    } else if (!has and d.pointer != null) {
        c.wl_pointer_destroy(d.pointer);
        d.pointer = null;
    }
}

fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}

const seat_listener = c.struct_wl_seat_listener{ .capabilities = seatCaps, .name = seatName };

fn ping(_: ?*anyopaque, ss: ?*c.struct_wl_shell_surface, serial: u32) callconv(.c) void {
    c.wl_shell_surface_pong(ss, serial);
}

fn shellConfigure(data: ?*anyopaque, _: ?*c.struct_wl_shell_surface, _: u32, width: i32, height: i32) callconv(.c) void {
    resize(wl(data), @bitCast(width), @bitCast(height));
}

fn popupDone(_: ?*anyopaque, _: ?*c.struct_wl_shell_surface) callconv(.c) void {}

const shell_listener = c.struct_wl_shell_surface_listener{ .ping = ping, .configure = shellConfigure, .popup_done = popupDone };

const ToplevelListener = extern struct {
    configure: *const fn (?*anyopaque, ?*anyopaque, i32, i32, ?*c.struct_wl_array) callconv(.c) void,
    close: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
};

fn toplevelClose(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const w: OWin = @ptrCast(@alignCast(data));
    if (w[0].close) |f| f(w[0].close_data);
    _ = c.gst_gl_display_remove_window(w[0].display, w);
}

fn toplevelConfigure(data: ?*anyopaque, _: ?*anyopaque, width: i32, height: i32, states: ?*c.struct_wl_array) callconv(.c) void {
    const w = wl(data);
    if (states) |s| {
        const n = s.size / @sizeOf(u32);
        const items: [*]const u32 = @ptrCast(@alignCast(s.data));
        for (items[0..n]) |st| {
            if (st == xdg.STATE_FULLSCREEN) w.window.fullscreen = 1;
        }
    }
    if (width > 0 and height > 0) resize(w, @bitCast(width), @bitCast(height));
}

const toplevel_listener = ToplevelListener{ .configure = toplevelConfigure, .close = toplevelClose };

const SurfaceListener = extern struct {
    configure: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) void,
};

fn surfaceConfigure(_: ?*anyopaque, xs: ?*anyopaque, serial: u32) callconv(.c) void {
    xdg.ackConfigure(xs, serial);
}

const surface_listener = SurfaceListener{ .configure = surfaceConfigure };

const WmListener = extern struct {
    ping: *const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) void,
};

fn wmPing(_: ?*anyopaque, wm: ?*anyopaque, serial: u32) callconv(.c) void {
    xdg.pong(wm, serial);
}

const wm_listener = WmListener{ .ping = wmPing };

fn destroySurfaces(w: OW) void {
    if (w.window.subsurface) |s| c.wl_subsurface_destroy(s);
    w.window.subsurface = null;
    if (w.window.xdg_toplevel) |t| xdg.toplevelDestroy(t);
    w.window.xdg_toplevel = null;
    if (w.window.xdg_surface) |s| xdg.surfaceDestroy(s);
    w.window.xdg_surface = null;
    if (w.window.wl_shell_surface) |s| c.wl_shell_surface_destroy(s);
    w.window.wl_shell_surface = null;
    if (w.window.surface) |s| c.wl_surface_destroy(s);
    w.window.surface = null;
    if (w.window.native) |n| c.wl_egl_window_destroy(n);
    w.window.native = null;
}

fn createXdg(w: OW) void {
    const xs = xdg.getXdgSurface(w.display.xdg_wm_base, w.window.surface);
    _ = xdg.addListener(xs, &surface_listener, w);
    const t = xdg.getToplevel(xs);
    const prg = c.g_get_prgname();
    xdg.setAppId(t, if (prg != null) prg else "org.gstreamer.wayland");
    xdg.setTitle(t, "OpenGL Renderer");
    _ = xdg.addListener(t, &toplevel_listener, w);
    c.wl_surface_commit(w.window.surface);
    w.window.xdg_surface = xs;
    w.window.xdg_toplevel = t;
}

fn createShell(w: OW) void {
    const ss = c.wl_shell_get_shell_surface(w.display.shell, w.window.surface);
    _ = c.wl_shell_surface_add_listener(ss, &shell_listener, w);
    c.wl_shell_surface_set_title(ss, "OpenGL Renderer");
    c.wl_shell_surface_set_toplevel(ss);
    w.window.wl_shell_surface = ss;
}

fn createSurfaces(w: OW) void {
    if (w.window.surface == null) w.window.surface = c.wl_compositor_create_surface(w.display.compositor);
    var shell = w.window.foreign_surface == null;
    if (!shell) {
        if (w.display.subcompositor == null) {
            w.window.foreign_surface = null;
            shell = true;
        } else if (w.window.subsurface == null) {
            w.window.subsurface = c.wl_subcompositor_get_subsurface(w.display.subcompositor, w.window.surface, w.window.foreign_surface);
            c.wl_subsurface_set_position(w.window.subsurface, w.window.window_x, w.window.window_y);
            c.wl_subsurface_set_desync(w.window.subsurface);
        }
    }
    if (shell) {
        if (w.display.xdg_wm_base != null) {
            if (w.window.xdg_surface == null) createXdg(w);
        } else if (w.window.wl_shell_surface == null) {
            createShell(w);
        }
    }
    const width: c_int = if (w.window.render_rect.w > 0) w.window.render_rect.w else if (w.window.window_width > 0) w.window.window_width else if (w.window.preferred_width > 0) w.window.preferred_width else 320;
    w.window.window_width = width;
    const height: c_int = if (w.window.render_rect.h > 0) w.window.render_rect.h else if (w.window.window_height > 0) w.window.window_height else if (w.window.preferred_height > 0) w.window.preferred_height else 240;
    w.window.window_height = height;
    if (w.window.native == null) {
        window.gst_gl_window_resize(@ptrCast(w), @bitCast(width), @bitCast(height));
        w.window.native = c.wl_egl_window_create(w.window.surface, width, height);
    }
}

fn close(gw: OWin) callconv(.c) void {
    const w = wl(gw);
    if (w.display.pointer) |p| {
        c.wl_pointer_destroy(p);
        w.display.pointer = null;
    }
    destroySurfaces(w);
    const dw: [*c]c.GstGLDisplayWayland = @ptrCast(@alignCast(gw[0].display));
    _ = c.wl_display_flush(dw[0].display);
    c.g_source_destroy(w.wl_source);
    c.g_source_unref(w.wl_source);
    w.wl_source = null;
    if (w.display.registry) |r| c.wl_registry_destroy(r);
    if (w.display.compositor) |r| c.wl_compositor_destroy(r);
    if (w.display.subcompositor) |r| c.wl_subcompositor_destroy(r);
    if (w.display.xdg_wm_base) |r| xdg.wmDestroy(r);
    if (w.display.shell) |r| c.wl_shell_destroy(r);
    if (w.display.seat) |r| c.wl_seat_destroy(r);
    c.wl_proxy_wrapper_destroy(w.display.display);
    c.wl_event_queue_destroy(w.window.queue);
    parent.?.close.?(gw);
}

fn registryGlobal(data: ?*anyopaque, reg: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, _: u32) callconv(.c) void {
    const w = wl(data);
    if (c.g_strcmp0(iface, "wl_compositor") == 0) {
        w.display.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, 1));
    } else if (c.g_strcmp0(iface, "wl_subcompositor") == 0) {
        w.display.subcompositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_subcompositor_interface, 1));
    } else if (c.g_strcmp0(iface, "xdg_wm_base") == 0) {
        w.display.xdg_wm_base = c.wl_registry_bind(reg, name, &xdg.wm_base, 1);
        _ = xdg.addListener(w.display.xdg_wm_base, &wm_listener, w);
    } else if (c.g_strcmp0(iface, "wl_shell") == 0) {
        w.display.shell = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_shell_interface, 1));
    } else if (c.g_strcmp0(iface, "wl_seat") == 0) {
        w.display.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 4));
        _ = c.wl_seat_add_listener(w.display.seat, &seat_listener, w);
    }
}

fn registryRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

const registry_listener = c.struct_wl_registry_listener{ .global = registryGlobal, .global_remove = registryRemove };

fn open(gw: OWin, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const w = wl(gw);
    const q = c.gst_gl_window_error_quark();
    if (!wdisplay.isWayland(gw[0].display)) {
        c.g_set_error(err, q, c.GST_GL_WINDOW_ERROR_RESOURCE_UNAVAILABLE, "Failed to retrieve Wayland display (wrong type?)");
        return 0;
    }
    const dw: [*c]c.GstGLDisplayWayland = @ptrCast(@alignCast(gw[0].display));
    const d = dw[0].display orelse {
        c.g_set_error(err, q, c.GST_GL_WINDOW_ERROR_RESOURCE_UNAVAILABLE, "Failed to retrieve Wayland display");
        return 0;
    };
    w.display.display = @ptrCast(c.wl_proxy_create_wrapper(d));
    w.window.queue = c.wl_display_create_queue(d);
    c.wl_proxy_set_queue(@ptrCast(w.display.display), w.window.queue);
    w.display.registry = c.wl_display_get_registry(w.display.display);
    _ = c.wl_registry_add_listener(w.display.registry, &registry_listener, w);
    if (c.wl_display_roundtrip_queue(d, w.window.queue) < 0) {
        c.g_set_error(err, q, c.GST_GL_WINDOW_ERROR_RESOURCE_UNAVAILABLE, "Failed to perform a wayland roundtrip");
        return 0;
    }
    w.wl_source = wdisplay.sourceNew(d, w.window.queue);
    if (parent.?.open.?(gw, err) == 0) return 0;
    _ = c.g_source_attach(w.wl_source, gw[0].main_context);
    return 1;
}

pub fn createWindow(gw: OWin) void {
    if (window.gst_gl_window_get_request_output_surface(gw) != 0) createSurfaces(wl(gw));
}

fn getHandle(gw: OWin) callconv(.c) c.guintptr {
    return @intFromPtr(wl(gw).window.native);
}

fn setHandle(gw: OWin, h: c.guintptr) callconv(.c) void {
    const w = wl(gw);
    const s: ?*c.struct_wl_surface = @ptrFromInt(h);
    if (s == null and w.window.foreign_surface == null) return;
    destroySurfaces(w);
    w.window.foreign_surface = s;
    createSurfaces(w);
}

fn roundtrip(data: c.gpointer) callconv(.c) void {
    const gw: OWin = @ptrCast(@alignCast(data));
    const dw: [*c]c.GstGLDisplayWayland = @ptrCast(@alignCast(gw[0].display));
    createSurfaces(wl(gw));
    _ = c.wl_display_roundtrip_queue(dw[0].display, wl(gw).window.queue);
}

fn show(gw: OWin) callconv(.c) void {
    window.gst_gl_window_send_message(gw, roundtrip, gw);
}

fn resize(w: OW, width: c.guint, height: c.guint) void {
    if (w.window.native) |n| c.wl_egl_window_resize(n, @bitCast(width), @bitCast(height), 0, 0);
    window.gst_gl_window_resize(@ptrCast(w), width, height);
    w.window.window_width = @bitCast(width);
    w.window.window_height = @bitCast(height);
}

fn drawCb(data: c.gpointer) callconv(.c) void {
    const gw: OWin = @ptrCast(@alignCast(data));
    const w = wl(gw);
    const ctx = window.gst_gl_window_get_context(gw);
    createSurfaces(w);
    if (w.window.subsurface) |s| c.wl_subsurface_set_desync(s);
    if (gw[0].queue_resize != 0) {
        var width: c.guint = 0;
        var height: c.guint = 0;
        window.gst_gl_window_get_surface_dimensions(gw, &width, &height);
        window.gst_gl_window_resize(gw, width, height);
    }
    if (gw[0].draw) |f| f(gw[0].draw_data);
    c.gst_gl_context_swap_buffers(ctx);
    if (w.window.subsurface) |s| c.wl_subsurface_set_desync(s);
    c.gst_object_unref(ctx);
}

fn draw(gw: OWin) callconv(.c) void {
    window.gst_gl_window_send_message(gw, drawCb, gw);
}

const Rect = struct {
    win: OW,
    rect: c.GstVideoRectangle,
};

fn freeRect(data: c.gpointer) callconv(.c) void {
    const r: *Rect = @ptrCast(@alignCast(data));
    c.gst_object_unref(r.win);
    c.g_free(r);
}

fn applyRect(data: c.gpointer) callconv(.c) void {
    const r: *Rect = @ptrCast(@alignCast(data));
    const w = r.win;
    if (w.window.subsurface) |s| {
        c.wl_subsurface_set_sync(s);
        c.wl_subsurface_set_position(s, r.rect.x, r.rect.y);
        w.window.window_x = r.rect.x;
        w.window.window_y = r.rect.y;
    }
    resize(w, @bitCast(r.rect.w), @bitCast(r.rect.h));
    w.window.render_rect = r.rect;
}

fn setRect(gw: OWin, x: c.gint, y: c.gint, width: c.gint, height: c.gint) callconv(.c) c.gboolean {
    const r: *Rect = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Rect))));
    r.win = wl(c.gst_object_ref(gw));
    r.rect = .{ .x = x, .y = y, .w = width, .h = height };
    window.gst_gl_window_send_message_async(gw, applyRect, r, freeRect);
    return 1;
}

fn setPreferred(gw: OWin, width: c.gint, height: c.gint) callconv(.c) void {
    const w = wl(gw);
    w.window.preferred_width = width;
    w.window.preferred_height = height;
    if (w.window.render_rect.w < 0 and w.window.render_rect.h < 0) {
        if (w.window.window_height != height or w.window.window_width != width) resize(w, @bitCast(width), @bitCast(height));
    }
}

fn getDisplay(gw: OWin) callconv(.c) c.guintptr {
    const dw: [*c]c.GstGLDisplayWayland = @ptrCast(@alignCast(gw[0].display));
    return @intFromPtr(dw[0].display);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const wc: *c.GstGLWindowClass = @ptrCast(@alignCast(k));
    wc.get_window_handle = getHandle;
    wc.set_window_handle = setHandle;
    wc.show = show;
    wc.draw = draw;
    wc.close = close;
    wc.open = open;
    wc.get_display = getDisplay;
    wc.set_render_rectangle = setRect;
    wc.set_preferred_size = setPreferred;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const w: OW = @ptrCast(@alignCast(inst));
    w.window.render_rect.w = -1;
    w.window.render_rect.h = -1;
}

pub fn typeGet() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(window.gst_gl_window_get_type, "GstGLWindowWaylandEGL", c.GstGLWindowClass, Win, classInit, init, 0);
        }
    }.f);
}

pub fn new(d: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    if (c.gst_gl_display_get_handle_type(d) & c.GST_GL_DISPLAY_TYPE_WAYLAND == 0) return null;
    const o = c.g_object_new(typeGet(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    return @ptrCast(@alignCast(o));
}
