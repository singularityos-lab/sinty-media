const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const format = @import("format.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Pos = c.GstAudioChannelPosition;
const PRECISION = 10;

const OutEntry = extern struct { index: c.guint, offset: c.guint, count: c.guint };
const Entry = extern struct { index: c.guint, coeff: f32, coeff_int: c.gint };

const Func = *const fn (*Mixer, [*c]const c.gpointer, [*c]c.gpointer, c.gint) void;

pub const Mixer = struct {
    in_channels: c.gint,
    out_channels: c.gint,
    finfo: [*c]const c.GstAudioFormatInfo,
    matrix: [*c][*c]f32,
    matrix_int: ?[*][*]c.gint,
    out_entry: ?[*]OutEntry,
    entry: ?[*]Entry,
    num_valid_out_ch: c.guint,
    non_interleaved: bool,
    clear_unit: usize,
    func: Func,
};

fn of(m: anytype) *Mixer {
    return @ptrCast(@alignCast(m));
}

fn p(comptime name: []const u8) Pos {
    return @field(c, "GST_AUDIO_CHANNEL_POSITION_" ++ name);
}

pub export fn gst_audio_channel_mixer_free(mp: ?*c.GstAudioChannelMixer) void {
    const m = of(mp);
    const n: usize = @intCast(m.in_channels);
    for (0..n) |i| c.g_free(m.matrix[i]);
    c.g_free(@ptrCast(m.matrix));
    if (m.matrix_int) |mi| {
        for (0..n) |i| c.g_free(mi[i]);
        c.g_free(@ptrCast(mi));
    }
    c.g_free(m.out_entry);
    c.g_free(m.entry);
    c.g_free(m);
}

fn fillIdentical(matrix: [*c][*c]f32, in_ch: c.gint, in_pos: [*c]const Pos, out_ch: c.gint, out_pos: [*c]const Pos, flags: c.GstAudioChannelMixerFlags) void {
    var co: usize = 0;
    while (co < out_ch) : (co += 1) {
        var ci: usize = 0;
        while (ci < in_ch) : (ci += 1) {
            if (flags & c.GST_AUDIO_CHANNEL_MIXER_FLAGS_UNPOSITIONED_IN != 0) {
                matrix[ci][co] = if (ci == co) 1.0 else 0.0;
            } else if (in_pos[ci] == out_pos[co]) matrix[ci][co] = 1.0;
        }
    }
}

const Conv = struct { a: Pos, b: Pos, m: Pos };
const CONV = [_]Conv{
    .{ .a = p("FRONT_LEFT"), .b = p("FRONT_RIGHT"), .m = p("MONO") },
    .{ .a = p("FRONT_LEFT_OF_CENTER"), .b = p("FRONT_RIGHT_OF_CENTER"), .m = p("FRONT_CENTER") },
    .{ .a = p("REAR_LEFT"), .b = p("REAR_RIGHT"), .m = p("REAR_CENTER") },
};

fn fillCompatible(matrix: [*c][*c]f32, in_ch: c.gint, in_pos: [*c]const Pos, out_ch: c.gint, out_pos: [*c]const Pos) void {
    for (CONV) |cv| {
        var a0: c_int = -1;
        var a1: c_int = -1;
        var a2: c_int = -1;
        var b0: c_int = -1;
        var b1: c_int = -1;
        var b2: c_int = -1;
        var n: c_int = 0;
        while (n < in_ch) : (n += 1) {
            const v = in_pos[@intCast(n)];
            if (v == cv.a) a0 = n else if (v == cv.b) a1 = n else if (v == cv.m) a2 = n;
        }
        n = 0;
        while (n < out_ch) : (n += 1) {
            const v = out_pos[@intCast(n)];
            if (v == cv.a) b0 = n else if (v == cv.b) b1 = n else if (v == cv.m) b2 = n;
        }
        const set = struct {
            fn f(mx: [*c][*c]f32, i: c_int, o: c_int, v: f32) void {
                mx[@intCast(i)][@intCast(o)] = v;
            }
        }.f;
        if (a0 != -1 and a2 == -1 and b0 == -1 and b2 != -1) {
            set(matrix, a0, b2, 1.0);
        } else if (a0 != -1 and a2 != -1 and b0 == -1 and b2 != -1) {
            set(matrix, a0, b2, 0.5);
        } else if (a0 != -1 and a2 == -1 and b0 != -1 and b2 != -1) set(matrix, a0, b2, 1.0);
        if (a1 != -1 and a2 == -1 and b1 == -1 and b2 != -1) {
            set(matrix, a1, b2, 1.0);
        } else if (a1 != -1 and a2 != -1 and b1 == -1 and b2 != -1) {
            set(matrix, a1, b2, 0.5);
        } else if (a1 != -1 and a2 == -1 and b1 != -1 and b2 != -1) set(matrix, a1, b2, 1.0);
        if (a2 != -1 and a0 == -1 and b2 == -1 and b0 != -1) {
            set(matrix, a2, b0, 1.0);
        } else if (a2 != -1 and a0 != -1 and b2 == -1 and b0 != -1) {
            set(matrix, a2, b0, 0.5);
        } else if (a2 != -1 and a0 == -1 and b2 != -1 and b0 != -1) set(matrix, a2, b0, 1.0);
        if (a2 != -1 and a1 == -1 and b2 == -1 and b1 != -1) {
            set(matrix, a2, b1, 1.0);
        } else if (a2 != -1 and a1 != -1 and b2 == -1 and b1 != -1) {
            set(matrix, a2, b1, 0.5);
        } else if (a2 != -1 and a1 == -1 and b2 != -1 and b1 != -1) set(matrix, a2, b1, 1.0);
    }
}

const Groups = struct {
    f: [3]c_int = .{ -1, -1, -1 },
    c: [3]c_int = .{ -1, -1, -1 },
    r: [3]c_int = .{ -1, -1, -1 },
    s: [3]c_int = .{ -1, -1, -1 },
    b: [3]c_int = .{ -1, -1, -1 },
    hf: bool = false,
    hc: bool = false,
    hr: bool = false,
    hs: bool = false,
    hb: bool = false,
};

fn detect(ch: c.gint, pos: [*c]const Pos) Groups {
    var g = Groups{};
    var n: c_int = 0;
    while (n < ch) : (n += 1) {
        switch (pos[@intCast(n)]) {
            p("MONO") => {
                g.f[1] = n;
                g.hf = true;
            },
            p("FRONT_LEFT") => {
                g.f[0] = n;
                g.hf = true;
            },
            p("FRONT_RIGHT") => {
                g.f[2] = n;
                g.hf = true;
            },
            p("FRONT_CENTER") => {
                g.c[1] = n;
                g.hc = true;
            },
            p("FRONT_LEFT_OF_CENTER") => {
                g.c[0] = n;
                g.hc = true;
            },
            p("FRONT_RIGHT_OF_CENTER") => {
                g.c[2] = n;
                g.hc = true;
            },
            p("REAR_CENTER") => {
                g.r[1] = n;
                g.hr = true;
            },
            p("REAR_LEFT") => {
                g.r[0] = n;
                g.hr = true;
            },
            p("REAR_RIGHT") => {
                g.r[2] = n;
                g.hr = true;
            },
            p("SIDE_LEFT") => {
                g.s[0] = n;
                g.hs = true;
            },
            p("SIDE_RIGHT") => {
                g.s[2] = n;
                g.hs = true;
            },
            p("LFE1") => {
                g.hb = true;
                g.b[1] = n;
            },
            else => {},
        }
    }
    return g;
}

fn one(matrix: [*c][*c]f32, from: [3]c_int, to: [3]c_int, ratio_d: f64) void {
    const ratio: f32 = @floatCast(ratio_d);
    const half: f32 = @floatCast(0.5 * @as(f64, ratio));
    const set = struct {
        fn f(mx: [*c][*c]f32, i: c_int, o: c_int, v: f32) void {
            mx[@intCast(i)][@intCast(o)] = v;
        }
    }.f;
    if (from[1] != -1 and to[1] != -1) set(matrix, from[1], to[1], ratio);
    if (from[0] != -1 and to[0] != -1) set(matrix, from[0], to[0], ratio);
    if (from[2] != -1 and to[2] != -1) set(matrix, from[2], to[2], ratio);
    if (from[0] != -1 and to[1] != -1 and from[1] != -1) {
        set(matrix, from[0], to[1], half);
    } else if (from[0] != -1 and to[1] != -1 and from[1] == -1) set(matrix, from[0], to[1], ratio);
    if (from[2] != -1 and to[1] != -1 and from[1] != -1) {
        set(matrix, from[2], to[1], half);
    } else if (from[2] != -1 and to[1] != -1 and from[1] == -1) set(matrix, from[2], to[1], ratio);
    if (from[1] != -1 and to[0] != -1 and from[0] != -1) {
        set(matrix, from[1], to[0], half);
    } else if (from[1] != -1 and to[0] != -1 and from[0] == -1) set(matrix, from[1], to[0], ratio);
    if (from[1] != -1 and to[2] != -1 and from[2] != -1) {
        set(matrix, from[1], to[2], half);
    } else if (from[1] != -1 and to[2] != -1 and from[2] == -1) set(matrix, from[1], to[2], ratio);
}

const SQRT2 = 1.0 / @sqrt(2.0);
const CENTER_FRONT = SQRT2;
const CENTER_SIDE = 1.0 / 2.0;
const CENTER_REAR = 1.0 / @sqrt(8.0);
const FRONT_SIDE = SQRT2;
const FRONT_REAR = 1.0 / 2.0;
const SIDE_REAR = SQRT2;
const CENTER_BASS = SQRT2;
const FRONT_BASS = 1.0;
const SIDE_BASS = SQRT2;
const REAR_BASS = SQRT2;

fn fillOthers(m: [*c][*c]f32, in_ch: c.gint, in_pos: [*c]const Pos, out_ch: c.gint, out_pos: [*c]const Pos) void {
    const i = detect(in_ch, in_pos);
    const o = detect(out_ch, out_pos);
    if (!i.hc and i.hf and o.hc) {
        one(m, i.f, o.c, CENTER_FRONT);
    } else if (!i.hc and !i.hf and i.hs and o.hc) {
        one(m, i.s, o.c, CENTER_SIDE);
    } else if (!i.hc and !i.hf and !i.hs and i.hr and o.hc) {
        one(m, i.r, o.c, CENTER_REAR);
    } else if (i.hc and !o.hc and o.hf) {
        one(m, i.c, o.f, CENTER_FRONT);
    } else if (i.hc and !o.hc and !o.hf and o.hs) {
        one(m, i.c, o.s, CENTER_SIDE);
    } else if (i.hc and !o.hc and !o.hf and !o.hs and o.hr) one(m, i.c, o.r, CENTER_REAR);

    if (!i.hf and i.hc and !i.hs and o.hf) {
        one(m, i.c, o.f, CENTER_FRONT);
    } else if (!i.hf and !i.hc and i.hs and o.hf) {
        one(m, i.s, o.f, FRONT_SIDE);
    } else if (!i.hf and i.hc and i.hs and o.hf) {
        one(m, i.c, o.f, 0.5 * CENTER_FRONT);
        one(m, i.s, o.f, 0.5 * FRONT_SIDE);
    } else if (!i.hf and !i.hc and !i.hs and i.hr and o.hf) {
        one(m, i.r, o.f, FRONT_REAR);
    } else if (i.hf and o.hc and !o.hs and !o.hf) {
        one(m, i.f, o.c, CENTER_FRONT);
    } else if (i.hf and !o.hc and o.hs and !o.hf) {
        one(m, i.f, o.s, FRONT_SIDE);
    } else if (i.hf and o.hc and o.hs and !o.hf) {
        one(m, i.f, o.c, 0.5 * CENTER_FRONT);
        one(m, i.f, o.s, 0.5 * FRONT_SIDE);
    } else if (i.hf and !o.hc and !o.hs and !o.hf and o.hr) one(m, i.f, o.r, FRONT_REAR);

    if (!i.hs and i.hf and !i.hr and o.hs) {
        one(m, i.f, o.s, FRONT_SIDE);
    } else if (!i.hs and !i.hf and i.hr and o.hs) {
        one(m, i.r, o.s, SIDE_REAR);
    } else if (!i.hs and i.hf and i.hr and o.hs) {
        one(m, i.f, o.s, 0.5 * FRONT_SIDE);
        one(m, i.r, o.s, 0.5 * SIDE_REAR);
    } else if (!i.hs and !i.hf and !i.hr and i.hc and o.hs) {
        one(m, i.c, o.s, CENTER_SIDE);
    } else if (i.hs and o.hf and !o.hr and !o.hs) {
        one(m, i.s, o.f, FRONT_SIDE);
    } else if (i.hs and !o.hf and o.hr and !o.hs) {
        one(m, i.s, o.r, SIDE_REAR);
    } else if (i.hs and o.hf and o.hr and !o.hs) {
        one(m, i.s, o.f, 0.5 * FRONT_SIDE);
        one(m, i.s, o.r, 0.5 * SIDE_REAR);
    } else if (i.hs and !o.hf and !o.hr and o.hc and !o.hs) one(m, i.s, o.c, CENTER_SIDE);

    if (!i.hr and i.hs and o.hr) {
        one(m, i.s, o.r, SIDE_REAR);
    } else if (!i.hr and !i.hs and i.hf and o.hr) {
        one(m, i.f, o.r, FRONT_REAR);
    } else if (!i.hr and !i.hs and !i.hf and i.hc and o.hr) {
        one(m, i.c, o.r, CENTER_REAR);
    } else if (i.hr and !o.hr and o.hs) {
        one(m, i.r, o.s, SIDE_REAR);
    } else if (i.hr and !o.hr and !o.hs and o.hf) {
        one(m, i.r, o.f, FRONT_REAR);
    } else if (i.hr and !o.hr and !o.hs and !o.hf and o.hc) one(m, i.r, o.c, CENTER_REAR);

    if (i.hb and !o.hb) {
        if (o.hc) one(m, i.b, o.c, CENTER_BASS);
        if (o.hf) one(m, i.b, o.f, FRONT_BASS);
        if (o.hs) one(m, i.b, o.s, SIDE_BASS);
        if (o.hr) one(m, i.b, o.r, REAR_BASS);
    } else if (!i.hb and o.hb) {
        if (i.hc) one(m, i.c, o.b, CENTER_BASS);
        if (i.hf) one(m, i.f, o.b, FRONT_BASS);
        if (i.hs) one(m, i.s, o.b, REAR_BASS);
        if (i.hr) one(m, i.r, o.b, REAR_BASS);
    }
}

fn normalize(m: [*c][*c]f32, in_ch: c.gint, out_ch: c.gint) void {
    const ni: usize = @intCast(@max(in_ch, 0));
    const no: usize = @intCast(@max(out_ch, 0));
    var top: f32 = 0;
    for (0..no) |j| {
        var sum: f32 = 0;
        for (0..ni) |i| sum = @floatCast(@as(f64, sum) + @abs(@as(f64, m[i][j])));
        if (sum > top) top = sum;
    }
    if (top == 0.0) return;
    for (0..no) |j| for (0..ni) |i| {
        m[i][j] /= top;
    };
}

fn fillSpecial(m: [*c][*c]f32, in_ch: c.gint, in_pos: [*c]const Pos, out_ch: c.gint, out_pos: [*c]const Pos) bool {
    const fl = p("FRONT_LEFT");
    const fr = p("FRONT_RIGHT");
    if (in_ch == 2 and out_ch == 1 and ((in_pos[0] == fl and in_pos[1] == fr) or (in_pos[0] == fr and in_pos[1] == fl)) and out_pos[0] == p("MONO")) {
        m[0][0] = 0.5;
        m[1][0] = 0.5;
        return true;
    }
    if (in_ch == 1 and out_ch == 2 and ((out_pos[0] == fl and out_pos[1] == fr) or (out_pos[0] == fr and out_pos[1] == fl)) and in_pos[0] == p("MONO")) {
        m[0][0] = 1.0;
        m[0][1] = 1.0;
        return true;
    }
    return false;
}

const Virtual = enum { none, mono, stereo };

fn detectVirtual(ch: c.gint, pos: [*c]const Pos) Virtual {
    if (ch < 2) return .none;
    const alt = [2]Pos{ p("FRONT_LEFT"), p("FRONT_RIGHT") };
    var mono = true;
    var alternate = true;
    var i: usize = 0;
    while (i < ch) : (i += 1) {
        if (pos[i] != p("MONO")) mono = false;
        if (pos[i] != alt[i % 2]) alternate = false;
        if (!mono and !alternate) return .none;
    }
    if (mono) return .mono;
    if (alternate and ch > 2) return .stereo;
    return .none;
}

fn fillMatrix(m: [*c][*c]f32, flags: c.GstAudioChannelMixerFlags, in_ch: c.gint, in_pos: [*c]const Pos, out_ch: c.gint, out_pos: [*c]const Pos) void {
    if (fillSpecial(m, in_ch, in_pos, out_ch, out_pos)) return;
    var in_size = in_ch;
    const virt = detectVirtual(in_size, in_pos);
    switch (virt) {
        .mono => in_size = 1,
        .stereo => in_size = 2,
        .none => {},
    }
    fillIdentical(m, in_size, in_pos, out_ch, out_pos, flags);
    if (flags & c.GST_AUDIO_CHANNEL_MIXER_FLAGS_UNPOSITIONED_IN == 0) {
        fillCompatible(m, in_size, in_pos, out_ch, out_pos);
        fillOthers(m, in_size, in_pos, out_ch, out_pos);
        normalize(m, in_size, out_ch);
    }
    const no: usize = @intCast(out_ch);
    const ni: usize = @intCast(in_ch);
    switch (virt) {
        .mono => {
            for (0..no) |o| m[0][o] /= @as(f32, @floatFromInt(in_ch));
            for (1..ni) |i| @memcpy(m[i][0..no], m[0][0..no]);
        },
        .stereo => {
            const right = in_ch >> 1;
            const left = right + @rem(in_ch, 2);
            for (0..no) |o| {
                m[0][o] /= @as(f32, @floatFromInt(left));
                m[1][o] /= @as(f32, @floatFromInt(right));
            }
            for (2..ni) |i| @memcpy(m[i][0..no], m[i % 2][0..no]);
        },
        .none => {},
    }
}

fn setupMatrixInt(m: *Mixer) void {
    const ni: usize = @intCast(m.in_channels);
    const no: usize = @intCast(m.out_channels);
    const mi: [*][*]c.gint = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(usize) * ni)));
    for (0..ni) |i| {
        mi[i] = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.gint) * no)));
        for (0..no) |j| {
            const tmp: f32 = m.matrix[i][j] * @as(f32, 1 << PRECISION);
            mi[i][j] = @intFromFloat(tmp);
        }
    }
    m.matrix_int = mi;
}

