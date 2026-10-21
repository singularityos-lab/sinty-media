const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const el = @import("el.zig");

pub const ENTRY_ID: c_int = 0;
pub const ENTRY_ASSOCIATION: c_int = 1;
pub const LOOKUP_EXACT: c_int = 0;
pub const LOOKUP_BEFORE: c_int = 1;
pub const LOOKUP_AFTER: c_int = 2;
pub const KEY_UNIT: c_int = 1 << 0;
pub const DELTA_UNIT: c_int = 1 << 1;
const WRITABLE: c.guint32 = c.GST_OBJECT_FLAG_LAST << 0;
const READABLE: c.guint32 = c.GST_OBJECT_FLAG_LAST << 1;
const RESOLVER_PATH: c_int = 2;

pub const Assoc = extern struct {
    format: c.GstFormat,
    value: i64,
};

pub const Entry = extern struct {
    type: c_int,
    id: c.gint,
    data: extern union {
        id: extern struct { description: [*c]u8 },
        assoc: extern struct { nassocs: c.gint, assocs: [*c]Assoc, flags: c_int },
        object: extern struct { key: [*c]u8, type: c.GType, object: c.gpointer },
        format: extern struct { format: c.GstFormat, key: [*c]const u8 },
    },
};

const Group = extern struct {
    groupnum: c.gint,
    entries: ?*c.GList,
    certainty: c_int,
    peergroup: c.gint,
};

pub const Index = extern struct {
    object: c.GstObject,
    groups: ?*c.GList,
    curgroup: *Group,
    maxgroup: c.gint,
    method: c_int,
    resolver: c.gpointer,
    resolver_user_data: c.gpointer,
    resolver_user_data_destroy: c.GDestroyNotify,
    filter: c.gpointer,
    filter_user_data: c.gpointer,
    filter_user_data_destroy: c.GDestroyNotify,
    writers: ?*c.GHashTable,
    last_id: c.gint,
    reserved: [4]c.gpointer,
};

const Class = extern struct {
    parent: c.GstObjectClass,
    get_writer_id: c.gpointer,
    commit: c.gpointer,
    add_entry: c.gpointer,
    get_assoc_entry: c.gpointer,
    entry_added: c.gpointer,
    reserved: [4]c.gpointer,
};

const Mem = extern struct {
    parent: Index,
    associations: ?*c.GList,
    id_index: ?*c.GHashTable,
};

const FormatIndex = extern struct {
    format: c.GstFormat,
    offset: c.gint,
    tree: ?*c.GTree,
};

const IdIndex = extern struct {
    id: c.gint,
    format_index: ?*c.GHashTable,
};

var index_once: gtype.Once = .{};
var mem_once: gtype.Once = .{};
var entry_once: gtype.Once = .{};
var resolver_once: gtype.Once = .{};
var index_parent: ?*c.GObjectClass = null;
var mem_parent: ?*c.GObjectClass = null;
var entry_added: c.guint = 0;

fn resolverType() c.GType {
    return resolver_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "GST_INDEX_RESOLVER_CUSTOM", .value_nick = "custom" },
            .{ .value = 1, .value_name = "GST_INDEX_RESOLVER_GTYPE", .value_nick = "gtype" },
            .{ .value = 2, .value_name = "GST_INDEX_RESOLVER_PATH", .value_nick = "path" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstIndexResolver", &values);
        }
    }.f);
}

fn entryCopy(p: c.gpointer) callconv(.c) c.gpointer {
    const n: *Entry = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Entry))));
    n.* = @as(*Entry, @ptrCast(@alignCast(p))).*;
    return n;
}

pub fn entryFree(e: *Entry) void {
    switch (e.type) {
        ENTRY_ID => if (e.data.id.description != null) {
            c.g_free(e.data.id.description);
            e.data.id.description = null;
        },
        ENTRY_ASSOCIATION => if (e.data.assoc.assocs != null) {
            c.g_free(e.data.assoc.assocs);
            e.data.assoc.assocs = null;
        },
        else => {},
    }
    c.g_free(e);
}

