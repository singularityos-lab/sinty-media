const std = @import("std");
const c = @import("c.zig").c;
const gtype = @import("gtype.zig");
const check = @import("check.zig");
const idstr = @import("idstr.zig");
const va = @import("varargs.zig");
const value = @import("value.zig");
const vtypes = @import("vtypes.zig");
const vlist = @import("vlist.zig");
const vsets = @import("vsets.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Structure = c.GstStructure;
const Value = c.GValue;
const IdStr = c.GstIdStr;

const G_TYPE_BOOLEAN: c.GType = 5 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_INT: c.GType = 6 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_UINT: c.GType = 7 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_INT64: c.GType = 10 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_UINT64: c.GType = 11 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_FLOAT: c.GType = 14 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_DOUBLE: c.GType = 15 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_STRING: c.GType = 16 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_POINTER: c.GType = 17 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_OBJECT: c.GType = 20 << c.G_TYPE_FUNDAMENTAL_SHIFT;

pub const Field = extern struct {
    name: IdStr,
    value: Value,
};

const Impl = extern struct {
    s: Structure,
    name: IdStr,
    parent_refcount: [*c]c.gint,
    len: c.guint,
    cap: c.guint,
    fields: [*]Field,
};

pub export var _gst_structure_type: c.GType = 0;

var type_once: gtype.Once = .{};
pub var debug_cat: [*c]c.GstDebugCategory = null;

pub export fn gst_structure_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstStructure", @ptrCast(&copyOrNull), @ptrCast(&gst_structure_free));
        }
    }.f);
}

fn copyOrNull(s: [*c]const Structure) callconv(.c) [*c]Structure {
    return if (s != null) gst_structure_copy(s) else null;
}

fn toString(src: [*c]const Value, dst: [*c]Value) callconv(.c) void {
    if (!check.that(src != null, "gst_structure_transform_to_string", "src_value != NULL")) return;
    if (!check.that(dst != null, "gst_structure_transform_to_string", "dest_value != NULL")) return;
    dst[0].data[0].v_pointer = gst_structure_to_string(@ptrCast(@alignCast(src[0].data[0].v_pointer)));
}

fn compareValues(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x: [*c]const Structure = @ptrCast(@alignCast(c.g_value_get_boxed(a)));
    const y: [*c]const Structure = @ptrCast(@alignCast(c.g_value_get_boxed(b)));
    if (x == y) return c.GST_VALUE_EQUAL;
    if (x == null or y == null) return c.GST_VALUE_UNORDERED;
    return if (gst_structure_is_equal(x, y) != 0) c.GST_VALUE_EQUAL else c.GST_VALUE_UNORDERED;
}

fn serializeValue(v: [*c]const Value) callconv(.c) [*c]u8 {
    return @import("vbasic.zig").takeAndWrap(gst_structure_to_string(@ptrCast(@alignCast(c.g_value_get_boxed(v)))));
}

fn deserializeValue(dest: [*c]Value, text: [*c]const u8) callconv(.c) c.gboolean {
    var s: [*c]Structure = null;
    if (text[0] != '"') {
        s = gst_structure_from_string(text, null);
    } else {
        const raw = @import("vbasic.zig").unwrap(text);
        if (raw == null) return 0;
        s = gst_structure_from_string(raw, null);
        c.g_free(raw);
    }
    if (s == null) return 0;
    c.g_value_take_boxed(dest, s);
    return 1;
}

var value_table: c.GstValueTable = .{};

pub fn initialize() void {
    _gst_structure_type = gst_structure_get_type();
    c.g_value_register_transform_func(_gst_structure_type, G_TYPE_STRING, toString);
    debug_cat = @import("info.zig").newCategory("structure", 0, "GstStructure debug");
}

pub fn impl(s: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(s)));
}

pub fn fieldsOf(s: anytype) []Field {
    const i = impl(s);
    return i.fields[0..i.len];
}

fn inlineFields(i: *Impl) [*]Field {
    const base: [*]u8 = @ptrCast(i);
    return @ptrCast(@alignCast(base + @sizeOf(Impl)));
}

fn mutable(s: anytype) bool {
    const r = impl(s).parent_refcount;
    return r == null or @atomicLoad(c.gint, r, .acquire) == 1;
}

fn roundUp8(n: c.guint) c.guint {
    return (n + 7) & ~@as(c.guint, 7);
}

fn create(name: *IdStr, prealloc: c.guint) [*c]Structure {
    const n = roundUp8(@max(prealloc, 1));
    const i: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl) + n * @sizeOf(Field))));
    i.s.type = _gst_structure_type;
    i.s.name = 0;
    idstr.gst_id_str_move(&i.name, name);
    i.parent_refcount = null;
    i.len = 0;
    i.cap = n;
    i.fields = inlineFields(i);
    return &i.s;
}

fn createCopyName(name: [*c]const IdStr, prealloc: c.guint) [*c]Structure {
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_copy_into(&n, name);
    return create(&n, prealloc);
}

fn createDupName(name: [*c]const u8, prealloc: c.guint) [*c]Structure {
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set(&n, name);
    return create(&n, prealloc);
}

fn createStaticName(name: [*c]const u8, prealloc: c.guint) [*c]Structure {
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&n, name);
    return create(&n, prealloc);
}

fn push(s: [*c]Structure, f: *const Field) void {
    const i = impl(s);
    if (i.len == i.cap) {
        if (i.cap > std.math.maxInt(c.guint) / 2) c.g_log("GStreamer", c.G_LOG_LEVEL_ERROR, "Growing structure would result in overflow");
        const want = @max(roundUp8(i.len + 1), i.cap * 2);
        if (i.fields == inlineFields(i)) {
            const grown: [*]Field = @ptrCast(@alignCast(c.g_malloc0(want * @sizeOf(Field))));
            @memcpy(grown[0..i.len], i.fields[0..i.len]);
            i.fields = grown;
        } else i.fields = @ptrCast(@alignCast(c.g_realloc(i.fields, want * @sizeOf(Field))));
        i.cap = want;
    }
    i.fields[i.len] = f.*;
    i.len += 1;
}

fn removeAt(s: [*c]Structure, at: usize) void {
    const i = impl(s);
    if (at >= i.len) return;
    std.mem.copyForwards(Field, i.fields[at .. i.len - 1], i.fields[at + 1 .. i.len]);
    i.len -= 1;
}

pub fn validName(name: [*c]const u8) bool {
    if (!check.that(name != null, "gst_structure_validate_name", "name != NULL")) return false;
    if (!std.ascii.isAlphabetic(name[0])) return false;
    var p = name + 1;
    while (p[0] != 0 and (std.ascii.isAlphanumeric(p[0]) or std.mem.indexOfScalar(u8, "/-_.:+", p[0]) != null)) p += 1;
    if (p[0] != 0) return false;
    const n = std.mem.span(name);
    if (std.mem.startsWith(u8, n, "video/x-raw-")) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "0.10-style raw video caps are being created. Should be video/x-raw,format=(string).. now.");
    } else if (std.mem.startsWith(u8, n, "audio/x-raw-")) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "0.10-style raw audio caps are being created. Should be audio/x-raw,format=(string).. now.");
    }
    return true;
}

fn isTaglist(s: anytype) bool {
    const raw: *const [16]u8 = @ptrCast(&impl(s).name);
    return raw[15] == 0 and std.mem.eql(u8, raw[0..8], "taglist\x00");
}

fn acceptable(s: anytype, name: [*c]const u8, v: *const Value) bool {
    const tags = isTaglist(s);
    if (v.g_type == G_TYPE_STRING) {
        const str = c.g_value_get_string(v);
        if (tags and (str == null or str[0] == 0)) return false;
        if (str != null and c.g_utf8_validate(str, -1, null) == 0) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Trying to set string on %s field '%s', but string is not valid UTF-8. Please file a bug.", @as([*c]const u8, if (tags) "taglist" else "structure"), name);
            return false;
        }
    } else if (v.g_type == c.g_date_get_type()) {
        const d: ?*const c.GDate = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
        if (tags and d == null) return false;
        if (d != null and c.g_date_valid(d) == 0) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Trying to set invalid GDate on %s field '%s'. Please file a bug.", @as([*c]const u8, if (tags) "taglist" else "structure"), name);
            return false;
        }
    }
    return true;
}

pub fn putField(s: [*c]Structure, f: *Field) void {
    if (!acceptable(s, idstr.gst_id_str_as_str(&f.name), &f.value)) {
        c.g_value_unset(&f.value);
        return;
    }
    for (fieldsOf(s)) |*existing| {
        if (idstr.gst_id_str_is_equal(&existing.name, &f.name) != 0) {
            c.g_value_unset(&existing.value);
            existing.value = f.value;
            idstr.gst_id_str_clear(&f.name);
            return;
        }
    }
    push(s, f);
}

pub fn lookupId(s: anytype, name: [*c]const IdStr) ?*Field {
    for (fieldsOf(s)) |*f| if (idstr.gst_id_str_is_equal(&f.name, name) != 0) return f;
    return null;
}

pub fn lookup(s: anytype, name: [*c]const u8) ?*Field {
    var key = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&key, name);
    return lookupId(s, &key);
}

fn setCopy(s: [*c]Structure, name: *IdStr, v: [*c]const Value) void {
    var f = std.mem.zeroes(Field);
    idstr.gst_id_str_move(&f.name, name);
    value.gst_value_init_and_copy(&f.value, v);
    putField(s, &f);
}

