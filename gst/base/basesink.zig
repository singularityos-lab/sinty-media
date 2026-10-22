const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("el.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Sink = c.GstBaseSink;
const Class = c.GstBaseSinkClass;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const Caps = c.GstCaps;
const Mini = c.GstMiniObject;
const NONE = el.NONE;
const FILE = "gstbasesink.c";
const SEC: u64 = 1_000_000_000;
const FLOW_STEP: c.GstFlowReturn = c.GST_FLOW_CUSTOM_ERROR;
const FLOW_DROPPED: c.GstFlowReturn = c.GST_FLOW_CUSTOM_SUCCESS;

const PROP_SYNC = 1;
const PROP_MAX_LATENESS = 2;
const PROP_QOS = 3;
const PROP_ASYNC = 4;
const PROP_TS_OFFSET = 5;
const PROP_ENABLE_LAST_SAMPLE = 6;
const PROP_LAST_SAMPLE = 7;
const PROP_BLOCKSIZE = 8;
const PROP_RENDER_DELAY = 9;
const PROP_THROTTLE_TIME = 10;
const PROP_MAX_BITRATE = 11;
const PROP_PROCESSING_DEADLINE = 12;
const PROP_STATS = 13;

const Step = extern struct {
    valid: bool,
    seqnum: c.guint32,
    format: c.GstFormat,
    amount: u64,
    position: u64,
    duration: u64,
    start: u64,
    rate: f64,
    start_rate: f64,
    start_start: u64,
    start_stop: u64,
    flush: bool,
    intermediate: bool,
    need_preroll: bool,
};

const Private = extern struct {
    qos_enabled: c.gint,
    async_enabled: c.gint,
    ts_offset: c.GstClockTimeDiff,
    render_delay: c.GstClockTime,
    processing_deadline: c.GstClockTime,
    current_sstart: c.GstClockTime,
    current_sstop: c.GstClockTime,
    current_rstart: c.GstClockTime,
    current_rstop: c.GstClockTime,
    current_jitter: c.GstClockTimeDiff,
    prev_rstart: c.GstClockTime,
    eos_rtime: c.GstClockTime,
    last_render_time: c.GstClockTime,
    last_left: c.GstClockTime,
    avg_pt: c.GstClockTime,
    avg_in_diff: c.GstClockTime,
    avg_rate: f64,
    rendered: u64,
    dropped: u64,
    latency: c.GstClockTime,
    committed: bool,
    to_playing: c.gint,
    received_eos: bool,
    have_latency: bool,
    enable_last_sample: c.gint,
    last_buffer: [*c]Buffer,
    last_caps: [*c]Caps,
    last_buffer_list: ?*c.GstBufferList,
    caps: [*c]Caps,
    blocksize: c.guint,
    discont: bool,
    seqnum: c.guint32,
    call_preroll: bool,
    step_unlock: bool,
    current_step: Step,
    pending_step: Step,
    instant_rate_sync_seqnum: c.guint32,
    instant_rate_multiplier: f64,
    last_instant_rate_seqnum: c.guint32,
    upstream_segment: c.GstSegment,
    last_anchor_running_time: c.GstClockTime,
    instant_rate_offset: c.GstClockTimeDiff,
    cached_clock_id: c.GstClockID,
    earliest_in_time: c.GstClockTime,
    throttle_time: c.GstClockTime,
    max_bitrate: u64,
    rc_time: c.GstClockTime,
    rc_next: c.GstClockTime,
    rc_accumulated: c.gsize,
    drop_out_of_segment: bool,
};

var type_once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GstElementClass = null;

fn priv(s: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Sink, @ptrCast(@alignCast(s)))[0].priv));
}

fn of(p: anytype) *Sink {
    return @ptrCast(@alignCast(p));
}

fn klass(s: anytype) *Class {
    return el.classOf(Class, s);
}

pub fn isSink(s: anytype) bool {
    return gtype.instanceOf(s, gst_base_sink_get_type());
}

fn prerollLock(s: *Sink) void {
    c.g_mutex_lock(&s.preroll_lock);
}

fn prerollUnlock(s: *Sink) void {
    c.g_mutex_unlock(&s.preroll_lock);
}

fn prerollSignal(s: *Sink) void {
    c.g_cond_signal(&s.preroll_cond);
}

fn atomicGet(p: *c.gint) bool {
    return @atomicLoad(c.gint, p, .seq_cst) != 0;
}

fn atomicSet(p: *c.gint, v: bool) void {
    @atomicStore(c.gint, p, @intFromBool(v), .seq_cst);
}

fn valid(t: u64) bool {
    return t != NONE;
}

fn sdiff(a: u64, b: u64) c.GstClockTimeDiff {
    return @as(c.GstClockTimeDiff, @bitCast(b)) -% @as(c.GstClockTimeDiff, @bitCast(a));
}

fn isEvent(o: anytype) bool {
    return @as(*Mini, @ptrCast(@alignCast(o))).type == c._gst_event_type;
}

fn isBuffer(o: anytype) bool {
    return @as(*Mini, @ptrCast(@alignCast(o))).type == c._gst_buffer_type;
}

fn isList(o: anytype) bool {
    return @as(*Mini, @ptrCast(@alignCast(o))).type == c._gst_buffer_list_type;
}

