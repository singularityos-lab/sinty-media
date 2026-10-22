const std = @import("std");
const s = @import("scan.zig");
const text = @import("text.zig");
const c = s.c;
const TF = s.TF;
const N: ?*anyopaque = null;
const FILE = "../gst/typefind/gsttypefindfunctions.c";

fn form(tf: TF, comptime a: []const u8, comptime b: []const u8, comptime caps: [:0]const u8) void {
    const d = s.peek(tf, 0, 16) orelse return;
    if (!s.eq(d, "FORM")) return;
    if (s.eq(d + 8, a) or s.eq(d + 8, b)) s.suggest(tf, s.MAXIMUM, s.caps(caps));
}

pub fn aiff(tf: TF, _: ?*anyopaque) callconv(.c) void {
    form(tf, "AIFF", "AIFC", "audio/x-aiff");
}

pub fn svx(tf: TF, _: ?*anyopaque) callconv(.c) void {
    form(tf, "8SVX", "16SV", "audio/x-svx");
}

pub fn shn(tf: TF, _: ?*anyopaque) callconv(.c) void {
    if (s.peek(tf, 0, 4)) |d| {
        if (s.eq(d, "ajkg")) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-shorten"));
    }
    if (s.peek(tf, -8, 8)) |d| {
        if (s.eq(d, "SHNAMPSK")) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-shorten"));
    }
}

pub fn ape(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 4) orelse return;
    if (s.eq(d, "MAC ")) s.suggest(tf, s.LIKELY + 10, s.caps("application/x-ape"));
}

pub fn m4a(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 4, 8) orelse return;
    if (s.eq(d, "ftypM4A ")) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-m4a"));
}

fn profile3gp(d: [*]const u8) ?[*:0]const u8 {
    if (d[0] != '3' or d[1] != 'g') return null;
    return switch (d[2]) {
        'g' => "general",
        'p' => "basic",
        's' => "streaming-server",
        'r' => "progressive-download",
        else => null,
    };
}

fn suggest3gp(tf: TF, p: [*:0]const u8) void {
    c.gst_type_find_suggest_simple(tf, s.MAXIMUM, "application/x-3gp", "profile", c.G_TYPE_STRING, p, N);
}

pub fn q3gp(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 12) orelse return;
    if (!s.eq(d + 4, "ftyp")) return;
    if (profile3gp(d + 8)) |p| return suggest3gp(tf, p);
    var size: u32 = 0;
    if (s.peek(tf, 0, 4)) |h| size = s.be32(h);
    const all = s.peek(tf, 0, size) orelse return;
    var off: u32 = 16;
    while (off +% 4 < size) : (off += 4) {
        if (profile3gp(all + off)) |p| return suggest3gp(tf, p);
    }
}

pub fn jp2(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 24) orelse return;
    if (!s.eq(d, "\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a")) return;
    if (!s.eq(d + 16, "ftyp")) return;
    if (s.eq(d + 20, "jp2 ")) {
        s.suggest(tf, s.MAXIMUM, s.caps("image/jp2"));
    } else if (s.eq(d + 20, "mjp2")) s.suggest(tf, s.MAXIMUM, s.caps("video/mj2"));
}

pub fn jpc(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var cod = false;
    var qcd = false;
    var sot = false;
    const d0 = s.peek(tf, 0, 4) orelse return;
    if (!s.eq(d0, "\xff\x4f\xff\x51")) return;
    var off: c.gint = 4;
    while (!sot) {
        off +%= s.be16(s.peek(tf, off, 2) orelse return);
        const m = s.be16(s.peek(tf, off, 2) orelse return);
        switch (m) {
            0xFF90 => sot = true,
            0xFF52 => cod = true,
            0xFF5C => qcd = true,
            0xFF53, 0xFF5E, 0xFF5D, 0xFF5F, 0xFF57, 0xFF60, 0xFF55, 0xFF63, 0xFF64, 0xFF78, 0xFF75, 0xFF74, 0xFF77 => {},
            else => return,
        }
        off +%= 2;
    }
    if (cod and qcd and sot) s.suggest(tf, s.MAXIMUM, s.caps("image/x-jpc"));
}

