const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

var log: std.ArrayList(u8) = .empty;
var log_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var pipe_g: ?*c.GstElement = null;
var atf: std.atomic.Value(u32) = .init(0);
var buf_first: c.gint = -1;
var buf_last: c.gint = -1;
var buf_count: u32 = 0;

fn add(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(A, "    " ++ fmt ++ "\n", args) catch unreachable;
    c.g_mutex_lock(&log_lock);
    log.appendSlice(A, s) catch unreachable;
    c.g_mutex_unlock(&log_lock);
    A.free(s);
}

fn objName(o: ?*anyopaque) []const u8 {
    const p = o orelse return "-";
    return z(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

fn counter(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (info[0].type & c.GST_PAD_PROBE_TYPE_BUFFER != 0) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(info[0].data));
        var map: c.GstMapInfo = undefined;
        if (c.gst_buffer_map(b, &map, c.GST_MAP_READ) != 0) {
            add("{s} buffer off {d} size {d} hash {x}", .{ objName(pad), b[0].offset, map.size, std.hash.Fnv1a_64.hash(map.data[0..map.size]) });
            c.gst_buffer_unmap(b, &map);
        }
    } else {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
        add("{s} event {s}", .{ objName(pad), z(c.gst_event_type_get_name(e[0].type)) });
    }
    return c.GST_PAD_PROBE_OK;
}

fn padAdded(_: ?*c.GstElement, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_pad_query_caps(pad, null);
    const cs = c.gst_caps_to_string(caps);
    add("pad-added {s} caps {s}", .{ objName(pad), z(cs) });
    c.g_free(cs);
    c.gst_caps_unref(caps);
    const sink = c.gst_element_factory_make("fakesink", null);
    c.g_object_set(@ptrCast(sink), "sync", @as(c.gboolean, 0), N);
    _ = c.gst_bin_add(@ptrCast(@alignCast(pipe_g)), sink);
    const sp = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(sp, c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, counter, null, null);
    add("link {d}", .{c.gst_pad_link(pad, sp)});
    c.gst_object_unref(sp);
    _ = c.gst_element_sync_state_with_parent(sink);
}

fn sourceSetup(_: ?*c.GstElement, src: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    const f = c.gst_element_get_factory(src);
    add("source-setup {s}", .{objName(f)});
}

fn aboutToFinish(_: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    _ = atf.fetchAdd(1, .monotonic);
}

fn tree(e: ?*c.GstElement, depth: usize) void {
    var pad_buf: [2048]u8 = undefined;
    var n: usize = 0;
    var pl = @as(*c.GstElement, @ptrCast(@alignCast(e))).pads;
    while (pl != null) : (pl = pl[0].next) {
        const p: ?*c.GstPad = @ptrCast(@alignCast(pl[0].data));
        const peer = c.gst_pad_get_peer(p);
        var pe: []const u8 = "-";
        if (peer) |x| {
            pe = objName(@as(*c.GstObject, @ptrCast(@alignCast(x))).parent);
            c.gst_object_unref(x);
        }
        const w = std.fmt.bufPrint(pad_buf[n..], "{s}->{s} ", .{ objName(p), if (depth == 0) "x" else pe }) catch break;
        n += w.len;
    }
    const f = c.gst_element_get_factory(e);
    var ind: [32]u8 = @splat(' ');
    out("  {s}{s} {s}", .{ ind[0 .. depth * 2], if (f != null) objName(f) else "-", pad_buf[0..n] });
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(e)), c.gst_bin_get_type()) == 0) return;
    var kids: std.ArrayList(?*c.GstElement) = .empty;
    var l = @as(*c.GstBin, @ptrCast(@alignCast(e))).children;
    while (l != null) : (l = l[0].next) kids.append(A, @ptrCast(@alignCast(l[0].data))) catch unreachable;
    std.mem.sort(?*c.GstElement, kids.items, {}, struct {
        fn lt(_: void, a: ?*c.GstElement, b: ?*c.GstElement) bool {
            const fa = c.gst_element_get_factory(a);
            const fb = c.gst_element_get_factory(b);
            return std.mem.lessThan(u8, objName(fa), objName(fb));
        }
    }.lt);
    for (kids.items) |k| tree(k, depth + 1);
    kids.deinit(A);
}