pub export fn gst_base_sink_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstBaseSink", Class, Sink, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    if (offset != 0) c.g_type_class_adjust_private_offset(k, &offset);
    _ = c._gst_debug_category_new("basesink", 0, "basesink element");
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = finalize;
    gc.set_property = setProp;
    gc.get_property = getProp;
    const rw = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const umax = std.math.maxInt(u64);
    c.g_object_class_install_property(gc, PROP_SYNC, c.g_param_spec_boolean("sync", "Sync", "Sync on the clock", 1, rw));
    c.g_object_class_install_property(gc, PROP_MAX_LATENESS, c.g_param_spec_int64("max-lateness", "Max Lateness", "Maximum number of nanoseconds that a buffer can be late before it is dropped (-1 unlimited)", -1, std.math.maxInt(i64), -1, rw));
    c.g_object_class_install_property(gc, PROP_QOS, c.g_param_spec_boolean("qos", "Qos", "Generate Quality-of-Service events upstream", 0, rw));
    c.g_object_class_install_property(gc, PROP_ASYNC, c.g_param_spec_boolean("async", "Async", "Go asynchronously to PAUSED", 1, rw));
    c.g_object_class_install_property(gc, PROP_TS_OFFSET, c.g_param_spec_int64("ts-offset", "TS Offset", "Timestamp offset in nanoseconds", std.math.minInt(i64), std.math.maxInt(i64), 0, rw));
    c.g_object_class_install_property(gc, PROP_ENABLE_LAST_SAMPLE, c.g_param_spec_boolean("enable-last-sample", "Enable Last Buffer", "Enable the last-sample property", 1, rw));
    c.g_object_class_install_property(gc, PROP_LAST_SAMPLE, c.g_param_spec_boxed("last-sample", "Last Sample", "The last sample received in the sink", c.gst_sample_get_type(), ro));
    c.g_object_class_install_property(gc, PROP_BLOCKSIZE, c.g_param_spec_uint("blocksize", "Block size", "Size in bytes to pull per buffer (0 = default)", 0, std.math.maxInt(c.guint), 4096, rw));
    c.g_object_class_install_property(gc, PROP_RENDER_DELAY, c.g_param_spec_uint64("render-delay", "Render Delay", "Additional render delay of the sink in nanoseconds", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_THROTTLE_TIME, c.g_param_spec_uint64("throttle-time", "Throttle time", "The time to keep between rendered buffers (0 = disabled)", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_MAX_BITRATE, c.g_param_spec_uint64("max-bitrate", "Max Bitrate", "The maximum bits per second to render (0 = disabled)", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_PROCESSING_DEADLINE, c.g_param_spec_uint64("processing-deadline", "Processing deadline", "Maximum processing time for a buffer in nanoseconds", 0, umax, 20 * 1_000_000, rw));
    c.g_object_class_install_property(gc, PROP_STATS, c.g_param_spec_boxed("stats", "Statistics", "Sink Statistics", c.gst_structure_get_type(), ro));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    ec.send_event = sendEvent;
    ec.query = elementQuery;
    const bc: *Class = @ptrCast(@alignCast(k));
    bc.get_caps = defaultGetCaps;
    bc.set_caps = defaultSetCaps;
    bc.fixate = defaultFixate;
    bc.activate_pull = defaultActivatePull;
    bc.get_times = defaultGetTimes;
    bc.query = defaultQuery;
    bc.event = defaultEvent;
    bc.wait_event = defaultWaitEvent;
}

fn init(instance: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const s: *Sink = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    s.priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
    const p = priv(s);
    const templ = c.gst_element_class_get_pad_template(@ptrCast(@alignCast(g_class)), "sink");
    if (!check.that(templ != null, "gst_base_sink_init", "pad_template != NULL")) return;
    s.sinkpad = c.gst_pad_new_from_template(templ, "sink");
    c.gst_pad_set_activate_function_full(s.sinkpad, padActivate, null, null);
    c.gst_pad_set_activatemode_function_full(s.sinkpad, padActivateMode, null, null);
    c.gst_pad_set_query_function_full(s.sinkpad, padQuery, null, null);
    c.gst_pad_set_event_function_full(s.sinkpad, padEvent, null, null);
    c.gst_pad_set_chain_function_full(s.sinkpad, chain, null, null);
    c.gst_pad_set_chain_list_function_full(s.sinkpad, chainList, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.sinkpad);
    s.pad_mode = c.GST_PAD_MODE_NONE;
    c.g_mutex_init(&s.preroll_lock);
    c.g_cond_init(&s.preroll_cond);
    p.have_latency = false;
    s.can_activate_push = 1;
    s.can_activate_pull = 0;
    s.sync = 1;
    s.max_lateness = -1;
    atomicSet(&p.qos_enabled, false);
    atomicSet(&p.async_enabled, true);
    p.ts_offset = 0;
    p.render_delay = 0;
    p.processing_deadline = 20 * 1_000_000;
    p.blocksize = 4096;
    p.cached_clock_id = null;
    atomicSet(&p.enable_last_sample, true);
    p.throttle_time = 0;
    p.max_bitrate = 0;
    p.drop_out_of_segment = true;
    el.setFlag(s, c.GST_ELEMENT_FLAG_SINK);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = of(o);
    c.g_mutex_clear(&s.preroll_lock);
    c.g_cond_clear(&s.preroll_cond);
    @as(*c.GObjectClass, @ptrCast(parent.?)).finalize.?(o);
}

fn queryCaps(s: *Sink, pad: ?*c.GstPad, filter: [*c]Caps) [*c]Caps {
    var caps: [*c]Caps = null;
    if (el.flags(pad) & c.GST_PAD_FLAG_FIXED_CAPS != 0 or s.pad_mode == c.GST_PAD_MODE_PULL) caps = c.gst_pad_get_current_caps(pad);
    if (caps != null) return caps;
    if (klass(s).get_caps) |f| caps = f(s, filter);
    if (caps != null) return caps;
    const templ = c.gst_element_class_get_pad_template(@ptrCast(klass(s)), "sink");
    if (templ == null) return null;
    caps = c.gst_pad_template_get_caps(templ);
    if (filter != null) {
        const i = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = i;
    }
    return caps;
}

fn defaultFixate(_: [*c]Sink, caps: [*c]Caps) callconv(.c) [*c]Caps {
    return c.gst_caps_fixate(caps);
}

fn fixate(s: *Sink, caps: [*c]Caps) [*c]Caps {
    if (klass(s).fixate) |f| return f(s, caps);
    return caps;
}

fn checked(s: anytype, comptime func: []const u8) bool {
    return check.that(isSink(s), func, "GST_IS_BASE_SINK (sink)");
}

pub export fn gst_base_sink_set_sync(s: [*c]Sink, sync: c.gboolean) void {
    if (!checked(s, "gst_base_sink_set_sync")) return;
    el.lock(s);
    s[0].sync = sync;
    el.unlock(s);
}

pub export fn gst_base_sink_get_sync(s: [*c]Sink) c.gboolean {
    if (!checked(s, "gst_base_sink_get_sync")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return s[0].sync;
}

pub export fn gst_base_sink_set_drop_out_of_segment(s: [*c]Sink, drop: c.gboolean) void {
    if (!checked(s, "gst_base_sink_set_drop_out_of_segment")) return;
    el.lock(s);
    priv(s).drop_out_of_segment = drop != 0;
    el.unlock(s);
}

pub export fn gst_base_sink_get_drop_out_of_segment(s: [*c]Sink) c.gboolean {
    if (!checked(s, "gst_base_sink_get_drop_out_of_segment")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return @intFromBool(priv(s).drop_out_of_segment);
}

pub export fn gst_base_sink_set_max_lateness(s: [*c]Sink, v: c.gint64) void {
    if (!checked(s, "gst_base_sink_set_max_lateness")) return;
    el.lock(s);
    s[0].max_lateness = v;
    el.unlock(s);
}

pub export fn gst_base_sink_get_max_lateness(s: [*c]Sink) c.gint64 {
    if (!checked(s, "gst_base_sink_get_max_lateness")) return -1;
    el.lock(s);
    defer el.unlock(s);
    return s[0].max_lateness;
}

pub export fn gst_base_sink_set_qos_enabled(s: [*c]Sink, v: c.gboolean) void {
    if (!checked(s, "gst_base_sink_set_qos_enabled")) return;
    atomicSet(&priv(s).qos_enabled, v != 0);
}

pub export fn gst_base_sink_is_qos_enabled(s: [*c]Sink) c.gboolean {
    if (!checked(s, "gst_base_sink_is_qos_enabled")) return 0;
    return @intFromBool(atomicGet(&priv(s).qos_enabled));
}

pub export fn gst_base_sink_set_async_enabled(s: [*c]Sink, v: c.gboolean) void {
    if (!checked(s, "gst_base_sink_set_async_enabled")) return;
    prerollLock(of(s));
    atomicSet(&priv(s).async_enabled, v != 0);
    prerollUnlock(of(s));
}

pub export fn gst_base_sink_is_async_enabled(s: [*c]Sink) c.gboolean {
    if (!checked(s, "gst_base_sink_is_async_enabled")) return 0;
    return @intFromBool(atomicGet(&priv(s).async_enabled));
}

pub export fn gst_base_sink_set_ts_offset(s: [*c]Sink, v: c.GstClockTimeDiff) void {
    if (!checked(s, "gst_base_sink_set_ts_offset")) return;
    el.lock(s);
    priv(s).ts_offset = v;
    el.unlock(s);
}

pub export fn gst_base_sink_get_ts_offset(s: [*c]Sink) c.GstClockTimeDiff {
    if (!checked(s, "gst_base_sink_get_ts_offset")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).ts_offset;
}

pub export fn gst_base_sink_get_last_sample(s: [*c]Sink) ?*c.GstSample {
    if (!checked(s, "gst_base_sink_get_last_sample")) return null;
    const p = priv(s);
    el.lock(s);
    defer el.unlock(s);
    if (p.last_buffer_list != null) {
        const first = c.gst_buffer_list_get(p.last_buffer_list, 0);
        const r = c.gst_sample_new(first, p.last_caps, &s[0].segment, null);
        c.gst_sample_set_buffer_list(r, p.last_buffer_list);
        return r;
    }
    if (p.last_buffer != null) return c.gst_sample_new(p.last_buffer, p.last_caps, &s[0].segment, null);
    return null;
}

fn setLastBufferUnlocked(s: *Sink, b: [*c]Buffer) void {
    const p = priv(s);
    const old = p.last_buffer;
    if (old == b) return;
    if (b != null) _ = c.gst_buffer_ref(b);
    p.last_buffer = b;
    _ = c.gst_caps_replace(&p.last_caps, if (b != null) p.caps else null);
    if (old != null) {
        el.unlock(s);
        c.gst_buffer_unref(old);
        el.lock(s);
    }
}

fn setLastListUnlocked(s: *Sink, l: ?*c.GstBufferList) void {
    const p = priv(s);
    const old = p.last_buffer_list;
    if (old == l) return;
    if (l != null) _ = c.gst_mini_object_ref(@ptrCast(@alignCast(l)));
    p.last_buffer_list = l;
    if (old != null) {
        el.unlock(s);
        c.gst_mini_object_unref(@ptrCast(@alignCast(old)));
        el.lock(s);
    }
}

fn setLastBuffer(s: *Sink, b: [*c]Buffer) void {
    if (!atomicGet(&priv(s).enable_last_sample)) return;
    el.lock(s);
    setLastBufferUnlocked(s, b);
    el.unlock(s);
}

fn setLastList(s: *Sink, l: ?*c.GstBufferList) void {
    if (!atomicGet(&priv(s).enable_last_sample)) return;
    el.lock(s);
    setLastListUnlocked(s, l);
    el.unlock(s);
}

pub export fn gst_base_sink_set_last_sample_enabled(s: [*c]Sink, enabled: c.gboolean) void {
    if (!checked(s, "gst_base_sink_set_last_sample_enabled")) return;
    const want: c.gint = @intFromBool(enabled != 0);
    if (@cmpxchgStrong(c.gint, &priv(s).enable_last_sample, 1 - want, want, .seq_cst, .seq_cst) == null and want == 0) {
        el.lock(s);
        setLastBufferUnlocked(of(s), null);
        setLastListUnlocked(of(s), null);
        el.unlock(s);
    }
}

pub export fn gst_base_sink_is_last_sample_enabled(s: [*c]Sink) c.gboolean {
    if (!checked(s, "gst_base_sink_is_last_sample_enabled")) return 0;
    return @intFromBool(atomicGet(&priv(s).enable_last_sample));
}

pub export fn gst_base_sink_get_latency(s: [*c]Sink) c.GstClockTime {
    el.lock(s);
    defer el.unlock(s);
    return priv(s).latency;
}

pub export fn gst_base_sink_query_latency(s: [*c]Sink, live: [*c]c.gboolean, upstream_live: [*c]c.gboolean, min_latency: [*c]c.GstClockTime, max_latency: [*c]c.GstClockTime) c.gboolean {
    const x = of(s);
    const p = priv(x);
    el.lock(x);
    const l = x.sync != 0;
    const have = p.have_latency;
    const delay = p.render_delay;
    const deadline = p.processing_deadline;
    el.unlock(x);
    var min: u64 = 0;
    var max: u64 = NONE;
    var us_live: c.gboolean = 0;
    var us_min: u64 = 0;
    var us_max: u64 = 0;
    var res = false;
    if (have) {
        const q = c.gst_query_new_latency();
        res = c.gst_pad_peer_query(x.sinkpad, q) != 0;
        if (res) {
            c.gst_query_parse_latency(q, &us_live, &us_min, &us_max);
            if (us_live != 0) {
                min = us_min;
                max = us_max;
                if (l) {
                    if (max == NONE or min +% deadline <= max) {
                        min +%= deadline;
                    } else {
                        const dbg = c.g_strdup_printf("Not enough buffering available for  the processing deadline of %" ++ "u:%02u:%02u.%09u" ++ ", add enough queues to buffer  %" ++ "u:%02u:%02u.%09u" ++ " additional data. Shortening processing latency to %" ++ "u:%02u:%02u.%09u" ++ ".", timeArgs(deadline)[0], timeArgs(deadline)[1], timeArgs(deadline)[2], timeArgs(deadline)[3], timeArgs(min +% deadline -% max)[0], timeArgs(min +% deadline -% max)[1], timeArgs(min +% deadline -% max)[2], timeArgs(min +% deadline -% max)[3], timeArgs(max -% min)[0], timeArgs(max -% min)[1], timeArgs(max -% min)[2], timeArgs(max -% min)[3]);
                        el.message(x, c.GST_MESSAGE_WARNING, .core, c.GST_CORE_ERROR_CLOCK, c.g_strdup(c.g_dgettext("gstreamer-1.0", "Pipeline construction is invalid, please add queues.")), dbg, FILE, "gst_base_sink_query_latency", 1248, null);
                        min = max;
                    }
                }
            }
            if (l) {
                min +%= delay;
                if (max != NONE) max +%= delay;
            }
        }
        c.gst_query_unref(q);
    }
    if (!res and !l) res = true;
    if (res) {
        if (live != null) live.* = @intFromBool(l);
        if (upstream_live != null) upstream_live.* = us_live;
        if (min_latency != null) min_latency.* = min;
        if (max_latency != null) max_latency.* = max;
    }
    return @intFromBool(res);
}

fn timeArgs(t: u64) [4]c.guint {
    if (t == NONE) return .{ 99, 99, 99, 999999999 };
    const sec = t / SEC;
    return .{ @intCast(sec / 3600), @intCast(sec / 60 % 60), @intCast(sec % 60), @intCast(t % SEC) };
}

fn postLatency(x: *Sink) void {
    _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_latency(@ptrCast(x)));
}

pub export fn gst_base_sink_set_render_delay(s: [*c]Sink, delay: c.GstClockTime) void {
    if (!checked(s, "gst_base_sink_set_render_delay")) return;
    if (!check.that(valid(delay), "gst_base_sink_set_render_delay", "GST_CLOCK_TIME_IS_VALID (delay)")) return;
    el.lock(s);
    const old = priv(s).render_delay;
    priv(s).render_delay = delay;
    el.unlock(s);
    if (delay != old) postLatency(of(s));
}

pub export fn gst_base_sink_get_render_delay(s: [*c]Sink) c.GstClockTime {
    if (!checked(s, "gst_base_sink_get_render_delay")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).render_delay;
}

pub export fn gst_base_sink_set_blocksize(s: [*c]Sink, v: c.guint) void {
    if (!checked(s, "gst_base_sink_set_blocksize")) return;
    el.lock(s);
    priv(s).blocksize = v;
    el.unlock(s);
}

pub export fn gst_base_sink_get_blocksize(s: [*c]Sink) c.guint {
    if (!checked(s, "gst_base_sink_get_blocksize")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).blocksize;
}

pub export fn gst_base_sink_set_throttle_time(s: [*c]Sink, v: c.guint64) void {
    if (!checked(s, "gst_base_sink_set_throttle_time")) return;
    el.lock(s);
    priv(s).throttle_time = v;
    el.unlock(s);
}

pub export fn gst_base_sink_get_throttle_time(s: [*c]Sink) c.guint64 {
    if (!checked(s, "gst_base_sink_get_throttle_time")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).throttle_time;
}

pub export fn gst_base_sink_set_max_bitrate(s: [*c]Sink, v: c.guint64) void {
    if (!checked(s, "gst_base_sink_set_max_bitrate")) return;
    el.lock(s);
    priv(s).max_bitrate = v;
    el.unlock(s);
}

pub export fn gst_base_sink_get_max_bitrate(s: [*c]Sink) c.guint64 {
    if (!checked(s, "gst_base_sink_get_max_bitrate")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).max_bitrate;
}

pub export fn gst_base_sink_set_processing_deadline(s: [*c]Sink, v: c.GstClockTime) void {
    if (!checked(s, "gst_base_sink_set_processing_deadline")) return;
    el.lock(s);
    const old = priv(s).processing_deadline;
    priv(s).processing_deadline = v;
    el.unlock(s);
    if (v != old) postLatency(of(s));
}

pub export fn gst_base_sink_get_processing_deadline(s: [*c]Sink) c.GstClockTime {
    if (!checked(s, "gst_base_sink_get_processing_deadline")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).processing_deadline;
}

fn setProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    switch (id) {
        PROP_SYNC => gst_base_sink_set_sync(s, c.g_value_get_boolean(v)),
        PROP_MAX_LATENESS => gst_base_sink_set_max_lateness(s, c.g_value_get_int64(v)),
        PROP_QOS => gst_base_sink_set_qos_enabled(s, c.g_value_get_boolean(v)),
        PROP_ASYNC => gst_base_sink_set_async_enabled(s, c.g_value_get_boolean(v)),
        PROP_TS_OFFSET => gst_base_sink_set_ts_offset(s, c.g_value_get_int64(v)),
        PROP_BLOCKSIZE => gst_base_sink_set_blocksize(s, c.g_value_get_uint(v)),
        PROP_RENDER_DELAY => gst_base_sink_set_render_delay(s, c.g_value_get_uint64(v)),
        PROP_ENABLE_LAST_SAMPLE => gst_base_sink_set_last_sample_enabled(s, c.g_value_get_boolean(v)),
        PROP_THROTTLE_TIME => gst_base_sink_set_throttle_time(s, c.g_value_get_uint64(v)),
        PROP_MAX_BITRATE => gst_base_sink_set_max_bitrate(s, c.g_value_get_uint64(v)),
        PROP_PROCESSING_DEADLINE => gst_base_sink_set_processing_deadline(s, c.g_value_get_uint64(v)),
        else => el.badProperty(o, id, pspec, FILE, 1601),
    }
}

fn getProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    switch (id) {
        PROP_SYNC => c.g_value_set_boolean(v, gst_base_sink_get_sync(s)),
        PROP_MAX_LATENESS => c.g_value_set_int64(v, gst_base_sink_get_max_lateness(s)),
        PROP_QOS => c.g_value_set_boolean(v, gst_base_sink_is_qos_enabled(s)),
        PROP_ASYNC => c.g_value_set_boolean(v, gst_base_sink_is_async_enabled(s)),
        PROP_TS_OFFSET => c.g_value_set_int64(v, gst_base_sink_get_ts_offset(s)),
        PROP_LAST_SAMPLE => c.g_value_take_boxed(v, gst_base_sink_get_last_sample(s)),
        PROP_ENABLE_LAST_SAMPLE => c.g_value_set_boolean(v, gst_base_sink_is_last_sample_enabled(s)),
        PROP_BLOCKSIZE => c.g_value_set_uint(v, gst_base_sink_get_blocksize(s)),
        PROP_RENDER_DELAY => c.g_value_set_uint64(v, gst_base_sink_get_render_delay(s)),
        PROP_THROTTLE_TIME => c.g_value_set_uint64(v, gst_base_sink_get_throttle_time(s)),
        PROP_MAX_BITRATE => c.g_value_set_uint64(v, gst_base_sink_get_max_bitrate(s)),
        PROP_PROCESSING_DEADLINE => c.g_value_set_uint64(v, gst_base_sink_get_processing_deadline(s)),
        PROP_STATS => c.g_value_take_boxed(v, gst_base_sink_get_stats(s)),
        else => el.badProperty(o, id, pspec, FILE, 1653),
    }
}

fn defaultGetCaps(_: [*c]Sink, _: [*c]Caps) callconv(.c) [*c]Caps {
    return null;
}

fn defaultSetCaps(_: [*c]Sink, _: [*c]Caps) callconv(.c) c.gboolean {
    return 1;
}

fn commitState(x: *Sink) bool {
    const p = priv(x);
    x.playing_async = 0;
    el.lock(x);
    const e = &x.element;
    const current = e.current_state;
    const next = e.next_state;
    const pending = e.pending_state;
    var post_pending = pending;
    var post_paused = false;
    var post_async_done = false;
    var post_playing = false;
    switch (pending) {
        c.GST_STATE_PLAYING => {
            x.need_preroll = 0;
            post_async_done = true;
            p.committed = true;
            post_playing = true;
            if (current == c.GST_STATE_READY) post_paused = true;
        },
        c.GST_STATE_PAUSED => {
            post_paused = true;
            post_async_done = true;
            p.committed = true;
            post_pending = c.GST_STATE_VOID_PENDING;
        },
        c.GST_STATE_READY, c.GST_STATE_NULL => {
            x.need_preroll = 0;
            x.flushing = 1;
            el.unlock(x);
            return false;
        },
        c.GST_STATE_VOID_PENDING => {
            switch (current) {
                c.GST_STATE_PLAYING => x.need_preroll = 0,
                c.GST_STATE_PAUSED => x.need_preroll = 1,
                else => {
                    x.need_preroll = 0;
                    x.flushing = 1;
                },
            }
            p.have_latency = true;
            el.unlock(x);
            postLatency(x);
            return true;
        },
        else => {},
    }
    p.have_latency = true;
    e.current_state = pending;
    e.next_state = c.GST_STATE_VOID_PENDING;
    e.pending_state = c.GST_STATE_VOID_PENDING;
    e.last_return = c.GST_STATE_CHANGE_SUCCESS;
    el.unlock(x);
    if (post_paused) _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_state_changed(@ptrCast(x), current, next, post_pending));
    if (post_async_done) _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_async_done(@ptrCast(x), NONE));
    if (post_playing) {
        if (post_paused) {
            const ek = el.classOf(c.GstElementClass, x);
            x.have_preroll = 1;
            prerollUnlock(x);
            if (ek.change_state) |f| _ = f(@ptrCast(x), c.GST_STATE_CHANGE_PAUSED_TO_PLAYING);
            prerollLock(x);
            if (x.flushing != 0) {
                el.lock(x);
                x.need_preroll = 0;
                x.flushing = 1;
                el.unlock(x);
                return false;
            }
        }
        _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_state_changed(@ptrCast(x), next, pending, c.GST_STATE_VOID_PENDING));
    }
    postLatency(x);
    c.g_cond_broadcast(&e.state_cond);
    return true;
}

