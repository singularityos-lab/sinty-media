const c = @import("../c.zig").c;
const l = @import("line.zig");

const Info = l.Info;
const Flags = l.Flags;
const Data = l.Data;
const Out = l.DataOut;
const Stride = l.Stride;
const Site = c.GstVideoChromaSite;

fn rd(p: [*]const u8, be: bool) u16 {
    return if (be) l.rd16be(p) else l.rd16le(p);
}

fn wr(p: [*]u8, v: u16, be: bool) void {
    if (be) l.wr16be(p, v) else l.wr16le(p, v);
}

fn rep(v: u16, sh: u5, flags: Flags) u16 {
    if (flags & l.TRUNCATE != 0 or sh >= 16) return v;
    return v | (v >> @intCast(sh));
}

fn up(v: u16, bits: u5) u16 {
    return @truncate(@as(u32, v) << (16 - bits));
}

fn down(v: u16, bits: u5) u16 {
    return @truncate(@as(u32, v) >> (16 - bits));
}

fn depth(info: [*c]const Info) u5 {
    return @intCast(info[0].bits);
}

fn depth0(info: [*c]const Info) u5 {
    return @intCast(info[0].depth[0]);
}

fn y21xBe(info: [*c]const Info) bool {
    return info[0].format != c.GST_VIDEO_FORMAT_Y210 and isBe(info);
}

fn isBe(info: [*c]const Info) bool {
    return info[0].flags & c.GST_VIDEO_FORMAT_FLAG_LE == 0;
}

fn px(d: [*]align(1) u16, i: usize, a: u16, y: u16, u: u16, v: u16) void {
    d[i * 4] = a;
    d[i * 4 + 1] = y;
    d[i * 4 + 2] = u;
    d[i * 4 + 3] = v;
}

pub fn planar16(comptime hsub: bool, comptime v420: bool, comptime alpha: bool) type {
    return struct {
        pub fn unpack(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const bits = depth(info);
            const be = isBe(info);
            const uv = if (v420) l.uv420(y, flags) else y;
            const cx = if (hsub) l.n(x >> 1) else l.n(x);
            const sy = l.comp(info, data, stride, 0, y) + l.n(x) * 2;
            const su = l.comp(info, data, stride, 1, uv) + cx * 2;
            const sv = l.comp(info, data, stride, 2, uv) + cx * 2;
            const sa = if (alpha) l.comp(info, data, stride, 3, y) + l.n(x) * 2 else sy;
            const d = l.u16s(dest);
            var skew: usize = 0;
            var odd = hsub and x & 1 != 0;
            for (0..l.n(width)) |i| {
                const ci = if (hsub) (i >> 1) + skew else i;
                const a = if (alpha) rep(up(rd(sa + i * 2, be), bits), bits, flags) else 0xffff;
                px(d, i, a, rep(up(rd(sy + i * 2, be), bits), bits, flags), rep(up(rd(su + ci * 2, be), bits), bits, flags), rep(up(rd(sv + ci * 2, be), bits), bits, flags));
                if (odd) {
                    odd = false;
                    skew = 1;
                }
            }
        }

        pub fn pack(info: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const bits = depth(info);
            const be = isBe(info);
            const uv = if (v420) l.uv420(y, flags) else y;
            const dy = l.comp(info, data, stride, 0, y);
            const du = l.comp(info, data, stride, 1, uv);
            const dv = l.comp(info, data, stride, 2, uv);
            const da = l.comp(info, data, stride, 3, y);
            const s = l.u16s(src);
            if (!hsub) {
                for (0..l.n(width)) |i| {
                    if (alpha) wr(da + i * 2, down(s[i * 4], bits), be);
                    wr(dy + i * 2, down(s[i * 4 + 1], bits), be);
                    wr(du + i * 2, down(s[i * 4 + 2], bits), be);
                    wr(dv + i * 2, down(s[i * 4 + 3], bits), be);
                }
                return;
            }
            const chroma = if (v420) l.chroma420(y, flags) else true;
            if (!chroma) {
                for (0..l.n(width)) |i| {
                    if (alpha) wr(da + i * 2, down(s[i * 4], bits), be);
                    wr(dy + i * 2, down(s[i * 4 + 1], bits), be);
                }
                return;
            }
            var i: c.gint = 0;
            while (i < width - 1) : (i += 2) {
                const k = l.n(i);
                if (alpha) {
                    wr(da + k * 2, down(s[k * 4], bits), be);
                    wr(da + k * 2 + 2, down(s[k * 4 + 4], bits), be);
                }
                wr(dy + k * 2, down(s[k * 4 + 1], bits), be);
                wr(dy + k * 2 + 2, down(s[k * 4 + 5], bits), be);
                wr(du + (k >> 1) * 2, down(s[k * 4 + 2], bits), be);
                wr(dv + (k >> 1) * 2, down(s[k * 4 + 3], bits), be);
            }
            if (i == width - 1) {
                const k = l.n(i);
                if (alpha) wr(da + k * 2, down(s[k * 4], bits), be);
                wr(dy + k * 2, down(s[k * 4 + 1], bits), be);
                wr(du + (k >> 1) * 2, down(s[k * 4 + 2], bits), be);
                wr(dv + (k >> 1) * 2, down(s[k * 4 + 3], bits), be);
            }
        }
    };
}

