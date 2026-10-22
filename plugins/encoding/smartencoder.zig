const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/encoding/gstsmartencoder.c";
const CAPS = "video/x-h263;video/x-intel-h263;video/x-vp8;video/x-vp9;video/x-h264;video/x-h265;video/mpeg,mpegversion=(int)1,systemstream=(boolean)false;video/mpeg,mpegversion=(int)2,systemstream=(boolean)false;";
const OUTPUT_START: u64 = 60 * 60 * c.GST_SECOND * 1000;

pub const Self = extern struct {
    parent: c.GstBin,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    internal_sinkpad: ?*c.GstPad,
    internal_srcpad: ?*c.GstPad,
    internal_flow_lock: c.GMutex,
    internal_flow_cond: c.GCond,
    internal_flow: c.GstFlowReturn,
    encoder: [*c]c.GstElement,
    decoder: [*c]c.GstElement,
    original_caps: [*c]c.GstCaps,
    push_original_caps: c.gboolean,
    segment_event: [*c]c.GstEvent,
    stream_start_event: [*c]c.GstEvent,
    input_segment: c.GstSegment,
    internal_segment: c.GstSegment,
    output_segment: c.GstSegment,
    gop_start: u64,
    gop_stop: u64,
    pending_gop: [*c]c.GList,
    last_dts: u64,
};

const Class = extern struct {
    parent: c.GstBinClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;

pub fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn ownerOf(o: [*c]c.GstObject) *Self {
    return me(o.*.parent);
}

fn clearEvent(e: *[*c]c.GstEvent) void {
    if (e.* != null) c.gst_event_unref(e.*);
    e.* = null;
}

fn reset(s: *Self) void {
    c.gst_segment_init(&s.internal_segment, c.GST_FORMAT_UNDEFINED);
    c.gst_segment_init(&s.input_segment, c.GST_FORMAT_UNDEFINED);
    c.gst_segment_init(&s.output_segment, c.GST_FORMAT_UNDEFINED);
    if (s.decoder != null) {
        _ = c.gst_element_set_state(s.encoder, c.GST_STATE_NULL);
        _ = c.gst_element_set_state(s.decoder, c.GST_STATE_NULL);
        if (s.internal_srcpad) |p| c.gst_object_unref(p);
        s.internal_srcpad = null;
        _ = c.gst_element_remove_pad(@ptrCast(s), s.internal_sinkpad);
        _ = c.gst_bin_remove(@ptrCast(s), @ptrCast(@alignCast(c.gst_object_ref(s.encoder))));
        _ = c.gst_bin_remove(@ptrCast(s), s.decoder);
        s.decoder = null;
        s.internal_sinkpad = null;
    }
    clearEvent(&s.segment_event);
}

fn toSrc(s: *Self, ts: *u64) void {
    var rt: u64 = 0;
    if (c.gst_segment_to_running_time_full(&s.internal_segment, c.GST_FORMAT_TIME, ts.*, &rt) > 0) {
        ts.* = rt +% s.output_segment.start;
    } else ts.* = s.output_segment.start -% rt;
}

fn finishBuffer(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    const bb = cm.buf(b);
    if (bb.dts == cm.CLOCK_NONE) bb.dts = bb.pts;
    toSrc(s, &bb.pts);
    toSrc(s, &bb.dts);
    if (s.last_dts > bb.dts) bb.dts = s.last_dts +% 1;
    s.last_dts = bb.dts;
    return c.gst_pad_push(s.srcpad, b);
}

fn pushOutputSegment(s: *Self, comptime func: []const u8, line: c.gint) bool {
    if (s.output_segment.format != c.GST_FORMAT_UNDEFINED) return true;
    c.gst_segment_init(&s.output_segment, c.GST_FORMAT_TIME);
    s.output_segment.start = OUTPUT_START;
    if (c.gst_pad_push_event(s.srcpad, c.gst_event_new_segment(&s.output_segment)) == 0) {
        cm.flowError(s, c.GST_FLOW_ERROR, FILE, func, line);
        return false;
    }
    return true;
}

fn internalEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.eventType(e)) {
        c.GST_EVENT_EOS => {
            c.g_mutex_lock(&s.internal_flow_lock);
            if (s.internal_flow == c.GST_FLOW_CUSTOM_SUCCESS) s.internal_flow = c.GST_FLOW_OK;
            c.g_cond_signal(&s.internal_flow_cond);
            c.g_mutex_unlock(&s.internal_flow_lock);
        },
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(e, &s.internal_segment);
            if (!pushOutputSegment(s, "internal_event_func", 138)) return 0;
        },
        c.GST_EVENT_CAPS => return c.gst_pad_push_event(s.srcpad, e),
        else => {},
    }
    return c.gst_pad_event_default(pad, par, e);
}

