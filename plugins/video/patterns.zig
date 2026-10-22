const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const libm = @import("../libm.zig");
const Src = @import("videotestsrc.zig").Self;

pub const Color = struct { y: u8 = 0, u: u8 = 0, v: u8 = 0, a: u8 = 0, r: u8 = 0, g: u8 = 0, b: u8 = 0 };

fn col(y: u8, u: u8, v: u8, a: u8, r: u8, g: u8, b: u8) Color {
    return .{ .y = y, .u = u, .v = v, .a = a, .r = r, .g = g, .b = b };
}

const WHITE = 0;
const YELLOW = 1;
const CYAN = 2;
const GREEN = 3;
const MAGENTA = 4;
const RED = 5;
const BLUE = 6;
const BLACK = 7;
const NEG_I = 8;
const POS_Q = 9;
const SUPER_BLACK = 10;
const DARK_GREY = 11;

const bt709_100 = [_]Color{
    col(235, 128, 128, 255, 255, 255, 255), col(219, 16, 138, 255, 255, 255, 0),
    col(188, 154, 16, 255, 0, 255, 255),    col(173, 42, 26, 255, 0, 255, 0),
    col(78, 214, 230, 255, 255, 0, 255),    col(63, 102, 240, 255, 255, 0, 0),
    col(32, 240, 118, 255, 0, 0, 255),      col(16, 128, 128, 255, 0, 0, 0),
    col(16, 198, 21, 255, 0, 0, 128),       col(16, 235, 198, 255, 0, 128, 255),
    col(0, 128, 128, 255, 0, 0, 0),         col(32, 128, 128, 255, 19, 19, 19),
};

const bt709_75 = [_]Color{
    col(180, 128, 128, 255, 191, 191, 191), col(168, 44, 136, 255, 191, 191, 0),
    col(145, 147, 44, 255, 0, 191, 191),    col(133, 63, 52, 255, 0, 191, 0),
    col(63, 193, 204, 255, 191, 0, 191),    col(51, 109, 212, 255, 191, 0, 0),
    col(28, 212, 120, 255, 0, 0, 191),      col(16, 128, 128, 255, 0, 0, 0),
    col(16, 198, 21, 255, 0, 0, 128),       col(16, 235, 198, 255, 0, 128, 255),
    col(0, 128, 128, 255, 0, 0, 0),         col(32, 128, 128, 255, 19, 19, 19),
};

const rp219 = [_]Color{
    col(104, 128, 128, 255, 102, 102, 102), col(180, 128, 128, 255, 191, 191, 191),
    col(168, 44, 136, 255, 190, 203, 8),    col(145, 147, 44, 255, 16, 211, 189),
    col(133, 63, 52, 255, 15, 223, 5),      col(63, 193, 204, 255, 176, 0, 186),
    col(51, 109, 212, 255, 175, 0, 2),      col(28, 212, 120, 255, 1, 0, 183),
    col(188, 154, 16, 255, 22, 255, 253),   col(235, 128, 128, 255, 255, 255, 255),
    col(61, 103, 157, 255, 99, 48, 15),     col(61, 153, 99, 255, 6, 66, 103),
    col(32, 240, 118, 255, 3, 0, 245),      col(219, 16, 138, 255, 252, 255, 10),
    col(16, 128, 128, 255, 0, 0, 0),        col(35, 174, 152, 255, 60, 0, 115),
    col(63, 102, 240, 255, 233, 0, 2),      col(49, 128, 128, 255, 38, 38, 38),
    col(1, 128, 128, 255, 0, 0, 0),         col(254, 128, 128, 255, 255, 255, 255),
    col(12, 128, 128, 255, 0, 0, 0),        col(20, 128, 128, 255, 5, 5, 5),
    col(25, 128, 128, 255, 10, 11, 10),
};

const bt601_100 = [_]Color{
    col(235, 128, 128, 255, 255, 255, 255), col(210, 16, 146, 255, 255, 255, 0),
    col(170, 166, 16, 255, 0, 255, 255),    col(145, 54, 34, 255, 0, 255, 0),
    col(106, 202, 222, 255, 255, 0, 255),   col(81, 90, 240, 255, 255, 0, 0),
    col(41, 240, 110, 255, 0, 0, 255),      col(16, 128, 128, 255, 0, 0, 0),
    col(16, 198, 21, 255, 0, 0, 128),       col(16, 235, 198, 255, 0, 128, 255),
    col(0, 128, 128, 255, 0, 0, 0),         col(32, 128, 128, 255, 19, 19, 19),
};

const bt601_75 = [_]Color{
    col(180, 128, 128, 255, 191, 191, 191), col(162, 44, 142, 255, 191, 191, 0),
    col(131, 156, 44, 255, 0, 191, 191),    col(112, 72, 58, 255, 0, 191, 0),
    col(84, 184, 198, 255, 191, 0, 191),    col(65, 100, 212, 255, 191, 0, 0),
    col(35, 212, 114, 255, 0, 0, 191),      col(16, 128, 128, 255, 0, 0, 0),
    col(16, 198, 21, 255, 0, 0, 128),       col(16, 235, 198, 255, 0, 128, 255),
    col(0, 128, 128, 255, 0, 0, 0),         col(32, 128, 128, 255, 19, 19, 19),
};

