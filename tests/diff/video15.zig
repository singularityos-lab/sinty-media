const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);
const CT_NONE: u64 = std.math.maxInt(u64);

fn ts(t: u64) i64 {
    return @bitCast(t);
}

fn showS(prefix: []const u8, s: ?*const c.GstStructure) void {
    if (s == null) {
        out("{s} -", .{prefix});
        return;
    }
    const str = c.gst_structure_to_string(s);
    out("{s} {s}", .{ prefix, str });
    c.g_free(str);
}

var mode: u32 = 0;

fn setFormat(d: [*c]c.GstVideoDecoder, st: [*c]c.GstVideoCodecState) callconv(.c) c.gboolean {
    const s = c.gst_caps_to_string(st[0].caps);
    out("    set_format {s} codec_data {d}", .{ s, @intFromBool(st[0].codec_data != null) });
    c.g_free(s);
    if (mode == 5) return 0;
    const os = c.gst_video_decoder_set_output_state(d, c.GST_VIDEO_FORMAT_GRAY8, @bitCast(st[0].info.width), @bitCast(st[0].info.height), st);
    c.gst_video_codec_state_unref(os);
    return 1;
}

fn handleFrame(d: [*c]c.GstVideoDecoder, f: [*c]c.GstVideoCodecFrame) callconv(.c) c.GstFlowReturn {
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(f[0].input_buffer, &mi, c.GST_MAP_READ);
    const first: u8 = if (mi.size > 0) mi.data[0] else 0;
    const size = mi.size;
    c.gst_buffer_unmap(f[0].input_buffer, &mi);
    out("    handle #{d} pts {d} dts {d} dur {d} flags {d} dist {d} size {d} b {d} sub {d}", .{ f[0].system_frame_number, ts(f[0].pts), ts(f[0].dts), ts(f[0].duration), f[0].flags, f[0].distance_from_sync, size, first, c.gst_video_decoder_get_input_subframe_index(d, f) });
    if (c.gst_video_decoder_get_subframe_mode(d) != 0 and f[0].input_buffer[0].mini_object.flags & c.GST_BUFFER_FLAG_MARKER == 0) {
        out("    subframe processed {d}", .{c.gst_video_decoder_get_processed_subframe_index(d, f)});
        return c.gst_video_decoder_finish_subframe(d, f);
    }
    if (first == 0xff) return c.gst_video_decoder_drop_frame(d, f);
    if (first == 0xfe) {
        const r = c._gst_video_decoder_error(d, 1, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, c.g_strdup("bad frame"), c.g_strdup("frame marked bad"), "test.c", "handle_frame", 42);
        c.gst_video_decoder_release_frame(d, f);
        return r;
    }
    if (first == 0xfd) {
        const old = c.gst_video_decoder_get_oldest_frame(d);
        out("    hold, oldest #{d} pending {d}", .{ old[0].system_frame_number, c.g_list_length(c.gst_video_decoder_get_frames(d)) });
        c.gst_video_codec_frame_unref(old);
        c.gst_video_codec_frame_unref(f);
        return c.GST_FLOW_OK;
    }
    if (first == 0xfc) {
        f[0].flags |= c.GST_VIDEO_CODEC_FRAME_FLAG_CORRUPTED;
    }
    const r = c.gst_video_decoder_allocate_output_frame(d, f);
    if (r != c.GST_FLOW_OK) {
        out("    alloc {d}", .{r});
        c.gst_video_decoder_release_frame(d, f);
        return r;
    }
    _ = c.gst_buffer_memset(f[0].output_buffer, 0, first, c.gst_buffer_get_size(f[0].output_buffer));
    if (first == 0xfb) f[0].pts = CT_NONE;
    return c.gst_video_decoder_finish_frame(d, f);
}

fn parse(d: [*c]c.GstVideoDecoder, _: [*c]c.GstVideoCodecFrame, a: ?*c.GstAdapter, at_eos: c.gboolean) callconv(.c) c.GstFlowReturn {
    const avail = c.gst_adapter_available(a);
    out("    parse avail {d} eos {d} pending {d}", .{ avail, at_eos, c.gst_video_decoder_get_pending_frame_size(d) });
    if (avail >= 3) {
        c.gst_video_decoder_add_to_frame(d, 3);
        return c.gst_video_decoder_have_frame(d);
    }
    if (at_eos != 0 and avail > 0) {
        c.gst_video_decoder_add_to_frame(d, @intCast(avail));
        return c.gst_video_decoder_have_frame(d);
    }
    return c.GST_VIDEO_DECODER_FLOW_NEED_DATA;
}

