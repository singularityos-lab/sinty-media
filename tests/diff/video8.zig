const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

const formats = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_A420, c.GST_VIDEO_FORMAT_ABGR, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_ARGB64, c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_BGR, c.GST_VIDEO_FORMAT_BGR15, c.GST_VIDEO_FORMAT_BGR16, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_BGRP, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_GBR, c.GST_VIDEO_FORMAT_GBRA, c.GST_VIDEO_FORMAT_GRAY16_BE, c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_I420_10BE, c.GST_VIDEO_FORMAT_I420_10LE, c.GST_VIDEO_FORMAT_I422_10BE, c.GST_VIDEO_FORMAT_I422_10LE, c.GST_VIDEO_FORMAT_IYU2, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_NV24, c.GST_VIDEO_FORMAT_NV61, c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_RGB15, c.GST_VIDEO_FORMAT_RGB16, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_RGBP, c.GST_VIDEO_FORMAT_RGBx, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_v210, c.GST_VIDEO_FORMAT_v308, c.GST_VIDEO_FORMAT_xBGR, c.GST_VIDEO_FORMAT_xRGB, c.GST_VIDEO_FORMAT_Y41B, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_YUV9, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YV12, c.GST_VIDEO_FORMAT_YVU9, c.GST_VIDEO_FORMAT_YVYU };

const Case = struct { sz: [4]c.guint, im: c.GstVideoInterlaceMode = 0 };

const cases = [_]Case{
    .{ .sz = .{ 34, 18, 34, 18 } },
    .{ .sz = .{ 34, 18, 20, 10 } },
    .{ .sz = .{ 16, 8, 32, 16 } },
    .{ .sz = .{ 32, 16, 16, 8 } },
    .{ .sz = .{ 34, 18, 40, 24 } },
    .{ .sz = .{ 34, 18, 34, 18 } },
    .{ .sz = .{ 34, 20, 34, 20 }, .im = 1 },
    .{ .sz = .{ 33, 17, 33, 17 } },
    .{ .sz = .{ 32, 16, 64, 32 } },
};

var seed: u32 = 1;

fn rnd() u8 {
    seed = seed *% 1103515245 +% 12345;
    return @truncate(seed >> 16);
}

fn config(k: usize) ?*c.GstStructure {
    const s = c.gst_structure_new_empty("GstVideoConverter");
    switch (k) {
        2, 8 => c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_RESAMPLER_METHOD, c.gst_video_resampler_method_get_type(), c.GST_VIDEO_RESAMPLER_METHOD_NEAREST, NONE),
        3 => c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_RESAMPLER_METHOD, c.gst_video_resampler_method_get_type(), c.GST_VIDEO_RESAMPLER_METHOD_LINEAR, NONE),
        4 => c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_SRC_X, c.G_TYPE_INT, @as(c.gint, 2), c.GST_VIDEO_CONVERTER_OPT_SRC_Y, c.G_TYPE_INT, @as(c.gint, 2), c.GST_VIDEO_CONVERTER_OPT_DEST_X, c.G_TYPE_INT, @as(c.gint, 4), c.GST_VIDEO_CONVERTER_OPT_DEST_Y, c.G_TYPE_INT, @as(c.gint, 2), c.GST_VIDEO_CONVERTER_OPT_DEST_WIDTH, c.G_TYPE_INT, @as(c.gint, 34), c.GST_VIDEO_CONVERTER_OPT_DEST_HEIGHT, c.G_TYPE_INT, @as(c.gint, 18), c.GST_VIDEO_CONVERTER_OPT_BORDER_ARGB, c.G_TYPE_UINT, @as(c.guint, 0xff20a0c0), NONE),
        5 => c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_ALPHA_VALUE, c.G_TYPE_DOUBLE, @as(f64, 0.5), NONE),
        else => {},
    }
    return s;
}

fn convertOnce(inf: c.GstVideoFormat, outf: c.GstVideoFormat, k: usize) void {
    const cs = cases[k];
    var ii: c.GstVideoInfo = undefined;
    var oi: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_interlaced_format(&ii, inf, cs.im, cs.sz[0], cs.sz[1]);
    _ = c.gst_video_info_set_interlaced_format(&oi, outf, cs.im, cs.sz[2], cs.sz[3]);
    const conv = c.gst_video_converter_new(&ii, &oi, config(k));
    if (conv == null) {
        out("  {d}->{d} k{d} null", .{ inf, outf, k });
        return;
    }
    const sbuf = c.gst_buffer_new_allocate(null, ii.size, null);
    const dbuf = c.gst_buffer_new_allocate(null, oi.size, null);
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(sbuf, &mi, c.GST_MAP_WRITE);
    seed = inf * 977 + @as(u32, @intCast(k));
    for (0..mi.size) |i| mi.data[i] = rnd();
    c.gst_buffer_unmap(sbuf, &mi);
    _ = c.gst_buffer_memset(dbuf, 0, 0x5a, oi.size);
    var sf: c.GstVideoFrame = undefined;
    var df: c.GstVideoFrame = undefined;
    _ = c.gst_video_frame_map(&sf, &ii, sbuf, c.GST_MAP_READ);
    _ = c.gst_video_frame_map(&df, &oi, dbuf, c.GST_MAP_WRITE);
    c.gst_video_converter_frame(conv, &sf, &df);
    c.gst_video_frame_unmap(&df);
    c.gst_video_frame_unmap(&sf);
    _ = c.gst_buffer_map(dbuf, &mi, c.GST_MAP_READ);
    var h: u32 = 2166136261;
    for (mi.data[0..mi.size]) |b| h = (h ^ b) *% 16777619;
    if (std.c.getenv("SM_DUMP") != null) {
        var i: usize = 0;
        while (i < mi.size) : (i += 32) out("D {d}: {any}", .{ i, mi.data[i..@min(i + 32, mi.size)] });
    }
    c.gst_buffer_unmap(dbuf, &mi);
    out("  {d}->{d} k{d}: {x}", .{ inf, outf, k, h });
    c.gst_buffer_unref(sbuf);
    c.gst_buffer_unref(dbuf);
    c.gst_video_converter_free(conv);
}

fn skip(inf: c.GstVideoFormat, outf: c.GstVideoFormat, k: usize) bool {
    const bad = [_][3]u32{.{ 5, 6, 7 }};
    for (bad) |b| if (b[0] == inf and b[1] == outf and b[2] == k) return true;
    return false;
}

pub fn main() void {
    c.gst_init(null, null);
    const only = std.c.getenv("SM_PAIR");
    out("fastpath", .{});
    for (formats) |inf| for (formats) |outf| for (0..cases.len) |k| {
        if (only != null) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "{d}-{d}", .{ inf, outf }) catch unreachable;
            if (c.strcmp(only, s.ptr) != 0) continue;
        }
        if (skip(inf, outf, k)) continue;
        convertOnce(inf, outf, k);
    };
}
