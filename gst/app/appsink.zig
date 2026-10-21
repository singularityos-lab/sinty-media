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

const Sink = c.GstAppSink;
const Class = c.GstAppSinkClass;
const Buffer = c.GstBuffer;
const List = c.GstBufferList;
const Mini = c.GstMiniObject;
const Sample = c.GstSample;
const NONE = el.NONE;
const PATH = "../gst-libs/gst/app/gstappsink.c";
const STREAM_WAITING: c_uint = 1 << 0;
const APP_WAITING: c_uint = 1 << 1;

const Callbacks = extern struct {
    callbacks: c.GstAppSinkCallbacks,
    user_data: c.gpointer,
    destroy_notify: c.GDestroyNotify,
    ref_count: c.gint,
};

const Simple = extern struct {
    ref_count: c.gint,
    attached: c.gint,
    eos_cb: c.GstAppSinkEosCallback,
    eos_user_data: c.gpointer,
    eos_destroy_notify: c.GDestroyNotify,
    new_preroll_cb: c.GstAppSinkNewPrerollCallback,
    new_preroll_user_data: c.gpointer,
    new_preroll_destroy_notify: c.GDestroyNotify,
    new_sample_cb: c.GstAppSinkNewSampleCallback,
    new_sample_user_data: c.gpointer,
    new_sample_destroy_notify: c.GDestroyNotify,
    new_event_cb: c.GstAppSinkNewEventCallback,
    new_event_user_data: c.gpointer,
    new_event_destroy_notify: c.GDestroyNotify,
    propose_allocation_cb: c.GstAppSinkProposeAllocationCallback,
    propose_allocation_user_data: c.gpointer,
    propose_allocation_destroy_notify: c.GDestroyNotify,
};

const Private = extern struct {
    caps: [*c]c.GstCaps,
    emit_signals: bool,
    max_buffers: u64,
    max_time: u64,
    max_bytes: u64,
    wait_on_eos: bool,
    wait_status: c_uint,
    status: queue.Status,
    leaky_type: c.GstAppLeakyType,
    in: u64,
    out: u64,
    dropped: u64,
    silent: bool,
    cond: c.GCond,
    mutex: c.GMutex,
    queue: ?*c.GstVecDeque,
    preroll_buffer: [*c]Buffer,
    preroll_caps: [*c]c.GstCaps,
    last_caps: [*c]c.GstCaps,
    preroll_segment: c.GstSegment,
    last_segment: c.GstSegment,
    flushing: bool,
    unlock: bool,
    started: bool,
    is_eos: bool,
    buffer_lists_supported: bool,
    callbacks: ?*Callbacks,
    simple_callbacks: ?*Simple,
    sample: ?*Sample,
};

const SIG_EOS = 0;
const SIG_NEW_PREROLL = 1;
const SIG_NEW_SAMPLE = 2;
const SIG_NEW_SERIALIZED_EVENT = 3;
const SIG_PULL_PREROLL = 4;
const SIG_PULL_SAMPLE = 5;
const SIG_TRY_PULL_PREROLL = 6;
const SIG_TRY_PULL_SAMPLE = 7;
const SIG_TRY_PULL_OBJECT = 8;
const SIG_PROPOSE_ALLOCATION = 9;

const PROP_CAPS = 1;
const PROP_EOS = 2;
const PROP_EMIT_SIGNALS = 3;
const PROP_MAX_BUFFERS = 4;
const PROP_DROP = 5;
const PROP_WAIT_ON_EOS = 6;
const PROP_BUFFER_LIST = 7;
const PROP_MAX_TIME = 8;
const PROP_MAX_BYTES = 9;
const PROP_CURRENT_LEVEL_BYTES = 10;
const PROP_CURRENT_LEVEL_BUFFERS = 11;
const PROP_CURRENT_LEVEL_TIME = 12;
const PROP_LEAKY_TYPE = 13;
const PROP_IN = 14;
const PROP_OUT = 15;
const PROP_DROPPED = 16;
const PROP_SILENT = 17;

var once: gtype.Once = .{};
var simple_once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GstBaseSinkClass = null;
var signals: [10]c.guint = .{0} ** 10;
var templ = c.GstStaticPadTemplate{ .name_template = "sink", .direction = c.GST_PAD_SINK, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "ANY", ._gst_reserved = .{null} ** 4 } };
var protocols = [_][*c]const u8{ "appsink", null };

fn priv(s: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Sink, @ptrCast(@alignCast(s)))[0].priv));
}

fn of(s: anytype) [*c]Sink {
    return @ptrCast(@alignCast(s));
}

fn isSink(s: anytype) bool {
    return gtype.instanceOf(s, gst_app_sink_get_type());
}

fn isType(o: anytype, t: c.GType) bool {
    const p: ?*const c.GstMiniObject = @ptrCast(@alignCast(o));
    return if (p) |m| m.type == t else false;
}

fn sinkPad(s: anytype) ?*c.GstPad {
    return @as(*c.GstBaseSink, @ptrCast(@alignCast(s))).sinkpad;
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
        } else if (r.simple_callbacks) |s| h.simple = @ptrCast(@alignCast(gst_app_sink_simple_callbacks_ref(@ptrCast(s))));
        return h;
    }

    fn release(h: *Held) void {
        cbUnref(h.cb);
        if (h.simple) |s| gst_app_sink_simple_callbacks_unref(@ptrCast(s));
    }
};

fn simpleCopy(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_app_sink_simple_callbacks_ref(@ptrCast(@alignCast(p)));
}

fn simpleFree(p: c.gpointer) callconv(.c) void {
    gst_app_sink_simple_callbacks_unref(@ptrCast(@alignCast(p)));
}

pub export fn gst_app_sink_simple_callbacks_get_type() c.GType {
    return simple_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstAppSinkSimpleCallbacks", simpleCopy, simpleFree);
        }
    }.f);
}

fn writableSample(r: *Private) void {
    r.sample = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(r.sample)))));
}