fn startStepping(x: *Sink, segment: *c.GstSegment, pending: *Step, current: *Step) void {
    el.lock(x);
    current.* = pending.*;
    pending.valid = false;
    el.unlock(x);
    const m = c.gst_message_new_step_start(@ptrCast(x), 1, current.format, current.amount, current.rate, @intFromBool(current.flush), @intFromBool(current.intermediate));
    c.gst_message_set_seqnum(m, current.seqnum);
    _ = c.gst_element_post_message(@ptrCast(x), m);
    current.start = c.gst_element_get_start_time(@ptrCast(x));
    _ = c.gst_segment_set_running_time(segment, c.GST_FORMAT_TIME, current.start);
    current.start_rate = segment.rate;
    segment.rate *= current.rate;
    if (segment.rate > 0.0) current.start_stop = segment.stop else current.start_start = segment.start;
    if (current.format == c.GST_FORMAT_TIME) {
        const end: u64 = if (current.amount != NONE) current.start +% current.amount else NONE;
        if (!current.flush) {
            if (segment.rate > 0.0) {
                const pos = if (end != NONE) c.gst_segment_position_from_running_time(segment, c.GST_FORMAT_TIME, end) else segment.stop;
                segment.stop = pos;
                segment.position = pos;
            } else {
                const pos = if (end != NONE) c.gst_segment_position_from_running_time(segment, c.GST_FORMAT_TIME, end) else segment.start;
                segment.time = pos;
                segment.start = pos;
                segment.position = pos;
            }
        }
    }
}

fn stopStepping(x: *Sink, segment: *c.GstSegment, current: *Step, rstart: u64, rstop: u64, eos: bool) void {
    const stop = if (segment.rate > 0.0) rstart else rstop;
    current.duration = if (stop == NONE) current.position else stop -% current.start;
    const position = current.start +% current.duration;
    _ = c.gst_segment_set_running_time(segment, c.GST_FORMAT_TIME, position);
    if (current.flush) segment.base = current.start else c.gst_element_set_start_time(@ptrCast(x), position);
    segment.rate = current.start_rate;
    if (segment.rate > 0.0) segment.stop = current.start_stop else segment.start = current.start_start;
    const m = c.gst_message_new_step_done(@ptrCast(x), current.format, current.amount, current.rate, @intFromBool(current.flush), @intFromBool(current.intermediate), current.duration, @intFromBool(eos));
    c.gst_message_set_seqnum(m, current.seqnum);
    _ = c.gst_element_post_message(@ptrCast(x), m);
    if (!current.intermediate) x.need_preroll = @intFromBool(current.need_preroll);
    current.valid = false;
}

fn handleStepping(segment: *c.GstSegment, current: *Step, cstart: *u64, cstop: *u64, rstart: *u64, rstop: *u64) bool {
    if (current.amount == NONE) return false;
    switch (current.format) {
        c.GST_FORMAT_TIME => {
            var first: u64 = undefined;
            var last: u64 = undefined;
            if (segment.rate > 0.0) {
                if (segment.stop == cstop.*) rstop.* = rstart.* +% current.amount;
                first = rstart.*;
                last = rstop.*;
            } else {
                if (segment.start == cstart.*) rstart.* = rstop.* +% current.amount;
                first = rstop.*;
                last = rstart.*;
            }
            const end = current.start +% current.amount;
            current.position = first -% current.start;
            const abs_rate = @abs(segment.rate);
            if (abs_rate != 1.0) current.position = @intFromFloat(@as(f64, @floatFromInt(current.position)) / abs_rate);
            if ((current.flush and current.position >= current.amount) or last >= end) {
                if (segment.rate > 0.0) {
                    rstart.* = end;
                    cstart.* = c.gst_segment_position_from_running_time(segment, c.GST_FORMAT_TIME, end);
                } else {
                    rstop.* = end;
                    cstop.* = c.gst_segment_position_from_running_time(segment, c.GST_FORMAT_TIME, end);
                }
                return true;
            }
            return false;
        },
        c.GST_FORMAT_BUFFERS => {
            if (current.position < current.amount) {
                current.position += 1;
                return false;
            }
            return true;
        },
        else => return false,
    }
}

const SyncTimes = struct {
    sstart: u64 = NONE,
    sstop: u64 = NONE,
    rstart: u64 = NONE,
    rstop: u64 = NONE,
    rnext: u64 = NONE,
};

fn getSyncTimes(x: *Sink, obj: *Mini, out: *SyncTimes, do_sync: *bool, stepped: *bool, step: *Step, step_end: *bool) bool {
    const p = priv(x);
    const segment = &x.segment;
    const k = klass(x);
    while (true) {
        var start: u64 = NONE;
        var stop: u64 = NONE;
        var eos = false;
        var cstart: u64 = NONE;
        var cstop: u64 = NONE;
        var rstart: u64 = NONE;
        var rstop: u64 = NONE;
        var rnext: u64 = NONE;
        var sstart: u64 = NONE;
        var sstop: u64 = NONE;
        computed: {
            if (isEvent(obj)) {
                const ev: [*c]Event = @ptrCast(@alignCast(obj));
                switch (ev[0].type) {
                    c.GST_EVENT_EOS => {
                        if (segment.rate >= 0.0) {
                            sstart = p.current_sstop;
                            if (!valid(sstart)) sstart = c.gst_segment_to_stream_time(segment, segment.format, segment.stop);
                        } else {
                            sstart = p.current_sstart;
                            if (!valid(sstart)) sstart = c.gst_segment_to_stream_time(segment, segment.format, segment.start);
                        }
                        sstop = sstart;
                        rstart = p.eos_rtime;
                        rstop = rstart;
                        rnext = rstart;
                        do_sync.* = valid(rstart);
                        step_end.* = step.valid;
                        eos = true;
                        break :computed;
                    },
                    c.GST_EVENT_GAP => {
                        var ts: u64 = 0;
                        var dur: u64 = 0;
                        c.gst_event_parse_gap(ev, &ts, &dur);
                        if (valid(ts)) {
                            start = ts;
                            if (valid(dur)) stop = start +% dur;
                        }
                        do_sync.* = true;
                    },
                    else => return false,
                }
            } else {
                const buf: [*c]Buffer = @ptrCast(@alignCast(obj));
                if (k.get_times) |f| f(x, buf, &start, &stop);
                if (!valid(start)) {
                    defaultGetTimes(x, buf, &start, &stop);
                    do_sync.* = false;
                } else do_sync.* = true;
            }
            const format = segment.format;
            var skip_clip = false;
            if (c.gst_segment_clip(segment, format, start, stop, &cstart, &cstop) == 0) {
                if (step.valid) {
                    if (segment.rate > 0.0) {
                        cstart = segment.stop;
                        cstop = segment.stop;
                    } else {
                        cstart = segment.start;
                        cstop = segment.start;
                    }
                    skip_clip = true;
                } else {
                    if (p.drop_out_of_segment) return false;
                    cstart = start;
                    cstop = stop;
                }
            }
            if (!skip_clip) {
                if (stop != NONE and cstop != NONE) segment.position = cstop else segment.position = cstart;
            }
            rstart = c.gst_segment_to_running_time(segment, format, cstart);
            rstop = c.gst_segment_to_running_time(segment, format, cstop);
            if (segment.rate < 0.0 and valid(rstop) and !step.valid) std.mem.swap(u64, &rstart, &rstop);
            rnext = if (valid(stop)) rstop else rstart;
            if (step.valid) {
                step_end.* = handleStepping(segment, step, &cstart, &cstop, &rstart, &rstop);
                if (!step_end.*) stepped.* = step.flush;
            }
            sstart = c.gst_segment_to_stream_time(segment, format, cstart);
            sstop = c.gst_segment_to_stream_time(segment, format, cstop);
        }
        if (step_end.* and step.flush) {
            stopStepping(x, segment, step, rstart, rstop, eos);
            step_end.* = false;
            if (!isEvent(obj)) continue;
        }
        out.* = .{ .sstart = sstart, .sstop = sstop, .rstart = rstart, .rstop = rstop, .rnext = rnext };
        return true;
    }
}