fn setTake(s: [*c]Structure, name: *IdStr, v: [*c]Value) void {
    var f = std.mem.zeroes(Field);
    idstr.gst_id_str_move(&f.name, name);
    f.value = v.*;
    putField(s, &f);
    v.*.g_type = 0;
}

fn isValue(v: [*c]const Value) bool {
    return v != null and v.*.g_type != 0;
}

pub export fn gst_structure_new_id_empty(quark: c.GQuark) [*c]Structure {
    if (!check.that(quark != 0, "gst_structure_new_id_empty", "quark != 0")) return null;
    return createStaticName(c.g_quark_to_string(quark), 0);
}

pub export fn gst_structure_new_id_str_empty(name: [*c]const IdStr) [*c]Structure {
    if (!check.that(name != null, "gst_structure_new_id_str_empty", "name != 0")) return null;
    if (!check.that(validName(idstr.gst_id_str_as_str(name)), "gst_structure_new_id_str_empty", "gst_structure_validate_name (gst_id_str_as_str (name))")) return null;
    return createCopyName(name, 0);
}

pub export fn gst_structure_new_empty(name: [*c]const u8) [*c]Structure {
    if (!check.that(validName(name), "gst_structure_new_empty", "gst_structure_validate_name (name)")) return null;
    return createDupName(name, 0);
}

pub export fn gst_structure_new_static_str_empty(name: [*c]const u8) [*c]Structure {
    if (!check.that(validName(name), "gst_structure_new_static_str_empty", "gst_structure_validate_name (name)")) return null;
    return createStaticName(name, 0);
}

fn countFields(comptime Key: type, first: Key, ap: *va.VaList) callconv(.c) c.guint {
    var copy = @cVaCopy(ap);
    defer @cVaEnd(&copy);
    var n: c.guint = 0;
    var key = first;
    while (key != 0) {
        va.skip(@cVaArg(&copy, c.GType), &copy);
        key = @cVaArg(&copy, Key);
        n += 1;
    }
    return n;
}

fn countPtr(first: c.gpointer, ap: *va.VaList) callconv(.c) c.guint {
    var copy = @cVaCopy(ap);
    defer @cVaEnd(&copy);
    var n: c.guint = 0;
    var key = first;
    while (key != null) {
        va.skip(@cVaArg(&copy, c.GType), &copy);
        key = @cVaArg(&copy, c.gpointer);
        n += 1;
    }
    return n;
}

fn countQuark(first: c.GQuark, ap: *va.VaList) callconv(.c) c.guint {
    var copy = @cVaCopy(ap);
    defer @cVaEnd(&copy);
    var n: c.guint = 0;
    var key = first;
    while (key != 0) {
        va.skip(@cVaArg(&copy, c.GType), &copy);
        key = @cVaArg(&copy, c.GQuark);
        n += 1;
    }
    return n;
}

const KeyKind = enum(c_int) { dup, static, id_str, quark };

fn setList(s: [*c]Structure, kind: KeyKind, first: c.gpointer, ap: *va.VaList) callconv(.c) void {
    var key: c.gpointer = first;
    while (key != null) {
        var f = std.mem.zeroes(Field);
        switch (kind) {
            .dup => idstr.gst_id_str_set(&f.name, @ptrCast(key)),
            .static => idstr.gst_id_str_set_static_str(&f.name, @ptrCast(key)),
            .id_str => idstr.gst_id_str_copy_into(&f.name, @ptrCast(@alignCast(key))),
            .quark => idstr.gst_id_str_set_static_str(&f.name, c.g_quark_to_string(@intCast(@intFromPtr(key)))),
        }
        const t = @cVaArg(ap, c.GType);
        const err = va.collect(&f.value, t, ap);
        if (err != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "%s", err);
            c.g_free(err);
            idstr.gst_id_str_clear(&f.name);
            return;
        }
        putField(s, &f);
        key = if (kind == .quark) @ptrFromInt(@as(usize, @cVaArg(ap, c.GQuark))) else @cVaArg(ap, c.gpointer);
    }
}

pub export fn gst_structure_new_valist(name: [*c]const u8, first: [*c]const u8, ap: va.CVaList) [*c]Structure {
    if (!check.that(validName(name), "gst_structure_new_valist", "gst_structure_validate_name (name)")) return null;
    const list = va.fromC(ap);
    const s = createDupName(name, countPtr(@constCast(first), list));
    setList(s, .dup, @constCast(first), list);
    return s;
}

pub export fn gst_structure_new_static_str_valist(name: [*c]const u8, first: [*c]const u8, ap: va.CVaList) [*c]Structure {
    if (!check.that(validName(name), "gst_structure_new_static_str_valist", "gst_structure_validate_name (name)")) return null;
    const list = va.fromC(ap);
    const s = createStaticName(name, countPtr(@constCast(first), list));
    setList(s, .static, @constCast(first), list);
    return s;
}

pub export fn gst_structure_new_id_str_valist(name: [*c]const IdStr, first: [*c]const IdStr, ap: va.CVaList) [*c]Structure {
    if (!check.that(validName(idstr.gst_id_str_as_str(name)), "gst_structure_new_id_str_valist", "gst_structure_validate_name (gst_id_str_as_str (name))")) return null;
    const list = va.fromC(ap);
    const s = createCopyName(name, countPtr(@constCast(first), list));
    setList(s, .id_str, @constCast(first), list);
    return s;
}

pub export fn gst_structure_new(name: [*c]const u8, first: [*c]const u8, ...) callconv(.c) [*c]Structure {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    if (!check.that(validName(name), "gst_structure_new_valist", "gst_structure_validate_name (name)")) return null;
    const s = createDupName(name, countPtr(@constCast(first), &ap));
    setList(s, .dup, @constCast(first), &ap);
    return s;
}

pub export fn gst_structure_new_static_str(name: [*c]const u8, first: [*c]const u8, ...) callconv(.c) [*c]Structure {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    if (!check.that(validName(name), "gst_structure_new_static_str_valist", "gst_structure_validate_name (name)")) return null;
    const s = createStaticName(name, countPtr(@constCast(first), &ap));
    setList(s, .static, @constCast(first), &ap);
    return s;
}

pub export fn gst_structure_new_id(name: c.GQuark, first: c.GQuark, ...) callconv(.c) [*c]Structure {
    if (!check.that(name != 0, "gst_structure_new_id", "name_quark != 0")) return null;
    if (!check.that(first != 0, "gst_structure_new_id", "field_quark != 0")) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const s = createStaticName(c.g_quark_to_string(name), countQuark(first, &ap));
    setList(s, .quark, @ptrFromInt(@as(usize, first)), &ap);
    return s;
}

pub export fn gst_structure_new_id_str(name: [*c]const IdStr, first: [*c]const IdStr, ...) callconv(.c) [*c]Structure {
    const func = "gst_structure_new_id_str";
    if (!check.that(name != null, func, "name != 0")) return null;
    if (!check.that(validName(idstr.gst_id_str_as_str(name)), func, "gst_structure_validate_name (gst_id_str_as_str (name))")) return null;
    if (!check.that(first != null, func, "fieldname != NULL")) return null;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const s = createCopyName(name, countPtr(@constCast(first), &ap));
    setList(s, .id_str, @constCast(first), &ap);
    return s;
}

pub export fn gst_structure_set_parent_refcount(s: [*c]Structure, refcount: [*c]c.gint) c.gboolean {
    const func = "gst_structure_set_parent_refcount";
    if (!check.that(s != null, func, "structure != NULL")) return 0;
    if (impl(s).parent_refcount != null) {
        if (refcount != null) {
            check.fail(func, "refcount == NULL");
            return 0;
        }
    } else if (refcount == null) {
        check.fail(func, "refcount != NULL");
        return 0;
    }
    impl(s).parent_refcount = refcount;
    return 1;
}

pub export fn gst_structure_copy(s: [*c]const Structure) [*c]Structure {
    if (!check.that(s != null, "gst_structure_copy", "structure != NULL")) return null;
    const out = createCopyName(&impl(s).name, impl(s).len);
    for (fieldsOf(s)) |*f| {
        var nf = std.mem.zeroes(Field);
        idstr.gst_id_str_copy_into(&nf.name, &f.name);
        value.gst_value_init_and_copy(&nf.value, &f.value);
        push(out, &nf);
    }
    return out;
}

pub export fn gst_structure_free(s: [*c]Structure) void {
    if (!check.that(s != null, "gst_structure_free", "structure != NULL")) return;
    if (!check.that(impl(s).parent_refcount == null, "gst_structure_free", "GST_STRUCTURE_REFCOUNT (structure) == NULL")) return;
    const i = impl(s);
    for (fieldsOf(s)) |*f| {
        if (isValue(&f.value)) c.g_value_unset(&f.value);
        idstr.gst_id_str_clear(&f.name);
    }
    if (i.fields != inlineFields(i)) c.g_free(i.fields);
    idstr.gst_id_str_clear(&i.name);
    c.g_free(i);
}

pub export fn gst_clear_structure(slot: [*c][*c]Structure) void {
    const s = slot.*;
    if (s != null) {
        slot.* = null;
        gst_structure_free(s);
    }
}

