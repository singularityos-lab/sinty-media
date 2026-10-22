const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const NONE = cm.CLOCK_NONE;
const SEC: u64 = 1_000_000_000;

const Stream = struct {
    number: c.guint,
    srcpad: ?*c.GstPad = null,
    sinkpad: ?*c.GstPad = null,
    segment: c.GstSegment = undefined,
    wait: bool = false,
    is_eos: bool = false,
    eos_sent: bool = false,
    flushing: bool = false,
    seen_data: bool = false,
    send_gap: bool = false,
    gap: u64 = 0,
    flags: c.GstStreamFlags = 0,
    cond: c.GCond = undefined,
    start_seqnum: u32 = std.math.maxInt(u32),
    segment_seqnum: u32 = std.math.maxInt(u32),
    group_id: c.guint = std.math.maxInt(c.guint),
    refs: std.atomic.Value(i32) = .init(1),

    fn ref(s: *Stream) *Stream {
        _ = s.refs.fetchAdd(1, .monotonic);
        return s;
    }

    fn unref(s: *Stream) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(s);
    }
};

const SyncPad = extern struct {
    parent: cm.Pad,
    stream: ?*Stream,
    pad: ?*c.GstPad,
    other: c.GWeakRef,
};

const Self = extern struct {
    parent: c.GstElement,
    lock: c.GMutex,
    shutdown: c.gboolean,
    eos: c.gboolean,
    flushing: c.gboolean,
    streams: [*c]c.GList,
    number: c.guint,
    group_start: u64,
    have_group_id: c.gboolean,
    group_id: c.guint,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var pad_parent: ?*c.GObjectClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn spad(p: anytype) *SyncPad {
    return @ptrCast(@alignCast(p));
}

fn lock(s: *Self) void {
    c.g_mutex_lock(&s.lock);
}

fn unlock(s: *Self) void {
    c.g_mutex_unlock(&s.lock);
}

fn streamOf(p: anytype) *Stream {
    return spad(p).stream.?.ref();
}

fn each(s: *Self) StreamIter {
    return .{ .l = s.streams };
}

const StreamIter = struct {
    l: [*c]c.GList,

    fn next(it: *StreamIter) ?*Stream {
        if (it.l == null) return null;
        const st: *Stream = @ptrCast(@alignCast(it.l[0].data));
        it.l = it.l[0].next;
        return st;
    }
};

fn isSrc(p: anytype) bool {
    return @as(*cm.Pad, @ptrCast(@alignCast(p))).direction == c.GST_PAD_SRC;
}

fn padDispose(o: [*c]c.GObject) callconv(.c) void {
    const p = spad(o);
    if (p.parent.direction == c.GST_PAD_SINK) {
        if (p.pad) |x| c.gst_object_unref(x);
        p.pad = null;
    } else c.g_weak_ref_clear(&p.other);
    if (p.stream) |st| st.unref();
    p.stream = null;
    pad_parent.?.dispose.?(o);
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = padDispose;
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_pad_get_type(), c.g_intern_static_string("GstStreamSyncPad"), @sizeOf(c.GstPadClass), padClassInit, @sizeOf(SyncPad), null, 0);
        }
    }.f);
}

fn newPad(templ: *c.GstStaticPadTemplate, name: [*c]const u8) ?*c.GstPad {
    const t = c.gst_static_pad_template_get(templ);
    defer c.gst_object_unref(t);
    if (!cm.that(cm.isA(t, c.gst_pad_template_get_type()), "gst_streamsync_pad_new_from_template", "GST_IS_PAD_TEMPLATE (templ)")) return null;
    return @ptrCast(@alignCast(c.g_object_new(padType(), "name", name, "direction", t[0].direction, "template", t, @as(?*anyopaque, null))));
}

fn otherPad(pad: anytype) ?*c.GstPad {
    const p = spad(pad);
    if (p.parent.direction == c.GST_PAD_SINK) return @ptrCast(@alignCast(c.gst_object_ref(p.pad)));
    return @ptrCast(@alignCast(c.g_weak_ref_get(&p.other)));
}

