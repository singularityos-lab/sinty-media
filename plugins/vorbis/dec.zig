const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const v = @import("vc.zig").v;
const vc = @import("common.zig");

const FILE = "../ext/vorbis/gstvorbisdec.c";
const SRC_CAPS = "audio/x-raw, format = (string)F32LE, rate = (int) [ 1, MAX ], channels = (int) [ 1, 256 ]";
const MIN_NUM_HEADERS = 3;

const Copy = *const fn (out: [*]f32, in: [*c][*c]f32, samples: usize, channels: usize) void;

const Self = extern struct {
    parent: c.GstAudioDecoder,
    vd: v.vorbis_dsp_state,
    vc: v.vorbis_comment,
    vb: v.vorbis_block,
    vi: v.vorbis_info,
    initialized: c.gboolean,
    info: c.GstAudioInfo,
    copy: ?Copy,
    pending_headers: [*c]c.GList,
};

const Class = extern struct {
    parent: c.GstAudioDecoderClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "audio/x-vorbis");
var once: cm.Once = .{};
var parent_class: ?*c.GObjectClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn adec(s: *Self) *c.GstAudioDecoder {
    return &s.parent;
}

fn copyMono(out: [*]f32, in: [*c][*c]f32, n: usize, _: usize) void {
    @memcpy(out[0..n], in[0][0..n]);
}

fn copyStereo(out: [*]f32, in: [*c][*c]f32, n: usize, _: usize) void {
    var o = out;
    for (0..n) |j| {
        o[0] = in[0][j];
        o[1] = in[1][j];
        o += 2;
    }
}

fn copyReorder(out: [*]f32, in: [*c][*c]f32, n: usize, ch: usize) void {
    var o = out;
    const map = vc.reorder[ch - 1];
    for (0..n) |j| {
        for (0..ch) |i| {
            o[0] = in[map[i]][j];
            o += 1;
        }
    }
}

fn copyPlain(out: [*]f32, in: [*c][*c]f32, n: usize, ch: usize) void {
    var o = out;
    for (0..n) |j| {
        for (0..ch) |i| {
            o[0] = in[i][j];
            o += 1;
        }
    }
}

fn copyFor(ch: c.gint) Copy {
    return switch (ch) {
        1 => copyMono,
        2 => copyStereo,
        3...8 => copyReorder,
        else => copyPlain,
    };
}

fn err(s: *Self, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, debug, FILE, func, line);
}

fn dropPending(s: *Self) void {
    if (s.pending_headers != null) {
        c.g_list_free_full(s.pending_headers, cm.unrefBuffer);
        s.pending_headers = null;
    }
}

fn clearCodec(s: *Self) void {
    _ = v.vorbis_block_clear(&s.vb);
    v.vorbis_dsp_clear(&s.vd);
    v.vorbis_comment_clear(&s.vc);
    v.vorbis_info_clear(&s.vi);
}

fn finalize(ob: [*c]c.GObject) callconv(.c) void {
    clearCodec(me(ob));
    parent_class.?.finalize.?(ob);
}

fn start(d: [*c]c.GstAudioDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    v.vorbis_info_init(&s.vi);
    v.vorbis_comment_init(&s.vc);
    s.initialized = 0;
    return 1;
}

fn stop(d: [*c]c.GstAudioDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    s.initialized = 0;
    clearCodec(s);
    dropPending(s);
    return 1;
}

fn identification(s: *Self) c.GstFlowReturn {
    var info: c.GstAudioInfo = undefined;
    const ch = s.vi.channels;
    if (ch >= 1 and ch <= 8) {
        c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_F32LE, @intCast(s.vi.rate), ch, &vc.default_positions[@intCast(ch - 1)]);
    } else {
        var pos: [64]c.GstAudioChannelPosition = undefined;
        cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("Using NONE channel layout for more than 8 channels"), FILE, "vorbis_handle_identification_packet", 209);
        const n: usize = @intCast(@min(ch, 64));
        for (pos[0..n]) |*p| p.* = c.GST_AUDIO_CHANNEL_POSITION_NONE;
        c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_F32LE, @intCast(s.vi.rate), ch, &pos);
    }
    _ = c.gst_audio_decoder_set_output_format(adec(s), &info);
    s.info = info;
    s.copy = copyFor(info.channels);
    return c.GST_FLOW_OK;
}

