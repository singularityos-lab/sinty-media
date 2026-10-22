const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const t = @import("tc.zig").t;

const FILE = "../ext/theora/gsttheoradec.c";
const SRC_CAPS = "video/x-raw, format = (string) { I420, Y42B, Y444 }, framerate = (fraction) [0/1, MAX], width = (int) [ 1, MAX ], height = (int) [ 1, MAX ]";
const DROP = c.GST_FLOW_CUSTOM_SUCCESS_1;
const MIN_NUM_HEADERS = 3;

const PROP_TELEMETRY_MV = 1;
const PROP_TELEMETRY_MBMODE = 2;
const PROP_TELEMETRY_QI = 3;
const PROP_TELEMETRY_BITS = 4;

const Self = extern struct {
    parent: c.GstVideoDecoder,
    info: t.th_info,
    comment: t.th_comment,
    setup: ?*t.th_setup_info,
    decoder: ?*t.th_dec_ctx,
    have_header: c.gboolean,
    need_keyframe: c.gboolean,
    input_state: ?*c.GstVideoCodecState,
    output_state: ?*c.GstVideoCodecState,
    telemetry_mv: c.gint,
    telemetry_mbmode: c.gint,
    telemetry_qi: c.gint,
    telemetry_bits: c.gint,
};

const Class = extern struct {
    parent: c.GstVideoDecoderClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "video/x-theora");
var once: cm.Once = .{};

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn vdec(s: *Self) *c.GstVideoDecoder {
    return &s.parent;
}

fn supported(req: c_int) bool {
    return t.th_decode_ctl(null, req, null, 0) != t.TH_EIMPL;
}

fn err(s: *Self, code: c.gint, debug: [*:0]const u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_stream_error_quark(), code, null, c.g_strdup(debug), FILE, func, line);
}

fn start(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    me(d).have_header = 0;
    return 1;
}

fn stop(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    t.th_info_clear(&s.info);
    t.th_comment_clear(&s.comment);
    if (s.setup) |x| t.th_setup_free(x);
    s.setup = null;
    if (s.decoder) |x| t.th_decode_free(x);
    s.decoder = null;
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = null;
    if (s.output_state) |x| c.gst_video_codec_state_unref(x);
    s.output_state = null;
    return 1;
}

fn flush(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    me(d).need_keyframe = 1;
    return 1;
}

fn parse(d: [*c]c.GstVideoDecoder, frame: [*c]c.GstVideoCodecFrame, a: ?*c.GstAdapter, _: c.gboolean) callconv(.c) c.GstFlowReturn {
    const av = c.gst_adapter_available(a);
    if (av > 0) {
        const data: [*]const u8 = @ptrCast(c.gst_adapter_map(a, 1).?);
        if (data[0] & 0xc0 == 0) frame[0].flags |= c.GST_VIDEO_CODEC_FRAME_FLAG_SYNC_POINT;
        c.gst_adapter_unmap(a);
    }
    c.gst_video_decoder_add_to_frame(d, @intCast(av));
    return c.gst_video_decoder_have_frame(d);
}

fn setFormat(d: [*c]c.GstVideoDecoder, state: [*c]c.GstVideoCodecState) callconv(.c) c.gboolean {
    const s = me(d);
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = c.gst_video_codec_state_ref(state);
    if (state[0].codec_data) |cd| {
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(cd, &map, c.GST_MAP_READ);
        var off: usize = 0;
        var size: usize = map.size;
        var data: [*]const u8 = map.data;
        while (size > 2) {
            var ps: usize = (@as(usize, data[0]) << 8) | data[1];
            data += 2;
            size -= 2;
            off += 2;
            ps = @min(ps, size);
            const b = c.gst_buffer_copy_region(cd, c.GST_BUFFER_COPY_ALL, off, ps);
            if (off == 2) @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags |= c.GST_BUFFER_FLAG_DISCONT;
            _ = decodeBuffer(s, b, null);
            c.gst_buffer_unref(b);
            size -= ps;
            data += ps;
            off += ps;
        }
        c.gst_buffer_unmap(cd, &map);
    }
    return 1;
}

fn commentPacket(s: *Self, p: *t.ogg_packet) c.GstFlowReturn {
    var encoder: [*c]u8 = null;
    var list = c.gst_tag_list_from_vorbiscomment(p.packet, @intCast(p.bytes), "\x81theora", 7, &encoder);
    if (list == null) list = c.gst_tag_list_new_empty();
    if (encoder != null) {
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_ENCODER, encoder, @as(?*anyopaque, null));
        c.g_free(encoder);
    }
    c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_ENCODER_VERSION, @as(c.guint, s.info.version_major), c.GST_TAG_VIDEO_CODEC, "Theora", @as(?*anyopaque, null));
    if (s.info.target_bitrate > 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_BITRATE, @as(c.guint, @intCast(s.info.target_bitrate)), c.GST_TAG_NOMINAL_BITRATE, @as(c.guint, @intCast(s.info.target_bitrate)), @as(?*anyopaque, null));
    c.gst_video_decoder_merge_tags(vdec(s), list, c.GST_TAG_MERGE_REPLACE);
    c.gst_tag_list_unref(list);
    return c.GST_FLOW_OK;
}

