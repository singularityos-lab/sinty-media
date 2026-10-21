const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const format = @import("format.zig");
const color = @import("color.zig");
const chroma = @import("chroma.zig");
const multiview = @import("multiview.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Info = c.GstVideoInfo;
const F = c.GstVideoFormatInfo;
const NONE = @as(?*anyopaque, null);

var type_once: gtype.Once = .{};

pub export fn gst_video_info_copy(info: [*c]const Info) [*c]Info {
    return @ptrCast(@alignCast(c.g_memdup2(info, @sizeOf(Info))));
}

pub export fn gst_video_info_free(info: [*c]Info) void {
    c.g_free(info);
}

fn copyBoxed(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_video_info_copy(@ptrCast(@alignCast(p)));
}

fn freeBoxed(p: c.gpointer) callconv(.c) void {
    gst_video_info_free(@ptrCast(@alignCast(p)));
}

pub export fn gst_video_info_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoInfo", copyBoxed, freeBoxed);
        }
    }.f);
}

pub export fn gst_video_info_new() [*c]Info {
    const info: [*c]Info = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Info))));
    gst_video_info_init(info);
    return info;
}

pub export fn gst_video_info_init(info: [*c]Info) void {
    if (!check.that(info != null, "gst_video_info_init", "info != NULL")) return;
    info.* = std.mem.zeroes(Info);
    info[0].finfo = format.get(c.GST_VIDEO_FORMAT_UNKNOWN);
    info[0].views = 1;
    info[0].fps_n = 0;
    info[0].fps_d = 1;
    info[0].par_n = 1;
    info[0].par_d = 1;
    info[0].ABI.abi.multiview_mode = c.GST_VIDEO_MULTIVIEW_MODE_NONE;
    info[0].ABI.abi.multiview_flags = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE;
    info[0].ABI.abi.field_order = c.GST_VIDEO_FIELD_ORDER_UNKNOWN;
}

fn colorimetry(r: c.GstVideoColorRange, m: c.GstVideoColorMatrix, t: c.GstVideoTransferFunction, p: c.GstVideoColorPrimaries) c.GstVideoColorimetry {
    return .{ .range = r, .matrix = m, .transfer = t, .primaries = p };
}

const yuv_sd = colorimetry(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_BT601, c.GST_VIDEO_TRANSFER_BT601, c.GST_VIDEO_COLOR_PRIMARIES_SMPTE170M);
const yuv_hd = colorimetry(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_BT709, c.GST_VIDEO_TRANSFER_BT709, c.GST_VIDEO_COLOR_PRIMARIES_BT709);
const rgb = colorimetry(c.GST_VIDEO_COLOR_RANGE_0_255, c.GST_VIDEO_COLOR_MATRIX_RGB, c.GST_VIDEO_TRANSFER_SRGB, c.GST_VIDEO_COLOR_PRIMARIES_BT709);
const gray = colorimetry(c.GST_VIDEO_COLOR_RANGE_0_255, c.GST_VIDEO_COLOR_MATRIX_BT601, c.GST_VIDEO_TRANSFER_UNKNOWN, c.GST_VIDEO_COLOR_PRIMARIES_UNKNOWN);
const unknown = colorimetry(c.GST_VIDEO_COLOR_RANGE_UNKNOWN, c.GST_VIDEO_COLOR_MATRIX_UNKNOWN, c.GST_VIDEO_TRANSFER_UNKNOWN, c.GST_VIDEO_COLOR_PRIMARIES_UNKNOWN);

fn ref(info: [*c]Info) *Info {
    return @ptrCast(info);
}

fn cref(info: [*c]const Info) *const Info {
    return @ptrCast(info);
}

fn has(f: [*c]const F, flag: c.guint) bool {
    return f[0].flags & flag != 0;
}

fn isYuv(f: [*c]const F) bool {
    return has(f, c.GST_VIDEO_FORMAT_FLAG_YUV);
}

fn isRgb(f: [*c]const F) bool {
    return has(f, c.GST_VIDEO_FORMAT_FLAG_RGB);
}

fn isGray(f: [*c]const F) bool {
    return has(f, c.GST_VIDEO_FORMAT_FLAG_GRAY);
}

fn defaultColorimetry(info: *Info) void {
    const f = info.finfo;
    info.colorimetry = if (isYuv(f)) (if (info.height > 576) yuv_hd else yuv_sd) else if (isGray(f)) gray else if (isRgb(f)) rgb else unknown;
}

fn validColorimetry(info: *const Info) bool {
    const f = info.finfo;
    if ((isYuv(f) or isGray(f)) and info.colorimetry.matrix == c.GST_VIDEO_COLOR_MATRIX_RGB) return false;
    if (isYuv(f) and info.colorimetry.matrix == c.GST_VIDEO_COLOR_MATRIX_UNKNOWN) return false;
    return true;
}

fn defaultChromaSite(info: *Info) void {
    info.chroma_site = if (isYuv(info.finfo)) (if (info.height > 576) c.GST_VIDEO_CHROMA_SITE_H_COSITED else c.GST_VIDEO_CHROMA_SITE_NONE) else c.GST_VIDEO_CHROMA_SITE_UNKNOWN;
}

fn validChromaSite(info: *const Info) bool {
    if (isYuv(info.finfo)) return !(info.chroma_site & c.GST_VIDEO_CHROMA_SITE_NONE != 0 and info.chroma_site & (c.GST_VIDEO_CHROMA_SITE_H_COSITED | c.GST_VIDEO_CHROMA_SITE_V_COSITED) != 0);
    return info.chroma_site == c.GST_VIDEO_CHROMA_SITE_UNKNOWN;
}