pub const Y444_16 = planar16(false, false, false);
pub const I420_16 = planar16(true, true, false);
pub const I422_16 = planar16(true, false, false);
pub const A444_16 = planar16(false, false, true);
pub const A420_16 = planar16(true, true, true);
pub const A422_16 = planar16(true, false, true);
pub const GBR_16 = Y444_16;
pub const GBRA_16 = A444_16;

pub fn unpackA444(info: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const sy = l.comp(info, data, stride, 0, y) + l.n(x);
    const su = l.comp(info, data, stride, 1, y) + l.n(x);
    const sv = l.comp(info, data, stride, 2, y) + l.n(x);
    const sa = l.comp(info, data, stride, 3, y) + l.n(x);
    const d = l.bytes(dest);
    for (0..l.n(width)) |i| {
        d[i * 4] = sa[i];
        d[i * 4 + 1] = sy[i];
        d[i * 4 + 2] = su[i];
        d[i * 4 + 3] = sv[i];
    }
}

pub fn packA444(info: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const dy = l.comp(info, data, stride, 0, y);
    const du = l.comp(info, data, stride, 1, y);
    const dv = l.comp(info, data, stride, 2, y);
    const da = l.comp(info, data, stride, 3, y);
    const s = l.bytes(src);
    for (0..l.n(width)) |i| {
        da[i] = s[i * 4];
        dy[i] = s[i * 4 + 1];
        du[i] = s[i * 4 + 2];
        dv[i] = s[i * 4 + 3];
    }
}

pub fn unpackA422(info: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const sy = l.comp(info, data, stride, 0, y) + l.n(x);
    const su = l.comp(info, data, stride, 1, y) + l.n(x >> 1);
    const sv = l.comp(info, data, stride, 2, y) + l.n(x >> 1);
    const sa = l.comp(info, data, stride, 3, y) + l.n(x);
    const d = l.bytes(dest);
    var skew: usize = 0;
    var odd = x & 1 != 0;
    for (0..l.n(width)) |i| {
        d[i * 4] = sa[i];
        d[i * 4 + 1] = sy[i];
        d[i * 4 + 2] = su[(i >> 1) + skew];
        d[i * 4 + 3] = sv[(i >> 1) + skew];
        if (odd) {
            odd = false;
            skew = 1;
        }
    }
}

pub fn packA422(info: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const dy = l.comp(info, data, stride, 0, y);
    const du = l.comp(info, data, stride, 1, y);
    const dv = l.comp(info, data, stride, 2, y);
    const da = l.comp(info, data, stride, 3, y);
    const s = l.bytes(src);
    var i: c.gint = 0;
    while (i < width - 1) : (i += 2) {
        const k = l.n(i);
        da[k] = s[k * 4];
        dy[k] = s[k * 4 + 1];
        da[k + 1] = s[k * 4 + 4];
        dy[k + 1] = s[k * 4 + 5];
        du[k >> 1] = s[k * 4 + 2];
        dv[k >> 1] = s[k * 4 + 3];
    }
    if (i == width - 1) {
        const k = l.n(i);
        da[k] = s[k * 4];
        dy[k] = s[k * 4 + 1];
        du[k >> 1] = s[k * 4 + 2];
        dv[k >> 1] = s[k * 4 + 3];
    }
}

fn mask(bits: u5) u16 {
    return @truncate(@as(u32, 0xffff) << (16 - bits));
}

