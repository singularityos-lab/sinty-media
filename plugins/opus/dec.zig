const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const o = @import("oc.zig").o;
const oc = @import("common.zig");

const FILE = "../ext/opus/gstopusdec.c";
const SRC_CAPS = "audio/x-raw, format = (string) S16LE, layout = (string) interleaved, rate = (int) { 48000, 24000, 16000, 12000, 8000 }, channels = (int) [ 1, 255 ] ";
const SINK_CAPS = "audio/x-opus, channel-mapping-family = (int) 0; audio/x-opus, channel-mapping-family = (int) [1, 255], channels = (int) [1, 255], stream-count = (int) [1, 255], coupled-count = (int) [0, 255]";

const PROP_USE_INBAND_FEC = 1;
const PROP_APPLY_GAIN = 2;
const PROP_PHASE_INVERSION = 3;
const PROP_STATS = 4;

const Self = extern struct {
    parent: c.GstAudioDecoder,
    state: ?*o.OpusMSDecoder,
    packetno: u64,
    streamheader: [*c]c.GstBuffer,
    vorbiscomment: [*c]c.GstBuffer,
    sample_rate: u32,
    n_channels: c.guint,
    pre_skip: u16,
    r128_gain: i16,
    opus_pos: [64]c.GstAudioChannelPosition,
    needs_reorder: c.gboolean,
    info: c.GstAudioInfo,
    n_streams: u8,
    n_stereo_streams: u8,
    channel_mapping_family: u8,
    channel_mapping: [256]u8,
    apply_gain: c.gboolean,
    r128_gain_volume: f64,
    use_inband_fec: c.gboolean,
    last_buffer: [*c]c.GstBuffer,
    primed: c.gboolean,
    leftover_plc_duration: u64,
    last_known_buffer_duration: u64,
    phase_inversion: c.gboolean,
    num_pushed: u64,
    num_gap: u64,
    plc_num_samples: u64,
    plc_duration: u64,
};

const Class = extern struct {
    parent: c.GstAudioDecoderClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, SINK_CAPS);
var once: cm.Once = .{};

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn adec(s: *Self) *c.GstAudioDecoder {
    return &s.parent;
}

fn reset(s: *Self) void {
    s.packetno = 0;
    if (s.state) |st| o.opus_multistream_decoder_destroy(st);
    s.state = null;
    _ = c.gst_buffer_replace(&s.streamheader, null);
    _ = c.gst_buffer_replace(&s.vorbiscomment, null);
    _ = c.gst_buffer_replace(&s.last_buffer, null);
    s.primed = 0;
    s.pre_skip = 0;
    s.r128_gain = 0;
    s.sample_rate = 0;
    s.n_channels = 0;
    s.leftover_plc_duration = 0;
    s.last_known_buffer_duration = c.GST_CLOCK_TIME_NONE;
}

fn start(d: [*c]c.GstAudioDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    reset(s);
    c.gst_audio_decoder_set_plc_aware(d, 1);
    if (s.use_inband_fec != 0) c.gst_audio_decoder_set_latency(d, 120 * @as(u64, c.GST_MSECOND), 120 * @as(u64, c.GST_MSECOND));
    cm.lock(s);
    s.num_pushed = 0;
    s.num_gap = 0;
    s.plc_num_samples = 0;
    s.plc_duration = 0;
    cm.unlock(s);
    return 1;
}

fn stop(d: [*c]c.GstAudioDecoder) callconv(.c) c.gboolean {
    reset(me(d));
    return 1;
}

fn preferIntersect(inter: *[*c]c.GstCaps, pref: [*c]c.GstCaps) void {
    const tmp = c.gst_caps_intersect(inter.*, pref);
    if (c.gst_caps_is_empty(tmp) == 0) {
        c.gst_caps_unref(inter.*);
        inter.* = tmp;
    } else c.gst_caps_unref(tmp);
    c.gst_caps_unref(pref);
}

