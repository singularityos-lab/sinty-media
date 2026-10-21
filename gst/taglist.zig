const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const idstr = @import("idstr.zig");
const va = @import("varargs.zig");
const value = @import("value.zig");
const vlist = @import("vlist.zig");
const vbasic = @import("vbasic.zig");
const tagdefs = @import("tagdefs.zig");

comptime {
    @import("abi.zig").check(@This());
}

const TagList = c.GstTagList;
const Value = c.GValue;
const Mini = c.GstMiniObject;

const Impl = extern struct {
    list: TagList,
    s: [*c]c.GstStructure,
    scope: c.GstTagScope,
};

const Info = struct {
    t: c.GType,
    name: c.GstIdStr,
    nick: [*c]const u8,
    blurb: [*c]const u8,
    merge: c.GstTagMergeFunc,
    flag: c.GstTagFlag,
};

pub export var _gst_tag_list_type: c.GType = 0;
var type_once: gtype.Once = .{};
var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var tags: ?*c.GHashTable = null;

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn isList(p: anytype) bool {
    return p != null and asMini(p)[0].type == _gst_tag_list_type;
}

fn validMode(m: c.GstTagMergeMode) bool {
    return m > c.GST_TAG_MERGE_UNDEFINED and m < c.GST_TAG_MERGE_COUNT;
}

pub export fn gst_tag_list_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstTagList", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_tag_merge_use_first(dest: [*c]Value, src: [*c]const Value) void {
    const first = vlist.gst_value_list_get_value(src, 0);
    _ = c.g_value_init(dest, first[0].g_type);
    c.g_value_copy(first, dest);
}

pub export fn gst_tag_merge_strings_with_comma(dest: [*c]Value, src: [*c]const Value) void {
    const n = vlist.gst_value_list_get_size(src);
    const s = c.g_string_new(c.g_value_get_string(vlist.gst_value_list_get_value(src, 0)));
    var i: c.guint = 1;
    while (i < n) : (i += 1) {
        _ = c.g_string_append(s, c.g_dgettext("gstreamer-1.0", ", "));
        _ = c.g_string_append(s, c.g_value_get_string(vlist.gst_value_list_get_value(src, i)));
    }
    _ = c.g_value_init(dest, c.G_TYPE_STRING);
    c.g_value_take_string(dest, c.g_string_free(s, 0));
}

fn lookup(name: [*c]const u8) ?*Info {
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    return @ptrCast(@alignCast(c.g_hash_table_lookup(tags, name)));
}

pub fn initialize() void {
    _gst_tag_list_type = gst_tag_list_get_type();
    tags = c.g_hash_table_new(c.g_str_hash, c.g_str_equal);
    for (tagdefs.defs) |d| {
        const merge: c.GstTagMergeFunc = switch (d.merge) {
            .none => null,
            .first => gst_tag_merge_use_first,
            .comma => gst_tag_merge_strings_with_comma,
        };
        gst_tag_register_static(d.name.ptr, d.flag, d.t(), c.g_dgettext("gstreamer-1.0", d.nick.ptr), c.g_dgettext("gstreamer-1.0", d.blurb.ptr), merge);
    }
    registerValue();
}

fn registerGuard(comptime f: []const u8, name: [*c]const u8, nick: [*c]const u8, blurb: [*c]const u8, t: c.GType) bool {
    if (!check.that(name != null, f, "name != NULL")) return false;
    if (!check.that(nick != null, f, "nick != NULL")) return false;
    if (!check.that(blurb != null, f, "blurb != NULL")) return false;
    return check.that(t != 0 and t != value._gst_value_list_type, f, "type != G_TYPE_INVALID && type != GST_TYPE_LIST");
}

pub export fn gst_tag_register(name: [*c]const u8, flag: c.GstTagFlag, t: c.GType, nick: [*c]const u8, blurb: [*c]const u8, merge: c.GstTagMergeFunc) void {
    if (!registerGuard("gst_tag_register", name, nick, blurb, t)) return;
    gst_tag_register_static(c.g_intern_string(name), flag, t, c.g_intern_string(nick), c.g_intern_string(blurb), merge);
}

