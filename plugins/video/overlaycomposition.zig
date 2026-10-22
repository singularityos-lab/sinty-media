const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FEATURE = "meta:GstVideoOverlayComposition";
const SIZES = ", width = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", height = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE;
const BLEND_CAPS = "video/x-raw, format = (string) " ++ c.GST_VIDEO_OVERLAY_COMPOSITION_BLEND_FORMATS ++ SIZES;
const ALL_CAPS = BLEND_CAPS ++ ";video/x-raw(ANY), format = (string) " ++ c.GST_VIDEO_FORMATS_ANY ++ SIZES;

const SIG_CAPS_CHANGED = 0;
const SIG_DRAW = 1;

const Self = extern struct {
    parent: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    sample: ?*c.GstSample,
    segment: c.GstSegment,
    caps: [*c]c.GstCaps,
    info: c.GstVideoInfo,
    window_width: c.guint,
    window_height: c.guint,
    attach: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, ALL_CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, ALL_CAPS);
var blend_caps = c.GstStaticCaps{ .caps = null, .string = BLEND_CAPS, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var signals: [2]c.guint = .{ 0, 0 };
var once: cm.Once = .{};
var parent_class: ?*c.GstElementClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn canBlend(caps: [*c]c.GstCaps) bool {
    const b = c.gst_static_caps_get(&blend_caps);
    defer c.gst_caps_unref(b);
    return c.gst_caps_is_subset(caps, b) != 0;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    const ret = parent_class.?.change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED),
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            s.info = std.mem.zeroes(c.GstVideoInfo);
            s.window_width = 0;
            s.window_height = 0;
            s.attach = 0;
            if (s.sample) |x| c.gst_sample_unref(x);
            s.sample = null;
            _ = c.gst_caps_replace(&s.caps, null);
            c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED);
        },
        else => {},
    }
    return ret;
}

fn isFlushing(p: ?*c.GstPad) bool {
    return cm.obj(p).flags & c.GST_PAD_FLAG_FLUSHING != 0;
}

fn negotiate(s: *Self, caps_in: [*c]c.GstCaps) bool {
    _ = c.gst_pad_check_reconfigure(s.srcpad);
    s.window_width = 0;
    s.window_height = 0;
    const caps = if (caps_in == null) c.gst_pad_get_current_caps(s.sinkpad) else c.gst_caps_ref(caps_in);
    if (caps == null or c.gst_caps_is_empty(caps) != 0) {
        if (caps != null) c.gst_caps_unref(caps);
        c.gst_pad_mark_reconfigure(s.srcpad);
        return false;
    }
    var upstream_meta = false;
    var caps_meta = false;
    var alloc_meta = false;
    var ret = true;
    if (c.gst_caps_get_features(caps, 0)) |f| upstream_meta = c.gst_caps_features_contains(f, FEATURE) != 0;
    var width: c.guint = @intCast(s.info.width);
    var height: c.guint = @intCast(s.info.height);
    var overlay: [*c]c.GstCaps = null;
    if (upstream_meta) {
        overlay = c.gst_caps_ref(caps);
    } else {
        overlay = c.gst_caps_copy(caps);
        c.gst_caps_features_add(c.gst_caps_get_features(overlay, 0), FEATURE);
        const peer = c.gst_pad_peer_query_caps(s.srcpad, overlay);
        caps_meta = c.gst_caps_is_empty(peer) == 0;
        c.gst_caps_unref(peer);
    }
    if (upstream_meta or caps_meta) {
        ret = cm.setCaps(s.srcpad, overlay);
        const q = c.gst_query_new_allocation(overlay, 0);
        if (c.gst_pad_peer_query(s.srcpad, q) == 0) {
            if (isFlushing(s.srcpad)) ret = false;
        }
        var idx: c.guint = 0;
        alloc_meta = c.gst_query_find_allocation_meta(q, c.gst_video_overlay_composition_meta_api_get_type(), &idx) != 0;
        if (alloc_meta) {
            var params: ?*const c.GstStructure = null;
            _ = c.gst_query_parse_nth_allocation_meta(q, idx, &params);
            if (params != null and c.gst_structure_get(params, "width", c.G_TYPE_UINT, &width, "height", c.G_TYPE_UINT, &height, @as(?*anyopaque, null)) != 0) {
                if (width == 0 or height == 0) c.g_assertion_message_expr(null, "../gst/overlaycomposition/gstoverlaycomposition.c", 308, "gst_overlay_composition_negotiate", "width != 0 && height != 0");
            }
        }
        c.gst_query_unref(q);
    }
    s.window_width = width;
    s.window_height = height;
    var attach = false;
    if (upstream_meta) {
        attach = true;
    } else if (caps_meta) {
        attach = if (alloc_meta) true else !canBlend(caps);
    } else ret = canBlend(caps);
    if (!attach and ret) ret = cm.setCaps(s.srcpad, caps);
    s.attach = @intFromBool(attach);
    if (!ret) c.gst_pad_mark_reconfigure(s.srcpad);
    c.g_signal_emit(s, signals[SIG_CAPS_CHANGED], 0, caps, s.window_width, s.window_height, @as(?*anyopaque, null));
    c.gst_caps_unref(overlay);
    c.gst_caps_unref(caps);
    return ret;
}

