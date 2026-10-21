const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("el.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Pads = c.GstCollectPads;
const Data = c.GstCollectData;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const NONE = el.NONE;

const EOS: c_uint = c.GST_COLLECT_PADS_STATE_EOS;
const FLUSHING: c_uint = c.GST_COLLECT_PADS_STATE_FLUSHING;
const NEW_SEGMENT: c_uint = c.GST_COLLECT_PADS_STATE_NEW_SEGMENT;
const WAITING: c_uint = c.GST_COLLECT_PADS_STATE_WAITING;
const LOCKED: c_uint = c.GST_COLLECT_PADS_STATE_LOCKED;

const DataPriv = extern struct {
    destroy_notify: c.GstCollectDataDestroyNotify,
    refcount: c.gint,
};

const Private = extern struct {
    started: bool,
    cookie: c.guint32,
    numpads: c.guint,
    queuedpads: c.guint,
    eospads: c.guint,
    earliest_time: c.GstClockTime,
    earliest_data: [*c]Data,
    pad_list: [*c]c.GSList,
    pad_cookie: c.guint32,
    func: c.GstCollectPadsFunction,
    user_data: c.gpointer,
    buffer_func: c.GstCollectPadsBufferFunction,
    buffer_user_data: c.gpointer,
    compare_func: c.GstCollectPadsCompareFunction,
    compare_user_data: c.gpointer,
    event_func: c.GstCollectPadsEventFunction,
    event_user_data: c.gpointer,
    query_func: c.GstCollectPadsQueryFunction,
    query_user_data: c.gpointer,
    clip_func: c.GstCollectPadsClipFunction,
    clip_user_data: c.gpointer,
    flush_func: c.GstCollectPadsFlushFunction,
    flush_user_data: c.gpointer,
    evt_lock: c.GMutex,
    evt_cond: c.GCond,
    evt_cookie: c.guint32,
    seeking: c.gint,
    pending_flush_start: c.gint,
    pending_flush_stop: c.gint,
};

var once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Pads, @ptrCast(@alignCast(p)))[0].priv));
}

fn dp(d: [*c]Data) *DataPriv {
    return @ptrCast(@alignCast(d[0].priv));
}

fn isPads(p: anytype) bool {
    return gtype.instanceOf(p, gst_collect_pads_get_type());
}

fn has(d: [*c]Data, f: c_uint) bool {
    return d[0].state & f != 0;
}

fn set(d: [*c]Data, f: c_uint) void {
    d[0].state |= f;
}

fn unset(d: [*c]Data, f: c_uint) void {
    d[0].state &= ~f;
}

fn streamLock(p: [*c]Pads) void {
    c.g_rec_mutex_lock(&p[0].stream_lock);
}

fn streamUnlock(p: [*c]Pads) void {
    c.g_rec_mutex_unlock(&p[0].stream_lock);
}

fn broadcast(p: [*c]Pads) void {
    const r = priv(p);
    c.g_mutex_lock(&r.evt_lock);
    r.evt_cookie +%= 1;
    c.g_cond_broadcast(&r.evt_cond);
    c.g_mutex_unlock(&r.evt_lock);
}

fn cookieNow(p: [*c]Pads) c.guint32 {
    const r = priv(p);
    c.g_mutex_lock(&r.evt_lock);
    defer c.g_mutex_unlock(&r.evt_lock);
    return r.evt_cookie;
}

fn waitCookie(p: [*c]Pads, cookie: c.guint32) void {
    const r = priv(p);
    c.g_mutex_lock(&r.evt_lock);
    while (cookie == r.evt_cookie) c.g_cond_wait(&r.evt_cond, &r.evt_lock);
    c.g_mutex_unlock(&r.evt_lock);
}

fn refData(d: [*c]Data) void {
    _ = @atomicRmw(c.gint, &dp(d).refcount, .Add, 1, .seq_cst);
}

fn unrefData(d: [*c]Data) void {
    if (@atomicRmw(c.gint, &dp(d).refcount, .Sub, 1, .seq_cst) != 1) return;
    if (dp(d).destroy_notify) |f| f(d);
    c.gst_object_unref(d[0].pad);
    if (d[0].buffer != null) c.gst_buffer_unref(d[0].buffer);
    c.g_free(d[0].priv);
    c.g_free(d);
}

