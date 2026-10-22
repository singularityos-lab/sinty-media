const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

pub const NONE = cm.CLOCK_NONE;
const SECOND: u64 = 1_000_000_000;
const NOSHIFT: c.guint = std.math.maxInt(c.guint);

pub const Packet = c.ogg_packet;

pub const Index = extern struct {
    offset: u64,
    timestamp: u64,
};

pub const Stream = extern struct {
    stream: c.ogg_stream_state,
    serialno: u32,
    headers: [*c]c.GList,
    have_headers: c.gboolean,
    queued: [*c]c.GList,
    in_headers: c.gboolean,
    unknown_pages: [*c]c.GList,
    stored_buffers: [*c]c.GList,
    map: c.gint,
    is_skeleton: c.gboolean,
    have_fisbone: c.gboolean,
    granulerate_n: c.gint,
    granulerate_d: c.gint,
    granule_offset: i64,
    preroll: u32,
    granuleshift: c.guint,
    n_header_packets: c.gint,
    n_header_packets_seen: c.gint,
    accumulated_granule: i64,
    frame_size: c.gint,
    bitrate: c.gint,
    total_time: u64,
    is_sparse: c.gboolean,
    audio_clipping: c.gboolean,
    caps: [*c]c.GstCaps,
    is_video: c.gboolean,
    always_flush_page: c.gboolean,
    nln_increments: [4]c_int,
    nsn_increment: c_int,
    short_size: c_int,
    long_size: c_int,
    vorbis_log2_num_modes: c_int,
    vorbis_mode_sizes: [256]c_int,
    last_size: c_int,
    version: c_int,
    bitrate_upper: c.gint,
    bitrate_nominal: c.gint,
    bitrate_lower: c.gint,
    taglist: ?*c.GstTagList,
    theora_has_zero_keyoffset: c.gboolean,
    is_vp8: c.gboolean,
    invisible_count: i64,
    first_granpos: i64,
    is_ogm: c.gboolean,
    is_ogm_text: c.gboolean,
    is_cmml: c.gboolean,
    skeleton_major: u16,
    skeleton_minor: u16,
    prestime: i64,
    basetime: i64,
    n_index: c.guint,
    index: [*c]Index,
    kp_denom: u64,
    idx_bitrate: u64,
};

pub const FISBONE = 0;
pub const INDEX = 1;

const Map = struct {
    id: []const u8,
    min: c_long,
    media: ?[*:0]const u8,
    setup: ?*const fn (*Stream, *Packet) bool = null,
    setup_caps: ?*const fn (*Stream, [*c]const c.GstCaps) bool = null,
    to_granule: ?*const fn (*Stream, i64) i64 = null,
    to_granulepos: ?*const fn (*Stream, i64, i64) i64 = null,
    is_key_gp: ?*const fn (*Stream, i64) bool = null,
    is_key_packet: ?*const fn (*Stream, *Packet) bool = null,
    is_header: ?*const fn (*Stream, *Packet) bool = null,
    duration: ?*const fn (*Stream, *Packet) i64 = null,
    to_key_granule: ?*const fn (*Stream, i64) i64 = null,
    tags: ?*const fn (*Stream, *Packet) void = null,
    headers: ?*const fn (*Stream) [*c]c.GstBuffer = null,
    stats: ?*const fn (*Stream, *Packet) void = null,
};

fn le16(d: [*]const u8) u16 {
    return std.mem.readInt(u16, d[0..2], .little);
}

fn le32(d: [*]const u8) u32 {
    return std.mem.readInt(u32, d[0..4], .little);
}

fn le64(d: [*]const u8) u64 {
    return std.mem.readInt(u64, d[0..8], .little);
}

fn be16(d: [*]const u8) u16 {
    return std.mem.readInt(u16, d[0..2], .big);
}

fn be24(d: [*]const u8) u32 {
    return std.mem.readInt(u24, d[0..3], .big);
}

fn be32(d: [*]const u8) u32 {
    return std.mem.readInt(u32, d[0..4], .big);
}

fn invalidRate(s: *Stream) bool {
    s.granulerate_n = 0;
    s.granulerate_d = 0;
    return false;
}

fn badShift(s: *Stream) bool {
    s.granulerate_n = 0;
    s.granulerate_d = 0;
    s.granuleshift = NOSHIFT;
    return false;
}

pub fn packetStartTime(s: *Stream, p: *Packet) u64 {
    if (p.granulepos == -1) return NONE;
    const d = packetDuration(s, p);
    if (d == -1) return NONE;
    return granuleToTime(s, granuleposToGranule(s, p.granulepos) - d);
}

pub fn startTimeForGranulepos(s: *Stream, gp: i64) u64 {
    if (s.frame_size == 0) return NONE;
    return granuleToTime(s, granuleposToGranule(s, gp));
}

pub fn endTimeForGranulepos(s: *Stream, gp: i64) u64 {
    return granuleToTime(s, granuleposToGranule(s, gp));
}

pub fn granuleToTime(s: *Stream, g0: i64) u64 {
    if (g0 == 0 or s.granulerate_n == 0 or s.granulerate_d == 0) return 0;
    const g = g0 +% s.granule_offset;
    if (g < 0) return 0;
    return c.gst_util_uint64_scale(@bitCast(g), SECOND *% @as(u64, @bitCast(@as(i64, s.granulerate_d))), @bitCast(@as(i64, s.granulerate_n)));
}

pub fn granuleposToGranule(s: *Stream, gp: i64) i64 {
    if (gp == -1 or gp == 0) return gp;
    const f = maps[@intCast(s.map)].to_granule orelse return -1;
    return f(s, gp);
}

pub fn granuleposToKeyGranule(s: *Stream, gp: i64) i64 {
    if (maps[@intCast(s.map)].to_key_granule) |f| return f(s, gp);
    if (gp == -1 or gp == 0 or s.granuleshift == NOSHIFT) return gp;
    return gp >> @intCast(s.granuleshift);
}

pub fn granuleToGranulepos(s: *Stream, g: i64, key: i64) i64 {
    if (g == -1 or g == 0) return g;
    const f = maps[@intCast(s.map)].to_granulepos orelse return -1;
    return f(s, g, key);
}

pub fn granuleposIsKeyFrame(s: *Stream, gp: i64) bool {
    if (gp == -1) return false;
    const f = maps[@intCast(s.map)].is_key_gp orelse return false;
    return f(s, gp);
}

pub fn packetIsKeyFrame(s: *Stream, p: *Packet) bool {
    const f = maps[@intCast(s.map)].is_key_packet orelse return false;
    return f(s, p);
}

pub fn packetIsHeader(s: *Stream, p: *Packet) bool {
    const f = maps[@intCast(s.map)].is_header orelse return false;
    return f(s, p);
}

pub fn packetDuration(s: *Stream, p: *Packet) i64 {
    const f = maps[@intCast(s.map)].duration orelse return -1;
    return f(s, p);
}

pub fn extractTags(s: *Stream, p: *Packet) void {
    if (maps[@intCast(s.map)].tags) |f| f(s, p);
}

pub fn mediaType(s: *Stream) [*c]const u8 {
    if (s.caps == null) return null;
    const st = c.gst_caps_get_structure(s.caps, 0);
    if (st == null) return null;
    return c.gst_structure_get_name(st);
}

pub fn getHeaders(s: *Stream) [*c]c.GstBuffer {
    const f = maps[@intCast(s.map)].headers orelse return null;
    return f(s);
}

pub fn updateStats(s: *Stream, p: *Packet) void {
    const m = maps[@intCast(s.map)];
    if (m.headers == null) return;
    m.stats.?(s, p);
}

fn keyTrue(_: *Stream, _: i64) bool {
    return true;
}

