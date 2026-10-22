const std = @import("std");
const s = @import("scan.zig");
const c = s.c;
const TF = s.TF;
const N: ?*anyopaque = null;
const FILE = "../gst/typefind/gsttypefindfunctions.c";

fn magic(tf: TF, off: i64, comptime size: c.guint, comptime m: []const u8, prob: c.guint, comptime caps: [:0]const u8) void {
    const d = s.peek(tf, off, size) orelse return;
    if (s.eq(d, m)) s.suggest(tf, prob, s.caps(caps));
}

pub fn postscript(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var d = s.peek(tf, 0, 3) orelse return;
    if (d[0] == 0x04) d += 1;
    if (d[0] == '%' and d[1] == '!') s.suggest(tf, s.POSSIBLE, s.caps("application/postscript"));
}

pub fn svg(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const ns = "http://www.w3.org/2000/svg";
    var k = s.Scan{};
    var prob = s.NONE;
    while (k.offset <= 1024) : (k.advance(1)) {
        if (!k.ensure(tf, ns.len)) break;
        if (s.eq(k.data, "!DOCTYPE svg") or s.eq(k.data, ns)) return s.suggest(tf, s.MAXIMUM, s.caps("image/svg+xml"));
        if (s.eq(k.data, "<svg")) prob = s.LIKELY;
    }
    if (prob > s.NONE) s.suggest(tf, prob, s.caps("image/svg+xml"));
}

pub fn multipart(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var d = s.peek(tf, 0, 16) orelse return;
    var i: usize = 0;
    while (i < 14 and s.isSpace(d[i])) i += 1;
    if (d[i] != '-' or d[i + 1] != '-') return;
    d = s.peek(tf, 0, 256) orelse return;
    for (0..256 - 14) |x| {
        if (d[x] >= 0x80) return;
        if (d[x] == '\n' and s.caseEq(d + x + 1, "content-type:")) return s.suggest(tf, s.MAXIMUM, s.caps("multipart/x-mixed-replace"));
    }
}

pub fn ogmvideo(tf: TF, _: ?*anyopaque) callconv(.c) void {
    magic(tf, 0, 9, "\x01video\x00\x00\x00", s.MAXIMUM, "application/x-ogm-video");
}

pub fn ogmaudio(tf: TF, _: ?*anyopaque) callconv(.c) void {
    magic(tf, 0, 9, "\x01audio\x00\x00\x00", s.MAXIMUM, "application/x-ogm-audio");
}

pub fn ogmtext(tf: TF, _: ?*anyopaque) callconv(.c) void {
    magic(tf, 0, 9, "\x01text\x00\x00\x00\x00", s.MAXIMUM, "application/x-ogm-text");
}

pub fn speex(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 80) orelse return;
    if (!s.eq(d, "Speex   ")) return;
    if (s.le32(d + 32) < 80 or s.le32(d + 36) > 48000 or s.le32(d + 40) > 3) return;
    s.suggest(tf, s.MAXIMUM, s.caps("audio/x-speex"));
}

pub fn celt(tf: TF, _: ?*anyopaque) callconv(.c) void {
    magic(tf, 0, 8, "CELT    ", s.MAXIMUM, "audio/x-celt");
}

pub fn oggskel(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 12) orelse return;
    if (!s.eq(d, "fishead\x00")) return;
    if (s.le16(d + 8) != 3 or s.le16(d + 10) != 0) return;
    s.suggest(tf, s.MAXIMUM, s.caps("application/x-ogg-skeleton, parsed=(boolean)FALSE"));
}

pub fn cmml(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 12) orelse return;
    if (!s.eq(d, "CMML\x00\x00\x00\x00")) return;
    if (s.le16(d + 8) < 2) return;
    s.suggest(tf, s.MAXIMUM, s.caps("text/x-cmml"));
}

pub fn tar(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 257, 8) orelse return;
    if (s.eq(d, "ustar  \x00") or (s.eq(d, "ustar\x00") and s.isDigit(d[6]) and s.isDigit(d[7]))) s.suggest(tf, s.NEARLY_CERTAIN, s.caps("application/x-tar"));
}

