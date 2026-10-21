const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const format = @import("format.zig");
const info = @import("info.zig");
const frame = @import("frame.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Info = c.GstVideoInfo;
const Frame = c.GstVideoFrame;

fn lin(a: u8, b: u8, f: u32) u8 {
    return @truncate((@as(u32, a) * (256 - f) + @as(u32, b) * f) >> 8);
}

fn bilinear(d: [*]u8, s: [*]const u8, inc: c.gint, n: c.gint) void {
    var i: c.gint = 0;
    while (i < n) : (i += 1) {
        const acc = inc *% i;
        const j: usize = @intCast(acc >> 16);
        const f: u32 = @intCast((acc >> 8) & 0xff);
        const o: usize = @intCast(i * 4);
        for (0..4) |e| d[o + e] = lin(s[j * 4 + e], s[j * 4 + 4 + e], f);
    }
}

fn mergeLinear(d: [*]u8, a: [*]const u8, b: [*]const u8, p: u16, n: c.gint) void {
    for (0..@intCast(n)) |i| {
        const t: u16 = (@as(u16, b[i]) -% a[i]) *% p +% 128;
        d[i] = @as(u8, @truncate(t >> 8)) +% a[i];
    }
}

pub export fn gst_video_blend_scale_linear_RGBA(src: [*c]Info, src_buffer: [*c]c.GstBuffer, dest_height: c.gint, dest_width: c.gint, dest: [*c]Info, dest_buffer: [*c][*c]c.GstBuffer) void {
    if (!check.that(dest_buffer != null, "gst_video_blend_scale_linear_RGBA", "dest_buffer != NULL")) return;
    info.gst_video_info_init(dest);
    if (info.gst_video_info_set_format(dest, src[0].finfo[0].format, @bitCast(dest_width), @bitCast(dest_height)) == 0) {
        check.warnReached("video-blend.c", "gst_video_blend_scale_linear_RGBA");
        return;
    }
    dest_buffer[0] = c.gst_buffer_new_allocate(null, dest[0].size, null);
    const tmp: [*]u8 = @ptrCast(c.g_malloc(@intCast(dest_width * 8 * 4)));
    defer c.g_free(tmp);
    var sf: Frame = undefined;
    var df: Frame = undefined;
    _ = frame.gst_video_frame_map(&sf, src, src_buffer, c.GST_MAP_READ);
    _ = frame.gst_video_frame_map(&df, dest, dest_buffer[0], c.GST_MAP_WRITE);
    const sh = src[0].height;
    const sw = src[0].width;
    const yinc: c.gint = if (dest_height == 1 or sh == 1) 0 else @divTrunc((sh - 1) << 16, dest_height - 1) - 1;
    const xinc: c.gint = if (dest_width == 1 or sw == 1) 0 else @divTrunc((sw - 1) << 16, dest_width - 1) - 1;
    const size: usize = @intCast(dest_width * 4);
    const sstride: usize = @intCast(sf.info.stride[0]);
    const dp: [*]u8 = @ptrCast(df.data[0]);
    const sp: [*]const u8 = @ptrCast(sf.data[0]);
    const line = struct {
        fn at(t: [*]u8, sz: usize, k: c.gint) [*]u8 {
            return t + sz * @as(usize, @intCast(k & 1));
        }
    }.at;
    bilinear(line(tmp, size, 0), sp, xinc, dest_width);
    var acc: c.gint = 0;
    var y1: c.gint = 0;
    var i: c.gint = 0;
    while (i < dest_height) : (i += 1) {
        const j = acc >> 16;
        const x = acc & 0xffff;
        const dl = dp + @as(usize, @intCast(i)) * size;
        if (x == 0) {
            @memcpy(dl[0..size], line(tmp, size, j)[0..size]);
        } else {
            if (j > y1) {
                bilinear(line(tmp, size, j), sp + @as(usize, @intCast(j)) * sstride, xinc, dest_width);
                y1 += 1;
            }
            if (j >= y1) {
                bilinear(line(tmp, size, j + 1), sp + @as(usize, @intCast(j + 1)) * sstride, xinc, dest_width);
                y1 += 1;
            }
            mergeLinear(dl, line(tmp, size, j), line(tmp, size, j + 1), @intCast(x >> 8), dest_width * 4);
        }
        acc += yinc;
    }
    frame.gst_video_frame_unmap(&sf);
    frame.gst_video_frame_unmap(&df);
}

fn preaRgbToYuv(t: [*]u8, w: usize) void {
    for (0..w) |i| {
        const p = t + i * 4;
        const a: i32 = p[0];
        var r: i32 = p[1];
        var g: i32 = p[2];
        var b: i32 = p[3];
        if (a != 0) {
            r = @divTrunc(r * 255 + @divTrunc(a, 2), a);
            g = @divTrunc(g * 255 + @divTrunc(a, 2), a);
            b = @divTrunc(b * 255 + @divTrunc(a, 2), a);
        }
        toYuv(p, r, g, b);
    }
}

fn toYuv(p: [*]u8, r: i32, g: i32, b: i32) void {
    p[1] = @intCast(std.math.clamp((47 * r + 157 * g + 16 * b + 4096) >> 8, 0, 255));
    p[2] = @intCast(std.math.clamp((-26 * r - 87 * g + 112 * b + 32768) >> 8, 0, 255));
    p[3] = @intCast(std.math.clamp((112 * r - 102 * g - 10 * b + 32768) >> 8, 0, 255));
}

fn rgbToYuv(t: [*]u8, w: usize) void {
    for (0..w) |i| {
        const p = t + i * 4;
        toYuv(p, p[1], p[2], p[3]);
    }
}

fn yuvToRgb(t: [*]u8, w: usize) void {
    for (0..w) |i| {
        const p = t + i * 4;
        const y: i32 = p[1];
        const u: i32 = p[2];
        const v: i32 = p[3];
        p[1] = @intCast(std.math.clamp((298 * y + 459 * v - 63514) >> 8, 0, 255));
        p[2] = @intCast(std.math.clamp((298 * y - 55 * u - 136 * v + 19681) >> 8, 0, 255));
        p[3] = @intCast(std.math.clamp((298 * y + 541 * u - 73988) >> 8, 0, 255));
    }
}

const Op = enum { over00, over10, over01, over11 };

fn mix(comptime op: Op, comptime wide: bool, max: u32, ag: u32, aa: u32, ca: u32, ab: u32, cb: u32, ad: u32) i32 {
    const r: u64 = switch (op) {
        .over00 => if (wide)
            (@as(u64, ca *% aa) + @as(u64, cb) * ab * (max -% aa) / max) / ad
        else
            (ca *% aa +% cb *% ab *% (max -% aa) / max) / ad,
        .over10 => if (wide)
            (@as(u64, @bitCast(@as(i64, @as(i32, @bitCast(ca *% ag))))) +% @as(u64, cb) * ab * (max -% aa) / max) / ad
        else
            (ca *% ag +% cb *% ab *% (max -% aa) / max) / ad,
        .over01 => (ca *% aa +% cb *% (max -% aa)) / max,
        .over11 => (ca *% ag +% cb *% (max -% aa)) / max,
    };
    return @bitCast(@as(u32, @truncate(r)));
}

fn blendLine(comptime T: type, comptime op: Op, s: [*]const u8, dline: [*]u8, w: usize, alpha: u32) void {
    const wide = T == u16;
    const max: u32 = if (wide) 65535 else 255;
    const shift: u5 = if (wide) 8 else 0;
    const d: [*]align(1) T = @ptrCast(dline);
    var j: usize = 0;
    while (j < w * 4) : (j += 4) {
        var asrc: u32 = @as(u32, s[j]) *% alpha / max;
        asrc <<= shift;
        if (asrc == 0) continue;
        const adst: u32 = d[j];
        var fa: u32 = asrc +% adst *% (max -% asrc) / max;
        d[j] = @truncate(fa);
        if (fa == 0) fa = 1;
        for (1..4) |k| {
            const v = mix(op, wide, max, alpha, asrc, @as(u32, s[j + k]) << shift, adst, d[j + k], fa);
            d[j + k] = @truncate(@as(u32, @bitCast(@min(v, @as(i32, @intCast(max))))));
        }
    }
}

fn blendAny(comptime T: type, sp: bool, dp: bool, s: [*]const u8, d: [*]u8, w: usize, alpha: u32) void {
    if (sp and dp) return blendLine(T, .over11, s, d, w, alpha);
    if (!sp and dp) return blendLine(T, .over01, s, d, w, alpha);
    if (sp and !dp) return blendLine(T, .over10, s, d, w, alpha);
    blendLine(T, .over00, s, d, w, alpha);
}

fn isRgb(i: *const Info) bool {
    return i.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0;
}

pub export fn gst_video_blend(dest: [*c]Frame, src: [*c]Frame, x_in: c.gint, y_in: c.gint, global_alpha: f32) c.gboolean {
    const d: *Frame = @ptrCast(dest);
    const s: *Frame = @ptrCast(src);
    const dp = d.info.flags & c.GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA != 0;
    var sp = s.info.flags & c.GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA != 0;
    var sw = s.info.width;
    var sh = s.info.height;
    const dw = d.info.width;
    const dh = d.info.height;
    var x = x_in;
    var y = y_in;
    if (x + sw <= 0 or y + sh <= 0 or x >= dw or y >= dh) return 1;
    const di = format.get(d.info.finfo[0].format);
    const si = format.get(s.info.finfo[0].format);
    if (si == null or di == null) return 0;
    const du = format.get(di[0].unpack_format);
    const su = format.get(si[0].unpack_format);
    if (du == null or su == null) return 0;
    if (du[0].bits != 8 and du[0].bits != 16) return 0;
    const bpp: usize = 4 * (du[0].bits / 8);
    const alpha: c.gint = @intFromFloat(if (bpp == 4) 255.0 * @as(f64, global_alpha) else 65535.0 * @as(f64, global_alpha));
    var matrix: ?*const fn ([*]u8, usize) void = null;
    if (isRgb(&s.info) != isRgb(&d.info)) {
        if (isRgb(&s.info)) {
            if (sp) {
                matrix = preaRgbToYuv;
                sp = false;
            } else matrix = rgbToYuv;
        } else matrix = yuvToRgb;
    }
    var sx: c.gint = 0;
    var sy: c.gint = 0;
    if (x < 0) {
        sx = -x;
        sw -= sx;
        x = 0;
    }
    if (y < 0) {
        sy = -y;
        sh -= sy;
        y = 0;
    }
    if (x + sw > dw) sw = dw - x;
    if (y + sh > dh) sh = dh - y;
    const ts: [*]u8 = @ptrCast(c.g_malloc(@as(usize, @intCast(sw + 8)) * 4));
    defer c.g_free(ts);
    const td: [*]u8 = @ptrCast(c.g_malloc(@as(usize, @intCast(dw + 8)) * bpp));
    defer c.g_free(td);
    const w: usize = @intCast(sw);
    const off = bpp * @as(usize, @intCast(x));
    var i = y;
    while (i < y + sh) : ({
        i += 1;
        sy += 1;
    }) {
        di[0].unpack_func.?(di, 0, td, &d.data, &d.info.stride, 0, i, dw);
        si[0].unpack_func.?(si, 0, ts, &s.data, &s.info.stride, sx, sy, sw);
        if (matrix) |m| m(ts, w);
        const a: u32 = @bitCast(alpha);
        if (bpp == 4) blendAny(u8, sp, dp, ts, td + off, w, a) else blendAny(u16, sp, dp, ts, td + off, w, a);
        di[0].pack_func.?(di, 0, td, dw, &d.data, &d.info.stride, d.info.chroma_site, i, dw);
    }
    return 1;
}
