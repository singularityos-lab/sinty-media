const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Reader = c.GstBitReader;

fn pos(r: [*c]const Reader) c.guint {
    return r[0].byte * 8 + r[0].bit;
}

fn remaining(r: [*c]const Reader) c.guint {
    return r[0].size * 8 - pos(r);
}

fn advance(r: [*c]Reader, n: c.guint) void {
    r[0].bit += n;
    r[0].byte += r[0].bit / 8;
    r[0].bit %= 8;
}

fn peekBits(r: [*c]const Reader, count: c.guint) u64 {
    var v: u64 = 0;
    var byte = r[0].byte;
    var bit = r[0].bit;
    var n = count;
    while (n > 0) {
        const take = @min(n, 8 - bit);
        v <<= @intCast(take);
        v |= (@as(u64, r[0].data[byte]) & (@as(u64, 0xff) >> @intCast(bit))) >> @intCast(8 - take - bit);
        bit += take;
        if (bit >= 8) {
            byte += 1;
            bit = 0;
        }
        n -= take;
    }
    return v;
}

fn accessors(comptime T: type, comptime bits: []const u8) type {
    const width = @bitSizeOf(T);
    return struct {
        fn peek(r: [*c]const Reader, v: [*c]T, n: c.guint) callconv(.c) c.gboolean {
            const f = "_gst_bit_reader_peek_bits_uint" ++ bits ++ "_inline";
            if (!check.that(r != null, f, "reader != NULL")) return 0;
            if (!check.that(v != null, f, "val != NULL")) return 0;
            if (!check.that(n <= width, f, "nbits <= " ++ bits)) return 0;
            if (remaining(r) < n) return 0;
            v.* = @truncate(peekBits(r, n));
            return 1;
        }
        fn get(r: [*c]Reader, v: [*c]T, n: c.guint) callconv(.c) c.gboolean {
            const f = "_gst_bit_reader_get_bits_uint" ++ bits ++ "_inline";
            if (!check.that(r != null, f, "reader != NULL")) return 0;
            if (!check.that(v != null, f, "val != NULL")) return 0;
            if (!check.that(n <= width, f, "nbits <= " ++ bits)) return 0;
            if (remaining(r) < n) return 0;
            v.* = @truncate(peekBits(r, n));
            advance(r, n);
            return 1;
        }
    };
}

comptime {
    for (.{ .{ u8, "8" }, .{ u16, "16" }, .{ u32, "32" }, .{ u64, "64" } }) |s| {
        const a = accessors(s[0], s[1]);
        @export(&a.peek, .{ .name = "gst_bit_reader_peek_bits_uint" ++ s[1] });
        @export(&a.get, .{ .name = "gst_bit_reader_get_bits_uint" ++ s[1] });
    }
}

pub export fn gst_bit_reader_new(data: [*c]const u8, size: c.guint) [*c]Reader {
    const r: [*c]Reader = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Reader))));
    r[0].data = data;
    r[0].size = size;
    return r;
}

pub export fn gst_bit_reader_free(r: [*c]Reader) void {
    if (!check.that(r != null, "gst_bit_reader_free", "reader != NULL")) return;
    c.g_free(r);
}

pub export fn gst_bit_reader_init(r: [*c]Reader, data: [*c]const u8, size: c.guint) void {
    if (!check.that(r != null, "gst_bit_reader_init", "reader != NULL")) return;
    r[0].data = data;
    r[0].size = size;
    r[0].byte = 0;
    r[0].bit = 0;
}

pub export fn gst_bit_reader_set_pos(r: [*c]Reader, p: c.guint) c.gboolean {
    if (!check.that(r != null, "gst_bit_reader_set_pos", "reader != NULL")) return 0;
    if (p > r[0].size * 8) return 0;
    r[0].byte = p / 8;
    r[0].bit = p % 8;
    return 1;
}

pub export fn gst_bit_reader_get_pos(r: [*c]const Reader) c.guint {
    if (!check.that(r != null, "_gst_bit_reader_get_pos_inline", "reader != NULL")) return 0;
    return pos(r);
}

pub export fn gst_bit_reader_get_remaining(r: [*c]const Reader) c.guint {
    if (!check.that(r != null, "_gst_bit_reader_get_remaining_inline", "reader != NULL")) return 0;
    return remaining(r);
}

pub export fn gst_bit_reader_get_size(r: [*c]const Reader) c.guint {
    if (!check.that(r != null, "_gst_bit_reader_get_size_inline", "reader != NULL")) return 0;
    return r[0].size * 8;
}

pub export fn gst_bit_reader_skip(r: [*c]Reader, n: c.guint) c.gboolean {
    if (!check.that(r != null, "_gst_bit_reader_skip_inline", "reader != NULL")) return 0;
    if (remaining(r) < n) return 0;
    advance(r, n);
    return 1;
}

pub export fn gst_bit_reader_skip_to_byte(r: [*c]Reader) c.gboolean {
    if (!check.that(r != null, "_gst_bit_reader_skip_to_byte_inline", "reader != NULL")) return 0;
    if (r[0].byte > r[0].size) return 0;
    if (r[0].bit != 0) {
        r[0].bit = 0;
        r[0].byte += 1;
    }
    return 1;
}
