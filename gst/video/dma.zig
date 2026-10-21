const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const format = @import("format.zig");
const info = @import("info.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Drm = c.GstVideoInfoDmaDrm;
const NONE = @as(?*anyopaque, null);
const DMABUF = "memory:DMABuf";

fn cc(s: *const [4]u8) u32 {
    return @as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24;
}

fn mod(vendor: u64, val: u64) u64 {
    return vendor << 56 | (val & 0x00ffffffffffffff);
}

const INVALID: u32 = 0;
const BIG_ENDIAN: u32 = 1 << 31;
const MOD_INVALID = mod(0, (1 << 56) - 1);
const MOD_LINEAR = mod(0, 0);
const MOD_VIVANTE = mod(0x06, 1);
const MOD_SAMSUNG = mod(0x04, 1);
const MOD_MTK_16L32S = mod(0x0b, 0x1);
const MOD_MTK_LSBTILED = mod(0x0b, 0x1 | 0x1 << 16);
const MOD_MTK_LSBRASTER = mod(0x0b, 0x1 | 0x2 << 16);

const Map = struct { format: c.GstVideoFormat, fourcc: u32, modifier: u64 };

fn lin(f: c.GstVideoFormat, s: *const [4]u8) Map {
    return .{ .format = f, .fourcc = cc(s), .modifier = MOD_LINEAR };
}

const map = [_]Map{
    lin(c.GST_VIDEO_FORMAT_YUY2, "YUYV"),
    lin(c.GST_VIDEO_FORMAT_YVYU, "YVYU"),
    lin(c.GST_VIDEO_FORMAT_UYVY, "UYVY"),
    lin(c.GST_VIDEO_FORMAT_VYUY, "VYUY"),
    lin(c.GST_VIDEO_FORMAT_VUYA, "AYUV"),
    lin(c.GST_VIDEO_FORMAT_NV12, "NV12"),
    .{ .format = c.GST_VIDEO_FORMAT_NV12_4L4, .fourcc = cc("NV12"), .modifier = MOD_VIVANTE },
    .{ .format = c.GST_VIDEO_FORMAT_NV12_64Z32, .fourcc = cc("NV12"), .modifier = MOD_SAMSUNG },
    .{ .format = c.GST_VIDEO_FORMAT_NV12_16L32S, .fourcc = cc("NV12"), .modifier = MOD_MTK_16L32S },
    .{ .format = c.GST_VIDEO_FORMAT_MT2110T, .fourcc = cc("NV15"), .modifier = MOD_MTK_LSBTILED },
    .{ .format = c.GST_VIDEO_FORMAT_MT2110R, .fourcc = cc("NV15"), .modifier = MOD_MTK_LSBRASTER },
    lin(c.GST_VIDEO_FORMAT_NV21, "NV21"),
    lin(c.GST_VIDEO_FORMAT_NV16, "NV16"),
    lin(c.GST_VIDEO_FORMAT_NV61, "NV61"),
    lin(c.GST_VIDEO_FORMAT_NV24, "NV24"),
    lin(c.GST_VIDEO_FORMAT_YUV9, "YUV9"),
    lin(c.GST_VIDEO_FORMAT_YVU9, "YVU9"),
    lin(c.GST_VIDEO_FORMAT_Y41B, "YU11"),
    lin(c.GST_VIDEO_FORMAT_I420, "YU12"),
    lin(c.GST_VIDEO_FORMAT_I420_10LE, "S010"),
    lin(c.GST_VIDEO_FORMAT_I422_10LE, "S210"),
    lin(c.GST_VIDEO_FORMAT_Y444_10LE, "S410"),
    lin(c.GST_VIDEO_FORMAT_I420_12LE, "S012"),
    lin(c.GST_VIDEO_FORMAT_I422_12LE, "S212"),
    lin(c.GST_VIDEO_FORMAT_Y444_12LE, "S412"),
    lin(c.GST_VIDEO_FORMAT_Y444_16LE, "S416"),
    lin(c.GST_VIDEO_FORMAT_YV12, "YV12"),
    lin(c.GST_VIDEO_FORMAT_Y42B, "YU16"),
    lin(c.GST_VIDEO_FORMAT_Y444, "YU24"),
    lin(c.GST_VIDEO_FORMAT_RGB15, "XR15"),
    lin(c.GST_VIDEO_FORMAT_RGB16, "RG16"),
    lin(c.GST_VIDEO_FORMAT_BGR16, "BG16"),
    lin(c.GST_VIDEO_FORMAT_RGB, "BG24"),
    lin(c.GST_VIDEO_FORMAT_BGR, "RG24"),
    lin(c.GST_VIDEO_FORMAT_RGBA, "AB24"),
    lin(c.GST_VIDEO_FORMAT_RGBx, "XB24"),
    lin(c.GST_VIDEO_FORMAT_BGRA, "AR24"),
    lin(c.GST_VIDEO_FORMAT_BGRx, "XR24"),
    lin(c.GST_VIDEO_FORMAT_ARGB, "BA24"),
    lin(c.GST_VIDEO_FORMAT_xRGB, "BX24"),
    lin(c.GST_VIDEO_FORMAT_ABGR, "RA24"),
    lin(c.GST_VIDEO_FORMAT_xBGR, "RX24"),
    lin(c.GST_VIDEO_FORMAT_Y410, "Y410"),
    lin(c.GST_VIDEO_FORMAT_Y412_LE, "Y412"),
    lin(c.GST_VIDEO_FORMAT_Y210, "Y210"),
    lin(c.GST_VIDEO_FORMAT_Y212_LE, "Y212"),
    lin(c.GST_VIDEO_FORMAT_NV12_10LE40, "NV15"),
    .{ .format = c.GST_VIDEO_FORMAT_NV12_10LE40_4L4, .fourcc = cc("NV15"), .modifier = MOD_VIVANTE },
    lin(c.GST_VIDEO_FORMAT_P010_10LE, "P010"),
    lin(c.GST_VIDEO_FORMAT_P012_LE, "P012"),
    lin(c.GST_VIDEO_FORMAT_BGR10A2_LE, "AR30"),
    lin(c.GST_VIDEO_FORMAT_RGB10A2_LE, "AB30"),
    lin(c.GST_VIDEO_FORMAT_BGR10x2_LE, "XR30"),
    lin(c.GST_VIDEO_FORMAT_RGB10x2_LE, "XB30"),
    lin(c.GST_VIDEO_FORMAT_GRAY8, "R8  "),
    lin(c.GST_VIDEO_FORMAT_GRAY16_LE, "R16 "),
    .{ .format = c.GST_VIDEO_FORMAT_GRAY16_BE, .fourcc = cc("R16 ") | BIG_ENDIAN, .modifier = MOD_LINEAR },
    lin(c.GST_VIDEO_FORMAT_NV16_10LE40, "NV20"),
    lin(c.GST_VIDEO_FORMAT_P016_LE, "P016"),
};

var type_once: gtype.Once = .{};

fn copy(p: c.gpointer) callconv(.c) c.gpointer {
    return c.g_memdup2(p, @sizeOf(Drm));
}

pub export fn gst_video_info_dma_drm_free(drm: [*c]Drm) void {
    c.g_free(drm);
}

fn free(p: c.gpointer) callconv(.c) void {
    c.g_free(p);
}

pub export fn gst_video_info_dma_drm_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoInfoDmaDrm", copy, free);
        }
    }.f);
}

