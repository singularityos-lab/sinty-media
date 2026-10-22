const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstconcat.c";
const NONE = cm.CLOCK_NONE;
const PROP_ACTIVE_PAD = 1;
const PROP_ADJUST_BASE = 2;

const Self = extern struct {
    parent: c.GstElement,
    lock: c.GMutex,
    cond: c.GCond,
    sinkpads: [*c]c.GList,
    current_sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    pad_count: c.guint,
    format: c.GstFormat,
    current_start_offset: u64,
    last_stop: u64,
    adjust_base: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

const ConcatPad = extern struct {
    parent: cm.Pad,
    segment: c.GstSegment,
    flushing: c.gboolean,
};

var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var pspec_active: [*c]c.GParamSpec = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn sp(p: anytype) *ConcatPad {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn ref(p: anytype) ?*c.GstPad {
    return @ptrCast(@alignCast(c.gst_object_ref(p)));
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_segment_init(&sp(inst).segment, c.GST_FORMAT_UNDEFINED);
    sp(inst).flushing = 0;
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_pad_get_type(), c.g_intern_static_string("GstConcatPad"), @sizeOf(c.GstPadClass), null, @sizeOf(ConcatPad), padInit, 0);
        }
    }.f);
}

fn notifyActive(s: *Self) void {
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspec_active);
}

fn lockS(s: *Self) void {
    c.g_mutex_lock(&s.lock);
}

fn unlockS(s: *Self) void {
    c.g_mutex_unlock(&s.lock);
}

fn wait(p: *ConcatPad, s: *Self) bool {
    lockS(s);
    defer unlockS(s);
    if (p.flushing != 0) return false;
    while (@as(?*anyopaque, @ptrCast(p)) != @as(?*anyopaque, @ptrCast(s.current_sinkpad))) {
        if (s.current_sinkpad == null and c.g_list_length(s.sinkpads) == 1) {
            s.current_sinkpad = ref(s.sinkpads[0].data);
            break;
        }
        c.g_cond_wait(&s.cond, &s.lock);
        if (p.flushing != 0) return false;
    }
    return true;
}

fn switchPad(s: *Self) bool {
    const seg = sp(s.current_sinkpad).segment;
    var stop = s.last_stop;
    if (stop == NONE) stop = seg.stop;
    if (stop == NONE) stop = seg.start;
    if (stop == NONE) c.g_assertion_message_expr(null, FILE, 480, "gst_concat_switch_pad", "last_stop != GST_CLOCK_TIME_NONE");
    if (stop > seg.stop) stop = seg.stop;
    if (seg.format == c.GST_FORMAT_TIME) {
        stop = c.gst_segment_to_running_time(&seg, seg.format, stop);
    } else stop +%= seg.start;
    s.current_start_offset +%= stop;
    var l = s.sinkpads;
    while (l != null) : (l = l[0].next) {
        if (l[0].data == @as(c.gpointer, @ptrCast(s.current_sinkpad))) {
            const prev = l[0].prev;
            c.gst_object_unref(s.current_sinkpad);
            s.current_sinkpad = if (prev != null) ref(prev[0].data) else null;
            c.g_cond_broadcast(&s.cond);
            break;
        }
    }
    s.last_stop = NONE;
    return s.current_sinkpad != null;
}

fn chain(pad: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    const p = sp(pad);
    if (!wait(p, s)) return c.GST_FLOW_FLUSHING;
    if (s.last_stop == NONE) s.last_stop = p.segment.start;
    if (s.format == c.GST_FORMAT_TIME) {
        const st = cm.buf(b).pts;
        var end: u64 = NONE;
        if (st != NONE) end = st;
        if (cm.buf(b).duration != NONE) end +%= cm.buf(b).duration;
        if (end != NONE and end > s.last_stop) s.last_stop = end;
    } else s.last_stop +%= c.gst_buffer_get_size(b);
    return c.gst_pad_push(s.srcpad, b);
}

