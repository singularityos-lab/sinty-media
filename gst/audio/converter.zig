const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const format = @import("format.zig");
const info_mod = @import("info.zig");
const enums = @import("enumtypes.zig");
const mixer = @import("channelmixer.zig");
const resampler = @import("resampler.zig");
const quantize = @import("quantize.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Info = c.GstAudioInfo;
const Fmt = c.GstAudioFormat;
const ALIGN = 16;

const ConvertFunc = *const fn (c.gpointer, c.gpointer, c.gint) void;
const SamplesFunc = *const fn (*Conv, c.GstAudioConverterFlags, [*c]c.gpointer, usize, [*c]c.gpointer, usize) bool;
const MakeFunc = *const fn (*Chain, *Conv) void;
const AllocFunc = *const fn (*Chain, usize, *Conv) [*c]c.gpointer;

const Chain = struct {
    prev: ?*Chain,
    make: MakeFunc,
    finfo: [*c]const c.GstAudioFormatInfo,
    stride: c.gint,
    inc: c.gint,
    blocks: c.gint,
    pass_alloc: bool,
    allow_ip: bool,
    alloc: ?AllocFunc,
    tmp: ?[*]c.gpointer,
    allocated: usize,
    samples: [*c]c.gpointer,
    num_samples: usize,
};

const Conv = struct {
    in: Info,
    out: Info,
    config: ?*c.GstStructure,
    flags: c.GstAudioConverterFlags,
    current_format: Fmt,
    current_layout: c.GstAudioLayout,
    current_channels: c.gint,
    in_writable: bool,
    in_data: [*c]c.gpointer,
    in_frames: usize,
    out_data: [*c]c.gpointer,
    out_frames: usize,
    in_place: bool,
    passthrough: bool,
    in_default: bool,
    convert_in: ?ConvertFunc,
    mix_passthrough: bool,
    mix: ?*c.GstAudioChannelMixer,
    resampler: ?*c.GstAudioResampler,
    convert_out: ?ConvertFunc,
    quant: ?*c.GstAudioQuantize,
    chlayout_format: Fmt,
    chlayout_target: c.GstAudioLayout,
    chlayout_channels: c.gint,
    out_default: bool,
    chain_end: ?*Chain,
    swap: ?ConvertFunc,
    convert: SamplesFunc,
};

fn of(p: anytype) *Conv {
    return @ptrCast(@alignCast(p));
}

var type_once: gtype.Once = .{};

fn copyBoxed(p: c.gpointer) callconv(.c) c.gpointer {
    const cv = of(p);
    return gst_audio_converter_new(cv.flags, &cv.in, &cv.out, cv.config);
}

fn freeBoxed(p: c.gpointer) callconv(.c) void {
    gst_audio_converter_free(@ptrCast(p));
}

pub export fn gst_audio_converter_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstAudioConverter", copyBoxed, freeBoxed);
        }
    }.f);
}

fn chainNew(prev: ?*Chain, cv: *Conv, make: MakeFunc, allow_ip: bool, pass_alloc: bool) *Chain {
    const ch: *Chain = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Chain))));
    ch.prev = prev;
    if (cv.current_layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) {
        ch.inc = 1;
        ch.blocks = cv.current_channels;
    } else {
        ch.inc = cv.current_channels;
        ch.blocks = 1;
    }
    ch.finfo = format.gst_audio_format_get_info(cv.current_format);
    ch.stride = @divTrunc(ch.finfo.*.width * ch.inc, 8);
    ch.make = make;
    ch.allow_ip = allow_ip;
    ch.pass_alloc = pass_alloc;
    return ch;
}

fn chainFree(ch: *Chain) void {
    c.g_free(@ptrCast(ch.tmp));
    c.g_free(ch);
}

fn allocSamples(ch: *Chain, n: usize, cv: *Conv) [*c]c.gpointer {
    return ch.alloc.?(ch, n, cv);
}

fn setSamples(ch: *Chain, s: [*c]c.gpointer, n: usize) void {
    ch.samples = s;
    ch.num_samples = n;
}

fn getSamples(ch: *Chain, cv: *Conv, avail: *usize) [*c]c.gpointer {
    if (ch.samples == null) ch.make(ch, cv);
    const res = ch.samples;
    avail.* = ch.num_samples;
    ch.samples = null;
    return res;
}

