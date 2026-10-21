const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const resampler = @import("resampler.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Opaque = c.GstVideoScaler;
const Resampler = c.GstVideoResampler;
const INTERLACED = c.GST_VIDEO_SCALER_FLAG_INTERLACED;
const FILE = "../gst-libs/gst/video/video-scaler.c";

const Scaler = struct {
    method: c.GstVideoResamplerMethod,
    flags: c.GstVideoScalerFlags,
    r: Resampler,
    merged: bool,
    in_y_offset: c.gint,
    out_y_offset: c.gint,
    taps_s16: ?[*]i16,
    taps_s16_4: ?[*]i16,
    offset_n: ?[*]u32,
    inc: c.gint,
    tmpwidth: c.gint,
    tmpline1: ?[*]u8,
    tmpline2: ?[*]u8,
};

fn of(p: ?*Opaque) *Scaler {
    return @ptrCast(@alignCast(p.?));
}

fn U(v: c.gint) c.guint {
    return @bitCast(v);
}

fn alloc(comptime T: type, n: usize) [*]T {
    return @ptrCast(@alignCast(c.g_malloc(@sizeOf(T) * n)));
}

fn zip(out: *Resampler, r1: *const Resampler, r2: *const Resampler) void {
    if (!check.that(r1.max_taps == r2.max_taps, "resampler_zip", "r1->max_taps == r2->max_taps")) return;
    const n: usize = @intCast(r1.out_size + r2.out_size);
    const nt: usize = r1.max_taps;
    const offset = alloc(u32, n);
    const phase = alloc(u32, n);
    const taps = alloc(f64, nt * n);
    out.in_size = r1.in_size + r2.in_size;
    out.out_size = @intCast(n);
    out.max_taps = @intCast(nt);
    out.n_phases = @intCast(n);
    out.offset = offset;
    out.phase = phase;
    out.n_taps = alloc(u32, n);
    out.taps = taps;
    for (0..n) |i| {
        const idx = i / 2;
        const r = if (i & 1 != 0) r2 else r1;
        offset[i] = r.offset[idx] *% 2 +% @as(u32, @intCast(i & 1));
        phase[i] = @intCast(i);
        @memcpy(taps[i * nt ..][0..nt], (r.taps + r.phase[idx] * nt)[0..nt]);
    }
}

fn reallocTmp(s: *Scaler, n_elems: c.gint, width: c.gint) void {
    var n_taps: c.gint = @bitCast(s.r.max_taps);
    if (s.flags & INTERLACED != 0) n_taps *= 2;
    const w: usize = @intCast(width);
    const e: usize = @intCast(n_elems);
    s.tmpline1 = @ptrCast(c.g_realloc(s.tmpline1, 4 * w * e * @as(usize, @intCast(n_taps))));
    s.tmpline2 = @ptrCast(c.g_realloc(s.tmpline2, 4 * w * e));
    s.tmpwidth = width;
}

pub export fn gst_video_scaler_new(method: c.GstVideoResamplerMethod, flags: c.GstVideoScalerFlags, n_taps_in: c.guint, in_size: c.guint, out_size: c.guint, options: ?*c.GstStructure) ?*Opaque {
    const fname = "gst_video_scaler_new";
    if (!check.that(in_size != 0, fname, "in_size != 0")) return null;
    if (!check.that(out_size != 0, fname, "out_size != 0")) return null;
    const s: *Scaler = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Scaler))));
    s.method = method;
    s.flags = flags;
    if (flags & INTERLACED != 0) {
        var t: Resampler = undefined;
        var b: Resampler = undefined;
        const shift = (0.5 * @as(f64, @floatFromInt(out_size))) / @as(f64, @floatFromInt(in_size));
        _ = resampler.gst_video_resampler_init(&t, method, c.GST_VIDEO_RESAMPLER_FLAG_HALF_TAPS, (out_size + 1) / 2, n_taps_in, shift, (in_size + 1) / 2, (out_size + 1) / 2, options);
        const n_taps = t.max_taps;
        _ = resampler.gst_video_resampler_init(&b, method, 0, out_size -% U(t.out_size), n_taps, -shift, in_size -% U(t.in_size), out_size -% U(t.out_size), options);
        zip(&s.r, &t, &b);
        resampler.gst_video_resampler_clear(&t);
        resampler.gst_video_resampler_clear(&b);
    } else {
        _ = resampler.gst_video_resampler_init(&s.r, method, c.GST_VIDEO_RESAMPLER_FLAG_NONE, out_size, n_taps_in, 0.0, in_size, out_size, options);
    }
    s.inc = if (out_size == 1) 0 else @bitCast(((in_size -% 1) << 16) / (out_size - 1) -% 1);
    return @ptrCast(s);
}

