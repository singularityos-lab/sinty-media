const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("el.zig");
const index = @import("index.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Parse = c.GstBaseParse;
const Class = c.GstBaseParseClass;
const Frame = c.GstBaseParseFrame;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const NONE = el.NONE;
const SEC: u64 = 1_000_000_000;
const FILE = "gstbaseparse.c";
const NOALLOC: c.guint = 1 << 0;
const MIN_FRAMES = 10;
const TARGET_DIFFERENCE: u64 = 20 * SEC;
const MAX_INDEX_ENTRIES = 4096;
const UPDATE_THRESHOLD = 2;
const DROPPED: c.GstFlowReturn = c.GST_FLOW_CUSTOM_SUCCESS;
const SEQNUM_INVALID: c.guint32 = 0;
const FMTLIST = [_]c.GstFormat{ c.GST_FORMAT_DEFAULT, c.GST_FORMAT_BYTES, c.GST_FORMAT_TIME, c.GST_FORMAT_UNDEFINED };

const Private = extern struct {
    pad_mode: c.GstPadMode,
    adapter: ?*c.GstAdapter,
    duration: i64,
    duration_fmt: c.GstFormat,
    estimated_duration: i64,
    estimated_drift: i64,
    min_frame_size: c.guint,
    disable_passthrough: bool,
    disable_clip: bool,
    passthrough: bool,
    pts_interpolate: bool,
    infer_ts: bool,
    syncable: bool,
    has_timing_info: bool,
    fps_num: c.guint,
    fps_den: c.guint,
    update_interval: c.gint,
    bitrate: c.guint,
    lead_in: c.guint,
    lead_out: c.guint,
    lead_in_ts: u64,
    lead_out_ts: u64,
    min_latency: u64,
    max_latency: u64,
    posted_latency_msg: bool,
    discont: bool,
    flushing: bool,
    drain: bool,
    saw_gaps: bool,
    offset: i64,
    sync_offset: i64,
    next_pts: u64,
    next_dts: u64,
    prev_pts: u64,
    prev_dts: u64,
    prev_dts_from_pts: bool,
    frame_duration: u64,
    seen_keyframe: bool,
    is_video: bool,
    flushed: c.gint,
    framecount: u64,
    bytecount: u64,
    data_bytecount: u64,
    acc_duration: u64,
    first_frame_pts: u64,
    first_frame_dts: u64,
    first_frame_offset: i64,
    post_min_bitrate: bool,
    post_avg_bitrate: bool,
    post_max_bitrate: bool,
    min_bitrate: c.guint,
    avg_bitrate: c.guint,
    max_bitrate: c.guint,
    posted_avg_bitrate: c.guint,
    queued_frames: c.GQueue,
    cache: [*c]Buffer,
    index: ?*index.Index,
    index_id: c.gint,
    own_index: bool,
    index_lock: c.GMutex,
    upstream_seekable: bool,
    upstream_has_duration: bool,
    upstream_size: i64,
    upstream_format: c.GstFormat,
    idx_interval: i64,
    idx_byte_interval: u64,
    index_last_ts: u64,
    index_last_offset: i64,
    index_last_valid: bool,
    exact_position: bool,
    pending_seeks: [*c]c.GSList,
    buffers_pending: [*c]c.GSList,
    buffers_head: [*c]c.GSList,
    buffers_queued: [*c]c.GSList,
    buffers_send: [*c]c.GSList,
    last_pts: u64,
    last_dts: u64,
    last_offset: i64,
    pending_events: ?*c.GList,
    checked_media: bool,
    prev_offset: i64,
    new_frame: bool,
    scanning: bool,
    scanned_frame: ?*Frame,
    detecting: bool,
    detect_buffers: ?*c.GList,
    detect_buffers_size: c.guint,
    first_buffer: bool,
    push_stream_start: bool,
    skip: c.guint,
    upstream_tags: ?*c.GstTagList,
    parser_tags: ?*c.GstTagList,
    parser_tags_merge_mode: c.GstTagMergeMode,
    tags_changed: bool,
    segment_seqnum: c.guint32,
};

const Seek = extern struct {
    segment: c.GstSegment,
    accurate: bool,
    offset: i64,
    start_ts: u64,
};

var once: gtype.Once = .{};
var frame_once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstElementClass = null;

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Parse, @ptrCast(@alignCast(p)))[0].priv));
}

fn of(p: anytype) *Parse {
    return @ptrCast(@alignCast(p));
}

fn klass(p: anytype) *Class {
    return el.classOf(Class, p);
}

fn adapter(p: *Parse) ?*c.GstAdapter {
    return priv(p).adapter;
}

fn isParse(p: anytype) bool {
    return gtype.instanceOf(p, gst_base_parse_get_type());
}

fn buf(p: c.gpointer) [*c]Buffer {
    return @ptrCast(@alignCast(p));
}

fn ev(p: c.gpointer) [*c]Event {
    return @ptrCast(@alignCast(p));
}

fn bufUnref(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_buffer_unref(buf(p));
}

fn miniUnref(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

fn freeFn(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_free(p);
}

fn frameFreeFn(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    gst_base_parse_frame_free(@ptrCast(@alignCast(p)));
}

fn freeSlist(l: *[*c]c.GSList) void {
    c.g_slist_foreach(l.*, bufUnref, null);
    c.g_slist_free(l.*);
    l.* = null;
}

fn freeDetect(r: *Private) void {
    c.g_list_foreach(r.detect_buffers, bufUnref, null);
    c.g_list_free(r.detect_buffers);
    r.detect_buffers = null;
    r.detect_buffers_size = 0;
}

fn flag(b: [*c]Buffer, f: c.guint) bool {
    return b[0].mini_object.flags & f != 0;
}

fn clearQueues(p: *Parse, sticky: bool) void {
    const r = priv(p);
    freeSlist(&r.buffers_queued);
    freeSlist(&r.buffers_pending);
    freeSlist(&r.buffers_head);
    freeSlist(&r.buffers_send);
    freeDetect(r);
    c.g_queue_foreach(&r.queued_frames, frameFreeFn, null);
    c.g_queue_clear(&r.queued_frames);
    _ = c.gst_mini_object_replace(@ptrCast(&r.cache), null);
    if (sticky) {
        c.g_list_foreach(r.pending_events, miniUnref, null);
        c.g_list_free(r.pending_events);
        r.pending_events = null;
    } else {
        var cur = r.pending_events;
        while (cur) |n| {
            const next = n.next;
            const e = ev(n.data);
            const t = e[0].type;
            if (t & c.GST_EVENT_TYPE_STICKY == 0 or t == c.GST_EVENT_EOS or t == c.GST_EVENT_STREAM_GROUP_DONE or t == c.GST_EVENT_SEGMENT) {
                c.gst_event_unref(e);
                r.pending_events = c.g_list_delete_link(r.pending_events, n);
            }
            cur = next;
        }
    }
    r.checked_media = false;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p = of(o);
    const r = priv(p);
    c.g_object_unref(r.adapter);
    if (r.index) |i| {
        c.gst_object_unref(i);
        r.index = null;
    }
    c.g_mutex_clear(&r.index_lock);
    clearQueues(p, true);
    @as(*c.GObjectClass, @ptrCast(parent.?)).finalize.?(o);
}

fn setProp(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => priv(o).disable_passthrough = c.g_value_get_boolean(v) != 0,
        2 => priv(o).disable_clip = c.g_value_get_boolean(v) != 0,
        else => el.badProperty(o, id, pspec, FILE, 701),
    }
}

fn getProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => c.g_value_set_boolean(v, @intFromBool(priv(o).disable_passthrough)),
        2 => c.g_value_set_boolean(v, @intFromBool(priv(o).disable_clip)),
        else => el.badProperty(o, id, pspec, FILE, 720),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = finalize;
    gc.set_property = setProp;
    gc.get_property = getProp;
    const rw = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_boolean("disable-passthrough", "Disable passthrough", "Force processing (disables passthrough)", 0, rw));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_boolean("disable-clip", "Disable Clip", "Disable buffer dropping that are out of segment", 1, rw));
    @as(*c.GstElementClass, @ptrCast(@alignCast(k))).change_state = changeState;
    const bc: *Class = @ptrCast(@alignCast(k));
    bc.sink_event = sinkEventDefault;
    bc.src_event = srcEventDefault;
    bc.sink_query = sinkQueryDefault;
    bc.src_query = srcQueryDefault;
    bc.convert = gst_base_parse_convert_default;
    _ = c._gst_debug_category_new("baseparse", 0, "baseparse element");
}

fn init(instance: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const p: *Parse = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    p.priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset_)))));
    const r = priv(p);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(g_class));
    var templ = c.gst_element_class_get_pad_template(ec, "sink");
    if (!check.that(templ != null, "gst_base_parse_init", "pad_template != NULL")) return;
    p.sinkpad = c.gst_pad_new_from_template(templ, "sink");
    c.gst_pad_set_event_function_full(p.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(p.sinkpad, sinkQuery, null, null);
    c.gst_pad_set_chain_function_full(p.sinkpad, chain, null, null);
    c.gst_pad_set_activate_function_full(p.sinkpad, sinkActivate, null, null);
    c.gst_pad_set_activatemode_function_full(p.sinkpad, sinkActivateMode, null, null);
    el.setFlag(p.sinkpad, c.GST_PAD_FLAG_PROXY_ALLOCATION);
    _ = c.gst_element_add_pad(@ptrCast(p), p.sinkpad);
    templ = c.gst_element_class_get_pad_template(ec, "src");
    if (!check.that(templ != null, "gst_base_parse_init", "pad_template != NULL")) return;
    p.srcpad = c.gst_pad_new_from_template(templ, "src");
    c.gst_pad_set_event_function_full(p.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(p.srcpad, srcQuery, null, null);
    c.gst_pad_use_fixed_caps(p.srcpad);
    _ = c.gst_element_add_pad(@ptrCast(p), p.srcpad);
    c.g_queue_init(&r.queued_frames);
    r.adapter = c.gst_adapter_new();
    r.pad_mode = c.GST_PAD_MODE_NONE;
    c.g_mutex_init(&r.index_lock);
    reset(p);
    el.setFlag(p, c.GST_ELEMENT_FLAG_INDEXABLE);
    r.upstream_tags = null;
    r.parser_tags = null;
    r.parser_tags_merge_mode = c.GST_TAG_MERGE_APPEND;
    r.disable_passthrough = false;
    r.disable_clip = true;
}

pub export fn gst_base_parse_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type(), "GstBaseParse", Class, Parse, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

pub export fn gst_base_parse_frame_copy(f: ?*Frame) ?*Frame {
    const n: *Frame = @ptrCast(@alignCast(c.g_memdup2(f, @sizeOf(Frame))));
    n.buffer = c.gst_buffer_ref(f.?.buffer);
    if (n.out_buffer != null) _ = c.gst_buffer_ref(n.out_buffer);
    n._private_flags &= ~NOALLOC;
    return n;
}

pub export fn gst_base_parse_frame_free(f: ?*Frame) void {
    const x = f.?;
    if (x.buffer != null) {
        c.gst_buffer_unref(x.buffer);
        x.buffer = null;
    }
    if (x.out_buffer != null) {
        c.gst_buffer_unref(x.out_buffer);
        x.out_buffer = null;
    }
    if (x._private_flags & NOALLOC == 0) c.g_free(x) else x.* = std.mem.zeroes(Frame);
}

fn frameCopyFn(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_base_parse_frame_copy(@ptrCast(@alignCast(p)));
}

fn frameFreeBoxed(p: c.gpointer) callconv(.c) void {
    gst_base_parse_frame_free(@ptrCast(@alignCast(p)));
}

pub export fn gst_base_parse_frame_get_type() c.GType {
    return frame_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstBaseParseFrame", frameCopyFn, frameFreeBoxed);
        }
    }.f);
}