fn telemetry(s: *Self, v: *c.gint, req: c_int) void {
    if (v.* != 0) _ = t.th_decode_ctl(s.decoder, req, v, @sizeOf(c.gint));
}

fn typePacket(s: *Self) c.GstFlowReturn {
    var par_n = s.input_state.?.info.par_n;
    var par_d = s.input_state.?.info.par_d;
    if (par_n == 1 and par_d == 1 and s.info.aspect_numerator != 0 and s.info.aspect_denominator != 0) {
        par_n = @intCast(s.info.aspect_numerator);
        par_d = @intCast(s.info.aspect_denominator);
    }
    const fmt: c.GstVideoFormat = switch (s.info.pixel_fmt) {
        t.TH_PF_420 => c.GST_VIDEO_FORMAT_I420,
        t.TH_PF_422 => c.GST_VIDEO_FORMAT_Y42B,
        t.TH_PF_444 => c.GST_VIDEO_FORMAT_Y444,
        else => return c.GST_FLOW_ERROR,
    };
    var w: c.guint = s.info.pic_width;
    var h: c.guint = s.info.pic_height;
    if (s.info.pic_x & 1 != 0 and s.info.pixel_fmt != t.TH_PF_444) w += 1;
    if (s.info.pic_y & 1 != 0 and s.info.pixel_fmt == t.TH_PF_420) h += 1;
    if (w == 0 or h == 0) return c.GST_FLOW_ERROR;
    s.decoder = t.th_decode_alloc(&s.info, s.setup);
    telemetry(s, &s.telemetry_mv, t.TH_DECCTL_SET_TELEMETRY_MV);
    telemetry(s, &s.telemetry_mbmode, t.TH_DECCTL_SET_TELEMETRY_MBMODE);
    telemetry(s, &s.telemetry_qi, t.TH_DECCTL_SET_TELEMETRY_QI);
    telemetry(s, &s.telemetry_bits, t.TH_DECCTL_SET_TELEMETRY_BITS);
    if (s.output_state) |x| c.gst_video_codec_state_unref(x);
    const st = c.gst_video_decoder_set_output_state(vdec(s), fmt, w, h, s.input_state);
    s.output_state = st;
    st[0].info.fps_n = @intCast(s.info.fps_numerator);
    st[0].info.fps_d = @intCast(s.info.fps_denominator);
    st[0].info.par_n = par_n;
    st[0].info.par_d = par_d;
    st[0].info.chroma_site = c.GST_VIDEO_CHROMA_SITE_JPEG;
    st[0].info.colorimetry.range = c.GST_VIDEO_COLOR_RANGE_16_235;
    st[0].info.colorimetry.matrix = c.GST_VIDEO_COLOR_MATRIX_BT601;
    st[0].info.colorimetry.transfer = c.GST_VIDEO_TRANSFER_BT709;
    st[0].info.colorimetry.primaries = switch (s.info.colorspace) {
        t.TH_CS_ITU_REC_470M => c.GST_VIDEO_COLOR_PRIMARIES_BT470M,
        t.TH_CS_ITU_REC_470BG => c.GST_VIDEO_COLOR_PRIMARIES_BT470BG,
        else => c.GST_VIDEO_COLOR_PRIMARIES_UNKNOWN,
    };
    if (c.gst_video_decoder_negotiate(vdec(s)) == 0) return c.GST_FLOW_NOT_NEGOTIATED;
    s.have_header = 1;
    return c.GST_FLOW_OK;
}

fn headerPacket(s: *Self, p: *t.ogg_packet) c.GstFlowReturn {
    if (t.th_decode_headerin(&s.info, &s.comment, &s.setup, p) < 0) {
        err(s, c.GST_STREAM_ERROR_DECODE, "couldn't read header packet", "theora_handle_header_packet", 581);
        return c.GST_FLOW_ERROR;
    }
    return switch (p.packet[0]) {
        0x81 => commentPacket(s, p),
        0x82 => typePacket(s),
        else => c.GST_FLOW_OK,
    };
}