fn clearSample(r: *Private) void {
    writableSample(r);
    c.gst_sample_set_buffer(r.sample, null);
    c.gst_sample_set_buffer_list(r.sample, null);
    c.gst_sample_set_caps(r.sample, null);
    c.gst_sample_set_segment(r.sample, null);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const r = priv(o);
    el.lock(o);
    if (r.caps != null) {
        c.gst_caps_unref(r.caps);
        r.caps = null;
    }
    el.unlock(o);
    c.g_mutex_lock(&r.mutex);
    const cb = r.callbacks;
    r.callbacks = null;
    const simple = r.simple_callbacks;
    r.simple_callbacks = null;
    while (c.gst_vec_deque_pop_head(r.queue)) |q| c.gst_mini_object_unref(@ptrCast(@alignCast(q)));
    _ = c.gst_mini_object_replace(@ptrCast(&r.preroll_buffer), null);
    _ = c.gst_caps_replace(&r.preroll_caps, null);
    _ = c.gst_caps_replace(&r.last_caps, null);
    if (r.sample) |s| {
        c.gst_mini_object_unref(@ptrCast(@alignCast(s)));
        r.sample = null;
    }
    c.g_mutex_unlock(&r.mutex);
    cbUnref(cb);
    if (simple) |x| gst_app_sink_simple_callbacks_unref(@ptrCast(x));
    @as(*c.GObjectClass, @ptrCast(parent.?)).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const r = priv(o);
    c.g_mutex_clear(&r.mutex);
    c.g_cond_clear(&r.cond);
    c.gst_vec_deque_free(r.queue);
    @as(*c.GObjectClass, @ptrCast(parent.?)).finalize.?(o);
}

fn setProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const s = of(o);
    switch (id) {
        PROP_CAPS => gst_app_sink_set_caps(s, c.gst_value_get_caps(v)),
        PROP_EMIT_SIGNALS => gst_app_sink_set_emit_signals(s, c.g_value_get_boolean(v)),
        PROP_MAX_BUFFERS => gst_app_sink_set_max_buffers(s, c.g_value_get_uint(v)),
        PROP_MAX_TIME => gst_app_sink_set_max_time(s, c.g_value_get_uint64(v)),
        PROP_MAX_BYTES => gst_app_sink_set_max_bytes(s, c.g_value_get_uint64(v)),
        PROP_DROP => gst_app_sink_set_drop(s, c.g_value_get_boolean(v)),
        PROP_BUFFER_LIST => gst_app_sink_set_buffer_list_support(s, c.g_value_get_boolean(v)),
        PROP_WAIT_ON_EOS => gst_app_sink_set_wait_on_eos(s, c.g_value_get_boolean(v)),
        PROP_LEAKY_TYPE => gst_app_sink_set_leaky_type(s, @intCast(c.g_value_get_enum(v))),
        PROP_SILENT => priv(o).silent = c.g_value_get_boolean(v) != 0,
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 878),
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
        PROP_CAPS => {
            const caps = gst_app_sink_get_caps(s);
            c.gst_value_set_caps(v, caps);
            if (caps != null) c.gst_caps_unref(caps);
        },
        PROP_EOS => c.g_value_set_boolean(v, gst_app_sink_is_eos(s)),
        PROP_EMIT_SIGNALS => c.g_value_set_boolean(v, gst_app_sink_get_emit_signals(s)),
        PROP_MAX_BUFFERS => c.g_value_set_uint(v, gst_app_sink_get_max_buffers(s)),
        PROP_MAX_TIME => c.g_value_set_uint64(v, gst_app_sink_get_max_time(s)),
        PROP_MAX_BYTES => c.g_value_set_uint64(v, gst_app_sink_get_max_bytes(s)),
        PROP_DROP => c.g_value_set_boolean(v, gst_app_sink_get_drop(s)),
        PROP_BUFFER_LIST => c.g_value_set_boolean(v, gst_app_sink_get_buffer_list_support(s)),
        PROP_WAIT_ON_EOS => c.g_value_set_boolean(v, gst_app_sink_get_wait_on_eos(s)),
        PROP_CURRENT_LEVEL_BYTES => c.g_value_set_uint64(v, gst_app_sink_get_current_level_bytes(s)),
        PROP_CURRENT_LEVEL_BUFFERS => c.g_value_set_uint64(v, gst_app_sink_get_current_level_buffers(s)),
        PROP_CURRENT_LEVEL_TIME => c.g_value_set_uint64(v, gst_app_sink_get_current_level_time(s)),
        PROP_LEAKY_TYPE => c.g_value_set_enum(v, @intCast(gst_app_sink_get_leaky_type(s))),
        PROP_IN => c.g_value_set_uint64(v, counter(r, &r.in)),
        PROP_OUT => c.g_value_set_uint64(v, counter(r, &r.out)),
        PROP_DROPPED => c.g_value_set_uint64(v, counter(r, &r.dropped)),
        PROP_SILENT => c.g_value_set_boolean(v, @intFromBool(r.silent)),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 958),
    }
}

fn unlockStart(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    r.unlock = true;
    c.g_cond_signal(&r.cond);
    c.g_mutex_unlock(&r.mutex);
    return 1;
}

fn unlockStop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    r.unlock = false;
    c.g_cond_signal(&r.cond);
    c.g_mutex_unlock(&r.mutex);
    return 1;
}

fn flushUnlocked(s: anytype) void {
    const r = priv(s);
    r.is_eos = false;
    _ = c.gst_mini_object_replace(@ptrCast(&r.preroll_buffer), null);
    while (c.gst_vec_deque_pop_head(r.queue)) |q| c.gst_mini_object_unref(@ptrCast(@alignCast(q)));
    queue.reset(&r.status);
    _ = c.gst_caps_replace(&r.last_caps, null);
    c.g_cond_signal(&r.cond);
    r.in = 0;
    r.out = 0;
    r.dropped = 0;
}

fn start(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    r.wait_status = 0;
    r.flushing = false;
    r.started = true;
    c.gst_segment_init(&r.preroll_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&r.last_segment, c.GST_FORMAT_TIME);
    clearSample(r);
    r.in = 0;
    r.out = 0;
    r.dropped = 0;
    c.g_mutex_unlock(&r.mutex);
    return 1;
}

fn stop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    r.flushing = true;
    r.started = false;
    r.wait_status = 0;
    flushUnlocked(b);
    _ = c.gst_mini_object_replace(@ptrCast(&r.preroll_buffer), null);
    _ = c.gst_caps_replace(&r.preroll_caps, null);
    _ = c.gst_caps_replace(&r.last_caps, null);
    c.gst_segment_init(&r.preroll_segment, c.GST_FORMAT_UNDEFINED);
    c.gst_segment_init(&r.last_segment, c.GST_FORMAT_UNDEFINED);
    clearSample(r);
    r.in = 0;
    r.out = 0;
    r.dropped = 0;
    c.g_mutex_unlock(&r.mutex);
    notifyDropped(b);
    return 1;
}

