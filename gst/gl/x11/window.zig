const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const window = @import("../window.zig");
const xdisplay = @import("display.zig");

const OWin = [*c]c.GstGLWindow;

const Priv = struct {
    activate: c.gboolean,
    activate_result: c.gboolean,
    preferred_width: c.gint,
    preferred_height: c.gint,
    handle_events: c.gboolean,
    colormap: c.Colormap,
    render_rect: c.GstVideoRectangle,
};

pub const Win = extern struct {
    parent: c.GstGLWindow,
    running: c.gboolean,
    visible: c.gboolean,
    allow_extra_expose_events: c.gboolean,
    device: ?*c.Display,
    screen: ?*c.Screen,
    screen_num: c.gint,
    visual: ?*c.Visual,
    root: c.Window,
    white: c.gulong,
    black: c.gulong,
    depth: c.gint,
    device_width: c.gint,
    device_height: c.gint,
    connection: c.gint,
    visual_info: ?*c.XVisualInfo,
    parent_win: c.Window,
    internal_win_id: c.Window,
    x11_source: ?*c.GSource,
    priv: ?*anyopaque,
    _reserved: [c.GST_PADDING]c.gpointer,
};

const OX = *Win;

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GstGLWindowClass = null;
var trapped: c_int = 0;
var old_handler: c.XErrorHandler = null;

fn x(w: anytype) OX {
    return @ptrCast(@alignCast(w));
}

fn pv(w: anytype) *Priv {
    return @ptrCast(@alignCast(x(w).priv));
}

pub fn isX11(w: anytype) bool {
    return gtype.instanceOf(w, typeGet());
}

fn open(w: OWin, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const wx = x(w);
    wx.device = @ptrFromInt(c.gst_gl_display_get_handle(w[0].display));
    if (wx.device == null) {
        c.g_set_error(err, c.gst_gl_window_error_quark(), c.GST_GL_WINDOW_ERROR_RESOURCE_UNAVAILABLE, "Failed to connect to X display server");
        return 0;
    }
    const d = wx.device.?;
    wx.screen = c.XDefaultScreenOfDisplay(d);
    wx.screen_num = c.XDefaultScreen(d);
    wx.visual = c.XDefaultVisual(d, wx.screen_num);
    wx.root = c.XDefaultRootWindow(d);
    wx.white = c.XWhitePixel(d, wx.screen_num);
    wx.black = c.XBlackPixel(d, wx.screen_num);
    wx.depth = c.XDefaultDepthOfScreen(wx.screen);
    wx.device_width = c.XDisplayWidth(d, wx.screen_num);
    wx.device_height = c.XDisplayHeight(d, wx.screen_num);
    wx.allow_extra_expose_events = 1;
    return parent.?.open.?(w, err);
}

pub fn createWindow(w: OWin) bool {
    const wx = x(w);
    const d = wx.device;
    var attr = std.mem.zeroes(c.XSetWindowAttributes);
    attr.event_mask = c.StructureNotifyMask | c.ExposureMask | c.VisibilityChangeMask;
    attr.do_not_propagate_mask = c.NoEventMask;
    attr.background_pixmap = c.None;
    attr.background_pixel = 0;
    attr.border_pixel = 0;
    const vi = wx.visual_info.?;
    pv(w).colormap = c.XCreateColormap(d, wx.root, vi.visual, c.AllocNone);
    attr.colormap = pv(w).colormap;
    const mask: c_ulong = c.CWBackPixmap | c.CWBorderPixel | c.CWColormap | c.CWEventMask;
    wx.internal_win_id = c.XCreateWindow(d, if (wx.parent_win != 0) wx.parent_win else wx.root, 0, 0, 1, 1, 0, vi.depth, c.InputOutput, vi.visual, mask, &attr);
    handleEvents(w, pv(w).handle_events);
    _ = c.XSync(d, 0);
    _ = c.XSetWindowBackgroundPixmap(d, wx.internal_win_id, c.None);
    var atoms = [_]c.Atom{c.XInternAtom(d, "WM_DELETE_WINDOW", 1)};
    _ = c.XSetWMProtocols(d, wx.internal_win_id, &atoms, 1);
    var hints = std.mem.zeroes(c.XWMHints);
    hints.flags = c.StateHint;
    hints.initial_state = c.NormalState;
    hints.input = 0;
    var title: [*c]u8 = @constCast("OpenGL renderer");
    var prop: c.XTextProperty = undefined;
    _ = c.XStringListToTextProperty(&title, 1, &prop);
    c.XSetWMProperties(d, wx.internal_win_id, &prop, &prop, null, 0, null, &hints, null);
    _ = c.XFree(prop.value);
    return true;
}

