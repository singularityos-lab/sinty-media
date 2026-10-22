const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstfakesink.c";

const PROP_STATE_ERROR = 1;
const PROP_SILENT = 2;
const PROP_DUMP = 3;
const PROP_SIGNAL_HANDOFFS = 4;
const PROP_DROP_OUT_OF_SEGMENT = 5;
const PROP_LAST_MESSAGE = 6;
const PROP_CAN_ACTIVATE_PUSH = 7;
const PROP_CAN_ACTIVATE_PULL = 8;
const PROP_NUM_BUFFERS = 9;

const ERR_NONE = 0;
const ERR_NULL_READY = 1;
const ERR_READY_PAUSED = 2;
const ERR_PAUSED_PLAYING = 3;
const ERR_PLAYING_PAUSED = 4;
const ERR_PAUSED_READY = 5;
const ERR_READY_NULL = 6;

const Handoff = ?*const fn ([*c]c.GstElement, [*c]c.GstBuffer, ?*c.GstPad) callconv(.c) void;

const Self = extern struct {
    parent: c.GstBaseSink,
    silent: c.gboolean,
    dump: c.gboolean,
    signal_handoffs: c.gboolean,
    state_error: c.gint,
    last_message: [*c]u8,
    num_buffers: c.gint,
    num_buffers_left: c.gint,
};

const Class = extern struct {
    parent: c.GstBaseSinkClass,
    handoff: Handoff,
    preroll_handoff: Handoff,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");

var once: cm.Once = .{};
var err_once: cm.Once = .{};
var parent: ?*c.GstBaseSinkClass = null;
var sig_handoff: c.guint = 0;
var sig_preroll: c.guint = 0;
var pspec_last: [*c]c.GParamSpec = null;

var errors = [_]c.GEnumValue{
    .{ .value = ERR_NONE, .value_name = "No state change errors", .value_nick = "none" },
    .{ .value = ERR_NULL_READY, .value_name = "Fail state change from NULL to READY", .value_nick = "null-to-ready" },
    .{ .value = ERR_READY_PAUSED, .value_name = "Fail state change from READY to PAUSED", .value_nick = "ready-to-paused" },
    .{ .value = ERR_PAUSED_PLAYING, .value_name = "Fail state change from PAUSED to PLAYING", .value_nick = "paused-to-playing" },
    .{ .value = ERR_PLAYING_PAUSED, .value_name = "Fail state change from PLAYING to PAUSED", .value_nick = "playing-to-paused" },
    .{ .value = ERR_PAUSED_READY, .value_name = "Fail state change from PAUSED to READY", .value_nick = "paused-to-ready" },
    .{ .value = ERR_READY_NULL, .value_name = "Fail state change from READY to NULL", .value_nick = "ready-to-null" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn errorType() c.GType {
    return err_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstFakeSinkStateError", &errors);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn bsink(p: anytype) [*c]c.GstBaseSink {
    return @ptrCast(@alignCast(p));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_STATE_ERROR => s.state_error = c.g_value_get_enum(v),
        PROP_SILENT => s.silent = c.g_value_get_boolean(v),
        PROP_DUMP => s.dump = c.g_value_get_boolean(v),
        PROP_SIGNAL_HANDOFFS => s.signal_handoffs = c.g_value_get_boolean(v),
        PROP_DROP_OUT_OF_SEGMENT => c.gst_base_sink_set_drop_out_of_segment(bsink(s), c.g_value_get_boolean(v)),
        PROP_CAN_ACTIVATE_PUSH => s.parent.can_activate_push = c.g_value_get_boolean(v),
        PROP_CAN_ACTIVATE_PULL => s.parent.can_activate_pull = c.g_value_get_boolean(v),
        PROP_NUM_BUFFERS => s.num_buffers = c.g_value_get_int(v),
        else => cm.warnInvalid(FILE, o, id, spec, 308),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_STATE_ERROR => c.g_value_set_enum(v, s.state_error),
        PROP_SILENT => c.g_value_set_boolean(v, s.silent),
        PROP_DUMP => c.g_value_set_boolean(v, s.dump),
        PROP_SIGNAL_HANDOFFS => c.g_value_set_boolean(v, s.signal_handoffs),
        PROP_DROP_OUT_OF_SEGMENT => c.g_value_set_boolean(v, c.gst_base_sink_get_drop_out_of_segment(bsink(s))),
        PROP_LAST_MESSAGE => {
            cm.lock(s);
            c.g_value_set_string(v, s.last_message);
            cm.unlock(s);
        },
        PROP_CAN_ACTIVATE_PUSH => c.g_value_set_boolean(v, s.parent.can_activate_push),
        PROP_CAN_ACTIVATE_PULL => c.g_value_set_boolean(v, s.parent.can_activate_pull),
        PROP_NUM_BUFFERS => c.g_value_set_int(v, s.num_buffers),
        else => cm.warnInvalid(FILE, o, id, spec, 353),
    }
}

fn notifyLast(s: *Self) void {
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(s)), pspec_last);
}