pub fn ar(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 24) orelse return;
    if (!s.eq(d, "!<arch>")) return;
    for (7..24) |i| {
        if (!s.isPrint(d[i]) and d[i] != '\n') s.suggest(tf, s.POSSIBLE, s.caps("application/x-ar"));
    }
    s.suggest(tf, s.NEARLY_CERTAIN, s.caps("application/x-ar"));
}

pub fn au(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 4) orelse return;
    if (s.eq(d, ".snd") or s.eq(d, "dns.")) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-au"));
}

pub fn nuv(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 11) orelse return;
    if (s.eq(d, "MythTVVideo") or s.eq(d, "NuppelVideo")) s.suggest(tf, s.MAXIMUM, s.caps("video/x-nuv"));
}

pub fn paris(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 4) orelse return;
    if (s.eq(d, " paf") or s.eq(d, "fap ")) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-paris"));
}

fn sbcHeader(d: [*]const u8, rate: *c.guint, chans: *c.guint) usize {
    const rates = [4]c.guint{ 16000, 32000, 44100, 48000 };
    const blocks = [4]usize{ 4, 8, 12, 16 };
    if (d[0] != 0x9C) return 0;
    const nb = blocks[(d[1] >> 4) & 0x03];
    const mode = (d[1] >> 2) & 0x03;
    const sub: usize = if (d[1] & 0x01 != 0) 8 else 4;
    const pool: usize = d[2];
    if (pool < 2) return 0;
    rate.* = rates[(d[1] >> 6) & 0x03];
    chans.* = if (mode == 0) 1 else 2;
    return switch (mode) {
        0 => 4 + sub / 2 + nb * pool / 8,
        1 => 4 + sub + nb * 2 * pool / 8,
        2 => 4 + sub + nb * pool / 8,
        else => 4 + sub + (sub + nb * pool) / 8,
    };
}

pub fn sbc(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var rate: c.guint = 0;
    var chans: c.guint = 0;
    var off: c.guint = 0;
    for (0..10) |_| {
        const d = s.peek(tf, off, 8) orelse return;
        const len = sbcHeader(d, &rate, &chans);
        if (len == 0) return;
        off +%= @truncate(len);
    }
    c.gst_type_find_suggest_simple(tf, s.POSSIBLE, "audio/x-sbc", "rate", c.G_TYPE_INT, rate, "channels", c.G_TYPE_INT, chans, "parsed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), N);
}

pub fn ilbc(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 8) orelse return;
    if (s.eq(d, "#!iLBC30") or s.eq(d, "#!iLBC20")) s.suggest(tf, s.LIKELY, s.caps("audio/iLBC-sh"));
}

pub fn msdos(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 64) orelse return;
    if (!(d[0] == 'M' and d[1] == 'Z' and s.le16(d + 8) == 4)) return;
    const pe = s.peek(tf, s.le32(d + 60), 2) orelse return;
    if (pe[0] == 'P' and pe[1] == 'E') s.suggest(tf, s.NEARLY_CERTAIN, s.caps("application/x-ms-dos-executable"));
}

pub fn mmsh(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 28) orelse return;
    if (d[0] == 0x24 and d[1] == 0x48 and s.le16(d + 2) > 28 and s.eq(d + 12, "\x30\x26\xb2\x75\x8e\x66\xcf\x11\xa6\xd9\x00\xaa\x00\x62\xce\x6c")) s.suggest(tf, s.LIKELY, s.caps("application/x-mmsh"));
}

pub fn dirac(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 8) orelse return;
    if (s.eq(d, "BBCD") or s.eq(d, "KW-DIRAC")) s.suggest(tf, s.MAXIMUM, s.caps("video/x-dirac"));
}

pub fn tap(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 16) orelse return;
    if (s.eq(d, "C64-TAPE-RAW") or s.eq(d, "C16-TAPE-RAW")) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-tap-tap"));
}

fn bom(d: [*]const u8) bool {
    const v = s.le32(d + 4);
    return v == 0xfffe or v == 0xfeff;
}

pub fn brstm(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 8) orelse return;
    if (s.eq(d, "RSTM") and bom(d)) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-brstm"));
}

pub fn bfstm(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 8) orelse return;
    if ((s.eq(d, "FSTM") or s.eq(d, "CSTM")) and bom(d)) s.suggest(tf, s.MAXIMUM, s.caps("audio/x-bfstm"));
}

