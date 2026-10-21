const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const va = @import("varargs.zig");
const taglist = @import("taglist.zig");
const mini = @import("mini.zig");

comptime {
    @import("abi.zig").check(@This());
}

const TagSetter = c.GstTagSetter;
const TocSetter = c.GstTocSetter;
const Mode = c.GstTagMergeMode;

const TagData = struct {
    mode: Mode,
    list: [*c]c.GstTagList,
    lock: c.GMutex,
};

const TocData = struct {
    toc: ?*c.GstToc,
    lock: c.GMutex,
};

var tag_once: gtype.Once = .{};
var toc_once: gtype.Once = .{};
var tag_key: c.GQuark = 0;
var toc_key: c.GQuark = 0;
var create_lock = std.mem.zeroes(c.GMutex);
const alloc = std.heap.c_allocator;

fn iface(comptime name: [:0]const u8, size: usize) c.GType {
    const t = c.g_type_register_static_simple(c.G_TYPE_INTERFACE, name, @intCast(size), null, 0, null, 0);
    c.g_type_interface_add_prerequisite(t, c.gst_element_get_type());
    return t;
}

pub export fn gst_tag_setter_get_type() c.GType {
    return tag_once.get(struct {
        fn f() c.GType {
            const t = iface("GstTagSetter", @sizeOf(c.GstTagSetterInterface));
            tag_key = c.g_quark_from_static_string("gst-tag-setter-data");
            return t;
        }
    }.f);
}

pub export fn gst_toc_setter_get_type() c.GType {
    return toc_once.get(struct {
        fn f() c.GType {
            const t = iface("GstTocSetter", @sizeOf(c.GstTocSetterInterface));
            toc_key = c.g_quark_from_static_string("gst-toc-setter-data");
            return t;
        }
    }.f);
}

fn freeTag(p: c.gpointer) callconv(.c) void {
    const d: *TagData = @ptrCast(@alignCast(p));
    if (d.list != null) c.gst_tag_list_unref(d.list);
    c.g_mutex_clear(&d.lock);
    alloc.destroy(d);
}

fn freeToc(p: c.gpointer) callconv(.c) void {
    const d: *TocData = @ptrCast(@alignCast(p));
    if (d.toc) |t| mini.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    c.g_mutex_clear(&d.lock);
    alloc.destroy(d);
}

fn dataOf(comptime T: type, obj: anytype, key: c.GQuark, comptime free: c.GDestroyNotify, init: T) *T {
    const o: [*c]c.GObject = @ptrCast(@alignCast(obj));
    if (c.g_object_get_qdata(o, key)) |d| return @ptrCast(@alignCast(d));
    c.g_mutex_lock(&create_lock);
    defer c.g_mutex_unlock(&create_lock);
    if (c.g_object_get_qdata(o, key)) |d| return @ptrCast(@alignCast(d));
    const d = alloc.create(T) catch @panic("oom");
    d.* = init;
    c.g_mutex_init(&d.lock);
    c.g_object_set_qdata_full(o, key, d, free);
    return d;
}

fn tagData(s: ?*TagSetter) *TagData {
    return dataOf(TagData, s, tag_key, freeTag, .{ .mode = c.GST_TAG_MERGE_KEEP, .list = null, .lock = std.mem.zeroes(c.GMutex) });
}

fn tocData(s: ?*TocSetter) *TocData {
    return dataOf(TocData, s, toc_key, freeToc, .{ .toc = null, .lock = std.mem.zeroes(c.GMutex) });
}

fn isTagSetter(s: anytype) bool {
    return gtype.instanceOf(s, gst_tag_setter_get_type());
}

fn isTocSetter(s: anytype) bool {
    return gtype.instanceOf(s, gst_toc_setter_get_type());
}

fn validMode(m: Mode) bool {
    return m > c.GST_TAG_MERGE_UNDEFINED and m < c.GST_TAG_MERGE_COUNT;
}

fn guard(comptime f: []const u8, s: ?*TagSetter, mode: Mode) bool {
    return check.that(isTagSetter(s), f, "GST_IS_TAG_SETTER (setter)") and check.that(validMode(mode), f, "GST_TAG_MODE_IS_VALID (mode)");
}

pub export fn gst_tag_setter_reset_tags(s: ?*TagSetter) void {
    if (!check.that(isTagSetter(s), "gst_tag_setter_reset_tags", "GST_IS_TAG_SETTER (setter)")) return;
    const d = tagData(s);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    if (d.list != null) {
        c.gst_tag_list_unref(d.list);
        d.list = null;
    }
}

