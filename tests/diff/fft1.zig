const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

var seed: u64 = 0x1234567;

fn rnd() u64 {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

fn crc(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

fn run(comptime T: type, comptime Cpx: type, comptime tag: []const u8, newf: anytype, fftf: anytype, invf: anytype, winf: anytype, freef: anytype, len: c_int, amp: f64) void {
    const n: usize = @intCast(len);
    const time = std.heap.c_allocator.alloc(T, n) catch return;
    defer std.heap.c_allocator.free(time);
    const freq = std.heap.c_allocator.alloc(Cpx, n / 2 + 1) catch return;
    defer std.heap.c_allocator.free(freq);
    for (time) |*x| {
        const r: f64 = @as(f64, @floatFromInt(rnd() % 20001)) / 10000.0 - 1.0;
        x.* = if (@typeInfo(T) == .int) @intFromFloat(r * amp) else @floatCast(r * amp);
    }
    const f = newf(len, 0);
    const inv = newf(len, 1);
    fftf(f, time.ptr, freq.ptr);
    const fc = crc(std.mem.sliceAsBytes(freq));
    invf(inv, freq.ptr, time.ptr);
    const tc = crc(std.mem.sliceAsBytes(time));
    var wc: [5]u32 = undefined;
    for (0..5) |w| {
        winf(f, time.ptr, @as(c.GstFFTWindow, @intCast(w)));
        wc[w] = crc(std.mem.sliceAsBytes(time));
    }
    out("{s} len={d} amp={d} fft={x:0>8} inv={x:0>8} win={x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{ tag, len, amp, fc, tc, wc[0], wc[1], wc[2], wc[3], wc[4] });
    freef(f);
    freef(inv);
}

pub fn main() void {
    c.gst_init(null, null);
    var lens: [200]c_int = undefined;
    var nl: usize = 0;
    var l: c_int = 2;
    while (l <= 130) : (l += 2) {
        lens[nl] = l;
        nl += 1;
    }
    for ([_]c_int{ 150, 154, 194, 198, 210, 242, 286, 338, 500, 512, 1000, 1022, 1024, 2310, 4096, 4802 }) |x| {
        lens[nl] = x;
        nl += 1;
    }
    for (lens[0..nl]) |len| {
        for ([_]f64{ 1000.0, 32767.0 }) |amp| run(i16, c.GstFFTS16Complex, "s16", c.gst_fft_s16_new, c.gst_fft_s16_fft, c.gst_fft_s16_inverse_fft, c.gst_fft_s16_window, c.gst_fft_s16_free, len, amp);
        for ([_]f64{ 1000000.0, 2147483647.0 }) |amp| run(i32, c.GstFFTS32Complex, "s32", c.gst_fft_s32_new, c.gst_fft_s32_fft, c.gst_fft_s32_inverse_fft, c.gst_fft_s32_window, c.gst_fft_s32_free, len, amp);
        run(f32, c.GstFFTF32Complex, "f32", c.gst_fft_f32_new, c.gst_fft_f32_fft, c.gst_fft_f32_inverse_fft, c.gst_fft_f32_window, c.gst_fft_f32_free, len, 1.0);
        run(f64, c.GstFFTF64Complex, "f64", c.gst_fft_f64_new, c.gst_fft_f64_fft, c.gst_fft_f64_inverse_fft, c.gst_fft_f64_window, c.gst_fft_f64_free, len, 1.0);
    }
    var n: c_int = -3;
    while (n < 400) : (n += 1) out("next {d} {d}", .{ n, c.gst_fft_next_fast_length(n) });
    for ([_]c_int{ 1001, 4097, 65535, 100003 }) |x| out("next {d} {d}", .{ x, c.gst_fft_next_fast_length(x) });
    out("checks", .{});
    _ = c.gst_fft_s16_new(0, 0);
    _ = c.gst_fft_s16_new(3, 0);
    _ = c.gst_fft_f64_new(-2, 1);
    const fw = c.gst_fft_f32_new(8, 0);
    const fi = c.gst_fft_f32_new(8, 1);
    var t: [8]f32 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var fr: [5]c.GstFFTF32Complex = undefined;
    c.gst_fft_f32_fft(null, &t, &fr);
    c.gst_fft_f32_fft(fi, &t, &fr);
    c.gst_fft_f32_fft(fw, null, &fr);
    c.gst_fft_f32_fft(fw, &t, null);
    c.gst_fft_f32_inverse_fft(fw, &fr, &t);
    c.gst_fft_f32_inverse_fft(null, &fr, &t);
    c.gst_fft_f32_window(null, &t, 0);
    c.gst_fft_f32_window(fw, null, 0);
    c.gst_fft_f32_free(fw);
    c.gst_fft_f32_free(fi);
    c.gst_fft_s16_free(null);
}
