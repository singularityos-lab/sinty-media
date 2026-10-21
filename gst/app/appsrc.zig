const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const queue = @import("queue.zig");
const enums = @import("enums.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Src = c.GstAppSrc;
const Class = c.GstAppSrcClass;
const Buffer = c.GstBuffer;
const List = c.GstBufferList;
const Mini = c.GstMiniObject;
const NONE = el.NONE;
const PATH = "../gst-libs/gst/app/gstappsrc.c";
const STREAM_WAITING: c_uint = 1 << 0;
const APP_WAITING: c_uint = 1 << 1;

const Callbacks = extern struct {
    callbacks: c.GstAppSrcCallbacks,
    user_data: c.gpointer,
    destroy_notify: c.GDestroyNotify,
    ref_count: c.gint,
};

const Simple = extern struct {
    ref_count: c.gint,
    attached: c.gint,
    need_data_cb: c.GstAppSrcNeedDataCallback,
    need_data_user_data: c.gpointer,
    need_data_destroy_notify: c.GDestroyNotify,
    enough_data_cb: c.GstAppSrcEnoughDataCallback,
    enough_data_user_data: c.gpointer,
    enough_data_destroy_notify: c.GDestroyNotify,
    seek_data_cb: c.GstAppSrcSeekDataCallback,
    seek_data_user_data: c.gpointer,
    seek_data_destroy_notify: c.GDestroyNotify,
};

const Private = extern struct {
    cond: c.GCond,
    mutex: c.GMutex,
    queue: ?*c.GstVecDeque,
    wait_status: c_uint,
    last_caps: [*c]c.GstCaps,
    current_caps: [*c]c.GstCaps,
    last_segment: c.GstSegment,
    current_segment: c.GstSegment,
    pending_custom_segment: bool,
    delayed_events: ?*c.GstVecDeque,
    pushed_buffer: bool,
    need_discont_upstream: bool,
    need_discont_downstream: bool,
    size: i64,
    duration: u64,
    stream_type: c.GstAppStreamType,
    max_bytes: u64,
    max_buffers: u64,
    max_time: u64,
    format: c.GstFormat,
    block: bool,
    uri: [*c]u8,
    flushing: bool,
    started: bool,
    is_eos: bool,
    status: queue.Status,
    offset: u64,
    current_type: c.GstAppStreamType,
    min_latency: u64,
    max_latency: u64,
    posted_latency_msg: bool,
    emit_signals: bool,
    min_percent: c.guint,
    handle_segment_change: bool,
    leaky_type: c.GstAppLeakyType,
    callbacks: ?*Callbacks,
    simple_callbacks: ?*Simple,
    in: u64,
    out: u64,
    dropped: u64,
    silent: bool,
};

const SIG_NEED_DATA = 0;
const SIG_ENOUGH_DATA = 1;
const SIG_SEEK_DATA = 2;
const SIG_PUSH_BUFFER = 3;
const SIG_END_OF_STREAM = 4;
const SIG_PUSH_SAMPLE = 5;
const SIG_PUSH_BUFFER_LIST = 6;

const PROP_CAPS = 1;
const PROP_SIZE = 2;
const PROP_STREAM_TYPE = 3;
const PROP_MAX_BYTES = 4;
const PROP_MAX_BUFFERS = 5;
const PROP_MAX_TIME = 6;
const PROP_FORMAT = 7;
const PROP_BLOCK = 8;
const PROP_IS_LIVE = 9;
const PROP_MIN_LATENCY = 10;
const PROP_MAX_LATENCY = 11;
const PROP_EMIT_SIGNALS = 12;
const PROP_MIN_PERCENT = 13;
const PROP_CURRENT_LEVEL_BYTES = 14;
const PROP_CURRENT_LEVEL_BUFFERS = 15;
const PROP_CURRENT_LEVEL_TIME = 16;
const PROP_DURATION = 17;
const PROP_HANDLE_SEGMENT_CHANGE = 18;
const PROP_LEAKY_TYPE = 19;
const PROP_IN = 20;
const PROP_OUT = 21;
const PROP_DROPPED = 22;
const PROP_SILENT = 23;

var once: gtype.Once = .{};
var simple_once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GstBaseSrcClass = null;
var signals: [7]c.guint = .{0} ** 7;
var templ = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "ANY", ._gst_reserved = .{null} ** 4 } };
var protocols = [_][*c]const u8{ "appsrc", null };

fn priv(s: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Src, @ptrCast(@alignCast(s)))[0].priv));
}

fn of(s: anytype) [*c]Src {
    return @ptrCast(@alignCast(s));
}

fn isSrc(s: anytype) bool {
    return gtype.instanceOf(s, gst_app_src_get_type());
}

fn isType(o: anytype, t: c.GType) bool {
    const p: ?*const c.GstMiniObject = @ptrCast(@alignCast(o));
    return if (p) |m| m.type == t else false;
}

fn srcPad(s: anytype) ?*c.GstPad {
    return @as(*c.GstBaseSrc, @ptrCast(@alignCast(s))).srcpad;
}

fn notifyDropped(s: anytype) void {
    if (!priv(s).silent) c.g_object_notify(@ptrCast(@alignCast(s)), "dropped");
}

fn cbRef(cb: *Callbacks) *Callbacks {
    _ = @atomicRmw(c.gint, &cb.ref_count, .Add, 1, .seq_cst);
    return cb;
}

fn cbUnref(cb: ?*Callbacks) void {
    const x = cb orelse return;
    if (@atomicRmw(c.gint, &x.ref_count, .Sub, 1, .seq_cst) != 1) return;
    if (x.destroy_notify) |d| d(x.user_data);
    c.g_free(x);
}

const Held = struct {
    cb: ?*Callbacks = null,
    simple: ?*Simple = null,
    emit: bool = false,

    fn take(r: *Private) Held {
        var h = Held{ .emit = r.emit_signals };
        if (r.callbacks) |cb| {
            h.cb = cbRef(cb);
        } else if (r.simple_callbacks) |s| h.simple = @ptrCast(@alignCast(gst_app_src_simple_callbacks_ref(@ptrCast(s))));
        return h;
    }

    fn release(h: *Held) void {
        cbUnref(h.cb);
        if (h.simple) |s| gst_app_src_simple_callbacks_unref(@ptrCast(s));
    }
};

fn simpleCopy(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_app_src_simple_callbacks_ref(@ptrCast(@alignCast(p)));
}

fn simpleFree(p: c.gpointer) callconv(.c) void {
    gst_app_src_simple_callbacks_unref(@ptrCast(@alignCast(p)));
}

pub export fn gst_app_src_simple_callbacks_get_type() c.GType {
    return simple_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstAppSrcSimpleCallbacks", simpleCopy, simpleFree);
        }
    }.f);
}

fn flushQueued(s: anytype, retain_last_caps: bool) void {
    const r = priv(s);
    var requeue: [*c]c.GstCaps = null;
    while (c.gst_vec_deque_is_empty(r.queue) == 0) {
        const o = c.gst_vec_deque_pop_head(r.queue);
        if (o == null) continue;
        if (isType(o, c._gst_caps_type) and retain_last_caps) _ = c.gst_caps_replace(&requeue, @ptrCast(@alignCast(o)));
        c.gst_mini_object_unref(@ptrCast(@alignCast(o)));
    }
    if (requeue != null) c.gst_vec_deque_push_tail(r.queue, requeue);
    c.gst_vec_deque_clear(r.delayed_events);
    r.pushed_buffer = false;
    queue.reset(&r.status);
    r.need_discont_upstream = false;
    r.need_discont_downstream = false;
    r.in = 0;
    r.out = 0;
    r.dropped = 0;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const r = priv(o);
    el.lock(o);
    if (r.current_caps != null) {
        c.gst_caps_unref(r.current_caps);
        r.current_caps = null;
    }
    if (r.last_caps != null) {
        c.gst_caps_unref(r.last_caps);
        r.last_caps = null;
    }
    el.unlock(o);
    c.g_mutex_lock(&r.mutex);
    const cb = r.callbacks;
    r.callbacks = null;
    const simple = r.simple_callbacks;
    r.simple_callbacks = null;
    flushQueued(o, false);
    c.g_mutex_unlock(&r.mutex);
    cbUnref(cb);
    if (simple) |x| gst_app_src_simple_callbacks_unref(@ptrCast(x));
    @as(*c.GObjectClass, @ptrCast(parent.?)).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const r = priv(o);
    c.g_mutex_clear(&r.mutex);
    c.g_cond_clear(&r.cond);
    c.gst_vec_deque_free(r.queue);
    c.gst_vec_deque_free(r.delayed_events);
    c.g_free(r.uri);
    @as(*c.GObjectClass, @ptrCast(parent.?)).finalize.?(o);
}

