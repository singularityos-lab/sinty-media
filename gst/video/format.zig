const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const table = @import("formattable.zig");
const p8 = @import("pack8.zig");
const p16 = @import("pack16.zig");
const tiled = @import("tiled.zig");

const Info = c.GstVideoFormatInfo;
const Unpack = c.GstVideoFormatUnpack;
const Pack = c.GstVideoFormatPack;

const Fns = struct { u: Unpack, p: Pack };

fn of(comptime T: type) Fns {
    return .{ .u = T.unpack, .p = T.pack };
}

fn fns(comptime name: []const u8) ?Fns {
    const eq = std.mem.eql;
    const any = struct {
        fn in(comptime n: []const u8, comptime list: []const []const u8) bool {
            for (list) |e| if (eq(u8, n, e)) return true;
            return false;
        }
    }.in;
    if (any(name, &.{ "I420", "YV12" })) return .{ .u = p8.unpackPlanar420, .p = p8.packPlanar420 };
    if (eq(u8, name, "YUY2")) return .{ .u = p8.unpackYUY2, .p = p8.packYUY2 };
    if (eq(u8, name, "UYVY")) return .{ .u = p8.unpackUYVY, .p = p8.packUYVY };
    if (eq(u8, name, "VYUY")) return .{ .u = p8.unpackVYUY, .p = p8.packVYUY };
    if (eq(u8, name, "YVYU")) return .{ .u = p8.unpackYVYU, .p = p8.packYVYU };
    if (any(name, &.{ "AYUV", "ARGB", "xRGB" })) return .{ .u = p8.unpackCopy4, .p = p8.packCopy4 };
    if (any(name, &.{ "RGBx", "RGBA" })) return of(p8.RGBA);
    if (any(name, &.{ "BGRx", "BGRA" })) return of(p8.BGRA);
    if (any(name, &.{ "xBGR", "ABGR" })) return of(p8.ABGR);
    if (eq(u8, name, "RBGA")) return of(p8.RBGA);
    if (eq(u8, name, "VUYA")) return of(p8.VUYA);
    if (eq(u8, name, "RGB")) return of(p8.RGB);
    if (eq(u8, name, "BGR")) return of(p8.BGR);
    if (eq(u8, name, "v308")) return of(p8.v308);
    if (eq(u8, name, "IYU2")) return of(p8.IYU2);
    if (eq(u8, name, "Y41B")) return .{ .u = p8.unpackY41B, .p = p8.packY41B };
    if (eq(u8, name, "Y42B")) return .{ .u = p8.unpackY42B, .p = p8.packY42B };
    if (eq(u8, name, "A420")) return .{ .u = p8.unpackA420, .p = p8.packA420 };
    if (eq(u8, name, "Y444")) return of(p8.Y444);
    if (any(name, &.{ "GBR", "RGBP", "BGRP" })) return of(p8.GBR);
    if (eq(u8, name, "GBRA")) return .{ .u = p8.unpackGBRA, .p = p8.packGBRA };
    if (eq(u8, name, "GRAY8")) return .{ .u = p8.unpackGRAY8, .p = p8.packGRAY8 };
    if (eq(u8, name, "RGB16")) return of(p8.RGB16);
    if (eq(u8, name, "BGR16")) return of(p8.BGR16);
    if (eq(u8, name, "RGB15")) return of(p8.RGB15);
    if (eq(u8, name, "BGR15")) return of(p8.BGR15);
    if (eq(u8, name, "NV12")) return of(p8.NV12);
    if (eq(u8, name, "NV21")) return of(p8.NV21);
    if (eq(u8, name, "AV12")) return of(p8.AV12);
    if (eq(u8, name, "NV16")) return of(p8.NV16);
    if (eq(u8, name, "NV61")) return of(p8.NV61);
    if (eq(u8, name, "NV24")) return .{ .u = p8.unpackNV24, .p = p8.packNV24 };
    if (eq(u8, name, "RGB8P")) return .{ .u = p8.unpackRGB8P, .p = p8.packRGB8P };
    if (any(name, &.{ "YUV9", "YVU9" })) return .{ .u = p8.unpack410, .p = p8.pack410 };
    if (eq(u8, name, "IYU1")) return .{ .u = p8.unpackIYU1, .p = p8.packIYU1 };
    if (eq(u8, name, "A444")) return .{ .u = p16.unpackA444, .p = p16.packA444 };
    if (eq(u8, name, "A422")) return .{ .u = p16.unpackA422, .p = p16.packA422 };
    if (eq(u8, name, "v210")) return .{ .u = p16.unpackV210, .p = p16.packV210 };
    if (eq(u8, name, "v216")) return .{ .u = p16.unpackV216, .p = p16.packV216 };
    if (eq(u8, name, "UYVP")) return .{ .u = p16.unpackUYVP, .p = p16.packUYVP };
    if (eq(u8, name, "GRAY16_BE")) return of(p16.GRAY16_BE);
    if (eq(u8, name, "GRAY16_LE")) return of(p16.GRAY16_LE);
    if (any(name, &.{ "ARGB64", "AYUV64", "ARGB64_LE" })) return .{ .u = p16.unpackCopy8, .p = p16.packCopy8 };
    if (eq(u8, name, "ARGB64_BE")) return of(p16.ARGB64_swap);
    if (eq(u8, name, "RGBA64_LE")) return of(p16.RGBA64_LE);
    if (eq(u8, name, "RGBA64_BE")) return of(p16.RGBA64_BE);
    if (eq(u8, name, "BGRA64_LE")) return of(p16.BGRA64_LE);
    if (eq(u8, name, "BGRA64_BE")) return of(p16.BGRA64_BE);
    if (eq(u8, name, "ABGR64_LE")) return of(p16.ABGR64_LE);
    if (eq(u8, name, "ABGR64_BE")) return of(p16.ABGR64_BE);
    if (eq(u8, name, "r210")) return .{ .u = p16.unpackR210, .p = p16.packR210 };
    if (eq(u8, name, "Y410")) return of(p16.Y410);
    if (any(name, &.{ "BGR10A2_LE", "BGR10x2_LE" })) return of(p16.BGR10A2);
    if (any(name, &.{ "RGB10A2_LE", "RGB10x2_LE" })) return of(p16.RGB10A2);
    if (any(name, &.{ "I420_10BE", "I420_10LE", "I420_12BE", "I420_12LE" })) return of(p16.I420_16);
    if (any(name, &.{ "I422_10BE", "I422_10LE", "I422_12BE", "I422_12LE" })) return of(p16.I422_16);
    if (any(name, &.{ "Y444_10BE", "Y444_10LE", "Y444_12BE", "Y444_12LE", "Y444_16BE", "Y444_16LE" })) return of(p16.Y444_16);
    if (any(name, &.{ "GBR_10BE", "GBR_10LE", "GBR_12BE", "GBR_12LE", "GBR_16BE", "GBR_16LE" })) return of(p16.GBR_16);
    if (any(name, &.{ "GBRA_10BE", "GBRA_10LE", "GBRA_12BE", "GBRA_12LE" })) return of(p16.GBRA_16);
    if (any(name, &.{ "A420_10BE", "A420_10LE", "A420_12BE", "A420_12LE", "A420_16BE", "A420_16LE" })) return of(p16.A420_16);
    if (any(name, &.{ "A422_10BE", "A422_10LE", "A422_12BE", "A422_12LE", "A422_16BE", "A422_16LE" })) return of(p16.A422_16);
    if (any(name, &.{ "A444_10BE", "A444_10LE", "A444_12BE", "A444_12LE", "A444_16BE", "A444_16LE" })) return of(p16.A444_16);
    if (any(name, &.{ "P010_10BE", "P010_10LE", "P012_BE", "P012_LE", "P016_BE", "P016_LE" })) return .{ .u = p16.unpackP01x, .p = p16.packP01x };
    if (any(name, &.{ "Y210", "Y212_BE", "Y212_LE", "Y216_BE", "Y216_LE" })) return .{ .u = p16.unpackY21x, .p = p16.packY21x };
    if (any(name, &.{ "Y412_BE", "Y412_LE", "Y416_BE", "Y416_LE" })) return .{ .u = p16.unpackY41x, .p = p16.packY41x };
    if (eq(u8, name, "GRAY10_LE16")) return .{ .u = p16.unpackGRAY10_LE16, .p = p16.packGRAY10_LE16 };
    if (eq(u8, name, "GRAY10_LE32")) return .{ .u = p16.unpackGRAY10_LE32, .p = p16.packGRAY10_LE32 };
    if (eq(u8, name, "NV12_10LE32")) return of(p16.NV12_10LE32);
    if (eq(u8, name, "NV16_10LE32")) return of(p16.NV16_10LE32);
    if (eq(u8, name, "NV12_10LE40")) return of(p16.NV12_10LE40);
    if (eq(u8, name, "NV16_10LE40")) return of(p16.NV16_10LE40);
    if (any(name, &.{ "NV12_64Z32", "NV12_4L4", "NV12_32L32", "NV12_16L32S", "NV12_8L128" })) return .{ .u = tiled.unpackNV12Tiled, .p = tiled.packNV12Tiled };
    if (eq(u8, name, "NV12_10LE40_4L4")) return .{ .u = tiled.unpackLE40Tiled, .p = tiled.packLE40Tiled };
    if (eq(u8, name, "NV12_10BE_8L128")) return .{ .u = tiled.unpack8L128, .p = tiled.pack8L128 };
    if (eq(u8, name, "MT2110T")) return of(tiled.MT2110T);
    if (eq(u8, name, "MT2110R")) return of(tiled.MT2110R);
    return null;
}

