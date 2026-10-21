const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const info = @import("info.zig");
const printf = @import("printf.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Toc = c.GstToc;
const Entry = c.GstTocEntry;
const Mini = c.GstMiniObject;
const TagList = c.GstTagList;
const NONE: u64 = std.math.maxInt(u64);

const TocImpl = extern struct {
    mini: Mini,
    scope: c.GstTocScope,
    entries: [*c]c.GList,
    tags: [*c]TagList,
};

const EntryImpl = extern struct {
    mini: Mini,
    toc: ?*Toc,
    parent: ?*Entry,
    uid: [*c]u8,
    kind: c.GstTocEntryType,
    start: c.GstClockTime,
    stop: c.GstClockTime,
    subentries: [*c]c.GList,
    tags: [*c]TagList,
    loop_type: c.GstTocLoopType,
    repeat_count: c.gint,
};

pub export var _gst_toc_type: c.GType = 0;
pub export var _gst_toc_entry_type: c.GType = 0;
var toc_once: gtype.Once = .{};
var entry_once: gtype.Once = .{};

fn t(p: anytype) *TocImpl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn e(p: anytype) *EntryImpl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn writable(p: anytype) bool {
    return mini.gst_mini_object_is_writable(asMini(p)) != 0;
}

fn boxed(comptime name: [:0]const u8) c.GType {
    return c.g_boxed_type_register_static(name.ptr, @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
}

pub export fn gst_toc_get_type() c.GType {
    return toc_once.get(struct {
        fn f() c.GType {
            return boxed("GstToc");
        }
    }.f);
}

pub export fn gst_toc_entry_get_type() c.GType {
    return entry_once.get(struct {
        fn f() c.GType {
            return boxed("GstTocEntry");
        }
    }.f);
}

pub fn initialize() void {
    _gst_toc_type = gst_toc_get_type();
    _gst_toc_entry_type = gst_toc_entry_get_type();
}

fn unrefAll(list: [*c]c.GList) void {
    var node: ?*c.GList = list;
    while (node) |n| : (node = n.next) mini.gst_mini_object_unref(@ptrCast(@alignCast(n.data)));
    c.g_list_free(list);
}

fn tocFree(m: [*c]Mini) callconv(.c) void {
    const x = t(m);
    unrefAll(x.entries);
    if (x.tags != null) c.gst_tag_list_unref(x.tags);
    c.g_free(m);
}

fn entryFree(m: [*c]Mini) callconv(.c) void {
    if (!check.that(m != null, "gst_toc_entry_free", "entry != NULL")) return;
    const x = e(m);
    unrefAll(x.subentries);
    c.g_free(x.uid);
    if (x.tags != null) c.gst_tag_list_unref(x.tags);
    c.g_free(m);
}

fn copyEntries(list: [*c]c.GList) [*c]c.GList {
    var out: [*c]c.GList = null;
    var node: ?*c.GList = list;
    while (node) |n| : (node = n.next) out = c.g_list_prepend(out, entryCopy(@ptrCast(@alignCast(n.data))));
    return c.g_list_reverse(out);
}

fn isTagList(p: [*c]TagList) bool {
    return p != null and asMini(p)[0].type == c.gst_tag_list_get_type();
}

fn entryCopy(src: [*c]const Mini) callconv(.c) [*c]Mini {
    if (!check.that(src != null, "gst_toc_entry_copy", "entry != NULL")) return null;
    const s = e(src);
    const out = gst_toc_entry_new(s.kind, s.uid) orelse return null;
    const o = e(out);
    o.start = s.start;
    o.stop = s.stop;
    if (isTagList(s.tags)) {
        const copy = c.gst_tag_list_copy(s.tags);
        if (o.tags != null) c.gst_tag_list_unref(o.tags);
        o.tags = copy;
    }
    o.subentries = copyEntries(s.subentries);
    return asMini(out);
}

fn tocCopy(src: [*c]const Mini) callconv(.c) [*c]Mini {
    if (!check.that(src != null, "gst_toc_copy", "toc != NULL")) return null;
    const s = t(src);
    const out = gst_toc_new(s.scope) orelse return null;
    if (isTagList(s.tags)) {
        const copy = c.gst_tag_list_copy(s.tags);
        c.gst_tag_list_unref(t(out).tags);
        t(out).tags = copy;
    }
    t(out).entries = copyEntries(s.entries);
    return asMini(out);
}

pub export fn gst_toc_new(scope: c.GstTocScope) ?*Toc {
    if (!check.that(scope == c.GST_TOC_SCOPE_GLOBAL or scope == c.GST_TOC_SCOPE_CURRENT, "gst_toc_new", "scope == GST_TOC_SCOPE_GLOBAL || scope == GST_TOC_SCOPE_CURRENT")) return null;
    const x: *TocImpl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(TocImpl))));
    mini.gst_mini_object_init(asMini(x), 0, gst_toc_get_type(), tocCopy, null, tocFree);
    x.scope = scope;
    x.tags = c.gst_tag_list_new_empty();
    return @ptrCast(x);
}

