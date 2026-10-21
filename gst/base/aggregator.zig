const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("el.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Agg = c.GstAggregator;
const Class = c.GstAggregatorClass;
const PadClass = c.GstAggregatorPadClass;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const Caps = c.GstCaps;
const Mini = c.GstMiniObject;
const NONE = el.NONE;
const FILE = "gstaggregator.c";
const NEED_DATA: c.GstFlowReturn = c.GST_FLOW_CUSTOM_ERROR;

pub const AggPad = extern struct {
    parent: el.Pad,
    segment: c.GstSegment,
    priv: *PadPriv,
    reserved: [4]c.gpointer,

    pub const Header = c.struct__GstAggregatorPad;
};

const PadPriv = extern struct {
    flow_return: c.GstFlowReturn,
    last_flush_start_seqnum: c.guint32,
    last_flush_stop_seqnum: c.guint32,
    first_buffer: bool,
    waited_once: bool,
    data: c.GQueue,
    clipped_buffer: [*c]Buffer,
    num_buffers: c.guint,
    num_bytes: u64,
    peeked_buffer: [*c]Buffer,
    query_in_proccess: bool,
    head_position: c.GstClockTime,
    tail_position: c.GstClockTime,
    head_time: c.GstClockTime,
    tail_time: c.GstClockTime,
    time_level: c.GstClockTime,
    head_segment: c.GstSegment,
    negotiated: bool,
    eos: bool,
    stream_start_pending: bool,
    lock: c.GMutex,
    event_cond: c.GCond,
    flush_lock: c.GMutex,
    emit_signals: bool,
};

const Private = extern struct {
    max_padserial: c.gint,
    running: bool,
    blocked: bool,
    next_seqnum: c.guint32,
    seqnum: c.guint32,
    send_stream_start: bool,
    send_segment: bool,
    flushing: bool,
    send_eos: bool,
    got_eos_event: bool,
    srccaps: [*c]Caps,
    peer_latency_live: bool,
    peer_latency_min: c.GstClockTime,
    peer_latency_max: c.GstClockTime,
    has_peer_latency: bool,
    sub_latency_min: c.GstClockTime,
    sub_latency_max: c.GstClockTime,
    posted_latency_msg: bool,
    upstream_latency_min: c.GstClockTime,
    aggregate_id: c.GstClockID,
    selected_samples_called_or_warned: bool,
    src_lock: c.GMutex,
    src_cond: c.GCond,
    first_buffer: bool,
    start_time_selection: c.GstAggregatorStartTimeSelection,
    start_time: c.GstClockTime,
    allocation_query: [*c]Query,
    allocator: ?*c.GstAllocator,
    pool: ?*c.GstBufferPool,
    allocation_params: c.GstAllocationParams,
    latency: c.GstClockTime,
    emit_signals: bool,
    ignore_inactive_pads: bool,
    force_live: bool,
};

const PROP_LATENCY = 1;
const PROP_MIN_UPSTREAM_LATENCY = 2;
const PROP_START_TIME_SELECTION = 3;
const PROP_START_TIME = 4;
const PROP_EMIT_SIGNALS = 5;
const PAD_PROP_EMIT_SIGNALS = 1;
const PAD_PROP_LEVEL_TIME = 2;
const PAD_PROP_LEVEL_BUFFERS = 3;
const PAD_PROP_LEVEL_BYTES = 4;

var agg_once: gtype.Once = .{};
var agg_offset: c.gint = 0;
var agg_parent: ?*c.GstElementClass = null;
var samples_selected: c.guint = 0;
var pad_once: gtype.Once = .{};
var pad_offset: c.gint = 0;
var pad_parent: ?*c.GObjectClass = null;
var buffer_consumed: c.guint = 0;
var sts_once: gtype.Once = .{};

fn priv(s: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Agg, @ptrCast(@alignCast(s)))[0].priv));
}

fn of(p: anytype) *Agg {
    return @ptrCast(@alignCast(p));
}

fn apad(p: anytype) *AggPad {
    return @ptrCast(@alignCast(p));
}

fn pp(p: anytype) *PadPriv {
    return apad(p).priv;
}

fn klass(s: anytype) *Class {
    return el.classOf(Class, s);
}

fn padKlass(s: anytype) *PadClass {
    return el.classOf(PadClass, s);
}

fn isAgg(s: anytype) bool {
    return gtype.instanceOf(s, gst_aggregator_get_type());
}

fn srcSeg(x: *Agg) *c.GstSegment {
    return &apad(x.srcpad).segment;
}

fn padLock(p: anytype) void {
    c.g_mutex_lock(&pp(p).lock);
}

fn padUnlock(p: anytype) void {
    c.g_mutex_unlock(&pp(p).lock);
}

fn padWait(p: anytype) void {
    c.g_cond_wait(&pp(p).event_cond, &pp(p).lock);
}

fn padBroadcast(p: anytype) void {
    c.g_cond_broadcast(&pp(p).event_cond);
}

fn srcLock(x: *Agg) void {
    c.g_mutex_lock(&priv(x).src_lock);
}

fn srcUnlock(x: *Agg) void {
    c.g_mutex_unlock(&priv(x).src_lock);
}

fn srcWait(x: *Agg) void {
    c.g_cond_wait(&priv(x).src_cond, &priv(x).src_lock);
}

fn srcBroadcast(x: *Agg) void {
    if (priv(x).aggregate_id != null) c.gst_clock_id_unschedule(priv(x).aggregate_id);
    c.g_cond_broadcast(&priv(x).src_cond);
}

fn miniType(o: c.gpointer) c.GType {
    if (o == null) return 0;
    return @as(*Mini, @ptrCast(@alignCast(o))).type;
}

fn isEvent(o: c.gpointer) bool {
    return o != null and miniType(o) == c._gst_event_type;
}

fn isQuery(o: c.gpointer) bool {
    return o != null and miniType(o) == c._gst_query_type;
}

fn isBuffer(o: c.gpointer) bool {
    return o != null and miniType(o) == c._gst_buffer_type;
}

fn tail(p: anytype) c.gpointer {
    return c.g_queue_peek_tail(&pp(p).data);
}

fn live(x: *Agg) bool {
    return priv(x).peer_latency_live or priv(x).force_live;
}

pub export fn gst_aggregator_start_time_selection_get_type() c.GType {
    return sts_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_AGGREGATOR_START_TIME_SELECTION_ZERO, .value_name = "GST_AGGREGATOR_START_TIME_SELECTION_ZERO", .value_nick = "zero" },
            .{ .value = c.GST_AGGREGATOR_START_TIME_SELECTION_FIRST, .value_name = "GST_AGGREGATOR_START_TIME_SELECTION_FIRST", .value_nick = "first" },
            .{ .value = c.GST_AGGREGATOR_START_TIME_SELECTION_SET, .value_name = "GST_AGGREGATOR_START_TIME_SELECTION_SET", .value_nick = "set" },
            .{ .value = c.GST_AGGREGATOR_START_TIME_SELECTION_NOW, .value_name = "GST_AGGREGATOR_START_TIME_SELECTION_NOW", .value_nick = "now" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstAggregatorStartTimeSelection", &values);
        }
    }.f);
}

fn padReset(p: *AggPad) void {
    const r = p.priv;
    r.eos = false;
    r.flow_return = c.GST_FLOW_OK;
    el.lock(p);
    c.gst_segment_init(&p.segment, c.GST_FORMAT_UNDEFINED);
    c.gst_segment_init(&r.head_segment, c.GST_FORMAT_UNDEFINED);
    el.unlock(p);
    r.head_position = NONE;
    r.tail_position = NONE;
    r.head_time = NONE;
    r.tail_time = NONE;
    r.time_level = 0;
    r.first_buffer = true;
    r.waited_once = false;
    r.stream_start_pending = false;
}

fn padFlush(p: *AggPad, x: *Agg) bool {
    padLock(p);
    padReset(p);
    padUnlock(p);
    if (padKlass(p).flush) |f| return f(@ptrCast(p), x) == c.GST_FLOW_OK;
    return true;
}

pub export fn gst_aggregator_peek_next_sample(s: [*c]Agg, p: ?*AggPad) ?*c.GstSample {
    if (klass(s).peek_next_sample) |f| return f(s, @ptrCast(p));
    return null;
}

fn queueEmpty(p: *AggPad) bool {
    return tail(p) == null and p.priv.clipped_buffer == null;
}

fn checkPadsReady(x: *Agg, have_eq: ?*bool) bool {
    const r = priv(x);
    var have_buffer = true;
    var have_event_or_query = false;
    var n_ready: c.guint = 0;
    el.lock(x);
    var ok = true;
    done: {
        const sinkpads = x.parent.sinkpads;
        if (sinkpads == null) {
            ok = false;
            break :done;
        }
        var l: ?*c.GList = sinkpads;
        while (l) |n| : (l = n.next) {
            const p = apad(n.data);
            padLock(p);
            defer padUnlock(p);
            if (p.priv.clipped_buffer == null and (isEvent(tail(p)) or isQuery(tail(p)))) {
                have_event_or_query = true;
                break;
            }
            if (r.ignore_inactive_pads and live(x) and p.priv.waited_once and p.priv.first_buffer and !p.priv.eos) continue;
            if (p.priv.clipped_buffer == null and !isBuffer(tail(p))) {
                if (!p.priv.eos) have_buffer = false else n_ready += 1;
            } else if (live(x)) {
                r.first_buffer = false;
                n_ready += 1;
            }
        }
        if (r.ignore_inactive_pads and live(x) and n_ready == 0) {
            ok = false;
            break :done;
        }
        if (have_event_or_query or !have_buffer) {
            ok = false;
            break :done;
        }
        r.first_buffer = false;
    }
    el.unlock(x);
    if (have_eq) |h| h.* = have_event_or_query;
    return ok;
}

fn resetFlowValues(x: *Agg) void {
    el.lock(x);
    priv(x).send_stream_start = true;
    priv(x).send_segment = true;
    c.gst_segment_init(srcSeg(x), c.GST_FORMAT_TIME);
    srcSeg(x).position = NONE;
    priv(x).first_buffer = true;
    el.unlock(x);
}

