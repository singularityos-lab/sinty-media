const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const info = @import("info.zig");
const codec = @import("codecutils.zig");
const vevent = @import("event.zig");
const pool = @import("pool.zig");
const vutils = @import("vutils.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Dec = c.GstVideoDecoder;
const Class = c.GstVideoDecoderClass;
const Frame = c.GstVideoCodecFrame;
const State = c.GstVideoCodecState;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const NONE = el.NONE;
const VNONE = @as(?*anyopaque, null);
const SEC: u64 = c.GST_SECOND;
const MSEC: u64 = 1_000_000;
const PATH = "../gst-libs/gst/video/gstvideodecoder.c";
const PENDING: u64 = 0;
const UNSET: u64 = std.math.maxInt(u64);
const INSTANT_FLAGS: c.GstSegmentFlags = c.GST_SEGMENT_FLAG_TRICKMODE | c.GST_SEGMENT_FLAG_TRICKMODE_KEY_UNITS | c.GST_SEGMENT_FLAG_TRICKMODE_NO_AUDIO;
const AUTO_FLAGS: c.GstVideoDecoderRequestSyncPointFlags = c.GST_VIDEO_DECODER_REQUEST_SYNC_POINT_DISCARD_INPUT | c.GST_VIDEO_DECODER_REQUEST_SYNC_POINT_CORRUPT_OUTPUT;
const SYNC_POINT = c.GST_VIDEO_CODEC_FRAME_FLAG_SYNC_POINT;
const DECODE_ONLY = c.GST_VIDEO_CODEC_FRAME_FLAG_DECODE_ONLY;
const CORRUPTED = c.GST_VIDEO_CODEC_FRAME_FLAG_CORRUPTED;

const Private = struct {
    pool: [*c]c.GstBufferPool,
    allocator: [*c]c.GstAllocator,
    params: c.GstAllocationParams,
    input_adapter: ?*c.GstAdapter,
    output_adapter: ?*c.GstAdapter,
    do_estimate_rate: bool,
    packetized: bool,
    subframe_mode: bool,
    max_errors: c.gint,
    error_count: c.gint,
    had_output_data: bool,
    had_input_data: bool,
    needs_format: bool,
    in_out_segment_sync: bool,
    decode_flags_override: bool,
    decode_flags: c.GstSegmentFlags,
    current_frame: [*c]Frame,
    current_frame_events: [*c]c.GList,
    pending_events: [*c]c.GList,
    input_offset: u64,
    frame_offset: u64,
    timestamps: c.GQueue,
    last_timestamp_out: u64,
    pts_delta: u64,
    reordered_output: bool,
    consecutive_orderered_output: c.guint,
    gather: [*c]c.GList,
    parse: [*c]c.GList,
    parse_gather: [*c]c.GList,
    decode: [*c]c.GList,
    output_queued: [*c]c.GList,
    min_force_key_unit_interval: u64,
    discard_corrupted_frames: bool,
    needs_sync_point: bool,
    request_sync_point_flags: c.GstVideoDecoderRequestSyncPointFlags,
    request_sync_point_frame_number: u64,
    last_force_key_unit_time: u64,
    distance_from_sync: u64,
    automatic_request_sync_points: bool,
    automatic_request_sync_point_flags: c.GstVideoDecoderRequestSyncPointFlags,
    system_frame_number: u32,
    decode_frame_number: u32,
    frames: c.GQueue,
    input_state: [*c]State,
    output_state: [*c]State,
    output_state_changed: bool,
    do_qos: bool,
    proportion: f64,
    earliest_time: u64,
    qos_frame_duration: u64,
    discont: bool,
    dropped: c.guint,
    processed: c.guint,
    bytes_out: i64,
    time: i64,
    min_latency: i64,
    max_latency: i64,
    posted_latency_msg: bool,
    upstream_tags: ?*c.GstTagList,
    tags: ?*c.GstTagList,
    tags_merge_mode: c.GstTagMergeMode,
    tags_changed: bool,
    use_default_pad_acceptcaps: bool,
};

const Timestamp = struct {
    offset: u64,
    pts: u64,
    dts: u64,
    duration: u64,
    flags: c.guint,
};

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstElementClass = null;
var video_tag: c.GQuark = 0;

fn of(p: anytype) [*c]Dec {
    return @ptrCast(@alignCast(p));
}

fn priv(d: anytype) *Private {
    return @ptrCast(@alignCast(of(d).*.priv));
}

fn klass(d: anytype) *Class {
    return gtype.classPeek(Class, d);
}

fn isDec(d: anytype) bool {
    return gtype.instanceOf(d, gst_video_decoder_get_type());
}

fn streamLock(d: [*c]Dec) void {
    c.g_rec_mutex_lock(&d.*.stream_lock);
}

fn streamUnlock(d: [*c]Dec) void {
    c.g_rec_mutex_unlock(&d.*.stream_lock);
}

fn valid(t: u64) bool {
    return t != NONE;
}

fn post(d: [*c]Dec, kind: c.GstMessageType, domain: el.Domain, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    el.messageAt(d, kind, domain, code, text, debug, PATH, func, line, null);
}

fn bufFlags(b: [*c]Buffer) c.guint {
    return b[0].mini_object.flags;
}

fn bufHas(b: [*c]Buffer, f: c.guint) bool {
    return bufFlags(b) & f != 0;
}

fn frameHas(f: [*c]Frame, flag: c.guint32) bool {
    return f[0].flags & flag != 0;
}

fn unrefMini(p: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

fn unrefFrame(p: c.gpointer) callconv(.c) void {
    codec.gst_video_codec_frame_unref(@ptrCast(@alignCast(p)));
}

fn refFrame(p: c.gconstpointer, _: c.gpointer) callconv(.c) c.gpointer {
    return @ptrCast(codec.gst_video_codec_frame_ref(@ptrCast(@alignCast(@constCast(p)))));
}

fn freeTs(p: c.gpointer) callconv(.c) void {
    c.g_free(p);
}

fn evType(e: anytype) c.GstEventType {
    return @as([*c]Event, @ptrCast(@alignCast(e)))[0].type;
}

fn subframe(d: [*c]Dec) bool {
    return priv(d).subframe_mode;
}

fn newInputState(caps: [*c]c.GstCaps) [*c]State {
    const s: [*c]State = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(State))));
    s[0].ref_count = 1;
    info.gst_video_info_init(&s[0].info);
    if (info.gst_video_info_from_caps(&s[0].info, caps) == 0) {
        c.g_free(s);
        return null;
    }
    s[0].caps = c.gst_caps_ref(caps);
    const st = c.gst_caps_get_structure(caps, 0);
    const cd = c.gst_structure_get_value(st, "codec_data");
    if (cd != null and cd[0].g_type == c.gst_buffer_get_type()) s[0].codec_data = @ptrCast(@alignCast(c.g_value_dup_boxed(cd)));
    return s;
}

fn newOutputState(fmt: c.GstVideoFormat, mode: c.GstVideoInterlaceMode, width: c.guint, height: c.guint, reference: [*c]State, copy_mode: bool) [*c]State {
    const s: [*c]State = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(State))));
    s[0].ref_count = 1;
    info.gst_video_info_init(&s[0].info);
    if (info.gst_video_info_set_interlaced_format(&s[0].info, fmt, mode, width, height) == 0) {
        c.g_free(s);
        return null;
    }
    if (reference != null) {
        const t = &s[0].info;
        const r = &reference[0].info;
        if (copy_mode) t.interlace_mode = r.interlace_mode;
        t.flags = r.flags;
        t.chroma_site = r.chroma_site;
        t.colorimetry = r.colorimetry;
        t.par_n = r.par_n;
        t.par_d = r.par_d;
        t.fps_n = r.fps_n;
        t.fps_d = r.fps_d;
        t.views = r.views;
        t.ABI.abi.field_order = r.ABI.abi.field_order;
        if (r.ABI.abi.multiview_mode != c.GST_VIDEO_MULTIVIEW_MODE_NONE) {
            t.ABI.abi.multiview_mode = r.ABI.abi.multiview_mode;
            t.ABI.abi.multiview_flags = r.ABI.abi.multiview_flags;
        } else {
            t.ABI.abi.multiview_mode = c.GST_VIDEO_MULTIVIEW_MODE_MONO;
            t.ABI.abi.multiview_flags = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE;
        }
    }
    return s;
}

fn setcaps(d: [*c]Dec, caps: [*c]c.GstCaps) bool {
    const k = klass(d);
    const p = priv(d);
    streamLock(d);
    defer streamUnlock(d);
    if (p.input_state != null and c.gst_caps_is_equal(p.input_state[0].caps, caps) != 0) return true;
    const state = newInputState(caps);
    if (state == null) return false;
    if (k.set_format) |f| {
        if (f(d, state) == 0) {
            codec.gst_video_codec_state_unref(state);
            return false;
        }
    }
    if (p.input_state != null) codec.gst_video_codec_state_unref(p.input_state);
    p.input_state = state;
    return true;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const d = of(o);
    const p = priv(d);
    c.g_rec_mutex_clear(&d[0].stream_lock);
    if (p.input_adapter) |a| c.g_object_unref(a);
    p.input_adapter = null;
    if (p.output_adapter) |a| c.g_object_unref(a);
    p.output_adapter = null;
    if (p.input_state != null) codec.gst_video_codec_state_unref(p.input_state);
    if (p.output_state != null) codec.gst_video_codec_state_unref(p.output_state);
    if (p.pool != null) c.gst_object_unref(p.pool);
    p.pool = null;
    if (p.allocator != null) c.gst_object_unref(p.allocator);
    p.allocator = null;
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = priv(o);
    switch (id) {
        1 => c.g_value_set_boolean(v, @intFromBool(p.do_qos)),
        2 => c.g_value_set_int(v, gst_video_decoder_get_max_errors(of(o))),
        3 => c.g_value_set_uint64(v, p.min_force_key_unit_interval),
        4 => c.g_value_set_boolean(v, @intFromBool(p.discard_corrupted_frames)),
        5 => c.g_value_set_boolean(v, @intFromBool(p.automatic_request_sync_points)),
        6 => c.g_value_set_flags(v, p.automatic_request_sync_point_flags),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 1002),
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = priv(o);
    switch (id) {
        1 => p.do_qos = c.g_value_get_boolean(v) != 0,
        2 => gst_video_decoder_set_max_errors(of(o), c.g_value_get_int(v)),
        3 => p.min_force_key_unit_interval = c.g_value_get_uint64(v),
        4 => p.discard_corrupted_frames = c.g_value_get_boolean(v) != 0,
        5 => p.automatic_request_sync_points = c.g_value_get_boolean(v) != 0,
        6 => p.automatic_request_sync_point_flags = c.g_value_get_flags(v),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 1034),
    }
}

fn flush(d: [*c]Dec, hard: bool) c.GstFlowReturn {
    const k = klass(d);
    if (k.reset) |f| _ = f(d, @intFromBool(hard));
    if (k.flush) |f| _ = f(d);
    reset(d, false, hard);
    return c.GST_FLOW_OK;
}

fn mergedTags(d: [*c]Dec) [*c]Event {
    const p = priv(d);
    const merged = c.gst_tag_list_merge(p.upstream_tags, p.tags, p.tags_merge_mode);
    if (merged == null) return null;
    if (c.gst_tag_list_is_empty(merged) != 0) {
        c.gst_mini_object_unref(@ptrCast(merged));
        return null;
    }
    return c.gst_event_new_tag(merged);
}

fn pushEvent(d: [*c]Dec, event: [*c]Event) bool {
    if (event[0].type == c.GST_EVENT_SEGMENT) {
        var seg: c.GstSegment = undefined;
        c.gst_event_copy_segment(event, &seg);
        if (seg.format == c.GST_FORMAT_TIME) {
            streamLock(d);
            d[0].output_segment = seg;
            priv(d).in_out_segment_sync = c.gst_segment_is_equal(&d[0].input_segment, &seg) != 0;
            priv(d).last_timestamp_out = NONE;
            priv(d).earliest_time = NONE;
            streamUnlock(d);
        }
    }
    return c.gst_pad_push_event(d[0].srcpad, event) != 0;
}