fn setCaps(b: [*c]c.GstBaseSink, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    if (r.preroll_buffer == null) _ = c.gst_caps_replace(&r.preroll_caps, caps);
    c.g_mutex_unlock(&r.mutex);
    return 1;
}

fn event(b: [*c]c.GstBaseSink, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const r = priv(b);
    switch (e[0].type) {
        c.GST_EVENT_SEGMENT => {
            c.g_mutex_lock(&r.mutex);
            if (r.preroll_buffer == null) c.gst_event_copy_segment(e, &r.preroll_segment);
            c.g_mutex_unlock(&r.mutex);
        },
        c.GST_EVENT_EOS => {
            c.g_mutex_lock(&r.mutex);
            r.is_eos = true;
            c.g_cond_signal(&r.cond);
            c.g_mutex_unlock(&r.mutex);
            c.g_mutex_lock(&r.mutex);
            while (r.status.queued_buffers > 0 and !r.flushing and r.wait_on_eos) {
                if (r.unlock) {
                    c.g_mutex_unlock(&r.mutex);
                    if (c.gst_base_sink_wait_preroll(b) != c.GST_FLOW_OK) {
                        c.gst_event_unref(e);
                        return 0;
                    }
                    c.g_mutex_lock(&r.mutex);
                    continue;
                }
                r.wait_status |= STREAM_WAITING;
                c.g_cond_wait(&r.cond, &r.mutex);
                r.wait_status &= ~STREAM_WAITING;
            }
            const emit = !r.flushing;
            var h = Held{};
            if (emit) h = Held.take(r);
            c.g_mutex_unlock(&r.mutex);
            if (emit) {
                if (h.cb != null and h.cb.?.callbacks.eos != null) {
                    h.cb.?.callbacks.eos.?(of(b), h.cb.?.user_data);
                } else if (h.simple != null and h.simple.?.eos_cb != null) {
                    h.simple.?.eos_cb.?(of(b), h.simple.?.eos_user_data);
                } else c.g_signal_emit(b, signals[SIG_EOS], 0);
                h.release();
            }
        },
        c.GST_EVENT_FLUSH_STOP => {
            c.g_mutex_lock(&r.mutex);
            flushUnlocked(b);
            c.g_mutex_unlock(&r.mutex);
            notifyDropped(b);
        },
        else => {},
    }
    if (e[0].type != c.GST_EVENT_EOS and e[0].type & c.GST_EVENT_TYPE_SERIALIZED != 0) {
        c.g_mutex_lock(&r.mutex);
        var h = Held.take(r);
        c.gst_vec_deque_push_tail(r.queue, c.gst_event_ref(e));
        queue.pushEvent(&r.status);
        if (r.wait_status & APP_WAITING != 0) c.g_cond_signal(&r.cond);
        c.g_mutex_unlock(&r.mutex);
        var ret: c.gboolean = 0;
        if (h.cb != null and h.cb.?.callbacks.new_event != null) {
            ret = h.cb.?.callbacks.new_event.?(of(b), h.cb.?.user_data);
        } else if (h.simple != null and h.simple.?.new_event_cb != null) {
            ret = h.simple.?.new_event_cb.?(of(b), h.simple.?.new_event_user_data);
        } else if (h.emit) c.g_signal_emit(b, signals[SIG_NEW_SERIALIZED_EVENT], 0, &ret);
        h.release();
        if (ret != 0) {
            c.gst_event_unref(e);
            return 1;
        }
    }
    return parent.?.event.?(b, e);
}

fn preroll(b: [*c]c.GstBaseSink, buffer: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    if (r.flushing) {
        c.g_mutex_unlock(&r.mutex);
        return c.GST_FLOW_FLUSHING;
    }
    _ = c.gst_mini_object_replace(@ptrCast(&r.preroll_buffer), @ptrCast(buffer));
    if (r.wait_status & APP_WAITING != 0) c.g_cond_signal(&r.cond);
    var h = Held.take(r);
    c.g_mutex_unlock(&r.mutex);
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    if (h.cb != null and h.cb.?.callbacks.new_preroll != null) {
        res = h.cb.?.callbacks.new_preroll.?(of(b), h.cb.?.user_data);
    } else if (h.simple != null and h.simple.?.new_preroll_cb != null) {
        res = h.simple.?.new_preroll_cb.?(of(b), h.simple.?.new_preroll_user_data);
    } else if (h.emit) c.g_signal_emit(b, signals[SIG_NEW_PREROLL], 0, &res);
    h.release();
    return res;
}

fn dequeueObject(s: anytype) ?*Mini {
    const r = priv(s);
    const o: ?*Mini = @ptrCast(@alignCast(c.gst_vec_deque_pop_head(r.queue)));
    if (isType(o, c._gst_event_type)) {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(o));
        switch (e[0].type) {
            c.GST_EVENT_CAPS => {
                var caps: [*c]c.GstCaps = null;
                c.gst_event_parse_caps(e, &caps);
                _ = c.gst_caps_replace(&r.last_caps, caps);
                writableSample(r);
                c.gst_sample_set_caps(r.sample, r.last_caps);
            },
            c.GST_EVENT_SEGMENT => {
                c.gst_event_copy_segment(e, &r.last_segment);
                writableSample(r);
                c.gst_sample_set_segment(r.sample, &r.last_segment);
            },
            else => {},
        }
    }
    queue.pop(&r.status, o, &r.last_segment, &r.last_segment);
    return o;
}

fn dequeueBuffer(s: anytype) ?*Mini {
    while (true) {
        const o = dequeueObject(s);
        if (isType(o, c._gst_buffer_type) or isType(o, c._gst_buffer_list_type)) return o;
        c.gst_mini_object_unref(o);
    }
}

