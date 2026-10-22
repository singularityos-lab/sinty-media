const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const context = @import("../context.zig");
const edisplay = @import("display.zig");
const egl_context = @import("context.zig");

comptime {
    @import("../../abi.zig").check(@This());
}

const Img = c.GstEGLImage;
const OImg = [*c]Img;
const OCtx = [*c]c.GstGLContext;

const DMA_BUF = 0x3270;
const DRM_FOURCC = 0x3271;
const PLANE_FD = [3]c.guintptr{ 0x3272, 0x3275, 0x3278 };
const PLANE_OFFSET = [3]c.guintptr{ 0x3273, 0x3276, 0x3279 };
const PLANE_PITCH = [3]c.guintptr{ 0x3274, 0x3277, 0x327A };
const PLANE_MOD_LO = [3]c.guintptr{ 0x3443, 0x3445, 0x3447 };
const PLANE_MOD_HI = [3]c.guintptr{ 0x3444, 0x3446, 0x3448 };
const REC601 = 0x327F;
const REC709 = 0x3280;
const REC2020 = 0x3281;
const SAMPLE_RANGE_HINT = 0x327C;
const COLOR_SPACE_HINT = 0x327B;
const FULL_RANGE = 0x3282;
const NARROW_RANGE = 0x3283;
const GL_TEXTURE_2D_KHR = 0x30B1;
const MOD_INVALID: u64 = 0x00ffffffffffffff;

fn fourcc(comptime s: *const [4]u8) c.gint {
    return @bitCast(@as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24);
}

var once: gtype.Once = .{};
var cat_done: usize = 0;

fn ensureCat() void {
    if (c.g_once_init_enter(&cat_done) != 0) {
        _ = c._gst_debug_category_new("gleglimage", 0, "EGLImage wrapper");
        c.g_once_init_leave(&cat_done, 1);
    }
}

pub export fn gst_egl_image_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstEGLImage", @ptrCast(&c.gst_mini_object_ref), @ptrCast(&c.gst_mini_object_unref));
        }
    }.f);
}

fn isImage(p: OImg) bool {
    return p != null and p[0].parent.type == gst_egl_image_get_type();
}

pub export fn gst_egl_image_get_image(img: OImg) c.gpointer {
    if (!check.that(isImage(img), "gst_egl_image_get_image", "GST_IS_EGL_IMAGE (image)")) return null;
    return img[0].image;
}

fn freeThread(_: OCtx, data: c.gpointer) callconv(.c) void {
    const img: OImg = @ptrCast(@alignCast(data));
    if (img[0].destroy_notify) |f| f(img, img[0].destroy_data);
}

fn freeImage(o: [*c]c.GstMiniObject) callconv(.c) void {
    const img: OImg = @ptrCast(@alignCast(o));
    if (img[0].context != null) {
        c.gst_gl_context_thread_add(img[0].context, freeThread, img);
        c.gst_object_unref(img[0].context);
    }
    c.g_free(img);
}

fn copyImage(o: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    return c.gst_mini_object_ref(@constCast(o));
}

pub export fn gst_egl_image_new_wrapped(ctx: OCtx, image: c.gpointer, fmt: c.GstGLFormat, user_data: c.gpointer, notify: c.GstEGLImageDestroyNotify) OImg {
    const fname = "gst_egl_image_new_wrapped";
    if (!check.that(ctx != null, fname, "context != NULL")) return null;
    if (!check.that(context.gst_gl_context_get_gl_platform(ctx) & c.GST_GL_PLATFORM_EGL != 0, fname, "(gst_gl_context_get_gl_platform (context) & GST_GL_PLATFORM_EGL) != 0")) return null;
    if (!check.that(image != null, fname, "image != EGL_NO_IMAGE_KHR")) return null;
    const img: OImg = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Img))));
    c.gst_mini_object_init(@ptrCast(img), 0, gst_egl_image_get_type(), copyImage, null, freeImage);
    img[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    img[0].image = image;
    img[0].format = fmt;
    img[0].destroy_data = user_data;
    img[0].destroy_notify = notify;
    return img;
}

