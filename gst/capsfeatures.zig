const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const idstr = @import("idstr.zig");
const va = @import("varargs.zig");
const vbasic = @import("vbasic.zig");
const value = @import("value.zig");

comptime {
    @import("abi.zig").check(@This());
}

const IdStr = c.GstIdStr;
const Value = c.GValue;
const CF = c.GstCapsFeatures;

const Features = extern struct {
    type: c.GType,
    parent_refcount: ?*c.gint,
    ids: [*c]IdStr,
    len: c.guint,
    cap: c.guint,
    any: c.gboolean,
};

pub export var _gst_caps_features_type: c.GType = 0;
pub export var _gst_caps_features_any: ?*CF = null;
pub export var _gst_caps_features_memory_system_memory: ?*CF = null;

var sysmem: IdStr = std.mem.zeroes(IdStr);
var forever: c.gint = std.math.maxInt(c.gint);
var type_once: gtype.Once = .{};

fn of(p: anytype) *Features {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn pub_(f: *Features) ?*CF {
    return @ptrCast(f);
}

fn items(f: *Features) []IdStr {
    if (f.len == 0) return &.{};
    return f.ids[0..f.len];
}

fn mutable(f: *Features) bool {
    const rc = f.parent_refcount orelse return true;
    return @atomicLoad(c.gint, rc, .monotonic) == 1;
}

pub export fn gst_caps_features_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstCapsFeatures", @ptrCast(&gst_caps_features_copy), @ptrCast(&gst_caps_features_free));
        }
    }.f);
}

pub export fn gst_is_caps_features(obj: c.gconstpointer) c.gboolean {
    return @intFromBool(obj != null and of(obj).type == _gst_caps_features_type);
}

fn validName(name: [*c]const u8) bool {
    var p = name;
    while (std.ascii.isAlphabetic(p[0])) p += 1;
    if (p[0] != ':') return false;
    p += 1;
    if (!std.ascii.isAlphabetic(p[0])) return false;
    while (std.ascii.isAlphanumeric(p[0])) p += 1;
    return p[0] == 0;
}

fn create() *Features {
    const f: *Features = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Features))));
    f.* = .{ .type = _gst_caps_features_type, .parent_refcount = null, .ids = null, .len = 0, .cap = 0, .any = 0 };
    return f;
}

pub export fn gst_caps_features_new_empty() ?*CF {
    return pub_(create());
}

pub export fn gst_caps_features_new_any() ?*CF {
    const f = create();
    f.any = 1;
    return pub_(f);
}

pub export fn gst_caps_features_new_single(feature: [*c]const u8) ?*CF {
    if (!check.that(feature != null, "gst_caps_features_new_single", "feature != NULL")) return null;
    const f = gst_caps_features_new_empty();
    gst_caps_features_add(f, feature);
    return f;
}

pub export fn gst_caps_features_new_single_static_str(feature: [*c]const u8) ?*CF {
    if (!check.that(feature != null, "gst_caps_features_new_single_static_str", "feature != NULL")) return null;
    const f = gst_caps_features_new_empty();
    gst_caps_features_add_static_str(f, feature);
    return f;
}

fn listStr(first: [*c]const u8, ap: *va.VaList) callconv(.c) ?*CF {
    const f = gst_caps_features_new_empty();
    var cur = first;
    while (cur != null) : (cur = @cVaArg(ap, [*c]const u8)) gst_caps_features_add(f, cur);
    return f;
}
fn listStatic(first: [*c]const u8, ap: *va.VaList) callconv(.c) ?*CF {
    const f = gst_caps_features_new_empty();
    var cur = first;
    while (cur != null) : (cur = @cVaArg(ap, [*c]const u8)) gst_caps_features_add_static_str(f, cur);
    return f;
}
fn listQuark(first: c.GQuark, ap: *va.VaList) callconv(.c) ?*CF {
    const f = gst_caps_features_new_empty();
    var cur = first;
    while (cur != 0) : (cur = @cVaArg(ap, c.GQuark)) gst_caps_features_add_id(f, cur);
    return f;
}
fn listIdStr(first: [*c]const IdStr, ap: *va.VaList) callconv(.c) ?*CF {
    const f = gst_caps_features_new_empty();
    var cur = first;
    while (cur != null) : (cur = @cVaArg(ap, [*c]const IdStr)) gst_caps_features_add_id_str(f, cur);
    return f;
}

