const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstinputselector.c";
const NONE = cm.CLOCK_NONE;

const PROP_N_PADS = 1;
const PROP_ACTIVE_PAD = 2;
const PROP_SYNC_STREAMS = 3;
const PROP_SYNC_MODE = 4;
const PROP_CACHE_BUFFERS = 5;
const PROP_DROP_BACKWARDS = 6;

const PAD_RUNNING_TIME = 1;
const PAD_TAGS = 2;
const PAD_ACTIVE = 3;
const PAD_ALWAYS_OK = 4;

const SYNC_ACTIVE_SEGMENT = 0;
const SYNC_CLOCK = 1;

const Self = extern struct {
    parent: c.GstElement,
    srcpad: ?*c.GstPad,
    active_lock: c.GRWLock,
    active_sinkpad: ?*c.GstPad,
    active_from_user: c.gboolean,
    pending_active: ?*c.GstPad,
    n_pads: c.guint,
    padcount: c.guint,
    sync_streams: c.gboolean,
    sync_mode: c.gint,
    cache_buffers: c.gboolean,
    drop_backwards: c.gboolean,
    have_group_id: c.gboolean,
    lock: c.GMutex,
    cond: c.GCond,
    eos: c.gboolean,
    eos_sent: c.gboolean,
    flushing: c.gboolean,
    playing: c.gboolean,
    upstream_latency: u64,
    last_output_ts: u64,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

const SelPad = extern struct {
    parent: cm.Pad,
    pushed: c.gboolean,
    group_id: c.guint,
    group_done: c.gboolean,
    eos: c.gboolean,
    eos_sent: c.gboolean,
    discont: c.gboolean,
    flushing: c.gboolean,
    being_released: c.gboolean,
    always_ok: c.gboolean,
    tags: ?*c.GstTagList,
    segment: c.GstSegment,
    segment_seqnum: u32,
    events_pending: c.gboolean,
    sending_cached: c.gboolean,
    cached: [*c]c.GQueue,
    clock_id: c.GstClockID,
};

const Cached = struct {
    buffer: [*c]c.GstBuffer,
    segment: c.GstSegment,
};

var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var mode_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var pad_parent: ?*c.GObjectClass = null;

var modes = [_]c.GEnumValue{
    .{ .value = SYNC_ACTIVE_SEGMENT, .value_name = "Sync using the current active segment", .value_nick = "active-segment" },
    .{ .value = SYNC_CLOCK, .value_name = "Sync using the clock", .value_nick = "clock" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn modeType() c.GType {
    return mode_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstInputSelectorSyncMode", &modes);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn sp(p: anytype) *SelPad {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn same(a: anytype, b: anytype) bool {
    return @as(?*anyopaque, @ptrCast(a)) == @as(?*anyopaque, @ptrCast(b));
}

fn ref(p: anytype) ?*c.GstPad {
    return @ptrCast(@alignCast(c.gst_object_ref(p)));
}

fn clear(p: *?*c.GstPad) void {
    if (p.*) |x| c.gst_object_unref(x);
    p.* = null;
}

fn lockS(s: *Self) void {
    c.g_mutex_lock(&s.lock);
}

fn unlockS(s: *Self) void {
    c.g_mutex_unlock(&s.lock);
}

fn broadcast(s: *Self) void {
    c.g_cond_broadcast(&s.cond);
}

fn readLock(s: *Self) void {
    c.g_rw_lock_reader_lock(&s.active_lock);
}

fn readUnlock(s: *Self) void {
    c.g_rw_lock_reader_unlock(&s.active_lock);
}

fn waitCond(s: *Self) void {
    readUnlock(s);
    c.g_cond_wait(&s.cond, &s.lock);
    unlockS(s);
    readLock(s);
    lockS(s);
    commit(s);
}

fn freeCached(p: c.gpointer) callconv(.c) void {
    const cb: *Cached = @ptrCast(@alignCast(p));
    if (cb.buffer != null) c.gst_buffer_unref(cb.buffer);
    std.heap.c_allocator.destroy(cb);
}

fn freeAllCached(p: *SelPad) void {
    if (p.cached == null) return;
    c.g_queue_free_full(p.cached, freeCached);
    p.cached = null;
}

fn padReset(p: *SelPad) void {
    cm.lock(p);
    p.pushed = 0;
    p.group_done = 0;
    p.eos = 0;
    p.eos_sent = 0;
    p.events_pending = 0;
    p.discont = 0;
    p.flushing = 0;
    p.being_released = 0;
    c.gst_segment_init(&p.segment, c.GST_FORMAT_UNDEFINED);
    p.sending_cached = 0;
    freeAllCached(p);
    if (p.clock_id != null) {
        c.gst_clock_id_unschedule(p.clock_id);
        c.gst_clock_id_unref(p.clock_id);
    }
    p.clock_id = null;
    cm.unlock(p);
}

fn runningTime(p: *SelPad) i64 {
    cm.lock(p);
    defer cm.unlock(p);
    if (p.segment.format != c.GST_FORMAT_TIME) return 0;
    return @bitCast(c.gst_segment_to_running_time(&p.segment, p.segment.format, p.segment.position));
}

fn isActive(s: *Self, p: ?*c.GstPad) bool {
    readLock(s);
    defer readUnlock(s);
    return p == s.active_sinkpad;
}

fn padGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = sp(o);
    switch (id) {
        PAD_RUNNING_TIME => c.g_value_set_int64(v, runningTime(p)),
        PAD_TAGS => {
            cm.lock(p);
            c.g_value_set_boxed(v, p.tags);
            cm.unlock(p);
        },
        PAD_ACTIVE => {
            const par = c.gst_object_get_parent(cm.obj(p));
            if (par != null) {
                c.g_value_set_boolean(v, @intFromBool(isActive(me(par), @ptrCast(@alignCast(p)))));
                c.gst_object_unref(par);
            } else c.g_value_set_boolean(v, 0);
        },
        PAD_ALWAYS_OK => {
            cm.lock(p);
            c.g_value_set_boolean(v, p.always_ok);
            cm.unlock(p);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 315),
    }
}

fn padSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = sp(o);
    switch (id) {
        PAD_ALWAYS_OK => {
            cm.lock(p);
            p.always_ok = c.g_value_get_boolean(v);
            cm.unlock(p);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 275),
    }
}

fn padFinalize(o: [*c]c.GObject) callconv(.c) void {
    const p = sp(o);
    if (p.tags) |t| c.gst_mini_object_unref(@ptrCast(t));
    freeAllCached(p);
    pad_parent.?.finalize.?(o);
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = padFinalize;
    oc.get_property = padGet;
    oc.set_property = padSet;
    c.g_object_class_install_property(oc, PAD_RUNNING_TIME, c.g_param_spec_int64("running-time", "Running time", "Running time of stream on pad", 0, std.math.maxInt(i64), 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PAD_TAGS, c.g_param_spec_boxed("tags", "Tags", "The currently active tags on the pad", c.gst_tag_list_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PAD_ACTIVE, c.g_param_spec_boolean("active", "Active", "If the pad is currently active", 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PAD_ALWAYS_OK, c.g_param_spec_boolean("always-ok", "Always OK", "Make an inactive pad return OK instead of NOT_LINKED", 1, cm.RW));
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    sp(inst).always_ok = 1;
    padReset(sp(inst));
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_pad_get_type(), c.g_intern_static_string("GstSelectorPad"), @sizeOf(c.GstPadClass), padClassInit, @sizeOf(SelPad), padInit, 0);
        }
    }.f);
}

