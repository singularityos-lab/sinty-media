const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Spec = c.GstAudioRingBufferSpec;
const HEADER = 8;

fn intField(caps: [*c]const c.GstCaps, field: [*c]const u8) c.gint {
    var ret: c.gint = 0;
    _ = c.gst_structure_get_int(c.gst_caps_get_structure(caps, 0), field, &ret);
    return ret;
}

fn strField(caps: [*c]const c.GstCaps, field: [*c]const u8) [*c]const u8 {
    return c.gst_structure_get_string(c.gst_caps_get_structure(caps, 0), field);
}

pub export fn gst_audio_iec61937_frame_size(spec: [*c]const Spec) c.guint {
    switch (spec.*.type) {
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_AC3 => return 1536 * 4,
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_EAC3 => return if (strField(spec.*.caps, "alignment") != null) 6144 * 4 else 0,
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DTS => {
            const dts = intField(spec.*.caps, "frame-size");
            const iec = intField(spec.*.caps, "block-size") *% 4;
            return if (iec >= dts +% HEADER) @bitCast(iec) else 0;
        },
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG => {
            const version = intField(spec.*.caps, "mpegaudioversion");
            const layer = intField(spec.*.caps, "layer");
            const channels = intField(spec.*.caps, "channels");
            if (version == 0 or layer == 0 or version == 3 or channels > 2) return 0;
            const frames: c.guint = if (version == 1 and layer == 1) 384 else if (version == 2 and layer == 1 and spec.*.info.rate <= 12000) 768 else if (version == 2 and layer == 2 and spec.*.info.rate <= 12000) 2304 else 1152;
            return frames * 4;
        },
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG2_AAC, c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG4_AAC => return 1024 * 4,
        else => return 0,
    }
}

pub export fn gst_audio_iec61937_payload(src: [*c]const u8, src_n: c.guint, dst: [*c]u8, dst_n: c.guint, spec: [*c]const Spec, endianness: c.gint) c.gboolean {
    const fname = "gst_audio_iec61937_payload";
    const zero = 1;
    const one = 0;
    const two = 3;
    const three = 2;
    const four = 5;
    const five = 4;
    const six = 7;
    const seven = 6;
    if (!check.that(src != null, fname, "src != NULL")) return 0;
    if (!check.that(dst != null, fname, "dst != NULL")) return 0;
    if (!check.that(src != dst, fname, "src != dst")) return 0;
    if (!check.that(dst_n >= gst_audio_iec61937_frame_size(spec), fname, "dst_n >= gst_audio_iec61937_frame_size (spec)")) return 0;
    if (dst_n < src_n +% HEADER) return 0;
    dst[zero] = 0xF8;
    dst[one] = 0x72;
    dst[two] = 0x4E;
    dst[three] = 0x1F;
    switch (spec.*.type) {
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_AC3 => {
            if (!check.that(src_n >= 6, fname, "src_n >= 6")) return 0;
            dst[four] = src[5] & 0x7;
            dst[five] = 1;
            const tmp = src_n *% 8;
            dst[six] = @truncate(tmp >> 8);
            dst[seven] = @truncate(tmp);
        },
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_EAC3 => {
            if (c.g_str_equal(strField(spec.*.caps, "alignment"), "iec61937") != 0) return 0;
            dst[four] = 0;
            dst[five] = 21;
            const w: u16 = @truncate(src_n);
            dst[six] = @truncate(w >> 8);
            dst[seven] = @truncate(w);
        },
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DTS => {
            const blocksize = intField(spec.*.caps, "block-size");
            if (!check.that(src_n != 0, fname, "src_n != 0")) return 0;
            if (blocksize == 0) return 0;
            dst[four] = 0;
            dst[five] = @truncate(@as(c_uint, @bitCast(11 + @divTrunc(blocksize, 1024))));
            const w: u16 = @truncate(src_n *% 8);
            dst[six] = @truncate(w >> 8);
            dst[seven] = @truncate(w);
        },
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG => {
            const version = intField(spec.*.caps, "mpegaudioversion");
            const layer = intField(spec.*.caps, "layer");
            if (!check.that(version > 0 and layer > 0, fname, "version > 0 && layer > 0")) return 0;
            const rate = spec.*.info.rate;
            dst[four] = 0;
            if (version == 1 and layer == 1) {
                dst[five] = 0x04;
            } else if ((version == 1 and (layer == 2 or layer == 3)) or (version == 2 and rate >= 12000)) {
                dst[five] = 0x05;
            } else if (version == 2 and layer == 1 and rate < 12000) {
                dst[five] = 0x08;
            } else if (version == 2 and layer == 2 and rate < 12000) {
                dst[five] = 0x09;
            } else if (version == 2 and layer == 3 and rate < 12000) {
                dst[five] = 0x0A;
            } else {
                check.reached("gstaudioiec61937.c", 294, fname);
                return 0;
            }
            const v: c_int = @as(c_int, @as(u16, @truncate(src_n))) * 8;
            dst[six] = @truncate(@as(c_uint, @bitCast(v >> 8)));
            dst[seven] = @truncate(@as(c_uint, @bitCast(v)));
        },
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG2_AAC, c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG4_AAC => {
            if (!check.that(src_n >= 7, fname, "src_n >= 7")) return 0;
            const blks = (src[6] & 0x03) + 1;
            dst[four] = 0;
            dst[five] = switch (blks) {
                1 => 0x07,
                2 => 0x13,
                4 => 0x33,
                else => {
                    check.reached("gstaudioiec61937.c", 328, fname);
                    return 0;
                },
            };
            const tmp = ((src_n +% 1) & ~@as(c.guint, 1)) *% 8;
            dst[six] = @truncate(tmp >> 8);
            dst[seven] = @truncate(tmp);
        },
        else => return 0,
    }
    var i: usize = 8;
    const n: usize = src_n;
    if (endianness == c.G_LITTLE_ENDIAN) {
        @memcpy(dst[i .. i + n], src[0..n]);
    } else {
        var t: usize = 1;
        while (t < n) : (t += 2) {
            dst[i + t - 1] = src[t];
            dst[i + t] = src[t - 1];
        }
        if (n % 2 != 0) {
            dst[i + n - 1] = 0;
            dst[i + n] = src[n - 1];
            i += 1;
        }
    }
    i += n;
    @memset(dst[i..dst_n], 0);
    return 1;
}
