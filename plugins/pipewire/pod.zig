const std = @import("std");

pub const ID: u32 = 3;
pub const INT: u32 = 4;
pub const RECTANGLE: u32 = 10;
pub const FRACTION: u32 = 11;
pub const OBJECT: u32 = 15;
pub const CHOICE: u32 = 19;

pub const CHOICE_NONE: u32 = 0;
pub const CHOICE_RANGE: u32 = 1;
pub const CHOICE_ENUM: u32 = 3;
pub const CHOICE_FLAGS: u32 = 4;

pub const OBJECT_FORMAT: u32 = 0x40003;
pub const OBJECT_BUFFERS: u32 = 0x40004;
pub const PARAM_ENUM_FORMAT: u32 = 3;
pub const PARAM_FORMAT: u32 = 4;
pub const PARAM_BUFFERS: u32 = 5;

pub const MEDIA_TYPE: u32 = 1;
pub const MEDIA_SUBTYPE: u32 = 2;
pub const TYPE_AUDIO: u32 = 1;
pub const TYPE_VIDEO: u32 = 2;
pub const SUBTYPE_RAW: u32 = 1;

pub const AUDIO_FORMAT: u32 = 0x10001;
pub const AUDIO_RATE: u32 = 0x10003;
pub const AUDIO_CHANNELS: u32 = 0x10004;
pub const VIDEO_FORMAT: u32 = 0x20001;
pub const VIDEO_SIZE: u32 = 0x20003;
pub const VIDEO_FRAMERATE: u32 = 0x20004;

pub const BUFFERS_DATATYPE: u32 = 6;
pub const DATA_MEMPTR: u32 = 1;
pub const DATA_MEMFD: u32 = 2;

pub const S16_LE: u32 = 259;
pub const S32_LE: u32 = 267;
pub const F32_LE: u32 = 283;

pub const Builder = struct {
    buf: []align(8) u8,
    len: usize = 0,
    ok: bool = true,
    stack: [8]usize = undefined,
    depth: usize = 0,

    fn put(b: *Builder, v: u32) void {
        if (b.len + 4 > b.buf.len) {
            b.ok = false;
            return;
        }
        std.mem.writeInt(u32, b.buf[b.len..][0..4], v, .little);
        b.len += 4;
    }

    fn pad(b: *Builder) void {
        while (b.len % 8 != 0) {
            if (b.len >= b.buf.len) {
                b.ok = false;
                return;
            }
            b.buf[b.len] = 0;
            b.len += 1;
        }
    }

    fn open(b: *Builder, kind: u32) void {
        b.stack[b.depth] = b.len;
        b.depth += 1;
        b.put(0);
        b.put(kind);
    }

    fn close(b: *Builder) void {
        b.depth -= 1;
        const at = b.stack[b.depth];
        if (b.ok) std.mem.writeInt(u32, b.buf[at..][0..4], @intCast(b.len - at - 8), .little);
        b.pad();
    }

    pub fn object(b: *Builder, kind: u32, param: u32) void {
        b.open(OBJECT);
        b.put(kind);
        b.put(param);
    }

    pub fn end(b: *Builder) void {
        b.close();
    }

    pub fn prop(b: *Builder, key: u32) void {
        b.put(key);
        b.put(0);
    }

    pub fn id(b: *Builder, v: u32) void {
        b.put(4);
        b.put(ID);
        b.put(v);
        b.pad();
    }

    pub fn choice(b: *Builder, kind: u32, child: u32, values: []const u32) void {
        const size: u32 = switch (child) {
            RECTANGLE, FRACTION => 8,
            else => 4,
        };
        b.open(CHOICE);
        b.put(kind);
        b.put(0);
        b.put(size);
        b.put(child);
        for (values) |v| b.put(v);
        b.close();
    }

    pub fn bytes(b: *Builder) ?[]align(8) u8 {
        if (!b.ok) return null;
        return b.buf[0..b.len];
    }
};

pub const Value = struct {
    kind: u32,
    data: []const u8,

    pub fn word(v: Value, i: usize) u32 {
        if (v.data.len < (i + 1) * 4) return 0;
        return std.mem.readInt(u32, v.data[i * 4 ..][0..4], .little);
    }
};

fn align8(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}

pub fn objectProp(pod: []const u8, key: u32) ?Value {
    if (pod.len < 16) return null;
    const size = std.mem.readInt(u32, pod[0..4], .little);
    if (std.mem.readInt(u32, pod[4..8], .little) != OBJECT) return null;
    const total = @min(pod.len, 8 + @as(usize, size));
    var p: usize = 16;
    while (p + 16 <= total) {
        const k = std.mem.readInt(u32, pod[p..][0..4], .little);
        const vs = std.mem.readInt(u32, pod[p + 8 ..][0..4], .little);
        const vt = std.mem.readInt(u32, pod[p + 12 ..][0..4], .little);
        const body = p + 16;
        if (body + vs > total) return null;
        if (k == key) return unchoice(.{ .kind = vt, .data = pod[body .. body + vs] });
        p = body + align8(vs);
    }
    return null;
}

fn unchoice(v: Value) Value {
    if (v.kind != CHOICE or v.data.len < 16) return v;
    const size = std.mem.readInt(u32, v.data[8..12], .little);
    const kind = std.mem.readInt(u32, v.data[12..16], .little);
    if (v.data.len < 16 + size) return .{ .kind = kind, .data = &.{} };
    return .{ .kind = kind, .data = v.data[16 .. 16 + size] };
}

test "an object with a choice and plain values reads back" {
    var mem: [256]u8 align(8) = undefined;
    var b = Builder{ .buf = &mem };
    b.object(OBJECT_FORMAT, PARAM_ENUM_FORMAT);
    b.prop(MEDIA_TYPE);
    b.id(TYPE_VIDEO);
    b.prop(VIDEO_FORMAT);
    b.choice(CHOICE_ENUM, ID, &.{ 8, 8, 7 });
    b.prop(VIDEO_SIZE);
    b.choice(CHOICE_RANGE, RECTANGLE, &.{ 640, 480, 1, 1, 8192, 8192 });
    b.end();
    const pod = b.bytes().?;
    try std.testing.expect(pod.len % 8 == 0);
    try std.testing.expectEqual(@as(u32, @intCast(pod.len - 8)), std.mem.readInt(u32, pod[0..4], .little));
    try std.testing.expectEqual(TYPE_VIDEO, objectProp(pod, MEDIA_TYPE).?.word(0));
    try std.testing.expectEqual(@as(u32, 8), objectProp(pod, VIDEO_FORMAT).?.word(0));
    const size = objectProp(pod, VIDEO_SIZE).?;
    try std.testing.expectEqual(RECTANGLE, size.kind);
    try std.testing.expectEqual(@as(u32, 480), size.word(1));
    try std.testing.expect(objectProp(pod, AUDIO_RATE) == null);
}

test "a builder that runs out of room reports it" {
    var mem: [16]u8 align(8) = undefined;
    var b = Builder{ .buf = &mem };
    b.object(OBJECT_FORMAT, PARAM_ENUM_FORMAT);
    b.prop(MEDIA_TYPE);
    b.id(TYPE_VIDEO);
    b.end();
    try std.testing.expect(b.bytes() == null);
}
