const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const MS: u64 = 1000000;

var count: usize = 0;

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, _: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    const flags = @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags;
    if (count < 60) out("  buf pts {d} dur {d} off {d}/{d} flags {x}", .{ @as(i64, @bitCast(b.*.pts)), @as(i64, @bitCast(b.*.duration)), @as(i64, @bitCast(b.*.offset)), @as(i64, @bitCast(b.*.offset_end)), flags & (c.GST_BUFFER_FLAG_DISCONT | c.GST_BUFFER_FLAG_GAP) });
    count += 1;
}

fn drain(p: ?*c.GstElement) void {
    const bus = c.gst_element_get_bus(p);
    defer c.gst_object_unref(bus);
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 10 * @as(u64, c.GST_SECOND), c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
        if (m == null) {
            out("  timeout", .{});
            return;
        }
        defer c.gst_message_unref(m);
        if (m.*.type == c.GST_MESSAGE_ERROR) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &e, &dbg);
            const d = z(dbg);
            const cut = if (std.mem.indexOf(u8, d, ": /")) |i| d[0..i] else d;
            out("  error {s} {d} [{s}] [{s}]", .{ z(c.g_quark_to_string(e.*.domain)), e.*.code, z(e.*.message), cut });
            c.g_error_free(e);
            c.g_free(dbg);
        } else out("  eos", .{});
        return;
    }
}

fn counters(rate: ?*c.GstElement) void {
    var in: u64 = 0;
    var o: u64 = 0;
    var dup: u64 = 0;
    var drop: u64 = 0;
    c.g_object_get(rate, "in", &in, "out", &o, "duplicate", &dup, "drop", &drop, @as(?*anyopaque, null));
    out("  in {d} out {d} dup {d} drop {d} total {d}", .{ in, o, dup, drop, count });
}

fn negotiated(p: ?*c.GstElement) void {
    const rate = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "rate");
    defer c.gst_object_unref(rate);
    const pad = c.gst_element_get_static_pad(rate, "src");
    defer c.gst_object_unref(pad);
    const caps = c.gst_pad_get_current_caps(pad);
    if (caps != null) {
        const s = c.gst_caps_to_string(caps);
        out("  src caps {s}", .{z(s)});
        c.g_free(s);
        c.gst_caps_unref(caps);
    }
}

fn run(desc: [:0]const u8) void {
    out("run {s}", .{desc});
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const sink = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    count = 0;
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    drain(p);
    negotiated(p);
    const rate = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "rate");
    counters(rate);
    var pos: i64 = 0;
    out("  position {d} {d}", .{ c.gst_element_query_position(rate, c.GST_FORMAT_TIME, &pos), pos });
    c.gst_object_unref(rate);
    c.gst_object_unref(sink);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

const Push = struct { pts: u64, dur: u64 };

fn pushed(desc: [:0]const u8, caps: [:0]const u8, bufs: []const Push) void {
    out("push {s} caps {s}", .{ desc, caps });
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const src = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "src");
    const sink = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    const cp = c.gst_caps_from_string(caps.ptr);
    c.g_object_set(src, "caps", cp, "format", @as(c.gint, c.GST_FORMAT_TIME), @as(?*anyopaque, null));
    c.gst_caps_unref(cp);
    count = 0;
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    for (bufs) |b| {
        const buf = c.gst_buffer_new_allocate(null, 64, null);
        _ = c.gst_buffer_memset(buf, 0, @truncate(b.pts / MS), 64);
        buf.*.pts = b.pts;
        buf.*.duration = b.dur;
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", buf, &ret);
        c.gst_buffer_unref(buf);
    }
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    drain(p);
    negotiated(p);
    const rate = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "rate");
    counters(rate);
    c.gst_object_unref(rate);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

