const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("el.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Src = c.GstBaseSrc;
const Class = c.GstBaseSrcClass;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const Caps = c.GstCaps;
const NONE = el.NONE;
const FILE = "gstbasesrc.c";

const PROP_BLOCKSIZE = 1;
const PROP_NUM_BUFFERS = 2;
const PROP_TYPEFIND = 3;
const PROP_DO_TIMESTAMP = 4;
const PROP_AUTOMATIC_EOS = 5;

const Private = extern struct {
    discont: bool,
    flushing: bool,
    start_result: c.GstFlowReturn,
    async_: bool,
    stream_start_pending: bool,
    segment_pending: bool,
    segment_seqnum: c.guint32,
    pending_eos: [*c]Event,
    has_pending_eos: c.gint,
    forced_eos: bool,
    latency: c.GstClockTime,
    ts_offset: c.GstClockTimeDiff,
    do_timestamp: bool,
    dynamic_size: c.gint,
    automatic_eos: c.gint,
    seqnum: c.guint32,
    pending_events: ?*c.GList,
    have_events: c.gint,
    proportion: f64,
    earliest_time: c.GstClockTime,
    pool: ?*c.GstBufferPool,
    allocator: ?*c.GstAllocator,
    params: c.GstAllocationParams,
    async_cond: c.GCond,
    pending_bufferlist: ?*c.GstBufferList,
    pending_unlock_stop: bool,
};

var type_once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GstElementClass = null;

fn priv(s: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Src, @ptrCast(@alignCast(s)))[0].priv));
}

fn of(p: anytype) *Src {
    return @ptrCast(@alignCast(p));
}

fn klass(s: anytype) *Class {
    return el.classOf(Class, s);
}

pub fn isSrc(s: anytype) bool {
    return gtype.instanceOf(s, gst_base_src_get_type());
}

fn started(s: *Src) bool {
    return el.flags(s) & c.GST_BASE_SRC_FLAG_STARTED != 0;
}

fn starting(s: *Src) bool {
    return el.flags(s) & c.GST_BASE_SRC_FLAG_STARTING != 0;
}

fn liveLock(s: *Src) void {
    c.g_mutex_lock(&s.live_lock);
}

fn liveUnlock(s: *Src) void {
    c.g_mutex_unlock(&s.live_lock);
}

fn atomicGet(p: *c.gint) bool {
    return @atomicLoad(c.gint, p, .seq_cst) != 0;
}

fn atomicSet(p: *c.gint, v: bool) void {
    @atomicStore(c.gint, p, @intFromBool(v), .seq_cst);
}

fn clearPendingEos(s: *Src) void {
    const p = priv(s);
    atomicSet(&p.has_pending_eos, false);
    _ = c.gst_event_replace(&p.pending_eos, null);
}

pub export fn gst_base_src_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstBaseSrc", Class, Src, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    if (offset != 0) c.g_type_class_adjust_private_offset(k, &offset);
    _ = c._gst_debug_category_new("basesrc", 0, "basesrc element");
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = finalize;
    gc.set_property = setProp;
    gc.get_property = getProp;
    const rw = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, PROP_BLOCKSIZE, c.g_param_spec_uint("blocksize", "Block size", "Size in bytes to read per buffer (-1 = default)", 0, std.math.maxInt(c.guint), 4096, rw));
    c.g_object_class_install_property(gc, PROP_NUM_BUFFERS, c.g_param_spec_int("num-buffers", "num-buffers", "Number of buffers to output before sending EOS (-1 = unlimited)", -1, std.math.maxInt(c.gint), -1, rw));
    c.g_object_class_install_property(gc, PROP_TYPEFIND, c.g_param_spec_boolean("typefind", "Typefind", "Run typefind before negotiating (deprecated, non-functional)", 0, rw | c.G_PARAM_DEPRECATED));
    c.g_object_class_install_property(gc, PROP_DO_TIMESTAMP, c.g_param_spec_boolean("do-timestamp", "Do timestamp", "Apply current stream time to buffers", 0, rw));
    c.g_object_class_install_property(gc, PROP_AUTOMATIC_EOS, c.g_param_spec_boolean("automatic-eos", "Automatic EOS", "Automatically EOS when the segment is done", 1, rw));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    ec.send_event = sendEvent;
    const bc: *Class = @ptrCast(@alignCast(k));
    bc.get_caps = defaultGetCaps;
    bc.negotiate = defaultNegotiate;
    bc.fixate = defaultFixate;
    bc.prepare_seek_segment = defaultPrepareSeek;
    bc.do_seek = defaultDoSeek;
    bc.query = defaultQuery;
    bc.event = defaultEvent;
    bc.create = defaultCreate;
    bc.alloc = defaultAlloc;
    bc.decide_allocation = defaultDecideAllocation;
}

fn init(instance: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const s: *Src = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    s.priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
    s.is_live = 0;
    c.g_mutex_init(&s.live_lock);
    c.g_cond_init(&s.live_cond);
    s.num_buffers = -1;
    s.num_buffers_left = -1;
    const p = priv(s);
    atomicSet(&p.automatic_eos, true);
    s.can_activate_push = 1;
    const templ = c.gst_element_class_get_pad_template(@ptrCast(@alignCast(g_class)), "src");
    if (!check.that(templ != null, "gst_base_src_init", "pad_template != NULL")) return;
    const pad = c.gst_pad_new_from_template(templ, "src");
    c.gst_pad_set_activatemode_function_full(pad, activateMode, null, null);
    c.gst_pad_set_event_function_full(pad, padEvent, null, null);
    c.gst_pad_set_query_function_full(pad, padQuery, null, null);
    c.gst_pad_set_getrange_function_full(pad, getRangeFn, null, null);
    s.srcpad = pad;
    _ = c.gst_element_add_pad(@ptrCast(s), pad);
    s.blocksize = 4096;
    s.clock_id = null;
    gst_base_src_set_format(s, c.GST_FORMAT_BYTES);
    p.do_timestamp = false;
    atomicSet(&p.have_events, false);
    c.g_cond_init(&p.async_cond);
    p.start_result = c.GST_FLOW_FLUSHING;
    el.unsetFlag(s, c.GST_BASE_SRC_FLAG_STARTED);
    el.unsetFlag(s, c.GST_BASE_SRC_FLAG_STARTING);
    el.setFlag(s, c.GST_ELEMENT_FLAG_SOURCE);
}

fn freeEvents(l: ?*c.GList) void {
    var n = l;
    while (n) |x| : (n = x.next) c.gst_event_unref(@ptrCast(@alignCast(x.data)));
    c.g_list_free(l);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = of(o);
    const p = priv(s);
    c.g_mutex_clear(&s.live_lock);
    c.g_cond_clear(&s.live_cond);
    c.g_cond_clear(&p.async_cond);
    _ = c.gst_event_replace(&s.pending_seek, null);
    if (p.pending_events != null) freeEvents(p.pending_events);
    @as(*c.GObjectClass, @ptrCast(parent.?)).finalize.?(o);
}

fn waitPlayingUnlocked(s: *Src) c.GstFlowReturn {
    const p = priv(s);
    while (s.live_running == 0 and !p.flushing) c.g_cond_wait(&s.live_cond, &s.live_lock);
    if (p.flushing) return c.GST_FLOW_FLUSHING;
    return c.GST_FLOW_OK;
}

pub export fn gst_base_src_wait_playing(s: [*c]Src) c.GstFlowReturn {
    if (!check.that(isSrc(s), "gst_base_src_wait_playing", "GST_IS_BASE_SRC (src)")) return c.GST_FLOW_ERROR;
    liveLock(of(s));
    defer liveUnlock(of(s));
    return waitPlayingUnlocked(of(s));
}

pub export fn gst_base_src_set_live(s: [*c]Src, live: c.gboolean) void {
    if (!check.that(isSrc(s), "gst_base_src_set_live", "GST_IS_BASE_SRC (src)")) return;
    el.lock(s);
    s[0].is_live = live;
    el.unlock(s);
}

