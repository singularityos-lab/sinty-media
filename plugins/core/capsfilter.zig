const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstcapsfilter.c";
const DOMAIN = "gstreamer-1.0";

const IMMEDIATE = 0;
const DELAYED = 1;

const PROP_CAPS = 1;
const PROP_MODE = 2;

const Self = extern struct {
    parent: c.GstBaseTransform,
    filter_caps: [*c]c.GstCaps,
    used: c.gboolean,
    mode: c.gint,
    got_sink_caps: c.gboolean,
    previous: ?*c.GList,
    pending: ?*c.GList,
};

const Class = extern struct {
    parent: c.GstBaseTransformClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");

var once: cm.Once = .{};
var mode_once: cm.Once = .{};
var parent: ?*c.GstBaseTransformClass = null;

var modes = [_]c.GEnumValue{
    .{ .value = IMMEDIATE, .value_name = "Only accept the current filter caps", .value_nick = "immediate" },
    .{ .value = DELAYED, .value_name = "Temporarily accept previous filter caps", .value_nick = "delayed" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn modeType() c.GType {
    return mode_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstCapsFilterCapsChangeMode", &modes);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn trans(p: anytype) [*c]c.GstBaseTransform {
    return @ptrCast(@alignCast(p));
}

fn dropPrevious(s: *Self) void {
    c.g_list_free_full(s.previous, cm.unrefCaps);
    s.previous = null;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_CAPS => {
            const val = c.gst_value_get_caps(v);
            const new: [*c]c.GstCaps = if (val == null) c.gst_caps_new_any() else c.gst_caps_ref(@constCast(val));
            cm.lock(s);
            const old = s.filter_caps;
            s.filter_caps = new;
            if (old != null and s.used != 0 and s.mode == DELAYED) {
                s.previous = c.g_list_prepend(s.previous, c.gst_caps_ref(old));
            } else if (s.mode != DELAYED) dropPrevious(s);
            s.used = 0;
            cm.unlock(s);
            c.gst_caps_unref(old);
            c.gst_base_transform_reconfigure_sink(trans(s));
        },
        PROP_MODE => {
            cm.lock(s);
            const old = s.mode;
            s.mode = c.g_value_get_enum(v);
            if (s.mode != old) dropPrevious(s);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 238),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_CAPS => {
            cm.lock(s);
            c.gst_value_set_caps(v, s.filter_caps);
            cm.unlock(s);
        },
        PROP_MODE => c.g_value_set_enum(v, s.mode),
        else => cm.warnInvalid(FILE, o, id, spec, 259),
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    _ = c.gst_caps_replace(&s.filter_caps, null);
    c.g_list_free_full(s.pending, cm.unrefEvent);
    s.pending = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn mergePrevious(s: *Self) [*c]c.GstCaps {
    var r = c.gst_caps_new_empty();
    var l = s.previous;
    while (l) |n| : (l = n.next) r = c.gst_caps_merge(r, c.gst_caps_ref(@ptrCast(@alignCast(n.data))));
    return r;
}

fn transformCaps(t: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(t);
    cm.lock(s);
    var fcaps = c.gst_caps_ref(s.filter_caps);
    s.used = 1;
    const mode = s.mode;
    cm.unlock(s);
    var retried = false;
    while (true) {
        if (filter != null) {
            const tmp = c.gst_caps_intersect_full(filter, fcaps, c.GST_CAPS_INTERSECT_FIRST);
            c.gst_caps_unref(fcaps);
            fcaps = tmp;
        }
        const r = c.gst_caps_intersect_full(fcaps, caps, c.GST_CAPS_INTERSECT_FIRST);
        if (c.gst_caps_is_empty(r) != 0 and mode == DELAYED and s.previous != null and !retried) {
            cm.lock(s);
            c.gst_caps_unref(fcaps);
            c.gst_caps_unref(r);
            fcaps = mergePrevious(s);
            cm.unlock(s);
            retried = true;
            continue;
        }
        c.gst_caps_unref(fcaps);
        return r;
    }
}

fn acceptCaps(t: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(t);
    cm.lock(s);
    const fcaps = c.gst_caps_ref(s.filter_caps);
    s.used = 1;
    cm.unlock(s);
    var ok = c.gst_caps_can_intersect(caps, fcaps) != 0;
    if (!ok and s.mode == DELAYED) {
        cm.lock(s);
        var l = s.previous;
        while (l) |n| : (l = n.next) {
            if (c.gst_caps_can_intersect(caps, @ptrCast(@alignCast(n.data))) != 0) {
                ok = true;
                break;
            }
        }
        cm.unlock(s);
        if (ok) c.gst_base_transform_reconfigure_sink(t);
    }
    c.gst_caps_unref(fcaps);
    return @intFromBool(ok);
}

fn transformIp(_: [*c]c.GstBaseTransform, _: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return c.GST_FLOW_OK;
}

fn forward(s: *Self, events: ?*c.GList) void {
    var l: ?*c.GList = c.g_list_last(events);
    while (l) |n| : (l = n.prev) _ = parent.?.sink_event.?(trans(s), @ptrCast(@alignCast(n.data)));
    c.g_list_free(events);
}

fn prepareBuf(t: [*c]c.GstBaseTransform, input: [*c]c.GstBuffer, buf: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(t);
    buf[0] = input;
    if (cm.pad(t[0].srcpad).mode == c.GST_PAD_MODE_PUSH and s.got_sink_caps == 0) {
        var pending = s.pending;
        s.pending = null;
        var out = c.gst_pad_get_current_caps(t[0].srcpad);
        if (out == null) {
            out = c.gst_pad_get_allowed_caps(t[0].srcpad);
            if (!cm.that(out != null, "gst_capsfilter_prepare_buf", "out_caps != NULL")) return c.GST_FLOW_ERROR;
        }
        out = c.gst_caps_simplify(out);
        if (c.gst_caps_is_fixed(out) != 0 and c.gst_caps_is_empty(out) == 0) {
            var ret: c.GstFlowReturn = c.GST_FLOW_OK;
            if (c.gst_pad_has_current_caps(t[0].srcpad) == 0) {
                if (cm.setCaps(t[0].srcpad, out)) {
                    if (pending != null) {
                        forward(s, pending);
                        pending = null;
                    }
                } else ret = c.GST_FLOW_NOT_NEGOTIATED;
            } else {
                forward(s, pending);
                pending = null;
            }
            c.g_list_free_full(pending, cm.unrefEvent);
            c.gst_caps_unref(out);
            return ret;
        }
        const str = c.gst_caps_to_string(out);
        c.gst_caps_unref(out);
        cm.elementError(t, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, c.g_strdup(cm.tr(DOMAIN, "Filter caps do not completely specify the output format")), c.g_strdup_printf("Output caps are unfixed: %s", str), FILE, "gst_capsfilter_prepare_buf", 458);
        c.g_free(str);
        c.g_list_free_full(pending, cm.unrefEvent);
        return c.GST_FLOW_ERROR;
    }
    if (s.pending != null) {
        const events = s.pending;
        s.pending = null;
        forward(s, events);
    }
    return c.GST_FLOW_OK;
}

fn sinkEvent(t: [*c]c.GstBaseTransform, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(t);
    const et = cm.eventType(ev);
    if (et == c.GST_EVENT_FLUSH_STOP) {
        var l: ?*c.GList = s.pending;
        while (l) |n| : (l = n.next) {
            const pt = cm.eventType(n.data);
            if (pt == c.GST_EVENT_SEGMENT or pt == c.GST_EVENT_EOS) {
                c.gst_mini_object_unref(@ptrCast(@alignCast(n.data)));
                s.pending = c.g_list_delete_link(s.pending, n);
                break;
            }
        }
    }
    const sticky = (@as(c.guint, @bitCast(et)) & c.GST_EVENT_TYPE_STICKY) != 0;
    if (sticky and et > c.GST_EVENT_CAPS) {
        if (et == c.GST_EVENT_EOS) {
            const events = s.pending;
            s.pending = null;
            forward(s, events);
        } else if (s.got_sink_caps == 0) {
            s.pending = c.g_list_prepend(s.pending, ev);
            return 1;
        }
    }
    const r = parent.?.sink_event.?(t, @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev)))));
    if (et == c.GST_EVENT_CAPS) {
        s.got_sink_caps = 1;
        if (s.mode == DELAYED) {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            cm.lock(s);
            var l: ?*c.GList = c.g_list_last(s.previous);
            while (l) |n| : (l = n.prev) {
                if (c.gst_caps_can_intersect(caps, @ptrCast(@alignCast(n.data))) != 0) {
                    var k: *c.GList = n;
                    while (k.next != null) {
                        const nx: *c.GList = k.next;
                        c.gst_mini_object_unref(@ptrCast(@alignCast(nx.data)));
                        k = c.g_list_delete_link(k, nx);
                    }
                    break;
                }
            }
            if (l == null and c.gst_caps_can_intersect(caps, s.filter_caps) != 0) {
                dropPrevious(s);
                s.used = 1;
            }
            cm.unlock(s);
        }
    }
    c.gst_mini_object_unref(@ptrCast(ev));
    return r;
}