fn setupMatrix(flags: c.GstAudioChannelMixerFlags, in_ch: c.gint, in_pos: [*c]const Pos, out_ch: c.gint, out_pos: [*c]const Pos) [*c][*c]f32 {
    const ni: usize = @intCast(@max(in_ch, 0));
    const no: usize = @intCast(@max(out_ch, 0));
    const m: [*c][*c]f32 = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(usize) * ni)));
    for (0..ni) |i| {
        m[i] = @ptrCast(@alignCast(c.g_malloc(@sizeOf(f32) * no)));
        @memset(m[i][0..no], 0);
    }
    fillMatrix(m, flags, in_ch, in_pos, out_ch, out_pos);
    return m;
}

fn MixFns(comptime T: type, comptime R: type) type {
    return struct {
        fn get(in: [*c]const c.gpointer, comptime planar: bool, n: usize, ch: usize, total: usize) T {
            const base: [*]const T = @ptrCast(@alignCast(if (planar) in[ch] else in[0]));
            return if (planar) base[n] else base[n * total + ch];
        }

        fn put(out: [*c]c.gpointer, comptime planar: bool, n: usize, ch: usize, total: usize, v: T) void {
            const base: [*]T = @ptrCast(@alignCast(if (planar) out[ch] else out[0]));
            if (planar) base[n] = v else base[n * total + ch] = v;
        }

        fn store(r: R) T {
            if (@typeInfo(T) == .float) return r;
            const v = (r +% (1 << (PRECISION - 1))) >> PRECISION;
            return @intCast(std.math.clamp(v, std.math.minInt(T), std.math.maxInt(T)));
        }

        fn dense(comptime pin: bool, comptime pout: bool) Func {
            return struct {
                fn f(m: *Mixer, in: [*c]const c.gpointer, out: [*c]c.gpointer, samples: c.gint) void {
                    const ni: usize = @intCast(m.in_channels);
                    const no: usize = @intCast(m.out_channels);
                    var n: usize = 0;
                    while (n < samples) : (n += 1) {
                        for (0..no) |o| {
                            var r: R = 0;
                            for (0..ni) |i| {
                                if (@typeInfo(T) == .float) {
                                    r += get(in, pin, n, i, ni) * @as(R, m.matrix[i][o]);
                                } else r +%= @as(R, get(in, pin, n, i, ni)) *% @as(R, m.matrix_int.?[i][o]);
                            }
                            put(out, pout, n, o, no, store(r));
                        }
                    }
                }
            }.f;
        }

        fn sparse(comptime pin: bool, comptime pout: bool) Func {
            return struct {
                fn f(m: *Mixer, in: [*c]const c.gpointer, out: [*c]c.gpointer, samples: c.gint) void {
                    const ni: usize = @intCast(m.in_channels);
                    const no: usize = @intCast(m.out_channels);
                    const nclear: usize = if (m.non_interleaved) no else 1;
                    for (0..nclear) |o| format.gst_audio_format_info_fill_silence(m.finfo, out[o], @as(usize, @intCast(samples)) *% m.clear_unit);
                    var n: usize = 0;
                    while (n < samples) : (n += 1) {
                        for (0..m.num_valid_out_ch) |o| {
                            const oe = m.out_entry.?[o];
                            var r: R = 0;
                            for (0..oe.count) |k| {
                                const e = m.entry.?[oe.offset + k];
                                if (@typeInfo(T) == .float) {
                                    r += get(in, pin, n, e.index, ni) * @as(R, e.coeff);
                                } else r +%= @as(R, get(in, pin, n, e.index, ni)) *% @as(R, e.coeff_int);
                            }
                            put(out, pout, n, oe.index, no, store(r));
                        }
                    }
                }
            }.f;
        }

        fn pick(flags: c.GstAudioChannelMixerFlags, use_sparse: bool) Func {
            const pin = flags & c.GST_AUDIO_CHANNEL_MIXER_FLAGS_NON_INTERLEAVED_IN != 0;
            const pout = flags & c.GST_AUDIO_CHANNEL_MIXER_FLAGS_NON_INTERLEAVED_OUT != 0;
            if (use_sparse) {
                return if (pin) (if (pout) sparse(true, true) else sparse(true, false)) else (if (pout) sparse(false, true) else sparse(false, false));
            }
            return if (pin) (if (pout) dense(true, true) else dense(true, false)) else (if (pout) dense(false, true) else dense(false, false));
        }
    };
}