pub export fn gst_base_parse_frame_init(f: ?*Frame) void {
    f.?.* = std.mem.zeroes(Frame);
    f.?._private_flags = NOALLOC;
}

pub export fn gst_base_parse_frame_new(b: [*c]Buffer, _: c.GstBaseParseFrameFlags, _: c.gint) ?*Frame {
    const f: *Frame = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Frame))));
    f.buffer = c.gst_buffer_ref(b);
    return f;
}

fn updateFlags(p: *Parse) void {
    p.flags = 0;
    if (priv(p).drain) p.flags |= c.GST_BASE_PARSE_FLAG_DRAINING;
    if (priv(p).discont) p.flags |= c.GST_BASE_PARSE_FLAG_LOST_SYNC;
}

fn updateFrame(p: *Parse, f: *Frame) void {
    const r = priv(p);
    if (r.discont) f.buffer[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT else f.buffer[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DISCONT);
    if (r.prev_offset != r.offset or r.new_frame) f.flags |= c.GST_BASE_PARSE_FRAME_FLAG_NEW_FRAME;
    r.prev_offset = r.offset;
    f.offset = @bitCast(r.offset);
}

fn reset(p: *Parse) void {
    const r = priv(p);
    el.lock(p);
    c.gst_segment_init(&p.segment, c.GST_FORMAT_TIME);
    r.duration = -1;
    r.min_frame_size = 1;
    r.discont = true;
    r.flushing = false;
    r.saw_gaps = false;
    r.offset = 0;
    r.sync_offset = 0;
    r.update_interval = -1;
    r.fps_num = 0;
    r.fps_den = 0;
    r.frame_duration = NONE;
    r.lead_in = 0;
    r.lead_out = 0;
    r.lead_in_ts = 0;
    r.lead_out_ts = 0;
    r.bitrate = 0;
    r.framecount = 0;
    r.bytecount = 0;
    r.data_bytecount = 0;
    r.acc_duration = 0;
    r.first_frame_pts = NONE;
    r.first_frame_dts = NONE;
    r.first_frame_offset = -1;
    r.estimated_duration = -1;
    r.estimated_drift = 0;
    r.next_pts = NONE;
    r.next_dts = 0;
    r.syncable = true;
    r.passthrough = false;
    r.pts_interpolate = true;
    r.infer_ts = true;
    r.has_timing_info = false;
    r.min_bitrate = std.math.maxInt(c.guint);
    r.max_bitrate = 0;
    r.avg_bitrate = 0;
    r.posted_avg_bitrate = 0;
    r.index_last_ts = NONE;
    r.index_last_offset = -1;
    r.index_last_valid = true;
    r.upstream_seekable = false;
    r.upstream_size = 0;
    r.upstream_has_duration = false;
    r.upstream_format = c.GST_FORMAT_UNDEFINED;
    r.idx_interval = 0;
    r.idx_byte_interval = 0;
    r.exact_position = true;
    r.seen_keyframe = false;
    r.checked_media = false;
    r.last_dts = NONE;
    r.last_pts = NONE;
    r.last_offset = 0;
    r.skip = 0;
    c.g_list_foreach(r.pending_events, miniUnref, null);
    c.g_list_free(r.pending_events);
    r.pending_events = null;
    if (r.cache != null) {
        c.gst_buffer_unref(r.cache);
        r.cache = null;
    }
    c.g_slist_foreach(r.pending_seeks, freeFn, null);
    c.g_slist_free(r.pending_seeks);
    r.pending_seeks = null;
    if (r.adapter != null) c.gst_adapter_clear(r.adapter);
    setUpstreamTags(p, null);
    if (r.parser_tags) |t| {
        c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
        r.parser_tags = null;
    }
    r.parser_tags_merge_mode = c.GST_TAG_MERGE_APPEND;
    r.new_frame = true;
    r.first_buffer = true;
    freeDetect(r);
    r.segment_seqnum = SEQNUM_INVALID;
    r.posted_latency_msg = false;
    el.unlock(p);
}

fn hasBitrateTag(r: *Private, tag: [*c]const u8) bool {
    var n: c.guint = 0;
    var got = false;
    if (r.upstream_tags) |t| got = c.gst_tag_list_get_uint(t, tag, &n) != 0;
    if (!got) {
        if (r.parser_tags) |t| got = c.gst_tag_list_get_uint(t, tag, &n) != 0;
    }
    return got;
}

fn checkBitrateTags(p: *Parse) void {
    const r = priv(p);
    r.post_min_bitrate = !hasBitrateTag(r, c.GST_TAG_MINIMUM_BITRATE);
    r.post_avg_bitrate = !hasBitrateTag(r, c.GST_TAG_BITRATE);
    r.post_max_bitrate = !hasBitrateTag(r, c.GST_TAG_MAXIMUM_BITRATE);
}

fn queueTagUpdate(p: *Parse) void {
    const r = priv(p);
    var merged = c.gst_tag_list_merge(r.upstream_tags, r.parser_tags, r.parser_tags_merge_mode);
    if (merged == null) merged = c.gst_tag_list_new_empty();
    if (r.framecount >= MIN_FRAMES) {
        if (r.min_bitrate != std.math.maxInt(c.guint) and r.post_min_bitrate) c.gst_tag_list_add(merged, c.GST_TAG_MERGE_KEEP, c.GST_TAG_MINIMUM_BITRATE, r.min_bitrate, @as(?*anyopaque, null));
        if (r.max_bitrate != 0 and r.post_max_bitrate) c.gst_tag_list_add(merged, c.GST_TAG_MERGE_KEEP, c.GST_TAG_MAXIMUM_BITRATE, r.max_bitrate, @as(?*anyopaque, null));
        if (r.avg_bitrate != 0 and r.post_avg_bitrate) {
            r.posted_avg_bitrate = r.avg_bitrate;
            c.gst_tag_list_add(merged, c.GST_TAG_MERGE_KEEP, c.GST_TAG_BITRATE, r.avg_bitrate, @as(?*anyopaque, null));
        }
    }
    if (c.gst_tag_list_is_empty(merged) != 0) {
        c.gst_mini_object_unref(@ptrCast(@alignCast(merged)));
        return;
    }
    r.pending_events = c.g_list_prepend(r.pending_events, c.gst_event_new_tag(merged));
}

fn parseFrame(p: *Parse, f: *Frame) void {
    const r = priv(p);
    const b = f.buffer;
    const approx_pts = b[0].pts == NONE and r.next_pts != NONE;
    const approx_dts = b[0].dts == NONE and r.next_dts != NONE;
    if (approx_pts) {
        b[0].pts = r.next_pts;
        if (!approx_dts and b[0].dts > r.next_pts and b[0].dts != NONE) b[0].pts = b[0].dts;
    }
    if (approx_dts) {
        b[0].dts = if (!approx_pts and b[0].pts < r.next_dts) b[0].pts else r.next_dts;
    }
    if (b[0].pts != NONE and b[0].dts != NONE and b[0].pts < b[0].dts) b[0].pts = b[0].dts;
    if (b[0].duration == NONE and r.frame_duration != NONE) b[0].duration = r.frame_duration;
}

fn convert(p: *Parse, src_fmt: c.GstFormat, src: i64, dst_fmt: c.GstFormat, dst: ?*i64) bool {
    if (!check.that(dst != null, "gst_base_parse_convert", "dest_value != NULL")) return false;
    const f = klass(p).convert orelse return false;
    return f(p, src_fmt, src, dst_fmt, dst) != 0;
}

fn updateUpstreamProvided(field: ?*const c.GstIdStr, v: [*c]const c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const caps: [*c]c.GstCaps = @ptrCast(@alignCast(data));
    const n = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const s = c.gst_caps_get_structure(caps, i);
        if (c.gst_structure_has_field(s, c.gst_id_str_as_str(field)) == 0) {
            c.gst_structure_id_str_set_value(s, field, v);
        } else {
            const cur = c.gst_structure_id_str_get_value(s, field);
            if (c.gst_value_is_fixed(cur) == 0 and c.gst_value_is_subset(v, cur) != 0) c.gst_structure_id_str_set_value(s, field, v);
        }
    }
    return 1;
}

fn negotiateDefaultCaps(p: *Parse) [*c]c.GstCaps {
    var templ = c.gst_pad_get_pad_template_caps(p.srcpad);
    var caps = c.gst_pad_peer_query_caps(p.srcpad, templ);
    if (caps != null) c.gst_caps_unref(templ) else caps = templ;
    templ = null;
    if (caps == null or c.gst_caps_is_empty(caps) != 0 or c.gst_caps_is_any(caps) != 0) {
        if (caps != null) c.gst_caps_unref(caps);
        return null;
    }
    var def = c.gst_caps_copy(caps);
    const sinkcaps = c.gst_pad_get_current_caps(p.sinkpad);
    if (sinkcaps != null) _ = c.gst_structure_foreach_id_str(c.gst_caps_get_structure(sinkcaps, 0), updateUpstreamProvided, def);
    def = c.gst_caps_fixate(def);
    if (sinkcaps != null) c.gst_caps_unref(sinkcaps);
    if (def == null) {
        c.gst_caps_unref(caps);
        return null;
    }
    c.gst_caps_unref(caps);
    return def;
}

fn sinkEvent(_: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]Event) callconv(.c) c.gboolean {
    return klass(par).sink_event.?(of(par), e);
}

fn drainOrFinish(p: *Parse, prev_head: bool) void {
    if (p.segment.rate > 0.0) gst_base_parse_drain(p) else _ = finishFragment(p, prev_head);
}

