const c = @import("../../c.zig").c;

comptime {
    @import("../../abi.zig").check(@This());
}

pub export fn gst_egl_get_error_string(err: c.EGLint) [*c]const u8 {
    return switch (err) {
        c.EGL_SUCCESS => "EGL_SUCCESS",
        c.EGL_BAD_DISPLAY => "EGL_BAD_DISPLAY",
        c.EGL_NOT_INITIALIZED => "EGL_NOT_INITIALIZED",
        c.EGL_BAD_ACCESS => "EGL_BAD_ACCESS",
        c.EGL_BAD_ALLOC => "EGL_BAD_ALLOC",
        c.EGL_BAD_ATTRIBUTE => "EGL_BAD_ATTRIBUTE",
        c.EGL_BAD_CONFIG => "EGL_BAD_CONFIG",
        c.EGL_BAD_CONTEXT => "EGL_BAD_CONTEXT",
        c.EGL_BAD_CURRENT_SURFACE => "EGL_BAD_CURRENT_SURFACE",
        c.EGL_BAD_MATCH => "EGL_BAD_MATCH",
        c.EGL_BAD_NATIVE_PIXMAP => "EGL_BAD_NATIVE_PIXMAP",
        c.EGL_BAD_NATIVE_WINDOW => "EGL_BAD_NATIVE_WINDOW",
        c.EGL_BAD_PARAMETER => "EGL_BAD_PARAMETER",
        c.EGL_BAD_SURFACE => "EGL_BAD_SURFACE",
        else => "unknown",
    };
}