pub fn unpackP01x(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width_in: c.gint) callconv(.c) void {
    const bits = depth0(info);
    const be = isBe(info);
    const uv = l.uv420(y, flags);
    var sy = l.plane(data, stride, 0, y) + l.n(x) * 2;
    var suv = l.plane(data, stride, 1, uv) + l.n(x & ~@as(c.gint, 1)) * 2;
    var d = l.u16s(dest);
    var width = width_in;
    if (x & 1 != 0) {
        px(d, 0, 0xffff, rep(rd(sy, be), bits, flags), rep(rd(suv, be), bits, flags), rep(rd(suv + 2, be), bits, flags));
        width -= 1;
        d += 4;
        sy += 2;
        suv += 4;
    }
    for (0..l.n(@divTrunc(width, 2))) |i| {
        const u = rep(rd(suv + i * 4, be), bits, flags);
        const v = rep(rd(suv + i * 4 + 2, be), bits, flags);
        px(d, i * 2, 0xffff, rep(rd(sy + i * 4, be), bits, flags), u, v);
        px(d, i * 2 + 1, 0xffff, rep(rd(sy + i * 4 + 2, be), bits, flags), u, v);
    }
    if (width & 1 != 0) {
        const i = l.n(width - 1);
        px(d, i, 0xffff, rep(rd(sy + i * 2, be), bits, flags), rep(rd(suv + i * 2, be), bits, flags), rep(rd(suv + i * 2 + 2, be), bits, flags));
    }
}

pub fn packP01x(info: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const m = mask(depth0(info));
    const be = isBe(info);
    const uv = l.uv420(y, flags);
    const dy = l.plane(data, stride, 0, y);
    const duv = l.plane(data, stride, 1, uv);
    const s = l.u16s(src);
    if (!l.chroma420(y, flags)) {
        for (0..l.n(width)) |i| wr(dy + i * 2, s[i * 4 + 1] & m, be);
        return;
    }
    for (0..l.n(@divTrunc(width, 2))) |i| {
        wr(dy + i * 4, s[i * 8 + 1] & m, be);
        wr(dy + i * 4 + 2, s[i * 8 + 5] & m, be);
        wr(duv + i * 4, s[i * 8 + 2] & m, be);
        wr(duv + i * 4 + 2, s[i * 8 + 3] & m, be);
    }
    if (width & 1 != 0) {
        const i = l.n(width - 1);
        wr(dy + i * 2, s[i * 4 + 1] & m, be);
        wr(duv + i * 2, s[i * 4 + 2] & m, be);
        wr(duv + i * 2 + 2, s[i * 4 + 3] & m, be);
    }
}

pub fn unpackY21x(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width_in: c.gint) callconv(.c) void {
    const bits = depth0(info);
    const be = y21xBe(info);
    var s = l.plane(data, stride, 0, y) + l.n(x & ~@as(c.gint, 1)) * 4;
    var d = l.u16s(dest);
    var width = width_in;
    if (x & 1 != 0) {
        px(d, 0, 0xffff, rep(rd(s + 4, be), bits, flags), rep(rd(s + 2, be), bits, flags), rep(rd(s + 6, be), bits, flags));
        s += 8;
        d += 4;
        width -= 1;
    }
    for (0..l.n(@divTrunc(width, 2))) |i| {
        const u = rep(rd(s + i * 8 + 2, be), bits, flags);
        const v = rep(rd(s + i * 8 + 6, be), bits, flags);
        px(d, i * 2, 0xffff, rep(rd(s + i * 8, be), bits, flags), u, v);
        px(d, i * 2 + 1, 0xffff, rd(s + i * 8 + 4, be), u, v);
    }
    if (width & 1 != 0) {
        const i = l.n(width - 1);
        px(d, i, 0xffff, rep(rd(s + i * 4, be), bits, flags), rep(rd(s + i * 4 + 2, be), bits, flags), rep(rd(s + i * 4 + 6, be), bits, flags));
    }
}

pub fn packY21x(info: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const m = mask(depth0(info));
    const be = y21xBe(info);
    const d = l.plane(data, stride, 0, y);
    const s = l.u16s(src);
    var i: c.gint = 0;
    while (i < width) : (i += 2) {
        const k = l.n(i);
        const y1 = if (i == width - 1) s[k * 4 + 1] else s[(k + 1) * 4 + 1];
        wr(d + k * 4, s[k * 4 + 1] & m, be);
        wr(d + k * 4 + 2, s[k * 4 + 2] & m, be);
        wr(d + k * 4 + 4, y1 & m, be);
        wr(d + k * 4 + 6, s[k * 4 + 3] & m, be);
    }
}