fn setCommon(info: [*c]Info, fmt: c.GstVideoFormat, width: c.guint, height: c.guint) bool {
    const fname = "gst_video_info_set_format_common";
    if (!check.that(info != null, fname, "info != NULL")) return false;
    if (!check.that(fmt != c.GST_VIDEO_FORMAT_UNKNOWN, fname, "format != GST_VIDEO_FORMAT_UNKNOWN")) return false;
    if (width > std.math.maxInt(c.gint) or height > std.math.maxInt(c.gint)) return false;
    gst_video_info_init(info);
    info[0].finfo = format.get(fmt);
    info[0].width = @intCast(width);
    info[0].height = @intCast(height);
    info[0].views = 1;
    defaultColorimetry(ref(info));
    return true;
}

pub export fn gst_video_info_set_format(info: [*c]Info, fmt: c.GstVideoFormat, width: c.guint, height: c.guint) c.gboolean {
    if (!setCommon(info, fmt, width, height)) return 0;
    return @intFromBool(fill(ref(info), null));
}

pub export fn gst_video_info_set_interlaced_format(info: [*c]Info, fmt: c.GstVideoFormat, mode: c.GstVideoInterlaceMode, width: c.guint, height: c.guint) c.gboolean {
    if (!setCommon(info, fmt, width, height)) return 0;
    info[0].interlace_mode = mode;
    return @intFromBool(fill(ref(info), null));
}

const interlace_modes = [_][*:0]const u8{ "progressive", "interleaved", "mixed", "fields", "alternate" };
const field_orders = [_][*:0]const u8{ "unknown", "top-field-first", "bottom-field-first" };

pub export fn gst_video_interlace_mode_to_string(mode: c.GstVideoInterlaceMode) [*c]const u8 {
    const k: c.guint = @bitCast(mode);
    if (k >= interlace_modes.len) return null;
    return interlace_modes[k];
}

pub export fn gst_video_interlace_mode_from_string(mode: [*c]const u8) c.GstVideoInterlaceMode {
    for (interlace_modes, 0..) |s, i| if (c.strcmp(s, mode) == 0) return @intCast(i);
    return c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE;
}

pub export fn gst_video_field_order_to_string(order: c.GstVideoFieldOrder) [*c]const u8 {
    const k: c.guint = @bitCast(order);
    if (k >= field_orders.len) return null;
    return field_orders[k];
}

pub export fn gst_video_field_order_from_string(order: [*c]const u8) c.GstVideoFieldOrder {
    for (field_orders, 0..) |s, i| if (c.strcmp(s, order) == 0) return @intCast(i);
    return c.GST_VIDEO_FIELD_ORDER_UNKNOWN;
}

fn startsWith(s: [*c]const u8, p: [*:0]const u8) bool {
    return c.g_str_has_prefix(s, p) != 0;
}

pub export fn gst_video_info_from_caps(info: [*c]Info, caps: [*c]const c.GstCaps) c.gboolean {
    const fname = "gst_video_info_from_caps";
    if (!check.that(info != null, fname, "info != NULL")) return 0;
    if (!check.that(caps != null, fname, "caps != NULL")) return 0;
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, fname, "gst_caps_is_fixed (caps)")) return 0;
    const sc = c.gst_caps_get_structure(caps, 0);
    var fmt: c.GstVideoFormat = c.GST_VIDEO_FORMAT_UNKNOWN;
    if (c.gst_structure_has_name(sc, "video/x-raw") != 0) {
        const s = c.gst_structure_get_string(sc, "format");
        if (s == null) return 0;
        fmt = format.gst_video_format_from_string(s);
        if (fmt == c.GST_VIDEO_FORMAT_UNKNOWN) return 0;
    } else if (startsWith(c.gst_structure_get_name(sc), "video/") or startsWith(c.gst_structure_get_name(sc), "image/")) {
        fmt = c.GST_VIDEO_FORMAT_ENCODED;
    } else return 0;
    var width: c.gint = 0;
    var height: c.gint = 0;
    if (c.gst_structure_get_int(sc, "width", &width) == 0 and fmt != c.GST_VIDEO_FORMAT_ENCODED) return 0;
    if (c.gst_structure_get_int(sc, "height", &height) == 0 and fmt != c.GST_VIDEO_FORMAT_ENCODED) return 0;
    gst_video_info_init(info);
    const v = ref(info);
    v.finfo = format.get(fmt);
    v.width = width;
    v.height = height;
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (c.gst_structure_get_fraction(sc, "framerate", &n, &d) != 0) {
        if (n == 0) {
            v.flags |= c.GST_VIDEO_FLAG_VARIABLE_FPS;
            _ = c.gst_structure_get_fraction(sc, "max-framerate", &n, &d);
        }
        v.fps_n = n;
        v.fps_d = d;
    } else {
        v.fps_n = 0;
        v.fps_d = 1;
    }
    if (c.gst_structure_get_fraction(sc, "pixel-aspect-ratio", &n, &d) != 0) {
        v.par_n = n;
        v.par_d = d;
    } else {
        v.par_n = 1;
        v.par_d = 1;
    }
    var s = c.gst_structure_get_string(sc, "interlace-mode");
    v.interlace_mode = if (s != null) gst_video_interlace_mode_from_string(s) else c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE;
    if (v.interlace_mode == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE and fmt != c.GST_VIDEO_FORMAT_ENCODED) {
        const f = c.gst_caps_get_features(caps, 0);
        if (f == null or c.gst_caps_features_contains(f, c.GST_CAPS_FEATURE_FORMAT_INTERLACED) == 0) return 0;
    }
    s = if (v.interlace_mode != c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE) c.gst_structure_get_string(sc, "field-order") else null;
    v.ABI.abi.field_order = if (s != null) gst_video_field_order_from_string(s) else c.GST_VIDEO_FIELD_ORDER_UNKNOWN;
    s = c.gst_structure_get_string(sc, "multiview-mode");
    v.ABI.abi.multiview_mode = if (s != null) multiview.gst_video_multiview_mode_from_caps_string(s) else c.GST_VIDEO_MULTIVIEW_MODE_NONE;
    var mflags: c.guint = 0;
    if (c.gst_structure_get_flagset(sc, "multiview-flags", &mflags, null) != 0) v.ABI.abi.multiview_flags = mflags;
    if (c.gst_structure_get_int(sc, "views", &v.views) == 0) v.views = 1;
    s = c.gst_structure_get_string(sc, "chroma-site");
    if (s != null) {
        v.chroma_site = chroma.gst_video_chroma_site_from_string(s);
        if (!validChromaSite(v)) {
            defaultChromaSite(v);
        } else if (isYuv(v.finfo) and v.chroma_site == c.GST_VIDEO_CHROMA_SITE_UNKNOWN) {
            defaultChromaSite(v);
        }
    } else defaultChromaSite(v);
    s = c.gst_structure_get_string(sc, "colorimetry");
    if (s != null) {
        if (color.gst_video_colorimetry_from_string(&v.colorimetry, s) == 0) {
            defaultColorimetry(v);
        } else if (!validColorimetry(v)) {
            defaultColorimetry(v);
        } else if (isRgb(v.finfo) and v.colorimetry.matrix != c.GST_VIDEO_COLOR_MATRIX_RGB) {
            v.colorimetry.matrix = c.GST_VIDEO_COLOR_MATRIX_RGB;
        }
    } else defaultColorimetry(v);
    return @intFromBool(fill(v, null));
}