pub export fn gst_toc_get_scope(p: ?*const Toc) c.GstTocScope {
    if (!check.that(p != null, "gst_toc_get_scope", "toc != NULL")) return c.GST_TOC_SCOPE_GLOBAL;
    return t(p).scope;
}

pub export fn gst_toc_set_tags(p: ?*Toc, tags: [*c]TagList) void {
    if (!check.that(p != null, "gst_toc_set_tags", "toc != NULL")) return;
    if (!check.that(writable(p), "gst_toc_set_tags", "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (toc))")) return;
    if (t(p).tags != null) c.gst_tag_list_unref(t(p).tags);
    t(p).tags = tags;
}

fn merge(slot: *[*c]TagList, tags: [*c]TagList, mode: c.GstTagMergeMode) void {
    if (slot.* == null) {
        slot.* = c.gst_tag_list_ref(tags);
        return;
    }
    const merged = c.gst_tag_list_merge(slot.*, tags, mode);
    c.gst_tag_list_unref(slot.*);
    slot.* = merged;
}

pub export fn gst_toc_merge_tags(p: ?*Toc, tags: [*c]TagList, mode: c.GstTagMergeMode) void {
    if (!check.that(p != null, "gst_toc_merge_tags", "toc != NULL")) return;
    if (!check.that(writable(p), "gst_toc_merge_tags", "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (toc))")) return;
    merge(&t(p).tags, tags, mode);
}

pub export fn gst_toc_get_tags(p: ?*const Toc) [*c]TagList {
    if (!check.that(p != null, "gst_toc_get_tags", "toc != NULL")) return null;
    return t(p).tags;
}

pub export fn gst_toc_append_entry(p: ?*Toc, entry: ?*Entry) void {
    const f = "gst_toc_append_entry";
    if (!check.that(p != null, f, "toc != NULL")) return;
    if (!check.that(writable(p), f, "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (toc))")) return;
    if (!check.that(writable(entry), f, "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (entry))")) return;
    if (!check.that(e(entry).toc == null, f, "entry->toc == NULL")) return;
    if (!check.that(e(entry).parent == null, f, "entry->parent == NULL")) return;
    t(p).entries = c.g_list_append(t(p).entries, entry);
    e(entry).toc = p;
    gst_toc_dump(p);
}

pub export fn gst_toc_get_entries(p: ?*const Toc) [*c]c.GList {
    if (!check.that(p != null, "gst_toc_get_entries", "toc != NULL")) return null;
    return t(p).entries;
}

pub export fn gst_toc_entry_new(kind: c.GstTocEntryType, uid: [*c]const u8) ?*Entry {
    if (!check.that(uid != null, "gst_toc_entry_new", "uid != NULL")) return null;
    const x: *EntryImpl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(EntryImpl))));
    mini.gst_mini_object_init(asMini(x), 0, gst_toc_entry_get_type(), entryCopy, null, entryFree);
    x.uid = c.g_strdup(uid);
    x.kind = kind;
    x.tags = null;
    x.start = NONE;
    x.stop = NONE;
    return @ptrCast(x);
}