pub fn unpackY41x(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const bits = depth0(info);
    const m = mask(bits);
    const be = isBe(info);
    const s = l.plane(data, stride, 0, y) + l.n(x) * 8;
    const d = l.u16s(dest);
    for (0..l.n(width)) |i| {
        const p = s + i * 8;
        px(d, i, rep(rd(p + 6, be) & m, bits, flags), rep(rd(p + 2, be) & m, bits, flags), rep(rd(p, be) & m, bits, flags), rep(rd(p + 4, be) & m, bits, flags));
    }
}

pub fn packY41x(info: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const m = mask(depth0(info));
    const be = isBe(info);
    const d = l.plane(data, stride, 0, y);
    const s = l.u16s(src);
    for (0..l.n(width)) |i| {
        const p = d + i * 8;
        wr(p, s[i * 4 + 2] & m, be);
        wr(p + 2, s[i * 4 + 1] & m, be);
        wr(p + 4, s[i * 4 + 3] & m, be);
        wr(p + 6, s[i * 4] & m, be);
    }
}

pub fn gray16(comptime be: bool) type {
    return struct {
        pub fn unpack(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const s = l.plane(data, stride, 0, y) + l.n(x) * 2;
            const d = l.u16s(dest);
            for (0..l.n(width)) |i| px(d, i, 0xffff, rd(s + i * 2, be), 0x8000, 0x8000);
        }
        pub fn pack(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const d = l.plane(data, stride, 0, y);
            const s = l.u16s(src);
            for (0..l.n(width)) |i| wr(d + i * 2, s[i * 4 + 1], be);
        }
    };
}

pub const GRAY16_BE = gray16(true);
pub const GRAY16_LE = gray16(false);

pub fn rgba64(comptime order: [4]usize, comptime be: bool) type {
    return struct {
        pub fn unpack(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const s = l.plane(data, stride, 0, y) + l.n(x) * 16;
            const d = l.u16s(dest);
            for (0..l.n(width)) |i| {
                inline for (0..4) |k| d[i * 4 + order[k]] = rd(s + i * 8 + k * 2, be);
            }
        }
        pub fn pack(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const d = l.plane(data, stride, 0, y);
            const s = l.u16s(src);
            for (0..l.n(width)) |i| {
                inline for (0..4) |k| wr(d + i * 8 + k * 2, s[i * 4 + order[k]], be);
            }
        }
    };
}

pub const ARGB64_swap = rgba64(.{ 0, 1, 2, 3 }, true);
pub const RGBA64_LE = rgba64(.{ 1, 2, 3, 0 }, false);
pub const RGBA64_BE = rgba64(.{ 1, 2, 3, 0 }, true);
pub const BGRA64_LE = rgba64(.{ 3, 2, 1, 0 }, false);
pub const BGRA64_BE = rgba64(.{ 3, 2, 1, 0 }, true);
pub const ABGR64_LE = rgba64(.{ 0, 3, 2, 1 }, false);
pub const ABGR64_BE = rgba64(.{ 0, 3, 2, 1 }, true);

pub fn unpackCopy8(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y) + l.n(x) * 8;
    @memcpy(l.bytes(dest)[0 .. l.n(width) * 8], s[0 .. l.n(width) * 8]);
}

pub fn packCopy8(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    @memcpy(d[0 .. l.n(width) * 8], l.bytes(src)[0 .. l.n(width) * 8]);
}

pub fn unpackR210(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y) + l.n(x) * 4;
    const d = l.u16s(dest);
    for (0..l.n(width)) |i| {
        const w = l.rd32be(s + i * 4);
        const r: u16 = @truncate((w >> 14) & 0xffc0);
        const g: u16 = @truncate((w >> 4) & 0xffc0);
        const b: u16 = @truncate((w << 6) & 0xffc0);
        px(d, i, 0xffff, rep(r, 10, flags), rep(g, 10, flags), rep(b, 10, flags));
    }
}

pub fn packR210(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.u16s(src);
    for (0..l.n(width)) |i| {
        const r: u32 = s[i * 4 + 1] & 0xffc0;
        const g: u32 = s[i * 4 + 2] & 0xffc0;
        const b: u32 = s[i * 4 + 3] & 0xffc0;
        l.wr32be(d + i * 4, r << 14 | g << 4 | b >> 6);
    }
}