fn negotiate(s: *Self, pos0: ?[*]const c.GstAudioChannelPosition) bool {
    var pos = pos0;
    const caps = c.gst_pad_get_allowed_caps(adec(s).srcpad);
    if (caps != null) {
        const constraint = c.gst_caps_new_empty_simple("audio/x-raw");
        if (s.n_channels <= 2) {
            c.gst_caps_set_simple(constraint, "channels", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, 2), @as(?*anyopaque, null));
        } else c.gst_caps_set_simple(constraint, "channels", c.G_TYPE_INT, @as(c.gint, @intCast(s.n_channels)), @as(?*anyopaque, null));
        var inter = c.gst_caps_intersect(caps, constraint);
        c.gst_caps_unref(constraint);
        if (c.gst_caps_is_empty(inter) != 0) {
            c.gst_caps_unref(inter);
            c.gst_caps_unref(caps);
            return false;
        }
        if (s.n_channels <= 2) preferIntersect(&inter, c.gst_caps_new_simple("audio/x-raw", "channels", c.G_TYPE_INT, @as(c.gint, if (s.n_channels > 0) @intCast(s.n_channels) else 2), @as(?*anyopaque, null)));
        preferIntersect(&inter, c.gst_caps_new_simple("audio/x-raw", "rate", c.G_TYPE_INT, @as(c.gint, if (s.sample_rate > 0) @intCast(s.sample_rate) else 48000), @as(?*anyopaque, null)));
        inter = c.gst_caps_truncate(inter);
        const st = c.gst_caps_get_structure(inter, 0);
        var rate: c.gint = if (s.sample_rate > 0) @intCast(s.sample_rate) else 48000;
        _ = c.gst_structure_fixate_field_nearest_int(st, "rate", @intCast(s.sample_rate));
        _ = c.gst_structure_get_int(st, "rate", &rate);
        var channels: c.gint = if (s.n_channels > 0) @intCast(s.n_channels) else 2;
        _ = c.gst_structure_fixate_field_nearest_int(st, "channels", channels);
        _ = c.gst_structure_get_int(st, "channels", &channels);
        c.gst_caps_unref(inter);
        s.sample_rate = @intCast(rate);
        s.n_channels = @intCast(channels);
        c.gst_caps_unref(caps);
    }
    if (s.n_channels == 0) {
        s.n_channels = 2;
        pos = null;
    }
    if (s.sample_rate == 0) s.sample_rate = 48000;
    var gpos: [64]c.GstAudioChannelPosition = undefined;
    const n: usize = s.n_channels;
    if (pos) |p| {
        @memcpy(gpos[0..n], p[0..n]);
        _ = c.gst_audio_channel_positions_to_valid_order(&gpos, @intCast(n));
        @memcpy(s.opus_pos[0..n], p[0..n]);
        s.needs_reorder = @intFromBool(!std.mem.eql(c.GstAudioChannelPosition, p[0..n], gpos[0..n]));
    } else s.needs_reorder = 0;
    var info: c.GstAudioInfo = undefined;
    c.gst_audio_info_init(&info);
    c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_S16LE, @intCast(s.sample_rate), @intCast(s.n_channels), if (pos != null) &gpos else null);
    _ = c.gst_audio_decoder_set_output_format(adec(s), &info);
    s.info = info;
    return true;
}

fn err(s: *Self, code: c.gint, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_stream_error_quark(), code, null, debug, FILE, func, line);
}