fn headerCaps(s: *Self) c.GstFlowReturn {
    var result: c.GstFlowReturn = DROP;
    const caps = c.gst_pad_get_current_caps(vdec(s).sinkpad);
    var st: ?*c.GstStructure = null;
    if (caps != null) st = c.gst_caps_get_structure(caps, 0);
    var arr: [*c]const c.GValue = null;
    if (st) |x| arr = c.gst_structure_get_value(x, "streamheader");
    if (caps != null) c.gst_caps_unref(caps);
    if (arr != null and c.gst_value_array_get_size(arr) >= MIN_NUM_HEADERS) {
        var i: c.guint = 0;
        while (result == DROP and i < c.gst_value_array_get_size(arr)) : (i += 1) {
            const b = c.gst_value_get_buffer(c.gst_value_array_get_value(arr, i));
            if (b == null) {
                result = c.GST_FLOW_ERROR;
                break;
            }
            result = decodeBuffer(s, b, null);
        }
    } else result = c.GST_FLOW_ERROR;
    return if (result != DROP) c.GST_FLOW_NOT_NEGOTIATED else c.GST_FLOW_OK;
}

fn subScale(sub: c.guint, v: c.gint) c.gint {
    return -((-v) >> @intCast(sub));
}

fn image(s: *Self, buf: *t.th_ycbcr_buffer, frame: [*c]c.GstVideoCodecFrame) c.GstFlowReturn {
    const r = c.gst_video_decoder_allocate_output_frame(vdec(s), frame);
    if (r != c.GST_FLOW_OK) return r;
    var ox: c.gint = @intCast(s.info.pic_x);
    var oy: c.gint = @intCast(s.info.pic_y);
    const pw: c.gint = @intCast(s.info.pic_width);
    const ph: c.gint = @intCast(s.info.pic_height);
    if (ox & 1 != 0 and s.info.pixel_fmt != t.TH_PF_444) ox -= 1;
    if (oy & 1 != 0 and s.info.pixel_fmt == t.TH_PF_420) oy -= 1;
    var vf: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&vf, &s.output_state.?.info, frame[0].output_buffer, c.GST_MAP_WRITE) == 0) return c.GST_FLOW_ERROR;
    const fi = vf.info.finfo;
    for (0..3) |comp| {
        const w = subScale(fi[0].w_sub[comp], pw);
        const h = subScale(fi[0].h_sub[comp], ph);
        const plane = fi[0].plane[comp];
        const stride: usize = @intCast(vf.info.stride[plane]);
        var dst: [*]u8 = @as([*]u8, @ptrCast(vf.data[plane].?)) + fi[0].poffset[comp];
        const sstride: isize = buf[comp].stride;
        var src: [*]const u8 = buf[comp].data;
        const yo: isize = if (h == ph) oy else @divTrunc(oy, 2);
        const xo: isize = if (w == pw) ox else @divTrunc(ox, 2);
        src = @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(@intFromPtr(src))) + yo * sstride + xo)));
        const wu: usize = @intCast(w);
        for (0..@intCast(h)) |_| {
            @memcpy(dst[0..wu], src[0..wu]);
            dst += stride;
            src = @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(@intFromPtr(src))) + sstride)));
        }
    }
    c.gst_video_frame_unmap(&vf);
    return c.GST_FLOW_OK;
}

fn dataPacket(s: *Self, p: *t.ogg_packet, frame: [*c]c.GstVideoCodecFrame) c.GstFlowReturn {
    if (s.have_header == 0) {
        if (headerCaps(s) != c.GST_FLOW_OK) {
            err(s, c.GST_STREAM_ERROR_DECODE, "no header sent yet", "theora_handle_data_packet", 770);
            return c.GST_FLOW_ERROR;
        }
    }
    const key = p.bytes != 0 and p.packet[0] & 0x40 == 0;
    if (key) {
        s.need_keyframe = 0;
    } else if (s.need_keyframe != 0) return DROP;
    var gp: t.ogg_int64_t = 0;
    if (t.th_decode_packetin(s.decoder, p, &gp) < 0) {
        err(s, c.GST_STREAM_ERROR_DECODE, "theora decoder did not decode data packet", "theora_handle_data_packet", 786);
        return c.GST_FLOW_ERROR;
    }
    if (frame != null and c.gst_video_decoder_get_max_decode_time(vdec(s), frame) < 0) return DROP;
    var buf: t.th_ycbcr_buffer = undefined;
    if (t.th_decode_ycbcr_out(s.decoder, &buf) < 0) {
        err(s, c.GST_STREAM_ERROR_DECODE, "couldn't read out YUV image", "theora_handle_data_packet", 792);
        return c.GST_FLOW_ERROR;
    }
    if (buf[0].width != s.info.frame_width or buf[0].height != s.info.frame_height) {
        err(s, c.GST_STREAM_ERROR_FORMAT, "dimensions of image do not match header", "theora_handle_data_packet", 798);
        return c.GST_FLOW_ERROR;
    }
    return image(s, &buf, frame);
}