fn internalGetCaps(b: [*c]c.GstBaseSrc, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    el.lock(b);
    var caps = priv(b).current_caps;
    if (caps != null) _ = c.gst_caps_ref(caps);
    el.unlock(b);
    if (filter != null) {
        if (caps != null) {
            const i = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
            c.gst_caps_unref(caps);
            caps = i;
        } else caps = c.gst_caps_ref(filter);
    }
    return caps;
}

fn setProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    const r = priv(o);
    switch (id) {
        PROP_CAPS => gst_app_src_set_caps(s, c.gst_value_get_caps(v)),
        PROP_SIZE => gst_app_src_set_size(s, c.g_value_get_int64(v)),
        PROP_STREAM_TYPE => gst_app_src_set_stream_type(s, @intCast(c.g_value_get_enum(v))),
        PROP_MAX_BYTES => gst_app_src_set_max_bytes(s, c.g_value_get_uint64(v)),
        PROP_MAX_BUFFERS => gst_app_src_set_max_buffers(s, c.g_value_get_uint64(v)),
        PROP_MAX_TIME => gst_app_src_set_max_time(s, c.g_value_get_uint64(v)),
        PROP_FORMAT => r.format = @intCast(c.g_value_get_enum(v)),
        PROP_BLOCK => r.block = c.g_value_get_boolean(v) != 0,
        PROP_IS_LIVE => c.gst_base_src_set_live(@ptrCast(s), c.g_value_get_boolean(v)),
        PROP_MIN_LATENCY => setLatencies(s, true, @bitCast(c.g_value_get_int64(v)), false, NONE),
        PROP_MAX_LATENCY => setLatencies(s, false, NONE, true, @bitCast(c.g_value_get_int64(v))),
        PROP_EMIT_SIGNALS => gst_app_src_set_emit_signals(s, c.g_value_get_boolean(v)),
        PROP_MIN_PERCENT => r.min_percent = c.g_value_get_uint(v),
        PROP_DURATION => gst_app_src_set_duration(s, c.g_value_get_uint64(v)),
        PROP_HANDLE_SEGMENT_CHANGE => r.handle_segment_change = c.g_value_get_boolean(v) != 0,
        PROP_LEAKY_TYPE => gst_app_src_set_leaky_type(s, @intCast(c.g_value_get_enum(v))),
        PROP_SILENT => r.silent = c.g_value_get_boolean(v) != 0,
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 1013),
    }
}

fn counter(r: *Private, field: *const u64) u64 {
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return field.*;
}

fn getProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    const r = priv(o);
    switch (id) {
        PROP_CAPS => c.g_value_take_boxed(v, gst_app_src_get_caps(s)),
        PROP_SIZE => c.g_value_set_int64(v, gst_app_src_get_size(s)),
        PROP_STREAM_TYPE => c.g_value_set_enum(v, @intCast(gst_app_src_get_stream_type(s))),
        PROP_MAX_BYTES => c.g_value_set_uint64(v, gst_app_src_get_max_bytes(s)),
        PROP_MAX_BUFFERS => c.g_value_set_uint64(v, gst_app_src_get_max_buffers(s)),
        PROP_MAX_TIME => c.g_value_set_uint64(v, gst_app_src_get_max_time(s)),
        PROP_FORMAT => c.g_value_set_enum(v, @intCast(r.format)),
        PROP_BLOCK => c.g_value_set_boolean(v, @intFromBool(r.block)),
        PROP_IS_LIVE => c.g_value_set_boolean(v, c.gst_base_src_is_live(@ptrCast(s))),
        PROP_MIN_LATENCY => {
            var min: u64 = 0;
            gst_app_src_get_latency(s, &min, null);
            c.g_value_set_int64(v, @bitCast(min));
        },
        PROP_MAX_LATENCY => {
            var max: u64 = 0;
            gst_app_src_get_latency(s, null, &max);
            c.g_value_set_int64(v, @bitCast(max));
        },
        PROP_EMIT_SIGNALS => c.g_value_set_boolean(v, gst_app_src_get_emit_signals(s)),
        PROP_MIN_PERCENT => c.g_value_set_uint(v, r.min_percent),
        PROP_CURRENT_LEVEL_BYTES => c.g_value_set_uint64(v, gst_app_src_get_current_level_bytes(s)),
        PROP_CURRENT_LEVEL_BUFFERS => c.g_value_set_uint64(v, gst_app_src_get_current_level_buffers(s)),
        PROP_CURRENT_LEVEL_TIME => c.g_value_set_uint64(v, gst_app_src_get_current_level_time(s)),
        PROP_DURATION => c.g_value_set_uint64(v, gst_app_src_get_duration(s)),
        PROP_HANDLE_SEGMENT_CHANGE => c.g_value_set_boolean(v, @intFromBool(r.handle_segment_change)),
        PROP_LEAKY_TYPE => c.g_value_set_enum(v, @intCast(gst_app_src_get_leaky_type(s))),
        PROP_IN => c.g_value_set_uint64(v, counter(r, &r.in)),
        PROP_OUT => c.g_value_set_uint64(v, counter(r, &r.out)),
        PROP_DROPPED => c.g_value_set_uint64(v, counter(r, &r.dropped)),
        PROP_SILENT => c.g_value_set_boolean(v, @intFromBool(r.silent)),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 1113),
    }
}

fn sendEvent(e: [*c]c.GstElement, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const r = priv(e);
    if (ev[0].type == c.GST_EVENT_FLUSH_STOP) {
        c.g_mutex_lock(&r.mutex);
        flushQueued(e, true);
        r.is_eos = false;
        c.g_mutex_unlock(&r.mutex);
        notifyDropped(e);
    } else if (ev[0].type & c.GST_EVENT_TYPE_SERIALIZED != 0) {
        c.g_mutex_lock(&r.mutex);
        c.gst_vec_deque_push_tail(r.queue, ev);
        if (r.wait_status & STREAM_WAITING != 0) c.g_cond_broadcast(&r.cond);
        c.g_mutex_unlock(&r.mutex);
        return 1;
    }
    const ec: *c.GstElementClass = @ptrCast(parent.?);
    if (ec.send_event) |f| return f(e, ev);
    return 0;
}

fn unlock(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    r.flushing = true;
    c.g_cond_broadcast(&r.cond);
    c.g_mutex_unlock(&r.mutex);
    return 1;
}

fn unlockStop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    r.flushing = false;
    c.g_cond_broadcast(&r.cond);
    c.g_mutex_unlock(&r.mutex);
    return 1;
}

fn start(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    r.started = true;
    r.offset = NONE;
    r.flushing = false;
    r.in = 0;
    r.out = 0;
    r.dropped = 0;
    c.g_mutex_unlock(&r.mutex);
    c.gst_base_src_set_format(b, r.format);
    c.gst_segment_init(&r.last_segment, r.format);
    c.gst_segment_init(&r.current_segment, r.format);
    r.pending_custom_segment = false;
    return 1;
}

