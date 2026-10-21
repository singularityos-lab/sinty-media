const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const vtypes = @import("vtypes.zig");

const Value = c.GValue;

const LESS = c.GST_VALUE_LESS_THAN;
const EQUAL = c.GST_VALUE_EQUAL;
const GREATER = c.GST_VALUE_GREATER_THAN;
const UNORDERED = c.GST_VALUE_UNORDERED;

fn order(a: anytype, b: @TypeOf(a)) c.gint {
    if (a > b) return GREATER;
    if (a < b) return LESS;
    return EQUAL;
}

fn floatOrder(a: anytype, b: @TypeOf(a)) c.gint {
    if (a > b) return GREATER;
    if (a < b) return LESS;
    if (a == b) return EQUAL;
    return UNORDERED;
}

pub fn isStringChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or switch (ch) {
        '_', '-', '+', '/', ':', '.' => true,
        else => false,
    };
}

fn viaTransform(v: [*c]const Value) [*c]u8 {
    var s = std.mem.zeroes(Value);
    _ = c.g_value_init(&s, c.G_TYPE_STRING);
    if (c.g_value_transform(v, &s) == 0) unreachable;
    return @ptrCast(@constCast(c.g_value_get_string(&s)));
}

pub fn compareInt(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return order(c.g_value_get_int(a), c.g_value_get_int(b));
}
pub fn compareInt64(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return order(c.g_value_get_int64(a), c.g_value_get_int64(b));
}
pub fn compareLong(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return order(c.g_value_get_long(a), c.g_value_get_long(b));
}
pub fn compareUint(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return order(c.g_value_get_uint(a), c.g_value_get_uint(b));
}
pub fn compareUint64(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return order(c.g_value_get_uint64(a), c.g_value_get_uint64(b));
}
pub fn compareUlong(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return order(c.g_value_get_ulong(a), c.g_value_get_ulong(b));
}
pub fn compareUchar(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return order(c.g_value_get_uchar(a), c.g_value_get_uchar(b));
}

pub fn serializeByTransform(v: [*c]const Value) callconv(.c) [*c]u8 {
    return viaTransform(v);
}

const ByteOrder = struct {
    const little: i64 = 1234;
    const big: i64 = 4321;
    const host: i64 = if (@import("builtin").cpu.arch.endian() == .little) 1234 else 4321;
};

fn keyword(s: [*c]const u8, min: i64, max: i64) ?i64 {
    if (c.g_ascii_strcasecmp(s, "little_endian") == 0) return ByteOrder.little;
    if (c.g_ascii_strcasecmp(s, "big_endian") == 0) return ByteOrder.big;
    if (c.g_ascii_strcasecmp(s, "byte_order") == 0) return ByteOrder.host;
    if (c.g_ascii_strcasecmp(s, "min") == 0) return min;
    if (c.g_ascii_strcasecmp(s, "max") == 0) return max;
    return null;
}

fn scanSigned(s: [*c]const u8, min: i64, max: i64, bytes: u7) ?i64 {
    var end: [*c]u8 = null;
    std.c._errno().* = 0;
    var x: i64 = @bitCast(c.g_ascii_strtoull(s, &end, 0));
    if (std.c._errno().* == @intFromEnum(std.c.E.RANGE)) return null;
    if (end[0] != 0) x = keyword(s, min, max) orelse return null;
    if (bytes == 8) return x;
    const bits: u6 = @intCast(bytes * 8);
    const ux: u64 = @bitCast(x);
    if (x >= 0) {
        if (ux >> bits != 0) return null;
    } else {
        const hi = ~@as(u64, 0) << (bits - 1);
        if (ux & hi != hi) return null;
    }
    return x;
}

fn scanUnsigned(s: [*c]const u8, comptime T: type) ?T {
    var end: [*c]u8 = null;
    std.c._errno().* = 0;
    const raw = c.g_ascii_strtoull(s, &end, 0);
    if (std.c._errno().* == @intFromEnum(std.c.E.RANGE)) return null;
    if (end[0] == 0) return @truncate(raw);
    const k = keyword(s, 0, 0) orelse return null;
    if (c.g_ascii_strcasecmp(s, "max") == 0) return std.math.maxInt(T);
    if (k > std.math.maxInt(T)) return null;
    return @intCast(k);
}

