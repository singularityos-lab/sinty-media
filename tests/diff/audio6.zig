const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

extern fn gst_g_thread_get_type() c.GType;

const FRAMES = 4410;
const BUFFERS = 6;

var mutex: c.GMutex = undefined;
var calls: [64][]const u8 = undefined;
var ncalls: usize = 0;
var samples: [FRAMES * BUFFERS * 2 + 64]i16 = undefined;
var nsamples: usize = 0;
var fail_prepare = false;
var spec_buf: [256]u8 = undefined;
var status_ok: u32 = 0;
var spec_line: []const u8 = "";

fn note(s: []const u8) void {
    c.g_mutex_lock(&mutex);
    if (ncalls < calls.len) {
        calls[ncalls] = s;
        ncalls += 1;
    }
    c.g_mutex_unlock(&mutex);
}

fn flushCalls() void {
    var buf: [2048]u8 = undefined;
    var n: usize = 0;
    for (calls[0..ncalls]) |s| {
        @memcpy(buf[n..][0..s.len], s);
        n += s.len;
        buf[n] = ' ';
        n += 1;
    }
    out("  calls: {s}", .{buf[0..n]});
    out("  spec: {s}", .{spec_line});
    spec_line = "";
    ncalls = 0;
}

fn sOpen(_: [*c]c.GstAudioSink) callconv(.c) c.gboolean {
    note("open");
    return 1;
}

fn sPrepare(_: [*c]c.GstAudioSink, spec: [*c]c.GstAudioRingBufferSpec) callconv(.c) c.gboolean {
    note("prepare");
    spec_line = std.fmt.bufPrint(&spec_buf, "segsize {d} segtotal {d} latency {d} buffer {d} rate {d} ch {d}", .{ spec.*.segsize, spec.*.segtotal, spec.*.latency_time, spec.*.buffer_time, spec.*.info.rate, spec.*.info.channels }) catch "";
    return if (fail_prepare) 0 else 1;
}

fn sUnprepare(_: [*c]c.GstAudioSink) callconv(.c) c.gboolean {
    note("unprepare");
    return 1;
}

fn sClose(_: [*c]c.GstAudioSink) callconv(.c) c.gboolean {
    note("close");
    return 1;
}

fn sWrite(_: [*c]c.GstAudioSink, data: c.gpointer, len: c.guint) callconv(.c) c.gint {
    const p: [*]const i16 = @ptrCast(@alignCast(data));
    c.g_mutex_lock(&mutex);
    for (p[0 .. len / 2]) |v| {
        if (v != 0 and nsamples < samples.len) {
            samples[nsamples] = v;
            nsamples += 1;
        }
    }
    c.g_mutex_unlock(&mutex);
    c.g_usleep(2000);
    return @intCast(len);
}

fn sDelay(_: [*c]c.GstAudioSink) callconv(.c) c.guint {
    return 0;
}

fn sReset(_: [*c]c.GstAudioSink) callconv(.c) void {}

fn classInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    const k: *c.GstAudioSinkClass = @ptrCast(@alignCast(kl));
    k.open = sOpen;
    k.prepare = sPrepare;
    k.unprepare = sUnprepare;
    k.close = sClose;
    k.write = sWrite;
    k.delay = sDelay;
    k.reset = sReset;
    const ek: [*c]c.GstElementClass = @ptrCast(@alignCast(kl));
    c.gst_element_class_set_static_metadata(ek, "Test sink", "Sink/Audio", "test", "test");
    const caps = c.gst_caps_from_string("audio/x-raw,format=S16LE,channels=2,rate=44100,layout=interleaved");
    c.gst_element_class_add_pad_template(ek, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
}

fn sinkType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_audio_sink_get_type(), "TestAudioSink", @sizeOf(c.GstAudioSinkClass), classInit, @sizeOf(c.GstAudioSink), null, 0);
    return S.t;
}

fn chain(t: c.GType) void {
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    var x = t;
    while (x != 0) : (x = c.g_type_parent(x)) {
        const s = std.mem.span(c.g_type_name(x));
        @memcpy(buf[n..][0..s.len], s);
        n += s.len;
        buf[n] = ' ';
        n += 1;
    }
    out("chain {s} abstract {d}", .{ buf[0..n], @intFromBool(c.g_type_test_flags(t, c.G_TYPE_FLAG_ABSTRACT) != 0) });
}