fn renderCommon(b: [*c]c.GstBaseSink, data: ?*Mini, is_list: bool) c.GstFlowReturn {
    const r = priv(b);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    restart: while (true) {
        c.g_mutex_lock(&r.mutex);
        if (r.flushing) {
            c.g_mutex_unlock(&r.mutex);
            return c.GST_FLOW_FLUSHING;
        }
        if (r.last_caps == null and c.gst_pad_has_current_caps(sinkPad(b)) != 0) {
            r.last_caps = c.gst_pad_get_current_caps(sinkPad(b));
            writableSample(r);
            c.gst_sample_set_caps(r.sample, r.last_caps);
        }
        while (queue.isFull(&r.status, r.max_buffers, r.max_bytes, r.max_time)) {
            if (r.leaky_type == c.GST_APP_LEAKY_TYPE_DOWNSTREAM) {
                const old = dequeueBuffer(b);
                if (old != null) {
                    r.dropped += if (isType(old, c._gst_buffer_list_type)) c.gst_buffer_list_length(@ptrCast(@alignCast(old))) else 1;
                    c.gst_mini_object_unref(old);
                    if (!r.silent) {
                        c.g_mutex_unlock(&r.mutex);
                        c.g_object_notify(@ptrCast(b), "dropped");
                        c.g_mutex_lock(&r.mutex);
                    }
                }
            } else if (r.leaky_type == c.GST_APP_LEAKY_TYPE_UPSTREAM) {
                r.dropped += if (is_list) c.gst_buffer_list_length(@ptrCast(@alignCast(data))) else 1;
                c.g_mutex_unlock(&r.mutex);
                notifyDropped(b);
                return ret;
            } else {
                if (r.unlock) {
                    c.g_mutex_unlock(&r.mutex);
                    ret = c.gst_base_sink_wait_preroll(b);
                    if (ret != c.GST_FLOW_OK) return ret;
                    continue :restart;
                }
                r.wait_status |= STREAM_WAITING;
                c.g_cond_wait(&r.cond, &r.mutex);
                r.wait_status &= ~STREAM_WAITING;
                if (r.flushing) {
                    c.g_mutex_unlock(&r.mutex);
                    return c.GST_FLOW_FLUSHING;
                }
            }
        }
        break;
    }
    r.in += if (is_list) c.gst_buffer_list_length(@ptrCast(@alignCast(data))) else 1;
    c.gst_vec_deque_push_tail(r.queue, c.gst_mini_object_ref(data));
    queue.push(&r.status, data, &r.last_segment);
    if (r.wait_status & APP_WAITING != 0) c.g_cond_signal(&r.cond);
    var h = Held.take(r);
    c.g_mutex_unlock(&r.mutex);
    ret = c.GST_FLOW_OK;
    if (h.cb != null and h.cb.?.callbacks.new_sample != null) {
        ret = h.cb.?.callbacks.new_sample.?(of(b), h.cb.?.user_data);
    } else if (h.simple != null and h.simple.?.new_sample_cb != null) {
        ret = h.simple.?.new_sample_cb.?(of(b), h.simple.?.new_sample_user_data);
    } else if (h.emit) c.g_signal_emit(b, signals[SIG_NEW_SAMPLE], 0, &ret);
    h.release();
    return ret;
}

fn render(b: [*c]c.GstBaseSink, buffer: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    return renderCommon(b, @ptrCast(buffer), false);
}

fn renderList(b: [*c]c.GstBaseSink, list: ?*List) callconv(.c) c.GstFlowReturn {
    if (priv(b).buffer_lists_supported) return renderCommon(b, @ptrCast(@alignCast(list)), true);
    const n = c.gst_buffer_list_length(list);
    var flow: c.GstFlowReturn = c.GST_FLOW_OK;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        flow = render(b, c.gst_buffer_list_get(list, i));
        if (flow != c.GST_FLOW_OK) break;
    }
    return flow;
}

fn getCaps(b: [*c]c.GstBaseSink, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    el.lock(b);
    defer el.unlock(b);
    var caps = priv(b).caps;
    if (caps != null) {
        if (filter != null) caps = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST) else _ = c.gst_caps_ref(caps);
    }
    return caps;
}

fn query(b: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const r = priv(b);
    switch (q[0].type) {
        c.GST_QUERY_DRAIN => {
            c.g_mutex_lock(&r.mutex);
            while (r.status.queued_buffers > 0 or r.preroll_buffer != null) {
                if (r.unlock) {
                    c.g_mutex_unlock(&r.mutex);
                    if (c.gst_base_sink_wait_preroll(b) != c.GST_FLOW_OK) return 0;
                    c.g_mutex_lock(&r.mutex);
                    continue;
                }
                r.wait_status |= STREAM_WAITING;
                c.g_cond_wait(&r.cond, &r.mutex);
                r.wait_status &= ~STREAM_WAITING;
                if (r.flushing) break;
            }
            c.g_mutex_unlock(&r.mutex);
            return parent.?.query.?(b, q);
        },
        c.GST_QUERY_SEEKING => {
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_seeking(q, &fmt, null, null, null);
            c.gst_query_set_seeking(q, fmt, 0, 0, -1);
            return 1;
        },
        else => return parent.?.query.?(b, q),
    }
}

pub export fn gst_app_sink_set_caps(s: [*c]Sink, caps: [*c]const c.GstCaps) void {
    if (!check.that(isSink(s), "gst_app_sink_set_caps", "GST_IS_APP_SINK (appsink)")) return;
    const r = priv(s);
    el.lock(s);
    const old = r.caps;
    if (@as(?*const anyopaque, @ptrCast(old)) != @as(?*const anyopaque, @ptrCast(caps))) {
        r.caps = if (caps != null) c.gst_caps_copy(caps) else null;
        if (old != null) c.gst_caps_unref(old);
    }
    el.unlock(s);
}

pub export fn gst_app_sink_get_caps(s: [*c]Sink) [*c]c.GstCaps {
    if (!check.that(isSink(s), "gst_app_sink_get_caps", "GST_IS_APP_SINK (appsink)")) return null;
    el.lock(s);
    defer el.unlock(s);
    const caps = priv(s).caps;
    if (caps != null) _ = c.gst_caps_ref(caps);
    return caps;
}

pub export fn gst_app_sink_is_eos(s: [*c]Sink) c.gboolean {
    if (!check.that(isSink(s), "gst_app_sink_is_eos", "GST_IS_APP_SINK (appsink)")) return 0;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    if (!r.started) return 1;
    return @intFromBool(r.is_eos and r.status.queued_buffers == 0);
}

