const c = @import("../c.zig").c;
const check = @import("check.zig");
const context = @import("context.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const OCtx = [*c]c.GstGLContext;
const RECTANGLE = 0x84F5;
const EXTERNAL_OES = 0x8D65;
const UINT_2_10_10_10_REV = 0x8368;

const ver = context.gst_gl_context_check_gl_version;
const feat = context.gst_gl_context_check_feature;

fn opengl(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_OPENGL, 1, 0) != 0;
}

fn opengl3(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_OPENGL3, 3, 1) != 0;
}

fn gles2(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_GLES2, 2, 0) != 0;
}

fn gles3(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_GLES2, 3, 0) != 0;
}

fn has(ctx: OCtx, name: [*:0]const u8) bool {
    return feat(ctx, name) != 0;
}

fn formatComponents(f: c.guint) c.guint {
    return switch (f) {
        c.GST_VIDEO_GL_TEXTURE_TYPE_RGBA, c.GST_GL_RGBA, c.GST_GL_RGBA8, c.GST_GL_RGBA16, c.GST_GL_RGB10_A2 => 4,
        c.GST_VIDEO_GL_TEXTURE_TYPE_RGB, c.GST_VIDEO_GL_TEXTURE_TYPE_RGB16, c.GST_GL_RGB, c.GST_GL_RGB8, c.GST_GL_RGB16, c.GST_GL_RGB565 => 3,
        c.GST_VIDEO_GL_TEXTURE_TYPE_LUMINANCE_ALPHA, c.GST_VIDEO_GL_TEXTURE_TYPE_RG, c.GST_GL_LUMINANCE_ALPHA, c.GST_GL_RG, c.GST_GL_RG8, c.GST_GL_RG16 => 2,
        c.GST_VIDEO_GL_TEXTURE_TYPE_LUMINANCE, c.GST_VIDEO_GL_TEXTURE_TYPE_R, c.GST_GL_LUMINANCE, c.GST_GL_ALPHA, c.GST_GL_RED, c.GST_GL_R8, c.GST_GL_R16 => 1,
        else => 0,
    };
}

fn typeComponents(t: c.guint) c.guint {
    return switch (t) {
        c.GL_UNSIGNED_BYTE, c.GL_UNSIGNED_SHORT => 1,
        c.GL_UNSIGNED_SHORT_5_6_5 => 3,
        UINT_2_10_10_10_REV => 4,
        else => check.assertFail("gstglformat.c", 105, "_gl_type_n_components", null),
    };
}

fn typeBytes(t: c.guint) c.guint {
    return switch (t) {
        c.GL_UNSIGNED_BYTE => 1,
        c.GL_UNSIGNED_SHORT, c.GL_UNSIGNED_SHORT_5_6_5 => 2,
        UINT_2_10_10_10_REV => 4,
        else => check.assertFail("gstglformat.c", 122, "_gl_type_n_bytes", null),
    };
}

pub export fn gst_gl_format_type_n_bytes(format: c.guint, t: c.guint) c.guint {
    return formatComponents(format) / typeComponents(t) * typeBytes(t);
}