fn props(obj: *anyopaque) void {
    var n: c.guint = 0;
    const ps = c.g_object_class_list_properties(@ptrCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(obj))).g_class), &n);
    for (ps[0..n]) |p| {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, p.*.value_type);
        c.g_object_get_property(@ptrCast(@alignCast(obj)), p.*.name, &v);
        const s = c.g_strdup_value_contents(&v);
        out("  prop {s} owner {s} flags {d} = {s}", .{ p.*.name, c.g_type_name(p.*.owner_type), p.*.flags, s });
        c.g_free(s);
        c.g_value_unset(&v);
    }
    c.g_free(@ptrCast(ps));
}

fn busDrain(pipe: [*c]c.GstElement, sink: [*c]c.GstElement, until: c.GstMessageType) void {
    const bus = c.gst_element_get_bus(pipe);
    var enter: u32 = 0;
    var leave: u32 = 0;
    while (true) {
        const m = c.gst_bus_timed_pop(bus, 5 * c.GST_SECOND) orelse {
            out("  bus timeout", .{});
            break;
        };
        const t = m.*.type;
        const fromSink = m.*.src == @as([*c]c.GstObject, @ptrCast(sink));
        if (t == c.GST_MESSAGE_STATE_CHANGED and fromSink) {
            var o: c.GstState = 0;
            var nw: c.GstState = 0;
            c.gst_message_parse_state_changed(m, &o, &nw, null);
            out("  sink state {s} -> {s}", .{ c.gst_element_state_get_name(o), c.gst_element_state_get_name(nw) });
        } else if (t == c.GST_MESSAGE_STREAM_STATUS) {
            var st: c.GstStreamStatusType = 0;
            var owner: [*c]c.GstElement = null;
            c.gst_message_parse_stream_status(m, &st, &owner);
            if (owner == sink) {
                const v = c.gst_message_get_stream_status_object(m);
                if (std.mem.eql(u8, std.mem.span(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(m.*.src))).g_class.*.g_type)), "GstAudioSinkRingBuffer") and v != null and v.*.g_type == gst_g_thread_get_type()) status_ok += 1;
                if (st == c.GST_STREAM_STATUS_TYPE_ENTER) enter += 1;
                if (st == c.GST_STREAM_STATUS_TYPE_LEAVE) leave += 1;
            }
        } else if (t == c.GST_MESSAGE_ERROR) {
            var e: [*c]c.GError = null;
            c.gst_message_parse_error(m, &e, null);
            out("  error {s}", .{e.*.message});
            c.g_error_free(e);
        } else if (t == c.GST_MESSAGE_EOS) {
            out("  eos", .{});
        } else if (t == c.GST_MESSAGE_ASYNC_DONE) {
            out("  async-done", .{});
        }
        const done = (t & until) != 0;
        c.gst_message_unref(m);
        if (done or t == c.GST_MESSAGE_ERROR) break;
    }
    c.gst_object_unref(bus);
    _ = .{ enter, leave };
}

