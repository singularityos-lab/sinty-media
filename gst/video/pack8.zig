const std = @import("std");
const c = @import("../c.zig").c;
const l = @import("line.zig");

const Info = l.Info;
const Flags = l.Flags;
const Data = l.Data;
const Out = l.DataOut;
const Stride = l.Stride;
const Site = c.GstVideoChromaSite;

const Y = c.GST_VIDEO_COMP_Y;
const U = c.GST_VIDEO_COMP_U;
const V = c.GST_VIDEO_COMP_V;
const A = c.GST_VIDEO_COMP_A;
const R = c.GST_VIDEO_COMP_R;
const G = c.GST_VIDEO_COMP_G;
const B = c.GST_VIDEO_COMP_B;

fn planarUnpack(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x_in: c.gint, y: c.gint, width_in: c.gint, comptime vsub: enum { none, s420 }, comptime alpha: bool) void {
    const uv = if (vsub == .s420) l.uv420(y, flags) else y;
    var x = x_in;
    var width = width_in;
    var sy = l.comp(info, data, stride, Y, y) + l.n(x);
    var su = l.comp(info, data, stride, U, uv) + l.n(x >> 1);
    var sv = l.comp(info, data, stride, V, uv) + l.n(x >> 1);
    var sa: [*]u8 = if (alpha) l.comp(info, data, stride, A, y) + l.n(x) else sy;
    var d = l.bytes(dest);
    if (x & 1 != 0) {
        d[0] = if (alpha) sa[0] else 0xff;
        if (alpha) sa += 1;
        d[1] = sy[0];
        d[2] = su[0];
        d[3] = sv[0];
        sy += 1;
        su += 1;
        sv += 1;
        width -= 1;
        d += 4;
        x += 1;
    }
    for (0..l.n(width)) |i| {
        d[i * 4 + 0] = if (alpha) sa[i] else 0xff;
        d[i * 4 + 1] = sy[i];
        d[i * 4 + 2] = su[i >> 1];
        d[i * 4 + 3] = sv[i >> 1];
    }
}

pub fn unpackPlanar420(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    planarUnpack(info, flags, dest, data, stride, x, y, width, .s420, false);
}

pub fn unpackY42B(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    planarUnpack(info, flags, dest, data, stride, x, y, width, .none, false);
}

pub fn unpackA420(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    planarUnpack(info, flags, dest, data, stride, x, y, width, .s420, true);
}

fn planarPack(info: [*c]const Info, flags: Flags, src: c.gpointer, data: Out, stride: Stride, y: c.gint, width: c.gint, comptime vsub: bool, comptime alpha: bool) void {
    const uv = if (vsub) l.uv420(y, flags) else y;
    const dy = l.comp(info, data, stride, Y, y);
    const du = l.comp(info, data, stride, U, uv);
    const dv = l.comp(info, data, stride, V, uv);
    const da: [*]u8 = if (alpha) l.comp(info, data, stride, A, y) else dy;
    const s = l.bytes(src);
    const w = l.n(width);
    if (!vsub or l.chroma420(y, flags)) {
        for (0..w / 2) |i| {
            if (alpha) {
                da[i * 2] = s[i * 8];
                da[i * 2 + 1] = s[i * 8 + 4];
            }
            dy[i * 2] = s[i * 8 + 1];
            dy[i * 2 + 1] = s[i * 8 + 5];
            du[i] = s[i * 8 + 2];
            dv[i] = s[i * 8 + 3];
        }
        if (w & 1 != 0) {
            const i = w - 1;
            if (alpha) da[i] = s[i * 4];
            dy[i] = s[i * 4 + 1];
            du[i >> 1] = s[i * 4 + 2];
            dv[i >> 1] = s[i * 4 + 3];
        }
    } else {
        for (0..w) |i| {
            dy[i] = s[i * 4 + 1];
            if (alpha) da[i] = s[i * 4];
        }
    }
}

pub fn packPlanar420(info: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    planarPack(info, flags, src, data, stride, y, width, true, false);
}

pub fn packY42B(info: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    planarPack(info, flags, src, data, stride, y, width, false, false);
}

pub fn packA420(info: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    planarPack(info, flags, src, data, stride, y, width, true, true);
}

