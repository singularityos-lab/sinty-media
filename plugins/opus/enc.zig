const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const o = @import("oc.zig").o;
const oc = @import("common.zig");

const FILE = "../ext/opus/gstopusenc.c";
const SINK_CAPS = "audio/x-raw, format = (string) S16LE, layout = (string) interleaved, rate = (int) 48000, channels = (int) [ 1, 255 ]; audio/x-raw, format = (string) S16LE, layout = (string) interleaved, rate = (int) { 8000, 12000, 16000, 24000 }, channels = (int) [ 1, 255 ] ";

const LOWEST_BITRATE = 4000;
const HIGHEST_BITRATE = 650000;

const CBR = 0;
const VBR = 1;
const CVBR = 2;

const PROP_AUDIO_TYPE = 1;
const PROP_BITRATE = 2;
const PROP_BANDWIDTH = 3;
const PROP_FRAME_SIZE = 4;
const PROP_BITRATE_TYPE = 5;
const PROP_COMPLEXITY = 6;
const PROP_INBAND_FEC = 7;
const PROP_DTX = 8;
const PROP_PACKET_LOSS_PERCENT = 9;
const PROP_MAX_PAYLOAD_SIZE = 10;

const Self = extern struct {
    parent: c.GstAudioEncoder,
    state: ?*o.OpusMSEncoder,
    lock: c.GMutex,
    audio_type: c.gint,
    bitrate: c.gint,
    bandwidth: c.gint,
    frame_size: c.gint,
    bitrate_type: c.gint,
    complexity: c.gint,
    inband_fec: c.gboolean,
    dtx: c.gboolean,
    packet_loss_percentage: c.gint,
    max_payload_size: c.guint,
    frame_samples: c.gint,
    n_channels: c.gint,
    sample_rate: c.gint,
    unpositioned: c.gboolean,
    encoded_samples: i64,
    consumed_samples: i64,
    lookahead: u16,
    pending_lookahead: u16,
    channel_mapping_family: u8,
    encoding_channel_mapping: [256]u8,
    channel_mapping: [256]u8,
    n_stereo_streams: u8,
    needs_reorder: c.gboolean,
    opus_pos: [64]c.GstAudioChannelPosition,
};

const Class = extern struct {
    parent: c.GstAudioEncoderClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "audio/x-opus");
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, SINK_CAPS);
var once: cm.Once = .{};
var parent_class: ?*c.GstAudioEncoderClass = null;

var bw_once: cm.Once = .{};
var fs_once: cm.Once = .{};
var at_once: cm.Once = .{};
var bt_once: cm.Once = .{};

const bw_values = [_]c.GEnumValue{
    .{ .value = o.OPUS_BANDWIDTH_NARROWBAND, .value_name = "Narrow band", .value_nick = "narrowband" },
    .{ .value = o.OPUS_BANDWIDTH_MEDIUMBAND, .value_name = "Medium band", .value_nick = "mediumband" },
    .{ .value = o.OPUS_BANDWIDTH_WIDEBAND, .value_name = "Wide band", .value_nick = "wideband" },
    .{ .value = o.OPUS_BANDWIDTH_SUPERWIDEBAND, .value_name = "Super wide band", .value_nick = "superwideband" },
    .{ .value = o.OPUS_BANDWIDTH_FULLBAND, .value_name = "Full band", .value_nick = "fullband" },
    .{ .value = o.OPUS_AUTO, .value_name = "Auto", .value_nick = "auto" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

const fs_values = [_]c.GEnumValue{
    .{ .value = 2, .value_name = "2.5", .value_nick = "2.5" },
    .{ .value = 5, .value_name = "5", .value_nick = "5" },
    .{ .value = 10, .value_name = "10", .value_nick = "10" },
    .{ .value = 20, .value_name = "20", .value_nick = "20" },
    .{ .value = 40, .value_name = "40", .value_nick = "40" },
    .{ .value = 60, .value_name = "60", .value_nick = "60" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

const at_values = [_]c.GEnumValue{
    .{ .value = o.OPUS_APPLICATION_AUDIO, .value_name = "Generic audio", .value_nick = "generic" },
    .{ .value = o.OPUS_APPLICATION_VOIP, .value_name = "Voice", .value_nick = "voice" },
    .{ .value = o.OPUS_APPLICATION_RESTRICTED_LOWDELAY, .value_name = "Restricted low delay", .value_nick = "restricted-lowdelay" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

const bt_values = [_]c.GEnumValue{
    .{ .value = CBR, .value_name = "CBR", .value_nick = "cbr" },
    .{ .value = VBR, .value_name = "VBR", .value_nick = "vbr" },
    .{ .value = CVBR, .value_name = "Constrained VBR", .value_nick = "constrained-vbr" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn bwType() c.GType {
    return bw_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstOpusEncBandwidth", &bw_values);
        }
    }.f);
}

fn fsType() c.GType {
    return fs_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstOpusEncFrameSize", &fs_values);
        }
    }.f);
}

fn atType() c.GType {
    return at_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstOpusEncAudioType", &at_values);
        }
    }.f);
}

