const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const Self = extern struct {
    parent: c.GstElement,
    sinkpad: ?*c.GstPad,
    lock: c.GMutex,
    current: ?*c.GstPad,
    srcpads: [*c]c.GList,
    cookie: u32,
    pending_events: [*c]c.GList,
    keyunit_seqnum: u32,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_REQUEST, "ANY");
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GObjectClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn lock(s: *Self) void {
    c.g_mutex_lock(&s.lock);
}

fn unlock(s: *Self) void {
    c.g_mutex_unlock(&s.lock);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_list_foreach(s.pending_events, @ptrCast(&c.gst_event_unref), null);
    c.g_list_free(s.pending_events);
    s.pending_events = null;
    parent.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&me(o).lock);
    parent.?.finalize.?(o);
}

fn pushPending(s: *Self, pad: ?*c.GstPad) void {
    var l = s.pending_events;
    while (l != null) : (l = l.*.next) _ = c.gst_pad_push_event(pad, @ptrCast(@alignCast(l.*.data)));
    c.g_list_free(s.pending_events);
    s.pending_events = null;
}

fn currentRef(s: *Self) ?*c.GstPad {
    lock(s);
    defer unlock(s);
    return if (s.current) |p| @ptrCast(c.gst_object_ref(p)) else null;
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    const pad = currentRef(s) orelse return c.GST_FLOW_ERROR;
    if (s.pending_events != null) pushPending(s, pad);
    const res = c.gst_pad_push(pad, b);
    c.gst_object_unref(pad);
    return res;
}

fn flushEvents(pad: ?*c.GstPad, events: [*c]c.GList) [*c]c.GList {
    var l = events;
    while (l != null) : (l = l.*.next) {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(l.*.data));
        const t = cm.eventType(e);
        if (t != c.GST_EVENT_EOS and t != c.GST_EVENT_SEGMENT and cm.eventSticky(e) and pad != null) _ = c.gst_pad_store_sticky_event(pad, e);
        c.gst_event_unref(e);
    }
    c.g_list_free(events);
    return null;
}

fn setCaps(s: *Self, caps: [*c]c.GstCaps) bool {
    lock(s);
    defer unlock(s);
    while (true) {
        if (s.srcpads == null) return false;
        var res = false;
        const prev: ?*c.GstPad = if (s.current) |p| @ptrCast(c.gst_object_ref(p)) else null;
        defer if (prev) |p| c.gst_object_unref(p);
        var l = s.srcpads;
        const cookie = s.cookie;
        var resync = false;
        while (l != null) : (l = l.*.next) {
            const sp: ?*c.GstPad = @ptrCast(l.*.data);
            unlock(s);
            const peer = c.gst_pad_peer_query_caps(sp, null);
            if (peer != null) {
                res = c.gst_caps_can_intersect(caps, peer) != 0;
                c.gst_caps_unref(peer);
            }
            lock(s);
            if (cookie != s.cookie) {
                resync = true;
                break;
            }
            if (res) {
                s.current = sp;
                if (prev != null and prev != sp) {
                    _ = c.gst_pad_push_event(prev, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new_empty("start-draining-encoder")));
                    _ = c.gst_pad_push_event(prev, c.gst_event_new_eos());
                    _ = c.gst_pad_push_event(prev, c.gst_event_new_flush_start());
                    _ = c.gst_pad_push_event(prev, c.gst_event_new_flush_stop(0));
                }
                return true;
            }
        }
        if (!resync) return res;
    }
}

fn sinkEvent(_: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    var res: c.gboolean = 1;
    var toall = false;
    var store = false;
    switch (cm.eventType(e)) {
        c.GST_EVENT_STREAM_START, c.GST_EVENT_FLUSH_START => toall = true,
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            res = @intFromBool(setCaps(s, caps));
            store = true;
        },
        c.GST_EVENT_FLUSH_STOP => {
            toall = true;
            lock(s);
            s.pending_events = flushEvents(s.current, s.pending_events);
            unlock(s);
        },
        c.GST_EVENT_EOS => {
            if (s.pending_events != null) {
                if (currentRef(s)) |sp| {
                    pushPending(s, sp);
                    c.gst_object_unref(sp);
                }
            }
            toall = true;
        },
        else => store = cm.eventSerialized(e),
    }
    if (store) {
        s.pending_events = c.g_list_append(s.pending_events, e);
        return res;
    }
    if (toall) {
        lock(s);
        outer: while (true) {
            if (s.srcpads == null) {
                unlock(s);
                c.gst_event_unref(e);
                return 0;
            }
            var l = s.srcpads;
            const cookie = s.cookie;
            while (l != null) {
                const sp: ?*c.GstPad = @ptrCast(l.*.data);
                unlock(s);
                res = c.gst_pad_push_event(sp, c.gst_event_ref(e));
                lock(s);
                if (cookie != s.cookie) continue :outer;
                l = l.*.next;
            }
            break;
        }
        unlock(s);
        c.gst_event_unref(e);
        return res;
    }
    lock(s);
    const pad = s.current;
    unlock(s);
    if (pad != null) return c.gst_pad_push_event(pad, e);
    c.gst_event_unref(e);
    return 0;
}