pub export fn gst_video_scaler_free(scale: ?*Opaque) void {
    if (!check.that(scale != null, "gst_video_scaler_free", "scale != NULL")) return;
    const s = of(scale);
    resampler.gst_video_resampler_clear(&s.r);
    c.g_free(s.taps_s16);
    c.g_free(s.taps_s16_4);
    c.g_free(s.offset_n);
    c.g_free(s.tmpline1);
    c.g_free(s.tmpline2);
    c.g_free(s);
}

pub export fn gst_video_scaler_get_max_taps(scale: ?*Opaque) c.guint {
    if (!check.that(scale != null, "gst_video_scaler_get_max_taps", "scale != NULL")) return 0;
    return of(scale).r.max_taps;
}

pub export fn gst_video_scaler_get_coeff(scale: ?*Opaque, out_offset: c.guint, in_offset: [*c]c.guint, n_taps: [*c]c.guint) [*c]const f64 {
    const fname = "gst_video_scaler_get_coeff";
    if (!check.that(scale != null, fname, "scale != NULL")) return null;
    const s = of(scale);
    if (!check.that(out_offset < U(s.r.out_size), fname, "out_offset < scale->resampler.out_size")) return null;
    if (in_offset != null) in_offset.* = s.r.offset[out_offset];
    if (n_taps != null) {
        n_taps.* = s.r.max_taps;
        if (s.flags & INTERLACED != 0) n_taps.* *%= 2;
    }
    return s.r.taps + @as(usize, s.r.phase[out_offset]) * s.r.max_taps;
}

fn toI16(x: f64) i16 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return 0;
    const v: i32 = @intFromFloat(x);
    return @truncate(v);
}

fn convertCoeff(src: [*]const f64, dest: [*]i16, n: usize, precision: u5) void {
    const target: c.gint = @as(c.gint, 1) << precision;
    const mult: f64 = @floatFromInt(target);
    var lo: f64 = 0.0;
    var hi: f64 = 1.0;
    var off: f64 = 0.5;
    for (0..64) |_| {
        var sum: c.gint = 0;
        for (0..n) |j| {
            const tap = toI16(@floor(off + src[j] * mult));
            dest[j] = tap;
            sum += tap;
        }
        if (sum == target) break;
        if (lo == hi) break;
        if (sum < target) {
            if (off > lo) lo = off;
            off += (hi - lo) / 2;
        } else {
            if (off < hi) hi = off;
            off -= (hi - lo) / 2;
        }
    }
}

fn makeTaps(s: *Scaler, n_elems: usize, precision: u5) void {
    const np: usize = s.r.n_phases;
    const nt: usize = s.r.max_taps;
    const t16 = alloc(i16, np * nt);
    s.taps_s16 = t16;
    for (0..np) |i| convertCoeff(s.r.taps + i * nt, t16 + i * nt, nt, precision);
    const n: usize = @intCast(s.r.out_size);
    const t4 = alloc(i16, n * nt * 4);
    s.taps_s16_4 = t4;
    const on = alloc(u32, n * nt);
    s.offset_n = on;
    const src_inc: u32 = if (s.flags & INTERLACED != 0) 2 else 1;
    for (0..nt) |j| {
        const ju: u32 = @intCast(j);
        for (0..n) |i| {
            if (s.merged) {
                const yoff: usize = @intCast(s.out_y_offset);
                on[j * n + i] = s.r.offset[i] +% (if (i & 1 == yoff) 2 * ju else 4 * ju);
            } else on[j * n + i] = s.r.offset[i] +% ju * src_inc;
            const tap = t16[@as(usize, s.r.phase[i]) * nt + j];
            for (0..@min(n_elems, 4)) |e| t4[(j * n + i) * n_elems + e] = tap;
        }
    }
}