fn findIn(list: [*c]c.GList, uid: [*c]const u8) ?*Entry {
    var node: ?*c.GList = list;
    while (node) |n| : (node = n.next) {
        const sub: *Entry = @ptrCast(@alignCast(n.data));
        if (c.g_strcmp0(e(sub).uid, uid) == 0) return sub;
        if (findIn(e(sub).subentries, uid)) |deep| return deep;
    }
    return null;
}

pub export fn gst_toc_find_entry(p: ?*const Toc, uid: [*c]const u8) ?*Entry {
    if (!check.that(p != null, "gst_toc_find_entry", "toc != NULL")) return null;
    if (!check.that(uid != null, "gst_toc_find_entry", "uid != NULL")) return null;
    return findIn(t(p).entries, uid);
}

pub export fn gst_toc_entry_set_start_stop_times(p: ?*Entry, start: c.gint64, stop: c.gint64) void {
    if (!check.that(p != null, "gst_toc_entry_set_start_stop_times", "entry != NULL")) return;
    e(p).start = @bitCast(start);
    e(p).stop = @bitCast(stop);
}

pub export fn gst_toc_entry_get_start_stop_times(p: ?*const Entry, start: [*c]c.gint64, stop: [*c]c.gint64) c.gboolean {
    if (!check.that(p != null, "gst_toc_entry_get_start_stop_times", "entry != NULL")) return 0;
    if (start != null) start.* = @bitCast(e(p).start);
    if (stop != null) stop.* = @bitCast(e(p).stop);
    return 1;
}

pub export fn gst_toc_entry_set_loop(p: ?*Entry, loop: c.GstTocLoopType, repeat: c.gint) void {
    if (!check.that(p != null, "gst_toc_entry_set_loop", "entry != NULL")) return;
    e(p).loop_type = loop;
    e(p).repeat_count = repeat;
}

pub export fn gst_toc_entry_get_loop(p: ?*const Entry, loop: [*c]c.GstTocLoopType, repeat: [*c]c.gint) c.gboolean {
    if (!check.that(p != null, "gst_toc_entry_get_loop", "entry != NULL")) return 0;
    if (loop != null) loop.* = e(p).loop_type;
    if (repeat != null) repeat.* = e(p).repeat_count;
    return 1;
}

pub export fn gst_toc_entry_type_get_nick(kind: c.GstTocEntryType) [*c]const u8 {
    return switch (kind) {
        c.GST_TOC_ENTRY_TYPE_ANGLE => "angle",
        c.GST_TOC_ENTRY_TYPE_VERSION => "version",
        c.GST_TOC_ENTRY_TYPE_EDITION => "edition",
        c.GST_TOC_ENTRY_TYPE_TITLE => "title",
        c.GST_TOC_ENTRY_TYPE_TRACK => "track",
        c.GST_TOC_ENTRY_TYPE_CHAPTER => "chapter",
        else => "invalid",
    };
}

pub export fn gst_toc_entry_get_entry_type(p: ?*const Entry) c.GstTocEntryType {
    if (!check.that(p != null, "gst_toc_entry_get_entry_type", "entry != NULL")) return c.GST_TOC_ENTRY_TYPE_INVALID;
    return e(p).kind;
}

pub export fn gst_toc_entry_is_alternative(p: ?*const Entry) c.gboolean {
    if (!check.that(p != null, "gst_toc_entry_is_alternative", "entry != NULL")) return 0;
    return @intFromBool(e(p).kind < 0);
}

pub export fn gst_toc_entry_is_sequence(p: ?*const Entry) c.gboolean {
    if (!check.that(p != null, "gst_toc_entry_is_sequence", "entry != NULL")) return 0;
    return @intFromBool(e(p).kind > 0);
}

pub export fn gst_toc_entry_get_uid(p: ?*const Entry) [*c]const u8 {
    if (!check.that(p != null, "gst_toc_entry_get_uid", "entry != NULL")) return null;
    return e(p).uid;
}