fn adjustTime(x: *Sink, time_in: u64) u64 {
    if (!valid(time_in)) return time_in;
    const p = priv(x);
    var time = time_in +% p.latency;
    var off = p.ts_offset;
    if (off < 0) {
        off = -off;
        const u: u64 = @bitCast(off);
        time = if (u < time) time - u else 0;
    } else time +%= @bitCast(off);
    return if (time > p.render_delay) time - p.render_delay else 0;
}

pub export fn gst_base_sink_wait_clock(s: [*c]Sink, time_in: c.GstClockTime, jitter: [*c]c.GstClockTimeDiff) c.GstClockReturn {
    const x = of(s);
    const p = priv(x);
    if (!valid(time_in)) return c.GST_CLOCK_BADTIME;
    el.lock(x);
    if (x.sync == 0) {
        el.unlock(x);
        return c.GST_CLOCK_BADTIME;
    }
    const clock = x.element.clock;
    if (clock == null) {
        el.unlock(x);
        return c.GST_CLOCK_BADTIME;
    }
    const time = time_in +% @as(u64, @bitCast(x.element.base_time));
    if (p.cached_clock_id != null and c.gst_clock_id_uses_clock(p.cached_clock_id, clock) != 0) {
        if (c.gst_clock_single_shot_id_reinit(clock, p.cached_clock_id, time) == 0) {
            c.gst_clock_id_unref(p.cached_clock_id);
            p.cached_clock_id = c.gst_clock_new_single_shot_id(clock, time);
        }
    } else {
        if (p.cached_clock_id != null) c.gst_clock_id_unref(p.cached_clock_id);
        p.cached_clock_id = c.gst_clock_new_single_shot_id(clock, time);
    }
    el.unlock(x);
    x.clock_id = p.cached_clock_id;
    prerollUnlock(x);
    const r = c.gst_clock_id_wait(p.cached_clock_id, jitter);
    prerollLock(x);
    x.clock_id = null;
    return r;
}

pub export fn gst_base_sink_wait_preroll(s: [*c]Sink) c.GstFlowReturn {
    const x = of(s);
    x.have_preroll = 1;
    c.g_cond_wait(&x.preroll_cond, &x.preroll_lock);
    x.have_preroll = 0;
    if (x.flushing != 0) return c.GST_FLOW_FLUSHING;
    if (priv(x).step_unlock) {
        priv(x).step_unlock = false;
        return FLOW_STEP;
    }
    return c.GST_FLOW_OK;
}

pub export fn gst_base_sink_do_preroll(s: [*c]Sink, obj: [*c]Mini) c.GstFlowReturn {
    const x = of(s);
    const p = priv(x);
    while (x.need_preroll != 0) {
        if (p.call_preroll) {
            var buf: [*c]Buffer = null;
            if (isList(obj)) {
                buf = c.gst_buffer_list_get(@ptrCast(obj), 0);
                setLastBuffer(x, buf);
                setLastList(x, @ptrCast(obj));
            } else if (isBuffer(obj)) {
                buf = @ptrCast(@alignCast(obj));
                setLastBuffer(x, buf);
                setLastList(x, null);
            }
            if (buf != null) {
                const k = klass(x);
                if (k.prepare) |f| {
                    const r = f(x, buf);
                    if (r != c.GST_FLOW_OK) {
                        c.gst_element_abort_state(@ptrCast(x));
                        return r;
                    }
                }
                if (k.preroll) |f| {
                    const r = f(x, buf);
                    if (r != c.GST_FLOW_OK) {
                        c.gst_element_abort_state(@ptrCast(x));
                        return r;
                    }
                }
                p.call_preroll = false;
            }
        }
        if (x.playing_async != 0) {
            if (!commitState(x)) return c.GST_FLOW_FLUSHING;
        }
        if (x.need_preroll != 0) {
            const r = gst_base_sink_wait_preroll(x);
            if (r != c.GST_FLOW_OK and r != FLOW_STEP) return r;
        }
    }
    return c.GST_FLOW_OK;
}

pub export fn gst_base_sink_wait(s: [*c]Sink, time: c.GstClockTime, jitter: [*c]c.GstClockTimeDiff) c.GstFlowReturn {
    const x = of(s);
    while (true) {
        while (x.need_preroll != 0) {
            const r = gst_base_sink_wait_preroll(x);
            if (r != c.GST_FLOW_OK and r != FLOW_STEP) return c.GST_FLOW_FLUSHING;
        }
        const status = gst_base_sink_wait_clock(x, adjustTime(x, time), jitter);
        if (status == c.GST_CLOCK_BADTIME) break;
        if (x.flushing != 0) return c.GST_FLOW_FLUSHING;
        if (status != c.GST_CLOCK_UNSCHEDULED) break;
    }
    return c.GST_FLOW_OK;
}

fn runAvg(avg: u64, v: u64, size: u64) u64 {
    return (v +% (size - 1) *% avg) / size;
}

fn doSync(x: *Sink, obj: *Mini, late: *bool, step_end: *bool) c.GstFlowReturn {
    const p = priv(x);
    var rate_seqnum = p.instant_rate_sync_seqnum;
    var jitter: c.GstClockTimeDiff = 0;
    step: while (true) {
        var times = SyncTimes{};
        var do_sync = true;
        var stepped = false;
        p.current_rstart = NONE;
        const current = &p.current_step;
        const pending = &p.pending_step;
        const syncable = getSyncTimes(x, obj, &times, &do_sync, &stepped, current, step_end);
        if (stepped) {
            late.* = true;
            return c.GST_FLOW_OK;
        }
        if (!syncable) return c.GST_FLOW_OK;
        p.current_rstart = times.rstart;
        p.current_rstop = if (valid(times.rstop)) times.rstop else times.rstart;
        p.eos_rtime = if (do_sync) times.rnext else NONE;
        if (valid(p.prev_rstart) and p.prev_rstart < times.rstart) {
            const in_diff = times.rstart - p.prev_rstart;
            p.avg_in_diff = if (p.avg_in_diff == NONE) in_diff else runAvg(p.avg_in_diff, in_diff, 8);
        }
        p.prev_rstart = times.rstart;
        if (valid(p.earliest_in_time) and times.rstart < p.earliest_in_time) {
            late.* = true;
            return c.GST_FLOW_OK;
        }
        while (true) {
            const ret = gst_base_sink_do_preroll(x, obj);
            if (ret != c.GST_FLOW_OK) {
                step_end.* = false;
                return ret;
            }
            if (pending.valid and !current.valid) {
                startStepping(x, &x.segment, pending, current);
                continue :step;
            }
            if (p.instant_rate_sync_seqnum != rate_seqnum) {
                rate_seqnum = p.instant_rate_sync_seqnum;
                continue :step;
            }
            el.lock(x);
            p.current_sstart = times.sstart;
            p.current_sstop = if (valid(times.sstop)) times.sstop else times.sstart;
            el.unlock(x);
            if (!do_sync) return c.GST_FLOW_OK;
            var stime = adjustTime(x, times.rstart);
            if (p.rc_next == NONE or (stime != NONE and stime >= p.rc_next)) {
                p.rc_time = stime;
                p.rc_accumulated = 0;
            } else stime = p.rc_next;
            const status = gst_base_sink_wait_clock(x, stime, &jitter);
            if (status == c.GST_CLOCK_BADTIME) return c.GST_FLOW_OK;
            if (x.flushing != 0) return c.GST_FLOW_FLUSHING;
            if (status == c.GST_CLOCK_UNSCHEDULED) {
                if (p.instant_rate_sync_seqnum != rate_seqnum) {
                    rate_seqnum = p.instant_rate_sync_seqnum;
                    continue :step;
                }
                p.call_preroll = true;
                continue;
            }
            p.current_jitter = jitter;
            late.* = isTooLate(x, obj, times.rstart, times.rstop, status, jitter, true);
            return c.GST_FLOW_OK;
        }
    }
}

fn sendQos(x: *Sink, kind: c.GstQOSType, proportion: f64, time_in: u64, diff: c.GstClockTimeDiff) bool {
    const p = priv(x);
    var time = time_in;
    if (p.instant_rate_sync_seqnum != 0) {
        var actual: u64 = undefined;
        var negative = false;
        if (time < p.last_anchor_running_time) {
            actual = p.last_anchor_running_time - time;
            negative = true;
        } else actual = time - p.last_anchor_running_time;
        const upstream: u64 = @intFromFloat(@as(f64, @floatFromInt(actual)) * x.segment.rate / p.upstream_segment.rate);
        var difference: c.GstClockTimeDiff = if (negative) @as(i64, @bitCast(upstream)) -% @as(i64, @bitCast(actual)) else @as(i64, @bitCast(actual)) -% @as(i64, @bitCast(upstream));
        difference = p.instant_rate_offset +% difference;
        if (difference > 0 and time < @as(u64, @bitCast(difference))) time = 0 else time -%= @bitCast(difference);
    }
    return c.gst_pad_push_event(x.sinkpad, c.gst_event_new_qos(kind, proportion, diff, time)) != 0;
}

fn performQos(x: *Sink, dropped: bool) void {
    const p = priv(x);
    const start = p.current_rstart;
    if (p.current_step.valid) return;
    if (!atomicGet(&p.qos_enabled) or !valid(start)) return;
    const jitter = p.current_jitter;
    var entered: u64 = undefined;
    var left: u64 = undefined;
    if (jitter < 0) {
        const nj: u64 = @bitCast(-jitter);
        entered = if (start < nj) 0 else start - nj;
        left = start;
    } else {
        entered = start +% @as(u64, @bitCast(jitter));
        left = entered;
    }
    const duration = p.avg_in_diff;
    var pt: u64 = undefined;
    if (valid(p.last_left)) {
        pt = if (entered > p.last_left) entered - p.last_left else 0;
    } else pt = p.avg_pt;
    p.avg_pt = if (!valid(p.avg_pt)) pt else runAvg(p.avg_pt, pt, 8);
    const rate: f64 = if (duration != NONE and duration != 0) @as(f64, @floatFromInt(p.avg_pt)) / @as(f64, @floatFromInt(duration)) else 1.0;
    if (valid(p.last_left)) {
        if (dropped or p.avg_rate < 0.0) {
            p.avg_rate = rate;
        } else if (rate > 1.0) {
            p.avg_rate = (rate + 3.0 * p.avg_rate) / 4.0;
        } else {
            p.avg_rate = (rate + 15.0 * p.avg_rate) / 16.0;
        }
    }
    if (p.avg_rate >= 0.0) {
        if (p.current_jitter < 0 and p.current_rstart < @as(u64, @bitCast(-p.current_jitter))) p.current_jitter = -@as(i64, @bitCast(p.current_rstart));
        var kind: c.GstQOSType = undefined;
        var diff: c.GstClockTimeDiff = undefined;
        if (p.throttle_time > 0) {
            diff = @bitCast(p.throttle_time);
            kind = c.GST_QOS_TYPE_THROTTLE;
        } else {
            diff = p.current_jitter;
            kind = if (diff <= 0) c.GST_QOS_TYPE_OVERFLOW else c.GST_QOS_TYPE_UNDERFLOW;
        }
        _ = sendQos(x, kind, p.avg_rate, p.current_rstart, diff);
    }
    p.last_left = left;
}

fn resetQos(x: *Sink) void {
    const p = priv(x);
    p.last_render_time = NONE;
    p.prev_rstart = NONE;
    p.earliest_in_time = NONE;
    p.last_left = NONE;
    p.avg_pt = NONE;
    p.avg_rate = -1.0;
    p.avg_in_diff = NONE;
    p.rendered = 0;
    p.dropped = 0;
}

