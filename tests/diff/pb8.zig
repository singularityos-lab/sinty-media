const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

const Sink = struct {
    name: []const u8,
    buffers: u32 = 0,
    bytes: u64 = 0,
    hash: u64 = 0,
};

var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var sinks: [3]Sink = .{ .{ .name = "audio" }, .{ .name = "video" }, .{ .name = "text" } };
var setups: std.ArrayList([]const u8) = .empty;
var events: std.ArrayList([]const u8) = .empty;
var next_uri: ?[:0]const u8 = null;
var notifies: [2]u32 = .{ 0, 0 };
var only_video = false;
var pb_g: ?*c.GstElement = null;

fn objName(o: ?*anyopaque) []const u8 {
    const p = o orelse return "-";
    return z(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

fn note(comptime fmt: []const u8, args: anytype) void {
    c.g_mutex_lock(&lock);
    events.append(A, std.fmt.allocPrint(A, fmt, args) catch unreachable) catch unreachable;
    c.g_mutex_unlock(&lock);
}

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, _: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const s: *Sink = @ptrCast(@alignCast(data));
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &map, c.GST_MAP_READ) == 0) return;
    c.g_mutex_lock(&lock);
    s.buffers += 1;
    s.bytes += map.size;
    s.hash = std.hash.Fnv1a_64.hash(map.data[0..map.size]) ^ (s.hash *% 31);
    c.g_mutex_unlock(&lock);
    c.gst_buffer_unmap(b, &map);
}

fn fakesink(s: *Sink) ?*c.GstElement {
    const e = c.gst_element_factory_make("fakesink", null);
    c.g_object_set(@ptrCast(e), "sync", @as(c.gboolean, 0), "signal-handoffs", @as(c.gboolean, 1), N);
    _ = c.g_signal_connect_data(e, "handoff", @ptrCast(&handoff), s, null, 0);
    return e;
}

fn elementSetup(_: ?*c.GstElement, e: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    const f = c.gst_element_get_factory(e);
    c.g_mutex_lock(&lock);
    setups.append(A, A.dupe(u8, if (f != null) objName(f) else "-") catch unreachable) catch unreachable;
    c.g_mutex_unlock(&lock);
}

fn sourceSetup(_: ?*c.GstElement, src: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    note("source-setup {s}", .{objName(c.gst_element_get_factory(src))});
}

fn aboutToFinish(e: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    c.g_mutex_lock(&lock);
    const nx = next_uri;
    next_uri = null;
    events.append(A, A.dupe(u8, "about-to-finish") catch unreachable) catch unreachable;
    c.g_mutex_unlock(&lock);
    if (nx) |u| c.g_object_set(@ptrCast(e), "uri", u.ptr, N);
}

fn notifyVolume(_: ?*c.GObject, _: ?*c.GParamSpec, _: c.gpointer) callconv(.c) void {
    notifies[0] += 1;
}

