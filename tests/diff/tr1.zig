const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const N: ?*anyopaque = null;

const masked = [_][]const u8{ "ts", "thread-id", "process-id", "time", "average-cpuload", "current-cpuload", "address", "src-element-id", "sink-element-id", "element-id", "trace" };

fn isMasked(k: []const u8) bool {
    for (masked) |m| if (std.mem.eql(u8, m, k)) return true;
    return false;
}

var line_buf: [65536]u8 = undefined;

fn field(id: c.GQuark, v: [*c]const c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const w: *std.ArrayList(u8) = @ptrCast(@alignCast(data));
    const k = z(c.g_quark_to_string(id));
    w.appendSlice(std.heap.c_allocator, ", ") catch {};
    w.appendSlice(std.heap.c_allocator, k) catch {};
    w.append(std.heap.c_allocator, '=') catch {};
    if (isMasked(k)) {
        w.append(std.heap.c_allocator, '*') catch {};
        return 1;
    }
    const s = c.gst_value_serialize(v);
    w.appendSlice(std.heap.c_allocator, z(s)) catch {};
    c.g_free(s);
    return 1;
}

fn maskRaw(raw_buf: []u8, msg: []const u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    outer: while (i < msg.len) {
        for (masked) |k| {
            if (std.mem.startsWith(u8, msg[i..], k) and (i == 0 or msg[i - 1] == ' ') and i + k.len < msg.len and msg[i + k.len] == '=') {
                const close = std.mem.indexOfScalarPos(u8, msg, i, ')') orelse break;
                const seg = msg[i .. close + 1];
                if (o + seg.len + 1 >= raw_buf.len) break :outer;
                @memcpy(raw_buf[o..][0..seg.len], seg);
                o += seg.len;
                raw_buf[o] = '*';
                o += 1;
                i = close + 1;
                while (i < msg.len and msg[i] != ',' and msg[i] != ';') i += 1;
                continue :outer;
            }
        }
        if (o + 1 >= raw_buf.len) break;
        raw_buf[o] = msg[i];
        o += 1;
        i += 1;
    }
    return raw_buf[0..o];
}

fn record(msg: []const u8) void {
    const dup = c.g_strndup(msg.ptr, msg.len);
    defer c.g_free(dup);
    const st = c.gst_structure_from_string(dup, null);
    if (st == null) {
        var buf: [16384]u8 = undefined;
        out("raw {s}", .{maskRaw(&buf, msg)});
        return;
    }
    defer c.gst_structure_free(st);
    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(std.heap.c_allocator);
    w.appendSlice(std.heap.c_allocator, z(c.gst_structure_get_name(st))) catch {};
    _ = c.gst_structure_foreach(st, field, &w);
    out("rec {s}", .{w.items});
}

fn logFn(cat: [*c]c.GstDebugCategory, _: c.GstDebugLevel, _: [*c]const u8, func: [*c]const u8, _: c.gint, _: [*c]c.GObject, m: ?*c.GstDebugMessage, _: c.gpointer) callconv(.c) void {
    const name = z(c.gst_debug_category_get_name(cat));
    const text = z(c.gst_debug_message_get(m));
    if (std.mem.eql(u8, name, "GST_TRACER")) {
        record(text);
        return;
    }
    const f = z(func);
    if (!std.mem.startsWith(u8, f, "do_") or std.mem.eql(u8, f, "do_stream_status")) return;
    var t = text;
    if (std.mem.indexOf(u8, t, ", ")) |i| t = t[i + 2 ..];
    var raw_buf: [16384]u8 = undefined;
    var o: usize = 0;
    var i: usize = 0;
    while (i < t.len and o + 1 < raw_buf.len) {
        if (std.mem.startsWith(u8, t[i..], "seq-num ")) {
            @memcpy(raw_buf[o..][0..9], "seq-num *");
            o += 9;
            i += 8;
            while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
            continue;
        }
        raw_buf[o] = t[i];
        o += 1;
        i += 1;
    }
    out("log {s} {s} {s}", .{ name, f, raw_buf[0..o] });
}

