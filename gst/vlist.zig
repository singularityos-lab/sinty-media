const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const value = @import("value.zig");

const Value = c.GValue;

pub const List = extern struct {
    fields: [*]Value,
    len: c.guint,
    cap: c.guint,
};

fn inlineSlots(l: *List) [*]Value {
    const base: [*]u8 = @ptrCast(l);
    return @ptrCast(@alignCast(base + @sizeOf(List)));
}

fn roundUp8(n: c.guint) c.guint {
    return (n + 7) & ~@as(c.guint, 7);
}

pub fn create(prealloc: c.guint) *List {
    const n = roundUp8(@max(prealloc, 1));
    const l: *List = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(List) + n * @sizeOf(Value))));
    l.fields = inlineSlots(l);
    l.len = 0;
    l.cap = n;
    return l;
}

pub fn destroy(l: *List) void {
    if (l.fields != inlineSlots(l)) c.g_free(l.fields);
    c.g_free(l);
}

pub fn of(v: anytype) *List {
    return @ptrCast(@alignCast(v[0].data[0].v_pointer));
}

pub fn items(v: anytype) []Value {
    const l = of(v);
    return l.fields[0..l.len];
}

fn grow(l: *List) void {
    if (l.cap > std.math.maxInt(c.guint) / 2) c.g_log("GStreamer", c.G_LOG_LEVEL_ERROR, "Growing GstValueList would result in overflow");
    const want = @max(roundUp8(l.len + 1), l.cap * 2);
    if (l.fields == inlineSlots(l)) {
        const fresh: [*]Value = @ptrCast(@alignCast(c.g_malloc0(want * @sizeOf(Value))));
        @memcpy(fresh[0..l.len], l.fields[0..l.len]);
        l.fields = fresh;
    } else l.fields = @ptrCast(@alignCast(c.g_realloc(l.fields, want * @sizeOf(Value))));
    l.cap = want;
}

pub fn pushTake(l: *List, v: *Value) void {
    if (l.len == l.cap) grow(l);
    l.fields[l.len] = v.*;
    l.len += 1;
}

pub fn unshiftTake(l: *List, v: *Value) void {
    if (l.len == l.cap) grow(l);
    std.mem.copyBackwards(Value, l.fields[1 .. l.len + 1], l.fields[0..l.len]);
    l.fields[0] = v.*;
    l.len += 1;
}

pub fn initAs(v: [*c]Value, t: c.GType, prealloc: c.guint) void {
    v.*.g_type = t;
    v.*.data = std.mem.zeroes(@TypeOf(v.*.data));
    v[0].data[0].v_pointer = create(prealloc);
}

pub fn clone(src: *const List) *List {
    const out = create(src.len);
    out.len = src.len;
    for (src.fields[0..src.len], out.fields[0..src.len]) |*s, *d| {
        d.* = std.mem.zeroes(Value);
        value.gst_value_init_and_copy(d, s);
    }
    return out;
}

pub fn contains(l: ?*const List, v: [*c]const Value) bool {
    const list = l orelse return false;
    for (list.fields[0..list.len]) |*item| if (value.gst_value_compare(v, item) == c.GST_VALUE_EQUAL) return true;
    return false;
}

pub fn isListLike(v: [*c]const Value) bool {
    const t = v.*.g_type;
    return t == value._gst_value_list_type or t == value._gst_value_array_type or t == value._gst_value_unique_list_type;
}

fn basicType(v: [*c]const Value) ?c.GType {
    if (v == null) return null;
    if (isListLike(v)) {
        if (of(v).len == 0) return null;
        return basicType(&of(v).fields[0]);
    }
    return v.*.g_type;
}

fn rangePair(a: c.GType, b: c.GType, x: c.GType, y: c.GType) bool {
    return (x == a and y == b) or (x == b and y == a);
}

pub fn compatible(a: [*c]const Value, b: [*c]const Value) bool {
    const ta = basicType(a) orelse return true;
    const tb = basicType(b) orelse return true;
    if (ta == tb) return true;
    const G_TYPE_INT: c.GType = 6 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    const G_TYPE_INT64: c.GType = 10 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    const G_TYPE_DOUBLE: c.GType = 15 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    return rangePair(G_TYPE_INT, value._gst_int_range_type, ta, tb) or
        rangePair(G_TYPE_INT64, value._gst_int64_range_type, ta, tb) or
        rangePair(G_TYPE_DOUBLE, value._gst_double_range_type, ta, tb) or
        rangePair(value._gst_fraction_type, value._gst_fraction_range_type, ta, tb);
}

fn holds(v: [*c]const Value, t: c.GType) bool {
    return v != null and v.*.g_type == t;
}