pub export fn gst_caps_features_new(first: [*c]const u8, ...) callconv(.c) ?*CF {
    if (!check.that(first != null, "gst_caps_features_new", "feature1 != NULL")) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return listStr(first, &ap);
}

pub export fn gst_caps_features_new_valist(first: [*c]const u8, ap: va.CVaList) ?*CF {
    if (!check.that(first != null, "gst_caps_features_new_valist", "feature1 != NULL")) return null;
    return listStr(first, va.fromC(ap));
}

pub export fn gst_caps_features_new_static_str(first: [*c]const u8, ...) callconv(.c) ?*CF {
    if (!check.that(first != null, "gst_caps_features_new_static_str", "feature1 != NULL")) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return listStatic(first, &ap);
}

pub export fn gst_caps_features_new_static_str_valist(first: [*c]const u8, ap: va.CVaList) ?*CF {
    if (!check.that(first != null, "gst_caps_features_new_static_str_valist", "feature1 != NULL")) return null;
    return listStatic(first, va.fromC(ap));
}

pub export fn gst_caps_features_new_id(first: c.GQuark, ...) callconv(.c) ?*CF {
    if (!check.that(first != 0, "gst_caps_features_new_id", "feature1 != 0")) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return listQuark(first, &ap);
}

pub export fn gst_caps_features_new_id_valist(first: c.GQuark, ap: va.CVaList) ?*CF {
    if (!check.that(first != 0, "gst_caps_features_new_id_valist", "feature1 != 0")) return null;
    return listQuark(first, va.fromC(ap));
}

pub export fn gst_caps_features_new_id_str(first: [*c]const IdStr, ...) callconv(.c) ?*CF {
    if (!check.that(first != null, "gst_caps_features_new_id_str", "feature1 != NULL")) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return listIdStr(first, &ap);
}

pub export fn gst_caps_features_new_id_str_valist(first: [*c]const IdStr, ap: va.CVaList) ?*CF {
    if (!check.that(first != null, "gst_caps_features_new_id_str_valist", "feature1 != NULL")) return null;
    return listIdStr(first, va.fromC(ap));
}

pub export fn gst_caps_features_set_parent_refcount(fp: ?*CF, refcount: [*c]c.gint) c.gboolean {
    const f = of(fp orelse {
        check.fail("gst_caps_features_set_parent_refcount", "features != NULL");
        return 0;
    });
    if (f.parent_refcount != null) {
        if (refcount != null) {
            check.fail("gst_caps_features_set_parent_refcount", "refcount == NULL");
            return 0;
        }
    } else if (refcount == null) {
        check.fail("gst_caps_features_set_parent_refcount", "refcount != NULL");
        return 0;
    }
    f.parent_refcount = refcount;
    return 1;
}

pub export fn gst_caps_features_copy(src: ?*const CF) ?*CF {
    const s = of(src orelse {
        check.fail("gst_caps_features_copy", "features != NULL");
        return null;
    });
    const out = create();
    for (items(s)) |*id| gst_caps_features_add_id_str(pub_(out), id);
    out.any = s.any;
    return pub_(out);
}

pub export fn gst_caps_features_free(fp: ?*CF) void {
    const f = of(fp orelse return check.fail("gst_caps_features_free", "features != NULL"));
    if (!check.that(f.parent_refcount == null, "gst_caps_features_free", "features->parent_refcount == NULL")) return;
    for (items(f)) |*id| idstr.gst_id_str_clear(id);
    c.g_free(f.ids);
    c.g_free(f);
}

pub fn appendTo(fp: ?*const CF, out: *c.GString) void {
    const f = of(fp orelse return check.fail("priv_gst_caps_features_append_to_gstring", "features != NULL"));
    if (f.len == 0 and f.any != 0) {
        _ = c.g_string_append(out, "ANY");
        return;
    }
    for (items(f), 0..) |*id, i| {
        _ = c.g_string_append(out, idstr.gst_id_str_as_str(id));
        if (i + 1 < f.len) _ = c.g_string_append(out, ", ");
    }
}

