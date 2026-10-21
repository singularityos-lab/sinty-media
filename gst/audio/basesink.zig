const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const enums = @import("enumtypes.zig");
const clock = @import("clock.zig");
const rb = @import("ringbuffer.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Sink = c.GstAudioBaseSink;
const Class = c.GstAudioBaseSinkClass;
const BSink = c.GstBaseSink;
const BClass = c.GstBaseSinkClass;
const NONE: u64 = std.math.maxInt(u64);
const PATH = "../gst-libs/gst/audio/gstaudiobasesink.c";
const NULLP = @as(?*anyopaque, null);

const Private = extern struct {
    us_latency: u64,
    slave_method: c.GstAudioBaseSinkSlaveMethod,
    avg_skew: i64,
    last_align: i64,
    sync_latency: c.gboolean,
    eos_time: u64,
    drift_tolerance: u64,
    alignment_threshold: u64,
    discont_time: u64,
    discont_wait: u64,
    custom_cb: c.GstAudioBaseSinkCustomSlavingCallback,
    custom_data: c.gpointer,
    custom_notify: c.GDestroyNotify,
};

const DEFAULT_BUFFER_TIME: i64 = 200000;
const DEFAULT_LATENCY_TIME: i64 = 10000;
const DEFAULT_ALIGNMENT = 40 * c.GST_MSECOND;
const DEFAULT_DRIFT: u64 = 40000;
const DEFAULT_DISCONT_WAIT = c.GST_SECOND;

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*BClass = null;

fn of(p: anytype) [*c]Sink {
    return @ptrCast(@alignCast(p));
}

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(of(p).*.priv));
}

fn bs(p: anytype) [*c]BSink {
    return @ptrCast(@alignCast(p));
}

fn isSink(p: anytype) bool {
    return gtype.instanceOf(p, gst_audio_base_sink_get_type());
}

fn lock(p: anytype) void {
    el.lock(p);
}

fn unlock(p: anytype) void {
    el.unlock(p);
}

fn elementClock(p: anytype) [*c]c.GstClock {
    return @as([*c]c.GstElement, @ptrCast(@alignCast(p))).*.clock;
}

fn formatError(s: [*c]Sink, debug: [*c]const u8, line: c.gint, comptime func: []const u8) void {
    el.messageAt(s, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_FORMAT, null, if (debug != null) c.g_strdup(debug) else null, PATH, func, line, null);
}

fn pspecs(oc: *c.GObjectClass) void {
    const F = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_int64("buffer-time", "Buffer Time", "Size of audio buffer in microseconds, this is the minimum latency that the sink reports", 1, std.math.maxInt(i64), DEFAULT_BUFFER_TIME, F));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_int64("latency-time", "Latency Time", "The minimum amount of data to write in each iteration in microseconds", 1, std.math.maxInt(i64), DEFAULT_LATENCY_TIME, F));
    c.g_object_class_install_property(oc, 3, c.g_param_spec_boolean("provide-clock", "Provide Clock", "Provide a clock to be used as the global pipeline clock", 1, F));
    c.g_object_class_install_property(oc, 4, c.g_param_spec_enum("slave-method", "Slave Method", "Algorithm used to match the rate of the masterclock", enums.gst_audio_base_sink_slave_method_get_type(), c.GST_AUDIO_BASE_SINK_SLAVE_SKEW, F));
    c.g_object_class_install_property(oc, 5, c.g_param_spec_boolean("can-activate-pull", "Allow Pull Scheduling", "Allow pull-based scheduling", 0, F));
    c.g_object_class_install_property(oc, 7, c.g_param_spec_int64("drift-tolerance", "Drift Tolerance", "Tolerance for clock drift in microseconds", 1, std.math.maxInt(i64), @intCast(DEFAULT_DRIFT), F));
    c.g_object_class_install_property(oc, 6, c.g_param_spec_uint64("alignment-threshold", "Alignment Threshold", "Timestamp alignment threshold in nanoseconds", 1, std.math.maxInt(u64) - 1, DEFAULT_ALIGNMENT, F));
    c.g_object_class_install_property(oc, 8, c.g_param_spec_uint64("discont-wait", "Discont Wait", "Window of time in nanoseconds to wait before creating a discontinuity", 0, std.math.maxInt(u64) - 1, DEFAULT_DISCONT_WAIT, F));
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const bc: *BClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    pspecs(oc);
    ec.change_state = changeState;
    ec.provide_clock = provideClock;
    ec.query = elementQuery;
    bc.fixate = fixate;
    bc.set_caps = setCaps;
    bc.event = event;
    bc.wait_event = waitEvent;
    bc.get_times = getTimes;
    bc.preroll = preroll;
    bc.render = render;
    bc.query = padQuery;
    bc.activate_pull = activatePull;
    _ = c.g_type_class_ref(clock.gst_audio_clock_get_type());
    _ = c.g_type_class_ref(rb.gst_audio_ring_buffer_get_type());
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = of(inst);
    s.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    s.*.buffer_time = DEFAULT_BUFFER_TIME;
    s.*.latency_time = DEFAULT_LATENCY_TIME;
    const p = priv(s);
    p.slave_method = c.GST_AUDIO_BASE_SINK_SLAVE_SKEW;
    p.drift_tolerance = DEFAULT_DRIFT;
    p.alignment_threshold = DEFAULT_ALIGNMENT;
    p.discont_wait = DEFAULT_DISCONT_WAIT;
    p.custom_cb = null;
    p.custom_data = null;
    p.custom_notify = null;
    s.*.provided_clock = clock.gst_audio_clock_new("GstAudioSinkClock", @ptrCast(&getTime), s, null);
    bs(s).*.can_activate_push = 1;
    bs(s).*.can_activate_pull = 0;
    c.gst_base_sink_set_last_sample_enabled(bs(s), 0);
    el.setFlag(s, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK);
}

