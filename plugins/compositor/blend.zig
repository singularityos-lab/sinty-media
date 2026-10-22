const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

pub const MODE_SOURCE = 0;
pub const MODE_OVER = 1;
pub const MODE_ADD = 2;

pub const Frame = c.GstVideoFrame;
pub const Blend = *const fn (*Frame, c.gint, c.gint, f64, *Frame, c.gint, c.gint, c.gint) void;
pub const Checker = *const fn (*Frame, c.guint, c.guint) void;
pub const Color = *const fn (*Frame, c.guint, c.guint, c.gint, c.gint, c.gint) void;

fn finfo(f: *Frame) [*c]const c.GstVideoFormatInfo {
    return f.info.finfo;
}

fn width(f: *Frame) c.gint {
    return f.info.width;
}

fn height(f: *Frame) c.gint {
    return f.info.height;
}

fn planeData(f: *Frame, p: usize) [*]u8 {
    return @ptrCast(f.data[p].?);
}

fn compData(f: *Frame, k: usize) [*]u8 {
    const fi = finfo(f);
    return planeData(f, fi[0].plane[k]) + fi[0].poffset[k];
}

fn compStride(f: *Frame, k: usize) c.gint {
    return f.info.stride[finfo(f)[0].plane[k]];
}

fn planeStride(f: *Frame, p: usize) c.gint {
    return f.info.stride[p];
}

fn compPstride(f: *Frame, k: usize) c.gint {
    return finfo(f)[0].pixel_stride[k];
}

fn scaleW(fi: [*c]const c.GstVideoFormatInfo, k: usize, w: c.gint) c.gint {
    return -((-w) >> @intCast(fi[0].w_sub[k]));
}

fn scaleH(fi: [*c]const c.GstVideoFormatInfo, k: usize, h: c.gint) c.gint {
    return -((-h) >> @intCast(fi[0].h_sub[k]));
}

fn compWidth(f: *Frame, k: usize) c.gint {
    return scaleW(finfo(f), k, width(f));
}

fn compHeight(f: *Frame, k: usize) c.gint {
    return scaleH(finfo(f), k, height(f));
}

fn at(p: [*]u8, off: c.gint) [*]u8 {
    return if (off >= 0) p + @as(usize, @intCast(off)) else p - @as(usize, @intCast(-off));
}

fn alpha255(a: f64, range: c.gint) c.gint {
    const v: c.gint = @intFromFloat(@trunc(a * @as(f64, @floatFromInt(range))));
    return std.math.clamp(v, 0, range);
}

fn div255(x: u16) u16 {
    return @truncate((@as(u32, x) * 0x8081) >> 23);
}

fn divlu(a: u16, b: u16) u16 {
    const d = b & 0xff;
    if (d == 0) return 255;
    return @min(@as(u16, 255), a / d);
}

fn rowsOf(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, j: usize) struct { [*]u8, [*]const u8 } {
    const jj: c.gint = @intCast(j);
    return .{ at(d, ds * jj), @ptrCast(at(@constCast(s), ss * jj)) };
}

pub fn orcBlendU8(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, p: c.gint, n: c.gint, m: c.gint) void {
    const pw: u16 = @truncate(@as(u32, @bitCast(p)));
    for (0..@intCast(m)) |j| {
        const r = rowsOf(d, ds, s, ss, j);
        for (0..@intCast(n)) |i| {
            const dv: u16 = r[0][i];
            const sv: u16 = r[1][i];
            const t = ((dv << 8) +% ((sv -% dv) *% pw)) >> 8;
            r[0][i] = @truncate(t);
        }
    }
}

fn rd16(p: [*]u8, swap: bool) u32 {
    const v = std.mem.readInt(u16, p[0..2], .little);
    return if (swap) @byteSwap(v) else v;
}

fn wr16(p: [*]u8, v: u16, swap: bool) void {
    std.mem.writeInt(u16, p[0..2], if (swap) @byteSwap(v) else v, .little);
}

fn orcBlendHigh(comptime bits: u5, comptime swap: bool) *const fn ([*]u8, c.gint, [*]const u8, c.gint, c.gint, c.gint, c.gint) void {
    return struct {
        fn f(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, p: c.gint, n: c.gint, m: c.gint) void {
            const pl: u32 = @bitCast(p);
            for (0..@intCast(m)) |j| {
                const r = rowsOf(d, ds, s, ss, j);
                for (0..@intCast(n)) |i| {
                    const dp = r[0] + i * 2;
                    const dv = rd16(dp, swap);
                    const sv = rd16(@constCast(r[1] + i * 2), swap);
                    const t: i32 = @bitCast(((dv << bits) +% ((sv -% dv) *% pl)) >> bits);
                    wr16(dp, @intCast(std.math.clamp(t, 0, 65535)), swap);
                }
            }
        }
    }.f;
}