pub fn dsf(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 12) orelse return;
    if (!s.eq(d, "DSD ")) return;
    if (s.be64(d + 4) == 28) return;
    s.suggest(tf, s.MAXIMUM, s.caps("audio/x-dsf"));
}

pub fn ea(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 8) orelse return;
    const tags = [_]*const [4]u8{ "ISNh", "SCHl", "SEAD", "SHEN", "kVGT", "MADk", "MPCh", "MVhd", "MVIh", "AVP6" };
    var hit = false;
    for (tags) |t| {
        if (std.mem.eql(u8, d[0..4], t)) hit = true;
    }
    if (!hit) return;
    var size = s.le32(d + 4);
    if (size > 0x000fffff) size = @byteSwap(size);
    if (size > 0xfffff or size < 8) return;
    s.suggest(tf, s.MAXIMUM, s.caps("video/x-ea"));
}

pub fn filmCpk(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 20) orelse return;
    if (s.eq(d, "FILM") and s.eq(d + 16, "FDSC")) s.suggest(tf, s.MAXIMUM, s.caps("video/x-film-cpk"));
}

pub fn gxf(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 16) orelse return;
    if (s.eq(d, "\x00\x00\x00\x00\x01\xbc") and s.eq(d + 10, "\x00\x00\x00\x00\xe1\xe2")) s.suggest(tf, s.MAXIMUM, s.caps("application/gxf"));
}

pub fn iff(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 16) orelse return;
    const kinds = [_]*const [4]u8{ "8SVX", "16SV", "MAUD", "PBM ", "ACBM", "DEEP", "ILBM", "RGB8", "ANIM", "RGBN" };
    if (s.eq(d, "FORM")) {
        for (kinds) |k| {
            if (std.mem.eql(u8, d[8..12], k)) return s.suggest(tf, s.MAXIMUM, s.caps("application/x-iff"));
        }
    }
    if (s.eq(d, "FRM8") and s.eq(d + 12, "DSD ")) s.suggest(tf, s.MAXIMUM, s.caps("application/x-iff"));
}

pub fn vivo(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 1024) orelse return;
    if (d[0] != 0x00) return;
    var pos: usize = 2;
    if (d[1] & 0x80 != 0) {
        if (d[2] & 0x80 != 0) return;
        const len = (@as(c.guint, d[1] & 0x7f) << 7) + d[2];
        if (len > 2048) return;
        pos = 3;
    }
    while (pos < 1008 and d[pos] == '\r' and d[pos + 1] == '\n') pos += 2;
    if (s.eq(d + pos, "Version:Vivo/")) s.suggest(tf, s.MAXIMUM, s.caps("video/vivo"));
}

pub fn windowsIcon(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const len: i64 = @bitCast(s.length(tf));
    if (len < 22) return;
    const d = s.peek(tf, 0, 6) orelse return;
    if (s.le16(d) != 0) return;
    const kind = s.le16(d + 2);
    if (kind != 1 and kind != 2) return;
    if (s.le16(d + 4) == 0) return;
    if (d[9] != 0) return;
    if (kind == 1 and s.le16(d + 10) > 1) return;
    const size: i32 = @bitCast(s.le32(d + 14));
    const off: i32 = @bitCast(s.le32(d + 18));
    if (off < 0 or size <= 0 or size >= len or off >= len or @as(i64, size +% off) > len) return;
    c.gst_type_find_suggest_empty_simple(tf, s.NEARLY_CERTAIN, "image/x-icon");
}

pub fn wbmp(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const len: i64 = @bitCast(s.length(tf));
    if (len == 0) return;
    var d = s.peek(tf, 0, 5) orelse return;
    if (d[0] != 0 or d[1] != 0) return;
    d += 2;
    var size: c.guint = 4;
    var w: c.guint = d[0];
    d += 1;
    if (w & 0x80 != 0) {
        w = (w << 8) | d[0];
        if (w & 0x80 != 0) return;
        size += 1;
        d = s.peek(tf, 4, 2) orelse return;
    }
    var h: c.guint = d[0];
    d += 1;
    if (h & 0x80 != 0) {
        h = (h << 8) | d[0];
        if (h & 0x80 != 0) return;
        size += 1;
    }
    if (w == 0 or h == 0) return;
    size +%= h *% (((w + 7) & ~@as(c.guint, 7)) / 8);
    if (len == size) c.gst_type_find_suggest_empty_simple(tf, s.POSSIBLE - 10, "image/vnd.wap.wbmp");
}

