const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const os = @import("stream.zig");

const FILE = "../ext/ogg/gstoggdemux.c";
const NONE = cm.CLOCK_NONE;
const SECOND: u64 = 1_000_000_000;
const MS: u64 = 1_000_000;
const CHUNKSIZE: c_long = 8500;
const DURATION_CHUNK_OFFSET: i64 = 128 * 1024;
const MAX_PAGE: i64 = 255 * 255 + 26;
const FLOW_LIMIT: c.GstFlowReturn = c.GST_FLOW_CUSTOM_ERROR;
const SKIP_PUSH: c.GstFlowReturn = c.GST_FLOW_CUSTOM_SUCCESS_1;
const GIVE_UP: u64 = 3 * SECOND;
const SEQNUM_INVALID: u32 = 0;
const A = std.heap.c_allocator;

const PUSH_PLAYING = 0;
const PUSH_DURATION = 1;
const PUSH_BISECT1 = 2;
const PUSH_LINEAR1 = 3;
const PUSH_BISECT2 = 4;
const PUSH_LINEAR2 = 5;

pub const Chain = struct {
    ogg: *Demux,
    offset: i64 = -1,
    end_offset: i64 = 0,
    bytes: i64 = -1,
    have_bos: bool = false,
    streams: std.ArrayListUnmanaged(*Pad) = .empty,
    total_time: u64 = NONE,
    begin_time: u64 = NONE,
    segment_start: u64 = NONE,
    segment_stop: u64 = NONE,
};

pub const Pad = extern struct {
    pad: cm.Pad,
    have_type: c.gboolean,
    chain: ?*Chain,
    ogg: ?*Demux,
    map: os.Stream,
    packetno: i64,
    current_granule: i64,
    prev_granule: i64,
    keyframe_granule: i64,
    start_time: u64,
    first_granule: i64,
    first_time: u64,
    position: u64,
    continued: [*c]c.GList,
    need_header_flag: c.gboolean,
    discont: c.gboolean,
    last_ret: c.GstFlowReturn,
    is_eos: c.gboolean,
    added: c.gboolean,
    push_kf_time: u64,
    push_sync_time: u64,
};

const PadClass = extern struct {
    parent: c.GstPadClass,
};

pub const Demux = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    flowcombiner: ?*c.GstFlowCombiner,
    length: i64,
    read_offset: i64,
    offset: i64,
    pullmode: c.gboolean,
    running: c.gboolean,
    have_group_id: c.gboolean,
    group_id: c.guint,
    need_chains: c.gboolean,
    resync: c.gboolean,
    max_packet_size: u64,
    max_page_size: u64,
    check_index_overflow: c.gboolean,
    chain_lock: c.GMutex,
    chains: ?*std.ArrayListUnmanaged(*Chain),
    total_time: u64,
    bitrate: c.gint,
    current_chain: ?*Chain,
    building_chain: ?*Chain,
    segment: c.GstSegment,
    seqnum: u32,
    newsegment: [*c]c.GstEvent,
    basetime: i64,
    prestime: i64,
    push_lock: c.GMutex,
    push_byte_offset: i64,
    push_byte_length: i64,
    push_time_length: u64,
    push_start_time: u64,
    push_time_offset: u64,
    push_state: c_int,
    push_seek_time_original_target: u64,
    push_seek_time_original_stop: u64,
    push_seek_time_target: u64,
    push_last_seek_offset: i64,
    push_last_seek_time: u64,
    push_offset0: i64,
    push_offset1: i64,
    push_time0: u64,
    push_time1: u64,
    push_seek_rate: f64,
    push_seek_flags: c.GstSeekFlags,
    push_mode_seek_delayed_event: [*c]c.GstEvent,
    push_disable_seeking: c.gboolean,
    seek_secant: c.gboolean,
    seek_undershot: c.gboolean,
    push_prev_seek_time: u64,
    push_bisection_steps: [2]c.gint,
    stats_bisection_steps: [2]c.gint,
    stats_bisection_max_steps: [2]c.gint,
    stats_nbisections: c.gint,
    sync: c.ogg_sync_state,
    chunk_size: c_long,
    seek_event: [*c]c.GstEvent,
    seek_event_thread: ?*c.GThread,
    seek_event_mutex: c.GMutex,
    seek_event_cond: c.GCond,
    seek_event_thread_stop: c.gboolean,
    seek_thread_started: c.gboolean,
    thread_started_cond: c.GCond,
    seek_event_drop_till: u32,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var src_t = cm.staticTemplate("src_%08x", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "application/ogg; audio/ogg; video/ogg; application/kate");
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent_class: ?*c.GstElementClass = null;
var pad_parent: ?*c.GObjectClass = null;
var cats_once: usize = 0;

pub fn debugInit() void {
    if (c.g_once_init_enter(&cats_once) != 0) {
        _ = c._gst_debug_category_new("oggdemux", 0, "ogg demuxer");
        _ = c._gst_debug_category_new("oggdemux_setup", 0, "ogg demuxer setup stage when parsing pipeline");
        c.g_once_init_leave(&cats_once, 1);
    }
}

fn pushLock(o: *Demux) void {
    c.g_mutex_lock(&o.push_lock);
}

fn pushUnlock(o: *Demux) void {
    c.g_mutex_unlock(&o.push_lock);
}

fn chainLock(o: *Demux) void {
    c.g_mutex_lock(&o.chain_lock);
}

fn chainUnlock(o: *Demux) void {
    c.g_mutex_unlock(&o.chain_lock);
}

fn gpad(p: *Pad) *c.GstPad {
    return @ptrCast(&p.pad);
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn packetCopy(p: *const os.Packet) *os.Packet {
    const r: *os.Packet = @ptrCast(@alignCast(c.g_malloc(@sizeOf(os.Packet))));
    r.* = p.*;
    r.packet = @ptrCast(c.g_memdup2(p.packet, @intCast(p.bytes)));
    return r;
}

fn packetFree(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    const pk: *os.Packet = @ptrCast(@alignCast(p));
    c.g_free(pk.packet);
    c.g_free(pk);
}

fn pageCopy(p: *c.ogg_page) *c.ogg_page {
    const r: *c.ogg_page = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.ogg_page))));
    r.header = @ptrCast(c.g_memdup2(p.header, @intCast(p.header_len)));
    r.header_len = p.header_len;
    r.body = @ptrCast(c.g_memdup2(p.body, @intCast(p.body_len)));
    r.body_len = p.body_len;
    return r;
}

fn pageFree(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    const pg: *c.ogg_page = @ptrCast(@alignCast(p));
    c.g_free(pg.header);
    c.g_free(pg.body);
    c.g_free(pg);
}

fn freeList(l: *[*c]c.GList, f: c.GFunc) void {
    c.g_list_foreach(l.*, f, null);
    c.g_list_free(l.*);
    l.* = null;
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: *Pad = @ptrCast(@alignCast(inst));
    c.gst_pad_set_event_function_full(gpad(p), padEvent, null, null);
    c.gst_pad_set_query_function_full(gpad(p), padQuery, null, null);
    c.gst_pad_use_fixed_caps(gpad(p));
    p.current_granule = -1;
    p.prev_granule = -1;
    p.keyframe_granule = -1;
    p.start_time = NONE;
    p.position = NONE;
    p.have_type = 0;
    p.continued = null;
    p.map.headers = null;
    p.map.queued = null;
    p.map.granulerate_n = 0;
    p.map.granulerate_d = 0;
    p.map.granuleshift = std.math.maxInt(c.guint);
}

fn padDispose(o: [*c]c.GObject) callconv(.c) void {
    const p: *Pad = @ptrCast(@alignCast(o));
    p.chain = null;
    p.ogg = null;
    freeList(&p.map.headers, packetFree);
    freeList(&p.map.queued, packetFree);
    c.g_free(p.map.index);
    p.map.index = null;
    freeList(&p.continued, pageFree);
    if (p.map.caps != null) c.gst_caps_unref(p.map.caps);
    p.map.caps = null;
    if (p.map.taglist) |t| c.gst_tag_list_unref(t);
    p.map.taglist = null;
    _ = c.ogg_stream_reset(&p.map.stream);
    pad_parent.?.dispose.?(o);
}

fn padFinalize(o: [*c]c.GObject) callconv(.c) void {
    const p: *Pad = @ptrCast(@alignCast(o));
    _ = c.ogg_stream_clear(&p.map.stream);
    pad_parent.?.finalize.?(o);
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.dispose = padDispose;
    gc.finalize = padFinalize;
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_pad_get_type(), "GstOggPad", PadClass, Pad, padClassInit, padInit);
        }
    }.f);
}

fn me(p: anytype) *Demux {
    return @ptrCast(@alignCast(p));
}

fn padQuery(pad: ?*c.GstPad, parent: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const ogg = me(parent);
    const op: *Pad = @ptrCast(@alignCast(pad));
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            var f: c.GstFormat = 0;
            c.gst_query_parse_position(q, &f, null);
            if (f != c.GST_FORMAT_TIME) return 0;
            c.gst_query_set_position(q, f, @bitCast(op.position));
            return 1;
        },
        c.GST_QUERY_DURATION => {
            var f: c.GstFormat = 0;
            var total: i64 = -1;
            c.gst_query_parse_duration(q, &f, null);
            if (f != c.GST_FORMAT_TIME) return 0;
            if (ogg.total_time != NONE) {
                total = @bitCast(ogg.total_time);
            } else if (ogg.bitrate > 0) {
                const uq = c.gst_query_new_duration(c.GST_FORMAT_BYTES);
                if (c.gst_pad_peer_query(ogg.sinkpad, uq) != 0) {
                    var len: i64 = 0;
                    c.gst_query_parse_duration(uq, null, &len);
                    total = @bitCast(c.gst_util_uint64_scale(@bitCast(len), 8 * SECOND, @intCast(ogg.bitrate)));
                }
                c.gst_query_unref(uq);
            }
            c.gst_query_set_duration(q, c.GST_FORMAT_TIME, total);
            return 1;
        },
        c.GST_QUERY_SEEKING => {
            var f: c.GstFormat = 0;
            c.gst_query_parse_seeking(q, &f, null, null, null);
            if (f != c.GST_FORMAT_TIME) return 0;
            var seekable: c.gboolean = 0;
            var stop: i64 = -1;
            chainLock(ogg);
            if (ogg.pullmode != 0) {
                seekable = 1;
                stop = @bitCast(ogg.total_time);
            } else if (ogg.push_disable_seeking != 0) {
                seekable = 0;
            } else if (ogg.current_chain == null) {
                const sq = c.gst_query_new_seeking(c.GST_FORMAT_BYTES);
                if (c.gst_pad_peer_query(ogg.sinkpad, sq) != 0) {
                    c.gst_query_parse_seeking(sq, null, &seekable, null, null);
                } else seekable = 0;
                c.gst_query_unref(sq);
            } else if (ogg.current_chain.?.streams.items.len > 0) {
                seekable = 0;
                for (ogg.current_chain.?.streams.items) |p| {
                    seekable = 1;
                    if (p.map.index != null and p.map.n_index != 0) {
                        const idx = p.map.index[p.map.n_index - 1];
                        const t: i64 = @bitCast(c.gst_util_uint64_scale(idx.timestamp, SECOND, p.map.kp_denom));
                        stop = if (stop == -1) t else @max(t, stop);
                    } else {
                        stop = @bitCast(ogg.push_time_length);
                        if (stop == -1) stop = @bitCast(ogg.total_time);
                    }
                }
            }
            c.gst_query_set_seeking(q, c.GST_FORMAT_TIME, seekable, 0, stop);
            chainUnlock(ogg);
            return 1;
        },
        c.GST_QUERY_SEGMENT => {
            const f = ogg.segment.format;
            const start = c.gst_segment_to_stream_time(&ogg.segment, f, ogg.segment.start);
            var stop = ogg.segment.stop;
            if (stop == NONE) {
                stop = ogg.segment.duration;
            } else stop = c.gst_segment_to_stream_time(&ogg.segment, f, stop);
            c.gst_query_set_segment(q, ogg.segment.rate, f, @bitCast(start), @bitCast(stop));
            return 1;
        },
        else => return c.gst_pad_query_default(pad, parent, q),
    }
}

fn receiveEvent(el: [*c]c.GstElement, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const ogg = me(el);
    if (cm.eventType(ev) == c.GST_EVENT_SEEK) {
        const r = performSeek(ogg, ev);
        c.gst_event_unref(ev);
        return @intFromBool(r);
    }
    c.gst_event_unref(ev);
    return 0;
}

