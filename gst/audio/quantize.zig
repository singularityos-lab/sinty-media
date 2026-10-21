const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Func = *const fn (*Quant, ?*const anyopaque, ?*anyopaque, c.gint) void;

const Quant = struct {
    dither: c.GstAudioDitherMethod,
    ns: c.GstAudioNoiseShapingMethod,
    flags: c.GstAudioQuantizeFlags,
    format: c.GstAudioFormat,
    quantizer: c.guint,
    stride: c.guint,
    blocks: c.guint,
    shift: c.guint,
    mask: u32,
    bias: u32,
    last_random: ?[*]i32,
    random_state: u32,
    error_size: c.guint,
    error_buf: ?[*]i32,
    dither_size: c.guint,
    dither_buf: ?[*]i32,
    coeffs: ?[*]i32,
    n_coeffs: c.gint,
    quantize: Func,
};

fn of(q: anytype) *Quant {
    return @ptrCast(@alignCast(q));
}

fn addss(res: i32, val: i32) i32 {
    if (val > 0 and res > 0 and std.math.maxInt(i32) - res <= val) return std.math.maxInt(i32);
    if (val < 0 and res < 0 and std.math.minInt(i32) - res >= val) return std.math.minInt(i32);
    return res +% val;
}

fn sat(a: i32, b: i32) i32 {
    return std.math.add(i32, a, b) catch if (b > 0) std.math.maxInt(i32) else std.math.minInt(i32);
}

fn qMemcpy(q: *Quant, src: ?*const anyopaque, dst: ?*anyopaque, samples: c.gint) void {
    if (src != @as(?*const anyopaque, dst)) {
        const n = @as(usize, @intCast(samples)) * 4 * q.stride;
        @memcpy(@as([*]u8, @ptrCast(dst))[0..n], @as([*]const u8, @ptrCast(src))[0..n]);
    }
}

fn qNone(q: *Quant, src: ?*const anyopaque, dst: ?*anyopaque, samples: c.gint) void {
    const s: [*]const i32 = @ptrCast(@alignCast(src));
    const d: [*]i32 = @ptrCast(@alignCast(dst));
    const n = @as(usize, @intCast(samples)) * q.stride;
    const m: i32 = @bitCast(~q.mask);
    for (0..n) |i| d[i] = sat(s[i], @bitCast(q.bias)) & m;
}

fn rand(state: *u32) i32 {
    var x: u64 = state.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state.* = @truncate(x);
    return @bitCast(state.*);
}

fn rdither(state: *u32, dither: i32) i32 {
    return -%dither +% (rand(state) & ((dither << 1) -% 1));
}

fn setupDither(q: *Quant, samples: c.gint) void {
    var need_init = false;
    const stride: usize = q.stride;
    const len: usize = @as(usize, @intCast(samples)) * stride;
    if (q.dither_size < len) {
        q.dither_size = @intCast(len);
        q.dither_buf = @ptrCast(@alignCast(c.g_realloc(q.dither_buf, len * 4)));
        need_init = true;
    }
    const bias: i32 = @bitCast(q.bias);
    const d = q.dither_buf.?;
    switch (q.dither) {
        c.GST_AUDIO_DITHER_NONE => if (need_init) @memset(d[0..len], 0),
        c.GST_AUDIO_DITHER_RPDF => {
            const dither: i32 = @bitCast(@as(u32, 1) << @intCast(q.shift));
            for (0..len) |i| d[i] = bias +% rdither(&q.random_state, dither);
        },
        c.GST_AUDIO_DITHER_TPDF => {
            const dither: i32 = @bitCast(@as(u32, 1) << @intCast(q.shift - 1));
            for (0..len) |i| {
                const a = rdither(&q.random_state, dither);
                d[i] = bias +% a +% rdither(&q.random_state, dither);
            }
        },
        c.GST_AUDIO_DITHER_TPDF_HF => {
            const dither: i32 = @bitCast(@as(u32, 1) << @intCast(q.shift - 1));
            const last = q.last_random.?;
            for (0..len) |i| {
                const tmp = rdither(&q.random_state, dither);
                d[i] = bias +% tmp -% last[i % stride];
                last[i % stride] = tmp;
            }
        },
        else => {},
    }
}

