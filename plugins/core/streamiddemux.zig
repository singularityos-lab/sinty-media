const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gststreamiddemux.c";
const DOMAIN = "gstreamer-1.0";
const PROP_ACTIVE_PAD = 1;

const Self = extern struct {
    parent: c.GstElement,
    sinkpad: ?*c.GstPad,
    nb_srcpads: c.guint,
    active_srcpad: ?*c.GstPad,
    pairs: ?*c.GHashTable,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn unrefObject(p: c.gpointer) callconv(.c) void {
    c.gst_object_unref(p);
}

fn table() ?*c.GHashTable {
    return c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, unrefObject);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const d = me(o);
    switch (id) {
        PROP_ACTIVE_PAD => {
            cm.lock(d);
            c.g_value_set_object(v, d.active_srcpad);
            cm.unlock(d);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 172),
    }
}

fn forwardSticky(_: ?*c.GstPad, ev: [*c][*c]c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    _ = c.gst_pad_push_event(@ptrCast(@alignCast(data)), @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev[0])))));
    return 1;
}

fn newPad(d: *Self, id: [*c]const u8) bool {
    const name = c.g_strdup_printf("src_%u", d.nb_srcpads);
    d.nb_srcpads += 1;
    const tmpl = c.gst_static_pad_template_get(&src_t);
    const p = c.gst_pad_new_from_template(tmpl, name);
    c.gst_object_unref(tmpl);
    c.g_free(name);
    if (!cm.that(p != null, "gst_streamid_demux_srcpad_create", "srcpad != NULL")) return false;
    d.active_srcpad = p;
    if (d.pairs == null) d.pairs = table();
    _ = c.g_hash_table_insert(d.pairs, c.g_strdup(id), c.gst_object_ref(p));
    return true;
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const d = me(par);
    cm.lock(d);
    const p = d.active_srcpad orelse {
        cm.unlock(d);
        return c.GST_FLOW_NOT_NEGOTIATED;
    };
    _ = c.gst_object_ref(p);
    cm.unlock(d);
    const r = c.gst_pad_push(p, b);
    c.gst_object_unref(p);
    return r;
}

fn fail(d: *Self, ev: [*c]c.GstEvent, code: c.gint, text: [*c]const u8, dbg: [*c]u8, line: c.gint) c.gboolean {
    cm.elementError(d, c.gst_stream_error_quark(), code, c.g_strdup(cm.tr(DOMAIN, text)), dbg, FILE, "gst_streamid_demux_event", line);
    c.gst_mini_object_unref(@ptrCast(ev));
    return 0;
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const d = me(par);
    const t = cm.eventType(ev);
    if (t == c.GST_EVENT_STREAM_START) {
        var id: [*c]const u8 = null;
        c.gst_event_parse_stream_start(ev, &id);
        if (id == null) return fail(d, ev, c.GST_STREAM_ERROR_DEMUX, "Error occurred trying to get stream-id to create a srcpad", c.g_strdup_printf("no stream-id found at %s", c.gst_event_type_get_name(t)), 330);
        cm.lock(d);
        const found: ?*c.GstPad = if (d.pairs != null) @ptrCast(@alignCast(c.g_hash_table_lookup(d.pairs, id))) else null;
        if (found == null) {
            if (!newPad(d, id)) {
                cm.unlock(d);
                return fail(d, ev, c.GST_STREAM_ERROR_FAILED, "Error occurred trying to create a srcpad", c.g_strdup_printf("Failed to create a srcpad via stream-id:%s", id), 340);
            }
            cm.unlock(d);
            _ = c.gst_pad_set_active(d.active_srcpad, 1);
            c.gst_pad_sticky_events_foreach(d.sinkpad, forwardSticky, d.active_srcpad);
            _ = c.gst_element_add_pad(element(d), d.active_srcpad);
        } else if (d.active_srcpad != found) {
            d.active_srcpad = found;
            cm.unlock(d);
            c.g_object_notify(@ptrCast(@alignCast(d)), "active-pad");
        } else cm.unlock(d);
    }
    if (t == c.GST_EVENT_FLUSH_START or t == c.GST_EVENT_FLUSH_STOP or t == c.GST_EVENT_EOS) return c.gst_pad_event_default(pad, par, ev);
    if (d.active_srcpad != null) {
        cm.lock(d);
        const p = c.gst_object_ref(d.active_srcpad);
        cm.unlock(d);
        const r = c.gst_pad_push_event(@ptrCast(@alignCast(p)), ev);
        c.gst_object_unref(p);
        return r;
    }
    c.gst_mini_object_unref(@ptrCast(ev));
    return 1;
}

fn release(item: [*c]const c.GValue, data: c.gpointer) callconv(.c) void {
    const p: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(item)));
    if (p == null) return;
    _ = c.gst_pad_set_active(p, 0);
    _ = c.gst_element_remove_pad(element(data), p);
}

fn reset(d: *Self) void {
    cm.lock(d);
    d.active_srcpad = null;
    d.nb_srcpads = 0;
    cm.unlock(d);
    if (d.pairs != null) {
        c.g_hash_table_unref(d.pairs);
        d.pairs = null;
    }
    const it = c.gst_element_iterate_src_pads(element(d));
    var r: c.GstIteratorResult = c.GST_ITERATOR_OK;
    while (r == c.GST_ITERATOR_OK or r == c.GST_ITERATOR_RESYNC) {
        r = c.gst_iterator_foreach(it, release, d);
        if (r == c.GST_ITERATOR_RESYNC) c.gst_iterator_resync(it);
    }
    c.gst_iterator_free(it);
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
    oc.get_property = getProperty;
    oc.dispose = dispose;
    c.g_object_class_install_property(oc, PROP_ACTIVE_PAD, c.g_param_spec_object("active-pad", "Active pad", "The currently active src pad", c.gst_pad_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Streamid Demux", "Generic", "1-to-N output stream by stream-id", "HoonHee Lee <hoonhee.lee@lge.com>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.change_state = changeState;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const d = me(inst);
    d.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(d.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(d.sinkpad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(element(d), d.sinkpad);
    d.active_srcpad = null;
    d.nb_srcpads = 0;
    d.pairs = table();
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstStreamidDemux", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("streamiddemux", 0, "Streamid demuxer");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "streamiddemux", c.GST_RANK_PRIMARY, getType()) != 0;
}
