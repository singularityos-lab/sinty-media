const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/debugutils/gstfakevideodec.c";
const COMMON = ", width=(int) [1, MAX], height=(int) [1, MAX], framerate=(fraction) [1, MAX]";
const PARSED = COMMON ++ ", parsed = (boolean) true";
const SINK_CAPS = "video/x-h264" ++ PARSED ++ ";" ++
    "video/x-h263" ++ PARSED ++ ";" ++
    "video/x-theora" ++ COMMON ++ ";" ++
    "video/x-vp6" ++ COMMON ++ ";" ++
    "video/x-vp6-flash" ++ COMMON ++ ";" ++
    "video/x-vp8" ++ COMMON ++ ";" ++
    "video/x-vp9" ++ COMMON ++ ";" ++
    "video/x-divx" ++ COMMON ++ ";" ++
    "video/x-msmpeg" ++ COMMON ++ ";" ++
    "video/mpeg, mpegversion=(int) {1, 2, 4}, systemstream=(boolean) false" ++ COMMON ++ ";" ++
    "video/x-flash-video, flvversion=(int) 1" ++ COMMON ++ ";" ++
    "video/x-raw,format={ RGBA, RGBx, BGRA, BGRx, RGB16} " ++ COMMON ++ ";" ++
    "video/x-wmv, wmvversion=(int) {1, 2, 3}" ++ COMMON;
const SRC_CAPS = "video/x-raw, format = (string) { RGBA, RGBx, BGRA, BGRx, RGB16}, width = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", height = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE;

const Self = extern struct {
    parent: c.GstVideoDecoder,
    input_state: ?*c.GstVideoCodecState,
    output_state: ?*c.GstVideoCodecState,
    min_buffers: c.guint,
    step: c.guint,
    max_steps: c.guint,
    length: c.guint,
};

const Class = extern struct {
    parent: c.GstVideoDecoderClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, SINK_CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var once: cm.Once = .{};
var parent: ?*c.GstVideoDecoderClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn dec(p: anytype) [*c]c.GstVideoDecoder {
    return @ptrCast(@alignCast(p));
}

fn start(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    s.min_buffers = 0;
    s.step = 0;
    return 1;
}

fn stop(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    if (s.output_state) |x| c.gst_video_codec_state_unref(x);
    s.output_state = null;
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = null;
    return 1;
}

fn setFormat(d: [*c]c.GstVideoDecoder, state: [*c]c.GstVideoCodecState) callconv(.c) c.gboolean {
    const s = me(d);
    const src = d.*.srcpad;
    const tmpl = c.gst_pad_get_pad_template_caps(src);
    var caps = c.gst_pad_peer_query_caps(src, tmpl);
    c.gst_caps_unref(tmpl);
    caps = c.gst_caps_truncate(caps);
    caps = c.gst_caps_fixate(caps);
    var info: c.GstVideoInfo = undefined;
    c.gst_video_info_init(&info);
    if (c.gst_video_info_from_caps(&info, caps) == 0) {
        c.gst_caps_unref(caps);
        return 0;
    }
    c.gst_caps_unref(caps);
    if (s.input_state) |x| c.gst_video_codec_state_unref(x);
    s.input_state = c.gst_video_codec_state_ref(state);
    s.output_state = c.gst_video_decoder_set_output_state(d, info.finfo.*.format, @intCast(s.input_state.?.info.width), @intCast(s.input_state.?.info.height), s.input_state);
    _ = c.gst_video_decoder_negotiate(d);
    var fps: f64 = 0;
    c.gst_util_fraction_to_double(s.output_state.?.info.fps_n, s.output_state.?.info.fps_d, &fps);
    if (fps < 1 or fps > 60) return 0;
    s.max_steps = @intFromFloat(fps);
    s.length = @intFromFloat(@as(f64, @floatFromInt(s.output_state.?.info.width)) / fps);
    return @intFromBool(s.length != 0);
}

fn clearBuffer(b: [*c]c.GstBuffer) void {
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &map, c.GST_MAP_READ) == 0) return;
    @memset(map.data[0..map.maxsize], 0);
    c.gst_buffer_unmap(b, &map);
}

fn negotiate(d: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    const s = me(d);
    if (parent.?.negotiate.?(d) == 0) return 0;
    const frame: *c.GstVideoCodecFrame = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstVideoCodecFrame))));
    defer c.g_free(frame);
    var i: c.guint = 0;
    while (i < s.min_buffers) : (i += 1) {
        if (c.gst_video_decoder_allocate_output_frame(d, frame) != c.GST_FLOW_OK) return 0;
        clearBuffer(frame.output_buffer);
        _ = c.gst_mini_object_replace(@ptrCast(&frame.output_buffer), null);
    }
    return 1;
}