fn optUint(cv: *Conv, opt: [*c]const u8, def: c.guint) c.guint {
    var r: c.guint = 0;
    if (c.gst_structure_get_uint(cv.config, opt, &r) == 0) r = def;
    return r;
}

fn optEnum(cv: *Conv, opt: [*c]const u8, t: c.GType, def: c.gint) c.gint {
    var r: c.gint = 0;
    if (c.gst_structure_get_enum(cv.config, opt, t, &r) == 0) r = def;
    return r;
}

fn copyConfig(name: ?*const c.GstIdStr, v: [*c]const c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    c.gst_structure_id_str_set_value(of(data).config, name, v);
    return 1;
}

pub export fn gst_audio_converter_update_config(cp: ?*c.GstAudioConverter, in_rate_in: c.gint, out_rate_in: c.gint, config: ?*c.GstStructure) c.gboolean {
    const fname = "gst_audio_converter_update_config";
    if (!check.that(cp != null, fname, "convert != NULL")) return 0;
    const cv = of(cp);
    if (!check.that((in_rate_in == 0 and out_rate_in == 0) or cv.flags & c.GST_AUDIO_CONVERTER_FLAG_VARIABLE_RATE != 0, fname, "(in_rate == 0 && out_rate == 0) || convert->flags & GST_AUDIO_CONVERTER_FLAG_VARIABLE_RATE")) return 0;
    const in_rate = if (in_rate_in <= 0) cv.in.rate else in_rate_in;
    const out_rate = if (out_rate_in <= 0) cv.out.rate else out_rate_in;
    cv.in.rate = in_rate;
    cv.out.rate = out_rate;
    if (cv.resampler != null) _ = resampler.gst_audio_resampler_update(cv.resampler, in_rate, out_rate, config);
    if (config != null) {
        _ = c.gst_structure_foreach_id_str(config, copyConfig, cv);
        c.gst_structure_free(config);
    }
    return 1;
}

pub export fn gst_audio_converter_get_config(cp: ?*c.GstAudioConverter, in_rate: [*c]c.gint, out_rate: [*c]c.gint) ?*const c.GstStructure {
    if (!check.that(cp != null, "gst_audio_converter_get_config", "convert != NULL")) return null;
    const cv = of(cp);
    if (in_rate != null) in_rate.* = cv.in.rate;
    if (out_rate != null) out_rate.* = cv.out.rate;
    return cv.config;
}

fn outputSamples(_: *Chain, _: usize, cv: *Conv) [*c]c.gpointer {
    return cv.out_data;
}

fn tempSamples(ch: *Chain, n: usize, _: *Conv) [*c]c.gpointer {
    if (n > ch.allocated) {
        const blocks: usize = @intCast(ch.blocks);
        const stride = (n * @as(usize, @intCast(ch.stride)) + ALIGN - 1) & ~@as(usize, ALIGN - 1);
        const needed = (stride + @sizeOf(c.gpointer)) * blocks + ALIGN - 1;
        ch.tmp = @ptrCast(@alignCast(c.g_realloc(@ptrCast(ch.tmp), needed)));
        ch.allocated = n;
        const base = (@intFromPtr(&ch.tmp.?[blocks]) + ALIGN - 1) & ~@as(usize, ALIGN - 1);
        for (0..blocks) |i| ch.tmp.?[i] = @ptrFromInt(base + i * stride);
    }
    return @ptrCast(ch.tmp);
}

fn doUnpack(ch: *Chain, cv: *Conv) void {
    const n = cv.in_frames;
    var tmp: [*c]c.gpointer = undefined;
    const blocks: usize = @intCast(ch.blocks);
    const stride: usize = @intCast(ch.stride);
    const inc: usize = @intCast(ch.inc);
    if (!ch.allow_ip or !cv.in_writable or !cv.in_default) {
        tmp = if (cv.in_writable and ch.allow_ip) cv.in_data else allocSamples(ch, n, cv);
        if (cv.in_data != null) {
            for (0..blocks) |i| {
                if (cv.in_default) {
                    @memcpy(@as([*]u8, @ptrCast(tmp[i]))[0 .. n * stride], @as([*]const u8, @ptrCast(cv.in_data[i]))[0 .. n * stride]);
                } else cv.in.finfo.*.unpack_func.?(cv.in.finfo, c.GST_AUDIO_PACK_FLAG_TRUNCATE_RANGE, tmp[i], cv.in_data[i], @intCast(n * inc));
            }
        } else {
            for (0..blocks) |i| format.gst_audio_format_info_fill_silence(ch.finfo, tmp[i], n * inc);
        }
    } else tmp = cv.in_data;
    setSamples(ch, tmp, n);
}

