const std = @import("std");
const c = @import("c").c;

var obuf: [1 << 16]u8 = undefined;
var olen: usize = 0;

fn flush() void {
    _ = std.c.write(1, &obuf, olen);
    olen = 0;
}

fn out(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(obuf[olen..], fmt ++ "\n", args) catch blk: {
        flush();
        break :blk std.fmt.bufPrint(obuf[olen..], fmt ++ "\n", args) catch return;
    };
    olen += s.len;
    if (olen > obuf.len - 4096) flush();
}

const NONE = @as(?*anyopaque, null);

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

var seed: u64 = 0x9e3779b97f4a7c15;

fn rnd() u64 {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

fn capsStr(caps: [*c]c.GstCaps) void {
    if (caps == null) {
        out("  caps -", .{});
        return;
    }
    const s = c.gst_caps_to_string(caps);
    out("  caps {s}", .{z(s)});
    c.g_free(s);
}

fn hex(b: [*c]c.GstBuffer) void {
    if (b == null) {
        out("  buf -", .{});
        return;
    }
    var m: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &m, c.GST_MAP_READ);
    var tmp: [1024]u8 = undefined;
    var n: usize = 0;
    for (m.data[0..m.size]) |x| {
        const s = std.fmt.bufPrint(tmp[n..], "{x:0>2}", .{x}) catch break;
        n += s.len;
    }
    out("  buf {d} off {d} {d} flags {d} {s}", .{ m.size, b[0].offset, b[0].offset_end, b[0].mini_object.flags, tmp[0..n] });
    c.gst_buffer_unmap(b, &m);
}

fn av1cHead(b: [*c]c.GstBuffer) void {
    if (b == null) {
        out("  av1c -", .{});
        return;
    }
    var m: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &m, c.GST_MAP_READ);
    out("  av1c {d} {x:0>2}{x:0>2}", .{ m.size, m.data[0], m.data[1] });
    c.gst_buffer_unmap(b, &m);
}

fn aac() void {
    out("== aac", .{});
    var i: c.guint = 0;
    while (i < 18) : (i += 1) out("idx {d} {d}", .{ i, c.gst_codec_utils_aac_get_sample_rate_from_index(i) });
    for ([_]c.guint{ 96000, 7350, 44100, 1, 0, 22050, 48000 }) |r| out("rate {d} {d}", .{ r, c.gst_codec_utils_aac_get_index_from_sample_rate(r) });
    var v: u32 = 0;
    while (v < 65536) : (v += 1) {
        const b = [2]u8{ @truncate(v >> 8), @truncate(v) };
        out("{x:0>4} {s} {s} {d} {d}", .{ v, z(c.gst_codec_utils_aac_get_profile(&b, 2)), z(c.gst_codec_utils_aac_get_level(&b, 2)), c.gst_codec_utils_aac_get_sample_rate(&b, 2), c.gst_codec_utils_aac_get_channels(&b, 2) });
    }
    var k: usize = 0;
    while (k < 40000) : (k += 1) {
        var b: [7]u8 = undefined;
        const len: c.guint = @intCast(rnd() % 8);
        for (&b) |*x| x.* = @truncate(rnd());
        if (k % 3 == 0) b[0] = (b[0] & 0x07) | (@as(u8, @truncate(rnd() % 32)) << 3);
        if (k % 5 == 0) b[0] |= 0xf8;
        if (k % 7 == 0) b[0] = (b[0] & 0xf8) | 0x07;
        out("r{d} {s} {s} {d} {d}", .{ len, z(c.gst_codec_utils_aac_get_profile(&b, len)), z(c.gst_codec_utils_aac_get_level(&b, len)), c.gst_codec_utils_aac_get_sample_rate(&b, len), c.gst_codec_utils_aac_get_channels(&b, len) });
    }
    for ([_][4]u8{ .{ 0x12, 0x10, 0, 0 }, .{ 0x0a, 0x10, 0, 0 }, .{ 0x2b, 0x92, 0x08, 0x00 }, .{ 0x13, 0x88, 0, 0 } }) |cfg| {
        for ([_]c_int{ 2, 4 }) |mv| {
            const caps = c.gst_caps_new_simple("audio/mpeg", "mpegversion", c.G_TYPE_INT, mv, NONE);
            out("set {d}", .{c.gst_codec_utils_aac_caps_set_level_and_profile(caps, &cfg, 4)});
            capsStr(caps);
            c.gst_caps_unref(caps);
        }
    }
}

