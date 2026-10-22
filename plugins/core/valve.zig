const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstvalve.c";
const PROP_DROP = 1;
const PROP_DROP_MODE = 2;

const DROP_ALL = 0;
const FORWARD_STICKY = 1;
const TO_GAP = 2;

const Self = extern struct {
    parent: c.GstElement,
    drop: c.gint,
    drop_mode: c.gint,
    discont: c.gboolean,
    need_repush_sticky: c.gboolean,
    srcpad: ?*c.GstPad,
    sinkpad: ?*c.GstPad,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var mode_once: cm.Once = .{};

var modes = [_]c.GEnumValue{
    .{ .value = DROP_ALL, .value_name = "Drop all buffers and events", .value_nick = "drop-all" },
    .{ .value = FORWARD_STICKY, .value_name = "Drop all buffers but forward sticky events", .value_nick = "forward-sticky-events" },
    .{ .value = TO_GAP, .value_name = "Convert all dropped buffers into gap events and forward sticky events", .value_nick = "transform-to-gap" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn modeType() c.GType {
    return mode_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstValveDropMode", &modes);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn dropping(v: *Self) bool {
    return @atomicLoad(c.gint, &v.drop, .seq_cst) != 0;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, val: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const v = me(o);
    switch (id) {
        PROP_DROP => {
            @atomicStore(c.gint, &v.drop, c.g_value_get_boolean(val), .seq_cst);
            _ = c.gst_pad_push_event(v.sinkpad, c.gst_event_new_reconfigure());
        },
        PROP_DROP_MODE => v.drop_mode = c.g_value_get_enum(val),
        else => cm.warnInvalid(FILE, o, id, spec, 189),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, val: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const v = me(o);
    switch (id) {
        PROP_DROP => c.g_value_set_boolean(val, @atomicLoad(c.gint, &v.drop, .seq_cst)),
        PROP_DROP_MODE => c.g_value_set_enum(val, v.drop_mode),
        else => cm.warnInvalid(FILE, o, id, spec, 208),
    }
}

fn forwardSticky(_: ?*c.GstPad, ev: [*c][*c]c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    const v = me(data);
    if (c.gst_pad_push_event(v.srcpad, @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev[0]))))) == 0) v.need_repush_sticky = 1;
    return 1;
}

fn repush(v: *Self) void {
    v.need_repush_sticky = 0;
    c.gst_pad_sticky_events_foreach(v.sinkpad, forwardSticky, v);
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b_in: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const v = me(par);
    var b = b_in;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (dropping(v)) {
        if (v.drop_mode == TO_GAP) _ = c.gst_pad_push_event(v.srcpad, c.gst_event_new_gap(cm.buf(b).pts, cm.buf(b).duration));
        c.gst_buffer_unref(b);
        v.discont = 1;
    } else {
        if (v.discont != 0) {
            b = c.gst_buffer_make_writable(b);
            cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
            v.discont = 0;
        }
        if (v.need_repush_sticky != 0) repush(v);
        ret = c.gst_pad_push(v.srcpad, b);
    }
    if (dropping(v)) ret = c.GST_FLOW_OK;
    return ret;
}

fn needsDropping(v: *Self, ev: [*c]c.GstEvent) bool {
    if (!dropping(v)) return false;
    return switch (v.drop_mode) {
        DROP_ALL => true,
        FORWARD_STICKY => !cm.eventSticky(ev),
        TO_GAP => !cm.eventSticky(ev) and cm.eventType(ev) != c.GST_EVENT_GAP,
        else => c.g_assertion_message_expr(null, FILE, 284, "gst_valve_event_needs_dropping", null),
    };
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const v = me(par);
    const drop = needsDropping(v, ev);
    const sticky = cm.eventSticky(ev);
    var ret: c.gboolean = 1;
    if (drop) {
        if (sticky) v.need_repush_sticky = 1;
        c.gst_mini_object_unref(@ptrCast(ev));
    } else {
        if (v.need_repush_sticky != 0) repush(v);
        ret = c.gst_pad_event_default(pad, par, ev);
    }
    if (dropping(v)) {
        if (v.drop_mode == DROP_ALL and sticky) v.need_repush_sticky = 1;
        ret = 1;
    }
    return ret;
}

fn query(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.querySerialized(q) and dropping(me(par))) return 0;
    return c.gst_pad_query_default(pad, par, q);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_DROP, c.g_param_spec_boolean("drop", "Drop buffers and events", "Whether to drop buffers and events or let them through", 0, cm.RW | cm.MUTABLE_PLAYING));
    c.g_object_class_install_property(oc, PROP_DROP_MODE, c.g_param_spec_enum("drop-mode", "Drop mode", "The drop mode to use", modeType(), DROP_ALL, cm.RW | cm.MUTABLE_READY));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Valve element", "Filter", "Drops buffers and events or lets them through", "Olivier Crete <olivier.crete@collabora.co.uk>");
    c.gst_type_mark_as_plugin_api(modeType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const v = me(inst);
    const e: [*c]c.GstElement = @ptrCast(@alignCast(inst));
    v.drop = 0;
    v.drop_mode = DROP_ALL;
    v.discont = 0;
    v.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_query_function_full(v.srcpad, query, null, null);
    cm.setPadFlag(v.srcpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(e, v.srcpad);
    v.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(v.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(v.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(v.sinkpad, query, null, null);
    cm.setPadFlag(v.sinkpad, c.GST_PAD_FLAG_PROXY_CAPS | c.GST_PAD_FLAG_PROXY_ALLOCATION);
    _ = c.gst_element_add_pad(e, v.sinkpad);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstValve", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("valve", 0, "Valve");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "valve", c.GST_RANK_NONE, getType()) != 0;
}
