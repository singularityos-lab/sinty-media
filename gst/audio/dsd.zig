const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const channels = @import("channels.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Info = c.GstDsdInfo;
const Fmt = c.GstDsdFormat;
const PMeta = c.GstDsdPlaneOffsetMeta;
const NONE = @as(?*anyopaque, null);

const REVERSE = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = @bitReverse(@as(u8, i));
    break :blk t;
};

pub export fn gst_dsd_format_from_string(s: [*c]const u8) Fmt {
    if (c.g_strcmp0(s, "DSDU8") == 0) return c.GST_DSD_FORMAT_U8;
    if (c.g_strcmp0(s, "DSDU16LE") == 0) return c.GST_DSD_FORMAT_U16LE;
    if (c.g_strcmp0(s, "DSDU16BE") == 0) return c.GST_DSD_FORMAT_U16BE;
    if (c.g_strcmp0(s, "DSDU32LE") == 0) return c.GST_DSD_FORMAT_U32LE;
    if (c.g_strcmp0(s, "DSDU32BE") == 0) return c.GST_DSD_FORMAT_U32BE;
    return c.GST_DSD_FORMAT_UNKNOWN;
}

pub export fn gst_dsd_format_to_string(f: Fmt) [*c]const u8 {
    return switch (f) {
        c.GST_DSD_FORMAT_U8 => "DSDU8",
        c.GST_DSD_FORMAT_U16LE => "DSDU16LE",
        c.GST_DSD_FORMAT_U16BE => "DSDU16BE",
        c.GST_DSD_FORMAT_U32LE => "DSDU32LE",
        c.GST_DSD_FORMAT_U32BE => "DSDU32BE",
        else => null,
    };
}

pub export fn gst_dsd_format_get_width(f: Fmt) c.guint {
    return switch (f) {
        c.GST_DSD_FORMAT_U8 => 1,
        c.GST_DSD_FORMAT_U16LE, c.GST_DSD_FORMAT_U16BE => 2,
        c.GST_DSD_FORMAT_U32LE, c.GST_DSD_FORMAT_U32BE => 4,
        else => 0,
    };
}

fn isLe(f: Fmt) bool {
    return f == c.GST_DSD_FORMAT_U16LE or f == c.GST_DSD_FORMAT_U32LE;
}

fn pmetaInit(m: [*c]c.GstMeta, _: c.gpointer, _: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const p: [*c]PMeta = @ptrCast(@alignCast(m));
    p.*.offsets = null;
    return 1;
}

fn pmetaFree(m: [*c]c.GstMeta, _: [*c]c.GstBuffer) callconv(.c) void {
    const p: [*c]PMeta = @ptrCast(@alignCast(m));
    if (p.*.offsets != null and p.*.offsets != @as([*c]usize, @ptrCast(&p.*.priv_offsets_arr))) c.g_free(p.*.offsets);
}

fn pmetaTransform(dest: [*c]c.GstBuffer, m: [*c]c.GstMeta, _: [*c]c.GstBuffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    const s: [*c]PMeta = @ptrCast(@alignCast(m));
    if (t != c._gst_meta_transform_copy) return 0;
    return @intFromBool(gst_buffer_add_dsd_plane_offset_meta(dest, s.*.num_channels, s.*.num_bytes_per_channel, s.*.offsets) != null);
}

var api: usize = 0;
var tags = [_][*c]const u8{ "audio", "dsdplaneoffsets", null };

pub export fn gst_dsd_plane_offset_meta_api_get_type() c.GType {
    if (c.g_once_init_enter(&api) != 0) c.g_once_init_leave(&api, c.gst_meta_api_type_register("GstDsdPlaneOffsetMetaAPI", &tags));
    return api;
}

var meta_info: usize = 0;

pub export fn gst_dsd_plane_offset_meta_get_info() [*c]const c.GstMetaInfo {
    if (c.g_once_init_enter(&meta_info) != 0) c.g_once_init_leave(&meta_info, @intFromPtr(c.gst_meta_register(gst_dsd_plane_offset_meta_api_get_type(), "GstDsdPlaneOffsetMeta", @sizeOf(PMeta), pmetaInit, pmetaFree, pmetaTransform)));
    return @ptrFromInt(meta_info);
}

