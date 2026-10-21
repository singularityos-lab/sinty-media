const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const format = @import("format.zig");
const enums = @import("enumtypes.zig");
const bessel = @import("bessel.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const libm = @import("../libm.zig");
const sin = libm.sin;
const cos = libm.cos;
const sqrt = libm.sqrt;
const pow = libm.pow;
const floor = libm.floor;

const PI = 3.14159265358979323846;
const ALIGN = 16;
const OVERREAD = 16;

const Kaiser = struct { cutoff: f64, down: f64, stop: f64, tr: f64 };
const KAISER = [_]Kaiser{
    .{ .cutoff = 0.860, .down = 0.96511, .stop = 60, .tr = 0.7 },
    .{ .cutoff = 0.880, .down = 0.96591, .stop = 65, .tr = 0.29 },
    .{ .cutoff = 0.910, .down = 0.96923, .stop = 70, .tr = 0.145 },
    .{ .cutoff = 0.920, .down = 0.97600, .stop = 80, .tr = 0.105 },
    .{ .cutoff = 0.940, .down = 0.97979, .stop = 85, .tr = 0.087 },
    .{ .cutoff = 0.940, .down = 0.98085, .stop = 95, .tr = 0.077 },
    .{ .cutoff = 0.945, .down = 0.99471, .stop = 100, .tr = 0.068 },
    .{ .cutoff = 0.950, .down = 1.0, .stop = 105, .tr = 0.055 },
    .{ .cutoff = 0.960, .down = 1.0, .stop = 110, .tr = 0.045 },
    .{ .cutoff = 0.968, .down = 1.0, .stop = 115, .tr = 0.039 },
    .{ .cutoff = 0.975, .down = 1.0, .stop = 120, .tr = 0.0305 },
};

const Blackman = struct { n_taps: c.gint, cutoff: f64 };
const BLACKMAN = [_]Blackman{ .{ .n_taps = 8, .cutoff = 0.5 }, .{ .n_taps = 16, .cutoff = 0.6 }, .{ .n_taps = 24, .cutoff = 0.72 }, .{ .n_taps = 32, .cutoff = 0.8 }, .{ .n_taps = 48, .cutoff = 0.85 }, .{ .n_taps = 64, .cutoff = 0.90 }, .{ .n_taps = 80, .cutoff = 0.92 }, .{ .n_taps = 96, .cutoff = 0.933 }, .{ .n_taps = 128, .cutoff = 0.950 }, .{ .n_taps = 148, .cutoff = 0.955 }, .{ .n_taps = 160, .cutoff = 0.960 } };
const OVERSAMPLE = [_]c.gint{ 4, 4, 4, 8, 8, 16, 16, 16, 16, 32, 32 };

const DEFAULT_QUALITY = c.GST_AUDIO_RESAMPLER_QUALITY_DEFAULT;

const ConvertTaps = *const fn ([*]f64, ?*anyopaque, f64, c.gint) void;
const Interpolate = *const fn (?*anyopaque, ?*const anyopaque, c.gint, ?*const anyopaque, c.gint) void;
const Resample = *const fn (*R, [*c]c.gpointer, usize, [*c]c.gpointer, usize, *usize) void;
const Deinterleave = *const fn (*R, [*c]c.gpointer, [*c]c.gpointer, usize) void;

const R = struct {
    method: c.GstAudioResamplerMethod,
    flags: c.GstAudioResamplerFlags,
    format: c.GstAudioFormat,
    options: ?*c.GstStructure,
    format_index: c.gint,
    channels: c.gint,
    in_rate: c.gint,
    out_rate: c.gint,
    bps: c.gint,
    ostride: c.gint,
    filter_mode: c.GstAudioResamplerFilterMode,
    filter_threshold: c.guint,
    filter_interpolation: c.GstAudioResamplerFilterInterpolation,
    cutoff: f64,
    kaiser_beta: f64,
    b: f64,
    c: f64,
    tmp_taps: ?[*]f64,
    oversample: c.gint,
    n_taps: c.gint,
    taps: ?[*]u8,
    taps_mem: ?*anyopaque,
    taps_stride: usize,
    n_phases: c.gint,
    alloc_taps: c.gint,
    alloc_phases: c.gint,
    cached_phases: ?[*]?*anyopaque,
    cached_taps: ?[*]u8,
    cached_taps_mem: ?*anyopaque,
    cached_taps_stride: usize,
    convert_taps: ConvertTaps,
    interpolate: Interpolate,
    deinterleave: Deinterleave,
    resample: Resample,
    blocks: c.gint,
    inc: c.gint,
    samp_inc: c.gint,
    samp_frac: c.gint,
    samp_index: c.gint,
    samp_phase: c.gint,
    skip: c.gint,
    samples: ?*anyopaque,
    samples_len: usize,
    samples_avail: usize,
    sbuf: [*c]c.gpointer,
};

fn of(r: anytype) *R {
    return @ptrCast(@alignCast(r));
}

fn optDouble(o: ?*c.GstStructure, name: [*c]const u8, def: f64) f64 {
    var v: f64 = 0;
    if (o == null or c.gst_structure_get_double(o, name, &v) == 0) return def;
    return v;
}

fn optInt(o: ?*c.GstStructure, name: [*c]const u8, def: c.gint) c.gint {
    var v: c.gint = 0;
    if (o == null or c.gst_structure_get_int(o, name, &v) == 0) return def;
    return v;
}

fn optEnum(o: ?*c.GstStructure, name: [*c]const u8, t: c.GType, def: c.gint) c.gint {
    var v: c.gint = 0;
    if (o == null or c.gst_structure_get_enum(o, name, t, &v) == 0) return def;
    return v;
}

fn linearTap(x: f64, n_taps: c.gint) f64 {
    return @as(f64, @floatFromInt(@divTrunc((n_taps + 1) & ~@as(c.gint, 1), 2))) - @abs(x);
}

fn cubicTap(x: f64, n_taps: c.gint, b: f64, cc: f64) f64 {
    const a = @abs(x * 4.0) / @as(f64, @floatFromInt(n_taps));
    const a2 = a * a;
    const a3 = a2 * a;
    if (a <= 1.0) return ((12.0 - 9.0 * b - 6.0 * cc) * a3 + (-18.0 + 12.0 * b + 6.0 * cc) * a2 + (6.0 - 2.0 * b)) / 6.0;
    if (a <= 2.0) return ((-b - 6.0 * cc) * a3 + (6.0 * b + 30.0 * cc) * a2 + (-12.0 * b - 48.0 * cc) * a + (8.0 * b + 24.0 * cc)) / 6.0;
    return 0.0;
}

fn blackmanTap(x: f64, n_taps: c.gint, fc: f64) f64 {
    const y = PI * x;
    const s = if (y == 0.0) fc else sin(y * fc) / y;
    const w = 2.0 * y / @as(f64, @floatFromInt(n_taps)) + PI;
    return s * (0.3635819 - 0.4891775 * cos(w) + 0.1365995 * cos(2 * w) - 0.0106411 * cos(3 * w));
}

fn kaiserTap(x: f64, n_taps: c.gint, fc: f64, beta: f64) f64 {
    const y = PI * x;
    const s = if (y == 0.0) fc else sin(y * fc) / y;
    const w = 2.0 * x / @as(f64, @floatFromInt(n_taps));
    const m = 1 - w * w;
    return s * bessel.besselI0(beta * sqrt(if (m > 0) m else 0));
}

fn convertInt(comptime T: type, comptime p: u6) ConvertTaps {
    return struct {
        fn f(tmp: [*]f64, taps: ?*anyopaque, weight: f64, n_taps: c.gint) void {
            const one: i64 = (@as(i64, 1) << p) - 1;
            const t: [*]T = @ptrCast(@alignCast(taps));
            const mult: f64 = @floatFromInt(one);
            var l: f64 = 0.0;
            var h: f64 = 1.0;
            var offset: f64 = 0.5;
            const n: usize = @intCast(n_taps);
            for (0..32) |_| {
                var sum: i64 = 0;
                for (0..n) |j| sum = @intFromFloat(@as(f64, @floatFromInt(sum)) + floor(offset + tmp[j] * mult / weight));
                if (sum == one) break;
                if (l == h) break;
                if (sum < one) {
                    if (offset > l) l = offset;
                    offset += (h - l) / 2;
                } else {
                    if (offset < h) h = offset;
                    offset -= (h - l) / 2;
                }
            }
            for (0..n) |j| t[j] = @intFromFloat(floor(offset + tmp[j] * mult / weight));
        }
    }.f;
}

fn convertFloat(comptime T: type) ConvertTaps {
    return struct {
        fn f(tmp: [*]f64, taps: ?*anyopaque, weight: f64, n_taps: c.gint) void {
            const t: [*]T = @ptrCast(@alignCast(taps));
            for (0..@intCast(n_taps)) |i| t[i] = @floatCast(tmp[i] / weight);
        }
    }.f;
}

fn makeTaps(r: *R, res: ?*anyopaque, x: f64, n_taps: c.gint) void {
    var weight: f64 = 0.0;
    const tmp = r.tmp_taps.?;
    const n: usize = @intCast(n_taps);
    for (0..n) |i| {
        const xi = x + @as(f64, @floatFromInt(i));
        const v: f64 = switch (r.method) {
            c.GST_AUDIO_RESAMPLER_METHOD_LINEAR => linearTap(xi, r.n_taps),
            c.GST_AUDIO_RESAMPLER_METHOD_CUBIC => cubicTap(xi, r.n_taps, r.b, r.c),
            c.GST_AUDIO_RESAMPLER_METHOD_BLACKMAN_NUTTALL => blackmanTap(xi, r.n_taps, r.cutoff),
            c.GST_AUDIO_RESAMPLER_METHOD_KAISER => kaiserTap(xi, r.n_taps, r.cutoff, r.kaiser_beta),
            else => break,
        };
        tmp[i] = v;
        weight += v;
    }
    r.convert_taps(tmp, res, weight, n_taps);
}

fn Int2(comptime T: type) type {
    return if (T == i16) i32 else i64;
}

fn prec(comptime T: type) u6 {
    return if (T == i16) 15 else 31;
}

fn coeffLinear(comptime T: type, num: c.gint, denom: c.gint, ic: [*]T) void {
    if (@typeInfo(T) == .int) {
        const P = prec(T);
        const PW: std.math.Log2Int(Int2(T)) = @intCast(P);
        const x: T = @truncate(@divTrunc(@as(i64, num) << P, denom));
        ic[0] = x;
        ic[2] = x;
        const y: T = @truncate(@as(Int2(T), (@as(Int2(T), 1) << PW) - 1) - x);
        ic[1] = y;
        ic[3] = y;
    } else {
        const x: T = @as(T, @floatFromInt(num)) / @as(T, @floatFromInt(denom));
        ic[0] = x;
        ic[2] = x;
        ic[1] = 1.0 - x;
        ic[3] = 1.0 - x;
    }
}

fn fl(comptime T: type, comptime v: f32) T {
    return @as(T, v);
}

fn coeffCubic(comptime T: type, num: c.gint, denom: c.gint, ic: [*]T) void {
    if (@typeInfo(T) == .int) {
        const W = Int2(T);
        const P0 = prec(T);
        const P: std.math.Log2Int(W) = @intCast(P0);
        const one: W = (@as(W, 1) << P) - 1;
        const x: W = @truncate(@divTrunc(@as(i64, num) << P0, denom));
        const x2: W = (x *% x) >> P;
        const x3: W = (x2 *% x) >> P;
        ic[0] = @truncate(@divTrunc((x3 -% x) << P, 6) >> P);
        ic[1] = @truncate(x +% ((x2 -% x3) >> 1));
        ic[3] = @truncate(-%(@divTrunc(x << P, 3) >> P) +% (x2 >> 1) -% (@divTrunc(x3 << P, 6) >> P));
        ic[2] = @truncate(one -% @as(W, ic[0]) -% @as(W, ic[1]) -% @as(W, ic[3]));
    } else {
        const x: T = @as(T, @floatFromInt(num)) / @as(T, @floatFromInt(denom));
        const x2 = x * x;
        const x3 = x2 * x;
        ic[0] = fl(T, 0.16667) * (x3 - x);
        ic[1] = x + fl(T, 0.5) * (x2 - x3);
        ic[3] = fl(T, -0.33333) * x + fl(T, 0.5) * x2 - fl(T, 0.16667) * x3;
        ic[2] = 1.0 - ic[0] - ic[1] - ic[3];
    }
}

fn rows(comptime T: type, base: ?*const anyopaque, stride: c.gint, comptime n: usize) [n][*]const T {
    var out: [n][*]const T = undefined;
    const b: [*]const u8 = @ptrCast(base);
    inline for (0..n) |k| out[k] = @ptrCast(@alignCast(b + k * @as(usize, @intCast(stride))));
    return out;
}

fn V(comptime T: type, comptime n: usize) type {
    return @Vector(n, T);
}

fn load(comptime T: type, comptime n: usize, p: [*]const T) V(T, n) {
    return @as(*align(1) const V(T, n), @ptrCast(p)).*;
}

fn store(comptime T: type, comptime n: usize, p: [*]T, v: V(T, n)) void {
    @as(*align(1) V(T, n), @ptrCast(p)).* = v;
}

fn sat16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn madd(a: V(i16, 8), b: V(i16, 8)) V(i32, 4) {
    var r: V(i32, 4) = undefined;
    inline for (0..4) |k| r[k] = @as(i32, a[2 * k]) * @as(i32, b[2 * k]) +% @as(i32, a[2 * k + 1]) * @as(i32, b[2 * k + 1]);
    return r;
}

fn hsum32(s: V(i32, 4)) i32 {
    return (s[0] +% s[3]) +% (s[1] +% s[2]);
}

fn interpolateFn(comptime T: type, comptime cubic: bool) Interpolate {
    return struct {
        fn f(op: ?*anyopaque, ap: ?*const anyopaque, len: c.gint, icp: ?*const anyopaque, astride: c.gint) void {
            const o: [*]T = @ptrCast(@alignCast(op));
            const ic: [*]const T = @ptrCast(@alignCast(icp));
            const n: usize = @intCast(@max(len, 0));
            if (T == f32 or T == f64) {
                const L = if (T == f32) 4 else 2;
                const step: usize = if (cubic) L else 2 * L;
                const cr = rows(T, ap, astride, if (cubic) 4 else 2);
                var i: usize = 0;
                while (i < n) : (i += step) {
                    var j: usize = i;
                    while (j < i + step) : (j += L) {
                        if (cubic) {
                            const t0 = load(T, L, cr[0] + j) * @as(V(T, L), @splat(ic[0]));
                            const t1 = load(T, L, cr[1] + j) * @as(V(T, L), @splat(ic[1]));
                            const t2 = load(T, L, cr[2] + j) * @as(V(T, L), @splat(ic[2]));
                            const t3 = load(T, L, cr[3] + j) * @as(V(T, L), @splat(ic[3]));
                            store(T, L, o + j, (t0 + t1) + (t2 + t3));
                        } else {
                            const t1 = load(T, L, cr[0] + j) * @as(V(T, L), @splat(ic[0]));
                            const t2 = load(T, L, cr[1] + j) * @as(V(T, L), @splat(ic[1]));
                            store(T, L, o + j, t1 + t2);
                        }
                    }
                }
            } else if (T == i16) {
                const cr = rows(i16, ap, astride, if (cubic) 4 else 2);
                var i: usize = 0;
                while (i < n) : (i += 8) {
                    for (0..8) |k| {
                        const j = i + k;
                        var v: i32 = @as(i32, cr[0][j]) * ic[0] +% @as(i32, cr[1][j]) * ic[1];
                        if (cubic) v +%= @as(i32, cr[2][j]) * ic[2] +% @as(i32, cr[3][j]) * ic[3];
                        o[j] = sat16((v +% (1 << 14)) >> 15);
                    }
                }
            } else {
                const cr = rows(i32, ap, astride, if (cubic) 4 else 2);
                for (0..n) |i| {
                    if (cubic) {
                        var t: i64 = @as(i64, cr[0][i]) *% ic[0] +% @as(i64, cr[1][i]) *% ic[1] +% @as(i64, cr[2][i]) *% ic[2] +% @as(i64, cr[3][i]) *% ic[3];
                        t = (t +% (1 << 30)) >> 31;
                        o[i] = @intCast(std.math.clamp(t, std.math.minInt(i32), std.math.maxInt(i32)));
                    } else {
                        const t: i64 = (@as(i64, cr[0][i]) -% @as(i64, cr[1][i])) *% ic[0] +% (@as(i64, cr[1][i]) << 31);
                        o[i] = @truncate((t +% (1 << 30)) >> 31);
                    }
                }
            }
        }
    }.f;
}

const Inter = enum { nearest, full, linear, cubic };

fn GetTaps(comptime T: type) type {
    return struct {
        fn advance(r: *R, idx: *c.gint, phase: *c.gint) void {
            idx.* += r.samp_inc;
            phase.* += r.samp_frac;
            if (phase.* >= r.out_rate) {
                phase.* -= r.out_rate;
                idx.* += 1;
            }
        }

        fn full(r: *R, idx: *c.gint, phase_p: *c.gint, _: [*]T) ?*anyopaque {
            const out_rate = r.out_rate;
            const n_phases = r.n_phases;
            const phase: usize = @intCast(if (n_phases == out_rate) phase_p.* else @divTrunc(@as(i64, phase_p.*) * n_phases, out_rate));
            var res = r.cached_phases.?[phase];
            if (res == null) {
                res = r.cached_taps.? + phase * r.cached_taps_stride;
                if (r.filter_interpolation == c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_NONE) {
                    const n_taps = r.n_taps;
                    const x = 1.0 - @as(f64, @floatFromInt(@divTrunc(n_taps, 2))) - @as(f64, @floatFromInt(phase)) / @as(f64, @floatFromInt(n_phases));
                    makeTaps(r, res, x, n_taps);
                } else {
                    const pos: c.gint = @as(c.gint, @intCast(phase)) * r.oversample;
                    const offset = (r.oversample - 1) - @divTrunc(pos, n_phases);
                    const frac = @rem(pos, n_phases);
                    const taps = r.taps.? + @as(usize, @intCast(offset)) * r.taps_stride;
                    var ic: [4]T = undefined;
                    if (r.filter_interpolation == c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC) coeffCubic(T, frac, n_phases, &ic) else coeffLinear(T, frac, n_phases, &ic);
                    r.interpolate(res, taps, r.n_taps, &ic, @intCast(r.taps_stride));
                }
                r.cached_phases.?[phase] = res;
            }
            advance(r, idx, phase_p);
            return res;
        }

        fn interp(comptime cubic: bool) *const fn (*R, *c.gint, *c.gint, [*]T) ?*anyopaque {
            return struct {
                fn f(r: *R, idx: *c.gint, phase: *c.gint, ic: [*]T) ?*anyopaque {
                    const out_rate = r.out_rate;
                    const pos = phase.* * r.oversample;
                    const offset = (r.oversample - 1) - @divTrunc(pos, out_rate);
                    const frac = @rem(pos, out_rate);
                    const res = r.taps.? + @as(usize, @intCast(offset)) * r.taps_stride;
                    if (cubic) coeffCubic(T, frac, out_rate, ic) else coeffLinear(T, frac, out_rate, ic);
                    advance(r, idx, phase);
                    return res;
                }
            }.f;
        }
    };
}

fn innerFloat(comptime T: type, comptime inter: Inter, o: *T, a: [*]const T, b: ?*const anyopaque, len: usize, ic: [*]const T, bstride: c.gint) void {
    const L = if (T == f32) 4 else 2;
    const VT = V(T, L);
    const zero: VT = @splat(0);
    switch (inter) {
        .full => {
            const bb: [*]const T = @ptrCast(@alignCast(b));
            var sum = zero;
            var i: usize = 0;
            while (i < len) : (i += 8) {
                var j: usize = 0;
                while (j < 8) : (j += L) sum = sum + load(T, L, a + i + j) * load(T, L, bb + i + j);
            }
            o.* = hsumF(T, sum);
        },
        .linear => {
            const cr = rows(T, b, bstride, 2);
            var s0 = zero;
            var s1 = zero;
            const step: usize = if (T == f32) 8 else 4;
            var i: usize = 0;
            while (i < len) : (i += step) {
                var j: usize = 0;
                while (j < step) : (j += L) {
                    const t = load(T, L, a + i + j);
                    s0 = s0 + t * load(T, L, cr[0] + i + j);
                    s1 = s1 + t * load(T, L, cr[1] + i + j);
                }
            }
            s0 = (s0 - s1) * @as(VT, @splat(ic[0]));
            s0 = s0 + s1;
            o.* = hsumF(T, s0);
        },
        .cubic => {
            const cr = rows(T, b, bstride, 4);
            var s = [4]VT{ zero, zero, zero, zero };
            var i: usize = 0;
            while (i < len) : (i += L) {
                const t = load(T, L, a + i);
                inline for (0..4) |k| s[k] = s[k] + t * load(T, L, cr[k] + i);
            }
            inline for (0..4) |k| s[k] = s[k] * @as(VT, @splat(ic[k]));
            s[0] = s[0] + s[1];
            s[2] = s[2] + s[3];
            s[0] = s[0] + s[2];
            o.* = hsumF(T, s[0]);
        },
        .nearest => o.* = a[0],
    }
}

fn hsumF(comptime T: type, s: V(T, if (T == f32) 4 else 2)) T {
    if (T == f32) return (s[0] + s[2]) + (s[1] + s[3]);
    return s[0] + s[1];
}

fn innerI16(comptime inter: Inter, o: *i16, a: [*]const i16, b: ?*const anyopaque, len: usize, ic: [*]const i16, bstride: c.gint) void {
    const zero: V(i32, 4) = @splat(0);
    switch (inter) {
        .full => {
            const bb: [*]const i16 = @ptrCast(@alignCast(b));
            var sum = zero;
            var i: usize = 0;
            while (i < len) : (i += 16) {
                sum +%= madd(load(i16, 8, a + i), load(i16, 8, bb + i));
                sum +%= madd(load(i16, 8, a + i + 8), load(i16, 8, bb + i + 8));
            }
            o.* = sat16((hsum32(sum) +% (1 << 14)) >> 15);
        },
        .linear => {
            const cr = rows(i16, b, bstride, 2);
            var s0 = zero;
            var s1 = zero;
            var i: usize = 0;
            while (i < len) : (i += 16) {
                var j: usize = 0;
                while (j < 16) : (j += 8) {
                    const t = load(i16, 8, a + i + j);
                    s0 +%= madd(t, load(i16, 8, cr[0] + i + j));
                    s1 +%= madd(t, load(i16, 8, cr[1] + i + j));
                }
            }
            var r: V(i32, 4) = undefined;
            inline for (0..4) |k| r[k] = @as(i32, @as(i16, @truncate(s0[k] >> 15))) * ic[0] +% @as(i32, @as(i16, @truncate(s1[k] >> 15))) * ic[1];
            o.* = sat16((hsum32(r) +% (1 << 14)) >> 15);
        },
        .cubic => {
            const cr = rows(i16, b, bstride, 4);
            var s = [4]V(i32, 4){ zero, zero, zero, zero };
            var i: usize = 0;
            while (i < len) : (i += 8) {
                const t = load(i16, 8, a + i);
                inline for (0..4) |k| s[k] +%= madd(t, load(i16, 8, cr[k] + i));
            }
            var r: V(i32, 4) = undefined;
            inline for (0..4) |k| {
                const lane = (s[k][0] +% s[k][1]) +% (s[k][2] +% s[k][3]);
                r[k] = @as(i32, @as(i16, @truncate(lane >> 15))) * ic[k];
            }
            o.* = sat16((hsum32(r) +% (1 << 14)) >> 15);
        },
        .nearest => o.* = a[0],
    }
}

fn mul32(a: i32, b: i32) i64 {
    return @as(i64, a) * @as(i64, b);
}

fn innerI32(comptime inter: Inter, o: *i32, a: [*]const i32, b: ?*const anyopaque, len: usize, ic: [*]const i32, bstride: c.gint) void {
    const clampOut = struct {
        fn f(res: i64) i32 {
            const v = (res +% (1 << 30)) >> 31;
            return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
        }
    }.f;
    switch (inter) {
        .full => {
            const bb: [*]const i32 = @ptrCast(@alignCast(b));
            var l0: i64 = 0;
            var l1: i64 = 0;
            var i: usize = 0;
            while (i < len) : (i += 8) {
                var j: usize = 0;
                while (j < 8) : (j += 4) {
                    l0 +%= mul32(a[i + j], bb[i + j]);
                    l1 +%= mul32(a[i + j + 1], bb[i + j + 1]);
                    l0 +%= mul32(a[i + j + 2], bb[i + j + 2]);
                    l1 +%= mul32(a[i + j + 3], bb[i + j + 3]);
                }
            }
            o.* = clampOut(l0 +% l1);
        },
        .linear, .cubic => {
            const n = if (inter == .linear) 2 else 4;
            const cr = rows(i32, b, bstride, n);
            var s: [n][2]i64 = .{.{ 0, 0 }} ** n;
            var i: usize = 0;
            while (i < len) : (i += 4) {
                inline for (0..n) |k| {
                    s[k][0] +%= mul32(a[i], cr[k][i]);
                    s[k][1] +%= mul32(a[i + 1], cr[k][i + 1]);
                    s[k][0] +%= mul32(a[i + 2], cr[k][i + 2]);
                    s[k][1] +%= mul32(a[i + 3], cr[k][i + 3]);
                }
            }
            var m: [n][2]i64 = undefined;
            inline for (0..n) |k| inline for (0..2) |l| {
                const low: i32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(s[k][l])) >> 31)));
                m[k][l] = mul32(low, ic[k]);
            };
            var t0: i64 = undefined;
            var t1: i64 = undefined;
            if (n == 2) {
                t0 = m[0][0] +% m[1][0];
                t1 = m[0][1] +% m[1][1];
            } else {
                t0 = (m[0][0] +% m[1][0]) +% (m[2][0] +% m[3][0]);
                t1 = (m[0][1] +% m[1][1]) +% (m[2][1] +% m[3][1]);
            }
            o.* = clampOut(t0 +% t1);
        },
        .nearest => o.* = a[0],
    }
}

