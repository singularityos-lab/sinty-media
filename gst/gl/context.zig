const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const feature = @import("feature.zig");
const backends = @import("backends.zig");
const debug = @import("debug.zig");
const quirks = @import("quirks.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Ctx = c.GstGLContext;
const CtxClass = c.GstGLContextClass;
const OCtx = [*c]Ctx;

const Share = struct {
    refs: std.atomic.Value(i32),
};

pub const Priv = struct {
    gl_thread: ?*c.GThread,
    active_thread: ?*c.GThread,
    render_lock: c.GMutex,
    create_cond: c.GCond,
    destroy_cond: c.GCond,
    created: bool,
    alive: bool,
    other: c.GWeakRef,
    share: ?*Share,
    err: [*c][*c]c.GError,
    gl_major: c.gint,
    gl_minor: c.gint,
    gl_exts: [*c]u8,
    requested: ?*c.GstStructure,
};

const Wrapped = extern struct {
    parent: Ctx,
    handle: c.guintptr,
    platform: c.GstGLPlatform,
    apis: c.GstGLAPI,
};

const WRAPPED_CONFIG = "gst.gl.context.wrapped.config";

var current_key: c.GPrivate = std.mem.zeroes(c.GPrivate);
var once: gtype.Once = .{};
var wrapped_once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;
var debug_done: usize = 0;
pub var cat: ?*c.GstDebugCategory = null;
pub var gldebug_cat: ?*c.GstDebugCategory = null;

const Module = struct {
    once: usize = 0,
    handle: ?*c.GModule = null,

    fn get(m: *Module, comptime names: []const ?[*:0]const u8) ?*c.GModule {
        if (c.g_once_init_enter(&m.once) != 0) {
            for (names) |n| {
                m.handle = c.g_module_open(n, c.G_MODULE_BIND_LAZY);
                if (m.handle != null) break;
            }
            c.g_once_init_leave(&m.once, 1);
        }
        return m.handle;
    }
};

var mod_gl: Module = .{};
var mod_gles: Module = .{};
var mod_self: Module = .{};

pub fn pv(ctx: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Ctx, @ptrCast(@alignCast(ctx))).priv));
}

fn cx(p: anytype) *Ctx {
    return @ptrCast(@alignCast(p));
}

fn klass(p: anytype) *CtxClass {
    return gtype.classPeek(CtxClass, p);
}

pub fn isContext(p: anytype) bool {
    return gtype.instanceOf(p, gst_gl_context_get_type());
}

pub fn isWrapped(p: anytype) bool {
    return gtype.instanceOf(p, wrappedType());
}

fn valid(p: anytype, comptime fname: []const u8) bool {
    return check.that(isContext(p), fname, "GST_IS_GL_CONTEXT (context)");
}

fn shareNew() *Share {
    const s: *Share = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Share))));
    s.refs = .init(1);
    return s;
}

fn shareRef(s: *Share) *Share {
    _ = s.refs.fetchAdd(1, .acq_rel);
    return s;
}

fn shareUnref(s: *Share) void {
    if (s.refs.fetchSub(1, .acq_rel) == 1) c.g_free(s);
}

pub fn initDebug() void {
    if (c.g_once_init_enter(&debug_done) != 0) {
        cat = c._gst_debug_category_new("glcontext", 0, "glcontext element");
        gldebug_cat = c._gst_debug_category_new("gldebug", 0, "OpenGL Debugging");
        c.g_once_init_leave(&debug_done, 1);
    }
}

pub export fn gst_gl_context_error_quark() c.GQuark {
    return c.g_quark_from_static_string("gst-gl-context-error-quark");
}

fn ensureWindow(ctx: *Ctx) void {
    if (ctx.window != null) return;
    const w = c.gst_gl_display_create_window(ctx.display);
    _ = gst_gl_context_set_window(ctx, w);
    c.gst_object_unref(w);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const ctx = cx(inst);
    ctx.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    const p = pv(ctx);
    p.* = std.mem.zeroes(Priv);
    ctx.window = null;
    ctx.gl_vtable = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstGLFuncs))));
    c.g_mutex_init(&p.render_lock);
    c.g_cond_init(&p.create_cond);
    c.g_cond_init(&p.destroy_cond);
    c.g_weak_ref_init(&p.other, null);
}

