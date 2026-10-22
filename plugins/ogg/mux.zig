const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const os = @import("stream.zig");
const demux = @import("demux.zig");

const FILE = "../ext/ogg/gstoggmux.c";
const NONE = cm.CLOCK_NONE;
const SECOND: u64 = 1_000_000_000;

const STATE_CONTROL = 0;
const STATE_DATA = 1;

const PadData = extern struct {
    collect: c.GstCollectData,
    map: os.Stream,
    have_type: c.gboolean,
    segment: c.GstSegment,
    buffer: [*c]c.GstBuffer,
    packetno: i64,
    pageno: i64,
    duration: u64,
    eos: c.gboolean,
    offset: i64,
    timestamp: u64,
    timestamp_end: u64,
    gp_time: u64,
    state: c_int,
    pagebuffers: ?*c.GQueue,
    new_page: c.gboolean,
    first_delta: c.gboolean,
    prev_delta: c.gboolean,
    data_pushed: c.gboolean,
    next_granule: i64,
    keyframe_granule: i64,
    tags: ?*c.GstTagList,
};

const Mux = extern struct {
    element: c.GstElement,
    srcpad: ?*c.GstPad,
    collect: ?*c.GstCollectPads,
    active_pads: c.gint,
    pulling: ?*PadData,
    next_ts: u64,
    last_ts: u64,
    offset: u64,
    need_headers: c.gboolean,
    need_start_events: c.gboolean,
    max_delay: u64,
    max_page_delay: u64,
    max_tolerance: u64,
    delta_pad: ?*PadData,
    use_skeleton: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "application/ogg; audio/ogg; video/ogg");
var video_t = cm.staticTemplate("video_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "video/x-theora; application/x-ogm-video; video/x-dirac; video/x-smoke; video/x-vp8; video/x-daala");
var audio_t = cm.staticTemplate("audio_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "audio/x-vorbis; audio/x-flac; audio/x-speex; audio/x-celt; application/x-ogm-audio; audio/x-opus");
var sub_t = cm.staticTemplate("subtitle_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "text/x-cmml, encoded = (boolean) TRUE; subtitle/x-kate; application/x-kate");
var once: cm.Once = .{};
var parent_class: ?*c.GstElementClass = null;

fn me(p: anytype) *Mux {
    return @ptrCast(@alignCast(p));
}

fn pads(m: *Mux) [*c]c.GSList {
    return m.collect.?.data;
}

fn padOf(l: [*c]c.GSList) *PadData {
    return @ptrCast(@alignCast(l.*.data));
}

fn endTime(b: [*c]c.GstBuffer) u64 {
    const x = cm.buf(b);
    return if (x.duration != NONE) x.pts +% x.duration else x.pts;
}

fn clear(m: *Mux) void {
    m.pulling = null;
    m.need_headers = 1;
    m.need_start_events = 1;
    m.delta_pad = null;
    m.offset = 0;
    m.next_ts = 0;
    m.last_ts = NONE;
}

fn finalize(ob: [*c]c.GObject) callconv(.c) void {
    const m = me(ob);
    if (m.collect) |col| c.gst_object_unref(col);
    m.collect = null;
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).finalize.?(ob);
}

fn padDestroy(data: [*c]c.GstCollectData) callconv(.c) void {
    const p: *PadData = @ptrCast(@alignCast(data));
    _ = c.ogg_stream_clear(&p.map.stream);
    _ = c.gst_caps_replace(&p.map.caps, null);
    if (p.pagebuffers) |q| {
        while (c.g_queue_pop_head(q)) |b| c.gst_buffer_unref(@ptrCast(@alignCast(b)));
        c.g_queue_free(q);
        p.pagebuffers = null;
    }
}

fn sinkConnect(_: ?*c.GstPad, _: [*c]c.GstObject, _: ?*c.GstPad) callconv(.c) c.GstPadLinkReturn {
    return c.GST_PAD_LINK_OK;
}

fn flush(m: *Mux) void {
    var l = pads(m);
    while (l != null) : (l = l.*.next) padReset(m, padOf(l));
    clear(m);
}

fn sinkEvent(cp: ?*c.GstCollectPads, data: [*c]c.GstCollectData, ev0: [*c]c.GstEvent, user: c.gpointer) callconv(.c) c.gboolean {
    const m = me(user);
    const p: *PadData = @ptrCast(@alignCast(data));
    var ev = ev0;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(ev, &seg);
            if (seg.*.format != c.GST_FORMAT_TIME) {
                c.gst_event_unref(ev);
                ev = null;
            } else c.gst_segment_copy_into(seg, &p.segment);
        },
        c.GST_EVENT_FLUSH_STOP => flush(m),
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(ev, &tags);
            const merged = c.gst_tag_list_merge(p.tags, tags, c.GST_TAG_MERGE_APPEND);
            if (p.tags) |t| c.gst_tag_list_unref(t);
            p.tags = merged;
        },
        else => {},
    }
    if (ev != null) return c.gst_collect_pads_event_default(cp, data, ev, 0);
    return 1;
}