pub export fn gst_tag_register_static(name: [*c]const u8, flag: c.GstTagFlag, t: c.GType, nick: [*c]const u8, blurb: [*c]const u8, merge: c.GstTagMergeFunc) void {
    if (!registerGuard("gst_tag_register_static", name, nick, blurb, t)) return;
    if (lookup(name)) |known| {
        _ = check.that(known.t == t, "gst_tag_register_static", "info->type == type");
        return;
    }
    const info: *Info = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Info))));
    info.* = .{ .t = t, .name = std.mem.zeroes(c.GstIdStr), .nick = nick, .blurb = blurb, .merge = merge, .flag = flag };
    idstr.gst_id_str_set_static_str(&info.name, name);
    c.g_mutex_lock(&lock);
    defer c.g_mutex_unlock(&lock);
    _ = c.g_hash_table_insert(tags, @constCast(name), info);
}

pub export fn gst_tag_exists(tag: [*c]const u8) c.gboolean {
    if (!check.that(tag != null, "gst_tag_exists", "tag != NULL")) return 0;
    return @intFromBool(lookup(tag) != null);
}

fn infoOrFail(comptime f: []const u8, tag: [*c]const u8) ?*Info {
    if (!check.that(tag != null, f, "tag != NULL")) return null;
    const info = lookup(tag);
    if (info == null) check.fail(f, "info != NULL");
    return info;
}

pub export fn gst_tag_get_type(tag: [*c]const u8) c.GType {
    return (infoOrFail("gst_tag_get_type", tag) orelse return 0).t;
}

pub export fn gst_tag_get_nick(tag: [*c]const u8) [*c]const u8 {
    if (!check.that(tag != null, "gst_tag_get_nick", "tag != NULL")) return null;
    const info = lookup(tag) orelse return tag;
    return info.nick;
}

pub export fn gst_tag_get_description(tag: [*c]const u8) [*c]const u8 {
    return (infoOrFail("gst_tag_get_description", tag) orelse return null).blurb;
}

pub export fn gst_tag_get_flag(tag: [*c]const u8) c.GstTagFlag {
    return (infoOrFail("gst_tag_get_flag", tag) orelse return c.GST_TAG_FLAG_UNDEFINED).flag;
}

pub export fn gst_tag_is_fixed(tag: [*c]const u8) c.gboolean {
    return @intFromBool((infoOrFail("gst_tag_is_fixed", tag) orelse return 0).merge == null);
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    if (!check.that(isList(src), "__gst_tag_list_copy", "GST_IS_TAG_LIST (list)")) return null;
    return asMini(wrap(c.gst_structure_copy(impl(src).s), impl(src).scope));
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    if (!check.that(isList(m), "__gst_tag_list_free", "GST_IS_TAG_LIST (list)")) return;
    c.gst_structure_free(impl(m).s);
    c.g_free(m);
}

fn wrap(s: [*c]c.GstStructure, scope: c.GstTagScope) [*c]TagList {
    const l: *Impl = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Impl))));
    mini.gst_mini_object_init(asMini(l), 0, _gst_tag_list_type, copyHook, null, freeHook);
    l.s = s;
    l.scope = scope;
    return @ptrCast(l);
}

pub export fn gst_tag_list_new_empty() [*c]TagList {
    return wrap(c.gst_structure_new_empty("taglist"), c.GST_TAG_SCOPE_STREAM);
}

pub export fn gst_tag_list_new(tag: [*c]const u8, ...) callconv(.c) [*c]TagList {
    if (!check.that(tag != null, "gst_tag_list_new", "tag != NULL")) return null;
    const l = gst_tag_list_new_empty();
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    addList(l, c.GST_TAG_MERGE_APPEND, tag, &ap);
    return l;
}

pub export fn gst_tag_list_new_valist(ap_c: va.CVaList) [*c]TagList {
    const l = gst_tag_list_new_empty();
    const ap = va.fromC(ap_c);
    const tag = @cVaArg(ap, [*c]const u8);
    addList(l, c.GST_TAG_MERGE_APPEND, tag, ap);
    return l;
}

pub export fn gst_tag_list_set_scope(l: [*c]TagList, scope: c.GstTagScope) void {
    if (!check.that(isList(l), "gst_tag_list_set_scope", "GST_IS_TAG_LIST (list)")) return;
    if (!check.that(gst_tag_list_is_writable(l) != 0, "gst_tag_list_set_scope", "gst_tag_list_is_writable (list)")) return;
    impl(l).scope = scope;
}

