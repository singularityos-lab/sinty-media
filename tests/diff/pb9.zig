const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

const Stat = struct {
    name: []u8,
    caps: []u8 = &.{},
    buffers: u32 = 0,
    bytes: u64 = 0,
    hash: u64 = 0,
    eos: bool = false,
};

var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var stats: std.ArrayList(*Stat) = .empty;
var events: std.ArrayList([]const u8) = .empty;
var pipe_g: ?*c.GstElement = null;
var drained: u32 = 0;

fn objName(o: ?*anyopaque) []const u8 {
    const p = o orelse return "-";
    return z(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

fn note(comptime fmt: []const u8, args: anytype) void {
    c.g_mutex_lock(&lock);
    events.append(A, std.fmt.allocPrint(A, fmt, args) catch unreachable) catch unreachable;
    c.g_mutex_unlock(&lock);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn probe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const s: *Stat = @ptrCast(@alignCast(data));
    if (info[0].type & c.GST_PAD_PROBE_TYPE_BUFFER != 0) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(info[0].data));
        var map: c.GstMapInfo = undefined;
        if (c.gst_buffer_map(b, &map, c.GST_MAP_READ) != 0) {
            c.g_mutex_lock(&lock);
            if (s.buffers == 0) {
                const caps = c.gst_pad_get_current_caps(pad);
                const cs = c.gst_caps_to_string(caps);
                s.caps = A.dupe(u8, z(cs)) catch unreachable;
                c.g_free(cs);
                if (caps != null) c.gst_caps_unref(caps);
            }
            s.buffers += 1;
            s.bytes += map.size;
            s.hash = std.hash.Fnv1a_64.hash(map.data[0..map.size]) ^ (s.hash *% 31);
            c.g_mutex_unlock(&lock);
            c.gst_buffer_unmap(b, &map);
        }
    } else {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
        if (e[0].type == c.GST_EVENT_EOS) s.eos = true;
    }
    return c.GST_PAD_PROBE_OK;
}

fn padAdded(_: ?*c.GstElement, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    const s = A.create(Stat) catch unreachable;
    s.* = .{ .name = A.dupe(u8, objName(pad)) catch unreachable };
    c.g_mutex_lock(&lock);
    stats.append(A, s) catch unreachable;
    c.g_mutex_unlock(&lock);
    _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, s, null);
    const sink = c.gst_element_factory_make("fakesink", null);
    c.g_object_set(@ptrCast(sink), "sync", @as(c.gboolean, 0), "async", @as(c.gboolean, 0), N);
    _ = c.gst_bin_add(@ptrCast(@alignCast(pipe_g)), sink);
    _ = c.gst_element_sync_state_with_parent(sink);
    const sp = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_link(pad, sp);
    c.gst_object_unref(sp);
}

fn unknownType(_: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps, _: c.gpointer) callconv(.c) void {
    const s = c.gst_caps_to_string(caps);
    note("unknown-type {s}", .{z(s)});
    c.g_free(s);
}

fn onDrained(_: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    c.g_mutex_lock(&lock);
    drained += 1;
    c.g_mutex_unlock(&lock);
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
        c.GST_MESSAGE_ELEMENT => {
            const st = c.gst_message_get_structure(m);
            const name = z(c.gst_structure_get_name(st));
            if (std.mem.eql(u8, name, "stream-topology")) {
                note("topology {s}", .{topo(st)});
            } else {
                const str = c.gst_structure_to_string(st);
                note("element {s} {s}", .{ objName(m[0].src), z(str) });
                c.g_free(str);
            }
        },
        else => {},
    }
}

fn topo(st: ?*const c.GstStructure) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    walk(st, &buf);
    return buf.items;
}

