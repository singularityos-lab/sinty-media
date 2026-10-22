const std = @import("std");
const c = @import("../../c.zig").c;
const gtype = @import("../../gtype.zig");
const window = @import("../window.zig");
const gdisplay = @import("display.zig");
const utils = @import("utils.zig");
const egl_context = @import("../egl/context.zig");

const OWin = [*c]c.GstGLWindow;

pub const Win = extern struct {
    parent: c.GstGLWindow,
    gbm_surf: ?*c.struct_gbm_surface,
    current_bo: ?*c.struct_gbm_bo,
    prev_bo: ?*c.struct_gbm_bo,
    waiting_for_flip: c_int,
    saved_crtc: [*c]c.drmModeCrtc,
    display: ?*gdisplay.Gbm,
    _reserved: [c.GST_PADDING]c.gpointer,
};

var once: gtype.Once = .{};
var parent: ?*c.GstGLWindowClass = null;

fn gw(p: anytype) *Win {
    return @ptrCast(@alignCast(p));
}

fn dsp(w: OWin) *gdisplay.Gbm {
    return @ptrCast(@alignCast(w[0].display));
}

pub fn isGbm(w: anytype) bool {
    return gtype.instanceOf(w, typeGet());
}

fn getHandle(w: OWin) callconv(.c) c.guintptr {
    return @intFromPtr(gw(w).gbm_surf);
}

fn getDisplay(w: OWin) callconv(.c) c.guintptr {
    return c.gst_gl_display_get_handle(w[0].display);
}

fn setHandle(_: OWin, _: c.guintptr) callconv(.c) void {}

fn close(w: OWin) callconv(.c) void {
    const x = gw(w);
    if (x.saved_crtc != null) {
        const d = dsp(w);
        const crtc = x.saved_crtc;
        _ = c.drmModeSetCrtc(d.drm_fd, crtc[0].crtc_id, crtc[0].buffer_id, crtc[0].x, crtc[0].y, &d.connector[0].connector_id, 1, &crtc[0].mode);
        c.drmModeFreeCrtc(crtc);
        x.saved_crtc = null;
    }
    if (x.gbm_surf) |s| {
        if (x.current_bo) |bo| {
            c.gbm_surface_release_buffer(s, bo);
            x.current_bo = null;
        }
        c.gbm_surface_destroy(s);
        x.gbm_surf = null;
    }
    parent.?.close.?(w);
}

fn flipped(_: c_int, _: c_uint, _: c_uint, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    @as(*c_int, @ptrCast(@alignCast(data))).* = 0;
}

fn drawCb(data: c.gpointer) callconv(.c) void {
    const w: OWin = @ptrCast(@alignCast(data));
    const x = gw(w);
    const ctx = window.gst_gl_window_get_context(w);
    const cc = gtype.classPeek(c.GstGLContextClass, ctx);
    const d = dsp(w);
    var ev = std.mem.zeroes(c.drmEventContext);
    ev.version = c.DRM_EVENT_CONTEXT_VERSION;
    ev.page_flip_handler = flipped;
    var pfd = c.struct_pollfd{ .fd = d.drm_fd, .events = c.POLLIN, .revents = 0 };
    if (d.mode == null) {
        c.gst_object_unref(ctx);
        return;
    }
    if (x.current_bo == null) {
        cc.swap_buffers.?(ctx);
        x.current_bo = c.gbm_surface_lock_front_buffer(x.gbm_surf);
        const fb = utils.fbFromBo(x.current_bo);
        if (x.saved_crtc == null) x.saved_crtc = c.drmModeGetCrtc(d.drm_fd, d.crtc_id);
        if (c.drmModeSetCrtc(d.drm_fd, d.crtc_id, fb.?.fb_id, 0, 0, &d.connector[0].connector_id, 1, d.mode) != 0) {
            c.gst_object_unref(ctx);
            return;
        }
    }
    if (w[0].queue_resize != 0) {
        var width: c.guint = 0;
        var height: c.guint = 0;
        window.gst_gl_window_get_surface_dimensions(w, &width, &height);
        window.gst_gl_window_resize(w, width, height);
    }
    if (w[0].draw) |f| f(w[0].draw_data);
    cc.swap_buffers.?(ctx);
    c.gst_object_unref(ctx);
    const next = c.gbm_surface_lock_front_buffer(x.gbm_surf);
    const fb = utils.fbFromBo(next);
    while (x.waiting_for_flip != 0) {
        if (c.poll(&pfd, 1, -1) < 0) return;
        _ = c.drmHandleEvent(d.drm_fd, &ev);
    }
    if (x.prev_bo) |bo| c.gbm_surface_release_buffer(x.gbm_surf, bo);
    x.waiting_for_flip = 1;
    if (c.drmModePageFlip(d.drm_fd, d.crtc_id, fb.?.fb_id, c.DRM_MODE_PAGE_FLIP_EVENT, &x.waiting_for_flip) != 0) return;
    x.prev_bo = x.current_bo;
    x.current_bo = next;
}

fn draw(w: OWin) callconv(.c) void {
    window.gst_gl_window_send_message(w, drawCb, w);
}

pub fn createWindow(w: OWin) bool {
    const x = gw(w);
    const d = dsp(w);
    const ctx = window.gst_gl_window_get_context(w);
    defer c.gst_object_unref(ctx);
    const e: *egl_context.Egl = @ptrCast(@alignCast(ctx));
    const hd: c_int = if (d.mode != null) d.mode[0].hdisplay else 0;
    const vd: c_int = if (d.mode != null) d.mode[0].vdisplay else 0;
    var fmt: c.EGLint = 0;
    if (c.eglGetConfigAttrib(e.egl_display, e.egl_config, c.EGL_NATIVE_VISUAL_ID, &fmt) == 0) return false;
    x.gbm_surf = c.gbm_surface_create(d.gbm_dev, @bitCast(hd), @bitCast(vd), @bitCast(fmt), c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING);
    window.gst_gl_window_resize(w, @bitCast(hd), @bitCast(vd));
    window.gst_gl_window_queue_resize(w);
    return true;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const wc: *c.GstGLWindowClass = @ptrCast(@alignCast(k));
    wc.get_window_handle = getHandle;
    wc.get_display = getDisplay;
    wc.set_window_handle = setHandle;
    wc.close = close;
    wc.draw = draw;
}

pub fn typeGet() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(window.gst_gl_window_get_type, "GstGLWindowGBMEGL", c.GstGLWindowClass, Win, classInit, null, 0);
        }
    }.f);
}

pub fn new(d: [*c]c.GstGLDisplay) ?*c.GstGLWindow {
    if (c.gst_gl_display_get_handle_type(d) & c.GST_GL_DISPLAY_TYPE_GBM == 0) return null;
    return @ptrCast(@alignCast(c.g_object_new(typeGet(), @as([*c]const u8, null))));
}