fn close(w: OWin) callconv(.c) void {
    const wx = x(w);
    if (wx.device) |d| {
        if (wx.internal_win_id != 0) {
            _ = c.XUnmapWindow(d, wx.internal_win_id);
            _ = c.XDestroyWindow(d, wx.internal_win_id);
            _ = c.XFreeColormap(d, pv(w).colormap);
            _ = c.XSync(d, 0);
        }
        _ = c.XFree(wx.visual_info);
    }
    wx.running = 0;
    parent.?.close.?(w);
}

fn setHandle(w: OWin, id: c.guintptr) callconv(.c) void {
    const wx = x(w);
    const p = pv(w);
    wx.parent_win = id;
    var px: c_int = 0;
    var py: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    if (p.render_rect.w > 0 and p.render_rect.h > 0) {
        px = p.render_rect.x;
        py = p.render_rect.y;
        width = p.render_rect.w;
        height = p.render_rect.h;
    } else if (wx.parent_win != 0) {
        var a: c.XWindowAttributes = undefined;
        _ = c.XGetWindowAttributes(wx.device, wx.parent_win, &a);
        width = a.width;
        height = a.height;
    } else {
        width = p.preferred_width;
        height = p.preferred_height;
    }
    _ = c.XResizeWindow(wx.device, wx.internal_win_id, @bitCast(width), @bitCast(height));
    _ = c.XReparentWindow(wx.device, wx.internal_win_id, wx.parent_win, px, py);
    _ = c.XSync(wx.device, 0);
}

const Rect = struct {
    win: OX,
    rect: c.GstVideoRectangle,
};

fn freeRect(data: c.gpointer) callconv(.c) void {
    const r: *Rect = @ptrCast(@alignCast(data));
    c.gst_object_unref(r.win);
    c.g_free(r);
}

fn applyRect(data: c.gpointer) callconv(.c) void {
    const r: *Rect = @ptrCast(@alignCast(data));
    const wx = r.win;
    if (wx.internal_win_id != 0) _ = c.XMoveResizeWindow(wx.device, wx.internal_win_id, r.rect.x, r.rect.y, @bitCast(r.rect.w), @bitCast(r.rect.h));
    if (wx.device != null) _ = c.XSync(wx.device, 0);
    pv(wx).render_rect = r.rect;
}

fn setRect(w: OWin, px: c_int, py: c_int, width: c_int, height: c_int) callconv(.c) c.gboolean {
    const r: *Rect = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Rect))));
    r.win = x(c.gst_object_ref(w));
    r.rect = .{ .x = px, .y = py, .w = width, .h = height };
    window.gst_gl_window_send_message_async(w, applyRect, r, freeRect);
    return 1;
}

fn getHandle(w: OWin) callconv(.c) c.guintptr {
    return x(w).internal_win_id;
}

fn setPreferred(w: OWin, width: c.gint, height: c.gint) callconv(.c) void {
    pv(w).preferred_width = width;
    pv(w).preferred_height = height;
}