fn serialPresent(m: *Mux, serial: u32) bool {
    var l = pads(m);
    while (l != null) : (l = l.*.next) {
        if (padOf(l).map.serialno == serial) return true;
    }
    return false;
}

fn padReset(m: *Mux, p: *PadData) void {
    p.packetno = 0;
    p.pageno = 0;
    p.eos = 0;
    p.state = STATE_CONTROL;
    p.new_page = 1;
    p.first_delta = 0;
    p.prev_delta = 0;
    p.data_pushed = 0;
    p.map.headers = null;
    p.map.queued = null;
    p.next_granule = 0;
    p.keyframe_granule = -1;
    _ = c.ogg_stream_clear(&p.map.stream);
    _ = c.ogg_stream_init(&p.map.stream, @bitCast(p.map.serialno));
    if (p.pagebuffers) |q| {
        while (c.g_queue_pop_head(q)) |b| c.gst_buffer_unref(@ptrCast(@alignCast(b)));
    } else if (m.element.current_state > c.GST_STATE_READY) p.pagebuffers = c.g_queue_new();
    c.gst_segment_init(&p.segment, c.GST_FORMAT_TIME);
}

fn generateSerial(m: *Mux) u32 {
    while (true) {
        const s: u32 = @bitCast(c.g_random_int_range(0, std.math.maxInt(i32)));
        if (!serialPresent(m, s)) return s;
    }
}

fn requestPad(el: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, _: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    if (!cm.that(templ != null, "gst_ogg_mux_request_new_pad", "templ != NULL")) return null;
    if (templ.*.direction != c.GST_PAD_SINK) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "ogg_mux: request pad that is not a SINK pad\n");
        return null;
    }
    const m = me(el);
    const k: *c.GstElementClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(el))).g_class));
    const vt = c.gst_element_class_get_pad_template(k, "video_%u");
    const at = c.gst_element_class_get_pad_template(k, "audio_%u");
    const st = c.gst_element_class_get_pad_template(k, "subtitle_%u");
    if (templ != vt and templ != at and templ != st) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "ogg_mux: this is not our template!\n");
        return null;
    }
    var serial: u32 = 0;
    if (name == null or std.mem.len(name) < 6) {
        serial = generateSerial(m);
    } else {
        var end: [*c]u8 = null;
        const v = c.strtoul(name + 5, &end, 10);
        if ((end != null and end[0] != 0) or (v & ~@as(c_ulong, 0xffffffff)) != 0) return null;
        serial = @truncate(v);
    }
    const pname = if (templ == vt) c.g_strdup_printf("video_%u", serial) else if (templ == at) c.g_strdup_printf("audio_%u", serial) else c.g_strdup_printf("subtitle_%u", serial);
    const pad = c.gst_pad_new_from_template(templ, pname);
    c.g_free(pname);
    const p: *PadData = @ptrCast(@alignCast(c.gst_collect_pads_add_pad(m.collect, pad, @sizeOf(PadData), padDestroy, 0)));
    m.active_pads += 1;
    p.map.serialno = serial;
    padReset(m, p);
    c.gst_pad_set_link_function_full(pad, sinkConnect, null, null);
    _ = c.gst_element_add_pad(el, pad);
    return pad;
}

fn releasePad(el: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const m: *Mux = @ptrCast(@alignCast(c.gst_pad_get_parent(pad)));
    _ = c.gst_collect_pads_remove_pad(m.collect, pad);
    _ = c.gst_element_remove_pad(el, pad);
    c.gst_object_unref(m);
}

fn srcEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev0: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const m = me(parent);
    var ev = ev0;
    if (cm.eventType(ev) == c.GST_EVENT_SEEK) {
        var flags: c.GstSeekFlags = 0;
        c.gst_event_parse_seek(ev, null, null, &flags, null, null, null, null);
        if (m.need_headers == 0 and flags & c.GST_SEEK_FLAG_FLUSH != 0) {
            c.gst_event_unref(ev);
            ev = null;
        }
    }
    if (ev != null) return c.gst_pad_event_default(pad, parent, ev);
    return 0;
}

fn bufferFromPage(page: *c.ogg_page, delta: bool) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, @intCast(page.header_len + page.body_len), null);
    _ = c.gst_buffer_fill(b, 0, page.header, @intCast(page.header_len));
    _ = c.gst_buffer_fill(b, @intCast(page.header_len), page.body, @intCast(page.body_len));
    cm.buf(b).offset_end = @bitCast(c.ogg_page_granulepos(page));
    if (delta) cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
    return b;
}

fn pushBuffer(m: *Mux, b: [*c]c.GstBuffer) c.GstFlowReturn {
    const x = cm.buf(b);
    x.offset = m.offset;
    m.offset += c.gst_buffer_get_size(b);
    x.offset_end = m.offset;
    if (x.pts != NONE) {
        const rt = x.pts;
        if (m.last_ts != NONE and rt < m.last_ts) {
            x.pts = m.last_ts;
        } else m.last_ts = rt;
    }
    return c.gst_pad_push(m.srcpad, b);
}

