const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const feature = @import("../feature.zig");
const context = @import("../context.zig");
const config = @import("../config.zig");
const edisplay = @import("display.zig");
const err_str = @import("error.zig").gst_egl_get_error_string;
const backends = @import("../backends.zig");

const OCtx = [*c]c.GstGLContext;

pub const Modifier = extern struct {
    modifier: u64,
    external_only: c.gboolean,
};

const DmaFormat = extern struct {
    fourcc: c.gint,
    modifiers: ?*c.GArray,
};

pub const Egl = extern struct {
    context: c.GstGLContext,
    display_egl: ?*c.GstGLDisplayEGL,
    egl_context: c.EGLContext,
    egl_display: c.EGLDisplay,
    egl_surface: c.EGLSurface,
    egl_config: c.EGLConfig,
    egl_major: c.gint,
    egl_minor: c.gint,
    gl_api: c.GstGLAPI,
    egl_exts: [*c]const u8,
    window_handle: c.guintptr,
    window_handle_signal: c.gulong,
    requested_config: ?*c.GstStructure,
    dma_formats: ?*c.GArray,
};

const OPENGL_VERSIONS = [_][2]c.gint{ .{ 4, 5 }, .{ 4, 4 }, .{ 4, 3 }, .{ 4, 2 }, .{ 4, 1 }, .{ 4, 0 }, .{ 3, 3 }, .{ 3, 2 }, .{ 3, 1 }, .{ 3, 0 }, .{ 2, 1 }, .{ 2, 0 }, .{ 1, 5 }, .{ 1, 4 }, .{ 1, 3 }, .{ 1, 2 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
const GLES2_VERSIONS = [_][2]c.gint{ .{ 3, 2 }, .{ 3, 1 }, .{ 3, 0 }, .{ 2, 0 }, .{ 0, 0 } };

const ES3_BIT = 0x40;
const KHR_MAJOR = 0x3098;
const KHR_MINOR = 0x30FB;
const KHR_FLAGS = 0x30FC;
const KHR_PROFILE = 0x30FD;
const KHR_DEBUG_BIT = 0x1;
const KHR_CORE_BIT = 0x1;

var once: gtype.Once = .{};

fn egl(p: anytype) *Egl {
    return @ptrCast(@alignCast(p));
}

pub fn isEgl(p: anytype) bool {
    return gtype.instanceOf(p, typeGet());
}

fn checkGl(maj: c.gint, min: c.gint, rmaj: c.gint, rmin: c.gint) bool {
    return maj > rmaj or (maj == rmaj and min >= rmin);
}

fn has(name: [*:0]const u8, exts: [*c]const u8) bool {
    return feature.gst_gl_check_extension(name, exts) != 0;
}

fn setError(e: [*c][*c]c.GError, code: c.gint, comptime fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, c.g_set_error, .{ e, context.gst_gl_context_error_quark(), code, fmt } ++ args);
}

fn conformant(v: c.EGLint) c.GstGLAPI {
    var r: c.GstGLAPI = c.GST_GL_API_NONE;
    if (v & c.EGL_OPENGL_BIT != 0) r |= c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3;
    if (v & c.EGL_OPENGL_ES_BIT != 0) r |= c.GST_GL_API_GLES1;
    if (v & c.EGL_OPENGL_ES2_BIT != 0) r |= c.GST_GL_API_GLES2;
    if (v & ES3_BIT != 0) r |= c.GST_GL_API_GLES2;
    return r;
}

fn surfaceType(v: c.EGLint) c.GstGLConfigSurfaceType {
    var r: c.GstGLConfigSurfaceType = c.GST_GL_CONFIG_SURFACE_TYPE_NONE;
    if (v & c.EGL_WINDOW_BIT != 0) r |= c.GST_GL_CONFIG_SURFACE_TYPE_WINDOW;
    if (v & c.EGL_PBUFFER_BIT != 0) r |= c.GST_GL_CONFIG_SURFACE_TYPE_PBUFFER;
    return r;
}

fn caveat(v: c.EGLint) c.GstGLConfigCaveat {
    return switch (v) {
        c.EGL_NONE => c.GST_GL_CONFIG_CAVEAT_NONE,
        c.EGL_SLOW_CONFIG => c.GST_GL_CONFIG_CAVEAT_SLOW,
        else => c.GST_GL_CONFIG_CAVEAT_NON_CONFORMANT,
    };
}

const Attr = struct { attr: c.EGLint, name: []const u8, kind: enum { int, uint, boolean, api, surface, caveat } };

fn configToStructure(dpy: c.EGLDisplay, cfg: c.EGLConfig) ?*c.GstStructure {
    if (dpy == null) return null;
    const s = c.gst_structure_new("gst-gl-context-config", config.name("PLATFORM"), c.gst_gl_platform_get_type(), @as(c.guint, c.GST_GL_PLATFORM_EGL), @as([*c]const u8, null));
    var val: c.EGLint = 0;
    const head = [_]Attr{
        .{ .attr = c.EGL_CONFIG_ID, .name = "CONFIG_ID", .kind = .uint },
        .{ .attr = c.EGL_NATIVE_VISUAL_ID, .name = "NATIVE_VISUAL_ID", .kind = .uint },
        .{ .attr = c.EGL_NATIVE_RENDERABLE, .name = "NATIVE_RENDERABLE", .kind = .boolean },
        .{ .attr = c.EGL_CONFORMANT, .name = "CONFORMANT_API", .kind = .api },
        .{ .attr = c.EGL_RENDERABLE_TYPE, .name = "RENDERABLE_API", .kind = .api },
        .{ .attr = c.EGL_SURFACE_TYPE, .name = "SURFACE_TYPE", .kind = .surface },
        .{ .attr = c.EGL_CONFIG_CAVEAT, .name = "CAVEAT", .kind = .caveat },
        .{ .attr = c.EGL_LEVEL, .name = "LEVEL", .kind = .int },
    };
    inline for (head) |a| {
        if (!put(s, dpy, cfg, a)) return fail(s);
    }
    var buffer: c.EGLint = 0;
    if (c.eglGetConfigAttrib(dpy, cfg, c.EGL_COLOR_BUFFER_TYPE, &buffer) == 0) return fail(s);
    if (buffer == c.EGL_RGB_BUFFER) {
        const rgb = [_]Attr{
            .{ .attr = c.EGL_RED_SIZE, .name = "RED_SIZE", .kind = .int },
            .{ .attr = c.EGL_GREEN_SIZE, .name = "GREEN_SIZE", .kind = .int },
            .{ .attr = c.EGL_BLUE_SIZE, .name = "BLUE_SIZE", .kind = .int },
            .{ .attr = c.EGL_ALPHA_SIZE, .name = "ALPHA_SIZE", .kind = .int },
        };
        inline for (rgb) |a| {
            if (!put(s, dpy, cfg, a)) return fail(s);
        }
    } else if (buffer == c.EGL_LUMINANCE_BUFFER) {
        const lum = [_]Attr{
            .{ .attr = c.EGL_LUMINANCE_SIZE, .name = "LUMINANCE_SIZE", .kind = .int },
            .{ .attr = c.EGL_ALPHA_SIZE, .name = "ALPHA_SIZE", .kind = .int },
        };
        inline for (lum) |a| {
            if (!put(s, dpy, cfg, a)) return fail(s);
        }
    } else return fail(s);
    const tail = [_]Attr{
        .{ .attr = c.EGL_DEPTH_SIZE, .name = "DEPTH_SIZE", .kind = .int },
        .{ .attr = c.EGL_STENCIL_SIZE, .name = "STENCIL_SIZE", .kind = .int },
        .{ .attr = c.EGL_MIN_SWAP_INTERVAL, .name = "MIN_SWAP_INTERVAL", .kind = .int },
        .{ .attr = c.EGL_MAX_SWAP_INTERVAL, .name = "MAX_SWAP_INTERVAL", .kind = .int },
        .{ .attr = c.EGL_MAX_PBUFFER_WIDTH, .name = "MAX_PBUFFER_WIDTH", .kind = .int },
        .{ .attr = c.EGL_MAX_PBUFFER_HEIGHT, .name = "MAX_PBUFFER_HEIGHT", .kind = .int },
        .{ .attr = c.EGL_MAX_PBUFFER_PIXELS, .name = "MAX_PBUFFER_PIXELS", .kind = .int },
        .{ .attr = c.EGL_SAMPLE_BUFFERS, .name = "SAMPLE_BUFFERS", .kind = .int },
        .{ .attr = c.EGL_SAMPLES, .name = "SAMPLES", .kind = .int },
    };
    inline for (tail) |a| {
        if (!put(s, dpy, cfg, a)) return fail(s);
    }
    _ = &val;
    return s;
}

fn fail(s: ?*c.GstStructure) ?*c.GstStructure {
    c.gst_structure_free(s);
    return null;
}

fn put(s: ?*c.GstStructure, dpy: c.EGLDisplay, cfg: c.EGLConfig, comptime a: Attr) bool {
    var v: c.EGLint = 0;
    if (c.eglGetConfigAttrib(dpy, cfg, a.attr, &v) == 0) return false;
    const n = config.name(a.name);
    const z = @as([*c]const u8, null);
    switch (a.kind) {
        .int => c.gst_structure_set(s, n, c.G_TYPE_INT, @as(c_int, v), z),
        .uint => c.gst_structure_set(s, n, c.G_TYPE_UINT, @as(c_uint, @bitCast(v)), z),
        .boolean => c.gst_structure_set(s, n, c.G_TYPE_BOOLEAN, @as(c_int, v), z),
        .api => c.gst_structure_set(s, n, c.gst_gl_api_get_type(), @as(c_uint, conformant(v)), z),
        .surface => c.gst_structure_set(s, n, c.gst_gl_config_surface_type_get_type(), @as(c_uint, surfaceType(v)), z),
        .caveat => c.gst_structure_set(s, n, c.gst_gl_config_caveat_get_type(), @as(c_uint, caveat(v)), z),
    }
    return true;
}

fn chooseConfig(e: *Egl, api: c.GstGLAPI, major: c.gint, err: [*c][*c]c.GError) bool {
    var surface: c.EGLint = c.EGL_WINDOW_BIT;
    var alpha: c.EGLint = 1;
    const w = context.gst_gl_context_get_window(&e.context);
    if (w == null or c.gst_gl_window_has_output_surface(w) == 0) surface = c.EGL_PBUFFER_BIT;
    if (w != null) c.gst_object_unref(w);
    const create = has("EGL_KHR_create_context", e.egl_exts);
    var egl_api: c.EGLint = c.EGL_OPENGL_BIT;
    if (api & c.GST_GL_API_GLES2 != 0) {
        if (major == 3) {
            if (!create) return false;
            egl_api = ES3_BIT;
        } else egl_api = c.EGL_OPENGL_ES2_BIT;
    }
    var n: c.EGLint = 0;
    var ok: c.EGLBoolean = 0;
    while (true) {
        var attrs: [20]c.EGLint = undefined;
        var i: usize = 0;
        attrs[i] = c.EGL_SURFACE_TYPE;
        attrs[i + 1] = surface;
        attrs[i + 2] = c.EGL_RENDERABLE_TYPE;
        attrs[i + 3] = egl_api;
        i += 4;
        if (e.requested_config) |rc| {
            const pairs = .{
                .{ "CONFIG_ID", c.EGL_CONFIG_ID, c.G_TYPE_UINT },
                .{ "RED_SIZE", c.EGL_RED_SIZE, c.G_TYPE_INT },
                .{ "GREEN_SIZE", c.EGL_GREEN_SIZE, c.G_TYPE_INT },
                .{ "BLUE_SIZE", c.EGL_BLUE_SIZE, c.G_TYPE_INT },
                .{ "ALPHA_SIZE", c.EGL_ALPHA_SIZE, c.G_TYPE_INT },
                .{ "DEPTH_SIZE", c.EGL_DEPTH_SIZE, c.G_TYPE_INT },
                .{ "STENCIL_SIZE", c.EGL_STENCIL_SIZE, c.G_TYPE_INT },
            };
            inline for (pairs) |p| {
                const n2 = config.name(p[0]);
                if (c.gst_structure_has_field_typed(rc, n2, p[2]) != 0) {
                    var v: c_int = 0;
                    if (c.gst_structure_get(rc, n2, @as(c.GType, p[2]), &v, @as([*c]const u8, null)) != 0) {
                        attrs[i] = p[1];
                        attrs[i + 1] = v;
                        i += 2;
                    }
                }
            }
        } else {
            const defaults = [_]c.EGLint{ c.EGL_DEPTH_SIZE, 16, c.EGL_RED_SIZE, 1, c.EGL_GREEN_SIZE, 1, c.EGL_BLUE_SIZE, 1, c.EGL_ALPHA_SIZE, alpha };
            @memcpy(attrs[i .. i + defaults.len], &defaults);
            i += defaults.len;
        }
        attrs[i] = c.EGL_NONE;
        ok = c.eglChooseConfig(e.egl_display, &attrs, &e.egl_config, 1, &n);
        if (ok != 0 and n == 0) {
            if (surface == c.EGL_PBUFFER_BIT) {
                surface = c.EGL_WINDOW_BIT;
                continue;
            }
            if (alpha == 1) {
                alpha = 0;
                continue;
            }
        }
        break;
    }
    if (ok != 0 and n == 1) return true;
    if (ok == 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Failed to choose EGLConfig: %s", .{err_str(c.eglGetError())});
    } else {
        c.g_set_error_literal(err, context.gst_gl_context_error_quark(), c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Could not find a compatible EGLConfig:");
    }
    return false;
}

fn createWithFlags(e: *Egl, share: c.EGLContext, api: c.GstGLAPI, major: c.gint, minor: c.gint, flags: c.gint, profile: c.gint) c.EGLContext {
    const create = has("EGL_KHR_create_context", e.egl_exts);
    if (!create and (profile != 0 or flags != 0 or (api & c.GST_GL_API_OPENGL3 != 0 and checkGl(major, minor, 3, 2)) or (api & c.GST_GL_API_GLES2 != 0 and minor > 0))) return null;
    var attrs: [20]c.EGLint = undefined;
    var n: usize = 0;
    if (create) {
        if (major != 0) {
            attrs[n] = KHR_MAJOR;
            attrs[n + 1] = major;
            n += 2;
        }
        if (minor != 0) {
            attrs[n] = KHR_MINOR;
            attrs[n + 1] = minor;
            n += 2;
        }
        if (flags != 0) {
            attrs[n] = KHR_FLAGS;
            attrs[n + 1] = flags;
            n += 2;
        }
        if (profile != 0) {
            attrs[n] = KHR_PROFILE;
            attrs[n + 1] = profile;
            n += 2;
        }
    } else {
        attrs[n] = c.EGL_CONTEXT_CLIENT_VERSION;
        attrs[n + 1] = major;
        n += 2;
    }
    attrs[n] = c.EGL_NONE;
    return c.eglCreateContext(e.egl_display, e.egl_config, share, &attrs);
}

fn handleChanged(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    const e = egl(data);
    if (e.egl_surface != c.EGL_NO_SURFACE) {
        _ = c.eglDestroySurface(e.egl_display, e.egl_surface);
        e.egl_surface = c.EGL_NO_SURFACE;
    }
}

fn createContext(ctx: OCtx, api: c.GstGLAPI, other: OCtx, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const e = egl(ctx);
    const w = context.gst_gl_context_get_window(ctx);
    defer if (w != null) c.gst_object_unref(w);
    var share: c.EGLContext = null;
    if (other != null) {
        if (context.gst_gl_context_get_gl_platform(other) != c.GST_GL_PLATFORM_EGL) {
            setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Cannot share context with non-EGL context", .{});
            return 0;
        }
        share = @ptrFromInt(context.gst_gl_context_get_gl_context(other));
    }
    if (api & (c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2) == c.GST_GL_API_NONE) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_API, "EGL supports opengl or gles2", .{});
        return 0;
    }
    if (e.display_egl == null) {
        const d = context.gst_gl_context_get_display(ctx);
        e.display_egl = edisplay.gst_gl_display_egl_from_gl_display(d);
        c.gst_object_unref(d);
        if (e.display_egl == null) {
            setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "Failed to create EGLDisplay from native display", .{});
            return 0;
        }
    }
    e.egl_display = @ptrFromInt(c.gst_gl_display_get_handle(@ptrCast(e.display_egl)));
    var maj: c.EGLint = 0;
    var min: c.EGLint = 0;
    if (c.eglInitialize(e.egl_display, &maj, &min) == 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "Failed to initialize egl: %s", .{err_str(c.eglGetError())});
        return 0;
    }
    e.egl_exts = c.eglQueryString(e.egl_display, c.EGL_EXTENSIONS);
    var gles = api & c.GST_GL_API_GLES2 != 0;
    if (!gles) {
        if (maj == 1 and min <= 3) {
            if (api & ~@as(c.GstGLAPI, c.GST_GL_API_OPENGL) == c.GST_GL_API_NONE) {
                setError(err, c.GST_GL_CONTEXT_ERROR_OLD_LIBS, "EGL version (%i.%i) too old for OpenGL support, (needed at least 1.4)", .{ maj, min });
                return 0;
            }
            if (api & c.GST_GL_API_GLES2 != 0) {
                gles = true;
            } else {
                setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "Failed to choose a suitable OpenGL API", .{});
                return 0;
            }
        }
    }
    if (gles) {
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == 0) {
            setError(err, c.GST_GL_CONTEXT_ERROR_FAILED, "Failed to bind OpenGL|ES API: %s", .{err_str(c.eglGetError())});
            return 0;
        }
        for (GLES2_VERSIONS) |v| {
            if (!chooseConfig(e, c.GST_GL_API_GLES2, v[0], err)) {
                c.g_clear_error(err);
                continue;
            }
            e.egl_context = createWithFlags(e, share, c.GST_GL_API_GLES2, v[0], v[1], KHR_DEBUG_BIT, 0);
            if (e.egl_context != null) break;
            e.egl_context = createWithFlags(e, share, c.GST_GL_API_GLES2, v[0], v[1], 0, 0);
            if (e.egl_context != null) break;
        }
        e.gl_api = c.GST_GL_API_GLES2;
    } else {
        if (c.eglBindAPI(c.EGL_OPENGL_API) == 0) {
            setError(err, c.GST_GL_CONTEXT_ERROR_FAILED, "Failed to bind OpenGL API: %s", .{err_str(c.eglGetError())});
            return 0;
        }
        if (!chooseConfig(e, c.GST_GL_API_OPENGL, 0, err)) return 0;
        var chosen: c.GstGLAPI = 0;
        for (OPENGL_VERSIONS) |v| {
            var profile: c.gint = 0;
            var flags: c.gint = 0;
            if (checkGl(v[0], v[1], 3, 2)) {
                if (api & c.GST_GL_API_OPENGL3 == 0) continue;
                chosen = c.GST_GL_API_OPENGL3;
                profile |= KHR_CORE_BIT;
                flags |= KHR_DEBUG_BIT;
            } else if (v[0] == 3 and v[1] == 1) {
                continue;
            } else {
                if (api & c.GST_GL_API_OPENGL == 0) continue;
                chosen = c.GST_GL_API_OPENGL;
            }
            e.egl_context = createWithFlags(e, share, chosen, v[0], v[1], flags, profile);
            if (e.egl_context != null) break;
            profile &= ~@as(c.gint, KHR_DEBUG_BIT);
            e.egl_context = createWithFlags(e, share, chosen, v[0], v[1], flags, profile);
            if (e.egl_context != null) break;
        }
        e.gl_api = chosen;
    }
    if (e.egl_context == c.EGL_NO_CONTEXT) {
        setError(err, c.GST_GL_CONTEXT_ERROR_CREATE_CONTEXT, "Failed to create a OpenGL context: %s", .{err_str(c.eglGetError())});
        return 0;
    }
    backends.createNativeWindow(ctx[0].window);
    const handle = if (w != null) c.gst_gl_window_get_window_handle(w) else 0;
    var need = true;
    if (handle != 0) {
        e.egl_surface = c.eglCreateWindowSurface(e.egl_display, e.egl_config, handle, null);
    } else if (!has("EGL_KHR_surfaceless_context", e.egl_exts)) {
        const attrs = [_]c.EGLint{ c.EGL_WIDTH, 1, c.EGL_HEIGHT, 1, c.EGL_LARGEST_PBUFFER, c.EGL_TRUE, c.EGL_NONE };
        e.egl_surface = c.eglCreatePbufferSurface(e.egl_display, e.egl_config, &attrs);
    } else {
        e.egl_surface = c.EGL_NO_SURFACE;
        need = false;
    }
    if (need and e.egl_surface == c.EGL_NO_SURFACE) {
        setError(err, c.GST_GL_CONTEXT_ERROR_FAILED, "Failed to create window surface: %s", .{err_str(c.eglGetError())});
        return 0;
    }
    e.egl_major = maj;
    e.egl_minor = min;
    if (w != null) e.window_handle_signal = c.g_signal_connect_data(w, "window-handle-changed", @ptrCast(&handleChanged), e, null, c.G_CONNECT_SWAPPED);
    return 1;
}