const cmaf = [_]*const [4]u8{ "cmf2", "cmfc", "cfsd", "cfhd", "chdf", "caac", "caaa", "ccea", "chhd", "chh1", "cud8", "cud1", "chd1", "clg1" };
const iso = [_]*const [4]u8{ "isom", "avc1", "iso3", "iso4", "iso5", "iso6", "iso7", "iso8", "iso9", "isoa", "isob", "mp42", "mp41" };
const isofrag = [_]*const [4]u8{ "isml", "dash", "hlsf", "avc3" };

fn brand(b: [*]const u8, list: []const *const [4]u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, b[0..4], x)) return true;
    }
    return false;
}

const atoms = [_]*const [4]u8{ "moov", "mdat", "ftyp", "free", "uuid", "udta", "styp", "sidx", "ssix", "prft", "emsg", "moof", "mfra", "pdin", "meta", "skip" };

pub fn qt(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var tip: c.guint = 0;
    var row: c.guint = 0;
    var moov = false;
    var mdat = false;
    var offset: u64 = 0;
    var variant: ?[*:0]const u8 = null;
    scan: while (s.peek(tf, @bitCast(offset), 12)) |d| {
        const tag = d + 4;
        if (s.eq(tag, "ftyp")) {
            const b = d + 8;
            if (s.eq(b, "qt  ")) {
                tip = s.MAXIMUM;
                break;
            }
            const v: ?[*:0]const u8 = if (brand(b, &cmaf)) "cmaf" else if (brand(b, &iso)) "iso" else if (brand(b, &isofrag)) "iso-fragmented" else if (s.eq(b, "ccff")) "ccff" else if (s.eq(b, "mif1")) "heif" else null;
            if (v) |x| {
                tip = s.MAXIMUM;
                variant = x;
                break;
            }
        }
        if (brand(tag, &atoms)) {
            tip = if (tip == 0) s.LIKELY else s.NEARLY_CERTAIN;
            if (s.eq(tag, "moov")) moov = true;
            if (s.eq(tag, "mdat")) mdat = true;
            row += 1;
            if ((moov and mdat) or row >= 5) {
                tip = s.MAXIMUM;
                break;
            }
        } else if (s.eq(tag, "pnot") or s.eq(tag, "PICT") or s.eq(tag, "wide") or s.eq(tag, "prfl")) {
            tip = s.MAXIMUM;
            break;
        } else {
            tip = if (row >= 3) s.LIKELY else 0;
            break;
        }
        var size: u64 = s.be32(d);
        if (size +% offset >= std.math.maxInt(i64)) break;
        if (s.eq(tag, "ftyp") and size >= 16) {
            const all = s.peek(tf, @bitCast(offset), @truncate(size)) orelse break :scan;
            var n: u64 = 12;
            while (n + 4 <= size) : (n += 4) {
                const b = all + n;
                const v: ?[*:0]const u8 = if (brand(b, &cmaf)) "cmaf" else if (brand(b, &iso)) "iso" else if (brand(b, &isofrag)) "iso-fragmented" else if (s.eq(b, "mif1")) "heif" else null;
                if (v) |x| {
                    tip = s.MAXIMUM;
                    variant = x;
                    break :scan;
                }
            }
        }
        if (size == 1) {
            const sd = s.peek(tf, @bitCast(offset +% 8), 8) orelse break;
            size = s.be64(sd);
        } else if (size < 8) break;
        const next = offset +% size;
        if (next <= offset) break;
        if (next +% 16 >= std.math.maxInt(i64)) break;
        offset = next;
    }
    if (tip == 0) return;
    if (variant) |v| {
        const caps = c.gst_caps_copy(s.caps("video/quicktime"));
        c.gst_caps_set_simple(caps, "variant", c.G_TYPE_STRING, v, N);
        s.suggest(tf, tip, caps);
        c.gst_mini_object_unref(@ptrCast(caps));
    } else s.suggest(tf, tip, s.caps("video/quicktime"));
}

