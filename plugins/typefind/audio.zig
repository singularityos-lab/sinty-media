const std = @import("std");
const s = @import("scan.zig");
const c = s.c;
const TF = s.TF;
const N: ?*anyopaque = null;

fn loasEp(tf: TF, start: *const s.Scan, max: c.gint) c.gint {
    var k = start.*;
    var count: c.gint = 0;
    while (true) {
        if (!k.ensure(tf, 5)) break;
        const len: c.guint = (@as(c.guint, k.data[2] & 0x0f) << 9) | (@as(c.guint, k.data[3]) << 1) | ((k.data[4] & 0x80) >> 7);
        if (len == 0 or !k.ensure(tf, len + 2)) break;
        if (s.be16(k.data + len) != 0x4de1) break;
        count += 1;
        k.advance(len);
        if (!(count < max and k.offset -% start.offset < 64 * 1024)) break;
    }
    return count;
}

fn loas(tf: TF, start: *const s.Scan, max: c.gint) c.gint {
    var k = start.*;
    var count: c.gint = 0;
    while (true) {
        if (!k.ensure(tf, 3)) break;
        var len: c.guint = (@as(c.guint, k.data[1] & 0x1f) << 8) | k.data[2];
        len += 3;
        if (len == 0 or !k.ensure(tf, len + 2)) break;
        if (s.be16(k.data + len) & 0xffe0 != 0x56e0) break;
        count += 1;
        k.advance(len);
        if (!(count < max and k.offset -% start.offset < 64 * 1024)) break;
    }
    return count;
}

fn adtsLen(d: [*]const u8) c.guint {
    return (@as(c.guint, d[3] & 0x03) << 11) | (@as(c.guint, d[4]) << 3) | ((d[5] & 0xe0) >> 5);
}

pub fn aac(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    var best_prob: c.guint = s.NONE;
    var best_caps: [*c]c.GstCaps = null;
    var best_count: c.gint = 0;
    while (k.offset < 4096) : (k.advance(1)) {
        if (!k.ensure(tf, 6)) break;
        const snc = s.be16(k.data);
        if (snc & 0xfff6 == 0xfff0) {
            var len = adtsLen(k.data);
            if (len == 0 or !k.ensure(tf, len + 6)) continue;
            var offset = len;
            if (s.be16(k.data + offset) & 0xfff6 != 0xfff0) continue;
            const version: c.gint = if (k.data[1] & 0x08 != 0) 2 else 4;
            const profile: c.guint = k.data[2] >> 6;
            const freq: c.guint = (k.data[2] & 0x3c) >> 2;
            const chans: c.guint = (@as(c.guint, k.data[2] & 0x01) << 2) + (k.data[3] >> 6);
            if (freq > 0xc) continue;
            const rate = c.gst_codec_utils_aac_get_sample_rate_from_index(freq);
            var cfg = [2]u8{ @truncate(((profile + 1) << 3) | ((freq >> 1) & 0x7)), @truncate(((freq & 0x1) << 7) | ((chans & 0xf) << 3)) };
            const caps = c.gst_caps_new_simple("audio/mpeg", "framed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), "mpegversion", c.G_TYPE_INT, version, "stream-format", c.G_TYPE_STRING, "adts", N);
            _ = c.gst_codec_utils_aac_caps_set_level_and_profile(caps, &cfg, 2);
            if (chans != 0 and chans <= 7) {
                const map = [_]c.gint{ 0, 1, 2, 3, 4, 5, 6, 8 };
                c.gst_caps_set_simple(caps, "channels", c.G_TYPE_INT, map[chans], "rate", c.G_TYPE_INT, rate, N);
            }
            len = adtsLen(k.data + offset);
            if (len == 0 or !k.ensure(tf, offset + len + 6)) {
                s.suggest(tf, s.LIKELY, caps);
            } else {
                offset += len;
                var i: c.guint = 3;
                while (i <= 6) : (i += 1) {
                    len = adtsLen(k.data + offset);
                    if (len == 0 or !k.ensure(tf, offset + len + 6)) break;
                    if (s.be16(k.data + offset) & 0xfff6 != 0xfff0) break;
                    offset += len;
                }
                s.suggest(tf, s.LIKELY + 5 * (i - 3), caps);
            }
            c.gst_mini_object_unref(@ptrCast(caps));
            break;
        } else if (snc & 0xffe0 == 0x56e0 or snc == 0x4de1) {
            const count = if (snc == 0x4de1) loasEp(tf, &k, 20) else loas(tf, &k, 20);
            if (count >= 3 and count > best_count) {
                if (best_caps != null) c.gst_mini_object_unref(@ptrCast(best_caps));
                best_caps = c.gst_caps_new_simple("audio/mpeg", "framed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), "mpegversion", c.G_TYPE_INT, @as(c.gint, 4), "stream-format", c.G_TYPE_STRING, "loas", N);
                best_count = count;
                best_prob = @intCast(@as(c.gint, s.POSSIBLE) - 10 + count * 3);
                if (best_prob >= s.LIKELY) break;
            }
        } else if (s.eq(k.data, "ADIF")) {
            c.gst_type_find_suggest_simple(tf, s.LIKELY, "audio/mpeg", "framed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), "mpegversion", c.G_TYPE_INT, @as(c.gint, 4), "stream-format", c.G_TYPE_STRING, "adif", N);
            break;
        }
    }
    if (best_prob > s.NONE) {
        s.suggest(tf, best_prob, best_caps);
        c.gst_mini_object_unref(@ptrCast(best_caps));
    }
}

const bitrates = [2][3][16]c.guint{
    .{ .{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0 }, .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0 }, .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 } },
    .{ .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0 }, .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 }, .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 } },
};