fn btType() c.GType {
    return bt_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstOpusEncBitrateType", &bt_values);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn aenc(s: *Self) *c.GstAudioEncoder {
    return &s.parent;
}

fn ctl(s: *Self, req: c_int, v: c_int) void {
    _ = o.opus_multistream_encoder_ctl(s.state, req, @as(i32, v));
}

fn setTags(s: *Self) void {
    const tl = c.gst_tag_list_new_empty();
    c.gst_tag_list_add(tl, c.GST_TAG_MERGE_REPLACE, "bitrate", @as(c.guint, @bitCast(s.bitrate)), @as(?*anyopaque, null));
    c.gst_audio_encoder_merge_tags(aenc(s), tl, c.GST_TAG_MERGE_REPLACE);
    c.gst_tag_list_unref(tl);
}

fn start(e: [*c]c.GstAudioEncoder) callconv(.c) c.gboolean {
    const s = me(e);
    s.encoded_samples = 0;
    s.consumed_samples = 0;
    return 1;
}

fn stop(e: [*c]c.GstAudioEncoder) callconv(.c) c.gboolean {
    const s = me(e);
    if (s.state) |st| o.opus_multistream_encoder_destroy(st);
    s.state = null;
    c.gst_tag_setter_reset_tags(@ptrCast(s));
    return 1;
}

fn latency(s: *Self) u64 {
    return c.gst_util_uint64_scale(@bitCast(@as(i64, s.frame_samples)), c.GST_SECOND, @bitCast(@as(i64, s.sample_rate)));
}

fn setupBase(s: *Self) void {
    c.gst_audio_encoder_set_latency(aenc(s), latency(s), latency(s));
    c.gst_audio_encoder_set_frame_samples_min(aenc(s), s.frame_samples);
    c.gst_audio_encoder_set_frame_samples_max(aenc(s), s.frame_samples);
    c.gst_audio_encoder_set_frame_max(aenc(s), 1);
}

fn frameSamples(s: *Self) c.gint {
    const r = s.sample_rate;
    return switch (s.frame_size) {
        2 => @divTrunc(r, 400),
        5 => @divTrunc(r, 200),
        10 => @divTrunc(r, 100),
        20 => @divTrunc(r, 50),
        40 => @divTrunc(r, 25),
        60 => @divTrunc(3 * r, 50),
        else => 0,
    };
}

fn trivial(m: *[256]u8) void {
    for (0..255) |i| m[i] = @intCast(i);
}