fn argbLike(comptime ai: usize) type {
    return struct {
        fn blend(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, alpha: c.gint, n: c.gint, m: c.gint) void {
            const al: u16 = @truncate(@as(u32, @bitCast(alpha)));
            for (0..@intCast(m)) |j| {
                const r = rowsOf(d, ds, s, ss, j);
                for (0..@intCast(n)) |i| {
                    const sp = r[1] + i * 4;
                    const dp = r[0] + i * 4;
                    const aw = div255(@as(u16, sp[ai]) *% al);
                    const inv = @as(u16, 0xff) -% aw;
                    for (0..4) |k| {
                        const v = div255(@as(u16, dp[k]) *% inv +% @as(u16, sp[k]) *% aw);
                        dp[k] = @truncate(v);
                    }
                    dp[ai] = 0xff;
                }
            }
        }

        fn source(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, alpha: c.gint, n: c.gint, m: c.gint) void {
            const al: u16 = @truncate(@as(u32, @bitCast(alpha)));
            for (0..@intCast(m)) |j| {
                const r = rowsOf(d, ds, s, ss, j);
                for (0..@intCast(n)) |i| {
                    const sp = r[1] + i * 4;
                    const dp = r[0] + i * 4;
                    const aw = div255(@as(u16, sp[ai]) *% al);
                    for (0..4) |k| dp[k] = sp[k];
                    dp[ai] = @truncate(aw);
                }
            }
        }

        fn overlay(comptime add: bool) *const fn ([*]u8, c.gint, [*]const u8, c.gint, c.gint, c.gint, c.gint) void {
            return struct {
                fn f(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, alpha: c.gint, n: c.gint, m: c.gint) void {
                    const al: u16 = @truncate(@as(u32, @bitCast(alpha)));
                    for (0..@intCast(m)) |j| {
                        const r = rowsOf(d, ds, s, ss, j);
                        for (0..@intCast(n)) |i| {
                            const sp = r[1] + i * 4;
                            const dp = r[0] + i * 4;
                            const as = div255(@as(u16, sp[ai]) *% al);
                            const inv = @as(u16, 0xff) -% as;
                            const da: u16 = dp[ai];
                            const ad = div255(da *% inv);
                            const total = ad +% as;
                            var o: [4]u8 = undefined;
                            for (0..4) |k| {
                                const w = @as(u16, dp[k]) *% ad +% @as(u16, sp[k]) *% as;
                                o[k] = @truncate(divlu(w, total));
                            }
                            o[ai] = @truncate(if (add) da +% as else total);
                            for (0..4) |k| dp[k] = o[k];
                        }
                    }
                }
            }.f;
        }
    };
}

const Argb = argbLike(0);
const Bgra = argbLike(3);

fn a32(comptime bpp: usize, comptime L: type, comptime overlay_kind: bool) Blend {
    _ = bpp;
    return struct {
        fn f(src: *Frame, xpos0: c.gint, ypos0: c.gint, alpha: f64, dst: *Frame, ys: c.gint, ye0: c.gint, mode: c.gint) void {
            var sw = width(src);
            var sh = height(src);
            var s = planeData(src, 0);
            const sst = compStride(src, 0);
            var d = planeData(dst, 0);
            const dst_s = compStride(dst, 0);
            const dw = compWidth(dst, 0);
            const dh = compHeight(dst, 0);
            const sa: c.guint = @intCast(alpha255(alpha, 255));
            if (sa == 0) return;
            var ye = ye0;
            var xpos = xpos0;
            var ypos = ypos0;
            if (ye > dh) ye = dh;
            if (xpos < 0) {
                s += @as(usize, @intCast(-xpos * 4));
                sw -= -xpos;
                xpos = 0;
            }
            if (ypos < ys) {
                s = at(s, (ys - ypos) * sst);
                sh -= ys - ypos;
                ypos = ys;
            }
            if (xpos + sw > dw) sw = dw - xpos;
            if (ypos + sh > ye) sh = ye - ypos;
            if (sh <= 0 or sw <= 0) return;
            d = at(d, 4 * xpos + ypos * dst_s);
            const a: c.gint = @intCast(@min(@as(c.guint, 255), sa));
            switch (mode) {
                MODE_SOURCE => {
                    if (a == 255) {
                        for (0..@intCast(sh)) |y| {
                            const r = rowsOf(d, dst_s, s, sst, y);
                            @memcpy(r[0][0..@intCast(4 * sw)], r[1][0..@intCast(4 * sw)]);
                        }
                    } else L.source(d, dst_s, s, sst, a, sw, sh);
                },
                MODE_OVER => if (overlay_kind) L.overlay(false)(d, dst_s, s, sst, a, sw, sh) else L.blend(d, dst_s, s, sst, a, sw, sh),
                MODE_ADD => if (overlay_kind) L.overlay(true)(d, dst_s, s, sst, a, sw, sh) else L.blend(d, dst_s, s, sst, a, sw, sh),
                else => {},
            }
        }
    }.f;
}

pub const blend_argb = a32(4, Argb, false);
pub const blend_bgra = a32(4, Bgra, false);
pub const overlay_argb = a32(4, Argb, true);
pub const overlay_bgra = a32(4, Bgra, true);

fn checkerA32(comptime rgb: bool, comptime A: usize, comptime C1: usize, comptime C2: usize, comptime C3: usize) Checker {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint) void {
            const tab = [_]u8{ 80, 160, 80, 160 };
            const w: usize = @intCast(compWidth(fr, 0));
            const st = compStride(fr, 0);
            var d = at(planeData(fr, 0), @as(c.gint, @intCast(ys)) * st);
            var i = ys;
            while (i < ye) : (i += 1) {
                for (0..w) |j| {
                    const v = tab[((i & 0x8) >> 3) + ((j & 0x8) >> 3)];
                    d[A] = 0xff;
                    d[C1] = v;
                    d[C2] = if (rgb) v else 128;
                    d[C3] = if (rgb) v else 128;
                    d += 4;
                }
            }
        }
    }.f;
}

