const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

const Stat = struct {
    name: []u8,
    caps: []u8,
    stream: []u8,
    buffers: u32 = 0,
    bytes: u64 = 0,
    hash: u64 = 0,
    eos: bool = false,
};

var stats: std.ArrayList(*Stat) = .empty;
var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var pipe_g: ?*c.GstElement = null;
var select_mode: u8 = 0;
var selects: std.ArrayList([]u8) = .empty;
var dbin_g: ?*c.GstElement = null;

fn objName(o: ?*anyopaque) []const u8 {
    const p = o orelse return "-";
    return z(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

fn probe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const st: *Stat = @ptrCast(@alignCast(data));
    if (info[0].type & c.GST_PAD_PROBE_TYPE_BUFFER != 0) {
        if (st.buffers == 0) {
            const caps = c.gst_pad_get_current_caps(pad);
            const cs = c.gst_caps_to_string(caps);
            A.free(st.caps);
            st.caps = A.dupe(u8, z(cs)) catch unreachable;
            c.g_free(cs);
            if (caps != null) c.gst_caps_unref(caps);
        }
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(info[0].data));
        var map: c.GstMapInfo = undefined;
        if (c.gst_buffer_map(b, &map, c.GST_MAP_READ) != 0) {
            c.g_mutex_lock(&lock);
            st.buffers += 1;
            st.bytes += map.size;
            st.hash = std.hash.Fnv1a_64.hash(map.data[0..map.size]) ^ (st.hash *% 31);
            c.g_mutex_unlock(&lock);
            c.gst_buffer_unmap(b, &map);
        }
    } else {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
        if (e[0].type == c.GST_EVENT_EOS) st.eos = true;
    }
    return c.GST_PAD_PROBE_OK;
}

fn padAdded(_: ?*c.GstElement, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    if (c.gst_pad_get_direction(pad) != c.GST_PAD_SRC) return;
    const caps = c.gst_pad_get_current_caps(pad);
    const cs = c.gst_caps_to_string(caps);
    const stream = c.gst_pad_get_stream(pad);
    var sdesc: []u8 = undefined;
    if (stream) |x| {
        const scaps = c.gst_stream_get_caps(x);
        const scs = c.gst_caps_to_string(scaps);
        sdesc = std.fmt.allocPrint(A, "type {s} flags {d} caps {s}", .{ z(c.gst_stream_type_get_name(c.gst_stream_get_stream_type(x))), c.gst_stream_get_stream_flags(x), z(scs) }) catch unreachable;
        c.g_free(scs);
        if (scaps != null) c.gst_caps_unref(scaps);
        c.gst_object_unref(x);
    } else sdesc = A.dupe(u8, "none") catch unreachable;
    const st = A.create(Stat) catch unreachable;
    st.* = .{ .name = A.dupe(u8, objName(pad)) catch unreachable, .caps = A.dupe(u8, z(cs)) catch unreachable, .stream = sdesc };
    c.g_free(cs);
    if (caps != null) c.gst_caps_unref(caps);
    c.g_mutex_lock(&lock);
    stats.append(A, st) catch unreachable;
    c.g_mutex_unlock(&lock);
    const sink = c.gst_element_factory_make("fakesink", null);
    c.g_object_set(@ptrCast(sink), "sync", @as(c.gboolean, 0), N);
    _ = c.gst_bin_add(@ptrCast(@alignCast(pipe_g)), sink);
    const sp = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(sp, c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, st, null);
    _ = c.gst_pad_link(pad, sp);
    c.gst_object_unref(sp);
    _ = c.gst_element_sync_state_with_parent(sink);
}

fn selectStream(_: ?*c.GstElement, _: ?*c.GstStreamCollection, stream: ?*c.GstStream, _: c.gpointer) callconv(.c) c.gint {
    const t = c.gst_stream_get_stream_type(stream);
    if (select_mode == 2) return -1;
    c.g_mutex_lock(&lock);
    selects.append(A, std.fmt.allocPrint(A, "select-stream {s} {s}", .{ z(c.gst_stream_type_get_name(t)), z(c.gst_stream_get_stream_id(stream)) }) catch unreachable) catch unreachable;
    c.g_mutex_unlock(&lock);
    if (select_mode == 1) return if ((t & c.GST_STREAM_TYPE_AUDIO) != 0) 1 else 0;
    return -1;
}

