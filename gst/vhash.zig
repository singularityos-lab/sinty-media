const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const value = @import("value.zig");
const vtypes = @import("vtypes.zig");
const vlist = @import("vlist.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Value = c.GValue;

fn h32(x: anytype) c.guint {
    var v: c.gint = @bitCast(x);
    return c.g_int_hash(&v);
}

fn h64(x: anytype) c.guint {
    var v: i64 = @bitCast(x);
    return c.g_int64_hash(&v);
}

fn hDouble(x: f64) c.guint {
    var v = x;
    return c.g_double_hash(&v);
}

pub fn ordered(acc: *c.guint, h: c.guint) void {
    acc.* = std.math.rotl(c.guint, acc.*, 5) ^ h;
}

fn put(res: [*c]c.guint, h: c.guint) c.gboolean {
    res.* = h;
    return 1;
}

pub fn int(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h32(c.g_value_get_int(v)));
}
pub fn int64(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h64(c.g_value_get_int64(v)));
}
pub fn long(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h64(@as(i64, c.g_value_get_long(v))));
}
pub fn uint(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h32(c.g_value_get_uint(v)));
}
pub fn uint64(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h64(c.g_value_get_uint64(v)));
}
pub fn ulong(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    var u: u64 = c.g_value_get_ulong(v);
    return put(res, c.g_double_hash(&u));
}
pub fn uchar(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h32(@as(c.gint, c.g_value_get_uchar(v))));
}
pub fn gtype(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h64(@as(u64, c.g_value_get_gtype(v))));
}
pub fn double(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, hDouble(c.g_value_get_double(v)));
}
pub fn float(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h32(c.g_value_get_float(v)));
}
pub fn string(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, c.g_str_hash(c.g_value_get_string(v)));
}
pub fn boolean(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, @intFromBool(c.g_value_get_boolean(v) != 0));
}
pub fn enumeration(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h32(c.g_value_get_enum(v)));
}
pub fn flags(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h32(c.g_value_get_flags(v)));
}

pub fn intRange(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    const lo = vtypes.gst_value_get_int_range_min(v);
    const hi = vtypes.gst_value_get_int_range_max(v);
    const step = vtypes.gst_value_get_int_range_step(v);
    var acc: c.guint = 0;
    var i: c.gint = lo;
    while (i <= hi) {
        acc ^= h32(i);
        i = std.math.add(c.gint, i, step) catch break;
    }
    return put(res, acc);
}

pub fn int64Range(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    const lo = vtypes.gst_value_get_int64_range_min(v);
    const hi = vtypes.gst_value_get_int64_range_max(v);
    const step = vtypes.gst_value_get_int64_range_step(v);
    var acc: c.guint = 0;
    var i: i64 = lo;
    while (i <= hi) {
        acc ^= h64(i);
        i = std.math.add(i64, i, step) catch break;
    }
    return put(res, acc);
}

pub fn doubleRange(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, hDouble(vtypes.gst_value_get_double_range_min(v)) ^ hDouble(vtypes.gst_value_get_double_range_max(v)));
}

fn ratio(v: [*c]const Value) c.guint {
    const n: f32 = @floatFromInt(vtypes.gst_value_get_fraction_numerator(v));
    const d: f32 = @floatFromInt(vtypes.gst_value_get_fraction_denominator(v));
    return h32(n / d);
}

pub fn fraction(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, ratio(v));
}

pub fn fractionRange(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, ratio(vtypes.gst_value_get_fraction_range_min(v)) ^ ratio(vtypes.gst_value_get_fraction_range_max(v)));
}

pub fn valueArray(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    res.* = 0;
    const arr: *c.GValueArray = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    var i: c.guint = 0;
    while (i < arr.n_values) : (i += 1) {
        var h: c.guint = 0;
        if (gst_value_hash(&arr.values[i], &h) == 0) return 0;
        ordered(res, h);
    }
    return 1;
}

pub fn date(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    const d: ?*const c.GDate = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    const julian = c.g_date_get_julian(d);
    if (julian != 0) return put(res, h32(julian));
    var acc = h32(@as(u32, c.g_date_get_year(d)));
    ordered(&acc, h32(@as(u32, c.g_date_get_month(d))));
    ordered(&acc, h32(@as(u32, c.g_date_get_day(d))));
    return put(res, acc);
}

pub fn gDateTimeHash(dt: ?*c.GDateTime) c.guint {
    return h64(c.g_date_time_to_unix(dt));
}

pub fn gDateTime(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, gDateTimeHash(@ptrCast(c.g_value_get_boxed(v))));
}

pub fn bytes(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    var size: c.gsize = 0;
    const data: [*c]const u8 = @ptrCast(c.g_bytes_get_data(@ptrCast(c.g_value_get_boxed(v)), &size));
    var acc: c.guint = 0;
    for (0..size) |i| ordered(&acc, data[i]);
    return put(res, acc);
}

pub fn bitmask(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h64(vtypes.gst_value_get_bitmask(v)));
}

pub fn flagset(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, h32(vtypes.gst_value_get_flagset_flags(v) & vtypes.gst_value_get_flagset_mask(v)));
}

pub fn object(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return put(res, c.g_direct_hash(c.g_value_get_object(v)));
}

pub fn allocationParams(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    const p: ?*const c.GstAllocationParams = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    const x = p orelse return put(res, 0);
    var acc = h32(x.flags);
    ordered(&acc, h64(x.@"align"));
    ordered(&acc, h64(x.prefix));
    ordered(&acc, h64(x.padding));
    return put(res, acc);
}