const Packed422 = struct { y0: usize, u: usize, y1: usize, v: usize, odd: [3]usize };

fn packed422Unpack(data: Data, stride: Stride, dest: c.gpointer, x: c.gint, y: c.gint, width_in: c.gint, comptime o: Packed422) void {
    packed422UnpackAligned(data, stride, dest, x, y, width_in, o, o);
}

fn aligned8(p: anytype) bool {
    return @intFromPtr(p) & 7 == 0;
}

fn packed422UnpackAligned(data: Data, stride: Stride, dest: c.gpointer, x: c.gint, y: c.gint, width_in: c.gint, comptime o: Packed422, comptime fast: Packed422) void {
    var s = l.plane(data, stride, 0, y) + (l.n(x & ~@as(c.gint, 1)) << 1);
    var d = l.bytes(dest);
    var width = width_in;
    if (x & 1 != 0) {
        d[0] = 0xff;
        d[1] = s[o.y1];
        d[2] = s[o.u];
        d[3] = s[o.v];
        s += 4;
        d += 4;
        width -= 1;
    }
    const w = l.n(width);
    const m = if (aligned8(d)) fast else o;
    for (0..w / 2) |i| {
        d[i * 8 + 0] = 0xff;
        d[i * 8 + 1] = s[i * 4 + m.y0];
        d[i * 8 + 2] = s[i * 4 + m.u];
        d[i * 8 + 3] = s[i * 4 + m.v];
        d[i * 8 + 4] = 0xff;
        d[i * 8 + 5] = s[i * 4 + m.y1];
        d[i * 8 + 6] = s[i * 4 + m.u];
        d[i * 8 + 7] = s[i * 4 + m.v];
    }
    if (w & 1 != 0) {
        const i = w - 1;
        d[i * 4 + 0] = 0xff;
        d[i * 4 + 1] = s[i * 2 + o.y0];
        d[i * 4 + 2] = s[i * 2 + o.u];
        d[i * 4 + 3] = s[i * 2 + o.v];
    }
}

fn packed422Pack(data: Out, stride: Stride, src: c.gpointer, y: c.gint, width: c.gint, comptime o: Packed422) void {
    packed422PackAligned(data, stride, src, y, width, o, o);
}

fn packed422PackAligned(data: Out, stride: Stride, src: c.gpointer, y: c.gint, width: c.gint, comptime o: Packed422, comptime fast: Packed422) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.bytes(src);
    const w = l.n(width);
    const m = if (aligned8(s)) fast else o;
    for (0..w / 2) |i| {
        d[i * 4 + m.y0] = s[i * 8 + 1];
        d[i * 4 + m.u] = s[i * 8 + 2];
        d[i * 4 + m.y1] = s[i * 8 + 5];
        d[i * 4 + m.v] = s[i * 8 + 3];
    }
    if (w & 1 != 0) {
        const i = w - 1;
        d[i * 2 + o.odd[0]] = s[i * 4 + 1];
        d[i * 2 + o.odd[1]] = s[i * 4 + 2];
        d[i * 2 + o.odd[2]] = s[i * 4 + 3];
    }
}

const YUY2 = Packed422{ .y0 = 0, .u = 1, .y1 = 2, .v = 3, .odd = .{ 0, 1, 3 } };
const UYVY = Packed422{ .y0 = 1, .u = 0, .y1 = 3, .v = 2, .odd = .{ 1, 0, 2 } };
const VYUY = Packed422{ .y0 = 1, .u = 2, .y1 = 3, .v = 0, .odd = .{ 1, 0, 2 } };
const YVYU = Packed422{ .y0 = 0, .u = 3, .y1 = 2, .v = 1, .odd = .{ 0, 3, 1 } };

pub fn unpackYUY2(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    packed422Unpack(data, stride, dest, x, y, width, YUY2);
}

pub fn packYUY2(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    packed422Pack(data, stride, src, y, width, YUY2);
}

pub fn unpackUYVY(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    packed422Unpack(data, stride, dest, x, y, width, UYVY);
}

pub fn packUYVY(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    packed422Pack(data, stride, src, y, width, UYVY);
}

