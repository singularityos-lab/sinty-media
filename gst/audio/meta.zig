const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const info_mod = @import("info.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Meta = c.GstMeta;
const Buffer = c.GstBuffer;
const Pos = c.GstAudioChannelPosition;
const DMeta = c.GstAudioDownmixMeta;
const CMeta = c.GstAudioClippingMeta;
const AMeta = c.GstAudioMeta;
const LMeta = c.GstAudioLevelMeta;

fn isCopy(t: c.GQuark) bool {
    return t == c._gst_meta_transform_copy;
}

fn apiType(store: *usize, comptime name: [*:0]const u8, tags: [*c][*c]const u8) c.GType {
    if (c.g_once_init_enter(store) != 0) c.g_once_init_leave(store, c.gst_meta_api_type_register(name, tags));
    return store.*;
}

fn infoOnce(store: *usize, make: *const fn () [*c]const c.GstMetaInfo) [*c]const c.GstMetaInfo {
    if (c.g_once_init_enter(store) != 0) c.g_once_init_leave(store, @intFromPtr(make()));
    return @ptrFromInt(store.*);
}

fn downmixInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const d: [*c]DMeta = @ptrCast(@alignCast(m));
    d.*.from_position = null;
    d.*.to_position = null;
    d.*.from_channels = 0;
    d.*.to_channels = 0;
    d.*.matrix = null;
    return 1;
}

fn downmixFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    const d: [*c]DMeta = @ptrCast(@alignCast(m));
    c.g_free(d.*.from_position);
    if (d.*.matrix != null) {
        c.g_free(d.*.matrix[0]);
        c.g_free(@ptrCast(d.*.matrix));
    }
}

fn downmixTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    const s: [*c]DMeta = @ptrCast(@alignCast(m));
    if (!isCopy(t)) return 0;
    return @intFromBool(gst_buffer_add_audio_downmix_meta(dest, s.*.from_position, s.*.from_channels, s.*.to_position, s.*.to_channels, @ptrCast(s.*.matrix)) != null);
}

pub export fn gst_buffer_get_audio_downmix_meta_for_channels(buffer: [*c]Buffer, to: [*c]const Pos, to_channels: c.gint) [*c]DMeta {
    var state: c.gpointer = null;
    const info = gst_audio_downmix_meta_get_info();
    while (true) {
        const m = c.gst_buffer_iterate_meta(buffer, &state);
        if (m == null) return null;
        if (m.*.info.*.api == info.*.api) {
            const a: [*c]DMeta = @ptrCast(@alignCast(m));
            const n: usize = @intCast(@max(to_channels, 0));
            if (a.*.to_channels == to_channels and std.mem.eql(Pos, a.*.to_position[0..n], to[0..n])) return a;
        }
    }
}

pub export fn gst_buffer_add_audio_downmix_meta(buffer: [*c]Buffer, from: [*c]const Pos, from_channels: c.gint, to: [*c]const Pos, to_channels: c.gint, matrix: [*c][*c]const f32) [*c]DMeta {
    const fname = "gst_buffer_add_audio_downmix_meta";
    if (!check.that(from != null, fname, "from_position != NULL")) return null;
    if (!check.that(from_channels > 0, fname, "from_channels > 0")) return null;
    if (!check.that(to != null, fname, "to_position != NULL")) return null;
    if (!check.that(to_channels > 0, fname, "to_channels > 0")) return null;
    if (!check.that(matrix != null, fname, "matrix != NULL")) return null;
    const m: [*c]DMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(buffer, gst_audio_downmix_meta_get_info(), null)));
    const nf: usize = @intCast(from_channels);
    const nt: usize = @intCast(to_channels);
    m.*.from_channels = from_channels;
    m.*.to_channels = to_channels;
    m.*.from_position = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Pos) * (nf + nt))));
    m.*.to_position = m.*.from_position + nf;
    @memcpy(m.*.from_position[0..nf], from[0..nf]);
    @memcpy(m.*.to_position[0..nt], to[0..nt]);
    m.*.matrix = @ptrCast(@alignCast(c.g_malloc(@sizeOf([*c]f32) * nt)));
    m.*.matrix[0] = @ptrCast(@alignCast(c.g_malloc(@sizeOf(f32) * nf * nt)));
    @memcpy(m.*.matrix[0][0..nf], matrix[0][0..nf]);
    for (1..nt) |i| {
        m.*.matrix[i] = m.*.matrix[0] + i * nf;
        @memcpy(m.*.matrix[i][0..nf], matrix[i][0..nf]);
    }
    return m;
}

