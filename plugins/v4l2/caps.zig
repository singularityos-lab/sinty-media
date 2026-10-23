const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const sys = @import("sys.zig");
const V = sys.v;

const Fmt = struct {
    v4l2: u32,
    gst: [:0]const u8,
    rank: c_int,
};

const YUV = 1000;
const JPEG = 500;
const DV = 200;
const RGB = 100;
const YUV_ODD = 50;
const RGB_ODD = 25;
const BAYER = 15;
const GREY = 5;

const f = sys.fourcc;
const fb = sys.fourccBe;

const raw = [_]Fmt{
    .{ .v4l2 = f("XR15"), .gst = "RGB15", .rank = RGB_ODD },
    .{ .v4l2 = f("RGBP"), .gst = "RGB16", .rank = RGB_ODD },
    .{ .v4l2 = f("BGR3"), .gst = "BGR", .rank = RGB - 1 },
    .{ .v4l2 = f("RGB3"), .gst = "RGB", .rank = RGB - 1 },
    .{ .v4l2 = f("AR24"), .gst = "BGRA", .rank = RGB },
    .{ .v4l2 = f("XR24"), .gst = "BGRx", .rank = RGB },
    .{ .v4l2 = f("RA24"), .gst = "ABGR", .rank = RGB },
    .{ .v4l2 = f("RX24"), .gst = "xBGR", .rank = RGB },
    .{ .v4l2 = f("AB24"), .gst = "RGBA", .rank = RGB },
    .{ .v4l2 = f("XB24"), .gst = "RGBx", .rank = RGB },
    .{ .v4l2 = f("BA24"), .gst = "ARGB", .rank = RGB },
    .{ .v4l2 = f("BX24"), .gst = "xRGB", .rank = RGB },
    .{ .v4l2 = f("AR30"), .gst = "BGR10A2_LE", .rank = RGB },
    .{ .v4l2 = f("RGBO"), .gst = "RGB15", .rank = RGB_ODD },
    .{ .v4l2 = f("RGBQ"), .gst = "BGR15", .rank = RGB_ODD },
    .{ .v4l2 = f("BGR4"), .gst = "BGRx", .rank = RGB },
    .{ .v4l2 = f("RGB4"), .gst = "xRGB", .rank = RGB },
    .{ .v4l2 = f("GREY"), .gst = "GRAY8", .rank = GREY },
    .{ .v4l2 = f("Y16 "), .gst = "GRAY16_LE", .rank = 0 },
    .{ .v4l2 = fb("Y16 "), .gst = "GRAY16_BE", .rank = 0 },
    .{ .v4l2 = f("YUV9"), .gst = "YUV9", .rank = YUV + 2 },
    .{ .v4l2 = f("YVU9"), .gst = "YVU9", .rank = YUV + 3 },
    .{ .v4l2 = f("YM12"), .gst = "I420", .rank = YUV + 7 },
    .{ .v4l2 = f("YU12"), .gst = "I420", .rank = YUV + 7 },
    .{ .v4l2 = f("YM21"), .gst = "YV12", .rank = YUV + 6 },
    .{ .v4l2 = f("YV12"), .gst = "YV12", .rank = YUV + 6 },
    .{ .v4l2 = f("YUYV"), .gst = "YUY2", .rank = YUV + 10 },
    .{ .v4l2 = f("YVYU"), .gst = "YVYU", .rank = 0 },
    .{ .v4l2 = f("UYVY"), .gst = "UYVY", .rank = YUV + 9 },
    .{ .v4l2 = f("VYUY"), .gst = "VYUY", .rank = 0 },
    .{ .v4l2 = f("YM16"), .gst = "Y42B", .rank = YUV + 8 },
    .{ .v4l2 = f("422P"), .gst = "Y42B", .rank = YUV + 8 },
    .{ .v4l2 = f("411P"), .gst = "Y41B", .rank = YUV + 4 },
    .{ .v4l2 = f("NM12"), .gst = "NV12", .rank = YUV + 8 },
    .{ .v4l2 = f("NV12"), .gst = "NV12", .rank = YUV + 8 },
    .{ .v4l2 = f("NM21"), .gst = "NV21", .rank = YUV_ODD },
    .{ .v4l2 = f("NV21"), .gst = "NV21", .rank = YUV_ODD },
    .{ .v4l2 = f("NM16"), .gst = "NV16", .rank = YUV_ODD },
    .{ .v4l2 = f("NV16"), .gst = "NV16", .rank = YUV_ODD },
    .{ .v4l2 = f("NM61"), .gst = "NV61", .rank = YUV_ODD },
    .{ .v4l2 = f("NV61"), .gst = "NV61", .rank = YUV_ODD },
    .{ .v4l2 = f("NV24"), .gst = "NV24", .rank = YUV_ODD },
    .{ .v4l2 = f("P010"), .gst = "P010_10LE", .rank = 0 },
};

