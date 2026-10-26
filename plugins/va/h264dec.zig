const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const v = @import("vc.zig").v;
const dsp = @import("display.zig");
const h = @import("h264.zig");
const dpb = @import("dpb.zig");

const FILE = "../sys/va/gstvah264dec.c";
const SINK_CAPS = "video/x-h264, stream-format = (string) { avc, avc3, byte-stream }, alignment = (string) au, profile = (string) { constrained-baseline, baseline, main, high, progressive-high, constrained-high }";
const SRC_CAPS = "video/x-raw, format = (string) NV12, width = (int) [ 1, MAX ], height = (int) [ 1, MAX ], framerate = (fraction) [ 0, MAX ]";

const Pic = extern struct {
    curr: v.VAPictureH264,
    refs: [16]v.VAPictureH264,
    width_mbs_minus1: u16,
    height_mbs_minus1: u16,
    depth_luma_minus8: u8,
    depth_chroma_minus8: u8,
    num_ref_frames: u8,
    seq_fields: u32,
    num_slice_groups_minus1: u8 = 0,
    slice_group_map_type: u8 = 0,
    slice_group_change_rate_minus1: u16 = 0,
    qp_minus26: i8,
    qs_minus26: i8,
    chroma_qp_offset: i8,
    second_chroma_qp_offset: i8,
    pic_fields: u32,
    frame_num: u16,
    va_reserved: [8]u32 = .{0} ** 8,
};

comptime {
    std.debug.assert(@sizeOf(v.VAPictureH264) == 36);
    std.debug.assert(@offsetOf(Pic, "seq_fields") == 620);
    std.debug.assert(@offsetOf(Pic, "pic_fields") == 632);
    std.debug.assert(@sizeOf(Pic) == 672);
}

const Priv = struct {
    display: dsp.Display,
    session: dsp.Session = .{},
    dpb: dpb.Dpb = .{},
    spss: [32]?h.Sps = .{null} ** 32,
    ppss: [256]?h.Pps = .{null} ** 256,
    rb: h.Rbsp = .{},
    length_size: usize = 0,
    sps_key: [4]u32 = .{ 0, 0, 0, 0 },
    out_width: u32 = 0,
    out_height: u32 = 0,
    crop_x: u32 = 0,
    crop_y: u32 = 0,
    target: u32 = dsp.INVALID,
    first: ?h.Slice = null,
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

fn err(s: *Self, debug: [*:0]const u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup(debug), FILE, func, line);
}

fn start(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    const display = dsp.Display.open() orelse {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ_WRITE, null, c.g_strdup("no VA display"), FILE, "gst_va_h264_dec_open", 110);
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
    p.dpb.pics = .{dpb.Pic{}} ** dpb.MAX;
    p.dpb.reset();
    return 1;
}

fn drain(d: [*c]c.GstVideoDecoder) callconv(.c) c.GstFlowReturn {
    const s = me(d);
    const p = s.priv orelse return c.GST_FLOW_OK;
    var out = dpb.Outputs{};
    p.dpb.flush(&out);
    return emit(s, p, &out);
}

fn parameterSet(p: *Priv, nal: []const u8) void {
    p.rb.load(nal, std.math.maxInt(usize));
    const data = p.rb.bytes();
    if (data.len < 2) return;
    switch (data[0] & 0x1f) {
        h.NAL_SPS => if (h.parseSps(data[1..])) |sps| {
            p.spss[sps.id] = sps;
        } else |_| {},
        h.NAL_PPS => if (h.parsePps(data[1..], &p.spss)) |pps| {
            p.ppss[pps.id] = pps;
        } else |_| {},
        else => {},
    }
}

fn setFormat(d: [*c]c.GstVideoDecoder, state: [*c]c.GstVideoCodecState) callconv(.c) c.gboolean {
    const s = me(d);
    const p = s.priv orelse return 0;
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = c.gst_video_codec_state_ref(state);
    const st = c.gst_caps_get_structure(state[0].caps, 0);
    const format = c.gst_structure_get_string(st, "stream-format");
    p.length_size = 0;
    if (format != null and std.mem.startsWith(u8, std.mem.span(format), "avc")) {
        p.length_size = 4;
        if (state[0].codec_data) |cd| {
            var map: c.GstMapInfo = undefined;
            if (c.gst_buffer_map(cd, &map, c.GST_MAP_READ) != 0) {
                defer c.gst_buffer_unmap(cd, &map);
                var sets: [64][]const u8 = undefined;
                var n: usize = 0;
                if (h.avcConfig(map.data[0..map.size], &sets, &n)) |ls| {
                    p.length_size = ls;
                    for (sets[0..n]) |nal| parameterSet(p, nal);
                }
            }
        }
    }
    return 1;
}

