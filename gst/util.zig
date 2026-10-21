const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");

comptime {
    @import("abi.zig").check(@This());
}

const MAX_U64 = std.math.maxInt(u64);
const MAX_INT = std.math.maxInt(c.gint);
const MAX_I64 = std.math.maxInt(i64);

fn abs32(x: c.gint) c.gint {
    return if (x < 0) -%x else x;
}

fn abs64(x: i64) i64 {
    return if (x < 0) -%x else x;
}

pub export fn gst_util_guint64_to_gdouble(v: c.guint64) c.gdouble {
    const as_signed: f64 = @floatFromInt(@as(i64, @bitCast(v)));
    return if (v & 0x8000000000000000 != 0) as_signed + 18446744073709551616.0 else as_signed;
}

pub export fn gst_util_gdouble_to_guint64(v: c.gdouble) c.guint64 {
    if (v < 9223372036854775808.0) return @bitCast(@as(i64, @intFromFloat(v)));
    return @bitCast(@as(i64, @intFromFloat(v - 18446744073709551616.0)));
}

fn scaleWide(val: u64, num: u64, denom: u64, correct: u64) u64 {
    const product = @as(u128, val) * num;
    const q = (product + correct) / denom;
    return if (q > MAX_U64) MAX_U64 else @intCast(q);
}

fn scale(val: u64, num: u64, denom: u64, correct: u64) u64 {
    if (!check.that(denom != 0, "_gst_util_uint64_scale", "denom != 0")) return MAX_U64;
    if (num == 0) return 0;
    if (num == denom) return val;
    return scaleWide(val, num, denom, correct);
}

pub export fn gst_util_uint64_scale(val: c.guint64, num: c.guint64, denom: c.guint64) c.guint64 {
    return scale(val, num, denom, 0);
}

pub export fn gst_util_uint64_scale_round(val: c.guint64, num: c.guint64, denom: c.guint64) c.guint64 {
    return scale(val, num, denom, denom >> 1);
}

pub export fn gst_util_uint64_scale_ceil(val: c.guint64, num: c.guint64, denom: c.guint64) c.guint64 {
    return scale(val, num, denom, denom -% 1);
}

fn scaleInt(val: u64, num: c.gint, denom: c.gint, correct: c.gint) u64 {
    if (!check.that(denom > 0, "_gst_util_uint64_scale_int", "denom > 0")) return MAX_U64;
    if (!check.that(num >= 0, "_gst_util_uint64_scale_int", "num >= 0")) return MAX_U64;
    if (num == 0) return 0;
    if (num == denom) return val;
    const n: u64 = @intCast(num);
    const d: u64 = @intCast(denom);
    const k: u64 = @intCast(correct);
    if (val <= std.math.maxInt(u32)) return (val * n + k) / d;
    return scaleWide(val, n, d, k);
}

pub export fn gst_util_uint64_scale_int(val: c.guint64, num: c.gint, denom: c.gint) c.guint64 {
    return scaleInt(val, num, denom, 0);
}

pub export fn gst_util_uint64_scale_int_round(val: c.guint64, num: c.gint, denom: c.gint) c.guint64 {
    return scaleInt(val, num, denom, denom >> 1);
}

pub export fn gst_util_uint64_scale_int_ceil(val: c.guint64, num: c.gint, denom: c.gint) c.guint64 {
    return scaleInt(val, num, denom, denom -% 1);
}

var seqnum_counter = std.atomic.Value(c.gint).init(1);

pub export fn gst_util_seqnum_next() c.guint32 {
    var n = seqnum_counter.fetchAdd(1, .monotonic);
    if (n == c.GST_SEQNUM_INVALID) n = seqnum_counter.fetchAdd(1, .monotonic);
    return @bitCast(n);
}

pub export fn gst_util_seqnum_compare(a: c.guint32, b: c.guint32) c.gint32 {
    return @bitCast(a -% b);
}