fn sat8(v: i16) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn sat16(v: i32) u16 {
    return @intCast(std.math.clamp(v, 0, 65535));
}

fn mulw(a: u8, t: i16) i16 {
    return @as(i16, a) *% t;
}

fn finish8(w: i16) u8 {
    return sat8((w +% 32) >> 6);
}

fn bytes(p: anytype) [*]u8 {
    return @ptrCast(p);
}

fn hNear(comptime T: type) fn (*Scaler, c.gpointer, c.gpointer, c.guint, c.guint, c.guint) void {
    return struct {
        fn f(s: *Scaler, src: c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, _: c.guint) void {
            const d: [*]align(1) T = @ptrCast(bytes(dest) + dest_offset * @sizeOf(T));
            const sp: [*]align(1) const T = @ptrCast(src);
            const off = s.r.offset + dest_offset;
            for (0..width) |i| d[i] = sp[off[i]];
        }
    }.f;
}

fn hNear3(s: *Scaler, src: c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, _: c.guint) void {
    const d = bytes(dest) + dest_offset;
    const sp = bytes(src);
    const off = s.r.offset + dest_offset;
    for (0..width) |i| {
        const j: usize = off[i] *% 3;
        d[i * 3] = sp[j];
        d[i * 3 + 1] = sp[j + 1];
        d[i * 3 + 2] = sp[j + 2];
    }
}

fn lin(a: u8, b: u8, tmp: c.gint) u8 {
    const f: u32 = @intCast((tmp >> 8) & 0xff);
    return @truncate((@as(u32, a) * (256 - f) + @as(u32, b) * f) >> 8);
}

fn h2tap1u8(s: *Scaler, src: c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, _: c.guint) void {
    const d = bytes(dest) + dest_offset;
    const sp = bytes(src);
    for (0..width) |i| {
        const tmp: c.gint = s.inc *% @as(c.gint, @intCast(i));
        const k: usize = @intCast(tmp >> 16);
        d[i] = lin(sp[k], sp[k + 1], tmp);
    }
}

fn h2tap4u8(s: *Scaler, src: c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, _: c.guint) void {
    const d = bytes(dest) + dest_offset * 4;
    const sp = bytes(src);
    for (0..width) |i| {
        const tmp: c.gint = s.inc *% @as(c.gint, @intCast(i));
        const k: usize = @intCast(tmp >> 16);
        for (0..4) |e| d[i * 4 + e] = lin(sp[k * 4 + e], sp[(k + 1) * 4 + e], tmp);
    }
}

fn hNtapU8(s: *Scaler, src: c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, n_elems: c.guint) void {
    if (s.taps_s16 == null) makeTaps(s, n_elems, 6);
    const nt: usize = s.r.max_taps;
    const on = s.offset_n.?;
    const px = s.tmpline1.?;
    const count = width * nt;
    var d: [*]u8 = undefined;
    switch (n_elems) {
        1 => {
            const sp = bytes(src);
            for (0..count) |i| px[i] = sp[on[i]];
            d = bytes(dest) + dest_offset;
        },
        2 => {
            const p16: [*]align(1) u16 = @ptrCast(px);
            const sp: [*]align(1) const u16 = @ptrCast(src);
            for (0..count) |i| p16[i] = sp[on[i]];
            d = bytes(dest) + dest_offset * 2;
        },
        3 => {
            const sp = bytes(src);
            for (0..count) |i| {
                const j: usize = on[i] *% 3;
                px[i * 3] = sp[j];
                px[i * 3 + 1] = sp[j + 1];
                px[i * 3 + 2] = sp[j + 2];
            }
            d = bytes(dest) + dest_offset * 3;
        },
        4 => {
            const p32: [*]align(1) u32 = @ptrCast(px);
            const sp: [*]align(1) const u32 = @ptrCast(src);
            for (0..count) |i| p32[i] = sp[on[i]];
            d = bytes(dest) + dest_offset * 4;
        },
        else => return,
    }
    const taps = s.taps_s16_4.?;
    const n: usize = width * n_elems;
    for (0..n) |i| {
        var w: i16 = 0;
        for (0..nt) |k| w +%= mulw(px[k * n + i], taps[k * n + i]);
        d[i] = finish8(w);
    }
}