pub export fn gst_app_sink_set_emit_signals(s: [*c]Sink, emit: c.gboolean) void {
    if (!check.that(isSink(s), "gst_app_sink_set_emit_signals", "GST_IS_APP_SINK (appsink)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    r.emit_signals = emit != 0;
    c.g_mutex_unlock(&r.mutex);
}

pub export fn gst_app_sink_get_emit_signals(s: [*c]Sink) c.gboolean {
    if (!check.that(isSink(s), "gst_app_sink_get_emit_signals", "GST_IS_APP_SINK (appsink)")) return 0;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return @intFromBool(r.emit_signals);
}

fn setLimit(s: [*c]Sink, comptime field: []const u8, v: u64, comptime func: []const u8) void {
    if (!check.that(isSink(s), func, "GST_IS_APP_SINK (appsink)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    if (v != @field(r, field)) {
        @field(r, field) = v;
        c.g_cond_signal(&r.cond);
    }
    c.g_mutex_unlock(&r.mutex);
}

fn getUint(s: [*c]Sink, comptime func: []const u8, comptime get: fn (*Private) u64) c.guint {
    if (!check.that(isSink(s), func, "GST_IS_APP_SINK (appsink)")) return 0;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return @truncate(get(r));
}

pub export fn gst_app_sink_set_max_buffers(s: [*c]Sink, max: c.guint) void {
    setLimit(s, "max_buffers", max, "gst_app_sink_set_max_buffers");
}

pub export fn gst_app_sink_set_max_time(s: [*c]Sink, max: c.GstClockTime) void {
    setLimit(s, "max_time", max, "gst_app_sink_set_max_time");
}

pub export fn gst_app_sink_set_max_bytes(s: [*c]Sink, max: c.guint64) void {
    setLimit(s, "max_bytes", max, "gst_app_sink_set_max_bytes");
}

pub export fn gst_app_sink_get_max_buffers(s: [*c]Sink) c.guint {
    return getUint(s, "gst_app_sink_get_max_buffers", struct {
        fn f(r: *Private) u64 {
            return r.max_buffers;
        }
    }.f);
}

pub export fn gst_app_sink_get_max_time(s: [*c]Sink) c.GstClockTime {
    return getUint(s, "gst_app_sink_get_max_time", struct {
        fn f(r: *Private) u64 {
            return r.max_time;
        }
    }.f);
}

pub export fn gst_app_sink_get_max_bytes(s: [*c]Sink) c.guint64 {
    return getUint(s, "gst_app_sink_get_max_bytes", struct {
        fn f(r: *Private) u64 {
            return r.max_bytes;
        }
    }.f);
}

pub export fn gst_app_sink_get_current_level_bytes(s: [*c]Sink) c.guint64 {
    return getUint(s, "gst_app_sink_get_current_level_bytes", struct {
        fn f(r: *Private) u64 {
            return r.status.queued_bytes;
        }
    }.f);
}

pub export fn gst_app_sink_get_current_level_buffers(s: [*c]Sink) c.guint64 {
    return getUint(s, "gst_app_sink_get_current_level_buffers", struct {
        fn f(r: *Private) u64 {
            return r.status.queued_buffers;
        }
    }.f);
}

pub export fn gst_app_sink_get_current_level_time(s: [*c]Sink) c.GstClockTime {
    return getUint(s, "gst_app_sink_get_current_level_time", struct {
        fn f(r: *Private) u64 {
            return r.status.queued_time;
        }
    }.f);
}

fn setLeaky(s: [*c]Sink, leaky: c.GstAppLeakyType) void {
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    if (r.leaky_type != leaky) {
        r.leaky_type = leaky;
        c.g_cond_signal(&r.cond);
    }
    c.g_mutex_unlock(&r.mutex);
}

pub export fn gst_app_sink_set_drop(s: [*c]Sink, drop: c.gboolean) void {
    if (!check.that(isSink(s), "gst_app_sink_set_drop", "GST_IS_APP_SINK (appsink)")) return;
    setLeaky(s, if (drop != 0) c.GST_APP_LEAKY_TYPE_DOWNSTREAM else c.GST_APP_LEAKY_TYPE_NONE);
}

pub export fn gst_app_sink_get_drop(s: [*c]Sink) c.gboolean {
    if (!check.that(isSink(s), "gst_app_sink_get_drop", "GST_IS_APP_SINK (appsink)")) return 0;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return @intFromBool(r.leaky_type != c.GST_APP_LEAKY_TYPE_NONE);
}

pub export fn gst_app_sink_set_leaky_type(s: [*c]Sink, leaky: c.GstAppLeakyType) void {
    if (!check.that(isSink(s), "gst_app_sink_set_leaky_type", "GST_IS_APP_SINK (appsink)")) return;
    setLeaky(s, leaky);
}

pub export fn gst_app_sink_get_leaky_type(s: [*c]Sink) c.GstAppLeakyType {
    if (!check.that(isSink(s), "gst_app_sink_get_leaky_type", "GST_IS_APP_SINK (appsink)")) return c.GST_APP_LEAKY_TYPE_NONE;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return r.leaky_type;
}

pub export fn gst_app_sink_set_buffer_list_support(s: [*c]Sink, enable: c.gboolean) void {
    if (!check.that(isSink(s), "gst_app_sink_set_buffer_list_support", "GST_IS_APP_SINK (appsink)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    r.buffer_lists_supported = enable != 0;
    c.g_mutex_unlock(&r.mutex);
}

pub export fn gst_app_sink_get_buffer_list_support(s: [*c]Sink) c.gboolean {
    if (!check.that(isSink(s), "gst_app_sink_get_buffer_list_support", "GST_IS_APP_SINK (appsink)")) return 0;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return @intFromBool(r.buffer_lists_supported);
}

pub export fn gst_app_sink_set_wait_on_eos(s: [*c]Sink, wait: c.gboolean) void {
    if (!check.that(isSink(s), "gst_app_sink_set_wait_on_eos", "GST_IS_APP_SINK (appsink)")) return;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    if (r.wait_on_eos != (wait != 0)) {
        r.wait_on_eos = wait != 0;
        c.g_cond_signal(&r.cond);
    }
    c.g_mutex_unlock(&r.mutex);
}

pub export fn gst_app_sink_get_wait_on_eos(s: [*c]Sink) c.gboolean {
    if (!check.that(isSink(s), "gst_app_sink_get_wait_on_eos", "GST_IS_APP_SINK (appsink)")) return 0;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    return @intFromBool(r.wait_on_eos);
}

pub export fn gst_app_sink_pull_preroll(s: [*c]Sink) ?*Sample {
    return gst_app_sink_try_pull_preroll(s, NONE);
}

pub export fn gst_app_sink_pull_sample(s: [*c]Sink) ?*Sample {
    return gst_app_sink_try_pull_sample(s, NONE);
}

pub export fn gst_app_sink_pull_object(s: [*c]Sink) [*c]Mini {
    return gst_app_sink_try_pull_object(s, NONE);
}

fn endTime(timeout: u64) i64 {
    return c.g_get_monotonic_time() +% @as(i64, @bitCast(timeout / 1000));
}

fn waitApp(r: *Private, valid: bool, end: i64) bool {
    r.wait_status |= APP_WAITING;
    if (valid) {
        if (c.g_cond_wait_until(&r.cond, &r.mutex, end) == 0) {
            r.wait_status &= ~APP_WAITING;
            return false;
        }
    } else c.g_cond_wait(&r.cond, &r.mutex);
    r.wait_status &= ~APP_WAITING;
    return true;
}

pub export fn gst_app_sink_try_pull_preroll(s: [*c]Sink, timeout: c.GstClockTime) ?*Sample {
    if (!check.that(isSink(s), "gst_app_sink_try_pull_preroll", "GST_IS_APP_SINK (appsink)")) return null;
    const r = priv(s);
    const valid = timeout != NONE;
    const end = if (valid) endTime(timeout) else 0;
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    while (true) {
        if (!r.started) return null;
        if (r.preroll_buffer != null) break;
        if (r.is_eos) return null;
        if (!waitApp(r, valid, end)) return null;
    }
    const sample = c.gst_sample_new(r.preroll_buffer, r.preroll_caps, &r.preroll_segment, null);
    _ = c.gst_mini_object_replace(@ptrCast(&r.preroll_buffer), null);
    return sample;
}

pub export fn gst_app_sink_try_pull_sample(s: [*c]Sink, timeout_in: c.GstClockTime) ?*Sample {
    var timeout = timeout_in;
    const valid = timeout != 0 and timeout != NONE;
    const end = if (valid) endTime(timeout) else 0;
    while (true) {
        const o = gst_app_sink_try_pull_object(s, timeout);
        if (o == null) return null;
        if (isType(o, c._gst_sample_type)) return @ptrCast(@alignCast(o));
        c.gst_mini_object_unref(o);
        if (valid) {
            const now = c.g_get_monotonic_time();
            if (now >= end) return null;
            timeout = @as(u64, @bitCast(end - now)) * 1000;
        }
    }
}

pub export fn gst_app_sink_try_pull_object(s: [*c]Sink, timeout: c.GstClockTime) [*c]Mini {
    if (!check.that(isSink(s), "gst_app_sink_try_pull_object", "GST_IS_APP_SINK (appsink)")) return null;
    const valid = timeout != NONE;
    const end = if (valid) endTime(timeout) else 0;
    const r = priv(s);
    c.g_mutex_lock(&r.mutex);
    defer c.g_mutex_unlock(&r.mutex);
    _ = c.gst_mini_object_replace(@ptrCast(&r.preroll_buffer), null);
    while (true) {
        if (!r.started) return null;
        if (r.status.queued_buffers > 0 or r.status.num_events > 0) break;
        if (r.is_eos) return null;
        if (!waitApp(r, valid, end)) return null;
    }
    const o = dequeueObject(s);
    var ret: [*c]Mini = @ptrCast(o);
    if (isType(o, c._gst_buffer_type)) {
        r.out += 1;
        writableSample(r);
        c.gst_sample_set_buffer_list(r.sample, null);
        c.gst_sample_set_buffer(r.sample, @ptrCast(@alignCast(o)));
        ret = c.gst_mini_object_ref(@ptrCast(@alignCast(r.sample)));
        c.gst_mini_object_unref(o);
    } else if (isType(o, c._gst_buffer_list_type)) {
        r.out += c.gst_buffer_list_length(@ptrCast(@alignCast(o)));
        writableSample(r);
        c.gst_sample_set_buffer(r.sample, null);
        c.gst_sample_set_buffer_list(r.sample, @ptrCast(@alignCast(o)));
        ret = c.gst_mini_object_ref(@ptrCast(@alignCast(r.sample)));
        c.gst_mini_object_unref(o);
    }
    if (r.wait_status & STREAM_WAITING != 0) c.g_cond_signal(&r.cond);
    return ret;
}

pub export fn gst_app_sink_set_callbacks(s: [*c]Sink, callbacks: [*c]c.GstAppSinkCallbacks, user_data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isSink(s), "gst_app_sink_set_callbacks", "GST_IS_APP_SINK (appsink)")) return;
    if (!check.that(callbacks != null, "gst_app_sink_set_callbacks", "callbacks != NULL")) return;
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
    if (simple) |x| gst_app_sink_simple_callbacks_unref(@ptrCast(x));
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SINK;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return &protocols;
}

fn uriGet(_: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    return c.g_strdup("appsink");
}

fn uriSet(_: ?*c.GstURIHandler, _: [*c]const u8, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    return 1;
}

fn uriInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(iface));
    i.get_type = uriType;
    i.get_protocols = uriProtocols;
    i.get_uri = uriGet;
    i.set_uri = uriSet;
}

fn proposeAllocation(b: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const r = priv(b);
    c.g_mutex_lock(&r.mutex);
    var h = Held.take(r);
    c.g_mutex_unlock(&r.mutex);
    var ret: c.gboolean = 0;
    if (h.cb != null and h.cb.?.callbacks.propose_allocation != null) {
        ret = h.cb.?.callbacks.propose_allocation.?(of(b), q, h.cb.?.user_data);
    } else if (h.simple != null and h.simple.?.propose_allocation_cb != null) {
        ret = h.simple.?.propose_allocation_cb.?(of(b), q, h.simple.?.propose_allocation_user_data);
    } else if (h.emit) c.g_signal_emit(b, signals[SIG_PROPOSE_ALLOCATION], 0, q, &ret);
    h.release();
    return ret;
}

pub export fn gst_app_sink_set_simple_callbacks(s: [*c]Sink, cb: ?*c.GstAppSinkSimpleCallbacks) void {
    if (!check.that(isSink(s), "gst_app_sink_set_simple_callbacks", "GST_IS_APP_SINK (appsink)")) return;
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
    if (old) |v| gst_app_sink_simple_callbacks_unref(@ptrCast(v));
}

pub export fn gst_app_sink_simple_callbacks_new() ?*c.GstAppSinkSimpleCallbacks {
    const x: *Simple = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Simple))));
    x.ref_count = 1;
    x.attached = 0;
    return @ptrCast(x);
}

