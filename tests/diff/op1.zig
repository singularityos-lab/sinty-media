const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, _: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const h = std.hash.Fnv1a_64.hash(map.data[0..map.size]);
    c.gst_buffer_unmap(b, &map);
    const flags = @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags;
    out("  buf pts {d} dur {d} off {d}/{d} flags {x} size {d} hash {x}", .{ @as(i64, @bitCast(b.*.pts)), @as(i64, @bitCast(b.*.duration)), @as(i64, @bitCast(b.*.offset)), @as(i64, @bitCast(b.*.offset_end)), flags & 0xfff0, map.size, h });
    const m: [*c]c.GstAudioClippingMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_clipping_meta_api_get_type())));
    if (m != null) out("  clip {d} {d} {d}", .{ m.*.format, m.*.start, m.*.end });
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
    caps(p, "enc", "sink");
    caps(p, "enc", "src");
    caps(p, "dec", "src");
    const dec = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "dec");
    if (dec != null) {
        var st: ?*c.GstStructure = null;
        c.g_object_get(dec, "stats", &st, @as(?*anyopaque, null));
        if (st) |s| {
            const str = c.gst_structure_to_string(s);
            out("  stats {s}", .{z(str)});
            c.g_free(str);
            c.gst_structure_free(s);
        }
        c.gst_object_unref(dec);
    }
    c.gst_object_unref(sink);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

const SINK = " ! fakesink name=sink signal-handoffs=true";

pub fn main() void {
    c.gst_init(null, null);
    ins.element("opusenc");
    ins.element("opusdec");
    const srcs = [_][:0]const u8{
        "audiotestsrc num-buffers=12 samplesperbuffer=960 ! audio/x-raw,rate=48000,channels=1",
        "audiotestsrc num-buffers=12 samplesperbuffer=960 wave=triangle freq=1234 ! audio/x-raw,rate=48000,channels=2",
        "audiotestsrc num-buffers=9 samplesperbuffer=700 wave=square ! audio/x-raw,rate=16000,channels=2",
        "audiotestsrc num-buffers=7 samplesperbuffer=1000 wave=saw ! audio/x-raw,rate=24000,channels=1",
        "audiotestsrc num-buffers=6 samplesperbuffer=960 ! audio/x-raw,rate=48000,channels=6",
        "audiotestsrc num-buffers=6 samplesperbuffer=960 ! audio/x-raw,rate=48000,channels=3,channel-mask=(bitmask)0x0",
        "audiotestsrc num-buffers=6 samplesperbuffer=960 wave=ticks ! audio/x-raw,rate=8000,channels=8",
        "audiotestsrc num-buffers=4 samplesperbuffer=480 ! audio/x-raw,rate=12000,channels=4",
    };
    const encs = [_][:0]const u8{
        "opusenc name=enc",
        "opusenc name=enc frame-size=10 bitrate=32000",
        "opusenc name=enc frame-size=60 bitrate-type=cbr audio-type=voice",
        "opusenc name=enc frame-size=2 bitrate-type=vbr complexity=3 bandwidth=wideband",
    };
    for (srcs) |s| {
        for (encs) |e| {
            run(std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s} ! {s}" ++ SINK, .{ s, e }, 0) catch unreachable);
            run(std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s} ! {s} ! opusdec name=dec" ++ SINK, .{ s, e }, 0) catch unreachable);
        }
    }
    const x = "audiotestsrc num-buffers=10 samplesperbuffer=960 ! audio/x-raw,rate=48000,channels=2 ! opusenc name=enc ! ";
    run(x ++ "opusdec name=dec ! audio/x-raw,rate=16000" ++ SINK);
    run(x ++ "opusdec name=dec ! audio/x-raw,channels=1" ++ SINK);
    run(x ++ "opusdec name=dec use-inband-fec=true" ++ SINK);
    run(x ++ "opusdec name=dec apply-gain=false phase-inversion=true" ++ SINK);
    run(x ++ "oggmux ! oggdemux ! opusdec name=dec" ++ SINK);
    run(x ++ "capsfilter caps=audio/x-opus ! opusdec name=dec" ++ SINK);
    run("audiotestsrc num-buffers=3 ! audio/x-raw,rate=44100 ! opusenc name=enc" ++ SINK);
}
