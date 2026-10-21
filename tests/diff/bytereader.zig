const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const DATA = [_]u8{ 0x01, 0x82, 0x03, 0xf4, 0x05, 0x06, 0x87, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x3f, 0x80, 0x00, 0x00, 0x40, 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18 };

fn ints(r: *c.GstByteReader) void {
    var u8v: u8 = 0;
    var i8v: i8 = 0;
    var u16v: u16 = 0;
    var i16v: i16 = 0;
    var u32v: u32 = 0;
    var i32v: i32 = 0;
    var u64v: u64 = 0;
    var i64v: i64 = 0;
    var f32v: f32 = 0;
    var f64v: f64 = 0;
    out("u8 {d} {d}", .{ c.gst_byte_reader_peek_uint8(r, &u8v), u8v });
    out("i8 {d} {d}", .{ c.gst_byte_reader_peek_int8(r, &i8v), i8v });
    out("u16le {d} {d} be {d} {d}", .{ c.gst_byte_reader_peek_uint16_le(r, &u16v), u16v, c.gst_byte_reader_peek_uint16_be(r, &u16v), u16v });
    out("i16le {d} {d} be {d} {d}", .{ c.gst_byte_reader_peek_int16_le(r, &i16v), i16v, c.gst_byte_reader_peek_int16_be(r, &i16v), i16v });
    out("u24le {d} {d} be {d} {d}", .{ c.gst_byte_reader_peek_uint24_le(r, &u32v), u32v, c.gst_byte_reader_peek_uint24_be(r, &u32v), u32v });
    out("i24le {d} {d} be {d} {d}", .{ c.gst_byte_reader_peek_int24_le(r, &i32v), i32v, c.gst_byte_reader_peek_int24_be(r, &i32v), i32v });
    out("u32le {d} {d} be {d} {d}", .{ c.gst_byte_reader_peek_uint32_le(r, &u32v), u32v, c.gst_byte_reader_peek_uint32_be(r, &u32v), u32v });
    out("i32le {d} {d} be {d} {d}", .{ c.gst_byte_reader_peek_int32_le(r, &i32v), i32v, c.gst_byte_reader_peek_int32_be(r, &i32v), i32v });
    out("u64le {d} {d} be {d} {d}", .{ c.gst_byte_reader_peek_uint64_le(r, &u64v), u64v, c.gst_byte_reader_peek_uint64_be(r, &u64v), u64v });
    out("i64le {d} {d} be {d} {d}", .{ c.gst_byte_reader_peek_int64_le(r, &i64v), i64v, c.gst_byte_reader_peek_int64_be(r, &i64v), i64v });
    out("f32le {d} {e} be {d} {e}", .{ c.gst_byte_reader_peek_float32_le(r, &f32v), f32v, c.gst_byte_reader_peek_float32_be(r, &f32v), f32v });
    out("f64le {d} {e} be {d} {e}", .{ c.gst_byte_reader_peek_float64_le(r, &f64v), f64v, c.gst_byte_reader_peek_float64_be(r, &f64v), f64v });
}