fn notifyMute(_: ?*c.GObject, _: ?*c.GParamSpec, _: c.gpointer) callconv(.c) void {
    notifies[1] += 1;
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
        c.GST_MESSAGE_STREAM_COLLECTION, c.GST_MESSAGE_STREAMS_SELECTED => {
            var col: ?*c.GstStreamCollection = null;
            if (m[0].type == c.GST_MESSAGE_STREAM_COLLECTION) c.gst_message_parse_stream_collection(m, &col) else c.gst_message_parse_streams_selected(m, &col);
            out("  {s} size {d}", .{ z(c.gst_message_type_get_name(m[0].type)), c.gst_stream_collection_get_size(col) });
            var i: c.guint = 0;
            while (i < c.gst_stream_collection_get_size(col)) : (i += 1) {
                const x = c.gst_stream_collection_get_stream(col, i);
                out("    stream {s}", .{z(c.gst_stream_type_get_name(c.gst_stream_get_stream_type(x)))});
            }
            if (m[0].type == c.GST_MESSAGE_STREAMS_SELECTED) {
                var names: std.ArrayList([]const u8) = .empty;
                i = 0;
                while (i < c.gst_message_streams_selected_get_size(m)) : (i += 1) {
                    const x = c.gst_message_streams_selected_get_stream(m, i);
                    names.append(A, A.dupe(u8, z(c.gst_stream_type_get_name(c.gst_stream_get_stream_type(x)))) catch unreachable) catch unreachable;
                    c.gst_object_unref(x);
                }
                std.mem.sort([]const u8, names.items, {}, lessThan);
                for (names.items) |n| out("    selected {s}", .{n});
                names.deinit(A);
            } else if (only_video) {
                var list: [*c]c.GList = null;
                i = 0;
                while (i < c.gst_stream_collection_get_size(col)) : (i += 1) {
                    const x = c.gst_stream_collection_get_stream(col, i);
                    if ((c.gst_stream_get_stream_type(x) & c.GST_STREAM_TYPE_VIDEO) != 0) list = c.g_list_append(list, @constCast(c.gst_stream_get_stream_id(x)));
                }
                if (list != null) {
                    out("  send select-streams {d}", .{@intFromBool(c.gst_element_send_event(pb_g, c.gst_event_new_select_streams(list)) != 0)});
                    c.g_list_free(list);
                }
            }
            c.gst_object_unref(col);
        },
        else => {},
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn tree(e: ?*c.GstElement, depth: usize) void {
    const f = c.gst_element_get_factory(e);
    var ind: [40]u8 = @splat(' ');
    out("  {s}{s}", .{ ind[0 .. depth * 2], if (f != null) objName(f) else "-" });
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(e)), c.gst_bin_get_type()) == 0) return;
    var kids: std.ArrayList([]const u8) = .empty;
    var bins: std.ArrayList(?*c.GstElement) = .empty;
    var l = @as(*c.GstBin, @ptrCast(@alignCast(e))).children;
    while (l != null) : (l = l[0].next) {
        const k: ?*c.GstElement = @ptrCast(@alignCast(l[0].data));
        const kf = c.gst_element_get_factory(k);
        if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(k)), c.gst_bin_get_type()) != 0) {
            bins.append(A, k) catch unreachable;
        } else kids.append(A, if (kf != null) objName(kf) else "-") catch unreachable;
    }
    std.mem.sort(?*c.GstElement, bins.items, {}, struct {
        fn lt(_: void, a: ?*c.GstElement, b: ?*c.GstElement) bool {
            return std.mem.lessThan(u8, objName(a), objName(b));
        }
    }.lt);
    for (bins.items) |b| tree(b, depth + 1);
    std.mem.sort([]const u8, kids.items, {}, lessThan);
    for (kids.items) |k| out("  {s}  {s}", .{ ind[0 .. depth * 2], k });
    kids.deinit(A);
    bins.deinit(A);
}

fn tail(p: [*c]const u8) []const u8 {
    const s = z(p);
    return if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
}

fn props(e: ?*c.GstElement) void {
    var uri: [*c]u8 = null;
    var cur: [*c]u8 = null;
    var flags: c.guint = 0;
    var vol: f64 = 0;
    var mute: c.gboolean = 0;
    var far: c.gboolean = 0;
    var sample: ?*c.GstSample = null;
    c.g_object_get(@ptrCast(e), "uri", &uri, "current-uri", &cur, "flags", &flags, "volume", &vol, "mute", &mute, "force-aspect-ratio", &far, "sample", &sample, N);
    out("  props uri {s} current {s} flags {x} volume {d:.2} mute {d} far {d} sample {d}", .{ tail(uri), tail(cur), flags, vol, mute, far, @intFromBool(sample != null) });
    if (sample) |x| c.gst_sample_unref(x);
    c.g_free(uri);
    c.g_free(cur);
}

const Opts = struct {
    uri: ?[]const u8 = null,
    suburi: ?[]const u8 = null,
    next: ?[]const u8 = null,
    flags: ?c.guint = null,
    only_video: bool = false,
    volume: bool = false,
};