fn stop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    r.is_eos = false;
    r.flushing = true;
    r.started = false;
    r.posted_latency_msg = false;
    flushQueued(b, true);
    c.g_cond_broadcast(&r.cond);
    r.in = 0;
    r.out = 0;
    r.dropped = 0;
    c.g_mutex_unlock(&r.mutex);
    notifyDropped(b);
    return 1;
}

fn isSeekable(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const t = priv(b).stream_type;
    return @intFromBool(t == c.GST_APP_STREAM_TYPE_SEEKABLE or t == c.GST_APP_STREAM_TYPE_RANDOM_ACCESS);
}

fn getSize(b: [*c]c.GstBaseSrc, size: [*c]u64) callconv(.c) c.gboolean {
    size.* = @bitCast(gst_app_src_get_size(of(b)));
    return 1;
}

fn query(b: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const r = priv(b);
    switch (q[0].type) {
        c.GST_QUERY_LATENCY => {
            var min: u64 = 0;
            var max: u64 = 0;
            var live: c.gboolean = 0;
            const res = c.gst_base_src_query_latency(b, &live, &min, &max);
            c.g_mutex_lock(&r.mutex);
            if (r.min_latency != NONE) {
                min = r.min_latency;
                max = r.max_latency;
            }
            c.g_mutex_unlock(&r.mutex);
            c.gst_query_set_latency(q, live, min, max);
            return res;
        },
        c.GST_QUERY_SCHEDULING => {
            c.gst_query_set_scheduling(q, c.GST_SCHEDULING_FLAG_SEEKABLE, 1, -1, 0);
            c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
            if (r.stream_type == c.GST_APP_STREAM_TYPE_RANDOM_ACCESS) c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PULL);
            return 1;
        },
        c.GST_QUERY_DURATION => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_duration(q, &format, null);
            if (format == c.GST_FORMAT_BYTES) {
                c.gst_query_set_duration(q, format, r.size);
                return 1;
            }
            if (format == c.GST_FORMAT_TIME and r.duration != NONE) {
                c.gst_query_set_duration(q, format, @bitCast(r.duration));
                return 1;
            }
            return 0;
        },
        else => return parent.?.query.?(b, q),
    }
}

fn emitSeekLocked(s: anytype, off: u64) bool {
    const r = priv(s);
    var h = Held.take(r);
    c.g_mutex_unlock(&r.mutex);
    var res: c.gboolean = 0;
    if (h.cb != null and h.cb.?.callbacks.seek_data != null) {
        res = h.cb.?.callbacks.seek_data.?(of(s), off, h.cb.?.user_data);
    } else if (h.simple != null and h.simple.?.seek_data_cb != null) {
        res = h.simple.?.seek_data_cb.?(of(s), off, h.simple.?.seek_data_user_data);
    } else if (h.emit) c.g_signal_emit(s, signals[SIG_SEEK_DATA], 0, off, &res);
    h.release();
    c.g_mutex_lock(&r.mutex);
    return res != 0;
}

fn doSeek(b: [*c]c.GstBaseSrc, seg: [*c]c.GstSegment) callconv(.c) c.gboolean {
    const r = priv(b);
    const pos = seg[0].position;
    if (r.stream_type == c.GST_APP_STREAM_TYPE_STREAM) return 1;
    c.g_mutex_lock(&r.mutex);
    var h = Held.take(r);
    c.g_mutex_unlock(&r.mutex);
    var res: c.gboolean = 0;
    if (h.cb != null and h.cb.?.callbacks.seek_data != null) {
        res = h.cb.?.callbacks.seek_data.?(of(b), pos, h.cb.?.user_data);
    } else if (h.simple != null and h.simple.?.seek_data_cb != null) {
        res = h.simple.?.seek_data_cb.?(of(b), pos, h.simple.?.seek_data_user_data);
    } else if (h.emit) c.g_signal_emit(b, signals[SIG_SEEK_DATA], 0, pos, &res);
    h.release();
    if (res != 0) {
        c.g_mutex_lock(&r.mutex);
        flushQueued(b, true);
        c.gst_segment_copy_into(seg, &r.last_segment);
        c.gst_segment_copy_into(seg, &r.current_segment);
        r.pending_custom_segment = false;
        r.is_eos = false;
        c.g_mutex_unlock(&r.mutex);
        notifyDropped(b);
    }
    return res;
}

fn emitNeedDataLocked(s: anytype, size: c.guint) void {
    const r = priv(s);
    var h = Held.take(r);
    c.g_mutex_unlock(&r.mutex);
    if (h.cb != null and h.cb.?.callbacks.need_data != null) {
        h.cb.?.callbacks.need_data.?(of(s), size, h.cb.?.user_data);
    } else if (h.simple != null and h.simple.?.need_data_cb != null) {
        h.simple.?.need_data_cb.?(of(s), size, h.simple.?.need_data_user_data);
    } else if (h.emit) c.g_signal_emit(s, signals[SIG_NEED_DATA], 0, size, @as(?*anyopaque, null));
    h.release();
    c.g_mutex_lock(&r.mutex);
}

fn doNegotiate(b: [*c]c.GstBaseSrc) bool {
    const r = priv(b);
    el.lock(b);
    const caps = if (r.current_caps != null) c.gst_caps_ref(r.current_caps) else null;
    el.unlock(b);
    c.g_mutex_unlock(&r.mutex);
    var ok = true;
    if (caps != null) {
        ok = c.gst_base_src_set_caps(b, caps) != 0;
        c.gst_caps_unref(caps);
    }
    c.g_mutex_lock(&r.mutex);
    return ok;
}

fn negotiate(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    const ok = doNegotiate(b);
    c.g_mutex_unlock(&r.mutex);
    return @intFromBool(ok);
}

fn queuedPop(s: anytype, item: ?*Mini, update_offset: bool) void {
    const r = priv(s);
    const old = r.status.queued_bytes;
    queue.pop(&r.status, item, &r.current_segment, &r.last_segment);
    if (update_offset and r.stream_type == c.GST_APP_STREAM_TYPE_RANDOM_ACCESS) r.offset +%= old -% r.status.queued_bytes;
}

fn needsSegment(o: c.gpointer) bool {
    if (isType(o, c._gst_caps_type)) return false;
    if (isType(o, c._gst_event_type)) return @as(*c.GstEvent, @ptrCast(@alignCast(o))).type != c.GST_EVENT_SEGMENT;
    return true;
}

fn ensureSegment(s: anytype) void {
    const r = priv(s);
    const se = c.gst_pad_get_sticky_event(srcPad(s), c.GST_EVENT_SEGMENT, 0);
    if (se == null) {
        c.g_mutex_unlock(&r.mutex);
        _ = c.gst_base_src_push_segment(@ptrCast(@alignCast(s)), &r.last_segment);
        c.g_mutex_lock(&r.mutex);
    } else c.gst_event_unref(se);
}

fn pushDelayed(s: anytype) void {
    const r = priv(s);
    while (c.gst_vec_deque_is_empty(r.delayed_events) == 0) {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(c.gst_vec_deque_pop_head(r.delayed_events)));
        c.g_mutex_unlock(&r.mutex);
        _ = c.gst_pad_push_event(srcPad(s), e);
        c.g_mutex_lock(&r.mutex);
    }
}