pub export fn gst_audio_base_sink_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_base_sink_get_type, "GstAudioBaseSink", Class, Sink, classInit, init, 0);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            _ = c._gst_debug_category_new("audiobasesink", 0, "audiobasesink element");
            return t;
        }
    }.f);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = of(o);
    if (priv(s).custom_notify != null) priv(s).custom_notify.?(priv(s).custom_data);
    if (s.*.provided_clock != null) {
        clock.gst_audio_clock_invalidate(@ptrCast(@alignCast(s.*.provided_clock)));
        c.gst_object_unref(s.*.provided_clock);
        s.*.provided_clock = null;
    }
    if (s.*.ringbuffer != null) {
        c.gst_object_unparent(@ptrCast(s.*.ringbuffer));
        s.*.ringbuffer = null;
    }
    @as(*c.GObjectClass, @ptrCast(parent)).dispose.?(o);
}

fn provideClock(e: [*c]c.GstElement) callconv(.c) [*c]c.GstClock {
    const s = of(e);
    if (s.*.ringbuffer == null or rb.gst_audio_ring_buffer_is_acquired(s.*.ringbuffer) == 0) return null;
    lock(s);
    defer unlock(s);
    if (el.flags(s) & c.GST_ELEMENT_FLAG_PROVIDE_CLOCK == 0) return null;
    return @ptrCast(@alignCast(c.gst_object_ref(s.*.provided_clock)));
}

fn selfClock(s: [*c]Sink) bool {
    const k = s.*.provided_clock;
    return k != null and gtype.instanceOf(k, clock.gst_audio_clock_get_type()) and @as([*c]c.GstAudioClock, @ptrCast(@alignCast(k))).*.func == @as(c.GstAudioClockGetTimeFunc, @ptrCast(&getTime));
}

fn convertQuery(s: [*c]Sink, q: [*c]c.GstQuery) c.gboolean {
    if (s.*.ringbuffer == null) return 0;
    var sf: c.GstFormat = 0;
    var df: c.GstFormat = 0;
    var sv: i64 = 0;
    var dv: c_long = 0;
    c.gst_query_parse_convert(q, &sf, &sv, &df, null);
    const res = rb.gst_audio_ring_buffer_convert(s.*.ringbuffer, sf, sv, df, &dv);
    if (res != 0) c.gst_query_set_convert(q, sf, sv, df, dv);
    return res;
}

fn padQuery(b: [*c]BSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q.*.type == c.GST_QUERY_CONVERT) return convertQuery(of(b), q);
    return parent.?.query.?(b, q);
}

fn elementQuery(e: [*c]c.GstElement, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = of(e);
    switch (q.*.type) {
        c.GST_QUERY_LATENCY => {
            var live: c.gboolean = 0;
            var us_live: c.gboolean = 0;
            var min_l: u64 = 0;
            var max_l: u64 = 0;
            const res = c.gst_base_sink_query_latency(bs(s), &live, &us_live, &min_l, &max_l);
            if (res == 0) return 0;
            var min_latency = min_l;
            var max_latency = max_l;
            if (live != 0 and us_live != 0) {
                lock(s);
                if (s.*.ringbuffer == null or s.*.ringbuffer.*.spec.info.rate == 0) {
                    unlock(s);
                    return 0;
                }
                const spec: *c.GstAudioRingBufferSpec = @ptrCast(&s.*.ringbuffer.*.spec);
                priv(s).us_latency = min_l;
                const base = c.gst_util_uint64_scale_int(@bitCast(@as(i64, spec.seglatency *% spec.segsize)), c.GST_SECOND, spec.info.rate *% spec.info.bpf);
                unlock(s);
                min_latency = base +% min_l;
                max_latency = if (max_l == NONE) NONE else base +% max_l;
            }
            c.gst_query_set_latency(q, live, min_latency, max_latency);
            return res;
        },
        c.GST_QUERY_CONVERT => return convertQuery(s, q),
        else => return @as(*c.GstElementClass, @ptrCast(parent)).query.?(e, q),
    }
}

fn getTime(_: [*c]c.GstClock, s: [*c]Sink) callconv(.c) c.GstClockTime {
    const r = s.*.ringbuffer;
    if (r == null) return NONE;
    const rate = r.*.spec.info.rate;
    if (rate == 0) return NONE;
    var samples = rb.gst_audio_ring_buffer_samples_done(r);
    const delay = rb.gst_audio_ring_buffer_delay(r);
    samples = if (samples >= delay) samples - delay else 0;
    return c.gst_util_uint64_scale_int(samples, c.GST_SECOND, rate);
}

pub export fn gst_audio_base_sink_set_provide_clock(s: [*c]Sink, provide: c.gboolean) void {
    if (!check.that(isSink(s), "gst_audio_base_sink_set_provide_clock", "GST_IS_AUDIO_BASE_SINK (sink)")) return;
    lock(s);
    if (provide != 0) el.setFlag(s, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK) else el.unsetFlag(s, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK);
    unlock(s);
}

pub export fn gst_audio_base_sink_get_provide_clock(s: [*c]Sink) c.gboolean {
    if (!check.that(isSink(s), "gst_audio_base_sink_get_provide_clock", "GST_IS_AUDIO_BASE_SINK (sink)")) return 0;
    lock(s);
    defer unlock(s);
    return @intFromBool(el.flags(s) & c.GST_ELEMENT_FLAG_PROVIDE_CLOCK != 0);
}

pub export fn gst_audio_base_sink_set_slave_method(s: [*c]Sink, m: c.GstAudioBaseSinkSlaveMethod) void {
    if (!check.that(isSink(s), "gst_audio_base_sink_set_slave_method", "GST_IS_AUDIO_BASE_SINK (sink)")) return;
    lock(s);
    priv(s).slave_method = m;
    unlock(s);
}

pub export fn gst_audio_base_sink_get_slave_method(s: [*c]Sink) c.GstAudioBaseSinkSlaveMethod {
    if (!check.that(isSink(s), "gst_audio_base_sink_get_slave_method", "GST_IS_AUDIO_BASE_SINK (sink)")) return @bitCast(@as(c_int, -1));
    lock(s);
    defer unlock(s);
    return priv(s).slave_method;
}