pub export fn gst_video_info_new_from_caps(caps: [*c]const c.GstCaps) [*c]Info {
    const ret = gst_video_info_new();
    if (gst_video_info_from_caps(ret, caps) != 0) return ret;
    gst_video_info_free(ret);
    return null;
}

pub export fn gst_video_info_is_equal(info: [*c]const Info, other: [*c]const Info) c.gboolean {
    if (info == other) return 1;
    const a = cref(info);
    const b = &other[0];
    if (a.finfo == null or b.finfo == null) return 0;
    if (a.finfo[0].format != b.finfo[0].format) return 0;
    if (a.interlace_mode != b.interlace_mode or a.flags != b.flags) return 0;
    if (a.width != b.width or a.height != b.height or a.size != b.size) return 0;
    if (a.par_n != b.par_n or a.par_d != b.par_d or a.fps_n != b.fps_n or a.fps_d != b.fps_d) return 0;
    if (color.gst_video_colorimetry_is_equal(&a.colorimetry, &b.colorimetry) == 0) return 0;
    if (a.chroma_site != b.chroma_site) return 0;
    if (a.ABI.abi.multiview_mode != b.ABI.abi.multiview_mode or a.ABI.abi.multiview_flags != b.ABI.abi.multiview_flags) return 0;
    if (a.views != b.views) return 0;
    for (0..a.finfo[0].n_planes) |i| {
        if (a.stride[i] != b.stride[i] or a.offset[i] != b.offset[i]) return 0;
    }
    return 1;
}

