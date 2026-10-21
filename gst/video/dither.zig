const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Opaque = c.GstVideoDither;
const Func = *const fn (*Dither, [*]u8, c.guint, c.guint, c.guint) void;

const Dither = struct {
    method: c.GstVideoDitherMethod,
    flags: c.GstVideoDitherFlags,
    format: c.GstVideoFormat,
    width: c.guint,
    depth: c.guint,
    n_comp: c.guint,
    func: ?Func,
    shift: [4]u8,
    mask: [4]u16,
    errors: ?[*]u8,
};

fn of(p: ?*Opaque) *Dither {
    return @ptrCast(@alignCast(p.?));
}

fn u16s(p: anytype) [*]align(1) u16 {
    return @ptrCast(p);
}

fn errs(d: *Dither) [*]align(1) u16 {
    return u16s(d.errors.?);
}

fn sat8(v: i16) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn noneU8(d: *Dither, p: [*]u8, x: c.guint, _: c.guint, width: c.guint) void {
    const q = p + x * 4;
    for (0..width * 4) |i| q[i] &= ~@as(u8, @truncate(d.mask[i & 3]));
}

fn noneU16(d: *Dither, p: [*]u8, x: c.guint, _: c.guint, width: c.guint) void {
    const q = u16s(p) + x * 4;
    for (0..width * 4) |i| q[i] &= ~d.mask[i & 3];
}

fn verterrU8(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const e = errs(d) + x * 4;
    if (y == 0) @memset(@as([*]u8, @ptrCast(e))[0 .. width * 8], 0);
    const q = p + x * 4;
    for (0..width * 4) |i| {
        const m = d.mask[i & 3];
        const t: u16 = @as(u16, q[i]) +% e[i];
        e[i] = m & t;
        q[i] = sat8(@bitCast(~m & t));
    }
}

fn verterrU16(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const e = errs(d);
    if (y == 0) @memset(@as([*]u8, @ptrCast(e + x * 4))[0 .. width * 8], 0);
    const q = u16s(p);
    var i: usize = x * 4;
    while (i < (width + x) * 4) : (i += 1) {
        const mp: u32 = d.mask[i & 3];
        var v: u32 = @as(u32, q[i]) + e[i];
        e[i] = @truncate(v & mp);
        v &= ~mp;
        q[i] = @truncate(@min(v, 65535));
    }
}

fn fsU8(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const e = errs(d);
    if (y == 0) @memset(@as([*]u8, @ptrCast(e + x * 4))[0 .. (width + 1) * 8], 0);
    const ex = e + x * 4;
    for (0..width * 4) |i| ex[i] = ex[i] +% 5 *% ex[i + 4] +% 3 *% ex[i + 8];
    var i: usize = x * 4;
    while (i < (width + x) * 4) : (i += 1) {
        const mp = d.mask[i & 3];
        var v: u16 = @truncate(@as(u32, p[i]) + ((7 * @as(u32, e[i]) + e[i + 4]) >> 4));
        e[i + 4] = v & mp;
        v &= ~mp;
        p[i] = @truncate(@min(v, 255));
    }
}

fn fsU16(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const e = errs(d);
    if (y == 0) @memset(@as([*]u8, @ptrCast(e + x * 4))[0 .. (width + 1) * 8], 0);
    const q = u16s(p);
    var i: usize = x * 4;
    while (i < (width + x) * 4) : (i += 1) {
        const mp: u32 = d.mask[i & 3];
        var v: u32 = @as(u32, q[i]) + ((7 * @as(u32, e[i]) + e[i + 4] + 5 * @as(u32, e[i + 8]) + 3 * @as(u32, e[i + 12])) >> 4);
        e[i + 4] = @truncate(v & mp);
        v &= ~mp;
        q[i] = @truncate(@min(v, 65535));
    }
}