fn padEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const ogg = me(parent);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEEK => {
            const r = performSeek(ogg, ev);
            c.gst_event_unref(ev);
            return @intFromBool(r);
        },
        c.GST_EVENT_RECONFIGURE => {
            @as(*Pad, @ptrCast(@alignCast(pad))).last_ret = c.GST_FLOW_OK;
            return c.gst_pad_event_default(pad, parent, ev);
        },
        else => return c.gst_pad_event_default(pad, parent, ev),
    }
}

fn padReset(p: *Pad) void {
    _ = c.ogg_stream_reset(&p.map.stream);
    freeList(&p.continued, pageFree);
    p.last_ret = c.GST_FLOW_OK;
    p.position = NONE;
    p.current_granule = -1;
    p.prev_granule = -1;
    p.keyframe_granule = -1;
    p.is_eos = 0;
}

fn queueData(p: *Pad, pk: *os.Packet) c.GstFlowReturn {
    p.map.queued = c.g_list_append(p.map.queued, packetCopy(pk));
    return c.GST_FLOW_OK;
}

fn chainPeer(p: *Pad, pk: *os.Packet, push_headers: bool) c.GstFlowReturn {
    const ogg = p.ogg.?;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var buf: [*c]c.GstBuffer = null;
    var offset: c_long = 0;
    var trim: c_long = 0;
    var delta = false;
    var duration: i64 = 0;
    var out_ts: u64 = NONE;
    var out_dur: u64 = NONE;
    var out_off: u64 = 0;
    var out_end: u64 = NONE;
    var clip_start: u64 = 0;
    var clip_end: u64 = 0;
    defer if (buf != null) c.gst_buffer_unref(buf);
    if (p.is_eos != 0) return combineFlows(ogg, p, c.GST_FLOW_EOS);
    pushLock(ogg);
    if (ogg.pullmode == 0 and ogg.push_state == PUSH_PLAYING and ogg.push_time_length == NONE and ogg.push_disable_seeking == 0) {
        if (ogg.building_chain == null) {
            if (!checkDurationPush(ogg, c.GST_SEEK_FLAG_FLUSH, null)) {
                pushUnlock(ogg);
                return c.GST_FLOW_OK;
            }
        }
        pushUnlock(ogg);
        return c.GST_FLOW_OK;
    }
    pushUnlock(ogg);
    os.updateStats(&p.map, pk);
    if (p.map.is_ogm != 0) {
        const d = pk.packet;
        var nbytes = pk.bytes;
        if (nbytes < 1) return c.GST_FLOW_OK;
        if (d[0] & 1 != 0 or (d[0] & 3 != 0 and p.map.is_ogm_text != 0)) return c.GST_FLOW_OK;
        offset = 1 + (((d[0] & 0xc0) >> 6) | ((d[0] & 0x02) << 1));
        delta = ((d[0] & 0x08) >> 3) == 0;
        trim = 0;
        if (p.map.is_ogm_text != 0) {
            while (nbytes != 0 and d[@intCast(nbytes - 1)] == 0) {
                trim += 1;
                nbytes -= 1;
            }
        }
    } else if (p.map.is_vp8 != 0) {
        if ((pk.bytes >= 7 and std.mem.eql(u8, pk.packet[0..7], "OVP80\x02 ")) or pk.b_o_s != 0 or (pk.bytes >= 5 and std.mem.eql(u8, pk.packet[0..5], "OVP80"))) {
            p.need_header_flag = 1;
            return c.GST_FLOW_OK;
        }
        delta = !os.packetIsKeyFrame(&p.map, pk);
    } else delta = !os.packetIsKeyFrame(&p.map, pk);
    const is_header = os.packetIsHeader(&p.map, pk);
    duration = if (is_header) 0 else os.packetDuration(&p.map, pk);
    if (!is_header and ogg.check_index_overflow != 0) {
        if (ogg.current_chain) |chain| {
            const q = c.gst_query_new_duration(c.GST_FORMAT_BYTES);
            if (c.gst_pad_peer_query(ogg.sinkpad, q) != 0) {
                var f: c.GstFormat = 0;
                var len: i64 = 0;
                c.gst_query_parse_duration(q, &f, &len);
                if (f == c.GST_FORMAT_BYTES and len >= 0) {
                    for (chain.streams.items) |ip| {
                        if (ip.map.index == null) continue;
                        const beyond = ip.map.n_index != 0 and ip.map.index[ip.map.n_index - 1].offset >= @as(u64, @bitCast(len));
                        if (beyond) {
                            if (ip.discont != 0) {
                                c.g_free(ip.map.index);
                                ip.map.index = null;
                                ip.map.n_index = 0;
                            } else {
                                while (ip.map.n_index > 0 and ip.map.index[ip.map.n_index - 1].offset >= @as(u64, @bitCast(len))) ip.map.n_index -= 1;
                                if (ip.map.n_index == 0) {
                                    c.g_free(ip.map.index);
                                    ip.map.index = null;
                                }
                            }
                            ip.map.total_time = NONE;
                        } else {
                            if (ogg.total_time == NONE) {
                                ogg.total_time = ip.map.total_time;
                            } else if (ip.map.total_time != NONE) ogg.total_time = @max(ogg.total_time, ip.map.total_time);
                        }
                    }
                }
            }
            c.gst_query_unref(q);
        }
        ogg.check_index_overflow = 0;
    }
    if (pk.b_o_s != 0) {
        out_ts = NONE;
        out_dur = NONE;
        out_off = 0;
        out_end = NONE;
    } else {
        if (pk.granulepos > -1) {
            const g = os.granuleposToGranule(&p.map, pk.granulepos);
            if (g < 0) {
                buf = null;
                return c.GST_FLOW_ERROR;
            }
            p.current_granule = g;
            p.keyframe_granule = os.granuleposToKeyGranule(&p.map, pk.granulepos);
        } else if (p.current_granule != -1) {
            p.current_granule += duration;
            if (!delta) p.keyframe_granule = p.current_granule;
        }
        if (ogg.segment.rate < 0.0 and p.current_granule == -1) {
            out_ts = NONE;
            out_dur = NONE;
            out_off = NONE;
            out_end = NONE;
            p.prev_granule = -1;
        } else {
            if (p.current_granule == -1) {
                p.prev_granule = -1;
                return c.GST_FLOW_OK;
            }
            const rate_n: u64 = @bitCast(@as(i64, p.map.granulerate_n));
            const rate_d: u64 = @bitCast(@as(i64, p.map.granulerate_d));
            if (p.map.is_ogm != 0) {
                out_ts = os.granuleToTime(&p.map, p.current_granule);
                out_dur = c.gst_util_uint64_scale(@bitCast(duration), SECOND *% rate_d, rate_n);
            } else if (p.map.is_sparse != 0) {
                out_ts = os.granuleToTime(&p.map, p.current_granule);
                out_dur = if (@as(u64, @bitCast(duration)) == NONE) NONE else c.gst_util_uint64_scale(@bitCast(duration), SECOND *% rate_d, rate_n);
            } else {
                const goff = -p.map.granule_offset;
                if (pk.e_o_s != 0) {
                    out_ts = if (p.prev_granule >= 0) os.granuleToTime(&p.map, p.prev_granule) else NONE;
                    if (p.map.audio_clipping != 0 and p.current_granule < p.prev_granule + duration) clip_end = @bitCast(p.prev_granule + duration - p.current_granule);
                } else out_ts = os.granuleToTime(&p.map, p.current_granule - duration);
                if (p.map.audio_clipping != 0 and p.current_granule - duration < goff) {
                    if (p.current_granule >= goff) {
                        const removed: u64 = if (p.current_granule > duration) @bitCast(p.current_granule - duration) else 0;
                        clip_start = if (removed > @as(u64, @bitCast(goff))) 0 else @as(u64, @bitCast(goff)) - removed;
                    } else clip_start = @bitCast(p.current_granule);
                }
                out_dur = os.granuleToTime(&p.map, p.current_granule) -% out_ts;
            }
            out_end = @bitCast(os.granuleToGranulepos(&p.map, p.current_granule, p.keyframe_granule));
            out_off = os.granuleToTime(&p.map, p.current_granule);
        }
        p.prev_granule = p.current_granule;
    }
    if (offset + trim > pk.bytes) return c.GST_FLOW_OK;
    if (p.map.is_ogm_text != 0 and offset + trim >= pk.bytes) return c.GST_FLOW_OK;
    if (p.added == 0) return c.GST_FLOW_OK;
    buf = c.gst_buffer_new_allocate(null, @intCast(pk.bytes - offset - trim), null);
    if (p.map.audio_clipping != 0 and (clip_start != 0 or clip_end != 0)) _ = c.gst_buffer_add_audio_clipping_meta(buf, c.GST_FORMAT_DEFAULT, clip_start, clip_end);
    const mo = cm.obj(buf);
    _ = mo;
    const b = cm.buf(buf);
    if (delta) b.mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
    if (is_header or p.need_header_flag != 0) {
        p.need_header_flag = 0;
        b.mini_object.flags |= c.GST_BUFFER_FLAG_HEADER;
    }
    if (pk.packet != null) _ = c.gst_buffer_fill(buf, 0, pk.packet + @as(usize, @intCast(offset)), @intCast(pk.bytes - offset - trim));
    b.pts = out_ts;
    b.duration = out_dur;
    b.offset = out_off;
    b.offset_end = out_end;
    if (p.discont != 0) {
        b.mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        if (ogg.segment.rate < 0.0 or b.pts != NONE) p.discont = 0;
    }
    if (pk.b_o_s == 0 or push_headers) {
        if (p.last_ret == c.GST_FLOW_OK) {
            ret = c.gst_pad_push(gpad(p), buf);
        } else {
            ret = p.last_ret;
            c.gst_buffer_unref(buf);
        }
        buf = null;
    }
    if (p.map.is_skeleton != 0 or pk.granulepos < 0) return combineFlows(ogg, p, ret);
    var cur = os.endTimeForGranulepos(&p.map, pk.granulepos);
    if (p.chain) |chain| {
        var start: u64 = 0;
        if (chain.segment_start != NONE) start = chain.segment_start;
        cur = cur -% start +% chain.begin_time;
    }
    ogg.segment.position = cur;
    p.position = ogg.segment.position;
    if (p.is_eos == 0 and !delta and ((ogg.segment.rate > 0.0 and ogg.segment.stop != NONE and @as(i64, @bitCast(cur)) >= @as(i64, @bitCast(ogg.segment.stop))) or (ogg.segment.rate < 0.0 and @as(i64, @bitCast(cur)) <= @as(i64, @bitCast(ogg.segment.start))))) {
        p.is_eos = 1;
        if (ret == c.GST_FLOW_OK) ret = c.GST_FLOW_EOS;
    }
    return combineFlows(ogg, p, ret);
}

fn collectStartTime(chain: *Chain) u64 {
    var t: u64 = std.math.maxInt(u64);
    for (chain.streams.items) |p| {
        if (p.map.is_skeleton != 0) continue;
        if (p.start_time == NONE) {
            if (p.map.is_sparse == 0) return std.math.maxInt(u64);
        } else t = @min(t, p.start_time);
    }
    return t;
}

fn collectSyncTime(chain: ?*Chain) u64 {
    const ch = chain orelse return NONE;
    var t: u64 = NONE;
    for (ch.streams.items) |p| {
        if (p.map.is_sparse != 0) continue;
        if (p.push_sync_time == NONE) return NONE;
        t = if (t == NONE) p.push_sync_time else @max(t, p.push_sync_time);
    }
    return t;
}