fn isValue(v: [*c]const Value) bool {
    return v != null and v.*.g_type != 0;
}

pub export fn gst_value_list_init(v: [*c]Value, prealloc: c.guint) [*c]Value {
    if (!check.that(v != null, "gst_value_list_init", "value != NULL")) return null;
    if (!check.that(v.*.g_type == 0, "gst_value_list_init", "G_VALUE_TYPE (value) == 0")) return null;
    initAs(v, value._gst_value_list_type, prealloc);
    return v;
}

pub export fn gst_value_array_init(v: [*c]Value, prealloc: c.guint) [*c]Value {
    if (!check.that(v != null, "gst_value_array_init", "value != NULL")) return null;
    if (!check.that(v.*.g_type == 0, "gst_value_array_init", "G_VALUE_TYPE (value) == 0")) return null;
    initAs(v, value._gst_value_array_type, prealloc);
    return v;
}

fn addCheck(comptime func: []const u8, comptime holds_expr: []const u8, v: [*c]Value, t: c.GType, item: [*c]const Value, comptime item_name: []const u8) bool {
    if (!check.that(holds(v, t), func, holds_expr)) return false;
    if (!check.that(isValue(item), func, "G_IS_VALUE (" ++ item_name ++ ")")) return false;
    return check.that(compatible(v, item), func, "gst_value_list_or_array_are_compatible (value, " ++ item_name ++ ")");
}

pub fn appendTake(v: [*c]Value, item: [*c]Value) void {
    pushTake(of(v), item);
    item.* = std.mem.zeroes(Value);
}

pub export fn gst_value_list_append_and_take_value(v: [*c]Value, item: [*c]Value) void {
    if (!addCheck("gst_value_list_append_and_take_value", "GST_VALUE_HOLDS_LIST (value)", v, value._gst_value_list_type, item, "append_value")) return;
    appendTake(v, item);
}

pub export fn gst_value_list_append_value(v: [*c]Value, item: [*c]const Value) void {
    if (!addCheck("gst_value_list_append_value", "GST_VALUE_HOLDS_LIST (value)", v, value._gst_value_list_type, item, "append_value")) return;
    var copy = std.mem.zeroes(Value);
    value.gst_value_init_and_copy(&copy, item);
    pushTake(of(v), &copy);
}

pub export fn gst_value_list_prepend_value(v: [*c]Value, item: [*c]const Value) void {
    if (!addCheck("gst_value_list_prepend_value", "GST_VALUE_HOLDS_LIST (value)", v, value._gst_value_list_type, item, "prepend_value")) return;
    var copy = std.mem.zeroes(Value);
    value.gst_value_init_and_copy(&copy, item);
    unshiftTake(of(v), &copy);
}

fn mergeCheck(comptime func: []const u8, dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) bool {
    if (!check.that(dest != null, func, "dest != NULL")) return false;
    if (!check.that(dest.*.g_type == 0, func, "G_VALUE_TYPE (dest) == 0")) return false;
    if (!check.that(isValue(a), func, "G_IS_VALUE (value1)")) return false;
    if (!check.that(isValue(b), func, "G_IS_VALUE (value2)")) return false;
    return check.that(compatible(a, b), func, "gst_value_list_or_array_are_compatible (value1, value2)");
}

fn spread(v: [*c]const Value) []const Value {
    if (holds(v, value._gst_value_list_type)) return items(v);
    return @as([*]const Value, @ptrCast(v))[0..1];
}

pub export fn gst_value_list_concat(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) void {
    if (!mergeCheck("gst_value_list_concat", dest, a, b)) return;
    const sa = spread(a);
    const sb = spread(b);
    initAs(dest, value._gst_value_list_type, @intCast(sa.len + sb.len));
    const l = of(dest);
    l.len = @intCast(sa.len + sb.len);
    for (sa, 0..) |*x, i| value.gst_value_init_and_copy(&l.fields[i], x);
    for (sb, 0..) |*x, i| value.gst_value_init_and_copy(&l.fields[sa.len + i], x);
}

pub fn concatTake(dest: [*c]Value, a: [*c]Value, b: [*c]Value) void {
    const a_list = holds(a, value._gst_value_list_type);
    const b_list = holds(b, value._gst_value_list_type);
    const na: c.guint = if (a_list) of(a).len else 1;
    const nb: c.guint = if (b_list) of(b).len else 1;
    initAs(dest, value._gst_value_list_type, na + nb);
    const l = of(dest);
    l.len = na + nb;
    if (a_list) {
        @memcpy(l.fields[0..na], of(a).fields[0..na]);
        of(a).len = 0;
        c.g_value_unset(a);
    } else {
        l.fields[0] = a.*;
        a.*.g_type = 0;
    }
    if (b_list) {
        @memcpy(l.fields[na .. na + nb], of(b).fields[0..nb]);
        of(b).len = 0;
        c.g_value_unset(b);
    } else {
        l.fields[na] = b.*;
        b.*.g_type = 0;
    }
}