fn dequeuePage(m: *Mux, flowret: *c.GstFlowReturn) bool {
    var opad: ?*PadData = null;
    var oldest: u64 = NONE;
    var ret = false;
    flowret.* = c.GST_FLOW_OK;
    var l = pads(m);
    while (l != null) : (l = l.*.next) {
        const p = padOf(l);
        const q = p.pagebuffers.?;
        if (q.length == 0) {
            if (p.eos == 0) return false;
        } else {
            var valid = false;
            var w = q.head;
            while (w != null) : (w = w.*.next) {
                if (cm.buf(w.*.data).offset_end != NONE) {
                    valid = true;
                    break;
                }
            }
            if (!valid) return false;
        }
    }
    l = pads(m);
    while (l != null) : (l = l.*.next) {
        const p = padOf(l);
        var b: [*c]c.GstBuffer = @ptrCast(@alignCast(c.g_queue_peek_head(p.pagebuffers)));
        while (b != null and cm.buf(b).offset_end == NONE) {
            _ = c.g_queue_pop_head(p.pagebuffers);
            flowret.* = pushBuffer(m, b);
            b = @ptrCast(@alignCast(c.g_queue_peek_head(p.pagebuffers)));
            ret = true;
        }
        if (b != null) {
            if (oldest == NONE or cm.buf(b).offset < oldest) {
                oldest = cm.buf(b).offset;
                opad = p;
            }
        }
    }
    if (oldest != NONE) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(c.g_queue_pop_head(opad.?.pagebuffers)));
        flowret.* = pushBuffer(m, b);
        ret = true;
    }
    return ret;
}

fn queuePage(m: *Mux, p: *PadData, page: *c.ogg_page, delta: bool) c.GstFlowReturn {
    const b = bufferFromPage(page, delta);
    cm.buf(b).pts = p.timestamp;
    cm.buf(b).duration = p.timestamp_end -% p.timestamp;
    cm.buf(b).offset = p.gp_time;
    p.timestamp = p.timestamp_end;
    c.g_queue_push_tail(p.pagebuffers, b);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    while (dequeuePage(m, &ret)) {
        if (ret != c.GST_FLOW_OK) break;
    }
    return ret;
}

fn comparePads(first: ?*PadData, second: *PadData) i32 {
    const f = first orelse return 1;
    const ft = cm.buf(f.buffer).pts;
    if (ft == NONE) return -1;
    const st = cm.buf(second.buffer).pts;
    if (st == NONE) return 1;
    if (st < ft) return 1;
    if (st > ft) return -1;
    if (second.pageno < f.pageno) return 1;
    if (second.pageno > f.pageno) return -1;
    return 0;
}

fn decorate(m: *Mux, p: *PadData, b0: [*c]c.GstBuffer) [*c]c.GstBuffer {
    const b: [*c]c.GstBuffer = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(b0)));
    var time = cm.buf(b).pts;
    if (time != NONE) {
        time = c.gst_segment_to_running_time(&p.segment, c.GST_FORMAT_TIME, time);
        if (time == NONE) {
            c.gst_buffer_unref(b);
            return null;
        }
        cm.buf(b).pts = time;
    }
    if (p.have_type == 0 or p.map.granulerate_n <= 0 or p.map.granulerate_d <= 0) return b;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    var pk = std.mem.zeroes(os.Packet);
    pk.packet = map.data;
    pk.bytes = @intCast(map.size);
    os.updateStats(&p.map, &pk);
    var duration = os.packetDuration(&p.map, &pk);
    c.gst_buffer_unmap(b, &map);
    var granule: i64 = 0;
    var limit: i64 = 0;
    var d: i64 = 0;
    const rate_n: u64 = @intCast(p.map.granulerate_n);
    const rate_d: u64 = @intCast(p.map.granulerate_d);
    if (duration < 0) {
        if (p.map.is_sparse == 0) return b;
        granule = 0;
        limit = 1;
        d = 2;
    } else {
        var end_clip = true;
        if (p.map.audio_clipping != 0) {
            const meta: [*c]c.GstAudioClippingMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_clipping_meta_api_get_type())));
            if (meta != null and meta.*.end != 0 and meta.*.end < @as(u64, @bitCast(duration))) {
                duration -= @intCast(meta.*.end);
                end_clip = false;
            }
        }
        if (end_clip) {
            const end_time = os.granuleToTime(&p.map, p.next_granule + duration);
            const meta: [*c]c.GstAudioClippingMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_clipping_meta_api_get_type())));
            if (meta != null and meta.*.end != 0) {
                if (meta.*.format == c.GST_FORMAT_DEFAULT) {
                    if (meta.*.end > @as(u64, @bitCast(duration))) {
                        duration = 0;
                    } else duration -= @intCast(meta.*.end);
                }
            }
            if (end_time > p.segment.stop and c.gst_segment_to_running_time(&p.segment, c.GST_FORMAT_TIME, p.segment.start +% end_time) == NONE) {
                duration = @bitCast(c.gst_util_uint64_scale_round(p.segment.stop -% time, rate_n, SECOND * rate_d));
            }
        }
        granule = p.next_granule;
        const next_time = os.granuleToTime(&p.map, p.next_granule);
        d = @as(i64, @bitCast(time)) -% @as(i64, @bitCast(next_time));
        limit = @bitCast(os.granuleToTime(&p.map, 1) / 2);
        limit = @max(limit, @as(i64, @bitCast(m.max_tolerance)));
    }
    if (d > limit or d < -limit) granule = @bitCast(c.gst_util_uint64_scale_round(time, rate_n, SECOND * rate_d));
    if (p.map.is_ogm != 0 or p.map.is_sparse != 0) {
        p.next_granule = granule;
    } else {
        granule += duration;
        p.next_granule = granule;
    }
    if (cm.buf(b).mini_object.flags & c.GST_BUFFER_FLAG_DELTA_UNIT == 0) p.keyframe_granule = granule;
    cm.buf(b).offset = os.granuleToTime(&p.map, granule);
    cm.buf(b).offset_end = @bitCast(os.granuleToGranulepos(&p.map, granule, p.keyframe_granule));
    return b;
}