fn submitPacket(p: *Pad, pk: *os.Packet) c.GstFlowReturn {
    const ogg = p.ogg.?;
    if (p.have_type == 0) {
        p.have_type = @intFromBool(os.setupMap(&p.map, pk));
        if (p.have_type == 0 and p.map.caps == null) p.map.caps = c.gst_caps_new_empty_simple("application/x-unknown");
        if (p.map.is_skeleton != 0) {
            ogg.basetime = p.map.basetime;
            ogg.prestime = p.map.prestime;
            if (ogg.total_time == NONE) {
                ogg.total_time = p.map.total_time;
            } else if (@as(i64, @bitCast(p.map.total_time)) > 0) ogg.total_time = @max(ogg.total_time, p.map.total_time);
        }
    }
    if (p.map.is_skeleton != 0) {
        var serial: u32 = 0;
        var kind: c_int = 0;
        if (os.parseFisbone(pk.packet, @intCast(pk.bytes), &serial, &kind)) {
            if (chainGetStream(p.chain.?, serial)) |sk| {
                if (kind == os.FISBONE) {
                    _ = os.addFisbone(&sk.map, pk.packet);
                } else if (kind == os.INDEX) {
                    _ = os.addIndex(&sk.map, &p.map, pk.packet, @intCast(pk.bytes));
                    ogg.check_index_overflow = 1;
                }
            }
        }
    }
    const g = os.granuleposToGranule(&p.map, pk.granulepos);
    if (g > 0) {
        p.current_granule = g;
    } else if (g != 0 and g != -1) return c.GST_FLOW_ERROR;
    if (pk.b_o_s != 0) {
        p.map.n_header_packets_seen = 0;
        if (p.map.have_headers == 0) freeList(&p.map.headers, packetFree);
    }
    pk.b_o_s = @intFromBool(os.packetIsHeader(&p.map, pk));
    if (pk.b_o_s == 0) {
        p.map.have_headers = 1;
        if (p.start_time == NONE) {
            const d = os.packetDuration(&p.map, pk);
            if (d != -1) p.map.accumulated_granule += d;
            if (pk.granulepos != -1) {
                const gg = os.granuleposToGranule(&p.map, pk.granulepos);
                if (gg < 0) return c.GST_FLOW_ERROR;
                const sg = if (gg >= p.map.accumulated_granule) gg - p.map.accumulated_granule else 0;
                p.start_time = os.granuleToTime(&p.map, sg);
            } else pk.granulepos = os.granuleToGranulepos(&p.map, p.map.accumulated_granule + p.current_granule, p.keyframe_granule);
        }
    } else {
        os.extractTags(&p.map, pk);
        p.map.n_header_packets_seen += 1;
        if (p.map.have_headers == 0) p.map.headers = c.g_list_append(p.map.headers, packetCopy(pk));
    }
    if (p.start_time != NONE and p.map.have_headers != 0) {
        const chain = p.chain;
        if (chain != null and chain == ogg.building_chain) {
            const ch = chain.?;
            var event: [*c]c.GstEvent = null;
            if (ogg.resync != 0) {
                const st = collectStartTime(ch);
                if (st != std.math.maxInt(u64)) {
                    const stime = if (ch.segment_start < st) (st - ch.segment_start) +% ch.begin_time else ch.begin_time;
                    var seg: c.GstSegment = undefined;
                    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
                    pushLock(ogg);
                    if (ogg.pullmode == 0 and ogg.push_state == PUSH_LINEAR2) {
                        seg.rate = ogg.push_seek_rate;
                        seg.start = ogg.push_seek_time_original_target;
                        seg.position = ogg.push_seek_time_original_target;
                        seg.stop = ogg.push_seek_time_original_stop;
                        seg.time = ogg.push_seek_time_original_target;
                        seg.base = ogg.segment.base;
                        event = c.gst_event_new_segment(&seg);
                        ogg.push_state = PUSH_PLAYING;
                    } else {
                        seg.rate = ogg.segment.rate;
                        seg.applied_rate = ogg.segment.applied_rate;
                        seg.start = st;
                        seg.position = st;
                        seg.stop = ch.segment_stop;
                        seg.time = stime;
                        seg.base = ogg.segment.base;
                        event = c.gst_event_new_segment(&seg);
                    }
                    pushUnlock(ogg);
                    ogg.resync = 0;
                }
            } else if (collectChainInfo(ch)) {
                var seg: c.GstSegment = undefined;
                c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
                seg.rate = ogg.segment.rate;
                seg.applied_rate = ogg.segment.applied_rate;
                seg.start = ch.segment_start;
                seg.position = ch.segment_start;
                seg.stop = ch.segment_stop;
                seg.time = ch.begin_time;
                seg.base = ogg.segment.base +% seg.time;
                event = c.gst_event_new_segment(&seg);
            }
            if (event != null) {
                c.gst_event_set_seqnum(event, ogg.seqnum);
                _ = activateChain(ogg, ch, event);
                ogg.building_chain = null;
            }
        }
    }
    if (ogg.building_chain != null) {
        if (pk.b_o_s == 0) return queueData(p, pk);
        return c.GST_FLOW_OK;
    }
    return chainPeer(p, pk, ogg.pullmode == 0);
}

fn streamOut(p: *Pad, n0: c_int) c.GstFlowReturn {
    const ogg = p.ogg.?;
    var n = n0;
    var result: c.GstFlowReturn = c.GST_FLOW_OK;
    pushLock(ogg);
    const drop = ogg.seek_event_drop_till != SEQNUM_INVALID;
    pushUnlock(ogg);
    if (drop) return result;
    var done = false;
    while (!done) {
        var pk: os.Packet = undefined;
        const r = c.ogg_stream_packetout(&p.map.stream, &pk);
        switch (r) {
            0 => done = true,
            -1 => {
                if (p.map.is_sparse == 0) {
                    markChainDiscont(p.chain.?);
                } else markDiscont(p);
            },
            1 => {
                if (pk.granulepos < -1) {
                    padReset(p);
                } else {
                    if (@as(u64, @intCast(pk.bytes)) > ogg.max_packet_size) ogg.max_packet_size = @intCast(pk.bytes);
                    result = submitPacket(p, &pk);
                    if (result != c.GST_FLOW_NOT_LINKED and result <= c.GST_FLOW_EOS) {
                        padReset(p);
                        return result;
                    }
                }
            },
            else => padReset(p),
        }
        if (n > 0) {
            n -= 1;
            done = n == 0;
        }
    }
    return result;
}

fn setupFirstGranule(p: *Pad, page: *c.ogg_page) void {
    if (p.current_granule != -1) return;
    const gp = c.ogg_page_granulepos(page);
    if (gp <= 0) return;
    var g = os.granuleposToGranule(&p.map, gp);
    const packets = c.ogg_page_packets(page);
    if (packets <= 0) return;
    var st = p.map.stream;
    const last = p.map.last_size;
    var valid = true;
    var n: c_int = 0;
    while (valid and n < packets) : (n += 1) {
        var op: os.Packet = undefined;
        const r = c.ogg_stream_packetout(&st, &op);
        if (r < 0) {
            if (r == -1 and n == 0) {
                n -= 1;
                continue;
            }
            valid = false;
            break;
        }
        if (r == 0) {
            valid = false;
            break;
        }
        g -= os.packetDuration(&p.map, &op);
    }
    p.map.last_size = last;
    if (valid) p.current_granule = if (g >= 0) g else 0;
}

fn setupBisectionBounds(o: *Demux) void {
    if (o.push_last_seek_time >= o.push_seek_time_target) {
        o.push_offset1 = o.push_last_seek_offset;
        o.push_time1 = o.push_last_seek_time;
        o.seek_undershot = 0;
    } else {
        o.push_offset0 = o.push_last_seek_offset;
        o.push_time0 = o.push_last_seek_time;
        o.seek_undershot = 1;
    }
}

fn estimateBisectionTarget(o: *Demux, quality: f32) i64 {
    var best: i64 = 0;
    if (o.push_time1 == NONE) {
        const rate: u64 = if (o.push_last_seek_time == o.push_start_time) @intCast(if (o.bitrate > 0) o.bitrate else 1000) else c.gst_util_uint64_scale(@bitCast(o.push_last_seek_offset), 8 * SECOND, o.push_last_seek_time -% o.push_start_time);
        best = o.push_offset0 +% @as(i64, @bitCast(c.gst_util_uint64_scale(o.push_seek_time_target -% o.push_time0, rate, 8 * SECOND)));
        o.seek_secant = 1;
    } else {
        if (o.push_time0 == o.push_time1) {
            best = o.push_offset0;
        } else {
            const rate = c.gst_util_uint64_scale(@bitCast(o.push_offset1 -% o.push_offset0), 8 * SECOND, o.push_time1 -% o.push_time0);
            best = o.push_offset0 +% @as(i64, @bitCast(c.gst_util_uint64_scale(o.push_seek_time_target -% o.push_time0, rate, 8 * SECOND)));
            if (quality < 0.5 and o.seek_secant != 0) {
                const best2 = @divTrunc(o.push_offset0 + o.push_offset1, 2);
                const w: f32 = @floatCast(1.0 - ((0.5 - @as(f64, quality)) / 0.5) * 0.25);
                const nb: f32 = @as(f32, @floatFromInt(best)) * w + @as(f32, @floatFromInt(best2)) * (1.0 - w);
                best = @intFromFloat(nb);
                o.seek_secant = 0;
            } else o.seek_secant = 1;
        }
    }
    if (o.seek_undershot == 0) {
        const skew: u64 = if (o.max_packet_size > o.max_page_size) o.max_packet_size else o.max_page_size;
        best -%= @bitCast(skew);
    }
    const mps: i64 = @bitCast(o.max_packet_size);
    if (best > o.push_offset1 - mps) {
        best = o.push_offset1 - mps;
    } else if (best < o.push_offset0 + mps) best = o.push_offset0 + mps;
    if (best > o.push_offset1) best = o.push_offset1;
    if (best < o.push_offset0) best = o.push_offset0;
    return best;
}

fn earliestKeyframeTime(o: *Demux) u64 {
    const chain = o.building_chain orelse return NONE;
    var t: u64 = NONE;
    for (chain.streams.items) |p| {
        if (p.map.is_sparse != 0) continue;
        if (p.push_kf_time == NONE) return NONE;
        if (t == NONE or p.push_kf_time < t) t = p.push_kf_time;
    }
    return t;
}

fn wakeSeekThread(o: *Demux) void {
    c.g_mutex_lock(&o.seek_event_mutex);
    c.g_cond_broadcast(&o.seek_event_cond);
    c.g_mutex_unlock(&o.seek_event_mutex);
}

fn seekBackUnlock(o: *Demux) c.GstFlowReturn {
    var ev = o.push_mode_seek_delayed_event;
    o.push_mode_seek_delayed_event = null;
    if (o.total_time == NONE) o.push_disable_seeking = 1;
    o.push_state = PUSH_PLAYING;
    if (ev == null) {
        ev = c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, c.GST_SEEK_FLAG_ACCURATE | c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 1, c.GST_SEEK_TYPE_SET, -1);
        o.seek_event_drop_till = c.gst_event_get_seqnum(ev);
    }
    _ = c.gst_mini_object_replace(@ptrCast(&o.seek_event), @ptrCast(ev));
    c.gst_event_unref(ev);
    pushUnlock(o);
    wakeSeekThread(o);
    return c.GST_FLOW_OK;
}

fn seekQuality(o: *Demux) f32 {
    if (o.push_prev_seek_time == NONE) return 1.0;
    var d = diff(o.push_seek_time_target, o.push_last_seek_time);
    if (d < 0) d = -d;
    var dist = diff(o.push_last_seek_time, o.push_prev_seek_time);
    if (dist < 0) dist = -dist;
    if (dist == 0) return 0.0;
    return 1.0 / (1.0 + @as(f32, @floatFromInt(d)) / @as(f32, @floatFromInt(dist)));
}

fn updateBisectionStats(o: *Demux) void {
    for (0..2) |n| {
        o.stats_bisection_steps[n] += o.push_bisection_steps[n];
        if (o.stats_bisection_max_steps[n] < o.push_bisection_steps[n]) o.stats_bisection_max_steps[n] = o.push_bisection_steps[n];
    }
    o.stats_nbisections += 1;
}