fn destroyContext(ctx: OCtx) callconv(.c) void {
    const e = egl(ctx);
    const w = context.gst_gl_context_get_window(ctx);
    if (w != null and e.window_handle_signal != 0) {
        c.g_signal_handler_disconnect(w, e.window_handle_signal);
        e.window_handle_signal = 0;
    }
    if (w != null) c.gst_object_unref(w);
    if (e.dma_formats) |a| {
        c.g_array_unref(a);
        e.dma_formats = null;
    }
    _ = activate(ctx, 0);
    if (e.egl_surface != null) {
        _ = c.eglDestroySurface(e.egl_display, e.egl_surface);
        e.egl_surface = c.EGL_NO_SURFACE;
    }
    if (e.egl_context != null) {
        _ = c.eglDestroyContext(e.egl_display, e.egl_context);
        e.egl_context = null;
    }
    _ = c.eglReleaseThread();
    if (e.display_egl) |d| {
        c.gst_object_unref(d);
        e.display_egl = null;
    }
    if (e.requested_config) |r| c.gst_structure_free(r);
    e.requested_config = null;
}

fn activate(ctx: OCtx, on: c.gboolean) callconv(.c) c.gboolean {
    const e = egl(ctx);
    if (on == 0) return @bitCast(c.eglMakeCurrent(e.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT));
    const w = context.gst_gl_context_get_window(ctx);
    var handle: c.guintptr = 0;
    if (w != null) {
        handle = c.gst_gl_window_get_window_handle(w);
        c.gst_object_unref(w);
    }
    if (handle != 0 and e.egl_surface == c.EGL_NO_SURFACE) {
        e.egl_surface = c.eglCreateWindowSurface(e.egl_display, e.egl_config, handle, null);
        e.window_handle = handle;
        if (e.egl_surface == c.EGL_NO_SURFACE) return 0;
    }
    const r: c.gboolean = @bitCast(c.eglMakeCurrent(e.egl_display, e.egl_surface, e.egl_surface, e.egl_context));
    if (backends.isWaylandWindow(ctx[0].window)) _ = c.eglSwapInterval(e.egl_display, 0);
    return r;
}

