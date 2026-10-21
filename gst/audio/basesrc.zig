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

const Src = c.GstAudioBaseSrc;
const Class = c.GstAudioBaseSrcClass;
const BSrc = c.GstBaseSrc;
const BClass = c.GstBaseSrcClass;
const NONE: u64 = std.math.maxInt(u64);
const MS: u64 = @intCast(c.GST_MSECOND);
const PATH = "../gst-libs/gst/audio/gstaudiobasesrc.c";

const Private = extern struct {
    slave_method: c.GstAudioBaseSrcSlaveMethod,
};

const DEFAULT_BUFFER_TIME: i64 = 200000;
const DEFAULT_LATENCY_TIME: i64 = 10000;

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*BClass = null;

fn of(p: anytype) [*c]Src {
    return @ptrCast(@alignCast(p));
}

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(of(p).*.priv));
}

fn bsrc(p: anytype) [*c]BSrc {
    return @ptrCast(@alignCast(p));
}

fn isSrc(p: anytype) bool {
    return gtype.instanceOf(p, gst_audio_base_src_get_type());
}

fn lock(p: anytype) void {
    el.lock(p);
}

fn unlock(p: anytype) void {
    el.unlock(p);
}

fn pspecs(oc: *c.GObjectClass) void {
    const F = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    const R = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_int64("buffer-time", "Buffer Time", "Size of audio buffer in microseconds. This is the maximum amount of data that is buffered in the device and the maximum latency that the source reports. This value might be ignored by the element if necessary; see \"actual-buffer-time\"", 1, std.math.maxInt(i64), DEFAULT_BUFFER_TIME, F));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_int64("latency-time", "Latency Time", "The minimum amount of data to read in each iteration in microseconds. This is the minimum latency that the source reports. This value might be ignored by the element if necessary; see \"actual-latency-time\"", 1, std.math.maxInt(i64), DEFAULT_LATENCY_TIME, F));
    c.g_object_class_install_property(oc, 3, c.g_param_spec_int64("actual-buffer-time", "Actual Buffer Time", "Actual configured size of audio buffer in microseconds", -1, std.math.maxInt(i64), -1, R));
    c.g_object_class_install_property(oc, 4, c.g_param_spec_int64("actual-latency-time", "Actual Latency Time", "Actual configured audio latency in microseconds", -1, std.math.maxInt(i64), -1, R));
    c.g_object_class_install_property(oc, 5, c.g_param_spec_boolean("provide-clock", "Provide Clock", "Provide a clock to be used as the global pipeline clock", 1, F));
    c.g_object_class_install_property(oc, 6, c.g_param_spec_enum("slave-method", "Slave Method", "Algorithm used to match the rate of the masterclock", enums.gst_audio_base_src_slave_method_get_type(), c.GST_AUDIO_BASE_SRC_SLAVE_SKEW, F));
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
    ec.post_message = postMessage;
    bc.set_caps = setCaps;
    bc.event = event;
    bc.query = query;
    bc.get_times = getTimes;
    bc.create = create;
    bc.fixate = fixate;
    _ = c.g_type_class_ref(clock.gst_audio_clock_get_type());
    _ = c.g_type_class_ref(rb.gst_audio_ring_buffer_get_type());
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = of(inst);
    s.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    s.*.buffer_time = DEFAULT_BUFFER_TIME;
    s.*.latency_time = DEFAULT_LATENCY_TIME;
    el.setFlag(s, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK);
    priv(s).slave_method = c.GST_AUDIO_BASE_SRC_SLAVE_SKEW;
    bsrc(s).*.blocksize = 0;
    s.*.clock = clock.gst_audio_clock_new("GstAudioSrcClock", @ptrCast(&getTime), s, null);
    c.gst_base_src_set_live(bsrc(s), 1);
    c.gst_base_src_set_format(bsrc(s), c.GST_FORMAT_TIME);
}