fn isTooLate(x: *Sink, obj: *Mini, rstart: u64, rstop: u64, status: c.GstClockReturn, jitter: c.GstClockTimeDiff, render: bool) bool {
    const p = priv(x);
    var late = false;
    if (status == c.GST_CLOCK_EARLY) {
        var max: u64 = @bitCast(x.max_lateness);
        if (max != NONE) {
            if (!isBuffer(obj) or !valid(rstart)) return false;
            if (valid(rstop)) {
                max +%= rstop;
            } else {
                max +%= rstart;
                if (p.avg_in_diff != NONE) max +%= p.avg_in_diff;
            }
            late = rstart +% @as(u64, @bitCast(jitter)) > max;
            if (late and valid(p.last_render_time) and rstart -% p.last_render_time > SEC) {
                late = false;
                el.message(x, c.GST_MESSAGE_WARNING, .core, c.GST_CORE_ERROR_CLOCK, c.g_strdup(c.g_dgettext("gstreamer-1.0", "A lot of buffers are being dropped.")), c.g_strdup("There may be a timestamping problem, or this computer is too slow."), FILE, "gst_base_sink_is_too_late", 3146, null);
            }
        }
    }
    if (render and (!late or !valid(p.last_render_time))) {
        p.last_render_time = rstart;
        if (p.throttle_time > 0) p.earliest_in_time = rstart +% p.throttle_time;
    }
    return late;
}

fn updateStartTime(x: *Sink) void {
    el.lock(x);
    defer el.unlock(x);
    const clock = x.element.clock;
    if (x.element.current_state != c.GST_STATE_PLAYING or clock == null) return;
    _ = c.gst_object_ref(clock);
    el.unlock(x);
    const now = c.gst_clock_get_time(clock);
    c.gst_object_unref(clock);
    el.lock(x);
    if (x.element.start_time != NONE and now != NONE) x.element.start_time = now -% @as(u64, @bitCast(x.element.base_time));
}

fn flushStart(x: *Sink, pad: ?*c.GstPad) void {
    _ = setFlushing(x, true);
    el.streamLock(pad);
    resetQos(x);
    x.playing_async = 1;
    if (atomicGet(&priv(x).async_enabled)) {
        updateStartTime(x);
        c.gst_element_lost_state(@ptrCast(x));
    } else {
        c.gst_element_set_start_time(@ptrCast(x), 0);
        priv(x).have_latency = true;
    }
    setLastBuffer(x, null);
    setLastList(x, null);
    el.streamUnlock(pad);
}

fn flushStop(x: *Sink, _: ?*c.GstPad, reset: bool) void {
    const p = priv(x);
    _ = setFlushing(x, false);
    el.lock(x);
    p.current_sstart = NONE;
    p.current_sstop = NONE;
    p.eos_rtime = NONE;
    p.call_preroll = true;
    p.current_step.valid = false;
    p.pending_step.valid = false;
    if (x.pad_mode == c.GST_PAD_MODE_PUSH) {
        x.have_newsegment = 0;
        if (reset) {
            c.gst_segment_init(&p.upstream_segment, c.GST_FORMAT_UNDEFINED);
            c.gst_segment_init(&x.segment, c.GST_FORMAT_UNDEFINED);
            x.element.start_time = 0;
            p.last_instant_rate_seqnum = 0;
            p.instant_rate_sync_seqnum = 0;
            p.instant_rate_multiplier = 0;
            p.instant_rate_offset = 0;
            p.last_anchor_running_time = 0;
        }
    }
    el.unlock(x);
    if (reset) _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_reset_time(@ptrCast(x), 0));
}

fn defaultWaitEvent(s: [*c]Sink, ev: [*c]Event) callconv(.c) c.GstFlowReturn {
    var late = false;
    var step_end = false;
    return doSync(of(s), @ptrCast(@alignCast(ev)), &late, &step_end);
}

fn waitEvent(x: *Sink, ev: [*c]Event) c.GstFlowReturn {
    if (klass(x).wait_event) |f| return f(x, ev);
    return c.GST_FLOW_NOT_SUPPORTED;
}

fn segmentEvent(x: *Sink, ev: [*c]Event) void {
    const p = priv(x);
    el.lock(x);
    defer el.unlock(x);
    var seg: c.GstSegment = undefined;
    c.gst_event_copy_segment(ev, &seg);
    if (seg.position > seg.stop) {
        seg.position = seg.stop;
    } else if (seg.position < seg.start) {
        seg.position = seg.start;
    }
    if (p.instant_rate_sync_seqnum != 0) {
        const rt = c.gst_segment_to_running_time(&seg, c.GST_FORMAT_TIME, seg.position);
        const anchor = p.last_anchor_running_time -% @as(u64, @bitCast(p.instant_rate_offset));
        var upstream: u64 = undefined;
        var negative = false;
        if (rt < anchor) {
            upstream = anchor - rt;
            negative = true;
        } else upstream = rt - anchor;
        const actual: u64 = @intFromFloat(@as(f64, @floatFromInt(upstream)) * p.instant_rate_multiplier);
        const difference: c.GstClockTimeDiff = if (negative) @as(i64, @bitCast(upstream)) -% @as(i64, @bitCast(actual)) else @as(i64, @bitCast(actual)) -% @as(i64, @bitCast(upstream));
        p.instant_rate_offset +%= difference;
        if (p.instant_rate_offset < 0 and rt < @as(u64, @bitCast(-p.instant_rate_offset))) {
            p.last_anchor_running_time = 0;
            p.instant_rate_offset = 0;
        } else p.last_anchor_running_time = rt +% @as(u64, @bitCast(p.instant_rate_offset));
        p.upstream_segment = seg;
        x.segment = seg;
        x.segment.rate *= p.instant_rate_multiplier;
        _ = c.gst_segment_offset_running_time(&x.segment, c.GST_FORMAT_TIME, p.instant_rate_offset);
    } else {
        p.upstream_segment = seg;
        x.segment = seg;
        p.last_anchor_running_time = c.gst_segment_to_running_time(&seg, seg.format, seg.position);
        p.instant_rate_offset = 0;
    }
    x.have_newsegment = 1;
    resetQos(x);
}

fn defaultEvent(s: [*c]Sink, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(s);
    const p = priv(x);
    var result: c.gboolean = 1;
    defer c.gst_event_unref(ev);
    switch (ev[0].type) {
        c.GST_EVENT_FLUSH_START => flushStart(x, x.sinkpad),
        c.GST_EVENT_FLUSH_STOP => {
            var reset: c.gboolean = 0;
            c.gst_event_parse_flush_stop(ev, &reset);
            flushStop(x, x.sinkpad, reset != 0);
        },
        c.GST_EVENT_EOS => {
            p.received_eos = true;
            if (waitEvent(x, ev) != c.GST_FLOW_OK) return 0;
            el.lock(x);
            x.eos = 1;
            el.unlock(x);
            p.seqnum = c.gst_event_get_seqnum(ev);
            const m = c.gst_message_new_eos(@ptrCast(x));
            c.gst_message_set_seqnum(m, p.seqnum);
            _ = c.gst_element_post_message(@ptrCast(x), m);
        },
        c.GST_EVENT_STREAM_START => {
            const seqnum = c.gst_event_get_seqnum(ev);
            const m = c.gst_message_new_stream_start(@ptrCast(x));
            var gid: c.guint = 0;
            if (c.gst_event_parse_group_id(ev, &gid) != 0) c.gst_message_set_group_id(m, gid);
            c.gst_message_set_seqnum(m, seqnum);
            _ = c.gst_element_post_message(@ptrCast(x), m);
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]Caps = null;
            c.gst_event_parse_caps(ev, &caps);
            const current = c.gst_pad_get_current_caps(x.sinkpad);
            if (current == null or c.gst_caps_is_equal(current, caps) == 0) {
                if (klass(x).set_caps) |f| result = f(x, caps);
                if (result != 0) {
                    el.lock(x);
                    _ = c.gst_caps_replace(&p.caps, caps);
                    el.unlock(x);
                }
            }
            if (current != null) c.gst_caps_unref(current);
        },
        c.GST_EVENT_SEGMENT => segmentEvent(x, ev),
        c.GST_EVENT_GAP => {
            if (waitEvent(x, ev) != c.GST_FLOW_OK) result = 0;
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(ev, &tags);
            _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_tag(@ptrCast(x), c.gst_tag_list_copy(tags)));
        },
        c.GST_EVENT_TOC => {
            var toc: ?*c.GstToc = null;
            var updated: c.gboolean = 0;
            c.gst_event_parse_toc(ev, &toc, &updated);
            _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_toc(@ptrCast(x), toc, updated));
            c.gst_mini_object_unref(@ptrCast(@alignCast(toc)));
        },
        c.GST_EVENT_SINK_MESSAGE => {
            var msg: [*c]c.GstMessage = null;
            c.gst_event_parse_sink_message(ev, &msg);
            if (msg != null) _ = c.gst_element_post_message(@ptrCast(x), msg);
        },
        c.GST_EVENT_INSTANT_RATE_CHANGE => {
            const seqnum = c.gst_event_get_seqnum(ev);
            el.lock(x);
            if (p.last_instant_rate_seqnum == seqnum or p.instant_rate_sync_seqnum == seqnum) {
                el.unlock(x);
                return result;
            }
            p.last_instant_rate_seqnum = seqnum;
            el.unlock(x);
            var mult: f64 = 0;
            c.gst_event_parse_instant_rate_change(ev, &mult, null);
            const m = c.gst_message_new_instant_rate_request(@ptrCast(x), mult);
            c.gst_message_set_seqnum(m, seqnum);
            _ = c.gst_element_post_message(@ptrCast(x), m);
        },
        else => {},
    }
    return result;
}

fn padEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    const k = klass(x);
    const t = ev[0].type;
    if (t == c.GST_EVENT_FLUSH_STOP) {
        if (k.event) |f| return f(x, ev);
        return 1;
    }
    if (t == c.GST_EVENT_STREAM_START) priv(x).received_eos = false;
    if (t & c.GST_EVENT_TYPE_SERIALIZED != 0) {
        prerollLock(x);
        if (x.flushing != 0 or priv(x).received_eos) {
            prerollUnlock(x);
            c.gst_event_unref(ev);
            return 0;
        }
        var result: c.gboolean = 1;
        if (k.event) |f| result = f(x, ev);
        prerollUnlock(x);
        return result;
    }
    if (k.event) |f| return f(x, ev);
    return 1;
}

fn defaultGetTimes(_: [*c]Sink, b: [*c]Buffer, start: [*c]c.GstClockTime, end: [*c]c.GstClockTime) callconv(.c) void {
    var ts = b[0].dts;
    if (!valid(ts)) ts = b[0].pts;
    if (!valid(ts)) return;
    const dur = b[0].duration;
    if (valid(dur)) end.* = ts +% dur;
    start.* = ts;
}

fn needsPreroll(x: *Sink) bool {
    return !(x.have_preroll != 0 or priv(x).received_eos);
}