var downmix_api: usize = 0;
var downmix_tags = [_][*c]const u8{ "audio", "channels", null };

pub export fn gst_audio_downmix_meta_api_get_type() c.GType {
    return apiType(&downmix_api, "GstAudioDownmixMetaAPI", &downmix_tags);
}

var downmix_info: usize = 0;

pub export fn gst_audio_downmix_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&downmix_info, struct {
        fn f() [*c]const c.GstMetaInfo {
            return c.gst_meta_register(gst_audio_downmix_meta_api_get_type(), "GstAudioDownmixMeta", @sizeOf(DMeta), downmixInit, downmixFree, downmixTransform);
        }
    }.f);
}

fn clippingInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const d: [*c]CMeta = @ptrCast(@alignCast(m));
    d.*.format = c.GST_FORMAT_UNDEFINED;
    d.*.start = 0;
    d.*.end = 0;
    return 1;
}

fn clippingTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const s: [*c]CMeta = @ptrCast(@alignCast(m));
    if (!isCopy(t)) return 0;
    const copy: [*c]c.GstMetaTransformCopy = @ptrCast(@alignCast(data));
    if (copy.*.region != 0) return 0;
    return @intFromBool(gst_buffer_add_audio_clipping_meta(dest, s.*.format, s.*.start, s.*.end) != null);
}

pub export fn gst_buffer_add_audio_clipping_meta(buffer: [*c]Buffer, fmt: c.GstFormat, start: c_ulong, end: c_ulong) [*c]CMeta {
    if (!check.that(fmt != c.GST_FORMAT_UNDEFINED, "gst_buffer_add_audio_clipping_meta", "format != GST_FORMAT_UNDEFINED")) return null;
    const m: [*c]CMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(buffer, gst_audio_clipping_meta_get_info(), null)));
    m.*.format = fmt;
    m.*.start = start;
    m.*.end = end;
    return m;
}

var clipping_api: usize = 0;
var clipping_tags = [_][*c]const u8{ "audio", "rate", null };

pub export fn gst_audio_clipping_meta_api_get_type() c.GType {
    return apiType(&clipping_api, "GstAudioClippingMetaAPI", &clipping_tags);
}

var clipping_info: usize = 0;

pub export fn gst_audio_clipping_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&clipping_info, struct {
        fn f() [*c]const c.GstMetaInfo {
            return c.gst_meta_register(gst_audio_clipping_meta_api_get_type(), "GstAudioClippingMeta", @sizeOf(CMeta), clippingInit, null, clippingTransform);
        }
    }.f);
}

fn audioInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const a: [*c]AMeta = @ptrCast(@alignCast(m));
    info_mod.gst_audio_info_init(&a.*.info);
    a.*.samples = 0;
    a.*.offsets = null;
    return 1;
}

fn audioFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    const a: [*c]AMeta = @ptrCast(@alignCast(m));
    if (a.*.offsets != null and a.*.offsets != @as([*c]usize, @ptrCast(&a.*.priv_offsets_arr))) c.g_free(a.*.offsets);
}

fn audioTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    const s: [*c]AMeta = @ptrCast(@alignCast(m));
    if (!isCopy(t)) return 0;
    return @intFromBool(gst_buffer_add_audio_meta(dest, &s.*.info, s.*.samples, s.*.offsets) != null);
}

fn audioSerialize(m: [*c]const Meta, data: [*c]c.GstByteArrayInterface, _: [*c]u8) callconv(.c) c.gboolean {
    const a: [*c]const AMeta = @ptrCast(@alignCast(m));
    const n_position: usize = if (a.*.info.channels > 64) 0 else @intCast(a.*.info.channels);
    const nch: usize = @intCast(a.*.info.channels);
    const size = 28 + n_position * 4 + nch * 8;
    const ptr = c.gst_byte_array_interface_append(data, size);
    if (ptr == null) return 0;
    var w: c.GstByteWriter = undefined;
    c.gst_byte_writer_init_with_data(&w, ptr, @intCast(size), 0);
    _ = c.gst_byte_writer_put_int32_le(&w, @intCast(a.*.info.finfo.*.format));
    _ = c.gst_byte_writer_put_int32_le(&w, @bitCast(a.*.info.flags));
    _ = c.gst_byte_writer_put_int32_le(&w, @intCast(a.*.info.layout));
    _ = c.gst_byte_writer_put_int32_le(&w, a.*.info.rate);
    _ = c.gst_byte_writer_put_int32_le(&w, a.*.info.channels);
    for (0..n_position) |i| _ = c.gst_byte_writer_put_int32_le(&w, a[0].info.position[i]);
    _ = c.gst_byte_writer_put_uint64_le(&w, a.*.samples);
    for (0..nch) |i| _ = c.gst_byte_writer_put_uint64_le(&w, a.*.offsets[i]);
    return 1;
}