pub fn packed2101010(comptime order: [3]usize) type {
    return struct {
        pub fn unpack(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const s = l.plane(data, stride, 0, y) + l.n(x) * 4;
            const d = l.u16s(dest);
            for (0..l.n(width)) |i| {
                const w = l.rd32le(s + i * 4);
                inline for (0..3) |k| {
                    const f: u16 = @truncate(((w >> (10 * k)) & 0x3ff) << 6);
                    d[i * 4 + order[k]] = rep(f, 10, flags);
                }
                const a: u16 = @truncate(((w >> 30) & 0x3) << 14);
                d[i * 4] = rep(a, 10, flags);
            }
        }
        pub fn pack(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const d = l.plane(data, stride, 0, y);
            const s = l.u16s(src);
            for (0..l.n(width)) |i| {
                const a: u32 = s[i * 4] & 0xc000;
                const f0: u32 = s[i * 4 + order[0]] & 0xffc0;
                const f1: u32 = s[i * 4 + order[1]] & 0xffc0;
                const f2: u32 = s[i * 4 + order[2]] & 0xffc0;
                l.wr32le(d + i * 4, f0 >> 6 | f1 << 4 | f2 << 14 | a << 16);
            }
        }
    };
}

pub const Y410 = packed2101010(.{ 2, 1, 3 });
pub const BGR10A2 = packed2101010(.{ 3, 2, 1 });
pub const RGB10A2 = packed2101010(.{ 1, 2, 3 });

fn f10(w: u32, k: u5) u16 {
    return @truncate(((w >> k) & 0x3ff) << 6);
}

pub fn unpackV210(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, _: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y);
    const d = l.u16s(dest);
    var i: c.gint = 0;
    while (i < width) : (i += 6) {
        const p = s + l.n(@divTrunc(i, 6)) * 16;
        const a0 = l.rd32le(p);
        const a1 = l.rd32le(p + 4);
        const a2 = l.rd32le(p + 8);
        const a3 = l.rd32le(p + 12);
        const v = [12]u16{ f10(a0, 0), f10(a0, 10), f10(a0, 20), f10(a1, 0), f10(a1, 10), f10(a1, 20), f10(a2, 0), f10(a2, 10), f10(a2, 20), f10(a3, 0), f10(a3, 10), f10(a3, 20) };
        var r: [12]u16 = undefined;
        for (v, 0..) |e, k| r[k] = rep(e, 10, flags);
        const ys = [6]usize{ 1, 3, 5, 7, 9, 11 };
        const us = [6]usize{ 0, 0, 4, 4, 8, 8 };
        const vs = [6]usize{ 2, 2, 6, 6, 10, 10 };
        const b = l.n(i);
        for (0..6) |k| {
            if (k > 0 and i >= width - @as(c.gint, @intCast(k))) break;
            px(d, b + k, 0xffff, r[ys[k]], r[us[k]], r[vs[k]]);
        }
    }
}

pub fn packV210(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.u16s(src);
    var i: c.gint = 0;
    while (i < width) : (i += 6) {
        const b = l.n(i);
        var yv = [6]u32{ 0, 0, 0, 0, 0, 0 };
        var uv = [3]u32{ 0, 0, 0 };
        var vv = [3]u32{ 0, 0, 0 };
        for (0..6) |k| {
            if (k > 0 and i >= width - @as(c.gint, @intCast(k))) break;
            yv[k] = s[(b + k) * 4 + 1] >> 6;
            if (k & 1 == 0) {
                uv[k >> 1] = s[(b + k) * 4 + 2] >> 6;
                vv[k >> 1] = s[(b + k) * 4 + 3] >> 6;
            }
        }
        const p = d + l.n(@divTrunc(i, 6)) * 16;
        l.wr32le(p, uv[0] | yv[0] << 10 | vv[0] << 20);
        l.wr32le(p + 4, yv[1] | uv[1] << 10 | yv[2] << 20);
        l.wr32le(p + 8, vv[1] | yv[3] << 10 | uv[2] << 20);
        l.wr32le(p + 12, yv[4] | vv[2] << 10 | yv[5] << 20);
    }
}

