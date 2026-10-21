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


fn pushTone(src: [*c]c.GstElement, rate: u32, ch: u32, f32fmt: bool, n: usize, frames: usize, freq: f64, start: u64, gap_at: usize) void {
    var i: usize = 0;
    var phase: f64 = 0;
    var pts: u64 = start;
    while (i < n) : (i += 1) {
        const bps: usize = if (f32fmt) 4 else 2;
        const b = c.gst_buffer_new_allocate(null, frames * ch * bps, null);
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
        var k: usize = 0;
        while (k < frames) : (k += 1) {
            const v = @sin(phase) * 0.3;
            phase += 2.0 * std.math.pi * freq / @as(f64, @floatFromInt(rate));
            var cc: usize = 0;
            while (cc < ch) : (cc += 1) {
                const idx = k * ch + cc;
                if (f32fmt) {
                    @as([*]f32, @ptrCast(@alignCast(map.data)))[idx] = @floatCast(v);
                } else @as([*]i16, @ptrCast(@alignCast(map.data)))[idx] = @intFromFloat(v * 32767.0);
            }
        }
        c.gst_buffer_unmap(b, &map);
        if (i == gap_at) pts += 30 * 1000000;
        b.*.pts = pts;
        b.*.duration = c.gst_util_uint64_scale_int(frames, c.GST_SECOND, @intCast(rate));
        pts += b.*.duration;
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
        c.gst_buffer_unref(b);
    }
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
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
        if (n < max) out("  buf {d} pts {d} dur {d} off {d} end {d} size {d} flags {x} hash {x}", .{ n, b.*.pts, b.*.duration, b.*.offset, b.*.offset_end, c.gst_buffer_get_size(b), b.*.mini_object.flags, h });
        n += 1;
        c.gst_sample_unref(sample);
    }
    out("  buffers {d} bytes {d} hash {x}", .{ n, total, all });
}

const Input = struct { caps: [*c]const u8, rate: u32, ch: u32, f32fmt: bool, n: usize, frames: usize, freq: f64, start: u64, gap: usize };

fn mix(label: []const u8, elem_name: [*c]const u8, out_caps: ?[*c]const u8, inputs: []const Input, props: bool) void {
    out("mix {s}", .{label});
    const pipe = c.gst_pipeline_new("p");
    const m = c.gst_element_factory_make(elem_name, "mix");
    if (m == null) {
        out("  no element", .{});
        return;
    }
    const sink = c.gst_element_factory_make("appsink", "out");
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), NONE);
    if (out_caps) |oc| {
        const caps = c.gst_caps_from_string(oc);
        c.g_object_set(sink, "caps", caps, NONE);
        c.gst_caps_unref(caps);
    }
    const kp = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(kp, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
    c.gst_object_unref(kp);
    _ = c.gst_bin_add(@ptrCast(pipe), m);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    _ = c.gst_element_link(m, sink);
    var srcs: [4][*c]c.GstElement = undefined;
    for (inputs, 0..) |in, i| {
        var nb: [16]u8 = undefined;
        const nm = std.fmt.bufPrintZ(&nb, "in{d}", .{i}) catch unreachable;
        const s = c.gst_element_factory_make("appsrc", nm.ptr);
        const caps = c.gst_caps_from_string(in.caps);
        c.g_object_set(s, "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
        c.gst_caps_unref(caps);
        _ = c.gst_bin_add(@ptrCast(pipe), s);
        _ = c.gst_element_link(s, m);
        srcs[i] = s;
    }
    if (props) {
        var n: c.guint = 0;
        const ps = c.g_object_class_list_properties(@ptrCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(m))).g_class), &n);
        for (ps[0..n]) |p| {
            if (p.*.flags & c.G_PARAM_READABLE == 0) continue;
            var v = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&v, p.*.value_type);
            c.g_object_get_property(@ptrCast(@alignCast(m)), p.*.name, &v);
            const s = c.g_strdup_value_contents(&v);
            out("  prop {s} owner {s} flags {d} = {s}", .{ p.*.name, c.g_type_name(p.*.owner_type), p.*.flags, s });
            c.g_free(s);
            c.g_value_unset(&v);
        }
        c.g_free(@ptrCast(ps));
        const sp = c.gst_element_get_static_pad(m, "sink_0");
        if (sp != null) {
            out("  sink_0 type {s} convert {d}", .{ c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(sp))).g_class.*.g_type), c.g_type_is_a(@as(*c.GTypeInstance, @ptrCast(@alignCast(sp))).g_class.*.g_type, c.gst_audio_aggregator_convert_pad_get_type()) });
            c.gst_object_unref(sp);
        }
    }
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    for (inputs, 0..) |in, i| pushTone(srcs[i], in.rate, in.ch, in.f32fmt, in.n, in.frames, in.freq, in.start, in.gap);
    drainSink(sink, 12);
    const mp = c.gst_element_get_static_pad(m, "src");
    var v: i64 = 0;
    out("  position {d} {d}", .{ c.gst_pad_query_position(mp, c.GST_FORMAT_DEFAULT, &v), v });
    v = 0;
    out("  position bytes {d} {d}", .{ c.gst_pad_query_position(mp, c.GST_FORMAT_BYTES, &v), v });
    c.gst_object_unref(mp);
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    flushLog();
    busDump(pipe);
    c.gst_object_unref(pipe);
}