const sine = [256]u8{
    128, 131, 134, 137, 140, 143, 146, 149, 152, 156, 159, 162, 165, 168, 171, 174,
    176, 179, 182, 185, 188, 191, 193, 196, 199, 201, 204, 206, 209, 211, 213, 216,
    218, 220, 222, 224, 226, 228, 230, 232, 234, 236, 237, 239, 240, 242, 243, 245,
    246, 247, 248, 249, 250, 251, 252, 252, 253, 254, 254, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 254, 254, 253, 252, 252, 251, 250, 249, 248, 247,
    246, 245, 243, 242, 240, 239, 237, 236, 234, 232, 230, 228, 226, 224, 222, 220,
    218, 216, 213, 211, 209, 206, 204, 201, 199, 196, 193, 191, 188, 185, 182, 179,
    176, 174, 171, 168, 165, 162, 159, 156, 152, 149, 146, 143, 140, 137, 134, 131,
    128, 124, 121, 118, 115, 112, 109, 106, 103, 99,  96,  93,  90,  87,  84,  81,
    79,  76,  73,  70,  67,  64,  62,  59,  56,  54,  51,  49,  46,  44,  42,  39,
    37,  35,  33,  31,  29,  27,  25,  23,  21,  19,  18,  16,  15,  13,  12,  10,
    9,   8,   7,   6,   5,   4,   3,   3,   2,   1,   1,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   1,   1,   2,   3,   3,   4,   5,   6,   7,   8,
    9,   10,  12,  13,  15,  16,  18,  19,  21,  23,  25,  27,  29,  31,  33,  35,
    37,  39,  42,  44,  46,  49,  51,  54,  56,  59,  62,  64,  67,  70,  73,  76,
    79,  81,  84,  87,  90,  93,  96,  99,  103, 106, 109, 112, 115, 118, 121, 124,
};

fn fix(comptime x: f64) i32 {
    return @intFromFloat(x * 1024.0 + 0.5);
}

const Matrix = struct { y: [3]i32, u: [3]i32, v: [3]i32 };

const CCIR601 = Matrix{
    .y = .{ fix(0.29900 * 219.0 / 255.0), fix(0.58700 * 219.0 / 255.0), fix(0.11400 * 219.0 / 255.0) },
    .u = .{ fix(0.16874 * 224.0 / 255.0), fix(0.33126 * 224.0 / 255.0), fix(0.50000 * 224.0 / 255.0) },
    .v = .{ fix(0.50000 * 224.0 / 255.0), fix(0.41869 * 224.0 / 255.0), fix(0.08131 * 224.0 / 255.0) },
};

const CCIR709 = Matrix{
    .y = .{ fix(0.212600 * 219.0 / 255.0), fix(0.715200 * 219.0 / 255.0), fix(0.072200 * 219.0 / 255.0) },
    .u = .{ fix(0.114572 * 224.0 / 255.0), fix(0.385427 * 224.0 / 255.0), fix(0.50000 * 224.0 / 255.0) },
    .v = .{ fix(0.50000 * 224.0 / 255.0), fix(0.454153 * 224.0 / 255.0), fix(0.045847 * 224.0 / 255.0) },
};

fn argbColor(argb: u32, m: *const Matrix) Color {
    const a: i32 = @intCast((argb >> 24) & 0xff);
    const r: i32 = @intCast((argb >> 16) & 0xff);
    const g: i32 = @intCast((argb >> 8) & 0xff);
    const b: i32 = @intCast(argb & 0xff);
    const y = (m.y[0] * r + m.y[1] * g + m.y[2] * b + (512 + (16 << 10))) >> 10;
    const u = ((-m.u[0] * r - m.u[1] * g + m.u[2] * b + 512 - 1) >> 10) + 128;
    const v = ((m.v[0] * r - m.v[1] * g - m.v[2] * b + 512 - 1) >> 10) + 128;
    return .{ .a = @truncate(@as(u32, @bitCast(a))), .r = @truncate(@as(u32, @bitCast(r))), .g = @truncate(@as(u32, @bitCast(g))), .b = @truncate(@as(u32, @bitCast(b))), .y = @truncate(@as(u32, @bitCast(y))), .u = @truncate(@as(u32, @bitCast(u))), .v = @truncate(@as(u32, @bitCast(v))) };
}

const Mode = enum { generic, bayer8, bayer16 };

