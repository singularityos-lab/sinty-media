const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const init = @import("init.zig");
const formats = @import("formats.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Fmt = formats.Fmt;
const Caps = c.GstCaps;
const VNONE = @as(?*anyopaque, null);

const F_CONTAINER: u32 = 1 << 0;
const F_AUDIO: u32 = 1 << 1;
const F_VIDEO: u32 = 1 << 2;
const F_SUB: u32 = 1 << 4;
const F_TAG: u32 = 1 << 5;

const DROP = [_][*:0]const u8{ "codec_data", "streamheader", "palette_data", "pixel-aspect-ratio", "framerate", "leaf_size", "packet_size", "block_align", "metadata-interval", "width", "depth", "height", "channels", "rate", "parsed", "framed", "stream-format", "alignment", "config", "clock-rate", "timestamp-offset", "maxps", "seqnum-offset", "npt-start", "npt-stop", "play-speed", "play-scale", "dynamic_range" };

pub fn cleanCaps(caps: [*c]const Caps) [*c]Caps {
    const r = c.gst_caps_copy(caps);
    const s = c.gst_caps_get_structure(r, 0);
    for (DROP) |f| c.gst_structure_remove_field(s, f);
    return r;
}

const Pair = struct { []const u8, [:0]const u8 };

const MPEG2V = [_]Pair{ .{ "simple", "Simple" }, .{ "main", "Main" }, .{ "high", "High" } };

const MPEG4V = [_]Pair{
    .{ "simple", "Simple" },                                    .{ "simple-scalable", "Simple Scalable" },
    .{ "core", "Core" },                                        .{ "main", "Main" },
    .{ "n-bit", "N-bit" },                                      .{ "scalable", "Scalable" },
    .{ "hybrid", "Hybrid" },                                    .{ "advanced-real-time-simple", "Advanced Real-Time Simple" },
    .{ "core-scalable", "Core-Scalable" },                      .{ "advanced-coding-efficiency", "Advanced Coding Efficiency" },
    .{ "advanced-core", "Advanced Core" },                      .{ "advanced-scalable-texture", "Advanced Scalable Texture" },
    .{ "simple-face", "Simple Face Animation" },                .{ "simple-fba", "Simple FBA" },
    .{ "simple-studio", "Simple Studio" },                      .{ "core-studio", "Core Studio" },
    .{ "advanced-simple", "Advanced Simple" },                  .{ "fine-granularity-scalable", "Fine Granularity Scalable" },
    .{ "basic-animated-texture", "Basic Animated Texture" },    .{ "baseline", "Baseline Profile" },
};

const H264 = [_]Pair{
    .{ "baseline", "Baseline" },                 .{ "constrained-baseline", "Constrained Baseline" },
    .{ "main", "Main" },                         .{ "extended", "Extended" },
    .{ "high", "High" },                         .{ "high-10-intra", "High 10 Intra" },
    .{ "high-10", "High 10" },                   .{ "high-4:2:2-intra", "High 4:2:2 Intra" },
    .{ "high-4:2:2", "High 4:2:2" },             .{ "high-4:4:4-intra", "High 4:4:4 Intra" },
    .{ "high-4:4:4", "High 4:4:4" },             .{ "cavlc-4:4:4-intra", "CAVLC 4:4:4 Intra" },
    .{ "multiview-high", "Multiview High" },     .{ "stereo-high", "Stereo High" },
    .{ "scalable-constrained-baseline", "Scalable Constrained Baseline" },
    .{ "scalable-baseline", "Scalable Baseline" },
    .{ "scalable-high", "Scalable High" },
};

const H265 = [_]Pair{
    .{ "main", "Main" },                           .{ "main-10", "Main 10" },
    .{ "main-12", "Main 12" },                     .{ "main-4:2:2-10", "Main 4:2:2 10" },
    .{ "main-4:2:2-12", "Main 4:2:2 12" },         .{ "main-4:4:4", "Main 4:4:4" },
    .{ "main-4:4:4-10", "Main 4:4:4 10" },         .{ "main-4:4:4-12", "Main 4:4:4 12" },
    .{ "main-4:4:4-16-intra", "Main 4:4:4 16 Intra" },
    .{ "main-still-picture", "Main Still Picture" },
};

const H266 = [_]Pair{
    .{ "main-10", "Main 10" },
    .{ "multilayer-main-10", "Multilayer Main 10" },
    .{ "main-10-still-picture", "Main 10 Still Picture" },
    .{ "main-4:4:4-10", "Main 4:4:4 10" },
    .{ "multilayer-main-4:4:4-10", "Multilayer Main 4:4:4 10" },
    .{ "main-4:4:4-10-still-picture", "Main 4:4:4 10 Still Picture" },
    .{ "main-12", "Main 12" },
    .{ "main-12-intra", "Main 12 Intra" },
    .{ "main-12-still-picture", "Main 12 Still Picture" },
    .{ "main-4:4:4-12", "Main 4:4:4 12" },
    .{ "main-4:4:4-12-intra", "Main 4:4:4 12 Intra" },
    .{ "main-4:4:4-12-still-picture", "Main 4:4:4 12 Still Picture" },
    .{ "main-4:4:4-16", "Main 4:4:4 16" },
};

fn profileName(map: []const Pair, nick: ?[*:0]const u8) ?[*:0]const u8 {
    const n = std.mem.span(nick orelse return null);
    for (map) |p| if (std.mem.eql(u8, p[0], n)) return p[1].ptr;
    return null;
}

fn str(s: ?*const c.GstStructure, f: [*:0]const u8) ?[*:0]const u8 {
    const v = c.gst_structure_get_string(s, f);
    return if (v != null) @ptrCast(v) else null;
}

fn eq(a: ?[*:0]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, std.mem.span(a.?), b);
}

