const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const spec = @import("spec.zig");

const FILE = "../plugins/tracers/gstlatency.c";
const N: ?*anyopaque = null;
const PIPELINE = 1 << 0;
const ELEMENT = 1 << 1;
const REPORTED = 1 << 2;
const PROP_FLAGS = 1;

const Self = extern struct {
    parent: c.GstTracer,
    flags: c.guint,
};

const Class = extern struct {
    parent: c.GstTracerClass,
};

const Entry = extern struct {
    peer_element: ?*c.GstElement,
    min: u64,
    max: u64,
};

var once: cm.Once = .{};
var flags_type: c.GType = 0;
var probe_id: c.GQuark = 0;
var sub_probe_id: c.GQuark = 0;
var drop_quark: c.GQuark = 0;
var tr_latency: ?*c.GstTracerRecord = null;
var tr_element: ?*c.GstTracerRecord = null;
var tr_reported: ?*c.GstTracerRecord = null;
var stack_key: c.GPrivate = .{ .p = null, .notify = destroyStack, .future = .{ null, null } };

const flag_values = [_]c.GFlagsValue{
    .{ .value = PIPELINE, .value_name = "Trace pipeline latency", .value_nick = "pipeline" },
    .{ .value = ELEMENT, .value_name = "Trace per-element latency", .value_nick = "element" },
    .{ .value = REPORTED, .value_name = "Trace reported element latency", .value_nick = "reported" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn flagsType() c.GType {
    if (flags_type == 0) flags_type = c.g_flags_register_static("GstLatencyTracerFlags", &flag_values);
    return flags_type;
}

fn obj(p: anytype) *c.GstObject {
    return @ptrCast(@alignCast(p));
}

fn hasFlag(p: anytype, f: c.guint) bool {
    return obj(p).flags & f != 0;
}

fn isBin(p: anytype) bool {
    return cm.isA(p, c.gst_bin_get_type());
}

fn realParent(p: ?*c.GstPad) ?*c.GstElement {
    if (p == null) return null;
    var parent = c.gst_object_get_parent(obj(p));
    if (parent != null and cm.isA(parent, c.gst_ghost_pad_get_type())) {
        const tmp = c.gst_object_get_parent(parent);
        c.gst_object_unref(parent);
        parent = tmp;
    }
    return @ptrCast(@alignCast(parent));
}

fn freeEntry(p: c.gpointer) callconv(.c) void {
    const v: *Entry = @ptrCast(@alignCast(p));
    if (v.peer_element) |e| c.gst_object_unref(e);
    v.peer_element = null;
    c.g_free(v);
}

fn destroyStack(p: c.gpointer) callconv(.c) void {
    c.g_queue_free_full(@ptrCast(@alignCast(p)), freeEntry);
}

fn stack() [*c]c.GQueue {
    var q: [*c]c.GQueue = @ptrCast(@alignCast(c.g_private_get(&stack_key)));
    if (q == null) {
        c.g_private_set(&stack_key, c.g_queue_new());
        q = @ptrCast(@alignCast(c.g_private_get(&stack_key)));
    }
    return q;
}

fn pop() ?*Entry {
    return @ptrCast(@alignCast(c.g_queue_pop_tail(stack())));
}

fn ptrStr(p: anytype) [*c]u8 {
    return c.g_strdup_printf("%p", @as(?*anyopaque, @ptrCast(p)));
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn strField(d: ?*const c.GstStructure, f: [*:0]const u8) [*c]const u8 {
    return c.g_value_get_string(c.gst_structure_get_value(d, f));
}

fn logLatency(d: ?*const c.GstStructure, sink_parent: ?*c.GstElement, sink_pad: ?*c.GstPad, sink_ts: u64) void {
    if (!cm.that(sink_parent != null, "log_latency", "sink_parent")) return;
    if (!cm.that(sink_pad != null, "log_latency", "sink_pad")) return;
    const src_ts = c.g_value_get_uint64(c.gst_structure_get_value(d, "latency_probe.ts"));
    const src = strField(d, "latency_probe.pad");
    const el_src = strField(d, "latency_probe.element");
    const id_src = strField(d, "latency_probe.element_id");
    const id_sink = ptrStr(sink_parent);
    const el_sink = c.gst_object_get_name(obj(sink_parent));
    const sink = c.gst_object_get_name(obj(sink_pad));
    c.gst_tracer_record_log(tr_latency, id_src, el_src, src, id_sink, el_sink, sink, diff(src_ts, sink_ts), sink_ts);
    c.g_free(sink);
    c.g_free(el_sink);
    c.g_free(id_sink);
}

fn logElementLatency(d: ?*const c.GstStructure, parent: ?*c.GstElement, p: ?*c.GstPad, sink_ts: u64) void {
    if (!cm.that(parent != null, "log_element_latency", "parent")) return;
    if (!cm.that(p != null, "log_element_latency", "pad")) return;
    const id = ptrStr(parent);
    const name = c.gst_object_get_name(obj(parent));
    const pname = c.gst_object_get_name(obj(p));
    const src_ts = c.g_value_get_uint64(c.gst_structure_get_value(d, "latency_probe.ts"));
    c.gst_tracer_record_log(tr_element, id, name, pname, diff(src_ts, sink_ts), sink_ts);
    c.g_free(pname);
    c.g_free(name);
    c.g_free(id);
}

fn probeEvent(name: [*:0]const u8, el: ?*c.GstElement, p: ?*c.GstPad, ts: u64) [*c]c.GstEvent {
    const id = ptrStr(el);
    const en = c.gst_object_get_name(obj(el));
    const pn = c.gst_object_get_name(obj(p));
    const ev = c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new_static_str(name, "latency_probe.element_id", c.G_TYPE_STRING, id, "latency_probe.element", c.G_TYPE_STRING, en, "latency_probe.pad", c.G_TYPE_STRING, pn, "latency_probe.ts", c.G_TYPE_UINT64, ts, N));
    c.g_free(pn);
    c.g_free(en);
    c.g_free(id);
    return ev;
}

fn sendProbe(self: *Self, parent: ?*c.GstElement, p: ?*c.GstPad, ts: u64) void {
    const peer_pad = c.gst_pad_get_peer(p);
    const peer_parent = realParent(peer_pad);
    if (peer_pad != null and (parent == null or !isBin(parent))) {
        if (parent != null and self.flags & PIPELINE != 0 and hasFlag(parent, c.GST_ELEMENT_FLAG_SOURCE)) {
            _ = c.gst_pad_push_event(p, probeEvent("latency_probe.id", parent, p, ts));
        }
        if (peer_parent != null and self.flags & ELEMENT != 0) {
            _ = c.gst_pad_push_event(p, probeEvent("sub_latency_probe.id", peer_parent, peer_pad, ts));
        }
    }
    if (peer_pad != null) c.gst_object_unref(peer_pad);
    if (peer_parent != null) c.gst_object_unref(peer_parent);
}

fn calculate(parent: ?*c.GstElement, p: ?*c.GstPad, ts: u64) void {
    if (parent == null or isBin(parent) or hasFlag(parent, c.GST_ELEMENT_FLAG_SOURCE)) return;
    const peer_pad = c.gst_pad_get_peer(p);
    const peer_parent = realParent(peer_pad);
    if (peer_pad != null and peer_parent != null and hasFlag(peer_parent, c.GST_ELEMENT_FLAG_SINK)) {
        const ev: [*c]c.GstEvent = @ptrCast(@alignCast(c.g_object_get_qdata(@ptrCast(@alignCast(p)), probe_id)));
        if (ev != null) {
            logLatency(c.gst_event_get_structure(ev), peer_parent, peer_pad, ts);
            c.g_object_set_qdata(@ptrCast(@alignCast(p)), probe_id, null);
        }
    }
    const ev: [*c]c.GstEvent = @ptrCast(@alignCast(c.g_object_get_qdata(@ptrCast(@alignCast(p)), sub_probe_id)));
    if (ev != null) {
        logElementLatency(c.gst_event_get_structure(ev), parent, p, ts);
        c.g_object_set_qdata(@ptrCast(@alignCast(p)), sub_probe_id, null);
    }
    if (peer_pad != null) c.gst_object_unref(peer_pad);
    if (peer_parent != null) c.gst_object_unref(peer_parent);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn pushPre(t: ?*anyopaque, ts: u64, p: ?*c.GstPad) callconv(.c) void {
    const parent = realParent(p);
    sendProbe(me(t), parent, p, ts);
    calculate(parent, p, ts);
    if (parent != null) c.gst_object_unref(parent);
}

fn pullPre(t: ?*anyopaque, ts: u64, p: ?*c.GstPad) callconv(.c) void {
    const pp: ?*c.GstPad = @ptrCast(cm.pad(p).peer);
    const parent = realParent(pp);
    sendProbe(me(t), parent, pp, ts);
    if (parent != null) c.gst_object_unref(parent);
}

fn pullPost(_: ?*anyopaque, ts: u64, p: ?*c.GstPad) callconv(.c) void {
    const parent = realParent(p);
    calculate(parent, p, ts);
    if (parent != null) c.gst_object_unref(parent);
}

fn dropSub(p: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const ev: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
    var ret: c.GstPadProbeReturn = c.GST_PAD_PROBE_OK;
    if (cm.eventType(ev) != c.GST_EVENT_CUSTOM_DOWNSTREAM) return ret;
    const d = c.gst_event_get_structure(ev);
    if (c.gst_structure_has_name(d, "sub_latency_probe.id") == 0) return ret;
    const peer_pad = c.gst_pad_get_peer(p);
    const peer_parent = realParent(peer_pad);
    const id = ptrStr(peer_parent);
    const pname: [*c]u8 = if (peer_pad != null) c.gst_object_get_name(obj(peer_pad)) else null;
    const vid = strField(d, "latency_probe.element_id");
    const vpad = strField(d, "latency_probe.pad");
    if (pname == null or c.g_str_equal(vid, id) == 0 or c.g_str_equal(vpad, pname) == 0) ret = c.GST_PAD_PROBE_DROP;
    c.g_free(pname);
    c.g_free(id);
    if (peer_pad != null) c.gst_object_unref(peer_pad);
    if (peer_parent != null) c.gst_object_unref(peer_parent);
    return ret;
}

fn eventPre(_: ?*anyopaque, _: u64, p: ?*c.GstPad, ev: [*c]c.GstEvent) callconv(.c) void {
    const parent = realParent(p);
    defer if (parent != null) c.gst_object_unref(parent);
    if (parent == null or isBin(parent) or hasFlag(parent, c.GST_ELEMENT_FLAG_SOURCE) or cm.eventType(ev) != c.GST_EVENT_CUSTOM_DOWNSTREAM) return;
    const d = c.gst_event_get_structure(ev);
    const peer_pad = c.gst_pad_get_peer(p);
    const peer_parent = realParent(peer_pad);
    const pg: [*c]c.GObject = @ptrCast(@alignCast(p));
    if (c.gst_structure_has_name(d, "latency_probe.id") != 0) {
        if (c.g_object_get_qdata(pg, drop_quark) == null) {
            _ = c.gst_pad_add_probe(p, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, dropSub, null, null);
            c.g_object_set_qdata(pg, drop_quark, @ptrFromInt(1));
        }
        if (peer_parent == null or hasFlag(peer_parent, c.GST_ELEMENT_FLAG_SINK)) c.g_object_set_qdata_full(pg, probe_id, c.gst_event_ref(ev), cm.unrefEvent);
    }
    if (c.gst_structure_has_name(d, "sub_latency_probe.id") != 0) {
        const id = ptrStr(peer_parent);
        const pname: [*c]u8 = if (peer_pad != null) c.gst_object_get_name(obj(peer_pad)) else null;
        const vid = strField(d, "latency_probe.element_id");
        const vpad = strField(d, "latency_probe.pad");
        if (c.g_str_equal(vid, id) == 0 or c.g_strcmp0(vpad, pname) != 0) c.g_object_set_qdata_full(pg, sub_probe_id, c.gst_event_ref(ev), cm.unrefEvent);
        c.g_free(pname);
        c.g_free(id);
    }
    if (peer_pad != null) c.gst_object_unref(peer_pad);
    if (peer_parent != null) c.gst_object_unref(peer_parent);
}

fn queryPost(t: ?*anyopaque, ts: u64, p: ?*c.GstPad, q: [*c]c.GstQuery, _: c.gboolean) callconv(.c) void {
    const self = me(t);
    if (self.flags & REPORTED == 0 or cm.queryType(q) != c.GST_QUERY_LATENCY) return;
    const el = realParent(p);
    const peer_pad = c.gst_pad_get_peer(p);
    const peer_el = realParent(peer_pad);
    if (el == null or peer_el == null or peer_pad == null) {
        while (pop()) |v| freeEntry(v);
        return;
    }
    var live: c.gboolean = 0;
    var min: u64 = 0;
    var max: u64 = 0;
    var min_prev: u64 = 0;
    var max_prev: u64 = 0;
    c.gst_query_parse_latency(q, &live, &min, &max);
    var v = pop();
    while (v != null and v.?.peer_element == el) {
        min_prev = @max(v.?.min, min_prev);
        max_prev = @max(v.?.max, max_prev);
        freeEntry(v.?);
        v = pop();
    }
    if (v) |x| freeEntry(x);
    const n: *Entry = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Entry))));
    n.peer_element = @ptrCast(@alignCast(c.gst_object_ref(peer_el)));
    n.min = min;
    n.max = max;
    c.g_queue_push_tail(stack(), n);
    const id = ptrStr(el);
    const name = c.gst_object_get_name(obj(el));
    c.gst_tracer_record_log(tr_reported, id, name, live, diff(min_prev, min), diff(max_prev, max), ts);
    c.g_free(name);
    c.g_free(id);
    c.gst_object_unref(peer_pad);
    c.gst_object_unref(peer_el);
    c.gst_object_unref(el);
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec_: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_FLAGS) {
        c.g_value_set_flags(v, me(ob).flags);
    } else cm.warnInvalid(FILE, ob, id, spec_, 579);
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec_: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_FLAGS) {
        me(ob).flags = c.g_value_get_flags(v);
    } else cm.warnInvalid(FILE, ob, id, spec_, 595);
}

