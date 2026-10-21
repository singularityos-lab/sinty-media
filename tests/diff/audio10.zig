const std = @import("std");
const c = @import("c").c;

var main_thread: ?*c.GThread = null;
var log_lock: c.GMutex = undefined;
var log_buf: [1 << 20]u8 = undefined;
var log_len: usize = 0;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    if (c.g_thread_self() != main_thread) {
        c.g_mutex_lock(&log_lock);
        @memcpy(log_buf[log_len..][0..s.len], s);
        log_len += s.len;
        c.g_mutex_unlock(&log_lock);
        return;
    }
    _ = std.c.write(1, s.ptr, s.len);
}

fn flushLog() void {
    c.g_mutex_lock(&log_lock);
    const hdr = "  streaming:\n";
    _ = std.c.write(1, hdr.ptr, hdr.len);
    _ = std.c.write(1, &log_buf, log_len);
    log_len = 0;
    c.g_mutex_unlock(&log_lock);
}

const NONE = @as(?*anyopaque, null);
const NOPROP = @as([*c]const u8, null);

fn probe(_: ?*c.GstPad, pinfo: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const e: [*c]c.GstEvent = @ptrCast(@alignCast(pinfo.*.data));
    switch (e.*.type) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            const s = c.gst_caps_to_string(caps);
            out("  event caps {s}", .{s});
            c.g_free(s);
        },
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            out("  event segment format {d} rate {d} start {d} stop {d} time {d}", .{ seg.*.format, seg.*.rate, seg.*.start, seg.*.stop, seg.*.time });
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(e, @ptrCast(&tags));
            const s = c.gst_tag_list_to_string(tags);
            out("  event tag {s}", .{s});
            c.g_free(s);
        },
        else => out("  event {s}", .{c.gst_event_type_get_name(e.*.type)}),
    }
    return c.GST_PAD_PROBE_OK;
}

fn hashBuf(b: [*c]c.GstBuffer) u64 {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    var h: u64 = 0xcbf29ce484222325;
    for (map.data[0..map.size]) |x| h = (h ^ x) *% 0x100000001b3;
    c.gst_buffer_unmap(b, &map);
    return h;
}


fn busDump(pipe: [*c]c.GstElement) void {
    const bus = c.gst_element_get_bus(pipe);
    while (c.gst_bus_pop(bus)) |m| {
        if (m.*.type == c.GST_MESSAGE_ERROR or m.*.type == c.GST_MESSAGE_WARNING) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            if (m.*.type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
            out("  bus {s} {s} {d} {s} | {s}", .{ c.gst_message_type_get_name(m.*.type), c.g_quark_to_string(e.*.domain), e.*.code, e.*.message, if (dbg != null) std.mem.span(dbg) else "-" });
            c.g_error_free(e);
            c.g_free(dbg);
        } else if (m.*.type == c.GST_MESSAGE_LATENCY) out("  bus latency", .{});
        c.gst_message_unref(m);
    }
    c.gst_object_unref(bus);
}

fn pushTone(src: [*c]c.GstElement, rate: u32, ch: u32, fmt_f32: bool, n: usize, frames: usize, gap_at: usize) void {
    var i: usize = 0;
    var phase: f64 = 0;
    var pts: u64 = 0;
    while (i < n) : (i += 1) {
        const bps: usize = if (fmt_f32) 4 else 2;
        const b = c.gst_buffer_new_allocate(null, frames * ch * bps, null);
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
        var k: usize = 0;
        while (k < frames) : (k += 1) {
            const v = @sin(phase) * 0.4;
            phase += 2.0 * std.math.pi * 440.0 / @as(f64, @floatFromInt(rate));
            var cc: usize = 0;
            while (cc < ch) : (cc += 1) {
                const idx = k * ch + cc;
                if (fmt_f32) {
                    @as([*]f32, @ptrCast(@alignCast(map.data)))[idx] = @floatCast(v);
                } else @as([*]i16, @ptrCast(@alignCast(map.data)))[idx] = @intFromFloat(v * 32767.0);
            }
        }
        c.gst_buffer_unmap(b, &map);
        if (i == gap_at) pts += 7 * 1000000;
        b.*.pts = pts;
        b.*.duration = c.gst_util_uint64_scale_int(frames, c.GST_SECOND, @intCast(rate));
        pts += b.*.duration;
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
        c.gst_buffer_unref(b);
    }
}