fn eglDisplay(ctx: OCtx) ?c.EGLDisplay {
    const d = edisplay.gst_gl_display_egl_from_gl_display(ctx[0].display);
    if (d == null) return null;
    const h: c.EGLDisplay = @ptrFromInt(c.gst_gl_display_get_handle(@ptrCast(d)));
    c.gst_object_unref(d);
    return h;
}

fn egl15(ctx: OCtx) bool {
    var maj: c.gint = 0;
    var min: c.gint = 0;
    context.gst_gl_context_get_gl_platform_version(ctx, &maj, &min);
    return maj > 1 or (maj == 1 and min >= 5);
}

const CreateImage = *const fn (c.EGLDisplay, c.EGLContext, c.EGLenum, c.EGLClientBuffer, [*c]const c.EGLAttrib) callconv(.c) c.EGLImageKHR;
const CreateImageKHR = *const fn (c.EGLDisplay, c.EGLContext, c.EGLenum, c.EGLClientBuffer, [*c]const c.EGLint) callconv(.c) c.EGLImageKHR;
const DestroyImage = *const fn (c.EGLDisplay, c.EGLImageKHR) callconv(.c) c.EGLBoolean;

fn create(ctx: OCtx, target: c.guint, buf: c.EGLClientBuffer, attribs: ?[]const c.guintptr) c.EGLImageKHR {
    const dpy = eglDisplay(ctx) orelse return null;
    const ectx: c.EGLContext = if (target != DMA_BUF) @ptrFromInt(context.gst_gl_context_get_gl_context(ctx)) else null;
    const al = std.heap.c_allocator;
    if (egl15(ctx)) {
        const f: CreateImage = @ptrCast(context.gst_gl_context_get_proc_address(ctx, "eglCreateImage") orelse return null);
        var list: ?[]c.EGLAttrib = null;
        defer if (list) |l| al.free(l);
        if (attribs) |a| {
            list = al.alloc(c.EGLAttrib, a.len) catch return null;
            for (a, 0..) |v, i| list.?[i] = @bitCast(v);
        }
        return f(dpy, ectx, target, buf, if (list) |l| l.ptr else null);
    }
    if (context.gst_gl_context_check_feature(ctx, "EGL_KHR_image_base") != 0) {
        const f: CreateImageKHR = @ptrCast(context.gst_gl_context_get_proc_address(ctx, "eglCreateImageKHR") orelse return null);
        var list: ?[]c.EGLint = null;
        defer if (list) |l| al.free(l);
        if (attribs) |a| {
            list = al.alloc(c.EGLint, a.len) catch return null;
            for (a, 0..) |v, i| list.?[i] = @truncate(@as(isize, @bitCast(v)));
        }
        return f(dpy, ectx, target, buf, if (list) |l| l.ptr else null);
    }
    return null;
}

fn destroyImage(ctx: OCtx, image: c.EGLImageKHR) void {
    var f: ?DestroyImage = null;
    if (egl15(ctx)) {
        f = @ptrCast(context.gst_gl_context_get_proc_address(ctx, "eglDestroyImage"));
    } else if (context.gst_gl_context_check_feature(ctx, "EGL_KHR_image_base") != 0) {
        f = @ptrCast(context.gst_gl_context_get_proc_address(ctx, "eglDestroyImageKHR"));
    } else return;
    const d = f orelse return;
    const dpy = eglDisplay(ctx) orelse return;
    _ = d(dpy, image);
}

fn destroyCb(img: OImg, _: c.gpointer) callconv(.c) void {
    destroyImage(img[0].context, img[0].image);
}