fn defaultPlatformVersion(_: OCtx, major: [*c]c.gint, minor: [*c]c.gint) callconv(.c) void {
    if (major != null) major[0] = 0;
    if (minor != null) minor[0] = 0;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const ctx = cx(o);
    const p = pv(ctx);
    if (ctx.window != null) {
        c.gst_gl_window_set_resize_callback(ctx.window, null, null, null);
        c.gst_gl_window_set_draw_callback(ctx.window, null, null, null);
        c.g_mutex_lock(&p.render_lock);
        if (p.alive) {
            c.gst_gl_window_quit(ctx.window);
            while (p.alive) c.g_cond_wait(&p.destroy_cond, &p.render_lock);
            if (p.gl_thread) |t| {
                c.g_thread_unref(t);
                p.gl_thread = null;
            }
        }
        c.g_mutex_unlock(&p.render_lock);
        c.gst_gl_window_set_close_callback(ctx.window, null, null, null);
        c.gst_object_unref(ctx.window);
        ctx.window = null;
    }
    if (p.active_thread) |t| {
        c.g_thread_unref(t);
        p.active_thread = null;
    }
    if (p.gl_thread) |t| {
        c.g_thread_unref(t);
        p.gl_thread = null;
    }
    if (p.share) |s| {
        shareUnref(s);
        p.share = null;
    }
    if (ctx.display != null) {
        c.gst_object_unref(ctx.display);
        ctx.display = null;
    }
    if (ctx.gl_vtable != null) {
        c.g_free(ctx.gl_vtable);
        ctx.gl_vtable = null;
    }
    if (p.requested) |r| c.gst_structure_free(r);
    p.requested = null;
    c.g_mutex_clear(&p.render_lock);
    c.g_cond_clear(&p.create_cond);
    c.g_cond_clear(&p.destroy_cond);
    c.g_free(p.gl_exts);
    c.g_weak_ref_clear(&p.other);
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const cc: *CtxClass = @ptrCast(@alignCast(k));
    cc.get_proc_address = gst_gl_context_default_get_proc_address;
    cc.get_gl_platform_version = defaultPlatformVersion;
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
    initDebug();
}

pub export fn gst_gl_context_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLContext", CtxClass, Ctx, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            return t;
        }
    }.f);
}

pub export fn gst_gl_context_new(display: [*c]c.GstGLDisplay) OCtx {
    initDebug();
    const choice = c.g_getenv("GST_GL_PLATFORM");
    var ctx: ?*Ctx = null;
    if (ctx == null and (choice == null or c.g_strstr_len(choice, 3, "glx") != null)) ctx = backends.glxContext(display);
    if (ctx == null and (choice == null or c.g_strstr_len(choice, 3, "egl") != null)) ctx = backends.eglContext(display);
    const r = ctx orelse return null;
    r.display = @ptrCast(@alignCast(c.gst_object_ref(display)));
    return r;
}