fn chooseFormat(ctx: OCtx, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    return @intFromBool(backends.matchVisual(ctx, err));
}

fn glContext(ctx: OCtx) callconv(.c) c.guintptr {
    return @intFromPtr(egl(ctx).egl_context);
}

fn swap(ctx: OCtx) callconv(.c) void {
    _ = c.eglSwapBuffers(egl(ctx).egl_display, egl(ctx).egl_surface);
}

fn glApi(ctx: OCtx) callconv(.c) c.GstGLAPI {
    return egl(ctx).gl_api;
}

fn glPlatform(_: OCtx) callconv(.c) c.GstGLPlatform {
    return c.GST_GL_PLATFORM_EGL;
}

const Module = struct {
    once: usize = 0,
    handle: ?*c.GModule = null,
};

var mod_egl: Module = .{};

pub fn procAddress(api: c.GstGLAPI, name: [*c]const u8) callconv(.c) c.gpointer {
    var r = context.gst_gl_context_default_get_proc_address(api, name);
    if (c.g_once_init_enter(&mod_egl.once) != 0) {
        mod_egl.handle = c.g_module_open("libEGL.so.1", c.G_MODULE_BIND_LAZY);
        if (mod_egl.handle == null) mod_egl.handle = c.g_module_open("libEGL", c.G_MODULE_BIND_LAZY);
        c.g_once_init_leave(&mod_egl.once, 1);
    }
    if (r == null and mod_egl.handle != null) _ = c.g_module_symbol(mod_egl.handle, name, &r);
    if (r == null) r = @ptrCast(@constCast(c.eglGetProcAddress(name)));
    return r;
}

