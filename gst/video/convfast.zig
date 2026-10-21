const std = @import("std");
const c = @import("../c.zig").c;
const cv = @import("converter.zig");
const ln = @import("line.zig");
const format = @import("format.zig");
const color = @import("color.zig");
const scaler = @import("scaler.zig");

const Frame = cv.Frame;
const Conv = cv.Converter;
const Fn = cv.ConvFn;
const FInfo = c.GstVideoFormatInfo;

const KI: u8 = 0x80;
const CM: u8 = 0x40;
const KS: u8 = 0x20;
const CROP: u8 = 0x10;
const BORDER: u8 = 0x08;
const ACOPY: u8 = 0x04;
const ASET: u8 = 0x02;
const AMULT: u8 = 0x01;

const Xf = struct { in: c.GstVideoFormat, out: c.GstVideoFormat, flags: u8, wa: c.gint, ha: c.gint, f: Fn };

fn xf(comptime in: []const u8, comptime out: []const u8, flags: u8, wa: c.gint, ha: c.gint, f: Fn) Xf {
    return .{ .in = @field(c, "GST_VIDEO_FORMAT_" ++ in), .out = @field(c, "GST_VIDEO_FORMAT_" ++ out), .flags = flags, .wa = wa, .ha = ha, .f = f };
}

var dummy: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };

fn at(p: [*]u8, off: isize) [*]u8 {
    return ln.offset(p, off);
}

fn cnt(v: anytype) usize {
    return if (v > 0) @intCast(v) else 0;
}

fn up2(v: c.gint) c.gint {
    return (v + 1) & ~@as(c.gint, 1);
}

fn pl(f: *const Frame, p: usize, line: c.gint) [*]u8 {
    return cv.planeLine(f, p, line);
}

fn cl(f: *const Frame, k: usize, line: c.gint) [*]u8 {
    return cv.compLine(f, k, line);
}

fn ps(f: *const Frame, p: usize) isize {
    return f.info.stride[p];
}

fn cs(f: *const Frame, k: usize) isize {
    return f.info.stride[f.info.finfo[0].plane[k]];
}

fn row(p: [*]u8, s: isize, r: usize) [*]u8 {
    return at(p, s * @as(isize, @intCast(r)));
}

fn avg(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + b + 1) >> 1);
}

fn alpha8(conv: *Conv) u8 {
    return @intCast(@min(conv.alpha_value, 255));
}

fn keys(conv: *Conv) [5]i16 {
    return cv.ayuvKeys(&conv.convert_matrix);
}

fn sw(fi: [*c]const FInfo, k: usize, w: c.gint) c.gint {
    return -((-w) >> @intCast(fi[0].w_sub[k]));
}

fn sh(fi: [*c]const FInfo, k: usize, h: c.gint) c.gint {
    return -((-h) >> @intCast(fi[0].h_sub[k]));
}

fn renew(conv: *Conv, k: usize, comptime T: type, n: usize) struct { [*]T, [*]c.gpointer } {
    const t: [*]T = @ptrCast(@alignCast(c.g_realloc(conv.tasks[k], @sizeOf(T) * n)));
    conv.tasks[k] = t;
    const tp: [*]c.gpointer = @ptrCast(@alignCast(c.g_realloc(conv.tasks_p[k], @sizeOf(c.gpointer) * n)));
    conv.tasks_p[k] = @ptrCast(tp);
    for (0..n) |i| tp[i] = &t[i];
    return .{ t, tp };
}

fn Wrap(comptime T: type, comptime k: fn (*T) void) type {
    return struct {
        fn f(p: c.gpointer) void {
            k(@ptrCast(@alignCast(p)));
        }
    };
}

fn lpt(conv: *Conv, h: c.gint, round2: bool) c.gint {
    const n: c.gint = @intCast(cv.nThreads(conv));
    const l = @divTrunc(h + n - 1, n);
    return if (round2) up2(l) else l;
}

const PTask = struct {
    s: [*]u8 = &dummy,
    s2: [*]u8 = &dummy,
    su: [*]u8 = &dummy,
    sv: [*]u8 = &dummy,
    d: [*]u8 = &dummy,
    d2: [*]u8 = &dummy,
    du: [*]u8 = &dummy,
    dv: [*]u8 = &dummy,
    ss: isize = 0,
    sus: isize = 0,
    svs: isize = 0,
    ds: isize = 0,
    dus: isize = 0,
    dvs: isize = 0,
    w: c.gint = 0,
    h: c.gint = 0,
    alpha: u8 = 0,
    k: [5]i16 = .{ 0, 0, 0, 0, 0 },
};

fn runPlanes(conv: *Conv, base: PTask, height: c.gint, round2: bool, half: bool, comptime k: fn (*PTask) void) void {
    const n = cv.nThreads(conv);
    const l = lpt(conv, height, round2);
    const ts, const tp = renew(conv, 0, PTask, n);
    for (0..n) |i| {
        const o: isize = @as(isize, @intCast(i)) * l;
        var t = base;
        t.d = at(base.d, o * base.ds);
        t.d2 = at(base.d2, o * base.ds);
        t.du = at(base.du, if (half) @divTrunc(o * base.dus, 2) else o * base.dus);
        t.dv = at(base.dv, if (half) @divTrunc(o * base.dvs, 2) else o * base.dvs);
        t.s = at(base.s, o * base.ss);
        t.s2 = at(base.s2, o * base.ss);
        t.su = at(base.su, o * base.sus);
        t.sv = at(base.sv, o * base.svs);
        t.h = @min(@as(c.gint, @intCast(i + 1)) * l, height) - @as(c.gint, @intCast(o));
        ts[i] = t;
    }
    cv.runnerRun(conv.runner.?, Wrap(PTask, k).f, tp);
}

const Lay = enum { p422, p444, pl422, pl444 };

fn place(t: *PTask, f: *const Frame, comptime l: Lay, x: c.gint, y: c.gint, src: bool) void {
    var a: [*]u8 = undefined;
    var b: [*]u8 = &dummy;
    var bb: [*]u8 = &dummy;
    var sa: isize = 0;
    var sb: isize = 0;
    var sc: isize = 0;
    switch (l) {
        .p422 => {
            a = at(pl(f, 0, y), up2(x) * 2);
            sa = ps(f, 0);
        },
        .p444 => {
            a = at(pl(f, 0, y), x * 4);
            sa = ps(f, 0);
        },
        .pl422, .pl444 => {
            const cx = if (l == .pl422) x >> 1 else x;
            a = at(cl(f, 0, y), x);
            b = at(cl(f, 1, y), cx);
            bb = at(cl(f, 2, y), cx);
            sa = cs(f, 0);
            sb = cs(f, 1);
            sc = cs(f, 2);
        },
    }
    if (src) {
        t.s = a;
        t.su = b;
        t.sv = bb;
        t.ss = sa;
        t.sus = sb;
        t.svs = sc;
    } else {
        t.d = a;
        t.du = b;
        t.dv = bb;
        t.ds = sa;
        t.dus = sb;
        t.dvs = sc;
    }
}

fn plane2d(comptime sl: Lay, comptime dl: Lay, comptime k: fn (*PTask) void) Fn {
    return struct {
        fn f(conv: *Conv, src: *const Frame, dest: *Frame) void {
            var t = PTask{ .w = conv.in_width, .alpha = alpha8(conv), .k = keys(conv) };
            place(&t, src, sl, conv.in_x, conv.in_y, true);
            place(&t, dest, dl, conv.out_x, conv.out_y, false);
            runPlanes(conv, t, conv.in_height, false, false, k);
            fillBorder(conv, dest);
        }
    }.f;
}

const RowFn = fn (*PTask, [*]u8, [*]u8, [*]u8, [*]u8, [*]u8, [*]u8) void;

fn rows(comptime f: RowFn) fn (*PTask) void {
    return struct {
        fn k(t: *PTask) void {
            for (0..cnt(t.h)) |r| f(t, row(t.s, t.ss, r), row(t.su, t.sus, r), row(t.sv, t.svs, r), row(t.d, t.ds, r), row(t.du, t.dus, r), row(t.dv, t.dvs, r));
        }
    }.k;
}

fn yuy2AyuvR(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| {
        const p = s + i * 4;
        (d + i * 8)[0..8].* = .{ t.alpha, p[0], p[1], p[3], t.alpha, p[2], p[1], p[3] };
    }
}

fn uyvyAyuvR(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| {
        const p = s + i * 4;
        (d + i * 8)[0..8].* = .{ t.alpha, p[1], p[0], p[2], t.alpha, p[3], p[0], p[2] };
    }
}

fn yuy2Y42bR(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, du: [*]u8, dv: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| {
        const p = s + i * 4;
        d[i * 2] = p[0];
        d[i * 2 + 1] = p[2];
        du[i] = p[1];
        dv[i] = p[3];
    }
}

fn uyvyY42bR(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, du: [*]u8, dv: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| {
        const p = s + i * 4;
        d[i * 2] = p[1];
        d[i * 2 + 1] = p[3];
        du[i] = p[0];
        dv[i] = p[2];
    }
}

fn yuy2Y444R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, du: [*]u8, dv: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| {
        const p = s + i * 4;
        d[i * 2] = p[0];
        d[i * 2 + 1] = p[2];
        du[i * 2] = p[1];
        du[i * 2 + 1] = p[1];
        dv[i * 2] = p[3];
        dv[i * 2 + 1] = p[3];
    }
}

fn uyvyY444R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, du: [*]u8, dv: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| {
        const p = s + i * 4;
        d[i * 2] = p[1];
        d[i * 2 + 1] = p[3];
        du[i * 2] = p[0];
        du[i * 2 + 1] = p[0];
        dv[i * 2] = p[2];
        dv[i * 2 + 1] = p[2];
    }
}

fn uyvyYuy2R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| {
        const p = s + i * 4;
        (d + i * 4)[0..4].* = .{ p[1], p[0], p[3], p[2] };
    }
}

