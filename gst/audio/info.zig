const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const format = @import("format.zig");
const channels = @import("channels.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Info = c.GstAudioInfo;
const Pos = c.GstAudioChannelPosition;
const NONE = @as(?*anyopaque, null);

var type_once: gtype.Once = .{};

pub export fn gst_audio_info_copy(info: [*c]const Info) [*c]Info {
    return @ptrCast(@alignCast(c.g_memdup2(info, @sizeOf(Info))));
}

pub export fn gst_audio_info_free(info: [*c]Info) void {
    c.g_free(info);
}

fn copyBoxed(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_audio_info_copy(@ptrCast(@alignCast(p)));
}

fn freeBoxed(p: c.gpointer) callconv(.c) void {
    gst_audio_info_free(@ptrCast(@alignCast(p)));
}

pub export fn gst_audio_info_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstAudioInfo", copyBoxed, freeBoxed);
        }
    }.f);
}

pub export fn gst_audio_info_new() [*c]Info {
    const info: [*c]Info = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Info))));
    gst_audio_info_init(info);
    return info;
}

pub export fn gst_audio_info_init(info: [*c]Info) void {
    if (!check.that(info != null, "gst_audio_info_init", "info != NULL")) return;
    info.* = std.mem.zeroes(Info);
    info.*.finfo = format.gst_audio_format_get_info(c.GST_AUDIO_FORMAT_UNKNOWN);
}

pub export fn gst_audio_info_set_format(info: [*c]Info, fmt: c.GstAudioFormat, rate: c.gint, chans: c.gint, position: [*c]const Pos) void {
    const fname = "gst_audio_info_set_format";
    if (!check.that(info != null, fname, "info != NULL")) return;
    if (!check.that(fmt != c.GST_AUDIO_FORMAT_UNKNOWN, fname, "format != GST_AUDIO_FORMAT_UNKNOWN")) return;
    if (!check.that(chans <= 64 or position == null, fname, "channels <= 64 || position == NULL")) return;
    gst_audio_info_init(info);
    const finfo = format.gst_audio_format_get_info(fmt);
    info.*.flags = 0;
    info.*.layout = c.GST_AUDIO_LAYOUT_INTERLEAVED;
    info.*.finfo = finfo;
    info.*.rate = rate;
    info.*.channels = chans;
    info.*.bpf = @divTrunc(finfo.*.width * chans, 8);
    for (&info[0].position) |*x| x.* = -1;
    if (position == null and chans == 1) {
        info[0].position[0] = c.GST_AUDIO_CHANNEL_POSITION_MONO;
        return;
    } else if (position == null and chans == 2) {
        info[0].position[0] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;
        info[0].position[1] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT;
        return;
    } else if (position == null or !channels.validate(position, chans, true, null)) {
        if (position != null) c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Invalid channel positions");
    } else {
        const n: usize = @intCast(@max(chans, 0));
        @memcpy(info[0].position[0..n], position[0..n]);
        if (info[0].position[0] == c.GST_AUDIO_CHANNEL_POSITION_NONE) info.*.flags |= c.GST_AUDIO_FLAG_UNPOSITIONED;
        return;
    }
    info.*.flags |= c.GST_AUDIO_FLAG_UNPOSITIONED;
    var i: usize = 0;
    while (i < @min(64, chans)) : (i += 1) info[0].position[i] = c.GST_AUDIO_CHANNEL_POSITION_NONE;
}