fn setupMappings(s: *Self, info: *const c.GstAudioInfo) void {
    s.n_stereo_streams = 0;
    s.needs_reorder = 0;
    trivial(&s.channel_mapping);
    const n: usize = @intCast(s.n_channels);
    if (n == 1 and s.unpositioned == 0) {
        s.channel_mapping_family = 0;
        return;
    }
    if (n == 2 and s.unpositioned == 0) {
        s.channel_mapping_family = 0;
        s.n_stereo_streams = 1;
        return;
    }
    if (n >= 3 and n <= 8 and s.unpositioned == 0) {
        const op = &oc.positions[n - 1];
        var gp: [8]c.GstAudioChannelPosition = op.*;
        _ = c.gst_audio_channel_positions_to_valid_order(&gp, @intCast(n));
        if (std.mem.eql(c.GstAudioChannelPosition, gp[0..n], info.position[0..n])) {
            @memcpy(s.channel_mapping[0..n], oc.vorbis_map[n - 1].mapping[0..n]);
            s.n_stereo_streams = oc.vorbis_map[n - 1].coupled;
            @memcpy(s.opus_pos[0..8], op);
            s.needs_reorder = @intFromBool(!std.mem.eql(c.GstAudioChannelPosition, op[0..n], gp[0..n]));
            s.channel_mapping_family = 1;
            return;
        }
    }
    trivial(&s.channel_mapping);
    s.channel_mapping_family = 255;
    s.n_stereo_streams = 0;
    const allowed = c.gst_pad_get_allowed_caps(aenc(s).srcpad);
    const fc = c.gst_caps_new_simple("audio/x-opus", "channels", c.G_TYPE_INT, s.n_channels, "rate", c.G_TYPE_INT, s.sample_rate, "channel-mapping-family", c.G_TYPE_INT, @as(c.gint, 255), @as(?*anyopaque, null));
    if (allowed != null) {
        var inter = c.gst_caps_intersect_full(allowed, fc, c.GST_CAPS_INTERSECT_FIRST);
        inter = c.gst_caps_fixate(inter);
        var sc: u8 = 0;
        var cc: u8 = 0;
        var map: [256]u8 = undefined;
        if (c.gst_codec_utils_opus_parse_caps(inter, null, null, null, &sc, &cc, &map) != 0 and @as(c.gint, sc) + cc == s.n_channels) {
            s.n_stereo_streams = cc;
            s.channel_mapping = map;
        }
        c.gst_caps_unref(inter);
        c.gst_caps_unref(allowed);
    }
    c.gst_caps_unref(fc);
}

fn setup(s: *Self) bool {
    var e: c_int = o.OPUS_OK;
    const nstreams = s.n_channels - s.n_stereo_streams;
    if (s.channel_mapping_family == 1) {
        var streams: c_int = 0;
        var coupled: c_int = 0;
        var mapping: [8]u8 = undefined;
        s.state = o.opus_multistream_surround_encoder_create(s.sample_rate, s.n_channels, s.channel_mapping_family, &streams, &coupled, &mapping, s.audio_type, &e);
        if (s.state == null or e != o.OPUS_OK) return false;
        const n: usize = @intCast(s.n_channels);
        if (streams != nstreams or coupled != s.n_stereo_streams or !std.mem.eql(u8, mapping[0..n], s.channel_mapping[0..n])) return false;
    } else {
        s.state = o.opus_multistream_encoder_create(s.sample_rate, s.n_channels, nstreams, s.n_stereo_streams, &s.channel_mapping, s.audio_type, &e);
        if (s.state == null or e != o.OPUS_OK) return false;
    }
    ctl(s, o.OPUS_SET_BITRATE_REQUEST, s.bitrate);
    ctl(s, o.OPUS_SET_BANDWIDTH_REQUEST, s.bandwidth);
    ctl(s, o.OPUS_SET_VBR_REQUEST, @intFromBool(s.bitrate_type != CBR));
    ctl(s, o.OPUS_SET_VBR_CONSTRAINT_REQUEST, @intFromBool(s.bitrate_type == CVBR));
    ctl(s, o.OPUS_SET_COMPLEXITY_REQUEST, s.complexity);
    ctl(s, o.OPUS_SET_INBAND_FEC_REQUEST, s.inband_fec);
    ctl(s, o.OPUS_SET_DTX_REQUEST, s.dtx);
    ctl(s, o.OPUS_SET_PACKET_LOSS_PERC_REQUEST, s.packet_loss_percentage);
    var la: i32 = 0;
    _ = o.opus_multistream_encoder_ctl(s.state, o.OPUS_GET_LOOKAHEAD_REQUEST, &la);
    la = @divTrunc(la * 48000, s.sample_rate);
    s.lookahead = @truncate(@as(u32, @bitCast(la)));
    s.pending_lookahead = s.lookahead;
    const header = c.gst_codec_utils_opus_create_header(@intCast(s.sample_rate), @intCast(s.n_channels), s.channel_mapping_family, @intCast(nstreams), s.n_stereo_streams, &s.channel_mapping, s.lookahead, 0);
    var empty: ?*c.GstTagList = null;
    var tags = c.gst_tag_setter_get_tag_list(@ptrCast(s));
    if (tags == null) {
        empty = c.gst_tag_list_new_empty();
        tags = empty;
    }
    const comments = c.gst_tag_list_to_vorbiscomment_buffer(tags, "OpusTags", 8, "Encoded with GStreamer opusenc");
    const caps = c.gst_codec_utils_opus_create_caps_from_header(header, comments);
    if (empty) |t| c.gst_tag_list_unref(t);
    c.gst_buffer_unref(header);
    c.gst_buffer_unref(comments);
    const ret = c.gst_audio_encoder_set_output_format(aenc(s), caps);
    c.gst_caps_unref(caps);
    return ret != 0;
}