fn packetKeyTrue(_: *Stream, _: *Packet) bool {
    return true;
}

fn toGranuleDefault(s: *Stream, gp: i64) i64 {
    if (s.granuleshift != 0 and s.granuleshift != NOSHIFT) {
        const sh: u6 = @intCast(s.granuleshift);
        const idx = gp >> sh;
        const off = gp -% (idx << sh);
        return idx +% off;
    }
    return gp;
}

fn toGranuleposDefault(s: *Stream, g: i64, key0: i64) i64 {
    if (s.granuleshift != 0 and s.granuleshift != NOSHIFT) {
        var key = key0;
        if (key < 0) key = if (s.theora_has_zero_keyoffset != 0) 0 else 1;
        const off = g -% key;
        return (key << @intCast(s.granuleshift)) | off;
    }
    return g;
}

fn headerTrue(_: *Stream, _: *Packet) bool {
    return true;
}

fn headerCount(s: *Stream, _: *Packet) bool {
    return s.n_header_packets_seen < s.n_header_packets;
}

fn durationConstant(s: *Stream, _: *Packet) i64 {
    return s.frame_size;
}

fn tagsFromComment(p: *Packet, id: ?[]const u8, tags: *?*c.GstTagList) void {
    var enc: [*c]u8 = null;
    const list = c.gst_tag_list_from_vorbiscomment(p.packet, @intCast(p.bytes), if (id) |x| x.ptr else null, if (id) |x| @intCast(x.len) else 0, &enc);
    if (list != null and enc != null) {
        if (enc[0] != 0 and c.g_utf8_validate(enc, -1, null) != 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, "encoder", enc, @as(?*anyopaque, null));
    }
    c.g_free(enc);
    if (tags.*) |t| c.gst_tag_list_unref(t);
    tags.* = list;
}

fn addTag(s: *Stream, tag: [*:0]const u8, v: anytype) void {
    if (s.taglist == null) s.taglist = c.gst_tag_list_new_empty();
    c.gst_tag_list_add(s.taglist, c.GST_TAG_MERGE_REPLACE, tag, v, @as(?*anyopaque, null));
}

fn ensureTags(s: *Stream) void {
    if (s.taglist == null) s.taglist = c.gst_tag_list_new_empty();
}

fn setupTheora(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    const vmaj = d[7];
    const vmin = d[8];
    const vrev = d[9];
    const w = be24(d + 14);
    const h = be24(d + 17);
    s.granulerate_n = @bitCast(be32(d + 22));
    s.granulerate_d = @bitCast(be32(d + 26));
    if (s.granulerate_n == 0 or s.granulerate_d == 0) return invalidRate(s);
    var par_n = be24(d + 30);
    var par_d = be24(d + 33);
    s.granuleshift = (@as(c.guint, d[40] & 0x03) << 3) + (d[41] >> 5);
    if (s.granuleshift >= 63) return badShift(s);
    s.is_video = 1;
    s.n_header_packets = 3;
    s.frame_size = 1;
    s.bitrate = @intCast(be24(d + 37));
    s.theora_has_zero_keyoffset = @intFromBool(((@as(u32, vmaj) << 16) | (@as(u32, vmin) << 8) | vrev) < 0x030201);
    s.caps = c.gst_caps_new_empty_simple("video/x-theora");
    if (w > 0 and h > 0) c.gst_caps_set_simple(s.caps, "width", c.G_TYPE_INT, @as(c.gint, @intCast(w)), "height", c.G_TYPE_INT, @as(c.gint, @intCast(h)), @as(?*anyopaque, null));
    if (par_n == 0 or par_d == 0) {
        par_n = 1;
        par_d = 1;
    }
    c.gst_caps_set_simple(s.caps, "framerate", c.gst_fraction_get_type(), s.granulerate_n, s.granulerate_d, "pixel-aspect-ratio", c.gst_fraction_get_type(), @as(c.gint, @intCast(par_n)), @as(c.gint, @intCast(par_d)), @as(?*anyopaque, null));
    return true;
}

fn toGranuleTheora(s: *Stream, gp: i64) i64 {
    if (s.granuleshift != 0 and s.granuleshift != NOSHIFT) {
        const sh: u6 = @intCast(s.granuleshift);
        const idx = gp >> sh;
        var off = gp -% (idx << sh);
        if (s.theora_has_zero_keyoffset != 0) off += 1;
        return idx +% off;
    }
    return gp;
}

fn keyTheora(s: *Stream, gp: i64) bool {
    if (gp == -1 or s.granuleshift == NOSHIFT) return false;
    const mask: i64 = @bitCast((@as(u64, 1) << @intCast(s.granuleshift)) - 1);
    return gp & mask == 0;
}

fn packetKeyTheora(_: *Stream, p: *Packet) bool {
    if (p.bytes == 0) return false;
    return p.packet[0] & 0xc0 == 0;
}

fn headerTheora(_: *Stream, p: *Packet) bool {
    return p.bytes > 0 and p.packet[0] & 0x80 == 0x80;
}

fn tagsTheora(s: *Stream, p: *Packet) void {
    if (p.bytes > 0 and p.packet[0] == 0x81) {
        tagsFromComment(p, "\x81theora", &s.taglist);
        addTag(s, "video-codec", @as([*:0]const u8, "Theora"));
        if (s.bitrate != 0) addTag(s, "bitrate", @as(c.guint, @bitCast(s.bitrate)));
    }
}

const Dirac = struct {
    width: i32 = 0,
    height: i32 = 0,
    interlaced: i32 = 0,
    fr_n: i32 = 0,
    fr_d: i32 = 0,
    ar_n: i32 = 0,
    ar_d: i32 = 0,
    interlaced_coding: u32 = 0,
};

const dirac_formats = [_][7]i32{
    .{ 640, 480, 0, 24000, 1001, 1, 1 },
    .{ 176, 120, 0, 15000, 1001, 10, 11 },
    .{ 176, 144, 0, 25, 2, 12, 11 },
    .{ 352, 240, 0, 15000, 1001, 10, 11 },
    .{ 352, 288, 0, 25, 2, 12, 11 },
    .{ 704, 480, 0, 15000, 1001, 10, 11 },
    .{ 704, 576, 0, 25, 2, 12, 11 },
    .{ 720, 480, 1, 30000, 1001, 10, 11 },
    .{ 720, 576, 1, 25, 1, 12, 11 },
    .{ 1280, 720, 0, 60000, 1001, 1, 1 },
    .{ 1280, 720, 0, 50, 1, 1, 1 },
    .{ 1920, 1080, 1, 30000, 1001, 1, 1 },
    .{ 1920, 1080, 1, 25, 1, 1, 1 },
    .{ 1920, 1080, 0, 60000, 1001, 1, 1 },
    .{ 1920, 1080, 0, 50, 1, 1, 1 },
    .{ 2048, 1080, 0, 24, 1, 1, 1 },
    .{ 4096, 2160, 0, 24, 1, 1, 1 },
};

const dirac_rates = [_][2]i32{ .{ 0, 0 }, .{ 24000, 1001 }, .{ 24, 1 }, .{ 25, 1 }, .{ 30000, 1001 }, .{ 30, 1 }, .{ 50, 1 }, .{ 60000, 1001 }, .{ 60, 1 }, .{ 15000, 1001 }, .{ 25, 2 } };
const dirac_aspects = [_][2]i32{ .{ 0, 0 }, .{ 1, 1 }, .{ 10, 11 }, .{ 12, 11 }, .{ 40, 33 }, .{ 16, 11 }, .{ 4, 3 } };