fn validBitrate(b: c_long) bool {
    return b > 0 and b != -1;
}

fn comment(s: *Self, p: *v.ogg_packet) c.GstFlowReturn {
    var encoder: [*c]u8 = null;
    var list = c.gst_tag_list_from_vorbiscomment(p.packet, @intCast(p.bytes), "\x03vorbis", 7, &encoder);
    if (list == null) list = c.gst_tag_list_new_empty();
    if (encoder != null) {
        if (encoder[0] != 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_ENCODER, encoder, @as(?*anyopaque, null));
        c.g_free(encoder);
    }
    c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_ENCODER_VERSION, @as(c.guint, @bitCast(s.vi.version)), c.GST_TAG_AUDIO_CODEC, "Vorbis", @as(?*anyopaque, null));
    var bitrate: c.guint = 0;
    if (validBitrate(s.vi.bitrate_nominal)) {
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_NOMINAL_BITRATE, @as(c.guint, @truncate(@as(c_ulong, @bitCast(s.vi.bitrate_nominal)))), @as(?*anyopaque, null));
        bitrate = @truncate(@as(c_ulong, @bitCast(s.vi.bitrate_nominal)));
    }
    if (validBitrate(s.vi.bitrate_upper)) {
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_MAXIMUM_BITRATE, @as(c.guint, @truncate(@as(c_ulong, @bitCast(s.vi.bitrate_upper)))), @as(?*anyopaque, null));
        if (bitrate == 0) bitrate = @truncate(@as(c_ulong, @bitCast(s.vi.bitrate_upper)));
    }
    if (validBitrate(s.vi.bitrate_lower)) {
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_MINIMUM_BITRATE, @as(c.guint, @truncate(@as(c_ulong, @bitCast(s.vi.bitrate_lower)))), @as(?*anyopaque, null));
        if (bitrate == 0) bitrate = @truncate(@as(c_ulong, @bitCast(s.vi.bitrate_lower)));
    }
    if (bitrate != 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_BITRATE, bitrate, @as(?*anyopaque, null));
    c.gst_audio_decoder_merge_tags(adec(s), list, c.GST_TAG_MERGE_REPLACE);
    c.gst_tag_list_unref(list);
    return c.GST_FLOW_OK;
}

fn setup(s: *Self) c.GstFlowReturn {
    var r = v.vorbis_synthesis_init(&s.vd, &s.vi);
    if (r != 0) {
        err(s, c.g_strdup_printf("couldn't initialize synthesis (%d)", r), "vorbis_handle_type_packet", 316);
        return c.GST_FLOW_ERROR;
    }
    r = v.vorbis_block_init(&s.vd, &s.vb);
    if (r != 0) {
        err(s, c.g_strdup_printf("couldn't initialize block (%d)", r), "vorbis_handle_type_packet", 322);
        return c.GST_FLOW_ERROR;
    }
    s.initialized = 1;
    return c.GST_FLOW_OK;
}

fn headerPacket(s: *Self, p: *v.ogg_packet) c.GstFlowReturn {
    p.b_o_s = @intFromBool(p.packet[0] == 1);
    const r = v.vorbis_synthesis_headerin(&s.vi, &s.vc, p);
    if (r != 0) {
        err(s, c.g_strdup_printf("couldn't read header packet (%d)", r), "vorbis_handle_header_packet", 368);
        return c.GST_FLOW_ERROR;
    }
    return switch (p.packet[0]) {
        1 => identification(s),
        3 => comment(s, p),
        5 => setup(s),
        else => c.GST_FLOW_OK,
    };
}