fn showCb(data: c.gpointer) callconv(.c) void {
    const w: OWin = @ptrCast(@alignCast(data));
    const wx = x(w);
    const width: c.guint = @bitCast(pv(w).preferred_width);
    const height: c.guint = @bitCast(pv(w).preferred_height);
    if (wx.visible != 0) return;
    if (wx.parent_win == 0) {
        _ = c.XResizeWindow(wx.device, wx.internal_win_id, width, height);
        window.gst_gl_window_resize(w, width, height);
    }
    _ = c.XMapWindow(wx.device, wx.internal_win_id);
    _ = c.XSync(wx.device, 0);
    wx.visible = 1;
}

fn show(w: OWin) callconv(.c) void {
    window.gst_gl_window_send_message(w, showCb, w);
}

fn drawCb(data: c.gpointer) callconv(.c) void {
    const w: OWin = @ptrCast(@alignCast(data));
    const wx = x(w);
    if (wx.internal_win_id == 0) return;
    var need = false;
    var a: c.XWindowAttributes = undefined;
    _ = c.XGetWindowAttributes(wx.device, wx.internal_win_id, &a);
    if (wx.parent_win != 0 and (pv(w).render_rect.w <= 0 or pv(w).render_rect.h <= 0)) {
        var ap: c.XWindowAttributes = undefined;
        _ = c.XGetWindowAttributes(wx.device, wx.parent_win, &ap);
        if (a.width != ap.width or a.height != ap.height) {
            _ = c.XMoveResizeWindow(wx.device, wx.internal_win_id, 0, 0, @bitCast(ap.width), @bitCast(ap.height));
            _ = c.XSync(wx.device, 0);
            a.width = ap.width;
            a.height = ap.height;
            need = true;
        }
    }
    var width: c.guint = 0;
    var height: c.guint = 0;
    window.gst_gl_window_get_surface_dimensions(w, &width, &height);
    if (@as(c.guint, @bitCast(a.width)) != width or @as(c.guint, @bitCast(a.height)) != height) need = true;
    if (need) window.gst_gl_window_queue_resize(w);
    if (wx.allow_extra_expose_events != 0) {
        if (w[0].queue_resize != 0) window.gst_gl_window_resize(w, width, height);
        if (w[0].draw) |f| {
            const ctx = window.gst_gl_window_get_context(w);
            f(w[0].draw_data);
            c.gst_gl_context_swap_buffers(ctx);
            c.gst_object_unref(ctx);
        }
    }
}

fn draw(w: OWin) callconv(.c) void {
    window.gst_gl_window_send_message(w, drawCb, w);
}

fn handleEvents(w: OWin, on: c.gboolean) callconv(.c) void {
    if (!check.that(w != null, "gst_gl_window_x11_handle_events", "window != NULL")) return;
    const wx = x(w);
    pv(w).handle_events = on;
    if (wx.internal_win_id == 0) return;
    const base_mask: c_long = c.StructureNotifyMask | c.ExposureMask | c.VisibilityChangeMask;
    const mask = if (on != 0) base_mask | c.PointerMotionMask | c.KeyPressMask | c.KeyReleaseMask | c.ButtonPressMask | c.ButtonReleaseMask else base_mask;
    _ = c.XSelectInput(wx.device, wx.internal_win_id, mask);
}