fn setFormat(e: [*c]c.GstAudioEncoder, info: [*c]c.GstAudioInfo) callconv(.c) c.gboolean {
    const s = me(e);
    c.g_mutex_lock(&s.lock);
    defer c.g_mutex_unlock(&s.lock);
    s.n_channels = info.*.channels;
    s.unpositioned = @intFromBool(info.*.flags & c.GST_AUDIO_FLAG_UNPOSITIONED != 0);
    s.sample_rate = info.*.rate;
    setupMappings(s, info);
    if (s.state) |st| o.opus_multistream_encoder_destroy(st);
    s.state = null;
    if (!setup(s)) return 0;
    setTags(s);
    s.frame_samples = frameSamples(s);
    setupBase(s);
    return 1;
}

fn sinkEvent(e: [*c]c.GstAudioEncoder, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(e);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_TAG => {
            var list: ?*c.GstTagList = null;
            const setter: ?*c.GstTagSetter = @ptrCast(s);
            const mode = c.gst_tag_setter_get_tag_merge_mode(setter);
            c.gst_event_parse_tag(ev, &list);
            c.gst_tag_setter_merge_tags(setter, list, mode);
        },
        c.GST_EVENT_SEGMENT => {
            s.encoded_samples = 0;
            s.consumed_samples = 0;
        },
        else => {},
    }
    return parent_class.?.sink_event.?(e, ev);
}

var tmpl_once: usize = 0;
var tmpl_caps: [*c]c.GstCaps = null;

fn templateCaps() [*c]c.GstCaps {
    if (c.g_once_init_enter(&tmpl_once) != 0) {
        const caps = c.gst_caps_new_empty();
        @as(*c.GstMiniObject, @ptrCast(caps)).flags |= c.GST_MINI_OBJECT_FLAG_MAY_BE_LEAKED;
        var rates = std.mem.zeroes(c.GValue);
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&rates, c.gst_value_list_get_type());
        _ = c.g_value_init(&v, c.G_TYPE_INT);
        for ([_]c.gint{ 8000, 12000, 16000, 24000 }) |r| {
            c.g_value_set_int(&v, r);
            c.gst_value_list_append_value(&rates, &v);
        }
        const s1 = c.gst_structure_new("audio/x-raw", "format", c.G_TYPE_STRING, "S16LE", "layout", c.G_TYPE_STRING, "interleaved", "rate", c.G_TYPE_INT, @as(c.gint, 48000), @as(?*anyopaque, null));
        const s2 = c.gst_structure_new("audio/x-raw", "format", c.G_TYPE_STRING, "S16LE", "layout", c.G_TYPE_STRING, "interleaved", @as(?*anyopaque, null));
        c.gst_structure_set_value(s2, "rate", &rates);
        c.g_value_unset(&rates);
        c.g_value_unset(&v);
        for ([_]*c.GstStructure{ s1.?, s2.? }) |b| {
            const st = c.gst_structure_copy(b);
            c.gst_structure_set(st, "channels", c.G_TYPE_INT, @as(c.gint, 1), @as(?*anyopaque, null));
            c.gst_caps_append_structure(caps, st);
        }
        for (2..9) |i| {
            var mask: u64 = 0;
            for (0..i) |k| mask |= @as(u64, 1) << @intCast(oc.positions[i - 1][k]);
            for ([_]*c.GstStructure{ s1.?, s2.? }) |b| {
                const st = c.gst_structure_copy(b);
                c.gst_structure_set(st, "channels", c.G_TYPE_INT, @as(c.gint, @intCast(i)), "channel-mask", c.gst_bitmask_get_type(), mask, @as(?*anyopaque, null));
                c.gst_caps_append_structure(caps, st);
            }
        }
        for ([_]*c.GstStructure{ s1.?, s2.? }) |b| {
            const st = c.gst_structure_copy(b);
            c.gst_structure_set(st, "channels", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, 255), @as(?*anyopaque, null));
            c.gst_caps_append_structure(caps, st);
        }
        c.gst_structure_free(s1);
        c.gst_structure_free(s2);
        tmpl_caps = caps;
        c.g_once_init_leave(&tmpl_once, 1);
    }
    return tmpl_caps;
}

