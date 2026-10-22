const std = @import("std");
const s = @import("scan.zig");
const c = s.c;
const TF = s.TF;
const N: ?*anyopaque = null;

pub fn isHeader(d: [*]const u8) bool {
    return d[0] == 0 and d[1] == 0 and d[2] == 1;
}

fn isPes(b: u8) bool {
    return b & 0xF0 == 0xE0 or b & 0xF0 == 0xC0 or b >= 0xBC;
}

pub fn validPack(d: [*]const u8, len: usize, size: ?*c.guint) bool {
    if (len < 12) return false;
    if (d[4] & 0xC4 == 0x44) {
        if (len < 14) return false;
        if (d[6] & 0x04 != 0x04 or d[8] & 0x04 != 0x04 or d[9] & 0x01 != 0x01 or d[12] & 0x03 != 0x03) return false;
        const stuff: usize = d[13] & 0x07;
        if (14 + stuff + 4 <= len and !isHeader(d + 14 + stuff)) return false;
        if (size) |p| p.* = @intCast(14 + stuff);
        return true;
    }
    if (d[4] & 0xF1 == 0x21) {
        if (d[6] & 0x01 != 0x01 or d[8] & 0x01 != 0x01 or d[9] & 0x80 != 0x80 or d[11] & 0x01 != 0x01) return false;
        if (16 <= len and !isHeader(d + 12)) return false;
        if (size) |p| p.* = 12;
        return true;
    }
    return false;
}

fn validLen(d: [*]const u8, len: usize, size: *c.guint, min: usize) bool {
    if (len < 6) return false;
    const n: usize = s.be16(d + 4);
    if (n < min) return false;
    if (6 + n + 4 <= len and !isHeader(d + 6 + n)) return false;
    size.* = @intCast(6 + n);
    return true;
}