fn resampleFn(comptime T: type, comptime inter: Inter) Resample {
    return struct {
        fn f(r: *R, in: [*c]c.gpointer, in_len: usize, out: [*c]c.gpointer, out_len: usize, consumed: *usize) void {
            const n_taps: usize = @intCast(r.n_taps);
            const blocks: usize = @intCast(r.blocks);
            const ostride: usize = @intCast(r.ostride);
            var samp_index: c.gint = 0;
            var samp_phase: c.gint = 0;
            for (0..blocks) |ch| {
                const ip: [*]T = @ptrCast(@alignCast(in[ch]));
                var op: [*]T = if (ostride == 1) @ptrCast(@alignCast(out[ch])) else @as([*]T, @ptrCast(@alignCast(out[0]))) + ch;
                samp_index = r.samp_index;
                samp_phase = r.samp_phase;
                for (0..out_len) |_| {
                    const ipp = ip + @as(usize, @intCast(samp_index));
                    var ic: [4]T = undefined;
                    const taps: ?*anyopaque = switch (inter) {
                        .nearest => blk: {
                            GetTaps(T).advance(r, &samp_index, &samp_phase);
                            break :blk null;
                        },
                        .full => GetTaps(T).full(r, &samp_index, &samp_phase, &ic),
                        .linear => GetTaps(T).interp(false)(r, &samp_index, &samp_phase, &ic),
                        .cubic => GetTaps(T).interp(true)(r, &samp_index, &samp_phase, &ic),
                    };
                    if (T == i16) {
                        innerI16(inter, &op[0], ipp, taps, n_taps, &ic, @intCast(r.taps_stride));
                    } else if (T == i32) {
                        innerI32(inter, &op[0], ipp, taps, n_taps, &ic, @intCast(r.taps_stride));
                    } else innerFloat(T, inter, &op[0], ipp, taps, n_taps, &ic, @intCast(r.taps_stride));
                    op += ostride;
                }
                const si: usize = @intCast(samp_index);
                if (in_len > si) std.mem.copyForwards(T, ip[0 .. in_len - si], ip[si..in_len]);
            }
            consumed.* = @intCast(samp_index - r.samp_index);
            r.samp_index = 0;
            r.samp_phase = samp_phase;
        }
    }.f;
}

