const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const v = @import("vc.zig").v;
const vc = @import("common.zig");

const SRC_CAPS = "audio/x-vorbis, rate = (int) [ 1, 200000 ], channels = (int) [ 1, 255 ]";

const PROP_MAX_BITRATE = 1;
const PROP_BITRATE = 2;
const PROP_MIN_BITRATE = 3;
const PROP_QUALITY = 4;
const PROP_MANAGED = 5;
const PROP_LAST_MESSAGE = 6;

const QUALITY_DEFAULT: f32 = 0.3;
const LOWEST_BITRATE = 6000;
const HIGHEST_BITRATE = 250001;

const Self = extern struct {
    parent: c.GstAudioEncoder,
    vi: v.vorbis_info,
    vc: v.vorbis_comment,
    vd: v.vorbis_dsp_state,
    vb: v.vorbis_block,
    managed: c.gboolean,
    bitrate: c.gint,
    min_bitrate: c.gint,
    max_bitrate: c.gint,
    quality: f32,
    quality_set: c.gboolean,
    channels: c.gint,
    frequency: c.gint,
    samples_out: u64,
    header_sent: c.gboolean,
    tags: ?*c.GstTagList,
    setup: c.gboolean,
    last_message: [*c]u8,
    long_size: c.gint,
    short_size: c.gint,
    last_size: c.gint,
    log2_modes: c.gint,
    mode_sizes: [256]c.gint,
};

const Class = extern struct {
    parent: c.GstAudioEncoderClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var once: cm.Once = .{};
var parent_class: ?*c.GstAudioEncoderClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn aenc(s: *Self) *c.GstAudioEncoder {
    return &s.parent;
}

fn sinkCaps() [*c]c.GstCaps {
    const caps = c.gst_caps_new_empty();
    c.gst_caps_append_structure(caps, c.gst_structure_new("audio/x-raw", "format", c.G_TYPE_STRING, "F32LE", "layout", c.G_TYPE_STRING, "interleaved", "rate", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, 200000), "channels", c.G_TYPE_INT, @as(c.gint, 1), @as(?*anyopaque, null)));
    var i: usize = 2;
    while (i <= 8) : (i += 1) {
        var mask: u64 = 0;
        for (vc.positions[i - 1][0..i]) |p| mask |= @as(u64, 1) << @intCast(p);
        c.gst_caps_append_structure(caps, c.gst_structure_new("audio/x-raw", "format", c.G_TYPE_STRING, "F32LE", "layout", c.G_TYPE_STRING, "interleaved", "rate", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, 200000), "channels", c.G_TYPE_INT, @as(c.gint, @intCast(i)), "channel-mask", c.gst_bitmask_get_type(), mask, @as(?*anyopaque, null)));
    }
    c.gst_caps_append_structure(caps, c.gst_structure_new("audio/x-raw", "format", c.G_TYPE_STRING, "F32LE", "layout", c.G_TYPE_STRING, "interleaved", "rate", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, 200000), "channels", c.gst_int_range_get_type(), @as(c.gint, 9), @as(c.gint, 255), "channel-mask", c.gst_bitmask_get_type(), @as(u64, 0), @as(?*anyopaque, null)));
    return caps;
}

fn start(e: [*c]c.GstAudioEncoder) callconv(.c) c.gboolean {
    const s = me(e);
    s.tags = c.gst_tag_list_new_empty();
    s.header_sent = 0;
    s.last_size = 0;
    return 1;
}

fn stop(e: [*c]c.GstAudioEncoder) callconv(.c) c.gboolean {
    const s = me(e);
    _ = v.vorbis_block_clear(&s.vb);
    v.vorbis_dsp_clear(&s.vd);
    v.vorbis_info_clear(&s.vi);
    c.g_free(s.last_message);
    s.last_message = null;
    if (s.tags) |t| c.gst_tag_list_unref(t);
    s.tags = null;
    c.gst_tag_setter_reset_tags(@ptrCast(s));
    return 1;
}