fn doConvertIn(ch: *Chain, cv: *Conv) void {
    var n: usize = 0;
    const in = getSamples(ch.prev.?, cv, &n);
    const out = if (ch.allow_ip) in else allocSamples(ch, n, cv);
    for (0..@intCast(ch.blocks)) |i| cv.convert_in.?(out[i], in[i], @intCast(n * @as(usize, @intCast(ch.inc))));
    setSamples(ch, out, n);
}

fn doMix(ch: *Chain, cv: *Conv) void {
    var n: usize = 0;
    const in = getSamples(ch.prev.?, cv, &n);
    const out = if (ch.allow_ip) in else allocSamples(ch, n, cv);
    mixer.gst_audio_channel_mixer_samples(cv.mix, in, out, @intCast(n));
    setSamples(ch, out, n);
}

fn doResample(ch: *Chain, cv: *Conv) void {
    var n: usize = 0;
    const in = getSamples(ch.prev.?, cv, &n);
    const out_frames = cv.out_frames;
    const out = if (ch.allow_ip) in else allocSamples(ch, out_frames, cv);
    resampler.gst_audio_resampler_resample(cv.resampler, in, n, out, out_frames);
    setSamples(ch, out, out_frames);
}

fn doConvertOut(ch: *Chain, cv: *Conv) void {
    var n: usize = 0;
    const in = getSamples(ch.prev.?, cv, &n);
    const out = if (ch.allow_ip) in else allocSamples(ch, n, cv);
    for (0..@intCast(ch.blocks)) |i| cv.convert_out.?(out[i], in[i], @intCast(n * @as(usize, @intCast(ch.inc))));
    setSamples(ch, out, n);
}

fn doQuantize(ch: *Chain, cv: *Conv) void {
    var n: usize = 0;
    const in = getSamples(ch.prev.?, cv, &n);
    const out = if (ch.allow_ip) in else allocSamples(ch, n, cv);
    if (in != null and out != null) quantize.gst_audio_quantize_samples(cv.quant, in, out, @intCast(n));
    setSamples(ch, out, n);
}

fn relayout(comptime T: type, in: [*c]c.gpointer, out: [*c]c.gpointer, n: usize, channels: usize, interleave: bool) void {
    for (0..n) |s| for (0..channels) |ch| {
        if (interleave) {
            @as([*]T, @ptrCast(@alignCast(out[0])))[s * channels + ch] = @as([*]const T, @ptrCast(@alignCast(in[ch])))[s];
        } else @as([*]T, @ptrCast(@alignCast(out[ch])))[s] = @as([*]const T, @ptrCast(@alignCast(in[0])))[s * channels + ch];
    };
}

fn doChangeLayout(ch: *Chain, cv: *Conv) void {
    var n: usize = 0;
    const in = getSamples(ch.prev.?, cv, &n);
    const out = if (ch.allow_ip) in else allocSamples(ch, n, cv);
    const channels: usize = @intCast(cv.chlayout_channels);
    const il = cv.chlayout_target == c.GST_AUDIO_LAYOUT_INTERLEAVED;
    switch (cv.chlayout_format) {
        c.GST_AUDIO_FORMAT_S16 => relayout(i16, in, out, n, channels, il),
        c.GST_AUDIO_FORMAT_S32 => relayout(i32, in, out, n, channels, il),
        c.GST_AUDIO_FORMAT_F32 => relayout(f32, in, out, n, channels, il),
        else => relayout(f64, in, out, n, channels, il),
    }
    setSamples(ch, out, n);
}

fn isIntermediate(f: Fmt) bool {
    return f == c.GST_AUDIO_FORMAT_S16 or f == c.GST_AUDIO_FORMAT_S32 or f == c.GST_AUDIO_FORMAT_F32 or f == c.GST_AUDIO_FORMAT_F64;
}

fn isInt(fi: [*c]const c.GstAudioFormatInfo) bool {
    return fi.*.flags & c.GST_AUDIO_FORMAT_FLAG_INTEGER != 0;
}