fn pushMandatoryEvents(x: *Agg, up_to_caps: bool) void {
    const r = priv(x);
    if (r.send_stream_start) {
        var id: [32]u8 = undefined;
        _ = c.g_snprintf(&id, id.len, "agg-%08x", c.g_random_int());
        _ = c.gst_pad_push_event(x.srcpad, c.gst_event_new_stream_start(&id));
        r.send_stream_start = false;
    }
    if (r.srccaps != null) {
        _ = c.gst_pad_push_event(x.srcpad, c.gst_event_new_caps(r.srccaps));
        c.gst_caps_unref(r.srccaps);
        r.srccaps = null;
    }
    if (up_to_caps) return;
    var segment: [*c]Event = null;
    el.lock(x);
    if (r.send_segment and !r.flushing) {
        segment = c.gst_event_new_segment(srcSeg(x));
        if (r.seqnum == 0) r.seqnum = c.gst_event_get_seqnum(segment) else c.gst_event_set_seqnum(segment, r.seqnum);
        r.send_segment = false;
    }
    el.unlock(x);
    if (segment != null) _ = c.gst_pad_push_event(x.srcpad, segment);
}

pub export fn gst_aggregator_set_src_caps(s: [*c]Agg, caps: [*c]Caps) void {
    const x = of(s);
    el.streamLock(x.srcpad);
    defer el.streamUnlock(x.srcpad);
    if (caps != null) {
        const old = c.gst_pad_get_current_caps(x.srcpad);
        if (old != null) {
            const same = c.gst_caps_is_equal(caps, old) != 0;
            c.gst_caps_unref(old);
            if (same) return;
        }
    }
    _ = c.gst_caps_replace(&priv(x).srccaps, caps);
    pushMandatoryEvents(x, true);
}

fn defaultFinishBuffer(s: [*c]Agg, b: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const x = of(s);
    pushMandatoryEvents(x, false);
    el.lock(x);
    if (!priv(x).flushing and c.gst_pad_is_active(x.srcpad) != 0) {
        el.unlock(x);
        return c.gst_pad_push(x.srcpad, b);
    }
    el.unlock(x);
    c.gst_buffer_unref(b);
    return c.GST_FLOW_OK;
}

pub export fn gst_aggregator_finish_buffer(s: [*c]Agg, b: [*c]Buffer) c.GstFlowReturn {
    return klass(s).finish_buffer.?(s, b);
}

fn defaultFinishList(s: [*c]Agg, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    const x = of(s);
    pushMandatoryEvents(x, false);
    el.lock(x);
    if (!priv(x).flushing and c.gst_pad_is_active(x.srcpad) != 0) {
        el.unlock(x);
        return c.gst_pad_push_list(x.srcpad, l);
    }
    el.unlock(x);
    c.gst_mini_object_unref(@ptrCast(@alignCast(l)));
    return c.GST_FLOW_OK;
}

pub export fn gst_aggregator_finish_buffer_list(s: [*c]Agg, l: ?*c.GstBufferList) c.GstFlowReturn {
    return klass(s).finish_buffer_list.?(s, l);
}

pub export fn gst_aggregator_push_src_event(s: [*c]Agg, ev: [*c]Event) c.gboolean {
    const t = ev[0].type;
    if (!check.that(t & c.GST_EVENT_TYPE_DOWNSTREAM != 0, "gst_aggregator_push_src_event", "GST_EVENT_IS_DOWNSTREAM (event)")) return 0;
    if (!check.that(t != c.GST_EVENT_STREAM_START and t != c.GST_EVENT_CAPS and t != c.GST_EVENT_SEGMENT and t != c.GST_EVENT_EOS, "gst_aggregator_push_src_event", "GST_EVENT_TYPE (event) != GST_EVENT_STREAM_START && GST_EVENT_TYPE (event) != GST_EVENT_CAPS && GST_EVENT_TYPE (event) != GST_EVENT_SEGMENT && GST_EVENT_TYPE (event) != GST_EVENT_EOS")) return 0;
    if (t & c.GST_EVENT_TYPE_SERIALIZED != 0) pushMandatoryEvents(of(s), false);
    return c.gst_pad_push_event(s[0].srcpad, ev);
}

fn pushEos(x: *Agg) void {
    pushMandatoryEvents(x, false);
    const ev = c.gst_event_new_eos();
    el.lock(x);
    priv(x).send_eos = false;
    if (priv(x).seqnum != 0) c.gst_event_set_seqnum(ev, priv(x).seqnum);
    el.unlock(x);
    _ = c.gst_pad_push_event(x.srcpad, ev);
}

fn nextTime(x: *Agg) c.GstClockTime {
    if (klass(x).get_next_time) |f| return f(x);
    return NONE;
}

fn waitAndCheck(x: *Agg, timeout: *bool) bool {
    const r = priv(x);
    timeout.* = false;
    srcLock(x);
    const latency = latencyUnlocked(x);
    var have_eq = false;
    if (checkPadsReady(x, &have_eq)) {
        srcUnlock(x);
        return true;
    }
    if (have_eq or !r.running or !r.send_eos) {
        srcUnlock(x);
        return false;
    }
    if (!r.blocked and ((r.force_live and r.first_buffer and r.start_time_selection == c.GST_AGGREGATOR_START_TIME_SELECTION_FIRST) or (r.start_time_selection == c.GST_AGGREGATOR_START_TIME_SELECTION_NOW and r.first_buffer))) {
        const st = c.gst_element_get_current_running_time(@ptrCast(x));
        if (st != NONE) {
            const seg = srcSeg(x);
            seg.position = if (seg.position == NONE) st else @min(st, seg.position);
            r.first_buffer = false;
        }
    }
    const start = nextTime(x);
    el.lock(x);
    const clock = x.parent.clock;
    if (latency == NONE or r.blocked or !gtype.instanceOf(clock, c.gst_clock_get_type()) or start == NONE or (r.first_buffer and r.start_time_selection == c.GST_AGGREGATOR_START_TIME_SELECTION_FIRST)) {
        el.unlock(x);
        srcWait(x);
        if (!r.running or !r.send_eos) {
            srcUnlock(x);
            return false;
        }
    } else {
        const base_time: u64 = @bitCast(x.parent.base_time);
        _ = c.gst_object_ref(clock);
        el.unlock(x);
        const time = base_time +% start +% latency;
        r.aggregate_id = c.gst_clock_new_single_shot_id(clock, time);
        c.gst_object_unref(clock);
        srcUnlock(x);
        var jitter: c.GstClockTimeDiff = 0;
        const status = c.gst_clock_id_wait(r.aggregate_id, &jitter);
        srcLock(x);
        if (r.aggregate_id != null) {
            c.gst_clock_id_unref(r.aggregate_id);
            r.aggregate_id = null;
        }
        if (!r.running or !r.send_eos or r.blocked) {
            srcUnlock(x);
            return false;
        }
        if (status == c.GST_CLOCK_OK or status == c.GST_CLOCK_EARLY) {
            el.lock(x);
            var l: ?*c.GList = x.parent.sinkpads;
            while (l) |n| : (l = n.next) {
                padLock(n.data);
                pp(n.data).waited_once = true;
                padUnlock(n.data);
            }
            el.unlock(x);
            srcUnlock(x);
            timeout.* = true;
            return true;
        }
    }
    const res = checkPadsReady(x, null);
    srcUnlock(x);
    return res;
}

const EqData = struct {
    processed: bool = false,
    flow: c.GstFlowReturn = c.GST_FLOW_OK,
};

fn doEventsAndQueries(e: [*c]c.GstElement, epad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const p = apad(epad);
    const x = of(e);
    const d: *EqData = @ptrCast(@alignCast(data));
    while (true) {
        var ev: [*c]Event = null;
        var q: [*c]Query = null;
        padLock(p);
        if (p.priv.clipped_buffer == null and !isBuffer(tail(p))) {
            if (isEvent(tail(p))) ev = c.gst_event_ref(@ptrCast(@alignCast(tail(p))));
            if (isQuery(tail(p))) {
                q = @ptrCast(@alignCast(tail(p)));
                p.priv.query_in_proccess = true;
            }
        }
        padUnlock(p);
        if (ev == null and q == null) return 1;
        d.processed = true;
        const k = klass(x);
        if (ev != null) {
            _ = c.gst_event_ref(ev);
            const ret = k.sink_event.?(x, @ptrCast(p), ev);
            padLock(p);
            if (ev[0].type == c.GST_EVENT_CAPS) p.priv.negotiated = ret != 0;
            if (tail(p) == @as(c.gpointer, @ptrCast(ev))) c.gst_event_unref(@ptrCast(@alignCast(c.g_queue_pop_tail(&p.priv.data))));
            c.gst_event_unref(ev);
        } else {
            const ret = k.sink_query.?(x, @ptrCast(p), q);
            padLock(p);
            if (tail(p) == @as(c.gpointer, @ptrCast(q))) {
                const s = c.gst_query_writable_structure(q);
                c.gst_structure_set(s, "gst-aggregator-retval", c.G_TYPE_BOOLEAN, ret, @as(?*anyopaque, null));
                _ = c.g_queue_pop_tail(&p.priv.data);
            }
            p.priv.query_in_proccess = false;
        }
        padBroadcast(p);
        padUnlock(p);
    }
}

fn bufferConsumed(p: *AggPad, b: [*c]Buffer, dequeued: bool) void {
    if (dequeued) {
        p.priv.num_buffers -%= 1;
        p.priv.num_bytes -%= c.gst_buffer_get_size(b);
    }
    if (b != null and p.priv.emit_signals) c.g_signal_emit(p, buffer_consumed, 0, b);
    padBroadcast(p);
}

fn skipBuffers(e: [*c]c.GstElement, epad: ?*c.GstPad, _: c.gpointer) callconv(.c) c.gboolean {
    const p = apad(epad);
    const skip = padKlass(p).skip_buffer orelse return 0;
    padLock(p);
    defer padUnlock(p);
    var item = c.g_queue_peek_tail_link(&p.priv.data);
    while (item != null) {
        const prev = item[0].prev;
        if (!isBuffer(item[0].data) or skip(@ptrCast(p), @ptrCast(e), @ptrCast(@alignCast(item[0].data))) == 0) break;
        bufferConsumed(p, @ptrCast(@alignCast(item[0].data)), true);
        c.gst_buffer_unref(@ptrCast(@alignCast(item[0].data)));
        c.g_queue_delete_link(&p.priv.data, item);
        item = prev;
    }
    return 1;
}