fn qDither(q: *Quant, src: ?*const anyopaque, dst: ?*anyopaque, samples: c.gint) void {
    setupDither(q, samples);
    const s: [*]const i32 = @ptrCast(@alignCast(src));
    const d: [*]i32 = @ptrCast(@alignCast(dst));
    const n = @as(usize, @intCast(samples)) * q.stride;
    const m: i32 = @bitCast(~q.mask);
    const dith = q.dither_buf.?;
    for (0..n) |i| d[i] = sat(s[i], dith[i]) & m;
}

fn setupError(q: *Quant, samples: c.gint, extra: c.gint) void {
    const stride: usize = q.stride;
    const len: usize = @as(usize, @intCast(samples + extra)) * stride;
    if (q.error_size < len) {
        q.error_buf = @ptrCast(@alignCast(c.g_realloc(q.error_buf, len * 4)));
        if (q.error_size == 0) @memset(q.error_buf.?[0 .. stride * @as(usize, @intCast(extra))], 0);
        q.error_size = @intCast(len);
    }
}

fn qFeedback(q: *Quant, src: ?*const anyopaque, dst: ?*anyopaque, samples: c.gint) void {
    setupDither(q, samples);
    setupError(q, samples, 1);
    const s: [*]const i32 = @ptrCast(@alignCast(src));
    const d: [*]i32 = @ptrCast(@alignCast(dst));
    const stride: usize = q.stride;
    const len = @as(usize, @intCast(samples)) * stride;
    const dith = q.dither_buf.?;
    const e = q.error_buf.?;
    const m: i32 = @bitCast(~q.mask);
    for (0..len) |i| {
        const o = s[i];
        var v = o;
        const err = dith[i] -% e[i];
        v = addss(v, err);
        v &= m;
        e[i + stride] = e[i] +% (v -% o);
        d[i] = v;
    }
    std.mem.copyForwards(i32, e[0..stride], e[len .. len + stride]);
}

fn qShape(q: *Quant, src: ?*const anyopaque, dst: ?*anyopaque, samples: c.gint) void {
    const nc: usize = @intCast(q.n_coeffs);
    setupDither(q, samples);
    setupError(q, samples, q.n_coeffs);
    const s: [*]const i32 = @ptrCast(@alignCast(src));
    const d: [*]i32 = @ptrCast(@alignCast(dst));
    const stride: usize = q.stride;
    const len = @as(usize, @intCast(samples)) * stride;
    const dith = q.dither_buf.?;
    const e = q.error_buf.?;
    const co = q.coeffs.?;
    const m: i32 = @bitCast(~q.mask);
    for (0..len) |i| {
        var v = s[i];
        var err: i32 = 0;
        var k = i;
        for (0..nc) |j| {
            err -%= e[k] *% co[j];
            k += stride;
        }
        err = (err +% 2) >> 2;
        v = addss(v, err);
        const o = v;
        v = addss(v, dith[i]);
        v &= m;
        e[k] = (v -% o +% 128) >> 8;
        d[i] = v;
    }
    std.mem.copyForwards(i32, e[0 .. stride * nc], e[len .. len + stride * nc]);
}

const SIMPLE = [_]f64{ -0.5, 1.0 };
const MEDIUM = [_]f64{ 0.6149, -1.590, 1.959, -2.165, 2.033 };
const HIGH = [_]f64{ -0.340122, 0.876066, -1.72008, 2.61339, -3.31399, 3.27918, -2.92975, 2.08484 };