const Paint = struct {
    src: *Src,
    colors: []const Color,
    color: Color = .{},
    rgb: bool,
    mode: Mode,
    line: [*]u8,
    line2: [*]u8,
    mask: [*]u8,
    wide: [*]u16,
    n_lines: u32,
    offset: i32,
    lines: [*]?*anyopaque,
    x_offset: i32,
    bpp: i32,
    x_inv: i32,
    y_inv: i32,
    fg: Color,
    bg: Color,

    fn fill(p: *Paint, x: i32, w: i32) void {
        const k = p.color;
        const px = if (p.rgb) [4]u8{ k.a, k.r, k.g, k.b } else [4]u8{ k.a, k.y, k.u, k.v };
        var i: i32 = 0;
        while (i < w) : (i += 1) @memcpy(p.line[@intCast((x + i) * 4)..][0..4], &px);
    }

    fn pick(p: *Paint, i: usize) void {
        p.color = p.colors[i];
    }

    fn blend(p: *Paint, a: Color, b: Color, x1: i32, x2: i32) void {
        const pa = if (p.rgb) [4]u8{ a.a, a.r, a.g, a.b } else [4]u8{ a.a, a.y, a.u, a.v };
        const pb = if (p.rgb) [4]u8{ b.a, b.r, b.g, b.b } else [4]u8{ b.a, b.y, b.u, b.v };
        var i = x1;
        while (i < x2) : (i += 1) {
            const x: i32 = p.mask[@intCast(i)];
            for (0..4) |k| {
                const t = @as(i32, pa[k]) * x + @as(i32, pb[k]) * (255 - x);
                p.line[@as(usize, @intCast(i)) * 4 + k] = @truncate(@as(u32, @bitCast((t + ((t + 128) >> 8) + 128) >> 8)));
            }
        }
    }

    fn blendFg(p: *Paint, x1: i32, x2: i32) void {
        p.blend(p.fg, p.bg, x1, x2);
    }

    fn row(p: *Paint, frame: [*c]c.GstVideoFrame, j_in: i32) void {
        var j = j_in;
        const x = p.x_offset;
        const width = frame[0].info.width;
        const height = frame[0].info.height;
        const a = p.line;
        const b = p.line2;
        const wu: usize = @intCast(width);
        if (x != 0) {
            const xu: usize = @intCast(x);
            @memcpy(b[0 .. (wu - xu) * 4], a[xu * 4 .. wu * 4]);
            @memcpy(b[(wu - xu) * 4 .. wu * 4], a[0 .. xu * 4]);
            p.line = b;
            p.line2 = a;
        }
        var i: usize = wu;
        while (i < wu + 5) : (i += 1) {
            for (0..4) |k| p.line[4 * i + k] = p.line[4 * (wu - 1) + k];
        }
        p.convert(frame, j);
        if (j == height - 1) {
            const n: i32 = @intCast(p.n_lines);
            while (@rem(j, n) - p.offset != n - 1) {
                j += 1;
                p.convert(frame, j);
            }
        }
        if (x != 0) {
            p.line = a;
            p.line2 = b;
        }
    }

    fn convert(p: *Paint, frame: [*c]c.GstVideoFrame, y: i32) void {
        switch (p.mode) {
            .generic => p.generic(frame, y),
            .bayer8 => p.bayer8(frame, y),
            .bayer16 => p.bayer16(frame, y),
        }
    }

    fn generic(p: *Paint, frame: [*c]c.GstVideoFrame, y_in: i32) void {
        const finfo = frame[0].info.finfo;
        const uinfo = c.gst_video_format_get_info(finfo[0].unpack_format);
        const width = frame[0].info.width;
        const height = frame[0].info.height;
        const wu: usize = @intCast(width);
        const n = p.n_lines;
        const line: u32 = @as(u32, @bitCast(y_in)) % n;
        const dest: [*]u8 = @ptrCast(p.lines[line].?);
        if (uinfo[0].depth[0] == 16) {
            for (0..wu * 4) |k| p.wide[k] = @as(u16, p.line[k]) << 8 | p.line[k];
            @memcpy(dest[0 .. wu * 8], @as([*]const u8, @ptrCast(p.wide))[0 .. wu * 8]);
        } else @memcpy(dest[0 .. wu * 4], p.line[0 .. wu * 4]);
        if (@as(i64, line) - p.offset != @as(i64, n) - 1) return;
        const y = y_in -% @as(i32, @bitCast(n -% 1));
        var set: [8]?*anyopaque = undefined;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx: u32 = @intCast(std.math.clamp(y + @as(i32, @intCast(i)) + p.offset, 0, height - 1));
            set[i] = p.lines[idx % n];
        }
        if (p.src.subsample) |s| c.gst_video_chroma_resample(s, @ptrCast(&set), width);
        i = 0;
        while (i < n) : (i += 1) {
            const idx: u32 = @bitCast(y +% @as(i32, @intCast(i)) +% p.offset);
            if (idx > @as(u32, @bitCast(height - 1))) break;
            finfo[0].pack_func.?(finfo, c.GST_VIDEO_PACK_FLAG_NONE, set[i], 0, @ptrCast(&frame[0].data), @ptrCast(&frame[0].info.stride), frame[0].info.chroma_site, @bitCast(idx), width);
        }
    }

    fn bayerPos(p: *Paint, i: usize, y: i32) usize {
        const yo: usize = @intCast(1 - ((y ^ p.y_inv) & 1));
        const xo: usize = @intCast(2 - ((@as(i32, @intCast(i)) ^ p.x_inv) & 1));
        return 4 * i + yo + xo;
    }

    fn bayer8(p: *Paint, frame: [*c]c.GstVideoFrame, y: i32) void {
        const data: [*]u8 = @ptrCast(frame[0].data[0]);
        const r = data + @as(usize, @intCast(y * frame[0].info.stride[0]));
        for (0..@intCast(frame[0].info.width)) |i| r[i] = p.line[p.bayerPos(i, y)];
    }

    fn bayer16(p: *Paint, frame: [*c]c.GstVideoFrame, y: i32) void {
        const data: [*]u8 = @ptrCast(frame[0].data[0]);
        const r: [*]align(1) u16 = @ptrCast(data + @as(usize, @intCast(y * frame[0].info.stride[0])));
        const le = frame[0].info.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_LE != 0;
        const sh: u4 = @intCast(p.bpp - 8);
        const sl: u4 = @intCast(16 - p.bpp);
        for (0..@intCast(frame[0].info.width)) |i| {
            const v8: u16 = p.line[p.bayerPos(i, y)];
            const v = (v8 << sh) | (v8 >> sl);
            r[i] = if (le) v else @byteSwap(v);
        }
    }
};