fn int(s: ?*const c.GstStructure, f: [*:0]const u8, v: *c.gint) bool {
    return c.gst_structure_get_int(s, f, v) != 0;
}

fn dup(s: [*c]const u8) [*c]u8 {
    return c.g_strdup(s);
}

fn pick(v: ?[*:0]const u8, comptime fallback: [:0]const u8, comptime table: anytype) [*c]const u8 {
    if (v == null) return fallback;
    inline for (table) |e| if (eq(v, e[0])) return e[1];
    return fallback;
}

fn rawVideo(s: ?*const c.GstStructure) [*c]u8 {
    const name = str(s, "format") orelse return dup(init.tr("Uncompressed video"));
    const f = c.gst_video_format_from_string(name);
    if (f == c.GST_VIDEO_FORMAT_UNKNOWN) return dup(init.tr("Uncompressed video"));
    const fi = c.gst_video_format_get_info(f);
    const fl = fi[0].flags;
    if (fl & c.GST_VIDEO_FORMAT_FLAG_GRAY != 0) return dup(init.tr("Uncompressed gray"));
    if (fl & c.GST_VIDEO_FORMAT_FLAG_YUV != 0) {
        const w = @as(c.gint, 1) << @intCast(fi[0].w_sub[1]);
        const h = @as(c.gint, 1) << @intCast(fi[0].h_sub[1]);
        const subs: [*c]const u8 = if (w == 1 and h == 1) "4:4:4" else if (w == 2 and h == 1) "4:2:2" else if (w == 2 and h == 2) "4:2:0" else if (w == 4 and h == 1) "4:1:1" else "";
        const semi: c.guint = if (fl & c.GST_VIDEO_FORMAT_FLAG_ALPHA != 0) 3 else 2;
        if (fi[0].n_planes == 1) return c.g_strdup_printf(init.tr("Uncompressed packed YUV %s"), subs);
        if (fi[0].n_planes == semi) return c.g_strdup_printf(init.tr("Uncompressed semi-planar YUV %s"), subs);
        return c.g_strdup_printf(init.tr("Uncompressed planar YUV %s"), subs);
    }
    if (fl & c.GST_VIDEO_FORMAT_FLAG_RGB != 0) {
        const rgb: [*c]const u8 = if (fl & c.GST_VIDEO_FORMAT_FLAG_ALPHA != 0) "RGBA" else "RGB";
        const bits: c.gint = @intCast(fi[0].bits);
        if (fl & c.GST_VIDEO_FORMAT_FLAG_PALETTE != 0) return c.g_strdup_printf(init.tr("Uncompressed palettized %d-bit %s"), bits, rgb);
        return c.g_strdup_printf(init.tr("Uncompressed %d-bit %s"), bits, rgb);
    }
    return dup(init.tr("Uncompressed video"));
}