fn deinterleaveFn(comptime T: type) Deinterleave {
    return struct {
        fn f(r: *R, sbuf: [*c]c.gpointer, in: [*c]c.gpointer, frames: usize) void {
            const channels: usize = @intCast(r.channels);
            for (0..channels) |ch| {
                const s: [*]T = @as([*]T, @ptrCast(@alignCast(sbuf[ch]))) + r.samples_avail;
                if (in == null) {
                    @memset(s[0..frames], 0);
                } else {
                    const ip: [*]const T = @as([*]const T, @ptrCast(@alignCast(in[0]))) + ch;
                    for (0..frames) |i| s[i] = ip[i * channels];
                }
            }
        }
    }.f;
}

fn copyFn(r: *R, sbuf: [*c]c.gpointer, in: [*c]c.gpointer, frames: usize) void {
    const channels: usize = @intCast(r.channels);
    const bps: usize = @intCast(r.bps);
    for (0..channels) |ch| {
        const s: [*]u8 = @as([*]u8, @ptrCast(sbuf[ch])) + r.samples_avail * bps;
        if (in == null) {
            @memset(s[0 .. frames * bps], 0);
        } else @memcpy(s[0 .. frames * bps], @as([*]const u8, @ptrCast(in[ch]))[0 .. frames * bps]);
    }
}

