const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const value = @import("value.zig");
const util = @import("util.zig");
const va = @import("varargs.zig");

const Value = c.GValue;
const CV = c.GTypeCValue;

fn holds(v: [*c]const Value, t: c.GType) bool {
    return v != null and v.*.g_type == t;
}

fn typeName(v: [*c]const Value) [*c]const u8 {
    return c.g_type_name(v.*.g_type);
}

fn cvals(cv: ?*CV) [*]va.CValue {
    return va.cvaluesOf(cv);
}

fn failMsg(comptime func: []const u8, comptime expr: []const u8, comptime fmt: [:0]const u8, v: [*c]const Value) [*c]u8 {
    check.fail(func, expr);
    return c.g_strdup_printf(fmt.ptr, typeName(v));
}

pub fn intMinPacked(v: [*c]const Value) c.gint {
    return @bitCast(@as(u32, @truncate(v[0].data[0].v_uint64 >> 32)));
}

pub fn intMaxPacked(v: [*c]const Value) c.gint {
    return @bitCast(@as(u32, @truncate(v[0].data[0].v_uint64)));
}

pub fn intStep(v: [*c]const Value) c.gint {
    return v[0].data[1].v_int;
}

pub fn pack(lo: c.gint, hi: c.gint) u64 {
    return (@as(u64, @as(u32, @bitCast(lo))) << 32) | @as(u32, @bitCast(hi));
}

pub fn intRangeInit(v: [*c]Value) callconv(.c) void {
    v[0].data[0].v_uint64 = 0;
    v[0].data[1].v_int = 1;
}

pub fn intRangeCopy(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_uint64 = src[0].data[0].v_uint64;
    dest[0].data[1].v_int = src[0].data[1].v_int;
}

pub fn intRangeCollect(v: [*c]Value, n: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    if (n != 2) return failMsg("gst_value_collect_int_range", "n_collect_values == 2", "not enough value locations for `%s' passed", v);
    if (!(x[0].v_int < x[1].v_int)) return failMsg("gst_value_collect_int_range", "collect_values[0].v_int < collect_values[1].v_int", "range start is not smaller than end for `%s'", v);
    gst_value_set_int_range_step(v, x[0].v_int, x[1].v_int, 1);
    return null;
}

pub fn intRangeLcopy(v: [*c]const Value, _: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    const lo: ?*u32 = @ptrCast(@alignCast(x[0].v_pointer));
    const hi: ?*u32 = @ptrCast(@alignCast(x[1].v_pointer));
    if (lo == null) return failMsg("gst_value_lcopy_int_range", "int_range_start != NULL", "start value location for `%s' passed as NULL", v);
    if (hi == null) return failMsg("gst_value_lcopy_int_range", "int_range_end != NULL", "end value location for `%s' passed as NULL", v);
    lo.?.* = @bitCast(intMinPacked(v));
    hi.?.* = @bitCast(intMaxPacked(v));
    return null;
}

pub export fn gst_value_set_int_range_step(v: [*c]Value, start: c.gint, end: c.gint, step: c.gint) void {
    const func = "gst_value_set_int_range_step";
    if (!check.that(holds(v, value._gst_int_range_type), func, "GST_VALUE_HOLDS_INT_RANGE (value)")) return;
    if (!check.that(start < end, func, "start < end")) return;
    if (!check.that(step > 0, func, "step > 0")) return;
    if (!check.that(@rem(start, step) == 0, func, "start % step == 0")) return;
    if (!check.that(@rem(end, step) == 0, func, "end % step == 0")) return;
    v[0].data[0].v_uint64 = pack(@divTrunc(start, step), @divTrunc(end, step));
    v[0].data[1].v_int = step;
}

pub export fn gst_value_set_int_range(v: [*c]Value, start: c.gint, end: c.gint) void {
    gst_value_set_int_range_step(v, start, end, 1);
}

pub export fn gst_value_get_int_range_min(v: [*c]const Value) c.gint {
    if (!check.that(holds(v, value._gst_int_range_type), "gst_value_get_int_range_min", "GST_VALUE_HOLDS_INT_RANGE (value)")) return 0;
    return intMinPacked(v) *% intStep(v);
}

pub export fn gst_value_get_int_range_max(v: [*c]const Value) c.gint {
    if (!check.that(holds(v, value._gst_int_range_type), "gst_value_get_int_range_max", "GST_VALUE_HOLDS_INT_RANGE (value)")) return 0;
    return intMaxPacked(v) *% intStep(v);
}

pub export fn gst_value_get_int_range_step(v: [*c]const Value) c.gint {
    if (!check.that(holds(v, value._gst_int_range_type), "gst_value_get_int_range_step", "GST_VALUE_HOLDS_INT_RANGE (value)")) return 0;
    return intStep(v);
}

pub fn intRangeToString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = if (intStep(src) == 1)
        c.g_strdup_printf("[%d,%d]", intMinPacked(src), intMaxPacked(src))
    else
        c.g_strdup_printf("[%d,%d,%d]", intMinPacked(src) *% intStep(src), intMaxPacked(src) *% intStep(src), intStep(src));
}

pub fn intRangeCompare(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    if (a[0].data[0].v_uint64 != b[0].data[0].v_uint64) return c.GST_VALUE_UNORDERED;
    if (intMinPacked(a) == intMaxPacked(a)) return c.GST_VALUE_EQUAL;
    return if (intStep(a) == intStep(b)) c.GST_VALUE_EQUAL else c.GST_VALUE_UNORDERED;
}

