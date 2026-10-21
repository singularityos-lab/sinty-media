const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const vlist = @import("vlist.zig");
const vtypes = @import("vtypes.zig");
const vbasic = @import("vbasic.zig");
const vsets = @import("vsets.zig");
const vparse = @import("vparse.zig");
const vhash = @import("vhash.zig");

comptime {
    @import("abi.zig").check(@This());
    _ = vlist;
    _ = vtypes;
    _ = vsets;
    _ = vparse;
    _ = vhash;
}

const Value = c.GValue;
const Table = c.GstValueTable;

pub const parseValue = vparse.parseValue;
pub const parseString = vparse.parseString;
pub const parseSimpleString = vparse.parseSimpleString;

pub const UNORDERED = c.GST_VALUE_UNORDERED;
pub const EQUAL = c.GST_VALUE_EQUAL;

pub export var _gst_int_range_type: c.GType = 0;
pub export var _gst_int64_range_type: c.GType = 0;
pub export var _gst_double_range_type: c.GType = 0;
pub export var _gst_fraction_range_type: c.GType = 0;
pub export var _gst_value_list_type: c.GType = 0;
pub export var _gst_value_array_type: c.GType = 0;
pub export var _gst_value_unique_list_type: c.GType = 0;
pub export var _gst_fraction_type: c.GType = 0;
pub export var _gst_bitmask_type: c.GType = 0;
pub export var _gst_flagset_type: c.GType = 0;

fn fundamental(comptime name: [:0]const u8, comptime vt: *const c.GTypeValueTable, comptime class_size: c.guint16, comptime flags: c.GTypeFundamentalFlags) c.GType {
    var info = std.mem.zeroes(c.GTypeInfo);
    info.class_size = class_size;
    info.value_table = vt;
    var finfo = std.mem.zeroes(c.GTypeFundamentalInfo);
    finfo.type_flags = flags;
    return c.g_type_register_fundamental(c.g_type_fundamental_next(), name.ptr, &info, &finfo, 0);
}

fn table(init: anytype, free: anytype, copy: anytype, peek: anytype, comptime cf: [:0]const u8, collect: anytype, comptime lf: [:0]const u8, lcopy: anytype) c.GTypeValueTable {
    return .{
        .value_init = init,
        .value_free = free,
        .value_copy = copy,
        .value_peek_pointer = peek,
        .collect_format = cf.ptr,
        .collect_value = collect,
        .lcopy_format = lf.ptr,
        .lcopy_value = lcopy,
    };
}

const int_range_vt = table(vtypes.intRangeInit, null, vtypes.intRangeCopy, null, "ii", vtypes.intRangeCollect, "pp", vtypes.intRangeLcopy);
const int64_range_vt = table(vtypes.int64RangeInit, vtypes.int64RangeFree, vtypes.int64RangeCopy, null, "qq", vtypes.int64RangeCollect, "pp", vtypes.int64RangeLcopy);
const double_range_vt = table(vtypes.doubleRangeInit, null, vtypes.doubleRangeCopy, null, "dd", vtypes.doubleRangeCollect, "pp", vtypes.doubleRangeLcopy);
const fraction_range_vt = table(vtypes.fractionRangeInit, vtypes.fractionRangeFree, vtypes.fractionRangeCopy, null, "iiii", vtypes.fractionRangeCollect, "pppp", vtypes.fractionRangeLcopy);
const list_vt = table(vlist.tableInit, vlist.tableFree, vlist.tableCopy, vlist.tablePeek, "p", vlist.tableCollect, "p", vlist.tableLcopy);
const fraction_vt = table(vtypes.fractionInit, null, vtypes.fractionCopy, null, "ii", vtypes.fractionCollect, "pp", vtypes.fractionLcopy);
const bitmask_vt = table(vtypes.bitmaskInit, null, vtypes.bitmaskCopy, null, "q", vtypes.bitmaskCollect, "p", vtypes.bitmaskLcopy);
const flagset_vt = table(vtypes.flagsetInit, null, vtypes.flagsetCopy, null, "ii", vtypes.flagsetCollect, "pp", vtypes.flagsetLcopy);

fn typeGetter(comptime name: [:0]const u8, comptime vt: *const c.GTypeValueTable, comptime class_size: c.guint16, comptime flags: c.GTypeFundamentalFlags, comptime slot: *c.GType) fn () callconv(.c) c.GType {
    return struct {
        var once: gtype.Once = .{};
        fn register() c.GType {
            const t = fundamental(name, vt, class_size, flags);
            slot.* = t;
            return t;
        }
        fn get() callconv(.c) c.GType {
            return once.get(register);
        }
    }.get;
}

const getIntRange = typeGetter("GstIntRange", &int_range_vt, 0, 0, &_gst_int_range_type);
const getInt64Range = typeGetter("GstInt64Range", &int64_range_vt, 0, 0, &_gst_int64_range_type);
const getDoubleRange = typeGetter("GstDoubleRange", &double_range_vt, 0, 0, &_gst_double_range_type);
const getFractionRange = typeGetter("GstFractionRange", &fraction_range_vt, 0, 0, &_gst_fraction_range_type);
const getList = typeGetter("GstValueList", &list_vt, 0, 0, &_gst_value_list_type);
const getArray = typeGetter("GstValueArray", &list_vt, 0, 0, &_gst_value_array_type);
const getUniqueList = typeGetter("GstValueUniqueList", &list_vt, 0, 0, &_gst_value_unique_list_type);
const getFraction = typeGetter("GstFraction", &fraction_vt, 0, 0, &_gst_fraction_type);
const getBitmask = typeGetter("GstBitmask", &bitmask_vt, 0, 0, &_gst_bitmask_type);
const getFlagset = typeGetter("GstFlagSet", &flagset_vt, @sizeOf(vtypes.FlagSetClass), c.G_TYPE_FLAG_CLASSED | c.G_TYPE_FLAG_DERIVABLE, &_gst_flagset_type);

pub export fn gst_int_range_get_type() c.GType {
    return getIntRange();
}
pub export fn gst_int64_range_get_type() c.GType {
    return getInt64Range();
}
pub export fn gst_double_range_get_type() c.GType {
    return getDoubleRange();
}
pub export fn gst_fraction_range_get_type() c.GType {
    return getFractionRange();
}
pub export fn gst_value_list_get_type() c.GType {
    return getList();
}
pub export fn gst_value_array_get_type() c.GType {
    return getArray();
}
pub export fn gst_value_unique_list_get_type() c.GType {
    return getUniqueList();
}
pub export fn gst_fraction_get_type() c.GType {
    return getFraction();
}
pub export fn gst_bitmask_get_type() c.GType {
    return getBitmask();
}
pub export fn gst_flagset_get_type() c.GType {
    return getFlagset();
}
pub export fn gst_g_thread_get_type() c.GType {
    return c.g_thread_get_type();
}

