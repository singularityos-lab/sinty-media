const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

fn visibleHash(b: [*c]c.GstBuffer, pad: ?*c.GstPad) ?u64 {
    const cp = c.gst_pad_get_current_caps(pad);
    if (cp == null) return null;
    defer c.gst_caps_unref(cp);
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, cp) == 0) return null;
    if (info.finfo[0].format == c.GST_VIDEO_FORMAT_ENCODED) return null;
    var f: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&f, &info, b, c.GST_MAP_READ) == 0) return null;
    defer c.gst_video_frame_unmap(&f);
    var hs = std.hash.Fnv1a_64.init();
    const fi = info.finfo;
    for (0..fi[0].n_components) |comp| {
        const w: usize = @intCast(-((-info.width) >> @intCast(fi[0].w_sub[comp])));
        const h: usize = @intCast(-((-info.height) >> @intCast(fi[0].h_sub[comp])));
        const plane = fi[0].plane[comp];
        const stride: usize = @intCast(f.info.stride[plane]);
        const base: [*]const u8 = @as([*]const u8, @ptrCast(f.data[plane].?)) + fi[0].poffset[comp];
        for (0..h) |y| hs.update(base[y * stride ..][0..w]);
    }
    return hs.final();
}

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    var h = if (map.size == 0) std.hash.Fnv1a_64.hash("") else std.hash.Fnv1a_64.hash(map.data[0..map.size]);
    c.gst_buffer_unmap(b, &map);
    if (visibleHash(b, pad)) |v| h = v;
    const flags = @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags;
    out("  buf pts {d} dur {d} off {d}/{d} flags {x} size {d} hash {x}", .{ @as(i64, @bitCast(b.*.pts)), @as(i64, @bitCast(b.*.duration)), @as(i64, @bitCast(b.*.offset)), @as(i64, @bitCast(b.*.offset_end)), flags & 0xfff0, map.size, h });
}

fn caps(p: ?*c.GstElement, name: [:0]const u8, padname: [:0]const u8) void {
    const e = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), name.ptr);
    if (e == null) return;
    defer c.gst_object_unref(e);
    const pad = c.gst_element_get_static_pad(e, padname.ptr);
    defer c.gst_object_unref(pad);
    const cp = c.gst_pad_get_current_caps(pad);
    if (cp != null) {
        const s = c.gst_caps_to_string(cp);
        out("  {s}.{s} caps {s}", .{ name, padname, z(s) });
        c.g_free(s);
        c.gst_caps_unref(cp);
    }
}

fn run(desc: [:0]const u8) void {
    out("run {s}", .{desc});
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const sink = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 20 * @as(u64, c.GST_SECOND), c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m == null) {
        out("  timeout", .{});
    } else {
        if (m.*.type == c.GST_MESSAGE_ERROR) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &e, &dbg);
            out("  error {s} {d} [{s}]", .{ z(c.g_quark_to_string(e.*.domain)), e.*.code, z(e.*.message) });
            c.g_error_free(e);
            c.g_free(dbg);
        } else out("  eos", .{});
        c.gst_message_unref(m);
    }
    c.gst_object_unref(bus);
    const parse = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "parse");
    if (parse != null) {
        const sp = c.gst_element_get_static_pad(parse, "src");
        var pos: i64 = -1;
        var fr: i64 = -1;
        var by: i64 = -1;
        const a = c.gst_pad_query_position(sp, c.GST_FORMAT_TIME, &pos);
        const b2 = c.gst_pad_query_position(sp, c.GST_FORMAT_DEFAULT, &fr);
        const b3 = c.gst_pad_query_convert(sp, c.GST_FORMAT_TIME, 1000000000, c.GST_FORMAT_BYTES, &by);
        out("  parse pos {d} {d} {d} {d} {d} {d}", .{ a, pos, b2, fr, b3, by });
        c.gst_object_unref(sp);
        c.gst_object_unref(parse);
    }
    caps(p, "enc", "sink");
    caps(p, "enc", "src");
    caps(p, "dec", "src");
    caps(p, "dec", "sink");
    caps(p, "parse", "src");
    const enc = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "enc");
    if (enc != null) {
        var br: c.gint = 0;
        var q: c.gint = 0;
        c.g_object_get(enc, "bitrate", &br, "quality", &q, @as(?*anyopaque, null));
        out("  bitrate {d} quality {d}", .{ br, q });
        c.gst_object_unref(enc);
    }
    c.gst_object_unref(sink);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

const SINK = " ! fakesink name=sink signal-handoffs=true";

pub fn main() void {
    c.gst_init(null, null);
    for ([_][:0]const u8{ "theoraenc", "theoradec", "theoraparse" }) |e| ins.element(e);
    const srcs = [_][:0]const u8{
        "videotestsrc num-buffers=20 ! video/x-raw,width=64,height=48,framerate=15/1,format=I420",
        "videotestsrc num-buffers=12 pattern=ball ! video/x-raw,width=50,height=30,framerate=25/1,format=Y42B",
        "videotestsrc num-buffers=10 pattern=checkers-4 ! video/x-raw,width=33,height=17,framerate=30000/1001,format=Y444",
        "videotestsrc num-buffers=8 pattern=smpte ! video/x-raw,width=80,height=64,framerate=5/1,pixel-aspect-ratio=4/3,format=I420",
    };
    const encs = [_][:0]const u8{
        "theoraenc name=enc",
        "theoraenc name=enc quality=10 speed-level=0",
        "theoraenc name=enc bitrate=200 keyframe-force=4",
        "theoraenc name=enc keyframe-auto=false keyframe-freq=3 drop-frames=false",
        "theoraenc name=enc vp3-compatible=true rate-buffer=5",
    };
    for (srcs) |s| {
        for (encs) |e| {
            run(std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s} ! {s}" ++ SINK, .{ s, e }, 0) catch unreachable);
            run(std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s} ! {s} ! theoradec name=dec" ++ SINK, .{ s, e }, 0) catch unreachable);
        }
    }
    const x = "videotestsrc num-buffers=30 ! video/x-raw,width=64,height=48,framerate=10/1 ! theoraenc name=enc keyframe-force=8 ! ";
    run(x ++ "theoraparse name=parse" ++ SINK);
    run(x ++ "theoraparse name=parse ! theoradec name=dec" ++ SINK);
    run(x ++ "oggmux ! oggdemux ! theoraparse name=parse" ++ SINK);
    run(x ++ "oggmux ! oggdemux ! theoradec name=dec" ++ SINK);
    run(x ++ "capsfilter caps=video/x-theora ! theoradec name=dec" ++ SINK);
    run(x ++ "theoradec name=dec visualize-motion-vectors=255" ++ SINK);
    run("videotestsrc num-buffers=3 ! video/x-raw,format=RGB ! theoraenc name=enc" ++ SINK);
    run("videotestsrc num-buffers=0 ! theoraenc name=enc" ++ SINK);
    run("videotestsrc num-buffers=4 ! theoraenc name=enc multipass-mode=first-pass" ++ SINK);
}
