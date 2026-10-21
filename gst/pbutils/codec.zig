const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Caps = c.GstCaps;
const Buffer = c.GstBuffer;
const BitReader = c.GstBitReader;
const VNONE = @as(?*anyopaque, null);

const AAC_RATES = [_]c.guint{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };
const DIGITS = [_][*:0]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

fn digit(d: anytype) ?[*:0]const u8 {
    return if (d >= 0 and d < 10) DIGITS[@intCast(d)] else null;
}

fn reader(data: [*c]const u8, len: c.guint) BitReader {
    return .{ .data = data, .size = len, .byte = 0, .bit = 0, ._gst_reserved = .{ null, null, null, null } };
}

fn bits8(br: *BitReader, n: c.guint) ?u8 {
    var v: u8 = 0;
    return if (c.gst_bit_reader_get_bits_uint8(br, &v, n) != 0) v else null;
}

fn isBuffer(p: anytype) bool {
    const m: [*c]const c.GstMiniObject = @ptrCast(@alignCast(p));
    return m != null and m[0].type == c.gst_buffer_get_type();
}

fn simpleCaps(caps: [*c]Caps, comptime fname: []const u8) bool {
    if (!check.that(check.isCaps(caps), fname, "GST_IS_CAPS (caps)")) return false;
    return check.that(c.gst_caps_get_size(caps) == 1, fname, "GST_CAPS_IS_SIMPLE (caps)");
}

fn hasName(caps: [*c]Caps, name: [*:0]const u8) bool {
    return c.gst_structure_has_name(c.gst_caps_get_structure(caps, 0), name) != 0;
}

fn setString(caps: [*c]Caps, field: [*:0]const u8, v: [*c]const u8) void {
    c.gst_caps_set_simple(caps, field, c.G_TYPE_STRING, v, VNONE);
}

fn eql(a: [*c]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(a))), b);
}

pub export fn gst_codec_utils_aac_get_sample_rate_from_index(sr_idx: c.guint) c.guint {
    return if (sr_idx < AAC_RATES.len) AAC_RATES[sr_idx] else 0;
}

pub export fn gst_codec_utils_aac_get_index_from_sample_rate(rate: c.guint) c.gint {
    for (AAC_RATES, 0..) |r, i| if (r == rate) return @intCast(i);
    return -1;
}

fn objectType(br: *BitReader) ?u8 {
    var aot = bits8(br, 5) orelse return null;
    if (aot == 31) aot = (bits8(br, 6) orelse return null) + 32;
    return aot;
}

fn sampleRate(br: *BitReader) ?c.guint {
    const idx = bits8(br, 4) orelse return null;
    if (idx == 0xf) {
        var r: u32 = 0;
        if (c.gst_bit_reader_get_bits_uint32(br, &r, 24) == 0) return null;
        return r;
    }
    const r = gst_codec_utils_aac_get_sample_rate_from_index(idx);
    return if (r == 0) null else r;
}

const AudioConfig = struct { aot: u8, channels: u8, rate: c.guint };

fn audioConfig(br: *BitReader) ?AudioConfig {
    var aot = objectType(br) orelse return null;
    var rate = sampleRate(br) orelse return null;
    const ch = bits8(br, 4) orelse return null;
    if (aot == 5 or aot == 29) {
        rate = sampleRate(br) orelse return null;
        aot = objectType(br) orelse return null;
    }
    return .{ .aot = aot, .channels = ch, .rate = rate };
}

pub export fn gst_codec_utils_aac_get_sample_rate(audio_config: [*c]const c.guint8, len: c.guint) c.guint {
    if (len < 2) return 0;
    var br = reader(audio_config, len);
    return if (audioConfig(&br)) |a| a.rate else 0;
}

pub export fn gst_codec_utils_aac_get_channels(audio_config: [*c]const c.guint8, len: c.guint) c.guint {
    if (len < 2) return 0;
    const ch: c.guint = (audio_config[1] & 0x7f) >> 3;
    if (ch > 0 and ch < 7) return ch;
    return if (ch == 7) 8 else 0;
}

pub export fn gst_codec_utils_aac_get_profile(audio_config: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (len < 1) return null;
    var br = reader(audio_config, len);
    const a = audioConfig(&br) orelse return null;
    return switch (a.aot) {
        1 => "main",
        2 => "lc",
        3 => "ssr",
        4 => "ltp",
        else => null,
    };
}

pub export fn gst_codec_utils_aac_get_level(audio_config: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(audio_config != null, "gst_codec_utils_aac_get_level", "audio_config != NULL")) return null;
    if (len < 2) return null;
    var br = reader(audio_config, len);
    const a = audioConfig(&br) orelse return null;
    var sce: c_int = 0;
    var cpe: c_int = 0;
    var lfe: c_int = 0;
    switch (a.channels) {
        1 => sce = 1,
        2 => cpe = 1,
        3 => {
            sce = 1;
            cpe = 1;
        },
        4 => {
            sce = 2;
            cpe = 1;
        },
        5, 6 => {
            sce = 1;
            cpe = 2;
        },
        7, 12, 14 => {
            sce = 1;
            cpe = 3;
            lfe = 1;
        },
        11 => {
            sce = 2;
            cpe = 2;
            lfe = 1;
        },
        else => return null,
    }
    var pref: c_int = 5;
    var rref: c_int = 5;
    switch (a.aot) {
        0 => return null,
        2 => {
            pref = 3;
            rref = 3;
        },
        3 => {
            pref = 4;
            rref = 3;
        },
        4 => {
            pref = 4;
            rref = 4;
        },
        else => {},
    }
    const ratio: f32 = @as(f32, @floatFromInt(a.rate)) / 48000.0;
    const pf: f32 = ratio * @as(f32, @floatFromInt(pref));
    const pcu: c_int = @intFromFloat(@as(f64, pf) * @as(f64, @floatFromInt(2 * cpe + sce + lfe)));
    const rsum: f64 = @as(f64, @floatFromInt(sce)) + 0.5 * @as(f64, @floatFromInt(lfe));
    var rcu: c_int = @intFromFloat(@as(f64, @as(f32, @floatFromInt(rref))) * rsum);
    if (cpe < 2) rcu += (rref + (rref - 1)) * cpe else rcu += rref + (rref - 1) * (2 * cpe - 1);
    const n = sce + 2 * cpe;
    const r = a.rate;
    var ret: c_int = -1;
    if (a.aot == 2) {
        if (n <= 2 and r <= 24000 and pcu <= 3 and rcu <= 5) {
            ret = 1;
        } else if (n <= 2 and r <= 48000 and pcu <= 6 and rcu <= 5) {
            ret = 2;
        } else if (n <= 5 and r <= 48000 and pcu <= 19 and rcu <= 15) {
            ret = 4;
        } else if (n <= 5 and r <= 96000 and pcu <= 38 and rcu <= 15) {
            ret = 5;
        } else if (n <= 7 and r <= 48000 and pcu <= 25 and rcu <= 19) {
            ret = 6;
        } else if (n <= 7 and r <= 96000 and pcu <= 50 and rcu <= 19) ret = 7;
    } else {
        if (pcu < 40 and rcu < 20) {
            ret = 1;
        } else if (pcu < 80 and rcu < 64) {
            ret = 2;
        } else if (pcu < 160 and rcu < 128) {
            ret = 3;
        } else if (pcu < 320 and rcu < 256) ret = 4;
    }
    if (ret == -1) return null;
    return digit(ret);
}