const N = table.rows.len;

const infos: [N]Info = blk: {
    @setEvalBranchQuota(200000);
    var a: [N]Info = undefined;
    for (table.rows, 0..) |r, i| {
        var f = std.mem.zeroes(Info);
        f.format = r.format;
        f.name = r.name.ptr;
        f.description = r.description.ptr;
        f.flags = r.flags;
        f.bits = r.bits;
        f.n_components = r.n_components;
        f.shift = r.shift;
        f.depth = r.depth;
        f.pixel_stride = r.pixel_stride;
        f.n_planes = r.n_planes;
        f.plane = r.plane;
        f.poffset = r.poffset;
        f.w_sub = r.w_sub;
        f.h_sub = r.h_sub;
        f.unpack_format = r.unpack_format;
        f.pack_lines = r.pack_lines;
        f.tile_mode = r.tile_mode;
        f.tile_ws = r.tile_ws;
        f.tile_hs = r.tile_hs;
        for (0..4) |k| {
            f.tile_info[k].width = r.tiles[k][0];
            f.tile_info[k].height = r.tiles[k][1];
            f.tile_info[k].stride = r.tiles[k][2];
            f.tile_info[k].size = r.tiles[k][3];
        }
        if (fns(r.name)) |x| {
            f.unpack_func = x.u;
            f.pack_func = x.p;
        }
        a[i] = f;
    }
    break :blk a;
};