fn versioned(s: ?*const c.GstStructure, field: [*:0]const u8, comptime fmt: [*:0]const u8, comptime plain: [*:0]const u8, ok: []const c.gint) [*c]u8 {
    var v: c.gint = 0;
    _ = int(s, field, &v);
    for (ok) |o| if (o == v) return c.g_strdup_printf(fmt, v);
    return dup(plain);
}

fn dynamicDesc(t: []const u8, s: ?*const c.GstStructure) [*c]u8 {
    const is = struct {
        fn f(a: []const u8, comptime b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    if (is(t, "video/x-raw")) return rawVideo(s);
    if (is(t, "video/x-h263")) return dup(pick(str(s, "variant"), "H.263", .{ .{ "itu", "ITU H.26n" }, .{ "lead", "Lead H.263" }, .{ "microsoft", "Microsoft H.263" }, .{ "vdolive", "VDOLive" }, .{ "vivo", "Vivo H.263" }, .{ "xirlink", "Xirlink H.263" } }));
    if (is(t, "video/x-h264")) {
        const base = pick(str(s, "variant"), "H.264", .{ .{ "itu", "ITU H.264" }, .{ "videosoft", "Videosoft H.264" }, .{ "lead", "Lead H.264" } });
        const prof = profileName(&H264, str(s, "profile"));
        var lcevc: c.gboolean = 0;
        _ = c.gst_structure_get_boolean(s, "lcevc", &lcevc);
        const tail: [*c]const u8 = if (lcevc != 0) " (LCEVC)" else "";
        if (prof) |p| return c.g_strdup_printf("%s (%s Profile)%s", base, p, tail);
        return c.g_strdup_printf("%s%s", base, tail);
    }
    if (is(t, "video/x-h265") or is(t, "video/x-h266")) {
        const h265 = is(t, "video/x-h265");
        const prof = profileName(if (h265) &H265 else &H266, str(s, "profile"));
        const name: [*c]const u8 = if (h265) "H.265" else "H.266";
        if (prof) |p| return c.g_strdup_printf("%s (%s Profile)", name, p);
        return dup(name);
    }
    if (is(t, "video/x-dirac")) {
        const p = str(s, "profile") orelse return dup("Dirac");
        const v = pick(p, "", .{ .{ "vc2-low-delay", "VC-2 Low Delay Profile" }, .{ "vc2-simple", "VC-2 Simple Profile" }, .{ "vc2-main", "VC-2 Main Profile" } });
        if (v[0] == 0) return dup("Dirac");
        return c.g_strdup_printf("Dirac (%s)", v);
    }
    if (is(t, "video/x-divx")) {
        var v: c.gint = 0;
        if (!int(s, "divxversion", &v) or v <= 2) return dup("DivX MPEG-4");
        return c.g_strdup_printf(init.tr("DivX MPEG-4 Version %d"), v);
    }
    if (is(t, "video/x-msmpeg")) {
        var v: c.gint = 0;
        if (!int(s, "msmpegversion", &v) or v < 40 or v > 49) return dup("Microsoft MPEG-4 4.x");
        return c.g_strdup_printf("Microsoft MPEG-4 4.%d", @rem(v, 10));
    }
    if (is(t, "video/x-truemotion")) {
        var v: c.gint = 0;
        _ = int(s, "trueversion", &v);
        return dup(switch (v) {
            1 => "Duck TrueMotion 1",
            2 => "TrueMotion 2.0",
            else => "TrueMotion",
        });
    }
    if (is(t, "video/x-xan")) {
        var v: c.gint = 0;
        if (!int(s, "wcversion", &v) or v < 1) return dup("Xan Wing Commander");
        return c.g_strdup_printf("Xan Wing Commander %u", v);
    }
    if (is(t, "video/x-indeo")) {
        var v: c.gint = 0;
        if (!int(s, "indeoversion", &v) or v < 2) return dup("Intel Indeo");
        return c.g_strdup_printf("Intel Indeo %u", v);
    }
    if (is(t, "audio/x-wma")) {
        var v: c.gint = 0;
        _ = int(s, "wmaversion", &v);
        if (v >= 1 and v <= 3) return c.g_strdup_printf("Windows Media Audio %d", v + 6);
        return dup("Windows Media Audio");
    }
    if (is(t, "video/x-wmv")) {
        var v: c.gint = 0;
        _ = int(s, "wmvversion", &v);
        const f = str(s, "format");
        if (v >= 1 and v <= 3) {
            if (f != null and std.mem.startsWith(u8, std.mem.span(f.?), "MSS")) return c.g_strdup_printf("Windows Media Video %d Screen", v + 6);
            return c.g_strdup_printf("Windows Media Video %d", v + 6);
        }
        return dup("Windows Media Video");
    }
    if (is(t, "audio/x-mace")) return versioned(s, "maceversion", "MACE-%d", "MACE", &.{ 3, 6 });
    if (is(t, "video/x-svq")) return versioned(s, "svqversion", "Sorensen Video %d", "Sorensen Video", &.{ 1, 3 });
    if (is(t, "video/x-asus")) return versioned(s, "asusversion", "Asus Video %d", "Asus Video", &.{ 1, 2 });
    if (is(t, "video/x-ati-vcr")) return versioned(s, "vcrversion", "ATI VCR %d", "ATI VCR", &.{ 1, 2 });
    if (is(t, "audio/x-adpcm")) {
        const v = c.gst_structure_get_value(s, "layout");
        if (v != null and c.g_type_check_value_holds(v, c.G_TYPE_STRING) != 0) {
            const l = c.g_value_get_string(v);
            if (l != null) {
                const known = pick(@ptrCast(l), "", .{ .{ "swf", "Shockwave ADPCM" }, .{ "microsoft", "Microsoft ADPCM" }, .{ "quicktime", "Quicktime ADPCM" }, .{ "westwood", "Westwood ADPCM" }, .{ "yamaha", "Yamaha ADPCM" } });
                if (known[0] != 0) return dup(known);
                const up = c.g_ascii_strup(l, -1);
                const r = c.g_strdup_printf("%s ADPCM", up);
                c.g_free(up);
                return r;
            }
        }
        return dup("ADPCM");
    }
    if (is(t, "audio/mpeg")) {
        var v: c.gint = 0;
        var layer: c.gint = 0;
        _ = int(s, "mpegversion", &v);
        return switch (v) {
            1 => if (int(s, "layer", &layer) and layer >= 1 and layer <= 3) c.g_strdup_printf("MPEG-1 Layer %d (MP%d)", layer, layer) else dup("MPEG-1 Audio"),
            2 => dup("MPEG-2 AAC"),
            4 => dup("MPEG-4 AAC"),
            else => dup("MPEG Audio"),
        };
    }
    if (is(t, "audio/x-pn-realaudio")) {
        var v: c.gint = 0;
        _ = int(s, "raversion", &v);
        return dup(switch (v) {
            1 => "RealAudio 14k4bps",
            2 => "RealAudio 28k8bps",
            8 => "RealAudio G2 (Cook)",
            else => "RealAudio",
        });
    }
    if (is(t, "video/x-pn-realvideo")) {
        var v: c.gint = 0;
        _ = int(s, "rmversion", &v);
        if (v >= 1 and v <= 4) return c.g_strdup_printf("RealVideo %d.0", v);
        return dup("RealVideo");
    }
    if (is(t, "video/mpeg")) {
        var sys: c.gboolean = 0;
        if (c.gst_structure_get_boolean(s, "systemstream", &sys) == 0) sys = 0;
        var v: c.gint = 0;
        if (int(s, "mpegversion", &v) and v > 0 and v <= 4) {
            if (sys != 0) return c.g_strdup_printf("MPEG-%d System Stream", v);
            const prof = if (v == 4) profileName(&MPEG4V, str(s, "profile")) else if (v == 2) profileName(&MPEG2V, str(s, "profile")) else null;
            if (prof) |p| return c.g_strdup_printf("MPEG-%d Video (%s Profile)", v, p);
            return c.g_strdup_printf("MPEG-%d Video", v);
        }
        return dup("MPEG Video");
    }
    if (is(t, "audio/x-raw")) {
        const name = str(s, "format");
        const f = if (name) |n| c.gst_audio_format_from_string(n) else c.GST_AUDIO_FORMAT_UNKNOWN;
        if (f == c.GST_AUDIO_FORMAT_UNKNOWN) return dup(init.tr("Uncompressed audio"));
        const fi = c.gst_audio_format_get_info(f);
        const kind: [*c]const u8 = if (fi[0].flags & c.GST_AUDIO_FORMAT_FLAG_FLOAT != 0) "floating-point" else "PCM";
        return c.g_strdup_printf(init.tr("Raw %d-bit %s audio"), fi[0].depth, kind);
    }
    if (is(t, "video/x-tscc")) {
        var v: c.gint = 0;
        _ = int(s, "tsccversion", &v);
        if (v == 1 or v == 2) return c.g_strdup_printf("TechSmith Screen Capture %d", v);
        return dup("TechSmith Screen Capture");
    }
    if (is(t, "video/x-hap")) return dup(pick(str(s, "variant"), "Hap", .{ .{ "Hap1", "Hap" }, .{ "Hap5", "Hap Alpha" }, .{ "HapY", "Hap Q" }, .{ "HapM", "Hap Q Alpha" }, .{ "HapA", "Hap Alpha-Only" }, .{ "Hap7", "Hap R" }, .{ "HapH", "Hap HDR" } }));
    return null;
}

fn infoDesc(f: *const Fmt, caps: [*c]const Caps) [*c]u8 {
    init.ensureLocale();
    if (f.d) |d| return dup(init.tr(d.ptr));
    return dynamicDesc(f.t, c.gst_caps_get_structure(caps, 0));
}

pub fn find(caps: [*c]const Caps) ?*const Fmt {
    const s = c.gst_caps_get_structure(caps, 0);
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(c.gst_structure_get_name(s))));
    for (&formats.formats) |*f| {
        if (!std.mem.eql(u8, name, f.t)) continue;
        if (f.f & formats.SYSTEMSTREAM == 0) return f;
        var sys: c.gboolean = 0;
        if (c.gst_structure_get_boolean(s, "systemstream", &sys) != 0 and sys != 0) return f;
    }
    return null;
}

