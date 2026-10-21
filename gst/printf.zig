const std = @import("std");
const c = @import("c.zig").c;
const va = @import("varargs.zig");

const NONE: u64 = std.math.maxInt(u64);
const SECOND: u64 = 1000000000;

pub const Hook = *const fn (kind: u8, ptr: ?*anyopaque) [*c]u8;
pub var describe: ?Hook = null;

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: ?usize = null,
    precision: ?usize = null,
    length: enum { none, hh, h, l, ll, j, z, t, big_l } = .none,
};

const Out = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,

    fn add(self: *Out, bytes: []const u8) void {
        self.list.appendSlice(std.heap.c_allocator, bytes) catch @panic("out of memory");
    }

    fn fill(self: *Out, ch: u8, n: usize) void {
        self.list.appendNTimes(std.heap.c_allocator, ch, n) catch @panic("out of memory");
    }

    fn padded(self: *Out, spec: *const Spec, sign: []const u8, prefix: []const u8, body: []const u8, zero_ok: bool) void {
        const len = sign.len + prefix.len + body.len;
        const width = spec.width orelse 0;
        const pad = if (width > len) width - len else 0;
        if (spec.left) {
            self.add(sign);
            self.add(prefix);
            self.add(body);
            self.fill(' ', pad);
        } else if (spec.zero and zero_ok) {
            self.add(sign);
            self.add(prefix);
            self.fill('0', pad);
            self.add(body);
        } else {
            self.fill(' ', pad);
            self.add(sign);
            self.add(prefix);
            self.add(body);
        }
    }
};

fn timeString(buf: []u8, t: u64) []const u8 {
    if (t == NONE) return std.fmt.bufPrint(buf, "99:99:99.999999999", .{}) catch unreachable;
    const h: u32 = @truncate(t / (SECOND * 3600));
    const m: u32 = @truncate((t / (SECOND * 60)) % 60);
    const s: u32 = @truncate((t / SECOND) % 60);
    const ns: u32 = @truncate(t % SECOND);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}.{d:0>9}", .{ h, m, s, ns }) catch unreachable;
}

pub fn timeAlloc(t: u64) [*c]u8 {
    var buf: [48]u8 = undefined;
    const s = timeString(&buf, t);
    return c.g_strndup(s.ptr, s.len);
}

pub fn stimeAlloc(t: i64) [*c]u8 {
    var buf: [48]u8 = undefined;
    const none = t == std.math.minInt(i64);
    const sign: u8 = if (none or t >= 0) '+' else '-';
    const abs: u64 = if (none) NONE else @abs(t);
    const body = timeString(&buf, abs);
    return c.g_strdup_printf("%c%.*s", @as(c_int, sign), @as(c_int, @intCast(body.len)), body.ptr);
}

fn unsignedArg(spec: *const Spec, ap: *va.VaList) callconv(.c) u64 {
    return switch (spec.length) {
        .hh => @as(u8, @truncate(@cVaArg(ap, c_uint))),
        .h => @as(u16, @truncate(@cVaArg(ap, c_uint))),
        .none => @cVaArg(ap, c_uint),
        .l => @cVaArg(ap, c_ulong),
        .ll, .big_l => @cVaArg(ap, c_ulonglong),
        .j => @cVaArg(ap, u64),
        .z => @cVaArg(ap, usize),
        .t => @bitCast(@as(i64, @cVaArg(ap, isize))),
    };
}

fn signedArg(spec: *const Spec, ap: *va.VaList) callconv(.c) i64 {
    return switch (spec.length) {
        .hh => @as(i8, @truncate(@cVaArg(ap, c_int))),
        .h => @as(i16, @truncate(@cVaArg(ap, c_int))),
        .none => @cVaArg(ap, c_int),
        .l => @cVaArg(ap, c_long),
        .ll, .big_l => @cVaArg(ap, c_longlong),
        .j => @cVaArg(ap, i64),
        .z => @bitCast(@as(u64, @cVaArg(ap, usize))),
        .t => @cVaArg(ap, isize),
    };
}

