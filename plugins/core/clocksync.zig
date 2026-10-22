const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstclocksync.c";
const NONE = cm.CLOCK_NONE;

const PROP_SYNC = 1;
const PROP_TS_OFFSET = 2;
const PROP_SYNC_TO_FIRST = 3;
const PROP_QOS = 4;
const PROP_RATE = 5;

const Self = extern struct {
    parent: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    segment: c.GstSegment,
    clock_id: c.GstClockID,
    flushing: c.gboolean,
    sync: c.gboolean,
    rate: c.gdouble,
    blocked_cond: c.GCond,
    blocked: c.gboolean,
    ts_offset: i64,
    sync_to_first: c.gboolean,
    is_first: c.gint,
    upstream_latency: u64,
    qos_enabled: c.gint,
    earliest_in_time: u64,
    current_rstart: u64,
    current_jitter: i64,
    avg_pt: u64,
    avg_in_diff: u64,
    avg_rate: c.gdouble,
    last_left: u64,
    prev_rstart: u64,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var pspec_offset: [*c]c.GParamSpec = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) *c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn valid(t: u64) bool {
    return t != NONE;
}

fn avg(a: u64, v: u64, n: u64) u64 {
    return (v +% (n - 1) *% a) / n;
}

fn avgF(a: f64, v: f64, n: f64) f64 {
    return (v + (n - 1) * a) / n;
}

fn qosOn(s: *Self) bool {
    return @atomicLoad(c.gint, &s.qos_enabled, .seq_cst) != 0;
}

fn resetQos(s: *Self) void {
    s.prev_rstart = NONE;
    s.earliest_in_time = NONE;
    s.last_left = NONE;
    s.avg_pt = NONE;
    s.avg_rate = -1.0;
    s.avg_in_diff = NONE;
}

fn performQos(s: *Self) bool {
    const start = s.current_rstart;
    if (!qosOn(s) or !valid(start) or s.sync == 0) return false;
    const jitter = s.current_jitter;
    const entered: u64 = if (jitter < 0 and start < @as(u64, @intCast(-jitter))) 0 else start +% @as(u64, @bitCast(jitter));
    const dur = s.avg_in_diff;
    const pt: u64 = if (valid(s.last_left)) (if (entered > s.last_left) entered - s.last_left else 0) else s.avg_pt;
    s.avg_pt = if (valid(s.avg_pt)) avg(s.avg_pt, pt, 8) else pt;
    const rate: f64 = if (dur != NONE and dur != 0) @as(f64, @floatFromInt(s.avg_pt)) / @as(f64, @floatFromInt(dur)) else 1.0;
    if (valid(s.last_left)) {
        if (s.avg_rate < 0.0) {
            s.avg_rate = rate;
        } else if (rate > 1.0) {
            s.avg_rate = avgF(s.avg_rate, rate, 4);
        } else s.avg_rate = avgF(s.avg_rate, rate, 16);
    }
    if (s.avg_rate >= 0.0) {
        if (s.current_jitter < 0 and s.current_rstart < @as(u64, @intCast(-s.current_jitter))) s.current_jitter = -@as(i64, @bitCast(s.current_rstart));
        const diff = s.current_jitter;
        const kind: c.GstQOSType = if (diff <= 0) c.GST_QOS_TYPE_OVERFLOW else c.GST_QOS_TYPE_UNDERFLOW;
        _ = c.gst_pad_push_event(s.sinkpad, c.gst_event_new_qos(kind, s.avg_rate, diff, s.current_rstart));
    }
    return true;
}

