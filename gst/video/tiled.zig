const c = @import("../c.zig").c;
const l = @import("line.zig");
const check = @import("check.zig");
const format = @import("format.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Info = l.Info;
const Flags = l.Flags;
const Data = l.Data;
const Out = l.DataOut;
const Stride = l.Stride;
const Site = c.GstVideoChromaSite;

fn xTiles(stride: c.gint) c.gint {
    return stride & 0xffff;
}

fn yTiles(stride: c.gint) c.gint {
    return stride >> 16;
}

pub fn tileIndex(mode: c.GstVideoTileMode, x: c.gint, y: c.gint, x_tiles: c.gint, y_tiles: c.gint) c.guint {
    if (!check.that(mode & 0xffff == c.GST_VIDEO_TILE_TYPE_INDEXED, "gst_video_tile_get_index", "GST_VIDEO_TILE_MODE_IS_INDEXED (mode)")) return 0;
    var off: c.gint = 0;
    switch (mode) {
        c.GST_VIDEO_TILE_MODE_ZFLIPZ_2X2 => {
            off = (y & ~@as(c.gint, 1)) * x_tiles + x;
            if (y & 1 != 0) {
                off += 2 + (x & ~@as(c.gint, 3));
            } else if (y_tiles & 1 == 0 or y != y_tiles - 1) {
                off += (x + 2) & ~@as(c.gint, 3);
            }
        },
        c.GST_VIDEO_TILE_MODE_LINEAR => off = y * x_tiles + x,
        else => {},
    }
    return @bitCast(off);
}

export fn gst_video_tile_get_index(mode: c.GstVideoTileMode, x: c.gint, y: c.gint, x_tiles: c.gint, y_tiles: c.gint) c.guint {
    return tileIndex(mode, x, y, x_tiles, y_tiles);
}

fn tileNV12(info: [*c]const Info, tx: c.gint, ty: c.gint, data: anytype, stride: Stride, tdata: *[4]c.gpointer, tstride: *[4]c.gint) void {
    const mode = info[0].tile_mode;
    const sub = info[0].flags & c.GST_VIDEO_FORMAT_FLAG_SUBTILES != 0;
    var off: usize = @as(usize, tileIndex(mode, tx, ty, xTiles(stride[0]), yTiles(stride[0]))) * info[0].tile_info[0].size;
    tdata[0] = l.offset(data[0], @intCast(off));
    off = @as(usize, tileIndex(mode, tx, if (sub) ty else @divTrunc(ty, 2), xTiles(stride[1]), yTiles(stride[1]))) * info[0].tile_info[1].size;
    if (!sub and ty & 1 != 0) off += info[0].tile_info[1].size / 2;
    tdata[1] = l.offset(data[1], @intCast(off));
    tstride[0] = @intCast(info[0].tile_info[0].stride);
    tstride[1] = @intCast(info[0].tile_info[1].stride);
}

fn pstride(info: [*c]const Info) usize {
    return if (info[0].unpack_format == c.GST_VIDEO_FORMAT_AYUV64) 8 else 4;
}

fn unpackTiled(inner: c.GstVideoFormat, info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x_in: c.gint, y_in: c.gint, width_in: c.gint) void {
    const tw: c.gint = @intCast(info[0].tile_info[0].width);
    const th: c.gint = @intCast(info[0].tile_info[0].height);
    const tile = format.get(inner);
    const ps = pstride(info);
    var line = l.bytes(dest);
    var tx = @divTrunc(x_in, tw);
    const ntx = @divTrunc(x_in + width_in - 1, tw) + 1;
    const ty = @divTrunc(y_in, th);
    const y = @rem(y_in, th);
    var x = @rem(x_in, tw);
    var width = width_in;
    while (tx < ntx) : (tx += 1) {
        var tdata: [4]c.gpointer = .{ null, null, null, null };
        var tstride: [4]c.gint = .{ 0, 0, 0, 0 };
        tileNV12(info, tx, ty, data, stride, &tdata, &tstride);
        const w = @min(width - x, tw - x);
        tile.*.unpack_func.?(tile, flags, line, &tdata, &tstride, x, y, w);
        x = 0;
        width -= w;
        line += l.n(w) * ps;
    }
}

fn packTiled(inner: c.GstVideoFormat, info: [*c]const Info, flags: Flags, src: c.gpointer, sstride: c.gint, data: Out, stride: Stride, site: Site, y_in: c.gint, width_in: c.gint) void {
    const tw: c.gint = @intCast(info[0].tile_info[0].width);
    const th: c.gint = @intCast(info[0].tile_info[0].height);
    const tile = format.get(inner);
    const ps = pstride(info);
    var line = l.bytes(src);
    const ntx = @divTrunc(width_in - 1, tw) + 1;
    const ty = @divTrunc(y_in, th);
    const y = @rem(y_in, th);
    var width = width_in;
    var tx: c.gint = 0;
    while (tx < ntx) : (tx += 1) {
        var tdata: [4]c.gpointer = .{ null, null, null, null };
        var tstride: [4]c.gint = .{ 0, 0, 0, 0 };
        tileNV12(info, tx, ty, data, stride, &tdata, &tstride);
        const w = @min(width, tw);
        tile.*.pack_func.?(tile, flags, line, sstride, &tdata, &tstride, site, y, w);
        width -= w;
        line += l.n(w) * ps;
    }
}

pub fn unpackNV12Tiled(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    unpackTiled(c.GST_VIDEO_FORMAT_NV12, info, flags, dest, data, stride, x, y, width);
}

pub fn packNV12Tiled(info: [*c]const Info, flags: Flags, src: c.gpointer, sstride: c.gint, data: Out, stride: Stride, site: Site, y: c.gint, width: c.gint) callconv(.c) void {
    packTiled(c.GST_VIDEO_FORMAT_NV12, info, flags, src, sstride, data, stride, site, y, width);
}

pub fn unpackLE40Tiled(info: [*c]const Info, flags: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
    unpackTiled(c.GST_VIDEO_FORMAT_NV12_10LE40, info, flags, dest, data, stride, x, y, width);
}

pub fn packLE40Tiled(info: [*c]const Info, flags: Flags, src: c.gpointer, sstride: c.gint, data: Out, stride: Stride, site: Site, y: c.gint, width: c.gint) callconv(.c) void {
    packTiled(c.GST_VIDEO_FORMAT_NV12_10LE40, info, flags, src, sstride, data, stride, site, y, width);
}

const Bits = struct { p: [2][*]u8, bits: [2]u4, mask: [2]u8 };

fn bitsAt(ty: c.gint, y: c.gint, x: c.gint, data: c.gpointer, stride: c.gint) Bits {
    const ws = 3;
    const ts = 10;
    const bit_index = 10 * x;
    const line_size = xTiles(stride) << ts;
    var pos: [2]c.gint = .{ @divTrunc(bit_index, 8), 0 };
    var b0 = 8 - @rem(bit_index, 8);
    if (b0 > 10) b0 = 10;
    const b1 = if (10 > b0) 10 - b0 else 0;
    if (b1 != 0) pos[1] = pos[0] + 1;
    var r: Bits = undefined;
    r.bits = .{ @intCast(b0), @intCast(b1) };
    r.mask = .{ @truncate((@as(c_uint, 1) << @intCast(b0)) - 1), @truncate((@as(c_uint, 1) << @intCast(b1)) - 1) };
    for (0..2) |i| {
        const off = line_size * ty + (1 << ts) * (pos[i] >> ws) + (1 << ws) * y + @rem(pos[i], 1 << ws);
        r.p[i] = l.offset(data, off);
    }
    return r;
}

fn getBits(b: Bits) u16 {
    const hi: u16 = b.p[0][0] & b.mask[0];
    const sh: u4 = 8 - b.bits[1];
    const lo: u16 = (@as(u16, b.p[1][0]) >> sh) & b.mask[1];
    return hi << b.bits[1] | lo;
}

fn setBits(b: Bits, v: u16) void {
    const sh: u4 = 8 - b.bits[1];
    b.p[0][0] = (b.p[0][0] & ~b.mask[0]) | (@as(u8, @truncate(v >> b.bits[1])) & b.mask[0]);
    if (sh < 8) {
        const m: u8 = b.mask[1] << @intCast(sh);
        b.p[1][0] = (b.p[1][0] & ~m) | ((@as(u8, @truncate(v)) & b.mask[1]) << @intCast(sh));
    }
}

pub fn unpack8L128(_: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y_in: c.gint, width: c.gint) callconv(.c) void {
    const ty = y_in >> 7;
    const y = y_in & 127;
    const uv_ty = ty >> 1;
    const uv_y = @divTrunc((@rem(ty, 2) << 7) + y, 2);
    const d = l.u16s(dest);
    var u: u16 = 0;
    var v: u16 = 0;
    for (0..l.n(width)) |i| {
        var j = x + @as(c.gint, @intCast(i));
        const yv = getBits(bitsAt(ty, y, j, data[0], stride[0]));
        if (i == 0 and @rem(j, 2) != 0) j -= 1;
        if (@rem(j, 2) == 0) {
            u = getBits(bitsAt(uv_ty, uv_y, j, data[1], stride[1]));
            v = getBits(bitsAt(uv_ty, uv_y, j + 1, data[1], stride[1]));
        }
        d[i * 4] = 0xffff;
        d[i * 4 + 1] = yv << 6;
        d[i * 4 + 2] = u << 6;
        d[i * 4 + 3] = v << 6;
    }
}

pub fn pack8L128(_: [*c]const Info, _: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y_in: c.gint, width: c.gint) callconv(.c) void {
    const ty = y_in >> 7;
    const y = y_in & 127;
    const uv_ty = ty >> 1;
    const uv_y = @divTrunc((@rem(ty, 2) << 7) + y, 2);
    const s = l.u16s(src);
    for (0..l.n(width)) |i| {
        const j: c.gint = @intCast(i);
        setBits(bitsAt(ty, y, j, data[0], stride[0]), s[i * 4 + 1] >> 6);
        if (@rem(y, 2) == 0 and i % 2 == 0) {
            setBits(bitsAt(uv_ty, uv_y, j, data[1], stride[1]), s[i * 4 + 2] >> 6);
            setBits(bitsAt(uv_ty, uv_y, j + 1, data[1], stride[1]), s[i * 4 + 3] >> 6);
        }
    }
}

const TILE = 640;

const Part = struct { ty: c.gint, luma: usize, chroma: usize, skip_luma: usize, skip_chroma: usize };

fn part(y: c.gint) Part {
    const tile_y = @rem(y, 32);
    const pl = @divTrunc(tile_y, 4);
    return .{ .ty = @divTrunc(y, 32), .luma = l.n(@rem(tile_y, 4)), .chroma = l.n(@rem(@divTrunc(tile_y, 2), 4)), .skip_luma = l.n(pl) * 80, .skip_chroma = l.n(@divTrunc(pl, 2)) * 80 };
}

fn tiles(info: [*c]const Info, data: anytype, stride: Stride, tx: c.gint, p: Part) [2][*]u8 {
    const yo = @as(usize, tileIndex(info[0].tile_mode, tx, p.ty, xTiles(stride[0]), yTiles(stride[0]))) * TILE;
    const uo = @as(usize, tileIndex(info[0].tile_mode, tx, p.ty, xTiles(stride[1]), yTiles(stride[1]))) * (TILE / 2);
    return .{ l.offset(data[0], @intCast(yo + p.skip_luma)), l.offset(data[1], @intCast(uo + p.skip_chroma)) };
}

fn mt2110(comptime raster: bool) type {
    return struct {
        pub fn unpack(info: [*c]const Info, _: Flags, dest: c.gpointer, data: Data, stride: Stride, x: c.gint, y: c.gint, width: c.gint) callconv(.c) void {
            if (x != 0) c.g_assertion_message_expr(check.DOMAIN, "../gst-libs/gst/video/video-format.c", if (raster) 7632 else 7482, if (raster) "unpack_MT2110R" else "unpack_MT2110T", "x == 0");
            const p = part(y);
            var d = l.u16s(dest);
            var tx: c.gint = 0;
            while (tx < @divTrunc(width, 16)) : (tx += 1) {
                const t = tiles(info, data, stride, tx, p);
                const yt = t[0];
                const ut = t[1];
                const num = l.n(@min(16, width - tx * 16));
                for (0..num) |k| {
                    const ky = if (raster) p.luma * 4 + k / 4 else k;
                    const ys: u3 = @intCast(if (raster) k % 4 * 2 else p.luma * 2);
                    const yv = @as(u16, yt[16 + p.luma * 16 + k]) << 2 | ((yt[ky] >> ys) & 3);
                    const k2 = k & ~@as(usize, 1);
                    const hi = p.chroma * 16 + k2;
                    var uv: u16 = undefined;
                    var vv: u16 = undefined;
                    if (raster) {
                        const ci = p.chroma * 4 + k / 4;
                        const cs: u3 = @intCast((k % 4 & ~@as(usize, 1)) * 2);
                        uv = @as(u16, ut[16 + hi]) << 2 | ((ut[ci] >> cs) & 3);
                        vv = @as(u16, ut[16 + hi + 1]) << 2 | ((ut[ci] >> (cs + 2)) & 3);
                    } else {
                        const cs: u3 = @intCast(p.chroma * 2);
                        uv = @as(u16, ut[16 + hi]) << 2 | ((ut[k2] >> cs) & 3);
                        vv = @as(u16, ut[16 + hi + 1]) << 2 | ((ut[k2 + 1] >> cs) & 3);
                    }
                    d[0] = 0xffff;
                    d[1] = yv << 6;
                    d[2] = uv << 6;
                    d[3] = vv << 6;
                    d += 4;
                }
            }
        }

        pub fn pack(info: [*c]const Info, flags: Flags, src: c.gpointer, _: c.gint, data: Out, stride: Stride, _: Site, y: c.gint, width: c.gint) callconv(.c) void {
            const p = part(y);
            const chroma = l.chroma420(y, flags);
            var s = l.u16s(src);
            var tx: c.gint = 0;
            while (tx < @divTrunc(width, 16)) : (tx += 1) {
                const t = tiles(info, data, stride, tx, p);
                const yt = t[0];
                const ut = t[1];
                const num = l.n(@min(16, width - tx * 16));
                for (0..num) |k| {
                    const yv = s[1] >> 6;
                    const uv = s[2] >> 6;
                    const vv = s[3] >> 6;
                    const ky = if (raster) p.luma * 4 + k / 4 else k;
                    const ys: u3 = @intCast(if (raster) k % 4 * 2 else p.luma * 2);
                    const ym: u8 = @as(u8, 3) << ys;
                    yt[ky] = (yt[ky] & ~ym) | (@as(u8, @truncate(yv & 3)) << ys);
                    yt[16 + p.luma * 16 + k] = @truncate(yv >> 2);
                    if (chroma and k & 1 == 0) {
                        const hi = p.chroma * 16 + k;
                        if (raster) {
                            const ci = p.chroma * 4 + k / 4;
                            const cs: u3 = @intCast((k % 4 & ~@as(usize, 1)) * 2);
                            const cm: u8 = @as(u8, 0x0f) << cs;
                            ut[ci] = (ut[ci] & ~cm) | (@as(u8, @truncate(uv & 3)) << cs) | (@as(u8, @truncate(vv & 3)) << (cs + 2));
                        } else {
                            const cs: u3 = @intCast(p.chroma * 2);
                            const cm: u8 = @as(u8, 3) << cs;
                            ut[k] = (ut[k] & ~cm) | (@as(u8, @truncate(uv & 3)) << cs);
                            ut[k + 1] = (ut[k + 1] & ~cm) | (@as(u8, @truncate(vv & 3)) << cs);
                        }
                        ut[16 + hi] = @truncate(uv >> 2);
                        ut[16 + hi + 1] = @truncate(vv >> 2);
                    }
                    s += 4;
                }
            }
        }
    };
}

pub const MT2110T = mt2110(false);
pub const MT2110R = mt2110(true);
