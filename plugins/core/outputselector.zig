const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstoutputselector.c";
const NONE = cm.CLOCK_NONE;
const PROP_ACTIVE_PAD = 1;
const PROP_RESEND_LATEST = 2;
const PROP_PAD_NEGOTIATION_MODE = 3;

const MODE_NONE = 0;
const MODE_ALL = 1;
const MODE_ACTIVE = 2;

const Self = extern struct {
    parent: c.GstElement,
    sinkpad: ?*c.GstPad,
    active_srcpad: ?*c.GstPad,
    pending_srcpad: ?*c.GstPad,
    nb_srcpads: c.guint,
    pad_negotiation_mode: c.gint,
    segment: c.GstSegment,
    segment_seqnum: u32,
    resend_latest: c.gboolean,
    latest_buffer: [*c]c.GstBuffer,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_REQUEST, "ANY");
var once: cm.Once = .{};
var mode_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;

var modes = [_]c.GEnumValue{
    .{ .value = MODE_NONE, .value_name = "None", .value_nick = "none" },
    .{ .value = MODE_ALL, .value_name = "All", .value_nick = "all" },
    .{ .value = MODE_ACTIVE, .value_name = "Active", .value_nick = "active" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn modeType() c.GType {
    return mode_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstOutputSelectorPadNegotiationMode", &modes);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn notifyActive(s: *Self) void {
    c.g_object_notify(@ptrCast(@alignCast(s)), "active-pad");
}

fn ref(p: anytype) @TypeOf(p) {
    return @ptrCast(@alignCast(c.gst_object_ref(p)));
}

fn active(s: *Self) ?*c.GstPad {
    cm.lock(s);
    defer cm.unlock(s);
    if (s.pending_srcpad) |p| return ref(p);
    if (s.active_srcpad) |p| return ref(p);
    return null;
}

fn dropLatest(s: *Self) void {
    if (s.latest_buffer != null) {
        c.gst_buffer_unref(s.latest_buffer);
        s.latest_buffer = null;
    }
}

fn reset(s: *Self) void {
    cm.lock(s);
    if (s.pending_srcpad) |p| {
        c.gst_object_unref(p);
        s.pending_srcpad = null;
    }
    dropLatest(s);
    s.segment_seqnum = c.GST_SEQNUM_INVALID;
    cm.unlock(s);
    c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_ACTIVE_PAD => {
            const next: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(v)));
            if (next) |n| {
                if (!cm.that(cm.pad(n).direction == c.GST_PAD_SRC, "gst_output_selector_set_property", "GST_PAD_IS_SRC (next_pad)")) return;
                if (!cm.that(cm.padParent(n) == @as(?*anyopaque, @ptrCast(s)), "gst_output_selector_set_property", "GST_PAD_PARENT (next_pad) == GST_ELEMENT_CAST (sel)")) return;
            }
            cm.lock(s);
            if (s.pending_srcpad) |p| c.gst_object_unref(p);
            s.pending_srcpad = null;
            if (next != s.active_srcpad) {
                if (next) |n| s.pending_srcpad = ref(n);
            }
            cm.unlock(s);
        },
        PROP_RESEND_LATEST => s.resend_latest = c.g_value_get_boolean(v),
        PROP_PAD_NEGOTIATION_MODE => s.pad_negotiation_mode = c.g_value_get_enum(v),
        else => cm.warnInvalid(FILE, o, id, spec, 265),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_ACTIVE_PAD => {
            cm.lock(s);
            c.g_value_set_object(v, if (s.pending_srcpad != null) s.pending_srcpad else s.active_srcpad);
            cm.unlock(s);
        },
        PROP_RESEND_LATEST => {
            cm.lock(s);
            c.g_value_set_boolean(v, s.resend_latest);
            cm.unlock(s);
        },
        PROP_PAD_NEGOTIATION_MODE => c.g_value_set_enum(v, s.pad_negotiation_mode),
        else => cm.warnInvalid(FILE, o, id, spec, 293),
    }
}

fn forwardSticky(_: ?*c.GstPad, ev: [*c][*c]c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    _ = c.gst_pad_push_event(@ptrCast(@alignCast(data)), @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev[0])))));
    return 1;
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    if (cm.eventType(ev) == c.GST_EVENT_SEEK) {
        const seq = c.gst_event_get_seqnum(ev);
        cm.lock(s);
        if (seq == s.segment_seqnum) {
            cm.unlock(s);
            c.gst_mini_object_unref(@ptrCast(ev));
            return 1;
        }
        s.segment_seqnum = seq;
        cm.unlock(s);
    }
    return c.gst_pad_event_default(pad, par, ev);
}

fn requestPad(el: [*c]c.GstElement, tmpl: [*c]c.GstPadTemplate, _: [*c]const u8, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(el);
    cm.lock(s);
    const name = c.g_strdup_printf("src_%u", s.nb_srcpads);
    s.nb_srcpads += 1;
    const p = c.gst_pad_new_from_template(tmpl, name);
    cm.unlock(s);
    c.gst_pad_set_event_function_full(p, srcEvent, null, null);
    _ = c.gst_pad_set_active(p, 1);
    c.gst_pad_sticky_events_foreach(s.sinkpad, forwardSticky, p);
    _ = c.gst_element_add_pad(el, p);
    cm.lock(s);
    if (s.active_srcpad == null) {
        s.active_srcpad = p;
        cm.unlock(s);
        notifyActive(s);
    } else cm.unlock(s);
    c.g_free(name);
    return p;
}

