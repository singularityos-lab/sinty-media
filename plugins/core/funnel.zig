const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstfunnel.c";
const PROP_FORWARD_STICKY_EVENTS = 1;

const FunnelPad = extern struct {
    parent: cm.Pad,
    got_eos: c.gboolean,
};

const Self = extern struct {
    element: c.GstElement,
    srcpad: ?*c.GstPad,
    last_sinkpad: ?*c.GstPad,
    forward_sticky_events: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    @as(*FunnelPad, @ptrCast(@alignCast(inst))).got_eos = 0;
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_pad_get_type(), c.g_intern_static_string("GstFunnelPad"), @sizeOf(c.GstPadClass), null, @sizeOf(FunnelPad), padInit, 0);
        }
    }.f);
}

fn fp(p: anytype) *FunnelPad {
    return @ptrCast(@alignCast(p));
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn el(p: anytype) *c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_FORWARD_STICKY_EVENTS) {
        me(o).forward_sticky_events = c.g_value_get_boolean(v);
    } else cm.warnInvalid(FILE, o, id, spec, 136);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_FORWARD_STICKY_EVENTS) {
        c.g_value_set_boolean(v, me(o).forward_sticky_events);
    } else cm.warnInvalid(FILE, o, id, spec, 152);
}

fn replaceLast(f: *Self, pad: ?*c.GstPad) void {
    _ = c.gst_object_replace(@ptrCast(&f.last_sinkpad), @ptrCast(@alignCast(pad)));
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const f = me(o);
    replaceLast(f, null);
    restart: while (true) {
        var item: ?*c.GList = el(o).pads;
        while (item) |n| : (item = n.next) {
            const pad: ?*c.GstPad = @ptrCast(@alignCast(n.data));
            if (cm.pad(pad).direction == c.GST_PAD_SINK) {
                c.gst_element_release_request_pad(el(o), pad);
                continue :restart;
            }
        }
        break;
    }
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn requestNewPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_object_new(padType(), "name", name, "direction", templ[0].direction, "template", templ, @as(?*anyopaque, null))));
    c.gst_pad_set_chain_function_full(pad, chain, null, null);
    c.gst_pad_set_chain_list_function_full(pad, chainList, null, null);
    c.gst_pad_set_event_function_full(pad, sinkEvent, null, null);
    cm.setPadFlag(pad, c.GST_PAD_FLAG_PROXY_CAPS | c.GST_PAD_FLAG_PROXY_ALLOCATION);
    _ = c.gst_element_add_pad(e, pad);
    return pad;
}

fn allEos(f: *Self) bool {
    if (el(f).numsinkpads == 0) return false;
    var item: ?*c.GList = el(f).sinkpads;
    while (item) |n| : (item = n.next) {
        if (fp(n.data).got_eos == 0) return false;
    }
    return true;
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const f = me(e);
    _ = c.gst_pad_set_active(pad, 0);
    const got_eos = fp(pad).got_eos;
    _ = c.gst_element_remove_pad(e, pad);
    cm.lock(f);
    const send = got_eos == 0 and allEos(f);
    cm.unlock(f);
    if (send) _ = c.gst_pad_push_event(f.srcpad, c.gst_event_new_eos());
}

fn forwardEvents(_: ?*c.GstPad, ev: [*c][*c]c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    if (cm.eventType(ev[0]) != c.GST_EVENT_EOS) _ = c.gst_pad_push_event(@ptrCast(@alignCast(data)), @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev[0])))));
    return 1;
}

fn switchTo(f: *Self, pad: ?*c.GstPad) void {
    if (f.last_sinkpad == null or (f.forward_sticky_events != 0 and f.last_sinkpad != pad)) {
        replaceLast(f, pad);
        c.gst_pad_sticky_events_foreach(pad, forwardEvents, f.srcpad);
    }
}

fn chainObject(pad: ?*c.GstPad, f: *Self, list: bool, obj: c.gpointer) c.GstFlowReturn {
    cm.streamLock(f.srcpad);
    switchTo(f, pad);
    const r = if (list) c.gst_pad_push_list(f.srcpad, @ptrCast(obj)) else c.gst_pad_push(f.srcpad, @ptrCast(@alignCast(obj)));
    cm.streamUnlock(f.srcpad);
    return r;
}

fn chain(pad: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return chainObject(pad, me(par), false, b);
}

fn chainList(pad: ?*c.GstPad, par: [*c]c.GstObject, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    return chainObject(pad, me(par), true, l);
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const f = me(par);
    var forward = true;
    var res: c.gboolean = 1;
    var locked = false;
    if (cm.eventSticky(ev)) {
        locked = true;
        cm.streamLock(f.srcpad);
        if (cm.eventType(ev) == c.GST_EVENT_EOS) {
            cm.lock(f);
            fp(pad).got_eos = 1;
            forward = allEos(f);
            cm.unlock(f);
        } else if (pad != f.last_sinkpad) forward = false;
    } else if (cm.eventType(ev) == c.GST_EVENT_FLUSH_STOP) {
        locked = true;
        cm.streamLock(f.srcpad);
        cm.lock(f);
        fp(pad).got_eos = 0;
        cm.unlock(f);
    }
    if (forward and cm.eventSerialized(ev)) {
        if (!locked) {
            locked = true;
            cm.streamLock(f.srcpad);
        }
        switchTo(f, pad);
    }
    if (forward) res = c.gst_pad_push_event(f.srcpad, ev) else c.gst_mini_object_unref(@ptrCast(ev));
    if (locked) cm.streamUnlock(f.srcpad);
    return res;
}

fn resetPad(v: [*c]const c.GValue, data: c.gpointer) callconv(.c) void {
    const f = me(data);
    cm.lock(f);
    fp(c.g_value_get_object(v)).got_eos = 0;
    cm.unlock(f);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const ret = parent.?.change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        const it = c.gst_element_iterate_sink_pads(e);
        var r: c.GstIteratorResult = undefined;
        while (true) {
            r = c.gst_iterator_foreach(it, resetPad, e);
            if (r != c.GST_ITERATOR_RESYNC) break;
            c.gst_iterator_resync(it);
        }
        c.gst_iterator_free(it);
        if (r == c.GST_ITERATOR_ERROR) return c.GST_STATE_CHANGE_FAILURE;
    }
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    c.g_object_class_install_property(oc, PROP_FORWARD_STICKY_EVENTS, c.g_param_spec_boolean("forward-sticky-events", "Forward sticky events", "Forward sticky events on stream changes", 1, cm.RW | cm.MUTABLE_READY));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Funnel pipe fitting", "Generic", "N-to-1 pipe fitting", "Olivier Crete <olivier.crete@collabora.co.uk>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    ec.change_state = changeState;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const f = me(inst);
    f.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_use_fixed_caps(f.srcpad);
    _ = c.gst_element_add_pad(el(f), f.srcpad);
    f.forward_sticky_events = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstFunnel", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("funnel", 0, "funnel element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "funnel", c.GST_RANK_NONE, getType()) != 0;
}