pub fn get(format: c.GstVideoFormat) [*c]const Info {
    return &infos[@intCast(format)];
}

pub export fn gst_video_format_get_info(format: c.GstVideoFormat) [*c]const Info {
    if (!check.that(format < N, "gst_video_format_get_info", "(gint) format < G_N_ELEMENTS (formats)")) return null;
    return &infos[@intCast(format)];
}

pub export fn gst_video_format_from_string(format: [*c]const u8) c.GstVideoFormat {
    if (!check.that(format != null, "gst_video_format_from_string", "format != NULL")) return c.GST_VIDEO_FORMAT_UNKNOWN;
    for (&infos) |*f| {
        if (c.strcmp(f.name, format) == 0) return f.format;
    }
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}

pub export fn gst_video_format_to_fourcc(format: c.GstVideoFormat) u32 {
    if (!check.that(format != c.GST_VIDEO_FORMAT_UNKNOWN, "gst_video_format_to_fourcc", "format != GST_VIDEO_FORMAT_UNKNOWN")) return 0;
    if (format >= N) return 0;
    return table.rows[@intCast(format)].fourcc;
}

pub export fn gst_video_format_to_string(format: c.GstVideoFormat) [*c]const u8 {
    if (!check.that(format < N, "gst_video_format_to_string", "(gint) format < G_N_ELEMENTS (formats)")) return null;
    return infos[@intCast(format)].name;
}

fn fourcc(s: *const [4]u8) u32 {
    return @as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24;
}