fn vstart(_: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    out("    start", .{});
    return 1;
}

fn vstop(_: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    out("    stop", .{});
    return @intFromBool(mode != 7);
}

fn vflush(_: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    out("    flush", .{});
    return 1;
}

fn vdrain(_: [*c]c.GstVideoDecoder) callconv(.c) c.GstFlowReturn {
    out("    drain", .{});
    return c.GST_FLOW_OK;
}

fn vfinish(_: [*c]c.GstVideoDecoder) callconv(.c) c.GstFlowReturn {
    out("    finish", .{});
    return c.GST_FLOW_OK;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: [*c]c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, c.gst_caps_from_string("video/x-test")));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, c.gst_caps_from_string("video/x-raw, format=(string){ GRAY8, I420 }, width=(int)[1,100], height=(int)[1,100]")));
    c.gst_element_class_set_static_metadata(ec, "t", "Codec/Decoder/Video", "t", "t");
    const vc: *c.GstVideoDecoderClass = @ptrCast(@alignCast(k));
    vc.set_format = setFormat;
    vc.handle_frame = handleFrame;
    vc.parse = parse;
    vc.start = vstart;
    vc.stop = vstop;
    vc.flush = vflush;
    vc.drain = vdrain;
    vc.finish = vfinish;
}

fn peerChain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &mi, c.GST_MAP_READ);
    const first: u8 = if (mi.size > 0) mi.data[0] else 0;
    c.gst_buffer_unmap(b, &mi);
    const vm = c.gst_buffer_get_video_meta(b);
    out("  OUT pts {d} dts {d} dur {d} flags {d} size {d} b {d} meta {d}", .{ ts(b[0].pts), ts(b[0].dts), ts(b[0].duration), b[0].mini_object.flags, c.gst_buffer_get_size(b), first, @intFromBool(vm != null) });
    c.gst_buffer_unref(b);
    return c.GST_FLOW_OK;
}

fn peerEvent(_: ?*c.GstPad, _: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (e[0].type == c.GST_EVENT_CAPS) {
        var caps: [*c]c.GstCaps = null;
        c.gst_event_parse_caps(e, &caps);
        const s = c.gst_caps_to_string(caps);
        out("  EV caps {s}", .{s});
        c.g_free(s);
    } else if (e[0].type == c.GST_EVENT_SEGMENT) {
        var seg: [*c]const c.GstSegment = null;
        c.gst_event_parse_segment(e, &seg);
        out("  EV segment fmt {d} rate {d} start {d} stop {d}", .{ seg[0].format, seg[0].rate, ts(seg[0].start), ts(seg[0].stop) });
    } else {
        out("  EV {s}", .{c.gst_event_type_get_name(e[0].type)});
        if (e[0].type == c.GST_EVENT_TAG) showS("    tag", c.gst_event_get_structure(e));
    }
    c.gst_event_unref(e);
    return 1;
}

fn peerQuery(_: ?*c.GstPad, _: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_ALLOCATION) {
        out("  Q allocation", .{});
        return 0;
    }
    if (q[0].type == c.GST_QUERY_CAPS) {
        var filter: [*c]c.GstCaps = null;
        c.gst_query_parse_caps(q, &filter);
        const caps = c.gst_caps_from_string("video/x-raw, format=(string){ GRAY8, I420 }, width=(int)[1,100], height=(int)[1,100], framerate=(fraction)[0/1, 100/1]");
        const r = if (filter != null) c.gst_caps_intersect(caps, filter) else c.gst_caps_ref(caps);
        c.gst_query_set_caps_result(q, r);
        c.gst_caps_unref(r);
        c.gst_caps_unref(caps);
        return 1;
    }
    if (q[0].type == c.GST_QUERY_ACCEPT_CAPS) {
        c.gst_query_set_accept_caps_result(q, 1);
        return 1;
    }
    return 0;
}

var sink_peer: ?*c.GstPad = null;

fn upQuery(_: ?*c.GstPad, _: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_LATENCY) {
        c.gst_query_set_latency(q, 1, 10, 100);
        return 1;
    }
    return 0;
}