fn resetPeeked(_: [*c]c.GstElement, epad: ?*c.GstPad, _: c.gpointer) callconv(.c) c.gboolean {
    padLock(epad);
    _ = c.gst_mini_object_replace(@ptrCast(&pp(epad).peeked_buffer), null);
    padUnlock(epad);
    return 1;
}

fn padSetFlushing(p: *AggPad, flow: c.GstFlowReturn, full: bool) void {
    padLock(p);
    defer padUnlock(p);
    if (flow == c.GST_FLOW_NOT_LINKED) p.priv.flow_return = @min(flow, p.priv.flow_return) else p.priv.flow_return = flow;
    var item = c.g_queue_peek_head_link(&p.priv.data);
    while (item != null) {
        const next = item[0].next;
        const d = item[0].data;
        const remove = full or isBuffer(d) or blk: {
            const et = @as(*Event, @ptrCast(@alignCast(d))).type;
            break :blk et == c.GST_EVENT_EOS or et == c.GST_EVENT_SEGMENT or et & c.GST_EVENT_TYPE_STICKY == 0;
        };
        if (remove) {
            if (!isQuery(d)) c.gst_mini_object_unref(@ptrCast(@alignCast(d)));
            c.g_queue_delete_link(&p.priv.data, item);
        }
        item = next;
    }
    p.priv.num_buffers = 0;
    p.priv.num_bytes = 0;
    p.priv.stream_start_pending = false;
    _ = c.gst_mini_object_replace(@ptrCast(&p.priv.clipped_buffer), null);
    padBroadcast(p);
}

fn defaultUpdateSrcCaps(_: [*c]Agg, caps: [*c]Caps, ret: [*c][*c]Caps) callconv(.c) c.GstFlowReturn {
    ret.* = c.gst_caps_ref(caps);
    return c.GST_FLOW_OK;
}

fn defaultFixateSrcCaps(_: [*c]Agg, caps: [*c]Caps) callconv(.c) [*c]Caps {
    return c.gst_caps_fixate(caps);
}

fn defaultNegotiatedSrcCaps(_: [*c]Agg, _: [*c]Caps) callconv(.c) c.gboolean {
    return 1;
}

fn setAllocation(x: *Agg, pool: ?*c.GstBufferPool, allocator: ?*c.GstAllocator, params: ?*const c.GstAllocationParams, q: [*c]Query) void {
    const r = priv(x);
    el.lock(x);
    const oldpool = r.pool;
    r.pool = pool;
    const oldalloc = r.allocator;
    r.allocator = allocator;
    const oldquery = r.allocation_query;
    r.allocation_query = q;
    if (params) |pa| r.allocation_params = pa.* else c.gst_allocation_params_init(&r.allocation_params);
    el.unlock(x);
    if (oldpool != null) {
        _ = c.gst_buffer_pool_set_active(oldpool, 0);
        c.gst_object_unref(oldpool);
    }
    if (oldalloc != null) c.gst_object_unref(oldalloc);
    if (oldquery != null) c.gst_query_unref(oldquery);
}

fn doAllocation(x: *Agg, caps: [*c]Caps) bool {
    const q = c.gst_query_new_allocation(caps, 1);
    _ = c.gst_pad_peer_query(x.srcpad, q);
    if (klass(x).decide_allocation) |f| {
        if (f(x, q) == 0) {
            c.gst_query_unref(q);
            return false;
        }
    }
    var allocator: ?*c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_query_get_n_allocation_params(q) > 0) {
        c.gst_query_parse_nth_allocation_param(q, 0, &allocator, &params);
    } else c.gst_allocation_params_init(&params);
    var pool: ?*c.GstBufferPool = null;
    if (c.gst_query_get_n_allocation_pools(q) > 0) c.gst_query_parse_nth_allocation_pool(q, 0, &pool, null, null, null);
    setAllocation(x, pool, allocator, &params, q);
    return true;
}

fn defaultNegotiate(s: [*c]Agg) callconv(.c) c.gboolean {
    const x = of(s);
    const k = klass(x);
    const templ = c.gst_pad_get_pad_template_caps(x.srcpad);
    const downstream = c.gst_pad_peer_query_caps(x.srcpad, templ);
    var caps: [*c]Caps = null;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    defer {
        c.gst_caps_unref(downstream);
        c.gst_caps_unref(templ);
        if (caps != null) c.gst_caps_unref(caps);
    }
    done: {
        if (c.gst_caps_is_empty(downstream) != 0) {
            ret = c.GST_FLOW_NOT_NEGOTIATED;
            break :done;
        }
        ret = k.update_src_caps.?(x, downstream, &caps);
        if (ret == NEED_DATA or ret < c.GST_FLOW_OK) break :done;
        if (caps == null or c.gst_caps_is_empty(caps) != 0) {
            ret = c.GST_FLOW_NOT_NEGOTIATED;
            break :done;
        }
        if (c.gst_caps_is_any(caps) != 0) break :done;
        if (c.gst_caps_is_fixed(caps) == 0) {
            caps = k.fixate_src_caps.?(x, caps);
            if (caps == null) {
                ret = c.GST_FLOW_NOT_NEGOTIATED;
                break :done;
            }
        }
        if (k.negotiated_src_caps) |f| {
            if (f(x, caps) == 0) {
                ret = c.GST_FLOW_NOT_NEGOTIATED;
                break :done;
            }
        }
        gst_aggregator_set_src_caps(x, caps);
        if (!doAllocation(x, caps)) ret = c.GST_FLOW_NOT_NEGOTIATED;
    }
    return @intFromBool(ret >= c.GST_FLOW_OK or ret == NEED_DATA);
}

fn negotiateUnlocked(x: *Agg) bool {
    if (klass(x).negotiate) |f| return f(x) != 0;
    return true;
}

pub export fn gst_aggregator_negotiate(s: [*c]Agg) c.gboolean {
    if (!check.that(isAgg(s), "gst_aggregator_negotiate", "GST_IS_AGGREGATOR (self)")) return 0;
    const x = of(s);
    el.streamLock(x.srcpad);
    defer el.streamUnlock(x.srcpad);
    _ = c.gst_pad_check_reconfigure(x.srcpad);
    const ok = negotiateUnlocked(x);
    if (!ok) c.gst_pad_mark_reconfigure(x.srcpad);
    return @intFromBool(ok);
}

fn checkPendingNewStream(_: [*c]c.GstElement, p: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    padLock(p);
    const pending = pp(p).stream_start_pending;
    padUnlock(p);
    if (pending) {
        @as(*c.gboolean, @ptrCast(@alignCast(data))).* = 1;
        return 0;
    }
    return 1;
}

fn aggLoop(x: *Agg) c.GstFlowReturn {
    const r = priv(x);
    const k = klass(x);
    var flow: c.GstFlowReturn = c.GST_FLOW_OK;
    var timeout = false;
    if (!r.running) return c.GST_FLOW_OK;
    while (r.send_eos and r.running) {
        flow = c.GST_FLOW_OK;
        var eq = EqData{};
        _ = c.gst_element_foreach_sink_pad(@ptrCast(x), doEventsAndQueries, &eq);
        flow = eq.flow;
        handled: {
            if (flow != c.GST_FLOW_OK) break :handled;
            if (live(x)) _ = c.gst_element_foreach_sink_pad(@ptrCast(x), skipBuffers, null);
            srcLock(x);
            if (r.got_eos_event) {
                r.got_eos_event = false;
                srcUnlock(x);
                pushEos(x);
                continue;
            }
            srcUnlock(x);
            if (!waitAndCheck(x, &timeout)) {
                _ = c.gst_element_foreach_sink_pad(@ptrCast(x), resetPeeked, null);
                continue;
            }
            if (c.gst_pad_check_reconfigure(x.srcpad) != 0) {
                if (!negotiateUnlocked(x)) {
                    c.gst_pad_mark_reconfigure(x.srcpad);
                    flow = if (el.flags(x.srcpad) & c.GST_PAD_FLAG_FLUSHING != 0) c.GST_FLOW_FLUSHING else c.GST_FLOW_NOT_NEGOTIATED;
                }
            }
            if (timeout or flow >= c.GST_FLOW_OK) flow = k.aggregate.?(x, @intFromBool(timeout));
            _ = c.gst_element_foreach_sink_pad(@ptrCast(x), resetPeeked, null);
            if (!r.selected_samples_called_or_warned) r.selected_samples_called_or_warned = true;
            if (flow == NEED_DATA) continue;
            el.lock(x);
            if (flow == c.GST_FLOW_FLUSHING and r.flushing) {
                el.unlock(x);
                return c.GST_FLOW_FLUSHING;
            }
            el.unlock(x);
            if (flow == c.GST_FLOW_EOS or flow == c.GST_FLOW_ERROR) pushEos(x);
        }
        if (flow == c.GST_FLOW_EOS) return c.GST_FLOW_EOS;
        if (flow != c.GST_FLOW_OK) {
            el.lock(x);
            var l: ?*c.GList = x.parent.sinkpads;
            while (l) |n| : (l = n.next) padSetFlushing(apad(n.data), flow, true);
            el.unlock(x);
            break;
        }
    }
    return flow;
}

fn aggregateFunc(data: c.gpointer) callconv(.c) void {
    const x = of(data);
    const r = priv(x);
    while (true) {
        const ret = aggLoop(x);
        srcLock(x);
        if (ret != c.GST_FLOW_EOS) break;
        var pending: c.gboolean = 0;
        _ = c.gst_element_foreach_sink_pad(@ptrCast(x), checkPendingNewStream, &pending);
        if (pending == 0) break;
        resetFlowValues(x);
        r.send_eos = true;
        srcUnlock(x);
    }
    _ = c.gst_pad_pause_task(x.srcpad);
    srcUnlock(x);
}