fn handlePushModeState(p: *Pad, page: *c.ogg_page) c.GstFlowReturn {
    const o = p.ogg.?;
    const gp = c.ogg_page_granulepos(page);
    pushLock(o);
    if (gp >= 0 and p.have_type != 0) {
        if (o.push_start_time == NONE) o.push_start_time = os.startTimeForGranulepos(&p.map, gp);
        o.push_time_offset = os.endTimeForGranulepos(&p.map, gp);
        if (o.push_state == PUSH_DURATION) {
            const t = os.endTimeForGranulepos(&p.map, gp);
            if (o.total_time == NONE or t > o.total_time) {
                o.total_time = t;
                o.push_time_length = t;
            }
            if (o.seek_event_drop_till != 0) {
                pushUnlock(o);
                return SKIP_PUSH;
            }
            if (o.push_byte_offset >= o.push_byte_length) {
                o.push_time_length = o.total_time;
                _ = c.gst_element_post_message(&o.element, c.gst_message_new_duration_changed(@ptrCast(o)));
                const r = seekBackUnlock(o);
                if (r != c.GST_FLOW_OK) return r;
                return SKIP_PUSH;
            }
            pushUnlock(o);
            return SKIP_PUSH;
        }
    }
    if (o.push_state != PUSH_PLAYING and o.push_state != PUSH_LINEAR2) {
        var best: i64 = -1;
        if (gp < 0) {
            pushUnlock(o);
            if (c.ogg_stream_pagein(&p.map.stream, page) != 0) {
                padReset(p);
                return SKIP_PUSH;
            }
            if (p.current_granule == -1) setupFirstGranule(p, page);
            return SKIP_PUSH;
        }
        const t = os.endTimeForGranulepos(&p.map, gp);
        if (o.push_state == PUSH_BISECT1 or o.push_state == PUSH_BISECT2) {
            if (p.push_sync_time == NONE) p.push_sync_time = t;
            const sync = collectSyncTime(o.building_chain);
            if (sync == NONE) {
                pushUnlock(o);
                if (c.ogg_stream_pagein(&p.map.stream, page) != 0) {
                    padReset(p);
                    return SKIP_PUSH;
                }
                if (p.current_granule == -1) setupFirstGranule(p, page);
                return SKIP_PUSH;
            }
            o.push_last_seek_time = sync;
            const q: f32 = if (o.push_time1 != NONE) seekQuality(o) else 1.0;
            o.push_prev_seek_time = o.push_last_seek_time;
            setupBisectionBounds(o);
            best = estimateBisectionTarget(o, q);
            var close = false;
            if (o.push_seek_time_target == 0) {
                close = o.push_last_seek_time == 0;
            } else {
                var tt: u64 = SECOND / 2;
                const bt: u64 = if (o.max_packet_size > 64 * 1024) o.max_packet_size else 64 * 1024;
                if (tt > o.push_seek_time_target) tt = o.push_seek_time_target;
                close = o.push_last_seek_time < o.push_seek_time_target and (o.push_last_seek_time >= o.push_seek_time_target - tt or o.push_offset1 <= o.push_offset0 +% @as(i64, @bitCast(bt)));
            }
            if (close or best == o.push_last_seek_offset) {
                if (o.push_state == PUSH_BISECT1) {
                    o.push_time0 = o.push_start_time;
                    o.push_offset0 = 0;
                    o.push_state = PUSH_LINEAR1;
                } else {
                    o.push_state = if (o.push_seek_flags & c.GST_SEEK_FLAG_ACCURATE != 0) PUSH_LINEAR2 else PUSH_PLAYING;
                    updateBisectionStats(o);
                }
            }
        } else if (o.push_state == PUSH_LINEAR1) {
            if (p.push_kf_time == NONE) {
                const kg = os.granuleposToKeyGranule(&p.map, gp);
                p.push_kf_time = os.granuleToTime(&p.map, kg);
                const early = earliestKeyframeTime(o);
                if (early != NONE) {
                    if (early > o.push_last_seek_time) {
                        o.push_state = PUSH_PLAYING;
                        updateBisectionStats(o);
                    } else {
                        o.push_seek_time_target = early;
                        o.push_offset0 = 0;
                        o.push_time0 = o.push_start_time;
                        o.push_offset1 = o.push_last_seek_offset;
                        o.push_time1 = o.push_last_seek_time;
                        o.push_prev_seek_time = NONE;
                        o.seek_secant = 0;
                        o.seek_undershot = 0;
                        o.push_state = PUSH_BISECT2;
                        best = estimateBisectionTarget(o, 1.0);
                    }
                }
            }
        }
        if (o.push_state == PUSH_BISECT1 or o.push_state == PUSH_BISECT2) {
            _ = c.ogg_sync_reset(&o.sync);
            for (o.building_chain.?.streams.items) |sp| {
                sp.push_sync_time = NONE;
                _ = c.ogg_stream_reset(&sp.map.stream);
            }
            o.push_bisection_steps[if (o.push_state == PUSH_BISECT2) 1 else 0] += 1;
            const sev = c.gst_event_new_seek(o.push_seek_rate, c.GST_FORMAT_BYTES, o.push_seek_flags, c.GST_SEEK_TYPE_SET, best, c.GST_SEEK_TYPE_NONE, -1);
            c.gst_event_set_seqnum(sev, o.seqnum);
            _ = c.gst_mini_object_replace(@ptrCast(&o.seek_event), @ptrCast(sev));
            c.gst_event_unref(sev);
            pushUnlock(o);
            wakeSeekThread(o);
            return SKIP_PUSH;
        }
        if (o.push_state != PUSH_PLAYING) {
            pushUnlock(o);
            return SKIP_PUSH;
        }
    }
    pushUnlock(o);
    return c.GST_FLOW_OK;
}

fn queryDurationPush(o: *Demux) void {
    if (o.pullmode == 0 and o.push_byte_length == -1) {
        const q = c.gst_query_new_seeking(c.GST_FORMAT_BYTES);
        var seekable: c.gboolean = 0;
        if (c.gst_pad_peer_query(o.sinkpad, q) != 0) c.gst_query_parse_seeking(q, null, &seekable, null, null);
        c.gst_query_unref(q);
        if (seekable != 0) {
            var len: i64 = -1;
            o.push_disable_seeking = @intFromBool(c.gst_element_query_duration(&o.element, c.GST_FORMAT_BYTES, &len) == 0 or len <= 0);
        } else o.push_disable_seeking = 1;
    }
}

fn submitPage(p: *Pad, page: *c.ogg_page) c.GstFlowReturn {
    const o = p.ogg.?;
    var result: c.GstFlowReturn = c.GST_FLOW_OK;
    var continued = false;
    done: {
        if (o.segment.rate < 0.0) {
            continued = c.ogg_page_continued(page) != 0;
            var n = c.ogg_page_packets(page);
            if (!continued and n == 0) n = 1;
            if (n == 0) break :done;
        }
        queryDurationPush(o);
        if (o.pullmode == 0) {
            result = handlePushModeState(p, page);
            if (result == SKIP_PUSH) return c.GST_FLOW_OK;
            if (result != c.GST_FLOW_OK) return result;
        }
        const size: u64 = @intCast(page.header_len + page.body_len);
        if (size > o.max_page_size) o.max_page_size = size;
        if (c.ogg_stream_pagein(&p.map.stream, page) != 0) {
            padReset(p);
            return c.GST_FLOW_OK;
        }
        if (p.current_granule == -1) setupFirstGranule(p, page);
        result = streamOut(p, 0);
        if (p.continued != null) {
            while (p.continued != null) {
                const pg: *c.ogg_page = @ptrCast(@alignCast(p.continued.*.data));
                if (c.ogg_stream_pagein(&p.map.stream, pg) != 0) {
                    padReset(p);
                    return c.GST_FLOW_OK;
                }
                p.continued = c.g_list_delete_link(p.continued, p.continued);
                pageFree(pg, null);
            }
            result = streamOut(p, 1);
            var pk: os.Packet = undefined;
            while (c.ogg_stream_packetout(&p.map.stream, &pk) != 0) {}
        }
    }
    if (continued) p.continued = c.g_list_prepend(p.continued, pageCopy(page));
    return result;
}

fn chainNew(o: *Demux) *Chain {
    const ch = A.create(Chain) catch unreachable;
    ch.* = .{ .ogg = o };
    return ch;
}

fn chainFree(ch: *Chain) void {
    for (ch.streams.items) |p| c.gst_object_unref(p);
    ch.streams.deinit(A);
    A.destroy(ch);
}

fn markDiscont(p: *Pad) void {
    p.discont = 1;
    p.map.last_size = 0;
}

fn markChainDiscont(ch: *Chain) void {
    for (ch.streams.items) |p| markDiscont(p);
}

fn chainReset(ch: *Chain) void {
    for (ch.streams.items) |p| padReset(p);
}

fn chainNewStream(ch: *Chain, serial: u32) ?*Pad {
    const name = c.g_strdup_printf("src_%08x", serial);
    const ret: *Pad = @ptrCast(@alignCast(c.g_object_new(padType(), "name", name, @as(?*anyopaque, null))));
    c.g_free(name);
    _ = c.gst_object_ref_sink(ret);
    ret.pad.direction = c.GST_PAD_SRC;
    markDiscont(ret);
    ret.chain = ch;
    ret.ogg = ch.ogg;
    ret.map.serialno = serial;
    if (c.ogg_stream_init(&ret.map.stream, @bitCast(serial)) != 0) {
        c.gst_object_unref(ret);
        return null;
    }
    ch.streams.append(A, ret) catch unreachable;
    _ = c.gst_pad_set_active(gpad(ret), 1);
    return ret;
}

fn chainGetStream(ch: *Chain, serial: u32) ?*Pad {
    for (ch.streams.items) |p| {
        if (p.map.serialno == serial) return p;
    }
    return null;
}

fn finalize(ob: [*c]c.GObject) callconv(.c) void {
    const o = me(ob);
    o.chains.?.deinit(A);
    A.destroy(o.chains.?);
    c.g_mutex_clear(&o.chain_lock);
    c.g_mutex_clear(&o.push_lock);
    c.g_cond_clear(&o.seek_event_cond);
    c.g_cond_clear(&o.thread_started_cond);
    c.g_mutex_clear(&o.seek_event_mutex);
    _ = c.ogg_sync_clear(&o.sync);
    if (o.newsegment != null) c.gst_event_unref(o.newsegment);
    c.gst_flow_combiner_free(o.flowcombiner);
    if (o.building_chain) |b| chainFree(b);
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).finalize.?(ob);
}

fn resetStreams(o: *Demux) void {
    const ch = o.current_chain orelse return;
    for (ch.streams.items) |p| {
        p.start_time = NONE;
        p.map.accumulated_granule = 0;
        p.current_granule = -1;
        p.keyframe_granule = -1;
    }
    o.building_chain = ch;
    o.current_chain = null;
    o.resync = 1;
    markChainDiscont(ch);
    o.chunk_size = CHUNKSIZE;
}

fn sinkEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev0: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const o = me(parent);
    var ev = ev0;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_FLUSH_START => {
            if (o.seqnum != SEQNUM_INVALID) {
                ev = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev)));
                c.gst_event_set_seqnum(ev, o.seqnum);
            }
            return @intFromBool(sendEvent(o, ev));
        },
        c.GST_EVENT_FLUSH_STOP => {
            _ = c.ogg_sync_reset(&o.sync);
            if (o.seqnum != SEQNUM_INVALID) {
                ev = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev)));
                c.gst_event_set_seqnum(ev, o.seqnum);
            }
            const r = sendEvent(o, ev);
            if (o.pullmode != 0 or o.push_state != PUSH_DURATION) resetStreams(o);
            return @intFromBool(r);
        },
        c.GST_EVENT_SEGMENT => {
            var seg: c.GstSegment = undefined;
            c.gst_event_copy_segment(ev, &seg);
            if (seg.format == c.GST_FORMAT_BYTES) {
                pushLock(o);
                o.push_byte_offset = @bitCast(seg.start);
                o.push_last_seek_offset = @bitCast(seg.start);
                if (c.gst_event_get_seqnum(ev) == o.seqnum) {
                    const stop_type: c.GstSeekType = if (o.push_seek_time_original_stop != NONE) c.GST_SEEK_TYPE_SET else c.GST_SEEK_TYPE_NONE;
                    var update: c.gboolean = 0;
                    _ = c.gst_segment_do_seek(&o.segment, o.push_seek_rate, c.GST_FORMAT_TIME, o.push_seek_flags, c.GST_SEEK_TYPE_SET, o.push_seek_time_original_target, stop_type, o.push_seek_time_original_stop, &update);
                } else if (o.seqnum == SEQNUM_INVALID) o.seqnum = c.gst_event_get_seqnum(ev);
                if (o.pullmode == 0 and o.push_seek_flags & c.GST_SEEK_FLAG_FLUSH == 0) {
                    o.push_seek_flags = 0;
                    if (o.current_chain) |ch| {
                        if (o.push_state != PUSH_DURATION) {
                            for (ch.streams.items) |p| {
                                p.push_kf_time = NONE;
                                p.push_sync_time = NONE;
                            }
                            _ = c.ogg_sync_reset(&o.sync);
                            resetStreams(o);
                        }
                    } else _ = c.ogg_sync_reset(&o.sync);
                }
                if (o.pullmode == 0) {
                    if (o.seek_event_drop_till == c.gst_event_get_seqnum(ev)) o.seek_event_drop_till = 0;
                }
                pushUnlock(o);
            }
            c.gst_event_unref(ev);
            return 1;
        },
        c.GST_EVENT_EOS => {
            var drop = false;
            var res: c.gboolean = 1;
            pushLock(o);
            if (o.push_state == PUSH_DURATION) {
                _ = seekBackUnlock(o);
                c.gst_event_unref(ev);
                return 1;
            }
            if (o.seek_event_drop_till > 0) drop = true;
            pushUnlock(o);
            if (!drop) {
                res = @intFromBool(sendEvent(o, ev));
            } else c.gst_event_unref(ev);
            if (o.current_chain == null) {
                o.push_disable_seeking = 1;
                res = 1;
            }
            return res;
        },
        else => return c.gst_pad_event_default(pad, parent, ev),
    }
}

