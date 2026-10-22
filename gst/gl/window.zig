const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const backends = @import("backends.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Window = c.GstGLWindow;
const WindowClass = c.GstGLWindowClass;
const OWindow = [*c]Window;
const VNONE = @as(?*anyopaque, null);

const Priv = struct {
    loop: ?*c.GMainLoop,
    surface_width: c.guint,
    surface_height: c.guint,
    sync_lock: c.GMutex,
    sync_cond: c.GCond,
    request_output_surface: c.gboolean,
};

const Dummy = extern struct {
    parent: Window,
    handle: c.guintptr,
};

const S_MOUSE = 0;
const S_KEY = 1;
const S_SCROLL = 2;
const S_HANDLE = 3;

var signals = [_]c.guint{0} ** 4;
var once: gtype.Once = .{};
var dummy_once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn pv(w: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Window, @ptrCast(@alignCast(w))).priv));
}

fn win(w: anytype) *Window {
    return @ptrCast(@alignCast(w));
}

fn klass(w: anytype) *WindowClass {
    return gtype.classPeek(WindowClass, w);
}

pub fn isWindow(w: anytype) bool {
    return gtype.instanceOf(w, gst_gl_window_get_type());
}

fn valid(w: anytype, comptime fname: []const u8) bool {
    return check.that(isWindow(w), fname, "GST_IS_GL_WINDOW (window)");
}

fn lock(w: anytype) void {
    c.g_mutex_lock(&win(w).lock);
}

fn unlock(w: anytype) void {
    c.g_mutex_unlock(&win(w).lock);
}

pub export fn gst_gl_window_error_quark() c.GQuark {
    return c.g_quark_from_static_string("gst-gl-window-error-quark");
}

fn defaultOpen(w: OWindow, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    c.g_main_context_push_thread_default(w[0].main_context);
    return 1;
}

fn defaultClose(w: OWindow) callconv(.c) void {
    c.g_main_context_pop_thread_default(w[0].main_context);
}

fn defaultRun(w: OWindow) callconv(.c) void {
    c.g_main_loop_run(pv(w).loop);
}

fn quitFunc(data: c.gpointer) callconv(.c) void {
    const w = win(data);
    _ = c.gst_gl_display_remove_window(w.display, w);
    c.g_main_loop_quit(pv(w).loop);
}

fn defaultQuit(w: OWindow) callconv(.c) void {
    gst_gl_window_send_message_async(w, quitFunc, c.gst_object_ref(w), c.gst_object_unref);
}

fn drawCb(data: c.gpointer) callconv(.c) void {
    const w = win(data);
    const ctx = gst_gl_window_get_context(w);
    if (w.queue_resize != 0) {
        var width: c.guint = 0;
        var height: c.guint = 0;
        gst_gl_window_get_surface_dimensions(w, &width, &height);
        gst_gl_window_resize(w, width, height);
    }
    if (w.draw) |d| d(w.draw_data);
    c.gst_gl_context_swap_buffers(ctx);
    c.gst_object_unref(ctx);
}

fn defaultDraw(w: OWindow) callconv(.c) void {
    gst_gl_window_send_message(w, drawCb, w);
}

const SyncMessage = struct {
    window: *Window,
    fired: bool,
    callback: c.GstGLWindowCB,
    data: c.gpointer,
};

fn runSync(data: c.gpointer) callconv(.c) void {
    const m: *SyncMessage = @ptrCast(@alignCast(data));
    if (m.callback) |cb| cb(m.data);
    const p = pv(m.window);
    c.g_mutex_lock(&p.sync_lock);
    m.fired = true;
    c.g_cond_broadcast(&p.sync_cond);
    c.g_mutex_unlock(&p.sync_lock);
}

fn defaultSend(w: OWindow, callback: c.GstGLWindowCB, data: c.gpointer) callconv(.c) void {
    var m = SyncMessage{ .window = win(w), .fired = false, .callback = callback, .data = data };
    gst_gl_window_send_message_async(w, runSync, &m, null);
    const p = pv(w);
    c.g_mutex_lock(&p.sync_lock);
    while (!@atomicLoad(bool, &m.fired, .acquire)) c.g_cond_wait(&p.sync_cond, &p.sync_lock);
    c.g_mutex_unlock(&p.sync_lock);
}

