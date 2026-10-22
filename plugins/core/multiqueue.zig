const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstmultiqueue.c";
const NONE = cm.CLOCK_NONE;
const SNONE: i64 = std.math.minInt(i64);
const MAXID: u32 = std.math.maxInt(u32);
const LEVEL_MAX = 1_000_000;
const PERCENT = LEVEL_MAX / 100;
const MS: u64 = 1_000_000;
const SEC: u64 = 1_000_000_000;

const PROP_EXTRA_SIZE_BYTES = 1;
const PROP_EXTRA_SIZE_BUFFERS = 2;
const PROP_EXTRA_SIZE_TIME = 3;
const PROP_MAX_SIZE_BYTES = 4;
const PROP_MAX_SIZE_BUFFERS = 5;
const PROP_MAX_SIZE_TIME = 6;
const PROP_USE_BUFFERING = 7;
const PROP_LOW_PERCENT = 8;
const PROP_HIGH_PERCENT = 9;
const PROP_LOW_WATERMARK = 10;
const PROP_HIGH_WATERMARK = 11;
const PROP_SYNC_BY_RUNNING_TIME = 12;
const PROP_USE_INTERLEAVE = 13;
const PROP_UNLINKED_CACHE_TIME = 14;
const PROP_MINIMUM_INTERLEAVE = 15;
const PROP_STATS = 16;

const PAD_GROUP_ID = 1;
const PAD_LEVEL_BUFFERS = 2;
const PAD_LEVEL_BYTES = 3;
const PAD_LEVEL_TIME = 4;

const Self = extern struct {
    parent: c.GstElement,
    sync_by_running_time: c.gboolean,
    use_interleave: c.gboolean,
    min_interleave_time: u64,
    nbqueues: c.guint,
    queues: [*c]c.GList,
    queues_cookie: u32,
    max_size: c.GstDataQueueSize,
    extra_size: c.GstDataQueueSize,
    use_buffering: c.gboolean,
    low_watermark: c.gint,
    high_watermark: c.gint,
    buffering: c.gboolean,
    buffering_percent: c.gint,
    counter: c.guint,
    highid: u32,
    high_time: i64,
    qlock: c.GMutex,
    reconf_lock: c.GMutex,
    numwaiting: c.gint,
    percent_changed: c.gboolean,
    post_lock: c.GMutex,
    interleave: u64,
    last_interleave_update: i64,
    interleave_incomplete: c.gboolean,
    unlinked_cache_time: u64,
};

const Class = extern struct {
    parent: c.GstElementClass,
    underrun: ?*const fn ([*c]c.GstElement) callconv(.c) void,
    overrun: ?*const fn ([*c]c.GstElement) callconv(.c) void,
};

const MqPad = extern struct {
    parent: cm.Pad,
    sq: ?*Single,
};

const Item = extern struct {
    base: c.GstDataQueueItem,
    posid: u32,
    is_query: c.gboolean,
};

const Single = struct {
    refcount: c.gint = 1,
    id: c.guint = 0,
    groupid: c.guint = 0,
    group_high_time: i64 = SNONE,
    mqueue: c.GWeakRef = undefined,
    sinkpad: c.GWeakRef = undefined,
    srcpad: c.GWeakRef = undefined,
    srcresult: c.GstFlowReturn = c.GST_FLOW_FLUSHING,
    pushed: bool = false,
    sink_segment: c.GstSegment = undefined,
    src_segment: c.GstSegment = undefined,
    sinktime: i64 = SNONE,
    srctime: i64 = SNONE,
    sink_start_time: i64 = SNONE,
    cached_sinktime: i64 = SNONE,
    sink_tainted: bool = false,
    src_tainted: bool = false,
    sink_gid: u32 = c.GST_GROUP_ID_INVALID,
    src_gid: u32 = c.GST_GROUP_ID_INVALID,
    sink_gid_changed: bool = false,
    src_gid_changed: bool = false,
    queue: ?*c.GstDataQueue = null,
    max_size: c.GstDataQueueSize = .{ .visible = 0, .bytes = 0, .time = 0 },
    extra_size: c.GstDataQueueSize = .{ .visible = 0, .bytes = 0, .time = 0 },
    cur_time: u64 = 0,
    is_eos: bool = false,
    is_segment_done: bool = false,
    is_sparse: bool = false,
    flushing: bool = false,
    active: bool = false,
    nextid: u32 = 0,
    oldid: u32 = 0,
    last_oldid: u32 = 0,
    next_time: i64 = SNONE,
    last_time: i64 = SNONE,
    turn: c.GCond = undefined,
    query_handled: c.GCond = undefined,
    last_query: bool = false,
    last_handled_query: [*c]c.GstQuery = null,
    thread: ?*c.GThread = null,
    interleave: u64 = 0,
};

var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var pad_parent: ?*c.GObjectClass = null;
var sig_underrun: c.guint = 0;
var sig_overrun: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn mp(p: anytype) *MqPad {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn queueOf(l: [*c]c.GList) *Single {
    return @ptrCast(@alignCast(l[0].data));
}

fn lockQ(m: *Self) void {
    c.g_mutex_lock(&m.qlock);
}

fn unlockQ(m: *Self) void {
    c.g_mutex_unlock(&m.qlock);
}

fn weakMq(sq: *Single) ?*Self {
    return @ptrCast(@alignCast(c.g_weak_ref_get(&sq.mqueue)));
}

fn weakPad(r: *c.GWeakRef) ?*c.GstPad {
    return @ptrCast(@alignCast(c.g_weak_ref_get(r)));
}

fn unref(p: anytype) void {
    if (p) |x| c.gst_object_unref(x);
}

fn padEos(p: ?*c.GstPad) bool {
    return cm.obj(p).flags & c.GST_PAD_FLAG_EOS != 0;
}

fn validS(t: i64) bool {
    return t != SNONE;
}

fn filled(max: anytype, v: anytype) bool {
    return max != 0 and max <= v;
}

fn runningTime(seg: *c.GstSegment, val: u64) i64 {
    if (val == NONE) return SNONE;
    var out: u64 = 0;
    const sign = c.gst_segment_to_running_time_full(seg, c.GST_FORMAT_TIME, val, &out);
    if (sign > 0) return @bitCast(out);
    if (sign < 0) return -@as(i64, @bitCast(out));
    return SNONE;
}

fn setPercent(m: *Self, p: c.gint) void {
    if (p != m.buffering_percent) {
        m.buffering_percent = p;
        m.percent_changed = 1;
    }
}

fn level(sq: *Single) c.GstDataQueueSize {
    var l: c.GstDataQueueSize = undefined;
    c.gst_data_queue_get_level(sq.queue, &l);
    return l;
}

fn singleRef(sq: *Single) *Single {
    _ = c.g_atomic_int_add(&sq.refcount, 1);
    return sq;
}

fn singleUnref(sq: *Single) void {
    if (c.g_atomic_int_dec_and_test(&sq.refcount) == 0) return;
    c.gst_data_queue_flush(sq.queue);
    c.g_object_unref(sq.queue);
    c.g_cond_clear(&sq.turn);
    c.g_cond_clear(&sq.query_handled);
    c.g_weak_ref_clear(&sq.sinkpad);
    c.g_weak_ref_clear(&sq.srcpad);
    c.g_weak_ref_clear(&sq.mqueue);
    std.heap.c_allocator.destroy(sq);
}

fn singleUnrefC(p: c.gpointer) callconv(.c) void {
    singleUnref(@ptrCast(@alignCast(p)));
}

fn padGroup(p: *MqPad) c.guint {
    const sq = p.sq orelse return 0;
    const m = weakMq(sq);
    if (m) |x| cm.lock(x);
    const r = sq.groupid;
    if (m) |x| {
        cm.unlock(x);
        c.gst_object_unref(x);
    }
    return r;
}

fn padLevel(p: *MqPad) ?c.GstDataQueueSize {
    const sq = p.sq orelse return null;
    const m = weakMq(sq);
    if (m) |x| lockQ(x);
    var l = level(sq);
    l.time = sq.cur_time;
    if (m) |x| {
        unlockQ(x);
        c.gst_object_unref(x);
    }
    return l;
}

fn padGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = mp(o);
    switch (id) {
        PAD_GROUP_ID => c.g_value_set_uint(v, padGroup(p)),
        PAD_LEVEL_BUFFERS => c.g_value_set_uint(v, if (padLevel(p)) |l| l.visible else 0),
        PAD_LEVEL_BYTES => c.g_value_set_uint(v, if (padLevel(p)) |l| l.bytes else 0),
        PAD_LEVEL_TIME => c.g_value_set_uint64(v, if (padLevel(p)) |l| l.time else 0),
        else => cm.warnInvalid(FILE, o, id, spec, 501),
    }
}