pub export fn gst_tag_list_get_scope(l: [*c]const TagList) c.GstTagScope {
    if (!check.that(isList(l), "gst_tag_list_get_scope", "GST_IS_TAG_LIST (list)")) return c.GST_TAG_SCOPE_STREAM;
    return impl(l).scope;
}

pub export fn gst_tag_list_to_string(l: [*c]const TagList) [*c]u8 {
    if (!check.that(isList(l), "gst_tag_list_to_string", "GST_IS_TAG_LIST (list)")) return null;
    return c.gst_structure_to_string(impl(l).s);
}

pub export fn gst_tag_list_new_from_string(text: [*c]const u8) [*c]TagList {
    if (!check.that(text != null, "gst_tag_list_new_from_string", "str != NULL")) return null;
    if (!check.that(c.g_str_has_prefix(text, "taglist") != 0, "gst_tag_list_new_from_string", "g_str_has_prefix (str, \"taglist\")")) return null;
    const s = c.gst_structure_from_string(text, null);
    if (s == null) return null;
    return wrap(s, c.GST_TAG_SCOPE_STREAM);
}

pub export fn gst_tag_list_n_tags(l: [*c]const TagList) c.gint {
    if (!check.that(l != null, "gst_tag_list_n_tags", "list != NULL")) return 0;
    if (!check.that(isList(l), "gst_tag_list_n_tags", "GST_IS_TAG_LIST (list)")) return 0;
    return c.gst_structure_n_fields(impl(l).s);
}

pub export fn gst_tag_list_nth_tag_name(l: [*c]const TagList, idx: c.guint) [*c]const u8 {
    if (!check.that(l != null, "gst_tag_list_nth_tag_name", "list != NULL")) return null;
    if (!check.that(isList(l), "gst_tag_list_nth_tag_name", "GST_IS_TAG_LIST (list)")) return null;
    return c.gst_structure_nth_field_name(impl(l).s, idx);
}

pub export fn gst_tag_list_is_empty(l: [*c]const TagList) c.gboolean {
    if (!check.that(l != null, "gst_tag_list_is_empty", "list != NULL")) return 0;
    if (!check.that(isList(l), "gst_tag_list_is_empty", "GST_IS_TAG_LIST (list)")) return 0;
    return @intFromBool(c.gst_structure_n_fields(impl(l).s) == 0);
}

fn fieldEqual(field: [*c]const c.GstIdStr, b: [*c]const Value, data: c.gpointer) callconv(.c) c.gboolean {
    const other: [*c]const c.GstStructure = @ptrCast(@alignCast(data));
    const a = c.gst_structure_id_str_get_value(other, field);
    if (a == null) return 0;
    if (value.gst_value_compare(a, b) == c.GST_VALUE_EQUAL) return 1;
    if (a[0].g_type == b[0].g_type and a[0].g_type == c.G_TYPE_DOUBLE) return @intFromBool(@abs(c.g_value_get_double(a) - c.g_value_get_double(b)) < 0.0000001);
    return 0;
}

pub export fn gst_tag_list_is_equal(a: [*c]const TagList, b: [*c]const TagList) c.gboolean {
    if (!check.that(isList(a), "gst_tag_list_is_equal", "GST_IS_TAG_LIST (list1)")) return 0;
    if (!check.that(isList(b), "gst_tag_list_is_equal", "GST_IS_TAG_LIST (list2)")) return 0;
    const s1 = impl(a).s;
    const s2 = impl(b).s;
    if (s1 == s2) return 1;
    if (c.gst_structure_n_fields(s1) != c.gst_structure_n_fields(s2)) return 0;
    return c.gst_structure_foreach_id_str(s1, fieldEqual, @ptrCast(s2));
}