const Bits = struct {
    data: [*]const u8,
    left: i64,
    index: usize = 0,

    fn bit(b: *Bits) u32 {
        if (b.left < 1) return 1;
        const v = (b.data[b.index >> 3] >> @intCast(7 - (b.index & 7))) & 1;
        b.index += 1;
        b.left -= 1;
        return v;
    }

    fn uint(b: *Bits) u32 {
        var count: u5 = 0;
        var value: u32 = 0;
        while (b.bit() == 0) {
            count +%= 1;
            value <<= 1;
            value |= b.bit();
        }
        return (@as(u32, 1) << count) -% 1 +% value;
    }
};

fn diracParse(data: [*]const u8, n: i64) Dirac {
    var h = Dirac{};
    var b = Bits{ .data = data, .left = 8 * n };
    for (0..4) |_| _ = b.uint();
    const idx = b.uint();
    if (idx < dirac_formats.len) {
        const f = dirac_formats[idx];
        h = .{ .width = f[0], .height = f[1], .interlaced = f[2], .fr_n = f[3], .fr_d = f[4], .ar_n = f[5], .ar_d = f[6] };
    }
    if (b.bit() != 0) {
        h.width = @bitCast(b.uint());
        h.height = @bitCast(b.uint());
    }
    if (b.bit() != 0) _ = b.uint();
    if (b.bit() != 0) h.interlaced = @bitCast(b.uint());
    if (b.bit() != 0) {
        const i = b.uint();
        if (i == 0) {
            h.fr_n = @bitCast(b.uint());
            h.fr_d = @bitCast(b.uint());
        } else if (i < dirac_rates.len) {
            h.fr_n = dirac_rates[i][0];
            h.fr_d = dirac_rates[i][1];
        }
    }
    if (b.bit() != 0) {
        const i = b.uint();
        if (i == 0) {
            h.ar_n = @bitCast(b.uint());
            h.ar_d = @bitCast(b.uint());
        } else if (i < dirac_aspects.len) {
            h.ar_n = dirac_aspects[i][0];
            h.ar_d = dirac_aspects[i][1];
        }
    }
    if (b.bit() != 0) {
        for (0..4) |_| _ = b.uint();
    }
    if (b.bit() != 0) {
        if (b.uint() == 0) {
            for (0..4) |_| _ = b.uint();
        }
    }
    if (b.bit() != 0) {
        if (b.uint() == 0) {
            for (0..3) |_| {
                if (b.bit() != 0) _ = b.uint();
            }
        }
    }
    h.interlaced_coding = b.uint();
    return h;
}

fn setupDirac(s: *Stream, p: *Packet) bool {
    const h = diracParse(p.packet + 13, p.bytes - 13);
    if (h.interlaced_coding != 0) return false;
    if (h.fr_n == 0 or h.fr_d == 0) return false;
    s.is_video = 1;
    s.always_flush_page = 1;
    s.granulerate_n = h.fr_n *% 2;
    s.granulerate_d = h.fr_d;
    s.granuleshift = 22;
    s.n_header_packets = 1;
    s.frame_size = 2;
    s.caps = c.gst_caps_new_simple("video/x-dirac", "width", c.G_TYPE_INT, h.width, "height", c.G_TYPE_INT, h.height, "interlace-mode", c.G_TYPE_STRING, @as([*:0]const u8, if (h.interlaced != 0) "mixed" else "progressive"), "pixel-aspect-ratio", c.gst_fraction_get_type(), h.ar_n, h.ar_d, "framerate", c.gst_fraction_get_type(), h.fr_n, h.fr_d, @as(?*anyopaque, null));
    return true;
}

fn keyDirac(_: *Stream, gp: i64) bool {
    if (gp == -1) return true;
    const dh = (gp >> 22) & 0xff;
    const dl = gp & 0xff;
    return ((dh << 8) | dl) == 0;
}

fn toGranuleDirac(_: *Stream, gp: i64) i64 {
    const pt = ((gp >> 22) +% (gp & ((1 << 22) - 1))) >> 9;
    const delay = (gp >> 9) & 0x1fff;
    return pt - delay + 4;
}

fn toGranuleposDirac(_: *Stream, _: i64, _: i64) i64 {
    return -1;
}

fn toKeyGranuleDirac(_: *Stream, gp: i64) i64 {
    if (gp == -1 or gp == 0) return gp;
    const pt = ((gp >> 22) +% (gp & ((1 << 22) - 1))) >> 9;
    const dist = (((gp >> 22) & 0xff) << 8) | (gp & 0xff);
    const delay = (gp >> 9) & 0x1fff;
    return pt - delay - 2 * dist + 4;
}

fn setupVp8(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    const w: c.gint = be16(d + 8);
    const h: c.gint = be16(d + 10);
    var par_n: c.gint = @intCast(be24(d + 12));
    var par_d: c.gint = @intCast(be24(d + 15));
    const fn_: c.gint = @bitCast(be32(d + 18));
    const fd: c.gint = @bitCast(be32(d + 22));
    if (fn_ == 0 or fd == 0) return false;
    s.is_video = 1;
    s.is_vp8 = 1;
    s.granulerate_n = fn_;
    s.granulerate_d = fd;
    s.n_header_packets = 2;
    s.frame_size = 1;
    if (par_n == 0 or par_d == 0) {
        par_n = 1;
        par_d = 1;
    }
    s.caps = c.gst_caps_new_simple("video/x-vp8", "width", c.G_TYPE_INT, w, "height", c.G_TYPE_INT, h, "pixel-aspect-ratio", c.gst_fraction_get_type(), par_n, par_d, "framerate", c.gst_fraction_get_type(), fn_, fd, @as(?*anyopaque, null));
    return true;
}

fn vp8Header(caps: [*c]const c.GstCaps, data: *[26]u8) bool {
    const st = c.gst_caps_get_structure(caps, 0);
    var w: c.gint = 0;
    var h: c.gint = 0;
    var fn_: c.gint = 0;
    var fd: c.gint = 0;
    var pn: c.gint = 0;
    var pd: c.gint = 0;
    if (!(c.gst_structure_get_int(st, "width", &w) != 0 and c.gst_structure_get_int(st, "height", &h) != 0 and c.gst_structure_get_fraction(st, "framerate", &fn_, &fd) != 0)) return false;
    if (c.gst_structure_get_fraction(st, "pixel-aspect-ratio", &pn, &pd) == 0) {
        pn = 1;
        pd = 1;
    }
    @memcpy(data[0..8], "OVP80\x01\x01\x00");
    std.mem.writeInt(u16, data[8..10], @truncate(@as(u32, @bitCast(w))), .big);
    std.mem.writeInt(u16, data[10..12], @truncate(@as(u32, @bitCast(h))), .big);
    std.mem.writeInt(u24, data[12..15], @truncate(@as(u32, @bitCast(pn))), .big);
    std.mem.writeInt(u24, data[15..18], @truncate(@as(u32, @bitCast(pd))), .big);
    std.mem.writeInt(u32, data[18..22], @bitCast(fn_), .big);
    std.mem.writeInt(u32, data[22..26], @bitCast(fd), .big);
    return true;
}

fn setupVp8Caps(s: *Stream, caps: [*c]const c.GstCaps) bool {
    var data: [26]u8 = undefined;
    if (!vp8Header(caps, &data)) return false;
    var p = std.mem.zeroes(Packet);
    p.packet = &data;
    p.bytes = 26;
    return setupVp8(s, &p);
}

fn keyVp8(_: *Stream, gp: i64) bool {
    if (gp == -1) return false;
    const g: u64 = @bitCast(gp);
    return (g >> 3) & 0x07ffffff == 0;
}

fn packetKeyVp8(_: *Stream, p: *Packet) bool {
    if (p.bytes < 3) return false;
    return p.packet[0] & 1 != 0;
}

fn toGranuleVp8(_: *Stream, gp: i64) i64 {
    const g: u64 = @bitCast(gp);
    return @as(u32, @truncate(g >> 32));
}

