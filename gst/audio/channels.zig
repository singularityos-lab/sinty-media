const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const format = @import("format.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Pos = c.GstAudioChannelPosition;
const INVALID = c.GST_AUDIO_CHANNEL_POSITION_INVALID;
const MONO = c.GST_AUDIO_CHANNEL_POSITION_MONO;
const NONE = c.GST_AUDIO_CHANNEL_POSITION_NONE;

fn p(comptime name: []const u8) Pos {
    return @field(c, "GST_AUDIO_CHANNEL_POSITION_" ++ name);
}

const ORDER = [_]Pos{ p("FRONT_LEFT"), p("FRONT_RIGHT"), p("FRONT_CENTER"), p("LFE1"), p("REAR_LEFT"), p("REAR_RIGHT"), p("FRONT_LEFT_OF_CENTER"), p("FRONT_RIGHT_OF_CENTER"), p("REAR_CENTER"), p("LFE2"), p("SIDE_LEFT"), p("SIDE_RIGHT"), p("TOP_FRONT_LEFT"), p("TOP_FRONT_RIGHT"), p("TOP_FRONT_CENTER"), p("TOP_CENTER"), p("TOP_REAR_LEFT"), p("TOP_REAR_RIGHT"), p("TOP_SIDE_LEFT"), p("TOP_SIDE_RIGHT"), p("TOP_REAR_CENTER"), p("BOTTOM_FRONT_CENTER"), p("BOTTOM_FRONT_LEFT"), p("BOTTOM_FRONT_RIGHT"), p("WIDE_LEFT"), p("WIDE_RIGHT"), p("SURROUND_LEFT"), p("SURROUND_RIGHT") } ++ [_]Pos{INVALID} ** 36;

fn bit(pos: Pos) u64 {
    return @as(u64, 1) << @truncate(@as(u32, @bitCast(pos)));
}

fn equal(a: [*c]const Pos, b: [*c]const Pos, channels: c.gint) bool {
    const n: usize = @intCast(@max(channels, 0));
    return std.mem.eql(u8, std.mem.sliceAsBytes(a[0..n]), std.mem.sliceAsBytes(b[0..n]));
}

pub fn validate(position: [*c]const Pos, channels: c.gint, enforce: bool, mask_out: ?*u64) bool {
    if (channels == 1 and position[0] == MONO) {
        if (mask_out) |mo| mo.* = 0;
        return true;
    }
    if (channels > 0 and position[0] == NONE) {
        if (mask_out) |mo| mo.* = 0;
        return true;
    }
    var mask: u64 = 0;
    var j: usize = 0;
    var i: usize = 0;
    while (i < channels) : (i += 1) {
        while (j < ORDER.len and ORDER[j] != position[i]) j += 1;
        if (position[i] == INVALID or position[i] == MONO or position[i] == NONE) return false;
        if (enforce and j == ORDER.len) return false;
        j += 1;
        if (mask & bit(position[i]) != 0) return false;
        mask |= bit(position[i]);
    }
    if (mask_out) |mo| mo.* = mask;
    return true;
}

pub export fn gst_audio_reorder_channels_with_reorder_map(data: c.gpointer, size: c_ulong, bps: c.gint, channels: c.gint, map: [*c]const c.gint) void {
    const fname = "gst_audio_reorder_channels_with_reorder_map";
    const bpf = bps * channels;
    if (!check.that(data != null, fname, "data != NULL")) return;
    if (!check.that(size % @as(usize, @intCast(bps * channels)) == 0, fname, "size % (bps * channels) == 0")) return;
    if (!check.that(bps > 0, fname, "bps > 0")) return;
    if (!check.that(bps <= 64, fname, "bps <= 64")) return;
    if (!check.that(channels > 0, fname, "channels > 0")) return;
    if (!check.that(channels <= 64, fname, "channels <= 64")) return;
    if (!check.that(map != null, fname, "reorder_map != NULL")) return;
    const ubpf: usize = @intCast(bpf);
    const ubps: usize = @intCast(bps);
    var ptr: [*]u8 = @ptrCast(data);
    const n = size / ubpf;
    var tmp: [64 * 8]u8 = undefined;
    for (0..n) |_| {
        @memcpy(tmp[0..ubpf], ptr[0..ubpf]);
        for (0..@intCast(channels)) |j| @memcpy(ptr[@as(usize, @intCast(map[j])) * ubps ..][0..ubps], tmp[j * ubps ..][0..ubps]);
        ptr += ubpf;
    }
}

pub export fn gst_audio_reorder_channels(data: c.gpointer, size: c_ulong, fmt: c.GstAudioFormat, channels: c.gint, from: [*c]const Pos, to: [*c]const Pos) c.gboolean {
    const fname = "gst_audio_reorder_channels";
    const info = format.gst_audio_format_get_info(fmt);
    if (!check.that(data != null, fname, "data != NULL")) return 0;
    if (!check.that(from != null, fname, "from != NULL")) return 0;
    if (!check.that(to != null, fname, "to != NULL")) return 0;
    if (!check.that(info != null and info.*.width > 0, fname, "info != NULL && info->width > 0")) return 0;
    if (!check.that(info.*.width > 0, fname, "info->width > 0")) return 0;
    if (!check.that(info.*.width <= 8 * 64, fname, "info->width <= 8 * 64")) return 0;
    const frame: usize = @intCast(@divTrunc(info.*.width * channels, 8));
    if (!check.that(size % frame == 0, fname, "size % ((info->width * channels) / 8) == 0")) return 0;
    if (!check.that(channels > 0, fname, "channels > 0")) return 0;
    if (size == 0) return 1;
    if (equal(from, to, channels)) return 1;
    if (!check.that(channels <= 64, fname, "channels <= 64")) return 0;
    var map = [_]c.gint{0} ** 64;
    if (gst_audio_get_channel_reorder_map(channels, from, to, &map) == 0) return 0;
    gst_audio_reorder_channels_with_reorder_map(data, size, @divTrunc(info.*.width, 8), channels, &map);
    return 1;
}

fn metaReorder(meta: [*c]c.GstAudioMeta, from: [*c]const Pos, to: [*c]const Pos) bool {
    const fname = "gst_audio_meta_reorder_channels";
    if (!check.that(meta != null, fname, "meta")) return false;
    if (!check.that(meta.*.info.channels > 0, fname, "meta->info.channels > 0")) return false;
    if (!check.that(meta.*.info.channels <= 64, fname, "meta->info.channels <= 64")) return false;
    if (!check.that(meta.*.offsets != null, fname, "meta->offsets != NULL")) return false;
    var map = [_]c.gint{0} ** 64;
    if (gst_audio_get_channel_reorder_map(meta.*.info.channels, from, to, &map) == 0) return false;
    const n: usize = @intCast(meta.*.info.channels);
    var tmp = [_]usize{0} ** 64;
    @memcpy(tmp[0..n], meta.*.offsets[0..n]);
    for (0..n) |i| meta.*.offsets[@intCast(map[i])] = tmp[i];
    return true;
}

pub fn audioMeta(b: [*c]c.GstBuffer) [*c]c.GstAudioMeta {
    return @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_meta_api_get_type())));
}