pub fn intRangeSerialize(v: [*c]const Value) callconv(.c) [*c]u8 {
    if (intStep(v) == 1) return c.g_strdup_printf("[ %d, %d ]", intMinPacked(v), intMaxPacked(v));
    return c.g_strdup_printf("[ %d, %d, %d ]", intMinPacked(v) *% intStep(v), intMaxPacked(v) *% intStep(v), intStep(v));
}

pub fn unimplemented(_: [*c]Value, _: [*c]const u8) callconv(.c) c.gboolean {
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "unimplemented");
    return 0;
}

pub fn i64Parts(v: [*c]const Value) *[3]i64 {
    return @ptrCast(@alignCast(v[0].data[0].v_pointer));
}

pub fn int64RangeInit(v: [*c]Value) callconv(.c) void {
    const p: *[3]i64 = @ptrCast(@alignCast(c.g_malloc0(3 * @sizeOf(i64))));
    p.* = .{ 0, 0, 1 };
    v[0].data[0].v_pointer = p;
}

pub fn int64RangeFree(v: [*c]Value) callconv(.c) void {
    if (!check.that(holds(v, value._gst_int64_range_type), "gst_value_free_int64_range", "GST_VALUE_HOLDS_INT64_RANGE (value)")) return;
    c.g_free(v[0].data[0].v_pointer);
    v[0].data[0].v_pointer = null;
}

pub fn int64RangeCopy(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    if (dest[0].data[0].v_pointer == null) int64RangeInit(dest);
    if (src[0].data[0].v_pointer != null) i64Parts(dest).* = i64Parts(src).*;
}

pub fn int64RangeCollect(v: [*c]Value, n: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    if (n != 2) return failMsg("gst_value_collect_int64_range", "n_collect_values == 2", "not enough value locations for `%s' passed", v);
    if (!(x[0].v_int64 < x[1].v_int64)) return failMsg("gst_value_collect_int64_range", "collect_values[0].v_int64 < collect_values[1].v_int64", "range start is not smaller than end for `%s'", v);
    if (v[0].data[0].v_pointer == null) int64RangeInit(v);
    gst_value_set_int64_range_step(v, x[0].v_int64, x[1].v_int64, 1);
    return null;
}

pub fn int64RangeLcopy(v: [*c]const Value, _: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    const f = "gst_value_lcopy_int64_range";
    if (x[0].v_pointer == null) return failMsg(f, "int_range_start != NULL", "start value location for `%s' passed as NULL", v);
    if (x[1].v_pointer == null) return failMsg(f, "int_range_end != NULL", "end value location for `%s' passed as NULL", v);
    if (x[2].v_pointer == null) return failMsg(f, "int_range_step != NULL", "step value location for `%s' passed as NULL", v);
    if (v[0].data[0].v_pointer == null) return failMsg(f, "vals != NULL", "Uninitialised `%s' passed", v);
    const p = i64Parts(v);
    @as(*i64, @ptrCast(@alignCast(x[0].v_pointer))).* = p[0];
    @as(*i64, @ptrCast(@alignCast(x[1].v_pointer))).* = p[1];
    @as(*i64, @ptrCast(@alignCast(x[2].v_pointer))).* = p[2];
    return null;
}

pub export fn gst_value_set_int64_range_step(v: [*c]Value, start: c.gint64, end: c.gint64, step: c.gint64) void {
    const func = "gst_value_set_int64_range_step";
    if (!check.that(holds(v, value._gst_int64_range_type), func, "GST_VALUE_HOLDS_INT64_RANGE (value)")) return;
    if (!check.that(start < end, func, "start < end")) return;
    if (!check.that(step > 0, func, "step > 0")) return;
    if (!check.that(@rem(start, step) == 0, func, "start % step == 0")) return;
    if (!check.that(@rem(end, step) == 0, func, "end % step == 0")) return;
    i64Parts(v).* = .{ @divTrunc(start, step), @divTrunc(end, step), step };
}

pub export fn gst_value_set_int64_range(v: [*c]Value, start: c.gint64, end: c.gint64) void {
    gst_value_set_int64_range_step(v, start, end, 1);
}

pub export fn gst_value_get_int64_range_min(v: [*c]const Value) c.gint64 {
    if (!check.that(holds(v, value._gst_int64_range_type), "gst_value_get_int64_range_min", "GST_VALUE_HOLDS_INT64_RANGE (value)")) return 0;
    return i64Parts(v)[0] *% i64Parts(v)[2];
}

pub export fn gst_value_get_int64_range_max(v: [*c]const Value) c.gint64 {
    if (!check.that(holds(v, value._gst_int64_range_type), "gst_value_get_int64_range_max", "GST_VALUE_HOLDS_INT64_RANGE (value)")) return 0;
    return i64Parts(v)[1] *% i64Parts(v)[2];
}

pub export fn gst_value_get_int64_range_step(v: [*c]const Value) c.gint64 {
    if (!check.that(holds(v, value._gst_int64_range_type), "gst_value_get_int64_range_step", "GST_VALUE_HOLDS_INT64_RANGE (value)")) return 0;
    return i64Parts(v)[2];
}

pub fn int64RangeToString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    const p = i64Parts(src);
    dest[0].data[0].v_pointer = if (p[2] == 1)
        c.g_strdup_printf("(gint64)[%" ++ "ld,%" ++ "ld]", p[0], p[1])
    else
        c.g_strdup_printf("(gint64)[%ld,%ld,%ld]", p[0] *% p[2], p[1] *% p[2], p[2]);
}

pub fn int64RangeCompare(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x = i64Parts(a);
    const y = i64Parts(b);
    if (x[0] != y[0] or x[1] != y[1]) return c.GST_VALUE_UNORDERED;
    if (x[0] == x[1]) return c.GST_VALUE_EQUAL;
    return if (x[2] == y[2]) c.GST_VALUE_EQUAL else c.GST_VALUE_UNORDERED;
}