fn parseAvailable(d: [*c]Dec, at_eos: bool, new_buffer_in: bool) c.GstFlowReturn {
    const k = klass(d);
    const p = priv(d);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var new_buffer = new_buffer_in;
    var available = c.gst_adapter_available(p.input_adapter);
    var inactive: c.guint = 0;
    while (available != 0 or new_buffer) {
        new_buffer = false;
        if (p.current_frame == null) p.current_frame = newFrame(d);
        const was = available;
        ret = k.parse.?(d, p.current_frame, p.input_adapter, @intFromBool(at_eos));
        if (ret != c.GST_FLOW_OK) break;
        available = c.gst_adapter_available(p.input_adapter);
        if (p.current_frame == null or available != was) {
            inactive = 0;
        } else {
            inactive += 1;
            if (inactive == 2) return c.GST_FLOW_ERROR;
        }
    }
    return ret;
}

fn drainOut(d: [*c]Dec, at_eos: bool) c.GstFlowReturn {
    const k = klass(d);
    const p = priv(d);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (d[0].input_segment.rate > 0.0) {
        if (!p.packetized) ret = parseAvailable(d, true, false);
        if (at_eos) {
            if (k.finish) |f| ret = f(d);
        } else if (k.drain) |f| ret = f(d);
    } else ret = flushParse(d, true);
    return ret;
}

fn flushEvents(pad: ?*c.GstPad, events: [*c]c.GList) [*c]c.GList {
    var l = events;
    while (l != null) : (l = l[0].next) {
        const e: [*c]Event = @ptrCast(@alignCast(l[0].data));
        const t = e[0].type;
        if (t != c.GST_EVENT_EOS and t != c.GST_EVENT_SEGMENT and t & c.GST_EVENT_TYPE_STICKY != 0) _ = c.gst_pad_store_sticky_event(pad, e);
        c.gst_mini_object_unref(@ptrCast(e));
    }
    c.g_list_free(events);
    return null;
}

fn negotiateDefaultCaps(d: [*c]Dec) bool {
    var templcaps = c.gst_pad_get_pad_template_caps(d[0].srcpad);
    var caps = c.gst_pad_peer_query_caps(d[0].srcpad, templcaps);
    if (caps != null) c.gst_caps_unref(templcaps) else caps = templcaps;
    templcaps = null;
    if (caps == null or c.gst_caps_is_empty(caps) != 0 or c.gst_caps_is_any(caps) != 0) {
        if (caps != null) c.gst_caps_unref(caps);
        return false;
    }
    caps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps)));
    const n = c.gst_caps_get_size(caps);
    const p = priv(d);
    if (p.input_state != null and p.input_state[0].caps != null) {
        const st = c.gst_caps_get_structure(p.input_state[0].caps, 0);
        var w: c.gint = 0;
        var h: c.gint = 0;
        if (c.gst_structure_get_int(st, "width", &w) != 0) {
            for (0..n) |i| c.gst_structure_set(c.gst_caps_get_structure(caps, @intCast(i)), "width", c.G_TYPE_INT, w, VNONE);
        }
        if (c.gst_structure_get_int(st, "height", &h) != 0) {
            for (0..n) |i| c.gst_structure_set(c.gst_caps_get_structure(caps, @intCast(i)), "height", c.G_TYPE_INT, h, VNONE);
        }
    }
    for (0..n) |i| {
        const st = c.gst_caps_get_structure(caps, @intCast(i));
        if (c.gst_structure_has_field(st, "format") != 0) _ = c.gst_structure_fixate_field_string(st, "format", "I420") else c.gst_structure_set(st, "format", c.G_TYPE_STRING, "I420", VNONE);
        if (c.gst_structure_has_field(st, "width") != 0) _ = c.gst_structure_fixate_field_nearest_int(st, "width", 1280) else c.gst_structure_set(st, "width", c.G_TYPE_INT, @as(c.gint, 1280), VNONE);
        if (c.gst_structure_has_field(st, "height") != 0) _ = c.gst_structure_fixate_field_nearest_int(st, "height", 720) else c.gst_structure_set(st, "height", c.G_TYPE_INT, @as(c.gint, 720), VNONE);
    }
    caps = c.gst_caps_fixate(caps);
    var vi: c.GstVideoInfo = undefined;
    if (caps == null or info.gst_video_info_from_caps(&vi, caps) == 0) {
        if (caps != null) c.gst_caps_unref(caps);
        return false;
    }
    const state = gst_video_decoder_set_output_state(d, vi.finfo[0].format, @bitCast(vi.width), @bitCast(vi.height), p.input_state);
    codec.gst_video_codec_state_unref(state);
    c.gst_caps_unref(caps);
    return true;
}

fn missingDataDefault(d: [*c]Dec, timestamp: c.GstClockTime, _: c.GstClockTime) callconv(.c) c.gboolean {
    if (d[0].input_segment.format != c.GST_FORMAT_TIME) return 0;
    const p = priv(d);
    if (p.automatic_request_sync_points) {
        const deadline = c.gst_segment_to_running_time(&d[0].input_segment, c.GST_FORMAT_TIME, timestamp);
        requestSyncPoint(d, deadline, p.automatic_request_sync_point_flags);
    }
    return 1;
}

fn handleGap(d: [*c]Dec, event: [*c]Event) bool {
    const k = klass(d);
    const p = priv(d);
    var ts: c.GstClockTime = 0;
    var dur: c.GstClockTime = 0;
    var gflags: c.GstGapFlags = 0;
    c.gst_event_parse_gap(event, &ts, &dur);
    c.gst_event_parse_gap_flags(event, &gflags);
    streamLock(d);
    const handled = gflags & c.GST_GAP_FLAG_MISSING_DATA == 0 or k.handle_missing_data == null or k.handle_missing_data.?(d, ts, dur) != 0;
    if (!handled) {
        streamUnlock(d);
        c.gst_mini_object_unref(@ptrCast(event));
        return false;
    }
    var flow: c.GstFlowReturn = c.GST_FLOW_OK;
    var reconf = false;
    if (d[0].input_segment.flags & c.GST_SEEK_FLAG_TRICKMODE_KEY_UNITS != 0) {
        flow = drainOut(d, false);
    } else if (p.frames.length > 0) {
        p.current_frame_events = c.g_list_prepend(p.current_frame_events, event);
        streamUnlock(d);
        return true;
    }
    if (p.output_state == null) {
        if (!negotiateDefaultCaps(d)) {
            streamUnlock(d);
            post(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup("Decoder output not negotiated before GAP event."), "gst_video_decoder_handle_gap", 1385);
            return pushEvent(d, event);
        }
        reconf = true;
    }
    reconf = c.gst_pad_check_reconfigure(d[0].srcpad) != 0 or reconf;
    if (p.output_state_changed or reconf) {
        if (!negotiateUnlocked(d)) c.gst_pad_mark_reconfigure(d[0].srcpad);
    }
    const events = p.pending_events;
    const fevents = p.current_frame_events;
    p.pending_events = null;
    p.current_frame_events = null;
    streamUnlock(d);
    pushEventList(d, events);
    pushEventList(d, fevents);
    return pushEvent(d, event);
}

fn sinkEventDefault(d: [*c]Dec, event_in: [*c]Event) callconv(.c) c.gboolean {
    const p = priv(d);
    var event = event_in;
    var ret = false;
    var forward = false;
    switch (event[0].type) {
        c.GST_EVENT_STREAM_START => {
            streamLock(d);
            ret = drainOut(d, false) == c.GST_FLOW_OK;
            if (p.upstream_tags) |t| {
                c.gst_mini_object_unref(@ptrCast(t));
                p.upstream_tags = null;
                p.tags_changed = true;
            }
            streamUnlock(d);
            forward = true;
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(event, &caps);
            ret = setcaps(d, caps);
            c.gst_mini_object_unref(@ptrCast(event));
            event = null;
        },
        c.GST_EVENT_SEGMENT_DONE => {
            streamLock(d);
            const f = drainOut(d, false);
            streamUnlock(d);
            ret = f == c.GST_FLOW_OK;
            forward = true;
        },
        c.GST_EVENT_EOS => {
            streamLock(d);
            const f = drainOut(d, true);
            streamUnlock(d);
            ret = f == c.GST_FLOW_OK;
            if (ret and p.had_input_data and !p.had_output_data) post(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_DECODE, c.g_strdup("No valid frames decoded before end of stream"), c.g_strdup("no valid frames found"), "gst_video_decoder_sink_event_default", 1503);
            forward = true;
        },
        c.GST_EVENT_GAP => {
            ret = handleGap(d, event);
            event = null;
        },
        c.GST_EVENT_CUSTOM_DOWNSTREAM => {
            var still: c.gboolean = 0;
            if (vevent.gst_video_event_parse_still_frame(event, &still) != 0) {
                if (still != 0) {
                    streamLock(d);
                    const f = drainOut(d, false);
                    streamUnlock(d);
                    ret = f == c.GST_FLOW_OK;
                }
                forward = true;
            }
        },
        c.GST_EVENT_SEGMENT => {
            var seg: c.GstSegment = undefined;
            c.gst_event_copy_segment(event, &seg);
            const seqnum = c.gst_event_get_seqnum(event);
            if (seg.format != c.GST_FORMAT_TIME) {
                var start: i64 = 0;
                if (p.do_estimate_rate and c.gst_pad_query_convert(d[0].sinkpad, c.GST_FORMAT_BYTES, @bitCast(seg.start), c.GST_FORMAT_TIME, &start) != 0) {
                    seg.start = @bitCast(start);
                    seg.stop = NONE;
                    seg.time = @bitCast(start);
                    c.gst_mini_object_unref(@ptrCast(event));
                    event = c.gst_event_new_segment(&seg);
                    c.gst_event_set_seqnum(event, seqnum);
                } else {
                    c.gst_mini_object_unref(@ptrCast(event));
                    return 1;
                }
            }
            streamLock(d);
            el.lock(d);
            if (!p.decode_flags_override) {
                p.decode_flags = seg.flags;
            } else {
                seg.flags &= ~INSTANT_FLAGS;
                seg.flags |= p.decode_flags & INSTANT_FLAGS;
            }
            d[0].input_segment = seg;
            p.in_out_segment_sync = false;
            el.unlock(d);
            streamUnlock(d);
        },
        c.GST_EVENT_INSTANT_RATE_CHANGE => {
            var flags: c.GstSegmentFlags = 0;
            c.gst_event_parse_instant_rate_change(event, null, &flags);
            el.lock(d);
            p.decode_flags_override = true;
            p.decode_flags = flags;
            d[0].input_segment.flags &= ~INSTANT_FLAGS;
            d[0].input_segment.flags |= p.decode_flags & INSTANT_FLAGS;
            el.unlock(d);
        },
        c.GST_EVENT_FLUSH_STOP => {
            streamLock(d);
            var l = p.frames.head;
            while (l != null) : (l = l[0].next) {
                const f: [*c]Frame = @ptrCast(@alignCast(l[0].data));
                f[0].events = flushEvents(d[0].srcpad, f[0].events);
            }
            p.current_frame_events = flushEvents(d[0].srcpad, p.current_frame_events);
            _ = flush(d, true);
            streamUnlock(d);
            forward = true;
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(event, &tags);
            if (c.gst_tag_list_get_scope(tags) == c.GST_TAG_SCOPE_STREAM) {
                streamLock(d);
                if (p.upstream_tags != tags) {
                    if (p.upstream_tags) |t| c.gst_mini_object_unref(@ptrCast(t));
                    p.upstream_tags = @ptrCast(c.gst_mini_object_ref(@ptrCast(tags)));
                }
                c.gst_mini_object_unref(@ptrCast(event));
                event = mergedTags(d);
                streamUnlock(d);
                if (event == null) ret = true;
            }
        },
        else => {},
    }
    if (event != null) {
        if (event[0].type & c.GST_EVENT_TYPE_SERIALIZED == 0 or forward) {
            ret = pushEvent(d, event);
        } else {
            streamLock(d);
            p.current_frame_events = c.g_list_prepend(p.current_frame_events, event);
            streamUnlock(d);
            ret = true;
        }
    }
    return @intFromBool(ret);
}