fn getCaps(s: *Self, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    lock(s);
    defer unlock(s);
    while (true) {
        if (s.srcpads == null) return if (filter != null) c.gst_caps_ref(filter) else c.gst_caps_new_any();
        var res: [*c]c.GstCaps = null;
        const cookie = s.cookie;
        var l = s.srcpads;
        var resync = false;
        while (l != null) : (l = l.*.next) {
            const sp: ?*c.GstPad = @ptrCast(l.*.data);
            _ = c.gst_object_ref(sp);
            unlock(s);
            if (res != null) {
                const peer = c.gst_pad_peer_query_caps(sp, filter);
                if (peer != null) res = c.gst_caps_merge(res, peer);
            } else res = c.gst_pad_peer_query_caps(sp, filter);
            lock(s);
            c.gst_object_unref(sp);
            if (cookie != s.cookie) {
                if (res != null) c.gst_caps_unref(res);
                resync = true;
                break;
            }
        }
        if (!resync) return res;
    }
}

fn acceptCaps(s: *Self, caps: [*c]c.GstCaps) bool {
    lock(s);
    defer unlock(s);
    while (true) {
        if (s.srcpads == null) return false;
        const cookie = s.cookie;
        var l = s.srcpads;
        var resync = false;
        var res = false;
        while (l != null) : (l = l.*.next) {
            const sp: ?*c.GstPad = @ptrCast(l.*.data);
            _ = c.gst_object_ref(sp);
            unlock(s);
            res = c.gst_pad_peer_query_accept_caps(sp, caps) != 0;
            lock(s);
            c.gst_object_unref(sp);
            if (cookie != s.cookie) {
                resync = true;
                break;
            }
            if (res) break;
        }
        if (!resync) return res;
    }
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.queryType(q)) {
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            const caps = getCaps(s, filter);
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(q, &caps);
            c.gst_query_set_accept_caps_result(q, @intFromBool(acceptCaps(s, caps)));
            return 1;
        },
        else => return c.gst_pad_query_default(pad, par, q),
    }
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    if (c.gst_video_event_is_force_key_unit(e) != 0) {
        const seq = c.gst_event_get_seqnum(e);
        lock(s);
        if (seq == s.keyunit_seqnum) {
            unlock(s);
            c.gst_event_unref(e);
            return 1;
        }
        s.keyunit_seqnum = seq;
        unlock(s);
    }
    return c.gst_pad_event_default(pad, par, e);
}

fn requestNewPad(el: [*c]c.GstElement, _: [*c]c.GstPadTemplate, name: [*c]const u8, _: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(el);
    const p = c.gst_pad_new_from_static_template(&src_t, name);
    lock(s);
    s.srcpads = c.g_list_append(s.srcpads, p);
    _ = c.gst_pad_set_active(p, 1);
    _ = c.gst_element_add_pad(el, p);
    s.cookie +%= 1;
    c.gst_pad_set_event_function_full(p, srcEvent, null, null);
    unlock(s);
    return p;
}

fn releasePad(el: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(el);
    lock(s);
    defer unlock(s);
    const l = c.g_list_find(s.srcpads, pad);
    if (l == null) return;
    const p: ?*c.GstPad = @ptrCast(l.*.data);
    s.srcpads = c.g_list_delete_link(s.srcpads, l);
    s.cookie +%= 1;
    if (p == s.current) s.current = null;
    _ = c.gst_element_remove_pad(el, p);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.finalize = finalize;
    _ = c._gst_debug_category_new("streamsplitter", 0, "Stream Splitter");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    c.gst_element_class_set_static_metadata(ec, "streamsplitter", "Generic", "Splits streams based on their media type", "Edward Hervey <edward.hervey@collabora.co.uk>");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(s.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(s.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(s.sinkpad, sinkQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.sinkpad);
    c.g_mutex_init(&s.lock);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstStreamSplitter", Class, Self, classInit, init);
        }
    }.f);
}

pub fn new(name: [*c]const u8) [*c]c.GstElement {
    return @ptrCast(@alignCast(c.g_object_new(getType(), "name", name, @as(?*anyopaque, null))));
}
