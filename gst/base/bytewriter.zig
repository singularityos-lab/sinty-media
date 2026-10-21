const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const reader = @import("bytereader.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Writer = c.GstByteWriter;
const NONE: c.guint = std.math.maxInt(c.guint);

fn data(w: [*c]Writer) [*c]u8 {
    return @constCast(w[0].parent.data);
}

fn nextPow2(n: c.guint) c.guint {
    var r: c.guint = 16;
    while (r < n and r > 0) r <<= 1;
    return if (r != 0) r else n;
}

fn ensure(w: [*c]Writer, size: c.guint) bool {
    if (size <= w[0].alloc_size -% w[0].parent.byte) return true;
    if (w[0].fixed != 0 or w[0].owned == 0) return false;
    if (w[0].parent.byte > NONE - size) return false;
    w[0].alloc_size = nextPow2(w[0].parent.byte + size);
    const p = c.g_try_realloc(@constCast(w[0].parent.data), w[0].alloc_size) orelse return false;
    w[0].parent.data = @ptrCast(p);
    return true;
}

fn advance(w: [*c]Writer, n: c.guint) void {
    w[0].parent.byte += n;
    w[0].parent.size = @max(w[0].parent.size, w[0].parent.byte);
}

fn encode(comptime k: reader.Kind, p: [*]u8, v: k.T) void {
    const bits = k.bytes * 8;
    const U = std.meta.Int(.unsigned, @bitSizeOf(k.T));
    const u: u64 = @as(U, @bitCast(v));
    for (0..k.bytes) |i| {
        const shift: u6 = @intCast(if (k.big) bits - 8 - 8 * i else 8 * i);
        p[i] = @truncate(u >> shift);
    }
}

fn putter(comptime k: reader.Kind) type {
    return struct {
        fn put(w: [*c]Writer, v: k.T) callconv(.c) c.gboolean {
            if (!check.that(w != null, "_gst_byte_writer_put_" ++ k.name ++ "_inline", "writer != NULL")) return 0;
            if (!ensure(w, k.bytes)) return 0;
            encode(k, data(w) + w[0].parent.byte, v);
            advance(w, k.bytes);
            return 1;
        }
    };
}

comptime {
    for (reader.KINDS) |k| @export(&putter(k).put, .{ .name = "gst_byte_writer_put_" ++ k.name });
}

pub export fn gst_byte_writer_new() [*c]Writer {
    const w: [*c]Writer = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Writer))));
    w[0].owned = 1;
    return w;
}

pub export fn gst_byte_writer_new_with_size(size: c.guint, fixed: c.gboolean) [*c]Writer {
    const w = gst_byte_writer_new();
    w[0].alloc_size = size;
    w[0].parent.data = @ptrCast(c.g_malloc(size));
    w[0].fixed = fixed;
    return w;
}

pub export fn gst_byte_writer_new_with_data(d: [*c]u8, size: c.guint, initialized: c.gboolean) [*c]Writer {
    const w = gst_byte_writer_new();
    w[0].parent.data = d;
    w[0].parent.size = if (initialized != 0) size else 0;
    w[0].alloc_size = size;
    w[0].fixed = 1;
    w[0].owned = 0;
    return w;
}

pub export fn gst_byte_writer_init(w: [*c]Writer) void {
    if (!check.that(w != null, "gst_byte_writer_init", "writer != NULL")) return;
    w[0] = std.mem.zeroes(Writer);
    w[0].owned = 1;
}

pub export fn gst_byte_writer_init_with_size(w: [*c]Writer, size: c.guint, fixed: c.gboolean) void {
    if (!check.that(w != null, "gst_byte_writer_init_with_size", "writer != NULL")) return;
    gst_byte_writer_init(w);
    w[0].parent.data = @ptrCast(c.g_malloc(size));
    w[0].alloc_size = size;
    w[0].fixed = fixed;
}

pub export fn gst_byte_writer_init_with_data(w: [*c]Writer, d: [*c]u8, size: c.guint, initialized: c.gboolean) void {
    if (!check.that(w != null, "gst_byte_writer_init_with_data", "writer != NULL")) return;
    gst_byte_writer_init(w);
    w[0].parent.data = d;
    w[0].parent.size = if (initialized != 0) size else 0;
    w[0].alloc_size = size;
    w[0].fixed = 1;
    w[0].owned = 0;
}