fn stop(t: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(t);
    c.g_list_free_full(s.pending, cm.unrefEvent);
    s.pending = null;
    cm.lock(s);
    dropPrevious(s);
    cm.unlock(s);
    s.got_sink_caps = 0;
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    c.g_object_class_install_property(oc, PROP_CAPS, c.g_param_spec_boxed("caps", cm.tr(DOMAIN, "Filter caps"), cm.tr(DOMAIN, "Restrict the possible allowed capabilities (NULL means ANY). Setting this property takes a reference to the supplied GstCaps object."), c.gst_caps_get_type(), c.G_PARAM_READWRITE | cm.MUTABLE_PLAYING | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_MODE, c.g_param_spec_enum("caps-change-mode", cm.tr(DOMAIN, "Caps Change Mode"), cm.tr(DOMAIN, "Filter caps change behaviour"), modeType(), IMMEDIATE, c.G_PARAM_READWRITE | cm.MUTABLE_PLAYING | c.G_PARAM_STATIC_STRINGS));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "CapsFilter", "Generic", "Pass data without modification, limiting formats", "David Schleef <ds@schleef.org>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.transform_caps = transformCaps;
    tc.transform_ip = transformIp;
    tc.accept_caps = acceptCaps;
    tc.prepare_output_buffer = prepareBuf;
    tc.sink_event = sinkEvent;
    tc.stop = stop;
    c.gst_type_mark_as_plugin_api(modeType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.gst_base_transform_set_gap_aware(trans(s), 1);
    c.gst_base_transform_set_prefer_passthrough(trans(s), 0);
    s.filter_caps = c.gst_caps_new_any();
    s.used = 0;
    s.got_sink_caps = 0;
    s.mode = IMMEDIATE;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_transform_get_type(), "GstCapsFilter", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("capsfilter", 0, "capsfilter element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "capsfilter", c.GST_RANK_NONE, getType()) != 0;
}