pub fn unpackVYUY(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    packed422UnpackAligned(data, stride, dest, x, y, width, UYVY, VYUY);
}

pub fn packVYUY(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    packed422PackAligned(data, stride, src, y, width, UYVY, VYUY);
}

pub fn unpackYVYU(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    packed422Unpack(data, stride, dest, x, y, width, YVYU);
}

pub fn packYVYU(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    packed422Pack(data, stride, src, y, width, YVYU);
}

fn triple(comptime order: [3]usize) type {
    return struct {
        pub fn unpack(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const s = l.plane(data, stride, 0, y) + l.n(x) * 3;
            const d = l.bytes(dest);
            for (0..l.n(width)) |i| {
                d[i * 4] = 0xff;
                d[i * 4 + 1] = s[i * 3 + order[0]];
                d[i * 4 + 2] = s[i * 3 + order[1]];
                d[i * 4 + 3] = s[i * 3 + order[2]];
            }
        }
        pub fn pack(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const d = l.plane(data, stride, 0, y);
            const s = l.bytes(src);
            for (0..l.n(width)) |i| {
                d[i * 3 + order[0]] = s[i * 4 + 1];
                d[i * 3 + order[1]] = s[i * 4 + 2];
                d[i * 3 + order[2]] = s[i * 4 + 3];
            }
        }
    };
}

pub const v308 = triple(.{ 0, 1, 2 });
pub const IYU2 = triple(.{ 1, 0, 2 });
pub const RGB = triple(.{ 0, 1, 2 });
pub const BGR = triple(.{ 2, 1, 0 });

pub fn unpackCopy4(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y) + l.n(x) * 4;
    @memcpy(l.bytes(dest)[0 .. l.n(width) * 4], s[0 .. l.n(width) * 4]);
}

pub fn packCopy4(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    @memcpy(d[0 .. l.n(width) * 4], l.bytes(src)[0 .. l.n(width) * 4]);
}

fn swizzle(comptime order: [4]usize) type {
    return struct {
        pub fn unpack(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const s = l.plane(data, stride, 0, y) + l.n(x) * 4;
            const d = l.bytes(dest);
            for (0..l.n(width)) |i| {
                inline for (0..4) |k| d[i * 4 + k] = s[i * 4 + order[k]];
            }
        }
        pub fn pack(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const d = l.plane(data, stride, 0, y);
            const s = l.bytes(src);
            for (0..l.n(width)) |i| {
                inline for (0..4) |k| d[i * 4 + order[k]] = s[i * 4 + k];
            }
        }
    };
}

pub const BGRA = swizzle(.{ 3, 2, 1, 0 });
pub const ABGR = swizzle(.{ 0, 3, 2, 1 });
pub const RGBA = swizzle(.{ 3, 0, 1, 2 });
pub const RBGA = swizzle(.{ 3, 0, 2, 1 });
pub const VUYA = swizzle(.{ 3, 2, 1, 0 });

fn plane444(comptime c0: c_int, comptime c1: c_int, comptime c2: c_int) type {
    return struct {
        pub fn unpack(info: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const s0 = l.comp(info, data, stride, c0, y) + l.n(x);
            const s1 = l.comp(info, data, stride, c1, y) + l.n(x);
            const s2 = l.comp(info, data, stride, c2, y) + l.n(x);
            const d = l.bytes(dest);
            for (0..l.n(width)) |i| {
                d[i * 4] = 0xff;
                d[i * 4 + 1] = s0[i];
                d[i * 4 + 2] = s1[i];
                d[i * 4 + 3] = s2[i];
            }
        }
        pub fn pack(info: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const d0 = l.comp(info, data, stride, c0, y);
            const d1 = l.comp(info, data, stride, c1, y);
            const d2 = l.comp(info, data, stride, c2, y);
            const s = l.bytes(src);
            for (0..l.n(width)) |i| {
                d0[i] = s[i * 4 + 1];
                d1[i] = s[i * 4 + 2];
                d2[i] = s[i * 4 + 3];
            }
        }
    };
}

pub const Y444 = plane444(Y, U, V);
pub const GBR = plane444(R, G, B);