pub export fn gst_codec_utils_aac_caps_set_level_and_profile(caps: [*c]Caps, audio_config: [*c]const c.guint8, len: c.guint) c.gboolean {
    const fname = "gst_codec_utils_aac_caps_set_level_and_profile";
    if (!simpleCaps(caps, fname)) return 0;
    if (!check.that(hasName(caps, "audio/mpeg"), fname, "GST_SIMPLE_CAPS_HAS_NAME (caps, \"audio/mpeg\")")) return 0;
    if (!check.that(c.gst_structure_has_field(c.gst_caps_get_structure(caps, 0), "mpegversion") != 0, fname, "GST_SIMPLE_CAPS_HAS_FIELD (caps, \"mpegversion\")")) return 0;
    if (!check.that(audio_config != null, fname, "audio_config != NULL")) return 0;
    const s = c.gst_caps_get_structure(caps, 0);
    var v: c.gint = 0;
    _ = c.gst_structure_get_int(s, "mpegversion", &v);
    if (!check.that(v == 2 or v == 4, fname, "mpegversion == 2 || mpegversion == 4")) return 0;
    const level = gst_codec_utils_aac_get_level(audio_config, len);
    if (level != null) c.gst_structure_set(s, "level", c.G_TYPE_STRING, level, VNONE);
    const profile = gst_codec_utils_aac_get_profile(audio_config, len);
    if (profile != null) {
        if (v == 4) c.gst_structure_set(s, "base-profile", c.G_TYPE_STRING, profile, "profile", c.G_TYPE_STRING, profile, VNONE) else c.gst_structure_set(s, "profile", c.G_TYPE_STRING, profile, VNONE);
    }
    return @intFromBool(level != null and profile != null);
}

pub export fn gst_codec_utils_h264_get_profile(sps: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(sps != null, "gst_codec_utils_h264_get_profile", "sps != NULL")) return null;
    if (len < 2) return null;
    const f1 = sps[1] & 0x40 != 0;
    const f3 = sps[1] & 0x10 != 0;
    const f4 = sps[1] & 0x08 != 0;
    const f5 = sps[1] & 0x04 != 0;
    return switch (sps[0]) {
        66 => if (f1) "constrained-baseline" else "baseline",
        77 => "main",
        88 => "extended",
        100 => if (f4) (if (f5) "constrained-high" else "progressive-high") else "high",
        110 => if (f3) "high-10-intra" else if (f4) "progressive-high-10" else "high-10",
        122 => if (f3) "high-4:2:2-intra" else "high-4:2:2",
        244 => if (f3) "high-4:4:4-intra" else "high-4:4:4",
        44 => "cavlc-4:4:4-intra",
        118 => "multiview-high",
        128 => "stereo-high",
        83 => if (f5) "scalable-constrained-baseline" else "scalable-baseline",
        86 => if (f3) "scalable-high-intra" else if (f5) "scalable-constrained-high" else "scalable-high",
        else => null,
    };
}

const Level = struct { [:0]const u8, u8 };

const H264_LEVELS = [_]Level{ .{ "1", 10 }, .{ "1b", 9 }, .{ "1.1", 11 }, .{ "1.2", 12 }, .{ "1.3", 13 }, .{ "2", 20 }, .{ "2.1", 21 }, .{ "2.2", 22 }, .{ "3", 30 }, .{ "3.1", 31 }, .{ "3.2", 32 }, .{ "4", 40 }, .{ "4.1", 41 }, .{ "4.2", 42 }, .{ "5", 50 }, .{ "5.1", 51 }, .{ "5.2", 52 }, .{ "6", 60 }, .{ "6.1", 61 }, .{ "6.2", 62 } };
const H265_LEVELS = [_]Level{ .{ "1", 30 }, .{ "2", 60 }, .{ "2.1", 63 }, .{ "3", 90 }, .{ "3.1", 93 }, .{ "4", 120 }, .{ "4.1", 123 }, .{ "5", 150 }, .{ "5.1", 153 }, .{ "5.2", 156 }, .{ "6", 180 }, .{ "6.1", 183 }, .{ "6.2", 186 } };
const H266_LEVELS = [_]Level{ .{ "1", 16 }, .{ "2", 32 }, .{ "2.1", 35 }, .{ "3", 48 }, .{ "3.1", 51 }, .{ "4", 64 }, .{ "4.1", 67 }, .{ "5", 80 }, .{ "5.1", 83 }, .{ "5.2", 86 }, .{ "6", 96 }, .{ "6.1", 99 }, .{ "6.2", 102 }, .{ "6.3", 105 } };
const AV1_LEVELS = [_][:0]const u8{ "2.0", "2.1", "2.2", "2.3", "3.0", "3.1", "3.2", "3.3", "4.0", "4.1", "4.2", "4.3", "5.0", "5.1", "5.2", "5.3", "6.0", "6.1", "6.2", "6.3", "7.0", "7.1", "7.2", "7.3" };

fn levelIdc(table: []const Level, level: [*c]const c.gchar) u8 {
    for (table) |l| if (eql(level, l[0])) return l[1];
    return 0;
}

fn levelName(table: []const Level, idc: u8) [*c]const c.gchar {
    for (table) |l| if (l[1] == idc) return l[0].ptr;
    return null;
}

pub export fn gst_codec_utils_h264_get_level(sps: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(sps != null, "gst_codec_utils_h264_get_level", "sps != NULL")) return null;
    if (len < 3) return null;
    const f3 = sps[1] & 0x10 != 0;
    const l = sps[2];
    if (l == 0) return null;
    if ((l == 11 and f3) or l == 9) return "1b";
    if (l % 10 == 0) return digit(l / 10);
    return levelName(&H264_LEVELS, l);
}

pub export fn gst_codec_utils_h264_get_level_idc(level: [*c]const c.gchar) c.guint8 {
    if (!check.that(level != null, "gst_codec_utils_h264_get_level_idc", "level != NULL")) return 0;
    return levelIdc(&H264_LEVELS, level);
}

pub export fn gst_codec_utils_h264_caps_set_level_and_profile(caps: [*c]Caps, sps: [*c]const c.guint8, len: c.guint) c.gboolean {
    const fname = "gst_codec_utils_h264_caps_set_level_and_profile";
    if (!simpleCaps(caps, fname)) return 0;
    if (!check.that(hasName(caps, "video/x-h264"), fname, "GST_SIMPLE_CAPS_HAS_NAME (caps, \"video/x-h264\")")) return 0;
    if (!check.that(sps != null, fname, "sps != NULL")) return 0;
    const level = gst_codec_utils_h264_get_level(sps, len);
    if (level != null) setString(caps, "level", level);
    const profile = gst_codec_utils_h264_get_profile(sps, len);
    if (profile != null) setString(caps, "profile", profile);
    return @intFromBool(level != null and profile != null);
}

pub export fn gst_codec_utils_h264_get_profile_flags_level(codec_data: [*c]const c.guint8, len: c.guint, profile: [*c]c.guint8, flags: [*c]c.guint8, level: [*c]c.guint8) c.gboolean {
    if (!check.that(codec_data != null, "gst_codec_utils_h264_get_profile_flags_level", "codec_data != NULL")) return 0;
    if (len < 7 or codec_data[0] != 1) return 0;
    if (profile != null) profile[0] = codec_data[1];
    if (flags != null) flags[0] = codec_data[2];
    if (level != null) level[0] = codec_data[3];
    return 1;
}

const Ext = struct {
    name: [*:0]const u8 = "",
    b14: u8 = 0,
    b12: u8 = 0,
    b10: u8 = 0,
    b8: u8 = 0,
    c422: u8 = 0,
    c420: u8 = 0,
    mono: u8 = 0,
    intra: u8 = 0,
    one: u8 = 0,
    lower: u8 = 0,
    prio: u32 = 0,
};

fn ext(name: [*:0]const u8, f: [10]u8, prio: u32) Ext {
    return .{ .name = name, .b14 = f[0], .b12 = f[1], .b10 = f[2], .b8 = f[3], .c422 = f[4], .c420 = f[5], .mono = f[6], .intra = f[7], .one = f[8], .lower = f[9], .prio = prio };
}