fn parseHeader(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    if (!oc.isIdHeader(b)) {
        err(s, c.GST_STREAM_ERROR_FORMAT, c.g_strdup("Header is not an Opus ID header"), "gst_opus_dec_parse_header", 407);
        return c.GST_FLOW_ERROR;
    }
    var ch: u8 = 0;
    if (c.gst_codec_utils_opus_parse_header(b, &s.sample_rate, &ch, &s.channel_mapping_family, &s.n_streams, &s.n_stereo_streams, &s.channel_mapping, &s.pre_skip, &s.r128_gain) == 0) {
        err(s, c.GST_STREAM_ERROR_DECODE, c.g_strdup("Failed to parse Opus ID header"), "gst_opus_dec_parse_header", 419);
        return c.GST_FLOW_ERROR;
    }
    s.n_channels = ch;
    s.r128_gain_volume = std.math.pow(f64, 10.0, (@as(f64, @floatFromInt(s.r128_gain)) / 256.0) / 20.0);
    var pos: [64]c.GstAudioChannelPosition = undefined;
    var posn: ?[*]const c.GstAudioChannelPosition = null;
    if (s.channel_mapping_family == 1) {
        switch (s.n_channels) {
            1, 2 => {},
            3...8 => posn = &oc.positions[s.n_channels - 1],
            else => {
                cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("Using NONE channel layout for more than 8 channels"), FILE, "gst_opus_dec_parse_header", 448);
                for (0..@min(s.n_channels, 64)) |i| pos[i] = c.GST_AUDIO_CHANNEL_POSITION_NONE;
                posn = &pos;
            },
        }
    }
    if (!negotiate(s, posn)) return c.GST_FLOW_NOT_NEGOTIATED;
    return c.GST_FLOW_OK;
}

fn packetDuration(data: [*]const u8, bytes: usize) u64 {
    const durations = [32]u64{ 480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 1920, 2880, 480, 960, 480, 960, 120, 240, 480, 960, 120, 240, 480, 960, 120, 240, 480, 960, 120, 240, 480, 960 };
    if (bytes < 1) return 0;
    if (bytes >= 8 and std.mem.eql(u8, data[0..4], "Opus")) return 0;
    const toc = data[0];
    const fd = durations[toc >> 3];
    var nframes: u64 = 0;
    switch (toc & 3) {
        0 => nframes = 1,
        1, 2 => nframes = 2,
        else => {
            if (bytes < 2) return 0;
            nframes = data[1] & 63;
        },
    }
    const dur = nframes * fd;
    if (dur > 5760) return 0;
    const v: f32 = @as(f32, @floatFromInt(dur)) / 48.0 * 1000000.0;
    return @intFromFloat(v);
}