const freqs = [3][3]c.guint{ .{ 11025, 12000, 8000 }, .{ 22050, 24000, 16000 }, .{ 44100, 48000, 32000 } };

const Mp3 = struct { layer: c.guint = 0, channels: c.guint = 0, bitrate: c.guint = 0, rate: c.guint = 0, free: bool = false };

fn frameLen(header_in: u32, out: *Mp3, free_len: c.gint) c.guint {
    var h = header_in;
    if (h & 0xffe00000 != 0xffe00000) return 0;
    h >>= 6;
    const mode = h & 0x3;
    h >>= 3;
    var len: c.guint = h & 0x1;
    h >>= 1;
    var rate: c.guint = h & 0x3;
    if (rate == 3) return 0;
    h >>= 2;
    var bitrate: c.guint = h & 0xF;
    if (bitrate == 0 and free_len == -1) out.free = true;
    if (bitrate == 15 or (bitrate == 0 and free_len == -1)) return 0;
    h >>= 5;
    const layer: c.guint = 4 - (h & 0x3);
    if (layer == 4) return 0;
    h >>= 2;
    const version = h & 0x3;
    if (version == 1) return 0;
    const channels: c.guint = if (mode == 3) 1 else 2;
    rate = freqs[if (version > 0) version - 1 else 0][rate];
    const row: usize = if (version == 3) 0 else 1;
    const big: c.guint = if (layer == 3 and version != 3) 72000 else 144000;
    if (bitrate == 0) {
        if (layer == 1) {
            len *= 4;
            len +%= @bitCast(free_len);
            bitrate = len *% rate / 48000;
        } else {
            len +%= @bitCast(free_len);
            bitrate = len *% rate / big;
        }
        if (bitrate < bitrates[row][layer - 1][14]) return 0;
    } else {
        bitrate = bitrates[row][layer - 1][bitrate];
        if (layer == 1) {
            len = ((12000 * bitrate / rate) + len) * 4;
        } else len += big * bitrate / rate;
    }
    out.layer = layer;
    out.channels = channels;
    out.bitrate = bitrate;
    out.rate = rate;
    return len;
}