fn getCaps(e: [*c]c.GstAudioEncoder, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    return c.gst_audio_encoder_proxy_getcaps(e, templateCaps(), filter);
}

fn encode(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    c.g_mutex_lock(&s.lock);
    const nch: usize = @intCast(s.n_channels);
    const bytes: usize = @as(usize, @intCast(s.frame_samples)) * nch * 2;
    const maxp = s.max_payload_size;
    const frame_samples: i64 = s.frame_samples;
    var input_samples: i64 = frame_samples;
    c.g_mutex_unlock(&s.lock);
    const rate: u64 = @intCast(s.sample_rate);
    var map: c.GstMapInfo = undefined;
    var mapped = false;
    var mdata: ?[*]u8 = null;
    var data: ?[*]const u8 = null;
    var size: usize = 0;
    var output_samples: i64 = 0;
    var trim_start: u64 = 0;
    var trim_end: u64 = 0;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    defer {
        if (mapped) c.gst_buffer_unmap(b, &map);
        c.g_free(mdata);
    }
    if (b != null) {
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        mapped = true;
        const bsize = map.size;
        if (bsize % bytes != 0) {
            input_samples = @intCast(bsize / (nch * 2));
            const diff = (s.encoded_samples + frame_samples) - (s.consumed_samples + input_samples);
            if (diff >= 0) {
                output_samples = frame_samples - diff;
                trim_end = @bitCast(@divTrunc(diff * 48000, @as(i64, @intCast(rate))));
            } else output_samples = frame_samples;
            size = ((bsize / bytes) + 1) * bytes;
            mdata = @ptrCast(c.g_malloc0(size));
            @memcpy(mdata.?[0..bsize], map.data[0..bsize]);
            data = mdata;
        } else {
            if (s.needs_reorder != 0) {
                mdata = @ptrCast(c.g_memdup2(map.data, bsize));
                data = mdata;
                size = bytes;
            } else {
                data = map.data;
                size = bsize;
            }
            if (s.pending_lookahead != 0) {
                const scaled: i64 = @divTrunc(@as(i64, s.pending_lookahead) * s.sample_rate, 48000);
                if (input_samples > scaled) {
                    output_samples = input_samples - scaled;
                    trim_start = s.pending_lookahead;
                    s.pending_lookahead = 0;
                } else {
                    trim_start = @as(u64, @intCast(input_samples)) * 48000 / rate;
                    s.pending_lookahead -%= @truncate(trim_start);
                    output_samples = 0;
                }
            } else output_samples = input_samples;
        }
    } else {
        if (s.encoded_samples < s.consumed_samples) {
            mdata = @ptrCast(c.g_malloc0(bytes));
            data = mdata;
            size = bytes;
            output_samples = s.consumed_samples - s.encoded_samples;
            input_samples = 0;
            trim_end = (@as(u64, @bitCast(frame_samples - output_samples)) *% 48000) / rate;
        } else return ret;
    }
    const out = c.gst_audio_encoder_allocate_output_buffer(aenc(s), maxp * @as(c.guint, @intCast(nch)));
    if (out == null) return ret;
    if (trim_start != 0 or trim_end != 0) _ = c.gst_buffer_add_audio_clipping_meta(out, c.GST_FORMAT_DEFAULT, trim_start, trim_end);
    if (s.needs_reorder != 0) {
        const info = c.gst_audio_encoder_get_audio_info(aenc(s));
        _ = c.gst_audio_reorder_channels(mdata, bytes, c.GST_AUDIO_FORMAT_S16LE, s.n_channels, &info.*.position[0], &s.opus_pos[0]);
    }
    var omap: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(out, &omap, c.GST_MAP_WRITE);
    const outsize = o.opus_multistream_encode(s.state, @ptrCast(@alignCast(data)), @intCast(frame_samples), omap.data, @intCast(maxp * @as(c.guint, @intCast(nch))));
    c.gst_buffer_unmap(out, &omap);
    if (outsize < 0) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_ENCODE, null, c.g_strdup_printf("Encoding failed (%d): %s", outsize, o.opus_strerror(outsize)), FILE, "gst_opus_enc_encode", 1045);
        c.gst_buffer_unref(out);
        return c.GST_FLOW_ERROR;
    } else if (@as(c.guint, @intCast(outsize)) > maxp) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_ENCODE, null, c.g_strdup_printf("Encoded size %d is higher than max payload size (%d bytes)", outsize, maxp), FILE, "gst_opus_enc_encode", 1050);
        c.gst_buffer_unref(out);
        return c.GST_FLOW_ERROR;
    }
    c.gst_buffer_set_size(out, outsize);
    ret = c.gst_audio_encoder_finish_frame(aenc(s), out, @intCast(output_samples));
    s.encoded_samples += output_samples;
    s.consumed_samples += input_samples;
    return ret;
}

