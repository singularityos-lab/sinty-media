const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const v = @import("vc.zig").v;
const dsp = @import("display.zig");
const vp9 = @import("vp9.zig");

const FILE = "../sys/va/gstvavp9dec.c";
const SINK_CAPS = "video/x-vp9, profile = (string) { 0, 2 }";
const SRC_CAPS = "video/x-raw, format = (string) { NV12, P010_10LE }, width = (int) [ 1, MAX ], height = (int) [ 1, MAX ], framerate = (fraction) [ 0, MAX ]";

const Pic = extern struct {
    frame_width: u16,
    frame_height: u16,
    reference_frames: [8]u32,
    pic_fields: u32,
    filter_level: u8,
    sharpness_level: u8,
    log2_tile_rows: u8,
    log2_tile_columns: u8,
    frame_header_length_in_bytes: u8,
    first_partition_size: u16,
    mb_segment_tree_probs: [7]u8,
    segment_pred_probs: [3]u8,
    profile: u8,
    bit_depth: u8,
    va_reserved: [8]u32 = .{0} ** 8,
};

const SegmentParam = extern struct {
    flags: u16,
    filter_level: [4][2]u8,
    luma_ac: i16,
    luma_dc: i16,
    chroma_ac: i16,
    chroma_dc: i16,
    va_reserved: [4]u32 = .{0} ** 4,
};

const Slice = extern struct {
    size: u32,
    offset: u32,
    flag: u32,
    seg: [8]SegmentParam,
    va_reserved: [4]u32 = .{0} ** 4,
};

comptime {
    std.debug.assert(@offsetOf(Pic, "first_partition_size") == 46);
    std.debug.assert(@sizeOf(Pic) == 92);
    std.debug.assert(@sizeOf(SegmentParam) == 36);
    std.debug.assert(@sizeOf(Slice) == 316);
}

const Priv = struct {
    display: dsp.Display,
    session: dsp.Session = .{},
    state: vp9.State = .{},
    refs: [8]u32 = .{dsp.INVALID} ** 8,
    out_width: u32 = 0,
    out_height: u32 = 0,
    out_format: c.GstVideoFormat = c.GST_VIDEO_FORMAT_UNKNOWN,
    frame: ?*c.GstVideoCodecFrame = null,
};

const Self = extern struct {
    parent: c.GstVideoDecoder,
    priv: ?*Priv,
    input_state: ?*c.GstVideoCodecState,
    output_state: ?*c.GstVideoCodecState,
};

const Class = extern struct {
    parent: c.GstVideoDecoderClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, SINK_CAPS);
var once: cm.Once = .{};

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn vdec(s: *Self) *c.GstVideoDecoder {
    return &s.parent;
}

fn err(s: *Self, code: c.gint, debug: [*:0]const u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_stream_error_quark(), code, null, c.g_strdup(debug), FILE, func, line);
}

fn start(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    const display = dsp.Display.open() orelse {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ_WRITE, null, c.g_strdup("no VA display"), FILE, "gst_va_vp9_dec_open", 120);
        return 0;
    };
    const p = std.heap.c_allocator.create(Priv) catch return 0;
    p.* = .{ .display = display };
    s.priv = p;
    return 1;
}

fn stop(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    if (s.priv) |p| {
        p.session.destroy(&p.display);
        p.display.close();
        std.heap.c_allocator.destroy(p);
    }
    s.priv = null;
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = null;
    if (s.output_state) |x| c.gst_video_codec_state_unref(x);
    s.output_state = null;
    return 1;
}

fn flush(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    const p = me(d).priv orelse return 1;
    p.refs = .{dsp.INVALID} ** 8;
    p.state = .{};
    return 1;
}

fn setFormat(d: [*c]c.GstVideoDecoder, state: [*c]c.GstVideoCodecState) callconv(.c) c.gboolean {
    const s = me(d);
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = c.gst_video_codec_state_ref(state);
    return 1;
}

fn profileOf(fr: *const vp9.Frame) ?struct { va: v.VAProfile, rt: c_uint, fourcc: u32, format: c.GstVideoFormat, bpp: usize } {
    return switch (fr.profile) {
        0 => .{ .va = v.VAProfileVP9Profile0, .rt = v.VA_RT_FORMAT_YUV420, .fourcc = v.VA_FOURCC_NV12, .format = c.GST_VIDEO_FORMAT_NV12, .bpp = 1 },
        2 => .{ .va = v.VAProfileVP9Profile2, .rt = v.VA_RT_FORMAT_YUV420_10, .fourcc = v.VA_FOURCC_P010, .format = c.GST_VIDEO_FORMAT_P010_10LE, .bpp = 2 },
        else => null,
    };
}

fn freeSurface(p: *const Priv) u32 {
    for (p.session.surfaces) |sf| {
        if (std.mem.indexOfScalar(u32, &p.refs, sf) == null) return sf;
    }
    return dsp.INVALID;
}