fn sinkEventDefault(sp: [*c]Parse, e_in: [*c]Event) callconv(.c) c.gboolean {
    const p = of(sp);
    const r = priv(p);
    var e = e_in;
    var ret: c.gboolean = 0;
    var immediate = false;
    switch (e[0].type) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            ret = if (klass(p).set_sink_caps) |f| f(p, caps) else 1;
            c.gst_event_unref(e);
            e = null;
        },
        c.GST_EVENT_SEGMENT => {
            r.segment_seqnum = c.gst_event_get_seqnum(e);
            var in: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &in);
            var out: c.GstSegment = undefined;
            c.gst_segment_init(&out, c.GST_FORMAT_TIME);
            out.rate = in[0].rate;
            out.applied_rate = in[0].applied_rate;
            r.upstream_format = in[0].format;
            var off: i64 = 0;
            var next_dts: i64 = 0;
            if (in[0].format == c.GST_FORMAT_BYTES) {
                off = @bitCast(in[0].time);
                var seek: ?*Seek = null;
                el.lock(p);
                var node = r.pending_seeks;
                while (node != null) : (node = node[0].next) {
                    const s: *Seek = @ptrCast(@alignCast(node[0].data));
                    if (s.offset == off) {
                        seek = s;
                        break;
                    }
                }
                r.pending_seeks = c.g_slist_remove(r.pending_seeks, seek);
                el.unlock(p);
                if (seek) |s| {
                    out.start = s.segment.start;
                    out.stop = s.segment.stop;
                    out.time = s.segment.start;
                    next_dts = @bitCast(s.start_ts);
                    r.exact_position = s.accurate;
                    c.g_free(s);
                } else {
                    _ = convert(p, c.GST_FORMAT_BYTES, @bitCast(in[0].start), c.GST_FORMAT_TIME, &next_dts);
                    out.start = @bitCast(next_dts);
                    out.stop = NONE;
                    out.time = @bitCast(next_dts);
                    r.exact_position = in[0].start == 0;
                }
                c.gst_event_unref(e);
                e = c.gst_event_new_segment(&out);
                c.gst_event_set_seqnum(e, r.segment_seqnum);
            } else if (in[0].format != c.GST_FORMAT_TIME) {
                c.gst_event_unref(e);
                out.start = 0;
                out.stop = NONE;
                out.time = 0;
                e = c.gst_event_new_segment(&out);
                c.gst_event_set_seqnum(e, r.segment_seqnum);
                next_dts = 0;
            } else {
                r.upstream_seekable = false;
                next_dts = -1;
                c.gst_event_copy_segment(e, &out);
            }
            p.segment = out;
            ret = 1;
            const rate = out.rate;
            if (rate > 0.0) gst_base_parse_drain(p) else _ = finishFragment(p, false);
            c.gst_adapter_clear(r.adapter);
            r.offset = off;
            r.sync_offset = off;
            r.next_dts = @bitCast(next_dts);
            r.next_pts = NONE;
            r.last_pts = NONE;
            r.last_dts = NONE;
            r.prev_pts = NONE;
            r.prev_dts = NONE;
            r.prev_dts_from_pts = false;
            r.discont = true;
            r.seen_keyframe = false;
            r.skip = 0;
        },
        c.GST_EVENT_SEGMENT_DONE => {
            drainOrFinish(p, false);
            immediate = true;
        },
        c.GST_EVENT_FLUSH_START => {
            el.lock(p);
            r.flushing = true;
            el.unlock(p);
        },
        c.GST_EVENT_FLUSH_STOP => {
            c.gst_adapter_clear(r.adapter);
            clearQueues(p, false);
            r.flushing = false;
            r.discont = true;
            r.last_pts = NONE;
            r.last_dts = NONE;
            r.new_frame = true;
            r.skip = 0;
            immediate = true;
        },
        c.GST_EVENT_EOS => {
            drainOrFinish(p, true);
            if (r.framecount == 0 and !r.saw_gaps and !r.first_buffer) el.err(p, .stream, c.GST_STREAM_ERROR_WRONG_TYPE, "No valid frames found before end of stream", null, FILE, "gst_base_parse_sink_event_default", 1481);
            if (!r.saw_gaps and r.framecount < MIN_FRAMES) queueTagUpdate(p);
            pushPendingEvents(p);
            immediate = true;
        },
        c.GST_EVENT_CUSTOM_DOWNSTREAM => {
            const s = c.gst_event_get_structure(e);
            var still: c.gboolean = 0;
            if (s != null and c.gst_structure_has_name(s, "GstEventStillFrame") != 0 and c.gst_structure_get_boolean(s, "still-state", &still) != 0) {
                if (still != 0) drainOrFinish(p, true);
                immediate = true;
            }
        },
        c.GST_EVENT_GAP => gap: {
            if (c.gst_pad_has_current_caps(p.srcpad) == 0) {
                const def = negotiateDefaultCaps(p);
                if (def == null) {
                    c.gst_event_unref(e);
                    e = null;
                    ret = 0;
                    el.err(p, .stream, c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup("Parser output not negotiated before GAP event."), FILE, "gst_base_parse_sink_event_default", 1559);
                    break :gap;
                }
                const ce = c.gst_event_new_caps(def);
                var l = r.pending_events;
                while (l) |n| : (l = n.next) {
                    if (ev(n.data)[0].type < c.GST_EVENT_CAPS) {
                        r.pending_events = c.g_list_insert_before(r.pending_events, n, ce);
                        break;
                    }
                }
                if (l == null) r.pending_events = c.g_list_append(r.pending_events, ce);
                c.gst_caps_unref(def);
            }
            pushPendingEvents(p);
            drainOrFinish(p, true);
            immediate = true;
            r.saw_gaps = true;
        },
        c.GST_EVENT_TAG => tag: {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(e, &tags);
            if (c.gst_tag_list_get_scope(tags) != c.GST_TAG_SCOPE_STREAM) break :tag;
            setUpstreamTags(p, tags);
            queueTagUpdate(p);
            r.tags_changed = false;
            c.gst_event_unref(e);
            e = null;
            ret = 1;
        },
        c.GST_EVENT_STREAM_START => {
            if (r.pad_mode != c.GST_PAD_MODE_PULL) immediate = true;
            setUpstreamTags(p, null);
            r.tags_changed = true;
        },
        else => {},
    }
    if (e != null) {
        if (e[0].type & c.GST_EVENT_TYPE_SERIALIZED == 0 or immediate) {
            ret = c.gst_pad_push_event(p.srcpad, e);
        } else {
            r.pending_events = c.g_list_prepend(r.pending_events, e);
            ret = 1;
        }
    }
    return ret;
}

fn sinkQueryDefault(sp: [*c]Parse, q: [*c]Query) callconv(.c) c.gboolean {
    const p = of(sp);
    const pad = p.sinkpad;
    switch (q[0].type) {
        c.GST_QUERY_BITRATE => {
            if (priv(p).avg_bitrate != 0) {
                c.gst_query_set_bitrate(q, priv(p).avg_bitrate);
                return 1;
            }
            return c.gst_pad_query_default(pad, @ptrCast(p), q);
        },
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            var caps: [*c]c.GstCaps = undefined;
            if (klass(p).get_sink_caps) |f| {
                caps = f(p, filter);
            } else {
                const templ = c.gst_pad_get_pad_template_caps(pad);
                if (filter != null) {
                    caps = c.gst_caps_intersect_full(filter, templ, c.GST_CAPS_INTERSECT_FIRST);
                    c.gst_caps_unref(templ);
                } else caps = templ;
            }
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        else => return c.gst_pad_query_default(pad, @ptrCast(p), q),
    }
}

fn sinkQuery(_: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const f = klass(par).sink_query orelse return 0;
    return f(of(par), q);
}

fn srcQuery(_: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const f = klass(par).src_query orelse return 0;
    return f(of(par), q);
}

fn srcEvent(_: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]Event) callconv(.c) c.gboolean {
    const f = klass(par).src_event orelse {
        c.gst_event_unref(e);
        return 1;
    };
    return f(of(par), e);
}

fn srcEventDefault(sp: [*c]Parse, e: [*c]Event) callconv(.c) c.gboolean {
    const p = of(sp);
    if (e[0].type != c.GST_EVENT_SEEK) return c.gst_pad_event_default(p.srcpad, @ptrCast(p), e);
    if (priv(p).syncable) return @intFromBool(handleSeek(p, e));
    return 0;
}

pub export fn gst_base_parse_convert_default(sp: [*c]Parse, src_fmt: c.GstFormat, src: c.gint64, dst_fmt: c.GstFormat, dst: [*c]c.gint64) c.gboolean {
    const r = priv(sp);
    if (src_fmt == dst_fmt) {
        dst.* = src;
        return 1;
    }
    if (src == -1) {
        dst.* = -1;
        return 1;
    }
    if (src == 0) {
        dst.* = 0;
        return 1;
    }
    if (r.upstream_format != c.GST_FORMAT_BYTES and (src_fmt == c.GST_FORMAT_BYTES or dst_fmt == c.GST_FORMAT_BYTES)) return 0;
    if (r.framecount == 0) return 0;
    const duration = r.acc_duration;
    const bytes = r.bytecount;
    if (duration == 0 or bytes == 0) return 0;
    const v: u64 = @bitCast(src);
    if (src_fmt == c.GST_FORMAT_BYTES and dst_fmt == c.GST_FORMAT_TIME) {
        dst.* = @bitCast(c.gst_util_uint64_scale(v, duration, bytes));
        return 1;
    }
    if (src_fmt == c.GST_FORMAT_TIME and dst_fmt == c.GST_FORMAT_BYTES) {
        dst.* = @bitCast(c.gst_util_uint64_scale(v, bytes, duration));
        return 1;
    }
    if (src_fmt == c.GST_FORMAT_DEFAULT and dst_fmt == c.GST_FORMAT_TIME and r.fps_den != 0) {
        dst.* = @bitCast(c.gst_util_uint64_scale(v, SEC * r.fps_den, r.fps_num));
        return 1;
    }
    return 0;
}

fn updateDuration(p: *Parse) void {
    const r = priv(p);
    var total: i64 = 0;
    if (c.gst_pad_peer_query_duration(p.sinkpad, c.GST_FORMAT_BYTES, &total) == 0) return;
    var dest: i64 = 0;
    if (!convert(p, c.GST_FORMAT_BYTES, total, c.GST_FORMAT_TIME, &dest)) return;
    r.estimated_drift +%= dest -% r.estimated_duration;
    r.estimated_duration = dest;
    if (r.estimated_drift > SEC or r.estimated_drift < -@as(i64, SEC)) {
        _ = c.gst_element_post_message(@ptrCast(p), c.gst_message_new_duration_changed(@ptrCast(p)));
        r.estimated_drift = 0;
    }
}

fn updateBitrates(p: *Parse, f: *Frame) void {
    const r = priv(p);
    const b = f.buffer;
    if (f.overhead == -1) return;
    const len: u64 = c.gst_buffer_get_size(b) -% @as(u64, @bitCast(@as(i64, f.overhead)));
    r.data_bytecount +%= len;
    if (b[0].duration == NONE or r.acc_duration == 0) return;
    const dur = b[0].duration;
    const avg = c.gst_util_uint64_scale(SEC, 8 *% r.data_bytecount, r.acc_duration);
    if (avg > std.math.maxInt(c.guint)) return;
    r.avg_bitrate = @intCast(avg);
    if (r.bitrate != 0) {
        r.avg_bitrate = r.bitrate;
        if (r.post_avg_bitrate and r.posted_avg_bitrate != r.avg_bitrate) r.tags_changed = true;
    }
    if (dur == 0) return;
    const fb64 = c.gst_util_uint64_scale(SEC, 8 *% len, dur);
    if (fb64 > std.math.maxInt(c.guint)) return;
    const fb: c.guint = @intCast(fb64);
    if (r.framecount < MIN_FRAMES) return;
    if (r.framecount == MIN_FRAMES and (r.post_min_bitrate or r.post_avg_bitrate or r.post_max_bitrate)) r.tags_changed = true;
    if (fb < r.min_bitrate) {
        r.min_bitrate = fb;
        if (r.post_min_bitrate) r.tags_changed = true;
    }
    if (fb > r.max_bitrate) {
        r.max_bitrate = fb;
        if (r.post_max_bitrate) r.tags_changed = true;
    }
    if (r.post_avg_bitrate and r.avg_bitrate != 0) {
        const a = r.avg_bitrate;
        const pa = r.posted_avg_bitrate;
        const diff = c.gst_util_uint64_scale(100, if (a > pa) a - pa else pa - a, a);
        if (diff >= UPDATE_THRESHOLD) r.tags_changed = true;
    }
}

fn clockDiff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