fn describe(m: [*c]c.GstMessage) void {
    var err: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    switch (m[0].type) {
        c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
            if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &err, &dbg) else c.gst_message_parse_warning(m, &err, &dbg);
            const d = z(dbg);
            const cut = if (std.mem.indexOf(u8, d, ": /")) |i| d[0..i] else d;
            out("  {s} {s} {s} {d} [{s}] [{s}]", .{ z(c.gst_message_type_get_name(m[0].type)), objName(m[0].src), z(c.g_quark_to_string(err[0].domain)), err[0].code, z(err[0].message), cut });
            c.g_error_free(err);
            c.g_free(dbg);
        },
        c.GST_MESSAGE_BUFFERING => {
            var p: c.gint = 0;
            c.gst_message_parse_buffering(m, &p);
            if (buf_first == -1) buf_first = p;
            buf_last = p;
            buf_count += 1;
        },
        c.GST_MESSAGE_STREAM_COLLECTION => out("  stream-collection from {s}", .{objName(m[0].src)}),
        else => {
            const str = c.gst_structure_to_string(c.gst_message_get_structure(m));
            out("  element {s} {s}", .{ objName(m[0].src), z(str) });
            c.g_free(str);
        },
    }
}

fn queries(usb: ?*c.GstElement) void {
    const d = c.gst_query_new_duration(c.GST_FORMAT_BYTES);
    const ok = c.gst_element_query(usb, d);
    var dur: i64 = 0;
    c.gst_query_parse_duration(d, null, &dur);
    out("  duration {d} {d}", .{ ok, dur });
    c.gst_query_unref(d);
    const s = c.gst_query_new_seeking(c.GST_FORMAT_BYTES);
    const ok2 = c.gst_element_query(usb, s);
    var seekable: c.gboolean = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    c.gst_query_parse_seeking(s, null, &seekable, &start, &stop);
    out("  seeking {d} {d} {d} {d}", .{ ok2, seekable, start, stop });
    c.gst_query_unref(s);
    const l = c.gst_query_new_latency();
    const ok3 = c.gst_element_query(usb, l);
    var live: c.gboolean = 0;
    var mn: u64 = 0;
    var mx: u64 = 0;
    c.gst_query_parse_latency(l, &live, &mn, &mx);
    out("  latency {d} {d} {d} {d}", .{ ok3, live, mn, @as(i64, @bitCast(mx)) });
    c.gst_query_unref(l);
    const p = c.gst_query_new_position(c.GST_FORMAT_BYTES);
    out("  position {d}", .{c.gst_element_query(usb, p)});
    c.gst_query_unref(p);
}

fn props(usb: ?*c.GstElement) void {
    var uri: [*c]u8 = null;
    var src: ?*c.GstElement = null;
    var speed: u64 = 0;
    var size: c.gint = 0;
    var dur: i64 = 0;
    var stats: ?*c.GstStructure = null;
    c.g_object_get(@ptrCast(usb), "uri", &uri, "source", &src, "connection-speed", &speed, "buffer-size", &size, "buffer-duration", &dur, "statistics", &stats, N);
    const ss = c.gst_structure_to_string(stats);
    out("  props uri {s} source {s} speed {d} size {d} dur {d} stats {s}", .{ z(uri), if (src != null) "yes" else "no", speed, size, dur, z(ss) });
    c.g_free(ss);
    if (stats) |x| c.gst_structure_free(x);
    if (src) |x| c.gst_object_unref(x);
    c.g_free(uri);
}

const Opts = struct {
    uri: ?[]const u8,
    speed: u64 = 0,
    buffer_size: c.gint = -1,
    use_buffering: bool = true,
    download: bool = false,
};