fn iterateLinks(pad: ?*c.GstPad, par: [*c]c.GstObject) callconv(.c) [*c]c.GstIterator {
    const s = me(par);
    lock(s);
    defer unlock(s);
    const o = otherPad(pad) orelse return null;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_pad_get_type());
    c.g_value_set_object(&v, o);
    const it = c.gst_iterator_new_single(c.gst_pad_get_type(), &v);
    c.g_value_unset(&v);
    c.gst_object_unref(o);
    return it;
}

fn rtOffset(s: *Self, pad: anytype, ev_in: [*c]c.GstEvent) [*c]c.GstEvent {
    var ev = ev_in;
    lock(s);
    const st = streamOf(pad);
    const diff: i64 = @bitCast(st.segment.base);
    st.unref();
    unlock(s);
    if (diff != -1) {
        ev = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(ev))));
        var off = c.gst_event_get_running_time_offset(ev);
        if (isSrc(pad)) off -%= diff else off +%= diff;
        c.gst_event_set_running_time_offset(ev, off);
    }
    return ev;
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    return c.gst_pad_event_default(pad, par, rtOffset(me(par), pad, ev));
}

fn waitFor(s: *Self, pad: anytype) bool {
    const st = streamOf(pad);
    while (s.eos == 0 and s.flushing == 0) {
        if (st.flushing or !st.wait) break;
        if (st.send_gap and isSrc(pad)) {
            if (st.segment.position == NONE) {
                st.send_gap = false;
                continue;
            }
            const ev = c.gst_event_new_gap(st.segment.position, st.gap);
            unlock(s);
            const ok = c.gst_pad_push_event(@ptrCast(@alignCast(pad)), ev);
            lock(s);
            if (ok == 0) {
                st.unref();
                return false;
            }
            st.send_gap = false;
            continue;
        }
        c.g_cond_wait(&st.cond, &s.lock);
    }
    st.unref();
    return true;
}

fn runningTime(seg: *c.GstSegment, pos: u64) i64 {
    return @bitCast(c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, pos));
}

fn streamStart(s: *Self, pad: anytype, ev: [*c]c.GstEvent) void {
    const seqnum = c.gst_event_get_seqnum(ev);
    var gid: c.guint = 0;
    var have = c.gst_event_parse_group_id(ev, &gid) != 0;
    lock(s);
    defer unlock(s);
    s.have_group_id &= @intFromBool(have);
    have = s.have_group_id != 0;
    s.eos = 0;
    const st = streamOf(pad);
    defer st.unref();
    c.gst_event_parse_stream_flags(ev, &st.flags);
    if (!((have and st.group_id != gid) or (!have and st.start_seqnum != seqnum))) return;
    st.is_eos = false;
    st.eos_sent = false;
    st.flushing = false;
    st.start_seqnum = seqnum;
    st.group_id = gid;
    if (!have) {
        var it = each(s);
        while (it.next()) |o| {
            if (o != st and o.start_seqnum == seqnum and !o.wait) {
                st.wait = false;
                return;
            }
        }
    } else if (gid == s.group_id) return;
    st.wait = true;
    var all = true;
    var it = each(s);
    while (it.next()) |o| {
        all = all and (o.flags & c.GST_STREAM_FLAG_SPARSE != 0 or (o.wait and (!have or o.group_id == gid)));
        if (!all) break;
    }
    if (!all) return;
    var position: i64 = 0;
    s.group_id = gid;
    it = each(s);
    while (it.next()) |o| {
        o.wait = false;
        if (o.segment.format != c.GST_FORMAT_TIME) continue;
        const fwd = o.segment.rate > 0;
        const stop = runningTime(&o.segment, if (fwd) o.segment.stop else o.segment.start);
        var pos = @max(runningTime(&o.segment, o.segment.position), stop);
        pos -%= runningTime(&o.segment, if (fwd) o.segment.start else o.segment.stop);
        pos = @max(0, pos);
        position = @max(position, pos);
    }
    s.group_start +%= @bitCast(position);
    it = each(s);
    while (it.next()) |o| {
        o.wait = false;
        c.g_cond_broadcast(&o.cond);
    }
}