pub export fn gst_base_parse_add_index_entry(sp: [*c]Parse, offset: c.guint64, ts: c.GstClockTime, key: c.gboolean, force: c.gboolean) c.gboolean {
    if (!check.that(ts != NONE, "gst_base_parse_add_index_entry", "GST_CLOCK_TIME_IS_VALID (ts)")) return 0;
    const p = of(sp);
    const r = priv(p);
    if (force == 0) {
        if (!r.upstream_seekable) return 0;
        if (@as(u64, @bitCast(r.index_last_offset)) +% r.idx_byte_interval >= offset) return 0;
        if (r.index_last_ts != NONE and clockDiff(r.index_last_ts, ts) < r.idx_interval) return 0;
        if (!r.index_last_valid) {
            var prev: u64 = 0;
            _ = findOffset(p, ts, true, &prev);
            if (clockDiff(prev, ts) < r.idx_interval) {
                r.index_last_offset = @bitCast(offset);
                r.index_last_ts = ts;
                return 0;
            }
        }
    }
    const list = [_]index.Assoc{ .{ .format = c.GST_FORMAT_TIME, .value = @bitCast(ts) }, .{ .format = c.GST_FORMAT_BYTES, .value = @bitCast(offset) } };
    c.g_mutex_lock(&r.index_lock);
    if (r.index) |i| index.addAssociations(i, r.index_id, if (key != 0) index.KEY_UNIT else index.DELTA_UNIT, &list) else check.fail("gst_index_add_associationv", "GST_IS_INDEX (index)");
    c.g_mutex_unlock(&r.index_lock);
    if (key != 0) {
        r.index_last_offset = @bitCast(offset);
        r.index_last_ts = ts;
    }
    return 1;
}

fn checkSeekability(p: *Parse) void {
    const r = priv(p);
    const q = c.gst_query_new_seeking(c.GST_FORMAT_BYTES);
    var seekable: c.gboolean = 0;
    var start: i64 = -1;
    var stop: i64 = -1;
    var interval: u64 = 0;
    var byte_interval: u64 = 0;
    if (c.gst_pad_peer_query(p.sinkpad, q) != 0) {
        c.gst_query_parse_seeking(q, null, &seekable, &start, &stop);
        if (seekable != 0 and stop == -1) _ = c.gst_pad_peer_query_duration(p.sinkpad, c.GST_FORMAT_BYTES, &stop);
        if (seekable != 0 and (start != 0 or stop <= start)) seekable = 0;
        if (seekable != 0) {
            interval = if (stop < 10 * 1024 * 1024) 100 else if (stop < 100 * 1024 * 1024) 500 else 1000;
            byte_interval = @as(u64, @bitCast(stop - start)) / MAX_INDEX_ENTRIES;
        }
    }
    c.gst_query_unref(q);
    r.upstream_seekable = seekable != 0;
    r.upstream_size = if (seekable != 0) stop else 0;
    r.idx_interval = @intCast(interval * 1_000_000);
    r.idx_byte_interval = byte_interval;
}

fn checkUpstream(p: *Parse) void {
    var stop: i64 = 0;
    if (c.gst_pad_peer_query_duration(p.sinkpad, c.GST_FORMAT_TIME, &stop) != 0 and stop != -1 and stop != 0) {
        gst_base_parse_set_duration(p, c.GST_FORMAT_TIME, stop, 0);
        priv(p).upstream_has_duration = true;
    }
}

fn checkMedia(p: *Parse) void {
    const r = priv(p);
    const caps = c.gst_pad_get_current_caps(p.srcpad);
    r.is_video = false;
    if (caps != null) {
        const s = c.gst_caps_get_structure(caps, 0);
        if (s != null) r.is_video = c.g_str_has_prefix(c.gst_structure_get_name(s), "video") != 0;
        c.gst_caps_unref(caps);
    }
    r.checked_media = true;
}

fn queueFrame(p: *Parse, f: *Frame) void {
    const r = priv(p);
    if (f._private_flags & NOALLOC == 0) {
        c.g_queue_push_tail(&r.queued_frames, f);
        return;
    }
    c.g_queue_push_tail(&r.queued_frames, gst_base_parse_frame_copy(f));
    gst_base_parse_frame_free(f);
}

fn prepareFrame(p: *Parse, b_in: [*c]Buffer) *Frame {
    const r = priv(p);
    const b: [*c]Buffer = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(b_in)))));
    b[0].offset = @bitCast(r.offset);
    updateFlags(p);
    const f = gst_base_parse_frame_new(b, 0, 0).?;
    c.gst_buffer_unref(b);
    updateFrame(p, f);
    r.discont = false;
    r.new_frame = false;
    parseFrame(p, f);
    return f;
}

fn handleBuffer(p: *Parse, b: [*c]Buffer, skip: *c.gint, flushed: *c.gint) c.GstFlowReturn {
    const r = priv(p);
    r.flushed = 0;
    skip.* = 0;
    if (r.pad_mode == c.GST_PAD_MODE_PULL) {
        _ = c.gst_buffer_ref(b);
        c.gst_adapter_push(r.adapter, b);
    }
    const f = prepareFrame(p, b);
    var ret = klass(p).handle_frame.?(p, f, skip);
    flushed.* = r.flushed;
    if (!(skip.* == 0 or flushed.* == 0)) c.g_assertion_message_expr("GStreamer-Base", "../libs/gst/base/gstbaseparse.c", 2332, "gst_base_parse_handle_buffer", "*skip == 0 || *flushed == 0");
    if (skip.* > 0) {
        if (p.segment.rate < 0.0 and r.buffers_queued == null) {
            const pts = c.gst_adapter_prev_pts(r.adapter, null);
            const dts = c.gst_adapter_prev_dts(r.adapter, null);
            var o = c.gst_adapter_take_buffer(r.adapter, @intCast(skip.*));
            o = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(o)))));
            o[0].pts = pts;
            o[0].dts = dts;
            o[0].offset = NONE;
            o[0].duration = NONE;
            o[0].offset_end = NONE;
            o[0].mini_object.flags = 0;
            r.buffers_head = c.g_slist_prepend(r.buffers_head, o);
        } else {
            const av = c.gst_adapter_available(r.adapter);
            if (av >= @as(usize, @intCast(skip.*))) {
                c.gst_adapter_flush(r.adapter, @intCast(skip.*));
            } else {
                r.skip = @intCast(@as(usize, @intCast(skip.*)) - av);
                c.gst_adapter_flush(r.adapter, av);
                skip.* = @intCast(av);
            }
        }
        if (!r.discont) r.sync_offset = r.offset;
        r.offset +%= skip.*;
        r.discont = true;
        if (ret == c.GST_FLOW_OK) ret = checkSync(p);
    }
    r.offset +%= flushed.*;
    if (r.pad_mode == c.GST_PAD_MODE_PULL) c.gst_adapter_clear(r.adapter);
    if (skip.* == 0 and flushed.* == 0 and flag(f.buffer, c.GST_BUFFER_FLAG_DISCONT)) r.discont = true;
    gst_base_parse_frame_free(f);
    return ret;
}

fn pushPendingEvents(p: *Parse) void {
    const r = priv(p);
    if (r.pending_events == null) return;
    const rev = c.g_list_reverse(r.pending_events);
    r.pending_events = null;
    var l: ?*c.GList = rev;
    while (l) |n| : (l = n.next) _ = c.gst_pad_push_event(p.srcpad, ev(n.data));
    c.g_list_free(rev);
}

fn handleAndPush(p: *Parse, f: *Frame) c.GstFlowReturn {
    const r = priv(p);
    const b = f.buffer;
    const off: i64 = @bitCast(f.offset);
    if (r.first_frame_offset < 0) {
        if (b[0].pts != NONE and r.has_timing_info and r.pad_mode == c.GST_PAD_MODE_PULL) {
            r.first_frame_offset = off;
            r.first_frame_pts = b[0].pts;
            r.first_frame_dts = b[0].dts;
            if (r.duration == -1) {
                var last: u64 = std.math.maxInt(i64);
                var o: i64 = 0;
                _ = locateTime(p, &last, &o);
                if (last != NONE) gst_base_parse_set_duration(p, c.GST_FORMAT_TIME, @bitCast(last), 0);
            }
        } else r.first_frame_offset = 0;
    }
    if (r.upstream_format == c.GST_FORMAT_TIME) {
        f.buffer[0].pts = NONE;
        f.buffer[0].dts = NONE;
    }
    if (r.infer_ts and r.pts_interpolate and r.next_pts == NONE) r.next_pts = r.next_dts;
    parseFrame(p, f);
    r.next_pts = NONE;
    if (b[0].dts != NONE and b[0].duration != NONE) {
        r.next_dts = b[0].dts +% b[0].duration;
        if (r.pts_interpolate and b[0].pts != NONE) {
            const np = b[0].pts +% b[0].duration;
            if (np >= r.next_dts) r.next_pts = np;
        }
    } else r.next_dts = NONE;
    if (r.upstream_seekable and r.exact_position and b[0].pts != NONE) _ = gst_base_parse_add_index_entry(p, @bitCast(off), b[0].pts, @intFromBool(!flag(b, c.GST_BUFFER_FLAG_DELTA_UNIT)), 0);
    while (c.g_queue_pop_head(&r.queued_frames)) |q| {
        const qf: *Frame = @ptrCast(@alignCast(q));
        _ = gst_base_parse_push_frame(p, qf);
        gst_base_parse_frame_free(qf);
    }
    return gst_base_parse_push_frame(p, f);
}

pub export fn gst_base_parse_push_frame(sp: [*c]Parse, fp: ?*Frame) c.GstFlowReturn {
    const fname = "gst_base_parse_push_frame";
    if (!check.that(fp != null, fname, "frame != NULL")) return c.GST_FLOW_ERROR;
    const f = fp.?;
    if (!check.that(f.buffer != null, fname, "frame->buffer != NULL")) return c.GST_FLOW_ERROR;
    const p = of(sp);
    const r = priv(p);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var b = f.buffer;
    r.bytecount +%= @as(u64, @bitCast(@as(i64, f.size)));
    if (f.flags & c.GST_BASE_PARSE_FRAME_FLAG_NO_FRAME == 0) {
        r.framecount += 1;
        if (b[0].duration != NONE) r.acc_duration +%= b[0].duration;
    }
    if (r.update_interval < 0) {
        r.update_interval = 50;
    } else if (r.update_interval > 0 and r.framecount % @as(u64, @intCast(r.update_interval)) == 0) updateDuration(p);
    var last_start: u64 = NONE;
    var last_stop: u64 = NONE;
    if (b[0].pts != NONE) {
        last_start = b[0].pts;
        last_stop = b[0].pts;
    }
    if (last_start != NONE and b[0].duration != NONE) last_stop = last_start +% b[0].duration;
    if (c.gst_pad_has_current_caps(p.srcpad) == 0) {
        if (el.flags(p.srcpad) & c.GST_PAD_FLAG_FLUSHING != 0) return c.GST_FLOW_FLUSHING;
        el.err(p, .stream, c.GST_STREAM_ERROR_DECODE, "No caps set", null, FILE, fname, 2733);
        return c.GST_FLOW_ERROR;
    }
    if (!r.checked_media) checkMedia(p);
    if (r.tags_changed) {
        queueTagUpdate(p);
        r.tags_changed = false;
    }
    pushPendingEvents(p);
    updateBitrates(p, f);
    if (klass(p).pre_push_frame) |pre| ret = pre(p, f) else f.flags |= c.GST_BASE_PARSE_FRAME_FLAG_CLIP;
    if (r.tags_changed) {
        queueTagUpdate(p);
        r.tags_changed = false;
    }
    pushPendingEvents(p);
    if (f.out_buffer != null) {
        b = f.out_buffer;
        f.out_buffer = null;
        _ = c.gst_mini_object_replace(@ptrCast(&f.buffer), null);
    } else {
        b = f.buffer;
        f.buffer = null;
    }
    if (!check.that(b != null, fname, "buffer != NULL")) return c.GST_FLOW_ERROR;
    r.seen_keyframe = r.seen_keyframe or (r.is_video and !flag(b, c.GST_BUFFER_FLAG_DELTA_UNIT));
    if (f.flags & c.GST_BASE_PARSE_FRAME_FLAG_CLIP != 0) {
        const ts = b[0].pts;
        const seg = &p.segment;
        if (ts != NONE and seg.stop != NONE and ts > seg.stop +% r.lead_out_ts) {
            ret = c.GST_FLOW_EOS;
        } else if (!r.disable_clip and ts != NONE and b[0].duration != NONE and seg.start != NONE and ts +% b[0].duration +% r.lead_in_ts < seg.start) {
            ret = if (r.seen_keyframe) c.GST_FLOW_OK else DROPPED;
        } else ret = c.GST_FLOW_OK;
    }
    if (ret == DROPPED) {
        if (flag(b, c.GST_BUFFER_FLAG_DISCONT)) r.discont = true;
        c.gst_buffer_unref(b);
        ret = c.GST_FLOW_OK;
    } else if (ret == c.GST_FLOW_OK) {
        if (p.segment.rate > 0.0) {
            ret = c.gst_pad_push(p.srcpad, b);
        } else if (!r.disable_passthrough and r.passthrough) {
            if (r.buffers_queued != null) {
                _ = finishFragment(p, true);
                ret = sendBuffers(p);
            }
            if (ret == c.GST_FLOW_OK) ret = c.gst_pad_push(p.srcpad, b) else c.gst_buffer_unref(b);
        } else {
            r.buffers_queued = c.g_slist_prepend(r.buffers_queued, b);
            ret = c.GST_FLOW_OK;
        }
    } else {
        c.gst_buffer_unref(b);
        if (ret == c.GST_FLOW_EOS and !r.disable_passthrough and (r.passthrough or (r.pad_mode == c.GST_PAD_MODE_PUSH and !r.upstream_seekable))) ret = c.GST_FLOW_OK;
    }
    if ((ret == c.GST_FLOW_OK or ret == c.GST_FLOW_NOT_LINKED) and last_stop != NONE and p.segment.position < last_stop) p.segment.position = last_stop;
    return ret;
}