pub fn unpackGBRA(info: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const sg = l.comp(info, data, stride, G, y) + l.n(x);
    const sb = l.comp(info, data, stride, B, y) + l.n(x);
    const sr = l.comp(info, data, stride, R, y) + l.n(x);
    const sa = l.comp(info, data, stride, A, y) + l.n(x);
    const d = l.bytes(dest);
    for (0..l.n(width)) |i| {
        d[i * 4] = sa[i];
        d[i * 4 + 1] = sr[i];
        d[i * 4 + 2] = sg[i];
        d[i * 4 + 3] = sb[i];
    }
}

pub fn packGBRA(info: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const dg = l.comp(info, data, stride, G, y);
    const db = l.comp(info, data, stride, B, y);
    const dr = l.comp(info, data, stride, R, y);
    const da = l.comp(info, data, stride, A, y);
    const s = l.bytes(src);
    for (0..l.n(width)) |i| {
        dg[i] = s[i * 4 + 2];
        db[i] = s[i * 4 + 3];
        dr[i] = s[i * 4 + 1];
        da[i] = s[i * 4];
    }
}

pub fn unpackGRAY8(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y) + l.n(x);
    const d = l.bytes(dest);
    for (0..l.n(width)) |i| {
        d[i * 4] = 0xff;
        d[i * 4 + 1] = s[i];
        d[i * 4 + 2] = 0x80;
        d[i * 4 + 3] = 0x80;
    }
}

pub fn packGRAY8(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.bytes(src);
    for (0..l.n(width)) |i| d[i] = s[i * 4 + 1];
}

const Rgb16 = struct { r_shift: u4, g_shift: u4, b_shift: u4, r_bits: u4, g_bits: u4, b_bits: u4 };

fn expand(v: u16, bits: u4, trunc: bool) u8 {
    const b: u4 = 8 - bits;
    const hi: u16 = v << b;
    if (trunc) return @truncate(hi);
    return @truncate(hi | (v >> (bits - b)));
}

fn rgb16(comptime f: Rgb16) type {
    return struct {
        pub fn unpack(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const s = l.u16s(l.plane(data, stride, 0, y)) + l.n(x);
            const d = l.bytes(dest);
            const trunc = flags & l.TRUNCATE != 0;
            for (0..l.n(width)) |i| {
                const v = s[i];
                d[i * 4] = 0xff;
                d[i * 4 + 1] = expand((v >> f.r_shift) & ((@as(u16, 1) << f.r_bits) - 1), f.r_bits, trunc);
                d[i * 4 + 2] = expand((v >> f.g_shift) & ((@as(u16, 1) << f.g_bits) - 1), f.g_bits, trunc);
                d[i * 4 + 3] = expand((v >> f.b_shift) & ((@as(u16, 1) << f.b_bits) - 1), f.b_bits, trunc);
            }
        }
        pub fn pack(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const d = l.u16s(l.plane(data, stride, 0, y));
            const s = l.bytes(src);
            for (0..l.n(width)) |i| {
                const r: u16 = s[i * 4 + 1] >> @as(u3, 8 - f.r_bits);
                const g: u16 = s[i * 4 + 2] >> @as(u3, 8 - f.g_bits);
                const b: u16 = s[i * 4 + 3] >> @as(u3, 8 - f.b_bits);
                d[i] = r << f.r_shift | g << f.g_shift | b << f.b_shift;
            }
        }
    };
}

pub const RGB16 = rgb16(.{ .r_shift = 11, .g_shift = 5, .b_shift = 0, .r_bits = 5, .g_bits = 6, .b_bits = 5 });
pub const BGR16 = rgb16(.{ .r_shift = 0, .g_shift = 5, .b_shift = 11, .r_bits = 5, .g_bits = 6, .b_bits = 5 });
pub const RGB15 = rgb16(.{ .r_shift = 10, .g_shift = 5, .b_shift = 0, .r_bits = 5, .g_bits = 5, .b_bits = 5 });
pub const BGR15 = rgb16(.{ .r_shift = 0, .g_shift = 5, .b_shift = 10, .r_bits = 5, .g_bits = 5, .b_bits = 5 });

const Semi = struct { swap: bool, sub420: bool, odd_swap: bool };