fn flushD(v: f64) f64 {
    const b: u64 = @bitCast(v);
    return if (b & 0x7ff0000000000000 == 0) @bitCast(b & 0x8000000000000000) else v;
}

fn s32ToDouble(dst: c.gpointer, src: c.gpointer, n: c.gint) void {
    const d: [*]f64 = @ptrCast(@alignCast(dst));
    const s: [*]const i32 = @ptrCast(@alignCast(src));
    for (0..@intCast(@max(n, 0))) |i| d[i] = flushD(@as(f64, @floatFromInt(s[i])) / 2147483648.0);
}

fn doubleToS32(dst: c.gpointer, src: c.gpointer, n: c.gint) void {
    const d: [*]i32 = @ptrCast(@alignCast(dst));
    const s: [*]const f64 = @ptrCast(@alignCast(src));
    for (0..@intCast(@max(n, 0))) |i| {
        const x = flushD(flushD(s[i]) * 2147483648.0);
        var t: i32 = std.math.minInt(i32);
        if (!std.math.isNan(x) and x > -2147483649.0 and x < 2147483648.0) t = @intFromFloat(x);
        if (t == std.math.minInt(i32) and @as(u64, @bitCast(x)) & 0x8000000000000000 == 0) t = std.math.maxInt(i32);
        d[i] = t;
    }
}

fn checkMatrix(in_ch: c.guint, out_ch: c.guint, v: [*c]const c.GValue) bool {
    if (c.gst_value_array_get_size(v) == 0) return true;
    if (c.gst_value_array_get_size(v) != out_ch) return false;
    for (0..out_ch) |j| {
        const row = c.gst_value_array_get_value(v, @intCast(j));
        if (c.gst_value_array_get_size(row) != in_ch) return false;
        for (0..in_ch) |i| {
            const t = c.gst_value_array_get_value(row, @intCast(i)).*.g_type;
            if (t != c.G_TYPE_FLOAT and t != c.G_TYPE_DOUBLE and t != c.G_TYPE_INT and t != c.G_TYPE_INT64 and t != c.G_TYPE_UINT and t != c.G_TYPE_UINT64) return false;
        }
    }
    return true;
}

fn matrixFromValue(in_ch: usize, out_ch: usize, v: [*c]const c.GValue) [*c][*c]f32 {
    const m: [*c][*c]f32 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(usize) * in_ch)));
    for (0..in_ch) |i| m[i] = @ptrCast(@alignCast(c.g_malloc(@sizeOf(f32) * out_ch)));
    for (0..out_ch) |j| {
        const row = c.gst_value_array_get_value(v, @intCast(j));
        for (0..in_ch) |i| {
            const itm = c.gst_value_array_get_value(row, @intCast(i));
            const t = itm.*.g_type;
            m[i][j] = if (t == c.G_TYPE_FLOAT) c.g_value_get_float(itm) else if (t == c.G_TYPE_DOUBLE) @floatCast(c.g_value_get_double(itm)) else if (t == c.G_TYPE_INT) @floatFromInt(c.g_value_get_int(itm)) else if (t == c.G_TYPE_INT64) @floatFromInt(c.g_value_get_int64(itm)) else if (t == c.G_TYPE_UINT) @floatFromInt(c.g_value_get_uint(itm)) else @floatFromInt(c.g_value_get_uint64(itm));
        }
    }
    return m;
}

fn chainUnpack(cv: *Conv) *Chain {
    const same = cv.in.finfo.*.format == cv.out.finfo.*.format;
    cv.current_format = if (same and isIntermediate(cv.in.finfo.*.format)) cv.in.finfo.*.format else cv.in.finfo.*.unpack_format;
    cv.current_layout = cv.in.layout;
    cv.current_channels = cv.in.channels;
    cv.in_default = cv.current_format == cv.in.finfo.*.format;
    const ch = chainNew(null, cv, doUnpack, false, false);
    ch.allow_ip = ch.finfo.*.width <= cv.in.finfo.*.width;
    return ch;
}

fn chainConvertIn(cv: *Conv, prev: *Chain) *Chain {
    if (isInt(cv.in.finfo) and !isInt(cv.out.finfo)) {
        cv.convert_in = s32ToDouble;
        cv.current_format = c.GST_AUDIO_FORMAT_F64;
        return chainNew(prev, cv, doConvertIn, false, false);
    }
    return prev;
}