fn toGranuleposVp8(s: *Stream, g: i64, key: i64) i64 {
    const inv: i64 = if (s.invisible_count <= 0) 3 else s.invisible_count - 1;
    return (g << 32) | (inv << 30) | ((g -% key) << 3);
}

fn durationVp8(_: *Stream, p: *Packet) i64 {
    if (p.bytes < 3) return 0;
    return if ((p.packet[0] >> 4) & 1 != 0) 1 else 0;
}

fn toKeyGranuleVp8(_: *Stream, gp: i64) i64 {
    const g: u64 = @bitCast(gp);
    const pts = g >> 32;
    const dist = (g >> 3) & 0x07ffffff;
    if (gp == -1 or gp == 0) return gp;
    if (dist > pts) return 0;
    return @intCast(pts - dist);
}

fn headerVp8(_: *Stream, p: *Packet) bool {
    return p.bytes >= 5 and std.mem.eql(u8, p.packet[0..5], "OVP80");
}

fn tagsVp8(s: *Stream, p: *Packet) void {
    if (p.bytes >= 7 and std.mem.eql(u8, p.packet[0..7], "OVP80\x02 ")) {
        tagsFromComment(p, "OVP80\x02 ", &s.taglist);
        addTag(s, "video-codec", @as([*:0]const u8, "VP8"));
    }
}

fn headersVp8(s: *Stream) [*c]c.GstBuffer {
    const data: *[26]u8 = @ptrCast(c.g_malloc(26));
    if (vp8Header(s.caps, data)) return c.gst_buffer_new_wrapped(data, 26);
    c.g_free(data);
    return null;
}

fn statsVp8(s: *Stream, p: *Packet) void {
    if (durationVp8(s, p) != 0) {
        s.invisible_count = -1;
    } else s.invisible_count += 1;
}

fn vorbisHeader(s: *Stream, p: *Packet) void {
    const long: c_int = @as(c_int, 1) << @intCast(p.packet[28] >> 4);
    const short: c_int = @as(c_int, 1) << @intCast(p.packet[28] & 0xF);
    s.nln_increments[3] = long >> 1;
    s.nln_increments[2] = 3 * (long >> 2) - (short >> 2);
    s.nln_increments[1] = (long >> 2) + (short >> 2);
    s.nln_increments[0] = s.nln_increments[3];
    s.short_size = short;
    s.long_size = long;
    s.nsn_increment = short >> 1;
}

fn vorbisSetup(s: *Stream, p: *Packet) c_int {
    const start = p.packet;
    const len: usize = @intCast(p.bytes);
    var pos: usize = len - 1;
    var off: i32 = 8;
    var size: i32 = 0;
    while (true) {
        off -= 1;
        if ((@as(u32, 1) << @intCast(off)) & start[pos] != 0) break;
        if (off == 0) {
            off = 8;
            if (pos == 0) return -1;
            pos -= 1;
        }
    }
    while (true) {
        off = @mod(off + 7, 8);
        if (off == 7) {
            if (pos == 0) return -1;
            pos -= 1;
        }
        if (pos < 5) return -1;
        const lo: u32 = (@as(u32, 1) << @intCast(off + 1)) - 1;
        if ((start[pos - 5] & ~lo & 0xff) != 0 or start[pos - 4] != 0 or start[pos - 3] != 0 or start[pos - 2] != 0 or (start[pos - 1] & lo) != 0) break;
        size += 1;
        pos -= 5;
    }
    for (0..2) |_| {
        var check: i32 = 0;
        if (off > 4) {
            check = (start[pos] >> @intCast(off - 5)) & 0x3F;
        } else {
            if (pos < 1) return -1;
            check = start[pos] & @as(u8, @truncate((@as(u32, 1) << @intCast(off + 1)) - 1));
            check <<= @intCast(5 - off);
            const m: u32 = (@as(u32, 1) << @intCast(off + 3)) - 1;
            check |= @intCast((start[pos - 1] & ~m & 0xff) >> @intCast(off + 3));
        }
        check += 1;
        if (check == size) break;
        off = @mod(off + 1, 8);
        if (off == 0) pos += 1;
        pos += 5;
        size -= 1;
        if (pos >= len) return -1;
    }
    var i: i32 = -1;
    while (true) {
        i += 1;
        if ((@as(i64, 1) << @intCast(i)) >= size) break;
    }
    s.vorbis_log2_num_modes = i;
    if (size > 256) return -1;
    for (0..@intCast(@max(size, 0))) |k| {
        off = @mod(off + 1, 8);
        if (off == 0) pos += 1;
        s.vorbis_mode_sizes[k] = (start[pos] >> @intCast(off)) & 1;
        pos += 5;
        if (pos >= len) return -1;
    }
    return 0;
}

fn setupVorbis(s: *Stream, p: *Packet) bool {
    const d = p.packet + 7;
    s.version = @bitCast(le32(d));
    const chans = d[4];
    s.granulerate_n = @bitCast(le32(d + 5));
    s.granulerate_d = 1;
    if (s.granulerate_n == 0) return invalidRate(s);
    s.granuleshift = 0;
    s.preroll = 2;
    s.last_size = 0;
    s.bitrate_upper = @bitCast(le32(d + 9));
    s.bitrate_nominal = @bitCast(le32(d + 13));
    s.bitrate_lower = @bitCast(le32(d + 17));
    if (s.bitrate_nominal > 0) s.bitrate = s.bitrate_nominal;
    if (s.bitrate_upper > 0 and s.bitrate == 0) s.bitrate = s.bitrate_upper;
    if (s.bitrate_lower > 0 and s.bitrate == 0) s.bitrate = s.bitrate_lower;
    s.n_header_packets = 3;
    vorbisHeader(s, p);
    s.caps = c.gst_caps_new_simple("audio/x-vorbis", "rate", c.G_TYPE_INT, s.granulerate_n, "channels", c.G_TYPE_INT, @as(c.gint, chans), @as(?*anyopaque, null));
    return true;
}

fn headerVorbis(s: *Stream, p: *Packet) bool {
    if (p.bytes == 0 or p.packet[0] & 1 == 0) return false;
    var res: c_int = 0;
    if (p.packet[0] == 5) res = vorbisSetup(s, p);
    return res == 0;
}

fn tagsVorbis(s: *Stream, p: *Packet) void {
    if (p.bytes == 0 or p.packet[0] & 1 == 0) return;
    if (p.packet[0] == 3) {
        tagsFromComment(p, "\x03vorbis", &s.taglist);
        ensureTags(s);
        c.gst_tag_list_add(s.taglist, c.GST_TAG_MERGE_REPLACE, "encoder-version", @as(c.guint, @bitCast(s.version)), "audio-codec", @as([*:0]const u8, "Vorbis"), @as(?*anyopaque, null));
        if (s.bitrate_nominal > 0) addTag(s, "nominal-bitrate", @as(c.guint, @bitCast(s.bitrate_nominal)));
        if (s.bitrate_upper > 0) addTag(s, "maximum-bitrate", @as(c.guint, @bitCast(s.bitrate_upper)));
        if (s.bitrate_lower > 0) addTag(s, "minimum-bitrate", @as(c.guint, @bitCast(s.bitrate_lower)));
        if (s.bitrate != 0) addTag(s, "bitrate", @as(c.guint, @bitCast(s.bitrate)));
    }
}

fn durationVorbis(s: *Stream, p: *Packet) i64 {
    if (p.bytes == 0 or p.packet[0] & 1 != 0) return 0;
    const mask: c_int = (@as(c_int, 1) << @intCast(s.vorbis_log2_num_modes)) - 1;
    const mode: usize = @intCast((p.packet[0] >> 1) & mask);
    const size = if (s.vorbis_mode_sizes[mode] != 0) s.long_size else s.short_size;
    const d: c_int = if (s.last_size == 0) 0 else @divTrunc(s.last_size, 4) + @divTrunc(size, 4);
    s.last_size = size;
    return d;
}

