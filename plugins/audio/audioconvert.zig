const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const reorder = @import("reorder.zig");

const FILE = "../gst/audioconvert/gstaudioconvert.c";
const CAPS = "audio/x-raw, format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout = (string) { interleaved, non-interleaved }";

const PROP_DITHERING = 1;
const PROP_NOISE_SHAPING = 2;
const PROP_MIX_MATRIX = 3;
const PROP_DITHERING_THRESHOLD = 4;
const PROP_INPUT_CHANNELS_REORDER = 5;
const PROP_INPUT_CHANNELS_REORDER_MODE = 6;

const MODE_NONE = 0;
const MODE_FORCE = 2;

const FL_FR: u64 = (1 << c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT) | (1 << c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT);

const Self = extern struct {
    parent: c.GstBaseTransform,
    dither: c.gint,
    dither_threshold: c.guint,
    ns: c.gint,
    mix_matrix: c.GValue,
    mix_matrix_is_set: c.gboolean,
    reorder: c.gint,
    reorder_mode: c.gint,
    in_info: c.GstAudioInfo,
    out_info: c.GstAudioInfo,
    convert: ?*c.GstAudioConverter,
};

const Class = extern struct {
    parent: c.GstBaseTransformClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var reorder_once: cm.Once = .{};
var mode_once: cm.Once = .{};
var parent: ?*c.GstBaseTransformClass = null;
var audio_tag: c.GQuark = 0;

var reorders = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "Reorder the input channels using the default GStreamer order", .value_nick = "gst" },
    .{ .value = 1, .value_name = "Reorder the input channels using the SMPTE order", .value_nick = "smpte" },
    .{ .value = 2, .value_name = "Reorder the input channels using the CINE order", .value_nick = "cine" },
    .{ .value = 3, .value_name = "Reorder the input channels using the AC3 order", .value_nick = "ac3" },
    .{ .value = 4, .value_name = "Reorder the input channels using the AAC order", .value_nick = "aac" },
    .{ .value = 5, .value_name = "Reorder and mix all input channels to a single mono channel", .value_nick = "mono" },
    .{ .value = 6, .value_name = "Reorder and mix all input channels to a single left and a single right stereo channels alternately", .value_nick = "alternate" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

var modes = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "Never reorder the input channels", .value_nick = "none" },
    .{ .value = 1, .value_name = "Reorder the input channels only if they are unpositioned", .value_nick = "unpositioned" },
    .{ .value = 2, .value_name = "Always reorder the input channels according to the selected configuration", .value_nick = "force" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn reorderType() c.GType {
    return reorder_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstAudioConvertInputChannelsReorder", &reorders);
        }
    }.f);
}

fn modeType() c.GType {
    return mode_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstAudioConvertInputChannelsReorderMode", &modes);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn trans(p: anytype) [*c]c.GstBaseTransform {
    return @ptrCast(@alignCast(p));
}

fn positionsFor(channels: c.gint, which: c.gint, pos: [*c]c.GstAudioChannelPosition) bool {
    if (channels == 1) {
        pos[0] = c.GST_AUDIO_CHANNEL_POSITION_MONO;
        return true;
    }
    const cfg = reorder.configs[@intCast(which)];
    if (channels == 2 and cfg[0]) {
        pos[0] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;
        pos[1] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT;
        return true;
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(channels))) : (i += 1) pos[i] = if (i < 64) reorder.positions[@intCast(which)][i] else c.GST_AUDIO_CHANNEL_POSITION_INVALID;
    if (channels > 2 and cfg[1]) {
        pos[@intCast(channels - 1)] = c.GST_AUDIO_CHANNEL_POSITION_LFE1;
        if (channels == 3 and cfg[0]) {
            pos[0] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;
            pos[1] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT;
        }
    }
    return true;
}