pub export fn gst_gl_context_new_wrapped(display: [*c]c.GstGLDisplay, handle: c.guintptr, platform: c.GstGLPlatform, apis: c.GstGLAPI) OCtx {
    const fname = "gst_gl_context_new_wrapped";
    initDebug();
    if (!check.that(gtype.instanceOf(display, c.gst_gl_display_get_type()), fname, "GST_IS_GL_DISPLAY (display)")) return null;
    if (!check.that(handle != 0, fname, "handle != 0")) return null;
    if (!check.that(apis != c.GST_GL_API_ANY, fname, "available_apis != GST_GL_API_ANY")) return null;
    if (!check.that(apis != c.GST_GL_API_NONE, fname, "available_apis != GST_GL_API_NONE")) return null;
    if (!check.that(platform != c.GST_GL_PLATFORM_NONE, fname, "context_type != GST_GL_PLATFORM_NONE")) return null;
    if (!check.that(platform != c.GST_GL_PLATFORM_ANY, fname, "context_type != GST_GL_PLATFORM_ANY")) return null;
    const dapi = c.gst_gl_display_get_gl_api(display);
    if (!check.that(dapi & apis != c.GST_GL_API_NONE, fname, "(display_api & available_apis) != GST_GL_API_NONE")) return null;
    const o = c.g_object_new(wrappedType(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    const w: *Wrapped = @ptrCast(@alignCast(o));
    const ctx = &w.parent;
    ctx.display = @ptrCast(@alignCast(c.gst_object_ref(display)));
    pv(ctx).share = shareNew();
    w.handle = handle;
    w.platform = platform;
    w.apis = apis;
    const cc = klass(ctx);
    if (platform == c.GST_GL_PLATFORM_GLX) {
        cc.get_current_context = backends.glxCurrent;
        cc.get_proc_address = backends.glxProc;
    }
    if (platform == c.GST_GL_PLATFORM_EGL) {
        cc.get_current_context = backends.eglCurrent;
        cc.get_proc_address = backends.eglProc;
    }
    if (cc.get_current_context == null) {
        c.gst_object_unref(ctx);
        return null;
    }
    return ctx;
}

pub export fn gst_gl_context_get_current_gl_context(platform: c.GstGLPlatform) c.guintptr {
    initDebug();
    var h: c.guintptr = 0;
    if (h == 0 and platform & c.GST_GL_PLATFORM_GLX != 0) h = backends.glxCurrent();
    if (h == 0 and platform & c.GST_GL_PLATFORM_EGL != 0) h = backends.eglCurrent();
    return h;
}

pub export fn gst_gl_context_get_proc_address_with_platform(platform: c.GstGLPlatform, api: c.GstGLAPI, name: [*c]const u8) c.gpointer {
    var r: c.gpointer = null;
    if (r == null and platform & c.GST_GL_PLATFORM_GLX != 0) r = backends.glxProc(api, name);
    if (r == null and platform & c.GST_GL_PLATFORM_EGL != 0) r = backends.eglProc(api, name);
    if (r == null) r = gst_gl_context_default_get_proc_address(api, name);
    return r;
}

pub fn parseVersion(s: []const u8) [2]c.gint {
    var out = [2]c.gint{ 0, 0 };
    var i: usize = 0;
    for (0..2) |k| {
        var neg = false;
        if (i < s.len and (s[i] == '-' or s[i] == '+')) {
            neg = s[i] == '-';
            i += 1;
        }
        const start = i;
        var v: c.gint = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) v = v *% 10 +% @as(c.gint, s[i] - '0');
        if (i == start) return out;
        out[k] = if (neg) -v else v;
        if (k == 0) {
            if (i >= s.len or s[i] != '.') return out;
            i += 1;
        }
    }
    return out;
}

const GetStringFn = *const fn (c.GLenum) callconv(.c) [*c]const c.GLubyte;
const GetIntegervFn = *const fn (c.GLenum, [*c]c.GLint) callconv(.c) void;

pub export fn gst_gl_context_get_current_gl_api(platform: c.GstGLPlatform, major: [*c]c.guint, minor: [*c]c.guint) c.GstGLAPI {
    initDebug();
    var ret: c.GstGLAPI = 1 << 31;
    var ver = [2]c.gint{ 0, 0 };
    while (ret != c.GST_GL_API_NONE) : (ret >>= 1) {
        const gs: ?GetStringFn = @ptrCast(gst_gl_context_get_proc_address_with_platform(platform, ret, "glGetString"));
        const gi: ?GetIntegervFn = @ptrCast(gst_gl_context_get_proc_address_with_platform(platform, ret, "glGetIntegerv"));
        const f = gs orelse continue;
        const vp = f(c.GL_VERSION);
        if (vp == null) continue;
        const v = std.mem.span(@as([*:0]const u8, @ptrCast(vp)));
        if (v.len < 3) continue;
        if (c.g_strstr_len(v.ptr, 9, "OpenGL ES") != null) {
            if (v.len < 13) continue;
            ver = parseVersion(v[10..]);
            if (ver[0] <= 0 or ver[1] < 0) continue;
            if (ver[0] == 1) {
                ret = c.GST_GL_API_GLES1;
                break;
            }
            if (ver[0] == 2 or ver[0] == 3) {
                ret = c.GST_GL_API_GLES2;
                break;
            }
            continue;
        }
        ver = parseVersion(v);
        if (ver[0] <= 0 or ver[1] < 0) continue;
        if (gi != null and (ver[0] > 3 or (ver[0] == 3 and ver[1] > 1))) {
            var flags: c.GLint = 0;
            ret = c.GST_GL_API_NONE;
            gi.?(c.GL_CONTEXT_PROFILE_MASK, &flags);
            if (flags & c.GL_CONTEXT_CORE_PROFILE_BIT != 0) ret |= c.GST_GL_API_OPENGL3;
            if (flags & c.GL_CONTEXT_COMPATIBILITY_PROFILE_BIT != 0) ret |= c.GST_GL_API_OPENGL;
            break;
        }
        ret = c.GST_GL_API_OPENGL;
        break;
    }
    if (ret == c.GST_GL_API_NONE) return c.GST_GL_API_NONE;
    if (major != null) major[0] = @bitCast(ver[0]);
    if (minor != null) minor[0] = @bitCast(ver[1]);
    return ret;
}

pub export fn gst_gl_context_activate(ctx: OCtx, activate: c.gboolean) c.gboolean {
    const fname = "gst_gl_context_activate";
    if (!valid(ctx, fname)) return 0;
    const cc = klass(ctx);
    if (!check.that(cc.activate != null, fname, "context_class->activate != NULL")) return 0;
    const p = pv(ctx);
    c.g_mutex_lock(&ctx[0].parent.lock);
    const r = cc.activate.?(ctx, activate);
    if (r != 0 and activate != 0) {
        const old = p.active_thread;
        p.active_thread = c.g_thread_ref(c.g_thread_self());
        if (old) |t| c.g_thread_unref(t);
        c.g_private_set(&current_key, ctx);
    } else {
        if (p.active_thread) |t| {
            c.g_thread_unref(t);
            p.active_thread = null;
        }
        c.g_private_set(&current_key, null);
    }
    c.g_mutex_unlock(&ctx[0].parent.lock);
    return r;
}

pub export fn gst_gl_context_get_thread(ctx: OCtx) ?*c.GThread {
    if (!valid(ctx, "gst_gl_context_get_thread")) return null;
    c.g_mutex_lock(&ctx[0].parent.lock);
    const r = pv(ctx).active_thread;
    if (r) |t| _ = c.g_thread_ref(t);
    c.g_mutex_unlock(&ctx[0].parent.lock);
    return r;
}

pub export fn gst_gl_context_get_gl_api(ctx: OCtx) c.GstGLAPI {
    const fname = "gst_gl_context_get_gl_api";
    if (!valid(ctx, fname)) return c.GST_GL_API_NONE;
    const cc = klass(ctx);
    if (!check.that(cc.get_gl_api != null, fname, "context_class->get_gl_api != NULL")) return c.GST_GL_API_NONE;
    return cc.get_gl_api.?(ctx);
}

pub export fn gst_gl_context_get_proc_address(ctx: OCtx, name: [*c]const u8) c.gpointer {
    const fname = "gst_gl_context_get_proc_address";
    if (!valid(ctx, fname)) return null;
    const cc = klass(ctx);
    if (!check.that(cc.get_proc_address != null, fname, "context_class->get_proc_address != NULL")) return null;
    return cc.get_proc_address.?(gst_gl_context_get_gl_api(ctx), name);
}

pub export fn gst_gl_context_default_get_proc_address(api: c.GstGLAPI, name: [*c]const u8) c.gpointer {
    var r: c.gpointer = null;
    if (r == null and api & c.GST_GL_API_GLES2 != 0) {
        if (mod_gles.get(&.{ "libGLESv2.so.2", "libGLESv2" })) |m| _ = c.g_module_symbol(m, name, &r);
    }
    if (r == null and api & (c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3) != 0) {
        if (mod_gl.get(&.{ "libGL.so.1", "libGL" })) |m| _ = c.g_module_symbol(m, name, &r);
    }
    const self = mod_self.get(&.{null});
    if (r == null) _ = c.g_module_symbol(self, name, &r);
    return r;
}

pub export fn gst_gl_context_set_window(ctx: OCtx, window: [*c]c.GstGLWindow) c.gboolean {
    if (!check.that(!isWrapped(ctx), "gst_gl_context_set_window", "!GST_IS_GL_WRAPPED_CONTEXT (context)")) return 0;
    if (pv(ctx).alive) return 0;
    if (window != null) c.g_weak_ref_set(&window[0].context_ref, ctx);
    if (ctx[0].window != null) c.gst_object_unref(ctx[0].window);
    ctx[0].window = if (window != null) @ptrCast(@alignCast(c.gst_object_ref(window))) else null;
    return 1;
}

pub export fn gst_gl_context_get_window(ctx: OCtx) [*c]c.GstGLWindow {
    if (!valid(ctx, "gst_gl_context_get_window")) return null;
    if (isWrapped(ctx)) return null;
    ensureWindow(ctx);
    return @ptrCast(@alignCast(c.gst_object_ref(ctx[0].window)));
}

pub export fn gst_gl_context_can_share(ctx: OCtx, other: OCtx) c.gboolean {
    const fname = "gst_gl_context_can_share";
    if (!valid(ctx, fname)) return 0;
    if (!check.that(isContext(other), fname, "GST_IS_GL_CONTEXT (other_context)")) return 0;
    const s = pv(ctx).share;
    return @intFromBool(s != null and s == pv(other).share);
}

pub export fn gst_gl_context_create(ctx: OCtx, other: OCtx, err: [*c][*c]c.GError) c.gboolean {
    const fname = "gst_gl_context_create";
    if (!valid(ctx, fname)) return 0;
    if (!check.that(!isWrapped(ctx), fname, "!GST_IS_GL_WRAPPED_CONTEXT (context)")) return 0;
    ensureWindow(ctx);
    const p = pv(ctx);
    c.g_mutex_lock(&p.render_lock);
    if (!p.created) {
        c.g_weak_ref_set(&p.other, other);
        p.err = err;
        p.share = if (other == null) shareNew() else shareRef(pv(other).share.?);
        p.gl_thread = c.g_thread_new("gstglcontext", createThread, ctx);
        while (!p.created) c.g_cond_wait(&p.create_cond, &p.render_lock);
    }
    const alive = p.alive;
    c.g_mutex_unlock(&p.render_lock);
    return @intFromBool(alive);
}

fn setError(err: [*c][*c]c.GError, code: c.gint, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, c.g_set_error, .{ err, gst_gl_context_error_quark(), code, fmt } ++ args);
}