fn mp3At(tf: TF, start: u64, found_layer: *c.guint, found_prob: *c.guint) void {
    var data: [*]const u8 = undefined;
    var end: usize = 0;
    var size: c.guint = 0;
    var skipped: u64 = 0;
    var last_free_off: c.gint = -1;
    var last_free_len: c.gint = -1;
    var headerstart = true;
    found_layer.* = 0;
    found_prob.* = 0;
    while (skipped < 10000) : ({
        data += 1;
        skipped += 1;
        size -%= 1;
    }) {
        if (size <= 0) {
            size = 4096;
            var d: ?[*]const u8 = null;
            while (true) {
                size /= 2;
                d = s.peek(tf, @bitCast(skipped + start), size);
                if (!(size > 10 and d == null)) break;
            }
            data = d orelse break;
            end = @intFromPtr(data) + size;
        }
        if (data[0] != 0xFF) continue;
        var head: ?[*]const u8 = null;
        var m = Mp3{};
        var found: c.guint = 0;
        var offset = skipped;
        var changed = false;
        var prev_layer: c.guint = 0;
        var prev_channels: c.guint = 0;
        var prev_rate: c.guint = 0;
        while (found < 5) {
            const rel: i64 = @bitCast(offset -% skipped);
            head = if (rel + 4 >= 0 and @as(i64, @intCast(@intFromPtr(data))) + rel + 4 < @as(i64, @intCast(end))) data + @as(usize, @intCast(rel)) else s.peek(tf, @bitCast(offset +% start), 4);
            const hd = head orelse break;
            m.free = false;
            const len = frameLen(s.be32(hd), &m, last_free_len);
            if (len == 0) {
                if (m.free) {
                    if (last_free_off == -1) {
                        last_free_off = @truncate(@as(i64, @bitCast(offset)));
                    } else {
                        last_free_len = @truncate(@as(i64, @bitCast(offset -% @as(u64, @bitCast(@as(i64, last_free_off))))));
                        offset = @bitCast(@as(i64, last_free_off));
                        continue;
                    }
                } else last_free_len = -1;
                if (found == 0) headerstart = false;
                break;
            }
            if ((prev_layer != 0 and prev_layer != m.layer) or (prev_rate != 0 and prev_rate != m.rate) or (prev_channels != 0 and prev_channels != m.channels)) {
                if (prev_layer != 0) changed = true;
            } else found += 1;
            prev_layer = m.layer;
            prev_channels = m.channels;
            prev_rate = m.rate;
            offset +%= len;
        }
        if (found != 0 and head == null and s.peek(tf, @bitCast(offset +% start -% 1), 1) == null) found -= 1;
        if (found == 5 or (found >= 2 and head == null)) {
            var prob: c.guint = @truncate(@as(u64, found) * 100 * (10000 - skipped) / 5 / 10000);
            if (!headerstart and prob > s.MINIMUM + 10) prob -= 10;
            if (prob < s.MINIMUM) prob = s.MINIMUM;
            if (start > 0) prob /= 2;
            if (!changed) prob = (prob + s.MAXIMUM) / 2;
            if (s.peek(tf, -128, 3)) |t| {
                if (s.eq(t, "TAG")) prob = 0;
            }
            found_prob.* = prob;
            if (prob > 0) found_layer.* = m.layer;
            return;
        }
    }
}