pub export fn gst_audio_base_sink_set_drift_tolerance(s: [*c]Sink, d: c_long) void {
    if (!check.that(isSink(s), "gst_audio_base_sink_set_drift_tolerance", "GST_IS_AUDIO_BASE_SINK (sink)")) return;
    lock(s);
    priv(s).drift_tolerance = @bitCast(d);
    unlock(s);
}

pub export fn gst_audio_base_sink_get_drift_tolerance(s: [*c]Sink) c_long {
    if (!check.that(isSink(s), "gst_audio_base_sink_get_drift_tolerance", "GST_IS_AUDIO_BASE_SINK (sink)")) return -1;
    lock(s);
    defer unlock(s);
    return @bitCast(priv(s).drift_tolerance);
}

pub export fn gst_audio_base_sink_set_alignment_threshold(s: [*c]Sink, t: c.GstClockTime) void {
    const f = "gst_audio_base_sink_set_alignment_threshold";
    if (!check.that(isSink(s), f, "GST_IS_AUDIO_BASE_SINK (sink)")) return;
    if (!check.that(t != NONE, f, "GST_CLOCK_TIME_IS_VALID (alignment_threshold)")) return;
    lock(s);
    priv(s).alignment_threshold = t;
    unlock(s);
}

pub export fn gst_audio_base_sink_get_alignment_threshold(s: [*c]Sink) c.GstClockTime {
    if (!check.that(isSink(s), "gst_audio_base_sink_get_alignment_threshold", "GST_IS_AUDIO_BASE_SINK (sink)")) return NONE;
    lock(s);
    defer unlock(s);
    return priv(s).alignment_threshold;
}

pub export fn gst_audio_base_sink_set_discont_wait(s: [*c]Sink, w: c.GstClockTime) void {
    const f = "gst_audio_base_sink_set_discont_wait";
    if (!check.that(isSink(s), f, "GST_IS_AUDIO_BASE_SINK (sink)")) return;
    if (!check.that(w != NONE, f, "GST_CLOCK_TIME_IS_VALID (discont_wait)")) return;
    lock(s);
    priv(s).discont_wait = w;
    unlock(s);
}

pub export fn gst_audio_base_sink_get_discont_wait(s: [*c]Sink) c.GstClockTime {
    if (!check.that(isSink(s), "gst_audio_base_sink_get_discont_wait", "GST_IS_AUDIO_BASE_SINK (sink)")) return NONE;
    lock(s);
    defer unlock(s);
    return priv(s).discont_wait;
}

pub export fn gst_audio_base_sink_set_custom_slaving_callback(s: [*c]Sink, cb: c.GstAudioBaseSinkCustomSlavingCallback, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isSink(s), "gst_audio_base_sink_set_custom_slaving_callback", "GST_IS_AUDIO_BASE_SINK (sink)")) return;
    lock(s);
    priv(s).custom_cb = cb;
    priv(s).custom_data = data;
    priv(s).custom_notify = notify;
    unlock(s);
}

fn reportDiscont(s: [*c]Sink, reason: c.GstAudioBaseSinkDiscontReason) void {
    const p = priv(s);
    if (p.custom_cb != null and p.slave_method == c.GST_AUDIO_BASE_SINK_SLAVE_CUSTOM) p.custom_cb.?(s, NONE, NONE, null, reason, p.custom_data);
}

pub export fn gst_audio_base_sink_report_device_failure(s: [*c]Sink) void {
    if (!check.that(isSink(s), "gst_audio_base_sink_report_device_failure", "GST_IS_AUDIO_BASE_SINK (sink)")) return;
    lock(s);
    reportDiscont(s, c.GST_AUDIO_BASE_SINK_DISCONT_REASON_DEVICE_FAILURE);
    unlock(s);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    switch (id) {
        1 => s.*.buffer_time = @bitCast(c.g_value_get_int64(v)),
        2 => s.*.latency_time = @bitCast(c.g_value_get_int64(v)),
        3 => gst_audio_base_sink_set_provide_clock(s, c.g_value_get_boolean(v)),
        4 => gst_audio_base_sink_set_slave_method(s, @bitCast(c.g_value_get_enum(v))),
        5 => bs(s).*.can_activate_pull = c.g_value_get_boolean(v),
        7 => gst_audio_base_sink_set_drift_tolerance(s, c.g_value_get_int64(v)),
        6 => gst_audio_base_sink_set_alignment_threshold(s, c.g_value_get_uint64(v)),
        8 => gst_audio_base_sink_set_discont_wait(s, c.g_value_get_uint64(v)),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 860),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    switch (id) {
        1 => c.g_value_set_int64(v, @bitCast(s.*.buffer_time)),
        2 => c.g_value_set_int64(v, @bitCast(s.*.latency_time)),
        3 => c.g_value_set_boolean(v, gst_audio_base_sink_get_provide_clock(s)),
        4 => c.g_value_set_enum(v, @bitCast(gst_audio_base_sink_get_slave_method(s))),
        5 => c.g_value_set_boolean(v, bs(s).*.can_activate_pull),
        7 => c.g_value_set_int64(v, gst_audio_base_sink_get_drift_tolerance(s)),
        6 => c.g_value_set_uint64(v, gst_audio_base_sink_get_alignment_threshold(s)),
        8 => c.g_value_set_uint64(v, gst_audio_base_sink_get_discont_wait(s)),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 900),
    }
}

