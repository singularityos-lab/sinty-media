const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn fnv(h: *u32, bytes: []const u8) void {
    for (bytes) |b| h.* = (h.* ^ b) *% 16777619;
}

fn options(k: usize) ?*c.GstStructure {
    return switch (k) {
        0 => null,
        1 => c.gst_structure_new("o", c.GST_VIDEO_RESAMPLER_OPT_SHARPNESS, c.G_TYPE_DOUBLE, @as(f64, 1.3), c.GST_VIDEO_RESAMPLER_OPT_SHARPEN, c.G_TYPE_DOUBLE, @as(f64, 0.2), NONE),
        2 => c.gst_structure_new("o", c.GST_VIDEO_RESAMPLER_OPT_CUBIC_B, c.G_TYPE_DOUBLE, @as(f64, 0.0), c.GST_VIDEO_RESAMPLER_OPT_CUBIC_C, c.G_TYPE_DOUBLE, @as(f64, 0.5), c.GST_VIDEO_RESAMPLER_OPT_ENVELOPE, c.G_TYPE_DOUBLE, @as(f64, 3.0), NONE),
        else => c.gst_structure_new("o", c.GST_VIDEO_RESAMPLER_OPT_MAX_TAPS, c.G_TYPE_INT, @as(c.gint, 6), NONE),
    };
}

const sizes = [_][2]c.guint{ .{ 1, 1 }, .{ 1, 7 }, .{ 7, 1 }, .{ 2, 3 }, .{ 10, 20 }, .{ 20, 10 }, .{ 64, 48 }, .{ 48, 64 }, .{ 100, 33 }, .{ 33, 100 }, .{ 320, 240 }, .{ 17, 17 } };

fn resamplers() void {
    out("resampler", .{});
    var total: u32 = 2166136261;
    for (0..5) |method| for ([_]c.guint{ 0, 1, 2, 3, 4, 7, 8, 16 }) |nt| for ([_]c.guint{ 0, c.GST_VIDEO_RESAMPLER_FLAG_HALF_TAPS }) |fl| for ([_]f64{ 0.0, 0.25, -0.5 }) |shift| for (sizes) |sz| for (0..4) |ok| {
        var r: c.GstVideoResampler = undefined;
        const o = options(ok);
        const res = c.gst_video_resampler_init(&r, @intCast(method), fl, sz[1], nt, shift, sz[0], sz[1], o);
        if (o != null) c.gst_structure_free(o);
        var h: u32 = 2166136261;
        fnv(&h, std.mem.sliceAsBytes(r.offset[0..@intCast(r.out_size)]));
        fnv(&h, std.mem.sliceAsBytes(r.phase[0..@intCast(r.out_size)]));
        fnv(&h, std.mem.sliceAsBytes(r.n_taps[0..@intCast(r.out_size)]));
        fnv(&h, std.mem.sliceAsBytes(r.taps[0 .. @as(usize, @intCast(r.out_size)) * r.max_taps]));
        if (sz[0] == 10 and sz[1] == 20 and nt == 0 and ok == 0 and shift == 0) {
            out("  m{d} f{d} {d}->{d} taps {d}: off {any}", .{ method, fl, sz[0], sz[1], r.max_taps, r.offset[0..@intCast(r.out_size)] });
            var line: [4096]u8 = undefined;
            var n: usize = 0;
            for (r.taps[0 .. @as(usize, @intCast(r.out_size)) * r.max_taps]) |t| {
                const w = std.fmt.bufPrint(line[n..], "{x} ", .{@as(u64, @bitCast(t))}) catch break;
                n += w.len;
            }
            out("    {s}", .{line[0..n]});
        }
        out("  m{d} nt{d} f{d} sh{d} {d}->{d} o{d}: {d} taps {d} hash {x}", .{ method, nt, fl, shift, sz[0], sz[1], ok, res, r.max_taps, h });
        total = (total ^ h) *% 16777619;
        c.gst_video_resampler_clear(&r);
    };
    out("  total {x}", .{total});
    var r: c.GstVideoResampler = undefined;
    _ = c.gst_video_resampler_init(&r, 0, 0, 3, 0, 0, 0, 3, null);
    _ = c.gst_video_resampler_init(&r, 0, 0, 3, 0, 0, 3, 0, null);
    _ = c.gst_video_resampler_init(&r, 0, 0, 2, 0, 0, 3, 3, null);
    c.gst_video_resampler_clear(null);
}

var src: [1 << 20]u8 align(16) = undefined;
var dst: [1 << 20]u8 align(16) = undefined;

fn fill() void {
    var s: u32 = 12345;
    for (&src) |*b| {
        s = s *% 1103515245 +% 12345;
        b.* = @truncate(s >> 16);
    }
}

const formats = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_ARGB64, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_I420 };

