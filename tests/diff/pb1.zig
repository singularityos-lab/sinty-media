const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const NONE = std.math.maxInt(u64);

const Log = struct {
    name: []const u8,
    lines: std.ArrayList(u8) = .empty,
    lock: c.GMutex = std.mem.zeroes(c.GMutex),

    fn add(l: *Log, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(A, "    " ++ fmt ++ "\n", args) catch unreachable;
        c.g_mutex_lock(&l.lock);
        l.lines.appendSlice(A, s) catch unreachable;
        c.g_mutex_unlock(&l.lock);
    }
};

fn t(v: u64) i64 {
    return if (v == NONE) -1 else @intCast(v / 1000000);
}

fn probe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const l: *Log = @ptrCast(@alignCast(data));
    if (info[0].type & c.GST_PAD_PROBE_TYPE_BUFFER != 0) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(info[0].data));
        l.add("buffer pts {d} dur {d} flags {x}", .{ t(b[0].pts), t(b[0].duration), b[0].mini_object.flags });
        return c.GST_PAD_PROBE_OK;
    }
    const e: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
    switch (e[0].type) {
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            l.add("segment format {d} rate {d} base {d} start {d} stop {d} time {d} offset {d}", .{ seg[0].format, seg[0].rate, t(seg[0].base), t(seg[0].start), t(seg[0].stop), t(seg[0].time), c.gst_event_get_running_time_offset(e) });
        },
        c.GST_EVENT_GAP => {
            var ts: u64 = 0;
            var dur: u64 = 0;
            c.gst_event_parse_gap(e, &ts, &dur);
            l.add("gap {d} {d}", .{ t(ts), t(dur) });
        },
        c.GST_EVENT_STREAM_START => {
            var gid: c.guint = 0;
            const have = c.gst_event_parse_group_id(e, &gid);
            l.add("stream-start group {d}", .{have});
        },
        else => l.add("event {s}", .{z(c.gst_event_type_get_name(e[0].type))}),
    }
    return c.GST_PAD_PROBE_OK;
}

fn run(title: []const u8, desc: [:0]const u8, sinks: []const [:0]const u8) void {
    out("pipeline {s}", .{title});
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err[0].message)});
        return;
    }
    var logs = A.alloc(Log, sinks.len) catch unreachable;
    for (sinks, 0..) |n, i| {
        logs[i] = .{ .name = n };
        const e = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), n.ptr);
        const pad = c.gst_element_get_static_pad(e, "sink");
        _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_DATA_DOWNSTREAM, probe, &logs[i], null);
        c.gst_object_unref(pad);
        c.gst_object_unref(e);
    }
    out("  state {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 6 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m == null) {
        out("  timeout", .{});
    } else {
        out("  end {s}", .{z(c.gst_message_type_get_name(m[0].type))});
        c.gst_mini_object_unref(@ptrCast(m));
    }
    c.gst_object_unref(bus);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    for (logs) |*l| out("  sink {s}\n{s}", .{ l.name, l.lines.items });
    c.gst_object_unref(p);
}

fn pads(el: ?*c.GstElement) void {
    var names: [1024]u8 = undefined;
    var n: usize = 0;
    var l = @as(*c.GstElement, @ptrCast(@alignCast(el))).pads;
    while (l != null) : (l = l[0].next) {
        const w = std.fmt.bufPrint(names[n..], "{s} ", .{z(c.gst_object_get_name(@ptrCast(@alignCast(l[0].data))))}) catch break;
        n += w.len;
    }
    out("  pads {s}", .{names[0..n]});
}

fn requests() void {
    out("requests", .{});
    const s = c.gst_element_factory_make("streamsynchronizer", "s");
    const tmpl = c.gst_element_get_pad_template(s, "sink_%u");
    const a = c.gst_element_request_pad(s, tmpl, null, null);
    const b = c.gst_element_request_pad(s, tmpl, "sink_7", null);
    out("  a {s} b {s}", .{ z(c.gst_object_get_name(@ptrCast(@alignCast(a)))), z(c.gst_object_get_name(@ptrCast(@alignCast(b)))) });
    pads(s);
    var it = c.gst_pad_iterate_internal_links(a);
    var v = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &v) == c.GST_ITERATOR_OK) {
        const o: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&v)));
        out("  link {s}", .{z(c.gst_object_get_name(@ptrCast(@alignCast(o))))});
        _ = c.g_value_reset(&v);
    }
    c.g_value_unset(&v);
    c.gst_iterator_free(it);
    c.gst_element_release_request_pad(s, a);
    pads(s);
    _ = c.gst_element_set_state(s, c.GST_STATE_READY);
    _ = c.gst_element_set_state(s, c.GST_STATE_NULL);
    const d = c.gst_element_request_pad(s, tmpl, null, null);
    out("  after reset {s}", .{z(c.gst_object_get_name(@ptrCast(@alignCast(d))))});
    pads(s);
    it = c.gst_pad_iterate_internal_links(c.gst_element_get_static_pad(s, "src_1"));
    c.gst_iterator_free(it);
    c.gst_object_unref(b);
    c.gst_object_unref(a);
    c.gst_object_unref(d);
    c.gst_object_unref(s);
}