pub const fill_checker_argb = checkerA32(true, 0, 1, 2, 3);
pub const fill_checker_bgra = checkerA32(true, 3, 2, 1, 0);
pub const fill_checker_ayuv = checkerA32(false, 0, 1, 2, 3);
pub const fill_checker_vuya = checkerA32(false, 3, 2, 1, 0);

fn splat32(d: [*]u8, val: u32, n: usize) void {
    for (0..n) |i| std.mem.writeInt(u32, (d + i * 4)[0..4], val, .little);
}

fn shl(v: c.gint, comptime s: u5) u32 {
    return @as(u32, @bitCast(v)) << s;
}

fn colorA32(comptime A: u5, comptime C1: u5, comptime C2: u5, comptime C3: u5) Color {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint, c1: c.gint, c2: c.gint, c3: c.gint) void {
            const st = compStride(fr, 0);
            const d = at(planeData(fr, 0), @as(c.gint, @intCast(ys)) * st);
            const val = @byteSwap((@as(u32, 0xff) << A) | shl(c1, C1) | shl(c2, C2) | shl(c3, C3));
            const count: c.gint = (@as(c.gint, @intCast(ye)) - @as(c.gint, @intCast(ys))) * @divTrunc(st, 4);
            if (count > 0) splat32(d, val, @intCast(count));
        }
    }.f;
}

pub const fill_color_argb = colorA32(24, 16, 8, 0);
pub const fill_color_bgra = colorA32(0, 8, 16, 24);
pub const fill_color_abgr = colorA32(24, 0, 8, 16);
pub const fill_color_rgba = colorA32(0, 24, 16, 8);
pub const fill_color_ayuv = colorA32(24, 16, 8, 0);
pub const fill_color_vuya = colorA32(0, 8, 16, 24);

const Loop = *const fn ([*]u8, c.gint, [*]const u8, c.gint, c.gint, c.gint, c.gint) void;

fn roundUp(v: c.gint, comptime n: c.gint) c.gint {
    if (n == 1) return v;
    return (v + (n - 1)) & ~@as(c.gint, n - 1);
}

fn planarInner(src: [*]const u8, dest: [*]u8, ss: c.gint, ds: c.gint, ps: c.gint, sw: c.gint, sh: c.gint, alpha0: f64, mode: c.gint, comptime loop: Loop, comptime bits: c.gint) void {
    var alpha = alpha0;
    if (mode == MODE_SOURCE) alpha = 1.0;
    if (alpha == 0.0) return;
    if (alpha == 1.0) {
        const wb: usize = @intCast(sw * ps);
        for (0..@intCast(sh)) |i| {
            const r = rowsOf(dest, ds, src, ss, i);
            @memcpy(r[0][0..wb], r[1][0..wb]);
        }
        return;
    }
    const range: c.gint = (@as(c.gint, 1) << @intCast(bits)) - 1;
    loop(dest, ds, src, ss, alpha255(alpha, range), sw, sh);
}

fn planarYuv(comptime xr: c.gint, comptime yr: c.gint, comptime loop: Loop, comptime bits: c.gint) Blend {
    return struct {
        fn f(src: *Frame, xpos0: c.gint, ypos0: c.gint, alpha: f64, dst: *Frame, ys: c.gint, ye0: c.gint, mode: c.gint) void {
            const sw = width(src);
            const sh = height(src);
            const fi = finfo(src);
            const dw = width(dst);
            const dh = height(dst);
            var ye = ye0;
            if (ye > dh) ye = dh;
            var xpos = roundUp(xpos0, xr);
            var ypos = roundUp(ypos0, yr);
            var bw = sw;
            var bh = sh;
            var xoff: c.gint = 0;
            var yoff: c.gint = 0;
            if (xpos < 0) {
                xoff = -xpos;
                bw -= -xpos;
                xpos = 0;
            }
            if (ypos < ys) {
                yoff = ys - ypos;
                bh -= ys - ypos;
                ypos = ys;
            }
            if (xoff >= sw or yoff >= sh) return;
            if (xpos + bw > dw) bw = dw - xpos;
            if (ypos + bh > ye) bh = ye - ypos;
            if (bw <= 0 or bh <= 0) return;
            for (0..3) |k| {
                const ss = compStride(src, k);
                const dss = compStride(dst, k);
                const cw = scaleW(fi, k, bw);
                const ch = scaleH(fi, k, bh);
                const ps = fi[0].pixel_stride[k];
                const hs: u5 = @intCast(fi[0].h_sub[k]);
                const cx = if (xpos == 0) 0 else scaleW(fi, k, xpos);
                const cy = if (ypos == 0) 0 else if (k == 0) scaleH(fi, 0, ypos) else ypos >> hs;
                const cxo = if (xoff == 0) 0 else scaleW(fi, k, xoff);
                const cyo = if (yoff == 0) 0 else if (k == 0) scaleH(fi, 0, yoff) else yoff >> hs;
                planarInner(at(compData(src, k), cxo * ps + cyo * ss), at(compData(dst, k), cx * ps + cy * dss), ss, dss, ps, cw, ch, alpha, mode, loop, bits);
            }
        }
    }.f;
}

