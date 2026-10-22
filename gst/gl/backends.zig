const c = @import("../c.zig").c;
const egl_context = @import("egl/context.zig");
const egl_display = @import("egl/display.zig");

pub fn x11Window(_: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    return null;
}

pub fn waylandWindow(_: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    return null;
}

pub fn gbmWindow(_: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    return null;
}

pub fn isWaylandWindow(_: [*c]c.GstGLWindow) bool {
    return false;
}

pub fn createNativeWindow(_: [*c]c.GstGLWindow) void {}

pub fn matchVisual(_: [*c]c.GstGLContext, _: [*c][*c]c.GError) bool {
    return true;
}

pub fn glxContext(_: [*c]c.GstGLDisplay) ?*c.GstGLContext {
    return null;
}

pub fn eglContext(_: [*c]c.GstGLDisplay) ?*c.GstGLContext {
    return egl_context.new();
}

pub fn glxCurrent() callconv(.c) c.guintptr {
    return 0;
}

pub const eglCurrent = egl_context.currentContext;

pub fn glxProc(_: c.GstGLAPI, _: [*c]const u8) callconv(.c) c.gpointer {
    return null;
}

pub const eglProc = egl_context.procAddress;

pub fn glxFillInfo(_: *c.GstGLContext, _: [*c][*c]c.GError) bool {
    return true;
}

pub const eglFillInfo = egl_context.fillInfo;

pub fn waylandDisplay() ?*c.GstGLDisplay {
    return null;
}

pub fn x11Display() ?*c.GstGLDisplay {
    return null;
}

pub fn gbmDisplay() ?*c.GstGLDisplay {
    return null;
}

pub fn eglDeviceDisplay() ?*c.GstGLDisplay {
    return @ptrCast(egl_display.gst_gl_display_egl_device_new(0));
}

pub fn eglDisplay() ?*c.GstGLDisplay {
    return @ptrCast(egl_display.gst_gl_display_egl_new());
}

pub fn eglSurfacelessDisplay() ?*c.GstGLDisplay {
    return @ptrCast(egl_display.gst_gl_display_egl_new_surfaceless());
}

pub fn memoryInit() void {
    c.gst_gl_buffer_init_once();
    c.gst_gl_memory_pbo_init_once();
    c.gst_gl_renderbuffer_init_once();
    c.gst_gl_memory_egl_init_once();
}