fn chainMix(cv: *Conv, prev: *Chain) *Chain {
    const fmt = cv.current_format;
    const opt = c.gst_structure_get_value(cv.config, c.GST_AUDIO_CONVERTER_OPT_MIX_MATRIX);
    var flags: c.GstAudioChannelMixerFlags = 0;
    cv.current_channels = cv.out.channels;
    if (cv.current_layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) flags |= c.GST_AUDIO_CHANNEL_MIXER_FLAGS_NON_INTERLEAVED_IN | c.GST_AUDIO_CHANNEL_MIXER_FLAGS_NON_INTERLEAVED_OUT;
    if (opt != null) {
        var m: [*c][*c]f32 = null;
        if (c.gst_value_array_get_size(opt) != 0) m = matrixFromValue(@intCast(cv.in.channels), @intCast(cv.out.channels), opt);
        cv.mix = mixer.gst_audio_channel_mixer_new_with_matrix(flags, fmt, cv.in.channels, cv.out.channels, m);
    } else {
        if (cv.in.flags & c.GST_AUDIO_FLAG_UNPOSITIONED != 0) flags |= c.GST_AUDIO_CHANNEL_MIXER_FLAGS_UNPOSITIONED_IN;
        if (cv.out.flags & c.GST_AUDIO_FLAG_UNPOSITIONED != 0) flags |= c.GST_AUDIO_CHANNEL_MIXER_FLAGS_UNPOSITIONED_OUT;
        cv.mix = mixer.gst_audio_channel_mixer_new(flags, fmt, cv.in.channels, @ptrCast(&cv.in.position), cv.out.channels, @ptrCast(&cv.out.position));
    }
    cv.mix_passthrough = mixer.gst_audio_channel_mixer_is_passthrough(cv.mix) != 0;
    if (!cv.mix_passthrough) return chainNew(prev, cv, doMix, false, false);
    return prev;
}

fn chainResample(cv: *Conv, prev: *Chain) *Chain {
    const variable = cv.flags & c.GST_AUDIO_CONVERTER_FLAG_VARIABLE_RATE != 0;
    if (cv.in.rate == cv.out.rate and !variable) return prev;
    const method: c.GstAudioResamplerMethod = @intCast(optEnum(cv, c.GST_AUDIO_CONVERTER_OPT_RESAMPLER_METHOD, enums.gst_audio_resampler_method_get_type(), c.GST_AUDIO_RESAMPLER_METHOD_BLACKMAN_NUTTALL));
    var flags: c.GstAudioResamplerFlags = 0;
    if (cv.current_layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) flags |= c.GST_AUDIO_RESAMPLER_FLAG_NON_INTERLEAVED_IN;
    if (cv.out.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) flags |= c.GST_AUDIO_RESAMPLER_FLAG_NON_INTERLEAVED_OUT;
    cv.current_layout = cv.out.layout;
    if (variable) flags |= c.GST_AUDIO_RESAMPLER_FLAG_VARIABLE_RATE;
    cv.resampler = resampler.gst_audio_resampler_new(method, flags, cv.current_format, cv.current_channels, cv.in.rate, cv.out.rate, cv.config);
    return chainNew(prev, cv, doResample, false, false);
}

fn chainConvertOut(cv: *Conv, prev: *Chain) *Chain {
    if (!isInt(cv.in.finfo) and isInt(cv.out.finfo)) {
        cv.convert_out = doubleToS32;
        cv.current_format = c.GST_AUDIO_FORMAT_S32;
        return chainNew(prev, cv, doConvertOut, true, false);
    }
    return prev;
}