pub export fn gst_base_src_is_live(s: [*c]Src) c.gboolean {
    if (!check.that(isSrc(s), "gst_base_src_is_live", "GST_IS_BASE_SRC (src)")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return s[0].is_live;
}

pub export fn gst_base_src_set_format(s: [*c]Src, format: c.GstFormat) void {
    if (!check.that(isSrc(s), "gst_base_src_set_format", "GST_IS_BASE_SRC (src)")) return;
    if (!check.that(s[0].element.current_state <= c.GST_STATE_READY, "gst_base_src_set_format", "GST_STATE (src) <= GST_STATE_READY")) return;
    el.lock(s);
    c.gst_segment_init(&s[0].segment, format);
    el.unlock(s);
}

pub export fn gst_base_src_set_dynamic_size(s: [*c]Src, dynamic: c.gboolean) void {
    if (!check.that(isSrc(s), "gst_base_src_set_dynamic_size", "GST_IS_BASE_SRC (src)")) return;
    atomicSet(&priv(s).dynamic_size, dynamic != 0);
}

pub export fn gst_base_src_set_automatic_eos(s: [*c]Src, automatic: c.gboolean) void {
    if (!check.that(isSrc(s), "gst_base_src_set_automatic_eos", "GST_IS_BASE_SRC (src)")) return;
    atomicSet(&priv(s).automatic_eos, automatic != 0);
}

pub export fn gst_base_src_set_async(s: [*c]Src, async_: c.gboolean) void {
    if (!check.that(isSrc(s), "gst_base_src_set_async", "GST_IS_BASE_SRC (src)")) return;
    el.lock(s);
    priv(s).async_ = async_ != 0;
    el.unlock(s);
}

pub export fn gst_base_src_is_async(s: [*c]Src) c.gboolean {
    if (!check.that(isSrc(s), "gst_base_src_is_async", "GST_IS_BASE_SRC (src)")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return @intFromBool(priv(s).async_);
}

pub export fn gst_base_src_query_latency(s: [*c]Src, live: [*c]c.gboolean, min_latency: [*c]c.GstClockTime, max_latency: [*c]c.GstClockTime) c.gboolean {
    if (!check.that(isSrc(s), "gst_base_src_query_latency", "GST_IS_BASE_SRC (src)")) return 0;
    el.lock(s);
    defer el.unlock(s);
    if (live != null) live.* = s[0].is_live;
    const l = priv(s).latency;
    const min: c.GstClockTime = if (l != NONE) l else 0;
    if (min_latency != null) min_latency.* = min;
    if (max_latency != null) max_latency.* = min;
    return 1;
}

pub export fn gst_base_src_set_blocksize(s: [*c]Src, size: c.guint) void {
    if (!check.that(isSrc(s), "gst_base_src_set_blocksize", "GST_IS_BASE_SRC (src)")) return;
    el.lock(s);
    s[0].blocksize = size;
    el.unlock(s);
}

pub export fn gst_base_src_get_blocksize(s: [*c]Src) c.guint {
    if (!check.that(isSrc(s), "gst_base_src_get_blocksize", "GST_IS_BASE_SRC (src)")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return s[0].blocksize;
}

pub export fn gst_base_src_set_do_timestamp(s: [*c]Src, timestamp: c.gboolean) void {
    if (!check.that(isSrc(s), "gst_base_src_set_do_timestamp", "GST_IS_BASE_SRC (src)")) return;
    el.lock(s);
    defer el.unlock(s);
    priv(s).do_timestamp = timestamp != 0;
    if (timestamp != 0 and s[0].segment.format != c.GST_FORMAT_TIME) c.gst_segment_init(&s[0].segment, c.GST_FORMAT_TIME);
}

pub export fn gst_base_src_get_do_timestamp(s: [*c]Src) c.gboolean {
    if (!check.that(isSrc(s), "gst_base_src_get_do_timestamp", "GST_IS_BASE_SRC (src)")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return @intFromBool(priv(s).do_timestamp);
}

pub export fn gst_base_src_new_seamless_segment(s: [*c]Src, start: c.gint64, stop: c.gint64, time: c.gint64) c.gboolean {
    const x = of(s);
    el.lock(x);
    x.segment.base = c.gst_segment_to_running_time(&x.segment, x.segment.format, x.segment.position);
    x.segment.start = @bitCast(start);
    x.segment.position = @bitCast(start);
    x.segment.stop = @bitCast(stop);
    x.segment.time = @bitCast(time);
    priv(x).segment_pending = true;
    priv(x).segment_seqnum = c.gst_util_seqnum_next();
    el.unlock(x);
    priv(x).discont = true;
    x.running = 1;
    return 1;
}

fn segmentFormatOk(x: *Src, segment: [*c]const c.GstSegment) bool {
    return x.segment.format != c.GST_FORMAT_UNDEFINED and x.segment.format == segment[0].format;
}

pub export fn gst_base_src_new_segment(s: [*c]Src, segment: [*c]const c.GstSegment) c.gboolean {
    if (!check.that(isSrc(s), "gst_base_src_new_segment", "GST_IS_BASE_SRC (src)")) return 0;
    if (!check.that(segment != null, "gst_base_src_new_segment", "segment != NULL")) return 0;
    const x = of(s);
    el.lock(x);
    if (!segmentFormatOk(x, segment)) {
        el.unlock(x);
        return 0;
    }
    c.gst_segment_copy_into(segment, &x.segment);
    priv(x).segment_pending = true;
    priv(x).segment_seqnum = c.gst_util_seqnum_next();
    el.unlock(x);
    x.running = 1;
    return 1;
}

pub export fn gst_base_src_push_segment(s: [*c]Src, segment: [*c]const c.GstSegment) c.gboolean {
    if (!check.that(isSrc(s), "gst_base_src_push_segment", "GST_IS_BASE_SRC (src)")) return 0;
    if (!check.that(segment != null, "gst_base_src_push_segment", "segment != NULL")) return 0;
    const x = of(s);
    el.lock(x);
    if (!segmentFormatOk(x, segment)) {
        el.unlock(x);
        return 0;
    }
    c.gst_segment_copy_into(segment, &x.segment);
    const ev = c.gst_event_new_segment(&x.segment);
    priv(x).segment_pending = false;
    priv(x).segment_seqnum = c.gst_util_seqnum_next();
    c.gst_event_set_seqnum(ev, priv(x).segment_seqnum);
    el.unlock(x);
    _ = c.gst_pad_push_event(x.srcpad, ev);
    x.running = 1;
    return 1;
}

fn sendStreamStart(x: *Src) bool {
    const p = priv(x);
    if (!p.stream_start_pending) return true;
    const id = c.gst_pad_create_stream_id(x.srcpad, @ptrCast(x), null);
    const ev = c.gst_event_new_stream_start(id);
    c.gst_event_set_group_id(ev, c.gst_util_group_id_next());
    const ok = c.gst_pad_push_event(x.srcpad, ev) != 0;
    p.stream_start_pending = false;
    c.g_free(id);
    return ok;
}

pub export fn gst_base_src_set_caps(s: [*c]Src, caps: [*c]Caps) c.gboolean {
    const x = of(s);
    _ = sendStreamStart(x);
    const current = c.gst_pad_get_current_caps(x.srcpad);
    defer if (current != null) c.gst_caps_unref(current);
    if (current != null and c.gst_caps_is_equal(current, caps) != 0) return 1;
    var ok: c.gboolean = 1;
    if (klass(x).set_caps) |f| ok = f(x, caps);
    if (ok != 0) ok = c.gst_pad_push_event(x.srcpad, c.gst_event_new_caps(caps));
    return ok;
}

fn defaultGetCaps(s: [*c]Src, filter: [*c]Caps) callconv(.c) [*c]Caps {
    const templ = c.gst_element_class_get_pad_template(@ptrCast(klass(s)), "src");
    if (templ == null) return null;
    var caps = c.gst_pad_template_get_caps(templ);
    if (filter != null) {
        const i = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = i;
    }
    return caps;
}

fn defaultFixate(_: [*c]Src, caps: [*c]Caps) callconv(.c) [*c]Caps {
    return c.gst_caps_fixate(caps);
}

fn fixate(x: *Src, caps: [*c]Caps) [*c]Caps {
    if (klass(x).fixate) |f| return f(x, caps);
    return caps;
}

fn seekable(x: *Src) bool {
    if (klass(x).is_seekable) |f| return f(x) != 0;
    return false;
}

fn defaultQuery(s: [*c]Src, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(s);
    switch (q[0].type) {
        c.GST_QUERY_POSITION => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_position(q, &format, null);
            if (format == c.GST_FORMAT_PERCENT) {
                el.lock(x);
                const pos: c.gint64 = @bitCast(x.segment.position);
                const dur: c.gint64 = @bitCast(x.segment.duration);
                el.unlock(x);
                var percent: c.gint64 = -1;
                if (pos != -1 and dur != -1) percent = if (pos < dur) @bitCast(c.gst_util_uint64_scale(c.GST_FORMAT_PERCENT_MAX, @bitCast(pos), @bitCast(dur))) else c.GST_FORMAT_PERCENT_MAX;
                c.gst_query_set_position(q, c.GST_FORMAT_PERCENT, percent);
                return 1;
            }
            el.lock(x);
            var pos: c.gint64 = @bitCast(c.gst_segment_to_stream_time(&x.segment, x.segment.format, x.segment.position));
            const sf = x.segment.format;
            el.unlock(x);
            var ok: c.gboolean = 1;
            if (pos != -1) ok = c.gst_pad_query_convert(x.srcpad, sf, pos, format, &pos);
            if (ok != 0) c.gst_query_set_position(q, format, pos);
            return ok;
        },
        c.GST_QUERY_DURATION => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_duration(q, &format, null);
            if (format == c.GST_FORMAT_PERCENT) {
                c.gst_query_set_duration(q, c.GST_FORMAT_PERCENT, c.GST_FORMAT_PERCENT_MAX);
                return 1;
            }
            var length: c.guint = 0;
            _ = updateLength(x, 0, &length, atomicGet(&priv(x).dynamic_size));
            el.lock(x);
            var dur: c.gint64 = @bitCast(x.segment.duration);
            const sf = x.segment.format;
            el.unlock(x);
            var ok: c.gboolean = 1;
            if (dur != -1) ok = c.gst_pad_query_convert(x.srcpad, sf, dur, format, &dur);
            if (ok != 0) c.gst_query_set_duration(q, format, dur);
            return ok;
        },
        c.GST_QUERY_SEEKING => {
            el.lock(x);
            const dur: c.gint64 = @bitCast(x.segment.duration);
            const sf = x.segment.format;
            el.unlock(x);
            var format: c.GstFormat = 0;
            c.gst_query_parse_seeking(q, &format, null, null, null);
            if (format != sf) return 0;
            c.gst_query_set_seeking(q, sf, @intFromBool(seekable(x)), 0, dur);
            return 1;
        },
        c.GST_QUERY_SEGMENT => {
            el.lock(x);
            defer el.unlock(x);
            const format = x.segment.format;
            const start: c.gint64 = @bitCast(c.gst_segment_to_stream_time(&x.segment, format, x.segment.start));
            var stop: c.gint64 = @bitCast(x.segment.stop);
            stop = if (stop == -1) @bitCast(x.segment.duration) else @bitCast(c.gst_segment_to_stream_time(&x.segment, format, x.segment.stop));
            c.gst_query_set_segment(q, x.segment.rate, format, start, stop);
            return 1;
        },
        c.GST_QUERY_FORMATS => {
            c.gst_query_set_formats(q, 3, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_BYTES, c.GST_FORMAT_PERCENT);
            return 1;
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: c.gint64 = 0;
            var dv: c.gint64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            var ok: c.gboolean = 0;
            if (sf == df) {
                dv = sv;
                ok = 1;
            }
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return ok;
        },
        c.GST_QUERY_LATENCY => {
            var min: c.GstClockTime = 0;
            var max: c.GstClockTime = 0;
            var live: c.gboolean = 0;
            const ok = gst_base_src_query_latency(x, &live, &min, &max);
            c.gst_query_set_latency(q, live, min, max);
            return ok;
        },
        c.GST_QUERY_JITTER, c.GST_QUERY_RATE => return 0,
        c.GST_QUERY_BUFFERING => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_buffering_range(q, &format, null, null, null);
            el.lock(x);
            var start: c.gint64 = -1;
            var stop: c.gint64 = -1;
            var estimated: c.gint64 = -1;
            if (x.random_access != 0) {
                estimated = 0;
                start = 0;
                stop = if (format == c.GST_FORMAT_PERCENT) c.GST_FORMAT_PERCENT_MAX else @bitCast(x.segment.duration);
            }
            const sf = x.segment.format;
            el.unlock(x);
            var ok: c.gboolean = 1;
            if (format != c.GST_FORMAT_PERCENT and stop != -1) ok = c.gst_pad_query_convert(x.srcpad, sf, stop, format, &stop);
            if (ok != 0 and format != c.GST_FORMAT_PERCENT and start != -1) ok = c.gst_pad_query_convert(x.srcpad, sf, start, format, &start);
            c.gst_query_set_buffering_range(q, format, start, stop, estimated);
            return ok;
        },
        c.GST_QUERY_SCHEDULING => {
            const random = isRandomAccess(x);
            c.gst_query_set_scheduling(q, c.GST_SCHEDULING_FLAG_SEEKABLE, 1, -1, 0);
            if (random) c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PULL);
            c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
            return 1;
        },
        c.GST_QUERY_CAPS => {
            var caps: [*c]Caps = null;
            if (el.flags(x.srcpad) & c.GST_PAD_FLAG_FIXED_CAPS != 0) caps = c.gst_pad_get_current_caps(x.srcpad);
            if (caps == null) {
                if (klass(x).get_caps) |f| {
                    var filter: [*c]Caps = null;
                    c.gst_query_parse_caps(q, &filter);
                    caps = f(x, filter);
                }
            }
            if (caps == null) return 0;
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_URI => {
            if (!gtype.instanceOf(x, c.gst_uri_handler_get_type())) return 0;
            const uri = c.gst_uri_handler_get_uri(@ptrCast(x));
            if (uri == null) return 0;
            c.gst_query_set_uri(q, uri);
            c.g_free(uri);
            return 1;
        },
        else => return 0,
    }
}

fn padQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    if (klass(x).query) |f| return f(x, q);
    return 0;
}