pub export fn gst_buffer_add_dsd_plane_offset_meta(buffer: [*c]c.GstBuffer, n_ch: c.gint, per: c_ulong, offsets: [*c]c_ulong) [*c]PMeta {
    const fname = "gst_buffer_add_dsd_plane_offset_meta";
    if (!check.that(buffer != null and @as(*c.GstMiniObject, @ptrCast(buffer)).type == c.gst_buffer_get_type(), fname, "GST_IS_BUFFER (buffer)")) return null;
    if (!check.that(n_ch >= 1, fname, "num_channels >= 1")) return null;
    if (!check.that(offsets == null or per >= 1, fname, "!offsets || (num_bytes_per_channel >= 1)")) return null;
    const m: [*c]PMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(buffer, gst_dsd_plane_offset_meta_get_info(), null)));
    const n: usize = @intCast(n_ch);
    m.*.num_channels = n_ch;
    m.*.num_bytes_per_channel = per;
    m.*.offsets = if (n > 8) @ptrCast(@alignCast(c.g_malloc(@sizeOf(usize) * n))) else @ptrCast(&m.*.priv_offsets_arr);
    if (offsets == null) return m;
    var max_offset: usize = 0;
    for (0..n) |i| {
        m.*.offsets[i] = offsets[i];
        max_offset = @max(max_offset, offsets[i]);
        for (0..n) |j| {
            if (i != j and !(offsets[j] +% per <= offsets[i] or offsets[i] +% per <= offsets[j])) {
                c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "GstDsdPlaneOffsetMeta properties would cause channel memory  areas to overlap! offsets: %lu (%d), %lu (%d) with %lu bytes per channel", offsets[i], @as(c_int, @intCast(i)), offsets[j], @as(c_int, @intCast(j)), per);
                _ = c.gst_buffer_remove_meta(buffer, @ptrCast(m));
                return null;
            }
        }
    }
    if (max_offset +% per > c.gst_buffer_get_size(buffer)) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "GstDsdPlaneOffsetMeta properties would cause out-of-bounds memory access on the buffer: max_offset %lu, %lu bytes per channel, buffer size %lu", max_offset, per, c.gst_buffer_get_size(buffer));
        _ = c.gst_buffer_remove_meta(buffer, @ptrCast(m));
        return null;
    }
    return m;
}

var type_once: gtype.Once = .{};

fn copyBoxed(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_dsd_info_copy(@ptrCast(@alignCast(p)));
}

fn freeBoxed(p: c.gpointer) callconv(.c) void {
    gst_dsd_info_free(@ptrCast(@alignCast(p)));
}

pub export fn gst_dsd_info_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstDsdInfo", copyBoxed, freeBoxed);
        }
    }.f);
}

pub export fn gst_dsd_info_new() [*c]Info {
    const info: [*c]Info = @ptrCast(@alignCast(c.g_slice_alloc(@sizeOf(Info))));
    gst_dsd_info_init(info);
    return info;
}

pub export fn gst_dsd_info_new_from_caps(caps: [*c]const c.GstCaps) [*c]Info {
    if (!check.that(caps != null, "gst_dsd_info_new_from_caps", "caps != NULL")) return null;
    const ret = gst_dsd_info_new();
    if (gst_dsd_info_from_caps(ret, caps) != 0) return ret;
    gst_dsd_info_free(ret);
    return null;
}

pub export fn gst_dsd_info_init(info: [*c]Info) void {
    if (!check.that(info != null, "gst_dsd_info_init", "info != NULL")) return;
    info.* = std.mem.zeroes(Info);
    info.*.format = c.GST_DSD_FORMAT_UNKNOWN;
}

pub export fn gst_dsd_info_set_format(info: [*c]Info, f: Fmt, rate: c.gint, chans: c.gint, positions: [*c]const c.GstAudioChannelPosition) void {
    const fname = "gst_dsd_info_set_format";
    if (!check.that(info != null, fname, "info != NULL")) return;
    if (!check.that(f != c.GST_DSD_FORMAT_UNKNOWN, fname, "format != GST_DSD_FORMAT_UNKNOWN")) return;
    if (!check.that(chans <= 64 or positions == null, fname, "channels <= 64 || positions == NULL")) return;
    gst_dsd_info_init(info);
    info.*.format = f;
    info.*.rate = rate;
    info.*.channels = chans;
    info.*.layout = c.GST_AUDIO_LAYOUT_INTERLEAVED;
    info.*.flags = c.GST_AUDIO_FLAG_NONE;
    for (&info[0].positions) |*x| x.* = -1;
    if (positions == null and chans == 1) {
        info[0].positions[0] = c.GST_AUDIO_CHANNEL_POSITION_MONO;
        return;
    } else if (positions == null and chans == 2) {
        info[0].positions[0] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;
        info[0].positions[1] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT;
        return;
    } else if (positions == null or !channels.validate(positions, chans, true, null)) {
        if (positions != null) c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Invalid channel positions");
    } else {
        const n: usize = @intCast(@max(chans, 0));
        const dst: [*]c.GstAudioChannelPosition = @ptrCast(&info[0].positions);
        @memcpy(dst[0..n], positions[0..n]);
        if (info[0].positions[0] == c.GST_AUDIO_CHANNEL_POSITION_NONE) info.*.flags |= c.GST_AUDIO_FLAG_UNPOSITIONED;
        return;
    }
    info.*.flags |= c.GST_AUDIO_FLAG_UNPOSITIONED;
    var i: usize = 0;
    while (i < @min(64, chans)) : (i += 1) info[0].positions[i] = c.GST_AUDIO_CHANNEL_POSITION_NONE;
}

