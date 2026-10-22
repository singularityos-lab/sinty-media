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
    const tagger = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "tagger");
    if (tagger != null) {
        c.gst_tag_setter_add_tags(@ptrCast(tagger), c.GST_TAG_MERGE_REPLACE, c.GST_TAG_TITLE, "retagged", c.GST_TAG_ARTIST, "someone", @as(?*anyopaque, null));
        c.gst_object_unref(tagger);
    }
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
    caps(p, "dec", "sink");
    caps(p, "parse", "src");
    const enc = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "enc");
    if (enc != null) {
        var msg: [*c]u8 = null;
        var managed: c.gboolean = 0;
        c.g_object_get(enc, "last-message", &msg, "managed", &managed, @as(?*anyopaque, null));
        out("  last-message {s} managed {d}", .{ z(msg), managed });
        c.g_free(msg);
        c.gst_object_unref(enc);
    }
    c.gst_object_unref(sink);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

const SINK = " ! fakesink name=sink signal-handoffs=true";

pub fn main() void {
    c.gst_init(null, null);
    for ([_][:0]const u8{ "vorbisenc", "vorbisdec", "vorbisparse", "vorbistag" }) |e| ins.element(e);
    const srcs = [_][:0]const u8{
        "audiotestsrc num-buffers=12 samplesperbuffer=1024 ! audio/x-raw,rate=44100,channels=1",
        "audiotestsrc num-buffers=10 samplesperbuffer=1000 wave=triangle freq=1234 ! audio/x-raw,rate=48000,channels=2",
        "audiotestsrc num-buffers=9 samplesperbuffer=700 wave=square ! audio/x-raw,rate=16000,channels=2",
        "audiotestsrc num-buffers=5 samplesperbuffer=1000 wave=saw ! audio/x-raw,rate=22050,channels=6",
        "audiotestsrc num-buffers=4 samplesperbuffer=512 wave=ticks ! audio/x-raw,rate=8000,channels=3",
        "audiotestsrc num-buffers=4 samplesperbuffer=512 ! audio/x-raw,rate=32000,channels=8",
        "audiotestsrc num-buffers=3 samplesperbuffer=400 ! audio/x-raw,rate=11025,channels=10,channel-mask=(bitmask)0x0",
    };
    const encs = [_][:0]const u8{
        "vorbisenc name=enc",
        "vorbisenc name=enc quality=0.9",
        "vorbisenc name=enc quality=-0.1",
        "vorbisenc name=enc bitrate=64000",
        "vorbisenc name=enc bitrate=96000 managed=true",
        "vorbisenc name=enc min-bitrate=32000 max-bitrate=128000",
        "vorbisenc name=enc max-bitrate=80000",
    };
    for (srcs) |s| {
        for (encs) |e| {
            run(std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s} ! {s}" ++ SINK, .{ s, e }, 0) catch unreachable);
            run(std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s} ! {s} ! vorbisdec name=dec" ++ SINK, .{ s, e }, 0) catch unreachable);
        }
    }
    const x = "audiotestsrc num-buffers=10 samplesperbuffer=1024 ! audio/x-raw,rate=44100,channels=2 ! vorbisenc name=enc ! ";
    run(x ++ "vorbisparse name=parse" ++ SINK);
    run(x ++ "vorbisparse name=parse ! vorbisdec name=dec" ++ SINK);
    run(x ++ "vorbistag name=tagger" ++ SINK);
    run(x ++ "vorbistag name=tagger ! vorbisdec name=dec" ++ SINK);
    run(x ++ "oggmux ! oggdemux ! vorbisparse name=parse" ++ SINK);
    run(x ++ "oggmux ! oggdemux ! vorbisdec name=dec" ++ SINK);
    run(x ++ "capsfilter caps=audio/x-vorbis ! vorbisdec name=dec" ++ SINK);
    run("audiotestsrc num-buffers=3 ! audio/x-raw,rate=44100,format=S16LE ! vorbisenc name=enc" ++ SINK);
    run("audiotestsrc num-buffers=3 ! audio/x-raw,rate=250000 ! vorbisenc name=enc" ++ SINK);
    run("audiotestsrc num-buffers=0 ! vorbisenc name=enc" ++ SINK);
    run("audiotestsrc num-buffers=2 samplesperbuffer=10 ! vorbisenc name=enc ! vorbisdec name=dec" ++ SINK);
}