pub export fn gst_toc_entry_append_sub_entry(p: ?*Entry, sub: ?*Entry) void {
    const f = "gst_toc_entry_append_sub_entry";
    if (!check.that(p != null, f, "entry != NULL")) return;
    if (!check.that(sub != null, f, "subentry != NULL")) return;
    if (!check.that(writable(p), f, "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (entry))")) return;
    if (!check.that(writable(sub), f, "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (subentry))")) return;
    if (!check.that(e(sub).toc == null, f, "subentry->toc == NULL")) return;
    if (!check.that(e(sub).parent == null, f, "subentry->parent == NULL")) return;
    e(p).subentries = c.g_list_append(e(p).subentries, sub);
    e(sub).toc = e(p).toc;
    e(sub).parent = p;
}

pub export fn gst_toc_entry_get_sub_entries(p: ?*const Entry) [*c]c.GList {
    if (!check.that(p != null, "gst_toc_entry_get_sub_entries", "entry != NULL")) return null;
    return e(p).subentries;
}

pub export fn gst_toc_entry_set_tags(p: ?*Entry, tags: [*c]TagList) void {
    if (!check.that(p != null, "gst_toc_entry_set_tags", "entry != NULL")) return;
    if (!check.that(writable(p), "gst_toc_entry_set_tags", "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (entry))")) return;
    if (e(p).tags != null) c.gst_tag_list_unref(e(p).tags);
    e(p).tags = tags;
}

pub export fn gst_toc_entry_merge_tags(p: ?*Entry, tags: [*c]TagList, mode: c.GstTagMergeMode) void {
    if (!check.that(p != null, "gst_toc_entry_merge_tags", "entry != NULL")) return;
    if (!check.that(writable(p), "gst_toc_entry_merge_tags", "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (entry))")) return;
    merge(&e(p).tags, tags, mode);
}

pub export fn gst_toc_entry_get_tags(p: ?*const Entry) [*c]TagList {
    if (!check.that(p != null, "gst_toc_entry_get_tags", "entry != NULL")) return null;
    return e(p).tags;
}

pub export fn gst_toc_entry_get_toc(p: ?*Entry) ?*Toc {
    if (!check.that(p != null, "gst_toc_entry_get_toc", "entry != NULL")) return null;
    return e(p).toc;
}

pub export fn gst_toc_entry_get_parent(p: ?*Entry) ?*Entry {
    if (!check.that(p != null, "gst_toc_entry_get_parent", "entry != NULL")) return null;
    return e(p).parent;
}

fn dumpEntries(list: [*c]c.GList, depth: usize) void {
    var indent: [64]u8 = undefined;
    const n = @min(depth, indent.len - 1);
    @memset(indent[0..n], ' ');
    indent[n] = 0;
    var node: ?*c.GList = list;
    while (node) |item| : (node = item.next) {
        const x = e(item.data);
        const start = printf.timeAlloc(x.start);
        const stop = printf.timeAlloc(x.stop);
        defer c.g_free(start);
        defer c.g_free(stop);
        info.gst_debug_log(info.GST_CAT_DEFAULT, c.GST_LEVEL_LOG, "gst/toc.zig", "gst_toc_dump_entries", 0, null, "%s  - %s (%s), %s - %s, tags: %p\x07A", &indent, x.uid, gst_toc_entry_type_get_nick(x.kind), start, stop, x.tags);
        if (x.subentries != null) dumpEntries(x.subentries, depth + 2);
    }
}

pub export fn gst_toc_dump(p: ?*Toc) void {
    if (info.GST_CAT_DEFAULT == null or info.gst_debug_category_get_threshold(info.GST_CAT_DEFAULT) < c.GST_LEVEL_LOG) return;
    info.gst_debug_log(info.GST_CAT_DEFAULT, c.GST_LEVEL_LOG, "gst/toc.zig", "gst_toc_dump", 0, null, "       Toc %p, scope: %s, tags: %p\x07A", p, @as([*c]const u8, if (t(p).scope == c.GST_TOC_SCOPE_GLOBAL) "global" else "current"), t(p).tags);
    dumpEntries(t(p).entries, 2);
}
