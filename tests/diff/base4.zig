const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, _: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const h = std.hash.Fnv1a_64.hash(map.data[0..map.size]);
    out("    buffer size {d} hash {x}", .{ map.size, h });
    c.gst_buffer_unmap(b, &map);
    const m: ?*c.GstDsdPlaneOffsetMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_dsd_plane_offset_meta_api_get_type())));
    if (m) |x| {
        out("    planes {d} bytes per channel {d}", .{ x.num_channels, x.num_bytes_per_channel });
        var i: usize = 0;
        while (i < @as(usize, @intCast(x.num_channels))) : (i += 1) out("      offset {d}", .{x.offsets[i]});
    }
}

fn scenario(title: []const u8, in_caps: [:0]const u8, out_caps: [:0]const u8, sizes: []const usize, planar: bool) void {
    out("scenario {s}", .{title});
    const desc = std.fmt.allocPrintSentinel(A, "appsrc name=src format=time caps=\"{s}\" ! dsdconvert ! {s} ! fakesink name=sink signal-handoffs=true", .{ in_caps, out_caps }, 0) catch unreachable;
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return;
    }
    const bin: *c.GstBin = @ptrCast(@alignCast(p));
    const src = c.gst_bin_get_by_name(bin, "src");
    const sink = c.gst_bin_get_by_name(bin, "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    var pts: u64 = 0;
    for (sizes, 0..) |n, k| {
        const b = c.gst_buffer_new_allocate(null, n, null);
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
        for (map.data[0..map.size], 0..) |*x, i| x.* = @truncate(i *% 13 +% k *% 5 +% 1);
        c.gst_buffer_unmap(b, &map);
        if (planar) {
            var offs = [2]usize{ 0, n / 2 };
            _ = c.gst_buffer_add_dsd_plane_offset_meta(b, 2, n / 2, &offs);
        }
        b.*.pts = pts;
        pts += 10000000;
        var ret: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
        c.gst_buffer_unref(b);
        out("  push {d} ret {d}", .{ n, ret });
    }
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
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
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    c.gst_object_unref(p);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("dsdconvert");
    const base = "audio/x-dsd, rate=(int)352800, channels=(int)2";
    scenario("u8 to u32be", base ++ ", format=DSDU8, layout=interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU32BE, layout=interleaved", &.{ 64, 128, 40 }, false);
    scenario("u8 to u16le", base ++ ", format=DSDU8, layout=interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU16LE", &.{ 64, 32 }, false);
    scenario("u32le to u8", base ++ ", format=DSDU32LE, layout=interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU8", &.{ 64, 128 }, false);
    scenario("interleaved to planar", base ++ ", format=DSDU8, layout=interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU32BE, layout=non-interleaved", &.{ 64, 128 }, false);
    scenario("planar to interleaved", base ++ ", format=DSDU16BE, layout=non-interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU8, layout=interleaved", &.{ 64, 128 }, true);
    scenario("planar to planar", base ++ ", format=DSDU32BE, layout=non-interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU16LE, layout=non-interleaved", &.{64}, true);
    scenario("reversed bytes", base ++ ", format=DSDU8, layout=interleaved, reversed-bytes=true", "audio/x-dsd, format=DSDU8, reversed-bytes=false", &.{ 64, 16 }, false);
    scenario("passthrough", base ++ ", format=DSDU16LE, layout=interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU16LE, layout=interleaved, reversed-bytes=false", &.{ 64, 32 }, false);
    scenario("mixed sizes", base ++ ", format=DSDU8, layout=interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU32BE", &.{ 68, 8 }, false);
    scenario("missing plane meta", base ++ ", format=DSDU8, layout=non-interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU32BE, layout=interleaved", &.{64}, false);
    scenario("not convertible", base ++ ", format=DSDU8, layout=interleaved, reversed-bytes=false", "audio/x-dsd, format=DSDU8, rate=(int)705600", &.{64}, false);
    out("done", .{});
}