fn startAgg(x: *Agg) bool {
    const r = priv(x);
    r.send_stream_start = true;
    r.send_segment = true;
    r.send_eos = true;
    r.got_eos_event = false;
    r.srccaps = null;
    r.has_peer_latency = false;
    r.peer_latency_live = false;
    r.peer_latency_min = 0;
    r.peer_latency_max = 0;
    r.blocked = true;
    setAllocation(x, null, null, null, null);
    if (klass(x).start) |f| return f(x) != 0;
    return true;
}

fn stopTask(x: *Agg, flush_start: [*c]Event) bool {
    srcLock(x);
    priv(x).running = false;
    srcBroadcast(x);
    srcUnlock(x);
    var ok = true;
    if (flush_start != null) ok = c.gst_pad_push_event(x.srcpad, flush_start) != 0;
    _ = c.gst_pad_stop_task(x.srcpad);
    return ok;
}

fn startTask(x: *Agg) void {
    priv(x).running = true;
    _ = c.gst_pad_start_task(x.srcpad, aggregateFunc, x, null);
}

fn flushAgg(x: *Agg) c.GstFlowReturn {
    el.lock(x);
    priv(x).send_segment = true;
    priv(x).flushing = false;
    el.unlock(x);
    if (klass(x).flush) |f| return f(x);
    return c.GST_FLOW_OK;
}

fn allFlushStop(x: *Agg, seqnum: c.guint32) bool {
    var l: ?*c.GList = x.parent.sinkpads;
    while (l) |n| : (l = n.next) if (pp(n.data).last_flush_stop_seqnum != seqnum) return false;
    return true;
}

fn allFlushStart(x: *Agg, seqnum: c.guint32) bool {
    var l: ?*c.GList = x.parent.sinkpads;
    while (l) |n| : (l = n.next) if (pp(n.data).last_flush_start_seqnum != seqnum) return false;
    return true;
}

fn flushStart(x: *Agg, p: *AggPad, ev: [*c]Event) void {
    const r = priv(x);
    const seqnum = c.gst_event_get_seqnum(ev);
    padSetFlushing(p, c.GST_FLOW_FLUSHING, false);
    c.g_mutex_lock(&p.priv.flush_lock);
    padLock(p);
    p.priv.last_flush_start_seqnum = seqnum;
    padUnlock(p);
    el.lock(x);
    if (!r.flushing and allFlushStart(x, seqnum)) {
        r.flushing = true;
        r.next_seqnum = seqnum;
        el.unlock(x);
        _ = stopTask(x, ev);
    } else {
        c.gst_event_unref(ev);
        el.unlock(x);
    }
    c.g_mutex_unlock(&p.priv.flush_lock);
}

fn updateTimeLevel(p: *AggPad, head: bool) void {
    const r = p.priv;
    if (head) {
        r.head_time = if (r.head_position != NONE and r.head_segment.format == c.GST_FORMAT_TIME) c.gst_segment_to_running_time(&r.head_segment, c.GST_FORMAT_TIME, r.head_position) else NONE;
        if (r.tail_time == NONE) r.tail_time = r.head_time;
    } else {
        r.tail_time = if (r.tail_position != NONE and p.segment.format == c.GST_FORMAT_TIME) c.gst_segment_to_running_time(&p.segment, c.GST_FORMAT_TIME, r.tail_position) else r.head_time;
    }
    if (r.head_time == NONE or r.tail_time == NONE) {
        r.time_level = 0;
        return;
    }
    r.time_level = if (r.tail_time > r.head_time) 0 else r.head_time - r.tail_time;
}

fn defaultSinkEvent(s: [*c]Agg, sp: ?*c.GstAggregatorPad, ev_in: [*c]Event) callconv(.c) c.gboolean {
    const x = of(s);
    const p = apad(sp);
    const r = priv(x);
    var ev = ev_in;
    var res: c.gboolean = 1;
    switch (ev[0].type) {
        c.GST_EVENT_FLUSH_START => {
            flushStart(x, p, ev);
            ev = null;
        },
        c.GST_EVENT_FLUSH_STOP => {
            const seqnum = c.gst_event_get_seqnum(ev);
            c.g_mutex_lock(&p.priv.flush_lock);
            padLock(p);
            p.priv.last_flush_stop_seqnum = seqnum;
            padUnlock(p);
            _ = padFlush(p, x);
            el.lock(x);
            if (r.flushing and allFlushStop(x, seqnum)) {
                el.unlock(x);
                _ = flushAgg(x);
                _ = c.gst_pad_push_event(x.srcpad, ev);
                ev = null;
                srcLock(x);
                r.send_eos = true;
                r.got_eos_event = false;
                srcBroadcast(x);
                srcUnlock(x);
                startTask(x);
            } else el.unlock(x);
            c.g_mutex_unlock(&p.priv.flush_lock);
        },
        c.GST_EVENT_EOS => {
            srcLock(x);
            padLock(p);
            p.priv.eos = true;
            padUnlock(p);
            srcBroadcast(x);
            srcUnlock(x);
        },
        c.GST_EVENT_SEGMENT => {
            padLock(p);
            el.lock(p);
            c.gst_event_copy_segment(ev, &p.segment);
            p.priv.tail_position = NONE;
            updateTimeLevel(p, false);
            el.unlock(p);
            padUnlock(p);
            el.lock(x);
            r.seqnum = c.gst_event_get_seqnum(ev);
            el.unlock(x);
        },
        c.GST_EVENT_STREAM_START => {
            srcLock(x);
            padLock(p);
            p.priv.eos = false;
            p.priv.stream_start_pending = false;
            padUnlock(p);
            srcBroadcast(x);
            srcUnlock(x);
        },
        c.GST_EVENT_GAP => {
            var pts: u64 = 0;
            var duration: u64 = 0;
            c.gst_event_parse_gap(ev, &pts, &duration);
            var endpts: u64 = if (duration != NONE) pts +% duration else NONE;
            el.lock(p);
            if (p.segment.format != c.GST_FORMAT_TIME) {
                el.unlock(p);
                res = 0;
            } else {
                const clipped = c.gst_segment_clip(&p.segment, c.GST_FORMAT_TIME, pts, endpts, &pts, &endpts);
                el.unlock(p);
                if (clipped != 0) {
                    duration = if (endpts != NONE and pts != NONE) endpts - pts else NONE;
                    const gap = c.gst_buffer_new();
                    gap[0].pts = pts;
                    gap[0].duration = duration;
                    gap[0].mini_object.flags |= c.GST_BUFFER_FLAG_GAP | c.GST_BUFFER_FLAG_DROPPABLE;
                    var flags: c.GstGapFlags = 0;
                    c.gst_event_parse_gap_flags(ev, &flags);
                    if (flags & c.GST_GAP_FLAG_MISSING_DATA != 0) _ = c.gst_buffer_add_custom_meta(gap, "GstAggregatorMissingDataMeta");
                    padLock(p);
                    if (tail(p) == @as(c.gpointer, @ptrCast(ev))) c.gst_event_unref(@ptrCast(@alignCast(c.g_queue_pop_tail(&p.priv.data))));
                    padUnlock(p);
                    if (chainInternal(x, p, gap, false) != c.GST_FLOW_OK) res = 0;
                }
            }
        },
        c.GST_EVENT_TAG => {},
        else => return c.gst_pad_event_default(@ptrCast(p), @ptrCast(x), ev),
    }
    if (ev != null) c.gst_event_unref(ev);
    return res;
}

fn defaultSinkEventPreQueue(s: [*c]Agg, sp: ?*c.GstAggregatorPad, ev: [*c]Event) callconv(.c) c.GstFlowReturn {
    const x = of(s);
    const p = apad(sp);
    const r = priv(x);
    const t = ev[0].type;
    if (t & c.GST_EVENT_TYPE_SERIALIZED == 0 or t == c.GST_EVENT_FLUSH_STOP) {
        if (klass(x).sink_event.?(x, sp, ev) == 0) return c.GST_FLOW_ERROR;
        return c.GST_FLOW_OK;
    }
    srcLock(x);
    padLock(p);
    if (t == c.GST_EVENT_STREAM_START and r.running) {
        p.priv.flow_return = c.GST_FLOW_OK;
        p.priv.stream_start_pending = true;
        if (c.gst_pad_get_task_state(x.srcpad) == c.GST_TASK_PAUSED) {
            r.send_eos = true;
            resetFlowValues(x);
            startTask(x);
        }
    }
    if (p.priv.flow_return != c.GST_FLOW_OK) {
        padUnlock(p);
        srcUnlock(x);
        if (t & c.GST_EVENT_TYPE_STICKY != 0) _ = c.gst_pad_store_sticky_event(@ptrCast(p), ev);
        c.gst_event_unref(ev);
        return p.priv.flow_return;
    }
    if (t == c.GST_EVENT_SEGMENT) {
        el.lock(p);
        c.gst_event_copy_segment(ev, &p.priv.head_segment);
        p.priv.head_position = p.priv.head_segment.position;
        updateTimeLevel(p, true);
        el.unlock(p);
    }
    c.g_queue_push_head(&p.priv.data, ev);
    srcBroadcast(x);
    padUnlock(p);
    srcUnlock(x);
    return c.GST_FLOW_OK;
}

fn stopPad(e: [*c]c.GstElement, epad: ?*c.GstPad, _: c.gpointer) callconv(.c) c.gboolean {
    const p = apad(epad);
    _ = padFlush(p, of(e));
    padLock(p);
    p.priv.flow_return = c.GST_FLOW_FLUSHING;
    p.priv.negotiated = false;
    padBroadcast(p);
    padUnlock(p);
    return 1;
}