fn cacheBuffer(p: *SelPad, b: [*c]c.GstBuffer) void {
    if (p.segment.format != c.GST_FORMAT_TIME) {
        c.gst_buffer_unref(b);
        return;
    }
    if (p.cached == null) p.cached = c.g_queue_new();
    const cb = std.heap.c_allocator.create(Cached) catch return;
    cb.* = .{ .buffer = b, .segment = p.segment };
    c.g_queue_push_tail(p.cached, cb);
}

fn linkedPad(s: *Self, pad: ?*c.GstPad, strict: bool) ?*c.GstPad {
    readLock(s);
    defer readUnlock(s);
    var other: ?*c.GstPad = null;
    if (pad == s.srcpad) {
        other = s.active_sinkpad;
    } else if (pad == s.active_sinkpad or !strict) other = s.srcpad;
    return if (other) |o| ref(o) else null;
}

fn iterateLinked(pad: ?*c.GstPad, par: [*c]c.GstObject) callconv(.c) [*c]c.GstIterator {
    const other = linkedPad(me(par), pad, true) orelse return null;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_pad_get_type());
    c.g_value_set_object(&v, other);
    const it = c.gst_iterator_new_single(c.gst_pad_get_type(), &v);
    c.g_value_unset(&v);
    c.gst_object_unref(other);
    return it;
}

fn storeSticky(pad: ?*c.GstPad, ev: [*c][*c]c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const t = cm.eventType(ev[0]);
    if (t == c.GST_EVENT_SEGMENT) {
        const e = c.gst_event_new_segment(&sp(pad).segment);
        c.gst_event_set_seqnum(e, sp(pad).segment_seqnum);
        _ = c.gst_pad_store_sticky_event(s.srcpad, e);
        c.gst_mini_object_unref(@ptrCast(e));
    } else if (t == c.GST_EVENT_STREAM_START and s.have_group_id == 0) {
        const tmp = c.gst_pad_get_sticky_event(s.srcpad, c.GST_EVENT_STREAM_START, 0);
        if (tmp == null) {
            _ = c.gst_pad_store_sticky_event(s.srcpad, ev[0]);
        } else c.gst_mini_object_unref(@ptrCast(tmp));
    } else _ = c.gst_pad_store_sticky_event(s.srcpad, ev[0]);
    return 1;
}