fn contextInfo(ctx: *Ctx, api: c.GstGLAPI, err: [*c][*c]c.GError) bool {
    const gl = ctx.gl_vtable;
    const gs = gl[0].GetString orelse null;
    if (gs == null or gs.?(c.GL_VERSION) == null) {
        setError(err, c.GST_GL_CONTEXT_ERROR_FAILED, "glGetString not defined or returned invalid value", .{});
        return false;
    }
    if (gs.?(c.GL_SHADING_LANGUAGE_VERSION) == null) {
        setError(err, c.GST_GL_CONTEXT_ERROR_FAILED, "No GL shader support available", .{});
        return false;
    }
    _ = gs.?(c.GL_VENDOR);
    _ = gs.?(c.GL_RENDERER);
    const e = gl[0].GetError.?();
    if (e != c.GL_NO_ERROR) {
        setError(err, c.GST_GL_CONTEXT_ERROR_FAILED, "glGetString error: 0x%x", .{e});
        return false;
    }
    var vs: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(gs.?(c.GL_VERSION))));
    if (std.mem.startsWith(u8, vs, "OpenGL ES ")) vs = vs[10..];
    const v = parseVersion(vs);
    const maj: c.guint = @bitCast(v[0]);
    const min: c.guint = @bitCast(v[1]);
    if (api & (c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3) != 0) {
        if (maj < 1 or (maj < 2 and maj >= 1 and min < 2)) {
            setError(err, c.GST_GL_CONTEXT_ERROR_OLD_LIBS, "OpenGL >= 1.2.0 required, found %u.%u", .{ maj, min });
            return false;
        }
    }
    pv(ctx).gl_major = @bitCast(maj);
    pv(ctx).gl_minor = @bitCast(min);
    return true;
}