fn handleFrame(e: [*c]c.GstAudioEncoder, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return encode(me(e), b);
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    c.g_mutex_lock(&s.lock);
    defer c.g_mutex_unlock(&s.lock);
    switch (id) {
        PROP_AUDIO_TYPE => c.g_value_set_enum(v, s.audio_type),
        PROP_BITRATE => c.g_value_set_int(v, s.bitrate),
        PROP_BANDWIDTH => c.g_value_set_enum(v, s.bandwidth),
        PROP_FRAME_SIZE => c.g_value_set_enum(v, s.frame_size),
        PROP_BITRATE_TYPE => c.g_value_set_enum(v, s.bitrate_type),
        PROP_COMPLEXITY => c.g_value_set_int(v, s.complexity),
        PROP_INBAND_FEC => c.g_value_set_boolean(v, s.inband_fec),
        PROP_DTX => c.g_value_set_boolean(v, s.dtx),
        PROP_PACKET_LOSS_PERCENT => c.g_value_set_int(v, s.packet_loss_percentage),
        PROP_MAX_PAYLOAD_SIZE => c.g_value_set_uint(v, s.max_payload_size),
        else => cm.warnInvalid(FILE, ob, id, spec, 1135),
    }
}

fn update(s: *Self, field: *c.gint, val: c.gint, req: c_int) void {
    c.g_mutex_lock(&s.lock);
    field.* = val;
    if (s.state != null) ctl(s, req, val);
    c.g_mutex_unlock(&s.lock);
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_AUDIO_TYPE => s.audio_type = c.g_value_get_enum(v),
        PROP_BITRATE => update(s, &s.bitrate, c.g_value_get_int(v), o.OPUS_SET_BITRATE_REQUEST),
        PROP_BANDWIDTH => update(s, &s.bandwidth, c.g_value_get_enum(v), o.OPUS_SET_BANDWIDTH_REQUEST),
        PROP_FRAME_SIZE => {
            c.g_mutex_lock(&s.lock);
            s.frame_size = c.g_value_get_enum(v);
            s.frame_samples = frameSamples(s);
            setupBase(s);
            c.g_mutex_unlock(&s.lock);
        },
        PROP_BITRATE_TYPE => {
            c.g_mutex_lock(&s.lock);
            s.bitrate_type = c.g_value_get_enum(v);
            if (s.state != null) {
                ctl(s, o.OPUS_SET_VBR_REQUEST, @intFromBool(s.bitrate_type != CBR));
                ctl(s, o.OPUS_SET_VBR_CONSTRAINT_REQUEST, @intFromBool(s.bitrate_type == CVBR));
            }
            c.g_mutex_unlock(&s.lock);
        },
        PROP_COMPLEXITY => update(s, &s.complexity, c.g_value_get_int(v), o.OPUS_SET_COMPLEXITY_REQUEST),
        PROP_INBAND_FEC => update(s, &s.inband_fec, c.g_value_get_boolean(v), o.OPUS_SET_INBAND_FEC_REQUEST),
        PROP_DTX => update(s, &s.dtx, c.g_value_get_boolean(v), o.OPUS_SET_DTX_REQUEST),
        PROP_PACKET_LOSS_PERCENT => update(s, &s.packet_loss_percentage, c.g_value_get_int(v), o.OPUS_SET_PACKET_LOSS_PERC_REQUEST),
        PROP_MAX_PAYLOAD_SIZE => {
            c.g_mutex_lock(&s.lock);
            s.max_payload_size = c.g_value_get_uint(v);
            c.g_mutex_unlock(&s.lock);
        },
        else => cm.warnInvalid(FILE, ob, id, spec, 1207),
    }
}