pub fn mpegSys(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var len: c.gint = 128 * 1024;
    var data: ?[*]const u8 = null;
    while (len >= 16) {
        data = s.peek(tf, 0, @intCast(5 + len));
        if (data != null) break;
        len = @divTrunc(len, 2);
    }
    const d0 = data orelse return;
    var d = d0;
    const end = d0 + @as(usize, @intCast(len));
    var first: ?[*]const u8 = null;
    var version: c.gint = 0;
    var packs: c.guint = 0;
    var pes: c.guint = 0;
    var since: c.guint = 0;
    var sync: u32 = 0xffffffff;
    var potential: c.guint = 0;
    const ok = blk: {
        while (@intFromPtr(d) < @intFromPtr(end)) {
            sync <<= 8;
            if (sync == 0x00000100) {
                if (first == null) first = d - 3;
                if (since > 4) {
                    pes = 0;
                    packs = 0;
                }
                var size: c.guint = 0;
                potential += 1;
                const rest = @intFromPtr(end) - @intFromPtr(d) + 3;
                if (d[0] == 0xBA) {
                    if (d[1] & 0xC0 == 0x40) {
                        version = 2;
                    } else if (d[1] & 0xF0 == 0x20) version = 1;
                    if (version != 0 and validPack(d - 3, rest, &size)) packs += 1;
                } else if (isPes(d[0])) {
                    if (validLen(d - 3, rest, &size, 1)) {
                        pes += 1;
                        if (version == 0) version = 2;
                    }
                } else if (d[0] == 0xBB) {
                    if (validLen(d - 3, rest, &size, 6)) packs += 1;
                }
                if (size != 0) {
                    d += size - 3;
                    sync = 0xffffffff;
                    since = 0;
                    continue;
                }
            }
            sync |= d[0];
            since += 1;
            d += 1;
            if (pes > 0 and packs + pes > 5) break :blk true;
        }
        break :blk pes > 0 and packs + pes > 2;
    };
    if (!ok) return;
    var prob: c.guint = @min(s.POSSIBLE + 10 * (packs + pes), s.MAXIMUM);
    if (potential == packs + pes) prob = @min(prob + 10, s.MAXIMUM);
    if (first != d0 and prob >= 10) prob -= 10;
    c.gst_type_find_suggest_simple(tf, prob, "video/mpeg", "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), "mpegversion", c.G_TYPE_INT, version, N);
}

fn isTs(d: [*]const u8) bool {
    return d[0] == 0x47 and d[1] & 0x80 == 0 and (d[3] & 0x30 != 0 or (d[1] & 0x1f == 0x1f and d[2] == 0xff));
}

fn tsProbe(tf: TF, start: u64, size: c.gint) c.gint {
    var off = start;
    var found: c.gint = 1;
    while (found < 10) {
        off +%= @intCast(size);
        const d = s.peek(tf, @bitCast(off), 4) orelse return found;
        if (!isTs(d)) return found;
        found += 1;
    }
    return found;
}

pub fn mpegTs(tf: TF, _: ?*anyopaque) callconv(.c) void {
    const sizes = [_]c.gint{ 188, 192, 204, 208 };
    var data: [*]const u8 = undefined;
    var size: c.guint = 0;
    var skipped: u64 = 0;
    while (skipped < 10 * 208 * 4) : ({
        data += 1;
        skipped += 1;
        size -%= 1;
    }) {
        if (size < 4) {
            data = s.peek(tf, @bitCast(skipped), 4 * 208) orelse break;
            size = 4 * 208;
        }
        if (!isTs(data)) continue;
        for (sizes) |ps| {
            const found = tsProbe(tf, skipped, ps);
            if (found >= 4) {
                c.gst_type_find_suggest_simple(tf, @intCast(@min(10 * found, @as(c.gint, s.MAXIMUM))), "video/mpegts", "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), "packetsize", c.G_TYPE_INT, ps, N);
                return;
            }
        }
    }
}

fn nextHeader(tf: TF, k: *s.Scan, max: u64) bool {
    var extra: u64 = 0;
    while (extra <= max) : (extra += 1) {
        if (!k.ensure(tf, 4)) return false;
        if (isHeader(k.data)) {
            k.advance(3);
            return true;
        }
        k.advance(1);
    }
    return false;
}

const TRY_PICTURES = 6;
const TRY_SYNC = 100 * 1024;

pub fn mpeg4(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    var vios0 = false;
    var vios = false;
    var vos = false;
    var vol = false;
    var vops: c.guint = 0;
    while (k.offset < TRY_SYNC) {
        if (vops >= TRY_PICTURES) break;
        if (!nextHeader(tf, &k, TRY_SYNC -% k.offset)) break;
        var sc = k.data[0];
        if (sc == 0xB0) {
            if (vios) break;
            if (k.offset == 0) vios0 = true;
            vios = true;
            k.advance(2);
            if (!nextHeader(tf, &k, 0)) break;
            sc = k.data[0];
            if (sc == 0xB2) {
                if (!nextHeader(tf, &k, 24)) break;
            }
        }
        if (sc == 0xB5) {
            k.advance(2);
            if (!nextHeader(tf, &k, 7)) break;
            sc = k.data[0];
        }
        if (sc <= 0x1F) {
            if (vos) break;
            vos = true;
            k.advance(2);
            continue;
        }
        if (sc >= 0x20 and sc <= 0x2F) {
            vol = true;
            k.advance(5);
            continue;
        }
        if (sc == 0xB6) {
            vops += 1;
            k.advance(2);
            continue;
        }
    }
    if (!(vops > 0 or vol)) return;
    const many = vops >= TRY_PICTURES;
    const prob: c.guint = if (many and vios0 and vos and vol) s.MAXIMUM - 1 else if (many and vios and vos and vol) s.NEARLY_CERTAIN - 1 else if (vios0 and vos and vol) s.NEARLY_CERTAIN - 6 else if (many and vos and vol) s.NEARLY_CERTAIN - 6 else if (many and vol) s.NEARLY_CERTAIN - 9 else if (many) s.LIKELY - 1 else if (vops > 2 and vios and vos and vol) s.LIKELY - 9 else if (vios and vos and vol) s.LIKELY - 20 else if (vops > 0 and vos and vol) s.POSSIBLE else if (vops > 0) s.POSSIBLE - 10 else if (vos and vol) s.POSSIBLE - 20 else 0;
    s.suggest(tf, prob, s.caps("video/mpeg, systemstream=(boolean)false, mpegversion=4, parsed=(boolean)false"));
}

pub fn h263(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    var data: u64 = 0xffff;
    var good: c.guint = 0;
    var bad: c.guint = 0;
    while (k.offset < 128 * 1024) : (k.advance(1)) {
        if (!k.ensure(tf, 4)) break;
        data = (data << 8) +% k.data[0];
        if (data & 0xfffffc0000 != 0x800000) continue;
        const ptype: u8 = @truncate((data & 0x3fc) >> 2);
        const format = ptype & 0x07;
        if (ptype >> 6 == 0x2 and format > 0 and format < 6) {
            const pc = data & 0x02;
            const pb = k.data[1] & 2;
            if (pc == 0 and pb != 0) bad += 1 else good += 1;
        } else bad += 1;
    }
    if (good > 2 * bad) s.suggest(tf, s.POSSIBLE, s.caps("video/x-h263, variant=(string)itu"));
}

pub fn h264(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    var idr = false;
    var sps = false;
    var pps = false;
    var ssps = false;
    var good: c.gint = 0;
    var bad: c.gint = 0;
    const caps = "video/x-h264,stream-format=byte-stream";
    while (k.offset < 128 * 1024) : (k.advance(1)) {
        if (!k.ensure(tf, 4)) break;
        if (!isHeader(k.data)) continue;
        const nut = k.data[3] & 0x9f;
        const ref = k.data[3] & 0x60;
        if (nut > 0x1f) {
            bad += 1;
            break;
        }
        if ((nut >= 1 and nut <= 13) or nut == 19) {
            if ((nut == 5 and ref == 0) or ((nut == 6 or (nut >= 9 and nut <= 12)) and ref != 0)) {
                bad += 1;
            } else {
                if (nut == 7) {
                    sps = true;
                } else if (nut == 8) {
                    pps = true;
                } else if (nut == 5) idr = true;
                good += 1;
            }
        } else if (nut >= 14 and nut <= 33) {
            if (nut == 15) {
                ssps = true;
                good += 1;
            } else if (nut == 14 or nut == 20) {
                if (ssps) good += 1;
            } else bad += 1;
        }
        if (sps and pps and idr and good >= 10 and bad < 4) return s.suggest(tf, s.LIKELY, s.caps(caps));
        k.advance(4);
    }
    if (good >= 2 and bad == 0) s.suggest(tf, if (pps and sps) s.LIKELY else s.POSSIBLE, s.caps(caps));
}

pub fn h265(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    var irap = false;
    var vps = false;
    var sps = false;
    var pps = false;
    var good: c.gint = 0;
    var bad: c.gint = 0;
    const caps = "video/x-h265,stream-format=byte-stream";
    while (k.offset < 128 * 1024) : (k.advance(1)) {
        if (!k.ensure(tf, 5)) break;
        if (!isHeader(k.data)) continue;
        var nut = k.data[3] & 0xfe;
        if (nut > 0x7e) {
            bad += 1;
            break;
        }
        nut >>= 1;
        if (k.data[3] & 0x01 != 0 or k.data[4] & 0xf8 != 0 or k.data[4] & 0x07 == 0) {
            bad += 1;
            break;
        }
        if (nut <= 9 or (nut >= 16 and nut <= 21) or (nut >= 32 and nut <= 40)) {
            if (nut == 32) {
                vps = true;
            } else if (nut == 33) {
                sps = true;
            } else if (nut == 34) {
                pps = true;
            } else if (nut >= 16 and nut <= 21) irap = true;
            good += 1;
        } else if ((nut >= 10 and nut <= 15) or (nut >= 22 and nut <= 31) or (nut >= 41 and nut <= 47)) bad += 1;
        if (sps and pps and irap and good >= 10 and bad < 4) return s.suggest(tf, s.LIKELY, s.caps(caps));
        k.advance(5);
    }
    if (good >= 2 and bad == 0) s.suggest(tf, if (pps and sps and vps) s.LIKELY else s.POSSIBLE, s.caps(caps));
}

pub fn h266(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    var irap = false;
    var vps = false;
    var sps = false;
    var pps = false;
    var good: c.gint = 0;
    var bad: c.gint = 0;
    const caps = "video/x-h266,stream-format=byte-stream";
    while (k.offset < 128 * 1024) : (k.advance(1)) {
        if (!k.ensure(tf, 5)) break;
        if (!isHeader(k.data)) continue;
        if (k.data[3] & 0xc0 != 0) {
            bad += 1;
            break;
        }
        const nut = (k.data[4] & 0xf8) >> 3;
        if (k.data[4] & 0x07 == 0) {
            bad += 1;
            break;
        }
        if (nut <= 27) {
            if (nut == 14) {
                vps = true;
            } else if (nut == 15) {
                sps = true;
            } else if (nut == 16) {
                pps = true;
            } else if (nut >= 7 and nut <= 9) irap = true;
            good += 1;
        } else bad += 1;
        if (sps and pps and irap and good >= 10 and bad < 4) return s.suggest(tf, s.LIKELY, s.caps(caps));
        k.advance(5);
    }
    if (good >= 2 and bad == 0) s.suggest(tf, if (pps and sps and vps) s.LIKELY else s.POSSIBLE, s.caps(caps));
}

pub fn mpegVideo(tf: TF, _: ?*anyopaque) callconv(.c) void {
    var k = s.Scan{};
    var seq0 = false;
    var seq = false;
    var gop = false;
    var last_pic: u64 = 0;
    var pics: c.gint = 0;
    var found: c.gint = 0;
    while (k.offset < TRY_SYNC) {
        if (found >= TRY_PICTURES) break;
        if (!k.ensure(tf, 5)) break;
        if (isHeader(k.data)) {
            const code = k.data[3];
            if (code == 0xBA and validPack(k.data, k.size, null)) return;
            if (code == 0xB3) {
                seq0 = seq0 or k.offset == 0;
                seq = true;
                k.advance(12);
                continue;
            }
            if (code == 0xB8) {
                gop = true;
                k.advance(8);
                continue;
            }
            if (code == 0x00) {
                pics += 1;
                last_pic = k.offset;
                k.advance(8);
                continue;
            }
            const gap = k.offset -% last_pic;
            if (code == 0x01 and pics > found and gap >= 4 and gap <= 64) {
                k.advance(4);
                found += 1;
                continue;
            }
        }
        k.advance(1);
    }
    if (!(found > 0 or seq)) return;
    const many = found >= TRY_PICTURES;
    const prob: c.guint = if (many and seq and gop) s.NEARLY_CERTAIN - 1 else if (many and seq) s.NEARLY_CERTAIN - 9 else if (many) s.LIKELY else if (seq0 and gop and found > 2) s.LIKELY - 10 else if (seq and gop and found > 2) s.LIKELY - 20 else if (seq0 and found > 0) s.POSSIBLE else if (seq and found > 0) s.POSSIBLE - 5 else if (found > 0) s.POSSIBLE - 10 else if (seq) s.POSSIBLE - 20 else 0;
    c.gst_type_find_suggest_simple(tf, prob, "video/mpeg", "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), "mpegversion", c.G_TYPE_INT, @as(c.gint, 1), "parsed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), N);
}