pub export fn gst_tag_setter_merge_tags(s: ?*TagSetter, list: [*c]const c.GstTagList, mode: Mode) void {
    const f = "gst_tag_setter_merge_tags";
    if (!guard(f, s, mode)) return;
    if (!check.that(list != null and list[0].mini_object.type == c.gst_tag_list_get_type(), f, "GST_IS_TAG_LIST (list)")) return;
    const d = tagData(s);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    if (d.list == null) {
        if (mode != c.GST_TAG_MERGE_KEEP_ALL) d.list = c.gst_tag_list_copy(list);
    } else c.gst_tag_list_insert(d.list, list, mode);
}

fn ensureList(d: *TagData) [*c]c.GstTagList {
    if (d.list == null) d.list = c.gst_tag_list_new_empty();
    return d.list;
}

pub export fn gst_tag_setter_add_tag_valist(s: ?*TagSetter, mode: Mode, tag: [*c]const u8, ap: va.CVaList) void {
    if (!guard("gst_tag_setter_add_tag_valist", s, mode)) return;
    const d = tagData(s);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    taglist.gst_tag_list_add_valist(ensureList(d), mode, tag, ap);
}

pub export fn gst_tag_setter_add_tag_valist_values(s: ?*TagSetter, mode: Mode, tag: [*c]const u8, ap: va.CVaList) void {
    if (!guard("gst_tag_setter_add_tag_valist_values", s, mode)) return;
    const d = tagData(s);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    taglist.gst_tag_list_add_valist_values(ensureList(d), mode, tag, ap);
}

pub export fn gst_tag_setter_add_tags(s: ?*TagSetter, mode: Mode, tag: [*c]const u8, ...) callconv(.c) void {
    if (!guard("gst_tag_setter_add_tags", s, mode)) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    gst_tag_setter_add_tag_valist(s, mode, tag, va.toC(&ap));
}

pub export fn gst_tag_setter_add_tag_values(s: ?*TagSetter, mode: Mode, tag: [*c]const u8, ...) callconv(.c) void {
    if (!guard("gst_tag_setter_add_tag_values", s, mode)) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    gst_tag_setter_add_tag_valist_values(s, mode, tag, va.toC(&ap));
}

pub export fn gst_tag_setter_add_tag_value(s: ?*TagSetter, mode: Mode, tag: [*c]const u8, v: [*c]const c.GValue) void {
    if (!guard("gst_tag_setter_add_tag_value", s, mode)) return;
    const d = tagData(s);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    c.gst_tag_list_add_value(ensureList(d), mode, tag, v);
}

pub export fn gst_tag_setter_get_tag_list(s: ?*TagSetter) [*c]const c.GstTagList {
    if (!check.that(isTagSetter(s), "gst_tag_setter_get_tag_list", "GST_IS_TAG_SETTER (setter)")) return null;
    return tagData(s).list;
}

pub export fn gst_tag_setter_set_tag_merge_mode(s: ?*TagSetter, mode: Mode) void {
    if (!guard("gst_tag_setter_set_tag_merge_mode", s, mode)) return;
    const d = tagData(s);
    c.g_mutex_lock(&d.lock);
    d.mode = mode;
    c.g_mutex_unlock(&d.lock);
}

pub export fn gst_tag_setter_get_tag_merge_mode(s: ?*TagSetter) Mode {
    if (!check.that(isTagSetter(s), "gst_tag_setter_get_tag_merge_mode", "GST_IS_TAG_SETTER (setter)")) return c.GST_TAG_MERGE_UNDEFINED;
    const d = tagData(s);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    return d.mode;
}

pub export fn gst_toc_setter_reset(s: ?*TocSetter) void {
    if (!check.that(isTocSetter(s), "gst_toc_setter_reset", "GST_IS_TOC_SETTER (setter)")) return;
    gst_toc_setter_set_toc(s, null);
}

pub export fn gst_toc_setter_get_toc(s: ?*TocSetter) ?*c.GstToc {
    if (!check.that(isTocSetter(s), "gst_toc_setter_get_toc", "GST_IS_TOC_SETTER (setter)")) return null;
    const d = tocData(s);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    return if (d.toc) |t| @ptrCast(mini.gst_mini_object_ref(@ptrCast(@alignCast(t)))) else null;
}

pub export fn gst_toc_setter_set_toc(s: ?*TocSetter, toc: ?*c.GstToc) void {
    if (!check.that(isTocSetter(s), "gst_toc_setter_set_toc", "GST_IS_TOC_SETTER (setter)")) return;
    const d = tocData(s);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    if (d.toc == toc) return;
    if (d.toc) |t| mini.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    d.toc = if (toc) |t| @ptrCast(mini.gst_mini_object_ref(@ptrCast(@alignCast(t)))) else null;
}