pub export fn gst_caps_features_to_string(fp: ?*const CF) [*c]u8 {
    const f = fp orelse {
        check.fail("gst_caps_features_to_string", "features != NULL");
        return null;
    };
    const out = c.g_string_sized_new(@as(c.gsize, of(f).len) * 14 + 1);
    appendTo(f, out);
    return c.g_string_free(out, 0);
}

fn rejectText(original: [*c]const u8, f: ?*CF) ?*CF {
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Failed deserialize caps features '%s'", original);
    gst_caps_features_free(f);
    return null;
}

pub export fn gst_caps_features_from_string(text: [*c]const u8) ?*CF {
    const out = gst_caps_features_new_empty();
    if (text == null or text[0] == 0) return out;
    if (std.mem.orderZ(u8, text, "ANY") == .eq) {
        of(out).any = 1;
        return out;
    }
    var p = text;
    while (p[0] == ' ') p += 1;
    var start = p;
    var escaped = false;
    while (true) {
        const ch = p[0];
        if (ch == '\\') {
            escaped = true;
            p += 1;
            continue;
        }
        if ((!escaped and ch == ',') or ch == 0) {
            const len = @intFromPtr(p) - @intFromPtr(start);
            if (len == 0) return rejectText(text, out);
            const piece = c.g_strndup(start, len);
            var end = len;
            while (end > 0 and piece[end - 1] == ' ') : (end -= 1) piece[end - 1] = 0;
            if (piece[0] == 0 or c.strstr(piece, " ") != null) {
                c.g_free(piece);
                return rejectText(text, out);
            }
            gst_caps_features_add(out, piece);
            c.g_free(piece);
            if (ch == 0) break;
            p += 1;
            while (p[0] == ' ') p += 1;
            start = p;
        } else {
            escaped = false;
            p += 1;
        }
    }
    return out;
}

pub export fn gst_caps_features_get_size(fp: ?*const CF) c.guint {
    const f = fp orelse {
        check.fail("gst_caps_features_get_size", "features != NULL");
        return 0;
    };
    return of(f).len;
}

pub export fn gst_caps_features_get_nth_id_str(fp: ?*const CF, i: c.guint) [*c]const IdStr {
    const f = of(fp orelse {
        check.fail("gst_caps_features_get_nth_id_str", "features != NULL");
        return null;
    });
    if (!check.that(i < f.len, "gst_caps_features_get_nth_id_str", "i < features->array->len")) return null;
    return &f.ids[i];
}

pub export fn gst_caps_features_get_nth(fp: ?*const CF, i: c.guint) [*c]const u8 {
    if (fp == null) {
        check.fail("gst_caps_features_get_nth", "features != NULL");
        return null;
    }
    const id = gst_caps_features_get_nth_id_str(fp, i);
    return if (id == null) null else idstr.gst_id_str_as_str(id);
}

pub export fn gst_caps_features_get_nth_id(fp: ?*const CF, i: c.guint) c.GQuark {
    const f = of(fp orelse {
        check.fail("gst_caps_features_get_nth_id", "features != NULL");
        return 0;
    });
    if (!check.that(i < f.len, "gst_caps_features_get_nth_id", "i < features->array->len")) return 0;
    return c.g_quark_from_string(idstr.gst_id_str_as_str(&f.ids[i]));
}

pub export fn gst_caps_features_contains_id_str(fp: ?*const CF, feature: [*c]const IdStr) c.gboolean {
    const f = of(fp orelse {
        check.fail("gst_caps_features_contains_id_str", "features != NULL");
        return 0;
    });
    if (!check.that(feature != null, "gst_caps_features_contains_id_str", "feature != NULL")) return 0;
    if (f.any != 0) return 1;
    if (f.len == 0) return idstr.gst_id_str_is_equal(feature, &sysmem);
    for (items(f)) |*id| if (idstr.gst_id_str_is_equal(id, feature) != 0) return 1;
    return 0;
}

