const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const info = @import("info.zig");
const clip = @import("clip.zig");
const utils = @import("utils.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Enc = c.GstAudioEncoder;
const Class = c.GstAudioEncoderClass;
const Buffer = c.GstBuffer;
const Event = c.GstEvent;
const Query = c.GstQuery;
const NONE = el.NONE;
const SEC: u64 = c.GST_SECOND;
const PATH = "../gst-libs/gst/audio/gstaudioencoder.c";
const DEFAULT_TOLERANCE: i64 = 40000000;

const Context = struct {
    input_caps: [*c]c.GstCaps,
    info: c.GstAudioInfo,
    caps: [*c]c.GstCaps,
    allocation_caps: [*c]c.GstCaps,
    output_caps_changed: bool,
    frame_samples_min: c.gint,
    frame_samples_max: c.gint,
    frame_max: c.gint,
    lookahead: c.gint,
    min_latency: u64,
    max_latency: u64,
    posted_latency_msg: bool,
    negotiated: bool,
    headers: [*c]c.GList,
    new_headers: bool,
    allocator: [*c]c.GstAllocator,
    params: c.GstAllocationParams,
};

const Private = struct {
    active: bool,
    base_ts: u64,
    base_gp: i64,
    samples: u64,
    adapter: ?*c.GstAdapter,
    offset: c.gint,
    discont: bool,
    last_duration: u64,
    got_data: bool,
    drained: bool,
    force: bool,
    do_caps: bool,
    samples_in: u64,
    bytes_out: u64,
    ctx: Context,
    tolerance: i64,
    perfect_ts: c.gboolean,
    hard_resync: c.gboolean,
    granule: c.gboolean,
    hard_min: c.gboolean,
    drainable: c.gboolean,
    upstream_tags: ?*c.GstTagList,
    tags: ?*c.GstTagList,
    tags_mode: c.GstTagMergeMode,
    tags_changed: bool,
    pending_events: [*c]c.GList,
    early_pending_events: [*c]c.GList,
};

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstElementClass = null;

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
    return gtype.instanceOf(e, gst_audio_encoder_get_type());
}

fn streamLock(e: [*c]Enc) void {
    c.g_rec_mutex_lock(&e.*.stream_lock);
}

fn streamUnlock(e: [*c]Enc) void {
    c.g_rec_mutex_unlock(&e.*.stream_lock);
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn post(e: [*c]Enc, domain: el.Domain, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    el.messageAt(e, c.GST_MESSAGE_ERROR, domain, code, text, debug, PATH, func, line, null);
}

fn unrefOne(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(data)));
}

fn freeEvents(l: *[*c]c.GList) void {
    c.g_list_foreach(l.*, unrefOne, null);
    c.g_list_free(l.*);
    l.* = null;
}

fn reset(e: [*c]Enc, full: bool) void {
    const r = priv(e);
    streamLock(e);
    if (full) {
        r.active = false;
        el.lock(e);
        r.samples_in = 0;
        r.bytes_out = 0;
        el.unlock(e);
        c.g_list_foreach(r.ctx.headers, unrefOne, null);
        c.g_list_free(r.ctx.headers);
        r.ctx.headers = null;
        r.ctx.new_headers = false;
        if (r.ctx.allocator != null) c.gst_object_unref(r.ctx.allocator);
        r.ctx.allocator = null;
        el.lock(e);
        _ = c.gst_caps_replace(&r.ctx.input_caps, null);
        _ = c.gst_caps_replace(&r.ctx.caps, null);
        _ = c.gst_caps_replace(&r.ctx.allocation_caps, null);
        r.ctx = std.mem.zeroes(Context);
        info.gst_audio_info_init(&r.ctx.info);
        el.unlock(e);
        if (r.upstream_tags) |t| c.gst_mini_object_unref(@ptrCast(t));
        r.upstream_tags = null;
        if (r.tags) |t| c.gst_mini_object_unref(@ptrCast(t));
        r.tags = null;
        r.tags_mode = c.GST_TAG_MERGE_APPEND;
        r.tags_changed = false;
        freeEvents(&r.early_pending_events);
        freeEvents(&r.pending_events);
    }
    c.gst_segment_init(&e.*.input_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&e.*.output_segment, c.GST_FORMAT_TIME);
    c.gst_adapter_clear(r.adapter);
    r.got_data = false;
    r.drained = true;
    r.offset = 0;
    r.base_ts = NONE;
    r.base_gp = -1;
    r.samples = 0;
    r.discont = false;
    streamUnlock(e);
}

fn pushEvent(e: [*c]Enc, ev: [*c]Event) c.gboolean {
    if (ev.*.type == c.GST_EVENT_SEGMENT) {
        var seg: c.GstSegment = undefined;
        streamLock(e);
        c.gst_event_copy_segment(ev, &seg);
        e.*.output_segment = seg;
        streamUnlock(e);
    }
    return c.gst_pad_push_event(e.*.srcpad, ev);
}

fn pushList(e: [*c]Enc, list: *[*c]c.GList) void {
    if (list.* == null) return;
    const l0 = list.*;
    list.* = null;
    var l = l0;
    while (l != null) : (l = l.*.next) _ = pushEvent(e, @ptrCast(@alignCast(l.*.data)));
    c.g_list_free(l0);
}

fn pushEarly(e: [*c]Enc) void {
    pushList(e, &priv(e).early_pending_events);
}

fn pushPending(e: [*c]Enc) void {
    pushEarly(e);
    pushList(e, &priv(e).pending_events);
}

fn mergedTags(e: [*c]Enc) [*c]Event {
    const r = priv(e);
    const merged = c.gst_tag_list_merge(r.upstream_tags, r.tags, r.tags_mode);
    if (merged == null) return null;
    if (c.gst_tag_list_is_empty(merged) != 0) {
        c.gst_mini_object_unref(@ptrCast(merged));
        return null;
    }
    return c.gst_event_new_tag(merged);
}

fn pushTags(e: [*c]Enc) void {
    const r = priv(e);
    if (!r.tags_changed) return;
    const ev = mergedTags(e);
    if (ev != null) _ = pushEvent(e, ev);
    r.tags_changed = false;
}