fn setCaps(b: [*c]BSink, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = of(b);
    if (s.*.ringbuffer == null) return 0;
    const spec: *c.GstAudioRingBufferSpec = @ptrCast(&s.*.ringbuffer.*.spec);
    if (spec.caps != null and c.gst_caps_is_equal(spec.caps, caps) != 0) return 1;
    const now = c.gst_clock_get_time(s.*.provided_clock);
    const internal = c.gst_clock_get_internal_time(s.*.provided_clock);
    _ = rb.gst_audio_ring_buffer_pause(s.*.ringbuffer);
    _ = rb.gst_audio_ring_buffer_activate(s.*.ringbuffer, 0);
    _ = rb.gst_audio_ring_buffer_release(s.*.ringbuffer);
    spec.buffer_time = s.*.buffer_time;
    spec.latency_time = s.*.latency_time;
    if (rb.gst_audio_ring_buffer_parse_caps(spec, caps) == 0) {
        formatError(s, "cannot parse audio format.", 995, "gst_audio_base_sink_setcaps");
        return 0;
    }
    if (rb.gst_audio_ring_buffer_acquire(s.*.ringbuffer, spec) == 0) return 0;
    if (selfClock(s)) clock.gst_audio_clock_reset(@ptrCast(@alignCast(s.*.provided_clock)), 0);
    resetSync(s);
    reportDiscont(s, c.GST_AUDIO_BASE_SINK_DISCONT_REASON_NEW_CAPS);
    if (b.*.pad_mode == c.GST_PAD_MODE_PUSH) _ = rb.gst_audio_ring_buffer_activate(s.*.ringbuffer, 1);
    var num: u64 = 0;
    var den: u64 = 0;
    c.gst_clock_get_calibration(s.*.provided_clock, null, null, &num, &den);
    c.gst_clock_set_calibration(s.*.provided_clock, internal, now, num, den);
    spec.latency_time = c.gst_util_uint64_scale(@bitCast(@as(i64, spec.segsize)), c.GST_SECOND / c.GST_USECOND, @bitCast(@as(i64, spec.info.rate *% spec.info.bpf)));
    spec.buffer_time = @as(u64, @bitCast(@as(i64, spec.segtotal))) *% spec.latency_time;
    _ = c.gst_element_post_message(@ptrCast(b), c.gst_message_new_latency(@ptrCast(b)));
    return 1;
}

fn fixate(b: [*c]BSink, caps_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const caps: [*c]c.GstCaps = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(caps_in))));
    const st = c.gst_caps_get_structure(caps, 0);
    _ = c.gst_structure_fixate_field_nearest_int(st, "rate", 44100);
    _ = c.gst_structure_fixate_field_nearest_int(st, "channels", 2);
    _ = c.gst_structure_fixate_field_nearest_int(st, "width", 16);
    if (c.gst_structure_has_field(st, "depth") != 0) {
        var width: c.gint = 0;
        _ = c.gst_structure_get_int(st, "width", &width);
        _ = c.gst_structure_fixate_field_nearest_int(st, "depth", (width + 7) & ~@as(c.gint, 7));
    }
    if (c.gst_structure_has_field(st, "signed") != 0) _ = c.gst_structure_fixate_field_boolean(st, "signed", 1);
    if (c.gst_structure_has_field(st, "endianness") != 0) _ = c.gst_structure_fixate_field_nearest_int(st, "endianness", c.G_BYTE_ORDER);
    return parent.?.fixate.?(b, caps);
}

fn resetSync(s: [*c]Sink) void {
    s.*.next_sample = NONE;
    const p = priv(s);
    p.eos_time = NONE;
    p.discont_time = NONE;
    p.avg_skew = -1;
    p.last_align = 0;
}

fn getTimes(_: [*c]BSink, _: [*c]c.GstBuffer, start: [*c]c.GstClockTime, end: [*c]c.GstClockTime) callconv(.c) void {
    start.* = NONE;
    end.* = NONE;
}

fn forceStart(s: [*c]Sink) void {
    @atomicStore(c.gint, &s.*.eos_rendering, 1, .seq_cst);
    _ = rb.gst_audio_ring_buffer_start(s.*.ringbuffer);
    @atomicStore(c.gint, &s.*.eos_rendering, 0, .seq_cst);
}

fn drain(s: [*c]Sink) c.GstFlowReturn {
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (s.*.ringbuffer == null or s.*.ringbuffer.*.spec.info.rate == 0) return ret;
    @atomicStore(c.gint, &s.*.eos_rendering, 1, .seq_cst);
    if (rb.gst_audio_ring_buffer_is_acquired(s.*.ringbuffer) != 0) _ = rb.gst_audio_ring_buffer_start(s.*.ringbuffer);
    if (priv(s).eos_time != NONE) ret = c.gst_base_sink_wait(bs(s), priv(s).eos_time, null);
    @atomicStore(c.gint, &s.*.eos_rendering, 0, .seq_cst);
    return ret;
}

fn waitEvent(b: [*c]BSink, ev: [*c]c.GstEvent) callconv(.c) c.GstFlowReturn {
    const s = of(b);
    var clear = false;
    if (ev.*.type == c.GST_EVENT_EOS or ev.*.type == c.GST_EVENT_GAP) {
        if (rb.gst_audio_ring_buffer_is_acquired(s.*.ringbuffer) == 0) {
            const dbg = c.g_strdup_printf("Sink not negotiated before %s event.", c.gst_event_type_get_name(ev.*.type));
            el.messageAt(s, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_FORMAT, null, dbg, PATH, "gst_audio_base_sink_wait_event", 1117, null);
            return c.GST_FLOW_ERROR;
        }
        forceStart(s);
        @atomicStore(c.gint, &s.*.eos_rendering, 1, .seq_cst);
        clear = true;
    }
    var ret = parent.?.wait_event.?(b, ev);
    if (ret == c.GST_FLOW_OK and ev.*.type == c.GST_EVENT_EOS) ret = drain(s);
    if (clear) @atomicStore(c.gint, &s.*.eos_rendering, 0, .seq_cst);
    return ret;
}

