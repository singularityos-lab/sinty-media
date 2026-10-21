const c = @import("../c.zig").c;

pub const Info = c.GstVideoFormatInfo;
pub const Data = [*c]const c.gpointer;
pub const Stride = [*c]const c.gint;
pub const DataOut = [*c]c.gpointer;
pub const Flags = c.GstVideoPackFlags;

pub const INTERLACED: Flags = c.GST_VIDEO_PACK_FLAG_INTERLACED;
pub const TRUNCATE: Flags = c.GST_VIDEO_PACK_FLAG_TRUNCATE_RANGE;

pub fn offset(p: anytype, off: isize) [*]u8 {
    return @ptrFromInt(@intFromPtr(p) +% @as(usize, @bitCast(off)));
}

pub fn plane(data: anytype, stride: Stride, k: usize, line: c.gint) [*]u8 {
    return offset(data[k], @as(isize, stride[k]) * line);
}

pub fn comp(info: [*c]const Info, data: anytype, stride: Stride, k: usize, line: c.gint) [*]u8 {
    const p = info[0].plane[k];
    return offset(data[p], @as(isize, info[0].poffset[k]) + @as(isize, stride[p]) * line);
}

pub fn uv420(y: c.gint, flags: Flags) c.gint {
    return if (flags & INTERLACED != 0) ((y & ~@as(c.gint, 3)) >> 1) + (y & 1) else y >> 1;
}

pub fn uv410(y: c.gint, flags: Flags) c.gint {
    return if (flags & INTERLACED != 0) ((y & ~@as(c.gint, 7)) >> 2) + (y & 1) else y >> 2;
}

pub fn chroma420(y: c.gint, flags: Flags) bool {
    return if (flags & INTERLACED != 0) y & 2 == 0 else y & 1 == 0;
}

pub fn chroma410(y: c.gint, flags: Flags) bool {
    return if (flags & INTERLACED != 0) y & 6 == 0 else y & 3 == 0;
}

pub fn n(w: c.gint) usize {
    return @intCast(@max(w, 0));
}

pub fn rd16le(p: [*]const u8) u16 {
    return @as(u16, p[0]) | @as(u16, p[1]) << 8;
}

pub fn rd16be(p: [*]const u8) u16 {
    return @as(u16, p[1]) | @as(u16, p[0]) << 8;
}

pub fn wr16le(p: [*]u8, v: u16) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

pub fn wr16be(p: [*]u8, v: u16) void {
    p[1] = @truncate(v);
    p[0] = @truncate(v >> 8);
}

pub fn rd32le(p: [*]const u8) u32 {
    return @as(u32, p[0]) | @as(u32, p[1]) << 8 | @as(u32, p[2]) << 16 | @as(u32, p[3]) << 24;
}

pub fn wr32le(p: [*]u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}

pub fn rd32be(p: [*]const u8) u32 {
    return @as(u32, p[3]) | @as(u32, p[2]) << 8 | @as(u32, p[1]) << 16 | @as(u32, p[0]) << 24;
}

pub fn wr32be(p: [*]u8, v: u32) void {
    p[3] = @truncate(v);
    p[2] = @truncate(v >> 8);
    p[1] = @truncate(v >> 16);
    p[0] = @truncate(v >> 24);
}

pub fn u16s(p: anytype) [*]align(1) u16 {
    return @ptrCast(p);
}

pub fn bytes(p: anytype) [*]u8 {
    return @ptrCast(p);
}
