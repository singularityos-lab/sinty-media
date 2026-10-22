const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstidentity.c";
const DOMAIN = "gstreamer-1.0";

const PROP_SLEEP_TIME = 1;
const PROP_ERROR_AFTER = 2;
const PROP_DROP_PROBABILITY = 3;
const PROP_DROP_BUFFER_FLAGS = 4;
const PROP_DATARATE = 5;
const PROP_SILENT = 6;
const PROP_SINGLE_SEGMENT = 7;
const PROP_LAST_MESSAGE = 8;
const PROP_DUMP = 9;
const PROP_SYNC = 10;
const PROP_TS_OFFSET = 11;
const PROP_CHECK_IMPERFECT_TIMESTAMP = 12;
const PROP_CHECK_IMPERFECT_OFFSET = 13;
const PROP_SIGNAL_HANDOFFS = 14;
const PROP_DROP_ALLOCATION = 15;
const PROP_EOS_AFTER = 16;
const PROP_STATS = 17;

const NONE = cm.CLOCK_NONE;

const Self = extern struct {
    parent: c.GstBaseTransform,
    clock_id: c.GstClockID,
    error_after: c.gint,
    error_after_counter: c.gint,
    drop_probability: c.gfloat,
    drop_buffer_flags: c.GstBufferFlags,
    datarate: c.gint,
    sleep_time: c.guint,
    silent: c.gboolean,
    dump: c.gboolean,
    sync: c.gboolean,
    check_imperfect_timestamp: c.gboolean,
    check_imperfect_offset: c.gboolean,
    single_segment: c.gboolean,
    seek_segment: c.GstSegment,
    prev_timestamp: c.GstClockTime,
    prev_duration: c.GstClockTime,
    prev_offset: c.guint64,
    prev_offset_end: c.guint64,
    last_message: [*c]u8,
    signal_handoffs: c.gboolean,
    ts_offset: c.GstClockTimeDiff,
    drop_allocation: c.gboolean,
    eos_after: c.gint,
    eos_after_counter: c.gint,
    offset: c.guint64,
    upstream_latency: c.GstClockTime,
    blocked_cond: c.GCond,
    blocked: c.gboolean,
    flushing: c.gboolean,
    num_bytes: c.guint64,
    num_buffers: c.guint64,
};

const Class = extern struct {
    parent: c.GstBaseTransformClass,
    handoff: ?*const fn ([*c]c.GstElement, [*c]c.GstBuffer) callconv(.c) void,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");

var once: cm.Once = .{};
var parent: ?*c.GstBaseTransformClass = null;
var sig_handoff: c.guint = 0;
var pspec_last: [*c]c.GParamSpec = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn trans(p: anytype) [*c]c.GstBaseTransform {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) *c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn notifyLast(s: *Self) void {
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspec_last);
}

fn valid(t: u64) bool {
    return t != NONE;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.last_message);
    c.g_cond_clear(&s.blocked_cond);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn doSync(s: *Self, running: u64) c.GstFlowReturn {
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (s.sync == 0 or s.parent.segment.format != c.GST_FORMAT_TIME) return ret;
    cm.lock(s);
    defer cm.unlock(s);
    if (s.flushing != 0) return c.GST_FLOW_FLUSHING;
    while (s.blocked != 0 and s.flushing == 0) c.g_cond_wait(&s.blocked_cond, &cm.obj(s).lock);
    if (s.flushing != 0) return c.GST_FLOW_FLUSHING;
    const clock = element(s).clock;
    if (clock != null) {
        var ts: u64 = running +% @as(u64, @bitCast(element(s).base_time)) +% s.upstream_latency;
        var off = s.ts_offset;
        if (off < 0) {
            off = -off;
            const uo: u64 = @intCast(off);
            ts = if (uo < ts) ts - uo else 0;
        } else ts +%= @intCast(off);
        s.clock_id = c.gst_clock_new_single_shot_id(clock, ts);
        cm.unlock(s);
        const cret = c.gst_clock_id_wait(s.clock_id, null);
        cm.lock(s);
        if (s.clock_id != null) {
            c.gst_clock_id_unref(s.clock_id);
            s.clock_id = null;
        }
        if (cret == c.GST_CLOCK_UNSCHEDULED or s.flushing != 0) ret = c.GST_FLOW_FLUSHING;
    }
    return ret;
}