fn addValue(l: [*c]TagList, mode: c.GstTagMergeMode, tag: [*c]const u8, v: [*c]const Value, known: ?*Info) void {
    const s = impl(l).s;
    const info = known orelse lookup(tag) orelse {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "unknown tag '%s'", tag);
        return;
    };
    const is_list = v[0].g_type == value._gst_value_list_type;
    if (c.g_type_check_value_holds(v, info.t) == 0 and !is_list) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "tag '%s' should hold value of type '%s', but value of type '%s' passed", info.nick, c.g_type_name(info.t), c.g_type_name(v[0].g_type));
        return;
    }
    const name = &info.name;
    const existing = c.gst_structure_id_str_get_value(s, name);
    if (info.merge != null and existing != null) {
        var dest = std.mem.zeroes(Value);
        const existing_list = existing[0].g_type == value._gst_value_list_type;
        switch (mode) {
            c.GST_TAG_MERGE_REPLACE_ALL, c.GST_TAG_MERGE_REPLACE => c.gst_structure_id_str_set_value(s, name, v),
            c.GST_TAG_MERGE_PREPEND => if (existing_list and !is_list) {
                vlist.gst_value_list_prepend_value(@constCast(existing), v);
            } else {
                vlist.gst_value_list_merge(&dest, v, existing);
                c.gst_structure_id_str_take_value(s, name, &dest);
            },
            c.GST_TAG_MERGE_APPEND => if (existing_list and !is_list) {
                vlist.gst_value_list_append_value(@constCast(existing), v);
            } else {
                vlist.gst_value_list_merge(&dest, existing, v);
                c.gst_structure_id_str_take_value(s, name, &dest);
            },
            c.GST_TAG_MERGE_KEEP, c.GST_TAG_MERGE_KEEP_ALL => {},
            else => check.unreachableAt("../gst/gsttaglist.c", 1132, "gst_tag_list_add_value_internal"),
        }
        return;
    }
    switch (mode) {
        c.GST_TAG_MERGE_APPEND, c.GST_TAG_MERGE_KEEP => if (existing == null) c.gst_structure_id_str_set_value(s, name, v),
        c.GST_TAG_MERGE_REPLACE_ALL, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_MERGE_PREPEND => c.gst_structure_id_str_set_value(s, name, v),
        c.GST_TAG_MERGE_KEEP_ALL => {},
        else => check.unreachableAt("../gst/gsttaglist.c", 1152, "gst_tag_list_add_value_internal"),
    }
}

const Copy = struct { list: [*c]TagList, mode: c.GstTagMergeMode };

fn copyEach(field: [*c]const c.GstIdStr, v: [*c]const Value, data: c.gpointer) callconv(.c) c.gboolean {
    const cp: *Copy = @ptrCast(@alignCast(data));
    addValue(cp.list, cp.mode, idstr.gst_id_str_as_str(field), v, null);
    return 1;
}

pub export fn gst_tag_list_insert(into: [*c]TagList, from: [*c]const TagList, mode: c.GstTagMergeMode) void {
    const f = "gst_tag_list_insert";
    if (!check.that(isList(into), f, "GST_IS_TAG_LIST (into)")) return;
    if (!check.that(gst_tag_list_is_writable(into) != 0, f, "gst_tag_list_is_writable (into)")) return;
    if (!check.that(isList(from), f, "GST_IS_TAG_LIST (from)")) return;
    if (!check.that(validMode(mode), f, "GST_TAG_MODE_IS_VALID (mode)")) return;
    if (mode == c.GST_TAG_MERGE_REPLACE_ALL) c.gst_structure_remove_all_fields(impl(into).s);
    var cp = Copy{ .list = into, .mode = mode };
    _ = c.gst_structure_foreach_id_str(impl(from).s, copyEach, &cp);
}

pub export fn gst_tag_list_merge(a: [*c]const TagList, b: [*c]const TagList, mode: c.GstTagMergeMode) [*c]TagList {
    const f = "gst_tag_list_merge";
    if (!check.that(a == null or isList(a), f, "list1 == NULL || GST_IS_TAG_LIST (list1)")) return null;
    if (!check.that(b == null or isList(b), f, "list2 == NULL || GST_IS_TAG_LIST (list2)")) return null;
    if (!check.that(validMode(mode), f, "GST_TAG_MODE_IS_VALID (mode)")) return null;
    if (a == null and b == null) return null;
    const out = if (a != null) gst_tag_list_copy(a) else gst_tag_list_new_empty();
    const other = if (b != null) b else gst_tag_list_new_empty();
    gst_tag_list_insert(out, other, mode);
    if (b == null) gst_tag_list_unref(@constCast(other));
    return out;
}