pub export fn gst_value_list_merge(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) void {
    if (!mergeCheck("gst_value_list_merge", dest, a, b)) return;
    const sa = spread(a);
    const sb = spread(b);
    initAs(dest, value._gst_value_list_type, @intCast(sa.len + sb.len));
    const l = of(dest);
    l.len = @intCast(sa.len + sb.len);
    for (sa, 0..) |*x, i| value.gst_value_init_and_copy(&l.fields[i], x);
    var next = sa.len;
    var skipped: usize = 0;
    for (sb) |*x| {
        var dup = false;
        for (l.fields[0..sa.len]) |*y| {
            if (value.gst_value_compare(y, x) == c.GST_VALUE_EQUAL) {
                dup = true;
                break;
            }
        }
        if (dup) {
            skipped += 1;
        } else {
            value.gst_value_init_and_copy(&l.fields[next], x);
            next += 1;
        }
    }
    if (skipped == 0) return;
    const size = sa.len + sb.len - skipped;
    if (size > 1) {
        l.len = @intCast(size);
        return;
    }
    const only = l.fields[0];
    l.len = 0;
    c.g_value_unset(dest);
    dest.* = only;
}

pub export fn gst_value_list_get_size(v: [*c]const Value) c.guint {
    if (!check.that(holds(v, value._gst_value_list_type), "gst_value_list_get_size", "GST_VALUE_HOLDS_LIST (value)")) return 0;
    return of(v).len;
}

pub export fn gst_value_list_get_value(v: [*c]const Value, index: c.guint) [*c]const Value {
    if (!check.that(holds(v, value._gst_value_list_type), "gst_value_list_get_value", "GST_VALUE_HOLDS_LIST (value)")) return null;
    if (!check.that(index < of(v).len, "gst_value_list_get_value", "index < VALUE_LIST_SIZE (value)")) return null;
    return &of(v).fields[index];
}

pub export fn gst_value_array_append_value(v: [*c]Value, item: [*c]const Value) void {
    if (!addCheck("gst_value_array_append_value", "GST_VALUE_HOLDS_ARRAY (value)", v, value._gst_value_array_type, item, "append_value")) return;
    var copy = std.mem.zeroes(Value);
    value.gst_value_init_and_copy(&copy, item);
    pushTake(of(v), &copy);
}

pub export fn gst_value_array_append_and_take_value(v: [*c]Value, item: [*c]Value) void {
    if (!addCheck("gst_value_array_append_and_take_value", "GST_VALUE_HOLDS_ARRAY (value)", v, value._gst_value_array_type, item, "append_value")) return;
    appendTake(v, item);
}

pub export fn gst_value_array_prepend_value(v: [*c]Value, item: [*c]const Value) void {
    if (!addCheck("gst_value_array_prepend_value", "GST_VALUE_HOLDS_ARRAY (value)", v, value._gst_value_array_type, item, "prepend_value")) return;
    var copy = std.mem.zeroes(Value);
    value.gst_value_init_and_copy(&copy, item);
    unshiftTake(of(v), &copy);
}

pub export fn gst_value_array_get_size(v: [*c]const Value) c.guint {
    if (!check.that(holds(v, value._gst_value_array_type), "gst_value_array_get_size", "GST_VALUE_HOLDS_ARRAY (value)")) return 0;
    return of(v).len;
}

pub export fn gst_value_array_get_value(v: [*c]const Value, index: c.guint) [*c]const Value {
    if (!check.that(holds(v, value._gst_value_array_type), "gst_value_array_get_value", "GST_VALUE_HOLDS_ARRAY (value)")) return null;
    if (!check.that(index < of(v).len, "gst_value_array_get_value", "index < VALUE_LIST_SIZE (value)")) return null;
    return &of(v).fields[index];
}

fn uniqueHas(v: [*c]const Value, item: [*c]const Value) bool {
    var i: c.guint = 0;
    while (i < gst_value_unique_list_get_size(v)) : (i += 1) {
        if (value.gst_value_compare(gst_value_unique_list_get_value(v, i), item) == c.GST_VALUE_EQUAL) return true;
    }
    return false;
}

