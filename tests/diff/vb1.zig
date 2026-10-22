const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;

const A = std.heap.c_allocator;

fn fillBuffer(b: [*c]c.GstBuffer, seed: u32) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
    var x: u32 = seed *% 2654435761 +% 1;
    for (map.data[0..map.size]) |*p| {
        x = x *% 1103515245 +% 12345;
        p.* = @truncate(x >> 16);
    }
    c.gst_buffer_unmap(b, &map);
}

fn hashBuffer(b: [*c]c.GstBuffer) u64 {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &map);
    return std.hash.Fnv1a_64.hash(map.data[0..map.size]);
}

fn run(dfmt: c.GstVideoFormat, sfmt: c.GstVideoFormat, dw: c.guint, dh: c.guint, sw: c.guint, sh: c.guint, x: c.gint, y: c.gint, alpha: f32, seed: u32, sp: bool, dp: bool) void {
    var di: c.GstVideoInfo = undefined;
    var si: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&di, dfmt, dw, dh);
    _ = c.gst_video_info_set_format(&si, sfmt, sw, sh);
    if (sp) si.flags |= c.GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA;
    if (dp) di.flags |= c.GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA;
    const db = c.gst_buffer_new_allocate(null, di.size, null);
    const sb = c.gst_buffer_new_allocate(null, si.size, null);
    fillBuffer(db, seed);
    fillBuffer(sb, seed +% 77);
    var df: c.GstVideoFrame = undefined;
    var sf: c.GstVideoFrame = undefined;
    _ = c.gst_video_frame_map(&df, &di, db, c.GST_MAP_READWRITE);
    _ = c.gst_video_frame_map(&sf, &si, sb, c.GST_MAP_READ);
    const ok = c.gst_video_blend(&df, &sf, x, y, alpha);
    c.gst_video_frame_unmap(&df);
    c.gst_video_frame_unmap(&sf);
    out("{s} <- {s} {d}x{d}@{d},{d} a={d:.2} seed {d} sp {d} dp {d}: ok {d} hash {x}", .{ std.mem.span(c.gst_video_format_to_string(dfmt)), std.mem.span(c.gst_video_format_to_string(sfmt)), sw, sh, x, y, alpha, seed, @intFromBool(sp), @intFromBool(dp), ok, hashBuffer(db) });
    c.gst_buffer_unref(db);
    c.gst_buffer_unref(sb);
}

pub fn main() void {
    c.gst_init(null, null);
    const dests = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_v210, c.GST_VIDEO_FORMAT_I420_10LE, c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_ARGB64, c.GST_VIDEO_FORMAT_Y210, c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_UYVY };
    const srcs = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_AYUV };
    const alphas = [_]f32{ 1.0, 0.5, 0.25 };
    for (dests) |d| for (srcs) |s| for (alphas) |a| {
        run(d, s, 32, 24, 16, 8, 4, 2, a, 1, false, false);
        run(d, s, 32, 24, 16, 8, 4, 2, a, 2, false, false);
        run(d, s, 32, 24, 12, 6, -3, 20, a, 3, false, false);
        run(d, s, 32, 24, 16, 8, 4, 2, a, 4, true, false);
        run(d, s, 32, 24, 16, 8, 4, 2, a, 5, false, true);
        run(d, s, 32, 24, 16, 8, 4, 2, a, 6, true, true);
    };
    out("done", .{});
}