fn setupSpeex(s: *Stream, p: *Packet) bool {
    const d = p.packet + 36;
    s.granulerate_n = @bitCast(le32(d));
    s.granulerate_d = 1;
    if (s.granulerate_n == 0) return invalidRate(s);
    s.granuleshift = 0;
    const chans = le32(d + 12);
    s.bitrate = @bitCast(le32(d + 16));
    s.n_header_packets = @bitCast(le32(p.packet + 68) +% 2);
    s.frame_size = @bitCast(le32(p.packet + 64) *% le32(p.packet + 56));
    s.caps = c.gst_caps_new_simple("audio/x-speex", "rate", c.G_TYPE_INT, s.granulerate_n, "channels", c.G_TYPE_INT, @as(c.gint, @bitCast(chans)), @as(?*anyopaque, null));
    return true;
}

fn tagsCount(s: *Stream, p: *Packet) void {
    if (p.bytes > 0 and s.n_header_packets_seen == 1) {
        tagsFromComment(p, null, &s.taglist);
        ensureTags(s);
        if (s.is_video != 0) {
            _ = c.gst_pb_utils_add_codec_description_to_tag_list(s.taglist, "video-codec", s.caps);
        } else if (s.is_sparse == 0 and s.is_ogm_text == 0 and s.is_ogm == 0) {
            _ = c.gst_pb_utils_add_codec_description_to_tag_list(s.taglist, "audio-codec", s.caps);
        }
        if (s.bitrate != 0) addTag(s, "bitrate", @as(c.guint, @bitCast(s.bitrate)));
    }
}

fn setupFLaC(s: *Stream, _: *Packet) bool {
    s.granulerate_n = 0;
    s.granulerate_d = 1;
    s.granuleshift = 0;
    s.n_header_packets = 3;
    s.caps = c.gst_caps_new_empty_simple("audio/x-flac");
    return true;
}

fn headerFLaC(s: *Stream, p: *Packet) bool {
    if (s.n_header_packets_seen == 1) {
        if (p.bytes < 17) return false;
        const d = p.packet;
        s.granulerate_n = (@as(c.gint, d[14]) << 12) | (@as(c.gint, d[15]) << 4) | ((d[16] >> 4) & 0xf);
    }
    return s.n_header_packets_seen < s.n_header_packets;
}

fn setupFlac(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    s.granulerate_n = @intCast((be32(d + 27) & 0xFFFFF000) >> 12);
    s.granulerate_d = 1;
    if (s.granulerate_n == 0) return invalidRate(s);
    s.granuleshift = 0;
    const chans = ((be32(d + 27) & 0xE00) >> 9) + 1;
    s.n_header_packets = be16(d + 7);
    s.caps = c.gst_caps_new_simple("audio/x-flac", "rate", c.G_TYPE_INT, s.granulerate_n, "channels", c.G_TYPE_INT, @as(c.gint, @intCast(chans)), @as(?*anyopaque, null));
    return true;
}

fn headerFlac(_: *Stream, p: *Packet) bool {
    return p.bytes > 0 and p.packet[0] != 0xff;
}

fn durationFlac(_: *Stream, p: *Packet) i64 {
    if (p.bytes < 4) return -1;
    const idx = p.packet[2] >> 4;
    if (idx == 1) return 192;
    if (idx >= 2 and idx <= 5) return @as(i64, 576) << @intCast(idx - 2);
    if (idx >= 8) return @as(i64, 256) << @intCast(idx - 8);
    if (idx == 6 or idx == 7) {
        const nb: c_long = idx - 6 + 1;
        if (p.bytes < 4 + 1 + nb) return -1;
        var tmp = p.packet[4];
        var len: c_long = 0;
        while (tmp & 0x80 != 0) {
            len += 1;
            tmp <<= 1;
        }
        if (len == 2) return -1;
        if (len == 0) len += 1;
        if (p.bytes < 4 + len + nb) return -1;
        const at: usize = @intCast(4 + len);
        if (nb == 1) return @as(i64, p.packet[at]) + 1;
        return @as(i64, be16(p.packet + at)) + 1;
    }
    return -1;
}

fn tagsFlac(s: *Stream, p: *Packet) void {
    if (p.bytes > 4 and (p.packet[0] & 0x7F) == 4) {
        tagsFromComment(p, p.packet[0..4], &s.taglist);
        addTag(s, "audio-codec", @as([*:0]const u8, "FLAC"));
    }
}

fn setupFishead(s: *Stream, p: *Packet) bool {
    const d = p.packet + 8;
    s.skeleton_major = le16(d);
    s.skeleton_minor = le16(d + 2);
    const pn: i64 = @bitCast(le64(d + 4));
    const pd: i64 = @bitCast(le64(d + 12));
    const bn: i64 = @bitCast(le64(d + 20));
    const bd: i64 = @bitCast(le64(d + 28));
    const rest = d + 36;
    s.basetime = if (bd != 0) @bitCast(c.gst_util_uint64_scale(SECOND, @bitCast(bn), @bitCast(bd))) else -1;
    s.prestime = if (pd != 0) @bitCast(c.gst_util_uint64_scale(SECOND, @bitCast(pn), @bitCast(pd))) else -1;
    if (p.bytes - 44 >= 112 and s.skeleton_major == 3 and s.skeleton_minor > 0) {
        const fsn: i64 = @bitCast(le64(rest + 64));
        const fsd: i64 = @bitCast(le64(rest + 72));
        const lsn: i64 = @bitCast(le64(rest + 80));
        const lsd: i64 = @bitCast(le64(rest + 88));
        const first: i64 = if (fsd > 0) @bitCast(c.gst_util_uint64_scale(SECOND, @bitCast(fsn), @bitCast(fsd))) else 0;
        const last: i64 = if (lsd > 0) @bitCast(c.gst_util_uint64_scale(SECOND, @bitCast(lsn), @bitCast(lsd))) else 0;
        s.total_time = if (last > first) @bitCast(last - first) else NONE;
    } else if (p.bytes - 44 >= 80 and s.skeleton_major == 4) {} else s.total_time = NONE;
    s.is_skeleton = 1;
    s.is_sparse = 1;
    s.caps = c.gst_caps_new_empty_simple("application/x-ogg-skeleton");
    return true;
}

pub fn parseFisbone(data: [*c]const u8, size: c.guint, serialno: ?*u32, kind: ?*c_int) bool {
    if (size != 0 and size < 52) return false;
    if (size == 0) return false;
    var t: c_int = 0;
    var off: usize = 0;
    if (std.mem.eql(u8, data[0..8], "fisbone\x00")) {
        t = FISBONE;
        off = 12;
    } else if (std.mem.eql(u8, data[0..6], "index\x00")) {
        t = INDEX;
        off = 6;
    } else return false;
    if (serialno) |sp| sp.* = le32(data + off);
    if (kind) |k| k.* = t;
    return true;
}

pub fn addFisbone(s: *Stream, data0: [*c]const u8) bool {
    if (s.have_fisbone != 0) return false;
    const d = data0 + 20;
    if (s.granulerate_n == 0 or s.granulerate_d == 0) {
        s.granulerate_n = @truncate(@as(i64, @bitCast(le64(d))));
        s.granulerate_d = @truncate(@as(i64, @bitCast(le64(d + 8))));
    }
    if (s.granuleshift == NOSHIFT) {
        s.granuleshift = d[28];
        if (s.granuleshift >= 63) return badShift(s);
    }
    s.have_fisbone = 1;
    s.preroll = le32(d + 24);
    return true;
}