fn bpp(f: c.GstVideoFormat) usize {
    return switch (f) {
        c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_I420 => 1,
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_NV12 => 2,
        c.GST_VIDEO_FORMAT_RGB => 3,
        c.GST_VIDEO_FORMAT_ARGB64, c.GST_VIDEO_FORMAT_AYUV64 => 8,
        else => 4,
    };
}

fn scalers() void {
    out("scaler", .{});
    fill();
    for ([_]c.GstVideoResamplerMethod{ 0, 1, 2, 3, 4 }) |method| for ([_]c.guint{ 0, 2, 3, 4, 5, 6, 8 }) |nt| for ([_]c.GstVideoScalerFlags{ 0, c.GST_VIDEO_SCALER_FLAG_INTERLACED }) |fl| for ([_][2]c.guint{ .{ 16, 16 }, .{ 37, 19 }, .{ 19, 37 }, .{ 64, 31 }, .{ 9, 200 }, .{ 120, 7 } }) |sz| {
        const s = c.gst_video_scaler_new(method, fl, nt, sz[0], sz[1], null);
        var in_off: c.guint = 0;
        var ntaps: c.guint = 0;
        var h: u32 = 2166136261;
        for (0..sz[1]) |o| {
            const coeff = c.gst_video_scaler_get_coeff(s, @intCast(o), &in_off, &ntaps);
            fnv(&h, std.mem.asBytes(&in_off));
            fnv(&h, std.mem.asBytes(&ntaps));
            fnv(&h, std.mem.sliceAsBytes(coeff[0..c.gst_video_scaler_get_max_taps(s)]));
        }
        out("  new m{d} nt{d} f{d} {any}: max {d} coeff {x}", .{ method, nt, fl, sz, c.gst_video_scaler_get_max_taps(s), h });
        c.gst_video_scaler_free(s);
        for (formats) |fmt| {
            const b = bpp(fmt);
            const ow: usize = sz[1];
            const iw: usize = sz[0];
            var hh: u32 = 2166136261;
            const packed_yuv = fmt == c.GST_VIDEO_FORMAT_YUY2 or fmt == c.GST_VIDEO_FORMAT_UYVY;
            var sh = c.gst_video_scaler_new(method, fl, nt, sz[0], sz[1], null);
            @memset(&dst, 0xcd);
            if (!packed_yuv) c.gst_video_scaler_horizontal(sh, fmt, &src, &dst, 0, @intCast(ow));
            fnv(&hh, dst[0 .. ow * b + 16]);
            if (ow > 3 and !packed_yuv) {
                @memset(&dst, 0xcd);
                c.gst_video_scaler_horizontal(sh, fmt, &src, &dst, 1, @intCast(ow - 2));
                fnv(&hh, dst[0 .. ow * b + 16]);
            }
            c.gst_video_scaler_free(sh);
            sh = c.gst_video_scaler_new(method, fl, nt, sz[0], sz[1], null);
            var lines: [512]c.gpointer = undefined;
            for (0..512) |k| lines[k] = @ptrCast(&src[(k * 97) % 1000 * 64]);
            for ([_]usize{ 0, ow / 2, ow - 1 }) |doff| {
                @memset(&dst, 0xcd);
                c.gst_video_scaler_vertical(sh, fmt, &lines, &dst, @intCast(doff), @intCast(iw));
                fnv(&hh, dst[0 .. iw * b + 16]);
            }
            c.gst_video_scaler_free(sh);
            out("   fmt {d}: {x}", .{ fmt, hh });
        }
    };
    for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_NV12 }) |fmt| for ([_][4]c.guint{ .{ 40, 30, 80, 60 }, .{ 80, 60, 40, 30 }, .{ 33, 17, 50, 71 }, .{ 64, 64, 64, 64 }, .{ 200, 20, 30, 150 } }) |d| for ([_]c.guint{ 0, 2, 4, 6 }) |nt| for (0..4) |mode| for ([_]c.GstVideoScalerFlags{ 0, c.GST_VIDEO_SCALER_FLAG_INTERLACED }) |vfl| {
        if (fmt == c.GST_VIDEO_FORMAT_YUY2 and mode & 1 != 0) continue;
        const hs = if (mode & 1 != 0) c.gst_video_scaler_new(c.GST_VIDEO_RESAMPLER_METHOD_CUBIC, 0, nt, d[0], d[2], null) else null;
        const vs = if (mode & 2 != 0) c.gst_video_scaler_new(c.GST_VIDEO_RESAMPLER_METHOD_LANCZOS, vfl, nt, d[1], d[3], null) else null;
        const b = bpp(fmt);
        const ss: c.gint = @intCast(d[0] * b + 8);
        const ds: c.gint = @intCast(d[2] * b + 24);
        @memset(&dst, 0xcd);
        const ow = if (mode & 1 != 0) d[2] else d[0];
        const oh = if (mode & 2 != 0) d[3] else d[1];
        c.gst_video_scaler_2d(hs, vs, fmt, &src, ss, &dst, ds, 0, 0, ow, oh);
        var h: u32 = 2166136261;
        fnv(&h, dst[0 .. @as(usize, @intCast(ds)) * oh + 64]);
        @memset(&dst, 0xcd);
        const x0: c.guint = if (mode == 3) 0 else 1;
        if (ow > 4 and oh > 4) c.gst_video_scaler_2d(hs, vs, fmt, &src, ss, &dst, ds, x0, 2, ow - 2, oh - 1);
        fnv(&h, dst[0 .. @as(usize, @intCast(ds)) * oh + 64]);
        out("  2d fmt {d} {any} nt {d} mode {d} vfl {d}: {x}", .{ fmt, d, nt, mode, vfl, h });
        if (hs != null) c.gst_video_scaler_free(hs);
        if (vs != null) c.gst_video_scaler_free(vs);
    };
    for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_YVYU }) |inf| for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY }) |outf| for ([_]c.guint{ 2, 4, 6 }) |nt| for ([_][2]c.guint{ .{ 32, 48 }, .{ 50, 20 } }) |sz| {
        const ys = c.gst_video_scaler_new(c.GST_VIDEO_RESAMPLER_METHOD_CUBIC, 0, nt, sz[0], sz[1], null);
        const uvs = c.gst_video_scaler_new(c.GST_VIDEO_RESAMPLER_METHOD_CUBIC, 0, nt, sz[0] / 2, sz[1] / 2, null);
        const comb = c.gst_video_scaler_combine_packed_YUV(ys, uvs, inf, outf);
        var h: u32 = 2166136261;
        const n = c.gst_video_scaler_get_max_taps(comb);
        var o: c.guint = 0;
        var in_off: c.guint = 0;
        var ntaps: c.guint = 0;
        while (o < sz[1] * 2) : (o += 1) {
            const coeff = c.gst_video_scaler_get_coeff(comb, o, &in_off, &ntaps);
            fnv(&h, std.mem.asBytes(&in_off));
            fnv(&h, std.mem.sliceAsBytes(coeff[0..ntaps]));
        }
        @memset(&dst, 0xcd);
        c.gst_video_scaler_horizontal(comb, outf, &src, &dst, 0, sz[1]);
        fnv(&h, dst[0 .. sz[1] * 2 + 16]);
        @memset(&dst, 0xcd);
        c.gst_video_scaler_2d(comb, null, outf, &src, @intCast(sz[0] * 2), &dst, @intCast(sz[1] * 2 + 4), 0, 0, sz[1], 8);
        fnv(&h, dst[0 .. (sz[1] * 2 + 4) * 8]);
        const vs = c.gst_video_scaler_new(c.GST_VIDEO_RESAMPLER_METHOD_LINEAR, 0, 2, 16, 10, null);
        @memset(&dst, 0xcd);
        c.gst_video_scaler_2d(comb, vs, outf, &src, @intCast(sz[0] * 2), &dst, @intCast(sz[1] * 2 + 4), 0, 0, sz[1], 10);
        fnv(&h, dst[0 .. (sz[1] * 2 + 4) * 10]);
        c.gst_video_scaler_free(vs);
        out("  combine {d}->{d} nt {d} {any}: taps {d} {x}", .{ inf, outf, nt, sz, n, h });
        c.gst_video_scaler_free(comb);
        c.gst_video_scaler_free(ys);
        c.gst_video_scaler_free(uvs);
    };
    const a = c.gst_video_scaler_new(0, 0, 1, 10, 10, null);
    const b = c.gst_video_scaler_new(0, 0, 2, 10, 10, null);
    _ = c.gst_video_scaler_combine_packed_YUV(a, b, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YUY2);
    _ = c.gst_video_scaler_combine_packed_YUV(null, b, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YUY2);
    c.gst_video_scaler_horizontal(a, c.GST_VIDEO_FORMAT_I420, &src, &dst, 0, 10);
    c.gst_video_scaler_horizontal(a, c.GST_VIDEO_FORMAT_GRAY8, &src, &dst, 5, 10);
    c.gst_video_scaler_vertical(a, c.GST_VIDEO_FORMAT_GRAY8, null, &dst, 0, 10);
    c.gst_video_scaler_vertical(a, c.GST_VIDEO_FORMAT_GRAY8, @ptrCast(&src), &dst, 10, 10);
    _ = c.gst_video_scaler_get_coeff(a, 10, null, null);
    _ = c.gst_video_scaler_get_max_taps(null);
    _ = c.gst_video_scaler_new(0, 0, 1, 0, 10, null);
    c.gst_video_scaler_2d(a, b, c.GST_VIDEO_FORMAT_GRAY8, null, 0, &dst, 0, 0, 0, 1, 1);
    c.gst_video_scaler_free(a);
    c.gst_video_scaler_free(b);
    c.gst_video_scaler_free(null);
}

pub fn main() void {
    c.gst_init(null, null);
    resamplers();
    scalers();
}
