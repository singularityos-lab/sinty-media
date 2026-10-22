const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;

var total: usize = 0;
var hash = std.hash.Fnv1a_64.init();

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, _: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    total += map.size;
    hash.update(map.data[0..map.size]);
    c.gst_buffer_unmap(b, &map);
}

fn payload(n: usize) []u8 {
    const d = A.alloc(u8, n) catch unreachable;
    for (d, 0..) |*x, i| x.* = @truncate(i *% 37 +% (i >> 9) +% 3);
    return d;
}

fn wait(p: ?*c.GstElement, seconds: u64) void {
    const bus = c.gst_element_get_bus(p);
    defer c.gst_object_unref(bus);
    const m = c.gst_bus_timed_pop_filtered(bus, seconds * @as(u64, c.GST_SECOND), c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
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
}

fn launch(desc: [:0]const u8) ?*c.GstElement {
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) out("  parse error {s}", .{z(err.*.message)});
    return p;
}

fn named(p: ?*c.GstElement, name: [*c]const u8) ?*c.GstElement {
    return c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), name);
}

fn stop(p: ?*c.GstElement) void {
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

fn serverSrc(file: []const u8) void {
    out("tcpserversrc <- tcpclientsink", .{});
    const rx = launch("tcpserversrc name=src host=127.0.0.1 port=0 ! fakesink name=sink signal-handoffs=true") orelse return;
    const sink = named(rx, "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    total = 0;
    hash = std.hash.Fnv1a_64.init();
    out("  rx playing {d}", .{c.gst_element_set_state(rx, c.GST_STATE_PLAYING)});
    var port: c.gint = 0;
    const src = named(rx, "src");
    c.g_object_get(src, "current-port", &port, @as(?*anyopaque, null));
    out("  bound {}", .{port != 0});
    const tx = launch(std.fmt.allocPrintSentinel(A, "filesrc location={s} blocksize=3000 ! tcpclientsink name=out host=127.0.0.1 port={d}", .{ file, port }, 0) catch unreachable) orelse return;
    out("  tx playing {d}", .{c.gst_element_set_state(tx, c.GST_STATE_PLAYING)});
    wait(tx, 10);
    stop(tx);
    wait(rx, 10);
    out("  received bytes {d} hash {x}", .{ total, hash.final() });
    var stats: ?*c.GstStructure = null;
    c.g_object_get(src, "stats", &stats, @as(?*anyopaque, null));
    var received: u64 = 0;
    _ = c.gst_structure_get_uint64(stats, "bytes-received", &received);
    out("  stats {s} bytes-received {d}", .{ z(c.gst_structure_get_name(stats)), received });
    c.gst_structure_free(stats);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    stop(rx);
}

fn refused() void {
    out("tcpclientsrc refused", .{});
    const p = launch("tcpclientsrc host=127.0.0.1 port=1 ! fakesink") orelse return;
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    wait(p, 5);
    stop(p);
    out("tcpclientsink refused", .{});
    const q = launch("fakesrc num-buffers=1 ! tcpclientsink host=127.0.0.1 port=1") orelse return;
    out("  playing {d}", .{c.gst_element_set_state(q, c.GST_STATE_PLAYING)});
    wait(q, 5);
    stop(q);
    out("tcpclientsrc unresolvable", .{});
    const r = launch("tcpclientsrc host=no.such.host.invalid port=4953 ! fakesink") orelse return;
    out("  playing {d}", .{c.gst_element_set_state(r, c.GST_STATE_PLAYING)});
    wait(r, 10);
    stop(r);
}

fn drainFd(fd: c_int) void {
    var buf: [65536]u8 = undefined;
    var got: usize = 0;
    var h = std.hash.Fnv1a_64.init();
    var idle: usize = 0;
    while (idle < 20) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n > 0) {
            got += @intCast(n);
            h.update(buf[0..@intCast(n)]);
            idle = 0;
        } else {
            idle += 1;
            c.g_usleep(50000);
        }
    }
    out("  peer read {d} hash {x}", .{ got, h.final() });
}

fn removed(_: ?*c.GstElement, fd: c.gint, status: c.gint, _: c.gpointer) callconv(.c) void {
    _ = fd;
    out("  client-removed status {d}", .{status});
}