pub export fn gst_app_sink_simple_callbacks_ref(cb: ?*c.GstAppSinkSimpleCallbacks) ?*c.GstAppSinkSimpleCallbacks {
    if (!check.that(cb != null, "gst_app_sink_simple_callbacks_ref", "cb != NULL")) return null;
    const x: *Simple = @ptrCast(@alignCast(cb));
    _ = @atomicRmw(c.gint, &x.ref_count, .Add, 1, .seq_cst);
    return cb;
}

pub export fn gst_app_sink_simple_callbacks_unref(cb: ?*c.GstAppSinkSimpleCallbacks) void {
    if (!check.that(cb != null, "gst_app_sink_simple_callbacks_unref", "cb != NULL")) return;
    const x: *Simple = @ptrCast(@alignCast(cb));
    if (@atomicRmw(c.gint, &x.ref_count, .Sub, 1, .seq_cst) != 1) return;
    if (x.eos_destroy_notify) |d| d(x.eos_user_data);
    if (x.new_preroll_destroy_notify) |d| d(x.new_preroll_user_data);
    if (x.new_sample_destroy_notify) |d| d(x.new_sample_user_data);
    if (x.new_event_destroy_notify) |d| d(x.new_event_user_data);
    if (x.propose_allocation_destroy_notify) |d| d(x.propose_allocation_user_data);
    c.g_free(x);
}