pub fn deserializeInt(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const x = scanSigned(s, std.math.minInt(c.gint), std.math.maxInt(c.gint), @sizeOf(c.gint)) orelse return 0;
    c.g_value_set_int(dest, @truncate(x));
    return 1;
}
pub fn deserializeInt64(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const x = scanSigned(s, std.math.minInt(i64), std.math.maxInt(i64), 8) orelse return 0;
    c.g_value_set_int64(dest, x);
    return 1;
}
pub fn deserializeLong(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const x = scanSigned(s, std.math.minInt(c.glong), std.math.maxInt(c.glong), @sizeOf(c.glong)) orelse return 0;
    c.g_value_set_long(dest, @truncate(x));
    return 1;
}
pub fn deserializeUint(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    c.g_value_set_uint(dest, scanUnsigned(s, c.guint) orelse return 0);
    return 1;
}
pub fn deserializeUint64(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    c.g_value_set_uint64(dest, scanUnsigned(s, u64) orelse return 0);
    return 1;
}
pub fn deserializeUlong(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    c.g_value_set_ulong(dest, scanUnsigned(s, c.gulong) orelse return 0);
    return 1;
}
pub fn deserializeUchar(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    c.g_value_set_uchar(dest, scanUnsigned(s, u8) orelse return 0);
    return 1;
}

pub fn compareDouble(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return floatOrder(a[0].data[0].v_double, b[0].data[0].v_double);
}
pub fn compareFloat(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return floatOrder(a[0].data[0].v_float, b[0].data[0].v_float);
}

pub fn serializeDouble(v: [*c]const Value) callconv(.c) [*c]u8 {
    var buf: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
    return c.g_strdup(vtypes.dtostr(&buf, v[0].data[0].v_double));
}
pub fn serializeFloat(v: [*c]const Value) callconv(.c) [*c]u8 {
    var buf: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
    return c.g_strdup(vtypes.dtostr(&buf, v[0].data[0].v_float));
}

fn scanDouble(s: [*c]const u8, lim: f64) ?f64 {
    var end: [*c]u8 = null;
    const x = c.g_ascii_strtod(s, &end);
    if (end[0] == 0) return x;
    if (c.g_ascii_strcasecmp(s, "min") == 0) return -lim;
    if (c.g_ascii_strcasecmp(s, "max") == 0) return lim;
    return null;
}

pub fn deserializeDouble(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    c.g_value_set_double(dest, scanDouble(s, std.math.floatMax(f64)) orelse return 0);
    return 1;
}
pub fn deserializeFloat(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const lim: f64 = std.math.floatMax(f32);
    const x = scanDouble(s, lim) orelse return 0;
    if (x > lim or x < -lim) return 0;
    c.g_value_set_float(dest, @floatCast(x));
    return 1;
}

pub fn compareBoolean(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return if ((a[0].data[0].v_int != 0) == (b[0].data[0].v_int != 0)) EQUAL else UNORDERED;
}
pub fn serializeBoolean(v: [*c]const Value) callconv(.c) [*c]u8 {
    return c.g_strdup(if (v[0].data[0].v_int != 0) "true" else "false");
}
pub fn deserializeBoolean(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const yes = [_][*c]const u8{ "true", "yes", "t" };
    const no = [_][*c]const u8{ "false", "no", "f" };
    for (yes) |w| if (c.g_ascii_strcasecmp(s, w) == 0) {
        c.g_value_set_boolean(dest, 1);
        return 1;
    };
    if (std.mem.orderZ(u8, s, "1") == .eq) {
        c.g_value_set_boolean(dest, 1);
        return 1;
    }
    for (no) |w| if (c.g_ascii_strcasecmp(s, w) == 0) {
        c.g_value_set_boolean(dest, 0);
        return 1;
    };
    if (std.mem.orderZ(u8, s, "0") == .eq) {
        c.g_value_set_boolean(dest, 0);
        return 1;
    }
    return 0;
}

pub fn compareString(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x: [*c]const u8 = @ptrCast(a[0].data[0].v_pointer);
    const y: [*c]const u8 = @ptrCast(b[0].data[0].v_pointer);
    if (x == null or y == null) return if (x == y) EQUAL else UNORDERED;
    return switch (std.mem.orderZ(u8, x, y)) {
        .lt => LESS,
        .gt => GREATER,
        .eq => EQUAL,
    };
}

fn needsOctal(ch: u8) bool {
    return ch < 0x20 or ch >= 0x7f;
}

fn wrappedLen(s: [*c]const u8) ?usize {
    if (s == null) return null;
    const str = std.mem.span(s);
    if (std.mem.eql(u8, str, "NULL")) return 4;
    var len: usize = 0;
    var quoted = false;
    for (str) |ch| {
        if (isStringChar(ch)) {
            len += 1;
        } else {
            quoted = true;
            len += if (needsOctal(ch)) 4 else 2;
        }
    }
    return if (quoted or len == 0) len else null;
}