fn constraints(s: *Self) [*c]u8 {
    const lo = s.min_bitrate;
    const hi = s.max_bitrate;
    if (lo > 0 and hi > 0) return c.g_strdup_printf("(min %d bps, max %d bps)", lo, hi);
    if (lo > 0) return c.g_strdup_printf("(min %d bps, no max)", lo);
    if (hi > 0) return c.g_strdup_printf("(no min, max %d bps)", hi);
    return c.g_strdup_printf("(no min or max)");
}

fn startMessage(s: *Self) void {
    c.g_free(s.last_message);
    if (s.bitrate > 0) {
        if (s.managed != 0) {
            const k = constraints(s);
            s.last_message = c.g_strdup_printf("encoding at average bitrate %d bps %s", s.bitrate, k);
            c.g_free(k);
        } else s.last_message = c.g_strdup_printf("encoding at approximate bitrate %d bps (VBR encoding enabled)", s.bitrate);
    } else if (s.quality_set != 0) {
        if (s.managed != 0) {
            const k = constraints(s);
            s.last_message = c.g_strdup_printf("encoding at quality level %2.2f using constrained VBR %s", @as(f64, s.quality), k);
            c.g_free(k);
        } else s.last_message = c.g_strdup_printf("encoding at quality level %2.2f", @as(f64, s.quality));
    } else {
        const k = constraints(s);
        s.last_message = c.g_strdup_printf("encoding using bitrate management %s", k);
        c.g_free(k);
    }
    c.g_object_notify(@ptrCast(s), "last_message");
}

fn setupEncoder(s: *Self) bool {
    if (s.bitrate < 0 and s.min_bitrate < 0 and s.max_bitrate < 0) s.quality_set = 1;
    startMessage(s);
    v.vorbis_info_init(&s.vi);
    if (s.quality_set != 0) {
        if (v.vorbis_encode_setup_vbr(&s.vi, s.channels, s.frequency, s.quality) != 0) {
            v.vorbis_info_clear(&s.vi);
            return false;
        }
        if (s.max_bitrate > 0 or s.min_bitrate > 0) {
            var ai: v.ovectl_ratemanage_arg = undefined;
            _ = v.vorbis_encode_ctl(&s.vi, v.OV_ECTL_RATEMANAGE_GET, &ai);
            ai.bitrate_hard_min = s.min_bitrate;
            ai.bitrate_hard_max = s.max_bitrate;
            ai.management_active = 1;
            _ = v.vorbis_encode_ctl(&s.vi, v.OV_ECTL_RATEMANAGE_SET, &ai);
        }
    } else {
        const lo: c_long = if (s.min_bitrate > 0) s.min_bitrate else -1;
        const hi: c_long = if (s.max_bitrate > 0) s.max_bitrate else -1;
        if (v.vorbis_encode_setup_managed(&s.vi, s.channels, s.frequency, hi, s.bitrate, lo) != 0) {
            v.vorbis_info_clear(&s.vi);
            return false;
        }
    }
    if (s.managed != 0 and s.bitrate < 0) {
        _ = v.vorbis_encode_ctl(&s.vi, v.OV_ECTL_RATEMANAGE_AVG, null);
    } else if (s.managed == 0) {
        _ = v.vorbis_encode_ctl(&s.vi, v.OV_ECTL_RATEMANAGE_SET, null);
    }
    _ = v.vorbis_encode_setup_init(&s.vi);
    _ = v.vorbis_analysis_init(&s.vd, &s.vi);
    _ = v.vorbis_block_init(&s.vd, &s.vb);
    s.samples_out = 0;
    s.setup = 1;
    return true;
}

fn setFormat(e: [*c]c.GstAudioEncoder, info: [*c]c.GstAudioInfo) callconv(.c) c.gboolean {
    const s = me(e);
    s.channels = info[0].channels;
    s.frequency = info[0].rate;
    s.header_sent = 0;
    if (!setupEncoder(s)) return 0;
    c.gst_audio_encoder_set_latency(e, 58 * @as(u64, c.GST_MSECOND), 58 * @as(u64, c.GST_MSECOND));
    return 1;
}