const bayer = [_]struct { v4l2: u32, name: [:0]const u8 }{
    .{ .v4l2 = f("BA81"), .name = "bggr" },
    .{ .v4l2 = f("GBRG"), .name = "gbrg" },
    .{ .v4l2 = f("GRBG"), .name = "grbg" },
    .{ .v4l2 = f("RGGB"), .name = "rggb" },
    .{ .v4l2 = f("BG10"), .name = "bggr10le" },
    .{ .v4l2 = f("GB10"), .name = "gbrg10le" },
    .{ .v4l2 = f("BA10"), .name = "grbg10le" },
    .{ .v4l2 = f("RG10"), .name = "rggb10le" },
    .{ .v4l2 = f("BG12"), .name = "bggr12le" },
    .{ .v4l2 = f("GB12"), .name = "gbrg12le" },
    .{ .v4l2 = f("BA12"), .name = "grbg12le" },
    .{ .v4l2 = f("RG12"), .name = "rggb12le" },
    .{ .v4l2 = f("BG14"), .name = "bggr14le" },
    .{ .v4l2 = f("GB14"), .name = "gbrg14le" },
    .{ .v4l2 = f("GR14"), .name = "grbg14le" },
    .{ .v4l2 = f("RG14"), .name = "rggb14le" },
    .{ .v4l2 = f("BYR2"), .name = "bggr16le" },
    .{ .v4l2 = f("GB16"), .name = "gbrg16le" },
    .{ .v4l2 = f("GR16"), .name = "grbg16le" },
    .{ .v4l2 = f("RG16"), .name = "rggb16le" },
};

pub const MJPEG = f("MJPG");
pub const JPEG_FMT = f("JPEG");
pub const PJPG = f("PJPG");
pub const MPEG = f("MPEG");

pub fn rank(fourcc: u32) c_int {
    if (fourcc == MJPEG or fourcc == PJPG) return JPEG;
    if (fourcc == JPEG_FMT) return JPEG + 1;
    if (fourcc == MPEG) return JPEG + 2;
    if (fourcc == f("dvsd")) return DV;
    for (raw) |r| {
        if (r.v4l2 == fourcc) return r.rank;
    }
    for (bayer) |b| {
        if (b.v4l2 == fourcc) return BAYER;
    }
    return 0;
}

pub fn rawFormat(fourcc: u32) ?[:0]const u8 {
    for (raw) |r| {
        if (r.v4l2 == fourcc) return r.gst;
    }
    return null;
}

pub fn fourccFor(s: *const c.GstStructure) u32 {
    const name = std.mem.span(c.gst_structure_get_name(s));
    if (std.mem.eql(u8, name, "image/jpeg")) return MJPEG;
    if (std.mem.eql(u8, name, "video/x-h264")) {
        const sf = c.gst_structure_get_string(s, "stream-format");
        if (sf != null and std.mem.eql(u8, std.mem.span(sf), "avc")) return f("AVC1");
        return f("H264");
    }
    if (std.mem.eql(u8, name, "video/x-h265")) return f("HEVC");
    if (std.mem.eql(u8, name, "video/x-vp8")) return f("VP80");
    if (std.mem.eql(u8, name, "video/x-vp9")) return f("VP90");
    if (std.mem.eql(u8, name, "video/x-dv")) return f("dvsd");
    if (std.mem.eql(u8, name, "video/mpegts")) return MPEG;
    if (std.mem.eql(u8, name, "video/x-bayer")) {
        const fmt = c.gst_structure_get_string(s, "format") orelse return 0;
        for (bayer) |b| {
            if (std.mem.eql(u8, b.name, std.mem.span(fmt))) return b.v4l2;
        }
        return 0;
    }
    if (std.mem.eql(u8, name, "video/x-raw")) {
        const fmt = c.gst_structure_get_string(s, "format") orelse return 0;
        for (raw) |r| {
            if (std.mem.eql(u8, r.gst, std.mem.span(fmt))) return r.v4l2;
        }
    }
    return 0;
}