fn unitSize(_: [*c]c.GstBaseTransform, caps: [*c]c.GstCaps, size: [*c]c.gsize) callconv(.c) c.gboolean {
    var info: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&info, caps) == 0) return 0;
    size[0] = @intCast(info.bpf);
    return 1;
}

fn dropFormat(_: ?*c.GstCapsFeatures, s: ?*c.GstStructure, _: c.gpointer) callconv(.c) c.gboolean {
    c.gst_structure_remove_field(s, "format");
    return 1;
}

fn dropLayout(_: ?*c.GstCapsFeatures, s: ?*c.GstStructure, _: c.gpointer) callconv(.c) c.gboolean {
    c.gst_structure_remove_field(s, "layout");
    return 1;
}

fn dropChannels(_: ?*c.GstCapsFeatures, s: ?*c.GstStructure, data: c.gpointer) callconv(.c) c.gboolean {
    const force = @as(*bool, @ptrCast(@alignCast(data))).*;
    var mask: u64 = 0;
    var ch: c.gint = 0;
    if (force or c.gst_structure_get(s, "channel-mask", c.gst_bitmask_get_type(), &mask, @as(?*anyopaque, null)) == 0 or (mask != 0 or (c.gst_structure_get_int(s, "channels", &ch) != 0 and ch == 1))) {
        c.gst_structure_remove_fields(s, "channel-mask", "channels", @as(?*anyopaque, null));
    }
    return 1;
}

fn setChannels(_: ?*c.GstCapsFeatures, s: ?*c.GstStructure, data: c.gpointer) callconv(.c) c.gboolean {
    c.gst_structure_set_static_str(s, "channels", c.G_TYPE_INT, @as(c.gint, @intCast(@intFromPtr(data))), @as(?*anyopaque, null));
    return 1;
}

fn transformCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bt);
    var tmp = c.gst_caps_copy(caps);
    _ = c.gst_caps_map_in_place(tmp, dropFormat, null);
    _ = c.gst_caps_map_in_place(tmp, dropLayout, null);
    cm.lock(s);
    var force = s.mix_matrix_is_set != 0 or (dir == c.GST_PAD_SINK and s.reorder_mode != MODE_NONE);
    _ = c.gst_caps_map_in_place(tmp, dropChannels, &force);
    if (c.gst_value_array_get_size(&s.mix_matrix) != 0) {
        const other: c.guint = if (dir == c.GST_PAD_SRC) c.gst_value_array_get_size(c.gst_value_array_get_value(&s.mix_matrix, 0)) else c.gst_value_array_get_size(&s.mix_matrix);
        _ = c.gst_caps_map_in_place(tmp, setChannels, @ptrFromInt(other));
    }
    cm.unlock(s);
    if (filter != null) {
        const t2 = c.gst_caps_intersect_full(filter, tmp, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_mini_object_unref(@ptrCast(tmp));
        tmp = t2;
    }
    return tmp;
}

fn bits(x_in: u64) c.gint {
    var x = x_in;
    var n: c.gint = 0;
    while (x != 0) : (n += 1) x &= x - 1;
    return n;
}

fn suitableMask(mask: u64, n_in: c.gint) u64 {
    var x = mask;
    var n = n_in;
    while (x != 0 and n != 0) : (n -= 1) x &= x - 1;
    if (!(x != 0 or n == 0)) c.g_assertion_message_expr(null, FILE, 1230, "find_suitable_mask", "x || n_chans == 0");
    return mask - x;
}

fn depthFlags(info: [*c]const c.GstAudioFormatInfo) struct { c.gint, c.GstAudioFormatFlags } {
    return .{ info[0].depth, info[0].flags & ~@as(c.GstAudioFormatFlags, c.GST_AUDIO_FORMAT_FLAG_UNPACK | c.GST_AUDIO_FORMAT_FLAG_SIGNED) };
}