fn drainSink(sink: [*c]c.GstElement, max: usize) void {
    var n: usize = 0;
    var total: u64 = 0;
    var all: u64 = 0xcbf29ce484222325;
    while (true) {
        var sample: ?*c.GstSample = null;
        c.g_signal_emit_by_name(sink, "try-pull-sample", @as(u64, 5 * c.GST_SECOND), &sample);
        if (sample == null) break;
        const b = c.gst_sample_get_buffer(sample);
        const h = hashBuf(b);
        all = (all ^ h) *% 0x100000001b3;
        total += c.gst_buffer_get_size(b);
        if (n < max) out("  buf {d} pts {d} dts {d} dur {d} off {d} end {d} size {d} flags {x} hash {x}", .{ n, b.*.pts, b.*.dts, b.*.duration, b.*.offset, b.*.offset_end, c.gst_buffer_get_size(b), b.*.mini_object.flags, h });
        n += 1;
        c.gst_sample_unref(sample);
    }
    out("  buffers {d} bytes {d} hash {x}", .{ n, total, all });
}

fn findEncoder(bin: [*c]c.GstElement) ?*c.GstElement {
    const it = c.gst_bin_iterate_recurse(@ptrCast(bin));
    defer c.gst_iterator_free(it);
    var v = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &v) == c.GST_ITERATOR_OK) {
        const e: *c.GstElement = @ptrCast(@alignCast(c.g_value_get_object(&v)));
        if (c.g_type_is_a(@as(*c.GTypeInstance, @ptrCast(e)).g_class.*.g_type, c.gst_audio_encoder_get_type()) != 0) {
            _ = c.gst_object_ref(e);
            c.g_value_unset(&v);
            return e;
        }
        c.g_value_unset(&v);
    }
    return null;
}

fn encode(label: []const u8, desc: [*c]const u8, rate: u32, ch: u32, f32fmt: bool, n: usize, frames: usize, max: usize) void {
    out("encode {s}", .{label});
    var err: [*c]c.GError = null;
    const pipe = c.gst_parse_launch(desc, &err);
    if (pipe == null) {
        out("  parse failed {s}", .{err.*.message});
        return;
    }
    const src = c.gst_bin_get_by_name(@ptrCast(pipe), "in");
    const sink = c.gst_bin_get_by_name(@ptrCast(pipe), "out");
    var buf: [256]u8 = undefined;
    const cs = std.fmt.bufPrintZ(&buf, "audio/x-raw,format={s},layout=interleaved,rate={d},channels={d}{s}", .{ if (f32fmt) "F32LE" else "S16LE", rate, ch, if (ch == 2) ",channel-mask=(bitmask)0x3" else "" }) catch unreachable;
    const caps = c.gst_caps_from_string(cs.ptr);
    c.g_object_set(src, "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
    c.gst_caps_unref(caps);
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), NONE);
    const pad = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
    c.gst_object_unref(pad);
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    pushTone(src, rate, ch, f32fmt, n, frames, 999);
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    drainSink(sink, max);
    if (findEncoder(pipe)) |e| {
        const ae: [*c]c.GstAudioEncoder = @ptrCast(@alignCast(e));
        var mn: u64 = 0;
        var mx: u64 = 0;
        c.gst_audio_encoder_get_latency(ae, &mn, &mx);
        out("  encoder {s} min {d} max {d} framemax {d} lookahead {d} latency {d} {d} perfect {d} granule {d} resync {d} hardmin {d} drainable {d} tolerance {d}", .{ c.g_type_name(@as(*c.GTypeInstance, @ptrCast(e)).g_class.*.g_type), c.gst_audio_encoder_get_frame_samples_min(ae), c.gst_audio_encoder_get_frame_samples_max(ae), c.gst_audio_encoder_get_frame_max(ae), c.gst_audio_encoder_get_lookahead(ae), mn, mx, c.gst_audio_encoder_get_perfect_timestamp(ae), c.gst_audio_encoder_get_mark_granule(ae), c.gst_audio_encoder_get_hard_resync(ae), c.gst_audio_encoder_get_hard_min(ae), c.gst_audio_encoder_get_drainable(ae), c.gst_audio_encoder_get_tolerance(ae) });
        const sp = c.gst_element_get_static_pad(e, "src");
        var v: i64 = 0;
        out("  src convert {d} {d}", .{ c.gst_pad_query_convert(sp, c.GST_FORMAT_TIME, c.GST_SECOND, c.GST_FORMAT_BYTES, &v), v });
        c.gst_object_unref(sp);
        const kp = c.gst_element_get_static_pad(e, "sink");
        v = 0;
        out("  sink convert {d} {d}", .{ c.gst_pad_query_convert(kp, c.GST_FORMAT_TIME, c.GST_SECOND, c.GST_FORMAT_BYTES, &v), v });
        const kc = c.gst_pad_query_caps(kp, null);
        const ks = c.gst_caps_to_string(kc);
        out("  sink caps {s}", .{ks});
        c.g_free(ks);
        c.gst_caps_unref(kc);
        c.gst_object_unref(kp);
        c.gst_object_unref(e);
    }
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    flushLog();
    busDump(pipe);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    c.gst_object_unref(pipe);
}