fn rtpFormat(caps: [*c]const Caps, media: []const u8) ?[*c]u8 {
    const s = c.gst_caps_get_structure(caps, 0);
    if (c.gst_structure_has_name(s, "application/x-rtp") == 0) return null;
    if (c.gst_structure_has_field_typed(s, "media", c.G_TYPE_STRING) == 0) return null;
    if (!eq(str(s, "media"), media)) return null;
    const e = str(s, "encoding-name") orelse return null;
    const enc = std.mem.span(e);
    if (enc.len == 0) return null;
    if (std.mem.eql(u8, enc, "X-ASF-PF")) return dup("Windows Media");
    if (std.mem.startsWith(u8, enc, "X-")) return dup(e + 2);
    return dup(e);
}

pub export fn gst_pb_utils_get_source_description(protocol: [*c]const c.gchar) [*c]c.gchar {
    if (!check.that(protocol != null, "gst_pb_utils_get_source_description", "protocol != NULL")) return null;
    init.ensureLocale();
    const p: [*:0]const u8 = @ptrCast(protocol);
    if (eq(p, "cdda")) return dup(init.tr("Audio CD source"));
    if (eq(p, "dvd")) return dup(init.tr("DVD source"));
    if (eq(p, "rtsp")) return dup(init.tr("Real Time Streaming Protocol (RTSP) source"));
    if (eq(p, "mms")) return dup(init.tr("Microsoft Media Server (MMS) protocol source"));
    const up = c.g_ascii_strup(protocol, -1);
    const r = c.g_strdup_printf(init.tr("%s protocol source"), up);
    c.g_free(up);
    return r;
}

