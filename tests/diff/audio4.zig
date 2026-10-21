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

var seed: u32 = 777;

fn rnd() u32 {
    seed = seed *% 1103515245 +% 12345;
    return seed;
}

fn fillInput(f: c.GstAudioFormat, buf: []u8, k: usize) void {
    const info = c.gst_audio_format_get_info(f);
    const isfloat = info.*.flags & c.GST_AUDIO_FORMAT_FLAG_FLOAT != 0;
    if (!isfloat) {
        for (buf, 0..) |*x, i| x.* = @truncate((rnd() >> 11) ^ (i *% 3) +% k);
        return;
    }
    var tmp: [8192]f64 = undefined;
    const bytes: usize = @intCast(@divTrunc(info.*.width, 8));
    const n = buf.len / bytes;
    for (0..n) |i| tmp[i] = @sin(@as(f64, @floatFromInt(i + k)) * 0.031) * 0.9 + @as(f64, @floatFromInt(rnd() % 2000)) / 1.0e5;
    info.*.pack_func.?(info, 0, &tmp, buf.ptr, @intCast(n));
}

const FORMATS = [_]c.GstAudioFormat{ c.GST_AUDIO_FORMAT_S8, c.GST_AUDIO_FORMAT_U8, c.GST_AUDIO_FORMAT_S16LE, c.GST_AUDIO_FORMAT_S16BE, c.GST_AUDIO_FORMAT_U16LE, c.GST_AUDIO_FORMAT_S24LE, c.GST_AUDIO_FORMAT_S24BE, c.GST_AUDIO_FORMAT_S24_32LE, c.GST_AUDIO_FORMAT_S32LE, c.GST_AUDIO_FORMAT_S32BE, c.GST_AUDIO_FORMAT_U32LE, c.GST_AUDIO_FORMAT_S20LE, c.GST_AUDIO_FORMAT_F32LE, c.GST_AUDIO_FORMAT_F32BE, c.GST_AUDIO_FORMAT_F64LE, c.GST_AUDIO_FORMAT_F64BE };

fn run(label: []const u8, in_info: *c.GstAudioInfo, out_info: *c.GstAudioInfo, config: ?*c.GstStructure, flags: c.GstAudioConverterFlags) void {
    const cfg_copy = if (config != null) c.gst_structure_copy(config) else null;
    const cv = c.gst_audio_converter_new(flags, in_info, out_info, cfg_copy);
    if (cv == null) {
        out("  {s} null", .{label});
        return;
    }
    var h: u64 = 0;
    var produced: usize = 0;
    const ibpf: usize = @intCast(in_info.bpf);
    const obpf: usize = @intCast(out_info.bpf);
    const in_ch: usize = @intCast(in_info.channels);
    const out_ch: usize = @intCast(out_info.channels);
    var inbuf: [8 * 8 * 700]u8 align(16) = undefined;
    var outbuf: [8 * 8 * 2200]u8 align(16) = undefined;
    for ([_]usize{ 1, 13, 256, 0, 640, 100 }, 0..) |n, k| {
        fillInput(in_info.finfo.*.format, inbuf[0 .. n * ibpf], k * 1000);
        const of = c.gst_audio_converter_get_out_frames(cv, n);
        @memset(outbuf[0 .. of * obpf], 0xab);
        var in: [8]c.gpointer = undefined;
        var o: [8]c.gpointer = undefined;
        if (in_info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) {
            for (0..in_ch) |cc| in[cc] = @ptrCast(&inbuf[cc * n * (ibpf / in_ch)]);
        } else in[0] = @ptrCast(&inbuf);
        if (out_info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) {
            for (0..out_ch) |cc| o[cc] = @ptrCast(&outbuf[cc * of * (obpf / out_ch)]);
        } else o[0] = @ptrCast(&outbuf);
        const r = c.gst_audio_converter_samples(cv, flags, if (k == 3) null else &in, if (k == 3) 50 else n, &o, if (k == 3) c.gst_audio_converter_get_out_frames(cv, 50) else of);
        const used = (if (k == 3) c.gst_audio_converter_get_out_frames(cv, 50) else of) * obpf;
        h = h *% 131 +% hash(outbuf[0..@min(used, outbuf.len)]) +% @as(u64, @intCast(r));
        if (flags & c.GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE != 0) h = h *% 7 +% hash(inbuf[0 .. n * ibpf]);
        produced += of;
    }
    var ir: c_int = 0;
    var orate: c_int = 0;
    const cfg = c.gst_audio_converter_get_config(cv, &ir, &orate);
    const cs = c.gst_structure_to_string(cfg);
    out("  {s} pass={d} inplace={d} lat={d} produced={d} in={d} {x} cfg={s}", .{ label, c.gst_audio_converter_is_passthrough(cv), c.gst_audio_converter_supports_inplace(cv), c.gst_audio_converter_get_max_latency(cv), produced, c.gst_audio_converter_get_in_frames(cv, 100), h, std.mem.span(cs) });
    c.g_free(cs);
    c.gst_audio_converter_reset(cv);
    c.gst_audio_converter_free(cv);
}

