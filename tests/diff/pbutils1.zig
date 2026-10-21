const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "(null)" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn own(p: [*c]u8) []const u8 {
    return z(p);
}

fn describe(caps: [*c]c.GstCaps) void {
    const cs = c.gst_caps_to_string(caps);
    const d = c.gst_pb_utils_get_codec_description(caps);
    const dec = c.gst_pb_utils_get_decoder_description(caps);
    const enc = c.gst_pb_utils_get_encoder_description(caps);
    const ext = c.gst_pb_utils_get_file_extension_from_caps(caps);
    const fl = c.gst_pb_utils_get_caps_description_flags(caps);
    const tl = c.gst_tag_list_new_empty();
    const added = c.gst_pb_utils_add_codec_description_to_tag_list(tl, null, caps);
    const ts = c.gst_tag_list_to_string(tl);
    out("{s}\n  desc {s} | dec {s} | enc {s} | ext {s} | flags {d} | tag {d} {s}", .{ z(cs), z(d), z(dec), z(enc), z(ext), fl, added, z(ts) });
    for ([_][*c]const u8{ c.GST_TAG_AUDIO_CODEC, c.GST_TAG_CODEC }) |tag| {
        const t2 = c.gst_tag_list_new_empty();
        const a2 = c.gst_pb_utils_add_codec_description_to_tag_list(t2, tag, caps);
        const s2 = c.gst_tag_list_to_string(t2);
        out("  tag2 {d} {s}", .{ a2, z(s2) });
        c.g_free(s2);
        c.gst_tag_list_unref(t2);
    }
    inline for (.{ c.gst_missing_decoder_installer_detail_new, c.gst_missing_encoder_installer_detail_new }) |f| {
        const det = f(caps);
        out("  inst {s}", .{z(det)});
        c.g_free(det);
    }
    c.g_free(ts);
    c.gst_tag_list_unref(tl);
    c.g_free(cs);
    c.g_free(d);
    c.g_free(dec);
    c.g_free(enc);
    c.g_free(ext);
}

fn describeStr(s: [*c]const u8) void {
    const caps = c.gst_caps_from_string(s);
    if (caps == null) {
        out("bad caps {s}", .{z(s)});
        return;
    }
    describe(caps);
    c.gst_caps_unref(caps);
}

