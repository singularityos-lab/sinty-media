const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pads = @import("../audiomixer/pads.zig");
const bl = @import("blend.zig");

const FILE = "../gst/compositor/compositor.c";
const CAPS = "video/x-raw, format = (string) " ++ c.GST_VIDEO_FORMATS_ALL ++ ", width = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", height = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE;

const OP_SOURCE = 0;
const OP_OVER = 1;
const OP_ADD = 2;
const BG_CHECKER = 0;
const BG_BLACK = 1;
const BG_WHITE = 2;
const BG_TRANSPARENT = 3;
const SIZING_NONE = 0;
const SIZING_KEEP = 1;

const PAD_XPOS = 1;
const PAD_YPOS = 2;
const PAD_WIDTH = 3;
const PAD_HEIGHT = 4;
const PAD_ALPHA = 5;
const PAD_OPERATOR = 6;
const PAD_SIZING = 7;

const PROP_BACKGROUND = 1;
const PROP_ZERO_SIZE = 2;
const PROP_MAX_THREADS = 3;
const PROP_IGNORE_INACTIVE = 4;

const VPad = extern struct {
    parent: pads.AggPad,
    info: c.GstVideoInfo,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

const ConvertPad = extern struct {
    parent: VPad,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

const Pad = extern struct {
    parent: ConvertPad,
    xpos: c.gint,
    ypos: c.gint,
    width: c.gint,
    height: c.gint,
    alpha: f64,
    op: c.gint,
    sizing: c.gint,
    x_offset: c.gint,
    y_offset: c.gint,
};

const PadClass = extern struct {
    parent: c.GstVideoAggregatorConvertPadClass,
    reserved: [4]c.gpointer,
};

const Self = extern struct {
    parent: c.GstVideoAggregator,
    background: c.gint,
    zero_size_is_unscaled: c.gboolean,
    max_threads: c.guint,
    n_threads: c.guint,
    blend: ?*const anyopaque,
    overlay: ?*const anyopaque,
    fill_checker: ?*const anyopaque,
    fill_color: ?*const anyopaque,
    black: [3]c.gint,
    white: [3]c.gint,
    intermediate_info: c.GstVideoInfo,
    intermediate_frame: [*c]c.GstBuffer,
    intermediate_convert: ?*c.GstVideoConverter,
};

const Class = extern struct {
    parent: c.GstVideoAggregatorClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, CAPS);
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var op_once: cm.Once = .{};
var bg_once: cm.Once = .{};
var sizing_once: cm.Once = .{};
var parent: ?*c.GstVideoAggregatorClass = null;
var pad_parent: ?*c.GstVideoAggregatorConvertPadClass = null;

const op_values = [_]c.GEnumValue{
    .{ .value = OP_SOURCE, .value_name = "Source", .value_nick = "source" },
    .{ .value = OP_OVER, .value_name = "Over", .value_nick = "over" },
    .{ .value = OP_ADD, .value_name = "Add", .value_nick = "add" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

const bg_values = [_]c.GEnumValue{
    .{ .value = BG_CHECKER, .value_name = "Checker pattern", .value_nick = "checker" },
    .{ .value = BG_BLACK, .value_name = "Black", .value_nick = "black" },
    .{ .value = BG_WHITE, .value_name = "White", .value_nick = "white" },
    .{ .value = BG_TRANSPARENT, .value_name = "Transparent Background to enable further compositing", .value_nick = "transparent" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

const sizing_values = [_]c.GEnumValue{
    .{ .value = SIZING_NONE, .value_name = "None: Image is scaled to fill configured destination rectangle without padding or keeping the aspect ratio", .value_nick = "none" },
    .{ .value = SIZING_KEEP, .value_name = "Keep Aspect Ratio: Image is scaled to fit destination rectangle specified by GstCompositorPad:{xpos, ypos, width, height} with preserved aspect ratio. Resulting image will be centered in the destination rectangle with padding if necessary", .value_nick = "keep-aspect-ratio" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn opType() c.GType {
    return op_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstCompositorOperator", &op_values);
        }
    }.f);
}

fn bgType() c.GType {
    return bg_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstCompositorBackground", &bg_values);
        }
    }.f);
}

fn sizingType() c.GType {
    return sizing_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstCompositorSizingPolicy", &sizing_values);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn pad(p: anytype) *Pad {
    return @ptrCast(@alignCast(p));
}

fn vinfo(p: anytype) *c.GstVideoInfo {
    return &@as(*VPad, @ptrCast(@alignCast(p))).info;
}

fn padGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = pad(o);
    switch (id) {
        PAD_XPOS => c.g_value_set_int(v, p.xpos),
        PAD_YPOS => c.g_value_set_int(v, p.ypos),
        PAD_WIDTH => c.g_value_set_int(v, p.width),
        PAD_HEIGHT => c.g_value_set_int(v, p.height),
        PAD_ALPHA => c.g_value_set_double(v, p.alpha),
        PAD_OPERATOR => c.g_value_set_enum(v, p.op),
        PAD_SIZING => c.g_value_set_enum(v, p.sizing),
        else => cm.warnInvalid(FILE, o, id, spec, 242),
    }
}

fn padSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = pad(o);
    switch (id) {
        PAD_XPOS => p.xpos = c.g_value_get_int(v),
        PAD_YPOS => p.ypos = c.g_value_get_int(v),
        PAD_WIDTH => {
            p.width = c.g_value_get_int(v);
            c.gst_video_aggregator_convert_pad_update_conversion_info(@ptrCast(p));
        },
        PAD_HEIGHT => {
            p.height = c.g_value_get_int(v);
            c.gst_video_aggregator_convert_pad_update_conversion_info(@ptrCast(p));
        },
        PAD_ALPHA => p.alpha = c.g_value_get_double(v),
        PAD_OPERATOR => {
            p.op = c.g_value_get_enum(v);
            c.gst_video_aggregator_pad_set_needs_alpha(@ptrCast(p), @intFromBool(p.op == OP_ADD));
        },
        PAD_SIZING => {
            p.sizing = c.g_value_get_enum(v);
            c.gst_video_aggregator_convert_pad_update_conversion_info(@ptrCast(p));
        },
        else => cm.warnInvalid(FILE, o, id, spec, 284),
    }
}