fn semiUnpack(data: Data, stride: Stride, dest: c.gpointer, flags: Flags, x: c.gint, y: c.gint, width_in: c.gint, comptime o: Semi, comptime alpha: bool) void {
    const uv = if (o.sub420) l.uv420(y, flags) else y;
    var sy = l.plane(data, stride, 0, y) + l.n(x);
    var suv = l.plane(data, stride, 1, uv) + l.n(x & ~@as(c.gint, 1));
    var sa: [*]u8 = if (alpha) l.plane(data, stride, 2, y) + l.n(x) else sy;
    var d = l.bytes(dest);
    var width = width_in;
    const ui: usize = if (o.swap) 1 else 0;
    const vi: usize = 1 - ui;
    if (x & 1 != 0) {
        d[0] = if (alpha) sa[0] else 0xff;
        if (alpha) sa += 1;
        d[1] = sy[0];
        sy += 1;
        d[2] = suv[ui];
        d[3] = suv[vi];
        width -= 1;
        d += 4;
        suv += 2;
    }
    const w = l.n(width);
    for (0..w / 2) |i| {
        d[i * 8] = if (alpha) sa[i * 2] else 0xff;
        d[i * 8 + 1] = sy[i * 2];
        d[i * 8 + 2] = suv[i * 2 + ui];
        d[i * 8 + 3] = suv[i * 2 + vi];
        d[i * 8 + 4] = if (alpha) sa[i * 2 + 1] else 0xff;
        d[i * 8 + 5] = sy[i * 2 + 1];
        d[i * 8 + 6] = suv[i * 2 + ui];
        d[i * 8 + 7] = suv[i * 2 + vi];
    }
    if (w & 1 != 0) {
        const i = w - 1;
        d[i * 4] = if (alpha) sa[i] else 0xff;
        d[i * 4 + 1] = sy[i];
        d[i * 4 + 2] = suv[i + ui];
        d[i * 4 + 3] = suv[i + vi];
    }
}

fn semiPack(data: Out, stride: Stride, src: c.gpointer, flags: Flags, y: c.gint, width: c.gint, comptime o: Semi, comptime alpha: bool) void {
    const uv = if (o.sub420) l.uv420(y, flags) else y;
    const dy = l.plane(data, stride, 0, y);
    const duv = l.plane(data, stride, 1, uv);
    const da: [*]u8 = if (alpha) l.plane(data, stride, 2, y) else dy;
    const s = l.bytes(src);
    const w = l.n(width);
    const ui: usize = if (o.swap) 1 else 0;
    const vi: usize = 1 - ui;
    if (!o.sub420 or l.chroma420(y, flags)) {
        for (0..w / 2) |i| {
            if (alpha) {
                da[i * 2] = s[i * 8];
                da[i * 2 + 1] = s[i * 8 + 4];
            }
            dy[i * 2] = s[i * 8 + 1];
            dy[i * 2 + 1] = s[i * 8 + 5];
            duv[i * 2 + ui] = s[i * 8 + 2];
            duv[i * 2 + vi] = s[i * 8 + 3];
        }
        if (w & 1 != 0) {
            const i = w - 1;
            const oi: usize = if (o.odd_swap) 1 else 0;
            if (alpha) da[i] = s[i * 4];
            dy[i] = s[i * 4 + 1];
            duv[i + oi] = s[i * 4 + 2];
            duv[i + 1 - oi] = s[i * 4 + 3];
        }
    } else {
        for (0..w) |i| {
            dy[i] = s[i * 4 + 1];
            if (alpha) da[i] = s[i * 4];
        }
    }
}

fn semi(comptime o: Semi, comptime alpha: bool) type {
    return struct {
        pub fn unpack(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            semiUnpack(data, stride, dest, flags, x, y, width, o, alpha);
        }
        pub fn pack(_: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            semiPack(data, stride, src, flags, y, width, o, alpha);
        }
    };
}

pub const NV12 = semi(.{ .swap = false, .sub420 = true, .odd_swap = false }, false);
pub const NV21 = semi(.{ .swap = true, .sub420 = true, .odd_swap = true }, false);
pub const AV12 = semi(.{ .swap = false, .sub420 = true, .odd_swap = false }, true);
pub const NV16 = semi(.{ .swap = false, .sub420 = false, .odd_swap = false }, false);
pub const NV61 = semi(.{ .swap = true, .sub420 = false, .odd_swap = false }, false);

