const c = @import("../c.zig").c;
const egl_context = @import("egl/context.zig");
const egl_display = @import("egl/display.zig");
const x11_window = @import("x11/window.zig");
const x11_display = @import("x11/display.zig");
const glx = @import("x11/glx.zig");
const wl_window = @import("wayland/window.zig");
const wl_display = @import("wayland/display.zig");
const gbm_window = @import("gbm/window.zig");
const gbm_display = @import("gbm/display.zig");

pub fn x11Window(d: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    return x11_window.new(d);
}

pub fn waylandWindow(d: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    return wl_window.new(d);
}

pub fn gbmWindow(d: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    return gbm_window.new(d);
}

pub fn isWaylandWindow(w: [*c]c.GstGLWindow) bool {
    return wl_window.isWayland(w);
}

pub fn createNativeWindow(w: [*c]c.GstGLWindow) void {
    if (x11_window.isX11(w)) _ = x11_window.createWindow(w);
    if (wl_window.isWayland(w)) wl_window.createWindow(w);
    if (gbm_window.isGbm(w)) _ = gbm_window.createWindow(w);
}

pub fn matchVisual(ctx: [*c]c.GstGLContext, err: [*c][*c]c.GError) bool {
    if (!x11_window.isX11(ctx[0].window)) return true;
    const w = c.gst_gl_context_get_window(ctx);
    defer c.gst_object_unref(w);
    return x11_window.matchVisual(w, err);
}

pub fn glxContext(d: [*c]c.GstGLDisplay) ?*c.GstGLContext {
    return glx.new(d);
}

pub fn eglContext(_: [*c]c.GstGLDisplay) ?*c.GstGLContext {
    return egl_context.new();
}

pub const glxCurrent = glx.currentContext;

pub const eglCurrent = egl_context.currentContext;

pub const glxProc = glx.procAddress;

pub const eglProc = egl_context.procAddress;

pub const glxFillInfo = glx.fillInfo;

pub const eglFillInfo = egl_context.fillInfo;

pub fn waylandDisplay() ?*c.GstGLDisplay {
    return @ptrCast(wl_display.gst_gl_display_wayland_new(null));
}

pub fn x11Display() ?*c.GstGLDisplay {
    return @ptrCast(x11_display.gst_gl_display_x11_new(null));
}

pub fn gbmDisplay() ?*c.GstGLDisplay {
    return gbm_display.new();
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