fn flushPending(s: *Self, p: *SelPad) void {
    c.gst_pad_sticky_events_foreach(@ptrCast(@alignCast(p)), storeSticky, s);
    p.events_pending = 0;
}

fn eosWait(s: *Self, p: *SelPad, ev: [*c]c.GstEvent) void {
    while (s.eos == 0 and s.flushing == 0 and p.flushing == 0 and p.being_released == 0) {
        if (same(p, s.active_sinkpad) and p.eos != 0 and p.eos_sent == 0) {
            if (p.events_pending != 0) flushPending(s, p);
            unlockS(s);
            _ = c.gst_pad_push_event(s.srcpad, @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev)))));
            lockS(s);
            if (p.clock_id != null) c.gst_clock_id_unschedule(p.clock_id);
            broadcast(s);
            p.eos_sent = 1;
        } else waitCond(s);
    }
}

fn allEos(s: *Self) bool {
    cm.lock(s);
    defer cm.unlock(s);
    var l = element(s)[0].sinkpads;
    while (l != null) : (l = l[0].next) {
        const p = sp(l[0].data);
        if (p.eos == 0 and p.being_released == 0) return false;
    }
    return true;
}

fn padEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    const p = sp(pad);
    var res: c.gboolean = 1;
    var new_tags = false;
    readLock(s);
    lockS(s);
    commit(s);
    var forward = pad == s.active_sinkpad;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_STREAM_START => if (c.gst_event_parse_group_id(ev, &p.group_id) == 0) {
            s.have_group_id = 0;
            p.group_id = 0;
        },
        c.GST_EVENT_FLUSH_START => {
            p.flushing = 1;
            s.eos = 0;
            p.group_done = 0;
            if (p.clock_id != null) c.gst_clock_id_unschedule(p.clock_id);
            broadcast(s);
        },
        c.GST_EVENT_FLUSH_STOP => {
            padReset(p);
            s.last_output_ts = NONE;
        },
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(ev, &p.segment);
            p.segment_seqnum = c.gst_event_get_seqnum(ev);
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(ev, &tags);
            cm.lock(p);
            const old = p.tags;
            p.tags = c.gst_tag_list_merge(old, tags, c.GST_TAG_MERGE_REPLACE);
            cm.unlock(p);
            if (old) |o| c.gst_mini_object_unref(@ptrCast(o));
            new_tags = true;
        },
        c.GST_EVENT_EOS => {
            p.eos = 1;
            if (allEos(s)) {
                s.eos = 1;
                broadcast(s);
            } else {
                eosWait(s, p, ev);
                forward = false;
            }
        },
        c.GST_EVENT_GAP => {
            var ts: u64 = 0;
            var dur: u64 = 0;
            c.gst_event_parse_gap(ev, &ts, &dur);
            if (ts != NONE) {
                if (dur != NONE) ts +%= dur;
                cm.lock(pad);
                p.segment.position = ts;
                cm.unlock(pad);
                if (s.sync_streams != 0 and s.active_sinkpad == pad) broadcast(s);
            }
        },
        c.GST_EVENT_STREAM_GROUP_DONE => {
            c.gst_event_parse_stream_group_done(ev, &p.group_id);
            p.group_done = 1;
            if (s.sync_streams != 0 and s.active_sinkpad == pad) broadcast(s);
        },
        else => {},
    }
    if (forward and p.events_pending != 0) flushPending(s, p);
    unlockS(s);
    if (new_tags) c.g_object_notify(@ptrCast(@alignCast(p)), "tags");
    if (forward) {
        res = c.gst_pad_push_event(s.srcpad, ev);
    } else {
        if (cm.eventSticky(ev)) p.events_pending = 1;
        c.gst_mini_object_unref(@ptrCast(ev));
    }
    readUnlock(s);
    return res;
}

fn padQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.queryType(q)) {
        c.GST_QUERY_CAPS, c.GST_QUERY_POSITION, c.GST_QUERY_DURATION, c.GST_QUERY_CONTEXT => return c.gst_pad_peer_query(s.srcpad, q),
        c.GST_QUERY_ALLOCATION => if (cm.pad(pad).direction == c.GST_PAD_SINK and !isActive(s, pad)) return 0,
        else => {},
    }
    return c.gst_pad_query_default(pad, par, q);
}

fn clippedRunning(seg: *const c.GstSegment, b: [*c]c.GstBuffer) u64 {
    var t = cm.buf(b).pts;
    if (cm.buf(b).duration != NONE) t +%= cm.buf(b).duration;
    if (seg.stop != NONE and t > seg.stop) t = seg.stop;
    return c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, t);
}