var next_uri: ?[:0]const u8 = null;

fn aboutToFinish(e: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    c.g_mutex_lock(&lock);
    selects.append(A, A.dupe(u8, "about-to-finish") catch unreachable) catch unreachable;
    const nx = next_uri;
    next_uri = null;
    c.g_mutex_unlock(&lock);
    if (nx) |u| c.g_object_set(@ptrCast(e), "uri", u.ptr, N);
}

fn sourceSetup(_: ?*c.GstElement, src: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    c.g_mutex_lock(&lock);
    selects.append(A, std.fmt.allocPrint(A, "source-setup {s}", .{objName(c.gst_element_get_factory(src))}) catch unreachable) catch unreachable;
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
        c.GST_MESSAGE_STREAM_COLLECTION, c.GST_MESSAGE_STREAMS_SELECTED => {
            var col: ?*c.GstStreamCollection = null;
            if (m[0].type == c.GST_MESSAGE_STREAM_COLLECTION) c.gst_message_parse_stream_collection(m, &col) else c.gst_message_parse_streams_selected(m, &col);
            out("  {s} from {s} size {d}", .{ z(c.gst_message_type_get_name(m[0].type)), objName(m[0].src), c.gst_stream_collection_get_size(col) });
            var i: c.guint = 0;
            while (i < c.gst_stream_collection_get_size(col)) : (i += 1) {
                const x = c.gst_stream_collection_get_stream(col, i);
                out("    stream {s} {s} flags {d}", .{ z(c.gst_stream_type_get_name(c.gst_stream_get_stream_type(x))), z(c.gst_stream_get_stream_id(x)), c.gst_stream_get_stream_flags(x) });
            }
            if (m[0].type == c.GST_MESSAGE_STREAMS_SELECTED) {
                var ids: std.ArrayList([]const u8) = .empty;
                i = 0;
                while (i < c.gst_message_streams_selected_get_size(m)) : (i += 1) {
                    const x = c.gst_message_streams_selected_get_stream(m, i);
                    ids.append(A, A.dupe(u8, z(c.gst_stream_get_stream_id(x))) catch unreachable) catch unreachable;
                    c.gst_object_unref(x);
                }
                std.mem.sort([]const u8, ids.items, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.lt);
                for (ids.items) |id| out("    selected {s}", .{id});
                ids.deinit(A);
            } else if (select_mode == 2 and dbin_g != null) {
                var list: [*c]c.GList = null;
                i = 0;
                while (i < c.gst_stream_collection_get_size(col)) : (i += 1) {
                    const x = c.gst_stream_collection_get_stream(col, i);
                    if ((c.gst_stream_get_stream_type(x) & c.GST_STREAM_TYPE_VIDEO) != 0) list = c.g_list_append(list, @constCast(c.gst_stream_get_stream_id(x)));
                }
                if (list != null) {
                    _ = c.gst_element_send_event(dbin_g, c.gst_event_new_select_streams(list));
                    c.g_list_free(list);
                }
            }
            c.gst_object_unref(col);
        },
        else => {
            const str = c.gst_structure_to_string(c.gst_message_get_structure(m));
            out("  element {s} {s}", .{ objName(m[0].src), z(str) });
            c.g_free(str);
        },
    }
}

fn tree(e: ?*c.GstElement, depth: usize) void {
    const f = c.gst_element_get_factory(e);
    var ind: [32]u8 = @splat(' ');
    out("  {s}{s}", .{ ind[0 .. depth * 2], if (f != null) objName(f) else "-" });
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(e)), c.gst_bin_get_type()) == 0) return;
    var kids: std.ArrayList([]const u8) = .empty;
    var l = @as(*c.GstBin, @ptrCast(@alignCast(e))).children;
    while (l != null) : (l = l[0].next) {
        const k: ?*c.GstElement = @ptrCast(@alignCast(l[0].data));
        const kf = c.gst_element_get_factory(k);
        if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(k)), c.gst_bin_get_type()) != 0) {
            tree(k, depth + 1);
        } else kids.append(A, if (kf != null) objName(kf) else "-") catch unreachable;
    }
    std.mem.sort([]const u8, kids.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (kids.items) |k| out("  {s}  {s}", .{ ind[0 .. depth * 2], k });
    kids.deinit(A);
}

