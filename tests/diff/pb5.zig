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
var mode_skip_parsers = false;
var selects: std.ArrayList([]u8) = .empty;

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

fn autoplugSelect(_: ?*c.GstElement, _: ?*c.GstPad, _: ?*c.GstCaps, f: ?*c.GstElementFactory, _: c.gpointer) callconv(.c) c.gint {
    const name = objName(f);
    c.g_mutex_lock(&lock);
    selects.append(A, A.dupe(u8, name) catch unreachable) catch unreachable;
    c.g_mutex_unlock(&lock);
    if (mode_skip_parsers and c.gst_element_factory_list_is_type(f, c.GST_ELEMENT_FACTORY_TYPE_PARSER) != 0) return 2;
    return 0;
}

fn unknownType(_: ?*c.GstElement, pad: ?*c.GstPad, caps: ?*c.GstCaps, _: c.gpointer) callconv(.c) void {
    const cs = c.gst_caps_to_string(caps);
    out("  unknown-type {s} {s}", .{ objName(pad), z(cs) });
    c.g_free(cs);
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
        c.GST_MESSAGE_STREAM_COLLECTION => {
            var col: ?*c.GstStreamCollection = null;
            c.gst_message_parse_stream_collection(m, &col);
            out("  stream-collection from {s} size {d}", .{ objName(m[0].src), c.gst_stream_collection_get_size(col) });
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
    file: ?[:0]const u8 = null,
    uri: bool = false,
    skip_parsers: bool = false,
    expose_all: bool = true,
};

fn scenario(title: []const u8, o: Opts) void {
    out("scenario {s}", .{title});
    stats.clearRetainingCapacity();
    selects.clearRetainingCapacity();
    mode_skip_parsers = o.skip_parsers;
    const pipe = c.gst_pipeline_new("pipe");
    pipe_g = pipe;
    const bin: *c.GstBin = @ptrCast(@alignCast(pipe));
    var top: ?*c.GstElement = null;
    if (o.uri) {
        top = c.gst_element_factory_make("urisourcebin", "usb");
        const uri = std.fmt.allocPrintSentinel(A, "file://{s}", .{o.file.?}, 0) catch unreachable;
        c.g_object_set(@ptrCast(top), "uri", uri.ptr, "parse-streams", @as(c.gboolean, 1), N);
        A.free(uri);
        _ = c.gst_bin_add(bin, top);
        _ = c.g_signal_connect_data(top, "pad-added", @ptrCast(&padAdded), null, null, 0);
    } else {
        const src = c.gst_element_factory_make("filesrc", "src");
        c.g_object_set(@ptrCast(src), "location", o.file.?.ptr, N);
        top = c.gst_element_factory_make("parsebin", "pb");
        if (!o.expose_all) c.g_object_set(@ptrCast(top), "expose-all-streams", @as(c.gboolean, 0), N);
        _ = c.gst_bin_add(bin, src);
        _ = c.gst_bin_add(bin, top);
        _ = c.gst_element_link(src, top);
        _ = c.g_signal_connect_data(top, "pad-added", @ptrCast(&padAdded), null, null, 0);
        _ = c.g_signal_connect_data(top, "autoplug-select", @ptrCast(&autoplugSelect), null, null, 0);
        _ = c.g_signal_connect_data(top, "unknown-type", @ptrCast(&unknownType), null, null, 0);
    }
    const bus = c.gst_element_get_bus(pipe);
    out("  playing ok {d}", .{@intFromBool(c.gst_element_set_state(pipe, c.GST_STATE_PLAYING) != c.GST_STATE_CHANGE_FAILURE)});
    var msgs: std.ArrayList([*c]c.GstMessage) = .empty;
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT | c.GST_MESSAGE_STREAM_COLLECTION);
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
    msgs.deinit(A);
    tree(top, 0);
    c.g_mutex_lock(&lock);
    std.mem.sort(*Stat, stats.items, {}, struct {
        fn lt(_: void, a: *Stat, b: *Stat) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    for (stats.items) |st| out("  pad {s} caps {s}\n    stream {s}\n    buffers {d} bytes {d} hash {x} eos {d}", .{ st.name, st.caps, st.stream, st.buffers, st.bytes, st.hash, @intFromBool(st.eos) });
    for (selects.items) |s| out("  select {s}", .{s});
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

pub fn main() void {
    c.gst_init(null, null);
    ins.element("parsebin");
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return;
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(cwd)));
    const ogg = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb5.ogg", .{dir}, 0) catch unreachable;
    const mkv = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb5.mkv", .{dir}, 0) catch unreachable;
    const flac = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb5.flac", .{dir}, 0) catch unreachable;
    const mp3 = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb5.mp3", .{dir}, 0) catch unreachable;
    const avi = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb5.avi", .{dir}, 0) catch unreachable;
    const wav = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb5.wav", .{dir}, 0) catch unreachable;
    const txt = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb5.txt", .{dir}, 0) catch unreachable;
    const junk = std.fmt.allocPrintSentinel(A, "{s}/zig-out/pb5.bin", .{dir}, 0) catch unreachable;
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
        const g = std.c.fopen(junk.ptr, "w");
        var x: u32 = 12345;
        var i: usize = 0;
        while (i < 4096) : (i += 1) {
            x = x *% 1103515245 +% 12345;
            const byte: u8 = @truncate(x >> 16);
            _ = std.c.fwrite(@as([*]const u8, @ptrCast(&byte)), 1, 1, g.?);
        }
        _ = std.c.fclose(g.?);
    }
    scenario("ogg vorbis", .{ .file = ogg });
    scenario("matroska vp8 opus", .{ .file = mkv });
    scenario("flac", .{ .file = flac });
    scenario("mp3", .{ .file = mp3 });
    scenario("avi jpeg", .{ .file = avi });
    scenario("wav", .{ .file = wav });
    scenario("plain text", .{ .file = txt });
    scenario("junk", .{ .file = junk });
    scenario("ogg skip parsers", .{ .file = ogg, .skip_parsers = true });
    scenario("mkv not all streams", .{ .file = mkv, .expose_all = false });
    scenario("urisourcebin parse-streams mkv", .{ .file = mkv, .uri = true });
    scenario("urisourcebin parse-streams flac", .{ .file = flac, .uri = true });
    out("done", .{});
}
