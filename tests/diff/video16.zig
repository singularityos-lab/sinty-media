const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);
const CT_NONE: u64 = std.math.maxInt(u64);
const MS: u64 = 1_000_000;

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

fn setFormat(e: [*c]c.GstVideoEncoder, st: [*c]c.GstVideoCodecState) callconv(.c) c.gboolean {
    const s = c.gst_caps_to_string(st[0].caps);
    out("    set_format {s} hdr {d} {d}", .{ s, @intFromBool(st[0].mastering_display_info != null), @intFromBool(st[0].content_light_level != null) });
    c.g_free(s);
    if (mode == 3) return 1;
    const os = c.gst_video_encoder_set_output_state(e, c.gst_caps_from_string("video/x-enc, profile=main"), st);
    const cd = c.gst_buffer_new_allocate(null, 2, null);
    os[0].codec_data = cd;
    c.gst_video_codec_state_unref(os);
    return 1;
}

fn handleFrame(e: [*c]c.GstVideoEncoder, f: [*c]c.GstVideoCodecFrame) callconv(.c) c.GstFlowReturn {
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(f[0].input_buffer, &mi, c.GST_MAP_READ);
    const first: u8 = mi.data[0];
    c.gst_buffer_unmap(f[0].input_buffer, &mi);
    out("    handle #{d} pfn {d} pts {d} dts {d} dur {d} flags {d} deadline {d} b {d}", .{ f[0].system_frame_number, f[0].presentation_frame_number, ts(f[0].pts), ts(f[0].dts), ts(f[0].duration), f[0].flags, ts(f[0].deadline), first });
    if (first == 0xff) {
        c.gst_video_encoder_drop_frame(e, f);
        return c.GST_FLOW_OK;
    }
    if (first == 0xfe) {
        const old = c.gst_video_encoder_get_oldest_frame(e);
        out("    hold oldest #{d} n {d} max {d}", .{ old[0].system_frame_number, c.g_list_length(c.gst_video_encoder_get_frames(e)), c.gst_video_encoder_get_max_encode_time(e, f) });
        c.gst_video_codec_frame_unref(old);
        c.gst_video_codec_frame_unref(f);
        return c.GST_FLOW_OK;
    }
    if (first == 0xfd) {
        _ = c.gst_video_encoder_allocate_output_frame(e, f, 2);
        f[0].flags |= c.GST_VIDEO_CODEC_FRAME_FLAG_SYNC_POINT;
        out("    sub {d}", .{c.gst_video_encoder_finish_subframe(e, f)});
        _ = c.gst_video_encoder_allocate_output_frame(e, f, 3);
        out("    sub {d}", .{c.gst_video_encoder_finish_subframe(e, f)});
        _ = c.gst_video_encoder_allocate_output_frame(e, f, 4);
        return c.gst_video_encoder_finish_frame(e, f);
    }
    if (first == 0xfc) {
        return c.gst_video_encoder_finish_frame(e, f);
    }
    const r = c.gst_video_encoder_allocate_output_frame(e, f, @as(usize, first) + 1);
    if (r != c.GST_FLOW_OK) return r;
    if (first % 3 == 1 or f[0].flags & c.GST_VIDEO_CODEC_FRAME_FLAG_FORCE_KEYFRAME != 0) f[0].flags |= c.GST_VIDEO_CODEC_FRAME_FLAG_SYNC_POINT;
    if (first == 9) {
        var hl: ?*c.GList = null;
        hl = c.g_list_append(hl, c.gst_buffer_new_allocate(null, 5, null));
        hl = c.g_list_append(hl, c.gst_buffer_new_allocate(null, 6, null));
        c.gst_video_encoder_set_headers(e, hl);
    }
    return c.gst_video_encoder_finish_frame(e, f);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: [*c]c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, c.gst_caps_from_string("video/x-raw, format=(string){ GRAY8, I420 }, width=(int)[1,100], height=(int)[1,100]")));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, c.gst_caps_from_string("video/x-enc")));
    c.gst_element_class_set_static_metadata(ec, "t", "Codec/Encoder/Video", "t", "t");
    const vc: *c.GstVideoEncoderClass = @ptrCast(@alignCast(k));
    vc.set_format = setFormat;
    vc.handle_frame = handleFrame;
}