fn unrefFunc(d: c.gpointer, _: c.gpointer) callconv(.c) void {
    unrefData(@ptrCast(@alignCast(d)));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p: [*c]Pads = @ptrCast(@alignCast(o));
    const r = priv(p);
    c.g_rec_mutex_clear(&p[0].stream_lock);
    c.g_cond_clear(&r.evt_cond);
    c.g_mutex_clear(&r.evt_lock);
    c.g_slist_foreach(r.pad_list, unrefFunc, null);
    c.g_slist_foreach(p[0].data, unrefFunc, null);
    c.g_slist_free(p[0].data);
    c.g_slist_free(r.pad_list);
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("collectpads", 0, "GstCollectPads");
    if (offset != 0) c.g_type_class_adjust_private_offset(k, &offset);
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Pads = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    p[0].priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
    const r = priv(p);
    p[0].data = null;
    r.* = std.mem.zeroes(Private);
    c.g_rec_mutex_init(&p[0].stream_lock);
    r.func = defaultCollected;
    r.compare_func = defaultCompare;
    r.earliest_time = NONE;
    r.event_func = eventDefaultInternal;
    r.query_func = queryDefaultInternal;
    c.g_mutex_init(&r.evt_lock);
    c.g_cond_init(&r.evt_cond);
}

pub export fn gst_collect_pads_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstCollectPads", c.GstCollectPadsClass, Pads, classInit, init, 0);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

pub export fn gst_collect_pads_new() [*c]Pads {
    const p: [*c]Pads = @ptrCast(@alignCast(c.g_object_new(gst_collect_pads_get_type(), null)));
    _ = c.gst_object_ref_sink(p);
    return p;
}

fn guard(p: [*c]Pads, comptime func: []const u8) bool {
    if (!check.that(p != null, func, "pads != NULL")) return false;
    return check.that(isPads(p), func, "GST_IS_COLLECT_PADS (pads)");
}

pub export fn gst_collect_pads_set_buffer_function(p: [*c]Pads, func: c.GstCollectPadsBufferFunction, data: c.gpointer) void {
    if (!guard(p, "gst_collect_pads_set_buffer_function")) return;
    el.lock(p);
    priv(p).buffer_func = func;
    priv(p).buffer_user_data = data;
    el.unlock(p);
}

pub export fn gst_collect_pads_set_compare_function(p: [*c]Pads, func: c.GstCollectPadsCompareFunction, data: c.gpointer) void {
    if (!guard(p, "gst_collect_pads_set_compare_function")) return;
    el.lock(p);
    priv(p).compare_func = func;
    priv(p).compare_user_data = data;
    el.unlock(p);
}

pub export fn gst_collect_pads_set_function(p: [*c]Pads, func: c.GstCollectPadsFunction, data: c.gpointer) void {
    if (!guard(p, "gst_collect_pads_set_function")) return;
    el.lock(p);
    priv(p).func = func;
    priv(p).user_data = data;
    priv(p).buffer_func = null;
    priv(p).buffer_user_data = null;
    el.unlock(p);
}

pub export fn gst_collect_pads_set_event_function(p: [*c]Pads, func: c.GstCollectPadsEventFunction, data: c.gpointer) void {
    if (!guard(p, "gst_collect_pads_set_event_function")) return;
    el.lock(p);
    priv(p).event_func = func;
    priv(p).event_user_data = data;
    el.unlock(p);
}

pub export fn gst_collect_pads_set_query_function(p: [*c]Pads, func: c.GstCollectPadsQueryFunction, data: c.gpointer) void {
    if (!guard(p, "gst_collect_pads_set_query_function")) return;
    el.lock(p);
    priv(p).query_func = func;
    priv(p).query_user_data = data;
    el.unlock(p);
}

pub export fn gst_collect_pads_set_clip_function(p: [*c]Pads, func: c.GstCollectPadsClipFunction, data: c.gpointer) void {
    if (!guard(p, "gst_collect_pads_set_clip_function")) return;
    priv(p).clip_func = func;
    priv(p).clip_user_data = data;
}

pub export fn gst_collect_pads_set_flush_function(p: [*c]Pads, func: c.GstCollectPadsFlushFunction, data: c.gpointer) void {
    if (!guard(p, "gst_collect_pads_set_flush_function")) return;
    priv(p).flush_func = func;
    priv(p).flush_user_data = data;
}

pub export fn gst_collect_pads_clip_running_time(_: [*c]Pads, d: [*c]Data, b: [*c]Buffer, out: [*c][*c]Buffer, _: c.gpointer) c.GstFlowReturn {
    out.* = b;
    const ts = if (b[0].dts != NONE) b[0].dts else b[0].pts;
    if (ts == NONE) return c.GST_FLOW_OK;
    var time = b[0].pts;
    if (time != NONE) {
        time = c.gst_segment_to_running_time(&d[0].segment, c.GST_FORMAT_TIME, time);
        if (time == NONE) {
            c.gst_buffer_unref(b);
            out.* = null;
            return c.GST_FLOW_OK;
        }
    }
    const w: [*c]Buffer = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(b)))));
    out.* = w;
    w[0].pts = time;
    var abs: u64 = 0;
    const sign = c.gst_segment_to_running_time_full(&d[0].segment, c.GST_FORMAT_TIME, w[0].dts, &abs);
    if (sign > 0) {
        w[0].dts = abs;
        d[0].ABI.abi.dts = @bitCast(abs);
    } else if (sign < 0) {
        w[0].dts = NONE;
        d[0].ABI.abi.dts = -@as(i64, @bitCast(abs));
    } else {
        w[0].dts = NONE;
        d[0].ABI.abi.dts = std.math.minInt(i64);
    }
    return c.GST_FLOW_OK;
}