fn chainUnlocked(x: *Sink, pad: ?*c.GstPad, obj: *Mini, list: bool) c.GstFlowReturn {
    _ = pad;
    const p = priv(x);
    if (x.flushing != 0) {
        c.gst_mini_object_unref(obj);
        return c.GST_FLOW_FLUSHING;
    }
    if (p.received_eos) {
        c.gst_mini_object_unref(obj);
        return c.GST_FLOW_EOS;
    }
    var sync_buf: [*c]Buffer = undefined;
    if (list) {
        const bl: ?*c.GstBufferList = @ptrCast(obj);
        if (c.gst_buffer_list_length(bl) == 0) {
            c.gst_mini_object_unref(obj);
            return c.GST_FLOW_OK;
        }
        sync_buf = c.gst_buffer_list_get(bl, 0);
    } else sync_buf = @ptrCast(@alignCast(obj));
    const segment = &x.segment;
    if (x.have_newsegment == 0) {
        if (gst_base_sink_get_sync(x) != 0) {
            el.message(x, c.GST_MESSAGE_WARNING, .stream, c.GST_STREAM_ERROR_FAILED, c.g_strdup(c.g_dgettext("gstreamer-1.0", "Internal data flow problem.")), c.g_strdup("Received buffer without a new-segment. Assuming timestamps start from 0."), FILE, "gst_base_sink_chain_unlocked", 3802, null);
        }
        el.lock(x);
        segment.start = 0;
        segment.stop = NONE;
        x.have_newsegment = 1;
        el.unlock(x);
    }
    const k = klass(x);
    var start: u64 = NONE;
    var end: u64 = NONE;
    if (k.get_times) |f| f(x, sync_buf, &start, &end);
    if (!valid(start)) defaultGetTimes(x, sync_buf, &start, &end);
    if (valid(start) and segment.format == c.GST_FORMAT_TIME) {
        var pts = sync_buf[0].pts;
        if (!valid(pts)) pts = start;
        const pts_end: u64 = if (valid(end)) pts +% (end -% start) else NONE;
        if (c.gst_segment_clip(segment, c.GST_FORMAT_TIME, pts, pts_end, null, null) == 0 and p.drop_out_of_segment) {
            c.gst_mini_object_unref(obj);
            return c.GST_FLOW_OK;
        }
    }
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var late = false;
    var step_end = false;
    var prepared = false;
    var dropped = false;
    if (k.prepare != null or k.prepare_list != null) {
        var do_sync = true;
        var stepped = false;
        var times = SyncTimes{};
        const syncable = getSyncTimes(x, obj, &times, &do_sync, &stepped, &p.current_step, &step_end);
        if (stepped) {
            dropped = true;
        } else {
            if (syncable and do_sync and gst_base_sink_get_sync(x) != 0) {
                el.lock(x);
                const clock = x.element.clock;
                if (clock != null and x.element.current_state == c.GST_STATE_PLAYING) {
                    const base_time: u64 = @bitCast(x.element.base_time);
                    const stime = base_time +% adjustTime(x, times.rstart);
                    const now = c.gst_clock_get_time(clock);
                    el.unlock(x);
                    late = isTooLate(x, obj, times.rstart, times.rstop, c.GST_CLOCK_EARLY, sdiff(stime, now), false);
                } else el.unlock(x);
            }
            ret = gst_base_sink_do_preroll(x, obj);
            if (ret != c.GST_FLOW_OK) {
                c.gst_mini_object_unref(obj);
                return ret;
            }
            if (late) {
                dropped = true;
            } else {
                if (!list) {
                    if (k.prepare) |f| ret = f(x, @ptrCast(@alignCast(obj)));
                } else {
                    if (k.prepare_list) |f| ret = f(x, @ptrCast(obj));
                }
                if (ret != c.GST_FLOW_OK) {
                    c.gst_mini_object_unref(obj);
                    return ret;
                }
                prepared = true;
            }
        }
    }
    again: while (true) {
        if (!dropped) {
            late = false;
            step_end = false;
            ret = doSync(x, @ptrCast(@alignCast(sync_buf)), &late, &step_end);
            if (ret == c.GST_FLOW_OK) {
                late = late and !prepared;
                if (late) {
                    dropped = true;
                } else {
                    if (p.max_bitrate != 0) {
                        const size = if (list) c.gst_buffer_list_calculate_size(@ptrCast(obj)) else c.gst_buffer_get_size(@ptrCast(@alignCast(obj)));
                        p.rc_accumulated += size;
                        p.rc_next = p.rc_time +% c.gst_util_uint64_scale(p.rc_accumulated, 8 * SEC, p.max_bitrate);
                    }
                    if (!list) {
                        setLastBuffer(x, @ptrCast(@alignCast(obj)));
                        setLastList(x, null);
                        if (k.render) |f| ret = f(x, @ptrCast(@alignCast(obj)));
                        if (ret == FLOW_DROPPED) {
                            ret = c.GST_FLOW_OK;
                            dropped = true;
                        }
                    } else {
                        if (k.render_list) |f| ret = f(x, @ptrCast(obj));
                        setLastBuffer(x, sync_buf);
                        setLastList(x, @ptrCast(obj));
                    }
                    if (!dropped) {
                        if (ret == FLOW_STEP) continue :again;
                        if (x.flushing != 0) {
                            c.gst_mini_object_unref(obj);
                            return c.GST_FLOW_FLUSHING;
                        }
                        p.rendered += 1;
                    }
                }
            }
        }
        if (dropped) {
            dropped = false;
            p.dropped += 1;
            if (atomicGet(&p.qos_enabled)) {
                const ts = sync_buf[0].pts;
                const dur = sync_buf[0].duration;
                const m = c.gst_message_new_qos(@ptrCast(x), x.sync, p.current_rstart, p.current_sstart, ts, dur);
                c.gst_message_set_qos_values(m, p.current_jitter, p.avg_rate, 1000000);
                c.gst_message_set_qos_stats(m, c.GST_FORMAT_BUFFERS, p.rendered, p.dropped);
                _ = c.gst_element_post_message(@ptrCast(x), m);
            }
        }
        if (step_end) {
            stopStepping(x, &x.segment, &p.current_step, p.current_rstart, p.current_rstop, x.eos != 0);
            continue :again;
        }
        break;
    }
    performQos(x, late);
    c.gst_mini_object_unref(obj);
    return ret;
}

fn chainMain(x: *Sink, pad: ?*c.GstPad, obj: *Mini, list: bool) c.GstFlowReturn {
    if (x.pad_mode != c.GST_PAD_MODE_PUSH) {
        c.gst_mini_object_unref(obj);
        return c.GST_FLOW_EOS;
    }
    prerollLock(x);
    defer prerollUnlock(x);
    return chainUnlocked(x, pad, obj, list);
}

fn chain(pad: ?*c.GstPad, parent_obj: [*c]c.GstObject, b: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    return chainMain(of(parent_obj), pad, @ptrCast(@alignCast(b)), false);
}

fn chainList(pad: ?*c.GstPad, parent_obj: [*c]c.GstObject, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    const x = of(parent_obj);
    if (klass(x).render_list != null) return chainMain(x, pad, @ptrCast(@alignCast(l)), true);
    const len = c.gst_buffer_list_length(l);
    var r: c.GstFlowReturn = c.GST_FLOW_OK;
    var i: c.guint = 0;
    while (i < len) : (i += 1) {
        r = chainMain(x, pad, @ptrCast(@alignCast(c.gst_buffer_ref(c.gst_buffer_list_get(l, i)))), false);
        if (r != c.GST_FLOW_OK) break;
    }
    c.gst_mini_object_unref(@ptrCast(@alignCast(l)));
    return r;
}

fn defaultDoSeek(segment: *c.GstSegment) bool {
    if (segment.format == c.GST_FORMAT_BYTES) {
        segment.time = segment.start;
    } else if (segment.start == 0) {
        segment.time = 0;
    } else return false;
    return true;
}

fn prepareSeek(x: *Sink, ev: [*c]Event, segment: *c.GstSegment) bool {
    var rate: f64 = 0;
    var fmt: c.GstFormat = 0;
    var flags_: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start: c.gint64 = 0;
    var stop: c.gint64 = 0;
    var update: c.gboolean = 0;
    c.gst_event_parse_seek(ev, &rate, &fmt, &flags_, &st, &start, &et, &stop);
    if (fmt == segment.format) {
        _ = c.gst_segment_do_seek(segment, rate, fmt, flags_, st, @bitCast(start), et, @bitCast(stop), &update);
        return true;
    }
    var ok: c.gboolean = 1;
    if (st != c.GST_SEEK_TYPE_NONE) {
        ok = c.gst_pad_query_convert(x.sinkpad, fmt, start, segment.format, &start);
        st = c.GST_SEEK_TYPE_SET;
    }
    if (ok != 0 and et != c.GST_SEEK_TYPE_NONE) {
        ok = c.gst_pad_query_convert(x.sinkpad, fmt, stop, segment.format, &stop);
        et = c.GST_SEEK_TYPE_SET;
    }
    _ = c.gst_segment_do_seek(segment, rate, segment.format, flags_, st, @bitCast(start), et, @bitCast(stop), &update);
    return ok != 0;
}

fn performSeek(x: *Sink, pad: ?*c.GstPad, ev: [*c]Event) bool {
    const dest = x.segment.format;
    var rate: f64 = 0;
    var fmt: c.GstFormat = 0;
    var flags_: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start: c.gint64 = 0;
    var stop: c.gint64 = 0;
    var update: c.gboolean = 0;
    var flush = false;
    if (ev != null) {
        c.gst_event_parse_seek(ev, &rate, &fmt, &flags_, &st, &start, &et, &stop);
        flush = flags_ & c.GST_SEEK_FLAG_FLUSH != 0;
    }
    if (flush) {
        _ = c.gst_pad_push_event(pad, c.gst_event_new_flush_start());
        flushStart(x, pad);
    }
    el.streamLock(pad);
    var seg = x.segment;
    var ok = true;
    if (ev != null) {
        if (x.segment.format != fmt) {
            if (!prepareSeek(x, ev, &seg)) ok = false;
        } else _ = c.gst_segment_do_seek(&seg, rate, fmt, flags_, st, @bitCast(start), et, @bitCast(stop), &update);
    }
    if (ok) ok = defaultDoSeek(&seg);
    if (flush) {
        _ = c.gst_pad_push_event(pad, c.gst_event_new_flush_stop(1));
        flushStop(x, pad, true);
    }
    if (ok and seg.format != dest) ok = false;
    if (ok) {
        c.gst_segment_copy_into(&seg, &x.segment);
        if (x.segment.flags & c.GST_SEGMENT_FLAG_SEGMENT != 0) _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_segment_start(@ptrCast(x), x.segment.format, @bitCast(x.segment.position)));
    }
    priv(x).discont = true;
    x.running = 1;
    el.streamUnlock(pad);
    return ok;
}

fn setStepInfo(x: *Sink, current: *Step, pending: *Step, seqnum: c.guint, format: c.GstFormat, amount: u64, rate: f64, flush: bool, intermediate: bool) void {
    el.lock(x);
    defer el.unlock(x);
    pending.seqnum = seqnum;
    pending.format = format;
    pending.amount = amount;
    pending.position = 0;
    pending.rate = rate;
    pending.flush = flush;
    pending.intermediate = intermediate;
    pending.valid = true;
    if (flush) current.valid = false;
}

fn performStep(x: *Sink, ev: [*c]Event) bool {
    const p = priv(x);
    const k = klass(x);
    var format: c.GstFormat = 0;
    var amount: u64 = 0;
    var rate: f64 = 0;
    var flush: c.gboolean = 0;
    var intermediate: c.gboolean = 0;
    c.gst_event_parse_step(ev, &format, &amount, &rate, &flush, &intermediate);
    const seqnum = c.gst_event_get_seqnum(ev);
    const m = c.gst_message_new_step_start(@ptrCast(x), 0, format, amount, rate, flush, intermediate);
    c.gst_message_set_seqnum(m, seqnum);
    _ = c.gst_element_post_message(@ptrCast(x), m);
    if (flush == 0) {
        setStepInfo(x, &p.current_step, &p.pending_step, seqnum, format, amount, rate, false, intermediate != 0);
        return true;
    }
    if (k.unlock) |f| _ = f(x);
    prerollLock(x);
    if (k.unlock_stop) |f| _ = f(x);
    setStepInfo(x, &p.current_step, &p.pending_step, seqnum, format, amount, rate, true, intermediate != 0);
    if (atomicGet(&p.async_enabled)) {
        x.playing_async = 1;
        p.pending_step.need_preroll = true;
        x.need_preroll = 0;
        updateStartTime(x);
        c.gst_element_lost_state(@ptrCast(x));
    } else {
        p.have_latency = true;
        x.need_preroll = 0;
    }
    p.current_sstart = NONE;
    p.current_sstop = NONE;
    p.eos_rtime = NONE;
    p.call_preroll = true;
    setLastBuffer(x, null);
    setLastList(x, null);
    resetQos(x);
    if (x.clock_id != null) c.gst_clock_id_unschedule(x.clock_id);
    if (x.have_preroll != 0) {
        p.step_unlock = true;
        prerollSignal(x);
    }
    prerollUnlock(x);
    return true;
}

fn performInstantRate(x: *Sink, ev: [*c]Event) void {
    const p = priv(x);
    const seqnum = c.gst_event_get_seqnum(ev);
    var rate: f64 = 0;
    var running: u64 = 0;
    var upstream: u64 = 0;
    c.gst_event_parse_instant_rate_sync_time(ev, &rate, &running, &upstream);
    prerollLock(x);
    defer prerollUnlock(x);
    p.instant_rate_sync_seqnum = seqnum;
    p.instant_rate_multiplier = rate;
    p.instant_rate_offset = sdiff(upstream, running);
    p.last_anchor_running_time = running;
    var switch_time: u64 = 0;
    if (c.gst_segment_position_from_running_time_full(&x.segment, c.GST_FORMAT_TIME, running, &switch_time) < 0) return;
    x.segment.position = switch_time;
    rate *= p.upstream_segment.rate;
    _ = c.gst_segment_do_seek(&x.segment, rate, c.GST_FORMAT_TIME, x.segment.flags & ~@as(c.guint, c.GST_SEEK_FLAG_FLUSH) & c.GST_SEEK_FLAG_INSTANT_RATE_CHANGE, c.GST_SEEK_TYPE_NONE, NONE, c.GST_SEEK_TYPE_NONE, NONE, null);
    p.current_sstart = NONE;
    p.current_sstop = NONE;
    p.eos_rtime = NONE;
    resetQos(x);
    if (x.clock_id != null) c.gst_clock_id_unschedule(x.clock_id);
    if (x.have_preroll != 0) {
        p.step_unlock = true;
        prerollSignal(x);
    }
}