fn chainQuantize(cv: *Conv, prev: *Chain) *Chain {
    var dither: c.GstAudioDitherMethod = @intCast(optEnum(cv, c.GST_AUDIO_CONVERTER_OPT_DITHER_METHOD, enums.gst_audio_dither_method_get_type(), c.GST_AUDIO_DITHER_NONE));
    const threshold = optUint(cv, c.GST_AUDIO_CONVERTER_OPT_DITHER_THRESHOLD, 20);
    var ns: c.GstAudioNoiseShapingMethod = @intCast(optEnum(cv, c.GST_AUDIO_CONVERTER_OPT_NOISE_SHAPING_METHOD, enums.gst_audio_noise_shaping_method_get_type(), c.GST_AUDIO_NOISE_SHAPING_NONE));
    const cur = format.gst_audio_format_get_info(cv.current_format);
    const in_depth = cur.*.depth;
    const out_depth = cv.out.finfo.*.depth;
    const in_int = isInt(cur);
    const out_int = isInt(cv.out.finfo);
    if (@as(c.guint, @bitCast(out_depth)) > threshold or (in_int and out_depth >= in_depth)) {
        dither = c.GST_AUDIO_DITHER_NONE;
        ns = c.GST_AUDIO_NOISE_SHAPING_NONE;
    } else if (ns > c.GST_AUDIO_NOISE_SHAPING_ERROR_FEEDBACK and cv.out.rate < 32000) ns = c.GST_AUDIO_NOISE_SHAPING_ERROR_FEEDBACK;
    if (out_int and out_depth < 32 and cv.current_format == c.GST_AUDIO_FORMAT_S32) {
        cv.quant = quantize.gst_audio_quantize_new(dither, ns, 0, cv.current_format, @intCast(cv.out.channels), @as(c.guint, 1) << @intCast(32 - out_depth));
        return chainNew(prev, cv, doQuantize, true, true);
    }
    return prev;
}

fn chainChangeLayout(cv: *Conv, prev: *Chain) *Chain {
    if (cv.current_layout != cv.out.layout) {
        cv.current_layout = cv.out.layout;
        if (cv.current_channels > 1) {
            cv.chlayout_target = cv.current_layout;
            cv.chlayout_format = cv.current_format;
            cv.chlayout_channels = cv.current_channels;
            return chainNew(prev, cv, doChangeLayout, false, false);
        }
    }
    return prev;
}

fn setupAllocators(cv: *Conv) void {
    var alloc: AllocFunc = if (cv.out_default) outputSamples else tempSamples;
    var allow_ip = !cv.out_default;
    var ch = cv.chain_end;
    while (ch) |cc| : (ch = cc.prev) {
        cc.alloc = alloc;
        cc.allow_ip = allow_ip and cc.allow_ip;
        if (!cc.pass_alloc) {
            alloc = tempSamples;
            allow_ip = true;
        }
    }
}

fn convPassthrough(cv: *Conv, _: c.GstAudioConverterFlags, in: [*c]c.gpointer, frames: usize, out: [*c]c.gpointer, _: usize) bool {
    if (in == out) return true;
    const ch = cv.chain_end.?;
    const samples = frames * @as(usize, @intCast(ch.inc));
    for (0..@intCast(ch.blocks)) |i| {
        if (in != null) {
            if (out[i] == in[i]) continue;
            const bytes = samples * @as(usize, @intCast(@divTrunc(cv.in.bpf, cv.in.channels)));
            @memcpy(@as([*]u8, @ptrCast(out[i]))[0..bytes], @as([*]const u8, @ptrCast(in[i]))[0..bytes]);
        } else format.gst_audio_format_info_fill_silence(cv.in.finfo, out[i], samples);
    }
    return true;
}

fn swapFn(comptime T: type) ConvertFunc {
    return struct {
        fn f(dst: c.gpointer, src: c.gpointer, n: c.gint) void {
            const d: [*]T = @ptrCast(@alignCast(dst));
            const s: [*]const T = @ptrCast(@alignCast(src));
            for (0..@intCast(@max(n, 0))) |i| d[i] = @byteSwap(s[i]);
        }
    }.f;
}

fn swap24(dst: c.gpointer, src: c.gpointer, n: c.gint) void {
    const d: [*]u8 = @ptrCast(dst);
    const s: [*]const u8 = @ptrCast(src);
    var i: usize = 0;
    const count: usize = @as(usize, @intCast(@max(n, 0))) * 3;
    while (i < count) : (i += 3) {
        const x = s[i];
        d[i] = s[i + 2];
        d[i + 1] = s[i + 1];
        d[i + 2] = x;
    }
}

fn convEndian(cv: *Conv, _: c.GstAudioConverterFlags, in: [*c]c.gpointer, frames: usize, out: [*c]c.gpointer, _: usize) bool {
    const ch = cv.chain_end.?;
    const samples = frames * @as(usize, @intCast(ch.inc));
    for (0..@intCast(ch.blocks)) |i| {
        if (in != null) cv.swap.?(out[i], in[i], @intCast(samples)) else format.gst_audio_format_info_fill_silence(cv.in.finfo, out[i], samples);
    }
    return true;
}