fn setLast(s: *Self, msg: [*c]u8) void {
    cm.lock(s);
    c.g_free(s.last_message);
    s.last_message = msg;
    cm.unlock(s);
    notifyLast(s);
}

fn event(b: [*c]c.GstBaseSink, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(b);
    if (s.silent == 0) {
        const pad = s.parent.sinkpad;
        cm.lock(s);
        c.g_free(s.last_message);
        if (cm.eventType(ev) == c.GST_EVENT_SINK_MESSAGE) {
            var msg: [*c]c.GstMessage = null;
            c.gst_event_parse_sink_message(ev, &msg);
            const sstr = c.gst_structure_to_string(c.gst_message_get_structure(msg));
            s.last_message = c.g_strdup_printf("message ******* (%s:%s) M (type: %d, %s) %p", cm.padParentName(pad), cm.padName(pad), msg[0].type, sstr, msg);
            c.gst_mini_object_unref(@ptrCast(msg));
            c.g_free(sstr);
        } else {
            const st = c.gst_event_get_structure(ev);
            const sstr = if (st != null) c.gst_structure_to_string(st) else c.g_strdup("");
            s.last_message = c.g_strdup_printf("event   ******* (%s:%s) E (type: %s (%d), %s) %p", cm.padParentName(pad), cm.padName(pad), c.gst_event_type_get_name(cm.eventType(ev)), cm.eventType(ev), sstr, ev);
            c.g_free(sstr);
        }
        cm.unlock(s);
        notifyLast(s);
    }
    return parent.?.event.?(b, ev);
}

fn preroll(b: [*c]c.GstBaseSink, buffer: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    if (s.num_buffers_left == 0) return c.GST_FLOW_EOS;
    if (s.silent == 0) setLast(s, c.g_strdup_printf("preroll   ******* "));
    if (s.signal_handoffs != 0) c.g_signal_emit(s, sig_preroll, 0, buffer, b[0].sinkpad);
    return c.GST_FLOW_OK;
}

fn render(b: [*c]c.GstBaseSink, buffer: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    if (s.num_buffers_left == 0) return c.GST_FLOW_EOS;
    if (s.num_buffers_left != -1) s.num_buffers_left -= 1;
    if (s.silent == 0) {
        var dts: [64]u8 = undefined;
        var pts: [64]u8 = undefined;
        var dur: [64]u8 = undefined;
        const bf = cm.buf(buffer);
        const flags = cm.flagsString(buffer);
        const metas = cm.metaString(buffer);
        const pad = s.parent.sinkpad;
        cm.lock(s);
        c.g_free(s.last_message);
        s.last_message = c.g_strdup_printf("chain   ******* (%s:%s) (%u bytes, dts: %s, pts: %s, duration: %s, offset: %" ++ "li" ++ ", offset_end: %" ++ "li" ++ ", flags: %08x %s, meta: %s) %p", cm.padParentName(pad), cm.padName(pad), @as(c.guint, @truncate(c.gst_buffer_get_size(buffer))), cm.timeStr(&dts, bf.dts), cm.timeStr(&pts, bf.pts), cm.timeStr(&dur, bf.duration), bf.offset, bf.offset_end, bf.mini_object.flags, flags, if (metas != null) @as([*c]const u8, metas) else @as([*c]const u8, "none"), buffer);
        cm.unlock(s);
        c.g_free(flags);
        c.g_free(metas);
        notifyLast(s);
    }
    if (s.signal_handoffs != 0) c.g_signal_emit(s, sig_handoff, 0, buffer, b[0].sinkpad);
    if (s.dump != 0) {
        var info: c.GstMapInfo = undefined;
        if (c.gst_buffer_map(buffer, &info, c.GST_MAP_READ) != 0) {
            c.gst_util_dump_mem(info.data, @intCast(info.size));
            c.gst_buffer_unmap(buffer, &info);
        }
    }
    if (s.num_buffers_left == 0) return c.GST_FLOW_EOS;
    return c.GST_FLOW_OK;
}

fn query(b: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.queryType(q) == c.GST_QUERY_SEEKING) {
        var fmt: c.GstFormat = 0;
        c.gst_query_parse_seeking(q, &fmt, null, null, null);
        c.gst_query_set_seeking(q, fmt, 0, 0, -1);
        return 1;
    }
    return parent.?.query.?(b, q);
}