pub fn qtif(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var idsc = false;
    var idat = false;
    var offset: u64 = 0;
    var rounds: c.guint = 0;
    while (s.peek(tf, @bitCast(offset), 8)) |d| {
        var size: u64 = s.be32(d);
        if (size == 1) {
            const sd = s.peek(tf, @bitCast(offset +% 8), 8) orelse break;
            size = s.be64(sd);
        }
        if (size < 8) break;
        if (s.eq(d + 4, "idsc")) idsc = true;
        if (s.eq(d + 4, "idat")) idat = true;
        if (idsc and idat) return s.suggest(tf, s.MAXIMUM, s.caps("image/x-quicktime"));
        offset +%= size;
        if (offset +% 8 >= std.math.maxInt(i64)) break;
        rounds += 1;
        if (rounds > 25) break;
    }
    if (idsc or idat) s.suggest(tf, s.LIKELY, s.caps("image/x-quicktime"));
}

fn modType(tf: TF) ?struct { [*:0]const u8, c.guint } {
    const dg = s.isDigit;
    const MAX = s.MAXIMUM;
    if (s.peek(tf, 1080, 4)) |d| {
        if (s.eq(d, "M.K.") or s.eq(d, "M!K!") or s.eq(d, "M&K!") or s.eq(d, "N.T.") or (s.eq(d, "FLT") and dg(d[3])) or (s.eq(d, "EXO") and dg(d[3])) or s.eq(d, "OKTA") or s.eq(d, "OCTA") or s.eq(d, "CD81") or (s.eq(d, "TDZ") and dg(d[3])) or (s.eq(d + 1, "CHN") and dg(d[0])) or (s.eq(d + 2, "CH") and dg(d[0]) and dg(d[1])) or (s.eq(d + 2, "CN") and dg(d[0]) and dg(d[1]))) return .{ "mod", MAX };
    }
    if (s.peek(tf, 0, 8)) |d| {
        if (s.eq(d, "MUSE") and (s.eq(d + 6, "\xBE\xEF") or s.eq(d + 6, "\xBA\xBE"))) return .{ "j2b", MAX };
    }
    if (s.peek(tf, 0, 7)) |d| {
        if (s.eq(d, "AMShdr\x1A")) return .{ "velvet-ams", MAX };
    }
    if (s.peek(tf, 0, 9)) |d| {
        if (s.eq(d, "Extreme") and d[8] == 1) return .{ "extreme-ams", s.LIKELY };
    }
    if (s.peek(tf, 0, 14)) |d| {
        if (s.eq(d, "MAS_UTrack_V00")) return .{ "ult", MAX };
    }
    if (s.peek(tf, 0, 20)) |d| {
        if (s.eq(d, "DIGI Booster module\x00")) return .{ "digi", MAX };
    }
    if (s.peek(tf, 0x2C, 4)) |d| {
        if (s.eq(d, "PTMF")) return .{ "ptm", s.LIKELY };
    }
    var data = s.peek(tf, 0, 38);
    if (data) |d| {
        if (s.eq(d, "Extended Module: ") and d[37] == 0x1A) return .{ "xm", MAX };
    }
    if (data == null) data = s.peek(tf, 0, 8);
    if (data) |d| {
        if (s.eq(d, "OKTASONG")) return .{ "okt", MAX };
    }
    if (data == null) data = s.peek(tf, 0, 4);
    if (data) |d| {
        if (s.eq(d, "PSM") and (d[3] == ' ' or d[3] == 254)) return .{ "psm", MAX };
        if (s.eq(d, "if") or s.eq(d, "JN")) return .{ "669", s.LIKELY };
        if (s.eq(d, "AMF") and d[3] > 10 and d[3] < 14) return .{ "dsmi-amf", MAX };
        if (s.eq(d, "IMPM")) return .{ "it", MAX };
        if (s.eq(d, "DBM0")) return .{ "dbm", MAX };
        if (s.eq(d, "DMDL")) return .{ "mdl", MAX };
        if (s.eq(d, "MT20")) return .{ "mt2", MAX };
        if (s.eq(d, "DDMF")) return .{ "dmf", MAX };
        if (s.eq(d, "MMD0") or s.eq(d, "MMD1")) return .{ "med", MAX };
        if (s.eq(d, "MTM")) return .{ "mtm", MAX };
        if (s.eq(d, "RIFF")) {
            if (s.peek(tf, 8, 4)) |e| {
                if (s.eq(e, "DSMF")) return .{ "dsm", MAX };
            }
        }
        if (s.eq(d, "FAR\xFE")) return .{ "far", MAX };
        if (s.eq(d, "FAM\xFE")) {
            if (s.peek(tf, 44, 3)) |e| {
                if (s.eq(e, "com")) return .{ "fam", MAX };
            } else return .{ "fam", s.LIKELY };
        }
        if (s.eq(d, "GDM\xFE")) {
            if (s.peek(tf, 71, 4)) |e| {
                if (s.eq(e, "GMFS")) return .{ "gdm", MAX };
            } else return .{ "gdm", s.LIKELY };
        }
        if (s.eq(d, "\xC1\x83\x2A\x9E")) return .{ "umx", s.POSSIBLE };
    }
    if (s.peek(tf, 44, 3)) |d| {
        if (s.eq(d, "\x0D\x0A\x1A")) return .{ "far", s.POSSIBLE };
    }
    if (s.peek(tf, 60, 4)) |d| {
        if (s.eq(d, "IM10")) return .{ "imf", MAX };
    }
    if (s.peek(tf, 44, 4)) |d| {
        if (s.eq(d, "SCRM")) return .{ "s3m", MAX };
    }
    if (s.peek(tf, 20, 8)) |d| {
        if (s.caseEq(d, "!Scream!") or s.caseEq(d, "BMOD2STM")) {
            const id = s.peek(tf, 28, 1) orelse return null;
            const st = s.peek(tf, 29, 1) orelse return null;
            if (id[0] == 0x1A and st[0] == 2) return .{ "stm", MAX };
        }
    }
    if (s.peek(tf, 0, 19)) |d| {
        if (s.eq(d, "ASYLUM Music Format")) return .{ "asylum-amf", MAX };
    }
    return null;
}