const DYNAMIC = [_][*c]const u8{
    "video/x-raw",
    "video/x-raw, format=NOPE",
    "video/x-h263, variant=itu",
    "video/x-h263, variant=lead",
    "video/x-h263, variant=microsoft",
    "video/x-h263, variant=vdolive",
    "video/x-h263, variant=vivo",
    "video/x-h263, variant=xirlink",
    "video/x-h263, variant=other",
    "video/x-h264, variant=itu, profile=high",
    "video/x-h264, variant=videosoft",
    "video/x-h264, variant=lead, lcevc=true",
    "video/x-h264, variant=weird, profile=nope",
    "video/x-h264, profile=constrained-baseline, lcevc=true",
    "video/x-h264, profile=high-4:4:4-intra, stream-format=avc, alignment=au, codec_data=(buffer)0102",
    "video/x-h265, profile=main-10",
    "video/x-h265, profile=nope",
    "video/x-h265",
    "video/x-h266, profile=main-4:4:4-16",
    "video/x-h266, profile=x",
    "video/x-dirac, profile=vc2-low-delay",
    "video/x-dirac, profile=vc2-simple",
    "video/x-dirac, profile=vc2-main",
    "video/x-dirac, profile=other",
    "video/x-divx, divxversion=5",
    "video/x-divx, divxversion=2",
    "video/x-msmpeg, msmpegversion=43",
    "video/x-msmpeg, msmpegversion=50",
    "video/x-truemotion, trueversion=1",
    "video/x-truemotion, trueversion=2",
    "video/x-truemotion, trueversion=3",
    "video/x-xan, wcversion=4",
    "video/x-xan, wcversion=0",
    "video/x-indeo, indeoversion=5",
    "video/x-indeo, indeoversion=1",
    "audio/x-wma, wmaversion=1",
    "audio/x-wma, wmaversion=3",
    "audio/x-wma, wmaversion=4",
    "video/x-wmv, wmvversion=3, format=MSS2",
    "video/x-wmv, wmvversion=2, format=WMV2",
    "video/x-wmv, wmvversion=1",
    "video/x-wmv, wmvversion=9",
    "audio/x-mace, maceversion=3",
    "audio/x-mace, maceversion=6",
    "audio/x-mace, maceversion=4",
    "video/x-svq, svqversion=1",
    "video/x-svq, svqversion=3",
    "video/x-svq, svqversion=2",
    "video/x-asus, asusversion=2",
    "video/x-asus, asusversion=3",
    "video/x-ati-vcr, vcrversion=1",
    "video/x-ati-vcr, vcrversion=5",
    "audio/x-adpcm, layout=swf",
    "audio/x-adpcm, layout=microsoft",
    "audio/x-adpcm, layout=quicktime",
    "audio/x-adpcm, layout=westwood",
    "audio/x-adpcm, layout=yamaha",
    "audio/x-adpcm, layout=dvi",
    "audio/x-adpcm, layout=(int)3",
    "audio/mpeg, mpegversion=1, layer=1",
    "audio/mpeg, mpegversion=1, layer=2",
    "audio/mpeg, mpegversion=1, layer=3",
    "audio/mpeg, mpegversion=1, layer=4",
    "audio/mpeg, mpegversion=1",
    "audio/mpeg, mpegversion=2",
    "audio/mpeg, mpegversion=4, stream-format=adts, rate=44100, channels=2",
    "audio/mpeg, mpegversion=3",
    "audio/x-pn-realaudio, raversion=1",
    "audio/x-pn-realaudio, raversion=2",
    "audio/x-pn-realaudio, raversion=8",
    "audio/x-pn-realaudio, raversion=3",
    "video/x-pn-realvideo, rmversion=1",
    "video/x-pn-realvideo, rmversion=4",
    "video/x-pn-realvideo, rmversion=5",
    "video/mpeg, mpegversion=1",
    "video/mpeg, mpegversion=2, profile=high",
    "video/mpeg, mpegversion=2, profile=main, systemstream=false",
    "video/mpeg, mpegversion=4, profile=advanced-simple",
    "video/mpeg, mpegversion=4, profile=nope",
    "video/mpeg, mpegversion=1, profile=simple",
    "video/mpeg, mpegversion=2, systemstream=true",
    "video/mpeg, mpegversion=4, systemstream=true",
    "video/mpeg, mpegversion=7",
    "video/mpeg, systemstream=true",
    "video/x-dv, systemstream=true",
    "video/x-dv, systemstream=false",
    "audio/x-raw",
    "audio/x-raw, format=NOPE",
    "video/x-tscc, tsccversion=1",
    "video/x-tscc, tsccversion=2",
    "video/x-tscc, tsccversion=3",
    "video/x-hap, variant=Hap5",
    "application/x-rtp, media=video, encoding-name=H264, clock-rate=90000",
    "application/x-rtp, media=audio, encoding-name=X-ASF-PF",
    "application/x-rtp, media=application, encoding-name=X-GST",
    "application/x-rtp, media=audio, encoding-name=\"\"",
    "application/x-rtp, media=(int)1, encoding-name=H264",
    "application/x-rtp, media=text, encoding-name=T140",
    "application/x-rtp, media=video",
    "application/x-something-unknown, foo=1, bar=2",
    "audio/x-unknown   ",
    "video/x-matroska, width=10, height=10, framerate=25/1",
    "image/png, width=3",
};

fn rawFormats() void {
    var f: c_uint = 1;
    while (f < 200) : (f += 1) {
        const name = c.gst_video_format_to_string(f);
        if (name == null or std.mem.eql(u8, z(name), "UNKNOWN")) continue;
        const caps = c.gst_caps_new_simple("video/x-raw", "format", c.G_TYPE_STRING, name, NONE);
        const d = c.gst_pb_utils_get_codec_description(caps);
        out("vraw {s} {s}", .{ z(name), z(d) });
        c.g_free(d);
        c.gst_caps_unref(caps);
    }
    var a: c_uint = 1;
    while (a < 64) : (a += 1) {
        const name = c.gst_audio_format_to_string(a);
        if (name == null or std.mem.eql(u8, z(name), "UNKNOWN")) continue;
        const caps = c.gst_caps_new_simple("audio/x-raw", "format", c.G_TYPE_STRING, name, NONE);
        const d = c.gst_pb_utils_get_codec_description(caps);
        out("araw {s} {s}", .{ z(name), z(d) });
        c.g_free(d);
        c.gst_caps_unref(caps);
    }
}

fn showMsg(m: [*c]c.GstMessage) void {
    if (m == null) {
        out("  msg (null)", .{});
        return;
    }
    const s = c.gst_structure_to_string(c.gst_message_get_structure(m));
    const is = c.gst_is_missing_plugin_message(m);
    const d = c.gst_missing_plugin_message_get_description(m);
    const det = c.gst_missing_plugin_message_get_installer_detail(m);
    out("  msg {s}\n    is {d} desc {s}\n    detail {s} sid {s}", .{ z(s), is, z(d), z(det), z(c.gst_missing_plugin_message_get_stream_id(m)) });
    c.gst_missing_plugin_message_set_stream_id(m, "stream-9");
    out("    sid {s}", .{z(c.gst_missing_plugin_message_get_stream_id(m))});
    c.g_free(s);
    c.g_free(d);
    c.g_free(det);
    c.gst_message_unref(m);
}