pub export fn gst_base_parse_finish_frame(sp: [*c]Parse, fp: ?*Frame, size: c.gint) c.GstFlowReturn {
    const fname = "gst_base_parse_finish_frame";
    if (!check.that(fp != null, fname, "frame != NULL")) return c.GST_FLOW_ERROR;
    const f = fp.?;
    if (!check.that(f.buffer != null, fname, "frame->buffer != NULL")) return c.GST_FLOW_ERROR;
    if (!check.that(size > 0 or f.out_buffer != null, fname, "size > 0 || frame->out_buffer")) return c.GST_FLOW_ERROR;
    const p = of(sp);
    const r = priv(p);
    if (!check.that(c.gst_adapter_available(r.adapter) >= @as(usize, @bitCast(@as(isize, size))), fname, "gst_adapter_available (parse->priv->adapter) >= size")) return c.GST_FLOW_ERROR;
    if (r.framecount == 0) {
        checkSeekability(p);
        checkUpstream(p);
    }
    r.flushed +%= size;
    if (r.scanning and f.buffer != null) {
        if (r.scanned_frame == null) r.scanned_frame = gst_base_parse_frame_copy(f);
        return c.GST_FLOW_OK;
    }
    const n: usize = @bitCast(@as(isize, size));
    if (f.out_buffer == null) {
        var dest = c.gst_adapter_take_buffer(r.adapter, n);
        dest = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(dest)))));
        f.out_buffer = dest;
        const src = f.buffer;
        dest[0].pts = src[0].pts;
        dest[0].dts = src[0].dts;
        dest[0].offset = src[0].offset;
        dest[0].duration = src[0].duration;
        dest[0].offset_end = src[0].offset_end;
        dest[0].mini_object.flags = src[0].mini_object.flags;
    } else c.gst_adapter_flush(r.adapter, n);
    _ = c.gst_mini_object_replace(@ptrCast(&f.buffer), @ptrCast(f.out_buffer));
    c.gst_buffer_unref(f.out_buffer);
    f.out_buffer = null;
    f.size = size;
    if (f.flags & c.GST_BASE_PARSE_FRAME_FLAG_DROP != 0) {
        _ = c.gst_mini_object_replace(@ptrCast(&f.buffer), null);
        return c.GST_FLOW_OK;
    }
    if (f.flags & c.GST_BASE_PARSE_FRAME_FLAG_QUEUE != 0) {
        const copy = gst_base_parse_frame_copy(f).?;
        copy.flags &= ~@as(c.guint, c.GST_BASE_PARSE_FRAME_FLAG_QUEUE);
        queueFrame(p, copy);
        return c.GST_FLOW_OK;
    }
    return handleAndPush(p, f);
}

pub export fn gst_base_parse_drain(sp: [*c]Parse) void {
    const p = of(sp);
    const r = priv(p);
    r.drain = true;
    while (true) {
        const avail = c.gst_adapter_available(r.adapter);
        if (avail == 0) break;
        if (chain(p.sinkpad, @ptrCast(p), null) != c.GST_FLOW_OK) break;
        if (avail == c.gst_adapter_available(r.adapter)) c.gst_adapter_clear(r.adapter);
    }
    r.drain = false;
}

fn sendBuffers(p: *Parse) c.GstFlowReturn {
    const r = priv(p);
    var send = r.buffers_send;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var first = true;
    while (send != null) {
        const b = buf(send[0].data);
        if (first) {
            b[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
            first = false;
        } else b[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DISCONT);
        ret = c.gst_pad_push(p.srcpad, b);
        send = c.g_slist_delete_link(send, send);
        if (ret != c.GST_FLOW_OK) {
            while (send != null) {
                c.gst_buffer_unref(buf(send[0].data));
                send = c.g_slist_delete_link(send, send);
            }
        }
    }
    r.buffers_send = send;
    return ret;
}

fn startFragment(p: *Parse) void {
    const r = priv(p);
    r.next_pts = NONE;
    r.prev_pts = NONE;
    r.next_dts = NONE;
    r.prev_dts = NONE;
    r.prev_dts_from_pts = false;
    p.segment.position = NONE;
    r.discont = true;
    r.buffers_pending = r.buffers_head;
    r.buffers_head = null;
}

fn finishFragment(p: *Parse, prev_head: bool) c.GstFlowReturn {
    const r = priv(p);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var seen_key = false;
    var seen_delta = false;
    r.buffers_pending = c.g_slist_reverse(r.buffers_pending);
    while (r.buffers_pending != null) {
        const b = buf(r.buffers_pending[0].data);
        if (prev_head) c.gst_adapter_push(r.adapter, b) else c.gst_buffer_unref(b);
        r.buffers_pending = c.g_slist_delete_link(r.buffers_pending, r.buffers_pending);
    }
    gst_base_parse_drain(p);
    if (r.buffers_send != null) seen_key = seen_key or !flag(buf(r.buffers_send[0].data), c.GST_BUFFER_FLAG_DELTA_UNIT);
    while (r.buffers_queued != null) {
        const b = buf(r.buffers_queued[0].data);
        if (b[0].pts == NONE and b[0].duration != NONE) {
            if (r.last_pts != NONE) {
                r.last_pts = if (b[0].duration <= r.last_pts) r.last_pts - b[0].duration else 0;
                b[0].pts = r.last_pts;
            }
            if (r.last_dts != NONE) {
                r.last_dts = if (b[0].duration <= r.last_dts) r.last_dts - b[0].duration else 0;
                b[0].dts = r.last_dts;
            }
        }
        r.last_pts = b[0].pts;
        r.last_dts = b[0].dts;
        if (flag(b, c.GST_BUFFER_FLAG_DELTA_UNIT)) {
            if (seen_key) {
                ret = sendBuffers(p);
                if (ret != c.GST_FLOW_OK) {
                    r.buffers_send = c.g_slist_reverse(r.buffers_queued);
                    r.buffers_queued = null;
                    break;
                }
                seen_key = false;
            }
            seen_delta = true;
        } else seen_key = true;
        r.buffers_send = c.g_slist_prepend(r.buffers_send, b);
        r.buffers_queued = c.g_slist_delete_link(r.buffers_queued, r.buffers_queued);
    }
    if (!seen_delta or seen_key) ret = sendBuffers(p);
    if (c.gst_adapter_available(r.adapter) != 0) c.gst_adapter_clear(r.adapter);
    return ret;
}

fn checkSync(p: *Parse) c.GstFlowReturn {
    const r = priv(p);
    if (r.discont and r.offset -% r.sync_offset > 2 * 1024 * 1024) {
        el.err(p, .stream, c.GST_STREAM_ERROR_DECODE, "Failed to parse stream", null, FILE, "gst_base_parse_check_sync", 3092);
        return c.GST_FLOW_ERROR;
    }
    return c.GST_FLOW_OK;
}

fn processStreamheader(p: *Parse) void {
    const caps = c.gst_pad_get_current_caps(p.sinkpad);
    if (caps == null) return;
    defer c.gst_caps_unref(caps);
    const v = c.gst_structure_get_value(c.gst_caps_get_structure(caps, 0), "streamheader");
    if (v == null) return;
    if (v[0].g_type == c.gst_value_array_get_type()) {
        const n = c.gst_value_array_get_size(v);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const hb: [*c]Buffer = @ptrCast(@alignCast(c.g_value_get_boxed(c.gst_value_array_get_value(v, i))));
            _ = chain(p.sinkpad, @ptrCast(p), c.gst_buffer_ref(hb));
        }
    } else if (v[0].g_type == c._gst_buffer_type) {
        const hb: [*c]Buffer = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
        _ = chain(p.sinkpad, @ptrCast(p), c.gst_buffer_ref(hb));
    }
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b_in: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const p = of(par);
    const r = priv(p);
    const k = klass(p);
    var b = b_in;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var old_ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (b != null and flag(b, c.GST_BUFFER_FLAG_DISCONT)) r.skip = 0;
    if (r.skip > 0) {
        const bsize = c.gst_buffer_get_size(b);
        if (r.skip >= bsize) {
            r.skip -= @intCast(bsize);
            r.offset +%= @intCast(bsize);
            r.sync_offset = r.offset;
            c.gst_buffer_unref(b);
            return c.GST_FLOW_OK;
        }
        b = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(b)))));
        c.gst_buffer_resize(b, r.skip, @intCast(bsize - r.skip));
        r.offset +%= r.skip;
        r.skip = 0;
        r.discont = true;
    }
    if (r.first_buffer) {
        r.first_buffer = false;
        if (!flag(b, c.GST_BUFFER_FLAG_HEADER)) processStreamheader(p);
    }
    if (r.detecting) {
        var db: [*c]Buffer = undefined;
        if (r.detect_buffers_size == 0) {
            db = c.gst_buffer_ref(b);
        } else {
            db = c.gst_buffer_new();
            var off: usize = 0;
            var l = r.detect_buffers;
            while (l) |n| : (l = n.next) {
                const sz = c.gst_buffer_get_size(buf(n.data));
                _ = c.gst_buffer_copy_into(db, buf(n.data), c.GST_BUFFER_COPY_MEMORY, off, sz);
                off += sz;
            }
            if (b != null) _ = c.gst_buffer_copy_into(db, b, c.GST_BUFFER_COPY_MEMORY, off, c.gst_buffer_get_size(b));
        }
        ret = k.detect.?(p, db);
        c.gst_buffer_unref(db);
        if (ret == c.GST_FLOW_OK) {
            r.detecting = false;
            var l = r.detect_buffers;
            while (l) |n| : (l = n.next) {
                if (ret == c.GST_FLOW_OK and !r.flushing) ret = chain(p.sinkpad, par, buf(n.data)) else c.gst_buffer_unref(buf(n.data));
            }
            c.g_list_free(r.detect_buffers);
            r.detect_buffers = null;
            r.detect_buffers_size = 0;
            if (ret != c.GST_FLOW_OK) return ret;
        } else if (ret == c.GST_FLOW_NOT_NEGOTIATED) {
            if (r.drain) return c.GST_FLOW_ERROR;
            if (r.flushing) {
                freeDetect(r);
            } else {
                r.detect_buffers = c.g_list_append(r.detect_buffers, b);
                r.detect_buffers_size += @intCast(c.gst_buffer_get_size(b));
                return c.GST_FLOW_OK;
            }
        } else return ret;
    }
    if (b != null) {
        if (!r.disable_passthrough and r.passthrough) {
            var f: Frame = undefined;
            gst_base_parse_frame_init(&f);
            f.buffer = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(b)))));
            ret = gst_base_parse_push_frame(p, &f);
            gst_base_parse_frame_free(&f);
            return ret;
        }
        if (flag(b, c.GST_BUFFER_FLAG_DISCONT)) {
            if (p.segment.rate < 0.0) {
                ret = finishFragment(p, true);
                startFragment(p);
            } else {
                gst_base_parse_drain(p);
                r.discont = true;
            }
        }
        c.gst_adapter_push(r.adapter, b);
    }
    const fsize: c.guint = 1;
    while (!r.flushing) {
        var skip: c.gint = -1;
        var flush: c.gint = 0;
        var updated_prev_pts = false;
        var min_size = @max(r.min_frame_size, fsize);
        const av: c.guint = @truncate(c.gst_adapter_available(r.adapter));
        if (r.drain) {
            min_size = av;
            if (min_size == 0) break;
        }
        if (av < min_size) break;
        const pts = c.gst_adapter_prev_pts(r.adapter, null);
        const dts = c.gst_adapter_prev_dts(r.adapter, null);
        if (pts != NONE and r.prev_pts != pts) {
            r.prev_pts = pts;
            r.next_pts = pts;
            updated_prev_pts = true;
        }
        if (dts != NONE and r.prev_dts != dts) {
            r.prev_dts = dts;
            r.next_dts = dts;
            r.prev_dts_from_pts = false;
        }
        if (r.infer_ts and r.pts_interpolate and dts == NONE and (r.prev_dts == NONE or (r.prev_dts_from_pts and updated_prev_pts)) and pts != NONE) {
            r.prev_dts = pts;
            r.next_dts = pts;
            r.prev_dts_from_pts = true;
        }
        var tmp = c.gst_adapter_get_buffer(r.adapter, av);
        if (r.upstream_format == c.GST_FORMAT_TIME) {
            const updated = tmp[0].pts != r.next_pts or tmp[0].dts != r.next_dts;
            if (updated or r.infer_ts or r.pts_interpolate) {
                tmp = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(tmp)))));
                tmp[0].pts = r.next_pts;
                tmp[0].dts = r.next_dts;
                tmp[0].duration = NONE;
            }
        }
        ret = handleBuffer(p, tmp, &skip, &flush);
        if (ret != c.GST_FLOW_OK and ret != c.GST_FLOW_NOT_LINKED) break;
        if (skip == 0 and flush == 0) {
            ret = old_ret;
            break;
        }
        if (old_ret == c.GST_FLOW_OK) old_ret = ret;
    }
    return ret;
}