fn sinkEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, event: [*c]Event) callconv(.c) c.gboolean {
    const d = of(parent_obj);
    if (klass(d).sink_event) |f| return f(d, event);
    return 0;
}

fn doByte(d: [*c]Dec) bool {
    el.lock(d);
    defer el.unlock(d);
    const p = priv(d);
    return p.do_estimate_rate and p.bytes_out > 0 and p.time > @as(i64, @intCast(SEC));
}

fn doSeek(d: [*c]Dec, event: [*c]Event) bool {
    var fmt: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var rate: f64 = 0;
    var start_time: i64 = 0;
    var end_time: i64 = 0;
    c.gst_event_parse_seek(event, &rate, &fmt, &flags, &st, &start_time, &et, &end_time);
    if (rate != 1.0 or st != c.GST_SEEK_TYPE_SET) return false;
    if ((et != c.GST_SEEK_TYPE_SET and et != c.GST_SEEK_TYPE_NONE) or (et == c.GST_SEEK_TYPE_SET and end_time != -1)) return false;
    if (flags & c.GST_SEEK_FLAG_FLUSH == 0) return false;
    var seg = d[0].output_segment;
    _ = c.gst_segment_do_seek(&seg, rate, fmt, flags, st, @bitCast(start_time), et, @bitCast(end_time), null);
    var start: i64 = 0;
    if (c.gst_pad_query_convert(d[0].sinkpad, c.GST_FORMAT_TIME, @bitCast(seg.position), c.GST_FORMAT_BYTES, &start) == 0) return false;
    const seqnum = c.gst_event_get_seqnum(event);
    const ev = c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, flags, c.GST_SEEK_TYPE_SET, start, c.GST_SEEK_TYPE_NONE, -1);
    c.gst_event_set_seqnum(ev, seqnum);
    return c.gst_pad_push_event(d[0].sinkpad, ev) != 0;
}

fn srcEventDefault(d: [*c]Dec, event: [*c]Event) callconv(.c) c.gboolean {
    const p = priv(d);
    switch (event[0].type) {
        c.GST_EVENT_SEEK => {
            var fmt: c.GstFormat = 0;
            var rate: f64 = 0;
            var flags: c.GstSeekFlags = 0;
            var st: c.GstSeekType = 0;
            var et: c.GstSeekType = 0;
            var start: i64 = 0;
            var stop: i64 = 0;
            c.gst_event_parse_seek(event, &rate, &fmt, &flags, &st, &start, &et, &stop);
            const seqnum = c.gst_event_get_seqnum(event);
            if (c.gst_pad_push_event(d[0].sinkpad, event) != 0) return 1;
            if (fmt == c.GST_FORMAT_TIME) {
                if (doByte(d)) return @intFromBool(doSeek(d, event));
                return 0;
            }
            var tstart: i64 = 0;
            var tstop: i64 = 0;
            if (c.gst_pad_query_convert(d[0].srcpad, fmt, start, c.GST_FORMAT_TIME, &tstart) == 0) return 0;
            if (c.gst_pad_query_convert(d[0].srcpad, fmt, stop, c.GST_FORMAT_TIME, &tstop) == 0) return 0;
            const ev = c.gst_event_new_seek(rate, c.GST_FORMAT_TIME, flags, st, tstart, et, tstop);
            c.gst_event_set_seqnum(ev, seqnum);
            return c.gst_pad_push_event(d[0].sinkpad, ev);
        },
        c.GST_EVENT_QOS => {
            var t: c.GstQOSType = 0;
            var proportion: f64 = 0;
            var diff: c.GstClockTimeDiff = 0;
            var ts: c.GstClockTime = 0;
            c.gst_event_parse_qos(event, &t, &proportion, &diff, &ts);
            el.lock(d);
            p.proportion = proportion;
            if (valid(ts)) {
                if (diff > 0) {
                    p.earliest_time = ts +% @as(u64, @bitCast(@min(2 * diff, @as(i64, @intCast(SEC))))) +% p.qos_frame_duration;
                } else p.earliest_time = ts +% @as(u64, @bitCast(diff));
            } else p.earliest_time = NONE;
            el.unlock(d);
            return c.gst_pad_push_event(d[0].sinkpad, event);
        },
        else => return c.gst_pad_push_event(d[0].sinkpad, event),
    }
}

fn srcEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, event: [*c]Event) callconv(.c) c.gboolean {
    const d = of(parent_obj);
    if (klass(d).src_event) |f| return f(d, event);
    return 0;
}

fn srcQueryDefault(d: [*c]Dec, query: [*c]Query) callconv(.c) c.gboolean {
    const pad = d[0].srcpad;
    const p = priv(d);
    switch (query[0].type) {
        c.GST_QUERY_POSITION => {
            if (c.gst_pad_peer_query(d[0].sinkpad, query) != 0) return 1;
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_position(query, &fmt, null);
            if (fmt == c.GST_FORMAT_BYTES) return 0;
            const time = c.gst_segment_to_stream_time(&d[0].output_segment, c.GST_FORMAT_TIME, p.last_timestamp_out);
            var value: i64 = 0;
            if (c.gst_pad_query_convert(pad, c.GST_FORMAT_TIME, @bitCast(time), fmt, &value) == 0) return 0;
            c.gst_query_set_position(query, fmt, value);
            return 1;
        },
        c.GST_QUERY_DURATION => {
            if (c.gst_pad_query_default(pad, @ptrCast(d), query) != 0) return 1;
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_duration(query, &fmt, null);
            var res: c.gboolean = 0;
            if (fmt == c.GST_FORMAT_TIME and doByte(d)) {
                var value: i64 = 0;
                if (c.gst_pad_peer_query_duration(d[0].sinkpad, c.GST_FORMAT_BYTES, &value) != 0) {
                    if (c.gst_pad_query_convert(d[0].sinkpad, c.GST_FORMAT_BYTES, value, c.GST_FORMAT_TIME, &value) != 0) {
                        c.gst_query_set_duration(query, c.GST_FORMAT_TIME, value);
                        res = 1;
                    }
                }
            }
            return res;
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(query, &sf, &sv, &df, &dv);
            el.lock(d);
            const res = if (p.output_state != null) vutils.rawvideoConvert(p.output_state, sf, sv, &df, &dv) else false;
            el.unlock(d);
            if (!res) return 0;
            c.gst_query_set_convert(query, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_LATENCY => {
            const res = c.gst_pad_peer_query(d[0].sinkpad, query);
            if (res != 0) {
                var live: c.gboolean = 0;
                var min: c.GstClockTime = 0;
                var max: c.GstClockTime = 0;
                c.gst_query_parse_latency(query, &live, &min, &max);
                el.lock(d);
                min +%= @bitCast(p.min_latency);
                if (max == NONE or p.max_latency == -1) max = NONE else max +%= @bitCast(p.max_latency);
                el.unlock(d);
                c.gst_query_set_latency(query, live, min, max);
            }
            return res;
        },
        else => return c.gst_pad_query_default(pad, @ptrCast(d), query),
    }
}

fn srcQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, query: [*c]Query) callconv(.c) c.gboolean {
    const d = of(parent_obj);
    if (klass(d).src_query) |f| return f(d, query);
    return 0;
}

pub export fn gst_video_decoder_proxy_getcaps(decoder: [*c]Dec, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    return vutils.proxyGetcaps(decoder[0].sinkpad, decoder[0].srcpad, caps, filter);
}

fn sinkGetcaps(d: [*c]Dec, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    if (klass(d).getcaps) |f| return f(d, filter);
    return gst_video_decoder_proxy_getcaps(d, null, filter);
}

fn sinkQueryDefault(d: [*c]Dec, query: [*c]Query) callconv(.c) c.gboolean {
    const pad = d[0].sinkpad;
    const p = priv(d);
    switch (query[0].type) {
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(query, &sf, &sv, &df, &dv);
            el.lock(d);
            const res = vutils.encodedConvert(p.bytes_out, p.time, sf, sv, &df, &dv);
            el.unlock(d);
            if (!res) return 0;
            c.gst_query_set_convert(query, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_ALLOCATION => {
            if (klass(d).propose_allocation) |f| return f(d, query);
            return 0;
        },
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(query, &filter);
            const caps = sinkGetcaps(d, filter);
            c.gst_query_set_caps_result(query, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            if (p.use_default_pad_acceptcaps) return c.gst_pad_query_default(pad, @ptrCast(d), query);
            var caps: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(query, &caps);
            const templ = c.gst_pad_get_pad_template_caps(pad);
            var accept = c.gst_caps_is_subset(caps, templ) != 0;
            c.gst_caps_unref(templ);
            if (accept) {
                const allowed = c.gst_pad_query_caps(pad, caps);
                accept = c.gst_caps_can_intersect(caps, allowed) != 0;
                c.gst_caps_unref(allowed);
            }
            c.gst_query_set_accept_caps_result(query, @intFromBool(accept));
            return 1;
        },
        else => return c.gst_pad_query_default(pad, @ptrCast(d), query),
    }
}

fn sinkQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, query: [*c]Query) callconv(.c) c.gboolean {
    const d = of(parent_obj);
    if (klass(d).sink_query) |f| return f(d, query);
    return 0;
}

fn addBufferInfo(d: [*c]Dec, buf: [*c]Buffer) void {
    const p = priv(d);
    if (!valid(buf[0].pts) and !valid(buf[0].dts) and !valid(buf[0].duration) and bufFlags(buf) == 0) return;
    const ts: *Timestamp = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Timestamp))));
    ts.* = .{ .offset = p.input_offset, .pts = buf[0].pts, .dts = buf[0].dts, .duration = buf[0].duration, .flags = bufFlags(buf) };
    c.g_queue_push_tail(&p.timestamps, ts);
}

fn infoAtOffset(d: [*c]Dec, offset: u64, pts: *u64, dts: *u64, duration: *u64, flags: *c.guint) void {
    const p = priv(d);
    pts.* = NONE;
    dts.* = NONE;
    duration.* = NONE;
    flags.* = 0;
    var g = p.timestamps.head;
    while (g != null) {
        const ts: *Timestamp = @ptrCast(@alignCast(g[0].data));
        if (ts.offset > offset) break;
        const next = g[0].next;
        pts.* = ts.pts;
        dts.* = ts.dts;
        duration.* = ts.duration;
        flags.* = ts.flags;
        c.g_queue_delete_link(&p.timestamps, g);
        g = next;
        c.g_free(ts);
    }
}

fn clearQueues(d: [*c]Dec) void {
    const p = priv(d);
    c.g_list_free_full(p.output_queued, unrefMini);
    p.output_queued = null;
    c.g_list_free_full(p.gather, unrefMini);
    p.gather = null;
    c.g_list_free_full(p.decode, unrefFrame);
    p.decode = null;
    c.g_list_free_full(p.parse, unrefMini);
    p.parse = null;
    c.g_list_free_full(p.parse_gather, unrefFrame);
    p.parse_gather = null;
    c.g_queue_clear_full(&p.frames, unrefFrame);
}