fn hNtapU16(s: *Scaler, src: c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, n_elems: c.guint) void {
    if (s.taps_s16 == null) makeTaps(s, n_elems, 12);
    const nt: usize = s.r.max_taps;
    const on = s.offset_n.?;
    const px: [*]align(1) u16 = @ptrCast(s.tmpline1.?);
    const count = width * nt;
    var d: [*]align(1) u16 = undefined;
    switch (n_elems) {
        1 => {
            const sp: [*]align(1) const u16 = @ptrCast(src);
            for (0..count) |i| px[i] = sp[on[i]];
            d = @ptrCast(bytes(dest) + dest_offset * 2);
        },
        4 => {
            const p64: [*]align(1) u64 = @ptrCast(px);
            const sp: [*]align(1) const u64 = @ptrCast(src);
            for (0..count) |i| p64[i] = sp[on[i]];
            d = @ptrCast(bytes(dest) + dest_offset * 8);
        },
        else => return,
    }
    const taps = s.taps_s16_4.?;
    const n: usize = width * n_elems;
    for (0..n) |i| {
        var w: i32 = 0;
        for (0..nt) |k| w +%= @as(i32, px[k * n + i]) *% @as(i32, taps[k * n + i]);
        d[i] = if (nt == 2) sat16((w +% 4096) >> 12) else sat16((w +% 4095) >> 12);
    }
}

fn srcInc(s: *const Scaler) usize {
    return if (s.flags & INTERLACED != 0) 2 else 1;
}

fn vNear(comptime size: usize) fn (*Scaler, [*c]c.gpointer, c.gpointer, c.guint, c.guint, c.guint) void {
    return struct {
        fn f(_: *Scaler, srcs: [*c]c.gpointer, dest: c.gpointer, _: c.guint, width: c.guint, n_elems: c.guint) void {
            if (dest == srcs[0]) return;
            const n = n_elems * size * width;
            @memcpy(bytes(dest)[0..n], bytes(srcs[0])[0..n]);
        }
    }.f;
}

fn v2tapU8(s: *Scaler, srcs: [*c]c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, n_elems: c.guint) void {
    if (s.taps_s16 == null) makeTaps(s, n_elems, 8);
    const nt: usize = s.r.max_taps;
    const inc = srcInc(s);
    const d = bytes(dest);
    const s1 = bytes(srcs[0]);
    const s2 = bytes(srcs[inc]);
    const p1 = s.taps_s16.?[dest_offset * nt + 1];
    for (0..width * n_elems) |i| {
        const w = ((@as(i16, s2[i]) -% @as(i16, s1[i])) *% p1) +% 128;
        const t: u8 = @truncate(@as(u16, @bitCast(w)) >> 8);
        d[i] = t +% s1[i];
    }
}

fn v2tapU16(s: *Scaler, srcs: [*c]c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, n_elems: c.guint) void {
    if (s.taps_s16 == null) makeTaps(s, n_elems, 12);
    const nt: usize = s.r.max_taps;
    const inc = srcInc(s);
    const d: [*]align(1) u16 = @ptrCast(dest);
    const s1: [*]align(1) const u16 = @ptrCast(srcs[0]);
    const s2: [*]align(1) const u16 = @ptrCast(srcs[inc]);
    const p1: i32 = @as(u16, @bitCast(s.taps_s16.?[dest_offset * nt + 1]));
    for (0..width * n_elems) |i| {
        const a: i32 = s1[i];
        const l2 = (((@as(i32, s2[i]) -% a) *% p1) +% 4096) >> 12;
        d[i] = sat16(a +% l2);
    }
}

fn v4tapU8(s: *Scaler, srcs: [*c]c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, n_elems: c.guint) void {
    if (s.taps_s16 == null) makeTaps(s, n_elems, 6);
    const nt: usize = s.r.max_taps;
    const taps = s.taps_s16.? + dest_offset * nt;
    const inc = srcInc(s);
    const d = bytes(dest);
    for (0..width * n_elems) |i| {
        var w: i16 = 0;
        for (0..4) |k| w +%= mulw(bytes(srcs[k * inc])[i], taps[k]);
        d[i] = finish8(w);
    }
}

