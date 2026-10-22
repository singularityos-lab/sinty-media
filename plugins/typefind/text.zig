const std = @import("std");
const s = @import("scan.zig");
const c = s.c;
const TF = s.TF;

fn validAt(tf: TF, off: u64, prob: *c.guint) bool {
    var size: c.guint = 32 * 1024;
    var p: c.guint = 95;
    while (p > 10 and size > 16) {
        if (s.peek(tf, @bitCast(off), size)) |d| {
            var end: [*c]const u8 = null;
            const start: [*c]const u8 = @ptrCast(d);
            if (c.g_utf8_validate(start, size, &end) != 0 or @as(i64, @intCast(@intFromPtr(end) - @intFromPtr(start))) + 4 > size) {
                prob.* = p;
                return true;
            }
            prob.* = 0;
            return false;
        }
        size /= 2;
        p -= 10;
    }
    prob.* = 0;
    return false;
}

pub fn utf8(tf: TF, _: ?*anyopaque) callconv(.c) void {
    if (xmlFirst(tf, "", true)) return;
    if (sdpHeader(tf)) return;
    var start: c.guint = 0;
    if (!validAt(tf, 0, &start)) return;
    const len = s.length(tf);
    if (len == 0 or len == std.math.maxInt(u64)) return s.suggest(tf, @min(start, s.POSSIBLE), s.caps("text/plain"));
    if (len < 64 * 1024) return s.suggest(tf, start, s.caps("text/plain"));
    var half: c.guint = 0;
    if (!validAt(tf, len / 2, &half)) return;
    s.suggest(tf, (start + half) / 2, s.caps("text/plain"));
}

const Endian = enum(c.gint) { little = 1234, big = 4321 };

fn utf16Ok(d: [*]const u8, len_in: usize, e: Endian) bool {
    var len = len_in;
    if (len & 1 != 0) return false;
    var p = d;
    while (len >= 2) {
        const high = if (e == .big) s.be16(p) else s.le16(p);
        p += 2;
        if (high >= 0xD800 and high <= 0xDBFF) {
            if (len < 4) return false;
            len -= 2;
            const low = if (e == .big) s.be16(p) else s.le16(p);
            p += 2;
            if (!(low >= 0xDC00 and low <= 0xDFFF)) return false;
        } else if (high >= 0xDC00 and high <= 0xDFFF) return false;
        len -= 2;
    }
    return true;
}

fn utf32Ok(d: [*]const u8, len_in: usize, e: Endian) bool {
    var len = len_in;
    if (len & 3 != 0) return false;
    var p = d;
    while (len > 3) {
        const v = if (e == .big) s.be32(p) else s.le32(p);
        if (v >= 0x10FFFF) return false;
        p += 4;
        len -= 4;
    }
    return true;
}

const Tester = struct { bom: []const u8, check: *const fn ([*]const u8, usize, Endian) bool, boost: c.gint, e: Endian };

fn unicode(tf: TF, testers: []const Tester, comptime media: [:0]const u8) void {
    var len: usize = 4;
    var data = s.peek(tf, 0, 4) orelse blk: {
        len = 2;
        break :blk s.peek(tf, 0, 2) orelse return;
    };
    while (len < 256 * 1024) {
        const nl = len << 1;
        data = s.peek(tf, 0, @intCast(nl)) orelse break;
        len = nl;
    }
    var prob: c.gint = -1;
    var endian: c.gint = 0;
    for (testers) |t| {
        var boost: c.gint = 0;
        if (len >= t.bom.len and std.mem.eql(u8, data[0..t.bom.len], t.bom)) boost = t.boost;
        if (boost == 0) continue;
        if (!t.check(data, len, t.e)) continue;
        const tmp = @as(c.gint, s.POSSIBLE) - 20 + boost;
        if (tmp > prob) {
            prob = tmp;
            endian = @intFromEnum(t.e);
        }
    }
    if (prob > 0) c.gst_type_find_suggest_simple(tf, @intCast(prob), media, "endianness", c.G_TYPE_INT, endian, @as(?*anyopaque, null));
}

