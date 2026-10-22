const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

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
    for (d, 0..) |*x, i| x.* = @truncate(i *% 31 +% (i >> 8) +% 7);
    return d;
}

fn drain(p: ?*c.GstElement) void {
    const bus = c.gst_element_get_bus(p);
    defer c.gst_object_unref(bus);
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT);
        if (m == null) {
            out("  timeout", .{});
            return;
        }
        defer c.gst_message_unref(m);
        switch (m.*.type) {
            c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
                var e: [*c]c.GError = null;
                var dbg: [*c]u8 = null;
                if (m.*.type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
                const d = z(dbg);
                const cut = if (std.mem.indexOf(u8, d, ": /")) |i| d[0..i] else d;
                const kind: []const u8 = if (m.*.type == c.GST_MESSAGE_ERROR) "error" else "warning";
                out("  {s} {s} {d} [{s}] [{s}]", .{ kind, z(c.g_quark_to_string(e.*.domain)), e.*.code, z(e.*.message), cut });
                c.g_error_free(e);
                c.g_free(dbg);
                if (m.*.type == c.GST_MESSAGE_ERROR) return;
            },
            c.GST_MESSAGE_ELEMENT => {
                const st = c.gst_message_get_structure(m);
                out("  element {s} uri {s}", .{ z(c.gst_structure_get_name(st)), z(c.gst_structure_get_string(st, "uri")) });
            },
            else => {
                out("  eos", .{});
                return;
            },
        }
    }
}

fn readPipeline(desc: [:0]const u8, setup: ?*const fn (?*c.GstElement) void) void {
    out("read {s}", .{desc});
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const sink = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "sink");
    if (sink != null) _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    if (setup) |f| f(p);
    total = 0;
    hash = std.hash.Fnv1a_64.init();
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    drain(p);
    out("  bytes {d} hash {x}", .{ total, hash.final() });
    const src = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "src");
    if (src != null) {
        const q = c.gst_query_new_duration(c.GST_FORMAT_BYTES);
        var dur: i64 = 0;
        const ok = c.gst_element_query(src, q);
        c.gst_query_parse_duration(q, null, &dur);
        out("  duration {d} {d}", .{ ok, dur });
        c.gst_query_unref(q);
        const sq = c.gst_query_new_scheduling();
        const sok = c.gst_element_query(src, sq);
        var flags: c.GstSchedulingFlags = 0;
        var minsize: c.gint = 0;
        var maxsize: c.gint = 0;
        var al: c.gint = 0;
        c.gst_query_parse_scheduling(sq, &flags, &minsize, &maxsize, &al);
        out("  scheduling {d} flags {d} {d} {d} {d} modes {d} push {d} pull {d}", .{ sok, flags, minsize, maxsize, al, c.gst_query_get_n_scheduling_modes(sq), c.gst_query_has_scheduling_mode(sq, c.GST_PAD_MODE_PUSH), c.gst_query_has_scheduling_mode(sq, c.GST_PAD_MODE_PULL) });
        c.gst_query_unref(sq);
        const uq = c.gst_query_new_uri();
        const uok = c.gst_element_query(src, uq);
        var uri: [*c]u8 = null;
        c.gst_query_parse_uri(uq, &uri);
        out("  uri {d} {s}", .{ uok, z(uri) });
        c.g_free(uri);
        c.gst_query_unref(uq);
        c.gst_object_unref(src);
    }
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    if (sink != null) c.gst_object_unref(sink);
    c.gst_object_unref(p);
}

var mem_data: []u8 = &.{};

fn memorySource(p: ?*c.GstElement) void {
    const src = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "src");
    const stream = c.g_memory_input_stream_new_from_data(mem_data.ptr, @intCast(mem_data.len), null);
    c.g_object_set(src, "stream", stream, N);
    c.g_object_unref(stream);
    c.gst_object_unref(src);
}

var mem_out: ?*c.GOutputStream = null;

fn memorySink(p: ?*c.GstElement) void {
    const sink = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "out");
    mem_out = c.g_memory_output_stream_new_resizable();
    c.g_object_set(sink, "stream", mem_out, N);
    var got: ?*c.GObject = null;
    c.g_object_get(sink, "stream", &got, N);
    out("  stream before start {d}", .{@intFromBool(got != null)});
    if (got) |g| c.g_object_unref(g);
    c.gst_object_unref(sink);
}

fn fileHash(path: [:0]const u8) void {
    var data: [*c]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(path.ptr, &data, &len, null) == 0) {
        out("  file missing", .{});
        return;
    }
    out("  file bytes {d} hash {x}", .{ len, std.hash.Fnv1a_64.hash(data[0..len]) });
    c.g_free(data);
}

