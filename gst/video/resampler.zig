const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const m = @import("../libm.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Resampler = c.GstVideoResampler;

const Params = struct {
    shift: f64,
    get_tap: *const fn (*const Params, i32, i32, f64) f64,
    b: f64 = 0,
    cc: f64 = 0,
    ex: f64 = 0,
    fx: f64 = 0,
    envelope: f64 = 0,
    sharpness: f64 = 0,
    sharpen: f64 = 0,
};

fn optDouble(options: ?*c.GstStructure, name: [*c]const u8, def: f64) f64 {
    var v: f64 = 0;
    if (options == null or c.gst_structure_get_double(options, name, &v) == 0) return def;
    return v;
}

fn optInt(options: ?*c.GstStructure, name: [*c]const u8, def: c.gint) c.gint {
    var v: c.gint = 0;
    if (options == null or c.gst_structure_get_int(options, name, &v) == 0) return def;
    return v;
}

fn sinc(x: f64) f64 {
    if (x == 0) return 1;
    return m.sin(std.math.pi * x) / (std.math.pi * x);
}

fn envelope(x: f64) f64 {
    if (x <= -1 or x >= 1) return 0;
    return sinc(x);
}

fn nearestTap(_: *const Params, _: i32, _: i32, _: f64) f64 {
    return 1.0;
}

fn linearTap(p: *const Params, l: i32, xi: i32, x: f64) f64 {
    const a = @abs(x - @as(f64, @floatFromInt(xi + l))) * p.fx;
    return if (a < 1.0) 1.0 - a else 0.0;
}

fn cubicTap(p: *const Params, l: i32, xi: i32, x: f64) f64 {
    const a = @abs(x - @as(f64, @floatFromInt(xi + l))) * p.fx;
    const a2 = a * a;
    const a3 = a2 * a;
    const b = p.b;
    const cc = p.cc;
    if (a <= 1.0) return ((12.0 - 9.0 * b - 6.0 * cc) * a3 + (-18.0 + 12.0 * b + 6.0 * cc) * a2 + (6.0 - 2.0 * b)) / 6.0;
    if (a <= 2.0) return ((-b - 6.0 * cc) * a3 + (6.0 * b + 30.0 * cc) * a2 + (-12.0 * b - 48.0 * cc) * a + (8.0 * b + 24.0 * cc)) / 6.0;
    return 0.0;
}

fn sincTap(p: *const Params, l: i32, xi: i32, x: f64) f64 {
    return sinc((x - @as(f64, @floatFromInt(xi + l))) * p.fx);
}

fn lanczosTap(p: *const Params, l: i32, xi: i32, x: f64) f64 {
    const d = x - @as(f64, @floatFromInt(xi + l));
    return (sinc(d * p.fx) - p.sharpen) * envelope(d * p.ex);
}

fn calculate(p: *const Params, r: *allowzero Resampler) void {
    const in_size: i32 = @bitCast(r.in_size);
    const out_size: i32 = @bitCast(r.out_size);
    const max_taps: i32 = @bitCast(r.max_taps);
    const nt: usize = r.max_taps;
    const tap_offs = @divTrunc(max_taps - 1, 2);
    const corr: f64 = if (max_taps == 1) 0.0 else 0.5;
    const n: usize = @intCast(r.out_size);
    r.taps = @ptrCast(@alignCast(c.g_malloc(@sizeOf(f64) * nt * n)));
    r.n_taps = @ptrCast(@alignCast(c.g_malloc(@sizeOf(u32) * n)));
    r.offset = @ptrCast(@alignCast(c.g_malloc(@sizeOf(u32) * n)));
    r.phase = @ptrCast(@alignCast(c.g_malloc(@sizeOf(u32) * n)));
    var j: i32 = 0;
    while (j < out_size) : (j += 1) {
        const ju: usize = @intCast(j);
        const ox = (0.5 + @as(f64, @floatFromInt(j)) - p.shift) / @as(f64, @floatFromInt(out_size));
        var x = ox * @as(f64, @floatFromInt(in_size)) - corr;
        const hi: f64 = @floatFromInt(in_size - 1);
        x = if (x > hi) hi else if (x < 0) 0 else x;
        const xi: i32 = @intFromFloat(@floor(x - @as(f64, @floatFromInt(tap_offs))));
        r.offset[ju] = @bitCast(xi);
        r.phase[ju] = @bitCast(j);
        r.n_taps[ju] = @bitCast(max_taps);
        const taps = r.taps + ju * nt;
        var weight: f64 = 0;
        var l: i32 = 0;
        while (l < max_taps) : (l += 1) {
            taps[@intCast(l)] = p.get_tap(p, l, xi, x);
            weight += taps[@intCast(l)];
        }
        for (0..nt) |k| taps[k] /= weight;
        if (xi < 0) {
            const sh: usize = @intCast(-xi);
            for (0..sh) |k| taps[sh] += taps[k];
            var k: usize = 0;
            while (k < nt - sh) : (k += 1) taps[k] = taps[sh + k];
            while (k < nt) : (k += 1) taps[k] = 0;
            r.offset[ju] +%= @intCast(sh);
        }
        if (xi > in_size - max_taps) {
            const sh: usize = @intCast(xi - (in_size - max_taps));
            for (0..sh) |k| taps[nt - sh - 1] += taps[nt - sh + k];
            for (0..nt - sh) |k| taps[nt - 1 - k] = taps[nt - 1 - sh - k];
            for (0..sh) |k| taps[k] = 0;
            r.offset[ju] -%= @intCast(sh);
        }
    }
}

pub export fn gst_video_resampler_init(r: [*c]Resampler, method: c.GstVideoResamplerMethod, flags: c.GstVideoResamplerFlags, n_phases: c.guint, n_taps_in: c.guint, shift: f64, in_size: c.guint, out_size: c.guint, options: ?*c.GstStructure) c.gboolean {
    const fname = "gst_video_resampler_init";
    if (!check.that(in_size != 0, fname, "in_size != 0")) return 0;
    if (!check.that(out_size != 0, fname, "out_size != 0")) return 0;
    if (!check.that(n_phases == out_size, fname, "n_phases == out_size")) return 0;
    r[0].in_size = @bitCast(in_size);
    r[0].out_size = @bitCast(out_size);
    r[0].n_phases = n_phases;
    var p = Params{ .shift = shift, .get_tap = nearestTap };
    p.sharpness = optDouble(options, c.GST_VIDEO_RESAMPLER_OPT_SHARPNESS, 1.0);
    p.sharpen = optDouble(options, c.GST_VIDEO_RESAMPLER_OPT_SHARPEN, 0.0);
    const scale = @as(f64, @floatFromInt(in_size)) / @as(f64, @floatFromInt(out_size));
    p.fx = if (scale > 1.0) (1.0 / scale) * p.sharpness else 1.0 * p.sharpness;
    const max_taps = optInt(options, c.GST_VIDEO_RESAMPLER_OPT_MAX_TAPS, 128);
    var n_taps = @min(n_taps_in, @as(c.guint, @bitCast(max_taps)));
    switch (method) {
        c.GST_VIDEO_RESAMPLER_METHOD_NEAREST => {
            p.envelope = optDouble(options, c.GST_VIDEO_RESAMPLER_OPT_ENVELOPE, 2.0);
            p.get_tap = nearestTap;
            if (n_taps == 0) n_taps = 1;
        },
        c.GST_VIDEO_RESAMPLER_METHOD_LINEAR => {
            p.get_tap = linearTap;
            p.envelope = 1.0;
        },
        c.GST_VIDEO_RESAMPLER_METHOD_CUBIC => {
            p.b = optDouble(options, c.GST_VIDEO_RESAMPLER_OPT_CUBIC_B, 1.0 / 3.0);
            p.cc = optDouble(options, c.GST_VIDEO_RESAMPLER_OPT_CUBIC_C, 1.0 / 3.0);
            p.envelope = 2.0;
            p.get_tap = cubicTap;
        },
        c.GST_VIDEO_RESAMPLER_METHOD_SINC => {
            p.envelope = optDouble(options, c.GST_VIDEO_RESAMPLER_OPT_ENVELOPE, 2.0);
            p.get_tap = sincTap;
        },
        c.GST_VIDEO_RESAMPLER_METHOD_LANCZOS => {
            p.envelope = optDouble(options, c.GST_VIDEO_RESAMPLER_OPT_ENVELOPE, 2.0);
            p.get_tap = lanczosTap;
        },
        else => {},
    }
    if (n_taps == 0) {
        const dx = @ceil(2.0 * p.envelope / p.fx);
        const hi: f64 = @floatFromInt(max_taps);
        n_taps = @intFromFloat(if (dx > hi) hi else if (dx < 0) 0 else dx);
    }
    if (flags & c.GST_VIDEO_RESAMPLER_FLAG_HALF_TAPS != 0 and n_taps > 3) n_taps /= 2;
    p.fx = 2.0 * p.envelope / @as(f64, @floatFromInt(n_taps));
    p.ex = 2.0 / @as(f64, @floatFromInt(n_taps));
    if (n_taps > in_size) n_taps = in_size;
    r[0].max_taps = n_taps;
    calculate(&p, &r[0]);
    return 1;
}

pub export fn gst_video_resampler_clear(r: [*c]Resampler) void {
    if (!check.that(r != null, "gst_video_resampler_clear", "resampler != NULL")) return;
    c.g_free(r[0].phase);
    c.g_free(r[0].offset);
    c.g_free(r[0].n_taps);
    c.g_free(r[0].taps);
}
