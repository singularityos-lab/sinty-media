const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstqueue.c";

const PROP_CUR_LEVEL_BUFFERS = 1;
const PROP_CUR_LEVEL_BYTES = 2;
const PROP_CUR_LEVEL_TIME = 3;
const PROP_MAX_SIZE_BUFFERS = 4;
const PROP_MAX_SIZE_BYTES = 5;
const PROP_MAX_SIZE_TIME = 6;
const PROP_MIN_THRESHOLD_BUFFERS = 7;
const PROP_MIN_THRESHOLD_BYTES = 8;
const PROP_MIN_THRESHOLD_TIME = 9;
const PROP_LEAKY = 10;
const PROP_SILENT = 11;
const PROP_FLUSH_ON_EOS = 12;
const PROP_NOTIFY_LEVELS = 13;
const PROP_LAST = 14;

const NO_LEAK = 0;
const LEAK_UPSTREAM = 1;
const LEAK_DOWNSTREAM = 2;

const STIME_NONE: i64 = std.math.minInt(i64);
const NONE = cm.CLOCK_NONE;

const Size = extern struct {
    buffers: c.guint = 0,
    bytes: c.guint = 0,
    time: c.guint64 = 0,
};

const Item = extern struct {
    item: [*c]c.GstMiniObject,
    size: c.gsize,
    is_query: c.gboolean,
};

const Self = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    sink_segment: c.GstSegment,
    src_segment: c.GstSegment,
    sinktime: c.GstClockTimeDiff,
    srctime: c.GstClockTimeDiff,
    sink_start_time: c.GstClockTimeDiff,
    sink_tainted: c.gboolean,
    src_tainted: c.gboolean,
    srcresult: c.GstFlowReturn,
    unexpected: c.gboolean,
    eos: c.gboolean,
    cur_level: Size,
    max_size: Size,
    min_threshold: Size,
    orig_min_threshold: Size,
    leaky: c.gint,
    qlock: c.GMutex,
    waiting_add: c.gboolean,
    item_add: c.GCond,
    waiting_del: c.gboolean,
    item_del: c.GCond,
    head_needs_discont: c.gboolean,
    tail_needs_discont: c.gboolean,
    push_newsegment: c.gboolean,
    silent: c.gboolean,
    queue: ?*c.GstVecDeque,
    flush_on_eos: c.gboolean,
    notify_levels: c.gboolean,
    query_handled: c.GCond,
    last_query: c.gboolean,
    last_handled_query: [*c]c.GstQuery,
    newseg_applied_to_src: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
    underrun: ?*const fn (*Self) callconv(.c) void,
    running: ?*const fn (*Self) callconv(.c) void,
    overrun: ?*const fn (*Self) callconv(.c) void,
    pushing: ?*const fn (*Self) callconv(.c) void,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");

var once: cm.Once = .{};
var leaky_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var sig_underrun: c.guint = 0;
var sig_running: c.guint = 0;
var sig_overrun: c.guint = 0;
var sig_pushing: c.guint = 0;
var props: [PROP_LAST][*c]c.GParamSpec = .{null} ** PROP_LAST;