pub export fn gst_byte_writer_reset(w: [*c]Writer) void {
    if (!check.that(w != null, "gst_byte_writer_reset", "writer != NULL")) return;
    if (w[0].owned != 0) c.g_free(@constCast(w[0].parent.data));
    w[0] = std.mem.zeroes(Writer);
}

pub export fn gst_byte_writer_reset_and_get_data(w: [*c]Writer) [*c]u8 {
    if (!check.that(w != null, "gst_byte_writer_reset_and_get_data", "writer != NULL")) return null;
    var d = data(w);
    if (w[0].owned == 0) d = @ptrCast(c.g_memdup2(d, w[0].parent.size));
    w[0].parent.data = null;
    gst_byte_writer_reset(w);
    return d;
}

pub export fn gst_byte_writer_reset_and_get_buffer(w: [*c]Writer) [*c]c.GstBuffer {
    if (!check.that(w != null, "gst_byte_writer_reset_and_get_buffer", "writer != NULL")) return null;
    const size = w[0].parent.size;
    const d = gst_byte_writer_reset_and_get_data(w);
    const b = c.gst_buffer_new();
    if (d != null) c.gst_buffer_append_memory(b, c.gst_memory_new_wrapped(0, d, size, 0, size, d, c.g_free));
    return b;
}

pub export fn gst_byte_writer_free(w: [*c]Writer) void {
    if (!check.that(w != null, "gst_byte_writer_free", "writer != NULL")) return;
    gst_byte_writer_reset(w);
    c.g_free(w);
}

pub export fn gst_byte_writer_free_and_get_data(w: [*c]Writer) [*c]u8 {
    if (!check.that(w != null, "gst_byte_writer_free_and_get_data", "writer != NULL")) return null;
    const d = gst_byte_writer_reset_and_get_data(w);
    c.g_free(w);
    return d;
}

pub export fn gst_byte_writer_free_and_get_buffer(w: [*c]Writer) [*c]c.GstBuffer {
    if (!check.that(w != null, "gst_byte_writer_free_and_get_buffer", "writer != NULL")) return null;
    const b = gst_byte_writer_reset_and_get_buffer(w);
    c.g_free(w);
    return b;
}

pub export fn gst_byte_writer_get_remaining(w: [*c]const Writer) c.guint {
    if (!check.that(w != null, "gst_byte_writer_get_remaining", "writer != NULL")) return NONE;
    if (w[0].fixed == 0) return NONE;
    return w[0].alloc_size - w[0].parent.byte;
}

pub export fn gst_byte_writer_ensure_free_space(w: [*c]Writer, size: c.guint) c.gboolean {
    return @intFromBool(ensure(w, size));
}

pub export fn gst_byte_writer_put_data(w: [*c]Writer, d: [*c]const u8, size: c.guint) c.gboolean {
    if (!check.that(w != null, "_gst_byte_writer_put_data_inline", "writer != NULL")) return 0;
    if (!ensure(w, size)) return 0;
    if (size > 0) @memcpy((data(w) + w[0].parent.byte)[0..size], d[0..size]);
    advance(w, size);
    return 1;
}

pub export fn gst_byte_writer_fill(w: [*c]Writer, value: u8, size: c.guint) c.gboolean {
    if (!check.that(w != null, "_gst_byte_writer_fill_inline", "writer != NULL")) return 0;
    if (!ensure(w, size)) return 0;
    if (size > 0) @memset((data(w) + w[0].parent.byte)[0..size], value);
    advance(w, size);
    return 1;
}

fn stringPutter(comptime T: type, comptime bits: []const u8) type {
    return struct {
        fn put(w: [*c]Writer, s: [*c]const T) callconv(.c) c.gboolean {
            if (!check.that(w != null, "gst_byte_writer_put_string_utf" ++ bits, "writer != NULL")) return 0;
            var n: c.guint = 0;
            while (s[n] != 0) {
                if (n == NONE) return 0;
                n += 1;
            }
            n += 1;
            const bytes = n *% @sizeOf(T);
            if (!ensure(w, bytes)) return 0;
            @memcpy((data(w) + w[0].parent.byte)[0..bytes], @as([*]const u8, @ptrCast(s))[0..bytes]);
            advance(w, bytes);
            return 1;
        }
    };
}

comptime {
    for (.{ .{ u8, "8" }, .{ u16, "16" }, .{ u32, "32" } }) |s| @export(&stringPutter(s[0], s[1]).put, .{ .name = "gst_byte_writer_put_string_utf" ++ s[1] });
}