pub export fn gst_dsd_info_copy(info: [*c]const Info) [*c]Info {
    return @ptrCast(@alignCast(c.g_slice_copy(@sizeOf(Info), info)));
}

pub export fn gst_dsd_info_free(info: [*c]Info) void {
    c.g_slice_free1(@sizeOf(Info), info);
}

pub export fn gst_dsd_info_from_caps(info: [*c]Info, caps: [*c]const c.GstCaps) c.gboolean {
    const fname = "gst_dsd_info_from_caps";
    if (!check.that(info != null, fname, "info != NULL")) return 0;
    if (!check.that(caps != null, fname, "caps != NULL")) return 0;
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, fname, "gst_caps_is_fixed (caps)")) return 0;
    const st = c.gst_caps_get_structure(caps, 0);
    if (!check.that(c.g_strcmp0(c.gst_structure_get_name(st), "audio/x-dsd") == 0, fname, "g_strcmp0 (media_type, GST_DSD_MEDIA_TYPE) == 0")) return 0;
    var flags: c.GstAudioFlags = c.GST_AUDIO_FLAG_NONE;
    var mask: u64 = 0;
    const fs = c.gst_structure_get_string(st, "format");
    if (fs == null) return 0;
    info.*.format = gst_dsd_format_from_string(fs);
    if (info.*.format == c.GST_DSD_FORMAT_UNKNOWN) return 0;
    if (c.gst_structure_get_int(st, "rate", &info.*.rate) == 0) return 0;
    if (info.*.rate < 1) return 0;
    if (c.gst_structure_get_int(st, "channels", &info.*.channels) == 0) return 0;
    if (info.*.channels < 1) return 0;
    if (c.gst_structure_get(st, "channel-mask", c.gst_bitmask_get_type(), &mask, NONE) == 0 or (mask == 0 and info.*.channels == 1)) {
        switch (info.*.channels) {
            1 => info[0].positions[0] = c.GST_AUDIO_CHANNEL_POSITION_MONO,
            2 => {
                info[0].positions[0] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;
                info[0].positions[1] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT;
            },
            else => return 0,
        }
    } else if (mask == 0) {
        flags |= c.GST_AUDIO_FLAG_UNPOSITIONED;
        var i: usize = 0;
        while (i < @min(64, info.*.channels)) : (i += 1) info[0].positions[i] = c.GST_AUDIO_CHANNEL_POSITION_NONE;
    } else if (channels.gst_audio_channel_positions_from_mask(info.*.channels, mask, @ptrCast(&info[0].positions)) == 0) return 0;
    const ls = c.gst_structure_get_string(st, "layout");
    if (ls == null or c.g_strcmp0(ls, "interleaved") == 0) {
        info.*.layout = c.GST_AUDIO_LAYOUT_INTERLEAVED;
    } else if (c.g_strcmp0(ls, "non-interleaved") == 0) {
        info.*.layout = c.GST_AUDIO_LAYOUT_NON_INTERLEAVED;
    } else return 0;
    var reversed: c.gboolean = 0;
    _ = c.gst_structure_get(st, "reversed-bytes", c.G_TYPE_BOOLEAN, &reversed, NONE);
    info.*.flags = flags;
    info.*.reversed_bytes = reversed;
    return 1;
}

fn layoutString(l: c.GstAudioLayout) [*c]const u8 {
    return switch (l) {
        c.GST_AUDIO_LAYOUT_INTERLEAVED => "interleaved",
        c.GST_AUDIO_LAYOUT_NON_INTERLEAVED => "non-interleaved",
        else => {
            check.reached("gstdsd.c", 96, "layout_to_string");
            return null;
        },
    };
}

