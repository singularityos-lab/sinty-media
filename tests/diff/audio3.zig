const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn hash(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

var seed: u32 = 12345;

fn rnd() u32 {
    seed = seed *% 1103515245 +% 12345;
    return seed;
}

fn fillSignal(comptime T: type, buf: []T, k: usize) void {
    for (buf, 0..) |*x, i| {
        const v = @sin(@as(f64, @floatFromInt(i + k)) * 0.05) * 0.8 + @as(f64, @floatFromInt(rnd() % 1000)) / 20000.0;
        x.* = switch (T) {
            i16 => @intFromFloat(v * 32767),
            i32 => @intFromFloat(v * 2147483647),
            f32 => @floatCast(v),
            f64 => v,
            else => unreachable,
        };
    }
}

fn quantize() void {
    out("quantize", .{});
    var src: [4 * 200]i32 = undefined;
    for (&src, 0..) |*x, i| x.* = @bitCast((rnd() << 3) ^ @as(u32, @truncate(i *% 2654435761)));
    src[3] = std.math.maxInt(i32);
    src[4] = std.math.minInt(i32);
    for ([_]c.GstAudioDitherMethod{ 0, 1, 2, 3 }) |d| for ([_]c.GstAudioNoiseShapingMethod{ 0, 1, 2, 3, 4 }) |ns| for ([_]c.guint{ 1, 2, 256, 65536, 1 << 20 }) |q| for ([_]c.GstAudioQuantizeFlags{ 0, 1 }) |fl| {
        const qt = c.gst_audio_quantize_new(d, ns, fl, c.GST_AUDIO_FORMAT_S32, 4, q);
        var dst: [4 * 200]i32 = undefined;
        var h: u64 = 0;
        for (0..3) |round| {
            if (fl == 0) {
                var in = [_]c.gpointer{&src};
                var o = [_]c.gpointer{&dst};
                c.gst_audio_quantize_samples(qt, &in, &o, @intCast(200 - round * 30));
            } else {
                var in: [4]c.gpointer = undefined;
                var o: [4]c.gpointer = undefined;
                for (0..4) |k| {
                    in[k] = @ptrCast(&src[k * 200]);
                    o[k] = @ptrCast(&dst[k * 200]);
                }
                c.gst_audio_quantize_samples(qt, &in, &o, @intCast(150 - round * 30));
            }
            h ^= hash(std.mem.sliceAsBytes(&dst)) +% round;
            if (round == 1) c.gst_audio_quantize_reset(qt);
        }
        out("  d={d} ns={d} q={d} fl={d} {x} {any}", .{ d, ns, q, fl, h, dst[0..6] });
        c.gst_audio_quantize_free(qt);
    };
    _ = c.gst_audio_quantize_new(0, 0, 0, c.GST_AUDIO_FORMAT_S16, 2, 1);
    _ = c.gst_audio_quantize_new(0, 0, 0, c.GST_AUDIO_FORMAT_S32, 0, 1);
    var inplace = src;
    const qt = c.gst_audio_quantize_new(0, 0, 0, c.GST_AUDIO_FORMAT_S32, 4, 1);
    var p = [_]c.gpointer{&inplace};
    c.gst_audio_quantize_samples(qt, &p, &p, 200);
    out("  inplace memcpy {x}", .{hash(std.mem.sliceAsBytes(&inplace))});
    c.gst_audio_quantize_free(qt);
}

fn P(comptime name: []const u8) c.GstAudioChannelPosition {
    return @field(c, "GST_AUDIO_CHANNEL_POSITION_" ++ name);
}

const Layout = struct { []const u8, []const c.GstAudioChannelPosition };

const LAYOUTS = [_]Layout{
    .{ "mono", &.{P("MONO")} },
    .{ "stereo", &.{ P("FRONT_LEFT"), P("FRONT_RIGHT") } },
    .{ "rstereo", &.{ P("FRONT_RIGHT"), P("FRONT_LEFT") } },
    .{ "2.1", &.{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("LFE1") } },
    .{ "quad", &.{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("REAR_LEFT"), P("REAR_RIGHT") } },
    .{ "5.0", &.{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("FRONT_CENTER"), P("REAR_LEFT"), P("REAR_RIGHT") } },
    .{ "5.1", &.{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("FRONT_CENTER"), P("LFE1"), P("REAR_LEFT"), P("REAR_RIGHT") } },
    .{ "7.1", &.{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("FRONT_CENTER"), P("LFE1"), P("REAR_LEFT"), P("REAR_RIGHT"), P("SIDE_LEFT"), P("SIDE_RIGHT") } },
    .{ "center", &.{P("FRONT_CENTER")} },
    .{ "sides", &.{ P("SIDE_LEFT"), P("SIDE_RIGHT") } },
    .{ "rear3", &.{ P("REAR_LEFT"), P("REAR_RIGHT"), P("REAR_CENTER") } },
    .{ "loc", &.{ P("FRONT_LEFT_OF_CENTER"), P("FRONT_RIGHT_OF_CENTER"), P("FRONT_CENTER") } },
    .{ "monox3", &.{ P("MONO"), P("MONO"), P("MONO") } },
    .{ "altx5", &.{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("FRONT_LEFT"), P("FRONT_RIGHT"), P("FRONT_LEFT") } },
    .{ "fcside", &.{ P("FRONT_CENTER"), P("SIDE_LEFT"), P("SIDE_RIGHT") } },
    .{ "lfe", &.{P("LFE1")} },
    .{ "none4", &.{ P("NONE"), P("NONE"), P("NONE"), P("NONE") } },
};

fn mixer() void {
    out("mixer", .{});
    const fmts = [_]c.GstAudioFormat{ c.GST_AUDIO_FORMAT_S16, c.GST_AUDIO_FORMAT_S32, c.GST_AUDIO_FORMAT_F32, c.GST_AUDIO_FORMAT_F64 };
    for (LAYOUTS) |li| for (LAYOUTS) |lo| {
        const ni: c_int = @intCast(li[1].len);
        const no: c_int = @intCast(lo[1].len);
        var ip: [8]c.GstAudioChannelPosition = undefined;
        var opos: [8]c.GstAudioChannelPosition = undefined;
        @memcpy(ip[0..li[1].len], li[1]);
        @memcpy(opos[0..lo[1].len], lo[1]);
        for ([_]c.GstAudioChannelMixerFlags{ 0, 1, 2, 3, 4 }) |fl| {
            for (fmts) |f| {
                const m = c.gst_audio_channel_mixer_new(fl, f, ni, &ip, no, &opos);
                if (m == null) continue;
                const width: usize = @intCast(@divTrunc(c.gst_audio_format_get_info(f).*.width, 8));
                const frames = 37;
                var inbuf: [8 * frames * 8]u8 align(8) = undefined;
                for (&inbuf, 0..) |*x, i| x.* = @truncate(rnd() >> 13 ^ i);
                if (f == c.GST_AUDIO_FORMAT_F32) fillSignal(f32, @as([*]f32, @ptrCast(@alignCast(&inbuf)))[0 .. 8 * frames], 3);
                if (f == c.GST_AUDIO_FORMAT_F64) fillSignal(f64, @as([*]f64, @ptrCast(@alignCast(&inbuf)))[0 .. 8 * frames], 3);
                var outbuf: [8 * frames * 8]u8 align(8) = undefined;
                @memset(&outbuf, 0x77);
                var in: [8]c.gpointer = undefined;
                var o: [8]c.gpointer = undefined;
                for (0..8) |k| {
                    in[k] = @ptrCast(&inbuf[k * frames * width]);
                    o[k] = @ptrCast(&outbuf[k * frames * width]);
                }
                c.gst_audio_channel_mixer_samples(m, &in, &o, frames);
                const used = @as(usize, @intCast(no)) * frames * width;
                out("  {s}->{s} fl={d} f={d} pass={d} {x}", .{ li[0], lo[0], fl, f, c.gst_audio_channel_mixer_is_passthrough(m), hash(outbuf[0..used]) });
                c.gst_audio_channel_mixer_free(m);
            }
        }
    };
    var r0 = [_]f32{ 0.5, 0.0, 0.0 };
    var r1 = [_]f32{ 0.0, 1.5, -2.0 };
    const mat: [*c][*c]f32 = @ptrCast(@alignCast(c.g_malloc(16)));
    mat[0] = @ptrCast(@alignCast(c.g_memdup2(&r0, 12)));
    mat[1] = @ptrCast(@alignCast(c.g_memdup2(&r1, 12)));
    const m = c.gst_audio_channel_mixer_new_with_matrix(0, c.GST_AUDIO_FORMAT_S16, 2, 3, mat);
    var in16 = [_]i16{ 1000, -2000, 32767, 32767, -32768, -32768, 5, 7 };
    var o16: [12]i16 = undefined;
    var ip = [_]c.gpointer{&in16};
    var op = [_]c.gpointer{&o16};
    c.gst_audio_channel_mixer_samples(m, &ip, &op, 4);
    out("  custom {any} pass {d}", .{ o16, c.gst_audio_channel_mixer_is_passthrough(m) });
    c.gst_audio_channel_mixer_free(m);
    const id = c.gst_audio_channel_mixer_new_with_matrix(0, c.GST_AUDIO_FORMAT_F32, 3, 3, null);
    out("  identity pass {d}", .{c.gst_audio_channel_mixer_is_passthrough(id)});
    c.gst_audio_channel_mixer_free(id);
    _ = c.gst_audio_channel_mixer_new_with_matrix(0, c.GST_AUDIO_FORMAT_U8, 3, 3, null);
    _ = c.gst_audio_channel_mixer_new_with_matrix(0, c.GST_AUDIO_FORMAT_F32, 0, 3, null);
}

fn runResampler(comptime T: type, f: c.GstAudioFormat, method: c.GstAudioResamplerMethod, flags: c.GstAudioResamplerFlags, ch: c_int, in_rate: c_int, out_rate: c_int, opts: ?*c.GstStructure, label: []const u8) void {
    const r = c.gst_audio_resampler_new(method, flags, f, ch, in_rate, out_rate, opts);
    if (r == null) {
        out("  {s} null", .{label});
        return;
    }
    const nch: usize = @intCast(ch);
    var h: u64 = 0;
    var total: usize = 0;
    var produced: usize = 0;
    var inbuf: [4096 * 4]T = undefined;
    var outbuf: [16384 * 4]T = undefined;
    const chunks = [_]usize{ 1, 7, 160, 333, 1000, 0, 64, 2048 };
    for (chunks, 0..) |n, k| {
        fillSignal(T, inbuf[0 .. n * nch], total);
        total += n;
        const o_frames = c.gst_audio_resampler_get_out_frames(r, n);
        const i_frames = c.gst_audio_resampler_get_in_frames(r, o_frames);
        @memset(std.mem.sliceAsBytes(outbuf[0 .. o_frames * nch]), 0);
        var in: [4]c.gpointer = undefined;
        var o: [4]c.gpointer = undefined;
        if (flags & c.GST_AUDIO_RESAMPLER_FLAG_NON_INTERLEAVED_IN != 0) {
            for (0..nch) |cc| in[cc] = @ptrCast(&inbuf[cc * n]);
        } else in[0] = @ptrCast(&inbuf);
        if (flags & c.GST_AUDIO_RESAMPLER_FLAG_NON_INTERLEAVED_OUT != 0) {
            for (0..nch) |cc| o[cc] = @ptrCast(&outbuf[cc * o_frames]);
        } else o[0] = @ptrCast(&outbuf);
        c.gst_audio_resampler_resample(r, if (k == 5) null else &in, n, &o, o_frames);
        produced += o_frames;
        h = h *% 31 +% hash(std.mem.sliceAsBytes(outbuf[0 .. o_frames * nch]));
        if (k == 4 and opts != null) {
            const ok = c.gst_audio_resampler_update(r, in_rate, out_rate + 1000, opts);
            out("    update {d} lat {d}", .{ ok, c.gst_audio_resampler_get_max_latency(r) });
        }
        if (k == 6) {
            _ = c.gst_audio_resampler_update(r, out_rate, in_rate, null);
        }
        if (k == 2) out("    after {d}: out {d} in {d}", .{ n, o_frames, i_frames });
    }
    out("  {s} lat={d} produced={d} {x}", .{ label, c.gst_audio_resampler_get_max_latency(r), produced, h });
    c.gst_audio_resampler_reset(r);
    c.gst_audio_resampler_free(r);
}

fn resampler() void {
    out("resampler", .{});
    const rates = [_][2]c_int{ .{ 44100, 48000 }, .{ 48000, 44100 }, .{ 8000, 48000 }, .{ 48000, 8000 }, .{ 44100, 44100 }, .{ 22050, 16000 }, .{ 32000, 96000 } };
    for ([_]c.GstAudioResamplerMethod{ 0, 1, 2, 3, 4 }) |m| for (rates) |rt| for ([_]c_int{ 1, 2 }) |ch| {
        var lb: [96]u8 = undefined;
        const s16 = std.fmt.bufPrint(&lb, "m{d} {d}->{d} ch{d} s16", .{ m, rt[0], rt[1], ch }) catch "";
        runResampler(i16, c.GST_AUDIO_FORMAT_S16, m, 0, ch, rt[0], rt[1], null, s16);
        const s32 = std.fmt.bufPrint(&lb, "m{d} {d}->{d} ch{d} s32", .{ m, rt[0], rt[1], ch }) catch "";
        runResampler(i32, c.GST_AUDIO_FORMAT_S32, m, 0, ch, rt[0], rt[1], null, s32);
        const sf = std.fmt.bufPrint(&lb, "m{d} {d}->{d} ch{d} f32", .{ m, rt[0], rt[1], ch }) catch "";
        runResampler(f32, c.GST_AUDIO_FORMAT_F32, m, 0, ch, rt[0], rt[1], null, sf);
        const sd = std.fmt.bufPrint(&lb, "m{d} {d}->{d} ch{d} f64", .{ m, rt[0], rt[1], ch }) catch "";
        runResampler(f64, c.GST_AUDIO_FORMAT_F64, m, 0, ch, rt[0], rt[1], null, sd);
    };
    const modes = [_]c_int{ c.GST_AUDIO_RESAMPLER_FILTER_MODE_INTERPOLATED, c.GST_AUDIO_RESAMPLER_FILTER_MODE_FULL };
    const interps = [_]c_int{ c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_NONE, c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_LINEAR, c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC };
    for ([_]c.GstAudioResamplerMethod{ 3, 4 }) |m| for (modes) |mode| for (interps) |ip| for ([_]c.guint{ 0, 4, 10 }) |q| {
        const opts = c.gst_structure_new_empty("opts");
        c.gst_audio_resampler_options_set_quality(m, q, 44100, 48000, opts);
        c.gst_structure_set(opts, c.GST_AUDIO_RESAMPLER_OPT_FILTER_MODE, c.gst_audio_resampler_filter_mode_get_type(), mode, c.GST_AUDIO_RESAMPLER_OPT_FILTER_INTERPOLATION, c.gst_audio_resampler_filter_interpolation_get_type(), ip, NONE);
        const so = c.gst_structure_to_string(opts);
        out("  opts {s}", .{std.mem.span(so)});
        c.g_free(so);
        var lb: [96]u8 = undefined;
        for ([_]c.GstAudioResamplerFlags{ 0, 3, 4 }) |fl| {
            runResampler(i16, c.GST_AUDIO_FORMAT_S16, m, fl, 2, 44100, 48000, opts, std.fmt.bufPrint(&lb, "o m{d} mode{d} ip{d} q{d} fl{d} s16", .{ m, mode, ip, q, fl }) catch "");
            runResampler(i32, c.GST_AUDIO_FORMAT_S32, m, fl, 2, 48000, 44100, opts, std.fmt.bufPrint(&lb, "o m{d} mode{d} ip{d} q{d} fl{d} s32", .{ m, mode, ip, q, fl }) catch "");
            runResampler(f32, c.GST_AUDIO_FORMAT_F32, m, fl, 2, 44100, 48000, opts, std.fmt.bufPrint(&lb, "o m{d} mode{d} ip{d} q{d} fl{d} f32", .{ m, mode, ip, q, fl }) catch "");
            runResampler(f64, c.GST_AUDIO_FORMAT_F64, m, fl, 1, 48000, 32000, opts, std.fmt.bufPrint(&lb, "o m{d} mode{d} ip{d} q{d} fl{d} f64", .{ m, mode, ip, q, fl }) catch "");
        }
        c.gst_structure_free(opts);
    };
    const opts = c.gst_structure_new_empty("opts");
    for ([_]c.GstAudioResamplerMethod{ 0, 1, 2, 3, 4, 9 }) |m| {
        c.gst_audio_resampler_options_set_quality(m, 2, 48000, 44100, opts);
    }
    const so = c.gst_structure_to_string(opts);
    out("  all opts {s}", .{std.mem.span(so)});
    c.g_free(so);
    c.gst_audio_resampler_options_set_quality(0, 11, 1, 1, opts);
    c.gst_audio_resampler_options_set_quality(0, 1, 0, 1, opts);
    c.gst_structure_set(opts, c.GST_AUDIO_RESAMPLER_OPT_MAX_PHASE_ERROR, c.G_TYPE_DOUBLE, @as(f64, 0.0), c.GST_AUDIO_RESAMPLER_OPT_FILTER_MODE_THRESHOLD, c.G_TYPE_INT, @as(c_int, 1), NONE);
    runResampler(f32, c.GST_AUDIO_FORMAT_F32, 4, c.GST_AUDIO_RESAMPLER_FLAG_VARIABLE_RATE, 2, 44100, 48000, opts, "variable exact");
    c.gst_structure_free(opts);
    _ = c.gst_audio_resampler_new(9, 0, c.GST_AUDIO_FORMAT_F32, 1, 1, 1, null);
    _ = c.gst_audio_resampler_new(0, 0, c.GST_AUDIO_FORMAT_U8, 1, 1, 1, null);
    _ = c.gst_audio_resampler_new(0, 0, c.GST_AUDIO_FORMAT_S16, 0, 1, 1, null);
    _ = c.gst_audio_resampler_new(0, 0, c.GST_AUDIO_FORMAT_S16, 1, 0, 1, null);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    quantize();
    mixer();
    resampler();
}