fn internalChain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return finishBuffer(me(par), b);
}

fn padAdded(_: [*c]c.GstElement, srcpad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const sink: ?*c.GstPad = @ptrCast(s.encoder.*.sinkpads.*.data);
    if (c.gst_pad_link(srcpad, sink) != c.GST_PAD_LINK_OK) {
        c.g_mutex_lock(&s.internal_flow_lock);
        s.internal_flow = c.GST_FLOW_NOT_LINKED;
        c.g_mutex_unlock(&s.internal_flow_lock);
    }
}

fn setupRecoder(s: *Self) bool {
    if (s.decoder != null) return true;
    s.decoder = c.gst_element_factory_make("decodebin", null);
    if (s.decoder == null) return false;
    _ = c.g_signal_connect_data(s.decoder, "pad-added", @ptrCast(&padAdded), s, null, 0);
    _ = c.gst_element_set_locked_state(s.decoder, 1);
    _ = c.gst_bin_add(@ptrCast(s), s.decoder);
    _ = c.gst_bin_add(@ptrCast(s), @ptrCast(@alignCast(c.gst_object_ref(s.encoder))));
    s.internal_srcpad = c.gst_pad_new("internal_src", c.GST_PAD_SRC);
    s.internal_sinkpad = c.gst_pad_new("internal_sink", c.GST_PAD_SINK);
    c.gst_pad_set_iterate_internal_links_function_full(s.internal_sinkpad, null, null, null);
    if (c.gst_element_add_pad(@ptrCast(s), s.internal_sinkpad) == 0) return false;
    c.gst_pad_set_chain_function_full(s.internal_sinkpad, internalChain, null, null);
    c.gst_pad_set_event_function_full(s.internal_sinkpad, internalEvent, null, null);
    _ = c.gst_pad_set_active(s.internal_sinkpad, 1);
    _ = c.gst_pad_set_active(s.internal_srcpad, 1);
    const capsfilter = c.gst_element_factory_make("capsfilter", null);
    if (c.gst_bin_add(@ptrCast(s), capsfilter) == 0) return false;
    _ = c.gst_element_sync_state_with_parent(capsfilter);
    if (c.gst_element_link(s.encoder, capsfilter) == 0) return false;
    var tmp = c.gst_element_get_static_pad(capsfilter, "src");
    if (c.gst_pad_link_full(tmp, s.internal_sinkpad, c.GST_PAD_LINK_CHECK_NOTHING) < c.GST_PAD_LINK_OK) {
        c.gst_object_unref(tmp);
        return false;
    }
    c.gst_object_unref(tmp);
    tmp = c.gst_element_get_static_pad(s.decoder, "sink");
    if (c.gst_pad_link_full(s.internal_srcpad, tmp, c.GST_PAD_LINK_CHECK_NOTHING) < c.GST_PAD_LINK_OK) {
        c.gst_object_unref(tmp);
        return false;
    }
    c.gst_object_unref(tmp);
    return true;
}

fn freePending(s: *Self) void {
    c.g_list_free_full(s.pending_gop, @ptrCast(&c.gst_mini_object_unref));
    s.pending_gop = null;
}