fn readVlc(data: *[*c]const u8, size: *c.guint, out: *u64) bool {
    var shift: u6 = 0;
    out.* = 0;
    while (true) {
        if (size.* < 1) return false;
        const b = data.*[0];
        const v: i32 = @bitCast(@as(u32, b & 0x7f) << @intCast(shift & 31));
        out.* |= @bitCast(@as(i64, v));
        shift +%= 7;
        data.* += 1;
        size.* -= 1;
        if (b & 0x80 == 0x80) break;
    }
    return true;
}

pub fn addIndex(s: *Stream, skel: *Stream, data0: [*c]const u8, size0: c.guint) bool {
    if (s.index != null) return true;
    if ((skel.skeleton_major == 3 and size0 < 26) or (skel.skeleton_major == 4 and size0 < 62)) return false;
    var data = data0 + 10;
    var size = size0 - 10;
    const nkp = le64(data);
    data += 8;
    size -= 8;
    s.kp_denom = le64(data);
    if (s.kp_denom == 0) s.kp_denom = 1;
    data += 8;
    size -= 8;
    if (skel.skeleton_major == 4) {
        const first = c.gst_util_uint64_scale(SECOND, le64(data), s.kp_denom);
        const last = c.gst_util_uint64_scale(SECOND, le64(data + 8), s.kp_denom);
        s.total_time = if (@as(i64, @bitCast(last)) > @as(i64, @bitCast(first))) last - first else NONE;
        data += 16;
        size -= 16;
    }
    s.index = @ptrCast(@alignCast(c.g_try_malloc_n(nkp, @sizeOf(Index))));
    if (s.index == null) return false;
    var n: u64 = 0;
    var off: u64 = 0;
    var ts: u64 = 0;
    while (n < nkp) : (n += 1) {
        var od: u64 = 0;
        var td: u64 = 0;
        if (!readVlc(&data, &size, &od)) break;
        if (!readVlc(&data, &size, &td)) break;
        off +%= od;
        ts +%= td;
        s.index[n] = .{ .offset = off, .timestamp = ts };
    }
    s.n_index = @intCast(n);
    if (n > 2) {
        const b = s.index[n - 1].offset -% s.index[0].offset;
        const t = s.index[n - 1].timestamp -% s.index[0].timestamp;
        s.idx_bitrate = c.gst_util_uint64_scale(8 *% b, s.kp_denom, t);
    }
    return true;
}

fn compareIndex(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const i: *const Index = @ptrCast(@alignCast(a));
    const t: *const u64 = @ptrCast(@alignCast(b));
    return if (i.timestamp < t.*) -1 else if (i.timestamp > t.*) 1 else 0;
}

pub fn searchIndex(s: *Stream, ts: *u64, off: *u64) bool {
    if (s.n_index == 0 or s.index == null) return false;
    var t = c.gst_util_uint64_scale(ts.*, s.kp_denom, SECOND);
    const best: ?*Index = @ptrCast(@alignCast(c.gst_util_array_binary_search(s.index, s.n_index, @sizeOf(Index), compareIndex, c.GST_SEARCH_MODE_BEFORE, &t, null)));
    const b = best orelse return false;
    off.* = b.offset;
    ts.* = c.gst_util_uint64_scale(b.timestamp, SECOND, s.kp_denom);
    return true;
}

fn headerOgm(_: *Stream, p: *Packet) bool {
    return p.bytes >= 1 and p.packet[0] & 1 != 0;
}

fn tagsOgm(s: *Stream, p: *Packet) void {
    if (p.packet[0] & 1 == 0 and (p.packet[0] & 3 != 0 and s.is_ogm_text != 0)) tagsFromComment(p, "\x03vorbis", &s.taglist);
}

fn durationOgm(_: *Stream, p: *Packet) i64 {
    const d = p.packet;
    const off: c_long = 1 + (((d[0] & 0xc0) >> 6) | ((d[0] & 0x02) << 1));
    if (off > p.bytes) return -1;
    var samples: i64 = 0;
    var n: usize = @intCast(off - 1);
    while (n > 0) : (n -= 1) samples = (samples << 8) | d[n];
    return samples;
}

fn fourcc(f: u32) [*c]u8 {
    return c.g_strdup_printf("%c%c%c%c", @as(c_int, @intCast(f & 0xff)), @as(c_int, @intCast((f >> 8) & 0xff)), @as(c_int, @intCast((f >> 16) & 0xff)), @as(c_int, @intCast((f >> 24) & 0xff)));
}

fn setupOgmAudio(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    s.granulerate_n = @truncate(@as(i64, @bitCast(le64(d + 25))));
    s.granulerate_d = 1;
    if (s.granulerate_n == 0) return invalidRate(s);
    const f = le32(d + 9);
    const fstr = fourcc(f);
    s.caps = c.gst_riff_create_audio_caps(@truncate(f), null, null, null, null, null, null);
    if (s.caps != null) {
        c.gst_caps_set_simple(s.caps, "rate", c.G_TYPE_INT, s.granulerate_n, @as(?*anyopaque, null));
    } else s.caps = c.gst_caps_new_simple("audio/x-ogm-unknown", "fourcc", c.G_TYPE_STRING, fstr, "rate", c.G_TYPE_INT, s.granulerate_n, @as(?*anyopaque, null));
    c.g_free(fstr);
    s.n_header_packets = 1;
    s.is_ogm = 1;
    return true;
}

fn clampUnit(t: i64) c.gint {
    return @intCast(std.math.clamp(t, std.math.minInt(c.gint), std.math.maxInt(c.gint)));
}

fn setupOgmVideo(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    s.is_video = 1;
    s.granulerate_n = 10000000;
    s.granulerate_d = clampUnit(@bitCast(le64(d + 17)));
    const f = le32(d + 9);
    const w: c.gint = @bitCast(le32(d + 45));
    const h: c.gint = @bitCast(le32(d + 49));
    const fstr = fourcc(f);
    s.caps = c.gst_riff_create_video_caps(f, null, null, null, null, null);
    if (s.caps == null) {
        s.caps = c.gst_caps_new_simple("video/x-ogm-unknown", "fourcc", c.G_TYPE_STRING, fstr, "framerate", c.gst_fraction_get_type(), s.granulerate_n, s.granulerate_d, @as(?*anyopaque, null));
    } else c.gst_caps_set_simple(s.caps, "framerate", c.gst_fraction_get_type(), s.granulerate_n, s.granulerate_d, "width", c.G_TYPE_INT, w, "height", c.G_TYPE_INT, h, @as(?*anyopaque, null));
    c.g_free(fstr);
    s.n_header_packets = 1;
    s.frame_size = 1;
    s.is_ogm = 1;
    return true;
}

fn setupOgmText(s: *Stream, p: *Packet) bool {
    s.granulerate_n = 10000000;
    s.granulerate_d = clampUnit(@bitCast(le64(p.packet + 17)));
    if (s.granulerate_d <= 0) return invalidRate(s);
    s.caps = c.gst_caps_new_simple("text/x-raw", "format", c.G_TYPE_STRING, "utf8", @as(?*anyopaque, null));
    s.n_header_packets = 1;
    s.is_ogm = 1;
    s.is_ogm_text = 1;
    s.is_sparse = 1;
    return true;
}

