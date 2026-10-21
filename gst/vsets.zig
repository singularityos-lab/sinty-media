const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const value = @import("value.zig");
const vtypes = @import("vtypes.zig");
const vlist = @import("vlist.zig");
const util = @import("util.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Value = c.GValue;
const EQUAL = c.GST_VALUE_EQUAL;
const LESS = c.GST_VALUE_LESS_THAN;
const GREATER = c.GST_VALUE_GREATER_THAN;
const UNORDERED = c.GST_VALUE_UNORDERED;

const Op = *const fn ([*c]Value, [*c]const Value, [*c]const Value) callconv(.c) c.gboolean;
const Rule = struct { a: c.GType, b: c.GType, op: Op };

var unions: std.ArrayListUnmanaged(Rule) = .empty;
var intersections: std.ArrayListUnmanaged(Rule) = .empty;
var subtractions: std.ArrayListUnmanaged(Rule) = .empty;

fn ints(v: [*c]const Value) struct { lo: c.gint, hi: c.gint, step: c.gint } {
    return .{ .lo = vtypes.intMinPacked(v), .hi = vtypes.intMaxPacked(v), .step = vtypes.intStep(v) };
}

fn i64s(v: [*c]const Value) *[3]i64 {
    return vtypes.i64Parts(v);
}

fn holds(v: [*c]const Value, t: c.GType) bool {
    return v.*.g_type == t;
}

fn rangeSubset(a: [*c]const Value, b: [*c]const Value) bool {
    if (!check.that(holds(a, value._gst_int_range_type), "gst_value_is_subset_int_range_int_range", "GST_VALUE_HOLDS_INT_RANGE (value1)")) return false;
    if (!check.that(holds(b, value._gst_int_range_type), "gst_value_is_subset_int_range_int_range", "GST_VALUE_HOLDS_INT_RANGE (value2)")) return false;
    const x = ints(a);
    const y = ints(b);
    if (x.lo *% x.step < y.lo *% y.step) return false;
    if (x.hi *% x.step > y.hi *% y.step) return false;
    if (y.lo == y.hi) return @rem(y.lo *% y.step, x.step) == 0;
    return util.gst_util_greatest_common_divisor(x.step, y.step) == @min(x.step, y.step);
}

fn range64Subset(a: [*c]const Value, b: [*c]const Value) bool {
    if (!check.that(holds(a, value._gst_int64_range_type), "gst_value_is_subset_int64_range_int64_range", "GST_VALUE_HOLDS_INT64_RANGE (value1)")) return false;
    if (!check.that(holds(b, value._gst_int64_range_type), "gst_value_is_subset_int64_range_int64_range", "GST_VALUE_HOLDS_INT64_RANGE (value2)")) return false;
    const x = i64s(a);
    const y = i64s(b);
    if (x[0] < y[0] or x[1] > y[1]) return false;
    if (y[0] == y[1]) return @rem(y[0] *% y[2], x[2]) == 0;
    return util.gst_util_greatest_common_divisor_int64(x[2], y[2]) == @min(x[2], y[2]);
}

fn flagsetSubset(a: [*c]const Value, b: [*c]const Value) bool {
    const m1 = a[0].data[1].v_uint;
    const m2 = b[0].data[1].v_uint;
    return (a[0].data[0].v_uint & m1) == (b[0].data[0].v_uint & (m1 & m2));
}

fn listInList(a: [*c]const Value, b: [*c]const Value) bool {
    const x = vlist.items(a);
    const y = vlist.items(b);
    if (x.len > y.len) return false;
    outer: for (x) |*p| {
        for (y) |*q| {
            const r = value.gst_value_compare(p, q);
            if (r == EQUAL) continue :outer;
            if (r == UNORDERED and gst_value_is_subset(p, q) != 0) continue :outer;
        }
        return false;
    }
    return true;
}

fn itemInList(a: [*c]const Value, b: [*c]const Value) bool {
    for (vlist.items(b)) |*q| if (value.gst_value_compare(a, q) == EQUAL) return true;
    return false;
}

fn arrayInArray(sub: [*c]const Value, sup: [*c]const Value) bool {
    const small = vlist.items(sub);
    const big = vlist.items(sup);
    var is_subset = small.len <= big.len;
    var is_equal = false;
    var subsets: usize = 0;
    var equals: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while ((is_subset or is_equal) and i < small.len) : ({
        i += 1;
        j += 1;
    }) {
        const p = &small[i];
        is_equal = value.gst_value_compare(p, &big[j]) == EQUAL;
        if (is_equal) {
            equals += 1;
            continue;
        }
        is_subset = gst_value_is_subset(p, &big[j]) != 0;
        if (is_subset) {
            subsets += 1;
            continue;
        }
        if (subsets != 0 or equals != 0) continue;
        j += 1;
        while (j < big.len and j + small.len <= big.len) : (j += 1) {
            if (value.gst_value_compare(p, &big[j]) == EQUAL) {
                is_equal = true;
                equals += 1;
                break;
            }
            is_subset = gst_value_is_subset(p, &big[j]) != 0;
            if (is_subset) {
                subsets += 1;
                break;
            }
        }
    }
    if (!is_equal and !is_subset) return false;
    if (value.gst_value_is_fixed(sup) != 0 and value.gst_value_is_fixed(sub) != 0) return subsets > 0;
    return true;
}

pub export fn gst_value_is_subset(a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const ta = a.*.g_type;
    const tb = b.*.g_type;
    const st = c.gst_structure_get_type();
    if (ta == value._gst_int_range_type and tb == value._gst_int_range_type) return @intFromBool(rangeSubset(a, b));
    if (ta == value._gst_int64_range_type and tb == value._gst_int64_range_type) return @intFromBool(range64Subset(a, b));
    if (vtypes.holdsFlagSet(a) and vtypes.holdsFlagSet(b)) return @intFromBool(flagsetSubset(a, b));
    if (ta == st and tb == st) return c.gst_structure_is_subset(value.gst_value_get_structure(a), value.gst_value_get_structure(b));
    if (tb == value._gst_value_list_type or tb == value._gst_value_unique_list_type) {
        if (ta == tb) return @intFromBool(listInList(a, b));
        return @intFromBool(itemInList(a, b));
    }
    if (tb == c.gst_caps_get_type()) return c.gst_caps_is_subset(value.gst_value_get_caps(a), value.gst_value_get_caps(b));
    if (ta == value._gst_value_array_type and tb == value._gst_value_array_type) return @intFromBool(arrayInArray(a, b));
    if (gst_value_subtract(null, a, b) == 0 and gst_value_subtract(null, b, a) != 0) return 1;
    return 0;
}

fn setRangePacked(dest: [*c]Value, src: [*c]const Value, lo: u64, hi: u64) void {
    value.gst_value_init_and_copy(dest, src);
    dest[0].data[0].v_uint64 = (lo << 32) | hi;
}

fn u32of(x: c.gint) u64 {
    return @as(u32, @bitCast(x));
}

fn unionIntRange(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    const v = a[0].data[0].v_int;
    const r = ints(b);
    if (r.lo *% r.step <= v and r.hi *% r.step >= v and @rem(v, r.step) == 0) {
        if (dest != null) value.gst_value_init_and_copy(dest, b);
        return 1;
    }
    if (v == (r.lo -% 1) *% r.step) {
        if (dest != null) setRangePacked(dest, b, @bitCast(@as(i64, r.lo - 1)), @bitCast(@as(i64, r.hi)));
        return 1;
    }
    if (v == (r.hi +% 1) *% r.step) {
        if (dest != null) setRangePacked(dest, b, @bitCast(@as(i64, r.lo)), @bitCast(@as(i64, r.hi + 1)));
        return 1;
    }
    return 0;
}

fn unionRangeRange(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    if (rangeSubset(a, b)) {
        if (dest != null) value.gst_value_init_and_copy(dest, b);
        return 1;
    }
    if (rangeSubset(b, a)) {
        if (dest != null) value.gst_value_init_and_copy(dest, a);
        return 1;
    }
    const x = ints(a);
    const y = ints(b);
    if (x.step == y.step) {
        const touch = (x.lo <= y.hi +% 1 and x.hi >= y.lo -% 1) or (y.lo <= x.hi +% 1 and y.hi >= x.lo -% 1);
        if (touch) {
            if (dest != null) {
                _ = c.g_value_init(dest, value._gst_int_range_type);
                vtypes.gst_value_set_int_range_step(dest, x.step *% @min(x.lo, y.lo), x.step *% @max(x.hi, y.hi), x.step);
            }
            return 1;
        }
        return 0;
    }
    const n1 = x.hi -% x.lo +% 1;
    const n2 = y.hi -% y.lo +% 1;
    if (n1 != 1 and n2 != 1) return 0;
    const range = if (n1 == 1) b else a;
    const scalar = if (n1 == 1) x.lo *% x.step else y.lo *% y.step;
    const r = ints(range);
    if (scalar == (r.lo -% 1) *% r.step) {
        if (dest != null) setRangePacked(dest, range, u32of((r.lo -% 1) *% r.step), u32of(r.hi *% r.step));
        return 1;
    }
    if (scalar == (r.hi +% 1) *% r.step) {
        if (dest != null) setRangePacked(dest, range, u32of(r.lo *% r.step), u32of((r.hi +% 1) *% r.step));
        return 1;
    }
    return 0;
}

fn unionFlagsets(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    if (!check.that(vtypes.holdsFlagSet(a), "gst_value_union_flagset_flagset", "GST_VALUE_HOLDS_FLAG_SET (src1)")) return 0;
    if (!check.that(vtypes.holdsFlagSet(b), "gst_value_union_flagset_flagset", "GST_VALUE_HOLDS_FLAG_SET (src2)")) return 0;
    var f1 = a[0].data[0].v_uint;
    const f2 = b[0].data[0].v_uint;
    var m1 = a[0].data[1].v_uint;
    const m2 = b[0].data[1].v_uint;
    if ((f1 & (m1 & m2)) != (f2 & (m1 & m2))) return 0;
    if (dest != null) {
        _ = c.g_value_init(dest, value._gst_flagset_type);
        f1 = (f1 & ~m2) | (f2 & m2);
        m1 |= m2;
        vtypes.gst_value_set_flagset(dest, f1, m1);
    }
    return 1;
}

fn mergeInto(name: [*c]const c.GstIdStr, v: [*c]Value, data: c.gpointer) callconv(.c) c.gboolean {
    const other: [*c]const c.GstStructure = @ptrCast(@alignCast(data));
    const ov = c.gst_structure_id_str_get_value(other, name);
    if (ov == null) return 1;
    var res = std.mem.zeroes(Value);
    if (gst_value_union(&res, v, ov) == 0) return 0;
    c.g_value_unset(v);
    value.move(v, &res);
    return 1;
}

fn addMissing(name: [*c]const c.GstIdStr, v: [*c]const Value, data: c.gpointer) callconv(.c) c.gboolean {
    const result: [*c]c.GstStructure = @ptrCast(@alignCast(data));
    if (c.gst_structure_id_str_get_value(result, name) == null) c.gst_structure_id_str_set_value(result, name, v);
    return 1;
}

fn unionStructures(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    const st = c.gst_structure_get_type();
    if (!check.that(holds(a, st), "gst_value_union_structure_structure", "GST_VALUE_HOLDS_STRUCTURE (src1)")) return 0;
    if (!check.that(holds(b, st), "gst_value_union_structure_structure", "GST_VALUE_HOLDS_STRUCTURE (src2)")) return 0;
    const s1 = value.gst_value_get_structure(a);
    const s2 = value.gst_value_get_structure(b);
    if (c.gst_structure_has_name(s1, c.gst_structure_get_name(s2)) == 0) {
        vlist.gst_value_list_concat(dest, a, b);
        return 1;
    }
    const result = c.gst_structure_copy(s1);
    defer c.gst_structure_free(result);
    if (c.gst_structure_map_in_place_id_str(result, mergeInto, @constCast(s2)) == 0) return 0;
    if (c.gst_structure_foreach_id_str(s2, addMissing, result) == 0) return 0;
    _ = c.g_value_init(dest, st);
    value.gst_value_set_structure(dest, result);
    return 1;
}

const Frac = struct { n: c.gint, d: c.gint };

fn frac(v: [*c]const Value) Frac {
    return .{ .n = v[0].data[0].v_int, .d = v[0].data[1].v_int };
}

fn fcmp(a: Frac, b: Frac) c.gint {
    return util.gst_util_fraction_compare(a.n, a.d, b.n, b.d);
}

fn unionFracRange(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    if (!check.that(holds(a, value._gst_fraction_type), "gst_value_union_fraction_fraction_range", "GST_VALUE_HOLDS_FRACTION (src1)")) return 0;
    if (!check.that(holds(b, value._gst_fraction_range_type), "gst_value_union_fraction_fraction_range", "GST_VALUE_HOLDS_FRACTION_RANGE (src2)")) return 0;
    const f = frac(a);
    const pair = vtypes.fracPair(b);
    if (fcmp(f, frac(&pair[0])) >= 0 and fcmp(f, frac(&pair[1])) <= 0) {
        if (dest != null) value.gst_value_init_and_copy(dest, b);
        return 1;
    }
    return 0;
}

fn unionFracRanges(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    const f = "gst_value_union_fraction_range_fraction_range";
    if (!check.that(holds(a, value._gst_fraction_range_type), f, "GST_VALUE_HOLDS_FRACTION_RANGE (src1)")) return 0;
    if (!check.that(holds(b, value._gst_fraction_range_type), f, "GST_VALUE_HOLDS_FRACTION_RANGE (src2)")) return 0;
    if (!check.that(a[0].data[0].v_pointer != null, f, "vals1 != NULL")) return 0;
    if (!check.that(b[0].data[0].v_pointer != null, f, "vals2 != NULL")) return 0;
    const p = vtypes.fracPair(a);
    const q = vtypes.fracPair(b);
    const s1 = frac(&p[0]);
    const e1 = frac(&p[1]);
    const s2 = frac(&q[0]);
    const e2 = frac(&q[1]);
    if (fcmp(e2, s1) < 0 or fcmp(e1, s2) < 0) return 0;
    if (dest == null) return 1;
    const s = if (fcmp(s1, s2) < 0) s1 else s2;
    const e = if (fcmp(e1, e2) > 0) e1 else e2;
    _ = c.g_value_init(dest, value._gst_fraction_range_type);
    vtypes.gst_value_set_fraction_range_full(dest, s.n, s.d, e.n, e.d);
    return 1;
}

fn unionSets(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    vlist.gst_value_unique_list_concat(dest, a, b);
    return 1;
}

fn findRule(rules: []const Rule, a: c.GType, b: c.GType) ?struct { op: Op, swap: bool } {
    for (rules) |r| {
        if (r.a == a and r.b == b) return .{ .op = r.op, .swap = false };
        if (r.a == b and r.b == a) return .{ .op = r.op, .swap = true };
    }
    return null;
}

pub export fn gst_value_can_union(a: [*c]const Value, b: [*c]const Value) c.gboolean {
    if (!check.that(value.isValue(a), "gst_value_can_union", "G_IS_VALUE (value1)")) return 0;
    if (!check.that(value.isValue(b), "gst_value_can_union", "G_IS_VALUE (value2)")) return 0;
    return @intFromBool(findRule(unions.items, a.*.g_type, b.*.g_type) != null);
}

pub export fn gst_value_union(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    if (!check.that(dest != null, "gst_value_union", "dest != NULL")) return 0;
    if (!check.that(value.isValue(a), "gst_value_union", "G_IS_VALUE (value1)")) return 0;
    if (!check.that(value.isValue(b), "gst_value_union", "G_IS_VALUE (value2)")) return 0;
    if (!check.that(vlist.compatible(a, b), "gst_value_union", "gst_value_list_or_array_are_compatible (value1, value2)")) return 0;
    if (findRule(unions.items, a.*.g_type, b.*.g_type)) |r| return if (r.swap) r.op(dest, b, a) else r.op(dest, a, b);
    vlist.gst_value_list_concat(dest, a, b);
    return 1;
}

fn intersectIntRange(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    const r = ints(b);
    const v = a[0].data[0].v_int;
    if (r.lo *% r.step <= v and r.hi *% r.step >= v and @rem(v, r.step) == 0) {
        if (dest != null) value.gst_value_init_and_copy(dest, a);
        return 1;
    }
    return 0;
}

fn intersectRanges(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const x = ints(a);
    const y = ints(b);
    var step = @divTrunc(x.step, util.gst_util_greatest_common_divisor(x.step, y.step));
    if (@divTrunc(std.math.maxInt(i32), y.step) < step) return 0;
    step *%= y.step;
    var lo = @max(x.lo *% x.step, y.lo *% y.step);
    lo = @divTrunc(lo +% step -% 1, step) *% step;
    var hi = @min(x.hi *% x.step, y.hi *% y.step);
    hi = @divTrunc(hi, step) *% step;
    if (lo < hi) {
        if (dest != null) {
            _ = c.g_value_init(dest, value._gst_int_range_type);
            vtypes.gst_value_set_int_range_step(dest, lo, hi, step);
        }
        return 1;
    }
    if (lo == hi) {
        if (dest != null) {
            _ = c.g_value_init(dest, c.G_TYPE_INT);
            c.g_value_set_int(dest, lo);
        }
        return 1;
    }
    return 0;
}

fn intersectInt64Range(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    const r = i64s(b);
    const v = a[0].data[0].v_int64;
    if (r[0] *% r[2] <= v and r[1] *% r[2] >= v and @rem(v, r[2]) == 0) {
        if (dest != null) value.gst_value_init_and_copy(dest, a);
        return 1;
    }
    return 0;
}

fn intersectRanges64(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const x = i64s(a);
    const y = i64s(b);
    var step = @divTrunc(x[2], util.gst_util_greatest_common_divisor_int64(x[2], y[2]));
    if (@divTrunc(std.math.maxInt(i64), y[2]) < step) return 0;
    step *%= y[2];
    var lo = @max(x[0] *% x[2], y[0] *% y[2]);
    lo = @divTrunc(lo +% step -% 1, step) *% step;
    var hi = @min(x[1] *% x[2], y[1] *% y[2]);
    hi = @divTrunc(hi, step) *% step;
    if (lo < hi) {
        if (dest != null) {
            _ = c.g_value_init(dest, value._gst_int64_range_type);
            vtypes.gst_value_set_int64_range_step(dest, lo, hi, step);
        }
        return 1;
    }
    if (lo == hi) {
        if (dest != null) {
            _ = c.g_value_init(dest, c.G_TYPE_INT64);
            c.g_value_set_int64(dest, lo);
        }
        return 1;
    }
    return 0;
}

fn intersectDoubleRange(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    const v = a[0].data[0].v_double;
    if (b[0].data[0].v_double <= v and b[0].data[1].v_double >= v) {
        if (dest != null) value.gst_value_init_and_copy(dest, a);
        return 1;
    }
    return 0;
}

fn intersectDoubleRanges(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const lo = @max(a[0].data[0].v_double, b[0].data[0].v_double);
    const hi = @min(a[0].data[1].v_double, b[0].data[1].v_double);
    if (lo < hi) {
        if (dest != null) {
            _ = c.g_value_init(dest, value._gst_double_range_type);
            vtypes.gst_value_set_double_range(dest, lo, hi);
        }
        return 1;
    }
    if (lo == hi) {
        if (dest != null) {
            _ = c.g_value_init(dest, c.G_TYPE_DOUBLE);
            c.g_value_set_int(dest, @intFromFloat(lo));
        }
        return 1;
    }
    return 0;
}

fn baseType(v: [*c]const Value) ?c.GType {
    if (vlist.isListLike(v)) {
        const items = vlist.items(v);
        if (items.len == 0) return null;
        return baseType(&items[0]);
    }
    return v.*.g_type;
}

fn intersectListList(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const ta = baseType(a) orelse return 0;
    const tb = baseType(b) orelse return 0;
    if (ta != tb) return 0;
    const x = vlist.items(a);
    const y = vlist.items(b);
    if (dest == null) {
        for (x) |*p| for (y) |*q| if (gst_value_intersect(null, p, q) != 0) return 1;
        return 0;
    }
    const seen = std.heap.c_allocator.alloc(bool, y.len) catch @panic("out of memory");
    defer std.heap.c_allocator.free(seen);
    @memset(seen, false);
    const out = vlist.create(@intCast(@min(x.len, y.len)));
    var start: usize = 0;
    var found = false;
    for (x) |*p| {
        var j = start;
        while (j < y.len) : (j += 1) {
            if (seen[j]) continue;
            if (gst_value_intersect(&out.fields[out.len], p, &y[j]) != 0) {
                found = true;
                seen[j] = true;
                if (j == start) start += 1;
                out.len += 1;
                break;
            }
        }
    }
    if (!found) {
        vlist.destroy(out);
        return 0;
    }
    if (out.len == 1 and a.*.g_type != value._gst_value_unique_list_type) {
        value.move(dest, &out.fields[0]);
        vlist.destroy(out);
    } else {
        dest.*.g_type = a.*.g_type;
        dest[0].data[0].v_pointer = out;
    }
    return 1;
}

fn intersectList(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const ta = a.*.g_type;
    const tb = b.*.g_type;
    if (ta == tb and (ta == value._gst_value_list_type or ta == value._gst_value_unique_list_type)) return intersectListList(dest, a, b);
    if (ta == value._gst_value_unique_list_type and tb == value._gst_value_list_type) return intersectList(dest, b, a);
    var ok = false;
    for (vlist.items(a)) |*cur| {
        if (dest == null) {
            if (gst_value_intersect(null, cur, b) != 0) return 1;
            continue;
        }
        var part = std.mem.zeroes(Value);
        if (gst_value_intersect(&part, cur, b) == 0) continue;
        if (!ok) {
            value.move(dest, &part);
            ok = true;
        } else if (dest.*.g_type == value._gst_value_list_type) {
            vlist.appendTake(dest, &part);
        } else {
            var prev: Value = undefined;
            value.move(&prev, dest);
            vlist.gst_value_list_merge(dest, &prev, &part);
            c.g_value_unset(&prev);
            c.g_value_unset(&part);
        }
    }
    return @intFromBool(ok);
}

fn intersectArrays(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const x = vlist.items(a);
    const y = vlist.items(b);
    if (x.len != y.len) return 0;
    if (dest == null) {
        for (x, y) |*p, *q| if (gst_value_intersect(null, p, q) == 0) return 0;
        return 1;
    }
    _ = c.g_value_init(dest, value._gst_value_array_type);
    for (x, y) |*p, *q| {
        var part = std.mem.zeroes(Value);
        if (gst_value_intersect(&part, p, q) == 0) {
            c.g_value_unset(dest);
            return 0;
        }
        vlist.pushTake(vlist.of(dest), &part);
    }
    return 1;
}

fn intersectFracRange(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gboolean {
    if (b[0].data[0].v_pointer == null) return 0;
    const pair = vtypes.fracPair(b);
    const r1 = vtypes.fractionCompare(&pair[0], a);
    const r2 = vtypes.fractionCompare(&pair[1], a);
    if ((r1 == EQUAL or r1 == LESS) and (r2 == EQUAL or r2 == GREATER)) {
        if (dest != null) value.gst_value_init_and_copy(dest, a);
        return 1;
    }
    return 0;
}

fn intersectFracRanges(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const p = vtypes.fracPair(a);
    const q = vtypes.fracPair(b);
    const lo: *Value = if (vtypes.fractionCompare(&p[0], &q[0]) == LESS) &q[0] else &p[0];
    const hi: *Value = if (vtypes.fractionCompare(&p[1], &q[1]) == GREATER) &q[1] else &p[1];
    const r = vtypes.fractionCompare(lo, hi);
    if (r == LESS) {
        if (dest != null) {
            _ = c.g_value_init(dest, value._gst_fraction_range_type);
            const out = vtypes.fracPair(dest);
            c.g_value_copy(lo, &out[0]);
            c.g_value_copy(hi, &out[1]);
        }
        return 1;
    }
    if (r == EQUAL) {
        if (dest != null) value.gst_value_init_and_copy(dest, lo);
        return 1;
    }
    return 0;
}

fn intersectFlagsets(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const f1 = a[0].data[0].v_uint;
    const f2 = b[0].data[0].v_uint;
    const m1 = a[0].data[1].v_uint;
    const m2 = b[0].data[1].v_uint;
    if ((f1 & (m1 & m2)) != (f2 & (m1 & m2))) return 0;
    const generic = value._gst_flagset_type;
    const ta = a.*.g_type;
    const tb = b.*.g_type;
    if (ta != tb and ta != generic and tb != generic) return 0;
    if (dest != null) {
        _ = c.g_value_init(dest, if (ta != generic) ta else tb);
        dest[0].data[0].v_uint = (f1 & m1) | (f2 & m2);
        dest[0].data[1].v_uint = m1 | m2;
    }
    return 1;
}

fn intersectStructures(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const d = c.gst_structure_intersect(value.gst_value_get_structure(a), value.gst_value_get_structure(b));
    if (d == null) return 0;
    if (dest != null) {
        _ = c.g_value_init(dest, c.gst_structure_get_type());
        value.gst_value_set_structure(dest, d);
    }
    c.gst_structure_free(d);
    return 1;
}

fn intersectCaps(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    const x: [*c]c.GstCaps = @ptrCast(@alignCast(c.g_value_get_boxed(a)));
    const y: [*c]c.GstCaps = @ptrCast(@alignCast(c.g_value_get_boxed(b)));
    if (!check.that(x != null, "gst_value_intersect_caps", "caps1 != NULL")) return 0;
    if (!check.that(y != null, "gst_value_intersect_caps", "caps2 != NULL")) return 0;
    const inter = c.gst_caps_intersect(x, y);
    const empty = c.gst_caps_is_empty(inter) != 0;
    if (dest != null) {
        const ct = c.gst_caps_get_type();
        if (dest.*.g_type != ct) {
            if (dest.*.g_type != 0) c.g_value_unset(dest);
            _ = c.g_value_init(dest, ct);
        }
        value.gst_value_set_caps(dest, inter);
    }
    c.gst_mini_object_unref(@ptrCast(inter));
    return @intFromBool(!empty);
}

pub export fn gst_value_can_intersect(a: [*c]const Value, b: [*c]const Value) c.gboolean {
    if (!check.that(value.isValue(a), "gst_value_can_intersect", "G_IS_VALUE (value1)")) return 0;
    if (!check.that(value.isValue(b), "gst_value_can_intersect", "G_IS_VALUE (value2)")) return 0;
    const ta = a.*.g_type;
    const tb = b.*.g_type;
    if (ta == tb) return 1;
    const l = value._gst_value_list_type;
    const u = value._gst_value_unique_list_type;
    if (ta == l or tb == l or ta == u or tb == u) return 1;
    if (vtypes.holdsFlagSet(a) and vtypes.holdsFlagSet(b) and (ta == value._gst_flagset_type or tb == value._gst_flagset_type)) return 1;
    if (findRule(intersections.items, ta, tb) != null) return 1;
    return @intFromBool(value.canCompare(a, b));
}

pub export fn gst_value_intersect(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) c.gboolean {
    if (!check.that(value.isValue(a), "gst_value_intersect", "G_IS_VALUE (value1)")) return 0;
    if (!check.that(value.isValue(b), "gst_value_intersect", "G_IS_VALUE (value2)")) return 0;
    const ta = a.*.g_type;
    const tb = b.*.g_type;
    const l = value._gst_value_list_type;
    const u = value._gst_value_unique_list_type;
    if (ta == l or ta == u) return intersectList(dest, a, b);
    if (tb == l or tb == u) return intersectList(dest, b, a);
    if (value.compareSameType(a, b) == EQUAL) {
        if (dest != null) {
            if (dest.*.g_type != 0) c.g_value_copy(a, dest) else value.gst_value_init_and_copy(dest, a);
        }
        return 1;
    }
    if (ta == tb) {
        if (ta == value._gst_int_range_type) return intersectRanges(dest, a, b);
        if (ta == value._gst_int64_range_type) return intersectRanges64(dest, a, b);
        if (ta == value._gst_double_range_type) return intersectDoubleRanges(dest, a, b);
        if (ta == value._gst_value_array_type) return intersectArrays(dest, a, b);
        if (ta == value._gst_fraction_range_type) return intersectFracRanges(dest, a, b);
        if (ta == value._gst_flagset_type) return intersectFlagsets(dest, a, b);
        if (ta == c.gst_structure_get_type()) return intersectStructures(dest, a, b);
        if (ta == c.gst_caps_get_type()) return intersectCaps(dest, a, b);
    } else if (findRule(intersections.items, ta, tb)) |r| {
        return if (r.swap) r.op(dest, b, a) else r.op(dest, a, b);
    }
    if (vtypes.holdsFlagSet(a) and vtypes.holdsFlagSet(b)) return intersectFlagsets(dest, a, b);
    return 0;
}

fn subtractIntRange(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    const lo = vtypes.gst_value_get_int_range_min(s);
    const hi = vtypes.gst_value_get_int_range_max(s);
    const step = vtypes.gst_value_get_int_range_step(s);
    const v = c.g_value_get_int(m);
    if (step == 0) return 0;
    if (v < lo or v > hi or @rem(v, step) != 0) {
        if (dest != null) value.gst_value_init_and_copy(dest, m);
        return 1;
    }
    return 0;
}

fn Pieces(comptime I: type, comptime range_type: *const c.GType, comptime scalar: c.GType) type {
    return struct {
        fn set(v: [*c]Value, lo: I, hi: I, step: I) void {
            if (lo < hi) {
                _ = c.g_value_init(v, range_type.*);
                if (I == c.gint) vtypes.gst_value_set_int_range_step(v, lo, hi, step) else vtypes.gst_value_set_int64_range_step(v, lo, hi, step);
            } else if (lo == hi) {
                _ = c.g_value_init(v, scalar);
                if (I == c.gint) c.g_value_set_int(v, lo) else c.g_value_set_int64(v, lo);
            }
        }

        fn make(dest: [*c]Value, lo1: I, hi1: I, lo2: I, hi2: I, step: I) c.gboolean {
            const first = lo1 <= hi1;
            const second = lo2 <= hi2;
            if (!first and !second) return 0;
            if (dest == null) return 1;
            if (first and second) {
                var x = std.mem.zeroes(Value);
                var y = std.mem.zeroes(Value);
                set(&x, lo1, hi1, step);
                set(&y, lo2, hi2, step);
                vlist.concatTake(dest, &x, &y);
            } else if (first) {
                set(dest, lo1, hi1, step);
            } else {
                set(dest, lo2, hi2, step);
            }
            return 1;
        }

        fn rangeMinusScalar(dest: [*c]Value, lo_in: I, hi_in: I, step: I, v_in: I, m: [*c]const Value) c.gboolean {
            if (step == 0) return 0;
            var lo = lo_in;
            var hi = hi_in;
            var v = v_in;
            if (v < lo or v > hi or @rem(v, step) != 0) {
                if (dest != null) value.gst_value_init_and_copy(dest, m);
                return 1;
            }
            if (v >= std.math.maxInt(I) - step + 1) {
                hi -= step;
                v -= step;
            }
            if (v <= std.math.minInt(I) + step - 1) {
                lo += step;
                v += step;
            }
            if (dest != null) _ = make(dest, lo, v - step, v + step, hi, step);
            return 1;
        }

        fn rangeMinusRange(dest: [*c]Value, lo1: I, hi1: I, s1: I, lo2: I, hi2: I, s2: I) c.gboolean {
            if (s1 != s2) return 0;
            const step = s1;
            if (step == 0) return 0;
            if (hi2 >= hi1 and lo2 <= lo1) return 0;
            if (hi2 >= hi1) return make(dest, lo1, @min(lo2 -% step, hi1), step, 0, step);
            if (lo2 <= lo1) return make(dest, @max(hi2 +% step, lo1), hi1, step, 0, step);
            return make(dest, lo1, @min(lo2 -% step, hi1), @max(hi2 +% step, lo1), hi1, step);
        }
    };
}

const P32 = Pieces(c.gint, &value._gst_int_range_type, c.G_TYPE_INT);
const P64 = Pieces(i64, &value._gst_int64_range_type, c.G_TYPE_INT64);

fn subtractRangeInt(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    return P32.rangeMinusScalar(dest, vtypes.gst_value_get_int_range_min(m), vtypes.gst_value_get_int_range_max(m), vtypes.gst_value_get_int_range_step(m), c.g_value_get_int(s), m);
}

fn subtractRangeRange(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    return P32.rangeMinusRange(dest, vtypes.gst_value_get_int_range_min(m), vtypes.gst_value_get_int_range_max(m), vtypes.gst_value_get_int_range_step(m), vtypes.gst_value_get_int_range_min(s), vtypes.gst_value_get_int_range_max(s), vtypes.gst_value_get_int_range_step(s));
}

fn subtractInt64Range(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    const lo = vtypes.gst_value_get_int64_range_min(s);
    const hi = vtypes.gst_value_get_int64_range_max(s);
    const step = vtypes.gst_value_get_int64_range_step(s);
    const v = c.g_value_get_int64(m);
    if (step == 0) return 0;
    if (v < lo or v > hi or @rem(v, step) != 0) {
        if (dest != null) value.gst_value_init_and_copy(dest, m);
        return 1;
    }
    return 0;
}

fn subtractRange64Int64(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    return P64.rangeMinusScalar(dest, vtypes.gst_value_get_int64_range_min(m), vtypes.gst_value_get_int64_range_max(m), vtypes.gst_value_get_int64_range_step(m), c.g_value_get_int64(s), m);
}

fn subtractRange64Range64(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    return P64.rangeMinusRange(dest, vtypes.gst_value_get_int64_range_min(m), vtypes.gst_value_get_int64_range_max(m), vtypes.gst_value_get_int64_range_step(m), vtypes.gst_value_get_int64_range_min(s), vtypes.gst_value_get_int64_range_max(s), vtypes.gst_value_get_int64_range_step(s));
}

fn subtractDoubleRange(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    const v = c.g_value_get_double(m);
    if (v < vtypes.gst_value_get_double_range_min(s) or v > vtypes.gst_value_get_double_range_max(s)) {
        if (dest != null) value.gst_value_init_and_copy(dest, m);
        return 1;
    }
    return 0;
}

fn keepMinuend(dest: [*c]Value, m: [*c]const Value, _: [*c]const Value) callconv(.c) c.gboolean {
    if (dest != null) value.gst_value_init_and_copy(dest, m);
    return 1;
}

fn subtractDoubleRanges(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    const lo1 = vtypes.gst_value_get_double_range_min(m);
    const hi2 = vtypes.gst_value_get_double_range_max(m);
    const hi1 = @min(vtypes.gst_value_get_double_range_min(s), hi2);
    const lo2 = @max(vtypes.gst_value_get_double_range_max(s), lo1);
    const first = lo1 < hi1;
    const second = lo2 < hi2;
    if (!first and !second) return 0;
    if (dest == null) return 1;
    if (first and second) {
        var x = std.mem.zeroes(Value);
        var y = std.mem.zeroes(Value);
        _ = c.g_value_init(&x, value._gst_double_range_type);
        vtypes.gst_value_set_double_range(&x, lo1, hi1);
        _ = c.g_value_init(&y, value._gst_double_range_type);
        vtypes.gst_value_set_double_range(&y, lo2, hi2);
        vlist.concatTake(dest, &x, &y);
    } else {
        _ = c.g_value_init(dest, value._gst_double_range_type);
        if (first) vtypes.gst_value_set_double_range(dest, lo1, hi1) else vtypes.gst_value_set_double_range(dest, lo2, hi2);
    }
    return 1;
}

fn subtractFromList(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) c.gboolean {
    var ok = false;
    for (vlist.items(m)) |*cur| {
        if (dest == null) {
            if (gst_value_subtract(null, cur, s) != 0) return 1;
            continue;
        }
        var part = std.mem.zeroes(Value);
        if (gst_value_subtract(&part, cur, s) == 0) continue;
        const dt = dest.*.g_type;
        if (!ok) {
            value.move(dest, &part);
            ok = true;
        } else if ((dt == value._gst_value_list_type or dt == value._gst_value_unique_list_type) and part.g_type != dt) {
            vlist.appendTake(dest, &part);
        } else {
            var prev: Value = undefined;
            value.move(&prev, dest);
            vlist.concatTake(dest, &prev, &part);
        }
    }
    return @intFromBool(ok);
}

fn subtractList(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) c.gboolean {
    var slots = [2]Value{ std.mem.zeroes(Value), std.mem.zeroes(Value) };
    var result: *Value = &slots[1];
    var scratch: *Value = &slots[0];
    value.gst_value_init_and_copy(result, m);
    for (vlist.items(s)) |*cur| {
        if (gst_value_subtract(scratch, result, cur) == 0) {
            c.g_value_unset(result);
            return 0;
        }
        std.mem.swap(*Value, &result, &scratch);
        c.g_value_unset(scratch);
    }
    if (dest != null) value.move(dest, result) else c.g_value_unset(result);
    return 1;
}

fn subtractFromArray(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) c.gboolean {
    const st = s.*.g_type;
    const items = vlist.items(m);
    var consumed = false;
    var started = false;
    for (items) |*kid| {
        if (kid.g_type != st) continue;
        if (!consumed and value.gst_value_compare(s, kid) == EQUAL) {
            consumed = true;
            continue;
        }
        if (dest != null) {
            if (!started) {
                _ = c.g_value_init(dest, c.g_array_get_type());
                started = true;
            }
            vlist.gst_value_array_append_value(dest, kid);
        }
    }
    if (consumed and items.len == 1) {
        if (started) c.g_value_unset(dest);
        return 0;
    }
    return 1;
}

fn subtractArray(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) c.gboolean {
    const mt = m.*.g_type;
    for (vlist.items(s)) |*kid| {
        if (kid.g_type == mt and value.gst_value_compare(m, kid) == EQUAL) return 0;
    }
    if (dest != null) value.gst_value_init_and_copy(dest, m);
    return 1;
}

fn subtractFracFracRange(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    const lo = vtypes.gst_value_get_fraction_range_min(s);
    const hi = vtypes.gst_value_get_fraction_range_max(s);
    if (vtypes.fractionCompare(m, lo) == LESS or vtypes.fractionCompare(m, hi) == GREATER) {
        if (dest != null) value.gst_value_init_and_copy(dest, m);
        return 1;
    }
    return 0;
}

fn subtractFracRanges(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) callconv(.c) c.gboolean {
    const lo1 = vtypes.gst_value_get_fraction_range_min(m);
    const hi2 = vtypes.gst_value_get_fraction_range_max(m);
    var hi1 = vtypes.gst_value_get_fraction_range_min(s);
    var lo2 = vtypes.gst_value_get_fraction_range_max(s);
    if (vtypes.fractionCompare(hi2, hi1) == LESS) hi1 = hi2;
    if (vtypes.fractionCompare(lo1, lo2) == GREATER) lo2 = lo1;
    const first = vtypes.fractionCompare(lo1, hi1) == LESS;
    const second = vtypes.fractionCompare(lo2, hi2) == LESS;
    if (!first and !second) return 0;
    if (dest == null) return 1;
    if (first and second) {
        var x = std.mem.zeroes(Value);
        var y = std.mem.zeroes(Value);
        _ = c.g_value_init(&x, value._gst_fraction_range_type);
        vtypes.gst_value_set_fraction_range(&x, lo1, hi1);
        _ = c.g_value_init(&y, value._gst_fraction_range_type);
        vtypes.gst_value_set_fraction_range(&y, lo2, hi2);
        vlist.concatTake(dest, &x, &y);
    } else {
        _ = c.g_value_init(dest, value._gst_fraction_range_type);
        if (first) vtypes.gst_value_set_fraction_range(dest, lo1, hi1) else vtypes.gst_value_set_fraction_range(dest, lo2, hi2);
    }
    return 1;
}

pub export fn gst_value_subtract(dest: [*c]Value, m: [*c]const Value, s: [*c]const Value) c.gboolean {
    if (!check.that(value.isValue(m), "gst_value_subtract", "G_IS_VALUE (minuend)")) return 0;
    if (!check.that(value.isValue(s), "gst_value_subtract", "G_IS_VALUE (subtrahend)")) return 0;
    const mt = m.*.g_type;
    const st = s.*.g_type;
    const l = value._gst_value_list_type;
    const u = value._gst_value_unique_list_type;
    const arr = value._gst_value_array_type;
    if (mt == l or mt == u) return subtractFromList(dest, m, s);
    if (st == l or st == u) return subtractList(dest, m, s);
    if (mt == arr and st != arr and value.isFixedType(st)) return subtractFromArray(dest, m, s);
    if (st == arr and mt != arr and value.isFixedType(mt)) return subtractArray(dest, m, s);
    for (subtractions.items) |r| if (r.a == mt and r.b == st) return r.op(dest, m, s);
    if (value.compareSameType(m, s) != EQUAL) {
        if (dest != null) value.gst_value_init_and_copy(dest, m);
        return 1;
    }
    return 0;
}

pub export fn gst_value_can_subtract(m: [*c]const Value, s: [*c]const Value) c.gboolean {
    if (!check.that(value.isValue(m), "gst_value_can_subtract", "G_IS_VALUE (minuend)")) return 0;
    if (!check.that(value.isValue(s), "gst_value_can_subtract", "G_IS_VALUE (subtrahend)")) return 0;
    const mt = m.*.g_type;
    const st = s.*.g_type;
    if (mt == value._gst_value_list_type or st == value._gst_value_list_type) return 1;
    const str = c.gst_structure_get_type();
    if (mt == str or st == str) return 0;
    for (subtractions.items) |r| if (r.a == mt and r.b == st) return 1;
    return @intFromBool(value.canCompare(m, s));
}

fn rule(list: *std.ArrayListUnmanaged(Rule), a: c.GType, b: c.GType, op: Op) void {
    list.append(std.heap.c_allocator, .{ .a = a, .b = b, .op = op }) catch @panic("out of memory");
}

pub fn initialize() void {
    const ir = value.gst_int_range_get_type();
    const i64r = value.gst_int64_range_get_type();
    const dr = value.gst_double_range_get_type();
    const fr = value.gst_fraction_range_get_type();
    const f = value.gst_fraction_get_type();
    rule(&intersections, c.G_TYPE_INT, ir, intersectIntRange);
    rule(&intersections, c.G_TYPE_INT64, i64r, intersectInt64Range);
    rule(&intersections, c.G_TYPE_DOUBLE, dr, intersectDoubleRange);
    rule(&intersections, f, fr, intersectFracRange);
    rule(&subtractions, c.G_TYPE_INT, ir, subtractIntRange);
    rule(&subtractions, ir, c.G_TYPE_INT, subtractRangeInt);
    rule(&subtractions, ir, ir, subtractRangeRange);
    rule(&subtractions, c.G_TYPE_INT64, i64r, subtractInt64Range);
    rule(&subtractions, i64r, c.G_TYPE_INT64, subtractRange64Int64);
    rule(&subtractions, i64r, i64r, subtractRange64Range64);
    rule(&subtractions, c.G_TYPE_DOUBLE, dr, subtractDoubleRange);
    rule(&subtractions, dr, c.G_TYPE_DOUBLE, keepMinuend);
    rule(&subtractions, dr, dr, subtractDoubleRanges);
    rule(&subtractions, f, fr, subtractFracFracRange);
    rule(&subtractions, fr, f, keepMinuend);
    rule(&subtractions, fr, fr, subtractFracRanges);
    rule(&unions, c.G_TYPE_INT, ir, unionIntRange);
    rule(&unions, ir, ir, unionRangeRange);
    rule(&unions, value.gst_flagset_get_type(), value.gst_flagset_get_type(), unionFlagsets);
    rule(&unions, c.gst_structure_get_type(), c.gst_structure_get_type(), unionStructures);
    rule(&unions, f, fr, unionFracRange);
    rule(&unions, fr, fr, unionFracRanges);
    rule(&unions, value.gst_value_unique_list_get_type(), value.gst_value_unique_list_get_type(), unionSets);
}
