const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const context = @import("../context.zig");
const config = @import("../config.zig");
const feature = @import("../feature.zig");
const xwindow = @import("window.zig");

const OCtx = [*c]c.GstGLContext;
const CreateAttribs = *const fn (?*c.Display, c.GLXFBConfig, c.GLXContext, c.Bool, [*c]const c_int) callconv(.c) c.GLXContext;

const Priv = struct {
    glx_major: c_int,
    glx_minor: c_int,
    api: c.GstGLAPI,
    fbconfigs: [*c]c.GLXFBConfig,
    create_attribs: ?CreateAttribs,
    requested: ?*c.GstStructure,
};

pub const Glx = extern struct {
    parent: c.GstGLContext,
    glx_context: c.GLXContext,
    priv: ?*anyopaque,
};

const OPENGL_VERSIONS = [_][2]c.gint{ .{ 4, 5 }, .{ 4, 4 }, .{ 4, 3 }, .{ 4, 2 }, .{ 4, 1 }, .{ 4, 0 }, .{ 3, 3 }, .{ 3, 2 }, .{ 3, 1 }, .{ 3, 0 }, .{ 2, 1 }, .{ 2, 0 }, .{ 1, 5 }, .{ 1, 4 }, .{ 1, 3 }, .{ 1, 2 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;

fn glx(p: anytype) *Glx {
    return @ptrCast(@alignCast(p));
}

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(glx(p).priv));
}

fn setError(e: [*c][*c]c.GError, code: c.gint, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, c.g_set_error, .{ e, context.gst_gl_context_error_quark(), code, fmt } ++ args);
}

fn drawable(v: c_int) c.GstGLConfigSurfaceType {
    var r: c.GstGLConfigSurfaceType = c.GST_GL_CONFIG_SURFACE_TYPE_NONE;
    if (v & c.GLX_WINDOW_BIT != 0) r |= c.GST_GL_CONFIG_SURFACE_TYPE_WINDOW;
    if (v & c.GLX_PIXMAP_BIT != 0) r |= c.GST_GL_CONFIG_SURFACE_TYPE_PIXMAP;
    if (v & c.GLX_PBUFFER_BIT != 0) r |= c.GST_GL_CONFIG_SURFACE_TYPE_PBUFFER;
    return r;
}

fn caveat(v: c_int) c.GstGLConfigCaveat {
    return switch (v) {
        c.GLX_NONE => c.GST_GL_CONFIG_CAVEAT_NONE,
        c.GLX_SLOW_CONFIG => c.GST_GL_CONFIG_CAVEAT_SLOW,
        else => c.GST_GL_CONFIG_CAVEAT_NON_CONFORMANT,
    };
}

fn attr(dpy: ?*c.Display, fb: c.GLXFBConfig, a: c_int) ?c_int {
    var v: c_int = 0;
    if (c.glXGetFBConfigAttrib(dpy, fb, a, &v) != c.Success) return null;
    return v;
}

