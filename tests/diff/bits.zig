const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn hex(d: [*c]const u8, n: usize) void {
    var buf: [2048]u8 = undefined;
    var k: usize = 0;
    for (0..@min(n, 1000)) |i| {
        _ = std.fmt.bufPrint(buf[k..], "{x:0>2}", .{d[i]}) catch break;
        k += 2;
    }
    out("  [{s}]", .{buf[0..k]});
}

const DATA = [_]u8{ 0b10110011, 0b01011100, 0xff, 0x00, 0x81, 0x7e, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc };

pub fn main() void {
    c.gst_init(null, null);
    var r: c.GstBitReader = undefined;
    c.gst_bit_reader_init(&r, &DATA, DATA.len);
    out("size {d} pos {d} rem {d}", .{ c.gst_bit_reader_get_size(&r), c.gst_bit_reader_get_pos(&r), c.gst_bit_reader_get_remaining(&r) });
    var v8: u8 = 0;
    var v16: u16 = 0;
    var v32: u32 = 0;
    var v64: u64 = 0;
    for ([_]c.guint{ 1, 3, 5, 7, 8, 2, 0 }) |n| out("get8 {d}: {d} {d} pos {d}", .{ n, c.gst_bit_reader_get_bits_uint8(&r, &v8, n), v8, c.gst_bit_reader_get_pos(&r) });
    out("peek16 {d} {d}", .{ c.gst_bit_reader_peek_bits_uint16(&r, &v16, 13), v16 });
    out("get16 {d} {d}", .{ c.gst_bit_reader_get_bits_uint16(&r, &v16, 16), v16 });
    out("peek32 {d} {d}", .{ c.gst_bit_reader_peek_bits_uint32(&r, &v32, 27), v32 });
    out("get32 {d} {d}", .{ c.gst_bit_reader_get_bits_uint32(&r, &v32, 32), v32 });
    out("skip {d} pos {d}", .{ c.gst_bit_reader_skip(&r, 3), c.gst_bit_reader_get_pos(&r) });
    out("to byte {d} pos {d}", .{ c.gst_bit_reader_skip_to_byte(&r), c.gst_bit_reader_get_pos(&r) });
    out("to byte again {d} pos {d}", .{ c.gst_bit_reader_skip_to_byte(&r), c.gst_bit_reader_get_pos(&r) });
    out("peek64 {d} {d}", .{ c.gst_bit_reader_peek_bits_uint64(&r, &v64, 40), v64 });
    out("get64 too many {d}", .{c.gst_bit_reader_get_bits_uint64(&r, &v64, 64)});
    out("set {d} {d} {d}", .{ c.gst_bit_reader_set_pos(&r, 5), c.gst_bit_reader_set_pos(&r, 96), c.gst_bit_reader_set_pos(&r, 97) });
    out("end rem {d} get {d} to byte {d}", .{ c.gst_bit_reader_get_remaining(&r), c.gst_bit_reader_get_bits_uint8(&r, &v8, 1), c.gst_bit_reader_skip_to_byte(&r) });
    _ = c.gst_bit_reader_set_pos(&r, 0);
    out("get64 full {d} {d}", .{ c.gst_bit_reader_get_bits_uint64(&r, &v64, 64), v64 });
    out("skip too far {d}", .{c.gst_bit_reader_skip(&r, 33)});
    const h = c.gst_bit_reader_new(&DATA, 2);
    out("heap size {d}", .{c.gst_bit_reader_get_size(h)});
    c.gst_bit_reader_free(h);
    out("crit {d} {d} {d}", .{ c.gst_bit_reader_get_bits_uint8(&r, &v8, 9), c.gst_bit_reader_peek_bits_uint16(&r, null, 1), c.gst_bit_reader_get_bits_uint32(null, &v32, 1) });
    out("crit {d} {d} {d} {d} {d}", .{ c.gst_bit_reader_get_pos(null), c.gst_bit_reader_get_remaining(null), c.gst_bit_reader_get_size(null), c.gst_bit_reader_skip(null, 1), c.gst_bit_reader_skip_to_byte(null) });
    out("crit set {d}", .{c.gst_bit_reader_set_pos(null, 0)});
    c.gst_bit_reader_init(null, &DATA, 1);
    c.gst_bit_reader_free(null);

    var w: c.GstBitWriter = undefined;
    c.gst_bit_writer_init(&w);
    out("w init size {d} cap {d} grow {d} owned {d}", .{ c.gst_bit_writer_get_size(&w), w.bit_capacity, w.auto_grow, w.owned });
    out("puts {d}{d}{d}{d}", .{ c.gst_bit_writer_put_bits_uint8(&w, 0b101, 3), c.gst_bit_writer_put_bits_uint16(&w, 0x1abc, 13), c.gst_bit_writer_put_bits_uint32(&w, 0xdeadbeef, 32), c.gst_bit_writer_put_bits_uint64(&w, 0x123456789abcdef0, 61) });
    out("size {d} cap {d}", .{ c.gst_bit_writer_get_size(&w), w.bit_capacity });
    hex(c.gst_bit_writer_get_data(&w), (c.gst_bit_writer_get_size(&w) + 7) / 8);
    out("align {d} size {d}", .{ c.gst_bit_writer_align_bytes(&w, 1), c.gst_bit_writer_get_size(&w) });
    out("bytes {d} size {d}", .{ c.gst_bit_writer_put_bytes(&w, "ABC", 3), c.gst_bit_writer_get_size(&w) });
    out("put1 {d} align0 {d} size {d}", .{ c.gst_bit_writer_put_bits_uint8(&w, 1, 1), c.gst_bit_writer_align_bytes(&w, 0), c.gst_bit_writer_get_size(&w) });
    out("align aligned {d}", .{c.gst_bit_writer_align_bytes(&w, 1)});
    hex(c.gst_bit_writer_get_data(&w), (c.gst_bit_writer_get_size(&w) + 7) / 8);
    var i: usize = 0;
    while (i < 300) : (i += 1) _ = c.gst_bit_writer_put_bits_uint8(&w, @truncate(i), 7);
    out("grown size {d} cap {d}", .{ c.gst_bit_writer_get_size(&w), w.bit_capacity });
    out("setpos {d} {d}", .{ c.gst_bit_writer_set_pos(&w, 4), c.gst_bit_writer_get_size(&w) });
    out("over {d}", .{c.gst_bit_writer_put_bits_uint8(&w, 0xf, 4)});
    hex(c.gst_bit_writer_get_data(&w), 3);
    const d = c.gst_bit_writer_reset_and_get_data(&w);
    out("got {x}", .{d[0]});
    c.g_free(d);
    out("after reset size {d} cap {d} data null {d}", .{ w.bit_size, w.bit_capacity, @intFromBool(w.data == null) });

    c.gst_bit_writer_init_with_size(&w, 2, 1);
    out("fixed cap {d} grow {d}", .{ w.bit_capacity, w.auto_grow });
    out("fixed puts {d} {d} {d}", .{ c.gst_bit_writer_put_bits_uint16(&w, 0xffff, 16), c.gst_bit_writer_put_bytes(&w, "x", 1), c.gst_bit_writer_put_bits_uint8(&w, 1, 1) });
    out("fixed align {d}", .{c.gst_bit_writer_align_bytes(&w, 1)});
    const fb = c.gst_bit_writer_reset_and_get_buffer(&w);
    out("fixed buffer {d}", .{c.gst_buffer_get_size(fb)});
    c.gst_buffer_unref(fb);
    c.gst_bit_writer_init_with_size(&w, 1, 0);
    out("nofix cap {d} grow {d}", .{ w.bit_capacity, w.auto_grow });
    out("empty get data null {d}", .{@intFromBool(c.gst_bit_writer_reset_and_get_data(&w) == null)});

    var ext = [_]u8{ 0x0f, 0xf0, 0x00, 0x00 };
    c.gst_bit_writer_init_with_data(&w, &ext, ext.len, 0);
    out("ext size {d} cap {d}", .{ w.bit_size, w.bit_capacity });
    out("ext put {d}", .{c.gst_bit_writer_put_bits_uint8(&w, 0xa, 4)});
    hex(&ext, 4);
    const ec = c.gst_bit_writer_reset_and_get_data(&w);
    out("ext copy {x} differs {d}", .{ ec[0], @intFromBool(ec != @as([*c]u8, &ext)) });
    c.g_free(ec);
    c.gst_bit_writer_init_with_data(&w, &ext, ext.len, 1);
    out("ext init size {d} full put {d}", .{ w.bit_size, c.gst_bit_writer_put_bits_uint8(&w, 1, 1) });
    c.gst_bit_writer_reset(&w);

    const hw = c.gst_bit_writer_new();
    _ = c.gst_bit_writer_put_bits_uint8(hw, 0x3, 2);
    const hd = c.gst_bit_writer_free_and_get_data(hw);
    out("heap {x}", .{hd[0]});
    c.g_free(hd);
    const hs = c.gst_bit_writer_new_with_size(1, 0);
    _ = c.gst_bit_writer_put_bits_uint32(hs, 0x12345678, 32);
    const hb = c.gst_bit_writer_free_and_get_buffer(hs);
    out("heap buffer {d}", .{c.gst_buffer_get_size(hb)});
    c.gst_buffer_unref(hb);
    const hx = c.gst_bit_writer_new_with_data(&ext, 2, 1);
    out("heap ext size {d}", .{hx[0].bit_size});
    c.gst_bit_writer_free(hx);
    const he = c.gst_bit_writer_new();
    const heb = c.gst_bit_writer_free_and_get_buffer(he);
    out("empty buffer {d} {d}", .{ c.gst_buffer_get_size(heb), c.gst_buffer_n_memory(heb) });
    c.gst_buffer_unref(heb);

    c.gst_bit_writer_init(&w);
    out("crit {d} {d} {d} {d}", .{ c.gst_bit_writer_put_bits_uint8(&w, 1, 0), c.gst_bit_writer_put_bits_uint16(&w, 1, 17), c.gst_bit_writer_put_bits_uint64(null, 1, 1), c.gst_bit_writer_put_bytes(&w, null, 1) });
    out("crit {d} {d} {d}", .{ c.gst_bit_writer_put_bytes(&w, "a", 0), c.gst_bit_writer_align_bytes(&w, 2), c.gst_bit_writer_set_pos(&w, 100) });
    out("crit {d} {d}", .{ c.gst_bit_writer_get_size(null), @intFromBool(c.gst_bit_writer_get_data(null) == null) });
    _ = c.gst_bit_writer_put_bits_uint8(&w, 1, 3);
    w.bit_capacity = 4;
    out("crit align {d}", .{c.gst_bit_writer_align_bytes(&w, 0)});
    w.bit_capacity = 2048;
    c.gst_bit_writer_reset(&w);
    c.gst_bit_writer_init(null);
    c.gst_bit_writer_reset(null);
    c.gst_bit_writer_free(null);
    out("crit get {d} {d}", .{ @intFromBool(c.gst_bit_writer_reset_and_get_data(null) == null), @intFromBool(c.gst_bit_writer_free_and_get_buffer(null) == null) });
    out("done", .{});
}