pub export fn gst_caps_features_contains(fp: ?*const CF, feature: [*c]const u8) c.gboolean {
    if (!check.that(fp != null, "gst_caps_features_contains", "features != NULL")) return 0;
    if (!check.that(feature != null, "gst_caps_features_contains", "feature != NULL")) return 0;
    var s = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&s, feature);
    defer idstr.gst_id_str_clear(&s);
    return gst_caps_features_contains_id_str(fp, &s);
}

pub export fn gst_caps_features_contains_id(fp: ?*const CF, feature: c.GQuark) c.gboolean {
    if (!check.that(fp != null, "gst_caps_features_contains_id", "features != NULL")) return 0;
    if (!check.that(feature != 0, "gst_caps_features_contains_id", "feature != 0")) return 0;
    var s = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&s, c.g_quark_to_string(feature));
    return gst_caps_features_contains_id_str(fp, &s);
}

fn onlySysmem(f: *Features) bool {
    return f.len == 1 and gst_caps_features_contains_id_str(pub_(f), &sysmem) != 0;
}

pub export fn gst_caps_features_is_equal(ap: ?*const CF, bp: ?*const CF) c.gboolean {
    const a = of(ap orelse {
        check.fail("gst_caps_features_is_equal", "features1 != NULL");
        return 0;
    });
    const b = of(bp orelse {
        check.fail("gst_caps_features_is_equal", "features2 != NULL");
        return 0;
    });
    if (a.any != 0 or b.any != 0) return 1;
    if (a.len == 0 and b.len == 0) return 1;
    if (a.len == 0 and onlySysmem(b)) return 1;
    if (b.len == 0 and onlySysmem(a)) return 1;
    if (a.len != b.len) return 0;
    for (items(a)) |*id| if (gst_caps_features_contains_id_str(pub_(b), id) == 0) return 0;
    return 1;
}

pub export fn gst_caps_features_is_any(fp: ?*const CF) c.gboolean {
    const f = fp orelse {
        check.fail("gst_caps_features_is_any", "features != NULL");
        return 0;
    };
    return of(f).any;
}

fn takeId(f: *Features, id: *IdStr) void {
    const name = idstr.gst_id_str_as_str(id);
    if (!validName(name)) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Invalid caps feature name: %s", name);
        idstr.gst_id_str_clear(id);
        return;
    }
    if (f.len > 0 and gst_caps_features_contains_id_str(pub_(f), id) != 0) {
        idstr.gst_id_str_clear(id);
        return;
    }
    if (f.len == f.cap) {
        f.cap = @max(4, f.cap * 2);
        f.ids = @ptrCast(@alignCast(c.g_realloc(f.ids, @as(usize, f.cap) * @sizeOf(IdStr))));
    }
    f.ids[f.len] = id.*;
    f.len += 1;
}

fn addGuard(comptime func: []const u8, fp: ?*CF, has_feature: bool, comptime feature_expr: []const u8) ?*Features {
    const f = of(fp orelse {
        check.fail(func, "features != NULL");
        return null;
    });
    if (!check.that(mutable(f), func, "IS_MUTABLE (features)")) return null;
    if (!check.that(has_feature, func, feature_expr)) return null;
    if (!check.that(f.any == 0, func, "!features->is_any")) return null;
    return f;
}

pub export fn gst_caps_features_add(fp: ?*CF, feature: [*c]const u8) void {
    const f = addGuard("gst_caps_features_add", fp, feature != null, "feature != NULL") orelse return;
    var s = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set(&s, feature);
    takeId(f, &s);
}

pub export fn gst_caps_features_add_static_str(fp: ?*CF, feature: [*c]const u8) void {
    const f = addGuard("gst_caps_features_add_static_str", fp, feature != null, "feature != NULL") orelse return;
    var s = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&s, feature);
    takeId(f, &s);
}

pub export fn gst_caps_features_add_id(fp: ?*CF, feature: c.GQuark) void {
    const f = addGuard("gst_caps_features_add_id", fp, feature != 0, "feature != 0") orelse return;
    var s = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&s, c.g_quark_to_string(feature));
    takeId(f, &s);
}