fn ayuvPair(p: [*]u8) [4]u8 {
    return .{ p[1], p[5], avg(p[6], p[2]), avg(p[7], p[3]) };
}

fn ayuvYuy2R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w, 2))) |i| {
        const q = ayuvPair(s + i * 8);
        (d + i * 4)[0..4].* = .{ q[0], q[2], q[1], q[3] };
    }
}

fn ayuvUyvyR(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w, 2))) |i| {
        const q = ayuvPair(s + i * 8);
        (d + i * 4)[0..4].* = .{ q[2], q[0], q[3], q[1] };
    }
}

fn ayuvY42bR(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, du: [*]u8, dv: [*]u8) void {
    for (0..cnt(@divTrunc(t.w, 2))) |i| {
        const q = ayuvPair(s + i * 8);
        d[i * 2] = q[0];
        d[i * 2 + 1] = q[1];
        du[i] = q[2];
        dv[i] = q[3];
    }
}

fn ayuvY444R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, du: [*]u8, dv: [*]u8) void {
    for (0..cnt(t.w)) |i| {
        d[i] = s[i * 4 + 1];
        du[i] = s[i * 4 + 2];
        dv[i] = s[i * 4 + 3];
    }
}

fn y42bYuy2R(t: *PTask, s: [*]u8, su: [*]u8, sv: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| (d + i * 4)[0..4].* = .{ s[i * 2], su[i], s[i * 2 + 1], sv[i] };
}

fn y42bUyvyR(t: *PTask, s: [*]u8, su: [*]u8, sv: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w + 1, 2))) |i| (d + i * 4)[0..4].* = .{ su[i], s[i * 2], sv[i], s[i * 2 + 1] };
}

fn y42bAyuvR(t: *PTask, s: [*]u8, su: [*]u8, sv: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w, 2))) |i| (d + i * 8)[0..8].* = .{ t.alpha, s[i * 2], su[i], sv[i], t.alpha, s[i * 2 + 1], su[i], sv[i] };
}

fn y444Yuy2R(t: *PTask, s: [*]u8, su: [*]u8, sv: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w, 2))) |i| (d + i * 4)[0..4].* = .{ s[i * 2], avg(su[i * 2 + 1], su[i * 2]), s[i * 2 + 1], avg(sv[i * 2 + 1], sv[i * 2]) };
}

fn y444UyvyR(t: *PTask, s: [*]u8, su: [*]u8, sv: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(@divTrunc(t.w, 2))) |i| (d + i * 4)[0..4].* = .{ avg(su[i * 2 + 1], su[i * 2]), s[i * 2], avg(sv[i * 2 + 1], sv[i * 2]), s[i * 2 + 1] };
}

fn y444AyuvR(t: *PTask, s: [*]u8, su: [*]u8, sv: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    for (0..cnt(t.w)) |i| (d + i * 4)[0..4].* = .{ t.alpha, s[i], su[i], sv[i] };
}

fn MatrixR(comptime o: [4]u8) type {
    return struct {
        fn f(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
            for (0..cnt(t.w)) |i| {
                const p = s + i * 4;
                const rgb = cv.yuvRgb(p[1], p[2], p[3], t.k);
                const v = [4]u8{ p[0], rgb[0], rgb[1], rgb[2] };
                (d + i * 4)[0..4].* = .{ v[o[0]], v[o[1]], v[o[2]], v[o[3]] };
            }
        }
    };
}

const YI = [6]usize{ 1, 3, 5, 7, 9, 11 };
const UI = [3]usize{ 0, 4, 8 };
const VI = [3]usize{ 2, 6, 10 };

fn each6(j: c.gint, w: c.gint, e: anytype) void {
    e.y(0);
    e.uv(0);
    if (j < w - 1) e.y(1);
    if (j < w - 2) {
        e.y(2);
        e.uv(1);
    }
    if (j < w - 3) e.y(3);
    if (j < w - 4) {
        e.y(4);
        e.uv(2);
    }
    if (j < w - 5) e.y(5);
}

fn ix(j: c.gint) usize {
    return @intCast(j);
}

fn group(j: c.gint) usize {
    return @intCast(@divTrunc(j, 6) * 16);
}

const Yuy2 = struct {
    s: [*]u8,
    fn y(t: Yuy2, j: c.gint) u32 {
        return t.s[ix(2 * j)];
    }
    fn u(t: Yuy2, j: c.gint) u32 {
        return t.s[ix(2 * j + 1)];
    }
    fn v(t: Yuy2, j: c.gint) u32 {
        return t.s[ix(2 * j + 3)];
    }
};

const Uyvy = struct {
    s: [*]u8,
    fn y(t: Uyvy, j: c.gint) u32 {
        return t.s[ix(2 * j + 1)];
    }
    fn u(t: Uyvy, j: c.gint) u32 {
        return t.s[ix(2 * j)];
    }
    fn v(t: Uyvy, j: c.gint) u32 {
        return t.s[ix(2 * j + 2)];
    }
};

const Planar8 = struct {
    sy: [*]u8,
    su: [*]u8,
    sv: [*]u8,
    fn y(t: Planar8, j: c.gint) u32 {
        return t.sy[ix(j)];
    }
    fn u(t: Planar8, j: c.gint) u32 {
        return t.su[ix(@divTrunc(j, 2))];
    }
    fn v(t: Planar8, j: c.gint) u32 {
        return t.sv[ix(@divTrunc(j, 2))];
    }
};

const Planar16 = struct {
    sy: [*]u8,
    su: [*]u8,
    sv: [*]u8,
    fn y(t: Planar16, j: c.gint) u32 {
        return ln.u16s(t.sy)[ix(j)];
    }
    fn u(t: Planar16, j: c.gint) u32 {
        return ln.u16s(t.su)[ix(@divTrunc(j, 2))];
    }
    fn v(t: Planar16, j: c.gint) u32 {
        return ln.u16s(t.sv)[ix(@divTrunc(j, 2))];
    }
};

fn Collect(comptime S: type) type {
    return struct {
        src: S,
        j: c.gint,
        g: [12]u32 = [_]u32{0} ** 12,
        fn y(e: *@This(), k: usize) void {
            e.g[YI[k]] = e.src.y(e.j + @as(c.gint, @intCast(k)));
        }
        fn uv(e: *@This(), m: usize) void {
            const p = e.j + @as(c.gint, @intCast(2 * m));
            e.g[UI[m]] = e.src.u(p);
            e.g[VI[m]] = e.src.v(p);
        }
    };
}

fn packV210(d: [*]u8, w: c.gint, comptime s: u5, src: anytype) void {
    var j: c.gint = 0;
    while (j < w) : (j += 6) {
        var e = Collect(@TypeOf(src)){ .src = src, .j = j };
        each6(j, w, &e);
        const o = d + group(j);
        for (0..4) |q| ln.wr32le(o + q * 4, e.g[q * 3] << s | e.g[q * 3 + 1] << (10 + s) | e.g[q * 3 + 2] << (20 + s));
    }
}

fn readV210(s: [*]u8, j: c.gint, comptime r: u4) [12]u16 {
    const o = s + group(j);
    var g: [12]u16 = undefined;
    for (0..4) |q| {
        const a = ln.rd32le(o + q * 4);
        g[q * 3] = @intCast((a & 0x3ff) >> r);
        g[q * 3 + 1] = @intCast(((a >> 10) & 0x3ff) >> r);
        g[q * 3 + 2] = @intCast(((a >> 20) & 0x3ff) >> r);
    }
    return g;
}

const Yuy2D = struct {
    d: [*]u8,
    fn y(t: Yuy2D, j: c.gint, v: u16) void {
        t.d[ix(2 * j)] = @truncate(v);
    }
    fn uv(t: Yuy2D, j: c.gint, u: u16, v: u16) void {
        t.d[ix(2 * j + 1)] = @truncate(u);
        t.d[ix(2 * j + 3)] = @truncate(v);
    }
};

const UyvyD = struct {
    d: [*]u8,
    fn y(t: UyvyD, j: c.gint, v: u16) void {
        t.d[ix(2 * j + 1)] = @truncate(v);
    }
    fn uv(t: UyvyD, j: c.gint, u: u16, v: u16) void {
        t.d[ix(2 * j)] = @truncate(u);
        t.d[ix(2 * j + 2)] = @truncate(v);
    }
};

const Planar8D = struct {
    dy: [*]u8,
    du: [*]u8,
    dv: [*]u8,
    fn y(t: Planar8D, j: c.gint, v: u16) void {
        t.dy[ix(j)] = @truncate(v);
    }
    fn uv(t: Planar8D, j: c.gint, u: u16, v: u16) void {
        t.du[ix(@divTrunc(j, 2))] = @truncate(u);
        t.dv[ix(@divTrunc(j, 2))] = @truncate(v);
    }
};

const Planar16D = struct {
    dy: [*]u8,
    du: [*]u8,
    dv: [*]u8,
    fn y(t: Planar16D, j: c.gint, v: u16) void {
        ln.u16s(t.dy)[ix(j)] = v;
    }
    fn uv(t: Planar16D, j: c.gint, u: u16, v: u16) void {
        ln.u16s(t.du)[ix(@divTrunc(j, 2))] = u;
        ln.u16s(t.dv)[ix(@divTrunc(j, 2))] = v;
    }
};

fn Emit(comptime D: type) type {
    return struct {
        a: D,
        b: ?D,
        j: c.gint,
        g1: [12]u16,
        g2: [12]u16,
        fn y(e: *@This(), k: usize) void {
            const p = e.j + @as(c.gint, @intCast(k));
            e.a.y(p, e.g1[YI[k]]);
            if (e.b) |b| b.y(p, e.g2[YI[k]]);
        }
        fn uv(e: *@This(), m: usize) void {
            const p = e.j + @as(c.gint, @intCast(2 * m));
            if (e.b == null) return e.a.uv(p, e.g1[UI[m]], e.g1[VI[m]]);
            e.a.uv(p, (e.g1[UI[m]] + e.g2[UI[m]]) / 2, (e.g1[VI[m]] + e.g2[VI[m]]) / 2);
        }
    };
}