fn queuePads(m: *Mux, popped: *bool) ?*PadData {
    var best: ?*PadData = null;
    popped.* = false;
    var l = pads(m);
    while (l != null) {
        const data: [*c]c.GstCollectData = @ptrCast(@alignCast(l.*.data));
        const p: *PadData = @ptrCast(@alignCast(data));
        l = l.*.next;
        if (p.buffer == null) {
            var b = c.gst_collect_pads_pop(m.collect, data);
            if (b != null) {
                popped.* = true;
                if (m.delta_pad == null and cm.buf(b).mini_object.flags & c.GST_BUFFER_FLAG_DELTA_UNIT != 0) m.delta_pad = p;
                if (p.state == STATE_CONTROL) {
                    var map: c.GstMapInfo = undefined;
                    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
                    var pk = std.mem.zeroes(os.Packet);
                    pk.packet = map.data;
                    pk.bytes = @intCast(map.size);
                    if (p.have_type == 0) {
                        const caps = c.gst_pad_get_current_caps(data.*.pad);
                        p.have_type = @intFromBool(os.setupMapFromCapsHeaders(&p.map, caps));
                        if (p.have_type == 0) p.have_type = @intFromBool(os.setupMap(&p.map, &pk));
                        if (p.have_type == 0) p.have_type = @intFromBool(os.setupMapFromCaps(&p.map, caps));
                        if (p.have_type != 0) {
                            if (p.map.is_sparse != 0) c.gst_collect_pads_set_waiting(m.collect, data, 0);
                            if (p.map.is_video != 0 and m.delta_pad == null) m.delta_pad = p;
                        }
                        if (caps != null) c.gst_caps_unref(caps);
                    }
                    const is_header = if (p.have_type != 0) os.packetIsHeader(&p.map, &pk) else cm.buf(b).mini_object.flags & c.GST_BUFFER_FLAG_HEADER != 0;
                    c.gst_buffer_unmap(b, &map);
                    if (is_header) {
                        p.map.n_header_packets_seen += 1;
                        c.gst_buffer_unref(b);
                        b = null;
                    } else {
                        p.state = STATE_DATA;
                        if (os.granuleToGranulepos(&p.map, 1, 1) < 0) p.map.granulerate_n = 0;
                    }
                }
                if (b != null) b = decorate(m, p, b);
            }
            p.buffer = b;
        }
        if (p.buffer != null and p.eos == 0) {
            if (comparePads(best, p) > 0) best = p;
        }
    }
    return best;
}

fn getHeaders(p: *PadData) [*c]c.GList {
    var res: [*c]c.GList = null;
    const caps = c.gst_pad_get_current_caps(p.collect.pad);
    if (caps == null) return null;
    const st = c.gst_caps_get_structure(caps, 0);
    const sh = c.gst_structure_get_value(st, "streamheader");
    if (sh != null) {
        if (sh.*.g_type == c.gst_value_array_get_type()) {
            const n = c.gst_value_array_get_size(sh);
            for (0..n) |i| {
                const v = c.gst_value_array_get_value(sh, @intCast(i));
                if (v.*.g_type == c.gst_buffer_get_type()) {
                    const b = c.gst_value_get_buffer(v);
                    _ = c.gst_mini_object_ref(@ptrCast(b));
                    res = c.g_list_append(res, b);
                }
            }
        }
    } else if (c.gst_structure_has_name(st, "video/x-dirac") != 0) {
        res = c.g_list_append(res, p.buffer);
        p.buffer = null;
    } else if (p.have_type != 0) {
        const h = os.getHeaders(&p.map);
        if (h != null) res = c.g_list_append(res, h);
    }
    c.gst_caps_unref(caps);
    return res;
}

