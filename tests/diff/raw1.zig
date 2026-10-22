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
    out("    buffer size {d} pts {d} dur {d} off {d} flags {x} hash {x}", .{ map.size, @as(i64, @bitCast(b.*.pts)), @as(i64, @bitCast(b.*.duration)), @as(i64, @bitCast(b.*.offset)), @as(*c.GstMiniObject, @ptrCast(b)).flags, h });
    const vm: ?*c.GstVideoMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_video_meta_api_get_type())));
    if (vm) |m| out("      meta flags {d} {d}x{d} planes {d} off {d},{d},{d} stride {d},{d},{d}", .{ m.flags, m.width, m.height, m.n_planes, m.offset[0], m.offset[1], m.offset[2], m.stride[0], m.stride[1], m.stride[2] });
}

fn bytes(n: usize, seed: usize) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, n, null);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
    for (map.data[0..map.size], 0..) |*x, i| x.* = @truncate(i *% 7 +% seed *% 13 +% (i >> 5));
    c.gst_buffer_unmap(b, &map);
    return b;
}

fn printError(m: [*c]c.GstMessage) void {
    var e: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    c.gst_message_parse_error(m, &e, &dbg);
    out("  error {s} {d} [{s}] [{s}]", .{ z(c.g_quark_to_string(e.*.domain)), e.*.code, z(e.*.message), z(dbg) });
    c.g_error_free(e);
    c.g_free(dbg);
}

fn scenario(title: []const u8, desc: [:0]const u8, sizes: []const usize, setup: ?*const fn (?*c.GstElement) void) void {
    out("scenario {s}", .{title});
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const bin: *c.GstBin = @ptrCast(@alignCast(p));
    const src = c.gst_bin_get_by_name(bin, "src");
    const sink = c.gst_bin_get_by_name(bin, "sink");
    const parser = c.gst_bin_get_by_name(bin, "parse");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    if (setup) |f| f(parser);
    c.g_free(last_caps);
    last_caps = null;
    const early_bus = c.gst_element_get_bus(p);
    const early = c.gst_bus_pop_filtered(early_bus, c.GST_MESSAGE_ERROR);
    c.gst_object_unref(early_bus);
    if (early != null) {
        printError(early);
        c.gst_message_unref(early);
        c.gst_object_unref(src);
        c.gst_object_unref(sink);
        c.gst_object_unref(parser);
        c.gst_object_unref(p);
        return;
    }
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    for (sizes, 0..) |n, k| {
        const b = bytes(n, k);
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
        c.gst_buffer_unref(b);
        if (ret != 0) out("  push {d} ret {d}", .{ n, ret });
    }
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    var failed = false;
    if (m == null) {
        out("  timeout", .{});
    } else {
        failed = m.*.type == c.GST_MESSAGE_ERROR;
        if (failed) printError(m) else out("  eos", .{});
        c.gst_message_unref(m);
    }
    if (!failed) {
        for ([_]c.GstFormat{ c.GST_FORMAT_TIME, c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT }) |f| {
            var pos: i64 = 0;
            const ok = c.gst_element_query_position(parser, f, &pos);
            var cv: i64 = 0;
            const cok = c.gst_element_query_convert(parser, c.GST_FORMAT_BYTES, 4096, f, &cv);
            out("  position {s} {d} {d} convert {d} {d}", .{ z(c.gst_format_get_name(f)), ok, pos, cok, cv });
        }
    }
    _ = c.g_signal_handlers_disconnect_matched(sink, c.G_SIGNAL_MATCH_FUNC, 0, 0, null, @constCast(@ptrCast(&handoff)), null);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    c.gst_object_unref(parser);
    c.gst_object_unref(p);
}

fn swapPositions(e: ?*c.GstElement) void {
    const arr = c.g_value_array_new(2);
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_audio_channel_position_get_type());
    c.g_value_set_enum(&v, c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT);
    _ = c.g_value_array_append(arr, &v);
    c.g_value_set_enum(&v, c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT);
    _ = c.g_value_array_append(arr, &v);
    c.g_object_set(e, "channel-positions", arr, N);
    c.g_value_array_free(arr);
    c.g_value_unset(&v);
    var got: ?*c.GValueArray = null;
    c.g_object_get(e, "channel-positions", &got, N);
    if (got) |g| {
        out("  positions {d}: {d} {d}", .{ g.n_values, c.g_value_get_enum(c.g_value_array_get_nth(g, 0)), c.g_value_get_enum(c.g_value_array_get_nth(g, 1)) });
        c.g_value_array_free(g);
    }
}

fn emptyPositions(e: ?*c.GstElement) void {
    const arr = c.g_value_array_new(0);
    c.g_object_set(e, "channel-positions", arr, N);
    c.g_value_array_free(arr);
}

fn strides(e: ?*c.GstElement) void {
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_INT);
    for ([_]c.gint{ 20, 12, 12 }) |x| {
        c.g_value_set_int(&v, x);
        c.gst_value_array_append_value(&arr, &v);
    }
    c.g_object_set_property(@ptrCast(e), "plane-strides", &arr);
    c.g_value_unset(&arr);
    var off = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&off, c.gst_value_array_get_type());
    for ([_]c.gint{ 0, 200, 260 }) |x| {
        c.g_value_set_int(&v, x);
        c.gst_value_array_append_value(&off, &v);
    }
    c.g_object_set_property(@ptrCast(e), "plane-offsets", &off);
    c.g_value_unset(&off);
    var got = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&got, c.gst_value_array_get_type());
    c.g_object_get_property(@ptrCast(e), "plane-strides", &got);
    const s = c.gst_value_serialize(&got);
    out("  strides {s}", .{z(s)});
    c.g_free(s);
    c.g_value_unset(&got);
    c.g_value_unset(&v);
}