fn vaProfile(dp: *const dsp.Display, sps: *const h.Sps) ?v.VAProfile {
    if (sps.chroma_format != 1 or sps.depth_luma != 8 or sps.depth_chroma != 8) return null;
    const order: []const v.VAProfile = switch (sps.profile) {
        66 => &.{ v.VAProfileH264ConstrainedBaseline, v.VAProfileH264Main, v.VAProfileH264High },
        77 => &.{ v.VAProfileH264Main, v.VAProfileH264High },
        100 => &.{v.VAProfileH264High},
        else => return null,
    };
    for (order) |pr| {
        if (dp.decodes(pr)) return pr;
    }
    return null;
}

fn ensureSession(s: *Self, p: *Priv, sps: *const h.Sps) c.GstFlowReturn {
    const width = sps.width_mbs * 16;
    const height = sps.heightMbs() * 16;
    const key = [4]u32{ width, height, sps.dpbSize(), sps.profile };
    if (p.session.context != dsp.INVALID and std.mem.eql(u32, &key, &p.sps_key)) return c.GST_FLOW_OK;
    var out = dpb.Outputs{};
    p.dpb.flush(&out);
    const r = emit(s, p, &out);
    if (r != c.GST_FLOW_OK) return r;
    const profile = vaProfile(&p.display, sps) orelse {
        err(s, "unsupported H.264 profile", "gst_va_h264_dec_new_sequence", 220);
        return c.GST_FLOW_NOT_NEGOTIATED;
    };
    p.dpb.pics = .{dpb.Pic{}} ** dpb.MAX;
    p.dpb.configure(sps);
    if (!p.session.create(&p.display, profile, width, height, v.VA_RT_FORMAT_YUV420, p.dpb.size + 3)) {
        err(s, "could not create the VA decoder", "gst_va_h264_dec_new_sequence", 240);
        return c.GST_FLOW_ERROR;
    }
    p.sps_key = key;
    const ch: u32 = if (sps.frame_only) 2 else 4;
    p.crop_x = sps.crop[0] * 2;
    p.crop_y = sps.crop[2] * ch;
    const ow = width -| (sps.crop[0] + sps.crop[1]) * 2;
    const oh = height -| (sps.crop[2] + sps.crop[3]) * ch;
    if (ow != p.out_width or oh != p.out_height or s.output_state == null) {
        if (s.output_state) |x| c.gst_video_codec_state_unref(x);
        s.output_state = c.gst_video_decoder_set_output_state(vdec(s), c.GST_VIDEO_FORMAT_NV12, ow, oh, s.input_state);
        if (c.gst_video_decoder_negotiate(vdec(s)) == 0) return c.GST_FLOW_NOT_NEGOTIATED;
        p.out_width = ow;
        p.out_height = oh;
    }
    return c.GST_FLOW_OK;
}

fn vaPic(pic: *const dpb.Pic) v.VAPictureH264 {
    var vp = std.mem.zeroes(v.VAPictureH264);
    vp.picture_id = pic.surface;
    vp.frame_idx = if (pic.long) pic.long_idx else pic.frame_num;
    vp.flags = if (pic.long) v.VA_PICTURE_H264_LONG_TERM_REFERENCE else if (pic.short) v.VA_PICTURE_H264_SHORT_TERM_REFERENCE else 0;
    vp.TopFieldOrderCnt = pic.top;
    vp.BottomFieldOrderCnt = pic.bottom;
    return vp;
}

fn invalidPic() v.VAPictureH264 {
    var vp = std.mem.zeroes(v.VAPictureH264);
    vp.picture_id = dsp.INVALID;
    vp.flags = v.VA_PICTURE_H264_INVALID;
    return vp;
}

fn bit(acc: *u32, on: bool, at: u5) void {
    if (on) acc.* |= @as(u32, 1) << at;
}