fn custom(st: [*c]const u8) void {
    const e: *c.GstElement = @ptrCast(@alignCast(c.g_object_new(c.gst_bin_get_type(), "name", "el", NONE)));
    const s = c.gst_structure_from_string(st, null);
    showMsg(c.gst_message_new_element(@ptrCast(e), s));
    c.gst_object_unref(e);
}

pub fn main() void {
    c.g_set_prgname("difftest");
    c.gst_init(null, null);
    c.gst_pb_utils_init();
    c.gst_pb_utils_init();
    var maj: c.guint = 0;
    var min: c.guint = 0;
    var mic: c.guint = 0;
    var nano: c.guint = 9;
    c.gst_plugins_base_version(&maj, &min, &mic, &nano);
    c.gst_plugins_base_version(null, null, null, null);
    const vs = c.gst_plugins_base_version_string();
    out("version {d}.{d}.{d}.{d} {s}", .{ maj, min, mic, nano, z(vs) });
    c.g_free(vs);

    const types = @embedFile("pbtypes.txt");
    var it = std.mem.tokenizeScalar(u8, types, '\n');
    var name: [256]u8 = undefined;
    while (it.next()) |line| {
        @memcpy(name[0..line.len], line);
        name[line.len] = 0;
        const caps = c.gst_caps_new_empty_simple(@ptrCast(&name));
        describe(caps);
        c.gst_caps_set_simple(caps, "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), NONE);
        describe(caps);
        c.gst_caps_unref(caps);
    }
    for (DYNAMIC) |s| describeStr(s);
    rawFormats();

    for ([_][*c]const u8{ "cdda", "dvd", "rtsp", "mms", "http", "file", "Ftp", "" }) |p| {
        const a = c.gst_pb_utils_get_source_description(p);
        const b = c.gst_pb_utils_get_sink_description(p);
        const e = c.gst_pb_utils_get_element_description(p);
        const d1 = c.gst_missing_uri_source_installer_detail_new(p);
        const d2 = c.gst_missing_uri_sink_installer_detail_new(p);
        const d3 = c.gst_missing_element_installer_detail_new(p);
        out("proto {s}: {s} | {s} | {s}\n  {s}\n  {s}\n  {s}", .{ z(p), z(a), z(b), z(e), z(d1), z(d2), z(d3) });
        c.g_free(a);
        c.g_free(b);
        c.g_free(e);
        c.g_free(d1);
        c.g_free(d2);
        c.g_free(d3);
    }
    const e2 = c.gst_pb_utils_get_element_description("GStreamer x");
    out("elem {s}", .{z(e2)});
    c.g_free(e2);

    const el: *c.GstElement = @ptrCast(@alignCast(c.g_object_new(c.gst_bin_get_type(), "name", "src", NONE)));
    showMsg(c.gst_missing_uri_source_message_new(el, "rtsp"));
    showMsg(c.gst_missing_uri_sink_message_new(el, "smb"));
    showMsg(c.gst_missing_element_message_new(el, "vp9|enc"));
    const dc = c.gst_caps_from_string("video/x-h264, profile=high, width=10, height=20, framerate=30/1, stream-format=byte-stream, codec_data=(buffer)00");
    showMsg(c.gst_missing_decoder_message_new(el, dc));
    showMsg(c.gst_missing_encoder_message_new(el, dc));
    c.gst_caps_unref(dc);
    const mux = c.gst_caps_from_string("video/quicktime, variant=iso");
    showMsg(c.gst_missing_decoder_message_new(el, mux));
    showMsg(c.gst_missing_encoder_message_new(el, mux));
    c.gst_caps_unref(mux);
    custom("missing-plugin, type=urisource, detail=foo");
    custom("missing-plugin, type=urisink, detail=foo");
    custom("missing-plugin, type=element, detail=foo, name=\"\"");
    custom("missing-plugin, type=decoder, detail=(GstCaps)\"audio/x-vorbis\"");
    custom("missing-plugin, type=encoder, detail=(GstCaps)\"audio/x-vorbis\"");
    custom("missing-plugin, type=decoder, detail=foo");
    custom("missing-plugin, type=element, detail=(int)5");
    custom("missing-plugin, type=element, detail=\"\"");
    custom("missing-plugin, type=urisource");
    custom("missing-plugin, type=weird, detail=x");
    custom("missing-plugin, detail=x");
    custom("missing-plugin, type=encoder, detail=(GstCaps)ANY");
    custom("missing-plugin, type=encoder, detail=(GstCaps)EMPTY");
    custom("missing-plugin, type=decoder, detail=(GstCaps)\"audio/x-vorbis\", name=\"my|name|x\"");
    custom("other-thing, type=decoder");

    out("checks", .{});
    _ = c.gst_pb_utils_get_codec_description(null);
    _ = c.gst_pb_utils_get_decoder_description(null);
    _ = c.gst_pb_utils_get_encoder_description(null);
    _ = c.gst_pb_utils_get_caps_description_flags(null);
    _ = c.gst_pb_utils_get_source_description(null);
    _ = c.gst_pb_utils_get_sink_description(null);
    _ = c.gst_pb_utils_get_element_description(null);
    const notcaps = c.gst_buffer_new();
    _ = c.gst_pb_utils_get_codec_description(@ptrCast(notcaps));
    _ = c.gst_pb_utils_get_caps_description_flags(@ptrCast(notcaps));
    const nf = c.gst_caps_from_string("video/x-h264, profile={ high, main }");
    out("  nonfixed {s}", .{z(c.gst_pb_utils_get_codec_description(nf))});
    _ = c.gst_pb_utils_get_decoder_description(nf);
    _ = c.gst_pb_utils_get_encoder_description(nf);
    out("  nonfixed flags {d}", .{c.gst_pb_utils_get_caps_description_flags(nf)});
    const tl = c.gst_tag_list_new_empty();
    const any = c.gst_caps_new_any();
    const empty = c.gst_caps_new_empty();
    const vc = c.gst_caps_from_string("audio/x-vorbis");
    out("  tl {d}", .{c.gst_pb_utils_add_codec_description_to_tag_list(null, null, vc)});
    out("  tl {d}", .{c.gst_pb_utils_add_codec_description_to_tag_list(@ptrCast(notcaps), null, vc)});
    out("  tl {d}", .{c.gst_pb_utils_add_codec_description_to_tag_list(tl, "nosuchtag", vc)});
    out("  tl {d}", .{c.gst_pb_utils_add_codec_description_to_tag_list(tl, c.GST_TAG_BITRATE, vc)});
    out("  tl {d}", .{c.gst_pb_utils_add_codec_description_to_tag_list(tl, null, null)});
    out("  tl {d}", .{c.gst_pb_utils_add_codec_description_to_tag_list(tl, null, @ptrCast(notcaps))});
    for ([_][*c]c.GstCaps{ null, any, empty, nf }) |bad| {
        out("  inst {d} {d}", .{ @intFromBool(c.gst_missing_decoder_installer_detail_new(bad) != null), @intFromBool(c.gst_missing_encoder_installer_detail_new(bad) != null) });
        out("  msgs {d} {d}", .{ @intFromBool(c.gst_missing_decoder_message_new(el, bad) != null), @intFromBool(c.gst_missing_encoder_message_new(el, bad) != null) });
    }
    out("  m {d}", .{@intFromBool(c.gst_missing_decoder_message_new(null, vc) != null)});
    out("  m {d}", .{@intFromBool(c.gst_missing_element_message_new(@ptrCast(notcaps), "x") != null)});
    out("  m {d}", .{@intFromBool(c.gst_missing_uri_source_message_new(el, null) != null)});
    out("  m {d}", .{@intFromBool(c.gst_missing_uri_sink_message_new(null, "x") != null)});
    out("  m {d}", .{@intFromBool(c.gst_missing_element_message_new(el, null) != null)});
    out("  d {d} {d} {d}", .{ @intFromBool(c.gst_missing_uri_source_installer_detail_new(null) != null), @intFromBool(c.gst_missing_uri_sink_installer_detail_new(null) != null), @intFromBool(c.gst_missing_element_installer_detail_new(null) != null) });
    out("  is {d} {d}", .{ c.gst_is_missing_plugin_message(null), c.gst_is_missing_plugin_message(@ptrCast(notcaps)) });
    const eos = c.gst_message_new_eos(null);
    out("  is eos {d}", .{c.gst_is_missing_plugin_message(eos)});
    out("  eos {s} {s}", .{ z(c.gst_missing_plugin_message_get_description(eos)), z(c.gst_missing_plugin_message_get_installer_detail(eos)) });
    c.gst_missing_plugin_message_set_stream_id(eos, "x");
    out("  eos sid {s}", .{z(c.gst_missing_plugin_message_get_stream_id(eos))});
    c.gst_object_unref(el);
}