fn finalize(ob: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&me(ob).lock);
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).finalize.?(ob);
}

const PLAYING = cm.RW | cm.MUTABLE_PLAYING;

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Opus audio encoder", "Codec/Encoder/Audio", "Encodes audio in Opus format", "Vincent Penquerc'h <vincent.penquerch@collabora.co.uk>");
    const ac: *c.GstAudioEncoderClass = @ptrCast(@alignCast(k));
    ac.start = start;
    ac.stop = stop;
    ac.set_format = setFormat;
    ac.handle_frame = handleFrame;
    ac.sink_event = sinkEvent;
    ac.getcaps = getCaps;
    c.g_object_class_install_property(gc, PROP_AUDIO_TYPE, c.g_param_spec_enum("audio-type", "What type of audio to optimize for", "What type of audio to optimize for", atType(), o.OPUS_APPLICATION_AUDIO, cm.RW));
    c.g_object_class_install_property(gc, PROP_BITRATE, c.g_param_spec_int("bitrate", "Encoding Bit-rate", "Specify an encoding bit-rate (in bps).", LOWEST_BITRATE, HIGHEST_BITRATE, 64000, PLAYING));
    c.g_object_class_install_property(gc, PROP_BANDWIDTH, c.g_param_spec_enum("bandwidth", "Band Width", "Audio Band Width", bwType(), o.OPUS_BANDWIDTH_FULLBAND, PLAYING));
    c.g_object_class_install_property(gc, PROP_FRAME_SIZE, c.g_param_spec_enum("frame-size", "Frame Size", "The duration of an audio frame, in ms", fsType(), 20, PLAYING));
    c.g_object_class_install_property(gc, PROP_BITRATE_TYPE, c.g_param_spec_enum("bitrate-type", "Bitrate type", "Bitrate type", btType(), CVBR, PLAYING));
    c.g_object_class_install_property(gc, PROP_COMPLEXITY, c.g_param_spec_int("complexity", "Complexity", "Complexity", 0, 10, 10, PLAYING));
    c.g_object_class_install_property(gc, PROP_INBAND_FEC, c.g_param_spec_boolean("inband-fec", "In-band FEC", "Enable in-band forward error correction (use in combination with the packet-loss-percentage property)", 0, PLAYING));
    c.g_object_class_install_property(gc, PROP_DTX, c.g_param_spec_boolean("dtx", "DTX", "DTX", 0, PLAYING));
    c.g_object_class_install_property(gc, PROP_PACKET_LOSS_PERCENT, c.g_param_spec_int("packet-loss-percentage", "Loss percentage", "Packet loss percentage", 0, 100, 0, PLAYING));
    c.g_object_class_install_property(gc, PROP_MAX_PAYLOAD_SIZE, c.g_param_spec_uint("max-payload-size", "Max payload size", "Maximum payload size in bytes", 2, 4000, 4000, PLAYING));
    gc.finalize = finalize;
    _ = c._gst_debug_category_new("opusenc", 0, "Opus encoder");
    c.gst_type_mark_as_plugin_api(atType(), 0);
    c.gst_type_mark_as_plugin_api(bwType(), 0);
    c.gst_type_mark_as_plugin_api(btType(), 0);
    c.gst_type_mark_as_plugin_api(fsType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    cm.obj(aenc(s).sinkpad).flags |= c.GST_PAD_FLAG_ACCEPT_TEMPLATE;
    c.g_mutex_init(&s.lock);
    s.state = null;
    s.n_channels = -1;
    s.sample_rate = -1;
    s.frame_samples = 0;
    s.unpositioned = 0;
    s.bitrate = 64000;
    s.bandwidth = o.OPUS_BANDWIDTH_FULLBAND;
    s.frame_size = 20;
    s.bitrate_type = CVBR;
    s.complexity = 10;
    s.inband_fec = 0;
    s.dtx = 0;
    s.packet_loss_percentage = 0;
    s.max_payload_size = 4000;
    s.audio_type = o.OPUS_APPLICATION_AUDIO;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_audio_encoder_get_type(), "GstOpusEnc", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_tag_setter_get_type(), &info);
            c.g_type_add_interface_static(t, c.gst_preset_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    oc.elementInit();
    return c.gst_element_register(p, "opusenc", c.GST_RANK_PRIMARY, getType()) != 0;
}