fn setup(v: *Src) Paint {
    const info = &v.info;
    const bt601 = info.colorimetry.matrix == c.GST_VIDEO_COLOR_MATRIX_BT601;
    const m = if (bt601) &CCIR601 else &CCIR709;
    const width = info.width;
    var xo: i32 = @truncate(@rem(@as(i64, v.horizontal_speed) * v.n_frames, width));
    if (xo < 0) xo += width;
    return .{
        .src = v,
        .colors = if (bt601) &bt601_100 else &bt709_100,
        .rgb = v.bayer != 0 or info.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0,
        .mode = if (v.bayer == 0) .generic else if (v.bpp == 8) .bayer8 else .bayer16,
        .line = v.tmpline.?,
        .line2 = v.tmpline2.?,
        .mask = v.tmpline_u8.?,
        .wide = v.tmpline_u16.?,
        .n_lines = v.n_lines,
        .offset = v.offset,
        .lines = v.lines.?,
        .x_offset = xo,
        .bpp = v.bpp,
        .x_inv = v.x_invert,
        .y_inv = v.y_invert,
        .fg = argbColor(v.foreground_color, m),
        .bg = argbColor(v.background_color, m),
    };
}

fn random(state: *c.guint) u8 {
    state.* *%= 1103515245;
    state.* +%= 12345;
    return @truncate(state.* >> 16);
}

fn dims(frame: [*c]c.GstVideoFrame) [2]i32 {
    return .{ frame[0].info.width, frame[0].info.height };
}

fn bars(p: *Paint, w: i32) void {
    var i: i32 = 0;
    while (i < 7) : (i += 1) {
        const x1 = @divTrunc(i * w, 7);
        const x2 = @divTrunc((i + 1) * w, 7);
        p.pick(@intCast(i));
        p.fill(x1, x2 - x1);
    }
}

pub fn smpte(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    const w, const h = dims(frame);
    const y1 = @divTrunc(2 * h, 3);
    const y2 = @divTrunc(3 * h, 4);
    var j: i32 = 0;
    while (j < y1) : (j += 1) {
        bars(&p, w);
        p.row(frame, j);
    }
    while (j < y2) : (j += 1) {
        var i: i32 = 0;
        while (i < 7) : (i += 1) {
            const x1 = @divTrunc(i * w, 7);
            const x2 = @divTrunc((i + 1) * w, 7);
            p.pick(if (i & 1 != 0) 7 else @intCast(6 - i));
            p.fill(x1, x2 - x1);
        }
        p.row(frame, j);
    }
    while (j < h) : (j += 1) {
        var i: i32 = 0;
        while (i < 3) : (i += 1) {
            const x1 = @divTrunc(i * w, 6);
            const x2 = @divTrunc((i + 1) * w, 6);
            p.pick(switch (i) {
                0 => NEG_I,
                1 => WHITE,
                else => POS_Q,
            });
            p.fill(x1, x2 - x1);
        }
        i = 0;
        while (i < 3) : (i += 1) {
            const x1 = @divTrunc(w, 2) + @divTrunc(i * w, 12);
            const x2 = @divTrunc(w, 2) + @divTrunc((i + 1) * w, 12);
            p.pick(switch (i) {
                0 => SUPER_BLACK,
                1 => BLACK,
                else => DARK_GREY,
            });
            p.fill(x1, x2 - x1);
        }
        const x1 = @divTrunc(w * 3, 4);
        p.pick(BLACK);
        var k = x1;
        while (k < w) : (k += 1) p.mask[@intCast(k)] = random(&v.random_state);
        p.blendFg(x1, w);
        p.row(frame, j);
    }
}