fn unpackV210(s1: [*]u8, s2: ?[*]u8, w: c.gint, comptime r: u4, a: anytype, b: ?@TypeOf(a)) void {
    var j: c.gint = 0;
    while (j < w) : (j += 6) {
        const g1 = readV210(s1, j, r);
        var e = Emit(@TypeOf(a)){ .a = a, .b = b, .j = j, .g1 = g1, .g2 = if (s2) |p| readV210(p, j, r) else g1 };
        each6(j, w, &e);
    }
}

fn yuy2V210R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    packV210(d, t.w, 2, Yuy2{ .s = s });
}

fn uyvyV210R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    packV210(d, t.w, 2, Uyvy{ .s = s });
}

fn y42bV210R(t: *PTask, s: [*]u8, su: [*]u8, sv: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    packV210(d, t.w, 2, Planar8{ .sy = s, .su = su, .sv = sv });
}

fn i422P10V210R(t: *PTask, s: [*]u8, su: [*]u8, sv: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    packV210(d, t.w, 0, Planar16{ .sy = s, .su = su, .sv = sv });
}

fn v210Y42bR(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, du: [*]u8, dv: [*]u8) void {
    unpackV210(s, null, t.w, 2, Planar8D{ .dy = d, .du = du, .dv = dv }, null);
}

fn v210I422P10R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, du: [*]u8, dv: [*]u8) void {
    unpackV210(s, null, t.w, 0, Planar16D{ .dy = d, .du = du, .dv = dv }, null);
}

fn v210UyvyR(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    unpackV210(s, null, t.w, 2, UyvyD{ .d = d }, null);
}

fn v210Yuy2R(t: *PTask, s: [*]u8, _: [*]u8, _: [*]u8, d: [*]u8, _: [*]u8, _: [*]u8) void {
    unpackV210(s, null, t.w, 2, Yuy2D{ .d = d }, null);
}

const yuy2Ayuv = plane2d(.p422, .p444, rows(yuy2AyuvR));
const yuy2V210 = plane2d(.p422, .p422, rows(yuy2V210R));
const yuy2Y42b = plane2d(.p422, .pl422, rows(yuy2Y42bR));
const yuy2Y444 = plane2d(.p422, .pl444, rows(yuy2Y444R));
const v210Y42b = plane2d(.p422, .pl422, rows(v210Y42bR));
const v210I422P10 = plane2d(.p422, .pl422, rows(v210I422P10R));
const uyvyAyuv = plane2d(.p422, .p444, rows(uyvyAyuvR));
const uyvyV210 = plane2d(.p422, .p422, rows(uyvyV210R));
const uyvyYuy2 = plane2d(.p422, .p422, rows(uyvyYuy2R));
const v210Uyvy = plane2d(.p422, .p422, rows(v210UyvyR));
const v210Yuy2 = plane2d(.p422, .p422, rows(v210Yuy2R));
const uyvyY42b = plane2d(.p422, .pl422, rows(uyvyY42bR));
const uyvyY444 = plane2d(.p422, .pl444, rows(uyvyY444R));
const ayuvYuy2 = plane2d(.p444, .p422, rows(ayuvYuy2R));
const ayuvUyvy = plane2d(.p444, .p422, rows(ayuvUyvyR));
const ayuvY42b = plane2d(.p444, .pl422, rows(ayuvY42bR));
const ayuvY444 = plane2d(.p444, .pl444, rows(ayuvY444R));
const y42bYuy2 = plane2d(.pl422, .p422, rows(y42bYuy2R));
const y42bUyvy = plane2d(.pl422, .p422, rows(y42bUyvyR));
const y42bAyuv = plane2d(.pl422, .p444, rows(y42bAyuvR));
const y42bV210 = plane2d(.pl422, .p422, rows(y42bV210R));
const i422P10V210 = plane2d(.pl422, .p422, rows(i422P10V210R));
const y444Yuy2 = plane2d(.pl444, .p422, rows(y444Yuy2R));
const y444Uyvy = plane2d(.pl444, .p422, rows(y444UyvyR));
const y444Ayuv = plane2d(.pl444, .p444, rows(y444AyuvR));
const ayuvArgb = plane2d(.p444, .p444, rows(MatrixR(.{ 0, 1, 2, 3 }).f));
const ayuvBgra = plane2d(.p444, .p444, rows(MatrixR(.{ 3, 2, 1, 0 }).f));
const ayuvAbgr = plane2d(.p444, .p444, rows(MatrixR(.{ 0, 3, 2, 1 }).f));
const ayuvRgba = plane2d(.p444, .p444, rows(MatrixR(.{ 1, 2, 3, 0 }).f));

fn ayuvI420K(t: *PTask) void {
    for (0..cnt(@divTrunc(t.h, 2))) |r| {
        const s1 = row(t.s, 2 * t.ss, r);
        const s2 = row(t.s2, 2 * t.ss, r);
        const d1 = row(t.d, 2 * t.ds, r);
        const d2 = row(t.d2, 2 * t.ds, r);
        const du = row(t.du, t.dus, r);
        const dv = row(t.dv, t.dvs, r);
        for (0..cnt(@divTrunc(t.w, 2))) |i| {
            const a = s1 + i * 8;
            const b = s2 + i * 8;
            d1[i * 2] = a[1];
            d1[i * 2 + 1] = a[5];
            d2[i * 2] = b[1];
            d2[i * 2 + 1] = b[5];
            du[i] = avg(avg(a[6], b[6]), avg(a[2], b[2]));
            dv[i] = avg(avg(a[7], b[7]), avg(a[3], b[3]));
        }
    }
}

fn ayuvI420(conv: *Conv, src: *const Frame, dest: *Frame) void {
    var t = PTask{ .w = conv.in_width };
    t.s = at(pl(src, 0, conv.in_y), conv.in_x * 4);
    t.s2 = at(pl(src, 0, conv.in_y + 1), conv.in_x * 4);
    t.ss = ps(src, 0);
    t.d = at(cl(dest, 0, conv.out_y), conv.out_x);
    t.d2 = at(cl(dest, 0, conv.out_y + 1), conv.out_x);
    t.du = at(cl(dest, 1, conv.out_y >> 1), conv.out_x >> 1);
    t.dv = at(cl(dest, 2, conv.out_y >> 1), conv.out_x >> 1);
    t.ds = cs(dest, 0);
    t.dus = cs(dest, 1);
    t.dvs = cs(dest, 2);
    runPlanes(conv, t, conv.in_height, true, true, ayuvI420K);
    fillBorder(conv, dest);
}

fn uyvyGray8K(t: *PTask) void {
    for (0..cnt(t.h)) |r| {
        const s = row(t.s, t.ss, r);
        const d = row(t.d, t.ds, r);
        for (0..cnt(t.w)) |i| d[i] = s[i * 2 + 1];
    }
}

fn uyvyGray8(conv: *Conv, src: *const Frame, dest: *Frame) void {
    const t = PTask{ .w = conv.in_width, .s = @ptrCast(src.data[0]), .ss = ps(src, 0), .d = @ptrCast(dest.data[0]), .ds = ps(dest, 0) };
    runPlanes(conv, t, conv.in_height, false, false, uyvyGray8K);
    fillBorder(conv, dest);
}

const LTask = struct {
    src: *const Frame,
    dest: *Frame,
    h0: c.gint = 0,
    h1: c.gint = 0,
    il: bool = false,
    w: c.gint,
    alpha: u8 = 0,
    k: [5]i16 = .{ 0, 0, 0, 0, 0 },
    in_x: c.gint = 0,
    in_y: c.gint = 0,
    out_x: c.gint = 0,
    out_y: c.gint = 0,
    tmp: [*]u16 = undefined,
};

fn runLines(conv: *Conv, base: LTask, height: c.gint, round2: bool, comptime k: fn (*LTask) void) void {
    const n = cv.nThreads(conv);
    const l = lpt(conv, height, round2);
    const ts, const tp = renew(conv, 0, LTask, n);
    for (0..n) |i| {
        var t = base;
        t.h0 = @as(c.gint, @intCast(i)) * l;
        t.h1 = @min(height, t.h0 + l);
        t.tmp = conv.tmpline.?[i];
        ts[i] = t;
    }
    cv.runnerRun(conv.runner.?, Wrap(LTask, k).f, tp);
}

fn offsets(il: bool, i: c.gint) [2]c.gint {
    if (il) {
        const l1 = if (i & 2 != 0) i - 1 else i;
        return .{ l1, l1 + 2 };
    }
    return .{ i, i + 1 };
}

const PairFn = fn (*LTask, c.gint, c.gint, c.gint) void;

fn PairLoop(comptime f: PairFn) fn (*LTask) void {
    return struct {
        fn k(t: *LTask) void {
            var i = t.h0;
            while (i < t.h1) : (i += 2) {
                const l = offsets(t.il, i);
                f(t, i, l[0], l[1]);
            }
        }
    }.k;
}

fn i420Yuy2L(t: *LTask, i: c.gint, l1: c.gint, l2: c.gint) void {
    const u = cl(t.src, 1, i >> 1);
    const v = cl(t.src, 2, i >> 1);
    for ([2]c.gint{ l1, l2 }) |l| {
        const d = pl(t.dest, 0, l);
        const y = cl(t.src, 0, l);
        for (0..cnt(@divTrunc(t.w + 1, 2))) |j| (d + j * 4)[0..4].* = .{ y[j * 2], u[j], y[j * 2 + 1], v[j] };
    }
}

fn i420UyvyL(t: *LTask, i: c.gint, l1: c.gint, l2: c.gint) void {
    const u = cl(t.src, 1, i >> 1);
    const v = cl(t.src, 2, i >> 1);
    for ([2]c.gint{ l1, l2 }) |l| {
        const d = pl(t.dest, 0, l);
        const y = cl(t.src, 0, l);
        for (0..cnt(@divTrunc(t.w + 1, 2))) |j| (d + j * 4)[0..4].* = .{ u[j], y[j * 2], v[j], y[j * 2 + 1] };
    }
}