pub fn int64RangeSerialize(v: [*c]const Value) callconv(.c) [*c]u8 {
    const p = i64Parts(v);
    if (p[2] == 1) return c.g_strdup_printf("[ %ld, %ld ]", p[0], p[1]);
    return c.g_strdup_printf("[ %ld, %ld, %ld ]", p[0] *% p[2], p[1] *% p[2], p[2]);
}

pub fn doubleRangeInit(v: [*c]Value) callconv(.c) void {
    v[0].data[0].v_double = 0;
    v[0].data[1].v_double = 0;
}

pub fn doubleRangeCopy(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_double = src[0].data[0].v_double;
    dest[0].data[1].v_double = src[0].data[1].v_double;
}

pub fn doubleRangeCollect(v: [*c]Value, n: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    if (n != 2) return failMsg("gst_value_collect_double_range", "n_collect_values == 2", "not enough value locations for `%s' passed", v);
    if (!(x[0].v_double < x[1].v_double)) return failMsg("gst_value_collect_double_range", "collect_values[0].v_double < collect_values[1].v_double", "range start is not smaller than end for `%s'", v);
    v[0].data[0].v_double = x[0].v_double;
    v[0].data[1].v_double = x[1].v_double;
    return null;
}

pub fn doubleRangeLcopy(v: [*c]const Value, _: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    const f = "gst_value_lcopy_double_range";
    if (x[0].v_pointer == null) return failMsg(f, "double_range_start != NULL", "start value location for `%s' passed as NULL", v);
    if (x[1].v_pointer == null) return failMsg(f, "double_range_end != NULL", "end value location for `%s' passed as NULL", v);
    @as(*f64, @ptrCast(@alignCast(x[0].v_pointer))).* = v[0].data[0].v_double;
    @as(*f64, @ptrCast(@alignCast(x[1].v_pointer))).* = v[0].data[1].v_double;
    return null;
}

pub export fn gst_value_set_double_range(v: [*c]Value, start: c.gdouble, end: c.gdouble) void {
    if (!check.that(holds(v, value._gst_double_range_type), "gst_value_set_double_range", "GST_VALUE_HOLDS_DOUBLE_RANGE (value)")) return;
    if (!check.that(start < end, "gst_value_set_double_range", "start < end")) return;
    v[0].data[0].v_double = start;
    v[0].data[1].v_double = end;
}

pub export fn gst_value_get_double_range_min(v: [*c]const Value) c.gdouble {
    if (!check.that(holds(v, value._gst_double_range_type), "gst_value_get_double_range_min", "GST_VALUE_HOLDS_DOUBLE_RANGE (value)")) return 0;
    return v[0].data[0].v_double;
}

pub export fn gst_value_get_double_range_max(v: [*c]const Value) c.gdouble {
    if (!check.that(holds(v, value._gst_double_range_type), "gst_value_get_double_range_max", "GST_VALUE_HOLDS_DOUBLE_RANGE (value)")) return 0;
    return v[0].data[1].v_double;
}

pub fn dtostr(buf: *[c.G_ASCII_DTOSTR_BUF_SIZE]u8, x: f64) [*c]u8 {
    return c.g_ascii_dtostr(buf, buf.len, x);
}

pub fn doubleRangeToString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    var a: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
    var b: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
    dest[0].data[0].v_pointer = c.g_strdup_printf("[%s,%s]", dtostr(&a, src[0].data[0].v_double), dtostr(&b, src[0].data[1].v_double));
}

pub fn doubleRangeCompare(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    if (b[0].data[0].v_double == a[0].data[0].v_double and b[0].data[1].v_double == a[0].data[1].v_double) return c.GST_VALUE_EQUAL;
    return c.GST_VALUE_UNORDERED;
}

pub fn doubleRangeSerialize(v: [*c]const Value) callconv(.c) [*c]u8 {
    var a: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
    var b: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
    return c.g_strdup_printf("[ %s, %s ]", dtostr(&a, v[0].data[0].v_double), dtostr(&b, v[0].data[1].v_double));
}

pub fn fracPair(v: [*c]const Value) [*]Value {
    return @ptrCast(@alignCast(v[0].data[0].v_pointer));
}

pub fn fractionRangeInit(v: [*c]Value) callconv(.c) void {
    const pair: [*]Value = @ptrCast(@alignCast(c.g_malloc0(2 * @sizeOf(Value))));
    _ = c.g_value_init(&pair[0], value._gst_fraction_type);
    _ = c.g_value_init(&pair[1], value._gst_fraction_type);
    v[0].data[0].v_pointer = pair;
}

pub fn fractionRangeFree(v: [*c]Value) callconv(.c) void {
    if (v[0].data[0].v_pointer != null) {
        c.g_free(v[0].data[0].v_pointer);
        v[0].data[0].v_pointer = null;
    }
}

pub fn fractionRangeCopy(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    if (dest[0].data[0].v_pointer == null) fractionRangeInit(dest);
    if (src[0].data[0].v_pointer != null) {
        c.g_value_copy(&fracPair(src)[0], &fracPair(dest)[0]);
        c.g_value_copy(&fracPair(src)[1], &fracPair(dest)[1]);
    }
}