fn defaultDoSeek(_: [*c]Src, segment: [*c]c.GstSegment) callconv(.c) c.gboolean {
    if (segment[0].format == c.GST_FORMAT_BYTES) {
        segment[0].time = segment[0].start;
    } else if (segment[0].start == 0) {
        segment[0].time = 0;
    } else return 0;
    return 1;
}

fn doSeek(x: *Src, segment: *c.GstSegment) bool {
    if (klass(x).do_seek) |f| return f(x, segment) != 0;
    return false;
}

fn relative(t: c.GstSeekType) bool {
    return t != c.GST_SEEK_TYPE_NONE and t != c.GST_SEEK_TYPE_SET;
}

fn defaultPrepareSeek(s: [*c]Src, ev: [*c]Event, segment: [*c]c.GstSegment) callconv(.c) c.gboolean {
    const x = of(s);
    var rate: f64 = 0;
    var fmt: c.GstFormat = 0;
    var flags_: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start: c.gint64 = 0;
    var stop: c.gint64 = 0;
    var update: c.gboolean = 0;
    c.gst_event_parse_seek(ev, &rate, &fmt, &flags_, &st, &start, &et, &stop);
    const dest = segment[0].format;
    if (fmt == dest) {
        _ = c.gst_segment_do_seek(segment, rate, fmt, flags_, st, @bitCast(start), et, @bitCast(stop), &update);
        return 1;
    }
    var ok: c.gboolean = 1;
    if (st != c.GST_SEEK_TYPE_NONE) {
        ok = c.gst_pad_query_convert(x.srcpad, fmt, start, dest, &start);
        st = c.GST_SEEK_TYPE_SET;
    }
    if (ok != 0 and et != c.GST_SEEK_TYPE_NONE) {
        ok = c.gst_pad_query_convert(x.srcpad, fmt, stop, dest, &stop);
        et = c.GST_SEEK_TYPE_SET;
    }
    if (ok != 0) ok = c.gst_segment_do_seek(segment, rate, dest, flags_, st, @bitCast(start), et, @bitCast(stop), &update);
    return ok;
}

fn prepareSeek(x: *Src, ev: [*c]Event, segment: *c.GstSegment) bool {
    if (klass(x).prepare_seek_segment) |f| return f(x, ev, segment) != 0;
    return false;
}

fn defaultAlloc(s: [*c]Src, _: c.guint64, size: c.guint, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const p = priv(s);
    var pool: ?*c.GstBufferPool = null;
    var allocator: ?*c.GstAllocator = null;
    el.lock(s);
    if (p.pool != null) {
        pool = @ptrCast(@alignCast(c.gst_object_ref(p.pool)));
    } else if (p.allocator != null) {
        allocator = @ptrCast(@alignCast(c.gst_object_ref(p.allocator)));
    }
    var params = p.params;
    el.unlock(s);
    defer {
        if (pool != null) c.gst_object_unref(pool);
        if (allocator != null) c.gst_object_unref(allocator);
    }
    if (pool != null) return c.gst_buffer_pool_acquire_buffer(pool, out, null);
    if (size == std.math.maxInt(c.guint)) return c.GST_FLOW_ERROR;
    out.* = c.gst_buffer_new_allocate(allocator, size, &params);
    if (out.* == null) return c.GST_FLOW_ERROR;
    return c.GST_FLOW_OK;
}