fn wrapInto(s: [*c]const u8, len: usize) [*c]u8 {
    const out: [*]u8 = @ptrCast(c.g_malloc(len + 3));
    var w: usize = 0;
    out[w] = '"';
    w += 1;
    for (std.mem.span(s)) |ch| {
        if (isStringChar(ch)) {
            out[w] = ch;
            w += 1;
        } else if (needsOctal(ch)) {
            out[w..][0..4].* = .{ '\\', '0' + (ch >> 6), '0' + ((ch >> 3) & 7), '0' + (ch & 7) };
            w += 4;
        } else {
            out[w..][0..2].* = .{ '\\', ch };
            w += 2;
        }
    }
    out[w] = '"';
    out[w + 1] = 0;
    return out;
}

pub fn wrap(s: [*c]const u8) [*c]u8 {
    const len = wrappedLen(s) orelse return c.g_strdup(s);
    return wrapInto(s, len);
}

pub fn takeAndWrap(s: [*c]u8) [*c]u8 {
    const len = wrappedLen(s) orelse return s;
    defer c.g_free(s);
    return wrapInto(s, len);
}

fn isOctal(ch: u8) bool {
    return ch >= '0' and ch <= '7';
}

pub fn unwrap(s: [*c]const u8) [*c]u8 {
    if (s == null or s[0] != '"') return null;
    const out = c.g_strdup(s);
    var r: usize = 1;
    var w: usize = 0;
    while (out[r] != 0) {
        const ch = out[r];
        if (isStringChar(ch)) {
            out[w] = ch;
            w += 1;
            r += 1;
        } else if (ch == '"') {
            break;
        } else if (ch == '\\') {
            r += 1;
            const d = out[r];
            if (d >= '0' and d <= '3') {
                if (!isOctal(out[r + 1]) or !isOctal(out[r + 2])) {
                    c.g_free(out);
                    return null;
                }
                out[w] = ((d - '0') << 6) + ((out[r + 1] - '0') << 3) + (out[r + 2] - '0');
                w += 1;
                r += 3;
            } else {
                if (d == 0) {
                    c.g_free(out);
                    return null;
                }
                out[w] = d;
                w += 1;
                r += 1;
            }
        } else {
            out[w] = ch;
            w += 1;
            r += 1;
        }
    }
    if (out[r] != '"' or out[r + 1] != 0) {
        c.g_free(out);
        return null;
    }
    out[w] = 0;
    return out;
}

pub fn serializeString(v: [*c]const Value) callconv(.c) [*c]u8 {
    return wrap(@ptrCast(v[0].data[0].v_pointer));
}

pub fn deserializeString(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const str = std.mem.span(s);
    if (std.mem.eql(u8, str, "NULL")) {
        c.g_value_set_string(dest, null);
        return 1;
    }
    if (str[0] != '"' or str[str.len - 1] != '"') {
        if (c.g_utf8_validate(s, -1, null) == 0) return 0;
        c.g_value_set_string(dest, s);
        return 1;
    }
    const out = unwrap(s);
    if (out == null) return 0;
    if (c.g_utf8_validate(out, -1, null) == 0) {
        c.g_free(out);
        return 0;
    }
    c.g_value_take_string(dest, out);
    return 1;
}

fn enumOf(v: [*c]const Value) [*c]c.GEnumClass {
    return @ptrCast(@alignCast(c.g_type_class_ref(v.*.g_type)));
}

pub fn compareEnum(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const ka = enumOf(a);
    const kb = enumOf(b);
    if (!check.that(ka != null, "gst_value_compare_enum", "klass1")) return UNORDERED;
    if (!check.that(kb != null, "gst_value_compare_enum", "klass2")) return UNORDERED;
    const ea = c.g_enum_get_value(ka, c.g_value_get_enum(a));
    const eb = c.g_enum_get_value(kb, c.g_value_get_enum(b));
    c.g_type_class_unref(ka);
    c.g_type_class_unref(kb);
    if (!check.that(ea != null, "gst_value_compare_enum", "en1")) return UNORDERED;
    if (!check.that(eb != null, "gst_value_compare_enum", "en2")) return UNORDERED;
    return order(ea.*.value, eb.*.value);
}

pub fn serializeEnum(v: [*c]const Value) callconv(.c) [*c]u8 {
    const k = enumOf(v);
    if (!check.that(k != null, "gst_value_serialize_enum", "klass")) return null;
    const e = c.g_enum_get_value(k, c.g_value_get_enum(v));
    c.g_type_class_unref(k);
    if (e == null and v.*.g_type == c.gst_format_get_type()) {
        const def = c.gst_format_get_details(@intCast(c.g_value_get_enum(v)));
        if (!check.that(def != null, "gst_value_serialize_enum", "format_def != NULL")) return null;
        return c.g_strdup(def.*.description);
    }
    if (!check.that(e != null, "gst_value_serialize_enum", "en")) return null;
    return c.g_strdup(e.*.value_nick);
}