fn clockWait(s: *Self, p: *SelPad, running: u64) enum { retry, done, again } {
    if (s.playing == 0) {
        waitCond(s);
        return .retry;
    }
    const base = c.gst_element_get_base_time(element(s));
    if (base == NONE) {
        waitCond(s);
        return .retry;
    }
    const clock = c.gst_element_get_clock(element(s));
    if (clock == null) {
        waitCond(s);
        return .retry;
    }
    const id = c.gst_clock_new_single_shot_id(clock, running +% base +% s.upstream_latency);
    p.clock_id = c.gst_clock_id_ref(id);
    unlockS(s);
    readUnlock(s);
    c.gst_object_unref(clock);
    var jitter: c.GstClockTimeDiff = 0;
    const r = c.gst_clock_id_wait(id, &jitter);
    c.gst_clock_id_unref(id);
    readLock(s);
    lockS(s);
    if (p.clock_id != null) {
        c.gst_clock_id_unref(p.clock_id);
        p.clock_id = null;
    }
    if (r == c.GST_CLOCK_OK or r == c.GST_CLOCK_EARLY or r == c.GST_CLOCK_DONE) return .done;
    return .again;
}

fn waitRunning(s: *Self, p: *SelPad, b: [*c]c.GstBuffer) bool {
    if (cm.buf(b).pts == NONE) return false;
    const seg = &p.segment;
    lockS(s);
    while (true) {
        const active_pad = s.active_sinkpad orelse {
            unlockS(s);
            break;
        };
        const act = sp(active_pad);
        if (seg.format != c.GST_FORMAT_TIME) {
            unlockS(s);
            return false;
        }
        const running = clippedRunning(seg, b);
        if (running == NONE) {
            unlockS(s);
            return false;
        }
        var cur: u64 = NONE;
        if (s.sync_mode != SYNC_CLOCK) {
            const aseg = &act.segment;
            if (aseg.format != c.GST_FORMAT_TIME and aseg.format != c.GST_FORMAT_UNDEFINED) {
                unlockS(s);
                return false;
            }
            if (aseg.format == c.GST_FORMAT_TIME) cur = c.gst_segment_to_running_time(aseg, c.GST_FORMAT_TIME, aseg.position);
        }
        if (p != act and act.group_done != 0 and p.group_id == act.group_id) {
            unlockS(s);
            break;
        }
        if (p == act or s.eos != 0 or s.flushing != 0 or p.flushing != 0 or p.being_released != 0) {
            unlockS(s);
            break;
        }
        if (s.sync_mode == SYNC_CLOCK and running != NONE) {
            switch (clockWait(s, p, running)) {
                .retry, .again => continue,
                .done => {
                    unlockS(s);
                    break;
                },
            }
        } else if (act.eos == 0 and (cur == NONE or running >= cur)) {
            waitCond(s);
        } else {
            unlockS(s);
            break;
        }
    }
    return s.flushing != 0 or p.flushing != 0 or p.being_released != 0;
}

fn cleanupCached(s: *Self) void {
    var cur: u64 = NONE;
    if (s.sync_mode == SYNC_CLOCK) {
        const clock = c.gst_element_get_clock(element(s));
        if (clock != null) {
            cur = c.gst_clock_get_time(clock);
            const base = c.gst_element_get_base_time(element(s));
            cur = if (base <= cur) cur - base else 0;
            c.gst_object_unref(clock);
        }
    } else {
        const aseg = &sp(s.active_sinkpad).segment;
        if (aseg.format == c.GST_FORMAT_TIME) cur = c.gst_segment_to_running_time(aseg, c.GST_FORMAT_TIME, aseg.position);
    }
    if (cur == NONE) return;
    cm.lock(s);
    var w = element(s)[0].sinkpads;
    while (w != null) : (w = w[0].next) {
        const p = sp(w[0].data);
        if (p.cached == null) continue;
        var maybe: [*c]c.GSList = null;
        var pos: c.guint = 0;
        while (true) {
            const cbp = c.g_queue_peek_nth(p.cached, pos);
            if (cbp == null) break;
            const cb: *Cached = @ptrCast(@alignCast(cbp));
            if (cm.buf(cb.buffer).pts == NONE) {
                maybe = c.g_slist_append(maybe, cb);
                pos = c.g_slist_length(maybe);
                continue;
            }
            if (clippedRunning(&cb.segment, cb.buffer) >= cur) break;
            _ = c.g_queue_pop_nth(p.cached, pos);
            freeCached(cb);
            var l = maybe;
            while (l != null) : (l = l[0].next) {
                _ = c.g_queue_remove(p.cached, l[0].data);
                freeCached(l[0].data);
            }
            c.g_slist_free(maybe);
            maybe = null;
            pos = 0;
        }
        c.g_slist_free(maybe);
        if (c.g_queue_is_empty(p.cached) != 0) {
            c.g_queue_free(p.cached);
            p.cached = null;
        }
    }
    cm.unlock(s);
}