fn event(b: [*c]BSink, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = of(b);
    switch (ev.*.type) {
        c.GST_EVENT_FLUSH_START => if (s.*.ringbuffer != null) rb.gst_audio_ring_buffer_set_flushing(s.*.ringbuffer, 1),
        c.GST_EVENT_FLUSH_STOP => {
            resetSync(s);
            reportDiscont(s, c.GST_AUDIO_BASE_SINK_DISCONT_REASON_FLUSH);
            if (s.*.ringbuffer != null) rb.gst_audio_ring_buffer_set_flushing(s.*.ringbuffer, 0);
        },
        else => {},
    }
    return parent.?.event.?(b, ev);
}

fn preroll(b: [*c]BSink, _: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = of(b);
    if (rb.gst_audio_ring_buffer_is_acquired(s.*.ringbuffer) == 0) {
        formatError(s, "sink not negotiated.", 1193, "gst_audio_base_sink_preroll");
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    return c.GST_FLOW_OK;
}

fn getOffset(s: [*c]Sink) u64 {
    var sample = s.*.next_sample;
    if (sample == NONE) sample = 0;
    const sps: u64 = @bitCast(@as(i64, s.*.ringbuffer.*.samples_per_seg));
    const writeseg = sample / sps;
    const segdone = rb.gst_audio_ring_buffer_get_segdone(s.*.ringbuffer) -% rb.gst_audio_ring_buffer_get_segbase(s.*.ringbuffer);
    const diff: i64 = @bitCast(writeseg -% segdone);
    if (diff < 0) sample = (segdone +% 1) *% sps;
    return sample;
}

fn convertExternal(external_in: u64, cinternal: u64, cexternal: u64, num: u64, den: u64) u64 {
    if (external_in >= cexternal) return c.gst_util_uint64_scale(external_in - cexternal, den, num) +% cinternal;
    const e = c.gst_util_uint64_scale(cexternal - external_in, den, num);
    return if (cinternal > e) cinternal - e else 0;
}

const Cal = struct { ci: u64 = 0, ce: u64 = 0, num: u64 = 0, den: u64 = 0 };

fn calibration(s: [*c]Sink) Cal {
    var k = Cal{};
    c.gst_clock_get_calibration(s.*.provided_clock, &k.ci, &k.ce, &k.num, &k.den);
    return k;
}

fn finish(k: Cal, start: u64, stop: u64, ss: *u64, sst: *u64) void {
    ss.* = convertExternal(start, k.ci, k.ce, k.num, k.den);
    sst.* = convertExternal(stop, k.ci, k.ce, k.num, k.den);
}

fn times(s: [*c]Sink, k: Cal) [2]u64 {
    var etime = c.gst_clock_get_time(elementClock(s));
    var itime = clock.gst_audio_clock_get_time(@ptrCast(@alignCast(s.*.provided_clock)));
    itime = clock.gst_audio_clock_adjust(@ptrCast(@alignCast(s.*.provided_clock)), itime);
    etime = if (etime > k.ce) etime - k.ce else 0;
    itime = if (itime > k.ci) itime - k.ci else 0;
    return .{ etime, itime };
}

fn applyDrift(s: [*c]Sink, k: *Cal, drift: i64, positive: bool) void {
    const driftsamples: c.gint = @truncate(@divTrunc(@as(i64, s.*.ringbuffer.*.spec.info.rate) *% drift, @as(i64, c.GST_SECOND)));
    const la = priv(s).last_align;
    if (positive) {
        if (la < 0 or la > driftsamples) s.*.next_sample = NONE;
    } else if (la > 0 or -la > driftsamples) s.*.next_sample = NONE;
    c.gst_clock_set_calibration(s.*.provided_clock, k.ci, k.ce, k.num, k.den);
}

fn slaving(s: [*c]Sink, start: u64, stop: u64, ss: *u64, sst: *u64) void {
    const p = priv(s);
    switch (p.slave_method) {
        c.GST_AUDIO_BASE_SINK_SLAVE_RESAMPLE => {
            var k = calibration(s);
            if (k.num == 0) {
                k.num = 1;
                k.den = 1;
            }
            finish(k, start, stop, ss, sst);
        },
        c.GST_AUDIO_BASE_SINK_SLAVE_SKEW => {
            var k = calibration(s);
            const t = times(s, k);
            const skew: i64 = @as(i64, @bitCast(t[1])) -% @as(i64, @bitCast(t[0]));
            if (p.avg_skew == -1) p.avg_skew = skew else p.avg_skew = @divTrunc(31 *% p.avg_skew +% skew, 32);
            const mdrift2: i64 = @divTrunc(@as(i64, @bitCast(p.drift_tolerance)) *% 1000, 2);
            if (p.avg_skew > mdrift2) {
                const drift: i64 = if (@as(i64, @bitCast(k.ce)) > p.avg_skew) p.avg_skew else @bitCast(k.ce);
                k.ce -%= @bitCast(drift);
                p.avg_skew -%= drift;
                applyDrift(s, &k, drift, true);
            } else if (p.avg_skew < -mdrift2) {
                const drift = -p.avg_skew;
                k.ce +%= @bitCast(drift);
                p.avg_skew = 0;
                applyDrift(s, &k, drift, false);
            }
            finish(k, start, stop, ss, sst);
        },
        c.GST_AUDIO_BASE_SINK_SLAVE_NONE => finish(calibration(s), start, stop, ss, sst),
        c.GST_AUDIO_BASE_SINK_SLAVE_CUSTOM => {
            var k = calibration(s);
            const t = times(s, k);
            var requested: i64 = 0;
            if (p.custom_cb != null) p.custom_cb.?(s, t[0], t[1], &requested, 0, p.custom_data);
            if (requested > 0) {
                const drift: i64 = if (@as(i64, @bitCast(k.ce)) > requested) requested else @bitCast(k.ce);
                k.ce -%= @bitCast(drift);
                applyDrift(s, &k, drift, true);
            } else if (requested < 0) {
                const drift = -requested;
                k.ce +%= @bitCast(drift);
                applyDrift(s, &k, drift, false);
            }
            finish(k, start, stop, ss, sst);
        },
        else => c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "unknown slaving method %d", p.slave_method),
    }
}