fn scopeStr(rel: c.GstTracerValueScope) [*c]c.GstStructure {
    return spec.scope(c.G_TYPE_STRING, rel);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_tracer_class_set_use_structure_params(@ptrCast(@alignCast(k)), 1);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.get_property = getProperty;
    gc.set_property = setProperty;
    c.g_object_class_install_property(gc, PROP_FLAGS, c.g_param_spec_flags("flags", "Flags", "Flags to control what latency measurements to perform", flagsType(), PIPELINE, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS));
    probe_id = c.g_quark_from_static_string("latency_probe.id");
    sub_probe_id = c.g_quark_from_static_string("sub_latency_probe.id");
    drop_quark = c.g_quark_from_static_string("drop_sub_latency.quark");
    const S = c.gst_structure_get_type();
    const EL = c.GST_TRACER_VALUE_SCOPE_ELEMENT;
    const PAD = c.GST_TRACER_VALUE_SCOPE_PAD;
    const time = "time it took for the buffer to go from src to sink ns";
    tr_latency = c.gst_tracer_record_new("latency.class", "src-element-id", S, scopeStr(EL), "src-element", S, scopeStr(EL), "src", S, scopeStr(PAD), "sink-element-id", S, scopeStr(EL), "sink-element", S, scopeStr(EL), "sink", S, scopeStr(PAD), "time", S, spec.u64Range(time), "ts", S, spec.u64Range("ts when the latency has been logged"), N);
    tr_element = c.gst_tracer_record_new("element-latency.class", "element-id", S, scopeStr(EL), "element", S, scopeStr(EL), "src", S, scopeStr(PAD), "time", S, spec.u64Range(time), "ts", S, spec.u64Range("ts when the latency has been logged"), N);
    tr_reported = c.gst_tracer_record_new("element-reported-latency.class", "element-id", S, scopeStr(EL), "element", S, scopeStr(EL), "live", S, spec.value(c.G_TYPE_BOOLEAN, "wether the it is a live stream or not"), "min", S, spec.u64Range("the minimum reported latency"), "max", S, spec.u64Range("the maximum reported latency"), "ts", S, spec.u64Range("ts when the latency has been reported"), N);
    spec.maybeLeaked(tr_latency);
    spec.maybeLeaked(tr_element);
    spec.maybeLeaked(tr_reported);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    me(inst).flags = PIPELINE;
    spec.hook(inst, "pad-push-pre", &pushPre);
    spec.hook(inst, "pad-push-list-pre", &pushPre);
    spec.hook(inst, "pad-pull-range-pre", &pullPre);
    spec.hook(inst, "pad-pull-range-post", &pullPost);
    spec.hook(inst, "pad-push-event-pre", &eventPre);
    spec.hook(inst, "pad-query-post", &queryPost);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            _ = c._gst_debug_category_new("latency", 0, "latency tracer");
            return cm.register(c.gst_tracer_get_type(), "GstLatencyTracer", Class, Self, classInit, init);
        }
    }.f);
}