pub fn mod(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const t = modType(tf) orelse return;
    const caps = c.gst_caps_new_simple("audio/x-mod", "type", c.G_TYPE_STRING, t[0], N);
    s.suggest(tf, t[1], caps);
    c.gst_mini_object_unref(@ptrCast(caps));
}

pub fn swf(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 4) orelse return;
    if ((d[0] == 'F' or d[0] == 'C') and d[1] == 'W' and d[2] == 'S') s.suggest(tf, s.MAXIMUM, s.caps("application/x-shockwave-flash"));
}

pub fn mss(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const caps = "application/vnd.ms-sstr+xml";
    if (text.xmlFirst(tf, "SmoothStreamingMedia", true)) return s.suggest(tf, s.MAXIMUM, s.caps(caps));
    var len: c.guint = @truncate(s.length(tf));
    const h = s.peek(tf, 0, 3) orelse return;
    var bom = false;
    var big = false;
    if (h[0] == 0xEF and h[1] == 0xBB and h[2] == 0xBF) {
        bom = true;
    } else if (h[0] == 0xFF and h[1] == 0xFE) {
        big = false;
    } else if (h[0] == 0xFE and h[1] == 0xFF) {
        big = true;
    } else return;
    if (len == 0) {
        len = 512;
    } else if (len < 64) {
        return;
    } else len = @min(1024, len);
    var d = s.peek(tf, 0, len) orelse return;
    d += 2;
    len -= 2;
    if (bom) {
        if (text.xmlFromData(d + 1, len - 1, "SmoothStreamingMedia", true)) s.suggest(tf, s.MAXIMUM, s.caps(caps));
        return;
    }
    len &= ~@as(c.guint, 1);
    var u: [512]u16 = undefined;
    for (0..len / 2) |i| u[i] = if (big) s.be16(d + 2 * i) else s.le16(d + 2 * i);
    var nread: c.glong = 0;
    var size: c.glong = 0;
    const utf8 = c.g_utf16_to_utf8(&u, @intCast(len / 2), &nread, &size, null);
    defer c.g_free(utf8);
    if (utf8 != null and nread > 0) {
        if (text.xmlFromData(@ptrCast(utf8), @intCast(size), "SmoothStreamingMedia", true)) s.suggest(tf, s.MAXIMUM, s.caps(caps));
    }
}