fn transformMetaDefault(_: [*c]Enc, _: [*c]Buffer, meta: [*c]c.GstMeta, _: [*c]Buffer) callconv(.c) c.gboolean {
    var tags = c.gst_meta_api_type_get_tags(meta.*.info.*.api);
    if (tags == null) return 1;
    while (tags.* != null) : (tags += 1) {
        const t = std.mem.span(tags.*);
        if (!std.mem.eql(u8, t, "audio") and !std.mem.eql(u8, t, "channels")) return 0;
    }
    return 1;
}

const CopyMeta = struct { enc: [*c]Enc, out: [*c]Buffer };

fn copyMeta(inbuf: [*c]Buffer, meta: [*c][*c]c.GstMeta, data: c.gpointer) callconv(.c) c.gboolean {
    const cm: *CopyMeta = @ptrCast(@alignCast(data));
    const mi = meta.*.*.info;
    var copy = false;
    if (c.gst_meta_api_type_has_tag(mi.*.api, c._gst_meta_tag_memory) != 0 or c.gst_meta_api_type_has_tag(mi.*.api, c._gst_meta_tag_memory_reference) != 0) {
        copy = false;
    } else if (klass(cm.enc).transform_meta) |f| {
        copy = f(cm.enc, cm.out, meta.*, inbuf) != 0;
    }
    if (copy) if (mi.*.transform_func) |tf| {
        var cd = c.GstMetaTransformCopy{ .region = 0, .offset = 0, .size = std.math.maxInt(c.gsize) };
        _ = tf(cm.out, meta.*, inbuf, c._gst_meta_transform_copy, &cd);
    };
    return 1;
}

fn negotiateUnlocked(e: [*c]Enc) bool {
    var ret = true;
    if (klass(e).negotiate) |f| ret = f(e) != 0;
    priv(e).ctx.negotiated = true;
    return ret;
}

pub export fn gst_audio_encoder_finish_frame(e: [*c]Enc, buf_in: [*c]Buffer, samples_in: c.gint) c.GstFlowReturn {
    const fname = "gst_audio_encoder_finish_frame";
    const r = priv(e);
    const ctx = &r.ctx;
    const k = klass(e);
    var buf = buf_in;
    var samples = samples_in;
    if (!check.that(buf == null or c.gst_buffer_get_size(buf) > 0, fname, "buf == NULL || gst_buffer_get_size (buf) > 0")) return c.GST_FLOW_ERROR;
    if (ctx.caps == null) {
        post(e, .stream, c.GST_STREAM_ERROR_ENCODE, c.g_strdup("no caps set"), null, fname, 1079);
        if (buf != null) c.gst_mini_object_unref(@ptrCast(buf));
        return c.GST_FLOW_ERROR;
    }
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var inbuf: [*c]Buffer = null;
    streamLock(e);
    body: {
        const needs = c.gst_pad_check_reconfigure(e.*.srcpad) != 0;
        if (ctx.output_caps_changed or needs) {
            if (!negotiateUnlocked(e)) {
                c.gst_pad_mark_reconfigure(e.*.srcpad);
                ret = if (el.flags(e.*.srcpad) & c.GST_PAD_FLAG_FLUSHING != 0) c.GST_FLOW_FLUSHING else c.GST_FLOW_NOT_NEGOTIATED;
                if (buf != null) c.gst_mini_object_unref(@ptrCast(buf));
                break :body;
            }
        }
        if (buf != null) r.got_data = true;
        pushEarly(e);
        pushTags(e);
        const bpf = ctx.info.bpf;
        if (samples < 0) samples = @divTrunc(r.offset, bpf);
        if (samples != 0) {
            if (r.perfect_ts == 0) {
                var distance: u64 = 0;
                const ts = c.gst_adapter_prev_pts(r.adapter, &distance);
                if (distance % @as(u64, @intCast(bpf)) != 0) c.g_assertion_message_expr(check.DOMAIN, PATH, 856, fname, "distance % ctx->info.bpf == 0");
                distance /= @intCast(bpf);
                if (ts != NONE and ts != r.base_ts) {
                    const rate: u64 = @intCast(ctx.info.rate);
                    const next = ts +% c.gst_util_uint64_scale(distance, SEC, rate);
                    const old = r.base_ts +% c.gst_util_uint64_scale(r.samples, SEC, rate);
                    const dt = diff(next, old);
                    if (dt < -r.tolerance or dt > r.tolerance) r.discont = true;
                    const half: i64 = @intCast(SEC / rate / 2);
                    if (dt > half or dt < -half) {
                        r.base_ts = ts;
                        r.samples = distance;
                    }
                }
            }
            const need = samples * bpf;
            if (need > r.offset) {
                const avail = c.gst_adapter_available(r.adapter);
                if (!r.force) {
                    post(e, .stream, c.GST_STREAM_ERROR_ENCODE, c.g_strdup_printf("received more encoded samples %d than provided %d as inputs", samples, @divTrunc(r.offset, bpf)), null, fname, 1086);
                    if (buf != null) c.gst_mini_object_unref(@ptrCast(buf));
                    ret = c.GST_FLOW_ERROR;
                    c.g_assertion_message_expr(check.DOMAIN, PATH, 1093, fname, null);
                    break :body;
                }
                r.offset = 0;
                if (avail > 0 and @as(c.gsize, @intCast(need)) >= avail) {
                    inbuf = c.gst_adapter_take_buffer_fast(r.adapter, avail);
                    c.gst_adapter_clear(r.adapter);
                } else if (avail > 0) {
                    inbuf = c.gst_adapter_take_buffer_fast(r.adapter, @intCast(need));
                }
            } else {
                if (c.gst_adapter_available(r.adapter) > 0) inbuf = c.gst_adapter_take_buffer_fast(r.adapter, @intCast(need));
                r.offset -= need;
                if (c.gst_adapter_available(r.adapter) == 0) c.gst_adapter_clear(r.adapter);
            }
        }
        if (buf == null) {
            r.samples +%= @bitCast(@as(i64, samples));
            break :body;
        }
        if (ctx.new_headers) {
            var l = ctx.headers;
            while (l != null) : (l = l.*.next) {
                var hb: [*c]Buffer = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(@alignCast(l.*.data)))));
                hb = c.gst_buffer_make_writable(hb);
                const hs = c.gst_buffer_get_size(hb);
                if (r.discont) {
                    hb.*.mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
                    r.discont = false;
                }
                if (r.base_gp >= 0) {
                    hb.*.offset = 0;
                    hb.*.offset_end = 0;
                } else {
                    hb.*.offset = r.bytes_out;
                    hb.*.offset_end = r.bytes_out + hs;
                }
                el.lock(e);
                r.bytes_out +%= hs;
                el.unlock(e);
                ret = c.gst_pad_push(e.*.srcpad, hb);
                if (ret != c.GST_FLOW_OK) break :body;
            }
            ctx.new_headers = false;
        }
        const size = c.gst_buffer_get_size(buf);
        buf = c.gst_buffer_make_writable(buf);
        if (r.base_ts != NONE) {
            const rate: u64 = @intCast(ctx.info.rate);
            const la: u64 = @bitCast(@as(i64, ctx.lookahead));
            buf.*.pts = r.base_ts +% c.gst_util_uint64_scale(r.samples -% la, SEC, rate);
            buf.*.dts = buf.*.pts;
            if (samples > 0) {
                r.samples +%= @intCast(samples);
                buf.*.duration = r.base_ts +% c.gst_util_uint64_scale(r.samples -% la, SEC, rate) -% buf.*.pts;
                r.last_duration = buf.*.duration;
            } else buf.*.duration = r.last_duration;
            if (r.base_gp >= 0) {
                buf.*.offset_end = @bitCast(r.base_gp +% @as(i64, @bitCast(r.samples)) -% ctx.lookahead);
                buf.*.offset = c.gst_util_uint64_scale_round(buf.*.offset_end, SEC, rate);
            } else {
                buf.*.offset = r.bytes_out;
                buf.*.offset_end = r.bytes_out + size;
            }
        }
        if (k.transform_meta != null and inbuf != null) {
            var cm = CopyMeta{ .enc = e, .out = buf };
            _ = c.gst_buffer_foreach_meta(inbuf, copyMeta, &cm);
        }
        el.lock(e);
        r.bytes_out +%= size;
        el.unlock(e);
        if (r.discont) {
            buf.*.mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
            r.discont = false;
        }
        if (k.pre_push) |f| {
            ret = f(e, &buf);
            if (ret != c.GST_FLOW_OK or buf == null) {
                if (buf != null) c.gst_mini_object_unref(@ptrCast(buf));
                break :body;
            }
        }
        ret = c.gst_pad_push(e.*.srcpad, buf);
        pushPending(e);
    }
    if (inbuf != null) c.gst_mini_object_unref(@ptrCast(inbuf));
    streamUnlock(e);
    return ret;
}