fn decodeData(s: *Self, buffer: [*c]c.GstBuffer) c.GstFlowReturn {
    const d = adec(s);
    if (s.state == null) {
        if (s.n_channels == 0) {
            s.n_channels = 2;
            s.sample_rate = 48000;
            s.channel_mapping_family = 0;
            s.channel_mapping[0] = 0;
            s.channel_mapping[1] = 1;
            s.n_streams = 1;
            s.n_stereo_streams = 1;
            if (!negotiate(s, null)) return c.GST_FLOW_NOT_NEGOTIATED;
        }
        if (s.n_channels == 2 and s.n_streams == 1 and s.n_stereo_streams == 0) s.channel_mapping[1] = 0;
        var e: c_int = 0;
        s.state = o.opus_multistream_decoder_create(@intCast(s.sample_rate), @intCast(s.n_channels), s.n_streams, s.n_stereo_streams, &s.channel_mapping, &e);
        if (s.state == null or e != o.OPUS_OK) {
            cm.elementError(s, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_INIT, c.g_strdup("Failed to create Opus decoder"), c.g_strdup_printf("Failed to create Opus decoder (%d): %s", e, o.opus_strerror(e)), FILE, "opus_dec_chain_parse_data", 865);
            return c.GST_FLOW_ERROR;
        }
        _ = o.opus_multistream_decoder_ctl(s.state, o.OPUS_SET_PHASE_INVERSION_DISABLED_REQUEST, @as(i32, @intFromBool(s.phase_inversion == 0)));
    }
    if (s.use_inband_fec != 0 and s.primed == 0) {
        _ = c.gst_buffer_replace(&s.last_buffer, buffer);
        s.primed = 1;
        return c.GST_FLOW_OK;
    }
    const b = if (s.use_inband_fec != 0 and c.gst_buffer_get_size(s.last_buffer) > 0) s.last_buffer else buffer;
    const bufd = if (s.use_inband_fec != 0) s.last_buffer else buffer;
    var map: c.GstMapInfo = undefined;
    var data: ?[*]const u8 = null;
    var size: usize = 0;
    if (b != null and c.gst_buffer_get_size(b) > 0) {
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        data = map.data;
        size = map.size;
    }
    var samples: c_int = 0;
    if (c.gst_buffer_get_size(bufd) == 0) {
        const align_: u64 = 2500 * @as(u64, c.GST_USECOND);
        var missing = cm.buf(bufd).duration;
        if (missing == c.GST_CLOCK_TIME_NONE or missing == 0) {
            missing = if (s.last_known_buffer_duration != c.GST_CLOCK_TIME_NONE) s.last_known_buffer_duration else 20 * @as(u64, c.GST_MSECOND);
        }
        cm.lock(s);
        s.num_gap += 1;
        cm.unlock(s);
        missing +%= s.leftover_plc_duration;
        const aligned = ((missing + align_ / 2) / align_) * align_;
        s.leftover_plc_duration = missing -% aligned;
        if (aligned < align_) {
            if (data != null) c.gst_buffer_unmap(b, &map);
            return c.GST_FLOW_OK;
        }
        samples = @intCast(c.gst_util_uint64_scale_int(aligned, @intCast(s.sample_rate), c.GST_SECOND));
        cm.lock(s);
        s.plc_num_samples +%= @intCast(samples);
        s.plc_duration +%= aligned;
        cm.unlock(s);
    } else {
        samples = @intCast(120 * s.sample_rate / 1000);
    }
    var packet: c.guint = @intCast(@as(c.guint, @intCast(samples)) * s.n_channels * 2);
    var out = c.gst_audio_decoder_allocate_output_buffer(d, packet);
    if (out == null) {
        err(s, c.GST_STREAM_ERROR_DECODE, c.g_strdup_printf("Failed to create %u byte buffer", packet), "opus_dec_chain_parse_data", 870);
        return c.GST_FLOW_ERROR;
    }
    if (size > 0) s.last_known_buffer_duration = packetDuration(data.?, size);
    var omap: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(out, &omap, c.GST_MAP_WRITE);
    var n: c_int = 0;
    while (true) {
        const fec: c_int = if (s.use_inband_fec != 0 and c.gst_buffer_get_size(s.last_buffer) == 0) 1 else 0;
        n = o.opus_multistream_decode(s.state, data, @intCast(size), @ptrCast(@alignCast(omap.data)), samples, fec);
        if (n != o.OPUS_BUFFER_TOO_SMALL) break;
        if (samples >= @as(c_int, @intCast(120 * s.sample_rate / 1000))) break;
        samples += @intCast(25 * s.sample_rate / 10000);
        packet = @intCast(@as(c.guint, @intCast(samples)) * s.n_channels * 2);
        c.gst_buffer_unmap(out, &omap);
        c.gst_buffer_unref(out);
        out = c.gst_audio_decoder_allocate_output_buffer(d, packet);
        if (out == null) {
            err(s, c.GST_STREAM_ERROR_DECODE, c.g_strdup_printf("Failed to create %u byte buffer", packet), "opus_dec_chain_parse_data", 870);
            return c.GST_FLOW_ERROR;
        }
        _ = c.gst_buffer_map(out, &omap, c.GST_MAP_WRITE);
    }
    c.gst_buffer_unmap(out, &omap);
    if (data != null) c.gst_buffer_unmap(b, &map);
    if (n < 0) {
        c.gst_buffer_unref(out);
        return c._gst_audio_decoder_error(d, 1, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("Decoding error (%d): %s", n, o.opus_strerror(n)), FILE, "opus_dec_chain_parse_data", 770);
    }
    c.gst_buffer_set_size(out, @as(isize, n) * 2 * @as(isize, @intCast(s.n_channels)));
    cm.buf(out).duration = @as(u64, @intCast(samples)) * @as(u64, c.GST_SECOND) / s.sample_rate;
    const nn: c.guint = @intCast(n);
    const cmeta: [*c]c.GstAudioClippingMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_clipping_meta_api_get_type())));
    if (cmeta != null and cmeta.*.start != 0) {
        const pre: c.guint = @truncate(cmeta.*.start);
        const scaled = (pre *% s.sample_rate) / 48000;
        const skip = if (scaled > nn) nn else scaled;
        c.gst_buffer_resize(out, @intCast(skip * 2 * s.n_channels), -1);
    }
    if (cmeta != null and cmeta.*.end != 0) {
        const post: c.guint = @truncate(cmeta.*.end);
        const scaled = (post *% s.sample_rate) / 48000;
        const skip = if (scaled > nn) nn else scaled;
        var outsize: c.guint = @intCast(c.gst_buffer_get_size(out));
        const sb = skip * 2 * s.n_channels;
        outsize = if (outsize > sb) outsize - sb else 0;
        c.gst_buffer_resize(out, 0, outsize);
    }
    var result = out;
    if (c.gst_buffer_get_size(out) == 0) {
        c.gst_buffer_unref(out);
        result = null;
    } else if (s.needs_reorder != 0) {
        _ = c.gst_audio_buffer_reorder_channels(out, c.GST_AUDIO_FORMAT_S16LE, @intCast(s.n_channels), &s.opus_pos, &s.info.position);
    }
    if (s.apply_gain != 0 and result != null and s.r128_gain != 0) {
        const vol = s.r128_gain_volume;
        _ = c.gst_buffer_map(result, &omap, c.GST_MAP_READWRITE);
        const smp: [*]i16 = @ptrCast(@alignCast(omap.data));
        for (0..omap.size / 2) |i| {
            const v: c_int = @intFromFloat(@trunc(@as(f64, @floatFromInt(smp[i])) * vol + 0.5));
            smp[i] = @intCast(std.math.clamp(v, -32768, 32767));
        }
        c.gst_buffer_unmap(result, &omap);
    }
    if (s.use_inband_fec != 0) _ = c.gst_buffer_replace(&s.last_buffer, buffer);
    cm.lock(s);
    s.num_pushed += 1;
    cm.unlock(s);
    return c.gst_audio_decoder_finish_frame(d, result, 1);
}