pub export fn gst_video_info_to_caps(info: [*c]const Info) [*c]c.GstCaps {
    const fname = "gst_video_info_to_caps";
    if (!check.that(info != null, fname, "info != NULL")) return null;
    const v = cref(info);
    if (!check.that(v.finfo != null, fname, "info->finfo != NULL")) return null;
    if (!check.that(v.finfo[0].format != c.GST_VIDEO_FORMAT_UNKNOWN, fname, "info->finfo->format != GST_VIDEO_FORMAT_UNKNOWN")) return null;
    const fmt = format.gst_video_format_to_string(v.finfo[0].format);
    if (!check.that(fmt != null, fname, "format != NULL")) return null;
    const caps = c.gst_caps_new_static_str_simple("video/x-raw", "format", c.G_TYPE_STRING, fmt, "width", c.G_TYPE_INT, v.width, "height", c.G_TYPE_INT, v.height, NONE);
    var par_n = v.par_n;
    var par_d = v.par_d;
    c.gst_caps_set_simple_static_str(caps, "interlace-mode", c.G_TYPE_STRING, gst_video_interlace_mode_to_string(v.interlace_mode), NONE);
    const im = v.interlace_mode;
    if ((im == c.GST_VIDEO_INTERLACE_MODE_INTERLEAVED or im == c.GST_VIDEO_INTERLACE_MODE_FIELDS or im == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) and v.ABI.abi.field_order != c.GST_VIDEO_FIELD_ORDER_UNKNOWN)
        c.gst_caps_set_simple_static_str(caps, "field-order", c.G_TYPE_STRING, gst_video_field_order_to_string(v.ABI.abi.field_order), NONE);
    if (im == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE)
        c.gst_caps_set_features(caps, 0, c.gst_caps_features_new_static_str(c.GST_CAPS_FEATURE_FORMAT_INTERLACED, NONE));
    const mode = v.ABI.abi.multiview_mode;
    if (mode != c.GST_VIDEO_MULTIVIEW_MODE_NONE) {
        var mflags = v.ABI.abi.multiview_flags;
        if (mflags & c.GST_VIDEO_MULTIVIEW_FLAGS_HALF_ASPECT != 0) {
            mflags &= ~@as(c.GstVideoMultiviewFlags, c.GST_VIDEO_MULTIVIEW_FLAGS_HALF_ASPECT);
            switch (mode) {
                c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE, c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE_QUINCUNX, c.GST_VIDEO_MULTIVIEW_MODE_COLUMN_INTERLEAVED, c.GST_VIDEO_MULTIVIEW_MODE_CHECKERBOARD => par_n *%= 2,
                c.GST_VIDEO_MULTIVIEW_MODE_ROW_INTERLEAVED, c.GST_VIDEO_MULTIVIEW_MODE_TOP_BOTTOM => par_d *%= 2,
                else => {},
            }
        }
        const cs = multiview.gst_video_multiview_mode_to_caps_string(mode);
        if (cs != null) c.gst_caps_set_simple_static_str(caps, "multiview-mode", c.G_TYPE_STRING, cs, "multiview-flags", multiview.gst_video_multiview_flagset_get_type(), mflags, @as(c.guint, c.GST_FLAG_SET_MASK_EXACT), NONE);
    }
    c.gst_caps_set_simple_static_str(caps, "pixel-aspect-ratio", c.gst_fraction_get_type(), par_n, par_d, NONE);
    if (v.chroma_site != c.GST_VIDEO_CHROMA_SITE_UNKNOWN) {
        const site = chroma.gst_video_chroma_site_to_string(v.chroma_site);
        if (site != null) {
            c.gst_caps_set_simple_static_str(caps, "chroma-site", c.G_TYPE_STRING, site, NONE);
            c.g_free(site);
        }
    }
    var col = v.colorimetry;
    if (isRgb(v.finfo) and col.matrix != c.GST_VIDEO_COLOR_MATRIX_RGB) col.matrix = c.GST_VIDEO_COLOR_MATRIX_RGB;
    const cstr = color.gst_video_colorimetry_to_string(&col);
    if (cstr != null) {
        c.gst_caps_set_simple_static_str(caps, "colorimetry", c.G_TYPE_STRING, cstr, NONE);
        c.g_free(cstr);
    }
    if (v.views > 1) c.gst_caps_set_simple_static_str(caps, "views", c.G_TYPE_INT, v.views, NONE);
    if (v.flags & c.GST_VIDEO_FLAG_VARIABLE_FPS != 0 and v.fps_n != 0) {
        c.gst_caps_set_simple_static_str(caps, "framerate", c.gst_fraction_get_type(), @as(c.gint, 0), @as(c.gint, 1), "max-framerate", c.gst_fraction_get_type(), v.fps_n, v.fps_d, NONE);
    } else {
        c.gst_caps_set_simple_static_str(caps, "framerate", c.gst_fraction_get_type(), v.fps_n, v.fps_d, NONE);
    }
    return caps;
}

fn up(v: u64, n: u64) u64 {
    return (v +% n -% 1) & ~(n -% 1);
}

fn st(v: u64) c.gint {
    return @bitCast(@as(u32, @truncate(v)));
}

fn wide(v: c.gint) u64 {
    return @bitCast(@as(i64, v));
}

fn tileStride(x: u64, y: u64) c.gint {
    return st(x | (y << 16));
}

fn fieldHeightExact(info: *const Info) c.gint {
    if (info.interlace_mode == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) return @divTrunc((info.height + 1) & ~@as(c.gint, 1), 2);
    return info.height;
}

fn subScale(n: c.guint, v: c.gint) c.gint {
    const sh: u5 = @intCast(n);
    return -((-v) >> sh);
}