fn reset(d: [*c]Dec, full: bool, flush_hard: bool) void {
    const p = priv(d);
    streamLock(d);
    if (full or flush_hard) {
        c.gst_segment_init(&d[0].input_segment, c.GST_FORMAT_UNDEFINED);
        c.gst_segment_init(&d[0].output_segment, c.GST_FORMAT_UNDEFINED);
        clearQueues(d);
        p.in_out_segment_sync = true;
        if (p.current_frame != null) {
            codec.gst_video_codec_frame_unref(p.current_frame);
            p.current_frame = null;
        }
        c.g_list_free_full(p.current_frame_events, unrefMini);
        p.current_frame_events = null;
        c.g_list_free_full(p.pending_events, unrefMini);
        p.pending_events = null;
        p.error_count = 0;
        p.had_output_data = false;
        p.had_input_data = false;
        el.lock(d);
        p.earliest_time = NONE;
        p.proportion = 0.5;
        p.decode_flags_override = false;
        p.request_sync_point_flags = 0;
        p.request_sync_point_frame_number = UNSET;
        p.last_force_key_unit_time = NONE;
        el.unlock(d);
        p.distance_from_sync = UNSET;
    }
    if (full) {
        if (p.input_state != null) codec.gst_video_codec_state_unref(p.input_state);
        p.input_state = null;
        el.lock(d);
        if (p.output_state != null) codec.gst_video_codec_state_unref(p.output_state);
        p.output_state = null;
        p.qos_frame_duration = 0;
        el.unlock(d);
        if (p.tags) |t| c.gst_mini_object_unref(@ptrCast(t));
        p.tags = null;
        p.tags_merge_mode = c.GST_TAG_MERGE_APPEND;
        if (p.upstream_tags) |t| c.gst_mini_object_unref(@ptrCast(t));
        p.upstream_tags = null;
        p.tags_changed = false;
        p.reordered_output = false;
        p.consecutive_orderered_output = 0;
        p.dropped = 0;
        p.processed = 0;
        p.posted_latency_msg = false;
        p.decode_frame_number = 0;
        if (p.pool != null) {
            _ = c.gst_buffer_pool_set_active(p.pool, 0);
            c.gst_object_unref(p.pool);
            p.pool = null;
        }
        if (p.allocator != null) {
            c.gst_object_unref(p.allocator);
            p.allocator = null;
        }
    }
    p.discont = true;
    p.last_timestamp_out = NONE;
    p.pts_delta = NONE;
    p.input_offset = 0;
    p.frame_offset = 0;
    c.gst_adapter_clear(p.input_adapter);
    c.gst_adapter_clear(p.output_adapter);
    c.g_queue_clear_full(&p.timestamps, freeTs);
    el.lock(d);
    p.bytes_out = 0;
    p.time = 0;
    el.unlock(d);
    streamUnlock(d);
}

fn chainForward(d: [*c]Dec, buf_in: [*c]Buffer, at_eos: bool) c.GstFlowReturn {
    const p = priv(d);
    const k = klass(d);
    var buf = buf_in;
    if (!check.that(p.packetized or k.parse != null, "gst_video_decoder_chain_forward", "priv->packetized || klass->parse")) return c.GST_FLOW_ERROR;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (d[0].input_segment.rate > 0.0 and bufHas(buf, c.GST_BUFFER_FLAG_DISCONT) and d[0].input_segment.flags & c.GST_SEEK_FLAG_TRICKMODE_KEY_UNITS != 0) ret = drainOut(d, false);
    if (p.current_frame == null) p.current_frame = newFrame(d);
    if (!p.packetized) addBufferInfo(d, buf);
    p.input_offset +%= c.gst_buffer_get_size(buf);
    if (bufHas(buf, c.GST_BUFFER_FLAG_DECODE_ONLY)) p.current_frame[0].flags |= DECODE_ONLY;
    if (p.packetized) {
        const frame = p.current_frame;
        var was_key = false;
        if (subframe(d)) {
            frame[0].abidata.ABI.num_subframes += 1;
            if (!bufHas(buf, c.GST_BUFFER_FLAG_MARKER) and d[0].input_segment.rate > 0.0) {
                p.current_frame = codec.gst_video_codec_frame_ref(frame);
            } else p.current_frame = null;
        } else p.current_frame = frame;
        if (!bufHas(buf, c.GST_BUFFER_FLAG_DELTA_UNIT)) {
            was_key = true;
            frame[0].flags |= SYNC_POINT;
        }
        replaceInputBuffer(d, frame, &buf);
        if (d[0].input_segment.rate < 0.0) {
            p.parse_gather = c.g_list_prepend(p.parse_gather, frame);
            p.current_frame = null;
        } else {
            ret = decodeFrame(d, frame);
            if (!subframe(d)) p.current_frame = null;
        }
        if (ret == c.GST_FLOW_OK and was_key and d[0].input_segment.rate > 0.0 and d[0].input_segment.flags & c.GST_SEEK_FLAG_TRICKMODE_KEY_UNITS != 0) ret = drainOut(d, false);
    } else {
        c.gst_adapter_push(p.input_adapter, buf);
        ret = parseAvailable(d, at_eos, true);
    }
    if (ret == c.GST_VIDEO_DECODER_FLOW_NEED_DATA) return c.GST_FLOW_OK;
    return ret;
}

fn flushDecode(d: [*c]Dec) c.GstFlowReturn {
    const p = priv(d);
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    var walk = p.decode;
    var current: [*c]Frame = null;
    while (walk != null) {
        const frame: [*c]Frame = @ptrCast(@alignCast(walk[0].data));
        var last = true;
        if (subframe(d)) {
            if (current == null) {
                current = codec.gst_video_codec_frame_ref(frame);
            } else {
                if (current[0].input_buffer != null) {
                    copyMetas(d, current, current[0].input_buffer, current[0].output_buffer);
                    c.gst_mini_object_unref(@ptrCast(current[0].input_buffer));
                }
                current[0].input_buffer = @ptrCast(c.gst_mini_object_ref(@ptrCast(frame[0].input_buffer)));
                codec.gst_video_codec_frame_unref(frame);
            }
            last = bufHas(current[0].input_buffer, c.GST_BUFFER_FLAG_MARKER);
        } else current = frame;
        const next = walk[0].next;
        p.decode = c.g_list_delete_link(p.decode, walk);
        res = decodeFrame(d, current);
        if (res != c.GST_FLOW_OK) break;
        if (!subframe(d) or last) current = null;
        walk = next;
    }
    return res;
}

fn flushParse(d: [*c]Dec, at_eos: bool) c.GstFlowReturn {
    const p = priv(d);
    const k = klass(d);
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    p.gather = c.g_list_reverse(p.gather);
    p.parse = c.g_list_concat(p.gather, p.parse);
    p.gather = null;
    _ = flush(d, false);
    var walk = p.parse;
    while (walk != null) {
        const buf: [*c]Buffer = @ptrCast(@alignCast(walk[0].data));
        const next = walk[0].next;
        _ = c.gst_mini_object_ref(@ptrCast(buf));
        res = chainForward(d, buf, at_eos);
        if (p.parse_gather != null) {
            p.parse = c.g_list_delete_link(p.parse, walk);
            c.gst_mini_object_unref(@ptrCast(buf));
        }
        walk = next;
    }
    walk = p.parse_gather;
    while (walk != null) : (walk = walk[0].next) {
        const frame: [*c]Frame = @ptrCast(@alignCast(walk[0].data));
        var w2 = frame[0].events;
        while (w2 != null) {
            const cur = w2;
            const event: [*c]Event = @ptrCast(@alignCast(w2[0].data));
            w2 = w2[0].next;
            if (event[0].type <= c.GST_EVENT_SEGMENT) {
                if (event[0].type == c.GST_EVENT_SEGMENT) {
                    var seg: c.GstSegment = undefined;
                    c.gst_event_copy_segment(event, &seg);
                    if (seg.format == c.GST_FORMAT_TIME) {
                        d[0].output_segment = seg;
                        p.in_out_segment_sync = c.gst_segment_is_equal(&d[0].input_segment, &seg) != 0;
                    }
                }
                p.pending_events = c.g_list_append(p.pending_events, event);
                frame[0].events = c.g_list_delete_link(frame[0].events, cur);
            }
        }
    }
    walk = p.parse_gather;
    while (walk != null) {
        const frame: [*c]Frame = @ptrCast(@alignCast(walk[0].data));
        p.parse_gather = c.g_list_remove_link(p.parse_gather, walk);
        p.decode = c.g_list_concat(walk, p.decode);
        if (frameHas(frame, SYNC_POINT)) {
            res = flushDecode(d);
            if (res != c.GST_FLOW_OK) return res;
            if (k.drain) |f| {
                res = f(d);
            } else if (k.finish) |f| res = f(d);
            if (res != c.GST_FLOW_OK) return res;
            var w = p.output_queued;
            while (w != null) {
                const buf: [*c]Buffer = @ptrCast(@alignCast(w[0].data));
                p.output_queued = c.g_list_delete_link(p.output_queued, p.output_queued);
                if (res == c.GST_FLOW_OK) {
                    buf[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DISCONT);
                    if (buf[0].pts != NONE) {
                        p.last_timestamp_out = buf[0].pts;
                    } else if (p.last_timestamp_out != NONE and buf[0].duration != NONE) {
                        buf[0].pts = p.last_timestamp_out -% buf[0].duration;
                        p.last_timestamp_out = buf[0].pts;
                    }
                    res = clipAndPush(d, buf);
                } else c.gst_mini_object_unref(@ptrCast(buf));
                w = p.output_queued;
            }
            _ = flush(d, false);
        }
        walk = p.parse_gather;
    }
    return res;
}

fn chainReverse(d: [*c]Dec, buf: [*c]Buffer) c.GstFlowReturn {
    const p = priv(d);
    var result: c.GstFlowReturn = c.GST_FLOW_OK;
    if (buf == null or bufHas(buf, c.GST_BUFFER_FLAG_DISCONT)) result = flushParse(d, false);
    if (buf != null) p.gather = c.g_list_prepend(p.gather, buf);
    return result;
}

fn chain(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, buf: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const d = of(parent_obj);
    const p = priv(d);
    if (p.input_state == null and p.needs_format) {
        post(d, c.GST_MESSAGE_ERROR, .core, c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("decoder not initialized"), "gst_video_decoder_chain", 2858);
        c.gst_mini_object_unref(@ptrCast(buf));
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    streamLock(d);
    if (d[0].input_segment.format == c.GST_FORMAT_UNDEFINED) {
        c.gst_segment_init(&d[0].input_segment, c.GST_FORMAT_TIME);
        const ev = c.gst_event_new_segment(&d[0].input_segment);
        p.current_frame_events = c.g_list_prepend(p.current_frame_events, ev);
    }
    p.had_input_data = true;
    const ret = if (d[0].input_segment.rate > 0.0) chainForward(d, buf, false) else chainReverse(d, buf);
    streamUnlock(d);
    return ret;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const d = of(e);
    const k = klass(d);
    const fname = "gst_video_decoder_change_state";
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            if (k.open) |f| {
                if (f(d) == 0) {
                    post(d, c.GST_MESSAGE_ERROR, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to open decoder"), fname, 2926);
                    return c.GST_STATE_CHANGE_FAILURE;
                }
            }
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            streamLock(d);
            reset(d, true, true);
            streamUnlock(d);
            if (k.start) |f| {
                if (f(d) == 0) {
                    post(d, c.GST_MESSAGE_ERROR, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to start decoder"), fname, 2933);
                    return c.GST_STATE_CHANGE_FAILURE;
                }
            }
        },
        else => {},
    }
    const ret = parent.?.change_state.?(e, t);
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            var stopped = true;
            if (k.stop) |f| stopped = f(d) != 0;
            streamLock(d);
            reset(d, true, true);
            streamUnlock(d);
            if (!stopped) {
                post(d, c.GST_MESSAGE_ERROR, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to stop decoder"), fname, 2940);
                return c.GST_STATE_CHANGE_FAILURE;
            }
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (k.close) |f| {
                if (f(d) == 0) {
                    post(d, c.GST_MESSAGE_ERROR, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to close decoder"), fname, 2947);
                    return c.GST_STATE_CHANGE_FAILURE;
                }
            }
        },
        else => {},
    }
    return ret;
}

fn newFrame(d: [*c]Dec) [*c]Frame {
    const p = priv(d);
    const f: [*c]Frame = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Frame))));
    f[0].ref_count = 1;
    streamLock(d);
    f[0].system_frame_number = p.system_frame_number;
    p.system_frame_number +%= 1;
    f[0].decode_frame_number = p.decode_frame_number;
    p.decode_frame_number +%= 1;
    f[0].dts = NONE;
    f[0].pts = NONE;
    f[0].duration = NONE;
    f[0].events = p.current_frame_events;
    p.current_frame_events = null;
    streamUnlock(d);
    return f;
}

fn pushEventList(d: [*c]Dec, events: [*c]c.GList) void {
    var l = c.g_list_last(events);
    while (l != null) : (l = l[0].prev) _ = pushEvent(d, @ptrCast(@alignCast(l[0].data)));
    c.g_list_free(events);
}