fn configToStructure(dpy: ?*c.Display, fb: c.GLXFBConfig) ?*c.GstStructure {
    const z = @as([*c]const u8, null);
    const s = c.gst_structure_new("gst-gl-context-config", config.name("PLATFORM"), c.gst_gl_platform_get_type(), @as(c.guint, c.GST_GL_PLATFORM_GLX), "platform-sub-type", c.G_TYPE_STRING, "fbconfig", z);
    ok: {
        c.gst_structure_set(s, config.name("CONFIG_ID"), c.G_TYPE_UINT, attr(dpy, fb, c.GLX_FBCONFIG_ID) orelse break :ok, z);
        c.gst_structure_set(s, config.name("NATIVE_VISUAL_ID"), c.G_TYPE_UINT, attr(dpy, fb, c.GLX_VISUAL_ID) orelse break :ok, z);
        c.gst_structure_set(s, config.name("CAVEAT"), c.gst_gl_config_caveat_get_type(), @as(c_uint, caveat(attr(dpy, fb, c.GLX_CONFIG_CAVEAT) orelse break :ok)), z);
        c.gst_structure_set(s, config.name("SURFACE_TYPE"), c.gst_gl_config_surface_type_get_type(), @as(c_uint, drawable(attr(dpy, fb, c.GLX_DRAWABLE_TYPE) orelse break :ok)), z);
        c.gst_structure_set(s, config.name("NATIVE_RENDERABLE"), c.G_TYPE_BOOLEAN, attr(dpy, fb, c.GLX_X_RENDERABLE) orelse break :ok, z);
        c.gst_structure_set(s, config.name("LEVEL"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_LEVEL) orelse break :ok, z);
        const rt = attr(dpy, fb, c.GLX_RENDER_TYPE) orelse break :ok;
        if (rt & c.GLX_RGBA_BIT != 0) {
            c.gst_structure_set(s, config.name("RED_SIZE"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_RED_SIZE) orelse break :ok, z);
            c.gst_structure_set(s, config.name("GREEN_SIZE"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_GREEN_SIZE) orelse break :ok, z);
            c.gst_structure_set(s, config.name("BLUE_SIZE"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_BLUE_SIZE) orelse break :ok, z);
            c.gst_structure_set(s, config.name("ALPHA_SIZE"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_ALPHA_SIZE) orelse break :ok, z);
        }
        c.gst_structure_set(s, config.name("DEPTH_SIZE"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_DEPTH_SIZE) orelse break :ok, z);
        c.gst_structure_set(s, config.name("STENCIL_SIZE"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_STENCIL_SIZE) orelse break :ok, z);
        c.gst_structure_set(s, config.name("MAX_PBUFFER_WIDTH"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_MAX_PBUFFER_WIDTH) orelse break :ok, z);
        c.gst_structure_set(s, config.name("MAX_PBUFFER_HEIGHT"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_MAX_PBUFFER_HEIGHT) orelse break :ok, z);
        c.gst_structure_set(s, config.name("MAX_PBUFFER_PIXELS"), c.G_TYPE_INT, attr(dpy, fb, c.GLX_MAX_PBUFFER_PIXELS) orelse break :ok, z);
        return s;
    }
    c.gst_structure_free(s);
    return null;
}

fn fbAttributes(cfg: ?*c.GstStructure) [*c]c_int {
    const s = cfg orelse {
        const def = [_]c_int{ c.GLX_RENDER_TYPE, c.GLX_RGBA_BIT, c.GLX_RED_SIZE, 1, c.GLX_GREEN_SIZE, 1, c.GLX_BLUE_SIZE, 1, c.GLX_DEPTH_SIZE, 16, c.GLX_DOUBLEBUFFER, c.True, c.None };
        return @ptrCast(@alignCast(c.g_memdup2(&def, @sizeOf(@TypeOf(def)))));
    };
    const n: usize = @as(usize, @intCast(c.gst_structure_n_fields(s))) * 2 + 1;
    const r: [*c]c_int = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c_int) * n)));
    var i: usize = 0;
    const pairs = .{
        .{ "CONFIG_ID", c.GLX_FBCONFIG_ID, c.G_TYPE_UINT },
        .{ "RED_SIZE", c.GLX_RED_SIZE, c.G_TYPE_INT },
        .{ "GREEN_SIZE", c.GLX_GREEN_SIZE, c.G_TYPE_INT },
        .{ "BLUE_SIZE", c.GLX_BLUE_SIZE, c.G_TYPE_INT },
        .{ "ALPHA_SIZE", c.GLX_ALPHA_SIZE, c.G_TYPE_INT },
        .{ "DEPTH_SIZE", c.GLX_DEPTH_SIZE, c.G_TYPE_INT },
        .{ "STENCIL_SIZE", c.GLX_STENCIL_SIZE, c.G_TYPE_INT },
    };
    inline for (pairs) |p| {
        const nm = config.name(p[0]);
        if (c.gst_structure_has_field_typed(s, nm, p[2]) != 0) {
            var v: c_int = 0;
            if (c.gst_structure_get(s, nm, @as(c.GType, p[2]), &v, @as([*c]const u8, null)) != 0) {
                r[i] = p[1];
                r[i + 1] = v;
                i += 2;
            }
        }
    }
    r[i] = c.None;
    return r;
}