const AsyncMessage = struct {
    callback: c.GstGLWindowCB,
    data: c.gpointer,
    destroy: c.GDestroyNotify,
};

fn runAsync(data: c.gpointer) callconv(.c) c.gboolean {
    const m: *AsyncMessage = @ptrCast(@alignCast(data));
    if (m.callback) |cb| cb(m.data);
    if (m.destroy) |d| d(m.data);
    c.g_free(m);
    return 0;
}

fn defaultSendAsync(w: OWindow, callback: c.GstGLWindowCB, data: c.gpointer, destroy: c.GDestroyNotify) callconv(.c) void {
    const m: *AsyncMessage = @ptrCast(@alignCast(c.g_malloc(@sizeOf(AsyncMessage))));
    m.* = .{ .callback = callback, .data = data, .destroy = destroy };
    c.g_main_context_invoke(w[0].main_context, runAsync, m);
}

fn defaultHasOutput(_: OWindow) callconv(.c) c.gboolean {
    return 1;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const w = win(o);
    const p = pv(w);
    _ = c.gst_gl_display_remove_window(w.display, w);
    if (p.loop != null) c.g_main_loop_unref(p.loop);
    if (w.main_context != null) c.g_main_context_unref(w.main_context);
    w.main_context = null;
    c.g_weak_ref_clear(&w.context_ref);
    c.g_mutex_clear(&w.lock);
    c.g_mutex_clear(&p.sync_lock);
    c.g_cond_clear(&p.sync_cond);
    c.gst_object_unref(w.display);
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const wc: *WindowClass = @ptrCast(@alignCast(k));
    wc.open = defaultOpen;
    wc.close = defaultClose;
    wc.run = defaultRun;
    wc.quit = defaultQuit;
    wc.draw = defaultDraw;
    wc.send_message = defaultSend;
    wc.send_message_async = defaultSendAsync;
    wc.has_output_surface = defaultHasOutput;
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    signals[S_MOUSE] = c.g_signal_new("mouse-event", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 4, c.G_TYPE_STRING, c.G_TYPE_INT, c.G_TYPE_DOUBLE, c.G_TYPE_DOUBLE);
    signals[S_KEY] = c.g_signal_new("key-event", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 2, c.G_TYPE_STRING, c.G_TYPE_STRING);
    signals[S_SCROLL] = c.g_signal_new("scroll-event", t, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 4, c.G_TYPE_DOUBLE, c.G_TYPE_DOUBLE, c.G_TYPE_DOUBLE, c.G_TYPE_DOUBLE);
    signals[S_HANDLE] = c.g_signal_new("window-handle_changed", t, c.G_SIGNAL_RUN_LAST, 0, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_NONE, 0);
    initDebug();
}

var debug_done: usize = 0;

fn initDebug() void {
    if (c.g_once_init_enter(&debug_done) != 0) {
        _ = c._gst_debug_category_new("glwindow", 0, "glwindow element");
        c.g_once_init_leave(&debug_done, 1);
    }
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const w = win(inst);
    w.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    const p = pv(w);
    p.* = std.mem.zeroes(Priv);
    c.g_mutex_init(&w.lock);
    w.is_drawing = 0;
    c.g_weak_ref_init(&w.context_ref, null);
    c.g_mutex_init(&p.sync_lock);
    c.g_cond_init(&p.sync_cond);
    w.main_context = c.g_main_context_new();
    p.loop = c.g_main_loop_new(w.main_context, 0);
}

pub export fn gst_gl_window_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLWindow", WindowClass, Window, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            return t;
        }
    }.f);
}

fn dummyHasOutput(_: OWindow) callconv(.c) c.gboolean {
    return 0;
}

fn dummySetHandle(w: OWindow, h: c.guintptr) callconv(.c) void {
    @as(*Dummy, @ptrCast(@alignCast(w))).handle = h;
}

