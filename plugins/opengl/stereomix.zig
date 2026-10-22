const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglstereomix.c";
const PROP_DOWNMIX_MODE = 1;
const CAPS = "video/x-raw(memory:GLMemory), format = (string) RGBA, width = " ++ el.SIZE ++ ", height = " ++ el.SIZE ++ ", framerate = " ++ el.FPS ++ ",texture-target = (string) 2D; " ++ el.capsWithFeatures("meta:GstVideoGLTextureUploadMeta", "RGBA") ++ "; video/x-raw, format = (string) " ++ c.GST_GL_COLOR_CONVERT_FORMATS ++ ", width = " ++ el.SIZE ++ ", height = " ++ el.SIZE ++ ", framerate = " ++ el.FPS;

const Pad = extern struct {
    parent: el.MixerPad,
    mapped: c.gboolean,
    current_buffer: [*c]c.GstBuffer,
};

const PadClass = extern struct {
    parent: c.GstGLMixerPadClass,
};

const Self = extern struct {
    mixer: c.GstGLMixer,
    out_tex_id: c.guint,
    viewconvert: ?*c.GstGLViewConvert,
    downmix_mode: c.GstGLStereoDownmix,
    mix_info: c.GstVideoInfo,
    input_frames: ?*c.GPtrArray,
    primary_out: [*c]c.GstBuffer,
    auxilliary_out: [*c]c.GstBuffer,
};

const Class = extern struct {
    parent: c.GstGLMixerClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, CAPS);
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent_agg: *c.GstAggregatorClass = undefined;
var parent_el: *c.GstElementClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_gl_mixer_pad_get_type(), "GstGLStereoMixPad", PadClass, Pad, null, null);
        }
    }.f);
}

fn queryCaps(agg: [*c]c.GstAggregator, q: [*c]c.GstQuery) c.gboolean {
    var filter: [*c]c.GstCaps = null;
    c.gst_query_parse_caps(q, &filter);
    var caps = c.gst_pad_get_current_caps(agg[0].srcpad);
    if (caps == null) caps = c.gst_pad_get_pad_template_caps(agg[0].srcpad);
    if (filter != null) caps = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_query_set_caps_result(q, caps);
    c.gst_caps_unref(caps);
    return 1;
}

fn srcQuery(agg: [*c]c.GstAggregator, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_CAPS) return queryCaps(agg, q);
    return parent_agg.src_query.?(agg, q);
}

fn processFrames(s: *Self) bool {
    const vagg: *c.GstVideoAggregator = @ptrCast(@alignCast(s));
    const out_info = &vagg.info;
    const inbuf = c.gst_buffer_new();
    var valid: c.gint = 0;
    var walk = @as(*c.GstElement, @ptrCast(@alignCast(s))).sinkpads;
    while (walk != null) : (walk = walk[0].next) {
        const pad: ?*Pad = @ptrCast(@alignCast(walk[0].data));
        if (pad == null or pad.?.current_buffer == null) continue;
        c.gst_buffer_append_memory(inbuf, c.gst_buffer_get_memory(pad.?.current_buffer, 0));
        _ = c.gst_buffer_add_parent_buffer_meta(inbuf, pad.?.current_buffer);
        valid += 1;
    }
    if (s.mix_info.views != valid) return false;
    const views: c.gint = if (out_info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED) out_info.views else 1;
    c.gst_gl_view_convert_set_context(s.viewconvert, @as(*c.GstGLBaseMixer, @ptrCast(@alignCast(s))).context);
    if (c.gst_gl_view_convert_submit_input_buffer(s.viewconvert, 0, inbuf) != c.GST_FLOW_OK) return false;
    _ = c.gst_buffer_replace(&s.primary_out, null);
    _ = c.gst_buffer_replace(&s.auxilliary_out, null);
    if (c.gst_gl_view_convert_get_output(s.viewconvert, &s.primary_out) != c.GST_FLOW_OK) return false;
    if (out_info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_FRAME_BY_FRAME) {
        if (c.gst_gl_view_convert_get_output(s.viewconvert, &s.auxilliary_out) != c.GST_FLOW_OK) return false;
    }
    if (s.primary_out == null) return false;
    const fmt = out_info.finfo[0].format;
    const planes = out_info.finfo[0].n_planes;
    var v: c.gint = 0;
    while (v < views) : (v += 1) {
        _ = c.gst_buffer_add_video_meta_full(s.primary_out, @bitCast(v), fmt, @intCast(out_info.width), @intCast(out_info.height), planes, &out_info.offset, &out_info.stride);
        if (s.auxilliary_out != null) _ = c.gst_buffer_add_video_meta_full(s.auxilliary_out, @bitCast(v), fmt, @intCast(out_info.width), @intCast(out_info.height), planes, &out_info.offset, &out_info.stride);
    }
    return true;
}