fn doSync(s: *Self, running: u64) c.GstFlowReturn {
    s.current_rstart = NONE;
    if (s.sync == 0 or running == NONE or s.segment.format != c.GST_FORMAT_TIME) return c.GST_FLOW_OK;
    cm.lock(s);
    defer cm.unlock(s);
    if (s.flushing != 0) return c.GST_FLOW_FLUSHING;
    while (s.blocked != 0 and s.flushing == 0) c.g_cond_wait(&s.blocked_cond, &cm.obj(s).lock);
    if (s.flushing != 0) return c.GST_FLOW_FLUSHING;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    const clock = element(s).clock;
    if (clock != null) {
        var ts: u64 = running +% @as(u64, @bitCast(element(s).base_time)) +% s.upstream_latency;
        const off = s.ts_offset;
        if (off < 0) {
            const uo: u64 = @intCast(-off);
            ts = if (uo < ts) ts - uo else 0;
        } else ts +%= @intCast(off);
        s.clock_id = c.gst_clock_new_single_shot_id(clock, ts);
        cm.unlock(s);
        var jitter: c.GstClockTimeDiff = 0;
        const cret = c.gst_clock_id_wait(s.clock_id, &jitter);
        cm.lock(s);
        if (s.clock_id != null) {
            c.gst_clock_id_unref(s.clock_id);
            s.clock_id = null;
        }
        if (cret == c.GST_CLOCK_UNSCHEDULED or s.flushing != 0) ret = c.GST_FLOW_FLUSHING;
        s.current_jitter = jitter;
    }
    s.current_rstart = running;
    if (valid(s.prev_rstart) and s.prev_rstart < running) {
        const d = running - s.prev_rstart;
        s.avg_in_diff = if (s.avg_in_diff == NONE) d else avg(s.avg_in_diff, d, 8);
    }
    s.prev_rstart = running;
    return ret;
}

fn updateOffset(s: *Self, rts: u64) void {
    if (s.sync_to_first == 0 or @atomicLoad(c.gint, &s.is_first, .seq_cst) == 0 or s.sync == 0) return;
    cm.lock(s);
    const clock = element(s).clock;
    if (clock == null) {
        cm.unlock(s);
        return;
    }
    const now = c.gst_clock_get_time(clock) -% @as(u64, @bitCast(element(s).base_time));
    const off: i64 = @bitCast(now -% rts);
    cm.unlock(s);
    @atomicStore(c.gint, &s.is_first, 0, .seq_cst);
    if (off != s.ts_offset) {
        s.ts_offset = off;
        c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspec_offset);
    }
}

fn runningOf(s: *Self, t: u64) u64 {
    return c.gst_segment_to_running_time(&s.segment, c.GST_FORMAT_TIME, t);
}

fn stamp(s: *Self, b: *c.GstBuffer, reverse: bool) u64 {
    var dts = b.dts;
    var pts = b.pts;
    if (reverse) {
        if (valid(b.duration) and valid(pts)) pts +%= b.duration;
        if (valid(b.duration) and valid(dts)) dts +%= b.duration;
    }
    const rd = runningOf(s, dts);
    const rp = runningOf(s, pts);
    return if (valid(rd)) rd else if (valid(rp)) rp else 0;
}

fn before(s: *Self, b: *c.GstBuffer, reverse: bool, qos: *bool) c.GstFlowReturn {
    if (s.segment.format != c.GST_FORMAT_TIME) return c.GST_FLOW_OK;
    const rts = stamp(s, b, reverse);
    updateOffset(s, rts);
    const ret = doSync(s, rts);
    if (ret != c.GST_FLOW_OK) return ret;
    qos.* = performQos(s);
    return c.GST_FLOW_OK;
}

fn after(s: *Self, qos: bool) void {
    if (qos) s.last_left = c.gst_element_get_current_running_time(element(s));
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    var qos = false;
    const r = before(s, cm.buf(b), s.segment.rate <= 0.0, &qos);
    if (r != c.GST_FLOW_OK) {
        c.gst_buffer_unref(b);
        return r;
    }
    const ret = c.gst_pad_push(s.srcpad, b);
    after(s, qos);
    return ret;
}