fn addComment(list: ?*const c.GstTagList, tag: [*c]const u8, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const all = c.gst_tag_to_vorbis_comments(list, tag);
    var l = all;
    while (l != null) : (l = l[0].next) {
        var key: [*c]u8 = null;
        var val: [*c]u8 = null;
        if (c.gst_tag_parse_extended_comment(@ptrCast(l[0].data), &key, null, &val, 1) != 0) {
            v.vorbis_comment_add_tag(&s.vc, key, val);
            c.g_free(key);
            c.g_free(val);
        }
    }
    c.g_list_free_full(all, c.g_free);
}

fn metadata(s: *Self) void {
    v.vorbis_comment_init(&s.vc);
    const user = c.gst_tag_setter_get_tag_list(@ptrCast(s));
    const merged = c.gst_tag_list_merge(user, s.tags, c.gst_tag_setter_get_tag_merge_mode(@ptrCast(s)));
    if (merged != null) {
        c.gst_tag_list_foreach(merged, addComment, s);
        c.gst_tag_list_unref(merged);
    }
}

fn clear(s: *Self) c.GstFlowReturn {
    var r: c.GstFlowReturn = c.GST_FLOW_OK;
    if (s.setup != 0) {
        _ = v.vorbis_analysis_wrote(&s.vd, 0);
        r = output(s);
        s.setup = 0;
    }
    _ = v.vorbis_block_clear(&s.vb);
    v.vorbis_dsp_clear(&s.vd);
    v.vorbis_info_clear(&s.vi);
    return r;
}

fn flush(e: [*c]c.GstAudioEncoder) callconv(.c) void {
    const s = me(e);
    _ = clear(s);
    s.header_sent = 0;
}

fn duration(s: *Self, p: *v.ogg_packet) i64 {
    if (p.bytes == 0 or p.packet[0] & 1 != 0) return 0;
    const mask = (@as(c_int, 1) << @intCast(s.log2_modes)) - 1;
    const mode: usize = @intCast((@as(c_int, p.packet[0]) >> 1) & mask);
    const size = if (s.mode_sizes[mode] != 0) s.long_size else s.short_size;
    const d: i64 = if (s.last_size == 0) 0 else @divTrunc(s.last_size, 4) + @divTrunc(size, 4);
    s.last_size = size;
    return d;
}

fn idHeader(s: *Self, p: *v.ogg_packet) void {
    s.long_size = @as(c.gint, 1) << @intCast(p.packet[28] >> 4);
    s.short_size = @as(c.gint, 1) << @intCast(p.packet[28] & 0xf);
}