fn picParams(p: *Priv, sps: *const h.Sps, pps: *const h.Pps, sl: *const h.Slice) Pic {
    var seq: u32 = sps.chroma_format & 3;
    bit(&seq, sps.separate_planes, 2);
    bit(&seq, sps.gaps, 3);
    bit(&seq, sps.frame_only, 4);
    bit(&seq, sps.mbaff, 5);
    bit(&seq, sps.direct8x8, 6);
    bit(&seq, sps.level >= 31, 7);
    seq |= @as(u32, sps.log2_frame_num - 4) << 8;
    seq |= (sps.poc_type & 3) << 12;
    seq |= @as(u32, sps.log2_poc_lsb - 4) << 14;
    bit(&seq, sps.poc_zero, 18);
    var pf: u32 = 0;
    bit(&pf, pps.cabac, 0);
    bit(&pf, pps.weighted, 1);
    pf |= @as(u32, pps.bipred) << 2;
    bit(&pf, pps.t8x8, 4);
    bit(&pf, sl.field, 5);
    bit(&pf, pps.constrained_intra, 6);
    bit(&pf, pps.bottom_poc, 7);
    bit(&pf, pps.deblocking, 8);
    bit(&pf, pps.redundant, 9);
    bit(&pf, sl.nal_ref != 0, 10);
    var cur = p.dpb.cur;
    cur.surface = p.target;
    var curr = vaPic(&cur);
    curr.flags = 0;
    var pic = Pic{
        .curr = curr,
        .refs = .{invalidPic()} ** 16,
        .width_mbs_minus1 = @intCast(sps.width_mbs - 1),
        .height_mbs_minus1 = @intCast(sps.heightMbs() - 1),
        .depth_luma_minus8 = @intCast(sps.depth_luma - 8),
        .depth_chroma_minus8 = @intCast(sps.depth_chroma - 8),
        .num_ref_frames = @intCast(@min(sps.max_refs, 255)),
        .seq_fields = seq,
        .qp_minus26 = @intCast(pps.qp),
        .qs_minus26 = @intCast(pps.qs),
        .chroma_qp_offset = @intCast(pps.chroma_qp),
        .second_chroma_qp_offset = @intCast(pps.second_chroma_qp),
        .pic_fields = pf,
        .frame_num = @intCast(sl.frame_num),
    };
    var n: usize = 0;
    for (&p.dpb.pics) |*r| {
        if (n >= 16) break;
        if (!r.used or !r.ref() or r.nonexisting) continue;
        pic.refs[n] = vaPic(r);
        n += 1;
    }
    return pic;
}

fn iqMatrix(pps: *const h.Pps) v.VAIQMatrixBufferH264 {
    var m = std.mem.zeroes(v.VAIQMatrixBufferH264);
    m.ScalingList4x4 = pps.scaling.l4;
    m.ScalingList8x8[0] = pps.scaling.l8[0];
    m.ScalingList8x8[1] = pps.scaling.l8[1];
    return m;
}

fn fillList(p: *const Priv, out: *[32]v.VAPictureH264, l: *const dpb.List) void {
    for (out) |*e| e.* = invalidPic();
    for (l.idx[0..l.count], 0..) |i, k| {
        if (i < dpb.MAX and p.dpb.pics[i].used) out[k] = vaPic(&p.dpb.pics[i]);
    }
}

fn sliceParams(p: *Priv, sps: *const h.Sps, sl: *const h.Slice, size: usize) v.VASliceParameterBufferH264 {
    var sp = std.mem.zeroes(v.VASliceParameterBufferH264);
    sp.slice_data_size = @intCast(size);
    sp.slice_data_offset = 0;
    sp.slice_data_flag = v.VA_SLICE_DATA_FLAG_ALL;
    sp.slice_data_bit_offset = @intCast(sl.header_bits);
    sp.first_mb_in_slice = @intCast(sl.first_mb);
    sp.slice_type = @intCast(sl.kind);
    sp.direct_spatial_mv_pred_flag = @intFromBool(sl.direct_spatial);
    sp.num_ref_idx_l0_active_minus1 = @intCast(if (sl.kind == h.I or sl.kind == h.SI) 0 else sl.l0);
    sp.num_ref_idx_l1_active_minus1 = @intCast(if (sl.kind == h.B) sl.l1 else 0);
    sp.cabac_init_idc = @intCast(sl.cabac_init);
    sp.slice_qp_delta = @intCast(sl.qp_delta);
    sp.disable_deblocking_filter_idc = @intCast(sl.deblock);
    sp.slice_alpha_c0_offset_div2 = @intCast(sl.alpha);
    sp.slice_beta_offset_div2 = @intCast(sl.beta);
    var l0 = dpb.List{};
    var l1 = dpb.List{};
    p.dpb.lists(sps, sl, &l0, &l1);
    fillList(p, &sp.RefPicList0, &l0);
    fillList(p, &sp.RefPicList1, &l1);
    if (sl.weights) |w| {
        sp.luma_log2_weight_denom = @intCast(w.luma_denom);
        sp.chroma_log2_weight_denom = @intCast(w.chroma_denom);
        sp.luma_weight_l0_flag = @intFromBool(w.luma_any[0]);
        sp.chroma_weight_l0_flag = @intFromBool(w.chroma_any[0]);
        sp.luma_weight_l1_flag = @intFromBool(w.luma_any[1]);
        sp.chroma_weight_l1_flag = @intFromBool(w.chroma_any[1]);
        for (0..32) |i| {
            sp.luma_weight_l0[i] = w.luma[0][i][0];
            sp.luma_offset_l0[i] = w.luma[0][i][1];
            for (0..2) |j| {
                sp.chroma_weight_l0[i][j] = w.chroma[0][i][j][0];
                sp.chroma_offset_l0[i][j] = w.chroma[0][i][j][1];
            }
            if (sl.kind == h.B) {
                sp.luma_weight_l1[i] = w.luma[1][i][0];
                sp.luma_offset_l1[i] = w.luma[1][i][1];
                for (0..2) |j| {
                    sp.chroma_weight_l1[i][j] = w.chroma[1][i][j][0];
                    sp.chroma_offset_l1[i][j] = w.chroma[1][i][j][1];
                }
            }
        }
    }
    return sp;
}