pub export fn gst_gl_format_from_video_info(ctx: OCtx, vinfo: [*c]const c.GstVideoInfo, plane: c.guint) c.GstGLFormat {
    const rg = has(ctx, "GL_EXT_texture_rg") or ver(ctx, c.GST_GL_API_GLES2, 3, 0) != 0 or has(ctx, "GL_ARB_texture_rg") or ver(ctx, c.GST_GL_API_OPENGL3, 3, 0) != 0;
    const f = vinfo[0].finfo[0].format;
    const n: c.guint = switch (f) {
        c.GST_VIDEO_FORMAT_RGBx, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_xRGB, c.GST_VIDEO_FORMAT_xBGR, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_ABGR, c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_VUYA, c.GST_VIDEO_FORMAT_RBGA => 4,
        c.GST_VIDEO_FORMAT_RGBA64_LE, c.GST_VIDEO_FORMAT_RGBA64_BE, c.GST_VIDEO_FORMAT_ARGB64 => return c.GST_GL_RGBA16,
        c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_BGR => 3,
        c.GST_VIDEO_FORMAT_RGB16, c.GST_VIDEO_FORMAT_BGR16 => return c.GST_GL_RGB565,
        c.GST_VIDEO_FORMAT_GRAY16_BE, c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY => 2,
        c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV61, c.GST_VIDEO_FORMAT_NV24, c.GST_VIDEO_FORMAT_NV12_16L32S, c.GST_VIDEO_FORMAT_NV12_4L4 => if (plane == 0) 1 else 2,
        c.GST_VIDEO_FORMAT_AV12 => if (plane == 1) 2 else 1,
        c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_Y41B, c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_YV12, c.GST_VIDEO_FORMAT_A420, c.GST_VIDEO_FORMAT_A422, c.GST_VIDEO_FORMAT_A444 => 1,
        c.GST_VIDEO_FORMAT_BGR10A2_LE, c.GST_VIDEO_FORMAT_RGB10A2_LE, c.GST_VIDEO_FORMAT_BGR10x2_LE, c.GST_VIDEO_FORMAT_RGB10x2_LE, c.GST_VIDEO_FORMAT_Y410, c.GST_VIDEO_FORMAT_v210 => return c.GST_GL_RGB10_A2,
        c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_P010_10BE, c.GST_VIDEO_FORMAT_P012_LE, c.GST_VIDEO_FORMAT_P012_BE, c.GST_VIDEO_FORMAT_P016_LE, c.GST_VIDEO_FORMAT_P016_BE => return if (plane == 0) c.GST_GL_R16 else c.GST_GL_RG16,
        c.GST_VIDEO_FORMAT_Y210, c.GST_VIDEO_FORMAT_Y212_LE, c.GST_VIDEO_FORMAT_Y212_BE => return c.GST_GL_RG16,
        c.GST_VIDEO_FORMAT_Y412_LE, c.GST_VIDEO_FORMAT_Y412_BE => return c.GST_GL_RGBA16,
        c.GST_VIDEO_FORMAT_GBR, c.GST_VIDEO_FORMAT_RGBP, c.GST_VIDEO_FORMAT_BGRP, c.GST_VIDEO_FORMAT_GBRA => return c.GST_GL_R8,
        c.GST_VIDEO_FORMAT_I420_10LE, c.GST_VIDEO_FORMAT_I420_10BE, c.GST_VIDEO_FORMAT_I420_12LE, c.GST_VIDEO_FORMAT_I420_12BE, c.GST_VIDEO_FORMAT_I422_10LE, c.GST_VIDEO_FORMAT_I422_12LE, c.GST_VIDEO_FORMAT_I422_10BE, c.GST_VIDEO_FORMAT_I422_12BE, c.GST_VIDEO_FORMAT_A420_10LE, c.GST_VIDEO_FORMAT_A420_10BE, c.GST_VIDEO_FORMAT_A420_12LE, c.GST_VIDEO_FORMAT_A420_12BE, c.GST_VIDEO_FORMAT_A420_16LE, c.GST_VIDEO_FORMAT_A420_16BE, c.GST_VIDEO_FORMAT_A422_10LE, c.GST_VIDEO_FORMAT_A422_10BE, c.GST_VIDEO_FORMAT_A422_12LE, c.GST_VIDEO_FORMAT_A422_12BE, c.GST_VIDEO_FORMAT_A422_16LE, c.GST_VIDEO_FORMAT_A422_16BE, c.GST_VIDEO_FORMAT_A444_10LE, c.GST_VIDEO_FORMAT_A444_10BE, c.GST_VIDEO_FORMAT_A444_12LE, c.GST_VIDEO_FORMAT_A444_12BE, c.GST_VIDEO_FORMAT_A444_16LE, c.GST_VIDEO_FORMAT_A444_16BE, c.GST_VIDEO_FORMAT_Y444_10LE, c.GST_VIDEO_FORMAT_Y444_10BE, c.GST_VIDEO_FORMAT_Y444_12LE, c.GST_VIDEO_FORMAT_Y444_12BE, c.GST_VIDEO_FORMAT_Y444_16LE, c.GST_VIDEO_FORMAT_Y444_16BE => return c.GST_GL_R16,
        else => check.assertFail("gstglformat.c", 278, "gst_gl_format_from_video_info", null),
    };
    return switch (n) {
        4 => c.GST_GL_RGBA,
        3 => c.GST_GL_RGB,
        2 => if (rg) c.GST_GL_RG else c.GST_GL_LUMINANCE_ALPHA,
        else => if (rg) c.GST_GL_RED else c.GST_GL_LUMINANCE,
    };
}