pub export fn gst_audio_base_src_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_push_src_get_type, "GstAudioBaseSrc", Class, Src, classInit, init, 0);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            _ = c._gst_debug_category_new("audiobasesrc", 0, "audiobasesrc element");
            return t;
        }
    }.f);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = of(o);
    lock(s);
    if (s.*.clock != null) {
        clock.gst_audio_clock_invalidate(@ptrCast(@alignCast(s.*.clock)));
        c.gst_object_unref(s.*.clock);
        s.*.clock = null;
    }
    if (s.*.ringbuffer != null) {
        c.gst_object_unparent(@ptrCast(s.*.ringbuffer));
        s.*.ringbuffer = null;
    }
    unlock(s);
    @as(*c.GObjectClass, @ptrCast(parent)).dispose.?(o);
}

fn provideClock(e: [*c]c.GstElement) callconv(.c) [*c]c.GstClock {
    const s = of(e);
    if (s.*.ringbuffer == null or rb.gst_audio_ring_buffer_is_flushing(s.*.ringbuffer) != 0) return null;
    lock(s);
    defer unlock(s);
    if (el.flags(s) & c.GST_ELEMENT_FLAG_PROVIDE_CLOCK == 0) return null;
    return @ptrCast(@alignCast(c.gst_object_ref(s.*.clock)));
}

fn getTime(_: [*c]c.GstClock, s: [*c]Src) callconv(.c) c.GstClockTime {
    const r = s.*.ringbuffer;
    if (r == null) return NONE;
    const rate = r.*.spec.info.rate;
    if (rate == 0) return NONE;
    const samples = rb.gst_audio_ring_buffer_samples_done(r) + rb.gst_audio_ring_buffer_delay(r);
    return c.gst_util_uint64_scale_int(samples, c.GST_SECOND, rate);
}

fn selfClock(s: [*c]Src) bool {
    const k = s.*.clock;
    return k != null and gtype.instanceOf(k, clock.gst_audio_clock_get_type()) and @as([*c]c.GstAudioClock, @ptrCast(@alignCast(k))).*.func == @as(c.GstAudioClockGetTimeFunc, @ptrCast(&getTime));
}

pub export fn gst_audio_base_src_set_provide_clock(s: [*c]Src, provide: c.gboolean) void {
    if (!check.that(isSrc(s), "gst_audio_base_src_set_provide_clock", "GST_IS_AUDIO_BASE_SRC (src)")) return;
    lock(s);
    if (provide != 0) el.setFlag(s, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK) else el.unsetFlag(s, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK);
    unlock(s);
}

pub export fn gst_audio_base_src_get_provide_clock(s: [*c]Src) c.gboolean {
    if (!check.that(isSrc(s), "gst_audio_base_src_get_provide_clock", "GST_IS_AUDIO_BASE_SRC (src)")) return 0;
    lock(s);
    defer unlock(s);
    return @intFromBool(el.flags(s) & c.GST_ELEMENT_FLAG_PROVIDE_CLOCK != 0);
}

pub export fn gst_audio_base_src_set_slave_method(s: [*c]Src, method: c.GstAudioBaseSrcSlaveMethod) void {
    if (!check.that(isSrc(s), "gst_audio_base_src_set_slave_method", "GST_IS_AUDIO_BASE_SRC (src)")) return;
    lock(s);
    priv(s).slave_method = method;
    unlock(s);
}

pub export fn gst_audio_base_src_get_slave_method(s: [*c]Src) c.GstAudioBaseSrcSlaveMethod {
    if (!check.that(isSrc(s), "gst_audio_base_src_get_slave_method", "GST_IS_AUDIO_BASE_SRC (src)")) return @bitCast(@as(c_int, -1));
    lock(s);
    defer unlock(s);
    return priv(s).slave_method;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    switch (id) {
        1 => s.*.buffer_time = @bitCast(c.g_value_get_int64(v)),
        2 => s.*.latency_time = @bitCast(c.g_value_get_int64(v)),
        5 => gst_audio_base_src_set_provide_clock(s, c.g_value_get_boolean(v)),
        6 => gst_audio_base_src_set_slave_method(s, @bitCast(c.g_value_get_enum(v))),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 444),
    }
}