pub fn jpeg(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var prob = s.POSSIBLE;
    var k = s.Scan{};
    if (!k.ensure(tf, 2)) return;
    if (k.data[0] != 0xff or k.data[1] != 0xd8) return;
    var markers: c.guint = 1;
    k.advance(2);
    const caps = c.gst_caps_copy(s.caps("image/jpeg"));
    while (k.ensure(tf, 4) and k.offset < 200 * 1024) {
        if (k.data[0] != 0xff) break;
        const m = k.data[1];
        if (m == 0xff) {
            k.advance(1);
            continue;
        }
        k.advance(2);
        const len = s.be16(k.data);
        if (!k.ensure(tf, len)) break;
        if (m == 0xc4 or m == 0xcc or m == 0xdb or m == 0xdd or m == 0xfe) {
            k.advance(len);
            markers += 1;
        } else if (m == 0xe0 and len >= 6 and k.memcmp(tf, 2, "JFIF")) {
            prob = s.MAXIMUM;
            k.advance(len);
            markers += 1;
        } else if (m == 0xe1 and len >= 6 and k.memcmp(tf, 2, "Exif")) {
            prob = s.MAXIMUM;
            k.advance(len);
            markers += 1;
        } else if (m >= 0xe0 and m <= 0xef) {
            k.advance(len);
            markers += 1;
        } else if (m >= 0xc0 and m <= 0xcf and m != 0xc4 and m != 0xc8 and m != 0xcc and len >= 10) {
            const h: c.gint = s.be16(k.data + 3);
            const w: c.gint = s.be16(k.data + 5);
            if (h == 0 or w == 0) break;
            prob = if (markers >= 5 or prob == s.MAXIMUM) s.MAXIMUM else s.LIKELY;
            c.gst_caps_set_simple(caps, "width", c.G_TYPE_INT, w, "height", c.G_TYPE_INT, h, "sof-marker", c.G_TYPE_INT, @as(c.gint, m & 0xf), N);
            break;
        } else break;
    }
    s.suggest(tf, prob, caps);
    c.gst_mini_object_unref(@ptrCast(caps));
}

pub fn bmp(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    if (!k.ensure(tf, 54)) return;
    if (k.data[0] != 'B' or k.data[1] != 'M') return;
    k.advance(6);
    if (s.le32(k.data) != 0) return;
    k.advance(4);
    if (s.le32(k.data) > 10 * 1024 * 1024) return;
    const st = s.le32(k.data + 4);
    k.advance(8);
    var w: u32 = 0;
    var h: u32 = 0;
    var planes: u32 = 0;
    var bpp: u32 = 0;
    if (st == 0x0C) {
        w = s.le16(k.data);
        h = s.le16(k.data + 2);
        planes = s.le16(k.data + 4);
        bpp = s.le16(k.data + 6);
    } else if (st == 40 or st == 64 or st == 108 or st == 124 or st == 0xF0) {
        w = s.le32(k.data);
        h = s.le32(k.data + 4);
        planes = s.le16(k.data + 8);
        bpp = s.le16(k.data + 10);
    } else return;
    if (w == 0 or w > 0xfffff or h == 0 or h > 0xfffff or planes != 1 or !(bpp == 1 or bpp == 4 or bpp == 8 or bpp == 16 or bpp == 24 or bpp == 32)) return;
    c.gst_type_find_suggest_simple(tf, s.MAXIMUM, "image/bmp", "width", c.G_TYPE_INT, w, "height", c.G_TYPE_INT, h, "bpp", c.G_TYPE_INT, bpp, N);
}

pub fn tiff(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 8) orelse return;
    if (s.eq(d, "II\x2a\x00")) {
        s.suggest(tf, s.MAXIMUM, s.caps("image/tiff, endianness = (int) LITTLE_ENDIAN"));
    } else if (s.eq(d, "MM\x00\x2a")) s.suggest(tf, s.MAXIMUM, s.caps("image/tiff, endianness = (int) BIG_ENDIAN"));
}

pub fn exr(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 8) orelse return;
    if (s.le32(d) != 0x01312f76) return;
    const flags = s.le32(d + 4);
    if (flags & 0xff != 1 and flags & 0xff != 2) return;
    if (flags & 0x200 != 0 and flags & 0x1800 != 0) return;
    s.suggest(tf, s.MAXIMUM, s.caps("image/x-exr"));
}