fn setFormat(d: [*c]c.GstAudioDecoder, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(d);
    const old = c.gst_pad_get_current_caps(d[0].sinkpad);
    if (old != null) {
        if (c.gst_caps_is_equal(caps, old) != 0) {
            c.gst_caps_unref(old);
            return 1;
        }
        reset(s);
        c.gst_caps_unref(old);
    }
    const st = c.gst_caps_get_structure(caps, 0);
    const sh = c.gst_structure_get_value(st, "streamheader");
    if (sh != null and sh.*.g_type == c.gst_value_array_get_type() and c.gst_value_array_get_size(sh) >= 2) {
        const header = c.gst_value_array_get_value(sh, 0);
        if (header != null and header.*.g_type == c.gst_buffer_get_type()) {
            const hb = c.gst_value_get_buffer(header);
            if (parseHeader(s, hb) != c.GST_FLOW_OK) return 0;
            _ = c.gst_buffer_replace(&s.streamheader, hb);
        }
        const vc = c.gst_value_array_get_value(sh, 1);
        if (vc != null and vc.*.g_type == c.gst_buffer_get_type()) _ = c.gst_buffer_replace(&s.vorbiscomment, c.gst_value_get_buffer(vc));
        return 1;
    }
    var ch: u8 = 0;
    if (c.gst_codec_utils_opus_parse_caps(caps, &s.sample_rate, &ch, &s.channel_mapping_family, &s.n_streams, &s.n_stereo_streams, &s.channel_mapping) == 0) return 0;
    s.n_channels = ch;
    var posn: ?[*]const c.GstAudioChannelPosition = null;
    if (s.channel_mapping_family == 1 and s.n_channels <= 8) posn = &oc.positions[s.n_channels - 1];
    return @intFromBool(negotiate(s, posn));
}