fn makeOutput(s: *Self) bool {
    cm.lock(s);
    defer cm.unlock(s);
    var missing = false;
    var walk = @as(*c.GstElement, @ptrCast(@alignCast(s))).sinkpads;
    while (walk != null) : (walk = walk[0].next) {
        const pad: *Pad = @ptrCast(@alignCast(walk[0].data));
        const b = c.gst_video_aggregator_pad_get_current_buffer(@ptrCast(@alignCast(pad)));
        pad.current_buffer = b;
        if (b == null) missing = true;
    }
    if (missing) return true;
    if (!processFrames(s)) return false;
    return s.primary_out != null;
}

fn createOutput(vagg: [*c]c.GstVideoAggregator, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(vagg);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (!makeOutput(s)) {
        _ = c.gst_buffer_replace(&s.primary_out, null);
        _ = c.gst_buffer_replace(&s.auxilliary_out, null);
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup("Failed to generate output"), c.g_strdup("failed to generate output"), FILE, "gst_gl_stereo_mix_create_output_buffer", 296);
        ret = c.GST_FLOW_ERROR;
    }
    if (s.auxilliary_out != null) {
        out.* = s.auxilliary_out;
        s.auxilliary_out = null;
    } else {
        out.* = s.primary_out;
        s.primary_out = null;
    }
    return ret;
}

fn aggregateFrames(vagg: [*c]c.GstVideoAggregator, out: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(vagg);
    if (vagg[0].info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_FRAME_BY_FRAME) {
        _ = c.gst_buffer_copy_into(s.primary_out, out, c.GST_BUFFER_COPY_TIMESTAMPS, 0, std.math.maxInt(usize));
        _ = c.gst_aggregator_finish_buffer(@ptrCast(vagg), s.primary_out);
        s.primary_out = null;
        out[0].pts = std.math.maxInt(u64);
        out[0].duration = std.math.maxInt(u64);
    }
    return c.GST_FLOW_OK;
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_DOWNMIX_MODE) c.g_value_set_enum(v, @intCast(me(o).downmix_mode)) else cm.warnInvalid(FILE, o, id, spec, 400);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id == PROP_DOWNMIX_MODE) {
        s.downmix_mode = @intCast(c.g_value_get_enum(v));
        if (s.viewconvert != null) c.g_object_set_property(@ptrCast(@alignCast(s.viewconvert)), "downmix-mode", v);
    } else cm.warnInvalid(FILE, o, id, spec, 419);
}

fn requestPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, caps: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    return el.requestPadAnnounced(parent_el, e, templ, name, caps);
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    el.releasePadAnnounced(parent_el, e, pad);
}

fn start(agg: [*c]c.GstAggregator) callconv(.c) c.gboolean {
    const s = me(agg);
    if (parent_agg.start.?(agg) == 0) return 0;
    cm.lock(s);
    s.viewconvert = c.gst_gl_view_convert_new();
    c.g_object_set(s.viewconvert, "downmix-mode", s.downmix_mode, @as(?*anyopaque, null));
    cm.unlock(s);
    return 1;
}

fn stop(agg: [*c]c.GstAggregator) callconv(.c) c.gboolean {
    const s = me(agg);
    if (parent_agg.stop.?(agg) == 0) return 0;
    if (s.viewconvert != null) c.gst_object_unref(s.viewconvert);
    s.viewconvert = null;
    return 1;
}