fn decodeBuffer(s: *Self, b: [*c]c.GstBuffer, frame: [*c]c.GstVideoCodecFrame) c.GstFlowReturn {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &map);
    var p = std.mem.zeroes(t.ogg_packet);
    p.packet = map.data;
    p.bytes = @intCast(map.size);
    p.granulepos = -1;
    p.packetno = 0;
    p.b_o_s = if (s.have_header != 0) 0 else 1;
    p.e_o_s = 0;
    if (p.bytes != 0 and p.packet[0] & 0x80 != 0) {
        if (s.have_header != 0) return DROP;
        const r = headerPacket(s, &p);
        if (r != c.GST_FLOW_OK) return r;
        return DROP;
    }
    return dataPacket(s, &p, frame);
}

fn handleFrame(d: [*c]c.GstVideoDecoder, frame: [*c]c.GstVideoCodecFrame) callconv(.c) c.GstFlowReturn {
    const r = decodeBuffer(me(d), frame[0].input_buffer, frame);
    return switch (r) {
        c.GST_FLOW_OK => c.gst_video_decoder_finish_frame(d, frame),
        DROP => c.gst_video_decoder_drop_frame(d, frame),
        else => blk: {
            c.gst_video_codec_frame_unref(frame);
            break :blk r;
        },
    };
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_TELEMETRY_MV => s.telemetry_mv = c.g_value_get_int(v),
        PROP_TELEMETRY_MBMODE => s.telemetry_mbmode = c.g_value_get_int(v),
        PROP_TELEMETRY_QI => s.telemetry_qi = c.g_value_get_int(v),
        PROP_TELEMETRY_BITS => s.telemetry_bits = c.g_value_get_int(v),
        else => cm.warnInvalid(FILE, ob, id, spec, 892),
    }
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    switch (id) {
        PROP_TELEMETRY_MV => c.g_value_set_int(v, s.telemetry_mv),
        PROP_TELEMETRY_MBMODE => c.g_value_set_int(v, s.telemetry_mbmode),
        PROP_TELEMETRY_QI => c.g_value_set_int(v, s.telemetry_qi),
        PROP_TELEMETRY_BITS => c.g_value_set_int(v, s.telemetry_bits),
        else => cm.warnInvalid(FILE, ob, id, spec, 917),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    if (supported(t.TH_DECCTL_SET_TELEMETRY_MV)) c.g_object_class_install_property(gc, PROP_TELEMETRY_MV, c.g_param_spec_int("visualize-motion-vectors", "Visualize motion vectors", "Show motion vector selection overlaid on image. Value gives a mask for motion vector (MV) modes to show", 0, 0xffff, 0, RW));
    if (supported(t.TH_DECCTL_SET_TELEMETRY_MBMODE)) c.g_object_class_install_property(gc, PROP_TELEMETRY_MBMODE, c.g_param_spec_int("visualize-macroblock-modes", "Visualize macroblock modes", "Show macroblock mode selection overlaid on image. Value gives a mask for macroblock (MB) modes to show", 0, 0xffff, 0, RW));
    if (supported(t.TH_DECCTL_SET_TELEMETRY_QI)) c.g_object_class_install_property(gc, PROP_TELEMETRY_QI, c.g_param_spec_int("visualize-quantization-modes", "Visualize adaptive quantization modes", "Show adaptive quantization mode selection overlaid on image. Value gives a mask for quantization (QI) modes to show", 0, 0xffff, 0, RW));
    if (supported(t.TH_DECCTL_SET_TELEMETRY_BITS)) c.g_object_class_install_property(gc, PROP_TELEMETRY_BITS, c.g_param_spec_int("visualize-bit-usage", "Visualize bitstream usage breakdown", "Sets the bitstream breakdown visualization mode. Values influence the width of the bit usage bars to show", 0, 0xff, 0, RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Theora video decoder", "Codec/Decoder/Video", "decode raw theora streams to raw YUV video", "Benjamin Otte <otte@gnome.org>, Wim Taymans <wim@fluendo.com>");
    const dc: *c.GstVideoDecoderClass = @ptrCast(@alignCast(k));
    dc.start = start;
    dc.stop = stop;
    dc.flush = flush;
    dc.set_format = setFormat;
    dc.parse = parse;
    dc.handle_frame = handleFrame;
    _ = c._gst_debug_category_new("theoradec", 0, "Theora decoder");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.gst_video_decoder_set_packetized(vdec(s), 0);
    c.gst_video_decoder_set_needs_format(vdec(s), 1);
    c.gst_video_decoder_set_use_default_pad_acceptcaps(vdec(s), 1);
    cm.obj(vdec(s).sinkpad).flags |= c.GST_PAD_FLAG_ACCEPT_TEMPLATE;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_video_decoder_get_type(), "GstTheoraDec", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "theoradec", c.GST_RANK_PRIMARY, getType()) != 0;
}