fn chainList(_: ?*c.GstPad, par: [*c]c.GstObject, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    var qos = false;
    if (c.gst_buffer_list_length(l) != 0) {
        const r = before(s, cm.buf(c.gst_buffer_list_get(l, 0)), false, &qos);
        if (r != c.GST_FLOW_OK) {
            c.gst_mini_object_unref(@ptrCast(@alignCast(l)));
            return r;
        }
    }
    const ret = c.gst_pad_push_list(s.srcpad, l);
    after(s, qos);
    return ret;
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(ev, &s.segment);
            if (s.rate > 0.0) s.segment.rate *= s.rate;
            resetQos(s);
        },
        c.GST_EVENT_GAP => if (s.segment.format == c.GST_FORMAT_TIME) {
            var start: u64 = 0;
            var dur: u64 = 0;
            c.gst_event_parse_gap(ev, &start, &dur);
            if (valid(start)) _ = doSync(s, runningOf(s, start));
        },
        c.GST_EVENT_FLUSH_START => {
            cm.lock(s);
            s.flushing = 1;
            c.g_cond_signal(&s.blocked_cond);
            if (s.clock_id != null) c.gst_clock_id_unschedule(s.clock_id);
            cm.unlock(s);
        },
        c.GST_EVENT_FLUSH_STOP => {
            cm.lock(s);
            s.flushing = 0;
            c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED);
            cm.unlock(s);
            resetQos(s);
            @atomicStore(c.gint, &s.is_first, 1, .seq_cst);
        },
        else => {},
    }
    return c.gst_pad_event_default(pad, par, ev);
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(ev) == c.GST_EVENT_QOS and qosOn(me(par))) {
        c.gst_mini_object_unref(@ptrCast(ev));
        return 1;
    }
    return c.gst_pad_event_default(pad, par, ev);
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(par);
    const res = c.gst_pad_query_default(pad, par, q);
    if (cm.queryType(q) != c.GST_QUERY_LATENCY) return res;
    var live: c.gboolean = 0;
    var min: u64 = 0;
    var max: u64 = 0;
    if (res != 0) {
        c.gst_query_parse_latency(q, &live, &min, &max);
        if (s.sync != 0 and max < min) {
            var a: [64]u8 = undefined;
            var b: [64]u8 = undefined;
            cm.elementWarning(par, c.gst_core_error_quark(), c.GST_CORE_ERROR_CLOCK, null, c.g_strdup_printf("Impossible to configure latency upstream of clocksync sync=true: max %s < min %s. Add queues or other buffering elements.", cm.timeFmt(&a, max), cm.timeFmt(&b, min)), FILE, "gst_clock_sync_src_query", 876);
        }
    }
    cm.lock(s);
    if (live != 0) {
        s.upstream_latency = min;
    } else {
        s.upstream_latency = 0;
        max = NONE;
    }
    cm.unlock(s);
    c.gst_query_set_latency(q, @intFromBool(live != 0 or (s.sync != 0 and s.rate == 1.0)), min, max);
    return res;
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(el);
    var no_preroll = false;
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            cm.lock(s);
            s.flushing = 0;
            s.blocked = 1;
            cm.unlock(s);
            if (s.sync != 0) no_preroll = true;
            @atomicStore(c.gint, &s.is_first, 1, .seq_cst);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => {
            cm.lock(s);
            s.blocked = 0;
            c.g_cond_signal(&s.blocked_cond);
            cm.unlock(s);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            cm.lock(s);
            s.flushing = 1;
            if (s.clock_id != null) c.gst_clock_id_unschedule(s.clock_id);
            s.blocked = 0;
            c.g_cond_signal(&s.blocked_cond);
            cm.unlock(s);
        },
        else => {},
    }
    var ret = parent.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_PLAYING_TO_PAUSED) {
        cm.lock(s);
        s.upstream_latency = 0;
        s.blocked = 1;
        cm.unlock(s);
        if (s.sync != 0) no_preroll = true;
        resetQos(s);
    }
    if (no_preroll and ret == c.GST_STATE_CHANGE_SUCCESS) ret = c.GST_STATE_CHANGE_NO_PREROLL;
    return ret;
}

fn provideClock(el: [*c]c.GstElement) callconv(.c) [*c]c.GstClock {
    if (me(el).sync == 0) return null;
    return c.gst_system_clock_obtain();
}