fn simpleGuard(cb: ?*c.GstAppSinkSimpleCallbacks, comptime func: []const u8) ?*Simple {
    if (!check.that(cb != null, func, "cb != NULL")) return null;
    const x: *Simple = @ptrCast(@alignCast(cb));
    if (!check.that(@atomicLoad(c.gint, &x.attached, .seq_cst) == 0, func, "!g_atomic_int_get (&cb->attached)")) return null;
    return x;
}

pub export fn gst_app_sink_simple_callbacks_set_eos(cb: ?*c.GstAppSinkSimpleCallbacks, f: c.GstAppSinkEosCallback, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const x = simpleGuard(cb, "gst_app_sink_simple_callbacks_set_eos") orelse return;
    if (x.eos_destroy_notify) |d| d(x.eos_user_data);
    x.eos_cb = f;
    x.eos_user_data = data;
    x.eos_destroy_notify = destroy;
}

pub export fn gst_app_sink_simple_callbacks_set_new_preroll(cb: ?*c.GstAppSinkSimpleCallbacks, f: c.GstAppSinkNewPrerollCallback, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const x = simpleGuard(cb, "gst_app_sink_simple_callbacks_set_new_preroll") orelse return;
    if (x.new_preroll_destroy_notify) |d| d(x.new_preroll_user_data);
    x.new_preroll_cb = f;
    x.new_preroll_user_data = data;
    x.new_preroll_destroy_notify = destroy;
}

pub export fn gst_app_sink_simple_callbacks_set_new_sample(cb: ?*c.GstAppSinkSimpleCallbacks, f: c.GstAppSinkNewSampleCallback, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const x = simpleGuard(cb, "gst_app_sink_simple_callbacks_set_new_sample") orelse return;
    if (x.new_sample_destroy_notify) |d| d(x.new_sample_user_data);
    x.new_sample_cb = f;
    x.new_sample_user_data = data;
    x.new_sample_destroy_notify = destroy;
}

pub export fn gst_app_sink_simple_callbacks_set_new_event(cb: ?*c.GstAppSinkSimpleCallbacks, f: c.GstAppSinkNewEventCallback, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const x = simpleGuard(cb, "gst_app_sink_simple_callbacks_set_new_event") orelse return;
    if (x.new_event_destroy_notify) |d| d(x.new_event_user_data);
    x.new_event_cb = f;
    x.new_event_user_data = data;
    x.new_event_destroy_notify = destroy;
}

pub export fn gst_app_sink_simple_callbacks_set_propose_allocation(cb: ?*c.GstAppSinkSimpleCallbacks, f: c.GstAppSinkProposeAllocationCallback, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const x = simpleGuard(cb, "gst_app_sink_simple_callbacks_set_propose_allocation") orelse return;
    if (x.propose_allocation_destroy_notify) |d| d(x.propose_allocation_user_data);
    x.propose_allocation_cb = f;
    x.propose_allocation_user_data = data;
    x.propose_allocation_destroy_notify = destroy;
}

const T_NONE: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const T_BOOLEAN: c.GType = 5 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const T_UINT64: c.GType = 11 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const STATIC_SCOPE: c.GType = 1;

fn pullPrerollAction(s: [*c]Sink) callconv(.c) ?*Sample {
    return gst_app_sink_pull_preroll(s);
}

fn pullSampleAction(s: [*c]Sink) callconv(.c) ?*Sample {
    return gst_app_sink_pull_sample(s);
}

fn tryPullPrerollAction(s: [*c]Sink, t: c.GstClockTime) callconv(.c) ?*Sample {
    return gst_app_sink_try_pull_preroll(s, t);
}

fn tryPullSampleAction(s: [*c]Sink, t: c.GstClockTime) callconv(.c) ?*Sample {
    return gst_app_sink_try_pull_sample(s, t);
}