pub fn handleEvent(xw: anytype, ev: *c.xcb_generic_event_t) c.gboolean {
    const w: OWin = @ptrCast(@alignCast(xw));
    const wx = x(w);
    const dx: [*c]c.GstGLDisplayX11 = @ptrCast(@alignCast(w[0].display));
    const conn = dx[0].xcb_connection;
    const code = ev.response_type & 0x7f;
    switch (code) {
        c.XCB_CLIENT_MESSAGE => {
            const ce: *c.xcb_client_message_event_t = @ptrCast(@alignCast(ev));
            const cookie = c.xcb_intern_atom(conn, 0, 16, "WM_DELETE_WINDOW");
            const reply = c.xcb_intern_atom_reply(conn, cookie, null);
            if (ce.data.data32[0] == reply[0].atom) {
                if (w[0].close) |f| f(w[0].close_data);
                _ = c.gst_gl_display_remove_window(w[0].display, w);
            }
            c.g_free(reply);
        },
        c.XCB_CONFIGURE_NOTIFY => {
            const ce: *c.xcb_configure_notify_event_t = @ptrCast(@alignCast(ev));
            window.gst_gl_window_resize(w, ce.width, ce.height);
            window.gst_gl_window_draw(w);
        },
        c.XCB_EXPOSE => {
            const ee: *c.xcb_expose_event_t = @ptrCast(@alignCast(ev));
            if (ee.count == 0) window.gst_gl_window_draw(w);
        },
        c.XCB_KEY_PRESS, c.XCB_KEY_RELEASE => {
            const kp: *c.xcb_key_press_event_t = @ptrCast(@alignCast(ev));
            const sym = c.XkbKeycodeToKeysym(wx.device, kp.detail, 0, 0);
            window.gst_gl_window_send_key_event(w, if (code == c.XCB_KEY_PRESS) "key-press" else "key-release", c.XKeysymToString(sym));
        },
        c.XCB_BUTTON_PRESS, c.XCB_BUTTON_RELEASE => {
            const bp: *c.xcb_button_press_event_t = @ptrCast(@alignCast(ev));
            window.gst_gl_window_send_mouse_event(w, if (code == c.XCB_BUTTON_PRESS) "mouse-button-press" else "mouse-button-release", bp.detail, @floatFromInt(bp.event_x), @floatFromInt(bp.event_y));
        },
        c.XCB_MOTION_NOTIFY => {
            const m: *c.xcb_motion_notify_event_t = @ptrCast(@alignCast(ev));
            window.gst_gl_window_send_mouse_event(w, "mouse-move", 0, @floatFromInt(m.event_x), @floatFromInt(m.event_y));
        },
        else => {},
    }
    return 1;
}

fn errorHandler(_: ?*c.Display, e: [*c]c.XErrorEvent) callconv(.c) c_int {
    trapped = e[0].error_code;
    return 0;
}

pub fn trap() void {
    trapped = 0;
    old_handler = c.XSetErrorHandler(errorHandler);
}

pub fn untrap() c_int {
    _ = c.XSetErrorHandler(old_handler);
    return trapped;
}

fn getDisplay(w: OWin) callconv(.c) c.guintptr {
    return @intFromPtr(x(w).device);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const wc: *c.GstGLWindowClass = @ptrCast(@alignCast(k));
    wc.get_display = getDisplay;
    wc.set_window_handle = setHandle;
    wc.set_render_rectangle = setRect;
    wc.get_window_handle = getHandle;
    wc.draw = draw;
    wc.open = open;
    wc.close = close;
    wc.handle_events = handleEvents;
    wc.set_preferred_size = setPreferred;
    wc.show = show;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const wx: OX = @ptrCast(@alignCast(inst));
    wx.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(wx).* = std.mem.zeroes(Priv);
}

pub fn typeGet() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(window.gst_gl_window_get_type, "GstGLWindowX11", c.GstGLWindowClass, Win, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            return t;
        }
    }.f);
}

pub fn new(d: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    if (c.gst_gl_display_get_handle_type(d) & c.GST_GL_DISPLAY_TYPE_X11 == c.GST_GL_DISPLAY_TYPE_NONE) return null;
    const o = c.g_object_new(typeGet(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    return @ptrCast(@alignCast(o));
}

pub fn matchVisual(w: OWin, err: [*c][*c]c.GError) bool {
    const wx = x(w);
    wx.visual_info = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.XVisualInfo))));
    if (c.XMatchVisualInfo(wx.device, wx.screen_num, wx.depth, c.TrueColor, wx.visual_info) == 0) {
        c.g_set_error(err, c.gst_gl_context_error_quark(), c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Failed to match XVisualInfo");
        return false;
    }
    return true;
}