fn outputSize(comp: *Self, p: *Pad, par_n: c.gint, par_d: c.gint, w: *c.gint, h: *c.gint, xo: *c.gint, yo: *c.gint) void {
    const info = vinfo(p);
    xo.* = 0;
    yo.* = 0;
    w.* = 0;
    h.* = 0;
    if (info.finfo == null or info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) return;
    var pw: c.gint = undefined;
    var ph: c.gint = undefined;
    if (comp.zero_size_is_unscaled != 0) {
        pw = if (p.width <= 0) info.width else p.width;
        ph = if (p.height <= 0) info.height else p.height;
    } else {
        pw = if (p.width < 0) info.width else p.width;
        ph = if (p.height < 0) info.height else p.height;
    }
    if (pw == 0 or ph == 0) return;
    var dn: c.guint = 0;
    var dd: c.guint = 0;
    if (c.gst_video_calculate_display_ratio(&dn, &dd, @intCast(pw), @intCast(ph), @intCast(info.par_n), @intCast(info.par_d), @intCast(par_n), @intCast(par_d)) == 0) return;
    const dar_n: c.gint = @intCast(dn);
    const dar_d: c.gint = @intCast(dd);
    switch (p.sizing) {
        SIZING_NONE => {
            if (@rem(ph, dar_n) == 0) {
                pw = @intCast(c.gst_util_uint64_scale_int(@intCast(ph), dar_n, dar_d));
            } else if (@rem(pw, dar_d) == 0) {
                ph = @intCast(c.gst_util_uint64_scale_int(@intCast(pw), dar_d, dar_n));
            } else {
                pw = @intCast(c.gst_util_uint64_scale_int(@intCast(ph), dar_n, dar_d));
            }
        },
        SIZING_KEEP => {
            var fn_: c.gint = 0;
            var fd: c.gint = 0;
            var tn: c.gint = 0;
            var td: c.gint = 0;
            var num: c.gint = 0;
            var den: c.gint = 0;
            if (c.gst_util_fraction_multiply(info.width, info.height, info.par_n, info.par_d, &fn_, &fd) == 0) {
                fn_ = -1;
                fd = -1;
            }
            if (c.gst_util_fraction_multiply(pw, ph, par_n, par_d, &tn, &td) == 0) {
                tn = -1;
                td = -1;
            }
            if (fn_ != tn or fd != td) {
                if (fn_ != -1 and fd != -1 and c.gst_util_fraction_multiply(fn_, fd, par_d, par_n, &num, &den) != 0) {
                    var src_r = c.GstVideoRectangle{ .x = 0, .y = 0, .w = pw, .h = @intCast(c.gst_util_uint64_scale_int(@intCast(pw), den, num)) };
                    if (src_r.h == 0) {
                        pw = 0;
                        ph = 0;
                    } else {
                        var dst_r = c.GstVideoRectangle{ .x = 0, .y = 0, .w = pw, .h = ph };
                        var res = std.mem.zeroes(c.GstVideoRectangle);
                        c.gst_video_center_rect(&src_r, &dst_r, &res, 1);
                        xo.* = res.x;
                        yo.* = res.y;
                        pw = res.w;
                        ph = res.h;
                    }
                } else {
                    xo.* = 0;
                    yo.* = 0;
                    pw = 0;
                    ph = 0;
                }
            }
        },
        else => {},
    }
    w.* = pw;
    h.* = ph;
}

fn rectContains(r1: c.GstVideoRectangle, r2: c.GstVideoRectangle) bool {
    return r2.x <= r1.x and r2.y <= r1.y and r2.x + r2.w >= r1.x + r1.w and r2.y + r2.h >= r1.y + r1.h;
}

fn clampRect(x: c.gint, y: c.gint, w: c.gint, h: c.gint, ow: c.gint, oh: c.gint) c.GstVideoRectangle {
    const cx = std.math.clamp(x, 0, ow);
    const cy = std.math.clamp(y, 0, oh);
    return .{ .x = cx, .y = cy, .w = std.math.clamp(x + w, 0, ow) - cx, .h = std.math.clamp(y + h, 0, oh) - cy };
}

fn vagg(s: *Self) *c.GstVideoAggregator {
    return &s.parent;
}

fn obscures(s: *Self, p0: ?*anyopaque, rect: c.GstVideoRectangle) bool {
    const p = pad(p0);
    if (c.gst_video_aggregator_pad_has_current_buffer(@ptrCast(p)) == 0) return false;
    if (p.alpha != 1.0 or (vinfo(p).finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_ALPHA) != 0) return false;
    var config: ?*c.GstStructure = null;
    var fill_border: c.gboolean = 1;
    var border: c.guint = 0xff000000;
    c.g_object_get(p, "converter-config", &config, @as(?*anyopaque, null));
    if (config) |cf| {
        _ = c.gst_structure_get(cf, c.GST_VIDEO_CONVERTER_OPT_BORDER_ARGB, c.G_TYPE_UINT, &border, @as(?*anyopaque, null));
        _ = c.gst_structure_get(cf, c.GST_VIDEO_CONVERTER_OPT_FILL_BORDER, c.G_TYPE_BOOLEAN, &fill_border, @as(?*anyopaque, null));
        c.gst_structure_free(cf);
    }
    if (fill_border == 0 or (border & 0xff000000) != 0xff000000) return false;
    var r = c.GstVideoRectangle{ .x = p.xpos, .y = p.ypos, .w = 0, .h = 0 };
    var xo: c.gint = 0;
    var yo: c.gint = 0;
    outputSize(s, p, vagg(s).info.par_n, vagg(s).info.par_d, &r.w, &r.h, &xo, &yo);
    r.x += xo;
    r.y += yo;
    return rectContains(rect, r);
}