pub fn fractionRangeCollect(v: [*c]Value, n: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    const f = "gst_value_collect_fraction_range";
    if (n != 4) return failMsg(f, "n_collect_values == 4", "not enough value locations for `%s' passed", v);
    if (x[1].v_int == 0) return failMsg(f, "collect_values[1].v_int != 0", "passed '0' as first denominator for `%s'", v);
    if (x[3].v_int == 0) return failMsg(f, "collect_values[3].v_int != 0", "passed '0' as second denominator for `%s'", v);
    if (!(util.gst_util_fraction_compare(x[0].v_int, x[1].v_int, x[2].v_int, x[3].v_int) < 0)) return failMsg(f, "gst_util_fraction_compare (collect_values[0].v_int, collect_values[1].v_int, collect_values[2].v_int, collect_values[3].v_int) < 0", "range start is not smaller than end for `%s'", v);
    if (v[0].data[0].v_pointer == null) fractionRangeInit(v);
    gst_value_set_fraction(&fracPair(v)[0], x[0].v_int, x[1].v_int);
    gst_value_set_fraction(&fracPair(v)[1], x[2].v_int, x[3].v_int);
    return null;
}

pub fn fractionRangeLcopy(v: [*c]const Value, n: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    const f = "gst_value_lcopy_fraction_range";
    if (n != 4) return failMsg(f, "n_collect_values == 4", "not enough value locations for `%s' passed", v);
    if (v[0].data[0].v_pointer == null) return failMsg(f, "vals != NULL", "Uninitialised `%s' passed", v);
    for (0..4) |i| if (x[i].v_pointer == null) return failMsg(f, "collect_values[i].v_pointer != NULL", "value location for `%s' passed as NULL", v);
    const p = fracPair(v);
    @as(*c.gint, @ptrCast(@alignCast(x[0].v_pointer))).* = p[0].data[0].v_int;
    @as(*c.gint, @ptrCast(@alignCast(x[1].v_pointer))).* = p[0].data[1].v_int;
    @as(*c.gint, @ptrCast(@alignCast(x[2].v_pointer))).* = p[1].data[0].v_int;
    @as(*c.gint, @ptrCast(@alignCast(x[3].v_pointer))).* = p[1].data[1].v_int;
    return null;
}

pub export fn gst_value_set_fraction_range(v: [*c]Value, start: [*c]const Value, end: [*c]const Value) void {
    const f = "gst_value_set_fraction_range";
    if (!check.that(holds(v, value._gst_fraction_range_type), f, "GST_VALUE_HOLDS_FRACTION_RANGE (value)")) return;
    if (!check.that(holds(start, value._gst_fraction_type), f, "GST_VALUE_HOLDS_FRACTION (start)")) return;
    if (!check.that(holds(end, value._gst_fraction_type), f, "GST_VALUE_HOLDS_FRACTION (end)")) return;
    if (!check.that(util.gst_util_fraction_compare(start[0].data[0].v_int, start[0].data[1].v_int, end[0].data[0].v_int, end[0].data[1].v_int) < 0, f, "gst_util_fraction_compare (start->data[0].v_int, start->data[1].v_int, end->data[0].v_int, end->data[1].v_int) < 0")) return;
    if (v[0].data[0].v_pointer == null) fractionRangeInit(v);
    c.g_value_copy(start, &fracPair(v)[0]);
    c.g_value_copy(end, &fracPair(v)[1]);
}

pub export fn gst_value_set_fraction_range_full(v: [*c]Value, n1: c.gint, d1: c.gint, n2: c.gint, d2: c.gint) void {
    const f = "gst_value_set_fraction_range_full";
    if (!check.that(v != null, f, "value != NULL")) return;
    if (!check.that(d1 != 0, f, "denominator_start != 0")) return;
    if (!check.that(d2 != 0, f, "denominator_end != 0")) return;
    if (!check.that(util.gst_util_fraction_compare(n1, d1, n2, d2) < 0, f, "gst_util_fraction_compare (numerator_start, denominator_start, numerator_end, denominator_end) < 0")) return;
    var a = std.mem.zeroes(Value);
    var b = std.mem.zeroes(Value);
    _ = c.g_value_init(&a, value._gst_fraction_type);
    _ = c.g_value_init(&b, value._gst_fraction_type);
    gst_value_set_fraction(&a, n1, d1);
    gst_value_set_fraction(&b, n2, d2);
    gst_value_set_fraction_range(v, &a, &b);
}

pub export fn gst_value_get_fraction_range_min(v: [*c]const Value) [*c]const Value {
    if (!check.that(holds(v, value._gst_fraction_range_type), "gst_value_get_fraction_range_min", "GST_VALUE_HOLDS_FRACTION_RANGE (value)")) return null;
    if (v[0].data[0].v_pointer == null) return null;
    return &fracPair(v)[0];
}

pub export fn gst_value_get_fraction_range_max(v: [*c]const Value) [*c]const Value {
    if (!check.that(holds(v, value._gst_fraction_range_type), "gst_value_get_fraction_range_max", "GST_VALUE_HOLDS_FRACTION_RANGE (value)")) return null;
    if (v[0].data[0].v_pointer == null) return null;
    return &fracPair(v)[1];
}

pub fn fractionRangeSerialize(v: [*c]const Value) callconv(.c) [*c]u8 {
    if (v[0].data[0].v_pointer == null) return c.g_strdup("[ 0/1, 0/1 ]");
    const a = fractionSerialize(&fracPair(v)[0]);
    const b = fractionSerialize(&fracPair(v)[1]);
    defer c.g_free(a);
    defer c.g_free(b);
    return c.g_strdup_printf("[ %s, %s ]", a, b);
}

pub fn fractionRangeToString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = fractionRangeSerialize(src);
}