fn stopAgg(x: *Agg) bool {
    const r = priv(x);
    resetFlowValues(x);
    _ = c.gst_element_foreach_sink_pad(@ptrCast(x), stopPad, null);
    var ok = true;
    if (klass(x).stop) |f| ok = f(x) != 0;
    r.has_peer_latency = false;
    r.peer_latency_live = false;
    r.peer_latency_min = 0;
    r.peer_latency_max = 0;
    r.posted_latency_msg = false;
    r.blocked = false;
    setAllocation(x, null, null, null, null);
    if (r.running) _ = stopTask(x, null);
    return ok;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const x = of(e);
    const r = priv(x);
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => if (!startAgg(x)) return c.GST_STATE_CHANGE_FAILURE,
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => {
            srcLock(x);
            r.blocked = false;
            srcBroadcast(x);
            srcUnlock(x);
        },
        else => {},
    }
    var ret = agg_parent.?.change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => _ = stopAgg(x),
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => {
            srcLock(x);
            r.blocked = true;
            srcBroadcast(x);
            srcUnlock(x);
            if (r.force_live) ret = c.GST_STATE_CHANGE_NO_PREROLL;
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => if (r.force_live) {
            ret = c.GST_STATE_CHANGE_NO_PREROLL;
        },
        else => {},
    }
    return ret;
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const x = of(e);
    const p = apad(pad);
    srcLock(x);
    padSetFlushing(p, c.GST_FLOW_FLUSHING, true);
    padLock(p);
    _ = c.gst_mini_object_replace(@ptrCast(&p.priv.peeked_buffer), null);
    _ = c.gst_mini_object_replace(@ptrCast(&p.priv.clipped_buffer), null);
    padUnlock(p);
    _ = c.gst_element_remove_pad(e, pad);
    priv(x).has_peer_latency = false;
    srcBroadcast(x);
    srcUnlock(x);
}

fn defaultCreateNewPad(s: [*c]Agg, templ: [*c]c.GstPadTemplate, req_name: [*c]const u8, _: [*c]const Caps) callconv(.c) ?*c.GstAggregatorPad {
    const x = of(s);
    const r = priv(x);
    const pad_type = if (templ[0].ABI.abi.gtype == (1 << c.G_TYPE_FUNDAMENTAL_SHIFT)) gst_aggregator_pad_get_type() else templ[0].ABI.abi.gtype;
    if (templ[0].direction != c.GST_PAD_SINK or templ[0].presence != c.GST_PAD_REQUEST) return null;
    const percent = c.strrchr(templ[0].name_template, '%');
    var name: [*c]u8 = null;
    if (percent == null) {
        name = c.g_strdup(if (req_name != null) req_name else templ[0].name_template);
    } else if (c.g_strcmp0(percent, "%u") == 0 or c.g_strcmp0(percent, "%d") == 0) {
        const idx: usize = @intFromPtr(percent) - @intFromPtr(templ[0].name_template);
        const prefix = c.g_strndup(templ[0].name_template, idx);
        defer c.g_free(prefix);
        var serial: c.gint = 0;
        el.lock(x);
        if (req_name == null or c.g_strcmp0(templ[0].name_template, req_name) == 0) {
            r.max_padserial += 1;
            serial = r.max_padserial;
        } else if (c.g_str_has_prefix(req_name, prefix) != 0) {
            var end: [*c]u8 = null;
            serial = @truncate(@as(i64, @bitCast(c.g_ascii_strtoull(req_name + idx, &end, 10))));
            if (end != null and end[0] == 0) {
                if (serial > r.max_padserial) r.max_padserial = serial;
            } else {
                el.unlock(x);
                return null;
            }
        } else {
            el.unlock(x);
            return null;
        }
        name = c.g_strdup_printf("%s%u", prefix, serial);
        el.unlock(x);
    } else return null;
    defer c.g_free(name);
    return @ptrCast(@alignCast(c.g_object_new(pad_type, "name", name, "direction", @as(c.gint, c.GST_PAD_SINK), "template", templ, @as(?*anyopaque, null))));
}

fn requestNewPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, req_name: [*c]const u8, caps: [*c]const Caps) callconv(.c) ?*c.GstPad {
    const x = of(e);
    const p = klass(x).create_new_pad.?(x, templ, req_name, caps) orelse return null;
    _ = c.gst_element_add_pad(e, @ptrCast(p));
    return @ptrCast(p);
}

fn queryLatencyUnlocked(x: *Agg, q: [*c]Query) bool {
    const r = priv(x);
    srcUnlock(x);
    const ok = c.gst_pad_query_default(x.srcpad, @ptrCast(x), q) != 0;
    srcLock(x);
    if (!ok) return false;
    var upstream_live: c.gboolean = 0;
    var min: u64 = 0;
    var max: u64 = 0;
    c.gst_query_parse_latency(q, &upstream_live, &min, &max);
    if (min == NONE) return false;
    if (r.upstream_latency_min > min) {
        const diff = r.upstream_latency_min - min;
        min +%= diff;
        if (max != NONE) max +%= diff;
    }
    if (min > max and max != NONE) {
        srcUnlock(x);
        const dbg = c.g_strdup_printf("Impossible to configure latency: max %u:%02u:%02u.%09u < min %u:%02u:%02u.%09u. Add queues or other buffering elements.", ta(max)[0], ta(max)[1], ta(max)[2], ta(max)[3], ta(min)[0], ta(min)[1], ta(min)[2], ta(min)[3]);
        el.message(x, c.GST_MESSAGE_WARNING, .core, c.GST_CORE_ERROR_CLOCK, null, dbg, FILE, "gst_aggregator_query_latency_unlocked", 2384, null);
        srcLock(x);
        return false;
    }
    r.peer_latency_live = upstream_live != 0;
    r.peer_latency_min = min;
    r.peer_latency_max = max;
    r.has_peer_latency = true;
    min +%= r.latency;
    min +%= r.sub_latency_min;
    if (r.sub_latency_max != NONE and max != NONE) max +%= r.sub_latency_max +% r.latency else max = NONE;
    srcBroadcast(x);
    c.gst_query_set_latency(q, @intFromBool(live(x)), min, max);
    return ok;
}

fn ta(t: u64) [4]c.guint {
    if (t == NONE) return .{ 99, 99, 99, 999999999 };
    const sec = t / 1_000_000_000;
    return .{ @intCast(sec / 3600), @intCast(sec / 60 % 60), @intCast(sec % 60), @intCast(t % 1_000_000_000) };
}

fn latencyUnlocked(x: *Agg) c.GstClockTime {
    const r = priv(x);
    if (!r.has_peer_latency) {
        const q = c.gst_query_new_latency();
        const ok = queryLatencyUnlocked(x, q);
        c.gst_query_unref(q);
        if (!ok and !r.force_live) return NONE;
    }
    if (!r.force_live and (!r.has_peer_latency or !r.peer_latency_live)) return NONE;
    return r.peer_latency_min +% r.latency +% r.sub_latency_min;
}

pub export fn gst_aggregator_get_latency(s: [*c]Agg) c.GstClockTime {
    if (!check.that(isAgg(s), "gst_aggregator_get_latency_unlocked", "GST_IS_AGGREGATOR (self)")) return 0;
    srcLock(of(s));
    defer srcUnlock(of(s));
    return latencyUnlocked(of(s));
}

fn sendEvent(e: [*c]c.GstElement, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(e);
    c.g_rec_mutex_lock(&e[0].state_lock);
    if (ev[0].type == c.GST_EVENT_SEEK and e[0].current_state < c.GST_STATE_PAUSED) {
        var rate: f64 = 0;
        var fmt: c.GstFormat = 0;
        var flags_: c.GstSeekFlags = 0;
        var st: c.GstSeekType = 0;
        var et: c.GstSeekType = 0;
        var startv: i64 = 0;
        var stopv: i64 = 0;
        c.gst_event_parse_seek(ev, &rate, &fmt, &flags_, &st, &startv, &et, &stopv);
        el.lock(x);
        _ = c.gst_segment_do_seek(srcSeg(x), rate, fmt, flags_, st, @bitCast(startv), et, @bitCast(stopv), null);
        priv(x).next_seqnum = c.gst_event_get_seqnum(ev);
        priv(x).first_buffer = false;
        el.unlock(x);
    }
    c.g_rec_mutex_unlock(&e[0].state_lock);
    if (ev[0].type == c.GST_EVENT_EOS) {
        srcLock(x);
        priv(x).got_eos_event = true;
        srcBroadcast(x);
        srcUnlock(x);
    }
    return agg_parent.?.send_event.?(e, ev);
}

fn defaultSrcQuery(s: [*c]Agg, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(s);
    switch (q[0].type) {
        c.GST_QUERY_SEEKING => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_seeking(q, &format, null, null, null);
            c.gst_query_set_seeking(q, format, 0, 0, -1);
            return 1;
        },
        c.GST_QUERY_LATENCY => {
            srcLock(x);
            defer srcUnlock(x);
            return @intFromBool(queryLatencyUnlocked(x, q));
        },
        else => return c.gst_pad_query_default(x.srcpad, @ptrCast(x), q),
    }
}

const EventData = struct {
    event: [*c]Event,
    flush: bool,
    only_active: bool,
    result: bool = true,
    one_seeked: bool = false,
};

fn forwardFunc(pad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const d: *EventData = @ptrCast(@alignCast(data));
    var ret = true;
    const peer = c.gst_pad_get_peer(pad);
    defer if (peer != null) c.gst_object_unref(peer);
    if (peer != null) {
        if (!(d.only_active and pp(pad).first_buffer)) ret = c.gst_pad_send_event(peer, c.gst_event_ref(d.event)) != 0;
    }
    if (!ret) {
        if (d.event[0].type == c.GST_EVENT_SEEK) {
            const seeking = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
            if (c.gst_pad_query(peer, seeking) != 0) {
                var seekable: c.gboolean = 0;
                c.gst_query_parse_seeking(seeking, null, &seekable, null, null);
                if (seekable == 0) ret = true;
            }
            c.gst_query_unref(seeking);
        }
    } else d.one_seeked = true;
    d.result = d.result and ret;
    return 0;
}

fn forwardToSinkpads(x: *Agg, d: *EventData) void {
    d.result = true;
    d.one_seeked = false;
    _ = c.gst_pad_forward(x.srcpad, forwardFunc, d);
    c.gst_event_unref(d.event);
}

