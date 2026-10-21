const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const info = @import("info.zig");
const clip = @import("clip.zig");
const channels = @import("channels.zig");
const utils = @import("utils.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Dec = c.GstAudioDecoder;
const Class = c.GstAudioDecoderClass;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const NONE = el.NONE;
const SEC: u64 = c.GST_SECOND;
const MSEC: i64 = 1_000_000;
const PATH = "../gst-libs/gst/audio/gstaudiodecoder.c";
const MAX_SYNC = 10 * 8 * 2 * 1024;
const INSTANT_FLAGS: c.GstSegmentFlags = c.GST_SEGMENT_FLAG_TRICKMODE | c.GST_SEGMENT_FLAG_TRICKMODE_KEY_UNITS | c.GST_SEGMENT_FLAG_TRICKMODE_NO_AUDIO;

const Context = struct {
    input_caps: [*c]c.GstCaps,
    info: c.GstAudioInfo,
    caps: [*c]c.GstCaps,
    output_format_changed: bool,
    eos: c.gboolean,
    sync: c.gboolean,
    had_output_data: bool,
    had_input_data: bool,
    delay: c.gint,
    do_plc: c.gboolean,
    do_estimate_rate: c.gboolean,
    allocation_caps: [*c]c.GstCaps,
    min_latency: u64,
    max_latency: u64,
    posted_latency_msg: bool,
    allocator: [*c]c.GstAllocator,
    params: c.GstAllocationParams,
};

const Private = struct {
    active: bool,
    base_ts: u64,
    samples: u64,
    adapter: ?*c.GstAdapter,
    prev_ts: u64,
    prev_distance: u64,
    frames: c.GQueue,
    adapter_out: ?*c.GstAdapter,
    out_ts: u64,
    out_dur: u64,
    discont: bool,
    drained: bool,
    force: bool,
    in_out_segment_sync: bool,
    decode_flags_override: bool,
    decode_flags: c.GstSegmentFlags,
    expecting_discont_buf: bool,
    subframe_samples: u64,
    bytes_in: u64,
    samples_out: u64,
    sync_flush: c.guint,
    error_count: c.gint,
    max_errors: c.gint,
    upstream_tags: ?*c.GstTagList,
    taglist: ?*c.GstTagList,
    tags_mode: c.GstTagMergeMode,
    tags_changed: bool,
    agg: c.gint,
    gather: [*c]c.GList,
    decode: [*c]c.GList,
    queued: [*c]c.GList,
    ctx: Context,
    latency: u64,
    tolerance: u64,
    plc: c.gboolean,
    drainable: c.gboolean,
    needs_format: c.gboolean,
    pending_events: [*c]c.GList,
    use_default_pad_acceptcaps: bool,
};

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstElementClass = null;

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
    return gtype.instanceOf(d, gst_audio_decoder_get_type());
}

fn streamLock(d: [*c]Dec) void {
    c.g_rec_mutex_lock(&d.*.stream_lock);
}

fn streamUnlock(d: [*c]Dec) void {
    c.g_rec_mutex_unlock(&d.*.stream_lock);
}

fn infoValid(i: *const c.GstAudioInfo) bool {
    return i.finfo != null and i.rate > 0 and i.channels > 0 and i.bpf > 0;
}

fn framesToTime(frames: u64, rate: c.gint) u64 {
    return c.gst_util_uint64_scale_round(frames, SEC, @intCast(rate));
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn post(d: [*c]Dec, kind: c.GstMessageType, domain: el.Domain, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    el.messageAt(d, kind, domain, code, text, debug, PATH, func, line, null);
}

fn unrefBuffer(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(data)));
}

fn freeList(l: *[*c]c.GList) void {
    c.g_list_foreach(l.*, unrefBuffer, null);
    c.g_list_free(l.*);
    l.* = null;
}

fn clearQueues(d: [*c]Dec) void {
    const r = priv(d);
    freeList(&r.queued);
    freeList(&r.gather);
    freeList(&r.decode);
}

fn clearFrames(r: *Private) void {
    c.g_queue_foreach(&r.frames, unrefBuffer, null);
    c.g_queue_clear(&r.frames);
}

fn reset(d: [*c]Dec, full: bool) void {
    const r = priv(d);
    streamLock(d);
    if (full) {
        r.active = false;
        el.lock(d);
        r.bytes_in = 0;
        r.samples_out = 0;
        el.unlock(d);
        r.agg = -1;
        r.error_count = 0;
        clearQueues(d);
        if (r.taglist) |t| c.gst_mini_object_unref(@ptrCast(t));
        r.taglist = null;
        r.tags_mode = c.GST_TAG_MERGE_KEEP_ALL;
        if (r.upstream_tags) |t| c.gst_mini_object_unref(@ptrCast(t));
        r.upstream_tags = null;
        r.tags_changed = false;
        c.gst_segment_init(&d.*.input_segment, c.GST_FORMAT_TIME);
        c.gst_segment_init(&d.*.output_segment, c.GST_FORMAT_TIME);
        r.in_out_segment_sync = true;
        c.g_list_foreach(r.pending_events, unrefBuffer, null);
        c.g_list_free(r.pending_events);
        r.pending_events = null;
        if (r.ctx.allocator != null) c.gst_object_unref(r.ctx.allocator);
        el.lock(d);
        r.decode_flags_override = false;
        _ = c.gst_caps_replace(&r.ctx.input_caps, null);
        _ = c.gst_caps_replace(&r.ctx.caps, null);
        _ = c.gst_caps_replace(&r.ctx.allocation_caps, null);
        r.ctx = std.mem.zeroes(Context);
        info.gst_audio_info_init(&r.ctx.info);
        el.unlock(d);
    }
    clearFrames(r);
    c.gst_adapter_clear(r.adapter);
    c.gst_adapter_clear(r.adapter_out);
    r.out_ts = NONE;
    r.out_dur = 0;
    r.prev_ts = NONE;
    r.prev_distance = 0;
    r.drained = true;
    r.base_ts = NONE;
    r.samples = 0;
    r.discont = true;
    r.sync_flush = 0;
    streamUnlock(d);
}

fn mergedTags(d: [*c]Dec) [*c]Event {
    const r = priv(d);
    const merged = c.gst_tag_list_merge(r.upstream_tags, r.taglist, r.tags_mode);
    if (merged == null) return null;
    if (c.gst_tag_list_is_empty(merged) != 0) {
        c.gst_mini_object_unref(@ptrCast(merged));
        return null;
    }
    return c.gst_event_new_tag(merged);
}

fn setOutputSegment(d: [*c]Dec, e: [*c]Event) void {
    var seg: c.GstSegment = undefined;
    streamLock(d);
    c.gst_event_copy_segment(e, &seg);
    d.*.output_segment = seg;
    priv(d).in_out_segment_sync = c.gst_segment_is_equal(&d.*.input_segment, &seg) != 0;
    streamUnlock(d);
}

fn pushEvent(d: [*c]Dec, e: [*c]Event) c.gboolean {
    if (e.*.type == c.GST_EVENT_SEGMENT) setOutputSegment(d, e);
    return c.gst_pad_push_event(d.*.srcpad, e);
}

fn negotiateDefault(d: [*c]Dec) callconv(.c) c.gboolean {
    const fname = "gst_audio_decoder_negotiate_default";
    if (!check.that(isDec(d), fname, "GST_IS_AUDIO_DECODER (dec)")) return 0;
    const r = priv(d);
    if (!check.that(infoValid(&r.ctx.info), fname, "GST_AUDIO_INFO_IS_VALID (&dec->priv->ctx.info)")) return 0;
    if (!check.that(r.ctx.caps != null and r.ctx.caps.*.mini_object.type == c.gst_caps_get_type(), fname, "GST_IS_CAPS (dec->priv->ctx.caps)")) return 0;
    const caps = r.ctx.caps;
    if (r.ctx.allocation_caps == null) r.ctx.allocation_caps = c.gst_caps_ref(caps);
    var l = r.pending_events;
    while (l != null) {
        const e: [*c]Event = @ptrCast(@alignCast(l.*.data));
        if (e.*.type < c.GST_EVENT_CAPS) {
            _ = pushEvent(d, e);
            const tmp = l;
            l = l.*.next;
            r.pending_events = c.g_list_delete_link(r.pending_events, tmp);
        } else l = l.*.next;
    }
    var res: c.gboolean = 1;
    const prev = c.gst_pad_get_current_caps(d.*.srcpad);
    if (prev == null or c.gst_caps_is_equal(prev, caps) == 0) res = @intFromBool(el.padSetCaps(d.*.srcpad, caps));
    if (prev != null) c.gst_caps_unref(prev);
    if (res == 0) return 0;
    r.ctx.output_format_changed = false;
    const q = c.gst_query_new_allocation(r.ctx.allocation_caps, 1);
    defer c.gst_query_unref(q);
    _ = c.gst_pad_peer_query(d.*.srcpad, q);
    res = klass(d).decide_allocation.?(d, q);
    if (res == 0) return 0;
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_query_get_n_allocation_params(q) > 0) c.gst_query_parse_nth_allocation_param(q, 0, &allocator, &params) else c.gst_allocation_params_init(&params);
    if (r.ctx.allocator != null) c.gst_object_unref(r.ctx.allocator);
    r.ctx.allocator = allocator;
    r.ctx.params = params;
    return res;
}