fn pushBuffers(e: [*c]Enc, force: bool) c.GstFlowReturn {
    const k = klass(e);
    if (!check.that(k.handle_frame != null, "gst_audio_encoder_push_buffers", "klass->handle_frame != NULL")) return c.GST_FLOW_ERROR;
    const r = priv(e);
    const ctx = &r.ctx;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    while (ret == c.GST_FLOW_OK) {
        var buf: [*c]Buffer = null;
        var av: c.gint = @intCast(c.gst_adapter_available(r.adapter));
        if (r.offset > av) c.g_assertion_message_expr(check.DOMAIN, PATH, 1125, "gst_audio_encoder_push_buffers", "priv->offset <= av");
        av -= r.offset;
        var need: c.gint = if (ctx.frame_samples_min > 0) ctx.frame_samples_min * ctx.info.bpf else av;
        if (need > av or av == 0) {
            if (force) {
                r.force = true;
                need = av;
            } else break;
        } else r.force = false;
        if (ctx.frame_samples_max > 0) need = @min(av, ctx.frame_samples_max * ctx.info.bpf);
        if (ctx.frame_samples_min == ctx.frame_samples_max and ctx.frame_samples_min > 0 and need != 0) {
            if (ctx.frame_max > 1) {
                need = need * @min(@divTrunc(av, need), ctx.frame_max);
            } else if (ctx.frame_max == 0) need = need * @divTrunc(av, need);
        }
        r.got_data = false;
        var skip = false;
        if (need != 0) {
            buf = c.gst_adapter_get_buffer(r.adapter, @intCast(r.offset + need));
            buf = c.gst_buffer_make_writable(buf);
            c.gst_buffer_resize(buf, r.offset, -1);
        } else if (r.drainable == 0) skip = true;
        if (!skip) {
            r.offset += need;
            el.lock(e);
            r.samples_in +%= @intCast(@divTrunc(need, ctx.info.bpf));
            el.unlock(e);
            if (r.force and r.hard_min != 0 and buf != null) {
                ret = gst_audio_encoder_finish_frame(e, null, -1);
            } else ret = k.handle_frame.?(e, buf);
            if (buf != null) c.gst_mini_object_unref(@ptrCast(buf));
        }
        if (buf == null and !r.got_data) {
            r.drained = true;
            break;
        }
    }
    return ret;
}

fn drain(e: [*c]Enc) c.GstFlowReturn {
    if (priv(e).drained) return c.GST_FLOW_OK;
    return pushBuffers(e, true);
}

fn setBaseGp(e: [*c]Enc) void {
    const r = priv(e);
    if (r.granule == 0) return;
    const ts = c.gst_segment_to_running_time(&e.*.input_segment, c.GST_FORMAT_TIME, r.base_ts);
    if (ts != NONE) {
        r.base_gp = @bitCast(c.gst_util_uint64_scale_round(r.base_ts, @intCast(r.ctx.info.rate), SEC));
    } else if (r.base_gp < 0) r.base_gp = 0;
}