fn doSeek(x: *Agg, ev: [*c]Event) bool {
    const r = priv(x);
    var rate: f64 = 0;
    var fmt: c.GstFormat = 0;
    var flags_: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var startv: i64 = 0;
    var stopv: i64 = 0;
    c.gst_event_parse_seek(ev, &rate, &fmt, &flags_, &st, &startv, &et, &stopv);
    const flushing = flags_ & c.GST_SEEK_FLAG_FLUSH != 0;
    el.lock(x);
    if (c.gst_event_get_seqnum(ev) == r.next_seqnum) {
        el.unlock(x);
        return true;
    }
    r.next_seqnum = c.gst_event_get_seqnum(ev);
    _ = c.gst_segment_do_seek(srcSeg(x), rate, fmt, flags_, st, @bitCast(startv), et, @bitCast(stopv), null);
    r.first_buffer = false;
    if (flushing) r.flushing = true;
    el.unlock(x);
    if (flushing) {
        const fs = c.gst_event_new_flush_start();
        c.gst_event_set_seqnum(fs, r.next_seqnum);
        _ = stopTask(x, fs);
    }
    var d = EventData{ .event = ev, .flush = flushing, .only_active = false };
    forwardToSinkpads(x, &d);
    if (!d.result or !d.one_seeked) {
        el.lock(x);
        r.flushing = false;
        el.unlock(x);
        if (flushing) {
            const fs = c.gst_event_new_flush_stop(1);
            c.gst_event_set_seqnum(fs, r.next_seqnum);
            _ = c.gst_pad_push_event(x.srcpad, fs);
        }
    }
    return d.result;
}

fn defaultSrcEvent(s: [*c]Agg, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(s);
    switch (ev[0].type) {
        c.GST_EVENT_SEEK => return @intFromBool(doSeek(x, ev)),
        c.GST_EVENT_NAVIGATION => {
            c.gst_event_unref(ev);
            return 0;
        },
        c.GST_EVENT_RECONFIGURE => {
            c.gst_event_unref(ev);
            return 1;
        },
        else => {},
    }
    var d = EventData{ .event = ev, .flush = false, .only_active = ev[0].type == c.GST_EVENT_QOS };
    forwardToSinkpads(x, &d);
    return @intFromBool(d.result);
}

fn srcPadEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.gboolean {
    return klass(parent_obj).src_event.?(of(parent_obj), ev);
}

fn srcPadQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    return klass(parent_obj).src_query.?(of(parent_obj), q);
}

fn srcPadActivateMode(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, m: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    if (klass(x).src_activate) |f| {
        if (f(x, m, active) == 0) return 0;
    }
    if (active != 0) {
        if (m != c.GST_PAD_MODE_PUSH) return 0;
        startTask(x);
        return 1;
    }
    _ = stopTask(x, null);
    return 1;
}

fn defaultSinkQuery(s: [*c]Agg, sp: ?*c.GstAggregatorPad, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(s);
    const p = apad(sp);
    if (q[0].type != c.GST_QUERY_ALLOCATION) return c.gst_pad_query_default(@ptrCast(p), @ptrCast(x), q);
    el.lock(x);
    padLock(p);
    if (!p.priv.negotiated) {
        padUnlock(p);
        el.unlock(x);
        return 0;
    }
    const decide = priv(x).allocation_query;
    if (decide != null) _ = c.gst_query_ref(decide);
    padUnlock(p);
    el.unlock(x);
    const ret = if (klass(x).propose_allocation) |f| f(x, sp, decide, q) else 0;
    if (decide != null) c.gst_query_unref(decide);
    return ret;
}

fn defaultSinkQueryPreQueue(s: [*c]Agg, sp: ?*c.GstAggregatorPad, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(s);
    const p = apad(sp);
    if (q[0].type & c.GST_QUERY_TYPE_SERIALIZED == 0) return klass(x).sink_query.?(x, sp, q);
    srcLock(x);
    padLock(p);
    if (p.priv.flow_return != c.GST_FLOW_OK) {
        srcUnlock(x);
        padUnlock(p);
        return 0;
    }
    c.g_queue_push_head(&p.priv.data, q);
    srcBroadcast(x);
    srcUnlock(x);
    if (p.priv.query_in_proccess) c.g_warn_message("GStreamer-Base", "../libs/gst/base/gstaggregator.c", 2855, "gst_aggregator_default_sink_query_pre_queue", "!aggpad->priv->query_in_proccess");
    while ((!queueEmpty(p) and p.priv.flow_return == c.GST_FLOW_OK) or p.priv.query_in_proccess) padWait(p);
    const st = c.gst_query_writable_structure(q);
    var ret: c.gboolean = 0;
    if (c.gst_structure_get_boolean(st, "gst-aggregator-retval", &ret) != 0) c.gst_structure_remove_field(st, "gst-aggregator-retval") else _ = c.g_queue_remove(&p.priv.data, q);
    if (p.priv.flow_return != c.GST_FLOW_OK) {
        padUnlock(p);
        return 0;
    }
    padUnlock(p);
    return ret;
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    const x = of(o);
    @as(*c.GObjectClass, @ptrCast(agg_parent.?)).constructed.?(o);
    if (priv(x).force_live) el.setFlag(x, c.GST_ELEMENT_FLAG_SOURCE);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&priv(o).src_lock);
    c.g_cond_clear(&priv(o).src_cond);
    @as(*c.GObjectClass, @ptrCast(agg_parent.?)).finalize.?(o);
}

fn setLatencyProperty(x: *Agg, latency: c.GstClockTime) void {
    if (!check.that(isAgg(x), "gst_aggregator_set_latency_property", "GST_IS_AGGREGATOR (self)")) return;
    if (!check.that(latency != NONE, "gst_aggregator_set_latency_property", "GST_CLOCK_TIME_IS_VALID (latency)")) return;
    srcLock(x);
    const changed = priv(x).latency != latency;
    if (changed) {
        el.lock(x);
        var l: ?*c.GList = x.parent.sinkpads;
        while (l) |n| : (l = n.next) padLock(n.data);
        priv(x).latency = latency;
        srcBroadcast(x);
        l = x.parent.sinkpads;
        while (l) |n| : (l = n.next) {
            padBroadcast(n.data);
            padUnlock(n.data);
        }
        el.unlock(x);
    }
    srcUnlock(x);
    if (changed) _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_latency(@ptrCast(x)));
}

fn setProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const x = of(o);
    switch (id) {
        PROP_LATENCY => setLatencyProperty(x, c.g_value_get_uint64(v)),
        PROP_MIN_UPSTREAM_LATENCY => {
            srcLock(x);
            priv(x).upstream_latency_min = c.g_value_get_uint64(v);
            srcUnlock(x);
        },
        PROP_START_TIME_SELECTION => priv(x).start_time_selection = @intCast(c.g_value_get_enum(v)),
        PROP_START_TIME => priv(x).start_time = c.g_value_get_uint64(v),
        PROP_EMIT_SIGNALS => priv(x).emit_signals = c.g_value_get_boolean(v) != 0,
        else => el.badProperty(o, id, pspec, FILE, 3013),
    }
}

fn getProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const x = of(o);
    switch (id) {
        PROP_LATENCY => {
            el.lock(x);
            c.g_value_set_uint64(v, priv(x).latency);
            el.unlock(x);
        },
        PROP_MIN_UPSTREAM_LATENCY => {
            srcLock(x);
            c.g_value_set_uint64(v, priv(x).upstream_latency_min);
            srcUnlock(x);
        },
        PROP_START_TIME_SELECTION => c.g_value_set_enum(v, @intCast(priv(x).start_time_selection)),
        PROP_START_TIME => c.g_value_set_uint64(v, priv(x).start_time),
        PROP_EMIT_SIGNALS => c.g_value_set_boolean(v, @intFromBool(priv(x).emit_signals)),
        else => el.badProperty(o, id, pspec, FILE, 3043),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    agg_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("aggregator", c.GST_DEBUG_FG_MAGENTA, "GstAggregator");
    if (agg_offset != 0) c.g_type_class_adjust_private_offset(k, &agg_offset);
    const bc: *Class = @ptrCast(@alignCast(k));
    bc.finish_buffer = defaultFinishBuffer;
    bc.finish_buffer_list = defaultFinishList;
    bc.sink_event = defaultSinkEvent;
    bc.sink_query = defaultSinkQuery;
    bc.src_event = defaultSrcEvent;
    bc.src_query = defaultSrcQuery;
    bc.create_new_pad = defaultCreateNewPad;
    bc.update_src_caps = defaultUpdateSrcCaps;
    bc.fixate_src_caps = defaultFixateSrcCaps;
    bc.negotiated_src_caps = defaultNegotiatedSrcCaps;
    bc.negotiate = defaultNegotiate;
    bc.sink_event_pre_queue = defaultSinkEventPreQueue;
    bc.sink_query_pre_queue = defaultSinkQueryPreQueue;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.request_new_pad = requestNewPad;
    ec.send_event = sendEvent;
    ec.release_pad = releasePad;
    ec.change_state = changeState;
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProp;
    gc.get_property = getProp;
    gc.constructed = constructed;
    gc.finalize = finalize;
    const rw = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    const umax = std.math.maxInt(u64);
    c.g_object_class_install_property(gc, PROP_LATENCY, c.g_param_spec_uint64("latency", "Buffer latency", "Additional latency in live mode to allow upstream to take longer to produce buffers for the current position (in nanoseconds)", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_MIN_UPSTREAM_LATENCY, c.g_param_spec_uint64("min-upstream-latency", "Buffer latency", "When sources with a higher latency are expected to be plugged in dynamically after the aggregator has started playing, this allows overriding the minimum latency reported by the initial source(s). This is only taken into account when larger than the actually reported minimum latency. (nanoseconds)", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_START_TIME_SELECTION, c.g_param_spec_enum("start-time-selection", "Start Time Selection", "Decides which start time is output", gst_aggregator_start_time_selection_get_type(), c.GST_AGGREGATOR_START_TIME_SELECTION_ZERO, rw));
    c.g_object_class_install_property(gc, PROP_START_TIME, c.g_param_spec_uint64("start-time", "Start Time", "Start time to use if start-time-selection=set", 0, umax, umax, rw));
    c.g_object_class_install_property(gc, PROP_EMIT_SIGNALS, c.g_param_spec_boolean("emit-signals", "Emit signals", "Send signals", 0, rw));
    const static_scope: c.GType = 1;
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    samples_selected = c.g_signal_new("samples-selected", t, c.G_SIGNAL_RUN_FIRST, 0, null, null, null, 1 << c.G_TYPE_FUNDAMENTAL_SHIFT, @as(c.guint, 5), c.gst_segment_get_type() | static_scope, @as(c.GType, 11 << c.G_TYPE_FUNDAMENTAL_SHIFT), @as(c.GType, 11 << c.G_TYPE_FUNDAMENTAL_SHIFT), @as(c.GType, 11 << c.G_TYPE_FUNDAMENTAL_SHIFT), c.gst_structure_get_type() | static_scope);
    _ = c.gst_meta_register_custom_simple("GstAggregatorMissingDataMeta");
}

fn init(instance: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const x: *Agg = @ptrCast(@alignCast(instance));
    const k: *Class = @ptrCast(@alignCast(g_class));
    if (!check.that(k.aggregate != null, "gst_aggregator_init", "klass->aggregate != NULL")) return;
    const base: [*]u8 = @ptrCast(instance);
    x.priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, agg_offset)))));
    const r = priv(x);
    const templ = c.gst_element_class_get_pad_template(@ptrCast(k), "src");
    if (!check.that(templ != null, "gst_aggregator_init", "pad_template != NULL")) return;
    r.max_padserial = -1;
    r.ignore_inactive_pads = false;
    r.peer_latency_live = false;
    r.peer_latency_min = 0;
    r.sub_latency_min = 0;
    r.peer_latency_max = 0;
    r.sub_latency_max = 0;
    r.has_peer_latency = false;
    const pad_type = if (templ[0].ABI.abi.gtype == (1 << c.G_TYPE_FUNDAMENTAL_SHIFT)) gst_aggregator_pad_get_type() else templ[0].ABI.abi.gtype;
    x.srcpad = @ptrCast(@alignCast(c.g_object_new(pad_type, "name", "src", "direction", @as(c.gint, c.GST_PAD_SRC), "template", templ, @as(?*anyopaque, null))));
    resetFlowValues(x);
    c.gst_pad_set_event_function_full(x.srcpad, srcPadEvent, null, null);
    c.gst_pad_set_query_function_full(x.srcpad, srcPadQuery, null, null);
    c.gst_pad_set_activatemode_function_full(x.srcpad, srcPadActivateMode, null, null);
    _ = c.gst_element_add_pad(@ptrCast(x), x.srcpad);
    r.upstream_latency_min = 0;
    r.latency = 0;
    r.start_time_selection = c.GST_AGGREGATOR_START_TIME_SELECTION_ZERO;
    r.start_time = NONE;
    r.force_live = false;
    c.g_mutex_init(&r.src_lock);
    c.g_cond_init(&r.src_cond);
}