fn entryFreeFn(p: c.gpointer) callconv(.c) void {
    entryFree(@ptrCast(@alignCast(p)));
}

fn entryType() c.GType {
    return entry_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstIndexEntry", entryCopy, entryFreeFn);
        }
    }.f);
}

fn freeWriter(_: c.gpointer, v: c.gpointer, _: c.gpointer) callconv(.c) void {
    if (v != null) entryFree(@ptrCast(@alignCast(v)));
}

fn freeGroup(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_free(g);
}

fn indexFinalize(o: [*c]c.GObject) callconv(.c) void {
    const x: *Index = @ptrCast(@alignCast(o));
    if (x.groups != null) {
        c.g_list_foreach(x.groups, freeGroup, null);
        c.g_list_free(x.groups);
        x.groups = null;
    }
    if (x.writers != null) {
        c.g_hash_table_foreach(x.writers, freeWriter, null);
        c.g_hash_table_destroy(x.writers);
        x.writers = null;
    }
    index_parent.?.finalize.?(o);
}

fn indexSetProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badProperty(o, id, pspec, "gstindex.c", 249);
    @as(*Index, @ptrCast(@alignCast(o))).method = c.g_value_get_enum(v);
}

fn indexGetProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badProperty(o, id, pspec, "gstindex.c", 267);
    c.g_value_set_enum(v, @as(*Index, @ptrCast(@alignCast(o))).method);
}

fn indexClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    index_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    entry_added = c.g_signal_new("entry-added", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "entry_added"), null, null, null, 1 << c.G_TYPE_FUNDAMENTAL_SHIFT, @as(c.guint, 1), entryType());
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = indexSetProp;
    gc.get_property = indexGetProp;
    gc.finalize = indexFinalize;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_enum("resolver", "Resolver", "Select a predefined object to string mapper", resolverType(), RESOLVER_PATH, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
}

fn indexInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const x: *Index = @ptrCast(@alignCast(instance));
    const g: *Group = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Group))));
    g.* = .{ .groupnum = 0, .entries = null, .certainty = 0, .peergroup = -1 };
    x.curgroup = g;
    x.maxgroup = 0;
    x.groups = c.g_list_prepend(null, g);
    x.writers = c.g_hash_table_new(null, null);
    x.last_id = 0;
    x.method = RESOLVER_PATH;
    el.setFlag(x, WRITABLE);
    el.setFlag(x, READABLE);
}

fn indexType() c.GType {
    return index_once.get(struct {
        fn f() c.GType {
            return gtype.object(c.gst_object_get_type(), "GstIndex", Class, Index, indexClassInit, indexInit, 0);
        }
    }.f);
}

fn writable(x: *Index) bool {
    return el.flags(x) & WRITABLE != 0;
}

fn emitAdded(x: *Index, e: *Entry) void {
    memAddEntry(@ptrCast(x), e);
    c.g_signal_emit(x, entry_added, 0, e);
}

fn resolve(x: *Index, writer: [*c]c.GstObject) ?[*c]u8 {
    switch (x.method) {
        RESOLVER_PATH => return c.gst_object_get_path_string(writer),
        1 => {
            if (gtype.instanceOf(writer, c.gst_pad_get_type())) {
                const parent = c.gst_object_get_parent(writer);
                const name = c.gst_object_get_name(writer);
                if (parent == null) return name;
                defer c.gst_object_unref(parent);
                defer c.g_free(name);
                return c.g_strdup_printf("%s.%s", c.g_type_name(gtype.typeOf(parent)), name);
            }
            return c.g_strdup(c.g_type_name(gtype.typeOf(writer)));
        },
        else => {
            c.g_log(null, c.G_LOG_LEVEL_WARNING, "no resolver found");
            return null;
        },
    }
}