pub export fn gst_structure_take(slot: [*c][*c]Structure, new: [*c]Structure) c.gboolean {
    if (!check.that(slot != null, "gst_structure_take", "oldstr_ptr != NULL")) return 0;
    const p: *?*Structure = @ptrCast(slot);
    const want: ?*Structure = @ptrCast(new);
    var old = @atomicLoad(?*Structure, p, .acquire);
    while (true) {
        if (old == want) {
            _ = check.that(want == null, "gst_structure_take", "newstr == NULL");
            return 0;
        }
        old = @cmpxchgWeak(?*Structure, p, old, want, .acq_rel, .acquire) orelse break;
    }
    if (old) |o| gst_structure_free(o);
    return 1;
}

pub export fn gst_structure_get_name(s: [*c]const Structure) [*c]const u8 {
    if (!check.that(s != null, "gst_structure_get_name", "structure != NULL")) return null;
    return idstr.gst_id_str_as_str(&impl(s).name);
}

pub export fn gst_structure_has_name(s: [*c]const Structure, name: [*c]const u8) c.gboolean {
    if (!check.that(s != null, "gst_structure_has_name", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_has_name", "name != NULL")) return 0;
    return idstr.gst_id_str_is_equal_to_str(&impl(s).name, name);
}

pub export fn gst_structure_get_name_id(s: [*c]const Structure) c.GQuark {
    if (!check.that(s != null, "gst_structure_get_name_id", "structure != NULL")) return 0;
    return c.g_quark_from_string(idstr.gst_id_str_as_str(&impl(s).name));
}

pub export fn gst_structure_get_name_id_str(s: [*c]const Structure) [*c]const IdStr {
    if (!check.that(s != null, "gst_structure_get_name_id_str", "structure != NULL")) return null;
    return &impl(s).name;
}

fn checkRename(comptime func: []const u8, s: [*c]Structure, name: [*c]const u8) bool {
    if (!check.that(s != null, func, "structure != NULL")) return false;
    if (!check.that(mutable(s), func, "IS_MUTABLE (structure)")) return false;
    return check.that(validName(name), func, "gst_structure_validate_name (name)");
}

pub export fn gst_structure_set_name_id_str(s: [*c]Structure, name: [*c]const IdStr) void {
    const func = "gst_structure_set_name_id_str";
    if (!check.that(s != null, func, "structure != NULL")) return;
    if (!check.that(mutable(s), func, "IS_MUTABLE (structure)")) return;
    if (!check.that(validName(idstr.gst_id_str_as_str(name)), func, "gst_structure_validate_name (gst_id_str_as_str (name))")) return;
    idstr.gst_id_str_copy_into(&impl(s).name, name);
}

pub export fn gst_structure_set_name(s: [*c]Structure, name: [*c]const u8) void {
    if (!checkRename("gst_structure_set_name", s, name)) return;
    idstr.gst_id_str_set(&impl(s).name, name);
}

pub export fn gst_structure_set_name_static_str(s: [*c]Structure, name: [*c]const u8) void {
    if (!checkRename("gst_structure_set_name_static_str", s, name)) return;
    idstr.gst_id_str_set_static_str(&impl(s).name, name);
}

fn checkSet(comptime func: []const u8, s: [*c]Structure, v: [*c]const Value) bool {
    if (!check.that(s != null, func, "structure != NULL")) return false;
    if (!check.that(isValue(v), func, "G_IS_VALUE (value)")) return false;
    return check.that(mutable(s), func, "IS_MUTABLE (structure)");
}

fn checkSetNamed(comptime func: []const u8, s: [*c]Structure, name: anytype, v: [*c]const Value) bool {
    if (!check.that(s != null, func, "structure != NULL")) return false;
    if (!check.that(name != null, func, "fieldname != NULL")) return false;
    if (!check.that(isValue(v), func, "G_IS_VALUE (value)")) return false;
    return check.that(mutable(s), func, "IS_MUTABLE (structure)");
}

pub export fn gst_structure_id_set_value(s: [*c]Structure, field: c.GQuark, v: [*c]const Value) void {
    if (!checkSet("gst_structure_id_set_value", s, v)) return;
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&n, c.g_quark_to_string(field));
    setCopy(s, &n, v);
}

pub export fn gst_structure_set_value(s: [*c]Structure, name: [*c]const u8, v: [*c]const Value) void {
    if (!checkSetNamed("gst_structure_set_value", s, name, v)) return;
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set(&n, name);
    setCopy(s, &n, v);
}

pub export fn gst_structure_set_value_static_str(s: [*c]Structure, name: [*c]const u8, v: [*c]const Value) void {
    if (!checkSetNamed("gst_structure_set_value_static_str", s, name, v)) return;
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&n, name);
    setCopy(s, &n, v);
}

pub export fn gst_structure_id_str_set_value(s: [*c]Structure, name: [*c]const IdStr, v: [*c]const Value) void {
    if (!checkSetNamed("gst_structure_id_str_set_value", s, name, v)) return;
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_copy_into(&n, name);
    setCopy(s, &n, v);
}

pub export fn gst_structure_id_take_value(s: [*c]Structure, field: c.GQuark, v: [*c]Value) void {
    if (!checkSet("gst_structure_id_take_value", s, v)) return;
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&n, c.g_quark_to_string(field));
    setTake(s, &n, v);
}

pub export fn gst_structure_take_value(s: [*c]Structure, name: [*c]const u8, v: [*c]Value) void {
    if (!checkSetNamed("gst_structure_take_value", s, name, v)) return;
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set(&n, name);
    setTake(s, &n, v);
}

pub export fn gst_structure_take_value_static_str(s: [*c]Structure, name: [*c]const u8, v: [*c]Value) void {
    if (!checkSetNamed("gst_structure_take_value_static_str", s, name, v)) return;
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_set_static_str(&n, name);
    setTake(s, &n, v);
}

pub export fn gst_structure_id_str_take_value(s: [*c]Structure, name: [*c]const IdStr, v: [*c]Value) void {
    if (!checkSet("gst_structure_id_str_take_value", s, v)) return;
    var n = std.mem.zeroes(IdStr);
    idstr.gst_id_str_copy_into(&n, name);
    setTake(s, &n, v);
}