fn padSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = mp(o);
    switch (id) {
        PAD_GROUP_ID => if (p.sq) |sq| {
            const m = weakMq(sq);
            if (m) |x| cm.lock(x);
            sq.groupid = c.g_value_get_uint(v);
            if (m) |x| {
                cm.unlock(x);
                c.gst_object_unref(x);
            }
        },
        else => cm.warnInvalid(FILE, o, id, spec, 529),
    }
}

fn padFinalize(o: [*c]c.GObject) callconv(.c) void {
    if (mp(o).sq) |sq| singleUnref(sq);
    pad_parent.?.finalize.?(o);
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = padSet;
    oc.get_property = padGet;
    oc.finalize = padFinalize;
    const R = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, PAD_GROUP_ID, c.g_param_spec_uint("group-id", "Group ID", "Group to which this pad belongs", 0, std.math.maxInt(u32), 0, cm.RW));
    c.g_object_class_install_property(oc, PAD_LEVEL_BUFFERS, c.g_param_spec_uint("current-level-buffers", "Current level buffers", "Current level buffers", 0, std.math.maxInt(u32), 0, R));
    c.g_object_class_install_property(oc, PAD_LEVEL_BYTES, c.g_param_spec_uint("current-level-bytes", "Current level bytes", "Current level bytes", 0, std.math.maxInt(u32), 0, R));
    c.g_object_class_install_property(oc, PAD_LEVEL_TIME, c.g_param_spec_uint64("current-level-time", "Current level time", "Current level time", 0, std.math.maxInt(u64), 0, R));
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_pad_get_type(), c.g_intern_static_string("GstMultiQueuePad"), @sizeOf(c.GstPadClass), padClassInit, @sizeOf(MqPad), null, 0);
        }
    }.f);
}

fn eachQueue(m: *Self, comptime f: fn (*Self, *Single) void) void {
    var l = m.queues;
    while (l != null) : (l = l[0].next) f(m, queueOf(l));
}

fn bufferingLevel(sq: *Single) c.gint {
    const l = level(sq);
    if (sq.is_eos or sq.is_segment_done or sq.srcresult == c.GST_FLOW_NOT_LINKED or sq.is_sparse) return LEVEL_MAX;
    var r: c.gint = 0;
    if (sq.max_size.time > 0) r = @max(r, @as(c.gint, @truncate(@as(i64, @bitCast(c.gst_util_uint64_scale(sq.cur_time, LEVEL_MAX, sq.max_size.time))))));
    if (sq.max_size.bytes > 0) r = @max(r, @as(c.gint, @truncate(@as(i64, @bitCast(c.gst_util_uint64_scale_int(l.bytes, LEVEL_MAX, @intCast(sq.max_size.bytes)))))));
    return r;
}

fn updateBuffering(m: *Self, sq: *Single) void {
    if (m.use_buffering == 0) return;
    const lv = bufferingLevel(sq);
    var pct: c.gint = @truncate(@as(i64, @bitCast(c.gst_util_uint64_scale(@intCast(lv), 100, @intCast(m.high_watermark)))));
    if (pct > 100) pct = 100;
    if (m.buffering != 0) {
        if (lv >= m.high_watermark) m.buffering = 0;
        setPercent(m, @max(m.buffering_percent, pct));
        return;
    }
    var l = m.queues;
    while (l != null) : (l = l[0].next) {
        if (bufferingLevel(queueOf(l)) >= m.high_watermark) return;
    }
    if (lv < m.low_watermark) {
        m.buffering = 1;
        setPercent(m, pct);
    }
}

fn postBuffering(m: *Self) void {
    c.g_mutex_lock(&m.post_lock);
    lockQ(m);
    var msg: [*c]c.GstMessage = null;
    if (m.percent_changed != 0) {
        m.percent_changed = 0;
        msg = c.gst_message_new_buffering(cm.obj(m), m.buffering_percent);
    }
    unlockQ(m);
    if (msg != null) _ = c.gst_element_post_message(element(m), msg);
    c.g_mutex_unlock(&m.post_lock);
}

fn refreshQueue(m: *Self, q: *Single) void {
    updateBuffering(m, q);
    c.gst_data_queue_limits_changed(q.queue);
}

fn recheckBuffering(m: *Self) void {
    if (m.use_buffering == 0 and m.buffering != 0) {
        lockQ(m);
        m.buffering = 0;
        setPercent(m, 100);
        unlockQ(m);
    }
    if (m.use_buffering != 0) {
        lockQ(m);
        m.buffering_percent = 0;
        eachQueue(m, refreshQueue);
        unlockQ(m);
    }
    postBuffering(m);
}

fn childTime(m: *Self, q: *Single) void {
    q.max_size.time = m.max_size.time;
    refreshQueue(m, q);
}

fn childBytes(m: *Self, q: *Single) void {
    q.max_size.bytes = m.max_size.bytes;
    refreshQueue(m, q);
}

fn childVisible(m: *Self, q: *Single) void {
    q.max_size.visible = m.max_size.visible;
    refreshQueue(m, q);
}

fn calculateInterleave(m: *Self, sq: ?*Single) void {
    var low: i64 = SNONE;
    var high: i64 = SNONE;
    var other: u64 = 0;
    var inactive = false;
    var l = m.queues;
    while (l != null) : (l = l[0].next) {
        const o = queueOf(l);
        if (o.is_sparse) continue;
        if (!o.active) {
            inactive = true;
            continue;
        }
        if (sq) |s| {
            if (s.thread != o.thread) {
                if (o.interleave > other) other = o.interleave;
                continue;
            }
        }
        if (validS(o.cached_sinktime) and !o.is_eos) {
            if (low == SNONE or o.cached_sinktime < low) low = o.cached_sinktime;
            if (high == SNONE or o.cached_sinktime > high) high = o.cached_sinktime;
            if (o.cached_sinktime < 0) inactive = true;
        }
    }
    if (!validS(low) or !validS(high)) return;
    var update = high == low;
    var il: u64 = @bitCast(high - low);
    il = (150 *% il / 100) +% m.min_interleave_time;
    if (sq) |s| s.interleave = il;
    il = @max(il, other);
    if (inactive and il <= m.interleave) {
        il = @min(5 * SEC, m.interleave +% 500 * MS);
        update = true;
    }
    if ((m.interleave_incomplete != 0) != inactive) update = true;
    m.interleave_incomplete = @intFromBool(inactive);
    const stale = m.last_interleave_update +% @as(i64, @intCast(2 * @as(u64, @min(SEC, m.interleave)))) < low and il < m.interleave * 3 / 4;
    if (update or il > m.interleave or stale) {
        m.interleave = il;
        m.last_interleave_update = high;
        m.max_size.time = m.interleave;
        eachQueue(m, childTime);
    }
}

fn updateTimeLevel(m: *Self, sq: *Single) void {
    var sink = sq.sinktime;
    if (sq.sink_tainted) {
        sink = runningTime(&sq.sink_segment, sq.sink_segment.position);
        sq.sinktime = sink;
        if (sq.last_time == SNONE) sq.last_time = sink;
        sq.sink_tainted = false;
        if (sink != SNONE and m.use_interleave != 0) {
            sq.cached_sinktime = sink;
            calculateInterleave(m, sq);
        }
    }
    const start = sq.sink_start_time;
    var src = sq.srctime;
    if (sq.src_tainted) {
        src = runningTime(&sq.src_segment, sq.src_segment.position);
        sq.srctime = src;
        sq.src_tainted = false;
    }
    sq.cur_time = 0;
    if (validS(sink)) {
        if (!validS(src) and validS(start) and sink >= start) {
            sq.cur_time = @bitCast(sink - start);
        } else if (validS(src) and sink >= src) sq.cur_time = @bitCast(sink - src);
    }
    updateBuffering(m, sq);
}

fn applySegment(m: *Self, sq: *Single, ev: [*c]c.GstEvent, seg: *c.GstSegment) void {
    const is_sink = seg == &sq.sink_segment;
    var ppos: u64 = 0;
    if (seg.rate > 0.0) {
        if (is_sink and sq.sink_gid_changed) {
            ppos = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, seg.position);
            sq.sink_gid_changed = false;
        } else if (!is_sink and sq.src_gid_changed) {
            ppos = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, seg.position);
            sq.src_gid_changed = false;
        }
    }
    c.gst_event_copy_segment(ev, seg);
    if (seg.format != c.GST_FORMAT_TIME) {
        seg.format = c.GST_FORMAT_TIME;
        seg.start = 0;
        seg.stop = NONE;
        seg.time = 0;
    }
    lockQ(m);
    if (ppos != 0) seg.base = ppos;
    seg.position = if (seg.rate > 0.0) seg.start else seg.stop;
    if (is_sink) {
        sq.sink_tainted = false;
    } else sq.src_tainted = false;
    unlockQ(m);
}

