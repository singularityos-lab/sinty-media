const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);
const NOPROP = @as([*c]const u8, null);

var mutex: c.GMutex = undefined;
var calls: [64][]const u8 = undefined;
var ncalls: usize = 0;
var counter: u32 = 0;
var fail_open = false;
var spec_buf: [256]u8 = undefined;
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

fn sOpen(_: [*c]c.GstAudioSrc) callconv(.c) c.gboolean {
    note("open");
    return if (fail_open) 0 else 1;
}

fn sPrepare(_: [*c]c.GstAudioSrc, spec: [*c]c.GstAudioRingBufferSpec) callconv(.c) c.gboolean {
    note("prepare");
    spec_line = std.fmt.bufPrint(&spec_buf, "segsize {d} segtotal {d} latency {d} buffer {d} rate {d} ch {d}", .{ spec.*.segsize, spec.*.segtotal, spec.*.latency_time, spec.*.buffer_time, spec.*.info.rate, spec.*.info.channels }) catch "";
    return 1;
}

fn sUnprepare(_: [*c]c.GstAudioSrc) callconv(.c) c.gboolean {
    note("unprepare");
    return 1;
}

fn sClose(_: [*c]c.GstAudioSrc) callconv(.c) c.gboolean {
    note("close");
    return 1;
}

fn sRead(_: [*c]c.GstAudioSrc, data: c.gpointer, len: c.guint, ts: [*c]c.GstClockTime) callconv(.c) c.guint {
    const p: [*]i16 = @ptrCast(@alignCast(data));
    for (p[0 .. len / 2]) |*v| {
        v.* = @intCast(counter % 20000 + 1);
        counter += 1;
    }
    ts.* = c.GST_CLOCK_TIME_NONE;
    c.g_usleep(5000);
    return len;
}

fn sDelay(_: [*c]c.GstAudioSrc) callconv(.c) c.guint {
    return 0;
}

fn sReset(_: [*c]c.GstAudioSrc) callconv(.c) void {}

fn classInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    const k: *c.GstAudioSrcClass = @ptrCast(@alignCast(kl));
    k.open = sOpen;
    k.prepare = sPrepare;
    k.unprepare = sUnprepare;
    k.close = sClose;
    k.read = sRead;
    k.delay = sDelay;
    k.reset = sReset;
    const ek: [*c]c.GstElementClass = @ptrCast(@alignCast(kl));
    c.gst_element_class_set_static_metadata(ek, "Test src", "Source/Audio", "test", "test");
    const caps = c.gst_caps_from_string("audio/x-raw,format=S16LE,channels=[1,2],rate=[8000,48000],layout=interleaved");
    c.gst_element_class_add_pad_template(ek, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
}

fn srcType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_audio_src_get_type(), "TestAudioSrc", @sizeOf(c.GstAudioSrcClass), classInit, @sizeOf(c.GstAudioSrc), null, 0);
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

fn typeName(o: ?*anyopaque) []const u8 {
    if (o == null) return "none";
    return std.mem.span(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class.*.g_type));
}