const fourccs = [_]struct { [4]u8, c.GstVideoFormat }{
    .{ "I420".*, c.GST_VIDEO_FORMAT_I420 },        .{ "YV12".*, c.GST_VIDEO_FORMAT_YV12 },
    .{ "YUY2".*, c.GST_VIDEO_FORMAT_YUY2 },        .{ "YVYU".*, c.GST_VIDEO_FORMAT_YVYU },
    .{ "UYVY".*, c.GST_VIDEO_FORMAT_UYVY },        .{ "VYUY".*, c.GST_VIDEO_FORMAT_VYUY },
    .{ "AYUV".*, c.GST_VIDEO_FORMAT_AYUV },        .{ "Y41B".*, c.GST_VIDEO_FORMAT_Y41B },
    .{ "Y42B".*, c.GST_VIDEO_FORMAT_Y42B },        .{ "Y444".*, c.GST_VIDEO_FORMAT_Y444 },
    .{ "v210".*, c.GST_VIDEO_FORMAT_v210 },        .{ "v216".*, c.GST_VIDEO_FORMAT_v216 },
    .{ "Y210".*, c.GST_VIDEO_FORMAT_Y210 },        .{ "NV12".*, c.GST_VIDEO_FORMAT_NV12 },
    .{ "NV21".*, c.GST_VIDEO_FORMAT_NV21 },        .{ "NV16".*, c.GST_VIDEO_FORMAT_NV16 },
    .{ "NV61".*, c.GST_VIDEO_FORMAT_NV61 },        .{ "NV24".*, c.GST_VIDEO_FORMAT_NV24 },
    .{ "v308".*, c.GST_VIDEO_FORMAT_v308 },        .{ "IYU2".*, c.GST_VIDEO_FORMAT_IYU2 },
    .{ "Y800".*, c.GST_VIDEO_FORMAT_GRAY8 },       .{ "Y8  ".*, c.GST_VIDEO_FORMAT_GRAY8 },
    .{ "GREY".*, c.GST_VIDEO_FORMAT_GRAY8 },       .{ "Y16 ".*, c.GST_VIDEO_FORMAT_GRAY16_LE },
    .{ "UYVP".*, c.GST_VIDEO_FORMAT_UYVP },        .{ "A420".*, c.GST_VIDEO_FORMAT_A420 },
    .{ "YUV9".*, c.GST_VIDEO_FORMAT_YUV9 },        .{ "YVU9".*, c.GST_VIDEO_FORMAT_YVU9 },
    .{ "IYU1".*, c.GST_VIDEO_FORMAT_IYU1 },        .{ "AY64".*, c.GST_VIDEO_FORMAT_AYUV64 },
    .{ "XV10".*, c.GST_VIDEO_FORMAT_GRAY10_LE32 }, .{ "XV15".*, c.GST_VIDEO_FORMAT_NV12_10LE32 },
    .{ "XV20".*, c.GST_VIDEO_FORMAT_NV16_10LE32 }, .{ "RK20".*, c.GST_VIDEO_FORMAT_NV12_10LE40 },
    .{ "Y410".*, c.GST_VIDEO_FORMAT_Y410 },        .{ "VUYA".*, c.GST_VIDEO_FORMAT_VUYA },
    .{ "AR30".*, c.GST_VIDEO_FORMAT_BGR10A2_LE },
};

pub export fn gst_video_format_from_fourcc(code: u32) c.GstVideoFormat {
    inline for (fourccs) |e| {
        if (code == fourcc(&e[0])) return e[1];
    }
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}

fn rgb32(r: c.guint, g: c.guint, b: c.guint) c.GstVideoFormat {
    if (r == 0xff000000 and g == 0x00ff0000 and b == 0x0000ff00) return c.GST_VIDEO_FORMAT_RGBx;
    if (r == 0x0000ff00 and g == 0x00ff0000 and b == 0xff000000) return c.GST_VIDEO_FORMAT_BGRx;
    if (r == 0x00ff0000 and g == 0x0000ff00 and b == 0x000000ff) return c.GST_VIDEO_FORMAT_xRGB;
    if (r == 0x000000ff and g == 0x0000ff00 and b == 0x00ff0000) return c.GST_VIDEO_FORMAT_xBGR;
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}

fn rgba32(r: c.guint, g: c.guint, b: c.guint, a: c.guint) c.GstVideoFormat {
    if (r == 0xff000000 and g == 0x00ff0000 and b == 0x0000ff00 and a == 0x000000ff) return c.GST_VIDEO_FORMAT_RGBA;
    if (r == 0x0000ff00 and g == 0x00ff0000 and b == 0xff000000 and a == 0x000000ff) return c.GST_VIDEO_FORMAT_BGRA;
    if (r == 0x00ff0000 and g == 0x0000ff00 and b == 0x000000ff and a == 0xff000000) return c.GST_VIDEO_FORMAT_ARGB;
    if (r == 0x000000ff and g == 0x0000ff00 and b == 0x00ff0000 and a == 0xff000000) return c.GST_VIDEO_FORMAT_ABGR;
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}