pub export fn gst_tag_list_get_tag_size(l: [*c]const TagList, tag: [*c]const u8) c.guint {
    if (!check.that(isList(l), "gst_tag_list_get_tag_size", "GST_IS_TAG_LIST (list)")) return 0;
    const v = c.gst_structure_get_value(impl(l).s, tag);
    if (v == null) return 0;
    if (v[0].g_type != value._gst_value_list_type) return 1;
    return vlist.gst_value_list_get_size(v);
}

fn addGuard(comptime f: []const u8, l: [*c]TagList, mode: c.GstTagMergeMode, tag: [*c]const u8) bool {
    if (!check.that(isList(l), f, "GST_IS_TAG_LIST (list)")) return false;
    if (!check.that(gst_tag_list_is_writable(l) != 0, f, "gst_tag_list_is_writable (list)")) return false;
    if (!check.that(validMode(mode), f, "GST_TAG_MODE_IS_VALID (mode)")) return false;
    return check.that(tag != null, f, "tag != NULL");
}

fn addList(l: [*c]TagList, mode: c.GstTagMergeMode, first: [*c]const u8, ap: *va.VaList) callconv(.c) void {
    if (mode == c.GST_TAG_MERGE_REPLACE_ALL) c.gst_structure_remove_all_fields(impl(l).s);
    var tag = first;
    while (tag != null) {
        const info = lookup(tag) orelse {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "unknown tag '%s'", tag);
            return;
        };
        var v = std.mem.zeroes(Value);
        const err = va.collect(&v, info.t, ap);
        if (err != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: %s", "../gst/gsttaglist.c:1307", err);
            c.g_free(err);
            return;
        }
        if (info.t == c.gst_sample_get_type() and !(v.data[0].v_pointer != null and @as([*c]Mini, @ptrCast(@alignCast(v.data[0].v_pointer)))[0].type == c.gst_sample_get_type())) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Expected GstSample argument for tag '%s'", tag);
        } else addValue(l, mode, tag, &v, info);
        c.g_value_unset(&v);
        tag = @cVaArg(ap, [*c]const u8);
    }
}

fn addValueList(l: [*c]TagList, mode: c.GstTagMergeMode, first: [*c]const u8, ap: *va.VaList) callconv(.c) void {
    if (mode == c.GST_TAG_MERGE_REPLACE_ALL) c.gst_structure_remove_all_fields(impl(l).s);
    var tag = first;
    while (tag != null) {
        const info = lookup(tag) orelse {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "unknown tag '%s'", tag);
            return;
        };
        addValue(l, mode, tag, @cVaArg(ap, [*c]const Value), info);
        tag = @cVaArg(ap, [*c]const u8);
    }
}

pub export fn gst_tag_list_add(l: [*c]TagList, mode: c.GstTagMergeMode, tag: [*c]const u8, ...) callconv(.c) void {
    if (!addGuard("gst_tag_list_add", l, mode, tag)) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    addList(l, mode, tag, &ap);
}

pub export fn gst_tag_list_add_values(l: [*c]TagList, mode: c.GstTagMergeMode, tag: [*c]const u8, ...) callconv(.c) void {
    if (!addGuard("gst_tag_list_add_values", l, mode, tag)) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    addValueList(l, mode, tag, &ap);
}

pub export fn gst_tag_list_add_valist(l: [*c]TagList, mode: c.GstTagMergeMode, tag: [*c]const u8, ap: va.CVaList) void {
    if (!addGuard("gst_tag_list_add_valist", l, mode, tag)) return;
    addList(l, mode, tag, va.fromC(ap));
}

pub export fn gst_tag_list_add_valist_values(l: [*c]TagList, mode: c.GstTagMergeMode, tag: [*c]const u8, ap: va.CVaList) void {
    if (!addGuard("gst_tag_list_add_valist_values", l, mode, tag)) return;
    addValueList(l, mode, tag, va.fromC(ap));
}

pub export fn gst_tag_list_add_value(l: [*c]TagList, mode: c.GstTagMergeMode, tag: [*c]const u8, v: [*c]const Value) void {
    if (!addGuard("gst_tag_list_add_value", l, mode, tag)) return;
    addValue(l, mode, tag, v, null);
}

pub export fn gst_tag_list_remove_tag(l: [*c]TagList, tag: [*c]const u8) void {
    if (!check.that(isList(l), "gst_tag_list_remove_tag", "GST_IS_TAG_LIST (list)")) return;
    if (!check.that(gst_tag_list_is_writable(l) != 0, "gst_tag_list_remove_tag", "gst_tag_list_is_writable (list)")) return;
    if (!check.that(tag != null, "gst_tag_list_remove_tag", "tag != NULL")) return;
    c.gst_structure_remove_field(impl(l).s, tag);
}

