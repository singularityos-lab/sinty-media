const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const streams = @import("streams.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Collection = c.GstStreamCollection;
const Stream = c.GstStream;

const Held = struct { stream: [*c]Stream, handler: c.gulong };

const Private = extern struct {
    items: ?*anyopaque,
};

const PROP_UPSTREAM_ID = 1;

var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var notify_signal: c.guint = 0;
var type_once: gtype.Once = .{};
var debug_cat: [*c]c.GstDebugCategory = null;

fn list(p: anytype) *std.ArrayListUnmanaged(Held) {
    const base: [*]u8 = @ptrCast(@constCast(p));
    const pv: *Private = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
    return @ptrCast(@alignCast(pv.items.?));
}

fn isCollection(p: anytype) bool {
    return gtype.instanceOf(p, gst_stream_collection_get_type());
}

pub export fn gst_stream_collection_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstStreamCollection", c.GstStreamCollectionClass, Collection, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            debug_cat = info._gst_debug_category_new("streamcollection", c.GST_DEBUG_BOLD, "debugging info for the stream collection objects");
            return t;
        }
    }.f);
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const col: *Collection = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(col);
    const pv: *Private = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
    col.priv = @ptrCast(pv);
    const items: *std.ArrayListUnmanaged(Held) = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(std.ArrayListUnmanaged(Held)))));
    items.* = .empty;
    pv.items = items;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    c.g_object_class_install_property(gc, PROP_UPSTREAM_ID, c.g_param_spec_string("upstream-id", "Upstream ID", "The stream ID of the parent stream", null, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS));
    notify_signal = c.g_signal_new("stream-notify", c.G_TYPE_FROM_CLASS(klass), c.G_SIGNAL_RUN_FIRST | c.G_SIGNAL_NO_RECURSE | c.G_SIGNAL_DETAILED | c.G_SIGNAL_NO_HOOKS, @offsetOf(c.GstStreamCollectionClass, "stream_notify"), null, null, null, c.G_TYPE_NONE, 2, streams.gst_stream_get_type(), c.G_TYPE_PARAM);
    gc.dispose = dispose;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const col: *Collection = @ptrCast(@alignCast(o));
    if (col.upstream_id != null) {
        c.g_free(col.upstream_id);
        col.upstream_id = null;
    }
    const pv: *Private = @ptrCast(@alignCast(col.priv));
    if (pv.items) |raw| {
        const items: *std.ArrayListUnmanaged(Held) = @ptrCast(@alignCast(raw));
        for (items.items) |h| {
            c.g_signal_handler_disconnect(h.stream, h.handler);
            object.gst_object_unref(h.stream);
        }
        items.deinit(std.heap.c_allocator);
        c.g_free(items);
        pv.items = null;
    }
    parent_class.?.dispose.?(o);
}

pub export fn gst_stream_collection_new(upstream: [*c]const u8) [*c]Collection {
    const col = c.g_object_new(gst_stream_collection_get_type(), "upstream-id", upstream, @as(?*anyopaque, null));
    _ = c.g_object_ref_sink(col);
    return @ptrCast(@alignCast(col));
}

fn setUpstream(col: *Collection, upstream: [*c]const u8) void {
    if (!check.that(col.upstream_id == null, "gst_stream_collection_set_upstream_id", "collection->upstream_id == NULL")) return;
    object.lock(col);
    if (upstream != null) col.upstream_id = c.g_strdup(upstream);
    c.g_free(col.object.name);
    col.object.name = c.g_strdup(if (upstream != null) upstream else "unparented");
    object.unlock(col);
}

pub export fn gst_stream_collection_get_upstream_id(col: [*c]Collection) [*c]const u8 {
    return col[0].upstream_id;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
    if (id == PROP_UPSTREAM_ID) setUpstream(@ptrCast(@alignCast(o)), c.g_value_get_string(v)) else object.warnBadProperty(o, id, pspec);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
    if (id == PROP_UPSTREAM_ID) c.g_value_set_string(v, gst_stream_collection_get_upstream_id(@ptrCast(@alignCast(o)))) else object.warnBadProperty(o, id, pspec);
}

fn onNotify(s: [*c]Stream, pspec: [*c]c.GParamSpec, weak: ?*c.GWeakRef) callconv(.c) void {
    const col = c.g_weak_ref_get(weak) orelse return;
    c.g_signal_emit(col, notify_signal, c.g_quark_from_string(pspec[0].name), s, pspec);
    object.gst_object_unref(col);
}

fn freeWeak(data: c.gpointer, _: ?*c.GClosure) callconv(.c) void {
    const weak: *c.GWeakRef = @ptrCast(@alignCast(data));
    c.g_weak_ref_clear(weak);
    c.g_free(weak);
}

pub export fn gst_stream_collection_add_stream(col: [*c]Collection, s: [*c]Stream) c.gboolean {
    if (!check.that(isCollection(col), "gst_stream_collection_add_stream", "GST_IS_STREAM_COLLECTION (collection)")) return 0;
    if (!check.that(gtype.instanceOf(s, streams.gst_stream_get_type()), "gst_stream_collection_add_stream", "GST_IS_STREAM (stream)")) return 0;
    const weak: *c.GWeakRef = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GWeakRef))));
    c.g_weak_ref_init(weak, col);
    const handler = c.g_signal_connect_data(s, "notify", @ptrCast(&onNotify), weak, freeWeak, 0);
    list(col).append(std.heap.c_allocator, .{ .stream = s, .handler = handler }) catch @panic("out of memory");
    return 1;
}

pub export fn gst_stream_collection_get_size(col: [*c]Collection) c.guint {
    if (!check.that(isCollection(col), "gst_stream_collection_get_size", "GST_IS_STREAM_COLLECTION (collection)")) return 0;
    return @intCast(list(col).items.len);
}

pub export fn gst_stream_collection_get_stream(col: [*c]Collection, idx: c.guint) [*c]Stream {
    if (!check.that(isCollection(col), "gst_stream_collection_get_stream", "GST_IS_STREAM_COLLECTION (collection)")) return null;
    const items = list(col).items;
    if (!check.that(idx < items.len, "gst_vec_deque_peek_nth_struct", "idx < array->length")) return null;
    return items[idx].stream;
}