fn setupPcm(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    s.granulerate_n = @bitCast(le32(d + 16));
    s.granulerate_d = 1;
    if (s.granulerate_n == 0) return invalidRate(s);
    const format = le32(d + 12);
    const channels: c.gint = d[21];
    const raw: ?[*:0]const u8 = switch (format) {
        0 => "S8",
        1 => "U8",
        2 => "S16LE",
        3 => "S16BE",
        4 => "S24LE",
        5 => "S24BE",
        6 => "S32LE",
        7 => "S32BE",
        0x20 => "F32LE",
        0x21 => "F32BE",
        0x22 => "F64LE",
        0x23 => "F64BE",
        else => null,
    };
    var caps: [*c]c.GstCaps = undefined;
    if (raw) |r| {
        caps = c.gst_caps_new_simple("audio/x-raw", "format", c.G_TYPE_STRING, r, @as(?*anyopaque, null));
    } else if (format == 0x10) {
        caps = c.gst_caps_new_empty_simple("audio/x-mulaw");
    } else if (format == 0x11) {
        caps = c.gst_caps_new_empty_simple("audio/x-alaw");
    } else return invalidRate(s);
    s.n_header_packets = @bitCast(2 +% le32(d + 24));
    c.gst_caps_set_simple(caps, "layout", c.G_TYPE_STRING, "interleaved", "rate", c.G_TYPE_INT, s.granulerate_n, "channels", c.G_TYPE_INT, channels, @as(?*anyopaque, null));
    s.caps = caps;
    return true;
}

fn setupCmml(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    s.granulerate_n = @truncate(@as(i64, @bitCast(le64(d + 12))));
    s.granulerate_d = @truncate(@as(i64, @bitCast(le64(d + 20))));
    s.granuleshift = d[28];
    if (s.granuleshift >= 63) return badShift(s);
    if (s.granulerate_n == 0) return badShift(s);
    s.n_header_packets = 3;
    s.caps = c.gst_caps_new_empty_simple("text/x-cmml");
    s.always_flush_page = 1;
    s.is_sparse = 1;
    s.is_cmml = 1;
    return true;
}

fn setupCelt(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    s.granulerate_n = @bitCast(le32(d + 36));
    s.granulerate_d = 1;
    s.granuleshift = 0;
    s.frame_size = @bitCast(le32(d + 44));
    s.n_header_packets = @bitCast(le32(d + 56) +% 2);
    if (s.granulerate_n == 0) return badShift(s);
    s.caps = c.gst_caps_new_simple("audio/x-celt", "rate", c.G_TYPE_INT, s.granulerate_n, @as(?*anyopaque, null));
    return true;
}

fn setupKate(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    s.granulerate_n = @bitCast(le32(d + 24));
    s.granulerate_d = @bitCast(le32(d + 28));
    s.granuleshift = d[15];
    if (s.granuleshift >= 63) return badShift(s);
    if (s.granulerate_n == 0) return badShift(s);
    s.n_header_packets = d[11];
    const cat = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(d + 48)), 0);
    const subs = [_][]const u8{ "subtitles", "SUB", "spu-subtitles", "K-SPU" };
    var is_sub = false;
    for (subs) |x| {
        if (std.mem.eql(u8, cat, x)) is_sub = true;
    }
    s.caps = c.gst_caps_new_empty_simple(if (is_sub) "subtitle/x-kate" else "application/x-kate");
    s.is_sparse = 1;
    s.always_flush_page = 1;
    return true;
}

fn durationKate(_: *Stream, p: *Packet) i64 {
    if (p.bytes < 1) return 0;
    if (p.packet[0] == 0) {
        if (p.bytes < 1 + 16) return 0;
        const d: i64 = @bitCast(le64(p.packet + 9));
        return if (d < 0) 0 else d;
    }
    return -1;
}

fn tagsKate(s: *Stream, p: *Packet) void {
    if (p.bytes <= 0) return;
    var list: ?*c.GstTagList = null;
    switch (p.packet[0]) {
        0x80 => {
            if (p.bytes >= 64) {
                var lang: [16]u8 = undefined;
                @memcpy(&lang, p.packet[32..48]);
                lang[15] = 0;
                _ = c.g_strdelimit(@ptrCast(&lang), null, 0);
                const canon = c.gst_tag_get_language_code_iso_639_1(@ptrCast(&lang));
                if (canon != null) list = c.gst_tag_list_new("language-code", canon, @as(?*anyopaque, null));
            }
        },
        0x81 => {
            tagsFromComment(p, "\x81kate\x00\x00\x00\x00", &list);
            if (list != null) c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, "subtitle-codec", @as([*:0]const u8, "Kate"), @as(?*anyopaque, null));
        },
        else => {},
    }
    if (list) |l| {
        if (s.taglist) |t| {
            c.gst_tag_list_insert(t, l, c.GST_TAG_MERGE_KEEP_ALL);
            c.gst_tag_list_unref(l);
        } else s.taglist = l;
    }
}

fn setupOpus(s: *Stream, p: *Packet) bool {
    s.granulerate_n = 48000;
    s.granulerate_d = 1;
    s.granuleshift = 0;
    s.n_header_packets = 2;
    s.first_granpos = -1;
    s.audio_clipping = 1;
    s.granule_offset = -@as(i64, le16(p.packet + 10));
    const b = c.gst_buffer_new_memdup(p.packet, @intCast(p.bytes));
    s.caps = c.gst_codec_utils_opus_create_caps_from_header(b, null);
    c.gst_buffer_unref(b);
    return true;
}

fn headerOpus(_: *Stream, p: *Packet) bool {
    return p.bytes >= 8 and std.mem.eql(u8, p.packet[0..4], "Opus");
}

fn toGranuleOpus(s: *Stream, gp: i64) i64 {
    if (gp == -1) return -1;
    if (s.first_granpos < 0 or gp < s.first_granpos) s.first_granpos = gp;
    return gp;
}

fn durationOpus(s: *Stream, p: *Packet) i64 {
    const durations = [32]i64{ 480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 480, 960, 120, 240, 480, 960, 120, 240, 480, 960, 120, 240, 480, 960, 120, 240, 480, 960 };
    if (p.bytes < 1) return 0;
    if (headerOpus(s, p)) return 0;
    const toc = p.packet[0];
    const fd = durations[toc >> 3];
    var n: i64 = 0;
    switch (toc & 3) {
        0 => n = 1,
        1, 2 => n = 2,
        else => {
            if (p.bytes < 2) return 0;
            n = p.packet[1] & 63;
        },
    }
    const d = n * fd;
    if (d > 5760) return 0;
    return d;
}

fn tagsOpus(s: *Stream, p: *Packet) void {
    if (p.bytes >= 8 and std.mem.eql(u8, p.packet[0..8], "OpusTags")) {
        tagsFromComment(p, "OpusTags", &s.taglist);
        addTag(s, "audio-codec", @as([*:0]const u8, "Opus"));
    }
}

fn setupDaala(s: *Stream, p: *Packet) bool {
    const d = p.packet;
    const w = le32(d + 9);
    const h = le32(d + 13);
    var par_n = le32(d + 17);
    var par_d = le32(d + 21);
    s.granulerate_n = @bitCast(le32(d + 25));
    s.granulerate_d = @bitCast(le32(d + 29));
    s.granuleshift = d[37];
    if (s.granuleshift >= 63) return badShift(s);
    if (s.granulerate_n == 0 or s.granulerate_d == 0) return badShift(s);
    s.is_video = 1;
    s.n_header_packets = 3;
    s.frame_size = 1;
    s.caps = c.gst_caps_new_empty_simple("video/x-daala");
    if (w > 0 and h > 0) c.gst_caps_set_simple(s.caps, "width", c.G_TYPE_INT, @as(c.gint, @bitCast(w)), "height", c.G_TYPE_INT, @as(c.gint, @bitCast(h)), @as(?*anyopaque, null));
    if (par_n == 0 or par_d == 0) {
        par_n = 1;
        par_d = 1;
    }
    c.gst_caps_set_simple(s.caps, "framerate", c.gst_fraction_get_type(), s.granulerate_n, s.granulerate_d, "pixel-aspect-ratio", c.gst_fraction_get_type(), @as(c.gint, @bitCast(par_n)), @as(c.gint, @bitCast(par_d)), @as(?*anyopaque, null));
    return true;
}