fn buildSparse(m: *Mixer) bool {
    const eps: f32 = 1e-6;
    const ni: usize = @intCast(m.in_channels);
    const no: usize = @intCast(m.out_channels);
    var total: usize = 0;
    for (0..no) |o| for (0..ni) |i| {
        if (@abs(m.matrix[i][o]) > eps) total += 1;
    };
    const density = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(@as(c_int, @intCast(no)) * @as(c_int, @intCast(ni))));
    if (0.5 <= density) return false;
    m.out_entry = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(OutEntry) * no)));
    m.entry = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Entry) * total)));
    var offset: c.guint = 0;
    const is_int = m.finfo.*.flags & c.GST_AUDIO_FORMAT_FLAG_INTEGER != 0;
    for (0..no) |o| {
        var count: c.guint = 0;
        for (0..ni) |i| {
            const coeff = m.matrix[i][o];
            if (@abs(coeff) > eps) {
                m.entry.?[offset].index = @intCast(i);
                if (is_int) {
                    m.entry.?[offset].coeff_int = @intFromFloat(@as(f32, 1 << PRECISION) * coeff);
                } else m.entry.?[offset].coeff = coeff;
                offset += 1;
                count += 1;
            }
        }
        if (count > 0) {
            const oe = &m.out_entry.?[m.num_valid_out_ch];
            oe.index = @intCast(o);
            oe.offset = offset - count;
            oe.count = count;
            m.num_valid_out_ch += 1;
        }
    }
    return true;
}