fn create(b: [*c]c.GstBaseSrc, off: u64, size: c.guint, out: [*c][*c]Buffer) callconv(.c) c.GstFlowReturn {
    const r = priv(b);
    el.lock(b);
    if (r.size != @as(i64, @bitCast(b[0].segment.duration)) and b[0].segment.format == c.GST_FORMAT_BYTES) {
        b[0].segment.duration = @bitCast(r.size);
        el.unlock(b);
        _ = c.gst_element_post_message(@ptrCast(b), c.gst_message_new_duration_changed(@ptrCast(b)));
    } else if (r.duration != b[0].segment.duration and b[0].segment.format == c.GST_FORMAT_TIME) {
        b[0].segment.duration = r.duration;
        el.unlock(b);
        _ = c.gst_element_post_message(@ptrCast(b), c.gst_message_new_duration_changed(@ptrCast(b)));
    } else el.unlock(b);
    c.g_mutex_lock(&r.mutex);
    if (r.flushing) {
        c.g_mutex_unlock(&r.mutex);
        return c.GST_FLOW_FLUSHING;
    }
    if (r.stream_type == c.GST_APP_STREAM_TYPE_RANDOM_ACCESS and r.offset != off) {
        if (!emitSeekLocked(b, off)) {
            c.g_mutex_unlock(&r.mutex);
            el.errAt(b, .resource, c.GST_RESOURCE_ERROR_READ, "failed to seek", c.g_strdup_printf("system error: %s", c.g_strerror(std.c._errno().*)), "gst-plugins-base-1.0", PATH, "gst_app_src_create", 1875);
            return c.GST_FLOW_ERROR;
        }
        r.offset = off;
        r.is_eos = false;
    }
    while (true) {
        if (r.flushing) {
            c.g_mutex_unlock(&r.mutex);
            return c.GST_FLOW_FLUSHING;
        }
        if (c.gst_vec_deque_is_empty(r.queue) == 0) {
            var o = c.gst_vec_deque_pop_head(r.queue);
            if (r.current_caps != null and needsSegment(o)) ensureSegment(b);
            if (isType(o, c._gst_caps_type)) {
                const next: [*c]c.GstCaps = @ptrCast(@alignCast(o));
                const changed = if (next != null and r.current_caps != null) c.gst_caps_is_equal(next, r.current_caps) == 0 else next != r.current_caps;
                _ = c.gst_caps_replace(&r.current_caps, next);
                if (next != null) c.gst_caps_unref(next);
                if (changed) _ = doNegotiate(b);
                if (c.gst_vec_deque_is_empty(r.delayed_events) == 0) {
                    ensureSegment(b);
                    pushDelayed(b);
                }
                continue;
            }
            if (isType(o, c._gst_buffer_type)) {
                var buffer: [*c]Buffer = @ptrCast(@alignCast(o));
                if (r.need_discont_downstream) {
                    buffer = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(buffer))));
                    o = buffer;
                    buffer[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
                    r.need_discont_downstream = false;
                }
                if (c.gst_vec_deque_is_empty(r.delayed_events) == 0) pushDelayed(b);
                r.pushed_buffer = true;
                r.out += 1;
                out.* = buffer;
            } else if (isType(o, c._gst_buffer_list_type)) {
                var list: ?*List = @ptrCast(@alignCast(o));
                if (r.need_discont_downstream) {
                    list = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(list)))));
                    o = list;
                    const first = c.gst_buffer_list_get_writable(list, 0);
                    first[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
                    r.need_discont_downstream = false;
                }
                if (c.gst_vec_deque_is_empty(r.delayed_events) == 0) pushDelayed(b);
                r.out += c.gst_buffer_list_length(list);
                c.gst_base_src_submit_buffer_list(b, list);
                r.pushed_buffer = true;
                out.* = null;
            } else if (isType(o, c._gst_event_type)) {
                const e: [*c]c.GstEvent = @ptrCast(@alignCast(o));
                if (e[0].type == c.GST_EVENT_SEGMENT) {
                    var seg: [*c]const c.GstSegment = null;
                    c.gst_event_parse_segment(e, &seg);
                    if (c.gst_segment_is_equal(&r.current_segment, seg) == 0) {
                        c.g_mutex_unlock(&r.mutex);
                        if (c.gst_base_src_push_segment(b, seg) == 0) {
                            c.gst_event_unref(e);
                            el.errAt(b, .library, c.GST_LIBRARY_ERROR_SETTINGS, null, c.g_strdup("Failed to configure the provided input segment."), "gst-plugins-base-1.0", PATH, "gst_app_src_create", 1883);
                            return c.GST_FLOW_ERROR;
                        }
                        c.g_mutex_lock(&r.mutex);
                        c.gst_segment_copy_into(seg, &r.current_segment);
                    }
                    c.gst_event_unref(e);
                } else if (r.current_caps == null and !r.pushed_buffer) {
                    c.gst_vec_deque_push_tail(r.delayed_events, e);
                } else {
                    c.g_mutex_unlock(&r.mutex);
                    _ = c.gst_pad_push_event(srcPad(b), e);
                    c.g_mutex_lock(&r.mutex);
                }
                continue;
            } else {
                c.g_assertion_message_expr(check.DOMAIN, PATH, 1803, "gst_app_src_create", null);
            }
            queuedPop(b, @ptrCast(@alignCast(o)), true);
            if (r.wait_status & APP_WAITING != 0) c.g_cond_broadcast(&r.cond);
            if (r.min_percent != 0) {
                const st = r.status;
                const low = (r.max_bytes != 0 and st.queued_bytes *% 100 / r.max_bytes <= r.min_percent) or (r.max_buffers != 0 and st.queued_buffers *% 100 / r.max_buffers <= r.min_percent) or (r.max_time != 0 and st.queued_time *% 100 / r.max_time <= r.min_percent);
                if (low) emitNeedDataLocked(b, size);
            }
            c.g_mutex_unlock(&r.mutex);
            return c.GST_FLOW_OK;
        }
        emitNeedDataLocked(b, size);
        if (r.flushing) {
            c.g_mutex_unlock(&r.mutex);
            return c.GST_FLOW_FLUSHING;
        }
        if (c.gst_vec_deque_is_empty(r.queue) == 0) continue;
        if (r.is_eos) {
            c.g_mutex_unlock(&r.mutex);
            return c.GST_FLOW_EOS;
        }
        r.wait_status |= STREAM_WAITING;
        c.g_cond_wait(&r.cond, &r.mutex);
        r.wait_status &= ~STREAM_WAITING;
    }
}

pub export fn gst_app_src_set_caps(s: [*c]Src, caps: [*c]const c.GstCaps) void {
    if (!check.that(isSrc(s), "gst_app_src_set_caps", "GST_IS_APP_SRC (appsrc)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    el.lock(s);
    const changed = if (caps != null and r.last_caps != null) c.gst_caps_is_equal(caps, r.last_caps) == 0 else @as(?*const anyopaque, @ptrCast(caps)) != @as(?*const anyopaque, @ptrCast(r.last_caps));
    if (changed) {
        const new_caps = if (caps != null) c.gst_caps_copy(caps) else null;
        while (true) {
            const t = c.gst_vec_deque_peek_tail(r.queue);
            if (t == null or !isType(t, c._gst_caps_type)) break;
            c.gst_caps_unref(@ptrCast(@alignCast(c.gst_vec_deque_pop_tail(r.queue))));
        }
        c.gst_vec_deque_push_tail(r.queue, new_caps);
        _ = c.gst_caps_replace(&r.last_caps, new_caps);
        if (r.wait_status & STREAM_WAITING != 0) c.g_cond_broadcast(&r.cond);
    }
    el.unlock(s);
    c.g_mutex_unlock(&r.mutex);
}

pub export fn gst_app_src_get_caps(s: [*c]Src) [*c]c.GstCaps {
    if (!check.that(isSrc(s), "gst_app_src_get_caps", "GST_IS_APP_SRC (appsrc)")) return null;
    el.lock(s);
    defer el.unlock(s);
    const caps = priv(s).last_caps;
    if (caps != null) _ = c.gst_caps_ref(caps);
    return caps;
}

pub export fn gst_app_src_set_size(s: [*c]Src, size: c.gint64) void {
    if (!check.that(isSrc(s), "gst_app_src_set_size", "GST_IS_APP_SRC (appsrc)")) return;
    el.lock(s);
    priv(s).size = size;
    el.unlock(s);
}

pub export fn gst_app_src_get_size(s: [*c]Src) c.gint64 {
    if (!check.that(isSrc(s), "gst_app_src_get_size", "GST_IS_APP_SRC (appsrc)")) return -1;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).size;
}

pub export fn gst_app_src_set_duration(s: [*c]Src, duration: c.GstClockTime) void {
    if (!check.that(isSrc(s), "gst_app_src_set_duration", "GST_IS_APP_SRC (appsrc)")) return;
    el.lock(s);
    priv(s).duration = duration;
    el.unlock(s);
}

pub export fn gst_app_src_get_duration(s: [*c]Src) c.GstClockTime {
    if (!check.that(isSrc(s), "gst_app_src_get_duration", "GST_IS_APP_SRC (appsrc)")) return NONE;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).duration;
}