fn defaultCreate(s: [*c]Src, off: c.guint64, size: c.guint, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const k = klass(s);
    const alloc = k.alloc orelse return c.GST_FLOW_NOT_SUPPORTED;
    const fill = k.fill orelse return c.GST_FLOW_NOT_SUPPORTED;
    var buf: [*c]Buffer = out.*;
    if (buf == null) {
        const r = alloc(s, off, size, &buf);
        if (r != c.GST_FLOW_OK) return r;
    }
    if (size > 0) {
        const r = fill(s, off, size, buf);
        if (r != c.GST_FLOW_OK) {
            if (out.* == null) c.gst_buffer_unref(buf);
            return r;
        }
    }
    out.* = buf;
    return c.GST_FLOW_OK;
}

fn performSeek(x: *Src, ev: [*c]Event, unlock_: bool) bool {
    const p = priv(x);
    el.lock(x);
    const dest = x.segment.format;
    el.unlock(x);
    var rate: f64 = 0;
    var fmt: c.GstFormat = 0;
    var flags_: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start: c.gint64 = 0;
    var stop: c.gint64 = 0;
    var update: c.gboolean = 0;
    var seg: c.GstSegment = undefined;
    var configured = false;
    var flush = false;
    var seqnum: c.guint32 = 0;
    if (ev != null) {
        c.gst_event_parse_seek(ev, &rate, &fmt, &flags_, &st, &start, &et, &stop);
        const rel = relative(st) or relative(et);
        if (dest != fmt and !rel) {
            c.gst_segment_init(&seg, dest);
            if (!prepareSeek(x, ev, &seg)) return false;
            configured = true;
        }
        flush = flags_ & c.GST_SEEK_FLAG_FLUSH != 0;
        seqnum = c.gst_event_get_seqnum(ev);
    } else {
        seqnum = c.gst_util_seqnum_next();
    }
    if (flush) {
        const t = c.gst_event_new_flush_start();
        c.gst_event_set_seqnum(t, seqnum);
        _ = c.gst_pad_push_event(x.srcpad, t);
    } else {
        _ = c.gst_pad_pause_task(x.srcpad);
    }
    if (unlock_) _ = setFlushing(x, true);
    el.streamLock(x.srcpad);
    if (p.seqnum != seqnum) p.seqnum = seqnum;
    if (unlock_) _ = setFlushing(x, false);
    var ok = true;
    if (!configured) {
        seg = x.segment;
        if (ev != null) {
            if (seg.format != fmt) {
                if (!prepareSeek(x, ev, &seg)) ok = false;
            } else {
                _ = c.gst_segment_do_seek(&seg, rate, fmt, flags_, st, @bitCast(start), et, @bitCast(stop), &update);
            }
        }
    }
    if (ok) ok = doSeek(x, &seg);
    if (flush) {
        const t = c.gst_event_new_flush_stop(1);
        c.gst_event_set_seqnum(t, seqnum);
        _ = c.gst_pad_push_event(x.srcpad, t);
    }
    if (ok and seg.format != dest) ok = false;
    if (ok) {
        el.lock(x);
        x.segment = seg;
        el.unlock(x);
        if (seg.flags & c.GST_SEGMENT_FLAG_SEGMENT != 0) {
            const m = c.gst_message_new_segment_start(@ptrCast(x), seg.format, @bitCast(seg.position));
            c.gst_message_set_seqnum(m, seqnum);
            _ = c.gst_element_post_message(@ptrCast(x), m);
        }
        el.lock(x);
        p.segment_pending = true;
        p.segment_seqnum = seqnum;
        el.unlock(x);
    }
    p.discont = true;
    x.running = 1;
    const started_task = c.gst_pad_start_task(x.srcpad, loop, x.srcpad, null) != 0;
    if (ok and !started_task) ok = false;
    el.streamUnlock(x.srcpad);
    return ok;
}

fn startLoop(x: *Src) void {
    _ = c.gst_pad_start_task(x.srcpad, loop, x.srcpad, null);
}

fn sendEvent(e: [*c]c.GstElement, ev_in: [*c]Event) callconv(.c) c.gboolean {
    const x = of(e);
    const p = priv(x);
    const k = klass(x);
    var ev = ev_in;
    var result: c.gboolean = 0;
    switch (ev[0].type) {
        c.GST_EVENT_FLUSH_START => {
            result = c.gst_pad_push_event(x.srcpad, ev);
            _ = setFlushing(x, true);
            ev = null;
        },
        c.GST_EVENT_FLUSH_STOP => {
            el.streamLock(x.srcpad);
            _ = setFlushing(x, false);
            result = c.gst_pad_push_event(x.srcpad, ev);
            liveLock(x);
            el.lock(x.srcpad);
            p.segment_pending = true;
            var start = el.mode(x.srcpad) == c.GST_PAD_MODE_PUSH;
            el.unlock(x.srcpad);
            if (x.is_live != 0 and x.live_running == 0) start = false;
            if (start) startLoop(x);
            liveUnlock(x);
            el.streamUnlock(x.srcpad);
            ev = null;
        },
        c.GST_EVENT_EOS => {
            const push = el.modeLocked(x.srcpad) == c.GST_PAD_MODE_PUSH;
            if (push) {
                _ = setFlushing(x, true);
                el.streamLock(x.srcpad);
                _ = setFlushing(x, false);
                el.lock(x);
                atomicSet(&p.has_pending_eos, true);
                if (p.pending_eos != null) c.gst_event_unref(p.pending_eos);
                p.pending_eos = ev;
                el.unlock(x);
                startLoop(x);
                el.streamUnlock(x.srcpad);
            } else {
                el.lock(x);
                atomicSet(&p.has_pending_eos, true);
                if (p.pending_eos != null) c.gst_event_unref(p.pending_eos);
                p.pending_eos = ev;
                el.unlock(x);
                poolFlushing(x, true);
                if (k.unlock) |f| _ = f(x);
                el.streamLock(x.srcpad);
                if (k.unlock_stop) |f| _ = f(x);
                poolFlushing(x, true);
                el.streamUnlock(x.srcpad);
            }
            ev = null;
            result = 1;
        },
        c.GST_EVENT_TAG, c.GST_EVENT_SINK_MESSAGE, c.GST_EVENT_CUSTOM_DOWNSTREAM, c.GST_EVENT_CUSTOM_BOTH, c.GST_EVENT_PROTECTION => {
            el.lock(x);
            p.pending_events = c.g_list_append(p.pending_events, ev);
            atomicSet(&p.have_events, true);
            el.unlock(x);
            ev = null;
            result = 1;
        },
        c.GST_EVENT_SEEK => {
            el.lock(x.srcpad);
            const m = el.mode(x.srcpad);
            if (m == c.GST_PAD_MODE_PULL) {
                el.unlock(x.srcpad);
                result = 0;
            } else {
                el.unlock(x.srcpad);
                if (m == c.GST_PAD_MODE_PUSH) {
                    result = @intFromBool(performSeek(x, ev, true));
                } else {
                    el.lock(x);
                    _ = c.gst_event_replace(&x.pending_seek, ev);
                    el.unlock(x);
                    result = 1;
                }
            }
        },
        c.GST_EVENT_CUSTOM_DOWNSTREAM_OOB, c.GST_EVENT_CUSTOM_BOTH_OOB => {
            result = c.gst_pad_push_event(x.srcpad, ev);
            ev = null;
        },
        else => {},
    }
    if (ev != null) c.gst_event_unref(ev);
    return result;
}

fn updateQos(x: *Src, proportion: f64, diff: c.GstClockTimeDiff, ts: c.GstClockTime) void {
    el.lock(x);
    priv(x).proportion = proportion;
    priv(x).earliest_time = ts +% @as(u64, @bitCast(diff));
    el.unlock(x);
}

fn defaultEvent(s: [*c]Src, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(s);
    switch (ev[0].type) {
        c.GST_EVENT_SEEK => {
            if (!seekable(x)) return 0;
            return @intFromBool(performSeek(x, ev, true));
        },
        c.GST_EVENT_FLUSH_START => return @intFromBool(setFlushing(x, true)),
        c.GST_EVENT_FLUSH_STOP => return @intFromBool(setFlushing(x, false)),
        c.GST_EVENT_QOS => {
            var proportion: f64 = 0;
            var diff: c.GstClockTimeDiff = 0;
            var ts: c.GstClockTime = 0;
            c.gst_event_parse_qos(ev, null, &proportion, &diff, &ts);
            updateQos(x, proportion, diff, ts);
            return 1;
        },
        c.GST_EVENT_RECONFIGURE, c.GST_EVENT_LATENCY => return 1,
        else => return 0,
    }
}