var tables: std.ArrayListUnmanaged(*const Table) = .empty;
var by_type: ?*c.GHashTable = null;
var by_fundamental: [256]?*const Table = .{null} ** 256;

fn isFundamental(t: c.GType) bool {
    return t <= c.G_TYPE_FUNDAMENTAL_MAX;
}

fn lookup(t: c.GType) ?*const Table {
    if (isFundamental(t)) return by_fundamental[t >> c.G_TYPE_FUNDAMENTAL_SHIFT];
    if (by_type == null) return null;
    return @ptrCast(@alignCast(c.g_hash_table_lookup(by_type, @ptrFromInt(t))));
}

fn closest(t: c.GType, comptime has: fn (*const Table) bool) ?*const Table {
    if (lookup(t)) |exact| if (has(exact)) return exact;
    var best: ?*const Table = null;
    for (tables.items) |tb| {
        if (!has(tb) or c.g_type_is_a(t, tb.type) == 0) continue;
        if (best == null or c.g_type_is_a(tb.type, best.?.type) != 0) best = tb;
    }
    return best;
}

fn hasCompare(tb: *const Table) bool {
    return tb.compare != null;
}
fn hasSerialize(tb: *const Table) bool {
    return tb.serialize != null;
}
fn hasDeserialize(tb: *const Table) bool {
    return tb.deserialize != null or tb.deserialize_with_pspec != null;
}

pub fn hashTableOf(t: c.GType) ?*const Table {
    return lookup(t);
}

pub export fn gst_value_register(tb: [*c]const Table) void {
    if (!check.that(tb != null, "gst_value_register", "table != NULL")) return;
    tables.append(std.heap.c_allocator, tb) catch @panic("out of memory");
    if (lookup(tb.*.type) != null) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "adding type %s multiple times", c.g_type_name(tb.*.type));
    if (isFundamental(tb.*.type)) by_fundamental[tb.*.type >> c.G_TYPE_FUNDAMENTAL_SHIFT] = tb;
    _ = c.g_hash_table_insert(by_type, @ptrFromInt(tb.*.type), @constCast(@ptrCast(tb)));
}

pub fn isValue(v: [*c]const Value) bool {
    return v != null and v.*.g_type != 0 and c.g_type_check_value(v) != 0;
}

pub fn compareFunc(v: [*c]const Value) c.GstValueCompareFunc {
    const tb = closest(v.*.g_type, hasCompare) orelse return null;
    return tb.compare;
}

pub export fn gst_value_can_compare(a: [*c]const Value, b: [*c]const Value) c.gboolean {
    if (!check.that(isValue(a), "gst_value_can_compare", "G_IS_VALUE (value1)")) return 0;
    if (!check.that(isValue(b), "gst_value_can_compare", "G_IS_VALUE (value2)")) return 0;
    return @intFromBool(canCompare(a, b));
}

pub fn canCompare(a: [*c]const Value, b: [*c]const Value) bool {
    return a.*.g_type == b.*.g_type and compareFunc(a) != null;
}

pub fn compareSameType(a: [*c]const Value, b: [*c]const Value) c.gint {
    if (a.*.g_type != b.*.g_type) return UNORDERED;
    if (compareFunc(a)) |f| return f(a, b);
    c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "unable to compare values of type %s\n", c.g_type_name(a.*.g_type));
    return UNORDERED;
}

fn listMatchesRange(list: [*c]const Value, range: [*c]const Value) bool {
    const items = vlist.items(list);
    if (items.len == 0) return false;
    const first = &items[0];
    if (first.g_type == c.G_TYPE_INT and range.*.g_type == _gst_int_range_type) {
        const lo = vtypes.gst_value_get_int_range_min(range);
        const hi = vtypes.gst_value_get_int_range_max(range);
        const step = vtypes.gst_value_get_int_range_step(range);
        if (step == 0) return false;
        const count: i64 = @as(i64, @divTrunc(hi, step)) - @divTrunc(lo, step) + 1;
        if (@as(i64, @intCast(items.len)) != count) return false;
        for (items) |*it| {
            const x = c.g_value_get_int(it);
            if (x < lo or x > hi or @rem(x, step) != 0) return false;
        }
        return true;
    }
    if (first.g_type == c.G_TYPE_INT64 and range.*.g_type == _gst_int64_range_type) {
        const lo = vtypes.gst_value_get_int64_range_min(range);
        const hi = vtypes.gst_value_get_int64_range_max(range);
        const step = vtypes.gst_value_get_int64_range_step(range);
        if (step == 0) return false;
        const count = @divTrunc(hi, step) -% @divTrunc(lo, step) +% 1;
        if (@as(i64, @intCast(items.len)) != count) return false;
        for (items) |*it| {
            const x = c.g_value_get_int64(it);
            if (x < lo or x > hi or @rem(x, step) != 0) return false;
        }
        return true;
    }
    return false;
}

fn compareAgainstContainer(container: [*c]const Value, other: [*c]const Value, size_must_be_one: bool) c.gint {
    const items = vlist.items(container);
    if (size_must_be_one and items.len != 1) return UNORDERED;
    if (items.len == 0) return UNORDERED;
    for (items) |*it| {
        const r = gst_value_compare(it, other);
        if (r != EQUAL) return if (items.len == 1) r else UNORDERED;
    }
    return EQUAL;
}

pub export fn gst_value_compare(a_in: [*c]const Value, b_in: [*c]const Value) c.gint {
    if (!check.that(isValue(a_in), "gst_value_compare", "G_IS_VALUE (value1)")) return c.GST_VALUE_LESS_THAN;
    if (!check.that(isValue(b_in), "gst_value_compare", "G_IS_VALUE (value2)")) return c.GST_VALUE_GREATER_THAN;
    var a = a_in;
    var b = b_in;
    const al = a.*.g_type == _gst_value_list_type;
    const bl = b.*.g_type == _gst_value_list_type;
    if (al != bl) {
        if (bl) std.mem.swap([*c]const Value, &a, &b);
        if (listMatchesRange(a, b)) return EQUAL;
        return compareAgainstContainer(a, b, false);
    }
    const au = a.*.g_type == _gst_value_unique_list_type;
    const bu = b.*.g_type == _gst_value_unique_list_type;
    if (au != bu) {
        if (bu) std.mem.swap([*c]const Value, &a, &b);
        return compareAgainstContainer(a, b, true);
    }
    return compareSameType(a, b);
}