fn fields(fr: *const vp9.Frame, st: *const vp9.State) u32 {
    var f: u32 = 0;
    const set = struct {
        fn bit(acc: *u32, on: bool, at: u5) void {
            if (on) acc.* |= @as(u32, 1) << at;
        }
        fn val(acc: *u32, x: u32, at: u5) void {
            acc.* |= x << at;
        }
    };
    set.bit(&f, st.subsampling_x, 0);
    set.bit(&f, st.subsampling_y, 1);
    set.bit(&f, !fr.key, 2);
    set.bit(&f, fr.show, 3);
    set.bit(&f, fr.error_resilient, 4);
    set.bit(&f, fr.intra_only, 5);
    set.bit(&f, fr.high_precision_mv, 6);
    set.val(&f, fr.interp_filter, 7);
    set.bit(&f, fr.parallel, 10);
    set.val(&f, fr.reset_context, 11);
    set.bit(&f, fr.refresh_context, 13);
    set.val(&f, if (fr.key or fr.intra_only) 0 else fr.context_idx, 14);
    set.bit(&f, fr.seg_enabled, 16);
    set.bit(&f, fr.seg_temporal, 17);
    set.bit(&f, fr.seg_update_map, 18);
    set.val(&f, fr.ref_idx[0], 19);
    set.bit(&f, fr.sign_bias[0], 22);
    set.val(&f, fr.ref_idx[1], 23);
    set.bit(&f, fr.sign_bias[1], 26);
    set.val(&f, fr.ref_idx[2], 27);
    set.bit(&f, fr.sign_bias[2], 30);
    set.bit(&f, fr.lossless, 31);
    return f;
}

fn decodeOne(s: *Self, p: *Priv, fr: *const vp9.Frame, data: []const u8) c.GstFlowReturn {
    const prof = profileOf(fr) orelse {
        err(s, c.GST_STREAM_ERROR_DECODE, "unsupported VP9 profile", "gst_va_vp9_dec_new_sequence", 200);
        return c.GST_FLOW_NOT_NEGOTIATED;
    };
    if (!p.session.ready(fr.width, fr.height, prof.rt)) {
        if (!fr.key and !fr.intra_only and p.session.context != dsp.INVALID) {
            err(s, c.GST_STREAM_ERROR_DECODE, "reference scaling is not supported", "gst_va_vp9_dec_new_sequence", 214);
            return c.GST_FLOW_ERROR;
        }
        p.refs = .{dsp.INVALID} ** 8;
        if (!p.session.create(&p.display, prof.va, fr.width, fr.height, prof.rt)) {
            err(s, c.GST_STREAM_ERROR_DECODE, "could not create the VA decoder", "gst_va_vp9_dec_new_sequence", 230);
            return c.GST_FLOW_ERROR;
        }
    }
    if (!fr.key and !fr.intra_only) {
        for (fr.ref_idx) |i| {
            if (p.refs[i] == dsp.INVALID) return c.GST_FLOW_CUSTOM_SUCCESS;
        }
    }
    const target = freeSurface(p);
    if (target == dsp.INVALID) return c.GST_FLOW_ERROR;
    var pic = Pic{
        .frame_width = @intCast(fr.width),
        .frame_height = @intCast(fr.height),
        .reference_frames = p.refs,
        .pic_fields = fields(fr, &p.state),
        .filter_level = fr.filter_level,
        .sharpness_level = fr.sharpness,
        .log2_tile_rows = fr.tile_rows_log2,
        .log2_tile_columns = fr.tile_cols_log2,
        .frame_header_length_in_bytes = @intCast(fr.header_bytes),
        .first_partition_size = @intCast(fr.compressed_bytes),
        .mb_segment_tree_probs = fr.tree_probs,
        .segment_pred_probs = fr.pred_probs,
        .profile = fr.profile,
        .bit_depth = p.state.bit_depth,
    };
    var slice = Slice{ .size = @intCast(data.len), .offset = 0, .flag = v.VA_SLICE_DATA_FLAG_ALL, .seg = undefined };
    for (&slice.seg, fr.segments) |*dst, sg| {
        var flags: u16 = 0;
        if (sg.reference_enabled) flags |= 1;
        flags |= @as(u16, sg.reference) << 1;
        if (sg.skipped) flags |= 8;
        dst.* = .{ .flags = flags, .filter_level = sg.filter_level, .luma_ac = sg.luma_ac, .luma_dc = sg.luma_dc, .chroma_ac = sg.chroma_ac, .chroma_dc = sg.chroma_dc };
    }
    const bufs = [_]dsp.Buffer{
        .{ .kind = v.VAPictureParameterBufferType, .data = dsp.bytesOf(&pic) },
        .{ .kind = v.VASliceParameterBufferType, .data = dsp.bytesOf(&slice) },
        .{ .kind = v.VASliceDataBufferType, .data = data },
    };
    if (!p.session.submit(&p.display, target, &bufs)) {
        err(s, c.GST_STREAM_ERROR_DECODE, "VA decoding failed", "gst_va_vp9_dec_decode_picture", 300);
        return c.GST_FLOW_ERROR;
    }
    for (0..8) |i| {
        if (fr.refresh_flags & (@as(u8, 1) << @intCast(i)) != 0) p.refs[i] = target;
    }
    p.state.update(fr);
    return if (fr.show) output(s, p, target, fr.width, fr.height, prof.format, prof.fourcc, prof.bpp) else c.GST_FLOW_CUSTOM_SUCCESS;
}