fn createWithFlags(g: *Glx, dpy: ?*c.Display, fb: c.GLXFBConfig, share: c.GLXContext, major: c_int, minor: c_int, flags: c_int, profile: c_int) c.GLXContext {
    var a: [20]c_int = undefined;
    var n: usize = 0;
    if (major != 0) {
        a[n] = c.GLX_CONTEXT_MAJOR_VERSION_ARB;
        a[n + 1] = major;
        n += 2;
    }
    if (minor != 0) {
        a[n] = c.GLX_CONTEXT_MINOR_VERSION_ARB;
        a[n + 1] = minor;
        n += 2;
    }
    if (flags != 0) {
        a[n] = c.GLX_CONTEXT_FLAGS_ARB;
        a[n + 1] = flags;
        n += 2;
    }
    if (profile != 0) {
        a[n] = c.GLX_CONTEXT_PROFILE_MASK_ARB;
        a[n + 1] = profile;
        n += 2;
    }
    a[n] = c.None;
    xwindow.trap();
    const r = pv(g).create_attribs.?(dpy, fb, share, c.True, &a);
    if (xwindow.untrap() != 0) return null;
    return r;
}

fn createContext(ctx: OCtx, api: c.GstGLAPI, other: OCtx, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const g = glx(ctx);
    const p = pv(ctx);
    const w = context.gst_gl_context_get_window(ctx);
    defer if (w != null) c.gst_object_unref(w);
    if (!xwindow.isX11(w)) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Cannot create an GLX context from a non-X11 window", .{});
        return 0;
    }
    const wx: *xwindow.Win = @ptrCast(@alignCast(w));
    const d = context.gst_gl_context_get_display(ctx);
    defer c.gst_object_unref(d);
    var share: c.GLXContext = null;
    if (other != null) {
        if (context.gst_gl_context_get_gl_platform(other) != c.GST_GL_PLATFORM_GLX) {
            setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Cannot share context with non-GLX context", .{});
            return 0;
        }
        share = @ptrFromInt(context.gst_gl_context_get_gl_context(other));
    }
    const dpy: ?*c.Display = @ptrFromInt(c.gst_gl_display_get_handle(d));
    if (dpy == null) {
        setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "Invalid Display handle", .{});
        return 0;
    }
    const exts = c.glXQueryExtensionsString(dpy, c.XDefaultScreen(dpy));
    const create = feature.gst_gl_check_extension("GLX_ARB_create_context", exts) != 0;
    p.create_attribs = @ptrCast(c.glXGetProcAddressARB("glXCreateContextAttribsARB"));
    if (g.glx_context == null and api & c.GST_GL_API_OPENGL3 != 0 and create and p.create_attribs != null) {
        for (OPENGL_VERSIONS) |v| {
            if (!(v[0] > 3 or (v[0] == 3 and v[1] >= 2))) break;
            g.glx_context = createWithFlags(g, dpy, p.fbconfigs[0], share, v[0], v[1], c.GLX_CONTEXT_DEBUG_BIT_ARB, c.GLX_CONTEXT_CORE_PROFILE_BIT_ARB);
            if (g.glx_context != null) {
                p.api = c.GST_GL_API_OPENGL3;
                break;
            }
        }
    }
    if (g.glx_context == null and api & c.GST_GL_API_OPENGL != 0) {
        g.glx_context = c.glXCreateContext(dpy, wx.visual_info, share, c.True);
        p.api = c.GST_GL_API_OPENGL;
    }
    if (g.glx_context == null) {
        setError(err, c.GST_GL_CONTEXT_ERROR_CREATE_CONTEXT, "Failed to create opengl context", .{});
        return 0;
    }
    return 1;
}

fn destroyContext(ctx: OCtx) callconv(.c) void {
    const g = glx(ctx);
    const p = pv(ctx);
    const w = context.gst_gl_context_get_window(ctx);
    const dpy: ?*c.Display = @ptrFromInt(c.gst_gl_display_get_handle(w[0].display));
    if (p.fbconfigs != null) _ = c.XFree(@ptrCast(p.fbconfigs));
    p.fbconfigs = null;
    c.glXDestroyContext(dpy, g.glx_context);
    g.glx_context = null;
    if (p.requested) |r| c.gst_structure_free(r);
    p.requested = null;
    c.gst_object_unref(w);
}