fn audioDeserialize(_: [*c]const c.GstMetaInfo, buffer: [*c]Buffer, data: [*c]const u8, size: usize, version: u8) callconv(.c) [*c]Meta {
    if (version != 0) return null;
    var r: c.GstByteReader = undefined;
    c.gst_byte_reader_init(&r, data, @intCast(size));
    var fmt: i32 = 0;
    var flags: i32 = 0;
    var layout: i32 = 0;
    var rate: i32 = 0;
    var chans: i32 = 0;
    var ok = c.gst_byte_reader_get_int32_le(&r, &fmt) != 0;
    ok = c.gst_byte_reader_get_int32_le(&r, &flags) != 0 and ok;
    ok = c.gst_byte_reader_get_int32_le(&r, &layout) != 0 and ok;
    ok = c.gst_byte_reader_get_int32_le(&r, &rate) != 0 and ok;
    ok = c.gst_byte_reader_get_int32_le(&r, &chans) != 0 and ok;
    if (!ok) return null;
    const n_position: usize = if (chans > 64) 0 else @intCast(@max(chans, 0));
    const nch: usize = @intCast(@max(chans, 0));
    const position: [*c]i32 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(i32) * n_position)));
    const offsets: [*c]u64 = @ptrCast(@alignCast(c.g_malloc(@sizeOf(u64) * nch)));
    var samples: u64 = 0;
    for (0..n_position) |i| ok = c.gst_byte_reader_get_int32_le(&r, &position[i]) != 0 and ok;
    ok = c.gst_byte_reader_get_uint64_le(&r, &samples) != 0 and ok;
    for (0..nch) |i| ok = c.gst_byte_reader_get_uint64_le(&r, &offsets[i]) != 0 and ok;
    if (!ok) {
        c.g_free(position);
        c.g_free(offsets);
        return null;
    }
    var info: c.GstAudioInfo = undefined;
    info_mod.gst_audio_info_set_format(&info, @intCast(fmt), rate, chans, if (chans > 64) null else @ptrCast(position));
    info.flags = @bitCast(flags);
    info.layout = @intCast(layout);
    const m = gst_buffer_add_audio_meta(buffer, &info, samples, @ptrCast(offsets));
    c.g_free(offsets);
    c.g_free(position);
    return @ptrCast(m);
}

