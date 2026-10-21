const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Reader = c.GstByteReader;

fn remaining(r: *const Reader) c.guint {
    return r.size - r.byte;
}

const Kind = struct {
    name: []const u8,
    T: type,
    bytes: comptime_int,
    big: bool,
};

const KINDS = [_]Kind{
    .{ .name = "uint8", .T = u8, .bytes = 1, .big = false },
    .{ .name = "int8", .T = i8, .bytes = 1, .big = false },
    .{ .name = "uint16_le", .T = u16, .bytes = 2, .big = false },
    .{ .name = "uint16_be", .T = u16, .bytes = 2, .big = true },
    .{ .name = "int16_le", .T = i16, .bytes = 2, .big = false },
    .{ .name = "int16_be", .T = i16, .bytes = 2, .big = true },
    .{ .name = "uint24_le", .T = u32, .bytes = 3, .big = false },
    .{ .name = "uint24_be", .T = u32, .bytes = 3, .big = true },
    .{ .name = "int24_le", .T = i32, .bytes = 3, .big = false },
    .{ .name = "int24_be", .T = i32, .bytes = 3, .big = true },
    .{ .name = "uint32_le", .T = u32, .bytes = 4, .big = false },
    .{ .name = "uint32_be", .T = u32, .bytes = 4, .big = true },
    .{ .name = "int32_le", .T = i32, .bytes = 4, .big = false },
    .{ .name = "int32_be", .T = i32, .bytes = 4, .big = true },
    .{ .name = "uint64_le", .T = u64, .bytes = 8, .big = false },
    .{ .name = "uint64_be", .T = u64, .bytes = 8, .big = true },
    .{ .name = "int64_le", .T = i64, .bytes = 8, .big = false },
    .{ .name = "int64_be", .T = i64, .bytes = 8, .big = true },
    .{ .name = "float32_le", .T = f32, .bytes = 4, .big = false },
    .{ .name = "float32_be", .T = f32, .bytes = 4, .big = true },
    .{ .name = "float64_le", .T = f64, .bytes = 8, .big = false },
    .{ .name = "float64_be", .T = f64, .bytes = 8, .big = true },
};

pub fn decode(comptime k: Kind, p: [*]const u8) k.T {
    var v: u64 = 0;
    for (0..k.bytes) |i| {
        const b: u64 = p[if (k.big) i else k.bytes - 1 - i];
        v = (v << 8) | b;
    }
    return switch (@typeInfo(k.T)) {
        .float => |f| @bitCast(@as(std.meta.Int(.unsigned, f.bits), @intCast(v))),
        .int => |i| blk: {
            const U = std.meta.Int(.unsigned, i.bits);
            var u: U = @intCast(v);
            if (i.signedness == .signed and k.bytes == 3 and u & 0x00800000 != 0) u |= 0xff000000;
            break :blk @bitCast(u);
        },
        else => unreachable,
    };
}

fn accessors(comptime k: Kind) type {
    return struct {
        fn peek(r: [*c]const Reader, v: [*c]k.T) callconv(.c) c.gboolean {
            if (!check.that(r != null, "_gst_byte_reader_peek_" ++ k.name ++ "_inline", "reader != NULL")) return 0;
            if (!check.that(v != null, "_gst_byte_reader_peek_" ++ k.name ++ "_inline", "val != NULL")) return 0;
            if (remaining(r) < k.bytes) return 0;
            v.* = decode(k, r[0].data + r[0].byte);
            return 1;
        }
        fn get(r: [*c]Reader, v: [*c]k.T) callconv(.c) c.gboolean {
            if (!check.that(r != null, "_gst_byte_reader_get_" ++ k.name ++ "_inline", "reader != NULL")) return 0;
            if (!check.that(v != null, "_gst_byte_reader_get_" ++ k.name ++ "_inline", "val != NULL")) return 0;
            if (remaining(r) < k.bytes) return 0;
            v.* = decode(k, r[0].data + r[0].byte);
            r[0].byte += k.bytes;
            return 1;
        }
    };
}

comptime {
    for (KINDS) |k| {
        const a = accessors(k);
        @export(&a.peek, .{ .name = "gst_byte_reader_peek_" ++ k.name });
        @export(&a.get, .{ .name = "gst_byte_reader_get_" ++ k.name });
    }
}

pub export fn gst_byte_reader_new(data: [*c]const u8, size: c.guint) [*c]Reader {
    const r: [*c]Reader = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Reader))));
    r[0].data = data;
    r[0].size = size;
    return r;
}

pub export fn gst_byte_reader_free(r: [*c]Reader) void {
    if (!check.that(r != null, "gst_byte_reader_free", "reader != NULL")) return;
    c.g_free(r);
}