fn vNtapU8(s: *Scaler, srcs: [*c]c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, n_elems: c.guint) void {
    if (s.taps_s16 == null) makeTaps(s, n_elems, 6);
    const nt: usize = s.r.max_taps;
    const taps = s.taps_s16.? + @as(usize, s.r.phase[dest_offset]) * nt;
    const inc = srcInc(s);
    const d = bytes(dest);
    for (0..width * n_elems) |i| {
        var w: i16 = 0;
        for (0..nt) |k| w +%= mulw(bytes(srcs[k * inc])[i], taps[k]);
        d[i] = finish8(w);
    }
}

fn vNtapU16(s: *Scaler, srcs: [*c]c.gpointer, dest: c.gpointer, dest_offset: c.guint, width: c.guint, n_elems: c.guint) void {
    if (s.taps_s16 == null) makeTaps(s, n_elems, 12);
    const nt: usize = s.r.max_taps;
    const taps = s.taps_s16.? + @as(usize, s.r.phase[dest_offset]) * nt;
    const inc = srcInc(s);
    const d: [*]align(1) u16 = @ptrCast(dest);
    for (0..width * n_elems) |i| {
        var w: i32 = 0;
        for (0..nt) |k| {
            const sp: [*]align(1) const u16 = @ptrCast(srcs[k * inc]);
            w +%= @as(i32, sp[i]) *% @as(i32, taps[k]);
        }
        d[i] = sat16((w +% 4095) >> 12);
    }
}

fn yOffset(fmt: c.GstVideoFormat) c.gint {
    return switch (fmt) {
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YVYU => 0,
        else => 1,
    };
}

pub export fn gst_video_scaler_combine_packed_YUV(y_scale: ?*Opaque, uv_scale: ?*Opaque, in_format: c.GstVideoFormat, out_format: c.GstVideoFormat) ?*Opaque {
    const fname = "gst_video_scaler_combine_packed_YUV";
    if (!check.that(y_scale != null, fname, "y_scale != NULL")) return null;
    if (!check.that(uv_scale != null, fname, "uv_scale != NULL")) return null;
    const y = of(y_scale);
    const uv = of(uv_scale);
    if (!check.that(uv.r.max_taps == y.r.max_taps, fname, "uv_scale->resampler.max_taps == y_scale->resampler.max_taps")) return null;
    const s: *Scaler = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Scaler))));
    s.method = y.method;
    s.flags = y.flags;
    s.merged = true;
    const n: usize = ((U(y.r.out_size) *% 2) +% 3) & ~@as(u32, 3);
    const nt: usize = y.r.max_taps;
    const offset = alloc(u32, n);
    const phase = alloc(u32, n);
    const taps = alloc(f64, nt * n);
    s.r.in_size = y.r.in_size *% 2;
    s.r.out_size = @intCast(n);
    s.r.max_taps = @intCast(nt);
    s.r.n_phases = @intCast(n);
    s.r.offset = offset;
    s.r.phase = phase;
    s.r.n_taps = alloc(u32, n);
    s.r.taps = taps;
    s.in_y_offset = yOffset(in_format);
    s.out_y_offset = yOffset(out_format);
    s.inc = y.inc;
    const yoff: usize = @intCast(s.out_y_offset);
    for (0..n) |i| {
        if (i & 1 == yoff) {
            const ic: usize = @min(i / 2, U(y.r.out_size) -% 1);
            offset[i] = y.r.offset[ic] *% 2 +% @as(u32, @bitCast(s.in_y_offset));
            @memcpy(taps[i * nt ..][0..nt], (y.r.taps + @as(usize, y.r.phase[ic]) * nt)[0..nt]);
        } else {
            const ic: usize = @min(i / 4, U(uv.r.out_size) -% 1);
            offset[i] = uv.r.offset[ic] *% 4 +% @as(u32, @intCast(i & 3));
            @memcpy(taps[i * nt ..][0..nt], (uv.r.taps + @as(usize, uv.r.phase[ic]) * nt)[0..nt]);
        }
        phase[i] = @intCast(i);
    }
    return @ptrCast(s);
}