fn tryPullObjectAction(s: [*c]Sink, t: c.GstClockTime) callconv(.c) [*c]Mini {
    return gst_app_sink_try_pull_object(s, t);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset != 0) c.g_type_class_adjust_private_offset(k, &offset);
    _ = c._gst_debug_category_new("appsink", 0, "appsink element");
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.dispose = dispose;
    gc.finalize = finalize;
    gc.set_property = setProp;
    gc.get_property = getProp;
    const rw = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const umax = std.math.maxInt(u64);
    c.g_object_class_install_property(gc, PROP_CAPS, c.g_param_spec_boxed("caps", "Caps", "The allowed caps for the sink pad", c._gst_caps_type, rw));
    c.g_object_class_install_property(gc, PROP_EOS, c.g_param_spec_boolean("eos", "EOS", "Check if the sink is EOS or not started", 1, ro));
    c.g_object_class_install_property(gc, PROP_EMIT_SIGNALS, c.g_param_spec_boolean("emit-signals", "Emit signals", "Emit new-preroll and new-sample signals", 0, rw));
    c.g_object_class_install_property(gc, PROP_MAX_BUFFERS, c.g_param_spec_uint("max-buffers", "Max Buffers", "The maximum number of buffers to queue internally (0 = unlimited)", 0, std.math.maxInt(c.guint), 0, rw));
    c.g_object_class_install_property(gc, PROP_MAX_TIME, c.g_param_spec_uint64("max-time", "Max time", "The maximum total duration to queue internally (in ns, 0 = unlimited)", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_MAX_BYTES, c.g_param_spec_uint64("max-bytes", "Max bytes", "The maximum amount of bytes to queue internally (0 = unlimited)", 0, umax, 0, rw));
    c.g_object_class_install_property(gc, PROP_DROP, c.g_param_spec_boolean("drop", "Drop", "Drop old buffers when the buffer queue is filled", 0, c.G_PARAM_DEPRECATED | rw));
    c.g_object_class_install_property(gc, PROP_BUFFER_LIST, c.g_param_spec_boolean("buffer-list", "Buffer List", "Use buffer lists", 0, rw));
    c.g_object_class_install_property(gc, PROP_WAIT_ON_EOS, c.g_param_spec_boolean("wait-on-eos", "Wait on EOS", "Wait for all buffers to be processed after receiving an EOS", 1, rw));
    c.g_object_class_install_property(gc, PROP_CURRENT_LEVEL_BYTES, c.g_param_spec_uint64("current-level-bytes", "Current Level Bytes", "The number of currently queued bytes", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_CURRENT_LEVEL_BUFFERS, c.g_param_spec_uint64("current-level-buffers", "Current Level Buffers", "The number of currently queued buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_CURRENT_LEVEL_TIME, c.g_param_spec_uint64("current-level-time", "Current Level Time", "The amount of currently queued time", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_LEAKY_TYPE, c.g_param_spec_enum("leaky-type", "Leaky Type", "Whether to drop buffers once the internal queue is full", enums.gst_app_leaky_type_get_type(), c.GST_APP_LEAKY_TYPE_NONE, rw | c.GST_PARAM_MUTABLE_PLAYING));
    c.g_object_class_install_property(gc, PROP_IN, c.g_param_spec_uint64("in", "In", "Number of input buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_OUT, c.g_param_spec_uint64("out", "Out", "Number of output buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_DROPPED, c.g_param_spec_uint64("dropped", "Dropped", "Number of dropped buffers", 0, umax, 0, ro));
    c.g_object_class_install_property(gc, PROP_SILENT, c.g_param_spec_boolean("silent", "silent", "Don't emit notify for dropped buffers", 1, rw | c.GST_PARAM_MUTABLE_PLAYING));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    const last = c.G_SIGNAL_RUN_LAST;
    const action = c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION;
    const flow = c.gst_flow_return_get_type();
    signals[SIG_EOS] = c.g_signal_new("eos", t, last, @offsetOf(Class, "eos"), null, null, null, T_NONE, @as(c.guint, 0), T_NONE);
    signals[SIG_NEW_PREROLL] = c.g_signal_new("new-preroll", t, last, @offsetOf(Class, "new_preroll"), null, null, null, flow, @as(c.guint, 0), T_NONE);
    signals[SIG_NEW_SAMPLE] = c.g_signal_new("new-sample", t, last, @offsetOf(Class, "new_sample"), null, null, null, flow, @as(c.guint, 0), T_NONE);
    signals[SIG_PROPOSE_ALLOCATION] = c.g_signal_new("propose-allocation", t, last, 0, null, null, null, T_BOOLEAN, @as(c.guint, 1), c._gst_query_type | STATIC_SCOPE);
    signals[SIG_NEW_SERIALIZED_EVENT] = c.g_signal_new("new-serialized-event", t, last, 0, null, null, null, T_BOOLEAN, @as(c.guint, 0), T_NONE);
    signals[SIG_PULL_PREROLL] = c.g_signal_new("pull-preroll", t, action, @offsetOf(Class, "pull_preroll"), null, null, null, c._gst_sample_type, @as(c.guint, 0), T_NONE);
    signals[SIG_PULL_SAMPLE] = c.g_signal_new("pull-sample", t, action, @offsetOf(Class, "pull_sample"), null, null, null, c._gst_sample_type, @as(c.guint, 0), T_NONE);
    signals[SIG_TRY_PULL_PREROLL] = c.g_signal_new("try-pull-preroll", t, action, @offsetOf(Class, "try_pull_preroll"), null, null, null, c._gst_sample_type, @as(c.guint, 1), T_UINT64);
    signals[SIG_TRY_PULL_SAMPLE] = c.g_signal_new("try-pull-sample", t, action, @offsetOf(Class, "try_pull_sample"), null, null, null, c._gst_sample_type, @as(c.guint, 1), T_UINT64);
    signals[SIG_TRY_PULL_OBJECT] = c.g_signal_new("try-pull-object", t, action, @offsetOf(Class, "try_pull_object"), null, null, null, c.gst_mini_object_get_type(), @as(c.guint, 1), T_UINT64);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "AppSink", "Generic/Sink", "Allow the application to get access to raw buffer", "David Schleef <ds@schleef.org>, Wim Taymans <wim.taymans@gmail.com>");
    c.gst_element_class_add_static_pad_template(ec, &templ);
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.unlock = unlockStart;
    bc.unlock_stop = unlockStop;
    bc.start = start;
    bc.stop = stop;
    bc.event = event;
    bc.preroll = preroll;
    bc.render = render;
    bc.render_list = renderList;
    bc.get_caps = getCaps;
    bc.set_caps = setCaps;
    bc.query = query;
    bc.propose_allocation = proposeAllocation;
    const ac: *Class = @ptrCast(@alignCast(k));
    ac.pull_preroll = pullPrerollAction;
    ac.pull_sample = pullSampleAction;
    ac.try_pull_preroll = tryPullPrerollAction;
    ac.try_pull_sample = tryPullSampleAction;
    ac.try_pull_object = tryPullObjectAction;
}

fn init(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: [*c]Sink = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    s[0].priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
    const r = priv(s);
    c.g_mutex_init(&r.mutex);
    c.g_cond_init(&r.cond);
    r.queue = c.gst_vec_deque_new(16);
    r.sample = c.gst_sample_new(null, null, null, null);
    r.emit_signals = false;
    r.max_buffers = 0;
    r.max_bytes = 0;
    r.max_time = 0;
    r.wait_on_eos = true;
    r.buffer_lists_supported = false;
    r.wait_status = 0;
    r.leaky_type = c.GST_APP_LEAKY_TYPE_NONE;
    r.silent = true;
}

pub export fn gst_app_sink_get_type() c.GType {
    return once.get(struct {
        var iface = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
        fn f() c.GType {
            const t = gtype.object(c.gst_base_sink_get_type, "GstAppSink", Class, Sink, classInit, init, 0);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &iface);
            return t;
        }
    }.f);
}