fn dummyGetHandle(w: OWindow) callconv(.c) c.guintptr {
    return @as(*Dummy, @ptrCast(@alignCast(w))).handle;
}

fn dummyGetDisplay(_: OWindow) callconv(.c) c.guintptr {
    return 0;
}

fn dummyClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const wc: *WindowClass = @ptrCast(@alignCast(k));
    wc.get_display = dummyGetDisplay;
    wc.get_window_handle = dummyGetHandle;
    wc.set_window_handle = dummySetHandle;
    wc.has_output_surface = dummyHasOutput;
}

fn dummyType() c.GType {
    return dummy_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_gl_window_get_type, "GstGLDummyWindow", WindowClass, Dummy, dummyClassInit, null, 0);
        }
    }.f);
}

pub fn dummyNew() *Window {
    const w = c.g_object_new(dummyType(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(w);
    return win(w);
}

pub export fn gst_gl_window_new(display: [*c]c.GstGLDisplay) OWindow {
    if (!check.that(display != null, "gst_gl_window_new", "display != NULL")) return null;
    initDebug();
    const choice = c.g_getenv("GST_GL_WINDOW");
    var w: ?*Window = null;
    if (w == null and (choice == null or c.g_strstr_len(choice, 3, "x11") != null)) w = backends.x11Window(display);
    if (w == null and (choice == null or c.g_strstr_len(choice, 7, "wayland") != null)) w = backends.waylandWindow(display);
    if (w == null and (choice == null or c.g_strstr_len(choice, 3, "gbm") != null)) w = backends.gbmWindow(display);
    if (w == null and (choice == null or c.g_strstr_len(choice, 11, "surfaceless") != null)) w = dummyNew();
    if (w == null) w = dummyNew();
    w.?.display = @ptrCast(@alignCast(c.gst_object_ref(display)));
    return w;
}

const HandleCb = struct {
    window: *Window,
    handle: c.guintptr,
};

fn setHandleCb(data: c.gpointer) callconv(.c) void {
    const d: *HandleCb = @ptrCast(@alignCast(data));
    const ctx = gst_gl_window_get_context(d.window);
    var thread: ?*c.GThread = null;
    if (ctx != null) {
        thread = c.gst_gl_context_get_thread(ctx);
        if (thread != null) {
            if (thread != c.g_thread_self()) check.assertFail("gstglwindow.c", 385, "_set_window_handle_cb", "thread == g_thread_self ()");
            _ = c.gst_gl_context_activate(ctx, 0);
        }
    }
    klass(d.window).set_window_handle.?(d.window, d.handle);
    c.g_signal_emit(d.window, signals[S_HANDLE], 0, VNONE);
    if (ctx != null and thread != null) _ = c.gst_gl_context_activate(ctx, 1);
    if (ctx != null) c.gst_object_unref(ctx);
    if (thread != null) c.g_thread_unref(thread);
}

fn freeHandleCb(data: c.gpointer) callconv(.c) void {
    const d: *HandleCb = @ptrCast(@alignCast(data));
    c.gst_object_unref(d.window);
    c.g_free(d);
}

pub export fn gst_gl_window_set_window_handle(w: OWindow, handle: c.guintptr) void {
    const fname = "gst_gl_window_set_window_handle";
    if (!valid(w, fname)) return;
    if (!check.that(handle != 0, fname, "handle != 0")) return;
    if (!check.that(klass(w).set_window_handle != null, fname, "window_class->set_window_handle != NULL")) return;
    const d: *HandleCb = @ptrCast(@alignCast(c.g_malloc(@sizeOf(HandleCb))));
    d.* = .{ .window = win(c.gst_object_ref(w)), .handle = handle };
    gst_gl_window_send_message_async(w, setHandleCb, d, freeHandleCb);
}

pub export fn gst_gl_window_draw(w: OWindow) void {
    if (!valid(w, "gst_gl_window_draw")) return;
    if (!check.that(klass(w).draw != null, "gst_gl_window_draw", "window_class->draw != NULL")) return;
    if (w[0].is_drawing != 0) return;
    klass(w).draw.?(w);
}

pub export fn gst_gl_window_set_preferred_size(w: OWindow, width: c.gint, height: c.gint) void {
    if (!valid(w, "gst_gl_window_set_preferred_size")) return;
    if (klass(w).set_preferred_size) |f| f(w, width, height);
}

pub export fn gst_gl_window_show(w: OWindow) void {
    if (!valid(w, "gst_gl_window_show")) return;
    if (klass(w).show) |f| f(w);
}

pub export fn gst_gl_window_run(w: OWindow) void {
    if (!valid(w, "gst_gl_window_run")) return;
    if (!check.that(klass(w).run != null, "gst_gl_window_run", "window_class->run != NULL")) return;
    klass(w).run.?(w);
}

pub export fn gst_gl_window_quit(w: OWindow) void {
    if (!valid(w, "gst_gl_window_quit")) return;
    if (!check.that(klass(w).quit != null, "gst_gl_window_quit", "window_class->quit != NULL")) return;
    lock(w);
    klass(w).quit.?(w);
    unlock(w);
}

pub export fn gst_gl_window_send_message(w: OWindow, callback: c.GstGLWindowCB, data: c.gpointer) void {
    const fname = "gst_gl_window_send_message";
    if (!valid(w, fname)) return;
    if (!check.that(callback != null, fname, "callback != NULL")) return;
    if (!check.that(klass(w).send_message != null, fname, "window_class->send_message != NULL")) return;
    klass(w).send_message.?(w, callback, data);
}

pub export fn gst_gl_window_has_output_surface(w: OWindow) c.gboolean {
    if (!valid(w, "gst_gl_window_has_output_surface")) return 0;
    if (klass(w).has_output_surface == null) check.assertFail("gstglwindow.c", 659, "gst_gl_window_has_output_surface", "window_class->has_output_surface");
    return klass(w).has_output_surface.?(w);
}

pub export fn gst_gl_window_send_message_async(w: OWindow, callback: c.GstGLWindowCB, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const fname = "gst_gl_window_send_message_async";
    if (!valid(w, fname)) return;
    if (!check.that(callback != null, fname, "callback != NULL")) return;
    if (!check.that(klass(w).send_message_async != null, fname, "window_class->send_message_async != NULL")) return;
    klass(w).send_message_async.?(w, callback, data, destroy);
}

pub export fn gst_gl_window_set_draw_callback(w: OWindow, callback: c.GstGLWindowCB, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!valid(w, "gst_gl_window_set_draw_callback")) return;
    lock(w);
    if (w[0].draw_notify) |n| n(w[0].draw_data);
    w[0].draw = callback;
    w[0].draw_data = data;
    w[0].draw_notify = notify;
    unlock(w);
}

pub export fn gst_gl_window_set_resize_callback(w: OWindow, callback: c.GstGLWindowResizeCB, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!valid(w, "gst_gl_window_set_resize_callback")) return;
    lock(w);
    if (w[0].resize_notify) |n| n(w[0].resize_data);
    w[0].resize = callback;
    w[0].resize_data = data;
    w[0].resize_notify = notify;
    unlock(w);
}

