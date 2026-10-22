const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const backends = @import("backends.zig");
const context = @import("context.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Disp = c.GstGLDisplay;
const DispClass = c.GstGLDisplayClass;
const ODisp = [*c]Disp;
const OCtx = [*c]c.GstGLContext;
const OWin = [*c]c.GstGLWindow;

const CONTEXT_TYPE = "gst.gl.GLDisplay";

const Priv = struct {
    gl_api: c.GstGLAPI,
    contexts: ?*c.GList,
    event_thread: ?*c.GThread,
    thread_lock: c.GMutex,
    thread_cond: c.GCond,
    window_lock: c.GMutex,
};

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;
var create_signal: c.guint = 0;
var cat: ?*c.GstDebugCategory = null;
var context_cat: ?*c.GstDebugCategory = null;

fn pv(d: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Disp, @ptrCast(@alignCast(d))).priv));
}

fn dp(p: anytype) *Disp {
    return @ptrCast(@alignCast(p));
}

fn klass(p: anytype) *DispClass {
    return gtype.classPeek(DispClass, p);
}

pub fn isDisplay(p: anytype) bool {
    return gtype.instanceOf(p, gst_gl_display_get_type());
}

fn valid(p: anytype, comptime fname: []const u8) bool {
    return check.that(isDisplay(p), fname, "GST_IS_GL_DISPLAY (display)");
}

fn objLock(p: anytype) void {
    c.g_mutex_lock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn objUnlock(p: anytype) void {
    c.g_mutex_unlock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn unlockMain(data: c.gpointer) callconv(.c) c.gboolean {
    c.g_mutex_unlock(&pv(data).thread_lock);
    return 0;
}

fn eventMain(data: c.gpointer) callconv(.c) c.gpointer {
    const d = dp(data);
    const p = pv(d);
    c.g_mutex_lock(&p.thread_lock);
    d.main_context = c.g_main_context_new();
    d.main_loop = c.g_main_loop_new(d.main_context, 0);
    c.g_main_context_invoke(d.main_context, unlockMain, d);
    c.g_cond_broadcast(&p.thread_cond);
    c.g_main_loop_run(d.main_loop);
    c.g_mutex_lock(&p.thread_lock);
    c.g_main_loop_unref(d.main_loop);
    c.g_main_context_unref(d.main_context);
    d.main_loop = null;
    d.main_context = null;
    c.g_cond_broadcast(&p.thread_cond);
    c.g_mutex_unlock(&p.thread_lock);
    return null;
}

fn defaultHandle(_: ODisp) callconv(.c) c.guintptr {
    return 0;
}

fn defaultCreateWindow(d: ODisp) callconv(.c) OWin {
    return c.gst_gl_window_new(d);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const d = dp(o);
    const p = pv(d);
    if (d.main_loop != null) c.g_main_loop_quit(d.main_loop);
    if (p.event_thread) |t| {
        c.g_mutex_lock(&p.thread_lock);
        while (d.main_loop != null) c.g_cond_wait(&p.thread_cond, &p.thread_lock);
        c.g_mutex_unlock(&p.thread_lock);
        c.g_thread_unref(t);
    }
    p.event_thread = null;
    if (d.event_source != null) {
        c.g_source_destroy(d.event_source);
        c.g_source_unref(d.event_source);
    }
    d.event_source = null;
    parent.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const d = dp(o);
    const p = pv(d);
    var l = p.contexts;
    while (l) |n| : (l = n.next) {
        c.g_weak_ref_clear(@ptrCast(@alignCast(n.data)));
        c.g_free(n.data);
    }
    c.g_list_free(d.windows);
    c.g_list_free(p.contexts);
    c.g_cond_clear(&p.thread_cond);
    c.g_mutex_clear(&p.thread_lock);
    c.g_mutex_clear(&p.window_lock);
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    create_signal = c.g_signal_new("create-context", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, context.gst_gl_context_get_type(), 1, context.gst_gl_context_get_type());
    const dc: *DispClass = @ptrCast(@alignCast(k));
    dc.get_handle = defaultHandle;
    dc.create_window = defaultCreateWindow;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.dispose = dispose;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const d = dp(inst);
    d.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    const p = pv(d);
    p.* = std.mem.zeroes(Priv);
    d.type = c.GST_GL_DISPLAY_TYPE_ANY;
    p.gl_api = c.GST_GL_API_ANY;
    c.g_mutex_init(&p.thread_lock);
    c.g_cond_init(&p.thread_cond);
    c.g_mutex_init(&p.window_lock);
    p.event_thread = c.g_thread_new("gldisplay-event", eventMain, d);
    c.g_mutex_lock(&p.thread_lock);
    while (d.main_loop == null) c.g_cond_wait(&p.thread_cond, &p.thread_lock);
    c.g_mutex_unlock(&p.thread_lock);
    backends.memoryInit();
}

pub export fn gst_gl_display_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLDisplay", DispClass, Disp, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            initDebug();
            context_cat = c._gst_debug_get_category("GST_CONTEXT");
            return t;
        }
    }.f);
}

