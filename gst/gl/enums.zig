const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

var gst_gl_api_once: gtype.Once = .{};
var gst_gl_platform_once: gtype.Once = .{};
var gst_gl_display_type_once: gtype.Once = .{};
var gst_gl_base_memory_error_once: gtype.Once = .{};
var gst_gl_base_memory_transfer_once: gtype.Once = .{};
var gst_gl_config_caveat_once: gtype.Once = .{};
var gst_gl_config_surface_type_once: gtype.Once = .{};
var gst_gl_context_error_once: gtype.Once = .{};
var gst_gl_drm_format_flags_once: gtype.Once = .{};
var gst_gl_format_once: gtype.Once = .{};
var gst_gl_query_type_once: gtype.Once = .{};
var gst_gl_stereo_downmix_once: gtype.Once = .{};
var gst_gl_texture_target_once: gtype.Once = .{};
var gst_gl_upload_return_once: gtype.Once = .{};
var gst_gl_window_error_once: gtype.Once = .{};
var gst_glsl_error_once: gtype.Once = .{};
var gst_glsl_profile_once: gtype.Once = .{};
var gst_glsl_version_once: gtype.Once = .{};

pub export fn gst_gl_api_get_type() c.GType {
    return gst_gl_api_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = 0, .value_name = "GST_GL_API_NONE", .value_nick = "none" },
            .{ .value = 1, .value_name = "GST_GL_API_OPENGL", .value_nick = "opengl" },
            .{ .value = 2, .value_name = "GST_GL_API_OPENGL3", .value_nick = "opengl3" },
            .{ .value = 32768, .value_name = "GST_GL_API_GLES1", .value_nick = "gles1" },
            .{ .value = 65536, .value_name = "GST_GL_API_GLES2", .value_nick = "gles2" },
            .{ .value = 4294967295, .value_name = "GST_GL_API_ANY", .value_nick = "any" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstGLAPI"), &values);
        }
    }.f);
}

pub export fn gst_gl_platform_get_type() c.GType {
    return gst_gl_platform_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = 0, .value_name = "GST_GL_PLATFORM_NONE", .value_nick = "none" },
            .{ .value = 1, .value_name = "GST_GL_PLATFORM_EGL", .value_nick = "egl" },
            .{ .value = 2, .value_name = "GST_GL_PLATFORM_GLX", .value_nick = "glx" },
            .{ .value = 4, .value_name = "GST_GL_PLATFORM_WGL", .value_nick = "wgl" },
            .{ .value = 8, .value_name = "GST_GL_PLATFORM_CGL", .value_nick = "cgl" },
            .{ .value = 16, .value_name = "GST_GL_PLATFORM_EAGL", .value_nick = "eagl" },
            .{ .value = 4294967295, .value_name = "GST_GL_PLATFORM_ANY", .value_nick = "any" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstGLPlatform"), &values);
        }
    }.f);
}

pub export fn gst_gl_display_type_get_type() c.GType {
    return gst_gl_display_type_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = 0, .value_name = "GST_GL_DISPLAY_TYPE_NONE", .value_nick = "none" },
            .{ .value = 1, .value_name = "GST_GL_DISPLAY_TYPE_X11", .value_nick = "x11" },
            .{ .value = 2, .value_name = "GST_GL_DISPLAY_TYPE_WAYLAND", .value_nick = "wayland" },
            .{ .value = 4, .value_name = "GST_GL_DISPLAY_TYPE_COCOA", .value_nick = "cocoa" },
            .{ .value = 8, .value_name = "GST_GL_DISPLAY_TYPE_WIN32", .value_nick = "win32" },
            .{ .value = 16, .value_name = "GST_GL_DISPLAY_TYPE_DISPMANX", .value_nick = "dispmanx" },
            .{ .value = 32, .value_name = "GST_GL_DISPLAY_TYPE_EGL", .value_nick = "egl" },
            .{ .value = 64, .value_name = "GST_GL_DISPLAY_TYPE_VIV_FB", .value_nick = "viv-fb" },
            .{ .value = 128, .value_name = "GST_GL_DISPLAY_TYPE_GBM", .value_nick = "gbm" },
            .{ .value = 256, .value_name = "GST_GL_DISPLAY_TYPE_EGL_DEVICE", .value_nick = "egl-device" },
            .{ .value = 512, .value_name = "GST_GL_DISPLAY_TYPE_EAGL", .value_nick = "eagl" },
            .{ .value = 1024, .value_name = "GST_GL_DISPLAY_TYPE_WINRT", .value_nick = "winrt" },
            .{ .value = 2048, .value_name = "GST_GL_DISPLAY_TYPE_ANDROID", .value_nick = "android" },
            .{ .value = 4096, .value_name = "GST_GL_DISPLAY_TYPE_EGL_SURFACELESS", .value_nick = "egl-surfaceless" },
            .{ .value = 4294967295, .value_name = "GST_GL_DISPLAY_TYPE_ANY", .value_nick = "any" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstGLDisplayType"), &values);
        }
    }.f);
}