fn i420AyuvL(t: *LTask, i: c.gint, l1: c.gint, l2: c.gint) void {
    const u = cl(t.src, 1, i >> 1);
    const v = cl(t.src, 2, i >> 1);
    for ([2]c.gint{ l1, l2 }) |l| {
        const d = pl(t.dest, 0, l);
        const y = cl(t.src, 0, l);
        for (0..cnt(t.w)) |j| (d + j * 4)[0..4].* = .{ t.alpha, y[j], u[j >> 1], v[j >> 1] };
    }
}

fn i420V210L(t: *LTask, i: c.gint, l1: c.gint, l2: c.gint) void {
    const u = cl(t.src, 1, i >> 1);
    const v = cl(t.src, 2, i >> 1);
    packV210(pl(t.dest, 0, l1), t.w, 2, Planar8{ .sy = cl(t.src, 0, l1), .su = u, .sv = v });
    packV210(pl(t.dest, 0, l2), t.w, 2, Planar8{ .sy = cl(t.src, 0, l2), .su = u, .sv = v });
}

fn i420P10V210L(t: *LTask, i: c.gint, l1: c.gint, l2: c.gint) void {
    const u = cl(t.src, 1, i >> 1);
    const v = cl(t.src, 2, i >> 1);
    packV210(pl(t.dest, 0, l1), t.w, 0, Planar16{ .sy = cl(t.src, 0, l1), .su = u, .sv = v });
    packV210(pl(t.dest, 0, l2), t.w, 0, Planar16{ .sy = cl(t.src, 0, l2), .su = u, .sv = v });
}

fn Packed422I420(comptime yo: usize, comptime uo: usize) PairFn {
    return struct {
        fn f(t: *LTask, i: c.gint, l1: c.gint, l2: c.gint) void {
            const a = pl(t.src, 0, l1);
            const b = pl(t.src, 0, l2);
            const y1 = cl(t.dest, 0, l1);
            const y2 = cl(t.dest, 0, l2);
            const u = cl(t.dest, 1, i >> 1);
            const v = cl(t.dest, 2, i >> 1);
            for (0..cnt(@divTrunc(t.w + 1, 2))) |j| {
                const p = a + j * 4;
                const q = b + j * 4;
                y1[j * 2] = p[yo];
                y1[j * 2 + 1] = p[yo + 2];
                y2[j * 2] = q[yo];
                y2[j * 2 + 1] = q[yo + 2];
                u[j] = avg(p[uo], q[uo]);
                v[j] = avg(p[uo + 2], q[uo + 2]);
            }
        }
    }.f;
}

fn v210I420L(t: *LTask, i: c.gint, l1: c.gint, l2: c.gint) void {
    const du = cl(t.dest, 1, i >> 1);
    const dv = cl(t.dest, 2, i >> 1);
    unpackV210(pl(t.src, 0, l1), pl(t.src, 0, l2), t.w, 2, Planar8D{ .dy = cl(t.dest, 0, l1), .du = du, .dv = dv }, Planar8D{ .dy = cl(t.dest, 0, l2), .du = du, .dv = dv });
}

fn v210I420P10L(t: *LTask, i: c.gint, l1: c.gint, l2: c.gint) void {
    const du = cl(t.dest, 1, i >> 1);
    const dv = cl(t.dest, 2, i >> 1);
    unpackV210(pl(t.src, 0, l1), pl(t.src, 0, l2), t.w, 0, Planar16D{ .dy = cl(t.dest, 0, l1), .du = du, .dv = dv }, Planar16D{ .dy = cl(t.dest, 0, l2), .du = du, .dv = dv });
}

const Tail = enum { none, alpha, up8, down8 };

fn packFlags(f: *const Frame) c.GstVideoPackFlags {
    return if (cv.frameInterlaced(f)) c.GST_VIDEO_PACK_FLAG_INTERLACED else c.GST_VIDEO_PACK_FLAG_NONE;
}

fn unpackFrame(f: *const Frame, d: c.gpointer, line: c.gint, x: c.gint, w: c.gint) void {
    f.info.finfo[0].unpack_func.?(f.info.finfo, packFlags(f), d, &f.data, &f.info.stride, x, line, w);
}

fn pairs(comptime k: PairFn, comptime tail: Tail) Fn {
    return struct {
        fn f(conv: *Conv, src: *const Frame, dest: *Frame) void {
            const width = conv.in_width;
            const height = conv.in_height;
            const il = cv.frameInterlaced(src) and src.info.interlace_mode != c.GST_VIDEO_INTERLACE_MODE_ALTERNATE;
            const alpha = alpha8(conv);
            const h2 = if (il) height & ~@as(c.gint, 3) else height & ~@as(c.gint, 1);
            runLines(conv, .{ .src = src, .dest = dest, .il = il, .w = width, .alpha = alpha }, h2, true, PairLoop(k));
            const tmp = conv.tmpline.?[0];
            const t8: [*]u8 = @ptrCast(tmp);
            const n = cnt(width);
            var i = h2;
            while (i < height) : (i += 1) {
                unpackFrame(src, tmp, i, conv.in_x, width);
                switch (tail) {
                    .none => {},
                    .alpha => if (alpha != 0xff) {
                        for (0..n) |j| t8[j * 4] = alpha;
                    },
                    .up8 => {
                        var j = n * 4;
                        while (j > 0) {
                            j -= 1;
                            tmp[j] = @as(u16, t8[j]) << 8;
                        }
                    },
                    .down8 => for (0..n * 4) |j| {
                        t8[j] = @truncate(tmp[j] >> 8);
                    },
                }
                cv.packFrame(dest, tmp, i, width);
            }
        }
    }.f;
}

const i420Yuy2 = pairs(i420Yuy2L, .none);
const i420Uyvy = pairs(i420UyvyL, .none);
const i420Ayuv = pairs(i420AyuvL, .alpha);
const i420V210 = pairs(i420V210L, .up8);
const i420P10V210 = pairs(i420P10V210L, .none);
const yuy2I420 = pairs(Packed422I420(0, 1), .none);
const uyvyI420 = pairs(Packed422I420(1, 0), .none);
const v210I420 = pairs(v210I420L, .down8);
const v210I420P10 = pairs(v210I420P10L, .none);

const RgbOut = enum { argb, bgra };

fn rgbLine(d: [*]u8, sy: [*]u8, su: [*]u8, sv: [*]u8, sa: ?[*]u8, w: c.gint, k: [5]i16, comptime o: RgbOut) void {
    for (0..cnt(w)) |j| {
        const rgb = cv.yuvRgb(sy[j], su[j >> 1], sv[j >> 1], k);
        const a: u8 = if (sa) |p| p[j] else 255;
        (d + j * 4)[0..4].* = switch (o) {
            .argb => .{ a, rgb[0], rgb[1], rgb[2] },
            .bgra => .{ rgb[2], rgb[1], rgb[0], a },
        };
    }
}

fn LineRgb(comptime o: RgbOut, comptime alpha: bool, comptime pack: bool) fn (*LTask) void {
    return struct {
        fn k(t: *LTask) void {
            var dp = [4]c.gpointer{ null, null, null, null };
            if (pack) dp[0] = at(pl(t.dest, 0, 0), t.out_x * t.dest.info.finfo[0].pixel_stride[0]);
            var i = t.h0;
            while (i < t.h1) : (i += 1) {
                const sy = at(cl(t.src, 0, i + t.in_y), t.in_x);
                const su = at(cl(t.src, 1, (i + t.in_y) >> 1), t.in_x >> 1);
                const sv = at(cl(t.src, 2, (i + t.in_y) >> 1), t.in_x >> 1);
                const sa: ?[*]u8 = if (alpha) at(cl(t.src, 3, i + t.in_y), t.in_x) else null;
                if (pack) {
                    rgbLine(@ptrCast(t.tmp), sy, su, sv, sa, t.w, t.k, o);
                    const fi = t.dest.info.finfo;
                    fi[0].pack_func.?(fi, packFlags(t.dest), t.tmp, 0, &dp, &t.dest.info.stride, t.dest.info.chroma_site, i + t.out_y, t.w);
                } else {
                    rgbLine(at(pl(t.dest, 0, i + t.out_y), t.out_x * 4), sy, su, sv, sa, t.w, t.k, o);
                }
            }
        }
    }.k;
}

fn lines(comptime k: fn (*LTask) void) Fn {
    return struct {
        fn f(conv: *Conv, src: *const Frame, dest: *Frame) void {
            runLines(conv, .{ .src = src, .dest = dest, .w = conv.in_width, .k = keys(conv), .in_x = conv.in_x, .in_y = conv.in_y, .out_x = conv.out_x, .out_y = conv.out_y }, conv.in_height, false, k);
            fillBorder(conv, dest);
        }
    }.f;
}

const i420Bgra = lines(LineRgb(.bgra, false, false));
const i420Argb = lines(LineRgb(.argb, false, false));
const i420PackArgb = lines(LineRgb(.argb, false, true));
const a420PackArgb = lines(LineRgb(.argb, true, true));
const a420Bgra = lines(LineRgb(.bgra, true, false));

fn putBorder(d: [*]u8, col: []const u8, pgroup: c.gint, n: c.gint) void {
    if (pgroup == 42) {
        var i: c.gint = 0;
        var p = d;
        while (i < n) : (i += 2) {
            p[0] = col[0];
            p[1] = col[1];
            if (i + 1 < n) {
                p[2] = col[2];
                p[3] = col[3];
            }
            p += 4;
        }
        return;
    }
    const g: usize = @intCast(pgroup);
    for (0..cnt(n)) |i| @memcpy((d + i * g)[0..g], col[0..g]);
}