fn prepareFrameStart(vp: ?*c.GstVideoAggregatorPad, va: [*c]c.GstVideoAggregator, b: [*c]c.GstBuffer, prepared: [*c]c.GstVideoFrame) callconv(.c) void {
    const p = pad(vp);
    const s = me(va);
    var w: c.gint = 0;
    var h: c.gint = 0;
    outputSize(s, p, va[0].info.par_n, va[0].info.par_d, &w, &h, &p.x_offset, &p.y_offset);
    if (p.alpha == 0.0) return;
    if (c.gst_aggregator_pad_is_inactive(@ptrCast(p)) != 0) return;
    const fr = clampRect(p.xpos + p.x_offset, p.ypos + p.y_offset, w, h, va[0].info.width, va[0].info.height);
    if (fr.w == 0 or fr.h == 0) return;
    cm.lock(s);
    var hidden = false;
    var l = c.g_list_find(@as(*c.GstElement, @ptrCast(s)).sinkpads, p);
    if (l != null) l = l.*.next;
    while (l != null) : (l = l.*.next) {
        const other = c.gst_video_aggregator_pad_get_current_buffer(@ptrCast(@alignCast(l.*.data)));
        if (other == null) continue;
        if (c.gst_buffer_get_size(other) == 0 and (@as(*c.GstMiniObject, @ptrCast(@alignCast(other))).flags & c.GST_BUFFER_FLAG_GAP) != 0) continue;
        if (obscures(s, l.*.data, fr)) {
            hidden = true;
            break;
        }
    }
    cm.unlock(s);
    if (hidden) return;
    @as(*c.GstVideoAggregatorPadClass, @ptrCast(pad_parent.?)).prepare_frame_start.?(vp, va, b, prepared);
}

fn createConversionInfo(cp: ?*c.GstVideoAggregatorConvertPad, va: [*c]c.GstVideoAggregator, ci: [*c]c.GstVideoInfo) callconv(.c) void {
    const s = me(va);
    const p = pad(cp);
    pad_parent.?.create_conversion_info.?(cp, va, ci);
    if (ci[0].finfo == null) return;
    if (s.intermediate_frame != null) {
        var tmp: c.GstVideoInfo = undefined;
        _ = c.gst_video_info_set_interlaced_format(&tmp, s.intermediate_info.finfo[0].format, ci[0].interlace_mode, @intCast(ci[0].width), @intCast(ci[0].height));
        tmp.colorimetry = ci[0].colorimetry;
        tmp.par_n = ci[0].par_n;
        tmp.par_d = ci[0].par_d;
        tmp.fps_n = ci[0].fps_n;
        tmp.fps_d = ci[0].fps_d;
        tmp.flags = ci[0].flags;
        ci[0] = tmp;
    }
    var w: c.gint = 0;
    var h: c.gint = 0;
    var xo: c.gint = 0;
    var yo: c.gint = 0;
    outputSize(s, p, va[0].info.par_n, va[0].info.par_d, &w, &h, &xo, &yo);
    if (ci[0].width != w or ci[0].height != h) {
        var tmp: c.GstVideoInfo = undefined;
        _ = c.gst_video_info_set_interlaced_format(&tmp, ci[0].finfo[0].format, ci[0].interlace_mode, @intCast(w), @intCast(h));
        tmp.chroma_site = ci[0].chroma_site;
        tmp.colorimetry = ci[0].colorimetry;
        tmp.par_n = ci[0].par_n;
        tmp.par_d = ci[0].par_d;
        tmp.fps_n = ci[0].fps_n;
        tmp.fps_d = ci[0].fps_d;
        tmp.flags = ci[0].flags;
        ci[0] = tmp;
    }
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = padSetProperty;
    oc.get_property = padGetProperty;
    const f = c.G_PARAM_READWRITE | c.GST_PARAM_CONTROLLABLE | c.G_PARAM_STATIC_STRINGS;
    const lo = std.math.minInt(c.gint);
    const hi = std.math.maxInt(c.gint);
    c.g_object_class_install_property(oc, PAD_XPOS, c.g_param_spec_int("xpos", "X Position", "X Position of the picture", lo, hi, 0, f));
    c.g_object_class_install_property(oc, PAD_YPOS, c.g_param_spec_int("ypos", "Y Position", "Y Position of the picture", lo, hi, 0, f));
    c.g_object_class_install_property(oc, PAD_WIDTH, c.g_param_spec_int("width", "Width", "Width of the picture", lo, hi, -1, f));
    c.g_object_class_install_property(oc, PAD_HEIGHT, c.g_param_spec_int("height", "Height", "Height of the picture", lo, hi, -1, f));
    c.g_object_class_install_property(oc, PAD_ALPHA, c.g_param_spec_double("alpha", "Alpha", "Alpha of the picture", 0.0, 1.0, 1.0, f));
    c.g_object_class_install_property(oc, PAD_OPERATOR, c.g_param_spec_enum("operator", "Operator", "Blending operator to use for blending this pad over the previous ones", opType(), OP_OVER, f));
    c.g_object_class_install_property(oc, PAD_SIZING, c.g_param_spec_enum("sizing-policy", "Sizing policy", "Sizing policy to use for image scaling", sizingType(), SIZING_NONE, f));
    @as(*c.GstVideoAggregatorPadClass, @ptrCast(@alignCast(k))).prepare_frame_start = prepareFrameStart;
    @as(*c.GstVideoAggregatorConvertPadClass, @ptrCast(@alignCast(k))).create_conversion_info = createConversionInfo;
    c.gst_type_mark_as_plugin_api(sizingType(), 0);
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = pad(inst);
    p.xpos = 0;
    p.ypos = 0;
    p.alpha = 1.0;
    p.op = OP_OVER;
    p.width = -1;
    p.height = -1;
    p.sizing = SIZING_NONE;
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_video_aggregator_parallel_convert_pad_get_type(), "GstCompositorPad", PadClass, Pad, padClassInit, padInit);
        }
    }.f);
}

const Fns = struct { blend: bl.Blend, overlay: bl.Blend, checker: bl.Checker, color: bl.Color };