fn negotiateUnlocked(d: [*c]Dec) bool {
    return if (klass(d).negotiate) |f| f(d) != 0 else true;
}

pub export fn gst_audio_decoder_negotiate(d: [*c]Dec) c.gboolean {
    if (!check.that(isDec(d), "gst_audio_decoder_negotiate", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    var res: c.gboolean = 1;
    streamLock(d);
    _ = c.gst_pad_check_reconfigure(d.*.srcpad);
    if (klass(d).negotiate) |f| {
        res = f(d);
        if (res == 0) c.gst_pad_mark_reconfigure(d.*.srcpad);
    }
    streamUnlock(d);
    return res;
}

pub export fn gst_audio_decoder_set_output_format(d: [*c]Dec, ai: [*c]const c.GstAudioInfo) c.gboolean {
    if (!check.that(isDec(d), "gst_audio_decoder_set_output_format", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    if (!check.that(ai != null and infoValid(ai), "gst_audio_decoder_set_output_format", "GST_AUDIO_INFO_IS_VALID (info)")) return 0;
    const caps = info.gst_audio_info_to_caps(ai);
    if (caps == null) return 0;
    const res = gst_audio_decoder_set_output_caps(d, caps);
    c.gst_caps_unref(caps);
    return res;
}

pub export fn gst_audio_decoder_set_output_caps(d: [*c]Dec, caps: [*c]c.GstCaps) c.gboolean {
    if (!check.that(isDec(d), "gst_audio_decoder_set_output_caps", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    const r = priv(d);
    streamLock(d);
    defer streamUnlock(d);
    if (c.gst_caps_is_fixed(caps) == 0) return 0;
    var ai: c.GstAudioInfo = undefined;
    if (info.gst_audio_info_from_caps(&ai, caps) == 0) return 0;
    const templ = c.gst_pad_get_pad_template_caps(d.*.srcpad);
    const subset = c.gst_caps_is_subset(caps, templ);
    c.gst_caps_unref(templ);
    if (subset == 0) return 0;
    const old_rate = r.ctx.info.rate;
    if (r.base_ts != NONE and old_rate != 0) {
        r.base_ts +%= framesToTime(r.samples, old_rate);
        r.samples = 0;
    }
    el.lock(d);
    r.ctx.info = ai;
    el.unlock(d);
    _ = c.gst_caps_replace(&r.ctx.caps, caps);
    r.ctx.output_format_changed = true;
    return 1;
}

fn sinkSetcaps(d: [*c]Dec, caps: [*c]c.GstCaps) c.gboolean {
    const r = priv(d);
    streamLock(d);
    defer streamUnlock(d);
    if (r.ctx.input_caps != null and c.gst_caps_is_equal(r.ctx.input_caps, caps) != 0) return 1;
    var res: c.gboolean = 1;
    if (klass(d).set_format) |f| res = f(d, caps);
    if (res != 0) _ = c.gst_caps_replace(&r.ctx.input_caps, caps);
    return res;
}

fn setup(d: [*c]Dec) void {
    const q = c.gst_query_new_latency();
    var res = c.gst_pad_peer_query(d.*.sinkpad, q);
    if (res != 0) {
        c.gst_query_parse_latency(q, &res, null, null);
        res = @intFromBool(res == 0);
    }
    c.gst_query_unref(q);
    priv(d).agg = @intFromBool(res != 0);
}

fn pushForward(d: [*c]Dec, buf_in: [*c]Buffer) c.GstFlowReturn {
    const r = priv(d);
    if (!check.that(r.ctx.info.bpf != 0, "gst_audio_decoder_push_forward", "ctx->info.bpf != 0")) return c.GST_FLOW_ERROR;
    r.ctx.had_output_data = true;
    const ts = buf_in.*.pts;
    var buf = clip.gst_audio_buffer_clip(buf_in, &d.*.output_segment, r.ctx.info.rate, r.ctx.info.bpf);
    if (buf == null) {
        if (r.in_out_segment_sync) {
            if (d.*.output_segment.rate >= 0) {
                if (ts >= d.*.output_segment.stop) return c.GST_FLOW_EOS;
            } else if (ts < d.*.output_segment.start) return c.GST_FLOW_EOS;
        }
        return c.GST_FLOW_OK;
    }
    if (r.discont) {
        buf.*.mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        r.discont = false;
    }
    if (buf.*.pts != NONE) d.*.output_segment.position = buf.*.pts +% buf.*.duration;
    if (klass(d).pre_push) |f| {
        const ret = f(d, &buf);
        if (ret != c.GST_FLOW_OK or buf == null) {
            if (buf != null) c.gst_mini_object_unref(@ptrCast(buf));
            return ret;
        }
    }
    return c.gst_pad_push(d.*.srcpad, buf);
}

fn output(d: [*c]Dec, buf_in: [*c]Buffer) c.GstFlowReturn {
    const r = priv(d);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (r.agg < 0) setup(d);
    var buf = buf_in;
    while (true) {
        var inbuf: [*c]Buffer = null;
        if (r.agg != 0 and r.latency > 0 and r.ctx.info.layout == c.GST_AUDIO_LAYOUT_INTERLEAVED) {
            var av = c.gst_adapter_available(r.adapter_out);
            var assemble = false;
            const tol: i64 = 10 * MSEC;
            var dt: i64 = -100 * MSEC;
            if (buf == null) {
                assemble = true;
            } else if (av != 0 and (buf.*.pts == NONE or r.out_ts == NONE or blk: {
                dt = diff(buf.*.pts, r.out_ts +% r.out_dur);
                break :blk dt > tol;
            } or dt < -tol)) {
                assemble = true;
            } else {
                if (av == 0) r.out_ts = buf.*.pts;
                c.gst_adapter_push(r.adapter_out, buf);
                r.out_dur +%= buf.*.duration;
                av += c.gst_buffer_get_size(buf);
                buf = null;
            }
            if (r.out_dur > r.latency) assemble = true;
            if (av != 0 and assemble) {
                inbuf = buf;
                buf = c.gst_adapter_take_buffer(r.adapter_out, av);
                buf.*.pts = r.out_ts;
                buf.*.duration = r.out_dur;
                r.out_ts = NONE;
                r.out_dur = 0;
            }
        }
        if (buf == null) break;
        if (d.*.output_segment.rate > 0.0) {
            ret = pushForward(d, buf);
        } else {
            ret = c.GST_FLOW_OK;
            r.queued = c.g_list_prepend(r.queued, buf);
        }
        if (inbuf == null) break;
        buf = inbuf;
    }
    return ret;
}

fn sendPendingEvents(d: [*c]Dec) void {
    const r = priv(d);
    const list = r.pending_events;
    r.pending_events = null;
    var l = list;
    while (l != null) : (l = l.*.next) _ = pushEvent(d, @ptrCast(@alignCast(l.*.data)));
    c.g_list_free(list);
}

fn applyPendingEvents(d: [*c]Dec) void {
    var l = priv(d).pending_events;
    while (l != null) : (l = l.*.next) {
        const e: [*c]Event = @ptrCast(@alignCast(l.*.data));
        if (e.*.type == c.GST_EVENT_SEGMENT) setOutputSegment(d, e);
    }
}

fn checkReconfigure(d: [*c]Dec) c.GstFlowReturn {
    const r = priv(d);
    const needs = c.gst_pad_check_reconfigure(d.*.srcpad) != 0;
    if (r.ctx.output_format_changed or (infoValid(&r.ctx.info) and needs)) {
        if (!negotiateUnlocked(d)) {
            c.gst_pad_mark_reconfigure(d.*.srcpad);
            return if (el.flags(d.*.srcpad) & c.GST_PAD_FLAG_FLUSHING != 0) c.GST_FLOW_FLUSHING else c.GST_FLOW_NOT_NEGOTIATED;
        }
    }
    return c.GST_FLOW_OK;
}

fn transformMetaDefault(_: [*c]Dec, _: [*c]Buffer, meta: [*c]c.GstMeta, _: [*c]Buffer) callconv(.c) c.gboolean {
    var tags = c.gst_meta_api_type_get_tags(meta.*.info.*.api);
    if (tags == null) return 1;
    while (tags.* != null) : (tags += 1) {
        const t = std.mem.span(tags.*);
        if (!std.mem.eql(u8, t, "audio") and !std.mem.eql(u8, t, "channels")) return 0;
    }
    return 1;
}

const CopyMeta = struct { dec: [*c]Dec, out: [*c]Buffer };

fn copyMeta(inbuf: [*c]Buffer, meta: [*c][*c]c.GstMeta, data: c.gpointer) callconv(.c) c.gboolean {
    const cm: *CopyMeta = @ptrCast(@alignCast(data));
    const mi = meta.*.*.info;
    var copy = false;
    if (c.gst_meta_api_type_has_tag(mi.*.api, c._gst_meta_tag_memory) != 0 or c.gst_meta_api_type_has_tag(mi.*.api, c._gst_meta_tag_memory_reference) != 0) {
        copy = false;
    } else if (klass(cm.dec).transform_meta) |f| {
        copy = f(cm.dec, cm.out, meta.*, inbuf) != 0;
    }
    if (copy) if (mi.*.transform_func) |tf| {
        var cd = c.GstMetaTransformCopy{ .region = 0, .offset = 0, .size = std.math.maxInt(c.gsize) };
        _ = tf(cm.out, meta.*, inbuf, c._gst_meta_transform_copy, &cd);
    };
    return 1;
}

pub export fn gst_audio_decoder_finish_subframe(d: [*c]Dec, buf: [*c]Buffer) c.GstFlowReturn {
    if (!check.that(isDec(d), "gst_audio_decoder_finish_subframe", "GST_IS_AUDIO_DECODER (dec)")) return c.GST_FLOW_ERROR;
    return if (buf == null) finishFrame(d, null, 1) else finishFrame(d, buf, 0);
}

pub export fn gst_audio_decoder_finish_frame(d: [*c]Dec, buf: [*c]Buffer, frames: c.gint) c.GstFlowReturn {
    if (!check.that(isDec(d), "gst_audio_decoder_finish_frame", "GST_IS_AUDIO_DECODER (dec)")) return c.GST_FLOW_ERROR;
    if (!check.that(frames != 0, "gst_audio_decoder_finish_frame", "frames != 0")) return c.GST_FLOW_ERROR;
    return finishFrame(d, buf, frames);
}

fn finishFrame(d: [*c]Dec, buf_in: [*c]Buffer, frames_in: c.gint) c.GstFlowReturn {
    const fname = "gst_audio_decoder_finish_frame_or_subframe";
    const r = priv(d);
    const ctx = &r.ctx;
    var buf = buf_in;
    var frames = frames_in;
    const subframe = frames == 0;
    if (!check.that(buf == null or c.gst_buffer_get_size(buf) > 0, fname, "buf == NULL || gst_buffer_get_size (buf) > 0")) return c.GST_FLOW_ERROR;
    const meta: [*c]c.GstAudioMeta = if (buf != null) @ptrCast(@alignCast(c.gst_buffer_get_meta(buf, c.gst_audio_meta_api_get_type()))) else null;
    const size: u64 = if (buf != null) c.gst_buffer_get_size(buf) else 0;
    const samples: u64 = if (buf == null) 0 else if (meta != null) meta.*.samples else size / @as(u64, @intCast(ctx.info.bpf));
    if (!check.that(buf == null or infoValid(&ctx.info), fname, "buf == NULL || GST_AUDIO_INFO_IS_VALID (&ctx->info)")) return c.GST_FLOW_ERROR;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var inbufs = std.mem.zeroes(c.GQueue);
    streamLock(d);
    body: {
        if (buf != null and r.subframe_samples == 0) {
            ret = checkReconfigure(d);
            if (ret == c.GST_FLOW_FLUSHING or ret == c.GST_FLOW_NOT_NEGOTIATED) {
                c.gst_mini_object_unref(@ptrCast(buf));
                break :body;
            }
            if (r.pending_events != null) sendPendingEvents(d);
        }
        if (buf != null and ctx.info.bpf != 0) {
            const bpf: u64 = @intCast(ctx.info.bpf);
            if (meta == null or meta.*.info.layout == c.GST_AUDIO_LAYOUT_INTERLEAVED) {
                if (size % bpf != 0) {
                    post(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("buffer size %lu not a multiple of %d", size, ctx.info.bpf), fname, 1587);
                    c.gst_mini_object_unref(@ptrCast(buf));
                    ret = c.GST_FLOW_ERROR;
                    break :body;
                }
                if (samples != size / bpf) {
                    wrongSamples(d, meta, size / bpf, buf);
                    ret = c.GST_FLOW_ERROR;
                    break :body;
                }
            } else if (samples > size / bpf) {
                wrongSamples(d, meta, size / bpf, buf);
                ret = c.GST_FLOW_ERROR;
                break :body;
            }
        }
        const pending: c.gint = @intCast(r.frames.length);
        if (frames < 0) {
            if (-frames - 1 > pending) {
                post(d, c.GST_MESSAGE_WARNING, .stream, c.GST_STREAM_ERROR_DECODE, c.g_strdup_printf("received more decoded frames %d than provided %d", frames, pending), null, fname, 1411);
                frames = 0;
            } else frames = pending + frames + 1;
        } else if (frames > pending) {
            if (!r.force) post(d, c.GST_MESSAGE_WARNING, .stream, c.GST_STREAM_ERROR_DECODE, c.g_strdup_printf("received more decoded frames %d than provided %d", frames, pending), null, fname, 1420);
            frames = pending;
        }
        if (buf != null) buf = c.gst_buffer_make_writable(buf);
        var ts: u64 = NONE;
        if (r.frames.length != 0) {
            const head: [*c]Buffer = @ptrCast(@alignCast(r.frames.head.*.data));
            ts = head.*.pts;
            if (buf != null) {
                if (head.*.mini_object.flags & c.GST_BUFFER_FLAG_RESYNC != 0) buf.*.mini_object.flags |= c.GST_BUFFER_FLAG_RESYNC;
                if (subframe) {
                    const w = c.gst_buffer_make_writable(head);
                    r.frames.head.*.data = w;
                    w.*.mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_RESYNC);
                }
            }
        }
        if (subframe and r.frames.length == 0) {
            post(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("Received decoded subframe, but no pending frame"), fname, 1608);
            c.gst_mini_object_unref(@ptrCast(buf));
            ret = c.GST_FLOW_ERROR;
            break :body;
        }
        while (r.frames.length != 0 and frames != 0) {
            c.g_queue_push_tail(&inbufs, c.g_queue_pop_head(&r.frames));
            ctx.delay = @intCast(r.frames.length);
            frames -= 1;
        }
        if (buf == null) break :body;
        if (r.base_ts == NONE) r.base_ts = ts;
        if (r.base_ts == NONE and d.*.output_segment.rate > 0.0) r.base_ts = d.*.output_segment.start;
        const resync = !subframe or r.subframe_samples == 0;
        if (resync and ts != NONE) {
            if (r.tolerance > 0) {
                const next = r.base_ts +% c.gst_util_uint64_scale(r.samples, SEC, @intCast(ctx.info.rate));
                const dt = diff(next, ts);
                const tol: i64 = @bitCast(r.tolerance);
                if (dt < -tol or dt > tol or buf.*.mini_object.flags & c.GST_BUFFER_FLAG_RESYNC != 0) {
                    r.base_ts = ts;
                    r.samples = 0;
                }
            } else {
                r.base_ts = ts;
                r.samples = 0;
            }
        }
        if (r.taglist != null and r.tags_changed) {
            const e = mergedTags(d);
            if (e != null) _ = pushEvent(d, e);
            r.tags_changed = false;
        }
        if (r.base_ts != NONE) {
            buf.*.pts = r.base_ts +% framesToTime(r.samples, ctx.info.rate);
            buf.*.duration = r.base_ts +% framesToTime(r.samples + samples, ctx.info.rate) -% buf.*.pts;
        } else {
            buf.*.pts = NONE;
            buf.*.duration = framesToTime(samples, ctx.info.rate);
        }
        if (klass(d).transform_meta != null) {
            var cm = CopyMeta{ .dec = d, .out = buf };
            if (inbufs.length != 0) {
                var l = inbufs.head;
                while (l != null) : (l = l.*.next) _ = c.gst_buffer_foreach_meta(@ptrCast(@alignCast(l.*.data)), copyMeta, &cm);
            } else if (subframe) {
                _ = c.gst_buffer_foreach_meta(@ptrCast(@alignCast(c.g_queue_peek_head(&r.frames))), copyMeta, &cm);
            }
        }
        el.lock(d);
        r.samples +%= samples;
        r.samples_out +%= samples;
        el.unlock(d);
        r.error_count = 0;
        ret = output(d, buf);
    }
    c.g_queue_foreach(&inbufs, unrefBuffer, null);
    c.g_queue_clear(&inbufs);
    if (subframe) r.subframe_samples +%= samples else r.subframe_samples = 0;
    streamUnlock(d);
    return ret;
}

fn wrongSamples(d: [*c]Dec, meta: [*c]c.GstAudioMeta, expect: u64, buf: [*c]Buffer) void {
    post(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("GstAudioMeta samples (%lu) are inconsistent with the buffer size and layout (size/bpf = %lu)", meta.*.samples, expect), "gst_audio_decoder_finish_frame_or_subframe", 1597);
    c.gst_mini_object_unref(@ptrCast(buf));
}

fn handleFrame(d: [*c]Dec, k: *Class, buffer: [*c]Buffer) c.GstFlowReturn {
    const r = priv(d);
    if (d.*.input_segment.rate > 0.0 and d.*.input_segment.flags & c.GST_SEGMENT_FLAG_TRICKMODE_NO_AUDIO != 0 and buffer != null) {
        const ts = buffer.*.pts;
        if (ts != NONE) {
            const e = c.gst_event_new_gap(ts, buffer.*.duration);
            c.gst_mini_object_unref(@ptrCast(buffer));
            _ = handleGap(d, e);
            return c.GST_FLOW_OK;
        }
    }
    if (buffer != null) {
        const size = c.gst_buffer_get_size(buffer);
        c.g_queue_push_tail(&r.frames, buffer);
        r.ctx.delay = @intCast(r.frames.length);
        el.lock(d);
        r.bytes_in +%= size;
        el.unlock(d);
    }
    return k.handle_frame.?(d, buffer);
}

fn pushBuffers(d: [*c]Dec, force: bool) c.GstFlowReturn {
    const k = klass(d);
    const r = priv(d);
    if (!check.that(k.handle_frame != null, "gst_audio_decoder_push_buffers", "klass->handle_frame != NULL")) return c.GST_FLOW_ERROR;
    var av: c.gint = @intCast(c.gst_adapter_available(r.adapter));
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    while (ret == c.GST_FLOW_OK) {
        var flush: c.gint = 0;
        r.ctx.eos = @intFromBool(force);
        var buffer: [*c]Buffer = null;
        if (av != 0) {
            var len: c.gint = av;
            if (k.parse) |parse| {
                var off: c.gint = 0;
                r.ctx.sync = @intFromBool(!r.discont);
                ret = parse(d, r.adapter, &off, &len);
                if (off != 0) {
                    c.gst_adapter_flush(r.adapter, @intCast(off));
                    flush = off;
                    r.sync_flush +%= @intCast(off);
                    if (r.sync_flush > MAX_SYNC) {
                        post(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("failed to parse stream"), "gst_audio_decoder_push_buffers", 1772);
                        return c.GST_FLOW_ERROR;
                    }
                }
                if (ret == c.GST_FLOW_EOS) {
                    ret = c.GST_FLOW_OK;
                    break;
                } else if (ret == c.GST_FLOW_OK) {
                    r.sync_flush = 0;
                } else break;
            }
            var distance: u64 = 0;
            var ts = c.gst_adapter_prev_pts(r.adapter, &distance);
            if (ts != r.prev_ts or distance <= r.prev_distance) {
                r.prev_ts = ts;
                r.prev_distance = distance;
            } else ts = NONE;
            buffer = c.gst_adapter_take_buffer(r.adapter, @intCast(len));
            buffer = c.gst_buffer_make_writable(buffer);
            buffer.*.pts = ts;
            flush += len;
            r.force = false;
        } else {
            if (!force) break;
            if (r.drainable == 0) {
                r.drained = true;
                break;
            }
            r.force = true;
        }
        ret = handleFrame(d, k, buffer);
        if (av == 0) {
            r.drained = true;
            break;
        }
        av -= flush;
    }
    return ret;
}

fn drain(d: [*c]Dec) c.GstFlowReturn {
    const r = priv(d);
    if (r.drained and r.gather == null) return c.GST_FLOW_OK;
    applyPendingEvents(d);
    if (d.*.output_segment.rate < 0.0 and r.gather != null) _ = chainReverse(d, null);
    var ret = pushBuffers(d, true);
    if (ret == c.GST_FLOW_OK) ret = output(d, null);
    if (r.frames.length != 0) clearFrames(r);
    c.gst_adapter_clear(r.adapter);
    return ret;
}

fn flushDec(d: [*c]Dec, hard: bool) c.GstFlowReturn {
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (!hard) {
        ret = drain(d);
    } else {
        clearQueues(d);
        c.gst_segment_init(&d.*.input_segment, c.GST_FORMAT_TIME);
        c.gst_segment_init(&d.*.output_segment, c.GST_FORMAT_TIME);
        priv(d).error_count = 0;
    }
    if (klass(d).flush) |f| if (priv(d).samples_out > 0) f(d, @intFromBool(hard));
    reset(d, false);
    return ret;
}

fn chainForward(d: [*c]Dec, buffer: [*c]Buffer) c.GstFlowReturn {
    if (c.gst_buffer_get_size(buffer) == 0) {
        c.gst_mini_object_unref(@ptrCast(buffer));
        return c.GST_FLOW_OK;
    }
    c.gst_adapter_push(priv(d).adapter, buffer);
    priv(d).drained = false;
    return pushBuffers(d, false);
}

fn flushDecode(d: [*c]Dec) c.GstFlowReturn {
    const r = priv(d);
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    var walk = r.decode;
    _ = flushDec(d, false);
    while (walk != null) {
        const next = walk.*.next;
        const buf: [*c]Buffer = @ptrCast(@alignCast(walk.*.data));
        _ = c.gst_mini_object_ref(@ptrCast(buf));
        res = chainForward(d, buf);
        if (r.queued != null) {
            r.decode = c.g_list_delete_link(r.decode, walk);
            c.gst_mini_object_unref(@ptrCast(buf));
        }
        walk = next;
    }
    _ = drain(d);
    var ts: u64 = NONE;
    while (r.queued != null) {
        var buf: [*c]Buffer = @ptrCast(@alignCast(r.queued.*.data));
        const duration = buf.*.duration;
        if (ts != NONE) ts = if (ts > duration) ts - duration else 0;
        if (buf.*.pts == NONE) buf.*.pts = ts else ts = buf.*.pts;
        if (res == c.GST_FLOW_OK) {
            buf = c.gst_buffer_make_writable(buf);
            buf.*.mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DISCONT);
            res = pushForward(d, buf);
        } else c.gst_mini_object_unref(@ptrCast(buf));
        r.queued = c.g_list_delete_link(r.queued, r.queued);
    }
    return res;
}

fn chainReverse(d: [*c]Dec, buf: [*c]Buffer) c.GstFlowReturn {
    const r = priv(d);
    if (buf == null or buf.*.mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) {
        while (r.gather != null) {
            const g = r.gather.*.data;
            r.gather = c.g_list_delete_link(r.gather, r.gather);
            r.decode = c.g_list_prepend(r.decode, g);
        }
        _ = flushDecode(d);
    }
    if (buf != null) r.gather = c.g_list_prepend(r.gather, buf);
    return c.GST_FLOW_OK;
}

fn chain(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, buffer: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const d = of(parent_obj);
    const r = priv(d);
    streamLock(d);
    if (r.ctx.input_caps == null and r.needs_format != 0) {
        streamUnlock(d);
        post(d, c.GST_MESSAGE_ERROR, .core, c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("decoder not initialized"), "gst_audio_decoder_chain", 2139);
        c.gst_mini_object_unref(@ptrCast(buffer));
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    r.ctx.had_input_data = true;
    if (!r.expecting_discont_buf and buffer.*.mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) {
        const ts = r.base_ts;
        const samples = r.samples;
        _ = flushDec(d, false);
        r.discont = true;
        if (d.*.input_segment.rate > 0.0 and buffer.*.pts == NONE) {
            r.base_ts = ts;
            r.samples = samples;
        }
    }
    r.expecting_discont_buf = false;
    const ret = if (d.*.input_segment.rate > 0.0) chainForward(d, buffer) else chainReverse(d, buffer);
    streamUnlock(d);
    return ret;
}

fn doByte(d: [*c]Dec) bool {
    const r = priv(d);
    el.lock(d);
    defer el.unlock(d);
    return r.ctx.do_estimate_rate != 0 and r.ctx.info.bpf != 0 and @as(u64, @intCast(r.ctx.info.rate)) <= r.samples_out;
}

fn negotiateDefaultCaps(d: [*c]Dec) bool {
    const r = priv(d);
    var templ = c.gst_pad_get_pad_template_caps(d.*.srcpad);
    var caps = c.gst_pad_peer_query_caps(d.*.srcpad, templ);
    if (caps != null) c.gst_caps_unref(templ) else caps = templ;
    templ = null;
    if (caps == null or c.gst_caps_is_empty(caps) != 0 or c.gst_caps_is_any(caps) != 0) {
        if (caps != null) c.gst_caps_unref(caps);
        return false;
    }
    caps = c.gst_caps_make_writable(caps);
    const n = c.gst_caps_get_size(caps);
    var rate: c.gint = 0;
    var chans: c.gint = 0;
    var mask: u64 = 0;
    if (r.ctx.input_caps != null) {
        const s = c.gst_caps_get_structure(r.ctx.input_caps, 0);
        if (c.gst_structure_get_int(s, "rate", &rate) != 0) {
            var i: c.guint = 0;
            while (i < n) : (i += 1) c.gst_structure_set(c.gst_caps_get_structure(caps, i), "rate", c.G_TYPE_INT, rate, @as(?*anyopaque, null));
        }
        if (c.gst_structure_get_int(s, "channels", &chans) != 0) {
            var i: c.guint = 0;
            while (i < n) : (i += 1) c.gst_structure_set(c.gst_caps_get_structure(caps, i), "channels", c.G_TYPE_INT, chans, @as(?*anyopaque, null));
        }
        if (c.gst_structure_get(s, "channel-mask", c.gst_bitmask_get_type(), &mask, @as(?*anyopaque, null)) != 0) {
            var i: c.guint = 0;
            while (i < n) : (i += 1) c.gst_structure_set(c.gst_caps_get_structure(caps, i), "channel-mask", c.gst_bitmask_get_type(), mask, @as(?*anyopaque, null));
        }
    }
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const s = c.gst_caps_get_structure(caps, i);
        if (c.gst_structure_has_field(s, "channels") != 0) _ = c.gst_structure_fixate_field_nearest_int(s, "channels", 2) else c.gst_structure_set(s, "channels", c.G_TYPE_INT, @as(c.gint, 2), @as(?*anyopaque, null));
        if (c.gst_structure_has_field(s, "rate") != 0) _ = c.gst_structure_fixate_field_nearest_int(s, "rate", 44100) else c.gst_structure_set(s, "rate", c.G_TYPE_INT, @as(c.gint, 44100), @as(?*anyopaque, null));
    }
    caps = c.gst_caps_fixate(caps);
    const s = c.gst_caps_get_structure(caps, 0);
    _ = c.gst_structure_get_int(s, "channels", &chans);
    if (chans > 2 and c.gst_structure_has_field(s, "channel-mask") == 0) {
        mask = channels.gst_audio_channel_get_fallback_mask(chans);
        if (mask != 0) c.gst_structure_set(s, "channel-mask", c.gst_bitmask_get_type(), mask, @as(?*anyopaque, null));
    }
    var ai: c.GstAudioInfo = undefined;
    if (caps == null or info.gst_audio_info_from_caps(&ai, caps) == 0) {
        if (caps != null) c.gst_caps_unref(caps);
        return false;
    }
    el.lock(d);
    r.ctx.info = ai;
    r.ctx.caps = caps;
    el.unlock(d);
    return true;
}

fn handleGap(d: [*c]Dec, e: [*c]Event) c.gboolean {
    const r = priv(d);
    var needs = false;
    streamLock(d);
    if (!infoValid(&r.ctx.info)) {
        if (!negotiateDefaultCaps(d)) {
            streamUnlock(d);
            post(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup("Decoder output not negotiated before GAP event."), "gst_audio_decoder_handle_gap", 2281);
            c.gst_mini_object_unref(@ptrCast(e));
            return 0;
        }
        needs = true;
    }
    needs = c.gst_pad_check_reconfigure(d.*.srcpad) != 0 or needs;
    if (r.ctx.output_format_changed or needs) {
        if (!negotiateUnlocked(d)) c.gst_pad_mark_reconfigure(d.*.srcpad);
    }
    streamUnlock(d);
    var ts: u64 = 0;
    var dur: u64 = 0;
    c.gst_event_parse_gap(e, &ts, &dur);
    if (r.plc != 0 and r.ctx.do_plc != 0 and d.*.input_segment.rate > 0.0) {
        const buf = c.gst_buffer_new();
        buf.*.pts = ts;
        buf.*.duration = dur;
        _ = handleFrame(d, klass(d), buf);
        r.expecting_discont_buf = true;
        c.gst_mini_object_unref(@ptrCast(e));
        return 1;
    }
    if (checkReconfigure(d) != c.GST_FLOW_OK) {
        c.gst_mini_object_unref(@ptrCast(e));
        return 0;
    }
    if (r.subframe_samples == 0) {
        sendPendingEvents(d);
        return pushEvent(d, e);
    }
    r.pending_events = c.g_list_append(r.pending_events, e);
    c.gst_mini_object_unref(@ptrCast(e));
    return 1;
}

fn flushEvents(pad: ?*c.GstPad, events: [*c]c.GList) [*c]c.GList {
    var l = events;
    while (l != null) : (l = l.*.next) {
        const e: [*c]Event = @ptrCast(@alignCast(l.*.data));
        if (e.*.type != c.GST_EVENT_EOS and e.*.type != c.GST_EVENT_SEGMENT and e.*.type & c.GST_EVENT_TYPE_STICKY != 0) _ = c.gst_pad_store_sticky_event(pad, e);
        c.gst_mini_object_unref(@ptrCast(e));
    }
    c.g_list_free(events);
    return null;
}

fn sinkEventDefault(d: [*c]Dec, e_in: [*c]Event) callconv(.c) c.gboolean {
    const r = priv(d);
    var e = e_in;
    switch (e.*.type) {
        c.GST_EVENT_STREAM_START => {
            streamLock(d);
            _ = drain(d);
            _ = flushDec(d, false);
            if (r.upstream_tags) |t| {
                c.gst_mini_object_unref(@ptrCast(t));
                r.upstream_tags = null;
                r.tags_changed = true;
            }
            streamUnlock(d);
            return pushEvent(d, e);
        },
        c.GST_EVENT_SEGMENT => {
            var seg: c.GstSegment = undefined;
            streamLock(d);
            c.gst_event_copy_segment(e, &seg);
            const seqnum = c.gst_event_get_seqnum(e);
            const format = seg.format;
            if (format != c.GST_FORMAT_TIME) {
                var nstart: i64 = 0;
                if (r.ctx.do_estimate_rate != 0 and c.gst_pad_query_convert(d.*.sinkpad, c.GST_FORMAT_BYTES, @bitCast(seg.start), c.GST_FORMAT_TIME, &nstart) != 0) {
                    seg.format = c.GST_FORMAT_TIME;
                    seg.start = @bitCast(nstart);
                    seg.time = @bitCast(nstart);
                    seg.stop = NONE;
                    c.gst_mini_object_unref(@ptrCast(e));
                    e = c.gst_event_new_segment(&seg);
                    c.gst_event_set_seqnum(e, seqnum);
                } else {
                    streamUnlock(d);
                    c.gst_mini_object_unref(@ptrCast(e));
                    return 0;
                }
            }
            if (format != c.GST_FORMAT_TIME) {
                r.base_ts = seg.start;
                r.samples = 0;
            }
            el.lock(d);
            if (r.decode_flags_override) {
                seg.flags &= ~INSTANT_FLAGS;
                seg.flags |= r.decode_flags & INSTANT_FLAGS;
            }
            r.in_out_segment_sync = false;
            d.*.input_segment = seg;
            el.unlock(d);
            r.pending_events = c.g_list_append(r.pending_events, e);
            streamUnlock(d);
            return 1;
        },
        c.GST_EVENT_INSTANT_RATE_CHANGE => {
            var flags: c.GstSegmentFlags = 0;
            c.gst_event_parse_instant_rate_change(e, null, &flags);
            el.lock(d);
            r.decode_flags_override = true;
            r.decode_flags = flags;
            d.*.input_segment.flags &= ~INSTANT_FLAGS;
            d.*.input_segment.flags |= r.decode_flags & INSTANT_FLAGS;
            el.unlock(d);
            return c.gst_pad_event_default(d.*.sinkpad, @ptrCast(d), e);
        },
        c.GST_EVENT_GAP => return handleGap(d, e),
        c.GST_EVENT_FLUSH_STOP => {
            streamLock(d);
            _ = flushDec(d, true);
            r.pending_events = flushEvents(d.*.srcpad, r.pending_events);
            streamUnlock(d);
            return pushEvent(d, e);
        },
        c.GST_EVENT_SEGMENT_DONE => {
            streamLock(d);
            _ = drain(d);
            streamUnlock(d);
            if (r.pending_events != null) sendPendingEvents(d);
            return pushEvent(d, e);
        },
        c.GST_EVENT_EOS => {
            streamLock(d);
            _ = drain(d);
            streamUnlock(d);
            if (r.ctx.had_input_data and !r.ctx.had_output_data) post(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_DECODE, c.g_strdup("No valid frames decoded before end of stream"), c.g_strdup("no valid frames found"), "gst_audio_decoder_sink_eventfunc", 2523);
            if (r.pending_events != null) sendPendingEvents(d);
            return pushEvent(d, e);
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            const ret = sinkSetcaps(d, caps);
            c.gst_mini_object_unref(@ptrCast(e));
            return ret;
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(e, @ptrCast(&tags));
            if (c.gst_tag_list_get_scope(tags) == c.GST_TAG_SCOPE_STREAM) {
                streamLock(d);
                if (r.upstream_tags != tags) {
                    if (r.upstream_tags) |t| c.gst_mini_object_unref(@ptrCast(t));
                    r.upstream_tags = @ptrCast(c.gst_mini_object_ref(@ptrCast(tags)));
                }
                c.gst_mini_object_unref(@ptrCast(e));
                e = mergedTags(d);
                r.tags_changed = false;
                streamUnlock(d);
                if (e == null) return 1;
            }
        },
        else => {},
    }
    if (e.*.type & c.GST_EVENT_TYPE_SERIALIZED == 0) return c.gst_pad_event_default(d.*.sinkpad, @ptrCast(d), e);
    streamLock(d);
    r.pending_events = c.g_list_append(r.pending_events, e);
    streamUnlock(d);
    return 1;
}

fn sinkEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, e: [*c]Event) callconv(.c) c.gboolean {
    const d = of(parent_obj);
    if (klass(d).sink_event) |f| return f(d, e);
    c.gst_mini_object_unref(@ptrCast(e));
    return 0;
}

fn doSeek(d: [*c]Dec, e: [*c]Event) c.gboolean {
    var rate: f64 = 0;
    var format: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start_time: i64 = 0;
    var end_time: i64 = 0;
    c.gst_event_parse_seek(e, &rate, &format, &flags, &st, &start_time, &et, &end_time);
    if (rate != 1.0) return 0;
    if (st != c.GST_SEEK_TYPE_SET) return 0;
    if ((et != c.GST_SEEK_TYPE_SET and et != c.GST_SEEK_TYPE_NONE) or (et == c.GST_SEEK_TYPE_SET and end_time != -1)) return 0;
    if (flags & c.GST_SEEK_FLAG_FLUSH == 0) return 0;
    var seg = d.*.output_segment;
    _ = c.gst_segment_do_seek(&seg, rate, format, flags, st, @bitCast(start_time), et, @bitCast(end_time), null);
    start_time = @bitCast(seg.position);
    var start: i64 = 0;
    if (c.gst_pad_query_convert(d.*.sinkpad, c.GST_FORMAT_TIME, start_time, c.GST_FORMAT_BYTES, &start) == 0) return 0;
    const seqnum = c.gst_event_get_seqnum(e);
    const ne = c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, flags, c.GST_SEEK_TYPE_SET, start, c.GST_SEEK_TYPE_NONE, -1);
    c.gst_event_set_seqnum(ne, seqnum);
    return c.gst_pad_push_event(d.*.sinkpad, ne);
}

fn srcEventDefault(d: [*c]Dec, e: [*c]Event) callconv(.c) c.gboolean {
    if (e.*.type != c.GST_EVENT_SEEK) return c.gst_pad_event_default(d.*.srcpad, @ptrCast(d), e);
    var rate: f64 = 0;
    var format: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    c.gst_event_parse_seek(e, &rate, &format, &flags, &st, &start, &et, &stop);
    const seqnum = c.gst_event_get_seqnum(e);
    _ = c.gst_mini_object_ref(@ptrCast(e));
    if (c.gst_pad_push_event(d.*.sinkpad, e) != 0) {
        c.gst_mini_object_unref(@ptrCast(e));
        return 1;
    }
    defer c.gst_mini_object_unref(@ptrCast(e));
    if (format == c.GST_FORMAT_TIME) return if (doByte(d)) doSeek(d, e) else 0;
    var tstart: i64 = 0;
    var tstop: i64 = 0;
    if (c.gst_pad_query_convert(d.*.srcpad, format, start, c.GST_FORMAT_TIME, &tstart) == 0) return 0;
    if (c.gst_pad_query_convert(d.*.srcpad, format, stop, c.GST_FORMAT_TIME, &tstop) == 0) return 0;
    const ne = c.gst_event_new_seek(rate, c.GST_FORMAT_TIME, flags, st, tstart, et, tstop);
    c.gst_event_set_seqnum(ne, seqnum);
    return c.gst_pad_push_event(d.*.sinkpad, ne);
}

fn srcEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, e: [*c]Event) callconv(.c) c.gboolean {
    const d = of(parent_obj);
    if (klass(d).src_event) |f| return f(d, e);
    c.gst_mini_object_unref(@ptrCast(e));
    return 0;
}

fn decideAllocationDefault(_: [*c]Dec, q: [*c]Query) callconv(.c) c.gboolean {
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_query_get_n_allocation_params(q) > 0) {
        c.gst_query_parse_nth_allocation_param(q, 0, &allocator, &params);
        c.gst_query_set_nth_allocation_param(q, 0, allocator, &params);
    } else {
        c.gst_allocation_params_init(&params);
        c.gst_query_add_allocation_param(q, allocator, &params);
    }
    if (allocator != null) c.gst_object_unref(allocator);
    return 1;
}

