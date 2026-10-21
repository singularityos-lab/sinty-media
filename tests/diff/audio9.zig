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

fn findDecoder(bin: [*c]c.GstElement) ?*c.GstElement {
    const it = c.gst_bin_iterate_recurse(@ptrCast(bin));
    defer c.gst_iterator_free(it);
    var v = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &v) == c.GST_ITERATOR_OK) {
        const e: *c.GstElement = @ptrCast(@alignCast(c.g_value_get_object(&v)));
        const t = @as(*c.GTypeInstance, @ptrCast(e)).g_class.*.g_type;
        if (c.g_type_is_a(t, c.gst_audio_decoder_get_type()) != 0) {
            _ = c.gst_object_ref(e);
            c.g_value_unset(&v);
            return e;
        }
        c.g_value_unset(&v);
    }
    return null;
}

fn decode(label: []const u8, desc: [*c]const u8, max: usize) void {
    out("decode {s}", .{label});
    var err: [*c]c.GError = null;
    const pipe = c.gst_parse_launch(desc, &err);
    if (pipe == null) {
        out("  parse failed {s}", .{err.*.message});
        return;
    }
    const sink = c.gst_bin_get_by_name(@ptrCast(pipe), "out");
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), NONE);
    const pad = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
    c.gst_object_unref(pad);
    out("  paused {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PAUSED)});
    _ = c.gst_element_get_state(pipe, null, null, 5 * c.GST_SECOND);
    const dec = findDecoder(pipe);
    if (dec) |d| {
        const ad: [*c]c.GstAudioDecoder = @ptrCast(@alignCast(d));
        var mn: u64 = 0;
        var mx: u64 = 0;
        c.gst_audio_decoder_get_latency(ad, &mn, &mx);
        out("  decoder {s} delay {d} plc-aware {d} estimate {d} drainable {d} needs-format {d} latency {d} {d} tolerance {d} max-errors {d}", .{ c.g_type_name(@as(*c.GTypeInstance, @ptrCast(d)).g_class.*.g_type), c.gst_audio_decoder_get_delay(ad), c.gst_audio_decoder_get_plc_aware(ad), c.gst_audio_decoder_get_estimate_rate(ad), c.gst_audio_decoder_get_drainable(ad), c.gst_audio_decoder_get_needs_format(ad), mn, mx, c.gst_audio_decoder_get_tolerance(ad), c.gst_audio_decoder_get_max_errors(ad) });
    }
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
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
        if (n < max) out("  buf {d} pts {d} dur {d} off {d} end {d} size {d} flags {x} hash {x}", .{ n, b.*.pts, b.*.duration, b.*.offset, b.*.offset_end, c.gst_buffer_get_size(b), b.*.mini_object.flags, h });
        n += 1;
        c.gst_sample_unref(sample);
    }
    out("  buffers {d} bytes {d} hash {x}", .{ n, total, all });
    if (dec) |d| {
        const ad: [*c]c.GstAudioDecoder = @ptrCast(@alignCast(d));
        const ai = c.gst_audio_decoder_get_audio_info(ad);
        out("  info rate {d} ch {d} bpf {d}", .{ ai.*.rate, ai.*.channels, ai.*.bpf });
        const srcpad = c.gst_element_get_static_pad(d, "src");
        const sinkpad = c.gst_element_get_static_pad(d, "sink");
        var v: i64 = 0;
        out("  src position {d} {d}", .{ c.gst_pad_query_position(srcpad, c.GST_FORMAT_TIME, &v), v });
        v = 0;
        out("  src duration {d} {d}", .{ c.gst_pad_query_duration(srcpad, c.GST_FORMAT_TIME, &v), v });
        v = 0;
        out("  src convert {d} {d}", .{ c.gst_pad_query_convert(srcpad, c.GST_FORMAT_TIME, c.GST_SECOND, c.GST_FORMAT_BYTES, &v), v });
        v = 0;
        out("  sink convert {d} {d}", .{ c.gst_pad_query_convert(sinkpad, c.GST_FORMAT_BYTES, 1000, c.GST_FORMAT_TIME, &v), v });
        const fq = c.gst_query_new_formats();
        var nf: c.guint = 0;
        _ = c.gst_pad_query(sinkpad, fq);
        c.gst_query_parse_n_formats(fq, &nf);
        out("  sink formats {d}", .{nf});
        c.gst_query_unref(fq);
        const caps = c.gst_pad_query_caps(sinkpad, null);
        const cs = c.gst_caps_to_string(caps);
        out("  sink caps {s}", .{cs});
        c.g_free(cs);
        c.gst_caps_unref(caps);
        c.gst_object_unref(srcpad);
        c.gst_object_unref(sinkpad);
        c.gst_object_unref(d);
    }
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(sink);
    c.gst_object_unref(pipe);
}

var handled: u32 = 0;
var mode: u32 = 0;

