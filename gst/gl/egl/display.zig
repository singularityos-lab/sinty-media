const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const feature = @import("../feature.zig");
const display = @import("../display.zig");

comptime {
    @import("../../abi.zig").check(@This());
}

const Egl = c.GstGLDisplayEGL;
const Dev = c.GstGLDisplayEGLDevice;
const ODisp = [*c]c.GstGLDisplay;

const NAME = "gst.gl.display.egl";
const PLATFORM_X11 = 0x31D5;
const PLATFORM_WAYLAND = 0x31D8;
const PLATFORM_GBM = 0x31D7;
const PLATFORM_DEVICE = 0x313F;
const PLATFORM_SURFACELESS = 0x31DD;

const PlatformDisplay = *const fn (c.EGLenum, ?*anyopaque, [*c]const c.EGLint) callconv(.c) c.EGLDisplay;
const QueryDevices = *const fn (c.EGLint, [*c]c.EGLDeviceEXT, [*c]c.EGLint) callconv(.c) c.EGLBoolean;

var once: gtype.Once = .{};
var dev_once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;
var debug_done: usize = 0;

fn initDebug() void {
    if (c.g_once_init_enter(&debug_done) != 0) {
        _ = c._gst_debug_category_new("gldisplayegl", 0, "OpenGL EGL Display");
        c.g_once_init_leave(&debug_done, 1);
    }
}

fn eglHandle(d: ODisp) callconv(.c) c.guintptr {
    return @intFromPtr(@as(*Egl, @ptrCast(@alignCast(d))).display);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const e: *Egl = @ptrCast(@alignCast(o));
    if (e.display != null and e.foreign_display == 0) {
        _ = c.eglTerminate(e.display);
        e.display = null;
    }
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GstGLDisplayClass, @ptrCast(@alignCast(k))).get_handle = eglHandle;
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const e: *Egl = @ptrCast(@alignCast(inst));
    e.parent.type = c.GST_GL_DISPLAY_TYPE_EGL;
    e.foreign_display = 0;
    c.gst_gl_memory_egl_init_once();
}

pub export fn gst_gl_display_egl_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(display.gst_gl_display_get_type, "GstGLDisplayEGL", c.GstGLDisplayEGLClass, Egl, classInit, init, 0);
        }
    }.f);
}

pub fn isEgl(p: anytype) bool {
    return gtype.instanceOf(p, gst_gl_display_egl_get_type());
}

pub export fn gst_gl_display_egl_get_from_native(t: c.GstGLDisplayType, native: c.guintptr) c.gpointer {
    const fname = "gst_gl_display_egl_get_from_native";
    if (!check.that(t != c.GST_GL_DISPLAY_TYPE_NONE, fname, "type != GST_GL_DISPLAY_TYPE_NONE")) return null;
    const anyish = t == c.GST_GL_DISPLAY_TYPE_ANY or t == c.GST_GL_DISPLAY_TYPE_EGL_SURFACELESS;
    if (!check.that((!anyish and native != 0) or (anyish and native == 0), fname, "(type != GST_GL_DISPLAY_TYPE_ANY && type != GST_GL_DISPLAY_TYPE_EGL_SURFACELESS && display != 0) || ((type == GST_GL_DISPLAY_TYPE_ANY || type == GST_GL_DISPLAY_TYPE_EGL_SURFACELESS) && display == 0)")) return null;
    initDebug();
    if (t == c.GST_GL_DISPLAY_TYPE_EGL) return @ptrFromInt(native);
    const nd: ?*anyopaque = @ptrFromInt(native);
    if (platformDisplay(t, nd)) |r| return r;
    return c.eglGetDisplay(@ptrFromInt(native));
}

fn platformDisplay(t: c.GstGLDisplayType, nd: ?*anyopaque) c.EGLDisplay {
    const exts = c.eglQueryString(c.EGL_NO_DISPLAY, c.EGL_EXTENSIONS);
    if (c.eglGetError() != c.EGL_SUCCESS or exts == null) return null;
    const has = struct {
        fn f(e: [*c]const u8, n: [*:0]const u8) bool {
            return feature.gst_gl_check_extension(n, e) != 0;
        }
    }.f;
    if (!has(exts, "EGL_KHR_client_get_all_proc_addresses")) return null;
    if (!has(exts, "EGL_EXT_platform_base")) return null;
    var get: ?PlatformDisplay = @ptrCast(c.eglGetProcAddress("eglGetPlatformDisplay"));
    if (get == null) get = @ptrCast(c.eglGetProcAddress("eglGetPlatformDisplayEXT"));
    const f = get orelse return null;
    var r: c.EGLDisplay = null;
    if (r == null and t & c.GST_GL_DISPLAY_TYPE_X11 != 0 and (has(exts, "EGL_KHR_platform_x11") or has(exts, "EGL_EXT_platform_x11"))) r = f(PLATFORM_X11, nd, null);
    if (r == null and t & c.GST_GL_DISPLAY_TYPE_WAYLAND != 0 and (has(exts, "EGL_KHR_platform_wayland") or has(exts, "EGL_EXT_platform_wayland"))) r = f(PLATFORM_WAYLAND, nd, null);
    if (r == null and t & c.GST_GL_DISPLAY_TYPE_GBM != 0 and (has(exts, "EGL_MESA_platform_gbm") or has(exts, "EGL_KHR_platform_gbm"))) r = f(PLATFORM_GBM, nd, null);
    if (r == null and t & c.GST_GL_DISPLAY_TYPE_EGL_DEVICE != 0 and has(exts, "EGL_EXT_device_base") and has(exts, "EGL_EXT_platform_device")) r = f(PLATFORM_DEVICE, nd, null);
    if (r == null and t & c.GST_GL_DISPLAY_TYPE_EGL_SURFACELESS != 0 and has(exts, "EGL_MESA_platform_surfaceless")) r = f(PLATFORM_SURFACELESS, nd, null);
    return r;
}