pub fn utf16(tf: TF, _: ?*anyopaque) callconv(.c) void {
    unicode(tf, &.{ .{ .bom = "\xff\xfe", .check = utf16Ok, .boost = 10, .e = .little }, .{ .bom = "\xfe\xff", .check = utf16Ok, .boost = 20, .e = .big } }, "text/utf-16");
}

pub fn utf32(tf: TF, _: ?*anyopaque) callconv(.c) void {
    unicode(tf, &.{ .{ .bom = "\xff\xfe\x00\x00", .check = utf32Ok, .boost = 10, .e = .little }, .{ .bom = "\x00\x00\xfe\xff", .check = utf32Ok, .boost = 20, .e = .big } }, "text/utf-32");
}

const Cursor = struct {
    tf: TF,
    data: [*]const u8,
    pos: c.guint = 0,
    offset: c.guint = 0,

    fn next(k: *Cursor) bool {
        k.pos += 1;
        if (k.pos == 16) {
            k.pos = 0;
            k.offset += 16;
            k.data = s.peek(k.tf, k.offset, 16) orelse return false;
        } else k.data += 1;
        return true;
    }
};

pub fn uri(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = Cursor{ .tf = tf, .data = s.peek(tf, 0, 16) orelse return };
    while (k.data[0] == '#') {
        while (k.data[0] != '\n') {
            if (!k.next()) return;
        }
        if (!k.next()) return;
    }
    if (!s.isAlpha(k.data[0])) return;
    if (!k.next()) return;
    while (s.isAlnum(k.data[0])) {
        if (!k.next()) return;
    }
    if (k.data[0] != ':') return;
    const d = s.peek(tf, k.offset + k.pos, 3) orelse return;
    if (d[1] != '/' and d[2] != '/') return;
    s.suggest(tf, s.LIKELY, s.caps("text/uri-list"));
}

pub fn itc(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    if (!k.ensure(tf, 8)) return;
    if (!s.eq(k.data, "\x00\x00\x01\x1Citch")) return;
    var prob = s.MINIMUM;
    defer s.suggest(tf, prob, s.caps("application/itc"));
    k.advance(8);
    if (!k.ensure(tf, 12)) return;
    for (0..3) |_| {
        if (!s.eq(k.data, "\x00\x00\x00\x02")) return;
        k.advance(4);
    }
    prob = s.POSSIBLE;
    if (!k.ensure(tf, 8)) return;
    if (!s.eq(k.data, "\x00\x00\x00\x00artw")) return;
    prob = s.LIKELY;
    k.advance(8);
    if (!k.ensure(tf, 256)) return;
    for (k.data[0..256]) |b| {
        if (b != 0) return;
    }
    prob = s.NEARLY_CERTAIN;
    k.advance(256);
    if (!k.ensure(tf, 8)) return;
    if (!s.eq(k.data + 4, "item")) return;
    prob = s.MAXIMUM;
}

pub fn hls(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    if (!k.ensure(tf, 30)) return;
    if (!s.eq(k.data, "#EXTM3U")) return;
    k.advance(7);
    while (k.offset < 4096) {
        if (!k.ensure(tf, 21)) return;
        if (k.data[0] == '#' and (s.eq(k.data, "#EXT-X-TARGETDURATION") or s.eq(k.data, "#EXT-X-STREAM-INF") or s.eq(k.data, "#EXT-X-MEDIA"))) {
            return s.suggest(tf, s.MAXIMUM, s.caps("application/x-hls"));
        }
        k.advance(1);
    }
}