fn capsCheck(desc: [:0]const u8) void {
    out("caps {s}", .{desc});
    const e = c.gst_element_factory_make("videorate", null);
    defer c.gst_object_unref(e);
    c.gst_util_set_object_arg(@ptrCast(e), "drop-only", if (std.mem.indexOf(u8, desc, "drop") != null) "true" else "false");
    if (std.mem.indexOf(u8, desc, "max5") != null) c.g_object_set(e, "max-rate", @as(c.gint, 5), @as(?*anyopaque, null));
    const caps = c.gst_caps_from_string("video/x-raw,format=I420,width=16,height=16,framerate=30/1;video/x-raw,format=GRAY8,framerate=[1/1,60/1];image/jpeg");
    defer c.gst_caps_unref(caps);
    for ([_][*c]const u8{ "sink", "src" }) |name| {
        const pad = c.gst_element_get_static_pad(e, name);
        defer c.gst_object_unref(pad);
        const q = c.gst_query_new_caps(caps);
        _ = c.gst_pad_peer_query(pad, q);
        const peer_caps = c.gst_pad_query_caps(pad, caps);
        const s = c.gst_caps_to_string(peer_caps);
        out("  {s} query {s}", .{ z(name), z(s) });
        c.g_free(s);
        c.gst_caps_unref(peer_caps);
        c.gst_query_unref(q);
    }
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("videorate");
    const base = "videotestsrc num-buffers=30 pattern=black ! video/x-raw,format=GRAY8,width=16,height=16,framerate=30/1 ! videorate name=rate";
    const list = [_][:0]const u8{
        base ++ " ! video/x-raw,framerate=10/1 ! fakesink name=sink signal-handoffs=true",
        base ++ " ! video/x-raw,framerate=25/1 ! fakesink name=sink signal-handoffs=true",
        base ++ " ! video/x-raw,framerate=60/1 ! fakesink name=sink signal-handoffs=true",
        base ++ " ! video/x-raw,framerate=30000/1001 ! fakesink name=sink signal-handoffs=true",
        base ++ " drop-only=true ! video/x-raw,framerate=12/1 ! fakesink name=sink signal-handoffs=true",
        base ++ " max-rate=7 ! fakesink name=sink signal-handoffs=true",
        base ++ " rate=2.0 ! video/x-raw,framerate=30/1 ! fakesink name=sink signal-handoffs=true",
        base ++ " rate=0.5 ! video/x-raw,framerate=30/1 ! fakesink name=sink signal-handoffs=true",
        base ++ " new-pref=0.0 ! video/x-raw,framerate=20/1 ! fakesink name=sink signal-handoffs=true",
        base ++ " new-pref=1.0 ! video/x-raw,framerate=20/1 ! fakesink name=sink signal-handoffs=true",
        base ++ " average-period=200000000 ! video/x-raw,framerate=10/1 ! fakesink name=sink signal-handoffs=true",
        "videotestsrc num-buffers=10 timestamp-offset=500000000 ! video/x-raw,format=GRAY8,width=16,height=16,framerate=10/1 ! videorate name=rate skip-to-first=true ! video/x-raw,framerate=20/1 ! fakesink name=sink signal-handoffs=true",
        "videotestsrc num-buffers=10 timestamp-offset=500000000 ! video/x-raw,format=GRAY8,width=16,height=16,framerate=10/1 ! videorate name=rate ! video/x-raw,framerate=20/1 ! fakesink name=sink signal-handoffs=true",
        "videotestsrc num-buffers=10 ! video/x-raw,format=GRAY8,width=16,height=16,framerate=10/1 ! videorate name=rate drop-out-of-segment=true max-closing-segment-duplication-duration=0 ! video/x-raw,framerate=15/1 ! fakesink name=sink signal-handoffs=true",
    };
    for (list) |d| run(d);

    const gaps = [_]Push{ .{ .pts = 0, .dur = 40 * MS }, .{ .pts = 40 * MS, .dur = 40 * MS }, .{ .pts = 300 * MS, .dur = 40 * MS }, .{ .pts = 340 * MS, .dur = 40 * MS }, .{ .pts = 1200 * MS, .dur = 40 * MS }, .{ .pts = 1180 * MS, .dur = 40 * MS }, .{ .pts = c.GST_CLOCK_TIME_NONE, .dur = 40 * MS }, .{ .pts = 1300 * MS, .dur = 40 * MS } };
    const vfr = [_]Push{ .{ .pts = 0, .dur = c.GST_CLOCK_TIME_NONE }, .{ .pts = 40 * MS, .dur = c.GST_CLOCK_TIME_NONE }, .{ .pts = 80 * MS, .dur = c.GST_CLOCK_TIME_NONE }, .{ .pts = 160 * MS, .dur = c.GST_CLOCK_TIME_NONE }, .{ .pts = 200 * MS, .dur = c.GST_CLOCK_TIME_NONE } };
    const app = "appsrc name=src ! videorate name=rate";
    const raw = "video/x-raw,format=GRAY8,width=8,height=8,framerate=25/1";
    const raw0 = "video/x-raw,format=GRAY8,width=8,height=8,framerate=0/1";
    pushed(app ++ " ! video/x-raw,framerate=25/1 ! fakesink name=sink signal-handoffs=true", raw, &gaps);
    pushed(app ++ " max-duplication-time=100000000 ! video/x-raw,framerate=25/1 ! fakesink name=sink signal-handoffs=true", raw, &gaps);
    pushed(app ++ " drop-only=true ! video/x-raw,framerate=10/1 ! fakesink name=sink signal-handoffs=true", raw, &gaps);
    pushed(app ++ " ! fakesink name=sink signal-handoffs=true", raw0, &vfr);
    pushed(app ++ " ! video/x-raw,framerate=0/1 ! fakesink name=sink signal-handoffs=true", raw0, &vfr);
    pushed(app ++ " ! video/x-raw,framerate=50/1 ! fakesink name=sink signal-handoffs=true", raw0, &vfr);

    for ([_][:0]const u8{ "plain", "drop", "drop max5", "max5" }) |d| capsCheck(d);
}