fn walk(st: ?*const c.GstStructure, buf: *std.ArrayList(u8)) void {
    var caps: [*c]c.GstCaps = null;
    if (c.gst_structure_get(st, "caps", c.gst_caps_get_type(), &caps, N) != 0 and caps != null) {
        const s = c.gst_caps_to_string(caps);
        const full = z(s);
        const cut = if (std.mem.indexOfScalar(u8, full, ',')) |i| full[0..i] else full;
        buf.appendSlice(A, cut) catch unreachable;
        c.g_free(s);
        c.gst_caps_unref(caps);
    }
    if (c.gst_structure_has_field(st, "pad") != 0) buf.appendSlice(A, "[pad]") catch unreachable;
    const next = c.gst_structure_get_value(st, "next") orelse return;
    if (next.*.g_type == c.gst_structure_get_type()) {
        buf.appendSlice(A, " > ") catch unreachable;
        walk(c.gst_value_get_structure(next), buf);
    } else if (next.*.g_type == c.gst_value_list_get_type()) {
        buf.appendSlice(A, " > {") catch unreachable;
        var i: c.guint = 0;
        while (i < c.gst_value_list_get_size(next)) : (i += 1) {
            if (i > 0) buf.appendSlice(A, " | ") catch unreachable;
            walk(c.gst_value_get_structure(c.gst_value_list_get_value(next, i)), buf);
        }
        buf.appendSlice(A, "}") catch unreachable;
    }
}

fn tree(e: ?*c.GstElement, depth: usize) void {
    const f = c.gst_element_get_factory(e);
    var ind: [40]u8 = @splat(' ');
    out("  {s}{s}", .{ ind[0 .. depth * 2], if (f != null) objName(f) else "-" });
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(e)), c.gst_bin_get_type()) == 0) return;
    var kids: std.ArrayList([]const u8) = .empty;
    var l = @as(*c.GstBin, @ptrCast(@alignCast(e))).children;
    while (l != null) : (l = l[0].next) {
        const k: ?*c.GstElement = @ptrCast(@alignCast(l[0].data));
        const kf = c.gst_element_get_factory(k);
        kids.append(A, if (kf != null) objName(kf) else "-") catch unreachable;
    }
    std.mem.sort([]const u8, kids.items, {}, lessThan);
    for (kids.items) |k| out("  {s}  {s}", .{ ind[0 .. depth * 2], k });
    kids.deinit(A);
}

const Opts = struct {
    file: [:0]const u8,
    caps: ?[:0]const u8 = null,
    expose_all: bool = true,
    topology: bool = false,
    buffering: bool = false,
};

fn scenario(title: []const u8, o: Opts) void {
    if (std.c.getenv("PB_ONLY")) |only| if (std.mem.indexOf(u8, title, std.mem.span(only)) == null) return;
    out("scenario {s}", .{title});
    stats.clearRetainingCapacity();
    events.clearRetainingCapacity();
    drained = 0;
    const pipe = c.gst_pipeline_new("pipe");
    pipe_g = pipe;
    const src = c.gst_element_factory_make("filesrc", null);
    c.g_object_set(@ptrCast(src), "location", o.file.ptr, N);
    const db = c.gst_element_factory_make("decodebin", "db");
    if (o.caps) |cs| {
        const caps = c.gst_caps_from_string(cs.ptr);
        c.g_object_set(@ptrCast(db), "caps", caps, N);
        c.gst_caps_unref(caps);
    }
    c.g_object_set(@ptrCast(db), "expose-all-streams", @as(c.gboolean, @intFromBool(o.expose_all)), "post-stream-topology", @as(c.gboolean, @intFromBool(o.topology)), "use-buffering", @as(c.gboolean, @intFromBool(o.buffering)), N);
    _ = c.gst_bin_add(@ptrCast(@alignCast(pipe)), src);
    _ = c.gst_bin_add(@ptrCast(@alignCast(pipe)), db);
    _ = c.gst_element_link(src, db);
    _ = c.g_signal_connect_data(db, "pad-added", @ptrCast(&padAdded), null, null, 0);
    _ = c.g_signal_connect_data(db, "unknown-type", @ptrCast(&unknownType), null, null, 0);
    _ = c.g_signal_connect_data(db, "drained", @ptrCast(&onDrained), null, null, 0);
    const bus = c.gst_element_get_bus(pipe);
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    var buffering_seen = false;
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT | c.GST_MESSAGE_BUFFERING);
        if (m == null) {
            out("  timeout", .{});
            break;
        }
        if (m[0].type == c.GST_MESSAGE_EOS) {
            c.gst_mini_object_unref(@ptrCast(m));
            out("  eos", .{});
            break;
        }
        if (m[0].type == c.GST_MESSAGE_BUFFERING) {
            buffering_seen = true;
            c.gst_mini_object_unref(@ptrCast(m));
            continue;
        }
        describe(m);
        const e = m[0].type == c.GST_MESSAGE_ERROR;
        c.gst_mini_object_unref(@ptrCast(m));
        if (e) break;
    }
    out("  buffering messages {d}", .{@intFromBool(buffering_seen)});
    tree(db, 0);
    c.g_mutex_lock(&lock);
    std.mem.sort(*Stat, stats.items, {}, struct {
        fn lt(_: void, a: *Stat, b: *Stat) bool {
            return std.mem.lessThan(u8, a.caps, b.caps);
        }
    }.lt);
    for (stats.items) |s| out("  pad caps {s}\n    buffers {d} bytes {d} hash {x} eos {d}", .{ s.caps, s.buffers, s.bytes, s.hash, @intFromBool(s.eos) });
    std.mem.sort([]const u8, events.items, {}, lessThan);
    for (events.items) |e| out("  {s}", .{e});
    out("  drained {d}", .{@intFromBool(drained > 0)});
    c.g_mutex_unlock(&lock);
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(pipe);
}