pub export fn gst_collect_pads_add_pad(p: [*c]Pads, pad: ?*c.GstPad, size: c.guint, destroy: c.GstCollectDataDestroyNotify, lock: c.gboolean) [*c]Data {
    const func = "gst_collect_pads_add_pad";
    if (!guard(p, func)) return null;
    if (!check.that(pad != null, func, "pad != NULL")) return null;
    if (!check.that(el.pad(pad).direction == c.GST_PAD_SINK, func, "GST_PAD_IS_SINK (pad)")) return null;
    if (!check.that(size >= @sizeOf(Data), func, "size >= sizeof (GstCollectData)")) return null;
    const d: [*c]Data = @ptrCast(@alignCast(c.g_malloc0(size)));
    const dpriv: *DataPriv = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(DataPriv))));
    d[0].priv = @ptrCast(dpriv);
    d[0].collect = p;
    d[0].pad = @ptrCast(@alignCast(c.gst_object_ref(pad)));
    c.gst_segment_init(&d[0].segment, c.GST_FORMAT_UNDEFINED);
    d[0].state = WAITING | (if (lock != 0) LOCKED else 0);
    dpriv.refcount = 1;
    dpriv.destroy_notify = destroy;
    d[0].ABI.abi.dts = std.math.minInt(i64);
    const r = priv(p);
    el.lock(p);
    el.lock(pad);
    c.gst_pad_set_element_private(pad, d);
    el.unlock(pad);
    r.pad_list = c.g_slist_append(r.pad_list, d);
    c.gst_pad_set_chain_function_full(pad, chain, null, null);
    c.gst_pad_set_event_function_full(pad, padEvent, null, null);
    c.gst_pad_set_query_function_full(pad, padQuery, null, null);
    if (!r.started) {
        p[0].data = c.g_slist_append(p[0].data, d);
        refData(d);
    } else _ = c.gst_pad_set_active(pad, 1);
    r.pad_cookie +%= 1;
    el.unlock(p);
    return d;
}

fn findPad(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const d: [*c]const Data = @ptrCast(@alignCast(a));
    return if (@as(?*const anyopaque, @ptrCast(d[0].pad)) == b) 0 else 1;
}

pub export fn gst_collect_pads_remove_pad(p: [*c]Pads, pad: ?*c.GstPad) c.gboolean {
    const func = "gst_collect_pads_remove_pad";
    if (!guard(p, func)) return 0;
    if (!check.that(pad != null, func, "pad != NULL")) return 0;
    if (!check.that(gtype.instanceOf(pad, c.gst_pad_get_type()), func, "GST_IS_PAD (pad)")) return 0;
    const r = priv(p);
    el.lock(p);
    defer el.unlock(p);
    const l = c.g_slist_find_custom(r.pad_list, pad, findPad);
    if (l == null) return 0;
    const d: [*c]Data = @ptrCast(@alignCast(l[0].data));
    c.gst_pad_set_chain_function_full(pad, null, null, null);
    c.gst_pad_set_event_function_full(pad, null, null, null);
    el.lock(pad);
    c.gst_pad_set_element_private(pad, null);
    el.unlock(pad);
    if (!r.started) {
        const dl = c.g_slist_find_custom(p[0].data, pad, findPad);
        if (dl != null) {
            const pd: [*c]Data = @ptrCast(@alignCast(dl[0].data));
            p[0].data = c.g_slist_delete_link(p[0].data, dl);
            unrefData(pd);
        }
    }
    r.pad_list = c.g_slist_delete_link(r.pad_list, l);
    r.pad_cookie +%= 1;
    broadcast(p);
    if (!r.started) _ = c.gst_pad_set_active(pad, 0);
    unrefData(d);
    return 1;
}

fn setFlushingUnlocked(p: [*c]Pads, flushing: bool) void {
    var l = priv(p).pad_list;
    while (l != null) : (l = l[0].next) {
        const d: [*c]Data = @ptrCast(@alignCast(l[0].data));
        if (!gtype.instanceOf(d[0].pad, c.gst_pad_get_type())) continue;
        el.lock(d[0].pad);
        if (flushing) {
            el.setFlag(d[0].pad, c.GST_PAD_FLAG_FLUSHING);
            set(d, FLUSHING);
        } else {
            el.unsetFlag(d[0].pad, c.GST_PAD_FLAG_FLUSHING);
            unset(d, FLUSHING);
        }
        clear(p, d);
        el.unlock(d[0].pad);
    }
    broadcast(p);
}