const Opts = struct {
    uri: ?[]const u8 = null,
    suburi: ?[]const u8 = null,
    next: ?[]const u8 = null,
    mode: u8 = 0,
    caps: ?[:0]const u8 = null,
};

fn props(e: ?*c.GstElement) void {
    var uri: [*c]u8 = null;
    var cur: [*c]u8 = null;
    var sub: [*c]u8 = null;
    var csub: [*c]u8 = null;
    c.g_object_get(@ptrCast(e), "uri", &uri, "current-uri", &cur, "suburi", &sub, "current-suburi", &csub, N);
    out("  props uri {s} current {s} suburi {s} current-suburi {s}", .{ tail(uri), tail(cur), tail(sub), tail(csub) });
    c.g_free(uri);
    c.g_free(cur);
    c.g_free(sub);
    c.g_free(csub);
}

fn tail(p: [*c]const u8) []const u8 {
    const s = z(p);
    return if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
}

fn dup(s: ?[]const u8) ?[:0]const u8 {
    const x = s orelse return null;
    return A.dupeZ(u8, x) catch unreachable;
}

fn waitText() void {
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        c.g_mutex_lock(&lock);
        var seen = false;
        for (stats.items) |s| {
            if (std.mem.startsWith(u8, s.name, "text")) seen = true;
        }
        c.g_mutex_unlock(&lock);
        if (seen) break;
        c.g_usleep(10 * 1000);
    }
    c.g_usleep(200 * 1000);
}