const RANGE_EXT = [_]Ext{
    ext("monochrome", .{ 0, 1, 1, 1, 1, 1, 1, 0, 0, 1 }, 0),
    ext("monochrome-10", .{ 0, 1, 1, 0, 1, 1, 1, 0, 0, 1 }, 1),
    ext("monochrome-12", .{ 0, 1, 0, 0, 1, 1, 1, 0, 0, 1 }, 2),
    ext("monochrome-16", .{ 0, 0, 0, 0, 1, 1, 1, 0, 0, 1 }, 3),
    ext("main-12", .{ 0, 1, 0, 0, 1, 1, 0, 0, 0, 1 }, 4),
    ext("main-422-10", .{ 0, 1, 1, 0, 1, 0, 0, 0, 0, 1 }, 5),
    ext("main-422-12", .{ 0, 1, 0, 0, 1, 0, 0, 0, 0, 1 }, 6),
    ext("main-444", .{ 0, 1, 1, 1, 0, 0, 0, 0, 0, 1 }, 7),
    ext("main-444-10", .{ 0, 1, 1, 0, 0, 0, 0, 0, 0, 1 }, 8),
    ext("main-444-12", .{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 1 }, 9),
    ext("main-intra", .{ 0, 1, 1, 1, 1, 1, 0, 1, 0, 0 }, 10),
    ext("main-10-intra", .{ 0, 1, 1, 0, 1, 1, 0, 1, 0, 0 }, 11),
    ext("main-12-intra", .{ 0, 1, 0, 0, 1, 1, 0, 1, 0, 0 }, 12),
    ext("main-422-10-intra", .{ 0, 1, 1, 0, 1, 0, 0, 1, 0, 0 }, 13),
    ext("main-422-12-intra", .{ 0, 1, 0, 0, 1, 0, 0, 1, 0, 0 }, 14),
    ext("main-444-intra", .{ 0, 1, 1, 1, 0, 0, 0, 1, 0, 0 }, 15),
    ext("main-444-10-intra", .{ 0, 1, 1, 0, 0, 0, 0, 1, 0, 0 }, 16),
    ext("main-444-12-intra", .{ 0, 1, 0, 0, 0, 0, 0, 1, 0, 0 }, 17),
    ext("main-444-16-intra", .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 0 }, 18),
    ext("main-444-still-picture", .{ 0, 1, 1, 1, 0, 0, 0, 1, 1, 0 }, 19),
    ext("main-444-16-still-picture", .{ 0, 0, 0, 0, 0, 0, 0, 1, 1, 0 }, 20),
};

const THREE_D = [_]Ext{ext("3d-main", .{ 0, 1, 1, 1, 1, 1, 0, 0, 0, 1 }, 0)};
const MULTIVIEW = [_]Ext{ext("multiview-main", .{ 0, 1, 1, 1, 1, 1, 0, 0, 0, 1 }, 0)};
const SCALABLE = [_]Ext{
    ext("scalable-main", .{ 0, 1, 1, 1, 1, 1, 0, 0, 0, 1 }, 0),
    ext("scalable-main-10", .{ 0, 1, 1, 0, 1, 1, 0, 0, 0, 1 }, 1),
};
const HIGH_THROUGHPUT = [_]Ext{
    ext("high-throughput-444", .{ 1, 1, 1, 1, 0, 0, 0, 0, 0, 1 }, 0),
    ext("high-throughput-444-10", .{ 1, 1, 1, 0, 0, 0, 0, 0, 0, 1 }, 1),
    ext("high-throughput-444-14", .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 2),
    ext("high-throughput-444-16-intra", .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 0 }, 3),
};
const SCREEN = [_]Ext{
    ext("screen-extended-main", .{ 1, 1, 1, 1, 1, 1, 0, 0, 0, 1 }, 0),
    ext("screen-extended-main-10", .{ 1, 1, 1, 0, 1, 1, 0, 0, 0, 1 }, 1),
    ext("screen-extended-main-444", .{ 1, 1, 1, 1, 0, 0, 0, 0, 0, 1 }, 2),
    ext("screen-extended-main-444-10", .{ 1, 1, 1, 0, 0, 0, 0, 0, 0, 1 }, 3),
    ext("screen-extended-high-throughput-444", .{ 1, 1, 1, 1, 0, 0, 0, 0, 0, 1 }, 4),
    ext("screen-extended-high-throughput-444-10", .{ 1, 1, 1, 0, 0, 0, 0, 0, 0, 1 }, 5),
    ext("screen-extended-high-throughput-444-14", .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 6),
};
const SCALABLE_RANGE = [_]Ext{
    ext("scalable-monochrome", .{ 1, 1, 1, 1, 1, 1, 1, 0, 0, 1 }, 0),
    ext("scalable-monochrome-12", .{ 1, 1, 0, 0, 1, 1, 1, 0, 0, 1 }, 1),
    ext("scalable-monochrome-16", .{ 0, 0, 0, 0, 1, 1, 1, 0, 0, 1 }, 2),
    ext("scalable-main-444", .{ 1, 1, 1, 1, 0, 0, 0, 0, 0, 1 }, 3),
};

fn pickExt(table: []const Ext, want: *const Ext) [*c]const c.gchar {
    var best: ?*const Ext = null;
    var best_extra: u32 = 0;
    for (table) |*p| {
        var extra: u32 = 0;
        const pairs = [_][2]u8{ .{ p.b14, want.b14 }, .{ p.b12, want.b12 }, .{ p.b10, want.b10 }, .{ p.b8, want.b8 }, .{ p.c422, want.c422 }, .{ p.c420, want.c420 }, .{ p.mono, want.mono }, .{ p.intra, want.intra }, .{ p.one, want.one } };
        var ok = true;
        for (pairs) |pr| {
            if (pr[0] == pr[1]) continue;
            if (pr[0] != 0) {
                ok = false;
                break;
            }
            extra += 1;
        }
        if (!ok) continue;
        if (p.lower != 0 and want.lower == 0) continue;
        if (extra == 0) return p.name;
        if (best == null or extra < best_extra or (extra == best_extra and p.prio > best.?.prio)) {
            best = p;
            best_extra = extra;
        }
    }
    return if (best) |b| b.name else null;
}

pub export fn gst_codec_utils_h265_get_profile(ptl: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(ptl != null, "gst_codec_utils_h265_get_profile", "profile_tier_level != NULL")) return null;
    if (len < 2) return null;
    const idc = ptl[0] & 0x1f;
    var profile: [*c]const c.gchar = switch (idc) {
        1 => "main",
        2 => "main-10",
        3 => "main-still-picture",
        else => null,
    };
    var compat = [_]u8{0} ** 32;
    var br = reader(ptl, len);
    if (len > 4) {
        if (c.gst_bit_reader_skip(&br, 8) == 0) return null;
        for (&compat) |*f| f.* = bits8(&br, 1) orelse return null;
    }
    if (profile == null) {
        if (compat[1] != 0) {
            profile = "main";
        } else if (compat[2] != 0) {
            profile = "main-10";
        } else if (compat[3] != 0) profile = "main-still-picture";
    }
    if (profile != null) return profile;
    if (idc < 4 or idc > 11 or len < 11) return null;
    if (c.gst_bit_reader_skip(&br, 4) == 0) return null;
    var e = Ext{};
    inline for (.{ "b12", "b10", "b8", "c422", "c420", "mono", "intra", "one", "lower" }) |f| {
        @field(e, f) = bits8(&br, 1) orelse return null;
    }
    const is = struct {
        fn f(cp: []const u8, i: u8, ids: []const u8) bool {
            for (ids) |x| if (i == x or cp[x] != 0) return true;
            return false;
        }
    }.f;
    if (is(&compat, idc, &.{ 5, 9, 10, 11 })) e.b14 = bits8(&br, 1) orelse return null;
    if (is(&compat, idc, &.{4})) return pickExt(&RANGE_EXT, &e);
    if (is(&compat, idc, &.{5})) return pickExt(&HIGH_THROUGHPUT, &e);
    if (is(&compat, idc, &.{6})) return pickExt(&MULTIVIEW, &e);
    if (is(&compat, idc, &.{7})) return pickExt(&SCALABLE, &e);
    if (is(&compat, idc, &.{8})) return pickExt(&THREE_D, &e);
    if (is(&compat, idc, &.{ 9, 11 })) return pickExt(&SCREEN, &e);
    if (is(&compat, idc, &.{10})) return pickExt(&SCALABLE_RANGE, &e);
    return null;
}

pub export fn gst_codec_utils_h265_get_tier(ptl: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(ptl != null, "gst_codec_utils_h265_get_tier", "profile_tier_level != NULL")) return null;
    if (len < 1) return null;
    return if (ptl[0] & 0x20 != 0) "high" else "main";
}

