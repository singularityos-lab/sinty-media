const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;

var xbyte: i32 = -1;

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_pad_get_current_caps(pad);
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&info, caps);
    c.gst_caps_unref(caps);
    var fr: c.GstVideoFrame = undefined;
    _ = c.gst_video_frame_map(&fr, &info, b, c.GST_MAP_READ);
    var hs = std.hash.Fnv1a_64.init();
    const fi = info.finfo;
    for (0..fi[0].n_planes) |pl| {
        var comp: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
        c.gst_video_format_info_component(fi, @intCast(pl), &comp);
        const k: usize = @intCast(comp[0]);
        const cw = -((-info.width) >> @intCast(fi[0].w_sub[k]));
        const ch = -((-info.height) >> @intCast(fi[0].h_sub[k]));
        const rowbytes: usize = @intCast(cw * fi[0].pixel_stride[k]);
        const base: [*]u8 = @ptrCast(fr.data[pl].?);
        for (0..@intCast(ch)) |y| {
            const row = base + y * @as(usize, @intCast(fr.info.stride[pl]));
            var x: usize = 0;
            while (x < rowbytes) : (x += 4) {
                var px: [4]u8 = .{ 0, 0, 0, 0 };
                const n = @min(4, rowbytes - x);
                @memcpy(px[0..n], row[x .. x + n]);
                if (xbyte >= 0) px[@intCast(xbyte)] = 0;
                hs.update(px[0..n]);
            }
        }
    }
    c.gst_video_frame_unmap(&fr);
    out("  buf pts {d} size {d} hash {x}", .{ @as(i64, @bitCast(b.*.pts)), c.gst_buffer_get_size(b), hs.final() });
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
            out("  error {s}", .{z(e.*.message)});
            c.g_error_free(e);
            c.g_free(dbg);
        } else out("  eos", .{});
        c.gst_message_unref(m);
    }
    c.gst_object_unref(bus);
    const comp = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "c");
    if (comp != null) {
        const pad = c.gst_element_get_static_pad(comp, "src");
        const caps = c.gst_pad_get_current_caps(pad);
        if (caps != null) {
            const s = c.gst_caps_to_string(caps);
            out("  caps {s}", .{z(s)});
            c.g_free(s);
            c.gst_caps_unref(caps);
        }
        c.gst_object_unref(pad);
        out("  children {d}", .{c.gst_child_proxy_get_children_count(@ptrCast(comp))});
        c.gst_object_unref(comp);
    }
    c.gst_object_unref(sink);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

fn mix(fmt: []const u8, bg: []const u8, extra: []const u8, w: u32, h: u32) void {
    xbyte = if (std.mem.eql(u8, fmt, "xRGB") or std.mem.eql(u8, fmt, "xBGR")) 0 else if (std.mem.eql(u8, fmt, "RGBx") or std.mem.eql(u8, fmt, "BGRx")) 3 else -1;
    const d = std.fmt.allocPrintSentinel(A, "compositor name=c max-threads=1 background={s} {s} ! video/x-raw,format={s},width={d},height={d} ! fakesink name=sink signal-handoffs=true " ++
        "videotestsrc num-buffers=2 pattern=smpte ! video/x-raw,format={s},width=40,height=30,framerate=10/1 ! c.sink_0 " ++
        "videotestsrc num-buffers=2 pattern=ball background-color=0x60208040 foreground-color=0xc0ffff00 ! video/x-raw,format={s},width=30,height=20,framerate=10/1 ! c.sink_1", .{ bg, extra, fmt, w, h, fmt, fmt }, 0) catch unreachable;
    run(d);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("compositor");
    const formats = [_][]const u8{ "AYUV", "VUYA", "ARGB", "BGRA", "ABGR", "RGBA", "I420", "YV12", "NV12", "NV21", "Y444", "Y42B", "Y41B", "RGB", "BGR", "xRGB", "xBGR", "RGBx", "BGRx", "YUY2", "UYVY", "YVYU", "I420_10LE", "I420_10BE", "I420_12LE", "I422_10LE", "I422_12BE", "Y444_10LE", "Y444_12LE", "Y444_16LE", "Y444_16BE", "ARGB64", "AYUV64", "GRAY8", "RGB16", "BGR10A2_LE", "GBR" };
    const bgs = [_][]const u8{ "checker", "black", "white", "transparent" };
    const pos = "sink_0::xpos=-6 sink_0::ypos=-3 sink_0::alpha=0.7 sink_1::xpos=21 sink_1::ypos=17 sink_1::alpha=0.55";
    for (formats) |f| {
        for (bgs) |b| mix(f, b, pos, 64, 48);
    }
    const ops = [_][]const u8{
        "sink_1::operator=source sink_1::xpos=10 sink_1::ypos=10",
        "sink_1::operator=add sink_1::xpos=10 sink_1::ypos=10 sink_1::alpha=0.8",
        "sink_1::operator=over sink_0::alpha=0.0",
        "sink_0::width=64 sink_0::height=48 sink_1::width=20 sink_1::height=40 sink_1::sizing-policy=keep-aspect-ratio",
        "sink_0::xpos=50 sink_0::ypos=40 sink_1::xpos=-29 sink_1::ypos=-19",
        "sink_0::xpos=3 sink_0::ypos=5",
        "sink_1::xpos=7 sink_1::ypos=9 sink_1::alpha=1.0",
    };
    for ([_][]const u8{ "ARGB", "BGRA", "AYUV", "I420", "NV12", "RGB", "YUY2", "ARGB64", "Y444_10LE" }) |f| {
        for (ops) |o| mix(f, "transparent", o, 64, 48);
        for (ops) |o| mix(f, "checker", o, 64, 48);
    }
    xbyte = -1;
    run("compositor name=c max-threads=1 sink_1::xpos=50 sink_1::ypos=7 ! video/x-raw,format=I420 ! fakesink name=sink signal-handoffs=true videotestsrc num-buffers=2 ! video/x-raw,format=I420,width=40,height=30,framerate=15/1 ! c.sink_0 videotestsrc num-buffers=2 pattern=ball ! video/x-raw,format=I420,width=30,height=20,framerate=10/1,pixel-aspect-ratio=4/3 ! c.sink_1");
    const tail = " ! fakesink name=sink signal-handoffs=true videotestsrc num-buffers=1 ! video/x-raw,format=I420,width=40,height=30,framerate=15/1 ! c.sink_0 videotestsrc num-buffers=1 pattern=ball ! video/x-raw,format=I420,width=30,height=20,framerate=10/1";
    run("compositor name=c max-threads=1 sink_1::width=40 ! video/x-raw,format=I420" ++ tail);
    run("compositor name=c max-threads=1 sink_1::width=40 ! video/x-raw,format=ARGB" ++ tail);
    run("compositor name=c max-threads=1 sink_1::width=40 sink_1::height=20 ! video/x-raw,format=I420" ++ tail ++ ",pixel-aspect-ratio=4/3");
    run("compositor name=c max-threads=1 ! video/x-raw,format=I420" ++ tail ++ ",pixel-aspect-ratio=4/3");
    run("compositor name=c max-threads=1 ! video/x-raw,format=ARGB" ++ tail ++ ",pixel-aspect-ratio=4/3");

}