fn sameBuffers(a: [*c]c.GstBuffer, b: [*c]c.GstBuffer) bool {
    if (c.gst_buffer_get_size(a) != c.gst_buffer_get_size(b)) return false;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(a, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(a, &map);
    return c.gst_buffer_memcmp(b, 0, map.data, map.size) == 0;
}

fn handleFrame(d: [*c]c.GstAudioDecoder, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    if (b == null) return c.GST_FLOW_OK;
    const s = me(d);
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    if (s.streamheader != null and s.vorbiscomment != null) {
        if (sameBuffers(s.streamheader, b) or sameBuffers(s.vorbiscomment, b)) {
            _ = c.gst_audio_decoder_finish_frame(d, null, 1);
        } else res = decodeData(s, b);
    } else switch (s.packetno) {
        0 => {
            if (oc.isHeader(b, "OpusHead", 8)) {
                res = parseHeader(s, b);
                _ = c.gst_audio_decoder_finish_frame(d, null, 1);
            } else res = decodeData(s, b);
        },
        1 => {
            if (oc.isHeader(b, "OpusTags", 8)) {
                _ = c.gst_audio_decoder_finish_frame(d, null, 1);
            } else res = decodeData(s, b);
        },
        else => res = decodeData(s, b),
    }
    s.packetno += 1;
    return res;
}

fn ctlGet(s: *Self, req: c_int) u32 {
    if (s.state == null) return 0;
    var v: i32 = 0;
    if (o.opus_multistream_decoder_ctl(s.state, req, &v) != o.OPUS_OK) return 0;
    return @bitCast(v);
}

fn bandwidth(s: *Self) u32 {
    if (s.state == null) return 0;
    var bw: i32 = 0;
    if (o.opus_multistream_decoder_ctl(s.state, o.OPUS_GET_BANDWIDTH_REQUEST, &bw) != o.OPUS_OK) return 0;
    return switch (bw) {
        o.OPUS_BANDWIDTH_NARROWBAND => 4,
        o.OPUS_BANDWIDTH_MEDIUMBAND => 6,
        o.OPUS_BANDWIDTH_WIDEBAND => 8,
        o.OPUS_BANDWIDTH_SUPERWIDEBAND => 12,
        o.OPUS_BANDWIDTH_FULLBAND => 20,
        else => 0,
    };
}

fn stats(s: *Self) ?*c.GstStructure {
    cm.lock(s);
    defer cm.unlock(s);
    return c.gst_structure_new("application/x-opusdec-stats", "num-pushed", c.G_TYPE_UINT64, s.num_pushed, "num-gap", c.G_TYPE_UINT64, s.num_gap, "plc-num-samples", c.G_TYPE_UINT64, s.plc_num_samples, "plc-duration", c.G_TYPE_UINT64, s.plc_duration, "bandwidth", c.G_TYPE_UINT, bandwidth(s), "sample-rate", c.G_TYPE_UINT, ctlGet(s, o.OPUS_GET_SAMPLE_RATE_REQUEST), "gain", c.G_TYPE_UINT, ctlGet(s, o.OPUS_GET_GAIN_REQUEST), "last-packet-duration", c.G_TYPE_UINT, ctlGet(s, o.OPUS_GET_LAST_PACKET_DURATION_REQUEST), "channels", c.G_TYPE_UINT, s.n_channels, @as(?*anyopaque, null));
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_USE_INBAND_FEC => c.g_value_set_boolean(v, s.use_inband_fec),
        PROP_APPLY_GAIN => c.g_value_set_boolean(v, s.apply_gain),
        PROP_PHASE_INVERSION => c.g_value_set_boolean(v, s.phase_inversion),
        PROP_STATS => c.g_value_take_boxed(v, stats(s)),
        else => cm.warnInvalid(FILE, ob, id, spec, 1175),
    }
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_USE_INBAND_FEC => s.use_inband_fec = c.g_value_get_boolean(v),
        PROP_APPLY_GAIN => s.apply_gain = c.g_value_get_boolean(v),
        PROP_PHASE_INVERSION => s.phase_inversion = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, ob, id, spec, 1197),
    }
}

