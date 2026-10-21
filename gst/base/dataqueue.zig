const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Queue = c.GstDataQueue;
const Item = c.GstDataQueueItem;

const Private = extern struct {
    queue: ?*c.GstVecDeque,
    level: c.GstDataQueueSize,
    checkfull: c.GstDataQueueCheckFullFunction,
    checkdata: c.gpointer,
    lock: c.GMutex,
    waiting_add: bool,
    item_add: c.GCond,
    waiting_del: bool,
    item_del: c.GCond,
    flushing: bool,
    fullcallback: c.GstDataQueueFullCallback,
    emptycallback: c.GstDataQueueEmptyCallback,
};

const PROP_VISIBLE = 1;
const PROP_BYTES = 2;
const PROP_TIME = 3;

var type_once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;
var empty_signal: c.guint = 0;
var full_signal: c.guint = 0;

fn priv(q: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Queue, @ptrCast(@alignCast(q)))[0].priv));
}

fn isQueue(q: anytype) bool {
    return gtype.instanceOf(q, gst_data_queue_get_type());
}

pub export fn gst_data_queue_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.g_object_get_type, "GstDataQueue", c.GstDataQueueClass, Queue, classInit, init, 0);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            _ = c._gst_debug_category_new("dataqueue", 0, "data queue object");
            _ = c._gst_debug_category_new("data_queue_dataflow", 0, "dataflow inside the data queue object");
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &offset);
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.set_property = setProp;
    gc.get_property = getProp;
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    empty_signal = c.g_signal_new("empty", t, c.G_SIGNAL_RUN_FIRST, @offsetOf(c.GstDataQueueClass, "empty"), null, null, null, 1 << c.G_TYPE_FUNDAMENTAL_SHIFT, @as(c.guint, 0));
    full_signal = c.g_signal_new("full", t, c.G_SIGNAL_RUN_FIRST, @offsetOf(c.GstDataQueueClass, "full"), null, null, null, 1 << c.G_TYPE_FUNDAMENTAL_SHIFT, @as(c.guint, 0));
    const fl = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, PROP_BYTES, c.g_param_spec_uint("current-level-bytes", "Current level (kB)", "Current amount of data in the queue (bytes)", 0, std.math.maxInt(c.guint), 0, fl));
    c.g_object_class_install_property(gc, PROP_VISIBLE, c.g_param_spec_uint("current-level-visible", "Current level (visible items)", "Current number of visible items in the queue", 0, std.math.maxInt(c.guint), 0, fl));
    c.g_object_class_install_property(gc, PROP_TIME, c.g_param_spec_uint64("current-level-time", "Current level (ns)", "Current amount of data in the queue (in ns)", 0, std.math.maxInt(u64), 0, fl));
    gc.finalize = finalize;
}

fn init(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const base: [*]u8 = @ptrCast(instance);
    const p: *Private = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
    @as([*c]Queue, @ptrCast(@alignCast(instance)))[0].priv = @ptrCast(p);
    p.* = std.mem.zeroes(Private);
    c.g_mutex_init(&p.lock);
    c.g_cond_init(&p.item_add);
    c.g_cond_init(&p.item_del);
    p.queue = c.gst_vec_deque_new(50);
}

fn cleanup(p: *Private) void {
    while (c.gst_vec_deque_is_empty(p.queue) == 0) {
        const item: [*c]Item = @ptrCast(@alignCast(c.gst_vec_deque_pop_head(p.queue)));
        item[0].destroy.?(item);
    }
    p.level = std.mem.zeroes(c.GstDataQueueSize);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p = priv(o);
    cleanup(p);
    c.gst_vec_deque_free(p.queue);
    c.g_mutex_clear(&p.lock);
    c.g_cond_clear(&p.item_add);
    c.g_cond_clear(&p.item_del);
    parent.?.finalize.?(o);
}

pub export fn gst_data_queue_new(checkfull: c.GstDataQueueCheckFullFunction, fullcb: c.GstDataQueueFullCallback, emptycb: c.GstDataQueueEmptyCallback, data: c.gpointer) [*c]Queue {
    if (!check.that(checkfull != null, "gst_data_queue_new", "checkfull != NULL")) return null;
    const q: [*c]Queue = @ptrCast(@alignCast(c.g_object_new(gst_data_queue_get_type(), null)));
    const p = priv(q);
    p.checkfull = checkfull;
    p.checkdata = data;
    p.fullcallback = fullcb;
    p.emptycallback = emptycb;
    return q;
}

fn empty(p: *Private) bool {
    return c.gst_vec_deque_get_length(p.queue) == 0;
}

fn full(q: [*c]Queue, p: *Private) bool {
    return p.checkfull.?(q, p.level.visible, p.level.bytes, p.level.time, p.checkdata) != 0;
}

pub export fn gst_data_queue_flush(q: [*c]Queue) void {
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    cleanup(p);
    if (p.waiting_del) c.g_cond_signal(&p.item_del);
}

pub export fn gst_data_queue_is_empty(q: [*c]Queue) c.gboolean {
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    return @intFromBool(empty(p));
}

pub export fn gst_data_queue_is_full(q: [*c]Queue) c.gboolean {
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    return @intFromBool(full(q, p));
}

pub export fn gst_data_queue_set_flushing(q: [*c]Queue, flushing: c.gboolean) void {
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    p.flushing = flushing != 0;
    if (!p.flushing) return;
    if (p.waiting_add) c.g_cond_signal(&p.item_add);
    if (p.waiting_del) c.g_cond_signal(&p.item_del);
}

fn add(p: *Private, item: [*c]Item) void {
    c.gst_vec_deque_push_tail(p.queue, item);
    if (item[0].visible != 0) p.level.visible += 1;
    p.level.bytes +%= item[0].size;
    p.level.time +%= item[0].duration;
}