pub export fn gst_value_unique_list_append_value(v: [*c]Value, item: [*c]const Value) void {
    if (!addCheck("gst_value_unique_list_append_value", "GST_VALUE_HOLDS_UNIQUE_LIST (value)", v, value._gst_value_unique_list_type, item, "append_value")) return;
    if (uniqueHas(v, item)) return;
    var copy = std.mem.zeroes(Value);
    value.gst_value_init_and_copy(&copy, item);
    pushTake(of(v), &copy);
}

pub export fn gst_value_unique_list_append_and_take_value(v: [*c]Value, item: [*c]Value) void {
    if (!addCheck("gst_value_unique_list_append_and_take_value", "GST_VALUE_HOLDS_UNIQUE_LIST (value)", v, value._gst_value_unique_list_type, item, "append_value")) return;
    if (uniqueHas(v, item)) return;
    appendTake(v, item);
}

pub export fn gst_value_unique_list_prepend_value(v: [*c]Value, item: [*c]const Value) void {
    gst_value_list_prepend_value(v, item);
}

pub export fn gst_value_unique_list_concat(dest: [*c]Value, a: [*c]const Value, b: [*c]const Value) void {
    if (!mergeCheck("gst_value_unique_list_concat", dest, a, b)) return;
    const ut = value._gst_value_unique_list_type;
    _ = c.g_value_init(dest, ut);
    if (holds(a, ut)) c.g_value_copy(a, dest) else gst_value_unique_list_append_value(dest, a);
    if (holds(b, ut)) {
        for (items(b)) |*x| if (!contains(of(dest), x)) gst_value_unique_list_append_value(dest, x);
    } else if (!contains(of(dest), b)) gst_value_unique_list_append_value(dest, b);
}

pub export fn gst_value_unique_list_get_size(v: [*c]const Value) c.guint {
    if (!check.that(holds(v, value._gst_value_unique_list_type), "gst_value_unique_list_get_size", "GST_VALUE_HOLDS_UNIQUE_LIST (value)")) return 0;
    return of(v).len;
}

pub export fn gst_value_unique_list_get_value(v: [*c]const Value, index: c.guint) [*c]const Value {
    if (!check.that(holds(v, value._gst_value_unique_list_type), "gst_value_unique_list_get_value", "GST_VALUE_HOLDS_UNIQUE_LIST (value)")) return null;
    if (!check.that(index < of(v).len, "gst_value_unique_list_get_value", "index < VALUE_LIST_SIZE (value)")) return null;
    return &of(v).fields[index];
}

pub fn tableInit(v: [*c]Value) callconv(.c) void {
    v[0].data[0].v_pointer = create(0);
}

pub fn tableFree(v: [*c]Value) callconv(.c) void {
    const l = of(v);
    if (v[0].data[1].v_uint & c.G_VALUE_NOCOPY_CONTENTS != 0) return;
    for (l.fields[0..l.len]) |*x| c.g_value_unset(x);
    destroy(l);
}

pub fn tableCopy(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    dest[0].data[0].v_pointer = clone(of(src));
}

pub fn tablePeek(v: [*c]const Value) callconv(.c) c.gpointer {
    return v[0].data[0].v_pointer;
}

pub fn tableCollect(v: [*c]Value, _: c.guint, cv: ?*c.GTypeCValue, flags: c.guint) callconv(.c) [*c]u8 {
    const vals = @import("varargs.zig").cvaluesOf(cv);
    if (flags & c.G_VALUE_NOCOPY_CONTENTS != 0) {
        v[0].data[0].v_pointer = vals[0].v_pointer;
        v[0].data[1].v_uint = c.G_VALUE_NOCOPY_CONTENTS;
    } else v[0].data[0].v_pointer = clone(@ptrCast(@alignCast(vals[0].v_pointer)));
    return null;
}

pub fn tableLcopy(v: [*c]const Value, _: c.guint, cv: ?*c.GTypeCValue, flags: c.guint) callconv(.c) [*c]u8 {
    const vals = @import("varargs.zig").cvaluesOf(cv);
    const dest: ?*?*List = @ptrCast(@alignCast(vals[0].v_pointer));
    if (dest == null) {
        check.fail("gst_value_lcopy_list_or_array", "dest != NULL");
        return c.g_strdup_printf("value location for `%s' passed as NULL", c.g_type_name(v.*.g_type));
    }
    if (v[0].data[0].v_pointer == null) {
        check.fail("gst_value_lcopy_list_or_array", "value->data[0].v_pointer != NULL");
        return c.g_strdup_printf("invalid value given for `%s'", c.g_type_name(v.*.g_type));
    }
    dest.?.* = if (flags & c.G_VALUE_NOCOPY_CONTENTS != 0) of(v) else clone(of(v));
    return null;
}