fn upEvent(_: ?*c.GstPad, _: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    out("  UP {s}", .{c.gst_event_type_get_name(e[0].type)});
    if (e[0].type == c.GST_EVENT_CUSTOM_UPSTREAM) showS("    up", c.gst_event_get_structure(e));
    c.gst_event_unref(e);
    return 1;
}

fn drain(bus: ?*c.GstBus) void {
    while (c.gst_bus_pop(bus)) |m| {
        switch (m[0].type) {
            c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
                var err: [*c]c.GError = null;
                var dbg: [*c]u8 = null;
                if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &err, &dbg) else c.gst_message_parse_warning(m, &err, &dbg);
                out("  MSG {s} {s} | {s}", .{ c.gst_message_type_get_name(m[0].type), err[0].message, dbg });
                c.g_error_free(err);
                c.g_free(dbg);
            },
            c.GST_MESSAGE_QOS => {
                var live: c.gboolean = 0;
                var rt: u64 = 0;
                var st: u64 = 0;
                var t: u64 = 0;
                var dur: u64 = 0;
                c.gst_message_parse_qos(m, &live, &rt, &st, &t, &dur);
                var jitter: i64 = 0;
                var prop: f64 = 0;
                var quality: c.gint = 0;
                c.gst_message_parse_qos_values(m, &jitter, &prop, &quality);
                var fmt: c.GstFormat = 0;
                var proc: u64 = 0;
                var drop: u64 = 0;
                c.gst_message_parse_qos_stats(m, &fmt, &proc, &drop);
                out("  MSG qos rt {d} st {d} t {d} jitter {d} prop {d} q {d} stats {d} {d}", .{ ts(rt), ts(st), ts(t), jitter, prop, quality, proc, drop });
            },
            else => out("  MSG {s}", .{c.gst_message_type_get_name(m[0].type)}),
        }
        c.gst_message_unref(m);
    }
}

fn mkbuf(b0: u8, n: usize, pts: u64, dts: u64, dur: u64, flags: c.guint) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, n, null);
    _ = c.gst_buffer_memset(b, 0, b0, n);
    b[0].pts = pts;
    b[0].dts = dts;
    b[0].duration = dur;
    b[0].mini_object.flags = flags;
    return b;
}

const Env = struct { el: [*c]c.GstElement, dec: [*c]c.GstVideoDecoder, sink: ?*c.GstPad, src: ?*c.GstPad, peer: ?*c.GstPad, up: ?*c.GstPad, bus: ?*c.GstBus };

fn setup(t: c.GType, name: [*:0]const u8) Env {
    const e: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(t, "name", name, NONE)));
    const d: [*c]c.GstVideoDecoder = @ptrCast(e);
    const peer = c.gst_pad_new("peer", c.GST_PAD_SINK);
    c.gst_pad_set_chain_function_full(peer, peerChain, null, null);
    c.gst_pad_set_event_function_full(peer, peerEvent, null, null);
    c.gst_pad_set_query_function_full(peer, peerQuery, null, null);
    const up = c.gst_pad_new("up", c.GST_PAD_SRC);
    c.gst_pad_set_query_function_full(up, upQuery, null, null);
    c.gst_pad_set_event_function_full(up, upEvent, null, null);
    _ = c.gst_pad_link(d[0].srcpad, peer);
    _ = c.gst_pad_link(up, d[0].sinkpad);
    _ = c.gst_pad_set_active(peer, 1);
    _ = c.gst_pad_set_active(up, 1);
    const bus = c.gst_bus_new();
    c.gst_element_set_bus(e, bus);
    out("  state {d}", .{c.gst_element_set_state(e, c.GST_STATE_PAUSED)});
    return .{ .el = e, .dec = d, .sink = d[0].sinkpad, .src = d[0].srcpad, .peer = peer, .up = up, .bus = bus };
}

fn teardown(env: Env) void {
    out("  state {d}", .{c.gst_element_set_state(env.el, c.GST_STATE_NULL)});
    drain(env.bus);
    c.gst_element_set_bus(env.el, null);
    c.gst_object_unref(env.bus);
    c.gst_object_unref(env.peer);
    c.gst_object_unref(env.up);
    c.gst_object_unref(env.el);
}