fn convGeneric(cv: *Conv, flags: c.GstAudioConverterFlags, in: [*c]c.gpointer, frames: usize, out: [*c]c.gpointer, out_frames: usize) bool {
    const ch = cv.chain_end.?;
    cv.in_writable = flags & c.GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE != 0;
    cv.in_data = in;
    cv.in_frames = frames;
    cv.out_data = out;
    cv.out_frames = out_frames;
    var produced: usize = 0;
    const tmp = getSamples(ch, cv, &produced);
    if (!cv.out_default and tmp != null and out != null) {
        for (0..@intCast(ch.blocks)) |i| cv.out.finfo.*.pack_func.?(cv.out.finfo, 0, tmp[i], out[i], @intCast(produced * @as(usize, @intCast(ch.inc))));
    }
    return true;
}

fn convResample(cv: *Conv, _: c.GstAudioConverterFlags, in: [*c]c.gpointer, frames: usize, out: [*c]c.gpointer, out_frames: usize) bool {
    resampler.gst_audio_resampler_resample(cv.resampler, in, frames, out, out_frames);
    return true;
}

fn isEndianConversion(a: [*c]const c.GstAudioFormatInfo, b: [*c]const c.GstAudioFormatInfo) bool {
    return ((a.*.flags ^ b.*.flags) & ~@as(c.GstAudioFormatFlags, c.GST_AUDIO_FORMAT_FLAG_UNPACK)) == 0 and a.*.endianness != b.*.endianness and a.*.width == b.*.width and a.*.depth == b.*.depth;
}

pub export fn gst_audio_converter_new(flags: c.GstAudioConverterFlags, in_info: [*c]Info, out_info: [*c]Info, config_in: ?*c.GstStructure) ?*c.GstAudioConverter {
    const fname = "gst_audio_converter_new";
    if (!check.that(in_info != null, fname, "in_info != NULL")) return null;
    if (!check.that(out_info != null, fname, "out_info != NULL")) return null;
    var config = config_in;
    var opt: [*c]const c.GValue = null;
    if (config != null) opt = c.gst_structure_get_value(config, c.GST_AUDIO_CONVERTER_OPT_MIX_MATRIX);
    if ((opt != null and !checkMatrix(@intCast(in_info.*.channels), @intCast(out_info.*.channels), opt)) or (in_info.*.channels != out_info.*.channels and (in_info.*.flags & c.GST_AUDIO_FLAG_UNPOSITIONED != 0 or out_info.*.flags & c.GST_AUDIO_FLAG_UNPOSITIONED != 0) and opt == null)) {
        if (config != null) {
            c.gst_structure_free(config);
            config = null;
        }
        return null;
    }
    const cv: *Conv = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Conv))));
    cv.flags = flags;
    cv.in = in_info.*;
    cv.out = out_info.*;
    cv.config = c.gst_structure_new_static_str_empty("GstAudioConverter");
    if (config != null) _ = gst_audio_converter_update_config(@ptrCast(cv), 0, 0, config);
    var prev = chainUnpack(cv);
    prev = chainConvertIn(cv, prev);
    prev = chainMix(cv, prev);
    prev = chainResample(cv, prev);
    prev = chainConvertOut(cv, prev);
    prev = chainQuantize(cv, prev);
    prev = chainChangeLayout(cv, prev);
    cv.out_default = cv.current_format == cv.out.finfo.*.format;
    cv.current_format = cv.out.finfo.*.format;
    cv.chain_end = prev;
    cv.convert = convGeneric;
    if (cv.mix_passthrough) {
        if (out_info.*.finfo.*.format == in_info.*.finfo.*.format) {
            if (cv.resampler == null) {
                if (out_info.*.layout == in_info.*.layout) {
                    cv.convert = convPassthrough;
                    cv.in_place = true;
                    cv.passthrough = true;
                }
            } else if (isIntermediate(in_info.*.finfo.*.format)) cv.convert = convResample;
        } else if (isEndianConversion(out_info.*.finfo, in_info.*.finfo)) {
            if (cv.resampler == null and out_info.*.layout == in_info.*.layout) {
                cv.convert = convEndian;
                cv.in_place = true;
                cv.swap = switch (in_info.*.finfo.*.width) {
                    16 => swapFn(u16),
                    24 => swap24,
                    32 => swapFn(u32),
                    else => swapFn(u64),
                };
            }
        }
    }
    setupAllocators(cv);
    return @ptrCast(cv);
}