fn replayCached(s: *Self, pad: ?*c.GstPad, par: [*c]c.GstObject, p: *SelPad) void {
    const saved = p.segment;
    p.sending_cached = 1;
    while (s.eos == 0 and s.flushing == 0 and p.flushing == 0 and p.being_released == 0) {
        const cbp = c.g_queue_pop_head(p.cached);
        if (cbp == null) break;
        const cb: *Cached = @ptrCast(@alignCast(cbp));
        p.segment = cb.segment;
        p.events_pending = 1;
        unlockS(s);
        readUnlock(s);
        _ = chain(pad, par, cb.buffer);
        readLock(s);
        lockS(s);
        cb.buffer = null;
        freeCached(cb);
        if (p.cached == null) break;
    }
    p.sending_cached = 0;
    p.segment = saved;
    p.events_pending = 1;
    commit(s);
}

fn ignore(s: *Self, p: *SelPad, b: [*c]c.GstBuffer) c.GstFlowReturn {
    const pushed = if (s.active_sinkpad) |a| sp(a).pushed != 0 else false;
    p.discont = 1;
    unlockS(s);
    c.gst_buffer_unref(b);
    cm.lock(p);
    defer cm.unlock(p);
    return if (p.always_ok != 0 or !pushed) c.GST_FLOW_OK else c.GST_FLOW_NOT_LINKED;
}

fn chain(pad: ?*c.GstPad, par: [*c]c.GstObject, b_in: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    const p = sp(pad);
    var b = b_in;
    readLock(s);
    defer readUnlock(s);
    lockS(s);
    commit(s);
    if (s.flushing != 0 or p.being_released != 0) {
        unlockS(s);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_FLUSHING;
    }
    if (s.sync_streams != 0) {
        if ((s.active_sinkpad != pad or p.pushed == 0) and p.cached != null and p.sending_cached == 0) replayCached(s, pad, par, p);
        if (s.active_sinkpad != pad) {
            unlockS(s);
            if (waitRunning(s, p, b)) {
                c.gst_buffer_unref(b);
                return c.GST_FLOW_FLUSHING;
            }
            lockS(s);
        }
    }
    if (cm.buf(b).pts != NONE) {
        cm.lock(pad);
        p.segment.position = cm.buf(b).pts;
        cm.unlock(pad);
    }
    if (pad != s.active_sinkpad) return ignore(s, p, b);
    if (s.sync_streams != 0) broadcast(s);
    if (p.events_pending != 0) flushPending(s, p);
    const seg = p.segment;
    var running: u64 = NONE;
    if (seg.format == c.GST_FORMAT_TIME) running = c.gst_segment_to_running_time(&seg, c.GST_FORMAT_TIME, cm.dtsOrPts(b));
    if (p.discont != 0) {
        if (s.sync_streams != 0 and s.drop_backwards != 0 and running != NONE and running < s.last_output_ts and s.last_output_ts != NONE) return ignore(s, p, b);
        b = c.gst_buffer_make_writable(b);
        cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        p.discont = 0;
    }
    s.last_output_ts = running;
    const keep = s.sync_streams != 0 and s.cache_buffers != 0;
    if (keep) b = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(b))));
    unlockS(s);
    const r = c.gst_pad_push(s.srcpad, b);
    lockS(s);
    if (keep) {
        cacheBuffer(p, b);
        cleanupCached(s);
    }
    p.pushed = 1;
    unlockS(s);
    return r;
}

fn setActive(s: *Self, pad: ?*c.GstPad) bool {
    if (pad) |x| {
        if (!thatVal(cm.pad(x).direction == c.GST_PAD_SINK, "GST_PAD_IS_SINK (pad)")) return false;
        if (!thatVal(cm.isA(@as(?*c.GstPad, x), padType()), "GST_IS_SELECTOR_PAD (pad)")) return false;
        if (!thatVal(same(cm.padParent(x), s), "GST_PAD_PARENT (pad) == GST_ELEMENT_CAST (sel)")) return false;
    }
    lockS(s);
    defer unlockS(s);
    if (pad == s.pending_active) return false;
    s.active_from_user = @intFromBool(pad != null);
    _ = c.gst_object_replace(@ptrCast(&s.pending_active), @ptrCast(@alignCast(pad)));
    broadcast(s);
    return true;
}

fn thatVal(ok: bool, comptime expr: []const u8) bool {
    if (!ok) c.g_return_if_fail_warning(null, "gst_input_selector_set_active_pad", (expr ++ "").ptr);
    return ok;
}