fn peerChain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    out("  OUT pts {d} dts {d} dur {d} flags {d} size {d}", .{ ts(b[0].pts), ts(b[0].dts), ts(b[0].duration), b[0].mini_object.flags, c.gst_buffer_get_size(b) });
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
        out("  EV segment start {d} stop {d} pos {d}", .{ ts(seg[0].start), ts(seg[0].stop), ts(seg[0].position) });
    } else {
        out("  EV {s}", .{c.gst_event_type_get_name(e[0].type)});
        if (e[0].type == c.GST_EVENT_TAG or e[0].type == c.GST_EVENT_CUSTOM_DOWNSTREAM) showS("    s", c.gst_event_get_structure(e));
    }
    c.gst_event_unref(e);
    return 1;
}

fn peerQuery(_: ?*c.GstPad, _: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_ALLOCATION) {
        out("  Q allocation", .{});
        var params = c.GstAllocationParams{ .flags = 0, .@"align" = 31, .prefix = 0, .padding = 0 };
        c.gst_query_add_allocation_param(q, null, &params);
        return 1;
    }
    if (q[0].type == c.GST_QUERY_CAPS) {
        var filter: [*c]c.GstCaps = null;
        c.gst_query_parse_caps(q, &filter);
        const caps = c.gst_caps_from_string("video/x-enc, width=(int)[1,50], framerate=(fraction)[0/1,60/1]");
        const r = if (filter != null) c.gst_caps_intersect(caps, filter) else c.gst_caps_ref(caps);
        c.gst_query_set_caps_result(q, r);
        c.gst_caps_unref(r);
        c.gst_caps_unref(caps);
        return 1;
    }
    return 0;
}

fn upQuery(_: ?*c.GstPad, _: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_LATENCY) {
        c.gst_query_set_latency(q, 0, 3, CT_NONE);
        return 1;
    }
    return 0;
}

fn upEvent(_: ?*c.GstPad, _: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    out("  UP {s}", .{c.gst_event_type_get_name(e[0].type)});
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
                out("  MSG {s} {s} | {s}", .{ c.gst_message_type_get_name(m[0].type), err[0].message, if (dbg != null) std.mem.span(dbg) else "-" });
                c.g_error_free(err);
                c.g_free(dbg);
            },
            c.GST_MESSAGE_QOS => {
                var jitter: i64 = 0;
                var prop: f64 = 0;
                var quality: c.gint = 0;
                c.gst_message_parse_qos_values(m, &jitter, &prop, &quality);
                var fmt: c.GstFormat = 0;
                var proc: u64 = 0;
                var drop: u64 = 0;
                c.gst_message_parse_qos_stats(m, &fmt, &proc, &drop);
                out("  MSG qos jitter {d} prop {d} stats {d} {d}", .{ jitter, prop, proc, drop });
            },
            else => out("  MSG {s}", .{c.gst_message_type_get_name(m[0].type)}),
        }
        c.gst_message_unref(m);
    }
}

fn mkbuf(b0: u8, pts: u64, dur: u64) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, 8, null);
    _ = c.gst_buffer_memset(b, 0, b0, 8);
    b[0].pts = pts;
    b[0].duration = dur;
    return b;
}

const Env = struct { el: [*c]c.GstElement, enc: [*c]c.GstVideoEncoder, sink: ?*c.GstPad, src: ?*c.GstPad, peer: ?*c.GstPad, up: ?*c.GstPad, bus: ?*c.GstBus };

fn setup(t: c.GType, name: [*:0]const u8) Env {
    const e: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(t, "name", name, NONE)));
    const d: [*c]c.GstVideoEncoder = @ptrCast(e);
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
    return .{ .el = e, .enc = d, .sink = d[0].sinkpad, .src = d[0].srcpad, .peer = peer, .up = up, .bus = bus };
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