pub fn fractionRangeCompare(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    if (a[0].data[0].v_pointer == b[0].data[0].v_pointer) return c.GST_VALUE_EQUAL;
    if (a[0].data[0].v_pointer == null or b[0].data[0].v_pointer == null) return c.GST_VALUE_UNORDERED;
    if (fractionCompare(&fracPair(a)[0], &fracPair(b)[0]) == c.GST_VALUE_EQUAL and fractionCompare(&fracPair(a)[1], &fracPair(b)[1]) == c.GST_VALUE_EQUAL) return c.GST_VALUE_EQUAL;
    return c.GST_VALUE_UNORDERED;
}

pub fn fractionInit(v: [*c]Value) callconv(.c) void {
    v[0].data[0].v_int = 0;
    v[0].data[1].v_int = 1;
}

pub fn fractionCopy(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_int = src[0].data[0].v_int;
    dest[0].data[1].v_int = src[0].data[1].v_int;
}

const MAX_INT = std.math.maxInt(c.gint);

pub fn fractionCollect(v: [*c]Value, n: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    const f = "gst_value_collect_fraction";
    if (n != 2) return failMsg(f, "n_collect_values == 2", "not enough value locations for `%s' passed", v);
    if (x[1].v_int == 0) return failMsg(f, "collect_values[1].v_int != 0", "passed '0' as denominator for `%s'", v);
    if (x[0].v_int < -MAX_INT) return failMsg(f, "collect_values[0].v_int >= -G_MAXINT", "passed value smaller than -G_MAXINT as numerator for `%s'", v);
    if (x[1].v_int < -MAX_INT) return failMsg(f, "collect_values[1].v_int >= -G_MAXINT", "passed value smaller than -G_MAXINT as denominator for `%s'", v);
    gst_value_set_fraction(v, x[0].v_int, x[1].v_int);
    return null;
}

pub fn fractionLcopy(v: [*c]const Value, _: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    if (x[0].v_pointer == null) return failMsg("gst_value_lcopy_fraction", "numerator != NULL", "numerator for `%s' passed as NULL", v);
    if (x[1].v_pointer == null) return failMsg("gst_value_lcopy_fraction", "denominator != NULL", "denominator for `%s' passed as NULL", v);
    @as(*c.gint, @ptrCast(@alignCast(x[0].v_pointer))).* = v[0].data[0].v_int;
    @as(*c.gint, @ptrCast(@alignCast(x[1].v_pointer))).* = v[0].data[1].v_int;
    return null;
}

pub export fn gst_value_set_fraction(v: [*c]Value, num_in: c.gint, den_in: c.gint) void {
    const f = "gst_value_set_fraction";
    if (!check.that(holds(v, value._gst_fraction_type), f, "GST_VALUE_HOLDS_FRACTION (value)")) return;
    if (!check.that(den_in != 0, f, "denominator != 0")) return;
    if (!check.that(den_in >= -MAX_INT, f, "denominator >= -G_MAXINT")) return;
    if (!check.that(num_in >= -MAX_INT, f, "numerator >= -G_MAXINT")) return;
    var num = num_in;
    var den = den_in;
    if (den < 0) {
        num = -num;
        den = -den;
    }
    const g = util.gst_util_greatest_common_divisor(num, den);
    if (g != 0) {
        num = @divTrunc(num, g);
        den = @divTrunc(den, g);
    }
    v[0].data[0].v_int = num;
    v[0].data[1].v_int = den;
}

pub export fn gst_value_get_fraction_numerator(v: [*c]const Value) c.gint {
    if (!check.that(holds(v, value._gst_fraction_type), "gst_value_get_fraction_numerator", "GST_VALUE_HOLDS_FRACTION (value)")) return 0;
    return v[0].data[0].v_int;
}

pub export fn gst_value_get_fraction_denominator(v: [*c]const Value) c.gint {
    if (!check.that(holds(v, value._gst_fraction_type), "gst_value_get_fraction_denominator", "GST_VALUE_HOLDS_FRACTION (value)")) return 1;
    return v[0].data[1].v_int;
}

pub export fn gst_value_fraction_multiply(product: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const f = "gst_value_fraction_multiply";
    if (!check.that(product != null, f, "product != NULL")) return 0;
    if (!check.that(holds(a, value._gst_fraction_type), f, "GST_VALUE_HOLDS_FRACTION (factor1)")) return 0;
    if (!check.that(holds(b, value._gst_fraction_type), f, "GST_VALUE_HOLDS_FRACTION (factor2)")) return 0;
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (util.gst_util_fraction_multiply(a[0].data[0].v_int, a[0].data[1].v_int, b[0].data[0].v_int, b[0].data[1].v_int, &n, &d) == 0) return 0;
    gst_value_set_fraction(product, n, d);
    return 1;
}

pub export fn gst_value_fraction_subtract(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const f = "gst_value_fraction_subtract";
    if (!check.that(dest != null, f, "dest != NULL")) return 0;
    if (!check.that(holds(a, value._gst_fraction_type), f, "GST_VALUE_HOLDS_FRACTION (minuend)")) return 0;
    if (!check.that(holds(b, value._gst_fraction_type), f, "GST_VALUE_HOLDS_FRACTION (subtrahend)")) return 0;
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (util.gst_util_fraction_add(a[0].data[0].v_int, a[0].data[1].v_int, -b[0].data[0].v_int, b[0].data[1].v_int, &n, &d) == 0) return 0;
    gst_value_set_fraction(dest, n, d);
    return 1;
}

pub fn fractionSerialize(v: [*c]const Value) callconv(.c) [*c]u8 {
    var n = v[0].data[0].v_int;
    var d = v[0].data[1].v_int;
    var positive = true;
    if (n < 0) {
        n = -%n;
        positive = !positive;
    }
    if (d < 0) {
        d = -%d;
        positive = !positive;
    }
    return c.g_strdup_printf("%s%d/%d", @as([*c]const u8, if (positive) "" else "-"), n, d);
}