fn wrap(p: *v.ogg_packet, map: *c.GstMapInfo) void {
    p.* = std.mem.zeroes(v.ogg_packet);
    p.packet = map.data;
    p.bytes = @intCast(map.size);
}

fn headerBuffer(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    _ = c.gst_buffer_ref(b);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    var p: v.ogg_packet = undefined;
    wrap(&p, &map);
    const r = headerPacket(s, &p);
    c.gst_buffer_unmap(b, &map);
    c.gst_buffer_unref(b);
    return r;
}

fn headerCaps(s: *Self) c.GstFlowReturn {
    var result: c.GstFlowReturn = c.GST_FLOW_OK;
    const caps = c.gst_pad_get_current_caps(adec(s).sinkpad);
    var st: ?*c.GstStructure = null;
    if (caps != null) st = c.gst_caps_get_structure(caps, 0);
    var arr: [*c]const c.GValue = null;
    if (st) |x| arr = c.gst_structure_get_value(x, "streamheader");
    if (caps != null) c.gst_caps_unref(caps);
    if (arr != null and c.gst_value_array_get_size(arr) >= MIN_NUM_HEADERS) {
        dropPending(s);
        var i: c.guint = 0;
        while (result == c.GST_FLOW_OK and i < c.gst_value_array_get_size(arr)) : (i += 1) {
            const b = c.gst_value_get_buffer(c.gst_value_array_get_value(arr, i));
            if (b == null) {
                result = c.GST_FLOW_ERROR;
                break;
            }
            result = headerBuffer(s, b);
        }
    } else result = c.GST_FLOW_ERROR;
    return if (result != c.GST_FLOW_OK) c.GST_FLOW_NOT_NEGOTIATED else c.GST_FLOW_OK;
}

fn dataPacket(s: *Self, p: *v.ogg_packet) c.GstFlowReturn {
    if (s.initialized == 0) {
        if (headerCaps(s) != c.GST_FLOW_OK) {
            err(s, null, "vorbis_handle_data_packet", 550);
            return c.GST_FLOW_NOT_NEGOTIATED;
        }
    }
    if (v.vorbis_synthesis(&s.vb, p) != 0) {
        err(s, null, "vorbis_handle_data_packet", 556);
        return c.GST_FLOW_ERROR;
    }
    if (v.vorbis_synthesis_blockin(&s.vd, &s.vb) < 0) {
        err(s, null, "vorbis_handle_data_packet", 562);
        return c.GST_FLOW_ERROR;
    }
    var out: [*c]c.GstBuffer = null;
    const n: c_int = v.vorbis_synthesis_pcmout(&s.vd, null);
    if (n != 0) {
        const count: usize = @intCast(n);
        out = c.gst_audio_decoder_allocate_output_buffer(adec(s), count * @as(usize, @intCast(s.info.bpf)));
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(out, &map, c.GST_MAP_WRITE);
        var pcm: [*c][*c]f32 = null;
        if (v.vorbis_synthesis_pcmout(&s.vd, &pcm) != n) {
            c.gst_buffer_unref(out);
            err(s, null, "vorbis_handle_data_packet", 569);
            return c.GST_FLOW_ERROR;
        }
        s.copy.?(@ptrCast(@alignCast(map.data)), pcm, count, @intCast(s.info.channels));
        c.gst_buffer_unmap(out, &map);
    }
    const r = c.gst_audio_decoder_finish_frame(adec(s), out, 1);
    _ = v.vorbis_synthesis_read(&s.vd, n);
    return r;
}

fn firstByte(b: [*c]c.GstBuffer) ?u8 {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &map);
    return if (map.size >= 1) map.data[0] else null;
}

fn resetCodec(s: *Self) void {
    s.initialized = 0;
    clearCodec(s);
    v.vorbis_info_init(&s.vi);
    v.vorbis_comment_init(&s.vc);
}