fn make(d: c.gpointer) *Egl {
    const o = c.g_object_new(gst_gl_display_egl_get_type(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    const e: *Egl = @ptrCast(@alignCast(o));
    e.display = d;
    return e;
}

pub export fn gst_gl_display_egl_new() [*c]Egl {
    initDebug();
    const d = gst_gl_display_egl_get_from_native(c.GST_GL_DISPLAY_TYPE_ANY, 0) orelse return null;
    return make(d);
}

pub export fn gst_gl_display_egl_new_surfaceless() [*c]Egl {
    initDebug();
    const d = gst_gl_display_egl_get_from_native(c.GST_GL_DISPLAY_TYPE_EGL_SURFACELESS, 0) orelse return null;
    return make(d);
}

pub export fn gst_gl_display_egl_new_with_egl_display(d: c.gpointer) [*c]Egl {
    if (!check.that(d != null, "gst_gl_display_egl_new_with_egl_display", "display != NULL")) return null;
    initDebug();
    const e = make(d);
    e.foreign_display = 1;
    return e;
}

fn refIfSet(data: c.gpointer, _: c.gpointer) callconv(.c) c.gpointer {
    if (data != null) _ = c.gst_object_ref(data);
    return data;
}

pub export fn gst_gl_display_egl_from_gl_display(d: ODisp) [*c]Egl {
    const fname = "gst_gl_display_egl_from_gl_display";
    if (!check.that(display.isDisplay(d), fname, "GST_IS_GL_DISPLAY (display)")) return null;
    initDebug();
    if (isEgl(d)) return @ptrCast(@alignCast(c.gst_object_ref(d)));
    const prev = c.g_object_dup_data(@ptrCast(d), NAME, refIfSet, null);
    if (prev != null and isEgl(prev)) return @ptrCast(@alignCast(prev));
    if (prev != null) c.gst_object_unref(prev);
    const t = display.gst_gl_display_get_handle_type(d);
    const native = display.gst_gl_display_get_handle(d);
    if (!check.that(native != 0, fname, "native_display != 0")) return null;
    if (!check.that(t != c.GST_GL_DISPLAY_TYPE_NONE, fname, "display_type != GST_GL_DISPLAY_TYPE_NONE")) return null;
    const o = c.g_object_new(gst_gl_display_egl_get_type(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    const e: *Egl = @ptrCast(@alignCast(o));
    e.display = gst_gl_display_egl_get_from_native(t, native);
    if (e.display == null) {
        c.gst_object_unref(e);
        return null;
    }
    c.g_object_set_data_full(@ptrCast(d), NAME, c.gst_object_ref(e), c.gst_object_unref);
    return e;
}

pub export fn gst_gl_display_egl_set_foreign(e: [*c]Egl, foreign: c.gboolean) void {
    if (!check.that(isEgl(e), "gst_gl_display_egl_set_foreign", "GST_IS_GL_DISPLAY_EGL (display_egl)")) return;
    c.g_mutex_lock(&e[0].parent.object.lock);
    e[0].foreign_display = foreign;
    c.g_mutex_unlock(&e[0].parent.object.lock);
}

fn devHandle(d: ODisp) callconv(.c) c.guintptr {
    return @intFromPtr(@as(*Dev, @ptrCast(@alignCast(d))).device);
}

fn devClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    @as(*c.GstGLDisplayClass, @ptrCast(@alignCast(k))).get_handle = devHandle;
}

fn devInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const d: *Dev = @ptrCast(@alignCast(inst));
    d.parent.type = c.GST_GL_DISPLAY_TYPE_EGL_DEVICE;
    c.gst_gl_memory_egl_init_once();
}

pub export fn gst_gl_display_egl_device_get_type() c.GType {
    return dev_once.get(struct {
        fn f() c.GType {
            return gtype.object(display.gst_gl_display_get_type, "GstGLDisplayEGLDevice", c.GstGLDisplayEGLDeviceClass, Dev, devClassInit, devInit, 0);
        }
    }.f);
}

fn devMake(device: c.gpointer) *Dev {
    const o = c.g_object_new(gst_gl_display_egl_device_get_type(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(o);
    const d: *Dev = @ptrCast(@alignCast(o));
    d.device = device;
    return d;
}

pub export fn gst_gl_display_egl_device_new(index: c.guint) [*c]Dev {
    const q: QueryDevices = @ptrCast(c.eglGetProcAddress("eglQueryDevicesEXT") orelse return null);
    var n: c.EGLint = 0;
    if (q(0, null, &n) == c.EGL_FALSE or n < 1) return null;
    if (@as(c.guint, @intCast(n)) <= index) return null;
    const list = std.heap.c_allocator.alloc(c.EGLDeviceEXT, @intCast(n)) catch return null;
    defer std.heap.c_allocator.free(list);
    _ = q(n, list.ptr, &n);
    return devMake(list[index]);
}

pub export fn gst_gl_display_egl_device_new_with_egl_device(device: c.gpointer) [*c]Dev {
    if (!check.that(device != null, "gst_gl_display_egl_device_new_with_egl_device", "device != NULL")) return null;
    return devMake(device);
}