fn flush(_: [*c]c.GstVideoDecoder) callconv(.c) c.gboolean {
    return 1;
}

fn nextStep(s: *Self) void {
    if (s.step < s.max_steps) {
        s.step += 1;
    } else s.step = 0;
}

fn fill(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    const info = &s.output_state.?.info;
    var frame: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&frame, info, b, c.GST_MAP_WRITE) == 0) return c.GST_FLOW_ERROR;
    defer c.gst_video_frame_unmap(&frame);
    const fi = frame.info.finfo.*;
    if (fi.n_planes != 1) return c.GST_FLOW_ERROR;
    switch (fi.format) {
        c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_RGBx, c.GST_VIDEO_FORMAT_RGB16 => {
            const data: [*]u8 = @ptrCast(frame.data[0].?);
            const stride: usize = @intCast(frame.info.stride[0]);
            const depth: usize = fi.depth[0];
            const row = frame.info.offset[0] + @as(usize, @intCast(@divTrunc(frame.info.height, 2))) * stride;
            @memset(data[row..][0 .. stride * depth], 0);
            @memset(data[row + s.step * s.length * depth ..][0 .. s.length * depth], 0xff);
        },
        else => {},
    }
    return c.GST_FLOW_OK;
}

fn handleFrame(d: [*c]c.GstVideoDecoder, frame: [*c]c.GstVideoCodecFrame) callconv(.c) c.GstFlowReturn {
    const s = me(d);
    if (s.input_state.?.info.finfo.*.format == c.GST_VIDEO_FORMAT_ENCODED) {
        var map: c.GstMapInfo = undefined;
        if (c.gst_buffer_map(frame.*.input_buffer, &map, c.GST_MAP_READ) == 0) return c.GST_FLOW_ERROR;
        c.gst_buffer_unmap(frame.*.input_buffer, &map);
        nextStep(s);
        var ret = c.gst_video_decoder_allocate_output_frame(d, frame);
        if (ret == c.GST_FLOW_OK) ret = fill(s, frame.*.output_buffer);
        if (ret != c.GST_FLOW_OK) {
            _ = c.gst_video_decoder_drop_frame(d, frame);
            return ret;
        }
    } else frame.*.output_buffer = c.gst_buffer_ref(frame.*.input_buffer);
    return c.gst_video_decoder_finish_frame(d, frame);
}

fn decideAllocation(d: [*c]c.GstVideoDecoder, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const s = me(d);
    if (parent.?.decide_allocation.?(d, q) == 0) return 0;
    if (c.gst_query_get_n_allocation_pools(q) == 0) c.g_assertion_message_expr(null, FILE, 457, "gst_fake_video_dec_decide_allocation", "gst_query_get_n_allocation_pools (query) > 0");
    var pool: ?*c.GstBufferPool = null;
    var min: c.guint = 0;
    c.gst_query_parse_nth_allocation_pool(q, 0, &pool, null, &min, null);
    if (pool == null) c.g_assertion_message_expr(null, FILE, 460, "gst_fake_video_dec_decide_allocation", "pool != NULL");
    s.min_buffers = @max(min, 2);
    const config = c.gst_buffer_pool_get_config(pool);
    if (c.gst_query_find_allocation_meta(q, c.gst_video_meta_api_get_type(), null) != 0) c.gst_buffer_pool_config_add_option(config, "GstBufferPoolOptionVideoMeta");
    _ = c.gst_buffer_pool_set_config(pool, config);
    c.gst_object_unref(pool);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&src_t));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&sink_t));
    c.gst_element_class_set_static_metadata(ec, "Fake Video Decoder", "Codec/Decoder/Video", "Fake video decoder", "Julien Isorce <julien.isorce@gmail.com>");
    const dc: *c.GstVideoDecoderClass = @ptrCast(@alignCast(k));
    dc.start = start;
    dc.stop = stop;
    dc.flush = flush;
    dc.set_format = setFormat;
    dc.negotiate = negotiate;
    dc.handle_frame = handleFrame;
    dc.decide_allocation = decideAllocation;
    _ = c._gst_debug_category_new("fakevideodec", 0, "Fake Video Decoder");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.gst_video_decoder_set_packetized(dec(s), 1);
    s.min_buffers = 0;
    s.step = 0;
    s.max_steps = 0;
    s.length = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_video_decoder_get_type(), "GstFakeVideoDec", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "fakevideodec", c.GST_RANK_NONE, getType()) != 0;
}