fn formatMatch(item: c.gconstpointer, s: c.gconstpointer) callconv(.c) c.gint {
    const v: [*c]const Value = @ptrCast(@alignCast(item));
    const def: *const c.GstFormatDefinition = @ptrCast(@alignCast(c.g_value_get_pointer(v)));
    const str: [*c]const u8 = @ptrCast(s);
    if (c.g_ascii_strcasecmp(str, def.nick) == 0) return 0;
    return c.g_ascii_strcasecmp(str, def.description);
}

pub fn deserializeEnum(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const k = enumOf(dest);
    if (!check.that(k != null, "gst_value_deserialize_enum", "klass")) return 0;
    var e = c.g_enum_get_value_by_name(k, s);
    if (e == null) e = c.g_enum_get_value_by_nick(k, s);
    if (e == null) {
        var end: [*c]u8 = null;
        const i: c.gint = @truncate(c.strtol(s, &end, 0));
        if (end != null and end[0] == 0) e = c.g_enum_get_value(k, i);
    }
    c.g_type_class_unref(k);
    if (e == null and dest.*.g_type == c.gst_format_get_type()) {
        var res = std.mem.zeroes(Value);
        const it = c.gst_format_iterate_definitions();
        const found = c.gst_iterator_find_custom(it, formatMatch, &res, @constCast(s));
        if (found != 0) {
            const def: ?*const c.GstFormatDefinition = @ptrCast(@alignCast(c.g_value_get_pointer(&res)));
            if (!check.that(def != null, "gst_value_deserialize_enum", "format_def != NULL")) return 0;
            c.g_value_set_enum(dest, @intCast(def.?.value));
            c.g_value_unset(&res);
        }
        c.gst_iterator_free(it);
        return found;
    }
    if (e == null) return 0;
    c.g_value_set_enum(dest, e.*.value);
    return 1;
}

fn flagsOf(v: [*c]const Value) [*c]c.GFlagsClass {
    return @ptrCast(@alignCast(c.g_type_class_ref(v.*.g_type)));
}

pub fn compareFlags(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const ka = flagsOf(a);
    const kb = flagsOf(b);
    if (!check.that(ka != null, "gst_value_compare_gflags", "klass1")) return UNORDERED;
    if (!check.that(kb != null, "gst_value_compare_gflags", "klass2")) return UNORDERED;
    const fa = c.g_value_get_flags(a);
    const fb = c.g_value_get_flags(b);
    c.g_type_class_unref(ka);
    c.g_type_class_unref(kb);
    return order(fa, fb);
}

pub fn serializeFlags(v: [*c]const Value) callconv(.c) [*c]u8 {
    const k = flagsOf(v);
    if (!check.that(k != null, "gst_value_serialize_gflags", "klass")) return null;
    var flags = c.g_value_get_flags(v);
    if (flags == 0) {
        const none = c.g_flags_get_first_value(k, 0);
        return c.g_strdup(if (none != null) none.*.value_name else "0");
    }
    var out = c.g_strdup("");
    var first = true;
    while (flags != 0) {
        const fv = c.g_flags_get_first_value(k, flags);
        if (fv == null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Could not serialize invalid flags 0x%x of type %s", flags, c.g_type_name(v.*.g_type));
            c.g_free(out);
            out = c.g_strdup("0");
            break;
        }
        const next = c.g_strconcat(out, @as([*c]const u8, if (first) "" else "+"), fv.*.value_name, @as(?*anyopaque, null));
        c.g_free(out);
        out = next;
        first = false;
        flags &= ~fv.*.value;
    }
    c.g_type_class_unref(k);
    return out;
}

pub fn deserializeFlags(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const k = flagsOf(dest);
    defer c.g_type_class_unref(k);
    var flags: c.guint = 0;
    if (!vtypes.flagsFromString(k, s, &flags, null)) return 0;
    c.g_value_set_flags(dest, flags);
    return 1;
}

pub fn compareGType(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return if (a[0].data[0].v_pointer == b[0].data[0].v_pointer) EQUAL else UNORDERED;
}
pub fn serializeGType(v: [*c]const Value) callconv(.c) [*c]u8 {
    return c.g_strdup(c.g_type_name(c.g_value_get_gtype(v)));
}
pub fn deserializeGType(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    const t = c.g_type_from_name(s);
    if (t == 0) return 0;
    c.g_value_set_gtype(dest, t);
    return 1;
}