fn digits(buf: []u8, v: u64, base: u8, upper: bool) []const u8 {
    const chars = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var i = buf.len;
    var x = v;
    if (x == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (x != 0) : (x /= base) {
        i -= 1;
        buf[i] = chars[@intCast(x % base)];
    }
    return buf[i..];
}

fn integer(out: *Out, spec: *const Spec, conv: u8, ap: *va.VaList) callconv(.c) void {
    var buf: [80]u8 = undefined;
    var sign: []const u8 = "";
    var mag: u64 = 0;
    if (conv == 'd' or conv == 'i') {
        const v = signedArg(spec, ap);
        mag = @abs(v);
        if (v < 0) sign = "-" else if (spec.plus) sign = "+" else if (spec.space) sign = " ";
    } else mag = unsignedArg(spec, ap);
    const base: u8 = switch (conv) {
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    var body = digits(buf[32..], mag, base, conv == 'X');
    if (spec.precision) |p| {
        if (p == 0 and mag == 0) body = "";
        if (body.len < p) {
            const start = 32 - (p - body.len);
            @memset(buf[start..32], '0');
            body = buf[start .. 32 + body.len];
        }
    }
    var prefix: []const u8 = "";
    if (spec.alt) {
        if (conv == 'o' and (body.len == 0 or body[0] != '0')) prefix = "0";
        if (conv == 'x' and mag != 0) prefix = "0x";
        if (conv == 'X' and mag != 0) prefix = "0X";
    }
    out.padded(spec, sign, prefix, body, spec.precision == null);
}

fn floating(out: *Out, spec: *const Spec, conv: u8, ap: *va.VaList) callconv(.c) void {
    const v: f64 = @cVaArg(ap, f64);
    var sign: []const u8 = "";
    if (std.math.signbit(v)) sign = "-" else if (spec.plus) sign = "+" else if (spec.space) sign = " ";
    const mag = @abs(v);
    var buf: [512]u8 = undefined;
    var body: []const u8 = undefined;
    if (std.math.isNan(mag)) {
        body = if (std.ascii.isUpper(conv)) "NAN" else "nan";
    } else if (std.math.isInf(mag)) {
        body = if (std.ascii.isUpper(conv)) "INF" else "inf";
    } else {
        const lower = std.ascii.toLower(conv);
        const precision = spec.precision orelse 6;
        var fmt_buf: [16]u8 = undefined;
        const fmt = std.fmt.bufPrintZ(&fmt_buf, "%{s}.{d}{c}", .{ if (spec.alt) "#" else "", precision, if (lower == 'a') 'e' else conv }) catch unreachable;
        const r = c.g_ascii_formatd(&buf, buf.len, fmt.ptr, mag);
        body = std.mem.span(r);
    }
    out.padded(spec, sign, "", body, std.math.isFinite(v));
}

fn pointer(out: *Out, spec: *const Spec, ap: *va.VaList, ext: u8) callconv(.c) void {
    const p = @cVaArg(ap, ?*anyopaque);
    if (ext != 0) {
        if (describe) |hook| {
            const s = hook(ext, p);
            if (s != null) {
                out.padded(spec, "", "", std.mem.span(s), false);
                c.g_free(s);
                return;
            }
        }
    }
    if (p == null) return out.padded(spec, "", "", "(nil)", false);
    var buf: [32]u8 = undefined;
    out.padded(spec, "", "0x", digits(&buf, @intFromPtr(p), 16, false), false);
}

fn run(out: *Out, fmt: [*c]const u8, ap: *va.VaList) callconv(.c) void {
    var i: usize = 0;
    while (fmt[i] != 0) {
        if (fmt[i] != '%') {
            const start = i;
            while (fmt[i] != 0 and fmt[i] != '%') i += 1;
            out.add(fmt[start..i]);
            continue;
        }
        i += 1;
        if (fmt[i] == '%') {
            out.add("%");
            i += 1;
            continue;
        }
        var spec = Spec{};
        while (true) : (i += 1) {
            switch (fmt[i]) {
                '-' => spec.left = true,
                '+' => spec.plus = true,
                ' ' => spec.space = true,
                '#' => spec.alt = true,
                '0' => spec.zero = true,
                '\'' => {},
                else => break,
            }
        }
        if (fmt[i] == '*') {
            const w = @cVaArg(ap, c_int);
            if (w < 0) {
                spec.left = true;
                spec.width = @intCast(-w);
            } else spec.width = @intCast(w);
            i += 1;
        } else {
            var w: usize = 0;
            var any = false;
            while (std.ascii.isDigit(fmt[i])) : (i += 1) {
                w = w * 10 + (fmt[i] - '0');
                any = true;
            }
            if (any) spec.width = w;
        }
        if (fmt[i] == '.') {
            i += 1;
            if (fmt[i] == '*') {
                const p = @cVaArg(ap, c_int);
                spec.precision = if (p < 0) null else @intCast(p);
                i += 1;
            } else {
                var p: usize = 0;
                while (std.ascii.isDigit(fmt[i])) : (i += 1) p = p * 10 + (fmt[i] - '0');
                spec.precision = p;
            }
        }
        switch (fmt[i]) {
            'h' => {
                i += 1;
                spec.length = .h;
                if (fmt[i] == 'h') {
                    i += 1;
                    spec.length = .hh;
                }
            },
            'l' => {
                i += 1;
                spec.length = .l;
                if (fmt[i] == 'l') {
                    i += 1;
                    spec.length = .ll;
                }
            },
            'q' => {
                i += 1;
                spec.length = .ll;
            },
            'L' => {
                i += 1;
                spec.length = .big_l;
            },
            'j' => {
                i += 1;
                spec.length = .j;
            },
            'z', 'Z' => {
                i += 1;
                spec.length = .z;
            },
            't' => {
                i += 1;
                spec.length = .t;
            },
            else => {},
        }
        const conv = fmt[i];
        if (conv == 0) break;
        i += 1;
        switch (conv) {
            'd', 'i', 'u', 'o', 'x', 'X' => integer(out, &spec, conv, ap),
            'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A' => floating(out, &spec, conv, ap),
            'c' => {
                const ch: u8 = @truncate(@as(c_uint, @bitCast(@cVaArg(ap, c_int))));
                out.padded(&spec, "", "", &.{ch}, false);
            },
            's' => {
                const s = @cVaArg(ap, [*c]const u8);
                const text: []const u8 = if (s == null) "(null)" else std.mem.span(s);
                const n = if (spec.precision) |p| @min(p, text.len) else text.len;
                out.padded(&spec, "", "", text[0..n], false);
            },
            'p' => {
                var ext: u8 = 0;
                if (fmt[i] == '\x07' and fmt[i + 1] != 0) {
                    ext = fmt[i + 1];
                    i += 2;
                }
                pointer(out, &spec, ap, ext);
            },
            'n' => _ = @cVaArg(ap, ?*anyopaque),
            else => out.add(&.{ '%', conv }),
        }
    }
}

pub fn format(fmt: [*c]const u8, ap: *va.VaList) ?[]u8 {
    var out = Out{};
    run(&out, fmt, ap);
    return out.list.toOwnedSlice(std.heap.c_allocator) catch null;
}

pub fn vasprintf(result: [*c][*c]u8, fmt: [*c]const u8, ap: *va.VaList) c.gint {
    const text = format(fmt, ap) orelse {
        result.* = null;
        return -1;
    };
    defer std.heap.c_allocator.free(text);
    result.* = c.g_strndup(text.ptr, text.len);
    return @intCast(text.len);
}