pub export fn gst_gl_window_set_close_callback(w: OWindow, callback: c.GstGLWindowCB, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!valid(w, "gst_gl_window_set_close_callback")) return;
    lock(w);
    if (w[0].close_notify) |n| n(w[0].close_data);
    w[0].close = callback;
    w[0].close_data = data;
    w[0].close_notify = notify;
    unlock(w);
}

pub export fn gst_gl_window_get_display(w: OWindow) c.guintptr {
    if (!valid(w, "gst_gl_window_get_display")) return 0;
    if (!check.that(klass(w).get_display != null, "gst_gl_window_get_display", "window_class->get_display != NULL")) return 0;
    return klass(w).get_display.?(w);
}

pub export fn gst_gl_window_get_window_handle(w: OWindow) c.guintptr {
    if (!valid(w, "gst_gl_window_get_window_handle")) return 0;
    if (!check.that(klass(w).get_window_handle != null, "gst_gl_window_get_window_handle", "window_class->get_window_handle != NULL")) return 0;
    return klass(w).get_window_handle.?(w);
}

pub export fn gst_gl_window_get_context(w: OWindow) [*c]c.GstGLContext {
    if (!valid(w, "gst_gl_window_get_context")) return null;
    return @ptrCast(@alignCast(c.g_weak_ref_get(&w[0].context_ref)));
}