pub export fn gst_gl_base_memory_error_get_type() c.GType {
    return gst_gl_base_memory_error_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GL_BASE_MEMORY_ERROR_FAILED", .value_nick = "failed" },
            .{ .value = 1, .value_name = "GST_GL_BASE_MEMORY_ERROR_OLD_LIBS", .value_nick = "old-libs" },
            .{ .value = 2, .value_name = "GST_GL_BASE_MEMORY_ERROR_RESOURCE_UNAVAILABLE", .value_nick = "resource-unavailable" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLBaseMemoryError"), &values);
        }
    }.f);
}

pub export fn gst_gl_base_memory_transfer_get_type() c.GType {
    return gst_gl_base_memory_transfer_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = 1048576, .value_name = "GST_GL_BASE_MEMORY_TRANSFER_NEED_DOWNLOAD", .value_nick = "download" },
            .{ .value = 2097152, .value_name = "GST_GL_BASE_MEMORY_TRANSFER_NEED_UPLOAD", .value_nick = "upload" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstGLBaseMemoryTransfer"), &values);
        }
    }.f);
}

pub export fn gst_gl_config_caveat_get_type() c.GType {
    return gst_gl_config_caveat_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GL_CONFIG_CAVEAT_NONE", .value_nick = "none" },
            .{ .value = 1, .value_name = "GST_GL_CONFIG_CAVEAT_SLOW", .value_nick = "slow" },
            .{ .value = 2, .value_name = "GST_GL_CONFIG_CAVEAT_NON_CONFORMANT", .value_nick = "non-conformant" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLConfigCaveat"), &values);
        }
    }.f);
}

pub export fn gst_gl_config_surface_type_get_type() c.GType {
    return gst_gl_config_surface_type_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = 0, .value_name = "GST_GL_CONFIG_SURFACE_TYPE_NONE", .value_nick = "none" },
            .{ .value = 1, .value_name = "GST_GL_CONFIG_SURFACE_TYPE_WINDOW", .value_nick = "window" },
            .{ .value = 2, .value_name = "GST_GL_CONFIG_SURFACE_TYPE_PBUFFER", .value_nick = "pbuffer" },
            .{ .value = 4, .value_name = "GST_GL_CONFIG_SURFACE_TYPE_PIXMAP", .value_nick = "pixmap" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstGLConfigSurfaceType"), &values);
        }
    }.f);
}

pub export fn gst_gl_context_error_get_type() c.GType {
    return gst_gl_context_error_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GL_CONTEXT_ERROR_FAILED", .value_nick = "failed" },
            .{ .value = 1, .value_name = "GST_GL_CONTEXT_ERROR_WRONG_CONFIG", .value_nick = "wrong-config" },
            .{ .value = 2, .value_name = "GST_GL_CONTEXT_ERROR_WRONG_API", .value_nick = "wrong-api" },
            .{ .value = 3, .value_name = "GST_GL_CONTEXT_ERROR_OLD_LIBS", .value_nick = "old-libs" },
            .{ .value = 4, .value_name = "GST_GL_CONTEXT_ERROR_CREATE_CONTEXT", .value_nick = "create-context" },
            .{ .value = 5, .value_name = "GST_GL_CONTEXT_ERROR_RESOURCE_UNAVAILABLE", .value_nick = "resource-unavailable" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLContextError"), &values);
        }
    }.f);
}

pub export fn gst_gl_drm_format_flags_get_type() c.GType {
    return gst_gl_drm_format_flags_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = 1, .value_name = "GST_GL_DRM_FORMAT_INCLUDE_EXTERNAL", .value_nick = "include-external" },
            .{ .value = 2, .value_name = "GST_GL_DRM_FORMAT_LINEAR_ONLY", .value_nick = "linear-only" },
            .{ .value = 4, .value_name = "GST_GL_DRM_FORMAT_INCLUDE_EMULATED", .value_nick = "include-emulated" },
            .{ .value = 8, .value_name = "GST_GL_DRM_FORMAT_DIRECT_IMPORT", .value_nick = "direct-import" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstGLDrmFormatFlags"), &values);
        }
    }.f);
}