fn setLastEvent(s: *Self, pad: anytype, ev: [*c]c.GstEvent) void {
    cm.lock(s);
    c.g_free(s.last_message);
    const st = c.gst_event_get_structure(ev);
    const sstr = if (st != null) c.gst_structure_to_string(st) else c.g_strdup("");
    s.last_message = c.g_strdup_printf("event   ******* (%s:%s) E (type: %s (%d), %s) %p", cm.padParentName(pad), cm.padName(pad), c.gst_event_type_get_name(cm.eventType(ev)), cm.eventType(ev), sstr, ev);
    c.g_free(sstr);
    cm.unlock(s);
    notifyLast(s);
}

fn sinkEvent(t: [*c]c.GstBaseTransform, ev_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(t);
    var ev = ev_in;
    if (s.silent == 0) setLastEvent(s, t[0].sinkpad, ev);
    if (s.single_segment != 0 and cm.eventType(ev) == c.GST_EVENT_SEGMENT) {
        if (t[0].have_segment == 0) {
            var seg: c.GstSegment = undefined;
            c.gst_event_copy_segment(ev, &seg);
            c.gst_event_copy_segment(ev, &t[0].segment);
            t[0].have_segment = 1;
            c.gst_segment_init(&seg, seg.format);
            if (s.seek_segment.format != c.GST_FORMAT_UNDEFINED) {
                seg.time = s.seek_segment.time;
                seg.base = s.seek_segment.base;
                c.gst_segment_init(&s.seek_segment, c.GST_FORMAT_UNDEFINED);
            }
            const news = c.gst_event_new_segment(&seg);
            news[0].seqnum = ev[0].seqnum;
            _ = c.gst_pad_event_default(t[0].sinkpad, @ptrCast(@alignCast(t)), news);
        } else c.gst_event_copy_segment(ev, &t[0].segment);
    }
    if (cm.eventType(ev) == c.GST_EVENT_GAP and t[0].have_segment != 0 and t[0].segment.format == c.GST_FORMAT_TIME) {
        var old_start: u64 = 0;
        var dur: u64 = 0;
        c.gst_event_parse_gap(ev, &old_start, &dur);
        const st = c.gst_segment_to_running_time(&t[0].segment, c.GST_FORMAT_TIME, old_start);
        _ = doSync(s, if (valid(st)) st else 0);
        if (s.single_segment != 0) {
            var cs: u64 = 0;
            var ce: u64 = 0;
            if (valid(st)) {
                c.gst_mini_object_unref(@ptrCast(ev));
                ev = c.gst_event_new_gap(st, dur);
            } else if (valid(dur) and c.gst_segment_clip(&t[0].segment, c.GST_FORMAT_TIME, old_start, old_start +% dur, &cs, &ce) != 0) {
                c.gst_mini_object_unref(@ptrCast(ev));
                ev = c.gst_event_new_gap(cs, ce - cs);
            } else {
                c.gst_mini_object_unref(@ptrCast(ev));
                return 1;
            }
        }
    }
    if (cm.eventType(ev) == c.GST_EVENT_SEGMENT) {
        s.prev_timestamp = NONE;
        s.prev_duration = NONE;
        s.prev_offset = NONE;
        s.prev_offset_end = NONE;
    }
    if (s.single_segment != 0 and cm.eventType(ev) == c.GST_EVENT_SEGMENT) {
        c.gst_mini_object_unref(@ptrCast(ev));
        return 1;
    }
    switch (cm.eventType(ev)) {
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
            t[0].have_segment = 0;
            cm.unlock(s);
        },
        else => {},
    }
    return parent.?.sink_event.?(t, ev);
}

