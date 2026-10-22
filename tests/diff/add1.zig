const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

var last_caps: [*c]u8 = null;

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_pad_get_current_caps(pad);
    if (caps != null) {
        const s = c.gst_caps_to_string(caps);
        if (last_caps == null or c.strcmp(last_caps, s) != 0) {
            out("    caps {s}", .{z(s)});
            c.g_free(last_caps);
            last_caps = c.g_strdup(s);
        }
        c.g_free(s);
        c.gst_caps_unref(caps);
    }
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const h = std.hash.Fnv1a_64.hash(map.data[0..map.size]);
    c.gst_buffer_unmap(b, &map);
    out("    buffer size {d} pts {d} dur {d} off {d} flags {x} hash {x}", .{ map.size, @as(i64, @bitCast(b.*.pts)), @as(i64, @bitCast(b.*.duration)), @as(i64, @bitCast(b.*.offset)), @as(*c.GstMiniObject, @ptrCast(b)).flags & ~@as(c.guint, 0xf), h });
}

const Input = struct {
    caps: []const u8,
    bpf: usize,
    rate: u64,
    frames: []const usize,
    seed: usize,
    start: u64 = 0,
};

fn fill(b: [*c]c.GstBuffer, seed: usize, k: usize) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
    var x: u32 = @truncate(seed *% 2654435761 +% k *% 40503 +% 1);
    for (map.data[0..map.size]) |*p| {
        x = x *% 1103515245 +% 12345;
        p.* = @truncate(x >> 16);
    }
    c.gst_buffer_unmap(b, &map);
}

fn scenario(title: []const u8, element: []const u8, outcaps: []const u8, inputs: []const Input, props: []const [:0]const u8) void {
    out("scenario {s}", .{title});
    var desc: std.ArrayList(u8) = .empty;
    desc.print(A, "{s} name=m ! capsfilter caps=\"{s}\" ! fakesink name=sink signal-handoffs=true sync=false", .{ element, outcaps }) catch unreachable;
    for (inputs, 0..) |in, i| desc.print(A, " appsrc name=s{d} format=time caps=\"{s}\" ! m.sink_{d}", .{ i, in.caps, i }) catch unreachable;
    desc.append(A, 0) catch unreachable;
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(@ptrCast(desc.items.ptr), &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const bin: *c.GstBin = @ptrCast(@alignCast(p));
    const m = c.gst_bin_get_by_name(bin, "m");
    const sink = c.gst_bin_get_by_name(bin, "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    for (props) |pr| {
        var it = std.mem.splitScalar(u8, pr, '=');
        const key = A.dupeZ(u8, it.next().?) catch unreachable;
        const val = A.dupeZ(u8, it.next().?) catch unreachable;
        var obj: ?*c.GObject = null;
        var spec: [*c]c.GParamSpec = null;
        if (c.gst_child_proxy_lookup(@ptrCast(m), key.ptr, &obj, &spec) == 0) {
            out("  no property {s}", .{key});
            continue;
        }
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, spec.*.value_type);
        _ = c.gst_value_deserialize(&v, val.ptr);
        c.g_object_set_property(obj, spec.*.name, &v);
        c.g_value_unset(&v);
        c.g_object_unref(obj);
    }
    c.g_free(last_caps);
    last_caps = null;
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    for (inputs, 0..) |in, i| {
        const name = std.fmt.allocPrintSentinel(A, "s{d}", .{i}, 0) catch unreachable;
        const src = c.gst_bin_get_by_name(bin, name.ptr);
        var pts: u64 = in.start;
        var frames_done: u64 = 0;
        for (in.frames, 0..) |n, k| {
            const b = c.gst_buffer_new_allocate(null, n * in.bpf, null);
            fill(b, in.seed, k);
            b.*.pts = pts;
            frames_done += n;
            const next = in.start + c.gst_util_uint64_scale(frames_done, c.GST_SECOND, in.rate);
            b.*.duration = next - pts;
            pts = next;
            var ret: c.GstFlowReturn = 0;
            c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
            c.gst_buffer_unref(b);
        }
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "end-of-stream", &ret);
        c.gst_object_unref(src);
    }
    const bus = c.gst_element_get_bus(p);
    const msg = c.gst_bus_timed_pop_filtered(bus, 10 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (msg == null) {
        out("  timeout", .{});
    } else {
        if (msg.*.type == c.GST_MESSAGE_ERROR) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(msg, &e, &dbg);
            out("  error {s} {d} [{s}]", .{ z(c.g_quark_to_string(e.*.domain)), e.*.code, z(e.*.message) });
            c.g_error_free(e);
            c.g_free(dbg);
        } else out("  eos", .{});
        c.gst_message_unref(msg);
    }
    _ = c.g_signal_handlers_disconnect_matched(sink, c.G_SIGNAL_MATCH_FUNC, 0, 0, null, @constCast(@ptrCast(&handoff)), null);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(m);
    c.gst_object_unref(sink);
    c.gst_object_unref(p);
}

fn acaps(comptime fmt: []const u8, comptime ch: []const u8) []const u8 {
    return "audio/x-raw,format=" ++ fmt ++ ",rate=8000,channels=" ++ ch ++ ",layout=interleaved";
}