pub export fn gst_gl_format_get_type() c.GType {
    return gst_gl_format_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 6409, .value_name = "GST_GL_LUMINANCE", .value_nick = "luminance" },
            .{ .value = 6406, .value_name = "GST_GL_ALPHA", .value_nick = "alpha" },
            .{ .value = 6410, .value_name = "GST_GL_LUMINANCE_ALPHA", .value_nick = "luminance-alpha" },
            .{ .value = 6403, .value_name = "GST_GL_RED", .value_nick = "red" },
            .{ .value = 33321, .value_name = "GST_GL_R8", .value_nick = "r8" },
            .{ .value = 33319, .value_name = "GST_GL_RG", .value_nick = "rg" },
            .{ .value = 33323, .value_name = "GST_GL_RG8", .value_nick = "rg8" },
            .{ .value = 6407, .value_name = "GST_GL_RGB", .value_nick = "rgb" },
            .{ .value = 32849, .value_name = "GST_GL_RGB8", .value_nick = "rgb8" },
            .{ .value = 36194, .value_name = "GST_GL_RGB565", .value_nick = "rgb565" },
            .{ .value = 32852, .value_name = "GST_GL_RGB16", .value_nick = "rgb16" },
            .{ .value = 6408, .value_name = "GST_GL_RGBA", .value_nick = "rgba" },
            .{ .value = 32856, .value_name = "GST_GL_RGBA8", .value_nick = "rgba8" },
            .{ .value = 32859, .value_name = "GST_GL_RGBA16", .value_nick = "rgba16" },
            .{ .value = 33189, .value_name = "GST_GL_DEPTH_COMPONENT16", .value_nick = "depth-component16" },
            .{ .value = 35056, .value_name = "GST_GL_DEPTH24_STENCIL8", .value_nick = "depth24-stencil8" },
            .{ .value = 32857, .value_name = "GST_GL_RGB10_A2", .value_nick = "rgb10-a2" },
            .{ .value = 33322, .value_name = "GST_GL_R16", .value_nick = "r16" },
            .{ .value = 33324, .value_name = "GST_GL_RG16", .value_nick = "rg16" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLFormat"), &values);
        }
    }.f);
}

pub export fn gst_gl_query_type_get_type() c.GType {
    return gst_gl_query_type_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GL_QUERY_NONE", .value_nick = "none" },
            .{ .value = 1, .value_name = "GST_GL_QUERY_TIME_ELAPSED", .value_nick = "time-elapsed" },
            .{ .value = 2, .value_name = "GST_GL_QUERY_TIMESTAMP", .value_nick = "timestamp" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLQueryType"), &values);
        }
    }.f);
}

pub export fn gst_gl_stereo_downmix_get_type() c.GType {
    return gst_gl_stereo_downmix_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GL_STEREO_DOWNMIX_ANAGLYPH_GREEN_MAGENTA_DUBOIS", .value_nick = "green-magenta-dubois" },
            .{ .value = 1, .value_name = "GST_GL_STEREO_DOWNMIX_ANAGLYPH_RED_CYAN_DUBOIS", .value_nick = "red-cyan-dubois" },
            .{ .value = 2, .value_name = "GST_GL_STEREO_DOWNMIX_ANAGLYPH_AMBER_BLUE_DUBOIS", .value_nick = "amber-blue-dubois" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLStereoDownmix"), &values);
        }
    }.f);
}

pub export fn gst_gl_stereo_downmix_mode_get_type() c.GType {
    return gst_gl_stereo_downmix_get_type();
}

pub export fn gst_gl_texture_target_get_type() c.GType {
    return gst_gl_texture_target_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GL_TEXTURE_TARGET_NONE", .value_nick = "none" },
            .{ .value = 1, .value_name = "GST_GL_TEXTURE_TARGET_2D", .value_nick = "2d" },
            .{ .value = 2, .value_name = "GST_GL_TEXTURE_TARGET_RECTANGLE", .value_nick = "rectangle" },
            .{ .value = 3, .value_name = "GST_GL_TEXTURE_TARGET_EXTERNAL_OES", .value_nick = "external-oes" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLTextureTarget"), &values);
        }
    }.f);
}