pub export fn gst_byte_reader_init(r: [*c]Reader, data: [*c]const u8, size: c.guint) void {
    if (!check.that(r != null, "gst_byte_reader_init", "reader != NULL")) return;
    r[0].data = data;
    r[0].size = size;
    r[0].byte = 0;
}

fn peekSub(r: [*c]Reader, sub: [*c]Reader, size: c.guint) bool {
    if (!check.that(r != null, "_gst_byte_reader_peek_sub_reader_inline", "reader != NULL")) return false;
    if (!check.that(sub != null, "_gst_byte_reader_peek_sub_reader_inline", "sub_reader != NULL")) return false;
    if (remaining(r) < size) return false;
    sub[0].data = r[0].data + r[0].byte;
    sub[0].byte = 0;
    sub[0].size = size;
    return true;
}

pub export fn gst_byte_reader_peek_sub_reader(r: [*c]Reader, sub: [*c]Reader, size: c.guint) c.gboolean {
    return @intFromBool(peekSub(r, sub, size));
}

pub export fn gst_byte_reader_get_sub_reader(r: [*c]Reader, sub: [*c]Reader, size: c.guint) c.gboolean {
    if (!peekSub(r, sub, size)) return 0;
    r[0].byte += size;
    return 1;
}

pub export fn gst_byte_reader_set_pos(r: [*c]Reader, pos: c.guint) c.gboolean {
    if (!check.that(r != null, "gst_byte_reader_set_pos", "reader != NULL")) return 0;
    if (pos > r[0].size) return 0;
    r[0].byte = pos;
    return 1;
}

pub export fn gst_byte_reader_get_pos(r: [*c]const Reader) c.guint {
    if (!check.that(r != null, "_gst_byte_reader_get_pos_inline", "reader != NULL")) return 0;
    return r[0].byte;
}

pub export fn gst_byte_reader_get_remaining(r: [*c]const Reader) c.guint {
    if (!check.that(r != null, "_gst_byte_reader_get_remaining_inline", "reader != NULL")) return 0;
    return remaining(r);
}

pub export fn gst_byte_reader_get_size(r: [*c]const Reader) c.guint {
    if (!check.that(r != null, "_gst_byte_reader_get_size_inline", "reader != NULL")) return 0;
    return r[0].size;
}

pub export fn gst_byte_reader_skip(r: [*c]Reader, n: c.guint) c.gboolean {
    if (!check.that(r != null, "_gst_byte_reader_skip_inline", "reader != NULL")) return 0;
    if (remaining(r) < n) return 0;
    r[0].byte += n;
    return 1;
}

fn dataOk(r: [*c]const Reader, size: c.guint, v: anytype, comptime func: []const u8) bool {
    if (!check.that(r != null, func, "reader != NULL")) return false;
    if (!check.that(v != null, func, "val != NULL")) return false;
    return size <= r[0].size and remaining(r) >= size;
}

pub export fn gst_byte_reader_get_data(r: [*c]Reader, size: c.guint, v: [*c][*c]const u8) c.gboolean {
    if (!dataOk(r, size, v, "_gst_byte_reader_get_data_inline")) return 0;
    v.* = r[0].data + r[0].byte;
    r[0].byte += size;
    return 1;
}

pub export fn gst_byte_reader_peek_data(r: [*c]const Reader, size: c.guint, v: [*c][*c]const u8) c.gboolean {
    if (!dataOk(r, size, v, "_gst_byte_reader_peek_data_inline")) return 0;
    v.* = r[0].data + r[0].byte;
    return 1;
}

pub export fn gst_byte_reader_dup_data(r: [*c]Reader, size: c.guint, v: [*c][*c]u8) c.gboolean {
    if (!dataOk(r, size, v, "_gst_byte_reader_dup_data_inline")) return 0;
    const out: [*c]u8 = @ptrCast(c.g_malloc(size));
    if (size > 0) @memcpy(out[0..size], (r[0].data + r[0].byte)[0..size]);
    r[0].byte += size;
    v.* = out;
    return 1;
}

fn startCode(data: [*]const u8, size: c.guint) c.gint {
    var i: usize = 0;
    const last = size - 4;
    while (i <= last) {
        if (data[i + 2] > 1) {
            i += 3;
        } else if (data[i + 1] != 0) {
            i += 2;
        } else if (data[i] != 0 or data[i + 2] != 1) {
            i += 1;
        } else {
            return @intCast(i);
        }
    }
    return -1;
}