fn chain(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, buffer_in: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const e = of(parent_obj);
    const r = priv(e);
    const ctx = &r.ctx;
    var buffer = buffer_in;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    const fname = "gst_audio_encoder_chain";
    streamLock(e);
    defer streamUnlock(e);
    var negotiated = true;
    if (r.do_caps) {
        const caps = c.gst_pad_get_current_caps(e.*.sinkpad);
        if (caps == null) {
            negotiated = false;
        } else {
            const ok = sinkSetcaps(e, caps);
            c.gst_caps_unref(caps);
            if (ok == 0) negotiated = false else r.do_caps = false;
        }
    }
    if (!negotiated or ctx.info.bpf == 0) {
        post(e, .core, c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("encoder not initialized"), fname, 1427);
        c.gst_mini_object_unref(@ptrCast(buffer));
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    var size = c.gst_buffer_get_size(buffer);
    const bpf: c.gsize = @intCast(ctx.info.bpf);
    if (size % bpf != 0) {
        post(e, .stream, c.GST_STREAM_ERROR_ENCODE, null, c.g_strdup_printf("buffer size %lu not a multiple of %d", c.gst_buffer_get_size(buffer), ctx.info.bpf), fname, 1435);
        c.gst_mini_object_unref(@ptrCast(buffer));
        return c.GST_FLOW_ERROR;
    }
    var discont = buffer.*.mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0;
    if (discont) r.discont = true;
    buffer = clip.gst_audio_buffer_clip(buffer, &e.*.input_segment, ctx.info.rate, ctx.info.bpf);
    if (buffer == null) return ret;
    size = c.gst_buffer_get_size(buffer);
    if (r.base_ts == NONE) {
        r.base_ts = buffer.*.pts;
        setBaseGp(e);
    }
    if (r.perfect_ts != 0) {
        var dt: i64 = 0;
        var next: u64 = 0;
        const rate: u64 = @intCast(ctx.info.rate);
        if (buffer.*.pts != NONE and r.base_ts != NONE) {
            const smp = r.samples + c.gst_adapter_available(r.adapter) / bpf;
            next = r.base_ts +% c.gst_util_uint64_scale(smp, SEC, rate);
            dt = diff(next, buffer.*.pts);
            if (dt < -r.tolerance or dt > r.tolerance) discont = true;
        }
        if (discont and r.hard_resync != 0) {
            if (dt < 0) {
                const diff_bytes = c.gst_util_uint64_scale_round(@intCast(-dt), rate, SEC) * bpf;
                if (diff_bytes >= size) {
                    c.gst_mini_object_unref(@ptrCast(buffer));
                    return ret;
                }
                buffer = c.gst_buffer_make_writable(buffer);
                c.gst_buffer_resize(buffer, @intCast(diff_bytes), @intCast(size - diff_bytes));
                buffer.*.pts = buffer.*.pts +% @as(u64, @bitCast(dt));
            } else _ = drain(e);
        }
        if (discont) {
            const shift = c.gst_util_uint64_scale(c.gst_adapter_available(r.adapter), SEC, rate * bpf);
            if (shift > buffer.*.pts) {
                post(e, .stream, c.GST_STREAM_ERROR_ENCODE, null, c.g_strdup("buffer going too far back in time"), fname, 1444);
                c.gst_mini_object_unref(@ptrCast(buffer));
                return c.GST_FLOW_ERROR;
            }
            r.base_ts = buffer.*.pts - shift;
            r.samples = 0;
            setBaseGp(e);
            r.discont = r.discont or discont;
        }
    }
    c.gst_adapter_push(r.adapter, buffer);
    r.drained = false;
    ret = pushBuffers(e, false);
    return ret;
}

fn sinkSetcaps(e: [*c]Enc, caps: [*c]c.GstCaps) c.gboolean {
    const k = klass(e);
    if (!check.that(k.set_format != null, "gst_audio_encoder_sink_setcaps", "klass->set_format != NULL")) return 0;
    const r = priv(e);
    const ctx = &r.ctx;
    streamLock(e);
    defer streamUnlock(e);
    if (c.gst_caps_is_fixed(caps) == 0) return 1;
    if (ctx.input_caps != null and c.gst_caps_is_equal(ctx.input_caps, caps) != 0) return 1;
    var state: c.GstAudioInfo = undefined;
    if (info.gst_audio_info_from_caps(&state, caps) == 0) return 1;
    if (ctx.input_caps != null and info.gst_audio_info_is_equal(&state, &ctx.info) != 0) return 1;
    const old_rate = ctx.info.rate;
    if (r.base_ts != NONE and old_rate != 0) {
        r.base_ts +%= c.gst_util_uint64_scale_round(r.samples, SEC, @intCast(old_rate));
        r.samples = 0;
    }
    _ = drain(e);
    ctx.frame_samples_min = 0;
    ctx.frame_samples_max = 0;
    ctx.frame_max = 0;
    ctx.lookahead = 0;
    var res: c.gboolean = 1;
    if (k.set_format) |f| res = f(e, &state);
    if (res != 0) {
        el.lock(e);
        ctx.info = state;
        _ = c.gst_caps_replace(&ctx.input_caps, caps);
        el.unlock(e);
    } else info.gst_audio_info_init(&state);
    return res;
}

pub export fn gst_audio_encoder_proxy_getcaps(e: [*c]Enc, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    return utils.proxyGetcaps(e.*.sinkpad, e.*.srcpad, caps, filter);
}

fn getcapsDefault(e: [*c]Enc, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    return gst_audio_encoder_proxy_getcaps(e, null, filter);
}

fn flushEvents(pad: ?*c.GstPad, events: [*c]c.GList) [*c]c.GList {
    var l = events;
    while (l != null) : (l = l.*.next) {
        const ev: [*c]Event = @ptrCast(@alignCast(l.*.data));
        if (ev.*.type != c.GST_EVENT_EOS and ev.*.type != c.GST_EVENT_SEGMENT and ev.*.type & c.GST_EVENT_TYPE_STICKY != 0) _ = c.gst_pad_store_sticky_event(pad, ev);
        c.gst_mini_object_unref(@ptrCast(ev));
    }
    c.g_list_free(events);
    return null;
}

const STRIP = [_][*c]const u8{ c.GST_TAG_CODEC, c.GST_TAG_AUDIO_CODEC, c.GST_TAG_VIDEO_CODEC, c.GST_TAG_SUBTITLE_CODEC, c.GST_TAG_CONTAINER_FORMAT, c.GST_TAG_BITRATE, c.GST_TAG_NOMINAL_BITRATE, c.GST_TAG_MAXIMUM_BITRATE, c.GST_TAG_MINIMUM_BITRATE, c.GST_TAG_ENCODER, c.GST_TAG_ENCODER_VERSION };

fn sinkEventDefault(e: [*c]Enc, ev_in: [*c]Event) callconv(.c) c.gboolean {
    const r = priv(e);
    var ev = ev_in;
    switch (ev.*.type) {
        c.GST_EVENT_SEGMENT => {
            var seg: c.GstSegment = undefined;
            c.gst_event_copy_segment(ev, &seg);
            if (seg.format != c.GST_FORMAT_TIME) {
                c.gst_mini_object_unref(@ptrCast(ev));
                return 1;
            }
            streamLock(e);
            _ = drain(e);
            reset(e, false);
            e.*.input_segment = seg;
            r.early_pending_events = c.g_list_append(r.early_pending_events, ev);
            streamUnlock(e);
            return 1;
        },
        c.GST_EVENT_FLUSH_START => return pushEvent(e, ev),
        c.GST_EVENT_FLUSH_STOP => {
            streamLock(e);
            if (!r.drained) if (klass(e).flush) |f| f(e);
            reset(e, false);
            r.pending_events = flushEvents(e.*.srcpad, r.pending_events);
            streamUnlock(e);
            return pushEvent(e, ev);
        },
        c.GST_EVENT_EOS => {
            streamLock(e);
            _ = drain(e);
            pushPending(e);
            pushTags(e);
            streamUnlock(e);
            return pushEvent(e, ev);
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            r.do_caps = true;
            c.gst_mini_object_unref(@ptrCast(ev));
            return 1;
        },
        c.GST_EVENT_STREAM_START => {
            streamLock(e);
            if (r.upstream_tags) |t| {
                c.gst_mini_object_unref(@ptrCast(t));
                r.upstream_tags = null;
                r.tags_changed = true;
            }
            streamUnlock(e);
            return pushEvent(e, ev);
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(ev, @ptrCast(&tags));
            if (c.gst_tag_list_get_scope(tags) == c.GST_TAG_SCOPE_STREAM) {
                streamLock(e);
                if (r.upstream_tags != tags) {
                    const copy = c.gst_tag_list_copy(tags);
                    for (STRIP) |t| c.gst_tag_list_remove_tag(copy, t);
                    if (r.upstream_tags) |old| c.gst_mini_object_unref(@ptrCast(old));
                    r.upstream_tags = copy;
                }
                c.gst_mini_object_unref(@ptrCast(ev));
                ev = mergedTags(e);
                streamUnlock(e);
                if (ev == null) return 1;
            }
        },
        else => {},
    }
    if (ev.*.type & c.GST_EVENT_TYPE_SERIALIZED == 0) return c.gst_pad_event_default(e.*.sinkpad, @ptrCast(e), ev);
    streamLock(e);
    if (c.gst_adapter_available(r.adapter) == 0) {
        r.early_pending_events = c.g_list_append(r.early_pending_events, ev);
    } else r.pending_events = c.g_list_append(r.pending_events, ev);
    streamUnlock(e);
    return 1;
}

fn sinkEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    if (klass(e).sink_event) |f| return f(e, ev);
    c.gst_mini_object_unref(@ptrCast(ev));
    return 0;
}