pub export fn gst_gl_upload_return_get_type() c.GType {
    return gst_gl_upload_return_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 1, .value_name = "GST_GL_UPLOAD_DONE", .value_nick = "done" },
            .{ .value = -1, .value_name = "GST_GL_UPLOAD_ERROR", .value_nick = "error" },
            .{ .value = -2, .value_name = "GST_GL_UPLOAD_UNSUPPORTED", .value_nick = "unsupported" },
            .{ .value = -3, .value_name = "GST_GL_UPLOAD_RECONFIGURE", .value_nick = "reconfigure" },
            .{ .value = -100, .value_name = "GST_GL_UPLOAD_UNSHARED_GL_CONTEXT", .value_nick = "unshared-gl-context" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLUploadReturn"), &values);
        }
    }.f);
}

pub export fn gst_gl_window_error_get_type() c.GType {
    return gst_gl_window_error_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GL_WINDOW_ERROR_FAILED", .value_nick = "failed" },
            .{ .value = 1, .value_name = "GST_GL_WINDOW_ERROR_OLD_LIBS", .value_nick = "old-libs" },
            .{ .value = 2, .value_name = "GST_GL_WINDOW_ERROR_RESOURCE_UNAVAILABLE", .value_nick = "resource-unavailable" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLWindowError"), &values);
        }
    }.f);
}

pub export fn gst_glsl_error_get_type() c.GType {
    return gst_glsl_error_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GLSL_ERROR_COMPILE", .value_nick = "compile" },
            .{ .value = 1, .value_name = "GST_GLSL_ERROR_LINK", .value_nick = "link" },
            .{ .value = 2, .value_name = "GST_GLSL_ERROR_PROGRAM", .value_nick = "program" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLSLError"), &values);
        }
    }.f);
}

pub export fn gst_glsl_profile_get_type() c.GType {
    return gst_glsl_profile_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = 0, .value_name = "GST_GLSL_PROFILE_NONE", .value_nick = "none" },
            .{ .value = 1, .value_name = "GST_GLSL_PROFILE_ES", .value_nick = "es" },
            .{ .value = 2, .value_name = "GST_GLSL_PROFILE_CORE", .value_nick = "core" },
            .{ .value = 4, .value_name = "GST_GLSL_PROFILE_COMPATIBILITY", .value_nick = "compatibility" },
            .{ .value = 4294967295, .value_name = "GST_GLSL_PROFILE_ANY", .value_nick = "any" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstGLSLProfile"), &values);
        }
    }.f);
}

pub export fn gst_glsl_version_get_type() c.GType {
    return gst_glsl_version_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_GLSL_VERSION_NONE", .value_nick = "none" },
            .{ .value = 100, .value_name = "GST_GLSL_VERSION_100", .value_nick = "100" },
            .{ .value = 110, .value_name = "GST_GLSL_VERSION_110", .value_nick = "110" },
            .{ .value = 120, .value_name = "GST_GLSL_VERSION_120", .value_nick = "120" },
            .{ .value = 130, .value_name = "GST_GLSL_VERSION_130", .value_nick = "130" },
            .{ .value = 140, .value_name = "GST_GLSL_VERSION_140", .value_nick = "140" },
            .{ .value = 150, .value_name = "GST_GLSL_VERSION_150", .value_nick = "150" },
            .{ .value = 300, .value_name = "GST_GLSL_VERSION_300", .value_nick = "300" },
            .{ .value = 310, .value_name = "GST_GLSL_VERSION_310", .value_nick = "310" },
            .{ .value = 320, .value_name = "GST_GLSL_VERSION_320", .value_nick = "320" },
            .{ .value = 330, .value_name = "GST_GLSL_VERSION_330", .value_nick = "330" },
            .{ .value = 400, .value_name = "GST_GLSL_VERSION_400", .value_nick = "400" },
            .{ .value = 410, .value_name = "GST_GLSL_VERSION_410", .value_nick = "410" },
            .{ .value = 420, .value_name = "GST_GLSL_VERSION_420", .value_nick = "420" },
            .{ .value = 430, .value_name = "GST_GLSL_VERSION_430", .value_nick = "430" },
            .{ .value = 440, .value_name = "GST_GLSL_VERSION_440", .value_nick = "440" },
            .{ .value = 450, .value_name = "GST_GLSL_VERSION_450", .value_nick = "450" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstGLSLVersion"), &values);
        }
    }.f);
}