fn headerOnCaps(caps0: [*c]c.GstCaps, bufs: [*c]c.GList) [*c]c.GstCaps {
    const caps: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps0)));
    const st = c.gst_caps_get_structure(caps, 0);
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    var w = bufs;
    while (w != null) : (w = w.*.next) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(w.*.data));
        cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_HEADER;
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.gst_buffer_get_type());
        c.gst_value_set_buffer(&v, b);
        c.gst_value_array_append_value(&arr, &v);
        c.g_value_unset(&v);
    }
    c.gst_structure_take_value(st, "streamheader", &arr);
    return caps;
}

fn headerPacket(pk: *os.Packet, bos: bool, eos: bool) void {
    pk.granulepos = 0;
    pk.b_o_s = @intFromBool(bos);
    pk.e_o_s = @intFromBool(eos);
}

fn padHeaderPacket(pk: *os.Packet, p: *PadData) void {
    headerPacket(pk, p.packetno == 0, false);
    pk.packetno = p.packetno;
    p.packetno += 1;
}

fn submitSkeleton(st: *c.ogg_stream_state, b: [*c]c.GstBuffer, bos: bool, eos: bool) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    var pk = std.mem.zeroes(os.Packet);
    pk.packet = map.data;
    pk.bytes = @intCast(map.size);
    headerPacket(&pk, bos, eos);
    _ = c.ogg_stream_packetin(st, &pk);
    c.gst_buffer_unmap(b, &map);
    c.gst_buffer_unref(b);
}

const Writer = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn put(w: *Writer, s: []const u8) void {
        w.data.appendSlice(std.heap.c_allocator, s) catch unreachable;
    }

    fn int(w: *Writer, comptime T: type, v: T) void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        w.put(&tmp);
    }

    fn fill(w: *Writer, v: u8, n: usize) void {
        for (0..n) |_| w.put(&.{v});
    }

    fn buffer(w: *Writer) [*c]c.GstBuffer {
        const b = c.gst_buffer_new_memdup(w.data.items.ptr, w.data.items.len);
        w.data.deinit(std.heap.c_allocator);
        return b;
    }
};

fn makeFishead(st: *c.ogg_stream_state) void {
    var w = Writer{};
    w.put("fishead\x00");
    w.int(i16, 3);
    w.int(i16, 0);
    w.int(i64, 0);
    w.int(i64, 1000);
    w.int(i64, 0);
    w.int(i64, 1000);
    w.fill(' ', 20);
    submitSkeleton(st, w.buffer(), true, false);
}

fn fisboneHeader(w: *Writer, tag: []const u8, value: ?[*:0]const u8) void {
    const v = value orelse return;
    w.put(tag);
    w.put(": ");
    w.put(std.mem.span(v));
    w.put("\r\n");
}

fn fisboneTags(w: *Writer, header: []const u8, tag: [*:0]const u8, tags: ?*c.GstTagList) void {
    const size = c.gst_tag_list_get_tag_size(tags, tag);
    if (size == 0) return;
    const s = c.g_string_new("");
    for (0..size) |n| {
        if (n != 0) _ = c.g_string_append(s, ", ");
        var tmp: [*c]u8 = null;
        if (c.gst_tag_list_get_string_index(tags, tag, @intCast(n), &tmp) != 0) {
            _ = c.g_string_append(s, tmp);
            c.g_free(tmp);
        }
    }
    fisboneHeader(w, header, @ptrCast(s.*.str));
    _ = c.g_string_free(s, 1);
}

fn defaultRole(p: *PadData) ?[*:0]const u8 {
    const t = os.mediaType(&p.map);
    if (t == null) return null;
    const s = std.mem.span(t);
    if (std.mem.startsWith(u8, s, "video/")) return "video/main";
    if (std.mem.startsWith(u8, s, "audio/")) return "audio/main";
    if (std.mem.endsWith(u8, s, "kate")) return "text/caption";
    return null;
}

fn makeFisbone(st: *c.ogg_stream_state, p: *PadData) void {
    var w = Writer{};
    w.put("fisbone\x00");
    w.int(i32, 44);
    w.int(u32, p.map.serialno);
    w.int(u32, @bitCast(p.map.n_header_packets));
    w.int(u64, @bitCast(@as(i64, p.map.granulerate_n)));
    w.int(u64, @bitCast(@as(i64, p.map.granulerate_d)));
    w.int(u64, 0);
    w.int(u32, p.map.preroll);
    w.put(&.{@truncate(p.map.granuleshift)});
    w.fill(0, 3);
    const mt = os.mediaType(&p.map);
    fisboneHeader(&w, "Content-Type", if (mt == null) null else @ptrCast(mt));
    fisboneHeader(&w, "Role", defaultRole(p));
    if (p.tags != null) {
        fisboneTags(&w, "Language", "language-code", p.tags);
        fisboneTags(&w, "Title", "title", p.tags);
    }
    submitSkeleton(st, w.buffer(), false, false);
}