fn proposeAllocationDefault(_: [*c]Dec, _: [*c]Query) callconv(.c) c.gboolean {
    return 1;
}

pub export fn gst_audio_decoder_proxy_getcaps(d: [*c]Dec, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    return utils.proxyGetcaps(d.*.sinkpad, d.*.srcpad, caps, filter);
}

fn sinkQueryDefault(d: [*c]Dec, q: [*c]Query) callconv(.c) c.gboolean {
    const r = priv(d);
    const pad = d.*.sinkpad;
    switch (q.*.type) {
        c.GST_QUERY_FORMATS => {
            c.gst_query_set_formats(q, 2, c.GST_FORMAT_TIME, c.GST_FORMAT_BYTES);
            return 1;
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            el.lock(d);
            const ok = utils.encodedConvert(&r.ctx.info, @bitCast(r.bytes_in), @bitCast(r.samples_out), sf, sv, &df, &dv);
            el.unlock(d);
            if (!ok) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_ALLOCATION => return if (klass(d).propose_allocation) |f| f(d, q) else 0,
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            const caps = if (klass(d).getcaps) |f| f(d, filter) else gst_audio_decoder_proxy_getcaps(d, null, filter);
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            if (r.use_default_pad_acceptcaps) return c.gst_pad_query_default(pad, @ptrCast(d), q);
            var caps: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(q, &caps);
            const templ = c.gst_pad_get_pad_template_caps(pad);
            var accept = c.gst_caps_is_subset(caps, templ);
            c.gst_caps_unref(templ);
            if (accept != 0) {
                const allowed = c.gst_pad_query_caps(pad, caps);
                accept = c.gst_caps_can_intersect(caps, allowed);
                c.gst_caps_unref(allowed);
            }
            c.gst_query_set_accept_caps_result(q, accept);
            return 1;
        },
        c.GST_QUERY_SEEKING => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_seeking(q, &format, null, null, null);
            if (format != c.GST_FORMAT_TIME) return 0;
            return c.gst_pad_query_default(pad, @ptrCast(d), q);
        },
        else => return c.gst_pad_query_default(pad, @ptrCast(d), q),
    }
}