pub export fn gst_codec_utils_h265_get_level(ptl: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(ptl != null, "gst_codec_utils_h265_get_level", "profile_tier_level != NULL")) return null;
    if (len < 12) return null;
    const l = ptl[11];
    if (l == 0) return null;
    if (l % 30 == 0) return digit(l / 30);
    return levelName(&H265_LEVELS, l);
}

pub export fn gst_codec_utils_h265_get_level_idc(level: [*c]const c.gchar) c.guint8 {
    if (!check.that(level != null, "gst_codec_utils_h265_get_level_idc", "level != NULL")) return 0;
    return levelIdc(&H265_LEVELS, level);
}

pub export fn gst_codec_utils_h265_caps_set_level_tier_and_profile(caps: [*c]Caps, ptl: [*c]const c.guint8, len: c.guint) c.gboolean {
    const fname = "gst_codec_utils_h265_caps_set_level_tier_and_profile";
    if (!simpleCaps(caps, fname)) return 0;
    if (!check.that(hasName(caps, "video/x-h265"), fname, "GST_SIMPLE_CAPS_HAS_NAME (caps, \"video/x-h265\")")) return 0;
    if (!check.that(ptl != null, fname, "profile_tier_level != NULL")) return 0;
    const level = gst_codec_utils_h265_get_level(ptl, len);
    if (level != null) setString(caps, "level", level);
    const tier = gst_codec_utils_h265_get_tier(ptl, len);
    if (tier != null) setString(caps, "tier", tier);
    const profile = gst_codec_utils_h265_get_profile(ptl, len);
    if (profile != null) setString(caps, "profile", profile);
    return @intFromBool(level != null and tier != null and profile != null);
}

pub export fn gst_codec_utils_h266_get_profile(ptl: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(ptl != null, "gst_codec_utils_h266_get_profile", "ptl_record != NULL")) return null;
    if (len < 2) return null;
    return switch ((ptl[1] & 0xfe) >> 1) {
        1 => "main-10",
        2 => "main-12",
        10 => "main-12-intra",
        17 => "multilayer-main-10",
        33 => "main-444-10",
        34 => "main-444-12",
        35 => "main-444-16",
        42 => "main-444-12-intra",
        43 => "main-444-16-intra",
        49 => "multilayer-main-444-10",
        65 => "main-10-still-picture",
        66 => "main-12-still-picture",
        97 => "main-444-10-still-picture",
        98 => "main-444-12-still-picture",
        99 => "main-444-16-still-picture",
        else => null,
    };
}

pub export fn gst_codec_utils_h266_get_tier(ptl: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(ptl != null, "gst_codec_utils_h266_get_tier", "ptl_record != NULL")) return null;
    if (len < 2) return null;
    return if (ptl[1] & 0x01 != 0) "high" else "main";
}

pub export fn gst_codec_utils_h266_get_level(ptl: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(ptl != null, "gst_codec_utils_h266_get_level", "ptl_record != NULL")) return null;
    if (len < 3 or ptl[2] == 0) return null;
    return levelName(&H266_LEVELS, ptl[2]);
}

pub export fn gst_codec_utils_h266_get_level_idc(level: [*c]const c.gchar) c.guint8 {
    if (!check.that(level != null, "gst_codec_utils_h266_get_level_idc", "level != NULL")) return 0;
    return levelIdc(&H266_LEVELS, level);
}

pub export fn gst_codec_utils_h266_caps_set_level_tier_and_profile(caps: [*c]Caps, config: [*c]const c.guint8, len_in: c.guint) c.gboolean {
    const fname = "gst_codec_utils_h266_caps_set_level_tier_and_profile";
    if (!simpleCaps(caps, fname)) return 0;
    if (!check.that(hasName(caps, "video/x-h266"), fname, "GST_SIMPLE_CAPS_HAS_NAME (caps, \"video/x-h266\")")) return 0;
    if (!check.that(config != null, fname, "decoder_configuration != NULL")) return 0;
    if (len_in < 5 or config[0] & 0x01 == 0) return 0;
    const ptl = config + 4;
    const len = len_in - 4;
    const level = gst_codec_utils_h266_get_level(ptl, len);
    if (level != null) setString(caps, "level", level);
    const tier = gst_codec_utils_h266_get_tier(ptl, len);
    if (tier != null) setString(caps, "tier", tier);
    const profile = gst_codec_utils_h266_get_profile(ptl, len);
    if (profile != null) setString(caps, "profile", profile);
    return @intFromBool(level != null and tier != null and profile != null);
}

pub export fn gst_codec_utils_av1_get_seq_level_idx(level: [*c]const c.gchar) c.guint8 {
    if (!check.that(level != null, "gst_codec_utils_av1_get_seq_level_idx", "level != NULL")) return 0;
    for (AV1_LEVELS, 0..) |l, i| if (eql(level, l)) return @intCast(i);
    return 31;
}

pub export fn gst_codec_utils_av1_get_level(seq_level_idx: c.guint8) [*c]const c.gchar {
    return if (seq_level_idx < AV1_LEVELS.len) AV1_LEVELS[seq_level_idx].ptr else null;
}

const MPEG4_PROFILES = [_]?[*:0]const u8{ "simple", "simple-scalable", "core", "main", "n-bit", "scalable", null, "basic-animated-texture", "hybrid", "advanced-real-time-simple", "core-scalable", "advanced-coding-efficiency", "advanced-core", "advanced-scalable-texture" };
const MPEG4_LEVEL_MAX = [_]u8{ 6, 2, 2, 4, 2, 1, 2, 2, 2, 4, 3, 4, 2, 3, 4, 5 };

pub export fn gst_codec_utils_mpeg4video_get_profile(vos: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(vos != null, "gst_codec_utils_mpeg4video_get_profile", "vis_obj_seq != NULL")) return null;
    if (len < 1) return null;
    const p = vos[0] >> 4;
    const l = vos[0] & 0xf;
    if (p != 6 and p < 0xe) return MPEG4_PROFILES[p];
    if (p != 0xf and l == 0) return null;
    switch (p) {
        0x6 => if (l < 3) return "simple-face" else if (l < 5) return "simple-fba",
        0xe => if (l < 5) return "simple-studio" else if (l < 9) return "core-studio",
        0xf => if (l < 6) return "advanced-simple" else if (l > 7 and l < 0xe) return "fine-granularity-scalable",
        else => {},
    }
    return null;
}

pub export fn gst_codec_utils_mpeg4video_get_level(vos: [*c]const c.guint8, len: c.guint) [*c]const c.gchar {
    if (!check.that(vos != null, "gst_codec_utils_mpeg4video_get_level", "vis_obj_seq != NULL")) return null;
    if (len < 1) return null;
    const p = vos[0] >> 4;
    const l = vos[0] & 0xf;
    if (p != 0xf and l == 0) return null;
    switch (p) {
        0x3 => if (l == 1) return null,
        0x4 => if (l != 2) return null,
        0x6 => if (l > 5) return null,
        0xe => if (l > 9) return null,
        0xf => if (l == 6 or l == 7 or l > 0xd) return null,
        else => {},
    }
    if (p == 0 and l == 8) return "0";
    if (p == 0 and l == 9) return "0b";
    if (p == 0 and l == 4) return "4a";
    if (p == 0xf and l > 7) return digit(l - 8);
    if (l <= MPEG4_LEVEL_MAX[p]) return digit(l);
    return null;
}

pub export fn gst_codec_utils_mpeg4video_caps_set_level_and_profile(caps: [*c]Caps, vos: [*c]const c.guint8, len: c.guint) c.gboolean {
    const fname = "gst_codec_utils_mpeg4video_caps_set_level_and_profile";
    if (!simpleCaps(caps, fname)) return 0;
    if (!check.that(vos != null, fname, "vis_obj_seq != NULL")) return 0;
    const profile = gst_codec_utils_mpeg4video_get_profile(vos, len);
    if (profile != null) setString(caps, "profile", profile);
    const level = gst_codec_utils_mpeg4video_get_level(vos, len);
    if (level != null) setString(caps, "level", level);
    return @intFromBool(profile != null and level != null);
}