pub export fn gst_app_src_set_stream_type(s: [*c]Src, t: c.GstAppStreamType) void {
    if (!check.that(isSrc(s), "gst_app_src_set_stream_type", "GST_IS_APP_SRC (appsrc)")) return;
    el.lock(s);
    priv(s).stream_type = t;
    el.unlock(s);
}

pub export fn gst_app_src_get_stream_type(s: [*c]Src) c.GstAppStreamType {
    if (!check.that(isSrc(s), "gst_app_src_get_stream_type", "GST_IS_APP_SRC (appsrc)")) return 0;
    el.lock(s);
    defer el.unlock(s);
    return priv(s).stream_type;
}

fn setLimit(s: [*c]Src, comptime field: []const u8, v: u64, comptime func: []const u8) void {
    if (!check.that(isSrc(s), func, "GST_IS_APP_SRC (appsrc)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    if (v != @field(r, field)) {
        @field(r, field) = v;
        c.g_cond_broadcast(&r.cond);
    }
    c.g_mutex_unlock(&r.mutex);
}

fn getLocked(s: [*c]Src, comptime func: []const u8, fallback: u64, comptime get: fn (*Private) u64) u64 {
    if (!check.that(isSrc(s), func, "GST_IS_APP_SRC (appsrc)")) return fallback;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return get(r);
}

pub export fn gst_app_src_set_max_bytes(s: [*c]Src, max: c.guint64) void {
    setLimit(s, "max_bytes", max, "gst_app_src_set_max_bytes");
}

pub export fn gst_app_src_get_max_bytes(s: [*c]Src) c.guint64 {
    return getLocked(s, "gst_app_src_get_max_bytes", 0, struct {
        fn f(r: *Private) u64 {
            return r.max_bytes;
        }
    }.f);
}

pub export fn gst_app_src_get_current_level_bytes(s: [*c]Src) c.guint64 {
    return getLocked(s, "gst_app_src_get_current_level_bytes", NONE, struct {
        fn f(r: *Private) u64 {
            return r.status.queued_bytes;
        }
    }.f);
}

pub export fn gst_app_src_set_max_buffers(s: [*c]Src, max: c.guint64) void {
    setLimit(s, "max_buffers", max, "gst_app_src_set_max_buffers");
}

pub export fn gst_app_src_get_max_buffers(s: [*c]Src) c.guint64 {
    return getLocked(s, "gst_app_src_get_max_buffers", 0, struct {
        fn f(r: *Private) u64 {
            return r.max_buffers;
        }
    }.f);
}

pub export fn gst_app_src_get_current_level_buffers(s: [*c]Src) c.guint64 {
    return getLocked(s, "gst_app_src_get_current_level_buffers", NONE, struct {
        fn f(r: *Private) u64 {
            return r.status.queued_buffers;
        }
    }.f);
}

pub export fn gst_app_src_set_max_time(s: [*c]Src, max: c.GstClockTime) void {
    setLimit(s, "max_time", max, "gst_app_src_set_max_time");
}

pub export fn gst_app_src_get_max_time(s: [*c]Src) c.GstClockTime {
    return getLocked(s, "gst_app_src_get_max_time", 0, struct {
        fn f(r: *Private) u64 {
            return r.max_time;
        }
    }.f);
}

pub export fn gst_app_src_get_current_level_time(s: [*c]Src) c.GstClockTime {
    return getLocked(s, "gst_app_src_get_current_level_time", NONE, struct {
        fn f(r: *Private) u64 {
            return r.status.queued_time;
        }
    }.f);
}

fn setLatencies(s: [*c]Src, do_min: bool, min: u64, do_max: bool, max: u64) void {
    const r = priv(s);
    var changed = false;
    c.g_mutex_lock(&r.mutex);
    if (do_min and r.min_latency != min) {
        r.min_latency = min;
        changed = true;
    }
    if (do_max and r.max_latency != max) {
        r.max_latency = max;
        changed = true;
    }
    if (!r.posted_latency_msg) {
        r.posted_latency_msg = true;
        changed = true;
    }
    c.g_mutex_unlock(&r.mutex);
    if (changed) _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_latency(@ptrCast(s)));
}

pub export fn gst_app_src_set_leaky_type(s: [*c]Src, leaky: c.GstAppLeakyType) void {
    if (!check.that(isSrc(s), "gst_app_src_set_leaky_type", "GST_IS_APP_SRC (appsrc)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    if (r.leaky_type != leaky) {
        r.leaky_type = leaky;
        c.g_cond_signal(&r.cond);
    }
    c.g_mutex_unlock(&r.mutex);
}

pub export fn gst_app_src_get_leaky_type(s: [*c]Src) c.GstAppLeakyType {
    if (!check.that(isSrc(s), "gst_app_src_get_leaky_type", "GST_IS_APP_SRC (appsrc)")) return c.GST_APP_LEAKY_TYPE_NONE;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return r.leaky_type;
}

pub export fn gst_app_src_set_latency(s: [*c]Src, min: c.guint64, max: c.guint64) void {
    setLatencies(s, true, min, true, max);
}

pub export fn gst_app_src_get_latency(s: [*c]Src, min: [*c]c.guint64, max: [*c]c.guint64) void {
    if (!check.that(isSrc(s), "gst_app_src_get_latency", "GST_IS_APP_SRC (appsrc)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    if (min != null) min.* = r.min_latency;
    if (max != null) max.* = r.max_latency;
    c.g_mutex_unlock(&r.mutex);
}

pub export fn gst_app_src_set_emit_signals(s: [*c]Src, emit: c.gboolean) void {
    if (!check.that(isSrc(s), "gst_app_src_set_emit_signals", "GST_IS_APP_SRC (appsrc)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    r.emit_signals = emit != 0;
    c.g_mutex_unlock(&r.mutex);
}

pub export fn gst_app_src_get_emit_signals(s: [*c]Src) c.gboolean {
    if (!check.that(isSrc(s), "gst_app_src_get_emit_signals", "GST_IS_APP_SRC (appsrc)")) return 0;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return @intFromBool(r.emit_signals);
}

fn dropRef(buffer: [*c]Buffer, list: ?*List, steal: bool) void {
    if (!steal) return;
    if (list != null) c.gst_mini_object_unref(@ptrCast(@alignCast(list))) else c.gst_buffer_unref(buffer);
}

fn writableList(list: ?*List, steal: *bool) ?*List {
    if (!steal.*) {
        steal.* = true;
        return c.gst_buffer_list_copy(list);
    }
    return @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(list)))));
}

fn writableBuffer(b: [*c]Buffer, steal: *bool) [*c]Buffer {
    if (!steal.*) {
        steal.* = true;
        return c.gst_buffer_copy(b);
    }
    return @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(b))));
}

