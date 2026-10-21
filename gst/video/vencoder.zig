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
const meta = @import("meta.zig");
const color = @import("color.zig");
const chroma = @import("chroma.zig");
const multiview = @import("multiview.zig");
const hdr = @import("hdr.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Enc = c.GstVideoEncoder;
const Class = c.GstVideoEncoderClass;
const Frame = c.GstVideoCodecFrame;
const State = c.GstVideoCodecState;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const NONE = el.NONE;
const VNONE = @as(?*anyopaque, null);
const SEC: u64 = c.GST_SECOND;
const PATH = "../gst-libs/gst/video/gstvideoencoder.c";
const SYNC_POINT = c.GST_VIDEO_CODEC_FRAME_FLAG_SYNC_POINT;

const Private = struct {
    presentation_frame_number: u64,
    distance_from_sync: c_int,
    drained: bool,
    min_latency: i64,
    max_latency: i64,
    posted_latency_msg: bool,
    current_frame_events: [*c]c.GList,
    pending_events: [*c]c.GList,
    headers: [*c]c.GList,
    new_headers: bool,
    force_key_unit: c.GQueue,
    min_force_key_unit_interval: u64,
    last_force_key_unit_request: u64,
    last_key_unit: u64,
    system_frame_number: u32,
    frames: c.GQueue,
    input_state: [*c]State,
    output_state: [*c]State,
    output_state_changed: bool,
    bytes: i64,
    time: i64,
    allocator: [*c]c.GstAllocator,
    params: c.GstAllocationParams,
    upstream_tags: ?*c.GstTagList,
    tags: ?*c.GstTagList,
    tags_merge_mode: c.GstTagMergeMode,
    tags_changed: bool,
    min_pts: u64,
    time_adjustment: u64,
    qos_enabled: c.gint,
    proportion: f64,
    earliest_time: u64,
    qos_frame_duration: u64,
    dropped: c.guint,
    processed: c.guint,
};

const Fku = struct {
    running_time: u64,
    pending: bool,
    all_headers: bool,
    count: c.guint,
    frame_id: u32,
};

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstElementClass = null;
var video_tag: c.GQuark = 0;

fn of(p: anytype) [*c]Enc {
    return @ptrCast(@alignCast(p));
}

fn priv(e: anytype) *Private {
    return @ptrCast(@alignCast(of(e).*.priv));
}

fn klass(e: anytype) *Class {
    return gtype.classPeek(Class, e);
}

fn isEnc(e: anytype) bool {
    return gtype.instanceOf(e, gst_video_encoder_get_type());
}

fn streamLock(e: [*c]Enc) void {
    c.g_rec_mutex_lock(&e.*.stream_lock);
}

fn streamUnlock(e: [*c]Enc) void {
    c.g_rec_mutex_unlock(&e.*.stream_lock);
}

fn valid(t: u64) bool {
    return t != NONE;
}

fn post(e: [*c]Enc, domain: el.Domain, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    el.messageAt(e, c.GST_MESSAGE_ERROR, domain, code, text, debug, PATH, func, line, null);
}

fn unrefMini(p: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

fn unrefMini2(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

fn unrefFrame(p: c.gpointer) callconv(.c) void {
    codec.gst_video_codec_frame_unref(@ptrCast(@alignCast(p)));
}

fn refFrame(p: c.gconstpointer, _: c.gpointer) callconv(.c) c.gpointer {
    return @ptrCast(codec.gst_video_codec_frame_ref(@ptrCast(@alignCast(@constCast(p)))));
}

fn freeFku(p: c.gpointer) callconv(.c) void {
    c.g_free(p);
}

fn newFku(rt: u64, all: bool, count: c.guint) *Fku {
    const f: *Fku = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Fku))));
    f.running_time = rt;
    f.all_headers = all;
    f.count = count;
    return f;
}

fn cmpFku(pa: c.gconstpointer, pb: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const a: *const Fku = @ptrCast(@alignCast(pa));
    const b: *const Fku = @ptrCast(@alignCast(pb));
    if (a.running_time == b.running_time) {
        if (a.pending and !b.pending) return -1;
        if (!a.pending and b.pending) return 1;
        return 0;
    }
    if (a.running_time == NONE) return -1;
    if (b.running_time == NONE) return 1;
    if (a.running_time < b.running_time) return -1;
    return 1;
}

fn frameHas(f: [*c]Frame, flag: c.guint32) bool {
    return f[0].flags & flag != 0;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => gst_video_encoder_set_qos_enabled(of(o), c.g_value_get_boolean(v)),
        2 => gst_video_encoder_set_min_force_key_unit_interval(of(o), c.g_value_get_uint64(v)),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 359),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => c.g_value_set_boolean(v, gst_video_encoder_is_qos_enabled(of(o))),
        2 => c.g_value_set_uint64(v, gst_video_encoder_get_min_force_key_unit_interval(of(o))),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 379),
    }
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

fn reset(e: [*c]Enc, hard: bool) void {
    const p = priv(e);
    streamLock(e);
    p.presentation_frame_number = 0;
    p.distance_from_sync = 0;
    c.g_queue_clear_full(&p.force_key_unit, freeFku);
    p.last_force_key_unit_request = NONE;
    p.last_key_unit = NONE;
    p.drained = true;
    el.lock(e);
    p.bytes = 0;
    p.time = 0;
    el.unlock(e);
    p.time_adjustment = NONE;
    if (hard) {
        c.gst_segment_init(&e[0].input_segment, c.GST_FORMAT_TIME);
        c.gst_segment_init(&e[0].output_segment, c.GST_FORMAT_TIME);
        if (p.input_state != null) codec.gst_video_codec_state_unref(p.input_state);
        p.input_state = null;
        if (p.output_state != null) codec.gst_video_codec_state_unref(p.output_state);
        p.output_state = null;
        if (p.upstream_tags) |t| c.gst_mini_object_unref(@ptrCast(t));
        p.upstream_tags = null;
        if (p.tags) |t| c.gst_mini_object_unref(@ptrCast(t));
        p.tags = null;
        p.tags_merge_mode = c.GST_TAG_MERGE_APPEND;
        p.tags_changed = false;
        c.g_list_foreach(p.headers, unrefMini2, null);
        c.g_list_free(p.headers);
        p.headers = null;
        p.new_headers = false;
        if (p.allocator != null) c.gst_object_unref(p.allocator);
        p.allocator = null;
        c.g_list_free_full(p.current_frame_events, unrefMini);
        p.current_frame_events = null;
        c.g_list_free_full(p.pending_events, unrefMini);
        p.pending_events = null;
        el.lock(e);
        p.proportion = 0.5;
        p.earliest_time = NONE;
        p.qos_frame_duration = 0;
        el.unlock(e);
        p.dropped = 0;
        p.processed = 0;
        p.posted_latency_msg = false;
    } else {
        var l = p.frames.head;
        while (l != null) : (l = l[0].next) {
            const f: [*c]Frame = @ptrCast(@alignCast(l[0].data));
            f[0].events = flushEvents(e[0].srcpad, f[0].events);
        }
        p.current_frame_events = flushEvents(e[0].srcpad, p.current_frame_events);
    }
    c.g_queue_clear_full(&p.frames, unrefFrame);
    streamUnlock(e);
}

fn flush(e: [*c]Enc) bool {
    if (klass(e).flush) |f| return f(e) != 0;
    return true;
}

pub export fn gst_video_encoder_set_headers(encoder: [*c]Enc, headers: [*c]c.GList) void {
    const p = priv(encoder);
    streamLock(encoder);
    if (p.headers != null) {
        c.g_list_foreach(p.headers, unrefMini2, null);
        c.g_list_free(p.headers);
    }
    p.headers = headers;
    p.new_headers = true;
    streamUnlock(encoder);
}