pub export fn gst_pb_utils_get_sink_description(protocol: [*c]const c.gchar) [*c]c.gchar {
    if (!check.that(protocol != null, "gst_pb_utils_get_sink_description", "protocol != NULL")) return null;
    const up = c.g_ascii_strup(protocol, -1);
    const r = c.g_strdup_printf("%s protocol sink", up);
    c.g_free(up);
    return r;
}

fn codecWord(caps: [*c]const Caps, comptime fname: []const u8, comptime rtp: [3][*:0]const u8, comptime mux: [*:0]const u8, comptime codec: [*:0]const u8) [*c]c.gchar {
    if (!check.that(caps != null, fname, "caps != NULL")) return null;
    if (!check.that(check.isCaps(caps), fname, "GST_IS_CAPS (caps)")) return null;
    const tmp = cleanCaps(caps);
    if (!check.that(c.gst_caps_is_fixed(tmp) != 0, fname, "gst_caps_is_fixed (tmp)")) return null;
    init.ensureLocale();
    var ret: [*c]u8 = undefined;
    var s: [*c]u8 = undefined;
    if (rtpFormat(tmp, "video")) |f| {
        s = f;
        ret = c.g_strdup_printf(init.tr(rtp[0]), s);
    } else if (rtpFormat(tmp, "audio")) |f| {
        s = f;
        ret = c.g_strdup_printf(init.tr(rtp[1]), s);
    } else if (rtpFormat(tmp, "application")) |f| {
        s = f;
        ret = c.g_strdup_printf(init.tr(rtp[2]), s);
    } else {
        s = gst_pb_utils_get_codec_description(tmp);
        const f = find(tmp);
        ret = c.g_strdup_printf(init.tr(if (f != null and f.?.f & F_CONTAINER != 0) mux else codec), s);
    }
    c.g_free(s);
    c.gst_caps_unref(tmp);
    return ret;
}