fn setInfo(i: *c.GstAudioInfo, f: c.GstAudioFormat, rate: c_int, ch: c_int, layout: c.GstAudioLayout) void {
    c.gst_audio_info_set_format(i, f, rate, ch, null);
    i.layout = layout;
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    out("type {s}", .{std.mem.span(c.g_type_name(c.gst_audio_converter_get_type()))});
    var a: c.GstAudioInfo = undefined;
    var b: c.GstAudioInfo = undefined;
    var lb: [128]u8 = undefined;
    for (FORMATS) |fi| for (FORMATS) |fo| {
        setInfo(&a, fi, 44100, 2, 0);
        setInfo(&b, fo, 44100, 2, 0);
        run(std.fmt.bufPrint(&lb, "fmt {d}->{d}", .{ fi, fo }) catch "", &a, &b, null, 0);
    };
    const pairs = [_][2]c.GstAudioFormat{ .{ c.GST_AUDIO_FORMAT_S16LE, c.GST_AUDIO_FORMAT_F32LE }, .{ c.GST_AUDIO_FORMAT_F32LE, c.GST_AUDIO_FORMAT_S16LE }, .{ c.GST_AUDIO_FORMAT_S24LE, c.GST_AUDIO_FORMAT_S16LE }, .{ c.GST_AUDIO_FORMAT_S16LE, c.GST_AUDIO_FORMAT_S16LE }, .{ c.GST_AUDIO_FORMAT_F64LE, c.GST_AUDIO_FORMAT_U8 } };
    for (pairs) |p| for ([_][2]c_int{ .{ 1, 2 }, .{ 2, 1 }, .{ 6, 2 }, .{ 2, 6 }, .{ 3, 3 } }) |ch| for ([_][2]c_int{ .{ 44100, 44100 }, .{ 44100, 48000 }, .{ 48000, 22050 } }) |rt| for ([_][2]c.GstAudioLayout{ .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 1, 0 } }) |ly| {
        const fi_float = c.gst_audio_format_get_info(p[0]).*.flags & c.GST_AUDIO_FORMAT_FLAG_FLOAT != 0;
        const fo_int = c.gst_audio_format_get_info(p[1]).*.flags & c.GST_AUDIO_FORMAT_FLAG_INTEGER != 0;
        if (fi_float and fo_int and (ch[0] > ch[1] or rt[1] != rt[0])) continue;
        setInfo(&a, p[0], rt[0], ch[0], ly[0]);
        setInfo(&b, p[1], rt[1], ch[1], ly[1]);
        if (ch[0] == 6) _ = c.gst_audio_channel_positions_from_mask(6, 0x3f, @ptrCast(&a.position));
        if (ch[1] == 6) _ = c.gst_audio_channel_positions_from_mask(6, 0x3f, @ptrCast(&b.position));
        if (ch[0] == 6) a.flags = 0;
        if (ch[1] == 6) b.flags = 0;
        run(std.fmt.bufPrint(&lb, "{d}->{d} ch{d}->{d} {d}->{d} ly{d}{d}", .{ p[0], p[1], ch[0], ch[1], rt[0], rt[1], ly[0], ly[1] }) catch "", &a, &b, null, 0);
    };
    const cfg = c.gst_structure_new_empty("cfg");
    for ([_]c_int{ 0, 1, 2, 3 }) |d| for ([_]c_int{ 0, 1, 2, 3, 4 }) |ns| {
        c.gst_structure_set(cfg, c.GST_AUDIO_CONVERTER_OPT_DITHER_METHOD, c.gst_audio_dither_method_get_type(), d, c.GST_AUDIO_CONVERTER_OPT_NOISE_SHAPING_METHOD, c.gst_audio_noise_shaping_method_get_type(), ns, NONE);
        setInfo(&a, c.GST_AUDIO_FORMAT_F32LE, 44100, 2, 0);
        setInfo(&b, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, 0);
        run(std.fmt.bufPrint(&lb, "dither {d} ns {d}", .{ d, ns }) catch "", &a, &b, cfg, 0);
        setInfo(&b, c.GST_AUDIO_FORMAT_S8, 44100, 2, 0);
        run(std.fmt.bufPrint(&lb, "dither {d} ns {d} s8", .{ d, ns }) catch "", &a, &b, cfg, 0);
    };
    c.gst_structure_set(cfg, c.GST_AUDIO_CONVERTER_OPT_DITHER_THRESHOLD, c.G_TYPE_UINT, @as(c_uint, 8), c.GST_AUDIO_CONVERTER_OPT_QUANTIZATION, c.G_TYPE_UINT, @as(c_uint, 4), NONE);
    setInfo(&a, c.GST_AUDIO_FORMAT_S32LE, 44100, 2, 0);
    setInfo(&b, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, 0);
    run("threshold", &a, &b, cfg, 0);
    for ([_]c_int{ 0, 1, 2, 3, 4 }) |m| {
        c.gst_structure_set(cfg, c.GST_AUDIO_CONVERTER_OPT_RESAMPLER_METHOD, c.gst_audio_resampler_method_get_type(), m, NONE);
        setInfo(&a, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, 0);
        setInfo(&b, c.GST_AUDIO_FORMAT_F32LE, 32000, 2, 0);
        run(std.fmt.bufPrint(&lb, "method {d}", .{m}) catch "", &a, &b, cfg, 0);
    }
    c.gst_structure_free(cfg);
    var mat = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&mat, c.gst_value_array_get_type());
    for (0..2) |j| {
        var row = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&row, c.gst_value_array_get_type());
        for (0..3) |i| {
            var v = std.mem.zeroes(c.GValue);
            if (i == 0) {
                _ = c.g_value_init(&v, c.G_TYPE_DOUBLE);
                c.g_value_set_double(&v, 0.25 * @as(f64, @floatFromInt(j + 1)));
            } else if (i == 1) {
                _ = c.g_value_init(&v, c.G_TYPE_FLOAT);
                c.g_value_set_float(&v, -0.5);
            } else {
                _ = c.g_value_init(&v, c.G_TYPE_INT);
                c.g_value_set_int(&v, @intCast(j));
            }
            c.gst_value_array_append_and_take_value(&row, &v);
        }
        c.gst_value_array_append_and_take_value(&mat, &row);
    }
    const mcfg = c.gst_structure_new_empty("m");
    c.gst_structure_set_value(mcfg, c.GST_AUDIO_CONVERTER_OPT_MIX_MATRIX, &mat);
    setInfo(&a, c.GST_AUDIO_FORMAT_S16LE, 44100, 3, 0);
    setInfo(&b, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, 0);
    run("matrix", &a, &b, mcfg, 0);
    setInfo(&b, c.GST_AUDIO_FORMAT_F32LE, 44100, 4, 0);
    run("matrix wrong", &a, &b, mcfg, 0);
    var empty = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&empty, c.gst_value_array_get_type());
    c.gst_structure_set_value(mcfg, c.GST_AUDIO_CONVERTER_OPT_MIX_MATRIX, &empty);
    setInfo(&b, c.GST_AUDIO_FORMAT_F32LE, 44100, 3, 0);
    run("matrix empty", &a, &b, mcfg, 0);
    c.gst_structure_free(mcfg);
    c.g_value_unset(&mat);
    c.g_value_unset(&empty);
    setInfo(&a, c.GST_AUDIO_FORMAT_S16LE, 44100, 3, 0);
    setInfo(&b, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, 0);
    a.flags = c.GST_AUDIO_FLAG_UNPOSITIONED;
    run("unpositioned", &a, &b, null, 0);
    a.flags = 0;
    setInfo(&a, c.GST_AUDIO_FORMAT_S16BE, 44100, 2, 0);
    setInfo(&b, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, 0);
    run("endian writable", &a, &b, null, c.GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE);
    setInfo(&a, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, 0);
    setInfo(&b, c.GST_AUDIO_FORMAT_S16LE, 48000, 2, 0);
    run("variable", &a, &b, null, c.GST_AUDIO_CONVERTER_FLAG_VARIABLE_RATE);
    setInfo(&a, c.GST_AUDIO_FORMAT_S32LE, 44100, 2, 0);
    setInfo(&b, c.GST_AUDIO_FORMAT_S24LE, 44100, 2, 0);
    run("s32->s24 writable", &a, &b, null, c.GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE);
    setInfo(&b, c.GST_AUDIO_FORMAT_S32LE, 44100, 2, 0);
    const cv = c.gst_audio_converter_new(c.GST_AUDIO_CONVERTER_FLAG_VARIABLE_RATE, &a, &b, null);
    var buf: [400]u8 = undefined;
    for (&buf, 0..) |*x, i| x.* = @truncate(i * 7);
    var ob: c.gpointer = null;
    var osz: c_ulong = 0;
    out("convert {d} {d}", .{ c.gst_audio_converter_convert(cv, 0, &buf, 400, &ob, &osz), osz });
    out("  hash {x}", .{hash(@as([*]u8, @ptrCast(ob))[0..osz])});
    c.g_free(ob);
    const upd = c.gst_structure_new("u", c.GST_AUDIO_CONVERTER_OPT_DITHER_METHOD, c.gst_audio_dither_method_get_type(), @as(c_int, 2), NONE);
    out("update {d}", .{c.gst_audio_converter_update_config(cv, 44100, 47000, upd)});
    var ir: c_int = 0;
    var orr: c_int = 0;
    const cs = c.gst_structure_to_string(c.gst_audio_converter_get_config(cv, &ir, &orr));
    out("  cfg {s} {d} {d}", .{ std.mem.span(cs), ir, orr });
    c.g_free(cs);
    const cv2 = c.gst_audio_converter_new(0, &a, &b, null);
    out("update fixed {d}", .{c.gst_audio_converter_update_config(cv2, 1, 2, null)});
    out("samples zero {d}", .{c.gst_audio_converter_samples(cv2, 0, null, 0, null, 0)});
    var dummy: [1]c.gpointer = .{null};
    out("samples empty {d}", .{c.gst_audio_converter_samples(cv2, 0, null, 0, &dummy, 0)});
    c.gst_audio_converter_free(cv2);
    const cp = c.g_boxed_copy(c.gst_audio_converter_get_type(), cv);
    out("  copy pass {d}", .{c.gst_audio_converter_is_passthrough(@ptrCast(cp))});
    c.g_boxed_free(c.gst_audio_converter_get_type(), cp);
    c.gst_audio_converter_free(cv);
}