var mode: u32 = 0;
var calls: u32 = 0;

fn teSetFormat(e: [*c]c.GstAudioEncoder, info: [*c]c.GstAudioInfo) callconv(.c) c.gboolean {
    out("  set_format rate {d} ch {d}", .{ info.*.rate, info.*.channels });
    c.gst_audio_encoder_set_frame_samples_min(e, 160);
    c.gst_audio_encoder_set_frame_samples_max(e, 160);
    if (mode == 1) c.gst_audio_encoder_set_lookahead(e, 40);
    if (mode == 2) c.gst_audio_encoder_set_frame_max(e, 3);
    const caps = c.gst_caps_from_string("audio/x-test,rate=8000,channels=1");
    const ok = c.gst_audio_encoder_set_output_format(e, caps);
    c.gst_caps_unref(caps);
    if (mode == 1) {
        var headers: [*c]c.GList = null;
        const h1 = c.gst_buffer_new_allocate(null, 7, null);
        _ = c.gst_buffer_memset(h1, 0, 0xaa, 7);
        const h2 = c.gst_buffer_new_allocate(null, 3, null);
        _ = c.gst_buffer_memset(h2, 0, 0xbb, 3);
        headers = c.g_list_append(headers, h1);
        headers = c.g_list_append(headers, h2);
        c.gst_audio_encoder_set_headers(e, headers);
        c.gst_audio_encoder_set_latency(e, 20 * c.GST_MSECOND, 40 * c.GST_MSECOND);
    }
    return ok;
}

fn teHandle(e: [*c]c.GstAudioEncoder, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    calls += 1;
    if (buf == null) {
        out("  handle_frame null", .{});
        return c.GST_FLOW_OK;
    }
    const size = c.gst_buffer_get_size(buf);
    out("  handle_frame {d} size {d} pts {d}", .{ calls, size, buf.*.pts });
    const o = c.gst_audio_encoder_allocate_output_buffer(e, size / 4 + 1);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(o, &map, c.GST_MAP_WRITE);
    @memset(map.data[0..map.size], @truncate(calls));
    c.gst_buffer_unmap(o, &map);
    if (mode == 3 and calls == 2) {
        const tags = c.gst_tag_list_new_empty();
        c.gst_tag_list_add(tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_TITLE, "encoded", NONE);
        c.gst_audio_encoder_merge_tags(e, tags, c.GST_TAG_MERGE_REPLACE);
        c.gst_tag_list_unref(tags);
    }
    const samples: c.gint = @intCast(size / 2);
    return c.gst_audio_encoder_finish_frame(e, o, if (mode == 2 and calls % 2 == 0) -1 else samples);
}

fn teClassInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    const k: *c.GstAudioEncoderClass = @ptrCast(@alignCast(kl));
    k.set_format = teSetFormat;
    k.handle_frame = teHandle;
    const ek: [*c]c.GstElementClass = @ptrCast(@alignCast(kl));
    c.gst_element_class_set_static_metadata(ek, "Test enc", "Codec/Encoder/Audio", "test", "test");
    const sc = c.gst_caps_from_string("audio/x-raw,format=S16LE,rate=8000,channels=1,layout=interleaved");
    c.gst_element_class_add_pad_template(ek, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, sc));
    c.gst_caps_unref(sc);
    const oc = c.gst_caps_from_string("audio/x-test");
    c.gst_element_class_add_pad_template(ek, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, oc));
    c.gst_caps_unref(oc);
}

fn teType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_audio_encoder_get_type(), "TestEnc", @sizeOf(c.GstAudioEncoderClass), teClassInit, @sizeOf(c.GstAudioEncoder), null, 0);
    return S.t;
}