fn srcEvent(t: [*c]c.GstBaseTransform, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(t);
    if (cm.eventType(ev) == c.GST_EVENT_SEEK) {
        var rate: f64 = 0;
        var fmt: c.GstFormat = 0;
        var flags: c.GstSeekFlags = 0;
        var st: c.GstSeekType = 0;
        var et: c.GstSeekType = 0;
        var sstart: i64 = 0;
        var sstop: i64 = 0;
        c.gst_event_parse_seek(ev, &rate, &fmt, &flags, &st, &sstart, &et, &sstop);
        cm.lock(s);
        if (s.single_segment != 0) {
            c.gst_segment_init(&s.seek_segment, fmt);
            if (c.gst_segment_do_seek(&s.seek_segment, rate, fmt, flags, st, @bitCast(sstart), et, @bitCast(sstop), null) == 0) {
                cm.unlock(s);
                return 0;
            }
        }
        cm.unlock(s);
    }
    return parent.?.src_event.?(t, ev);
}

fn imperfectTimestamp(s: *Self, b: [*c]c.GstBuffer) void {
    const bf = cm.buf(b);
    const ts = bf.pts;
    if (ts == NONE) return;
    if (s.prev_timestamp == NONE or s.prev_duration == NONE) return;
    const expected = s.prev_timestamp +% s.prev_duration;
    const dt: i64 = @as(i64, @bitCast(ts)) -% @as(i64, @bitCast(expected));
    if (dt == 0) return;
    const st = c.gst_structure_new("imperfect-timestamp", "delta", c.G_TYPE_INT64, dt, "prev-timestamp", c.G_TYPE_UINT64, s.prev_timestamp, "prev-duration", c.G_TYPE_UINT64, s.prev_duration, "prev-offset", c.G_TYPE_UINT64, s.prev_offset, "prev-offset-end", c.G_TYPE_UINT64, s.prev_offset_end, "cur-timestamp", c.G_TYPE_UINT64, ts, "cur-duration", c.G_TYPE_UINT64, bf.duration, "cur-offset", c.G_TYPE_UINT64, bf.offset, "cur-offset-end", c.G_TYPE_UINT64, bf.offset_end, @as(?*anyopaque, null));
    _ = c.gst_element_post_message(element(s), c.gst_message_new_element(cm.obj(s), st));
}

fn imperfectOffset(s: *Self, b: [*c]c.GstBuffer) void {
    const bf = cm.buf(b);
    if (s.prev_offset_end != bf.offset and s.prev_offset_end != NONE and bf.offset != NONE) {
        const st = c.gst_structure_new("imperfect-offset", "prev-timestamp", c.G_TYPE_UINT64, s.prev_timestamp, "prev-duration", c.G_TYPE_UINT64, s.prev_duration, "prev-offset", c.G_TYPE_UINT64, s.prev_offset, "prev-offset-end", c.G_TYPE_UINT64, s.prev_offset_end, "cur-timestamp", c.G_TYPE_UINT64, bf.pts, "cur-duration", c.G_TYPE_UINT64, bf.duration, "cur-offset", c.G_TYPE_UINT64, bf.offset, "cur-offset-end", c.G_TYPE_UINT64, bf.offset_end, @as(?*anyopaque, null));
        _ = c.gst_element_post_message(element(s), c.gst_message_new_element(cm.obj(s), st));
    }
}

fn lastForBuffer(s: *Self, action: [*c]const u8, b: [*c]c.GstBuffer, size: usize) void {
    var dts: [64]u8 = undefined;
    var pts: [64]u8 = undefined;
    var dur: [64]u8 = undefined;
    const bf = cm.buf(b);
    const pad = s.parent.sinkpad;
    cm.lock(s);
    const flags = cm.flagsString(b);
    const metas = cm.metaString(b);
    c.g_free(s.last_message);
    s.last_message = c.g_strdup_printf("%s   ******* (%s:%s) (%lu bytes, dts: %s, pts: %s, duration: %s, offset: %li, offset_end: %li, flags: %08x %s, meta: %s) %p", action, cm.padParentName(pad), cm.padName(pad), size, cm.timeStr(&dts, bf.dts), cm.timeStr(&pts, bf.pts), cm.timeStr(&dur, bf.duration), bf.offset, bf.offset_end, bf.mini_object.flags, flags, if (metas != null) @as([*c]const u8, metas) else @as([*c]const u8, "none"), b);
    c.g_free(flags);
    c.g_free(metas);
    cm.unlock(s);
    notifyLast(s);
}