const Each = struct { func: c.GstTagForeachFunc, list: [*c]const TagList, data: c.gpointer };

fn eachTag(field: [*c]const c.GstIdStr, _: [*c]const Value, data: c.gpointer) callconv(.c) c.gboolean {
    const e: *Each = @ptrCast(@alignCast(data));
    e.func.?(e.list, idstr.gst_id_str_as_str(field), e.data);
    return 1;
}

pub export fn gst_tag_list_foreach(l: [*c]const TagList, func: c.GstTagForeachFunc, data: c.gpointer) void {
    if (!check.that(isList(l), "gst_tag_list_foreach", "GST_IS_TAG_LIST (list)")) return;
    if (!check.that(func != null, "gst_tag_list_foreach", "func != NULL")) return;
    var e = Each{ .func = func, .list = l, .data = data };
    _ = c.gst_structure_foreach_id_str(impl(l).s, eachTag, &e);
}

pub export fn gst_tag_list_get_value_index(l: [*c]const TagList, tag: [*c]const u8, idx: c.guint) [*c]const Value {
    if (!check.that(isList(l), "gst_tag_list_get_value_index", "GST_IS_TAG_LIST (list)")) return null;
    if (!check.that(tag != null, "gst_tag_list_get_value_index", "tag != NULL")) return null;
    const v = c.gst_structure_get_value(impl(l).s, tag);
    if (v == null) return null;
    if (v[0].g_type == value._gst_value_list_type) {
        if (idx >= vlist.gst_value_list_get_size(v)) return null;
        return vlist.gst_value_list_get_value(v, idx);
    }
    return if (idx > 0) null else v;
}

pub export fn gst_tag_list_copy_value(dest: [*c]Value, l: [*c]const TagList, tag: [*c]const u8) c.gboolean {
    const f = "gst_tag_list_copy_value";
    if (!check.that(isList(l), f, "GST_IS_TAG_LIST (list)")) return 0;
    if (!check.that(tag != null, f, "tag != NULL")) return 0;
    if (!check.that(dest != null, f, "dest != NULL")) return 0;
    if (!check.that(dest[0].g_type == 0, f, "G_VALUE_TYPE (dest) == 0")) return 0;
    const src = c.gst_structure_get_value(impl(l).s, tag);
    if (src == null) return 0;
    if (src[0].g_type == value._gst_value_list_type) {
        const info = lookup(tag) orelse return 0;
        info.merge.?(dest, src);
    } else {
        _ = c.g_value_init(dest, src[0].g_type);
        c.g_value_copy(src, dest);
    }
    return 1;
}

fn Getter(comptime T: type, comptime get: anytype, comptime name: []const u8, comptime check_ptr: bool, comptime dup: bool) type {
    return struct {
        fn store(out: [*c]T, v: [*c]const Value) c.gboolean {
            if (dup) {
                const s: [*c]const u8 = get(v);
                out.* = if (s == null or s[0] == 0) null else c.g_strdup(s);
            } else out.* = get(v);
            if (check_ptr) return @intFromBool(out.* != null);
            return 1;
        }

        fn whole(l: [*c]const TagList, tag: [*c]const u8, out: [*c]T) c.gboolean {
            const f = "gst_tag_list_get_" ++ name;
            if (!check.that(isList(l), f, "GST_IS_TAG_LIST (list)")) return 0;
            if (!check.that(tag != null, f, "tag != NULL")) return 0;
            if (!check.that(out != null, f, "value != NULL")) return 0;
            var v = std.mem.zeroes(Value);
            if (gst_tag_list_copy_value(&v, l, tag) == 0) return 0;
            defer c.g_value_unset(&v);
            return store(out, &v);
        }

        fn indexed(l: [*c]const TagList, tag: [*c]const u8, idx: c.guint, out: [*c]T) c.gboolean {
            const f = "gst_tag_list_get_" ++ name ++ "_index";
            if (!check.that(isList(l), f, "GST_IS_TAG_LIST (list)")) return 0;
            if (!check.that(tag != null, f, "tag != NULL")) return 0;
            if (!check.that(out != null, f, "value != NULL")) return 0;
            const v = gst_tag_list_get_value_index(l, tag, idx);
            if (v == null) return 0;
            return store(out, v);
        }
    };
}