var group_counter = std.atomic.Value(c.gint).init(1);

pub export fn gst_util_group_id_next() c.guint {
    var n = group_counter.fetchAdd(1, .monotonic);
    if (n == c.GST_GROUP_ID_INVALID) n = group_counter.fetchAdd(1, .monotonic);
    return @bitCast(n);
}

pub export fn gst_util_greatest_common_divisor(a_in: c.gint, b_in: c.gint) c.gint {
    var a = a_in;
    var b = b_in;
    while (b != 0) {
        const t = a;
        a = b;
        b = @rem(t, b);
    }
    return abs32(a);
}

pub export fn gst_util_greatest_common_divisor_int64(a_in: c.gint64, b_in: c.gint64) c.gint64 {
    var a = a_in;
    var b = b_in;
    while (b != 0) {
        const t = a;
        a = b;
        b = @rem(t, b);
    }
    return abs64(a);
}

pub export fn gst_util_simplify_fraction(numerator: [*c]c.gint, denominator: [*c]c.gint, n_terms: c.guint, threshold: c.guint) void {
    const terms: [*]c.guint = @ptrCast(@alignCast(c.g_malloc_n(n_terms, @sizeOf(c.guint)) orelse return));
    defer c.g_free(terms);
    var x: c.guint = @bitCast(numerator.*);
    var y: c.guint = @bitCast(denominator.*);
    var n: c.guint = 0;
    while (n < n_terms and y != 0) : (n += 1) {
        terms[n] = x / y;
        if (terms[n] >= threshold) {
            if (n < 2) n += 1;
            break;
        }
        const r = x -% terms[n] *% y;
        x = y;
        y = r;
    }
    x = 0;
    y = 1;
    var i = n;
    while (i > 0) : (i -= 1) {
        const r = y;
        y = terms[i - 1] *% y +% x;
        x = r;
    }
    numerator.* = @bitCast(y);
    denominator.* = @bitCast(x);
}

pub export fn gst_util_fraction_to_double(n: c.gint, d: c.gint, dest: [*c]c.gdouble) void {
    if (!check.that(dest != null, "gst_util_fraction_to_double", "dest != NULL")) return;
    if (!check.that(d != 0, "gst_util_fraction_to_double", "src_d != 0")) return;
    dest.* = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
}

pub export fn gst_util_double_to_fraction(src: c.gdouble, dest_n: [*c]c.gint, dest_d: [*c]c.gint) void {
    if (!check.that(dest_n != null, "gst_util_double_to_fraction", "dest_n != NULL")) return;
    if (!check.that(dest_d != null, "gst_util_double_to_fraction", "dest_d != NULL")) return;
    var f = src;
    const negative = f < 0.0;
    if (negative) f = -f;
    const v = f;
    var n1: i64 = 1;
    var d1: i64 = 0;
    var n2: i64 = 0;
    var d2: i64 = 1;
    var n: c.gint = 1;
    var d: c.gint = 1;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const a: c.gint = @intFromFloat(f);
        f -= @floatFromInt(a);
        n2 = n1 * a + n2;
        d2 = d1 * a + d2;
        if (n2 > MAX_INT or d2 > MAX_INT) break;
        n = @intCast(n2);
        d = @intCast(d2);
        n2 = n1;
        d2 = d1;
        n1 = n;
        d1 = d;
        if (f < 1.0e-10 or @abs(v - @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d))) < 1.0e-20) break;
        f = 1 / f;
    }
    if (d == 0) {
        n = MAX_INT;
        d = 1;
    }
    if (negative) n = -n;
    const g = gst_util_greatest_common_divisor(n, d);
    if (g != 0) {
        n = @divTrunc(n, g);
        d = @divTrunc(d, g);
    }
    dest_n.* = n;
    dest_d.* = d;
}