fn fixateFormat(ins: ?*c.GstStructure, outs: ?*c.GstStructure) void {
    const in_fmt = c.gst_structure_get_string(ins, "format");
    if (in_fmt == null) return;
    const fmt = c.gst_structure_get_value(outs, "format");
    if (fmt == null or fmt[0].g_type != c.gst_value_list_get_type()) return;
    const in_info = c.gst_audio_format_get_info(c.gst_audio_format_from_string(in_fmt));
    if (in_info == null) return;
    const in_df = depthFlags(in_info);
    var out_info: [*c]const c.GstAudioFormatInfo = null;
    var out_depth: c.gint = -1;
    var out_flags: c.GstAudioFormatFlags = 0;
    const n = c.gst_value_list_get_size(fmt);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const v = c.gst_value_list_get_value(fmt, i);
        if (v[0].g_type != c.G_TYPE_STRING) continue;
        const name = c.g_value_get_string(v);
        const t = c.gst_audio_format_get_info(c.gst_audio_format_from_string(name));
        if (t == null) continue;
        if (c.strcmp(name, in_fmt) == 0) {
            out_info = t;
            break;
        }
        const df = depthFlags(t);
        if (out_info == null) {
            out_info = t;
            out_depth = df[0];
            out_flags = df[1];
            continue;
        }
        const better = df[1] == in_df[1] and out_flags != in_df[1];
        if ((df[0] == in_df[0] and (out_depth != in_df[0] or better)) or
            (df[0] >= in_df[0] and (in_df[0] > out_depth or (out_depth >= in_df[0] and better))) or
            ((df[0] > out_depth and out_depth < in_df[0]) or (better and out_depth == df[0])))
        {
            out_info = t;
            out_depth = df[0];
            out_flags = df[1];
        }
    }
    if (out_info != null) c.gst_structure_set_static_str(outs, "format", c.G_TYPE_STRING, out_info[0].name, @as(?*anyopaque, null));
}

fn setMask(outs: ?*c.GstStructure, mask: u64) void {
    c.gst_structure_set_static_str(outs, "channel-mask", c.gst_bitmask_get_type(), mask, @as(?*anyopaque, null));
}

fn fixateChannels(s: *Self, ins: ?*c.GstStructure, outs: ?*c.GstStructure) void {
    var in_ch: c.gint = 0;
    var out_ch: c.gint = 0;
    if (c.gst_structure_get_int(ins, "channels", &in_ch) == 0) return;
    if (c.gst_structure_has_field(outs, "channels") == 0) {
        c.gst_structure_remove_field(outs, "channel-mask");
        return;
    }
    _ = c.gst_structure_fixate_field_nearest_int(outs, "channels", in_ch);
    if (c.gst_structure_get_int(outs, "channels", &out_ch) == 0) {
        c.gst_structure_remove_field(outs, "channel-mask");
        return;
    }
    var out_mask: u64 = 0;
    var has_out = c.gst_structure_has_field(outs, "channel-mask") != 0;
    if (has_out) {
        _ = c.gst_structure_get(outs, "channel-mask", c.gst_bitmask_get_type(), &out_mask, @as(?*anyopaque, null));
    } else if (out_ch == 2) {
        out_mask = FL_FR;
        has_out = true;
        setMask(outs, out_mask);
    }
    var in_mask: u64 = 0;
    var has_in = c.gst_structure_has_field(ins, "channel-mask") != 0;
    if (has_in) {
        _ = c.gst_structure_get(ins, "channel-mask", c.gst_bitmask_get_type(), &in_mask, @as(?*anyopaque, null));
    } else if (in_ch == 2) {
        in_mask = FL_FR;
        has_in = true;
    }
    if (!has_out and out_ch == 1 and (in_ch != out_ch or !has_in)) return;
    if (in_ch == out_ch and (has_in or in_ch == 1)) {
        if (!has_out) return setMask(outs, in_mask);
        if (in_mask == out_mask) return;
        if (bits(out_mask) == out_ch) return;
        if (bits(out_mask) >= in_ch) {
            if (bits(in_mask & out_mask) >= in_ch) return setMask(outs, in_mask);
            const m = suitableMask(out_mask, out_ch);
            if (m != 0) return setMask(outs, m);
        }
    } else {
        if (has_out and out_mask == 0) return setMask(outs, out_mask);
        if (bits(out_mask) >= out_ch) return setMask(outs, suitableMask(out_mask, out_ch));
        _ = s;
    }
    if (out_ch > 1) {
        const fb = c.gst_audio_channel_get_fallback_mask(out_ch);
        setMask(outs, fb);
    }
}