pub export fn gst_caps_features_add_id_str(fp: ?*CF, feature: [*c]const IdStr) void {
    const f = addGuard("gst_caps_features_add_id_str", fp, feature != null, "feature != NULL") orelse return;
    var s = std.mem.zeroes(IdStr);
    idstr.gst_id_str_copy_into(&s, feature);
    takeId(f, &s);
}

fn removeGuard(comptime func: []const u8, fp: ?*CF, has_feature: bool, comptime feature_expr: []const u8) ?*Features {
    const f = of(fp orelse {
        check.fail(func, "features != NULL");
        return null;
    });
    if (!check.that(mutable(f), func, "IS_MUTABLE (features)")) return null;
    if (!check.that(has_feature, func, feature_expr)) return null;
    return f;
}

pub export fn gst_caps_features_remove_id_str(fp: ?*CF, feature: [*c]const IdStr) void {
    const f = removeGuard("gst_caps_features_remove_id_str", fp, feature != null, "feature != NULL") orelse return;
    for (items(f), 0..) |*id, i| {
        if (idstr.gst_id_str_is_equal(id, feature) == 0) continue;
        idstr.gst_id_str_clear(id);
        f.len -= 1;
        if (i != f.len) f.ids[i] = f.ids[f.len];
        return;
    }
}

pub export fn gst_caps_features_remove(fp: ?*CF, feature: [*c]const u8) void {
    _ = removeGuard("gst_caps_features_remove", fp, feature != null, "feature != NULL") orelse return;
    var s = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&s, feature);
    defer idstr.gst_id_str_clear(&s);
    gst_caps_features_remove_id_str(fp, &s);
}

pub export fn gst_caps_features_remove_id(fp: ?*CF, feature: c.GQuark) void {
    _ = removeGuard("gst_caps_features_remove_id", fp, feature != 0, "feature != 0") orelse return;
    var s = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&s, c.g_quark_to_string(feature));
    gst_caps_features_remove_id_str(fp, &s);
}

fn toString(src: [*c]const Value, dest: [*c]Value) callconv(.c) void {
    if (!check.that(src != null, "gst_caps_features_transform_to_string", "src_value != NULL")) return;
    if (!check.that(dest != null, "gst_caps_features_transform_to_string", "dest_value != NULL")) return;
    dest[0].data[0].v_pointer = gst_caps_features_to_string(@ptrCast(@alignCast(src[0].data[0].v_pointer)));
}

fn serializeValue(v: [*c]const Value) callconv(.c) [*c]u8 {
    return vbasic.takeAndWrap(gst_caps_features_to_string(@ptrCast(@alignCast(c.g_value_get_boxed(v)))));
}

fn deserializeValue(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    var f: ?*CF = null;
    if (s[0] != '"') {
        f = gst_caps_features_from_string(s);
    } else {
        const raw = vbasic.unwrap(s);
        if (raw == null) return 0;
        f = gst_caps_features_from_string(raw);
        c.g_free(raw);
    }
    const got = f orelse return 0;
    c.g_value_take_boxed(dest, got);
    return 1;
}

var value_table: c.GstValueTable = .{};

pub fn initialize() void {
    _gst_caps_features_type = gst_caps_features_get_type();
    c.g_value_register_transform_func(_gst_caps_features_type, c.G_TYPE_STRING, toString);
    _gst_caps_features_any = gst_caps_features_new_any();
    _ = gst_caps_features_set_parent_refcount(_gst_caps_features_any, &forever);
    idstr.gst_id_str_set_static_str(&sysmem, c.GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY);
    _gst_caps_features_memory_system_memory = gst_caps_features_new_id_str(&sysmem, @as([*c]const IdStr, null));
    _ = gst_caps_features_set_parent_refcount(_gst_caps_features_memory_system_memory, &forever);
}

pub fn registerValue() void {
    value_table = .{ .type = gst_caps_features_get_type(), .serialize = serializeValue, .deserialize = deserializeValue, .hash = @import("vhash.zig").capsFeatures };
    value.gst_value_register(&value_table);
}