const HFunc = *const fn (*Scaler, c.gpointer, c.gpointer, c.guint, c.guint, c.guint) void;
const VFunc = *const fn (*Scaler, [*c]c.gpointer, c.gpointer, c.guint, c.guint, c.guint) void;

const Funcs = struct { h: ?HFunc = null, v: ?VFunc = null, n_elems: c.guint, bits: c.guint };

fn functions(h: ?*Scaler, v: ?*Scaler, fmt: c.GstVideoFormat, width: *c.guint) ?Funcs {
    var mono = false;
    var f: Funcs = undefined;
    switch (fmt) {
        c.GST_VIDEO_FORMAT_GRAY8 => {
            f = .{ .bits = 8, .n_elems = 1 };
            mono = true;
        },
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YVYU, c.GST_VIDEO_FORMAT_UYVY => {
            f = .{ .bits = 8, .n_elems = 1 };
            width.* = (width.* *% 2 +% 3) & ~@as(c.guint, 3);
        },
        c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_BGR, c.GST_VIDEO_FORMAT_v308, c.GST_VIDEO_FORMAT_IYU2 => f = .{ .bits = 8, .n_elems = 3 },
        c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_RGBx, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_xRGB, c.GST_VIDEO_FORMAT_xBGR, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_ABGR => f = .{ .bits = 8, .n_elems = 4 },
        c.GST_VIDEO_FORMAT_ARGB64, c.GST_VIDEO_FORMAT_ARGB64_LE, c.GST_VIDEO_FORMAT_ARGB64_BE, c.GST_VIDEO_FORMAT_RGBA64_BE, c.GST_VIDEO_FORMAT_RGBA64_LE, c.GST_VIDEO_FORMAT_BGRA64_BE, c.GST_VIDEO_FORMAT_BGRA64_LE, c.GST_VIDEO_FORMAT_ABGR64_BE, c.GST_VIDEO_FORMAT_ABGR64_LE, c.GST_VIDEO_FORMAT_AYUV64 => f = .{ .bits = 16, .n_elems = 4 },
        c.GST_VIDEO_FORMAT_GRAY16_LE, c.GST_VIDEO_FORMAT_GRAY16_BE => {
            f = .{ .bits = 16, .n_elems = 1 };
            mono = true;
        },
        c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV16, c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_NV24, c.GST_VIDEO_FORMAT_NV61 => f = .{ .bits = 8, .n_elems = 2 },
        else => return null,
    }
    const ht: c.guint = if (h) |x| x.r.max_taps else 0;
    const vt: c.guint = if (v) |x| x.r.max_taps else 0;
    if (f.bits == 8) {
        switch (ht) {
            0 => {},
            1 => f.h = switch (f.n_elems) {
                1 => hNear(u8),
                2 => hNear(u16),
                3 => hNear3,
                else => hNear(u32),
            },
            2 => f.h = if (f.n_elems == 1 and mono) h2tap1u8 else if (f.n_elems == 4) h2tap4u8 else hNtapU8,
            else => f.h = hNtapU8,
        }
        switch (vt) {
            0 => {},
            1 => f.v = vNear(1),
            2 => f.v = v2tapU8,
            4 => f.v = v4tapU8,
            else => f.v = vNtapU8,
        }
    } else {
        switch (ht) {
            0 => {},
            1 => f.h = if (f.n_elems == 1) hNear(u16) else hNear(u64),
            else => f.h = hNtapU16,
        }
        switch (vt) {
            0 => {},
            1 => f.v = vNear(2),
            2 => f.v = v2tapU16,
            else => f.v = vNtapU16,
        }
    }
    return f;
}

fn warn() void {}