pub fn fill(info: *Info, plane_size: ?*[4]c.gsize) bool {
    const fi = info.finfo;
    const width: u64 = @bitCast(@as(i64, info.width));
    const height: u64 = @bitCast(@as(i64, fieldHeightExact(info)));
    const interlaced = info.interlace_mode != c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE;
    var bpp: c.gint = 0;
    for (0..fi[0].n_components) |i| bpp += @intCast(fi[0].depth[i]);
    bpp = @divTrunc((bpp + 7) & ~@as(c.gint, 7), 8);
    if (bpp > 0 and up(width, 128) *% height >= @as(u64, std.math.maxInt(c.guint) / @as(c.guint, @intCast(bpp)))) return false;
    const s = &info.stride;
    const o = &info.offset;
    switch (fi[0].format) {
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YVYU, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_VYUY, c.GST_VIDEO_FORMAT_RGB16, c.GST_VIDEO_FORMAT_BGR16, c.GST_VIDEO_FORMAT_RGB15, c.GST_VIDEO_FORMAT_BGR15, c.GST_VIDEO_FORMAT_GRAY16_BE, c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_GRAY10_LE16 => single(info, st(up(width * 2, 4)), height),
        c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_RGBx, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_xRGB, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_xBGR, c.GST_VIDEO_FORMAT_ABGR, c.GST_VIDEO_FORMAT_r210, c.GST_VIDEO_FORMAT_Y410, c.GST_VIDEO_FORMAT_VUYA, c.GST_VIDEO_FORMAT_BGR10A2_LE, c.GST_VIDEO_FORMAT_RGB10A2_LE, c.GST_VIDEO_FORMAT_BGR10x2_LE, c.GST_VIDEO_FORMAT_RGB10x2_LE, c.GST_VIDEO_FORMAT_RBGA => single(info, st(width * 4), height),
        c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_BGR, c.GST_VIDEO_FORMAT_v308, c.GST_VIDEO_FORMAT_IYU2 => single(info, st(up(width * 3, 4)), height),
        c.GST_VIDEO_FORMAT_v210 => single(info, st(((width + 47) / 48) * 128), height),
        c.GST_VIDEO_FORMAT_v216, c.GST_VIDEO_FORMAT_Y210, c.GST_VIDEO_FORMAT_Y212_BE, c.GST_VIDEO_FORMAT_Y212_LE, c.GST_VIDEO_FORMAT_Y216_BE, c.GST_VIDEO_FORMAT_Y216_LE => single(info, st(up(width * 4, 8)), height),
        c.GST_VIDEO_FORMAT_GRAY8 => single(info, st(up(width, 4)), height),
        c.GST_VIDEO_FORMAT_UYVP => single(info, st(up((up(width, 2) * 5) / 2, 4)), height),
        c.GST_VIDEO_FORMAT_RGB8P => {
            s[0] = st(up(width, 4));
            s[1] = 4;
            o[0] = 0;
            o[1] = wide(s[0]) *% height;
            info.size = o[1] + 4 * 256;
        },
        c.GST_VIDEO_FORMAT_IYU1 => single(info, st(up(up(width, 4) + up(width, 4) / 2, 4)), height),
        c.GST_VIDEO_FORMAT_ARGB64, c.GST_VIDEO_FORMAT_ARGB64_BE, c.GST_VIDEO_FORMAT_ARGB64_LE, c.GST_VIDEO_FORMAT_RGBA64_BE, c.GST_VIDEO_FORMAT_RGBA64_LE, c.GST_VIDEO_FORMAT_BGRA64_BE, c.GST_VIDEO_FORMAT_BGRA64_LE, c.GST_VIDEO_FORMAT_ABGR64_BE, c.GST_VIDEO_FORMAT_ABGR64_LE, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_Y412_BE, c.GST_VIDEO_FORMAT_Y412_LE, c.GST_VIDEO_FORMAT_Y416_BE, c.GST_VIDEO_FORMAT_Y416_LE => single(info, st(width * 8), height),
        c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_YV12 => planar420(info, st(up(width, 4)), st(up(up(width, 2) / 2, 4)), height, interlaced, false),
        c.GST_VIDEO_FORMAT_I420_10LE, c.GST_VIDEO_FORMAT_I420_10BE, c.GST_VIDEO_FORMAT_I420_12LE, c.GST_VIDEO_FORMAT_I420_12BE => planar420(info, st(up(width * 2, 4)), st(up(width, 4)), height, interlaced, false),
        c.GST_VIDEO_FORMAT_A420 => planar420(info, st(up(width, 4)), st(up(up(width, 2) / 2, 4)), height, interlaced, true),
        c.GST_VIDEO_FORMAT_A420_10LE, c.GST_VIDEO_FORMAT_A420_10BE, c.GST_VIDEO_FORMAT_A420_12LE, c.GST_VIDEO_FORMAT_A420_12BE, c.GST_VIDEO_FORMAT_A420_16LE, c.GST_VIDEO_FORMAT_A420_16BE => planar420(info, st(up(width * 2, 4)), st(up(width, 4)), height, interlaced, true),
        c.GST_VIDEO_FORMAT_Y41B => {
            s[0] = st(up(width, 4));
            s[1] = st(up(width, 16) / 4);
            s[2] = s[1];
            o[0] = 0;
            o[1] = wide(s[0]) *% height;
            o[2] = o[1] +% wide(s[1]) *% height;
            info.size = (wide(s[0]) +% up(width, 16) / 2) *% height;
        },
        c.GST_VIDEO_FORMAT_Y42B => {
            s[0] = st(up(width, 4));
            s[1] = st(up(width, 8) / 2);
            s[2] = s[1];
            o[0] = 0;
            o[1] = wide(s[0]) *% height;
            o[2] = o[1] +% wide(s[1]) *% height;
            info.size = (wide(s[0]) +% up(width, 8)) *% height;
        },
        c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_GBR, c.GST_VIDEO_FORMAT_RGBP, c.GST_VIDEO_FORMAT_BGRP => equal(info, st(up(width, 4)), height, 3),
        c.GST_VIDEO_FORMAT_GBRA => equal(info, st(up(width, 4)), height, 4),
        c.GST_VIDEO_FORMAT_Y444_10LE, c.GST_VIDEO_FORMAT_Y444_10BE, c.GST_VIDEO_FORMAT_Y444_12LE, c.GST_VIDEO_FORMAT_Y444_12BE, c.GST_VIDEO_FORMAT_GBR_10LE, c.GST_VIDEO_FORMAT_GBR_10BE, c.GST_VIDEO_FORMAT_GBR_12LE, c.GST_VIDEO_FORMAT_GBR_12BE, c.GST_VIDEO_FORMAT_GBR_16LE, c.GST_VIDEO_FORMAT_GBR_16BE, c.GST_VIDEO_FORMAT_Y444_16LE, c.GST_VIDEO_FORMAT_Y444_16BE => equal(info, st(up(width * 2, 4)), height, 3),
        c.GST_VIDEO_FORMAT_GBRA_10LE, c.GST_VIDEO_FORMAT_GBRA_10BE, c.GST_VIDEO_FORMAT_GBRA_12LE, c.GST_VIDEO_FORMAT_GBRA_12BE, c.GST_VIDEO_FORMAT_A444_10LE, c.GST_VIDEO_FORMAT_A444_10BE, c.GST_VIDEO_FORMAT_A444_12LE, c.GST_VIDEO_FORMAT_A444_12BE, c.GST_VIDEO_FORMAT_A444_16LE, c.GST_VIDEO_FORMAT_A444_16BE => equal(info, st(up(width * 2, 4)), height, 4),
        c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV21 => semi420(info, st(up(width, 4)), height, interlaced),
        c.GST_VIDEO_FORMAT_NV12_10LE32 => semi420(info, st((width + 2) / 3 * 4), height, interlaced),
        c.GST_VIDEO_FORMAT_NV12_10LE40 => semi420(info, st(((width * 5 >> 2) + 4) / 5 * 5), height, interlaced),
        c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_P010_10BE, c.GST_VIDEO_FORMAT_P016_LE, c.GST_VIDEO_FORMAT_P016_BE, c.GST_VIDEO_FORMAT_P012_LE, c.GST_VIDEO_FORMAT_P012_BE => semi420(info, st(up(width * 2, 4)), height, false),
        c.GST_VIDEO_FORMAT_AV12 => {
            s[0] = st(up(width, 4));
            s[1] = s[0];
            s[2] = s[0];
            o[0] = 0;
            o[1] = wide(s[0]) *% up(height, 2);
            o[2] = o[1] +% (wide(s[1]) *% up(height, 2) / 2);
            info.size = o[2] +% wide(s[2]) *% up(height, 2);
        },
        c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV61, c.GST_VIDEO_FORMAT_NV16_10LE32 => {
            const w: u64 = if (fi[0].format == c.GST_VIDEO_FORMAT_NV16_10LE32) (width + 2) / 3 * 4 else up(width, 4);
            s[0] = st(w);
            s[1] = s[0];
            o[0] = 0;
            o[1] = wide(s[0]) *% height;
            info.size = wide(s[0]) *% height *% 2;
        },
        c.GST_VIDEO_FORMAT_NV16_10LE40 => {
            s[0] = st(((width * 5 >> 2) + 4) / 5 * 5);
            s[1] = s[0];
            o[0] = 0;
            o[1] = wide(s[0]) *% up(height, 2);
            info.size = o[1] *% 2;
        },
        c.GST_VIDEO_FORMAT_NV24 => {
            s[0] = st(up(width, 4));
            s[1] = st(up(width * 2, 4));
            o[0] = 0;
            o[1] = wide(s[0]) *% height;
            info.size = wide(s[0]) *% height +% wide(s[1]) *% height;
        },
        c.GST_VIDEO_FORMAT_A422 => planarFull(info, st(up(width, 4)), st(up(width, 8) / 2), height),
        c.GST_VIDEO_FORMAT_A444 => planarFull(info, st(up(width, 4)), st(up(width, 4)), height),
        c.GST_VIDEO_FORMAT_I422_10LE, c.GST_VIDEO_FORMAT_I422_10BE, c.GST_VIDEO_FORMAT_I422_12LE, c.GST_VIDEO_FORMAT_I422_12BE => {
            s[0] = st(up(width * 2, 4));
            s[1] = st(up(width, 4));
            s[2] = s[1];
            o[0] = 0;
            o[1] = wide(s[0]) *% up(height, 2);
            o[2] = o[1] +% wide(s[1]) *% up(height, 2);
            info.size = o[2] +% wide(s[2]) *% up(height, 2);
        },
        c.GST_VIDEO_FORMAT_A422_10LE, c.GST_VIDEO_FORMAT_A422_10BE, c.GST_VIDEO_FORMAT_A422_12LE, c.GST_VIDEO_FORMAT_A422_12BE, c.GST_VIDEO_FORMAT_A422_16LE, c.GST_VIDEO_FORMAT_A422_16BE => planarFull(info, st(up(width * 2, 4)), st(up(width, 4)), height),
        c.GST_VIDEO_FORMAT_YUV9, c.GST_VIDEO_FORMAT_YVU9 => {
            s[0] = st(up(width, 4));
            s[1] = st(up(up(width, 4) / 4, 4));
            s[2] = s[1];
            o[0] = 0;
            o[1] = wide(s[0]) *% height;
            var cr_h = up(height, 4) / 4;
            if (interlaced) cr_h = up(cr_h, 2);
            o[2] = o[1] +% wide(s[1]) *% cr_h;
            info.size = o[2] +% wide(s[2]) *% cr_h;
        },
        c.GST_VIDEO_FORMAT_GRAY10_LE32 => {
            s[0] = st((width + 2) / 3 * 4);
            o[0] = 0;
            info.size = wide(s[0]) *% up(height, 2);
        },
        c.GST_VIDEO_FORMAT_NV12_64Z32 => {
            s[0] = tileStride(up(width, 128) / 64, up(height, 32) / 32);
            s[1] = tileStride(up(width, 128) / 64, up(height, 64) / 64);
            o[0] = 0;
            o[1] = up(width, 128) *% up(height, 32);
            info.size = o[1] +% up(width, 128) *% (up(height, 64) / 2);
        },
        c.GST_VIDEO_FORMAT_NV12_4L4, c.GST_VIDEO_FORMAT_NV12_32L32, c.GST_VIDEO_FORMAT_NV12_10LE40_4L4 => {
            const size: u64 = fi[0].tile_info[0].size;
            const tw: u64 = fi[0].tile_info[0].width;
            const th: u64 = fi[0].tile_info[0].height;
            const nx = gintDiv(up(wide(info.width), tw), tw);
            const ny = gintDiv(up(wide(info.height), th), th);
            s[0] = tileStride(nx, ny);
            s[1] = tileStride(nx, up(ny, 2) / 2);
            o[1] = nx *% ny *% size;
            info.size = o[1] +% nx *% up(ny, 2) / 2 *% size;
        },
        c.GST_VIDEO_FORMAT_NV12_16L32S => {
            const ys: u64 = fi[0].tile_info[0].size;
            const uvs: u64 = fi[0].tile_info[1].size;
            const tw: u64 = fi[0].tile_info[0].width;
            const th: u64 = fi[0].tile_info[0].height;
            const nx = gintDiv(up(wide(info.width), tw), tw);
            const ny = gintDiv(up(wide(info.height), th), th);
            s[0] = tileStride(nx, ny);
            s[1] = s[0];
            o[0] = 0;
            o[1] = nx *% ny *% ys;
            info.size = o[1] +% nx *% ny *% uvs;
        },
        c.GST_VIDEO_FORMAT_NV12_8L128, c.GST_VIDEO_FORMAT_NV12_10BE_8L128 => {
            const size: u64 = fi[0].tile_info[0].size;
            const th: u64 = fi[0].tile_info[0].height;
            const tiled10 = fi[0].format == c.GST_VIDEO_FORMAT_NV12_10BE_8L128;
            const tw: u64 = if (tiled10) fi[0].tile_info[0].stride else fi[0].tile_info[0].width;
            const span: u64 = if (tiled10) @as(u32, @truncate(up(width * 10, 8) >> 3)) else width;
            const ah: u64 = if (interlaced) th * 2 else th;
            const nx: u32 = @truncate(up(span, tw) / tw);
            const ny: u32 = @truncate(up(height, ah) / th);
            const uny: u32 = @truncate(up(ny, 2) / 2);
            s[0] = tileStride(nx, ny);
            s[1] = tileStride(nx, uny);
            o[0] = 0;
            const ts: u32 = @truncate(size);
            o[1] = nx *% ny *% ts;
            info.size = o[1] +% nx *% uny *% ts;
        },
        c.GST_VIDEO_FORMAT_MT2110T, c.GST_VIDEO_FORMAT_MT2110R => {
            const size: u64 = fi[0].tile_info[0].size;
            const nx = gintDiv(up(wide(info.width), 16), 16);
            const ny = gintDiv(up(wide(info.height), 32), 32);
            s[0] = tileStride(nx, ny);
            s[1] = s[0];
            o[0] = 0;
            o[1] = size *% nx *% ny;
            info.size = o[1] +% o[1] / 2;
        },
        c.GST_VIDEO_FORMAT_ENCODED, c.GST_VIDEO_FORMAT_DMA_DRM => {},
        c.GST_VIDEO_FORMAT_UNKNOWN => {
            c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "invalid format");
            return false;
        },
        else => {},
    }
    if (plane_size) |ps| {
        for (0..4) |i| {
            if (i < fi[0].n_planes) {
                if (fi[0].tile_mode != 0) {
                    const xt: u64 = @as(u32, @bitCast(s[i])) & 0xffff;
                    const yt: u64 = @as(u32, @bitCast(s[i])) >> 16;
                    ps[i] = xt * yt * fi[0].tile_info[i].size;
                } else {
                    var comp: [4]c.gint = undefined;
                    format.gst_video_format_info_component(fi, @intCast(i), &comp);
                    const ph: c.guint = @bitCast(subScale(fi[0].h_sub[@intCast(comp[0])], fieldHeightExact(info)));
                    ps[i] = @as(u64, ph) *% wide(s[i]);
                }
            } else ps[i] = 0;
        }
    }
    return true;
}