fn make(path: [:0]const u8, comptime desc: []const u8) void {
    if (std.c.access(path.ptr, 0) == 0) return;
    var err: [*c]c.GError = null;
    const d = std.fmt.allocPrintSentinel(A, desc ++ " ! filesink location={s}", .{path}, 0) catch unreachable;
    const p = c.gst_parse_launch(d.ptr, &err);
    A.free(d);
    if (p == null) {
        out("make failed {s}", .{z(err[0].message)});
        return;
    }
    _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 20 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m != null) c.gst_mini_object_unref(@ptrCast(m));
    c.gst_object_unref(bus);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

fn file(dir: []const u8, name: []const u8) [:0]const u8 {
    return std.fmt.allocPrintSentinel(A, "{s}/zig-out/{s}", .{ dir, name }, 0) catch unreachable;
}

fn writeFile(path: [:0]const u8, body: []const u8) void {
    if (std.c.access(path.ptr, 0) == 0) return;
    const f = std.c.fopen(path.ptr, "w");
    _ = std.c.fwrite(body.ptr, 1, body.len, f.?);
    _ = std.c.fclose(f.?);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("decodebin");
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return;
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(cwd)));
    const ogg = file(dir, "pb7.ogg");
    const mkv = file(dir, "pb7.mkv");
    const avi = file(dir, "pb7.avi");
    const wav = file(dir, "pb7.wav");
    const txt = file(dir, "pb7.txt");
    const junk = file(dir, "pb9.bin");
    make(ogg, "audiotestsrc num-buffers=30 ! audio/x-raw,rate=44100,channels=1 ! vorbisenc quality=0.1 ! oggmux");
    make(mkv, "videotestsrc num-buffers=10 ! video/x-raw,width=64,height=48,framerate=10/1 ! vp8enc deadline=1 ! matroskamux name=m audiotestsrc num-buffers=20 ! opusenc ! m. m.");
    make(avi, "videotestsrc num-buffers=5 ! video/x-raw,width=64,height=48,framerate=5/1 ! jpegenc ! avimux");
    make(wav, "audiotestsrc num-buffers=10 ! wavenc");
    writeFile(txt, "hello this is plain text\nand more text here\n");
    var noise: [4096]u8 = undefined;
    var seed: u32 = 12345;
    for (&noise) |*b| {
        seed = seed *% 1103515245 +% 12345;
        b.* = @truncate(seed >> 16);
    }
    writeFile(junk, &noise);
    scenario("ogg", .{ .file = ogg });
    scenario("mkv", .{ .file = mkv });
    scenario("wav", .{ .file = wav });
    scenario("avi", .{ .file = avi });
    scenario("text file", .{ .file = txt });
    scenario("junk", .{ .file = junk });
    scenario("mkv caps encoded", .{ .file = mkv, .caps = "video/x-vp8; audio/x-opus" });
    scenario("mkv audio raw only", .{ .file = mkv, .caps = "audio/x-raw", .expose_all = false });
    scenario("mkv topology", .{ .file = mkv, .topology = true });
    scenario("ogg buffering", .{ .file = ogg, .buffering = true });
    out("done", .{});
}