fn syncLatency(b: [*c]BSink, obj: [*c]c.GstMiniObject) c.GstFlowReturn {
    const s = of(b);
    const clk = elementClock(s);
    if (clk == null or clk == s.*.provided_clock) return c.GST_FLOW_OK;
    unlock(s);
    var time: u64 = 0;
    var status: c.GstClockReturn = 0;
    var jitter: i64 = 0;
    while (true) {
        if (c.gst_base_sink_do_preroll(b, obj) != c.GST_FLOW_OK) {
            lock(s);
            return c.GST_FLOW_FLUSHING;
        }
        lock(s);
        time = priv(s).us_latency;
        unlock(s);
        const rd = c.gst_base_sink_get_render_delay(b);
        time = if (time > rd) time - rd else 0;
        status = c.gst_base_sink_wait_clock(b, time, &jitter);
        if (status == c.GST_CLOCK_BADTIME) break;
        if (b.*.flushing != 0) {
            lock(s);
            return c.GST_FLOW_FLUSHING;
        }
        if (status != c.GST_CLOCK_UNSCHEDULED) break;
    }
    var itime = clock.gst_audio_clock_get_time(@ptrCast(@alignCast(s.*.provided_clock)));
    itime = clock.gst_audio_clock_adjust(@ptrCast(@alignCast(s.*.provided_clock)), itime);
    lock(s);
    var etime = @as(u64, @bitCast(@as([*c]c.GstElement, @ptrCast(s)).*.base_time)) +% time;
    if (status == c.GST_CLOCK_EARLY) etime +%= @bitCast(jitter);
    forceStart(s);
    var num: u64 = 0;
    var den: u64 = 0;
    c.gst_clock_get_calibration(s.*.provided_clock, null, null, &num, &den);
    c.gst_clock_set_calibration(s.*.provided_clock, itime, etime, num, den);
    if (priv(s).slave_method == c.GST_AUDIO_BASE_SINK_SLAVE_RESAMPLE) _ = c.gst_clock_set_master(s.*.provided_clock, clk);
    resetSync(s);
    reportDiscont(s, c.GST_AUDIO_BASE_SINK_DISCONT_REASON_SYNC_LATENCY);
    return c.GST_FLOW_OK;
}