fn sendHeaders(m: *Mux) c.GstFlowReturn {
    var hbufs: [*c]c.GList = null;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var page: c.ogg_page = undefined;
    var skel: c.ogg_stream_state = undefined;
    var l = pads(m);
    while (l != null) : (l = l.*.next) {
        const p = padOf(l);
        if (p.buffer == null and p.map.is_sparse == 0) continue;
        p.map.headers = getHeaders(p);
    }
    l = pads(m);
    while (l != null) : (l = l.*.next) {
        const p = padOf(l);
        const pad = p.collect.pad;
        p.packetno = 0;
        var b: [*c]c.GstBuffer = null;
        if (p.map.headers != null) {
            b = @ptrCast(@alignCast(p.map.headers.*.data));
            p.map.headers = c.g_list_remove(p.map.headers, b);
        } else if (p.buffer != null) {
            b = p.buffer;
            _ = c.gst_mini_object_ref(@ptrCast(b));
        } else {
            cm.lock(pad);
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "No headers or buffers on pad %s:%s", cm.padParentName(pad), cm.padName(pad));
            cm.unlock(pad);
            continue;
        }
        const caps = c.gst_pad_get_current_caps(pad);
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        var pk = std.mem.zeroes(os.Packet);
        pk.packet = map.data;
        pk.bytes = @intCast(map.size);
        padHeaderPacket(&pk, p);
        _ = c.ogg_stream_packetin(&p.map.stream, &pk);
        c.gst_buffer_unmap(b, &map);
        c.gst_buffer_unref(b);
        if (c.ogg_stream_flush(&p.map.stream, &page) == 0) c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Could not flush BOS page");
        const hb = bufferFromPage(&page, false);
        if (p.map.is_video != 0) {
            hbufs = c.g_list_prepend(hbufs, hb);
        } else hbufs = c.g_list_append(hbufs, hb);
        if (caps != null) c.gst_caps_unref(caps);
    }
    if (m.use_skeleton != 0) {
        _ = c.ogg_stream_init(&skel, @bitCast(generateSerial(m)));
        makeFishead(&skel);
        while (c.ogg_stream_flush(&skel, &page) > 0) hbufs = c.g_list_append(hbufs, bufferFromPage(&page, false));
    }
    l = pads(m);
    while (l != null) : (l = l.*.next) {
        const p = padOf(l);
        if (m.use_skeleton != 0) makeFisbone(&skel, p);
        var hw = p.map.headers;
        while (hw != null) {
            const b: [*c]c.GstBuffer = @ptrCast(@alignCast(hw.*.data));
            hw = hw.*.next;
            var map: c.GstMapInfo = undefined;
            _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
            var pk = std.mem.zeroes(os.Packet);
            pk.packet = map.data;
            pk.bytes = @intCast(map.size);
            padHeaderPacket(&pk, p);
            _ = c.ogg_stream_packetin(&p.map.stream, &pk);
            c.gst_buffer_unmap(b, &map);
            c.gst_buffer_unref(b);
            if (hw == null) {
                while (c.ogg_stream_flush(&p.map.stream, &page) != 0) hbufs = c.g_list_append(hbufs, bufferFromPage(&page, false));
            } else {
                while (c.ogg_stream_pageout(&p.map.stream, &page) > 0) hbufs = c.g_list_append(hbufs, bufferFromPage(&page, false));
            }
        }
        c.g_list_free(p.map.headers);
        p.map.headers = null;
    }
    if (m.use_skeleton != 0) {
        while (c.ogg_stream_flush(&skel, &page) > 0) hbufs = c.g_list_append(hbufs, bufferFromPage(&page, false));
        submitSkeleton(&skel, c.gst_buffer_new_allocate(null, 0, null), false, true);
        while (c.ogg_stream_flush(&skel, &page) > 0) hbufs = c.g_list_append(hbufs, bufferFromPage(&page, false));
        _ = c.ogg_stream_clear(&skel);
    }
    var caps = c.gst_pad_get_allowed_caps(m.srcpad);
    if (caps != null and c.gst_caps_is_fixed(caps) == 0) caps = c.gst_caps_fixate(caps);
    if (caps == null) caps = c.gst_caps_new_empty_simple("application/ogg");
    caps = headerOnCaps(caps, hbufs);
    _ = cm.setCaps(m.srcpad, caps);
    c.gst_caps_unref(caps);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_segment(&seg));
    while (hbufs != null) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(hbufs.*.data));
        hbufs = c.g_list_delete_link(hbufs, hbufs);
        ret = pushBuffer(m, b);
        if (ret != c.GST_FLOW_OK) break;
    }
    var w = hbufs;
    while (w != null) : (w = w.*.next) c.gst_mini_object_unref(@ptrCast(@alignCast(w.*.data)));
    c.g_list_free(hbufs);
    return ret;
}

fn flushPages(m: *Mux, p: *PadData, ts: u64) c.GstFlowReturn {
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var page: c.ogg_page = undefined;
    while (c.ogg_stream_flush(&p.map.stream, &page) != 0) {
        m.pulling.?.timestamp_end = ts;
        ret = queuePage(m, p, &page, p.first_delta != 0);
        p.pageno += 1;
        p.first_delta = 1;
    }
    return ret;
}