const COMPILED: c.GstGLAPI = c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2;

fn unlockCreate(data: c.gpointer) callconv(.c) void {
    const p = pv(data);
    p.created = true;
    c.g_cond_signal(&p.create_cond);
    c.g_mutex_unlock(&p.render_lock);
}

fn extString(ctx: *Ctx) *c.GString {
    const gl = ctx.gl_vtable;
    const s = c.g_string_sized_new(1024);
    var n: c.GLint = 0;
    gl[0].GetIntegerv.?(c.GL_NUM_EXTENSIONS, &n);
    var i: c.GLint = 0;
    while (i < n) : (i += 1) {
        const e = gl[0].GetStringi.?(c.GL_EXTENSIONS, @bitCast(i));
        if (e != null) {
            _ = c.g_string_append(s, @ptrCast(e));
            _ = c.g_string_append_c(s, ' ');
        }
    }
    return s;
}

const Fill = struct {
    err: [*c][*c]c.GError,
    ok: c.gboolean,
};

fn fillCb(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const f: *Fill = @ptrCast(@alignCast(data));
    f.ok = gst_gl_context_fill_info(ctx, f.err);
}

fn assertErr(err: [*c][*c]c.GError) void {
    if (!(err == null or err[0] != null)) check.assertFail("gstglcontext.c", 1100, "gst_gl_context_create_thread", "error == NULL || *error != NULL");
}

fn createThread(data: c.gpointer) callconv(.c) c.gpointer {
    const ctx = cx(data);
    const p = pv(ctx);
    c.g_mutex_lock(&p.render_lock);
    const err = p.err;
    const other: OCtx = @ptrCast(@alignCast(c.g_weak_ref_get(&p.other)));
    const cc = klass(ctx);
    const wc = gtype.classPeek(c.GstGLWindowClass, ctx.window);
    if (run(ctx, cc, wc, err, other)) {
        if (other != null) c.gst_object_unref(other);
        c.gst_gl_window_send_message_async(ctx.window, unlockCreate, ctx, null);
        c.gst_gl_window_run(ctx.window);
        c.g_mutex_lock(&p.render_lock);
        p.alive = false;
        _ = gst_gl_context_activate(ctx, 0);
        cc.destroy_context.?(ctx);
        if (ctx.window[0].close) |f| f(ctx.window[0].close_data);
        if (wc.close) |f| f(ctx.window);
        p.created = false;
        c.g_cond_signal(&p.destroy_cond);
        c.g_mutex_unlock(&p.render_lock);
        return null;
    }
    if (other != null) c.gst_object_unref(other);
    p.created = true;
    c.g_cond_signal(&p.create_cond);
    c.g_mutex_unlock(&p.render_lock);
    return null;
}