fn reencodeGop(s: *Self) c.GstFlowReturn {
    if (s.decoder == null and !setupRecoder(s)) return c.GST_FLOW_ERROR;
    _ = c.gst_element_set_state(s.encoder, c.GST_STATE_PLAYING);
    _ = c.gst_element_set_state(s.decoder, c.GST_STATE_PLAYING);
    _ = c.gst_pad_push_event(s.internal_srcpad, c.gst_event_new_flush_start());
    _ = c.gst_pad_push_event(s.internal_srcpad, c.gst_event_new_flush_stop(1));
    _ = c.gst_pad_push_event(s.internal_srcpad, c.gst_event_ref(s.stream_start_event));
    const caps = c.gst_pad_get_current_caps(s.sinkpad);
    _ = c.gst_pad_push_event(s.internal_srcpad, c.gst_event_new_caps(caps));
    c.gst_caps_unref(caps);
    _ = c.gst_pad_push_event(s.internal_srcpad, c.gst_event_ref(s.segment_event));
    c.g_mutex_lock(&s.internal_flow_lock);
    s.internal_flow = c.GST_FLOW_CUSTOM_SUCCESS;
    c.g_mutex_unlock(&s.internal_flow_lock);
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    while (s.pending_gop != null) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(s.pending_gop.*.data));
        s.pending_gop = c.g_list_remove_link(s.pending_gop, s.pending_gop);
        res = c.gst_pad_push(s.internal_srcpad, b);
        if (res == c.GST_FLOW_EOS) break;
        if (res != c.GST_FLOW_OK) {
            freePending(s);
            return res;
        }
    }
    _ = c.gst_pad_push_event(s.internal_srcpad, c.gst_event_new_eos());
    c.g_mutex_lock(&s.internal_flow_lock);
    while (s.internal_flow == c.GST_FLOW_CUSTOM_SUCCESS) c.g_cond_wait(&s.internal_flow_cond, &s.internal_flow_lock);
    c.g_mutex_unlock(&s.internal_flow_lock);
    res = s.internal_flow;
    _ = c.gst_element_set_state(s.encoder, c.GST_STATE_NULL);
    _ = c.gst_element_set_state(s.decoder, c.GST_STATE_NULL);
    cm.obj(s.internal_sinkpad).flags &= ~@as(c.guint, c.GST_PAD_FLAG_EOS);
    cm.obj(s.internal_srcpad).flags &= ~@as(c.guint, c.GST_PAD_FLAG_EOS);
    freePending(s);
    return res;
}

fn forceReencoding(s: *Self) bool {
    const st = c.gst_caps_get_structure(s.original_caps, 0);
    if (c.gst_structure_has_name(st, "video/x-vp9") == 0) return false;
    const profile = c.gst_structure_get_string(st, "profile");
    if (profile == null) return true;
    return c.g_strcmp0(profile, "0") != 0 and c.g_strcmp0(profile, "2") != 0;
}

fn pushPendingGop(s: *Self) c.GstFlowReturn {
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    defer {
        c.g_list_free(s.pending_gop);
        s.pending_gop = null;
        s.gop_start = cm.CLOCK_NONE;
        s.gop_stop = 0;
    }
    if (s.pending_gop == null) return res;
    var cs: u64 = 0;
    var ce: u64 = 0;
    if (c.gst_segment_clip(&s.input_segment, c.GST_FORMAT_TIME, s.gop_start, s.gop_stop, &cs, &ce) == 0) {
        var l = s.pending_gop;
        while (l != null) : (l = l.*.next) c.gst_buffer_unref(@ptrCast(@alignCast(l.*.data)));
        return res;
    }
    const force = forceReencoding(s);
    if (cs != s.gop_start or ce != s.gop_stop or force) {
        res = reencodeGop(s);
        if (!force) s.push_original_caps = 1;
        return res;
    }
    if (s.push_original_caps != 0) {
        _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_caps(s.original_caps));
        s.push_original_caps = 0;
    }
    if (!pushOutputSegment(s, "gst_smart_encoder_push_pending_gop", 448)) return c.GST_FLOW_ERROR;
    s.internal_segment = s.input_segment;
    var l = s.pending_gop;
    while (l != null) : (l = l.*.next) {
        res = finishBuffer(s, @ptrCast(@alignCast(l.*.data)));
        if (res != c.GST_FLOW_OK) break;
    }
    return res;
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = ownerOf(par);
    const bb = cm.buf(b);
    const flags = @as(*c.GstMiniObject, @ptrCast(b)).flags;
    const keyframe = flags & c.GST_BUFFER_FLAG_DELTA_UNIT == 0;
    var end = bb.pts;
    if (end != cm.CLOCK_NONE) end +%= if (bb.duration != cm.CLOCK_NONE) bb.duration else 0;
    if (keyframe) {
        if (s.pending_gop != null) {
            if (bb.pts != cm.CLOCK_NONE) s.gop_stop = bb.pts;
            const res = pushPendingGop(s);
            if (res != c.GST_FLOW_OK) return res;
        }
        s.gop_start = bb.pts;
    }
    s.pending_gop = c.g_list_append(s.pending_gop, b);
    if (end != cm.CLOCK_NONE) s.gop_stop = @max(s.gop_stop, end);
    return c.GST_FLOW_OK;
}