pub export fn gst_audio_buffer_reorder_channels(buffer: [*c]c.GstBuffer, fmt: c.GstAudioFormat, channels: c.gint, from: [*c]const Pos, to: [*c]const Pos) c.gboolean {
    const fname = "gst_audio_buffer_reorder_channels";
    if (!check.that(buffer != null and @as(*c.GstMiniObject, @ptrCast(buffer)).type == c.gst_buffer_get_type(), fname, "GST_IS_BUFFER (buffer)")) return 0;
    if (!check.that(c.gst_mini_object_is_writable(@ptrCast(buffer)) != 0, fname, "gst_buffer_is_writable (buffer)")) return 0;
    if (equal(from, to, channels)) return 1;
    const meta = audioMeta(buffer);
    if (meta != null and meta.*.info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) {
        if (!check.that(channels == meta.*.info.channels, fname, "channels == meta->info.channels")) return 0;
        return @intFromBool(metaReorder(meta, from, to));
    }
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buffer, &info, c.GST_MAP_READWRITE) == 0) return 0;
    const ret = gst_audio_reorder_channels(info.data, info.size, fmt, channels, from, to);
    c.gst_buffer_unmap(buffer, &info);
    return ret;
}

pub export fn gst_audio_check_valid_channel_positions(position: [*c]const Pos, channels: c.gint, force_order: c.gboolean) c.gboolean {
    return @intFromBool(validate(position, channels, force_order != 0, null));
}