fn validFormat(f: c.GstAudioFormat) bool {
    return f == c.GST_AUDIO_FORMAT_S16 or f == c.GST_AUDIO_FORMAT_S32 or f == c.GST_AUDIO_FORMAT_F32 or f == c.GST_AUDIO_FORMAT_F64;
}

pub export fn gst_audio_channel_mixer_new_with_matrix(flags: c.GstAudioChannelMixerFlags, fmt: c.GstAudioFormat, in_ch: c.gint, out_ch: c.gint, matrix: [*c][*c]f32) ?*c.GstAudioChannelMixer {
    const fname = "gst_audio_channel_mixer_new_with_matrix";
    if (!check.that(validFormat(fmt), fname, "format == GST_AUDIO_FORMAT_S16 || format == GST_AUDIO_FORMAT_S32 || format == GST_AUDIO_FORMAT_F32 || format == GST_AUDIO_FORMAT_F64")) return null;
    if (!check.that(in_ch > 0, fname, "in_channels > 0")) return null;
    if (!check.that(out_ch > 0, fname, "out_channels > 0")) return null;
    const m: *Mixer = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Mixer))));
    m.in_channels = in_ch;
    m.out_channels = out_ch;
    if (matrix == null) {
        const ni: usize = @intCast(in_ch);
        const no: usize = @intCast(out_ch);
        m.matrix = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(usize) * ni)));
        for (0..ni) |i| {
            m.matrix[i] = @ptrCast(@alignCast(c.g_malloc(@sizeOf(f32) * no)));
            for (0..no) |j| m.matrix[i][j] = if (i == j) 1.0 else 0.0;
        }
    } else m.matrix = matrix;
    m.finfo = format.gst_audio_format_get_info(fmt);
    const use_sparse = buildSparse(m);
    if (use_sparse) {
        if (flags & c.GST_AUDIO_CHANNEL_MIXER_FLAGS_NON_INTERLEAVED_OUT != 0) {
            m.non_interleaved = true;
            m.clear_unit = @intCast(@divTrunc(m.finfo.*.width, 8));
        } else m.clear_unit = @intCast(@divTrunc(m.finfo.*.width * out_ch, 8));
    } else if (m.finfo.*.flags & c.GST_AUDIO_FORMAT_FLAG_INTEGER != 0) setupMatrixInt(m);
    m.func = switch (fmt) {
        c.GST_AUDIO_FORMAT_S16 => MixFns(i16, i32).pick(flags, use_sparse),
        c.GST_AUDIO_FORMAT_S32 => MixFns(i32, i64).pick(flags, use_sparse),
        c.GST_AUDIO_FORMAT_F32 => MixFns(f32, f32).pick(flags, use_sparse),
        else => MixFns(f64, f64).pick(flags, use_sparse),
    };
    return @ptrCast(m);
}