fn submitBuffer(o: *Demux, b: [*c]c.GstBuffer) c.GstFlowReturn {
    defer c.gst_buffer_unref(b);
    const size = c.gst_buffer_get_size(b);
    if (size == 0) return c.GST_FLOW_OK;
    const ob = c.ogg_sync_buffer(&o.sync, @intCast(size));
    if (ob == null) {
        cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("failed to get ogg sync buffer"), FILE, "gst_ogg_demux_submit_buffer", 2626);
        return c.GST_FLOW_ERROR;
    }
    _ = c.gst_buffer_extract(b, 0, ob, size);
    if (c.ogg_sync_wrote(&o.sync, @intCast(size)) < 0) {
        cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("failed to write %lu bytes to the sync buffer", size), FILE, "gst_ogg_demux_submit_buffer", 2633);
        return c.GST_FLOW_ERROR;
    }
    if (o.pullmode == 0) {
        pushLock(o);
        o.push_byte_offset += @intCast(size);
        pushUnlock(o);
    }
    return c.GST_FLOW_OK;
}

fn seek(o: *Demux, off: i64) void {
    o.offset = off;
    o.read_offset = off;
    _ = c.ogg_sync_reset(&o.sync);
}

fn getData(o: *Demux, end: i64) c.GstFlowReturn {
    if (end > 0 and o.read_offset >= end) return FLOW_LIMIT;
    if (o.read_offset == o.length) return c.GST_FLOW_EOS;
    const ob = c.ogg_sync_buffer(&o.sync, o.chunk_size);
    if (ob == null) {
        cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("failed to get ogg sync buffer"), FILE, "gst_ogg_demux_get_data", 2712);
        return c.GST_FLOW_ERROR;
    }
    var b = c.gst_buffer_new_wrapped_full(0, ob, @intCast(o.chunk_size), 0, @intCast(o.chunk_size), null, null);
    const ret = c.gst_pad_pull_range(o.sinkpad, @bitCast(o.read_offset), @intCast(o.chunk_size), &b);
    if (ret != c.GST_FLOW_OK) {
        c.gst_buffer_unref(b);
        return ret;
    }
    const size = c.gst_buffer_get_size(b);
    if (c.ogg_sync_wrote(&o.sync, @intCast(size)) < 0) {
        cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("failed to write %lu bytes to the sync buffer", size), FILE, "gst_ogg_demux_get_data", 2725);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_ERROR;
    }
    o.read_offset += @intCast(size);
    c.gst_buffer_unref(b);
    return ret;
}

fn nextPage(o: *Demux, og: *c.ogg_page, boundary: i64, offset: ?*i64) c.GstFlowReturn {
    var end: i64 = -1;
    if (boundary >= 0) end = o.offset + boundary;
    while (true) {
        if (end > 0 and o.offset >= end) return FLOW_LIMIT;
        const more = c.ogg_sync_pageseek(&o.sync, og);
        if (more < 0) {
            o.offset -= more;
        } else if (more == 0) {
            if (boundary == 0) return FLOW_LIMIT;
            const r = getData(o, end);
            if (r != c.GST_FLOW_OK) return r;
        } else {
            if (offset) |x| x.* = o.offset;
            o.offset += more;
            return c.GST_FLOW_OK;
        }
    }
}

fn prevPage(o: *Demux, og: *c.ogg_page, offset: ?*i64) c.GstFlowReturn {
    var begin = o.offset;
    const end = begin;
    var cur: i64 = -1;
    while (cur == -1) {
        begin -= o.chunk_size;
        if (begin < 0) begin = 0;
        seek(o, begin);
        while (o.offset < end) {
            var nb = end - o.offset;
            if (nb > 2 * MAX_PAGE) nb = 2 * MAX_PAGE;
            var noff: i64 = 0;
            const r = nextPage(o, og, nb, &noff);
            if (r == FLOW_LIMIT) break;
            if (r == c.GST_FLOW_EOS) return r;
            if (r != c.GST_FLOW_OK) return r;
            cur = noff;
        }
    }
    seek(o, cur);
    const r = nextPage(o, og, -1, null);
    if (r != c.GST_FLOW_OK) return r;
    if (offset) |x| x.* = cur;
    return r;
}

fn deactivateCurrentChain(o: *Demux) bool {
    const ch = o.current_chain orelse return true;
    for (ch.streams.items) |p| {
        if (p.added == 0) continue;
        const ev = c.gst_event_new_eos();
        c.gst_event_set_seqnum(ev, o.seqnum);
        _ = c.gst_pad_push_event(gpad(p), ev);
        _ = c.gst_pad_set_active(gpad(p), 0);
        c.gst_flow_combiner_remove_pad(o.flowcombiner, gpad(p));
        _ = c.gst_element_remove_pad(&o.element, gpad(p));
        p.added = 0;
    }
    if (o.pullmode == 0) {
        if (o.building_chain == ch) o.building_chain = null;
        o.current_chain = null;
        chainFree(ch);
    }
    return true;
}

fn headerOnCaps(caps0: [*c]c.GstCaps, headers: [*c]c.GList) [*c]c.GstCaps {
    if (caps0 == null) return null;
    if (headers == null) return caps0;
    const caps: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps0)));
    const st = c.gst_caps_get_structure(caps, 0);
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    var l = headers;
    while (l != null) : (l = l.*.next) {
        const op: *os.Packet = @ptrCast(@alignCast(l.*.data));
        const b = c.gst_buffer_new_allocate(null, @intCast(op.bytes), null);
        if (op.bytes != 0) _ = c.gst_buffer_fill(b, 0, op.packet, @intCast(op.bytes));
        cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_HEADER;
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.gst_buffer_get_type());
        c.gst_value_take_buffer(&v, b);
        c.gst_value_array_append_value(&arr, &v);
        c.g_value_unset(&v);
    }
    c.gst_structure_take_value(st, "streamheader", &arr);
    return caps;
}

fn pushQueued(p: *Pad) void {
    var l = p.map.queued;
    while (l != null) : (l = l.*.next) {
        const pk: *os.Packet = @ptrCast(@alignCast(l.*.data));
        _ = chainPeer(p, pk, true);
        packetFree(pk, null);
    }
    c.g_list_free(p.map.queued);
    p.map.queued = null;
}

fn activateChain(o: *Demux, ch: *Chain, ev: [*c]c.GstEvent) bool {
    if (o.current_chain == ch) {
        if (ev != null) c.gst_event_unref(ev);
        for (ch.streams.items) |p| pushQueued(p);
        return true;
    }
    var bitrate: c.gint = 0;
    var idx_bitrate: u64 = 0;
    for (ch.streams.items) |p| {
        if (p.map.idx_bitrate != 0) idx_bitrate = @max(idx_bitrate, p.map.idx_bitrate);
        bitrate +%= p.map.bitrate;
        markDiscont(p);
        p.last_ret = c.GST_FLOW_OK;
        if (p.map.is_skeleton != 0 or p.map.is_cmml != 0 or p.added != 0 or p.map.caps == null) continue;
        _ = c.gst_pad_set_active(gpad(p), 1);
        const sid = c.gst_pad_create_stream_id_printf(gpad(p), &o.element, "%08x", p.map.serialno);
        var ss = c.gst_pad_get_sticky_event(o.sinkpad, c.GST_EVENT_STREAM_START, 0);
        if (ss != null) {
            o.have_group_id = c.gst_event_parse_group_id(ss, &o.group_id);
            c.gst_event_unref(ss);
        } else if (o.have_group_id == 0) {
            o.have_group_id = 1;
            o.group_id = c.gst_util_group_id_next();
        }
        ss = c.gst_event_new_stream_start(sid);
        if (o.have_group_id != 0) c.gst_event_set_group_id(ss, o.group_id);
        _ = c.gst_pad_push_event(gpad(p), ss);
        c.g_free(sid);
        p.map.caps = headerOnCaps(p.map.caps, p.map.headers);
        _ = cm.setCaps(gpad(p), p.map.caps);
        _ = c.gst_element_add_pad(&o.element, gpad(p));
        p.added = 1;
        c.gst_flow_combiner_add_pad(o.flowcombiner, gpad(p));
    }
    o.bitrate = if (idx_bitrate != 0) @truncate(@as(i64, @bitCast(idx_bitrate))) else bitrate;
    _ = deactivateCurrentChain(o);
    o.current_chain = ch;
    c.gst_element_no_more_pads(&o.element);
    for (ch.streams.items) |p| {
        if (p.added == 0) continue;
        if (ev != null) _ = c.gst_pad_push_event(gpad(p), @ptrCast(c.gst_mini_object_ref(@ptrCast(ev))));
        if (p.map.taglist) |t| {
            _ = c.gst_pad_push_event(gpad(p), c.gst_event_new_tag(t));
            p.map.taglist = null;
        }
        const tags = c.gst_tag_list_new("container-format", @as([*:0]const u8, "Ogg"), @as(?*anyopaque, null));
        c.gst_tag_list_set_scope(tags, c.GST_TAG_SCOPE_GLOBAL);
        _ = c.gst_pad_push_event(gpad(p), c.gst_event_new_tag(tags));
        var l = p.map.headers;
        while (l != null) : (l = l.*.next) _ = chainPeer(p, @ptrCast(@alignCast(l.*.data)), true);
        pushQueued(p);
    }
    if (ev != null) c.gst_event_unref(ev);
    return true;
}

fn binarySearch(o: *Demux, ch: *Chain, begin0: i64, end0: i64, begintime0: i64, endtime0: i64, target: i64, out: *i64, only_serial: bool, serialno: c_int) bool {
    var begin = begin0;
    var end = end0;
    var begintime = begintime0;
    var endtime = endtime0;
    var best = begin;
    var result: i64 = 0;
    while (begin < end) {
        var bisect: i64 = 0;
        if (end - begin < o.chunk_size or endtime == begintime) {
            bisect = begin;
        } else {
            const rate = @divTrunc((end - begin) *% @as(i64, MS), endtime - begintime);
            bisect = @divTrunc(target - begintime, @as(i64, MS)) *% rate +% begin -% o.chunk_size;
            if (bisect <= begin) bisect = begin;
        }
        seek(o, bisect);
        while (begin < end) {
            var og: c.ogg_page = undefined;
            const r = nextPage(o, &og, end - o.offset, &result);
            if (r == FLOW_LIMIT) {
                if (bisect <= begin + 1) {
                    end = begin;
                } else {
                    if (bisect == 0) return false;
                    bisect -= o.chunk_size;
                    if (bisect <= begin) bisect = begin + 1;
                    seek(o, bisect);
                }
            } else if (r == c.GST_FLOW_OK) {
                const gp = c.ogg_page_granulepos(&og);
                if (gp == -1) continue;
                if (only_serial and c.ogg_page_serialno(&og) != serialno) continue;
                const p = chainGetStream(ch, @bitCast(c.ogg_page_serialno(&og))) orelse continue;
                if (p.map.is_skeleton != 0) continue;
                var gt = os.endTimeForGranulepos(&p.map, gp);
                if (gt < p.start_time) continue;
                gt -= p.start_time;
                gt +%= ch.begin_time;
                const gti: i64 = @bitCast(gt);
                if (gti < target) {
                    best = result;
                    begin = o.offset;
                    begintime = gti;
                    bisect = begin;
                } else {
                    if (bisect <= begin + 1) {
                        end = begin;
                    } else {
                        if (end == o.offset) {
                            end = result;
                            bisect -= o.chunk_size;
                            if (bisect <= begin) bisect = begin + 1;
                            seek(o, bisect);
                        } else {
                            end = result;
                            endtime = gti;
                            break;
                        }
                    }
                }
            } else return false;
        }
    }
    seek(o, best);
    out.* = best;
    return true;
}