pub export fn gst_egl_image_from_texture(ctx: OCtx, mem: [*c]c.GstGLMemory, attribs: [*c]c.guintptr) OImg {
    ensureCat();
    if (mem[0].tex_target != c.GST_GL_TEXTURE_TARGET_2D) return null;
    var a: ?[]const c.guintptr = null;
    if (attribs != null) {
        var n: usize = 0;
        while (true) {
            n += 1;
            if (attribs[n - 1] == c.EGL_NONE) break;
        }
        a = attribs[0..n];
    }
    const img = create(ctx, GL_TEXTURE_2D_KHR, @ptrFromInt(mem[0].tex_id), a);
    if (img == null) return null;
    return gst_egl_image_new_wrapped(ctx, img, mem[0].tex_format, null, destroyCb);
}

fn drmFourcc(f: c.GstVideoFormat, plane: c.gint, out: *c.GstGLFormat) c.gint {
    const rgba = fourcc("AB24");
    const rgb = fourcc("BG24");
    const rg = fourcc("GR88");
    const rg16 = fourcc("GR32");
    const rgb10a2 = fourcc("AB30");
    const r8 = fourcc("R8  ");
    const r16 = fourcc("R16 ");
    switch (f) {
        c.GST_VIDEO_FORMAT_RGB16, c.GST_VIDEO_FORMAT_BGR16 => {
            out.* = c.GST_GL_RGB565;
            return fourcc("RG16");
        },
        c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_BGR => {
            out.* = c.GST_GL_RGB;
            return rgb;
        },
        c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_RGBx, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_xRGB, c.GST_VIDEO_FORMAT_ABGR, c.GST_VIDEO_FORMAT_xBGR, c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_VUYA => {
            out.* = c.GST_GL_RGBA;
            return rgba;
        },
        c.GST_VIDEO_FORMAT_GRAY8 => {
            out.* = c.GST_GL_RED;
            return r8;
        },
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_GRAY16_BE => {
            out.* = c.GST_GL_RG;
            return rg;
        },
        c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV61, c.GST_VIDEO_FORMAT_NV12_16L32S, c.GST_VIDEO_FORMAT_NV12_4L4, c.GST_VIDEO_FORMAT_NV24 => {
            out.* = if (plane == 0) c.GST_GL_RED else c.GST_GL_RG;
            return if (plane == 0) r8 else rg;
        },
        c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_YV12, c.GST_VIDEO_FORMAT_Y41B, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_Y444 => {
            out.* = c.GST_GL_RED;
            return r8;
        },
        c.GST_VIDEO_FORMAT_BGR10A2_LE, c.GST_VIDEO_FORMAT_BGR10x2_LE => {
            out.* = c.GST_GL_RGB10_A2;
            return fourcc("BA30");
        },
        c.GST_VIDEO_FORMAT_RGB10A2_LE, c.GST_VIDEO_FORMAT_RGB10x2_LE => {
            out.* = c.GST_GL_RGB10_A2;
            return fourcc("RA30");
        },
        c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_P012_LE, c.GST_VIDEO_FORMAT_P016_LE => {
            out.* = if (plane == 0) c.GST_GL_R16 else c.GST_GL_RG16;
            return if (plane == 0) r16 else rg16;
        },
        c.GST_VIDEO_FORMAT_P010_10BE, c.GST_VIDEO_FORMAT_P012_BE, c.GST_VIDEO_FORMAT_P016_BE => {
            out.* = if (plane == 0) c.GST_GL_R16 else c.GST_GL_RG16;
            return if (plane == 0) r16 else fourcc("RG32");
        },
        c.GST_VIDEO_FORMAT_I420_10LE, c.GST_VIDEO_FORMAT_I422_10LE, c.GST_VIDEO_FORMAT_Y444_10LE, c.GST_VIDEO_FORMAT_I420_12LE, c.GST_VIDEO_FORMAT_I422_12LE, c.GST_VIDEO_FORMAT_Y444_12LE, c.GST_VIDEO_FORMAT_Y444_16LE => {
            out.* = c.GST_GL_R16;
            return r16;
        },
        c.GST_VIDEO_FORMAT_AV12 => {
            out.* = if (plane == 1) c.GST_GL_RED else c.GST_GL_RG;
            return if (plane == 1) rg else r8;
        },
        c.GST_VIDEO_FORMAT_Y210 => {
            out.* = c.GST_GL_RG16;
            return rg16;
        },
        c.GST_VIDEO_FORMAT_Y212_LE => {
            out.* = c.GST_GL_RG16;
            return fourcc("GR32");
        },
        c.GST_VIDEO_FORMAT_Y212_BE => {
            out.* = c.GST_GL_RG16;
            return fourcc("RG32");
        },
        c.GST_VIDEO_FORMAT_Y410 => {
            out.* = c.GST_GL_RGB10_A2;
            return rgb10a2;
        },
        c.GST_VIDEO_FORMAT_Y412_LE => {
            out.* = c.GST_GL_RGBA16;
            return fourcc("AB48");
        },
        else => return -1,
    }
}