pub const blend_i420 = planarYuv(2, 2, orcBlendU8, 8);
pub const blend_y444 = planarYuv(1, 1, orcBlendU8, 8);
pub const blend_y42b = planarYuv(2, 1, orcBlendU8, 8);
pub const blend_y41b = planarYuv(4, 1, orcBlendU8, 8);
pub const blend_i420_10le = planarYuv(2, 2, orcBlendHigh(10, false), 10);
pub const blend_i420_10be = planarYuv(2, 2, orcBlendHigh(10, true), 10);
pub const blend_i420_12le = planarYuv(2, 2, orcBlendHigh(12, false), 12);
pub const blend_i420_12be = planarYuv(2, 2, orcBlendHigh(12, true), 12);
pub const blend_i422_10le = planarYuv(2, 1, orcBlendHigh(10, false), 10);
pub const blend_i422_10be = planarYuv(2, 1, orcBlendHigh(10, true), 10);
pub const blend_i422_12le = planarYuv(2, 1, orcBlendHigh(12, false), 12);
pub const blend_i422_12be = planarYuv(2, 1, orcBlendHigh(12, true), 12);
pub const blend_y444_10le = planarYuv(1, 1, orcBlendHigh(10, false), 10);
pub const blend_y444_10be = planarYuv(1, 1, orcBlendHigh(10, true), 10);
pub const blend_y444_12le = planarYuv(1, 1, orcBlendHigh(12, false), 12);
pub const blend_y444_12be = planarYuv(1, 1, orcBlendHigh(12, true), 12);
pub const blend_y444_16le = planarYuv(1, 1, orcBlendHigh(16, false), 16);
pub const blend_y444_16be = planarYuv(1, 1, orcBlendHigh(16, true), 16);

fn compYOffset(fi: [*c]const c.GstVideoFormatInfo, k: usize, ys: c.guint) c.gint {
    if (ys == 0) return 0;
    const y: c.gint = @intCast(ys);
    return if (k == 0) scaleH(fi, 0, y) else y >> @intCast(fi[0].h_sub[k]);
}

fn rowsCount(fi: [*c]const c.GstVideoFormatInfo, k: usize, ys: c.guint, ye: c.guint) c.gint {
    return scaleH(fi, k, @as(c.gint, @intCast(ye)) - @as(c.gint, @intCast(ys)));
}

pub fn fill_checker_planar(fr: *Frame, ys: c.guint, ye: c.guint) void {
    const tab = [_]u8{ 80, 160, 80, 160 };
    const fi = finfo(fr);
    {
        const cw: usize = @intCast(compWidth(fr, 0));
        const ch = rowsCount(fi, 0, ys, ye);
        const rs = compStride(fr, 0);
        var p = at(compData(fr, 0), compYOffset(fi, 0, ys) * rs);
        var i: c.gint = 0;
        while (i < ch) : (i += 1) {
            const row: usize = @as(usize, @intCast(i)) + ys;
            for (0..cw) |j| p[j] = tab[((row & 0x8) >> 3) + ((j & 0x8) >> 3)];
            p = at(p, rs);
        }
    }
    for (1..3) |k| {
        const cw: usize = @intCast(compWidth(fr, k));
        const ch = rowsCount(fi, k, ys, ye);
        const rs = compStride(fr, k);
        var p = at(compData(fr, k), compYOffset(fi, k, ys) * rs);
        var i: c.gint = 0;
        while (i < ch) : (i += 1) {
            @memset(p[0..cw], 0x80);
            p = at(p, rs);
        }
    }
}

pub fn fill_color_planar(fr: *Frame, ys: c.guint, ye: c.guint, cy: c.gint, cu: c.gint, cv: c.gint) void {
    const fi = finfo(fr);
    const cols = [_]c.gint{ cy, cu, cv };
    for (0..3) |k| {
        const cw: usize = @intCast(compWidth(fr, k));
        const ch = rowsCount(fi, k, ys, ye);
        const rs = compStride(fr, k);
        var p = at(compData(fr, k), compYOffset(fi, k, ys) * rs);
        var i: c.gint = 0;
        while (i < ch) : (i += 1) {
            @memset(p[0..cw], @truncate(@as(u32, @bitCast(cols[k]))));
            p = at(p, rs);
        }
    }
}

fn memset16(p: [*]u8, stride: c.gint, v: u16, n: c.gint, m: c.gint) void {
    for (0..@intCast(@max(m, 0))) |j| {
        const row = at(p, stride * @as(c.gint, @intCast(j)));
        for (0..@intCast(@max(n, 0))) |i| std.mem.writeInt(u16, (row + i * 2)[0..2], v, .little);
    }
}

fn toEndian(v: u16, comptime be: bool) u16 {
    return if (be) @byteSwap(v) else v;
}

fn checkerHigh(comptime bits: u5, comptime be: bool) Checker {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint) void {
            const tab = [_]u16{ 80 << (bits - 8), 160 << (bits - 8), 80 << (bits - 8), 160 << (bits - 8) };
            const fi = finfo(fr);
            const cw: usize = @intCast(compWidth(fr, 0));
            const ch = rowsCount(fi, 0, ys, ye);
            const rs = compStride(fr, 0);
            const ps: usize = @intCast(compPstride(fr, 0));
            var p = at(compData(fr, 0), compYOffset(fi, 0, ys) * rs);
            var i: c.gint = 0;
            while (i < ch) : (i += 1) {
                const row: usize = @as(usize, @intCast(i)) + ys;
                for (0..cw) |j| std.mem.writeInt(u16, (p + j * ps)[0..2], tab[((row & 0x8) >> 3) + ((j & 0x8) >> 3)], if (be) .big else .little);
                p = at(p, rs);
            }
            const uv = toEndian(@as(u16, 1) << @intCast(bits - 1), be);
            for (1..3) |k| {
                const crs = compStride(fr, k);
                memset16(at(compData(fr, k), compYOffset(fi, k, ys) * crs), crs, uv, compWidth(fr, k), rowsCount(fi, k, ys, ye));
            }
        }
    }.f;
}