pub export fn gst_video_info_dma_drm_init(drm: [*c]Drm) void {
    if (!check.that(drm != null, "gst_video_info_dma_drm_init", "drm_info != NULL")) return;
    info.gst_video_info_init(&drm[0].vinfo);
    drm[0].drm_fourcc = INVALID;
    drm[0].drm_modifier = MOD_INVALID;
}

pub export fn gst_video_info_dma_drm_new() [*c]Drm {
    const d: [*c]Drm = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Drm))));
    gst_video_info_dma_drm_init(d);
    return d;
}

pub export fn gst_video_is_dma_drm_caps(caps: [*c]const c.GstCaps) c.gboolean {
    if (!check.that(caps != null, "gst_video_is_dma_drm_caps", "caps != NULL")) return 0;
    if (c.gst_caps_is_fixed(caps) == 0) return 0;
    if (c.gst_caps_features_contains(c.gst_caps_get_features(caps, 0), DMABUF) == 0) return 0;
    const st = c.gst_caps_get_structure(caps, 0);
    return @intFromBool(c.g_strcmp0(c.gst_structure_get_string(st, "format"), "DMA_DRM") == 0);
}

pub export fn gst_video_info_dma_drm_to_caps(drm: [*c]const Drm) [*c]c.GstCaps {
    const fname = "gst_video_info_dma_drm_to_caps";
    if (!check.that(drm != null, fname, "drm_info != NULL")) return null;
    if (!check.that(drm[0].drm_fourcc != INVALID, fname, "drm_info->drm_fourcc != DRM_FORMAT_INVALID")) return null;
    if (!check.that(drm[0].drm_modifier != MOD_INVALID, fname, "drm_info->drm_modifier != DRM_FORMAT_MOD_INVALID")) return null;
    const caps = info.gst_video_info_to_caps(&drm[0].vinfo);
    if (caps == null) return null;
    c.gst_caps_set_features_simple(caps, c.gst_caps_features_new_single_static_str(DMABUF));
    const s = gst_video_dma_drm_fourcc_to_string(drm[0].drm_fourcc, drm[0].drm_modifier);
    c.gst_structure_set(c.gst_caps_get_structure(caps, 0), "format", c.G_TYPE_STRING, "DMA_DRM", "drm-format", c.G_TYPE_STRING, s, NONE);
    c.g_free(s);
    return caps;
}