fn props(name: [*c]const u8) void {
    const e = c.gst_element_factory_make(name, null);
    defer c.gst_object_unref(e);
    var close: c.gboolean = 0;
    var loc: [*c]u8 = null;
    if (c.g_object_class_find_property(@ptrCast(@as(*c.GTypeInstance, @ptrCast(e)).g_class), "close-on-stop") != null) c.g_object_get(e, "close-on-stop", &close, N);
    if (c.g_object_class_find_property(@ptrCast(@as(*c.GTypeInstance, @ptrCast(e)).g_class), "location") != null) {
        c.g_object_set(e, "location", "file:///nowhere/x.bin", N);
        c.g_object_get(e, "location", &loc, N);
    }
    out("props {s} close {d} location {s} sync {d}", .{ z(name), close, z(loc), @intFromBool(c.g_type_check_instance_is_a(@ptrCast(e), c.gst_base_sink_get_type()) != 0 and c.gst_base_sink_get_sync(@ptrCast(e)) != 0) });
    c.g_free(loc);
    if (c.g_type_check_instance_is_a(@ptrCast(e), c.gst_uri_handler_get_type()) != 0) {
        const h: ?*c.GstURIHandler = @ptrCast(e);
        const protos = c.gst_uri_handler_get_protocols(h);
        var has_file = false;
        var has_http = false;
        var i: usize = 0;
        while (protos != null and protos[i] != null) : (i += 1) {
            if (c.strcmp(protos[i], "file") == 0) has_file = true;
            if (c.strcmp(protos[i], "http") == 0) has_http = true;
        }
        var gerr: [*c]c.GError = null;
        const ok = c.gst_uri_handler_set_uri(h, "file:///tmp/y.bin", &gerr);
        const u = c.gst_uri_handler_get_uri(h);
        out("  uri type {d} file {d} http {d} set {d} get {s}", .{ c.gst_uri_handler_get_uri_type(h), @intFromBool(has_file), @intFromBool(has_http), ok, z(u) });
        c.g_free(u);
    }
}

pub fn main() void {
    c.gst_init(null, null);
    for ([_][*c]const u8{ "giosrc", "giosink", "giostreamsrc", "giostreamsink" }) |n| ins.element(n);
    for ([_][*c]const u8{ "giosrc", "giosink", "giostreamsrc", "giostreamsink" }) |n| props(n);
    const cwd = c.g_get_current_dir();
    const dir = std.fmt.allocPrintSentinel(A, "{s}/zig-out/gio1work", .{z(cwd)}, 0) catch unreachable;
    _ = c.g_spawn_command_line_sync((std.fmt.allocPrintSentinel(A, "rm -rf {s}", .{dir}, 0) catch unreachable).ptr, null, null, null, null);
    _ = c.g_mkdir_with_parents(dir.ptr, 0o755);
    const data = payload(70000);
    const in_path = std.fmt.allocPrintSentinel(A, "{s}/in.bin", .{dir}, 0) catch unreachable;
    _ = c.g_file_set_contents(in_path.ptr, data.ptr, @intCast(data.len), null);
    out("source hash {x}", .{std.hash.Fnv1a_64.hash(data)});

    readPipeline(std.fmt.allocPrintSentinel(A, "giosrc name=src location=file://{s} ! fakesink name=sink signal-handoffs=true", .{in_path}, 0) catch unreachable, null);
    readPipeline(std.fmt.allocPrintSentinel(A, "giosrc name=src location=file://{s} blocksize=1000 ! fakesink name=sink signal-handoffs=true", .{in_path}, 0) catch unreachable, null);
    readPipeline(std.fmt.allocPrintSentinel(A, "giosrc name=src location=file://{s} ! queue2 ! fakesink name=sink signal-handoffs=true", .{in_path}, 0) catch unreachable, null);
    readPipeline(std.fmt.allocPrintSentinel(A, "giosrc name=src location=file://{s}/missing.bin ! fakesink name=sink signal-handoffs=true", .{dir}, 0) catch unreachable, null);
    readPipeline("giosrc name=src ! fakesink name=sink signal-handoffs=true", null);

    mem_data = payload(12345);
    out("memory hash {x}", .{std.hash.Fnv1a_64.hash(mem_data)});
    readPipeline("giostreamsrc name=src blocksize=4000 ! fakesink name=sink signal-handoffs=true", &memorySource);
    readPipeline("giostreamsrc name=src ! fakesink name=sink signal-handoffs=true", null);

    const out_path = std.fmt.allocPrintSentinel(A, "{s}/out.bin", .{dir}, 0) catch unreachable;
    readPipeline(std.fmt.allocPrintSentinel(A, "giosrc location=file://{s} ! giosink name=sink location=file://{s}", .{ in_path, out_path }, 0) catch unreachable, null);
    fileHash(out_path);
    readPipeline(std.fmt.allocPrintSentinel(A, "giosrc location=file://{s} ! giosink name=sink location=file://{s}", .{ in_path, out_path }, 0) catch unreachable, null);
    readPipeline(std.fmt.allocPrintSentinel(A, "giosrc location=file://{s} ! giosink name=sink location=file://{s}/nodir/x.bin", .{ in_path, dir }, 0) catch unreachable, null);
    readPipeline("fakesrc num-buffers=1 ! giosink name=sink", null);

    readPipeline(std.fmt.allocPrintSentinel(A, "giosrc location=file://{s} blocksize=3000 ! giostreamsink name=out", .{in_path}, 0) catch unreachable, &memorySink);
    if (mem_out) |m| {
        const mo: ?*c.GMemoryOutputStream = @ptrCast(@alignCast(m));
        const n = c.g_memory_output_stream_get_data_size(mo);
        const d: [*c]u8 = @ptrCast(c.g_memory_output_stream_get_data(mo));
        out("  memory out bytes {d} hash {x} closed {d}", .{ n, std.hash.Fnv1a_64.hash(d[0..n]), c.g_output_stream_is_closed(m) });
        c.g_object_unref(m);
    }
    readPipeline("fakesrc num-buffers=1 ! giostreamsink name=out", null);
    out("done", .{});
}