pub export fn gst_codec_utils_opus_parse_caps(caps: [*c]Caps, rate: [*c]c.guint32, channels: [*c]u8, family: [*c]u8, stream_count: [*c]u8, coupled_count: [*c]u8, mapping: [*c]u8) c.gboolean {
    const fname = "gst_codec_utils_opus_parse_caps";
    if (!check.that(caps != null, fname, "caps != NULL")) return 0;
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, fname, "gst_caps_is_fixed (caps)")) return 0;
    if (!check.that(c.gst_caps_is_empty(caps) == 0, fname, "!gst_caps_is_empty (caps)")) return 0;
    const s = c.gst_caps_get_structure(caps, 0);
    if (!check.that(c.gst_structure_has_name(s, "audio/x-opus") != 0, fname, "gst_structure_has_name (s, \"audio/x-opus\")")) return 0;
    if (!check.that(c.gst_structure_has_field_typed(s, "channel-mapping-family", c.G_TYPE_INT) != 0, fname, "gst_structure_has_field_typed (s, \"channel-mapping-family\", G_TYPE_INT)")) return 0;
    if (rate != null) {
        var r: c.gint = 0;
        rate[0] = if (c.gst_structure_get_int(s, "rate", &r) != 0) @bitCast(r) else 48000;
    }
    var f: c.gint = 0;
    _ = c.gst_structure_get_int(s, "channel-mapping-family", &f);
    if (family != null) family[0] = @truncate(@as(c.guint, @bitCast(f)));
    var ch: c.gint = 0;
    if (c.gst_structure_get_int(s, "channels", &ch) == 0 or ch == 0) {
        if (f != 0) return 0;
        ch = 2;
    }
    if (channels != null) channels[0] = @truncate(@as(c.guint, @bitCast(ch)));
    if (f == 0) {
        if (ch > 2) return 0;
        if (stream_count != null) stream_count[0] = 1;
        if (coupled_count != null) coupled_count[0] = if (ch == 2) 1 else 0;
        if (mapping != null) {
            mapping[0] = 0;
            mapping[1] = 1;
        }
        return 1;
    }
    var sc: c.gint = 0;
    if (c.gst_structure_get_int(s, "stream-count", &sc) == 0) return 0;
    if (stream_count != null) stream_count[0] = @truncate(@as(c.guint, @bitCast(sc)));
    var cc: c.gint = 0;
    if (c.gst_structure_get_int(s, "coupled-count", &cc) == 0) return 0;
    if (coupled_count != null) coupled_count[0] = @truncate(@as(c.guint, @bitCast(cc)));
    const va = c.gst_structure_get_value(s, "channel-mapping");
    if (va == null or c.g_type_check_value_holds(va, c.gst_value_array_get_type()) == 0) return 0;
    if (c.gst_value_array_get_size(va) != @as(c.guint, @bitCast(ch))) return 0;
    if (mapping != null) {
        var i: c.guint = 0;
        while (i < @as(c.guint, @bitCast(ch))) : (i += 1) {
            const v = c.gst_value_array_get_value(va, i);
            if (c.g_type_check_value_holds(v, c.G_TYPE_INT) == 0) return 0;
            const cm = c.g_value_get_int(v);
            if (cm < 0 or cm > 255) return 0;
            mapping[i] = @intCast(cm);
        }
    }
    return 1;
}

pub export fn gst_codec_utils_opus_create_caps(rate_in: c.guint32, channels_in: u8, family: u8, stream_count_in: u8, coupled_count_in: u8, mapping: [*c]const u8) [*c]Caps {
    const rate: u32 = if (rate_in == 0) 48000 else rate_in;
    var channels = channels_in;
    var sc = stream_count_in;
    var cc = coupled_count_in;
    if (family == 0) {
        if (channels > 2 or sc > 1 or cc > 1) return null;
        if (channels == 0) channels = 2;
        if (sc == 0) sc = 1;
        if (cc == 0) cc = if (channels == 2) 1 else 0;
        return c.gst_caps_new_simple("audio/x-opus", "rate", c.G_TYPE_INT, rate, "channels", c.G_TYPE_INT, @as(c.gint, channels), "channel-mapping-family", c.G_TYPE_INT, @as(c.gint, family), "stream-count", c.G_TYPE_INT, @as(c.gint, sc), "coupled-count", c.G_TYPE_INT, @as(c.gint, cc), VNONE);
    }
    if (channels == 0 or sc == 0 or cc > sc or mapping == null) return null;
    const caps = c.gst_caps_new_simple("audio/x-opus", "rate", c.G_TYPE_INT, rate, "channels", c.G_TYPE_INT, @as(c.gint, channels), "channel-mapping-family", c.G_TYPE_INT, @as(c.gint, family), "stream-count", c.G_TYPE_INT, @as(c.gint, sc), "coupled-count", c.G_TYPE_INT, @as(c.gint, cc), VNONE);
    var va = std.mem.zeroes(c.GValue);
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&va, c.gst_value_array_get_type());
    _ = c.g_value_init(&v, c.G_TYPE_INT);
    for (0..channels) |i| {
        c.g_value_set_int(&v, mapping[i]);
        c.gst_value_array_append_value(&va, &v);
    }
    c.gst_structure_set_value(c.gst_caps_get_structure(caps, 0), "channel-mapping", &va);
    c.g_value_unset(&va);
    c.g_value_unset(&v);
    return caps;
}

fn headerArray(caps: [*c]Caps, field: [*:0]const u8, bufs: []const [*c]Buffer) [*c]Caps {
    const w: [*c]Caps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps)));
    const s = c.gst_caps_get_structure(w, 0);
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    for (bufs) |b| {
        if (c.gst_mini_object_is_writable(@ptrCast(b)) == 0) c.g_assertion_message_expr(check.DOMAIN, "../gst-libs/gst/pbutils/codec-utils.c", 2449, "_gst_caps_set_buffer_array", "gst_buffer_is_writable (buf)");
        b[0].mini_object.flags |= c.GST_BUFFER_FLAG_HEADER;
        var val = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&val, c.gst_buffer_get_type());
        const cp = c.gst_buffer_copy(b);
        cp[0].mini_object.flags |= c.GST_BUFFER_FLAG_HEADER;
        c.g_value_set_boxed(&val, cp);
        c.gst_mini_object_unref(@ptrCast(cp));
        c.gst_value_array_append_value(&arr, &val);
        c.g_value_unset(&val);
    }
    c.gst_structure_set_value(s, field, &arr);
    c.g_value_unset(&arr);
    return w;
}

pub export fn gst_codec_utils_opus_create_caps_from_header(header: [*c]Buffer, comments: [*c]Buffer) [*c]Caps {
    const fname = "gst_codec_utils_opus_create_caps_from_header";
    if (!check.that(isBuffer(header), fname, "GST_IS_BUFFER (header)")) return null;
    if (!check.that(comments == null or isBuffer(comments), fname, "comments == NULL || GST_IS_BUFFER (comments)")) return null;
    var rate: u32 = 0;
    var ch: u8 = 0;
    var fam: u8 = 0;
    var sc: u8 = 0;
    var cc: u8 = 0;
    var map: [256]u8 = undefined;
    if (gst_codec_utils_opus_parse_header(header, &rate, &ch, &fam, &sc, &cc, &map, null, null) == 0) return null;
    var caps = gst_codec_utils_opus_create_caps(rate, ch, fam, sc, cc, &map);
    if (caps == null) return null;
    var dummy: [*c]Buffer = null;
    if (comments == null) {
        const tags = c.gst_tag_list_new_empty();
        dummy = c.gst_tag_list_to_vorbiscomment_buffer(tags, "OpusTags", 8, null);
        c.gst_tag_list_unref(tags);
    }
    caps = headerArray(caps, "streamheader", &.{ header, if (comments != null) comments else dummy });
    if (dummy != null) c.gst_mini_object_unref(@ptrCast(dummy));
    return caps;
}