fn packetKeyDaala(_: *Stream, p: *Packet) bool {
    if (p.bytes == 0) return false;
    return p.packet[0] & 0x40 != 0;
}

fn tagsDaala(s: *Stream, p: *Packet) void {
    if (p.bytes > 0 and p.packet[0] == 0x81) {
        tagsFromComment(p, "\x81daala", &s.taglist);
        addTag(s, "video-codec", @as([*:0]const u8, "Daala"));
        if (s.bitrate != 0) addTag(s, "bitrate", @as(c.guint, @bitCast(s.bitrate)));
    }
}

const maps = [_]Map{
    .{ .id = "", .min = std.math.maxInt(i32), .media = null },
    .{ .id = "\x80theora", .min = 42, .media = "video/x-theora", .setup = setupTheora, .to_granule = toGranuleTheora, .to_granulepos = toGranuleposDefault, .is_key_gp = keyTheora, .is_key_packet = packetKeyTheora, .is_header = headerTheora, .duration = durationConstant, .tags = tagsTheora },
    .{ .id = "\x01vorbis", .min = 29, .media = "audio/x-vorbis", .setup = setupVorbis, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_key_gp = keyTrue, .is_key_packet = packetKeyTrue, .is_header = headerVorbis, .duration = durationVorbis, .tags = tagsVorbis },
    .{ .id = "Speex", .min = 80, .media = "audio/x-speex", .setup = setupSpeex, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_key_gp = keyTrue, .is_key_packet = packetKeyTrue, .is_header = headerCount, .duration = durationConstant, .tags = tagsCount },
    .{ .id = "PCM     ", .min = 28, .media = "audio/x-raw", .setup = setupPcm, .is_header = headerCount },
    .{ .id = "CMML\x00\x00\x00\x00", .min = 29, .media = "text/x-cmml", .setup = setupCmml, .is_header = headerCount },
    .{ .id = "Annodex", .min = 44, .media = "application/x-annodex", .setup = setupFishead, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_header = headerCount },
    .{ .id = "fishead", .min = 64, .media = "application/octet-stream", .setup = setupFishead, .is_header = headerTrue },
    .{ .id = "fLaC", .min = 0, .media = "audio/x-flac", .setup = setupFLaC, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_key_gp = keyTrue, .is_key_packet = packetKeyTrue, .is_header = headerFLaC, .duration = durationFlac },
    .{ .id = "\x7fFLAC", .min = 36, .media = "audio/x-flac", .setup = setupFlac, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_key_gp = keyTrue, .is_key_packet = packetKeyTrue, .is_header = headerFlac, .duration = durationFlac, .tags = tagsFlac },
    .{ .id = "AnxData", .min = 0, .media = "application/octet-stream" },
    .{ .id = "CELT    ", .min = 60, .media = "audio/x-celt", .setup = setupCelt, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_header = headerCount, .duration = durationConstant, .tags = tagsCount },
    .{ .id = "\x80kate\x00\x00\x00", .min = 64, .media = "text/x-kate", .setup = setupKate, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_header = headerCount, .duration = durationKate, .tags = tagsKate },
    .{ .id = "BBCD\x00", .min = 13, .media = "video/x-dirac", .setup = setupDirac, .to_granule = toGranuleDirac, .to_granulepos = toGranuleposDirac, .is_key_gp = keyDirac, .is_header = headerCount, .duration = durationConstant, .to_key_granule = toKeyGranuleDirac },
    .{ .id = "OVP80\x01\x01", .min = 26, .media = "video/x-vp8", .setup = setupVp8, .setup_caps = setupVp8Caps, .to_granule = toGranuleVp8, .to_granulepos = toGranuleposVp8, .is_key_gp = keyVp8, .is_key_packet = packetKeyVp8, .is_header = headerVp8, .duration = durationVp8, .to_key_granule = toKeyGranuleVp8, .tags = tagsVp8, .headers = headersVp8, .stats = statsVp8 },
    .{ .id = "OpusHead", .min = 19, .media = "audio/x-opus", .setup = setupOpus, .to_granule = toGranuleOpus, .to_granulepos = toGranuleposDefault, .is_key_packet = packetKeyTrue, .is_header = headerOpus, .duration = durationOpus, .tags = tagsOpus },
    .{ .id = "\x01audio\x00\x00\x00", .min = 53, .media = "application/x-ogm-audio", .setup = setupOgmAudio, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_key_gp = keyTrue, .is_key_packet = packetKeyTrue, .is_header = headerOgm, .duration = durationOgm },
    .{ .id = "\x01video\x00\x00\x00", .min = 53, .media = "application/x-ogm-video", .setup = setupOgmVideo, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_header = headerOgm, .duration = durationConstant },
    .{ .id = "\x01text\x00\x00\x00", .min = 25, .media = "application/x-ogm-text", .setup = setupOgmText, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_key_gp = keyTrue, .is_key_packet = packetKeyTrue, .is_header = headerOgm, .duration = durationOgm, .tags = tagsOgm },
    .{ .id = "\x80daala", .min = 42, .media = "video/x-daala", .setup = setupDaala, .to_granule = toGranuleDefault, .to_granulepos = toGranuleposDefault, .is_key_gp = keyTheoraLike, .is_key_packet = packetKeyDaala, .is_header = headerTheora, .duration = durationConstant, .tags = tagsDaala },
};

fn keyTheoraLike(s: *Stream, gp: i64) bool {
    return keyTheora(s, gp);
}

pub fn setupMap(s: *Stream, p: *Packet) bool {
    for (maps, 0..) |m, i| {
        if (p.bytes >= m.min and p.bytes >= @as(c_long, @intCast(m.id.len)) and std.mem.eql(u8, p.packet[0..m.id.len], m.id)) {
            const f = m.setup orelse continue;
            if (f(s, p)) {
                s.map = @intCast(i);
                return true;
            }
        }
    }
    return false;
}

pub fn setupMapFromCaps(s: *Stream, caps: [*c]const c.GstCaps) bool {
    if (caps == null) return false;
    const st = c.gst_caps_get_structure(caps, 0);
    for (maps, 0..) |m, i| {
        const f = m.setup_caps orelse continue;
        if (c.gst_structure_has_name(st, m.media.?) == 0) continue;
        if (f(s, caps)) {
            s.map = @intCast(i);
            return true;
        }
    }
    return false;
}

pub fn setupMapFromCapsHeaders(s: *Stream, caps: [*c]const c.GstCaps) bool {
    if (caps == null) return false;
    const st = c.gst_caps_get_structure(caps, 0);
    const sh = c.gst_structure_get_value(st, "streamheader");
    if (sh == null) return false;
    if (sh.*.g_type != c.gst_value_array_get_type()) return false;
    if (c.gst_value_array_get_size(sh) == 0) return false;
    const first = c.gst_value_array_get_value(sh, 0);
    if (first.*.g_type != c.gst_buffer_get_type()) return false;
    const buf = c.gst_value_get_buffer(first);
    if (buf == null) return false;
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buf, &map, c.GST_MAP_READ) == 0) return false;
    if (map.size == 0) {
        c.gst_buffer_unmap(buf, &map);
        return false;
    }
    var p = std.mem.zeroes(Packet);
    p.packet = map.data;
    p.bytes = @intCast(map.size);
    const r = setupMap(s, &p);
    c.gst_buffer_unmap(buf, &map);
    return r;
}

pub fn clear(s: *Stream) void {
    s.* = std.mem.zeroes(Stream);
}