fn degasTail(tf: TF, len: i64) bool {
    const d = s.peek(tf, len - 16, 8) orelse return false;
    for (0..4) |n| {
        if (s.be16(d + n * 2) > 2) return false;
    }
    return true;
}

pub fn degas(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const len: i64 = @bitCast(s.length(tf));
    if (len < 34) return;
    const d = s.peek(tf, 0, 4) orelse return;
    const res = s.be16(d);
    const ok = if (len == 32034) res <= 2 else if (len == 32066) res <= 2 and degasTail(tf, len) else if (len >= 66 and len < 32066) res & 0x8000 != 0 and res & 0x7fff <= 2 and degasTail(tf, len) else false;
    if (ok) c.gst_type_find_suggest_empty_simple(tf, s.POSSIBLE + 5, "image/x-degas");
}

pub fn y4m(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 10) orelse return;
    if (s.eq(d, "YUV4MPEG2 ")) c.gst_type_find_suggest_simple(tf, s.MAXIMUM, "application/x-yuv4mpeg", "y4mversion", c.G_TYPE_INT, @as(c.gint, 2), N);
}

pub fn dvdiso(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const len: i64 = @bitCast(s.length(tf));
    if (len < 0x8006) return;
    const d = s.peek(tf, 0, 0x8006) orelse return;
    for (d[0..0x8000]) |b| {
        if (b != 0) return;
    }
    if (!s.eq(d + 0x8000, "\x01CD001")) return;
    c.gst_type_find_suggest_empty_simple(tf, s.LIKELY, "application/octet-stream");
}

pub fn ssa(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var d = s.peek(tf, 0, 32) orelse return;
    if (!s.eq(d, "[Script Info]") and !s.eq(d + 3, "[Script Info]")) return;
    var len: i64 = @bitCast(s.length(tf));
    if (len > 8192) len = 8192;
    d = s.peek(tf, 0, @truncate(@as(u64, @bitCast(len)))) orelse return;
    const start = d + (s.find(d, 5, '[') orelse {
        c.g_assertion_message_expr(null, FILE, 6656, "ssa_type_find", "start");
        return;
    });
    len -= @intCast(@intFromPtr(start) - @intFromPtr(d));
    var end: [*c]const u8 = null;
    if (c.g_utf8_validate(@ptrCast(start), len, &end) == 0 and len - @as(i64, @intCast(@intFromPtr(end) - @intFromPtr(start))) > 6) return;
    if (d[0] != '[' and (d[0] != 0xEF or d[1] != 0xBB or d[2] != 0xBF)) return;
    len = @intCast(@intFromPtr(end) - @intFromPtr(start));
    const str = c.g_strndup(@ptrCast(start), @bitCast(len - 1));
    defer c.g_free(str);
    var media: ?[*:0]const u8 = null;
    if (c.strstr(str, "ScriptType:")) |st| {
        var v: [*c]u8 = st + 11;
        while (v[0] == ' ' or v[0] == 'v' or v[0] == 'V') v += 1;
        var p: [*c]u8 = null;
        const ver = c.g_ascii_strtod(v, &p);
        if (ver == 4.0 and p != null and p[0] == '+') {
            media = "application/x-ass";
        } else if (ver >= 1.0 and ver <= 4.0) media = "application/x-ssa";
    }
    if (media == null) {
        if (c.strstr(str, "[v4+ Styles]") != null or c.strstr(str, "[V4+ Styles]") != null) {
            media = "application/x-ass";
        } else if (c.strstr(str, "[v4 Styles]") != null or c.strstr(str, "[V4 Styles]") != null) media = "application/x-ssa";
    }
    if (media) |m| c.gst_type_find_suggest_simple(tf, s.MAXIMUM, m, "parsed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), N);
}

pub fn mcc(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 31) orelse return;
    if (!s.eq(d, "File Format=MacCaption_MCC V") or !s.isDigit(d[28]) or d[29] != '.' or !s.isDigit(d[30])) return;
    c.gst_type_find_suggest_simple(tf, s.MAXIMUM, "application/x-mcc", "version", c.G_TYPE_INT, @as(c.gint, d[28] - '0'), N);
}