fn chooseFormat(ctx: OCtx, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const p = pv(ctx);
    const w = context.gst_gl_context_get_window(ctx);
    defer if (w != null) c.gst_object_unref(w);
    if (!xwindow.isX11(w)) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Cannot create an GLX context from a non-X11 window", .{});
        return 0;
    }
    const wx: *xwindow.Win = @ptrCast(@alignCast(w));
    const dpy: ?*c.Display = @ptrFromInt(c.gst_gl_display_get_handle(w[0].display));
    if (dpy == null) {
        setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "Invalid Display handle", .{});
        return 0;
    }
    var eb: c_int = 0;
    var evb: c_int = 0;
    if (c.glXQueryExtension(dpy, &eb, &evb) == 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "No GLX extension", .{});
        return 0;
    }
    if (c.glXQueryVersion(dpy, &p.glx_major, &p.glx_minor) == 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_CREATE_CONTEXT, "Failed to query GLX version (glXQueryVersion failed)", .{});
        return 0;
    }
    if (p.glx_major < 1 or (p.glx_major == 1 and p.glx_minor < 3)) {
        var a = [_]c_int{ c.GLX_RGBA, c.GLX_RED_SIZE, 1, c.GLX_GREEN_SIZE, 1, c.GLX_BLUE_SIZE, 1, c.GLX_DEPTH_SIZE, 16, c.GLX_DOUBLEBUFFER, c.None };
        wx.visual_info = c.glXChooseVisual(dpy, wx.screen_num, &a);
        if (wx.visual_info == null) {
            setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Bad attributes in glXChooseVisual", .{});
            return 0;
        }
    } else {
        var n: c_int = 0;
        const a = fbAttributes(p.requested);
        p.fbconfigs = c.glXChooseFBConfig(dpy, c.XDefaultScreen(dpy), a, &n);
        c.g_free(a);
        if (p.fbconfigs == null) {
            setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Could not find any FBConfig's to use (check attributes?)", .{});
            return 0;
        }
        wx.visual_info = c.glXGetVisualFromFBConfig(dpy, p.fbconfigs[0]);
        if (wx.visual_info == null) {
            setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Bad attributes in FBConfig", .{});
            return 0;
        }
    }
    _ = xwindow.createWindow(w);
    return 1;
}

fn swap(ctx: OCtx) callconv(.c) void {
    const w = context.gst_gl_context_get_window(ctx);
    c.glXSwapBuffers(@ptrFromInt(c.gst_gl_display_get_handle(w[0].display)), c.gst_gl_window_get_window_handle(w));
    c.gst_object_unref(w);
}

fn glContext(ctx: OCtx) callconv(.c) c.guintptr {
    return @intFromPtr(glx(ctx).glx_context);
}

fn activate(ctx: OCtx, on: c.gboolean) callconv(.c) c.gboolean {
    const w = context.gst_gl_context_get_window(ctx);
    defer c.gst_object_unref(w);
    const dpy: ?*c.Display = @ptrFromInt(c.gst_gl_display_get_handle(w[0].display));
    if (on != 0) return c.glXMakeCurrent(dpy, c.gst_gl_window_get_window_handle(w), glx(ctx).glx_context);
    return c.glXMakeCurrent(dpy, c.None, null);
}

fn glApi(ctx: OCtx) callconv(.c) c.GstGLAPI {
    return pv(ctx).api;
}

fn glPlatform(_: OCtx) callconv(.c) c.GstGLPlatform {
    return c.GST_GL_PLATFORM_GLX;
}

pub fn procAddress(api: c.GstGLAPI, name: [*c]const u8) callconv(.c) c.gpointer {
    const r = context.gst_gl_context_default_get_proc_address(api, name);
    if (r != null) return r;
    return @ptrCast(@constCast(c.glXGetProcAddressARB(name)));
}