pub export fn gst_structure_set(s: [*c]Structure, field: [*c]const u8, ...) callconv(.c) void {
    if (!check.that(s != null, "gst_structure_set", "structure != NULL")) return;
    if (!check.that(mutable(s) or field == null, "gst_structure_set", "IS_MUTABLE (structure) || field == NULL")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    setList(s, .dup, @constCast(field), &ap);
}

pub export fn gst_structure_set_static_str(s: [*c]Structure, field: [*c]const u8, ...) callconv(.c) void {
    if (!check.that(s != null, "gst_structure_set_static_str", "structure != NULL")) return;
    if (!check.that(mutable(s) or field == null, "gst_structure_set_static_str", "IS_MUTABLE (structure) || field == NULL")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    setList(s, .static, @constCast(field), &ap);
}

pub export fn gst_structure_set_valist(s: [*c]Structure, field: [*c]const u8, ap: va.CVaList) void {
    if (!check.that(s != null, "gst_structure_set_valist", "structure != NULL")) return;
    if (!check.that(mutable(s), "gst_structure_set_valist", "IS_MUTABLE (structure)")) return;
    setList(s, .dup, @constCast(field), va.fromC(ap));
}

pub export fn gst_structure_set_static_str_valist(s: [*c]Structure, field: [*c]const u8, ap: va.CVaList) void {
    if (!check.that(s != null, "gst_structure_set_static_str_valist", "structure != NULL")) return;
    if (!check.that(mutable(s), "gst_structure_set_static_str_valist", "IS_MUTABLE (structure)")) return;
    setList(s, .static, @constCast(field), va.fromC(ap));
}

pub export fn gst_structure_id_set(s: [*c]Structure, field: c.GQuark, ...) callconv(.c) void {
    if (!check.that(s != null, "gst_structure_id_set", "structure != NULL")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    setList(s, .quark, @ptrFromInt(@as(usize, field)), &ap);
}

pub export fn gst_structure_id_set_valist(s: [*c]Structure, field: c.GQuark, ap: va.CVaList) void {
    if (!check.that(s != null, "gst_structure_id_set_valist", "structure != NULL")) return;
    if (!check.that(mutable(s), "gst_structure_id_set_valist", "IS_MUTABLE (structure)")) return;
    setList(s, .quark, @ptrFromInt(@as(usize, field)), va.fromC(ap));
}

pub export fn gst_structure_id_str_set(s: [*c]Structure, field: [*c]const IdStr, ...) callconv(.c) void {
    if (!check.that(s != null, "gst_structure_id_str_set", "structure != NULL")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    setList(s, .id_str, @constCast(field), &ap);
}

pub export fn gst_structure_id_str_set_valist(s: [*c]Structure, field: [*c]const IdStr, ap: va.CVaList) void {
    if (!check.that(s != null, "gst_structure_id_str_set_valist", "structure != NULL")) return;
    if (!check.that(mutable(s), "gst_structure_id_str_set_valist", "IS_MUTABLE (structure)")) return;
    setList(s, .id_str, @constCast(field), va.fromC(ap));
}

pub export fn gst_structure_get_value(s: [*c]const Structure, name: [*c]const u8) [*c]const Value {
    if (!check.that(s != null, "gst_structure_get_value", "structure != NULL")) return null;
    if (!check.that(name != null, "gst_structure_get_value", "fieldname != NULL")) return null;
    const f = lookup(s, name) orelse return null;
    return &f.value;
}

pub export fn gst_structure_id_str_get_value(s: [*c]const Structure, name: [*c]const IdStr) [*c]const Value {
    if (!check.that(s != null, "gst_structure_id_str_get_value", "structure != NULL")) return null;
    if (!check.that(name != null, "gst_structure_id_str_get_value", "fieldname != NULL")) return null;
    const f = lookupId(s, name) orelse return null;
    return &f.value;
}

pub export fn gst_structure_id_get_value(s: [*c]const Structure, field: c.GQuark) [*c]const Value {
    if (!check.that(s != null, "gst_structure_id_get_value", "structure != NULL")) return null;
    const f = lookup(s, c.g_quark_to_string(field)) orelse return null;
    return &f.value;
}

fn dropField(s: [*c]Structure, f: *Field) void {
    if (isValue(&f.value)) c.g_value_unset(&f.value);
    idstr.gst_id_str_clear(&f.name);
    removeAt(s, (@intFromPtr(f) - @intFromPtr(impl(s).fields)) / @sizeOf(Field));
}

pub export fn gst_structure_remove_field(s: [*c]Structure, name: [*c]const u8) void {
    const func = "gst_structure_remove_field";
    if (!check.that(s != null, func, "structure != NULL")) return;
    if (!check.that(name != null, func, "fieldname != NULL")) return;
    if (!check.that(mutable(s), func, "IS_MUTABLE (structure)")) return;
    if (lookup(s, name)) |f| dropField(s, f);
}

pub export fn gst_structure_id_str_remove_field(s: [*c]Structure, name: [*c]const IdStr) void {
    const func = "gst_structure_id_str_remove_field";
    if (!check.that(s != null, func, "structure != NULL")) return;
    if (!check.that(name != null, func, "fieldname != NULL")) return;
    if (!check.that(mutable(s), func, "IS_MUTABLE (structure)")) return;
    if (lookupId(s, name)) |f| dropField(s, f);
}

pub export fn gst_structure_remove_fields_valist(s: [*c]Structure, first: [*c]const u8, ap: va.CVaList) void {
    if (!check.that(s != null, "gst_structure_remove_fields_valist", "structure != NULL")) return;
    if (!check.that(first != null, "gst_structure_remove_fields_valist", "fieldname != NULL")) return;
    removeNames(s, first, va.fromC(ap));
}

fn removeNames(s: [*c]Structure, first: [*c]const u8, ap: *va.VaList) callconv(.c) void {
    var name = first;
    while (name != null) {
        gst_structure_remove_field(s, name);
        name = @cVaArg(ap, [*c]const u8);
    }
}

fn removeIdNames(s: [*c]Structure, first: [*c]const IdStr, ap: *va.VaList) callconv(.c) void {
    var name = first;
    while (name != null) {
        gst_structure_id_str_remove_field(s, name);
        name = @cVaArg(ap, [*c]const IdStr);
    }
}

pub export fn gst_structure_remove_fields(s: [*c]Structure, first: [*c]const u8, ...) callconv(.c) void {
    if (!check.that(s != null, "gst_structure_remove_fields", "structure != NULL")) return;
    if (!check.that(first != null, "gst_structure_remove_fields", "fieldname != NULL")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    removeNames(s, first, &ap);
}

pub export fn gst_structure_id_str_remove_fields_valist(s: [*c]Structure, first: [*c]const IdStr, ap: va.CVaList) void {
    if (!check.that(s != null, "gst_structure_id_str_remove_fields_valist", "structure != NULL")) return;
    if (!check.that(first != null, "gst_structure_id_str_remove_fields_valist", "fieldname != NULL")) return;
    removeIdNames(s, first, va.fromC(ap));
}

pub export fn gst_structure_id_str_remove_fields(s: [*c]Structure, first: [*c]const IdStr, ...) callconv(.c) void {
    if (!check.that(s != null, "gst_structure_id_str_remove_fields", "structure != NULL")) return;
    if (!check.that(first != null, "gst_structure_id_str_remove_fields", "fieldname != NULL")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    removeIdNames(s, first, &ap);
}

pub export fn gst_structure_remove_all_fields(s: [*c]Structure) void {
    if (!check.that(s != null, "gst_structure_remove_all_fields", "structure != NULL")) return;
    if (!check.that(mutable(s), "gst_structure_remove_all_fields", "IS_MUTABLE (structure)")) return;
    while (impl(s).len > 0) dropField(s, &impl(s).fields[impl(s).len - 1]);
}

pub export fn gst_structure_get_field_type(s: [*c]const Structure, name: [*c]const u8) c.GType {
    if (!check.that(s != null, "gst_structure_get_field_type", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_get_field_type", "fieldname != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    return f.value.g_type;
}

pub export fn gst_structure_id_str_get_field_type(s: [*c]const Structure, name: [*c]const IdStr) c.GType {
    if (!check.that(s != null, "gst_structure_id_str_get_field_type", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_id_str_get_field_type", "fieldname != NULL")) return 0;
    const f = lookupId(s, name) orelse return 0;
    return f.value.g_type;
}

pub export fn gst_structure_n_fields(s: [*c]const Structure) c.gint {
    if (!check.that(s != null, "gst_structure_n_fields", "structure != NULL")) return 0;
    return @intCast(impl(s).len);
}

pub export fn gst_structure_nth_field_name(s: [*c]const Structure, index: c.guint) [*c]const u8 {
    if (!check.that(s != null, "gst_structure_nth_field_name", "structure != NULL")) return null;
    if (!check.that(index < impl(s).len, "gst_structure_nth_field_name", "index < GST_STRUCTURE_LEN (structure)")) return null;
    return idstr.gst_id_str_as_str(&impl(s).fields[index].name);
}

pub export fn gst_structure_id_str_nth_field_name(s: [*c]const Structure, index: c.guint) [*c]const IdStr {
    if (!check.that(s != null, "gst_structure_id_str_nth_field_name", "structure != NULL")) return null;
    if (!check.that(index < impl(s).len, "gst_structure_id_str_nth_field_name", "index < GST_STRUCTURE_LEN (structure)")) return null;
    return &impl(s).fields[index].name;
}

const QuarkAdapter = struct {
    func: ?*const fn (c.GQuark, [*c]Value, c.gpointer) callconv(.c) c.gboolean,
    data: c.gpointer,

    fn call(name: [*c]const IdStr, v: [*c]Value, p: c.gpointer) callconv(.c) c.gboolean {
        const self: *QuarkAdapter = @ptrCast(@alignCast(p));
        return self.func.?(c.g_quark_from_string(idstr.gst_id_str_as_str(name)), v, self.data);
    }
};

pub export fn gst_structure_foreach(s: [*c]const Structure, func: c.GstStructureForeachFunc, data: c.gpointer) c.gboolean {
    var a = QuarkAdapter{ .func = @ptrCast(func), .data = data };
    return gst_structure_foreach_id_str(s, @ptrCast(&QuarkAdapter.call), &a);
}

pub export fn gst_structure_map_in_place(s: [*c]Structure, func: c.GstStructureMapFunc, data: c.gpointer) c.gboolean {
    var a = QuarkAdapter{ .func = @ptrCast(func), .data = data };
    return gst_structure_map_in_place_id_str(s, QuarkAdapter.call, &a);
}

pub export fn gst_structure_filter_and_map_in_place(s: [*c]Structure, func: c.GstStructureFilterMapFunc, data: c.gpointer) void {
    var a = QuarkAdapter{ .func = @ptrCast(func), .data = data };
    gst_structure_filter_and_map_in_place_id_str(s, QuarkAdapter.call, &a);
}

pub export fn gst_structure_foreach_id_str(s: [*c]const Structure, func: c.GstStructureForeachIdStrFunc, data: c.gpointer) c.gboolean {
    if (!check.that(s != null, "gst_structure_foreach_id_str", "structure != NULL")) return 0;
    if (!check.that(func != null, "gst_structure_foreach_id_str", "func != NULL")) return 0;
    var i: usize = 0;
    while (i < impl(s).len) : (i += 1) {
        const f = &impl(s).fields[i];
        if (func.?(&f.name, &f.value, data) == 0) return 0;
    }
    return 1;
}

pub export fn gst_structure_map_in_place_id_str(s: [*c]Structure, func: c.GstStructureMapIdStrFunc, data: c.gpointer) c.gboolean {
    if (!check.that(s != null, "gst_structure_map_in_place_id_str", "structure != NULL")) return 0;
    if (!check.that(mutable(s), "gst_structure_map_in_place_id_str", "IS_MUTABLE (structure)")) return 0;
    if (!check.that(func != null, "gst_structure_map_in_place_id_str", "func != NULL")) return 0;
    var i: usize = 0;
    while (i < impl(s).len) : (i += 1) {
        const f = &impl(s).fields[i];
        if (func.?(&f.name, &f.value, data) == 0) return 0;
    }
    return 1;
}

pub export fn gst_structure_filter_and_map_in_place_id_str(s: [*c]Structure, func: c.GstStructureFilterMapIdStrFunc, data: c.gpointer) void {
    if (!check.that(s != null, "gst_structure_filter_and_map_in_place_id_str", "structure != NULL")) return;
    if (!check.that(mutable(s), "gst_structure_filter_and_map_in_place_id_str", "IS_MUTABLE (structure)")) return;
    if (!check.that(func != null, "gst_structure_filter_and_map_in_place_id_str", "func != NULL")) return;
    var i: usize = 0;
    while (i < impl(s).len) {
        const f = &impl(s).fields[i];
        if (func.?(&f.name, &f.value, data) == 0) dropField(s, f) else i += 1;
    }
}

pub export fn gst_structure_id_str_has_field(s: [*c]const Structure, name: [*c]const IdStr) c.gboolean {
    if (!check.that(s != null, "gst_structure_id_str_has_field", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_id_str_has_field", "fieldname != NULL")) return 0;
    return @intFromBool(lookupId(s, name) != null);
}

pub export fn gst_structure_id_has_field(s: [*c]const Structure, field: c.GQuark) c.gboolean {
    if (!check.that(s != null, "gst_structure_id_has_field", "structure != NULL")) return 0;
    if (!check.that(field != 0, "gst_structure_id_has_field", "field != 0")) return 0;
    return @intFromBool(lookup(s, c.g_quark_to_string(field)) != null);
}

pub export fn gst_structure_has_field(s: [*c]const Structure, name: [*c]const u8) c.gboolean {
    if (!check.that(s != null, "gst_structure_has_field", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_has_field", "fieldname != NULL")) return 0;
    return @intFromBool(lookup(s, name) != null);
}

pub export fn gst_structure_id_str_has_field_typed(s: [*c]const Structure, name: [*c]const IdStr, t: c.GType) c.gboolean {
    if (!check.that(s != null, "gst_structure_id_str_has_field_typed", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_id_str_has_field_typed", "fieldname != NULL")) return 0;
    const f = lookupId(s, name) orelse return 0;
    return @intFromBool(f.value.g_type == t);
}

pub export fn gst_structure_id_has_field_typed(s: [*c]const Structure, field: c.GQuark, t: c.GType) c.gboolean {
    if (!check.that(s != null, "gst_structure_id_has_field_typed", "structure != NULL")) return 0;
    if (!check.that(field != 0, "gst_structure_id_has_field_typed", "field != 0")) return 0;
    const f = lookup(s, c.g_quark_to_string(field)) orelse return 0;
    return @intFromBool(f.value.g_type == t);
}

pub export fn gst_structure_has_field_typed(s: [*c]const Structure, name: [*c]const u8, t: c.GType) c.gboolean {
    if (!check.that(s != null, "gst_structure_has_field_typed", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_has_field_typed", "fieldname != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    return @intFromBool(f.value.g_type == t);
}

fn typed(comptime func: []const u8, s: [*c]const Structure, name: [*c]const u8, out: anytype, t: c.GType) ?*Field {
    if (!check.that(s != null, func, "structure != NULL")) return null;
    if (!check.that(name != null, func, "fieldname != NULL")) return null;
    if (!check.that(out != null, func, "value != NULL")) return null;
    const f = lookup(s, name) orelse return null;
    return if (f.value.g_type == t) f else null;
}

pub export fn gst_structure_get_boolean(s: [*c]const Structure, name: [*c]const u8, out: [*c]c.gboolean) c.gboolean {
    if (!check.that(s != null, "gst_structure_get_boolean", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_get_boolean", "fieldname != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    if (f.value.g_type != G_TYPE_BOOLEAN) return 0;
    out.* = f.value.data[0].v_int;
    return 1;
}

pub export fn gst_structure_get_int(s: [*c]const Structure, name: [*c]const u8, out: [*c]c.gint) c.gboolean {
    const f = typed("gst_structure_get_int", s, name, out, G_TYPE_INT) orelse return 0;
    out.* = f.value.data[0].v_int;
    return 1;
}

pub export fn gst_structure_get_uint(s: [*c]const Structure, name: [*c]const u8, out: [*c]c.guint) c.gboolean {
    const f = typed("gst_structure_get_uint", s, name, out, G_TYPE_UINT) orelse return 0;
    out.* = f.value.data[0].v_uint;
    return 1;
}

pub export fn gst_structure_get_int64(s: [*c]const Structure, name: [*c]const u8, out: [*c]c.gint64) c.gboolean {
    const f = typed("gst_structure_get_int64", s, name, out, G_TYPE_INT64) orelse return 0;
    out.* = f.value.data[0].v_int64;
    return 1;
}

pub export fn gst_structure_get_uint64(s: [*c]const Structure, name: [*c]const u8, out: [*c]c.guint64) c.gboolean {
    const f = typed("gst_structure_get_uint64", s, name, out, G_TYPE_UINT64) orelse return 0;
    out.* = f.value.data[0].v_uint64;
    return 1;
}

pub export fn gst_structure_get_double(s: [*c]const Structure, name: [*c]const u8, out: [*c]c.gdouble) c.gboolean {
    const f = typed("gst_structure_get_double", s, name, out, G_TYPE_DOUBLE) orelse return 0;
    out.* = f.value.data[0].v_double;
    return 1;
}

pub export fn gst_structure_get_clock_time(s: [*c]const Structure, name: [*c]const u8, out: [*c]c.GstClockTime) c.gboolean {
    return gst_structure_get_uint64(s, name, out);
}

pub export fn gst_structure_get_date(s: [*c]const Structure, name: [*c]const u8, out: [*c]?*c.GDate) c.gboolean {
    const f = typed("gst_structure_get_date", s, name, out, c.g_date_get_type()) orelse return 0;
    out.* = @ptrCast(@alignCast(c.g_value_dup_boxed(&f.value)));
    return 1;
}

pub export fn gst_structure_get_date_time(s: [*c]const Structure, name: [*c]const u8, out: [*c]?*c.GstDateTime) c.gboolean {
    const func = "gst_structure_get_date_time";
    if (!check.that(s != null, func, "structure != NULL")) return 0;
    if (!check.that(name != null, func, "fieldname != NULL")) return 0;
    if (!check.that(out != null, func, "value != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    if (f.value.g_type != c.gst_date_time_get_type()) return 0;
    out.* = @ptrCast(@alignCast(c.g_value_dup_boxed(&f.value)));
    return 1;
}

pub export fn gst_structure_get_string(s: [*c]const Structure, name: [*c]const u8) [*c]const u8 {
    if (!check.that(s != null, "gst_structure_get_string", "structure != NULL")) return null;
    if (!check.that(name != null, "gst_structure_get_string", "fieldname != NULL")) return null;
    const f = lookup(s, name) orelse return null;
    if (f.value.g_type != G_TYPE_STRING) return null;
    return @ptrCast(f.value.data[0].v_pointer);
}

pub export fn gst_structure_get_enum(s: [*c]const Structure, name: [*c]const u8, t: c.GType, out: [*c]c.gint) c.gboolean {
    const func = "gst_structure_get_enum";
    if (!check.that(s != null, func, "structure != NULL")) return 0;
    if (!check.that(name != null, func, "fieldname != NULL")) return 0;
    if (!check.that(t != 0, func, "enumtype != G_TYPE_INVALID")) return 0;
    if (!check.that(out != null, func, "value != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    if (c.g_type_check_value_holds(&f.value, t) == 0) return 0;
    out.* = c.g_value_get_enum(&f.value);
    return 1;
}

pub export fn gst_structure_get_flags(s: [*c]const Structure, name: [*c]const u8, t: c.GType, out: [*c]c.guint) c.gboolean {
    const func = "gst_structure_get_flags";
    if (!check.that(s != null, func, "structure != NULL")) return 0;
    if (!check.that(name != null, func, "fieldname != NULL")) return 0;
    if (!check.that(t != 0, func, "flags_type != G_TYPE_INVALID")) return 0;
    if (!check.that(out != null, func, "value != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    if (c.g_type_check_value_holds(&f.value, t) == 0) return 0;
    out.* = c.g_value_get_flags(&f.value);
    return 1;
}

pub export fn gst_structure_get_fraction(s: [*c]const Structure, name: [*c]const u8, num: [*c]c.gint, den: [*c]c.gint) c.gboolean {
    const func = "gst_structure_get_fraction";
    if (!check.that(s != null, func, "structure != NULL")) return 0;
    if (!check.that(name != null, func, "fieldname != NULL")) return 0;
    if (!check.that(num != null, func, "value_numerator != NULL")) return 0;
    if (!check.that(den != null, func, "value_denominator != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    if (f.value.g_type != value._gst_fraction_type) return 0;
    num.* = vtypes.gst_value_get_fraction_numerator(&f.value);
    den.* = vtypes.gst_value_get_fraction_denominator(&f.value);
    return 1;
}

pub export fn gst_structure_get_flagset(s: [*c]const Structure, name: [*c]const u8, flags: [*c]c.guint, mask: [*c]c.guint) c.gboolean {
    if (!check.that(s != null, "gst_structure_get_flagset", "structure != NULL")) return 0;
    if (!check.that(name != null, "gst_structure_get_flagset", "fieldname != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    if (!value.holdsFlagSet(&f.value)) return 0;
    if (flags != null) flags.* = vtypes.gst_value_get_flagset_flags(&f.value);
    if (mask != null) mask.* = vtypes.gst_value_get_flagset_mask(&f.value);
    return 1;
}

pub export fn gst_structure_get_caps(s: [*c]const Structure, name: [*c]const u8, out: [*c][*c]const c.GstCaps) c.gboolean {
    const func = "gst_structure_get_caps";
    if (!check.that(s != null, func, "structure != NULL")) return 0;
    if (!check.that(name != null, func, "fieldname != NULL")) return 0;
    if (!check.that(out != null, func, "caps != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    if (f.value.g_type != c.gst_caps_get_type()) return 0;
    out.* = value.gst_value_get_caps(&f.value);
    return 1;
}

pub fn genericType(v: [*c]const Value) c.GType {
    const t = v.*.g_type;
    if (t == value._gst_value_list_type or t == value._gst_value_array_type) {
        const arr: *const c.GArray = @ptrCast(@alignCast(v[0].data[0].v_pointer));
        if (arr.len == 0) return G_TYPE_INT;
        const items: [*]const Value = @ptrCast(@alignCast(arr.data));
        return genericType(&items[0]);
    }
    if (t == value._gst_int_range_type) return G_TYPE_INT;
    if (t == value._gst_int64_range_type) return G_TYPE_INT64;
    if (t == value._gst_double_range_type) return G_TYPE_DOUBLE;
    if (t == value._gst_fraction_range_type) return value._gst_fraction_type;
    return t;
}

pub fn appendFields(s: [*c]const Structure, out: *c.GString, flags: c.GstSerializeFlags) bool {
    const brackets = flags & c.GST_SERIALIZE_FLAG_BACKWARD_COMPAT == 0;
    const strict = flags & c.GST_SERIALIZE_FLAG_STRICT != 0;
    const caps_type = c.gst_caps_get_type();
    for (fieldsOf(s)) |*f| {
        const vt = f.value.g_type;
        var text: [*c]u8 = null;
        if (vt == value._gst_value_array_type) {
            text = value.serializeList(&f.value, "< ", " >", false, flags);
        } else if (vt == value._gst_value_list_type) {
            text = value.serializeList(&f.value, "{ ", " }", false, flags);
        } else if (!brackets or (vt != _gst_structure_type and vt != caps_type)) {
            text = value.gst_value_serialize(&f.value);
        }
        const t = genericType(&f.value);
        _ = c.g_string_append_len(out, ", ", 2);
        _ = c.g_string_append(out, idstr.gst_id_str_as_str(&f.name));
        if (text != null and text[0] == '(') {
            _ = c.g_string_append_len(out, "=", 1);
        } else {
            _ = c.g_string_append_len(out, "=(", 2);
            _ = c.g_string_append(out, value.abbrOf(t));
            _ = c.g_string_append_c(out, ')');
        }
        if (brackets and vt == _gst_structure_type) {
            const sub = value.gst_value_get_structure(&f.value);
            _ = c.g_string_append_c(out, '[');
            _ = c.g_string_append(out, gst_structure_get_name(sub));
            if (!appendFields(sub, out, flags)) return false;
            _ = c.g_string_append_c(out, ']');
        } else if (brackets and vt == caps_type) {
            const str = c.gst_caps_serialize(value.gst_value_get_caps(&f.value), flags);
            c.g_string_append_printf(out, "[%s]", str);
            c.g_free(str);
        } else if (text != null) {
            _ = c.g_string_append(out, text);
            c.g_free(text);
            if (strict and c.g_type_check_value_holds(&f.value, G_TYPE_OBJECT) != 0) return false;
        } else if (c.g_type_check_value_holds(&f.value, G_TYPE_POINTER) != 0) {
            if (strict) return false;
            const ptr = c.g_value_get_pointer(&f.value);
            if (ptr == null) _ = c.g_string_append(out, "NULL") else c.g_string_append_printf(out, "%p", ptr);
        } else if (c.g_type_check_value_holds(&f.value, c.g_array_get_type()) != 0) {
            if (strict) return false;
            const arr: ?*const c.GArray = @ptrCast(@alignCast(c.g_value_get_boxed(&f.value)));
            if (arr) |a| c.g_string_append_printf(out, "[%d %s]", a.len, @as([*c]const u8, if (a.len == 1) "entry" else "entries")) else _ = c.g_string_append(out, "NULL");
        } else {
            if (strict) return false;
            _ = c.g_string_append(out, "NULL");
        }
    }
    _ = c.g_string_append_c(out, ';');
    return true;
}

fn serialize(s: [*c]const Structure, flags: c.GstSerializeFlags) [*c]u8 {
    if (!check.that(s != null, "structure_serialize", "structure != NULL")) return null;
    const out = c.g_string_sized_new(16 + @as(c.gsize, impl(s).len) * 22);
    _ = c.g_string_append(out, gst_structure_get_name(s));
    if (!appendFields(s, out, flags)) {
        _ = c.g_string_free(out, 1);
        return null;
    }
    return c.g_string_free(out, 0);
}

pub export fn gst_structure_to_string(s: [*c]const Structure) [*c]u8 {
    return serialize(s, c.GST_SERIALIZE_FLAG_BACKWARD_COMPAT);
}

pub export fn gst_structure_serialize(s: [*c]const Structure, flags: c.GstSerializeFlags) [*c]u8 {
    if (!check.that(flags & c.GST_SERIALIZE_FLAG_STRICT == 0, "gst_structure_serialize", "(flags & GST_SERIALIZE_FLAG_STRICT) == 0")) return null;
    return serialize(s, flags);
}

pub export fn gst_structure_serialize_full(s: [*c]const Structure, flags: c.GstSerializeFlags) [*c]u8 {
    return serialize(s, flags);
}

fn skipBlanks(p: [*c]u8) [*c]u8 {
    var r = p;
    while (r[0] != 0 and (std.ascii.isWhitespace(r[0]) or (r[0] == '\\' and std.ascii.isWhitespace(r[1])))) r += 1;
    return r;
}

fn parseField(text: [*c]u8, after: *[*c]u8, f: *Field) bool {
    var p = skipBlanks(text);
    const name = p;
    var name_end: [*c]u8 = undefined;
    if (!value.parseSimpleString(p, &name_end)) return false;
    p = skipBlanks(name_end);
    if (p[0] != '=') return false;
    p += 1;
    const saved = name_end[0];
    name_end[0] = 0;
    idstr.gst_id_str_set(&f.name, name);
    name_end[0] = saved;
    if (!value.parseValue(p, &p, &f.value, 0, null)) return false;
    after.* = p;
    return true;
}

pub fn parseName(text: [*c]u8, start: *[*c]u8, end: *[*c]u8, next: *[*c]u8, validate: bool) bool {
    var r = skipBlanks(text);
    start.* = r;
    var w: [*c]u8 = undefined;
    if (!value.parseString(r, &w, &r, true)) return false;
    if (validate) {
        const saved = w[0];
        w[0] = 0;
        const ok = validName(start.*);
        w[0] = saved;
        if (!ok) return false;
    }
    end.* = w;
    next.* = r;
    return true;
}

pub fn parseFields(text: [*c]u8, end: *[*c]u8, s: [*c]Structure) bool {
    var r = text;
    while (true) {
        r = skipBlanks(r);
        if (r[0] == ';') {
            r += 1;
            break;
        }
        if (r[0] == 0) break;
        if (r[0] != ',') return false;
        r = skipBlanks(r + 1);
        if (r[0] == 0) break;
        if (r[0] == ';') {
            r += 1;
            break;
        }
        var f = std.mem.zeroes(Field);
        if (!parseField(r, &r, &f)) return false;
        putField(s, &f);
    }
    end.* = r;
    return true;
}

pub export fn gst_structure_from_string(text: [*c]const u8, end: [*c][*c]u8) [*c]Structure {
    if (!check.that(text != null, "gst_structure_from_string", "string != NULL")) return null;
    const copy = c.g_strdup(text);
    defer c.g_free(copy);
    var name: [*c]u8 = undefined;
    var w: [*c]u8 = undefined;
    var r: [*c]u8 = copy;
    if (!parseName(r, &name, &w, &r, false)) return null;
    const saved = w[0];
    w[0] = 0;
    const s = gst_structure_new_empty(name);
    w[0] = saved;
    if (s == null) return null;
    if (!parseFields(r, &r, s)) {
        gst_structure_free(s);
        return null;
    }
    if (end != null) {
        end.* = @constCast(text) + (@intFromPtr(r) - @intFromPtr(copy));
    } else if (r[0] != 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "gst_structure_from_string did not consume whole string, but caller did not provide end pointer (\"%s\")", text);
    }
    return s;
}

pub export fn gst_structure_new_from_string(text: [*c]const u8) [*c]Structure {
    return gst_structure_from_string(text, null);
}

fn fixateCheck(comptime func: []const u8, s: [*c]Structure, name: [*c]const u8) ?[*c]const Value {
    if (!check.that(gst_structure_has_field(s, name) != 0, func, "gst_structure_has_field (structure, field_name)")) return null;
    if (!check.that(mutable(s), func, "IS_MUTABLE (structure)")) return null;
    return gst_structure_get_value(s, name);
}

fn setInt(s: [*c]Structure, name: [*c]const u8, x: c.gint) void {
    var v = std.mem.zeroes(Value);
    _ = c.g_value_init(&v, G_TYPE_INT);
    c.g_value_set_int(&v, x);
    gst_structure_take_value(s, name, &v);
}

fn setDouble(s: [*c]Structure, name: [*c]const u8, x: f64) void {
    var v = std.mem.zeroes(Value);
    _ = c.g_value_init(&v, G_TYPE_DOUBLE);
    c.g_value_set_double(&v, x);
    gst_structure_take_value(s, name, &v);
}

pub export fn gst_structure_fixate_field_nearest_int(s: [*c]Structure, name: [*c]const u8, target_in: c.gint) c.gboolean {
    const v = fixateCheck("gst_structure_fixate_field_nearest_int", s, name) orelse return 0;
    var target = target_in;
    if (v.*.g_type == G_TYPE_INT) return 0;
    if (v.*.g_type == value._gst_int_range_type) {
        const lo = vtypes.gst_value_get_int_range_min(v);
        const hi = vtypes.gst_value_get_int_range_max(v);
        const step = vtypes.gst_value_get_int_range_step(v);
        target = std.math.clamp(target, lo, hi);
        if (step != 1) {
            const rem = @rem(target, step);
            target -= rem;
            if (rem > @divTrunc(step, 2)) target += step;
        }
        setInt(s, name, target);
        return 1;
    }
    if (v.*.g_type == value._gst_value_list_type) {
        var best: c.gint = 0;
        var found = false;
        var i: c.guint = 0;
        while (i < vlist.gst_value_list_get_size(v)) : (i += 1) {
            const item = vlist.gst_value_list_get_value(v, i);
            if (item.*.g_type != G_TYPE_INT) continue;
            const x = item[0].data[0].v_int;
            if (!found or @abs(target - x) < @abs(target - best)) {
                best = x;
                found = true;
            }
        }
        if (found) {
            setInt(s, name, best);
            return 1;
        }
    }
    return 0;
}

pub export fn gst_structure_fixate_field_nearest_double(s: [*c]Structure, name: [*c]const u8, target_in: c.gdouble) c.gboolean {
    const v = fixateCheck("gst_structure_fixate_field_nearest_double", s, name) orelse return 0;
    var target = target_in;
    if (v.*.g_type == G_TYPE_DOUBLE) return 0;
    if (v.*.g_type == value._gst_double_range_type) {
        const lo = vtypes.gst_value_get_double_range_min(v);
        if (target < lo) target = lo;
        const hi = vtypes.gst_value_get_double_range_max(v);
        if (target > hi) target = hi;
        setDouble(s, name, target);
        return 1;
    }
    if (v.*.g_type == value._gst_value_list_type) {
        var best: f64 = 0;
        var found = false;
        var i: c.guint = 0;
        while (i < vlist.gst_value_list_get_size(v)) : (i += 1) {
            const item = vlist.gst_value_list_get_value(v, i);
            if (item.*.g_type != G_TYPE_DOUBLE) continue;
            const x = item[0].data[0].v_double;
            if (!found or @abs(target - x) < @abs(target - best)) {
                best = x;
                found = true;
            }
        }
        if (found) {
            setDouble(s, name, best);
            return 1;
        }
    }
    return 0;
}

pub export fn gst_structure_fixate_field_boolean(s: [*c]Structure, name: [*c]const u8, target: c.gboolean) c.gboolean {
    const v = fixateCheck("gst_structure_fixate_field_boolean", s, name) orelse return 0;
    if (v.*.g_type == G_TYPE_BOOLEAN) return 0;
    if (v.*.g_type != value._gst_value_list_type) return 0;
    var best: c.gboolean = 0;
    var found = false;
    var i: c.guint = 0;
    while (i < vlist.gst_value_list_get_size(v)) : (i += 1) {
        const item = vlist.gst_value_list_get_value(v, i);
        if (item.*.g_type != G_TYPE_BOOLEAN) continue;
        const x = item[0].data[0].v_int;
        if (!found or x == target) {
            best = x;
            found = true;
        }
    }
    if (!found) return 0;
    var nv = std.mem.zeroes(Value);
    _ = c.g_value_init(&nv, G_TYPE_BOOLEAN);
    c.g_value_set_boolean(&nv, best);
    gst_structure_take_value(s, name, &nv);
    return 1;
}

pub export fn gst_structure_fixate_field_string(s: [*c]Structure, name: [*c]const u8, target: [*c]const u8) c.gboolean {
    const v = fixateCheck("gst_structure_fixate_field_string", s, name) orelse return 0;
    if (v.*.g_type == G_TYPE_STRING) return 0;
    if (v.*.g_type != value._gst_value_list_type) return 0;
    var best: [*c]const u8 = null;
    var found = false;
    var i: c.guint = 0;
    while (i < vlist.gst_value_list_get_size(v)) : (i += 1) {
        const item = vlist.gst_value_list_get_value(v, i);
        if (item.*.g_type != G_TYPE_STRING) continue;
        const x = c.g_value_get_string(item);
        if (!found or c.g_str_equal(x, target) != 0) {
            best = x;
            found = true;
        }
    }
    if (!found) return 0;
    var nv = std.mem.zeroes(Value);
    _ = c.g_value_init(&nv, G_TYPE_STRING);
    c.g_value_set_string(&nv, best);
    gst_structure_take_value(s, name, &nv);
    return 1;
}

pub export fn gst_structure_fixate_field_nearest_fraction(s: [*c]Structure, name: [*c]const u8, num: c.gint, den: c.gint) c.gboolean {
    const func = "gst_structure_fixate_field_nearest_fraction";
    if (!check.that(gst_structure_has_field(s, name) != 0, func, "gst_structure_has_field (structure, field_name)")) return 0;
    if (!check.that(mutable(s), func, "IS_MUTABLE (structure)")) return 0;
    if (!check.that(den != 0, func, "target_denominator != 0")) return 0;
    const v = gst_structure_get_value(s, name);
    if (v.*.g_type == value._gst_fraction_type) return 0;
    if (v.*.g_type == value._gst_fraction_range_type) {
        var target = std.mem.zeroes(Value);
        _ = c.g_value_init(&target, value._gst_fraction_type);
        vtypes.gst_value_set_fraction(&target, num, den);
        var pick: [*c]const Value = &target;
        const lo = vtypes.gst_value_get_fraction_range_min(v);
        if (value.gst_value_compare(&target, lo) == c.GST_VALUE_LESS_THAN) pick = lo;
        const hi = vtypes.gst_value_get_fraction_range_max(v);
        if (value.gst_value_compare(&target, hi) == c.GST_VALUE_GREATER_THAN) pick = hi;
        gst_structure_set_value(s, name, pick);
        c.g_value_unset(&target);
        return 1;
    }
    if (v.*.g_type == value._gst_value_list_type) {
        const target = @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
        var best: [*c]const Value = null;
        var best_diff: f64 = std.math.floatMax(f64);
        var i: c.guint = 0;
        while (i < vlist.gst_value_list_get_size(v)) : (i += 1) {
            const item = vlist.gst_value_list_get_value(v, i);
            if (item.*.g_type != value._gst_fraction_type) continue;
            const x = @as(f64, @floatFromInt(vtypes.gst_value_get_fraction_numerator(item))) / @as(f64, @floatFromInt(vtypes.gst_value_get_fraction_denominator(item)));
            const diff = @abs(target - x);
            if (best == null or diff < best_diff) {
                best = item;
                best_diff = diff;
            }
        }
        if (best != null) {
            gst_structure_set_value(s, name, best);
            return 1;
        }
    }
    return 0;
}

fn fixateOne(name: [*c]const IdStr, v: [*c]Value, data: c.gpointer) callconv(.c) c.gboolean {
    const s: [*c]Structure = @ptrCast(@alignCast(data));
    var fixed = std.mem.zeroes(Value);
    if (value.gst_value_fixate(&fixed, v) != 0 and acceptable(s, idstr.gst_id_str_as_str(name), v)) {
        c.g_value_unset(v);
        v.* = fixed;
    }
    return 1;
}

pub export fn gst_structure_fixate_field(s: [*c]Structure, name: [*c]const u8) c.gboolean {
    if (!check.that(s != null, "gst_structure_fixate_field", "structure != NULL")) return 0;
    if (!check.that(mutable(s), "gst_structure_fixate_field", "IS_MUTABLE (structure)")) return 0;
    const f = lookup(s, name) orelse return 0;
    return fixateOne(&f.name, &f.value, s);
}

pub export fn gst_structure_fixate(s: [*c]Structure) void {
    if (!check.that(isStructure(s), "gst_structure_fixate", "GST_IS_STRUCTURE (structure)")) return;
    _ = gst_structure_map_in_place_id_str(s, fixateOne, s);
}

fn isStructure(s: anytype) bool {
    return s != null and s.*.type == _gst_structure_type;
}

const KeyGet = enum(c_int) { str, id_str, quark };

fn getList(s: [*c]const Structure, kind: KeyGet, first: c.gpointer, ap: *va.VaList) callconv(.c) c.gboolean {
    var key = first;
    while (key != null) {
        const expected = @cVaArg(ap, c.GType);
        const name: [*c]const u8 = switch (kind) {
            .str => @ptrCast(key),
            .id_str => idstr.gst_id_str_as_str(@ptrCast(@alignCast(key))),
            .quark => c.g_quark_to_string(@intCast(@intFromPtr(key))),
        };
        const f = (if (kind == .id_str) lookupId(s, @ptrCast(@alignCast(key))) else lookup(s, name)) orelse return 0;
        if (f.value.g_type != expected) return 0;
        const err = va.lcopy(&f.value, ap, name);
        if (err != null) {
            const fname: [*c]const u8 = switch (kind) {
                .str => "gst_structure_get_valist",
                .id_str => "gst_structure_id_str_get_valist",
                .quark => "gst_structure_id_get_valist",
            };
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: %s", fname, err);
            c.g_free(err);
            return 0;
        }
        key = if (kind == .quark) @ptrFromInt(@as(usize, @cVaArg(ap, c.GQuark))) else @cVaArg(ap, c.gpointer);
    }
    return 1;
}

pub export fn gst_structure_get_valist(s: [*c]const Structure, first: [*c]const u8, ap: va.CVaList) c.gboolean {
    if (!check.that(isStructure(s), "gst_structure_get_valist", "GST_IS_STRUCTURE (structure)")) return 0;
    if (!check.that(first != null, "gst_structure_get_valist", "first_fieldname != NULL")) return 0;
    return getList(s, .str, @constCast(first), va.fromC(ap));
}

pub export fn gst_structure_id_str_get_valist(s: [*c]const Structure, first: [*c]const IdStr, ap: va.CVaList) c.gboolean {
    if (!check.that(isStructure(s), "gst_structure_id_str_get_valist", "GST_IS_STRUCTURE (structure)")) return 0;
    if (!check.that(first != null, "gst_structure_id_str_get_valist", "first_fieldname != NULL")) return 0;
    return getList(s, .id_str, @constCast(first), va.fromC(ap));
}

pub export fn gst_structure_id_get_valist(s: [*c]const Structure, first: c.GQuark, ap: va.CVaList) c.gboolean {
    if (!check.that(isStructure(s), "gst_structure_id_get_valist", "GST_IS_STRUCTURE (structure)")) return 0;
    if (!check.that(first != 0, "gst_structure_id_get_valist", "first_field_id != 0")) return 0;
    return getList(s, .quark, @ptrFromInt(@as(usize, first)), va.fromC(ap));
}

pub export fn gst_structure_get(s: [*c]const Structure, first: [*c]const u8, ...) callconv(.c) c.gboolean {
    if (!check.that(isStructure(s), "gst_structure_get", "GST_IS_STRUCTURE (structure)")) return 0;
    if (!check.that(first != null, "gst_structure_get", "first_fieldname != NULL")) return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return getList(s, .str, @constCast(first), &ap);
}

pub export fn gst_structure_id_str_get(s: [*c]const Structure, first: [*c]const IdStr, ...) callconv(.c) c.gboolean {
    if (!check.that(isStructure(s), "gst_structure_id_str_get", "GST_IS_STRUCTURE (structure)")) return 0;
    if (!check.that(first != null, "gst_structure_id_str_get", "first_fieldname != NULL")) return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return getList(s, .id_str, @constCast(first), &ap);
}

pub export fn gst_structure_id_get(s: [*c]const Structure, first: c.GQuark, ...) callconv(.c) c.gboolean {
    if (!check.that(isStructure(s), "gst_structure_id_get", "GST_IS_STRUCTURE (structure)")) return 0;
    if (!check.that(first != 0, "gst_structure_id_get", "first_field_id != 0")) return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return getList(s, .quark, @ptrFromInt(@as(usize, first)), &ap);
}

pub export fn gst_structure_is_equal(a: [*c]const Structure, b: [*c]const Structure) c.gboolean {
    if (!check.that(isStructure(a), "gst_structure_is_equal", "GST_IS_STRUCTURE (structure1)")) return 0;
    if (!check.that(isStructure(b), "gst_structure_is_equal", "GST_IS_STRUCTURE (structure2)")) return 0;
    if (a == b) return 1;
    if (idstr.gst_id_str_is_equal(&impl(a).name, &impl(b).name) == 0) return 0;
    if (impl(a).len != impl(b).len) return 0;
    for (fieldsOf(a)) |*f| {
        const other = lookupId(b, &f.name) orelse return 0;
        if (value.gst_value_compare(&other.value, &f.value) != c.GST_VALUE_EQUAL) return 0;
    }
    return 1;
}

pub export fn gst_structure_intersect(a: [*c]const Structure, b: [*c]const Structure) [*c]Structure {
    if (idstr.gst_id_str_is_equal(&impl(a).name, &impl(b).name) == 0) return null;
    const out = createCopyName(&impl(a).name, @min(impl(a).len, impl(b).len));
    for (fieldsOf(a)) |*fa| {
        if (lookupId(b, &fa.name)) |fb| {
            var both = std.mem.zeroes(Value);
            if (vsets.gst_value_intersect(&both, &fa.value, &fb.value) == 0) {
                gst_structure_free(out);
                return null;
            }
            gst_structure_id_str_take_value(out, &fa.name, &both);
        } else gst_structure_id_str_set_value(out, &fa.name, &fa.value);
    }
    for (fieldsOf(b)) |*fb| {
        if (lookupId(a, &fb.name) == null) gst_structure_id_str_set_value(out, &fb.name, &fb.value);
    }
    return out;
}

pub export fn gst_structure_can_intersect(a: [*c]const Structure, b: [*c]const Structure) c.gboolean {
    if (!check.that(isStructure(a), "gst_structure_can_intersect", "GST_IS_STRUCTURE (struct1)")) return 0;
    if (!check.that(isStructure(b), "gst_structure_can_intersect", "GST_IS_STRUCTURE (struct2)")) return 0;
    if (idstr.gst_id_str_is_equal(&impl(a).name, &impl(b).name) == 0) return 0;
    for (fieldsOf(a)) |*fa| {
        const fb = lookupId(b, &fa.name) orelse continue;
        if (vsets.gst_value_can_intersect(&fa.value, &fb.value) == 0) return 0;
        const order = value.gst_value_compare(&fa.value, &fb.value);
        if (order == c.GST_VALUE_UNORDERED) {
            if (vsets.gst_value_intersect(null, &fa.value, &fb.value) == 0) return 0;
        } else if (order != c.GST_VALUE_EQUAL) return 0;
    }
    return 1;
}

pub export fn gst_structure_is_subset(subset: [*c]const Structure, superset: [*c]const Structure) c.gboolean {
    if (idstr.gst_id_str_is_equal(&impl(superset).name, &impl(subset).name) == 0) return 0;
    if (impl(superset).len > impl(subset).len) return 0;
    for (fieldsOf(superset)) |*sup| {
        const sub = lookupId(subset, &sup.name) orelse return 0;
        const order = value.gst_value_compare(&sub.value, &sup.value);
        if (order == c.GST_VALUE_EQUAL) continue;
        if (order != c.GST_VALUE_UNORDERED) return 0;
        if (vsets.gst_value_is_subset(&sub.value, &sup.value) == 0) return 0;
    }
    return 1;
}

fn getAnyList(s: [*c]Structure, t: c.GType, comptime func: []const u8, name: [*c]const u8, out: [*c][*c]c.GValueArray) c.gboolean {
    if (!check.that(s != null, func, "structure != NULL")) return 0;
    if (!check.that(name != null, func, "fieldname != NULL")) return 0;
    if (!check.that(out != null, func, "array != NULL")) return 0;
    const f = lookup(s, name) orelse return 0;
    if (f.value.g_type != t) return 0;
    var v = std.mem.zeroes(Value);
    _ = c.g_value_init(&v, c.g_value_array_get_type());
    if (c.g_value_transform(&f.value, &v) != 0) {
        out.* = @ptrCast(@alignCast(c.g_value_get_boxed(&v)));
        return 1;
    }
    c.g_value_unset(&v);
    return 0;
}

pub export fn gst_structure_get_array(s: [*c]Structure, name: [*c]const u8, out: [*c][*c]c.GValueArray) c.gboolean {
    return getAnyList(s, value._gst_value_array_type, "_gst_structure_get_any_list", name, out);
}

pub export fn gst_structure_get_list(s: [*c]Structure, name: [*c]const u8, out: [*c][*c]c.GValueArray) c.gboolean {
    return getAnyList(s, value._gst_value_list_type, "_gst_structure_get_any_list", name, out);
}

fn setAnyList(s: [*c]Structure, t: c.GType, name: [*c]const u8, arr: [*c]const c.GValueArray) void {
    const func = "_gst_structure_set_any_list";
    if (!check.that(s != null, func, "structure != NULL")) return;
    if (!check.that(name != null, func, "fieldname != NULL")) return;
    if (!check.that(arr != null, func, "array != NULL")) return;
    if (!check.that(mutable(s), func, "IS_MUTABLE (structure)")) return;
    var v = std.mem.zeroes(Value);
    var src = std.mem.zeroes(Value);
    _ = c.g_value_init(&v, t);
    _ = c.g_value_init(&src, c.g_value_array_get_type());
    c.g_value_set_static_boxed(&src, arr);
    if (c.g_value_transform(&src, &v) != 0) {
        var n = std.mem.zeroes(IdStr);
        idstr.gst_id_str_set(&n, name);
        setTake(s, &n, &v);
    } else {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Failed to convert a GValueArray");
        c.g_value_unset(&v);
    }
    c.g_value_unset(&src);
}

pub export fn gst_structure_set_array(s: [*c]Structure, name: [*c]const u8, arr: [*c]const c.GValueArray) void {
    setAnyList(s, value._gst_value_array_type, name, arr);
}

pub export fn gst_structure_set_list(s: [*c]Structure, name: [*c]const u8, arr: [*c]const c.GValueArray) void {
    setAnyList(s, value._gst_value_list_type, name, arr);
}

pub export fn gst_structure_is_writable(s: [*c]const Structure) c.gboolean {
    if (!check.that(isStructure(s), "gst_structure_is_writable", "GST_IS_STRUCTURE (structure)")) return 0;
    return @intFromBool(mutable(s));
}

pub fn registerValue() void {
    value_table = .{ .type = gst_structure_get_type(), .compare = compareValues, .serialize = serializeValue, .deserialize = deserializeValue, .hash = @import("vhash.zig").structure };
    value.gst_value_register(&value_table);
}