fn checkFeature(ctx: OCtx, name: [*c]const u8) callconv(.c) c.gboolean {
    return feature.gst_gl_check_extension(name, egl(ctx).egl_exts);
}

pub fn currentContext() callconv(.c) c.guintptr {
    return @intFromPtr(c.eglGetCurrentContext());
}

fn platformVersion(ctx: OCtx, major: [*c]c.gint, minor: [*c]c.gint) callconv(.c) void {
    major[0] = egl(ctx).egl_major;
    minor[0] = egl(ctx).egl_minor;
}

fn getConfig(ctx: OCtx) callconv(.c) ?*c.GstStructure {
    const e = egl(ctx);
    if (!check.that(e.egl_config != null, "gst_gl_context_egl_get_config", "egl->egl_config")) return null;
    return configToStructure(e.egl_display, e.egl_config);
}

fn requestConfig(ctx: OCtx, cfg: ?*c.GstStructure) callconv(.c) c.gboolean {
    const e = egl(ctx);
    if (e.requested_config) |r| c.gst_structure_free(r);
    e.requested_config = cfg;
    return 1;
}

pub fn fillInfo(ctx: *c.GstGLContext, err: [*c][*c]c.GError) bool {
    const ectx: c.EGLContext = @ptrFromInt(context.gst_gl_context_get_gl_context(ctx));
    if (ectx == null) {
        setError(err, c.GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE, "no EGL context", .{});
        return false;
    }
    const d = edisplay.gst_gl_display_egl_from_gl_display(ctx.display);
    defer c.gst_object_unref(d);
    const dpy: c.EGLDisplay = @ptrFromInt(c.gst_gl_display_get_handle(@ptrCast(d)));
    var id: c.EGLint = 0;
    if (c.eglQueryContext(dpy, ectx, c.EGL_CONFIG_ID, &id) != c.EGL_TRUE) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "could not retrieve egl config id from egl context: %s", .{err_str(c.eglGetError())});
        return false;
    }
    if (id == 0) return true;
    const attrs = [_]c.EGLint{ c.EGL_CONFIG_ID, id, c.EGL_NONE };
    var cfg: c.EGLConfig = null;
    var n: c.EGLint = 0;
    if (c.eglChooseConfig(dpy, &attrs, &cfg, 1, &n) != c.EGL_TRUE or n <= 0) {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "could not retrieve egl config from its ID 0x%x. Wrong EGLDisplay or context?", .{id});
        return false;
    }
    const s = configToStructure(dpy, cfg) orelse {
        setError(err, c.GST_GL_CONTEXT_ERROR_WRONG_CONFIG, "could not transform config id 0x%x into GstStructure", .{id});
        return false;
    };
    c.g_object_set_data_full(@ptrCast(ctx), "gst.gl.context.wrapped.config", s, @ptrCast(&c.gst_structure_free));
    return true;
}