pub export fn gst_audio_channel_positions_to_mask(position: [*c]const Pos, channels: c.gint, force_order: c.gboolean, mask: [*c]c_ulong) c.gboolean {
    return @intFromBool(validate(position, channels, force_order != 0, if (mask != null) @ptrCast(mask) else null));
}

pub export fn gst_audio_channel_positions_from_mask(channels: c.gint, mask: c_ulong, position: [*c]Pos) c.gboolean {
    const fname = "gst_audio_channel_positions_from_mask";
    if (!check.that(position != null, fname, "position != NULL")) return 0;
    if (!check.that(channels != 0, fname, "channels != 0")) return 0;
    if (mask == 0) {
        if (channels == 1) {
            position[0] = MONO;
        } else if (channels == 2) {
            position[0] = p("FRONT_LEFT");
            position[1] = p("FRONT_RIGHT");
        } else return 0;
        return 1;
    }
    var j: c.gint = 0;
    for (0..64) |i| {
        if (mask & (@as(u64, 1) << @intCast(i)) != 0) {
            if (j < channels) position[@intCast(j)] = ORDER[i];
            j += 1;
        }
    }
    return 1;
}

pub export fn gst_audio_get_channel_reorder_map(channels: c.gint, from: [*c]const Pos, to: [*c]const Pos, map: [*c]c.gint) c.gboolean {
    const fname = "gst_audio_get_channel_reorder_map";
    if (!check.that(map != null, fname, "reorder_map != NULL")) return 0;
    if (!check.that(channels > 0, fname, "channels > 0")) return 0;
    if (!check.that(channels <= 64, fname, "channels <= 64")) return 0;
    if (!check.that(from != null, fname, "from != NULL")) return 0;
    if (!check.that(to != null, fname, "to != NULL")) return 0;
    if (!check.that(validate(from, channels, false, null), fname, "check_valid_channel_positions (from, channels, FALSE, NULL)")) return 0;
    if (!check.that(validate(to, channels, false, null), fname, "check_valid_channel_positions (to, channels, FALSE, NULL)")) return 0;
    const n: usize = @intCast(channels);
    for (0..n) |i| {
        if (from[i] == NONE or to[i] == NONE) return 0;
        if (from[i] == INVALID or to[i] == INVALID) return 0;
        if (from[i] == MONO or to[i] == MONO) return 0;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (from[i] == to[j]) {
                map[i] = @intCast(j);
                break;
            }
        }
        if (j == n) return 0;
    }
    return 1;
}

pub export fn gst_audio_channel_positions_to_valid_order(position: [*c]Pos, channels: c.gint) c.gboolean {
    const fname = "gst_audio_channel_positions_to_valid_order";
    if (!check.that(channels > 0, fname, "channels > 0")) return 0;
    if (!check.that(position != null, fname, "position != NULL")) return 0;
    if (!check.that(validate(position, channels, false, null), fname, "check_valid_channel_positions (position, channels, FALSE, NULL)")) return 0;
    if (channels == 1 and position[0] == MONO) return 1;
    if (position[0] == NONE) return 1;
    var mask: u64 = 0;
    _ = validate(position, channels, false, &mask);
    var tmp = [_]Pos{-1} ** 64;
    var j: usize = 0;
    for (0..64) |i| {
        if (mask & (@as(u64, 1) << @intCast(i)) != 0) {
            tmp[j] = @intCast(i);
            j += 1;
        }
    }
    @memcpy(position[0..@intCast(channels)], tmp[0..@intCast(channels)]);
    return 1;
}