fn cachedAvailable(r: *Private) c.guint {
    if (r.cache == null) return 0;
    const co: i64 = @bitCast(r.cache[0].offset);
    const cs: c.gint = @truncate(@as(i64, @intCast(c.gst_buffer_get_size(r.cache))));
    if (r.offset >= co and r.offset < co + cs) return @truncate(@as(u64, @bitCast(cs - (r.offset - co))));
    return 0;
}

fn pullRange(p: *Parse, size: c.guint, out: *[*c]Buffer) c.GstFlowReturn {
    const r = priv(p);
    if (r.cache != null) {
        const co: i64 = @bitCast(r.cache[0].offset);
        const cs: c.gint = @truncate(@as(i64, @intCast(c.gst_buffer_get_size(r.cache))));
        if (co <= r.offset and r.offset + size <= co + cs) {
            out.* = c.gst_buffer_copy_region(r.cache, c.GST_BUFFER_COPY_ALL, @intCast(r.offset - co), size);
            out.*[0].offset = @bitCast(r.offset);
            return c.GST_FLOW_OK;
        }
        c.gst_buffer_unref(r.cache);
        r.cache = null;
    }
    const ret = c.gst_pad_pull_range(p.sinkpad, @bitCast(r.offset), @max(64 * 1024, size), &r.cache);
    if (ret != c.GST_FLOW_OK) {
        r.cache = null;
        return ret;
    }
    if (c.gst_buffer_get_size(r.cache) < size) {
        out.* = r.cache;
        r.cache = null;
        return c.GST_FLOW_OK;
    }
    r.cache[0].offset = @bitCast(r.offset);
    out.* = c.gst_buffer_copy_region(r.cache, c.GST_BUFFER_COPY_ALL, 0, size);
    out.*[0].offset = @bitCast(r.offset);
    return c.GST_FLOW_OK;
}

fn handlePreviousFragment(p: *Parse) c.GstFlowReturn {
    const r = priv(p);
    if (r.last_offset == 0 or r.last_pts <= p.segment.start) return c.GST_FLOW_EOS;
    var ts: u64 = 0;
    if (r.last_pts >= 10 * SEC) ts = r.last_pts - 10 * SEC;
    var off: i64 = 0;
    if (r.exact_position) off = findOffset(p, ts, true, null) else _ = convert(p, c.GST_FORMAT_TIME, @bitCast(ts), c.GST_FORMAT_BYTES, &off);
    off = std.math.clamp(off, r.last_offset - 1024 * 1024, r.last_offset - 1024);
    off = @max(0, off);
    r.offset = off;
    var b: [*c]Buffer = null;
    var ret = pullRange(p, @intCast(r.last_offset - off), &b);
    if (ret != c.GST_FLOW_OK) return ret;
    r.last_offset = off;
    startFragment(p);
    c.gst_adapter_push(r.adapter, b);
    ret = finishFragment(p, true);
    if (ret != c.GST_FLOW_OK) return ret;
    r.offset = -1;
    return ret;
}

fn scanFrame(p: *Parse) c.GstFlowReturn {
    const r = priv(p);
    const k = klass(p);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var fsize = cachedAvailable(r);
    if (fsize < 1024) fsize = 64 * 1024;
    var flushed: c.gint = 0;
    var skip: c.gint = 0;
    while (true) {
        const min_size = @max(r.min_frame_size, fsize);
        r.drain = false;
        var b: [*c]Buffer = null;
        ret = pullRange(p, min_size, &b);
        if (ret != c.GST_FLOW_OK) return ret;
        if (c.gst_buffer_get_size(b) < min_size) r.drain = true;
        if (r.detecting) {
            ret = k.detect.?(p, b);
            if (ret == c.GST_FLOW_NOT_NEGOTIATED) {
                c.gst_buffer_unref(b);
                if (r.drain) return c.GST_FLOW_ERROR;
                fsize += @min(fsize, 64 * 1024);
                continue;
            } else if (ret != c.GST_FLOW_OK) {
                c.gst_buffer_unref(b);
                return ret;
            }
        }
        ret = handleBuffer(p, b, &skip, &flushed);
        if (ret != c.GST_FLOW_OK) break;
        r.offset +%= r.skip;
        r.skip = 0;
        if (flushed != 0) break;
        if (skip == 0) {
            if (r.drain) {
                ret = c.GST_FLOW_EOS;
                break;
            }
            fsize += @min(fsize, 64 * 1024);
        }
    }
    return ret;
}

fn loop(data: c.gpointer) callconv(.c) void {
    const pad: ?*c.GstPad = @ptrCast(@alignCast(data));
    const p = of(c.gst_pad_get_parent(pad));
    const r = priv(p);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (r.push_stream_start) {
        const id = c.gst_pad_create_stream_id(p.srcpad, @ptrCast(p), null);
        const e = c.gst_event_new_stream_start(id);
        c.gst_event_set_group_id(e, c.gst_util_group_id_next());
        _ = c.gst_pad_push_event(p.srcpad, e);
        r.push_stream_start = false;
        c.g_free(id);
    }
    done: {
        if (p.segment.rate < 0.0 and r.offset < 0) {
            ret = handlePreviousFragment(p);
            break :done;
        }
        ret = scanFrame(p);
        if (p.segment.rate < 0.0 and ret == c.GST_FLOW_EOS and p.segment.position >= p.segment.stop) {
            _ = finishFragment(p, false);
            r.offset = -1;
        }
    }
    if (ret == c.GST_FLOW_OK) {
        c.gst_object_unref(p);
        return;
    }
    _ = c.gst_pad_pause_task(p.sinkpad);
    var push_eos = false;
    if (ret == c.GST_FLOW_EOS) {
        if (p.segment.flags & c.GST_SEGMENT_FLAG_SEGMENT != 0) {
            var stop: i64 = @bitCast(p.segment.stop);
            if (stop == -1) stop = @bitCast(p.segment.duration);
            _ = c.gst_element_post_message(@ptrCast(p), c.gst_message_new_segment_done(@ptrCast(p), c.GST_FORMAT_TIME, stop));
            _ = c.gst_pad_push_event(p.srcpad, c.gst_event_new_segment_done(c.GST_FORMAT_TIME, stop));
        } else {
            if (r.framecount == 0) el.err(p, .stream, c.GST_STREAM_ERROR_WRONG_TYPE, "No valid frames found before end of stream", null, FILE, "gst_base_parse_loop", 3763);
            push_eos = true;
        }
    } else if (ret == c.GST_FLOW_NOT_LINKED or ret < c.GST_FLOW_EOS) {
        el.flowError(p, ret, FILE, "gst_base_parse_loop", 3772);
        push_eos = true;
    }
    if (push_eos) {
        if (r.estimated_duration <= 0) updateDuration(p);
        pushPendingEvents(p);
        const e = c.gst_event_new_eos();
        if (r.segment_seqnum != SEQNUM_INVALID) c.gst_event_set_seqnum(e, r.segment_seqnum);
        _ = c.gst_pad_push_event(p.srcpad, e);
    }
    c.gst_object_unref(p);
}

fn sinkActivate(pad: ?*c.GstPad, par: [*c]c.GstObject) callconv(.c) c.gboolean {
    const p = of(par);
    const q = c.gst_query_new_scheduling();
    if (c.gst_pad_peer_query(pad, q) == 0) {
        c.gst_query_unref(q);
        return c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PUSH, 1);
    }
    var sched: c.GstSchedulingFlags = 0;
    c.gst_query_parse_scheduling(q, &sched, null, null, null);
    const pull = c.gst_query_has_scheduling_mode(q, c.GST_PAD_MODE_PULL) != 0 and sched & c.GST_SCHEDULING_FLAG_SEEKABLE != 0;
    c.gst_query_unref(q);
    if (!pull or c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PULL, 1) == 0) return c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PUSH, 1);
    priv(p).push_stream_start = true;
    priv(p).upstream_format = c.GST_FORMAT_BYTES;
    return c.gst_pad_start_task(pad, loop, pad, null);
}