pub fn main() void {
    c.gst_init(null, null);
    var r: c.GstByteReader = undefined;
    c.gst_byte_reader_init(&r, &DATA, DATA.len);
    out("size {d} pos {d} rem {d}", .{ c.gst_byte_reader_get_size(&r), c.gst_byte_reader_get_pos(&r), c.gst_byte_reader_get_remaining(&r) });
    var p: c.guint = 0;
    while (p <= DATA.len + 1) : (p += 3) {
        out("== pos {d} set {d}", .{ p, c.gst_byte_reader_set_pos(&r, p) });
        ints(&r);
    }
    _ = c.gst_byte_reader_set_pos(&r, 0);
    var v8: u8 = 0;
    var v16: u16 = 0;
    var v24: i32 = 0;
    var v32: u32 = 0;
    var v64: i64 = 0;
    var vf: f64 = 0;
    var vs: f32 = 0;
    out("gets {d} {d} {d} {d} {d}", .{ c.gst_byte_reader_get_uint8(&r, &v8), c.gst_byte_reader_get_uint16_be(&r, &v16), c.gst_byte_reader_get_int24_le(&r, &v24), c.gst_byte_reader_get_uint32_le(&r, &v32), c.gst_byte_reader_get_int64_be(&r, &v64) });
    out("  {d} {d} {d} {d} {d} pos {d}", .{ v8, v16, v24, v32, v64, c.gst_byte_reader_get_pos(&r) });
    out("float gets {d} {d} pos {d}", .{ c.gst_byte_reader_get_float32_be(&r, &vs), c.gst_byte_reader_get_float64_be(&r, &vf), c.gst_byte_reader_get_pos(&r) });
    out("skip {d} {d} pos {d}", .{ c.gst_byte_reader_skip(&r, 3), c.gst_byte_reader_skip(&r, 100), c.gst_byte_reader_get_pos(&r) });
    var sub: c.GstByteReader = undefined;
    _ = c.gst_byte_reader_set_pos(&r, 4);
    out("sub peek {d} size {d} pos {d}", .{ c.gst_byte_reader_peek_sub_reader(&r, &sub, 6), sub.size, c.gst_byte_reader_get_pos(&r) });
    out("sub get {d} size {d} first {d} pos {d}", .{ c.gst_byte_reader_get_sub_reader(&r, &sub, 5), sub.size, sub.data[0], c.gst_byte_reader_get_pos(&r) });
    out("sub too big {d}", .{c.gst_byte_reader_get_sub_reader(&r, &sub, 1000)});
    var d: [*c]const u8 = null;
    out("peek data {d} {d}", .{ c.gst_byte_reader_peek_data(&r, 2, &d), d[0] });
    out("get data {d} {d} pos {d}", .{ c.gst_byte_reader_get_data(&r, 2, &d), d[0], c.gst_byte_reader_get_pos(&r) });
    var dd: [*c]u8 = null;
    out("dup data {d} {d} {d}", .{ c.gst_byte_reader_dup_data(&r, 3, &dd), dd[0], dd[2] });
    c.g_free(dd);
    out("data too big {d} {d}", .{ c.gst_byte_reader_get_data(&r, 100, &d), c.gst_byte_reader_dup_data(&r, 100, &dd) });
    out("zero data {d}", .{c.gst_byte_reader_peek_data(&r, 0, &d)});

    const scan = [_]u8{ 0xff, 0x00, 0x00, 0x01, 0xb3, 0x12, 0x00, 0x00, 0x01, 0x09, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x00, 0x00, 0x01 };
    c.gst_byte_reader_init(&r, &scan, scan.len);
    var val: u32 = 0;
    for ([_]c.guint{ 0, 1, 2, 3, 4, 6, 10, 14 }) |off| {
        const n: c.guint = @intCast(scan.len - off);
        out("start code at {d}: {d} val {x}", .{ off, @as(i32, @bitCast(c.gst_byte_reader_masked_scan_uint32_peek(&r, 0xffffff00, 0x00000100, off, n, &val))), val });
        out("  generic {d}", .{@as(i32, @bitCast(c.gst_byte_reader_masked_scan_uint32(&r, 0xffffffff, 0x000001b3, off, n)))});
        out("  mask {d}", .{@as(i32, @bitCast(c.gst_byte_reader_masked_scan_uint32_peek(&r, 0x00ff00ff, 0x00cd0012, off, n, &val)))});
    }
    out("short {d}", .{@as(i32, @bitCast(c.gst_byte_reader_masked_scan_uint32(&r, 0xff, 1, 0, 3)))});
    out("crit size {d}", .{@as(i32, @bitCast(c.gst_byte_reader_masked_scan_uint32(&r, 0xff, 1, 0, 0)))});
    out("crit range {d}", .{@as(i32, @bitCast(c.gst_byte_reader_masked_scan_uint32(&r, 0xff, 1, 10, 100)))});

    const strs = "abc\x00\x00def";
    c.gst_byte_reader_init(&r, strs, strs.len);
    var s: [*c]const u8 = null;
    out("peek str {d} {s}", .{ c.gst_byte_reader_peek_string_utf8(&r, &s), std.mem.span(s) });
    out("get str {d} {s} pos {d}", .{ c.gst_byte_reader_get_string_utf8(&r, &s), std.mem.span(s), c.gst_byte_reader_get_pos(&r) });
    out("get empty {d} {s} pos {d}", .{ c.gst_byte_reader_get_string_utf8(&r, &s), std.mem.span(s), c.gst_byte_reader_get_pos(&r) });
    out("unterminated {d} null {d}", .{ c.gst_byte_reader_peek_string_utf8(&r, &s), @intFromBool(s == null) });
    out("skip unterminated {d} pos {d}", .{ c.gst_byte_reader_skip_string_utf8(&r), c.gst_byte_reader_get_pos(&r) });
    var ds: [*c]u8 = null;
    out("dup unterminated {d} {d}", .{ c.gst_byte_reader_dup_string_utf8(&r, &ds), @intFromBool(ds == null) });
    const w16 = [_]u8{ 'h', 0, 'i', 0, 0, 0, 'x', 0, 0, 0, 0, 0, 0, 0 };
    c.gst_byte_reader_init(&r, &w16, w16.len);
    var d16: [*c]u16 = null;
    out("dup16 {d} {d} {d} pos {d}", .{ c.gst_byte_reader_dup_string_utf16(&r, &d16), d16[0], d16[2], c.gst_byte_reader_get_pos(&r) });
    c.g_free(d16);
    out("skip16 {d} pos {d}", .{ c.gst_byte_reader_skip_string_utf16(&r), c.gst_byte_reader_get_pos(&r) });
    _ = c.gst_byte_reader_set_pos(&r, 0);
    out("skip32 {d} pos {d}", .{ c.gst_byte_reader_skip_string_utf32(&r), c.gst_byte_reader_get_pos(&r) });
    var d32: [*c]u32 = null;
    out("dup32 {d} pos {d}", .{ c.gst_byte_reader_dup_string_utf32(&r, &d32), c.gst_byte_reader_get_pos(&r) });
    c.g_free(d32);
    _ = c.gst_byte_reader_set_pos(&r, 13);
    out("skip32 tail {d}", .{c.gst_byte_reader_skip_string_utf32(&r)});

    const h = c.gst_byte_reader_new(&DATA, 4);
    out("new size {d} pos {d}", .{ h[0].size, h[0].byte });
    c.gst_byte_reader_free(h);

    out("crit get {d}", .{c.gst_byte_reader_get_uint32_le(null, &v32)});
    out("crit peek {d}", .{c.gst_byte_reader_peek_float64_be(&r, null)});
    out("crit pos {d} rem {d} size {d}", .{ c.gst_byte_reader_get_pos(null), c.gst_byte_reader_get_remaining(null), c.gst_byte_reader_get_size(null) });
    out("crit skip {d} set {d}", .{ c.gst_byte_reader_skip(null, 1), c.gst_byte_reader_set_pos(null, 1) });
    out("crit sub {d}", .{c.gst_byte_reader_peek_sub_reader(&r, null, 1)});
    out("crit data {d} {d}", .{ c.gst_byte_reader_get_data(null, 1, &d), c.gst_byte_reader_dup_data(&r, 1, null) });
    out("crit str {d} {d} {d}", .{ c.gst_byte_reader_get_string_utf8(&r, null), c.gst_byte_reader_skip_string_utf16(null), c.gst_byte_reader_dup_string_utf32(&r, null) });
    c.gst_byte_reader_init(null, &DATA, 1);
    c.gst_byte_reader_free(null);
    out("done", .{});
}