pub export fn gst_value_init_and_copy(dest: [*c]Value, src: [*c]const Value) void {
    if (!check.that(isValue(src), "gst_value_init_and_copy", "G_IS_VALUE (src)")) return;
    if (!check.that(dest != null, "gst_value_init_and_copy", "dest != NULL")) return;
    const t = src.*.g_type;
    if (t == _gst_value_list_type or t == _gst_value_array_type or t == _gst_value_unique_list_type) {
        dest.*.g_type = t;
        vlist.tableCopy(src, dest);
        return;
    }
    _ = c.g_value_init(dest, t);
    c.g_value_copy(src, dest);
}

pub fn move(dest: [*c]Value, src: [*c]Value) void {
    dest.* = src.*;
    src.* = std.mem.zeroes(Value);
}

pub export fn gst_value_serialize(v: [*c]const Value) [*c]u8 {
    if (!check.that(isValue(v), "gst_value_serialize", "G_IS_VALUE (value)")) return null;
    if (closest(v.*.g_type, hasSerialize)) |tb| return tb.serialize.?(v);
    var s = std.mem.zeroes(Value);
    _ = c.g_value_init(&s, c.G_TYPE_STRING);
    defer c.g_value_unset(&s);
    if (c.g_value_transform(v, &s) == 0) return null;
    return vbasic.wrap(c.g_value_get_string(&s));
}

fn deserializeVia(dest: [*c]Value, src: [*c]const u8, pspec: [*c]c.GParamSpec) c.gboolean {
    const tb = closest(dest.*.g_type, hasDeserialize) orelse return 0;
    if (tb.deserialize_with_pspec) |f| return f(dest, src, pspec);
    return tb.deserialize.?(dest, src);
}

pub export fn gst_value_deserialize(dest: [*c]Value, src: [*c]const u8) c.gboolean {
    if (!check.that(src != null, "gst_value_deserialize", "src != NULL")) return 0;
    if (!check.that(isValue(dest), "gst_value_deserialize", "G_IS_VALUE (dest)")) return 0;
    return deserializeVia(dest, src, null);
}

pub export fn gst_value_deserialize_with_pspec(dest: [*c]Value, src: [*c]const u8, pspec: [*c]c.GParamSpec) c.gboolean {
    const f = "gst_value_deserialize_with_pspec";
    if (!check.that(src != null, f, "src != NULL")) return 0;
    if (!check.that(isValue(dest), f, "G_IS_VALUE (dest)")) return 0;
    if (pspec != null and !check.that(dest.*.g_type == pspec.*.value_type, f, "G_VALUE_TYPE (dest) == G_PARAM_SPEC_VALUE_TYPE (pspec)")) return 0;
    return deserializeVia(dest, src, pspec);
}

pub fn holdsFlagSet(v: [*c]const Value) bool {
    return vtypes.holdsFlagSet(v);
}

fn typeIsFixed(t: c.GType) bool {
    if (t <= c.G_TYPE_RESERVED_GLIB_LAST << c.G_TYPE_FUNDAMENTAL_SHIFT) return true;
    if (t == _gst_int_range_type or t == _gst_double_range_type or t == _gst_int64_range_type or t == _gst_value_list_type or t == _gst_fraction_range_type or t == c.gst_structure_get_type()) return false;
    if (t == c.gst_buffer_get_type()) return true;
    return isFundamental(t) or c.g_type_fundamental(t) <= c.G_TYPE_RESERVED_GLIB_LAST << c.G_TYPE_FUNDAMENTAL_SHIFT;
}

pub fn isFixedType(t: c.GType) bool {
    return typeIsFixed(t);
}

fn fieldFixed(_: [*c]const c.GstIdStr, v: [*c]const Value, _: c.gpointer) callconv(.c) c.gboolean {
    return gst_value_is_fixed(v);
}

pub export fn gst_value_is_fixed(v: [*c]const Value) c.gboolean {
    if (!check.that(isValue(v), "gst_value_is_fixed", "G_IS_VALUE (value)")) return 0;
    const t = v.*.g_type;
    if (t <= c.G_TYPE_RESERVED_GLIB_LAST << c.G_TYPE_FUNDAMENTAL_SHIFT) return 1;
    if (t == _gst_value_array_type or t == _gst_value_unique_list_type) {
        for (vlist.items(v)) |*kid| if (gst_value_is_fixed(kid) == 0) return 0;
        return 1;
    }
    if (holdsFlagSet(v)) return @intFromBool(vtypes.gst_value_get_flagset_mask(v) == c.GST_FLAG_SET_MASK_EXACT);
    if (t == c.gst_structure_get_type()) return c.gst_structure_foreach_id_str(gst_value_get_structure(v), fieldFixed, null);
    if (t == c.gst_caps_get_type()) {
        const caps = gst_value_get_caps(v);
        return @intFromBool(caps == null or c.gst_caps_is_fixed(caps) != 0);
    }
    return @intFromBool(typeIsFixed(t));
}