fn indexSearch(ch: *Chain, begintime: i64, target0: i64, off: *i64, ts: *i64) bool {
    const target = target0 - begintime;
    var r_off: u64 = NONE;
    var r_ts: u64 = NONE;
    var found = false;
    for (ch.streams.items) |p| {
        var t: u64 = @bitCast(target);
        var o: u64 = 0;
        if (os.searchIndex(&p.map, &t, &o)) {
            if (r_off == NONE or o < r_off) {
                r_off = o;
                r_ts = t;
            }
            found = true;
        }
    }
    ts.* = @bitCast(r_ts);
    off.* = @bitCast(r_off);
    return found;
}

fn doSeek(o: *Demux, segment: *c.GstSegment, keyframe: bool, rchain: *?*Chain) bool {
    const position = segment.position;
    var total: u64 = o.total_time;
    const chains = o.chains.?;
    if (chains.items.len == 0) return false;
    var chain: *Chain = undefined;
    var i: isize = @intCast(chains.items.len - 1);
    while (i >= 0) : (i -= 1) {
        chain = chains.items[@intCast(i)];
        total -%= chain.total_time;
        if (position >= total) break;
    }
    const begin = chain.offset;
    const end = chain.end_offset;
    const begintime: i64 = @bitCast(chain.begin_time);
    const endtime = begintime +% @as(i64, @bitCast(chain.total_time));
    const target: i64 = @as(i64, @bitCast(position)) -% @as(i64, @bitCast(total)) +% begintime;
    var best: i64 = 0;
    if (!binarySearch(o, chain, begin, end, begintime, endtime, target, &best, false, 0)) return false;
    var pending: isize = @intCast(chain.streams.items.len);
    for (chain.streams.items) |p| {
        if (p.map.is_skeleton != 0 or p.map.is_sparse != 0) pending -= 1;
    }
    var keytarget = target;
    var serialno: c_int = 0;
    var found = false;
    var first_ts: u64 = NONE;
    var result: i64 = 0;
    while (true) {
        var og: c.ogg_page = undefined;
        const r = nextPage(o, &og, end - o.offset, &result);
        if (r == FLOW_LIMIT) break;
        if (r != c.GST_FLOW_OK) return false;
        const p = chainGetStream(chain, @bitCast(c.ogg_page_serialno(&og))) orelse continue;
        skip: {
            if (p.map.is_skeleton != 0 or p.map.is_sparse != 0) break :skip;
            const gp = c.ogg_page_granulepos(&og);
            if (gp == -1 or gp == 0) continue;
            const ts = os.endTimeForGranulepos(&p.map, gp);
            if (ts != NONE) {
                if (first_ts == NONE) first_ts = ts;
                if (ts -% first_ts > GIVE_UP) {
                    found = false;
                    keytarget = target;
                    break;
                }
            }
            if (segment.rate < 0.0) {
                var gt = os.endTimeForGranulepos(&p.map, gp);
                gt -%= p.start_time;
                gt +%= chain.begin_time;
                if (@as(i64, @bitCast(gt)) < target) continue;
            }
            if (p.keyframe_granule != -1) continue;
            p.keyframe_granule = os.granuleposToKeyGranule(&p.map, gp);
            var kt = os.granuleToTime(&p.map, p.keyframe_granule);
            if (kt != NONE) {
                kt -%= p.start_time;
                kt +%= @bitCast(begintime);
                if (@as(i64, @bitCast(kt)) < keytarget) {
                    serialno = @bitCast(p.map.serialno);
                    keytarget = @bitCast(kt);
                    found = true;
                }
            }
        }
        pending -= 1;
        if (pending == 0) break;
    }
    if (segment.rate >= 0.0) {
        if (!found) best = 0;
        if (keytarget != target) {
            if (!binarySearch(o, chain, begin, end, begintime, endtime, keytarget, &best, true, serialno)) return false;
        } else seek(o, best);
    }
    if (keyframe) {
        if (segment.rate > 0.0) segment.time = @bitCast(keytarget);
        segment.position = @bitCast(keytarget -% begintime);
    }
    rchain.* = chain;
    return true;
}

fn performSeekPull(o: *Demux, event: [*c]c.GstEvent) bool {
    var rate: f64 = 1.0;
    var format: c.GstFormat = c.GST_FORMAT_TIME;
    var flags: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    var seqnum: u32 = 0;
    defer if (event != null) c.gst_event_unref(event);
    if (event != null) {
        c.gst_event_parse_seek(event, &rate, &format, &flags, &st, &start, &et, &stop);
        if (format != c.GST_FORMAT_TIME) return false;
        seqnum = c.gst_event_get_seqnum(event);
    } else seqnum = c.gst_util_seqnum_next();
    const keyframe = flags & c.GST_SEEK_FLAG_KEY_UNIT != 0;
    _ = c.gst_pad_pause_task(o.sinkpad);
    cm.streamLock(o.sinkpad);
    if (event != null) {
        var update: c.gboolean = 0;
        _ = c.gst_segment_do_seek(&o.segment, rate, format, flags, st, @bitCast(start), et, @bitCast(stop), &update);
    }
    for (o.chains.?.items) |ch| chainReset(ch);
    var chain: ?*Chain = null;
    if (!doSeek(o, &o.segment, keyframe, &chain)) chain = o.current_chain;
    const ch = chain orelse {
        cm.streamUnlock(o.sinkpad);
        return false;
    };
    const begin_time: u64 = if (ch.begin_time != NONE) ch.begin_time else 0;
    var sstart = o.segment.start -% begin_time;
    if (ch.segment_start != NONE) sstart +%= ch.segment_start;
    var sstop = o.segment.stop;
    if (sstop == NONE) sstop = o.segment.duration;
    if (sstop != NONE) {
        sstop = if (@as(i64, @bitCast(sstop)) > @as(i64, @bitCast(begin_time))) sstop - begin_time else 0;
        sstop +%= ch.segment_start;
        sstop = @bitCast(@min(@as(i64, @bitCast(sstop)), @as(i64, @bitCast(ch.segment_stop))));
    }
    var position = o.segment.position;
    if (ch.segment_start != NONE) position +%= ch.segment_start;
    var seg: c.GstSegment = undefined;
    c.gst_segment_copy_into(&o.segment, &seg);
    if (o.segment.rate >= 0.0) {
        seg.start = position;
        seg.stop = sstop;
    } else {
        seg.start = sstart;
        seg.stop = position;
    }
    const ev = c.gst_event_new_segment(&seg);
    c.gst_event_set_seqnum(ev, seqnum);
    if (ch != o.current_chain) {
        _ = activateChain(o, ch, ev);
    } else {
        markChainDiscont(ch);
        if (o.newsegment != null) c.gst_event_unref(o.newsegment);
        o.newsegment = ev;
    }
    if (o.segment.flags & c.GST_SEEK_FLAG_SEGMENT != 0) {
        const m = c.gst_message_new_segment_start(@ptrCast(o), c.GST_FORMAT_TIME, @bitCast(o.segment.position));
        c.gst_message_set_seqnum(m, seqnum);
        _ = c.gst_element_post_message(&o.element, m);
    }
    o.seqnum = seqnum;
    _ = c.gst_pad_start_task(o.sinkpad, loop, o.sinkpad, null);
    cm.streamUnlock(o.sinkpad);
    return true;
}

fn getDurationPush(o: *Demux, flags: c.GstSeekFlags) bool {
    var pos = o.push_byte_length - DURATION_CHUNK_OFFSET;
    if (pos < 0) pos = 0;
    o.push_state = PUSH_DURATION;
    const ev = c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, flags, c.GST_SEEK_TYPE_SET, pos, c.GST_SEEK_TYPE_SET, o.push_byte_length - 1);
    _ = c.gst_mini_object_replace(@ptrCast(&o.seek_event), @ptrCast(ev));
    o.seek_event_drop_till = c.gst_event_get_seqnum(ev);
    c.gst_event_unref(ev);
    wakeSeekThread(o);
    return true;
}

fn checkDurationPush(o: *Demux, flags: c.GstSeekFlags, event: [*c]c.GstEvent) bool {
    if (o.push_byte_length < 0) {
        const peer = c.gst_pad_get_peer(o.sinkpad) orelse return true;
        var len: i64 = 0;
        if (c.gst_pad_query_duration(peer, c.GST_FORMAT_BYTES, &len) != 0 and len > 0) {
            o.push_byte_length = len;
        } else {
            o.push_disable_seeking = 1;
            c.gst_object_unref(peer);
            return true;
        }
        const ok = c.gst_pad_query_duration(peer, c.GST_FORMAT_TIME, &len) != 0;
        c.gst_object_unref(peer);
        if (ok and len >= 0) {
            o.push_time_length = @bitCast(len);
        } else if (o.push_disable_seeking == 0) {
            if (getDurationPush(o, flags)) {
                o.push_mode_seek_delayed_event = null;
                if (event != null) o.push_mode_seek_delayed_event = @ptrCast(c.gst_mini_object_copy(@ptrCast(event)));
                return false;
            }
        }
    }
    return true;
}

fn performSeekPush(o: *Demux, event: [*c]c.GstEvent) bool {
    var rate: f64 = 0;
    var format: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    c.gst_event_parse_seek(event, &rate, &format, &flags, &st, &start, &et, &stop);
    if (format != c.GST_FORMAT_TIME) return false;
    if (st != c.GST_SEEK_TYPE_SET) return false;
    if (et == c.GST_SEEK_TYPE_NONE) stop = -1;
    const ch = o.current_chain orelse return false;
    pushLock(o);
    if (o.push_disable_seeking != 0 or o.push_state == PUSH_DURATION or o.push_state != PUSH_PLAYING) {
        pushUnlock(o);
        return false;
    }
    if (!checkDurationPush(o, flags, event)) {
        pushUnlock(o);
        return false;
    }
    var best: i64 = 0;
    var best_time: i64 = 0;
    if (!indexSearch(ch, 0, start, &best, &best_time)) {
        var bitrate: u64 = 0;
        if (@as(i64, @bitCast(o.push_time_length)) > 0) {
            bitrate = c.gst_util_uint64_scale(@bitCast(o.push_byte_length), 8 * SECOND, o.push_time_length);
        } else if (@as(i64, @bitCast(o.push_time_offset)) > 0) {
            bitrate = c.gst_util_uint64_scale(@bitCast(o.push_byte_offset), 8 * SECOND, o.push_time_offset);
        } else if (o.bitrate > 0) {
            bitrate = @intCast(o.bitrate);
        } else bitrate = 1000;
        bitrate = @as(u32, @truncate(bitrate));
        best = @bitCast(c.gst_util_uint64_scale(@bitCast(start), @as(u64, @bitCast(@as(i64, @as(c.gint, @bitCast(@as(u32, @truncate(bitrate))))))), 8 * SECOND));
    }
    best -= o.chunk_size;
    if (best < 0) best = 0;
    if (o.push_byte_length > 0 and best >= o.push_byte_length) best = o.push_byte_length - 1;
    o.push_offset0 = 0;
    o.push_offset1 = o.push_byte_length - 1;
    o.push_time0 = o.push_start_time;
    o.push_time1 = o.push_time_length;
    o.seqnum = c.gst_event_get_seqnum(event);
    o.push_seek_time_target = @bitCast(start);
    o.push_prev_seek_time = NONE;
    o.push_seek_time_original_target = @bitCast(start);
    o.push_seek_time_original_stop = @bitCast(stop);
    o.push_state = PUSH_BISECT1;
    o.seek_secant = 0;
    o.seek_undershot = 0;
    if (flags & c.GST_SEEK_FLAG_FLUSH != 0) {
        for (ch.streams.items) |p| {
            p.push_kf_time = NONE;
            p.push_sync_time = NONE;
        }
    }
    o.push_seek_rate = rate;
    o.push_seek_flags = flags;
    o.push_mode_seek_delayed_event = null;
    o.push_bisection_steps = .{ 1, 0 };
    const sev = c.gst_event_new_seek(rate, c.GST_FORMAT_BYTES, flags, st, best, c.GST_SEEK_TYPE_NONE, -1);
    c.gst_event_set_seqnum(sev, c.gst_event_get_seqnum(event));
    _ = c.gst_mini_object_replace(@ptrCast(&o.seek_event), @ptrCast(sev));
    c.gst_event_unref(sev);
    pushUnlock(o);
    wakeSeekThread(o);
    return true;
}