fn padEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    var result: c.gboolean = 0;
    if (klass(x).event) |f| result = f(x, ev);
    c.gst_event_unref(ev);
    return result;
}

fn setProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const x = of(o);
    switch (id) {
        PROP_BLOCKSIZE => gst_base_src_set_blocksize(x, c.g_value_get_uint(v)),
        PROP_NUM_BUFFERS => x.num_buffers = c.g_value_get_int(v),
        PROP_TYPEFIND => x.typefind = c.g_value_get_boolean(v),
        PROP_DO_TIMESTAMP => gst_base_src_set_do_timestamp(x, c.g_value_get_boolean(v)),
        PROP_AUTOMATIC_EOS => gst_base_src_set_automatic_eos(x, c.g_value_get_boolean(v)),
        else => el.badProperty(o, id, pspec, FILE, 2232),
    }
}

fn getProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const x = of(o);
    switch (id) {
        PROP_BLOCKSIZE => c.g_value_set_uint(v, gst_base_src_get_blocksize(x)),
        PROP_NUM_BUFFERS => c.g_value_set_int(v, x.num_buffers),
        PROP_TYPEFIND => c.g_value_set_boolean(v, x.typefind),
        PROP_DO_TIMESTAMP => c.g_value_set_boolean(v, gst_base_src_get_do_timestamp(x)),
        PROP_AUTOMATIC_EOS => c.g_value_set_boolean(v, @intFromBool(atomicGet(&priv(x).automatic_eos))),
        else => el.badProperty(o, id, pspec, FILE, 2264),
    }
}

fn clockWait(x: *Src, clock: ?*c.GstClock, time: c.GstClockTime) c.GstClockReturn {
    const id = c.gst_clock_new_single_shot_id(clock, time);
    x.clock_id = id;
    liveUnlock(x);
    const r = c.gst_clock_id_wait(id, null);
    liveLock(x);
    c.gst_clock_id_unref(id);
    x.clock_id = null;
    return r;
}

fn doSync(x: *Src, buf: [*c]Buffer) c.GstClockReturn {
    const p = priv(x);
    var start: c.GstClockTime = NONE;
    var end: c.GstClockTime = NONE;
    if (klass(x).get_times) |f| f(x, buf, &start, &end);
    var dts = buf[0].dts;
    var pts = buf[0].pts;
    const ts = if (dts != NONE) dts else pts;
    el.lock(x);
    const live = x.is_live != 0;
    const pseudo = start != NONE and live;
    const first = p.latency == NONE;
    if (ts != NONE and pseudo) {
        const latency = if (ts <= start) start - ts else 0;
        p.latency = latency;
    } else if (first) {
        p.latency = 0;
    }
    const clock = x.element.clock;
    if (clock == null) {
        el.unlock(x);
        return c.GST_CLOCK_OK;
    }
    _ = c.gst_object_ref(clock);
    const base_time: c.GstClockTime = @bitCast(x.element.base_time);
    const do_ts = p.do_timestamp;
    el.unlock(x);
    defer c.gst_object_unref(clock);
    if (first) {
        const now = c.gst_clock_get_time(clock);
        const running = now -% base_time;
        p.ts_offset = if (pseudo and ts != NONE) @as(c.GstClockTimeDiff, @bitCast(running)) -% @as(c.GstClockTimeDiff, @bitCast(ts)) else 0;
        if (dts == NONE) {
            if (do_ts) {
                dts = running;
            } else if (pts == NONE) {
                dts = if (x.segment.start != NONE) x.segment.start else 0;
            }
            buf[0].dts = dts;
        }
    } else if (do_ts and dts == NONE) {
        dts = c.gst_clock_get_time(clock) -% base_time;
        buf[0].dts = dts;
    }
    if (pts == NONE) {
        if (buf[0].mini_object.flags & c.GST_BUFFER_FLAG_DELTA_UNIT == 0) pts = dts;
        buf[0].pts = dts;
    }
    if (start == NONE) return c.GST_CLOCK_OK;
    if (live) {
        const off: u64 = @bitCast(p.ts_offset);
        if (pts != NONE) buf[0].pts +%= off;
        if (dts != NONE) buf[0].dts +%= off;
        start +%= off;
    }
    return clockWait(x, clock, start +% base_time);
}

fn updateLength(x: *Src, off: c.guint64, length: *c.guint, force: bool) bool {
    if (x.segment.format != c.GST_FORMAT_BYTES) return true;
    const p = priv(x);
    const stop = x.segment.stop;
    var size = x.segment.duration;
    const auto = atomicGet(&p.automatic_eos);
    var maxsize: u64 = if (!auto) stop else if (stop != NONE) (if (size != NONE) @min(size, stop) else stop) else size;
    if (maxsize != NONE) {
        if (off >= maxsize or off +% length.* >= maxsize or force) {
            if (klass(x).get_size) |f| {
                if (f(x, &size) == 0) size = NONE;
            }
            maxsize = if (!auto) stop else if (stop != NONE) (if (size != NONE) @min(size, stop) else stop) else size;
            if (maxsize != NONE) {
                if (off >= maxsize) return false;
                if (off +% length.* >= maxsize) length.* = @truncate(maxsize - off);
            }
        }
    }
    el.lock(x);
    x.segment.duration = size;
    el.unlock(x);
    return true;
}

fn getRange(x: *Src, off: c.guint64, length_in: c.guint, out: [*c][*c]Buffer) c.GstFlowReturn {
    const p = priv(x);
    const k = klass(x);
    var length = length_in;
    again: while (true) {
        if (x.is_live != 0 and x.live_running == 0) {
            const r = waitPlayingUnlocked(x);
            if (r != c.GST_FLOW_OK) return r;
        }
        if (!started(x) and !starting(x)) return c.GST_FLOW_FLUSHING;
        const create = k.create orelse return c.GST_FLOW_NOT_SUPPORTED;
        if (!updateLength(x, off, &length, false)) return c.GST_FLOW_EOS;
        el.lock(x);
        if (x.segment.format == c.GST_FORMAT_BYTES) x.segment.position = off;
        el.unlock(x);
        if (x.num_buffers_left >= 0) {
            if (x.num_buffers_left == 0) return c.GST_FLOW_EOS;
            x.num_buffers_left -= 1;
        }
        if (atomicGet(&p.has_pending_eos)) {
            p.forced_eos = true;
            return c.GST_FLOW_EOS;
        }
        const in_buf = out.*;
        var res: [*c]Buffer = in_buf;
        var own = in_buf == null;
        var ret: c.GstFlowReturn = undefined;
        while (true) {
            liveUnlock(x);
            el.lock(x);
            const pending_stop = p.pending_unlock_stop;
            p.pending_unlock_stop = false;
            el.unlock(x);
            if (pending_stop) {
                if (k.unlock_stop) |f| _ = f(x);
            }
            ret = create(x, off, length, &res);
            liveLock(x);
            if (x.is_live != 0 and x.live_running == 0) {
                if (ret == c.GST_FLOW_OK and own) c.gst_clear_buffer(&res);
                c.gst_clear_buffer_list(&p.pending_bufferlist);
                const w = waitPlayingUnlocked(x);
                if (w != c.GST_FLOW_OK) return w;
                continue;
            }
            break;
        }
        if (atomicGet(&p.has_pending_eos)) {
            if (ret == c.GST_FLOW_OK) {
                if (own) c.gst_clear_buffer(&res);
                c.gst_clear_buffer_list(&p.pending_bufferlist);
            }
            p.forced_eos = true;
            return c.GST_FLOW_EOS;
        }
        if (ret != c.GST_FLOW_OK) return ret;
        if (in_buf != null and res != in_buf) {
            var info: c.GstMapInfo = undefined;
            if (c.gst_buffer_map(in_buf, &info, c.GST_MAP_WRITE) == 0) {
                el.err(x, .resource, c.GST_RESOURCE_ERROR_BUSY, "Failed to map buffer.", c.g_strdup("failed to map result buffer in WRITE mode"), FILE, "gst_base_src_get_range", 2777);
                if (own) c.gst_buffer_unref(res);
                return c.GST_FLOW_ERROR;
            }
            const copied = c.gst_buffer_extract(res, 0, info.data, info.size);
            c.gst_buffer_unmap(in_buf, &info);
            c.gst_buffer_set_size(in_buf, @intCast(copied));
            _ = c.gst_buffer_copy_into(in_buf, res, c.GST_BUFFER_COPY_METADATA, 0, std.math.maxInt(c.gsize));
            c.gst_buffer_unref(res);
            res = in_buf;
        }
        if (res == null) {
            const list = p.pending_bufferlist;
            if (list == null or c.gst_buffer_list_length(list) == 0) {
                el.err(x, .stream, c.GST_STREAM_ERROR_FAILED, "Internal data flow error.", c.g_strdup_printf("Subclass %s neither returned a buffer nor submitted a buffer list from its create function", c.g_type_name(gtype.typeOf(x))), FILE, "gst_base_src_get_range", 2819);
                return c.GST_FLOW_ERROR;
            }
            res = c.gst_buffer_list_get_writable(list, 0);
            own = false;
        }
        if (off == 0 and x.segment.time == 0 and res[0].dts == NONE and x.is_live == 0) {
            res = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(res))));
            res[0].dts = 0;
        }
        const status = doSync(x, res);
        if (p.flushing) {
            if (own) c.gst_buffer_unref(res);
            return c.GST_FLOW_FLUSHING;
        }
        switch (status) {
            c.GST_CLOCK_EARLY, c.GST_CLOCK_OK => {},
            c.GST_CLOCK_UNSCHEDULED => {
                if (own) c.gst_buffer_unref(res);
                if (x.live_running == 0) {
                    ret = c.GST_FLOW_FLUSHING;
                } else continue :again;
            },
            else => {
                el.err(x, .core, c.GST_CORE_ERROR_CLOCK, "Internal clock error.", c.g_strdup_printf("clock returned unexpected return value %d", status), FILE, "gst_base_src_get_range", 2749);
                if (own) c.gst_buffer_unref(res);
                ret = c.GST_FLOW_ERROR;
            },
        }
        if (ret == c.GST_FLOW_OK) out.* = res;
        return ret;
    }
}