fn sinkEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(parent);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(ev, &s.segment);
            return c.gst_pad_event_default(pad, parent, ev);
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            defer c.gst_event_unref(ev);
            if (c.gst_video_info_from_caps(&s.info, caps) == 0) return 0;
            if (!negotiate(s, caps)) return 0;
            _ = c.gst_caps_replace(&s.caps, caps);
            return 1;
        },
        c.GST_EVENT_FLUSH_STOP => {
            c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED);
            return c.gst_pad_event_default(pad, parent, ev);
        },
        else => return c.gst_pad_event_default(pad, parent, ev),
    }
}

fn addFeature(caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const out = c.gst_caps_copy(caps);
    const n = c.gst_caps_get_size(out);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const f = c.gst_caps_get_features(out, i);
        if (c.gst_caps_features_is_any(f) == 0) c.gst_caps_features_add(f, FEATURE);
    }
    c.gst_caps_append(out, c.gst_caps_intersect_full(caps, filter, c.GST_CAPS_INTERSECT_FIRST));
    return out;
}

fn byFeature(caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const out = c.gst_caps_new_empty();
    const n = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const st = c.gst_caps_get_structure(caps, i);
        const f = c.gst_caps_features_copy(c.gst_caps_get_features(caps, i));
        const simple = c.gst_caps_new_full(c.gst_structure_copy(st), @as(?*anyopaque, null));
        c.gst_caps_set_features(simple, 0, f);
        var filtered: [*c]c.GstCaps = null;
        if (c.gst_caps_features_contains(f, FEATURE) != 0) {
            c.gst_caps_append(out, c.gst_caps_copy(simple));
            c.gst_caps_features_remove(f, FEATURE);
            filtered = c.gst_caps_ref(simple);
        } else filtered = c.gst_caps_intersect_full(simple, filter, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(simple);
        c.gst_caps_append(out, filtered);
    }
    return out;
}

fn queryCaps(s: *Self, filter: [*c]c.GstCaps, from_sink: bool) [*c]c.GstCaps {
    const here = if (from_sink) s.sinkpad else s.srcpad;
    const there = if (from_sink) s.srcpad else s.sinkpad;
    var ofilter: [*c]c.GstCaps = null;
    if (filter != null) {
        const sw = c.gst_static_caps_get(&blend_caps);
        ofilter = if (from_sink) addFeature(filter, sw) else byFeature(filter, sw);
        c.gst_caps_unref(sw);
    }
    const peer = c.gst_pad_peer_query_caps(there, ofilter);
    if (ofilter != null) c.gst_caps_unref(ofilter);
    var caps: [*c]c.GstCaps = null;
    if (peer != null) {
        if (c.gst_caps_is_any(peer) != 0) {
            const t = c.gst_pad_get_pad_template_caps(there);
            caps = c.gst_caps_copy(t);
            c.gst_caps_unref(t);
        } else {
            const sw = c.gst_static_caps_get(&blend_caps);
            caps = if (from_sink) byFeature(peer, sw) else addFeature(peer, sw);
            c.gst_caps_unref(sw);
        }
        c.gst_caps_unref(peer);
    } else caps = c.gst_pad_get_pad_template_caps(here);
    if (filter != null) {
        const i = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = i;
    }
    return caps;
}