pub export fn gst_audio_channel_mixer_new(flags: c.GstAudioChannelMixerFlags, fmt: c.GstAudioFormat, in_ch: c.gint, in_pos: [*c]Pos, out_ch: c.gint, out_pos: [*c]Pos) ?*c.GstAudioChannelMixer {
    if (!check.that(validFormat(fmt), "gst_audio_channel_mixer_new", "format == GST_AUDIO_FORMAT_S16 || format == GST_AUDIO_FORMAT_S32 || format == GST_AUDIO_FORMAT_F32 || format == GST_AUDIO_FORMAT_F64")) return null;
    return gst_audio_channel_mixer_new_with_matrix(flags, fmt, in_ch, out_ch, setupMatrix(flags, in_ch, in_pos, out_ch, out_pos));
}

pub export fn gst_audio_channel_mixer_is_passthrough(mp: ?*c.GstAudioChannelMixer) c.gboolean {
    const m = of(mp);
    if (m.in_channels != m.out_channels) return 0;
    const n: usize = @intCast(m.in_channels);
    for (0..n) |i| for (0..n) |j| {
        if ((i == j and m.matrix[i][j] != 1.0) or (i != j and m.matrix[i][j] != 0.0)) return 0;
    };
    return 1;
}

pub export fn gst_audio_channel_mixer_samples(mp: ?*c.GstAudioChannelMixer, in: [*c]const c.gpointer, out: [*c]c.gpointer, samples: c.gint) void {
    if (!check.that(mp != null, "gst_audio_channel_mixer_samples", "mix != NULL")) return;
    const m = of(mp);
    if (!check.that(m.matrix != null, "gst_audio_channel_mixer_samples", "mix->matrix != NULL")) return;
    m.func(m, in, out, samples);
}