fn fillBorder(conv: *Conv, dest: *Frame) void {
    if (!conv.fill_border or conv.borderline == null) return;
    const fi = conv.out_info.finfo;
    for (0..dest.info.finfo[0].n_planes) |k| {
        var comp: [4]c.gint = undefined;
        format.gst_video_format_info_component(fi, @intCast(k), &comp);
        const c0: usize = @intCast(comp[0]);
        const out_x = sw(fi, c0, conv.out_x);
        const out_y = sh(fi, c0, conv.out_y);
        const out_w = sw(fi, c0, conv.out_width);
        const out_h = sh(fi, c0, conv.out_height);
        var maxw = sw(fi, c0, conv.out_maxwidth);
        const maxh = sh(fi, c0, conv.out_maxheight);
        const pstride = fi[0].pixel_stride[c0];
        var pgroup = pstride;
        switch (fi[0].format) {
            c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YVYU, c.GST_VIDEO_FORMAT_UYVY => {
                pgroup = 42;
                maxw = up2(maxw);
            },
            else => {},
        }
        const r_border = out_x + out_w;
        const rb = maxw - r_border;
        const lb = out_x;
        const b: [*]const u8 = @ptrCast(&conv.borders[k]);
        var col: [8]u8 = undefined;
        switch (pgroup) {
            1, 2, 3, 4, 8 => @memcpy(col[0..8], b[0..8]),
            42 => {
                col[0] = b[0];
                col[2] = b[2];
                col[1] = b[if (r_border & 1 != 0) 3 else 1];
                col[3] = b[if (r_border & 1 != 0) 1 else 3];
            },
            else => continue,
        }
        var i: c.gint = 0;
        while (i < out_y) : (i += 1) putBorder(pl(dest, k, i), &col, pgroup, maxw);
        if (rb != 0 or lb != 0) {
            i = 0;
            while (i < out_h) : (i += 1) {
                const d = pl(dest, k, i + out_y);
                if (lb != 0) putBorder(d, &col, pgroup, lb);
                if (rb != 0) putBorder(at(d, @as(isize, pstride) * r_border), &col, pgroup, rb);
            }
        }
        i = out_y + out_h;
        while (i < maxh) : (i += 1) putBorder(pl(dest, k, i), &col, pgroup, maxw);
    }
}

const STask = struct {
    s: [*]u8 = &dummy,
    s2: [*]u8 = &dummy,
    d: [*]u8 = &dummy,
    d2: [*]u8 = &dummy,
    ss: isize = 0,
    ds: isize = 0,
    w: c.gint = 0,
    h: c.gint = 0,
    fill: u8 = 0,
};

const Shape = enum { fill, one, vdouble, vhalve };

fn simple(comptime shape: Shape, comptime k: fn (*STask) void) cv.FastFn {
    return struct {
        fn f(conv: *Conv, src: *const Frame, dest: *Frame, plane: c.gint) void {
            const p: usize = @intCast(plane);
            const sp: usize = @intCast(conv.fsplane[p]);
            const n = cv.nThreads(conv);
            const oh = conv.fout_height[p];
            const l = lpt(conv, oh, shape == .vdouble);
            const ds = ps(dest, p);
            const d = at(pl(dest, p, conv.fout_y[p]), conv.fout_x[p]);
            const d2 = at(pl(dest, p, conv.fout_y[p] + 1), conv.fout_x[p]);
            var s: [*]u8 = &dummy;
            var s2: [*]u8 = &dummy;
            var ss: isize = 0;
            if (shape != .fill) {
                s = at(pl(src, sp, conv.fin_y[sp]), conv.fin_x[sp]);
                s2 = at(pl(src, sp, conv.fin_y[sp] + 1), conv.fin_x[sp]);
                ss = ps(src, sp);
            }
            const ts, const tp = renew(conv, p, STask, n);
            for (0..n) |i| {
                const o: isize = @as(isize, @intCast(i)) * l;
                var t = STask{ .ds = ds, .ss = ss, .w = conv.fout_width[p], .fill = @truncate(@as(c.guint, @bitCast(conv.ffill[p]))) };
                switch (shape) {
                    .fill => t.d = at(d, o * conv.fout_width[p]),
                    .one => {
                        t.d = at(d, o * ds);
                        t.s = at(s, o * ss);
                    },
                    .vdouble => {
                        t.d = at(d, o * ds);
                        t.d2 = at(d2, o * ds);
                        t.s = at(s, @divTrunc(o * ss, 2));
                    },
                    .vhalve => {
                        t.d = at(d, o * ds);
                        t.s = at(s, o * ss * 2);
                        t.s2 = at(s2, o * ss * 2);
                    },
                }
                t.h = @min(@as(c.gint, @intCast(i + 1)) * l, oh) - @as(c.gint, @intCast(o));
                ts[i] = t;
            }
            cv.runnerRun(conv.runner.?, Wrap(STask, k).f, tp);
        }
    }.f;
}

fn fillK(t: *STask) void {
    for (0..cnt(t.h)) |r| @memset(row(t.d, t.ds, r)[0..cnt(t.w)], t.fill);
}

fn hDoubleK(t: *STask) void {
    for (0..cnt(t.h)) |r| {
        const s = row(t.s, t.ss, r);
        const d = row(t.d, t.ds, r);
        for (0..cnt(@divTrunc(t.w, 2))) |i| {
            d[i * 2] = s[i];
            d[i * 2 + 1] = s[i];
        }
    }
}

fn hHalveK(t: *STask) void {
    for (0..cnt(t.h)) |r| {
        const s = row(t.s, t.ss, r);
        const d = row(t.d, t.ds, r);
        for (0..cnt(t.w)) |i| d[i] = avg(s[i * 2 + 1], s[i * 2]);
    }
}

fn vDoubleK(t: *STask) void {
    for (0..cnt(@divTrunc(t.h, 2))) |r| {
        const s = row(t.s, t.ss, r);
        const d1 = row(t.d, 2 * t.ds, r);
        const d2 = row(t.d2, 2 * t.ds, r);
        for (0..cnt(t.w)) |i| {
            d1[i] = s[i];
            d2[i] = s[i];
        }
    }
}

fn vHalveK(t: *STask) void {
    for (0..cnt(t.h)) |r| {
        const a = row(t.s, 2 * t.ss, r);
        const b = row(t.s2, 2 * t.ss, r);
        const d = row(t.d, t.ds, r);
        for (0..cnt(t.w)) |i| d[i] = avg(a[i], b[i]);
    }
}

fn hvDoubleK(t: *STask) void {
    for (0..cnt(@divTrunc(t.h, 2))) |r| {
        const s = row(t.s, t.ss, r);
        const d1 = row(t.d, 2 * t.ds, r);
        const d2 = row(t.d2, 2 * t.ds, r);
        for (0..cnt(@divTrunc(t.w + 1, 2))) |i| {
            d1[i * 2] = s[i];
            d1[i * 2 + 1] = s[i];
            d2[i * 2] = s[i];
            d2[i * 2 + 1] = s[i];
        }
    }
}

fn hvHalveK(t: *STask) void {
    for (0..cnt(t.h)) |r| {
        const a = row(t.s, 2 * t.ss, r);
        const b = row(t.s2, 2 * t.ss, r);
        const d = row(t.d, t.ds, r);
        for (0..cnt(t.w)) |i| d[i] = avg(avg(a[i * 2 + 1], b[i * 2 + 1]), avg(a[i * 2], b[i * 2]));
    }
}

const planeFill = simple(.fill, fillK);
const planeHDouble = simple(.one, hDoubleK);
const planeHHalve = simple(.one, hHalveK);
const planeVDouble = simple(.vdouble, vDoubleK);
const planeVHalve = simple(.vhalve, vHalveK);
const planeHvDouble = simple(.vdouble, hvDoubleK);
const planeHvHalve = simple(.vhalve, hvHalveK);

const QTask = struct {
    hs: ?*c.GstVideoScaler,
    vs: ?*c.GstVideoScaler,
    fmt: c.GstVideoFormat,
    s: [*]u8,
    d: [*]u8,
    ss: c.gint,
    ds: c.gint,
    x: c.guint,
    y: c.guint,
    w: c.guint,
    h: c.guint,
};

fn hvK(t: *QTask) void {
    scaler.gst_video_scaler_2d(@ptrCast(t.hs), @ptrCast(t.vs), t.fmt, t.s, t.ss, t.d, t.ds, t.x, t.y, t.w, t.h);
}

fn planeHv(conv: *Conv, src: *const Frame, dest: *Frame, plane: c.gint) void {
    const p: usize = @intCast(plane);
    const sp: usize = @intCast(conv.fsplane[p]);
    const out_h = conv.fout_height[p];
    const s = at(pl(src, sp, conv.fin_y[sp]), conv.fin_x[sp]);
    const d = at(pl(dest, p, conv.fout_y[p]), conv.fout_x[p]);
    const n = cv.nThreads(conv);
    const l = lpt(conv, out_h, false);
    const ts, const tp = renew(conv, p, QTask, n);
    for (0..n) |i| {
        const y = @as(c.gint, @intCast(i)) * l;
        ts[i] = .{
            .hs = if (conv.fh_scaler[p]) |a| a[i] else null,
            .vs = if (conv.fv_scaler[p]) |a| a[i] else null,
            .fmt = conv.fformat[p],
            .s = s,
            .d = d,
            .ss = src.info.stride[sp],
            .ds = dest.info.stride[p],
            .x = 0,
            .w = @bitCast(conv.fout_width[p]),
            .y = @bitCast(y),
            .h = @bitCast(@min(out_h, y + l)),
        };
    }
    cv.runnerRun(conv.runner.?, Wrap(QTask, hvK).f, tp);
}

fn scalePlanes(conv: *Conv, src: *const Frame, dest: *Frame) void {
    for (0..dest.info.finfo[0].n_planes) |i| {
        if (conv.fconvert[i]) |f| f(conv, src, dest, @intCast(i));
    }
    fillBorder(conv, dest);
}