var debug_done: usize = 0;

fn initDebug() void {
    if (c.g_once_init_enter(&debug_done) != 0) {
        cat = c._gst_debug_category_new("gldisplay", 0, "opengl display");
        c.g_once_init_leave(&debug_done, 1);
    }
}

fn envType() c.GstGLDisplayType {
    const env = c.g_getenv("GST_GL_WINDOW") orelse return c.GST_GL_DISPLAY_TYPE_ANY;
    const table = [_]struct { n: c.gssize, s: [*:0]const u8, t: c.GstGLDisplayType }{
        .{ .n = 3, .s = "x11", .t = c.GST_GL_DISPLAY_TYPE_X11 },
        .{ .n = 7, .s = "wayland", .t = c.GST_GL_DISPLAY_TYPE_WAYLAND },
        .{ .n = 5, .s = "cocoa", .t = c.GST_GL_DISPLAY_TYPE_COCOA },
        .{ .n = 5, .s = "win32", .t = c.GST_GL_DISPLAY_TYPE_WIN32 },
        .{ .n = 8, .s = "dispmanx", .t = c.GST_GL_DISPLAY_TYPE_DISPMANX },
        .{ .n = 10, .s = "egl-device", .t = c.GST_GL_DISPLAY_TYPE_EGL_DEVICE },
        .{ .n = 3, .s = "egl", .t = c.GST_GL_DISPLAY_TYPE_EGL },
        .{ .n = 6, .s = "viv-fb", .t = c.GST_GL_DISPLAY_TYPE_VIV_FB },
        .{ .n = 3, .s = "gbm", .t = c.GST_GL_DISPLAY_TYPE_GBM },
        .{ .n = 4, .s = "eagl", .t = c.GST_GL_DISPLAY_TYPE_EAGL },
        .{ .n = 7, .s = "android", .t = c.GST_GL_DISPLAY_TYPE_EGL },
        .{ .n = 5, .s = "winrt", .t = c.GST_GL_DISPLAY_TYPE_EGL },
        .{ .n = 11, .s = "surfaceless", .t = c.GST_GL_DISPLAY_TYPE_EGL_SURFACELESS },
    };
    for (table) |e| {
        if (c.g_strstr_len(env, e.n, e.s) != null) return e.t;
    }
    return c.GST_GL_DISPLAY_TYPE_NONE;
}