fn gintDiv(a: u64, b: u64) u64 {
    const x: c.gint = @bitCast(@as(u32, @truncate(a)));
    const y: c.gint = @bitCast(@as(u32, @truncate(b)));
    return wide(@divTrunc(x, y));
}

fn single(info: *Info, stride: c.gint, height: u64) void {
    info.stride[0] = stride;
    info.offset[0] = 0;
    info.size = wide(stride) *% height;
}

fn equal(info: *Info, stride: c.gint, height: u64, n: u64) void {
    for (0..@intCast(n)) |i| info.stride[i] = stride;
    info.offset[0] = 0;
    info.offset[1] = wide(stride) *% height;
    info.offset[2] = info.offset[1] *% 2;
    if (n == 4) info.offset[3] = info.offset[1] *% 3;
    info.size = wide(stride) *% height *% n;
}

fn planar420(info: *Info, s0: c.gint, s1: c.gint, height: u64, interlaced: bool, alpha: bool) void {
    const s = &info.stride;
    const o = &info.offset;
    s[0] = s0;
    s[1] = s1;
    s[2] = s1;
    if (alpha) s[3] = s0;
    o[0] = 0;
    o[1] = wide(s0) *% up(height, 2);
    var cr_h = up(height, 2) / 2;
    if (interlaced) cr_h = up(cr_h, 2);
    o[2] = o[1] +% wide(s1) *% cr_h;
    if (alpha) {
        o[3] = o[2] +% wide(s1) *% cr_h;
        info.size = o[3] +% wide(s0) *% up(height, 2);
    } else info.size = o[2] +% wide(s1) *% cr_h;
}