pub export fn gst_codec_utils_opus_create_header(rate_in: c.guint32, channels_in: u8, family: u8, stream_count_in: u8, coupled_count_in: u8, mapping_in: [*c]const u8, pre_skip: c.guint16, output_gain: c.gint16) [*c]Buffer {
    const fname = "gst_codec_utils_opus_create_header";
    const rate: u32 = if (rate_in == 0) 48000 else rate_in;
    var ch = channels_in;
    var sc = stream_count_in;
    var cc = coupled_count_in;
    var mapping = mapping_in;
    if (family == 0) {
        if (!check.that(ch <= 2, fname, "channels <= 2")) return null;
        if (ch == 0) ch = 2;
        if (!check.that(sc == 0 or sc == 1, fname, "stream_count == 0 || stream_count == 1")) return null;
        if (sc == 0) sc = 1;
        if (!check.that(cc == 0 or cc == 1, fname, "coupled_count == 0 || coupled_count == 1")) return null;
        if (cc == 0) cc = if (ch == 2) 1 else 0;
        mapping = null;
    } else {
        if (!check.that(ch > 0, fname, "channels > 0")) return null;
        if (!check.that(sc > 0, fname, "stream_count > 0")) return null;
        if (!check.that(cc <= sc, fname, "coupled_count <= stream_count")) return null;
        if (!check.that(mapping != null, fname, "channel_mapping != NULL")) return null;
    }
    const size: usize = if (family > 0) 21 + @as(usize, ch) else 19;
    const d: [*]u8 = @ptrCast(c.g_malloc(size));
    @memcpy(d[0..8], "OpusHead");
    d[8] = 1;
    d[9] = ch;
    std.mem.writeInt(u16, d[10..12], pre_skip, .little);
    std.mem.writeInt(u32, d[12..16], rate, .little);
    std.mem.writeInt(u16, d[16..18], @bitCast(output_gain), .little);
    d[18] = family;
    if (family > 0) {
        d[19] = sc;
        d[20] = cc;
        @memcpy(d[21..size], mapping[0..ch]);
    }
    const b = c.gst_buffer_new();
    c.gst_buffer_append_memory(b, c.gst_memory_new_wrapped(0, d, size, 0, size, d, c.g_free));
    b[0].offset = 0;
    b[0].offset_end = 0;
    return b;
}

pub export fn gst_codec_utils_opus_parse_header(header: [*c]Buffer, rate: [*c]c.guint32, channels: [*c]u8, family: [*c]u8, stream_count: [*c]u8, coupled_count: [*c]u8, mapping: [*c]u8, pre_skip: [*c]c.guint16, output_gain: [*c]c.gint16) c.gboolean {
    const fname = "gst_codec_utils_opus_parse_header";
    if (!check.that(isBuffer(header), fname, "GST_IS_BUFFER (header)")) return 0;
    if (!check.that(c.gst_buffer_get_size(header) >= 19, fname, "gst_buffer_get_size (header) >= 19")) return 0;
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(header, &map, c.GST_MAP_READ) == 0) return 0;
    defer c.gst_buffer_unmap(header, &map);
    const d = map.data;
    if (!std.mem.eql(u8, d[0..8], "OpusHead")) return 0;
    if (d[8] != 0 and d[8] != 1) return 0;
    const ch = d[9];
    if (channels != null) channels[0] = ch;
    if (pre_skip != null) pre_skip[0] = std.mem.readInt(u16, d[10..12], .little);
    if (rate != null) rate[0] = std.mem.readInt(u32, d[12..16], .little);
    if (output_gain != null) output_gain[0] = @bitCast(std.mem.readInt(u16, d[16..18], .little));
    const f = d[18];
    if (family != null) family[0] = f;
    if (f == 0 and ch <= 2) {
        if (stream_count != null) stream_count[0] = 1;
        if (coupled_count != null) coupled_count[0] = if (ch == 2) 1 else 0;
        if (mapping != null) {
            mapping[0] = 0;
            mapping[1] = 1;
        }
        return 1;
    }
    if (map.size - 19 < 2 + @as(usize, ch)) return 0;
    if (stream_count != null) stream_count[0] = d[19];
    if (coupled_count != null) coupled_count[0] = d[20];
    if (mapping != null) @memcpy(mapping[0..ch], d[21 .. 21 + @as(usize, ch)]);
    return 1;
}

pub export fn gst_codec_utils_av1_create_caps_from_av1c(av1c: [*c]Buffer) [*c]Caps {
    if (!check.that(av1c != null, "gst_codec_utils_av1_create_caps_from_av1c", "av1c")) return null;
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(av1c, &map, c.GST_MAP_READ) == 0) return null;
    defer c.gst_buffer_unmap(av1c, &map);
    if (map.size < 4 or map.data[0] != 0x81) return null;
    const d = map.data;
    const profile: [*c]const u8 = switch (d[1] >> 5) {
        0 => "main",
        1 => "high",
        2 => "professional",
        else => return null,
    };
    const depth: c.guint = if (d[2] & 0x60 == 0x60) 12 else if (d[2] & 0x60 == 0x40) 10 else 8;
    const chroma: [*c]const u8 = switch (d[2] & 0x1c) {
        0x1c => "4:0:0",
        0x0c => "4:2:0",
        0x08 => "4:2:2",
        0x00 => "4:4:4",
        else => return null,
    };
    const ret = c.gst_caps_new_simple("video/x-av1", "profile", c.G_TYPE_STRING, profile, "bit-depth-luma", c.G_TYPE_UINT, depth, "chroma-format", c.G_TYPE_STRING, chroma, VNONE);
    if (d[3] & 0x10 != 0) c.gst_caps_set_simple(ret, "presentation-delay", c.G_TYPE_INT, @as(c.gint, d[3] & 0xf), VNONE);
    return ret;
}

pub export fn gst_codec_utils_av1_create_av1c_from_caps(caps: [*c]Caps) [*c]Buffer {
    if (!check.that(caps != null, "gst_codec_utils_av1_create_av1c_from_caps", "caps")) return null;
    const s = c.gst_caps_get_structure(caps, 0);
    if (s == null or c.gst_structure_has_name(s, "video/x-av1") == 0) return null;
    var delay: c.gint = -1;
    _ = c.gst_structure_get_int(s, "presentation-delay", &delay);
    const b = c.gst_buffer_new_allocate(null, 4, null);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
    const d = map.data;
    @memset(d[0..4], 0);
    d[0] = 0x81;
    const p = c.gst_structure_get_string(s, "profile");
    if (eql(p, "high")) d[1] |= 1 << 5;
    if (eql(p, "professional")) d[1] |= 2 << 5;
    d[1] |= 0x01;
    var depth: c.guint = 0;
    if (c.gst_structure_get_uint(s, "bit-depth-luma", &depth) != 0) {
        if (depth == 10) d[2] |= 0x40 else if (depth == 12) d[2] |= 0x60;
    }
    d[2] |= 0x0c;
    const cf = c.gst_structure_get_string(s, "chroma-format");
    if (eql(cf, "4:0:0")) d[2] |= 0x1c;
    if (eql(cf, "4:2:2")) d[2] |= 0x08;
    if (delay != -1) d[3] = 0x10 | @as(u8, @intCast(@max(0xf, delay) & 0xf));
    c.gst_buffer_unmap(b, &map);
    return b;
}

fn codecDataMap(s: ?*const c.GstStructure, map: *c.GstMapInfo) ?[*c]Buffer {
    const v = c.gst_structure_get_value(s, "codec_data");
    if (v == null) return null;
    const b: [*c]Buffer = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    if (c.gst_buffer_map(b, map, c.GST_MAP_READ) == 0) return null;
    return b;
}

fn hevcMime(s: ?*const c.GstStructure) ?[*c]u8 {
    const sf = c.gst_structure_get_string(s, "stream-format");
    if (c.gst_structure_get_value(s, "codec_data") == null or sf == null) return null;
    var map: c.GstMapInfo = undefined;
    const b = codecDataMap(s, &map) orelse return null;
    defer c.gst_buffer_unmap(b, &map);
    if (map.size < 23) return null;
    if (!eql(sf, "hev1") and !eql(sf, "hvc1")) return null;
    const d = map.data;
    const space = (d[1] >> 6) & 3;
    const tier = (d[1] >> 5) & 1;
    const idc: u16 = d[1] & 0x1f;
    const compat = @bitReverse(std.mem.readInt(u32, d[2..6], .big));
    const str = c.g_string_new(sf);
    _ = c.g_string_append_c(str, '.');
    if (space != 0) _ = c.g_string_append_c(str, @intCast('A' + space - 1));
    c.g_string_append_printf(str, "%u.%X.%c%d", @as(c.guint, idc), compat, @as(c_int, if (tier != 0) 'H' else 'L'), @as(c_int, d[12]));
    var last: usize = 6;
    while (last > 0 and d[6 + last - 1] == 0) last -= 1;
    for (0..last) |i| c.g_string_append_printf(str, ".%02X", @as(c.guint, d[6 + i]));
    return c.g_string_free(str, 0);
}

