const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

const formats = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_RGB16, c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_v210, c.GST_VIDEO_FORMAT_I420_10LE, c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_A420, c.GST_VIDEO_FORMAT_RGB8P, c.GST_VIDEO_FORMAT_ARGB64, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_NV24, c.GST_VIDEO_FORMAT_Y210, c.GST_VIDEO_FORMAT_GBR, c.GST_VIDEO_FORMAT_IYU1, c.GST_VIDEO_FORMAT_UYVP, c.GST_VIDEO_FORMAT_YUV9 };

const sizes = [_][4]c.guint{ .{ 34, 18, 34, 18 }, .{ 34, 18, 20, 10 }, .{ 16, 8, 40, 30 } };

var seed: u32 = 1;

fn rnd() u8 {
    seed = seed *% 1103515245 +% 12345;
    return @truncate(seed >> 16);
}

fn config(k: usize) ?*c.GstStructure {
    const s = c.gst_structure_new_empty("GstVideoConverter");
    c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_DITHER_QUANTIZATION, c.G_TYPE_UINT, @as(c.guint, 2), NONE);
    switch (k) {
        0 => {},
        1 => c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_MATRIX_MODE, c.gst_video_matrix_mode_get_type(), c.GST_VIDEO_MATRIX_MODE_NONE, c.GST_VIDEO_CONVERTER_OPT_CHROMA_MODE, c.gst_video_chroma_mode_get_type(), c.GST_VIDEO_CHROMA_MODE_NONE, c.GST_VIDEO_CONVERTER_OPT_DITHER_METHOD, c.gst_video_dither_method_get_type(), c.GST_VIDEO_DITHER_NONE, NONE),
        2 => c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_GAMMA_MODE, c.gst_video_gamma_mode_get_type(), c.GST_VIDEO_GAMMA_MODE_REMAP, c.GST_VIDEO_CONVERTER_OPT_RESAMPLER_METHOD, c.gst_video_resampler_method_get_type(), c.GST_VIDEO_RESAMPLER_METHOD_LANCZOS, NONE),
        3 => c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_SRC_X, c.G_TYPE_INT, @as(c.gint, 3), c.GST_VIDEO_CONVERTER_OPT_SRC_Y, c.G_TYPE_INT, @as(c.gint, 2), c.GST_VIDEO_CONVERTER_OPT_DEST_X, c.G_TYPE_INT, @as(c.gint, 4), c.GST_VIDEO_CONVERTER_OPT_DEST_Y, c.G_TYPE_INT, @as(c.gint, 2), c.GST_VIDEO_CONVERTER_OPT_DEST_WIDTH, c.G_TYPE_INT, @as(c.gint, 9), c.GST_VIDEO_CONVERTER_OPT_DEST_HEIGHT, c.G_TYPE_INT, @as(c.gint, 5), c.GST_VIDEO_CONVERTER_OPT_BORDER_ARGB, c.G_TYPE_UINT, @as(c.guint, 0xff20a0c0), c.GST_VIDEO_CONVERTER_OPT_ALPHA_VALUE, c.G_TYPE_DOUBLE, @as(f64, 0.5), c.GST_VIDEO_CONVERTER_OPT_ALPHA_MODE, c.gst_video_alpha_mode_get_type(), c.GST_VIDEO_ALPHA_MODE_MULT, c.GST_VIDEO_CONVERTER_OPT_RESAMPLER_METHOD, c.gst_video_resampler_method_get_type(), c.GST_VIDEO_RESAMPLER_METHOD_NEAREST, NONE),
        else => c.gst_structure_set(s, c.GST_VIDEO_CONVERTER_OPT_DITHER_METHOD, c.gst_video_dither_method_get_type(), c.GST_VIDEO_DITHER_FLOYD_STEINBERG, c.GST_VIDEO_CONVERTER_OPT_ALPHA_VALUE, c.G_TYPE_DOUBLE, @as(f64, 0.25), c.GST_VIDEO_CONVERTER_OPT_RESAMPLER_TAPS, c.G_TYPE_UINT, @as(c.guint, 3), c.GST_VIDEO_CONVERTER_OPT_PRIMARIES_MODE, c.gst_video_primaries_mode_get_type(), c.GST_VIDEO_PRIMARIES_MODE_FAST, NONE),
    }
    return s;
}

fn convertOnce(inf: c.GstVideoFormat, outf: c.GstVideoFormat, sz: [4]c.guint, k: usize, im: c.GstVideoInterlaceMode) void {
    var ii: c.GstVideoInfo = undefined;
    var oi: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_interlaced_format(&ii, inf, im, sz[0], sz[1]);
    _ = c.gst_video_info_set_interlaced_format(&oi, outf, im, sz[2], sz[3]);
    if (k == 4) {
        oi.colorimetry.primaries = c.GST_VIDEO_COLOR_PRIMARIES_BT2020;
        ii.colorimetry.matrix = if (ii.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV != 0) c.GST_VIDEO_COLOR_MATRIX_BT709 else ii.colorimetry.matrix;
        ii.colorimetry.range = c.GST_VIDEO_COLOR_RANGE_0_255;
    }
    const conv = c.gst_video_converter_new(&ii, &oi, config(k));
    if (conv == null) {
        out("  {d}->{d} {any} k{d} null", .{ inf, outf, sz, k });
        return;
    }
    const sbuf = c.gst_buffer_new_allocate(null, ii.size, null);
    const dbuf = c.gst_buffer_new_allocate(null, oi.size, null);
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(sbuf, &mi, c.GST_MAP_WRITE);
    seed = inf * 977 + @as(u32, @intCast(sz[0]));
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
    out("  {d}->{d} {any} k{d} im{d}: {x}", .{ inf, outf, sz, k, im, h });
    c.gst_buffer_unref(sbuf);
    c.gst_buffer_unref(dbuf);
    c.gst_video_converter_free(conv);
}

pub fn main() void {
    c.gst_init(null, null);
    const only = std.c.getenv("SM_PAIR");
    out("convert", .{});
    for (formats) |inf| for (formats) |outf| for (sizes) |sz| for (0..5) |k| {
        if (only != null) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrintZ(&buf, "{d}-{d}", .{ inf, outf }) catch unreachable;
            if (c.strcmp(only, s.ptr) != 0) continue;
        }
        convertOnce(inf, outf, sz, k, 0);
    };
    for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_NV12 }) |inf| for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_ARGB64 }) |outf| for (sizes) |sz| for ([_]c.GstVideoInterlaceMode{ 1, 2 }) |im| {
        convertOnce(inf, outf, sz, 0, im);
    };
}