fn processBestPad(m: *Mux, best: ?*PadData) c.GstFlowReturn {
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (m.pulling) |pl| {
        const nb = c.gst_collect_pads_peek(m.collect, &pl.collect);
        if (nb != null) {
            pl.eos = 0;
            c.gst_buffer_unref(nb);
        } else if (pl.map.is_sparse == 0) pl.eos = 1;
    }
    if (best != null and best != m.pulling) {
        const bp = best.?;
        const nb = c.gst_collect_pads_peek(m.collect, &bp.collect);
        if (nb != null) {
            bp.eos = 0;
            c.gst_buffer_unref(nb);
        } else if (bp.map.is_sparse == 0) bp.eos = 1;
    }
    if (m.pulling != null and best != null and m.pulling != best and m.pulling.?.buffer != null) {
        const p = m.pulling.?;
        const last = endTime(p.buffer);
        if (last > m.next_ts +% m.max_delay) {
            ret = flushPages(m, p, cm.buf(p.buffer).pts);
            p.new_page = 1;
            m.pulling = null;
        }
    }
    if (m.pulling == null) {
        m.pulling = best;
        if (m.pulling) |pl| {
            m.next_ts = cm.buf(pl.buffer).pts;
        } else {
            _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_eos());
            return c.GST_FLOW_FLUSHING;
        }
    }
    if (m.need_headers != 0) {
        ret = sendHeaders(m);
        m.need_headers = 0;
    }
    if (m.pulling) |p| {
        const b = p.buffer;
        if (b == null) {
            m.pulling = null;
            return c.GST_FLOW_OK;
        }
        const delta = cm.buf(b).mini_object.flags & c.GST_BUFFER_FLAG_DELTA_UNIT != 0;
        const duration = cm.buf(b).duration;
        if (p.timestamp == NONE) p.timestamp = cm.buf(b).pts;
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        var pk = std.mem.zeroes(os.Packet);
        pk.packet = map.data;
        pk.bytes = @intCast(map.size);
        pk.granulepos = @bitCast(cm.buf(b).offset_end);
        if (pk.granulepos == -1) pk.granulepos = 0;
        pk.b_o_s = @intFromBool(p.packetno == 0);
        pk.packetno = p.packetno;
        p.packetno += 1;
        pk.e_o_s = if (p.eos != 0) 1 else 0;
        var force = (p.prev_delta != 0 and !delta) or p.map.always_flush_page != 0;
        if (duration != NONE) {
            p.duration +%= duration;
            if (p.duration > m.max_page_delay) {
                force = true;
                p.duration = 0;
            }
        }
        if (cm.buf(b).mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) {
            if (p.data_pushed != 0) {
                pk.packetno += 1;
                p.map.stream.pageno += 1;
                force = true;
            }
        }
        if (force) {
            ret = flushPages(m, p, cm.buf(p.buffer).pts);
            p.new_page = 1;
        }
        if (p.new_page != 0) {
            if (delta) {
                p.first_delta = 1;
            } else if (m.delta_pad == p) {
                p.first_delta = 0;
            } else if (m.delta_pad != null) {
                p.first_delta = 1;
            } else p.first_delta = 0;
            p.new_page = 0;
        }
        p.prev_delta = @intFromBool(delta);
        _ = c.ogg_stream_packetin(&p.map.stream, &pk);
        c.gst_buffer_unmap(b, &map);
        p.data_pushed = 1;
        const gp_time = cm.buf(p.buffer).offset;
        const granulepos: i64 = @bitCast(cm.buf(p.buffer).offset_end);
        const timestamp = cm.buf(p.buffer).pts;
        c.gst_buffer_unref(p.buffer);
        p.buffer = null;
        var page: c.ogg_page = undefined;
        if (c.ogg_stream_pageout(&p.map.stream, &page) > 0) {
            if (c.ogg_page_granulepos(&page) == granulepos) p.gp_time = gp_time;
            p.timestamp_end = timestamp;
            ret = queuePage(m, p, &page, p.first_delta != 0);
            p.pageno += 1;
            p.first_delta = 1;
            while (c.ogg_stream_pageout(&p.map.stream, &page) > 0) {
                if (c.ogg_page_granulepos(&page) == granulepos) p.gp_time = gp_time;
                ret = queuePage(m, p, &page, p.first_delta != 0);
                p.pageno += 1;
            }
            p.new_page = 1;
            p.duration = 0;
            m.pulling = null;
        }
        if (p.gp_time < gp_time) p.gp_time = gp_time;
    }
    return ret;
}

fn allEos(cp: ?*c.GstCollectPads) bool {
    var l = cp.?.data;
    while (l != null) : (l = l.*.next) {
        if (padOf(l).eos == 0) return false;
    }
    return true;
}