pub export fn gst_pb_utils_get_decoder_description(caps: [*c]const Caps) [*c]c.gchar {
    return codecWord(caps, "gst_pb_utils_get_decoder_description", .{ "%s video RTP depayloader", "%s audio RTP depayloader", "%s RTP depayloader" }, "%s demuxer", "%s decoder");
}

pub export fn gst_pb_utils_get_encoder_description(caps: [*c]const Caps) [*c]c.gchar {
    return codecWord(caps, "gst_pb_utils_get_encoder_description", .{ "%s video RTP payloader", "%s audio RTP payloader", "%s RTP payloader" }, "%s muxer", "%s encoder");
}

pub export fn gst_pb_utils_get_element_description(factory_name: [*c]const c.gchar) [*c]c.gchar {
    if (!check.that(factory_name != null, "gst_pb_utils_get_element_description", "factory_name != NULL")) return null;
    init.ensureLocale();
    const r = c.g_strdup_printf(init.tr("GStreamer element %s"), factory_name);
    if (r != null and c.g_str_has_prefix(r, factory_name) != 0) r[0] = c.g_ascii_toupper(r[0]);
    return r;
}

pub export fn gst_pb_utils_add_codec_description_to_tag_list(taglist: ?*c.GstTagList, codec_tag: [*c]const c.gchar, caps: [*c]const Caps) c.gboolean {
    const fname = "gst_pb_utils_add_codec_description_to_tag_list";
    if (!check.that(taglist != null, fname, "taglist != NULL")) return 0;
    if (!check.that(check.isTagList(taglist), fname, "GST_IS_TAG_LIST (taglist)")) return 0;
    if (!check.that(codec_tag == null or (c.gst_tag_exists(codec_tag) != 0 and c.gst_tag_get_type(codec_tag) == c.G_TYPE_STRING), fname, "codec_tag == NULL || (gst_tag_exists (codec_tag) && gst_tag_get_type (codec_tag) == G_TYPE_STRING)")) return 0;
    if (!check.that(caps != null, fname, "caps != NULL")) return 0;
    if (!check.that(check.isCaps(caps), fname, "GST_IS_CAPS (caps)")) return 0;
    const f = find(caps) orelse return 0;
    var tag = codec_tag;
    if (tag == null) {
        tag = if (f.f & F_CONTAINER != 0) c.GST_TAG_CONTAINER_FORMAT else if (f.f & F_AUDIO != 0) c.GST_TAG_AUDIO_CODEC else if (f.f & F_VIDEO != 0) c.GST_TAG_VIDEO_CODEC else if (f.f & F_SUB != 0) c.GST_TAG_SUBTITLE_CODEC else c.GST_TAG_CODEC;
    }
    const d = infoDesc(f, caps);
    c.gst_tag_list_add(taglist, c.GST_TAG_MERGE_REPLACE, tag, d, VNONE);
    c.g_free(d);
    return 1;
}

