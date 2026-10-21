const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Writer = c.GstBitWriter;
const MASK = [9]u8{ 0x00, 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff };
const ALIGN: u32 = 2047;

fn room(w: [*c]Writer, bits: u32) bool {
    var want = bits +% w[0].bit_size;
    std.debug.assert(w[0].bit_size <= w[0].bit_capacity);
    if (want <= w[0].bit_capacity) return true;
    if (w[0].auto_grow == 0) return false;
    want = (want + ALIGN) & ~ALIGN;
    const clear = (w[0].bit_size + 7) >> 3;
    w[0].data = @ptrCast(c.g_realloc(w[0].data, want >> 3));
    @memset(w[0].data[clear .. want >> 3], 0);
    w[0].bit_capacity = want;
    return true;
}

fn putBits(w: [*c]Writer, value: u64, count: c.guint) void {
    var n = count;
    var off = w[0].bit_size & 7;
    var cur = w[0].data + (w[0].bit_size >> 3);
    while (n != 0) {
        const fill = @min(8 - off, n);
        n -= fill;
        w[0].bit_size += fill;
        const part: u8 = @truncate((value >> @intCast(n)) & MASK[fill]);
        cur[0] |= part << @intCast(8 - off - fill);
        cur += 1;
        off = 0;
    }
}

fn putter(comptime T: type, comptime bits: []const u8) type {
    return struct {
        fn put(w: [*c]Writer, v: T, n: c.guint) callconv(.c) c.gboolean {
            const f = "_gst_bit_writer_put_bits_uint" ++ bits ++ "_inline";
            if (!check.that(w != null, f, "bitwriter != NULL")) return 0;
            if (!check.that(n != 0, f, "nbits != 0")) return 0;
            if (!check.that(n <= @bitSizeOf(T), f, "nbits <= " ++ bits)) return 0;
            if (!room(w, n)) return 0;
            putBits(w, v, n);
            return 1;
        }
    };
}

comptime {
    for (.{ .{ u8, "8" }, .{ u16, "16" }, .{ u32, "32" }, .{ u64, "64" } }) |s| @export(&putter(s[0], s[1]).put, .{ .name = "gst_bit_writer_put_bits_uint" ++ s[1] });
}

fn alloc() [*c]Writer {
    return @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Writer))));
}

pub export fn gst_bit_writer_new() [*c]Writer {
    const w = alloc();
    w[0].owned = 1;
    w[0].auto_grow = 1;
    return w;
}

pub export fn gst_bit_writer_new_with_size(size: c.guint32, fixed: c.gboolean) [*c]Writer {
    const w = alloc();
    gst_bit_writer_init_with_size(w, size, fixed);
    return w;
}

pub export fn gst_bit_writer_new_with_data(d: [*c]u8, size: c.guint, initialized: c.gboolean) [*c]Writer {
    const w = alloc();
    gst_bit_writer_init_with_data(w, d, size, initialized);
    return w;
}

pub export fn gst_bit_writer_init(w: [*c]Writer) void {
    if (!check.that(w != null, "gst_bit_writer_init", "bitwriter != NULL")) return;
    w[0] = std.mem.zeroes(Writer);
    w[0].owned = 1;
    w[0].auto_grow = 1;
}

pub export fn gst_bit_writer_init_with_size(w: [*c]Writer, size: c.guint32, fixed: c.gboolean) void {
    if (!check.that(w != null, "gst_bit_writer_init_with_size", "bitwriter != NULL")) return;
    gst_bit_writer_init(w);
    _ = room(w, size << 3);
    w[0].auto_grow = @intFromBool(fixed == 0);
}

pub export fn gst_bit_writer_init_with_data(w: [*c]Writer, d: [*c]u8, size: c.guint, initialized: c.gboolean) void {
    if (!check.that(w != null, "gst_bit_writer_init_with_data", "bitwriter != NULL")) return;
    gst_bit_writer_init(w);
    w[0].data = d;
    w[0].bit_capacity = size * 8;
    w[0].bit_size = if (initialized != 0) size << 3 else 0;
    w[0].auto_grow = 0;
    w[0].owned = 0;
}

pub export fn gst_bit_writer_reset(w: [*c]Writer) void {
    if (!check.that(w != null, "gst_bit_writer_reset", "bitwriter != NULL")) return;
    if (w[0].owned != 0) c.g_free(w[0].data);
    w[0] = std.mem.zeroes(Writer);
}

fn bytes(w: [*c]const Writer) c.guint {
    return ((w[0].bit_size + 7) & ~@as(c.guint, 7)) >> 3;
}

