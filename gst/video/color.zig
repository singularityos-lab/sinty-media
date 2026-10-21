const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const m = @import("../libm.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Colorimetry = c.GstVideoColorimetry;
const Named = struct { name: ?[*:0]const u8, color: Colorimetry };

fn col(range: c.GstVideoColorRange, matrix: c.GstVideoColorMatrix, transfer: c.GstVideoTransferFunction, primaries: c.GstVideoColorPrimaries) Colorimetry {
    return .{ .range = range, .matrix = matrix, .transfer = transfer, .primaries = primaries };
}

const named = [_]Named{
    .{ .name = "bt601", .color = col(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_BT601, c.GST_VIDEO_TRANSFER_BT601, c.GST_VIDEO_COLOR_PRIMARIES_SMPTE170M) },
    .{ .name = "bt709", .color = col(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_BT709, c.GST_VIDEO_TRANSFER_BT709, c.GST_VIDEO_COLOR_PRIMARIES_BT709) },
    .{ .name = "smpte240m", .color = col(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_SMPTE240M, c.GST_VIDEO_TRANSFER_SMPTE240M, c.GST_VIDEO_COLOR_PRIMARIES_SMPTE240M) },
    .{ .name = "sRGB", .color = col(c.GST_VIDEO_COLOR_RANGE_0_255, c.GST_VIDEO_COLOR_MATRIX_RGB, c.GST_VIDEO_TRANSFER_SRGB, c.GST_VIDEO_COLOR_PRIMARIES_BT709) },
    .{ .name = "bt2020", .color = col(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_BT2020, c.GST_VIDEO_TRANSFER_BT2020_12, c.GST_VIDEO_COLOR_PRIMARIES_BT2020) },
    .{ .name = "bt2020-10", .color = col(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_BT2020, c.GST_VIDEO_TRANSFER_BT2020_10, c.GST_VIDEO_COLOR_PRIMARIES_BT2020) },
    .{ .name = "bt2100-pq", .color = col(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_BT2020, c.GST_VIDEO_TRANSFER_SMPTE2084, c.GST_VIDEO_COLOR_PRIMARIES_BT2020) },
    .{ .name = "bt2100-hlg", .color = col(c.GST_VIDEO_COLOR_RANGE_16_235, c.GST_VIDEO_COLOR_MATRIX_BT2020, c.GST_VIDEO_TRANSFER_ARIB_STD_B67, c.GST_VIDEO_COLOR_PRIMARIES_BT2020) },
    .{ .name = null, .color = col(c.GST_VIDEO_COLOR_RANGE_0_255, c.GST_VIDEO_COLOR_MATRIX_BT601, c.GST_VIDEO_TRANSFER_UNKNOWN, c.GST_VIDEO_COLOR_PRIMARIES_UNKNOWN) },
    .{ .name = null, .color = col(c.GST_VIDEO_COLOR_RANGE_UNKNOWN, c.GST_VIDEO_COLOR_MATRIX_UNKNOWN, c.GST_VIDEO_TRANSFER_UNKNOWN, c.GST_VIDEO_COLOR_PRIMARIES_UNKNOWN) },
};

const unknown = named[named.len - 1].color;

fn same(a: *const Colorimetry, b: *const Colorimetry) bool {
    return a.range == b.range and a.matrix == b.matrix and a.transfer == b.transfer and a.primaries == b.primaries;
}

fn lookup(s: [*c]const u8) ?*const Named {
    for (&named) |*n| {
        const name = n.name orelse break;
        if (c.strcmp(name, s) == 0) return n;
    }
    return null;
}

pub export fn gst_video_colorimetry_from_string(cinfo: *Colorimetry, color: [*c]const u8) c.gboolean {
    if (color == null) {
        cinfo.* = unknown;
        return 1;
    }
    if (lookup(color)) |n| {
        cinfo.* = n.color;
        return 1;
    }
    var r: c.gint = 0;
    var mx: c.gint = 0;
    var t: c.gint = 0;
    var p: c.gint = 0;
    if (c.sscanf(color, "%d:%d:%d:%d", &r, &mx, &t, &p) == 4) {
        cinfo.range = @bitCast(r);
        cinfo.matrix = @bitCast(mx);
        cinfo.transfer = @bitCast(t);
        cinfo.primaries = @bitCast(p);
        return 1;
    }
    return 0;
}

pub export fn gst_video_colorimetry_to_string(cinfo: *const Colorimetry) [*c]u8 {
    for (&named) |*n| {
        const name = n.name orelse break;
        if (same(&n.color, cinfo)) return c.g_strdup(name);
    }
    if (!same(&unknown, cinfo)) return c.g_strdup_printf("%d:%d:%d:%d", cinfo.range, cinfo.matrix, cinfo.transfer, cinfo.primaries);
    return null;
}

pub export fn gst_video_colorimetry_matches(cinfo: *const Colorimetry, color: [*c]const u8) c.gboolean {
    const n = lookup(color) orelse return 0;
    return @intFromBool(same(&n.color, cinfo));
}

fn shl(v: c.gint, n: c.guint) c.gint {
    const sh: u5 = @truncate(n);
    return @bitCast(@as(u32, @bitCast(v)) << sh);
}

pub export fn gst_video_color_range_offsets(range: c.GstVideoColorRange, info: [*c]const c.GstVideoFormatInfo, offset: [*c]c.gint, scale: [*c]c.gint) void {
    const yuv = info[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV != 0;
    const d = info[0].depth;
    if (range == c.GST_VIDEO_COLOR_RANGE_16_235) {
        offset[0] = shl(1, d[0] -% 4);
        scale[0] = shl(219, d[0] -% 8);
        for (1..3) |k| {
            offset[k] = if (yuv) shl(1, d[k] -% 1) else shl(1, d[k] -% 4);
            scale[k] = if (yuv) shl(224, d[k] -% 8) else shl(219, d[k] -% 8);
        }
    } else {
        offset[0] = 0;
        for (1..3) |k| offset[k] = if (yuv) shl(1, d[k] -% 1) else 0;
        for (0..3) |k| scale[k] = shl(1, d[k]) -% 1;
    }
    offset[3] = 0;
    scale[3] = shl(1, d[3]) -% 1;
}

pub export fn gst_video_colorimetry_is_equal(cinfo: ?*const Colorimetry, other: ?*const Colorimetry) c.gboolean {
    const fname = "gst_video_colorimetry_is_equal";
    if (!check.that(cinfo != null, fname, "cinfo != NULL")) return 0;
    if (!check.that(other != null, fname, "other != NULL")) return 0;
    return @intFromBool(same(cinfo.?, other.?));
}

pub export fn gst_video_colorimetry_is_equivalent(cinfo: ?*const Colorimetry, bitdepth: c.guint, other: ?*const Colorimetry, other_bitdepth: c.guint) c.gboolean {
    const fname = "gst_video_colorimetry_is_equivalent";
    if (!check.that(cinfo != null, fname, "cinfo != NULL")) return 0;
    if (!check.that(other != null, fname, "other != NULL")) return 0;
    const a = cinfo.?;
    const b = other.?;
    if (a.range != b.range or a.matrix != b.matrix) return 0;
    if (gst_video_color_primaries_is_equivalent(a.primaries, b.primaries) == 0) return 0;
    return gst_video_transfer_function_is_equivalent(a.transfer, bitdepth, b.transfer, other_bitdepth);
}

const Prim = c.GstVideoColorPrimariesInfo;

fn prim(p: c.GstVideoColorPrimaries, w: [2]f64, v: [6]f64) Prim {
    return .{ .primaries = p, .Wx = w[0], .Wy = w[1], .Rx = v[0], .Ry = v[1], .Gx = v[2], .Gy = v[3], .Bx = v[4], .By = v[5] };
}

const WP_C = [2]f64{ 0.31006, 0.31616 };
const WP_D65 = [2]f64{ 0.31271, 0.32902 };
const WP_CENTRE = [2]f64{ 0, 0 };
const WP_WHITE = [2]f64{ 0.314, 0.351 };

const primaries_table = [_]Prim{
    prim(c.GST_VIDEO_COLOR_PRIMARIES_UNKNOWN, .{ 0, 0 }, .{ 0, 0, 0, 0, 0, 0 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_BT709, WP_D65, .{ 0.64, 0.33, 0.30, 0.60, 0.15, 0.06 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_BT470M, WP_C, .{ 0.67, 0.33, 0.21, 0.71, 0.14, 0.08 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_BT470BG, WP_D65, .{ 0.64, 0.33, 0.29, 0.60, 0.15, 0.06 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_SMPTE170M, WP_D65, .{ 0.63, 0.34, 0.31, 0.595, 0.155, 0.07 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_SMPTE240M, WP_D65, .{ 0.63, 0.34, 0.31, 0.595, 0.155, 0.07 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_FILM, WP_C, .{ 0.681, 0.319, 0.243, 0.692, 0.145, 0.049 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_BT2020, WP_D65, .{ 0.708, 0.292, 0.170, 0.797, 0.131, 0.046 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_ADOBERGB, WP_D65, .{ 0.64, 0.33, 0.21, 0.71, 0.15, 0.06 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_SMPTEST428, WP_CENTRE, .{ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_SMPTERP431, WP_WHITE, .{ 0.68, 0.32, 0.265, 0.69, 0.15, 0.06 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_SMPTEEG432, WP_D65, .{ 0.68, 0.32, 0.265, 0.69, 0.15, 0.06 }),
    prim(c.GST_VIDEO_COLOR_PRIMARIES_EBU3213, WP_D65, .{ 0.63, 0.34, 0.295, 0.605, 0.155, 0.077 }),
};

pub export fn gst_video_color_primaries_get_info(primaries: c.GstVideoColorPrimaries) ?*const Prim {
    if (!check.that(primaries < primaries_table.len, "gst_video_color_primaries_get_info", "(gint) primaries < G_N_ELEMENTS (color_primaries)")) return null;
    return &primaries_table[@intCast(primaries)];
}

fn smpte(p: c.GstVideoColorPrimaries) bool {
    return p == c.GST_VIDEO_COLOR_PRIMARIES_SMPTE170M or p == c.GST_VIDEO_COLOR_PRIMARIES_SMPTE240M;
}

pub export fn gst_video_color_primaries_is_equivalent(primaries: c.GstVideoColorPrimaries, other: c.GstVideoColorPrimaries) c.gboolean {
    return @intFromBool(primaries == other or (smpte(primaries) and smpte(other)));
}

pub export fn gst_video_color_matrix_get_Kr_Kb(matrix: c.GstVideoColorMatrix, kr: *f64, kb: *f64) c.gboolean {
    const v: [2]f64 = switch (matrix) {
        c.GST_VIDEO_COLOR_MATRIX_FCC => .{ 0.30, 0.11 },
        c.GST_VIDEO_COLOR_MATRIX_BT709 => .{ 0.2126, 0.0722 },
        c.GST_VIDEO_COLOR_MATRIX_BT601 => .{ 0.2990, 0.1140 },
        c.GST_VIDEO_COLOR_MATRIX_SMPTE240M => .{ 0.212, 0.087 },
        c.GST_VIDEO_COLOR_MATRIX_BT2020 => .{ 0.2627, 0.0593 },
        else => return 0,
    };
    kr.* = v[0];
    kb.* = v[1];
    return 1;
}

const PQ = struct {
    const c1 = 0.8359375;
    const c2 = 18.8515625;
    const c3 = 18.6875;
    const m1 = 0.1593017578125;
    const m2 = 78.84375;
};

const HLG = struct {
    const a = 0.17883277;
    const b = 0.28466892;
    const k = 0.55991073;
};

pub export fn gst_video_transfer_function_encode(func: c.GstVideoTransferFunction, val: f64) f64 {
    return switch (func) {
        c.GST_VIDEO_TRANSFER_GAMMA18 => m.pow(val, 1.0 / 1.8),
        c.GST_VIDEO_TRANSFER_GAMMA20 => m.pow(val, 1.0 / 2.0),
        c.GST_VIDEO_TRANSFER_GAMMA22 => m.pow(val, 1.0 / 2.2),
        c.GST_VIDEO_TRANSFER_BT601, c.GST_VIDEO_TRANSFER_BT709, c.GST_VIDEO_TRANSFER_BT2020_10 => if (val < 0.018) 4.5 * val else 1.099 * m.pow(val, 0.45) - 0.099,
        c.GST_VIDEO_TRANSFER_SMPTE240M => if (val < 0.0228) val * 4.0 else 1.1115 * m.pow(val, 0.45) - 0.1115,
        c.GST_VIDEO_TRANSFER_SRGB => if (val <= 0.0031308) 12.92 * val else 1.055 * m.pow(val, 1.0 / 2.4) - 0.055,
        c.GST_VIDEO_TRANSFER_GAMMA28 => m.pow(val, 1.0 / 2.8),
        c.GST_VIDEO_TRANSFER_LOG100 => if (val < 0.01) 0.0 else 1.0 + m.log10(val) / 2.0,
        c.GST_VIDEO_TRANSFER_LOG316 => if (val < 0.0031622777) 0.0 else 1.0 + m.log10(val) / 2.5,
        c.GST_VIDEO_TRANSFER_BT2020_12 => if (val < 0.0181) 4.5 * val else 1.0993 * m.pow(val, 0.45) - 0.0993,
        c.GST_VIDEO_TRANSFER_ADOBERGB => m.pow(val, 1.0 / 2.19921875),
        c.GST_VIDEO_TRANSFER_SMPTE2084 => blk: {
            const ln = m.pow(val, PQ.m1);
            break :blk m.pow((PQ.c1 + PQ.c2 * ln) / (1.0 + PQ.c3 * ln), PQ.m2);
        },
        c.GST_VIDEO_TRANSFER_ARIB_STD_B67 => if (val > 1.0 / 12.0) HLG.a * m.log(12.0 * val - HLG.b) + HLG.k else @sqrt(3.0 * val),
        else => val,
    };
}

pub export fn gst_video_transfer_function_decode(func: c.GstVideoTransferFunction, val: f64) f64 {
    return switch (func) {
        c.GST_VIDEO_TRANSFER_GAMMA18 => m.pow(val, 1.8),
        c.GST_VIDEO_TRANSFER_GAMMA20 => m.pow(val, 2.0),
        c.GST_VIDEO_TRANSFER_GAMMA22 => m.pow(val, 2.2),
        c.GST_VIDEO_TRANSFER_BT601, c.GST_VIDEO_TRANSFER_BT709, c.GST_VIDEO_TRANSFER_BT2020_10 => if (val < 0.081) val / 4.5 else m.pow((val + 0.099) / 1.099, 1.0 / 0.45),
        c.GST_VIDEO_TRANSFER_SMPTE240M => if (val < 0.0913) val / 4.0 else m.pow((val + 0.1115) / 1.1115, 1.0 / 0.45),
        c.GST_VIDEO_TRANSFER_SRGB => if (val <= 0.04045) val / 12.92 else m.pow((val + 0.055) / 1.055, 2.4),
        c.GST_VIDEO_TRANSFER_GAMMA28 => m.pow(val, 2.8),
        c.GST_VIDEO_TRANSFER_LOG100 => if (val == 0.0) 0.0 else m.pow(10.0, 2.0 * (val - 1.0)),
        c.GST_VIDEO_TRANSFER_LOG316 => if (val == 0.0) 0.0 else m.pow(10.0, 2.5 * (val - 1.0)),
        c.GST_VIDEO_TRANSFER_BT2020_12 => if (val < 0.08145) val / 4.5 else m.pow((val + 0.0993) / 1.0993, 1.0 / 0.45),
        c.GST_VIDEO_TRANSFER_ADOBERGB => m.pow(val, 2.19921875),
        c.GST_VIDEO_TRANSFER_SMPTE2084 => blk: {
            const t = m.pow(val, 1.0 / PQ.m2);
            const t2 = @max(t - PQ.c1, 0.0);
            break :blk m.pow(t2 / (PQ.c2 - PQ.c3 * t), 1.0 / PQ.m1);
        },
        c.GST_VIDEO_TRANSFER_ARIB_STD_B67 => if (val > 0.5) (m.exp((val - HLG.k) / HLG.a) + HLG.b) / 12.0 else val * val / 3.0,
        else => val,
    };
}

pub export fn gst_video_color_transfer_encode(func: c.GstVideoTransferFunction, val: f64) f64 {
    return gst_video_transfer_function_encode(func, val);
}

pub export fn gst_video_color_transfer_decode(func: c.GstVideoTransferFunction, val: f64) f64 {
    return gst_video_transfer_function_decode(func, val);
}

const matrix_iso = [_][2]c.guint{
    .{ c.GST_VIDEO_COLOR_MATRIX_RGB, 0 },     .{ c.GST_VIDEO_COLOR_MATRIX_BT709, 1 },
    .{ c.GST_VIDEO_COLOR_MATRIX_FCC, 4 },     .{ c.GST_VIDEO_COLOR_MATRIX_BT601, 6 },
    .{ c.GST_VIDEO_COLOR_MATRIX_SMPTE240M, 7 }, .{ c.GST_VIDEO_COLOR_MATRIX_BT2020, 9 },
};

const transfer_iso = [_][2]c.guint{
    .{ c.GST_VIDEO_TRANSFER_BT709, 1 },      .{ c.GST_VIDEO_TRANSFER_GAMMA22, 4 },
    .{ c.GST_VIDEO_TRANSFER_GAMMA28, 5 },    .{ c.GST_VIDEO_TRANSFER_BT601, 6 },
    .{ c.GST_VIDEO_TRANSFER_SMPTE240M, 7 },  .{ c.GST_VIDEO_TRANSFER_GAMMA10, 8 },
    .{ c.GST_VIDEO_TRANSFER_LOG100, 9 },     .{ c.GST_VIDEO_TRANSFER_LOG316, 10 },
    .{ c.GST_VIDEO_TRANSFER_SRGB, 13 },      .{ c.GST_VIDEO_TRANSFER_BT2020_10, 14 },
    .{ c.GST_VIDEO_TRANSFER_BT2020_12, 15 }, .{ c.GST_VIDEO_TRANSFER_SMPTE2084, 16 },
    .{ c.GST_VIDEO_TRANSFER_ARIB_STD_B67, 18 },
};

const primaries_iso = [_][2]c.guint{
    .{ c.GST_VIDEO_COLOR_PRIMARIES_BT709, 1 },       .{ c.GST_VIDEO_COLOR_PRIMARIES_BT470M, 4 },
    .{ c.GST_VIDEO_COLOR_PRIMARIES_BT470BG, 5 },     .{ c.GST_VIDEO_COLOR_PRIMARIES_SMPTE170M, 6 },
    .{ c.GST_VIDEO_COLOR_PRIMARIES_SMPTE240M, 7 },   .{ c.GST_VIDEO_COLOR_PRIMARIES_FILM, 8 },
    .{ c.GST_VIDEO_COLOR_PRIMARIES_BT2020, 9 },      .{ c.GST_VIDEO_COLOR_PRIMARIES_SMPTEST428, 10 },
    .{ c.GST_VIDEO_COLOR_PRIMARIES_SMPTERP431, 11 }, .{ c.GST_VIDEO_COLOR_PRIMARIES_SMPTEEG432, 12 },
    .{ c.GST_VIDEO_COLOR_PRIMARIES_EBU3213, 22 },
};

fn toIso(table: []const [2]c.guint, v: c.guint) c.guint {
    for (table) |e| if (e[0] == v) return e[1];
    return 2;
}

fn fromIso(table: []const [2]c.guint, v: c.guint, none: c.guint) c.guint {
    for (table) |e| if (e[1] == v) return e[0];
    return none;
}

pub export fn gst_video_color_matrix_to_iso(matrix: c.GstVideoColorMatrix) c.guint {
    return toIso(&matrix_iso, matrix);
}

pub export fn gst_video_transfer_function_to_iso(func: c.GstVideoTransferFunction) c.guint {
    return toIso(&transfer_iso, func);
}

pub export fn gst_video_color_primaries_to_iso(primaries: c.GstVideoColorPrimaries) c.guint {
    return toIso(&primaries_iso, primaries);
}

pub export fn gst_video_color_matrix_from_iso(value: c.guint) c.GstVideoColorMatrix {
    if (value == 5) return c.GST_VIDEO_COLOR_MATRIX_BT601;
    return fromIso(&matrix_iso, value, c.GST_VIDEO_COLOR_MATRIX_UNKNOWN);
}

pub export fn gst_video_transfer_function_from_iso(value: c.guint) c.GstVideoTransferFunction {
    return fromIso(&transfer_iso, value, c.GST_VIDEO_TRANSFER_UNKNOWN);
}

pub export fn gst_video_color_primaries_from_iso(value: c.guint) c.GstVideoColorPrimaries {
    return fromIso(&primaries_iso, value, c.GST_VIDEO_COLOR_PRIMARIES_UNKNOWN);
}

fn equivalentTransfer(func: c.GstVideoTransferFunction, bpp: c.guint) c.GstVideoTransferFunction {
    return switch (func) {
        c.GST_VIDEO_TRANSFER_BT2020_12 => if (bpp >= 12) func else c.GST_VIDEO_TRANSFER_BT709,
        c.GST_VIDEO_TRANSFER_BT709, c.GST_VIDEO_TRANSFER_BT601, c.GST_VIDEO_TRANSFER_BT2020_10 => c.GST_VIDEO_TRANSFER_BT709,
        else => func,
    };
}

pub export fn gst_video_transfer_function_is_equivalent(from_func: c.GstVideoTransferFunction, from_bpp: c.guint, to_func: c.GstVideoTransferFunction, to_bpp: c.guint) c.gboolean {
    const a = equivalentTransfer(from_func, from_bpp);
    const b = equivalentTransfer(to_func, to_bpp);
    if (a == c.GST_VIDEO_TRANSFER_BT2020_12 and to_bpp < 12 and b == c.GST_VIDEO_TRANSFER_BT709) return 1;
    return @intFromBool(a == b);
}

comptime {
    std.debug.assert(primaries_table.len == c.GST_VIDEO_COLOR_PRIMARIES_EBU3213 + 1);
}