fn coreError(s: *Self, dbg: [*c]u8, line: c.gint) void {
    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, null, dbg, FILE, "gst_concat_sink_event", line);
}

fn forwardFlush(s: *Self, p: *ConcatPad) bool {
    lockS(s);
    defer unlockS(s);
    return @as(?*anyopaque, @ptrCast(s.current_sinkpad)) == @as(?*anyopaque, @ptrCast(p)) or c.g_list_length(s.sinkpads) == 1;
}

fn drop(ev: *[*c]c.GstEvent) void {
    if (ev.* != null) c.gst_mini_object_unref(@ptrCast(ev.*));
    ev.* = null;
}

fn shiftOffset(s: *Self, ev_in: [*c]c.GstEvent, sign: i64) [*c]c.GstEvent {
    var ev = ev_in;
    lockS(s);
    if (s.adjust_base != 0 and s.format == c.GST_FORMAT_TIME) {
        ev = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(ev))));
        const off = c.gst_event_get_running_time_offset(ev) +% sign *% @as(i64, @bitCast(s.current_start_offset));
        c.gst_event_set_running_time_offset(ev, off);
    }
    unlockS(s);
    return ev;
}

fn sinkSegment(s: *Self, p: *ConcatPad, ev: *[*c]c.GstEvent, adjust: bool) bool {
    const seq = c.gst_event_get_seqnum(ev.*);
    c.gst_event_copy_segment(ev.*, &p.segment);
    drop(ev);
    lockS(s);
    if (s.format == c.GST_FORMAT_UNDEFINED) {
        if (p.segment.format != c.GST_FORMAT_TIME and p.segment.format != c.GST_FORMAT_BYTES) {
            unlockS(s);
            coreError(s, c.g_strdup("Can only operate in TIME or BYTES format"), 552);
            return false;
        }
        s.format = p.segment.format;
    } else if (s.format != p.segment.format) {
        unlockS(s);
        coreError(s, c.g_strdup_printf("Operating in %s format but new pad has %s", c.gst_format_get_name(s.format), c.gst_format_get_name(p.segment.format)), 562);
        return false;
    }
    unlockS(s);
    if (!wait(p, s)) return false;
    var seg = p.segment;
    lockS(s);
    if (adjust) {
        seg.duration = NONE;
        if (s.format == c.GST_FORMAT_TIME) {
            seg.base +%= s.current_start_offset;
        } else {
            seg.start +%= s.current_start_offset;
            if (seg.stop != NONE) seg.stop +%= s.current_start_offset;
        }
    }
    ev.* = c.gst_event_new_segment(&seg);
    c.gst_event_set_seqnum(ev.*, seq);
    unlockS(s);
    return true;
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    const p = sp(pad);
    var ev = ev_in;
    var ret = true;
    lockS(s);
    const adjust = s.adjust_base != 0;
    unlockS(s);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_STREAM_START => if (!wait(p, s)) {
            ret = false;
            drop(&ev);
        },
        c.GST_EVENT_SEGMENT => ret = sinkSegment(s, p, &ev, adjust),
        c.GST_EVENT_EOS => {
            const seq = c.gst_event_get_seqnum(ev);
            drop(&ev);
            if (!wait(p, s)) {
                ret = false;
            } else {
                lockS(s);
                const next = switchPad(s);
                unlockS(s);
                notifyActive(s);
                if (!next) {
                    ev = c.gst_event_new_eos();
                    c.gst_event_set_seqnum(ev, seq);
                } else _ = c.gst_element_post_message(element(s), c.gst_message_new_duration_changed(cm.obj(s)));
            }
        },
        c.GST_EVENT_FLUSH_START => {
            lockS(s);
            p.flushing = 1;
            c.g_cond_broadcast(&s.cond);
            unlockS(s);
            if (!forwardFlush(s, p)) drop(&ev);
        },
        c.GST_EVENT_FLUSH_STOP => {
            c.gst_segment_init(&p.segment, c.GST_FORMAT_UNDEFINED);
            p.flushing = 0;
            if (forwardFlush(s, p)) {
                var reset: c.gboolean = 0;
                c.gst_event_parse_flush_stop(ev, &reset);
                if (reset != 0) {
                    s.current_start_offset = 0;
                    s.last_stop = NONE;
                }
            } else drop(&ev);
        },
        else => if (cm.eventSerialized(ev) and !wait(p, s)) {
            drop(&ev);
            ret = false;
        },
    }
    if (ev != null) return c.gst_pad_event_default(pad, par, shiftOffset(s, ev, 1));
    return @intFromBool(ret);
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.querySerialized(q) and !wait(sp(pad), me(par))) return 0;
    return c.gst_pad_query_default(pad, par, q);
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    var ev = ev_in;
    var target: ?*c.GstPad = null;
    var ret = true;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEEK, c.GST_EVENT_QOS => {
            lockS(s);
            if (s.current_sinkpad) |cur| target = ref(cur);
            if (target == null and cm.eventType(ev) == c.GST_EVENT_SEEK and c.g_list_length(s.sinkpads) == 1) target = ref(s.sinkpads[0].data);
            unlockS(s);
            if (target == null) {
                drop(&ev);
                ret = false;
            }
        },
        c.GST_EVENT_FLUSH_STOP => {
            var reset: c.gboolean = 0;
            c.gst_event_parse_flush_stop(ev, &reset);
            if (reset != 0) s.current_start_offset = 0;
        },
        else => {},
    }
    if (ev != null) {
        ev = shiftOffset(s, ev, -1);
        ret = if (target) |t| c.gst_pad_push_event(t, ev) != 0 else c.gst_pad_event_default(pad, par, ev) != 0;
    }
    if (target) |t| c.gst_object_unref(t);
    return @intFromBool(ret);
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    return c.gst_pad_query_default(pad, par, q);
}