fn output(s: *Self, p: *Priv, surface: u32, width: u32, height: u32, format: c.GstVideoFormat, fourcc: u32, bpp: usize) c.GstFlowReturn {
    if (p.out_width != width or p.out_height != height or p.out_format != format or s.output_state == null) {
        if (s.output_state) |x| c.gst_video_codec_state_unref(x);
        s.output_state = c.gst_video_decoder_set_output_state(vdec(s), format, width, height, s.input_state);
        if (c.gst_video_decoder_negotiate(vdec(s)) == 0) return c.GST_FLOW_NOT_NEGOTIATED;
        p.out_width = width;
        p.out_height = height;
        p.out_format = format;
    }
    const frame = p.frame orelse return c.GST_FLOW_ERROR;
    const r = c.gst_video_decoder_allocate_output_frame(vdec(s), frame);
    if (r != c.GST_FLOW_OK) return r;
    var vf: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&vf, &s.output_state.?.info, frame.output_buffer, c.GST_MAP_WRITE) == 0) return c.GST_FLOW_ERROR;
    defer c.gst_video_frame_unmap(&vf);
    const planes = [2]dsp.Plane{
        .{ .data = @ptrCast(vf.data[0].?), .stride = @intCast(vf.info.stride[0]) },
        .{ .data = @ptrCast(vf.data[1].?), .stride = @intCast(vf.info.stride[1]) },
    };
    if (!dsp.download(&p.display, surface, fourcc, width, height, planes, bpp)) {
        err(s, c.GST_STREAM_ERROR_DECODE, "could not read the decoded picture", "gst_va_base_dec_copy_output_buffer", 400);
        return c.GST_FLOW_ERROR;
    }
    return c.GST_FLOW_OK;
}

fn handleFrame(d: [*c]c.GstVideoDecoder, frame: [*c]c.GstVideoCodecFrame) callconv(.c) c.GstFlowReturn {
    const s = me(d);
    const p = s.priv orelse return c.GST_FLOW_ERROR;
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(frame[0].input_buffer, &map, c.GST_MAP_READ) == 0) return c.GST_FLOW_ERROR;
    const data: []const u8 = map.data[0..map.size];
    p.frame = frame;
    defer p.frame = null;
    var shown = false;
    var r: c.GstFlowReturn = c.GST_FLOW_OK;
    const sf = vp9.split(data);
    var off: usize = 0;
    for (sf.sizes[0..sf.count]) |sz| {
        const part = data[off .. off + sz];
        off += sz;
        const fr = p.state.parse(part) catch {
            r = c.GST_FLOW_ERROR;
            break;
        };
        if (fr.show_existing) {
            const surface = p.refs[fr.show_idx];
            if (surface == dsp.INVALID or shown) continue;
            const prof = profileOf(&fr) orelse continue;
            r = output(s, p, surface, p.session.width, p.session.height, prof.format, prof.fourcc, prof.bpp);
            if (r != c.GST_FLOW_OK) break;
            shown = true;
            continue;
        }
        r = decodeOne(s, p, &fr, part);
        if (r == c.GST_FLOW_OK) {
            shown = true;
        } else if (r == c.GST_FLOW_CUSTOM_SUCCESS) {
            r = c.GST_FLOW_OK;
        } else break;
    }
    c.gst_buffer_unmap(frame[0].input_buffer, &map);
    if (r != c.GST_FLOW_OK) {
        if (r == c.GST_FLOW_ERROR) err(s, c.GST_STREAM_ERROR_DECODE, "failed to decode the VP9 frame", "gst_va_vp9_dec_handle_frame", 450);
        c.gst_video_codec_frame_unref(frame);
        return r;
    }
    if (!shown) {
        c.gst_video_decoder_release_frame(d, frame);
        return c.GST_FLOW_OK;
    }
    return c.gst_video_decoder_finish_frame(d, frame);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "VA-API VP9 Decoder", "Codec/Decoder/Video/Hardware", "VA-API based VP9 video decoder", "Sinty");
    const dc: *c.GstVideoDecoderClass = @ptrCast(@alignCast(k));
    dc.start = start;
    dc.stop = stop;
    dc.flush = flush;
    dc.set_format = setFormat;
    dc.handle_frame = handleFrame;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.gst_video_decoder_set_packetized(vdec(s), 1);
    c.gst_video_decoder_set_needs_format(vdec(s), 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_video_decoder_get_type(), "GstVaVp9Dec", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    if (!dsp.probe(v.VAProfileVP9Profile0)) return false;
    return c.gst_element_register(p, "vavp9dec", c.GST_RANK_PRIMARY + 1, getType()) != 0;
}