fn activate(p: *Parse, active: bool) bool {
    const r = priv(p);
    const k = klass(p);
    var ok = true;
    if (active) {
        if (r.pad_mode == c.GST_PAD_MODE_NONE) {
            if (k.start) |f| ok = f(p) != 0;
        }
        r.detecting = k.detect != null;
    } else {
        el.streamLock(p.sinkpad);
        el.streamUnlock(p.sinkpad);
        if (r.pad_mode != c.GST_PAD_MODE_NONE) {
            if (k.stop) |f| ok = f(p) != 0;
        }
        r.pad_mode = c.GST_PAD_MODE_NONE;
        r.upstream_format = c.GST_FORMAT_UNDEFINED;
    }
    return ok;
}

fn sinkActivateMode(pad: ?*c.GstPad, par: [*c]c.GstObject, m: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const p = of(par);
    const r = priv(p);
    if (!activate(p, active != 0)) return 0;
    var ok = true;
    if (m == c.GST_PAD_MODE_PULL) {
        if (active != 0) {
            const e = c.gst_event_new_segment(&p.segment);
            if (r.segment_seqnum != SEQNUM_INVALID) c.gst_event_set_seqnum(e, r.segment_seqnum) else r.segment_seqnum = c.gst_event_get_seqnum(e);
            r.pending_events = c.g_list_prepend(r.pending_events, e);
        } else ok = c.gst_pad_stop_task(pad) != 0;
    }
    if (ok) r.pad_mode = if (active != 0) m else c.GST_PAD_MODE_NONE;
    return @intFromBool(ok);
}

pub export fn gst_base_parse_set_duration(sp: [*c]Parse, fmt: c.GstFormat, duration: c.gint64, interval: c.gint) void {
    if (!check.that(sp != null, "gst_base_parse_set_duration", "parse != NULL")) return;
    const p = of(sp);
    const r = priv(p);
    if (r.upstream_has_duration) return;
    const old = r.duration;
    r.duration = duration;
    r.duration_fmt = fmt;
    r.update_interval = if (fmt == c.GST_FORMAT_TIME and duration != -1) 0 else interval;
    if (duration != old) _ = c.gst_element_post_message(@ptrCast(p), c.gst_message_new_duration_changed(@ptrCast(p)));
}

pub export fn gst_base_parse_set_average_bitrate(sp: [*c]Parse, bitrate: c.guint) void {
    priv(sp).bitrate = bitrate;
}

pub export fn gst_base_parse_set_min_frame_size(sp: [*c]Parse, size: c.guint) void {
    if (!check.that(sp != null, "gst_base_parse_set_min_frame_size", "parse != NULL")) return;
    priv(sp).min_frame_size = size;
}

pub export fn gst_base_parse_set_frame_rate(sp: [*c]Parse, num: c.guint, den: c.guint, lead_in: c.guint, lead_out: c.guint) void {
    if (!check.that(sp != null, "gst_base_parse_set_frame_rate", "parse != NULL")) return;
    const r = priv(sp);
    r.fps_num = num;
    r.fps_den = den;
    if (num == 0 or den == 0) {
        r.frame_duration = NONE;
        r.lead_in = 0;
        r.lead_out = 0;
        r.lead_in_ts = 0;
        r.lead_out_ts = 0;
        return;
    }
    r.frame_duration = c.gst_util_uint64_scale(SEC, den, num);
    r.lead_in = lead_in;
    r.lead_out = lead_out;
    r.lead_in_ts = c.gst_util_uint64_scale(SEC, @as(c.guint, den *% lead_in), num);
    r.lead_out_ts = c.gst_util_uint64_scale(SEC, @as(c.guint, den *% lead_out), num);
    if (r.update_interval < 0) {
        const iv = c.gst_util_uint64_scale(num, 3, 2 * @as(u64, den));
        r.update_interval = @intCast(@min(iv, std.math.maxInt(c.gint)));
    }
}

pub export fn gst_base_parse_set_has_timing_info(sp: [*c]Parse, v: c.gboolean) void {
    priv(sp).has_timing_info = v != 0;
}

pub export fn gst_base_parse_set_syncable(sp: [*c]Parse, v: c.gboolean) void {
    priv(sp).syncable = v != 0;
}

pub export fn gst_base_parse_set_passthrough(sp: [*c]Parse, v: c.gboolean) void {
    priv(sp).passthrough = v != 0;
}

pub export fn gst_base_parse_set_pts_interpolation(sp: [*c]Parse, v: c.gboolean) void {
    priv(sp).pts_interpolate = v != 0;
}

pub export fn gst_base_parse_set_infer_ts(sp: [*c]Parse, v: c.gboolean) void {
    priv(sp).infer_ts = v != 0;
}

pub export fn gst_base_parse_set_latency(sp: [*c]Parse, min: c.GstClockTime, max: c.GstClockTime) void {
    if (!check.that(min != NONE, "gst_base_parse_set_latency", "GST_CLOCK_TIME_IS_VALID (min_latency)")) return;
    if (!check.that(min <= max, "gst_base_parse_set_latency", "min_latency <= max_latency")) return;
    const p = of(sp);
    const r = priv(p);
    var post = false;
    el.lock(p);
    if (r.min_latency != min) {
        r.min_latency = min;
        post = true;
    }
    if (r.max_latency != max) {
        r.max_latency = max;
        post = true;
    }
    if (!r.posted_latency_msg) {
        r.posted_latency_msg = true;
        post = true;
    }
    el.unlock(p);
    if (post) _ = c.gst_element_post_message(@ptrCast(p), c.gst_message_new_latency(@ptrCast(p)));
}

fn getDuration(p: *Parse, format: c.GstFormat, duration: *u64) bool {
    const r = priv(p);
    duration.* = NONE;
    if (r.duration != -1 and format == r.duration_fmt) {
        duration.* = @bitCast(r.duration);
        return true;
    }
    if (r.duration != -1) return convert(p, r.duration_fmt, r.duration, format, @ptrCast(duration));
    if (format == c.GST_FORMAT_TIME and r.estimated_duration != -1) {
        duration.* = @bitCast(r.estimated_duration);
        return true;
    }
    return false;
}

fn srcQueryDefault(sp: [*c]Parse, q: [*c]Query) callconv(.c) c.gboolean {
    const p = of(sp);
    const r = priv(p);
    const pad = p.srcpad;
    switch (q[0].type) {
        c.GST_QUERY_POSITION => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_position(q, &format, null);
            var res = c.gst_pad_query_default(pad, @ptrCast(p), q) != 0;
            if (res) return 1;
            var dest: i64 = 0;
            el.lock(p);
            if (format == c.GST_FORMAT_BYTES and r.upstream_format == c.GST_FORMAT_BYTES) {
                dest = r.offset;
                res = true;
            } else if (format == p.segment.format and p.segment.position != NONE) {
                dest = @bitCast(c.gst_segment_to_stream_time(&p.segment, p.segment.format, p.segment.position));
                res = true;
            }
            el.unlock(p);
            if (!res and r.upstream_format == c.GST_FORMAT_BYTES) res = convert(p, c.GST_FORMAT_BYTES, r.offset, format, &dest);
            if (res) c.gst_query_set_position(q, format, dest);
            return @intFromBool(res);
        },
        c.GST_QUERY_DURATION => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_duration(q, &format, null);
            if (c.gst_pad_query_default(pad, @ptrCast(p), q) != 0) return 1;
            var duration: u64 = NONE;
            if (!getDuration(p, format, &duration)) return 0;
            c.gst_query_set_duration(q, format, @bitCast(duration));
            return 1;
        },
        c.GST_QUERY_SEEKING => {
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_seeking(q, &fmt, null, null, null);
            var res = c.gst_pad_query_default(pad, @ptrCast(p), q);
            if (fmt == c.GST_FORMAT_TIME and r.syncable) {
                var seekable: c.gboolean = 0;
                c.gst_query_parse_seeking(q, &fmt, &seekable, null, null);
                if (!(res != 0 and seekable != 0)) {
                    var duration: u64 = NONE;
                    const s = if (!getDuration(p, c.GST_FORMAT_TIME, &duration) or duration == NONE) r.upstream_seekable and r.update_interval > 0 else r.upstream_seekable;
                    c.gst_query_set_seeking(q, c.GST_FORMAT_TIME, @intFromBool(s), 0, @bitCast(duration));
                    res = 1;
                }
            }
            return res;
        },
        c.GST_QUERY_FORMATS => {
            c.gst_query_set_formatsv(q, 3, &FMTLIST);
            return 1;
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            if (!convert(p, sf, sv, df, &dv)) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_LATENCY => {
            if (c.gst_pad_peer_query(p.sinkpad, q) == 0) return 0;
            var live: c.gboolean = 0;
            var min: u64 = 0;
            var max: u64 = 0;
            c.gst_query_parse_latency(q, &live, &min, &max);
            el.lock(p);
            min +%= r.min_latency;
            if (max == NONE or r.max_latency == NONE) max = NONE else max +%= r.max_latency;
            el.unlock(p);
            c.gst_query_set_latency(q, live, min, max);
            return 1;
        },
        c.GST_QUERY_SEGMENT => {
            const format = p.segment.format;
            const start: i64 = @bitCast(c.gst_segment_to_stream_time(&p.segment, format, p.segment.start));
            var stop: i64 = @bitCast(p.segment.stop);
            stop = if (stop == -1) @bitCast(p.segment.duration) else @bitCast(c.gst_segment_to_stream_time(&p.segment, format, p.segment.stop));
            c.gst_query_set_segment(q, p.segment.rate, format, start, stop);
            return 1;
        },
        else => return c.gst_pad_query_default(pad, @ptrCast(p), q),
    }
}

fn findFrame(p: *Parse, pos: *i64, time: *u64, duration: *u64) c.GstFlowReturn {
    const r = priv(p);
    time.* = NONE;
    duration.* = NONE;
    const orig_offset = r.offset;
    const orig_discont = r.discont;
    const orig_drain = r.drain;
    r.offset = pos.*;
    r.scanning = true;
    const ret = scanFrame(p);
    r.scanning = false;
    const sf = r.scanned_frame;
    r.scanned_frame = null;
    if (ret == c.GST_FLOW_OK) {
        if (sf) |f| {
            pos.* = @bitCast(f.offset);
            time.* = f.buffer[0].pts;
            duration.* = f.buffer[0].duration;
        }
    }
    if (sf) |f| gst_base_parse_frame_free(f);
    r.offset = orig_offset;
    r.discont = orig_discont;
    r.drain = orig_drain;
    return ret;
}