pub fn unpackV216(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width_in: c.gint) callconv(.c) void {
    var s = l.plane(data, stride, 0, y) + l.n(x & ~@as(c.gint, 1)) * 4;
    var d = l.u16s(dest);
    var width = width_in;
    if (x & 1 != 0) {
        px(d, 0, 0xffff, l.rd16le(s + 6), l.rd16le(s), l.rd16le(s + 4));
        s += 8;
        d += 4;
        width -= 1;
    }
    for (0..l.n(width)) |i| px(d, i, 0xffff, l.rd16le(s + i * 4 + 2), l.rd16le(s + (i >> 1) * 8), l.rd16le(s + (i >> 1) * 8 + 4));
}

pub fn packV216(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.u16s(src);
    var i: c.gint = 0;
    while (i < width - 1) : (i += 2) {
        const k = l.n(i);
        l.wr16le(d + k * 4, s[k * 4 + 2]);
        l.wr16le(d + k * 4 + 2, s[k * 4 + 1]);
        l.wr16le(d + k * 4 + 4, s[k * 4 + 3]);
        l.wr16le(d + k * 4 + 6, s[(k + 1) * 4 + 1]);
    }
    if (i == width - 1) {
        const k = l.n(i);
        l.wr16le(d + k * 4, s[k * 4 + 2]);
        l.wr16le(d + k * 4 + 2, s[k * 4 + 1]);
        l.wr16le(d + k * 4 + 4, s[k * 4 + 3]);
        l.wr16le(d + k * 4 + 6, s[k * 4 + 1]);
    }
}

pub fn unpackUYVP(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y) + l.n(x) * 2;
    const d = l.u16s(dest);
    var i: c.gint = 0;
    while (i < width) : (i += 2) {
        const k = l.n(i);
        const p = s + (k / 2) * 5;
        const b = [5]u16{ p[0], p[1], p[2], p[3], p[4] };
        const cu: u16 = (b[0] << 2 | b[1] >> 6) << 6;
        const y0: u16 = ((b[1] & 0x3f) << 4 | b[2] >> 4) << 6;
        const v0: u16 = ((b[2] & 0x0f) << 6 | b[3] >> 2) << 6;
        const y1: u16 = ((b[3] & 0x03) << 8 | b[4]) << 6;
        const u = rep(cu, 10, flags);
        const v = rep(v0, 10, flags);
        px(d, k, 0xffff, rep(y0, 10, flags), u, v);
        if (i < width - 1) px(d, k + 1, 0xffff, rep(y1, 10, flags), u, v);
    }
}

pub fn packUYVP(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.u16s(src);
    var i: c.gint = 0;
    while (i < width) : (i += 2) {
        const k = l.n(i);
        const y0 = s[k * 4 + 1];
        const y1 = if (i < width - 1) s[(k + 1) * 4 + 1] else y0;
        const cu = s[k * 4 + 2];
        const v0 = s[k * 4 + 3];
        const p = d + (k / 2) * 5;
        p[0] = @truncate(cu >> 8);
        p[1] = @truncate((cu & 0xc0) | y0 >> 10);
        p[2] = @truncate(((y0 & 0x3c0) >> 2) | v0 >> 12);
        p[3] = @truncate(((v0 & 0xfc0) >> 4) | y1 >> 14);
        p[4] = @truncate(y1 >> 6);
    }
}

pub fn unpackGRAY10_LE16(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const s = l.plane(data, stride, 0, y) + l.n(x) * 2;
    const d = l.u16s(dest);
    for (0..l.n(width)) |i| {
        const v = l.rd16le(s + i * 2);
        var g: u16 = v << 6;
        if (flags & l.TRUNCATE == 0) g |= (v & 0x3ff) >> 4;
        px(d, i, 0xffff, g, 0x8000, 0x8000);
    }
}

pub fn packGRAY10_LE16(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const d = l.plane(data, stride, 0, y);
    const s = l.u16s(src);
    for (0..l.n(width)) |i| l.wr16le(d + i * 2, s[i * 4 + 1] >> 6);
}

fn words(width: c.gint) usize {
    return l.n(@divTrunc(width + 2, 3));
}

fn comps(width: c.gint, i: usize) usize {
    return l.n(@min(3, width - @as(c.gint, @intCast(i * 3))));
}