const QueryFormats = *const fn (c.EGLDisplay, c.EGLint, [*c]c.EGLint, [*c]c.EGLint) callconv(.c) c.EGLBoolean;
const QueryModifiers = *const fn (c.EGLDisplay, c.EGLint, c.EGLint, [*c]u64, [*c]c.EGLBoolean, [*c]c.EGLint) callconv(.c) c.EGLBoolean;

fn cmpFormat(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const x: *const DmaFormat = @ptrCast(@alignCast(a));
    const y: *const DmaFormat = @ptrCast(@alignCast(b));
    return x.fourcc -% y.fourcc;
}

fn freeFormat(data: c.gpointer) callconv(.c) void {
    const f: *DmaFormat = @ptrCast(@alignCast(data));
    if (f.modifiers) |m| c.g_array_unref(m);
}

fn objLock(ctx: OCtx) void {
    c.g_mutex_lock(&ctx[0].parent.lock);
}

fn objUnlock(ctx: OCtx) void {
    c.g_mutex_unlock(&ctx[0].parent.lock);
}

fn fetchFormats(ctx: OCtx) bool {
    const e = egl(ctx);
    objLock(ctx);
    if (e.dma_formats != null) {
        objUnlock(ctx);
        return true;
    }
    objUnlock(ctx);
    if (context.gst_gl_context_check_feature(ctx, "EGL_EXT_image_dma_buf_import_modifiers") == 0) return false;
    const qf: QueryFormats = @ptrCast(context.gst_gl_context_get_proc_address(ctx, "eglQueryDmaBufFormatsEXT") orelse return false);
    const qm: QueryModifiers = @ptrCast(context.gst_gl_context_get_proc_address(ctx, "eglQueryDmaBufModifiersEXT") orelse return false);
    const d = edisplay.gst_gl_display_egl_from_gl_display(ctx[0].display);
    if (d == null) return false;
    const dpy: c.EGLDisplay = @ptrFromInt(c.gst_gl_display_get_handle(@ptrCast(d)));
    c.gst_object_unref(d);
    var n: c.EGLint = 0;
    if (qf(dpy, 0, null, &n) == 0 or n == 0) return false;
    const al = std.heap.c_allocator;
    const formats = al.alloc(c.EGLint, @intCast(n)) catch return false;
    defer al.free(formats);
    if (qf(dpy, n, formats.ptr, &n) == 0 or n == 0) return false;
    const arr = c.g_array_sized_new(0, 0, @sizeOf(DmaFormat), @bitCast(n));
    c.g_array_set_clear_func(arr, freeFormat);
    var mods: []u64 = &.{};
    var ext: []c.EGLBoolean = &.{};
    defer {
        if (mods.len != 0) al.free(mods);
        if (ext.len != 0) al.free(ext);
    }
    for (formats[0..@intCast(n)]) |fourcc| {
        var f = DmaFormat{ .fourcc = fourcc, .modifiers = null };
        var nm: c.EGLint = 0;
        if (qm(dpy, fourcc, 0, null, null, &nm) == 0) continue;
        if (nm > 0) {
            const need: usize = @intCast(nm);
            if (mods.len < need) {
                if (mods.len != 0) al.free(mods);
                if (ext.len != 0) al.free(ext);
                mods = al.alloc(u64, need) catch return false;
                ext = al.alloc(c.EGLBoolean, need) catch return false;
            }
            @memset(ext, 0);
            if (qm(dpy, fourcc, nm, mods.ptr, ext.ptr, &nm) == 0) continue;
            const ma = c.g_array_sized_new(0, 0, @sizeOf(Modifier), @bitCast(nm));
            f.modifiers = c.g_array_set_size(ma, @bitCast(nm));
            const md: [*]Modifier = @ptrCast(@alignCast(f.modifiers.?.data));
            for (0..@intCast(nm)) |j| md[j] = .{ .modifier = mods[j], .external_only = @bitCast(ext[j]) };
        }
        _ = c.g_array_append_vals(arr, &f, 1);
    }
    c.g_array_sort(arr, cmpFormat);
    objLock(ctx);
    const fresh = e.dma_formats == null;
    if (fresh) e.dma_formats = arr;
    objUnlock(ctx);
    if (!fresh) c.g_array_unref(arr);
    return true;
}