fn run(sync: bool, slave: c_int) void {
    out("run sync {d} slave {d}", .{ @intFromBool(sync), slave });
    nsamples = 0;
    const pipe = c.gst_pipeline_new("p");
    const src = c.gst_element_factory_make("appsrc", "src");
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "snk", "sync", @as(c.gboolean, @intFromBool(sync)), "slave-method", slave, "buffer-time", @as(i64, 200000), "latency-time", @as(i64, 10000), NONE)));
    const caps = c.gst_caps_from_string("audio/x-raw,format=S16LE,channels=2,rate=44100,layout=interleaved");
    c.g_object_set(src, "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
    c.gst_caps_unref(caps);
    _ = c.gst_bin_add(@ptrCast(pipe), src);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    _ = c.gst_element_link(src, sink);
    out("  to paused {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PAUSED)});
    var i: usize = 0;
    var expect: u64 = 0xcbf29ce484222325;
    while (i < BUFFERS) : (i += 1) {
        const b = c.gst_buffer_new_allocate(null, FRAMES * 4, null);
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
        const p: [*]i16 = @ptrCast(@alignCast(map.data));
        for (0..FRAMES * 2) |k| {
            const v: i16 = @intCast(100 + @as(i32, @intCast((k + i * 7) % 3000)));
            p[k] = v;
            expect = (expect ^ @as(u16, @bitCast(v))) *% 0x100000001b3;
        }
        c.gst_buffer_unmap(b, &map);
        b.*.pts = i * 100 * c.GST_MSECOND;
        b.*.duration = 100 * c.GST_MSECOND;
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
        c.gst_buffer_unref(b);
    }
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    busDrain(pipe, sink, c.GST_MESSAGE_ASYNC_DONE);
    var lat = c.gst_query_new_latency();
    if (c.gst_element_query(sink, lat) != 0) {
        var live: c.gboolean = 0;
        var mn: c.GstClockTime = 0;
        var mx: c.GstClockTime = 0;
        c.gst_query_parse_latency(lat, &live, &mn, &mx);
        out("  latency live {d} min {d} max {d}", .{ live, mn, mx });
    } else out("  latency query failed", .{});
    c.gst_query_unref(lat);
    const clk = c.gst_element_provide_clock(sink);
    out("  provides clock {s}", .{if (clk != null) std.mem.span(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(clk))).g_class.*.g_type)) else "none"});
    if (clk != null) c.gst_object_unref(clk);
    out("  to playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    busDrain(pipe, sink, c.GST_MESSAGE_EOS);
    out("  to null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    out("  thread stream-status seen {d}", .{@intFromBool(status_ok > 0)});
    status_ok = 0;
    c.g_mutex_lock(&mutex);
    var h: u64 = 0xcbf29ce484222325;
    for (samples[0..nsamples]) |v| h = (h ^ @as(u16, @bitCast(v))) *% 0x100000001b3;
    out("  samples {d} expect {d} hash match {d}", .{ nsamples, FRAMES * BUFFERS * 2, @intFromBool(h == expect) });
    c.g_mutex_unlock(&mutex);
    flushCalls();
    lat = null;
    c.gst_object_unref(pipe);
}

pub fn main() void {
    c.g_mutex_init(&mutex);
    c.gst_init(null, null);
    chain(sinkType());
    chain(c.gst_audio_base_sink_get_type());
    const s = c.g_object_new(sinkType(), @as([*c]const u8, null)).?;
    props(s);
    const bs: [*c]c.GstAudioBaseSink = @ptrCast(@alignCast(s));
    c.gst_audio_base_sink_set_provide_clock(bs, 0);
    c.gst_audio_base_sink_set_slave_method(bs, c.GST_AUDIO_BASE_SINK_SLAVE_SKEW);
    c.gst_audio_base_sink_set_alignment_threshold(bs, 10 * c.GST_MSECOND);
    c.gst_audio_base_sink_set_discont_wait(bs, 2 * c.GST_SECOND);
    c.gst_audio_base_sink_set_drift_tolerance(bs, 12345);
    out("getters clock {d} slave {d} align {d} discont {d} drift {d}", .{ c.gst_audio_base_sink_get_provide_clock(bs), c.gst_audio_base_sink_get_slave_method(bs), c.gst_audio_base_sink_get_alignment_threshold(bs), c.gst_audio_base_sink_get_discont_wait(bs), c.gst_audio_base_sink_get_drift_tolerance(bs) });
    props(s);
    const r = c.gst_audio_base_sink_create_ringbuffer(bs);
    out("ringbuffer {s} parent set {d}", .{ c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(r))).g_class.*.g_type), @intFromBool(@as([*c]c.GstObject, @ptrCast(r)).*.parent == @as([*c]c.GstObject, @ptrCast(bs))) });
    c.gst_object_unref(s);
    run(false, c.GST_AUDIO_BASE_SINK_SLAVE_SKEW);
    run(true, c.GST_AUDIO_BASE_SINK_SLAVE_SKEW);
    run(true, c.GST_AUDIO_BASE_SINK_SLAVE_NONE);
    fail_prepare = true;
    out("failing prepare", .{});
    const pipe = c.gst_pipeline_new("p");
    const src = c.gst_element_factory_make("appsrc", "src");
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "snk", NONE)));
    const caps = c.gst_caps_from_string("audio/x-raw,format=S16LE,channels=2,rate=44100,layout=interleaved");
    c.g_object_set(src, "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
    c.gst_caps_unref(caps);
    _ = c.gst_bin_add(@ptrCast(pipe), src);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    _ = c.gst_element_link(src, sink);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_PLAYING);
    const b = c.gst_buffer_new_allocate(null, 400, null);
    _ = c.gst_buffer_memset(b, 0, 1, 400);
    b.*.pts = 0;
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
    c.gst_buffer_unref(b);
    busDrain(pipe, sink, c.GST_MESSAGE_ERROR);
    out("  to null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    flushCalls();
    c.gst_object_unref(pipe);
}