pub fn unpackGRAY10_LE32(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    const sy = l.plane(data, stride, 0, y);
    const d = l.u16s(dest);
    for (0..words(width)) |i| {
        const pix = i * 3;
        var doff = pix * 4;
        var w = l.rd32le(sy + i * 4);
        for (0..comps(width, i)) |k| {
            var g: u16 = @truncate((w & 0x3ff) << 6);
            w >>= 10;
            if (pix + k < l.n(x)) continue;
            g = rep(g, 10, flags);
            d[doff] = 0xffff;
            d[doff + 1] = g;
            d[doff + 2] = 0x8000;
            d[doff + 3] = 0x8000;
            doff += 4;
        }
    }
}

pub fn packGRAY10_LE32(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
    const dy = l.plane(data, stride, 0, y);
    const s = l.u16s(src);
    for (0..words(width)) |i| {
        var soff = i * 3 * 4;
        var w: u32 = 0;
        for (0..comps(width, i)) |k| {
            w |= @as(u32, s[soff + 1] >> 6) << @intCast(10 * k);
            soff += 4;
        }
        l.wr32le(dy + i * 4, w);
    }
}

pub fn le32(comptime v420: bool) type {
    return struct {
        pub fn unpack(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const uv = if (v420) l.uv420(y, flags) else y;
            const sy = l.plane(data, stride, 0, y);
            const suv = l.plane(data, stride, 1, uv);
            const d = l.u16s(dest);
            var w_uv: u32 = 0;
            var un: u16 = 0;
            var vn: u16 = 0;
            for (0..words(width)) |i| {
                const pix = i * 3;
                var doff = pix * 4;
                var w = l.rd32le(sy + i * 4);
                for (0..comps(width, i)) |k| {
                    var yn: u16 = @truncate((w & 0x3ff) << 6);
                    w >>= 10;
                    switch ((pix + k) % 6) {
                        0, 4 => {
                            if ((pix + k) % 6 == 0) w_uv = l.rd32le(suv + i * 4);
                            un = @truncate((w_uv & 0x3ff) << 6);
                            w_uv >>= 10;
                            vn = @truncate((w_uv & 0x3ff) << 6);
                            w_uv >>= 10;
                        },
                        2 => {
                            un = @truncate((w_uv & 0x3ff) << 6);
                            w_uv = l.rd32le(suv + i * 4 + 4);
                            vn = @truncate((w_uv & 0x3ff) << 6);
                            w_uv >>= 10;
                        },
                        else => {},
                    }
                    if (pix + k < l.n(x)) continue;
                    if (flags & l.TRUNCATE == 0) {
                        yn |= yn >> 10;
                        un |= un >> 10;
                        vn |= vn >> 10;
                    }
                    px(d, doff / 4, 0xffff, yn, un, vn);
                    doff += 4;
                }
            }
        }

        pub fn pack(_: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const uv = if (v420) l.uv420(y, flags) else y;
            const chroma = if (v420) l.chroma420(y, flags) else true;
            const dy = l.plane(data, stride, 0, y);
            const duv = l.plane(data, stride, 1, uv);
            const s = l.u16s(src);
            var w_uv: u32 = 0;
            for (0..words(width)) |i| {
                const pix = i * 3;
                var soff = pix * 4;
                var w: u32 = 0;
                const n = comps(width, i);
                for (0..n) |k| {
                    w |= @as(u32, s[soff + 1] >> 6) << @intCast(10 * k);
                    if (chroma) {
                        const cu: u32 = s[soff + 2] >> 6;
                        const cv: u32 = s[soff + 3] >> 6;
                        switch ((pix + k) % 6) {
                            0 => w_uv = cu | cv << 10,
                            2 => {
                                w_uv |= cu << 20;
                                l.wr32le(duv + i * 4, w_uv);
                                w_uv = cv;
                            },
                            4 => {
                                w_uv |= cu << 10 | cv << 20;
                                l.wr32le(duv + i * 4, w_uv);
                            },
                            else => {},
                        }
                    }
                    soff += 4;
                }
                l.wr32le(dy + i * 4, w);
                if (chroma and n < 3) l.wr32le(duv + i * 4, w_uv);
            }
        }
    };
}

pub const NV12_10LE32 = le32(true);
pub const NV16_10LE32 = le32(false);