const GBool = Getter(c.gboolean, c.g_value_get_boolean, "boolean", false, false);
const GInt = Getter(c.gint, c.g_value_get_int, "int", false, false);
const GUint = Getter(c.guint, c.g_value_get_uint, "uint", false, false);
const GInt64 = Getter(c.gint64, c.g_value_get_int64, "int64", false, false);
const GUint64 = Getter(c.guint64, c.g_value_get_uint64, "uint64", false, false);
const GFloat = Getter(c.gfloat, c.g_value_get_float, "float", false, false);
const GDouble = Getter(c.gdouble, c.g_value_get_double, "double", false, false);
const GPointer = Getter(c.gpointer, c.g_value_get_pointer, "pointer", true, false);
const GString = Getter([*c]u8, c.g_value_get_string, "string", true, true);
const GDate = Getter(?*c.GDate, dupDate, "date", true, false);
const GDateTime = Getter(?*c.GstDateTime, dupDateTime, "date_time", true, false);
const GSample = Getter(?*c.GstSample, dupSample, "sample", true, false);

fn dupDate(v: [*c]const Value) ?*c.GDate {
    return @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
}
fn dupDateTime(v: [*c]const Value) ?*c.GstDateTime {
    return @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
}
fn dupSample(v: [*c]const Value) ?*c.GstSample {
    return @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
}

pub export fn gst_tag_list_get_boolean(l: [*c]const TagList, tag: [*c]const u8, out: [*c]c.gboolean) c.gboolean {
    return GBool.whole(l, tag, out);
}
pub export fn gst_tag_list_get_boolean_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]c.gboolean) c.gboolean {
    return GBool.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_int(l: [*c]const TagList, tag: [*c]const u8, out: [*c]c.gint) c.gboolean {
    return GInt.whole(l, tag, out);
}
pub export fn gst_tag_list_get_int_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]c.gint) c.gboolean {
    return GInt.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_uint(l: [*c]const TagList, tag: [*c]const u8, out: [*c]c.guint) c.gboolean {
    return GUint.whole(l, tag, out);
}
pub export fn gst_tag_list_get_uint_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]c.guint) c.gboolean {
    return GUint.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_int64(l: [*c]const TagList, tag: [*c]const u8, out: [*c]c.gint64) c.gboolean {
    return GInt64.whole(l, tag, out);
}
pub export fn gst_tag_list_get_int64_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]c.gint64) c.gboolean {
    return GInt64.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_uint64(l: [*c]const TagList, tag: [*c]const u8, out: [*c]c.guint64) c.gboolean {
    return GUint64.whole(l, tag, out);
}
pub export fn gst_tag_list_get_uint64_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]c.guint64) c.gboolean {
    return GUint64.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_float(l: [*c]const TagList, tag: [*c]const u8, out: [*c]c.gfloat) c.gboolean {
    return GFloat.whole(l, tag, out);
}
pub export fn gst_tag_list_get_float_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]c.gfloat) c.gboolean {
    return GFloat.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_double(l: [*c]const TagList, tag: [*c]const u8, out: [*c]c.gdouble) c.gboolean {
    return GDouble.whole(l, tag, out);
}
pub export fn gst_tag_list_get_double_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]c.gdouble) c.gboolean {
    return GDouble.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_pointer(l: [*c]const TagList, tag: [*c]const u8, out: [*c]c.gpointer) c.gboolean {
    return GPointer.whole(l, tag, out);
}
pub export fn gst_tag_list_get_pointer_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]c.gpointer) c.gboolean {
    return GPointer.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_string(l: [*c]const TagList, tag: [*c]const u8, out: [*c][*c]u8) c.gboolean {
    return GString.whole(l, tag, out);
}
pub export fn gst_tag_list_get_string_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c][*c]u8) c.gboolean {
    return GString.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_date(l: [*c]const TagList, tag: [*c]const u8, out: [*c]?*c.GDate) c.gboolean {
    return GDate.whole(l, tag, out);
}
pub export fn gst_tag_list_get_date_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]?*c.GDate) c.gboolean {
    return GDate.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_date_time(l: [*c]const TagList, tag: [*c]const u8, out: [*c]?*c.GstDateTime) c.gboolean {
    return GDateTime.whole(l, tag, out);
}
pub export fn gst_tag_list_get_date_time_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]?*c.GstDateTime) c.gboolean {
    return GDateTime.indexed(l, tag, i, out);
}
pub export fn gst_tag_list_get_sample(l: [*c]const TagList, tag: [*c]const u8, out: [*c]?*c.GstSample) c.gboolean {
    return GSample.whole(l, tag, out);
}
pub export fn gst_tag_list_get_sample_index(l: [*c]const TagList, tag: [*c]const u8, i: c.guint, out: [*c]?*c.GstSample) c.gboolean {
    return GSample.indexed(l, tag, i, out);
}