fn run(ctx: *Ctx, cc: *CtxClass, wc: *c.GstGLWindowClass, err: [*c][*c]c.GError, other: OCtx) bool {
    const p = pv(ctx);
    const dapi = c.gst_gl_display_get_gl_api_unlocked(ctx.display);
    if (dapi == c.GST_GL_API_NONE) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_API, "Cannot create context with satisfying requested apis (display has no GL api!)", .{});
        return false;
    }
    if (wc.open) |open| {
        if (open(ctx.window, err) == 0) {
            assertErr(err);
            return false;
        }
    }
    const uapi = c.gst_gl_api_from_string(c.g_getenv("GST_GL_API"));
    if (uapi & COMPILED & dapi == c.GST_GL_API_NONE) {
        const us = c.gst_gl_api_to_string(uapi);
        const cs = c.gst_gl_api_to_string(COMPILED);
        const ds = c.gst_gl_api_to_string(dapi);
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_API, "Cannot create context with the user requested api (%s).  We have support for (%s), display api (%s)", .{ us, cs, ds });
        c.g_free(us);
        c.g_free(cs);
        c.g_free(ds);
        return false;
    }
    if (c.g_getenv("GST_GL_CONFIG")) |cfg_str| {
        const cfg = c.gst_structure_from_string(cfg_str, null);
        if (cfg == null) {
            setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "could not construct OpenGL config from the 'GST_GL_CONFIG' environment variable", .{});
            return false;
        }
        _ = gst_gl_context_request_config(ctx, c.gst_structure_copy(cfg));
        c.gst_structure_free(cfg);
    } else if (other != null and p.requested == null) {
        if (gst_gl_context_get_config(other)) |cfg| {
            _ = gst_gl_context_request_config(ctx, c.gst_structure_copy(cfg));
            c.gst_structure_free(cfg);
        }
    }
    if (cc.choose_format) |f| {
        if (f(ctx, err) == 0) {
            assertErr(err);
            return false;
        }
    }
    if (cc.create_context.?(ctx, COMPILED & uapi & dapi, other, err) == 0) {
        assertErr(err);
        return false;
    }
    if (gst_gl_context_activate(ctx, 1) == 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "Failed to activate the GL Context", .{});
        return false;
    }
    const api = gst_gl_context_get_gl_api(ctx);
    if (api == c.GST_GL_API_NONE or api == c.GST_GL_API_ANY) check.assertFail("gstglcontext.c", 1068, "gst_gl_context_create_thread", "gl_api != GST_GL_API_NONE && gl_api != GST_GL_API_ANY");
    if (gst_gl_context_get_config(ctx)) |cfg| c.gst_structure_free(cfg);
    if (COMPILED & api & dapi & uapi == c.GST_GL_API_NONE) {
        const us = c.gst_gl_api_to_string(uapi);
        const cs = c.gst_gl_api_to_string(COMPILED);
        const as = c.gst_gl_api_to_string(api);
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_API, "failed to create context, context could not provide correct api. user (%s), compiled (%s), context (%s)", .{ us, cs, as });
        c.g_free(us);
        c.g_free(cs);
        c.g_free(as);
        return false;
    }
    var fill = Fill{ .err = err, .ok = 0 };
    gst_gl_context_thread_add(ctx, fillCb, &fill);
    if (fill.ok == 0) {
        assertErr(err);
        return false;
    }
    p.alive = true;
    debug.enable(ctx);
    return true;
}

pub export fn gst_gl_context_destroy(ctx: OCtx) void {
    const fname = "gst_gl_context_destroy";
    if (!valid(ctx, fname)) return;
    const cc = klass(ctx);
    if (!check.that(cc.destroy_context != null, fname, "context_class->destroy_context != NULL")) return;
    cc.destroy_context.?(ctx);
}

pub export fn gst_gl_context_fill_info(ctx: OCtx, err: [*c][*c]c.GError) c.gboolean {
    const fname = "gst_gl_context_fill_info";
    if (!valid(ctx, fname)) return 0;
    const p = pv(ctx);
    if (!check.that(p.active_thread == c.g_thread_self(), fname, "context->priv->active_thread == g_thread_self ()")) return 0;
    const gl = ctx[0].gl_vtable;
    const api = gst_gl_context_get_gl_api(ctx);
    gl[0].GetError = @ptrCast(gst_gl_context_get_proc_address(ctx, "glGetError"));
    gl[0].GetString = @ptrCast(gst_gl_context_get_proc_address(ctx, "glGetString"));
    gl[0].GetStringi = @ptrCast(gst_gl_context_get_proc_address(ctx, "glGetStringi"));
    gl[0].GetIntegerv = @ptrCast(gst_gl_context_get_proc_address(ctx, "glGetIntegerv"));
    if (gl[0].GetError == null or gl[0].GetString == null) {
        setError(err, c.GST_GL_CONTEXT_ERROR_FAILED, "could not GetProcAddress core opengl functions", .{});
        return 0;
    }
    if (!contextInfo(ctx, api, err)) {
        assertErr(err);
        return 0;
    }
    var exts: ?*c.GString = null;
    if (gl[0].GetIntegerv != null and gl[0].GetStringi != null and p.gl_major >= 3) exts = extString(ctx);
    if (exts != null and exts.?.len != 0) {
        feature.checkAll(ctx, exts.?.str);
        p.gl_exts = c.g_string_free(exts, 0);
    } else {
        if (exts) |s| _ = c.g_string_free(s, 1);
        var e: [*c]const u8 = @ptrCast(gl[0].GetString.?(c.GL_EXTENSIONS));
        if (e == null) e = "";
        feature.checkAll(ctx, e);
        p.gl_exts = c.g_strdup(e);
    }
    if (api & c.GST_GL_API_OPENGL3 != 0 and gst_gl_context_check_gl_version(ctx, c.GST_GL_API_OPENGL3, 4, 1) == 0 and feature.gst_gl_check_extension("GL_ARB_ES2_compatibility", p.gl_exts) == 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_FAILED, "An opengl3 context created but the required ES2 compatibility was not found", .{});
        return 0;
    }
    quirks.apply(ctx);
    if (isWrapped(ctx)) {
        const plat = gst_gl_context_get_gl_platform(ctx);
        if (plat == c.GST_GL_PLATFORM_GLX and !backends.glxFillInfo(ctx, err)) return 0;
        if (plat == c.GST_GL_PLATFORM_EGL and !backends.eglFillInfo(ctx, err)) return 0;
    }
    return 1;
}