var leaky_values = [_]c.GEnumValue{
    .{ .value = NO_LEAK, .value_name = "Not Leaky", .value_nick = "no" },
    .{ .value = LEAK_UPSTREAM, .value_name = "Leaky on upstream (new buffers)", .value_nick = "upstream" },
    .{ .value = LEAK_DOWNSTREAM, .value_name = "Leaky on downstream (old buffers)", .value_nick = "downstream" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn leakyType() c.GType {
    return leaky_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstQueueLeaky", &leaky_values);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn lock(q: *Self) void {
    c.g_mutex_lock(&q.qlock);
}

fn unlock(q: *Self) void {
    c.g_mutex_unlock(&q.qlock);
}

fn signalDel(q: *Self) void {
    if (q.waiting_del != 0) c.g_cond_signal(&q.item_del);
}

fn signalAdd(q: *Self) void {
    if (q.waiting_add != 0) c.g_cond_signal(&q.item_add);
}

fn waitDel(q: *Self) bool {
    q.waiting_del = 1;
    c.g_cond_wait(&q.item_del, &q.qlock);
    q.waiting_del = 0;
    return q.srcresult == c.GST_FLOW_OK;
}

fn waitAdd(q: *Self) bool {
    q.waiting_add = 1;
    c.g_cond_wait(&q.item_add, &q.qlock);
    q.waiting_add = 0;
    return q.srcresult == c.GST_FLOW_OK;
}

fn emit(q: *Self, id: c.guint) void {
    c.g_signal_emit(q, id, 0);
}

fn notifyLevels(q: *Self, prev: Size, new: Size) void {
    if (q.notify_levels == 0) return;
    if (new.buffers != prev.buffers) c.g_object_notify_by_pspec(@ptrCast(@alignCast(q)), props[PROP_CUR_LEVEL_BUFFERS]);
    if (new.bytes != prev.bytes) c.g_object_notify_by_pspec(@ptrCast(@alignCast(q)), props[PROP_CUR_LEVEL_BYTES]);
    if (new.time != prev.time) c.g_object_notify_by_pspec(@ptrCast(@alignCast(q)), props[PROP_CUR_LEVEL_TIME]);
}

fn unlockNotify(q: *Self, prev: Size) void {
    const new = q.cur_level;
    unlock(q);
    notifyLevels(q, prev, new);
}

fn runningTime(seg: *c.GstSegment, val: u64) i64 {
    if (val == NONE) return STIME_NONE;
    var v = val;
    const sign = c.gst_segment_to_running_time_full(seg, c.GST_FORMAT_TIME, val, &v);
    if (sign > 0) return @bitCast(v);
    if (sign < 0) return -@as(i64, @bitCast(v));
    return STIME_NONE;
}

fn updateTimeLevel(q: *Self) void {
    if (q.sink_tainted != 0) {
        q.sinktime = runningTime(&q.sink_segment, q.sink_segment.position);
        q.sink_tainted = 0;
    }
    if (q.src_tainted != 0) {
        q.srctime = runningTime(&q.src_segment, q.src_segment.position);
        q.src_tainted = 0;
    }
    const sink = q.sinktime;
    const src = q.srctime;
    const start = q.sink_start_time;
    if (sink != STIME_NONE) {
        if (src == STIME_NONE and start != STIME_NONE and sink >= start) {
            q.cur_level.time = @bitCast(sink - start);
        } else if (src != STIME_NONE and sink >= src) {
            q.cur_level.time = @bitCast(sink - src);
        } else q.cur_level.time = 0;
    } else q.cur_level.time = 0;
}

fn taint(q: *Self, sink: bool) void {
    if (sink) q.sink_tainted = 1 else q.src_tainted = 1;
}

fn applySegment(q: *Self, ev: anytype, seg: *c.GstSegment, sink: bool) void {
    c.gst_event_copy_segment(@ptrCast(@alignCast(ev)), seg);
    if (seg.format != c.GST_FORMAT_TIME) {
        seg.format = c.GST_FORMAT_TIME;
        seg.start = 0;
        seg.stop = NONE;
        seg.time = 0;
    }
    if (sink) q.sink_tainted = 0 else q.src_tainted = 0;
}

fn applyGap(q: *Self, ev: anytype, seg: *c.GstSegment, sink: bool) void {
    var ts: u64 = 0;
    var dur: u64 = 0;
    c.gst_event_parse_gap(@ptrCast(@alignCast(ev)), &ts, &dur);
    if (!cm.that(ts != NONE, "apply_gap", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return;
    if (sink and q.sink_start_time == STIME_NONE) q.sink_start_time = runningTime(seg, ts);
    if (dur != NONE) ts +%= dur;
    seg.position = ts;
    taint(q, sink);
    updateTimeLevel(q);
}

fn applyBuffer(q: *Self, b: anytype, seg: *c.GstSegment, sink: bool) void {
    var ts = cm.dtsOrPts(b);
    const dur = cm.buf(b).duration;
    if (ts == NONE) return;
    if (sink and q.sink_start_time == STIME_NONE) q.sink_start_time = runningTime(seg, ts);
    if (dur != NONE) ts +%= dur;
    seg.position = ts;
    taint(q, sink);
    updateTimeLevel(q);
}

const ListTimes = struct { first: u64 = NONE, ts: u64 = NONE };

fn listTime(b: [*c][*c]c.GstBuffer, _: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    const d: *ListTimes = @ptrCast(@alignCast(data));
    const t = cm.dtsOrPts(b[0]);
    if (t != NONE) {
        if (d.first == NONE) d.first = t;
        d.ts = t;
    }
    const dur = cm.buf(b[0]).duration;
    if (dur != NONE and d.ts != NONE) d.ts +%= dur;
    return 1;
}

fn applyList(q: *Self, l: anytype, seg: *c.GstSegment, sink: bool) void {
    var d = ListTimes{};
    _ = c.gst_buffer_list_foreach(@ptrCast(@alignCast(l)), listTime, &d);
    if (d.ts == NONE) return;
    if (sink and q.sink_start_time == STIME_NONE and d.first != NONE) q.sink_start_time = runningTime(seg, d.first);
    seg.position = d.ts;
    taint(q, sink);
    updateTimeLevel(q);
}

fn popItem(q: *Self) ?*Item {
    return @ptrCast(@alignCast(c.gst_vec_deque_pop_head_struct(q.queue)));
}

fn lockedFlush(q: *Self, full: bool) void {
    while (popItem(q)) |it| {
        if (!full and it.is_query == 0 and cm.isEvent(it.item) and cm.eventSticky(it.item) and cm.eventType(it.item) != c.GST_EVENT_SEGMENT and cm.eventType(it.item) != c.GST_EVENT_EOS) {
            _ = c.gst_pad_store_sticky_event(q.srcpad, @ptrCast(it.item));
        }
        if (it.is_query == 0) c.gst_mini_object_unref(it.item);
        it.* = std.mem.zeroes(Item);
    }
    q.last_query = 0;
    c.g_cond_signal(&q.query_handled);
    q.cur_level = .{};
    q.min_threshold = q.orig_min_threshold;
    c.gst_segment_init(&q.sink_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&q.src_segment, c.GST_FORMAT_TIME);
    q.head_needs_discont = 0;
    q.tail_needs_discont = 0;
    q.sinktime = STIME_NONE;
    q.srctime = STIME_NONE;
    q.sink_start_time = STIME_NONE;
    q.sink_tainted = 0;
    q.src_tainted = 0;
    signalDel(q);
}

fn push(q: *Self, item: anytype, size: usize, query: bool) void {
    var it = Item{ .item = @ptrCast(@alignCast(item)), .size = size, .is_query = @intFromBool(query) };
    c.gst_vec_deque_push_tail_struct(q.queue, &it);
    signalAdd(q);
}

fn enqueueBuffer(q: *Self, b: [*c]c.GstMiniObject) void {
    const size = c.gst_buffer_get_size(@ptrCast(b));
    q.cur_level.buffers += 1;
    q.cur_level.bytes +%= @truncate(size);
    applyBuffer(q, b, &q.sink_segment, true);
    push(q, b, size, false);
}

fn enqueueList(q: *Self, l: [*c]c.GstMiniObject) void {
    const size = c.gst_buffer_list_calculate_size(@ptrCast(l));
    q.cur_level.buffers += c.gst_buffer_list_length(@ptrCast(l));
    q.cur_level.bytes +%= @truncate(size);
    applyList(q, l, &q.sink_segment, true);
    push(q, l, size, false);
}

fn enqueueEvent(q: *Self, ev: [*c]c.GstEvent) void {
    switch (cm.eventType(ev)) {
        c.GST_EVENT_EOS => {
            if (q.flush_on_eos != 0) lockedFlush(q, false) else q.min_threshold = .{};
            q.eos = 1;
        },
        c.GST_EVENT_SEGMENT => {
            applySegment(q, ev, &q.sink_segment, true);
            if (c.gst_vec_deque_is_empty(q.queue) != 0) {
                applySegment(q, ev, &q.src_segment, false);
                q.newseg_applied_to_src = 1;
            }
            q.unexpected = 0;
        },
        c.GST_EVENT_GAP => applyGap(q, ev, &q.sink_segment, true),
        else => {},
    }
    push(q, ev, 0, false);
}

fn dequeue(q: *Self) [*c]c.GstMiniObject {
    const it = popItem(q) orelse return null;
    var item = it.item;
    const size = it.size;
    if (cm.isBuffer(item)) {
        q.cur_level.buffers -= 1;
        q.cur_level.bytes -%= @truncate(size);
        applyBuffer(q, item, &q.src_segment, false);
        if (q.cur_level.buffers == 0) q.cur_level.time = 0;
    } else if (cm.isBufferList(item)) {
        q.cur_level.buffers -%= c.gst_buffer_list_length(@ptrCast(item));
        q.cur_level.bytes -%= @truncate(size);
        applyList(q, item, &q.src_segment, false);
        if (q.cur_level.buffers == 0) q.cur_level.time = 0;
    } else if (cm.isEvent(item)) {
        switch (cm.eventType(item)) {
            c.GST_EVENT_EOS => q.cur_level = .{},
            c.GST_EVENT_SEGMENT => {
                if (q.newseg_applied_to_src == 0) applySegment(q, item, &q.src_segment, false) else q.newseg_applied_to_src = 0;
            },
            c.GST_EVENT_GAP => applyGap(q, item, &q.src_segment, false),
            else => {},
        }
    } else if (!cm.isQuery(item)) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "Unexpected item %p dequeued from queue %s (refcounting problem?)", item, cm.obj(q).name);
        item = null;
    }
    signalDel(q);
    return item;
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.GstFlowReturn {
    const q = me(par);
    var ok = true;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_FLUSH_START => {
            ok = c.gst_pad_push_event(q.srcpad, ev) != 0;
            lock(q);
            q.srcresult = c.GST_FLOW_FLUSHING;
            signalAdd(q);
            signalDel(q);
            unlock(q);
            _ = c.gst_pad_pause_task(q.srcpad);
            lock(q);
            q.last_query = 0;
            c.g_cond_signal(&q.query_handled);
            unlock(q);
        },
        c.GST_EVENT_FLUSH_STOP => {
            ok = c.gst_pad_push_event(q.srcpad, ev) != 0;
            lock(q);
            lockedFlush(q, false);
            q.srcresult = c.GST_FLOW_OK;
            q.eos = 0;
            q.unexpected = 0;
            if (c.gst_pad_is_active(q.srcpad) != 0) _ = c.gst_pad_start_task(q.srcpad, loop, q.srcpad, null);
            unlock(q);
        },
        else => {
            if (cm.eventSerialized(ev)) {
                lock(q);
                const prev = q.cur_level;
                const et = cm.eventType(ev);
                if (q.srcresult == c.GST_FLOW_EOS and (et == c.GST_EVENT_STREAM_START or et == c.GST_EVENT_SEGMENT)) q.srcresult = c.GST_FLOW_OK;
                if (q.srcresult != c.GST_FLOW_OK) {
                    if (!cm.eventSticky(ev)) {
                        unlock(q);
                        return flowRefused(q, ev);
                    } else if (et == c.GST_EVENT_EOS) {
                        const r = q.srcresult;
                        unlock(q);
                        if (r == c.GST_FLOW_NOT_LINKED or r < c.GST_FLOW_EOS) cm.flowError(q, r, FILE, "gst_queue_handle_sink_event", 1083);
                        return flowRefused(q, ev);
                    }
                }
                if (q.eos != 0) {
                    if (et == c.GST_EVENT_STREAM_START or et == c.GST_EVENT_SEGMENT) {
                        if (cm.pad(q.srcpad).mode == c.GST_PAD_MODE_PUSH) {
                            q.srcresult = c.GST_FLOW_OK;
                            q.eos = 0;
                            q.unexpected = 0;
                            _ = c.gst_pad_start_task(q.srcpad, loop, q.srcpad, null);
                        } else {
                            q.eos = 0;
                            q.unexpected = 0;
                        }
                    } else {
                        unlock(q);
                        c.gst_mini_object_unref(@ptrCast(ev));
                        return c.GST_FLOW_EOS;
                    }
                }
                enqueueEvent(q, ev);
                unlockNotify(q, prev);
            } else ok = c.gst_pad_push_event(q.srcpad, ev) != 0;
        },
    }
    _ = pad;
    return if (ok) c.GST_FLOW_OK else c.GST_FLOW_ERROR;
}

fn flowRefused(q: *Self, ev: [*c]c.GstEvent) c.GstFlowReturn {
    c.gst_mini_object_unref(@ptrCast(ev));
    return q.srcresult;
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, qy: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const q = me(par);
    if (!cm.querySerialized(qy)) return c.gst_pad_query_default(pad, par, qy);
    lock(q);
    if (q.srcresult != c.GST_FLOW_OK) {
        unlock(q);
        return 0;
    }
    push(q, qy, 0, true);
    while (q.srcresult == c.GST_FLOW_OK and q.last_handled_query != qy) c.g_cond_wait(&q.query_handled, &q.qlock);
    q.last_handled_query = null;
    if (q.srcresult != c.GST_FLOW_OK) {
        unlock(q);
        return 0;
    }
    const r = q.last_query;
    unlock(q);
    return r;
}

fn isFilled(q: *Self) bool {
    return (q.max_size.buffers > 0 and q.cur_level.buffers >= q.max_size.buffers) or
        (q.max_size.bytes > 0 and q.cur_level.bytes >= q.max_size.bytes) or
        (q.max_size.time > 0 and q.cur_level.time >= q.max_size.time);
}

fn isEmpty(q: *Self) bool {
    const tail: ?*Item = @ptrCast(@alignCast(c.gst_vec_deque_peek_tail_struct(q.queue)));
    const t = tail orelse return true;
    if (!cm.isBuffer(t.item) and !cm.isBufferList(t.item)) return false;
    return ((q.min_threshold.buffers > 0 and q.cur_level.buffers < q.min_threshold.buffers) or
        (q.min_threshold.bytes > 0 and q.cur_level.bytes < q.min_threshold.bytes) or
        (q.min_threshold.time > 0 and q.cur_level.time < q.min_threshold.time)) and !isFilled(q);
}

fn leakDownstream(q: *Self) void {
    while (isFilled(q)) {
        const leak = dequeue(q);
        if (leak == null) c.g_assertion_message_expr(null, FILE, 1237, "gst_queue_leak_downstream", "leak != NULL");
        if (cm.isEvent(leak) and cm.eventSticky(leak)) _ = c.gst_pad_store_sticky_event(q.srcpad, @ptrCast(leak));
        if (!cm.isQuery(leak)) c.gst_mini_object_unref(leak);
        q.head_needs_discont = 1;
    }
}

fn discontFirst(b: [*c][*c]c.GstBuffer, _: c.guint, _: c.gpointer) callconv(.c) c.gboolean {
    const w = c.gst_buffer_make_writable(b[0]);
    if (w != null) {
        b[0] = w;
        cm.buf(w).mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
    }
    return 0;
}

fn markDiscont(obj: [*c]c.GstMiniObject, list: bool) [*c]c.GstMiniObject {
    if (!list) {
        var b: [*c]c.GstBuffer = @ptrCast(obj);
        const w = c.gst_buffer_make_writable(b);
        if (w != null) {
            b = w;
            cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        }
        return @ptrCast(b);
    }
    const l = c.gst_buffer_list_make_writable(@ptrCast(obj));
    _ = c.gst_buffer_list_foreach(l, discontFirst, null);
    return @ptrCast(@alignCast(l));
}

fn chainAny(par: [*c]c.GstObject, obj_in: [*c]c.GstMiniObject, list: bool) c.GstFlowReturn {
    const q = me(par);
    var obj = obj_in;
    lock(q);
    if (q.srcresult != c.GST_FLOW_OK) return outFlushing(q, obj);
    const prev = q.cur_level;
    if (q.eos != 0 or q.unexpected != 0) {
        unlock(q);
        c.gst_mini_object_unref(obj);
        return c.GST_FLOW_EOS;
    }
    while (isFilled(q)) {
        if (q.silent == 0) {
            unlock(q);
            emit(q, sig_overrun);
            lock(q);
            if (q.srcresult != c.GST_FLOW_OK) return outFlushing(q, obj);
            if (!isFilled(q)) break;
        }
        switch (q.leaky) {
            LEAK_UPSTREAM => {
                q.tail_needs_discont = 1;
                unlockNotify(q, prev);
                c.gst_mini_object_unref(obj);
                return c.GST_FLOW_OK;
            },
            LEAK_DOWNSTREAM => {
                leakDownstream(q);
                if (q.silent == 0) {
                    unlockNotify(q, prev);
                    lock(q);
                    if (q.srcresult != c.GST_FLOW_OK) return outFlushing(q, obj);
                }
            },
            else => {
                if (q.leaky != NO_LEAK) c.g_log(null, c.G_LOG_LEVEL_WARNING, "Unknown leaky type, using default");
                while (isFilled(q)) {
                    if (!waitDel(q)) return outFlushing(q, obj);
                }
                if (q.silent == 0) {
                    unlock(q);
                    emit(q, sig_running);
                    lock(q);
                    if (q.srcresult != c.GST_FLOW_OK) return outFlushing(q, obj);
                }
            },
        }
    }
    if (q.tail_needs_discont != 0) {
        obj = markDiscont(obj, list);
        q.tail_needs_discont = 0;
    }
    if (list) enqueueList(q, obj) else enqueueBuffer(q, obj);
    unlockNotify(q, prev);
    return c.GST_FLOW_OK;
}

fn outFlushing(q: *Self, obj: [*c]c.GstMiniObject) c.GstFlowReturn {
    const r = q.srcresult;
    unlock(q);
    c.gst_mini_object_unref(obj);
    return r;
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return chainAny(par, @ptrCast(b), false);
}

fn chainList(_: ?*c.GstPad, par: [*c]c.GstObject, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    return chainAny(par, @ptrCast(@alignCast(l)), true);
}

fn pushOne(q: *Self) c.GstFlowReturn {
    var result = q.srcresult;
    var data = dequeue(q);
    if (data == null) return c.GST_FLOW_ERROR;
    while (true) {
        const list = cm.isBufferList(data);
        if (cm.isBuffer(data) or list) {
            if (!list) {
                var b: [*c]c.GstBuffer = @ptrCast(data);
                if (q.head_needs_discont != 0) {
                    b = @ptrCast(markDiscont(@ptrCast(b), false));
                    q.head_needs_discont = 0;
                }
                unlock(q);
                result = c.gst_pad_push(q.srcpad, b);
            } else {
                var l: ?*c.GstBufferList = @ptrCast(data);
                if (q.head_needs_discont != 0) {
                    l = @ptrCast(markDiscont(@ptrCast(@alignCast(l)), true));
                    q.head_needs_discont = 0;
                }
                unlock(q);
                result = c.gst_pad_push_list(q.srcpad, l);
            }
            lock(q);
            if (q.srcresult != c.GST_FLOW_OK) return q.srcresult;
            if (result == c.GST_FLOW_EOS) {
                var again = false;
                while (true) {
                    data = dequeue(q);
                    if (data == null) break;
                    if (cm.isBuffer(data) or cm.isBufferList(data)) {
                        c.gst_mini_object_unref(data);
                    } else if (cm.isEvent(data)) {
                        const t = cm.eventType(data);
                        if (t == c.GST_EVENT_EOS or t == c.GST_EVENT_SEGMENT or t == c.GST_EVENT_STREAM_START) {
                            again = true;
                            break;
                        }
                        c.gst_mini_object_unref(data);
                    } else if (cm.isQuery(data)) {
                        q.last_query = 0;
                        c.g_cond_signal(&q.query_handled);
                    }
                }
                if (again) continue;
                q.unexpected = 1;
                result = c.GST_FLOW_OK;
            }
        } else if (cm.isEvent(data)) {
            const t = cm.eventType(data);
            unlock(q);
            _ = c.gst_pad_push_event(q.srcpad, @ptrCast(data));
            lock(q);
            if (q.srcresult != c.GST_FLOW_OK) return q.srcresult;
            if (t == c.GST_EVENT_EOS) result = c.GST_FLOW_EOS;
        } else if (cm.isQuery(data)) {
            const qy: [*c]c.GstQuery = @ptrCast(data);
            unlock(q);
            const r = c.gst_pad_peer_query(q.srcpad, qy);
            lock(q);
            if (q.srcresult != c.GST_FLOW_OK) {
                q.last_query = 0;
                c.g_cond_signal(&q.query_handled);
                return q.srcresult;
            }
            q.last_query = r;
            q.last_handled_query = qy;
            c.g_cond_signal(&q.query_handled);
        }
        return result;
    }
}

fn loopExit(q: *Self) void {
    const eos = q.eos;
    const ret = q.srcresult;
    _ = c.gst_pad_pause_task(q.srcpad);
    if (ret != c.GST_FLOW_NOT_LINKED and ret != c.GST_FLOW_EOS) {
        lockedFlush(q, false);
    } else {
        signalDel(q);
        q.last_query = 0;
        c.g_cond_signal(&q.query_handled);
    }
    unlock(q);
    if (eos != 0 and (ret == c.GST_FLOW_NOT_LINKED or ret < c.GST_FLOW_EOS)) {
        cm.flowError(q, ret, FILE, "gst_queue_loop", 1660);
        _ = c.gst_pad_push_event(q.srcpad, c.gst_event_new_eos());
    }
}

fn loop(data: c.gpointer) callconv(.c) void {
    const q = me(cm.padParent(data));
    lock(q);
    if (q.srcresult != c.GST_FLOW_OK) return loopExit(q);
    while (isEmpty(q)) {
        if (q.silent == 0) {
            unlock(q);
            emit(q, sig_underrun);
            lock(q);
            if (q.srcresult != c.GST_FLOW_OK) return loopExit(q);
        }
        while (isEmpty(q)) {
            if (!waitAdd(q)) return loopExit(q);
        }
        if (q.silent == 0) {
            unlock(q);
            emit(q, sig_running);
            emit(q, sig_pushing);
            lock(q);
            if (q.srcresult != c.GST_FLOW_OK) return loopExit(q);
        }
    }
    const prev = q.cur_level;
    const ret = pushOne(q);
    q.srcresult = ret;
    if (ret != c.GST_FLOW_OK) return loopExit(q);
    unlockNotify(q, prev);
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const q = me(par);
    if (cm.eventType(ev) == c.GST_EVENT_RECONFIGURE) {
        lock(q);
        if (q.srcresult == c.GST_FLOW_NOT_LINKED) {
            q.srcresult = c.GST_FLOW_OK;
            _ = c.gst_pad_start_task(pad, loop, pad, null);
        }
        unlock(q);
        return c.gst_pad_push_event(q.sinkpad, ev);
    }
    return c.gst_pad_event_default(pad, par, ev);
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, qy: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const q = me(par);
    var res: c.gboolean = 0;
    if (cm.queryType(qy) == c.GST_QUERY_SCHEDULING) {
        c.gst_query_add_scheduling_mode(qy, c.GST_PAD_MODE_PUSH);
        res = 1;
    } else res = c.gst_pad_query_default(pad, par, qy);
    if (res == 0) return 0;
    switch (cm.queryType(qy)) {
        c.GST_QUERY_POSITION => {
            var pos: i64 = 0;
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_position(qy, &fmt, &pos);
            switch (fmt) {
                c.GST_FORMAT_BYTES => {
                    pos -= q.cur_level.bytes;
                    if (pos < 0) pos = 0;
                },
                c.GST_FORMAT_TIME => {
                    pos -%= @bitCast(q.cur_level.time);
                    if (pos < 0) pos = 0;
                },
                else => return 1,
            }
            c.gst_query_set_position(qy, fmt, pos);
        },
        c.GST_QUERY_LATENCY => {
            var live: c.gboolean = 0;
            var min: u64 = 0;
            var max: u64 = 0;
            c.gst_query_parse_latency(qy, &live, &min, &max);
            if (q.max_size.time > 0 and max != NONE and q.leaky == NO_LEAK) {
                max +%= q.max_size.time;
            } else if (q.max_size.time > 0 and q.leaky != NO_LEAK) {
                max = @max(q.max_size.time, max);
            } else max = NONE;
            if (q.min_threshold.time > 0) min +%= q.min_threshold.time;
            c.gst_query_set_latency(qy, live, min, max);
        },
        else => {},
    }
    return 1;
}

fn sinkActivate(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const q = me(par);
    if (mode != c.GST_PAD_MODE_PUSH) return 0;
    if (active != 0) {
        lock(q);
        q.srcresult = c.GST_FLOW_OK;
        q.eos = 0;
        q.unexpected = 0;
        unlock(q);
    } else {
        lock(q);
        q.srcresult = c.GST_FLOW_FLUSHING;
        signalDel(q);
        unlock(q);
        cm.streamLock(pad);
        lock(q);
        lockedFlush(q, true);
        unlock(q);
        cm.streamUnlock(pad);
    }
    return 1;
}

fn srcActivate(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const q = me(par);
    if (mode != c.GST_PAD_MODE_PUSH) return 0;
    if (active != 0) {
        lock(q);
        q.srcresult = c.GST_FLOW_OK;
        q.eos = 0;
        q.unexpected = 0;
        const r = c.gst_pad_start_task(pad, loop, pad, null);
        unlock(q);
        return r;
    }
    lock(q);
    q.srcresult = c.GST_FLOW_FLUSHING;
    c.g_cond_signal(&q.item_add);
    unlock(q);
    const r = c.gst_pad_stop_task(pad);
    lock(q);
    lockedFlush(q, false);
    unlock(q);
    return r;
}

fn capacityChange(q: *Self) void {
    if (q.leaky == LEAK_DOWNSTREAM) leakDownstream(q);
    signalDel(q);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const q = me(o);
    lock(q);
    defer unlock(q);
    switch (id) {
        PROP_MAX_SIZE_BYTES => {
            q.max_size.bytes = c.g_value_get_uint(v);
            capacityChange(q);
        },
        PROP_MAX_SIZE_BUFFERS => {
            q.max_size.buffers = c.g_value_get_uint(v);
            capacityChange(q);
        },
        PROP_MAX_SIZE_TIME => {
            q.max_size.time = c.g_value_get_uint64(v);
            capacityChange(q);
        },
        PROP_MIN_THRESHOLD_BYTES => {
            q.min_threshold.bytes = c.g_value_get_uint(v);
            q.orig_min_threshold.bytes = q.min_threshold.bytes;
            signalAdd(q);
        },
        PROP_MIN_THRESHOLD_BUFFERS => {
            q.min_threshold.buffers = c.g_value_get_uint(v);
            q.orig_min_threshold.buffers = q.min_threshold.buffers;
            signalAdd(q);
        },
        PROP_MIN_THRESHOLD_TIME => {
            q.min_threshold.time = c.g_value_get_uint64(v);
            q.orig_min_threshold.time = q.min_threshold.time;
            signalAdd(q);
        },
        PROP_LEAKY => q.leaky = c.g_value_get_enum(v),
        PROP_SILENT => q.silent = c.g_value_get_boolean(v),
        PROP_FLUSH_ON_EOS => q.flush_on_eos = c.g_value_get_boolean(v),
        PROP_NOTIFY_LEVELS => q.notify_levels = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 1940),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const q = me(o);
    lock(q);
    defer unlock(q);
    switch (id) {
        PROP_CUR_LEVEL_BYTES => c.g_value_set_uint(v, q.cur_level.bytes),
        PROP_CUR_LEVEL_BUFFERS => c.g_value_set_uint(v, q.cur_level.buffers),
        PROP_CUR_LEVEL_TIME => c.g_value_set_uint64(v, q.cur_level.time),
        PROP_MAX_SIZE_BYTES => c.g_value_set_uint(v, q.max_size.bytes),
        PROP_MAX_SIZE_BUFFERS => c.g_value_set_uint(v, q.max_size.buffers),
        PROP_MAX_SIZE_TIME => c.g_value_set_uint64(v, q.max_size.time),
        PROP_MIN_THRESHOLD_BYTES => c.g_value_set_uint(v, q.min_threshold.bytes),
        PROP_MIN_THRESHOLD_BUFFERS => c.g_value_set_uint(v, q.min_threshold.buffers),
        PROP_MIN_THRESHOLD_TIME => c.g_value_set_uint64(v, q.min_threshold.time),
        PROP_LEAKY => c.g_value_set_enum(v, q.leaky),
        PROP_SILENT => c.g_value_set_boolean(v, q.silent),
        PROP_FLUSH_ON_EOS => c.g_value_set_boolean(v, q.flush_on_eos),
        PROP_NOTIFY_LEVELS => c.g_value_set_boolean(v, q.notify_levels),
        else => cm.warnInvalid(FILE, o, id, spec, 1996),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const q = me(o);
    while (popItem(q)) |it| {
        if (it.is_query == 0) c.gst_mini_object_unref(it.item);
    }
    c.gst_vec_deque_free(q.queue);
    c.g_mutex_clear(&q.qlock);
    c.g_cond_clear(&q.item_add);
    c.g_cond_clear(&q.item_del);
    c.g_cond_clear(&q.query_handled);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn sig(k: c.gpointer, name: [*c]const u8, comptime field: []const u8) c.guint {
    return c.g_signal_new(name, cm.typeOfClass(k), c.G_SIGNAL_RUN_FIRST, @offsetOf(Class, field), null, null, null, c.G_TYPE_NONE, 0);
}

const PLAYING = c.G_PARAM_READWRITE | cm.MUTABLE_PLAYING | c.G_PARAM_STATIC_STRINGS;
const READ = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    sig_underrun = sig(k, "underrun", "underrun");
    sig_running = sig(k, "running", "running");
    sig_overrun = sig(k, "overrun", "overrun");
    sig_pushing = sig(k, "pushing", "pushing");
    const UMAX = std.math.maxInt(c.guint);
    const U64MAX = std.math.maxInt(u64);
    props[PROP_CUR_LEVEL_BYTES] = c.g_param_spec_uint("current-level-bytes", "Current level (kB)", "Current amount of data in the queue (bytes)", 0, UMAX, 0, READ);
    props[PROP_CUR_LEVEL_BUFFERS] = c.g_param_spec_uint("current-level-buffers", "Current level (buffers)", "Current number of buffers in the queue", 0, UMAX, 0, READ);
    props[PROP_CUR_LEVEL_TIME] = c.g_param_spec_uint64("current-level-time", "Current level (ns)", "Current amount of data in the queue (in ns)", 0, U64MAX, 0, READ);
    props[PROP_MAX_SIZE_BYTES] = c.g_param_spec_uint("max-size-bytes", "Max. size (kB)", "Max. amount of data in the queue (bytes, 0=disable)", 0, UMAX, 10 * 1024 * 1024, PLAYING);
    props[PROP_MAX_SIZE_BUFFERS] = c.g_param_spec_uint("max-size-buffers", "Max. size (buffers)", "Max. number of buffers in the queue (0=disable)", 0, UMAX, 200, PLAYING);
    props[PROP_MAX_SIZE_TIME] = c.g_param_spec_uint64("max-size-time", "Max. size (ns)", "Max. amount of data in the queue (in ns, 0=disable)", 0, U64MAX, c.GST_SECOND, PLAYING);
    props[PROP_MIN_THRESHOLD_BYTES] = c.g_param_spec_uint("min-threshold-bytes", "Min. threshold (kB)", "Min. amount of data in the queue to allow reading (bytes, 0=disable)", 0, UMAX, 0, PLAYING);
    props[PROP_MIN_THRESHOLD_BUFFERS] = c.g_param_spec_uint("min-threshold-buffers", "Min. threshold (buffers)", "Min. number of buffers in the queue to allow reading (0=disable)", 0, UMAX, 0, PLAYING);
    props[PROP_MIN_THRESHOLD_TIME] = c.g_param_spec_uint64("min-threshold-time", "Min. threshold (ns)", "Min. amount of data in the queue to allow reading (in ns, 0=disable)", 0, U64MAX, 0, PLAYING);
    props[PROP_LEAKY] = c.g_param_spec_enum("leaky", "Leaky", "Where the queue leaks, if at all", leakyType(), NO_LEAK, PLAYING);
    props[PROP_SILENT] = c.g_param_spec_boolean("silent", "Silent", "Don't emit queue signals", 0, PLAYING);
    props[PROP_FLUSH_ON_EOS] = c.g_param_spec_boolean("flush-on-eos", "Flush on EOS", "Discard all data in the queue when an EOS event is received", 0, PLAYING);
    props[PROP_NOTIFY_LEVELS] = c.g_param_spec_boolean("notify-levels", "Notify-Levels", "Whether to emit `notify` signals on levels changes or not", 0, PLAYING);
    c.g_object_class_install_properties(oc, PROP_LAST, &props);
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Queue", "Generic", "Simple data queue", "Erik Walthinsen <omega@cse.ogi.edu>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_type_mark_as_plugin_api(leakyType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const q = me(inst);
    const el: [*c]c.GstElement = @ptrCast(@alignCast(inst));
    q.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(q.sinkpad, chain, null, null);
    c.gst_pad_set_chain_list_function_full(q.sinkpad, chainList, null, null);
    c.gst_pad_set_activatemode_function_full(q.sinkpad, sinkActivate, null, null);
    c.gst_pad_set_event_full_function_full(q.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(q.sinkpad, sinkQuery, null, null);
    cm.setPadFlag(q.sinkpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(el, q.sinkpad);
    q.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_activatemode_function_full(q.srcpad, srcActivate, null, null);
    c.gst_pad_set_event_function_full(q.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(q.srcpad, srcQuery, null, null);
    cm.setPadFlag(q.srcpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(el, q.srcpad);
    q.cur_level = .{};
    q.max_size = .{ .buffers = 200, .bytes = 10 * 1024 * 1024, .time = c.GST_SECOND };
    q.min_threshold = .{};
    q.orig_min_threshold = .{};
    c.gst_segment_init(&q.sink_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&q.src_segment, c.GST_FORMAT_TIME);
    q.head_needs_discont = 0;
    q.tail_needs_discont = 0;
    q.leaky = NO_LEAK;
    q.srcresult = c.GST_FLOW_FLUSHING;
    c.g_mutex_init(&q.qlock);
    c.g_cond_init(&q.item_add);
    c.g_cond_init(&q.item_del);
    c.g_cond_init(&q.query_handled);
    q.queue = c.gst_vec_deque_new_for_struct(@sizeOf(Item), 200 * 3 / 2);
    q.sinktime = STIME_NONE;
    q.srctime = STIME_NONE;
    q.sink_start_time = STIME_NONE;
    q.sink_tainted = 0;
    q.src_tainted = 0;
    q.newseg_applied_to_src = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstQueue", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("queue", 0, "queue element");
            _ = c._gst_debug_category_new("queue_dataflow", 0, "dataflow inside the queue element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "queue", c.GST_RANK_NONE, getType()) != 0;
}