const RESAMPLE = [16]Resample{
    resampleFn(i16, .nearest), resampleFn(i32, .nearest), resampleFn(f32, .nearest), resampleFn(f64, .nearest),
    resampleFn(i16, .full),    resampleFn(i32, .full),    resampleFn(f32, .full),    resampleFn(f64, .full),
    resampleFn(i16, .linear),  resampleFn(i32, .linear),  resampleFn(f32, .linear),  resampleFn(f64, .linear),
    resampleFn(i16, .cubic),   resampleFn(i32, .cubic),   resampleFn(f32, .cubic),   resampleFn(f64, .cubic),
};

const INTERPOLATE = [8]Interpolate{
    interpolateFn(i16, false), interpolateFn(i32, false), interpolateFn(f32, false), interpolateFn(f64, false),
    interpolateFn(i16, true),  interpolateFn(i32, true),  interpolateFn(f32, true),  interpolateFn(f64, true),
};

const CONVERT = [4]ConvertTaps{ convertInt(i16, 15), convertInt(i32, 31), convertFloat(f32), convertFloat(f64) };
const DEINTERLEAVE = [4]Deinterleave{ deinterleaveFn(i16), deinterleaveFn(i32), deinterleaveFn(f32), deinterleaveFn(f64) };

var init_once: usize = 0;