pub export fn gst_collect_pads_set_flushing(p: [*c]Pads, flushing: c.gboolean) void {
    if (!guard(p, "gst_collect_pads_set_flushing")) return;
    streamLock(p);
    el.lock(p);
    setFlushingUnlocked(p, flushing != 0);
    el.unlock(p);
    streamUnlock(p);
}

pub export fn gst_collect_pads_start(p: [*c]Pads) void {
    if (!guard(p, "gst_collect_pads_start")) return;
    streamLock(p);
    el.lock(p);
    var l = priv(p).pad_list;
    while (l != null) : (l = l[0].next) {
        const d: [*c]Data = @ptrCast(@alignCast(l[0].data));
        c.gst_segment_init(&d[0].segment, c.GST_FORMAT_UNDEFINED);
    }
    setFlushingUnlocked(p, false);
    priv(p).started = true;
    el.unlock(p);
    streamUnlock(p);
}

pub export fn gst_collect_pads_stop(p: [*c]Pads) void {
    if (!guard(p, "gst_collect_pads_stop")) return;
    const r = priv(p);
    streamLock(p);
    el.lock(p);
    setFlushingUnlocked(p, true);
    r.started = false;
    r.eospads = 0;
    r.queuedpads = 0;
    var l = r.pad_list;
    while (l != null) : (l = l[0].next) {
        const d: [*c]Data = @ptrCast(@alignCast(l[0].data));
        if (d[0].buffer != null) {
            _ = c.gst_mini_object_replace(@ptrCast(&d[0].buffer), null);
            d[0].pos = 0;
        }
        unset(d, EOS);
    }
    if (r.earliest_data != null) unrefData(r.earliest_data);
    r.earliest_data = null;
    r.earliest_time = NONE;
    el.unlock(p);
    broadcast(p);
    streamUnlock(p);
}

pub export fn gst_collect_pads_peek(p: [*c]Pads, d: [*c]Data) [*c]Buffer {
    const func = "gst_collect_pads_peek";
    if (!guard(p, func)) return null;
    if (!check.that(d != null, func, "data != NULL")) return null;
    if (d[0].buffer != null) return c.gst_buffer_ref(d[0].buffer);
    return null;
}

pub export fn gst_collect_pads_pop(p: [*c]Pads, d: [*c]Data) [*c]Buffer {
    const func = "gst_collect_pads_pop";
    if (!guard(p, func)) return null;
    if (!check.that(d != null, func, "data != NULL")) return null;
    const b = d[0].buffer;
    if (b != null) {
        d[0].buffer = null;
        d[0].pos = 0;
        if (has(d, WAITING)) priv(p).queuedpads -%= 1;
    }
    broadcast(p);
    return b;
}

fn clear(p: [*c]Pads, d: [*c]Data) void {
    const b = gst_collect_pads_pop(p, d);
    if (b != null) c.gst_buffer_unref(b);
}

pub export fn gst_collect_pads_available(p: [*c]Pads) c.guint {
    if (!guard(p, "gst_collect_pads_available")) return 0;
    var result: c.guint = std.math.maxInt(c.guint);
    var l = p[0].data;
    while (l != null) : (l = l[0].next) {
        const d: [*c]Data = @ptrCast(@alignCast(l[0].data));
        if (has(d, EOS)) continue;
        if (d[0].buffer == null) return 0;
        const size: c.gint = @truncate(@as(i64, @intCast(c.gst_buffer_get_size(d[0].buffer))) - d[0].pos);
        if (@as(c.guint, @bitCast(size)) < result) result = @bitCast(size);
    }
    return if (result == std.math.maxInt(c.guint)) 0 else result;
}

pub export fn gst_collect_pads_flush(p: [*c]Pads, d: [*c]Data, size: c.guint) c.guint {
    const func = "gst_collect_pads_flush";
    if (!guard(p, func)) return 0;
    if (!check.that(d != null, func, "data != NULL")) return 0;
    const b = d[0].buffer;
    if (b == null) return 0;
    const bsize = c.gst_buffer_get_size(b);
    const n: c.guint = @truncate(@min(@as(u64, size), bsize -% d[0].pos));
    d[0].pos +%= size;
    if (d[0].pos >= bsize) clear(p, d);
    return n;
}