pub export fn gst_gl_sized_gl_format_from_gl_format_type(ctx: OCtx, format: c.guint, t: c.guint) c.guint {
    const ext_rg = has(ctx, "GL_EXT_texture_rg");
    switch (format) {
        c.GST_GL_RGBA => switch (t) {
            c.GL_UNSIGNED_BYTE => return if (gles2(ctx) and !gles3(ctx)) c.GST_GL_RGBA else c.GST_GL_RGBA8,
            c.GL_UNSIGNED_SHORT => return c.GST_GL_RGBA16,
            UINT_2_10_10_10_REV => return c.GST_GL_RGB10_A2,
            else => {},
        },
        c.GST_GL_RGB => switch (t) {
            c.GL_UNSIGNED_BYTE => return if (gles2(ctx) and !gles3(ctx)) c.GST_GL_RGB else c.GST_GL_RGB8,
            c.GL_UNSIGNED_SHORT_5_6_5 => return c.GST_GL_RGB565,
            c.GL_UNSIGNED_SHORT => return c.GST_GL_RGB16,
            else => {},
        },
        c.GST_GL_RG => switch (t) {
            c.GL_UNSIGNED_BYTE => return if (!gles3(ctx) and gles2(ctx) and ext_rg) c.GST_GL_RG else c.GST_GL_RG8,
            c.GL_UNSIGNED_SHORT => return c.GST_GL_RG16,
            else => {},
        },
        c.GST_GL_RED => switch (t) {
            c.GL_UNSIGNED_BYTE => return if (!gles3(ctx) and gles2(ctx) and ext_rg) c.GST_GL_RED else c.GST_GL_R8,
            c.GL_UNSIGNED_SHORT => return c.GST_GL_R16,
            else => {},
        },
        c.GST_GL_RGBA8, c.GST_GL_RGBA16, c.GST_GL_RGB8, c.GST_GL_RGB16, c.GST_GL_RGB565, c.GST_GL_RG8, c.GST_GL_R8, c.GST_GL_LUMINANCE, c.GST_GL_LUMINANCE_ALPHA, c.GST_GL_ALPHA, c.GST_GL_DEPTH_COMPONENT16, c.GST_GL_DEPTH24_STENCIL8, c.GST_GL_RGB10_A2, c.GST_GL_R16, c.GST_GL_RG16 => return format,
        else => {
            c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Unknown GL format 0x%x type 0x%x provided", format, t);
            return format;
        },
    }
    check.assertFail("gstglformat.c", 379, "gst_gl_sized_gl_format_from_gl_format_type", null);
}

pub export fn gst_gl_format_type_from_sized_gl_format(format: c.GstGLFormat, unsized: [*c]c.GstGLFormat, gl_type: [*c]c.guint) void {
    const fname = "gst_gl_format_type_from_sized_gl_format";
    if (!check.that(unsized != null, fname, "unsized_format != NULL")) return;
    if (!check.that(gl_type != null, fname, "gl_type != NULL")) return;
    const r: struct { c.GstGLFormat, c.guint } = switch (format) {
        c.GST_GL_RGBA8 => .{ c.GST_GL_RGBA, c.GL_UNSIGNED_BYTE },
        c.GST_GL_RGB8 => .{ c.GST_GL_RGB, c.GL_UNSIGNED_BYTE },
        c.GST_GL_RGBA16 => .{ c.GST_GL_RGBA, c.GL_UNSIGNED_SHORT },
        c.GST_GL_RGB16 => .{ c.GST_GL_RGB, c.GL_UNSIGNED_SHORT },
        c.GST_GL_RGB565 => .{ c.GST_GL_RGB, c.GL_UNSIGNED_SHORT_5_6_5 },
        c.GST_GL_RG8 => .{ c.GST_GL_RG, c.GL_UNSIGNED_BYTE },
        c.GST_GL_R8 => .{ c.GST_GL_RED, c.GL_UNSIGNED_BYTE },
        c.GST_GL_RGBA, c.GST_GL_RGB, c.GST_GL_RG, c.GST_GL_RED, c.GST_GL_LUMINANCE, c.GST_GL_LUMINANCE_ALPHA, c.GST_GL_ALPHA => .{ format, c.GL_UNSIGNED_BYTE },
        c.GST_GL_RGB10_A2 => .{ c.GST_GL_RGBA, UINT_2_10_10_10_REV },
        c.GST_GL_R16 => .{ c.GST_GL_RED, c.GL_UNSIGNED_SHORT },
        c.GST_GL_RG16 => .{ c.GST_GL_RG, c.GL_UNSIGNED_SHORT },
        else => blk: {
            c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Unknown GL format 0x%x provided", format);
            break :blk .{ format, c.GL_UNSIGNED_BYTE };
        },
    };
    unsized[0] = r[0];
    gl_type[0] = r[1];
}