fn eglStride(info: *const c.GstVideoInfo, plane: usize) c.gint {
    const stride = info.stride[plane];
    if (info.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_TILED == 0) return stride;
    return (stride & 0xffff) * @as(c.gint, @bitCast(info.finfo[0].tile_info[plane].stride));
}

fn fieldHeight(info: *const c.GstVideoInfo) c.gint {
    if (info.interlace_mode == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) return @divTrunc(info.height + 1, 2);
    return info.height;
}

fn sub(scale: c.guint, v: c.gint) c.gint {
    return -((-v) >> @intCast(scale));
}

fn int(v: anytype) c.guintptr {
    return @bitCast(@as(isize, @intCast(v)));
}

pub export fn gst_egl_image_from_dmabuf(ctx: OCtx, fd: c.gint, info_in: [*c]const c.GstVideoInfo, plane: c.gint, offset: c.gsize) OImg {
    ensureCat();
    const info: *const [1]c.GstVideoInfo = @ptrCast(info_in);
    var comp: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
    c.gst_video_format_info_component(info[0].finfo, @bitCast(plane), &comp);
    var fmt: c.GstGLFormat = 0;
    const fcc = drmFourcc(info[0].finfo[0].format, plane, &fmt);
    const mods = context.gst_gl_context_check_feature(ctx, "EGL_EXT_image_dma_buf_import_modifiers") != 0;
    const ci: usize = @intCast(comp[0]);
    var a: [17]c.guintptr = undefined;
    var n: usize = 0;
    const vals = [_]c.guintptr{ c.EGL_WIDTH, int(sub(info[0].finfo[0].w_sub[ci], info[0].width)), c.EGL_HEIGHT, int(sub(info[0].finfo[0].h_sub[ci], fieldHeight(&info[0]))), DRM_FOURCC, int(fcc), PLANE_FD[0], int(fd), PLANE_OFFSET[0], offset, PLANE_PITCH[0], int(eglStride(&info[0], @intCast(plane))) };
    for (vals) |v| {
        a[n] = v;
        n += 1;
    }
    if (mods) {
        for ([_]c.guintptr{ PLANE_MOD_LO[0], 0, PLANE_MOD_HI[0], 0 }) |v| {
            a[n] = v;
            n += 1;
        }
    }
    a[n] = c.EGL_NONE;
    const img = create(ctx, DMA_BUF, null, a[0 .. n + 1]);
    if (img == null) return null;
    return gst_egl_image_new_wrapped(ctx, img, fmt, null, destroyCb);
}

pub fn checkDirectDrm(ctx: OCtx, dma: *const c.GstVideoInfoDmaDrm, target: c.GstGLTextureTarget) bool {
    const fcc = dma.drm_fourcc;
    if (fcc == 0) return false;
    var mods: ?*const c.GArray = null;
    if (!egl_context.formatModifiers(ctx, @bitCast(fcc), &mods)) return false;
    const linear = [_]egl_context.Modifier{.{ .modifier = 0, .external_only = 0 }};
    const list: []const egl_context.Modifier = if (mods) |m| @as([*]const egl_context.Modifier, @ptrCast(@alignCast(m.data)))[0..m.len] else &linear;
    for (list) |m| {
        if (m.modifier == dma.drm_modifier) return m.external_only == 0 or target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES;
    }
    return false;
}