fn requestPad(el: [*c]c.GstElement, tmpl: [*c]c.GstPadTemplate, _: [*c]const u8, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(el);
    lockS(s);
    const name = c.g_strdup_printf("sink_%u", s.pad_count);
    s.pad_count += 1;
    unlockS(s);
    const p: ?*c.GstPad = @ptrCast(@alignCast(c.g_object_new(padType(), "name", name, "direction", tmpl[0].direction, "template", tmpl, @as(?*anyopaque, null))));
    c.g_free(name);
    c.gst_pad_set_chain_function_full(p, chain, null, null);
    c.gst_pad_set_event_function_full(p, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(p, sinkQuery, null, null);
    cm.setPadFlag(p, c.GST_PAD_FLAG_PROXY_CAPS | c.GST_PAD_FLAG_PROXY_ALLOCATION);
    lockS(s);
    s.sinkpads = c.g_list_prepend(s.sinkpads, c.gst_object_ref(p));
    const first = s.current_sinkpad == null;
    if (first) s.current_sinkpad = ref(p);
    unlockS(s);
    _ = c.gst_element_add_pad(el, p);
    if (first) notifyActive(s);
    return p;
}

fn releasePad(el: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(el);
    const p = sp(pad);
    lockS(s);
    p.flushing = 1;
    c.g_cond_broadcast(&s.cond);
    unlockS(s);
    _ = c.gst_pad_set_active(pad, 0);
    lockS(s);
    var removed = false;
    var eos = false;
    if (s.current_sinkpad == pad) {
        eos = !switchPad(s);
        removed = true;
    }
    var l = s.sinkpads;
    while (l != null) : (l = l[0].next) {
        if (l[0].data == @as(c.gpointer, @ptrCast(pad))) {
            c.gst_object_unref(pad);
            s.sinkpads = c.g_list_delete_link(s.sinkpads, l);
            break;
        }
    }
    unlockS(s);
    _ = c.gst_element_remove_pad(el, pad);
    if (removed) notifyActive(s);
    if (el[0].current_state > c.GST_STATE_READY) {
        if (removed and !eos) _ = c.gst_element_post_message(el, c.gst_message_new_duration_changed(cm.obj(s)));
        if (eos) _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_eos());
    }
}