pub export fn gst_video_scaler_horizontal(scale: ?*Opaque, fmt: c.GstVideoFormat, src: c.gpointer, dest: c.gpointer, dest_offset: c.guint, width_in: c.guint) void {
    const fname = "gst_video_scaler_horizontal";
    if (!check.that(scale != null, fname, "scale != NULL")) return;
    if (!check.that(src != null, fname, "src != NULL")) return;
    if (!check.that(dest != null, fname, "dest != NULL")) return;
    const s = of(scale);
    if (!check.that(dest_offset +% width_in <= U(s.r.out_size), fname, "dest_offset + width <= scale->resampler.out_size")) return;
    var width = width_in;
    const f = functions(s, null, fmt, &width) orelse return warn();
    const func = f.h orelse return warn();
    if (s.tmpwidth < @as(c.gint, @bitCast(width))) reallocTmp(s, @bitCast(f.n_elems), @bitCast(width));
    func(s, src, dest, dest_offset, width, f.n_elems);
}

pub export fn gst_video_scaler_vertical(scale: ?*Opaque, fmt: c.GstVideoFormat, src_lines: [*c]c.gpointer, dest: c.gpointer, dest_offset: c.guint, width_in: c.guint) void {
    const fname = "gst_video_scaler_vertical";
    if (!check.that(scale != null, fname, "scale != NULL")) return;
    if (!check.that(src_lines != null, fname, "src_lines != NULL")) return;
    if (!check.that(dest != null, fname, "dest != NULL")) return;
    const s = of(scale);
    if (!check.that(dest_offset < U(s.r.out_size), fname, "dest_offset < scale->resampler.out_size")) return;
    var width = width_in;
    const f = functions(null, s, fmt, &width) orelse return warn();
    const func = f.v orelse return warn();
    if (s.tmpwidth < @as(c.gint, @bitCast(width))) reallocTmp(s, @bitCast(f.n_elems), @bitCast(width));
    func(s, src_lines, dest, dest_offset, width, f.n_elems);
}

fn line(p: c.gpointer, stride: c.gint, i: anytype) [*]u8 {
    return @ptrFromInt(@intFromPtr(p) +% @as(usize, @bitCast(@as(isize, stride) * @as(isize, @intCast(i)))));
}

fn assert(ok: bool, ln: c_int, comptime expr: [*:0]const u8) void {
    if (!ok) c.g_assertion_message_expr(check.DOMAIN, FILE, ln, "gst_video_scaler_2d", expr);
}