fn fixateCaps(bt: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps, other: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    var res = c.gst_caps_intersect(other, caps);
    if (c.gst_caps_is_empty(res) != 0) {
        const removed = c.gst_caps_copy(caps);
        if (res != null) c.gst_mini_object_unref(@ptrCast(res));
        _ = c.gst_caps_map_in_place(removed, dropFormat, null);
        _ = c.gst_caps_map_in_place(removed, dropLayout, null);
        res = c.gst_caps_intersect(other, removed);
        c.gst_mini_object_unref(@ptrCast(removed));
        if (c.gst_caps_is_empty(res) != 0) {
            if (res != null) c.gst_mini_object_unref(@ptrCast(res));
            res = other;
        } else c.gst_mini_object_unref(@ptrCast(other));
    } else c.gst_mini_object_unref(@ptrCast(other));
    res = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(res))));
    const ins = c.gst_caps_get_structure(caps, 0);
    const outs = c.gst_caps_get_structure(res, 0);
    fixateChannels(me(bt), ins, outs);
    fixateFormat(ins, outs);
    return c.gst_caps_fixate(res);
}

fn infoValid(i: *const c.GstAudioInfo) bool {
    return i.finfo != null and i.rate > 0 and i.channels > 0 and i.bpf > 0;
}

fn ensureConverter(bt: [*c]c.GstBaseTransform, in_info: *c.GstAudioInfo, out_info: *c.GstAudioInfo) bool {
    const s = me(bt);
    cm.lock(s);
    defer cm.unlock(s);
    if (s.convert != null or !infoValid(in_info) or !infoValid(out_info)) return true;
    const config = c.gst_structure_new_static_str("GstAudioConverterConfig", c.GST_AUDIO_CONVERTER_OPT_DITHER_METHOD, c.gst_audio_dither_method_get_type(), s.dither, c.GST_AUDIO_CONVERTER_OPT_DITHER_THRESHOLD, c.G_TYPE_UINT, s.dither_threshold, c.GST_AUDIO_CONVERTER_OPT_NOISE_SHAPING_METHOD, c.gst_audio_noise_shaping_method_get_type(), s.ns, @as(?*anyopaque, null));
    if (s.mix_matrix_is_set != 0) {
        c.gst_structure_set_value_static_str(config, c.GST_AUDIO_CONVERTER_OPT_MIX_MATRIX, &s.mix_matrix);
        s.convert = c.gst_audio_converter_new(0, in_info, out_info, config);
    } else if (s.reorder_mode != MODE_NONE) {
        const ch: usize = @intCast(in_info.channels);
        const saved_flags = in_info.flags;
        var saved: [64]c.GstAudioChannelPosition = undefined;
        var restore = false;
        if (s.reorder_mode == MODE_FORCE or in_info.flags & c.GST_AUDIO_FLAG_UNPOSITIONED != 0) {
            @memcpy(saved[0..ch], in_info.position[0..ch]);
            if (positionsFor(in_info.channels, s.reorder, &in_info.position)) {
                in_info.flags &= ~@as(c.GstAudioFlags, c.GST_AUDIO_FLAG_UNPOSITIONED);
                restore = true;
            }
        }
        s.convert = c.gst_audio_converter_new(0, in_info, out_info, config);
        if (restore) {
            in_info.flags = saved_flags;
            @memcpy(in_info.position[0..ch], saved[0..ch]);
        }
    } else s.convert = c.gst_audio_converter_new(0, in_info, out_info, config);
    const conv = s.convert orelse return false;
    const in_place = c.gst_audio_converter_supports_inplace(conv);
    cm.unlock(s);
    c.gst_base_transform_set_in_place(bt, in_place);
    c.gst_base_transform_set_passthrough(bt, c.gst_audio_converter_is_passthrough(conv));
    cm.lock(s);
    return true;
}