fn actual(s: [*c]Src, comptime buffer: bool) i64 {
    lock(s);
    defer unlock(s);
    const r = s.*.ringbuffer;
    if (r == null or r.*.acquired == 0) return -1;
    return @bitCast(if (buffer) r.*.spec.buffer_time else r.*.spec.latency_time);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    switch (id) {
        1 => c.g_value_set_int64(v, @bitCast(s.*.buffer_time)),
        2 => c.g_value_set_int64(v, @bitCast(s.*.latency_time)),
        3 => c.g_value_set_int64(v, actual(s, true)),
        4 => c.g_value_set_int64(v, actual(s, false)),
        5 => c.g_value_set_boolean(v, gst_audio_base_src_get_provide_clock(s)),
        6 => c.g_value_set_enum(v, @bitCast(gst_audio_base_src_get_slave_method(s))),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 487),
    }
}

fn fixate(b: [*c]BSrc, caps_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const caps = c.gst_caps_make_writable(caps_in);
    const st = c.gst_caps_get_structure(caps, 0);
    _ = c.gst_structure_fixate_field_nearest_int(st, "rate", 44100);
    _ = c.gst_structure_fixate_field_nearest_int(st, "channels", 2);
    _ = c.gst_structure_fixate_field_string(st, "format", "S16LE");
    return parent.?.fixate.?(b, caps);
}

fn setCaps(b: [*c]BSrc, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = of(b);
    const r = s.*.ringbuffer;
    const spec: [*c]c.GstAudioRingBufferSpec = @ptrCast(&r.*.spec);
    if (rb.gst_audio_ring_buffer_is_acquired(r) != 0 and c.gst_caps_is_equal(spec.*.caps, caps) != 0) return 1;
    _ = rb.gst_audio_ring_buffer_release(r);
    spec.*.buffer_time = @bitCast(s.*.buffer_time);
    spec.*.latency_time = @bitCast(s.*.latency_time);
    lock(s);
    if (rb.gst_audio_ring_buffer_parse_caps(spec, caps) == 0) {
        unlock(s);
        return 0;
    }
    const bpf: u64 = @intCast(spec.*.info.bpf);
    const rate: u64 = @intCast(spec.*.info.rate);
    const lt: u64 = @bitCast(spec.*.latency_time);
    var segsize = rate * bpf * lt / MS;
    segsize -= segsize % bpf;
    spec.*.segsize = @truncate(@as(i64, @bitCast(segsize)));
    const bt: u64 = @bitCast(spec.*.buffer_time);
    spec.*.segtotal = @truncate(@as(i64, @bitCast(bt / lt)));
    unlock(s);
    rb.gst_audio_ring_buffer_debug_spec_buff(spec);
    if (rb.gst_audio_ring_buffer_acquire(r, spec) == 0) return 0;
    const seg: u64 = @bitCast(@as(i64, spec.*.segsize));
    const total: u64 = @bitCast(@as(i64, spec.*.segtotal));
    spec.*.latency_time = @bitCast(seg * MS / (rate * bpf));
    spec.*.buffer_time = @bitCast(total * seg * MS / (rate * bpf));
    rb.gst_audio_ring_buffer_debug_spec_buff(spec);
    c.g_object_notify(@ptrCast(s), "actual-buffer-time");
    c.g_object_notify(@ptrCast(s), "actual-latency-time");
    _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_latency(@ptrCast(s)));
    return 1;
}

fn getTimes(_: [*c]BSrc, _: [*c]c.GstBuffer, start: [*c]c.GstClockTime, end: [*c]c.GstClockTime) callconv(.c) void {
    start.* = NONE;
    end.* = NONE;
}