fn newOutputState(caps: [*c]c.GstCaps, reference: [*c]State) [*c]State {
    const s: [*c]State = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(State))));
    s[0].ref_count = 1;
    info.gst_video_info_init(&s[0].info);
    if (info.gst_video_info_set_format(&s[0].info, c.GST_VIDEO_FORMAT_ENCODED, 0, 0) == 0) {
        c.g_free(s);
        return null;
    }
    s[0].caps = caps;
    if (reference != null) {
        const t = &s[0].info;
        const r = &reference[0].info;
        t.interlace_mode = r.interlace_mode;
        t.flags = r.flags;
        t.width = r.width;
        t.height = r.height;
        t.chroma_site = r.chroma_site;
        t.colorimetry = r.colorimetry;
        t.par_n = r.par_n;
        t.par_d = r.par_d;
        t.fps_n = r.fps_n;
        t.fps_d = r.fps_d;
        t.ABI.abi.field_order = r.ABI.abi.field_order;
        t.ABI.abi.multiview_mode = r.ABI.abi.multiview_mode;
        t.ABI.abi.multiview_flags = r.ABI.abi.multiview_flags;
        if (reference[0].mastering_display_info != null) s[0].mastering_display_info = @ptrCast(@alignCast(c.g_memdup2(reference[0].mastering_display_info, @sizeOf(c.GstVideoMasteringDisplayInfo))));
        if (reference[0].content_light_level != null) s[0].content_light_level = @ptrCast(@alignCast(c.g_memdup2(reference[0].content_light_level, @sizeOf(c.GstVideoContentLightLevel))));
    }
    return s;
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
    var str = c.gst_structure_get_string(st, "mastering-display-info");
    if (str != null) {
        s[0].mastering_display_info = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstVideoMasteringDisplayInfo))));
        _ = hdr.gst_video_mastering_display_info_from_string(s[0].mastering_display_info, str);
    }
    str = c.gst_structure_get_string(st, "content-light-level");
    if (str != null) {
        s[0].content_light_level = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstVideoContentLightLevel))));
        _ = hdr.gst_video_content_light_level_from_string(s[0].content_light_level, str);
    }
    return s;
}

fn setcaps(e: [*c]Enc, caps: [*c]c.GstCaps) bool {
    const k = klass(e);
    const p = priv(e);
    streamLock(e);
    defer streamUnlock(e);
    if (p.input_state != null and c.gst_caps_is_equal(p.input_state[0].caps, caps) != 0) return true;
    const state = newInputState(caps);
    if (state == null) return false;
    if (p.input_state != null and info.gst_video_info_is_equal(&state[0].info, &p.input_state[0].info) != 0) {
        codec.gst_video_codec_state_unref(state);
        return true;
    }
    if (k.reset) |f| _ = f(e, 1);
    var ret = true;
    if (k.set_format) |f| ret = f(e, state) != 0;
    if (ret) {
        if (p.input_state != null) codec.gst_video_codec_state_unref(p.input_state);
        p.input_state = state;
    } else codec.gst_video_codec_state_unref(state);
    return ret;
}

pub export fn gst_video_encoder_proxy_getcaps(encoder: [*c]Enc, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    return vutils.proxyGetcaps(encoder[0].sinkpad, encoder[0].srcpad, caps, filter);
}

fn sinkGetcaps(e: [*c]Enc, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    if (klass(e).getcaps) |f| return f(e, filter);
    return gst_video_encoder_proxy_getcaps(e, null, filter);
}

fn decideAllocationDefault(_: [*c]Enc, query: [*c]Query) callconv(.c) c.gboolean {
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    var update = false;
    if (c.gst_query_get_n_allocation_params(query) > 0) {
        c.gst_query_parse_nth_allocation_param(query, 0, &allocator, &params);
        update = true;
    } else c.gst_allocation_params_init(&params);
    if (update) c.gst_query_set_nth_allocation_param(query, 0, allocator, &params) else c.gst_query_add_allocation_param(query, allocator, &params);
    if (allocator != null) c.gst_object_unref(allocator);
    return 1;
}

fn proposeAllocationDefault(e: [*c]Enc, query: [*c]Query) callconv(.c) c.gboolean {
    var caps: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(query, &caps, null);
    if (caps == null) return 0;
    var vi: c.GstVideoInfo = undefined;
    if (info.gst_video_info_from_caps(&vi, caps) == 0) return 0;
    const size: c.guint = @truncate(vi.size);
    if (c.gst_query_get_n_allocation_pools(query) != 0) return 1;
    var allocator: [*c]c.GstAllocator = null;
    var params = c.GstAllocationParams{ .flags = 0, .@"align" = 15, .prefix = 0, .padding = 0 };
    if (c.gst_query_get_n_allocation_params(query) > 0) {
        c.gst_query_parse_nth_allocation_param(query, 0, &allocator, &params);
    } else c.gst_query_add_allocation_param(query, allocator, &params);
    const bp = pool.gst_video_buffer_pool_new();
    const name = c.g_strdup_printf("%s-propose-pool", @as(*c.GstObject, @ptrCast(@alignCast(e))).name);
    c.g_object_set(bp, "name", name, VNONE);
    c.g_free(name);
    const st = c.gst_buffer_pool_get_config(bp);
    c.gst_buffer_pool_config_set_params(st, caps, size, 0, 0);
    c.gst_buffer_pool_config_set_allocator(st, allocator, &params);
    if (allocator != null) c.gst_object_unref(allocator);
    if (c.gst_buffer_pool_set_config(bp, st) == 0) {
        c.gst_object_unref(bp);
        return 0;
    }
    c.gst_query_add_allocation_pool(query, bp, size, 0, 0);
    c.gst_object_unref(bp);
    c.gst_query_add_allocation_meta(query, meta.gst_video_meta_api_get_type(), null);
    return 1;
}