pub export fn gst_video_info_dma_drm_from_caps(drm: [*c]Drm, caps: [*c]const c.GstCaps) c.gboolean {
    const fname = "gst_video_info_dma_drm_from_caps";
    if (!check.that(drm != null, fname, "drm_info != NULL")) return 0;
    if (!check.that(caps != null, fname, "caps != NULL")) return 0;
    if (gst_video_is_dma_drm_caps(caps) == 0) return 0;
    const tmp = c.gst_caps_copy(caps);
    defer c.gst_caps_unref(tmp);
    const st = c.gst_caps_get_structure(tmp, 0);
    const s = c.gst_structure_get_string(st, "drm-format");
    if (s == null) return 0;
    var modifier: c_ulong = 0;
    const fourcc = gst_video_dma_drm_fourcc_from_string(s, &modifier);
    if (fourcc == INVALID or modifier == MOD_INVALID) return 0;
    const fmt = gst_video_dma_drm_format_to_gst_format(fourcc, modifier);
    if (fmt != c.GST_VIDEO_FORMAT_UNKNOWN) c.gst_structure_set(st, "format", c.G_TYPE_STRING, format.gst_video_format_to_string(fmt), NONE);
    c.gst_structure_remove_field(st, "drm-format");
    if (info.gst_video_info_from_caps(&drm[0].vinfo, tmp) == 0) return 0;
    drm[0].drm_fourcc = fourcc;
    drm[0].drm_modifier = modifier;
    return 1;
}

pub export fn gst_video_info_dma_drm_new_from_caps(caps: [*c]const c.GstCaps) [*c]Drm {
    if (!check.that(caps != null, "gst_video_info_dma_drm_new_from_caps", "caps != NULL")) return null;
    if (gst_video_is_dma_drm_caps(caps) == 0) return null;
    const ret = gst_video_info_dma_drm_new();
    if (gst_video_info_dma_drm_from_caps(ret, caps) != 0) return ret;
    gst_video_info_dma_drm_free(ret);
    return null;
}

pub export fn gst_video_info_dma_drm_from_video_info(drm: [*c]Drm, vi: [*c]const c.GstVideoInfo, modifier: c_ulong) c.gboolean {
    const fname = "gst_video_info_dma_drm_from_video_info";
    if (!check.that(drm != null, fname, "drm_info != NULL")) return 0;
    if (!check.that(vi != null, fname, "info != NULL")) return 0;
    if (modifier == MOD_INVALID) return 0;
    const fourcc = gst_video_dma_drm_fourcc_from_format(vi[0].finfo[0].format);
    if (fourcc == INVALID) return 0;
    drm[0].vinfo = vi[0];
    drm[0].drm_fourcc = fourcc;
    drm[0].drm_modifier = modifier;
    if (modifier == MOD_LINEAR) return 1;
    return info.gst_video_info_set_interlaced_format(&drm[0].vinfo, c.GST_VIDEO_FORMAT_DMA_DRM, vi[0].interlace_mode, @bitCast(vi[0].width), @bitCast(vi[0].height));
}