pub export fn gst_pb_utils_get_codec_description(caps: [*c]const Caps) [*c]c.gchar {
    const fname = "gst_pb_utils_get_codec_description";
    if (!check.that(caps != null, fname, "caps != NULL")) return null;
    if (!check.that(check.isCaps(caps), fname, "GST_IS_CAPS (caps)")) return null;
    const tmp = cleanCaps(caps);
    if (!check.that(c.gst_caps_is_fixed(tmp) != 0, fname, "gst_caps_is_fixed (tmp)")) return null;
    var r: [*c]u8 = undefined;
    if (find(tmp)) |f| {
        r = infoDesc(f, tmp);
    } else {
        r = c.gst_caps_to_string(tmp);
        if (c.strchr(r, ',')) |comma| {
            comma[0] = 0;
            _ = c.g_strchomp(r);
        }
    }
    c.gst_caps_unref(tmp);
    return r;
}

pub fn extension(caps: [*c]const Caps) ?[*:0]const u8 {
    const tmp = cleanCaps(caps);
    defer c.gst_caps_unref(tmp);
    const f = find(tmp) orelse return null;
    if (f.e.len > 0) return f.e.ptr;
    if (f.d != null or !std.mem.eql(u8, f.t, "audio/mpeg")) return null;
    const s = c.gst_caps_get_structure(tmp, 0);
    var v: c.gint = 0;
    var layer: c.gint = 3;
    if (!int(s, "mpegversion", &v)) return null;
    if (v == 2 or v == 4) return "aac";
    if (v != 1) return null;
    _ = int(s, "layer", &layer);
    return if (layer == 1) "mp1" else if (layer == 2) "mp2" else "mp3";
}

pub fn isTag(caps: [*c]const Caps) bool {
    const tmp = cleanCaps(caps);
    defer c.gst_caps_unref(tmp);
    const f = find(tmp) orelse return false;
    return f.f & F_TAG != 0;
}

pub export fn gst_pb_utils_get_file_extension_from_caps(caps: [*c]const Caps) [*c]c.gchar {
    const e = extension(caps) orelse return null;
    return c.g_strdup(e);
}

pub export fn gst_pb_utils_get_caps_description_flags(caps: [*c]const Caps) c.GstPbUtilsCapsDescriptionFlags {
    const fname = "gst_pb_utils_get_caps_description_flags";
    if (!check.that(caps != null, fname, "caps != NULL")) return 0;
    if (!check.that(check.isCaps(caps), fname, "GST_IS_CAPS (caps)")) return 0;
    const tmp = cleanCaps(caps);
    if (!check.that(c.gst_caps_is_fixed(tmp) != 0, fname, "gst_caps_is_fixed (tmp)")) return 0;
    const flags: c.GstPbUtilsCapsDescriptionFlags = if (find(tmp)) |f| f.f & 0xff else 0;
    c.gst_caps_unref(tmp);
    return flags;
}