fn vp9Mime(s: ?*const c.GstStructure) [*c]u8 {
    const str = c.g_string_new("vp09");
    blk: {
        const ps = c.gst_structure_get_string(s, "profile");
        const profile: c.guint = if (eql(ps, "0")) 0 else if (eql(ps, "1")) 1 else if (eql(ps, "2")) 2 else if (eql(ps, "3")) 3 else break :blk;
        var luma: c.guint = 0;
        var chroma: c.guint = 0;
        _ = c.gst_structure_get(s, "bit-depth-luma", c.G_TYPE_UINT, &luma, "bit-depth-chroma", c.G_TYPE_UINT, &chroma, VNONE);
        if (luma == 0 or luma != chroma) break :blk;
        c.g_string_append_printf(str, ".%02u.%02u.%02u", profile, @as(c.guint, 10), luma);
        const cs = c.gst_structure_get_string(s, "colorimetry");
        if (cs == null) break :blk;
        var ci = std.mem.zeroes(c.GstVideoColorimetry);
        if (c.gst_video_colorimetry_from_string(&ci, cs) == 0) break :blk;
        const full: c.guint = @intFromBool(ci.range == c.GST_VIDEO_COLOR_RANGE_0_255);
        const cf = c.gst_structure_get_string(s, "chroma-format");
        var fmt: c.guint = 0;
        if (eql(cf, "4:2:0")) {
            const site_s = c.gst_structure_get_string(s, "chroma-site");
            const site = if (site_s != null) c.gst_video_chroma_site_from_string(site_s) else c.GST_VIDEO_CHROMA_SITE_UNKNOWN;
            fmt = if (site == c.GST_VIDEO_CHROMA_SITE_V_COSITED) 0 else 1;
        } else if (eql(cf, "4:2:2")) {
            fmt = 2;
        } else if (eql(cf, "4:4:4")) {
            fmt = 3;
        } else break :blk;
        const prim: c.guint = @as(u8, @truncate(c.gst_video_color_primaries_to_iso(ci.primaries)));
        const xfer: c.guint = @as(u8, @truncate(c.gst_video_transfer_function_to_iso(ci.transfer)));
        const mat: c.guint = @as(u8, @truncate(c.gst_video_color_matrix_to_iso(ci.matrix)));
        if (fmt != 1 or prim != 1 or xfer != 1 or mat != 1 or full != 0) c.g_string_append_printf(str, ".%02u.%02u.%02u.%02u.%02u", fmt, prim, xfer, mat, full);
    }
    return c.g_string_free(str, 0);
}

fn av1Mime(s: ?*const c.GstStructure) [*c]u8 {
    const str = c.g_string_new("av01");
    blk: {
        const tier: c_int = if (eql(c.gst_structure_get_string(s, "tier"), "high")) 'H' else 'M';
        const ls = c.gst_structure_get_string(s, "level");
        const level: c.guint = if (ls != null) gst_codec_utils_av1_get_seq_level_idx(ls) else 1;
        const ps = c.gst_structure_get_string(s, "profile");
        const profile: c_int = if (eql(ps, "main")) 0 else if (eql(ps, "high")) 1 else if (eql(ps, "professional")) 2 else break :blk;
        var depth: c.guint = 0;
        if (c.gst_structure_get_uint(s, "bit-depth-luma", &depth) == 0) break :blk;
        c.g_string_append_printf(str, ".%d.%02u%c.%02u", profile, level, tier, depth);
        const cf = c.gst_structure_get_string(s, "chroma-format");
        var mono: c.guint = 0;
        var sx: c.guint = 1;
        var sy: c.guint = 1;
        if (eql(cf, "4:0:0")) {
            mono = 1;
        } else if (eql(cf, "4:2:0")) {} else if (eql(cf, "4:2:2")) {
            sy = 0;
        } else if (eql(cf, "4:4:4")) {
            sx = 0;
            sy = 0;
        } else break :blk;
        const site = c.gst_structure_get_string(s, "chroma-site");
        const pos: c.guint = if (eql(site, "v-cosited")) 1 else if (eql(site, "v-cosited+h-cosited")) 2 else 0;
        const cs = c.gst_structure_get_string(s, "colorimetry");
        if (cs == null) break :blk;
        var ci = std.mem.zeroes(c.GstVideoColorimetry);
        if (c.gst_video_colorimetry_from_string(&ci, cs) == 0) break :blk;
        const full: c.guint = @intFromBool(ci.range == c.GST_VIDEO_COLOR_RANGE_0_255);
        const prim = c.gst_video_color_primaries_to_iso(ci.primaries);
        const xfer = c.gst_video_transfer_function_to_iso(ci.transfer);
        const mat = c.gst_video_color_matrix_to_iso(ci.matrix);
        if (sx != 1 or sy != 1 or pos != 0 or prim != 1 or xfer != 1 or mat != 1 or full != 0) c.g_string_append_printf(str, ".%u.%u%u%u.%02u.%02u.%02u.%u", mono, sx, sy, pos, prim, xfer, mat, full);
    }
    return c.g_string_free(str, 0);
}

pub export fn gst_codec_utils_caps_get_mime_codec(caps: [*c]Caps) [*c]c.gchar {
    const fname = "gst_codec_utils_caps_get_mime_codec";
    if (!check.that(caps != null, fname, "caps != NULL")) return null;
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, fname, "gst_caps_is_fixed (caps)")) return null;
    const s = c.gst_caps_get_structure(caps, 0);
    if (s == null) return null;
    const t = c.gst_structure_get_name(s);
    if (eql(t, "video/x-h264")) {
        var map: c.GstMapInfo = undefined;
        if (codecDataMap(s, &map)) |b| {
            var p: u8 = 0;
            var f: u8 = 0;
            var l: u8 = 0;
            const ok = gst_codec_utils_h264_get_profile_flags_level(map.data, @truncate(map.size), &p, &f, &l) != 0;
            c.gst_buffer_unmap(b, &map);
            if (ok) return c.g_strdup_printf("avc1.%02X%02X%02X", @as(c.guint, p), @as(c.guint, f), @as(c.guint, l));
        }
        return c.g_strdup("avc1");
    }
    if (eql(t, "video/x-h265")) return hevcMime(s) orelse c.g_strdup("hev1");
    if (eql(t, "video/x-h266")) return c.g_strdup("vvc1");
    if (eql(t, "video/x-av1")) return av1Mime(s);
    if (eql(t, "video/x-vp8")) return c.g_strdup("vp08");
    if (eql(t, "video/x-vp9")) return vp9Mime(s);
    if (eql(t, "image/jpeg")) return c.g_strdup("mjpg");
    if (eql(t, "audio/mpeg")) {
        var map: c.GstMapInfo = undefined;
        if (codecDataMap(s, &map)) |b| {
            var aot: ?u8 = null;
            if (map.size >= 2) {
                var br = reader(map.data, @truncate(map.size));
                aot = objectType(&br);
            }
            c.gst_buffer_unmap(b, &map);
            if (aot) |a| return c.g_strdup_printf("mp4a.40.%u", @as(c.guint, a));
        }
        return c.g_strdup("mp4a.40");
    }
    const simple = [_]struct { []const u8, [*:0]const u8 }{
        .{ "audio/x-ac3", "ac-3" },          .{ "audio/x-eac3", "ec-3" },
        .{ "audio/x-ac4", "ac-4" },          .{ "audio/x-opus", "opus" },
        .{ "audio/x-flac", "flac" },         .{ "audio/x-mulaw", "ulaw" },
        .{ "application/ttml+xml", "stpp" }, .{ "application/x-subtitle-vtt", "wvtt" },
    };
    for (simple) |e| if (eql(t, e[0])) return c.g_strdup(e[1]);
    if (eql(t, "audio/x-adpcm") and eql(c.gst_structure_get_string(s, "layout"), "g726")) return c.g_strdup("g726");
    return null;
}