pub fn fourccFromAvailable(s: *const c.GstStructure, avail: []const u32) u32 {
    const name = std.mem.span(c.gst_structure_get_name(s));
    if (std.mem.eql(u8, name, "image/jpeg")) {
        for (avail) |a| {
            if (a == MJPEG or a == JPEG_FMT or a == PJPG) return a;
        }
        return 0;
    }
    if (std.mem.eql(u8, name, "video/x-raw")) {
        const fmt = c.gst_structure_get_string(s, "format") orelse return 0;
        for (avail) |a| {
            if (rawFormat(a)) |g| {
                if (std.mem.eql(u8, g, std.mem.span(fmt))) return a;
            }
        }
        return 0;
    }
    const want = fourccFor(s);
    for (avail) |a| {
        if (a == want) return a;
    }
    return 0;
}

pub fn bare(fourcc: u32) ?*c.GstStructure {
    if (fourcc == MJPEG or fourcc == PJPG or fourcc == JPEG_FMT) return c.gst_structure_new("image/jpeg", "parsed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), @as(?*anyopaque, null));
    if (fourcc == f("H264")) return c.gst_structure_new("video/x-h264", "stream-format", c.G_TYPE_STRING, "byte-stream", "alignment", c.G_TYPE_STRING, "au", @as(?*anyopaque, null));
    if (fourcc == f("AVC1")) return c.gst_structure_new("video/x-h264", "stream-format", c.G_TYPE_STRING, "avc", "alignment", c.G_TYPE_STRING, "au", @as(?*anyopaque, null));
    if (fourcc == f("HEVC")) return c.gst_structure_new("video/x-h265", "stream-format", c.G_TYPE_STRING, "byte-stream", "alignment", c.G_TYPE_STRING, "au", @as(?*anyopaque, null));
    if (fourcc == f("VP80")) return c.gst_structure_new_empty("video/x-vp8");
    if (fourcc == f("VP90")) return c.gst_structure_new_empty("video/x-vp9");
    if (fourcc == f("dvsd")) return c.gst_structure_new("video/x-dv", "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), @as(?*anyopaque, null));
    if (fourcc == MPEG) return c.gst_structure_new("video/mpegts", "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), @as(?*anyopaque, null));
    for (bayer) |b| {
        if (b.v4l2 == fourcc) return c.gst_structure_new("video/x-bayer", "format", c.G_TYPE_STRING, b.name.ptr, @as(?*anyopaque, null));
    }
    if (rawFormat(fourcc)) |g| return c.gst_structure_new("video/x-raw", "format", c.G_TYPE_STRING, g.ptr, @as(?*anyopaque, null));
    return null;
}

fn fraction(num: u32, den: u32) [2]c.gint {
    var n = num;
    var d = den;
    if (n > std.math.maxInt(c.gint) or d > std.math.maxInt(c.gint)) {
        n >>= 1;
        d >>= 1;
    }
    return .{ @intCast(n), @intCast(d) };
}

fn simplify(v: *c.GValue) void {
    if (c.gst_value_list_get_size(v) == 1) {
        var one = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&one, c.gst_fraction_get_type());
        c.g_value_copy(c.gst_value_list_get_value(v, 0), &one);
        c.g_value_unset(v);
        v.* = one;
    }
}

fn forSize(fd: c_int, fourcc: u32, w: u32, h: u32, tmpl: *c.GstStructure, par: [*c]const c.GValue) ?*c.GstStructure {
    var iv = std.mem.zeroes(V.struct_v4l2_frmivalenum);
    iv.pixel_format = fourcc;
    iv.width = w;
    iv.height = h;
    var rates = std.mem.zeroes(c.GValue);
    var have = false;
    if (sys.xioctl(fd, sys.ENUM_FRAMEINTERVALS, &iv) >= 0) {
        if (iv.type == V.V4L2_FRMIVAL_TYPE_DISCRETE) {
            _ = c.g_value_init(&rates, c.gst_value_list_get_type());
            var r = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&r, c.gst_fraction_get_type());
            while (true) {
                const fr = fraction(iv.unnamed_0.discrete.numerator, iv.unnamed_0.discrete.denominator);
                c.gst_value_set_fraction(&r, fr[1], fr[0]);
                c.gst_value_list_append_value(&rates, &r);
                iv.index += 1;
                if (sys.xioctl(fd, sys.ENUM_FRAMEINTERVALS, &iv) < 0) break;
            }
            c.g_value_unset(&r);
            have = true;
        } else if (iv.type == V.V4L2_FRMIVAL_TYPE_STEPWISE) {
            _ = c.g_value_init(&rates, c.gst_value_list_get_type());
            var lo = std.mem.zeroes(c.GValue);
            var step = std.mem.zeroes(c.GValue);
            var hi = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&lo, c.gst_fraction_get_type());
            _ = c.g_value_init(&step, c.gst_fraction_get_type());
            _ = c.g_value_init(&hi, c.gst_fraction_get_type());
            const sw = iv.unnamed_0.stepwise;
            const mn = fraction(sw.min.numerator, sw.min.denominator);
            const mx = fraction(sw.max.numerator, sw.max.denominator);
            var st = fraction(sw.step.numerator, sw.step.denominator);
            if (st[0] == 0 or st[1] == 0) st = mx;
            c.gst_value_set_fraction(&lo, mn[0], mn[1]);
            c.gst_value_set_fraction(&hi, mx[0], mx[1]);
            c.gst_value_set_fraction(&step, -st[0], st[1]);
            while (c.gst_value_compare(&lo, &hi) != c.GST_VALUE_GREATER_THAN) {
                var r = std.mem.zeroes(c.GValue);
                _ = c.g_value_init(&r, c.gst_fraction_get_type());
                c.gst_value_set_fraction(&r, c.gst_value_get_fraction_denominator(&lo), c.gst_value_get_fraction_numerator(&lo));
                c.gst_value_list_append_and_take_value(&rates, &r);
                have = true;
                if (c.gst_value_fraction_subtract(&lo, &lo, &step) == 0) break;
            }
            c.g_value_unset(&lo);
            c.g_value_unset(&step);
            c.g_value_unset(&hi);
            if (!have) c.g_value_unset(&rates);
        } else if (iv.type == V.V4L2_FRMIVAL_TYPE_CONTINUOUS) {
            const sw = iv.unnamed_0.stepwise;
            const mn = fraction(sw.min.numerator, sw.min.denominator);
            const mx = fraction(sw.max.numerator, sw.max.denominator);
            _ = c.g_value_init(&rates, c.gst_fraction_range_get_type());
            c.gst_value_set_fraction_range_full(&rates, mx[1], mx[0], mn[1], mn[0]);
            have = true;
        } else return null;
    }
    const s = c.gst_structure_copy(tmpl);
    c.gst_structure_set(s, "width", c.G_TYPE_INT, @as(c.gint, @intCast(w)), "height", c.G_TYPE_INT, @as(c.gint, @intCast(h)), @as(?*anyopaque, null));
    if (par != null) c.gst_structure_set_value(s, "pixel-aspect-ratio", par);
    if (have) {
        if (c.g_type_check_value_holds(&rates, c.gst_value_list_get_type()) != 0) simplify(&rates);
        c.gst_structure_take_value(s, "framerate", &rates);
    } else c.gst_structure_set(s, "framerate", c.gst_fraction_range_get_type(), @as(c.gint, 0), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), @as(c.gint, 1), @as(?*anyopaque, null));
    return s;
}