pub fn main() void {
    main_thread = c.g_thread_self();
    c.g_mutex_init(&log_lock);
    c.gst_init(null, null);
    const t = c.gst_audio_aggregator_get_type();
    out("type {s} abstract {d} parent {s}", .{ c.g_type_name(t), @intFromBool(c.g_type_test_flags(t, c.G_TYPE_FLAG_ABSTRACT) != 0), c.g_type_name(c.g_type_parent(t)) });
    out("pad parent {s} convert parent {s}", .{ c.g_type_name(c.g_type_parent(c.gst_audio_aggregator_pad_get_type())), c.g_type_name(c.g_type_parent(c.gst_audio_aggregator_convert_pad_get_type())) });
    const s16 = "audio/x-raw,format=S16LE,layout=interleaved,rate=48000,channels=2,channel-mask=(bitmask)0x3";
    const f32s = "audio/x-raw,format=F32LE,layout=interleaved,rate=48000,channels=2,channel-mask=(bitmask)0x3";
    const mono = "audio/x-raw,format=S16LE,layout=interleaved,rate=48000,channels=1";
    mix("two-s16", "audiomixer", null, &.{ .{ .caps = s16, .rate = 48000, .ch = 2, .f32fmt = false, .n = 8, .frames = 960, .freq = 440, .start = 0, .gap = 99 }, .{ .caps = s16, .rate = 48000, .ch = 2, .f32fmt = false, .n = 6, .frames = 480, .freq = 660, .start = 5000000, .gap = 99 } }, true);
    mix("s16-f32-convert", "audiomixer", "audio/x-raw,format=F32LE", &.{ .{ .caps = s16, .rate = 48000, .ch = 2, .f32fmt = false, .n = 6, .frames = 960, .freq = 440, .start = 0, .gap = 99 }, .{ .caps = f32s, .rate = 48000, .ch = 2, .f32fmt = true, .n = 6, .frames = 960, .freq = 330, .start = 0, .gap = 99 } }, false);
    mix("gap", "audiomixer", null, &.{ .{ .caps = s16, .rate = 48000, .ch = 2, .f32fmt = false, .n = 8, .frames = 960, .freq = 440, .start = 0, .gap = 3 }, .{ .caps = s16, .rate = 48000, .ch = 2, .f32fmt = false, .n = 4, .frames = 960, .freq = 880, .start = 0, .gap = 99 } }, false);
    mix("late-start", "audiomixer", null, &.{ .{ .caps = s16, .rate = 48000, .ch = 2, .f32fmt = false, .n = 4, .frames = 960, .freq = 440, .start = 100000000, .gap = 99 } }, false);
    mix("interleave", "audiointerleave", null, &.{ .{ .caps = mono, .rate = 48000, .ch = 1, .f32fmt = false, .n = 5, .frames = 960, .freq = 440, .start = 0, .gap = 99 }, .{ .caps = mono, .rate = 48000, .ch = 1, .f32fmt = false, .n = 5, .frames = 960, .freq = 550, .start = 0, .gap = 99 } }, true);
}
