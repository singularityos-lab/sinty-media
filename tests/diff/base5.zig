const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const caps = c.gst_pad_get_current_caps(pad);
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&info, caps);
    const stride: usize = @intCast(info.stride[0]);
    const row = info.offset[0] + @as(usize, @intCast(@divTrunc(info.height, 2))) * stride;
    const h = std.hash.Fnv1a_64.hash(map.data[row..][0..stride]);
    const cs = c.gst_caps_to_string(caps);
    out("    buffer pts {d} size {d} middle row hash {x} caps {s}", .{ b.*.pts, map.size, h, z(cs) });
    c.g_free(cs);
    if (caps != null) c.gst_caps_unref(caps);
    c.gst_buffer_unmap(b, &map);
}

fn scenario(title: []const u8, desc: [:0]const u8) void {
    out("scenario {s}", .{title});
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const bin: *c.GstBin = @ptrCast(@alignCast(p));
    const sink = c.gst_bin_get_by_name(bin, "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 10 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m == null) {
        out("  timeout", .{});
    } else {
        if (m.*.type == c.GST_MESSAGE_ERROR) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &e, &dbg);
            const d = z(dbg);
            const cut = if (std.mem.indexOf(u8, d, ": /")) |i| d[0..i] else d;
            out("  error {s} {d} [{s}] [{s}]", .{ z(c.g_quark_to_string(e.*.domain)), e.*.code, z(e.*.message), cut });
            c.g_error_free(e);
            c.g_free(dbg);
        } else out("  eos", .{});
        c.gst_message_unref(m);
    }
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(sink);
    c.gst_object_unref(p);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("fakevideodec");
    scenario("vp8 to bgra", "videotestsrc num-buffers=6 ! video/x-raw,width=64,height=48,framerate=10/1 ! vp8enc deadline=1 ! fakevideodec ! video/x-raw,format=BGRA ! fakesink name=sink signal-handoffs=true");
    scenario("vp8 to rgb16", "videotestsrc num-buffers=6 ! video/x-raw,width=80,height=32,framerate=5/1 ! vp8enc deadline=1 ! fakevideodec ! video/x-raw,format=RGB16 ! fakesink name=sink signal-handoffs=true");
    scenario("vp8 to rgbx high fps", "videotestsrc num-buffers=4 ! video/x-raw,width=64,height=64,framerate=60/1 ! vp8enc deadline=1 ! fakevideodec ! video/x-raw,format=RGBx ! fakesink name=sink signal-handoffs=true");
    scenario("raw passthrough", "videotestsrc num-buffers=3 ! video/x-raw,format=BGRx,width=32,height=16,framerate=10/1 ! fakevideodec ! fakesink name=sink signal-handoffs=true");
    scenario("framerate too high", "videotestsrc num-buffers=3 ! video/x-raw,width=64,height=48,framerate=100/1 ! vp8enc deadline=1 ! fakevideodec ! fakesink name=sink signal-handoffs=true");
    scenario("too narrow", "videotestsrc num-buffers=3 ! video/x-raw,width=8,height=8,framerate=30/1 ! vp8enc deadline=1 ! fakevideodec ! fakesink name=sink signal-handoffs=true");
    out("done", .{});
}