fn freeSurface(p: *const Priv) u32 {
    for (p.session.pool()) |sf| {
        if (!p.dpb.surfaceBusy(sf)) return sf;
    }
    return dsp.INVALID;
}

fn emit(s: *Self, p: *Priv, out: *const dpb.Outputs) c.GstFlowReturn {
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    for (out.items[0..out.count]) |o| {
        const frame = c.gst_video_decoder_get_frame(vdec(s), @intCast(o.frame)) orelse continue;
        if (o.surface == dsp.INVALID or ret != c.GST_FLOW_OK) {
            c.gst_video_decoder_release_frame(vdec(s), frame);
            continue;
        }
        ret = download(s, p, frame, o.surface);
        if (ret != c.GST_FLOW_OK) {
            c.gst_video_decoder_release_frame(vdec(s), frame);
            continue;
        }
        ret = c.gst_video_decoder_finish_frame(vdec(s), frame);
    }
    return ret;
}

fn download(s: *Self, p: *Priv, frame: *c.GstVideoCodecFrame, surface: u32) c.GstFlowReturn {
    const r = c.gst_video_decoder_allocate_output_frame(vdec(s), frame);
    if (r != c.GST_FLOW_OK) return r;
    var vf: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&vf, &s.output_state.?.info, frame.output_buffer, c.GST_MAP_WRITE) == 0) return c.GST_FLOW_ERROR;
    defer c.gst_video_frame_unmap(&vf);
    const planes = [2]dsp.Plane{
        .{ .data = @ptrCast(vf.data[0].?), .stride = @intCast(vf.info.stride[0]) },
        .{ .data = @ptrCast(vf.data[1].?), .stride = @intCast(vf.info.stride[1]) },
    };
    if (!dsp.download(&p.display, surface, v.VA_FOURCC_NV12, p.crop_x, p.crop_y, p.out_width, p.out_height, planes, 1)) {
        err(s, "could not read the decoded picture", "gst_va_base_dec_copy_output_buffer", 400);
        return c.GST_FLOW_ERROR;
    }
    return c.GST_FLOW_OK;
}

fn startPicture(s: *Self, p: *Priv, sl: *const h.Slice) c.GstFlowReturn {
    const pps = &(p.ppss[sl.pps] orelse return c.GST_FLOW_ERROR);
    const sps = &(p.spss[pps.sps] orelse return c.GST_FLOW_ERROR);
    if (sl.field) {
        err(s, "field pictures are not supported", "gst_va_h264_dec_new_picture", 300);
        return c.GST_FLOW_ERROR;
    }
    var r = ensureSession(s, p, sps);
    if (r != c.GST_FLOW_OK) return r;
    var out = dpb.Outputs{};
    p.dpb.begin(sps, sl, &out);
    r = emit(s, p, &out);
    if (r != c.GST_FLOW_OK) return r;
    p.target = freeSurface(p);
    if (p.target == dsp.INVALID) {
        err(s, "no free surface", "gst_va_h264_dec_new_picture", 320);
        return c.GST_FLOW_ERROR;
    }
    const pic = picParams(p, sps, pps, sl);
    const iq = iqMatrix(pps);
    if (!p.session.begin(&p.display, p.target) or !p.session.add(&p.display, v.VAPictureParameterBufferType, dsp.bytesOf(&pic)) or !p.session.add(&p.display, v.VAIQMatrixBufferType, dsp.bytesOf(&iq))) {
        err(s, "VA decoding failed", "gst_va_h264_dec_start_picture", 340);
        return c.GST_FLOW_ERROR;
    }
    p.first = sl.*;
    return c.GST_FLOW_OK;
}