pub export fn gst_value_fixate(dest: [*c]Value, src: [*c]const Value) c.gboolean {
    if (!check.that(isValue(src), "gst_value_fixate", "G_IS_VALUE (src)")) return 0;
    if (!check.that(dest != null, "gst_value_fixate", "dest != NULL")) return 0;
    const t = src.*.g_type;
    if (t == _gst_int_range_type) {
        _ = c.g_value_init(dest, c.G_TYPE_INT);
        c.g_value_set_int(dest, vtypes.gst_value_get_int_range_min(src));
        return 1;
    }
    if (t == _gst_double_range_type) {
        _ = c.g_value_init(dest, c.G_TYPE_DOUBLE);
        c.g_value_set_double(dest, vtypes.gst_value_get_double_range_min(src));
        return 1;
    }
    if (t == _gst_fraction_range_type) {
        gst_value_init_and_copy(dest, vtypes.gst_value_get_fraction_range_min(src));
        return 1;
    }
    if (t == _gst_value_list_type) {
        const items = vlist.items(src);
        if (items.len == 0) return 0;
        var first = std.mem.zeroes(Value);
        gst_value_init_and_copy(&first, &items[0]);
        if (gst_value_fixate(dest, &first) == 0) move(dest, &first) else c.g_value_unset(&first);
        return 1;
    }
    if (t == _gst_value_unique_list_type or t == _gst_value_array_type) {
        var changed = false;
        _ = c.g_value_init(dest, t);
        for (vlist.items(src)) |*kid| {
            var out = std.mem.zeroes(Value);
            if (gst_value_fixate(&out, kid) == 0) gst_value_init_and_copy(&out, kid) else changed = true;
            vlist.pushTake(vlist.of(dest), &out);
        }
        if (!changed) c.g_value_unset(dest);
        return @intFromBool(changed);
    }
    if (holdsFlagSet(src)) {
        if (vtypes.gst_value_get_flagset_mask(src) == c.GST_FLAG_SET_MASK_EXACT) return 0;
        const flags = vtypes.gst_value_get_flagset_flags(src);
        _ = c.g_value_init(dest, t);
        vtypes.gst_value_set_flagset(dest, flags, c.GST_FLAG_SET_MASK_EXACT);
        return 1;
    }
    if (t == c.gst_structure_get_type()) {
        const s = gst_value_get_structure(src);
        if (s == null) return 0;
        const kid = c.gst_structure_copy(s);
        c.gst_structure_fixate(kid);
        _ = c.g_value_init(dest, t);
        gst_value_set_structure(dest, kid);
        c.gst_structure_free(kid);
        return 1;
    }
    if (t == c.gst_caps_get_type()) {
        _ = c.g_value_init(dest, t);
        var caps: [*c]c.GstCaps = @constCast(gst_value_get_caps(src));
        if (caps != null) caps = c.gst_caps_fixate(c.gst_caps_copy(caps));
        gst_value_set_caps(dest, caps);
        if (caps != null) c.gst_mini_object_unref(@ptrCast(caps));
        return 1;
    }
    return 0;
}

pub export fn gst_value_set_structure(v: [*c]Value, s: [*c]const c.GstStructure) void {
    const f = "gst_value_set_structure";
    if (!check.that(isValue(v), f, "G_IS_VALUE (value)")) return;
    if (!check.that(v.*.g_type == c.gst_structure_get_type(), f, "G_VALUE_TYPE (value) == GST_TYPE_STRUCTURE")) return;
    if (!check.that(s == null or c.gst_structure_get_name(s) != null, f, "structure == NULL || GST_IS_STRUCTURE (structure)")) return;
    c.g_value_set_boxed(v, s);
}

pub export fn gst_value_get_structure(v: [*c]const Value) [*c]const c.GstStructure {
    if (!check.that(isValue(v), "gst_value_get_structure", "G_IS_VALUE (value)")) return null;
    if (!check.that(v.*.g_type == c.gst_structure_get_type(), "gst_value_get_structure", "G_VALUE_TYPE (value) == GST_TYPE_STRUCTURE")) return null;
    return @ptrCast(@alignCast(c.g_value_get_boxed(v)));
}

pub export fn gst_value_set_caps(v: [*c]Value, caps: [*c]const c.GstCaps) void {
    const f = "gst_value_set_caps";
    if (!check.that(isValue(v), f, "G_IS_VALUE (value)")) return;
    if (!check.that(v.*.g_type == c.gst_caps_get_type(), f, "G_VALUE_TYPE (value) == GST_TYPE_CAPS")) return;
    if (!check.that(caps == null or caps.*.mini_object.type == c.gst_caps_get_type(), f, "caps == NULL || GST_IS_CAPS (caps)")) return;
    c.g_value_set_boxed(v, caps);
}

pub export fn gst_value_get_caps(v: [*c]const Value) [*c]const c.GstCaps {
    if (!check.that(isValue(v), "gst_value_get_caps", "G_IS_VALUE (value)")) return null;
    if (!check.that(v.*.g_type == c.gst_caps_get_type(), "gst_value_get_caps", "G_VALUE_TYPE (value) == GST_TYPE_CAPS")) return null;
    return @ptrCast(@alignCast(c.g_value_get_boxed(v)));
}

pub export fn gst_value_set_caps_features(v: [*c]Value, features: ?*const c.GstCapsFeatures) void {
    const f = "gst_value_set_caps_features";
    if (!check.that(isValue(v), f, "G_IS_VALUE (value)")) return;
    if (!check.that(v.*.g_type == c.gst_caps_features_get_type(), f, "G_VALUE_TYPE (value) == GST_TYPE_CAPS_FEATURES")) return;
    if (!check.that(features == null or c.gst_is_caps_features(features) != 0, f, "features == NULL || GST_IS_CAPS_FEATURES (features)")) return;
    c.g_value_set_boxed(v, features);
}

pub export fn gst_value_get_caps_features(v: [*c]const Value) ?*const c.GstCapsFeatures {
    if (!check.that(isValue(v), "gst_value_get_caps_features", "G_IS_VALUE (value)")) return null;
    if (!check.that(v.*.g_type == c.gst_caps_features_get_type(), "gst_value_get_caps_features", "G_VALUE_TYPE (value) == GST_TYPE_CAPS_FEATURES")) return null;
    return @ptrCast(@alignCast(c.g_value_get_boxed(v)));
}

pub fn dynamicLoad() ?*const fn ([*c]const u8) callconv(.c) c.GType {
    return @import("gtype.zig").lookup(?*const fn ([*c]const u8) callconv(.c) c.GType, "gst_dynamic_type_factory_load");
}

const Abbr = struct { name: [:0]const u8, t: *const fn () callconv(.c) c.GType };

fn glibType(comptime fundamental_id: c.GType) fn () callconv(.c) c.GType {
    return struct {
        fn f() callconv(.c) c.GType {
            return fundamental_id << c.G_TYPE_FUNDAMENTAL_SHIFT;
        }
    }.f;
}