pub export fn gst_collect_pads_read_buffer(p: [*c]Pads, d: [*c]Data, size: c.guint) [*c]Buffer {
    const func = "gst_collect_pads_read_buffer";
    if (!guard(p, func)) return null;
    if (!check.that(d != null, func, "data != NULL")) return null;
    const b = d[0].buffer;
    if (b == null) return null;
    const bsize: c.guint = @truncate(c.gst_buffer_get_size(b));
    return c.gst_buffer_copy_region(b, c.GST_BUFFER_COPY_ALL, d[0].pos, @min(size, bsize -% d[0].pos));
}

pub export fn gst_collect_pads_take_buffer(p: [*c]Pads, d: [*c]Data, size: c.guint) [*c]Buffer {
    const b = gst_collect_pads_read_buffer(p, d, size);
    if (b != null) _ = gst_collect_pads_flush(p, d, @truncate(c.gst_buffer_get_size(b)));
    return b;
}

pub export fn gst_collect_pads_set_waiting(p: [*c]Pads, d: [*c]Data, waiting: c.gboolean) void {
    const func = "gst_collect_pads_set_waiting";
    if (!guard(p, func)) return;
    if (!check.that(d != null, func, "data != NULL")) return;
    if (has(d, LOCKED) or has(d, WAITING) == (waiting != 0)) return;
    if (waiting != 0) set(d, WAITING) else unset(d, WAITING);
    if (d[0].buffer == null and !has(d, EOS)) {
        if (waiting != 0) priv(p).queuedpads -%= 1 else priv(p).queuedpads +%= 1;
    }
    broadcast(p);
}

fn checkPads(p: [*c]Pads) void {
    const r = priv(p);
    el.lock(p);
    defer el.unlock(p);
    if (r.pad_cookie == r.cookie) return;
    c.g_slist_foreach(p[0].data, unrefFunc, null);
    c.g_slist_free(p[0].data);
    p[0].data = null;
    r.numpads = 0;
    r.queuedpads = 0;
    r.eospads = 0;
    if (r.earliest_data != null) unrefData(r.earliest_data);
    r.earliest_data = null;
    r.earliest_time = NONE;
    var l = r.pad_list;
    while (l != null) : (l = l[0].next) {
        const d: [*c]Data = @ptrCast(@alignCast(l[0].data));
        r.numpads += 1;
        if (has(d, EOS)) {
            r.eospads += 1;
        } else if (d[0].buffer != null or !has(d, WAITING)) r.queuedpads += 1;
        refData(d);
        p[0].data = c.g_slist_append(p[0].data, d);
    }
    r.cookie = r.pad_cookie;
}

fn checkCollected(p: [*c]Pads) c.GstFlowReturn {
    const fname = "gst_collect_pads_check_collected";
    if (!check.that(isPads(p), fname, "GST_IS_COLLECT_PADS (pads)")) return c.GST_FLOW_ERROR;
    const r = priv(p);
    el.lock(p);
    const func = r.func;
    const data = r.user_data;
    el.unlock(p);
    if (!check.that(r.func != null, fname, "pads->priv->func != NULL")) return c.GST_FLOW_NOT_SUPPORTED;
    checkPads(p);
    var flow: c.GstFlowReturn = c.GST_FLOW_OK;
    if (r.eospads == r.numpads) {
        _ = @cmpxchgStrong(c.gint, &r.seeking, 1, 0, .seq_cst, .seq_cst);
        while (true) {
            flow = func.?(p, data);
            if (flow != c.GST_FLOW_OK) break;
        }
        return flow;
    }
    while (r.queuedpads +% r.eospads >= r.numpads) {
        _ = @cmpxchgStrong(c.gint, &r.seeking, 1, 0, .seq_cst, .seq_cst);
        flow = func.?(p, data);
        if (flow != c.GST_FLOW_OK or r.queuedpads == 0) break;
    }
    return flow;
}

fn compare(p: [*c]Pads, a: [*c]Data, ta: c.GstClockTime, b: [*c]Data, tb: c.GstClockTime) c.gint {
    const r = priv(p);
    return r.compare_func.?(p, a, ta, b, tb, r.compare_user_data);
}

fn recalculateWaiting(p: [*c]Pads) bool {
    const r = priv(p);
    if (r.earliest_data == null) return false;
    var result = false;
    var l = p[0].data;
    while (l != null) : (l = l[0].next) {
        const d: [*c]Data = @ptrCast(@alignCast(l[0].data));
        if (d[0].segment.format == c.GST_FORMAT_UNDEFINED) {
            c.gst_segment_init(&d[0].segment, c.GST_FORMAT_TIME);
            set(d, NEW_SEGMENT);
        }
        if (d[0].segment.format != c.GST_FORMAT_TIME) continue;
        if (compare(p, d, d[0].segment.position, r.earliest_data, r.earliest_time) > 0) {
            gst_collect_pads_set_waiting(p, d, 0);
        } else if (!has(d, WAITING)) {
            gst_collect_pads_set_waiting(p, d, 1);
            result = true;
        }
    }
    return result;
}