fn moveTo(m: *Self, sq: *Single, seg: *c.GstSegment, ts_in: u64, dur: u64) void {
    var ts = ts_in;
    const is_sink = seg == &sq.sink_segment;
    if (is_sink and !validS(sq.sink_start_time)) sq.sink_start_time = runningTime(seg, ts);
    if (dur != NONE) ts +%= dur;
    seg.position = ts;
    if (is_sink) {
        sq.sink_tainted = true;
    } else sq.src_tainted = true;
    updateTimeLevel(m, sq);
}

fn applyBuffer(m: *Self, sq: *Single, ts: u64, dur: u64, seg: *c.GstSegment) void {
    lockQ(m);
    if (ts == NONE) {
        updateBuffering(m, sq);
    } else moveTo(m, sq, seg, ts, dur);
    unlockQ(m);
    postBuffering(m);
}

fn applyGap(m: *Self, sq: *Single, ev: [*c]c.GstEvent, seg: *c.GstSegment) void {
    var ts: u64 = 0;
    var dur: u64 = 0;
    c.gst_event_parse_gap(ev, &ts, &dur);
    if (!cm.that(ts != NONE, "apply_gap", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return;
    lockQ(m);
    moveTo(m, sq, seg, ts, dur);
    unlockQ(m);
    postBuffering(m);
}

fn bufferTime(seg: *c.GstSegment, b: [*c]c.GstBuffer, end: bool) ?i64 {
    var t = cm.dtsOrPts(b);
    if (t == NONE) return null;
    if (end and cm.buf(b).duration != NONE) t +%= cm.buf(b).duration;
    return runningTime(seg, t);
}

fn objectTime(seg: *c.GstSegment, o: [*c]c.GstMiniObject, end: bool) i64 {
    if (cm.isBuffer(o)) return bufferTime(seg, @ptrCast(o), end) orelse SNONE;
    if (cm.isBufferList(o)) {
        const l: ?*c.GstBufferList = @ptrCast(o);
        var t: i64 = SNONE;
        var i: c.guint = 0;
        while (i < c.gst_buffer_list_length(l)) : (i += 1) {
            if (bufferTime(seg, c.gst_buffer_list_get(l, i), end)) |x| {
                t = x;
                if (!end) return t;
            } else if (!end) return t;
        }
        return t;
    }
    if (cm.isEvent(o)) {
        const ev: [*c]c.GstEvent = @ptrCast(o);
        if (cm.eventType(ev) == c.GST_EVENT_SEGMENT) {
            var ns: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(ev, &ns);
            if (ns[0].format == c.GST_FORMAT_TIME) return runningTime(@ptrCast(@constCast(ns)), if (ns[0].rate > 0.0) ns[0].start else ns[0].stop);
        } else if (cm.eventType(ev) == c.GST_EVENT_GAP) {
            var ts: u64 = 0;
            var dur: u64 = 0;
            c.gst_event_parse_gap(ev, &ts, &dur);
            if (ts != NONE) {
                if (dur != NONE) ts +%= dur;
                return runningTime(seg, ts);
            }
        }
    }
    return SNONE;
}

fn pushOne(m: *Self, sq: *Single, o: [*c]c.GstMiniObject, drop: *bool) c.GstFlowReturn {
    var r = sq.srcresult;
    const src = weakPad(&sq.srcpad) orelse return c.GST_FLOW_FLUSHING;
    defer c.gst_object_unref(src);
    if (cm.isBuffer(o)) {
        const b: [*c]c.GstBuffer = @ptrCast(o);
        applyBuffer(m, sq, cm.dtsOrPts(b), cm.buf(b).duration, &sq.src_segment);
        c.gst_data_queue_limits_changed(sq.queue);
        if (drop.*) {
            c.gst_buffer_unref(b);
        } else r = c.gst_pad_push(src, b);
    } else if (cm.isEvent(o)) {
        const ev: [*c]c.GstEvent = @ptrCast(o);
        switch (cm.eventType(ev)) {
            c.GST_EVENT_SEGMENT_DONE => drop.* = false,
            c.GST_EVENT_EOS => {
                r = c.GST_FLOW_EOS;
                drop.* = false;
            },
            c.GST_EVENT_STREAM_START => {
                var gid: u32 = 0;
                if (c.gst_event_parse_group_id(ev, &gid) != 0) {
                    if (sq.src_gid == c.GST_GROUP_ID_INVALID) {
                        sq.src_gid = gid;
                    } else if (gid != sq.src_gid) {
                        sq.src_gid = gid;
                        sq.src_gid_changed = true;
                    }
                }
                r = c.GST_FLOW_OK;
                drop.* = false;
            },
            c.GST_EVENT_SEGMENT => {
                applySegment(m, sq, ev, &sq.src_segment);
                if (drop.*) {
                    r = c.GST_FLOW_OK;
                    drop.* = false;
                }
            },
            c.GST_EVENT_GAP => {
                applyGap(m, sq, ev, &sq.src_segment);
                c.gst_data_queue_limits_changed(sq.queue);
            },
            else => {},
        }
        if (drop.*) {
            c.gst_mini_object_unref(@ptrCast(ev));
        } else _ = c.gst_pad_push_event(src, ev);
    } else if (cm.isQuery(o)) {
        const q: [*c]c.GstQuery = @ptrCast(o);
        const res = !drop.* and c.gst_pad_peer_query(src, q) != 0;
        lockQ(m);
        sq.last_query = res;
        sq.last_handled_query = q;
        c.g_cond_signal(&sq.query_handled);
        unlockQ(m);
    } else c.g_log(null, c.G_LOG_LEVEL_WARNING, "Unexpected object in singlequeue %u (refcounting problem?)", sq.id);
    return r;
}

fn destroyItem(p: c.gpointer) callconv(.c) void {
    const it: *Item = @ptrCast(@alignCast(p));
    if (it.is_query == 0 and it.base.object != null) c.gst_mini_object_unref(it.base.object);
    c.g_free(it);
}

fn newItem(o: [*c]c.GstMiniObject, id: u32, buffer: bool) *Item {
    const it: *Item = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Item))));
    it.* = .{ .base = std.mem.zeroes(c.GstDataQueueItem), .posid = id, .is_query = @intFromBool(cm.isQuery(o)) };
    it.base.object = o;
    it.base.destroy = destroyItem;
    if (buffer) {
        it.base.size = @intCast(c.gst_buffer_get_size(@ptrCast(o)));
        const d = cm.buf(o).duration;
        it.base.duration = if (d == NONE) 0 else d;
        it.base.visible = 1;
    }
    return it;
}

fn shouldWait(m: *Self, sq: *Single, newid: u32, next: i64) bool {
    if (m.sync_by_running_time == 0) return newid > m.highid;
    if (sq.group_high_time == SNONE) return validS(next) and (m.high_time == SNONE or next > m.high_time);
    return validS(next) and next > sq.group_high_time;
}

fn recompute(m: *Self, sq: *Single) void {
    computeHighId(m);
    computeHighTime(m, sq.groupid);
}

fn waitTurn(m: *Self, sq: *Single, newid: u32, next_in: i64) bool {
    var next = next_in;
    sq.nextid = newid;
    if (validS(next)) next +%= @as(i64, @bitCast(m.unlinked_cache_time));
    sq.next_time = next;
    if (sq.last_oldid != MAXID) sq.oldid = sq.last_oldid;
    if (sq.srcresult == c.GST_FLOW_NOT_LINKED) {
        recompute(m, sq);
        var wait = shouldWait(m, sq, newid, next);
        while (wait and sq.srcresult == c.GST_FLOW_NOT_LINKED) {
            wakeNext(m);
            m.numwaiting += 1;
            c.g_cond_wait(&sq.turn, &m.qlock);
            m.numwaiting -= 1;
            if (sq.flushing) return false;
            computeHighTime(m, sq.groupid);
            computeHighId(m);
            wait = shouldWait(m, sq, newid, next);
        }
        recompute(m, sq);
    } else {
        recompute(m, sq);
        wakeNext(m);
    }
    sq.nextid = 0;
    sq.next_time = SNONE;
    return true;
}