fn absdiff(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

fn getAlignment(s: [*c]Sink, sample_offset: u64) i64 {
    const r = s.*.ringbuffer;
    const p = priv(s);
    const segdone = rb.gst_audio_ring_buffer_get_segdone(r) -% rb.gst_audio_ring_buffer_get_segbase(r);
    const samples_done: i64 = @as(i64, @bitCast(segdone)) *% @as(i64, r.*.samples_per_seg);
    const headroom: i64 = @as(i64, @bitCast(sample_offset)) -% samples_done;
    var allow = true;
    var discont = false;
    var al: i64 = @bitCast(s.*.next_sample -% sample_offset);
    const sample_diff: i64 = if (al < 0) -%al else al;
    const rate = r.*.spec.info.rate;
    const max_diff: i64 = @bitCast(c.gst_util_uint64_scale_int(p.alignment_threshold, rate, c.GST_SECOND));
    if (sample_diff > headroom and al < 0) allow = false;
    if (sample_diff >= max_diff) {
        if (p.discont_wait > 0) {
            const time = c.gst_util_uint64_scale_int(sample_offset, c.GST_SECOND, rate);
            const expected = c.gst_util_uint64_scale_int(s.*.next_sample, c.GST_SECOND, rate);
            if (p.discont_time == NONE) {
                if (absdiff(expected, time) >= p.discont_wait) discont = true else p.discont_time = expected;
            } else if (absdiff(time, p.discont_time) >= p.discont_wait) {
                discont = true;
                p.discont_time = NONE;
            }
        } else discont = true;
    } else if (p.discont_time != NONE) p.discont_time = NONE;
    if (discont or !allow) {
        al = 0;
        reportDiscont(s, c.GST_AUDIO_BASE_SINK_DISCONT_REASON_ALIGNMENT);
    }
    return al;
}

fn render(b: [*c]BSink, buf_in: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = of(b);
    const k = gtype.classPeek(Class, s);
    const r = s.*.ringbuffer;
    var buf = buf_in;
    var out: [*c]c.GstBuffer = null;
    defer if (out != null) c.gst_mini_object_unref(@ptrCast(out));
    if (rb.gst_audio_ring_buffer_is_acquired(r) == 0) {
        formatError(s, "sink not negotiated.", 2243, "gst_audio_base_sink_render");
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    lock(s);
    const base_time: u64 = @bitCast(@as([*c]c.GstElement, @ptrCast(s)).*.base_time);
    if (priv(s).sync_latency != 0) {
        const ret = syncLatency(b, @ptrCast(buf));
        unlock(s);
        if (ret != c.GST_FLOW_OK) return ret;
        priv(s).sync_latency = 0;
    } else unlock(s);
    if (k.payload) |pf| {
        out = pf(s, buf);
        if (out == null) {
            formatError(s, "failed to payload.", 2236, "gst_audio_base_sink_render");
            return c.GST_FLOW_ERROR;
        }
        buf = out;
    }
    const bpf = r.*.spec.info.bpf;
    const rate = r.*.spec.info.rate;
    const size = c.gst_buffer_get_size(buf);
    if (size % @as(usize, @intCast(bpf)) != 0) {
        el.messageAt(s, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_WRONG_TYPE, null, c.g_strdup("sink received buffer of wrong size."), PATH, "gst_audio_base_sink_render", 2250, null);
        return c.GST_FLOW_ERROR;
    }
    var samples: c.guint = @intCast(size / @as(usize, @intCast(bpf)));
    var time = buf.*.pts;
    if (b.*.segment.flags & c.GST_SEGMENT_FLAG_TRICKMODE_NO_AUDIO != 0 or buf.*.mini_object.flags & c.GST_BUFFER_FLAG_GAP != 0) {
        const dur = c.gst_util_uint64_scale_int(samples, c.GST_SECOND, rate);
        const gev = c.gst_event_new_gap(time, dur);
        const ret = gtype.classPeek(BClass, s).wait_event.?(b, gev);
        c.gst_mini_object_unref(@ptrCast(gev));
        s.*.next_sample = NONE;
        return ret;
    }
    var offset: usize = 0;
    var render_start: u64 = 0;
    var render_stop: u64 = 0;
    var stop: u64 = NONE;
    var sample_offset: u64 = 0;
    no_align: {
        if (time == NONE) {
            render_start = getOffset(s);
            render_stop = render_start +% samples;
            break :no_align;
        }
        stop = time +% c.gst_util_uint64_scale_int(samples, c.GST_SECOND, rate);
        var clip = std.mem.zeroes(c.GstSegment);
        clip.format = c.GST_FORMAT_TIME;
        clip.start = b.*.segment.start;
        clip.stop = b.*.segment.stop;
        clip.duration = NONE;
        const latency = c.gst_base_sink_get_latency(b);
        const ts_offset = c.gst_base_sink_get_ts_offset(b);
        const render_delay = c.gst_base_sink_get_render_delay(b);
        const sync_offset: i64 = ts_offset -% @as(i64, @bitCast(render_delay)) +% @as(i64, @bitCast(latency));
        if (sync_offset < 0) {
            clip.start +%= @bitCast(-sync_offset);
            if (clip.stop != NONE) clip.stop +%= @bitCast(-sync_offset);
        }
        var ctime: u64 = 0;
        var cstop: u64 = 0;
        if (c.gst_segment_clip(&clip, c.GST_FORMAT_TIME, time, stop, &ctime, &cstop) == 0) return c.GST_FLOW_OK;
        var diff: i64 = @bitCast(ctime -% time);
        if (diff > 0) {
            diff = @bitCast(c.gst_util_uint64_scale_int(@bitCast(diff), rate, c.GST_SECOND));
            samples -%= @truncate(@as(u64, @bitCast(diff)));
            offset +%= @as(usize, @bitCast(diff)) *% @as(usize, @intCast(bpf));
            time = ctime;
        }
        diff = @bitCast(stop -% cstop);
        if (diff > 0) {
            diff = @bitCast(c.gst_util_uint64_scale_int(@bitCast(diff), rate, c.GST_SECOND));
            samples -%= @truncate(@as(u64, @bitCast(diff)));
            stop = cstop;
        }
        const clk = elementClock(b);
        const sync = clk != null and b.*.sync != 0;
        if (!sync) {
            render_start = getOffset(s);
            render_stop = render_start +% samples;
            break :no_align;
        }
        render_start = c.gst_segment_to_running_time(&b.*.segment, c.GST_FORMAT_TIME, time);
        render_stop = c.gst_segment_to_running_time(&b.*.segment, c.GST_FORMAT_TIME, stop);
        if (render_start == NONE or render_stop == NONE) return c.GST_FLOW_OK;
        priv(s).eos_time = if (b.*.segment.rate >= 0.0) render_stop else render_start;
        if (sync_offset != 0) {
            render_start +%= @bitCast(sync_offset);
            render_stop +%= @bitCast(sync_offset);
        }
        if (base_time != 0) {
            render_start +%= base_time;
            render_stop +%= base_time;
        }
        const slaved = clk != s.*.provided_clock;
        if (slaved) slaving(s, render_start, render_stop, &render_start, &render_stop) else finish(calibration(s), render_start, render_stop, &render_start, &render_stop);
        const toff = @as([*c]c.GstAudioClock, @ptrCast(@alignCast(s.*.provided_clock))).*.time_offset;
        if (toff != 0) {
            const t: u64 = @bitCast(toff);
            render_start = if (render_start > t) render_start - t else 0;
            render_stop = if (render_stop > t) render_stop - t else 0;
        }
        if (render_start == 0 and render_stop == 0) return c.GST_FLOW_OK;
        render_start = c.gst_util_uint64_scale_int(render_start, rate, c.GST_SECOND);
        render_stop = c.gst_util_uint64_scale_int(render_stop, rate, c.GST_SECOND);
        if (render_start == 0) {
            const nsamples: c.guint = @truncate(render_stop -% render_start);
            if (nsamples < samples) {
                const d = samples - nsamples;
                samples -= d;
                offset +%= @as(usize, d) * @as(usize, @intCast(bpf));
            }
        }
        if (b.*.segment.rate >= 0.0) {
            sample_offset = render_start;
            if (b.*.segment.rate == 1.0) render_stop = sample_offset +% samples;
        } else {
            sample_offset = render_stop;
            if (b.*.segment.rate == -1.0) render_start = sample_offset +% samples;
        }
        if (buf.*.mini_object.flags & (c.GST_BUFFER_FLAG_DISCONT | c.GST_BUFFER_FLAG_RESYNC) != 0) break :no_align;
        if (s.*.next_sample == NONE) break :no_align;
        const al = getAlignment(s, sample_offset);
        priv(s).last_align = al;
        render_start +%= @bitCast(al);
        if (slaved and priv(s).slave_method == c.GST_AUDIO_BASE_SINK_SLAVE_RESAMPLE) break :no_align;
        render_stop +%= @bitCast(al);
    }
    var out_samples: c.gint = @truncate(@as(i64, @bitCast(render_stop -% render_start)));
    sample_offset = if (b.*.segment.rate >= 0.0) render_start else render_stop;
    var accum: c.gint = 0;
    var align_next = true;
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buf, &info, c.GST_MAP_READ);
    while (true) {
        const written = rb.gst_audio_ring_buffer_commit(r, &sample_offset, info.data + offset, @bitCast(samples), out_samples, &accum);
        if (written == samples) break;
        const ret = c.gst_base_sink_wait_preroll(b);
        if (ret != c.GST_FLOW_OK) {
            c.gst_buffer_unmap(buf, &info);
            return ret;
        }
        align_next = false;
        if (out_samples > @as(c.gint, @bitCast(written))) {
            out_samples -= @bitCast(written);
            accum = 0;
        } else break;
        samples -%= written;
        offset +%= @as(usize, written) * @as(usize, @intCast(bpf));
    }
    c.gst_buffer_unmap(buf, &info);
    s.*.next_sample = if (align_next) sample_offset else NONE;
    if (stop != NONE and stop >= b.*.segment.stop) forceStart(s);
    return c.GST_FLOW_OK;
}

pub export fn gst_audio_base_sink_create_ringbuffer(s: [*c]Sink) [*c]c.GstAudioRingBuffer {
    const k = gtype.classPeek(Class, s);
    var buffer: [*c]c.GstAudioRingBuffer = null;
    if (k.create_ringbuffer) |f| buffer = f(s);
    if (buffer != null) _ = c.gst_object_set_parent(@ptrCast(buffer), @ptrCast(s));
    return buffer;
}

fn callback(rbuf: [*c]c.GstAudioRingBuffer, data: [*c]u8, len_in: c.guint, user: c.gpointer) callconv(.c) void {
    const b = bs(user);
    const s = of(user);
    var len = len_in;
    el.streamLock(b.*.sinkpad);
    defer el.streamUnlock(b.*.sinkpad);
    var buf: [*c]c.GstBuffer = null;
    const ret = c.gst_pad_pull_range(b.*.sinkpad, b.*.segment.position, len, &buf);
    if (ret != c.GST_FLOW_OK) {
        if (ret == c.GST_FLOW_EOS) {
            _ = drain(s);
            _ = rb.gst_audio_ring_buffer_pause(rbuf);
            _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_eos(@ptrCast(s)));
        } else _ = rb.gst_audio_ring_buffer_pause(rbuf);
        return;
    }
    c.g_mutex_lock(&b.*.preroll_lock);
    defer c.g_mutex_unlock(&b.*.preroll_lock);
    if (b.*.flushing != 0 or c.gst_base_sink_do_preroll(b, @ptrCast(buf)) != c.GST_FLOW_OK) {
        _ = rb.gst_audio_ring_buffer_pause(rbuf);
        return;
    }
    const size = c.gst_buffer_get_size(buf);
    if (len != size) len = @intCast(@min(size, len));
    b.*.segment.position +%= len;
    _ = c.gst_buffer_extract(buf, 0, data, len);
}