fn pushInternal(s: [*c]Src, buffer_in: [*c]Buffer, list_in: ?*List, steal_in: bool) c.GstFlowReturn {
    const fname = "gst_app_src_push_internal";
    if (!check.that(isSrc(s), fname, "GST_IS_APP_SRC (appsrc)")) return c.GST_FLOW_ERROR;
    var buffer = buffer_in;
    var list = list_in;
    var steal = steal_in;
    if (buffer != null) {
        if (!check.that(isType(buffer, c._gst_buffer_type), fname, "GST_IS_BUFFER (buffer)")) return c.GST_FLOW_ERROR;
    } else if (!check.that(isType(list, c._gst_buffer_list_type), fname, "GST_IS_BUFFER_LIST (buflist)")) return c.GST_FLOW_ERROR;
    const r = priv(s);
    if (list != null) {
        if (c.gst_buffer_list_length(list) == 0) return c.GST_FLOW_OK;
        buffer = c.gst_buffer_list_get(list, 0);
    }
    if (buffer[0].dts == NONE and buffer[0].pts == NONE and c.gst_base_src_get_do_timestamp(@ptrCast(s)) != 0) {
        const clock = c.gst_element_get_clock(@ptrCast(s));
        if (clock != null) {
            const base = c.gst_element_get_base_time(@ptrCast(s));
            var now = c.gst_clock_get_time(clock);
            now = if (now > base) now - base else 0;
            c.gst_object_unref(clock);
            if (list == null) {
                buffer = writableBuffer(buffer, &steal);
            } else {
                list = writableList(list, &steal);
                buffer = c.gst_buffer_list_get_writable(list, 0);
            }
            buffer[0].pts = now;
            buffer[0].dts = now;
        }
    }
    var first = true;
    c.g_mutex_lock(&r.mutex);
    while (true) {
        if (r.flushing) {
            dropRef(buffer, list, steal);
            c.g_mutex_unlock(&r.mutex);
            return c.GST_FLOW_FLUSHING;
        }
        if (r.is_eos) {
            dropRef(buffer, list, steal);
            c.g_mutex_unlock(&r.mutex);
            return c.GST_FLOW_EOS;
        }
        if (!queue.isFull(&r.status, r.max_buffers, r.max_bytes, r.max_time)) break;
        if (first) {
            var h = Held.take(r);
            c.g_mutex_unlock(&r.mutex);
            if (h.cb != null and h.cb.?.callbacks.enough_data != null) {
                h.cb.?.callbacks.enough_data.?(s, h.cb.?.user_data);
            } else if (h.simple != null and h.simple.?.enough_data_cb != null) {
                h.simple.?.enough_data_cb.?(s, h.simple.?.enough_data_user_data);
            } else if (h.emit) c.g_signal_emit(s, signals[SIG_ENOUGH_DATA], 0, @as(?*anyopaque, null));
            h.release();
            c.g_mutex_lock(&r.mutex);
        }
        if (r.leaky_type == c.GST_APP_LEAKY_TYPE_UPSTREAM) {
            r.need_discont_upstream = true;
            r.dropped += if (list != null) c.gst_buffer_list_length(list) else 1;
            dropRef(buffer, list, steal);
            c.g_mutex_unlock(&r.mutex);
            notifyDropped(s);
            return c.GST_FLOW_OK;
        } else if (r.leaky_type == c.GST_APP_LEAKY_TYPE_DOWNSTREAM) {
            const length = c.gst_vec_deque_get_length(r.queue);
            var item: ?*Mini = null;
            var i: c.guint = 0;
            while (i < length) : (i += 1) {
                const cand = c.gst_vec_deque_peek_nth(r.queue, i);
                if (isType(cand, c._gst_buffer_type) or isType(cand, c._gst_buffer_list_type)) {
                    item = @ptrCast(@alignCast(cand));
                    _ = c.gst_vec_deque_drop_element(r.queue, i);
                    break;
                }
            }
            const it = item orelse break;
            queuedPop(s, it, false);
            r.dropped += if (isType(it, c._gst_buffer_list_type)) c.gst_buffer_list_length(list) else 1;
            c.gst_mini_object_unref(it);
            if (!r.silent) {
                c.g_mutex_unlock(&r.mutex);
                c.g_object_notify(@ptrCast(s), "dropped");
                c.g_mutex_lock(&r.mutex);
            }
            r.need_discont_downstream = true;
            continue;
        }
        if (first) {
            first = false;
            continue;
        }
        if (!r.block) break;
        r.wait_status |= APP_WAITING;
        c.g_cond_wait(&r.cond, &r.mutex);
        r.wait_status &= ~APP_WAITING;
    }
    if (r.pending_custom_segment) {
        c.gst_vec_deque_push_tail(r.queue, c.gst_event_new_segment(&r.last_segment));
        r.pending_custom_segment = false;
    }
    if (list != null) {
        if (r.need_discont_upstream) {
            list = writableList(list, &steal);
            buffer = c.gst_buffer_list_get_writable(list, 0);
            buffer[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
            r.need_discont_upstream = false;
        }
        if (!steal) _ = c.gst_mini_object_ref(@ptrCast(@alignCast(list)));
        c.gst_vec_deque_push_tail(r.queue, list);
        r.in += c.gst_buffer_list_length(list);
    } else {
        if (r.need_discont_upstream) {
            buffer = writableBuffer(buffer, &steal);
            buffer[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
            r.need_discont_upstream = false;
        }
        if (!steal) _ = c.gst_buffer_ref(buffer);
        c.gst_vec_deque_push_tail(r.queue, buffer);
        r.in += 1;
    }
    queue.push(&r.status, if (list != null) @ptrCast(@alignCast(list)) else @ptrCast(buffer), &r.last_segment);
    if (r.wait_status & STREAM_WAITING != 0) c.g_cond_broadcast(&r.cond);
    c.g_mutex_unlock(&r.mutex);
    return c.GST_FLOW_OK;
}

fn pushSampleInternal(s: [*c]Src, sample: ?*c.GstSample) c.GstFlowReturn {
    if (!check.that(isType(sample, c._gst_sample_type), "gst_app_src_push_sample_internal", "GST_IS_SAMPLE (sample)")) return c.GST_FLOW_ERROR;
    const r = priv(s);
    const caps = c.gst_sample_get_caps(sample);
    if (caps != null) gst_app_src_set_caps(s, caps);
    if (r.handle_segment_change and r.format == c.GST_FORMAT_TIME) seg: {
        const segment = c.gst_sample_get_segment(sample);
        if (segment[0].format != c.GST_FORMAT_TIME) break :seg;
        c.g_mutex_lock(&r.mutex);
        if (c.gst_segment_is_equal(&r.last_segment, segment) != 0) {
            c.g_mutex_unlock(&r.mutex);
            break :seg;
        }
        c.gst_segment_copy_into(segment, &r.last_segment);
        r.pending_custom_segment = true;
        c.g_mutex_unlock(&r.mutex);
    }
    const b = c.gst_sample_get_buffer(sample);
    if (b != null) return pushInternal(s, b, null, false);
    const l = c.gst_sample_get_buffer_list(sample);
    if (l != null) return pushInternal(s, null, l, false);
    return c.GST_FLOW_OK;
}

pub export fn gst_app_src_push_buffer(s: [*c]Src, b: [*c]Buffer) c.GstFlowReturn {
    return pushInternal(s, b, null, true);
}

pub export fn gst_app_src_push_buffer_list(s: [*c]Src, l: ?*List) c.GstFlowReturn {
    return pushInternal(s, null, l, true);
}

pub export fn gst_app_src_push_sample(s: [*c]Src, sample: ?*c.GstSample) c.GstFlowReturn {
    return pushSampleInternal(s, sample);
}

fn pushBufferAction(s: [*c]Src, b: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    return pushInternal(s, b, null, false);
}

fn pushListAction(s: [*c]Src, l: ?*List) callconv(.c) c.GstFlowReturn {
    return pushInternal(s, null, l, false);
}

fn pushSampleAction(s: [*c]Src, sample: ?*c.GstSample) callconv(.c) c.GstFlowReturn {
    return pushSampleInternal(s, sample);
}

pub export fn gst_app_src_end_of_stream(s: [*c]Src) c.GstFlowReturn {
    if (!check.that(isSrc(s), "gst_app_src_end_of_stream", "GST_IS_APP_SRC (appsrc)")) return c.GST_FLOW_ERROR;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    if (r.flushing) return c.GST_FLOW_FLUSHING;
    r.is_eos = true;
    c.g_cond_broadcast(&r.cond);
    return c.GST_FLOW_OK;
}

pub export fn gst_app_src_set_callbacks(s: [*c]Src, callbacks: [*c]c.GstAppSrcCallbacks, user_data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isSrc(s), "gst_app_src_set_callbacks", "GST_IS_APP_SRC (appsrc)")) return;
    if (!check.that(callbacks != null, "gst_app_src_set_callbacks", "callbacks != NULL")) return;
    const r = priv(s);
    const n: *Callbacks = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Callbacks))));
    n.* = .{ .callbacks = callbacks.*, .user_data = user_data, .destroy_notify = notify, .ref_count = 1 };
    c.g_mutex_lock(&r.mutex);
    const old = r.callbacks;
    const simple = r.simple_callbacks;
    r.simple_callbacks = null;
    r.callbacks = n;
    c.g_mutex_unlock(&r.mutex);
    cbUnref(old);
    if (simple) |x| gst_app_src_simple_callbacks_unref(@ptrCast(x));
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SRC;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return &protocols;
}