pub export fn gst_util_fraction_multiply(a_n_in: c.gint, a_d_in: c.gint, b_n_in: c.gint, b_d_in: c.gint, res_n: [*c]c.gint, res_d: [*c]c.gint) c.gboolean {
    const func = "gst_util_fraction_multiply";
    if (!check.that(res_n != null, func, "res_n != NULL")) return 0;
    if (!check.that(res_d != null, func, "res_d != NULL")) return 0;
    if (!check.that(a_d_in != 0, func, "a_d != 0")) return 0;
    if (!check.that(b_d_in != 0, func, "b_d != 0")) return 0;
    if (a_n_in == 0 or b_n_in == 0) {
        res_n.* = 0;
        res_d.* = 1;
        return 1;
    }
    var a_n = a_n_in;
    var a_d = a_d_in;
    var b_n = b_n_in;
    var b_d = b_d_in;
    var g = gst_util_greatest_common_divisor(a_n, a_d);
    a_n = @divTrunc(a_n, g);
    a_d = @divTrunc(a_d, g);
    g = gst_util_greatest_common_divisor(b_n, b_d);
    b_n = @divTrunc(b_n, g);
    b_d = @divTrunc(b_d, g);
    g = gst_util_greatest_common_divisor(a_n, b_d);
    a_n = @divTrunc(a_n, g);
    b_d = @divTrunc(b_d, g);
    g = gst_util_greatest_common_divisor(a_d, b_n);
    a_d = @divTrunc(a_d, g);
    b_n = @divTrunc(b_n, g);
    if (a_n != 0 and @divTrunc(MAX_INT, abs32(a_n)) < abs32(b_n)) return 0;
    if (@divTrunc(MAX_INT, abs32(a_d)) < abs32(b_d)) return 0;
    var n = a_n * b_n;
    var d = a_d * b_d;
    g = gst_util_greatest_common_divisor(n, d);
    n = @divTrunc(n, g);
    d = @divTrunc(d, g);
    res_n.* = n;
    res_d.* = d;
    return 1;
}

pub export fn gst_util_fraction_multiply_int64(a_n_in: c.gint64, a_d_in: c.gint64, b_n_in: c.gint64, b_d_in: c.gint64, res_n: [*c]c.gint64, res_d: [*c]c.gint64) c.gboolean {
    const func = "gst_util_fraction_multiply_int64";
    if (!check.that(res_n != null, func, "res_n != NULL")) return 0;
    if (!check.that(res_d != null, func, "res_d != NULL")) return 0;
    if (!check.that(a_d_in != 0, func, "a_d != 0")) return 0;
    if (!check.that(b_d_in != 0, func, "b_d != 0")) return 0;
    if (a_n_in == 0 or b_n_in == 0) {
        res_n.* = 0;
        res_d.* = 1;
        return 1;
    }
    var a_n = a_n_in;
    var a_d = a_d_in;
    var b_n = b_n_in;
    var b_d = b_d_in;
    var g: c.gint = @truncate(gst_util_greatest_common_divisor_int64(a_n, a_d));
    a_n = @divTrunc(a_n, g);
    a_d = @divTrunc(a_d, g);
    g = @truncate(gst_util_greatest_common_divisor_int64(b_n, b_d));
    b_n = @divTrunc(b_n, g);
    b_d = @divTrunc(b_d, g);
    g = @truncate(gst_util_greatest_common_divisor_int64(a_n, b_d));
    a_n = @divTrunc(a_n, g);
    b_d = @divTrunc(b_d, g);
    g = @truncate(gst_util_greatest_common_divisor_int64(a_d, b_n));
    a_d = @divTrunc(a_d, g);
    b_n = @divTrunc(b_n, g);
    if (a_n != 0 and @divTrunc(MAX_I64, abs64(a_n)) < abs64(b_n)) return 0;
    if (@divTrunc(MAX_I64, abs64(a_d)) < abs64(b_d)) return 0;
    var n = a_n * b_n;
    var d = a_d * b_d;
    g = @truncate(gst_util_greatest_common_divisor_int64(n, d));
    n = @divTrunc(n, g);
    d = @divTrunc(d, g);
    res_n.* = n;
    res_d.* = d;
    return 1;
}