fn dummy() *Disp {
    const d = c.g_object_new(gst_gl_display_get_type(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(d);
    return dp(d);
}

pub export fn gst_gl_display_new_with_type(type_in: c.GstGLDisplayType) ODisp {
    initDebug();
    var t = type_in;
    var d: ?*Disp = null;
    if (d == null and t & c.GST_GL_DISPLAY_TYPE_WAYLAND != 0) d = backends.waylandDisplay();
    if (d == null and t & c.GST_GL_DISPLAY_TYPE_X11 != 0) d = backends.x11Display();
    if (d == null and t & c.GST_GL_DISPLAY_TYPE_GBM != 0) d = backends.gbmDisplay();
    if (d == null and t == c.GST_GL_DISPLAY_TYPE_EGL_DEVICE) d = backends.eglDeviceDisplay();
    if (d == null and t & c.GST_GL_DISPLAY_TYPE_EGL != 0) d = backends.eglDisplay();
    if (d == null and t & c.GST_GL_DISPLAY_TYPE_EGL_SURFACELESS != 0) d = backends.eglSurfacelessDisplay();
    const known: c.GstGLDisplayType = c.GST_GL_DISPLAY_TYPE_COCOA | c.GST_GL_DISPLAY_TYPE_WAYLAND | c.GST_GL_DISPLAY_TYPE_X11 | c.GST_GL_DISPLAY_TYPE_VIV_FB | c.GST_GL_DISPLAY_TYPE_GBM | c.GST_GL_DISPLAY_TYPE_EGL_DEVICE | c.GST_GL_DISPLAY_TYPE_EGL | c.GST_GL_DISPLAY_TYPE_EGL_SURFACELESS | c.GST_GL_DISPLAY_TYPE_DISPMANX | c.GST_GL_DISPLAY_TYPE_WINRT | c.GST_GL_DISPLAY_TYPE_ANDROID | c.GST_GL_DISPLAY_TYPE_WIN32 | c.GST_GL_DISPLAY_TYPE_EAGL;
    if (d == null and t != c.GST_GL_DISPLAY_TYPE_ANY and t != c.GST_GL_DISPLAY_TYPE_NONE) {
        t &= ~known;
        if (t != 0 and t & (t -% 1) == 0) {
            d = dummy();
            d.?.type = t;
        }
    }
    return d;
}

pub export fn gst_gl_display_new() ODisp {
    return gst_gl_display_new_with_type(envType()) orelse dummy();
}

pub export fn gst_gl_display_get_handle(d: ODisp) c.guintptr {
    const fname = "gst_gl_display_get_handle";
    if (!valid(d, fname)) return 0;
    const k = klass(d);
    if (!check.that(k.get_handle != null, fname, "klass->get_handle != NULL")) return 0;
    return k.get_handle.?(d);
}

pub export fn gst_gl_display_filter_gl_api(d: ODisp, api: c.GstGLAPI) void {
    if (!valid(d, "gst_gl_display_filter_gl_api")) return;
    objLock(d);
    pv(d).gl_api &= api;
    objUnlock(d);
}

pub export fn gst_gl_display_get_gl_api_unlocked(d: ODisp) c.GstGLAPI {
    if (!valid(d, "gst_gl_display_get_gl_api_unlocked")) return c.GST_GL_API_NONE;
    return pv(d).gl_api;
}

pub export fn gst_gl_display_get_gl_api(d: ODisp) c.GstGLAPI {
    if (!valid(d, "gst_gl_display_get_gl_api")) return c.GST_GL_API_NONE;
    objLock(d);
    const r = pv(d).gl_api;
    objUnlock(d);
    return r;
}

pub export fn gst_gl_display_get_handle_type(d: ODisp) c.GstGLDisplayType {
    if (!valid(d, "gst_gl_display_get_handle_type")) return c.GST_GL_DISPLAY_TYPE_NONE;
    return d[0].type;
}

pub export fn gst_context_set_gl_display(ctx: ?*c.GstContext, d: ODisp) void {
    if (!check.that(ctx != null, "gst_context_set_gl_display", "context != NULL")) return;
    const s = c.gst_context_writable_structure(ctx);
    c.gst_structure_set(s, CONTEXT_TYPE, gst_gl_display_get_type(), d, @as([*c]const u8, null));
}

pub export fn gst_context_get_gl_display(ctx: ?*c.GstContext, d: [*c]ODisp) c.gboolean {
    const fname = "gst_context_get_gl_display";
    if (!check.that(d != null, fname, "display != NULL")) return 0;
    if (!check.that(ctx != null, fname, "context != NULL")) return 0;
    const s = c.gst_context_get_structure(ctx);
    return c.gst_structure_get(s, CONTEXT_TYPE, gst_gl_display_get_type(), d, @as([*c]const u8, null));
}

pub export fn gst_gl_display_create_context(d: ODisp, other: OCtx, out: [*c]OCtx, err: [*c][*c]c.GError) c.gboolean {
    const fname = "gst_gl_display_create_context";
    if (!check.that(d != null, fname, "display != NULL")) return 0;
    if (!check.that(out != null, fname, "p_context != NULL")) return 0;
    if (!check.that(err == null or err[0] == null, fname, "error == NULL || *error == NULL")) return 0;
    var ctx: OCtx = null;
    c.g_signal_emit(d, create_signal, 0, other, &ctx);
    if (ctx != null) {
        out[0] = ctx;
        return 1;
    }
    ctx = context.gst_gl_context_new(d);
    if (ctx == null) {
        c.g_set_error(err, context.gst_gl_context_error_quark(), c.GST_GL_CONTEXT_ERROR_FAILED, "Failed to create GL context");
        return 0;
    }
    const r = context.gst_gl_context_create(ctx, other, err);
    if (r != 0) out[0] = ctx else c.gst_object_unref(ctx);
    return r;
}

pub export fn gst_gl_display_create_window(d: ODisp) OWin {
    const fname = "gst_gl_display_create_window";
    if (!valid(d, fname)) return null;
    const k = klass(d);
    if (!check.that(k.create_window != null, fname, "klass->create_window != NULL")) return null;
    const p = pv(d);
    c.g_mutex_lock(&p.window_lock);
    const w = k.create_window.?(d);
    if (w != null) d[0].windows = c.g_list_prepend(d[0].windows, w);
    c.g_mutex_unlock(&p.window_lock);
    return w;
}

pub export fn gst_gl_display_remove_window(d: ODisp, w: OWin) c.gboolean {
    const p = pv(d);
    c.g_mutex_lock(&p.window_lock);
    defer c.g_mutex_unlock(&p.window_lock);
    const l = c.g_list_find(d[0].windows, w) orelse return 0;
    d[0].windows = c.g_list_delete_link(d[0].windows, l);
    return 1;
}

pub export fn gst_gl_display_find_window(d: ODisp, data: c.gpointer, cmp: c.GCompareFunc) OWin {
    const r = gst_gl_display_retrieve_window(d, data, cmp);
    if (r != null) c.gst_object_unref(r);
    return r;
}

pub export fn gst_gl_display_retrieve_window(d: ODisp, data: c.gpointer, cmp: c.GCompareFunc) OWin {
    const p = pv(d);
    c.g_mutex_lock(&p.window_lock);
    defer c.g_mutex_unlock(&p.window_lock);
    const l = c.g_list_find_custom(d[0].windows, data, cmp) orelse return null;
    return @ptrCast(@alignCast(c.gst_object_ref(l.*.data)));
}

fn dropLink(p: *Priv, l: *c.GList) void {
    c.g_weak_ref_clear(@ptrCast(@alignCast(l.data)));
    c.g_free(l.data);
    p.contexts = c.g_list_delete_link(p.contexts, l);
}

fn forThread(d: ODisp, thread: ?*c.GThread) OCtx {
    const p = pv(d);
    var prev: ?*c.GList = null;
    var l = p.contexts;
    while (l) |n| {
        const ctx: OCtx = @ptrCast(@alignCast(c.g_weak_ref_get(@ptrCast(@alignCast(n.data)))));
        if (ctx == null) {
            dropLink(p, n);
            l = if (prev) |pr| pr.next else p.contexts;
            continue;
        }
        if (thread == null) return ctx;
        const ct = context.gst_gl_context_get_thread(ctx);
        if (thread != ct) {
            if (ct) |t| c.g_thread_unref(t);
            c.gst_object_unref(ctx);
            prev = n;
            l = n.next;
            continue;
        }
        if (ct) |t| c.g_thread_unref(t);
        return ctx;
    }
    return null;
}

pub export fn gst_gl_display_get_gl_context_for_thread(d: ODisp, thread: ?*c.GThread) OCtx {
    if (!valid(d, "gst_gl_display_get_gl_context_for_thread")) return null;
    return forThread(d, thread);
}

fn collides(a: OCtx, b: OCtx) bool {
    if (a == null or b == null) return false;
    const ta = context.gst_gl_context_get_thread(a);
    const tb = context.gst_gl_context_get_thread(b);
    defer {
        if (ta) |t| c.g_thread_unref(t);
        if (tb) |t| c.g_thread_unref(t);
    }
    return ta != null and tb != null and ta == tb;
}

pub export fn gst_gl_display_add_context(d: ODisp, ctx: OCtx) c.gboolean {
    const fname = "gst_gl_display_add_context";
    if (!valid(d, fname)) return 0;
    if (!check.that(context.isContext(ctx), fname, "GST_IS_GL_CONTEXT (context)")) return 0;
    const cd = context.gst_gl_context_get_display(ctx);
    if (cd != d) check.assertFail("gstgldisplay.c", 721, "gst_gl_display_add_context", "context_display == display");
    c.gst_object_unref(cd);
    var collision: OCtx = null;
    defer if (collision != null) c.gst_object_unref(collision);
    if (context.gst_gl_context_get_thread(ctx)) |t| {
        collision = forThread(d, t);
        c.g_thread_unref(t);
        if (ctx == collision) return 1;
        if (collides(ctx, collision)) return 0;
    }
    const ref: *c.GWeakRef = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GWeakRef))));
    c.g_weak_ref_init(ref, ctx);
    pv(d).contexts = c.g_list_prepend(pv(d).contexts, ref);
    return 1;
}