pub export fn gst_aggregator_get_type() c.GType {
    return agg_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstAggregator", Class, Agg, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            agg_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn hasSpace(x: *Agg, p: *AggPad) bool {
    const r = priv(x);
    if (p.priv.num_buffers == 0 and p.priv.clipped_buffer == null) return true;
    if (live(x) and p.priv.num_buffers < 2) return true;
    const max_level = r.latency +% r.sub_latency_min +% r.peer_latency_min;
    if (max_level == 0) return false;
    return p.priv.time_level <= max_level;
}

fn applyBuffer(p: *AggPad, b: [*c]Buffer, head: bool) void {
    var ts = if (b[0].dts != NONE) b[0].dts else b[0].pts;
    if (ts == NONE) ts = if (head) p.priv.head_position else p.priv.tail_position;
    if (b[0].duration != NONE) ts +%= b[0].duration;
    if (head) p.priv.head_position = ts else p.priv.tail_position = ts;
    el.lock(p);
    updateTimeLevel(p, head);
    el.unlock(p);
}

fn chainInternal(x: *Agg, p: *AggPad, buffer_in: [*c]Buffer, head: bool) c.GstFlowReturn {
    const r = priv(x);
    var buffer = buffer_in;
    padLock(p);
    var flow = p.priv.flow_return;
    if (flow != c.GST_FLOW_OK) {
        padUnlock(p);
        if (buffer != null) c.gst_buffer_unref(buffer);
        return flow;
    }
    padUnlock(p);
    const buf_pts = buffer[0].pts;
    const buf_duration = buffer[0].duration;
    while (true) {
        srcLock(x);
        el.lock(x);
        padLock(p);
        if (p.priv.first_buffer) {
            r.has_peer_latency = false;
            p.priv.first_buffer = false;
        }
        if ((hasSpace(x, p) or !head) and p.priv.flow_return == c.GST_FLOW_OK) {
            if (head) c.g_queue_push_head(&p.priv.data, buffer) else c.g_queue_push_tail(&p.priv.data, buffer);
            applyBuffer(p, buffer, head);
            p.priv.num_buffers += 1;
            p.priv.num_bytes += c.gst_buffer_get_size(buffer);
            buffer = null;
            srcBroadcast(x);
            break;
        }
        flow = p.priv.flow_return;
        if (flow != c.GST_FLOW_OK) {
            el.unlock(x);
            srcUnlock(x);
            padUnlock(p);
            if (buffer != null) c.gst_buffer_unref(buffer);
            return flow;
        }
        el.unlock(x);
        srcUnlock(x);
        padWait(p);
        padUnlock(p);
    }
    if (r.first_buffer) {
        var start_time: u64 = 0;
        switch (r.start_time_selection) {
            c.GST_AGGREGATOR_START_TIME_SELECTION_FIRST => {
                el.lock(p);
                if (p.priv.head_segment.format == c.GST_FORMAT_TIME) {
                    start_time = buf_pts;
                    if (start_time != NONE) {
                        if (p.priv.head_segment.rate < 0.0 and buf_duration != NONE) start_time +%= buf_duration;
                        start_time = @max(start_time, p.priv.head_segment.start);
                        start_time = c.gst_segment_to_running_time(&p.priv.head_segment, c.GST_FORMAT_TIME, start_time);
                    }
                } else start_time = 0;
                el.unlock(p);
            },
            c.GST_AGGREGATOR_START_TIME_SELECTION_SET => {
                start_time = r.start_time;
                if (start_time == NONE) start_time = 0;
            },
            c.GST_AGGREGATOR_START_TIME_SELECTION_NOW => start_time = c.gst_element_get_current_running_time(@ptrCast(x)),
            else => start_time = 0,
        }
        if (start_time != NONE) {
            const seg = srcSeg(x);
            seg.position = if (seg.position == NONE) start_time else @min(start_time, seg.position);
        }
    }
    padUnlock(p);
    el.unlock(x);
    srcUnlock(x);
    return flow;
}

fn padChain(pad: ?*c.GstPad, parent_obj: [*c]c.GstObject, b: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const p = apad(pad);
    c.g_mutex_lock(&p.priv.flush_lock);
    defer c.g_mutex_unlock(&p.priv.flush_lock);
    return chainInternal(of(parent_obj), p, b, true);
}

fn padQuery(pad: ?*c.GstPad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    return klass(parent_obj).sink_query_pre_queue.?(of(parent_obj), @ptrCast(pad), q);
}

fn padEvent(pad: ?*c.GstPad, parent_obj: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.GstFlowReturn {
    return klass(parent_obj).sink_event_pre_queue.?(of(parent_obj), @ptrCast(pad), ev);
}

fn padActivateMode(pad: ?*c.GstPad, parent_obj: [*c]c.GstObject, _: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    const p = apad(pad);
    if (active == 0) {
        srcLock(x);
        padSetFlushing(p, c.GST_FLOW_FLUSHING, true);
        srcBroadcast(x);
        srcUnlock(x);
    } else {
        padLock(p);
        p.priv.flow_return = c.GST_FLOW_OK;
        padBroadcast(p);
        padUnlock(p);
    }
    return 1;
}

fn padConstructed(o: [*c]c.GObject) callconv(.c) void {
    pad_parent.?.constructed.?(o);
    const pad: ?*c.GstPad = @ptrCast(o);
    if (el.pad(pad).direction != c.GST_PAD_SINK) return;
    c.gst_pad_set_chain_function_full(pad, padChain, null, null);
    c.gst_pad_set_event_full_function_full(pad, padEvent, null, null);
    c.gst_pad_set_query_function_full(pad, padQuery, null, null);
    c.gst_pad_set_activatemode_function_full(pad, padActivateMode, null, null);
}

fn padFinalize(o: [*c]c.GObject) callconv(.c) void {
    const p = apad(o);
    _ = c.gst_mini_object_replace(@ptrCast(&p.priv.peeked_buffer), null);
    c.g_cond_clear(&p.priv.event_cond);
    c.g_mutex_clear(&p.priv.flush_lock);
    c.g_mutex_clear(&p.priv.lock);
    pad_parent.?.finalize.?(o);
}

fn padDispose(o: [*c]c.GObject) callconv(.c) void {
    padSetFlushing(apad(o), c.GST_FLOW_FLUSHING, true);
    pad_parent.?.dispose.?(o);
}

fn padSetProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PAD_PROP_EMIT_SIGNALS => pp(o).emit_signals = c.g_value_get_boolean(v) != 0,
        else => el.badProperty(o, id, pspec, FILE, 3620),
    }
}