fn uriGet(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    const r = priv(h);
    return if (r.uri != null) c.g_strdup(r.uri) else null;
}

fn uriSet(h: ?*c.GstURIHandler, uri: [*c]const u8, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const r = priv(h);
    c.g_free(r.uri);
    r.uri = if (uri != null) c.g_strdup(uri) else null;
    return 1;
}

fn uriInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(iface));
    i.get_type = uriType;
    i.get_protocols = uriProtocols;
    i.get_uri = uriGet;
    i.set_uri = uriSet;
}

fn event(b: [*c]c.GstBaseSrc, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const r = priv(b);
    if (e[0].type == c.GST_EVENT_FLUSH_STOP) {
        c.g_mutex_lock(&r.mutex);
        r.is_eos = false;
        c.g_mutex_unlock(&r.mutex);
    }
    return parent.?.event.?(b, e);
}

pub export fn gst_app_src_set_simple_callbacks(s: [*c]Src, cb: ?*c.GstAppSrcSimpleCallbacks) void {
    if (!check.that(isSrc(s), "gst_app_src_set_simple_callbacks", "GST_IS_APP_SRC (appsrc)")) return;
    const x: ?*Simple = @ptrCast(@alignCast(cb));
    if (x) |v| @atomicStore(c.gint, &v.attached, 1, .seq_cst);
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    const old = r.simple_callbacks;
    const cbs = r.callbacks;
    r.callbacks = null;
    r.simple_callbacks = x;
    c.g_mutex_unlock(&r.mutex);
    cbUnref(cbs);
    if (old) |v| gst_app_src_simple_callbacks_unref(@ptrCast(v));
}

pub export fn gst_app_src_simple_callbacks_new() ?*c.GstAppSrcSimpleCallbacks {
    const x: *Simple = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Simple))));
    x.ref_count = 1;
    x.attached = 0;
    return @ptrCast(x);
}

pub export fn gst_app_src_simple_callbacks_ref(cb: ?*c.GstAppSrcSimpleCallbacks) ?*c.GstAppSrcSimpleCallbacks {
    if (!check.that(cb != null, "gst_app_src_simple_callbacks_ref", "cb != NULL")) return null;
    const x: *Simple = @ptrCast(@alignCast(cb));
    _ = @atomicRmw(c.gint, &x.ref_count, .Add, 1, .seq_cst);
    return cb;
}

pub export fn gst_app_src_simple_callbacks_unref(cb: ?*c.GstAppSrcSimpleCallbacks) void {
    if (!check.that(cb != null, "gst_app_src_simple_callbacks_unref", "cb != NULL")) return;
    const x: *Simple = @ptrCast(@alignCast(cb));
    if (@atomicRmw(c.gint, &x.ref_count, .Sub, 1, .seq_cst) != 1) return;
    if (x.need_data_destroy_notify) |d| d(x.need_data_user_data);
    if (x.enough_data_destroy_notify) |d| d(x.enough_data_user_data);
    if (x.seek_data_destroy_notify) |d| d(x.seek_data_user_data);
    c.g_free(x);
}

fn simpleGuard(cb: ?*c.GstAppSrcSimpleCallbacks, comptime func: []const u8) ?*Simple {
    if (!check.that(cb != null, func, "cb != NULL")) return null;
    const x: *Simple = @ptrCast(@alignCast(cb));
    if (!check.that(@atomicLoad(c.gint, &x.attached, .seq_cst) == 0, func, "!g_atomic_int_get (&cb->attached)")) return null;
    return x;
}

pub export fn gst_app_src_simple_callbacks_set_need_data(cb: ?*c.GstAppSrcSimpleCallbacks, f: c.GstAppSrcNeedDataCallback, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const x = simpleGuard(cb, "gst_app_src_simple_callbacks_set_need_data") orelse return;
    if (x.need_data_destroy_notify) |d| d(x.need_data_user_data);
    x.need_data_cb = f;
    x.need_data_user_data = data;
    x.need_data_destroy_notify = destroy;
}

pub export fn gst_app_src_simple_callbacks_set_enough_data(cb: ?*c.GstAppSrcSimpleCallbacks, f: c.GstAppSrcEnoughDataCallback, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const x = simpleGuard(cb, "gst_app_src_simple_callbacks_set_enough_data") orelse return;
    if (x.enough_data_destroy_notify) |d| d(x.enough_data_user_data);
    x.enough_data_cb = f;
    x.enough_data_user_data = data;
    x.enough_data_destroy_notify = destroy;
}

pub export fn gst_app_src_simple_callbacks_set_seek_data(cb: ?*c.GstAppSrcSimpleCallbacks, f: c.GstAppSrcSeekDataCallback, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const x = simpleGuard(cb, "gst_app_src_simple_callbacks_set_seek_data") orelse return;
    if (x.seek_data_destroy_notify) |d| d(x.seek_data_user_data);
    x.seek_data_cb = f;
    x.seek_data_user_data = data;
    x.seek_data_destroy_notify = destroy;
}