fn segmentEvent(s: *Self, pad: anytype, ev: *[*c]c.GstEvent) bool {
    var seg: c.GstSegment = undefined;
    c.gst_event_copy_segment(ev.*, &seg);
    lock(s);
    _ = waitFor(s, pad);
    if (s.shutdown != 0) {
        unlock(s);
        c.gst_mini_object_unref(@ptrCast(ev.*));
        return false;
    }
    const st = streamOf(pad);
    if (seg.format == c.GST_FORMAT_TIME) {
        seg.base +%= s.group_start;
        c.gst_segment_copy_into(&seg, &st.segment);
        st.segment_seqnum = c.gst_event_get_seqnum(ev.*);
        const tmp = c.gst_event_new_segment(&st.segment);
        c.gst_event_set_seqnum(tmp, st.segment_seqnum);
        c.gst_mini_object_unref(@ptrCast(ev.*));
        ev.* = tmp;
    } else c.gst_segment_init(&st.segment, c.GST_FORMAT_UNDEFINED);
    st.unref();
    unlock(s);
    return true;
}

fn flushStop(s: *Self, pad: anytype, ev: [*c]c.GstEvent) void {
    var reset: c.gboolean = 0;
    c.gst_event_parse_flush_stop(ev, &reset);
    lock(s);
    defer unlock(s);
    const st = streamOf(pad);
    defer st.unref();
    if (reset != 0) c.gst_segment_init(&st.segment, c.GST_FORMAT_UNDEFINED);
    if (st.is_eos) {
        st.wait = false;
        st.is_eos = false;
    }
    st.eos_sent = false;
    st.flushing = false;
    c.g_cond_broadcast(&st.cond);
    if (reset == 0) return;
    var start: u64 = 0;
    var it = each(s);
    while (it.next()) |o| {
        if (o == st or o.flushing) continue;
        if (o.segment.format == c.GST_FORMAT_TIME) {
            const t = c.gst_segment_to_running_time(&o.segment, c.GST_FORMAT_TIME, if (o.segment.rate > 0) o.segment.start else o.segment.stop);
            start = @max(start, t);
        }
    }
    s.group_start = start;
}

fn eosEvent(s: *Self, pad: anytype, ev: [*c]c.GstEvent) c.gboolean {
    var ret: c.gboolean = 0;
    lock(s);
    var st = streamOf(pad);
    st.is_eos = true;
    const seen = st.seen_data;
    const src: ?*c.GstPad = @ptrCast(@alignCast(c.gst_object_ref(st.srcpad)));
    const seqnum = st.segment_seqnum;
    const ts = if (seen and st.segment.position != NONE) st.segment.position else if (st.segment.rate < 0.0 or st.segment.stop == NONE) st.segment.start else st.segment.stop;
    st.segment.position = ts;
    var all = true;
    var it = each(s);
    while (it.next()) |o| {
        all = all and o.is_eos;
        if (!all) break;
    }
    if (all) {
        s.eos = 1;
        var pads: [*c]c.GSList = null;
        it = each(s);
        while (it.next()) |o| pads = c.g_slist_prepend(pads, c.gst_object_ref(o.srcpad));
        if (pads != null) {
            ret = 1;
            var e = pads;
            while (e != null) : (e = e[0].next) {
                const o = streamOf(e[0].data);
                c.g_cond_broadcast(&o.cond);
                o.unref();
                c.gst_object_unref(e[0].data);
            }
            c.g_slist_free(pads);
        }
    } else if (seen) {
        st.send_gap = true;
        st.gap = NONE;
        st.wait = true;
        ret = @intFromBool(waitFor(s, src));
    }
    if (!seen or s.eos != 0) {
        const push = c.gst_event_new_eos();
        c.gst_event_set_seqnum(push, seqnum);
        unlock(s);
        ret = c.gst_pad_push_event(src, push);
        lock(s);
        st = streamOf(pad);
        st.eos_sent = true;
        st.unref();
    }
    c.gst_object_unref(src);
    c.gst_mini_object_unref(@ptrCast(ev));
    st.unref();
    unlock(s);
    return ret;
}