fn query(b: [*c]BSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = of(b);
    switch (q.*.type) {
        c.GST_QUERY_LATENCY => {
            lock(s);
            const r = s.*.ringbuffer;
            if (r == null or r.*.spec.info.rate == 0) {
                unlock(s);
                return 0;
            }
            const div = r.*.spec.info.rate * r.*.spec.info.bpf;
            const lo = c.gst_util_uint64_scale_int(@intCast(r.*.spec.segsize), c.GST_SECOND, div);
            const hi = c.gst_util_uint64_scale_int(@intCast(r.*.spec.segtotal * r.*.spec.segsize), c.GST_SECOND, div);
            unlock(s);
            c.gst_query_set_latency(q, 1, lo, hi);
            return 1;
        },
        c.GST_QUERY_SCHEDULING => {
            c.gst_query_set_scheduling(q, c.GST_SCHEDULING_FLAG_SEQUENTIAL, 1, -1, 0);
            c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PULL);
            c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
            return 1;
        },
        else => return parent.?.query.?(b, q),
    }
}

fn event(b: [*c]BSrc, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = of(b);
    switch (e.*.type) {
        c.GST_EVENT_FLUSH_START => {
            _ = rb.gst_audio_ring_buffer_pause(s.*.ringbuffer);
            rb.gst_audio_ring_buffer_clear_all(s.*.ringbuffer);
        },
        c.GST_EVENT_FLUSH_STOP => {
            s.*.next_sample = NONE;
            rb.gst_audio_ring_buffer_clear_all(s.*.ringbuffer);
        },
        c.GST_EVENT_SEEK => return 0,
        else => {},
    }
    return parent.?.event.?(b, e);
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn readOffset(s: [*c]Src) u64 {
    const r = s.*.ringbuffer;
    const sps: u64 = @intCast(r.*.samples_per_seg);
    const done: u64 = rb.gst_audio_ring_buffer_get_segdone(r) -% rb.gst_audio_ring_buffer_get_segbase(r);
    const next = s.*.next_sample;
    if (next == NONE) return done *% sps;
    const lag: i64 = @bitCast(done -% next / sps);
    return if (lag >= r.*.spec.segtotal) done *% sps else next;
}

fn skew(s: [*c]Src, k: [*c]c.GstClock, sample: u64, samples: u64, rate: c.gint, first_sample: bool, ts: *u64) void {
    const r = s.*.ringbuffer;
    const sps: u64 = @intCast(r.*.samples_per_seg);
    const written = rb.gst_audio_ring_buffer_get_segdone(r) -% rb.gst_audio_ring_buffer_get_segbase(r) -% 1;
    const running = c.gst_clock_get_time(k) -% @as(u64, @bitCast(@as([*c]c.GstElement, @ptrCast(s)).*.base_time));
    const now_seg = c.gst_util_uint64_scale_int(running, rate, c.GST_SECOND) / sps;
    const drift: i64 = @bitCast(now_seg -% written);
    if (drift < r.*.spec.segtotal and sample / sps != 0 and !first_sample) return;
    rb.gst_audio_ring_buffer_advance(r, @truncate(now_seg -% written));
    const at = (rb.gst_audio_ring_buffer_get_segdone(r) -% rb.gst_audio_ring_buffer_get_segbase(r)) *% sps;
    ts.* = c.gst_util_uint64_scale_int(at, c.GST_SECOND, rate);
    s.*.next_sample = at +% samples;
}

fn create(b: [*c]BSrc, offset: c.guint64, length_in: c.guint, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = of(b);
    const first_sample = s.*.next_sample == NONE;
    const r = s.*.ringbuffer;
    if (rb.gst_audio_ring_buffer_is_acquired(r) == 0) return c.GST_FLOW_FLUSHING;
    const bpf: c.guint = @intCast(r.*.spec.info.bpf);
    const rate = r.*.spec.info.rate;
    var length = length_in;
    if ((length == 0 and b.*.blocksize == 0) or length == std.math.maxInt(c.guint)) length = @intCast(r.*.spec.segsize) else length -= length % bpf;
    var sample: u64 = undefined;
    if (offset != NONE) {
        sample = offset / bpf;
        if (s.*.next_sample != NONE and sample != s.*.next_sample) {
            el.messageAt(s, c.GST_MESSAGE_ERROR, .resource, c.GST_RESOURCE_ERROR_SEEK, null, c.g_strdup_printf("resource can only be operated on sequentially but offset %lu was given", offset), PATH, "gst_audio_base_src_create", 1064, null);
            return c.GST_FLOW_ERROR;
        }
    } else sample = readOffset(s);
    const total: c.guint = length / bpf;
    var samples = total;
    var buf: [*c]c.GstBuffer = null;
    const ret = parent.?.alloc.?(b, offset, length, &buf);
    if (ret != c.GST_FLOW_OK) return ret;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buf, &map, c.GST_MAP_WRITE);
    var ptr: [*c]u8 = map.data;
    var rb_ts: u64 = NONE;
    var first = true;
    while (true) {
        var t: u64 = NONE;
        const got = rb.gst_audio_ring_buffer_read(r, sample, ptr, samples, &t);
        if (first and t != NONE) {
            first = false;
            rb_ts = t;
        }
        if (got == samples) break;
        if (@atomicLoad(c.gint, &r.*.state, .seq_cst) == c.GST_AUDIO_RING_BUFFER_STATE_ERROR) {
            c.gst_buffer_unmap(buf, &map);
            c.gst_buffer_unref(buf);
            return c.GST_FLOW_ERROR;
        }
        if (c.gst_base_src_wait_playing(b) != c.GST_FLOW_OK) {
            c.gst_buffer_unmap(buf, &map);
            c.gst_buffer_unref(buf);
            return c.GST_FLOW_FLUSHING;
        }
        sample += got;
        samples -= got;
        ptr += got * bpf;
    }
    c.gst_buffer_unmap(buf, &map);
    if (sample != s.*.next_sample and s.*.next_sample != NONE) {
        const text = c.g_strdup(c.g_dgettext("gst-plugins-base-1.0", "Can't record audio fast enough"));
        const debug = c.g_strdup_printf("Dropped %lu samples. This is most likely because downstream can't keep up and is consuming samples too slowly.", sample -% s.*.next_sample);
        el.messageAt(s, c.GST_MESSAGE_WARNING, .core, c.GST_CORE_ERROR_CLOCK, text, debug, PATH, "gst_audio_base_src_create", 851, null);
        buf.*.mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
    }
    s.*.next_sample = sample + samples;
    var ts = c.gst_util_uint64_scale_int(sample, c.GST_SECOND, rate);
    const duration = c.gst_util_uint64_scale_int(s.*.next_sample, c.GST_SECOND, rate) -% ts;
    lock(s);
    const k = @as([*c]c.GstElement, @ptrCast(s)).*.clock;
    if (k != null) {
        const base: u64 = @bitCast(@as([*c]c.GstElement, @ptrCast(s)).*.base_time);
        if (rb_ts == NONE and k != s.*.clock) {
            switch (priv(s).slave_method) {
                c.GST_AUDIO_BASE_SRC_SLAVE_RESAMPLE, c.GST_AUDIO_BASE_SRC_SLAVE_SKEW => skew(s, k, sample, samples, rate, first_sample, &ts),
                c.GST_AUDIO_BASE_SRC_SLAVE_RE_TIMESTAMP => {
                    ts = c.gst_clock_get_time(k);
                    ts = if (diff(ts, base) < 0) ts -% base else 0;
                    const lat = c.gst_util_uint64_scale_int(total, c.GST_SECOND, rate);
                    ts = if (ts > lat) ts - lat else 0;
                },
                else => {},
            }
        } else {
            ts = if (rb_ts != NONE) rb_ts else clock.gst_audio_clock_adjust(@ptrCast(@alignCast(k)), ts);
            ts = if (diff(ts, base) < 0) ts -% base else 0;
        }
    }
    unlock(s);
    buf.*.pts = ts;
    buf.*.duration = duration;
    buf.*.offset = sample;
    buf.*.offset_end = sample + samples;
    out.* = buf;
    return c.GST_FLOW_OK;
}