pub export fn gst_gl_window_get_surface_dimensions(w: OWindow, width: [*c]c.guint, height: [*c]c.guint) void {
    lock(w);
    if (width != null) width[0] = pv(w).surface_width;
    if (height != null) height[0] = pv(w).surface_height;
    unlock(w);
}

pub export fn gst_gl_window_send_key_event(w: OWindow, event_type: [*c]const u8, key: [*c]const u8) void {
    c.g_signal_emit(w, signals[S_KEY], 0, event_type, key);
}

pub export fn gst_gl_window_send_mouse_event(w: OWindow, event_type: [*c]const u8, button: c_int, x: f64, y: f64) void {
    c.g_signal_emit(w, signals[S_MOUSE], 0, event_type, button, x, y);
}

pub export fn gst_gl_window_send_scroll_event(w: OWindow, x: f64, y: f64, dx: f64, dy: f64) void {
    c.g_signal_emit(w, signals[S_SCROLL], 0, x, y, dx, dy);
}

pub export fn gst_gl_window_handle_events(w: OWindow, handle_events: c.gboolean) void {
    if (!valid(w, "gst_gl_window_handle_events")) return;
    if (klass(w).handle_events) |f| f(w, handle_events);
}

pub export fn gst_gl_window_set_render_rectangle(w: OWindow, x_in: c.gint, y_in: c.gint, width_in: c.gint, height_in: c.gint) c.gboolean {
    if (!valid(w, "gst_gl_window_set_render_rectangle")) return 0;
    var x = x_in;
    var y = y_in;
    var width = width_in;
    var height = height_in;
    lock(w);
    defer unlock(w);
    if (x < 0 or y < 0) {
        x = 0;
        y = 0;
        width = @bitCast(pv(w).surface_width);
        height = @bitCast(pv(w).surface_height);
    }
    if (x < 0 or y < 0 or width <= 0 or height <= 0) return 0;
    if (klass(w).set_render_rectangle) |f| return f(w, x, y, width, height);
    return 0;
}

pub export fn gst_gl_window_queue_resize(w: OWindow) void {
    if (!valid(w, "gst_gl_window_queue_resize")) return;
    w[0].queue_resize = 1;
    if (klass(w).queue_resize) |f| f(w);
}

const Resize = struct {
    window: *Window,
    width: c.guint,
    height: c.guint,
};

fn onResize(data: c.gpointer) callconv(.c) void {
    const r: *Resize = @ptrCast(@alignCast(data));
    lock(r.window);
    if (r.window.resize) |f| f(r.window.resize_data, r.width, r.height);
    pv(r.window).surface_width = r.width;
    pv(r.window).surface_height = r.height;
    unlock(r.window);
    r.window.queue_resize = 0;
}

pub export fn gst_gl_window_resize(w: OWindow, width: c.guint, height: c.guint) void {
    if (!valid(w, "gst_gl_window_resize")) return;
    var r = Resize{ .window = win(w), .width = width, .height = height };
    gst_gl_window_send_message(w, onResize, &r);
}

pub export fn gst_gl_window_controls_viewport(w: OWindow) c.gboolean {
    if (!valid(w, "gst_gl_window_controls_viewport")) return 0;
    if (klass(w).controls_viewport) |f| return f(w);
    return 0;
}

pub export fn gst_gl_window_set_request_output_surface(w: OWindow, output_surface: c.gboolean) void {
    if (!valid(w, "gst_gl_window_set_request_output_surface")) return;
    pv(w).request_output_surface = output_surface;
}

pub export fn gst_gl_window_get_request_output_surface(w: OWindow) c.gboolean {
    if (!valid(w, "gst_gl_window_get_request_output_surface")) return 0;
    return pv(w).request_output_surface;
}