fn extendChannels(caps: [*c]c.GstCaps) void {
    for (0..c.gst_caps_get_size(caps)) |i| {
        const st = c.gst_caps_get_structure(caps, @intCast(i));
        var ch: c.gint = 0;
        if (c.gst_structure_get_int(st, "channels", &ch) != 0 and (ch == 1 or ch == 2)) {
            var v = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&v, c.gst_int_range_get_type());
            c.gst_value_set_int_range(&v, 1, 2);
            c.gst_structure_set_value(st, "channels", &v);
            c.g_value_unset(&v);
        }
    }
}

fn extendRates(caps: [*c]c.GstCaps) void {
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    for ([_]c.gint{ 48000, 24000, 16000, 12000, 8000 }) |r| {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.G_TYPE_INT);
        c.g_value_set_int(&v, r);
        c.gst_value_list_append_value(&list, &v);
        c.g_value_unset(&v);
    }
    for (0..c.gst_caps_get_size(caps)) |i| c.gst_structure_set_value(c.gst_caps_get_structure(caps, @intCast(i)), "rate", &list);
    c.g_value_unset(&list);
}

fn getCaps(d: [*c]c.GstAudioDecoder, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    var proxy: [*c]c.GstCaps = null;
    if (filter != null) {
        proxy = c.gst_caps_copy(filter);
        extendChannels(proxy);
        extendRates(proxy);
    }
    var caps = c.gst_audio_decoder_proxy_getcaps(d, null, proxy);
    if (proxy != null) c.gst_caps_unref(proxy);
    if (caps != null) {
        caps = c.gst_caps_make_writable(caps);
        extendChannels(caps);
        extendRates(caps);
    }
    if (filter != null) {
        const r = c.gst_caps_intersect(caps, filter);
        c.gst_caps_unref(caps);
        return r;
    }
    return caps;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc_: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc_.set_property = setProperty;
    oc_.get_property = getProperty;
    const ac: *c.GstAudioDecoderClass = @ptrCast(@alignCast(k));
    ac.start = start;
    ac.stop = stop;
    ac.handle_frame = handleFrame;
    ac.set_format = setFormat;
    ac.getcaps = getCaps;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Opus audio decoder", "Codec/Decoder/Audio/Converter", "decode opus streams to audio", "Vincent Penquerc'h <vincent.penquerch@collabora.co.uk>");
    c.g_object_class_install_property(oc_, PROP_USE_INBAND_FEC, c.g_param_spec_boolean("use-inband-fec", "Use in-band FEC", "Use forward error correction if available (needs PLC enabled)", 0, cm.RW));
    c.g_object_class_install_property(oc_, PROP_APPLY_GAIN, c.g_param_spec_boolean("apply-gain", "Apply gain", "Apply gain if any is specified in the header", 1, cm.RW));
    c.g_object_class_install_property(oc_, PROP_PHASE_INVERSION, c.g_param_spec_boolean("phase-inversion", "Control Phase Inversion", "Set to true to enable phase inversion, this will slightly improve stereo quality, but will have side effects when downmixed to mono.", 0, cm.RW));
    c.g_object_class_install_property(oc_, PROP_STATS, c.g_param_spec_boxed("stats", "Statistics", "Various statistics", c.gst_structure_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    _ = c._gst_debug_category_new("opusdec", 0, "opus decoding element");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.use_inband_fec = 0;
    s.apply_gain = 1;
    s.phase_inversion = 0;
    s.state = null;
    s.streamheader = null;
    s.vorbiscomment = null;
    s.last_buffer = null;
    c.gst_audio_decoder_set_needs_format(adec(s), 1);
    c.gst_audio_decoder_set_use_default_pad_acceptcaps(adec(s), 1);
    cm.obj(adec(s).sinkpad).flags |= c.GST_PAD_FLAG_ACCEPT_TEMPLATE;
    reset(s);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_audio_decoder_get_type(), "GstOpusDec", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    oc.elementInit();
    return c.gst_element_register(p, "opusdec", c.GST_RANK_PRIMARY, getType()) != 0;
}