fn ensureInit() void {
    if (c.g_once_init_enter(&init_once) != 0) {
        _ = c._gst_debug_category_new("audio-resampler", 0, "audio-resampler object");
        c.g_once_init_leave(&init_once, 1);
    }
}

fn kaiserParams(r: *R) void {
    const q = KAISER[DEFAULT_QUALITY];
    var fc = q.cutoff;
    if (r.out_rate < r.in_rate) fc *= q.down;
    fc = optDouble(r.options, c.GST_AUDIO_RESAMPLER_OPT_CUTOFF, fc);
    const a = optDouble(r.options, c.GST_AUDIO_RESAMPLER_OPT_STOP_ATTENUATION, q.stop);
    const tr = optDouble(r.options, c.GST_AUDIO_RESAMPLER_OPT_TRANSITION_BANDWIDTH, q.tr);
    const b = if (a > 50) 0.1102 * (a - 8.7) else if (a >= 21) 0.5842 * pow(a - 21, 0.4) + 0.07886 * (a - 21) else 0.0;
    const dw = 2 * PI * tr;
    const n: c.gint = @intFromFloat((a - 8.0) / (2.285 * dw));
    r.kaiser_beta = b;
    r.n_taps = n + 1;
    r.cutoff = fc;
}

fn roundUp32(v: usize) usize {
    return (v + 31) & ~@as(usize, 31);
}

fn alignPtr(p: ?*anyopaque) [*]u8 {
    const a = @intFromPtr(p) + (ALIGN - 1);
    return @ptrFromInt(a & ~@as(usize, ALIGN - 1));
}

fn allocTaps(r: *R, bps: c.gint, n_taps: c.gint, n_phases: c.gint) void {
    if (r.alloc_taps >= n_taps and r.alloc_phases >= n_phases) return;
    r.tmp_taps = @ptrCast(@alignCast(c.g_realloc_n(r.tmp_taps, @intCast(n_taps), @sizeOf(f64))));
    r.taps_stride = roundUp32(@intCast(bps * (n_taps + OVERREAD)));
    c.g_free(r.taps_mem);
    r.taps_mem = c.g_malloc0(@as(usize, @intCast(n_phases)) * r.taps_stride + ALIGN - 1);
    r.taps = alignPtr(r.taps_mem);
    r.alloc_taps = n_taps;
    r.alloc_phases = n_phases;
}

fn allocCache(r: *R, bps: c.gint, n_taps: c.gint, n_phases: c.gint) void {
    r.tmp_taps = @ptrCast(@alignCast(c.g_realloc_n(r.tmp_taps, @intCast(n_taps), @sizeOf(f64))));
    r.cached_taps_stride = roundUp32(@intCast(bps * (n_taps + OVERREAD)));
    const phases_size = @sizeOf(usize) * @as(usize, @intCast(n_phases));
    c.g_free(r.cached_taps_mem);
    r.cached_taps_mem = c.g_malloc0(phases_size + @as(usize, @intCast(n_phases)) * r.cached_taps_stride + ALIGN - 1);
    r.cached_taps = alignPtr(@ptrCast(@as([*]u8, @ptrCast(r.cached_taps_mem)) + phases_size));
    r.cached_phases = @ptrCast(@alignCast(r.cached_taps_mem));
}