fn sinkQueryDefault(e: [*c]Enc, q: [*c]Query) callconv(.c) c.gboolean {
    const r = priv(e);
    switch (q.*.type) {
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
            el.lock(e);
            const ok = info.gst_audio_info_convert(&r.ctx.info, sf, sv, df, &dv);
            el.unlock(e);
            if (ok == 0) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_CAPS => {
            const f = klass(e).getcaps orelse return 0;
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            const caps = f(e, filter);
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ALLOCATION => return if (klass(e).propose_allocation) |f| f(e, q) else 0,
        else => return c.gst_pad_query_default(e.*.sinkpad, @ptrCast(e), q),
    }
}

fn sinkQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    return if (klass(e).sink_query) |f| f(e, q) else 0;
}

fn srcEventDefault(e: [*c]Enc, ev: [*c]Event) callconv(.c) c.gboolean {
    return c.gst_pad_event_default(e.*.srcpad, @ptrCast(e), ev);
}

fn srcEvent(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, ev: [*c]Event) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    if (klass(e).src_event) |f| return f(e, ev);
    c.gst_mini_object_unref(@ptrCast(ev));
    return 0;
}

fn decideAllocationDefault(_: [*c]Enc, q: [*c]Query) callconv(.c) c.gboolean {
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

fn proposeAllocationDefault(_: [*c]Enc, _: [*c]Query) callconv(.c) c.gboolean {
    return 1;
}

fn peerConvert(e: [*c]Enc, q: [*c]Query, comptime position: bool) c.gboolean {
    if (c.gst_pad_peer_query(e.*.sinkpad, q) != 0) return 1;
    var req: c.GstFormat = 0;
    if (position) c.gst_query_parse_position(q, &req, null) else c.gst_query_parse_duration(q, &req, null);
    if (req == c.GST_FORMAT_BYTES) return 0;
    var v: i64 = 0;
    const ok = if (position) c.gst_pad_peer_query_position(e.*.sinkpad, c.GST_FORMAT_TIME, &v) else c.gst_pad_peer_query_duration(e.*.sinkpad, c.GST_FORMAT_TIME, &v);
    if (ok == 0) return 0;
    var val: i64 = 0;
    const res = c.gst_pad_peer_query_convert(e.*.sinkpad, c.GST_FORMAT_TIME, v, req, &val);
    if (res != 0) {
        if (position) c.gst_query_set_position(q, req, val) else c.gst_query_set_duration(q, req, val);
    }
    return res;
}

fn srcQueryDefault(e: [*c]Enc, q: [*c]Query) callconv(.c) c.gboolean {
    const r = priv(e);
    switch (q.*.type) {
        c.GST_QUERY_POSITION => return peerConvert(e, q, true),
        c.GST_QUERY_DURATION => return peerConvert(e, q, false),
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
            el.lock(e);
            const ok = utils.encodedConvert(&r.ctx.info, @bitCast(r.bytes_out), @bitCast(r.samples_in), sf, sv, &df, &dv);
            el.unlock(e);
            if (!ok) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_LATENCY => {
            const res = c.gst_pad_peer_query(e.*.sinkpad, q);
            if (res != 0) {
                var live: c.gboolean = 0;
                var mn: u64 = 0;
                var mx: u64 = 0;
                c.gst_query_parse_latency(q, &live, &mn, &mx);
                el.lock(e);
                mn +%= r.ctx.min_latency;
                mx = if (mx == NONE or r.ctx.max_latency == NONE) NONE else mx +% r.ctx.max_latency;
                el.unlock(e);
                c.gst_query_set_latency(q, live, mn, mx);
            }
            return res;
        },
        else => return c.gst_pad_query_default(e.*.srcpad, @ptrCast(e), q),
    }
}

fn srcQuery(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, q: [*c]Query) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    return if (klass(e).src_query) |f| f(e, q) else 0;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const r = priv(o);
    switch (id) {
        1 => if (!(r.granule != 0 and c.g_value_get_boolean(v) == 0)) {
            r.perfect_ts = c.g_value_get_boolean(v);
        },
        3 => r.hard_resync = c.g_value_get_boolean(v),
        4 => r.tolerance = c.g_value_get_int64(v),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 2109),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const r = priv(o);
    switch (id) {
        1 => c.g_value_set_boolean(v, r.perfect_ts),
        2 => c.g_value_set_boolean(v, r.granule),
        3 => c.g_value_set_boolean(v, r.hard_resync),
        4 => c.g_value_set_int64(v, r.tolerance),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 2136),
    }
}