pub fn smpteRp219(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    p.colors = &rp219;
    const a, const b = dims(frame);
    const b12_err = [6][6]i32{ .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 1, 0, 0, 0 }, .{ 0, 0, 0, 1, 1, 1 }, .{ 0, 1, 1, 1, 0, 1 }, .{ 0, 1, 1, 1, 1, 1 } };
    const b1 = @divTrunc(b, 2);
    const b2 = b - b1;
    var bs: [6]i32 = undefined;
    for (&bs, 0..) |*x, k| x.* = @divTrunc(b2, 6) + b12_err[@intCast(@rem(b2, 6))][k];
    const c_w_err = [7][7]i32{ .{ 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 1, 0, 0, 0 }, .{ 1, 0, 0, 0, 0, 0, 1 }, .{ 0, 1, 0, 1, 0, 1, 0 }, .{ 1, 0, 1, 0, 1, 0, 1 }, .{ 0, 1, 1, 1, 1, 1, 0 }, .{ 1, 1, 1, 0, 1, 1, 1 } };
    const i_err = [3][3]i32{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 0, 1 } };
    const d = @divTrunc(a, 8);
    const a34 = a - 2 * d;
    var cs: [7]i32 = undefined;
    for (&cs, 0..) |*x, k| x.* = @divTrunc(a34, 7) + c_w_err[@intCast(@rem(a34, 7))][k];
    const dkg = @divTrunc(a, 2);
    const hijmd = a - dkg;
    const kg = dkg - d;
    const g = cs[0] + cs[1];
    const k = kg - g;
    const k1 = @divTrunc(k, 2);
    const k2 = k - k1;
    const g1 = @divTrunc(g, 2);
    const g2 = g - g1;
    const hijm = hijmd - d;
    var ij: [5]i32 = undefined;
    for (0..3) |n| ij[n] = @divTrunc(cs[5], 3) + i_err[@intCast(@rem(cs[5], 3))][n];
    ij[3] = ij[1];
    ij[4] = ij[2];
    const m = cs[5];
    const h = hijm - ij[0] - ij[1] - ij[2] - ij[3] - ij[4] - m;
    var x: i32 = 0;
    const seg = struct {
        fn f(pp: *Paint, xx: *i32, len: i32, idx: usize) void {
            pp.pick(idx);
            pp.fill(xx.*, len);
            xx.* += len;
        }
    }.f;
    const ramp = struct {
        fn f(pp: *Paint, xx: *i32, len: i32, ca: usize, cb: usize) void {
            const x1 = xx.*;
            const x2 = x1 + len;
            var q = x1;
            while (q < x2) : (q += 1) pp.mask[@intCast(q)] = @truncate(@as(u32, @bitCast(@divTrunc(255 * (q - x1), x2 - x1))));
            pp.blend(pp.colors[ca], pp.colors[cb], x1, x2);
            xx.* = x2;
        }
    }.f;
    const rows = struct {
        fn f(pp: *Paint, fr: [*c]c.GstVideoFrame, y: *i32, n: i32) void {
            const end = y.* + n;
            while (y.* < end) : (y.* += 1) pp.row(fr, y.*);
        }
    }.f;
    seg(&p, &x, d, 0);
    for (0..7) |n| seg(&p, &x, cs[n], n + 1);
    seg(&p, &x, d, 0);
    var y: i32 = 0;
    rows(&p, frame, &y, b1 + bs[0]);
    x = 0;
    seg(&p, &x, d, 8);
    seg(&p, &x, cs[0], 11);
    seg(&p, &x, cs[1] + cs[2] + cs[3] + cs[4] + cs[5] + cs[6], 1);
    seg(&p, &x, d, 12);
    rows(&p, frame, &y, bs[1]);
    x = 0;
    seg(&p, &x, d, 13);
    seg(&p, &x, cs[0], 15);
    ramp(&p, &x, cs[1] + cs[2] + cs[3] + cs[4] + cs[5], 9, 14);
    seg(&p, &x, cs[6], 9);
    seg(&p, &x, d, 16);
    rows(&p, frame, &y, bs[2]);
    x = 0;
    seg(&p, &x, d, 17);
    seg(&p, &x, k, 14);
    seg(&p, &x, g, 9);
    seg(&p, &x, h, 14);
    seg(&p, &x, ij[0], 20);
    seg(&p, &x, ij[1], 14);
    seg(&p, &x, ij[2], 21);
    seg(&p, &x, ij[3], 20);
    seg(&p, &x, ij[4], 22);
    seg(&p, &x, m, 14);
    seg(&p, &x, d, 17);
    rows(&p, frame, &y, bs[3]);
    x = d;
    ramp(&p, &x, k1, 18, 14);
    ramp(&p, &x, k2, 14, 18);
    ramp(&p, &x, g1, 19, 9);
    ramp(&p, &x, g2, 9, 19);
    rows(&p, frame, &y, bs[4]);
    x = d;
    seg(&p, &x, k, 14);
    seg(&p, &x, g, 9);
    rows(&p, frame, &y, bs[5]);
}