fn setupSeekPull(o: *Demux, event: [*c]c.GstEvent) bool {
    const seqnum = c.gst_event_get_seqnum(event);
    var flags: c.GstSeekFlags = 0;
    c.gst_event_parse_seek(event, null, null, &flags, null, null, null, null);
    const flush = flags & c.GST_SEEK_FLAG_FLUSH != 0;
    if (flush) {
        const fs = c.gst_event_new_flush_start();
        c.gst_event_set_seqnum(fs, seqnum);
        _ = c.gst_mini_object_ref(@ptrCast(fs));
        _ = c.gst_pad_push_event(o.sinkpad, fs);
        chainLock(o);
        for (o.chains.?.items) |ch| {
            for (ch.streams.items) |p| {
                _ = c.gst_mini_object_ref(@ptrCast(fs));
                _ = c.gst_pad_push_event(gpad(p), fs);
            }
        }
        chainUnlock(o);
        c.gst_event_unref(fs);
    }
    _ = c.gst_pad_pause_task(o.sinkpad);
    cm.streamLock(o.sinkpad);
    if (flush) {
        const fs = c.gst_event_new_flush_stop(1);
        c.gst_event_set_seqnum(fs, seqnum);
        _ = c.gst_pad_push_event(o.sinkpad, @ptrCast(c.gst_mini_object_ref(@ptrCast(fs))));
        _ = sendEvent(o, fs);
    }
    _ = c.gst_mini_object_replace(@ptrCast(&o.seek_event), @ptrCast(event));
    _ = c.gst_pad_start_task(o.sinkpad, loop, o.sinkpad, null);
    cm.streamUnlock(o.sinkpad);
    return true;
}

fn performSeek(o: *Demux, event: [*c]c.GstEvent) bool {
    if (o.pullmode != 0) return setupSeekPull(o, event);
    return performSeekPush(o, event);
}

fn chainHasStream(ch: *Chain, serial: u32) bool {
    return chainGetStream(ch, serial) != null;
}

fn bisectForwardSerialno(o: *Demux, begin: i64, searched0: i64, end: i64, ch: *Chain, m: c_long) c.GstFlowReturn {
    _ = begin;
    var searched = searched0;
    var endsearched = end;
    var next = end;
    while (searched < endsearched) {
        const bisect = if (endsearched - searched < o.chunk_size) searched else @divTrunc(searched + endsearched, 2);
        seek(o, bisect);
        var og: c.ogg_page = undefined;
        var off: i64 = 0;
        const r = nextPage(o, &og, -1, &off);
        if (r == c.GST_FLOW_EOS) {
            endsearched = bisect;
        } else if (r == c.GST_FLOW_OK) {
            if (!chainHasStream(ch, @bitCast(c.ogg_page_serialno(&og)))) {
                endsearched = bisect;
                next = off;
            } else searched = off + og.header_len + og.body_len;
        } else return r;
    }
    ch.end_offset = searched;
    var ret = readEndChain(o, ch);
    if (ret != c.GST_FLOW_OK) return ret;
    seek(o, next);
    var nextchain: ?*Chain = null;
    ret = readChain(o, &nextchain);
    if (ret == c.GST_FLOW_EOS) {
        nextchain = null;
        ret = c.GST_FLOW_OK;
    } else if (ret != c.GST_FLOW_OK) return ret;
    if (searched < end and nextchain != null) {
        ret = bisectForwardSerialno(o, next, o.offset, end, nextchain.?, m + 1);
        if (ret != c.GST_FLOW_OK) return ret;
    }
    o.chains.?.insert(A, 0, ch) catch unreachable;
    return ret;
}

fn readChain(o: *Demux, res: ?*?*Chain) c.GstFlowReturn {
    var chain: ?*Chain = null;
    var offset = o.offset;
    var og: c.ogg_page = undefined;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    while (true) {
        ret = nextPage(o, &og, -1, null);
        if (ret != c.GST_FLOW_OK) break;
        if (c.ogg_page_bos(&og) == 0) {
            if (chain == null) ret = c.GST_FLOW_EOS;
            break;
        }
        if (chain == null) {
            chain = chainNew(o);
            chain.?.offset = offset;
        }
        const serial: u32 = @bitCast(c.ogg_page_serialno(&og));
        if (chainGetStream(chain.?, serial) != null) continue;
        if (chainNewStream(chain.?, serial)) |p| _ = submitPage(p, &og);
    }
    if (ret != c.GST_FLOW_OK or chain == null) {
        if (ret == c.GST_FLOW_OK) ret = c.GST_FLOW_ERROR;
        if (chain) |ch| chainFree(ch);
        if (res) |r| r.* = null;
        return ret;
    }
    const ch = chain.?;
    ch.have_bos = true;
    offset = o.offset;
    var done = false;
    while (!done) {
        const serial: u32 = @bitCast(c.ogg_page_serialno(&og));
        var known = false;
        done = true;
        for (ch.streams.items) |p| {
            if (p.map.serialno == serial) {
                known = true;
                _ = submitPage(p, &og);
                if (p.map.is_skeleton == 0 and p.start_time == NONE and c.ogg_page_eos(&og) != 0) {
                    done = true;
                    break;
                }
            }
            if (p.map.is_sparse == 0) done = done and (p.start_time != NONE);
        }
        if (!known) {
            seek(o, offset);
            break;
        }
        if (!done) {
            if (nextPage(o, &og, -1, null) != c.GST_FLOW_OK) break;
        }
    }
    if (res) |r| r.* = ch;
    return c.GST_FLOW_OK;
}

fn readEndChain(o: *Demux, ch: *Chain) c.GstFlowReturn {
    var begin = ch.end_offset;
    const end = begin;
    var last: i64 = -1;
    var last_pad: ?*Pad = null;
    var done = false;
    while (!done) {
        begin -= o.chunk_size;
        if (begin < 0) begin = 0;
        seek(o, begin);
        while (o.offset < end) {
            var og: c.ogg_page = undefined;
            const r = nextPage(o, &og, end - o.offset, null);
            if (r == FLOW_LIMIT) break;
            if (r != c.GST_FLOW_OK) return r;
            for (ch.streams.items) |p| {
                if (p.map.is_skeleton != 0) continue;
                if (p.map.serialno == @as(u32, @bitCast(c.ogg_page_serialno(&og)))) {
                    const gp = c.ogg_page_granulepos(&og);
                    if (gp != -1) {
                        last = gp;
                        last_pad = p;
                        done = true;
                    }
                    break;
                }
            }
        }
    }
    ch.segment_stop = if (last_pad) |p| os.endTimeForGranulepos(&p.map, last) else NONE;
    return c.GST_FLOW_OK;
}

fn findPad(o: *Demux, serial: u32) ?*Pad {
    if (o.building_chain) |b| {
        if (chainGetStream(b, serial)) |p| return p;
    }
    if (o.current_chain) |cc| {
        if (chainGetStream(cc, serial)) |p| return p;
    }
    for (o.chains.?.items) |ch| {
        if (chainGetStream(ch, serial)) |p| return p;
    }
    return null;
}

fn findChain(o: *Demux, serial: u32) ?*Chain {
    const p = findPad(o, serial) orelse return null;
    return p.chain;
}

fn collectChainInfo(ch: *Chain) bool {
    ch.total_time = NONE;
    ch.segment_start = collectStartTime(ch);
    if (ch.segment_start == std.math.maxInt(u64)) return false;
    if (ch.segment_stop != NONE) ch.total_time = ch.segment_stop -% ch.segment_start;
    return true;
}

fn collectInfo(o: *Demux) void {
    o.total_time = 0;
    for (o.chains.?.items) |ch| {
        ch.begin_time = o.total_time;
        _ = collectChainInfo(ch);
        o.total_time +%= ch.total_time;
    }
    o.segment.duration = o.total_time;
}

fn findChains(o: *Demux) c.GstFlowReturn {
    const peer = c.gst_pad_get_peer(o.sinkpad) orelse {
        cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DEMUX, null, c.g_strdup("we don't have a peer"), FILE, "gst_ogg_demux_find_chains", 4555);
        return c.GST_FLOW_NOT_LINKED;
    };
    const ok = c.gst_pad_query_duration(peer, c.GST_FORMAT_BYTES, &o.length) != 0;
    c.gst_object_unref(peer);
    if (!ok or o.length <= 0) {
        cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DEMUX, null, c.g_strdup("can't get file length"), FILE, "gst_ogg_demux_find_chains", 4560);
        return c.GST_FLOW_NOT_SUPPORTED;
    }
    seek(o, 0);
    var chain: ?*Chain = null;
    var ret = readChain(o, &chain);
    if (ret != c.GST_FLOW_OK) {
        if (ret == c.GST_FLOW_FLUSHING) return c.GST_FLOW_FLUSHING;
        cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DEMUX, null, c.g_strdup("can't get first chain"), FILE, "gst_ogg_demux_find_chains", 4565);
        return c.GST_FLOW_ERROR;
    }
    seek(o, o.length);
    var og: c.ogg_page = undefined;
    ret = prevPage(o, &og, null);
    if (ret != c.GST_FLOW_OK) {
        if (chain) |ch| chainFree(ch);
        return ret;
    }
    const serial: u32 = @bitCast(c.ogg_page_serialno(&og));
    if (!chainHasStream(chain.?, serial)) {
        ret = bisectForwardSerialno(o, 0, 0, o.length, chain.?, 0);
    } else ret = bisectForwardSerialno(o, 0, o.length, o.length, chain.?, 0);
    if (ret != c.GST_FLOW_OK) return ret;
    collectInfo(o);
    return ret;
}

fn updateChunkSize(o: *Demux, page: *c.ogg_page) void {
    const cs = (page.header_len + page.body_len) * 2;
    if (cs > o.chunk_size) o.chunk_size = cs;
}

fn handlePage(o: *Demux, page: *c.ogg_page, discont: bool) c.GstFlowReturn {
    const serial: u32 = @bitCast(c.ogg_page_serialno(page));
    updateChunkSize(o, page);
    var pad: ?*Pad = null;
    if (c.ogg_page_bos(page) != 0) {
        if (findChain(o, serial)) |ch| {
            const start: u64 = if (ch.segment_start != NONE) ch.segment_start else 0;
            var seg: c.GstSegment = undefined;
            c.gst_segment_copy_into(&o.segment, &seg);
            seg.start = start;
            seg.stop = ch.segment_stop;
            seg.time = ch.begin_time;
            seg.base +%= ch.begin_time;
            const ev = c.gst_event_new_segment(&seg);
            c.gst_event_set_seqnum(ev, o.seqnum);
            _ = activateChain(o, ch, ev);
            pad = findPad(o, serial);
        } else {
            if (o.pullmode != 0) {
                cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("unknown ogg chain for serial %08x detected", serial), FILE, "gst_ogg_demux_handle_page", 4715);
                return c.GST_FLOW_ERROR;
            }
            if (o.building_chain == null) {
                const nc = chainNew(o);
                nc.offset = 0;
                nc.begin_time = o.segment.position;
                o.building_chain = nc;
            }
            pad = chainNewStream(o.building_chain.?, serial);
        }
    } else pad = findPad(o, serial);
    if (pad) |p| {
        if (discont) p.current_granule = -1;
        return submitPage(p, page);
    }
    pushLock(o);
    if (o.pullmode == 0 and o.push_disable_seeking == 0) {
        if (o.push_state == PUSH_DURATION) {
            const r = seekBackUnlock(o);
            pushLock(o);
            if (r != c.GST_FLOW_OK) return r;
        }
        o.push_disable_seeking = 1;
    } else {
        pushUnlock(o);
        cm.elementWarning(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("unknown ogg pad for serial %08x detected", serial), FILE, "gst_ogg_demux_handle_page", 4704);
        return c.GST_FLOW_OK;
    }
    pushUnlock(o);
    return c.GST_FLOW_OK;
}

fn chainFunc(_: ?*c.GstPad, parent: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return chainBuffer(me(parent), b);
}

fn chainBuffer(o: *Demux, b: [*c]c.GstBuffer) c.GstFlowReturn {
    pushLock(o);
    const drop = o.seek_event_drop_till > 0;
    pushUnlock(o);
    if (drop) {
        c.gst_buffer_unref(b);
        return c.GST_FLOW_OK;
    }
    var result = submitBuffer(o, b);
    var r: c_int = 0;
    while (result == c.GST_FLOW_OK) {
        var page: c.ogg_page = undefined;
        r = c.ogg_sync_pageout(&o.sync, &page);
        if (r == 0) break;
        if (r != -1) result = handlePage(o, &page, false);
    }
    if (r == 0 or result == c.GST_FLOW_OK) syncStreams(o);
    return result;
}