fn fail(el: [*c]c.GstElement) c.GstStateChangeReturn {
    cm.elementError(el, c.gst_core_error_quark(), c.GST_CORE_ERROR_STATE_CHANGE, null, c.g_strdup("Erroring out on state change as requested"), FILE, "gst_fake_sink_change_state", 600);
    return c.GST_STATE_CHANGE_FAILURE;
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(el);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => if (s.state_error == ERR_NULL_READY) return fail(el),
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            if (s.state_error == ERR_READY_PAUSED) return fail(el);
            s.num_buffers_left = s.num_buffers;
        },
        c.GST_STATE_CHANGE_PAUSED_TO_PLAYING => if (s.state_error == ERR_PAUSED_PLAYING) return fail(el),
        else => {},
    }
    const ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent.?))).change_state.?(el, t);
    switch (t) {
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => if (s.state_error == ERR_PLAYING_PAUSED) return fail(el),
        c.GST_STATE_CHANGE_PAUSED_TO_READY => if (s.state_error == ERR_PAUSED_READY) return fail(el),
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (s.state_error == ERR_READY_NULL) return fail(el);
            cm.lock(s);
            c.g_free(s.last_message);
            s.last_message = null;
            cm.unlock(s);
        },
        else => {},
    }
    return ret;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn boolProp(oc: *c.GObjectClass, id: c.guint, name: [*c]const u8, nick: [*c]const u8, blurb: [*c]const u8, def: bool, flags: c.GParamFlags) void {
    c.g_object_class_install_property(oc, id, c.g_param_spec_boolean(name, nick, blurb, @intFromBool(def), flags));
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.g_object_class_install_property(oc, PROP_STATE_ERROR, c.g_param_spec_enum("state-error", "State Error", "Generate a state change error", errorType(), ERR_NONE, cm.RW));
    pspec_last = c.g_param_spec_string("last-message", "Last Message", "The message describing current status", null, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS);
    c.g_object_class_install_property(oc, PROP_LAST_MESSAGE, pspec_last);
    boolProp(oc, PROP_SIGNAL_HANDOFFS, "signal-handoffs", "Signal handoffs", "Send a signal before unreffing the buffer", false, cm.RW);
    boolProp(oc, PROP_DROP_OUT_OF_SEGMENT, "drop-out-of-segment", "Drop out-of-segment buffers", "Drop and don't render / hand off out-of-segment buffers", true, cm.RW);
    boolProp(oc, PROP_SILENT, "silent", "Silent", "Don't produce last_message events", true, cm.RW | cm.MUTABLE_PLAYING);
    boolProp(oc, PROP_DUMP, "dump", "Dump", "Dump buffer contents to stdout", false, cm.RW | cm.MUTABLE_PLAYING);
    boolProp(oc, PROP_CAN_ACTIVATE_PUSH, "can-activate-push", "Can activate push", "Can activate in push mode", true, cm.RW);
    boolProp(oc, PROP_CAN_ACTIVATE_PULL, "can-activate-pull", "Can activate pull", "Can activate in pull mode", false, cm.RW);
    c.g_object_class_install_property(oc, PROP_NUM_BUFFERS, c.g_param_spec_int("num-buffers", "num-buffers", "Number of buffers to accept going EOS", -1, std.math.maxInt(c.gint), -1, cm.RW));
    const t = cm.typeOfClass(k);
    sig_handoff = c.g_signal_new("handoff", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "handoff"), null, null, null, c.G_TYPE_NONE, 2, c.gst_buffer_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE, c.gst_pad_get_type());
    sig_preroll = c.g_signal_new("preroll-handoff", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "preroll_handoff"), null, null, null, c.G_TYPE_NONE, 2, c.gst_buffer_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE, c.gst_pad_get_type());
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Fake Sink", "Sink", "Black hole for data", "Erik Walthinsen <omega@cse.ogi.edu>, Wim Taymans <wim@fluendo.com>, Mr. 'frag-me-more' Vanderwingo <wingo@fluendo.com>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    ec.change_state = changeState;
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.event = event;
    bc.preroll = preroll;
    bc.render = render;
    bc.query = query;
    c.gst_type_mark_as_plugin_api(errorType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.silent = 1;
    s.dump = 0;
    s.last_message = null;
    s.state_error = ERR_NONE;
    s.signal_handoffs = 0;
    s.num_buffers = -1;
    c.gst_base_sink_set_sync(bsink(s), 0);
    c.gst_base_sink_set_drop_out_of_segment(bsink(s), 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_sink_get_type(), "GstFakeSink", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("fakesink", 0, "fakesink element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "fakesink", c.GST_RANK_NONE, getType()) != 0;
}