fn locateTime(p: *Parse, time_io: *u64, off_out: *i64) c.GstFlowReturn {
    const r = priv(p);
    const chunk: i64 = 4 * 1024;
    const time = time_io.*;
    if (time == 0) {
        off_out.* = 0;
        return c.GST_FLOW_OK;
    }
    if (time == NONE) {
        off_out.* = -1;
        return c.GST_FLOW_OK;
    }
    off_out.* = -1;
    time_io.* = NONE;
    var lpos = r.first_frame_offset;
    var ltime = r.first_frame_pts;
    if (ltime == NONE) ltime = r.first_frame_dts;
    var htime: u64 = NONE;
    if (!getDuration(p, c.GST_FORMAT_TIME, &htime)) return c.GST_FLOW_ERROR;
    var hpos = r.upstream_size;
    const maxi: u64 = std.math.maxInt(i64);
    if (r.pad_mode != c.GST_PAD_MODE_PULL or hpos == 0 or ltime == NONE or (htime == NONE and time != maxi)) return c.GST_FLOW_OK;
    if (time < ltime) return c.GST_FLOW_OK;
    if (time < ltime +% TARGET_DIFFERENCE) {
        off_out.* = lpos;
        time_io.* = ltime;
        return c.GST_FLOW_OK;
    }
    if (time >= htime) {
        off_out.* = hpos;
        time_io.* = htime;
        return c.GST_FLOW_OK;
    }
    var cont = true;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    while (htime > ltime and cont) {
        var newpos: i64 = undefined;
        if (time == maxi) {
            newpos = hpos;
        } else if (hpos > lpos) {
            newpos = @as(i64, @bitCast(c.gst_util_uint64_scale(@bitCast(hpos - lpos), time - ltime, htime - ltime))) + lpos - chunk;
        } else {
            newpos = lpos;
            cont = false;
        }
        newpos = std.math.clamp(newpos, lpos, hpos);
        var newtime: u64 = 0;
        var dur: u64 = 0;
        ret = findFrame(p, &newpos, &newtime, &dur);
        if (ret == c.GST_FLOW_EOS) {
            hpos = @max(lpos, hpos - chunk);
            continue;
        } else if (ret != c.GST_FLOW_OK) return ret;
        if (newtime == NONE or newpos == -1) break;
        if (time == maxi) {
            off_out.* = newpos;
            time_io.* = newtime;
            if (dur != NONE) time_io.* +%= dur;
            break;
        } else if (newtime > time) {
            hpos = if (newpos >= hpos) @max(lpos, hpos - chunk) else @max(lpos, newpos);
            htime = newtime;
        } else if (newtime +% TARGET_DIFFERENCE > time) {
            off_out.* = newpos;
            time_io.* = newtime;
            break;
        } else if (newtime < ltime) {
            break;
        } else {
            if (newpos == lpos) newpos += chunk;
            lpos = std.math.clamp(newpos, lpos, hpos);
            ltime = newtime;
        }
    }
    return ret;
}

fn findOffset(p: *Parse, time: u64, before: bool, ts_out: ?*u64) i64 {
    const r = priv(p);
    var bytes: i64 = 0;
    var ts: i64 = 0;
    if (time == NONE) {
        if (ts_out) |o| o.* = time;
        return -1;
    }
    c.g_mutex_lock(&r.index_lock);
    var entry: ?*index.Entry = null;
    if (r.index) |i| entry = index.assocEntry(i, r.index_id, if (before) index.LOOKUP_BEFORE else index.LOOKUP_AFTER, index.KEY_UNIT, c.GST_FORMAT_TIME, @bitCast(time));
    if (entry) |e| {
        _ = index.assocMap(e, c.GST_FORMAT_BYTES, &bytes);
        _ = index.assocMap(e, c.GST_FORMAT_TIME, &ts);
    } else if (!before) {
        bytes = -1;
        ts = -1;
    }
    c.g_mutex_unlock(&r.index_lock);
    if (ts_out) |o| o.* = @bitCast(ts);
    return bytes;
}

fn handleSeek(p: *Parse, e: [*c]Event) bool {
    const r = priv(p);
    defer c.gst_event_unref(e);
    if (r.pad_mode != c.GST_PAD_MODE_PULL) {
        if (c.gst_pad_push_event(p.sinkpad, c.gst_event_ref(e)) != 0) return true;
    }
    var rate: f64 = 0;
    var format: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var start_type: c.GstSeekType = c.GST_SEEK_TYPE_NONE;
    var stop_type: c.GstSeekType = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    c.gst_event_parse_seek(e, &rate, &format, &flags, &start_type, &start, &stop_type, &stop);
    const seqnum = c.gst_event_get_seqnum(e);
    r.segment_seqnum = seqnum;
    if (format != c.GST_FORMAT_TIME) {
        if (!convert(p, format, start, c.GST_FORMAT_TIME, &start) or !convert(p, format, stop, c.GST_FORMAT_TIME, &stop)) return false;
        format = c.GST_FORMAT_TIME;
    }
    if (rate < 0.0 and r.pad_mode == c.GST_PAD_MODE_PUSH) return false;
    if (start_type != c.GST_SEEK_TYPE_SET or (stop_type != c.GST_SEEK_TYPE_SET and stop_type != c.GST_SEEK_TYPE_NONE)) return false;
    const flush = flags & c.GST_SEEK_FLAG_FLUSH != 0;
    var seg = std.mem.zeroes(c.GstSegment);
    c.gst_segment_copy_into(&p.segment, &seg);
    var update: c.gboolean = 0;
    _ = c.gst_segment_do_seek(&seg, rate, format, flags, start_type, @bitCast(start), stop_type, @bitCast(stop), &update);
    var accurate = flags & c.GST_SEEK_FLAG_ACCURATE != 0;
    var start_ts: u64 = 0;
    _ = findOffset(p, seg.position, true, &start_ts);
    if (seg.position <= start_ts +% TARGET_DIFFERENCE) accurate = true;
    var seekpos: i64 = 0;
    var seekstop: i64 = 0;
    if (accurate) {
        var startpos: u64 = if (rate >= 0) seg.position else @bitCast(start);
        startpos = if (startpos < r.lead_in_ts) 0 else startpos - r.lead_in_ts;
        if (seg.stop == NONE and seg.duration != NONE) seg.stop = seg.start +% seg.duration;
        seekpos = findOffset(p, startpos, true, &start_ts);
        seekstop = findOffset(p, seg.stop, false, null);
    } else {
        start_ts = if (rate >= 0) seg.position else @bitCast(start);
        if (seg.stop == NONE and seg.duration != NONE) seg.stop = seg.start +% seg.duration;
        if (!convert(p, format, @bitCast(start_ts), c.GST_FORMAT_BYTES, &seekpos)) return false;
        if (!convert(p, format, @bitCast(seg.stop), c.GST_FORMAT_BYTES, &seekstop)) return false;
    }
    if (r.pad_mode == c.GST_PAD_MODE_PULL) {
        if (flush) {
            if (p.srcpad != null) {
                const fe = c.gst_event_new_flush_start();
                c.gst_event_set_seqnum(fe, seqnum);
                _ = c.gst_pad_push_event(p.srcpad, c.gst_event_ref(fe));
                _ = c.gst_pad_push_event(p.sinkpad, fe);
            }
        } else _ = c.gst_pad_pause_task(p.sinkpad);
        el.streamLock(p.sinkpad);
        if (flush) {
            const fe = c.gst_event_new_flush_stop(1);
            c.gst_event_set_seqnum(fe, seqnum);
            _ = c.gst_pad_push_event(p.srcpad, c.gst_event_ref(fe));
            _ = c.gst_pad_push_event(p.sinkpad, fe);
            clearQueues(p, false);
        }
        p.segment = seg;
        const se = c.gst_event_new_segment(&p.segment);
        c.gst_event_set_seqnum(se, seqnum);
        r.pending_events = c.g_list_prepend(r.pending_events, se);
        if (!accurate) {
            var ts = seg.position;
            var scanpos: i64 = 0;
            _ = locateTime(p, &ts, &scanpos);
            if (scanpos >= 0) {
                accurate = true;
                seekpos = scanpos;
                r.index_last_valid = false;
                r.index_last_offset = 0;
                r.index_last_ts = 0;
            }
        }
        if (seekpos != r.offset) {
            r.offset = seekpos;
            r.last_offset = seekpos;
            r.seen_keyframe = false;
            r.discont = true;
            r.next_dts = start_ts;
            r.next_pts = NONE;
            r.last_dts = NONE;
            r.last_pts = NONE;
            r.sync_offset = seekpos;
            r.exact_position = accurate;
        }
        _ = c.gst_pad_start_task(p.sinkpad, loop, p.sinkpad, null);
        el.streamUnlock(p.sinkpad);
        return true;
    }
    if (seekstop >= 0 and seekstop <= seekpos) seekstop = seekpos;
    const ne = c.gst_event_new_seek(rate, c.GST_FORMAT_BYTES, if (flush) c.GST_SEEK_FLAG_FLUSH else c.GST_SEEK_FLAG_NONE, c.GST_SEEK_TYPE_SET, seekpos, stop_type, seekstop);
    c.gst_event_set_seqnum(ne, seqnum);
    const seek: *Seek = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Seek))));
    seek.segment = seg;
    seek.accurate = accurate;
    seek.offset = seekpos;
    seek.start_ts = start_ts;
    el.lock(p);
    r.pending_seeks = c.g_slist_append(r.pending_seeks, seek);
    el.unlock(p);
    const res = c.gst_pad_push_event(p.sinkpad, ne) != 0;
    if (!res) {
        el.lock(p);
        r.pending_seeks = c.g_slist_remove(r.pending_seeks, seek);
        el.unlock(p);
        c.g_free(seek);
    }
    return res;
}

fn setUpstreamTags(p: *Parse, tags: ?*c.GstTagList) void {
    const r = priv(p);
    if (tags == r.upstream_tags) return;
    if (r.upstream_tags) |t| {
        c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
        r.upstream_tags = null;
    }
    if (tags) |t| r.upstream_tags = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(@alignCast(t)))));
    checkBitrateTags(p);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const p = of(e);
    const r = priv(p);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        c.g_mutex_lock(&r.index_lock);
        if (r.own_index) {
            c.gst_object_unref(r.index);
            r.index = null;
            r.own_index = false;
        }
        if (r.index == null) {
            const i = index.newMem();
            r.index = i;
            _ = index.writerId(i, @ptrCast(p), &r.index_id);
            r.own_index = true;
        }
        c.g_mutex_unlock(&r.index_lock);
    }
    const ret = parent.?.change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) reset(p);
    return ret;
}

pub export fn gst_base_parse_set_ts_at_offset(sp: [*c]Parse, offset: c.gsize) void {
    if (!check.that(isParse(sp), "gst_base_parse_set_ts_at_offset", "GST_IS_BASE_PARSE (parse)")) return;
    const r = priv(sp);
    const pts = c.gst_adapter_prev_pts_at_offset(r.adapter, offset, null);
    const dts = c.gst_adapter_prev_dts_at_offset(r.adapter, offset, null);
    if (pts != NONE and r.prev_pts != pts) {
        r.prev_pts = pts;
        r.next_pts = pts;
    }
    if (dts != NONE and r.prev_dts != dts) {
        r.prev_dts = dts;
        r.next_dts = dts;
        r.prev_dts_from_pts = false;
    }
}

pub export fn gst_base_parse_merge_tags(sp: [*c]Parse, tags: ?*c.GstTagList, m: c.GstTagMergeMode) void {
    const fname = "gst_base_parse_merge_tags";
    if (!check.that(isParse(sp), fname, "GST_IS_BASE_PARSE (parse)")) return;
    const is_list = tags == null or @as(*c.GstMiniObject, @ptrCast(@alignCast(tags))).type == c.gst_tag_list_get_type();
    if (!check.that(is_list, fname, "tags == NULL || GST_IS_TAG_LIST (tags)")) return;
    if (!check.that(tags == null or m != c.GST_TAG_MERGE_UNDEFINED, fname, "tags == NULL || mode != GST_TAG_MERGE_UNDEFINED")) return;
    const p = of(sp);
    const r = priv(p);
    el.lock(p);
    defer el.unlock(p);
    if (tags == r.parser_tags) return;
    if (r.parser_tags) |t| {
        c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
        r.parser_tags = null;
        r.parser_tags_merge_mode = c.GST_TAG_MERGE_APPEND;
    }
    if (tags) |t| {
        r.parser_tags = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(@alignCast(t)))));
        r.parser_tags_merge_mode = m;
    }
    checkBitrateTags(p);
    r.tags_changed = true;
}