fn h264() void {
    out("== h264", .{});
    var v: u32 = 0;
    while (v < 65536) : (v += 1) {
        const b = [3]u8{ @truncate(v >> 8), @truncate(v), @truncate(v) };
        out("{x:0>4} {s} {s}", .{ v, z(c.gst_codec_utils_h264_get_profile(&b, 3)), z(c.gst_codec_utils_h264_get_level(&b, 3)) });
    }
    const b1 = [_]u8{ 100, 0 };
    out("short {s} {s}", .{ z(c.gst_codec_utils_h264_get_profile(&b1, 1)), z(c.gst_codec_utils_h264_get_level(&b1, 2)) });
    for ([_][*c]const u8{ "1", "1b", "1.1", "1.2", "1.3", "2", "2.1", "2.2", "3", "3.1", "3.2", "4", "4.1", "4.2", "5", "5.1", "5.2", "6", "6.1", "6.2", "7", "", "1.0", "6.3" }) |l| {
        out("idc {s} {d} {d} {d} {d}", .{ z(l), c.gst_codec_utils_h264_get_level_idc(l), c.gst_codec_utils_h265_get_level_idc(l), c.gst_codec_utils_h266_get_level_idc(l), c.gst_codec_utils_av1_get_seq_level_idx(l) });
    }
    const cd = [_]u8{ 1, 0x64, 0x00, 0x28, 0xff, 0xe1, 0 };
    var p: u8 = 0;
    var f: u8 = 0;
    var l: u8 = 0;
    out("pfl {d} {d} {d} {d}", .{ c.gst_codec_utils_h264_get_profile_flags_level(&cd, 7, &p, &f, &l), p, f, l });
    out("pfl {d}", .{c.gst_codec_utils_h264_get_profile_flags_level(&cd, 6, null, null, null)});
    const cd2 = [_]u8{ 2, 0x64, 0x00, 0x28, 0xff, 0xe1, 0 };
    out("pfl {d}", .{c.gst_codec_utils_h264_get_profile_flags_level(&cd2, 7, &p, null, null)});
    out("pfl {d}", .{c.gst_codec_utils_h264_get_profile_flags_level(&cd, 7, null, null, &l)});
    const caps = c.gst_caps_new_empty_simple("video/x-h264");
    const sps = [_]u8{ 77, 0x40, 31 };
    out("set {d}", .{c.gst_codec_utils_h264_caps_set_level_and_profile(caps, &sps, 3)});
    capsStr(caps);
    const sps2 = [_]u8{ 1, 0x40, 0 };
    out("set {d}", .{c.gst_codec_utils_h264_caps_set_level_and_profile(caps, &sps2, 3)});
    capsStr(caps);
    c.gst_caps_unref(caps);
}

fn h265() void {
    out("== h265", .{});
    var k: usize = 0;
    while (k < 120000) : (k += 1) {
        var b: [13]u8 = undefined;
        for (&b) |*x| x.* = @truncate(rnd());
        const idc: u8 = @truncate(rnd() % 13);
        b[0] = (b[0] & 0xe0) | idc;
        if (k % 2 == 0) {
            b[1] = 0;
            b[2] = 0;
            b[3] = 0;
            b[4] = 0;
            if (k % 4 == 0) {
                const bit: u5 = @truncate(rnd() % 13);
                const word = @as(u32, 1) << (31 - bit);
                std.mem.writeInt(u32, b[1..5], word, .big);
            }
        }
        if (k % 3 == 0) b[11] = @as(u8, @truncate(rnd() % 8)) * 30 + @as(u8, if (k % 6 == 0) 3 else 0);
        const len: c.guint = if (k % 10 == 0) @intCast(rnd() % 14) else if (k % 10 == 1) 11 else 13;
        out("{d} {x} {s} {s} {s}", .{ len, b[0..@min(len, 13)], z(c.gst_codec_utils_h265_get_profile(&b, len)), z(c.gst_codec_utils_h265_get_tier(&b, len)), z(c.gst_codec_utils_h265_get_level(&b, len)) });
    }
    var l: u32 = 0;
    while (l < 256) : (l += 1) {
        var b = [_]u8{0} ** 12;
        b[11] = @truncate(l);
        out("lvl {d} {s}", .{ l, z(c.gst_codec_utils_h265_get_level(&b, 12)) });
    }
    const caps = c.gst_caps_new_empty_simple("video/x-h265");
    const ptl = [_]u8{ 0x21, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 93 };
    out("set {d}", .{c.gst_codec_utils_h265_caps_set_level_tier_and_profile(caps, &ptl, 12)});
    capsStr(caps);
    c.gst_caps_unref(caps);
}