pub fn unpackNV24(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const sy = l.plane(data, stride, 0, y) + l.n(x);
    const suv = l.plane(data, stride, 1, y) + (l.n(x) << 1);
    const d = l.bytes(dest);
    for (0..l.n(width)) |i| {
        d[i * 4] = 0xff;
        d[i * 4 + 1] = sy[i];
        d[i * 4 + 2] = suv[i * 2];
        d[i * 4 + 3] = suv[i * 2 + 1];
    }
}

pub fn packNV24(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const dy = l.plane(data, stride, 0, y);
    const duv = l.plane(data, stride, 1, y);
    const s = l.bytes(src);
    for (0..l.n(width)) |i| {
        dy[i] = s[i * 4 + 1];
        duv[i * 2] = s[i * 4 + 2];
        duv[i * 2 + 1] = s[i * 4 + 3];
    }
}

pub fn unpackRGB8P(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y) + l.n(x);
    const p: [*]align(1) const u32 = @ptrCast(data[1]);
    const d = l.bytes(dest);
    for (0..l.n(width)) |i| {
        const v = p[s[i]];
        d[i * 4] = @truncate(v >> 24);
        d[i * 4 + 1] = @truncate(v >> 16);
        d[i * 4 + 2] = @truncate(v >> 8);
        d[i * 4 + 3] = @truncate(v);
    }
}

pub fn packRGB8P(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.bytes(src);
    for (0..l.n(width)) |i| {
        d[i] = if (s[i * 4] < 0x80) 6 * 6 * 6 else @intCast((s[i * 4 + 1] / 47 % 6) * 36 + (s[i * 4 + 2] / 47 % 6) * 6 + (s[i * 4 + 3] / 47 % 6));
    }
}

pub const palette = blk: {
    var p: [256]u32 = undefined;
    for (0..216) |i| p[i] = 0xff000000 | @as(u32, (i / 36) * 0x33) << 16 | @as(u32, (i / 6 % 6) * 0x33) << 8 | @as(u32, (i % 6) * 0x33);
    p[216] = 0;
    for (217..256) |i| p[i] = 0xff000000;
    break :blk p;
};

fn sub4Unpack(info: [*c]const Info, dest: c.gpointer, data: Data, stride: Stride, x_in: c.gint, y: c.gint, uv: c.gint, width_in: c.gint) void {
    var x = x_in;
    var width = width_in;
    var sy = l.comp(info, data, stride, Y, y) + l.n(x);
    var su = l.comp(info, data, stride, U, uv) + l.n(x >> 2);
    const sv = l.comp(info, data, stride, V, uv) + l.n(x >> 2);
    var d = l.bytes(dest);
    if (x & 3 != 0) {
        while (x & 3 != 0) : (x += 1) {
            d[0] = 0xff;
            d[1] = sy[0];
            sy += 1;
            d[2] = su[0];
            d[3] = sv[0];
            width -= 1;
            d += 4;
        }
        su += 1;
        sy += 1;
    }
    const w = l.n(width);
    for (0..w / 2) |i| {
        d[i * 8] = 0xff;
        d[i * 8 + 1] = sy[i * 2];
        d[i * 8 + 2] = su[i >> 1];
        d[i * 8 + 3] = sv[i >> 1];
        d[i * 8 + 4] = 0xff;
        d[i * 8 + 5] = sy[i * 2 + 1];
        d[i * 8 + 6] = su[i >> 1];
        d[i * 8 + 7] = sv[i >> 1];
    }
    if (w & 1 != 0) {
        const i = w - 1;
        d[i * 4] = 0xff;
        d[i * 4 + 1] = sy[i];
        d[i * 4 + 2] = su[i >> 2];
        d[i * 4 + 3] = sv[i >> 2];
    }
}

pub fn unpackY41B(info: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    sub4Unpack(info, dest, data, stride, x, y, y, width);
}

pub fn unpack410(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    sub4Unpack(info, dest, data, stride, x, y, l.uv410(y, flags), width);
}