fn getRangeFn(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, off: c.guint64, length: c.guint, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const x = of(parent_obj);
    liveLock(x);
    defer liveUnlock(x);
    if (priv(x).flushing) return c.GST_FLOW_FLUSHING;
    return getRange(x, off, length, out);
}

fn isRandomAccess(x: *Src) bool {
    if (!started(x)) {
        if (startSrc(x)) {
            if (gst_base_src_start_wait(x) != c.GST_FLOW_OK) return false;
            _ = stopSrc(x);
        }
    }
    return x.random_access != 0;
}

fn loop(data: c.gpointer) callconv(.c) void {
    const pad: ?*c.GstPad = @ptrCast(@alignCast(data));
    const x = of(el.obj(pad).parent);
    const p = priv(x);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    run: {
        liveLock(x);
        if (p.flushing or el.flags(pad) & c.GST_PAD_FLAG_FLUSHING != 0) {
            liveUnlock(x);
            ret = c.GST_FLOW_FLUSHING;
            break :run;
        }
        liveUnlock(x);
        if (el.flags(pad) & c.GST_PAD_FLAG_EOS != 0) {
            _ = c.gst_pad_pause_task(pad);
            return;
        }
        _ = sendStreamStart(x);
        liveLock(x);
        if (p.flushing or el.flags(pad) & c.GST_PAD_FLAG_FLUSHING != 0) {
            liveUnlock(x);
            ret = c.GST_FLOW_FLUSHING;
            break :run;
        }
        liveUnlock(x);
        if (c.gst_pad_check_reconfigure(pad) != 0) {
            if (!negotiateUnlocked(x)) {
                c.gst_pad_mark_reconfigure(pad);
                ret = if (el.flags(pad) & c.GST_PAD_FLAG_FLUSHING != 0) c.GST_FLOW_FLUSHING else c.GST_FLOW_NOT_NEGOTIATED;
                break :run;
            }
        }
        liveLock(x);
        if (p.flushing or el.flags(pad) & c.GST_PAD_FLAG_FLUSHING != 0) {
            liveUnlock(x);
            ret = c.GST_FLOW_FLUSHING;
            break :run;
        }
        var blocksize = x.blocksize;
        var position: c.gint64 = -1;
        if (x.segment.format == c.GST_FORMAT_BYTES) {
            position = @bitCast(x.segment.position);
            if (x.segment.rate < 0.0) {
                const st: c.gint64 = @bitCast(x.segment.start);
                if (position > st + blocksize) {
                    position -= blocksize;
                } else {
                    blocksize = @truncate(@as(u64, @bitCast(position - st)));
                    position = st;
                }
            }
        }
        if (p.pending_bufferlist != null) {
            c.gst_buffer_list_unref(p.pending_bufferlist);
            p.pending_bufferlist = null;
        }
        var buf: [*c]Buffer = null;
        ret = getRange(x, @bitCast(position), blocksize, &buf);
        if (ret != c.GST_FLOW_OK) {
            liveUnlock(x);
            break :run;
        }
        var seg_event: [*c]Event = null;
        if (p.segment_pending) {
            seg_event = c.gst_event_new_segment(&x.segment);
            el.lock(x);
            c.gst_event_set_seqnum(seg_event, p.segment_seqnum);
            p.segment_seqnum = c.gst_util_seqnum_next();
            p.segment_pending = false;
            el.unlock(x);
        }
        var pending: ?*c.GList = null;
        if (atomicGet(&p.have_events)) {
            el.lock(x);
            pending = p.pending_events;
            p.pending_events = null;
            atomicSet(&p.have_events, false);
            el.unlock(x);
        }
        liveUnlock(x);
        if (seg_event != null) _ = c.gst_pad_push_event(pad, seg_event);
        if (pending != null) {
            var l = pending;
            while (l) |n| : (l = n.next) _ = c.gst_pad_push_event(pad, @ptrCast(@alignCast(n.data)));
            c.g_list_free(pending);
        }
        switch (x.segment.format) {
            c.GST_FORMAT_BYTES => {
                if (x.segment.rate >= 0.0) position += @intCast(c.gst_buffer_get_size(buf));
            },
            c.GST_FORMAT_TIME => {
                const st = buf[0].pts;
                const dur = buf[0].duration;
                position = if (st != NONE) @bitCast(st) else @bitCast(x.segment.position);
                if (dur != NONE and x.segment.rate >= 0.0) position +%= @bitCast(dur);
            },
            c.GST_FORMAT_DEFAULT => position = if (x.segment.rate >= 0.0) @bitCast(buf[0].offset_end) else @bitCast(buf[0].offset),
            else => position = -1,
        }
        var eos = false;
        if (position != -1) {
            if (x.segment.rate >= 0.0) {
                if (x.segment.stop != NONE and @as(u64, @bitCast(position)) >= x.segment.stop) {
                    if (atomicGet(&p.automatic_eos)) eos = true;
                    position = @bitCast(x.segment.stop);
                }
            } else {
                if (@as(u64, @bitCast(position)) <= x.segment.start) {
                    if (atomicGet(&p.automatic_eos)) eos = true;
                    position = @bitCast(x.segment.start);
                }
                p.discont = true;
            }
            el.lock(x);
            x.segment.position = @bitCast(position);
            el.unlock(x);
        }
        if (p.discont) {
            buf = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(buf))));
            buf[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
            p.discont = false;
        }
        if (p.pending_bufferlist != null) {
            ret = c.gst_pad_push_list(pad, p.pending_bufferlist);
            p.pending_bufferlist = null;
        } else {
            ret = c.gst_pad_push(pad, buf);
        }
        if (ret != c.GST_FLOW_OK) {
            if (ret == c.GST_FLOW_NOT_NEGOTIATED and c.gst_pad_needs_reconfigure(pad) != 0) return;
            break :run;
        }
        if (eos and !p.segment_pending) {
            ret = c.GST_FLOW_EOS;
            break :run;
        }
        return;
    }
    pause(x, pad, ret);
}

fn pause(x: *Src, pad: ?*c.GstPad, ret: c.GstFlowReturn) void {
    const p = priv(x);
    x.running = 0;
    _ = c.gst_pad_pause_task(pad);
    if (ret == c.GST_FLOW_EOS) {
        const flag_segment = x.segment.flags & c.GST_SEGMENT_FLAG_SEGMENT != 0;
        const format = x.segment.format;
        const position: c.gint64 = @bitCast(x.segment.position);
        var ev: [*c]Event = null;
        if (p.forced_eos) {
            el.lock(x);
            ev = p.pending_eos;
            p.pending_eos = null;
            el.unlock(x);
        } else if (flag_segment) {
            const m = c.gst_message_new_segment_done(@ptrCast(x), format, position);
            c.gst_message_set_seqnum(m, p.seqnum);
            _ = c.gst_element_post_message(@ptrCast(x), m);
            ev = c.gst_event_new_segment_done(format, position);
            c.gst_event_set_seqnum(ev, p.seqnum);
        } else {
            ev = c.gst_event_new_eos();
            c.gst_event_set_seqnum(ev, p.seqnum);
        }
        _ = c.gst_pad_push_event(pad, ev);
        p.forced_eos = false;
    } else if (ret == c.GST_FLOW_NOT_LINKED or ret <= c.GST_FLOW_EOS) {
        const ev = c.gst_event_new_eos();
        c.gst_event_set_seqnum(ev, p.seqnum);
        el.flowError(x, ret, FILE, "gst_base_src_loop", 3187);
        _ = c.gst_pad_push_event(pad, ev);
    }
}