pub export fn gst_gl_display_remove_context(d: ODisp, needle: OCtx) void {
    const fname = "gst_gl_display_remove_context";
    if (!valid(d, fname)) return;
    if (!check.that(context.isContext(needle), fname, "GST_IS_GL_CONTEXT (needle)")) return;
    const p = pv(d);
    var prev: ?*c.GList = null;
    var l = p.contexts;
    while (l) |n| {
        const ctx: OCtx = @ptrCast(@alignCast(c.g_weak_ref_get(@ptrCast(@alignCast(n.data)))));
        if (ctx == null or ctx == needle) {
            dropLink(p, n);
            if (ctx != null) {
                c.gst_object_unref(ctx);
                return;
            }
            l = if (prev) |pr| pr.next else p.contexts;
            continue;
        }
        c.gst_object_unref(ctx);
        prev = n;
        l = n.next;
    }
}

pub export fn gst_gl_display_ensure_context(d: ODisp, other: OCtx, ctx: [*c]OCtx, err: [*c][*c]c.GError) c.gboolean {
    const fname = "gst_gl_display_ensure_context";
    if (!valid(d, fname)) return 0;
    if (!check.that(other == null or context.isContext(other), fname, "other_context == NULL || GST_IS_GL_CONTEXT (other_context)")) return 0;
    if (!check.that(ctx != null, fname, "context != NULL")) return 0;
    if (!check.that(ctx[0] == null or context.isContext(ctx[0]), fname, "*context == NULL || GST_IS_GL_CONTEXT (*context)")) return 0;
    if (!check.that(err == null or err[0] == null, fname, "error == NULL || *error == NULL")) return 0;
    if (ctx[0] != null and ctx[0][0].display == d) return 1;
    objLock(d);
    defer objUnlock(d);
    while (true) {
        if (ctx[0] != null) {
            c.gst_object_unref(ctx[0]);
            ctx[0] = null;
        }
        ctx[0] = gst_gl_display_get_gl_context_for_thread(d, null);
        if (ctx[0] == null and gst_gl_display_create_context(d, other, ctx, err) == 0) return 0;
        if (gst_gl_display_add_context(d, ctx[0]) != 0) return 1;
    }
}