fn tdSetFormat(d: [*c]c.GstAudioDecoder, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = c.gst_caps_to_string(caps);
    out("  set_format {s}", .{s});
    c.g_free(s);
    var info: c.GstAudioInfo = undefined;
    c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_S16LE, 8000, 1, null);
    return c.gst_audio_decoder_set_output_format(d, &info);
}

fn tdHandle(d: [*c]c.GstAudioDecoder, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    if (buf == null) {
        out("  handle_frame null", .{});
        return c.GST_FLOW_OK;
    }
    handled += 1;
    const size = c.gst_buffer_get_size(buf);
    out("  handle_frame {d} size {d} pts {d} delay {d}", .{ handled, size, buf.*.pts, c.gst_audio_decoder_get_delay(d) });
    if (mode == 1 and handled == 3) return c._gst_audio_decoder_error(d, 1, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, c.g_strdup("bad frame"), c.g_strdup("frame three"), "test.c", "tdHandle", 42);
    if (mode == 2 and handled % 2 == 1) return c.GST_FLOW_OK;
    const o = c.gst_audio_decoder_allocate_output_buffer(d, size * 2);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(o, &map, c.GST_MAP_WRITE);
    @memset(map.data[0..map.size], @intCast(handled));
    c.gst_buffer_unmap(o, &map);
    if (mode == 3 and handled == 2) {
        const tags = c.gst_tag_list_new_empty();
        c.gst_tag_list_add(tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_TITLE, "decoded", NONE);
        c.gst_audio_decoder_merge_tags(d, tags, c.GST_TAG_MERGE_REPLACE);
        c.gst_tag_list_unref(tags);
    }
    return c.gst_audio_decoder_finish_frame(d, o, if (mode == 2) -1 else 1);
}

fn tdClassInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    const k: *c.GstAudioDecoderClass = @ptrCast(@alignCast(kl));
    k.set_format = tdSetFormat;
    k.handle_frame = tdHandle;
    const ek: [*c]c.GstElementClass = @ptrCast(@alignCast(kl));
    c.gst_element_class_set_static_metadata(ek, "Test dec", "Codec/Decoder/Audio", "test", "test");
    const sc = c.gst_caps_from_string("audio/x-test");
    c.gst_element_class_add_pad_template(ek, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, sc));
    c.gst_caps_unref(sc);
    const oc = c.gst_caps_from_string("audio/x-raw,format=S16LE,rate=8000,channels=1,layout=interleaved");
    c.gst_element_class_add_pad_template(ek, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, oc));
    c.gst_caps_unref(oc);
}

fn tdType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_audio_decoder_get_type(), "TestDec", @sizeOf(c.GstAudioDecoderClass), tdClassInit, @sizeOf(c.GstAudioDecoder), null, 0);
    return S.t;
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

fn custom(m: u32, label: []const u8) void {
    out("custom {s}", .{label});
    mode = m;
    handled = 0;
    const pipe = c.gst_pipeline_new("p");
    const src = c.gst_element_factory_make("appsrc", "src");
    const dec: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(tdType(), "name", "dec", NONE)));
    const sink = c.gst_element_factory_make("appsink", "out");
    const caps = c.gst_caps_from_string("audio/x-test");
    c.g_object_set(src, "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
    c.gst_caps_unref(caps);
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), NONE);
    const spad = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(spad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
    c.gst_object_unref(spad);
    _ = c.gst_bin_add(@ptrCast(pipe), src);
    _ = c.gst_bin_add(@ptrCast(pipe), dec);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    _ = c.gst_element_link_many(src, dec, sink, NONE);
    const ad: [*c]c.GstAudioDecoder = @ptrCast(@alignCast(dec));
    if (m == 1) c.gst_audio_decoder_set_max_errors(ad, 0);
    if (m == 3) {
        c.gst_audio_decoder_set_latency(ad, 5 * c.GST_MSECOND, 9 * c.GST_MSECOND);
        c.gst_audio_decoder_set_tolerance(ad, 2 * c.GST_MSECOND);
    }
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const b = c.gst_buffer_new_allocate(null, 100, null);
        _ = c.gst_buffer_memset(b, 0, @intCast(i), 100);
        const us: u64 = 1000;
        const ms: u64 = 1000000;
        b.*.pts = if (m == 3 and i == 4) std.math.maxInt(u64) else i * 12500 * us + (if (m == 3 and i == 2) 7 * ms else 0);
        if (i == 5 and m == 0) b.*.mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
        c.gst_buffer_unref(b);
    }
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    var n: usize = 0;
    while (true) {
        var sample: ?*c.GstSample = null;
        c.g_signal_emit_by_name(sink, "try-pull-sample", @as(u64, 2 * c.GST_SECOND), &sample);
        if (sample == null) break;
        const b = c.gst_sample_get_buffer(sample);
        out("  out {d} pts {d} dur {d} size {d} flags {x} hash {x}", .{ n, b.*.pts, b.*.duration, c.gst_buffer_get_size(b), b.*.mini_object.flags, hashBuf(b) });
        n += 1;
        c.gst_sample_unref(sample);
    }
    var mn: u64 = 0;
    var mx: u64 = 0;
    c.gst_audio_decoder_get_latency(ad, &mn, &mx);
    var sync: c.gboolean = 0;
    var eos: c.gboolean = 0;
    c.gst_audio_decoder_get_parse_state(ad, &sync, &eos);
    out("  latency {d} {d} parse sync {d} eos {d} delay {d}", .{ mn, mx, sync, eos, c.gst_audio_decoder_get_delay(ad) });
    const lq = c.gst_query_new_latency();
    const srcpad = c.gst_element_get_static_pad(dec, "src");
    if (c.gst_pad_query(srcpad, lq) != 0) {
        var live: c.gboolean = 0;
        c.gst_query_parse_latency(lq, &live, &mn, &mx);
        out("  latency query live {d} min {d} max {d}", .{ live, mn, mx });
    } else out("  latency query failed", .{});
    c.gst_query_unref(lq);
    c.gst_object_unref(srcpad);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    flushLog();
    busDump(pipe);
    c.gst_object_unref(pipe);
}