pub export fn gst_util_fraction_add(a_n_in: c.gint, a_d_in: c.gint, b_n_in: c.gint, b_d_in: c.gint, res_n: [*c]c.gint, res_d: [*c]c.gint) c.gboolean {
    const func = "gst_util_fraction_add";
    if (!check.that(res_n != null, func, "res_n != NULL")) return 0;
    if (!check.that(res_d != null, func, "res_d != NULL")) return 0;
    if (!check.that(a_d_in != 0, func, "a_d != 0")) return 0;
    if (!check.that(b_d_in != 0, func, "b_d != 0")) return 0;
    var a_n = a_n_in;
    var a_d = a_d_in;
    var b_n = b_n_in;
    var b_d = b_d_in;
    var g = gst_util_greatest_common_divisor(a_n, a_d);
    a_n = @divTrunc(a_n, g);
    a_d = @divTrunc(a_d, g);
    g = gst_util_greatest_common_divisor(b_n, b_d);
    b_n = @divTrunc(b_n, g);
    b_d = @divTrunc(b_d, g);
    if (a_n == 0) {
        res_n.* = b_n;
        res_d.* = b_d;
        return 1;
    }
    if (b_n == 0) {
        res_n.* = a_n;
        res_d.* = a_d;
        return 1;
    }
    if (@divTrunc(MAX_INT, abs32(a_n)) < abs32(b_n)) return 0;
    if (@divTrunc(MAX_INT, abs32(a_d)) < abs32(b_d)) return 0;
    var n = a_n *% b_d +% a_d *% b_n;
    var d = a_d * b_d;
    g = gst_util_greatest_common_divisor(n, d);
    if (g != 0) {
        n = @divTrunc(n, g);
        d = @divTrunc(d, g);
    } else d = 1;
    res_n.* = n;
    res_d.* = d;
    return 1;
}

pub export fn gst_util_fraction_compare(a_n_in: c.gint, a_d_in: c.gint, b_n_in: c.gint, b_d_in: c.gint) c.gint {
    if (!check.that(a_d_in != 0 and b_d_in != 0, "gst_util_fraction_compare", "a_d != 0 && b_d != 0")) return 0;
    var a_n = a_n_in;
    var a_d = a_d_in;
    var b_n = b_n_in;
    var b_d = b_d_in;
    var g = gst_util_greatest_common_divisor(a_n, a_d);
    a_n = @divTrunc(a_n, g);
    a_d = @divTrunc(a_d, g);
    g = gst_util_greatest_common_divisor(b_n, b_d);
    b_n = @divTrunc(b_n, g);
    b_d = @divTrunc(b_d, g);
    if (a_n == b_n and a_d == b_d) return 0;
    const x = @as(i64, a_n) * b_d;
    const y = @as(i64, b_n) * a_d;
    if (x < y) return -1;
    if (x > y) return 1;
    check.unreachableAt("../gst/gstutils.c", 4161, "gst_util_fraction_compare");
    return 0;
}

pub export fn gst_util_ceil_log2(v: c.guint32) c.guint {
    if (!check.that(v != 0, "gst_util_ceil_log2", "v != 0")) return std.math.maxInt(c.guint);
    if (v == 1) return 0;
    return 32 - @as(c.guint, @clz(v - 1));
}

pub export fn gst_util_floor_log2(v: c.guint32) c.guint {
    if (!check.that(v != 0, "gst_util_floor_log2", "v != 0")) return std.math.maxInt(c.guint);
    return 31 - @as(c.guint, @clz(v));
}

pub export fn gst_util_get_timestamp() c.GstClockTime {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * c.GST_SECOND + @as(u64, @intCast(ts.tv_nsec));
}