fn rgb24(r: c.guint, g: c.guint, b: c.guint) c.GstVideoFormat {
    if (r == 0xff0000 and g == 0x00ff00 and b == 0x0000ff) return c.GST_VIDEO_FORMAT_RGB;
    if (r == 0x0000ff and g == 0x00ff00 and b == 0xff0000) return c.GST_VIDEO_FORMAT_BGR;
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}

fn rgb16(r: c.guint, g: c.guint, b: c.guint) c.GstVideoFormat {
    if (r == 0xf800 and g == 0x07e0 and b == 0x001f) return c.GST_VIDEO_FORMAT_RGB16;
    if (r == 0x001f and g == 0x07e0 and b == 0xf800) return c.GST_VIDEO_FORMAT_BGR16;
    if (r == 0x7c00 and g == 0x03e0 and b == 0x001f) return c.GST_VIDEO_FORMAT_RGB15;
    if (r == 0x001f and g == 0x03e0 and b == 0x7c00) return c.GST_VIDEO_FORMAT_BGR15;
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}

pub export fn gst_video_format_from_masks(depth: c.gint, bpp: c.gint, endianness_in: c.gint, red_in: c.guint, green_in: c.guint, blue_in: c.guint, alpha_in: c.guint) c.GstVideoFormat {
    var r = red_in;
    var g = green_in;
    var b = blue_in;
    var a = alpha_in;
    var endianness = endianness_in;
    if ((bpp == 24 or bpp == 32) and endianness == c.G_LITTLE_ENDIAN and a != 0xc0000000) {
        r = @byteSwap(r);
        g = @byteSwap(g);
        b = @byteSwap(b);
        a = @byteSwap(a);
        endianness = c.G_BIG_ENDIAN;
        if (bpp == 24) {
            r >>= 8;
            g >>= 8;
            b >>= 8;
        }
    }
    if (depth == 32 and bpp == 32 and a == 0xc0000000 and endianness == c.G_LITTLE_ENDIAN)
        return if (r == 0x3ff00000) c.GST_VIDEO_FORMAT_RGB10A2_LE else c.GST_VIDEO_FORMAT_BGR10A2_LE;
    if (depth == 30 and bpp == 32) return c.GST_VIDEO_FORMAT_r210;
    if (depth == 24 and bpp == 32) return rgb32(r, g, b);
    if (depth == 32 and bpp == 32 and a == 0) return rgb32(r, g, b);
    if (depth == 32 and bpp == 32) return rgba32(r, g, b, a);
    if (depth == 24 and bpp == 24) return rgb24(r, g, b);
    if ((depth == 15 or depth == 16) and bpp == 16 and endianness == c.G_LITTLE_ENDIAN) return rgb16(r, g, b);
    if (depth == 8 and bpp == 8) return c.GST_VIDEO_FORMAT_RGB8P;
    if (depth == 64 and bpp == 64) return if (rgba32(r, g, b, a) == c.GST_VIDEO_FORMAT_ARGB) c.GST_VIDEO_FORMAT_ARGB64 else c.GST_VIDEO_FORMAT_UNKNOWN;
    return c.GST_VIDEO_FORMAT_UNKNOWN;
}

pub export fn gst_video_format_get_palette(format: c.GstVideoFormat, size: [*c]c.gsize) c.gconstpointer {
    const fname = "gst_video_format_get_palette";
    if (!check.that(format < N, fname, "(gint) format < G_N_ELEMENTS (formats)")) return null;
    if (!check.that(size != null, fname, "size != NULL")) return null;
    if (format != c.GST_VIDEO_FORMAT_RGB8P) return null;
    size.* = @sizeOf(@TypeOf(p8.palette));
    return &p8.palette;
}

pub export fn gst_video_format_info_component(info: [*c]const Info, plane: c.guint, components: [*c]c.gint) void {
    var i: usize = 0;
    for (0..info[0].n_components) |k| {
        if (info[0].plane[k] == plane) {
            components[i] = @intCast(k);
            i += 1;
        }
    }
    for (i..c.GST_VIDEO_MAX_COMPONENTS) |k| components[k] = -1;
}

