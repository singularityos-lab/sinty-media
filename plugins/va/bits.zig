const std = @import("std");

pub const Error = error{Truncated};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn bit(r: *Reader) Error!u1 {
        if (r.pos >= r.data.len * 8) return error.Truncated;
        const v: u1 = @intCast((r.data[r.pos >> 3] >> @intCast(7 - (r.pos & 7))) & 1);
        r.pos += 1;
        return v;
    }

    pub fn flag(r: *Reader) Error!bool {
        return try r.bit() == 1;
    }

    pub fn f(r: *Reader, n: u6) Error!u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | try r.bit();
        return v;
    }

    pub fn s(r: *Reader, n: u6) Error!i32 {
        const v: i32 = @intCast(try r.f(n));
        return if (try r.flag()) -v else v;
    }

    pub fn ue(r: *Reader) Error!u32 {
        var zeros: u6 = 0;
        while (!try r.flag()) {
            zeros += 1;
            if (zeros > 31) return error.Truncated;
        }
        if (zeros == 0) return 0;
        return ((@as(u32, 1) << @intCast(zeros)) - 1) + try r.f(zeros);
    }

    pub fn se(r: *Reader) Error!i32 {
        const k = try r.ue();
        const m: i32 = @intCast((k + 1) >> 1);
        return if (k & 1 == 1) m else -m;
    }

    pub fn moreData(r: *const Reader) bool {
        var end = r.data.len;
        while (end > 0 and r.data[end - 1] == 0) end -= 1;
        if (end == 0) return false;
        const last = r.data[end - 1];
        const stop = (end - 1) * 8 + (7 - @as(usize, @ctz(last)));
        return r.pos < stop;
    }

    pub fn bytes(r: *const Reader) usize {
        return (r.pos + 7) >> 3;
    }
};

test "bits are read most significant first" {
    var r = Reader{ .data = &.{ 0b1010_0000, 0xff } };
    try std.testing.expectEqual(@as(u32, 0b101), try r.f(3));
    try std.testing.expectEqual(@as(u32, 0), try r.f(5));
    try std.testing.expectEqual(@as(i32, -7), try r.s(3));
    try std.testing.expectEqual(@as(usize, 2), r.bytes());
    _ = try r.f(4);
    try std.testing.expectError(error.Truncated, r.bit());
}

test "exp-golomb codes decode" {
    var r = Reader{ .data = &.{ 0b1010_0110, 0b0100_1000 } };
    try std.testing.expectEqual(@as(u32, 0), try r.ue());
    try std.testing.expectEqual(@as(u32, 1), try r.ue());
    try std.testing.expectEqual(@as(i32, -1), try r.se());
    try std.testing.expectEqual(@as(u32, 3), try r.ue());
    try std.testing.expect(!r.moreData());
}