const abbreviations = [_]Abbr{
    .{ .name = "int", .t = glibType(6) },
    .{ .name = "i", .t = glibType(6) },
    .{ .name = "uint", .t = glibType(7) },
    .{ .name = "u", .t = glibType(7) },
    .{ .name = "float", .t = glibType(14) },
    .{ .name = "f", .t = glibType(14) },
    .{ .name = "double", .t = glibType(15) },
    .{ .name = "d", .t = glibType(15) },
    .{ .name = "buffer", .t = c.gst_buffer_get_type },
    .{ .name = "fraction", .t = gst_fraction_get_type },
    .{ .name = "boolean", .t = glibType(5) },
    .{ .name = "bool", .t = glibType(5) },
    .{ .name = "b", .t = glibType(5) },
    .{ .name = "string", .t = glibType(16) },
    .{ .name = "str", .t = glibType(16) },
    .{ .name = "s", .t = glibType(16) },
    .{ .name = "structure", .t = c.gst_structure_get_type },
    .{ .name = "date", .t = c.g_date_get_type },
    .{ .name = "datetime", .t = c.gst_date_time_get_type },
    .{ .name = "gdatetime", .t = c.g_date_time_get_type },
    .{ .name = "bitmask", .t = gst_bitmask_get_type },
    .{ .name = "flagset", .t = gst_flagset_get_type },
    .{ .name = "sample", .t = c.gst_sample_get_type },
    .{ .name = "taglist", .t = c.gst_tag_list_get_type },
    .{ .name = "type", .t = c.g_gtype_get_type },
    .{ .name = "array", .t = gst_value_array_get_type },
    .{ .name = "list", .t = gst_value_list_get_type },
    .{ .name = "uniquelist", .t = gst_value_unique_list_get_type },
    .{ .name = "caps", .t = c.gst_caps_get_type },
};

pub fn typeFromAbbr(name: [*c]const u8) c.GType {
    if (!check.that(name != null, "_priv_gst_value_gtype_from_abbr", "type_name != NULL")) return 0;
    const s = std.mem.span(name);
    for (abbreviations) |a| if (std.mem.eql(u8, s, a.name)) return a.t();
    const t = c.g_type_from_name(name);
    if (t != 0) return t;
    const load = dynamicLoad() orelse return 0;
    return load(name);
}

pub fn abbrOf(t: c.GType) [*c]const u8 {
    if (!check.that(t != 0, "_priv_gst_value_gtype_to_abbr", "type != G_TYPE_INVALID")) return null;
    for (abbreviations) |a| if (a.t() == t) return a.name.ptr;
    return c.g_type_name(t);
}

pub fn serializeList(v: [*c]const Value, begin: [*c]const u8, end: [*c]const u8, print_type: bool, flags: c.GstSerializeFlags) [*c]u8 {
    const items = vlist.items(v);
    const out = c.g_string_sized_new(4 + 6 * items.len);
    _ = c.g_string_append(out, begin);
    for (items, 0..) |*it, i| {
        const st = c.gst_structure_get_type();
        const ct = c.gst_caps_get_type();
        const bracket = flags & c.GST_SERIALIZE_FLAG_BACKWARD_COMPAT == 0 and (it.g_type == st or it.g_type == ct);
        const text: [*c]u8 = if (!bracket)
            gst_value_serialize(it)
        else if (it.g_type == st)
            c.gst_structure_serialize_full(gst_value_get_structure(it), flags)
        else
            c.gst_caps_serialize(gst_value_get_caps(it), flags);
        if (text == null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Could not serialize list/array value of type '%s'", c.g_type_name(it.g_type));
            continue;
        }
        if (print_type) {
            _ = c.g_string_append_c(out, '(');
            _ = c.g_string_append(out, abbrOf(it.g_type));
            _ = c.g_string_append_c(out, ')');
        }
        if (bracket) _ = c.g_string_append_c(out, '[');
        _ = c.g_string_append(out, text);
        if (bracket) _ = c.g_string_append_c(out, ']');
        c.g_free(text);
        if (i + 1 < items.len) _ = c.g_string_append_len(out, ", ", 2);
    }
    _ = c.g_string_append(out, end);
    return c.g_string_free(out, 0);
}

fn listToString(v: [*c]const Value, begin: [*c]const u8, end: [*c]const u8) [*c]u8 {
    const items = vlist.items(v);
    const out = c.g_string_sized_new(4 + 10 * items.len);
    _ = c.g_string_append(out, begin);
    for (items, 0..) |*it, i| {
        if (i != 0) _ = c.g_string_append_len(out, ", ", 2);
        const s = c.g_strdup_value_contents(it);
        _ = c.g_string_append(out, s);
        c.g_free(s);
    }
    _ = c.g_string_append(out, end);
    return c.g_string_free(out, 0);
}

fn valueArrayOf(v: [*c]const Value) ?*c.GValueArray {
    return @ptrCast(@alignCast(v[0].data[0].v_pointer));
}

fn valueArrayItems(a: ?*c.GValueArray) []Value {
    const arr = a orelse return &.{};
    if (arr.n_values == 0) return &.{};
    return arr.values[0..arr.n_values];
}

fn valueArrayToString(v: [*c]const Value) [*c]u8 {
    const items = valueArrayItems(valueArrayOf(v));
    const out = c.g_string_sized_new(4 + 10 * items.len);
    _ = c.g_string_append(out, "< ");
    for (items, 0..) |*it, i| {
        if (i != 0) _ = c.g_string_append_len(out, ", ", 2);
        const s = c.g_strdup_value_contents(it);
        _ = c.g_string_append(out, s);
        c.g_free(s);
    }
    _ = c.g_string_append(out, " >");
    return c.g_string_free(out, 0);
}

fn listStr(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = listToString(src, "{ ", " }");
}
fn arrayStr(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = listToString(src, "< ", " >");
}
fn uniqueStr(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = listToString(src, "(/uniquelist){ ", " }");
}
fn valueArrayStr(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = valueArrayToString(src);
}

fn valueArrayToList(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    const items = valueArrayItems(@ptrCast(@alignCast(c.g_value_get_boxed(src))));
    const l = vlist.create(@intCast(items.len));
    dest[0].data[0].v_pointer = l;
    for (items) |*it| {
        var copy = std.mem.zeroes(Value);
        gst_value_init_and_copy(&copy, it);
        vlist.pushTake(l, &copy);
    }
}

fn listToValueArray(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    const items = vlist.items(src);
    const arr = c.g_value_array_new(@intCast(items.len));
    for (items) |*it| _ = c.g_value_array_append(arr, it);
    c.g_value_take_boxed(dest, arr);
}