fn fdSink(file: []const u8, sync: [:0]const u8) void {
    out("multifdsink sync-method={s}", .{sync});
    var pair: [2]c_int = undefined;
    _ = c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair);
    _ = c.fcntl(pair[1], c.F_SETFL, @as(c_int, c.O_NONBLOCK));
    const p = launch(std.fmt.allocPrintSentinel(A, "filesrc location={s} blocksize=4096 ! multifdsink name=sink sync-method={s}", .{ file, sync }, 0) catch unreachable) orelse return;
    const sink = named(p, "sink");
    _ = c.g_signal_connect_data(sink, "client-removed", @ptrCast(&removed), null, null, 0);
    out("  ready {d}", .{c.gst_element_set_state(p, c.GST_STATE_READY)});
    c.g_signal_emit_by_name(sink, "add", pair[0]);
    c.g_signal_emit_by_name(sink, "add", pair[0]);
    var handles: c.guint = 0;
    c.g_object_get(sink, "num-handles", &handles, @as(?*anyopaque, null));
    out("  num-handles {d}", .{handles});
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    wait(p, 10);
    drainFd(pair[1]);
    var stats: ?*c.GstStructure = null;
    c.g_signal_emit_by_name(sink, "get-stats", pair[0], &stats);
    var sent: u64 = 0;
    _ = c.gst_structure_get_uint64(stats, "bytes-sent", &sent);
    out("  stats {s} bytes-sent {d} fields {d}", .{ z(c.gst_structure_get_name(stats)), sent, c.gst_structure_n_fields(stats) });
    c.gst_structure_free(stats);
    var served: u64 = 0;
    var to_serve: u64 = 0;
    c.g_object_get(sink, "bytes-served", &served, "bytes-to-serve", &to_serve, @as(?*anyopaque, null));
    out("  bytes-served {d} bytes-to-serve {d}", .{ served, to_serve });
    c.g_signal_emit_by_name(sink, "remove", pair[0]);
    c.g_object_get(sink, "num-handles", &handles, @as(?*anyopaque, null));
    out("  num-handles after remove {d}", .{handles});
    c.gst_object_unref(sink);
    stop(p);
    _ = std.c.close(pair[0]);
    _ = std.c.close(pair[1]);
}

fn socketRemoved(_: ?*c.GstElement, _: ?*c.GSocket, status: c.gint, _: c.gpointer) callconv(.c) void {
    out("  client-removed status {d}", .{status});
}

fn socketSink(file: []const u8) void {
    out("multisocketsink", .{});
    var pair: [2]c_int = undefined;
    _ = c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair);
    _ = c.fcntl(pair[1], c.F_SETFL, @as(c_int, c.O_NONBLOCK));
    const sock = c.g_socket_new_from_fd(pair[0], null);
    const p = launch(std.fmt.allocPrintSentinel(A, "filesrc location={s} blocksize=5000 ! multisocketsink name=sink", .{file}, 0) catch unreachable) orelse return;
    const sink = named(p, "sink");
    _ = c.g_signal_connect_data(sink, "client-removed", @ptrCast(&socketRemoved), null, null, 0);
    out("  ready {d}", .{c.gst_element_set_state(p, c.GST_STATE_READY)});
    c.g_signal_emit_by_name(sink, "add", sock);
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    wait(p, 10);
    drainFd(pair[1]);
    var stats: ?*c.GstStructure = null;
    c.g_signal_emit_by_name(sink, "get-stats", sock, &stats);
    var sent: u64 = 0;
    _ = c.gst_structure_get_uint64(stats, "bytes-sent", &sent);
    out("  stats bytes-sent {d}", .{sent});
    c.gst_structure_free(stats);
    c.g_signal_emit_by_name(sink, "clear");
    var handles: c.guint = 0;
    c.g_object_get(sink, "num-handles", &handles, @as(?*anyopaque, null));
    out("  num-handles after clear {d}", .{handles});
    c.gst_object_unref(sink);
    stop(p);
    c.g_object_unref(sock);
    _ = std.c.close(pair[1]);
}

fn socketSrc(data: []const u8) void {
    out("socketsrc", .{});
    var pair: [2]c_int = undefined;
    _ = c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair);
    const sock = c.g_socket_new_from_fd(pair[0], null);
    const p = launch("socketsrc name=src ! fakesink name=sink signal-handoffs=true") orelse return;
    const src = named(p, "src");
    const sink = named(p, "sink");
    c.g_object_set(src, "socket", sock, @as(?*anyopaque, null));
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    total = 0;
    hash = std.hash.Fnv1a_64.init();
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(pair[1], data[off..].ptr, @min(data.len - off, 8192));
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = std.c.close(pair[1]);
    wait(p, 10);
    out("  received bytes {d} hash {x}", .{ total, hash.final() });
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    stop(p);
    c.g_object_unref(sock);
}

pub fn main() void {
    c.gst_init(null, null);
    for ([_][*c]const u8{ "socketsrc", "tcpclientsink", "tcpclientsrc", "tcpserversink", "tcpserversrc", "multifdsink", "multisocketsink" }) |n| ins.element(n);
    const cwd = c.g_get_current_dir();
    const dir = std.fmt.allocPrintSentinel(A, "{s}/zig-out/tcp1work", .{z(cwd)}, 0) catch unreachable;
    _ = c.g_mkdir_with_parents(dir.ptr, 0o755);
    const data = payload(90000);
    const file = std.fmt.allocPrintSentinel(A, "{s}/in.bin", .{dir}, 0) catch unreachable;
    _ = c.g_file_set_contents(file.ptr, data.ptr, @intCast(data.len), null);
    out("source bytes {d} hash {x}", .{ data.len, std.hash.Fnv1a_64.hash(data) });
    serverSrc(file);
    refused();
    for ([_][:0]const u8{ "latest", "next-keyframe" }) |s| fdSink(file, s);
    socketSink(file);
    socketSrc(data);
}