pub export fn gst_data_queue_push_force(q: [*c]Queue, item: [*c]Item) c.gboolean {
    if (!check.that(isQueue(q), "gst_data_queue_push_force", "GST_IS_DATA_QUEUE (queue)")) return 0;
    if (!check.that(item != null, "gst_data_queue_push_force", "item != NULL")) return 0;
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    if (p.flushing) return 0;
    add(p, item);
    if (p.waiting_add) c.g_cond_signal(&p.item_add);
    return 1;
}

pub export fn gst_data_queue_push(q: [*c]Queue, item: [*c]Item) c.gboolean {
    if (!check.that(isQueue(q), "gst_data_queue_push", "GST_IS_DATA_QUEUE (queue)")) return 0;
    if (!check.that(item != null, "gst_data_queue_push", "item != NULL")) return 0;
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    if (p.flushing) {
        c.g_mutex_unlock(&p.lock);
        return 0;
    }
    if (full(q, p)) {
        c.g_mutex_unlock(&p.lock);
        if (p.fullcallback) |f| f(q, p.checkdata) else c.g_signal_emit(q, full_signal, 0);
        c.g_mutex_lock(&p.lock);
        if (p.flushing) {
            c.g_mutex_unlock(&p.lock);
            return 0;
        }
        while (full(q, p)) {
            p.waiting_del = true;
            c.g_cond_wait(&p.item_del, &p.lock);
            p.waiting_del = false;
            if (p.flushing) {
                c.g_mutex_unlock(&p.lock);
                return 0;
            }
        }
    }
    add(p, item);
    if (p.waiting_add) c.g_cond_signal(&p.item_add);
    c.g_mutex_unlock(&p.lock);
    return 1;
}

fn waitItem(q: [*c]Queue, p: *Private) bool {
    if (p.flushing) return false;
    if (!empty(p)) return true;
    c.g_mutex_unlock(&p.lock);
    if (p.emptycallback) |f| f(q, p.checkdata) else c.g_signal_emit(q, empty_signal, 0);
    c.g_mutex_lock(&p.lock);
    if (p.flushing) return false;
    while (empty(p)) {
        p.waiting_add = true;
        c.g_cond_wait(&p.item_add, &p.lock);
        p.waiting_add = false;
        if (p.flushing) return false;
    }
    return true;
}

pub export fn gst_data_queue_pop(q: [*c]Queue, item: [*c][*c]Item) c.gboolean {
    if (!check.that(isQueue(q), "gst_data_queue_pop", "GST_IS_DATA_QUEUE (queue)")) return 0;
    if (!check.that(item != null, "gst_data_queue_pop", "item != NULL")) return 0;
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    if (!waitItem(q, p)) return 0;
    const it: [*c]Item = @ptrCast(@alignCast(c.gst_vec_deque_pop_head(p.queue)));
    item.* = it;
    if (it[0].visible != 0) p.level.visible -%= 1;
    p.level.bytes -%= it[0].size;
    p.level.time -%= it[0].duration;
    if (p.waiting_del) c.g_cond_signal(&p.item_del);
    return 1;
}

pub export fn gst_data_queue_peek(q: [*c]Queue, item: [*c][*c]Item) c.gboolean {
    if (!check.that(isQueue(q), "gst_data_queue_peek", "GST_IS_DATA_QUEUE (queue)")) return 0;
    if (!check.that(item != null, "gst_data_queue_peek", "item != NULL")) return 0;
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    if (!waitItem(q, p)) return 0;
    item.* = @ptrCast(@alignCast(c.gst_vec_deque_peek_head(p.queue)));
    return 1;
}

fn notOfType(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const it: *const Item = @ptrCast(@alignCast(a));
    if (it.object != null and it.object[0].type == @intFromPtr(b)) return 0;
    return @intFromBool(c.g_type_check_instance_is_a(@ptrCast(@alignCast(@constCast(a))), @intFromPtr(b)) == 0);
}

pub export fn gst_data_queue_drop_head(q: [*c]Queue, t: c.GType) c.gboolean {
    if (!check.that(isQueue(q), "gst_data_queue_drop_head", "GST_IS_DATA_QUEUE (queue)")) return 0;
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    const idx: c.guint = @truncate(c.gst_vec_deque_find(p.queue, notOfType, @ptrFromInt(t)));
    if (idx == std.math.maxInt(c.guint)) return 0;
    const it: [*c]Item = @ptrCast(@alignCast(c.gst_vec_deque_drop_element(p.queue, idx)));
    if (it[0].visible != 0) p.level.visible -%= 1;
    p.level.bytes -%= it[0].size;
    p.level.time -%= it[0].duration;
    it[0].destroy.?(it);
    return 1;
}

pub export fn gst_data_queue_limits_changed(q: [*c]Queue) void {
    if (!check.that(isQueue(q), "gst_data_queue_limits_changed", "GST_IS_DATA_QUEUE (queue)")) return;
    const p = priv(q);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    if (p.waiting_del) c.g_cond_signal(&p.item_del);
}

pub export fn gst_data_queue_get_level(q: [*c]Queue, level: [*c]c.GstDataQueueSize) void {
    level.* = priv(q).level;
}

fn setProp(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    @import("el.zig").badProperty(o, id, pspec, "gstdataqueue.c", 782);
}

fn getProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = priv(o);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    switch (id) {
        PROP_BYTES => c.g_value_set_uint(v, p.level.bytes),
        PROP_VISIBLE => c.g_value_set_uint(v, p.level.visible),
        PROP_TIME => c.g_value_set_uint64(v, p.level.time),
        else => @import("el.zig").badProperty(o, id, pspec, "gstdataqueue.c", 807),
    }
}