fn countPower(v_in: c.guint) c.guint {
    var v = v_in;
    var r: c.guint = 0;
    while (v > 1) : (v >>= 1) r += 1;
    return r;
}

pub export fn gst_audio_quantize_new(dither: c.GstAudioDitherMethod, ns: c.GstAudioNoiseShapingMethod, flags: c.GstAudioQuantizeFlags, fmt: c.GstAudioFormat, channels: c.guint, quantizer: c.guint) ?*c.GstAudioQuantize {
    const fname = "gst_audio_quantize_new";
    if (!check.that(fmt == c.GST_AUDIO_FORMAT_S32, fname, "format == GST_AUDIO_FORMAT_S32")) return null;
    if (!check.that(channels > 0, fname, "channels > 0")) return null;
    const q: *Quant = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Quant))));
    q.dither = dither;
    q.ns = ns;
    q.flags = flags;
    q.format = fmt;
    if (flags & c.GST_AUDIO_QUANTIZE_FLAG_NON_INTERLEAVED != 0) {
        q.stride = 1;
        q.blocks = channels;
    } else {
        q.stride = channels;
        q.blocks = 1;
    }
    q.quantizer = quantizer;
    q.shift = countPower(quantizer);
    q.bias = if (q.shift > 0) @as(u32, 1) << @intCast(q.shift - 1) else 0;
    q.mask = (@as(u32, 1) << @intCast(q.shift)) -% 1;
    q.random_state = 0xc2d6038f;
    q.last_random = if (dither == c.GST_AUDIO_DITHER_TPDF_HF) @ptrCast(@alignCast(c.g_malloc0(4 * q.stride))) else null;
    const coeffs: []const f64 = switch (ns) {
        c.GST_AUDIO_NOISE_SHAPING_HIGH => &HIGH,
        c.GST_AUDIO_NOISE_SHAPING_MEDIUM => &MEDIUM,
        c.GST_AUDIO_NOISE_SHAPING_SIMPLE => &SIMPLE,
        else => &.{},
    };
    if (coeffs.len > 0) {
        q.n_coeffs = @intCast(coeffs.len);
        const co: [*]i32 = @ptrCast(@alignCast(c.g_malloc0(4 * coeffs.len)));
        for (coeffs, 0..) |v, i| co[i] = @intFromFloat(@floor(v * 1024 + 0.5));
        q.coeffs = co;
    }
    if (q.shift == 0) {
        q.quantize = qMemcpy;
    } else {
        const index = 5 * dither + ns;
        q.quantize = if (index == 0) qNone else switch (index % 5) {
            0 => qDither,
            1 => qFeedback,
            else => qShape,
        };
    }
    return @ptrCast(q);
}

pub export fn gst_audio_quantize_free(qp: ?*c.GstAudioQuantize) void {
    if (!check.that(qp != null, "gst_audio_quantize_free", "quant != NULL")) return;
    const q = of(qp);
    c.g_free(q.error_buf);
    c.g_free(q.coeffs);
    c.g_free(q.last_random);
    c.g_free(q.dither_buf);
    c.g_free(q);
}

pub export fn gst_audio_quantize_reset(qp: ?*c.GstAudioQuantize) void {
    const q = of(qp);
    c.g_free(q.error_buf);
    q.error_buf = null;
    q.error_size = 0;
}

pub export fn gst_audio_quantize_samples(qp: ?*c.GstAudioQuantize, in: [*c]const c.gpointer, out: [*c]c.gpointer, samples: c.guint) void {
    const fname = "gst_audio_quantize_samples";
    if (!check.that(qp != null, fname, "quant != NULL")) return;
    if (!check.that(out != null or samples == 0, fname, "out != NULL || samples == 0")) return;
    if (!check.that(in != null or samples == 0, fname, "in != NULL || samples == 0")) return;
    const q = of(qp);
    for (0..q.blocks) |i| q.quantize(q, in[i], out[i], @bitCast(samples));
}