pub fn formatModifiers(ctx: OCtx, fourcc: c.gint, out: *?*const c.GArray) bool {
    if (!check.that(isEgl(ctx), "gst_gl_context_egl_get_format_modifiers", "GST_IS_GL_CONTEXT_EGL (context)")) return false;
    if (!fetchFormats(ctx)) return false;
    const e = egl(ctx);
    objLock(ctx);
    defer objUnlock(ctx);
    const arr = e.dma_formats orelse return false;
    var key = DmaFormat{ .fourcc = fourcc, .modifiers = null };
    var idx: c.guint = 0;
    if (c.g_array_binary_search(arr, &key, cmpFormat, &idx) == 0) return false;
    const fs: [*]DmaFormat = @ptrCast(@alignCast(arr.data));
    out.* = fs[idx].modifiers;
    return true;
}

pub fn supportsModifierFor(ctx: OCtx, fourcc: u32, modifier: u64, external: bool) bool {
    if (!check.that(isEgl(ctx), "gst_gl_context_egl_format_supports_modifier", "GST_IS_GL_CONTEXT_EGL (context)")) return false;
    var mods: ?*const c.GArray = null;
    if (!formatModifiers(ctx, @bitCast(fourcc), &mods)) return false;
    const m = mods orelse return modifier == 0;
    const md: [*]const Modifier = @ptrCast(@alignCast(m.data));
    for (md[0..m.len]) |x| {
        if ((x.external_only == 0 or external) and x.modifier == modifier) return true;
    }
    return false;
}