fn colorHigh(comptime be: bool) Color {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint, cy: c.gint, cu: c.gint, cv: c.gint) void {
            const fi = finfo(fr);
            const cols = [_]c.gint{ cy, cu, cv };
            for (0..3) |k| {
                const rs = compStride(fr, k);
                memset16(at(compData(fr, k), compYOffset(fi, k, ys) * rs), rs, toEndian(@truncate(@as(u32, @bitCast(cols[k]))), be), compWidth(fr, k), rowsCount(fi, k, ys, ye));
            }
        }
    }.f;
}

pub const fill_checker_i420_10le = checkerHigh(10, false);
pub const fill_checker_i420_10be = checkerHigh(10, true);
pub const fill_checker_i420_12le = checkerHigh(12, false);
pub const fill_checker_i420_12be = checkerHigh(12, true);
pub const fill_checker_y444_16le = checkerHigh(16, false);
pub const fill_checker_y444_16be = checkerHigh(16, true);
pub const fill_color_high_le = colorHigh(false);
pub const fill_color_high_be = colorHigh(true);

const C16 = struct {
    fn sa(v: u64, p: u64) u64 {
        return @min((v *% p) / 65535, 65535);
    }

    fn blend(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, p1: c.gint, n: c.gint, m: c.gint) void {
        const p: u64 = @intCast(p1);
        for (0..@intCast(m)) |j| {
            const r = rowsOf(d, ds, s, ss, j);
            for (0..@intCast(n)) |i| {
                const sv = std.mem.readInt(u64, (r[1] + i * 8)[0..8], .little);
                const dv = std.mem.readInt(u64, (r[0] + i * 8)[0..8], .little);
                const a = sa(sv & 0xffff, p);
                const inv = 65535 - a;
                var o: u64 = 0xffff;
                for (0..3) |k| {
                    const sh: u6 = @intCast(48 - 16 * k);
                    const x = (((sv >> sh) & 0xffff) *% a +% ((dv >> sh) & 0xffff) *% inv) / 65535;
                    o |= @as(u64, @min(x, 65535)) << sh;
                }
                std.mem.writeInt(u64, (r[0] + i * 8)[0..8], o, .little);
            }
        }
    }

    fn source(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, p1: c.gint, n: c.gint, m: c.gint) void {
        const p: u64 = @intCast(p1);
        for (0..@intCast(m)) |j| {
            const r = rowsOf(d, ds, s, ss, j);
            for (0..@intCast(n)) |i| {
                const sv = std.mem.readInt(u64, (r[1] + i * 8)[0..8], .little);
                std.mem.writeInt(u64, (r[0] + i * 8)[0..8], (sv & 0xffffffffffff0000) | sa(sv & 0xffff, p), .little);
            }
        }
    }

    fn overlay(comptime add: bool) Loop {
        return struct {
            fn f(d: [*]u8, ds: c.gint, s: [*]const u8, ss: c.gint, p1: c.gint, n: c.gint, m: c.gint) void {
                const p: u64 = @intCast(p1);
                for (0..@intCast(m)) |j| {
                    const r = rowsOf(d, ds, s, ss, j);
                    for (0..@intCast(n)) |i| {
                        const sv = std.mem.readInt(u64, (r[1] + i * 8)[0..8], .little);
                        const dv = std.mem.readInt(u64, (r[0] + i * 8)[0..8], .little);
                        const a = sa(sv & 0xffff, p);
                        const inv = 65535 - a;
                        var factor = ((dv & 0xffff) *% inv) / 65535;
                        var comps: [3]u64 = undefined;
                        for (0..3) |k| {
                            const sh: u6 = @intCast(48 - 16 * k);
                            comps[k] = ((sv >> sh) & 0xffff) *% a +% ((dv >> sh) & 0xffff) *% factor;
                        }
                        factor = @min(factor +% a, 65535);
                        var o: u64 = 0;
                        for (0..3) |k| {
                            var x = comps[k];
                            if (factor > 0) x /= factor;
                            o |= @as(u64, @min(x, 65535)) << @intCast(48 - 16 * k);
                        }
                        const out_a = if (add) @min((dv & 0xffff) +% a, 65535) else factor;
                        std.mem.writeInt(u64, (r[0] + i * 8)[0..8], o | out_a, .little);
                    }
                }
            }
        }.f;
    }
};

