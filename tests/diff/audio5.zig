const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn hash(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

var log: [4096]u8 = undefined;
var log_len: usize = 0;

fn note(s: []const u8) void {
    @memcpy(log[log_len..][0..s.len], s);
    log_len += s.len;
    log[log_len] = ' ';
    log_len += 1;
}

fn flushLog() void {
    out("  calls: {s}", .{log[0..log_len]});
    log_len = 0;
}

var fail_acquire = false;

fn openDevice(_: [*c]c.GstAudioRingBuffer) callconv(.c) c.gboolean {
    note("open");
    return 1;
}

fn closeDevice(_: [*c]c.GstAudioRingBuffer) callconv(.c) c.gboolean {
    note("close");
    return 1;
}

fn acquire(b: [*c]c.GstAudioRingBuffer, spec: [*c]c.GstAudioRingBufferSpec) callconv(.c) c.gboolean {
    note("acquire");
    if (fail_acquire) return 0;
    b.*.spec = spec.*;
    _ = c.gst_caps_ref(spec.*.caps);
    b.*.size = @intCast(spec.*.segtotal * spec.*.segsize);
    b.*.memory = @ptrCast(c.g_malloc0(@intCast(b.*.size)));
    return 1;
}

fn release(b: [*c]c.GstAudioRingBuffer) callconv(.c) c.gboolean {
    note("release");
    c.g_free(b.*.memory);
    b.*.memory = null;
    return 1;
}

fn start(_: [*c]c.GstAudioRingBuffer) callconv(.c) c.gboolean {
    note("start");
    return 1;
}

fn pausef(_: [*c]c.GstAudioRingBuffer) callconv(.c) c.gboolean {
    note("pause");
    return 1;
}

fn resumef(_: [*c]c.GstAudioRingBuffer) callconv(.c) c.gboolean {
    note("resume");
    return 1;
}

fn stop(_: [*c]c.GstAudioRingBuffer) callconv(.c) c.gboolean {
    note("stop");
    return 1;
}

fn delay(_: [*c]c.GstAudioRingBuffer) callconv(.c) c.guint {
    return 42;
}

fn activate(_: [*c]c.GstAudioRingBuffer, a: c.gboolean) callconv(.c) c.gboolean {
    note(if (a != 0) "activate1" else "activate0");
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const rc: *c.GstAudioRingBufferClass = @ptrCast(@alignCast(k));
    rc.open_device = openDevice;
    rc.close_device = closeDevice;
    rc.acquire = acquire;
    rc.release = release;
    rc.start = start;
    rc.pause = pausef;
    rc.@"resume" = resumef;
    rc.stop = stop;
    rc.delay = delay;
    rc.activate = activate;
}

fn showSpec(label: []const u8, s: *c.GstAudioRingBufferSpec) void {
    out("  {s} type={d} segsize={d} segtotal={d} seglat={d} rate={d} ch={d} bpf={d} fmt={s}", .{ label, s.type, s.segsize, s.segtotal, s.seglatency, s.info.rate, s.info.channels, s.info.bpf, if (s.info.finfo != null) std.mem.span(s.info.finfo.*.name) else "-" });
}

fn parseCaps() void {
    out("parse caps", .{});
    const list = [_][*:0]const u8{
        "audio/x-raw,format=S16LE,layout=interleaved,rate=44100,channels=2",
        "audio/x-raw,format=F32LE,layout=interleaved,rate=48000,channels=6,channel-mask=(bitmask)0x3f",
        "audio/x-raw,format=S16LE,rate=44100,channels=2",
        "audio/x-alaw,rate=8000,channels=1",
        "audio/x-mulaw,rate=8000,channels=2",
        "audio/x-mulaw,rate=8000,channels=5",
        "audio/x-iec958,rate=48000",
        "audio/x-ac3,rate=48000,channels=6",
        "audio/x-eac3,rate=48000",
        "audio/x-dts,rate=48000,channels=2",
        "audio/mpeg,mpegaudioversion=1,rate=44100,channels=2",
        "audio/mpeg,mpegversion=4,stream-format=adts,rate=44100,channels=2",
        "audio/mpeg,mpegversion=2,stream-format=raw,rate=44100",
        "audio/mpeg,mpegversion=4,stream-format=loas,rate=44100",
        "audio/x-flac,rate=96000,channels=2",
        "audio/x-dsd,format=DSDU32BE,rate=352800,channels=2",
        "audio/x-ac3",
        "video/x-raw",
    };
    for (list) |cs| {
        var spec = std.mem.zeroes(c.GstAudioRingBufferSpec);
        spec.latency_time = 10000;
        spec.buffer_time = 200000;
        const caps = c.gst_caps_from_string(cs);
        const r = c.gst_audio_ring_buffer_parse_caps(&spec, caps);
        out("  {s} -> {d}", .{ cs, r });
        if (r != 0) showSpec("   ", &spec);
        if (spec.caps != null) c.gst_caps_unref(spec.caps);
        c.gst_caps_unref(caps);
    }
    var spec = std.mem.zeroes(c.GstAudioRingBufferSpec);
    const caps = c.gst_caps_from_string("audio/x-raw,format=S16LE,layout=interleaved,rate=44100,channels=2");
    out("  zero latency {d}", .{c.gst_audio_ring_buffer_parse_caps(&spec, caps)});
    if (spec.caps != null) c.gst_caps_unref(spec.caps);
    c.gst_caps_unref(caps);
}

fn mkbuf(t: c.GType, caps_str: [*:0]const u8, spec: *c.GstAudioRingBufferSpec) [*c]c.GstAudioRingBuffer {
    const b: [*c]c.GstAudioRingBuffer = @ptrCast(@alignCast(c.g_object_new(t, null)));
    spec.* = std.mem.zeroes(c.GstAudioRingBufferSpec);
    spec.latency_time = 10000;
    spec.buffer_time = 200000;
    const caps = c.gst_caps_from_string(caps_str);
    _ = c.gst_audio_ring_buffer_parse_caps(spec, caps);
    c.gst_caps_unref(caps);
    return b;
}

fn mem(b: [*c]c.GstAudioRingBuffer) u64 {
    return hash(@as([*]u8, @ptrCast(b.*.memory))[0..@intCast(b.*.size)]);
}

fn lifecycle(t: c.GType) void {
    out("lifecycle", .{});
    var spec: c.GstAudioRingBufferSpec = undefined;
    const b = mkbuf(t, "audio/x-raw,format=S16LE,layout=interleaved,rate=8000,channels=2", &spec);
    out("  type {s} flushing {d} open {d} acquired {d} active {d} state {d}", .{ std.mem.span(c.g_type_name(c.gst_audio_ring_buffer_get_type())), c.gst_audio_ring_buffer_is_flushing(b), c.gst_audio_ring_buffer_device_is_open(b), c.gst_audio_ring_buffer_is_acquired(b), c.gst_audio_ring_buffer_is_active(b), b.*.state });
    out("  acquire closed {d}", .{c.gst_audio_ring_buffer_acquire(b, &spec)});
    out("  open {d} again {d}", .{ c.gst_audio_ring_buffer_open_device(b), c.gst_audio_ring_buffer_open_device(b) });
    fail_acquire = true;
    out("  acquire fail {d} acquired {d}", .{ c.gst_audio_ring_buffer_acquire(b, &spec), b.*.acquired });
    fail_acquire = false;
    out("  activate unacquired {d}", .{c.gst_audio_ring_buffer_activate(b, 1)});
    out("  acquire {d} again {d} sps {d} empty {x}", .{ c.gst_audio_ring_buffer_acquire(b, &spec), c.gst_audio_ring_buffer_acquire(b, &spec), b.*.samples_per_seg, hash(@as([*]u8, @ptrCast(b.*.empty_seg))[0..@intCast(spec.segsize)]) });
    out("  close acquired {d}", .{c.gst_audio_ring_buffer_close_device(b)});
    out("  activate {d} {d} active {d} delay {d}", .{ c.gst_audio_ring_buffer_activate(b, 1), c.gst_audio_ring_buffer_activate(b, 1), c.gst_audio_ring_buffer_is_active(b), c.gst_audio_ring_buffer_delay(b) });
    out("  start flushing {d}", .{c.gst_audio_ring_buffer_start(b)});
    c.gst_audio_ring_buffer_set_flushing(b, 0);
    out("  start no may {d}", .{c.gst_audio_ring_buffer_start(b)});
    c.gst_audio_ring_buffer_may_start(b, 1);
    out("  start {d} state {d} again {d}", .{ c.gst_audio_ring_buffer_start(b), b.*.state, c.gst_audio_ring_buffer_start(b) });
    out("  pause {d} state {d} resume {d} state {d}", .{ c.gst_audio_ring_buffer_pause(b), b.*.state, c.gst_audio_ring_buffer_start(b), b.*.state });
    c.gst_audio_ring_buffer_set_errored(b);
    out("  errored state {d} stop {d} state {d} stop again {d}", .{ b.*.state, c.gst_audio_ring_buffer_stop(b), b.*.state, c.gst_audio_ring_buffer_stop(b) });
    var dv: i64 = 0;
    out("  convert {d} {d}", .{ c.gst_audio_ring_buffer_convert(b, c.GST_FORMAT_BYTES, 4000, c.GST_FORMAT_TIME, &dv), dv });
    flushLog();
    var sample: u64 = 0;
    var accum: c_int = 0;
    var data: [4000]u8 = undefined;
    for (&data, 0..) |*x, i| x.* = @truncate(i * 13 + 1);
    out("  commit fwd {d} sample {d} mem {x}", .{ c.gst_audio_ring_buffer_commit(b, &sample, &data, 100, 100, &accum), sample, mem(b) });
    accum = 0;
    out("  commit up {d} sample {d} accum {d} mem {x}", .{ c.gst_audio_ring_buffer_commit(b, &sample, &data, 100, 37, &accum), sample, accum, mem(b) });
    accum = 0;
    out("  commit down {d} sample {d} accum {d} mem {x}", .{ c.gst_audio_ring_buffer_commit(b, &sample, &data, 21, 60, &accum), sample, accum, mem(b) });
    accum = 0;
    out("  commit rev up {d} sample {d} accum {d} mem {x}", .{ c.gst_audio_ring_buffer_commit(b, &sample, &data, 50, -30, &accum), sample, accum, mem(b) });
    accum = 0;
    out("  commit rev down {d} sample {d} accum {d} mem {x}", .{ c.gst_audio_ring_buffer_commit(b, &sample, &data, 30, -45, &accum), sample, accum, mem(b) });
    out("  commit zero {d}", .{c.gst_audio_ring_buffer_commit(b, &sample, &data, 0, 5, &accum)});
    c.gst_audio_ring_buffer_advance(b, 2);
    out("  advance segdone {d} samples done {d} segbase {d}", .{ c.gst_audio_ring_buffer_get_segdone(b), c.gst_audio_ring_buffer_samples_done(b), c.gst_audio_ring_buffer_get_segbase(b) });
    var rd: [800]u8 = undefined;
    var ts: u64 = 0;
    c.gst_audio_ring_buffer_set_timestamp(b, 0, 12345);
    out("  read {d} ts {d} {x}", .{ c.gst_audio_ring_buffer_read(b, 0, &rd, 40, &ts), ts, hash(rd[0..160]) });
    c.gst_audio_ring_buffer_set_segdone(b, 20);
    out("  read old {d} {x}", .{ c.gst_audio_ring_buffer_read(b, 0, &rd, 20, null), hash(rd[0..80]) });
    c.gst_audio_ring_buffer_set_sample(b, 16);
    out("  set sample segbase {d} {d} mem {x}", .{ c.gst_audio_ring_buffer_get_segbase(b), b.*.segbase, mem(b) });
    c.gst_audio_ring_buffer_set_sample(b, std.math.maxInt(u64));
    var seg: c_int = 0;
    var rp: [*c]u8 = null;
    var len: c_int = 0;
    out("  prepare read stopped {d}", .{c.gst_audio_ring_buffer_prepare_read(b, &seg, &rp, &len)});
    _ = c.gst_audio_ring_buffer_start(b);
    out("  prepare read {d} seg {d} len {d} off {d}", .{ c.gst_audio_ring_buffer_prepare_read(b, &seg, &rp, &len), seg, len, @intFromPtr(rp) - @intFromPtr(b.*.memory) });
    c.gst_audio_ring_buffer_clear(b, 9);
    c.gst_audio_ring_buffer_clear_all(b);
    out("  cleared mem {x}", .{mem(b)});
    var swapped = [_]c.GstAudioChannelPosition{ c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT, c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT };
    c.gst_audio_ring_buffer_set_channel_positions(b, &swapped);
    out("  reorder {d} map {any}", .{ b.*.need_reorder, b.*.channel_reorder_map[0..2] });
    sample = 0;
    c.gst_audio_ring_buffer_set_segdone(b, 0);
    c.gst_audio_ring_buffer_set_sample(b, 0);
    out("  commit reorder {d} mem {x}", .{ c.gst_audio_ring_buffer_commit(b, &sample, &data, 50, 50, &accum), mem(b) });
    accum = 0;
    out("  commit reorder up {d} mem {x}", .{ c.gst_audio_ring_buffer_commit(b, &sample, &data, 20, 13, &accum), mem(b) });
    c.gst_audio_ring_buffer_advance(b, 1);
    out("  read reorder {d} {x}", .{ c.gst_audio_ring_buffer_read(b, 0, &rd, 8, null), hash(rd[0..32]) });
    var nonepos = [_]c.GstAudioChannelPosition{ c.GST_AUDIO_CHANNEL_POSITION_NONE, c.GST_AUDIO_CHANNEL_POSITION_NONE };
    c.gst_audio_ring_buffer_set_channel_positions(b, &nonepos);
    out("  none reorder {d}", .{b.*.need_reorder});
    var bad = [_]c.GstAudioChannelPosition{ c.GST_AUDIO_CHANNEL_POSITION_REAR_LEFT, c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT };
    c.gst_audio_ring_buffer_set_channel_positions(b, &bad);
    var cbcount: c_int = 0;
    c.gst_audio_ring_buffer_set_callback(b, struct {
        fn f(_: [*c]c.GstAudioRingBuffer, _: [*c]u8, l: c.guint, ud: c.gpointer) callconv(.c) void {
            @as(*c_int, @ptrCast(@alignCast(ud))).* += @intCast(l);
        }
    }.f, &cbcount);
    _ = c.gst_audio_ring_buffer_stop(b);
    out("  prepare read cb {d} count {d}", .{ c.gst_audio_ring_buffer_prepare_read(b, &seg, &rp, &len), cbcount });
    out("  activate off {d} release {d} released {d} close {d}", .{ c.gst_audio_ring_buffer_activate(b, 0), c.gst_audio_ring_buffer_release(b), c.gst_audio_ring_buffer_release(b), c.gst_audio_ring_buffer_close_device(b) });
    out("  close again {d}", .{c.gst_audio_ring_buffer_close_device(b)});
    flushLog();
    if (spec.caps != null) c.gst_caps_unref(spec.caps);
    c.gst_object_unref(b);
    var spec2: c.GstAudioRingBufferSpec = undefined;
    const d = mkbuf(t, "audio/x-dsd,format=DSDU8,rate=2822400,channels=1", &spec2);
    _ = c.gst_audio_ring_buffer_open_device(d);
    out("  dsd acquire {d} empty {x}", .{ c.gst_audio_ring_buffer_acquire(d, &spec2), @as([*]u8, @ptrCast(d.*.empty_seg))[0] });
    _ = c.gst_audio_ring_buffer_release(d);
    if (spec2.caps != null) c.gst_caps_unref(spec2.caps);
    c.gst_object_unref(d);
    flushLog();
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    parseCaps();
    const t = c.g_type_register_static_simple(c.gst_audio_ring_buffer_get_type(), "TestRing", @sizeOf(c.GstAudioRingBufferClass), classInit, @sizeOf(c.GstAudioRingBuffer), null, 0);
    lifecycle(t);
}