pub export fn gst_gl_context_get_gl_context(ctx: OCtx) c.guintptr {
    const fname = "gst_gl_context_get_gl_context";
    if (!valid(ctx, fname)) return 0;
    const cc = klass(ctx);
    if (!check.that(cc.get_gl_context != null, fname, "context_class->get_gl_context != NULL")) return 0;
    return cc.get_gl_context.?(ctx);
}

pub export fn gst_gl_context_get_gl_platform(ctx: OCtx) c.GstGLPlatform {
    const fname = "gst_gl_context_get_gl_platform";
    if (!valid(ctx, fname)) return 0;
    const cc = klass(ctx);
    if (!check.that(cc.get_gl_platform != null, fname, "context_class->get_gl_platform != NULL")) return 0;
    return cc.get_gl_platform.?(ctx);
}

pub export fn gst_gl_context_get_display(ctx: OCtx) [*c]c.GstGLDisplay {
    if (!valid(ctx, "gst_gl_context_get_display")) return null;
    return @ptrCast(@alignCast(c.gst_object_ref(ctx[0].display)));
}

const Generic = struct {
    ctx: OCtx,
    func: c.GstGLContextThreadFunc,
    data: c.gpointer,
};

fn runGeneric(data: c.gpointer) callconv(.c) void {
    const g: *Generic = @ptrCast(@alignCast(data));
    g.func.?(g.ctx, g.data);
}

pub export fn gst_gl_context_thread_add(ctx: OCtx, func: c.GstGLContextThreadFunc, data: c.gpointer) void {
    const fname = "gst_gl_context_thread_add";
    if (!valid(ctx, fname)) return;
    if (!check.that(func != null, fname, "func != NULL")) return;
    const p = pv(ctx);
    if (isWrapped(ctx) and !check.that(p.active_thread == c.g_thread_self(), fname, "context->priv->active_thread == g_thread_self ()")) return;
    if (p.active_thread == c.g_thread_self()) {
        func.?(ctx, data);
        return;
    }
    var g = Generic{ .ctx = ctx, .func = func, .data = data };
    const w = gst_gl_context_get_window(ctx);
    c.gst_gl_window_send_message(w, runGeneric, &g);
    c.gst_object_unref(w);
}

pub export fn gst_gl_context_get_gl_version(ctx: OCtx, maj: [*c]c.gint, min: [*c]c.gint) void {
    const fname = "gst_gl_context_get_gl_version";
    if (!valid(ctx, fname)) return;
    if (!check.that(!(maj == null and min == null), fname, "!(maj == NULL && min == NULL)")) return;
    if (maj != null) maj[0] = pv(ctx).gl_major;
    if (min != null) min[0] = pv(ctx).gl_minor;
}

pub export fn gst_gl_context_check_gl_version(ctx: OCtx, api: c.GstGLAPI, maj: c.gint, min: c.gint) c.gboolean {
    if (!valid(ctx, "gst_gl_context_check_gl_version")) return 0;
    const p = pv(ctx);
    if (maj > p.gl_major) return 0;
    if (gst_gl_context_get_gl_api(ctx) & api == c.GST_GL_API_NONE) return 0;
    if (maj < p.gl_major) return 1;
    if (min > p.gl_minor) return 0;
    return 1;
}

pub export fn gst_gl_context_check_feature(ctx: OCtx, name: [*c]const u8) c.gboolean {
    const fname = "gst_gl_context_check_feature";
    if (!valid(ctx, fname)) return 0;
    if (!check.that(name != null, fname, "feature != NULL")) return 0;
    if (c.g_strstr_len(name, 3, "GL_") != null) return feature.gst_gl_check_extension(name, pv(ctx).gl_exts);
    const f = klass(ctx).check_feature orelse return 0;
    return f(ctx, name);
}

pub export fn gst_gl_context_get_current() OCtx {
    return @ptrCast(@alignCast(c.g_private_get(&current_key)));
}

pub export fn gst_gl_context_is_shared(ctx: OCtx) c.gboolean {
    const fname = "gst_gl_context_is_shared";
    if (!valid(ctx, fname)) return 0;
    const p = pv(ctx);
    const s = p.share orelse return 0;
    if (isWrapped(ctx)) {
        if (!check.that(p.active_thread != null, fname, "context->priv->active_thread")) return 0;
    } else {
        if (!check.that(p.alive, fname, "context->priv->alive")) return 0;
    }
    return @intFromBool(s.refs.load(.acquire) > 1);
}