fn activate(e: [*c]Enc, active: bool) bool {
    const r = priv(e);
    const k = klass(e);
    if (!check.that(r.granule == 0 or r.perfect_ts != 0, "gst_audio_encoder_activate", "!enc->priv->granule || enc->priv->perfect_ts")) return false;
    var result = true;
    if (active) {
        reset(e, true);
        if (!r.active) if (k.start) |f| {
            result = f(e) != 0;
        };
    } else {
        el.streamLock(e.*.sinkpad);
        el.streamUnlock(e.*.sinkpad);
        if (r.active) if (k.stop) |f| {
            result = f(e) != 0;
        };
        reset(e, true);
    }
    return result;
}

fn sinkActivateMode(_: ?*c.GstPad, parent_obj: [*c]c.GstObject, _: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const e = of(parent_obj);
    const result = activate(e, active != 0);
    if (result) priv(e).active = active != 0;
    return @intFromBool(result);
}

fn changeState(el_: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const e = of(el_);
    const k = klass(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY) if (k.open) |f| if (f(e) == 0) {
        post(e, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to open codec"), "gst_audio_encoder_change_state", 589);
        return c.GST_STATE_CHANGE_FAILURE;
    };
    const ret = parent.?.change_state.?(el_, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) if (k.close) |f| if (f(e) == 0) {
        post(e, .library, c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup("Failed to close codec"), "gst_audio_encoder_change_state", 594);
        return c.GST_STATE_CHANGE_FAILURE;
    };
    return ret;
}

fn negotiateDefault(e: [*c]Enc) callconv(.c) c.gboolean {
    const fname = "gst_audio_encoder_negotiate_default";
    if (!check.that(isEnc(e), fname, "GST_IS_AUDIO_ENCODER (enc)")) return 0;
    const r = priv(e);
    if (!check.that(r.ctx.caps != null and r.ctx.caps.*.mini_object.type == c.gst_caps_get_type(), fname, "GST_IS_CAPS (enc->priv->ctx.caps)")) return 0;
    const caps = r.ctx.caps;
    if (r.ctx.allocation_caps == null) r.ctx.allocation_caps = c.gst_caps_ref(caps);
    var l = r.early_pending_events;
    while (l != null) {
        const ev: [*c]Event = @ptrCast(@alignCast(l.*.data));
        if (ev.*.type < c.GST_EVENT_CAPS) {
            _ = pushEvent(e, ev);
            const tmp = l;
            l = l.*.next;
            r.early_pending_events = c.g_list_delete_link(r.early_pending_events, tmp);
        } else l = l.*.next;
    }
    var res = true;
    const prev = c.gst_pad_get_current_caps(e.*.srcpad);
    if (prev == null or c.gst_caps_is_equal(prev, caps) == 0) res = el.padSetCaps(e.*.srcpad, caps);
    if (prev != null) c.gst_caps_unref(prev);
    if (!res) return 0;
    r.ctx.output_caps_changed = false;
    const q = c.gst_query_new_allocation(r.ctx.allocation_caps, 1);
    defer c.gst_query_unref(q);
    _ = c.gst_pad_peer_query(e.*.srcpad, q);
    if (klass(e).decide_allocation.?(e, q) == 0) return 0;
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_query_get_n_allocation_params(q) > 0) c.gst_query_parse_nth_allocation_param(q, 0, &allocator, &params) else c.gst_allocation_params_init(&params);
    if (r.ctx.allocator != null) c.gst_object_unref(r.ctx.allocator);
    r.ctx.allocator = allocator;
    r.ctx.params = params;
    return 1;
}

pub export fn gst_audio_encoder_negotiate(e: [*c]Enc) c.gboolean {
    if (!check.that(isEnc(e), "gst_audio_encoder_negotiate", "GST_IS_AUDIO_ENCODER (enc)")) return 0;
    var ret: c.gboolean = 1;
    streamLock(e);
    _ = c.gst_pad_check_reconfigure(e.*.srcpad);
    if (klass(e).negotiate) |f| {
        ret = f(e);
        if (ret == 0) c.gst_pad_mark_reconfigure(e.*.srcpad);
    }
    streamUnlock(e);
    return ret;
}

pub export fn gst_audio_encoder_set_output_format(e: [*c]Enc, caps: [*c]c.GstCaps) c.gboolean {
    streamLock(e);
    defer streamUnlock(e);
    if (c.gst_caps_is_fixed(caps) == 0) return 0;
    const templ = c.gst_pad_get_pad_template_caps(e.*.srcpad);
    const subset = c.gst_caps_is_subset(caps, templ);
    c.gst_caps_unref(templ);
    if (subset == 0) return 0;
    _ = c.gst_caps_replace(&priv(e).ctx.caps, caps);
    priv(e).ctx.output_caps_changed = true;
    return 1;
}

pub export fn gst_audio_encoder_allocate_output_buffer(e: [*c]Enc, size: c.gsize) [*c]Buffer {
    if (!check.that(size > 0, "gst_audio_encoder_allocate_output_buffer", "size > 0")) return null;
    const r = priv(e);
    streamLock(e);
    defer streamUnlock(e);
    const needs = c.gst_pad_check_reconfigure(e.*.srcpad) != 0;
    if (r.ctx.output_caps_changed or (r.ctx.caps != null and needs)) {
        if (!negotiateUnlocked(e)) {
            c.gst_pad_mark_reconfigure(e.*.srcpad);
            return c.gst_buffer_new_allocate(null, size, null);
        }
    }
    const b = c.gst_buffer_new_allocate(r.ctx.allocator, size, &r.ctx.params);
    return if (b != null) b else c.gst_buffer_new_allocate(null, size, null);
}