fn area(s: *c.GstStructure) c.gint {
    var w: c.gint = 0;
    var h: c.gint = 0;
    _ = c.gst_structure_get_int(s, "width", &w);
    _ = c.gst_structure_get_int(s, "height", &h);
    return w * h;
}

fn bySize(_: void, a: *c.GstStructure, b: *c.GstStructure) bool {
    return area(a) > area(b);
}

fn merge(fields: *c.GstStructure, tmpl: *c.GstStructure) *c.GstStructure {
    const s = c.gst_structure_copy(tmpl);
    const n = c.gst_structure_n_fields(fields);
    var i: c.gint = 0;
    while (i < n) : (i += 1) {
        const name = c.gst_structure_nth_field_name(fields, @intCast(i));
        c.gst_structure_set_value(s, name, c.gst_structure_get_value(fields, name));
    }
    c.gst_structure_free(fields);
    return s.?;
}

fn forFormat(fd: c_int, fourcc: u32, tmpl: *c.GstStructure, par: [*c]const c.GValue, out: *c.GstCaps) void {
    if (fourcc == MPEG) {
        c.gst_caps_append_structure(out, c.gst_structure_copy(tmpl));
        return;
    }
    const holder = c.gst_structure_new_empty("fields/holder").?;
    defer c.gst_structure_free(holder);
    var fs = std.mem.zeroes(V.struct_v4l2_frmsizeenum);
    fs.pixel_format = fourcc;
    var list: std.ArrayListUnmanaged(*c.GstStructure) = .empty;
    defer list.deinit(std.heap.c_allocator);
    const max = std.math.maxInt(c.gint);
    if (sys.xioctl(fd, sys.ENUM_FRAMESIZES, &fs) >= 0) {
        if (fs.type == V.V4L2_FRMSIZE_TYPE_DISCRETE) {
            while (true) {
                const w: u32 = @min(fs.unnamed_0.discrete.width, max);
                const h: u32 = @min(fs.unnamed_0.discrete.height, max);
                if (w != 0 and h != 0) {
                    if (forSize(fd, fourcc, w, h, holder, par)) |s| list.append(std.heap.c_allocator, s) catch {};
                }
                fs.index += 1;
                if (sys.xioctl(fd, sys.ENUM_FRAMESIZES, &fs) < 0) break;
            }
            std.mem.sort(*c.GstStructure, list.items, {}, bySize);
            for (list.items) |s| c.gst_caps_append_structure_full(out, merge(s, tmpl), c.gst_caps_features_new_single_static_str(c.GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY));
            if (list.items.len != 0) return;
        } else if (fs.type == V.V4L2_FRMSIZE_TYPE_STEPWISE or fs.type == V.V4L2_FRMSIZE_TYPE_CONTINUOUS) {
            const sw = fs.unnamed_0.stepwise;
            const cont = fs.type == V.V4L2_FRMSIZE_TYPE_CONTINUOUS;
            const step_w: u32 = if (cont) 1 else @max(sw.step_width, 1);
            const step_h: u32 = if (cont) 1 else @max(sw.step_height, 1);
            const w = @max(sw.min_width, step_w);
            const h = @max(sw.min_height, step_h);
            var mw: u32 = @min(sw.max_width, max);
            var mh: u32 = @min(sw.max_height, max);
            if (!cont) {
                mw -= mw % step_w;
                mh -= mh % step_h;
            }
            if (forSize(fd, fourcc, w, h, holder, par)) |s| {
                var range = std.mem.zeroes(c.GValue);
                _ = c.g_value_init(&range, c.gst_int_range_get_type());
                c.gst_value_set_int_range_step(&range, @intCast(w), @intCast(mw), @intCast(step_w));
                c.gst_structure_set_value(s, "width", &range);
                c.gst_value_set_int_range_step(&range, @intCast(h), @intCast(mh), @intCast(step_h));
                c.gst_structure_take_value(s, "height", &range);
                c.gst_caps_append_structure_full(out, merge(s, tmpl), c.gst_caps_features_new_single_static_str(c.GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY));
                return;
            }
        }
    }
    const s = c.gst_structure_copy(holder);
    c.gst_structure_set(s, "framerate", c.gst_fraction_range_get_type(), @as(c.gint, 0), @as(c.gint, 1), @as(c.gint, max), @as(c.gint, 1), "width", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, 32768), "height", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, 32768), @as(?*anyopaque, null));
    if (par != null) c.gst_structure_set_value(s, "pixel-aspect-ratio", par);
    c.gst_caps_append_structure_full(out, merge(s, tmpl), c.gst_caps_features_new_single_static_str(c.GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY));
}