fn run(caps_str: [*c]const u8, nbuf: usize) void {
    out("run {s}", .{caps_str});
    counter = 0;
    const pipe = c.gst_pipeline_new("p");
    const src: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(srcType(), "name", "asrc", "buffer-time", @as(i64, 100000), "latency-time", @as(i64, 10000), NONE)));
    const sink = c.gst_element_factory_make("appsink", "sink");
    const caps = c.gst_caps_from_string(caps_str);
    c.g_object_set(sink, "caps", caps, "sync", @as(c.gboolean, 0), NONE);
    c.gst_caps_unref(caps);
    _ = c.gst_bin_add(@ptrCast(pipe), src);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    _ = c.gst_element_link(src, sink);
    out("  to playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    var expect: u32 = 0;
    var i: usize = 0;
    var contiguous = true;
    while (i < nbuf) : (i += 1) {
        var sample: ?*c.GstSample = null;
        c.g_signal_emit_by_name(sink, "pull-sample", &sample);
        if (sample == null) {
            out("  no sample", .{});
            break;
        }
        const b = c.gst_sample_get_buffer(sample);
        if (i == 0) {
            const sc = c.gst_sample_get_caps(sample);
            const s = c.gst_caps_to_string(sc);
            out("  caps {s}", .{s});
            c.g_free(s);
        }
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        const p: [*]const i16 = @ptrCast(@alignCast(map.data));
        if (i == 0) expect = @intCast(p[0] - 1);
        for (p[0 .. map.size / 2]) |v| {
            if (v != @as(i16, @intCast(expect % 20000 + 1))) contiguous = false;
            expect += 1;
        }
        out("  buf {d} size {d} offset {d} end {d} dur {d} pts-valid {d} discont {d}", .{ i, map.size, b.*.offset -% b.*.offset, b.*.offset_end -% b.*.offset, b.*.duration, @intFromBool(b.*.pts != c.GST_CLOCK_TIME_NONE), @intFromBool(b.*.mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) });
        c.gst_buffer_unmap(b, &map);
        c.gst_sample_unref(sample);
    }
    out("  contiguous {d}", .{@intFromBool(contiguous)});
    var abt: i64 = 0;
    var alt: i64 = 0;
    c.g_object_get(src, "actual-buffer-time", &abt, "actual-latency-time", &alt, NONE);
    out("  actual buffer {d} latency {d}", .{ abt, alt });
    const lat = c.gst_query_new_latency();
    if (c.gst_element_query(src, lat) != 0) {
        var live: c.gboolean = 0;
        var mn: c.GstClockTime = 0;
        var mx: c.GstClockTime = 0;
        c.gst_query_parse_latency(lat, &live, &mn, &mx);
        out("  latency live {d} min {d} max {d}", .{ live, mn, mx });
    } else out("  latency query failed", .{});
    c.gst_query_unref(lat);
    const sq = c.gst_query_new_scheduling();
    const pad = c.gst_element_get_static_pad(src, "src");
    out("  scheduling {d} modes {d} pull {d}", .{ c.gst_pad_query(pad, sq), c.gst_query_get_n_scheduling_modes(sq), c.gst_query_has_scheduling_mode(sq, c.GST_PAD_MODE_PULL) });
    c.gst_query_unref(sq);
    const seek = c.gst_event_new_seek(1.0, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 0, c.GST_SEEK_TYPE_NONE, 0);
    out("  seek {d}", .{c.gst_element_send_event(src, seek)});
    c.gst_object_unref(pad);
    const clk = c.gst_element_provide_clock(src);
    out("  provides clock {s} pipeline clock is src {d}", .{ typeName(clk), @intFromBool(c.gst_pipeline_get_clock(@ptrCast(pipe)) == clk) });
    if (clk != null) c.gst_object_unref(clk);
    out("  to null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    flushCalls();
    c.gst_object_unref(pipe);
}

pub fn main() void {
    c.g_mutex_init(&mutex);
    c.gst_init(null, null);
    chain(srcType());
    chain(c.gst_audio_base_src_get_type());
    const s = c.g_object_new(srcType(), NOPROP).?;
    props(s);
    const bs: [*c]c.GstAudioBaseSrc = @ptrCast(@alignCast(s));
    c.gst_audio_base_src_set_provide_clock(bs, 0);
    c.gst_audio_base_src_set_slave_method(bs, c.GST_AUDIO_BASE_SRC_SLAVE_RE_TIMESTAMP);
    out("getters clock {d} slave {d}", .{ c.gst_audio_base_src_get_provide_clock(bs), c.gst_audio_base_src_get_slave_method(bs) });
    out("live {d} format {d} blocksize {d}", .{ c.gst_base_src_is_live(@ptrCast(bs)), @as(*c.GstBaseSrc, @ptrCast(@alignCast(s))).segment.format, c.gst_base_src_get_blocksize(@ptrCast(bs)) });
    const r = c.gst_audio_base_src_create_ringbuffer(bs);
    out("ringbuffer {s} parent set {d}", .{ typeName(r), @intFromBool(@as([*c]c.GstObject, @ptrCast(r)).*.parent == @as([*c]c.GstObject, @ptrCast(bs))) });
    c.gst_object_unparent(@ptrCast(r));
    c.gst_object_unref(s);
    run("audio/x-raw,format=S16LE,channels=2,rate=44100", 12);
    run("audio/x-raw,format=S16LE,channels=1,rate=16000", 8);
    fail_open = true;
    out("failing open", .{});
    const src: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(srcType(), "name", "asrc", NONE)));
    _ = c.gst_object_ref_sink(src);
    out("  to ready {d}", .{c.gst_element_set_state(src, c.GST_STATE_READY)});
    _ = c.gst_element_set_state(src, c.GST_STATE_NULL);
    flushCalls();
    c.gst_object_unref(src);
}