pub export fn gst_gl_format_n_components(format: c.GstGLFormat) c.guint {
    return switch (format) {
        c.GST_GL_LUMINANCE, c.GST_GL_ALPHA, c.GST_GL_RED, c.GST_GL_R8, c.GST_GL_DEPTH_COMPONENT16, c.GST_GL_R16 => 1,
        c.GST_GL_LUMINANCE_ALPHA, c.GST_GL_RG, c.GST_GL_RG8, c.GST_GL_DEPTH24_STENCIL8, c.GST_GL_RG16 => 2,
        c.GST_GL_RGB, c.GST_GL_RGB8, c.GST_GL_RGB565, c.GST_GL_RGB16 => 3,
        c.GST_GL_RGBA, c.GST_GL_RGBA8, c.GST_GL_RGBA16, c.GST_GL_RGB10_A2 => 4,
        else => blk: {
            c.g_warn_message(check.DOMAIN, "../gst-libs/gst/gl/gstglformat.c", 496, "gst_gl_format_n_components", null);
            break :blk 0;
        },
    };
}

fn singlePlane(format: c.GstVideoFormat, sw: [*c]c.gint) void {
    const fi = c.gst_video_format_get_info(format);
    if (!check.that(fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0 or format == c.GST_VIDEO_FORMAT_AYUV or format == c.GST_VIDEO_FORMAT_VUYA, "get_single_planar_format_gl_swizzle_order", "finfo->flags & GST_VIDEO_FORMAT_FLAG_RGB || format == GST_VIDEO_FORMAT_AYUV || format == GST_VIDEO_FORMAT_VUYA")) return;
    if (format == c.GST_VIDEO_FORMAT_BGR10A2_LE or format == c.GST_VIDEO_FORMAT_BGR10x2_LE) {
        sw[0..4].* = .{ 2, 1, 0, 3 };
        return;
    }
    if (format == c.GST_VIDEO_FORMAT_RGB10A2_LE or format == c.GST_VIDEO_FORMAT_RGB10x2_LE) {
        sw[0..4].* = .{ 0, 1, 2, 3 };
        return;
    }
    var k: usize = 0;
    const step: c.guint = ((fi[0].bits + 7) & ~@as(c.guint, 7)) / 8;
    for (0..fi[0].n_components) |i| {
        sw[k] = @intCast(fi[0].poffset[i] / step);
        k += 1;
    }
    if (format == c.GST_VIDEO_FORMAT_xRGB or format == c.GST_VIDEO_FORMAT_xBGR) {
        sw[k] = 0;
    } else if (format == c.GST_VIDEO_FORMAT_RGBx or format == c.GST_VIDEO_FORMAT_BGRx or format == c.GST_VIDEO_FORMAT_RGB or format == c.GST_VIDEO_FORMAT_BGR) {
        sw[k] = 3;
    } else {
        var i: usize = fi[0].n_components;
        while (i < c.GST_VIDEO_MAX_COMPONENTS) : (i += 1) {
            sw[k] = -1;
            k += 1;
        }
    }
}