fn frameDuration(d: [*c]Dec) u64 {
    const s = priv(d).output_state;
    if (s == null or s[0].info.fps_d == 0 or s[0].info.fps_n == 0) return NONE;
    return c.gst_util_uint64_scale(SEC, @intCast(s[0].info.fps_d), @intCast(s[0].info.fps_n));
}

fn prepareFinish(d: [*c]Dec, frame: [*c]Frame, dropping: bool) void {
    const p = priv(d);
    var events: [*c]c.GList = null;
    const sync = frameHas(frame, SYNC_POINT);
    var l = p.frames.head;
    while (l != null) : (l = l[0].next) {
        const tmp: [*c]Frame = @ptrCast(@alignCast(l[0].data));
        if (tmp[0].events != null) {
            events = c.g_list_concat(tmp[0].events, events);
            tmp[0].events = null;
        }
        if (tmp == frame) break;
    }
    if (dropping or p.output_state == null) {
        p.pending_events = c.g_list_concat(events, p.pending_events);
    } else {
        pushEventList(d, p.pending_events);
        p.pending_events = null;
        pushEventList(d, events);
    }
    if (frameHas(frame, DECODE_ONLY)) return;
    if (frame[0].output_buffer == null and !dropping) return;
    if (p.reordered_output and valid(frame[0].pts)) {
        if (frame[0].pts > p.last_timestamp_out) {
            p.consecutive_orderered_output += 1;
            if (p.consecutive_orderered_output >= 30) {
                p.reordered_output = false;
                p.consecutive_orderered_output = 0;
            }
        } else p.consecutive_orderered_output = 0;
    }
    if (frame[0].duration == NONE) frame[0].duration = frameDuration(d);
    var no_pts = false;
    var no_dts = false;
    var min_dts: u64 = NONE;
    var min_pts: u64 = NONE;
    var e_dts: [*c]Frame = null;
    var e_pts: [*c]Frame = null;
    l = p.frames.head;
    while (l != null) : (l = l[0].next) {
        const tmp: [*c]Frame = @ptrCast(@alignCast(l[0].data));
        const ts = tmp[0].abidata.ABI.ts;
        const ts2 = tmp[0].abidata.ABI.ts2;
        if (!valid(ts)) {
            no_dts = true;
        } else if (!valid(min_dts) or ts < min_dts) {
            min_dts = ts;
            e_dts = tmp;
        }
        if (!valid(ts2)) {
            no_pts = true;
        } else if (!valid(min_pts) or ts2 < min_pts) {
            min_pts = ts2;
            e_pts = tmp;
        }
    }
    if (e_dts != null and e_dts != frame) e_dts[0].abidata.ABI.ts = frame[0].abidata.ABI.ts;
    if (e_pts != null and e_pts != frame) e_pts[0].abidata.ABI.ts2 = frame[0].abidata.ABI.ts2;
    if (!p.reordered_output and !valid(frame[0].pts) and !no_dts and valid(p.pts_delta)) frame[0].pts = min_dts +% p.pts_delta;
    if (p.reordered_output and !no_pts) frame[0].pts = NONE;
    if (!valid(frame[0].pts) and !no_pts) frame[0].pts = min_pts;
    if (frame[0].pts == NONE) {
        if (frame[0].duration != NONE) {
            if (valid(p.last_timestamp_out)) {
                frame[0].pts = p.last_timestamp_out +% frame[0].duration;
            } else if (frame[0].dts != NONE) {
                frame[0].pts = frame[0].dts;
            } else if (d[0].output_segment.rate > 0.0) frame[0].pts = d[0].output_segment.start;
        } else if (sync and frame[0].dts != NONE) frame[0].pts = frame[0].dts;
    }
    if (valid(p.last_timestamp_out) and frame[0].pts < p.last_timestamp_out) {
        p.reordered_output = true;
        frame[0].pts = p.last_timestamp_out;
    }
    if (valid(frame[0].pts)) p.last_timestamp_out = frame[0].pts;
}

pub export fn gst_video_decoder_release_frame(dec: [*c]Dec, frame: [*c]Frame) void {
    const p = priv(dec);
    streamLock(dec);
    const link = c.g_queue_find(&p.frames, frame);
    if (link != null) {
        codec.gst_video_codec_frame_unref(frame);
        c.g_queue_delete_link(&p.frames, link);
    }
    if (frame[0].events != null) {
        p.pending_events = c.g_list_concat(frame[0].events, p.pending_events);
        frame[0].events = null;
    }
    streamUnlock(dec);
    codec.gst_video_codec_frame_unref(frame);
}

fn qosDrop(d: [*c]Dec, timestamp: u64) void {
    const p = priv(d);
    p.dropped += 1;
    el.lock(d);
    const proportion = p.proportion;
    const earliest = p.earliest_time;
    el.unlock(d);
    var seg = &d[0].output_segment;
    if (seg.format == c.GST_FORMAT_UNDEFINED) seg = &d[0].input_segment;
    const stream_time = c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, timestamp);
    const qostime = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, timestamp);
    const jitter: i64 = @as(i64, @bitCast(earliest)) -% @as(i64, @bitCast(qostime));
    const msg = c.gst_message_new_qos(@ptrCast(d), 0, qostime, stream_time, timestamp, NONE);
    c.gst_message_set_qos_values(msg, jitter, proportion, 1000000);
    c.gst_message_set_qos_stats(msg, c.GST_FORMAT_BUFFERS, p.processed, p.dropped);
    _ = c.gst_element_post_message(@ptrCast(d), msg);
}

pub export fn gst_video_decoder_drop_frame(dec: [*c]Dec, frame: [*c]Frame) c.GstFlowReturn {
    streamLock(dec);
    prepareFinish(dec, frame, true);
    qosDrop(dec, frame[0].pts);
    gst_video_decoder_release_frame(dec, frame);
    priv(dec).had_output_data = true;
    streamUnlock(dec);
    return c.GST_FLOW_OK;
}

pub export fn gst_video_decoder_drop_subframe(dec: [*c]Dec, frame: [*c]Frame) c.GstFlowReturn {
    if (!check.that(gst_video_decoder_get_subframe_mode(dec) != 0, "gst_video_decoder_drop_subframe", "gst_video_decoder_get_subframe_mode (dec)")) return c.GST_FLOW_NOT_SUPPORTED;
    streamLock(dec);
    codec.gst_video_codec_frame_unref(frame);
    streamUnlock(dec);
    return c.GST_FLOW_OK;
}

var supported_tags = [_][*c]const u8{ "video", "orientation", "size", null };

fn transformMetaDefault(_: [*c]Dec, _: [*c]Frame, m: [*c]c.GstMeta) callconv(.c) c.gboolean {
    var tags = c.gst_meta_api_type_get_tags(m[0].info[0].api);
    if (tags == null) return 1;
    while (tags[0] != null) : (tags += 1) {
        if (c.g_strv_contains(@ptrCast(&supported_tags), tags[0]) == 0) return 0;
    }
    return 1;
}

const CopyData = struct { d: [*c]Dec, frame: [*c]Frame, buffer: [*c]Buffer };

fn eachMeta(inbuf: [*c]Buffer, m: [*c][*c]c.GstMeta, user: c.gpointer) callconv(.c) c.gboolean {
    const data: *CopyData = @ptrCast(@alignCast(user));
    const mi = m[0][0].info;
    const k = klass(data.d);
    var copy = false;
    if (c.gst_meta_api_type_has_tag(mi[0].api, c._gst_meta_tag_memory) != 0 or c.gst_meta_api_type_has_tag(mi[0].api, c._gst_meta_tag_memory_reference) != 0) {
        copy = false;
    } else if (k.transform_meta) |f| copy = f(data.d, data.frame, m[0]) != 0;
    if (copy) {
        if (mi[0].transform_func) |tf| {
            var cd = c.GstMetaTransformCopy{ .region = 0, .offset = 0, .size = std.math.maxInt(c.gsize) };
            _ = tf(data.buffer, m[0], inbuf, c._gst_meta_transform_copy, &cd);
        }
    }
    return 1;
}

fn copyMetas(d: [*c]Dec, frame: [*c]Frame, src: [*c]Buffer, dest: [*c]Buffer) void {
    if (klass(d).transform_meta == null) return;
    if (frame == null) return;
    var data = CopyData{ .d = d, .frame = frame, .buffer = dest };
    _ = c.gst_buffer_foreach_meta(src, eachMeta, &data);
}

fn replaceInputBuffer(d: [*c]Dec, frame: [*c]Frame, dest: *[*c]Buffer) void {
    if (frame[0].input_buffer != null) {
        dest.* = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(dest.*)));
        copyMetas(d, frame, frame[0].input_buffer, dest.*);
        c.gst_mini_object_unref(@ptrCast(frame[0].input_buffer));
    }
    frame[0].input_buffer = dest.*;
}

fn isFlushing(pad: ?*c.GstPad) bool {
    return el.flags(pad) & c.GST_PAD_FLAG_FLUSHING != 0;
}

pub export fn gst_video_decoder_finish_frame(decoder: [*c]Dec, frame_in: [*c]Frame) c.GstFlowReturn {
    const d = decoder;
    const p = priv(d);
    var frame = frame_in;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    streamLock(d);
    defer streamUnlock(d);
    const reconf = c.gst_pad_check_reconfigure(d[0].srcpad) != 0;
    if (p.output_state_changed or (p.output_state != null and reconf)) {
        if (!negotiateUnlocked(d)) {
            c.gst_pad_mark_reconfigure(d[0].srcpad);
            ret = if (isFlushing(d[0].srcpad)) c.GST_FLOW_FLUSHING else c.GST_FLOW_NOT_NEGOTIATED;
            gst_video_decoder_release_frame(d, frame);
            return ret;
        }
    }
    prepareFinish(d, frame, false);
    p.processed += 1;
    if (p.tags_changed) {
        const te = mergedTags(d);
        if (te != null) _ = pushEvent(d, te);
        p.tags_changed = false;
    }
    blk: {
        if (frame[0].output_buffer == null or frameHas(frame, DECODE_ONLY)) break :blk;
        el.lock(d);
        if (frame[0].system_frame_number <= p.request_sync_point_frame_number and p.request_sync_point_frame_number != UNSET) {
            if (p.request_sync_point_flags & c.GST_VIDEO_DECODER_REQUEST_SYNC_POINT_CORRUPT_OUTPUT != 0) frame[0].flags |= CORRUPTED;
        } else p.request_sync_point_frame_number = UNSET;
        el.unlock(d);
        if (p.discard_corrupted_frames and (frameHas(frame, CORRUPTED) or bufHas(frame[0].output_buffer, c.GST_BUFFER_FLAG_CORRUPTED))) break :blk;
        const out: [*c]Buffer = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(frame[0].output_buffer)));
        frame[0].output_buffer = out;
        out[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DELTA_UNIT);
        out[0].pts = frame[0].pts;
        out[0].dts = NONE;
        out[0].duration = frame[0].duration;
        out[0].offset = NONE;
        out[0].offset_end = NONE;
        if (p.discont) out[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        if (frameHas(frame, CORRUPTED)) out[0].mini_object.flags |= c.GST_BUFFER_FLAG_CORRUPTED;
        copyMetas(d, frame, frame[0].input_buffer, frame[0].output_buffer);
        const ob: [*c]Buffer = @ptrCast(c.gst_mini_object_ref(@ptrCast(out)));
        gst_video_decoder_release_frame(d, frame);
        frame = null;
        if (d[0].output_segment.rate < 0.0 and d[0].output_segment.flags & c.GST_SEEK_FLAG_TRICKMODE_KEY_UNITS == 0) {
            p.output_queued = c.g_list_prepend(p.output_queued, ob);
        } else ret = clipAndPush(d, ob);
    }
    if (frame != null) gst_video_decoder_release_frame(d, frame);
    return ret;
}

pub export fn gst_video_decoder_finish_subframe(decoder: [*c]Dec, frame: [*c]Frame) c.GstFlowReturn {
    if (!check.that(gst_video_decoder_get_subframe_mode(decoder) != 0, "gst_video_decoder_finish_subframe", "gst_video_decoder_get_subframe_mode (decoder)")) return c.GST_FLOW_NOT_SUPPORTED;
    streamLock(decoder);
    frame[0].abidata.ABI.subframes_processed += 1;
    codec.gst_video_codec_frame_unref(frame);
    streamUnlock(decoder);
    return c.GST_FLOW_OK;
}