pub fn xmlFromData(d_in: [*]const u8, len_in: c.guint, element: []const u8, strict: bool) bool {
    var d = d_in;
    var len = len_in;
    var i = s.find(d, len, '<') orelse return false;
    len -= @intCast(i);
    d += i;
    if (len < 5) return false;
    var xmldec = s.eq(d, "<?xml");
    if (xmldec) {
        d += 5;
        len -= 5;
        i = s.find(d, len, '?') orelse return false;
        len -= @intCast(i);
        d += i;
        if (len < 2) return false;
        xmldec = s.eq(d, "?>");
        if (!xmldec) return false;
        d += 2;
        len -= 2;
    }
    if (strict and !xmldec) return false;
    if (xmldec) {
        i = s.find(d, len, '<') orelse return false;
        len -= @intCast(i);
        d += i;
    }
    while (len >= 4 and s.eq(d, "<!--")) {
        d += 4;
        len -= 4;
        const e: [*]const u8 = @ptrCast(c.g_strstr_len(@ptrCast(d), len, "-->") orelse return false);
        const n: c.guint = @intCast(@intFromPtr(e + 3) - @intFromPtr(d));
        len -= n;
        d += n;
        i = s.find(d, len, '<') orelse return false;
        len -= @intCast(i);
        d += i;
    }
    if (element.len == 0) return true;
    if (len < element.len + 1) return false;
    d += 1;
    len -= 1;
    if (!std.mem.eql(u8, d[0..element.len], element)) return false;
    d += element.len;
    len -= @intCast(element.len);
    const close = s.find(d, len, '>') orelse return false;
    for (d[0..close]) |b| {
        if (b == '>' or b == '=') return true;
        if (!s.isPrint(b) and b != '\n' and b != '\r') return false;
    }
    return false;
}

pub fn xmlFirst(tf: TF, element: []const u8, strict: bool) bool {
    var len: c.guint = @truncate(s.length(tf));
    var data: ?[*]const u8 = null;
    if (len == 0) {
        len = 4096;
        while (true) {
            data = s.peek(tf, 0, len);
            if (data != null or len < 512) break;
            len /= 2;
        }
    } else if (len < 32) {
        return false;
    } else {
        len = @min(4096, len);
        data = s.peek(tf, 0, len);
    }
    return xmlFromData(data orelse return false, len, element, strict);
}

fn xmlSuggest(tf: TF, comptime el: []const u8, prob: c.guint, comptime caps: [:0]const u8) void {
    if (xmlFirst(tf, el, false)) s.suggest(tf, prob, s.caps(caps));
}

pub fn xml(tf: TF, _: ?*anyopaque) callconv(.c) void {
    if (xmlFirst(tf, "", true)) s.suggest(tf, s.MINIMUM, s.caps("application/xml"));
}

pub fn dash(tf: TF, _: ?*anyopaque) callconv(.c) void {
    if (xmlFirst(tf, "MPD", false) or xmlFirst(tf, "mpd", false)) s.suggest(tf, s.MAXIMUM, s.caps("application/dash+xml"));
}

pub fn xges(tf: TF, _: ?*anyopaque) callconv(.c) void {
    xmlSuggest(tf, "ges", s.MAXIMUM, "application/xges");
}

pub fn fcpxml(tf: TF, _: ?*anyopaque) callconv(.c) void {
    xmlSuggest(tf, "fcp", s.MAXIMUM, "application/vnd.apple-fcp+xml");
}

pub fn xmeml(tf: TF, _: ?*anyopaque) callconv(.c) void {
    xmlSuggest(tf, "xme", s.MAXIMUM, "application/vnd.apple-xmeml+xml");
}

pub fn smil(tf: TF, _: ?*anyopaque) callconv(.c) void {
    xmlSuggest(tf, "smil", s.MAXIMUM, "application/smil");
}

pub fn ttml(tf: TF, _: ?*anyopaque) callconv(.c) void {
    xmlSuggest(tf, "tt", s.MAXIMUM, "application/ttml+xml");
}

pub fn otio(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var d = s.peek(tf, 0, 30) orelse return;
    var i = s.find(d, 30, '{') orelse return;
    d = s.peek(tf, @intCast(i), 30) orelse return;
    i = s.find(d, 30, '"') orelse return;
    d = s.peek(tf, @intCast(i), 14) orelse return;
    if (s.eq(d, "\"OTIO_SCHEMA\":")) s.suggest(tf, s.MAXIMUM, s.caps("application/vnd.pixar.opentimelineio+json"));
}