fn setupHeader(s: *Self, p: *v.ogg_packet) void {
    var pos: [*c]u8 = &p.packet[@intCast(p.bytes - 1)];
    var size: c.gint = 0;
    var off: u3 = 0;
    var bit: c.gint = 8;
    while (true) {
        bit -= 1;
        if ((@as(c.gint, 1) << @intCast(bit)) & pos[0] != 0) break;
        if (bit == 0) {
            bit = 8;
            pos -= 1;
        }
    }
    off = @intCast(bit);
    while (true) {
        off = @intCast((@as(u8, off) + 7) % 8);
        if (off == 7) pos -= 1;
        const hiMask: c.gint = (@as(c.gint, 1) << (@as(u5, off) + 1)) - 1;
        if ((@as(c.gint, (pos - 5)[0]) & ~hiMask) != 0 or (pos - 4)[0] != 0 or (pos - 3)[0] != 0 or (pos - 2)[0] != 0 or (@as(c.gint, (pos - 1)[0]) & hiMask) != 0) break;
        size += 1;
        pos -= 5;
    }
    for (0..2) |_| {
        var check: c.gint = undefined;
        if (off > 4) {
            check = (@as(c.gint, pos[0]) >> (@as(u5, off) - 5)) & 0x3f;
        } else {
            check = @as(c.gint, pos[0]) & ((@as(c.gint, 1) << (@as(u5, off) + 1)) - 1);
            check <<= @intCast(5 - @as(u5, off));
            check |= (@as(c.gint, (pos - 1)[0]) & ~((@as(c.gint, 1) << (@as(u5, off) + 3)) - 1)) >> (@as(u5, off) + 3);
        }
        check += 1;
        if (check == size) break;
        off = @intCast((@as(u8, off) + 1) % 8);
        if (off == 0) pos += 1;
        pos += 5;
        size -= 1;
    }
    var i: c.gint = 0;
    while ((@as(c.gint, 1) << @intCast(i)) < size) i += 1;
    s.log2_modes = i;
    const n: usize = @intCast(@max(size, 0));
    for (0..@min(n, s.mode_sizes.len)) |k| {
        off = @intCast((@as(u8, off) + 1) % 8);
        if (off == 0) pos += 1;
        s.mode_sizes[k] = (@as(c.gint, pos[0]) >> off) & 1;
        pos += 5;
    }
}

fn headerBuffer(s: *Self, p: *v.ogg_packet) [*c]c.GstBuffer {
    if (p.bytes > 0 and p.packet[0] == 1) {
        idHeader(s, p);
    } else if (p.bytes > 0 and p.packet[0] == 5) setupHeader(s, p);
    const b = c.gst_audio_encoder_allocate_output_buffer(aenc(s), @intCast(p.bytes));
    _ = c.gst_buffer_fill(b, 0, p.packet, @intCast(p.bytes));
    b[0].offset = 0;
    b[0].offset_end = 0;
    b[0].pts = c.GST_CLOCK_TIME_NONE;
    b[0].duration = c.GST_CLOCK_TIME_NONE;
    @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags |= c.GST_BUFFER_FLAG_HEADER;
    return b;
}

fn sinkEvent(e: [*c]c.GstAudioEncoder, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(e);
    if (cm.eventType(ev) == c.GST_EVENT_TAG) {
        if (s.tags) |t| {
            var list: ?*c.GstTagList = null;
            c.gst_event_parse_tag(ev, &list);
            c.gst_tag_list_insert(t, list, c.gst_tag_setter_get_tag_merge_mode(@ptrCast(s)));
        }
    }
    return parent_class.?.sink_event.?(e, ev);
}

fn appendBuffer(arr: *c.GValue, b: [*c]c.GstBuffer) void {
    var val = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&val, c.gst_buffer_get_type());
    c.gst_value_set_buffer(&val, b);
    c.gst_value_array_append_value(arr, &val);
    c.g_value_unset(&val);
}