fn collected(cp: ?*c.GstCollectPads, user: c.gpointer) callconv(.c) c.GstFlowReturn {
    const m = me(user);
    if (m.need_start_events != 0) {
        var sid: [32]u8 = undefined;
        _ = c.g_snprintf(&sid, sid.len, "oggmux-%08x", c.g_random_int());
        _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_stream_start(&sid));
        m.need_start_events = 0;
    }
    var popped = false;
    const best = queuePads(m, &popped);
    if (popped) return c.GST_FLOW_OK;
    const b = best orelse {
        _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_eos());
        return c.GST_FLOW_EOS;
    };
    if (!cm.that(b.buffer != null, "gst_ogg_mux_collected", "best->buffer != NULL")) return c.GST_FLOW_ERROR;
    const ret = processBestPad(m, b);
    if (b.eos != 0 and allEos(cp)) {
        _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_eos());
        return c.GST_FLOW_EOS;
    }
    _ = queuePads(m, &popped);
    return ret;
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const m = me(ob);
    switch (id) {
        1 => c.g_value_set_uint64(v, m.max_delay),
        2 => c.g_value_set_uint64(v, m.max_page_delay),
        3 => c.g_value_set_uint64(v, m.max_tolerance),
        4 => c.g_value_set_boolean(v, m.use_skeleton),
        else => cm.warnInvalid(FILE, ob, id, spec, 2129),
    }
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const m = me(ob);
    switch (id) {
        1 => m.max_delay = c.g_value_get_uint64(v),
        2 => m.max_page_delay = c.g_value_get_uint64(v),
        3 => m.max_tolerance = c.g_value_get_uint64(v),
        4 => m.use_skeleton = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, ob, id, spec, 2156),
    }
}

fn initCollect(cp: ?*c.GstCollectPads) void {
    var l = cp.?.data;
    while (l != null) : (l = l.*.next) {
        const p = padOf(l);
        _ = c.ogg_stream_clear(&p.map.stream);
        _ = c.ogg_stream_init(&p.map.stream, @bitCast(p.map.serialno));
        p.packetno = 0;
        p.pageno = 0;
        p.eos = 0;
        p.state = STATE_CONTROL;
        p.new_page = 1;
        p.first_delta = 0;
        p.prev_delta = 0;
        p.data_pushed = 0;
        p.pagebuffers = c.g_queue_new();
        c.gst_segment_init(&p.segment, c.GST_FORMAT_TIME);
    }
}

fn clearCollect(cp: ?*c.GstCollectPads) void {
    var l = cp.?.data;
    while (l != null) : (l = l.*.next) {
        const p = padOf(l);
        _ = c.ogg_stream_clear(&p.map.stream);
        if (p.pagebuffers) |q| {
            while (c.g_queue_pop_head(q)) |b| c.gst_buffer_unref(@ptrCast(@alignCast(b)));
            c.g_queue_free(q);
        }
        p.pagebuffers = null;
        if (p.buffer != null) c.gst_buffer_unref(p.buffer);
        p.buffer = null;
        if (p.tags) |t| c.gst_tag_list_unref(t);
        p.tags = null;
        c.gst_segment_init(&p.segment, c.GST_FORMAT_TIME);
    }
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const m = me(el);
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            clear(m);
            initCollect(m.collect);
            c.gst_collect_pads_start(m.collect);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => c.gst_collect_pads_stop(m.collect),
        else => {},
    }
    const r = parent_class.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) clearCollect(m.collect);
    return r;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = finalize;
    gc.get_property = getProperty;
    gc.set_property = setProperty;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &video_t);
    c.gst_element_class_add_static_pad_template(ec, &audio_t);
    c.gst_element_class_add_static_pad_template(ec, &sub_t);
    c.gst_element_class_set_static_metadata(ec, "Ogg muxer", "Codec/Muxer", "mux ogg streams (info about ogg: http://xiph.org)", "Wim Taymans <wim@fluendo.com>");
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    const f = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_uint64("max-delay", "Max delay", "Maximum delay in multiplexing streams", 0, NONE, 500000000, f));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_uint64("max-page-delay", "Max page delay", "Maximum delay for sending out a page", 0, NONE, 500000000, f));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_uint64("max-tolerance", "Max time tolerance", "Maximum timestamp difference for maintaining perfect granules", 0, NONE, 40000000, f));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_boolean("skeleton", "Skeleton", "Whether to include a Skeleton track", 0, f));
    ec.change_state = changeState;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const m = me(inst);
    const k: *c.GstElementClass = @ptrCast(@alignCast(inst.*.g_class));
    m.srcpad = c.gst_pad_new_from_template(c.gst_element_class_get_pad_template(k, "src"), "src");
    c.gst_pad_set_event_function_full(m.srcpad, srcEvent, null, null);
    _ = c.gst_element_add_pad(&m.element, m.srcpad);
    c.srand(@truncate(@as(u64, @bitCast(c.time(null)))));
    m.collect = c.gst_collect_pads_new();
    c.gst_collect_pads_set_function(m.collect, collected, m);
    c.gst_collect_pads_set_event_function(m.collect, sinkEvent, m);
    m.max_delay = 500000000;
    m.max_page_delay = 500000000;
    m.max_tolerance = 40000000;
    clear(m);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstOggMux", Class, Mux, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_preset_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    _ = c._gst_debug_category_new("oggmux", 0, "ogg muxer");
    demux.debugInit();
    return c.gst_element_register(p, "oggmux", c.GST_RANK_PRIMARY, getType()) != 0;
}