fn padGetProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = apad(o);
    switch (id) {
        PAD_PROP_EMIT_SIGNALS => c.g_value_set_boolean(v, @intFromBool(p.priv.emit_signals)),
        PAD_PROP_LEVEL_TIME, PAD_PROP_LEVEL_BUFFERS, PAD_PROP_LEVEL_BYTES => {
            padLock(p);
            el.lock(p);
            c.g_value_set_uint64(v, switch (id) {
                PAD_PROP_LEVEL_TIME => p.priv.time_level,
                PAD_PROP_LEVEL_BUFFERS => p.priv.num_buffers,
                else => p.priv.num_bytes,
            });
            el.unlock(p);
            padUnlock(p);
        },
        else => el.badProperty(o, id, pspec, FILE, 3657),
    }
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (pad_offset != 0) c.g_type_class_adjust_private_offset(k, &pad_offset);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.constructed = padConstructed;
    gc.finalize = padFinalize;
    gc.dispose = padDispose;
    gc.set_property = padSetProp;
    gc.get_property = padGetProp;
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    buffer_consumed = c.g_signal_new("buffer-consumed", t, c.G_SIGNAL_RUN_FIRST, 0, null, null, null, 1 << c.G_TYPE_FUNDAMENTAL_SHIFT, @as(c.guint, 1), c._gst_buffer_type);
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const umax = std.math.maxInt(u64);
    c.g_object_class_install_property(gc, PAD_PROP_EMIT_SIGNALS, c.g_param_spec_boolean("emit-signals", "Emit signals", "Send signals to signal data consumption", 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(gc, PAD_PROP_LEVEL_TIME, c.g_param_spec_uint64("current-level-time", "Current Level Time", "The amount of currently queued time", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PAD_PROP_LEVEL_BUFFERS, c.g_param_spec_uint64("current-level-buffers", "Current Level Buffers", "The number of currently queued buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PAD_PROP_LEVEL_BYTES, c.g_param_spec_uint64("current-level-bytes", "Current Level Bytes", "The number of currently queued bytes", 0, umax, 0, ro));
}

fn padInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: *AggPad = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    p.priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, pad_offset)))));
    c.g_queue_init(&p.priv.data);
    c.g_cond_init(&p.priv.event_cond);
    c.g_mutex_init(&p.priv.flush_lock);
    c.g_mutex_init(&p.priv.lock);
    padReset(p);
    p.priv.negotiated = false;
    p.priv.emit_signals = false;
}

pub export fn gst_aggregator_pad_get_type() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_pad_get_type, "GstAggregatorPad", PadClass, AggPad, padClassInit, padInit, 0);
            pad_offset = c.g_type_add_instance_private(t, @sizeOf(PadPriv));
            return t;
        }
    }.f);
}

fn clipUnlocked(p: *AggPad) void {
    var x: [*c]Agg = null;
    var k: ?*Class = null;
    defer if (x != null) c.gst_object_unref(x);
    while (p.priv.clipped_buffer == null and isBuffer(tail(p))) {
        var b: [*c]Buffer = @ptrCast(@alignCast(c.g_queue_pop_tail(&p.priv.data)));
        applyBuffer(p, b, false);
        if (x == null) {
            x = @ptrCast(@alignCast(c.gst_pad_get_parent_element(@ptrCast(p))));
            if (x == null) {
                c.gst_buffer_unref(b);
                return;
            }
            k = klass(x);
        }
        if (k.?.clip) |f| {
            const ref = c.gst_buffer_ref(b);
            b = f(x, @ptrCast(p), b);
            if (b == null) {
                bufferConsumed(p, ref, true);
            } else {
                p.priv.num_bytes -%= c.gst_buffer_get_size(ref) - c.gst_buffer_get_size(b);
            }
            c.gst_buffer_unref(ref);
        }
        p.priv.clipped_buffer = b;
    }
}

pub export fn gst_aggregator_pad_pop_buffer(sp: ?*c.GstAggregatorPad) [*c]Buffer {
    const p = apad(sp);
    padLock(p);
    defer padUnlock(p);
    var b: [*c]Buffer = null;
    if (p.priv.peeked_buffer != null) {
        b = p.priv.peeked_buffer;
    } else if (p.priv.flow_return == c.GST_FLOW_OK) {
        clipUnlocked(p);
        b = p.priv.clipped_buffer;
    }
    if (b != null) {
        if (p.priv.clipped_buffer != null) {
            bufferConsumed(p, b, true);
            p.priv.clipped_buffer = null;
            _ = c.gst_mini_object_replace(@ptrCast(&p.priv.peeked_buffer), null);
        } else {
            bufferConsumed(p, b, false);
            p.priv.peeked_buffer = null;
        }
    }
    return b;
}

pub export fn gst_aggregator_pad_drop_buffer(sp: ?*c.GstAggregatorPad) c.gboolean {
    const b = gst_aggregator_pad_pop_buffer(sp);
    if (b == null) return 0;
    c.gst_buffer_unref(b);
    return 1;
}

pub export fn gst_aggregator_pad_peek_buffer(sp: ?*c.GstAggregatorPad) [*c]Buffer {
    const p = apad(sp);
    padLock(p);
    defer padUnlock(p);
    if (p.priv.peeked_buffer != null) return c.gst_buffer_ref(p.priv.peeked_buffer);
    if (p.priv.flow_return != c.GST_FLOW_OK) return null;
    clipUnlocked(p);
    if (p.priv.clipped_buffer == null) return null;
    const b = c.gst_buffer_ref(p.priv.clipped_buffer);
    p.priv.peeked_buffer = c.gst_buffer_ref(b);
    return b;
}

pub export fn gst_aggregator_pad_has_buffer(sp: ?*c.GstAggregatorPad) c.gboolean {
    const p = apad(sp);
    padLock(p);
    defer padUnlock(p);
    if (p.priv.peeked_buffer != null) return 1;
    clipUnlocked(p);
    if (p.priv.clipped_buffer == null) return 0;
    p.priv.peeked_buffer = c.gst_buffer_ref(p.priv.clipped_buffer);
    return 1;
}

pub export fn gst_aggregator_pad_is_eos(sp: ?*c.GstAggregatorPad) c.gboolean {
    padLock(sp);
    defer padUnlock(sp);
    return @intFromBool(pp(sp).eos);
}

pub export fn gst_aggregator_pad_is_inactive(sp: ?*c.GstAggregatorPad) c.gboolean {
    const x: [*c]Agg = @ptrCast(@alignCast(c.gst_pad_get_parent_element(@ptrCast(sp))));
    if (x == null) return 0;
    defer c.gst_object_unref(x);
    padLock(sp);
    defer padUnlock(sp);
    return @intFromBool(priv(x).ignore_inactive_pads and live(of(x)) and pp(sp).first_buffer);
}

pub export fn gst_aggregator_set_latency(s: [*c]Agg, min: c.GstClockTime, max: c.GstClockTime) void {
    if (!check.that(isAgg(s), "gst_aggregator_set_latency", "GST_IS_AGGREGATOR (self)")) return;
    if (!check.that(min != NONE, "gst_aggregator_set_latency", "GST_CLOCK_TIME_IS_VALID (min_latency)")) return;
    if (!check.that(max >= min, "gst_aggregator_set_latency", "max_latency >= min_latency")) return;
    const x = of(s);
    const r = priv(x);
    var changed = false;
    srcLock(x);
    if (r.sub_latency_min != min) {
        r.sub_latency_min = min;
        changed = true;
    }
    if (r.sub_latency_max != max) {
        r.sub_latency_max = max;
        changed = true;
    }
    if (!r.posted_latency_msg) {
        r.posted_latency_msg = true;
        changed = true;
    }
    if (changed) srcBroadcast(x);
    srcUnlock(x);
    if (changed) _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_latency(@ptrCast(x)));
}

pub export fn gst_aggregator_get_buffer_pool(s: [*c]Agg) ?*c.GstBufferPool {
    if (!check.that(isAgg(s), "gst_aggregator_get_buffer_pool", "GST_IS_AGGREGATOR (self)")) return null;
    el.lock(s);
    defer el.unlock(s);
    const pool = priv(s).pool;
    if (pool != null) _ = c.gst_object_ref(pool);
    return pool;
}

pub export fn gst_aggregator_get_allocator(s: [*c]Agg, allocator: [*c]?*c.GstAllocator, params: [*c]c.GstAllocationParams) void {
    if (!check.that(isAgg(s), "gst_aggregator_get_allocator", "GST_IS_AGGREGATOR (self)")) return;
    const r = priv(s);
    if (allocator != null) allocator.* = if (r.allocator != null) @ptrCast(@alignCast(c.gst_object_ref(r.allocator))) else null;
    if (params != null) params.* = r.allocation_params;
}

pub export fn gst_aggregator_simple_get_next_time(s: [*c]Agg) c.GstClockTime {
    const x = of(s);
    const seg = srcSeg(x);
    el.lock(x);
    defer el.unlock(x);
    if (seg.format != c.GST_FORMAT_TIME) return NONE;
    var next = if (seg.position == NONE or seg.position < seg.start) seg.start else seg.position;
    if (seg.stop != NONE and next > seg.stop) next = seg.stop;
    return c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, next);
}

pub export fn gst_aggregator_update_segment(s: [*c]Agg, segment: [*c]const c.GstSegment) void {
    if (!check.that(isAgg(s), "gst_aggregator_update_segment", "GST_IS_AGGREGATOR (self)")) return;
    if (!check.that(segment != null, "gst_aggregator_update_segment", "segment != NULL")) return;
    const x = of(s);
    el.lock(x);
    srcSeg(x).* = segment[0];
    priv(x).send_segment = true;
    priv(x).first_buffer = false;
    el.unlock(x);
}

pub export fn gst_aggregator_selected_samples(s: [*c]Agg, pts: c.GstClockTime, dts: c.GstClockTime, duration: c.GstClockTime, info: [*c]c.GstStructure) void {
    if (!check.that(isAgg(s), "gst_aggregator_selected_samples", "GST_IS_AGGREGATOR (self)")) return;
    const x = of(s);
    if (priv(x).emit_signals) c.g_signal_emit(x, samples_selected, 0, srcSeg(x), pts, dts, duration, info);
    priv(x).selected_samples_called_or_warned = true;
}

pub export fn gst_aggregator_set_ignore_inactive_pads(s: [*c]Agg, ignore: c.gboolean) void {
    if (!check.that(isAgg(s), "gst_aggregator_set_ignore_inactive_pads", "GST_IS_AGGREGATOR (self)")) return;
    el.lock(s);
    priv(s).ignore_inactive_pads = ignore != 0;
    el.unlock(s);
}

pub export fn gst_aggregator_get_ignore_inactive_pads(s: [*c]Agg) c.gboolean {
    if (!check.that(isAgg(s), "gst_aggregator_get_ignore_inactive_pads", "GST_IS_AGGREGATOR (self)")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return @intFromBool(priv(s).ignore_inactive_pads);
}

pub export fn gst_aggregator_get_force_live(s: [*c]Agg) c.gboolean {
    return @intFromBool(priv(s).force_live);
}

pub export fn gst_aggregator_set_force_live(s: [*c]Agg, force: c.gboolean) void {
    priv(s).force_live = force != 0;
}