fn scenario(title: []const u8, o: Opts) void {
    if (std.c.getenv("PB_ONLY")) |only| if (std.mem.indexOf(u8, title, std.mem.span(only)) == null) return;
    out("scenario {s}", .{title});
    setups.clearRetainingCapacity();
    events.clearRetainingCapacity();
    for (&sinks) |*s| s.* = .{ .name = s.name };
    notifies = .{ 0, 0 };
    only_video = o.only_video;
    next_uri = if (o.next) |x| A.dupeZ(u8, x) catch unreachable else null;
    const pb = c.gst_element_factory_make("playbin3", null);
    pb_g = pb;
    _ = c.g_signal_connect_data(pb, "element-setup", @ptrCast(&elementSetup), null, null, 0);
    _ = c.g_signal_connect_data(pb, "source-setup", @ptrCast(&sourceSetup), null, null, 0);
    _ = c.g_signal_connect_data(pb, "about-to-finish", @ptrCast(&aboutToFinish), null, null, 0);
    _ = c.g_signal_connect_data(pb, "notify::volume", @ptrCast(&notifyVolume), null, null, 0);
    _ = c.g_signal_connect_data(pb, "notify::mute", @ptrCast(&notifyMute), null, null, 0);
    c.g_object_set(@ptrCast(pb), "audio-sink", fakesink(&sinks[0]), "video-sink", fakesink(&sinks[1]), "text-sink", fakesink(&sinks[2]), N);
    if (o.uri) |x| c.g_object_set(@ptrCast(pb), "uri", (A.dupeZ(u8, x) catch unreachable).ptr, N);
    if (o.suburi) |x| c.g_object_set(@ptrCast(pb), "suburi", (A.dupeZ(u8, x) catch unreachable).ptr, N);
    if (o.flags) |f| c.g_object_set(@ptrCast(pb), "flags", f, N);
    if (o.volume) c.g_object_set(@ptrCast(pb), "volume", @as(f64, 0.5), "mute", @as(c.gboolean, 1), N);
    props(pb);
    const bus = c.gst_element_get_bus(pb);
    out("  playing {d}", .{c.gst_element_set_state(pb, c.GST_STATE_PLAYING)});
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_STREAM_COLLECTION | c.GST_MESSAGE_STREAMS_SELECTED);
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
    var pos: i64 = -1;
    _ = c.gst_element_query_position(pb, c.GST_FORMAT_TIME, &pos);
    out("  position {d}", .{@intFromBool(pos > 0)});
    props(pb);
    tree(pb, 0);
    c.g_mutex_lock(&lock);
    for (sinks) |s| out("  sink {s} buffers {d} bytes {d} hash {x}", .{ s.name, s.buffers, s.bytes, s.hash });
    std.mem.sort([]const u8, setups.items, {}, lessThan);
    var i: usize = 0;
    while (i < setups.items.len) {
        var j = i;
        while (j < setups.items.len and std.mem.eql(u8, setups.items[i], setups.items[j])) j += 1;
        out("  element-setup {s} x{d}", .{ setups.items[i], j - i });
        i = j;
    }
    std.mem.sort([]const u8, events.items, {}, lessThan);
    for (events.items) |e| out("  {s}", .{e});
    c.g_mutex_unlock(&lock);
    out("  notify volume {d} mute {d}", .{ @intFromBool(notifies[0] > 0), @intFromBool(notifies[1] > 0) });
    out("  null {d}", .{c.gst_element_set_state(pb, c.GST_STATE_NULL)});
    pb_g = null;
    c.gst_object_unref(bus);
    c.gst_object_unref(pb);
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

fn fileUri(p: [:0]const u8) []const u8 {
    return std.fmt.allocPrint(A, "file://{s}", .{p}) catch unreachable;
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("playbin3");
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return;
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(cwd)));
    const ogg = file(dir, "pb7.ogg");
    const mkv = file(dir, "pb7.mkv");
    const avi = file(dir, "pb7.avi");
    const wav = file(dir, "pb7.wav");
    const srt = file(dir, "pb7.srt");
    make(ogg, "audiotestsrc num-buffers=30 ! audio/x-raw,rate=44100,channels=1 ! vorbisenc quality=0.1 ! oggmux");
    make(mkv, "videotestsrc num-buffers=10 ! video/x-raw,width=64,height=48,framerate=10/1 ! vp8enc deadline=1 ! matroskamux name=m audiotestsrc num-buffers=20 ! opusenc ! m. m.");
    make(avi, "videotestsrc num-buffers=5 ! video/x-raw,width=64,height=48,framerate=5/1 ! jpegenc ! avimux");
    make(wav, "audiotestsrc num-buffers=10 ! wavenc");
    if (std.c.access(srt.ptr, 0) != 0) {
        const f = std.c.fopen(srt.ptr, "w");
        const body = "1\n00:00:00,000 --> 00:00:00,400\nfirst line\n\n2\n00:00:00,500 --> 00:00:00,900\nsecond line\n\n";
        _ = std.c.fwrite(body.ptr, 1, body.len, f.?);
        _ = std.c.fclose(f.?);
    }
    scenario("no uri", .{});
    scenario("ogg", .{ .uri = fileUri(ogg) });
    scenario("mkv", .{ .uri = fileUri(mkv) });
    scenario("mkv video flag only", .{ .uri = fileUri(mkv), .flags = 1 });
    scenario("mkv select video", .{ .uri = fileUri(mkv), .only_video = true });
    scenario("avi with srt", .{ .uri = fileUri(avi), .suburi = fileUri(srt) });
    scenario("gapless ogg then wav", .{ .uri = fileUri(ogg), .next = fileUri(wav) });
    scenario("volume and mute", .{ .uri = fileUri(wav), .volume = true });
    out("done", .{});
}