fn pickDefault(s: *Self) void {
    const it = c.gst_element_iterate_sink_pads(element(s));
    var item = std.mem.zeroes(c.GValue);
    while (s.pending_active == null) {
        var r = c.gst_iterator_next(it, &item);
        while (r == c.GST_ITERATOR_RESYNC) {
            c.gst_iterator_resync(it);
            r = c.gst_iterator_next(it, &item);
        }
        if (r != c.GST_ITERATOR_OK) break;
        const p: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_dup_object(&item)));
        _ = c.g_value_reset(&item);
        if (sp(p).being_released == 0) {
            s.pending_active = p;
        } else c.gst_object_unref(p);
    }
    c.gst_iterator_free(it);
}

fn relock(s: *Self) void {
    unlockS(s);
    c.g_rw_lock_writer_unlock(&s.active_lock);
    readLock(s);
    lockS(s);
}

fn commit(s: *Self) void {
    if (s.pending_active == null) {
        if (s.active_sinkpad != null) return;
    } else if (s.pending_active == s.active_sinkpad) {
        clear(&s.pending_active);
        return;
    }
    unlockS(s);
    readUnlock(s);
    c.g_rw_lock_writer_lock(&s.active_lock);
    lockS(s);
    if (s.pending_active == null) {
        if (s.active_sinkpad != null) return relock(s);
        pickDefault(s);
        if (s.pending_active == null) return relock(s);
    } else if (s.pending_active == s.active_sinkpad) {
        clear(&s.pending_active);
        return relock(s);
    }
    const old: ?*SelPad = if (s.active_sinkpad) |a| sp(a) else null;
    const new = sp(s.pending_active);
    if (old == new) c.g_assertion_message_expr(null, FILE, 1638, "gst_input_selector_maybe_commit_active_pad", "old != new");
    if (old) |o| o.pushed = 0;
    _ = c.gst_object_ref(new);
    new.pushed = 0;
    new.events_pending = 1;
    if (old) |o| _ = c.gst_pad_push_event(@ptrCast(@alignCast(o)), c.gst_event_new_reconfigure());
    _ = c.gst_pad_push_event(@ptrCast(@alignCast(new)), c.gst_event_new_reconfigure());
    s.active_sinkpad = s.pending_active;
    s.pending_active = null;
    if (new.eos != 0) {
        new.eos_sent = 0;
        broadcast(s);
    }
    unlockS(s);
    c.g_rw_lock_writer_unlock(&s.active_lock);
    if (old) |o| {
        c.g_object_notify(@ptrCast(@alignCast(o)), "active");
        c.gst_object_unref(o);
    }
    c.g_object_notify(@ptrCast(@alignCast(new)), "active");
    c.g_object_notify(@ptrCast(@alignCast(s)), "active-pad");
    c.gst_object_unref(new);
    readLock(s);
    lockS(s);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_ACTIVE_PAD => _ = setActive(s, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_SYNC_STREAMS, PROP_SYNC_MODE, PROP_CACHE_BUFFERS, PROP_DROP_BACKWARDS => {
            lockS(s);
            switch (id) {
                PROP_SYNC_STREAMS => s.sync_streams = c.g_value_get_boolean(v),
                PROP_SYNC_MODE => s.sync_mode = c.g_value_get_enum(v),
                PROP_CACHE_BUFFERS => s.cache_buffers = c.g_value_get_boolean(v),
                else => s.drop_backwards = c.g_value_get_boolean(v),
            }
            unlockS(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1729),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_ACTIVE_PAD => {
            readLock(s);
            c.g_value_set_object(v, s.active_sinkpad);
            readUnlock(s);
        },
        PROP_N_PADS, PROP_SYNC_STREAMS, PROP_SYNC_MODE, PROP_CACHE_BUFFERS, PROP_DROP_BACKWARDS => {
            lockS(s);
            switch (id) {
                PROP_N_PADS => c.g_value_set_uint(v, s.n_pads),
                PROP_SYNC_STREAMS => c.g_value_set_boolean(v, s.sync_streams),
                PROP_SYNC_MODE => c.g_value_set_enum(v, s.sync_mode),
                PROP_CACHE_BUFFERS => c.g_value_set_boolean(v, s.cache_buffers),
                else => c.g_value_set_boolean(v, s.drop_backwards),
            }
            unlockS(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1782),
    }
}

fn activeChanged(o: ?*c.GObject, _: ?*c.GParamSpec, _: c.gpointer) callconv(.c) void {
    const s = me(o);
    if (s.sync_streams != 0) broadcast(s);
}

fn srcEvent(_: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    var result: c.gboolean = 0;
    var pushed: [*c]c.GList = null;
    const it = c.gst_element_iterate_sink_pads(element(s));
    readLock(s);
    lockS(s);
    const t: c.guint = @bitCast(cm.eventType(ev));
    if (t & c.GST_EVENT_TYPE_SERIALIZED != 0 and t & c.GST_EVENT_TYPE_DOWNSTREAM != 0) commit(s);
    if (s.active_sinkpad) |a| {
        const ep = ref(a);
        unlockS(s);
        result |= c.gst_pad_push_event(ep, @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev)))));
        pushed = c.g_list_append(pushed, ep);
        c.gst_object_unref(ep);
    } else unlockS(s);
    readUnlock(s);
    var item = std.mem.zeroes(c.GValue);
    var done = false;
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                const ep = c.g_value_get_object(&item);
                if (c.g_list_find(pushed, ep) == null) {
                    result |= c.gst_pad_push_event(@ptrCast(@alignCast(ep)), @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev)))));
                    pushed = c.g_list_append(pushed, ep);
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => done = true,
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    c.g_list_free(pushed);
    c.gst_mini_object_unref(@ptrCast(ev));
    return result;
}