fn fns(fmt: c.GstVideoFormat) ?Fns {
    return switch (fmt) {
        c.GST_VIDEO_FORMAT_AYUV => .{ .blend = bl.blend_argb, .overlay = bl.overlay_argb, .checker = bl.fill_checker_ayuv, .color = bl.fill_color_ayuv },
        c.GST_VIDEO_FORMAT_VUYA => .{ .blend = bl.blend_bgra, .overlay = bl.overlay_bgra, .checker = bl.fill_checker_vuya, .color = bl.fill_color_vuya },
        c.GST_VIDEO_FORMAT_ARGB => .{ .blend = bl.blend_argb, .overlay = bl.overlay_argb, .checker = bl.fill_checker_argb, .color = bl.fill_color_argb },
        c.GST_VIDEO_FORMAT_BGRA => .{ .blend = bl.blend_bgra, .overlay = bl.overlay_bgra, .checker = bl.fill_checker_bgra, .color = bl.fill_color_bgra },
        c.GST_VIDEO_FORMAT_ABGR => .{ .blend = bl.blend_argb, .overlay = bl.overlay_argb, .checker = bl.fill_checker_argb, .color = bl.fill_color_abgr },
        c.GST_VIDEO_FORMAT_RGBA => .{ .blend = bl.blend_bgra, .overlay = bl.overlay_bgra, .checker = bl.fill_checker_bgra, .color = bl.fill_color_rgba },
        c.GST_VIDEO_FORMAT_Y444_16LE => .{ .blend = bl.blend_y444_16le, .overlay = bl.blend_y444_16le, .checker = bl.fill_checker_y444_16le, .color = bl.fill_color_high_le },
        c.GST_VIDEO_FORMAT_Y444_16BE => .{ .blend = bl.blend_y444_16be, .overlay = bl.blend_y444_16be, .checker = bl.fill_checker_y444_16be, .color = bl.fill_color_high_be },
        c.GST_VIDEO_FORMAT_Y444_12LE => .{ .blend = bl.blend_y444_12le, .overlay = bl.blend_y444_12le, .checker = bl.fill_checker_i420_12le, .color = bl.fill_color_high_le },
        c.GST_VIDEO_FORMAT_Y444_12BE => .{ .blend = bl.blend_y444_12be, .overlay = bl.blend_y444_12be, .checker = bl.fill_checker_i420_12be, .color = bl.fill_color_high_be },
        c.GST_VIDEO_FORMAT_Y444_10LE => .{ .blend = bl.blend_y444_10le, .overlay = bl.blend_y444_10le, .checker = bl.fill_checker_i420_10le, .color = bl.fill_color_high_le },
        c.GST_VIDEO_FORMAT_Y444_10BE => .{ .blend = bl.blend_y444_10be, .overlay = bl.blend_y444_10be, .checker = bl.fill_checker_i420_10be, .color = bl.fill_color_high_be },
        c.GST_VIDEO_FORMAT_Y444 => .{ .blend = bl.blend_y444, .overlay = bl.blend_y444, .checker = bl.fill_checker_planar, .color = bl.fill_color_planar },
        c.GST_VIDEO_FORMAT_Y42B => .{ .blend = bl.blend_y42b, .overlay = bl.blend_y42b, .checker = bl.fill_checker_planar, .color = bl.fill_color_planar },
        c.GST_VIDEO_FORMAT_YUY2 => .{ .blend = bl.blend_yuy2, .overlay = bl.blend_yuy2, .checker = bl.fill_checker_yuy2, .color = bl.fill_color_yuy2 },
        c.GST_VIDEO_FORMAT_UYVY => .{ .blend = bl.blend_yuy2, .overlay = bl.blend_yuy2, .checker = bl.fill_checker_uyvy, .color = bl.fill_color_uyvy },
        c.GST_VIDEO_FORMAT_YVYU => .{ .blend = bl.blend_yuy2, .overlay = bl.blend_yuy2, .checker = bl.fill_checker_yuy2, .color = bl.fill_color_yvyu },
        c.GST_VIDEO_FORMAT_I422_12LE => .{ .blend = bl.blend_i422_12le, .overlay = bl.blend_i422_12le, .checker = bl.fill_checker_i420_12le, .color = bl.fill_color_high_le },
        c.GST_VIDEO_FORMAT_I422_12BE => .{ .blend = bl.blend_i422_12be, .overlay = bl.blend_i422_12be, .checker = bl.fill_checker_i420_12be, .color = bl.fill_color_high_be },
        c.GST_VIDEO_FORMAT_I422_10LE => .{ .blend = bl.blend_i422_10le, .overlay = bl.blend_i422_10le, .checker = bl.fill_checker_i420_10le, .color = bl.fill_color_high_le },
        c.GST_VIDEO_FORMAT_I422_10BE => .{ .blend = bl.blend_i422_10be, .overlay = bl.blend_i422_10be, .checker = bl.fill_checker_i420_10be, .color = bl.fill_color_high_be },
        c.GST_VIDEO_FORMAT_I420_12LE => .{ .blend = bl.blend_i420_12le, .overlay = bl.blend_i420_12le, .checker = bl.fill_checker_i420_12le, .color = bl.fill_color_high_le },
        c.GST_VIDEO_FORMAT_I420_12BE => .{ .blend = bl.blend_i420_12be, .overlay = bl.blend_i420_12be, .checker = bl.fill_checker_i420_12be, .color = bl.fill_color_high_be },
        c.GST_VIDEO_FORMAT_I420_10LE => .{ .blend = bl.blend_i420_10le, .overlay = bl.blend_i420_10le, .checker = bl.fill_checker_i420_10le, .color = bl.fill_color_high_le },
        c.GST_VIDEO_FORMAT_I420_10BE => .{ .blend = bl.blend_i420_10be, .overlay = bl.blend_i420_10be, .checker = bl.fill_checker_i420_10be, .color = bl.fill_color_high_be },
        c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_YV12 => .{ .blend = bl.blend_i420, .overlay = bl.blend_i420, .checker = bl.fill_checker_planar, .color = bl.fill_color_planar },
        c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV21 => .{ .blend = bl.blend_nv, .overlay = bl.blend_nv, .checker = bl.fill_checker_nv, .color = bl.fill_color_nv },
        c.GST_VIDEO_FORMAT_Y41B => .{ .blend = bl.blend_y41b, .overlay = bl.blend_y41b, .checker = bl.fill_checker_planar, .color = bl.fill_color_planar },
        c.GST_VIDEO_FORMAT_RGB => .{ .blend = bl.blend_rgb, .overlay = bl.blend_rgb, .checker = bl.fill_checker_rgb, .color = bl.fill_color_rgb },
        c.GST_VIDEO_FORMAT_BGR => .{ .blend = bl.blend_rgb, .overlay = bl.blend_rgb, .checker = bl.fill_checker_rgb, .color = bl.fill_color_bgr },
        c.GST_VIDEO_FORMAT_xRGB => .{ .blend = bl.blend_rgbx, .overlay = bl.blend_rgbx, .checker = bl.fill_checker_xrgb, .color = bl.fill_color_xrgb },
        c.GST_VIDEO_FORMAT_xBGR => .{ .blend = bl.blend_rgbx, .overlay = bl.blend_rgbx, .checker = bl.fill_checker_xrgb, .color = bl.fill_color_xbgr },
        c.GST_VIDEO_FORMAT_RGBx => .{ .blend = bl.blend_rgbx, .overlay = bl.blend_rgbx, .checker = bl.fill_checker_rgbx, .color = bl.fill_color_rgbx },
        c.GST_VIDEO_FORMAT_BGRx => .{ .blend = bl.blend_rgbx, .overlay = bl.blend_rgbx, .checker = bl.fill_checker_rgbx, .color = bl.fill_color_bgrx },
        c.GST_VIDEO_FORMAT_ARGB64 => .{ .blend = bl.blend_argb64, .overlay = bl.overlay_argb64, .checker = bl.fill_checker_argb64, .color = bl.fill_color_argb64 },
        c.GST_VIDEO_FORMAT_AYUV64 => .{ .blend = bl.blend_argb64, .overlay = bl.overlay_argb64, .checker = bl.fill_checker_ayuv64, .color = bl.fill_color_argb64 },
        else => null,
    };
}