fn getCaps(original: [*c]c.GstCaps) [*c]c.GstCaps {
    const ost = c.gst_caps_get_structure(original, 0);
    if (c.gst_structure_has_name(ost, "video/x-vp8") == 0) return c.gst_caps_ref(original);
    var caps = c.gst_caps_copy(original);
    var st = c.gst_caps_get_structure(caps, 0);
    c.gst_structure_set_name(st, "video/x-raw");
    c.gst_structure_set(st, "format", c.G_TYPE_STRING, "I420", "multiview-mode", c.G_TYPE_STRING, "mono", "multiview-flags", c.gst_video_multiview_flagset_get_type(), @as(c.guint, c.GST_VIDEO_MULTIVIEW_FLAGS_NONE), @as(c.guint, c.GST_FLAG_SET_MASK_EXACT), @as(?*anyopaque, null));
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&info, caps);
    c.gst_caps_unref(caps);
    caps = c.gst_video_info_to_caps(&info);
    st = c.gst_caps_get_structure(caps, 0);
    const outcaps = c.gst_caps_copy(original);
    const out = c.gst_caps_get_structure(outcaps, 0);
    for ([_][*:0]const u8{ "pixel-aspect-ratio", "framerate", "interlace-mode", "colorimetry", "chroma-site", "multiview-mode", "multiview-flags" }) |field| {
        if (c.gst_structure_has_field(ost, field) == 0) {
            const v = c.gst_structure_get_value(st, field);
            if (v == null) c.g_assertion_message_expr(null, FILE, 585, "smart_encoder_get_caps", "v");
            c.gst_structure_set_value(out, field, v);
        }
    }
    c.gst_caps_unref(caps);
    return outcaps;
}

fn sinkEvent(_: ?*c.GstPad, par: [*c]c.GstObject, e_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = ownerOf(par);
    var e = e_in;
    switch (cm.eventType(e)) {
        c.GST_EVENT_FLUSH_STOP => reset(s),
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            if (s.original_caps != null) c.gst_caps_unref(s.original_caps);
            s.original_caps = getCaps(caps);
            s.push_original_caps = 1;
            clearEvent(&e);
        },
        c.GST_EVENT_STREAM_START => _ = c.gst_mini_object_replace(@ptrCast(&s.stream_start_event), @ptrCast(c.gst_event_ref(e))),
        c.GST_EVENT_SEGMENT => {
            _ = pushPendingGop(s);
            c.gst_event_copy_segment(e, &s.input_segment);
            if (s.input_segment.format != c.GST_FORMAT_TIME) {
                c.gst_event_unref(e);
                return 0;
            }
            s.segment_event = e;
            e = null;
        },
        c.GST_EVENT_EOS => if (s.input_segment.format == c.GST_FORMAT_TIME) {
            _ = pushPendingGop(s);
        },
        else => {},
    }
    if (e != null) return c.gst_pad_push_event(s.srcpad, e);
    return 1;
}

fn sinkGetCaps(s: *Self, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const tmpl = c.gst_static_pad_template_get_caps(&src_t);
    const peer = c.gst_pad_peer_query_caps(s.srcpad, tmpl);
    var res: [*c]c.GstCaps = undefined;
    if (peer == null) {
        res = tmpl;
    } else {
        res = peer;
        c.gst_caps_unref(tmpl);
    }
    if (filter != null) {
        const f = c.gst_caps_intersect(res, filter);
        c.gst_caps_unref(res);
        res = if (f == null or c.gst_caps_is_empty(f) != 0) null else f;
    }
    return res;
}

fn stripFields(caps: [*c]c.GstCaps) void {
    for (0..c.gst_caps_get_size(caps)) |i| {
        const st = c.gst_caps_get_structure(caps, @intCast(i));
        if (c.gst_structure_has_name(st, "video/x-h264") != 0 or c.gst_structure_has_name(st, "video/x-h265") != 0) {
            c.gst_structure_remove_fields(st, "codec_data", "tier", "profile", "level", @as(?*anyopaque, null));
        } else if (c.gst_structure_has_name(st, "video/x-vp8") != 0 or c.gst_structure_has_name(st, "video/x-vp9") != 0) {
            c.gst_structure_remove_field(st, "streamheader");
        }
    }
}

fn acceptCaps(s: *Self, caps: [*c]c.GstCaps) bool {
    var accepted = c.gst_pad_get_current_caps(s.srcpad);
    if (accepted == null) accepted = c.gst_pad_get_pad_template_caps(s.srcpad);
    accepted = c.gst_caps_make_writable(accepted);
    stripFields(accepted);
    const modified = c.gst_caps_copy(caps);
    stripFields(modified);
    return c.gst_caps_can_intersect(modified, accepted) != 0;
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = ownerOf(par);
    switch (cm.queryType(q)) {
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            const caps = sinkGetCaps(s, filter);
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(q, &caps);
            c.gst_query_set_accept_caps_result(q, @intFromBool(acceptCaps(s, caps)));
            return 1;
        },
        else => return c.gst_pad_query_default(pad, par, q),
    }
}