fn pnmSpace(b: u8) bool {
    return b == ' ' or b == '\r' or b == '\n' or b == 't';
}

pub fn pnm(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    if (!k.ensure(tf, 16)) return;
    if (k.data[0] != 'P' or k.data[1] < '1' or k.data[1] > '7' or !pnmSpace(k.data[2])) return;
    const media: [*:0]const u8 = switch (k.data[1]) {
        '1', '4' => "image/x-portable-bitmap",
        '2', '5' => "image/x-portable-graymap",
        '3', '6' => "image/x-portable-pixmap",
        else => "image/x-portable-anymap",
    };
    var w: c.guint = 0;
    var h: c.guint = 0;
    if (k.data[1] != '7') {
        k.advance(3);
        if (!k.ensure(tf, 1)) return;
        while (k.data[0] == '#') {
            k.advance(1);
            if (!k.ensure(tf, 1)) return;
            while (k.data[0] != '\n' and k.data[0] != '\r') {
                k.advance(1);
                if (!k.ensure(tf, 1)) return;
            }
            k.advance(1);
            if (!k.ensure(tf, 1)) return;
        }
        if (!k.ensure(tf, 32) and !k.ensure(tf, 4)) return;
        var buf = std.mem.zeroes([64]u8);
        const n = @min(63, k.size);
        @memcpy(buf[0..n], k.data[0..n]);
        var s1: u8 = 0;
        var s2: u8 = 0;
        if (!(c.sscanf(&buf, "%u%c%u%c", &w, &s1, &h, &s2) == 4 and pnmSpace(s1) and pnmSpace(s2) and w > 0 and w < std.math.maxInt(c.gint) and h > 0 and h < std.math.maxInt(c.gint))) {
            w = 0;
            h = 0;
        }
    }
    if (w > 0 and h > 0) {
        c.gst_type_find_suggest_simple(tf, s.MAXIMUM, media, "width", c.G_TYPE_INT, w, "height", c.G_TYPE_INT, h, N);
    } else c.gst_type_find_suggest_empty_simple(tf, s.LIKELY, media);
}

pub fn sds(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 4) orelse return;
    if (d[0] == 0xF0 and d[1] == 0x7E and d[2] & 0x80 == 0 and d[3] == 0x01) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-sds"));
}

pub fn ircam(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 4) orelse return;
    if (d[0] == 0x64 and d[1] == 0xA3 and d[2] & 0xF8 == 0 and d[3] == 0) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-ircam"));
}

const Mkv = struct { doctype: u8 = 0, audio: c.guint = 0, video: c.guint = 0, other: c.guint = 0, stereo: c.guint = 0, chunks: c.guint = 0, tracks_ok: bool = false };

const SEGMENT: u32 = 0x18538067;

fn ebmlHeader(tf: TF, k: *s.Scan, max_in: c.guint, id: *u32, size: *u64) c.guint {
    _ = tf;
    var max = max_in;
    if (k.size < 12 or max < 1) return 0;
    const b = k.data[0];
    const idl: c.guint = if (b & 0x80 == 0x80) 1 else if (b & 0xC0 == 0x40) 2 else if (b & 0xE0 == 0x20) 3 else if (b & 0xF0 == 0x10) 4 else return 0;
    if (max < idl) return 0;
    id.* = b;
    var i: c.guint = 1;
    while (i < idl) : (i += 1) id.* = (id.* << 8) | k.data[i];
    k.advance(idl);
    max -= idl;
    if (max < 1 or k.data[0] == 0) return 0;
    const msb: u6 = @intCast(7 - @clz(k.data[0]));
    var mask: u64 = (@as(u64, 1) << msb) - 1;
    size.* = k.data[0] & mask;
    const len: c.guint = 7 - @as(c.guint, msb);
    if (max < 1 + len) return 0;
    i = 0;
    while (i < len) : (i += 1) {
        mask = (mask << 8) | 0xff;
        size.* = (size.* << 8) | k.data[1 + i];
    }
    k.advance(1 + len);
    if (size.* == mask) {
        if (id.* == SEGMENT) size.* = std.math.maxInt(u64) else return 0;
    }
    return idl + 1 + len;
}

