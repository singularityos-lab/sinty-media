const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn dump(w: *c.GstByteWriter, label: []const u8) void {
    var buf: [600]u8 = undefined;
    var n: usize = 0;
    const size: usize = w.parent.size;
    var i: usize = 0;
    while (i < size and n + 3 < buf.len) : (i += 1) {
        _ = std.fmt.bufPrint(buf[n..], "{x:0>2}", .{w.parent.data[i]}) catch break;
        n += 2;
    }
    out("{s}: size={d} pos={d} alloc={d} rem={d} [{s}]", .{ label, w.parent.size, w.parent.byte, w.alloc_size, @as(i64, @as(i32, @bitCast(c.gst_byte_writer_get_remaining(w)))), buf[0..n] });
}

pub fn main() void {
    c.gst_init(null, null);
    var w: c.GstByteWriter = undefined;
    c.gst_byte_writer_init(&w);
    dump(&w, "init");
    out("puts {d}{d}{d}{d}{d}{d}{d}{d}", .{ c.gst_byte_writer_put_uint8(&w, 0xab), c.gst_byte_writer_put_int8(&w, -2), c.gst_byte_writer_put_uint16_le(&w, 0x1234), c.gst_byte_writer_put_uint16_be(&w, 0x1234), c.gst_byte_writer_put_int16_le(&w, -3), c.gst_byte_writer_put_int16_be(&w, -3), c.gst_byte_writer_put_uint24_le(&w, 0x123456), c.gst_byte_writer_put_uint24_be(&w, 0x123456) });
    dump(&w, "a");
    out("puts {d}{d}{d}{d}{d}{d}", .{ c.gst_byte_writer_put_int24_le(&w, -5), c.gst_byte_writer_put_int24_be(&w, -5), c.gst_byte_writer_put_uint32_le(&w, 0xdeadbeef), c.gst_byte_writer_put_uint32_be(&w, 0xdeadbeef), c.gst_byte_writer_put_int32_le(&w, -7), c.gst_byte_writer_put_int32_be(&w, -7) });
    dump(&w, "b");
    out("puts {d}{d}{d}{d}", .{ c.gst_byte_writer_put_uint64_le(&w, 0x0102030405060708), c.gst_byte_writer_put_uint64_be(&w, 0x0102030405060708), c.gst_byte_writer_put_int64_le(&w, -9), c.gst_byte_writer_put_int64_be(&w, -9) });
    dump(&w, "c");
    out("floats {d}{d}{d}{d}", .{ c.gst_byte_writer_put_float32_le(&w, 1.5), c.gst_byte_writer_put_float32_be(&w, -2.25), c.gst_byte_writer_put_float64_le(&w, 3.14159), c.gst_byte_writer_put_float64_be(&w, 1e300) });
    dump(&w, "d");
    out("data {d} fill {d}", .{ c.gst_byte_writer_put_data(&w, "xyz", 3), c.gst_byte_writer_fill(&w, 0x5a, 5) });
    dump(&w, "e");
    out("strings {d} {d} {d}", .{ c.gst_byte_writer_put_string_utf8(&w, "hi"), c.gst_byte_writer_put_string_utf16(&w, &[_:0]u16{ 'a', 'b' }), c.gst_byte_writer_put_string_utf32(&w, &[_:0]u32{'z'}) });
    dump(&w, "f");
    w.parent.byte = 2;
    out("overwrite {d}", .{c.gst_byte_writer_put_uint16_be(&w, 0xffff)});
    dump(&w, "g");
    out("ensure {d}", .{c.gst_byte_writer_ensure_free_space(&w, 1000)});
    out("alloc {d}", .{w.alloc_size});
    const d = c.gst_byte_writer_reset_and_get_data(&w);
    out("got {x} {x}", .{ d[0], d[3] });
    c.g_free(d);
    dump(&w, "reset");

    c.gst_byte_writer_init_with_size(&w, 4, 1);
    out("fixed {d} {d} {d}", .{ c.gst_byte_writer_put_uint16_le(&w, 1), c.gst_byte_writer_put_uint32_le(&w, 2), c.gst_byte_writer_put_uint16_le(&w, 3) });
    dump(&w, "fixed");
    out("ensure fixed {d} {d}", .{ c.gst_byte_writer_ensure_free_space(&w, 0), c.gst_byte_writer_ensure_free_space(&w, 1) });
    const b = c.gst_byte_writer_reset_and_get_buffer(&w);
    out("buffer size {d}", .{c.gst_buffer_get_size(b)});
    c.gst_buffer_unref(b);

    var ext = [_]u8{ 1, 2, 3, 4, 5, 6 };
    c.gst_byte_writer_init_with_data(&w, &ext, ext.len, 1);
    dump(&w, "ext init");
    out("ext put {d}", .{c.gst_byte_writer_put_uint8(&w, 9)});
    w.parent.byte = 6;
    out("ext full {d} ensure {d}", .{ c.gst_byte_writer_put_uint8(&w, 9), c.gst_byte_writer_ensure_free_space(&w, 1) });
    const copy = c.gst_byte_writer_reset_and_get_data(&w);
    out("ext copy differs {d} first {d}", .{ @intFromBool(copy != @as([*c]u8, &ext)), copy[0] });
    c.g_free(copy);
    c.gst_byte_writer_init_with_data(&w, &ext, ext.len, 0);
    dump(&w, "ext uninit");
    c.gst_byte_writer_reset(&w);

    const h = c.gst_byte_writer_new();
    _ = c.gst_byte_writer_put_string_utf8(h, "heap");
    const hd = c.gst_byte_writer_free_and_get_data(h);
    out("heap {s}", .{std.mem.span(@as([*:0]u8, @ptrCast(hd)))});
    c.g_free(hd);
    const hs = c.gst_byte_writer_new_with_size(2, 0);
    out("grow {d} {d}", .{ c.gst_byte_writer_put_uint64_be(hs, 7), hs[0].alloc_size });
    const hb = c.gst_byte_writer_free_and_get_buffer(hs);
    out("grow buffer {d}", .{c.gst_buffer_get_size(hb)});
    c.gst_buffer_unref(hb);
    const hw = c.gst_byte_writer_new_with_data(&ext, 3, 0);
    out("hd {d} {d} {d}", .{ hw[0].parent.size, hw[0].fixed, hw[0].owned });
    c.gst_byte_writer_free(hw);
    const empty = c.gst_byte_writer_new();
    const eb = c.gst_byte_writer_free_and_get_buffer(empty);
    out("empty buffer {d} mems {d}", .{ c.gst_buffer_get_size(eb), c.gst_buffer_n_memory(eb) });
    c.gst_buffer_unref(eb);

    out("crit {d} {d} {d}", .{ c.gst_byte_writer_put_uint8(null, 1), c.gst_byte_writer_put_data(null, "a", 1), c.gst_byte_writer_fill(null, 1, 1) });
    out("crit rem {d}", .{@as(i32, @bitCast(c.gst_byte_writer_get_remaining(null)))});
    out("crit str {d}", .{c.gst_byte_writer_put_string_utf8(null, "x")});
    out("crit data {d} {d}", .{ @intFromBool(c.gst_byte_writer_reset_and_get_data(null) == null), @intFromBool(c.gst_byte_writer_free_and_get_buffer(null) == null) });
    c.gst_byte_writer_init(null);
    c.gst_byte_writer_init_with_size(null, 1, 0);
    c.gst_byte_writer_reset(null);
    c.gst_byte_writer_free(null);
    out("done", .{});
}