fn hasName(ev: [*c]c.GstEvent, name: [*c]const u8) bool {
    return c.gst_event_has_name(ev, name) != 0;
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    var ev = ev_in;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_STREAM_START => streamStart(s, pad, ev),
        c.GST_EVENT_SEGMENT => if (!segmentEvent(s, pad, &ev)) return 0,
        c.GST_EVENT_FLUSH_START => {
            lock(s);
            const st = streamOf(pad);
            s.eos = 0;
            st.flushing = true;
            c.g_cond_broadcast(&st.cond);
            st.unref();
            unlock(s);
        },
        c.GST_EVENT_FLUSH_STOP => flushStop(s, pad, ev),
        c.GST_EVENT_CUSTOM_DOWNSTREAM_OOB => {
            if (hasName(ev, "playsink-custom-video-flush") or hasName(ev, "playsink-custom-audio-flush") or hasName(ev, "playsink-custom-subtitle-flush")) {
                lock(s);
                const st = streamOf(pad);
                st.is_eos = false;
                st.eos_sent = false;
                st.wait = false;
                c.g_cond_broadcast(&st.cond);
                st.unref();
                unlock(s);
            }
        },
        c.GST_EVENT_EOS => return eosEvent(s, pad, ev),
        else => {},
    }
    return c.gst_pad_event_default(pad, par, rtOffset(s, pad, ev));
}

fn chain(pad: ?*c.GstPad, par: [*c]c.GstObject, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    var ret: c.GstFlowReturn = c.GST_FLOW_ERROR;
    const ts = buf[0].pts;
    const dur = buf[0].duration;
    var end: u64 = if (ts != NONE and dur != NONE) ts +% dur else NONE;
    lock(s);
    var st = streamOf(pad);
    st.seen_data = true;
    if (st.segment.format == c.GST_FORMAT_TIME and ts != NONE) st.segment.position = if (st.segment.rate > 0.0) ts else end;
    st.unref();
    unlock(s);
    if (otherPad(pad)) |o| {
        ret = c.gst_pad_push(o, buf);
        c.gst_object_unref(o);
    }
    if (ret != c.GST_FLOW_OK) return ret;
    lock(s);
    st = streamOf(pad);
    if (st.segment.format == c.GST_FORMAT_TIME) {
        const pos = if (st.segment.rate > 0.0) end else ts;
        if (pos != NONE) st.segment.position = pos;
    }
    if (end == NONE and ts != NONE) end = ts +% SEC;
    var it = each(s);
    while (it.next()) |o| {
        if (!o.is_eos or o.eos_sent or o.segment.format != c.GST_FORMAT_TIME) continue;
        const pos: i64 = @bitCast(if (o.segment.position != NONE) o.segment.position else o.segment.start);
        if (pos != -1 and end != NONE and @as(u64, @bitCast(pos)) +% SEC < end) {
            const ns: i64 = @as(i64, @bitCast(end)) -% @as(i64, SEC);
            o.segment.position = @bitCast(ns);
            o.send_gap = true;
            o.gap = @bitCast(ns -% pos);
            c.g_cond_broadcast(&o.cond);
        }
    }
    st.unref();
    unlock(s);
    return ret;
}

fn setFlags(p: ?*c.GstPad) void {
    cm.setPadFlag(p, c.GST_PAD_FLAG_PROXY_CAPS | c.GST_PAD_FLAG_PROXY_ALLOCATION | c.GST_PAD_FLAG_PROXY_SCHEDULING);
}