fn sinkQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const d = of(parent_obj);
    return if (klass(d).sink_query) |f| f(d, q) else 0;
}

fn srcQueryDefault(d: [*c]Dec, q: [*c]Query) callconv(.c) c.gboolean {
    const r = priv(d);
    const pad = d.*.srcpad;
    switch (q.*.type) {
        c.GST_QUERY_DURATION => {
            if (c.gst_pad_query_default(pad, @ptrCast(d), q) != 0) return 1;
            var format: c.GstFormat = 0;
            c.gst_query_parse_duration(q, &format, null);
            if (format == c.GST_FORMAT_TIME and doByte(d)) {
                var value: i64 = 0;
                if (c.gst_pad_peer_query_duration(d.*.sinkpad, c.GST_FORMAT_BYTES, &value) != 0 and c.gst_pad_query_convert(d.*.sinkpad, c.GST_FORMAT_BYTES, value, c.GST_FORMAT_TIME, &value) != 0) {
                    c.gst_query_set_duration(q, c.GST_FORMAT_TIME, value);
                    return 1;
                }
            }
            return 0;
        },
        c.GST_QUERY_POSITION => {
            if (c.gst_pad_peer_query(d.*.sinkpad, q) != 0) return 1;
            var format: c.GstFormat = 0;
            c.gst_query_parse_position(q, &format, null);
            if (format == c.GST_FORMAT_BYTES) return 0;
            const time = c.gst_segment_to_stream_time(&d.*.output_segment, c.GST_FORMAT_TIME, d.*.output_segment.position);
            var value: i64 = 0;
            if (c.gst_pad_query_convert(pad, c.GST_FORMAT_TIME, @bitCast(time), format, &value) == 0) return 0;
            c.gst_query_set_position(q, format, value);
            return 1;
        },
        c.GST_QUERY_FORMATS => {
            c.gst_query_set_formats(q, 3, c.GST_FORMAT_TIME, c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT);
            return 1;
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            el.lock(d);
            const ok = info.gst_audio_info_convert(&r.ctx.info, sf, sv, df, &dv);
            el.unlock(d);
            if (ok == 0) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_LATENCY => {
            const res = c.gst_pad_peer_query(d.*.sinkpad, q);
            if (res != 0) {
                var live: c.gboolean = 0;
                var mn: u64 = 0;
                var mx: u64 = 0;
                c.gst_query_parse_latency(q, &live, &mn, &mx);
                el.lock(d);
                mn +%= r.ctx.min_latency;
                mx = if (mx == NONE or r.ctx.max_latency == NONE) NONE else mx +% r.ctx.max_latency;
                el.unlock(d);
                c.gst_query_set_latency(q, live, mn, mx);
            }
            return res;
        },
        else => return c.gst_pad_query_default(pad, @ptrCast(d), q),
    }
}

fn srcQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const d = of(parent_obj);
    return if (klass(d).src_query) |f| f(d, q) else 0;
}