const Fold = struct {
    live: bool = false,
    min: u64 = 0,
    max: u64 = NONE,
};

fn foldLatency(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(item)));
    const f: *Fold = @ptrCast(@alignCast(data));
    const q = c.gst_query_new_latency();
    const peer = c.gst_pad_get_peer(pad);
    const res = peer != null and c.gst_pad_peer_query(pad, q) != 0;
    if (res) {
        var live: c.gboolean = 0;
        var min: u64 = 0;
        var max: u64 = 0;
        c.gst_query_parse_latency(q, &live, &min, &max);
        if (live != 0) {
            if (min > f.min) f.min = min;
            if (f.max == NONE) {
                f.max = max;
            } else if (max < f.max) f.max = max;
            f.live = true;
        }
    } else if (peer != null) c.g_value_set_boolean(ret, 0);
    c.gst_mini_object_unref(@ptrCast(q));
    if (peer) |x| c.gst_object_unref(x);
    return 1;
}

fn queryLatency(s: *Self, q: [*c]c.GstQuery) c.gboolean {
    const it = c.gst_element_iterate_sink_pads(element(s));
    if (it == null) return 0;
    var ret = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&ret, c.G_TYPE_BOOLEAN);
    var f: Fold = .{};
    while (true) {
        f = .{};
        c.g_value_set_boolean(&ret, 1);
        const r = c.gst_iterator_fold(it, foldLatency, &ret, &f);
        if (r == c.GST_ITERATOR_RESYNC) {
            c.gst_iterator_resync(it);
            continue;
        }
        if (r == c.GST_ITERATOR_ERROR) c.g_value_set_boolean(&ret, 0);
        if (r == c.GST_ITERATOR_OK) c.g_assertion_message_expr(null, FILE, 1972, "gst_input_selector_query_latency", null);
        break;
    }
    c.gst_iterator_free(it);
    const ok = c.g_value_get_boolean(&ret);
    if (ok != 0) {
        lockS(s);
        s.upstream_latency = if (f.live) f.min else 0;
        c.gst_query_set_latency(q, @intFromBool(f.live or s.sync_mode == SYNC_CLOCK), f.min, f.max);
        unlockS(s);
    }
    return ok;
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.queryType(q) == c.GST_QUERY_LATENCY) return queryLatency(me(par), q);
    return c.gst_pad_query_default(pad, par, q);
}

fn requestPad(el: [*c]c.GstElement, tmpl: [*c]c.GstPadTemplate, _: [*c]const u8, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    if (tmpl[0].direction != c.GST_PAD_SINK) {
        c.g_return_if_fail_warning(null, "gst_input_selector_request_new_pad", "templ->direction == GST_PAD_SINK");
        return null;
    }
    const s = me(el);
    lockS(s);
    const name = c.g_strdup_printf("sink_%u", s.padcount);
    s.padcount += 1;
    const p: ?*c.GstPad = @ptrCast(@alignCast(c.g_object_new(padType(), "name", name, "direction", tmpl[0].direction, "template", tmpl, @as(?*anyopaque, null))));
    c.g_free(name);
    s.n_pads += 1;
    c.gst_pad_set_event_function_full(p, padEvent, null, null);
    c.gst_pad_set_query_function_full(p, padQuery, null, null);
    c.gst_pad_set_chain_function_full(p, chain, null, null);
    c.gst_pad_set_iterate_internal_links_function_full(p, iterateLinked, null, null);
    cm.setPadFlag(p, c.GST_PAD_FLAG_PROXY_CAPS | c.GST_PAD_FLAG_PROXY_ALLOCATION);
    unlockS(s);
    _ = c.gst_element_add_pad(el, p);
    return p;
}

fn releasePad(el: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(el);
    c.g_rw_lock_writer_lock(&s.active_lock);
    lockS(s);
    if (s.pending_active == pad) clear(&s.pending_active);
    if (s.active_sinkpad == pad) {
        clear(&s.active_sinkpad);
        s.active_from_user = 0;
    }
    sp(pad).being_released = 1;
    broadcast(s);
    s.n_pads -= 1;
    unlockS(s);
    c.g_rw_lock_writer_unlock(&s.active_lock);
    _ = c.gst_pad_set_active(pad, 0);
    _ = c.gst_element_remove_pad(el, pad);
}