pub export fn gst_audio_info_from_caps(info: [*c]Info, caps: [*c]const c.GstCaps) c.gboolean {
    const fname = "gst_audio_info_from_caps";
    if (!check.that(info != null, fname, "info != NULL")) return 0;
    if (!check.that(caps != null, fname, "caps != NULL")) return 0;
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, fname, "gst_caps_is_fixed (caps)")) return 0;
    var flags: c.GstAudioFlags = 0;
    var fmt: c.GstAudioFormat = c.GST_AUDIO_FORMAT_UNKNOWN;
    var layout: c.GstAudioLayout = c.GST_AUDIO_LAYOUT_INTERLEAVED;
    var rate: c.gint = 0;
    var chans: c.gint = 0;
    var mask: u64 = 0;
    var position: [64]Pos = undefined;
    const str = c.gst_caps_get_structure(caps, 0);
    if (c.gst_structure_has_name(str, "audio/x-raw") != 0) {
        const s = c.gst_structure_get_string(str, "format");
        if (s == null) return 0;
        fmt = format.gst_audio_format_from_string(s);
        if (fmt == c.GST_AUDIO_FORMAT_UNKNOWN) return 0;
    } else if (c.g_str_has_prefix(c.gst_structure_get_name(str), "audio/") != 0) {
        fmt = c.GST_AUDIO_FORMAT_ENCODED;
    } else return 0;
    if (fmt != c.GST_AUDIO_FORMAT_ENCODED) {
        const s = c.gst_structure_get_string(str, "layout");
        if (s == null) return 0;
        if (c.g_str_equal(s, "interleaved") != 0) {
            layout = c.GST_AUDIO_LAYOUT_INTERLEAVED;
        } else if (c.g_str_equal(s, "non-interleaved") != 0) {
            layout = c.GST_AUDIO_LAYOUT_NON_INTERLEAVED;
        } else return 0;
    }
    if (c.gst_structure_get_int(str, "rate", &rate) == 0 and fmt != c.GST_AUDIO_FORMAT_ENCODED) return 0;
    if (c.gst_structure_get_int(str, "channels", &chans) == 0 and fmt != c.GST_AUDIO_FORMAT_ENCODED) return 0;
    if (c.gst_structure_get(str, "channel-mask", c.gst_bitmask_get_type(), &mask, NONE) == 0 or (mask == 0 and chans == 1)) {
        if (chans == 1) {
            position[0] = c.GST_AUDIO_CHANNEL_POSITION_MONO;
        } else if (chans == 2) {
            position[0] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT;
            position[1] = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT;
        } else if (fmt != c.GST_AUDIO_FORMAT_ENCODED) return 0;
    } else if (mask == 0) {
        flags |= c.GST_AUDIO_FLAG_UNPOSITIONED;
        var i: usize = 0;
        while (i < @min(64, chans)) : (i += 1) position[i] = c.GST_AUDIO_CHANNEL_POSITION_NONE;
    } else if (channels.gst_audio_channel_positions_from_mask(chans, mask, &position) == 0) return 0;
    gst_audio_info_set_format(info, fmt, rate, chans, if (chans > 64) null else &position);
    info.*.flags = flags;
    info.*.layout = layout;
    return 1;
}

pub export fn gst_audio_info_new_from_caps(caps: [*c]const c.GstCaps) [*c]Info {
    const ret = gst_audio_info_new();
    if (gst_audio_info_from_caps(ret, caps) != 0) return ret;
    gst_audio_info_free(ret);
    return null;
}

pub export fn gst_audio_info_to_caps(info: [*c]const Info) [*c]c.GstCaps {
    const fname = "gst_audio_info_to_caps";
    if (!check.that(info != null, fname, "info != NULL")) return null;
    if (!check.that(info.*.finfo != null, fname, "info->finfo != NULL")) return null;
    if (!check.that(info.*.finfo.*.format != c.GST_AUDIO_FORMAT_UNKNOWN, fname, "info->finfo->format != GST_AUDIO_FORMAT_UNKNOWN")) return null;
    const fmt = format.gst_audio_format_to_string(info.*.finfo.*.format);
    if (!check.that(fmt != null, fname, "format != NULL")) return null;
    const layout: [*c]const u8 = switch (info.*.layout) {
        c.GST_AUDIO_LAYOUT_INTERLEAVED => "interleaved",
        c.GST_AUDIO_LAYOUT_NON_INTERLEAVED => "non-interleaved",
        else => {
            check.reached("audio-info.c", 374, fname);
            return null;
        },
    };
    var flags = info.*.flags;
    if (flags & c.GST_AUDIO_FLAG_UNPOSITIONED != 0 and info.*.channels > 1 and info[0].position[0] != c.GST_AUDIO_CHANNEL_POSITION_NONE) {
        flags &= ~@as(c.GstAudioFlags, c.GST_AUDIO_FLAG_UNPOSITIONED);
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Unpositioned audio channel position flag set but channel positions present");
    } else if (flags & c.GST_AUDIO_FLAG_UNPOSITIONED == 0 and info.*.channels > 1 and info[0].position[0] == c.GST_AUDIO_CHANNEL_POSITION_NONE) {
        flags |= c.GST_AUDIO_FLAG_UNPOSITIONED;
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Unpositioned audio channel position flag not set but no channel positions present");
    }
    const caps = c.gst_caps_new_static_str_simple("audio/x-raw", "format", c.G_TYPE_STRING, fmt, "layout", c.G_TYPE_STRING, layout, "rate", c.G_TYPE_INT, info.*.rate, "channels", c.G_TYPE_INT, info.*.channels, NONE);
    if (info.*.channels > 1 or info[0].position[0] != c.GST_AUDIO_CHANNEL_POSITION_MONO) {
        var mask: u64 = 0;
        if (flags & c.GST_AUDIO_FLAG_UNPOSITIONED == 0) {
            if (!channels.validate(@ptrCast(&info[0].position), info.*.channels, true, &mask)) {
                c.gst_mini_object_unref(@ptrCast(caps));
                return null;
            }
        }
        if (!(info.*.channels == 1 and info[0].position[0] == c.GST_AUDIO_CHANNEL_POSITION_MONO)) c.gst_caps_set_simple_static_str(caps, "channel-mask", c.gst_bitmask_get_type(), mask, NONE);
    }
    return caps;
}