fn clipAndPush(d: [*c]Dec, buf: [*c]Buffer) c.GstFlowReturn {
    const p = priv(d);
    const start = buf[0].pts;
    const duration = buf[0].duration;
    p.had_output_data = true;
    var stop: u64 = NONE;
    if (valid(start) and valid(duration)) {
        stop = start +% duration;
    } else if (valid(start)) stop = start +% 40 * MSEC;
    const seg = &d[0].output_segment;
    var cstart: u64 = 0;
    var cstop: u64 = 0;
    if (c.gst_segment_clip(seg, c.GST_FORMAT_TIME, start, stop, &cstart, &cstop) != 0) {
        buf[0].pts = cstart;
        if (stop != NONE and valid(duration)) buf[0].duration = cstop -% cstart;
    } else {
        var ret: c.GstFlowReturn = c.GST_FLOW_OK;
        if (p.in_out_segment_sync) {
            if (seg.rate >= 0) {
                if (buf[0].pts >= seg.stop) ret = c.GST_FLOW_EOS;
            } else if (buf[0].pts < seg.start) ret = c.GST_FLOW_EOS;
        }
        c.gst_mini_object_unref(@ptrCast(buf));
        return ret;
    }
    if (p.do_qos and valid(p.earliest_time)) {
        var deadline: u64 = NONE;
        if (valid(cstop)) {
            deadline = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, cstop);
        } else if (valid(cstart)) deadline = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, cstart);
        if (valid(deadline) and deadline < p.earliest_time) {
            qosDrop(d, cstart);
            c.gst_mini_object_unref(@ptrCast(buf));
            p.discont = true;
            return c.GST_FLOW_OK;
        }
    }
    if (p.discont) {
        buf[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        p.discont = false;
    }
    el.lock(d);
    p.bytes_out +%= @intCast(c.gst_buffer_get_size(buf));
    if (valid(duration)) p.time +%= @bitCast(duration) else p.time = -1;
    el.unlock(d);
    if (p.error_count != 0) p.error_count = 0;
    streamUnlock(d);
    const ret = c.gst_pad_push(d[0].srcpad, buf);
    streamLock(d);
    return ret;
}

pub export fn gst_video_decoder_add_to_frame(decoder: [*c]Dec, n_bytes: c_int) void {
    const p = priv(decoder);
    if (n_bytes == 0) return;
    streamLock(decoder);
    if (c.gst_adapter_available(p.output_adapter) == 0) p.frame_offset = p.input_offset -% c.gst_adapter_available(p.input_adapter);
    const buf = c.gst_adapter_take_buffer(p.input_adapter, @intCast(n_bytes));
    c.gst_adapter_push(p.output_adapter, buf);
    streamUnlock(decoder);
}

pub export fn gst_video_decoder_get_pending_frame_size(decoder: [*c]Dec) c.gsize {
    streamLock(decoder);
    defer streamUnlock(decoder);
    return c.gst_adapter_available(priv(decoder).output_adapter);
}

pub export fn gst_video_decoder_have_frame(decoder: [*c]Dec) c.GstFlowReturn {
    const d = decoder;
    const p = priv(d);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    streamLock(d);
    const n = c.gst_adapter_available(p.output_adapter);
    var buffer: [*c]Buffer = if (n != 0) c.gst_adapter_take_buffer(p.output_adapter, n) else c.gst_buffer_new_allocate(null, 0, null);
    replaceInputBuffer(d, p.current_frame, &buffer);
    var pts: u64 = 0;
    var dts: u64 = 0;
    var dur: u64 = 0;
    var flags: c.guint = 0;
    infoAtOffset(d, p.frame_offset, &pts, &dts, &dur, &flags);
    buffer[0].pts = pts;
    buffer[0].dts = dts;
    buffer[0].duration = dur;
    buffer[0].mini_object.flags = flags;
    if (!bufHas(buffer, c.GST_BUFFER_FLAG_DELTA_UNIT)) p.current_frame[0].flags |= SYNC_POINT;
    if (bufHas(buffer, c.GST_BUFFER_FLAG_CORRUPTED)) p.current_frame[0].flags |= CORRUPTED;
    if (d[0].input_segment.rate < 0.0) {
        p.parse_gather = c.g_list_prepend(p.parse_gather, p.current_frame);
        p.current_frame = null;
    } else {
        const frame = p.current_frame;
        if (subframe(d)) {
            frame[0].abidata.ABI.num_subframes += 1;
            _ = codec.gst_video_codec_frame_ref(p.current_frame);
        } else p.current_frame = null;
        ret = decodeFrame(d, frame);
    }
    streamUnlock(d);
    return ret;
}

fn decodeFrame(d: [*c]Dec, frame: [*c]Frame) c.GstFlowReturn {
    const p = priv(d);
    const k = klass(d);
    const fname = "gst_video_decoder_decode_frame";
    if (!check.that(k.handle_frame != null, fname, "decoder_class->handle_frame != NULL")) return c.GST_FLOW_ERROR;
    if (!check.that(frame != null, fname, "frame != NULL")) return c.GST_FLOW_ERROR;
    frame[0].pts = frame[0].input_buffer[0].pts;
    frame[0].dts = frame[0].input_buffer[0].dts;
    frame[0].duration = frame[0].input_buffer[0].duration;
    frame[0].deadline = c.gst_segment_to_running_time(&d[0].input_segment, c.GST_FORMAT_TIME, frame[0].pts);
    if (frameHas(frame, SYNC_POINT)) {
        p.distance_from_sync = 0;
        el.lock(d);
        p.request_sync_point_flags &= ~@as(c.GstVideoDecoderRequestSyncPointFlags, c.GST_VIDEO_DECODER_REQUEST_SYNC_POINT_DISCARD_INPUT);
        if (p.request_sync_point_frame_number == PENDING) p.request_sync_point_frame_number = frame[0].system_frame_number;
        el.unlock(d);
        if (valid(frame[0].pts) and valid(frame[0].dts)) p.pts_delta = frame[0].pts -% frame[0].dts;
    } else {
        if (p.distance_from_sync == UNSET and p.automatic_request_sync_points) gst_video_decoder_request_sync_point(d, frame, p.automatic_request_sync_point_flags);
        el.lock(d);
        if ((p.needs_sync_point and p.distance_from_sync == UNSET) or p.request_sync_point_flags & c.GST_VIDEO_DECODER_REQUEST_SYNC_POINT_DISCARD_INPUT != 0) {
            el.unlock(d);
            if (p.automatic_request_sync_points) gst_video_decoder_request_sync_point(d, frame, p.automatic_request_sync_point_flags);
            gst_video_decoder_release_frame(d, frame);
            return c.GST_FLOW_OK;
        }
        el.unlock(d);
        p.distance_from_sync +%= 1;
    }
    frame[0].distance_from_sync = @truncate(@as(i64, @bitCast(p.distance_from_sync)));
    if (!subframe(d) or frame[0].abidata.ABI.num_subframes == 1) {
        frame[0].abidata.ABI.ts = frame[0].dts;
        frame[0].abidata.ABI.ts2 = frame[0].pts;
    }
    if (c.g_queue_find(&p.frames, frame) == null) c.g_queue_push_tail(&p.frames, codec.gst_video_codec_frame_ref(frame));
    return k.handle_frame.?(d, frame);
}

pub export fn gst_video_decoder_get_output_state(decoder: [*c]Dec) [*c]State {
    el.lock(decoder);
    defer el.unlock(decoder);
    const s = priv(decoder).output_state;
    return if (s != null) codec.gst_video_codec_state_ref(s) else null;
}

fn setInterlacedOutputState(d: [*c]Dec, fmt: c.GstVideoFormat, mode: c.GstVideoInterlaceMode, width: c.guint, height: c.guint, reference: [*c]State, copy_mode: bool) [*c]State {
    const p = priv(d);
    const state = newOutputState(fmt, mode, width, height, reference, copy_mode);
    if (state == null) return null;
    streamLock(d);
    el.lock(d);
    if (p.output_state != null) codec.gst_video_codec_state_unref(p.output_state);
    p.output_state = codec.gst_video_codec_state_ref(state);
    if (p.output_state != null and p.output_state[0].info.fps_n > 0) {
        p.qos_frame_duration = c.gst_util_uint64_scale(SEC, @intCast(p.output_state[0].info.fps_d), @intCast(p.output_state[0].info.fps_n));
    } else p.qos_frame_duration = 0;
    p.output_state_changed = true;
    el.unlock(d);
    streamUnlock(d);
    return state;
}

pub export fn gst_video_decoder_set_output_state(decoder: [*c]Dec, fmt: c.GstVideoFormat, width: c.guint, height: c.guint, reference: [*c]State) [*c]State {
    return setInterlacedOutputState(decoder, fmt, c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE, width, height, reference, true);
}

pub export fn gst_video_decoder_set_interlaced_output_state(decoder: [*c]Dec, fmt: c.GstVideoFormat, mode: c.GstVideoInterlaceMode, width: c.guint, height: c.guint, reference: [*c]State) [*c]State {
    return setInterlacedOutputState(decoder, fmt, mode, width, height, reference, false);
}

pub export fn gst_video_decoder_get_oldest_frame(decoder: [*c]Dec) [*c]Frame {
    streamLock(decoder);
    defer streamUnlock(decoder);
    const h = priv(decoder).frames.head;
    return if (h != null) codec.gst_video_codec_frame_ref(@ptrCast(@alignCast(h[0].data))) else null;
}

pub export fn gst_video_decoder_get_frame(decoder: [*c]Dec, frame_number: c_int) [*c]Frame {
    streamLock(decoder);
    defer streamUnlock(decoder);
    var g = priv(decoder).frames.head;
    while (g != null) : (g = g[0].next) {
        const tmp: [*c]Frame = @ptrCast(@alignCast(g[0].data));
        if (tmp[0].system_frame_number == @as(u32, @bitCast(frame_number))) return codec.gst_video_codec_frame_ref(tmp);
    }
    return null;
}

pub export fn gst_video_decoder_get_frames(decoder: [*c]Dec) [*c]c.GList {
    streamLock(decoder);
    defer streamUnlock(decoder);
    return c.g_list_copy_deep(priv(decoder).frames.head, refFrame, null);
}

fn decideAllocationDefault(d: [*c]Dec, query: [*c]Query) callconv(.c) c.gboolean {
    var outcaps: [*c]c.GstCaps = null;
    var p: [*c]c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    var update_alloc = false;
    var update_pool = false;
    var vi: c.GstVideoInfo = undefined;
    c.gst_query_parse_allocation(query, &outcaps, null);
    info.gst_video_info_init(&vi);
    if (outcaps != null) _ = info.gst_video_info_from_caps(&vi, outcaps);
    if (c.gst_query_get_n_allocation_params(query) > 0) {
        c.gst_query_parse_nth_allocation_param(query, 0, &allocator, &params);
        update_alloc = true;
    } else c.gst_allocation_params_init(&params);
    if (c.gst_query_get_n_allocation_pools(query) > 0) {
        c.gst_query_parse_nth_allocation_pool(query, 0, &p, &size, &min, &max);
        size = @max(size, @as(c.guint, @truncate(vi.size)));
        update_pool = true;
    } else size = @truncate(vi.size);
    const name_obj: *c.GstObject = @ptrCast(@alignCast(d));
    if (p == null) {
        p = pool.gst_video_buffer_pool_new();
        const name = c.g_strdup_printf("%s-pool", name_obj.name);
        c.g_object_set(p, "name", name, VNONE);
        c.g_free(name);
    }
    var config = c.gst_buffer_pool_get_config(p);
    c.gst_buffer_pool_config_set_params(config, outcaps, size, min, max);
    c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
    if (c.gst_buffer_pool_set_config(p, config) == 0) {
        config = c.gst_buffer_pool_get_config(p);
        if (c.gst_buffer_pool_config_validate_params(config, outcaps, size, min, max) == 0) {
            c.gst_structure_free(config);
            c.gst_object_unref(p);
            p = null;
        } else if (c.gst_buffer_pool_set_config(p, config) == 0) {
            c.gst_object_unref(p);
            p = null;
        }
        if (p == null) {
            const name = c.g_strdup_printf("%s-fallback-pool", name_obj.name);
            p = pool.gst_video_buffer_pool_new();
            c.g_object_set(p, "name", name, VNONE);
            c.g_free(name);
            config = c.gst_buffer_pool_get_config(p);
            c.gst_buffer_pool_config_set_params(config, outcaps, size, min, max);
            c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
            if (c.gst_buffer_pool_set_config(p, config) == 0) {
                if (allocator != null) c.gst_object_unref(allocator);
                c.gst_object_unref(p);
                el.messageAt(d, c.GST_MESSAGE_ERROR, .resource, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup("Failed to configure the buffer pool"), c.g_strdup("Configuration is most likely invalid, please report this issue."), PATH, "gst_video_decoder_decide_allocation_default", 4373, null);
                return 0;
            }
        }
    }
    if (update_alloc) c.gst_query_set_nth_allocation_param(query, 0, allocator, &params) else c.gst_query_add_allocation_param(query, allocator, &params);
    if (allocator != null) c.gst_object_unref(allocator);
    if (update_pool) c.gst_query_set_nth_allocation_pool(query, 0, p, size, min, max) else c.gst_query_add_allocation_pool(query, p, size, min, max);
    if (p != null) c.gst_object_unref(p);
    return 1;
}