fn sinkQueryDefault(e: [*c]Enc, query: [*c]Query) callconv(.c) c.gboolean {
    const pad = e[0].sinkpad;
    const p = priv(e);
    switch (query[0].type) {
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(query, &filter);
            const caps = sinkGetcaps(e, filter);
            c.gst_query_set_caps_result(query, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(query, &sf, &sv, &df, &dv);
            el.lock(e);
            const res = if (p.input_state != null) vutils.rawvideoConvert(p.input_state, sf, sv, &df, &dv) else false;
            el.unlock(e);
            if (!res) return 0;
            c.gst_query_set_convert(query, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_ALLOCATION => {
            if (klass(e).propose_allocation) |f| return f(e, query);
            return 0;
        },
        else => return c.gst_pad_query_default(pad, @ptrCast(e), query),
    }
}

fn sinkQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, query: [*c]Query) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    if (klass(e).sink_query) |f| return f(e, query);
    return 0;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const e = of(o);
    c.g_rec_mutex_clear(&e[0].stream_lock);
    const p = priv(e);
    if (p.allocator != null) c.gst_object_unref(p.allocator);
    p.allocator = null;
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn pushEvent(e: [*c]Enc, event_in: [*c]Event) bool {
    var event = event_in;
    if (event[0].type == c.GST_EVENT_SEGMENT) {
        streamLock(e);
        var seg: c.GstSegment = undefined;
        c.gst_event_copy_segment(event, &seg);
        if (seg.format != c.GST_FORMAT_TIME) {
            streamUnlock(e);
        } else {
            const p = priv(e);
            if (p.time_adjustment != NONE) {
                seg.start +%= p.time_adjustment;
                if (valid(seg.position)) seg.position +%= p.time_adjustment;
                if (valid(seg.stop)) seg.stop +%= p.time_adjustment;
            }
            e[0].output_segment = seg;
            streamUnlock(e);
            c.gst_mini_object_unref(@ptrCast(event));
            event = c.gst_event_new_segment(&e[0].output_segment);
        }
    }
    return c.gst_pad_push_event(e[0].srcpad, event) != 0;
}

fn mergedTags(e: [*c]Enc) [*c]Event {
    const p = priv(e);
    const merged = c.gst_tag_list_merge(p.upstream_tags, p.tags, p.tags_merge_mode);
    if (merged == null) return null;
    if (c.gst_tag_list_is_empty(merged) != 0) {
        c.gst_mini_object_unref(@ptrCast(merged));
        return null;
    }
    return c.gst_event_new_tag(merged);
}

fn checkPushTags(e: [*c]Enc) void {
    const p = priv(e);
    if (p.tags_changed) {
        const te = mergedTags(e);
        if (te != null) _ = pushEvent(e, te);
        p.tags_changed = false;
    }
}

const STRIP_TAGS = [_][*:0]const u8{ "codec", "audio-codec", "video-codec", "subtitle-codec", "container-format", "bitrate", "nominal-bitrate", "maximum-bitrate", "minimum-bitrate", "encoder", "encoder-version" };

fn sinkEventDefault(e: [*c]Enc, event_in: [*c]Event) callconv(.c) c.gboolean {
    const k = klass(e);
    const p = priv(e);
    var event = event_in;
    var ret = false;
    switch (event[0].type) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(event, &caps);
            ret = setcaps(e, caps);
            c.gst_mini_object_unref(@ptrCast(event));
            event = null;
        },
        c.GST_EVENT_EOS => {
            streamLock(e);
            const flow: c.GstFlowReturn = if (k.finish) |f| f(e) else c.GST_FLOW_OK;
            if (p.current_frame_events != null) {
                var l = c.g_list_last(p.current_frame_events);
                while (l != null) : (l = l[0].prev) _ = pushEvent(e, @ptrCast(@alignCast(l[0].data)));
            }
            c.g_list_free(p.current_frame_events);
            p.current_frame_events = null;
            checkPushTags(e);
            ret = flow == c.GST_FLOW_OK;
            streamUnlock(e);
        },
        c.GST_EVENT_SEGMENT => {
            streamLock(e);
            var seg: c.GstSegment = undefined;
            c.gst_event_copy_segment(event, &seg);
            if (seg.format == c.GST_FORMAT_TIME) {
                e[0].input_segment = seg;
                ret = true;
            }
            streamUnlock(e);
        },
        c.GST_EVENT_CUSTOM_DOWNSTREAM => {
            if (vevent.gst_video_event_is_force_key_unit(event) != 0) {
                var rt: c.GstClockTime = 0;
                var all: c.gboolean = 0;
                var count: c.guint = 0;
                if (vevent.gst_video_event_parse_downstream_force_key_unit(event, null, null, &rt, &all, &count) != 0) {
                    el.lock(e);
                    c.g_queue_insert_sorted(&p.force_key_unit, newFku(rt, all != 0, count), cmpFku, null);
                    el.unlock(e);
                }
                c.gst_mini_object_unref(@ptrCast(event));
                event = null;
                ret = true;
            }
        },
        c.GST_EVENT_STREAM_START => {
            streamLock(e);
            if (p.upstream_tags) |t| {
                c.gst_mini_object_unref(@ptrCast(t));
                p.upstream_tags = null;
                p.tags_changed = true;
            }
            streamUnlock(e);
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(event, &tags);
            if (c.gst_tag_list_get_scope(tags) == c.GST_TAG_SCOPE_STREAM) {
                streamLock(e);
                if (p.upstream_tags != tags) {
                    const copy = c.gst_tag_list_copy(tags);
                    for (STRIP_TAGS) |t| c.gst_tag_list_remove_tag(copy, t);
                    if (p.upstream_tags) |t| c.gst_mini_object_unref(@ptrCast(t));
                    p.upstream_tags = copy;
                }
                c.gst_mini_object_unref(@ptrCast(event));
                event = mergedTags(e);
                streamUnlock(e);
                if (event == null) ret = true;
            }
        },
        c.GST_EVENT_FLUSH_STOP => {
            streamLock(e);
            _ = flush(e);
            c.gst_segment_init(&e[0].input_segment, c.GST_FORMAT_TIME);
            c.gst_segment_init(&e[0].output_segment, c.GST_FORMAT_TIME);
            reset(e, false);
            streamUnlock(e);
        },
        else => {},
    }
    if (event != null) {
        const t = event[0].type;
        if (t & c.GST_EVENT_TYPE_SERIALIZED == 0 or t == c.GST_EVENT_EOS or t == c.GST_EVENT_FLUSH_STOP) {
            ret = pushEvent(e, event);
        } else {
            streamLock(e);
            p.current_frame_events = c.g_list_prepend(p.current_frame_events, event);
            streamUnlock(e);
            ret = true;
        }
    }
    return @intFromBool(ret);
}

fn sinkEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, event: [*c]Event) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    if (klass(e).sink_event) |f| return f(e, event);
    return 1;
}

fn srcEventDefault(e: [*c]Enc, event_in: [*c]Event) callconv(.c) c.gboolean {
    const p = priv(e);
    var event = event_in;
    var ret: c.gboolean = 0;
    switch (event[0].type) {
        c.GST_EVENT_CUSTOM_UPSTREAM => {
            if (vevent.gst_video_event_is_force_key_unit(event) != 0) {
                var rt: c.GstClockTime = 0;
                var all: c.gboolean = 0;
                var count: c.guint = 0;
                if (vevent.gst_video_event_parse_upstream_force_key_unit(event, &rt, &all, &count) != 0) {
                    el.lock(e);
                    c.g_queue_insert_sorted(&p.force_key_unit, newFku(rt, all != 0, count), cmpFku, null);
                    el.unlock(e);
                }
                c.gst_mini_object_unref(@ptrCast(event));
                event = null;
                ret = 1;
            }
        },
        c.GST_EVENT_QOS => {
            if (@atomicLoad(c.gint, &p.qos_enabled, .seq_cst) != 0) {
                var t: c.GstQOSType = 0;
                var proportion: f64 = 0;
                var diff: c.GstClockTimeDiff = 0;
                var ts: c.GstClockTime = 0;
                c.gst_event_parse_qos(event, &t, &proportion, &diff, &ts);
                el.lock(e);
                p.proportion = proportion;
                if (valid(ts)) {
                    if (diff > 0) {
                        p.earliest_time = ts +% @as(u64, @bitCast(@min(2 * diff, @as(i64, @intCast(SEC))))) +% p.qos_frame_duration;
                    } else p.earliest_time = ts +% @as(u64, @bitCast(diff));
                } else p.earliest_time = NONE;
                el.unlock(e);
                ret = c.gst_pad_push_event(e[0].sinkpad, event);
                event = null;
            }
        },
        else => {},
    }
    if (event != null) ret = c.gst_pad_event_default(e[0].srcpad, @ptrCast(e), event);
    return ret;
}

fn srcEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, event: [*c]Event) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    if (klass(e).src_event) |f| return f(e, event);
    return 0;
}

fn srcQueryDefault(e: [*c]Enc, query: [*c]Query) callconv(.c) c.gboolean {
    const p = priv(e);
    switch (query[0].type) {
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(query, &sf, &sv, &df, &dv);
            el.lock(e);
            const res = vutils.encodedConvert(p.bytes, p.time, sf, sv, &df, &dv);
            el.unlock(e);
            if (!res) return 0;
            c.gst_query_set_convert(query, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_LATENCY => {
            const res = c.gst_pad_peer_query(e[0].sinkpad, query);
            if (res != 0) {
                var live: c.gboolean = 0;
                var min: c.GstClockTime = 0;
                var max: c.GstClockTime = 0;
                c.gst_query_parse_latency(query, &live, &min, &max);
                el.lock(e);
                min +%= @bitCast(p.min_latency);
                if (max == NONE or p.max_latency == -1) max = NONE else max +%= @bitCast(p.max_latency);
                el.unlock(e);
                c.gst_query_set_latency(query, live, min, max);
            }
            return res;
        },
        else => return c.gst_pad_query_default(e[0].srcpad, @ptrCast(e), query),
    }
}

fn srcQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, query: [*c]Query) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    if (klass(e).src_query) |f| return f(e, query);
    return 0;
}