fn addStream(s: *Self) ?*c.GstPad {
    const st = std.heap.c_allocator.create(Stream) catch @panic("oom");
    st.* = .{ .number = s.number };
    c.g_cond_init(&st.cond);
    var name = c.g_strdup_printf("sink_%u", s.number);
    st.sinkpad = newPad(&sink_t, name);
    c.g_free(name);
    spad(st.sinkpad).stream = st.ref();
    c.gst_pad_set_iterate_internal_links_function_full(st.sinkpad, iterateLinks, null, null);
    c.gst_pad_set_event_function_full(st.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_chain_function_full(st.sinkpad, chain, null, null);
    setFlags(st.sinkpad);
    name = c.g_strdup_printf("src_%u", s.number);
    st.srcpad = newPad(&src_t, name);
    c.g_free(name);
    spad(st.srcpad).stream = st.ref();
    spad(st.sinkpad).pad = @ptrCast(@alignCast(c.gst_object_ref(st.srcpad)));
    c.g_weak_ref_init(&spad(st.srcpad).other, st.sinkpad);
    c.gst_pad_set_iterate_internal_links_function_full(st.srcpad, iterateLinks, null, null);
    c.gst_pad_set_event_function_full(st.srcpad, srcEvent, null, null);
    setFlags(st.srcpad);
    c.gst_segment_init(&st.segment, c.GST_FORMAT_UNDEFINED);
    unlock(s);
    const el = &s.parent;
    c.g_rec_mutex_lock(&el.state_lock);
    if (el.target_state != c.GST_STATE_NULL) {
        _ = c.gst_pad_set_active(st.srcpad, 1);
        _ = c.gst_pad_set_active(st.sinkpad, 1);
    }
    _ = c.gst_element_add_pad(el, st.srcpad);
    _ = c.gst_element_add_pad(el, st.sinkpad);
    c.g_rec_mutex_unlock(&el.state_lock);
    lock(s);
    s.streams = c.g_list_prepend(s.streams, st);
    s.number += 1;
    return st.sinkpad;
}

fn requestPad(el: [*c]c.GstElement, _: ?*c.GstPadTemplate, _: [*c]const u8, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(el);
    lock(s);
    defer unlock(s);
    return addStream(s);
}

fn releaseStream(s: *Self, st: *Stream) void {
    var l = s.streams;
    while (l != null) : (l = l[0].next) {
        if (l[0].data == @as(?*anyopaque, st)) {
            s.streams = c.g_list_delete_link(s.streams, l);
            break;
        }
    }
    if (l == null) c.g_assertion_message_expr(null, "../gst/playback/gststreamsynchronizer.c", 1164, "gst_stream_synchronizer_release_stream", "l != NULL");
    if (s.streams == null) {
        s.have_group_id = 1;
        s.group_id = std.math.maxInt(c.guint);
    }
    unlock(s);
    _ = c.gst_pad_set_active(st.srcpad, 0);
    _ = c.gst_element_remove_pad(&s.parent, st.srcpad);
    _ = c.gst_pad_set_active(st.sinkpad, 0);
    _ = c.gst_element_remove_pad(&s.parent, st.sinkpad);
    c.g_cond_clear(&st.cond);
    st.unref();
    lock(s);
}

fn releasePad(el: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(el);
    lock(s);
    const st = streamOf(pad);
    if (st.sinkpad != @as(?*c.GstPad, pad)) c.g_assertion_message_expr(null, "../gst/playback/gststreamsynchronizer.c", 1206, "gst_stream_synchronizer_release_pad", "stream->sinkpad == pad");
    releaseStream(s, st);
    st.unref();
    unlock(s);
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(el);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => s.shutdown = 0,
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            s.group_start = 0;
            s.have_group_id = 1;
            s.group_id = std.math.maxInt(c.guint);
            s.shutdown = 0;
            s.flushing = 0;
            s.eos = 0;
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lock(s);
            s.flushing = 1;
            s.shutdown = 1;
            var it = each(s);
            while (it.next()) |o| c.g_cond_broadcast(&o.cond);
            unlock(s);
        },
        else => {},
    }
    const ret = parent.?.change_state.?(el, t);
    if (ret != c.GST_STATE_CHANGE_SUCCESS) return ret;
    switch (t) {
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => {
            lock(s);
            var it = each(s);
            while (it.next()) |o| {
                if (o.is_eos and !o.eos_sent) {
                    o.send_gap = true;
                    o.gap = NONE;
                    c.g_cond_broadcast(&o.cond);
                }
            }
            unlock(s);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            s.group_start = 0;
            lock(s);
            var it = each(s);
            while (it.next()) |o| {
                c.gst_segment_init(&o.segment, c.GST_FORMAT_UNDEFINED);
                o.gap = NONE;
                o.wait = false;
                o.is_eos = false;
                o.eos_sent = false;
                o.flushing = false;
                o.send_gap = false;
            }
            unlock(s);
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            lock(s);
            s.number = 0;
            unlock(s);
        },
        else => {},
    }
    return ret;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&me(o).lock);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Stream Synchronizer", "Generic", "Synchronizes a group of streams to have equal durations and starting points", "Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    ec.change_state = changeState;
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    _ = c._gst_debug_category_new("streamsynchronizer", 0, "Stream Synchronizer");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.g_mutex_init(&me(inst).lock);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstStreamSynchronizer", Class, Self, classInit, init);
        }
    }.f);
}