const Cap = struct {
    log: Log,
    pad: ?*c.GstPad = null,
    count: std.atomic.Value(u32) = .init(0),
};

var caps_store: [2]Cap = undefined;
var srcs: [2]?*c.GstPad = .{ null, null };
var ups: [2]Log = undefined;

fn capChain(pad: ?*c.GstPad, _: ?*c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const cp: *Cap = @ptrCast(@alignCast(c.gst_pad_get_element_private(pad)));
    cp.log.add("buffer pts {d} dur {d}", .{ t(b[0].pts), t(b[0].duration) });
    _ = cp.count.fetchAdd(1, .seq_cst);
    c.gst_mini_object_unref(@ptrCast(b));
    return c.GST_FLOW_OK;
}

fn capEvent(pad: ?*c.GstPad, _: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const cp: *Cap = @ptrCast(@alignCast(c.gst_pad_get_element_private(pad)));
    var info = std.mem.zeroes(c.GstPadProbeInfo);
    info.type = c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM;
    info.data = e;
    _ = probe(pad, &info, &cp.log);
    _ = cp.count.fetchAdd(1, .seq_cst);
    c.gst_mini_object_unref(@ptrCast(e));
    return 1;
}

fn upEvent(pad: ?*c.GstPad, _: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const l: *Log = @ptrCast(@alignCast(c.gst_pad_get_element_private(pad)));
    l.add("upstream {s} offset {d}", .{ z(c.gst_event_type_get_name(e[0].type)), c.gst_event_get_running_time_offset(e) });
    c.gst_mini_object_unref(@ptrCast(e));
    return 1;
}

fn buf(pts_ms: u64, dur_ms: u64) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, 4, null);
    b[0].pts = pts_ms * 1000000;
    b[0].duration = if (dur_ms == NONE) NONE else dur_ms * 1000000;
    return b;
}

fn segTime(start_ms: u64, rate: f64) [*c]c.GstEvent {
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = start_ms * 1000000;
    seg.time = seg.start;
    seg.position = seg.start;
    seg.rate = rate;
    if (rate < 0) seg.stop = 4000 * 1000000;
    return c.gst_event_new_segment(&seg);
}

fn startEv(id: []const u8, group: c.guint) [*c]c.GstEvent {
    const e = c.gst_event_new_stream_start(@ptrCast(id.ptr));
    if (group != 0) c.gst_event_set_group_id(e, group);
    return e;
}

fn push(i: usize, b: [*c]c.GstBuffer) void {
    const r = c.gst_pad_push(srcs[i], b);
    out("  push {d} -> {s}", .{ i, z(c.gst_flow_get_name(r)) });
}

fn send(i: usize, e: [*c]c.GstEvent) void {
    const name = z(c.gst_event_type_get_name(e[0].type));
    const r = c.gst_pad_push_event(srcs[i], e);
    out("  event {d} {s} -> {d}", .{ i, name, r });
}

fn waitCount(cp: *Cap, target: u32) void {
    var n: usize = 0;
    while (cp.count.load(.seq_cst) < target and n < 200) : (n += 1) c.g_usleep(5000);
}

fn eosThread(data: c.gpointer) callconv(.c) c.gpointer {
    const i: usize = @intFromPtr(data);
    const r = c.gst_pad_push_event(srcs[i], c.gst_event_new_eos());
    out("  eos {d} returned {d}", .{ i, r });
    return null;
}

fn scenario(title: []const u8, comptime body: fn (*c.GstElement) void) void {
    out("scenario {s}", .{title});
    const s = c.gst_element_factory_make("streamsynchronizer", null);
    const tmpl = c.gst_element_get_pad_template(s, "sink_%u");
    for (0..2) |i| {
        caps_store[i] = .{ .log = .{ .name = "out" } };
        ups[i] = .{ .name = "in" };
        const sink = c.gst_element_request_pad(s, tmpl, null, null);
        const name = std.fmt.allocPrintSentinel(A, "src_{d}", .{i}, 0) catch unreachable;
        const src = c.gst_element_get_static_pad(s, name.ptr);
        const cap = c.gst_pad_new("cap", c.GST_PAD_SINK);
        c.gst_pad_set_element_private(cap, &caps_store[i]);
        c.gst_pad_set_chain_function_full(cap, capChain, null, null);
        c.gst_pad_set_event_function_full(cap, capEvent, null, null);
        _ = c.gst_pad_set_active(cap, 1);
        _ = c.gst_pad_link(src, cap);
        caps_store[i].pad = cap;
        const in = c.gst_pad_new("in", c.GST_PAD_SRC);
        c.gst_pad_set_element_private(in, &ups[i]);
        c.gst_pad_set_event_function_full(in, upEvent, null, null);
        _ = c.gst_pad_set_active(in, 1);
        _ = c.gst_pad_link(in, sink);
        srcs[i] = in;
        c.gst_object_unref(src);
        c.gst_object_unref(sink);
    }
    out("  state {d}", .{c.gst_element_set_state(s, c.GST_STATE_PLAYING)});
    body(s);
    out("  null {d}", .{c.gst_element_set_state(s, c.GST_STATE_NULL)});
    for (0..2) |i| {
        out("  out {d}\n{s}  in {d}\n{s}", .{ i, caps_store[i].log.lines.items, i, ups[i].lines.items });
        _ = c.gst_pad_set_active(srcs[i], 0);
        _ = c.gst_pad_set_active(caps_store[i].pad, 0);
        c.gst_object_unref(srcs[i]);
        c.gst_object_unref(caps_store[i].pad);
    }
    c.gst_object_unref(s);
}