fn newFrame(e: [*c]Enc, buf: [*c]Buffer, pts: u64, dts: u64, duration: u64) [*c]Frame {
    const p = priv(e);
    const f: [*c]Frame = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Frame))));
    f[0].ref_count = 1;
    streamLock(e);
    f[0].system_frame_number = p.system_frame_number;
    p.system_frame_number +%= 1;
    f[0].presentation_frame_number = @truncate(p.presentation_frame_number);
    p.presentation_frame_number +%= 1;
    streamUnlock(e);
    f[0].events = p.current_frame_events;
    p.current_frame_events = null;
    f[0].input_buffer = buf;
    f[0].pts = pts;
    f[0].dts = dts;
    f[0].duration = duration;
    f[0].abidata.ABI.ts = pts;
    return f;
}

fn chain(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, buf: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const e = of(parent_obj);
    const p = priv(e);
    const k = klass(e);
    if (!check.that(k.handle_frame != null, "gst_video_encoder_chain", "klass->handle_frame != NULL")) return c.GST_FLOW_ERROR;
    if (p.input_state == null) {
        post(e, .core, c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("encoder not initialized"), "gst_video_encoder_chain", 1745);
        c.gst_mini_object_unref(@ptrCast(buf));
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    streamLock(e);
    defer streamUnlock(e);
    const start = buf[0].pts;
    var duration = buf[0].duration;
    const stop: u64 = if (valid(duration)) start +% duration else NONE;
    var cstart: u64 = 0;
    var cstop: u64 = 0;
    if (c.gst_segment_clip(&e[0].input_segment, c.GST_FORMAT_TIME, start, stop, &cstart, &cstop) == 0) {
        c.gst_mini_object_unref(@ptrCast(buf));
        return c.GST_FLOW_OK;
    }
    duration = if (valid(cstop)) cstop -% cstart else NONE;
    if (p.min_pts != NONE and p.time_adjustment == NONE) {
        if (cstart < p.min_pts) p.time_adjustment = p.min_pts - cstart;
    }
    const adjusted = if (p.time_adjustment != NONE) cstart +% p.time_adjustment else cstart;
    const frame = newFrame(e, buf, adjusted, NONE, duration);
    el.lock(e);
    if (p.force_key_unit.head != null) {
        const rt = c.gst_segment_to_running_time(&e[0].input_segment, c.GST_FORMAT_TIME, cstart);
        const mi = p.min_force_key_unit_interval;
        const throttled = mi != 0 and mi != NONE and ((p.last_force_key_unit_request != NONE and p.last_force_key_unit_request +% mi > rt) or (p.last_key_unit != NONE and p.last_key_unit +% mi > rt));
        var have = false;
        var have_pending_none = false;
        var matching = std.mem.zeroes(c.GQueue);
        var l = p.force_key_unit.head;
        while (l != null and (!throttled or !have)) : (l = l[0].next) {
            const f: *Fku = @ptrCast(@alignCast(l[0].data));
            if (f.pending) {
                if (f.running_time == NONE) have_pending_none = true;
                continue;
            }
            if (f.running_time == NONE or f.running_time <= rt) {
                have = true;
                if (!throttled) c.g_queue_push_tail(&matching, f);
                continue;
            }
            break;
        }
        if (throttled and have) c.g_queue_clear(&matching);
        if (matching.length > 0) {
            var all = false;
            var force = false;
            while (c.g_queue_pop_head(&matching)) |raw| {
                const f: *Fku = @ptrCast(@alignCast(raw));
                f.pending = true;
                const skip = (f.running_time == NONE and have_pending_none) or (p.last_force_key_unit_request != NONE and f.running_time != NONE and f.running_time <= p.last_force_key_unit_request) or (p.last_key_unit != NONE and f.running_time != NONE and f.running_time <= p.last_key_unit);
                if (!skip) {
                    force = true;
                    f.frame_id = frame[0].system_frame_number;
                    if (f.all_headers) all = true;
                }
            }
            if (force) {
                frame[0].flags |= c.GST_VIDEO_CODEC_FRAME_FLAG_FORCE_KEYFRAME;
                if (all) frame[0].flags |= c.GST_VIDEO_CODEC_FRAME_FLAG_FORCE_KEYFRAME_HEADERS;
                p.last_force_key_unit_request = rt;
            }
        }
    }
    el.unlock(e);
    c.g_queue_push_tail(&p.frames, codec.gst_video_codec_frame_ref(frame));
    p.drained = false;
    frame[0].deadline = c.gst_segment_to_running_time(&e[0].input_segment, c.GST_FORMAT_TIME, cstart);
    return k.handle_frame.?(e, frame);
}

fn changeState(el_in: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const e = of(el_in);
    const k = klass(e);
    const fname = "gst_video_encoder_change_state";
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            if (k.open) |f| {
                if (f(e) == 0) {
                    post(e, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to open encoder"), fname, 1813);
                    return c.GST_STATE_CHANGE_FAILURE;
                }
            }
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            streamLock(e);
            reset(e, true);
            streamUnlock(e);
            if (k.start) |f| {
                if (f(e) == 0) {
                    post(e, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to start encoder"), fname, 1820);
                    return c.GST_STATE_CHANGE_FAILURE;
                }
            }
        },
        else => {},
    }
    const ret = parent.?.change_state.?(el_in, t);
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            var stopped = true;
            if (k.stop) |f| stopped = f(e) != 0;
            streamLock(e);
            reset(e, true);
            streamUnlock(e);
            if (!stopped) {
                post(e, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to stop encoder"), fname, 1827);
                return c.GST_STATE_CHANGE_FAILURE;
            }
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (k.close) |f| {
                if (f(e) == 0) {
                    post(e, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to close encoder"), fname, 1834);
                    return c.GST_STATE_CHANGE_FAILURE;
                }
            }
        },
        else => {},
    }
    return ret;
}

fn negotiateDefault(e: [*c]Enc) callconv(.c) c.gboolean {
    const k = klass(e);
    const p = priv(e);
    const state = p.output_state;
    const vi = &state[0].info;
    if (!check.that(state[0].caps != null, "gst_video_encoder_negotiate_default", "state->caps != NULL")) return 0;
    if (p.output_state_changed) {
        state[0].caps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(state[0].caps)));
        const caps = state[0].caps;
        c.gst_caps_set_simple(caps, "width", c.G_TYPE_INT, vi.width, "height", c.G_TYPE_INT, vi.height, "pixel-aspect-ratio", c.gst_fraction_get_type(), vi.par_n, vi.par_d, VNONE);
        if (vi.flags & c.GST_VIDEO_FLAG_VARIABLE_FPS != 0 and vi.fps_n != 0) {
            c.gst_caps_set_simple(caps, "framerate", c.gst_fraction_get_type(), @as(c.gint, 0), @as(c.gint, 1), "max-framerate", c.gst_fraction_get_type(), vi.fps_n, vi.fps_d, VNONE);
        } else c.gst_caps_set_simple(caps, "framerate", c.gst_fraction_get_type(), vi.fps_n, vi.fps_d, VNONE);
        if (state[0].codec_data != null) c.gst_caps_set_simple(caps, "codec_data", c.gst_buffer_get_type(), state[0].codec_data, VNONE);
        c.gst_caps_set_simple(caps, "interlace-mode", c.G_TYPE_STRING, info.gst_video_interlace_mode_to_string(vi.interlace_mode), VNONE);
        const mode = vi.interlace_mode;
        if ((mode == c.GST_VIDEO_INTERLACE_MODE_INTERLEAVED or mode == c.GST_VIDEO_INTERLACE_MODE_FIELDS or mode == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) and vi.ABI.abi.field_order != c.GST_VIDEO_FIELD_ORDER_UNKNOWN) {
            c.gst_caps_set_simple(caps, "field-order", c.G_TYPE_STRING, info.gst_video_field_order_to_string(vi.ABI.abi.field_order), VNONE);
        }
        const colorimetry = color.gst_video_colorimetry_to_string(@ptrCast(&vi.colorimetry));
        if (colorimetry != null) c.gst_caps_set_simple(caps, "colorimetry", c.G_TYPE_STRING, colorimetry, VNONE);
        c.g_free(colorimetry);
        if (vi.chroma_site != c.GST_VIDEO_CHROMA_SITE_UNKNOWN) {
            const cs = chroma.gst_video_chroma_site_to_string(vi.chroma_site);
            if (cs != null) {
                c.gst_caps_set_simple(caps, "chroma-site", c.G_TYPE_STRING, cs, VNONE);
                c.g_free(cs);
            }
        }
        if (vi.ABI.abi.multiview_mode != c.GST_VIDEO_MULTIVIEW_MODE_NONE) {
            const mm = multiview.gst_video_multiview_mode_to_caps_string(vi.ABI.abi.multiview_mode);
            c.gst_caps_set_simple(caps, "multiview-mode", c.G_TYPE_STRING, mm, "multiview-flags", multiview.gst_video_multiview_flagset_get_type(), vi.ABI.abi.multiview_flags, c.GST_FLAG_SET_MASK_EXACT, VNONE);
        }
        const os = c.gst_caps_get_structure(caps, 0);
        if (state[0].mastering_display_info != null and c.gst_structure_has_field(os, "mastering-display-info") == 0) _ = hdr.gst_video_mastering_display_info_add_to_caps(state[0].mastering_display_info, caps);
        if (state[0].content_light_level != null and c.gst_structure_has_field(os, "content-light-level") == 0) _ = hdr.gst_video_content_light_level_add_to_caps(state[0].content_light_level, caps);
        p.output_state_changed = false;
    }
    if (state[0].allocation_caps == null) state[0].allocation_caps = c.gst_caps_ref(state[0].caps);
    const frame: [*c]Frame = if (p.frames.head != null) @ptrCast(@alignCast(p.frames.head[0].data)) else null;
    if (frame != null or p.current_frame_events != null) {
        const events: *[*c]c.GList = if (frame != null) @ptrCast(&frame[0].events) else &p.current_frame_events;
        var l = c.g_list_last(events.*);
        while (l != null) {
            const ev: [*c]Event = @ptrCast(@alignCast(l[0].data));
            if (ev[0].type < c.GST_EVENT_CAPS) {
                _ = pushEvent(e, ev);
                const tmp = l;
                l = l[0].prev;
                events.* = c.g_list_delete_link(events.*, tmp);
            } else l = l[0].prev;
        }
    }
    const prev = c.gst_pad_get_current_caps(e[0].srcpad);
    var ret = true;
    if (prev == null or c.gst_caps_is_equal(prev, state[0].caps) == 0) ret = vutils.padSetCaps(e[0].srcpad, state[0].caps);
    if (prev != null) c.gst_caps_unref(prev);
    if (!ret) return 0;
    const query = c.gst_query_new_allocation(state[0].allocation_caps, 1);
    defer c.gst_mini_object_unref(@ptrCast(query));
    _ = c.gst_pad_peer_query(e[0].srcpad, query);
    if (k.decide_allocation.?(e, query) == 0) return 0;
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_query_get_n_allocation_params(query) > 0) {
        c.gst_query_parse_nth_allocation_param(query, 0, &allocator, &params);
    } else c.gst_allocation_params_init(&params);
    if (p.allocator != null) c.gst_object_unref(p.allocator);
    p.allocator = allocator;
    p.params = params;
    return 1;
}