pub export fn gst_gl_context_set_shared_with(ctx: OCtx, share: OCtx) void {
    const fname = "gst_gl_context_set_shared_with";
    if (!valid(ctx, fname)) return;
    if (!check.that(isContext(share), fname, "GST_IS_GL_CONTEXT (share)")) return;
    if (!check.that(gst_gl_context_is_shared(ctx) == 0, fname, "!gst_gl_context_is_shared (context)")) return;
    if (!check.that(isWrapped(ctx), fname, "GST_IS_GL_WRAPPED_CONTEXT (context)")) return;
    const p = pv(ctx);
    if (p.share) |s| shareUnref(s);
    p.share = shareRef(pv(share).share.?);
}

pub export fn gst_gl_context_get_gl_platform_version(ctx: OCtx, major: [*c]c.gint, minor: [*c]c.gint) void {
    const fname = "gst_gl_context_get_gl_platform_version";
    if (!valid(ctx, fname)) return;
    if (!check.that(major != null, fname, "major != NULL")) return;
    if (!check.that(minor != null, fname, "minor != NULL")) return;
    const cc = klass(ctx);
    if (!check.that(cc.get_gl_platform_version != null, fname, "context_class->get_gl_platform_version != NULL")) return;
    cc.get_gl_platform_version.?(ctx, major, minor);
}

pub export fn gst_gl_context_swap_buffers(ctx: OCtx) void {
    const fname = "gst_gl_context_swap_buffers";
    if (!valid(ctx, fname)) return;
    const cc = klass(ctx);
    if (!check.that(cc.swap_buffers != null, fname, "context_class->swap_buffers != NULL")) return;
    cc.swap_buffers.?(ctx);
}

pub export fn gst_gl_context_get_config(ctx: OCtx) ?*c.GstStructure {
    if (!valid(ctx, "gst_gl_context_get_config")) return null;
    const f = klass(ctx).get_config orelse return null;
    return f(ctx);
}

pub export fn gst_gl_context_request_config(ctx: OCtx, cfg: ?*c.GstStructure) c.gboolean {
    const fname = "gst_gl_context_request_config";
    if (!valid(ctx, fname)) return 0;
    const p = pv(ctx);
    if (!check.that(!p.created, fname, "context->priv->created == FALSE")) return 0;
    const f = klass(ctx).request_config orelse {
        c.gst_structure_free(cfg);
        return 0;
    };
    const r = f(ctx, c.gst_structure_copy(cfg));
    if (r != 0) {
        if (p.requested) |old| c.gst_structure_free(old);
        p.requested = cfg;
    } else {
        c.gst_structure_free(cfg);
    }
    return r;
}

pub fn debugEnabled() bool {
    return c.gst_debug_category_get_threshold(gldebug_cat) >= c.GST_LEVEL_WARNING;
}

fn wrappedApi(ctx: OCtx) callconv(.c) c.GstGLAPI {
    return @as(*Wrapped, @ptrCast(@alignCast(ctx))).apis;
}

fn wrappedHandle(ctx: OCtx) callconv(.c) c.guintptr {
    return @as(*Wrapped, @ptrCast(@alignCast(ctx))).handle;
}

fn wrappedPlatform(ctx: OCtx) callconv(.c) c.GstGLPlatform {
    return @as(*Wrapped, @ptrCast(@alignCast(ctx))).platform;
}

fn wrappedActivate(ctx: OCtx, activate: c.gboolean) callconv(.c) c.gboolean {
    const p = pv(ctx);
    if (activate != 0) {
        const old = p.gl_thread;
        p.gl_thread = c.g_thread_ref(c.g_thread_self());
        if (old) |t| c.g_thread_unref(t);
    } else if (p.gl_thread) |t| {
        c.g_thread_unref(t);
        p.gl_thread = null;
    }
    return 1;
}

fn copyIfSet(data: c.gpointer, _: c.gpointer) callconv(.c) c.gpointer {
    if (data == null) return null;
    return c.gst_structure_copy(@ptrCast(@alignCast(data)));
}

fn wrappedConfig(ctx: OCtx) callconv(.c) ?*c.GstStructure {
    return @ptrCast(@alignCast(c.g_object_dup_data(@ptrCast(ctx), WRAPPED_CONFIG, copyIfSet, null)));
}

fn wrappedClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const cc: *CtxClass = @ptrCast(@alignCast(k));
    cc.get_gl_context = wrappedHandle;
    cc.get_gl_api = wrappedApi;
    cc.get_gl_platform = wrappedPlatform;
    cc.activate = wrappedActivate;
    cc.get_config = wrappedConfig;
}

fn wrappedType() c.GType {
    return wrapped_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_gl_context_get_type, "GstGLWrappedContext", CtxClass, Wrapped, wrappedClassInit, null, 0);
        }
    }.f);
}