fn scanLevelTier(str: [*c]const u8, level: *c.guint, tier: *u8) bool {
    var i: usize = 0;
    while (str[i] == ' ' or (str[i] >= '\t' and str[i] <= '\r')) i += 1;
    var width: usize = 0;
    var neg = false;
    if (str[i] == '+' or str[i] == '-') {
        neg = str[i] == '-';
        i += 1;
        width += 1;
    }
    var v: c.guint = 0;
    var digits: usize = 0;
    while (width < 2 and str[i] >= '0' and str[i] <= '9') {
        v = v * 10 + (str[i] - '0');
        i += 1;
        width += 1;
        digits += 1;
    }
    if (digits == 0) return false;
    level.* = if (neg) 0 -% v else v;
    if (str[i] == 0) return false;
    tier.* = str[i];
    return true;
}

fn av1FromMime(sub: [*c][*c]u8) [*c]Caps {
    const caps = c.gst_caps_new_empty_simple("video/x-av1");
    if (sub[1] == null) return caps;
    const prof = c.g_ascii_strtoull(sub[1], null, 10);
    const ps: [*c]const u8 = switch (prof) {
        0 => "main",
        1 => "high",
        2 => "professional",
        else => return caps,
    };
    setString(caps, "profile", ps);
    var level: c.guint = 1;
    var tier: u8 = 'M';
    if (sub[2] != null and !scanLevelTier(sub[2], &level, &tier)) return caps;
    const ts: [*c]const u8 = switch (tier) {
        'H' => "high",
        'M' => "main",
        else => return caps,
    };
    setString(caps, "tier", ts);
    const ls = gst_codec_utils_av1_get_level(@truncate(level));
    if (ls == null) return caps;
    setString(caps, "level", ls);
    if (sub[2] == null or sub[3] == null) return caps;
    const depth: c.guint = @truncate(c.g_ascii_strtoull(sub[3], null, 10));
    c.gst_caps_set_simple(caps, "bit-depth-luma", c.G_TYPE_UINT, depth, "bit-depth-chroma", c.G_TYPE_UINT, depth, VNONE);
    var cf: [*c]const u8 = "4:2:0";
    var pos: c.guint = 0;
    var prim: c.guint = 1;
    var xfer: c.guint = 1;
    var mat: c.guint = 1;
    var full: c.guint = 0;
    if (sub[4] != null and sub[5] != null and sub[6] != null and sub[7] != null and sub[8] != null and sub[9] != null) {
        const mono: c.guint = @truncate(c.g_ascii_strtoull(sub[4], null, 10));
        const samp: c.guint = @truncate(c.g_ascii_strtoull(sub[5], null, 10));
        const sx = samp / 100;
        const sy = (samp % 100) / 10;
        pos = samp % 10;
        if (mono != 0) {
            cf = "4:0:0";
        } else if (sx == 1 and sy == 1) {
            cf = "4:2:0";
        } else if (sx == 1 and sy == 0) {
            cf = "4:2:2";
        } else if (sx == 0 and sy == 0) {
            cf = "4:4:4";
        } else return caps;
        prim = @truncate(c.g_ascii_strtoull(sub[6], null, 10));
        xfer = @truncate(c.g_ascii_strtoull(sub[7], null, 10));
        mat = @truncate(c.g_ascii_strtoull(sub[8], null, 10));
        full = @truncate(c.g_ascii_strtoull(sub[9], null, 10));
    }
    setString(caps, "chroma-format", cf);
    if (pos == 1) setString(caps, "chroma-site", "v-cosited") else if (pos == 2) setString(caps, "chroma-site", "v-cosited+h-cosited");
    var ci = std.mem.zeroes(c.GstVideoColorimetry);
    ci.range = if (full != 0) c.GST_VIDEO_COLOR_RANGE_0_255 else c.GST_VIDEO_COLOR_RANGE_16_235;
    ci.primaries = c.gst_video_color_primaries_from_iso(prim);
    ci.transfer = c.gst_video_transfer_function_from_iso(xfer);
    ci.matrix = c.gst_video_color_matrix_from_iso(mat);
    const cs = c.gst_video_colorimetry_to_string(&ci);
    if (cs != null) setString(caps, "colorimetry", cs);
    c.g_free(cs);
    return caps;
}

fn fourcc(s: []const u8) u32 {
    return std.mem.readInt(u32, s[0..4], .little);
}

fn fromMimeSingle(codec: [*c]const u8) [*c]Caps {
    if (c.strlen(codec) < 4) return null;
    const sub = c.g_strsplit(codec, ".", 0);
    defer c.g_strfreev(sub);
    var s0 = sub[0];
    if (s0 == null) return null;
    while (s0[0] == ' ') s0 += 1;
    if (c.strlen(s0) < 4) return null;
    const cc = std.mem.readInt(u32, s0[0..4], .little);
    if (cc == fourcc("avc1") or cc == fourcc("avc2") or cc == fourcc("avc3") or cc == fourcc("avc4")) {
        const caps = c.gst_caps_new_empty_simple("video/x-h264");
        if (sub[1] != null) {
            const v = c.g_ascii_strtoull(sub[1], null, 16);
            const sps = [3]u8{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
            _ = gst_codec_utils_h264_caps_set_level_and_profile(caps, &sps, 3);
        }
        return caps;
    }
    if (cc == fourcc("mp4a")) {
        if (sub[1] == null) return null;
        if (c.g_ascii_strtoull(sub[1], null, 16) != 0x40) return null;
        const caps = c.gst_caps_new_simple("audio/mpeg", "mpegversion", c.G_TYPE_INT, @as(c.gint, 4), VNONE);
        if (sub[2] == null) return caps;
        const p: [*c]const u8 = switch (c.g_ascii_strtoull(sub[2], null, 16)) {
            1 => "main",
            2 => "lc",
            3 => "ssr",
            4 => "ltp",
            else => null,
        };
        if (p != null) setString(caps, "profile", p);
        return caps;
    }
    const names = [_]struct { []const u8, [*:0]const u8 }{
        .{ "hev1", "video/x-h265" },         .{ "hvc1", "video/x-h265" },
        .{ "vvc1", "video/x-h266" },         .{ "vvi1", "video/x-h266" },
        .{ "ac-3", "audio/x-ac3" },          .{ "ec+3", "audio/x-eac3" },
        .{ "ec-3", "audio/x-eac3" },         .{ "ac-4", "audio/x-ac4" },
        .{ "stpp", "application/ttml+xml" }, .{ "wvtt", "application/x-subtitle-vtt" },
        .{ "vp08", "video/x-vp8" },          .{ "vp09", "video/x-vp9" },
        .{ "opus", "audio/x-opus" },         .{ "flac", "audio/x-flac" },
        .{ "ulaw", "audio/x-mulaw" },        .{ "mjpg", "image/jpeg" },
    };
    for (names) |n| if (cc == fourcc(n[0])) return c.gst_caps_new_empty_simple(n[1]);
    if (cc == fourcc("av01")) return av1FromMime(sub);
    if (cc == fourcc("g726")) return c.gst_caps_new_simple("audio/x-adpcm", "layout", c.G_TYPE_STRING, @as([*c]const u8, "g726"), VNONE);
    return null;
}

pub export fn gst_codec_utils_caps_from_mime_codec(codecs_field: [*c]const c.gchar) [*c]Caps {
    if (!check.that(codecs_field != null, "gst_codec_utils_caps_from_mime_codec", "codecs_field != NULL")) return null;
    const codecs = c.g_strsplit(codecs_field, ",", 0);
    defer c.g_strfreev(codecs);
    var caps: [*c]Caps = null;
    var i: usize = 0;
    while (codecs[i] != null) : (i += 1) {
        const cc = fromMimeSingle(codecs[i]);
        if (caps == null) {
            caps = cc;
        } else if (cc != null) c.gst_caps_append(caps, cc);
    }
    return caps;
}