fn a64(comptime overlay_kind: bool) Blend {
    return struct {
        fn f(src: *Frame, xpos0: c.gint, ypos0: c.gint, alpha: f64, dst: *Frame, ys: c.gint, ye0: c.gint, mode: c.gint) void {
            var sw = width(src);
            var sh = height(src);
            var s = planeData(src, 0);
            const sst = compStride(src, 0);
            var d = planeData(dst, 0);
            const dst_s = compStride(dst, 0);
            const dw = compWidth(dst, 0);
            const dh = compHeight(dst, 0);
            const sa = alpha255(alpha, 65535);
            if (sa == 0) return;
            var ye = ye0;
            var xpos = xpos0;
            var ypos = ypos0;
            if (ye > dh) ye = dh;
            if (xpos < 0) {
                s += @as(usize, @intCast(-xpos * 8));
                sw -= -xpos;
                xpos = 0;
            }
            if (ypos < ys) {
                s = at(s, (ys - ypos) * sst);
                sh -= ys - ypos;
                ypos = ys;
            }
            if (xpos + sw > dw) sw = dw - xpos;
            if (ypos + sh > ye) sh = ye - ypos;
            if (sh <= 0 or sw <= 0) return;
            d = at(d, 8 * xpos + ypos * dst_s);
            switch (mode) {
                MODE_SOURCE => {
                    if (sa == 65535) {
                        for (0..@intCast(sh)) |y| {
                            const r = rowsOf(d, dst_s, s, sst, y);
                            @memcpy(r[0][0..@intCast(8 * sw)], r[1][0..@intCast(8 * sw)]);
                        }
                    } else C16.source(d, dst_s, s, sst, sa, sw, sh);
                },
                MODE_OVER => if (overlay_kind) C16.overlay(false)(d, dst_s, s, sst, sa, sw, sh) else C16.blend(d, dst_s, s, sst, sa, sw, sh),
                MODE_ADD => if (overlay_kind) C16.overlay(true)(d, dst_s, s, sst, sa, sw, sh) else C16.blend(d, dst_s, s, sst, sa, sw, sh),
                else => {},
            }
        }
    }.f;
}

pub const blend_argb64 = a64(false);
pub const overlay_argb64 = a64(true);

fn checkerA64(comptime rgb: bool) Checker {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint) void {
            const tab = [_]u16{ 20480, 40960, 20480, 40960 };
            const w: usize = @intCast(compWidth(fr, 0));
            const st = compStride(fr, 0);
            var i = ys;
            while (i < ye) : (i += 1) {
                const row = at(planeData(fr, 0), @as(c.gint, @intCast(i)) * st);
                for (0..w) |j| {
                    const v = tab[((i & 0x8) >> 3) + ((j & 0x8) >> 3)];
                    const px = row + j * 8;
                    std.mem.writeInt(u16, px[0..2], 0xffff, .little);
                    std.mem.writeInt(u16, px[2..4], v, .little);
                    std.mem.writeInt(u16, px[4..6], if (rgb) v else 1 << 15, .little);
                    std.mem.writeInt(u16, px[6..8], if (rgb) v else 1 << 15, .little);
                }
            }
        }
    }.f;
}

pub const fill_checker_argb64 = checkerA64(true);
pub const fill_checker_ayuv64 = checkerA64(false);

pub fn fill_color_argb64(fr: *Frame, ys: c.guint, ye: c.guint, c1: c.gint, c2: c.gint, c3: c.gint) void {
    if (ye <= ys) return;
    const st = compStride(fr, 0);
    const w: usize = @intCast(width(fr));
    var i = ys;
    while (i < ye) : (i += 1) {
        const row = at(planeData(fr, 0), @as(c.gint, @intCast(i)) * st);
        for (0..w) |j| {
            const px = row + j * 8;
            std.mem.writeInt(u16, px[0..2], 0xffff, .little);
            std.mem.writeInt(u16, px[2..4], @truncate(@as(u32, @bitCast(c1))), .little);
            std.mem.writeInt(u16, px[4..6], @truncate(@as(u32, @bitCast(c2))), .little);
            std.mem.writeInt(u16, px[6..8], @truncate(@as(u32, @bitCast(c3))), .little);
        }
    }
}

fn nvInner(src: [*]const u8, dest: [*]u8, ss: c.gint, ds: c.gint, sw: c.gint, sh: c.gint, alpha0: f64, mode: c.gint) void {
    var alpha = alpha0;
    if (mode == MODE_SOURCE) alpha = 1.0;
    if (alpha == 0.0) return;
    if (alpha == 1.0) {
        for (0..@intCast(sh)) |i| {
            const r = rowsOf(dest, ds, src, ss, i);
            @memcpy(r[0][0..@intCast(sw)], r[1][0..@intCast(sw)]);
        }
        return;
    }
    orcBlendU8(dest, ds, src, ss, alpha255(alpha, 255), sw, sh);
}