fn negotiateUnlocked(e: [*c]Enc) bool {
    if (klass(e).negotiate) |f| return f(e) != 0;
    return true;
}

pub export fn gst_video_encoder_negotiate(encoder: [*c]Enc) c.gboolean {
    const fname = "gst_video_encoder_negotiate";
    if (!check.that(isEnc(encoder), fname, "GST_IS_VIDEO_ENCODER (encoder)")) return 0;
    if (!check.that(priv(encoder).output_state != null, fname, "encoder->priv->output_state")) return 0;
    var ret = true;
    streamLock(encoder);
    _ = c.gst_pad_check_reconfigure(encoder[0].srcpad);
    if (klass(encoder).negotiate) |f| {
        ret = f(encoder) != 0;
        if (!ret) c.gst_pad_mark_reconfigure(encoder[0].srcpad);
    }
    streamUnlock(encoder);
    return @intFromBool(ret);
}

pub export fn gst_video_encoder_allocate_output_buffer(encoder: [*c]Enc, size: c.gsize) [*c]Buffer {
    if (!check.that(size > 0, "gst_video_encoder_allocate_output_buffer", "size > 0")) return null;
    const p = priv(encoder);
    streamLock(encoder);
    defer streamUnlock(encoder);
    const reconf = c.gst_pad_check_reconfigure(encoder[0].srcpad) != 0;
    if (p.output_state_changed or (p.output_state != null and reconf)) {
        if (!negotiateUnlocked(encoder)) {
            c.gst_pad_mark_reconfigure(encoder[0].srcpad);
            return c.gst_buffer_new_allocate(null, size, null);
        }
    }
    const b = c.gst_buffer_new_allocate(p.allocator, size, &p.params);
    if (b == null) return c.gst_buffer_new_allocate(null, size, null);
    return b;
}

pub export fn gst_video_encoder_allocate_output_frame(encoder: [*c]Enc, frame: [*c]Frame, size: c.gsize) c.GstFlowReturn {
    if (!check.that(frame[0].output_buffer == null, "gst_video_encoder_allocate_output_frame", "frame->output_buffer == NULL")) return c.GST_FLOW_ERROR;
    const p = priv(encoder);
    streamLock(encoder);
    defer streamUnlock(encoder);
    const reconf = c.gst_pad_check_reconfigure(encoder[0].srcpad) != 0;
    if (p.output_state_changed or (p.output_state != null and reconf)) {
        if (!negotiateUnlocked(encoder)) c.gst_pad_mark_reconfigure(encoder[0].srcpad);
    }
    frame[0].output_buffer = c.gst_buffer_new_allocate(p.allocator, size, &p.params);
    return if (frame[0].output_buffer != null) c.GST_FLOW_OK else c.GST_FLOW_ERROR;
}

fn releaseUnlocked(e: [*c]Enc, frame: [*c]Frame) void {
    const p = priv(e);
    const link = c.g_queue_find(&p.frames, frame);
    if (link != null) {
        codec.gst_video_codec_frame_unref(frame);
        c.g_queue_delete_link(&p.frames, link);
    }
    if (frame[0].events != null) {
        p.pending_events = c.g_list_concat(frame[0].events, p.pending_events);
        frame[0].events = null;
    }
    codec.gst_video_codec_frame_unref(frame);
}

pub export fn gst_video_encoder_release_frame(enc: [*c]Enc, frame: [*c]Frame) void {
    if (!check.that(isEnc(enc), "gst_video_encoder_release_frame", "GST_IS_VIDEO_ENCODER (enc)")) return;
    if (!check.that(frame != null, "gst_video_encoder_release_frame", "frame != NULL")) return;
    streamLock(enc);
    releaseUnlocked(enc, frame);
    streamUnlock(enc);
}

pub export fn gst_video_encoder_drop_frame(enc: [*c]Enc, frame: [*c]Frame) void {
    if (!check.that(isEnc(enc), "gst_video_encoder_drop_frame", "GST_IS_VIDEO_ENCODER (enc)")) return;
    if (!check.that(frame != null, "gst_video_encoder_drop_frame", "frame != NULL")) return;
    streamLock(enc);
    pushPending(enc, frame, true);
    qosDrop(enc, frame);
    releaseUnlocked(enc, frame);
    streamUnlock(enc);
}