fn loopFlushing(m: *Self, sq: *Single, src: ?*c.GstPad, o: [*c]c.GstMiniObject, is_query: bool) void {
    if (o != null and !is_query) c.gst_mini_object_unref(o);
    lockQ(m);
    sq.last_query = false;
    c.g_cond_signal(&sq.query_handled);
    if ((sq.is_eos or sq.is_segment_done) and sq.srcresult < c.GST_FLOW_EOS) {
        unlockQ(m);
        cm.flowError(m, sq.srcresult, FILE, "gst_multi_queue_loop", 2457);
    } else unlockQ(m);
    flushQueue(sq, false);
    underrun(sq.queue, sq);
    c.gst_data_queue_set_flushing(sq.queue, 1);
    _ = c.gst_pad_pause_task(src);
}

fn loop(data: c.gpointer) callconv(.c) void {
    const pad: ?*c.GstPad = @ptrCast(@alignCast(data));
    const sq = mp(pad).sq.?;
    const m = weakMq(sq);
    const src = weakPad(&sq.srcpad);
    defer unref(m);
    defer unref(src);
    if (m == null or src == null) return;
    const mq = m.?;
    var dropping = false;
    while (true) {
        if (sq.flushing) return loopFlushing(mq, sq, src, null, false);
        var sitem: [*c]c.GstDataQueueItem = null;
        if (c.gst_data_queue_pop(sq.queue, &sitem) == 0) return loopFlushing(mq, sq, src, null, false);
        const item: *Item = @ptrCast(@alignCast(sitem));
        const newid = item.posid;
        const is_query = item.is_query != 0;
        const o = item.base.object;
        item.base.object = null;
        destroyItem(item);
        const is_buffer = cm.isBuffer(o);
        var next = objectTime(&sq.src_segment, o, false);
        lockQ(mq);
        if (sq.srcresult == c.GST_FLOW_NOT_LINKED or sq.last_oldid == MAXID or newid != sq.last_oldid +% 1 or sq.last_oldid > mq.highid) {
            if (sq.flushing or !waitTurn(mq, sq, newid, next)) {
                unlockQ(mq);
                return loopFlushing(mq, sq, src, o, is_query);
            }
        }
        unlockQ(mq);
        if (sq.flushing) return loopFlushing(mq, sq, src, o, is_query);
        lockQ(mq);
        next = objectTime(&sq.src_segment, o, true);
        if (validS(next)) {
            if (sq.last_time == SNONE or sq.last_time < next) sq.last_time = next;
            if (mq.high_time == SNONE or mq.high_time <= next) {
                mq.high_time = next;
                wakeNext(mq);
            }
        }
        unlockQ(mq);
        var r = pushOne(mq, sq, o, &dropping);
        lockQ(mq);
        var rebuffer = false;
        if (sq.pushed and sq.srcresult == c.GST_FLOW_OK and r == c.GST_FLOW_NOT_LINKED) {
            recompute(mq, sq);
            rebuffer = true;
            if (mq.numwaiting > 0) {
                var l = mq.queues;
                while (l != null) : (l = l[0].next) {
                    const q2 = queueOf(l);
                    if (q2.srcresult == c.GST_FLOW_NOT_LINKED) {
                        q2.pushed = false;
                        q2.srcresult = c.GST_FLOW_OK;
                        c.g_cond_signal(&q2.turn);
                    }
                }
            }
        }
        if (is_buffer) sq.pushed = true;
        if (r == c.GST_FLOW_EOS and !dropping and sq.srcresult != c.GST_FLOW_NOT_LINKED) {
            dropping = true;
            r = sq.srcresult;
        } else if (dropping and c.gst_data_queue_is_empty(sq.queue) != 0) r = c.GST_FLOW_EOS;
        sq.srcresult = r;
        sq.last_oldid = newid;
        if (rebuffer) updateBuffering(mq, sq);
        unlockQ(mq);
        postBuffering(mq);
        lockQ(mq);
        if (mq.numwaiting > 0 and (padEos(src) or sq.srcresult == c.GST_FLOW_EOS)) {
            computeHighTime(mq, sq.groupid);
            computeHighId(mq);
            wakeNext(mq);
        }
        unlockQ(mq);
        if (dropping) continue;
        if (r != c.GST_FLOW_OK and r != c.GST_FLOW_NOT_LINKED and r != c.GST_FLOW_EOS) return loopFlushing(mq, sq, src, null, false);
        return;
    }
}

fn chain(pad: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const sq = mp(pad).sq.?;
    const mq = weakMq(sq) orelse return sq.srcresult;
    defer c.gst_object_unref(mq);
    if (sq.is_eos) {
        c.gst_buffer_unref(b);
        return c.GST_FLOW_EOS;
    }
    sq.active = true;
    const id: u32 = @bitCast(c.g_atomic_int_add(@as(*c.gint, @ptrCast(&mq.counter)), 1));
    const ts = cm.dtsOrPts(b);
    const dur = cm.buf(b).duration;
    const item = newItem(@ptrCast(b), id, true);
    if (mq.use_interleave != 0) {
        lockQ(mq);
        var v = ts;
        if (v == NONE) v = sq.sink_segment.position;
        if (dur != NONE) v +%= dur;
        const dv = runningTime(&sq.sink_segment, v);
        if (validS(dv)) {
            sq.cached_sinktime = dv;
            calculateInterleave(mq, sq);
        }
        unlockQ(mq);
    }
    if (c.gst_data_queue_push(sq.queue, &item.base) == 0) {
        destroyItem(item);
        return sq.srcresult;
    }
    applyBuffer(mq, sq, ts, dur, &sq.sink_segment);
    return sq.srcresult;
}