fn scanInt(s: [*c]const u8, pos: *usize, out: *c.gint) bool {
    var i = pos.*;
    while (std.ascii.isWhitespace(s[i])) i += 1;
    const start = i;
    if (s[i] == '-' or s[i] == '+') i += 1;
    if (!std.ascii.isDigit(s[i])) return false;
    while (std.ascii.isDigit(s[i])) i += 1;
    const n = std.fmt.parseInt(i64, s[start..i], 10) catch std.math.maxInt(i64);
    out.* = @truncate(std.math.clamp(n, std.math.minInt(i64), std.math.maxInt(i64)));
    if (n > std.math.maxInt(c.gint) or n < std.math.minInt(c.gint)) out.* = if (n > 0) -1 else 0;
    pos.* = i;
    return true;
}

pub fn fractionDeserialize(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    if (s == null) return 0;
    if (dest == null or !holds(dest, value._gst_fraction_type)) return 0;
    var pos: usize = 0;
    var num: c.gint = 0;
    var den: c.gint = 0;
    if (scanInt(s, &pos, &num)) {
        var p2 = pos;
        if (s[p2] == '/') {
            p2 += 1;
            if (scanInt(s, &p2, &den)) {
                if (s[p2] != 0) return 0;
                if (den == 0) return 0;
                gst_value_set_fraction(dest, num, den);
                return 1;
            }
        }
    }
    if (c.g_ascii_strcasecmp(s, "1/max") == 0) {
        gst_value_set_fraction(dest, 1, MAX_INT);
        return 1;
    }
    pos = 0;
    if (scanInt(s, &pos, &num)) {
        if (s[pos] != 0) return 0;
        gst_value_set_fraction(dest, num, 1);
        return 1;
    }
    if (c.g_ascii_strcasecmp(s, "min") == 0) {
        gst_value_set_fraction(dest, -MAX_INT, 1);
        return 1;
    }
    if (c.g_ascii_strcasecmp(s, "max") == 0) {
        gst_value_set_fraction(dest, MAX_INT, 1);
        return 1;
    }
    return 0;
}

pub fn fractionToString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = fractionSerialize(src);
}

pub fn stringToFraction(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    if (fractionDeserialize(dest, @ptrCast(src[0].data[0].v_pointer)) == 0) gst_value_set_fraction(dest, 0, 1);
}

pub fn doubleToFraction(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    var n: c.gint = 0;
    var d: c.gint = 0;
    util.gst_util_double_to_fraction(c.g_value_get_double(src), &n, &d);
    gst_value_set_fraction(dest, n, d);
}

pub fn floatToFraction(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    var n: c.gint = 0;
    var d: c.gint = 0;
    util.gst_util_double_to_fraction(c.g_value_get_float(src), &n, &d);
    gst_value_set_fraction(dest, n, d);
}

pub fn fractionToDouble(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_double = @as(f64, @floatFromInt(src[0].data[0].v_int)) / @as(f64, @floatFromInt(src[0].data[1].v_int));
}

pub fn fractionToFloat(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_float = @as(f32, @floatFromInt(src[0].data[0].v_int)) / @as(f32, @floatFromInt(src[0].data[1].v_int));
}

pub fn fractionCompare(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const n1 = a[0].data[0].v_int;
    const n2 = b[0].data[0].v_int;
    const d1 = a[0].data[1].v_int;
    const d2 = b[0].data[1].v_int;
    if (n1 == n2 and d1 == d2) return c.GST_VALUE_EQUAL;
    if (d1 == 0 and d2 == 0) return c.GST_VALUE_UNORDERED;
    if (d1 == 0) return c.GST_VALUE_GREATER_THAN;
    if (d2 == 0) return c.GST_VALUE_LESS_THAN;
    const r = util.gst_util_fraction_compare(n1, d1, n2, d2);
    if (r == -1) return c.GST_VALUE_LESS_THAN;
    if (r == 1) return c.GST_VALUE_GREATER_THAN;
    check.unreachableAt("../gst/gstvalue.c", 8015, "gst_value_compare_fraction");
    return c.GST_VALUE_UNORDERED;
}

pub fn bitmaskInit(v: [*c]Value) callconv(.c) void {
    v[0].data[0].v_uint64 = 0;
}

pub fn bitmaskCopy(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_uint64 = src[0].data[0].v_uint64;
}

pub fn bitmaskCollect(v: [*c]Value, n: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    if (n != 1) return failMsg("gst_value_collect_bitmask", "n_collect_values == 1", "not enough value locations for `%s' passed", v);
    gst_value_set_bitmask(v, @bitCast(cvals(cv)[0].v_int64));
    return null;
}

pub fn bitmaskLcopy(v: [*c]const Value, _: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const p = cvals(cv)[0].v_pointer;
    if (p == null) return failMsg("gst_value_lcopy_bitmask", "bitmask != NULL", "value for `%s' passed as NULL", v);
    @as(*u64, @ptrCast(@alignCast(p))).* = v[0].data[0].v_uint64;
    return null;
}

pub export fn gst_value_set_bitmask(v: [*c]Value, mask: c.guint64) void {
    if (!check.that(holds(v, value._gst_bitmask_type), "gst_value_set_bitmask", "GST_VALUE_HOLDS_BITMASK (value)")) return;
    v[0].data[0].v_uint64 = mask;
}