fn dropped(s: *Self, b: [*c]c.GstBuffer, size: usize) c.GstFlowReturn {
    if (s.silent == 0) lastForBuffer(s, "dropping", b, size);
    const bf = cm.buf(b);
    if (valid(bf.pts)) _ = c.gst_pad_push_event(s.parent.srcpad, c.gst_event_new_gap(bf.pts, bf.duration));
    return c.GST_BASE_TRANSFORM_FLOW_DROPPED;
}

fn transformIp(t: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(t);
    const bf = cm.buf(b);
    var rundts: u64 = NONE;
    var runpts: u64 = NONE;
    const size = c.gst_buffer_get_size(b);
    if (s.check_imperfect_timestamp != 0) imperfectTimestamp(s, b);
    if (s.check_imperfect_offset != 0) imperfectOffset(s, b);
    s.prev_timestamp = bf.pts;
    s.prev_duration = bf.duration;
    s.prev_offset_end = bf.offset_end;
    s.prev_offset = bf.offset;
    if (s.error_after_counter >= 0) {
        s.error_after_counter -= 1;
        if (s.error_after_counter == 0) {
            cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, c.g_strdup(cm.tr(DOMAIN, "Failed after iterations as requested.")), null, FILE, "gst_identity_transform_ip", 849);
            return c.GST_FLOW_ERROR;
        }
    }
    if (s.eos_after_counter >= 0) {
        s.eos_after_counter -= 1;
        if (s.eos_after_counter == 0) return c.GST_FLOW_EOS;
    }
    if (s.drop_probability > 0.0) {
        const r: f32 = @floatCast(1.0 * @as(f64, @floatFromInt(c.rand())) / @as(f64, @floatFromInt(c.RAND_MAX)));
        if (r < s.drop_probability) return dropped(s, b, size);
    }
    if (bf.mini_object.flags & s.drop_buffer_flags != 0) return dropped(s, b, size);
    if (s.dump != 0) {
        var info: c.GstMapInfo = undefined;
        if (c.gst_buffer_map(b, &info, c.GST_MAP_READ) != 0) {
            c.gst_util_dump_mem(info.data, @intCast(info.size));
            c.gst_buffer_unmap(b, &info);
        }
    }
    if (s.silent == 0) lastForBuffer(s, "chain", b, size);
    if (s.datarate > 0) {
        const time = c.gst_util_uint64_scale_int(s.offset, c.GST_SECOND, s.datarate);
        bf.pts = time;
        bf.dts = time;
        bf.duration = size *% c.GST_SECOND / @as(u64, @intCast(s.datarate));
    }
    if (s.signal_handoffs != 0) c.g_signal_emit(s, sig_handoff, 0, b);
    const seg = &t[0].segment;
    if (seg.format == c.GST_FORMAT_TIME) {
        if (seg.rate > 0) {
            runpts = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, bf.pts);
            rundts = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, bf.dts);
        } else {
            runpts = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, if (valid(bf.duration) and valid(bf.pts)) bf.pts +% bf.duration else bf.pts);
            rundts = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, if (valid(bf.duration) and valid(bf.dts)) bf.dts +% bf.duration else bf.dts);
        }
    }
    const runts: u64 = if (valid(rundts)) rundts else if (valid(runpts)) runpts else 0;
    const ret = doSync(s, runts);
    s.offset += size;
    if (s.sleep_time != 0 and ret == c.GST_FLOW_OK) c.g_usleep(s.sleep_time);
    if (s.single_segment != 0 and seg.format == c.GST_FORMAT_TIME and ret == c.GST_FLOW_OK) {
        bf.dts = rundts;
        bf.pts = runpts;
        bf.offset = NONE;
        bf.offset_end = NONE;
    }
    cm.lock(t);
    s.num_bytes += c.gst_buffer_get_size(b);
    s.num_buffers += 1;
    cm.unlock(t);
    return ret;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SLEEP_TIME => s.sleep_time = c.g_value_get_uint(v),
        PROP_SILENT => s.silent = c.g_value_get_boolean(v),
        PROP_SINGLE_SEGMENT => s.single_segment = c.g_value_get_boolean(v),
        PROP_DUMP => s.dump = c.g_value_get_boolean(v),
        PROP_ERROR_AFTER => s.error_after = c.g_value_get_int(v),
        PROP_DROP_PROBABILITY => s.drop_probability = c.g_value_get_float(v),
        PROP_DROP_BUFFER_FLAGS => s.drop_buffer_flags = c.g_value_get_flags(v),
        PROP_DATARATE => s.datarate = c.g_value_get_int(v),
        PROP_SYNC => {
            const sync = c.g_value_get_boolean(v);
            var msg: [*c]c.GstMessage = null;
            cm.lock(s);
            if (sync != s.sync) {
                const sys = c.gst_system_clock_obtain();
                s.sync = sync;
                if (sync != 0) {
                    cm.obj(s).flags |= c.GST_ELEMENT_FLAG_PROVIDE_CLOCK;
                    msg = c.gst_message_new_clock_provide(cm.obj(s), sys, 1);
                } else {
                    cm.obj(s).flags &= ~@as(c.guint32, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK);
                    msg = c.gst_message_new_clock_lost(cm.obj(s), sys);
                }
                c.gst_object_unref(sys);
            }
            cm.unlock(s);
            if (msg != null) _ = c.gst_element_post_message(element(s), msg);
        },
        PROP_TS_OFFSET => s.ts_offset = c.g_value_get_int64(v),
        PROP_CHECK_IMPERFECT_TIMESTAMP => s.check_imperfect_timestamp = c.g_value_get_boolean(v),
        PROP_CHECK_IMPERFECT_OFFSET => s.check_imperfect_offset = c.g_value_get_boolean(v),
        PROP_SIGNAL_HANDOFFS => s.signal_handoffs = c.g_value_get_boolean(v),
        PROP_DROP_ALLOCATION => s.drop_allocation = c.g_value_get_boolean(v),
        PROP_EOS_AFTER => s.eos_after = c.g_value_get_int(v),
        else => cm.warnInvalid(FILE, o, id, spec, 954),
    }
    c.gst_base_transform_set_passthrough(trans(s), @intFromBool(!(s.datarate > 0 or s.single_segment != 0)));
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SLEEP_TIME => c.g_value_set_uint(v, s.sleep_time),
        PROP_ERROR_AFTER => c.g_value_set_int(v, s.error_after),
        PROP_DROP_PROBABILITY => c.g_value_set_float(v, s.drop_probability),
        PROP_DROP_BUFFER_FLAGS => c.g_value_set_flags(v, s.drop_buffer_flags),
        PROP_DATARATE => c.g_value_set_int(v, s.datarate),
        PROP_SILENT => c.g_value_set_boolean(v, s.silent),
        PROP_SINGLE_SEGMENT => c.g_value_set_boolean(v, s.single_segment),
        PROP_DUMP => c.g_value_set_boolean(v, s.dump),
        PROP_LAST_MESSAGE => {
            cm.lock(s);
            c.g_value_set_string(v, s.last_message);
            cm.unlock(s);
        },
        PROP_SYNC => c.g_value_set_boolean(v, s.sync),
        PROP_TS_OFFSET => c.g_value_set_int64(v, s.ts_offset),
        PROP_CHECK_IMPERFECT_TIMESTAMP => c.g_value_set_boolean(v, s.check_imperfect_timestamp),
        PROP_CHECK_IMPERFECT_OFFSET => c.g_value_set_boolean(v, s.check_imperfect_offset),
        PROP_SIGNAL_HANDOFFS => c.g_value_set_boolean(v, s.signal_handoffs),
        PROP_DROP_ALLOCATION => c.g_value_set_boolean(v, s.drop_allocation),
        PROP_EOS_AFTER => c.g_value_set_int(v, s.eos_after),
        PROP_STATS => {
            cm.lock(s);
            const st = c.gst_structure_new("application/x-identity-stats", "num-bytes", c.G_TYPE_UINT64, s.num_bytes, "num-buffers", c.G_TYPE_UINT64, s.num_buffers, @as(?*anyopaque, null));
            cm.unlock(s);
            c.g_value_take_boxed(v, st);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1040),
    }
}