fn handleFrame(e: [*c]c.GstAudioEncoder, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(e);
    if (s.setup == 0) {
        if (b == null) return c.GST_FLOW_OK;
        if (!setupEncoder(s)) return c.GST_FLOW_ERROR;
    }
    if (s.header_sent == 0) {
        var h1: v.ogg_packet = undefined;
        var h2: v.ogg_packet = undefined;
        var h3: v.ogg_packet = undefined;
        metadata(s);
        _ = v.vorbis_analysis_headerout(&s.vd, &s.vc, &h1, &h2, &h3);
        v.vorbis_comment_clear(&s.vc);
        const b1 = headerBuffer(s, &h1);
        const b2 = headerBuffer(s, &h2);
        const b3 = headerBuffer(s, &h3);
        var caps = c.gst_caps_new_simple("audio/x-vorbis", "rate", c.G_TYPE_INT, s.frequency, "channels", c.G_TYPE_INT, s.channels, @as(?*anyopaque, null));
        caps = c.gst_caps_make_writable(caps);
        var arr = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&arr, c.gst_value_array_get_type());
        appendBuffer(&arr, b1);
        appendBuffer(&arr, b2);
        appendBuffer(&arr, b3);
        c.gst_structure_take_value(c.gst_caps_get_structure(caps, 0), "streamheader", &arr);
        _ = c.gst_audio_encoder_set_output_format(e, caps);
        c.gst_caps_unref(caps);
        var headers: [*c]c.GList = null;
        headers = c.g_list_prepend(headers, b3);
        headers = c.g_list_prepend(headers, b2);
        headers = c.g_list_prepend(headers, b1);
        c.gst_audio_encoder_set_headers(e, headers);
        s.header_sent = 1;
    }
    if (b == null) return clear(s);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const ch: usize = @intCast(s.channels);
    const n = map.size / (ch * @sizeOf(f32));
    var ptr: [*]const f32 = @ptrCast(@alignCast(map.data));
    const dst = v.vorbis_analysis_buffer(&s.vd, @intCast(n));
    if (ch < 2 or ch > 8) {
        for (0..n) |i| {
            for (0..ch) |j| {
                dst[j][i] = ptr[0];
                ptr += 1;
            }
        }
    } else {
        const map_ = vc.reorder[ch - 1];
        for (0..n) |i| {
            for (0..ch) |j| dst[map_[j]][i] = ptr[j];
            ptr += ch;
        }
    }
    _ = v.vorbis_analysis_wrote(&s.vd, @intCast(n));
    c.gst_buffer_unmap(b, &map);
    return output(s);
}

fn output(s: *Self) c.GstFlowReturn {
    while (v.vorbis_analysis_blockout(&s.vd, &s.vb) == 1) {
        _ = v.vorbis_analysis(&s.vb, null);
        _ = v.vorbis_bitrate_addblock(&s.vb);
        var op: v.ogg_packet = undefined;
        while (v.vorbis_bitrate_flushpacket(&s.vd, &op) != 0) {
            const b = c.gst_audio_encoder_allocate_output_buffer(aenc(s), @intCast(op.bytes));
            _ = c.gst_buffer_fill(b, 0, op.packet, @intCast(op.bytes));
            const d = duration(s, &op);
            if (op.e_o_s != 0) {
                const samples: i64 = op.granulepos - @as(i64, @bitCast(s.samples_out));
                if (samples < d) _ = c.gst_buffer_add_audio_clipping_meta(b, c.GST_FORMAT_DEFAULT, 0, @bitCast(d - samples));
            }
            const r = c.gst_audio_encoder_finish_frame(aenc(s), b, @intCast(op.granulepos - @as(i64, @bitCast(s.samples_out))));
            s.samples_out = @bitCast(op.granulepos);
            if (r != c.GST_FLOW_OK) return r;
        }
    }
    return c.GST_FLOW_OK;
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, val: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_MAX_BITRATE => c.g_value_set_int(val, s.max_bitrate),
        PROP_BITRATE => c.g_value_set_int(val, s.bitrate),
        PROP_MIN_BITRATE => c.g_value_set_int(val, s.min_bitrate),
        PROP_QUALITY => c.g_value_set_float(val, s.quality),
        PROP_MANAGED => c.g_value_set_boolean(val, s.managed),
        PROP_LAST_MESSAGE => c.g_value_set_string(val, s.last_message),
        else => cm.warnInvalid("../ext/vorbis/gstvorbisenc.c", ob, id, spec, 1039),
    }
}

fn lowest(p: *c.gint) void {
    if (p.* >= 0 and p.* < LOWEST_BITRATE) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "Lowest allowed bitrate is %d", @as(c_int, LOWEST_BITRATE));
        p.* = LOWEST_BITRATE;
    }
}