pub export fn gst_value_get_bitmask(v: [*c]const Value) c.guint64 {
    if (!check.that(holds(v, value._gst_bitmask_type), "gst_value_get_bitmask", "GST_VALUE_HOLDS_BITMASK (value)")) return 0;
    return v[0].data[0].v_uint64;
}

pub fn bitmaskSerialize(v: [*c]const Value) callconv(.c) [*c]u8 {
    return c.g_strdup_printf("0x%016lx", v[0].data[0].v_uint64);
}

pub fn bitmaskDeserialize(dest: [*c]Value, s_in: [*c]const u8) callconv(.c) c.gboolean {
    if (s_in == null) return 0;
    if (dest == null or !holds(dest, value._gst_bitmask_type)) return 0;
    var s = s_in;
    var base: c.guint = 16;
    if (c.g_str_has_prefix(s, "0b") != 0 or c.g_str_has_prefix(s, "0B") != 0) {
        s += 2;
        base = 2;
    }
    var end: [*c]u8 = null;
    std.c._errno().* = 0;
    const v = c.g_ascii_strtoull(s, &end, base);
    const e = std.c._errno().*;
    if (v == std.math.maxInt(u64) and (e == @intFromEnum(std.c.E.RANGE) or e == @intFromEnum(std.c.E.INVAL))) return 0;
    if (v == 0 and end == s) return 0;
    gst_value_set_bitmask(dest, v);
    return 1;
}

pub fn bitmaskToString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = bitmaskSerialize(src);
}

pub fn stringToBitmask(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    if (bitmaskDeserialize(dest, @ptrCast(src[0].data[0].v_pointer)) == 0) gst_value_set_bitmask(dest, 0);
}

pub fn u64Passthrough(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_uint64 = src[0].data[0].v_uint64;
}

pub fn bitmaskCompare(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return if (a[0].data[0].v_uint64 == b[0].data[0].v_uint64) c.GST_VALUE_EQUAL else c.GST_VALUE_UNORDERED;
}

pub const FlagSetClass = extern struct {
    parent: c.GTypeClass,
    flags_type: c.GType,
};

pub fn holdsFlagSet(v: [*c]const Value) bool {
    return v != null and v.*.g_type != 0 and c.g_type_is_a(v.*.g_type, value._gst_flagset_type) != 0;
}

pub fn flagsetInit(v: [*c]Value) callconv(.c) void {
    v[0].data[0].v_uint = 0;
    v[0].data[1].v_uint = 0;
}

pub fn flagsetCopy(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_uint = src[0].data[0].v_uint;
    dest[0].data[1].v_uint = src[0].data[1].v_uint;
}

pub fn flagsetCollect(v: [*c]Value, n: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    if (n != 2) return failMsg("gst_value_collect_flagset", "n_collect_values == 2", "not enough value locations for `%s' passed", v);
    const x = cvals(cv);
    gst_value_set_flagset(v, @bitCast(x[0].v_int), @bitCast(x[1].v_int));
    return null;
}

pub fn flagsetLcopy(v: [*c]const Value, _: c.guint, cv: ?*CV, _: c.guint) callconv(.c) [*c]u8 {
    const x = cvals(cv);
    @as(*c.guint, @ptrCast(@alignCast(x[0].v_pointer))).* = v[0].data[0].v_uint;
    @as(*c.guint, @ptrCast(@alignCast(x[1].v_pointer))).* = v[0].data[1].v_uint;
    return null;
}

pub export fn gst_value_set_flagset(v: [*c]Value, flags: c.guint, mask: c.guint) void {
    if (!check.that(holdsFlagSet(v), "gst_value_set_flagset", "GST_VALUE_HOLDS_FLAG_SET (value)")) return;
    v[0].data[0].v_uint = flags & mask;
    v[0].data[1].v_uint = mask;
}

pub export fn gst_value_get_flagset_flags(v: [*c]const Value) c.guint {
    if (!check.that(holdsFlagSet(v), "gst_value_get_flagset_flags", "GST_VALUE_HOLDS_FLAG_SET (value)")) return 0;
    return v[0].data[0].v_uint;
}

pub export fn gst_value_get_flagset_mask(v: [*c]const Value) c.guint {
    if (!check.that(holdsFlagSet(v), "gst_value_get_flagset_mask", "GST_VALUE_HOLDS_FLAG_SET (value)")) return 1;
    return v[0].data[1].v_uint;
}

pub fn flagsetSerialize(v: [*c]const Value) callconv(.c) [*c]u8 {
    const flags = v[0].data[0].v_uint;
    var mask = v[0].data[1].v_uint;
    const klass: *FlagSetClass = @ptrCast(@alignCast(c.g_type_class_ref(v.*.g_type)));
    defer c.g_type_class_unref(klass);
    var out = c.g_strdup_printf("%x:%x", flags, mask);
    if (mask != 0 and klass.flags_type != 0) {
        const fk: [*c]c.GFlagsClass = @ptrCast(@alignCast(c.g_type_class_ref(klass.flags_type)));
        if (!check.that(fk != null, "gst_value_serialize_flagset", "flags_klass")) return null;
        defer c.g_type_class_unref(fk);
        var first = true;
        while (mask != 0) {
            const fv = c.g_flags_get_first_value(fk, mask);
            if (fv == null) break;
            const next = c.g_strconcat(out, @as([*c]const u8, if (first) ":" else ""), @as([*c]const u8, if (flags & fv.*.value != 0) "+" else "/"), fv.*.value_nick, @as(?*anyopaque, null));
            c.g_free(out);
            out = next;
            first = false;
            mask &= ~fv.*.value;
        }
    }
    return out;
}