fn resetPad(v: [*c]const c.GValue, _: c.gpointer) callconv(.c) void {
    const p = sp(c.g_value_get_object(v));
    c.gst_segment_init(&p.segment, c.GST_FORMAT_UNDEFINED);
    p.flushing = 0;
}

fn unblockPad(v: [*c]const c.GValue, _: c.gpointer) callconv(.c) void {
    sp(c.g_value_get_object(v)).flushing = 1;
}

fn eachSink(el: [*c]c.GstElement, f: c.GstIteratorForeachFunction) c.GstIteratorResult {
    const it = c.gst_element_iterate_sink_pads(el);
    var r = c.gst_iterator_foreach(it, f, null);
    while (r == c.GST_ITERATOR_RESYNC) {
        c.gst_iterator_resync(it);
        r = c.gst_iterator_foreach(it, f, null);
    }
    c.gst_iterator_free(it);
    return r;
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(el);
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            s.format = c.GST_FORMAT_UNDEFINED;
            s.current_start_offset = 0;
            s.last_stop = NONE;
            if (eachSink(el, resetPad) == c.GST_ITERATOR_ERROR) return c.GST_STATE_CHANGE_FAILURE;
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lockS(s);
            const r = eachSink(el, unblockPad);
            c.g_cond_broadcast(&s.cond);
            unlockS(s);
            if (r == c.GST_ITERATOR_ERROR) return c.GST_STATE_CHANGE_FAILURE;
        },
        else => {},
    }
    return parent.?.change_state.?(el, t);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_ACTIVE_PAD => {
            lockS(s);
            c.g_value_set_object(v, s.current_sinkpad);
            unlockS(s);
        },
        PROP_ADJUST_BASE => {
            lockS(s);
            c.g_value_set_boolean(v, s.adjust_base);
            unlockS(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 260),
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_ADJUST_BASE => {
            lockS(s);
            s.adjust_base = c.g_value_get_boolean(v);
            unlockS(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 279),
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    _ = c.gst_object_replace(@ptrCast(&s.current_sinkpad), null);
    outer: while (true) {
        var l = element(s)[0].pads;
        while (l != null) : (l = l[0].next) {
            const p: ?*c.GstPad = @ptrCast(@alignCast(l[0].data));
            if (cm.pad(p).direction == c.GST_PAD_SINK) {
                c.gst_element_release_request_pad(element(s), p);
                continue :outer;
            }
        }
        break;
    }
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_mutex_clear(&s.lock);
    c.g_cond_clear(&s.cond);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    oc.dispose = dispose;
    oc.finalize = finalize;
    pspec_active = c.g_param_spec_object("active-pad", "Active pad", "Currently active sink pad", c.gst_pad_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS);
    c.g_object_class_install_property(oc, PROP_ACTIVE_PAD, pspec_active);
    c.g_object_class_install_property(oc, PROP_ADJUST_BASE, c.g_param_spec_boolean("adjust-base", "Adjust segment base", "Adjust the base value of segments to ensure they are adjacent", 1, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Concat", "Generic", "Concatenate multiple streams", "Sebastian Dröge <sebastian@centricular.com>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    ec.change_state = changeState;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.g_mutex_init(&s.lock);
    c.g_cond_init(&s.cond);
    s.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_event_function_full(s.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(s.srcpad, srcQuery, null, null);
    c.gst_pad_use_fixed_caps(s.srcpad);
    _ = c.gst_element_add_pad(element(s), s.srcpad);
    s.adjust_base = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstConcat", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("concat", 0, "concat element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "concat", c.GST_RANK_NONE, getType()) != 0;
}