fn addSlice(s: *Self, p: *Priv, sl: *const h.Slice, nal: []const u8) c.GstFlowReturn {
    const pps = &(p.ppss[sl.pps] orelse return c.GST_FLOW_ERROR);
    const sps = &(p.spss[pps.sps] orelse return c.GST_FLOW_ERROR);
    const sp = sliceParams(p, sps, sl, nal.len);
    if (!p.session.add(&p.display, v.VASliceParameterBufferType, dsp.bytesOf(&sp)) or !p.session.add(&p.display, v.VASliceDataBufferType, nal)) {
        err(s, "VA decoding failed", "gst_va_h264_dec_decode_slice", 360);
        return c.GST_FLOW_ERROR;
    }
    return c.GST_FLOW_OK;
}

fn endPicture(s: *Self, p: *Priv, frame: u32) c.GstFlowReturn {
    const sl = &(p.first orelse return c.GST_FLOW_OK);
    defer p.first = null;
    if (!p.session.end(&p.display)) {
        err(s, "VA decoding failed", "gst_va_h264_dec_end_picture", 380);
        return c.GST_FLOW_ERROR;
    }
    const pps = &(p.ppss[sl.pps] orelse return c.GST_FLOW_ERROR);
    const sps = &(p.spss[pps.sps] orelse return c.GST_FLOW_ERROR);
    var out = dpb.Outputs{};
    p.dpb.finish(sps, sl, p.target, frame, &out);
    return emit(s, p, &out);
}

fn handleFrame(d: [*c]c.GstVideoDecoder, frame: [*c]c.GstVideoCodecFrame) callconv(.c) c.GstFlowReturn {
    const s = me(d);
    const p = s.priv orelse return c.GST_FLOW_ERROR;
    const number = frame[0].system_frame_number;
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(frame[0].input_buffer, &map, c.GST_MAP_READ) == 0) {
        c.gst_video_codec_frame_unref(frame);
        return c.GST_FLOW_ERROR;
    }
    var it = h.Iter{ .data = map.data[0..map.size], .length_size = p.length_size };
    var r: c.GstFlowReturn = c.GST_FLOW_OK;
    var decoded = false;
    while (it.next()) |nal| {
        if (nal.len < 2) continue;
        const kind = nal[0] & 0x1f;
        if (kind == h.NAL_SPS or kind == h.NAL_PPS) {
            parameterSet(p, nal);
            continue;
        }
        if (kind != h.NAL_SLICE and kind != h.NAL_IDR) continue;
        p.rb.load(nal, 1024);
        const sl = h.parseSlice(&p.rb, &p.spss, &p.ppss) catch continue;
        if (sl.redundant > 0) continue;
        if (p.first == null) {
            r = startPicture(s, p, &sl);
            if (r != c.GST_FLOW_OK) break;
            decoded = true;
        }
        r = addSlice(s, p, &sl, nal);
        if (r != c.GST_FLOW_OK) break;
    }
    c.gst_buffer_unmap(frame[0].input_buffer, &map);
    if (r == c.GST_FLOW_OK and decoded) {
        r = endPicture(s, p, number);
    } else if (p.first != null) {
        _ = p.session.end(&p.display);
        p.first = null;
    }
    if (!decoded or r != c.GST_FLOW_OK) {
        c.gst_video_decoder_release_frame(d, frame);
        return r;
    }
    c.gst_video_codec_frame_unref(frame);
    return r;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "VA-API H.264 Decoder", "Codec/Decoder/Video/Hardware", "VA-API based H.264 video decoder", "Sinty");
    const dc: *c.GstVideoDecoderClass = @ptrCast(@alignCast(k));
    dc.start = start;
    dc.stop = stop;
    dc.flush = flush;
    dc.drain = drain;
    dc.finish = drain;
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
            return cm.register(c.gst_video_decoder_get_type(), "GstVaH264Dec", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    var d = dsp.Display.open() orelse return false;
    defer d.close();
    if (!d.decodes(v.VAProfileH264Main) and !d.decodes(v.VAProfileH264High) and !d.decodes(v.VAProfileH264ConstrainedBaseline)) return false;
    return c.gst_element_register(p, "vah264dec", c.GST_RANK_PRIMARY + 1, getType()) != 0;
}