pub fn smpte75(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    p.colors = if (v.info.colorimetry.matrix == c.GST_VIDEO_COLOR_MATRIX_BT601) &bt601_75 else &bt709_75;
    const w, const h = dims(frame);
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        bars(&p, w);
        p.row(frame, j);
    }
}

pub fn smpte100(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    const w, const h = dims(frame);
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        bars(&p, w);
        p.row(frame, j);
    }
}

pub fn bar(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    const w, const h = dims(frame);
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        const x2 = @divTrunc(w, 7);
        p.color = p.fg;
        p.fill(0, x2);
        p.color = p.bg;
        p.fill(x2, w - x2);
        p.row(frame, j);
    }
}

pub fn snow(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    const w, const h = dims(frame);
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        for (0..@intCast(w)) |i| p.mask[i] = random(&v.random_state);
        p.blendFg(0, w);
        p.row(frame, j);
    }
}

fn flat(p: *Paint, frame: [*c]c.GstVideoFrame) void {
    const w, const h = dims(frame);
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        p.fill(0, w);
        p.row(frame, j);
    }
}

fn unicolor(v: *Src, frame: [*c]c.GstVideoFrame, idx: usize) void {
    var p = setup(v);
    p.color = if (idx == BLACK) p.bg else if (idx == WHITE) p.fg else p.colors[idx];
    flat(&p, frame);
}

pub fn black(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    unicolor(v, frame, BLACK);
}

pub fn white(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    unicolor(v, frame, WHITE);
}

pub fn red(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    unicolor(v, frame, RED);
}

pub fn green(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    unicolor(v, frame, GREEN);
}

pub fn blue(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    unicolor(v, frame, BLUE);
}

pub fn blink(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    p.color = if (v.n_frames & 1 != 0) p.fg else p.bg;
    flat(&p, frame);
}

pub fn solid(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    p.color = p.fg;
    flat(&p, frame);
}

fn checkers(v: *Src, frame: [*c]c.GstVideoFrame, size: i32) void {
    var p = setup(v);
    const w, const h = dims(frame);
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += size) {
            p.pick(if ((x ^ y) & size != 0) GREEN else RED);
            p.fill(x, @min(size, w - x));
        }
        p.row(frame, y);
    }
}

pub fn checkers1(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    checkers(v, frame, 1);
}

pub fn checkers2(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    checkers(v, frame, 2);
}

pub fn checkers4(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    checkers(v, frame, 4);
}

pub fn checkers8(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    checkers(v, frame, 8);
}

const Zone = struct {
    t: i32,
    w: i32,
    h: i32,
    xreset: i32,
    yreset: i32,
    kt: i32,
    kt2: i32,
    dkxt: i32,
    skxy: i32,
    skx2: i32,
    ky: i32 = 0,
    kyt: i32 = 0,

    fn init(v: *Src, frame: [*c]c.GstVideoFrame) Zone {
        const w, const h = dims(frame);
        const t: i32 = @truncate(v.n_frames);
        return .{
            .t = t,
            .w = w,
            .h = h,
            .xreset = -@divTrunc(w, 2) -% v.xoffset,
            .yreset = -@divTrunc(h, 2) -% v.yoffset,
            .kt = v.kt *% t,
            .kt2 = v.kt2 *% t *% t,
            .dkxt = v.kxt *% t,
            .skxy = @divTrunc(0xffff, @divTrunc(w, 2)),
            .skx2 = @divTrunc(0xffff, w),
        };
    }

    fn line(z: *Zone, v: *Src, j: i32, out: anytype) void {
        const y = z.yreset +% j;
        var kx: i32 = 0;
        var kxt: i32 = 0;
        z.ky +%= v.ky;
        z.kyt +%= v.kyt *% z.t;
        const dkxy = v.kxy *% y *% z.skxy;
        var kxy = dkxy *% z.xreset;
        const ky2 = @divTrunc(v.ky2 *% y *% y, z.h);
        var i: i32 = 0;
        var x = z.xreset;
        while (i < z.w) : ({
            i += 1;
            x +%= 1;
        }) {
            var phase = v.k0;
            kx +%= v.kx;
            phase = phase +% kx +% z.ky +% z.kt;
            kxt +%= z.dkxt;
            kxy +%= dkxy;
            phase = phase +% kxt +% z.kyt;
            phase = phase +% (kxy >> 16);
            phase = phase +% ((v.kx2 *% x *% x *% z.skx2) >> 16) +% ky2 +% (z.kt2 >> 1);
            out.put(i, sine[@intCast(phase & 0xff)]);
        }
    }
};