fn recalculateFull(p: [*c]Pads) bool {
    const r = priv(p);
    if (r.earliest_data != null) unrefData(r.earliest_data);
    var best: [*c]Data = null;
    var best_time: c.GstClockTime = NONE;
    var l = p[0].data;
    while (l != null) : (l = l[0].next) {
        const d: [*c]Data = @ptrCast(@alignCast(l[0].data));
        const b = gst_collect_pads_peek(p, d);
        if (b == null) continue;
        const ts = if (b[0].dts != NONE) b[0].dts else b[0].pts;
        c.gst_buffer_unref(b);
        if (best == null or compare(p, d, ts, best, best_time) < 0) {
            best = d;
            best_time = ts;
        }
    }
    r.earliest_data = best;
    r.earliest_time = best_time;
    if (best != null) refData(best);
    return recalculateWaiting(p);
}

fn defaultCollected(p: [*c]Pads, _: c.gpointer) callconv(.c) c.GstFlowReturn {
    const fname = "gst_collect_pads_default_collected";
    if (!check.that(isPads(p), fname, "GST_IS_COLLECT_PADS (pads)")) return c.GST_FLOW_ERROR;
    const r = priv(p);
    el.lock(p);
    const func = r.buffer_func;
    const data = r.buffer_user_data;
    el.unlock(p);
    if (!check.that(func != null, fname, "func != NULL")) return c.GST_FLOW_NOT_SUPPORTED;
    if (recalculateFull(p)) return c.GST_FLOW_OK;
    const best = r.earliest_data;
    if (best == null) {
        const ret = func.?(p, best, null, data);
        return if (ret == c.GST_FLOW_OK) c.GST_FLOW_EOS else ret;
    }
    gst_collect_pads_set_waiting(p, best, 1);
    const b = gst_collect_pads_pop(p, best);
    const ret = func.?(p, best, b, data);
    _ = recalculateFull(p);
    return ret;
}