fn serializeValueArray(v: [*c]const Value) callconv(.c) [*c]u8 {
    const items = valueArrayItems(valueArrayOf(v));
    const out = c.g_string_sized_new(4 + 6 * items.len);
    _ = c.g_string_append(out, "< ");
    for (items, 0..) |*it, i| {
        const s = gst_value_serialize(it);
        if (s == null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Could not serialize list/array value of type '%s'", c.g_type_name(it.g_type));
            continue;
        }
        _ = c.g_string_append(out, s);
        c.g_free(s);
        if (i + 1 < items.len) _ = c.g_string_append_len(out, ", ", 2);
    }
    _ = c.g_string_append(out, " >");
    return c.g_string_free(out, 0);
}

fn deserializeValueArray(_: [*c]Value, _: [*c]const u8) callconv(.c) c.gboolean {
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "gst_value_deserialize_g_value_array: unimplemented");
    return 0;
}

fn compareValueArray(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x = valueArrayItems(valueArrayOf(a));
    const y = valueArrayItems(valueArrayOf(b));
    if (x.len != y.len) return UNORDERED;
    for (x, y) |*p, *q| if (gst_value_compare(p, q) != EQUAL) return UNORDERED;
    return EQUAL;
}

fn compareListUnordered(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x = vlist.items(a);
    const y = vlist.items(b);
    if (x.len != y.len) return UNORDERED;
    var taken_small: [256]bool = undefined;
    const taken: []bool = if (y.len <= taken_small.len) taken_small[0..y.len] else (std.heap.c_allocator.alloc(bool, y.len) catch @panic("out of memory"));
    defer if (y.len > taken_small.len) std.heap.c_allocator.free(taken);
    @memset(taken, false);
    var left = y.len;
    for (x) |*p| {
        const f = compareFunc(p) orelse return UNORDERED;
        var hit = false;
        for (y, 0..) |*q, j| {
            if (taken[j]) continue;
            if (p.g_type == q.g_type and f(p, q) == EQUAL) {
                taken[j] = true;
                left -= 1;
                hit = true;
                break;
            }
        }
        if (!hit) return UNORDERED;
    }
    return if (left == 0) EQUAL else UNORDERED;
}

fn compareArray(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x = vlist.items(a);
    const y = vlist.items(b);
    if (x.len != y.len) return UNORDERED;
    for (x, y) |*p, *q| if (gst_value_compare(p, q) != EQUAL) return UNORDERED;
    return EQUAL;
}

fn serializeListValue(v: [*c]const Value) callconv(.c) [*c]u8 {
    return serializeList(v, "{ ", " }", true, c.GST_SERIALIZE_FLAG_BACKWARD_COMPAT);
}
fn serializeArrayValue(v: [*c]const Value) callconv(.c) [*c]u8 {
    return serializeList(v, "< ", " >", true, c.GST_SERIALIZE_FLAG_BACKWARD_COMPAT);
}
fn serializeUniqueValue(v: [*c]const Value) callconv(.c) [*c]u8 {
    return serializeList(v, "(/uniquelist){ ", " }", true, c.GST_SERIALIZE_FLAG_BACKWARD_COMPAT);
}
fn deserializeListValue(dest: [*c]Value, s: [*c]const u8, pspec: [*c]c.GParamSpec) callconv(.c) c.gboolean {
    var p: [*c]u8 = @constCast(s);
    return @intFromBool(vparse.parseList(p, &p, dest, 0, pspec));
}
fn deserializeArrayValue(dest: [*c]Value, s: [*c]const u8, pspec: [*c]c.GParamSpec) callconv(.c) c.gboolean {
    var p: [*c]u8 = @constCast(s);
    return @intFromBool(vparse.parseArray(p, &p, dest, 0, pspec));
}

fn compareDate(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x: ?*const c.GDate = @ptrCast(@alignCast(c.g_value_get_boxed(a)));
    const y: ?*const c.GDate = @ptrCast(@alignCast(c.g_value_get_boxed(b)));
    if (x == y) return EQUAL;
    const xv = x != null and c.g_date_valid(x) != 0;
    const yv = y != null and c.g_date_valid(y) != 0;
    if (!xv and yv) return c.GST_VALUE_LESS_THAN;
    if (!yv and xv) return c.GST_VALUE_GREATER_THAN;
    if (!xv or !yv) return UNORDERED;
    const j1 = c.g_date_get_julian(x);
    const j2 = c.g_date_get_julian(y);
    if (j1 == j2) return EQUAL;
    return if (j1 < j2) c.GST_VALUE_LESS_THAN else c.GST_VALUE_GREATER_THAN;
}

fn serializeDate(v: [*c]const Value) callconv(.c) [*c]u8 {
    const d: ?*const c.GDate = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    if (d == null or c.g_date_valid(d) == 0) return c.g_strdup("9999-99-99");
    return c.g_strdup_printf("%04u-%02u-%02u", @as(c.guint, c.g_date_get_year(d)), @as(c.guint, c.g_date_get_month(d)), @as(c.guint, c.g_date_get_day(d)));
}

fn scanFixed(s: []const u8, pos: *usize, max_digits: usize) ?c.guint {
    var i = pos.*;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i < s.len and s[i] == '+') i += 1;
    const start = i;
    while (i < s.len and i - start < max_digits and std.ascii.isDigit(s[i])) i += 1;
    if (i == start) return null;
    pos.* = i;
    return std.fmt.parseInt(c.guint, s[start..i], 10) catch null;
}

fn deserializeDate(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    if (s == null) return 0;
    const str = std.mem.span(s);
    var pos: usize = 0;
    const year = scanFixed(str, &pos, 4) orelse return 0;
    if (pos >= str.len or str[pos] != '-') return 0;
    pos += 1;
    const month = scanFixed(str, &pos, 2) orelse return 0;
    if (pos >= str.len or str[pos] != '-') return 0;
    pos += 1;
    const day = scanFixed(str, &pos, 2) orelse return 0;
    if (c.g_date_valid_dmy(@truncate(day), @truncate(month), @truncate(year)) == 0) return 0;
    c.g_value_take_boxed(dest, c.g_date_new_dmy(@truncate(day), @truncate(month), @truncate(year)));
    return 1;
}

fn dateStr(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = serializeDate(src);
}
fn strDate(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    _ = deserializeDate(dest, @ptrCast(src[0].data[0].v_pointer));
}

fn compareBytes(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x: ?*c.GBytes = @ptrCast(c.g_value_get_boxed(a));
    const y: ?*c.GBytes = @ptrCast(c.g_value_get_boxed(b));
    if (x == null or y == null) return if (x == y) EQUAL else UNORDERED;
    return c.g_bytes_compare(x, y);
}