fn freeConverter(s: *Self) void {
    if (s.convert) |cv| c.gst_audio_converter_free(cv);
    s.convert = null;
}

fn setCaps(bt: [*c]c.GstBaseTransform, incaps: [*c]c.GstCaps, outcaps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bt);
    freeConverter(s);
    var in_info: c.GstAudioInfo = undefined;
    var out_info: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&in_info, incaps) == 0 or c.gst_audio_info_from_caps(&out_info, outcaps) == 0) return 0;
    if (!ensureConverter(bt, &in_info, &out_info)) return 0;
    s.in_info = in_info;
    s.out_info = out_info;
    return 1;
}

fn formatError(s: *Self, dbg: [:0]const u8, line: c.gint) c.GstFlowReturn {
    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup(dbg.ptr), FILE, "gst_audio_convert_transform", line);
    return c.GST_FLOW_ERROR;
}

fn transform(bt: [*c]c.GstBaseTransform, inbuf: [*c]c.GstBuffer, outbuf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    if (c.gst_buffer_get_size(inbuf) == 0) return c.GST_FLOW_OK;
    _ = ensureConverter(bt, &s.in_info, &s.out_info);
    const conv = s.convert orelse return c.GST_FLOW_ERROR;
    var src: c.GstAudioBuffer = undefined;
    var dst: c.GstAudioBuffer = undefined;
    const same = inbuf == outbuf;
    var writable = true;
    if (!same) {
        writable = c.gst_buffer_is_writable(inbuf) != 0 and c.gst_buffer_n_memory(inbuf) == 1 and c.gst_memory_is_writable(c.gst_buffer_peek_memory(inbuf, 0)) != 0;
        if (c.gst_audio_buffer_map(&src, &s.in_info, inbuf, if (writable) c.GST_MAP_READWRITE else c.GST_MAP_READ) == 0) return formatError(s, "failed to map input buffer", 1759);
    }
    if (c.gst_audio_buffer_map(&dst, &s.out_info, outbuf, c.GST_MAP_WRITE) == 0) {
        if (!same) c.gst_audio_buffer_unmap(&src);
        return formatError(s, "failed to map output buffer", 1765);
    }
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (cm.buf(inbuf).mini_object.flags & c.GST_BUFFER_FLAG_GAP == 0) {
        const flags: c.GstAudioConverterFlags = if (writable) c.GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE else 0;
        if (c.gst_audio_converter_samples(conv, flags, if (same) dst.planes else src.planes, dst.n_samples, dst.planes, dst.n_samples) == 0) ret = formatError(s, "error while converting", 1752);
    } else {
        var i: c.gint = 0;
        while (i < dst.n_planes) : (i += 1) c.gst_audio_format_info_fill_silence(s.out_info.finfo, dst.planes[@intCast(i)], dst.n_samples * @as(c.gsize, @intCast(if (s.out_info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) @divTrunc(s.out_info.bpf, s.out_info.channels) else s.out_info.bpf)));
    }
    c.gst_audio_buffer_unmap(&dst);
    if (!same) c.gst_audio_buffer_unmap(&src);
    return ret;
}

fn transformIp(bt: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return transform(bt, b, b);
}