fn h266() void {
    out("== h266", .{});
    var v: u32 = 0;
    while (v < 65536) : (v += 1) {
        const b = [3]u8{ 0, @truncate(v >> 8), @truncate(v) };
        out("{x:0>4} {s} {s} {s}", .{ v, z(c.gst_codec_utils_h266_get_profile(&b, 3)), z(c.gst_codec_utils_h266_get_tier(&b, 3)), z(c.gst_codec_utils_h266_get_level(&b, 3)) });
    }
    const b = [_]u8{ 0, 2 };
    out("short {s} {s} {s}", .{ z(c.gst_codec_utils_h266_get_profile(&b, 1)), z(c.gst_codec_utils_h266_get_tier(&b, 1)), z(c.gst_codec_utils_h266_get_level(&b, 2)) });
    for ([_][6]u8{ .{ 0xff, 0, 0, 0, 0x03, 0x43 }, .{ 0xfe, 0, 0, 0, 0x03, 0x43 }, .{ 0x01, 0, 0, 0, 0x02, 0x00 }, .{ 0x01, 0, 0, 0, 0xff, 0x51 } }) |cfg| {
        for ([_]c.guint{ 4, 5, 6 }) |len| {
            const caps = c.gst_caps_new_empty_simple("video/x-h266");
            out("set {d}", .{c.gst_codec_utils_h266_caps_set_level_tier_and_profile(caps, &cfg, len)});
            capsStr(caps);
            c.gst_caps_unref(caps);
        }
    }
}

fn mpeg4() void {
    out("== mpeg4", .{});
    var v: u32 = 0;
    while (v < 256) : (v += 1) {
        const b = [1]u8{@truncate(v)};
        out("{x:0>2} {s} {s}", .{ v, z(c.gst_codec_utils_mpeg4video_get_profile(&b, 1)), z(c.gst_codec_utils_mpeg4video_get_level(&b, 1)) });
        if (v % 37 == 0) {
            const caps = c.gst_caps_new_empty_simple("video/mpeg");
            out("set {d}", .{c.gst_codec_utils_mpeg4video_caps_set_level_and_profile(caps, &b, 1)});
            capsStr(caps);
            c.gst_caps_unref(caps);
        }
    }
    const b = [1]u8{0x11};
    out("zero {s} {s}", .{ z(c.gst_codec_utils_mpeg4video_get_profile(&b, 0)), z(c.gst_codec_utils_mpeg4video_get_level(&b, 0)) });
}