fn stopDec(d: [*c]Dec) bool {
    var ret = true;
    if (klass(d).stop) |f| ret = f(d) != 0;
    reset(d, true);
    if (ret) priv(d).active = false;
    return ret;
}

fn startDec(d: [*c]Dec) bool {
    reset(d, true);
    var ret = true;
    if (klass(d).start) |f| ret = f(d) != 0;
    if (ret) priv(d).active = true;
    return ret;
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const r = priv(o);
    switch (id) {
        1 => c.g_value_set_int64(v, @bitCast(r.latency)),
        2 => c.g_value_set_int64(v, @bitCast(r.tolerance)),
        3 => c.g_value_set_boolean(v, r.plc),
        4 => c.g_value_set_int(v, gst_audio_decoder_get_max_errors(of(o))),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 3176),
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const r = priv(o);
    switch (id) {
        1 => r.latency = @bitCast(c.g_value_get_int64(v)),
        2 => r.tolerance = @bitCast(c.g_value_get_int64(v)),
        3 => r.plc = c.g_value_get_boolean(v),
        4 => gst_audio_decoder_set_max_errors(of(o), c.g_value_get_int(v)),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 3203),
    }
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const d = of(e);
    const k = klass(d);
    const fname = "gst_audio_decoder_change_state";
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => if (k.open) |f| if (f(d) == 0) {
            post(d, c.GST_MESSAGE_ERROR, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to open codec"), fname, 3270);
            return c.GST_STATE_CHANGE_FAILURE;
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => if (!startDec(d)) {
            post(d, c.GST_MESSAGE_ERROR, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to start codec"), fname, 3260);
            return c.GST_STATE_CHANGE_FAILURE;
        },
        else => {},
    }
    const ret = parent.?.change_state.?(e, t);
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => if (!stopDec(d)) {
            post(d, c.GST_MESSAGE_ERROR, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to stop codec"), fname, 3265);
            return c.GST_STATE_CHANGE_FAILURE;
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => if (k.close) |f| if (f(d) == 0) {
            post(d, c.GST_MESSAGE_ERROR, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to close codec"), fname, 3275);
            return c.GST_STATE_CHANGE_FAILURE;
        },
        else => {},
    }
    return ret;
}

pub export fn _gst_audio_decoder_error(d: [*c]Dec, weight: c.gint, domain: c.GQuark, code: c.gint, txt: [*c]u8, dbg: [*c]u8, file: [*c]const u8, function: [*c]const u8, line: c.gint) c.GstFlowReturn {
    const r = priv(d);
    r.error_count += weight;
    r.discont = true;
    if (r.max_errors >= 0 and r.max_errors < r.error_count) {
        c.gst_element_message_full(@ptrCast(d), c.GST_MESSAGE_ERROR, domain, code, txt, dbg, file, function, line);
        return c.GST_FLOW_ERROR;
    }
    c.g_free(txt);
    c.g_free(dbg);
    return c.GST_FLOW_OK;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    if (!check.that(isDec(o), "gst_audio_decoder_finalize", "GST_IS_AUDIO_DECODER (object)")) return;
    const d = of(o);
    const r = priv(d);
    if (r.adapter) |a| c.g_object_unref(a);
    if (r.adapter_out) |a| c.g_object_unref(a);
    c.g_rec_mutex_clear(&d.*.stream_lock);
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    _ = c._gst_debug_category_new("audiodecoder", 0, "audio decoder base class");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    @as(*c.GstElementClass, @ptrCast(@alignCast(k))).change_state = changeState;
    const F = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_int64("min-latency", "Minimum Latency", "Aggregate output data to a minimum of latency time (ns)", 0, std.math.maxInt(i64), 0, F));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_int64("tolerance", "Tolerance", "Perfect ts while timestamp jitter/imperfection within tolerance (ns)", 0, std.math.maxInt(i64), 0, F));
    c.g_object_class_install_property(oc, 3, c.g_param_spec_boolean("plc", "Packet Loss Concealment", "Perform packet loss concealment (if supported)", 0, F));
    c.g_object_class_install_property(oc, 4, c.g_param_spec_int("max-errors", "Max errors", "Max consecutive decoder errors before returning flow error", -1, std.math.maxInt(c.gint), -1, F));
    const dc: *Class = @ptrCast(@alignCast(k));
    dc.sink_event = sinkEventDefault;
    dc.src_event = srcEventDefault;
    dc.propose_allocation = proposeAllocationDefault;
    dc.decide_allocation = decideAllocationDefault;
    dc.negotiate = negotiateDefault;
    dc.sink_query = sinkQueryDefault;
    dc.src_query = srcQueryDefault;
    dc.transform_meta = transformMetaDefault;
    _ = c.g_quark_from_static_string("audio");
}

fn init(inst: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const d = of(inst);
    d.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    const r = priv(d);
    r.* = std.mem.zeroes(Private);
    const ec: [*c]c.GstElementClass = @ptrCast(@alignCast(g_class));
    var templ = c.gst_element_class_get_pad_template(ec, "sink");
    if (!check.that(templ != null, "gst_audio_decoder_init", "pad_template != NULL")) return;
    d.*.sinkpad = c.gst_pad_new_from_template(templ, "sink");
    c.gst_pad_set_event_function_full(d.*.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_chain_function_full(d.*.sinkpad, chain, null, null);
    c.gst_pad_set_query_function_full(d.*.sinkpad, sinkQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(d), d.*.sinkpad);
    templ = c.gst_element_class_get_pad_template(ec, "src");
    if (!check.that(templ != null, "gst_audio_decoder_init", "pad_template != NULL")) return;
    d.*.srcpad = c.gst_pad_new_from_template(templ, "src");
    c.gst_pad_set_event_function_full(d.*.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(d.*.srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(d), d.*.srcpad);
    r.adapter = c.gst_adapter_new();
    r.adapter_out = c.gst_adapter_new();
    c.g_queue_init(&r.frames);
    c.g_rec_mutex_init(&d.*.stream_lock);
    r.drainable = 1;
    r.max_errors = -1;
    reset(d, true);
}

pub export fn gst_audio_decoder_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstAudioDecoder", Class, Dec, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

pub export fn gst_audio_decoder_get_audio_info(d: [*c]Dec) [*c]c.GstAudioInfo {
    if (!check.that(isDec(d), "gst_audio_decoder_get_audio_info", "GST_IS_AUDIO_DECODER (dec)")) return null;
    return &priv(d).ctx.info;
}

pub export fn gst_audio_decoder_set_plc_aware(d: [*c]Dec, plc: c.gboolean) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_plc_aware", "GST_IS_AUDIO_DECODER (dec)")) return;
    priv(d).ctx.do_plc = plc;
}

pub export fn gst_audio_decoder_get_plc_aware(d: [*c]Dec) c.gint {
    if (!check.that(isDec(d), "gst_audio_decoder_get_plc_aware", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    return priv(d).ctx.do_plc;
}

pub export fn gst_audio_decoder_set_estimate_rate(d: [*c]Dec, enabled: c.gboolean) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_estimate_rate", "GST_IS_AUDIO_DECODER (dec)")) return;
    priv(d).ctx.do_estimate_rate = enabled;
}

pub export fn gst_audio_decoder_get_estimate_rate(d: [*c]Dec) c.gint {
    if (!check.that(isDec(d), "gst_audio_decoder_get_estimate_rate", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    return priv(d).ctx.do_estimate_rate;
}

pub export fn gst_audio_decoder_get_delay(d: [*c]Dec) c.gint {
    if (!check.that(isDec(d), "gst_audio_decoder_get_delay", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    return priv(d).ctx.delay;
}

pub export fn gst_audio_decoder_set_max_errors(d: [*c]Dec, num: c.gint) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_max_errors", "GST_IS_AUDIO_DECODER (dec)")) return;
    priv(d).max_errors = num;
}

pub export fn gst_audio_decoder_get_max_errors(d: [*c]Dec) c.gint {
    if (!check.that(isDec(d), "gst_audio_decoder_get_max_errors", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    return priv(d).max_errors;
}

pub export fn gst_audio_decoder_set_latency(d: [*c]Dec, min: c.GstClockTime, max: c.GstClockTime) void {
    const fname = "gst_audio_decoder_set_latency";
    if (!check.that(isDec(d), fname, "GST_IS_AUDIO_DECODER (dec)")) return;
    if (!check.that(min != NONE, fname, "GST_CLOCK_TIME_IS_VALID (min)")) return;
    if (!check.that(min <= max, fname, "min <= max")) return;
    const r = priv(d);
    var post_msg = false;
    el.lock(d);
    if (r.ctx.min_latency != min) {
        r.ctx.min_latency = min;
        post_msg = true;
    }
    if (r.ctx.max_latency != max) {
        r.ctx.max_latency = max;
        post_msg = true;
    }
    if (!r.ctx.posted_latency_msg) {
        r.ctx.posted_latency_msg = true;
        post_msg = true;
    }
    el.unlock(d);
    if (post_msg) _ = c.gst_element_post_message(@ptrCast(d), c.gst_message_new_latency(@ptrCast(d)));
}

pub export fn gst_audio_decoder_get_latency(d: [*c]Dec, min: [*c]c.GstClockTime, max: [*c]c.GstClockTime) void {
    if (!check.that(isDec(d), "gst_audio_decoder_get_latency", "GST_IS_AUDIO_DECODER (dec)")) return;
    el.lock(d);
    if (min != null) min.* = priv(d).ctx.min_latency;
    if (max != null) max.* = priv(d).ctx.max_latency;
    el.unlock(d);
}

pub export fn gst_audio_decoder_get_parse_state(d: [*c]Dec, sync: [*c]c.gboolean, eos: [*c]c.gboolean) void {
    if (!check.that(isDec(d), "gst_audio_decoder_get_parse_state", "GST_IS_AUDIO_DECODER (dec)")) return;
    if (sync != null) sync.* = priv(d).ctx.sync;
    if (eos != null) eos.* = priv(d).ctx.eos;
}

pub export fn gst_audio_decoder_set_allocation_caps(d: [*c]Dec, caps: [*c]c.GstCaps) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_allocation_caps", "GST_IS_AUDIO_DECODER (dec)")) return;
    _ = c.gst_caps_replace(&priv(d).ctx.allocation_caps, caps);
}

pub export fn gst_audio_decoder_set_plc(d: [*c]Dec, enabled: c.gboolean) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_plc", "GST_IS_AUDIO_DECODER (dec)")) return;
    el.lock(d);
    priv(d).plc = enabled;
    el.unlock(d);
}

pub export fn gst_audio_decoder_get_plc(d: [*c]Dec) c.gboolean {
    if (!check.that(isDec(d), "gst_audio_decoder_get_plc", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    el.lock(d);
    defer el.unlock(d);
    return priv(d).plc;
}

pub export fn gst_audio_decoder_set_min_latency(d: [*c]Dec, num: c.GstClockTime) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_min_latency", "GST_IS_AUDIO_DECODER (dec)")) return;
    if (!check.that(num != NONE, "gst_audio_decoder_set_min_latency", "GST_CLOCK_TIME_IS_VALID (num)")) return;
    el.lock(d);
    priv(d).latency = num;
    el.unlock(d);
}

pub export fn gst_audio_decoder_get_min_latency(d: [*c]Dec) c.GstClockTime {
    if (!check.that(isDec(d), "gst_audio_decoder_get_min_latency", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    el.lock(d);
    defer el.unlock(d);
    return priv(d).latency;
}

pub export fn gst_audio_decoder_set_tolerance(d: [*c]Dec, tolerance: c.GstClockTime) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_tolerance", "GST_IS_AUDIO_DECODER (dec)")) return;
    if (!check.that(tolerance != NONE, "gst_audio_decoder_set_tolerance", "GST_CLOCK_TIME_IS_VALID (tolerance)")) return;
    el.lock(d);
    priv(d).tolerance = tolerance;
    el.unlock(d);
}

pub export fn gst_audio_decoder_get_tolerance(d: [*c]Dec) c.GstClockTime {
    if (!check.that(isDec(d), "gst_audio_decoder_get_tolerance", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    el.lock(d);
    defer el.unlock(d);
    return priv(d).tolerance;
}

pub export fn gst_audio_decoder_set_drainable(d: [*c]Dec, enabled: c.gboolean) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_drainable", "GST_IS_AUDIO_DECODER (dec)")) return;
    el.lock(d);
    priv(d).drainable = enabled;
    el.unlock(d);
}

pub export fn gst_audio_decoder_get_drainable(d: [*c]Dec) c.gboolean {
    if (!check.that(isDec(d), "gst_audio_decoder_get_drainable", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    el.lock(d);
    defer el.unlock(d);
    return priv(d).drainable;
}

pub export fn gst_audio_decoder_set_needs_format(d: [*c]Dec, enabled: c.gboolean) void {
    if (!check.that(isDec(d), "gst_audio_decoder_set_needs_format", "GST_IS_AUDIO_DECODER (dec)")) return;
    el.lock(d);
    priv(d).needs_format = enabled;
    el.unlock(d);
}

pub export fn gst_audio_decoder_get_needs_format(d: [*c]Dec) c.gboolean {
    if (!check.that(isDec(d), "gst_audio_decoder_get_needs_format", "GST_IS_AUDIO_DECODER (dec)")) return 0;
    el.lock(d);
    defer el.unlock(d);
    return priv(d).needs_format;
}

pub export fn gst_audio_decoder_merge_tags(d: [*c]Dec, tags: ?*const c.GstTagList, mode: c.GstTagMergeMode) void {
    const fname = "gst_audio_decoder_merge_tags";
    if (!check.that(isDec(d), fname, "GST_IS_AUDIO_DECODER (dec)")) return;
    if (!check.that(tags == null or @as([*c]const c.GstMiniObject, @ptrCast(tags)).*.type == c.gst_tag_list_get_type(), fname, "tags == NULL || GST_IS_TAG_LIST (tags)")) return;
    if (!check.that(mode != c.GST_TAG_MERGE_UNDEFINED, fname, "mode != GST_TAG_MERGE_UNDEFINED")) return;
    const r = priv(d);
    streamLock(d);
    if (@as(?*const c.GstTagList, r.taglist) != tags) {
        if (r.taglist) |t| {
            c.gst_mini_object_unref(@ptrCast(t));
            r.taglist = null;
            r.tags_mode = c.GST_TAG_MERGE_KEEP_ALL;
        }
        if (tags) |t| {
            r.taglist = @ptrCast(c.gst_mini_object_ref(@ptrCast(@constCast(t))));
            r.tags_mode = mode;
        }
        r.tags_changed = true;
    }
    streamUnlock(d);
}

pub export fn gst_audio_decoder_allocate_output_buffer(d: [*c]Dec, size: c.gsize) [*c]Buffer {
    if (!check.that(size > 0, "gst_audio_decoder_allocate_output_buffer", "size > 0")) return null;
    const r = priv(d);
    streamLock(d);
    defer streamUnlock(d);
    const needs = c.gst_pad_check_reconfigure(d.*.srcpad) != 0;
    if (r.ctx.output_format_changed or (infoValid(&r.ctx.info) and needs)) {
        if (!negotiateUnlocked(d)) {
            c.gst_pad_mark_reconfigure(d.*.srcpad);
            return c.gst_buffer_new_allocate(null, size, null);
        }
    }
    const b = c.gst_buffer_new_allocate(r.ctx.allocator, size, &r.ctx.params);
    return if (b != null) b else c.gst_buffer_new_allocate(null, size, null);
}

pub export fn gst_audio_decoder_get_allocator(d: [*c]Dec, allocator: [*c][*c]c.GstAllocator, params: [*c]c.GstAllocationParams) void {
    if (!check.that(isDec(d), "gst_audio_decoder_get_allocator", "GST_IS_AUDIO_DECODER (dec)")) return;
    const r = priv(d);
    if (allocator != null) allocator.* = if (r.ctx.allocator != null) @ptrCast(@alignCast(c.gst_object_ref(r.ctx.allocator))) else null;
    if (params != null) params.* = r.ctx.params;
}

pub export fn gst_audio_decoder_set_use_default_pad_acceptcaps(d: [*c]Dec, use: c.gboolean) void {
    priv(d).use_default_pad_acceptcaps = use != 0;
}