pub export fn gst_bit_writer_reset_and_get_data(w: [*c]Writer) [*c]u8 {
    if (!check.that(w != null, "gst_bit_writer_reset_and_get_data", "bitwriter != NULL")) return null;
    var d: [*c]u8 = null;
    if (w[0].bit_size != 0) {
        d = w[0].data;
        if (w[0].owned == 0) d = @ptrCast(c.g_memdup2(d, bytes(w)));
        w[0].data = null;
    }
    gst_bit_writer_reset(w);
    return d;
}

pub export fn gst_bit_writer_reset_and_get_buffer(w: [*c]Writer) [*c]c.GstBuffer {
    if (!check.that(w != null, "gst_bit_writer_reset_and_get_buffer", "bitwriter != NULL")) return null;
    const size = bytes(w);
    const d = gst_bit_writer_reset_and_get_data(w);
    const b = c.gst_buffer_new();
    if (d != null) c.gst_buffer_append_memory(b, c.gst_memory_new_wrapped(0, d, size, 0, size, d, c.g_free));
    return b;
}

pub export fn gst_bit_writer_free(w: [*c]Writer) void {
    if (!check.that(w != null, "gst_bit_writer_free", "bitwriter != NULL")) return;
    gst_bit_writer_reset(w);
    c.g_free(w);
}

pub export fn gst_bit_writer_free_and_get_data(w: [*c]Writer) [*c]u8 {
    if (!check.that(w != null, "gst_bit_writer_free_and_get_data", "bitwriter != NULL")) return null;
    const d = gst_bit_writer_reset_and_get_data(w);
    c.g_free(w);
    return d;
}

pub export fn gst_bit_writer_free_and_get_buffer(w: [*c]Writer) [*c]c.GstBuffer {
    if (!check.that(w != null, "gst_bit_writer_free_and_get_buffer", "bitwriter != NULL")) return null;
    const b = gst_bit_writer_reset_and_get_buffer(w);
    c.g_free(w);
    return b;
}

pub export fn gst_bit_writer_get_size(w: [*c]const Writer) c.guint {
    if (!check.that(w != null, "_gst_bit_writer_get_size_inline", "bitwriter != NULL")) return 0;
    return w[0].bit_size;
}

pub export fn gst_bit_writer_get_data(w: [*c]const Writer) [*c]u8 {
    if (!check.that(w != null, "_gst_bit_writer_get_data_inline", "bitwriter != NULL")) return null;
    return w[0].data;
}

pub export fn gst_bit_writer_set_pos(w: [*c]Writer, p: c.guint) c.gboolean {
    if (!check.that(w != null, "_gst_bit_writer_set_pos_inline", "bitwriter != NULL")) return 0;
    if (!check.that(p <= w[0].bit_capacity, "_gst_bit_writer_set_pos_inline", "pos <= bitwriter->bit_capacity")) return 0;
    w[0].bit_size = p;
    return 1;
}

pub export fn gst_bit_writer_put_bytes(w: [*c]Writer, d: [*c]const u8, n: c.guint) c.gboolean {
    if (!check.that(w != null, "_gst_bit_writer_put_bytes_inline", "bitwriter != NULL")) return 0;
    if (!check.that(d != null, "_gst_bit_writer_put_bytes_inline", "data != NULL")) return 0;
    if (!check.that(n != 0, "_gst_bit_writer_put_bytes_inline", "nbytes")) return 0;
    if (!room(w, n *% 8)) return 0;
    if (w[0].bit_size & 7 == 0) {
        const at = w[0].bit_size >> 3;
        @memcpy(w[0].data[at .. at + n], d[0..n]);
        w[0].bit_size += n << 3;
        return 1;
    }
    c.g_assertion_message_expr("GStreamer-Base", "../libs/gst/base/gstbitwriter.h", 244, "gst_bit_writer_put_bytes_unchecked", "0");
    return 0;
}

pub export fn gst_bit_writer_align_bytes(w: [*c]Writer, trailing: u8) c.gboolean {
    const f = "_gst_bit_writer_align_bytes_inline";
    if (!check.that(w != null, f, "bitwriter != NULL")) return 0;
    if (!check.that(trailing == 0 or trailing == 1, f, "(trailing_bit == 0 || trailing_bit == 1)")) return 0;
    if (!check.that(((w[0].bit_size + 7) & ~@as(c.guint, 7)) <= w[0].bit_capacity, f, "((bitwriter->bit_size + 7) & (~7)) <= bitwriter->bit_capacity")) return 0;
    const off = w[0].bit_size & 7;
    if (off == 0) return 1;
    const left = 8 - off;
    putBits(w, if (trailing != 0) MASK[left] else 0, left);
    return 1;
}