fn fnsOf(s: *Self) Fns {
    return .{ .blend = @ptrCast(s.blend.?), .overlay = @ptrCast(s.overlay.?), .checker = @ptrCast(s.fill_checker.?), .color = @ptrCast(s.fill_color.?) };
}

fn setFunctions(s: *Self, info: *const c.GstVideoInfo) bool {
    if (s.intermediate_frame != null) c.gst_buffer_unref(s.intermediate_frame);
    s.intermediate_frame = null;
    if (s.intermediate_convert) |cv| c.gst_video_converter_free(cv);
    s.intermediate_convert = null;
    s.blend = null;
    s.overlay = null;
    s.fill_checker = null;
    s.fill_color = null;
    s.intermediate_info = info.*;
    const fi = info.finfo;
    var chosen = fns(fi[0].format);
    if (chosen == null) {
        const yuv = (fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV) != 0;
        const deep = fi[0].depth[0] != 8;
        const fmt: c.GstVideoFormat = if (yuv) (if (deep) c.GST_VIDEO_FORMAT_AYUV64 else c.GST_VIDEO_FORMAT_AYUV) else (if (deep) c.GST_VIDEO_FORMAT_ARGB64 else c.GST_VIDEO_FORMAT_ARGB);
        chosen = fns(fmt);
        const ii = &s.intermediate_info;
        _ = c.gst_video_info_set_interlaced_format(ii, fmt, info.interlace_mode, @intCast(info.width), @intCast(info.height));
        ii.par_n = info.par_n;
        ii.par_d = info.par_d;
        ii.fps_n = info.fps_n;
        ii.fps_d = info.fps_d;
        ii.flags = info.flags;
        if ((fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_GRAY) == 0) ii.colorimetry = info.colorimetry;
        s.intermediate_frame = c.gst_buffer_new_allocate(null, s.intermediate_info.size, null);
    }
    const f = chosen.?;
    s.blend = @ptrCast(f.blend);
    s.overlay = @ptrCast(f.overlay);
    s.fill_checker = @ptrCast(f.checker);
    s.fill_color = @ptrCast(f.color);
    var off = [_]c.gint{0} ** c.GST_VIDEO_MAX_COMPONENTS;
    var sc = [_]c.gint{0} ** c.GST_VIDEO_MAX_COMPONENTS;
    c.gst_video_color_range_offsets(s.intermediate_info.colorimetry.range, s.intermediate_info.finfo, &off, &sc);
    if ((fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV) != 0) {
        s.black[0] = off[0];
        s.white[0] = sc[0] + off[0];
        for (1..3) |i| {
            s.black[i] = off[i];
            s.white[i] = off[i];
        }
    } else {
        for (0..3) |i| {
            s.black[i] = off[i];
            s.white[i] = sc[i] + off[i];
        }
    }
    return true;
}

fn fixateCaps(agg: [*c]c.GstAggregator, caps: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(agg);
    var bw: c.gint = -1;
    var bh: c.gint = -1;
    var bfn: c.gint = -1;
    var bfd: c.gint = -1;
    var par_n: c.gint = 1;
    var par_d: c.gint = 1;
    var best: f64 = 0;
    var ret = c.gst_caps_make_writable(caps);
    const st = c.gst_caps_get_structure(ret, 0);
    if (c.gst_structure_has_field(st, "pixel-aspect-ratio") != 0) {
        _ = c.gst_structure_fixate_field_nearest_fraction(st, "pixel-aspect-ratio", 1, 1);
        _ = c.gst_structure_get_fraction(st, "pixel-aspect-ratio", &par_n, &par_d);
    }
    cm.lock(s);
    var l = @as(*c.GstElement, @ptrCast(s)).sinkpads;
    while (l != null) : (l = l.*.next) {
        const p = pad(l.*.data);
        if (c.gst_aggregator_pad_is_inactive(@ptrCast(p)) != 0) continue;
        const info = vinfo(p);
        var w: c.gint = 0;
        var h: c.gint = 0;
        var xo: c.gint = 0;
        var yo: c.gint = 0;
        outputSize(s, p, par_n, par_d, &w, &h, &xo, &yo);
        if (w == 0 or h == 0) continue;
        const tw = w + @max(p.xpos + 2 * xo, 0);
        const th = h + @max(p.ypos + 2 * yo, 0);
        if (bw < tw) bw = tw;
        if (bh < th) bh = th;
        var cur: f64 = 0;
        if (info.fps_d != 0) c.gst_util_fraction_to_double(info.fps_n, info.fps_d, &cur);
        if (best < cur) {
            best = cur;
            bfn = info.fps_n;
            bfd = info.fps_d;
        }
    }
    cm.unlock(s);
    if (bfn <= 0 or bfd <= 0 or best == 0.0) {
        bfn = 25;
        bfd = 1;
    }
    _ = c.gst_structure_fixate_field_nearest_int(st, "width", bw);
    _ = c.gst_structure_fixate_field_nearest_int(st, "height", bh);
    _ = c.gst_structure_fixate_field_nearest_fraction(st, "framerate", bfn, bfd);
    ret = c.gst_caps_fixate(ret);
    return ret;
}