fn sendEvent(o: *Demux, ev: [*c]c.GstEvent) bool {
    var chain = o.current_chain;
    if (chain == null) chain = o.building_chain;
    var sent = false;
    var res = true;
    if (chain) |ch| {
        for (ch.streams.items) |p| {
            _ = c.gst_mini_object_ref(@ptrCast(ev));
            res = (c.gst_pad_push_event(gpad(p), ev) != 0) and res;
            if (p.added != 0) sent = true;
        }
    }
    const t = cm.eventType(ev);
    c.gst_event_unref(ev);
    if (!sent and t == c.GST_EVENT_EOS) cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DEMUX, null, c.g_strdup("EOS before finding a chain"), FILE, "gst_ogg_demux_send_event", 4799);
    return res;
}

fn combineFlows(o: *Demux, p: *Pad, ret: c.GstFlowReturn) c.GstFlowReturn {
    p.last_ret = ret;
    p.is_eos = @intFromBool(ret == c.GST_FLOW_EOS);
    return c.gst_flow_combiner_update_pad_flow(o.flowcombiner, gpad(p), ret);
}

fn loopForward(o: *Demux) c.GstFlowReturn {
    if (o.offset == o.length) return c.GST_FLOW_EOS;
    var b: [*c]c.GstBuffer = null;
    const r = c.gst_pad_pull_range(o.sinkpad, @bitCast(o.offset), @intCast(o.chunk_size), &b);
    if (r != c.GST_FLOW_OK) return r;
    o.offset += @intCast(c.gst_buffer_get_size(b));
    if (o.newsegment != null) {
        _ = sendEvent(o, o.newsegment);
        o.newsegment = null;
    }
    return chainBuffer(o, b);
}

fn loopReverse(o: *Demux) c.GstFlowReturn {
    if (o.offset == 0) return c.GST_FLOW_EOS;
    var page: c.ogg_page = undefined;
    var off: i64 = 0;
    const r = prevPage(o, &page, &off);
    if (r != c.GST_FLOW_OK) return r;
    o.offset = off;
    if (o.newsegment != null) {
        _ = sendEvent(o, o.newsegment);
        o.newsegment = null;
    }
    return handlePage(o, &page, true);
}

fn syncStreams(o: *Demux) void {
    const ch = o.current_chain orelse return;
    const cur = o.segment.position;
    if (cur == NONE) return;
    for (ch.streams.items) |s| {
        if (s.position != NONE and diff(s.position, cur) > 2 * @as(i64, SECOND)) {
            s.position = cur;
            _ = c.gst_pad_push_event(gpad(s), c.gst_event_new_gap(s.position, cur -% s.position));
        }
    }
}

fn loop(data: c.gpointer) callconv(.c) void {
    const pad: *c.GstPad = @ptrCast(@alignCast(data));
    const o = me(cm.obj(pad).parent);
    const sk = o.seek_event;
    o.seek_event = null;
    var ret: c.GstFlowReturn = c.GST_FLOW_ERROR;
    run: {
        if (o.need_chains != 0) {
            chainLock(o);
            ret = findChains(o);
            chainUnlock(o);
            if (ret != c.GST_FLOW_OK) break :run;
            o.need_chains = 0;
            cm.lock(o);
            o.running = 1;
            cm.unlock(o);
            if (!performSeekPull(o, sk)) {
                ret = seekFailed(o, pad, ret);
                break :run;
            }
        } else if (sk != null) {
            if (!performSeekPull(o, sk)) {
                ret = seekFailed(o, pad, ret);
                break :run;
            }
        }
        ret = if (o.segment.rate >= 0.0) loopForward(o) else loopReverse(o);
        if (ret == c.GST_FLOW_OK) {
            syncStreams(o);
            return;
        }
    }
    pauseLoop(o, ret);
}

fn seekFailed(o: *Demux, pad: *c.GstPad, ret: c.GstFlowReturn) c.GstFlowReturn {
    cm.lock(pad);
    const flushing = cm.obj(pad).flags & c.GST_PAD_FLAG_FLUSHING != 0;
    cm.unlock(pad);
    if (flushing) return c.GST_FLOW_FLUSHING;
    cm.flowError(o, ret, FILE, "gst_ogg_demux_loop", 5003);
    return c.GST_FLOW_ERROR;
}

fn pauseLoop(o: *Demux, ret: c.GstFlowReturn) void {
    _ = c.gst_pad_pause_task(o.sinkpad);
    var ev: [*c]c.GstEvent = null;
    if (ret == c.GST_FLOW_EOS) {
        if (o.segment.flags & c.GST_SEEK_FLAG_SEGMENT != 0) {
            var stop = o.segment.stop;
            if (stop == NONE) stop = o.segment.duration;
            const m = c.gst_message_new_segment_done(@ptrCast(o), c.GST_FORMAT_TIME, @bitCast(stop));
            c.gst_message_set_seqnum(m, o.seqnum);
            _ = c.gst_element_post_message(&o.element, m);
            const sd = c.gst_event_new_segment_done(c.GST_FORMAT_TIME, @bitCast(stop));
            c.gst_event_set_seqnum(sd, o.seqnum);
            _ = sendEvent(o, sd);
        } else ev = c.gst_event_new_eos();
    } else if (ret == c.GST_FLOW_NOT_LINKED or ret < c.GST_FLOW_EOS) {
        cm.flowError(o, ret, FILE, "gst_ogg_demux_loop", 5045);
        ev = c.gst_event_new_eos();
    }
    if (ev != null) {
        if (o.current_chain != null or o.building_chain != null) {
            c.gst_event_set_seqnum(ev, o.seqnum);
            _ = sendEvent(o, ev);
        } else {
            c.gst_event_unref(ev);
            cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DEMUX, null, c.g_strdup("EOS before finding a chain"), FILE, "gst_ogg_demux_loop", 5063);
        }
    }
}

fn loopPush(data: c.gpointer) callconv(.c) c.gpointer {
    const o = me(data);
    c.g_mutex_lock(&o.seek_event_mutex);
    o.seek_thread_started = 1;
    c.g_cond_broadcast(&o.thread_started_cond);
    while (o.seek_event_thread_stop == 0) {
        var ev: [*c]c.GstEvent = null;
        while (o.seek_event_thread_stop == 0) {
            pushLock(o);
            ev = o.seek_event;
            o.seek_event = null;
            if (ev != null) o.seek_event_drop_till = c.gst_event_get_seqnum(ev);
            pushUnlock(o);
            if (ev != null) break;
            c.g_cond_wait(&o.seek_event_cond, &o.seek_event_mutex);
        }
        if (o.seek_event_thread_stop != 0) break;
        c.g_mutex_unlock(&o.seek_event_mutex);
        if (c.gst_pad_push_event(o.sinkpad, ev) == 0) {
            pushLock(o);
            if (o.pullmode == 0) {
                o.push_state = PUSH_PLAYING;
                o.push_disable_seeking = 1;
            }
            pushUnlock(o);
        }
        c.g_mutex_lock(&o.seek_event_mutex);
    }
    c.g_mutex_unlock(&o.seek_event_mutex);
    c.gst_object_unref(o);
    return null;
}

fn clearChains(o: *Demux) void {
    _ = deactivateCurrentChain(o);
    chainLock(o);
    for (o.chains.?.items) |ch| {
        if (o.current_chain == ch) o.current_chain = null;
        if (o.building_chain == ch) o.building_chain = null;
        chainFree(ch);
    }
    o.chains.?.clearRetainingCapacity();
    if (o.current_chain) |cc| {
        chainFree(cc);
        o.current_chain = null;
    }
    if (o.building_chain) |b| {
        chainFree(b);
        o.building_chain = null;
    }
    chainUnlock(o);
}

fn sinkActivate(pad: ?*c.GstPad, _: [*c]c.GstObject) callconv(.c) c.gboolean {
    const q = c.gst_query_new_scheduling();
    if (c.gst_pad_peer_query(pad, q) == 0) {
        c.gst_query_unref(q);
        return c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PUSH, 1);
    }
    const pull = c.gst_query_has_scheduling_mode_with_flags(q, c.GST_PAD_MODE_PULL, c.GST_SCHEDULING_FLAG_SEEKABLE) != 0;
    c.gst_query_unref(q);
    if (!pull) return c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PUSH, 1);
    return c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PULL, 1);
}

fn sinkActivateMode(pad: ?*c.GstPad, parent: [*c]c.GstObject, mode: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    const o = me(parent);
    switch (mode) {
        c.GST_PAD_MODE_PUSH => {
            o.pullmode = 0;
            o.resync = 0;
            if (active != 0) {
                o.seek_event_thread_stop = 0;
                o.seek_thread_started = 0;
                o.seek_event_thread = c.g_thread_new("seek_event_thread", loopPush, c.gst_object_ref(o));
                c.g_mutex_lock(&o.seek_event_mutex);
                while (o.seek_thread_started == 0) c.g_cond_wait(&o.thread_started_cond, &o.seek_event_mutex);
                c.g_mutex_unlock(&o.seek_event_mutex);
            } else {
                c.g_mutex_lock(&o.seek_event_mutex);
                o.seek_event_thread_stop = 1;
                c.g_cond_broadcast(&o.seek_event_cond);
                c.g_mutex_unlock(&o.seek_event_mutex);
                _ = c.g_thread_join(o.seek_event_thread);
                o.seek_event_thread = null;
            }
            return 1;
        },
        c.GST_PAD_MODE_PULL => {
            if (active != 0) {
                o.need_chains = 1;
                o.pullmode = 1;
                return c.gst_pad_start_task(pad, loop, pad, null);
            }
            return c.gst_pad_stop_task(pad);
        },
        else => return 0,
    }
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const o = me(el);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            o.basetime = 0;
            _ = c.ogg_sync_init(&o.sync);
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            _ = c.ogg_sync_reset(&o.sync);
            o.running = 0;
            o.bitrate = 0;
            o.total_time = NONE;
            pushLock(o);
            o.push_byte_offset = 0;
            o.push_byte_length = -1;
            o.push_time_length = NONE;
            o.push_time_offset = NONE;
            o.push_state = PUSH_PLAYING;
            o.have_group_id = 0;
            o.group_id = std.math.maxInt(c.guint);
            o.seqnum = SEQNUM_INVALID;
            o.push_disable_seeking = 0;
            queryDurationPush(o);
            pushUnlock(o);
            c.gst_segment_init(&o.segment, c.GST_FORMAT_TIME);
        },
        else => {},
    }
    const r = parent_class.?.change_state.?(el, t);
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            clearChains(o);
            cm.lock(o);
            o.running = 0;
            _ = c.gst_mini_object_replace(@ptrCast(&o.seek_event), null);
            cm.unlock(o);
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => _ = c.ogg_sync_clear(&o.sync),
        else => {},
    }
    return r;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Ogg demuxer", "Codec/Demuxer", "demux ogg streams (info about ogg: http://xiph.org)", "Wim Taymans <wim@fluendo.com>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.change_state = changeState;
    ec.send_event = receiveEvent;
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = finalize;
    debugInit();
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const o = me(inst);
    o.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_event_function_full(o.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_chain_function_full(o.sinkpad, chainFunc, null, null);
    c.gst_pad_set_activate_function_full(o.sinkpad, sinkActivate, null, null);
    c.gst_pad_set_activatemode_function_full(o.sinkpad, sinkActivateMode, null, null);
    _ = c.gst_element_add_pad(&o.element, o.sinkpad);
    c.g_mutex_init(&o.chain_lock);
    c.g_mutex_init(&o.push_lock);
    c.g_mutex_init(&o.seek_event_mutex);
    c.g_cond_init(&o.seek_event_cond);
    c.g_cond_init(&o.thread_started_cond);
    const chains = A.create(std.ArrayListUnmanaged(*Chain)) catch unreachable;
    chains.* = .empty;
    o.chains = chains;
    o.stats_nbisections = 0;
    o.stats_bisection_steps = .{ 0, 0 };
    o.stats_bisection_max_steps = .{ 0, 0 };
    o.newsegment = null;
    o.seqnum = SEQNUM_INVALID;
    o.chunk_size = CHUNKSIZE;
    o.flowcombiner = c.gst_flow_combiner_new();
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstOggDemux", Class, Demux, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "oggdemux", c.GST_RANK_PRIMARY, getType()) != 0;
}