fn transformMeta(_: [*c]c.GstBaseTransform, _: [*c]c.GstBuffer, meta: [*c]c.GstMeta, _: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const api = meta[0].info[0].api;
    const tags = c.gst_meta_api_type_get_tags(api);
    return @intFromBool(tags == null or (c.g_strv_length(@ptrCast(@constCast(tags))) == 1 and c.gst_meta_api_type_has_tag(api, audio_tag) != 0));
}

fn submitInput(bt: [*c]c.GstBaseTransform, discont: c.gboolean, input_in: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    var input = input_in;
    if (bt[0].segment.format == c.GST_FORMAT_TIME) {
        if (!infoValid(&s.in_info)) return c.GST_FLOW_NOT_NEGOTIATED;
        input = c.gst_audio_buffer_clip(input, &bt[0].segment, s.in_info.rate, s.in_info.bpf);
        if (input == null) return c.GST_FLOW_OK;
    }
    return parent.?.submit_input_buffer.?(bt, discont, input);
}

fn prepareOutput(bt: [*c]c.GstBaseTransform, inbuf: [*c]c.GstBuffer, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    const ret = parent.?.prepare_output_buffer.?(bt, inbuf, out);
    if (ret != c.GST_FLOW_OK) return ret;
    const meta: [*c]c.GstAudioMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(inbuf, c.gst_audio_meta_api_get_type())));
    if (inbuf != out[0]) {
        const samples: c.gsize = if (meta != null) meta[0].samples else c.gst_buffer_get_size(inbuf) / @as(c.gsize, @intCast(s.in_info.bpf));
        c.gst_buffer_resize(out[0], 0, @intCast(samples * @as(c.gsize, @intCast(s.out_info.bpf))));
        if (s.out_info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) _ = c.gst_buffer_add_audio_meta(out[0], &s.out_info, samples, null);
    } else if (meta != null) meta[0].info = s.out_info;
    return ret;
}

fn setMixMatrix(s: *Self, v: [*c]const c.GValue) void {
    cm.lock(s);
    freeConverter(s);
    if (c.gst_value_array_get_size(v) == 0) {
        c.g_value_copy(v, &s.mix_matrix);
        s.mix_matrix_is_set = 1;
    } else if (c.gst_value_array_get_size(c.gst_value_array_get_value(v, 0)) != 0) {
        c.g_value_copy(v, &s.mix_matrix);
        s.mix_matrix_is_set = 1;
    } else s.mix_matrix_is_set = 0;
    cm.unlock(s);
    c.gst_base_transform_set_in_place(trans(s), 0);
    c.gst_base_transform_set_passthrough(trans(s), 0);
    c.gst_base_transform_reconfigure_sink(trans(s));
}