fn maskedScan(r: [*c]const Reader, mask: c.guint32, pattern: c.guint32, offset: c.guint, size: c.guint, value: [*c]c.guint32) c.guint {
    const fail: c.guint = @bitCast(@as(c.gint, -1));
    if (!check.that(size > 0, "_masked_scan_uint32_peek", "size > 0")) return fail;
    if (!check.that(@as(u64, offset) + size <= r[0].size - r[0].byte, "_masked_scan_uint32_peek", "(guint64) offset + size <= reader->size - reader->byte")) return fail;
    if (size < 4) return fail;
    const data = r[0].data + r[0].byte + offset;
    if (pattern == 0x00000100 and mask == 0xffffff00) {
        const at = startCode(data, size);
        if (at < 0) return fail;
        const i: usize = @intCast(at);
        if (value != null) value.* = (1 << 8) | @as(c.guint32, data[i + 3]);
        return @as(c.guint, @intCast(at)) + offset;
    }
    var state: c.guint32 = ~pattern;
    for (0..size) |i| {
        state = (state << 8) | data[i];
        if (state & mask == pattern and i >= 3) {
            if (value != null) value.* = state;
            return offset + @as(c.guint, @intCast(i)) - 3;
        }
    }
    return fail;
}

pub export fn gst_byte_reader_masked_scan_uint32(r: [*c]const Reader, mask: c.guint32, pattern: c.guint32, offset: c.guint, size: c.guint) c.guint {
    return maskedScan(r, mask, pattern, offset, size, null);
}

pub export fn gst_byte_reader_masked_scan_uint32_peek(r: [*c]const Reader, mask: c.guint32, pattern: c.guint32, offset: c.guint, size: c.guint, value: [*c]c.guint32) c.guint {
    return maskedScan(r, mask, pattern, offset, size, value);
}

fn scan(comptime T: type, r: [*c]const Reader) c.guint {
    const w = @sizeOf(T);
    const max = remaining(r) / w;
    if (max < 1) return 0;
    var len: c.guint = 0;
    var off: usize = r[0].byte;
    while (true) {
        var v: u64 = 0;
        for (0..w) |i| v |= @as(u64, r[0].data[off + i]) << @intCast(8 * i);
        if (v == 0) break;
        len += 1;
        off += w;
        if (len == max) return 0;
    }
    return (len + 1) * w;
}

fn strings(comptime T: type, comptime bits: []const u8) type {
    return struct {
        fn skip(r: [*c]Reader) callconv(.c) c.gboolean {
            if (!check.that(r != null, "gst_byte_reader_skip_string_utf" ++ bits, "reader != NULL")) return 0;
            const n = scan(T, r);
            r[0].byte += n;
            return @intFromBool(n > 0);
        }
        fn dup(r: [*c]Reader, out: [*c][*c]T) callconv(.c) c.gboolean {
            if (!check.that(r != null, "gst_byte_reader_dup_string_utf" ++ bits, "reader != NULL")) return 0;
            if (!check.that(out != null, "gst_byte_reader_dup_string_utf" ++ bits, "str != NULL")) return 0;
            const n = scan(T, r);
            if (n == 0) {
                out.* = null;
                return 0;
            }
            out.* = @ptrCast(@alignCast(c.g_memdup2(r[0].data + r[0].byte, n)));
            r[0].byte += n;
            return 1;
        }
    };
}

comptime {
    for (.{ .{ u8, "8" }, .{ u16, "16" }, .{ u32, "32" } }) |s| {
        const f = strings(s[0], s[1]);
        @export(&f.skip, .{ .name = "gst_byte_reader_skip_string_utf" ++ s[1] });
        @export(&f.dup, .{ .name = "gst_byte_reader_dup_string_utf" ++ s[1] });
    }
}

pub export fn gst_byte_reader_peek_string_utf8(r: [*c]const Reader, out: [*c][*c]const u8) c.gboolean {
    if (!check.that(r != null, "gst_byte_reader_peek_string_utf8", "reader != NULL")) return 0;
    if (!check.that(out != null, "gst_byte_reader_peek_string_utf8", "str != NULL")) return 0;
    out.* = if (scan(u8, r) > 0) r[0].data + r[0].byte else null;
    return @intFromBool(out.* != null);
}

pub export fn gst_byte_reader_get_string_utf8(r: [*c]Reader, out: [*c][*c]const u8) c.gboolean {
    if (!check.that(r != null, "gst_byte_reader_get_string_utf8", "reader != NULL")) return 0;
    if (!check.that(out != null, "gst_byte_reader_get_string_utf8", "str != NULL")) return 0;
    const n = scan(u8, r);
    if (n == 0) {
        out.* = null;
        return 0;
    }
    out.* = r[0].data + r[0].byte;
    r[0].byte += n;
    return 1;
}