pub export fn gst_video_scaler_2d(hscale: ?*Opaque, vscale: ?*Opaque, fmt: c.GstVideoFormat, src: c.gpointer, src_stride: c.gint, dest: c.gpointer, dest_stride: c.gint, x: c.guint, y: c.guint, width_in: c.guint, height: c.guint) void {
    const fname = "gst_video_scaler_2d";
    if (!check.that(src != null, fname, "src != NULL")) return;
    if (!check.that(dest != null, fname, "dest != NULL")) return;
    const hs: ?*Scaler = if (hscale) |p| of(p) else null;
    const vs: ?*Scaler = if (vscale) |p| of(p) else null;
    var width = width_in;
    const f = functions(hs, vs, fmt, &width) orelse return warn();
    const n_elems = f.n_elems;
    const interlaced = if (vs) |v| v.flags & INTERLACED != 0 else false;
    const tmpLine = struct {
        fn at(s: *Scaler, i: usize, w: c.guint, n: c.guint) [*]u8 {
            return s.tmpline1.? + i * (4 * @as(usize, w) * n);
        }
    }.at;
    if (vs == null) {
        if (hs == null) {
            const xo = x *% n_elems;
            const xw = width *% n_elems *% (f.bits / 8);
            var sp = line(src, src_stride, y) + xo;
            var dp = line(dest, dest_stride, y) + xo;
            var i = y;
            while (i < height) : (i += 1) {
                @memcpy(dp[0..xw], sp[0..xw]);
                dp = line(dp, dest_stride, 1);
                sp = line(sp, src_stride, 1);
            }
        } else {
            const h = hs.?;
            if (h.tmpwidth < @as(c.gint, @bitCast(width))) reallocTmp(h, @bitCast(n_elems), @bitCast(width));
            var i = y;
            while (i < height) : (i += 1) f.h.?(h, line(src, src_stride, i), line(dest, dest_stride, i), x, width, n_elems);
        }
        return;
    }
    const v = vs.?;
    if (v.tmpwidth < @as(c.gint, @bitCast(width))) reallocTmp(v, @bitCast(n_elems), @bitCast(width));
    const v_taps: usize = v.r.max_taps;
    const mult: usize = if (interlaced) 2 else 1;
    var lines_buf: [512]c.gpointer = undefined;
    const lines: [*c]c.gpointer = &lines_buf;
    for (0..mult * v_taps) |k| lines[k] = null;
    const src_inc: c.guint = if (interlaced) 2 else 1;
    if (hs == null) {
        var i = y;
        while (i < height) : (i += 1) {
            const in = v.r.offset[i];
            for (0..v_taps) |j| {
                const l = in +% @as(c.guint, @intCast(j)) *% src_inc;
                assert(l < U(v.r.in_size), 1524, "l < vscale->resampler.in_size");
                lines[j * src_inc] = line(src, src_stride, l);
            }
            f.v.?(v, lines, line(dest, dest_stride, i), i, width, n_elems);
        }
        return;
    }
    const h = hs.?;
    var tl_buf: [512]c.guint = undefined;
    const tl = tl_buf[0 .. mult * v_taps];
    @memset(tl, 0xffffffff);
    if (h.tmpwidth < @as(c.gint, @bitCast(width))) reallocTmp(h, @bitCast(n_elems), @bitCast(width));
    const s1: c.gint = @bitCast(width *% v.r.offset[height - 1]);
    const s2: c.gint = @bitCast(width *% height);
    if (s1 <= s2) {
        var i = y;
        while (i < height) : (i += 1) {
            const f2: usize = if (interlaced and i % 2 == 1) v_taps else 0;
            const in = v.r.offset[i];
            for (0..v_taps) |j| {
                const l = in +% @as(c.guint, @intCast(j)) *% src_inc;
                assert(l < U(v.r.in_size), 1556, "l < vscale->resampler.in_size");
                var k = f2;
                var found = false;
                while (k < v_taps + f2) : (k += 1) {
                    if (tl[k] == l) {
                        lines[j * src_inc] = tmpLine(v, k, width, n_elems);
                        found = true;
                        break;
                    }
                }
                if (found) continue;
                k = f2;
                while (k < v_taps + f2) : (k += 1) {
                    if (tl[k] < in or tl[k] == 0xffffffff) break;
                }
                assert(k < v_taps + f2, 1577, "k < v_taps + f2_offset");
                f.h.?(h, line(src, src_stride, l), tmpLine(v, k, width, n_elems), x, width, n_elems);
                tl[k] = l;
                lines[j * src_inc] = tmpLine(v, k, width, n_elems);
            }
            f.v.?(v, lines, line(dest, dest_stride, i), i, width, n_elems);
        }
        return;
    }
    const h_taps: c.guint = h.r.max_taps;
    const w1 = x +% width -% 1;
    const ws = h.r.offset[w1];
    const uinc: c.guint = @bitCast(h.inc);
    var vx: c.guint = (uinc *% x) >> 16;
    vx = @min(vx, h.r.offset[x]);
    var vw: c.guint = (uinc *% (x +% width)) >> 16;
    if (h.merged) {
        vw = if (w1 & 1 == @as(c.guint, @bitCast(h.out_y_offset))) @max(vw, ws +% 2 *% h_taps) else @max(vw, ws +% 4 *% h_taps);
    } else vw = @max(vw, ws +% h_taps);
    vw +%= 1;
    vw = @min(vw, U(h.r.in_size));
    if (v.tmpwidth < @as(c.gint, @bitCast(vw))) reallocTmp(v, @bitCast(n_elems), @bitCast(vw));
    var i = y;
    while (i < height) : (i += 1) {
        const in = v.r.offset[i];
        for (0..v_taps) |j| {
            const l = in +% @as(c.guint, @intCast(j)) *% src_inc;
            assert(l < U(v.r.in_size), 1624, "l < vscale->resampler.in_size");
            lines[j * src_inc] = line(src, src_stride, l) + vx * n_elems;
        }
        f.v.?(v, lines, tmpLine(v, 0, width, n_elems) + vx * n_elems, i, vw -% vx, n_elems);
        f.h.?(h, tmpLine(v, 0, width, n_elems), line(dest, dest_stride, i), x, width, n_elems);
    }
}