pub fn blend_nv(src: *Frame, xpos0: c.gint, ypos0: c.gint, alpha: f64, dst: *Frame, ys: c.gint, ye0: c.gint, mode: c.gint) void {
    const sw = width(src);
    const sh = height(src);
    const fi = finfo(src);
    const dw = width(dst);
    const dh = height(dst);
    var ye = ye0;
    if (ye > dh) ye = dh;
    var xpos = roundUp(xpos0, 2);
    var ypos = roundUp(ypos0, 2);
    var bw = sw;
    var bh = sh;
    var xoff: c.gint = 0;
    var yoff: c.gint = 0;
    if (xpos < 0) {
        xoff = -xpos;
        bw -= -xpos;
        xpos = 0;
    }
    if (ypos < ys) {
        yoff += ys - ypos;
        bh -= ys - ypos;
        ypos = ys;
    }
    if (xoff > sw or yoff > sh) return;
    if (xpos + bw > dw) bw = dw - xpos;
    if (ypos + bh > ye) bh = ye - ypos;
    if (bw < 0 or bh < 0) return;
    {
        const ss = compStride(src, 0);
        const dss = compStride(dst, 0);
        const cx = if (xpos == 0) 0 else scaleW(fi, 0, xpos);
        const cy = if (ypos == 0) 0 else scaleH(fi, 0, ypos);
        const cxo = if (xoff == 0) 0 else scaleW(fi, 0, xoff);
        const cyo = if (yoff == 0) 0 else scaleH(fi, 0, yoff);
        nvInner(at(compData(src, 0), cxo + cyo * ss), at(compData(dst, 0), cx + cy * dss), ss, dss, scaleW(fi, 0, bw), scaleH(fi, 0, bh), alpha, mode);
    }
    {
        const ss = compStride(src, 1);
        const dss = compStride(dst, 1);
        const hs: u5 = @intCast(fi[0].h_sub[1]);
        const cx = if (xpos == 0) 0 else scaleW(fi, 1, xpos);
        const cy = if (ypos == 0) 0 else ypos >> hs;
        const cxo = if (xoff == 0) 0 else scaleW(fi, 1, xoff);
        const cyo = if (yoff == 0) 0 else yoff >> hs;
        nvInner(at(planeData(src, 1), cxo * 2 + cyo * ss), at(planeData(dst, 1), cx * 2 + cy * dss), ss, dss, 2 * scaleW(fi, 1, bw), scaleH(fi, 1, bh), alpha, mode);
    }
}

pub fn fill_checker_nv(fr: *Frame, ys: c.guint, ye: c.guint) void {
    const tab = [_]u8{ 80, 160, 80, 160 };
    const fi = finfo(fr);
    {
        const cw: usize = @intCast(compWidth(fr, 0));
        const ch = rowsCount(fi, 0, ys, ye);
        const rs = compStride(fr, 0);
        var p = at(compData(fr, 0), compYOffset(fi, 0, ys) * rs);
        var i: c.gint = 0;
        while (i < ch) : (i += 1) {
            const row: usize = @as(usize, @intCast(i)) + ys;
            for (0..cw) |j| p[j] = tab[((row & 0x8) >> 3) + ((j & 0x8) >> 3)];
            p = at(p, rs);
        }
    }
    const cw: usize = @intCast(compWidth(fr, 1));
    const ch = rowsCount(fi, 1, ys, ye);
    const rs = compStride(fr, 1);
    var p = at(planeData(fr, 1), compYOffset(fi, 1, ys) * rs);
    var i: c.gint = 0;
    while (i < ch) : (i += 1) {
        @memset(p[0 .. cw * 2], 0x80);
        p = at(p, rs);
    }
}

pub fn fill_color_nv(fr: *Frame, ys: c.guint, ye: c.guint, cy: c.gint, cu: c.gint, cv: c.gint) void {
    const fi = finfo(fr);
    {
        const cw: usize = @intCast(compWidth(fr, 0));
        const ch = rowsCount(fi, 0, ys, ye);
        const rs = compStride(fr, 0);
        var p = at(compData(fr, 0), compYOffset(fi, 0, ys) * rs);
        var i: c.gint = 0;
        while (i < ch) : (i += 1) {
            @memset(p[0..cw], @truncate(@as(u32, @bitCast(cy))));
            p = at(p, rs);
        }
    }
    const cw: usize = @intCast(compWidth(fr, 1));
    const ch = rowsCount(fi, 1, ys, ye);
    const rs = compStride(fr, 1);
    var u = at(compData(fr, 1), compYOffset(fi, 1, ys) * rs);
    var v = at(compData(fr, 2), compYOffset(fi, 1, ys) * rs);
    var i: c.gint = 0;
    while (i < ch) : (i += 1) {
        for (0..cw) |j| {
            u[j * 2] = @truncate(@as(u32, @bitCast(cu)));
            v[j * 2] = @truncate(@as(u32, @bitCast(cv)));
        }
        u = at(u, rs);
        v = at(v, rs);
    }
}

fn packedRows(comptime bpp: c.gint, comptime round_x: bool, comptime memcpy32: bool) Blend {
    return struct {
        fn f(src: *Frame, xpos0: c.gint, ypos0: c.gint, alpha0: f64, dst: *Frame, ys: c.gint, ye0: c.gint, mode: c.gint) void {
            var sw = width(src);
            var sh = height(src);
            var s = planeData(src, 0);
            var d = planeData(dst, 0);
            const dw = width(dst);
            const dh = height(dst);
            const sst = compStride(src, 0);
            const dst_s = compStride(dst, 0);
            const ba = alpha255(alpha0, 255);
            var xpos = if (round_x) roundUp(xpos0, 2) else xpos0;
            var ypos = ypos0;
            var ye = ye0;
            if (ye > dh) ye = dh;
            if (xpos < 0) {
                s += @as(usize, @intCast(-xpos * bpp));
                sw -= -xpos;
                xpos = 0;
            }
            if (ypos < ys) {
                s = at(s, (ys - ypos) * sst);
                sh -= ys - ypos;
                ypos = ys;
            }
            if (xpos + sw > dw) sw = dw - xpos;
            if (ypos + sh > ye) sh = ye - ypos;
            d = at(d, bpp * xpos + ypos * dst_s);
            var alpha = alpha0;
            if (mode == MODE_SOURCE) alpha = 1.0;
            if (alpha == 0.0) return;
            if (alpha == 1.0) {
                if (sh <= 0) return;
                for (0..@intCast(sh)) |i| {
                    const r = rowsOf(d, dst_s, s, sst, i);
                    var n = bpp * sw;
                    if (memcpy32) n = @divTrunc(n, 4) * 4;
                    if (n > 0) @memcpy(r[0][0..@intCast(n)], r[1][0..@intCast(n)]);
                }
                return;
            }
            if (sh > 0 and sw > 0) orcBlendU8(d, dst_s, s, sst, ba, sw * bpp, sh);
        }
    }.f;
}