fn serializeBytes(v: [*c]const Value) callconv(.c) [*c]u8 {
    const b: ?*c.GBytes = @ptrCast(c.g_value_get_boxed(v));
    var len: c.gsize = 0;
    const data: [*c]const u8 = if (b != null) @ptrCast(c.g_bytes_get_data(b, &len)) else null;
    return c.g_base64_encode(data, len);
}

fn deserializeBytes(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    if (s == null) {
        c.g_value_take_boxed(dest, c.g_bytes_new(null, 0));
        return 1;
    }
    var len: c.gsize = 0;
    const data = c.g_base64_decode(s, &len);
    c.g_value_take_boxed(dest, c.g_bytes_new_take(data, len));
    return 1;
}

fn compareGDateTime(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x: ?*c.GDateTime = @ptrCast(c.g_value_get_boxed(a));
    const y: ?*c.GDateTime = @ptrCast(c.g_value_get_boxed(b));
    if (x == y) return EQUAL;
    if (x == null or y == null) return c.GST_VALUE_LESS_THAN;
    return c.g_date_time_compare(x, y);
}

fn serializeGDateTime(v: [*c]const Value) callconv(.c) [*c]u8 {
    const d: ?*c.GDateTime = @ptrCast(c.g_value_get_boxed(v));
    if (d == null) return c.g_strdup("null");
    return c.g_date_time_format_iso8601(d);
}

fn deserializeGDateTime(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    if (s == null or std.mem.orderZ(u8, s, "null") == .eq) return 0;
    const gdt = c.gst_date_time_new_from_iso8601_string(s);
    if (gdt == null) return 0;
    const d = c.gst_date_time_to_g_date_time(gdt);
    c.gst_date_time_unref(gdt);
    if (d == null) return 0;
    c.g_value_take_boxed(dest, d);
    return 1;
}

fn compareObject(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return if (a[0].data[0].v_pointer == b[0].data[0].v_pointer) EQUAL else UNORDERED;
}

fn objectStr(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    const obj: ?*c.GstObject = @ptrCast(@alignCast(c.g_value_get_object(src)));
    dest[0].data[0].v_pointer = if (obj) |o|
        c.g_strdup_printf("(%s) %s", c.g_type_name(gtype.typeOf(o)), o.name)
    else
        c.g_strdup("NULL");
}

fn serializeStrv(v: [*c]const Value) callconv(.c) [*c]u8 {
    const strv: [*c]const [*c]const u8 = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    const out = c.g_string_new("<");
    var i: usize = 0;
    while (strv[i] != null) : (i += 1) {
        if (out.*.len > 1) _ = c.g_string_append_c(out, ',');
        _ = c.g_string_append_c(out, '"');
        for (std.mem.span(strv[i])) |ch| {
            if (ch == '"' or ch == '\\') _ = c.g_string_append_c(out, '\\');
            _ = c.g_string_append_c(out, ch);
        }
        _ = c.g_string_append_c(out, '"');
    }
    _ = c.g_string_append_c(out, '>');
    return c.g_string_free(out, 0);
}

fn deserializeStrv(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    if (s[0] != '<') {
        c.g_value_take_boxed(dest, @ptrCast(c.g_strsplit(s, ",", -1)));
        return 1;
    }
    var after: [*c]const u8 = s;
    return @intFromBool(vparse.parseStrv(s, &after, dest));
}

fn compareAllocationParams(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x: ?*const c.GstAllocationParams = @ptrCast(@alignCast(a[0].data[0].v_pointer));
    const y: ?*const c.GstAllocationParams = @ptrCast(@alignCast(b[0].data[0].v_pointer));
    if (x == null and x == y) return EQUAL;
    if (x == null or y == null) return UNORDERED;
    if (x.?.flags == y.?.flags and x.?.@"align" == y.?.@"align" and x.?.prefix == y.?.prefix and x.?.padding == y.?.padding) return EQUAL;
    return UNORDERED;
}

fn allocationParamsStr(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    const p: ?*const c.GstAllocationParams = @ptrCast(@alignCast(src[0].data[0].v_pointer));
    if (p == null) {
        dest[0].data[0].v_pointer = c.g_strdup("NULL");
        return;
    }
    const s = c.gst_structure_new_empty("GstAllocationParams");
    var tmp = std.mem.zeroes(Value);
    _ = c.g_value_init(&tmp, c.gst_memory_flags_get_type());
    c.g_value_set_flags(&tmp, p.?.flags);
    c.gst_structure_set_value_static_str(s, "flags", &tmp);
    c.g_value_unset(&tmp);
    _ = c.g_value_init(&tmp, c.G_TYPE_UINT64);
    c.g_value_set_uint64(&tmp, p.?.@"align");
    c.gst_structure_set_value_static_str(s, "align", &tmp);
    c.g_value_set_uint64(&tmp, p.?.prefix);
    c.gst_structure_set_value_static_str(s, "prefix", &tmp);
    c.g_value_set_uint64(&tmp, p.?.padding);
    c.gst_structure_set_value_static_str(s, "padding", &tmp);
    c.g_value_unset(&tmp);
    dest[0].data[0].v_pointer = c.gst_structure_to_string(s);
    c.gst_structure_free(s);
}

fn entry(t: c.GType, cmp: c.GstValueCompareFunc, ser: c.GstValueSerializeFunc, de: c.GstValueDeserializeFunc, de_ps: c.GstValueDeserializeWithPSpecFunc, h: c.GstValueHashFunc) Table {
    return .{ .type = t, .compare = cmp, .serialize = ser, .deserialize = de, .deserialize_with_pspec = de_ps, .hash = h };
}

var core_tables: [40]Table = undefined;
var core_len: usize = 0;

fn add(tb: Table) void {
    core_tables[core_len] = tb;
    gst_value_register(&core_tables[core_len]);
    core_len += 1;
}