pub export fn gst_audio_encoder_get_allocator(e: [*c]Enc, allocator: [*c][*c]c.GstAllocator, params: [*c]c.GstAllocationParams) void {
    if (!check.that(isEnc(e), "gst_audio_encoder_get_allocator", "GST_IS_AUDIO_ENCODER (enc)")) return;
    const r = priv(e);
    if (allocator != null) allocator.* = if (r.ctx.allocator != null) @ptrCast(@alignCast(c.gst_object_ref(r.ctx.allocator))) else null;
    if (params != null) params.* = r.ctx.params;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const e = of(o);
    c.g_object_unref(priv(e).adapter);
    c.g_rec_mutex_clear(&e.*.stream_lock);
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("audioencoder", 0, "audio encoder base class");
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const F = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_boolean("perfect-timestamp", "Perfect Timestamps", "Favour perfect timestamps over tracking upstream timestamps", 0, F));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_boolean("mark-granule", "Granule Marking", "Apply granule semantics to buffer metadata (implies perfect-timestamp)", 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, 3, c.g_param_spec_boolean("hard-resync", "Hard Resync", "Perform clipping and sample flushing upon discontinuity", 0, F));
    c.g_object_class_install_property(oc, 4, c.g_param_spec_int64("tolerance", "Tolerance", "Consider discontinuity if timestamp jitter/imperfection exceeds tolerance (ns)", 0, std.math.maxInt(i64), DEFAULT_TOLERANCE, F));
    @as(*c.GstElementClass, @ptrCast(@alignCast(k))).change_state = changeState;
    const ec: *Class = @ptrCast(@alignCast(k));
    ec.getcaps = getcapsDefault;
    ec.sink_event = sinkEventDefault;
    ec.src_event = srcEventDefault;
    ec.sink_query = sinkQueryDefault;
    ec.src_query = srcQueryDefault;
    ec.propose_allocation = proposeAllocationDefault;
    ec.decide_allocation = decideAllocationDefault;
    ec.negotiate = negotiateDefault;
    ec.transform_meta = transformMetaDefault;
    _ = c.g_quark_from_static_string("audio");
}

fn init(inst: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const e = of(inst);
    e.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    const r = priv(e);
    r.* = std.mem.zeroes(Private);
    const gc: [*c]c.GstElementClass = @ptrCast(@alignCast(g_class));
    var templ = c.gst_element_class_get_pad_template(gc, "sink");
    if (!check.that(templ != null, "gst_audio_encoder_init", "pad_template != NULL")) return;
    e.*.sinkpad = c.gst_pad_new_from_template(templ, "sink");
    c.gst_pad_set_event_function_full(e.*.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(e.*.sinkpad, sinkQuery, null, null);
    c.gst_pad_set_chain_function_full(e.*.sinkpad, chain, null, null);
    c.gst_pad_set_activatemode_function_full(e.*.sinkpad, sinkActivateMode, null, null);
    _ = c.gst_element_add_pad(@ptrCast(e), e.*.sinkpad);
    templ = c.gst_element_class_get_pad_template(gc, "src");
    if (!check.that(templ != null, "gst_audio_encoder_init", "pad_template != NULL")) return;
    e.*.srcpad = c.gst_pad_new_from_template(templ, "src");
    c.gst_pad_set_event_function_full(e.*.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(e.*.srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(e), e.*.srcpad);
    r.adapter = c.gst_adapter_new();
    c.g_rec_mutex_init(&e.*.stream_lock);
    r.tolerance = DEFAULT_TOLERANCE;
    r.drainable = 1;
    reset(e, true);
}

pub export fn gst_audio_encoder_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstAudioEncoder", Class, Enc, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            const iface = std.mem.zeroes(c.GInterfaceInfo);
            c.g_type_add_interface_static(t, c.gst_preset_get_type(), &iface);
            return t;
        }
    }.f);
}

pub export fn gst_audio_encoder_get_audio_info(e: [*c]Enc) [*c]c.GstAudioInfo {
    if (!check.that(isEnc(e), "gst_audio_encoder_get_audio_info", "GST_IS_AUDIO_ENCODER (enc)")) return null;
    return &priv(e).ctx.info;
}

fn ctxSetter(comptime field: []const u8, comptime name: []const u8) fn ([*c]Enc, c.gint) callconv(.c) void {
    return struct {
        fn f(e: [*c]Enc, num: c.gint) callconv(.c) void {
            if (!check.that(isEnc(e), name, "GST_IS_AUDIO_ENCODER (enc)")) return;
            @field(priv(e).ctx, field) = num;
        }
    }.f;
}

fn ctxGetter(comptime field: []const u8, comptime name: []const u8) fn ([*c]Enc) callconv(.c) c.gint {
    return struct {
        fn f(e: [*c]Enc) callconv(.c) c.gint {
            if (!check.that(isEnc(e), name, "GST_IS_AUDIO_ENCODER (enc)")) return 0;
            return @field(priv(e).ctx, field);
        }
    }.f;
}

comptime {
    @export(&ctxSetter("frame_samples_min", "gst_audio_encoder_set_frame_samples_min"), .{ .name = "gst_audio_encoder_set_frame_samples_min" });
    @export(&ctxGetter("frame_samples_min", "gst_audio_encoder_get_frame_samples_min"), .{ .name = "gst_audio_encoder_get_frame_samples_min" });
    @export(&ctxSetter("frame_samples_max", "gst_audio_encoder_set_frame_samples_max"), .{ .name = "gst_audio_encoder_set_frame_samples_max" });
    @export(&ctxGetter("frame_samples_max", "gst_audio_encoder_get_frame_samples_max"), .{ .name = "gst_audio_encoder_get_frame_samples_max" });
    @export(&ctxSetter("frame_max", "gst_audio_encoder_set_frame_max"), .{ .name = "gst_audio_encoder_set_frame_max" });
    @export(&ctxGetter("frame_max", "gst_audio_encoder_get_frame_max"), .{ .name = "gst_audio_encoder_get_frame_max" });
    @export(&ctxSetter("lookahead", "gst_audio_encoder_set_lookahead"), .{ .name = "gst_audio_encoder_set_lookahead" });
    @export(&ctxGetter("lookahead", "gst_audio_encoder_get_lookahead"), .{ .name = "gst_audio_encoder_get_lookahead" });
}