fn start(env: Env, caps: [*:0]const u8, rate: f64) void {
    out("  start-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_stream_start("s"))});
    out("  caps-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_caps(c.gst_caps_from_string(caps)))});
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.rate = rate;
    out("  seg-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_segment(&seg))});
}

fn push(env: Env, b: [*c]c.GstBuffer) void {
    out("  push {d}", .{c.gst_pad_chain(env.sink, b)});
    drain(env.bus);
}

const MS: u64 = 1_000_000;
const DELTA: c.guint = c.GST_BUFFER_FLAG_DELTA_UNIT;

pub fn main() void {
    c.gst_init(null, null);
    const t = c.g_type_register_static_simple(c.gst_video_decoder_get_type(), "TDec", @sizeOf(c.GstVideoDecoderClass), classInit, @sizeOf(c.GstVideoDecoder), null, 0);
    {
        out("forward", .{});
        mode = 0;
        const env = setup(t, "d0");
        var v: c.gint = 0;
        c.g_object_get(env.el, "max-errors", &v, NONE);
        out("  max-errors {d} qos {d} packetized {d} subframe {d} estimate {d} needs-format {d} sync {d}", .{ v, c.gst_video_decoder_get_qos_proportion(env.dec), c.gst_video_decoder_get_packetized(env.dec), c.gst_video_decoder_get_subframe_mode(env.dec), c.gst_video_decoder_get_estimate_rate(env.dec), c.gst_video_decoder_get_needs_format(env.dec), c.gst_video_decoder_get_needs_sync_point(env.dec) });
        start(env, "video/x-test, width=4, height=2, framerate=25/1", 1.0);
        push(env, mkbuf(1, 3, 0, 0, CT_NONE, 0));
        push(env, mkbuf(2, 3, 40 * MS, CT_NONE, 40 * MS, DELTA));
        push(env, mkbuf(3, 3, CT_NONE, 80 * MS, CT_NONE, DELTA));
        push(env, mkbuf(0xff, 3, 120 * MS, 120 * MS, CT_NONE, DELTA));
        push(env, mkbuf(0xfe, 3, 160 * MS, 160 * MS, CT_NONE, DELTA));
        c.gst_video_decoder_set_max_errors(env.dec, 0);
        push(env, mkbuf(0xfe, 3, 200 * MS, 200 * MS, CT_NONE, DELTA));
        push(env, mkbuf(0xfc, 3, 240 * MS, 240 * MS, CT_NONE, DELTA));
        c.g_object_set(env.el, "discard-corrupted-frames", @as(c.gboolean, 1), NONE);
        push(env, mkbuf(0xfc, 3, 280 * MS, 280 * MS, CT_NONE, DELTA));
        push(env, mkbuf(0xfd, 3, 320 * MS, 320 * MS, CT_NONE, DELTA));
        push(env, mkbuf(0xfb, 3, 30 * MS, 360 * MS, CT_NONE, 0));
        push(env, mkbuf(7, 3, 20 * MS, 400 * MS, CT_NONE, DELTA));
        const tags = c.gst_tag_list_new("title", "t1", NONE);
        c.gst_video_decoder_merge_tags(env.dec, tags, c.GST_TAG_MERGE_REPLACE);
        c.gst_tag_list_unref(tags);
        _ = c.gst_pad_send_event(env.sink, c.gst_event_new_tag(c.gst_tag_list_new("artist", "a1", NONE)));
        push(env, mkbuf(8, 3, 440 * MS, 440 * MS, CT_NONE, DELTA));
        c.gst_video_decoder_set_latency(env.dec, 5 * MS, 20 * MS);
        c.gst_video_decoder_set_latency(env.dec, 5 * MS, 20 * MS);
        var mn: u64 = 0;
        var mx: u64 = 0;
        c.gst_video_decoder_get_latency(env.dec, &mn, &mx);
        out("  latency {d} {d}", .{ mn, mx });
        const lq = c.gst_query_new_latency();
        out("  latency query {d}", .{c.gst_pad_query(env.src, lq)});
        var live: c.gboolean = 0;
        c.gst_query_parse_latency(lq, &live, &mn, &mx);
        out("    {d} {d} {d}", .{ live, mn, mx });
        c.gst_query_unref(lq);
        for ([_][3]c.GstFormat{ .{ c.GST_FORMAT_DEFAULT, c.GST_FORMAT_TIME, 0 }, .{ c.GST_FORMAT_TIME, c.GST_FORMAT_BYTES, 0 }, .{ c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT, 0 }, .{ c.GST_FORMAT_PERCENT, c.GST_FORMAT_TIME, 0 } }) |f| {
            const q = c.gst_query_new_convert(f[0], 3, f[1]);
            const r = c.gst_pad_query(env.src, q);
            var dv: i64 = 0;
            c.gst_query_parse_convert(q, null, null, null, &dv);
            out("  convert src {d}->{d}: {d} {d}", .{ f[0], f[1], r, dv });
            c.gst_query_unref(q);
            const q2 = c.gst_query_new_convert(f[0], 3 * @as(i64, @intCast(MS)), f[1]);
            const r2 = c.gst_pad_query(env.sink, q2);
            c.gst_query_parse_convert(q2, null, null, null, &dv);
            out("  convert sink {d}->{d}: {d} {d}", .{ f[0], f[1], r2, dv });
            c.gst_query_unref(q2);
        }
        const pq = c.gst_query_new_position(c.GST_FORMAT_TIME);
        var pos: i64 = 0;
        out("  position {d}", .{c.gst_pad_query(env.src, pq)});
        c.gst_query_parse_position(pq, null, &pos);
        out("    {d}", .{pos});
        c.gst_query_unref(pq);
        const cq = c.gst_query_new_caps(null);
        out("  caps query {d}", .{c.gst_pad_query(env.sink, cq)});
        var cr: [*c]c.GstCaps = null;
        c.gst_query_parse_caps_result(cq, &cr);
        const crs = c.gst_caps_to_string(cr);
        out("    {s}", .{crs});
        c.g_free(crs);
        c.gst_query_unref(cq);
        const aq = c.gst_query_new_accept_caps(c.gst_caps_from_string("video/x-test, width=3"));
        out("  accept {d}", .{c.gst_pad_query(env.sink, aq)});
        var acc: c.gboolean = 0;
        c.gst_query_parse_accept_caps_result(aq, &acc);
        out("    {d}", .{acc});
        c.gst_query_unref(aq);
        out("  qos-ev {d}", .{c.gst_pad_send_event(env.src, c.gst_event_new_qos(c.GST_QOS_TYPE_UNDERFLOW, 0.75, @intCast(100 * MS), 400 * MS))});
        out("  qos prop {d}", .{c.gst_video_decoder_get_qos_proportion(env.dec)});
        push(env, mkbuf(9, 3, 480 * MS, 480 * MS, CT_NONE, DELTA));
        push(env, mkbuf(10, 3, 900 * MS, 900 * MS, CT_NONE, DELTA));
        const fr = c.gst_video_decoder_get_frame(env.dec, 8);
        out("  get_frame 8 {d}", .{@intFromBool(fr != null)});
        if (fr != null) {
            out("  max decode time {d}", .{c.gst_video_decoder_get_max_decode_time(env.dec, fr)});
            c.gst_video_codec_frame_unref(fr);
        }
        const ostate = c.gst_video_decoder_get_output_state(env.dec);
        const ocs = c.gst_caps_to_string(ostate[0].caps);
        out("  output state {s}", .{ocs});
        c.g_free(ocs);
        c.gst_video_codec_state_unref(ostate);
        const bp = c.gst_video_decoder_get_buffer_pool(env.dec);
        out("  pool {d}", .{@intFromBool(bp != null)});
        if (bp != null) c.gst_object_unref(bp);
        var alloc: [*c]c.GstAllocator = null;
        var params: c.GstAllocationParams = undefined;
        c.gst_video_decoder_get_allocator(env.dec, &alloc, &params);
        out("  allocator {d} align {d}", .{ @intFromBool(alloc != null), params.@"align" });
        if (alloc != null) c.gst_object_unref(alloc);
        out("  eos-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_eos())});
        drain(env.bus);
        teardown(env);
    }
    {
        out("reverse", .{});
        mode = 0;
        const env = setup(t, "d1");
        start(env, "video/x-test, width=2, height=2, framerate=10/1", -1.0);
        push(env, mkbuf(1, 3, 0, CT_NONE, CT_NONE, c.GST_BUFFER_FLAG_DISCONT));
        push(env, mkbuf(2, 3, 100 * MS, CT_NONE, CT_NONE, DELTA));
        push(env, mkbuf(3, 3, 200 * MS, CT_NONE, CT_NONE, DELTA));
        push(env, mkbuf(4, 3, 300 * MS, CT_NONE, CT_NONE, c.GST_BUFFER_FLAG_DISCONT));
        push(env, mkbuf(5, 3, 400 * MS, CT_NONE, CT_NONE, DELTA));
        out("  eos-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_eos())});
        drain(env.bus);
        teardown(env);
    }
    {
        out("parse", .{});
        mode = 0;
        const env = setup(t, "d2");
        c.gst_video_decoder_set_packetized(env.dec, 0);
        start(env, "video/x-test, width=3, height=1", 1.0);
        push(env, mkbuf(1, 2, 0, CT_NONE, CT_NONE, 0));
        push(env, mkbuf(2, 5, 50 * MS, CT_NONE, 10 * MS, DELTA));
        push(env, mkbuf(3, 4, 90 * MS, CT_NONE, CT_NONE, c.GST_BUFFER_FLAG_CORRUPTED));
        out("  eos-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_eos())});
        drain(env.bus);
        teardown(env);
    }
    {
        out("gap and sync", .{});
        mode = 0;
        const env = setup(t, "d3");
        out("  start-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_stream_start("s"))});
        var seg: c.GstSegment = undefined;
        c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
        out("  seg-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_segment(&seg))});
        out("  gap-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_gap(0, 40 * MS))});
        drain(env.bus);
        c.gst_video_decoder_set_needs_sync_point(env.dec, 1);
        c.g_object_set(env.el, "automatic-request-sync-points", @as(c.gboolean, 1), "min-force-key-unit-interval", @as(u64, 0), NONE);
        out("  caps-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_caps(c.gst_caps_from_string("video/x-test, width=2, height=2")))});
        push(env, mkbuf(5, 3, 10 * MS, 10 * MS, CT_NONE, DELTA));
        push(env, mkbuf(6, 3, 20 * MS, 20 * MS, CT_NONE, 0));
        push(env, mkbuf(7, 3, 30 * MS, 30 * MS, CT_NONE, DELTA));
        const gap = c.gst_event_new_gap(50 * MS, 10 * MS);
        c.gst_event_set_gap_flags(gap, c.GST_GAP_FLAG_MISSING_DATA);
        out("  gap-missing {d}", .{c.gst_pad_send_event(env.sink, gap)});
        push(env, mkbuf(8, 3, 60 * MS, 60 * MS, CT_NONE, DELTA));
        push(env, mkbuf(9, 3, 70 * MS, 70 * MS, CT_NONE, 0));
        out("  flush {d} {d}", .{ c.gst_pad_send_event(env.sink, c.gst_event_new_flush_start()), c.gst_pad_send_event(env.sink, c.gst_event_new_flush_stop(1)) });
        var sflag: c.guint = 0;
        out("  props {d}", .{sflag});
        c.g_object_get(env.el, "automatic-request-sync-point-flags", &sflag, NONE);
        out("  sync flags {d}", .{sflag});
        teardown(env);
    }
    {
        out("needs format and eos error", .{});
        mode = 0;
        const env = setup(t, "d4");
        c.gst_video_decoder_set_needs_format(env.dec, 1);
        push(env, mkbuf(1, 3, 0, 0, CT_NONE, 0));
        c.gst_video_decoder_set_needs_format(env.dec, 0);
        mode = 5;
        start(env, "video/x-test, width=2, height=2", 1.0);
        push(env, mkbuf(0xff, 3, 0, 0, CT_NONE, 0));
        out("  eos-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_eos())});
        drain(env.bus);
        mode = 7;
        teardown(env);
    }
    {
        out("subframes", .{});
        mode = 0;
        const env = setup(t, "d5");
        c.gst_video_decoder_set_subframe_mode(env.dec, 1);
        start(env, "video/x-test, width=2, height=2, framerate=30/1", 1.0);
        push(env, mkbuf(1, 3, 0, 0, CT_NONE, 0));
        push(env, mkbuf(1, 3, 0, 0, CT_NONE, c.GST_BUFFER_FLAG_MARKER));
        push(env, mkbuf(2, 3, 33 * MS, 33 * MS, CT_NONE, c.GST_BUFFER_FLAG_MARKER | DELTA));
        teardown(env);
    }
    out("misc", .{});
    out("  abstract {d}", .{c.g_type_test_flags(c.gst_video_decoder_get_type(), c.G_TYPE_FLAG_ABSTRACT)});
    c.gst_video_decoder_set_max_errors(null, 1);
    out("  {d}", .{c.gst_video_decoder_negotiate(null)});
}