fn scaleFormat(f: c.GstVideoFormat, plane: usize) c.GstVideoFormat {
    return switch (f) {
        c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_YV12, c.GST_VIDEO_FORMAT_Y41B, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_A420, c.GST_VIDEO_FORMAT_A422, c.GST_VIDEO_FORMAT_A444, c.GST_VIDEO_FORMAT_YUV9, c.GST_VIDEO_FORMAT_YVU9, c.GST_VIDEO_FORMAT_GBR, c.GST_VIDEO_FORMAT_GBRA, c.GST_VIDEO_FORMAT_RGBP, c.GST_VIDEO_FORMAT_BGRP => c.GST_VIDEO_FORMAT_GRAY8,
        c.GST_VIDEO_FORMAT_GRAY16_BE, c.GST_VIDEO_FORMAT_GRAY16_LE => c.GST_VIDEO_FORMAT_GRAY16_BE,
        c.GST_VIDEO_FORMAT_RGB15, c.GST_VIDEO_FORMAT_BGR15, c.GST_VIDEO_FORMAT_RGB16, c.GST_VIDEO_FORMAT_BGR16 => c.GST_VIDEO_FORMAT_NV12,
        c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV61, c.GST_VIDEO_FORMAT_NV24 => if (plane == 0) c.GST_VIDEO_FORMAT_GRAY8 else c.GST_VIDEO_FORMAT_NV12,
        c.GST_VIDEO_FORMAT_AV12 => if (plane == 0 or plane == 2) c.GST_VIDEO_FORMAT_GRAY8 else c.GST_VIDEO_FORMAT_NV12,
        else => f,
    };
}

fn isMergeYuv(f: c.GstVideoFormat) bool {
    return switch (f) {
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YVYU, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_VYUY => true,
        else => false,
    };
}

fn scalers(n: usize) [*]?*c.GstVideoScaler {
    return @ptrCast(@alignCast(c.g_malloc(@sizeOf(?*c.GstVideoScaler) * n)));
}

fn newScaler(method: c.gint, flags: c.GstVideoScalerFlags, taps: c.guint, a: c.gint, b: c.gint, cfg: ?*c.GstStructure) ?*c.GstVideoScaler {
    return @ptrCast(scaler.gst_video_scaler_new(@bitCast(method), flags, taps, @bitCast(a), @bitCast(b), cfg));
}

