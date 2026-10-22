const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const Pad = extern struct {
    parent: cm.Pad,
    is_eos: c.gboolean,
};

const PadClass = extern struct {
    parent: c.GstPadClass,
};

const Self = extern struct {
    parent: c.GstElement,
    srcpad: ?*c.GstPad,
    lock: c.GMutex,
    current: ?*c.GstPad,
    sinkpads: [*c]c.GList,
    cookie: u32,
    draining_encoder: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent: ?*c.GObjectClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn cpad(p: anytype) *Pad {
    return @ptrCast(@alignCast(p));
}

fn padClassInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    cpad(inst).is_eos = 0;
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_pad_get_type(), "GstStreamCombinerPad", PadClass, Pad, padClassInit, padInit);
        }
    }.f);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&me(o).lock);
    parent.?.finalize.?(o);
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return c.gst_pad_push(me(par).srcpad, b);
}

fn allEos(s: *Self) bool {
    var l = s.sinkpads;
    while (l != null) : (l = l.*.next) {
        if (cpad(l.*.data).is_eos == 0) return false;
    }
    return true;
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, e_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    var e = e_in;
    switch (cm.eventType(e)) {
        c.GST_EVENT_CUSTOM_DOWNSTREAM => {
            c.g_mutex_lock(&s.lock);
            if (c.gst_structure_has_name(c.gst_event_get_structure(e), "start-draining-encoder") != 0) s.draining_encoder = 1;
            c.g_mutex_unlock(&s.lock);
        },
        c.GST_EVENT_FLUSH_START => {
            c.g_mutex_lock(&s.lock);
            if (s.draining_encoder != 0) {
                c.gst_event_unref(e);
                e = null;
            }
            c.g_mutex_unlock(&s.lock);
        },
        c.GST_EVENT_FLUSH_STOP => {
            c.g_mutex_lock(&s.lock);
            if (s.draining_encoder != 0) {
                c.gst_event_unref(e);
                e = null;
            }
            s.draining_encoder = 0;
            c.g_mutex_unlock(&s.lock);
        },
        c.GST_EVENT_EOS => {
            c.g_mutex_lock(&s.lock);
            if (s.draining_encoder != 0) {
                c.g_mutex_unlock(&s.lock);
                c.gst_event_unref(e);
                return 0;
            }
            cpad(pad).is_eos = 1;
            if (!allEos(s)) {
                c.gst_event_unref(e);
                e = null;
            }
            c.g_mutex_unlock(&s.lock);
        },
        else => {},
    }
    if (e != null) return c.gst_pad_push_event(s.srcpad, e);
    return 0;
}

fn sinkQuery(_: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    return c.gst_pad_peer_query(me(par).srcpad, q);
}

fn currentSink(s: *Self) ?*c.GstPad {
    c.g_mutex_lock(&s.lock);
    defer c.g_mutex_unlock(&s.lock);
    if (s.current) |p| return p;
    if (s.sinkpads != null) return @ptrCast(s.sinkpads.*.data);
    return null;
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (c.gst_video_event_is_force_key_unit(e) != 0) return c.gst_pad_event_default(pad, par, e);
    if (currentSink(me(par))) |sp| return c.gst_pad_push_event(sp, e);
    return 0;
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.queryType(q) == c.GST_QUERY_CAPS) return c.gst_pad_query_default(pad, par, q);
    if (currentSink(me(par))) |sp| return c.gst_pad_peer_query(sp, q);
    return 0;
}

fn requestNewPad(el: [*c]c.GstElement, _: [*c]c.GstPadTemplate, name: [*c]const u8, _: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(el);
    const templ = c.gst_element_class_get_pad_template(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(el)).g_class)), "sink_%u");
    const p: ?*c.GstPad = @ptrCast(c.g_object_new(padType(), "name", name, "template", templ, "direction", templ.*.direction, @as(?*anyopaque, null)));
    c.gst_pad_set_chain_function_full(p, chain, null, null);
    c.gst_pad_set_event_function_full(p, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(p, sinkQuery, null, null);
    c.g_mutex_lock(&s.lock);
    s.sinkpads = c.g_list_append(s.sinkpads, p);
    _ = c.gst_pad_set_active(p, 1);
    _ = c.gst_element_add_pad(el, p);
    s.cookie +%= 1;
    c.g_mutex_unlock(&s.lock);
    return p;
}

fn releasePad(el: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(el);
    c.g_mutex_lock(&s.lock);
    defer c.g_mutex_unlock(&s.lock);
    const l = c.g_list_find(s.sinkpads, pad);
    if (l == null) return;
    const p: ?*c.GstPad = @ptrCast(l.*.data);
    s.sinkpads = c.g_list_delete_link(s.sinkpads, l);
    s.cookie +%= 1;
    if (p == s.current) s.current = null;
    _ = c.gst_element_remove_pad(el, p);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
    _ = c._gst_debug_category_new("streamcombiner", 0, "Stream Combiner");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    c.gst_element_class_set_static_metadata(ec, "streamcombiner", "Generic", "Recombines streams split by the streamsplitter element", "Edward Hervey <edward.hervey@collabora.co.uk>");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_event_function_full(s.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(s.srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
    c.g_mutex_init(&s.lock);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstStreamCombiner", Class, Self, classInit, init);
        }
    }.f);
}

pub fn new(name: [*c]const u8) [*c]c.GstElement {
    return @ptrCast(@alignCast(c.g_object_new(getType(), "name", name, @as(?*anyopaque, null))));
}