fn custom(m: u32, label: []const u8, perfect: bool, granule: bool, resync: bool) void {
    out("custom {s}", .{label});
    mode = m;
    calls = 0;
    const pipe = c.gst_pipeline_new("p");
    const src = c.gst_element_factory_make("appsrc", "in");
    const enc: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(teType(), "name", "enc", NONE)));
    const sink = c.gst_element_factory_make("appsink", "out");
    const caps = c.gst_caps_from_string("audio/x-raw,format=S16LE,rate=8000,channels=1,layout=interleaved");
    c.g_object_set(src, "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
    c.gst_caps_unref(caps);
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), NONE);
    const spad = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(spad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
    c.gst_object_unref(spad);
    _ = c.gst_bin_add(@ptrCast(pipe), src);
    _ = c.gst_bin_add(@ptrCast(pipe), enc);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    _ = c.gst_element_link_many(src, enc, sink, NONE);
    const ae: [*c]c.GstAudioEncoder = @ptrCast(@alignCast(enc));
    if (granule) c.gst_audio_encoder_set_mark_granule(ae, 1);
    if (perfect) c.gst_audio_encoder_set_perfect_timestamp(ae, 1);
    if (resync) {
        c.gst_audio_encoder_set_hard_resync(ae, 1);
        c.gst_audio_encoder_set_tolerance(ae, c.GST_MSECOND);
    }
    if (m == 2) c.gst_audio_encoder_set_hard_min(ae, 1);
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    pushTone(src, 8000, 1, false, 7, 250, if (perfect) 3 else 999);
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    drainSink(sink, 40);
    const sp = c.gst_element_get_static_pad(enc, "src");
    const lq = c.gst_query_new_latency();
    if (c.gst_pad_query(sp, lq) != 0) {
        var live: c.gboolean = 0;
        var mn: u64 = 0;
        var mx: u64 = 0;
        c.gst_query_parse_latency(lq, &live, &mn, &mx);
        out("  latency query live {d} min {d} max {d}", .{ live, mn, mx });
    } else out("  latency query failed", .{});
    c.gst_query_unref(lq);
    var v: i64 = 0;
    out("  src convert {d} {d}", .{ c.gst_pad_query_convert(sp, c.GST_FORMAT_BYTES, 100, c.GST_FORMAT_TIME, &v), v });
    c.gst_object_unref(sp);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    flushLog();
    busDump(pipe);
    c.gst_object_unref(pipe);
}

fn props() void {
    const o = c.g_object_new(teType(), NOPROP).?;
    var n: c.guint = 0;
    const ps = c.g_object_class_list_properties(@ptrCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class), &n);
    for (ps[0..n]) |p| {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, p.*.value_type);
        c.g_object_get_property(@ptrCast(@alignCast(o)), p.*.name, &v);
        const s = c.g_strdup_value_contents(&v);
        out("prop {s} owner {s} flags {d} = {s}", .{ p.*.name, c.g_type_name(p.*.owner_type), p.*.flags, s });
        c.g_free(s);
        c.g_value_unset(&v);
    }
    c.g_free(@ptrCast(ps));
    out("preset iface {d}", .{c.g_type_is_a(teType(), c.gst_preset_get_type())});
    const ae: [*c]c.GstAudioEncoder = @ptrCast(@alignCast(o));
    c.gst_audio_encoder_set_mark_granule(ae, 1);
    c.g_object_set(o, "perfect-timestamp", @as(c.gboolean, 0), NONE);
    out("granule blocks perfect off {d}", .{c.gst_audio_encoder_get_perfect_timestamp(ae)});
    c.gst_audio_encoder_set_latency(ae, 10, 5);
    c.gst_audio_encoder_set_tolerance(ae, c.GST_CLOCK_TIME_NONE);
    _ = c.gst_audio_encoder_get_audio_info(null);
    c.gst_audio_encoder_merge_tags(ae, c.gst_tag_list_new_empty(), c.GST_TAG_MERGE_UNDEFINED);
    out("finish without caps {d}", .{c.gst_audio_encoder_finish_frame(ae, null, 1)});
    const bad = c.gst_caps_from_string("audio/x-other");
    out("output format not in template {d}", .{c.gst_audio_encoder_set_output_format(ae, bad)});
    c.gst_caps_unref(bad);
    c.gst_object_unref(o);
}

pub fn main() void {
    main_thread = c.g_thread_self();
    c.g_mutex_init(&log_lock);
    c.gst_init(null, null);
    const t = c.gst_audio_encoder_get_type();
    out("type {s} abstract {d} parent {s}", .{ c.g_type_name(t), @intFromBool(c.g_type_test_flags(t, c.G_TYPE_FLAG_ABSTRACT) != 0), c.g_type_name(c.g_type_parent(t)) });
    props();
    custom(0, "basic", false, false, false);
    custom(1, "lookahead-headers", false, false, false);
    custom(2, "framemax-hardmin", false, false, false);
    custom(3, "perfect-tags", true, false, false);
    custom(4, "granule-resync", true, true, true);
    encode("flac", "appsrc name=in ! flacenc ! appsink name=out", 44100, 2, false, 12, 1024, 6);
    encode("opus", "appsrc name=in ! opusenc ! appsink name=out", 48000, 2, false, 10, 960, 6);
    encode("mp3", "appsrc name=in ! lamemp3enc ! appsink name=out", 44100, 2, false, 10, 1152, 6);
    encode("alaw", "appsrc name=in ! alawenc ! appsink name=out", 8000, 1, false, 6, 800, 6);
    encode("mulaw", "appsrc name=in ! mulawenc ! appsink name=out", 8000, 1, false, 6, 800, 6);
    encode("opus-16k", "appsrc name=in ! opusenc ! appsink name=out", 16000, 1, false, 6, 320, 6);
}