var supported_tags = [_][*c]const u8{ "video", "orientation", "size", null };

fn transformMetaDefault(_: [*c]Enc, _: [*c]Frame, m: [*c]c.GstMeta) callconv(.c) c.gboolean {
    var tags = c.gst_meta_api_type_get_tags(m[0].info[0].api);
    if (tags == null) return 1;
    while (tags[0] != null) : (tags += 1) {
        if (c.g_strv_contains(@ptrCast(&supported_tags), tags[0]) == 0) return 0;
    }
    return 1;
}

const CopyData = struct { e: [*c]Enc, frame: [*c]Frame };

fn eachMeta(inbuf: [*c]Buffer, m: [*c][*c]c.GstMeta, user: c.gpointer) callconv(.c) c.gboolean {
    const data: *CopyData = @ptrCast(@alignCast(user));
    const mi = m[0][0].info;
    const k = klass(data.e);
    var copy = false;
    if (c.gst_meta_api_type_has_tag(mi[0].api, c._gst_meta_tag_memory) != 0 or c.gst_meta_api_type_has_tag(mi[0].api, c._gst_meta_tag_memory_reference) != 0) {
        copy = false;
    } else if (k.transform_meta) |f| copy = f(data.e, data.frame, m[0]) != 0;
    if (copy) {
        if (mi[0].transform_func) |tf| {
            var cd = c.GstMetaTransformCopy{ .region = 0, .offset = 0, .size = std.math.maxInt(c.gsize) };
            _ = tf(data.frame[0].output_buffer, m[0], inbuf, c._gst_meta_transform_copy, &cd);
        }
    }
    return 1;
}

fn qosDrop(e: [*c]Enc, frame: [*c]Frame) void {
    const p = priv(e);
    p.dropped += 1;
    el.lock(e);
    const proportion = p.proportion;
    const earliest = p.earliest_time;
    el.unlock(e);
    const timestamp = frame[0].pts;
    var seg = &e[0].output_segment;
    if (seg.format == c.GST_FORMAT_UNDEFINED) seg = &e[0].input_segment;
    const stream_time = c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, timestamp);
    const qostime = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, timestamp);
    const jitter: i64 = @as(i64, @bitCast(earliest)) -% @as(i64, @bitCast(qostime));
    const msg = c.gst_message_new_qos(@ptrCast(e), 0, qostime, stream_time, timestamp, NONE);
    c.gst_message_set_qos_values(msg, jitter, proportion, 1000000);
    c.gst_message_set_qos_stats(msg, c.GST_FORMAT_BUFFERS, p.processed, p.dropped);
    _ = c.gst_element_post_message(@ptrCast(e), msg);
}

fn canPush(e: [*c]Enc) c.GstFlowReturn {
    const p = priv(e);
    const reconf = c.gst_pad_check_reconfigure(e[0].srcpad) != 0;
    if (p.output_state_changed or (p.output_state != null and reconf)) {
        if (!negotiateUnlocked(e)) {
            c.gst_pad_mark_reconfigure(e[0].srcpad);
            if (el.flags(e[0].srcpad) & c.GST_PAD_FLAG_FLUSHING != 0) return c.GST_FLOW_FLUSHING;
            return c.GST_FLOW_NOT_NEGOTIATED;
        }
    }
    if (p.output_state == null) {
        post(e, .library, c.GST_LIBRARY_ERROR_FAILED, c.g_strdup("Output state was not configured"), null, "gst_video_encoder_can_push_unlocked", 2365);
        return c.GST_FLOW_ERROR;
    }
    return c.GST_FLOW_OK;
}

fn pushEventList(e: [*c]Enc, events: [*c]c.GList) void {
    var l = c.g_list_last(events);
    while (l != null) : (l = l[0].prev) _ = pushEvent(e, @ptrCast(@alignCast(l[0].data)));
    c.g_list_free(events);
}

fn pushPending(e: [*c]Enc, frame: [*c]Frame, dropping: bool) void {
    const p = priv(e);
    var events: [*c]c.GList = null;
    var l = p.frames.head;
    while (l != null) : (l = l[0].next) {
        const tmp: [*c]Frame = @ptrCast(@alignCast(l[0].data));
        if (tmp[0].events != null) {
            events = c.g_list_concat(tmp[0].events, events);
            tmp[0].events = null;
        }
        if (tmp == frame) break;
    }
    if (dropping) {
        p.pending_events = c.g_list_concat(events, p.pending_events);
    } else {
        pushEventList(e, p.pending_events);
        p.pending_events = null;
        pushEventList(e, events);
    }
    checkPushTags(e);
}

fn inferDts(e: [*c]Enc, frame: [*c]Frame) void {
    const p = priv(e);
    var min_ts: u64 = NONE;
    var oframe: [*c]Frame = null;
    var seen_none = false;
    var l = p.frames.head;
    while (l != null) : (l = l[0].next) {
        const tmp: [*c]Frame = @ptrCast(@alignCast(l[0].data));
        const ts = tmp[0].abidata.ABI.ts;
        if (!valid(ts)) {
            seen_none = true;
            continue;
        }
        if (!valid(min_ts) or ts < min_ts) {
            min_ts = ts;
            oframe = tmp;
        }
    }
    if (oframe != null and oframe != frame) oframe[0].abidata.ABI.ts = frame[0].abidata.ABI.ts;
    if (!valid(frame[0].dts) and !seen_none) frame[0].dts = min_ts;
}

fn sendHeaders(e: [*c]Enc, discont: *bool, key_unit_in: bool) void {
    const p = priv(e);
    if (!p.new_headers) return;
    var key_unit = key_unit_in;
    var l = p.headers;
    while (l != null) : (l = l[0].next) {
        const b: [*c]Buffer = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(@alignCast(l[0].data))));
        l[0].data = b;
        el.lock(e);
        p.bytes +%= @intCast(c.gst_buffer_get_size(b));
        el.unlock(e);
        if (key_unit) {
            key_unit = false;
            b[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DELTA_UNIT);
        } else b[0].mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
        if (discont.*) {
            b[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
            discont.* = false;
        } else b[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DISCONT);
        _ = c.gst_pad_push(e[0].srcpad, @ptrCast(c.gst_mini_object_ref(@ptrCast(b))));
    }
    p.new_headers = false;
}

fn transformMeta(e: [*c]Enc, frame: [*c]Frame) void {
    if (klass(e).transform_meta == null) return;
    if (frame[0].input_buffer == null) return;
    var data = CopyData{ .e = e, .frame = frame };
    _ = c.gst_buffer_foreach_meta(frame[0].input_buffer, eachMeta, &data);
}

fn sendKeyUnit(e: [*c]Enc, frame: [*c]Frame, send_headers: *bool) void {
    const p = priv(e);
    const rt = c.gst_segment_to_running_time(&e[0].output_segment, c.GST_FORMAT_TIME, frame[0].pts);
    var matching = std.mem.zeroes(c.GQueue);
    el.lock(e);
    var l = p.force_key_unit.head;
    while (l != null) {
        const f: *Fku = @ptrCast(@alignCast(l[0].data));
        if (!f.pending) {
            l = l[0].next;
            continue;
        }
        if (frame[0].system_frame_number == f.frame_id or f.running_time == NONE or f.running_time <= rt) {
            const next = l[0].next;
            c.g_queue_push_tail(&matching, f);
            c.g_queue_delete_link(&p.force_key_unit, l);
            l = next;
            continue;
        }
        break;
    }
    el.unlock(e);
    while (c.g_queue_pop_head(&matching)) |raw| {
        const f: *Fku = @ptrCast(@alignCast(raw));
        const st = c.gst_segment_to_stream_time(&e[0].output_segment, c.GST_FORMAT_TIME, frame[0].pts);
        const ev = vevent.gst_video_event_new_downstream_force_key_unit(frame[0].pts, st, rt, @intFromBool(f.all_headers), f.count);
        _ = pushEvent(e, ev);
        if (f.all_headers) send_headers.* = true;
        c.g_free(f);
    }
}