pub fn checkDirect(ctx: OCtx, info: *const c.GstVideoInfo, target: c.GstGLTextureTarget) bool {
    var dma: c.GstVideoInfoDmaDrm = undefined;
    if (c.gst_video_info_dma_drm_from_video_info(&dma, info, 0) == 0) return false;
    return checkDirectDrm(ctx, &dma, target);
}

pub export fn gst_egl_image_from_dmabuf_direct_target(ctx: OCtx, fd: [*c]c.gint, offset: [*c]const c.gsize, info: [*c]const c.GstVideoInfo, target: c.GstGLTextureTarget) OImg {
    ensureCat();
    var dma: c.GstVideoInfoDmaDrm = undefined;
    if (c.gst_video_info_dma_drm_from_video_info(&dma, info, 0) == 0) return null;
    return gst_egl_image_from_dmabuf_direct_target_with_dma_drm(ctx, info[0].finfo[0].n_planes, fd, offset, &dma, target);
}

pub export fn gst_egl_image_from_dmabuf_direct_target_with_dma_drm(ctx: OCtx, n_planes: c.guint, fd: [*c]c.gint, offset: [*c]const c.gsize, dma: [*c]const c.GstVideoInfoDmaDrm, target: c.GstGLTextureTarget) OImg {
    ensureCat();
    const d: *const c.GstVideoInfoDmaDrm = @ptrCast(dma);
    const info = &d.vinfo;
    if (!checkDirectDrm(ctx, d, target)) return null;
    const fcc = dma[0].drm_fourcc;
    const modifier = dma[0].drm_modifier;
    const mods = context.gst_gl_context_check_feature(ctx, "EGL_EXT_image_dma_buf_import_modifiers") != 0;
    if (!mods and modifier != 0) return null;
    if (n_planes > 3) return null;
    var a: [41]c.guintptr = undefined;
    var n: usize = 0;
    const push = struct {
        fn f(buf: *[41]c.guintptr, k: *usize, v: c.guintptr) void {
            buf[k.*] = v;
            k.* += 1;
        }
    }.f;
    push(&a, &n, c.EGL_WIDTH);
    push(&a, &n, int(info.width));
    push(&a, &n, c.EGL_HEIGHT);
    push(&a, &n, int(info.height));
    push(&a, &n, DRM_FOURCC);
    push(&a, &n, fcc);
    var p: usize = 0;
    while (p < @max(n_planes, 1) and p < 3) : (p += 1) {
        push(&a, &n, PLANE_FD[p]);
        push(&a, &n, int(fd[p]));
        push(&a, &n, PLANE_OFFSET[p]);
        push(&a, &n, offset[p]);
        push(&a, &n, PLANE_PITCH[p]);
        push(&a, &n, int(eglStride(info, p)));
        if (mods and modifier != MOD_INVALID) {
            push(&a, &n, PLANE_MOD_LO[p]);
            push(&a, &n, @truncate(modifier & 0xffffffff));
            push(&a, &n, PLANE_MOD_HI[p]);
            push(&a, &n, @truncate((modifier >> 32) & 0xffffffff));
        }
    }
    const cs: c.guintptr = switch (info.colorimetry.matrix) {
        c.GST_VIDEO_COLOR_MATRIX_BT601 => REC601,
        c.GST_VIDEO_COLOR_MATRIX_BT709 => REC709,
        c.GST_VIDEO_COLOR_MATRIX_BT2020 => REC2020,
        else => 0,
    };
    if (cs != 0) {
        push(&a, &n, COLOR_SPACE_HINT);
        push(&a, &n, cs);
    }
    const range: c.guintptr = switch (info.colorimetry.range) {
        c.GST_VIDEO_COLOR_RANGE_0_255 => FULL_RANGE,
        c.GST_VIDEO_COLOR_RANGE_16_235 => NARROW_RANGE,
        else => 0,
    };
    if (range != 0) {
        push(&a, &n, SAMPLE_RANGE_HINT);
        push(&a, &n, range);
    }
    a[n] = c.EGL_NONE;
    const img = create(ctx, DMA_BUF, null, a[0 .. n + 1]);
    if (img == null) return null;
    return gst_egl_image_new_wrapped(ctx, img, c.GST_GL_RGBA, null, destroyCb);
}