pub const Desc = struct {
    fourcc: u32,
    rank: c_int,
};

fn byRank(_: void, a: Desc, b: Desc) bool {
    return a.rank > b.rank;
}

pub fn formats(fd: c_int, out: *std.ArrayListUnmanaged(Desc)) bool {
    var i: u32 = 0;
    while (true) : (i += 1) {
        var d = std.mem.zeroes(V.struct_v4l2_fmtdesc);
        d.index = i;
        d.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (sys.xioctl(fd, sys.ENUM_FMT, &d) < 0) {
            if (sys.errno() == V.EINVAL) break;
            return false;
        }
        var dup = false;
        for (out.items) |e| {
            if (e.fourcc == d.pixelformat) dup = true;
        }
        if (!dup) out.append(std.heap.c_allocator, .{ .fourcc = d.pixelformat, .rank = rank(d.pixelformat) }) catch {};
    }
    std.mem.sort(Desc, out.items, {}, byRank);
    return true;
}

pub fn probe(fd: c_int, list: []const Desc, par: [*c]const c.GValue) [*c]c.GstCaps {
    const all = c.gst_caps_new_empty();
    for (list) |d| {
        const tmpl = bare(d.fourcc) orelse continue;
        defer c.gst_structure_free(tmpl);
        forFormat(fd, d.fourcc, tmpl, par, all);
    }
    const sys_caps = c.gst_caps_new_empty();
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(all)) : (i += 1) c.gst_caps_append_structure(sys_caps, c.gst_structure_copy(c.gst_caps_get_structure(all, i)));
    c.gst_caps_unref(all);
    return c.gst_caps_simplify(sys_caps);
}