pub export fn gst_video_encoder_finish_frame(encoder: [*c]Enc, frame_in: [*c]Frame) c.GstFlowReturn {
    if (!check.that(frame_in != null, "gst_video_encoder_finish_frame", "frame")) return c.GST_FLOW_ERROR;
    const e = encoder;
    const p = priv(e);
    var frame = frame_in;
    var send_headers = false;
    var key_unit = false;
    var discont = frame[0].presentation_frame_number == 0 and frame[0].abidata.ABI.num_subframes == 0;
    const k = klass(e);
    streamLock(e);
    var ret = canPush(e);
    blk: {
        if (ret != c.GST_FLOW_OK) break :blk;
        if (frame[0].abidata.ABI.num_subframes == 0) pushPending(e, frame, false);
        if (frame[0].output_buffer == null) {
            qosDrop(e, frame);
            break :blk;
        }
        p.processed += 1;
        if (frameHas(frame, SYNC_POINT) and p.force_key_unit.head != null) sendKeyUnit(e, frame, &send_headers);
        if (frameHas(frame, SYNC_POINT) and frame[0].abidata.ABI.num_subframes == 0) {
            p.distance_from_sync = 0;
            key_unit = true;
            if (!valid(frame[0].dts)) frame[0].dts = frame[0].pts;
            p.last_key_unit = c.gst_segment_to_running_time(&e[0].output_segment, c.GST_FORMAT_TIME, frame[0].pts);
        }
        inferDts(e, frame);
        frame[0].distance_from_sync = p.distance_from_sync;
        p.distance_from_sync += 1;
        const ob: [*c]Buffer = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(frame[0].output_buffer)));
        frame[0].output_buffer = ob;
        ob[0].pts = frame[0].pts;
        ob[0].dts = frame[0].dts;
        ob[0].duration = frame[0].duration;
        ob[0].mini_object.flags |= c.GST_BUFFER_FLAG_MARKER;
        el.lock(e);
        p.bytes +%= @intCast(c.gst_buffer_get_size(ob));
        if (valid(frame[0].duration)) p.time +%= @bitCast(frame[0].duration) else p.time = -1;
        el.unlock(e);
        if (send_headers) p.new_headers = true;
        sendHeaders(e, &discont, key_unit);
        if (key_unit) ob[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DELTA_UNIT) else ob[0].mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
        if (discont) ob[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        if (k.pre_push) |f| ret = f(e, frame);
        if (ret != c.GST_FLOW_OK) break :blk;
        transformMeta(e, frame);
        const buffer: [*c]Buffer = @ptrCast(c.gst_mini_object_ref(@ptrCast(ob)));
        releaseUnlocked(e, frame);
        frame = null;
        streamUnlock(e);
        ret = c.gst_pad_push(e[0].srcpad, buffer);
        streamLock(e);
    }
    if (frame != null) releaseUnlocked(e, frame);
    streamUnlock(e);
    return ret;
}

pub export fn gst_video_encoder_finish_subframe(encoder: [*c]Enc, frame: [*c]Frame) c.GstFlowReturn {
    const fname = "gst_video_encoder_finish_subframe";
    if (!check.that(frame != null, fname, "frame")) return c.GST_FLOW_ERROR;
    if (!check.that(frame[0].output_buffer != null, fname, "frame->output_buffer")) return c.GST_FLOW_ERROR;
    const e = encoder;
    const p = priv(e);
    var sub: [*c]Buffer = frame[0].output_buffer;
    var send_headers = false;
    var key_unit = false;
    streamLock(e);
    var discont = frame[0].presentation_frame_number == 0 and frame[0].abidata.ABI.num_subframes == 0;
    const k = klass(e);
    var ret = canPush(e);
    if (ret == c.GST_FLOW_OK) {
        if (frameHas(frame, SYNC_POINT) and p.force_key_unit.head != null) sendKeyUnit(e, frame, &send_headers);
        if (frame[0].abidata.ABI.num_subframes == 0) pushPending(e, frame, false);
        if (frameHas(frame, SYNC_POINT) and frame[0].abidata.ABI.num_subframes == 0) {
            p.distance_from_sync = 0;
            key_unit = true;
            if (!valid(frame[0].dts)) frame[0].dts = frame[0].pts;
            p.last_key_unit = c.gst_segment_to_running_time(&e[0].output_segment, c.GST_FORMAT_TIME, frame[0].pts);
        }
        inferDts(e, frame);
        sub = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(sub)));
        sub[0].pts = frame[0].pts;
        sub[0].dts = frame[0].dts;
        sub[0].duration = frame[0].duration;
        el.lock(e);
        p.bytes +%= @intCast(c.gst_buffer_get_size(sub));
        el.unlock(e);
        if (send_headers) p.new_headers = true;
        sendHeaders(e, &discont, key_unit);
        if (key_unit) sub[0].mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DELTA_UNIT) else sub[0].mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
        if (discont) sub[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        if (k.pre_push) |f| ret = f(e, frame);
        transformMeta(e, frame);
        if (ret == c.GST_FLOW_OK) {
            streamUnlock(e);
            ret = c.gst_pad_push(e[0].srcpad, sub);
            sub = null;
            streamLock(e);
        }
    }
    frame[0].abidata.ABI.num_subframes += 1;
    if (sub != null) c.gst_mini_object_unref(@ptrCast(sub));
    frame[0].output_buffer = null;
    streamUnlock(e);
    return ret;
}

pub export fn gst_video_encoder_get_output_state(encoder: [*c]Enc) [*c]State {
    streamLock(encoder);
    defer streamUnlock(encoder);
    const s = priv(encoder).output_state;
    return if (s != null) codec.gst_video_codec_state_ref(s) else null;
}

pub export fn gst_video_encoder_set_output_state(encoder: [*c]Enc, caps: [*c]c.GstCaps, reference: [*c]State) [*c]State {
    if (!check.that(caps != null, "gst_video_encoder_set_output_state", "caps != NULL")) return null;
    const p = priv(encoder);
    const state = newOutputState(caps, reference);
    if (state == null) return null;
    streamLock(encoder);
    if (p.output_state != null) codec.gst_video_codec_state_unref(p.output_state);
    p.output_state = codec.gst_video_codec_state_ref(state);
    if (p.output_state != null and p.output_state[0].info.fps_n > 0) {
        p.qos_frame_duration = c.gst_util_uint64_scale(SEC, @intCast(p.output_state[0].info.fps_d), @intCast(p.output_state[0].info.fps_n));
    } else p.qos_frame_duration = 0;
    p.output_state_changed = true;
    streamUnlock(encoder);
    return state;
}

pub export fn gst_video_encoder_set_latency(encoder: [*c]Enc, min_latency: c.GstClockTime, max_latency: c.GstClockTime) void {
    const fname = "gst_video_encoder_set_latency";
    if (!check.that(valid(min_latency), fname, "GST_CLOCK_TIME_IS_VALID (min_latency)")) return;
    if (!check.that(max_latency >= min_latency, fname, "max_latency >= min_latency")) return;
    const p = priv(encoder);
    var post_msg = false;
    el.lock(encoder);
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
    el.unlock(encoder);
    if (post_msg) _ = c.gst_element_post_message(@ptrCast(encoder), c.gst_message_new_latency(@ptrCast(encoder)));
}

pub export fn gst_video_encoder_get_latency(encoder: [*c]Enc, min_latency: [*c]c.GstClockTime, max_latency: [*c]c.GstClockTime) void {
    el.lock(encoder);
    defer el.unlock(encoder);
    if (min_latency != null) min_latency[0] = @bitCast(priv(encoder).min_latency);
    if (max_latency != null) max_latency[0] = @bitCast(priv(encoder).max_latency);
}