fn setAllocation(x: *Src, pool: ?*c.GstBufferPool, allocator: ?*c.GstAllocator, params: ?*const c.GstAllocationParams) bool {
    const p = priv(x);
    if (pool != null and c.gst_buffer_pool_set_active(pool, 1) == 0) return false;
    el.lock(x);
    const oldpool = p.pool;
    p.pool = pool;
    const oldalloc = p.allocator;
    p.allocator = allocator;
    if (p.pool != null) _ = c.gst_object_ref(p.pool);
    if (p.allocator != null) _ = c.gst_object_ref(p.allocator);
    if (params) |pp| p.params = pp.* else c.gst_allocation_params_init(&p.params);
    el.unlock(x);
    if (oldpool != null) {
        if (oldpool != pool) _ = c.gst_buffer_pool_set_active(oldpool, 0);
        c.gst_object_unref(oldpool);
    }
    if (oldalloc != null) c.gst_object_unref(oldalloc);
    return true;
}

fn poolFlushing(x: *Src, flushing: bool) void {
    el.lock(x);
    const pool = priv(x).pool;
    if (pool != null) _ = c.gst_object_ref(pool);
    el.unlock(x);
    if (pool == null) return;
    c.gst_buffer_pool_set_flushing(pool, @intFromBool(flushing));
    c.gst_object_unref(pool);
}

fn defaultDecideAllocation(s: [*c]Src, q: [*c]Query) callconv(.c) c.gboolean {
    var outcaps: [*c]Caps = null;
    c.gst_query_parse_allocation(q, &outcaps, null);
    var allocator: ?*c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    var update = false;
    if (c.gst_query_get_n_allocation_params(q) > 0) {
        c.gst_query_parse_nth_allocation_param(q, 0, &allocator, &params);
        update = true;
    } else {
        c.gst_allocation_params_init(&params);
    }
    var pool: ?*c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    if (c.gst_query_get_n_allocation_pools(q) > 0) {
        c.gst_query_parse_nth_allocation_pool(q, 0, &pool, &size, &min, &max);
        if (pool == null) pool = c.gst_buffer_pool_new();
    }
    if (pool != null) {
        var config = c.gst_buffer_pool_get_config(pool);
        c.gst_buffer_pool_config_set_params(config, outcaps, size, min, max);
        c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
        if (c.gst_buffer_pool_set_config(pool, config) == 0) {
            config = c.gst_buffer_pool_get_config(pool);
            if (c.gst_buffer_pool_config_validate_params(config, outcaps, size, min, max) == 0) {
                c.gst_structure_free(config);
                c.gst_clear_object(@ptrCast(&pool));
            } else if (c.gst_buffer_pool_set_config(pool, config) == 0) {
                c.gst_clear_object(@ptrCast(&pool));
            }
            if (pool == null) {
                pool = c.gst_buffer_pool_new();
                config = c.gst_buffer_pool_get_config(pool);
                c.gst_buffer_pool_config_set_params(config, outcaps, size, min, max);
                c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
                if (c.gst_buffer_pool_set_config(pool, config) == 0) {
                    el.err(s, .resource, c.GST_RESOURCE_ERROR_SETTINGS, null, c.g_strdup("Configuration is most likely invalid, please report this issue."), FILE, "gst_base_src_decide_allocation_default", 3351);
                    c.gst_object_unref(pool);
                    return 0;
                }
            }
        }
    }
    if (update) c.gst_query_set_nth_allocation_param(q, 0, allocator, &params) else c.gst_query_add_allocation_param(q, allocator, &params);
    if (allocator != null) c.gst_object_unref(allocator);
    if (pool != null) {
        c.gst_query_set_nth_allocation_pool(q, 0, pool, size, min, max);
        c.gst_object_unref(pool);
    }
    return 1;
}

fn prepareAllocation(x: *Src, caps: [*c]Caps) bool {
    const q = c.gst_query_new_allocation(caps, 1);
    defer c.gst_query_unref(q);
    _ = c.gst_pad_peer_query(x.srcpad, q);
    const decide = klass(x).decide_allocation.?;
    if (decide(x, q) == 0) return false;
    var allocator: ?*c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_query_get_n_allocation_params(q) > 0) {
        c.gst_query_parse_nth_allocation_param(q, 0, &allocator, &params);
    } else {
        c.gst_allocation_params_init(&params);
    }
    var pool: ?*c.GstBufferPool = null;
    if (c.gst_query_get_n_allocation_pools(q) > 0) c.gst_query_parse_nth_allocation_pool(q, 0, &pool, null, null, null);
    const ok = setAllocation(x, pool, allocator, &params);
    if (allocator != null) c.gst_object_unref(allocator);
    if (pool != null) c.gst_object_unref(pool);
    return ok;
}

fn defaultNegotiate(s: [*c]Src) callconv(.c) c.gboolean {
    const x = of(s);
    const thiscaps = c.gst_pad_query_caps(x.srcpad, null);
    if (thiscaps == null or c.gst_caps_is_any(thiscaps) != 0) {
        if (thiscaps != null) c.gst_caps_unref(thiscaps);
        return 1;
    }
    if (c.gst_caps_is_empty(thiscaps) != 0) {
        el.err(x, .stream, c.GST_STREAM_ERROR_FORMAT, "No supported formats found", c.g_strdup("This element did not produce valid caps"), FILE, "gst_base_src_default_negotiate", 3489);
        c.gst_caps_unref(thiscaps);
        return 1;
    }
    const peercaps = c.gst_pad_peer_query_caps(x.srcpad, thiscaps);
    var caps = thiscaps;
    if (peercaps != null) {
        caps = peercaps;
        c.gst_caps_unref(thiscaps);
    }
    var result: c.gboolean = 0;
    if (caps != null and c.gst_caps_is_empty(caps) == 0) {
        if (c.gst_caps_is_any(caps) != 0) {
            result = 1;
        } else {
            caps = fixate(x, caps);
            if (c.gst_caps_is_fixed(caps) != 0) result = gst_base_src_set_caps(x, caps);
        }
        c.gst_caps_unref(caps);
    } else if (caps != null) {
        c.gst_caps_unref(caps);
    }
    return result;
}

fn negotiateUnlocked(x: *Src) bool {
    var ok = true;
    if (klass(x).negotiate) |f| ok = f(x) != 0;
    if (ok) {
        const caps = c.gst_pad_get_current_caps(x.srcpad);
        ok = prepareAllocation(x, caps);
        if (caps != null) c.gst_caps_unref(caps);
    }
    return ok;
}

pub export fn gst_base_src_negotiate(s: [*c]Src) c.gboolean {
    if (!check.that(isSrc(s), "gst_base_src_negotiate", "GST_IS_BASE_SRC (src)")) return 0;
    const x = of(s);
    el.streamLock(x.srcpad);
    defer el.streamUnlock(x.srcpad);
    _ = c.gst_pad_check_reconfigure(x.srcpad);
    const ok = negotiateUnlocked(x);
    if (!ok) c.gst_pad_mark_reconfigure(x.srcpad);
    return @intFromBool(ok);
}

fn startSrc(x: *Src) bool {
    const p = priv(x);
    liveLock(x);
    el.lock(x);
    if (starting(x) or started(x)) {
        el.unlock(x);
        liveUnlock(x);
        return true;
    }
    p.start_result = c.GST_FLOW_FLUSHING;
    el.setFlag(x, c.GST_BASE_SRC_FLAG_STARTING);
    c.gst_segment_init(&x.segment, x.segment.format);
    el.unlock(x);
    x.num_buffers_left = x.num_buffers;
    x.running = 0;
    p.segment_pending = false;
    p.segment_seqnum = c.gst_util_seqnum_next();
    p.forced_eos = false;
    liveUnlock(x);
    var ok = true;
    if (klass(x).start) |f| ok = f(x) != 0;
    if (!ok) {
        el.err(x, .core, c.GST_CORE_ERROR_STATE_CHANGE, null, c.g_strdup("Failed to start"), FILE, "gst_base_src_start", 3623);
        gst_base_src_start_complete(x, c.GST_FLOW_ERROR);
        return false;
    }
    if (gst_base_src_is_async(x) == 0) {
        gst_base_src_start_complete(x, c.GST_FLOW_OK);
        ok = gst_base_src_start_wait(x) == c.GST_FLOW_OK;
    }
    return ok;
}