fn scenario(title: []const u8, o: Opts) void {
    if (std.c.getenv("PB_ONLY")) |only| if (std.mem.indexOf(u8, title, std.mem.span(only)) == null) return;
    out("scenario {s}", .{title});
    stats.clearRetainingCapacity();
    selects.clearRetainingCapacity();
    select_mode = o.mode;
    next_uri = dup(o.next);
    const pipe = c.gst_pipeline_new("pipe");
    pipe_g = pipe;
    const bin: *c.GstBin = @ptrCast(@alignCast(pipe));
    const db = c.gst_element_factory_make("uridecodebin3", "udb");
    dbin_g = db;
    if (dup(o.uri)) |u| c.g_object_set(@ptrCast(db), "uri", u.ptr, N);
    if (dup(o.suburi)) |u| c.g_object_set(@ptrCast(db), "suburi", u.ptr, N);
    if (o.caps) |cs| {
        const caps = c.gst_caps_from_string(cs.ptr);
        c.g_object_set(@ptrCast(db), "caps", caps, N);
        c.gst_caps_unref(caps);
    }
    _ = c.gst_bin_add(bin, db);
    _ = c.g_signal_connect_data(db, "pad-added", @ptrCast(&padAdded), null, null, 0);
    _ = c.g_signal_connect_data(db, "select-stream", @ptrCast(&selectStream), null, null, 0);
    _ = c.g_signal_connect_data(db, "about-to-finish", @ptrCast(&aboutToFinish), null, null, 0);
    _ = c.g_signal_connect_data(db, "source-setup", @ptrCast(&sourceSetup), null, null, 0);
    props(db);
    const bus = c.gst_element_get_bus(pipe);
    out("  playing ok {d}", .{@intFromBool(c.gst_element_set_state(pipe, c.GST_STATE_PLAYING) != c.GST_STATE_CHANGE_FAILURE)});
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT | c.GST_MESSAGE_STREAM_COLLECTION | c.GST_MESSAGE_STREAMS_SELECTED);
        if (m == null) {
            out("  timeout", .{});
            break;
        }
        if (m[0].type == c.GST_MESSAGE_EOS) {
            c.gst_mini_object_unref(@ptrCast(m));
            if (o.suburi != null) {
                waitText();
                while (c.gst_bus_pop_filtered(bus, c.GST_MESSAGE_STREAM_COLLECTION | c.GST_MESSAGE_STREAMS_SELECTED)) |r| {
                    describe(r);
                    c.gst_mini_object_unref(@ptrCast(r));
                }
            }
            out("  eos", .{});
            break;
        }
        describe(m);
        const e = m[0].type == c.GST_MESSAGE_ERROR;
        c.gst_mini_object_unref(@ptrCast(m));
        if (e) break;
    }
    props(db);
    tree(db, 0);
    c.g_mutex_lock(&lock);
    std.mem.sort(*Stat, stats.items, {}, struct {
        fn lt(_: void, a: *Stat, b: *Stat) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    for (stats.items) |s| out("  pad {s} caps {s}\n    stream {s}\n    buffers {d} bytes {d} hash {x} eos {d}", .{ s.name, s.caps, s.stream, s.buffers, s.bytes, s.hash, @intFromBool(s.eos) });
    std.mem.sort([]u8, selects.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (selects.items) |s| out("  {s}", .{s});
    c.g_mutex_unlock(&lock);
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    props(db);
    dbin_g = null;
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

pub fn main() void {
    c.gst_init(null, null);
    ins.element("uridecodebin3");
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return;
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(cwd)));
    const ogg = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb7.ogg", .{dir}, 0) catch unreachable;
    const mkv = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb7.mkv", .{dir}, 0) catch unreachable;
    const flac = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb7.flac", .{dir}, 0) catch unreachable;
    const mp3 = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb7.mp3", .{dir}, 0) catch unreachable;
    const avi = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb7.avi", .{dir}, 0) catch unreachable;
    const wav = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb7.wav", .{dir}, 0) catch unreachable;
    const txt = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb7.txt", .{dir}, 0) catch unreachable;
        make(ogg, "audiotestsrc num-buffers=30 ! audio/x-raw,rate=44100,channels=1 ! vorbisenc quality=0.1 ! oggmux");
    make(mkv, "videotestsrc num-buffers=10 ! video/x-raw,width=64,height=48,framerate=10/1 ! vp8enc deadline=1 ! matroskamux name=m audiotestsrc num-buffers=20 ! opusenc ! m. m.");
    make(flac, "audiotestsrc num-buffers=20 ! flacenc");
    make(mp3, "audiotestsrc num-buffers=30 ! lamemp3enc ! xingmux");
    make(avi, "videotestsrc num-buffers=5 ! video/x-raw,width=64,height=48,framerate=5/1 ! jpegenc ! avimux");
    make(wav, "audiotestsrc num-buffers=10 ! wavenc");
    {
        const f = std.c.fopen(txt.ptr, "w");
        _ = std.c.fwrite("hello this is plain text\nand more text here\n".ptr, 1, 45, f.?);
        _ = std.c.fclose(f.?);

    }
    const srt = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb7.srt", .{dir}, 0) catch unreachable;
    {
        const f = std.c.fopen(srt.ptr, "w");
        const body = "1\n00:00:00,000 --> 00:00:00,400\nfirst line\n\n2\n00:00:00,500 --> 00:00:00,900\nsecond line\n\n";
        _ = std.c.fwrite(body.ptr, 1, body.len, f.?);
        _ = std.c.fclose(f.?);
    }
    const u = struct {
        fn of(p: [:0]const u8) []const u8 {
            return std.fmt.allocPrint(A, "file://{s}", .{p}) catch unreachable;
        }
    }.of;
    scenario("no uri", .{});
    scenario("invalid uri", .{ .uri = "nope" });
    scenario("ogg", .{ .uri = u(ogg) });
    scenario("mkv", .{ .uri = u(mkv) });
    scenario("mkv audio only", .{ .uri = u(mkv), .mode = 1 });
    scenario("mkv caps encoded", .{ .uri = u(mkv), .caps = "video/x-vp8; audio/x-opus" });
    scenario("wav", .{ .uri = u(wav) });
    scenario("avi with srt", .{ .uri = u(avi), .suburi = u(srt) });
    scenario("gapless ogg then wav", .{ .uri = u(ogg), .next = u(wav) });
    scenario("gapless mkv then mkv", .{ .uri = u(mkv), .next = u(mkv) });
    scenario("text", .{ .uri = u(txt) });
    out("done", .{});
}