pub export fn gst_gl_video_format_swizzle(format: c.GstVideoFormat, sw: [*c]c_int) c.gboolean {
    const fi = c.gst_video_format_get_info(format);
    if (fi[0].n_planes == 1 and (fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0 or format == c.GST_VIDEO_FORMAT_AYUV or format == c.GST_VIDEO_FORMAT_VUYA)) {
        singlePlane(format, sw);
        return 1;
    }
    switch (format) {
        c.GST_VIDEO_FORMAT_BGRP => singlePlane(c.GST_VIDEO_FORMAT_BGR, sw),
        c.GST_VIDEO_FORMAT_RGBP => singlePlane(c.GST_VIDEO_FORMAT_RGB, sw),
        c.GST_VIDEO_FORMAT_AV12, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV24, c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_P010_10BE, c.GST_VIDEO_FORMAT_P012_LE, c.GST_VIDEO_FORMAT_P012_BE, c.GST_VIDEO_FORMAT_P016_LE, c.GST_VIDEO_FORMAT_P016_BE, c.GST_VIDEO_FORMAT_NV12_16L32S, c.GST_VIDEO_FORMAT_NV12_4L4, c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_I420_10LE, c.GST_VIDEO_FORMAT_I420_10BE, c.GST_VIDEO_FORMAT_I420_12LE, c.GST_VIDEO_FORMAT_I420_12BE, c.GST_VIDEO_FORMAT_I422_10LE, c.GST_VIDEO_FORMAT_I422_10BE, c.GST_VIDEO_FORMAT_I422_12LE, c.GST_VIDEO_FORMAT_I422_12BE, c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_Y41B, c.GST_VIDEO_FORMAT_A420, c.GST_VIDEO_FORMAT_A420_10LE, c.GST_VIDEO_FORMAT_A420_10BE, c.GST_VIDEO_FORMAT_A420_12LE, c.GST_VIDEO_FORMAT_A420_12BE, c.GST_VIDEO_FORMAT_A420_16LE, c.GST_VIDEO_FORMAT_A420_16BE, c.GST_VIDEO_FORMAT_A422, c.GST_VIDEO_FORMAT_A422_10LE, c.GST_VIDEO_FORMAT_A422_10BE, c.GST_VIDEO_FORMAT_A422_12LE, c.GST_VIDEO_FORMAT_A422_12BE, c.GST_VIDEO_FORMAT_A422_16LE, c.GST_VIDEO_FORMAT_A422_16BE, c.GST_VIDEO_FORMAT_A444, c.GST_VIDEO_FORMAT_A444_10LE, c.GST_VIDEO_FORMAT_A444_10BE, c.GST_VIDEO_FORMAT_A444_12LE, c.GST_VIDEO_FORMAT_A444_12BE, c.GST_VIDEO_FORMAT_A444_16LE, c.GST_VIDEO_FORMAT_A444_16BE, c.GST_VIDEO_FORMAT_Y444_10BE, c.GST_VIDEO_FORMAT_Y444_10LE, c.GST_VIDEO_FORMAT_Y444_12BE, c.GST_VIDEO_FORMAT_Y444_12LE, c.GST_VIDEO_FORMAT_Y444_16BE, c.GST_VIDEO_FORMAT_Y444_16LE => sw[0..4].* = .{ 0, 1, 2, 3 },
        c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_NV61, c.GST_VIDEO_FORMAT_YV12 => sw[0..4].* = .{ 0, 2, 1, 3 },
        c.GST_VIDEO_FORMAT_Y410, c.GST_VIDEO_FORMAT_Y412_LE, c.GST_VIDEO_FORMAT_Y412_BE => sw[0..4].* = .{ 1, 0, 2, 3 },
        else => return 0,
    }
    return 1;
}

pub export fn gst_gl_swizzle_invert(sw: [*c]c.gint, inv: [*c]c.gint) void {
    for (0..c.GST_VIDEO_MAX_COMPONENTS) |i| inv[i] = -1;
    for (0..c.GST_VIDEO_MAX_COMPONENTS) |i| {
        const s = sw[i];
        if (s >= 0 and s < 4 and inv[@intCast(s)] == -1) inv[@intCast(s)] = @intCast(i);
    }
}