pub fn zoneplate(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    var z = Zone.init(v, frame);
    const Out = struct {
        p: *Paint,
        fn put(o: @This(), i: i32, s: u8) void {
            o.p.mask[@intCast(i)] = s;
        }
    };
    var j: i32 = 0;
    while (j < z.h) : (j += 1) {
        z.line(v, j, Out{ .p = &p });
        p.blendFg(0, z.w);
        p.row(frame, j);
    }
}

pub fn chromazoneplate(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    var z = Zone.init(v, frame);
    const Out = struct {
        p: *Paint,
        fn put(o: @This(), i: i32, s: u8) void {
            o.p.color = .{ .y = 128, .u = s, .v = s, .a = o.p.color.a, .r = 128, .g = 128, .b = s };
            o.p.fill(i, 1);
        }
    };
    p.pick(BLACK);
    var j: i32 = 0;
    while (j < z.h) : (j += 1) {
        z.line(v, j, Out{ .p = &p });
        p.row(frame, j);
    }
}

pub fn circular(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    const w, const h = dims(frame);
    var freq: [8]f64 = undefined;
    var n: i32 = 1;
    while (n < 8) : (n += 1) freq[@intCast(n)] = 200 * libm.pow(2.0, @as(f64, @floatFromInt(-(n - 1))) / 4.0);
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        var i: i32 = 0;
        while (i < w) : (i += 1) {
            const sq = (2 * i - w) * (2 * i - w) + (2 * j - h) * (2 * j - h);
            const dist = @sqrt(@as(f64, @floatFromInt(sq))) / @as(f64, @floatFromInt(2 * w));
            const sg: i32 = @intFromFloat(@floor(dist * 16));
            if (sg == 0 or sg >= 8) {
                p.mask[@intCast(i)] = 0;
            } else {
                const d: i32 = @intFromFloat(@floor(256 * dist * freq[@intCast(sg)] + 0.5));
                p.mask[@intCast(i)] = sine[@intCast(d & 0xff)];
            }
        }
        p.blendFg(0, w);
        p.row(frame, j);
    }
}

pub fn gamut(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    const w, const h = dims(frame);
    var y: i32 = 0;
    var prim: Color = .{};
    var sec: Color = .{};
    while (y < h) : (y += 1) {
        switch (@divTrunc(y * 4, h)) {
            0 => {
                prim = p.colors[BLACK];
                sec = prim;
                sec.y = 0;
            },
            1 => {
                prim = p.colors[WHITE];
                sec = prim;
                sec.y = 255;
            },
            2 => {
                prim = p.colors[RED];
                sec = prim;
                sec.v = 255;
            },
            3 => {
                prim = p.colors[BLUE];
                sec = prim;
                sec.u = 255;
            },
            else => {},
        }
        var x: i32 = 0;
        while (x < w) : (x += 8) {
            p.color = if ((x ^ y) & 16 != 0) prim else sec;
            p.fill(x, @min(8, w - x));
        }
        p.row(frame, y);
    }
}

fn toInt(x: f64) i32 {
    return @intFromFloat(x);
}