fn setupFunctions(r: *R) void {
    var index: usize = @intCast(r.format_index);
    if (r.in_rate == r.out_rate) {
        r.resample = RESAMPLE[index];
        return;
    }
    const fidx: usize = if (r.filter_interpolation == c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC) 4 else 0;
    r.interpolate = INTERPOLATE[index + fidx];
    if (r.method != c.GST_AUDIO_RESAMPLER_METHOD_NEAREST) {
        index += 4;
        if (r.filter_mode == c.GST_AUDIO_RESAMPLER_FILTER_MODE_INTERPOLATED) index += 4 + fidx;
    }
    r.resample = RESAMPLE[index];
}

fn calculateTaps(r: *R) void {
    var scale = true;
    var sinc = false;
    switch (r.method) {
        c.GST_AUDIO_RESAMPLER_METHOD_NEAREST => {
            r.n_taps = 2;
            scale = false;
        },
        c.GST_AUDIO_RESAMPLER_METHOD_LINEAR => r.n_taps = optInt(r.options, c.GST_AUDIO_RESAMPLER_OPT_N_TAPS, 2),
        c.GST_AUDIO_RESAMPLER_METHOD_CUBIC => {
            r.n_taps = optInt(r.options, c.GST_AUDIO_RESAMPLER_OPT_N_TAPS, 4);
            r.b = optDouble(r.options, c.GST_AUDIO_RESAMPLER_OPT_CUBIC_B, 1.0);
            r.c = optDouble(r.options, c.GST_AUDIO_RESAMPLER_OPT_CUBIC_C, 0.0);
        },
        c.GST_AUDIO_RESAMPLER_METHOD_BLACKMAN_NUTTALL => {
            const q = BLACKMAN[DEFAULT_QUALITY];
            r.n_taps = optInt(r.options, c.GST_AUDIO_RESAMPLER_OPT_N_TAPS, q.n_taps);
            r.cutoff = optDouble(r.options, c.GST_AUDIO_RESAMPLER_OPT_CUTOFF, q.cutoff);
            sinc = true;
        },
        c.GST_AUDIO_RESAMPLER_METHOD_KAISER => {
            kaiserParams(r);
            sinc = true;
        },
        else => {},
    }
    const in_rate = r.in_rate;
    const out_rate = r.out_rate;
    if (out_rate < in_rate and scale) {
        r.cutoff = r.cutoff * @as(f64, @floatFromInt(out_rate)) / @as(f64, @floatFromInt(in_rate));
        r.n_taps = @intCast(c.gst_util_uint64_scale_int(@intCast(r.n_taps), in_rate, out_rate));
    }
    var fi: c.GstAudioResamplerFilterInterpolation = undefined;
    if (sinc) {
        r.n_taps = (r.n_taps + 7) & ~@as(c.gint, 7);
        r.filter_mode = @intCast(optEnum(r.options, c.GST_AUDIO_RESAMPLER_OPT_FILTER_MODE, enums.gst_audio_resampler_filter_mode_get_type(), c.GST_AUDIO_RESAMPLER_FILTER_MODE_AUTO));
        r.filter_threshold = @bitCast(optInt(r.options, c.GST_AUDIO_RESAMPLER_OPT_FILTER_MODE_THRESHOLD, 1048576));
        fi = @intCast(optEnum(r.options, c.GST_AUDIO_RESAMPLER_OPT_FILTER_INTERPOLATION, enums.gst_audio_resampler_filter_interpolation_get_type(), c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC));
    } else {
        r.filter_mode = c.GST_AUDIO_RESAMPLER_FILTER_MODE_FULL;
        fi = c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_NONE;
    }
    var oversample: c.gint = 1;
    if (fi != c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_NONE) {
        var mult: c.gint = 2;
        oversample = optInt(r.options, c.GST_AUDIO_RESAMPLER_OPT_FILTER_OVERSAMPLE, 8);
        while (oversample > 1) {
            if (mult *% out_rate >= in_rate) break;
            mult *%= 2;
            oversample >>= 1;
        }
        if (fi == c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_LINEAR) oversample *= 11;
    }
    r.oversample = oversample;
    const n_taps = r.n_taps;
    const bps = r.bps;
    if (r.filter_mode == c.GST_AUDIO_RESAMPLER_FILTER_MODE_AUTO) {
        if (out_rate <= oversample and r.flags & c.GST_AUDIO_RESAMPLER_FLAG_VARIABLE_RATE == 0) {
            r.filter_mode = c.GST_AUDIO_RESAMPLER_FILTER_MODE_FULL;
        } else if (@as(c.guint, @bitCast(bps *% n_taps *% out_rate)) < r.filter_threshold) {
            r.filter_mode = c.GST_AUDIO_RESAMPLER_FILTER_MODE_FULL;
        } else r.filter_mode = c.GST_AUDIO_RESAMPLER_FILTER_MODE_INTERPOLATED;
    }
    if (r.filter_mode != c.GST_AUDIO_RESAMPLER_FILTER_MODE_FULL and fi == c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_NONE) fi = c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC;
    r.filter_interpolation = fi;
    if (r.filter_mode == c.GST_AUDIO_RESAMPLER_FILTER_MODE_FULL and r.method != c.GST_AUDIO_RESAMPLER_METHOD_NEAREST) {
        r.n_phases = out_rate;
        allocCache(r, bps, n_taps, out_rate);
    }
    if (r.filter_interpolation != c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_NONE) {
        const isz: c.gint = if (r.filter_interpolation == c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC) 4 else 2;
        allocTaps(r, bps, n_taps, oversample + isz);
        var i: c.gint = 0;
        while (i < oversample + isz) : (i += 1) {
            const x = @as(f64, @floatFromInt(-@divTrunc(n_taps, 2))) + @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(oversample));
            makeTaps(r, r.taps.? + @as(usize, @intCast(i)) * r.taps_stride, x, n_taps);
        }
    }
}