fn startFailed(x: *Src, ret: c.GstFlowReturn) void {
    el.lock(x);
    priv(x).start_result = ret;
    el.unsetFlag(x, c.GST_BASE_SRC_FLAG_STARTING);
    c.g_cond_signal(&priv(x).async_cond);
    el.unlock(x);
}

pub export fn gst_base_src_start_complete(s: [*c]Src, ret: c.GstFlowReturn) void {
    const x = of(s);
    if (ret != c.GST_FLOW_OK) return startFailed(x, ret);
    const format = x.segment.format;
    if (format == c.GST_FORMAT_BYTES) {
        var size: c.guint64 = NONE;
        if (klass(x).get_size) |f| {
            if (f(x, &size) == 0) size = NONE;
        }
        el.lock(x);
        x.segment.duration = size;
        el.unlock(x);
    }
    x.random_access = @intFromBool(seekable(x) and format == c.GST_FORMAT_BYTES);
    c.gst_pad_mark_reconfigure(x.srcpad);
    const m = el.modeLocked(x.srcpad);
    el.streamLock(x.srcpad);
    switch (m) {
        c.GST_PAD_MODE_PUSH => {
            el.lock(x);
            const ev = x.pending_seek;
            x.pending_seek = null;
            el.unlock(x);
            if (!performSeek(x, ev, false)) {
                el.streamUnlock(x.srcpad);
                _ = stopSrc(x);
                if (ev != null) c.gst_event_unref(ev);
                return startFailed(x, c.GST_FLOW_ERROR);
            }
            if (ev != null) c.gst_event_unref(ev);
        },
        c.GST_PAD_MODE_PULL => {
            if (x.random_access == 0) {
                el.streamUnlock(x.srcpad);
                _ = stopSrc(x);
                return startFailed(x, c.GST_FLOW_ERROR);
            }
        },
        else => {
            el.streamUnlock(x.srcpad);
            _ = stopSrc(x);
            return startFailed(x, c.GST_FLOW_ERROR);
        },
    }
    el.lock(x);
    el.setFlag(x, c.GST_BASE_SRC_FLAG_STARTED);
    el.unsetFlag(x, c.GST_BASE_SRC_FLAG_STARTING);
    priv(x).start_result = ret;
    c.g_cond_signal(&priv(x).async_cond);
    el.unlock(x);
    el.streamUnlock(x.srcpad);
}

pub export fn gst_base_src_start_wait(s: [*c]Src) c.GstFlowReturn {
    const x = of(s);
    el.lock(x);
    defer el.unlock(x);
    while (starting(x)) c.g_cond_wait(&priv(x).async_cond, &el.obj(x).lock);
    return priv(x).start_result;
}

fn stopSrc(x: *Src) bool {
    const p = priv(x);
    _ = setFlushing(x, true);
    _ = c.gst_pad_stop_task(x.srcpad);
    _ = setFlushing(x, false);
    el.lock(x);
    if (!started(x) and !starting(x)) {
        el.unlock(x);
        return true;
    }
    el.unsetFlag(x, c.GST_BASE_SRC_FLAG_STARTING);
    el.unsetFlag(x, c.GST_BASE_SRC_FLAG_STARTED);
    p.start_result = c.GST_FLOW_FLUSHING;
    c.g_cond_signal(&p.async_cond);
    el.unlock(x);
    var ok = true;
    if (klass(x).stop) |f| ok = f(x) != 0;
    if (p.pending_bufferlist != null) {
        c.gst_buffer_list_unref(p.pending_bufferlist);
        p.pending_bufferlist = null;
    }
    _ = setAllocation(x, null, null, null);
    return ok;
}

fn setFlushing(x: *Src, flushing: bool) bool {
    const p = priv(x);
    const k = klass(x);
    if (flushing) {
        poolFlushing(x, true);
        if (k.unlock) |f| _ = f(x);
    }
    liveLock(x);
    p.flushing = flushing;
    if (flushing) {
        if (atomicGet(&p.has_pending_eos)) {
            el.lock(x);
            clearPendingEos(x);
            p.forced_eos = false;
            el.unlock(x);
        }
        if (x.clock_id != null) c.gst_clock_id_unschedule(x.clock_id);
    } else {
        poolFlushing(x, false);
        el.lock(x);
        if (p.pending_events != null) {
            freeEvents(p.pending_events);
            p.pending_events = null;
            atomicSet(&p.have_events, false);
        }
        el.unlock(x);
    }
    c.g_cond_signal(&x.live_cond);
    liveUnlock(x);
    if (!flushing) {
        el.streamLock(x.srcpad);
        if (k.unlock_stop) |f| _ = f(x);
        el.streamUnlock(x.srcpad);
    }
    return true;
}

fn setPlaying(x: *Src, play: bool) void {
    const k = klass(x);
    liveLock(x);
    defer liveUnlock(x);
    if (!play) {
        if (k.unlock) |f| _ = f(x);
    }
    if (x.clock_id != null) c.gst_clock_id_unschedule(x.clock_id);
    x.live_running = @intFromBool(play);
    if (!play) return;
    el.lock(x);
    priv(x).latency = NONE;
    priv(x).pending_unlock_stop = true;
    el.unlock(x);
    if (el.modeLocked(x.srcpad) == c.GST_PAD_MODE_PUSH) startLoop(x);
    c.g_cond_signal(&x.live_cond);
}

fn activateMode(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, m: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const x = of(parent_obj);
    const p = priv(x);
    p.stream_start_pending = false;
    switch (m) {
        c.GST_PAD_MODE_PULL => return @intFromBool(if (active != 0) startSrc(x) else stopSrc(x)),
        c.GST_PAD_MODE_PUSH => {
            p.stream_start_pending = active != 0;
            if (active != 0) {
                if (x.can_activate_push == 0) return 0;
                return @intFromBool(startSrc(x));
            }
            return @intFromBool(stopSrc(x));
        },
        else => return 0,
    }
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const x = of(e);
    var no_preroll = false;
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => no_preroll = gst_base_src_is_live(x) != 0,
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => if (gst_base_src_is_live(x) != 0) setPlaying(x, true),
        else => {},
    }
    var result = parent.?.change_state.?(e, t);
    if (result == c.GST_STATE_CHANGE_FAILURE) return result;
    switch (t) {
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => if (gst_base_src_is_live(x) != 0) {
            setPlaying(x, false);
            no_preroll = true;
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            if (atomicGet(&priv(x).has_pending_eos)) {
                el.lock(x);
                clearPendingEos(x);
                el.unlock(x);
            }
            _ = c.gst_event_replace(&x.pending_seek, null);
        },
        else => {},
    }
    if (no_preroll and result == c.GST_STATE_CHANGE_SUCCESS) result = c.GST_STATE_CHANGE_NO_PREROLL;
    return result;
}

pub export fn gst_base_src_get_buffer_pool(s: [*c]Src) ?*c.GstBufferPool {
    if (!check.that(isSrc(s), "gst_base_src_get_buffer_pool", "GST_IS_BASE_SRC (src)")) return null;
    el.lock(s);
    defer el.unlock(s);
    const pool = priv(s).pool;
    return if (pool != null) @ptrCast(@alignCast(c.gst_object_ref(pool))) else null;
}

pub export fn gst_base_src_get_allocator(s: [*c]Src, allocator: [*c]?*c.GstAllocator, params: [*c]c.GstAllocationParams) void {
    if (!check.that(isSrc(s), "gst_base_src_get_allocator", "GST_IS_BASE_SRC (src)")) return;
    el.lock(s);
    defer el.unlock(s);
    const p = priv(s);
    if (allocator != null) allocator.* = if (p.allocator != null) @ptrCast(@alignCast(c.gst_object_ref(p.allocator))) else null;
    if (params != null) params.* = p.params;
}

pub export fn gst_base_src_submit_buffer_list(s: [*c]Src, list: ?*c.GstBufferList) void {
    if (!check.that(isSrc(s), "gst_base_src_submit_buffer_list", "GST_IS_BASE_SRC (src)")) return;
    if (!check.that(list != null and @as(*c.GstMiniObject, @ptrCast(@alignCast(list))).type == c._gst_buffer_list_type, "gst_base_src_submit_buffer_list", "GST_IS_BUFFER_LIST (buffer_list)")) return;
    if (!check.that(priv(s).pending_bufferlist == null, "gst_base_src_submit_buffer_list", "BASE_SRC_HAS_PENDING_BUFFER_LIST (src) == FALSE")) return;
    priv(s).pending_bufferlist = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(list)))));
}