fn props() void {
    const o = c.g_object_new(tdType(), NOPROP).?;
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
    const ad: [*c]c.GstAudioDecoder = @ptrCast(@alignCast(o));
    c.gst_audio_decoder_set_plc(ad, 1);
    c.gst_audio_decoder_set_min_latency(ad, 33);
    c.gst_audio_decoder_set_drainable(ad, 0);
    c.gst_audio_decoder_set_needs_format(ad, 1);
    c.gst_audio_decoder_set_plc_aware(ad, 1);
    c.gst_audio_decoder_set_estimate_rate(ad, 1);
    out("getters plc {d} min {d} drainable {d} needs {d} aware {d} estimate {d}", .{ c.gst_audio_decoder_get_plc(ad), c.gst_audio_decoder_get_min_latency(ad), c.gst_audio_decoder_get_drainable(ad), c.gst_audio_decoder_get_needs_format(ad), c.gst_audio_decoder_get_plc_aware(ad), c.gst_audio_decoder_get_estimate_rate(ad) });
    c.gst_audio_decoder_set_latency(ad, 10, 5);
    c.gst_audio_decoder_set_tolerance(ad, c.GST_CLOCK_TIME_NONE);
    _ = c.gst_audio_decoder_finish_frame(ad, null, 0);
    _ = c.gst_audio_decoder_get_audio_info(null);
    c.gst_audio_decoder_merge_tags(ad, null, c.GST_TAG_MERGE_UNDEFINED);
    var info: c.GstAudioInfo = undefined;
    c.gst_audio_info_init(&info);
    out("set output format invalid {d}", .{c.gst_audio_decoder_set_output_format(ad, &info)});
    const bad = c.gst_caps_from_string("audio/x-raw,format=F32LE,rate=8000,channels=1,layout=interleaved");
    out("set output caps not in template {d}", .{c.gst_audio_decoder_set_output_caps(ad, bad)});
    c.gst_caps_unref(bad);
    const unfixed = c.gst_caps_from_string("audio/x-raw,format=S16LE,rate=[1,9],channels=1");
    out("set output caps unfixed {d}", .{c.gst_audio_decoder_set_output_caps(ad, unfixed)});
    c.gst_caps_unref(unfixed);
    const ob = c.gst_audio_decoder_allocate_output_buffer(ad, 64);
    out("alloc {d}", .{c.gst_buffer_get_size(ob)});
    c.gst_buffer_unref(ob);
    var alloc: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    c.gst_audio_decoder_get_allocator(ad, &alloc, &params);
    out("allocator null {d} align {d}", .{ @intFromBool(alloc == null), params.@"align" });
    c.gst_object_unref(o);
}

pub fn main() void {
    main_thread = c.g_thread_self();
    c.g_mutex_init(&log_lock);
    c.gst_init(null, null);
    const t = c.gst_audio_decoder_get_type();
    out("type {s} abstract {d} parent {s}", .{ c.g_type_name(t), @intFromBool(c.g_type_test_flags(t, c.G_TYPE_FLAG_ABSTRACT) != 0), c.g_type_name(c.g_type_parent(t)) });
    props();
    custom(0, "basic");
    custom(1, "errors");
    custom(2, "delayed");
    custom(3, "tags-tolerance");
    decode("flac", "filesrc location=tests/data/tone.flac ! flacparse ! flacdec ! appsink name=out", 6);
    decode("opus", "filesrc location=tests/data/tone.opus.ogg ! oggdemux ! opusdec ! appsink name=out", 6);
    decode("mp3", "filesrc location=tests/data/tone.mp3 ! mpegaudioparse ! mpg123audiodec ! appsink name=out", 6);
    decode("alaw", "filesrc location=tests/data/tone.alaw blocksize=800 ! audio/x-alaw,rate=8000,channels=1 ! alawdec ! appsink name=out", 6);
}