fn activatePull(b: [*c]BSink, active: c.gboolean) callconv(.c) c.gboolean {
    const s = of(b);
    if (active != 0) {
        rb.gst_audio_ring_buffer_set_callback(s.*.ringbuffer, callback, s);
        return rb.gst_audio_ring_buffer_activate(s.*.ringbuffer, 1);
    }
    rb.gst_audio_ring_buffer_set_callback(s.*.ringbuffer, null, null);
    return rb.gst_audio_ring_buffer_activate(s.*.ringbuffer, 0);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = of(e);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            clock.gst_audio_clock_reset(@ptrCast(@alignCast(s.*.provided_clock)), 0);
            const r = gst_audio_base_sink_create_ringbuffer(s);
            if (r == null) return c.GST_STATE_CHANGE_FAILURE;
            lock(s);
            s.*.ringbuffer = r;
            unlock(s);
            if (rb.gst_audio_ring_buffer_open_device(s.*.ringbuffer) == 0) {
                lock(s);
                c.gst_object_unparent(@ptrCast(s.*.ringbuffer));
                s.*.ringbuffer = null;
                unlock(s);
                return c.GST_STATE_CHANGE_FAILURE;
            }
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            resetSync(s);
            rb.gst_audio_ring_buffer_set_flushing(s.*.ringbuffer, 0);
            rb.gst_audio_ring_buffer_may_start(s.*.ringbuffer, 0);
            if (selfClock(s)) _ = c.gst_element_post_message(e, c.gst_message_new_clock_provide(@ptrCast(e), s.*.provided_clock, 1));
        },
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => {
            lock(s);
            priv(s).sync_latency = 1;
            const eos = bs(s).*.eos;
            unlock(s);
            rb.gst_audio_ring_buffer_may_start(s.*.ringbuffer, 1);
            if (bs(s).*.pad_mode == c.GST_PAD_MODE_PULL or @atomicLoad(c.gint, &s.*.eos_rendering, .seq_cst) != 0 or eos != 0) _ = rb.gst_audio_ring_buffer_start(s.*.ringbuffer);
        },
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => {
            rb.gst_audio_ring_buffer_may_start(s.*.ringbuffer, 0);
            _ = rb.gst_audio_ring_buffer_pause(s.*.ringbuffer);
            lock(s);
            priv(s).sync_latency = 0;
            unlock(s);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            if (selfClock(s)) _ = c.gst_element_post_message(e, c.gst_message_new_clock_lost(@ptrCast(e), s.*.provided_clock));
            rb.gst_audio_ring_buffer_set_flushing(s.*.ringbuffer, 1);
        },
        else => {},
    }
    const ret = @as(*c.GstElementClass, @ptrCast(parent)).change_state.?(e, t);
    switch (t) {
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => _ = c.gst_clock_set_master(s.*.provided_clock, null),
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            _ = rb.gst_audio_ring_buffer_activate(s.*.ringbuffer, 0);
            _ = rb.gst_audio_ring_buffer_release(s.*.ringbuffer);
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            _ = rb.gst_audio_ring_buffer_activate(s.*.ringbuffer, 0);
            _ = rb.gst_audio_ring_buffer_release(s.*.ringbuffer);
            _ = rb.gst_audio_ring_buffer_close_device(s.*.ringbuffer);
            lock(s);
            c.gst_object_unparent(@ptrCast(s.*.ringbuffer));
            s.*.ringbuffer = null;
            unlock(s);
        },
        else => {},
    }
    return ret;
}