pub export fn gst_gl_format_is_supported(ctx: OCtx, format: c.GstGLFormat) c.gboolean {
    if (!check.that(context.isContext(ctx), "gst_gl_format_is_supported", "GST_IS_GL_CONTEXT (context)")) return 0;
    const r = switch (format) {
        c.GST_GL_RGBA, c.GST_GL_RGB => true,
        c.GST_GL_LUMINANCE, c.GST_GL_ALPHA, c.GST_GL_LUMINANCE_ALPHA => opengl(ctx) or gles2(ctx),
        c.GST_GL_RG, c.GST_GL_RED => ver(ctx, c.GST_GL_API_GLES2, 3, 0) != 0 or ver(ctx, c.GST_GL_API_OPENGL3, 3, 0) != 0 or has(ctx, "GL_EXT_texture_rg") or has(ctx, "GL_ARB_texture_rg"),
        c.GST_GL_R8, c.GST_GL_RG8 => gles3(ctx) or ver(ctx, c.GST_GL_API_OPENGL3, 3, 0) != 0 or has(ctx, "GL_ARB_texture_rg"),
        c.GST_GL_RGB8, c.GST_GL_RGBA8 => (gles3(ctx) and !gles2(ctx)) or opengl(ctx) or opengl3(ctx),
        c.GST_GL_RGB16, c.GST_GL_RGBA16 => opengl(ctx) or opengl3(ctx) or gles3(ctx),
        c.GST_GL_RGB565 => gles2(ctx) or (opengl3(ctx) and has(ctx, "GL_ARB_ES2_compatibility")),
        c.GST_GL_DEPTH_COMPONENT16 => ver(ctx, c.GST_GL_API_OPENGL, 1, 4) != 0 or gles2(ctx) or has(ctx, "GL_ARB_depth_texture") or has(ctx, "GL_OES_depth_texture"),
        c.GST_GL_DEPTH24_STENCIL8 => ver(ctx, c.GST_GL_API_OPENGL, 3, 0) != 0 or gles3(ctx) or has(ctx, "GL_OES_packed_depth_stencil") or has(ctx, "GL_EXT_packed_depth_stencil"),
        c.GST_GL_RGB10_A2 => opengl(ctx) or opengl3(ctx) or gles3(ctx) or has(ctx, "GL_OES_required_internalformat"),
        c.GST_GL_R16, c.GST_GL_RG16 => ver(ctx, c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3, 3, 0) != 0 or (ver(ctx, c.GST_GL_API_GLES2, 3, 1) != 0 and has(ctx, "GL_EXT_texture_norm16")),
        else => check.assertFail("gstglformat.c", 765, "gst_gl_format_is_supported", null),
    };
    return @intFromBool(r);
}

pub export fn gst_gl_texture_target_to_string(t: c.GstGLTextureTarget) [*c]const u8 {
    return switch (t) {
        c.GST_GL_TEXTURE_TARGET_2D => "2D",
        c.GST_GL_TEXTURE_TARGET_RECTANGLE => "rectangle",
        c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES => "external-oes",
        else => null,
    };
}

pub export fn gst_gl_texture_target_from_string(s: [*c]const u8) c.GstGLTextureTarget {
    if (s == null) return c.GST_GL_TEXTURE_TARGET_NONE;
    if (c.g_strcmp0(s, "2D") == 0) return c.GST_GL_TEXTURE_TARGET_2D;
    if (c.g_strcmp0(s, "rectangle") == 0) return c.GST_GL_TEXTURE_TARGET_RECTANGLE;
    if (c.g_strcmp0(s, "external-oes") == 0) return c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES;
    return c.GST_GL_TEXTURE_TARGET_NONE;
}

pub export fn gst_gl_texture_target_to_gl(t: c.GstGLTextureTarget) c.guint {
    return switch (t) {
        c.GST_GL_TEXTURE_TARGET_2D => c.GL_TEXTURE_2D,
        c.GST_GL_TEXTURE_TARGET_RECTANGLE => RECTANGLE,
        c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES => EXTERNAL_OES,
        else => 0,
    };
}

pub export fn gst_gl_texture_target_from_gl(t: c.guint) c.GstGLTextureTarget {
    return switch (t) {
        c.GL_TEXTURE_2D => c.GST_GL_TEXTURE_TARGET_2D,
        RECTANGLE => c.GST_GL_TEXTURE_TARGET_RECTANGLE,
        EXTERNAL_OES => c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES,
        else => c.GST_GL_TEXTURE_TARGET_NONE,
    };
}

pub export fn gst_gl_texture_target_to_buffer_pool_option(t: c.GstGLTextureTarget) [*c]const u8 {
    return switch (t) {
        c.GST_GL_TEXTURE_TARGET_2D => "GstBufferPoolOptionGLTextureTarget2D",
        c.GST_GL_TEXTURE_TARGET_RECTANGLE => "GstBufferPoolOptionGLTextureTargetRectangle",
        c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES => "GstBufferPoolOptionGLTextureTargetExternalOES",
        else => null,
    };
}