pub fn sdpHeader(tf: TF) bool {
    const d = s.peek(tf, 0, 5) orelse return false;
    if (!s.eq(d, "v=0")) return false;
    return (d[3] == '\r' and d[4] == '\n') or d[3] == '\n';
}

pub fn sdp(tf: TF, _: ?*anyopaque) callconv(.c) void {
    if (sdpHeader(tf)) s.suggest(tf, s.MAXIMUM, s.caps("application/sdp"));
}

pub fn html(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 16) orelse return;
    if (s.caseEq(d, "<!DOCTYPE HTML")) return s.suggest(tf, s.MAXIMUM, s.caps("text/html"));
    if (xmlFirst(tf, "html", false)) return s.suggest(tf, s.MAXIMUM, s.caps("text/html"));
    if (s.find(d, 16, '<')) |i| {
        const h = s.peek(tf, @intCast(i), 6) orelse return;
        if (s.caseEq(h, "<html>")) s.suggest(tf, s.MAXIMUM, s.caps("text/html"));
    }
}

pub fn mid(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 4) orelse return;
    if (s.eq(d, "MThd")) s.suggest(tf, s.MAXIMUM, s.caps("audio/midi"));
}

pub fn mxmf(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var d = s.peek(tf, 0, 4) orelse return;
    if (!s.eq(d, "XMF_")) return;
    d = s.peek(tf, 4, 4) orelse return;
    if (!s.eq(d, "2.00")) return;
    d = s.peek(tf, 11, 1) orelse return;
    if (d[0] == 2) s.suggest(tf, s.MAXIMUM, s.caps("audio/mobile-xmf"));
}

fn flxMagic(d: [*]const u8) bool {
    return (d[4] == 0x11 or d[4] == 0x12 or d[4] == 0x30 or d[4] == 0x44) and d[5] == 0xaf;
}

pub fn flx(tf: TF, _: ?*anyopaque) callconv(.c) void {
    if (s.peek(tf, 0, 134)) |d| {
        if (flxMagic(d) and (d[132] == 0x00 or d[132] == 0xfa) and d[133] == 0xf1) s.suggest(tf, s.MAXIMUM, s.caps("video/x-fli"));
        return;
    }
    const d = s.peek(tf, 0, 6) orelse return;
    if (flxMagic(d)) s.suggest(tf, s.LIKELY, s.caps("video/x-fli"));
}

pub fn id3v2(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 10) orelse return;
    if (s.eq(d, "ID3") and d[3] != 0xFF and d[4] != 0xFF and (d[6] | d[7] | d[8] | d[9]) & 0x80 == 0) s.suggest(tf, s.MAXIMUM, s.caps("application/x-id3"));
}

pub fn id3v1(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, -128, 3) orelse return;
    if (s.eq(d, "TAG")) s.suggest(tf, s.MAXIMUM, s.caps("application/x-id3"));
}

pub fn apetag(tf: TF, _: ?*anyopaque) callconv(.c) void {
    if (s.peek(tf, 0, 8)) |d| {
        if (s.eq(d, "APETAGEX")) return s.suggest(tf, s.MAXIMUM, s.caps("application/x-apetag"));
    }
    if (s.peek(tf, -32, 8)) |d| {
        if (s.eq(d, "APETAGEX")) s.suggest(tf, s.MAXIMUM, s.caps("application/x-apetag"));
    }
}

pub fn tta(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 3) orelse return;
    if (s.eq(d, "TTA")) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-ttafile"));
}

pub fn flac(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    if (!k.ensure(tf, 4)) return;
    if (s.eq(k.data, "fLaC")) return s.suggest(tf, s.MAXIMUM, s.caps("audio/x-flac"));
    if (!k.ensure(tf, 6)) return;
    if (s.eq(k.data, "\x7fFLAC\x01")) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-flac"));
}