pub fn mp3(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var layer: c.guint = 0;
    var prob: c.guint = 0;
    mp3At(tf, 0, &layer, &prob);
    const len = s.length(tf);
    blk: {
        if (len == 0 or len == std.math.maxInt(u64)) {
            if (prob != 0) break :blk;
            return;
        }
        if (prob >= s.LIKELY) break :blk;
        var mid_layer: c.guint = 0;
        var mid_prob: c.guint = 0;
        mp3At(tf, len / 2, &mid_layer, &mid_prob);
        if (mid_prob > 0) {
            if (prob == 0) {
                layer = mid_layer;
                prob = mid_prob;
                break :blk;
            }
            if (layer != mid_layer) return;
            prob = (prob + mid_prob) / 2;
            break :blk;
        }
        if (prob > 0) {
            if (s.peek(tf, 0, 4)) |d| {
                var m = Mp3{};
                if (frameLen(s.be32(d), &m, 0) != 0) {
                    layer = m.layer;
                    prob = @min(prob + 10, s.MAXIMUM);
                }
            }
        }
        if (prob == 0) return;
    }
    if (!(layer >= 1 and layer <= 3)) {
        c.g_return_if_fail_warning(null, "mp3_type_find", "layer >= 1 && layer <= 3");
        return;
    }
    c.gst_type_find_suggest_simple(tf, prob, "audio/mpeg", "mpegversion", c.G_TYPE_INT, @as(c.gint, 1), "layer", c.G_TYPE_INT, layer, "parsed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), N);
}

pub fn musepack(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const d = s.peek(tf, 0, 4) orelse return;
    var prob = s.MINIMUM;
    var version: c.gint = -1;
    if (s.eq(d, "MP+")) {
        version = 7;
        prob = if (d[3] & 0x7f == 7) s.MAXIMUM else s.LIKELY + 10;
    } else if (s.eq(d, "MPCK")) {
        version = 8;
        prob = s.MAXIMUM;
    }
    if (version != -1) c.gst_type_find_suggest_simple(tf, prob, "audio/x-musepack", "streamversion", c.G_TYPE_INT, version, N);
}

const ac3_sizes = [38][3]c.guint{
    .{ 64, 69, 96 },     .{ 64, 70, 96 },     .{ 80, 87, 120 },    .{ 80, 88, 120 },    .{ 96, 104, 144 },   .{ 96, 105, 144 },
    .{ 112, 121, 168 },  .{ 112, 122, 168 },  .{ 128, 139, 192 },  .{ 128, 140, 192 },  .{ 160, 174, 240 },  .{ 160, 175, 240 },
    .{ 192, 208, 288 },  .{ 192, 209, 288 },  .{ 224, 243, 336 },  .{ 224, 244, 336 },  .{ 256, 278, 384 },  .{ 256, 279, 384 },
    .{ 320, 348, 480 },  .{ 320, 349, 480 },  .{ 384, 417, 576 },  .{ 384, 418, 576 },  .{ 448, 487, 672 },  .{ 448, 488, 672 },
    .{ 512, 557, 768 },  .{ 512, 558, 768 },  .{ 640, 696, 960 },  .{ 640, 697, 960 },  .{ 768, 835, 1152 }, .{ 768, 836, 1152 },
    .{ 896, 975, 1344 }, .{ 896, 976, 1344 }, .{ 1024, 1114, 1536 }, .{ 1024, 1115, 1536 }, .{ 1152, 1253, 1728 }, .{ 1152, 1254, 1728 },
    .{ 1280, 1393, 1920 }, .{ 1280, 1394, 1920 },
};

pub fn ac3(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    while (k.offset < 1024) : (k.advance(1)) {
        if (!k.ensure(tf, 6)) break;
        if (!(k.data[0] == 0x0b and k.data[1] == 0x77)) continue;
        const bsid = k.data[5] >> 3;
        const prob = if (k.offset == 0) s.MAXIMUM else s.NEARLY_CERTAIN;
        if (bsid <= 8) {
            const fscod = k.data[4] >> 6;
            const code = k.data[4] & 0x3f;
            if (!(fscod < 3 and code < 38)) continue;
            var n = k;
            const size = ac3_sizes[code][fscod];
            if (!n.ensure(tf, size * 2 + 5)) continue;
            n.advance(size * 2);
            if (n.data[0] == 0x0b and n.data[1] == 0x77) {
                if (n.data[4] >> 6 < 3 and n.data[4] & 0x3f < 38) return s.suggest(tf, prob, s.caps("audio/x-ac3"));
            }
        } else if (bsid <= 16 and bsid > 10) {
            var n = k;
            const size: c.guint = ((@as(c.guint, k.data[2] & 0x07) << 8) + k.data[3]) + 1;
            if (!n.ensure(tf, size * 2 + 5)) continue;
            n.advance(size * 2);
            if (n.data[0] == 0x0b and n.data[1] == 0x77) return s.suggest(tf, prob, s.caps("audio/x-eac3"));
        }
    }
}

const Dts = struct { size: c.guint = 0, rate: c.guint = 0, chans: c.guint = 0, depth: c.guint = 0, endian: c.guint = 0 };

fn dtsHeader(d: [*]const u8, out: *Dts) bool {
    const rates = [16]c.guint{ 0, 8000, 16000, 32000, 0, 0, 11025, 22050, 44100, 0, 0, 12000, 24000, 48000, 96000, 192000 };
    const table = [16]u8{ 1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 6, 6, 6, 7, 8, 8 };
    var h: [8]u16 = undefined;
    const marker = s.be32(d);
    if (marker == 0x7FFE8001 or marker == 0x1FFFE800) {
        out.endian = 4321;
        for (&h, 0..) |*x, i| x.* = s.be16(d + i * 2);
    } else if (marker == 0xFE7F0180 or marker == 0xFF1F00E8) {
        out.endian = 1234;
        for (&h, 0..) |*x, i| x.* = s.le16(d + i * 2);
    } else return false;
    const packed14 = marker == 0x1FFFE800 or marker == 0xFF1F00E8;
    if (packed14) {
        if (h[2] & 0xFFF0 != 0x07F0) return false;
        var i: usize = 0;
        while (i < 7) : (i += 1) {
            const sh: u4 = @intCast(2 * (i + 1));
            const keep: u16 = (@as(u16, 1) << sh) - 1;
            h[i] = (h[i] << sh) | ((h[i + 1] >> (14 - sh)) & keep);
        }
        if (!(h[0] == 0x7FFE and h[1] == 0x8001)) c.g_assertion_message_expr(null, "../gst/typefind/gsttypefindfunctions.c", 1955, "dts_parse_frame_header", "hdr[0] == 0x7FFE && hdr[1] == 0x8001");
        out.depth = 14;
    } else out.depth = 16;
    const blocks = (h[2] >> 2) & 0x7F;
    out.size = ((@as(c.guint, h[2] & 0x03) << 12) | (h[3] >> 4)) + 1;
    const chans = (@as(c.guint, h[3] & 0x0F) << 2) | (h[4] >> 14);
    out.rate = rates[(h[4] >> 10) & 0x0F];
    const lfe = (h[5] >> 9) & 0x03;
    if (blocks < 5 or out.size < 96 or out.rate == 0) return false;
    if (packed14) out.size = (out.size * 16) / 14;
    out.chans = if (chans < 16) table[chans] + @as(c.guint, @intFromBool(lfe != 0)) else 0;
    return true;
}

pub fn dts(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    while (k.offset <= 18725) : (k.advance(1)) {
        if (!k.ensure(tf, 96)) return;
        var h = Dts{};
        if (!dtsHeader(k.data, &h)) continue;
        var prob = if (k.offset == 0) s.LIKELY else s.POSSIBLE;
        var n = k;
        n.advance(h.size);
        if (n.ensure(tf, 4) and s.be32(k.data) == s.be32(n.data)) prob = s.MAXIMUM;
        const r: c.gint = @intCast(h.rate);
        const dp: c.gint = @intCast(h.depth);
        const en: c.gint = @intCast(h.endian);
        if (h.chans > 0) {
            c.gst_type_find_suggest_simple(tf, prob, "audio/x-dts", "rate", c.G_TYPE_INT, r, "channels", c.G_TYPE_INT, @as(c.gint, @intCast(h.chans)), "depth", c.G_TYPE_INT, dp, "endianness", c.G_TYPE_INT, en, "framed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), N);
        } else c.gst_type_find_suggest_simple(tf, prob, "audio/x-dts", "rate", c.G_TYPE_INT, r, "depth", c.G_TYPE_INT, dp, "endianness", c.G_TYPE_INT, en, "framed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), N);
        return;
    }
}

pub fn wavpack(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var d = s.peek(tf, 0, 32) orelse return;
    if (!s.eq(d, "wvpk")) return;
    var base = s.POSSIBLE;
    const lim: u64 = @as(u32, 8) +% s.le32(d + 4);
    var wv: c.guint = 0;
    var wvc: c.guint = 0;
    var offset: u64 = 32;
    while (offset < lim) {
        d = s.peek(tf, @bitCast(offset), 4) orelse break;
        var sub: u32 = @as(u32, d[1]) << 1;
        if (d[0] & 0x80 != 0) {
            sub |= (@as(u32, d[2]) << 9) | (@as(u32, d[3]) << 17);
            sub += 4;
        } else sub += 2;
        if (offset + sub > lim) break;
        switch (d[0] & 0x3f) {
            0xa, 0xc, 0x2c => wv += 1,
            0xb => wvc += 1,
            else => {},
        }
        if (wv >= 5 or wvc >= 5) break;
        offset += sub;
    }
    if (s.peek(tf, @bitCast(lim), 4)) |n| {
        if (s.eq(n, "wvpk")) base = s.LIKELY;
    }
    if (wvc > 0 and wvc > wv) {
        s.suggest(tf, @min(base + 5 * wvc, s.NEARLY_CERTAIN), s.caps("audio/x-wavpack-correction, framed = (boolean) false"));
    } else if (wv > 0) s.suggest(tf, @min(base + 5 * wv, s.NEARLY_CERTAIN), s.caps("audio/x-wavpack, framed = (boolean) false"));
}
