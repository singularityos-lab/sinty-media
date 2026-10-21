const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn fnv(h: *u32, bytes: []const u8) void {
    for (bytes) |b| h.* = (h.* ^ b) *% 16777619;
}

var line: [4096]u8 align(16) = undefined;

fn dithers() void {
    out("dither", .{});
    var seed: u32 = 99;
    for (0..5) |method| for ([_]c.guint{ 0, c.GST_VIDEO_DITHER_FLAG_QUANTIZE, c.GST_VIDEO_DITHER_FLAG_INTERLACED }) |fl| for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_ARGB64 }) |fmt| for ([_][4]c.guint{ .{ 1, 1, 1, 1 }, .{ 4, 4, 4, 1 }, .{ 8, 2, 16, 1 }, .{ 64, 64, 64, 256 }, .{ 3, 5, 7, 9 } }) |q| for ([_]c.guint{ 1, 7, 16, 33 }) |w| {
        var qq = q;
        const d = c.gst_video_dither_new(@intCast(method), fl, fmt, &qq, w);
        var h: u32 = 2166136261;
        const wide = fmt == c.GST_VIDEO_FORMAT_AYUV64 or fmt == c.GST_VIDEO_FORMAT_ARGB64;
        const bpl: usize = w * 4 * @as(usize, if (wide) 2 else 1);
        for (0..20) |y| {
            for ([_]c.guint{ 0, 1 }) |x| {
                if (x >= w) continue;
                for (line[0 .. bpl + 64]) |*b| {
                    seed = seed *% 1103515245 +% 12345;
                    b.* = @truncate(seed >> 16);
                }
                c.gst_video_dither_line(d, &line, x, @intCast(y), w - x);
                fnv(&h, line[0 .. bpl + 64]);
            }
        }
        out("  m{d} f{d} fmt {d} q {any} w {d}: {x}", .{ method, fl, fmt, q, w, h });
        c.gst_video_dither_free(d);
    };
    var q = [4]c.guint{ 1, 1, 1, 1 };
    out("  bad fmt {any}", .{c.gst_video_dither_new(0, 0, c.GST_VIDEO_FORMAT_I420, &q, 4) == null});
    const d = c.gst_video_dither_new(1, 0, c.GST_VIDEO_FORMAT_AYUV, &q, 4);
    c.gst_video_dither_line(d, &line, 2, 0, 3);
    c.gst_video_dither_line(null, &line, 0, 0, 1);
    c.gst_video_dither_free(d);
    c.gst_video_dither_free(null);
}

pub fn main() void {
    c.gst_init(null, null);
    dithers();
}