fn reset(s: *Self) void {
    c.g_rw_lock_writer_lock(&s.active_lock);
    lockS(s);
    clear(&s.pending_active);
    if (s.active_sinkpad != null and s.active_from_user == 0) clear(&s.active_sinkpad);
    s.eos_sent = 0;
    cm.lock(s);
    var l = element(s)[0].sinkpads;
    while (l != null) : (l = l[0].next) {
        const p = sp(l[0].data);
        padReset(p);
        if (p.tags) |t| {
            c.gst_mini_object_unref(@ptrCast(t));
            p.tags = null;
        }
    }
    cm.unlock(s);
    s.have_group_id = 1;
    s.upstream_latency = 0;
    s.last_output_ts = NONE;
    unlockS(s);
    c.g_rw_lock_writer_unlock(&s.active_lock);
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(el);
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            lockS(s);
            s.eos = 0;
            s.flushing = 0;
            unlockS(s);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lockS(s);
            s.eos = 1;
            s.flushing = 1;
            broadcast(s);
            unlockS(s);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => {
            lockS(s);
            s.playing = 1;
            broadcast(s);
            unlockS(s);
        },
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => {
            lockS(s);
            s.playing = 0;
            broadcast(s);
            cm.lock(s);
            var l = el[0].sinkpads;
            while (l != null) : (l = l[0].next) {
                const p = sp(l[0].data);
                if (p.clock_id != null) c.gst_clock_id_unschedule(p.clock_id);
            }
            cm.unlock(s);
            unlockS(s);
        },
        else => {},
    }
    const r = parent.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) reset(s);
    return r;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    clear(&s.active_sinkpad);
    clear(&s.pending_active);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_rw_lock_clear(&s.active_lock);
    c.g_mutex_clear(&s.lock);
    c.g_cond_clear(&s.cond);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_N_PADS, c.g_param_spec_uint("n-pads", "Number of Pads", "The number of sink pads", 0, std.math.maxInt(c.guint), 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_ACTIVE_PAD, c.g_param_spec_object("active-pad", "Active pad", "The currently active sink pad", c.gst_pad_get_type(), cm.RW | cm.MUTABLE_PLAYING));
    c.g_object_class_install_property(oc, PROP_SYNC_STREAMS, c.g_param_spec_boolean("sync-streams", "Sync Streams", "Synchronize inactive streams to the running time of the active stream or to the current clock", 1, cm.RW | cm.MUTABLE_READY));
    c.g_object_class_install_property(oc, PROP_SYNC_MODE, c.g_param_spec_enum("sync-mode", "Sync mode", "Behavior in sync-streams mode", modeType(), SYNC_ACTIVE_SEGMENT, cm.RW | cm.MUTABLE_READY));
    c.g_object_class_install_property(oc, PROP_CACHE_BUFFERS, c.g_param_spec_boolean("cache-buffers", "Cache Buffers", "Cache buffers for active-pad", 0, cm.RW | cm.MUTABLE_READY));
    c.g_object_class_install_property(oc, PROP_DROP_BACKWARDS, c.g_param_spec_boolean("drop-backwards", "Drop Backwards Buffers", "Drop backwards buffers on pad switch", 0, cm.RW | cm.MUTABLE_READY));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Input selector", "Generic", "N-to-1 input stream selector", "Julien Moutte <julien@moutte.net>, Jan Schmidt <thaytan@mad.scientist.com>, Wim Taymans <wim.taymans@gmail.com>");
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &sink_t, padType());
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    ec.change_state = changeState;
    c.gst_type_mark_as_plugin_api(padType(), 0);
    c.gst_type_mark_as_plugin_api(modeType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.srcpad = c.gst_pad_new("src", c.GST_PAD_SRC);
    c.gst_pad_set_iterate_internal_links_function_full(s.srcpad, iterateLinked, null, null);
    c.gst_pad_set_event_function_full(s.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(s.srcpad, srcQuery, null, null);
    cm.setPadFlag(s.srcpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(element(s), s.srcpad);
    c.g_rw_lock_init(&s.active_lock);
    s.active_sinkpad = null;
    s.pending_active = null;
    s.active_from_user = 0;
    s.padcount = 0;
    s.sync_streams = 1;
    s.sync_mode = SYNC_ACTIVE_SEGMENT;
    s.have_group_id = 1;
    c.g_mutex_init(&s.lock);
    c.g_cond_init(&s.cond);
    s.eos = 0;
    s.playing = 0;
    s.upstream_latency = 0;
    s.last_output_ts = NONE;
    _ = c.g_signal_connect_data(s, "notify::active-pad", @ptrCast(&activeChanged), null, null, c.G_CONNECT_AFTER);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstInputSelector", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("input-selector", 0, "An input stream selector element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "input-selector", c.GST_RANK_NONE, getType()) != 0;
}