fn updateCaps(vagg: [*c]c.GstVideoAggregator, caps: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(vagg);
    var bw: c.gint = -1;
    var bh: c.gint = -1;
    var best: f64 = -1;
    var bn: c.gint = 0;
    var bd: c.gint = 1;
    cm.lock(s);
    var walk = @as(*c.GstElement, @ptrCast(@alignCast(s))).sinkpads;
    while (walk != null) : (walk = walk[0].next) {
        const pad: *el.VPad = @ptrCast(@alignCast(walk[0].data));
        if (pad.info.finfo == null) continue;
        if (pad.info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) continue;
        var tmp = pad.info;
        c.gst_video_multiview_video_info_change_mode(&tmp, c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED, c.GST_VIDEO_MULTIVIEW_FLAGS_NONE);
        if (tmp.width == 0 or tmp.height == 0) continue;
        if (bw < tmp.width) bw = tmp.width;
        if (bh < tmp.height) bh = tmp.height;
        var cur: f64 = 0;
        if (tmp.fps_d != 0) c.gst_util_fraction_to_double(tmp.fps_n, tmp.fps_d, &cur);
        if (best < cur) {
            best = cur;
            bn = tmp.fps_n;
            bd = tmp.fps_d;
        }
    }
    cm.unlock(s);
    const info = &s.mix_info;
    _ = c.gst_video_info_set_format(info, c.GST_VIDEO_FORMAT_RGBA, @bitCast(bw), @bitCast(bh));
    info.fps_n = bn;
    info.fps_d = bd;
    info.ABI.abi.multiview_mode = c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED;
    info.views = 2;
    info.ABI.abi.multiview_flags = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE;
    const blend = c.gst_video_info_to_caps(info);
    c.gst_caps_set_features(blend, 0, c.gst_caps_features_new_single_static_str(c.GST_CAPS_FEATURE_MEMORY_GL_MEMORY));
    const conv = c.gst_gl_view_convert_transform_caps(s.viewconvert, c.GST_PAD_SINK, blend, null);
    c.gst_caps_unref(blend);
    const out = c.gst_caps_intersect(caps, conv);
    c.gst_caps_unref(conv);
    return out;
}

fn negotiated(agg: [*c]c.GstAggregator, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(agg);
    if (parent_agg.negotiated_src_caps) |f| if (f(agg, caps) == 0) return 0;
    c.gst_gl_view_convert_set_context(s.viewconvert, @as(*c.GstGLBaseMixer, @ptrCast(@alignCast(s))).context);
    const in = c.gst_video_info_to_caps(&s.mix_info);
    c.gst_caps_set_features(in, 0, c.gst_caps_features_new_single_static_str(c.GST_CAPS_FEATURE_MEMORY_GL_MEMORY));
    c.gst_caps_set_simple(in, "texture-target", c.G_TYPE_STRING, "2D", @as(?*anyopaque, null));
    _ = c.gst_gl_view_convert_set_caps(s.viewconvert, in, caps);
    c.gst_caps_unref(in);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_agg = el.parentOf(c.GstAggregatorClass, k);
    parent_el = el.parentOf(c.GstElementClass, k);
    _ = c._gst_debug_category_new("glstereomixer", 0, "opengl stereoscopic mixer");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "OpenGL stereo video combiner", "Filter/Effect/Video", "OpenGL stereo video combiner", "Jan Schmidt <jan@centricular.com>");
    c.g_object_class_install_property(oc, PROP_DOWNMIX_MODE, c.g_param_spec_enum("downmix-mode", "Mode for mono downmixed output", "Output anaglyph type to generate when downmixing to mono", c.gst_gl_stereo_downmix_get_type(), c.GST_GL_STEREO_DOWNMIX_ANAGLYPH_GREEN_MAGENTA_DUBOIS, cm.RW));
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &src_t, c.gst_aggregator_pad_get_type());
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &sink_t, padType());
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    const ac: *c.GstAggregatorClass = @ptrCast(@alignCast(k));
    ac.stop = stop;
    ac.start = start;
    ac.src_query = srcQuery;
    ac.negotiated_src_caps = negotiated;
    const vc: *c.GstVideoAggregatorClass = @ptrCast(@alignCast(k));
    vc.aggregate_frames = aggregateFrames;
    vc.update_caps = updateCaps;
    vc.create_output_buffer = createOutput;
    const bc: *c.GstGLBaseMixerClass = @ptrCast(@alignCast(k));
    bc.supported_gl_api = c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3;
    c.gst_type_mark_as_plugin_api(c.gst_gl_stereo_downmix_get_type(), 0);
    c.gst_type_mark_as_plugin_api(padType(), 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_mixer_get_type(), "GstGLStereoMix", Class, Self, classInit, null);
            el.addSinkpadProxy(t);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glstereomix", c.GST_RANK_NONE, getType());
}