fn sierraU8(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const e = errs(d);
    if (y == 0) @memset(@as([*]u8, @ptrCast(e + x * 4))[0 .. (width + 4) * 8], 0);
    var i: usize = x;
    while (i < (width + x) * 4) : (i += 1) {
        const mp = d.mask[i & 3];
        var v: u16 = @truncate(@as(u32, p[i]) + ((2 * @as(u32, e[i]) + e[i + 8] + e[i + 12]) >> 2));
        e[i + 4] = v & mp;
        v &= ~mp;
        p[i] = @truncate(@min(v, 255));
    }
}

fn sierraU16(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const e = errs(d);
    if (y == 0) @memset(@as([*]u8, @ptrCast(e + x * 4))[0 .. (width + 4) * 8], 0);
    const q = u16s(p);
    var i: usize = x;
    while (i < (width + x) * 4) : (i += 1) {
        const mp: u32 = d.mask[i & 3];
        var v: u32 = @as(u32, q[i]) + ((2 * @as(u32, e[i]) + e[i + 8] + e[i + 12]) >> 2);
        e[i + 4] = @truncate(v & mp);
        v &= ~mp;
        q[i] = @truncate(@min(v & ~mp, 65535));
    }
}

const bayer = [16][16]u16{
    .{ 0, 128, 32, 160, 8, 136, 40, 168, 2, 130, 34, 162, 10, 138, 42, 170 },
    .{ 192, 64, 224, 96, 200, 72, 232, 104, 194, 66, 226, 98, 202, 74, 234, 106 },
    .{ 48, 176, 16, 144, 56, 184, 24, 152, 50, 178, 18, 146, 58, 186, 26, 154 },
    .{ 240, 112, 208, 80, 248, 120, 216, 88, 242, 114, 210, 82, 250, 122, 218, 90 },
    .{ 12, 240, 44, 172, 4, 132, 36, 164, 14, 242, 46, 174, 6, 134, 38, 166 },
    .{ 204, 76, 236, 108, 196, 68, 228, 100, 206, 78, 238, 110, 198, 70, 230, 102 },
    .{ 60, 188, 28, 156, 52, 180, 20, 148, 62, 190, 30, 158, 54, 182, 22, 150 },
    .{ 252, 142, 220, 92, 244, 116, 212, 84, 254, 144, 222, 94, 246, 118, 214, 86 },
    .{ 3, 131, 35, 163, 11, 139, 43, 171, 1, 129, 33, 161, 9, 137, 41, 169 },
    .{ 195, 67, 227, 99, 203, 75, 235, 107, 193, 65, 225, 97, 201, 73, 233, 105 },
    .{ 51, 179, 19, 147, 59, 187, 27, 155, 49, 177, 17, 145, 57, 185, 25, 153 },
    .{ 243, 115, 211, 83, 251, 123, 219, 91, 241, 113, 209, 81, 249, 121, 217, 89 },
    .{ 15, 243, 47, 175, 7, 135, 39, 167, 13, 241, 45, 173, 5, 133, 37, 165 },
    .{ 207, 79, 239, 111, 199, 71, 231, 103, 205, 77, 237, 109, 197, 69, 229, 101 },
    .{ 63, 191, 31, 159, 55, 183, 23, 151, 61, 189, 29, 157, 53, 181, 21, 149 },
    .{ 255, 145, 223, 95, 247, 119, 215, 87, 253, 143, 221, 93, 245, 117, 213, 85 },
};

fn orderedU8(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const cc = d.errors.? + ((y & 15) * width + (x & 15)) * 4;
    for (0..width * 4) |i| p[i] +|= cc[i];
}

fn orderedU8Mask(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const cc = errs(d) + ((y & 15) * width + (x & 15)) * 4;
    for (0..width * 4) |i| {
        const v: u16 = @as(u16, p[i]) +% cc[i];
        p[i] = sat8(@bitCast(~d.mask[i & 3] & v));
    }
}

fn orderedU16(d: *Dither, p: [*]u8, x: c.guint, y: c.guint, width: c.guint) void {
    const cc = errs(d) + ((y & 15) * width + (x & 15)) * 4;
    const q = u16s(p);
    for (0..width * 4) |i| q[i] = ~d.mask[i & 3] & (q[i] +| cc[i]);
}