fn addParser(s: *Self, format: [*c]c.GstCaps) bool {
    const st = c.gst_caps_get_structure(format, 0);
    const capsfilter = c.gst_element_factory_make("capsfilter", null);
    _ = c.gst_bin_add(@ptrCast(s), capsfilter);
    c.g_object_set(capsfilter, "caps", format, @as(?*anyopaque, null));
    var parser: [*c]c.GstElement = null;
    var sinkpad: ?*c.GstPad = null;
    if (c.gst_structure_has_name(st, "video/x-h264") != 0) {
        parser = c.gst_element_factory_make("h264parse", null);
        if (parser == null) return false;
        if (c.g_strcmp0(c.gst_structure_get_string(st, "stream-format"), "avc") != 0) c.g_object_set(parser, "config-interval", @as(c.gint, -1), @as(?*anyopaque, null));
    } else if (c.gst_structure_has_name(st, "video/x-h265") != 0) {
        parser = c.gst_element_factory_make("h265parse", null);
        if (parser == null) return false;
        if (c.g_strcmp0(c.gst_structure_get_string(st, "stream-format"), "hvc1") != 0) c.g_object_set(parser, "config-interval", @as(c.gint, -1), @as(?*anyopaque, null));
    } else if (c.gst_structure_has_name(st, "video/x-vp9") != 0) {
        parser = c.gst_element_factory_make("vp9parse", null);
        if (parser == null) return false;
    } else sinkpad = c.gst_element_get_static_pad(capsfilter, "sink");
    if (parser != null) {
        if (c.gst_bin_add(@ptrCast(s), parser) == 0 or c.gst_element_link(parser, capsfilter) == 0) {
            c.gst_object_unref(parser);
            return false;
        }
        sinkpad = c.gst_element_get_static_pad(parser, "sink");
    }
    const chainpad: ?*c.GstPad = c.gst_ghost_pad_new("chainpad", @ptrCast(capsfilter.*.srcpads.*.data));
    _ = c.gst_element_add_pad(@ptrCast(s), chainpad);
    const internal: ?*c.GstPad = @ptrCast(c.gst_proxy_pad_get_internal(@ptrCast(@alignCast(chainpad))));
    c.gst_pad_set_chain_function_full(internal, chain, null, null);
    c.gst_pad_set_event_function_full(internal, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(internal, sinkQuery, null, null);
    _ = c.gst_ghost_pad_set_target(@ptrCast(@alignCast(s.sinkpad)), sinkpad);
    c.gst_object_unref(sinkpad);
    return true;
}

pub fn setEncoder(s: *Self, format: [*c]c.GstCaps, encoder: [*c]c.GstElement) bool {
    s.encoder = @ptrCast(@alignCast(c.g_object_ref_sink(encoder)));
    _ = c.gst_element_set_locked_state(s.encoder, 1);
    return addParser(s, format);
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const ret = parent.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) reset(me(el));
    return ret;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_mutex_clear(&s.internal_flow_lock);
    c.g_cond_clear(&s.internal_flow_cond);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.encoder != null) c.gst_object_unref(s.encoder);
    s.encoder = null;
    if (s.original_caps != null) c.gst_caps_unref(s.original_caps);
    s.original_caps = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Smart Video Encoder", "Codec/Recoder/Video", "Re-encodes portions of Video that lay on segment boundaries", "Edward Hervey <bilboed@gmail.com>");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.finalize = finalize;
    ec.change_state = changeState;
    _ = c._gst_debug_category_new("smartencoder", 0, "Smart Encoder");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const templ = c.gst_static_pad_template_get(&sink_t);
    s.sinkpad = c.gst_ghost_pad_new_no_target_from_template("sink", templ);
    _ = c.gst_element_add_pad(@ptrCast(s), s.sinkpad);
    c.gst_object_unref(templ);
    s.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_use_fixed_caps(s.srcpad);
    _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
    c.g_mutex_init(&s.internal_flow_lock);
    c.g_cond_init(&s.internal_flow_cond);
    reset(s);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstSmartEncoder", Class, Self, classInit, init);
        }
    }.f);
}