fn updateManaged(s: *Self, ob: [*c]c.GObject, old: c.gboolean) void {
    s.managed = @intFromBool(s.min_bitrate > 0 and s.max_bitrate > 0);
    if (old != s.managed) c.g_object_notify(ob, "managed");
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, val: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_MAX_BITRATE => {
            const old = s.managed;
            s.max_bitrate = c.g_value_get_int(val);
            lowest(&s.max_bitrate);
            updateManaged(s, ob, old);
        },
        PROP_BITRATE => {
            s.bitrate = c.g_value_get_int(val);
            lowest(&s.bitrate);
        },
        PROP_MIN_BITRATE => {
            const old = s.managed;
            s.min_bitrate = c.g_value_get_int(val);
            lowest(&s.min_bitrate);
            updateManaged(s, ob, old);
        },
        PROP_QUALITY => {
            s.quality = c.g_value_get_float(val);
            s.quality_set = @intFromBool(s.quality >= 0.0);
        },
        PROP_MANAGED => s.managed = c.g_value_get_boolean(val),
        else => cm.warnInvalid("../ext/vorbis/gstvorbisenc.c", ob, id, spec, 1111),
    }
}

fn dispose(ob: [*c]c.GObject) callconv(.c) void {
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).dispose.?(ob);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    gc.dispose = dispose;
    const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, PROP_MAX_BITRATE, c.g_param_spec_int("max-bitrate", "Maximum Bitrate", "Specify a maximum bitrate (in bps). Useful for streaming applications. (-1 == disabled)", -1, HIGHEST_BITRATE, -1, RW));
    c.g_object_class_install_property(gc, PROP_BITRATE, c.g_param_spec_int("bitrate", "Target Bitrate", "Attempt to encode at a bitrate averaging this (in bps). This uses the bitrate management engine, and is not recommended for most users. Quality is a better alternative. (-1 == disabled)", -1, HIGHEST_BITRATE, -1, RW));
    c.g_object_class_install_property(gc, PROP_MIN_BITRATE, c.g_param_spec_int("min-bitrate", "Minimum Bitrate", "Specify a minimum bitrate (in bps). Useful for encoding for a fixed-size channel. (-1 == disabled)", -1, HIGHEST_BITRATE, -1, RW));
    c.g_object_class_install_property(gc, PROP_QUALITY, c.g_param_spec_float("quality", "Quality", "Specify quality instead of specifying a particular bitrate.", -0.1, 1.0, QUALITY_DEFAULT, RW));
    c.g_object_class_install_property(gc, PROP_MANAGED, c.g_param_spec_boolean("managed", "Managed", "Enable bitrate management engine", 0, RW));
    c.g_object_class_install_property(gc, PROP_LAST_MESSAGE, c.g_param_spec_string("last-message", "last-message", "The last status message", null, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const caps = sinkCaps();
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "Vorbis audio encoder", "Codec/Encoder/Audio", "Encodes audio in Vorbis format", "Monty <monty@xiph.org>, Wim Taymans <wim@fluendo.com>");
    const ac: *c.GstAudioEncoderClass = @ptrCast(@alignCast(k));
    ac.start = start;
    ac.stop = stop;
    ac.set_format = setFormat;
    ac.handle_frame = handleFrame;
    ac.sink_event = sinkEvent;
    ac.flush = flush;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    cm.obj(aenc(s).sinkpad).flags |= c.GST_PAD_FLAG_ACCEPT_TEMPLATE;
    s.channels = -1;
    s.frequency = -1;
    s.managed = 0;
    s.max_bitrate = -1;
    s.bitrate = -1;
    s.min_bitrate = -1;
    s.quality = QUALITY_DEFAULT;
    s.quality_set = 0;
    s.last_message = null;
    c.gst_audio_encoder_set_mark_granule(aenc(s), 1);
    c.gst_audio_encoder_set_perfect_timestamp(aenc(s), 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_audio_encoder_get_type(), "GstVorbisEnc", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_tag_setter_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    _ = c._gst_debug_category_new("vorbisenc", 0, "vorbis encoding element");
    vc.elementInit();
    return c.gst_element_register(p, "vorbisenc", c.GST_RANK_PRIMARY, getType()) != 0;
}