fn releasePad(el: [*c]c.GstElement, p: ?*c.GstPad) callconv(.c) void {
    const s = me(el);
    cm.lock(s);
    if (s.active_srcpad == p) {
        s.active_srcpad = null;
        cm.unlock(s);
        notifyActive(s);
    } else cm.unlock(s);
    _ = c.gst_pad_set_active(p, 0);
    _ = c.gst_element_remove_pad(el, p);
}

fn switchPad(s: *Self) void {
    cm.lock(s);
    const pending = s.pending_srcpad orelse {
        cm.unlock(s);
        return;
    };
    const linked = c.gst_pad_is_linked(pending) != 0;
    if (linked) s.active_srcpad = pending;
    c.gst_object_unref(pending);
    s.pending_srcpad = null;
    const target: ?*c.GstPad = if (linked) ref(s.active_srcpad.?) else null;
    cm.unlock(s);
    const t = target orelse return;
    notifyActive(s);
    cm.lock(s);
    const latest: [*c]c.GstBuffer = if (s.latest_buffer != null) @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(s.latest_buffer)))) else null;
    cm.unlock(s);
    c.gst_pad_sticky_events_foreach(s.sinkpad, forwardSticky, t);
    if (s.segment.format != c.GST_FORMAT_UNDEFINED) {
        if (s.resend_latest != 0 and latest != null and cm.buf(latest).pts != NONE) s.segment.position = cm.buf(latest).pts;
        _ = c.gst_pad_push_event(t, c.gst_event_new_segment(&s.segment));
    }
    if (latest != null) {
        if (s.resend_latest != 0) {
            _ = c.gst_pad_push(t, latest);
        } else c.gst_buffer_unref(latest);
    }
    c.gst_object_unref(t);
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    while (s.pending_srcpad != null) switchPad(s);
    const p = active(s) orelse {
        c.gst_buffer_unref(b);
        return c.GST_FLOW_OK;
    };
    cm.lock(s);
    dropLatest(s);
    if (s.resend_latest != 0) s.latest_buffer = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(b))));
    cm.unlock(s);
    var pos = cm.buf(b).pts;
    if (pos != NONE) {
        if (cm.buf(b).duration != NONE) pos +%= cm.buf(b).duration;
        s.segment.position = pos;
    }
    const r = c.gst_pad_push(p, b);
    c.gst_object_unref(p);
    return r;
}

fn toActive(s: *Self, ev: [*c]c.GstEvent) c.gboolean {
    const p = active(s) orelse {
        c.gst_mini_object_unref(@ptrCast(ev));
        return 1;
    };
    const r = c.gst_pad_push_event(p, ev);
    c.gst_object_unref(p);
    return r;
}

fn sinkEvent(_: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_EOS => return switch (s.pad_negotiation_mode) {
            MODE_ALL => c.gst_pad_event_default(s.sinkpad, par, ev),
            MODE_NONE => blk: {
                c.gst_mini_object_unref(@ptrCast(ev));
                break :blk 1;
            },
            else => toActive(s, ev),
        },
        c.GST_EVENT_SEGMENT => c.gst_event_copy_segment(ev, &s.segment),
        else => {},
    }
    return toActive(s, ev);
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.queryType(q)) {
        c.GST_QUERY_CAPS => switch (s.pad_negotiation_mode) {
            MODE_ALL => return c.gst_pad_proxy_query_caps(pad, q),
            MODE_NONE => return 0,
            else => {
                const p = active(s) orelse return 0;
                const r = c.gst_pad_peer_query(p, q);
                c.gst_object_unref(p);
                return r;
            },
        },
        c.GST_QUERY_DRAIN => dropLatest(s),
        else => {},
    }
    return c.gst_pad_query_default(pad, par, q);
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const r = parent.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) reset(me(el));
    return r;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    reset(me(o));
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_ACTIVE_PAD, c.g_param_spec_object("active-pad", "Active pad", "Currently active src pad", c.gst_pad_get_type(), cm.RW | cm.MUTABLE_PLAYING));
    c.g_object_class_install_property(oc, PROP_RESEND_LATEST, c.g_param_spec_boolean("resend-latest", "Resend latest buffer", "Resend latest buffer after a switch to a new pad", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_PAD_NEGOTIATION_MODE, c.g_param_spec_enum("pad-negotiation-mode", "Pad negotiation mode", "The mode to be used for pad negotiation", modeType(), MODE_ALL, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Output selector", "Generic", "1-to-N output stream selector", "Stefan Kost <stefan.kost@nokia.com>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    ec.change_state = changeState;
    c.gst_type_mark_as_plugin_api(modeType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(s.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(s.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(s.sinkpad, sinkQuery, null, null);
    _ = c.gst_element_add_pad(element(s), s.sinkpad);
    s.active_srcpad = null;
    s.nb_srcpads = 0;
    c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED);
    s.pending_srcpad = null;
    s.resend_latest = 0;
    s.latest_buffer = null;
    s.pad_negotiation_mode = MODE_ALL;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstOutputSelector", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("output-selector", 0, "Output stream selector");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "output-selector", c.GST_RANK_NONE, getType()) != 0;
}