fn checkPending(s: *Self) c.GstFlowReturn {
    if (c.g_list_length(s.pending_headers) < MIN_NUM_HEADERS) {
        dropPending(s);
        return c.GST_FLOW_OK;
    }
    var l = s.pending_headers;
    const b1: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].data));
    l = l[0].next;
    const b3: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].data));
    l = l[0].next;
    const b5: [*c]c.GstBuffer = @ptrCast(@alignCast(l[0].data));
    if (firstByte(b1) != 1 or firstByte(b3) != 3 or firstByte(b5) != 5) {
        dropPending(s);
        return c.GST_FLOW_OK;
    }
    if (l[0].next != null) {
        c.g_list_free_full(l[0].next, cm.unrefBuffer);
        l[0].next = null;
    }
    c.g_list_free(s.pending_headers);
    s.pending_headers = null;
    resetCodec(s);
    var r = headerBuffer(s, b1);
    c.gst_buffer_unref(b1);
    if (r != c.GST_FLOW_OK) {
        c.gst_buffer_unref(b3);
        c.gst_buffer_unref(b5);
        return r;
    }
    r = headerBuffer(s, b3);
    c.gst_buffer_unref(b3);
    if (r != c.GST_FLOW_OK) {
        c.gst_buffer_unref(b5);
        return r;
    }
    r = headerBuffer(s, b5);
    c.gst_buffer_unref(b5);
    return r;
}

fn handleFrame(d: [*c]c.GstAudioDecoder, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    if (b == null) return c.GST_FLOW_OK;
    const s = me(d);
    _ = c.gst_buffer_ref(b);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer {
        c.gst_buffer_unmap(b, &map);
        c.gst_buffer_unref(b);
    }
    var p: v.ogg_packet = undefined;
    wrap(&p, &map);
    p.granulepos = -1;
    if (p.bytes == 0) {
        if (s.initialized != 0) return c.GST_FLOW_OK;
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("empty header received"), FILE, "vorbis_dec_handle_frame", 768);
        return c.GST_FLOW_ERROR;
    }
    const first = p.packet[0];
    if (first & 1 != 0) {
        if (s.pending_headers != null and first == 1) dropPending(s);
        const all = c.g_list_length(s.pending_headers) >= 2 and first == 5;
        if (s.pending_headers != null or first == 1) s.pending_headers = c.g_list_append(s.pending_headers, c.gst_buffer_ref(b));
        var r = c.gst_audio_decoder_finish_frame(d, null, 1);
        if (r == c.GST_FLOW_OK and all) r = checkPending(s);
        return r;
    }
    if (s.pending_headers != null) {
        const r = checkPending(s);
        if (r != c.GST_FLOW_OK) return r;
    }
    return dataPacket(s, &p);
}

fn flush(d: [*c]c.GstAudioDecoder, _: c.gboolean) callconv(.c) void {
    _ = v.vorbis_synthesis_restart(&me(d).vd);
}

fn setFormat(d: [*c]c.GstAudioDecoder, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(d);
    if (s.initialized == 0) return 1;
    resetCodec(s);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Vorbis audio decoder", "Codec/Decoder/Audio", "decode raw vorbis streams to float audio", "Benjamin Otte <otte@gnome.org>, Chris Lord <chris@openedhand.com>");
    const ac: *c.GstAudioDecoderClass = @ptrCast(@alignCast(k));
    ac.start = start;
    ac.stop = stop;
    ac.set_format = setFormat;
    ac.handle_frame = handleFrame;
    ac.flush = flush;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.gst_audio_decoder_set_use_default_pad_acceptcaps(adec(s), 1);
    cm.obj(adec(s).sinkpad).flags |= c.GST_PAD_FLAG_ACCEPT_TEMPLATE;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_audio_decoder_get_type(), "GstVorbisDec", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    _ = c._gst_debug_category_new("vorbisdec", 0, "vorbis decoding element");
    vc.elementInit();
    return c.gst_element_register(p, "vorbisdec", c.GST_RANK_PRIMARY, getType()) != 0;
}