fn resync(s: *Self) callconv(.c) void {
    @atomicStore(c.gint, &s.is_first, 1, .seq_cst);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SYNC => s.sync = c.g_value_get_boolean(v),
        PROP_TS_OFFSET => s.ts_offset = c.g_value_get_int64(v),
        PROP_SYNC_TO_FIRST => s.sync_to_first = c.g_value_get_boolean(v),
        PROP_QOS => @atomicStore(c.gint, &s.qos_enabled, c.g_value_get_boolean(v), .seq_cst),
        PROP_RATE => s.rate = c.g_value_get_double(v),
        else => cm.warnInvalid(FILE, o, id, spec, 336),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SYNC => c.g_value_set_boolean(v, s.sync),
        PROP_TS_OFFSET => c.g_value_set_int64(v, s.ts_offset),
        PROP_SYNC_TO_FIRST => c.g_value_set_boolean(v, s.sync_to_first),
        PROP_QOS => c.g_value_set_boolean(v, @atomicLoad(c.gint, &s.qos_enabled, .seq_cst)),
        PROP_RATE => c.g_value_set_double(v, s.rate),
        else => cm.warnInvalid(FILE, o, id, spec, 364),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_cond_clear(&me(o).blocked_cond);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

const TO_FIRST_BLURB = "Automatically set ts-offset based on running time of the first " ++
    "buffer and pipeline's running time " ++
    "(i.e., ts-offset = \"pipeline running time\" - \"buffer running time\"). " ++
    "When enabled, clocksync element will update ts-offset on the first " ++
    "buffer per flush event or READY to PAUSED state change. " ++
    "This property can be useful in case that buffer timestamp does not " ++
    "necessarily have to be synchronized with pipeline's running time, " ++
    "but duration of the buffer through clocksync element needs to be " ++
    "synchronized with the amount of clock time go. " ++
    "Note that mixed use of ts-offset and this property would be racy " ++
    "if clocksync element is running already.";

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.g_object_class_install_property(oc, PROP_SYNC, c.g_param_spec_boolean("sync", "Synchronize", "Synchronize to pipeline clock", 1, cm.RW));
    pspec_offset = c.g_param_spec_int64("ts-offset", "Timestamp offset for synchronisation", "Timestamp offset in nanoseconds for synchronisation, negative for earlier sync", std.math.minInt(i64), std.math.maxInt(i64), 0, cm.RW);
    c.g_object_class_install_property(oc, PROP_TS_OFFSET, pspec_offset);
    c.g_object_class_install_property(oc, PROP_SYNC_TO_FIRST, c.g_param_spec_boolean("sync-to-first", "Sync to first", TO_FIRST_BLURB, 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_QOS, c.g_param_spec_boolean("qos", "Qos", "Generate Quality-of-Service events upstream", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_RATE, c.g_param_spec_double("rate", "Rate", "Factor of buffer output speed", 0.0, std.math.floatMax(f64), 1.0, cm.RW | cm.MUTABLE_READY));
    _ = c.g_signal_new_class_handler("resync", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @ptrCast(&resync), null, null, null, c.G_TYPE_NONE, 0);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    ec.provide_clock = provideClock;
    c.gst_element_class_set_static_metadata(ec, "ClockSync", "Generic", "Synchronise buffers to the clock", "Jan Schmidt <jan@centricular.com>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const e: [*c]c.GstElement = @ptrCast(@alignCast(inst));
    s.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_event_function_full(s.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_chain_function_full(s.sinkpad, chain, null, null);
    c.gst_pad_set_chain_list_function_full(s.sinkpad, chainList, null, null);
    cm.setPadFlag(s.sinkpad, c.GST_PAD_FLAG_PROXY_CAPS | c.GST_PAD_FLAG_PROXY_ALLOCATION);
    _ = c.gst_element_add_pad(e, s.sinkpad);
    s.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_query_function_full(s.srcpad, srcQuery, null, null);
    cm.setPadFlag(s.srcpad, c.GST_PAD_FLAG_PROXY_CAPS | c.GST_PAD_FLAG_PROXY_ALLOCATION);
    c.gst_pad_set_event_function_full(s.srcpad, srcEvent, null, null);
    _ = c.gst_element_add_pad(e, s.srcpad);
    s.ts_offset = 0;
    s.sync = 1;
    s.sync_to_first = 0;
    s.rate = 1.0;
    @atomicStore(c.gint, &s.qos_enabled, 0, .seq_cst);
    c.g_cond_init(&s.blocked_cond);
    cm.obj(s).flags |= c.GST_ELEMENT_FLAG_PROVIDE_CLOCK | c.GST_ELEMENT_FLAG_REQUIRE_CLOCK;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstClockSync", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("clocksync", 0, "clocksync element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "clocksync", c.GST_RANK_NONE, getType()) != 0;
}