fn loop(data: c.gpointer) callconv(.c) void {
    const pad: ?*c.GstPad = @ptrCast(@alignCast(data));
    const parent_obj = el.obj(pad).parent;
    const x = of(parent_obj);
    var blocksize = priv(x).blocksize;
    if (blocksize == 0) blocksize = std.math.maxInt(c.guint);
    var off = x.segment.position;
    var buf: [*c]Buffer = null;
    var result = c.gst_pad_pull_range(pad, off, blocksize, &buf);
    if (result == c.GST_FLOW_OK) {
        if (buf == null) {
            el.err(x, .stream, c.GST_STREAM_ERROR_FAILED, "Internal data flow error.", c.g_strdup("element returned NULL buffer"), FILE, "gst_base_sink_loop", 4644);
            result = c.GST_FLOW_ERROR;
        } else {
            off +%= c.gst_buffer_get_size(buf);
            x.segment.position = off;
            prerollLock(x);
            result = chainUnlocked(x, pad, @ptrCast(@alignCast(buf)), false);
            prerollUnlock(x);
            if (result == c.GST_FLOW_OK) return;
        }
    }
    _ = c.gst_pad_pause_task(pad);
    if (result == c.GST_FLOW_EOS) {
        if (x.segment.flags & c.GST_SEGMENT_FLAG_SEGMENT != 0) {
            _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_segment_done(@ptrCast(x), x.segment.format, @bitCast(x.segment.position)));
            _ = padEvent(pad, parent_obj, c.gst_event_new_segment_done(x.segment.format, @bitCast(x.segment.position)));
        } else _ = padEvent(pad, parent_obj, c.gst_event_new_eos());
    } else if (result == c.GST_FLOW_NOT_LINKED or result <= c.GST_FLOW_EOS) {
        el.flowError(x, result, FILE, "gst_base_sink_loop", 4636);
        _ = padEvent(pad, parent_obj, c.gst_event_new_eos());
    }
}

fn setFlushing(x: *Sink, flushing: bool) bool {
    const k = klass(x);
    const p = priv(x);
    if (flushing) {
        if (k.unlock) |f| _ = f(x);
    }
    prerollLock(x);
    defer prerollUnlock(x);
    x.flushing = @intFromBool(flushing);
    if (!flushing) return true;
    if (k.unlock_stop) |f| _ = f(x);
    x.need_preroll = 1;
    if (x.clock_id != null) c.gst_clock_id_unschedule(x.clock_id);
    x.eos = 0;
    p.received_eos = false;
    x.have_preroll = 0;
    p.step_unlock = false;
    if (atomicGet(&p.async_enabled)) {
        el.lock(x);
        p.have_latency = false;
        el.unlock(x);
    }
    prerollSignal(x);
    return true;
}

fn defaultActivatePull(s: [*c]Sink, active: c.gboolean) callconv(.c) c.gboolean {
    const x = of(s);
    if (active != 0) return c.gst_pad_start_task(x.sinkpad, loop, x.sinkpad, null);
    return c.gst_pad_stop_task(x.sinkpad);
}

fn negotiatePull(x: *Sink) bool {
    var caps = c.gst_pad_get_allowed_caps(x.sinkpad);
    if (caps == null or c.gst_caps_is_empty(caps) != 0) {
        if (caps != null) c.gst_caps_unref(caps);
        return false;
    }
    var ok = false;
    if (c.gst_caps_is_any(caps) != 0) {
        ok = true;
    } else {
        caps = fixate(x, caps);
        if (c.gst_caps_is_fixed(caps) != 0) {
            if (!el.padSetCaps(x.sinkpad, caps)) {
                c.gst_caps_unref(caps);
                return false;
            }
            ok = true;
        }
    }
    c.gst_caps_unref(caps);
    return ok;
}

fn padActivate(pad: ?*c.GstPad, parent_obj: [*c]c.GstObject) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    _ = setFlushing(x, false);
    var result = false;
    pull: {
        if (x.can_activate_pull == 0) break :pull;
        const q = c.gst_query_new_scheduling();
        if (c.gst_pad_peer_query(pad, q) == 0) {
            c.gst_query_unref(q);
            break :pull;
        }
        const pull_mode = c.gst_query_has_scheduling_mode(q, c.GST_PAD_MODE_PULL) != 0;
        c.gst_query_unref(q);
        if (!pull_mode) break :pull;
        x.pad_mode = c.GST_PAD_MODE_PULL;
        if (!negotiatePull(x)) break :pull;
        if (c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PULL, 1) == 0) {
            el.lock(x);
            _ = c.gst_caps_replace(&priv(x).caps, null);
            el.unlock(x);
            break :pull;
        }
        return 1;
    }
    result = c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PUSH, 1) != 0;
    if (!result) _ = setFlushing(x, true);
    return @intFromBool(result);
}

fn activationError() void {
    c.g_log("GStreamer-Base", c.G_LOG_LEVEL_WARNING, "Internal GStreamer activation error!!!");
}

fn padActivatePush(x: *Sink, active: bool) bool {
    if (active) {
        if (x.can_activate_push == 0) {
            x.pad_mode = c.GST_PAD_MODE_NONE;
            return false;
        }
        x.pad_mode = c.GST_PAD_MODE_PUSH;
        return true;
    }
    if (x.pad_mode != c.GST_PAD_MODE_PUSH) {
        activationError();
        return false;
    }
    _ = setFlushing(x, true);
    x.pad_mode = c.GST_PAD_MODE_NONE;
    return true;
}

fn padActivatePull(x: *Sink, pad: ?*c.GstPad, active: bool) bool {
    const k = klass(x);
    if (active) {
        c.gst_segment_init(&x.segment, c.GST_FORMAT_BYTES);
        el.lock(x);
        x.have_newsegment = 1;
        el.unlock(x);
        var duration: c.gint64 = 0;
        if (c.gst_pad_peer_query_duration(pad, c.GST_FORMAT_BYTES, &duration) != 0) x.segment.duration = @bitCast(duration);
        const ok = if (k.activate_pull) |f| f(x, 1) != 0 else false;
        if (!ok) {
            x.pad_mode = c.GST_PAD_MODE_NONE;
            return false;
        }
        return true;
    }
    if (x.pad_mode != c.GST_PAD_MODE_PULL) {
        activationError();
        return false;
    }
    var ok = setFlushing(x, true);
    if (k.activate_pull) |f| ok = ok and f(x, 0) != 0;
    x.pad_mode = c.GST_PAD_MODE_NONE;
    return ok;
}

fn padActivateMode(pad: ?*c.GstPad, parent_obj: [*c]c.GstObject, m: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    return switch (m) {
        c.GST_PAD_MODE_PULL => @intFromBool(padActivatePull(x, pad, active != 0)),
        c.GST_PAD_MODE_PUSH => @intFromBool(padActivatePush(x, active != 0)),
        else => 0,
    };
}

fn sendEvent(e: [*c]c.GstElement, ev_in: [*c]Event) callconv(.c) c.gboolean {
    const x = of(e);
    const p = priv(x);
    var ev = ev_in;
    el.lock(x);
    const pad: ?*c.GstPad = @ptrCast(@alignCast(c.gst_object_ref(x.sinkpad)));
    const m = x.pad_mode;
    el.unlock(x);
    defer c.gst_object_unref(pad);
    var forward = ev[0].type & c.GST_EVENT_TYPE_UPSTREAM != 0;
    var result: c.gboolean = 1;
    switch (ev[0].type) {
        c.GST_EVENT_LATENCY => {
            var latency: u64 = 0;
            c.gst_event_parse_latency(ev, &latency);
            el.lock(x);
            p.latency = latency;
            if (!p.have_latency) forward = false;
            el.unlock(x);
        },
        c.GST_EVENT_INSTANT_RATE_SYNC_TIME => {
            performInstantRate(x, ev);
            forward = true;
        },
        c.GST_EVENT_SEEK => if (m == c.GST_PAD_MODE_PULL) {
            result = @intFromBool(performSeek(x, pad, ev));
        },
        c.GST_EVENT_STEP => {
            result = @intFromBool(performStep(x, ev));
            forward = false;
        },
        else => {},
    }
    if (!forward) {
        c.gst_event_unref(ev);
        return result;
    }
    if (p.instant_rate_sync_seqnum != 0) {
        var now: u64 = NONE;
        el.lock(x);
        const es = &x.element;
        const playing = es.current_state == c.GST_STATE_PLAYING and (es.pending_state == c.GST_STATE_VOID_PENDING or es.pending_state == c.GST_STATE_PLAYING);
        if (playing) {
            const base_time: u64 = @bitCast(es.base_time);
            const clock = es.clock;
            el.unlock(x);
            if (clock != null) now = c.gst_clock_get_time(clock) -% base_time;
        } else {
            now = es.start_time;
            el.unlock(x);
        }
        if (now != NONE) {
            var actual: u64 = undefined;
            var negative = false;
            if (now < p.last_anchor_running_time) {
                actual = p.last_anchor_running_time - now;
                negative = true;
            } else actual = now - p.last_anchor_running_time;
            const upstream: u64 = @intFromFloat(@as(f64, @floatFromInt(actual)) * x.segment.rate / p.upstream_segment.rate);
            var difference: c.GstClockTimeDiff = if (negative) @as(i64, @bitCast(upstream)) -% @as(i64, @bitCast(actual)) else @as(i64, @bitCast(actual)) -% @as(i64, @bitCast(upstream));
            difference = p.instant_rate_offset +% difference;
            ev = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(ev)))));
            c.gst_event_set_running_time_offset(ev, -difference);
        }
    }
    return c.gst_pad_push_event(pad, ev);
}

fn getPosition(x: *Sink, format: c.GstFormat, cur: *c.gint64, upstream: *bool) bool {
    const p = priv(x);
    el.lock(x);
    const es = &x.element;
    if (es.current_state <= c.GST_STATE_READY and es.pending_state <= c.GST_STATE_READY) {
        cur.* = -1;
        el.unlock(x);
        return false;
    }
    const segment = &x.segment;
    var oformat = segment.format;
    if (oformat == c.GST_FORMAT_UNDEFINED) {
        cur.* = -1;
        el.unlock(x);
        return false;
    }
    var in_paused = es.current_state != c.GST_STATE_PLAYING or es.pending_state != c.GST_STATE_VOID_PENDING;
    var last_seen = x.eos != 0;
    var with_clock = x.sync != 0;
    const clock = es.clock;
    if (clock == null) with_clock = false else _ = c.gst_object_ref(clock);
    defer if (clock != null) c.gst_object_unref(clock);
    if (in_paused and with_clock and atomicGet(&p.to_playing)) in_paused = false;
    var time: c.gint64 = if (valid(segment.time)) @bitCast(segment.time) else 0;
    const off: c.gint64 = if (valid(segment.offset)) @bitCast(segment.offset) else 0;
    var duration: c.gint64 = if (valid(segment.stop)) @bitCast(segment.stop -% segment.start) else 0;
    var base: c.gint64 = @bitCast(segment.base);
    const rate = segment.rate * segment.applied_rate;
    const latency = p.latency;
    var base_time: c.GstClockTimeDiff = undefined;
    if (in_paused) {
        base_time = @bitCast(es.start_time);
    } else if (with_clock) {
        base_time = es.base_time;
    } else base_time = -1;
    if (base_time == -1) last_seen = true;
    var last: c.gint64 = undefined;
    if (oformat == c.GST_FORMAT_TIME) {
        const start: c.gint64 = @bitCast(p.current_sstart);
        const stop: c.gint64 = @bitCast(p.current_sstop);
        if (last_seen) {
            last = if (stop == -1 or segment.rate > 0.0) start else stop;
        } else {
            last = if (start == -1 or segment.rate > 0.0) stop else start;
        }
    } else last = @bitCast(c.gst_segment_to_stream_time(segment, oformat, segment.position));
    el.unlock(x);
    if (last_seen) {
        if (last == -1) {
            upstream.* = true;
            return false;
        }
        cur.* = last;
    } else {
        if (oformat != c.GST_FORMAT_TIME) {
            if (c.gst_pad_query_convert(x.sinkpad, oformat, base, c.GST_FORMAT_TIME, &base) == 0 or
                c.gst_pad_query_convert(x.sinkpad, oformat, duration, c.GST_FORMAT_TIME, &duration) == 0 or
                c.gst_pad_query_convert(x.sinkpad, oformat, time, c.GST_FORMAT_TIME, &time) == 0 or
                c.gst_pad_query_convert(x.sinkpad, oformat, last, c.GST_FORMAT_TIME, &last) == 0)
            {
                upstream.* = true;
                return false;
            }
            oformat = c.GST_FORMAT_TIME;
        }
        var now: u64 = undefined;
        var bt: u64 = @bitCast(base_time);
        if (!in_paused and with_clock) {
            now = c.gst_clock_get_time(clock);
        } else {
            now = bt;
            bt = 0;
        }
        bt +%= @bitCast(base);
        bt +%= latency;
        if (sdiff(bt, now) < 0) bt = now;
        if (rate < 0.0) time += duration;
        cur.* = time + off + @as(c.gint64, @intFromFloat(@as(f64, @floatFromInt(now -% bt)) * rate));
        if (last != -1) cur.* = if (rate > 0.0) @min(last, cur.*) else @max(last, cur.*);
    }
    if (oformat != format) {
        if (c.gst_pad_query_convert(x.sinkpad, oformat, cur.*, format, cur) == 0) {
            upstream.* = true;
            return false;
        }
    }
    return true;
}