pub export fn gst_audio_resampler_options_set_quality(method: c.GstAudioResamplerMethod, quality: c.guint, in_rate: c.gint, out_rate: c.gint, options: ?*c.GstStructure) void {
    const fname = "gst_audio_resampler_options_set_quality";
    const NONE = @as(?*anyopaque, null);
    if (!check.that(options != null, fname, "options != NULL")) return;
    if (!check.that(quality <= c.GST_AUDIO_RESAMPLER_QUALITY_MAX, fname, "quality <= GST_AUDIO_RESAMPLER_QUALITY_MAX")) return;
    if (!check.that(in_rate > 0 and out_rate > 0, fname, "in_rate > 0 && out_rate > 0")) return;
    switch (method) {
        c.GST_AUDIO_RESAMPLER_METHOD_LINEAR => c.gst_structure_set(options, c.GST_AUDIO_RESAMPLER_OPT_N_TAPS, c.G_TYPE_INT, @as(c.gint, 2), NONE),
        c.GST_AUDIO_RESAMPLER_METHOD_CUBIC => c.gst_structure_set(options, c.GST_AUDIO_RESAMPLER_OPT_N_TAPS, c.G_TYPE_INT, @as(c.gint, 4), c.GST_AUDIO_RESAMPLER_OPT_CUBIC_B, c.G_TYPE_DOUBLE, @as(f64, 1.0), c.GST_AUDIO_RESAMPLER_OPT_CUBIC_C, c.G_TYPE_DOUBLE, @as(f64, 0.0), NONE),
        c.GST_AUDIO_RESAMPLER_METHOD_BLACKMAN_NUTTALL => {
            const m = BLACKMAN[quality];
            c.gst_structure_set(options, c.GST_AUDIO_RESAMPLER_OPT_N_TAPS, c.G_TYPE_INT, m.n_taps, c.GST_AUDIO_RESAMPLER_OPT_CUTOFF, c.G_TYPE_DOUBLE, m.cutoff, NONE);
        },
        c.GST_AUDIO_RESAMPLER_METHOD_KAISER => {
            const m = KAISER[quality];
            var cutoff = m.cutoff;
            if (out_rate < in_rate) cutoff *= m.down;
            c.gst_structure_set(options, c.GST_AUDIO_RESAMPLER_OPT_CUTOFF, c.G_TYPE_DOUBLE, cutoff, c.GST_AUDIO_RESAMPLER_OPT_STOP_ATTENUATION, c.G_TYPE_DOUBLE, m.stop, c.GST_AUDIO_RESAMPLER_OPT_TRANSITION_BANDWIDTH, c.G_TYPE_DOUBLE, m.tr, NONE);
        },
        else => {},
    }
    c.gst_structure_set(options, c.GST_AUDIO_RESAMPLER_OPT_FILTER_OVERSAMPLE, c.G_TYPE_INT, OVERSAMPLE[quality], NONE);
}

pub export fn gst_audio_resampler_new(method: c.GstAudioResamplerMethod, flags: c.GstAudioResamplerFlags, fmt: c.GstAudioFormat, channels: c.gint, in_rate: c.gint, out_rate: c.gint, options_in: ?*c.GstStructure) ?*c.GstAudioResampler {
    const fname = "gst_audio_resampler_new";
    if (!check.that(method >= c.GST_AUDIO_RESAMPLER_METHOD_NEAREST and method <= c.GST_AUDIO_RESAMPLER_METHOD_KAISER, fname, "method >= GST_AUDIO_RESAMPLER_METHOD_NEAREST && method <= GST_AUDIO_RESAMPLER_METHOD_KAISER")) return null;
    if (!check.that(fmt == c.GST_AUDIO_FORMAT_S16 or fmt == c.GST_AUDIO_FORMAT_S32 or fmt == c.GST_AUDIO_FORMAT_F32 or fmt == c.GST_AUDIO_FORMAT_F64, fname, "format == GST_AUDIO_FORMAT_S16 || format == GST_AUDIO_FORMAT_S32 || format == GST_AUDIO_FORMAT_F32 || format == GST_AUDIO_FORMAT_F64")) return null;
    if (!check.that(channels > 0, fname, "channels > 0")) return null;
    if (!check.that(in_rate > 0, fname, "in_rate > 0")) return null;
    if (!check.that(out_rate > 0, fname, "out_rate > 0")) return null;
    ensureInit();
    const r: *R = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(R))));
    r.method = method;
    r.flags = flags;
    r.format = fmt;
    r.channels = channels;
    r.format_index = switch (fmt) {
        c.GST_AUDIO_FORMAT_S16 => 0,
        c.GST_AUDIO_FORMAT_S32 => 1,
        c.GST_AUDIO_FORMAT_F32 => 2,
        else => 3,
    };
    const info = format.gst_audio_format_get_info(fmt);
    r.bps = @divTrunc(info.*.width, 8);
    r.sbuf = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.gpointer) * @as(usize, @intCast(channels)))));
    r.blocks = channels;
    r.inc = 1;
    r.ostride = if (flags & c.GST_AUDIO_RESAMPLER_FLAG_NON_INTERLEAVED_OUT != 0) 1 else channels;
    r.deinterleave = if (flags & c.GST_AUDIO_RESAMPLER_FLAG_NON_INTERLEAVED_IN != 0) copyFn else DEINTERLEAVE[@intCast(r.format_index)];
    r.convert_taps = CONVERT[@intCast(r.format_index)];
    r.interpolate = INTERPOLATE[0];
    r.resample = RESAMPLE[0];
    var options = options_in;
    var def: ?*c.GstStructure = null;
    if (options == null) {
        def = c.gst_structure_new_empty("GstAudioResampler.options");
        options = def;
        gst_audio_resampler_options_set_quality(c.GST_AUDIO_RESAMPLER_METHOD_KAISER, DEFAULT_QUALITY, in_rate, out_rate, options);
    }
    _ = gst_audio_resampler_update(@ptrCast(r), in_rate, out_rate, options);
    gst_audio_resampler_reset(@ptrCast(r));
    if (def != null) c.gst_structure_free(def);
    return @ptrCast(r);
}

fn sampleBufs(r: *R, need: usize) [*c]c.gpointer {
    if (r.samples_len < need) {
        const blocks: usize = @intCast(r.blocks);
        const bytes = ((need * @as(usize, @intCast(r.bps)) * @as(usize, @intCast(r.inc))) + ALIGN - 1) & ~@as(usize, ALIGN - 1);
        const samples = c.g_malloc0(blocks * bytes + ALIGN - 1);
        const ptr = alignPtr(samples);
        var to_move: usize = 0;
        if (r.samples_len > 0) to_move = r.samples_avail * @as(usize, @intCast(r.bps)) * @as(usize, @intCast(r.inc));
        for (0..blocks) |ch| {
            const dst = ptr + ch * bytes;
            if (to_move > 0) @memcpy(dst[0..to_move], @as([*]const u8, @ptrCast(r.sbuf[ch]))[0..to_move]);
            r.sbuf[ch] = dst;
        }
        c.g_free(r.samples);
        r.samples = samples;
        r.samples_len = need;
    }
    return r.sbuf;
}

pub export fn gst_audio_resampler_reset(rp: ?*c.GstAudioResampler) void {
    if (!check.that(rp != null, "gst_audio_resampler_reset", "resampler != NULL")) return;
    const r = of(rp);
    if (r.samples != null) {
        const bpf: usize = @intCast(r.bps * r.inc);
        const bytes = @as(usize, @intCast(@divTrunc(r.n_taps, 2))) * bpf;
        for (0..@intCast(r.blocks)) |ch| @memset(@as([*]u8, @ptrCast(r.sbuf[ch]))[0..bytes], 0);
    }
    r.samp_index = 0;
    r.samples_avail = @intCast(@divTrunc(r.n_taps, 2) - 1);
}