fn run(desc: [*:0]const u8) void {
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc, &err);
    if (p == null) {
        out("parse error", .{});
        return;
    }
    _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 10 * @as(u64, c.GST_SECOND), c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m != null) c.gst_message_unref(m);
    c.gst_object_unref(bus);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

fn leakActions() void {
    const active = c.gst_tracing_get_active_tracers();
    var l: ?*c.GList = active;
    while (l) |n| : (l = n.next) {
        const t = n.data;
        out("tracer {s}", .{z(c.g_type_name(c.G_TYPE_FROM_INSTANCE(t)))});
        if (!std.mem.eql(u8, z(c.g_type_name(c.G_TYPE_FROM_INSTANCE(t))), "GstLeaksTracer")) continue;
        var f: [*c]u8 = null;
        var refs: c.gboolean = 0;
        var logl: c.gboolean = 0;
        c.g_object_get(t, "filters", &f, "check-refs", &refs, "log-leaks-on-deinit", &logl, N);
        out("filters {s} check-refs {d} log {d}", .{ z(f), refs, logl });
        c.g_free(f);
        c.g_signal_emit_by_name(t, "activity-start-tracking");
        const b = c.gst_buffer_new_allocate(null, 5, null);
        const caps = c.gst_caps_from_string("audio/x-raw");
        var cp: ?*c.GstStructure = null;
        c.g_signal_emit_by_name(t, "activity-get-checkpoint", &cp);
        if (cp) |s| {
            out("checkpoint created {d} removed {d}", .{ c.gst_value_list_get_size(c.gst_structure_get_value(s, "objects-created-list")), c.gst_value_list_get_size(c.gst_structure_get_value(s, "objects-removed-list")) });
            c.gst_structure_free(s);
        }
        c.gst_caps_unref(caps);
        c.g_signal_emit_by_name(t, "activity-log-checkpoint");
        c.g_signal_emit_by_name(t, "activity-stop-tracking");
        var live: ?*c.GstStructure = null;
        c.g_signal_emit_by_name(t, "get-live-objects", &live);
        if (live) |s| {
            const list = c.gst_structure_get_value(s, "live-objects-list");
            out("live {d}", .{c.gst_value_list_get_size(list)});
        }
        c.g_signal_emit_by_name(t, "log-live-objects");
        c.gst_buffer_unref(b);
    }
    c.g_list_free_full(active, c.gst_object_unref);
}

fn child(stage: []const u8) void {
    _ = c.gst_debug_remove_log_function(c.gst_debug_log_default);
    c.gst_debug_add_log_function(logFn, null, null);
    c.gst_init(null, null);
    _ = c.gst_debug_remove_log_function(c.gst_debug_log_default);
    if (std.mem.eql(u8, stage, "leaks")) {
        leakActions();
        _ = c.gst_buffer_new_allocate(null, 7, null);
    } else if (std.mem.eql(u8, stage, "latency")) {
        run("fakesrc num-buffers=4 sizetype=fixed sizemax=16 ! identity ! queue ! fakesink sync=false");
    } else if (std.mem.eql(u8, stage, "factories")) {
        run("fakesrc num-buffers=1 ! typefind ! fakesink");
    } else run("fakesrc num-buffers=3 sizetype=fixed sizemax=8 ! identity ! fakesink");
    c.gst_deinit();
}

const Case = struct { name: []const u8, tracers: [:0]const u8, debug: [:0]const u8 };

const cases = [_]Case{
    .{ .name = "log", .tracers = "log", .debug = "GST_TRACER:7,GST_BUFFER:7,GST_BUFFER_LIST:7,GST_EVENT:7,GST_MESSAGE:7,GST_STATES:7,GST_PADS:7,GST_ELEMENT_PADS:7,GST_ELEMENT_FACTORY:7,query:7,bin:7" },
    .{ .name = "stats", .tracers = "stats", .debug = "GST_TRACER:7" },
    .{ .name = "rusage", .tracers = "rusage", .debug = "GST_TRACER:7" },
    .{ .name = "latency", .tracers = "latency(flags=pipeline+element+reported)", .debug = "GST_TRACER:7" },
    .{ .name = "factories", .tracers = "factories", .debug = "GST_TRACER:7" },
    .{ .name = "leaks", .tracers = "leaks(filters=GstBuffer,check-refs=true)", .debug = "GST_TRACER:7" },
    .{ .name = "dots", .tracers = "dots", .debug = "GST_TRACER:7" },
    .{ .name = "multi", .tracers = "stats;latency;leaks", .debug = "GST_TRACER:7" },
};