fn getDuration(x: *Sink, format: c.GstFormat, dur: *c.gint64, upstream: *bool) bool {
    if (x.pad_mode != c.GST_PAD_MODE_PULL) {
        upstream.* = true;
        return false;
    }
    upstream.* = false;
    var u: c.gint64 = 0;
    if (c.gst_pad_peer_query_duration(x.sinkpad, c.GST_FORMAT_BYTES, &u) == 0) return false;
    x.segment.duration = @bitCast(u);
    if (format != c.GST_FORMAT_BYTES) return c.gst_pad_query_convert(x.sinkpad, c.GST_FORMAT_BYTES, u, format, dur) != 0;
    dur.* = u;
    return true;
}

fn elementQuery(e: [*c]c.GstElement, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(e);
    switch (q[0].type) {
        c.GST_QUERY_POSITION => {
            var cur: c.gint64 = 0;
            var format: c.GstFormat = 0;
            var upstream = false;
            c.gst_query_parse_position(q, &format, null);
            var res = getPosition(x, format, &cur, &upstream);
            if (res) {
                c.gst_query_set_position(q, format, cur);
            } else if (upstream) res = c.gst_pad_peer_query(x.sinkpad, q) != 0;
            if (!res and format == c.GST_FORMAT_PERCENT) {
                var dur: c.gint64 = 0;
                res = getPosition(x, c.GST_FORMAT_TIME, &cur, &upstream);
                if (!res and upstream) res = c.gst_pad_peer_query_position(x.sinkpad, c.GST_FORMAT_TIME, &cur) != 0;
                if (res) {
                    res = getDuration(x, c.GST_FORMAT_TIME, &dur, &upstream);
                    if (!res and upstream) res = c.gst_pad_peer_query_duration(x.sinkpad, c.GST_FORMAT_TIME, &dur) != 0;
                }
                if (res) c.gst_query_set_position(q, c.GST_FORMAT_PERCENT, @bitCast(c.gst_util_uint64_scale(100 * c.GST_FORMAT_PERCENT_SCALE, @bitCast(cur), @bitCast(dur))));
            }
            return @intFromBool(res);
        },
        c.GST_QUERY_DURATION => {
            var dur: c.gint64 = 0;
            var format: c.GstFormat = 0;
            var upstream = false;
            c.gst_query_parse_duration(q, &format, null);
            var res = getDuration(x, format, &dur, &upstream);
            if (res) {
                c.gst_query_set_duration(q, format, dur);
            } else if (upstream) res = c.gst_pad_peer_query(x.sinkpad, q) != 0;
            if (!res and format == c.GST_FORMAT_PERCENT) {
                c.gst_query_set_duration(q, c.GST_FORMAT_PERCENT, c.GST_FORMAT_PERCENT_MAX);
                res = true;
            }
            return @intFromBool(res);
        },
        c.GST_QUERY_LATENCY => {
            var live: c.gboolean = 0;
            var us_live: c.gboolean = 0;
            var min: u64 = 0;
            var max: u64 = 0;
            const res = gst_base_sink_query_latency(x, &live, &us_live, &min, &max);
            if (res != 0) c.gst_query_set_latency(q, live, min, max);
            return res;
        },
        c.GST_QUERY_JITTER => return 0,
        c.GST_QUERY_RATE => return 1,
        c.GST_QUERY_SEGMENT => {
            if (x.pad_mode != c.GST_PAD_MODE_PULL) return c.gst_pad_peer_query(x.sinkpad, q);
            const format = x.segment.format;
            const start = c.gst_segment_to_stream_time(&x.segment, format, x.segment.start);
            const stop = if (x.segment.stop == NONE) x.segment.duration else c.gst_segment_to_stream_time(&x.segment, format, x.segment.stop);
            c.gst_query_set_segment(q, x.segment.rate, format, @bitCast(start), @bitCast(stop));
            return 1;
        },
        else => return c.gst_pad_peer_query(x.sinkpad, q),
    }
}

fn drain(x: *Sink) void {
    const p = priv(x);
    el.lock(x);
    const old = p.last_buffer;
    if (old != null) p.last_buffer = c.gst_buffer_copy_deep(old);
    const old_list = p.last_buffer_list;
    if (old_list != null) p.last_buffer_list = c.gst_buffer_list_copy_deep(old_list);
    el.unlock(x);
    if (old != null) c.gst_buffer_unref(old);
    if (old_list != null) c.gst_mini_object_unref(@ptrCast(@alignCast(old_list)));
}

fn defaultQuery(s: [*c]Sink, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(s);
    switch (q[0].type) {
        c.GST_QUERY_ALLOCATION => {
            drain(x);
            if (klass(x).propose_allocation) |f| return f(x, q);
            return 0;
        },
        c.GST_QUERY_CAPS => {
            var filter: [*c]Caps = null;
            c.gst_query_parse_caps(q, &filter);
            const caps = queryCaps(x, x.sinkpad, filter);
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            var caps: [*c]Caps = null;
            c.gst_query_parse_accept_caps(q, &caps);
            const allowed = queryCaps(x, x.sinkpad, null);
            const subset = c.gst_caps_is_subset(caps, allowed);
            c.gst_caps_unref(allowed);
            c.gst_query_set_accept_caps_result(q, subset);
            return 1;
        },
        c.GST_QUERY_DRAIN => {
            drain(x);
            return 1;
        },
        c.GST_QUERY_POSITION => return elementQuery(@ptrCast(x), q),
        else => return c.gst_pad_query_default(x.sinkpad, @ptrCast(x), q),
    }
}

fn padQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    if (klass(x).query) |f| return f(x, q);
    return 0;
}

fn asyncStart(x: *Sink) void {
    _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_async_start(@ptrCast(x)));
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const x = of(e);
    const p = priv(x);
    const k = klass(x);
    var ret: c.GstStateChangeReturn = c.GST_STATE_CHANGE_SUCCESS;
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => if (k.start) |f| {
            if (f(x) == 0) {
                el.err(x, .core, c.GST_CORE_ERROR_STATE_CHANGE, null, c.g_strdup("Failed to start"), FILE, "gst_base_sink_change_state", 5902);
                return c.GST_STATE_CHANGE_FAILURE;
            }
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            prerollLock(x);
            x.have_newsegment = 0;
            c.gst_segment_init(&x.segment, c.GST_FORMAT_UNDEFINED);
            c.gst_segment_init(&p.upstream_segment, c.GST_FORMAT_UNDEFINED);
            x.offset = 0;
            x.have_preroll = 0;
            p.step_unlock = false;
            x.need_preroll = 1;
            x.playing_async = 1;
            p.current_sstart = NONE;
            p.current_sstop = NONE;
            p.eos_rtime = NONE;
            p.latency = 0;
            x.eos = 0;
            p.received_eos = false;
            resetQos(x);
            p.rc_next = NONE;
            p.committed = false;
            p.call_preroll = true;
            p.current_step.valid = false;
            p.pending_step.valid = false;
            p.instant_rate_sync_seqnum = 0;
            p.instant_rate_multiplier = 0;
            p.last_instant_rate_seqnum = 0;
            p.instant_rate_offset = 0;
            p.last_anchor_running_time = 0;
            if (atomicGet(&p.async_enabled)) {
                ret = c.GST_STATE_CHANGE_ASYNC;
                asyncStart(x);
            } else {
                p.have_latency = true;
                postLatency(x);
            }
            prerollUnlock(x);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => {
            prerollLock(x);
            atomicSet(&p.to_playing, true);
            if (!needsPreroll(x)) {
                x.playing_async = 0;
                x.need_preroll = 0;
                if (x.eos != 0) {
                    const m = c.gst_message_new_eos(@ptrCast(x));
                    c.gst_message_set_seqnum(m, p.seqnum);
                    _ = c.gst_element_post_message(@ptrCast(x), m);
                } else prerollSignal(x);
            } else {
                x.need_preroll = 1;
                x.playing_async = 1;
                p.call_preroll = true;
                p.committed = false;
                if (atomicGet(&p.async_enabled)) {
                    ret = c.GST_STATE_CHANGE_ASYNC;
                    asyncStart(x);
                }
            }
            prerollUnlock(x);
        },
        else => {},
    }
    if (parent.?.change_state.?(e, t) == c.GST_STATE_CHANGE_FAILURE) return c.GST_STATE_CHANGE_FAILURE;
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => atomicSet(&p.to_playing, false),
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => {
            atomicSet(&p.to_playing, false);
            if (k.unlock) |f| _ = f(x);
            prerollLock(x);
            if (k.unlock_stop) |f| _ = f(x);
            if (x.clock_id != null) c.gst_clock_id_unschedule(x.clock_id);
            if (!needsPreroll(x)) {
                x.playing_async = 0;
                x.need_preroll = 0;
            } else if (x.element.target_state <= c.GST_STATE_READY) {
                ret = c.GST_STATE_CHANGE_SUCCESS;
            } else {
                x.playing_async = 1;
                x.need_preroll = 1;
                p.committed = false;
                p.call_preroll = true;
                if (atomicGet(&p.async_enabled)) {
                    ret = c.GST_STATE_CHANGE_ASYNC;
                    asyncStart(x);
                }
            }
            resetQos(x);
            prerollUnlock(x);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            prerollLock(x);
            el.lock(x);
            x.have_newsegment = 0;
            p.current_sstart = NONE;
            p.current_sstop = NONE;
            p.have_latency = false;
            if (p.cached_clock_id != null) {
                c.gst_clock_id_unref(p.cached_clock_id);
                p.cached_clock_id = null;
            }
            _ = c.gst_caps_replace(&p.caps, null);
            el.unlock(x);
            setLastBuffer(x, null);
            setLastList(x, null);
            p.call_preroll = false;
            if (!p.committed) {
                if (atomicGet(&p.async_enabled)) {
                    _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_state_changed(@ptrCast(x), c.GST_STATE_PLAYING, c.GST_STATE_PAUSED, c.GST_STATE_READY));
                    _ = c.gst_element_post_message(@ptrCast(x), c.gst_message_new_async_done(@ptrCast(x), NONE));
                }
                p.committed = true;
            }
            prerollUnlock(x);
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (k.stop) |f| _ = f(x);
            setLastBuffer(x, null);
            setLastList(x, null);
            p.call_preroll = false;
        },
        else => {},
    }
    return ret;
}

pub export fn gst_base_sink_get_stats(s: [*c]Sink) [*c]c.GstStructure {
    if (!check.that(s != null, "gst_base_sink_get_stats", "sink != NULL")) return null;
    const p = priv(s);
    return c.gst_structure_new("application/x-gst-base-sink-stats", "average-rate", c.G_TYPE_DOUBLE, p.avg_rate, "dropped", c.G_TYPE_UINT64, p.dropped, "rendered", c.G_TYPE_UINT64, p.rendered, @as(?*anyopaque, null));
}