pub export fn gst_video_info_dma_drm_to_video_info(drm: [*c]const Drm, vi: [*c]c.GstVideoInfo) c.gboolean {
    const fname = "gst_video_info_dma_drm_to_video_info";
    if (!check.that(drm != null, fname, "drm_info")) return 0;
    if (!check.that(vi != null, fname, "info")) return 0;
    if (drm[0].vinfo.finfo[0].format != c.GST_VIDEO_FORMAT_DMA_DRM) {
        vi[0] = drm[0].vinfo;
        return 1;
    }
    const fmt = gst_video_dma_drm_fourcc_to_format(drm[0].drm_fourcc);
    if (fmt == c.GST_VIDEO_FORMAT_UNKNOWN) return 0;
    var tmp: c.GstVideoInfo = undefined;
    if (info.gst_video_info_set_format(&tmp, fmt, @bitCast(drm[0].vinfo.width), @bitCast(drm[0].vinfo.height)) == 0) return 0;
    vi[0] = drm[0].vinfo;
    vi[0].finfo = tmp.finfo;
    vi[0].stride = tmp.stride;
    vi[0].offset = tmp.offset;
    vi[0].size = tmp.size;
    return 1;
}

fn plainFourcc(s: [*c]const u8, len: usize) ?bool {
    if (len == 7 and c.strstr(s + 4, "_BE") != null) return true;
    if (len != 4) return null;
    return false;
}

pub export fn gst_video_dma_drm_fourcc_from_string(s: [*c]const u8, modifier: [*c]c_ulong) c.guint {
    if (!check.that(s != null, "gst_video_dma_drm_fourcc_from_string", "format_str != NULL")) return 0;
    const colon = c.strchr(s, ':');
    var m: u64 = MOD_INVALID;
    var be = false;
    if (colon != null) {
        be = plainFourcc(s, @intFromPtr(colon) - @intFromPtr(s)) orelse return INVALID;
        const ms = colon + 1;
        if (!(ms[0] == '0' and (ms[1] == 'X' or ms[1] == 'x'))) return INVALID;
        m = c.g_ascii_strtoull(ms, null, 16);
        if (m == MOD_LINEAR) return INVALID;
    } else {
        be = plainFourcc(s, c.strlen(s)) orelse return INVALID;
        m = MOD_LINEAR;
    }
    var fourcc = @as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24;
    if (be) fourcc |= BIG_ENDIAN;
    if (modifier != null) modifier.* = m;
    return fourcc;
}

pub export fn gst_video_dma_drm_fourcc_to_string(fourcc_in: c.guint, modifier: c_ulong) [*c]u8 {
    const fname = "gst_video_dma_drm_fourcc_to_string";
    if (!check.that(fourcc_in != INVALID, fname, "fourcc != DRM_FORMAT_INVALID")) return null;
    if (!check.that(modifier != MOD_INVALID, fname, "modifier != DRM_FORMAT_MOD_INVALID")) return null;
    var fourcc = fourcc_in;
    var be: [*c]const u8 = "";
    if (fourcc & BIG_ENDIAN != 0) {
        be = "_BE";
        fourcc &= ~BIG_ENDIAN;
    }
    const a: c_int = @intCast(fourcc & 0xff);
    const b: c_int = @intCast((fourcc >> 8) & 0xff);
    const d: c_int = @intCast((fourcc >> 16) & 0xff);
    const e: c_int = @intCast((fourcc >> 24) & 0xff);
    if (modifier == MOD_LINEAR) return c.g_strdup_printf("%c%c%c%c%s", a, b, d, e, be);
    return c.g_strdup_printf("%c%c%c%c%s:0x%016lx", a, b, d, e, be, modifier);
}

pub export fn gst_video_dma_drm_format_from_gst_format(fmt: c.GstVideoFormat, modifier: [*c]c_ulong) c.guint {
    for (map) |e| {
        if (e.format == fmt) {
            if (modifier != null) modifier.* = e.modifier;
            return e.fourcc;
        }
    }
    modifier.* = MOD_INVALID;
    return INVALID;
}

pub export fn gst_video_dma_drm_fourcc_from_format(fmt: c.GstVideoFormat) c.guint {
    var m: c_ulong = 0;
    const fourcc = gst_video_dma_drm_format_from_gst_format(fmt, &m);
    if (fourcc == INVALID or m != MOD_LINEAR) return INVALID;
    return fourcc;
}

pub export fn gst_video_dma_drm_fourcc_to_format(fourcc: c.guint) c.GstVideoFormat {
    for (map) |e| if (e.fourcc == fourcc) return e.format;
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}

pub export fn gst_video_dma_drm_format_to_gst_format(fourcc: c.guint, modifier: c_ulong) c.GstVideoFormat {
    for (map) |e| if (e.fourcc == fourcc and e.modifier == modifier) return e.format;
    c.g_free(gst_video_dma_drm_fourcc_to_string(fourcc, modifier));
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}