fn sinkMode(pad: ?*c.GstPad, _: [*c]c.GstObject, mode: c.GstPadMode, on: c.gboolean) callconv(.c) c.gboolean {
    const sq = mp(pad).sq.?;
    const m: ?*Self = @ptrCast(@alignCast(c.gst_object_get_parent(cm.obj(pad))));
    if (m) |x| lockQ(x);
    var res: c.gboolean = 0;
    if (mode == c.GST_PAD_MODE_PUSH) {
        res = 1;
        if (on != 0) {
            sq.srcresult = c.GST_FLOW_OK;
            sq.pushed = false;
            c.gst_data_queue_set_flushing(sq.queue, 0);
        } else {
            sq.srcresult = c.GST_FLOW_FLUSHING;
            sq.last_query = false;
            c.g_cond_signal(&sq.query_handled);
            c.gst_data_queue_set_flushing(sq.queue, 1);
            if (m) |x| unlockQ(x);
            cm.streamLock(pad);
            if (m) |x| lockQ(x);
            c.gst_data_queue_flush(sq.queue);
            if (m) |x| unlockQ(x);
            cm.streamUnlock(pad);
            if (m) |x| lockQ(x);
        }
    }
    if (m) |x| {
        unlockQ(x);
        c.gst_object_unref(x);
    }
    return res;
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.GstFlowReturn {
    const sq = mp(pad).sq.?;
    const mq = me(par);
    const src = weakPad(&sq.srcpad) orelse return c.GST_FLOW_FLUSHING;
    defer c.gst_object_unref(src);
    const t = cm.eventType(ev);
    var sref: [*c]c.GstEvent = null;
    var timed = false;
    switch (t) {
        c.GST_EVENT_STREAM_START => {
            var gid: u32 = 0;
            if (c.gst_event_parse_group_id(ev, &gid) != 0) {
                if (sq.sink_gid == c.GST_GROUP_ID_INVALID) {
                    sq.sink_gid = gid;
                } else if (gid != sq.sink_gid) {
                    sq.sink_gid = gid;
                    sq.sink_gid_changed = true;
                }
            }
            if (mq.sync_by_running_time != 0) {
                var fl: c.GstStreamFlags = 0;
                c.gst_event_parse_stream_flags(ev, &fl);
                if (fl & c.GST_STREAM_FLAG_SPARSE != 0) sq.is_sparse = true;
            }
            sq.thread = c.g_thread_self();
            sq.is_eos = false;
        },
        c.GST_EVENT_FLUSH_START => {
            const ok = c.gst_pad_push_event(src, ev);
            flush(mq, sq, true, false);
            _ = c.gst_pad_pause_task(src);
            return if (ok != 0) c.GST_FLOW_OK else c.GST_FLOW_ERROR;
        },
        c.GST_EVENT_FLUSH_STOP => {
            const ok = c.gst_pad_push_event(src, ev);
            flush(mq, sq, false, false);
            _ = c.gst_pad_start_task(src, loop, src, null);
            return if (ok != 0) c.GST_FLOW_OK else c.GST_FLOW_ERROR;
        },
        c.GST_EVENT_SEGMENT => {
            sq.is_segment_done = false;
            sref = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev))));
        },
        c.GST_EVENT_GAP => {
            sref = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev))));
            if (mq.use_interleave != 0) {
                var v: u64 = 0;
                var dur: u64 = 0;
                c.gst_event_parse_gap(ev, &v, &dur);
                if (v != NONE) {
                    lockQ(mq);
                    if (dur != NONE) v +%= dur;
                    const st = runningTime(&sq.sink_segment, v);
                    if (validS(st)) {
                        sq.cached_sinktime = st;
                        calculateInterleave(mq, sq);
                    }
                    unlockQ(mq);
                }
            }
            timed = true;
        },
        else => if (!cm.eventSerialized(ev)) {
            return if (c.gst_pad_push_event(src, ev) != 0) c.GST_FLOW_OK else c.GST_FLOW_ERROR;
        },
    }
    if (sq.is_eos) {
        c.gst_mini_object_unref(@ptrCast(ev));
        if (sref != null) c.gst_mini_object_unref(@ptrCast(sref));
        return c.GST_FLOW_EOS;
    }
    const id: u32 = @bitCast(c.g_atomic_int_add(@as(*c.gint, @ptrCast(&mq.counter)), 1));
    const item = newItem(@ptrCast(ev), id, false);
    const ok = if (timed) c.gst_data_queue_push(sq.queue, &item.base) else c.gst_data_queue_push_force(sq.queue, &item.base);
    if (ok == 0) {
        if (sref != null) c.gst_mini_object_unref(@ptrCast(sref));
        destroyItem(item);
        return sq.srcresult;
    }
    switch (t) {
        c.GST_EVENT_SEGMENT_DONE, c.GST_EVENT_EOS => {
            if (t == c.GST_EVENT_SEGMENT_DONE) {
                sq.is_segment_done = true;
            } else {
                lockQ(mq);
                sq.is_eos = true;
                const res = sq.srcresult;
                unlockQ(mq);
                if (res < c.GST_FLOW_EOS) cm.flowError(mq, res, FILE, "gst_multi_queue_sink_event", 2778);
            }
            lockQ(mq);
            updateBuffering(mq, sq);
            unlockQ(mq);
            overrun(sq.queue, sq);
            postBuffering(mq);
        },
        c.GST_EVENT_SEGMENT => {
            applySegment(mq, sq, sref, &sq.sink_segment);
            c.gst_mini_object_unref(@ptrCast(sref));
            lockQ(mq);
            if (sq.srcresult == c.GST_FLOW_EOS) sq.srcresult = c.GST_FLOW_OK;
            unlockQ(mq);
        },
        c.GST_EVENT_GAP => {
            sq.active = true;
            applyGap(mq, sq, sref, &sq.sink_segment);
            c.gst_mini_object_unref(@ptrCast(sref));
        },
        else => {},
    }
    return c.GST_FLOW_OK;
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const sq = mp(pad).sq.?;
    const mq = me(par);
    if (!cm.querySerialized(q)) return c.gst_pad_query_default(pad, par, q);
    lockQ(mq);
    defer unlockQ(mq);
    if (sq.srcresult != c.GST_FLOW_OK) return 0;
    if (mq.use_buffering != 0 and c.gst_data_queue_is_empty(sq.queue) == 0) return 0;
    const id: u32 = @bitCast(c.g_atomic_int_add(@as(*c.gint, @ptrCast(&mq.counter)), 1));
    const item = newItem(@ptrCast(q), id, false);
    unlockQ(mq);
    const pushed = c.gst_data_queue_push(sq.queue, &item.base) != 0;
    lockQ(mq);
    if (!pushed or sq.flushing) return 0;
    while (!sq.flushing and sq.srcresult == c.GST_FLOW_OK and sq.last_handled_query != q) c.g_cond_wait(&sq.query_handled, &mq.qlock);
    const res = sq.last_query;
    sq.last_handled_query = null;
    return @intFromBool(res);
}

fn srcMode(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, on: c.gboolean) callconv(.c) c.gboolean {
    const sq = mp(pad).sq.?;
    const mq = weakMq(sq) orelse return 0;
    defer c.gst_object_unref(mq);
    if (mode != c.GST_PAD_MODE_PUSH) return 0;
    const src = weakPad(&sq.srcpad);
    defer unref(src);
    if (on != 0) {
        flush(mq, sq, false, true);
        if (par == null) return 1;
        return if (src) |s| c.gst_pad_start_task(s, loop, s, null) else 0;
    }
    flush(mq, sq, true, true);
    return if (src) |s| c.gst_pad_stop_task(s) else 0;
}

fn srcEvent(pad: ?*c.GstPad, _: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const sq = mp(pad).sq.?;
    const m = weakMq(sq);
    const sink = weakPad(&sq.sinkpad);
    defer unref(m);
    defer unref(sink);
    if (m == null or sink == null) return 0;
    const mq = m.?;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_LATENCY => {
            var lat: u64 = NONE;
            c.gst_event_parse_latency(ev, &lat);
            if (lat != NONE) {
                lockQ(mq);
                if (lat > mq.min_interleave_time) {
                    mq.min_interleave_time = lat;
                    if (mq.use_interleave != 0) calculateInterleave(mq, null);
                }
                unlockQ(mq);
            }
        },
        c.GST_EVENT_RECONFIGURE => {
            lockQ(mq);
            if (sq.srcresult == c.GST_FLOW_NOT_LINKED) {
                sq.srcresult = c.GST_FLOW_OK;
                c.g_cond_signal(&sq.turn);
            }
            unlockQ(mq);
        },
        else => {},
    }
    return c.gst_pad_push_event(sink, ev);
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    return c.gst_pad_query_default(pad, par, q);
}

fn internalLinks(pad: ?*c.GstPad, _: [*c]c.GstObject) callconv(.c) [*c]c.GstIterator {
    const sq = mp(pad).sq.?;
    const other = switch (cm.pad(pad).direction) {
        c.GST_PAD_SRC => weakPad(&sq.sinkpad),
        c.GST_PAD_SINK => weakPad(&sq.srcpad),
        else => {
            c.g_return_if_fail_warning(null, "gst_multi_queue_iterate_internal_links", null);
            return null;
        },
    } orelse return null;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_pad_get_type());
    c.g_value_take_object(&v, other);
    const it = c.gst_iterator_new_single(c.gst_pad_get_type(), &v);
    c.g_value_unset(&v);
    return it;
}

fn wakeNext(m: *Self) void {
    if (m.numwaiting < 1) return;
    var l = m.queues;
    if (m.sync_by_running_time != 0 and validS(m.high_time)) {
        while (l != null) : (l = l[0].next) {
            const sq = queueOf(l);
            if (sq.srcresult != c.GST_FLOW_NOT_LINKED) continue;
            const high = if (validS(sq.group_high_time)) sq.group_high_time else m.high_time;
            if (validS(sq.next_time) and validS(high) and sq.next_time <= high) c.g_cond_signal(&sq.turn);
        }
        return;
    }
    while (l != null) : (l = l[0].next) {
        const sq = queueOf(l);
        if (sq.srcresult == c.GST_FLOW_NOT_LINKED and sq.nextid != 0 and sq.nextid <= m.highid) c.g_cond_signal(&sq.turn);
    }
}

fn computeHighId(m: *Self) void {
    var lowest: u32 = MAXID;
    var highid: u32 = MAXID;
    var l = m.queues;
    while (l != null) : (l = l[0].next) {
        const sq = queueOf(l);
        const src = weakPad(&sq.srcpad) orelse continue;
        defer c.gst_object_unref(src);
        if (sq.nextid == 0) continue;
        if (sq.srcresult == c.GST_FLOW_NOT_LINKED) {
            if (sq.nextid < lowest) lowest = sq.nextid;
        } else if (!padEos(src) and sq.srcresult != c.GST_FLOW_EOS) {
            if (highid == MAXID or sq.oldid > highid) highid = sq.oldid;
        }
    }
    m.highid = if (highid == MAXID or lowest < highid) lowest else highid;
}