fn framesToTime(frames: u64, rate: c.gint) i64 {
    return @bitCast(c.gst_util_uint64_scale_round(frames, c.GST_SECOND, @intCast(rate)));
}

pub export fn gst_audio_info_convert(info: [*c]const Info, src_fmt: c.GstFormat, src_val: c_long, dest_fmt: c.GstFormat, dest_val: [*c]c_long) c.gboolean {
    if (src_fmt == dest_fmt or src_val == -1) {
        dest_val.* = src_val;
        return 1;
    }
    const bpf = info.*.bpf;
    const rate = info.*.rate;
    if (bpf == 0 or rate == 0) return 0;
    switch (src_fmt) {
        c.GST_FORMAT_BYTES => switch (dest_fmt) {
            c.GST_FORMAT_TIME => dest_val.* = framesToTime(@bitCast(@divTrunc(src_val, bpf)), rate),
            c.GST_FORMAT_DEFAULT => dest_val.* = @divTrunc(src_val, bpf),
            else => return 0,
        },
        c.GST_FORMAT_DEFAULT => switch (dest_fmt) {
            c.GST_FORMAT_TIME => dest_val.* = framesToTime(@bitCast(src_val), rate),
            c.GST_FORMAT_BYTES => dest_val.* = src_val *% bpf,
            else => return 0,
        },
        c.GST_FORMAT_TIME => switch (dest_fmt) {
            c.GST_FORMAT_DEFAULT => dest_val.* = @bitCast(c.gst_util_uint64_scale_round(@bitCast(src_val), @intCast(rate), c.GST_SECOND)),
            c.GST_FORMAT_BYTES => dest_val.* = @as(i64, @bitCast(c.gst_util_uint64_scale_round(@bitCast(src_val), @intCast(rate), c.GST_SECOND))) *% bpf,
            else => return 0,
        },
        else => return 0,
    }
    return 1;
}

pub export fn gst_audio_info_is_equal(info: [*c]const Info, other: [*c]const Info) c.gboolean {
    if (info == other) return 1;
    if (info.*.finfo == null or other.*.finfo == null) return 0;
    if (info.*.finfo.*.format != other.*.finfo.*.format) return 0;
    if (info.*.flags != other.*.flags) return 0;
    if (info.*.layout != other.*.layout) return 0;
    if (info.*.rate != other.*.rate) return 0;
    if (info.*.channels != other.*.channels) return 0;
    if (info.*.channels > 64) return 1;
    const n: usize = @intCast(@max(info.*.channels, 0));
    const a: [*]const Pos = @ptrCast(&info[0].position);
    const b: [*]const Pos = @ptrCast(&other[0].position);
    return @intFromBool(std.mem.eql(Pos, a[0..n], b[0..n]));
}