pub fn pva(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 5) orelse return;
    if (d[0] == 'A' and d[1] == 'V' and d[2] < 3 and d[4] == 0x55) s.suggest(tf, s.NEARLY_CERTAIN, s.caps("video/x-pva"));
}

pub fn aa(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 12) orelse return;
    if (s.be32(d + 4) != 0x57907536) return;
    const len = s.length(tf);
    s.suggest(tf, if (len > 0 and s.be32(d) == len) s.NEARLY_CERTAIN else s.POSSIBLE, s.caps("audio/x-audible"));
}

const Reader = struct {
    d: [*]const u8,
    pos: usize = 0,
    len: usize,

    fn byte(r: *Reader) ?u8 {
        if (r.pos >= r.len) return null;
        r.pos += 1;
        return r.d[r.pos - 1];
    }
};

fn leb128(r: *Reader) ?u32 {
    var v: u64 = 0;
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        const b = r.byte() orelse return null;
        v |= @as(u64, b & 0x7f) << (i * 7);
        if (b & 0x80 == 0) break;
        if (i == 7) return null;
    }
    if (v <= std.math.maxInt(u32)) return @intCast(v);
    return null;
}

fn obu(r: *Reader, kind: *c.guint) bool {
    kind.* = 0;
    const b = r.byte() orelse return false;
    if (b & 0x80 != 0) return false;
    kind.* = (b & 0x78) >> 3;
    if (b & 0x4 != 0) {
        if (r.pos + 1 > r.len) return false;
        r.pos += 1;
    }
    const valid = (kind.* > 0 and kind.* < 9) or kind.* == 15;
    if (valid and b & 0x1 == 0) {
        if (b & 0x2 != 0) _ = leb128(r) orelse return false;
        return true;
    }
    return false;
}

fn av1Suggest(tf: TF, comptime fmt: [:0]const u8) void {
    c.gst_type_find_suggest_simple(tf, s.MINIMUM, "video/x-av1", "stream-format", c.G_TYPE_STRING, fmt.ptr, "alignment", c.G_TYPE_STRING, "none", N);
}

pub fn av1(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 25) orelse return;
    var r = Reader{ .d = d, .len = 25 };
    var kind: c.guint = 0;
    if (obu(&r, &kind)) return av1Suggest(tf, "obu-stream");
    const tu = leb128(&r) orelse return;
    const fu = leb128(&r) orelse return;
    if (fu > tu) return;
    const ol = leb128(&r) orelse return;
    if (ol > fu) return;
    if (!obu(&r, &kind)) return;
    if (kind == 2) av1Suggest(tf, "annexb");
}

pub const Data = extern struct {
    data: [*]const u8,
    size: c.guint,
    prob: c.guint,
    caps: [*c]c.GstCaps,
};

pub fn startWith(tf: TF, p: ?*anyopaque) callconv(.c) void {
    const sw: *Data = @ptrCast(@alignCast(p));
    const d = s.peek(tf, 0, sw.size) orelse return;
    if (std.mem.eql(u8, d[0..sw.size], sw.data[0..sw.size])) s.suggest(tf, sw.prob, sw.caps);
}

pub fn riff(tf: TF, p: ?*anyopaque) callconv(.c) void {
    const sw: *Data = @ptrCast(@alignCast(p));
    const d = s.peek(tf, 0, 12) orelse return;
    if (s.eq(d, "RIFF") or s.eq(d, "AVF0")) {
        if (std.mem.eql(u8, d[8..12], sw.data[0..4])) s.suggest(tf, sw.prob, sw.caps);
    }
}

pub fn destroy(p: ?*anyopaque) callconv(.c) void {
    const sw: *Data = @ptrCast(@alignCast(p));
    if (sw.caps != null) c.gst_mini_object_unref(@ptrCast(sw.caps));
    c.g_free(p);
}