fn proposeAllocationDefault(_: [*c]Dec, _: [*c]Query) callconv(.c) c.gboolean {
    return 1;
}

fn negotiatePool(d: [*c]Dec, caps: [*c]c.GstCaps) bool {
    const k = klass(d);
    const p = priv(d);
    const query = c.gst_query_new_allocation(caps, 1);
    defer c.gst_mini_object_unref(@ptrCast(query));
    _ = c.gst_pad_peer_query(d[0].srcpad, query);
    if (k.decide_allocation.?(d, query) == 0) return false;
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    var bp: [*c]c.GstBufferPool = null;
    if (c.gst_query_get_n_allocation_params(query) > 0) {
        c.gst_query_parse_nth_allocation_param(query, 0, &allocator, &params);
    } else c.gst_allocation_params_init(&params);
    if (c.gst_query_get_n_allocation_pools(query) > 0) c.gst_query_parse_nth_allocation_pool(query, 0, &bp, null, null, null);
    if (bp == null) {
        if (allocator != null) c.gst_object_unref(allocator);
        return false;
    }
    if (p.allocator != null) c.gst_object_unref(p.allocator);
    p.allocator = allocator;
    p.params = params;
    if (p.pool != null) c.gst_object_unref(p.pool);
    p.pool = bp;
    _ = c.gst_buffer_pool_set_active(bp, 1);
    return true;
}

fn negotiateDefault(d: [*c]Dec) callconv(.c) c.gboolean {
    const p = priv(d);
    const state = p.output_state;
    if (state == null) return @intFromBool(negotiatePool(d, null));
    const fname = "gst_video_decoder_negotiate_default";
    if (!check.that(state[0].info.width != 0, fname, "GST_VIDEO_INFO_WIDTH (&state->info) != 0")) return 0;
    if (!check.that(state[0].info.height != 0, fname, "GST_VIDEO_INFO_HEIGHT (&state->info) != 0")) return 0;
    if (state[0].info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_NONE) {
        state[0].info.ABI.abi.multiview_mode = c.GST_VIDEO_MULTIVIEW_MODE_MONO;
        state[0].info.ABI.abi.multiview_flags = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE;
    }
    if (state[0].caps == null) state[0].caps = info.gst_video_info_to_caps(&state[0].info);
    const incaps = c.gst_pad_get_current_caps(d[0].sinkpad);
    if (incaps != null) {
        const ins = c.gst_caps_get_structure(incaps, 0);
        if (c.gst_structure_has_field(ins, "mastering-display-info") != 0 or c.gst_structure_has_field(ins, "content-light-level") != 0) {
            state[0].caps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(state[0].caps)));
            var s = c.gst_structure_get_string(ins, "mastering-display-info");
            if (s != null) c.gst_caps_set_simple(state[0].caps, "mastering-display-info", c.G_TYPE_STRING, s, VNONE);
            s = c.gst_structure_get_string(ins, "content-light-level");
            if (s != null) c.gst_caps_set_simple(state[0].caps, "content-light-level", c.G_TYPE_STRING, s, VNONE);
        }
        c.gst_caps_unref(incaps);
    }
    if (state[0].allocation_caps == null) state[0].allocation_caps = c.gst_caps_ref(state[0].caps);
    const frame: [*c]Frame = if (p.frames.head != null) @ptrCast(@alignCast(p.frames.head[0].data)) else null;
    if (frame != null or p.current_frame_events != null) {
        const events: *[*c]c.GList = if (frame != null) @ptrCast(&frame[0].events) else &p.current_frame_events;
        var l = c.g_list_last(events.*);
        while (l != null) {
            const ev: [*c]Event = @ptrCast(@alignCast(l[0].data));
            if (ev[0].type < c.GST_EVENT_CAPS) {
                _ = pushEvent(d, ev);
                const tmp = l;
                l = l[0].prev;
                events.* = c.g_list_delete_link(events.*, tmp);
            } else l = l[0].prev;
        }
    }
    const prev = c.gst_pad_get_current_caps(d[0].srcpad);
    var ret = true;
    if (prev == null or c.gst_caps_is_equal(prev, state[0].caps) == 0) ret = vutils.padSetCaps(d[0].srcpad, state[0].caps);
    if (prev != null) c.gst_caps_unref(prev);
    if (!ret) return 0;
    p.output_state_changed = false;
    return @intFromBool(negotiatePool(d, state[0].allocation_caps));
}

fn negotiateUnlocked(d: [*c]Dec) bool {
    if (klass(d).negotiate) |f| return f(d) != 0;
    return true;
}

pub export fn gst_video_decoder_negotiate(decoder: [*c]Dec) c.gboolean {
    if (!check.that(isDec(decoder), "gst_video_decoder_negotiate", "GST_IS_VIDEO_DECODER (decoder)")) return 0;
    var ret = true;
    streamLock(decoder);
    _ = c.gst_pad_check_reconfigure(decoder[0].srcpad);
    if (klass(decoder).negotiate) |f| {
        ret = f(decoder) != 0;
        if (!ret) c.gst_pad_mark_reconfigure(decoder[0].srcpad);
    }
    streamUnlock(decoder);
    return @intFromBool(ret);
}

pub export fn gst_video_decoder_allocate_output_buffer(decoder: [*c]Dec) [*c]Buffer {
    const d = decoder;
    const p = priv(d);
    var buffer: [*c]Buffer = null;
    streamLock(d);
    defer streamUnlock(d);
    const reconf = c.gst_pad_check_reconfigure(d[0].srcpad) != 0;
    var fallback = false;
    if (p.output_state == null or p.output_state_changed or reconf) {
        if (!negotiateUnlocked(d)) {
            if (p.output_state != null) {
                c.gst_pad_mark_reconfigure(d[0].srcpad);
                fallback = true;
            } else return buffer;
        }
    }
    if (!fallback) {
        if (p.pool == null) {
            fallback = true;
        } else {
            const flow = c.gst_buffer_pool_acquire_buffer(p.pool, &buffer, null);
            if (flow == c.GST_FLOW_OK) return buffer;
            if (p.output_state != null and p.output_state[0].info.size != 0) fallback = true else return buffer;
        }
    }
    return c.gst_buffer_new_allocate(null, p.output_state[0].info.size, null);
}

pub export fn gst_video_decoder_allocate_output_frame(decoder: [*c]Dec, frame: [*c]Frame) c.GstFlowReturn {
    return gst_video_decoder_allocate_output_frame_with_params(decoder, frame, null);
}

pub export fn gst_video_decoder_allocate_output_frame_with_params(decoder: [*c]Dec, frame: [*c]Frame, params: [*c]c.GstBufferPoolAcquireParams) c.GstFlowReturn {
    const d = decoder;
    const p = priv(d);
    const fname = "gst_video_decoder_allocate_output_frame_with_params";
    if (!check.that(p.output_state != null, fname, "decoder->priv->output_state")) return c.GST_FLOW_NOT_NEGOTIATED;
    if (!check.that(frame[0].output_buffer == null, fname, "frame->output_buffer == NULL")) return c.GST_FLOW_ERROR;
    streamLock(d);
    defer streamUnlock(d);
    const state = p.output_state;
    if (state == null) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Output state should be set before allocating frame");
        return c.GST_FLOW_ERROR;
    }
    if (state[0].info.size == 0) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Frame size should not be 0");
        return c.GST_FLOW_ERROR;
    }
    const reconf = c.gst_pad_check_reconfigure(d[0].srcpad) != 0;
    if (p.output_state_changed or reconf) {
        if (!negotiateUnlocked(d)) {
            c.gst_pad_mark_reconfigure(d[0].srcpad);
            if (isFlushing(d[0].srcpad)) return c.GST_FLOW_FLUSHING;
            if (p.pool == null or p.output_state_changed) return c.GST_FLOW_ERROR;
        }
    }
    return c.gst_buffer_pool_acquire_buffer(p.pool, &frame[0].output_buffer, params);
}

pub export fn gst_video_decoder_get_max_decode_time(decoder: [*c]Dec, frame: [*c]Frame) c.GstClockTimeDiff {
    el.lock(decoder);
    defer el.unlock(decoder);
    const earliest = priv(decoder).earliest_time;
    if (valid(earliest) and valid(frame[0].deadline)) return @as(i64, @bitCast(frame[0].deadline)) -% @as(i64, @bitCast(earliest));
    return std.math.maxInt(i64);
}

pub export fn gst_video_decoder_get_qos_proportion(decoder: [*c]Dec) f64 {
    if (!check.that(isDec(decoder), "gst_video_decoder_get_qos_proportion", "GST_IS_VIDEO_DECODER (decoder)")) return 1.0;
    el.lock(decoder);
    defer el.unlock(decoder);
    return priv(decoder).proportion;
}

pub export fn _gst_video_decoder_error(dec: [*c]Dec, weight: c.gint, domain: c.GQuark, code: c.gint, txt: [*c]u8, dbg: [*c]u8, file: [*c]const u8, function: [*c]const u8, line: c.gint) c.GstFlowReturn {
    const p = priv(dec);
    p.error_count += weight;
    p.discont = true;
    if (p.max_errors >= 0 and p.error_count > p.max_errors) {
        c.gst_element_message_full(@ptrCast(dec), c.GST_MESSAGE_ERROR, domain, code, txt, dbg, file, function, line);
        return c.GST_FLOW_ERROR;
    }
    c.g_free(txt);
    c.g_free(dbg);
    return c.GST_FLOW_OK;
}

pub export fn gst_video_decoder_set_max_errors(dec: [*c]Dec, num: c.gint) void {
    if (!check.that(isDec(dec), "gst_video_decoder_set_max_errors", "GST_IS_VIDEO_DECODER (dec)")) return;
    priv(dec).max_errors = num;
}

pub export fn gst_video_decoder_get_max_errors(dec: [*c]Dec) c.gint {
    if (!check.that(isDec(dec), "gst_video_decoder_get_max_errors", "GST_IS_VIDEO_DECODER (dec)")) return 0;
    return priv(dec).max_errors;
}

pub export fn gst_video_decoder_set_needs_format(dec: [*c]Dec, enabled: c.gboolean) void {
    if (!check.that(isDec(dec), "gst_video_decoder_set_needs_format", "GST_IS_VIDEO_DECODER (dec)")) return;
    priv(dec).needs_format = enabled != 0;
}

pub export fn gst_video_decoder_get_needs_format(dec: [*c]Dec) c.gboolean {
    if (!check.that(isDec(dec), "gst_video_decoder_get_needs_format", "GST_IS_VIDEO_DECODER (dec)")) return 0;
    return @intFromBool(priv(dec).needs_format);
}