fn validFlagsString(s: [*c]const u8) bool {
    return c.g_regex_match_simple("^([\\+\\/][\\w\\d-]+)+$", s, c.G_REGEX_CASELESS, 0) != 0;
}

pub fn flagsFromString(klass: [*c]c.GFlagsClass, s: [*c]const u8, out_flags: ?*c.guint, out_mask: ?*c.guint) bool {
    if (!check.that(klass != null, "gst_value_gflags_str_to_flags", "klass")) return false;
    var flags: c.guint = 0;
    var mask: c.guint = 0;
    var pos = s;
    if (pos[0] != 0) {
        var delim: u8 = '+';
        if (pos[0] == '/' or pos[0] == '+') {
            delim = pos[0];
            pos += 1;
        }
        while (true) {
            var next = pos;
            while (next[0] != 0 and next[0] != '+' and next[0] != '/') next += 1;
            const part = c.g_strndup(pos, @intFromPtr(next) - @intFromPtr(pos));
            var val: c.guint = 0;
            if (c.g_flags_get_value_by_name(klass, part)) |fv| {
                val = fv.*.value;
            } else if (c.g_flags_get_value_by_nick(klass, part)) |fv| {
                val = fv.*.value;
            } else {
                var endp: [*c]u8 = null;
                val = @truncate(c.strtoul(part, &endp, 0));
                if (endp == null or endp[0] != 0) {
                    c.g_free(part);
                    return false;
                }
            }
            c.g_free(part);
            if (val != 0) {
                mask |= val;
                if (delim == '+') flags |= val;
            }
            pos = next;
            delim = pos[0];
            pos += 1;
            if (delim == 0) break;
        }
    }
    if (out_flags) |p| p.* = flags;
    if (out_mask) |p| p.* = mask;
    return true;
}

pub fn flagsetDeserialize(dest: [*c]Value, s_in: [*c]const u8) callconv(.c) c.gboolean {
    if (s_in == null) return 0;
    if (dest == null or !holdsFlagSet(dest)) return 0;
    var flags: c.guint = 0;
    var mask: c.guint = 0;
    var next: [*c]u8 = null;
    const errno = std.c._errno();
    flags = @truncate(c.strtoul(s_in, &next, 16));
    var hex = !((flags == 0 and errno.* == @intFromEnum(std.c.E.INVAL)) or next == s_in);
    if (hex) {
        if (next[0] == ':') next += 1;
        var cur = next;
        mask = @truncate(c.strtoul(cur, &next, 16));
        if ((mask == 0 and errno.* == @intFromEnum(std.c.E.INVAL)) or cur == next) {
            hex = false;
        } else {
            if (c.g_str_has_prefix(cur, "0x") != 0 or c.g_str_has_prefix(cur, "0X") != 0) cur += 2;
            if (@intFromPtr(next) - @intFromPtr(cur) > 8) return 0;
            if (next[0] != 0) {
                if (next[0] != ':') return 0;
                const rest = next + 1;
                if (std.mem.orderZ(u8, c.g_type_name(dest.*.g_type), "GstFlagSet") == .eq and !validFlagsString(rest)) return 0;
            }
            gst_value_set_flagset(dest, flags, mask);
            return 1;
        }
    }
    const set_name = c.g_type_name(dest.*.g_type);
    if (std.mem.orderZ(u8, set_name, "GstFlagSet") == .eq) return 0;
    var fk: [*c]c.GFlagsClass = null;
    const tail = c.g_strrstr(set_name, "Set");
    if (tail != null) {
        const base = c.g_strndup(set_name, @intFromPtr(tail) - @intFromPtr(set_name));
        const ft = c.g_type_from_name(base);
        if (ft == 0) if (@import("value.zig").dynamic_load) |load| {
            _ = load(base);
        };
        if (ft != 0) fk = @ptrCast(@alignCast(c.g_type_class_ref(ft)));
        c.g_free(base);
    }
    if (fk == null) return 0;
    const ok = flagsFromString(fk, s_in, &flags, &mask);
    c.g_type_class_unref(fk);
    if (ok) gst_value_set_flagset(dest, flags, mask);
    return @intFromBool(ok);
}

pub fn flagsetToString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = flagsetSerialize(src);
}

pub fn stringToFlagset(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    if (flagsetDeserialize(dest, @ptrCast(src[0].data[0].v_pointer)) == 0) gst_value_set_flagset(dest, 0, 0);
}

pub fn flagsetCompare(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    if (a[0].data[0].v_uint == b[0].data[0].v_uint and a[0].data[1].v_uint == b[0].data[1].v_uint) return c.GST_VALUE_EQUAL;
    return c.GST_VALUE_UNORDERED;
}

fn flagsetClassInit(klass: c.gpointer, data: c.gpointer) callconv(.c) void {
    const k: *FlagSetClass = @ptrCast(@alignCast(klass));
    k.flags_type = @intFromPtr(data);
}

pub export fn gst_flagset_register(flags_type: c.GType) c.GType {
    if (!check.that(c.g_type_fundamental(flags_type) == 13 << c.G_TYPE_FUNDAMENTAL_SHIFT, "gst_flagset_register", "G_TYPE_IS_FLAGS (flags_type)")) return 0;
    var info = std.mem.zeroes(c.GTypeInfo);
    info.class_size = @sizeOf(FlagSetClass);
    info.class_init = flagsetClassInit;
    info.class_data = @ptrFromInt(flags_type);
    const name = c.g_strdup_printf("%sSet", c.g_type_name(flags_type));
    defer c.g_free(name);
    return c.g_type_register_static(value._gst_flagset_type, c.g_intern_string(name), &info, 0);
}