fn allocErrors(d: *Dither, lines: c.guint) void {
    d.errors = @ptrCast(c.g_malloc0(@sizeOf(u16) * (d.width + 8) * d.n_comp * lines));
}

fn setupBayer(d: *Dither) void {
    var errdepth: c.guint = 16;
    if (d.depth == 8) {
        if (d.flags & c.GST_VIDEO_DITHER_FLAG_QUANTIZE != 0) {
            d.func = orderedU8Mask;
        } else {
            d.func = orderedU8;
            errdepth = 8;
        }
    } else d.func = orderedU16;
    allocErrors(d, 16);
    const w = d.width;
    const n = d.n_comp;
    for (0..16) |i| {
        for (0..w) |j| {
            for (0..n) |k| {
                var v: u16 = bayer[i & 15][j & 15];
                if (d.shift[k] < 8) v = v >> @intCast(8 - d.shift[k]);
                if (errdepth == 8) {
                    (d.errors.? + n * w * i)[n * j + k] = @truncate(v);
                } else (errs(d) + n * w * i)[n * j + k] = v;
            }
        }
    }
}

fn countPower(v_in: c.guint) u8 {
    var v = v_in;
    var r: u8 = 0;
    while (v > 1) : (v >>= 1) r += 1;
    return r;
}

pub export fn gst_video_dither_new(method: c.GstVideoDitherMethod, flags: c.GstVideoDitherFlags, format: c.GstVideoFormat, quantizer: [*c]c.guint, width: c.guint) ?*Opaque {
    const d: *Dither = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Dither))));
    d.method = method;
    d.flags = flags;
    d.format = format;
    d.width = width;
    d.n_comp = 4;
    switch (format) {
        c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_ARGB => d.depth = 8,
        c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_ARGB64 => d.depth = 16,
        else => {
            c.g_free(d);
            c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", "../gst-libs/gst/video/video-dither.c", @as(c_int, 402), "gst_video_dither_new");
            return null;
        },
    }
    for (0..4) |i| {
        const q = quantizer[(i + 3) & 3];
        d.shift[i] = countPower(q);
        d.mask[i] = @truncate((@as(u32, 1) << @intCast(d.shift[i])) - 1);
    }
    switch (method) {
        c.GST_VIDEO_DITHER_NONE => d.func = if (d.flags & c.GST_VIDEO_DITHER_FLAG_QUANTIZE != 0) (if (d.depth == 8) noneU8 else noneU16) else null,
        c.GST_VIDEO_DITHER_VERTERR => {
            allocErrors(d, 1);
            d.func = if (d.depth == 8) verterrU8 else verterrU16;
        },
        c.GST_VIDEO_DITHER_FLOYD_STEINBERG => {
            allocErrors(d, 1);
            d.func = if (d.depth == 8) fsU8 else fsU16;
        },
        c.GST_VIDEO_DITHER_SIERRA_LITE => {
            allocErrors(d, 1);
            d.func = if (d.depth == 8) sierraU8 else sierraU16;
        },
        c.GST_VIDEO_DITHER_BAYER => setupBayer(d),
        else => {},
    }
    return @ptrCast(d);
}

pub export fn gst_video_dither_free(dither: ?*Opaque) void {
    if (!check.that(dither != null, "gst_video_dither_free", "dither != NULL")) return;
    const d = of(dither);
    c.g_free(d.errors);
    c.g_free(d);
}

pub export fn gst_video_dither_line(dither: ?*Opaque, line: c.gpointer, x: c.guint, y: c.guint, width: c.guint) void {
    const fname = "gst_video_dither_line";
    if (!check.that(dither != null, fname, "dither != NULL")) return;
    const d = of(dither);
    if (!check.that(x +% width <= d.width, fname, "x + width <= dither->width")) return;
    if (d.func) |f| f(d, @ptrCast(line), x, y, width);
}