fn scenario(title: []const u8, o: Opts) void {
    out("scenario {s}", .{title});
    log.clearRetainingCapacity();
    atf.store(0, .monotonic);
    buf_first = -1;
    buf_last = -1;
    buf_count = 0;
    const pipe = c.gst_pipeline_new("pipe");
    pipe_g = pipe;
    const usb = c.gst_element_factory_make("urisourcebin", "usb");
    if (usb == null) {
        out("  no urisourcebin", .{});
        return;
    }
    if (o.uri) |u| {
        const us = A.dupeZ(u8, u) catch unreachable;
        c.g_object_set(@ptrCast(usb), "uri", us.ptr, N);
        A.free(us);
    }
    if (o.speed != 0) c.g_object_set(@ptrCast(usb), "connection-speed", o.speed, N);
    if (o.buffer_size != -1) c.g_object_set(@ptrCast(usb), "buffer-size", o.buffer_size, N);
    if (!o.use_buffering) c.g_object_set(@ptrCast(usb), "use-buffering", @as(c.gboolean, 0), N);
    if (o.download) c.g_object_set(@ptrCast(usb), "download", @as(c.gboolean, 1), N);
    _ = c.g_signal_connect_data(usb, "pad-added", @ptrCast(&padAdded), null, null, 0);
    _ = c.g_signal_connect_data(usb, "source-setup", @ptrCast(&sourceSetup), null, null, 0);
    _ = c.g_signal_connect_data(usb, "about-to-finish", @ptrCast(&aboutToFinish), null, null, 0);
    _ = c.gst_bin_add(@ptrCast(@alignCast(pipe)), usb);
    props(usb);
    const bus = c.gst_element_get_bus(pipe);
    out("  paused {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PAUSED)});
    var cur: c.GstState = 0;
    out("  get_state {d}", .{c.gst_element_get_state(pipe, &cur, null, 5 * c.GST_SECOND)});
    while (c.gst_bus_pop_filtered(bus, c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT | c.GST_MESSAGE_BUFFERING | c.GST_MESSAGE_STREAM_COLLECTION)) |m| {
        describe(m);
        c.gst_mini_object_unref(@ptrCast(m));
    }
    var waited: u32 = 0;
    while (@as(*c.GstElement, @ptrCast(@alignCast(usb))).numsrcpads == 0 and waited < 100) : (waited += 1) c.g_usleep(10000);
    tree(usb, 0);
    queries(usb);
    props(usb);
    out("  playing ok {d}", .{@intFromBool(c.gst_element_set_state(pipe, c.GST_STATE_PLAYING) != c.GST_STATE_CHANGE_FAILURE)});
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 3 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT | c.GST_MESSAGE_BUFFERING | c.GST_MESSAGE_STREAM_COLLECTION);
        if (m == null) {
            out("  timeout", .{});
            break;
        }
        if (m[0].type == c.GST_MESSAGE_EOS) {
            c.gst_mini_object_unref(@ptrCast(m));
            out("  eos", .{});
            break;
        }
        describe(m);
        const e = m[0].type == c.GST_MESSAGE_ERROR;
        c.gst_mini_object_unref(@ptrCast(m));
        if (e) break;
    }
    out("  buffering first {d} last {d} any {d}", .{ buf_first, buf_last, @intFromBool(buf_count > 0) });
    out("  about-to-finish {d}", .{atf.load(.monotonic)});
    out("  log\n{s}", .{log.items});
    out("  ready {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_READY)});
    tree(usb, 0);
    props(usb);
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(pipe);
}

fn makeWav(path: [:0]const u8) void {
    var err: [*c]c.GError = null;
    const desc = std.fmt.allocPrintSentinel(A, "audiotestsrc num-buffers=20 samplesperbuffer=1024 ! audio/x-raw,format=S16LE,rate=44100,channels=2 ! wavenc ! filesink location={s}", .{path}, 0) catch unreachable;
    const p = c.gst_parse_launch(desc.ptr, &err);
    A.free(desc);
    _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 10 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m != null) c.gst_mini_object_unref(@ptrCast(m));
    c.gst_object_unref(bus);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("urisourcebin");
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return;
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(cwd)));
    const wav = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb4.wav", .{dir}, 0) catch unreachable;
    makeWav(wav);
    const file_uri = std.fmt.allocPrint(A, "file://{s}", .{wav}) catch unreachable;
    scenario("no uri", .{ .uri = null });
    scenario("invalid uri", .{ .uri = "not a uri" });
    scenario("unknown protocol", .{ .uri = "sintyfoo://bar" });
    scenario("missing file", .{ .uri = "file:///nonexistent/sinty-media.wav" });
    scenario("file", .{ .uri = file_uri, .speed = 1000 });
    scenario("file no buffering", .{ .uri = file_uri, .use_buffering = false });
    const fd = c.open(wav.ptr, c.O_RDONLY);
    const fd_uri = std.fmt.allocPrint(A, "fd://{d}", .{fd}) catch unreachable;
    scenario("fd stream", .{ .uri = fd_uri, .buffer_size = 65536 });
    _ = c.lseek(fd, 0, c.SEEK_SET);
    scenario("fd stream no buffering", .{ .uri = fd_uri, .use_buffering = false });
    _ = c.close(fd);
    out("done", .{});
}