pub export fn gst_egl_image_from_dmabuf_direct(ctx: OCtx, fd: [*c]c.gint, offset: [*c]const c.gsize, info: [*c]const c.GstVideoInfo) OImg {
    return gst_egl_image_from_dmabuf_direct_target(ctx, fd, offset, info, c.GST_GL_TEXTURE_TARGET_2D);
}

const ExportQuery = *const fn (c.EGLDisplay, c.EGLImageKHR, [*c]c_int, [*c]c_int, [*c]u64) callconv(.c) c.EGLBoolean;
const ExportImage = *const fn (c.EGLDisplay, c.EGLImageKHR, [*c]c_int, [*c]c.EGLint, [*c]c.EGLint) callconv(.c) c.EGLBoolean;

pub export fn gst_egl_image_export_dmabuf(img: OImg, fd: [*c]c_int, stride: [*c]c.gint, offset: [*c]c.gsize) c.gboolean {
    const ctx = img[0].context;
    const q: ?ExportQuery = @ptrCast(context.gst_gl_context_get_proc_address(ctx, "eglExportDMABUFImageQueryMESA"));
    const e: ?ExportImage = @ptrCast(context.gst_gl_context_get_proc_address(ctx, "eglExportDMABUFImageMESA"));
    if (q == null or e == null) return 0;
    const dpy = eglDisplay(ctx) orelse return 0;
    var fcc: c_int = 0;
    var planes: c_int = 0;
    var mods = [_]u64{0} ** c.GST_VIDEO_MAX_PLANES;
    if (q.?(dpy, img[0].image, &fcc, &planes, &mods) == 0) return 0;
    if (planes > 1) return 0;
    if (mods[0] != 0) return 0;
    var efd: c_int = 0;
    var es: c.EGLint = 0;
    var eo: c.EGLint = 0;
    if (e.?(dpy, img[0].image, &efd, &es, &eo) == 0) return 0;
    fd[0] = efd;
    stride[0] = es;
    offset[0] = @bitCast(@as(isize, eo));
    return 1;
}

pub export fn gst_egl_image_can_emulate(ctx: OCtx, f: c.GstVideoFormat) c.gboolean {
    const info = c.gst_video_format_get_info(f);
    var i: c.guint = 0;
    while (i != info[0].n_planes) : (i += 1) {
        var out: c.GstGLFormat = 0;
        const fcc = drmFourcc(f, @bitCast(i), &out);
        if (fcc == -1) return 0;
        if (info[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV != 0) {
            if (!egl_context.supportsModifierFor(ctx, @bitCast(fcc), 0, false)) return 0;
        } else if (info[0].flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0) {
            var mods: ?*const c.GArray = null;
            if (!egl_context.formatModifiers(ctx, fcc, &mods)) return 0;
            const linear = [_]egl_context.Modifier{.{ .modifier = 0, .external_only = 0 }};
            const list: []const egl_context.Modifier = if (mods) |m| @as([*]const egl_context.Modifier, @ptrCast(@alignCast(m.data)))[0..m.len] else &linear;
            var found = false;
            for (list) |m| {
                if (m.external_only == 0) {
                    found = true;
                    break;
                }
            }
            if (!found) return 0;
        } else return 0;
    }
    return 1;
}
