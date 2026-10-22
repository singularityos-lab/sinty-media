const c = @import("../c.zig").c;

comptime {
    @import("../abi.zig").check(@This());
}

const API_NAMES = [_]struct { c.GstGLAPI, [*:0]const u8 }{
    .{ c.GST_GL_API_OPENGL, "opengl" },
    .{ c.GST_GL_API_OPENGL3, "opengl3" },
    .{ c.GST_GL_API_GLES1, "gles1" },
    .{ c.GST_GL_API_GLES2, "gles2" },
};

const PLATFORM_NAMES = [_]struct { c.GstGLPlatform, [*:0]const u8 }{
    .{ c.GST_GL_PLATFORM_GLX, "glx" },
    .{ c.GST_GL_PLATFORM_EGL, "egl" },
    .{ c.GST_GL_PLATFORM_WGL, "wgl" },
    .{ c.GST_GL_PLATFORM_CGL, "cgl" },
    .{ c.GST_GL_PLATFORM_EAGL, "eagl" },
};

pub export fn gst_gl_api_to_string(api: c.GstGLAPI) [*c]c.gchar {
    if (api == c.GST_GL_API_NONE) return c.g_strdup("none");
    if (api == c.GST_GL_API_ANY) return c.g_strdup("any");
    var s: ?*c.GString = null;
    for (API_NAMES) |e| {
        if (api & e[0] == 0) continue;
        if (s) |x| {
            _ = c.g_string_append_c(x, ' ');
            _ = c.g_string_append(x, e[1]);
        } else s = c.g_string_new(e[1]);
    }
    return c.g_string_free(s orelse c.g_string_new("unknown"), 0);
}

pub export fn gst_gl_api_from_string(apis_s: [*c]const c.gchar) c.GstGLAPI {
    if (apis_s == null or apis_s[0] == 0 or c.g_strcmp0(apis_s, "any") == 0) return c.GST_GL_API_ANY;
    if (c.g_strcmp0(apis_s, "none") == 0) return c.GST_GL_API_NONE;
    var ret: c.GstGLAPI = c.GST_GL_API_NONE;
    var p = apis_s;
    while (p[0] != 0) {
        if (p[0] == ' ' or p[0] == ',') {
            p += 1;
        } else if (c.g_strstr_len(p, 7, "opengl3") != null) {
            ret |= c.GST_GL_API_OPENGL3;
            p += 7;
        } else if (c.g_strstr_len(p, 6, "opengl") != null) {
            ret |= c.GST_GL_API_OPENGL;
            p += 6;
        } else if (c.g_strstr_len(p, 5, "gles1") != null) {
            ret |= c.GST_GL_API_GLES1;
            p += 5;
        } else if (c.g_strstr_len(p, 5, "gles2") != null) {
            ret |= c.GST_GL_API_GLES2;
            p += 5;
        } else break;
    }
    return ret;
}

pub export fn gst_gl_platform_to_string(platform: c.GstGLPlatform) [*c]c.gchar {
    if (platform == c.GST_GL_PLATFORM_NONE) return c.g_strdup("none");
    if (platform == c.GST_GL_PLATFORM_ANY) return c.g_strdup("any");
    const s = c.g_string_new("");
    var first = true;
    for (PLATFORM_NAMES) |e| {
        if (platform & e[0] == 0) continue;
        if (!first) _ = c.g_string_append_c(s, ' ');
        _ = c.g_string_append(s, e[1]);
        first = false;
    }
    if (s[0].len == 0) _ = c.g_string_append(s, "unknown");
    return c.g_string_free(s, 0);
}

pub export fn gst_gl_platform_from_string(platform_s: [*c]const c.gchar) c.GstGLPlatform {
    if (platform_s == null or platform_s[0] == 0 or c.g_strcmp0(platform_s, "any") == 0) return c.GST_GL_PLATFORM_ANY;
    if (c.g_strcmp0(platform_s, "none") == 0) return c.GST_GL_PLATFORM_NONE;
    var ret: c.GstGLPlatform = c.GST_GL_PLATFORM_NONE;
    var p = platform_s;
    outer: while (p[0] != 0) {
        if (p[0] == ' ' or p[0] == ',') {
            p += 1;
            continue;
        }
        for (PLATFORM_NAMES) |e| {
            const n: usize = if (e[0] == c.GST_GL_PLATFORM_EAGL) 4 else 3;
            if (c.g_strstr_len(p, @intCast(n), e[1]) != null) {
                ret |= e[0];
                p += n;
                continue :outer;
            }
        }
        break;
    }
    return ret;
}