pub fn appendDrmFormats(ctx: OCtx, out: *c.GPtrArray, external: bool) void {
    if (!check.that(isEgl(ctx), "gst_gl_context_egl_append_all_drm_formats", "GST_IS_GL_CONTEXT_EGL (context)")) return;
    if (!fetchFormats(ctx)) return;
    const e = egl(ctx);
    objLock(ctx);
    defer objUnlock(ctx);
    const arr = e.dma_formats orelse return;
    const fs: [*]DmaFormat = @ptrCast(@alignCast(arr.data));
    for (fs[0..arr.len]) |f| {
        const linear = [_]Modifier{.{ .modifier = 0, .external_only = 0 }};
        const mods: []const Modifier = if (f.modifiers) |m| @as([*]const Modifier, @ptrCast(@alignCast(m.data)))[0..m.len] else &linear;
        for (mods) |m| {
            if (m.external_only != 0 and !external) continue;
            c.g_ptr_array_add(out, c.gst_video_dma_drm_fourcc_to_string(@bitCast(f.fourcc), m.modifier));
        }
    }
}

pub fn supportsModifier(ctx: OCtx) bool {
    if (!check.that(isEgl(ctx), "gst_gl_context_egl_supports_modifier", "GST_IS_GL_CONTEXT_EGL (context)")) return false;
    return fetchFormats(ctx);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
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
    cc.check_feature = checkFeature;
    cc.get_current_context = currentContext;
    cc.get_gl_platform_version = platformVersion;
    cc.get_config = getConfig;
    cc.request_config = requestConfig;
}

pub fn typeGet() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(context.gst_gl_context_get_type, "GstGLContextEGL", c.GstGLContextClass, Egl, classInit, null, 0);
        }
    }.f);
}

pub fn new() *c.GstGLContext {
    const o = c.g_object_new(typeGet(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    return @ptrCast(@alignCast(o));
}