fn computeHighTime(m: *Self, group: c.guint) void {
    if (m.sync_by_running_time == 0) return;
    var highest: i64 = SNONE;
    var lowest: i64 = SNONE;
    var ghigh: i64 = SNONE;
    var glow: i64 = SNONE;
    var count: c.guint = 0;
    var l = m.queues;
    while (l != null) : (l = l[0].next) {
        const sq = queueOf(l);
        const src = weakPad(&sq.srcpad) orelse continue;
        defer c.gst_object_unref(src);
        if (sq.groupid == group) count += 1;
        if (sq.srcresult == c.GST_FLOW_NOT_LINKED) {
            if (!validS(sq.next_time)) continue;
            if (lowest == SNONE or sq.next_time < lowest) lowest = sq.next_time;
            if (sq.groupid == group and (glow == SNONE or sq.next_time < glow)) glow = sq.next_time;
        } else if (!padEos(src) and sq.srcresult != c.GST_FLOW_EOS) {
            if (highest == SNONE or (sq.last_time != SNONE and sq.last_time > highest)) highest = sq.last_time;
            if (sq.groupid == group and (ghigh == SNONE or (sq.last_time != SNONE and sq.last_time > ghigh))) ghigh = sq.last_time;
        }
    }
    m.high_time = if (highest == SNONE) lowest else highest;
    const res: i64 = if (count < 2) SNONE else if (ghigh == SNONE) glow else ghigh;
    l = m.queues;
    while (l != null) : (l = l[0].next) {
        const sq = queueOf(l);
        if (sq.groupid == group) sq.group_high_time = res;
    }
}

fn overrun(_: ?*c.GstDataQueue, data: c.gpointer) callconv(.c) void {
    const sq: *Single = @ptrCast(@alignCast(data));
    const mq = weakMq(sq) orelse return;
    defer c.gst_object_unref(mq);
    const size = level(sq);
    var full = true;
    lockQ(mq);
    if (!(sq.is_eos or filled(sq.max_size.bytes, size.bytes) or (!sq.is_sparse and filled(sq.max_size.time, sq.cur_time)))) {
        var empty = false;
        var l = mq.queues;
        while (l != null) : (l = l[0].next) {
            const o = queueOf(l);
            if (o == sq or o.srcresult == c.GST_FLOW_NOT_LINKED) continue;
            if (c.gst_data_queue_is_empty(o.queue) != 0 and !o.is_sparse) {
                empty = true;
                break;
            }
        }
        if (empty and filled(sq.max_size.visible, size.visible)) {
            sq.max_size.visible = size.visible + 1;
            full = false;
        }
    }
    unlockQ(mq);
    if (full) c.g_signal_emit(mq, sig_overrun, 0);
}

fn underrun(_: ?*c.GstDataQueue, data: c.gpointer) callconv(.c) void {
    const sq: *Single = @ptrCast(@alignCast(data));
    const mq = weakMq(sq) orelse return;
    defer c.gst_object_unref(mq);
    if (sq.srcresult == c.GST_FLOW_NOT_LINKED) return;
    var empty = true;
    lockQ(mq);
    var l = mq.queues;
    while (l != null) : (l = l[0].next) {
        const o = queueOf(l);
        if (c.gst_data_queue_is_full(o.queue) != 0) {
            const sz = level(o);
            if (filled(o.max_size.visible, sz.visible)) {
                o.max_size.visible = sz.visible + 1;
                c.gst_data_queue_limits_changed(o.queue);
            }
        }
        if (c.gst_data_queue_is_empty(o.queue) == 0 or o.is_sparse) empty = false;
    }
    unlockQ(mq);
    if (empty) c.g_signal_emit(mq, sig_underrun, 0);
}

fn checkFull(_: ?*c.GstDataQueue, visible: c.guint, bytes: c.guint, _: u64, data: c.gpointer) callconv(.c) c.gboolean {
    const sq: *Single = @ptrCast(@alignCast(data));
    const mq = weakMq(sq) orelse return 1;
    defer c.gst_object_unref(mq);
    if (sq.is_eos or sq.is_segment_done) return 1;
    if (mq.use_buffering == 0 and filled(sq.max_size.visible, visible)) return 1;
    var res = filled(sq.max_size.bytes, bytes);
    if (!sq.is_sparse or mq.sync_by_running_time == 0) {
        if (mq.sync_by_running_time != 0 and sq.srcresult == c.GST_FLOW_NOT_LINKED) {
            if (sq.cur_time > mq.unlinked_cache_time) {
                res = res or filled(sq.max_size.time, sq.cur_time - mq.unlinked_cache_time);
            } else res = false;
        } else res = res or filled(sq.max_size.time, sq.cur_time);
    }
    return @intFromBool(res);
}

fn flushQueue(sq: *Single, full: bool) void {
    const src = weakPad(&sq.srcpad);
    const mq = weakMq(sq);
    var was = false;
    while (c.gst_data_queue_is_empty(sq.queue) == 0) {
        var sitem: [*c]c.GstDataQueueItem = null;
        if (c.gst_data_queue_pop(sq.queue, &sitem) == 0) {
            was = true;
            c.gst_data_queue_set_flushing(sq.queue, 0);
            continue;
        }
        const item: *Item = @ptrCast(@alignCast(sitem));
        const d = sitem[0].object;
        if (!full and item.is_query == 0 and cm.isEvent(d) and src != null and cm.eventSticky(d) and cm.eventType(d) != c.GST_EVENT_SEGMENT and cm.eventType(d) != c.GST_EVENT_EOS) _ = c.gst_pad_store_sticky_event(src, @ptrCast(d));
        sitem[0].destroy.?(sitem);
    }
    unref(src);
    c.gst_data_queue_flush(sq.queue);
    if (was) c.gst_data_queue_set_flushing(sq.queue, 1);
    if (mq) |m| {
        lockQ(m);
        updateBuffering(m, sq);
        unlockQ(m);
        postBuffering(m);
        c.gst_object_unref(m);
    }
}

fn flush(mq: *Self, sq: *Single, on: bool, full: bool) void {
    if (on) {
        lockQ(mq);
        sq.srcresult = c.GST_FLOW_FLUSHING;
        c.gst_data_queue_set_flushing(sq.queue, 1);
        sq.flushing = true;
        c.g_cond_signal(&sq.turn);
        sq.last_query = false;
        c.g_cond_signal(&sq.query_handled);
        unlockQ(mq);
        return;
    }
    flushQueue(sq, full);
    lockQ(mq);
    c.gst_segment_init(&sq.sink_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&sq.src_segment, c.GST_FORMAT_TIME);
    sq.srcresult = c.GST_FLOW_OK;
    sq.pushed = false;
    sq.cur_time = 0;
    sq.max_size.visible = mq.max_size.visible;
    sq.is_eos = false;
    sq.is_segment_done = false;
    sq.nextid = 0;
    sq.oldid = 0;
    sq.last_oldid = MAXID;
    sq.sinktime = SNONE;
    sq.srctime = SNONE;
    sq.sink_start_time = SNONE;
    sq.next_time = SNONE;
    sq.last_time = SNONE;
    sq.cached_sinktime = SNONE;
    sq.group_high_time = SNONE;
    c.gst_data_queue_set_flushing(sq.queue, 0);
    sq.active = false;
    mq.high_time = SNONE;
    sq.flushing = false;
    sq.sink_tainted = false;
    sq.src_tainted = false;
    unlockQ(mq);
}

fn newPad(dir_t: *c.GstStaticPadTemplate, comptime fmt: [:0]const u8, id: c.guint, ref: *c.GWeakRef) ?*c.GstPad {
    const name = c.g_strdup_printf(fmt, id);
    const tmpl = c.gst_static_pad_template_get(dir_t);
    const p: ?*c.GstPad = @ptrCast(@alignCast(c.g_object_new(padType(), "name", name, "direction", tmpl[0].direction, "template", tmpl, @as(?*anyopaque, null))));
    c.g_weak_ref_init(ref, p);
    c.gst_object_unref(tmpl);
    c.g_free(name);
    return p;
}