fn unptr(A: std.mem.Allocator, l: []const u8) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < l.len) {
        if (std.mem.startsWith(u8, l[i..], "stream-id=(string)")) {
            o.appendSlice(A, "stream-id=(string)ID") catch {};
            i += 18;
            while (i < l.len and l[i] != ',' and l[i] != ';' and l[i] != ' ') i += 1;
            continue;
        }
        if (i + 2 < l.len and l[i] == '0' and l[i + 1] == 'x' and std.ascii.isHex(l[i + 2])) {
            o.appendSlice(A, "PTR") catch {};
            i += 2;
            while (i < l.len and std.ascii.isHex(l[i])) i += 1;
            continue;
        }
        o.append(A, l[i]) catch {};
        i += 1;
    }
    return o.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn main() void {
    var cmd: [4096]u8 = undefined;
    const fd = c.open("/proc/self/cmdline", c.O_RDONLY);
    const got = if (fd >= 0) c.read(fd, &cmd, cmd.len) else 0;
    if (fd >= 0) _ = c.close(fd);
    if (got > 0) {
        const data = cmd[0..@intCast(got)];
        if (std.mem.indexOfScalar(u8, data, 0)) |e| {
            if (e + 1 < data.len) {
                const rest = data[e + 1 ..];
                const stage = rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse rest.len];
                if (stage.len != 0) return child(stage);
            }
        }
    }
    var exe: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return;
    exe[@intCast(n)] = 0;
    const dir = std.fs.path.dirname(exe[0..@intCast(n)]).?;
    var dbuf: [4096]u8 = undefined;
    const dots = std.fmt.bufPrintZ(&dbuf, "{s}/trdots", .{dir}) catch return;
    _ = c.g_mkdir_with_parents(dots.ptr, 0o755);
    const A = std.heap.c_allocator;
    for (cases) |k| {
        out("case {s}", .{k.name});
        _ = c.setenv("GST_TRACERS", k.tracers.ptr, 1);
        _ = c.setenv("GST_DEBUG", k.debug.ptr, 1);
        _ = c.setenv("GST_DEBUG_DUMP_DOT_DIR", dots.ptr, 1);
        _ = c.setenv("GST_DEBUG_FILE", "/dev/null", 1);
        const name = A.dupeZ(u8, k.name) catch return;
        var argv = [_:null]?[*:0]u8{ @ptrCast(&exe), name.ptr };
        var sout: [*c]u8 = null;
        var serr: [*c]u8 = null;
        var status: c.gint = 0;
        _ = c.g_spawn_sync(null, @ptrCast(&argv), null, 0, null, null, &sout, &serr, &status, null);
        var lines: std.ArrayList([]const u8) = .empty;
        var li = std.mem.splitScalar(u8, z(sout), '\n');
        while (li.next()) |l| if (l.len != 0) lines.append(A, unptr(A, l)) catch {};
        std.mem.sort([]const u8, lines.items, {}, lessThan);
        var prev: []const u8 = "";
        var count: usize = 0;
        for (lines.items) |l| {
            if (std.mem.eql(u8, l, prev)) {
                count += 1;
                continue;
            }
            if (prev.len != 0) out("  {d}x {s}", .{ count, prev });
            prev = l;
            count = 1;
        }
        if (prev.len != 0) out("  {d}x {s}", .{ count, prev });
        var ei = std.mem.splitScalar(u8, z(serr), '\n');
        while (ei.next()) |l| if (l.len != 0) out("  err {s}", .{l});
        out("  status {d}", .{status});
        c.g_free(sout);
        c.g_free(serr);
    }
}