pub fn currentContext() callconv(.c) c.guintptr {
    return @intFromPtr(c.glXGetCurrentContext());
}

fn platformVersion(ctx: OCtx, major: [*c]c.gint, minor: [*c]c.gint) callconv(.c) void {
    major[0] = pv(ctx).glx_major;
    minor[0] = pv(ctx).glx_minor;
}

fn getConfig(ctx: OCtx) callconv(.c) ?*c.GstStructure {
    const p = pv(ctx);
    const w = context.gst_gl_context_get_window(ctx);
    defer c.gst_object_unref(w);
    const wx: *xwindow.Win = @ptrCast(@alignCast(w));
    if (!check.that(p.fbconfigs != null or wx.visual_info != null, "gst_gl_context_glx_get_config", "glx->priv->fbconfigs || window_x11->visual_info")) return null;
    if (p.fbconfigs == null) return null;
    return configToStructure(@ptrFromInt(c.gst_gl_display_get_handle(w[0].display)), p.fbconfigs[0]);
}

fn requestConfig(ctx: OCtx, cfg: ?*c.GstStructure) callconv(.c) c.gboolean {
    const p = pv(ctx);
    if (p.requested) |r| c.gst_structure_free(r);
    p.requested = cfg;
    return 1;
}

pub fn fillInfo(ctx: *c.GstGLContext, err: [*c][*c]c.GError) bool {
    const gc: c.GLXContext = @ptrFromInt(context.gst_gl_context_get_gl_context(ctx));
    if (gc == null) {
        setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "No GLX context", .{});
        return false;
    }
    const dpy: ?*c.Display = @ptrFromInt(c.gst_gl_display_get_handle(ctx.display));
    var maj: c_int = 0;
    var min: c_int = 0;
    if (c.glXQueryVersion(dpy, &maj, &min) == 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "could not retrieve GLX version", .{});
        return false;
    }
    if (!(maj > 1 or (maj == 1 and min >= 4))) return true;
    var id: c_int = 0;
    if (c.glXQueryContext(dpy, gc, c.GLX_FBCONFIG_ID, &id) != c.Success) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "could not retrieve fbconfig id from glx context", .{});
        return false;
    }
    var a = [_]c_int{ c.GLX_FBCONFIG_ID, id, c.None };
    var n: c_int = 0;
    const fbs = c.glXChooseFBConfig(dpy, c.XDefaultScreen(dpy), &a, &n);
    if (fbs == null or n <= 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "could not retrieve fbconfig from its ID 0x%x. Wrong Display or Screen?", .{id});
        return false;
    }
    const s = configToStructure(dpy, fbs[0]) orelse {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "could not transform fbconfig id 0x%x into GstStructure.", .{id});
        return false;
    };
    c.g_object_set_data_full(@ptrCast(ctx), "gst.gl.context.wrapped.config", s, @ptrCast(&c.gst_structure_free));
    _ = c.XFree(@ptrCast(fbs));
    return true;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const cc: *c.GstGLContextClass = @ptrCast(@alignCast(k));
    cc.get_gl_context = glContext;
    cc.activate = activate;
    cc.create_context = createContext;
    cc.destroy_context = destroyContext;
    cc.choose_format = chooseFormat;
    cc.swap_buffers = swap;
    cc.get_gl_api = glApi;
    cc.get_gl_platform = glPlatform;
    cc.get_proc_address = procAddress;
    cc.get_current_context = currentContext;
    cc.get_gl_platform_version = platformVersion;
    cc.get_config = getConfig;
    cc.request_config = requestConfig;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const g = glx(inst);
    g.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(g).* = std.mem.zeroes(Priv);
}

pub fn typeGet() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(context.gst_gl_context_get_type, "GstGLContextGLX", c.GstGLContextClass, Glx, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            return t;
        }
    }.f);
}

pub fn new(d: [*c]c.GstGLDisplay) ?*c.GstGLContext {
    if (c.gst_gl_display_get_handle_type(d) & c.GST_GL_DISPLAY_TYPE_X11 == 0) return null;
    const o = c.g_object_new(typeGet(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    return @ptrCast(@alignCast(o));
}