pub fn packY41B(info: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const dy = l.comp(info, data, stride, Y, y);
    const du = l.comp(info, data, stride, U, y);
    const dv = l.comp(info, data, stride, V, y);
    const s = l.bytes(src);
    const w: usize = l.n(width);
    var i: usize = 0;
    while (i + 3 < w) : (i += 4) {
        dy[i] = s[i * 4 + 1];
        dy[i + 1] = s[i * 4 + 5];
        dy[i + 2] = s[i * 4 + 9];
        dy[i + 3] = s[i * 4 + 13];
        du[i >> 2] = s[i * 4 + 2];
        dv[i >> 2] = s[i * 4 + 3];
    }
    if (i < w) {
        dy[i] = s[i * 4 + 1];
        du[i >> 2] = s[i * 4 + 2];
        dv[i >> 2] = s[i * 4 + 3];
        if (i + 1 < w) dy[i + 1] = s[i * 4 + 5];
        if (i + 2 < w) dy[i + 2] = s[i * 4 + 9];
    }
}

pub fn pack410(info: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const uv = l.uv410(y, flags);
    const dy = l.comp(info, data, stride, Y, y);
    const du = l.comp(info, data, stride, U, uv);
    const dv = l.comp(info, data, stride, V, uv);
    const s = l.bytes(src);
    const w: usize = l.n(width);
    const chroma = l.chroma410(y, flags);
    var i: usize = 0;
    while (i + 3 < w) : (i += 4) {
        dy[i] = s[i * 4 + 1];
        dy[i + 1] = s[i * 4 + 5];
        dy[i + 2] = s[i * 4 + 9];
        dy[i + 3] = s[i * 4 + 13];
        if (chroma) {
            du[i >> 2] = s[i * 4 + 2];
            dv[i >> 2] = s[i * 4 + 3];
        }
    }
    if (i < w) {
        dy[i] = s[i * 4 + 1];
        if (chroma) {
            du[i >> 2] = s[i * 4 + 2];
            dv[i >> 2] = s[i * 4 + 3];
        }
        if (i + 1 < w) dy[i + 1] = s[i * 4 + 5];
        if (i + 2 < w) dy[i + 2] = s[i * 4 + 9];
    }
}

pub fn unpackIYU1(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y) + l.n(x) * 4;
    const d = l.bytes(dest);
    const w: usize = l.n(width);
    const yo = [4]usize{ 1, 2, 4, 5 };
    var i: usize = 0;
    while (i + 3 < w) : (i += 4) {
        const b = (i >> 2) * 6;
        inline for (0..4) |k| {
            d[(i + k) * 4] = 0xff;
            d[(i + k) * 4 + 1] = s[b + yo[k]];
            d[(i + k) * 4 + 2] = s[b];
            d[(i + k) * 4 + 3] = s[b + 3];
        }
    }
    if (i < w) {
        const b = (i >> 2) * 6;
        for (0..3) |k| {
            if (k > 0 and i + k >= w) break;
            d[(i + k) * 4] = 0xff;
            d[(i + k) * 4 + 1] = s[b + yo[k]];
            d[(i + k) * 4 + 2] = s[b];
            d[(i + k) * 4 + 3] = s[b + 3];
        }
    }
}

pub fn packIYU1(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.bytes(src);
    const w: usize = l.n(width);
    var i: usize = 0;
    while (i + 3 < w) : (i += 4) {
        const b = (i >> 2) * 6;
        d[b] = s[i * 4 + 2];
        d[b + 1] = s[i * 4 + 1];
        d[b + 2] = s[i * 4 + 5];
        d[b + 3] = s[i * 4 + 3];
        d[b + 4] = s[i * 4 + 9];
        d[b + 5] = s[i * 4 + 13];
    }
    if (i < w) {
        const b = (i >> 2) * 6;
        d[b + 1] = s[i * 4 + 1];
        d[b] = s[i * 4 + 2];
        d[b + 3] = s[i * 4 + 3];
        if (i + 1 < w) d[b + 2] = s[i * 4 + 5];
        if (i + 2 < w) d[b + 4] = s[i * 4 + 9];
    }
}