fn newSingle(mq: *Self, want: c.guint) ?*Single {
    var id: c.guint = if (want == MAXID) 0 else want;
    lockQ(mq);
    var at = mq.queues;
    while (at != null) : (at = at[0].next) {
        const o = queueOf(at);
        if (o.id == id) {
            if (want != MAXID) {
                unlockQ(mq);
                return null;
            }
            id = o.id + 1;
        } else if (o.id > id) break;
    }
    const sq = std.heap.c_allocator.create(Single) catch {
        unlockQ(mq);
        return null;
    };
    sq.* = .{};
    mq.nbqueues += 1;
    sq.id = id;
    mq.queues = c.g_list_insert_before(mq.queues, at, sq);
    mq.queues_cookie +%= 1;
    sq.max_size = mq.max_size;
    sq.extra_size = mq.extra_size;
    c.g_weak_ref_init(&sq.mqueue, mq);
    sq.queue = c.gst_data_queue_new(checkFull, overrun, underrun, sq);
    c.gst_segment_init(&sq.sink_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&sq.src_segment, c.GST_FORMAT_TIME);
    c.g_cond_init(&sq.turn);
    c.g_cond_init(&sq.query_handled);
    const sink = newPad(&sink_t, "sink_%u", sq.id, &sq.sinkpad);
    mp(sink).sq = sq;
    c.gst_pad_set_chain_function_full(sink, chain, null, null);
    c.gst_pad_set_activatemode_function_full(sink, sinkMode, null, null);
    c.gst_pad_set_event_full_function_full(sink, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(sink, sinkQuery, null, null);
    c.gst_pad_set_iterate_internal_links_function_full(sink, internalLinks, null, null);
    cm.setPadFlag(sink, c.GST_PAD_FLAG_PROXY_CAPS);
    const src = newPad(&src_t, "src_%u", sq.id, &sq.srcpad);
    mp(src).sq = singleRef(sq);
    c.gst_pad_set_activatemode_function_full(src, srcMode, null, null);
    c.gst_pad_set_event_function_full(src, srcEvent, null, null);
    c.gst_pad_set_query_function_full(src, srcQuery, null, null);
    c.gst_pad_set_iterate_internal_links_function_full(src, internalLinks, null, null);
    cm.setPadFlag(src, c.GST_PAD_FLAG_PROXY_CAPS);
    unlockQ(mq);
    const el = element(mq);
    c.g_rec_mutex_lock(&el[0].state_lock);
    const live = el[0].target_state != c.GST_STATE_NULL;
    if (live) {
        _ = c.gst_pad_set_active(src, 1);
        _ = c.gst_pad_set_active(sink, 1);
    }
    _ = c.gst_element_add_pad(el, src);
    _ = c.gst_element_add_pad(el, sink);
    if (live) _ = c.gst_pad_start_task(src, loop, src, null);
    c.g_rec_mutex_unlock(&el[0].state_lock);
    return sq;
}

fn requestPad(el: [*c]c.GstElement, _: [*c]c.GstPadTemplate, name: [*c]const u8, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    const mq = me(el);
    var id: c.guint = MAXID;
    if (name != null) _ = c.sscanf(name + 4, "_%u", &id);
    c.g_mutex_lock(&mq.reconf_lock);
    const sq = newSingle(mq, id);
    c.g_mutex_unlock(&mq.reconf_lock);
    const p = if (sq) |s| weakPad(&s.sinkpad) else null;
    if (p) |x| c.gst_object_unref(x);
    return p;
}

fn releasePad(el: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const mq = me(el);
    c.g_mutex_lock(&mq.reconf_lock);
    lockQ(mq);
    var l = mq.queues;
    var sink: ?*c.GstPad = null;
    var src: ?*c.GstPad = null;
    while (l != null) : (l = l[0].next) {
        sink = weakPad(&queueOf(l).sinkpad);
        if (sink == pad) {
            src = weakPad(&queueOf(l).srcpad);
            break;
        }
        unref(sink);
        sink = null;
    }
    if (l == null) {
        unref(sink);
        unlockQ(mq);
        c.g_mutex_unlock(&mq.reconf_lock);
        return;
    }
    const sq = queueOf(l);
    mq.queues = c.g_list_delete_link(mq.queues, l);
    mq.queues_cookie +%= 1;
    unlockQ(mq);
    c.gst_data_queue_set_flushing(sq.queue, 1);
    _ = c.gst_pad_set_active(src, 0);
    _ = c.gst_pad_set_active(sink, 0);
    _ = c.gst_element_remove_pad(el, src);
    _ = c.gst_element_remove_pad(el, sink);
    unref(src);
    unref(sink);
    c.g_mutex_unlock(&mq.reconf_lock);
}

fn readyQueue(_: *Self, q: *Single) void {
    q.flushing = false;
    q.sink_gid = c.GST_GROUP_ID_INVALID;
    q.src_gid = c.GST_GROUP_ID_INVALID;
}

fn stopQueue(_: *Self, q: *Single) void {
    q.flushing = true;
    c.g_cond_signal(&q.turn);
    q.last_query = false;
    c.g_cond_signal(&q.query_handled);
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const mq = me(el);
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            lockQ(mq);
            eachQueue(mq, readyQueue);
            eachQueue(mq, childVisible);
            unlockQ(mq);
            postBuffering(mq);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lockQ(mq);
            eachQueue(mq, stopQueue);
            mq.interleave_incomplete = 0;
            unlockQ(mq);
        },
        else => {},
    }
    return parent.?.change_state.?(el, t);
}

fn stats(mq: *Self) ?*c.GstStructure {
    const ret = c.gst_structure_new_empty("application/x-gst-multi-queue-stats");
    if (mq.queues == null) return ret;
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    var l = mq.queues;
    while (l != null) : (l = l[0].next) {
        const sq = queueOf(l);
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.gst_structure_get_type());
        const lv = level(sq);
        const id = c.g_strdup_printf("queue_%d", sq.id);
        const s = c.gst_structure_new(id, "buffers", c.G_TYPE_UINT, lv.visible, "bytes", c.G_TYPE_UINT, lv.bytes, "time", c.G_TYPE_UINT64, sq.cur_time, @as(?*anyopaque, null));
        c.g_value_take_boxed(&v, s);
        c.gst_value_array_append_and_take_value(&arr, &v);
        c.g_free(id);
    }
    c.gst_structure_take_value(ret, "queues", &arr);
    return ret;
}