pub export fn gst_buffer_add_audio_meta(buffer: [*c]Buffer, info: [*c]const c.GstAudioInfo, samples: c_ulong, offsets: [*c]c_ulong) [*c]AMeta {
    const fname = "gst_buffer_add_audio_meta";
    if (!check.that(buffer != null and @as(*c.GstMiniObject, @ptrCast(buffer)).type == c.gst_buffer_get_type(), fname, "GST_IS_BUFFER (buffer)")) return null;
    if (!check.that(info != null, fname, "info != NULL")) return null;
    if (!check.that(info.*.finfo != null and info.*.rate > 0 and info.*.channels > 0 and info.*.bpf > 0, fname, "GST_AUDIO_INFO_IS_VALID (info)")) return null;
    if (!check.that(info.*.finfo.*.format != c.GST_AUDIO_FORMAT_UNKNOWN, fname, "GST_AUDIO_INFO_FORMAT (info) != GST_AUDIO_FORMAT_UNKNOWN")) return null;
    if (!check.that(info.*.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED or offsets == null, fname, "info->layout == GST_AUDIO_LAYOUT_NON_INTERLEAVED || !offsets")) return null;
    const m: [*c]AMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(buffer, gst_audio_meta_get_info(), null)));
    m.*.info = info.*;
    m.*.samples = samples;
    const plane: usize = samples *% @as(usize, @intCast(info.*.finfo.*.width)) / 8;
    if (info.*.layout != c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) return m;
    const n: usize = @intCast(info.*.channels);
    var max_offset: usize = 0;
    m.*.offsets = if (n > 8) @ptrCast(@alignCast(c.g_malloc(@sizeOf(usize) * n))) else @ptrCast(&m.*.priv_offsets_arr);
    if (offsets != null) {
        for (0..n) |i| {
            m.*.offsets[i] = offsets[i];
            max_offset = @max(max_offset, offsets[i]);
            for (0..n) |j| {
                if (i != j and !(offsets[j] +% plane <= offsets[i] or offsets[i] +% plane <= offsets[j])) {
                    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "GstAudioMeta properties would cause channel memory areas to overlap! offsets: %lu (%d), %lu (%d) with plane size %lu", offsets[i], @as(c_int, @intCast(i)), offsets[j], @as(c_int, @intCast(j)), plane);
                    _ = c.gst_buffer_remove_meta(buffer, @ptrCast(m));
                    return null;
                }
            }
        }
    } else {
        for (0..n) |i| m.*.offsets[i] = i *% plane;
        max_offset = m.*.offsets[n - 1];
    }
    if (max_offset +% plane > c.gst_buffer_get_size(buffer)) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "GstAudioMeta properties would cause out-of-bounds memory access on the buffer: max_offset %lu, samples %lu, bps %u, buffer size %lu", max_offset, samples, @as(c_uint, @intCast(@divTrunc(info.*.finfo.*.width, 8))), c.gst_buffer_get_size(buffer));
        _ = c.gst_buffer_remove_meta(buffer, @ptrCast(m));
        return null;
    }
    return m;
}

var audio_api: usize = 0;
var audio_tags = [_][*c]const u8{ "audio", "channels", "rate", null };

pub export fn gst_audio_meta_api_get_type() c.GType {
    return apiType(&audio_api, "GstAudioMetaAPI", &audio_tags);
}

var audio_info: usize = 0;

pub export fn gst_audio_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&audio_info, struct {
        fn f() [*c]const c.GstMetaInfo {
            const i = c.gst_meta_info_new(gst_audio_meta_api_get_type(), "GstAudioMeta", @sizeOf(AMeta));
            i.*.init_func = audioInit;
            i.*.free_func = audioFree;
            i.*.transform_func = audioTransform;
            i.*.serialize_func = audioSerialize;
            i.*.deserialize_func = audioDeserialize;
            return c.gst_meta_info_register(i);
        }
    }.f);
}

var level_api: usize = 0;
var level_tags = [_][*c]const u8{null};

pub export fn gst_audio_level_meta_api_get_type() c.GType {
    return apiType(&level_api, "GstAudioLevelMetaAPI", &level_tags);
}

fn levelInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const d: [*c]LMeta = @ptrCast(@alignCast(m));
    d.*.level = 127;
    d.*.voice_activity = 0;
    return 1;
}

fn levelTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    if (!isCopy(t)) return 0;
    const s: [*c]LMeta = @ptrCast(@alignCast(m));
    return @intFromBool(gst_buffer_add_audio_level_meta(dest, s.*.level, s.*.voice_activity) != null);
}

var level_info: usize = 0;

pub export fn gst_audio_level_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&level_info, struct {
        fn f() [*c]const c.GstMetaInfo {
            return c.gst_meta_register(gst_audio_level_meta_api_get_type(), "GstAudioLevelMeta", @sizeOf(LMeta), levelInit, null, levelTransform);
        }
    }.f);
}

pub export fn gst_buffer_add_audio_level_meta(buffer: [*c]Buffer, level: u8, voice_activity: c.gboolean) [*c]LMeta {
    if (!check.that(buffer != null, "gst_buffer_add_audio_level_meta", "buffer != NULL")) return null;
    const m: [*c]LMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(buffer, gst_audio_level_meta_get_info(), null)));
    if (m == null) return null;
    m.*.level = level;
    m.*.voice_activity = voice_activity;
    return m;
}

pub export fn gst_buffer_get_audio_level_meta(buffer: [*c]Buffer) [*c]LMeta {
    return @ptrCast(@alignCast(c.gst_buffer_get_meta(buffer, gst_audio_level_meta_api_get_type())));
}