fn av1() void {
    out("== av1", .{});
    var v: u32 = 0;
    while (v < 256) : (v += 1) out("lvl {d} {s}", .{ v, z(c.gst_codec_utils_av1_get_level(@truncate(v))) });
    for ([_]u8{ 0x81, 0x80, 0x01 }) |b0| {
        for ([_]u8{ 0x00, 0x01, 0x20, 0x41, 0x5f, 0x60, 0x80, 0xe0 }) |b1| {
            var b2: u32 = 0;
            while (b2 < 256) : (b2 += 1) {
                for ([_]u8{ 0x00, 0x10, 0x1f, 0x05, 0x13 }) |b3| {
                    if (b0 != 0x81 and b2 != 0x0c) continue;
                    const data = [4]u8{ b0, b1, @truncate(b2), b3 };
                    const buf = c.gst_buffer_new_memdup(&data, 4);
                    const caps = c.gst_codec_utils_av1_create_caps_from_av1c(buf);
                    out("av1c {x}", .{data});
                    capsStr(caps);
                    if (caps != null) {
                        const back = c.gst_codec_utils_av1_create_av1c_from_caps(caps);
                        av1cHead(back);
                        c.gst_buffer_unref(back);
                        c.gst_caps_unref(caps);
                    }
                    c.gst_buffer_unref(buf);
                }
            }
        }
    }
    const short = c.gst_buffer_new_memdup("\x81\x00\x0c", 3);
    capsStr(c.gst_codec_utils_av1_create_caps_from_av1c(short));
    for ([_][*c]const u8{
        "video/x-av1",
        "video/x-av1, profile=high, bit-depth-luma=(uint)10, chroma-format=4:4:4, presentation-delay=3",
        "video/x-av1, profile=professional, bit-depth-luma=(uint)12, chroma-format=4:0:0, presentation-delay=20",
        "video/x-av1, profile=main, bit-depth-luma=(uint)8, chroma-format=4:2:2, presentation-delay=-1",
        "video/x-av1, profile=other, bit-depth-luma=(int)10",
        "video/x-h264",
    }) |s| {
        const caps = c.gst_caps_from_string(s);
        out("from {s}", .{z(s)});
        av1cHead(c.gst_codec_utils_av1_create_av1c_from_caps(caps));
        c.gst_caps_unref(caps);
    }
}