pub fn initialize() void {
    by_type = c.g_hash_table_new(null, null);
    vsets.initialize();
    const h = vhash;
    add(entry(gst_int_range_get_type(), vtypes.intRangeCompare, vtypes.intRangeSerialize, vtypes.unimplemented, null, h.intRange));
    add(entry(gst_int64_range_get_type(), vtypes.int64RangeCompare, vtypes.int64RangeSerialize, vtypes.unimplemented, null, h.int64Range));
    add(entry(gst_double_range_get_type(), vtypes.doubleRangeCompare, vtypes.doubleRangeSerialize, vtypes.unimplemented, null, h.doubleRange));
    add(entry(gst_fraction_range_get_type(), vtypes.fractionRangeCompare, vtypes.fractionRangeSerialize, vtypes.unimplemented, null, h.fractionRange));
    add(entry(c.g_value_array_get_type(), compareValueArray, serializeValueArray, deserializeValueArray, null, h.valueArray));
    add(entry(gst_fraction_get_type(), vtypes.fractionCompare, vtypes.fractionSerialize, vtypes.fractionDeserialize, null, h.fraction));
    add(entry(c.g_date_get_type(), compareDate, serializeDate, deserializeDate, null, h.date));
    add(entry(c.g_bytes_get_type(), compareBytes, serializeBytes, deserializeBytes, null, h.bytes));
    add(entry(c.g_date_time_get_type(), compareGDateTime, serializeGDateTime, deserializeGDateTime, null, h.gDateTime));
    add(entry(gst_bitmask_get_type(), vtypes.bitmaskCompare, vtypes.bitmaskSerialize, vtypes.bitmaskDeserialize, null, h.bitmask));
    add(entry(gst_flagset_get_type(), vtypes.flagsetCompare, vtypes.flagsetSerialize, vtypes.flagsetDeserialize, null, h.flagset));
    add(entry(c.g_gtype_get_type(), vbasic.compareGType, vbasic.serializeGType, vbasic.deserializeGType, null, h.gtype));
    add(entry(c.g_strv_get_type(), null, serializeStrv, deserializeStrv, null, h.strv));
    add(entry(c.gst_allocation_params_get_type(), compareAllocationParams, null, null, null, h.allocationParams));
    add(entry(c.G_TYPE_OBJECT, compareObject, null, null, null, h.object));
    add(entry(c.G_TYPE_DOUBLE, vbasic.compareDouble, vbasic.serializeDouble, vbasic.deserializeDouble, null, h.double));
    add(entry(c.G_TYPE_FLOAT, vbasic.compareFloat, vbasic.serializeFloat, vbasic.deserializeFloat, null, h.float));
    add(entry(c.G_TYPE_STRING, vbasic.compareString, vbasic.serializeString, vbasic.deserializeString, null, h.string));
    add(entry(c.G_TYPE_BOOLEAN, vbasic.compareBoolean, vbasic.serializeBoolean, vbasic.deserializeBoolean, null, h.boolean));
    add(entry(c.G_TYPE_ENUM, vbasic.compareEnum, vbasic.serializeEnum, vbasic.deserializeEnum, null, h.enumeration));
    add(entry(c.G_TYPE_FLAGS, vbasic.compareFlags, vbasic.serializeFlags, vbasic.deserializeFlags, null, h.flags));
    add(entry(c.G_TYPE_INT, vbasic.compareInt, vbasic.serializeByTransform, vbasic.deserializeInt, null, h.int));
    add(entry(c.G_TYPE_INT64, vbasic.compareInt64, vbasic.serializeByTransform, vbasic.deserializeInt64, null, h.int64));
    add(entry(c.G_TYPE_LONG, vbasic.compareLong, vbasic.serializeByTransform, vbasic.deserializeLong, null, h.long));
    add(entry(c.G_TYPE_UINT, vbasic.compareUint, vbasic.serializeByTransform, vbasic.deserializeUint, null, h.uint));
    add(entry(c.G_TYPE_UINT64, vbasic.compareUint64, vbasic.serializeByTransform, vbasic.deserializeUint64, null, h.uint64));
    add(entry(c.G_TYPE_ULONG, vbasic.compareUlong, vbasic.serializeByTransform, vbasic.deserializeUlong, null, h.ulong));
    add(entry(c.G_TYPE_UCHAR, vbasic.compareUchar, vbasic.serializeByTransform, vbasic.deserializeUchar, null, h.uchar));
    add(entry(gst_value_list_get_type(), compareListUnordered, serializeListValue, null, deserializeListValue, h.list));
    add(entry(gst_value_array_get_type(), compareArray, serializeArrayValue, null, deserializeArrayValue, h.array));
    add(entry(gst_value_unique_list_get_type(), compareListUnordered, serializeUniqueValue, null, deserializeListValue, h.list));

    const reg = c.g_value_register_transform_func;
    const S = c.G_TYPE_STRING;
    reg(_gst_int_range_type, S, vtypes.intRangeToString);
    reg(_gst_int64_range_type, S, vtypes.int64RangeToString);
    reg(_gst_double_range_type, S, vtypes.doubleRangeToString);
    reg(_gst_fraction_range_type, S, vtypes.fractionRangeToString);
    reg(_gst_value_list_type, S, listStr);
    reg(_gst_value_list_type, c.g_value_array_get_type(), listToValueArray);
    reg(_gst_value_array_type, S, arrayStr);
    reg(_gst_value_array_type, c.g_value_array_get_type(), listToValueArray);
    reg(c.g_value_array_get_type(), S, valueArrayStr);
    reg(c.g_value_array_get_type(), _gst_value_array_type, valueArrayToList);
    reg(c.g_value_array_get_type(), _gst_value_list_type, valueArrayToList);
    reg(_gst_value_unique_list_type, S, uniqueStr);
    reg(_gst_fraction_type, S, vtypes.fractionToString);
    reg(S, _gst_fraction_type, vtypes.stringToFraction);
    reg(_gst_fraction_type, c.G_TYPE_DOUBLE, vtypes.fractionToDouble);
    reg(_gst_fraction_type, c.G_TYPE_FLOAT, vtypes.fractionToFloat);
    reg(c.G_TYPE_DOUBLE, _gst_fraction_type, vtypes.doubleToFraction);
    reg(c.G_TYPE_FLOAT, _gst_fraction_type, vtypes.floatToFraction);
    reg(c.g_date_get_type(), S, dateStr);
    reg(S, c.g_date_get_type(), strDate);
    reg(c.gst_object_get_type(), S, objectStr);
    reg(_gst_bitmask_type, c.G_TYPE_UINT64, vtypes.u64Passthrough);
    reg(_gst_bitmask_type, S, vtypes.bitmaskToString);
    reg(c.G_TYPE_UINT64, _gst_bitmask_type, vtypes.u64Passthrough);
    reg(S, _gst_bitmask_type, vtypes.stringToBitmask);
    reg(_gst_flagset_type, S, vtypes.flagsetToString);
    reg(S, _gst_flagset_type, vtypes.stringToFlagset);
    reg(c.gst_allocation_params_get_type(), S, allocationParamsStr);
}