pub fn writerId(x: *Index, writer: [*c]c.GstObject, id: *c.gint) bool {
    id.* = -1;
    const found: ?*Entry = @ptrCast(@alignCast(c.g_hash_table_lookup(x.writers, writer)));
    if (found) |e| {
        id.* = e.id;
        return true;
    }
    const desc = resolve(x, writer) orelse return false;
    x.last_id += 1;
    id.* = x.last_id;
    const e: *Entry = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Entry))));
    e.type = ENTRY_ID;
    e.id = id.*;
    e.data.id.description = desc;
    if (writable(x)) emitAdded(x, e);
    _ = c.g_hash_table_insert(x.writers, writer, e);
    return true;
}

pub fn addAssociations(x: *Index, id: c.gint, flags: c_int, list: []const Assoc) void {
    if (!writable(x) or id == -1) return;
    const e: *Entry = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Entry))));
    e.type = ENTRY_ASSOCIATION;
    e.id = id;
    e.data.assoc.flags = flags;
    e.data.assoc.assocs = @ptrCast(@alignCast(c.g_memdup2(list.ptr, @sizeOf(Assoc) * list.len)));
    e.data.assoc.nassocs = @intCast(list.len);
    emitAdded(x, e);
}

pub fn assocMap(e: *Entry, format: c.GstFormat, value: *i64) bool {
    var i: usize = 0;
    while (i < @as(usize, @intCast(e.data.assoc.nassocs))) : (i += 1) {
        if (e.data.assoc.assocs[i].format == format) {
            value.* = e.data.assoc.assocs[i].value;
            return true;
        }
    }
    return false;
}

fn memFinalizeFormat(_: c.gpointer, v: c.gpointer, _: c.gpointer) callconv(.c) void {
    const fi: *FormatIndex = @ptrCast(@alignCast(v));
    if (fi.tree != null) c.g_tree_destroy(fi.tree);
    c.g_free(fi);
}

fn memFinalizeId(_: c.gpointer, v: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ii: *IdIndex = @ptrCast(@alignCast(v));
    if (ii.format_index != null) {
        c.g_hash_table_foreach(ii.format_index, memFinalizeFormat, null);
        c.g_hash_table_destroy(ii.format_index);
        ii.format_index = null;
    }
    c.g_free(ii);
}

fn memFreeAssoc(e: c.gpointer, _: c.gpointer) callconv(.c) void {
    entryFree(@ptrCast(@alignCast(e)));
}

fn memFinalize(o: [*c]c.GObject) callconv(.c) void {
    const m: *Mem = @ptrCast(@alignCast(o));
    if (m.id_index != null) {
        c.g_hash_table_foreach(m.id_index, memFinalizeId, null);
        c.g_hash_table_destroy(m.id_index);
        m.id_index = null;
    }
    if (m.associations != null) {
        c.g_list_foreach(m.associations, memFreeAssoc, null);
        c.g_list_free(m.associations);
        m.associations = null;
    }
    mem_parent.?.finalize.?(o);
}

fn assocValue(e: c.gconstpointer, off: c.gint) i64 {
    const x: *const Entry = @ptrCast(@alignCast(e));
    return x.data.assoc.assocs[@intCast(off)].value;
}

fn treeCompare(a: c.gconstpointer, b: c.gconstpointer, data: c.gpointer) callconv(.c) c.gint {
    const fi: *FormatIndex = @ptrCast(@alignCast(data));
    const diff = assocValue(b, fi.offset) -% assocValue(a, fi.offset);
    return if (diff == 0) 0 else if (diff > 0) 1 else -1;
}