fn padQuery(pad: ?*c.GstPad, parent: [*c]c.GstObject, q: [*c]c.GstQuery, from_sink: bool) c.gboolean {
    if (cm.queryType(q) != c.GST_QUERY_CAPS) return c.gst_pad_query_default(pad, parent, q);
    var filter: [*c]c.GstCaps = null;
    c.gst_query_parse_caps(q, &filter);
    const caps = queryCaps(me(parent), filter, from_sink);
    c.gst_query_set_caps_result(q, caps);
    c.gst_caps_unref(caps);
    return 1;
}

fn sinkQuery(pad: ?*c.GstPad, parent: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    return padQuery(pad, parent, q, true);
}

fn srcQuery(pad: ?*c.GstPad, parent: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    return padQuery(pad, parent, q, false);
}

fn chain(_: ?*c.GstPad, parent: [*c]c.GstObject, b_in: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(parent);
    var b = b_in;
    if (c.gst_pad_check_reconfigure(s.srcpad) != 0) {
        if (!negotiate(s, null)) {
            c.gst_pad_mark_reconfigure(s.srcpad);
            c.gst_buffer_unref(b);
            cm.lock(s.srcpad);
            defer cm.unlock(s.srcpad);
            return if (isFlushing(s.srcpad)) c.GST_FLOW_FLUSHING else c.GST_FLOW_NOT_NEGOTIATED;
        }
    }
    if (s.sample == null) {
        s.sample = c.gst_sample_new(b, s.caps, &s.segment, null);
    } else {
        s.sample = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(s.sample)))));
        c.gst_sample_set_buffer(s.sample, b);
        c.gst_sample_set_caps(s.sample, s.caps);
        c.gst_sample_set_segment(s.sample, &s.segment);
    }
    var compo: ?*c.GstVideoOverlayComposition = null;
    c.g_signal_emit(s, signals[SIG_DRAW], 0, s.sample, &compo);
    if (c.gst_mini_object_is_writable(@ptrCast(@alignCast(s.sample))) != 0) c.gst_sample_set_buffer(s.sample, null);
    const co = compo orelse return c.gst_pad_push(s.srcpad, b);
    b = c.gst_buffer_make_writable(b);
    if (s.attach != 0) {
        _ = c.gst_buffer_add_video_overlay_composition_meta(b, co);
        c.gst_mini_object_unref(@ptrCast(@alignCast(co)));
    } else {
        var frame: c.GstVideoFrame = undefined;
        if (c.gst_video_frame_map(&frame, &s.info, b, c.GST_MAP_READWRITE) == 0) {
            c.gst_mini_object_unref(@ptrCast(@alignCast(co)));
            c.gst_buffer_unref(b);
            return c.GST_FLOW_ERROR;
        }
        _ = c.gst_video_overlay_composition_blend(co, &frame);
        c.gst_video_frame_unmap(&frame);
        c.gst_mini_object_unref(@ptrCast(@alignCast(co)));
    }
    return c.gst_pad_push(s.srcpad, b);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("overlaycomposition", 0, "Overlay Composition");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Overlay Composition", "Filter/Editor/Video", "Overlay Composition", "Sebastian Dröge <sebastian@centricular.com>");
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&src_t));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&sink_t));
    ec.change_state = changeState;
    const t = cm.typeOfClass(k);
    signals[SIG_DRAW] = c.g_signal_new("draw", t, 0, 0, null, null, null, c.gst_video_overlay_composition_get_type(), 1, c.gst_sample_get_type());
    signals[SIG_CAPS_CHANGED] = c.g_signal_new("caps-changed", t, 0, 0, null, null, null, c.G_TYPE_NONE, 3, c.gst_caps_get_type(), c.G_TYPE_UINT, c.G_TYPE_UINT);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const e: [*c]c.GstElement = @ptrCast(@alignCast(inst));
    s.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(s.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(s.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(s.sinkpad, sinkQuery, null, null);
    cm.setPadFlag(s.sinkpad, c.GST_PAD_FLAG_PROXY_ALLOCATION);
    _ = c.gst_element_add_pad(e, s.sinkpad);
    s.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_query_function_full(s.srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(e, s.srcpad);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstOverlayComposition", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "overlaycomposition", c.GST_RANK_NONE, getType()) != 0;
}
