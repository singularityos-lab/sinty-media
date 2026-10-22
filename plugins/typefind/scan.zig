const std = @import("std");
const cm = @import("../common.zig");
pub const c = cm.c;

pub const TF = [*c]c.GstTypeFind;

pub const NONE: c.guint = 0;
pub const MINIMUM: c.guint = 1;
pub const POSSIBLE: c.guint = 50;
pub const LIKELY: c.guint = 80;
pub const NEARLY_CERTAIN: c.guint = 99;
pub const MAXIMUM: c.guint = 100;

const CHUNK: c.guint = 4096;

pub fn peek(tf: TF, off: i64, size: c.guint) ?[*]const u8 {
    return @ptrCast(c.gst_type_find_peek(tf, off, size));
}

pub fn length(tf: TF) u64 {
    return c.gst_type_find_get_length(tf);
}

pub fn suggest(tf: TF, prob: c.guint, cp: [*c]c.GstCaps) void {
    c.gst_type_find_suggest(tf, prob, cp);
}

pub fn be16(p: [*]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .big);
}

pub fn be32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

pub fn le16(p: [*]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .little);
}

pub fn le32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}

pub fn be64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .big);
}

pub fn le64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .little);
}

pub fn eq(p: [*]const u8, comptime s: []const u8) bool {
    return std.mem.eql(u8, p[0..s.len], s);
}

pub fn Static(comptime s: [:0]const u8) type {
    return struct {
        var v = c.GstStaticCaps{ .caps = null, .string = s.ptr, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
        pub fn get() [*c]c.GstCaps {
            return c.gst_static_caps_get(&v);
        }
    };
}

pub fn caps(comptime s: [:0]const u8) [*c]c.GstCaps {
    return Static(s).get();
}

pub const Scan = struct {
    offset: u64 = 0,
    data: [*]const u8 = undefined,
    size: c.guint = 0,

    pub fn advance(s: *Scan, n: c.guint) void {
        s.offset +%= n;
        if (s.size > n) {
            s.size -= n;
            s.data += n;
        } else {
            s.data += s.size;
            s.size = 0;
        }
    }

    pub fn ensure(s: *Scan, tf: TF, min: c.guint) bool {
        const chunk = @max(CHUNK, min);
        if (s.size >= min) return true;
        if (peek(tf, @bitCast(s.offset), chunk)) |d| {
            s.data = d;
            s.size = chunk;
            return true;
        }
        var len = length(tf);
        len = if (len > 0) std.math.clamp(len -% s.offset, min, chunk) else min;
        if (peek(tf, @bitCast(s.offset), @truncate(len))) |d| {
            s.data = d;
            s.size = @truncate(len);
            return true;
        }
        return false;
    }

    pub fn memcmp(s: *Scan, tf: TF, off: c.guint, comptime str: []const u8) bool {
        if (@as(u64, off) + str.len >= std.math.maxInt(u32)) return false;
        if (!s.ensure(tf, off + @as(c.guint, str.len))) return false;
        return eq(s.data + off, str);
    }
};

pub fn isPrint(b: u8) bool {
    return b >= 0x20 and b < 0x7f;
}

pub fn isSpace(b: u8) bool {
    return b == ' ' or (b >= '\t' and b <= '\r');
}

pub fn isDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}

pub fn isAlpha(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

pub fn isAlnum(b: u8) bool {
    return isAlpha(b) or isDigit(b);
}

pub fn isXdigit(b: u8) bool {
    return isDigit(b) or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F');
}

pub fn lower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

pub fn caseEq(p: [*]const u8, comptime s: []const u8) bool {
    for (s, 0..) |ch, i| {
        if (lower(p[i]) != lower(ch)) return false;
    }
    return true;
}

pub fn find(p: [*]const u8, len: usize, ch: u8) ?usize {
    return std.mem.indexOfScalar(u8, p[0..len], ch);
}