fn negotiatedCaps(agg: [*c]c.GstAggregator, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(agg);
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    if (!setFunctions(s, &info)) return 0;
    var n_sdr: c.guint = 0;
    var n_hlg: c.guint = 0;
    var n_pq: c.guint = 0;
    cm.lock(s);
    var l = @as(*c.GstElement, @ptrCast(s)).sinkpads;
    while (l != null) : (l = l.*.next) {
        const vi = vinfo(l.*.data);
        if (vi.finfo == null) continue;
        switch (vi.colorimetry.transfer) {
            c.GST_VIDEO_TRANSFER_SMPTE2084 => n_pq += 1,
            c.GST_VIDEO_TRANSFER_ARIB_STD_B67 => n_hlg += 1,
            else => n_sdr += 1,
        }
    }
    cm.unlock(s);
    const DOMAIN = "gst-plugins-base-1.0";
    if (n_sdr > 0) {
        if (n_hlg > 0 or n_pq > 0) cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_NOT_IMPLEMENTED, c.g_strdup(cm.tr(DOMAIN, "Mixing SDR and HDR contents would result in color loss")), null, FILE, "_negotiated_caps", 1433);
    } else if (n_hlg > 0 and n_pq > 0) {
        cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_NOT_IMPLEMENTED, c.g_strdup(cm.tr(DOMAIN, "Mixing HDR10 and HLG contents would result in color loss")), null, FILE, "_negotiated_caps", 1437);
    }
    var n: c.guint = if (s.max_threads == 0) c.g_get_num_processors() else s.max_threads;
    if (@divTrunc(@as(c.guint, @intCast(info.height)), n) < 200) n = @divTrunc(@as(c.guint, @intCast(info.height)) + 199, 200);
    if (n < 1) n = 1;
    s.n_threads = n;
    if (s.intermediate_frame != null) {
        var config: ?*c.GstStructure = null;
        const pool = c.gst_video_aggregator_get_execution_task_pool(&s.parent);
        if (pool != null and n > 1) {
            config = c.gst_structure_new_static_str_empty("GstVideoConverterConfig");
            c.gst_structure_set_static_str(config, c.GST_VIDEO_CONVERTER_OPT_THREADS, c.G_TYPE_UINT, n, @as(?*anyopaque, null));
        }
        s.intermediate_convert = c.gst_video_converter_new_with_pool(&s.intermediate_info, &info, config, pool);
        if (pool) |pl| c.gst_object_unref(pl);
    }
    return @as(*c.GstAggregatorClass, @ptrCast(parent.?)).negotiated_src_caps.?(agg, caps);
}

fn stop(agg: [*c]c.GstAggregator) callconv(.c) c.gboolean {
    const s = me(agg);
    if (s.intermediate_frame != null) c.gst_buffer_unref(s.intermediate_frame);
    s.intermediate_frame = null;
    if (s.intermediate_convert) |cv| c.gst_video_converter_free(cv);
    s.intermediate_convert = null;
    return @as(*c.GstAggregatorClass, @ptrCast(parent.?)).stop.?(agg);
}

fn shouldDrawBackground(s: *Self) bool {
    const bg = c.GstVideoRectangle{ .x = 0, .y = 0, .w = 0, .h = 0 };
    cm.lock(s);
    defer cm.unlock(s);
    var r = bg;
    r.w = s.parent.info.width;
    r.h = s.parent.info.height;
    var l = @as(*c.GstElement, @ptrCast(s)).sinkpads;
    while (l != null) : (l = l.*.next) {
        if (c.gst_aggregator_pad_is_inactive(@ptrCast(@alignCast(l.*.data))) != 0 or c.gst_video_aggregator_pad_get_prepared_frame(@ptrCast(@alignCast(l.*.data))) == null) continue;
        if (obscures(s, l.*.data, r)) return false;
    }
    return true;
}

fn canCopy(a: *c.GstVideoFrame, b: *c.GstVideoFrame) bool {
    return a.info.finfo[0].format == b.info.finfo[0].format and a.info.height == b.info.height and a.info.width == b.info.width;
}

const PadInfo = struct { frame: *c.GstVideoFrame, pad: *Pad, mode: c.gint };

fn drawBackground(s: *Self, out: *c.GstVideoFrame, ys: c.guint, ye: c.guint) bl.Blend {
    const f = fnsOf(s);
    switch (s.background) {
        BG_CHECKER => f.checker(out, ys, ye),
        BG_BLACK => f.color(out, ys, ye, s.black[0], s.black[1], s.black[2]),
        BG_WHITE => f.color(out, ys, ye, s.white[0], s.white[1], s.white[2]),
        BG_TRANSPARENT => {
            const fi = out.info.finfo;
            const np = fi[0].n_planes;
            for (0..np) |plane| {
                var comp: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
                c.gst_video_format_info_component(fi, @intCast(plane), &comp);
                const k: usize = @intCast(comp[0]);
                const cw = -((-out.info.width) >> @intCast(fi[0].w_sub[k]));
                const rowsize: usize = @intCast(cw * fi[0].pixel_stride[k]);
                const span: c.gint = @as(c.gint, @intCast(ye)) - @as(c.gint, @intCast(ys));
                const h = -((-span) >> @intCast(fi[0].h_sub[k]));
                const yoff = -((-@as(c.gint, @intCast(ys))) >> @intCast(fi[0].h_sub[k]));
                const pst = out.info.stride[plane];
                var p: [*]u8 = @ptrCast(out.data[plane].?);
                p += @as(usize, @intCast(yoff * pst));
                var i: c.gint = 0;
                while (i < h) : (i += 1) {
                    @memset(p[0..rowsize], 0);
                    p += @as(usize, @intCast(pst));
                }
            }
            return f.overlay;
        },
        else => {},
    }
    return f.blend;
}

fn copyMetas(s: *Self, p: *Pad, in: *c.GstVideoFrame, out: [*c]c.GstBuffer) void {
    var state: c.gpointer = null;
    const tags = [_][*c]const u8{ c.GST_META_TAG_VIDEO_STR, c.GST_META_TAG_VIDEO_ORIENTATION_STR, c.GST_META_TAG_VIDEO_SIZE_STR, c.GST_META_TAG_VIDEO_COLORSPACE_STR, null };
    var m: c.GstVideoMetaTransformMatrix = undefined;
    const in_r = c.GstVideoRectangle{ .x = 0, .y = 0, .w = in.info.width, .h = in.info.height };
    const out_r = c.GstVideoRectangle{ .x = p.xpos + p.x_offset, .y = p.ypos + p.y_offset, .w = in.info.width, .h = in.info.height };
    c.gst_video_meta_transform_matrix_init(&m, &in.info, &in_r, &s.parent.info, &out_r);
    while (true) {
        const meta = c.gst_buffer_iterate_meta(in.buffer, &state);
        if (meta == null) break;
        const info = meta.*.info;
        if (info.*.transform_func == null) continue;
        if (c.gst_meta_api_type_tags_contain_only(info.*.api, @ptrCast(@constCast(&tags))) == 0) continue;
        _ = info.*.transform_func.?(out, meta, in.buffer, c.gst_video_meta_transform_matrix_get_quark(), &m);
    }
}