fn maskOf(comptime names: []const []const u8) u64 {
    var v: u64 = 0;
    inline for (names) |n| v |= bit(p(n));
    return v;
}

const FALLBACK = [_]u64{
    0,
    maskOf(&.{ "FRONT_LEFT", "FRONT_RIGHT" }),
    maskOf(&.{ "FRONT_LEFT", "FRONT_RIGHT", "LFE1" }),
    maskOf(&.{ "FRONT_LEFT", "FRONT_RIGHT", "REAR_LEFT", "REAR_RIGHT" }),
    maskOf(&.{ "FRONT_LEFT", "FRONT_RIGHT", "REAR_LEFT", "REAR_RIGHT", "FRONT_CENTER" }),
    maskOf(&.{ "FRONT_LEFT", "FRONT_RIGHT", "REAR_LEFT", "REAR_RIGHT", "FRONT_CENTER", "LFE1" }),
    maskOf(&.{ "FRONT_LEFT", "FRONT_RIGHT", "REAR_LEFT", "REAR_RIGHT", "FRONT_CENTER", "LFE1", "REAR_CENTER" }),
    maskOf(&.{ "FRONT_LEFT", "FRONT_RIGHT", "REAR_LEFT", "REAR_RIGHT", "FRONT_CENTER", "LFE1", "SIDE_LEFT", "SIDE_RIGHT" }),
};

pub export fn gst_audio_channel_get_fallback_mask(channels: c.gint) c_ulong {
    if (!check.that(channels > 0, "gst_audio_channel_get_fallback_mask", "channels > 0")) return 0;
    if (channels > 8) return 0;
    return FALLBACK[@intCast(channels - 1)];
}

fn posName(pos: Pos) [*c]const u8 {
    return switch (pos) {
        NONE => "NONE",
        MONO => "MONO",
        INVALID => "INVALID",
        p("FRONT_LEFT") => "FL",
        p("FRONT_RIGHT") => "FR",
        p("FRONT_CENTER") => "FC",
        p("LFE1") => "LFE1",
        p("REAR_LEFT") => "RL",
        p("REAR_RIGHT") => "RR",
        p("FRONT_LEFT_OF_CENTER") => "FLoC",
        p("FRONT_RIGHT_OF_CENTER") => "FRoC",
        p("REAR_CENTER") => "RC",
        p("LFE2") => "LF2",
        p("SIDE_LEFT") => "SL",
        p("SIDE_RIGHT") => "SR",
        p("TOP_FRONT_LEFT") => "TFL",
        p("TOP_FRONT_RIGHT") => "TFR",
        p("TOP_FRONT_CENTER"), p("TOP_CENTER") => "TFC",
        p("TOP_REAR_LEFT") => "TRL",
        p("TOP_REAR_RIGHT") => "TRR",
        p("TOP_SIDE_LEFT") => "TSL",
        p("TOP_SIDE_RIGHT") => "TSR",
        p("TOP_REAR_CENTER") => "TRC",
        p("BOTTOM_FRONT_CENTER") => "BFC",
        p("BOTTOM_FRONT_LEFT") => "BFL",
        p("BOTTOM_FRONT_RIGHT") => "BFR",
        p("WIDE_LEFT") => "WL",
        p("WIDE_RIGHT") => "WR",
        p("SURROUND_LEFT") => "SL",
        p("SURROUND_RIGHT") => "SR",
        else => "UNKNOWN",
    };
}

pub export fn gst_audio_channel_positions_to_string(position: [*c]const Pos, channels: c.gint) [*c]u8 {
    const fname = "gst_audio_channel_positions_to_string";
    if (!check.that(channels > 0, fname, "channels > 0")) return null;
    if (!check.that(position != null, fname, "position != NULL")) return null;
    const s = c.g_string_new("[");
    for (0..@intCast(channels)) |i| c.g_string_append_printf(s, " %s", posName(position[i]));
    _ = c.g_string_append(s, " ]");
    return c.g_string_free(s, 0);
}