fn opus() void {
    out("== opus", .{});
    const map3 = [_]u8{ 0, 2, 1, 5, 4, 3, 7, 6 };
    for ([_]u32{ 0, 48000, 16000 }) |rate| {
        var ch: u8 = 0;
        while (ch < 9) : (ch += 1) {
            for ([_]u8{ 0, 1, 255 }) |fam| {
                for ([_][2]u8{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 2, 1 }, .{ 4, 3 }, .{ 2, 3 } }) |sc| {
                    out("create {d} {d} {d} {d} {d}", .{ rate, ch, fam, sc[0], sc[1] });
                    const caps = c.gst_codec_utils_opus_create_caps(rate, ch, fam, sc[0], sc[1], &map3);
                    capsStr(caps);
                    if (caps != null) {
                        var r: u32 = 0;
                        var och: u8 = 0;
                        var of: u8 = 0;
                        var os: u8 = 0;
                        var oc: u8 = 0;
                        var om = [_]u8{0xaa} ** 256;
                        out("  parse {d} {d} {d} {d} {d} {d} {x}", .{ c.gst_codec_utils_opus_parse_caps(caps, &r, &och, &of, &os, &oc, &om), r, och, of, os, oc, om[0..8] });
                        out("  parse null {d}", .{c.gst_codec_utils_opus_parse_caps(caps, null, null, null, null, null, null)});
                        c.gst_caps_unref(caps);
                    }
                    const h = c.gst_codec_utils_opus_create_header(rate, ch, fam, sc[0], sc[1], if (fam == 0) null else &map3, 312, -5);
                    hex(h);
                    if (h != null) {
                        var r: u32 = 0;
                        var och: u8 = 0;
                        var of: u8 = 0;
                        var os: u8 = 0;
                        var oc: u8 = 0;
                        var om = [_]u8{0xaa} ** 256;
                        var ps: u16 = 0;
                        var og: i16 = 0;
                        out("  ph {d} {d} {d} {d} {d} {d} {x} {d} {d}", .{ c.gst_codec_utils_opus_parse_header(h, &r, &och, &of, &os, &oc, &om, &ps, &og), r, och, of, os, oc, om[0..8], ps, og });
                        out("  ph null {d}", .{c.gst_codec_utils_opus_parse_header(h, null, null, null, null, null, null, null, null)});
                        const hc = c.gst_codec_utils_opus_create_caps_from_header(h, null);
                        capsStr(hc);
                        if (hc != null) c.gst_caps_unref(hc);
                        out("  hflags {d}", .{h[0].mini_object.flags});
                        c.gst_buffer_unref(h);
                    }
                }
            }
        }
    }
    const comments = c.gst_buffer_new_memdup("OpusTags\x00\x00\x00\x00\x00\x00\x00\x00", 16);
    const h = c.gst_codec_utils_opus_create_header(0, 1, 0, 0, 0, null, 0, 0);
    capsStr(c.gst_codec_utils_opus_create_caps_from_header(h, comments));
    hex(comments);
    for ([_][]const u8{ "OpusHead\x00\x02\x00\x00\x80\xbb\x00\x00\x00\x00\x00", "OpusHead\x02\x02\x00\x00\x80\xbb\x00\x00\x00\x00\x00", "OpusHexd\x01\x02\x00\x00\x80\xbb\x00\x00\x00\x00\x00", "OpusHead\x01\x03\x00\x00\x80\xbb\x00\x00\x00\x00\x00", "OpusHead\x01\x03\x00\x00\x80\xbb\x00\x00\x00\x00\x01\x02\x01\x00\x01\x02", "OpusHead\x01\x03\x00\x00\x80\xbb\x00\x00\x00\x00\x01\x02\x01\x00\x01" }) |raw| {
        const b = c.gst_buffer_new_memdup(raw.ptr, raw.len);
        var r: u32 = 0;
        var och: u8 = 0;
        var om = [_]u8{0xaa} ** 256;
        out("raw {d} {d} {d} {x}", .{ c.gst_codec_utils_opus_parse_header(b, &r, &och, null, null, null, &om, null, null), r, och, om[0..4] });
        capsStr(c.gst_codec_utils_opus_create_caps_from_header(b, null));
        c.gst_buffer_unref(b);
    }
    for ([_][*c]const u8{
        "audio/x-opus, channel-mapping-family=0",
        "audio/x-opus, channel-mapping-family=0, channels=3",
        "audio/x-opus, channel-mapping-family=0, channels=1, rate=8000",
        "audio/x-opus, channel-mapping-family=1",
        "audio/x-opus, channel-mapping-family=1, channels=2",
        "audio/x-opus, channel-mapping-family=1, channels=2, stream-count=1",
        "audio/x-opus, channel-mapping-family=1, channels=2, stream-count=1, coupled-count=1",
        "audio/x-opus, channel-mapping-family=1, channels=2, stream-count=1, coupled-count=1, channel-mapping=<0>",
        "audio/x-opus, channel-mapping-family=1, channels=2, stream-count=1, coupled-count=1, channel-mapping=<0, 300>",
        "audio/x-opus, channel-mapping-family=1, channels=2, stream-count=1, coupled-count=1, channel-mapping=<0, 1>",
        "audio/x-opus, channel-mapping-family=1, channels=2, stream-count=1, coupled-count=1, channel-mapping=<0, (string)a>",
        "audio/x-opus, channel-mapping-family=1, channels=2, stream-count=1, coupled-count=1, channel-mapping={0, 1}",
    }) |s| {
        const caps = c.gst_caps_from_string(s);
        var r: u32 = 0;
        var och: u8 = 0;
        var of: u8 = 0;
        var os: u8 = 0;
        var oc: u8 = 0;
        var om = [_]u8{0xaa} ** 256;
        out("pc {s}: {d} {d} {d} {d} {d} {d} {x}", .{ z(s), c.gst_codec_utils_opus_parse_caps(caps, &r, &och, &of, &os, &oc, &om), r, och, of, os, oc, om[0..3] });
        c.gst_caps_unref(caps);
    }
}