fn semi420(info: *Info, s0: c.gint, height: u64, interlaced: bool) void {
    info.stride[0] = s0;
    info.stride[1] = s0;
    info.offset[0] = 0;
    info.offset[1] = wide(s0) *% up(height, 2);
    var cr_h = up(height, 2) / 2;
    if (interlaced) cr_h = up(cr_h, 2);
    info.size = info.offset[1] +% wide(s0) *% cr_h;
}

fn planarFull(info: *Info, s0: c.gint, s1: c.gint, height: u64) void {
    const s = &info.stride;
    const o = &info.offset;
    s[0] = s0;
    s[1] = s1;
    s[2] = s1;
    s[3] = s0;
    o[0] = 0;
    o[1] = wide(s0) *% up(height, 2);
    o[2] = o[1] +% wide(s1) *% up(height, 2);
    o[3] = o[2] +% wide(s1) *% up(height, 2);
    info.size = o[3] +% wide(s0) *% up(height, 2);
}

pub export fn gst_video_info_convert(info: [*c]const Info, src_format: c.GstFormat, src_value: c_long, dest_format: c.GstFormat, dest_value: [*c]c_long) c.gboolean {
    const fname = "gst_video_info_convert";
    if (!check.that(info != null, fname, "info != NULL")) return 0;
    const v = cref(info);
    if (!check.that(v.finfo != null, fname, "info->finfo != NULL")) return 0;
    if (!check.that(v.finfo[0].format != c.GST_VIDEO_FORMAT_UNKNOWN, fname, "info->finfo->format != GST_VIDEO_FORMAT_UNKNOWN")) return 0;
    if (!check.that(v.size > 0, fname, "info->size > 0")) return 0;
    const size: u64 = v.size;
    const fps_n = v.fps_n;
    const fps_d = v.fps_d;
    const src: u64 = @bitCast(src_value);
    const SECOND: i64 = c.GST_SECOND;
    const scale = c.gst_util_uint64_scale;
    if (src_format == dest_format) {
        dest_value.* = src_value;
        return 1;
    }
    if (src_value == -1) {
        dest_value.* = -1;
        return 1;
    }
    const B = c.GST_FORMAT_BYTES;
    const D = c.GST_FORMAT_DEFAULT;
    const T = c.GST_FORMAT_TIME;
    var r: u64 = 0;
    if (src_format == B and dest_format == D) {
        r = if (size != 0) scale(src, 1, size) else 0;
    } else if (src_format == D and dest_format == B) {
        r = scale(src, size, 1);
    } else if (src_format == T and dest_format == D) {
        r = if (fps_d != 0) scale(src, wide(fps_n), @bitCast(SECOND *% fps_d)) else 0;
    } else if (src_format == D and dest_format == T) {
        r = if (fps_n != 0) scale(src, @bitCast(SECOND *% fps_d), wide(fps_n)) else 0;
    } else if (src_format == T and dest_format == B) {
        r = if (fps_d != 0) scale(src, wide(fps_n) *% size, @bitCast(SECOND *% fps_d)) else 0;
    } else if (src_format == B and dest_format == T) {
        r = if (fps_n != 0 and size != 0) scale(src, @bitCast(SECOND *% fps_d), wide(fps_n) *% size) else 0;
    } else return 0;
    dest_value.* = @bitCast(r);
    return 1;
}