fn ebmlParse(tf: TF, ctx: *const s.Scan, size_in: c.guint, info: *Mkv, depth: c.guint) bool {
    var k = ctx.*;
    var chunk = size_in;
    if (depth >= 8) return false;
    while (chunk > 0) {
        if (k.offset > 2 * 1024 * 1024 or !k.ensure(tf, 64)) return false;
        var id: u32 = 0;
        var el: u64 = 0;
        const hl = ebmlHeader(tf, &k, chunk, &id, &el);
        if (hl == 0) return false;
        if (!(hl <= chunk)) c.g_assertion_message_expr(null, FILE, 4712, "ebml_parse_chunk", "hdr_len <= chunk_size");
        chunk -= hl;
        if (el > chunk) return false;
        if (el >= std.math.maxInt(u32)) return false;
        if (!k.ensure(tf, @truncate(el))) return false;
        switch (id) {
            0x4282 => {
                if (el >= 8 and s.eq(k.data, "matroska")) {
                    info.doctype = 1;
                } else if (el >= 4 and s.eq(k.data, "webm")) info.doctype = 2;
            },
            SEGMENT => {
                _ = ebmlParse(tf, &k, @truncate(el), info, depth + 1);
                return false;
            },
            0x1654AE6B => {
                info.tracks_ok = ebmlParse(tf, &k, @truncate(el), info, depth + 1);
                return false;
            },
            0xAE => if (!ebmlParse(tf, &k, @truncate(el), info, depth + 1)) return false,
            0x83 => {
                var t: c.guint = 0;
                for (0..@intCast(el)) |i| t = (t << 8) | k.data[i];
                if (t == 1) {
                    info.video += 1;
                } else if (k.data[0] == 2) {
                    info.audio += 1;
                } else info.other += 1;
            },
            0x53B8 => info.stereo += 1,
            0x1F43B675 => return false,
            else => {},
        }
        k.advance(@truncate(el));
        chunk -%= @truncate(el);
        info.chunks += 1;
    }
    return true;
}

pub fn matroska(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var info = Mkv{};
    var k = s.Scan{};
    if (!k.ensure(tf, 64)) return;
    if (s.be32(k.data) != 0x1A45DFA3) return;
    while (k.offset < 2 * 1024 * 1024 and k.ensure(tf, 64)) {
        var id: u32 = 0;
        var size: u64 = 0;
        if (ebmlHeader(tf, &k, k.size, &id, &size) == 0) return;
        if (!ebmlParse(tf, &k, @truncate(size), &info, 0)) break;
        k.advance(@truncate(size));
        if (id == SEGMENT) break;
    }
    const audio = info.audio > 0 and info.video == 0 and info.other == 0;
    const name: [*:0]const u8 = if (info.doctype == 2) (if (audio) "audio/webm" else "video/webm") else if (info.video > 0 and info.stereo != 0) "video/x-matroska-3d" else if (audio) "audio/x-matroska" else "video/x-matroska";
    c.gst_type_find_suggest_empty_simple(tf, if (info.doctype == 0) s.LIKELY else s.MAXIMUM, name);
}

pub fn mxf(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const key = "\x06\x0e\x2b\x34\x02\x05\x01\x01\x0d\x01\x02\x01\x01";
    var k = s.Scan{};
    while (k.offset <= 64 * 1024) : (k.advance(1024 - 16)) {
        if (!k.ensure(tf, 1024)) break;
        for (0..1024 - 16) |i| {
            const d = k.data + i;
            if (d[0] == 0x06 and s.eq(d, key)) {
                if (d[13] != 0x02 or d[14] >= 0x05 or d[15] != 0x00) break;
                return s.suggest(tf, s.MAXIMUM, s.caps("application/mxf"));
            }
        }
    }
}

pub fn dv(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 5) orelse return;
    if (d[0] == 0x1f and d[1] == 0x07 and d[2] == 0x00) {
        const f: [*:0]const u8 = if (d[3] & 0x80 != 0) "PAL" else "NTSC";
        c.gst_type_find_suggest_simple(tf, s.MAXIMUM, "video/x-dv", "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), "format", c.G_TYPE_STRING, f, N);
    }
}

const OggKind = enum(u3) { audio, video, kate, other, skeleton, annodex };

