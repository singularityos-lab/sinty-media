const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const channels = @import("channels.zig");
const info_mod = @import("info.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const ABuf = c.GstAudioBuffer;

fn unmapInternal(b: [*c]ABuf, n: c.guint) void {
    if (b.*.buffer == null) return;
    for (0..n) |i| c.gst_buffer_unmap(b.*.buffer, &b.*.map_infos[i]);
    if (b.*.planes != @as([*c]c.gpointer, @ptrCast(&b.*.priv_planes_arr))) {
        c.g_free(@ptrCast(b.*.planes));
        b.*.planes = null;
    }
    if (b.*.map_infos != @as([*c]c.GstMapInfo, @ptrCast(&b.*.priv_map_infos_arr))) {
        c.g_free(@ptrCast(b.*.map_infos));
        b.*.map_infos = null;
    }
    b.*.buffer = null;
    b.*.priv_planes_arr = std.mem.zeroes(@TypeOf(b.*.priv_planes_arr));
    b.*.priv_map_infos_arr = std.mem.zeroes(@TypeOf(b.*.priv_map_infos_arr));
}

pub export fn gst_audio_buffer_unmap(b: [*c]ABuf) void {
    unmapInternal(b, @intCast(b.*.n_planes));
}

pub export fn gst_audio_buffer_map(b: [*c]ABuf, info: [*c]const c.GstAudioInfo, gb: [*c]c.GstBuffer, flags: c.GstMapFlags) c.gboolean {
    const fname = "gst_audio_buffer_map";
    if (!check.that(b != null, fname, "buffer != NULL")) return 0;
    if (!check.that(info != null, fname, "info != NULL")) return 0;
    if (!check.that(info.*.finfo != null and info.*.rate > 0 and info.*.channels > 0 and info.*.bpf > 0, fname, "GST_AUDIO_INFO_IS_VALID (info)")) return 0;
    if (!check.that(info.*.finfo.*.format != c.GST_AUDIO_FORMAT_UNKNOWN, fname, "GST_AUDIO_INFO_FORMAT (info) != GST_AUDIO_FORMAT_UNKNOWN")) return 0;
    if (!check.that(gb != null and @as(*c.GstMiniObject, @ptrCast(gb)).type == c.gst_buffer_get_type(), fname, "GST_IS_BUFFER (gstbuffer)")) return 0;
    const meta = channels.audioMeta(gb);
    if (!check.that((meta == null and info.*.layout == c.GST_AUDIO_LAYOUT_INTERLEAVED) or (meta != null and info.*.layout == meta.*.info.layout), fname, "(!meta && info->layout == GST_AUDIO_LAYOUT_INTERLEAVED) || (meta && info->layout == meta->info.layout)")) return 0;
    if (meta != null and info_mod.gst_audio_info_is_equal(&meta.*.info, info) == 0) c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "the GstAudioInfo argument is not equal to the GstAudioMeta's attached info");
    if (meta != null) {
        if (!check.that(meta.*.samples <= c.gst_buffer_get_size(gb) / @as(usize, @intCast(meta.*.info.bpf)), fname, "meta->samples <= gst_buffer_get_size (gstbuffer) / GST_AUDIO_INFO_BPF (&meta->info)")) return 0;
        b.*.n_samples = meta.*.samples;
    } else b.*.n_samples = c.gst_buffer_get_size(gb) / @as(usize, @intCast(info.*.bpf));
    b.*.info = if (meta != null) meta.*.info else info.*;
    b.*.buffer = gb;
    if (b.*.info.layout == c.GST_AUDIO_LAYOUT_INTERLEAVED) {
        b.*.n_planes = 1;
        b.*.planes = @ptrCast(&b.*.priv_planes_arr);
        b.*.map_infos = @ptrCast(&b.*.priv_map_infos_arr);
        if (c.gst_buffer_map(gb, &b.*.map_infos[0], flags) == 0) return 0;
        b.*.planes[0] = b.*.map_infos[0].data;
        return 1;
    }
    b.*.n_planes = b.*.info.channels;
    const np: usize = @intCast(b.*.n_planes);
    if (b.*.n_planes > 8) {
        b.*.planes = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.gpointer) * np)));
        b.*.map_infos = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstMapInfo) * np)));
    } else {
        b.*.planes = @ptrCast(&b.*.priv_planes_arr);
        b.*.map_infos = @ptrCast(&b.*.priv_map_infos_arr);
    }
    if (b.*.n_samples == 0) {
        @memset(std.mem.sliceAsBytes(b.*.map_infos[0..np]), 0);
        @memset(std.mem.sliceAsBytes(b.*.planes[0..np]), 0);
        return 1;
    }
    const stride: usize = @intCast(b.*.info.finfo.*.width >> 3);
    const plane_size = b.*.n_samples * stride * @as(usize, @intCast(b.*.info.channels)) / np;
    var i: c.guint = 0;
    while (i < np) : (i += 1) {
        var idx: c.guint = 0;
        var length: c.guint = 0;
        var skip: usize = 0;
        if (c.gst_buffer_find_memory(gb, meta.*.offsets[i], plane_size, &idx, &length, &skip) == 0 or c.gst_buffer_map_range(gb, idx, @intCast(length), &b.*.map_infos[i], flags) == 0) {
            unmapInternal(b, i);
            return 0;
        }
        b.*.planes[i] = b.*.map_infos[i].data + skip;
    }
    return 1;
}