fn aggregateFrames(va: [*c]c.GstVideoAggregator, outbuf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(va);
    var out_frame: c.GstVideoFrame = undefined;
    var inter: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&out_frame, &va[0].info, outbuf, c.GST_MAP_WRITE | c.GST_VIDEO_FRAME_MAP_FLAG_NO_REF) == 0) return c.GST_FLOW_ERROR;
    var outframe = &out_frame;
    if (s.intermediate_frame != null) {
        if (c.gst_video_frame_map(&inter, &s.intermediate_info, s.intermediate_frame, c.GST_MAP_READWRITE | c.GST_VIDEO_FRAME_MAP_FLAG_NO_REF) == 0) {
            c.gst_video_frame_unmap(&out_frame);
            return c.GST_FLOW_ERROR;
        }
        outframe = &inter;
    }
    var draw_bg = shouldDrawBackground(s);
    cm.lock(s);
    var infos: std.ArrayListUnmanaged(PadInfo) = .empty;
    defer infos.deinit(std.heap.c_allocator);
    var any = false;
    var l = @as(*c.GstElement, @ptrCast(s)).sinkpads;
    while (l != null) : (l = l.*.next) {
        if (c.gst_video_aggregator_pad_get_prepared_frame(@ptrCast(@alignCast(l.*.data))) != null) any = true;
    }
    if (!any) draw_bg = true;
    var drawn = false;
    l = @as(*c.GstElement, @ptrCast(s)).sinkpads;
    while (l != null) : (l = l.*.next) {
        const p = pad(l.*.data);
        const fr = c.gst_video_aggregator_pad_get_prepared_frame(@ptrCast(p));
        const mode: c.gint = switch (p.op) {
            OP_SOURCE => bl.MODE_SOURCE,
            OP_ADD => bl.MODE_ADD,
            else => bl.MODE_OVER,
        };
        if (fr != null) {
            if (!drawn and !draw_bg and canCopy(fr, outframe)) {
                _ = c.gst_video_frame_copy(outframe, fr);
                copyMetas(s, p, fr, outbuf);
            } else {
                infos.append(std.heap.c_allocator, .{ .frame = fr, .pad = p, .mode = mode }) catch {};
            }
            drawn = true;
        }
    }
    const n = @max(s.n_threads, 1);
    const height: c.guint = @intCast(outframe.info.height);
    const per = (height + n - 1) / n;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const ys = i * per;
        const ye = @min((i + 1) * per, height);
        var composite = fnsOf(s).blend;
        if (draw_bg) composite = drawBackground(s, outframe, ys, ye);
        for (infos.items) |pi| composite(pi.frame, pi.pad.xpos + pi.pad.x_offset, pi.pad.ypos + pi.pad.y_offset, pi.pad.alpha, outframe, @intCast(ys), @intCast(ye), pi.mode);
    }
    cm.unlock(s);
    if (s.intermediate_frame != null) {
        c.gst_video_converter_frame(s.intermediate_convert, &inter, &out_frame);
        c.gst_video_frame_unmap(&inter);
    }
    c.gst_video_frame_unmap(&out_frame);
    cm.lock(s);
    for (infos.items) |pi| copyMetas(s, pi.pad, pi.frame, outbuf);
    cm.unlock(s);
    return c.GST_FLOW_OK;
}

fn requestNewPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, caps: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const np = @as(*c.GstElementClass, @ptrCast(parent.?)).request_new_pad.?(e, templ, name, caps);
    if (np == null) return null;
    c.gst_child_proxy_child_added(@ptrCast(e), @ptrCast(@alignCast(np)), cm.obj(np).name);
    return np;
}

fn releasePad(e: [*c]c.GstElement, p: ?*c.GstPad) callconv(.c) void {
    c.gst_child_proxy_child_removed(@ptrCast(e), @ptrCast(@alignCast(p)), cm.obj(p).name);
    @as(*c.GstElementClass, @ptrCast(parent.?)).release_pad.?(e, p);
}

const MouseData = extern struct { event: [*c]c.GstEvent, res: c.gboolean };