fn start(t: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(t);
    if (s.eos_after != -1 and s.error_after != -1) {
        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, c.g_strdup(cm.tr(DOMAIN, "eos-after and error-after can't both be defined.")), null, FILE, "gst_identity_start", 1069);
        return 0;
    }
    s.offset = 0;
    s.prev_timestamp = NONE;
    s.prev_duration = NONE;
    s.prev_offset_end = NONE;
    s.prev_offset = NONE;
    s.error_after_counter = s.error_after;
    s.eos_after_counter = s.eos_after;
    return 1;
}

fn stop(t: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(t);
    cm.lock(s);
    c.g_free(s.last_message);
    s.last_message = null;
    cm.unlock(s);
    return 1;
}

fn acceptCaps(t: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const pad = if (dir == c.GST_PAD_SRC) t[0].sinkpad else t[0].srcpad;
    return c.gst_pad_peer_query_accept_caps(pad, caps);
}

fn query(t: [*c]c.GstBaseTransform, dir: c.GstPadDirection, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(t);
    if (cm.queryType(q) == c.GST_QUERY_ALLOCATION and s.drop_allocation != 0) return 0;
    var ret = parent.?.query.?(t, dir, q);
    if (cm.queryType(q) == c.GST_QUERY_LATENCY) {
        var live: c.gboolean = 0;
        var min: u64 = 0;
        var max: u64 = 0;
        if (ret != 0) {
            c.gst_query_parse_latency(q, &live, &min, &max);
            if (s.sync != 0 and max < min) {
                var a: [64]u8 = undefined;
                var b: [64]u8 = undefined;
                cm.elementWarning(t, c.gst_core_error_quark(), c.GST_CORE_ERROR_CLOCK, null, c.g_strdup_printf("Impossible to configure latency before identity sync=true: max %s < min %s. Add queues or other buffering elements.", cm.timeFmt(&a, max), cm.timeFmt(&b, min)), FILE, "gst_identity_query", 1134);
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
        c.gst_query_set_latency(q, @intFromBool(live != 0 or s.sync != 0), min, max);
        ret = 1;
    }
    return ret;
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
            s.num_bytes = 0;
            s.num_buffers = 0;
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
    var ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent.?))).change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_PLAYING_TO_PAUSED) {
        cm.lock(s);
        s.upstream_latency = 0;
        s.blocked = 1;
        cm.unlock(s);
        if (s.sync != 0) no_preroll = true;
    }
    if (no_preroll and ret == c.GST_STATE_CHANGE_SUCCESS) ret = c.GST_STATE_CHANGE_NO_PREROLL;
    return ret;
}