pub export fn gst_dsd_info_to_caps(info: [*c]const Info) [*c]c.GstCaps {
    const fname = "gst_dsd_info_to_caps";
    if (!check.that(info != null, fname, "info != NULL")) return null;
    if (!check.that(info.*.format > c.GST_DSD_FORMAT_UNKNOWN and info.*.format < c.GST_NUM_DSD_FORMATS, fname, "info->format > GST_DSD_FORMAT_UNKNOWN && info->format < GST_NUM_DSD_FORMATS")) return null;
    if (!check.that(info.*.rate >= 1, fname, "info->rate >= 1")) return null;
    if (!check.that(info.*.channels >= 1, fname, "info->channels >= 1")) return null;
    const fs = gst_dsd_format_to_string(info.*.format);
    if (!check.that(fs != null, fname, "format != NULL")) return null;
    var flags = info.*.flags;
    if (flags & c.GST_AUDIO_FLAG_UNPOSITIONED != 0 and info.*.channels > 1 and info[0].positions[0] != c.GST_AUDIO_CHANNEL_POSITION_NONE) {
        flags &= ~@as(c.GstAudioFlags, c.GST_AUDIO_FLAG_UNPOSITIONED);
    } else if (flags & c.GST_AUDIO_FLAG_UNPOSITIONED == 0 and info.*.channels > 1 and info[0].positions[0] == c.GST_AUDIO_CHANNEL_POSITION_NONE) {
        flags |= c.GST_AUDIO_FLAG_UNPOSITIONED;
    }
    const caps = c.gst_caps_new_simple("audio/x-dsd", "format", c.G_TYPE_STRING, fs, "rate", c.G_TYPE_INT, info.*.rate, "channels", c.G_TYPE_INT, info.*.channels, "layout", c.G_TYPE_STRING, layoutString(info.*.layout), "reversed-bytes", c.G_TYPE_BOOLEAN, info.*.reversed_bytes, NONE);
    if (info.*.channels > 1 or info[0].positions[0] != c.GST_AUDIO_CHANNEL_POSITION_MONO) {
        var mask: u64 = 0;
        if (flags & c.GST_AUDIO_FLAG_UNPOSITIONED == 0 and !channels.validate(@ptrCast(&info[0].positions), info.*.channels, true, &mask)) {
            c.gst_mini_object_unref(@ptrCast(caps));
            return null;
        }
        if (!(info.*.channels == 1 and info[0].positions[0] == c.GST_AUDIO_CHANNEL_POSITION_MONO)) c.gst_caps_set_simple(caps, "channel-mask", c.gst_bitmask_get_type(), mask, NONE);
    }
    return caps;
}

pub export fn gst_dsd_info_is_equal(info: [*c]const Info, other: [*c]const Info) c.gboolean {
    if (info == other) return 1;
    if (info.*.format != other.*.format or info.*.rate != other.*.rate or info.*.channels != other.*.channels or info.*.layout != other.*.layout or info.*.reversed_bytes != other.*.reversed_bytes) return 0;
    const n: usize = @as(usize, @intCast(@max(info.*.channels, 0))) * @sizeOf(c.GstAudioChannelPosition);
    const a: [*]const u8 = @ptrCast(&info[0].positions);
    const b: [*]const u8 = @ptrCast(&other[0].positions);
    return @intFromBool(std.mem.eql(u8, a[0..n], b[0..n]));
}

fn rev(b: u8, reverse: bool) u8 {
    return if (reverse) REVERSE[b] else b;
}

fn copySame(in: [*c]const u8, out: [*c]u8, n: usize, reverse: bool) void {
    if (reverse) {
        for (0..n) |i| out[i] = REVERSE[in[i]];
    } else @memcpy(out[0..n], in[0..n]);
}