pub export fn gst_tag_list_peek_string_index(l: [*c]const TagList, tag: [*c]const u8, idx: c.guint, out: [*c][*c]const u8) c.gboolean {
    const f = "gst_tag_list_peek_string_index";
    if (!check.that(isList(l), f, "GST_IS_TAG_LIST (list)")) return 0;
    if (!check.that(tag != null, f, "tag != NULL")) return 0;
    if (!check.that(out != null, f, "value != NULL")) return 0;
    const v = gst_tag_list_get_value_index(l, tag, idx);
    if (v == null) return 0;
    out.* = c.g_value_get_string(v);
    return @intFromBool(out.* != null and out.*[0] != 0);
}

pub export fn gst_tag_list_copy(l: [*c]const TagList) [*c]TagList {
    return @ptrCast(mini.gst_mini_object_copy(asMini(l)));
}
pub export fn gst_tag_list_ref(l: [*c]TagList) [*c]TagList {
    return @ptrCast(mini.gst_mini_object_ref(asMini(l)));
}
pub export fn gst_tag_list_unref(l: [*c]TagList) void {
    mini.gst_mini_object_unref(asMini(l));
}
pub export fn gst_clear_tag_list(slot: [*c][*c]TagList) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}
pub export fn gst_tag_list_replace(slot: [*c][*c]TagList, l: [*c]TagList) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), asMini(l));
}
pub export fn gst_tag_list_take(slot: [*c][*c]TagList, l: [*c]TagList) c.gboolean {
    return mini.gst_mini_object_take(@ptrCast(slot), asMini(l));
}
pub fn structureOf(l: [*c]const TagList) [*c]const c.GstStructure {
    return impl(l).s;
}
pub export fn gst_tag_list_is_writable(l: [*c]const TagList) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(l));
}
pub export fn gst_tag_list_make_writable(l: [*c]TagList) [*c]TagList {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(l)));
}

fn compareValues(a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    const x: [*c]const TagList = @ptrCast(@alignCast(c.g_value_get_boxed(a)));
    const y: [*c]const TagList = @ptrCast(@alignCast(c.g_value_get_boxed(b)));
    return if (gst_tag_list_is_equal(x, y) != 0) c.GST_VALUE_EQUAL else c.GST_VALUE_UNORDERED;
}

fn serializeValue(v: [*c]const Value) callconv(.c) [*c]u8 {
    return vbasic.takeAndWrap(gst_tag_list_to_string(@ptrCast(@alignCast(c.g_value_get_boxed(v)))));
}

fn deserializeValue(dest: [*c]Value, s: [*c]const u8) callconv(.c) c.gboolean {
    var l: [*c]TagList = null;
    if (s[0] != '"') {
        l = gst_tag_list_new_from_string(s);
    } else {
        const raw = vbasic.unwrap(s);
        if (raw == null) return 0;
        l = gst_tag_list_new_from_string(raw);
        c.g_free(raw);
    }
    if (l == null) return 0;
    c.g_value_take_boxed(dest, l);
    return 1;
}

fn hashValue(v: [*c]const Value, res: [*c]c.guint) callconv(.c) c.gboolean {
    return @import("vhash.zig").structureHash(structureOf(@ptrCast(@alignCast(c.g_value_get_boxed(v)))), res);
}

var value_table: c.GstValueTable = .{};

pub fn registerValue() void {
    value_table = .{ .type = _gst_tag_list_type, .compare = compareValues, .serialize = serializeValue, .deserialize = deserializeValue, .hash = hashValue };
    value.gst_value_register(&value_table);
}