pub export fn gst_video_encoder_get_oldest_frame(encoder: [*c]Enc) [*c]Frame {
    streamLock(encoder);
    defer streamUnlock(encoder);
    const h = priv(encoder).frames.head;
    return if (h != null) codec.gst_video_codec_frame_ref(@ptrCast(@alignCast(h[0].data))) else null;
}

pub export fn gst_video_encoder_get_frame(encoder: [*c]Enc, frame_number: c_int) [*c]Frame {
    streamLock(encoder);
    defer streamUnlock(encoder);
    var g = priv(encoder).frames.head;
    while (g != null) : (g = g[0].next) {
        const tmp: [*c]Frame = @ptrCast(@alignCast(g[0].data));
        if (tmp[0].system_frame_number == @as(u32, @bitCast(frame_number))) return codec.gst_video_codec_frame_ref(tmp);
    }
    return null;
}

pub export fn gst_video_encoder_get_frames(encoder: [*c]Enc) [*c]c.GList {
    streamLock(encoder);
    defer streamUnlock(encoder);
    return c.g_list_copy_deep(priv(encoder).frames.head, refFrame, null);
}

pub export fn gst_video_encoder_merge_tags(encoder: [*c]Enc, tags: ?*const c.GstTagList, mode: c.GstTagMergeMode) void {
    const fname = "gst_video_encoder_merge_tags";
    if (!check.that(isEnc(encoder), fname, "GST_IS_VIDEO_ENCODER (encoder)")) return;
    const is_tags = tags != null and @as(*const c.GstMiniObject, @ptrCast(@alignCast(tags))).type == c.gst_tag_list_get_type();
    if (!check.that(tags == null or is_tags, fname, "tags == NULL || GST_IS_TAG_LIST (tags)")) return;
    if (!check.that(tags == null or mode != c.GST_TAG_MERGE_UNDEFINED, fname, "tags == NULL || mode != GST_TAG_MERGE_UNDEFINED")) return;
    const p = priv(encoder);
    streamLock(encoder);
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
    streamUnlock(encoder);
}

pub export fn gst_video_encoder_get_allocator(encoder: [*c]Enc, allocator: [*c][*c]c.GstAllocator, params: [*c]c.GstAllocationParams) void {
    if (!check.that(isEnc(encoder), "gst_video_encoder_get_allocator", "GST_IS_VIDEO_ENCODER (encoder)")) return;
    const p = priv(encoder);
    if (allocator != null) allocator[0] = if (p.allocator != null) @ptrCast(@alignCast(c.gst_object_ref(p.allocator))) else null;
    if (params != null) params[0] = p.params;
}

pub export fn gst_video_encoder_set_min_pts(encoder: [*c]Enc, min_pts: c.GstClockTime) void {
    if (!check.that(isEnc(encoder), "gst_video_encoder_set_min_pts", "GST_IS_VIDEO_ENCODER (encoder)")) return;
    priv(encoder).min_pts = min_pts;
    priv(encoder).time_adjustment = NONE;
}

pub export fn gst_video_encoder_get_max_encode_time(encoder: [*c]Enc, frame: [*c]Frame) c.GstClockTimeDiff {
    const p = priv(encoder);
    if (@atomicLoad(c.gint, &p.qos_enabled, .seq_cst) == 0) return std.math.maxInt(i64);
    el.lock(encoder);
    defer el.unlock(encoder);
    if (valid(p.earliest_time) and valid(frame[0].deadline)) return @as(i64, @bitCast(frame[0].deadline)) -% @as(i64, @bitCast(p.earliest_time));
    return std.math.maxInt(i64);
}

pub export fn gst_video_encoder_set_qos_enabled(encoder: [*c]Enc, enabled: c.gboolean) void {
    if (!check.that(isEnc(encoder), "gst_video_encoder_set_qos_enabled", "GST_IS_VIDEO_ENCODER (encoder)")) return;
    @atomicStore(c.gint, &priv(encoder).qos_enabled, enabled, .seq_cst);
}

pub export fn gst_video_encoder_is_qos_enabled(encoder: [*c]Enc) c.gboolean {
    if (!check.that(isEnc(encoder), "gst_video_encoder_is_qos_enabled", "GST_IS_VIDEO_ENCODER (encoder)")) return 0;
    return @atomicLoad(c.gint, &priv(encoder).qos_enabled, .seq_cst);
}

pub export fn gst_video_encoder_set_min_force_key_unit_interval(encoder: [*c]Enc, interval: c.GstClockTime) void {
    if (!check.that(isEnc(encoder), "gst_video_encoder_set_min_force_key_unit_interval", "GST_IS_VIDEO_ENCODER (encoder)")) return;
    el.lock(encoder);
    priv(encoder).min_force_key_unit_interval = interval;
    el.unlock(encoder);
}

pub export fn gst_video_encoder_get_min_force_key_unit_interval(encoder: [*c]Enc) c.GstClockTime {
    if (!check.that(isEnc(encoder), "gst_video_encoder_get_min_force_key_unit_interval", "GST_IS_VIDEO_ENCODER (encoder)")) return NONE;
    el.lock(encoder);
    defer el.unlock(encoder);
    return priv(encoder).min_force_key_unit_interval;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    _ = c._gst_debug_category_new("videoencoder", 0, "Base Video Encoder");
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const vc: *Class = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    ec.change_state = changeState;
    vc.sink_event = sinkEventDefault;
    vc.src_event = srcEventDefault;
    vc.propose_allocation = proposeAllocationDefault;
    vc.decide_allocation = decideAllocationDefault;
    vc.negotiate = negotiateDefault;
    vc.sink_query = sinkQueryDefault;
    vc.src_query = srcQueryDefault;
    vc.transform_meta = transformMetaDefault;
    const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_boolean("qos", "Qos", "Handle Quality-of-Service events from downstream", 0, RW));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_uint64("min-force-key-unit-interval", "Minimum Force Keyunit Interval", "Minimum interval between force-keyunit requests in nanoseconds", 0, std.math.maxInt(u64), 0, RW));
    video_tag = c.g_quark_from_static_string("video");
}

fn init(inst: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const e = of(inst);
    e[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    const ec: [*c]c.GstElementClass = @ptrCast(@alignCast(g_class));
    var tmpl = c.gst_element_class_get_pad_template(ec, "sink");
    if (!check.that(tmpl != null, "gst_video_encoder_init", "pad_template != NULL")) return;
    e[0].sinkpad = c.gst_pad_new_from_template(tmpl, "sink");
    c.gst_pad_set_chain_function_full(e[0].sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(e[0].sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(e[0].sinkpad, sinkQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(e), e[0].sinkpad);
    tmpl = c.gst_element_class_get_pad_template(ec, "src");
    if (!check.that(tmpl != null, "gst_video_encoder_init", "pad_template != NULL")) return;
    e[0].srcpad = c.gst_pad_new_from_template(tmpl, "src");
    c.gst_pad_set_query_function_full(e[0].srcpad, srcQuery, null, null);
    c.gst_pad_set_event_function_full(e[0].srcpad, srcEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(e), e[0].srcpad);
    c.gst_segment_init(&e[0].input_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&e[0].output_segment, c.GST_FORMAT_TIME);
    c.g_rec_mutex_init(&e[0].stream_lock);
    const p = priv(e);
    p.headers = null;
    p.new_headers = false;
    c.g_queue_init(&p.frames);
    c.g_queue_init(&p.force_key_unit);
    p.min_latency = 0;
    p.max_latency = 0;
    p.min_pts = NONE;
    p.time_adjustment = NONE;
    reset(e, true);
}

pub export fn gst_video_encoder_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstVideoEncoder", Class, Enc, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            var pi = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_preset_get_type(), &pi);
            return t;
        }
    }.f);
}