fn startBoth(group: c.guint) void {
    send(0, startEv("a", group));
    send(1, startEv("b", group));
    send(0, segTime(0, 1.0));
    send(1, segTime(0, 1.0));
}

fn gapRun(_: *c.GstElement) void {
    startBoth(7);
    push(0, buf(0, 250));
    push(1, buf(0, 250));
    const th = c.g_thread_new("eos", eosThread, @ptrFromInt(0));
    c.g_usleep(100000);
    var pts: u64 = 250;
    while (pts <= 3000) : (pts += 250) {
        const before = caps_store[0].count.load(.seq_cst);
        push(1, buf(pts, 250));
        if (pts + 250 > 1250) waitCount(&caps_store[0], before + 1);
    }
    send(1, c.gst_event_new_eos());
    _ = c.g_thread_join(th);
}

fn equalRun(_: *c.GstElement) void {
    startBoth(7);
    for (0..4) |k| {
        push(0, buf(k * 250, 250));
        push(1, buf(k * 250, 250));
    }
    const th = c.g_thread_new("eos", eosThread, @ptrFromInt(0));
    c.g_usleep(100000);
    send(1, c.gst_event_new_eos());
    _ = c.g_thread_join(th);
}

fn noDataEos(_: *c.GstElement) void {
    startBoth(7);
    send(0, c.gst_event_new_eos());
    push(1, buf(0, NONE));
    push(1, buf(500, NONE));
    send(1, c.gst_event_new_eos());
}

fn groups(_: *c.GstElement) void {
    startBoth(7);
    push(0, buf(0, 500));
    push(1, buf(0, 500));
    push(1, buf(500, 500));
    send(0, startEv("a2", 9));
    send(1, startEv("b2", 9));
    send(0, segTime(0, 1.0));
    send(1, segTime(0, 1.0));
    push(0, buf(0, 250));
    push(1, buf(0, 250));
    send(0, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_UPSTREAM, c.gst_structure_new_empty("probe")));
    _ = c.gst_pad_push_event(caps_store[1].pad, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_UPSTREAM, c.gst_structure_new_empty("up")));
    _ = c.gst_pad_push_event(caps_store[0].pad, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_UPSTREAM, c.gst_structure_new_empty("up")));
}

fn noGroup(_: *c.GstElement) void {
    startBoth(0);
    push(0, buf(0, 100));
    send(0, startEv("a", 0));
    send(1, startEv("b", 0));
    send(1, segTime(100, 1.0));
    push(1, buf(100, 100));
}

fn flushing(_: *c.GstElement) void {
    startBoth(7);
    push(0, buf(0, 250));
    push(1, buf(0, 250));
    push(1, buf(250, 250));
    send(0, c.gst_event_new_flush_start());
    send(0, c.gst_event_new_flush_stop(1));
    send(0, segTime(1000, 1.0));
    push(0, buf(1000, 250));
    send(1, c.gst_event_new_flush_start());
    send(1, c.gst_event_new_flush_stop(0));
    send(1, segTime(0, 1.0));
    push(1, buf(500, 250));
    send(0, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM_OOB, c.gst_structure_new_empty("playsink-custom-video-flush")));
}

fn reverse(_: *c.GstElement) void {
    send(0, startEv("a", 7));
    send(1, startEv("b", 7));
    send(0, segTime(0, -1.0));
    send(1, segTime(0, -1.0));
    push(0, buf(3000, 250));
    push(1, buf(3500, 250));
    push(1, buf(1000, 250));
    const th = c.g_thread_new("eos", eosThread, @ptrFromInt(0));
    c.g_usleep(100000);
    send(1, c.gst_event_new_eos());
    _ = c.g_thread_join(th);
}

fn bytes(_: *c.GstElement) void {
    send(0, startEv("a", 7));
    send(1, startEv("b", 7));
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_BYTES);
    send(0, c.gst_event_new_segment(&seg));
    send(1, segTime(0, 1.0));
    push(0, buf(0, 250));
    const th = c.g_thread_new("eos", eosThread, @ptrFromInt(0));
    c.g_usleep(100000);
    send(1, c.gst_event_new_eos());
    _ = c.g_thread_join(th);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("streamsynchronizer");
    requests();
    scenario("gaps", gapRun);
    scenario("equal", equalRun);
    scenario("eos without data", noDataEos);
    scenario("groups", groups);
    scenario("no group id", noGroup);
    scenario("flushing", flushing);
    scenario("reverse", reverse);
    scenario("bytes", bytes);
    out("done", .{});
}