const ogg_markers = [_]struct { m: []const u8, k: OggKind }{
    .{ .m = "\x01vorbis", .k = .audio },     .{ .m = "\x80theora", .k = .video },           .{ .m = "fLaC", .k = .audio },
    .{ .m = "\x7fFLAC", .k = .audio },       .{ .m = "Speex", .k = .audio },                .{ .m = "CMML\x00\x00\x00\x00", .k = .other },
    .{ .m = "PCM     ", .k = .audio },       .{ .m = "Annodex", .k = .annodex },           .{ .m = "fishead", .k = .skeleton },
    .{ .m = "AnxData", .k = .annodex },      .{ .m = "CELT    ", .k = .audio },             .{ .m = "\x80kate\x00\x00\x00", .k = .kate },
    .{ .m = "BBCD\x00", .k = .video },       .{ .m = "OVP80\x01\x01", .k = .video },        .{ .m = "OpusHead", .k = .audio },
    .{ .m = "\x01audio\x00\x00\x00", .k = .audio }, .{ .m = "\x01video\x00\x00\x00", .k = .video }, .{ .m = "\x01text\x00\x00\x00", .k = .other },
};

pub fn ogg(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    var syncs: c.guint = 0;
    var count = [_]c.guint{0} ** 6;
    while (k.offset < 4096 and k.ensure(tf, 64)) {
        if (!s.eq(k.data, "OggS\x00")) break;
        syncs += 1;
        if (k.data[5] != 0x02) break;
        if (k.data[26] != 1) break;
        const size: c.guint = k.data[27];
        if (size < 8) break;
        k.advance(28);
        if (!k.ensure(tf, @max(size, 8))) break;
        var hit = false;
        for (ogg_markers) |m| {
            if (std.mem.eql(u8, k.data[0..m.m.len], m.m)) {
                count[@intFromEnum(m.k)] += 1;
                hit = true;
                break;
            }
        }
        if (!hit) count[@intFromEnum(OggKind.other)] += 1;
        k.advance(size);
    }
    if (syncs == 0) return;
    const media: [*:0]const u8 = if (count[1] > 0) "video/ogg" else if (count[0] > 0) "audio/ogg" else if (count[2] > 0 and count[3] == 0) "application/kate" else "application/ogg";
    c.gst_type_find_suggest_empty_simple(tf, s.MAXIMUM, media);
}

pub fn vorbis(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 30) orelse return;
    if (!s.eq(d, "\x01vorbis\x00\x00\x00\x00")) return;
    if (d[11] == 0) return;
    if (s.le32(d + 12) == 0) return;
    const b0 = d[28] & 0x0F;
    const b1 = (d[28] & 0xF0) >> 4;
    if (b0 > b1 or b0 < 6 or b0 > 13 or b1 < 6 or b1 > 13) return;
    if (d[29] & 0x01 != 1) return;
    s.suggest(tf, s.MAXIMUM, s.caps("audio/x-vorbis"));
}

pub fn theora(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 7) orelse return;
    if (s.eq(d, "\x80theora")) s.suggest(tf, s.MAXIMUM, s.caps("video/x-theora"));
}

pub fn kate(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 64) orelse return;
    if (!s.eq(d, "\x80kate\x00\x00\x00")) return;
    const raw = d[48..63];
    const cat = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse 15];
    const subs = std.mem.eql(u8, cat, "subtitles") or std.mem.eql(u8, cat, "SUB") or std.mem.eql(u8, cat, "spu-subtitles") or std.mem.eql(u8, cat, "K-SPU");
    c.gst_type_find_suggest_empty_simple(tf, s.MAXIMUM, if (subs) "subtitle/x-kate" else "application/x-kate");
}

pub fn webvtt(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var d = s.peek(tf, 0, 7) orelse return;
    if (s.eq(d, "WEBVTT")) {
        d += 6;
    } else {
        d = s.peek(tf, 0, 10) orelse return;
        if (!s.eq(d, "\xef\xbb\xbfWEBVTT")) return;
        d += 9;
    }
    if (d[0] != 0x20 and d[0] != 0x9 and d[0] != 0xa and d[0] != 0xd) return;
    s.suggest(tf, s.MAXIMUM, s.caps("application/x-subtitle-vtt, parsed=(boolean)false"));
}