pub export fn gst_video_info_align_full(info_in: [*c]Info, al_in: [*c]c.GstVideoAlignment, plane_size_in: [*c]c.gsize) c.gboolean {
    const info = ref(info_in);
    const al: *c.GstVideoAlignment = @ptrCast(al_in);
    const plane_size: ?*[4]c.gsize = if (plane_size_in == null) null else @ptrCast(plane_size_in);
    const fi = info.finfo;
    const width = info.width;
    const height = info.height;
    var n_planes: usize = fi[0].n_planes;
    if (fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_PALETTE != 0) n_planes -= 1;
    while (true) {
        var aligned = true;
        for (0..n_planes) |i| {
            var comp: [4]c.gint = undefined;
            format.gst_video_format_info_component(fi, @intCast(i), &comp);
            const k: usize = @intCast(comp[0]);
            var hedge = subScale(fi[0].w_sub[k], @bitCast(al.padding_left));
            hedge *%= fi[0].pixel_stride[k];
            aligned = aligned and (@as(c.guint, @bitCast(hedge)) & al.stride_align[i]) == 0;
        }
        if (aligned) break;
        al.padding_left +%= al.padding_left & ~(al.padding_left -% 1);
    }
    var pw: c.gint = width +% @as(c.gint, @bitCast(al.padding_left)) +% @as(c.gint, @bitCast(al.padding_right));
    const ph: c.gint = height +% @as(c.gint, @bitCast(al.padding_top)) +% @as(c.gint, @bitCast(al.padding_bottom));
    while (true) {
        info.width = pw;
        info.height = ph;
        if (!fill(info, plane_size)) return 0;
        var aligned = true;
        for (0..n_planes) |i| aligned = aligned and (@as(c.guint, @bitCast(info.stride[i])) & al.stride_align[i]) == 0;
        if (aligned) break;
        pw +%= pw & ~(pw -% 1);
    }
    al.padding_right = @bitCast(pw -% width -% @as(c.gint, @bitCast(al.padding_left)));
    info.width = width;
    info.height = height;
    for (0..n_planes) |i| {
        var comp: [4]c.gint = undefined;
        format.gst_video_format_info_component(fi, @intCast(i), &comp);
        const k: usize = @intCast(comp[0]);
        const hedge = subScale(fi[0].w_sub[k], @bitCast(al.padding_left));
        const vedge = subScale(fi[0].h_sub[k], @bitCast(al.padding_top));
        info.offset[i] +%= wide(vedge *% info.stride[i]) +% wide(hedge *% fi[0].pixel_stride[k]);
    }
    return 1;
}

pub export fn gst_video_info_align(info: [*c]Info, al: [*c]c.GstVideoAlignment) c.gboolean {
    return gst_video_info_align_full(info, al, null);
}