pub export fn gst_audio_base_src_create_ringbuffer(s: [*c]Src) [*c]c.GstAudioRingBuffer {
    const k = gtype.classPeek(Class, s);
    var buffer: [*c]c.GstAudioRingBuffer = null;
    if (k.create_ringbuffer) |f| buffer = f(s);
    if (buffer != null) _ = c.gst_object_set_parent(@ptrCast(buffer), @ptrCast(s));
    return buffer;
}

fn dropRingbuffer(s: [*c]Src) void {
    lock(s);
    c.gst_object_unparent(@ptrCast(s.*.ringbuffer));
    s.*.ringbuffer = null;
    unlock(s);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = of(e);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            clock.gst_audio_clock_reset(@ptrCast(@alignCast(s.*.clock)), 0);
            const r = gst_audio_base_src_create_ringbuffer(s);
            if (r == null) return c.GST_STATE_CHANGE_FAILURE;
            lock(s);
            s.*.ringbuffer = r;
            unlock(s);
            if (rb.gst_audio_ring_buffer_open_device(s.*.ringbuffer) == 0) {
                dropRingbuffer(s);
                return c.GST_STATE_CHANGE_FAILURE;
            }
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            s.*.next_sample = NONE;
            rb.gst_audio_ring_buffer_set_flushing(s.*.ringbuffer, 0);
            rb.gst_audio_ring_buffer_may_start(s.*.ringbuffer, 0);
            if (selfClock(s)) _ = c.gst_element_post_message(e, c.gst_message_new_clock_provide(@ptrCast(e), s.*.clock, 1));
        },
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => rb.gst_audio_ring_buffer_may_start(s.*.ringbuffer, 1),
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => {
            rb.gst_audio_ring_buffer_may_start(s.*.ringbuffer, 0);
            _ = rb.gst_audio_ring_buffer_pause(s.*.ringbuffer);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            if (selfClock(s)) _ = c.gst_element_post_message(e, c.gst_message_new_clock_lost(@ptrCast(e), s.*.clock));
            rb.gst_audio_ring_buffer_set_flushing(s.*.ringbuffer, 1);
        },
        else => {},
    }
    const ret = @as(*c.GstElementClass, @ptrCast(parent)).change_state.?(e, t);
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => _ = rb.gst_audio_ring_buffer_release(s.*.ringbuffer),
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            _ = rb.gst_audio_ring_buffer_close_device(s.*.ringbuffer);
            dropRingbuffer(s);
        },
        else => {},
    }
    return ret;
}

fn postMessage(e: [*c]c.GstElement, m: [*c]c.GstMessage) callconv(.c) c.gboolean {
    const s = of(e);
    const pc: *c.GstElementClass = @ptrCast(parent);
    if (m.*.type != c.GST_MESSAGE_ERROR or s.*.ringbuffer == null) return pc.post_message.?(e, m);
    const r: [*c]c.GstAudioRingBuffer = @ptrCast(@alignCast(c.gst_object_ref(s.*.ringbuffer)));
    const ret = pc.post_message.?(e, m);
    rb.gst_audio_ring_buffer_set_errored(r);
    c.g_cond_signal(@ptrCast(&r.*.cond));
    c.gst_object_unref(r);
    return ret;
}