pub fn ball(v: *Src, pts: u64, frame: [*c]c.GstVideoFrame) void {
    var radius: i32 = 20;
    const w, const h = dims(frame);
    var rad: f64 = 0;
    var flipit: i64 = 0;
    switch (v.animation_mode) {
        0 => {
            rad = @as(f64, @floatFromInt(v.n_frames)) / 200;
            flipit = @rem(@divTrunc(v.n_frames, 50), 2);
        },
        1 => {
            const wall = c.g_get_real_time();
            rad = @as(f64, @floatFromInt(wall)) / 1000000.0;
            flipit = @rem(@divTrunc(wall, 1000000), 2);
        },
        2 => {
            rad = @as(f64, @floatFromInt(pts)) / 1e9;
            flipit = @intCast((pts / 1_000_000_000) % 2);
        },
        else => {},
    }
    if (v.motion_type == 2) {
        rad /= 2;
        rad -= @floor(2 * rad) / 2;
    }
    rad = 2 * std.math.pi * rad;
    var x: f64 = 0;
    var y: f64 = 0;
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    if (v.motion_type == 0) {
        x = @as(f64, @floatFromInt(radius)) + (0.5 + 0.5 * libm.sin(rad)) * @as(f64, @floatFromInt(w - 2 * radius));
        y = @as(f64, @floatFromInt(radius)) + (0.5 + 0.5 * libm.sin(rad * std.math.sqrt2)) * @as(f64, @floatFromInt(h - 2 * radius));
    } else {
        radius = @divTrunc(@min(h, w), 4);
        x = @as(f64, @floatFromInt(@divTrunc(w, 2))) + libm.sin(rad) * @as(f64, @floatFromInt(radius));
        y = @as(f64, @floatFromInt(@divTrunc(h, 2))) - libm.cos(rad) * @as(f64, @floatFromInt(radius));
    }
    _ = fh;
    var p = setup(v);
    var fg = p.fg;
    var bg = p.bg;
    if (v.flip != 0 and flipit != 0) {
        fg = p.bg;
        bg = p.fg;
    }
    const fr: f64 = @floatFromInt(radius);
    const sweep = v.motion_type == 1 or v.motion_type == 2;
    var i: i32 = 0;
    while (i < h) : (i += 1) {
        const fi: f64 = @floatFromInt(i);
        if (fi < y - fr or fi > y + fr) {
            @memset(p.mask[0..@intCast(w)], 0);
        } else {
            const o = @max(0, fr * fr - (fi - y) * (fi - y));
            const r: i32 = toInt(libm.rint(@sqrt(o)));
            const fr2: f64 = @floatFromInt(r);
            var j: i32 = 0;
            var x2 = toInt(@max(0, x - fr2));
            while (j < x2) : (j += 1) p.mask[@intCast(j)] = 0;
            j = toInt(@max(0, x - fr2));
            x2 = toInt(@min(fw, x + fr2 + 1));
            while (j < x2) : (j += 1) {
                const fj: f64 = @floatFromInt(j);
                var rr = fr - @sqrt((fj - x) * (fj - x) + (fi - y) * (fi - y));
                rr *= 0.5;
                p.mask[@intCast(j)] = @intCast(std.math.clamp(toInt(@floor(256 * rr)), 0, 255));
            }
            j = toInt(@min(fw, x + fr2 + 1));
            while (j < w) : (j += 1) p.mask[@intCast(j)] = 0;
        }
        if (sweep) {
            p.mask[@intCast(@divTrunc(w, 2))] = 255;
            p.mask[@intCast(toInt(x))] = 255;
        }
        p.blend(fg, bg, 0, w);
        p.row(frame, i);
    }
    if (sweep) {
        @memset(p.mask[0..@intCast(w)], 255);
        p.blend(fg, bg, 0, w);
        p.row(frame, @divTrunc(h, 2));
        p.row(frame, toInt(y));
    }
}

fn wheel(v: *Src, frame: [*c]c.GstVideoFrame, comptime spokes_mode: bool) void {
    var p = setup(v);
    const w, const h = dims(frame);
    const t: i32 = @truncate(v.n_frames);
    var cs: [19]f64 = undefined;
    var sn: [19]f64 = undefined;
    for (0..19) |k| {
        const theta = std.math.pi / 19.0 * @as(f64, @floatFromInt(k)) + 0.001 * @as(f64, @floatFromInt(v.kt)) * @as(f64, @floatFromInt(t));
        cs[k] = libm.cos(theta);
        sn[k] = libm.sin(theta);
    }
    const hw = 0.5 * @as(f64, @floatFromInt(w));
    const hh = 0.5 * @as(f64, @floatFromInt(h));
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        var i: i32 = 0;
        while (i < w) : (i += 1) {
            var acc: f64 = 0;
            for (0..19) |k| {
                var x = cs[k] * (@as(f64, @floatFromInt(i)) - hw) + sn[k] * (@as(f64, @floatFromInt(j)) - hh);
                if (spokes_mode) {
                    x = 2.0 * 0.5 - @abs(x);
                    x *= 1.0;
                    acc += std.math.clamp(x + 0.5, 0.0, 1.0);
                } else {
                    x *= 1.0;
                    var yy = std.math.clamp(x, -1, 1);
                    if (k & 1 != 0) yy = -yy;
                    acc += yy;
                }
            }
            const val = if (spokes_mode) libm.rint(acc * 255) else libm.rint(acc * 128 + 128);
            p.mask[@intCast(i)] = @intFromFloat(std.math.clamp(val, 0, 255));
        }
        p.blendFg(0, w);
        p.row(frame, j);
    }
}

pub fn pinwheel(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    wheel(v, frame, false);
}

pub fn spokes(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    wheel(v, frame, true);
}

pub fn gradient(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    const w, const h = dims(frame);
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        const y: i32 = @intFromFloat(@as(f64, @floatFromInt(j)) * 255.0 / @as(f64, @floatFromInt(h)));
        @memset(p.mask[0..@intCast(w)], @truncate(@as(u32, @bitCast(y))));
        p.blendFg(0, w);
        p.row(frame, j);
    }
}

pub fn colors(v: *Src, _: u64, frame: [*c]c.GstVideoFrame) void {
    var p = setup(v);
    const w, const h = dims(frame);
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        var i: i32 = 0;
        while (i < w) : (i += 1) {
            const o: usize = @intCast(i * 4);
            p.line[o] = 0xff;
            p.line[o + 1] = @intCast(@rem(@divTrunc(i * 4096, w), 256));
            p.line[o + 2] = @truncate(@as(u32, @bitCast((@divTrunc(j * 16, h) << 4) | @divTrunc(i * 16, w))));
            p.line[o + 3] = @intCast(@rem(@divTrunc(j * 4096, h), 256));
        }
        p.row(frame, j);
    }
}