pub export fn gst_audio_converter_free(cp: ?*c.GstAudioConverter) void {
    if (!check.that(cp != null, "gst_audio_converter_free", "convert != NULL")) return;
    const cv = of(cp);
    var ch = cv.chain_end;
    while (ch) |cc| {
        ch = cc.prev;
        chainFree(cc);
    }
    if (cv.quant != null) quantize.gst_audio_quantize_free(cv.quant);
    if (cv.mix != null) mixer.gst_audio_channel_mixer_free(cv.mix);
    if (cv.resampler != null) resampler.gst_audio_resampler_free(cv.resampler);
    info_mod.gst_audio_info_init(&cv.in);
    info_mod.gst_audio_info_init(&cv.out);
    c.gst_structure_free(cv.config);
    c.g_free(cv);
}

pub export fn gst_audio_converter_get_out_frames(cp: ?*c.GstAudioConverter, in_frames: c_ulong) c_ulong {
    const cv = of(cp);
    return if (cv.resampler != null) resampler.gst_audio_resampler_get_out_frames(cv.resampler, in_frames) else in_frames;
}

pub export fn gst_audio_converter_get_in_frames(cp: ?*c.GstAudioConverter, out_frames: c_ulong) c_ulong {
    const cv = of(cp);
    return if (cv.resampler != null) resampler.gst_audio_resampler_get_in_frames(cv.resampler, out_frames) else out_frames;
}

pub export fn gst_audio_converter_get_max_latency(cp: ?*c.GstAudioConverter) c_ulong {
    const cv = of(cp);
    return if (cv.resampler != null) resampler.gst_audio_resampler_get_max_latency(cv.resampler) else 0;
}

pub export fn gst_audio_converter_reset(cp: ?*c.GstAudioConverter) void {
    const cv = of(cp);
    if (cv.resampler != null) resampler.gst_audio_resampler_reset(cv.resampler);
    if (cv.quant != null) quantize.gst_audio_quantize_reset(cv.quant);
}

pub export fn gst_audio_converter_samples(cp: ?*c.GstAudioConverter, flags: c.GstAudioConverterFlags, in: [*c]c.gpointer, in_frames: c_ulong, out: [*c]c.gpointer, out_frames: c_ulong) c.gboolean {
    const fname = "gst_audio_converter_samples";
    if (!check.that(cp != null, fname, "convert != NULL")) return 0;
    if (!check.that(out != null, fname, "out != NULL")) return 0;
    if (in_frames == 0) return 1;
    const cv = of(cp);
    return @intFromBool(cv.convert(cv, flags, in, in_frames, out, out_frames));
}

pub export fn gst_audio_converter_convert(cp: ?*c.GstAudioConverter, flags: c.GstAudioConverterFlags, in: c.gpointer, in_size: c_ulong, out: [*c]c.gpointer, out_size: [*c]c_ulong) c.gboolean {
    const fname = "gst_audio_converter_convert";
    if (!check.that(cp != null, fname, "convert != NULL")) return 0;
    if (!check.that(flags ^ c.GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE != 0, fname, "flags ^ GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE")) return 0;
    const cv = of(cp);
    const in_frames = in_size / @as(usize, @intCast(cv.in.bpf));
    const out_frames = gst_audio_converter_get_out_frames(cp, in_frames);
    out_size.* = out_frames * @as(usize, @intCast(cv.out.bpf));
    out.* = c.g_malloc0(out_size.*);
    var inp = [1]c.gpointer{in};
    return gst_audio_converter_samples(cp, flags, &inp, in_frames, out, out_frames);
}

pub export fn gst_audio_converter_supports_inplace(cp: ?*c.GstAudioConverter) c.gboolean {
    return @intFromBool(of(cp).in_place);
}

pub export fn gst_audio_converter_is_passthrough(cp: ?*c.GstAudioConverter) c.gboolean {
    return @intFromBool(of(cp).passthrough);
}