fn defaultCompare(_: [*c]Pads, _: [*c]Data, a: c.GstClockTime, _: [*c]Data, b: c.GstClockTime, _: c.gpointer) callconv(.c) c.gint {
    if (a == NONE) return if (b != NONE) -1 else 0;
    if (b == NONE) return 1;
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

fn positionUpdate(p: [*c]Pads, d: [*c]Data, pos: c.GstClockTime) void {
    const r = priv(p);
    if (r.earliest_data == null or r.earliest_data == d) {
        _ = recalculateFull(p);
        return;
    }
    if (compare(p, d, pos, r.earliest_data, r.earliest_time) > 0) gst_collect_pads_set_waiting(p, d, 0);
}

fn clipTime(p: [*c]Pads, d: [*c]Data, time: c.GstClockTime) c.GstClockTime {
    const r = priv(p);
    const f = r.clip_func orelse return time;
    const in = c.gst_buffer_new();
    in[0].pts = time;
    in[0].dts = NONE;
    var o: [*c]Buffer = null;
    _ = f(p, d, in, &o, r.clip_user_data);
    if (o == null) return std.math.maxInt(i64) / 2;
    const t = o[0].pts;
    c.gst_buffer_unref(o);
    return t;
}

pub export fn gst_collect_pads_event_default(p: [*c]Pads, d: [*c]Data, ev_in: [*c]Event, discard: c.gboolean) c.gboolean {
    const r = priv(p);
    var ev = ev_in;
    var res: c.gboolean = 1;
    el.lock(p);
    const buffer_func = r.buffer_func;
    el.unlock(p);
    const pad = d[0].pad;
    const par: [*c]c.GstObject = @as(*c.GstObject, @ptrCast(@alignCast(pad))).parent;
    forward: {
        switch (ev[0].type) {
            c.GST_EVENT_FLUSH_START => {
                if (@atomicLoad(c.gint, &r.seeking, .seq_cst) != 0) {
                    if (@cmpxchgStrong(c.gint, &r.pending_flush_start, 1, 0, .seq_cst, .seq_cst) == null) {
                        _ = c.gst_pad_event_default(pad, par, ev);
                        ev = null;
                        streamLock(p);
                        gst_collect_pads_set_flushing(p, 1);
                        if (r.flush_func) |f| f(p, r.flush_user_data);
                        @atomicStore(c.gint, &r.pending_flush_stop, 1, .seq_cst);
                        streamUnlock(p);
                    }
                } else {
                    res = c.gst_pad_event_default(pad, par, ev);
                    ev = null;
                    streamLock(p);
                    set(d, FLUSHING);
                    clear(p, d);
                    if (buffer_func != null) {
                        gst_collect_pads_set_waiting(p, d, 1);
                        if (r.earliest_data == d) {
                            unrefData(d);
                            r.earliest_data = null;
                            r.earliest_time = NONE;
                        }
                    }
                    streamUnlock(p);
                }
            },
            c.GST_EVENT_FLUSH_STOP => {
                streamLock(p);
                unset(d, FLUSHING);
                clear(p, d);
                c.gst_segment_init(&d[0].segment, c.GST_FORMAT_UNDEFINED);
                unset(d, NEW_SEGMENT);
                if (has(d, EOS)) {
                    if (!has(d, WAITING)) r.queuedpads +%= 1;
                    if (@atomicLoad(c.gint, &r.seeking, .seq_cst) == 0) r.eospads -%= 1;
                    unset(d, EOS);
                }
                streamUnlock(p);
                if (@atomicLoad(c.gint, &r.seeking, .seq_cst) == 0) break :forward;
                if (@cmpxchgStrong(c.gint, &r.pending_flush_stop, 1, 0, .seq_cst, .seq_cst) == null) break :forward;
            },
            c.GST_EVENT_EOS => {
                streamLock(p);
                if (!has(d, EOS)) {
                    set(d, EOS);
                    if (!has(d, WAITING)) r.queuedpads -%= 1;
                    r.eospads +%= 1;
                }
                _ = checkCollected(p);
                streamUnlock(p);
            },
            c.GST_EVENT_SEGMENT => {
                streamLock(p);
                var seg: c.GstSegment = undefined;
                c.gst_event_copy_segment(ev, &seg);
                if (buffer_func == null or seg.format == c.GST_FORMAT_TIME) {
                    d[0].segment = seg;
                    set(d, NEW_SEGMENT);
                    seg.position = clipTime(p, d, seg.start +% seg.offset);
                    d[0].segment = seg;
                    if (buffer_func != null) positionUpdate(p, d, seg.position);
                }
                streamUnlock(p);
            },
            c.GST_EVENT_GAP => {
                streamLock(p);
                var start: u64 = 0;
                var dur: u64 = 0;
                c.gst_event_parse_gap(ev, &start, &dur);
                if (dur != NONE) start +%= dur;
                d[0].segment.position = clipTime(p, d, start);
                positionUpdate(p, d, d[0].segment.position);
                streamUnlock(p);
            },
            c.GST_EVENT_STREAM_START, c.GST_EVENT_CAPS => {},
            else => break :forward,
        }
        if (ev != null) c.gst_event_unref(ev);
        return res;
    }
    if (discard != 0) {
        c.gst_event_unref(ev);
        return res;
    }
    return c.gst_pad_event_default(pad, par, ev);
}

const EventData = struct {
    event: [*c]Event,
    result: bool = true,
};

fn forwardFunc(pad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const ed: *EventData = @ptrCast(@alignCast(data));
    var ok = true;
    const peer = c.gst_pad_get_peer(pad);
    if (peer != null) {
        ok = c.gst_pad_send_event(peer, c.gst_event_ref(ed.event)) != 0;
        c.gst_object_unref(peer);
    }
    ed.result = ed.result and ok;
    return 0;
}

pub export fn gst_collect_pads_src_event_default(p: [*c]Pads, pad: ?*c.GstPad, ev_in: [*c]Event) c.gboolean {
    const r = priv(p);
    var ev = ev_in;
    var res: c.gboolean = 1;
    if (ev[0].type == c.GST_EVENT_SEEK) {
        r.eospads = 0;
        var flags: c.GstSeekFlags = 0;
        c.gst_event_parse_seek(ev, null, null, &flags, null, null, null, null);
        if (flags & c.GST_SEEK_FLAG_FLUSH != 0) {
            @atomicStore(c.gint, &r.seeking, 1, .seq_cst);
            @atomicStore(c.gint, &r.pending_flush_start, 1, .seq_cst);
            var ed = EventData{ .event = ev };
            _ = c.gst_pad_forward(pad, forwardFunc, &ed);
            c.gst_event_unref(ev);
            ev = null;
            res = @intFromBool(ed.result);
            if (!ed.result) {
                @atomicStore(c.gint, &r.seeking, 0, .seq_cst);
                @atomicStore(c.gint, &r.pending_flush_start, 0, .seq_cst);
            }
        }
    }
    if (ev != null) res = c.gst_pad_event_default(pad, @as(*c.GstObject, @ptrCast(@alignCast(pad))).parent, ev);
    return res;
}

fn eventDefaultInternal(p: [*c]Pads, d: [*c]Data, ev: [*c]Event, _: c.gpointer) callconv(.c) c.gboolean {
    return gst_collect_pads_event_default(p, d, ev, 0);
}

fn padData(pad: ?*c.GstPad) [*c]Data {
    el.lock(pad);
    defer el.unlock(pad);
    const d: [*c]Data = @ptrCast(@alignCast(c.gst_pad_get_element_private(pad)));
    if (d != null) refData(d);
    return d;
}

fn padEvent(pad: ?*c.GstPad, _: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.gboolean {
    const d = padData(pad);
    if (d == null) return 0;
    defer unrefData(d);
    const p = d[0].collect;
    el.lock(p);
    const func = priv(p).event_func;
    const data = priv(p).event_user_data;
    el.unlock(p);
    const serialized = ev[0].type & c.GST_EVENT_TYPE_SERIALIZED != 0;
    if (serialized) streamLock(p);
    defer if (serialized) streamUnlock(p);
    return if (func) |f| f(p, d, ev, data) else 0;
}

pub export fn gst_collect_pads_query_default(_: [*c]Pads, d: [*c]Data, q: [*c]Query, discard: c.gboolean) c.gboolean {
    const pad = d[0].pad;
    if (q[0].type == c.GST_QUERY_SEEKING) {
        var format: c.GstFormat = 0;
        c.gst_query_parse_seeking(q, &format, null, null, null);
        c.gst_query_set_seeking(q, format, 0, 0, -1);
        return 1;
    }
    if (discard != 0) return 1;
    return c.gst_pad_query_default(pad, @as(*c.GstObject, @ptrCast(@alignCast(pad))).parent, q);
}

fn queryDefaultInternal(p: [*c]Pads, d: [*c]Data, q: [*c]Query, _: c.gpointer) callconv(.c) c.gboolean {
    return gst_collect_pads_query_default(p, d, q, 0);
}

fn padQuery(pad: ?*c.GstPad, _: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const d = padData(pad);
    if (d == null) return 0;
    defer unrefData(d);
    const p = d[0].collect;
    el.lock(p);
    const func = priv(p).query_func;
    const data = priv(p).query_user_data;
    el.unlock(p);
    const serialized = q[0].type & c.GST_QUERY_TYPE_SERIALIZED != 0;
    if (serialized) streamLock(p);
    defer if (serialized) streamUnlock(p);
    return if (func) |f| f(p, d, q, data) else 0;
}

fn chain(pad: ?*c.GstPad, _: [*c]c.GstObject, buffer_in: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    var d = padData(pad);
    if (d == null) {
        c.gst_buffer_unref(buffer_in);
        return c.GST_FLOW_NOT_LINKED;
    }
    var b = buffer_in;
    const p = d[0].collect;
    const r = priv(p);
    streamLock(p);
    const ret: c.GstFlowReturn = blk: {
        if (!r.started or has(d, FLUSHING)) {
            clear(p, d);
            break :blk c.GST_FLOW_FLUSHING;
        }
        if (has(d, EOS)) break :blk c.GST_FLOW_EOS;
        if (r.clip_func) |f| {
            var o: [*c]Buffer = null;
            const cr = f(p, d, b, &o, r.clip_user_data);
            b = o;
            if (o == null) break :blk c.GST_FLOW_OK;
            if (cr == c.GST_FLOW_EOS) break :blk c.GST_FLOW_EOS;
            if (cr != c.GST_FLOW_OK) {
                clear(p, d);
                break :blk cr;
            }
        }
        if (has(d, WAITING)) r.queuedpads +%= 1;
        _ = c.gst_mini_object_replace(@ptrCast(&d[0].buffer), @ptrCast(b));
        if (d[0].segment.format == c.GST_FORMAT_TIME) {
            const ts = if (b[0].dts != NONE) b[0].dts else b[0].pts;
            if (ts != NONE) d[0].segment.position = ts;
        }
        while (true) {
            const cr = checkCollected(p);
            if (cr != c.GST_FLOW_OK) {
                clear(p, d);
                break :blk cr;
            }
            if (d[0].buffer == null) break :blk c.GST_FLOW_OK;
            const cookie = cookieNow(p);
            unrefData(d);
            d = padData(pad);
            if (d == null) break :blk c.GST_FLOW_NOT_LINKED;
            streamUnlock(p);
            waitCookie(p, cookie);
            streamLock(p);
            if (!r.started or has(d, FLUSHING)) {
                clear(p, d);
                break :blk c.GST_FLOW_FLUSHING;
            }
            if (d[0].buffer == null) break :blk c.GST_FLOW_OK;
        }
    };
    streamUnlock(p);
    if (d != null) unrefData(d);
    if (b != null) c.gst_buffer_unref(b);
    return ret;
}