fn memAddEntry(x: *Mem, e: *Entry) void {
    switch (e.type) {
        ENTRY_ID => {
            if (c.g_hash_table_lookup(x.id_index, &e.id) != null) return;
            const ii: *IdIndex = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(IdIndex))));
            ii.id = e.id;
            ii.format_index = c.g_hash_table_new(c.g_int_hash, c.g_int_equal);
            _ = c.g_hash_table_insert(x.id_index, &ii.id, ii);
        },
        ENTRY_ASSOCIATION => {
            x.associations = c.g_list_prepend(x.associations, e);
            const ii: *IdIndex = @ptrCast(@alignCast(c.g_hash_table_lookup(x.id_index, &e.id) orelse return));
            var i: c.gint = 0;
            while (i < e.data.assoc.nassocs) : (i += 1) {
                const fmt = &e.data.assoc.assocs[@intCast(i)].format;
                var fi: ?*FormatIndex = @ptrCast(@alignCast(c.g_hash_table_lookup(ii.format_index, fmt)));
                if (fi == null) {
                    const n: *FormatIndex = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(FormatIndex))));
                    n.format = fmt.*;
                    n.offset = i;
                    n.tree = c.g_tree_new_with_data(treeCompare, n);
                    _ = c.g_hash_table_insert(ii.format_index, &n.format, n);
                    fi = n;
                }
                c.g_tree_insert(fi.?.tree, e, e);
            }
        },
        else => {},
    }
}

const Search = struct {
    value: i64,
    index: *FormatIndex,
    exact: bool,
    lower: ?*Entry = null,
    low_diff: i64 = std.math.minInt(i64),
    higher: ?*Entry = null,
    high_diff: i64 = std.math.maxInt(i64),
};

fn treeSearch(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const s: *Search = @ptrCast(@alignCast(@constCast(b)));
    const diff = assocValue(a, s.index.offset) -% s.value;
    if (diff == 0) return 0;
    if (s.exact) return if (diff > 0) 1 else -1;
    if (diff < 0) {
        if (diff > s.low_diff) {
            s.low_diff = diff;
            s.lower = @ptrCast(@alignCast(@constCast(a)));
        }
        return -1;
    }
    if (diff < s.high_diff) {
        s.high_diff = diff;
        s.higher = @ptrCast(@alignCast(@constCast(a)));
    }
    return 1;
}

fn hasFlags(e: *Entry, flags: c_int) bool {
    return e.data.assoc.flags & flags == flags;
}

pub fn assocEntry(x: *Index, id: c.gint, method: c_int, flags: c_int, format: c.GstFormat, v: i64) ?*Entry {
    if (id == -1) return null;
    const m: *Mem = @ptrCast(x);
    var key = id;
    const ii: *IdIndex = @ptrCast(@alignCast(c.g_hash_table_lookup(m.id_index, &key) orelse return null));
    var fkey = format;
    const fi: *FormatIndex = @ptrCast(@alignCast(c.g_hash_table_lookup(ii.format_index, &fkey) orelse return null));
    var s = Search{ .value = v, .index = fi, .exact = method == LOOKUP_EXACT };
    var e: ?*Entry = @ptrCast(@alignCast(c.g_tree_search(fi.tree, treeSearch, &s)));
    if (e == null and !s.exact) {
        if (method == LOOKUP_BEFORE) e = s.lower else if (method == LOOKUP_AFTER) e = s.higher;
    }
    const found = e orelse return null;
    if (hasFlags(found, flags)) return found;
    if (method == LOOKUP_EXACT) return null;
    var l = c.g_list_find(m.associations, found);
    e = null;
    while (l != null) {
        const cand: *Entry = @ptrCast(@alignCast(l[0].data));
        e = cand;
        if (cand.id == id and hasFlags(cand, flags)) break;
        l = if (method == LOOKUP_BEFORE) l[0].next else l[0].prev;
    }
    return e;
}

fn memClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    mem_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = memFinalize;
}

fn memInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const m: *Mem = @ptrCast(@alignCast(instance));
    m.associations = null;
    m.id_index = c.g_hash_table_new(c.g_int_hash, c.g_int_equal);
}

fn memType() c.GType {
    return mem_once.get(struct {
        fn f() c.GType {
            return gtype.object(indexType(), "GstMemIndex", Class, Mem, memClassInit, memInit, 0);
        }
    }.f);
}

pub fn newMem() *Index {
    return @ptrCast(@alignCast(c.g_object_new(memType(), null)));
}