fn mime() void {
    out("== mime", .{});
    const cd264 = c.gst_buffer_new_memdup("\x01\x64\x00\x28\xff\xe1\x00", 7);
    const cdaac = c.gst_buffer_new_memdup("\x12\x10", 2);
    const cdaac1 = c.gst_buffer_new_memdup("\x12", 1);
    const cdaac31 = c.gst_buffer_new_memdup("\xf8\x10\x00", 3);
    var hevc: [23]u8 = .{ 1, 0x61, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 93, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const cdhevc = c.gst_buffer_new_memdup(&hevc, 23);
    hevc[1] = 0xa4;
    hevc[6] = 0;
    hevc[11] = 0x07;
    const cdhevc2 = c.gst_buffer_new_memdup(&hevc, 23);
    const cdshort = c.gst_buffer_new_memdup(&hevc, 20);
    const list = [_]struct { [*c]const u8, [*c]c.GstBuffer }{
        .{ "video/x-h264", null },
        .{ "video/x-h264", cd264 },
        .{ "video/x-h264", cdaac },
        .{ "video/x-h265", null },
        .{ "video/x-h265, stream-format=hvc1", cdhevc },
        .{ "video/x-h265, stream-format=hev1", cdhevc2 },
        .{ "video/x-h265, stream-format=byte-stream", cdhevc },
        .{ "video/x-h265, stream-format=hvc1", cdshort },
        .{ "video/x-h265", cdhevc },
        .{ "video/x-h266", null },
        .{ "video/x-av1", null },
        .{ "video/x-av1, profile=main, bit-depth-luma=(uint)8", null },
        .{ "video/x-av1, profile=high, level=5.1, tier=high, bit-depth-luma=(uint)10, chroma-format=4:4:4, colorimetry=bt2100-pq", null },
        .{ "video/x-av1, profile=main, level=4.0, bit-depth-luma=(uint)8, chroma-format=4:2:0, colorimetry=bt709", null },
        .{ "video/x-av1, profile=main, level=bogus, tier=weird, bit-depth-luma=(uint)8, chroma-format=4:2:0, chroma-site=v-cosited, colorimetry=bt709", null },
        .{ "video/x-av1, profile=professional, bit-depth-luma=(uint)12, chroma-format=4:0:0, colorimetry=bt601", null },
        .{ "video/x-av1, profile=main, bit-depth-luma=(uint)8, chroma-format=4:2:2, chroma-site=v-cosited+h-cosited, colorimetry=1:1:1:1", null },
        .{ "video/x-av1, profile=main, bit-depth-luma=(uint)8, chroma-format=4:2:0", null },
        .{ "video/x-av1, profile=main, bit-depth-luma=(uint)8, chroma-format=4:1:1", null },
        .{ "video/x-vp8", null },
        .{ "video/x-vp9", null },
        .{ "video/x-vp9, profile=0, bit-depth-luma=(uint)8, bit-depth-chroma=(uint)8, colorimetry=bt709, chroma-format=4:2:0", null },
        .{ "video/x-vp9, profile=2, bit-depth-luma=(uint)10, bit-depth-chroma=(uint)10, colorimetry=bt2100-hlg, chroma-format=4:2:0, chroma-site=v-cosited", null },
        .{ "video/x-vp9, profile=1, bit-depth-luma=(uint)8, bit-depth-chroma=(uint)8, colorimetry=bt601, chroma-format=4:4:4", null },
        .{ "video/x-vp9, profile=3, bit-depth-luma=(uint)12, bit-depth-chroma=(uint)12, colorimetry=bt709, chroma-format=4:2:2", null },
        .{ "video/x-vp9, profile=0, bit-depth-luma=(uint)8, bit-depth-chroma=(uint)10, colorimetry=bt709, chroma-format=4:2:0", null },
        .{ "video/x-vp9, profile=0, bit-depth-luma=(uint)8, bit-depth-chroma=(uint)8, chroma-format=4:2:0", null },
        .{ "video/x-vp9, profile=0, bit-depth-luma=(uint)8, bit-depth-chroma=(uint)8, colorimetry=bt709, chroma-format=x", null },
        .{ "video/x-vp9, profile=0, bit-depth-luma=(uint)8, bit-depth-chroma=(uint)8, colorimetry=bt709, chroma-format=4:2:0, chroma-site=jpeg", null },
        .{ "video/x-vp9, profile=7", null },
        .{ "image/jpeg", null },
        .{ "audio/mpeg", null },
        .{ "audio/mpeg", cdaac },
        .{ "audio/mpeg", cdaac1 },
        .{ "audio/mpeg", cdaac31 },
        .{ "audio/x-ac3", null },
        .{ "audio/x-eac3", null },
        .{ "audio/x-ac4", null },
        .{ "audio/x-opus", null },
        .{ "audio/x-flac", null },
        .{ "audio/x-mulaw", null },
        .{ "audio/x-adpcm", null },
        .{ "audio/x-adpcm, layout=g726", null },
        .{ "application/ttml+xml", null },
        .{ "application/x-subtitle-vtt", null },
        .{ "audio/x-vorbis", null },
    };
    for (list) |e| {
        const caps = c.gst_caps_from_string(e[0]);
        if (e[1] != null) c.gst_caps_set_simple(caps, "codec_data", c.gst_buffer_get_type(), e[1], NONE);
        const m = c.gst_codec_utils_caps_get_mime_codec(caps);
        out("{s} {d} -> {s}", .{ z(e[0]), @intFromBool(e[1] != null), z(m) });
        c.g_free(m);
        c.gst_caps_unref(caps);
    }
    for ([_][*c]const u8{
        "avc1",                 "avc1.64001F",               "avc3.4D401E",       "avc1.42E01E,mp4a.40.2", "avc2.640028",     "avc4",
        "mp4a",                 "mp4a.40",                   "mp4a.40.2",         "mp4a.40.5",             "mp4a.40.1",       "mp4a.69",
        "mp4a.6B",              "hev1.1.6.L93.B0",           "hvc1",              "vvc1.1",                "vvi1",            "ac-3",
        "ec-3",                 "ec+3",                      "ac-4.02.01.01",     "stpp",                  "wvtt",            "vp08.00.10.08",
        "vp09.00.10.08",        "av01",                      "av01.0.04M.08",     "av01.1.13H.10",         "av01.2.08M.12.1.110.01.01.01.0", "av01.0.05M.08.0.111.09.16.09.1",
        "av01.0.05M.08.0.112.09.16.09.1", "av01.0.05M.08.0.000.01.13.12.0", "av01.0.05M.08.0.010.01.01.01.0", "av01.0.24M.08", "av01.0.04X.08", "av01.3.04M.08",
        "av01.0.4M.08",         "av01.0.H.08",               "av01.0.04",         "av01.0.04M.08.0.110",   "opus",            "flac",
        "ulaw",                 "g726",                      "mjpg",              "abc",                   "  avc1",          " av",
        "xxxx",                 "",                          "avc1.64001F, mp4a.40.2", ",avc1,,opus,",   "mp4a.40.2,avc1", "vp09,av01.0.04M.10,bogus",
    }) |s| {
        const caps = c.gst_codec_utils_caps_from_mime_codec(s);
        out("from '{s}'", .{z(s)});
        capsStr(caps);
        if (caps != null) c.gst_caps_unref(caps);
    }
}

fn checks() void {
    out("== checks", .{});
    flush();
    _ = c.gst_codec_utils_aac_get_level(null, 2);
    _ = c.gst_codec_utils_h264_get_profile(null, 2);
    _ = c.gst_codec_utils_h264_get_level(null, 3);
    _ = c.gst_codec_utils_h264_get_level_idc(null);
    _ = c.gst_codec_utils_h264_get_profile_flags_level(null, 7, null, null, null);
    _ = c.gst_codec_utils_h265_get_profile(null, 2);
    _ = c.gst_codec_utils_h265_get_tier(null, 2);
    _ = c.gst_codec_utils_h265_get_level(null, 12);
    _ = c.gst_codec_utils_h265_get_level_idc(null);
    _ = c.gst_codec_utils_h266_get_profile(null, 2);
    _ = c.gst_codec_utils_h266_get_tier(null, 2);
    _ = c.gst_codec_utils_h266_get_level(null, 3);
    _ = c.gst_codec_utils_h266_get_level_idc(null);
    _ = c.gst_codec_utils_av1_get_seq_level_idx(null);
    _ = c.gst_codec_utils_mpeg4video_get_profile(null, 1);
    _ = c.gst_codec_utils_mpeg4video_get_level(null, 1);
    _ = c.gst_codec_utils_caps_get_mime_codec(null);
    _ = c.gst_codec_utils_caps_from_mime_codec(null);
    _ = c.gst_codec_utils_av1_create_caps_from_av1c(null);
    _ = c.gst_codec_utils_av1_create_av1c_from_caps(null);
    const b = [_]u8{ 0, 0, 0 };
    const two = c.gst_caps_from_string("audio/mpeg, mpegversion=4; audio/mpeg, mpegversion=2");
    const wrong = c.gst_caps_from_string("video/x-foo, mpegversion=4");
    const nover = c.gst_caps_from_string("audio/mpeg");
    const v1 = c.gst_caps_from_string("audio/mpeg, mpegversion=1");
    const buf = c.gst_buffer_new();
    out("{d}", .{c.gst_codec_utils_aac_caps_set_level_and_profile(@ptrCast(buf), &b, 2)});
    out("{d}", .{c.gst_codec_utils_aac_caps_set_level_and_profile(two, &b, 2)});
    out("{d}", .{c.gst_codec_utils_aac_caps_set_level_and_profile(wrong, &b, 2)});
    out("{d}", .{c.gst_codec_utils_aac_caps_set_level_and_profile(nover, &b, 2)});
    out("{d}", .{c.gst_codec_utils_aac_caps_set_level_and_profile(v1, null, 2)});
    out("{d}", .{c.gst_codec_utils_aac_caps_set_level_and_profile(v1, &b, 2)});
    out("{d}", .{c.gst_codec_utils_h264_caps_set_level_and_profile(wrong, &b, 3)});
    out("{d}", .{c.gst_codec_utils_h264_caps_set_level_and_profile(two, &b, 3)});
    const x264 = c.gst_caps_from_string("video/x-h264");
    out("{d}", .{c.gst_codec_utils_h264_caps_set_level_and_profile(x264, null, 3)});
    out("{d}", .{c.gst_codec_utils_h265_caps_set_level_tier_and_profile(x264, &b, 3)});
    out("{d}", .{c.gst_codec_utils_h266_caps_set_level_tier_and_profile(x264, &b, 3)});
    out("{d}", .{c.gst_codec_utils_mpeg4video_caps_set_level_and_profile(two, &b, 1)});
    out("{d}", .{c.gst_codec_utils_mpeg4video_caps_set_level_and_profile(x264, null, 1)});
    out("{d}", .{c.gst_codec_utils_mpeg4video_caps_set_level_and_profile(null, &b, 1)});
    const x265 = c.gst_caps_from_string("video/x-h265");
    out("{d}", .{c.gst_codec_utils_h265_caps_set_level_tier_and_profile(x265, null, 3)});
    const x266 = c.gst_caps_from_string("video/x-h266");
    out("{d}", .{c.gst_codec_utils_h266_caps_set_level_tier_and_profile(x266, null, 3)});
    const nf = c.gst_caps_from_string("audio/x-opus, channel-mapping-family={0,1}");
    out("{d}", .{c.gst_codec_utils_opus_parse_caps(null, null, null, null, null, null, null)});
    out("{d}", .{c.gst_codec_utils_opus_parse_caps(nf, null, null, null, null, null, null)});
    out("{d}", .{c.gst_codec_utils_opus_parse_caps(c.gst_caps_new_empty(), null, null, null, null, null, null)});
    out("{d}", .{c.gst_codec_utils_opus_parse_caps(x264, null, null, null, null, null, null)});
    out("{d}", .{c.gst_codec_utils_opus_parse_caps(c.gst_caps_from_string("audio/x-opus, channel-mapping-family=(string)x"), null, null, null, null, null, null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_caps_from_header(null, null) != null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_caps_from_header(buf, @ptrCast(x264)) != null)});
    out("{d}", .{c.gst_codec_utils_opus_parse_header(null, null, null, null, null, null, null, null, null)});
    out("{d}", .{c.gst_codec_utils_opus_parse_header(buf, null, null, null, null, null, null, null, null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_header(0, 3, 0, 0, 0, null, 0, 0) != null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_header(0, 2, 0, 2, 0, null, 0, 0) != null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_header(0, 2, 0, 1, 2, null, 0, 0) != null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_header(0, 0, 1, 1, 0, &b, 0, 0) != null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_header(0, 1, 1, 0, 0, &b, 0, 0) != null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_header(0, 1, 1, 1, 2, &b, 0, 0) != null)});
    out("{d}", .{@intFromBool(c.gst_codec_utils_opus_create_header(0, 1, 1, 1, 0, null, 0, 0) != null)});
    flush();
}

pub fn main() void {
    c.gst_init(null, null);
    aac();
    h264();
    h265();
    h266();
    mpeg4();
    av1();
    opus();
    mime();
    flush();
    checks();
}