fn mouseEvent(e: [*c]c.GstElement, p0: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(e);
    const p = pad(p0);
    const d: *MouseData = @ptrCast(@alignCast(data));
    const st = c.gst_structure_copy(c.gst_event_get_structure(d.event));
    var ex: f64 = 0;
    var ey: f64 = 0;
    _ = c.gst_structure_get(st, "pointer_x", c.G_TYPE_DOUBLE, &ex, "pointer_y", c.G_TYPE_DOUBLE, &ey, @as(?*anyopaque, null));
    var r = c.GstVideoRectangle{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var ox: c.gint = 0;
    var oy: c.gint = 0;
    outputSize(s, p, s.parent.info.par_n, s.parent.info.par_d, &r.w, &r.h, &ox, &oy);
    r.x = p.xpos + ox;
    r.y = p.ypos + oy;
    const px: c.gint = @intFromFloat(@trunc(ex));
    const py: c.gint = @intFromFloat(@trunc(ey));
    if (px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h) {
        const w: f64 = @floatFromInt(vinfo(p).width);
        const h: f64 = @floatFromInt(vinfo(p).height);
        const x = (ex - @as(f64, @floatFromInt(r.x))) * (w / @as(f64, @floatFromInt(r.w)));
        const y = (ey - @as(f64, @floatFromInt(r.y))) * (h / @as(f64, @floatFromInt(r.h)));
        c.gst_structure_set_static_str(st, "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, @as(?*anyopaque, null));
        d.res |= c.gst_pad_push_event(p0, c.gst_event_new_navigation(st));
    } else c.gst_structure_free(st);
    return 1;
}

fn srcEvent(agg: [*c]c.GstAggregator, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(ev) == c.GST_EVENT_NAVIGATION) {
        switch (c.gst_navigation_event_get_type(ev)) {
            c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_PRESS, c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_RELEASE, c.GST_NAVIGATION_EVENT_MOUSE_MOVE, c.GST_NAVIGATION_EVENT_MOUSE_SCROLL => {
                var d = MouseData{ .event = ev, .res = 0 };
                _ = c.gst_element_foreach_sink_pad(@ptrCast(agg), mouseEvent, &d);
                c.gst_event_unref(ev);
                return d.res;
            },
            else => {},
        }
    }
    return @as(*c.GstAggregatorClass, @ptrCast(parent.?)).src_event.?(agg, ev);
}

fn sinkQuery(agg: [*c]c.GstAggregator, bp: ?*c.GstAggregatorPad, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.queryType(q) != c.GST_QUERY_ALLOCATION) return @as(*c.GstAggregatorClass, @ptrCast(parent.?)).sink_query.?(agg, bp, q);
    var caps: [*c]c.GstCaps = null;
    var info: c.GstVideoInfo = undefined;
    c.gst_query_parse_allocation(q, &caps, null);
    if (caps == null) return 0;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    const size: c.guint = @intCast(info.size);
    const pool = c.gst_video_buffer_pool_new();
    const name = c.g_strdup_printf("%s-pool", cm.obj(agg).name);
    c.g_object_set(pool, "name", name, @as(?*anyopaque, null));
    c.g_free(name);
    const st = c.gst_buffer_pool_get_config(pool);
    c.gst_buffer_pool_config_set_params(st, caps, size, 0, 0);
    if (c.gst_buffer_pool_set_config(pool, st) == 0) {
        c.gst_object_unref(pool);
        return 0;
    }
    c.gst_query_add_allocation_pool(q, pool, size, 0, 0);
    c.gst_object_unref(pool);
    c.gst_query_add_allocation_meta(q, c.gst_video_meta_api_get_type(), null);
    return 1;
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_BACKGROUND => c.g_value_set_enum(v, s.background),
        PROP_ZERO_SIZE => c.g_value_set_boolean(v, s.zero_size_is_unscaled),
        PROP_MAX_THREADS => c.g_value_set_uint(v, s.max_threads),
        PROP_IGNORE_INACTIVE => c.g_value_set_boolean(v, c.gst_aggregator_get_ignore_inactive_pads(@ptrCast(s))),
        else => cm.warnInvalid(FILE, o, id, spec, 776),
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_BACKGROUND => s.background = c.g_value_get_enum(v),
        PROP_ZERO_SIZE => s.zero_size_is_unscaled = c.g_value_get_boolean(v),
        PROP_MAX_THREADS => s.max_threads = c.g_value_get_uint(v),
        PROP_IGNORE_INACTIVE => c.gst_aggregator_set_ignore_inactive_pads(@ptrCast(s), c.g_value_get_boolean(v)),
        else => cm.warnInvalid(FILE, o, id, spec, 802),
    }
}

fn childByIndex(cp: ?*c.GstChildProxy, index: c.guint) callconv(.c) [*c]c.GObject {
    const s = me(cp);
    cm.lock(s);
    defer cm.unlock(s);
    const o = c.g_list_nth_data(@as(*c.GstElement, @ptrCast(s)).sinkpads, index);
    if (o != null) _ = c.gst_object_ref(o);
    return @ptrCast(@alignCast(o));
}

fn childrenCount(cp: ?*c.GstChildProxy) callconv(.c) c.guint {
    const s = me(cp);
    cm.lock(s);
    defer cm.unlock(s);
    return @as(*c.GstElement, @ptrCast(s)).numsinkpads;
}

fn proxyInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstChildProxyInterface = @ptrCast(@alignCast(iface));
    i.get_child_by_index = childByIndex;
    i.get_children_count = childrenCount;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    const ac: *c.GstAggregatorClass = @ptrCast(@alignCast(k));
    ac.sink_query = sinkQuery;
    ac.src_event = srcEvent;
    ac.fixate_src_caps = fixateCaps;
    ac.negotiated_src_caps = negotiatedCaps;
    ac.stop = stop;
    @as(*c.GstVideoAggregatorClass, @ptrCast(@alignCast(k))).aggregate_frames = aggregateFrames;
    _ = c._gst_debug_category_new("compositor_blend", 0, "video compositor blending functions");
    c.g_object_class_install_property(oc, PROP_BACKGROUND, c.g_param_spec_enum("background", "Background", "Background type", bgType(), BG_CHECKER, cm.RW));
    c.g_object_class_install_property(oc, PROP_ZERO_SIZE, c.g_param_spec_boolean("zero-size-is-unscaled", "Zero size is unscaled", "If TRUE, then input video is unscaled in that dimension if width or height is 0 (for backwards compatibility)", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_MAX_THREADS, c.g_param_spec_uint("max-threads", "Max Threads", "Maximum number of blending/rendering worker threads to spawn (0 = auto)", 0, std.math.maxInt(c.gint), 0, cm.MUTABLE_READY | cm.RW));
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &src_t, c.gst_aggregator_pad_get_type());
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &sink_t, padType());
    c.gst_element_class_set_static_metadata(ec, "Compositor", "Filter/Editor/Video/Compositor", "Composite multiple video streams", "Wim Taymans <wim@fluendo.com>, Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    c.g_object_class_install_property(oc, PROP_IGNORE_INACTIVE, c.g_param_spec_boolean("ignore-inactive-pads", "Ignore inactive pads", "Avoid timing out waiting for inactive pads", 0, cm.RW));
    c.gst_type_mark_as_plugin_api(padType(), 0);
    c.gst_type_mark_as_plugin_api(opType(), 0);
    c.gst_type_mark_as_plugin_api(bgType(), 0);
    _ = c._gst_debug_category_new("compositor", 0, "compositor");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.background = BG_CHECKER;
    s.zero_size_is_unscaled = 1;
    s.max_threads = 0;
    s.n_threads = 1;
    s.intermediate_frame = null;
    s.intermediate_convert = null;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_video_aggregator_get_type(), "GstCompositor", Class, Self, classInit, init);
            const iface = c.GInterfaceInfo{ .interface_init = proxyInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_child_proxy_get_type(), &iface);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "compositor", c.GST_RANK_PRIMARY + 1, getType()) != 0;
}