pub fn le40(comptime v420: bool) type {
    return struct {
        pub fn unpack(_: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, _: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            const uv = if (v420) l.uv420(y, flags) else y;
            var sy = l.plane(data, stride, 0, y);
            var suv = l.plane(data, stride, 1, uv);
            const d = l.u16s(dest);
            var y0: u16 = 0;
            var y1: u16 = 0;
            var yn: u16 = 0;
            var un: u16 = 0;
            var vn: u16 = 0;
            var w_uv: u32 = 0;
            for (0..l.n(width)) |i| {
                var upd = false;
                switch (i & 3) {
                    0 => {
                        y0 = l.rd16le(sy);
                        yn = y0 & 0x3ff;
                        sy += 2;
                        w_uv = l.rd32le(suv);
                        un = @truncate(w_uv & 0x3ff);
                        vn = @truncate((w_uv >> 10) & 0x3ff);
                        suv += 4;
                        yn <<= 6;
                        un <<= 6;
                        vn <<= 6;
                        upd = true;
                    },
                    1 => {
                        y1 = l.rd16le(sy);
                        yn = (y0 >> 10) | ((y1 & 0xf) << 6);
                        sy += 2;
                        yn <<= 6;
                    },
                    2 => {
                        yn = (y1 >> 4) & 0x3ff;
                        un = @truncate((w_uv >> 20) & 0x3ff);
                        vn = @truncate(w_uv >> 30);
                        w_uv = suv[0];
                        vn |= @truncate(w_uv << 2);
                        suv += 1;
                        yn <<= 6;
                        un <<= 6;
                        vn <<= 6;
                        upd = true;
                    },
                    else => {
                        y0 = sy[0];
                        yn = (y1 >> 14) | (y0 << 2);
                        sy += 1;
                        yn <<= 6;
                    },
                }
                if (flags & l.TRUNCATE == 0) {
                    yn |= yn >> 10;
                    if (upd) {
                        un |= un >> 10;
                        vn |= vn >> 10;
                    }
                }
                px(d, i, 0xffff, yn, un, vn);
            }
        }

        pub fn pack(_: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const uv = if (v420) l.uv420(y, flags) else y;
            const chroma = if (v420) l.chroma420(y, flags) else true;
            var dy = l.plane(data, stride, 0, y);
            var duv = l.plane(data, stride, 1, uv);
            const s = l.u16s(src);
            var y0: u16 = 0;
            var y1: u16 = 0;
            var y2: u16 = 0;
            var v0: u16 = 0;
            for (0..l.n(width)) |i| {
                const yv = s[i * 4 + 1] >> 6;
                switch (i & 3) {
                    0 => {
                        y0 = yv;
                        dy[0] = @truncate(y0);
                        dy += 1;
                        if (chroma) {
                            const u_0 = s[i * 4 + 2] >> 6;
                            v0 = s[i * 4 + 3] >> 6;
                            duv[0] = @truncate(u_0);
                            duv[1] = @truncate((u_0 >> 8) | ((v0 & 0x3f) << 2));
                            duv += 2;
                        }
                    },
                    1 => {
                        y1 = yv;
                        dy[0] = @truncate((y0 >> 8) | ((y1 & 0x3f) << 2));
                        dy += 1;
                    },
                    2 => {
                        y2 = yv;
                        dy[0] = @truncate((y1 >> 6) | ((y2 & 0xf) << 4));
                        dy += 1;
                        if (chroma) {
                            const u_1 = s[i * 4 + 2] >> 6;
                            const v_1 = s[i * 4 + 3] >> 6;
                            duv[0] = @truncate((v0 >> 6) | ((u_1 & 0xf) << 4));
                            duv[1] = @truncate((u_1 >> 4) | ((v_1 & 0x3) << 6));
                            duv[2] = @truncate(v_1 >> 2);
                            duv += 3;
                        }
                    },
                    else => {
                        dy[0] = @truncate((y2 >> 4) | ((yv & 0x3) << 6));
                        dy[1] = @truncate(yv >> 2);
                        dy += 2;
                    },
                }
            }
            switch (width & 3) {
                1 => {
                    dy[0] = @truncate(y0 >> 8);
                    if (chroma) duv[0] = @truncate(v0 >> 6);
                },
                2 => {
                    dy[0] = @truncate(y1 >> 6);
                    if (chroma) duv[0] = @truncate(v0 >> 6);
                },
                3 => dy[0] = @truncate(y2 >> 4),
                else => {},
            }
        }
    };
}

pub const NV12_10LE40 = le40(true);
pub const NV16_10LE40 = le40(false);