fn setupScale(conv: *Conv) bool {
    const n = cv.nThreads(conv);
    const in = &conv.in_info;
    const fin = in.finfo;
    const fout = conv.out_info.finfo;
    const np = fout[0].n_planes;
    const interlaced = cv.isInterlaced(in) and in.interlace_mode != c.GST_VIDEO_INTERLACE_MODE_ALTERNATE;
    const vflags: c.GstVideoScalerFlags = if (interlaced) c.GST_VIDEO_SCALER_FLAG_INTERLACED else c.GST_VIDEO_SCALER_FLAG_NONE;
    const method = cv.resamplerMethod(conv);
    const cr_method = if (method == c.GST_VIDEO_RESAMPLER_METHOD_NEAREST) method else cv.chromaResamplerMethod(conv);
    const taps = cv.resamplerTaps(conv);
    const inf = fin[0].format;
    const outf = fout[0].format;
    switch (inf) {
        c.GST_VIDEO_FORMAT_RGB15, c.GST_VIDEO_FORMAT_RGB16, c.GST_VIDEO_FORMAT_BGR15, c.GST_VIDEO_FORMAT_BGR16, c.GST_VIDEO_FORMAT_GRAY16_BE => if (method != c.GST_VIDEO_RESAMPLER_METHOD_NEAREST) return false,
        else => {},
    }
    const in_w = conv.in_width;
    const in_h = conv.in_height;
    const out_w = conv.out_width;
    const out_h = conv.out_height;
    if (np == 1 and fout[0].flags & c.GST_VIDEO_FORMAT_FLAG_GRAY == 0) {
        const pstride = fout[0].pixel_stride[0];
        if (isMergeYuv(inf)) {
            if (in_w != out_w) {
                const a = scalers(n);
                for (0..n) |j| {
                    const ys = newScaler(method, c.GST_VIDEO_SCALER_FLAG_NONE, taps, sw(fin, 0, in_w), sw(fout, 0, out_w), conv.config);
                    const uvs = newScaler(method, c.GST_VIDEO_SCALER_FLAG_NONE, scaler.gst_video_scaler_get_max_taps(@ptrCast(ys)), sw(fin, 1, in_w), sw(fout, 1, out_w), conv.config);
                    a[j] = @ptrCast(scaler.gst_video_scaler_combine_packed_YUV(@ptrCast(ys), @ptrCast(uvs), inf, outf));
                    scaler.gst_video_scaler_free(@ptrCast(ys));
                    scaler.gst_video_scaler_free(@ptrCast(uvs));
                }
                conv.fh_scaler[0] = a;
            } else conv.fh_scaler[0] = null;
            conv.fin_x[0] = up2(conv.in_x) * pstride;
            conv.fout_x[0] = up2(conv.out_x) * pstride;
        } else {
            if (in_w != out_w and in_w != 0 and out_w != 0) {
                const a = scalers(n);
                for (0..n) |j| a[j] = newScaler(method, c.GST_VIDEO_SCALER_FLAG_NONE, taps, in_w, out_w, conv.config);
                conv.fh_scaler[0] = a;
            } else conv.fh_scaler[0] = null;
            conv.fin_x[0] = conv.in_x * pstride;
            conv.fout_x[0] = conv.out_x * pstride;
        }
        if (in_h != out_h and in_h != 0 and out_h != 0) {
            const a = scalers(n);
            for (0..n) |j| a[j] = newScaler(method, vflags, taps, in_h, out_h, conv.config);
            conv.fv_scaler[0] = a;
        } else conv.fv_scaler[0] = null;
        conv.fin_y[0] = conv.in_y;
        conv.fout_y[0] = conv.out_y;
        conv.fout_width[0] = out_w;
        conv.fout_height[0] = out_h;
        conv.fconvert[0] = planeHv;
        conv.fformat[0] = scaleFormat(inf, 0);
        conv.fsplane[0] = 0;
        return true;
    }
    for (0..np) |i| {
        var oc: [4]c.gint = undefined;
        format.gst_video_format_info_component(fout, @intCast(i), &oc);
        const c0: usize = @intCast(oc[0]);
        const ow = sw(fout, c0, out_w);
        const oh = sh(fout, c0, out_h);
        const pstride = fout[0].pixel_stride[c0];
        var iw: c.gint = -1;
        var ih: c.gint = -1;
        var comp: c.gint = -1;
        if (oc[0] < @as(c.gint, @intCast(fin[0].n_components))) {
            comp = oc[0];
            const k: usize = @intCast(comp);
            iw = sw(fin, k, in_w);
            ih = sh(fin, k, in_h);
            conv.fin_x[i] = sw(fin, k, conv.in_x) * pstride;
            conv.fin_y[i] = sh(fin, k, conv.in_y);
        } else {
            conv.fin_x[i] = -1;
            conv.fin_y[i] = -1;
        }
        conv.fout_width[i] = ow;
        conv.fout_height[i] = oh;
        conv.fout_x[i] = sw(fout, c0, conv.out_x) * pstride;
        conv.fout_y[i] = sh(fout, c0, conv.out_y);
        if (comp == -1) {
            conv.fconvert[i] = planeFill;
            if (fout[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV != 0) {
                conv.ffill[i] = if (i == 0) 0x00 else 0x80;
            } else {
                conv.ffill[i] = if (i == 3) @bitCast(conv.alpha_value) else 0x00;
            }
            continue;
        }
        conv.fsplane[i] = @intCast(fin[0].plane[@intCast(comp)]);
        const cfg = c.gst_structure_copy(conv.config);
        defer c.gst_structure_free(cfg);
        const rm = if (i == 0) method else cr_method;
        const lin = rm == c.GST_VIDEO_RESAMPLER_METHOD_LINEAR;
        const near = rm == c.GST_VIDEO_RESAMPLER_METHOD_NEAREST;
        var need_v = false;
        var need_h = false;
        if (iw == ow) {
            if (!interlaced and ih == oh) {
                conv.fconvert[i] = planeHv;
            } else if (!interlaced and ih == 2 * oh and pstride == 1 and lin) {
                conv.fconvert[i] = planeVHalve;
            } else if (!interlaced and 2 * ih == oh and pstride == 1 and near) {
                conv.fconvert[i] = planeVDouble;
            } else {
                conv.fconvert[i] = planeHv;
                need_v = true;
            }
        } else if (ih == oh) {
            if (!interlaced and iw == 2 * ow and pstride == 1 and lin) {
                conv.fconvert[i] = planeHHalve;
            } else if (!interlaced and 2 * iw == ow and pstride == 1 and near) {
                conv.fconvert[i] = planeHDouble;
            } else {
                conv.fconvert[i] = planeHv;
                need_h = true;
            }
        } else {
            if (!interlaced and iw == 2 * ow and ih == 2 * oh and pstride == 1 and lin) {
                conv.fconvert[i] = planeHvHalve;
            } else if (!interlaced and 2 * iw == ow and 2 * ih == oh and pstride == 1 and near) {
                conv.fconvert[i] = planeHvDouble;
            } else {
                conv.fconvert[i] = planeHv;
                need_v = true;
                need_h = true;
            }
        }
        if (need_h and iw != 0 and ow != 0) {
            const a = scalers(n);
            for (0..n) |j| a[j] = newScaler(rm, c.GST_VIDEO_SCALER_FLAG_NONE, taps, iw, ow, cfg);
            conv.fh_scaler[i] = a;
        } else conv.fh_scaler[i] = null;
        if (need_v and ih != 0 and oh != 0) {
            const a = scalers(n);
            for (0..n) |j| a[j] = newScaler(rm, vflags, taps, ih, oh, cfg);
            conv.fv_scaler[i] = a;
        } else conv.fv_scaler[i] = null;
        conv.fformat[i] = scaleFormat(inf, i);
    }
    return true;
}

const table = [_]Xf{
    xf("I420", "YUY2", 0b10100000, 0, 0, i420Yuy2),
    xf("I420", "UYVY", 0b10100000, 0, 0, i420Uyvy),
    xf("I420", "AYUV", 0b10100010, 0, 0, i420Ayuv),
    xf("I420", "v210", 0b10100000, 0, 0, i420V210),
    xf("YV12", "YUY2", 0b10100000, 0, 0, i420Yuy2),
    xf("YV12", "UYVY", 0b10100000, 0, 0, i420Uyvy),
    xf("YV12", "AYUV", 0b10100010, 0, 0, i420Ayuv),
    xf("YV12", "v210", 0b10100000, 0, 0, i420V210),
    xf("Y42B", "YUY2", 0b10111000, 0, 0, y42bYuy2),
    xf("Y42B", "UYVY", 0b10111000, 0, 0, y42bUyvy),
    xf("Y42B", "AYUV", 0b10111010, 1, 0, y42bAyuv),
    xf("Y42B", "v210", 0b10111000, 0, 0, y42bV210),
    xf("Y444", "YUY2", 0b10111000, 1, 0, y444Yuy2),
    xf("Y444", "UYVY", 0b10111000, 1, 0, y444Uyvy),
    xf("Y444", "AYUV", 0b10111010, 0, 0, y444Ayuv),
    xf("YUY2", "YUY2", 0b10011000, 0, 0, scalePlanes),
    xf("YUY2", "UYVY", 0b10111000, 0, 0, uyvyYuy2),
    xf("YUY2", "AYUV", 0b10111010, 1, 0, yuy2Ayuv),
    xf("YUY2", "v210", 0b10101000, 0, 0, yuy2V210),
    xf("UYVY", "UYVY", 0b10011000, 0, 0, scalePlanes),
    xf("UYVY", "YUY2", 0b10111000, 0, 0, uyvyYuy2),
    xf("UYVY", "AYUV", 0b10111010, 0, 0, uyvyAyuv),
    xf("UYVY", "v210", 0b10101000, 0, 0, uyvyV210),
    xf("AYUV", "AYUV", 0b10011100, 0, 0, scalePlanes),
    xf("AYUV", "YUY2", 0b10111000, 1, 0, ayuvYuy2),
    xf("AYUV", "UYVY", 0b10111000, 1, 0, ayuvUyvy),
    xf("v210", "UYVY", 0b10101000, 0, 0, v210Uyvy),
    xf("v210", "YUY2", 0b10101000, 0, 0, v210Yuy2),
    xf("YUY2", "I420", 0b10100000, 0, 0, yuy2I420),
    xf("YUY2", "YV12", 0b10100000, 0, 0, yuy2I420),
    xf("YUY2", "Y42B", 0b10111000, 0, 0, yuy2Y42b),
    xf("YUY2", "Y444", 0b10111000, 0, 0, yuy2Y444),
    xf("UYVY", "GRAY8", 0b11111000, 0, 0, uyvyGray8),
    xf("UYVY", "I420", 0b10100000, 0, 0, uyvyI420),
    xf("UYVY", "YV12", 0b10100000, 0, 0, uyvyI420),
    xf("UYVY", "Y42B", 0b10111000, 0, 0, uyvyY42b),
    xf("UYVY", "Y444", 0b10111000, 0, 0, uyvyY444),
    xf("AYUV", "I420", 0b00111000, 1, 1, ayuvI420),
    xf("AYUV", "YV12", 0b00111000, 1, 1, ayuvI420),
    xf("AYUV", "Y42B", 0b10111000, 1, 0, ayuvY42b),
    xf("AYUV", "Y444", 0b10111000, 0, 0, ayuvY444),
    xf("v210", "I420", 0b10100000, 0, 0, v210I420),
    xf("v210", "YV12", 0b10100000, 0, 0, v210I420),
    xf("v210", "Y42B", 0b10100000, 0, 0, v210Y42b),
    xf("v210", "I420_10LE", 0b10100000, 0, 0, v210I420P10),
    xf("v210", "I422_10LE", 0b10100000, 0, 0, v210I422P10),
    xf("I420_10LE", "v210", 0b10100000, 0, 0, i420P10V210),
    xf("I422_10LE", "v210", 0b10111000, 0, 0, i422P10V210),
    xf("I420", "I420", 0b10011000, 0, 0, scalePlanes),
    xf("I420", "YV12", 0b10011000, 0, 0, scalePlanes),
    xf("I420", "Y41B", 0b00011000, 0, 0, scalePlanes),
    xf("I420", "Y42B", 0b00011000, 0, 0, scalePlanes),
    xf("I420", "Y444", 0b00011000, 0, 0, scalePlanes),
    xf("I420", "GRAY8", 0b00011000, 0, 0, scalePlanes),
    xf("I420", "A420", 0b00011010, 0, 0, scalePlanes),
    xf("I420", "YUV9", 0b00011000, 0, 0, scalePlanes),
    xf("I420", "YVU9", 0b00011000, 0, 0, scalePlanes),
    xf("YV12", "I420", 0b10011000, 0, 0, scalePlanes),
    xf("YV12", "YV12", 0b10011000, 0, 0, scalePlanes),
    xf("YV12", "Y41B", 0b00011000, 0, 0, scalePlanes),
    xf("YV12", "Y42B", 0b00011000, 0, 0, scalePlanes),
    xf("YV12", "Y444", 0b00011000, 0, 0, scalePlanes),
    xf("YV12", "GRAY8", 0b00011000, 0, 0, scalePlanes),
    xf("YV12", "A420", 0b00011010, 0, 0, scalePlanes),
    xf("YV12", "YUV9", 0b00011000, 0, 0, scalePlanes),
    xf("YV12", "YVU9", 0b00011000, 0, 0, scalePlanes),
    xf("Y41B", "I420", 0b00011000, 0, 0, scalePlanes),
    xf("Y41B", "YV12", 0b00011000, 0, 0, scalePlanes),
    xf("Y41B", "Y41B", 0b10011000, 0, 0, scalePlanes),
    xf("Y41B", "Y42B", 0b00011000, 0, 0, scalePlanes),
    xf("Y41B", "Y444", 0b00011000, 0, 0, scalePlanes),
    xf("Y41B", "GRAY8", 0b00011000, 0, 0, scalePlanes),
    xf("Y41B", "A420", 0b00011010, 0, 0, scalePlanes),
    xf("Y41B", "YUV9", 0b00011000, 0, 0, scalePlanes),
    xf("Y41B", "YVU9", 0b00011000, 0, 0, scalePlanes),
    xf("Y42B", "I420", 0b00011000, 0, 0, scalePlanes),
    xf("Y42B", "YV12", 0b00011000, 0, 0, scalePlanes),
    xf("Y42B", "Y41B", 0b00011000, 0, 0, scalePlanes),
    xf("Y42B", "Y42B", 0b10011000, 0, 0, scalePlanes),
    xf("Y42B", "Y444", 0b00011000, 0, 0, scalePlanes),
    xf("Y42B", "GRAY8", 0b00011000, 0, 0, scalePlanes),
    xf("Y42B", "A420", 0b00011010, 0, 0, scalePlanes),
    xf("Y42B", "YUV9", 0b00011000, 0, 0, scalePlanes),
    xf("Y42B", "YVU9", 0b00011000, 0, 0, scalePlanes),
    xf("Y444", "I420", 0b00011000, 0, 0, scalePlanes),
    xf("Y444", "YV12", 0b00011000, 0, 0, scalePlanes),
    xf("Y444", "Y41B", 0b00011000, 0, 0, scalePlanes),
    xf("Y444", "Y42B", 0b00011000, 0, 0, scalePlanes),
    xf("Y444", "Y444", 0b10011000, 0, 0, scalePlanes),
    xf("Y444", "GRAY8", 0b00011000, 0, 0, scalePlanes),
    xf("Y444", "A420", 0b00011010, 0, 0, scalePlanes),
    xf("Y444", "YUV9", 0b00011000, 0, 0, scalePlanes),
    xf("Y444", "YVU9", 0b00011000, 0, 0, scalePlanes),
    xf("GRAY8", "I420", 0b00011000, 0, 0, scalePlanes),
    xf("GRAY8", "YV12", 0b00011000, 0, 0, scalePlanes),
    xf("GRAY8", "Y41B", 0b00011000, 0, 0, scalePlanes),
    xf("GRAY8", "Y42B", 0b00011000, 0, 0, scalePlanes),
    xf("GRAY8", "Y444", 0b00011000, 0, 0, scalePlanes),
    xf("GRAY8", "GRAY8", 0b10011000, 0, 0, scalePlanes),
    xf("GRAY8", "A420", 0b00011010, 0, 0, scalePlanes),
    xf("GRAY8", "YUV9", 0b00011000, 0, 0, scalePlanes),
    xf("GRAY8", "YVU9", 0b00011000, 0, 0, scalePlanes),
    xf("A420", "I420", 0b00011000, 0, 0, scalePlanes),
    xf("A420", "YV12", 0b00011000, 0, 0, scalePlanes),
    xf("A420", "Y41B", 0b00011000, 0, 0, scalePlanes),
    xf("A420", "Y42B", 0b00011000, 0, 0, scalePlanes),
    xf("A420", "Y444", 0b00011000, 0, 0, scalePlanes),
    xf("A420", "GRAY8", 0b00011000, 0, 0, scalePlanes),
    xf("A420", "A420", 0b10011100, 0, 0, scalePlanes),
    xf("A420", "YUV9", 0b00011000, 0, 0, scalePlanes),
    xf("A420", "YVU9", 0b00011000, 0, 0, scalePlanes),
    xf("YUV9", "I420", 0b00011000, 0, 0, scalePlanes),
    xf("YUV9", "YV12", 0b00011000, 0, 0, scalePlanes),
    xf("YUV9", "Y41B", 0b00011000, 0, 0, scalePlanes),
    xf("YUV9", "Y42B", 0b00011000, 0, 0, scalePlanes),
    xf("YUV9", "Y444", 0b00011000, 0, 0, scalePlanes),
    xf("YUV9", "GRAY8", 0b00011000, 0, 0, scalePlanes),
    xf("YUV9", "A420", 0b00011010, 0, 0, scalePlanes),
    xf("YUV9", "YUV9", 0b10011000, 0, 0, scalePlanes),
    xf("YUV9", "YVU9", 0b10011000, 0, 0, scalePlanes),
    xf("YVU9", "I420", 0b00011000, 0, 0, scalePlanes),
    xf("YVU9", "YV12", 0b00011000, 0, 0, scalePlanes),
    xf("YVU9", "Y41B", 0b00011000, 0, 0, scalePlanes),
    xf("YVU9", "Y42B", 0b00011000, 0, 0, scalePlanes),
    xf("YVU9", "Y444", 0b00011000, 0, 0, scalePlanes),
    xf("YVU9", "GRAY8", 0b00011000, 0, 0, scalePlanes),
    xf("YVU9", "A420", 0b00011010, 0, 0, scalePlanes),
    xf("YVU9", "YUV9", 0b10011000, 0, 0, scalePlanes),
    xf("YVU9", "YVU9", 0b10011000, 0, 0, scalePlanes),
    xf("NV12", "NV12", 0b10011000, 0, 0, scalePlanes),
    xf("NV12", "NV16", 0b10011000, 0, 0, scalePlanes),
    xf("NV12", "NV24", 0b10011000, 0, 0, scalePlanes),
    xf("NV21", "NV21", 0b10011000, 0, 0, scalePlanes),
    xf("NV16", "NV12", 0b10011000, 0, 0, scalePlanes),
    xf("NV16", "NV16", 0b10011000, 0, 0, scalePlanes),
    xf("NV16", "NV24", 0b10011000, 0, 0, scalePlanes),
    xf("NV61", "NV61", 0b10011000, 0, 0, scalePlanes),
    xf("NV24", "NV12", 0b10011000, 0, 0, scalePlanes),
    xf("NV24", "NV16", 0b10011000, 0, 0, scalePlanes),
    xf("NV24", "NV24", 0b10011000, 0, 0, scalePlanes),
    xf("AYUV", "ARGB", 0b11111100, 0, 0, ayuvArgb),
    xf("AYUV", "BGRA", 0b11111100, 0, 0, ayuvBgra),
    xf("AYUV", "xRGB", 0b11111000, 0, 0, ayuvArgb),
    xf("AYUV", "BGRx", 0b11111000, 0, 0, ayuvBgra),
    xf("AYUV", "ABGR", 0b11111100, 0, 0, ayuvAbgr),
    xf("AYUV", "RGBA", 0b11111100, 0, 0, ayuvRgba),
    xf("AYUV", "xBGR", 0b11111000, 0, 0, ayuvAbgr),
    xf("AYUV", "RGBx", 0b11111000, 0, 0, ayuvRgba),
    xf("I420", "BGRA", 0b01111000, 0, 0, i420Bgra),
    xf("I420", "BGRx", 0b01111000, 0, 0, i420Bgra),
    xf("YV12", "BGRA", 0b01111000, 0, 0, i420Bgra),
    xf("YV12", "BGRx", 0b01111000, 0, 0, i420Bgra),
    xf("I420", "ARGB", 0b01111000, 0, 0, i420Argb),
    xf("I420", "xRGB", 0b01111000, 0, 0, i420Argb),
    xf("YV12", "ARGB", 0b01111000, 0, 0, i420Argb),
    xf("YV12", "xRGB", 0b01111000, 0, 0, i420Argb),
    xf("I420", "ABGR", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "xBGR", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "RGBA", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "RGBx", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "RGB", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "BGR", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "RGB15", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "BGR15", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "RGB16", 0b01111000, 0, 0, i420PackArgb),
    xf("I420", "BGR16", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "ABGR", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "xBGR", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "RGBA", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "RGBx", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "RGB", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "BGR", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "RGB15", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "BGR15", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "RGB16", 0b01111000, 0, 0, i420PackArgb),
    xf("YV12", "BGR16", 0b01111000, 0, 0, i420PackArgb),
    xf("A420", "ABGR", 0b01111100, 0, 0, a420PackArgb),
    xf("A420", "RGBA", 0b01111100, 0, 0, a420PackArgb),
    xf("A420", "BGRA", 0b01111100, 0, 0, a420Bgra),
    xf("A420", "BGRx", 0b01111000, 0, 0, i420Bgra),
    xf("A420", "xBGR", 0b01111000, 0, 0, i420PackArgb),
    xf("A420", "RGBx", 0b01111000, 0, 0, i420PackArgb),
    xf("A420", "RGB", 0b01111000, 0, 0, i420PackArgb),
    xf("A420", "BGR", 0b01111000, 0, 0, i420PackArgb),
    xf("A420", "RGB15", 0b01111000, 0, 0, i420PackArgb),
    xf("A420", "BGR16", 0b01111000, 0, 0, i420PackArgb),
    xf("GBR", "GBR", 0b10011000, 0, 0, scalePlanes),
    xf("GBRA", "GBRA", 0b10011100, 0, 0, scalePlanes),
    xf("RGBP", "RGBP", 0b10011000, 0, 0, scalePlanes),
    xf("BGRP", "BGRP", 0b10011000, 0, 0, scalePlanes),
    xf("YVYU", "YVYU", 0b10011000, 0, 0, scalePlanes),
    xf("RGB15", "RGB15", 0b10011000, 0, 0, scalePlanes),
    xf("RGB16", "RGB16", 0b10011000, 0, 0, scalePlanes),
    xf("BGR15", "BGR15", 0b10011000, 0, 0, scalePlanes),
    xf("BGR16", "BGR16", 0b10011000, 0, 0, scalePlanes),
    xf("RGB", "RGB", 0b10011000, 0, 0, scalePlanes),
    xf("BGR", "BGR", 0b10011000, 0, 0, scalePlanes),
    xf("v308", "v308", 0b10011000, 0, 0, scalePlanes),
    xf("IYU2", "IYU2", 0b10011000, 0, 0, scalePlanes),
    xf("ARGB", "ARGB", 0b10011100, 0, 0, scalePlanes),
    xf("xRGB", "xRGB", 0b10011000, 0, 0, scalePlanes),
    xf("ABGR", "ABGR", 0b10011100, 0, 0, scalePlanes),
    xf("xBGR", "xBGR", 0b10011000, 0, 0, scalePlanes),
    xf("RGBA", "RGBA", 0b10011100, 0, 0, scalePlanes),
    xf("RGBx", "RGBx", 0b10011000, 0, 0, scalePlanes),
    xf("BGRA", "BGRA", 0b10011100, 0, 0, scalePlanes),
    xf("BGRx", "BGRx", 0b10011000, 0, 0, scalePlanes),
    xf("ARGB64", "ARGB64", 0b10011100, 0, 0, scalePlanes),
    xf("AYUV64", "AYUV64", 0b10011100, 0, 0, scalePlanes),
    xf("GRAY16_LE", "GRAY16_LE", 0b10011000, 0, 0, scalePlanes),
    xf("GRAY16_BE", "GRAY16_BE", 0b10011000, 0, 0, scalePlanes),
};

pub fn lookup(conv: *Conv) bool {
    const in = &conv.in_info;
    const out = &conv.out_info;
    const width = in.width;
    const height = cv.fieldHeight(in);
    if (cv.ditherQuantization(conv) != 1) return false;
    const same_size = width == conv.out_width and height == conv.out_height;
    if (cv.gammaMode(conv) == c.GST_VIDEO_GAMMA_MODE_REMAP and (!same_size or color.gst_video_transfer_function_is_equivalent(in.colorimetry.transfer, in.finfo[0].bits, out.colorimetry.transfer, out.finfo[0].bits) == 0)) return false;
    const need_copy = conv.alpha_mode & cv.ALPHA_COPY != 0;
    const need_set = conv.alpha_mode & cv.ALPHA_SET != 0;
    const need_mult = conv.alpha_mode & cv.ALPHA_MULT != 0;
    const same_matrix = cv.matrixMode(conv) == c.GST_VIDEO_MATRIX_MODE_NONE or in.colorimetry.matrix == out.colorimetry.matrix;
    const same_primaries = cv.primariesMode(conv) == c.GST_VIDEO_PRIMARIES_MODE_NONE or color.gst_video_color_primaries_is_equivalent(in.colorimetry.primaries, out.colorimetry.primaries) != 0;
    const interlaced = cv.isInterlaced(in) or cv.isInterlaced(out);
    const crop = conv.in_x != 0 or conv.in_y != 0 or conv.in_width < conv.in_maxwidth or conv.in_height < conv.in_maxheight;
    const border = conv.out_x != 0 or conv.out_y != 0 or conv.out_width < conv.out_maxwidth or conv.out_height < conv.out_maxheight;
    const fin = in.finfo[0].format;
    const fout = out.finfo[0].format;
    for (table) |t| {
        if (t.in != fin or t.out != fout) continue;
        if (t.flags & KI == 0 and interlaced) continue;
        if (t.flags & CM == 0 and !(same_matrix and same_primaries)) continue;
        if (t.flags & KS != 0 and !same_size) continue;
        if (t.wa & width != 0 or t.ha & height != 0) continue;
        if (t.flags & CROP == 0 and crop) continue;
        if (t.flags & BORDER == 0 and border) continue;
        if (t.flags & ACOPY == 0 and need_copy) continue;
        if (t.flags & ASET == 0 and need_set) continue;
        if (t.flags & AMULT == 0 and need_mult) continue;
        if (t.flags & CM != 0) cv.computeMatrix(conv);
        conv.convert = t.f;
        const n = cv.nThreads(conv);
        const tl: [*][*]u16 = @ptrCast(@alignCast(c.g_malloc(@sizeOf([*]u16) * n)));
        for (0..n) |j| tl[j] = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(u16) * cnt(width + 8) * 4)));
        conv.tmpline = tl;
        if (t.flags & KS == 0 and !setupScale(conv)) return false;
        if (border) cv.setupBorderline(conv);
        return true;
    }
    return false;
}
