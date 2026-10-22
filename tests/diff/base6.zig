const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

var draw_mode: u8 = 0;

fn onDraw(_: ?*c.GstElement, sample: ?*c.GstSample, _: c.gpointer) callconv(.c) ?*c.GstVideoOverlayComposition {
    const b = c.gst_sample_get_buffer(sample);
    out("    draw pts {d} caps {d}", .{ b.*.pts, @intFromBool(c.gst_sample_get_caps(sample) != null) });
    if (draw_mode == 1) return null;
    const w: c.guint = 16;
    const h: c.guint = 8;
    const rb = c.gst_buffer_new_allocate(null, w * h * 4, null);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(rb, &map, c.GST_MAP_WRITE);
    for (map.data[0..map.size], 0..) |*x, i| x.* = @truncate(if (i % 4 == 3) 0xc0 else i * 11 + b.*.pts / 1000000);
    c.gst_buffer_unmap(rb, &map);
    _ = c.gst_buffer_add_video_meta(rb, c.GST_VIDEO_FRAME_FLAG_NONE, c.GST_VIDEO_FORMAT_BGRA, w, h);
    const rect = c.gst_video_overlay_rectangle_new_raw(rb, 4, 2, w, h, c.GST_VIDEO_OVERLAY_FORMAT_FLAG_NONE);
    c.gst_buffer_unref(rb);
    const compo = c.gst_video_overlay_composition_new(rect);
    c.gst_mini_object_unref(@ptrCast(@alignCast(rect)));
    return compo;
}

fn onCaps(_: ?*c.GstElement, caps: [*c]c.GstCaps, w: c.guint, h: c.guint, _: c.gpointer) callconv(.c) void {
    const cs = c.gst_caps_to_string(caps);
    out("    caps-changed {s} window {d}x{d}", .{ z(cs), w, h });
    c.g_free(cs);
}

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const h = std.hash.Fnv1a_64.hash(map.data[0..map.size]);
    c.gst_buffer_unmap(b, &map);
    const caps = c.gst_pad_get_current_caps(pad);
    const cs = c.gst_caps_to_string(caps);
    const meta = c.gst_buffer_get_meta(b, c.gst_video_overlay_composition_meta_api_get_type()) != null;
    out("    buffer pts {d} size {d} hash {x} meta {d} caps {s}", .{ b.*.pts, map.size, h, @intFromBool(meta), z(cs) });
    c.g_free(cs);
    if (caps != null) c.gst_caps_unref(caps);
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
    const oc = c.gst_bin_get_by_name(bin, "oc");
    _ = c.g_signal_connect_data(oc, "draw", @ptrCast(&onDraw), null, null, 0);
    _ = c.g_signal_connect_data(oc, "caps-changed", @ptrCast(&onCaps), null, null, 0);
    c.gst_object_unref(oc);
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
    ins.element("overlaycomposition");
    const src = "videotestsrc num-buffers=3 ! video/x-raw,width=32,height=24,framerate=10/1,format=";
    scenario("blend i420", src ++ "I420 ! overlaycomposition name=oc ! fakesink name=sink signal-handoffs=true");
    scenario("blend bgrx", src ++ "BGRx ! overlaycomposition name=oc ! fakesink name=sink signal-handoffs=true");
    scenario("blend nv12", src ++ "NV12 ! overlaycomposition name=oc ! fakesink name=sink signal-handoffs=true");
    scenario("blend ayuv", src ++ "AYUV ! overlaycomposition name=oc ! fakesink name=sink signal-handoffs=true");
    scenario("attach meta", src ++ "I420 ! overlaycomposition name=oc ! video/x-raw(meta:GstVideoOverlayComposition) ! fakesink name=sink signal-handoffs=true");
    scenario("blend y42b", src ++ "Y42B ! overlaycomposition name=oc ! fakesink name=sink signal-handoffs=true");
    scenario("attach meta bgrx", src ++ "BGRx ! overlaycomposition name=oc ! video/x-raw(meta:GstVideoOverlayComposition) ! fakesink name=sink signal-handoffs=true");
    draw_mode = 1;
    scenario("no composition", src ++ "I420 ! overlaycomposition name=oc ! fakesink name=sink signal-handoffs=true");
    out("done", .{});
}