pub export fn gst_video_format_info_extrapolate_stride(finfo: [*c]const Info, plane: c.gint, stride: c.gint) c.gint {
    if (plane == 0) return stride;
    var comp: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
    gst_video_format_info_component(finfo, @intCast(plane), &comp);
    var est: c.gint = 0;
    for (comp) |k| {
        if (k < 0) break;
        const n: u5 = @intCast(finfo[0].w_sub[@intCast(k)]);
        est += -((-stride) >> n);
    }
    return est;
}

const Raw = struct { formats: [*c]c.GstVideoFormat, n: c.guint };
var raw_once = std.mem.zeroes(c.GOnce);
var any_once = std.mem.zeroes(c.GOnce);

fn generate(formats: [*c]const u8) *Raw {
    var list = std.mem.zeroes(c.GValue);
    const all: *Raw = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Raw))));
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    const tmp = c.g_strdup(formats);
    _ = c.gst_value_deserialize(&list, tmp);
    c.g_free(tmp);
    all.n = c.gst_value_list_get_size(&list);
    all.formats = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstVideoFormat) * all.n)));
    for (0..all.n) |i| all.formats[i] = gst_video_format_from_string(c.g_value_get_string(c.gst_value_list_get_value(&list, @intCast(i))));
    c.g_value_unset(&list);
    return all;
}

fn generateRaw(_: c.gpointer) callconv(.c) c.gpointer {
    return generate(c.GST_VIDEO_FORMATS_ALL);
}

fn generateAny(_: c.gpointer) callconv(.c) c.gpointer {
    return generate(c.GST_VIDEO_FORMATS_ANY);
}

pub export fn gst_video_formats_raw(len: [*c]c.guint) [*c]const c.GstVideoFormat {
    if (!check.that(len != null, "gst_video_formats_raw", "len")) return null;
    _ = c.g_once_impl(&raw_once, generateRaw, null);
    const all: *Raw = @ptrCast(@alignCast(raw_once.retval));
    len.* = all.n;
    return all.formats;
}

pub export fn gst_video_formats_any(len: [*c]c.guint) [*c]const c.GstVideoFormat {
    if (!check.that(len != null, "gst_video_formats_any", "len")) return null;
    _ = c.g_once_impl(&any_once, generateAny, null);
    const all: *Raw = @ptrCast(@alignCast(any_once.retval));
    len.* = all.n;
    return all.formats;
}

pub export fn gst_video_make_raw_caps(formats: [*c]const c.GstVideoFormat, len: c.guint) [*c]c.GstCaps {
    return gst_video_make_raw_caps_with_features(formats, len, null);
}

pub export fn gst_video_make_raw_caps_with_features(formats_in: [*c]const c.GstVideoFormat, len_in: c.guint, features: ?*c.GstCapsFeatures) [*c]c.GstCaps {
    const fname = "gst_video_make_raw_caps_with_features";
    var fl = formats_in;
    var len = len_in;
    if (!check.that((fl != null and len > 0) or (fl == null and len == 0), fname, "(formats && len > 0) || (!formats && len == 0)")) return null;
    if (fl == null) fl = gst_video_formats_raw(&len);
    var format = std.mem.zeroes(c.GValue);
    if (len > 1) {
        _ = c.g_value_init(&format, c.gst_value_list_get_type());
        for (0..len) |i| {
            if (!check.that(fl[i] != c.GST_VIDEO_FORMAT_UNKNOWN and fl[i] != c.GST_VIDEO_FORMAT_ENCODED, fname, "formats[i] != GST_VIDEO_FORMAT_UNKNOWN && formats[i] != GST_VIDEO_FORMAT_ENCODED")) return null;
            var v = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&v, c.G_TYPE_STRING);
            c.g_value_set_static_string(&v, gst_video_format_to_string(fl[i]));
            c.gst_value_list_append_and_take_value(&format, &v);
        }
    } else {
        _ = c.g_value_init(&format, c.G_TYPE_STRING);
        c.g_value_set_static_string(&format, gst_video_format_to_string(fl[0]));
    }
    const s = c.gst_structure_new_static_str("video/x-raw", "width", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), "height", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), "framerate", c.gst_fraction_range_get_type(), @as(c.gint, 0), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), @as(c.gint, 1), @as(?*anyopaque, null));
    c.gst_structure_take_value_static_str(s, "format", &format);
    const caps = c.gst_caps_new_full(s, @as(?*anyopaque, null));
    if (features) |f| c.gst_caps_set_features(caps, 0, f);
    return caps;
}