fn provideClock(el: [*c]c.GstElement) callconv(.c) [*c]c.GstClock {
    if (me(el).sync == 0) return null;
    return c.gst_system_clock_obtain();
}

fn boolProp(oc: *c.GObjectClass, id: c.guint, name: [*c]const u8, nick: [*c]const u8, blurb: [*c]const u8, def: bool) void {
    c.g_object_class_install_property(oc, id, c.g_param_spec_boolean(name, nick, blurb, @intFromBool(def), cm.RW));
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_SLEEP_TIME, c.g_param_spec_uint("sleep-time", "Sleep time", "Microseconds to sleep between processing", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_ERROR_AFTER, c.g_param_spec_int("error-after", "Error After", "Error after N buffers", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_DROP_PROBABILITY, c.g_param_spec_float("drop-probability", "Drop Probability", "The Probability a buffer is dropped", 0.0, 1.0, 0.0, cm.RW));
    c.g_object_class_install_property(oc, PROP_DROP_BUFFER_FLAGS, c.g_param_spec_flags("drop-buffer-flags", "Check flags to drop buffers", "Drop buffers with the given flags", c.gst_buffer_flags_get_type(), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_DATARATE, c.g_param_spec_int("datarate", "Datarate", "(Re)timestamps buffers with number of bytes per second (0 = inactive)", 0, std.math.maxInt(c.gint), 0, cm.RW));
    boolProp(oc, PROP_SILENT, "silent", "silent", "silent", true);
    boolProp(oc, PROP_SINGLE_SEGMENT, "single-segment", "Single Segment", "Timestamp buffers and eat segments so as to appear as one segment", false);
    pspec_last = c.g_param_spec_string("last-message", "last-message", "last-message", null, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS);
    c.g_object_class_install_property(oc, PROP_LAST_MESSAGE, pspec_last);
    boolProp(oc, PROP_DUMP, "dump", "Dump", "Dump buffer contents to stdout", false);
    boolProp(oc, PROP_SYNC, "sync", "Synchronize", "Synchronize to pipeline clock", false);
    c.g_object_class_install_property(oc, PROP_TS_OFFSET, c.g_param_spec_int64("ts-offset", "Timestamp offset for synchronisation", "Timestamp offset in nanoseconds for synchronisation, negative for earlier sync", std.math.minInt(i64), std.math.maxInt(i64), 0, cm.RW));
    boolProp(oc, PROP_CHECK_IMPERFECT_TIMESTAMP, "check-imperfect-timestamp", "Check for discontiguous timestamps", "Send element messages if timestamps and durations do not match up", false);
    boolProp(oc, PROP_CHECK_IMPERFECT_OFFSET, "check-imperfect-offset", "Check for discontiguous offset", "Send element messages if offset and offset_end do not match up", false);
    boolProp(oc, PROP_SIGNAL_HANDOFFS, "signal-handoffs", "Signal handoffs", "Send a signal before pushing the buffer", true);
    boolProp(oc, PROP_DROP_ALLOCATION, "drop-allocation", "Drop allocation query", "Don't forward allocation queries", false);
    c.g_object_class_install_property(oc, PROP_EOS_AFTER, c.g_param_spec_int("eos-after", "EOS After", "EOS after N buffers", -1, std.math.maxInt(c.gint), -1, cm.RW));
    sig_handoff = c.g_signal_new("handoff", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "handoff"), null, null, null, c.G_TYPE_NONE, 1, c.gst_buffer_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE);
    c.g_object_class_install_property(oc, PROP_STATS, c.g_param_spec_boxed("stats", "Statistics", "Statistics", c.gst_structure_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Identity", "Generic", "Pass data without modification", "Erik Walthinsen <omega@cse.ogi.edu>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    ec.change_state = changeState;
    ec.provide_clock = provideClock;
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.sink_event = sinkEvent;
    tc.src_event = srcEvent;
    tc.transform_ip = transformIp;
    tc.start = start;
    tc.stop = stop;
    tc.accept_caps = acceptCaps;
    tc.query = query;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.sleep_time = 0;
    s.error_after = -1;
    s.error_after_counter = -1;
    s.drop_probability = 0;
    s.drop_buffer_flags = 0;
    s.datarate = 0;
    s.silent = 1;
    s.single_segment = 0;
    s.sync = 0;
    s.check_imperfect_timestamp = 0;
    s.check_imperfect_offset = 0;
    s.dump = 0;
    s.last_message = null;
    s.signal_handoffs = 1;
    s.ts_offset = 0;
    c.g_cond_init(&s.blocked_cond);
    s.eos_after = -1;
    s.eos_after_counter = -1;
    c.gst_base_transform_set_gap_aware(trans(s), 1);
    cm.obj(s).flags |= c.GST_ELEMENT_FLAG_REQUIRE_CLOCK;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_transform_get_type(), "GstIdentity", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("identity", 0, "identity element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "identity", c.GST_RANK_NONE, getType()) != 0;
}