fn setMaxBuffers(mq: *Self, n: c.guint) void {
    mq.max_size.visible = n;
    var l = mq.queues;
    while (l != null) : (l = l[0].next) {
        const q = queueOf(l);
        const lv = level(q);
        if (n == 0) {
            q.max_size.visible = 0;
        } else if (q.max_size.visible == 0) {
            q.max_size.visible = @max(n, lv.visible);
        } else if (n > lv.visible) q.max_size.visible = n;
        refreshQueue(mq, q);
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const mq = me(o);
    switch (id) {
        PROP_MAX_SIZE_BYTES, PROP_MAX_SIZE_BUFFERS, PROP_MAX_SIZE_TIME, PROP_UNLINKED_CACHE_TIME => {
            lockQ(mq);
            switch (id) {
                PROP_MAX_SIZE_BYTES => {
                    mq.max_size.bytes = c.g_value_get_uint(v);
                    eachQueue(mq, childBytes);
                },
                PROP_MAX_SIZE_BUFFERS => setMaxBuffers(mq, c.g_value_get_uint(v)),
                PROP_MAX_SIZE_TIME => {
                    mq.max_size.time = c.g_value_get_uint64(v);
                    eachQueue(mq, childTime);
                },
                else => mq.unlinked_cache_time = c.g_value_get_uint64(v),
            }
            unlockQ(mq);
            postBuffering(mq);
        },
        PROP_EXTRA_SIZE_BYTES => mq.extra_size.bytes = c.g_value_get_uint(v),
        PROP_EXTRA_SIZE_BUFFERS => mq.extra_size.visible = c.g_value_get_uint(v),
        PROP_EXTRA_SIZE_TIME => mq.extra_size.time = c.g_value_get_uint64(v),
        PROP_USE_BUFFERING, PROP_LOW_PERCENT, PROP_HIGH_PERCENT, PROP_LOW_WATERMARK, PROP_HIGH_WATERMARK => {
            switch (id) {
                PROP_USE_BUFFERING => mq.use_buffering = c.g_value_get_boolean(v),
                PROP_LOW_PERCENT => mq.low_watermark = c.g_value_get_int(v) * PERCENT,
                PROP_HIGH_PERCENT => mq.high_watermark = c.g_value_get_int(v) * PERCENT,
                PROP_LOW_WATERMARK => mq.low_watermark = @intFromFloat(c.g_value_get_double(v) * LEVEL_MAX),
                else => mq.high_watermark = @intFromFloat(c.g_value_get_double(v) * LEVEL_MAX),
            }
            recheckBuffering(mq);
        },
        PROP_SYNC_BY_RUNNING_TIME => mq.sync_by_running_time = c.g_value_get_boolean(v),
        PROP_USE_INTERLEAVE => mq.use_interleave = c.g_value_get_boolean(v),
        PROP_MINIMUM_INTERLEAVE => {
            lockQ(mq);
            mq.min_interleave_time = c.g_value_get_uint64(v);
            if (mq.use_interleave != 0) calculateInterleave(mq, null);
            unlockQ(mq);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1035),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const mq = me(o);
    lockQ(mq);
    defer unlockQ(mq);
    switch (id) {
        PROP_EXTRA_SIZE_BYTES => c.g_value_set_uint(v, mq.extra_size.bytes),
        PROP_EXTRA_SIZE_BUFFERS => c.g_value_set_uint(v, mq.extra_size.visible),
        PROP_EXTRA_SIZE_TIME => c.g_value_set_uint64(v, mq.extra_size.time),
        PROP_MAX_SIZE_BYTES => c.g_value_set_uint(v, mq.max_size.bytes),
        PROP_MAX_SIZE_BUFFERS => c.g_value_set_uint(v, mq.max_size.visible),
        PROP_MAX_SIZE_TIME => c.g_value_set_uint64(v, mq.max_size.time),
        PROP_USE_BUFFERING => c.g_value_set_boolean(v, mq.use_buffering),
        PROP_LOW_PERCENT => c.g_value_set_int(v, @divTrunc(mq.low_watermark, PERCENT)),
        PROP_HIGH_PERCENT => c.g_value_set_int(v, @divTrunc(mq.high_watermark, PERCENT)),
        PROP_LOW_WATERMARK => c.g_value_set_double(v, @as(f64, @floatFromInt(mq.low_watermark)) / LEVEL_MAX),
        PROP_HIGH_WATERMARK => c.g_value_set_double(v, @as(f64, @floatFromInt(mq.high_watermark)) / LEVEL_MAX),
        PROP_SYNC_BY_RUNNING_TIME => c.g_value_set_boolean(v, mq.sync_by_running_time),
        PROP_USE_INTERLEAVE => c.g_value_set_boolean(v, mq.use_interleave),
        PROP_UNLINKED_CACHE_TIME => c.g_value_set_uint64(v, mq.unlinked_cache_time),
        PROP_MINIMUM_INTERLEAVE => c.g_value_set_uint64(v, mq.min_interleave_time),
        PROP_STATS => c.g_value_take_boxed(v, stats(mq)),
        else => cm.warnInvalid(FILE, o, id, spec, 1138),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const mq = me(o);
    c.g_list_free_full(mq.queues, singleUnrefC);
    mq.queues = null;
    mq.queues_cookie +%= 1;
    c.g_mutex_clear(&mq.qlock);
    c.g_mutex_clear(&mq.reconf_lock);
    c.g_mutex_clear(&mq.post_lock);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    sig_underrun = c.g_signal_new("underrun", cm.typeOfClass(k), c.G_SIGNAL_RUN_FIRST, @offsetOf(Class, "underrun"), null, null, null, c.G_TYPE_NONE, 0);
    sig_overrun = c.g_signal_new("overrun", cm.typeOfClass(k), c.G_SIGNAL_RUN_FIRST, @offsetOf(Class, "overrun"), null, null, null, c.G_TYPE_NONE, 0);
    const P = cm.RW | cm.MUTABLE_PLAYING;
    const U = std.math.maxInt(c.guint);
    const U64 = std.math.maxInt(u64);
    c.g_object_class_install_property(oc, PROP_MAX_SIZE_BYTES, c.g_param_spec_uint("max-size-bytes", "Max. size (kB)", "Max. amount of data in the queue (bytes, 0=disable)", 0, U, 10 * 1024 * 1024, P));
    c.g_object_class_install_property(oc, PROP_MAX_SIZE_BUFFERS, c.g_param_spec_uint("max-size-buffers", "Max. size (buffers)", "Max. number of buffers in the queue (0=disable)", 0, U, 5, P));
    c.g_object_class_install_property(oc, PROP_MAX_SIZE_TIME, c.g_param_spec_uint64("max-size-time", "Max. size (ns)", "Max. amount of data in the queue (in ns, 0=disable)", 0, U64, 2 * SEC, P));
    c.g_object_class_install_property(oc, PROP_EXTRA_SIZE_BYTES, c.g_param_spec_uint("extra-size-bytes", "Extra Size (kB)", "Amount of data the queues can grow if one of them is empty (bytes, 0=disable) (NOT IMPLEMENTED)", 0, U, 10 * 1024 * 1024, cm.RW));
    c.g_object_class_install_property(oc, PROP_EXTRA_SIZE_BUFFERS, c.g_param_spec_uint("extra-size-buffers", "Extra Size (buffers)", "Amount of buffers the queues can grow if one of them is empty (0=disable) (NOT IMPLEMENTED)", 0, U, 5, cm.RW));
    c.g_object_class_install_property(oc, PROP_EXTRA_SIZE_TIME, c.g_param_spec_uint64("extra-size-time", "Extra Size (ns)", "Amount of time the queues can grow if one of them is empty (in ns, 0=disable) (NOT IMPLEMENTED)", 0, U64, 3 * SEC, cm.RW));
    c.g_object_class_install_property(oc, PROP_USE_BUFFERING, c.g_param_spec_boolean("use-buffering", "Use buffering", "Emit GST_MESSAGE_BUFFERING based on low-/high-percent thresholds (0% = low-watermark, 100% = high-watermark)", 0, P));
    c.g_object_class_install_property(oc, PROP_LOW_PERCENT, c.g_param_spec_int("low-percent", "Low percent", "Low threshold for buffering to start. Only used if use-buffering is True (Deprecated: use low-watermark instead)", 0, 100, 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_HIGH_PERCENT, c.g_param_spec_int("high-percent", "High percent", "High threshold for buffering to finish. Only used if use-buffering is True (Deprecated: use high-watermark instead)", 0, 100, 99, cm.RW));
    c.g_object_class_install_property(oc, PROP_LOW_WATERMARK, c.g_param_spec_double("low-watermark", "Low watermark", "Low threshold for buffering to start. Only used if use-buffering is True", 0.0, 1.0, 0.01, cm.RW));
    c.g_object_class_install_property(oc, PROP_HIGH_WATERMARK, c.g_param_spec_double("high-watermark", "High watermark", "High threshold for buffering to finish. Only used if use-buffering is True", 0.0, 1.0, 0.99, cm.RW));
    c.g_object_class_install_property(oc, PROP_SYNC_BY_RUNNING_TIME, c.g_param_spec_boolean("sync-by-running-time", "Sync By Running Time", "Synchronize deactivated or not-linked streams by running time", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_USE_INTERLEAVE, c.g_param_spec_boolean("use-interleave", "Use interleave", "Adjust time limits based on input interleave", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_UNLINKED_CACHE_TIME, c.g_param_spec_uint64("unlinked-cache-time", "Unlinked cache time (ns)", "Extra buffering in time for unlinked streams (if 'sync-by-running-time')", 0, U64, 250 * MS, P));
    c.g_object_class_install_property(oc, PROP_MINIMUM_INTERLEAVE, c.g_param_spec_uint64("min-interleave-time", "Minimum interleave time", "Minimum extra buffering for deinterleaving (size of the queues) when use-interleave=true", 0, U64, 250 * MS, P));
    c.g_object_class_install_property(oc, PROP_STATS, c.g_param_spec_boxed("stats", "Stats", "Multiqueue Statistics", c.gst_structure_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "MultiQueue", "Generic", "Multiple data queue", "Edward Hervey <edward@fluendo.com>");
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &sink_t, padType());
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &src_t, padType());
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    ec.change_state = changeState;
    c.gst_type_mark_as_plugin_api(padType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const mq = me(inst);
    mq.nbqueues = 0;
    mq.queues = null;
    mq.max_size = .{ .visible = 5, .bytes = 10 * 1024 * 1024, .time = 2 * SEC };
    mq.extra_size = .{ .visible = 5, .bytes = 10 * 1024 * 1024, .time = 3 * SEC };
    mq.use_buffering = 0;
    mq.low_watermark = @intFromFloat(0.01 * @as(f64, LEVEL_MAX));
    mq.high_watermark = @intFromFloat(0.99 * @as(f64, LEVEL_MAX));
    mq.sync_by_running_time = 0;
    mq.use_interleave = 0;
    mq.min_interleave_time = 250 * MS;
    mq.unlinked_cache_time = 250 * MS;
    mq.counter = 1;
    mq.highid = MAXID;
    mq.high_time = SNONE;
    c.g_mutex_init(&mq.qlock);
    c.g_mutex_init(&mq.reconf_lock);
    c.g_mutex_init(&mq.post_lock);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstMultiQueue", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("multiqueue", 0, "multiqueue element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "multiqueue", c.GST_RANK_NONE, getType()) != 0;
}