fn start(env: Env, caps: [*:0]const u8, seg_start: u64) void {
    out("  start-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_stream_start("s"))});
    out("  caps-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_caps(c.gst_caps_from_string(caps)))});
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = seg_start;
    out("  seg-ev {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_segment(&seg))});
}

fn push(env: Env, b: [*c]c.GstBuffer) void {
    out("  push {d}", .{c.gst_pad_chain(env.sink, b)});
    drain(env.bus);
}

pub fn main() void {
    c.gst_init(null, null);
    const t = c.g_type_register_static_simple(c.gst_video_encoder_get_type(), "TEnc", @sizeOf(c.GstVideoEncoderClass), classInit, @sizeOf(c.GstVideoEncoder), null, 0);
    out("preset {d}", .{@intFromBool(c.g_type_is_a(t, c.gst_preset_get_type()) != 0)});
    {
        out("basic", .{});
        mode = 0;
        const env = setup(t, "e0");
        var q: c.gboolean = 7;
        var mfk: u64 = 7;
        c.g_object_get(env.el, "qos", &q, "min-force-key-unit-interval", &mfk, NONE);
        out("  qos {d} mfk {d}", .{ q, mfk });
        push(env, mkbuf(1, 0, 10 * MS));
        start(env, "video/x-raw, format=GRAY8, width=4, height=2, framerate=30/1, pixel-aspect-ratio=1/1, mastering-display-info=(string)\"35399:14599:8500:39850:6550:2300:15634:16450:10000000:1\", content-light-level=(string)\"1000:400\", chroma-site=mpeg2", 5 * MS);
        out("  caps-ev same {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_caps(c.gst_caps_from_string("video/x-raw, format=GRAY8, width=4, height=2, framerate=30/1, pixel-aspect-ratio=1/1, mastering-display-info=(string)\"35399:14599:8500:39850:6550:2300:15634:16450:10000000:1\", content-light-level=(string)\"1000:400\", chroma-site=mpeg2")))});
        push(env, mkbuf(1, 0, 10 * MS));
        push(env, mkbuf(2, 10 * MS, 33 * MS));
        push(env, mkbuf(3, 40 * MS, CT_NONE));
        push(env, mkbuf(0xff, 80 * MS, CT_NONE));
        push(env, mkbuf(0xfe, 90 * MS, CT_NONE));
        push(env, mkbuf(5, 100 * MS, CT_NONE));
        _ = c.gst_pad_send_event(env.sink, c.gst_video_event_new_downstream_force_key_unit(CT_NONE, CT_NONE, 120 * MS, 1, 4));
        _ = c.gst_pad_send_event(env.src, c.gst_video_event_new_upstream_force_key_unit(CT_NONE, 0, 2));
        push(env, mkbuf(5, 130 * MS, CT_NONE));
        push(env, mkbuf(6, 140 * MS, CT_NONE));
        push(env, mkbuf(9, 150 * MS, CT_NONE));
        push(env, mkbuf(10, 160 * MS, CT_NONE));
        push(env, mkbuf(0xfd, 170 * MS, CT_NONE));
        push(env, mkbuf(0xfc, 180 * MS, CT_NONE));
        const tags = c.gst_tag_list_new("title", "t", "bitrate", @as(c.guint, 1000), "encoder", "x", NONE);
        _ = c.gst_pad_send_event(env.sink, c.gst_event_new_tag(tags));
        c.gst_video_encoder_merge_tags(env.enc, c.gst_tag_list_new("artist", "a", NONE), c.GST_TAG_MERGE_APPEND);
        push(env, mkbuf(7, 190 * MS, CT_NONE));
        c.gst_video_encoder_set_qos_enabled(env.enc, 1);
        out("  qos-ev {d}", .{c.gst_pad_send_event(env.src, c.gst_event_new_qos(c.GST_QOS_TYPE_OVERFLOW, 0.5, -@as(i64, @intCast(5 * MS)), 200 * MS))});
        push(env, mkbuf(0xfe, 210 * MS, CT_NONE));
        c.gst_video_encoder_set_latency(env.enc, 2 * MS, 4 * MS);
        var mn: u64 = 0;
        var mx: u64 = 0;
        c.gst_video_encoder_get_latency(env.enc, &mn, &mx);
        out("  latency {d} {d}", .{ mn, mx });
        const lq = c.gst_query_new_latency();
        out("  latency q {d}", .{c.gst_pad_query(env.src, lq)});
        var live: c.gboolean = 0;
        c.gst_query_parse_latency(lq, &live, &mn, &mx);
        out("    {d} {d} {d}", .{ live, mn, ts(mx) });
        c.gst_query_unref(lq);
        for ([_][2]c.GstFormat{ .{ c.GST_FORMAT_TIME, c.GST_FORMAT_BYTES }, .{ c.GST_FORMAT_BYTES, c.GST_FORMAT_TIME }, .{ c.GST_FORMAT_DEFAULT, c.GST_FORMAT_TIME } }) |f| {
            var dv: i64 = 0;
            const qa = c.gst_query_new_convert(f[0], 1000, f[1]);
            const ra = c.gst_pad_query(env.src, qa);
            c.gst_query_parse_convert(qa, null, null, null, &dv);
            out("  convert src {d}->{d}: {d} {d}", .{ f[0], f[1], ra, dv });
            c.gst_query_unref(qa);
            const qb = c.gst_query_new_convert(f[0], 1000, f[1]);
            const rb = c.gst_pad_query(env.sink, qb);
            c.gst_query_parse_convert(qb, null, null, null, &dv);
            out("  convert sink {d}->{d}: {d} {d}", .{ f[0], f[1], rb, dv });
            c.gst_query_unref(qb);
        }
        const cq = c.gst_query_new_caps(null);
        out("  caps q {d}", .{c.gst_pad_query(env.sink, cq)});
        var cr: [*c]c.GstCaps = null;
        c.gst_query_parse_caps_result(cq, &cr);
        const crs = c.gst_caps_to_string(cr);
        out("    {s}", .{crs});
        c.g_free(crs);
        c.gst_query_unref(cq);
        const aq = c.gst_query_new_allocation(c.gst_caps_from_string("video/x-raw, format=GRAY8, width=4, height=2"), 1);
        out("  alloc q {d} pools {d} metas {d}", .{ c.gst_pad_query(env.sink, aq), c.gst_query_get_n_allocation_pools(aq), c.gst_query_get_n_allocation_metas(aq) });
        c.gst_query_unref(aq);
        var alloc: [*c]c.GstAllocator = null;
        var params: c.GstAllocationParams = undefined;
        c.gst_video_encoder_get_allocator(env.enc, &alloc, &params);
        out("  allocator {d} align {d}", .{ @intFromBool(alloc != null), params.@"align" });
        const ob = c.gst_video_encoder_allocate_output_buffer(env.enc, 7);
        out("  out buf {d}", .{c.gst_buffer_get_size(ob)});
        c.gst_buffer_unref(ob);
        const os = c.gst_video_encoder_get_output_state(env.enc);
        const ocs = c.gst_caps_to_string(os[0].caps);
        out("  output state {s}", .{ocs});
        c.g_free(ocs);
        c.gst_video_codec_state_unref(os);
        out("  flush {d} {d}", .{ c.gst_pad_send_event(env.sink, c.gst_event_new_flush_start()), c.gst_pad_send_event(env.sink, c.gst_event_new_flush_stop(1)) });
        out("  eos {d}", .{c.gst_pad_send_event(env.sink, c.gst_event_new_eos())});
        teardown(env);
    }
    {
        out("min pts", .{});
        mode = 0;
        const env = setup(t, "e1");
        c.gst_video_encoder_set_min_pts(env.enc, 1000 * MS);
        start(env, "video/x-raw, format=I420, width=4, height=2, framerate=0/1, interlace-mode=interleaved, field-order=top-field-first", 0);
        push(env, mkbuf(1, 20 * MS, 5 * MS));
        push(env, mkbuf(2, 25 * MS, 5 * MS));
        var seg: c.GstSegment = undefined;
        c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
        seg.start = 30 * MS;
        seg.stop = 100 * MS;
        _ = c.gst_pad_send_event(env.sink, c.gst_event_new_segment(&seg));
        push(env, mkbuf(4, 20 * MS, 5 * MS));
        push(env, mkbuf(4, 40 * MS, 5 * MS));
        teardown(env);
    }
    {
        out("no output state", .{});
        mode = 3;
        const env = setup(t, "e2");
        start(env, "video/x-raw, format=GRAY8, width=4, height=2", 0);
        push(env, mkbuf(1, 0, CT_NONE));
        teardown(env);
    }
    out("misc", .{});
    c.gst_video_encoder_set_qos_enabled(null, 1);
    out("  {d}", .{c.gst_video_encoder_negotiate(null)});
}