pub export fn gst_video_decoder_set_packetized(decoder: [*c]Dec, packetized: c.gboolean) void {
    priv(decoder).packetized = packetized != 0;
}

pub export fn gst_video_decoder_get_packetized(decoder: [*c]Dec) c.gboolean {
    return @intFromBool(priv(decoder).packetized);
}

pub export fn gst_video_decoder_have_last_subframe(decoder: [*c]Dec, frame: [*c]Frame) c.GstFlowReturn {
    if (!check.that(gst_video_decoder_get_subframe_mode(decoder) != 0, "gst_video_decoder_have_last_subframe", "gst_video_decoder_get_subframe_mode (decoder)")) return c.GST_FLOW_OK;
    streamLock(decoder);
    const p = priv(decoder);
    if (p.current_frame == frame) {
        codec.gst_video_codec_frame_unref(p.current_frame);
        p.current_frame = null;
    }
    streamUnlock(decoder);
    return c.GST_FLOW_OK;
}

pub export fn gst_video_decoder_set_subframe_mode(decoder: [*c]Dec, subframe_mode: c.gboolean) void {
    priv(decoder).subframe_mode = subframe_mode != 0;
}

pub export fn gst_video_decoder_get_subframe_mode(decoder: [*c]Dec) c.gboolean {
    return @intFromBool(priv(decoder).subframe_mode);
}

pub export fn gst_video_decoder_get_input_subframe_index(decoder: [*c]Dec, frame: [*c]Frame) c.guint {
    if (subframe(decoder)) return frame[0].abidata.ABI.num_subframes;
    return 1;
}

pub export fn gst_video_decoder_get_processed_subframe_index(_: [*c]Dec, frame: [*c]Frame) c.guint {
    return frame[0].abidata.ABI.subframes_processed;
}

pub export fn gst_video_decoder_set_estimate_rate(dec: [*c]Dec, enabled: c.gboolean) void {
    if (!check.that(isDec(dec), "gst_video_decoder_set_estimate_rate", "GST_IS_VIDEO_DECODER (dec)")) return;
    priv(dec).do_estimate_rate = enabled != 0;
}

pub export fn gst_video_decoder_get_estimate_rate(dec: [*c]Dec) c.gboolean {
    if (!check.that(isDec(dec), "gst_video_decoder_get_estimate_rate", "GST_IS_VIDEO_DECODER (dec)")) return 0;
    return @intFromBool(priv(dec).do_estimate_rate);
}

pub export fn gst_video_decoder_set_latency(decoder: [*c]Dec, min_latency: c.GstClockTime, max_latency: c.GstClockTime) void {
    const fname = "gst_video_decoder_set_latency";
    if (!check.that(valid(min_latency), fname, "GST_CLOCK_TIME_IS_VALID (min_latency)")) return;
    if (!check.that(max_latency >= min_latency, fname, "max_latency >= min_latency")) return;
    const p = priv(decoder);
    var post_msg = false;
    el.lock(decoder);
    if (p.min_latency != @as(i64, @bitCast(min_latency))) {
        p.min_latency = @bitCast(min_latency);
        post_msg = true;
    }
    if (p.max_latency != @as(i64, @bitCast(max_latency))) {
        p.max_latency = @bitCast(max_latency);
        post_msg = true;
    }
    if (!p.posted_latency_msg) {
        p.posted_latency_msg = true;
        post_msg = true;
    }
    el.unlock(decoder);
    if (post_msg) _ = c.gst_element_post_message(@ptrCast(decoder), c.gst_message_new_latency(@ptrCast(decoder)));
}

pub export fn gst_video_decoder_get_latency(decoder: [*c]Dec, min_latency: [*c]c.GstClockTime, max_latency: [*c]c.GstClockTime) void {
    el.lock(decoder);
    defer el.unlock(decoder);
    if (min_latency != null) min_latency[0] = @bitCast(priv(decoder).min_latency);
    if (max_latency != null) max_latency[0] = @bitCast(priv(decoder).max_latency);
}

pub export fn gst_video_decoder_merge_tags(decoder: [*c]Dec, tags: ?*const c.GstTagList, mode: c.GstTagMergeMode) void {
    const fname = "gst_video_decoder_merge_tags";
    if (!check.that(isDec(decoder), fname, "GST_IS_VIDEO_DECODER (decoder)")) return;
    const is_tags = tags != null and @as(*const c.GstMiniObject, @ptrCast(@alignCast(tags))).type == c.gst_tag_list_get_type();
    if (!check.that(tags == null or is_tags, fname, "tags == NULL || GST_IS_TAG_LIST (tags)")) return;
    if (!check.that(tags == null or mode != c.GST_TAG_MERGE_UNDEFINED, fname, "tags == NULL || mode != GST_TAG_MERGE_UNDEFINED")) return;
    const p = priv(decoder);
    streamLock(decoder);
    if (p.tags != tags) {
        if (p.tags) |t| {
            c.gst_mini_object_unref(@ptrCast(t));
            p.tags = null;
            p.tags_merge_mode = c.GST_TAG_MERGE_APPEND;
        }
        if (tags != null) {
            p.tags = @ptrCast(c.gst_mini_object_ref(@ptrCast(@constCast(tags))));
            p.tags_merge_mode = mode;
        }
        p.tags_changed = true;
    }
    streamUnlock(decoder);
}

pub export fn gst_video_decoder_get_buffer_pool(decoder: [*c]Dec) [*c]c.GstBufferPool {
    if (!check.that(isDec(decoder), "gst_video_decoder_get_buffer_pool", "GST_IS_VIDEO_DECODER (decoder)")) return null;
    const p = priv(decoder).pool;
    if (p != null) return @ptrCast(@alignCast(c.gst_object_ref(p)));
    return null;
}

pub export fn gst_video_decoder_get_allocator(decoder: [*c]Dec, allocator: [*c][*c]c.GstAllocator, params: [*c]c.GstAllocationParams) void {
    if (!check.that(isDec(decoder), "gst_video_decoder_get_allocator", "GST_IS_VIDEO_DECODER (decoder)")) return;
    const p = priv(decoder);
    if (allocator != null) allocator[0] = if (p.allocator != null) @ptrCast(@alignCast(c.gst_object_ref(p.allocator))) else null;
    if (params != null) params[0] = p.params;
}

pub export fn gst_video_decoder_set_use_default_pad_acceptcaps(decoder: [*c]Dec, use: c.gboolean) void {
    priv(decoder).use_default_pad_acceptcaps = use != 0;
}

fn requestSyncPoint(d: [*c]Dec, deadline: u64, flags: c.GstVideoDecoderRequestSyncPointFlags) void {
    if (!check.that(isDec(d), "gst_video_decoder_request_sync_point_internal", "GST_IS_VIDEO_DECODER (dec)")) return;
    const p = priv(d);
    var fku: [*c]Event = null;
    el.lock(d);
    if (p.min_force_key_unit_interval == 0 or deadline == NONE or (p.min_force_key_unit_interval != NONE and (p.last_force_key_unit_time == NONE or p.last_force_key_unit_time +% p.min_force_key_unit_interval <= deadline))) {
        fku = vevent.gst_video_event_new_upstream_force_key_unit(NONE, 0, 0);
        p.last_force_key_unit_time = deadline;
    }
    p.request_sync_point_flags |= flags;
    p.request_sync_point_frame_number = PENDING;
    el.unlock(d);
    if (fku != null) _ = c.gst_pad_push_event(d[0].sinkpad, fku);
}

pub export fn gst_video_decoder_request_sync_point(dec: [*c]Dec, frame: [*c]Frame, flags: c.GstVideoDecoderRequestSyncPointFlags) void {
    const fname = "gst_video_decoder_request_sync_point";
    if (!check.that(isDec(dec), fname, "GST_IS_VIDEO_DECODER (dec)")) return;
    if (!check.that(frame != null, fname, "frame != NULL")) return;
    requestSyncPoint(dec, frame[0].deadline, flags);
}

pub export fn gst_video_decoder_set_needs_sync_point(dec: [*c]Dec, enabled: c.gboolean) void {
    if (!check.that(isDec(dec), "gst_video_decoder_set_needs_sync_point", "GST_IS_VIDEO_DECODER (dec)")) return;
    priv(dec).needs_sync_point = enabled != 0;
}

pub export fn gst_video_decoder_get_needs_sync_point(dec: [*c]Dec) c.gboolean {
    if (!check.that(isDec(dec), "gst_video_decoder_get_needs_sync_point", "GST_IS_VIDEO_DECODER (dec)")) return 0;
    return @intFromBool(priv(dec).needs_sync_point);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    _ = c._gst_debug_category_new("videodecoder", 0, "Base Video Decoder");
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const vc: *Class = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    ec.change_state = changeState;
    vc.sink_event = sinkEventDefault;
    vc.src_event = srcEventDefault;
    vc.decide_allocation = decideAllocationDefault;
    vc.propose_allocation = proposeAllocationDefault;
    vc.negotiate = negotiateDefault;
    vc.sink_query = sinkQueryDefault;
    vc.src_query = srcQueryDefault;
    vc.transform_meta = transformMetaDefault;
    vc.handle_missing_data = missingDataDefault;
    const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_boolean("qos", "Quality of Service", "Handle Quality-of-Service events from downstream", 1, RW));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_int("max-errors", "Max errors", "Max consecutive decoder errors before returning flow error", -1, std.math.maxInt(c.gint), c.GST_VIDEO_DECODER_MAX_ERRORS, RW));
    c.g_object_class_install_property(oc, 3, c.g_param_spec_uint64("min-force-key-unit-interval", "Minimum Force Keyunit Interval", "Minimum interval between force-keyunit requests in nanoseconds", 0, std.math.maxInt(u64), 0, RW));
    c.g_object_class_install_property(oc, 4, c.g_param_spec_boolean("discard-corrupted-frames", "Discard Corrupted Frames", "Discard frames marked as corrupted instead of outputting them", 0, RW));
    c.g_object_class_install_property(oc, 5, c.g_param_spec_boolean("automatic-request-sync-points", "Automatic Request Sync Points", "Automatically request sync points when it would be useful", 0, RW));
    c.g_object_class_install_property(oc, 6, c.g_param_spec_flags("automatic-request-sync-point-flags", "Automatic Request Sync Point Flags", "Flags to use when automatically requesting sync points", c.gst_video_decoder_request_sync_point_flags_get_type(), AUTO_FLAGS, RW));
    video_tag = c.g_quark_from_static_string("video");
}

fn init(inst: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const d = of(inst);
    d[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    const ec: [*c]c.GstElementClass = @ptrCast(@alignCast(g_class));
    var tmpl = c.gst_element_class_get_pad_template(ec, "sink");
    if (!check.that(tmpl != null, "gst_video_decoder_init", "pad_template != NULL")) return;
    d[0].sinkpad = c.gst_pad_new_from_template(tmpl, "sink");
    c.gst_pad_set_chain_function_full(d[0].sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(d[0].sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(d[0].sinkpad, sinkQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(d), d[0].sinkpad);
    tmpl = c.gst_element_class_get_pad_template(ec, "src");
    if (!check.that(tmpl != null, "gst_video_decoder_init", "pad_template != NULL")) return;
    d[0].srcpad = c.gst_pad_new_from_template(tmpl, "src");
    c.gst_pad_set_event_function_full(d[0].srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(d[0].srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(d), d[0].srcpad);
    c.gst_segment_init(&d[0].input_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&d[0].output_segment, c.GST_FORMAT_TIME);
    c.g_rec_mutex_init(&d[0].stream_lock);
    const p = priv(d);
    p.input_adapter = c.gst_adapter_new();
    p.output_adapter = c.gst_adapter_new();
    p.packetized = true;
    p.needs_format = false;
    c.g_queue_init(&p.frames);
    c.g_queue_init(&p.timestamps);
    p.do_qos = true;
    p.max_errors = c.GST_VIDEO_DECODER_MAX_ERRORS;
    p.min_latency = 0;
    p.max_latency = 0;
    p.automatic_request_sync_points = false;
    p.automatic_request_sync_point_flags = AUTO_FLAGS;
    reset(d, true, true);
}

pub export fn gst_video_decoder_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstVideoDecoder", Class, Dec, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}