pub export fn gst_dsd_convert(in: [*c]const u8, out: [*c]u8, in_fmt: Fmt, out_fmt: Fmt, in_layout: c.GstAudioLayout, out_layout: c.GstAudioLayout, in_offs: [*c]const c_ulong, out_offs: [*c]const c_ulong, n_bytes: c_ulong, n_ch: c.gint, reverse_g: c.gboolean) void {
    const fname = "gst_dsd_convert";
    if (!check.that(in != null, fname, "input_data != NULL")) return;
    if (!check.that(out != null, fname, "output_data != NULL")) return;
    if (!check.that(in_fmt > c.GST_DSD_FORMAT_UNKNOWN and in_fmt < c.GST_NUM_DSD_FORMATS, fname, "input_format > GST_DSD_FORMAT_UNKNOWN && input_format < GST_NUM_DSD_FORMATS")) return;
    if (!check.that(out_fmt > c.GST_DSD_FORMAT_UNKNOWN and out_fmt < c.GST_NUM_DSD_FORMATS, fname, "output_format > GST_DSD_FORMAT_UNKNOWN && output_format < GST_NUM_DSD_FORMATS")) return;
    if (!check.that(in_layout == c.GST_AUDIO_LAYOUT_INTERLEAVED or in_offs != null, fname, "input_layout == GST_AUDIO_LAYOUT_INTERLEAVED || input_plane_offsets != NULL")) return;
    if (!check.that(out_layout == c.GST_AUDIO_LAYOUT_INTERLEAVED or out_offs != null, fname, "output_layout == GST_AUDIO_LAYOUT_INTERLEAVED || output_plane_offsets != NULL")) return;
    if (!check.that(n_bytes > 0, fname, "num_dsd_bytes > 0")) return;
    if (!check.that(n_bytes % gst_dsd_format_get_width(in_fmt) == 0, fname, "(num_dsd_bytes % gst_dsd_format_get_width (input_format)) == 0")) return;
    if (!check.that(n_bytes % gst_dsd_format_get_width(out_fmt) == 0, fname, "(num_dsd_bytes % gst_dsd_format_get_width (output_format)) == 0")) return;
    if (!check.that(n_ch > 0, fname, "num_channels > 0")) return;
    const reverse = reverse_g != 0;
    const iw: c.guint = gst_dsd_format_get_width(in_fmt);
    const ow: c.guint = gst_dsd_format_get_width(out_fmt);
    const ile = isLe(in_fmt);
    const ole = isLe(out_fmt);
    const nch: c.guint = @intCast(n_ch);
    const n: c.guint = @truncate(n_bytes);
    const per: usize = n_bytes / nch;
    const in_inter = in_layout == c.GST_AUDIO_LAYOUT_INTERLEAVED;
    const out_inter = out_layout == c.GST_AUDIO_LAYOUT_INTERLEAVED;
    if (out_inter) {
        if (in_inter and in_fmt == out_fmt) return copySame(in, out, n_bytes, reverse);
        const stride = ow * nch;
        var oi: c.guint = 0;
        while (oi < n) : (oi += 1) {
            const owi = oi / ow;
            var owo = oi % ow;
            if (ole) owo = ow - 1 - owo;
            const ch = owi % nch;
            const pos = (oi / stride) * ow + owo;
            var iwo = pos % iw;
            if (ile) iwo = iw - 1 - iwo;
            const ii: usize = if (in_inter) ((pos / iw) * nch + ch) * iw + iwo else @as(usize, @truncate(in_offs[ch] +% (pos / iw) * iw + iwo));
            out[oi] = rev(in[ii], reverse);
        }
        return;
    }
    if (!in_inter) {
        const same_offs = std.mem.eql(c_ulong, in_offs[0..nch], out_offs[0..nch]);
        if (in_fmt == out_fmt and same_offs) return copySame(in, out, n_bytes, reverse);
        if (in_fmt == out_fmt) {
            for (0..nch) |ch| {
                if (reverse) {
                    var p: c.guint = 0;
                    while (p < per) : (p += 1) {
                        const ii: c.guint = @truncate(in_offs[ch] +% p);
                        const oi: c.guint = @truncate(out_offs[ch] +% p);
                        out[oi] = REVERSE[in[ii]];
                    }
                } else @memcpy(out[out_offs[ch]..][0..per], in[in_offs[ch]..][0..per]);
            }
            return;
        }
    }
    var ch: c.guint = 0;
    while (ch < nch) : (ch += 1) {
        var p: c.guint = 0;
        while (p < per) : (p += 1) {
            const owi = p / ow;
            var owo = p % ow;
            if (ole) owo = ow - 1 - owo;
            var iwo = p % iw;
            if (ile) iwo = iw - 1 - iwo;
            const ii: c.guint = if (in_inter) ((p / iw) * nch + ch) * iw + iwo else @truncate(in_offs[ch] +% (p / iw) * iw + iwo);
            const oi: c.guint = @truncate(out_offs[ch] +% owi * ow + owo);
            out[oi] = rev(in[ii], reverse);
        }
    }
}