fn shortStrides(e: ?*c.GstElement) void {
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_INT);
    c.g_value_set_int(&v, 16);
    c.gst_value_array_append_value(&arr, &v);
    c.g_object_set_property(@ptrCast(e), "plane-strides", &arr);
    c.g_value_unset(&arr);
    c.g_value_unset(&v);
}

fn colorimetry(e: ?*c.GstElement) void {
    c.g_object_set(e, "colorimetry", "bt709", N);
}

fn props(name: [*c]const u8) void {
    const e = c.gst_element_factory_make(name, null);
    defer c.gst_object_unref(e);
    const k: *c.GObjectClass = @ptrCast(@as(*c.GTypeInstance, @ptrCast(e)).g_class);
    var n: c.guint = 0;
    const specs = c.g_object_class_list_properties(k, &n);
    defer c.g_free(@ptrCast(specs));
    out("props {s}", .{z(name)});
    for (specs[0..n]) |sp| {
        if (sp.*.flags & c.G_PARAM_READABLE == 0) continue;
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, sp.*.value_type);
        c.g_object_get_property(@ptrCast(e), sp.*.name, &v);
        const s = c.g_strdup_value_contents(&v);
        out("  {s} = {s}", .{ z(sp.*.name), z(s) });
        c.g_free(s);
        c.g_value_unset(&v);
    }
}

pub fn main() void {
    c.gst_init(null, null);
    for ([_][*c]const u8{ "rawvideoparse", "unalignedaudioparse", "unalignedvideoparse" }) |n| ins.element(n);
    for ([_][*c]const u8{ "rawaudioparse", "rawvideoparse" }) |n| props(n);
    const a = "appsrc name=src format=bytes ! ";
    const fs = "! fakesink name=sink signal-handoffs=true";
    scenario("audio properties", a ++ "rawaudioparse name=parse " ++ fs, &.{ 1000, 4410, 3 }, null);
    scenario("audio custom", a ++ "rawaudioparse name=parse pcm-format=f32le sample-rate=8000 num-channels=3 " ++ fs, &.{ 1200, 500 }, null);
    scenario("audio alaw", a ++ "rawaudioparse name=parse format=alaw sample-rate=8000 num-channels=1 " ++ fs, &.{ 800, 333 }, null);
    scenario("audio mulaw stereo", a ++ "rawaudioparse name=parse format=mulaw sample-rate=16000 num-channels=2 " ++ fs, &.{ 640, 7 }, null);
    scenario("audio reorder", a ++ "rawaudioparse name=parse " ++ fs, &.{ 400, 64 }, &swapPositions);
    scenario("audio empty positions", a ++ "rawaudioparse name=parse " ++ fs, &.{64}, &emptyPositions);
    scenario("audio sink caps", "appsrc name=src format=bytes caps=\"audio/x-raw,format=S24LE,rate=48000,channels=2,layout=interleaved\" ! rawaudioparse name=parse use-sink-caps=true " ++ fs, &.{ 6000, 100 }, null);
    scenario("audio sink caps alaw", "appsrc name=src format=bytes caps=\"audio/x-alaw,rate=8000,channels=2\" ! rawaudioparse name=parse use-sink-caps=true " ++ fs, &.{ 1000, 1 }, null);
    scenario("audio sink caps missing", a ++ "rawaudioparse name=parse use-sink-caps=true " ++ fs, &.{64}, null);
    scenario("audio unaligned", "appsrc name=src format=bytes caps=\"audio/x-unaligned-raw,format=S16BE,rate=22050,channels=1,layout=interleaved\" ! unalignedaudioparse name=parse " ++ fs, &.{ 1001, 999 }, null);
    scenario("video default", a ++ "rawvideoparse name=parse " ++ fs, &.{ 115200, 115200, 1000 }, null);
    scenario("video rgb", a ++ "rawvideoparse name=parse format=rgb width=10 height=6 framerate=30/1 " ++ fs, &.{ 180, 360, 50 }, null);
    scenario("video frame size", a ++ "rawvideoparse name=parse format=gray8 width=8 height=4 frame-size=40 " ++ fs, &.{ 120, 41 }, null);
    scenario("video interlaced", a ++ "rawvideoparse name=parse format=nv12 width=16 height=8 interlaced=true top-field-first=true " ++ fs, &.{ 192, 192 }, null);
    scenario("video custom strides", a ++ "rawvideoparse name=parse format=i420 width=16 height=10 " ++ fs, &.{ 340, 340 }, &strides);
    scenario("video short strides", a ++ "rawvideoparse name=parse format=i420 width=16 height=10 " ++ fs, &.{240}, &shortStrides);
    scenario("video colorimetry", a ++ "rawvideoparse name=parse format=gray8 width=4 height=4 " ++ fs, &.{ 16, 16 }, &colorimetry);
    scenario("video tiled", a ++ "rawvideoparse name=parse format=nv12_64z32 width=64 height=64 " ++ fs, &.{ 8192, 8192 }, null);
    scenario("video sink caps", "appsrc name=src format=bytes caps=\"video/x-raw,format=YUY2,width=6,height=2,framerate=10/1\" ! rawvideoparse name=parse use-sink-caps=true " ++ fs, &.{ 24, 24, 10 }, null);
    scenario("video unaligned", "appsrc name=src format=bytes caps=\"video/x-unaligned-raw,format=BGRA,width=3,height=3,framerate=5/1\" ! unalignedvideoparse name=parse " ++ fs, &.{ 36, 36 }, null);
    out("done", .{});
}