pub export fn gst_audio_encoder_set_latency(e: [*c]Enc, min: c.GstClockTime, max: c.GstClockTime) void {
    const fname = "gst_audio_encoder_set_latency";
    if (!check.that(isEnc(e), fname, "GST_IS_AUDIO_ENCODER (enc)")) return;
    if (!check.that(min != NONE, fname, "GST_CLOCK_TIME_IS_VALID (min)")) return;
    if (!check.that(min <= max, fname, "min <= max")) return;
    const r = priv(e);
    var post_msg = false;
    el.lock(e);
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
    el.unlock(e);
    if (post_msg) _ = c.gst_element_post_message(@ptrCast(e), c.gst_message_new_latency(@ptrCast(e)));
}

pub export fn gst_audio_encoder_get_latency(e: [*c]Enc, min: [*c]c.GstClockTime, max: [*c]c.GstClockTime) void {
    if (!check.that(isEnc(e), "gst_audio_encoder_get_latency", "GST_IS_AUDIO_ENCODER (enc)")) return;
    el.lock(e);
    if (min != null) min.* = priv(e).ctx.min_latency;
    if (max != null) max.* = priv(e).ctx.max_latency;
    el.unlock(e);
}

pub export fn gst_audio_encoder_set_headers(e: [*c]Enc, headers: [*c]c.GList) void {
    const r = priv(e);
    if (r.ctx.headers != null) {
        c.g_list_foreach(r.ctx.headers, unrefOne, null);
        c.g_list_free(r.ctx.headers);
    }
    r.ctx.headers = headers;
    r.ctx.new_headers = true;
}

pub export fn gst_audio_encoder_set_allocation_caps(e: [*c]Enc, caps: [*c]c.GstCaps) void {
    if (!check.that(isEnc(e), "gst_audio_encoder_set_allocation_caps", "GST_IS_AUDIO_ENCODER (enc)")) return;
    _ = c.gst_caps_replace(&priv(e).ctx.allocation_caps, caps);
}

fn boolSetter(comptime field: []const u8, comptime name: []const u8) fn ([*c]Enc, c.gboolean) callconv(.c) void {
    return struct {
        fn f(e: [*c]Enc, enabled: c.gboolean) callconv(.c) void {
            if (!check.that(isEnc(e), name, "GST_IS_AUDIO_ENCODER (enc)")) return;
            el.lock(e);
            @field(priv(e), field) = enabled;
            el.unlock(e);
        }
    }.f;
}

fn boolGetter(comptime field: []const u8, comptime name: []const u8) fn ([*c]Enc) callconv(.c) c.gboolean {
    return struct {
        fn f(e: [*c]Enc) callconv(.c) c.gboolean {
            if (!check.that(isEnc(e), name, "GST_IS_AUDIO_ENCODER (enc)")) return 0;
            el.lock(e);
            defer el.unlock(e);
            return @field(priv(e), field);
        }
    }.f;
}

comptime {
    @export(&boolSetter("granule", "gst_audio_encoder_set_mark_granule"), .{ .name = "gst_audio_encoder_set_mark_granule" });
    @export(&boolGetter("granule", "gst_audio_encoder_get_mark_granule"), .{ .name = "gst_audio_encoder_get_mark_granule" });
    @export(&boolSetter("perfect_ts", "gst_audio_encoder_set_perfect_timestamp"), .{ .name = "gst_audio_encoder_set_perfect_timestamp" });
    @export(&boolGetter("perfect_ts", "gst_audio_encoder_get_perfect_timestamp"), .{ .name = "gst_audio_encoder_get_perfect_timestamp" });
    @export(&boolSetter("hard_resync", "gst_audio_encoder_set_hard_resync"), .{ .name = "gst_audio_encoder_set_hard_resync" });
    @export(&boolGetter("hard_resync", "gst_audio_encoder_get_hard_resync"), .{ .name = "gst_audio_encoder_get_hard_resync" });
    @export(&boolSetter("hard_min", "gst_audio_encoder_set_hard_min"), .{ .name = "gst_audio_encoder_set_hard_min" });
    @export(&boolGetter("hard_min", "gst_audio_encoder_get_hard_min"), .{ .name = "gst_audio_encoder_get_hard_min" });
    @export(&boolSetter("drainable", "gst_audio_encoder_set_drainable"), .{ .name = "gst_audio_encoder_set_drainable" });
    @export(&boolGetter("drainable", "gst_audio_encoder_get_drainable"), .{ .name = "gst_audio_encoder_get_drainable" });
}

pub export fn gst_audio_encoder_set_tolerance(e: [*c]Enc, tolerance: c.GstClockTime) void {
    if (!check.that(isEnc(e), "gst_audio_encoder_set_tolerance", "GST_IS_AUDIO_ENCODER (enc)")) return;
    if (!check.that(tolerance != NONE, "gst_audio_encoder_set_tolerance", "GST_CLOCK_TIME_IS_VALID (tolerance)")) return;
    el.lock(e);
    priv(e).tolerance = @bitCast(tolerance);
    el.unlock(e);
}

pub export fn gst_audio_encoder_get_tolerance(e: [*c]Enc) c.GstClockTime {
    if (!check.that(isEnc(e), "gst_audio_encoder_get_tolerance", "GST_IS_AUDIO_ENCODER (enc)")) return 0;
    el.lock(e);
    defer el.unlock(e);
    return @bitCast(priv(e).tolerance);
}

pub export fn gst_audio_encoder_merge_tags(e: [*c]Enc, tags: ?*const c.GstTagList, mode: c.GstTagMergeMode) void {
    const fname = "gst_audio_encoder_merge_tags";
    if (!check.that(isEnc(e), fname, "GST_IS_AUDIO_ENCODER (enc)")) return;
    if (!check.that(tags == null or @as([*c]const c.GstMiniObject, @ptrCast(tags)).*.type == c.gst_tag_list_get_type(), fname, "tags == NULL || GST_IS_TAG_LIST (tags)")) return;
    if (!check.that(tags == null or mode != c.GST_TAG_MERGE_UNDEFINED, fname, "tags == NULL || mode != GST_TAG_MERGE_UNDEFINED")) return;
    const r = priv(e);
    streamLock(e);
    if (@as(?*const c.GstTagList, r.tags) != tags) {
        if (r.tags) |t| {
            c.gst_mini_object_unref(@ptrCast(t));
            r.tags = null;
            r.tags_mode = c.GST_TAG_MERGE_APPEND;
        }
        if (tags) |t| {
            r.tags = @ptrCast(c.gst_mini_object_ref(@ptrCast(@constCast(t))));
            r.tags_mode = mode;
        }
        r.tags_changed = true;
    }
    streamUnlock(e);
}
