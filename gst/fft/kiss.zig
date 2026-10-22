const std = @import("std");
const c = @import("../c.zig").c;
const libm = @import("../libm.zig");

const PI: f64 = 3.141592653589793238462643383279502884197169399375105820974944;
const PI_R: f64 = 3.14159265358979323846264338327;

pub fn Fft(comptime T: type) type {
    return struct {
        const fixed = @typeInfo(T) == .int;
        const Wide = if (T == i16) i32 else i64;
        const FRAC = if (T == i16) 15 else 31;
        const SMAX: Wide = std.math.maxInt(T);

        pub const Cpx = extern struct { r: T, i: T };

        pub const State = struct {
            nfft: usize,
            inverse: bool,
            factors: [64]usize,
            twiddles: []Cpx,
            tmp: []Cpx,
            super: []Cpx,
        };

        fn wrap(x: anytype) T {
            return @truncate(@as(Wide, x));
        }

        fn round(x: Wide) T {
            return @truncate((x +% (@as(Wide, 1) << (FRAC - 1))) >> FRAC);
        }

        fn smul(a: T, b: T) Wide {
            return @as(Wide, a) *% @as(Wide, b);
        }

        fn sMul(a: T, b: T) T {
            if (fixed) return round(smul(a, b));
            return a * b;
        }

        fn add(a: T, b: T) T {
            if (fixed) return wrap(@as(Wide, a) +% @as(Wide, b));
            return a + b;
        }

        fn sub(a: T, b: T) T {
            if (fixed) return wrap(@as(Wide, a) -% @as(Wide, b));
            return a - b;
        }

        fn neg(a: T) T {
            if (fixed) return wrap(0 -% @as(Wide, a));
            return -a;
        }

        fn cmul(a: Cpx, b: Cpx) Cpx {
            if (fixed) return .{ .r = round(smul(a.r, b.r) -% smul(a.i, b.i)), .i = round(smul(a.r, b.i) +% smul(a.i, b.r)) };
            return .{ .r = a.r * b.r - a.i * b.i, .i = a.r * b.i + a.i * b.r };
        }

        fn cadd(a: Cpx, b: Cpx) Cpx {
            return .{ .r = add(a.r, b.r), .i = add(a.i, b.i) };
        }

        fn csub(a: Cpx, b: Cpx) Cpx {
            return .{ .r = sub(a.r, b.r), .i = sub(a.i, b.i) };
        }

        fn fixdiv(x: *Cpx, comptime div: Wide) void {
            if (!fixed) return;
            x.r = round(smul(x.r, @intCast(@divTrunc(SMAX, div))));
            x.i = round(smul(x.i, @intCast(@divTrunc(SMAX, div))));
        }

        fn fixdivRt(x: *Cpx, div: Wide) void {
            if (!fixed) return;
            const k: T = @intCast(@divTrunc(SMAX, div));
            x.r = round(smul(x.r, k));
            x.i = round(smul(x.i, k));
        }

        fn half(x: anytype) T {
            if (fixed) return wrap(@as(Wide, x) >> 1);
            return @floatCast(@as(f64, x) * 0.5);
        }

        fn cexp(phase: f64) Cpx {
            if (fixed) return .{ .r = @intFromFloat(c.floor(0.5 + @as(f64, @floatFromInt(SMAX)) * libm.cos(phase))), .i = @intFromFloat(c.floor(0.5 + @as(f64, @floatFromInt(SMAX)) * libm.sin(phase))) };
            return .{ .r = @floatCast(libm.cos(phase)), .i = @floatCast(libm.sin(phase)) };
        }

        fn bfly2(out: [*]Cpx, stride: usize, st: *const State, m: usize) void {
            var tw: usize = 0;
            for (0..m) |k| {
                fixdiv(&out[k], 2);
                fixdiv(&out[k + m], 2);
                const t = cmul(out[k + m], st.twiddles[tw]);
                tw += stride;
                out[k + m] = csub(out[k], t);
                out[k] = cadd(out[k], t);
            }
        }

        fn bfly4(out: [*]Cpx, stride: usize, st: *const State, m: usize) void {
            var t1: usize = 0;
            var t2: usize = 0;
            var t3: usize = 0;
            for (0..m) |k| {
                const f = out + k;
                fixdiv(&f[0], 4);
                fixdiv(&f[m], 4);
                fixdiv(&f[2 * m], 4);
                fixdiv(&f[3 * m], 4);
                const s0 = cmul(f[m], st.twiddles[t1]);
                const s1 = cmul(f[2 * m], st.twiddles[t2]);
                const s2 = cmul(f[3 * m], st.twiddles[t3]);
                const s5 = csub(f[0], s1);
                f[0] = cadd(f[0], s1);
                const s3 = cadd(s0, s2);
                const s4 = csub(s0, s2);
                f[2 * m] = csub(f[0], s3);
                t1 += stride;
                t2 += stride * 2;
                t3 += stride * 3;
                f[0] = cadd(f[0], s3);
                if (st.inverse) {
                    f[m] = .{ .r = sub(s5.r, s4.i), .i = add(s5.i, s4.r) };
                    f[3 * m] = .{ .r = add(s5.r, s4.i), .i = sub(s5.i, s4.r) };
                } else {
                    f[m] = .{ .r = add(s5.r, s4.i), .i = sub(s5.i, s4.r) };
                    f[3 * m] = .{ .r = sub(s5.r, s4.i), .i = add(s5.i, s4.r) };
                }
            }
        }

        fn mulScalar(x: *Cpx, s: T) void {
            if (fixed) {
                x.r = round(smul(x.r, s));
                x.i = round(smul(x.i, s));
            } else {
                x.r *= s;
                x.i *= s;
            }
        }

        fn halfSub(a: T, b: T) T {
            if (fixed) return wrap(@as(Wide, a) -% (@as(Wide, b) >> 1));
            return @floatCast(@as(f64, a) - @as(f64, b) * 0.5);
        }

        fn bfly3(out: [*]Cpx, stride: usize, st: *const State, m: usize) void {
            const epi3 = st.twiddles[stride * m];
            var t1: usize = 0;
            var t2: usize = 0;
            for (0..m) |k| {
                const f = out + k;
                fixdiv(&f[0], 3);
                fixdiv(&f[m], 3);
                fixdiv(&f[2 * m], 3);
                const s1 = cmul(f[m], st.twiddles[t1]);
                const s2 = cmul(f[2 * m], st.twiddles[t2]);
                const s3 = cadd(s1, s2);
                var s0 = csub(s1, s2);
                t1 += stride;
                t2 += stride * 2;
                f[m] = .{ .r = halfSub(f[0].r, s3.r), .i = halfSub(f[0].i, s3.i) };
                mulScalar(&s0, epi3.i);
                f[0] = cadd(f[0], s3);
                f[2 * m] = .{ .r = add(f[m].r, s0.i), .i = sub(f[m].i, s0.r) };
                f[m].r = sub(f[m].r, s0.i);
                f[m].i = add(f[m].i, s0.r);
            }
        }

        fn sum3(a: T, b: T, d: T) T {
            if (fixed) return wrap(@as(Wide, a) +% @as(Wide, b) +% @as(Wide, d));
            return a + b + d;
        }

        fn bfly5(out: [*]Cpx, stride: usize, st: *const State, m: usize) void {
            const ya = st.twiddles[stride * m];
            const yb = st.twiddles[stride * 2 * m];
            const tw = st.twiddles;
            for (0..m) |u| {
                const f0 = &out[u];
                const f1 = &out[u + m];
                const f2 = &out[u + 2 * m];
                const f3 = &out[u + 3 * m];
                const f4 = &out[u + 4 * m];
                fixdiv(f0, 5);
                fixdiv(f1, 5);
                fixdiv(f2, 5);
                fixdiv(f3, 5);
                fixdiv(f4, 5);
                const s0 = f0.*;
                const s1 = cmul(f1.*, tw[u * stride]);
                const s2 = cmul(f2.*, tw[2 * u * stride]);
                const s3 = cmul(f3.*, tw[3 * u * stride]);
                const s4 = cmul(f4.*, tw[4 * u * stride]);
                const s7 = cadd(s1, s4);
                const s10 = csub(s1, s4);
                const s8 = cadd(s2, s3);
                const s9 = csub(s2, s3);
                f0.r = add(f0.r, add(s7.r, s8.r));
                f0.i = add(f0.i, add(s7.i, s8.i));
                const s5 = Cpx{ .r = sum3(s0.r, sMul(s7.r, ya.r), sMul(s8.r, yb.r)), .i = sum3(s0.i, sMul(s7.i, ya.r), sMul(s8.i, yb.r)) };
                const s6 = Cpx{ .r = add(sMul(s10.i, ya.i), sMul(s9.i, yb.i)), .i = sub(neg(sMul(s10.r, ya.i)), sMul(s9.r, yb.i)) };
                f1.* = csub(s5, s6);
                f4.* = cadd(s5, s6);
                const s11 = Cpx{ .r = sum3(s0.r, sMul(s7.r, yb.r), sMul(s8.r, ya.r)), .i = sum3(s0.i, sMul(s7.i, yb.r), sMul(s8.i, ya.r)) };
                const s12 = Cpx{ .r = add(neg(sMul(s10.i, yb.i)), sMul(s9.i, ya.i)), .i = sub(sMul(s10.r, yb.i), sMul(s9.r, ya.i)) };
                f2.* = cadd(s11, s12);
                f3.* = csub(s11, s12);
            }
        }

        fn bflyGeneric(out: [*]Cpx, stride: usize, st: *const State, m: usize, p: usize) void {
            const scratch: [*]Cpx = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Cpx) * p)));
            defer c.g_free(scratch);
            for (0..m) |u| {
                var k = u;
                for (0..p) |q1| {
                    scratch[q1] = out[k];
                    fixdivRt(&scratch[q1], @intCast(p));
                    k += m;
                }
                k = u;
                for (0..p) |_| {
                    var idx: usize = 0;
                    out[k] = scratch[0];
                    for (1..p) |q| {
                        idx += stride * k;
                        if (idx >= st.nfft) idx -= st.nfft;
                        out[k] = cadd(out[k], cmul(scratch[q], st.twiddles[idx]));
                    }
                    k += m;
                }
            }
        }

        fn work(out_beg: [*]Cpx, input: [*]const Cpx, stride: usize, factors: []const usize, st: *const State) void {
            const p = factors[0];
            const m = factors[1];
            var f = input;
            if (m == 1) {
                for (0..p * m) |j| {
                    out_beg[j] = f[0];
                    f += stride;
                }
            } else {
                var j: usize = 0;
                while (j < p * m) : (j += m) {
                    work(out_beg + j, f, stride * p, factors[2..], st);
                    f += stride;
                }
            }
            switch (p) {
                2 => bfly2(out_beg, stride, st, m),
                3 => bfly3(out_beg, stride, st, m),
                4 => bfly4(out_beg, stride, st, m),
                5 => bfly5(out_beg, stride, st, m),
                else => bflyGeneric(out_beg, stride, st, m, p),
            }
        }

        fn factor(n_in: usize, buf: *[64]usize) void {
            var n = n_in;
            var p: usize = 4;
            const limit = c.floor(c.sqrt(@floatFromInt(n_in)));
            var i: usize = 0;
            while (true) {
                while (n % p != 0) {
                    p = switch (p) {
                        4 => 2,
                        2 => 3,
                        else => p + 2,
                    };
                    if (@as(f64, @floatFromInt(p)) > limit) p = n;
                }
                n /= p;
                buf[i] = p;
                buf[i + 1] = n;
                i += 2;
                if (n <= 1) break;
            }
        }

        pub fn complexFft(st: *const State, input: [*]const Cpx, out: [*]Cpx) void {
            if (@intFromPtr(input) == @intFromPtr(out)) {
                const tmp: [*]Cpx = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Cpx) * st.nfft)));
                defer c.g_free(tmp);
                work(tmp, input, 1, &st.factors, st);
                @memcpy(out[0..st.nfft], tmp[0..st.nfft]);
            } else work(out, input, 1, &st.factors, st);
        }

        pub fn init(st: *State, len: usize, inverse: bool) void {
            const n = len / 2;
            st.nfft = n;
            st.inverse = inverse;
            st.factors = [_]usize{0} ** 64;
            st.twiddles = @as([*]Cpx, @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Cpx) * (n + n * 3 / 2 + 1)))))[0 .. n + n * 3 / 2 + 1];
            st.tmp = st.twiddles[n .. n + n];
            st.super = st.twiddles[n + n .. n + n + n / 2 + 1];
            st.twiddles = st.twiddles[0..n];
            for (0..n) |i| {
                var phase = -2.0 * PI * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                if (inverse) phase *= -1;
                st.twiddles[i] = cexp(phase);
            }
            factor(n, &st.factors);
            for (0..n / 2) |i| {
                var phase = -PI_R * (@as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(n)) + 0.5);
                if (inverse) phase *= -1;
                st.super[i] = cexp(phase);
            }
        }

        pub fn deinit(st: *State) void {
            c.g_free(st.twiddles.ptr);
        }

        pub fn forward(st: *const State, time: [*]const T, freq: [*]Cpx) void {
            const n = st.nfft;
            complexFft(st, @ptrCast(time), st.tmp.ptr);
            var tdc = st.tmp[0];
            fixdiv(&tdc, 2);
            freq[0].r = add(tdc.r, tdc.i);
            freq[n].r = sub(tdc.r, tdc.i);
            freq[0].i = 0;
            freq[n].i = 0;
            var k: usize = 1;
            while (k <= n / 2) : (k += 1) {
                var fpk = st.tmp[k];
                var fpnk = Cpx{ .r = st.tmp[n - k].r, .i = neg(st.tmp[n - k].i) };
                fixdiv(&fpk, 2);
                fixdiv(&fpnk, 2);
                const f1k = cadd(fpk, fpnk);
                const f2k = csub(fpk, fpnk);
                const tw = cmul(f2k, st.super[k - 1]);
                freq[k].r = halfOf(f1k.r, tw.r, true);
                freq[k].i = halfOf(f1k.i, tw.i, true);
                freq[n - k].r = halfOf(f1k.r, tw.r, false);
                freq[n - k].i = halfOf(tw.i, f1k.i, false);
            }
        }

        fn halfOf(a: T, b: T, plus: bool) T {
            if (fixed) {
                const s: Wide = if (plus) @as(Wide, a) +% @as(Wide, b) else @as(Wide, a) -% @as(Wide, b);
                return wrap(s >> 1);
            }
            const s: T = if (plus) a + b else a - b;
            return half(s);
        }

        pub fn inverseFft(st: *const State, freq: [*]const Cpx, time: [*]T) void {
            const n = st.nfft;
            st.tmp[0].r = add(freq[0].r, freq[n].r);
            st.tmp[0].i = sub(freq[0].r, freq[n].r);
            fixdiv(&st.tmp[0], 2);
            var k: usize = 1;
            while (k <= n / 2) : (k += 1) {
                var fk = freq[k];
                var fnkc = Cpx{ .r = freq[n - k].r, .i = neg(freq[n - k].i) };
                fixdiv(&fk, 2);
                fixdiv(&fnkc, 2);
                const fek = cadd(fk, fnkc);
                const tmp = csub(fk, fnkc);
                const fok = cmul(tmp, st.super[k - 1]);
                st.tmp[k] = cadd(fek, fok);
                st.tmp[n - k] = csub(fek, fok);
                st.tmp[n - k].i = if (fixed) neg(st.tmp[n - k].i) else st.tmp[n - k].i * -1;
            }
            complexFft(st, st.tmp.ptr, @ptrCast(time));
        }
    };
}

pub fn nextFastSize(n_in: c_int) c_int {
    var n = n_in;
    while (true) {
        var m = n;
        while (@rem(m, 2) == 0) m = @divTrunc(m, 2);
        while (@rem(m, 3) == 0) m = @divTrunc(m, 3);
        while (@rem(m, 5) == 0) m = @divTrunc(m, 5);
        if (m <= 1) break;
        n += 1;
    }
    return n;
}