pub const blend_rgb = packedRows(3, false, false);
pub const blend_rgbx = packedRows(4, false, true);
pub const blend_yuy2 = packedRows(2, true, false);

fn checkerRgb(comptime bpp: usize, comptime r: usize, comptime g: usize, comptime b: usize) Checker {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint) void {
            const tab = [_]u8{ 80, 160, 80, 160 };
            const w: usize = @intCast(width(fr));
            const st = compStride(fr, 0);
            var i: c.guint = 0;
            while (i < ye - ys) : (i += 1) {
                const row = at(planeData(fr, 0), @as(c.gint, @intCast(ys + i)) * st);
                for (0..w) |j| {
                    const v = tab[(((i + ys) & 0x8) >> 3) + ((j & 0x8) >> 3)];
                    const px = row + j * bpp;
                    px[r] = v;
                    px[g] = v;
                    px[b] = v;
                }
            }
        }
    }.f;
}

pub const fill_checker_rgb = checkerRgb(3, 0, 1, 2);
pub const fill_checker_xrgb = checkerRgb(4, 1, 2, 3);
pub const fill_checker_rgbx = checkerRgb(4, 0, 1, 2);

fn colorRgb3(comptime r: usize, comptime g: usize, comptime b: usize) Color {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint, cr: c.gint, cg: c.gint, cb: c.gint) void {
            const w: usize = @intCast(width(fr));
            const st = compStride(fr, 0);
            var i: c.guint = 0;
            while (i < ye - ys) : (i += 1) {
                const row = at(planeData(fr, 0), @as(c.gint, @intCast(ys + i)) * st);
                for (0..w) |j| {
                    const px = row + j * 3;
                    px[r] = @truncate(@as(u32, @bitCast(cr)));
                    px[g] = @truncate(@as(u32, @bitCast(cg)));
                    px[b] = @truncate(@as(u32, @bitCast(cb)));
                }
            }
        }
    }.f;
}

pub const fill_color_rgb = colorRgb3(0, 1, 2);
pub const fill_color_bgr = colorRgb3(2, 1, 0);

fn colorX(comptime r: u5, comptime g: u5, comptime b: u5) Color {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint, cr: c.gint, cg: c.gint, cb: c.gint) void {
            const w: usize = @intCast(width(fr));
            const st = compStride(fr, 0);
            const val = @byteSwap(shl(cr, r) | shl(cg, g) | shl(cb, b));
            var i: c.guint = 0;
            while (i < ye - ys) : (i += 1) splat32(at(planeData(fr, 0), @as(c.gint, @intCast(ys + i)) * st), val, w);
        }
    }.f;
}

pub const fill_color_xrgb = colorX(24, 16, 0);
pub const fill_color_xbgr = colorX(0, 16, 24);
pub const fill_color_rgbx = colorX(24, 16, 8);
pub const fill_color_bgrx = colorX(8, 16, 24);

fn checker422(comptime Y1: usize, comptime U: usize, comptime Y2: usize, comptime V: usize) Checker {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint) void {
            const tab = [_]u8{ 80, 160, 80, 160 };
            const w: usize = @intCast(@divTrunc(roundUp(width(fr), 2), 2));
            const st = compStride(fr, 0);
            var i: c.guint = 0;
            while (i < ye - ys) : (i += 1) {
                const row = at(planeData(fr, 0), @as(c.gint, @intCast(ys + i)) * st);
                for (0..w) |j| {
                    const px = row + j * 4;
                    px[Y1] = tab[(((i + ys) & 0x8) >> 3) + (((2 * j) & 0x8) >> 3)];
                    px[Y2] = tab[(((i + ys) & 0x8) >> 3) + (((2 * j + 1) & 0x8) >> 3)];
                    px[U] = 128;
                    px[V] = 128;
                }
            }
        }
    }.f;
}

pub const fill_checker_yuy2 = checker422(0, 1, 2, 3);
pub const fill_checker_uyvy = checker422(1, 0, 3, 2);

fn color422(comptime Y1: u5, comptime U: u5, comptime Y2: u5, comptime V: u5) Color {
    return struct {
        fn f(fr: *Frame, ys: c.guint, ye: c.guint, cy: c.gint, cu: c.gint, cv: c.gint) void {
            const w: usize = @intCast(@divTrunc(roundUp(width(fr), 2), 2));
            const st = compStride(fr, 0);
            const val = @byteSwap(shl(cy, Y1) | shl(cy, Y2) | shl(cu, U) | shl(cv, V));
            var i: c.guint = 0;
            while (i < ye - ys) : (i += 1) splat32(at(planeData(fr, 0), @as(c.gint, @intCast(ys + i)) * st), val, w);
        }
    }.f;
}

pub const fill_color_yuy2 = color422(24, 16, 8, 0);
pub const fill_color_yvyu = color422(24, 0, 8, 16);
pub const fill_color_uyvy = color422(16, 24, 0, 8);