fn readProps() void {
    const live = c.gst_element_factory_make("liveadder", null);
    var lat: c.guint = 0;
    c.g_object_get(live, "latency", &lat, N);
    var agg_lat: u64 = 0;
    const spec = c.g_object_class_find_property(@ptrCast(@alignCast(c.g_type_class_peek(c.gst_aggregator_get_type()))), "latency");
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_UINT64);
    c.g_object_get_property(@ptrCast(live), spec.*.name, &v);
    agg_lat = c.g_value_get_uint64(&v);
    c.g_value_unset(&v);
    c.g_object_set(live, "latency", @as(c.guint, 75), N);
    var lat2: c.guint = 0;
    c.g_object_get(live, "latency", &lat2, N);
    out("liveadder latency {d} {d} {d}", .{ lat, agg_lat, lat2 });
    c.gst_object_unref(live);
    const il = c.gst_element_factory_make("audiointerleave", null);
    const t = c.gst_element_class_get_pad_template(@ptrCast(@as(*c.GTypeInstance, @ptrCast(il)).g_class), "sink_%u");
    const p0 = c.gst_element_request_pad(il, t, null, null);
    const p1 = c.gst_element_request_pad(il, t, null, null);
    const p2 = c.gst_element_request_pad(il, t, null, null);
    var ch: c.guint = 0;
    c.g_object_get(p2, "channel", &ch, N);
    out("interleave pads {s} {s} {s} channel {d} children {d}", .{ z(c.gst_object_get_name(@ptrCast(@alignCast(p0)))), z(c.gst_object_get_name(@ptrCast(@alignCast(p1)))), z(c.gst_object_get_name(@ptrCast(@alignCast(p2)))), ch, c.gst_child_proxy_get_children_count(@ptrCast(il)) });
    c.gst_element_release_request_pad(il, p1);
    c.g_object_get(p2, "channel", &ch, N);
    out("  after release channel {d} children {d}", .{ ch, c.gst_child_proxy_get_children_count(@ptrCast(il)) });
    c.gst_object_unref(p0);
    c.gst_object_unref(p1);
    c.gst_object_unref(p2);
    c.gst_object_unref(il);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("adder");
    const fr = &[_]usize{ 160, 160, 200, 37 };
    const fr2 = &[_]usize{ 100, 300, 100 };
    scenario("s16 two inputs", "adder", acaps("S16LE", "2"), &.{ .{ .caps = acaps("S16LE", "2"), .bpf = 4, .rate = 8000, .frames = fr, .seed = 1 }, .{ .caps = acaps("S16LE", "2"), .bpf = 4, .rate = 8000, .frames = fr2, .seed = 2 } }, &.{});
    scenario("s16 volume", "adder", acaps("S16LE", "2"), &.{ .{ .caps = acaps("S16LE", "2"), .bpf = 4, .rate = 8000, .frames = fr, .seed = 3 }, .{ .caps = acaps("S16LE", "2"), .bpf = 4, .rate = 8000, .frames = fr, .seed = 4 } }, &.{ "sink_0::volume=0.5", "sink_1::volume=3.3" });
    scenario("mute", "adder", acaps("S16LE", "1"), &.{ .{ .caps = acaps("S16LE", "1"), .bpf = 2, .rate = 8000, .frames = fr, .seed = 5 }, .{ .caps = acaps("S16LE", "1"), .bpf = 2, .rate = 8000, .frames = fr, .seed = 6 } }, &.{"sink_1::mute=true"});
    scenario("all muted", "adder", acaps("S16LE", "1"), &.{ .{ .caps = acaps("S16LE", "1"), .bpf = 2, .rate = 8000, .frames = fr, .seed = 5 } }, &.{"sink_0::mute=true"});
    const formats = [_]struct { f: []const u8, b: usize }{ .{ .f = "U8", .b = 1 }, .{ .f = "S8", .b = 1 }, .{ .f = "U16LE", .b = 2 }, .{ .f = "S32LE", .b = 4 }, .{ .f = "U32LE", .b = 4 }, .{ .f = "F32LE", .b = 4 }, .{ .f = "F64LE", .b = 8 } };
    inline for (formats) |f| {
        const cp = "audio/x-raw,format=" ++ f.f ++ ",rate=8000,channels=1,layout=interleaved";
        scenario(f.f ++ " unity", "adder", cp, &.{ .{ .caps = cp, .bpf = f.b, .rate = 8000, .frames = fr, .seed = 7 }, .{ .caps = cp, .bpf = f.b, .rate = 8000, .frames = fr, .seed = 8 } }, &.{});
        scenario(f.f ++ " volume", "adder", cp, &.{ .{ .caps = cp, .bpf = f.b, .rate = 8000, .frames = fr, .seed = 9 }, .{ .caps = cp, .bpf = f.b, .rate = 8000, .frames = fr, .seed = 10 } }, &.{ "sink_0::volume=0.7", "sink_1::volume=1.9" });
    }
    scenario("three inputs", "adder", acaps("S16LE", "1"), &.{ .{ .caps = acaps("S16LE", "1"), .bpf = 2, .rate = 8000, .frames = fr, .seed = 11 }, .{ .caps = acaps("S16LE", "1"), .bpf = 2, .rate = 8000, .frames = fr2, .seed = 12 }, .{ .caps = acaps("S16LE", "1"), .bpf = 2, .rate = 8000, .frames = fr, .seed = 13 } }, &.{"sink_2::volume=0.25"});
    out("done", .{});
}