pub export fn gst_audio_resampler_update(rp: ?*c.GstAudioResampler, in_rate_in: c.gint, out_rate_in: c.gint, options: ?*c.GstStructure) c.gboolean {
    if (!check.that(rp != null, "gst_audio_resampler_update", "resampler != NULL")) return 0;
    const r = of(rp);
    var in_rate = if (in_rate_in <= 0) r.in_rate else in_rate_in;
    var out_rate = if (out_rate_in <= 0) r.out_rate else out_rate_in;
    var samp_phase: c.gint = if (r.out_rate > 0) @intCast(c.gst_util_uint64_scale_int(@intCast(r.samp_phase), out_rate, r.out_rate)) else 0;
    var gcd = c.gst_util_greatest_common_divisor(in_rate, out_rate);
    const max_error = optDouble(r.options, c.GST_AUDIO_RESAMPLER_OPT_MAX_PHASE_ERROR, 0.1);
    if (max_error < 1.0e-8) {
        gcd = c.gst_util_greatest_common_divisor(gcd, samp_phase);
    } else {
        while (gcd > 1) {
            const ph1 = @as(f64, @floatFromInt(samp_phase)) / @as(f64, @floatFromInt(out_rate));
            var factor: c.gint = 2;
            const ph2 = @as(f64, @floatFromInt(@divTrunc(samp_phase, gcd))) / @as(f64, @floatFromInt(@divTrunc(out_rate, gcd)));
            if (@abs(ph1 - ph2) < max_error) break;
            while (@rem(gcd, factor) != 0) factor += 1;
            gcd = @divTrunc(gcd, factor);
        }
    }
    samp_phase = @divTrunc(samp_phase, gcd);
    r.samp_phase = samp_phase;
    in_rate = @divTrunc(in_rate, gcd);
    out_rate = @divTrunc(out_rate, gcd);
    r.in_rate = in_rate;
    r.out_rate = out_rate;
    r.samp_inc = @divTrunc(in_rate, out_rate);
    r.samp_frac = @rem(in_rate, out_rate);
    if (options != null) {
        if (r.options != null) c.gst_structure_free(r.options);
        r.options = c.gst_structure_copy(options);
        const old_n_taps = r.n_taps;
        calculateTaps(r);
        if (old_n_taps > 0 and old_n_taps != r.n_taps) {
            const sbuf = sampleBufs(r, @intCast(r.n_taps));
            const bpf: c.gint = r.bps * r.inc;
            var bytes: c.gint = @as(c.gint, @intCast(r.samples_avail)) * bpf;
            var soff: c.gint = r.samp_index * bpf;
            var doff = soff;
            const diff = @divTrunc(r.n_taps - old_n_taps, 2);
            if (diff < 0) {
                soff += -diff * bpf;
                bytes -= -diff * bpf;
            } else doff += diff * bpf;
            for (0..@intCast(r.blocks)) |i| {
                const base: [*]u8 = @ptrCast(sbuf[i]);
                const n: usize = @intCast(@max(bytes, 0));
                const d = base + @as(usize, @intCast(doff));
                const s = base + @as(usize, @intCast(soff));
                if (@intFromPtr(d) < @intFromPtr(s)) std.mem.copyForwards(u8, d[0..n], s[0..n]) else std.mem.copyBackwards(u8, d[0..n], s[0..n]);
            }
            r.samples_avail = @intCast(@as(isize, @intCast(r.samples_avail)) + diff);
        }
    } else if (r.filter_mode == c.GST_AUDIO_RESAMPLER_FILTER_MODE_FULL) {
        r.n_phases = r.out_rate;
        allocCache(r, r.bps, r.n_taps, r.n_phases);
    }
    setupFunctions(r);
    return 1;
}

pub export fn gst_audio_resampler_free(rp: ?*c.GstAudioResampler) void {
    if (!check.that(rp != null, "gst_audio_resampler_free", "resampler != NULL")) return;
    const r = of(rp);
    c.g_free(r.cached_taps_mem);
    c.g_free(r.taps_mem);
    c.g_free(r.tmp_taps);
    c.g_free(r.samples);
    c.g_free(@ptrCast(r.sbuf));
    if (r.options != null) c.gst_structure_free(r.options);
    c.g_free(r);
}

pub export fn gst_audio_resampler_get_out_frames(rp: ?*c.GstAudioResampler, in_frames: c_ulong) c_ulong {
    if (!check.that(rp != null, "gst_audio_resampler_get_out_frames", "resampler != NULL")) return 0;
    const r = of(rp);
    const need: usize = @intCast(r.n_taps + r.samp_index + r.skip);
    const avail = r.samples_avail + in_frames;
    if (avail < need) return 0;
    var out = (avail - need) *% @as(usize, @intCast(r.out_rate));
    if (out < @as(usize, @intCast(r.samp_phase))) return 0;
    out = ((out - @as(usize, @intCast(r.samp_phase))) / @as(usize, @intCast(r.in_rate))) + 1;
    return out;
}

pub export fn gst_audio_resampler_get_in_frames(rp: ?*c.GstAudioResampler, out_frames: c_ulong) c_ulong {
    if (!check.that(rp != null, "gst_audio_resampler_get_in_frames", "resampler != NULL")) return 0;
    const r = of(rp);
    var n = (@as(usize, @intCast(r.samp_phase)) +% out_frames *% @as(usize, @intCast(r.samp_frac))) / @as(usize, @intCast(r.out_rate));
    n +%= out_frames *% @as(usize, @intCast(r.samp_inc));
    return n;
}

pub export fn gst_audio_resampler_get_max_latency(rp: ?*c.GstAudioResampler) c_ulong {
    if (!check.that(rp != null, "gst_audio_resampler_get_max_latency", "resampler != NULL")) return 0;
    return @intCast(@divTrunc(of(rp).n_taps, 2));
}

pub export fn gst_audio_resampler_resample(rp: ?*c.GstAudioResampler, in: [*c]c.gpointer, in_frames: c_ulong, out: [*c]c.gpointer, out_frames: c_ulong) void {
    const r = of(rp);
    if (@as(usize, @intCast(r.skip)) >= in_frames) {
        r.skip -= @intCast(in_frames);
        return;
    }
    r.samp_index += r.skip;
    var avail = r.samples_avail;
    const sbuf = sampleBufs(r, in_frames + avail);
    r.deinterleave(r, sbuf, in, in_frames);
    avail += in_frames;
    r.samples_avail = avail;
    const need: usize = @intCast(r.n_taps + r.samp_index);
    if (avail < need or out_frames == 0) return;
    var consumed: usize = 0;
    r.resample(r, sbuf, avail, out, out_frames, &consumed);
    if (consumed > 0) {
        const left: isize = @as(isize, @intCast(avail)) - @as(isize, @intCast(consumed));
        if (left > 0) {
            r.samples_avail = @intCast(left);
        } else {
            r.samples_avail = 0;
            r.skip = @intCast(-left);
        }
    }
}