pub fn list(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    res.* = 0;
    for (vlist.items(v)) |*it| {
        var h: c.guint = 0;
        if (gst_value_hash(it, &h) == 0) return 0;
        res.* ^= h;
    }
    return 1;
}

pub fn array(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    res.* = 0;
    for (vlist.items(v)) |*it| {
        var h: c.guint = 0;
        if (gst_value_hash(it, &h) == 0) return 0;
        ordered(res, h);
    }
    return 1;
}

pub fn strv(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    res.* = 0;
    const s: [*c]const [*c]const u8 = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    var i: usize = 0;
    while (s[i] != null) : (i += 1) ordered(res, c.g_str_hash(s[i]));
    return 1;
}

pub export fn gst_value_hash(v: [*c]const Value, res: [*c]c.guint) c.gboolean {
    if (!check.that(res != null, "gst_value_hash", "res")) return 0;
    res.* = 0;
    var t = v.*.g_type;
    const tb = value.hashTableOf(t);
    if (tb != null and tb.?.hash != null) {
        if (t == value._gst_value_list_type and vlist.items(v).len == 1) return gst_value_hash(&vlist.items(v)[0], res);
        if (t == value._gst_int_range_type or t == value._gst_int64_range_type) t = value._gst_value_list_type;
        var h: c.guint = 0;
        res.* = h32(@as(u32, @truncate(t)));
        if (tb.?.hash.?(v, &h) == 0) return 0;
        res.* ^= h;
        return 1;
    }
    if (c.g_type_check_value_holds(v, c.G_TYPE_ENUM) != 0) return enumeration(v, res);
    if (c.g_type_check_value_holds(v, c.G_TYPE_FLAGS) != 0) return flags(v, res);
    return 0;
}

fn fieldHash(name: [*c]const c.GstIdStr, v: [*c]const Value, data: c.gpointer) callconv(.c) c.gboolean {
    const acc: *c.guint = @ptrCast(@alignCast(data));
    acc.* ^= c.g_str_hash(c.gst_id_str_as_str(name));
    var h: c.guint = 0;
    if (gst_value_hash(v, &h) == 0) return 0;
    acc.* ^= h;
    return 1;
}

pub fn structureHash(s: [*c]const c.GstStructure, res: [*c]c.guint) c.gboolean {
    res.* = c.g_str_hash(c.gst_structure_get_name(s));
    return c.gst_structure_foreach_id_str(s, fieldHash, res);
}

pub fn structure(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return structureHash(value.gst_value_get_structure(v), res);
}

pub fn featuresHash(f: ?*const c.GstCapsFeatures, res: [*c]c.guint) c.gboolean {
    if (c.gst_caps_features_is_any(f) != 0) return put(res, c.g_str_hash("ANY"));
    const n = c.gst_caps_features_get_size(f);
    if (n == 0) return put(res, c.g_str_hash("EMPTY"));
    var acc: c.guint = 0;
    var i: c.guint = 0;
    while (i < n) : (i += 1) acc ^= c.g_str_hash(c.gst_caps_features_get_nth(f, i));
    return put(res, acc);
}

pub fn capsFeatures(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return featuresHash(value.gst_value_get_caps_features(v), res);
}

pub fn caps(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    const cp = value.gst_value_get_caps(v);
    const n = c.gst_caps_get_size(cp);
    if (c.gst_caps_is_any(cp) != 0) return put(res, c.g_str_hash("ANY"));
    if (n == 0) return put(res, c.g_str_hash("EMPTY"));
    res.* = 0;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        var h: c.guint = 0;
        if (structureHash(c.gst_caps_get_structure(cp, i), &h) == 0) return 0;
        res.* ^= h;
        if (featuresHash(c.gst_caps_get_features(cp, i), &h) == 0) return 0;
        res.* ^= h;
    }
    return 1;
}

pub fn bufferHash(buf: [*c]c.GstBuffer, res: [*c]c.guint) c.gboolean {
    res.* = 0;
    var map = std.mem.zeroes(c.GstMapInfo);
    if (c.gst_buffer_map(buf, &map, c.GST_MAP_READ) == 0) return 0;
    for (0..map.size) |i| ordered(res, map.data[i]);
    c.gst_buffer_unmap(buf, &map);
    return 1;
}

pub fn buffer(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return bufferHash(@ptrCast(@alignCast(c.g_value_get_boxed(v))), res);
}

pub fn sample(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return bufferHash(c.gst_sample_get_buffer(@ptrCast(@alignCast(c.g_value_get_boxed(v)))), res);
}

pub fn segment(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    const s: *const c.GstSegment = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    var acc = h32(@as(c.guint, s.flags));
    ordered(&acc, hDouble(s.rate));
    ordered(&acc, hDouble(s.applied_rate));
    ordered(&acc, h32(@as(c.guint, s.format)));
    for ([_]u64{ s.base, s.offset, s.start, s.stop, s.time, s.position, s.duration }) |x| ordered(&acc, h64(x));
    return put(res, acc);
}

pub fn dateTime(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    const gdt = c.gst_date_time_to_g_date_time(@ptrCast(@alignCast(c.g_value_get_boxed(v))));
    defer c.g_date_time_unref(gdt);
    return put(res, gDateTimeHash(gdt));
}