fn srcEvent(bt: [*c]c.GstBaseTransform, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(ev) == c.GST_EVENT_CUSTOM_UPSTREAM) {
        const st = c.gst_event_get_structure(ev);
        if (st != null and c.gst_structure_has_name(st, "GstRequestAudioMixMatrix") != 0) {
            const m = c.gst_structure_get_value(st, "matrix");
            if (m != null) {
                setMixMatrix(me(bt), m);
                c.g_object_notify(@ptrCast(@alignCast(bt)), "mix-matrix");
            }
            return 1;
        }
    }
    return parent.?.src_event.?(bt, ev);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_DITHERING => s.dither = c.g_value_get_enum(v),
        PROP_NOISE_SHAPING => s.ns = c.g_value_get_enum(v),
        PROP_DITHERING_THRESHOLD => s.dither_threshold = c.g_value_get_uint(v),
        PROP_MIX_MATRIX => setMixMatrix(s, v),
        PROP_INPUT_CHANNELS_REORDER => s.reorder = c.g_value_get_enum(v),
        PROP_INPUT_CHANNELS_REORDER_MODE => s.reorder_mode = c.g_value_get_enum(v),
        else => cm.warnInvalid(FILE, o, id, spec, 1915),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_DITHERING => c.g_value_set_enum(v, s.dither),
        PROP_NOISE_SHAPING => c.g_value_set_enum(v, s.ns),
        PROP_DITHERING_THRESHOLD => c.g_value_set_uint(v, s.dither_threshold),
        PROP_MIX_MATRIX => {
            cm.lock(s);
            if (s.mix_matrix_is_set != 0) c.g_value_copy(&s.mix_matrix, v);
            cm.unlock(s);
        },
        PROP_INPUT_CHANNELS_REORDER => c.g_value_set_enum(v, s.reorder),
        PROP_INPUT_CHANNELS_REORDER_MODE => c.g_value_set_enum(v, s.reorder_mode),
        else => cm.warnInvalid(FILE, o, id, spec, 1949),
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    freeConverter(s);
    if (s.mix_matrix.g_type != 0) c.g_value_unset(&s.mix_matrix);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_DITHERING, c.g_param_spec_enum("dithering", "Dithering", "Selects between different dithering methods.", c.gst_audio_dither_method_get_type(), c.GST_AUDIO_DITHER_TPDF, cm.RW));
    c.g_object_class_install_property(oc, PROP_NOISE_SHAPING, c.g_param_spec_enum("noise-shaping", "Noise shaping", "Selects between different noise shaping methods.", c.gst_audio_noise_shaping_method_get_type(), c.GST_AUDIO_NOISE_SHAPING_NONE, cm.RW));
    c.g_object_class_install_property(oc, PROP_MIX_MATRIX, c.gst_param_spec_array("mix-matrix", "Input/output channel matrix", "Transformation matrix for input/output channels.", c.gst_param_spec_array("matrix-rows", "rows", "rows", c.g_param_spec_float("matrix-cols", "cols", "cols", -1, 1, 0, cm.RW), cm.RW), cm.RW));
    c.g_object_class_install_property(oc, PROP_DITHERING_THRESHOLD, c.g_param_spec_uint("dithering-threshold", "Dithering Threshold", "Threshold for the output bit depth at/below which to apply dithering.", 0, 32, 20, cm.RW));
    c.g_object_class_install_property(oc, PROP_INPUT_CHANNELS_REORDER, c.g_param_spec_enum("input-channels-reorder", "Input Channels Reorder", "The positions configuration to use to reorder the input channels consecutively according to their index.", reorderType(), 0, cm.RW));
    c.gst_type_mark_as_plugin_api(reorderType(), 0);
    c.g_object_class_install_property(oc, PROP_INPUT_CHANNELS_REORDER_MODE, c.g_param_spec_enum("input-channels-reorder-mode", "Input Channels Reorder Mode", "The input channels reordering mode used to apply the selected positions configuration.", modeType(), MODE_NONE, cm.RW));
    c.gst_type_mark_as_plugin_api(modeType(), 0);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Audio converter", "Filter/Converter/Audio", "Convert audio to different formats", "Benjamin Otte <otte@gnome.org>");
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.get_unit_size = unitSize;
    tc.transform_caps = transformCaps;
    tc.fixate_caps = fixateCaps;
    tc.set_caps = setCaps;
    tc.transform = transform;
    tc.transform_ip = transformIp;
    tc.transform_meta = transformMeta;
    tc.submit_input_buffer = submitInput;
    tc.prepare_output_buffer = prepareOutput;
    tc.src_event = srcEvent;
    tc.transform_ip_on_passthrough = 0;
    audio_tag = c.g_quark_from_static_string(c.GST_META_TAG_AUDIO_STR);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.dither = c.GST_AUDIO_DITHER_TPDF;
    s.dither_threshold = 20;
    s.ns = c.GST_AUDIO_NOISE_SHAPING_NONE;
    s.mix_matrix = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&s.mix_matrix, c.gst_value_array_get_type());
    c.gst_base_transform_set_gap_aware(trans(s), 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_transform_get_type(), "GstAudioConvert", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("audioconvert", 0, "audio conversion element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "audioconvert", c.GST_RANK_PRIMARY, getType()) != 0;
}