const T_NONE: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const T_BOOLEAN: c.GType = 5 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const T_UINT: c.GType = 7 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const T_UINT64: c.GType = 11 << c.G_TYPE_FUNDAMENTAL_SHIFT;

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset != 0) c.g_type_class_adjust_private_offset(k, &offset);
    _ = c._gst_debug_category_new("appsrc", 0, "appsrc element");
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.dispose = dispose;
    gc.finalize = finalize;
    gc.set_property = setProp;
    gc.get_property = getProp;
    const rw = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const umax = std.math.maxInt(u64);
    const imax = std.math.maxInt(i64);
    c.g_object_class_install_property(gc, PROP_CAPS, c.g_param_spec_boxed("caps", "Caps", "The allowed caps for the src pad", c._gst_caps_type, rw));
    c.g_object_class_install_property(gc, PROP_FORMAT, c.g_param_spec_enum("format", "Format", "The format of the segment events and seek", c.gst_format_get_type(), c.GST_FORMAT_BYTES, rw));
    c.g_object_class_install_property(gc, PROP_SIZE, c.g_param_spec_int64("size", "Size", "The size of the data stream in bytes (-1 if unknown)", -1, imax, -1, rw));
    c.g_object_class_install_property(gc, PROP_STREAM_TYPE, c.g_param_spec_enum("stream-type", "Stream Type", "the type of the stream", enums.gst_app_stream_type_get_type(), c.GST_APP_STREAM_TYPE_STREAM, rw));
    c.g_object_class_install_property(gc, PROP_MAX_BYTES, c.g_param_spec_uint64("max-bytes", "Max bytes", "The maximum number of bytes to queue internally (0 = unlimited)", 0, umax, 200000, rw));
    c.g_object_class_install_property(gc, PROP_MAX_BUFFERS, c.g_param_spec_uint64("max-buffers", "Max buffers", "The maximum number of buffers to queue internally (0 = unlimited)", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_MAX_TIME, c.g_param_spec_uint64("max-time", "Max time", "The maximum amount of time to queue internally (0 = unlimited)", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_BLOCK, c.g_param_spec_boolean("block", "Block", "Block push-buffer when max-bytes are queued", 0, rw));
    c.g_object_class_install_property(gc, PROP_IS_LIVE, c.g_param_spec_boolean("is-live", "Is Live", "Whether to act as a live source", 0, rw));
    c.g_object_class_install_property(gc, PROP_MIN_LATENCY, c.g_param_spec_int64("min-latency", "Min Latency", "The minimum latency (-1 = default)", -1, imax, -1, rw));
    c.g_object_class_install_property(gc, PROP_MAX_LATENCY, c.g_param_spec_int64("max-latency", "Max Latency", "The maximum latency (-1 = unlimited)", -1, imax, -1, rw));
    c.g_object_class_install_property(gc, PROP_EMIT_SIGNALS, c.g_param_spec_boolean("emit-signals", "Emit signals", "Emit need-data, enough-data and seek-data signals", 1, rw));
    c.g_object_class_install_property(gc, PROP_MIN_PERCENT, c.g_param_spec_uint("min-percent", "Min Percent", "Emit need-data when queued bytes drops below this percent of max-bytes", 0, 100, 0, rw));
    c.g_object_class_install_property(gc, PROP_CURRENT_LEVEL_BYTES, c.g_param_spec_uint64("current-level-bytes", "Current Level Bytes", "The number of currently queued bytes", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_CURRENT_LEVEL_BUFFERS, c.g_param_spec_uint64("current-level-buffers", "Current Level Buffers", "The number of currently queued buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_CURRENT_LEVEL_TIME, c.g_param_spec_uint64("current-level-time", "Current Level Time", "The amount of currently queued time", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_DURATION, c.g_param_spec_uint64("duration", "Duration", "The duration of the data stream in nanoseconds (GST_CLOCK_TIME_NONE if unknown)", 0, umax, NONE, rw));
    c.g_object_class_install_property(gc, PROP_HANDLE_SEGMENT_CHANGE, c.g_param_spec_boolean("handle-segment-change", "Handle Segment Change", "Whether to detect and handle changed time format GstSegment in GstSample. User should set valid GstSegment in GstSample. Must set format property as \"time\" to enable this property", 0, rw | c.GST_PARAM_MUTABLE_READY));
    c.g_object_class_install_property(gc, PROP_LEAKY_TYPE, c.g_param_spec_enum("leaky-type", "Leaky Type", "Whether to drop buffers once the internal queue is full", enums.gst_app_leaky_type_get_type(), c.GST_APP_LEAKY_TYPE_NONE, rw | c.GST_PARAM_MUTABLE_PLAYING));
    c.g_object_class_install_property(gc, PROP_IN, c.g_param_spec_uint64("in", "In", "Number of input buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_OUT, c.g_param_spec_uint64("out", "Out", "Number of output buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_DROPPED, c.g_param_spec_uint64("dropped", "Dropped", "Number of dropped buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_SILENT, c.g_param_spec_boolean("silent", "silent", "Don't emit notify for dropped buffers", 1, rw));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    const action = c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION;
    signals[SIG_NEED_DATA] = c.g_signal_new("need-data", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "need_data"), null, null, null, T_NONE, @as(c.guint, 1), T_UINT);
    signals[SIG_ENOUGH_DATA] = c.g_signal_new("enough-data", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "enough_data"), null, null, null, T_NONE, @as(c.guint, 0), T_NONE);
    signals[SIG_SEEK_DATA] = c.g_signal_new("seek-data", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "seek_data"), null, null, null, T_BOOLEAN, @as(c.guint, 1), T_UINT64);
    signals[SIG_PUSH_BUFFER] = c.g_signal_new("push-buffer", t, action, @offsetOf(Class, "push_buffer"), null, null, null, c.gst_flow_return_get_type(), @as(c.guint, 1), c._gst_buffer_type);
    signals[SIG_PUSH_BUFFER_LIST] = c.g_signal_new("push-buffer-list", t, action, @offsetOf(Class, "push_buffer_list"), null, null, null, c.gst_flow_return_get_type(), @as(c.guint, 1), c._gst_buffer_list_type);
    signals[SIG_PUSH_SAMPLE] = c.g_signal_new("push-sample", t, action, @offsetOf(Class, "push_sample"), null, null, null, c.gst_flow_return_get_type(), @as(c.guint, 1), c._gst_sample_type);
    signals[SIG_END_OF_STREAM] = c.g_signal_new("end-of-stream", t, action, @offsetOf(Class, "end_of_stream"), null, null, null, c.gst_flow_return_get_type(), @as(c.guint, 0), T_NONE);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "AppSrc", "Generic/Source", "Allow the application to feed buffers to a pipeline", "David Schleef <ds@schleef.org>, Wim Taymans <wim.taymans@gmail.com>");
    c.gst_element_class_add_static_pad_template(ec, &templ);
    ec.send_event = sendEvent;
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.negotiate = negotiate;
    bc.get_caps = internalGetCaps;
    bc.create = create;
    bc.start = start;
    bc.stop = stop;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    bc.do_seek = doSeek;
    bc.is_seekable = isSeekable;
    bc.get_size = getSize;
    bc.query = query;
    bc.event = event;
    const ac: *Class = @ptrCast(@alignCast(k));
    ac.push_buffer = pushBufferAction;
    ac.push_buffer_list = pushListAction;
    ac.push_sample = pushSampleAction;
    ac.end_of_stream = gst_app_src_end_of_stream;
}

fn init(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: [*c]Src = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    s[0].priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
    const r = priv(s);
    c.g_mutex_init(&r.mutex);
    c.g_cond_init(&r.cond);
    r.queue = c.gst_vec_deque_new(16);
    r.delayed_events = c.gst_vec_deque_new(16);
    r.wait_status = 0;
    r.pushed_buffer = false;
    r.size = -1;
    r.duration = NONE;
    r.stream_type = c.GST_APP_STREAM_TYPE_STREAM;
    r.max_bytes = 200000;
    r.max_buffers = 0;
    r.max_time = 0;
    r.format = c.GST_FORMAT_BYTES;
    r.block = false;
    r.min_latency = NONE;
    r.max_latency = NONE;
    r.emit_signals = true;
    r.min_percent = 0;
    r.handle_segment_change = false;
    r.leaky_type = c.GST_APP_LEAKY_TYPE_NONE;
    r.silent = true;
    c.gst_base_src_set_live(@ptrCast(s), 0);
}

pub export fn gst_app_src_get_type() c.GType {
    return once.get(struct {
        var iface = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
        fn f() c.GType {
            const t = gtype.object(c.gst_base_src_get_type, "GstAppSrc", Class, Src, classInit, init, 0);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &iface);
            return t;
        }
    }.f);
}
