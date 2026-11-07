const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FORMATS = "{ RGBx, xRGB, BGRx, xBGR, RGBA, ARGB, BGRA, ABGR, RGB, BGR, GRAY8, GRAY16_LE, GRAY16_BE, AYUV, YUY2, UYVY, YVYU, I420, YV12, Y444, Y42B, Y41B, NV12, NV21 }";
const CAPS = "video/x-raw, format = (string) " ++ FORMATS ++ ", width = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", height = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE;

const PROP_LEFT = 1;
const PROP_RIGHT = 2;
const PROP_TOP = 3;
const PROP_BOTTOM = 4;

const Self = extern struct {
    parent: c.GstVideoFilter,
    left: c.gint,
    right: c.gint,
    top: c.gint,
    bottom: c.gint,
    x: c.gint,
    y: c.gint,
    luma: c.gint,
};

const Class = extern struct {
    parent: c.GstVideoFilterClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn trans(p: anytype) [*c]c.GstBaseTransform {
    return @ptrCast(@alignCast(p));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const n = @max(c.g_value_get_int(v), 0);
    cm.lock(s);
    switch (id) {
        PROP_LEFT => s.left = n,
        PROP_RIGHT => s.right = n,
        PROP_TOP => s.top = n,
        PROP_BOTTOM => s.bottom = n,
        else => {
            cm.unlock(s);
            cm.warnInvalid("gstvideocrop.c", o, id, spec, 0);
            return;
        },
    }
    cm.unlock(s);
    c.gst_base_transform_reconfigure_src(trans(s));
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_LEFT => c.g_value_set_int(v, s.left),
        PROP_RIGHT => c.g_value_set_int(v, s.right),
        PROP_TOP => c.g_value_set_int(v, s.top),
        PROP_BOTTOM => c.g_value_set_int(v, s.bottom),
        else => cm.warnInvalid("gstvideocrop.c", o, id, spec, 0),
    }
}

fn shrink(v: c.gint, d: c.gint) c.gint {
    if (v == std.math.maxInt(c.gint)) return v;
    return @max(v - d, 1);
}

fn grow(v: c.gint, d: c.gint) c.gint {
    if (v > std.math.maxInt(c.gint) - d) return std.math.maxInt(c.gint);
    return v + d;
}

fn adjust(st: ?*c.GstStructure, field: [*c]const u8, d: c.gint, down: bool) void {
    const v = c.gst_structure_get_value(st, field);
    if (v == null) return;
    const t = v.*.g_type;
    if (t == c.G_TYPE_INT) {
        const n = c.g_value_get_int(v);
        c.gst_structure_set(st, field, c.G_TYPE_INT, if (down) shrink(n, d) else grow(n, d), @as(?*anyopaque, null));
    } else if (t == c.gst_int_range_get_type()) {
        const lo = c.gst_value_get_int_range_min(v);
        const hi = c.gst_value_get_int_range_max(v);
        const a = if (down) shrink(lo, d) else grow(lo, d);
        const b = if (down) shrink(hi, d) else grow(hi, d);
        if (a == b) {
            c.gst_structure_set(st, field, c.G_TYPE_INT, a, @as(?*anyopaque, null));
        } else c.gst_structure_set(st, field, c.gst_int_range_get_type(), a, b, @as(?*anyopaque, null));
    } else c.gst_structure_remove_field(st, field);
}

fn transformCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bt);
    cm.lock(s);
    const dw = s.left + s.right;
    const dh = s.top + s.bottom;
    cm.unlock(s);
    const out = c.gst_caps_new_empty();
    const n = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const st = c.gst_structure_copy(c.gst_caps_get_structure(caps, i));
        const down = dir == c.GST_PAD_SINK;
        adjust(st, "width", dw, down);
        adjust(st, "height", dh, down);
        const f = c.gst_caps_features_copy(c.gst_caps_get_features(caps, i));
        c.gst_caps_append_structure_full(out, st, f);
    }
    if (filter != null) {
        const r = c.gst_caps_intersect_full(filter, out, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(out);
        return r;
    }
    return out;
}

fn setInfo(vf: [*c]c.GstVideoFilter, _: [*c]c.GstCaps, in: [*c]c.GstVideoInfo, _: [*c]c.GstCaps, out: [*c]c.GstVideoInfo) callconv(.c) c.gboolean {
    const s = me(vf);
    cm.lock(s);
    const l = s.left;
    const r = s.right;
    const t = s.top;
    const b = s.bottom;
    cm.unlock(s);
    if (l + r >= in.*.width or t + b >= in.*.height) return 0;
    if (out.*.width != in.*.width - l - r or out.*.height != in.*.height - t - b) return 0;
    s.luma = switch (in.*.finfo.*.format) {
        c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_YVYU => 0,
        c.GST_VIDEO_FORMAT_UYVY => 1,
        else => -1,
    };
    s.x = l;
    s.y = t;
    c.gst_base_transform_set_passthrough(trans(s), @intFromBool(l == 0 and r == 0 and t == 0 and b == 0));
    return 1;
}

fn copyFrame(s: *Self, in: [*c]c.GstVideoFrame, out: [*c]c.GstVideoFrame) c.GstFlowReturn {
    const fi = in.*.info.finfo.*;
    var p: c.guint = 0;
    while (p < fi.n_planes) : (p += 1) {
        var comp: c.guint = 0;
        while (comp < fi.n_components and fi.plane[comp] != p) : (comp += 1) {}
        if (comp == fi.n_components) continue;
        const ps: usize = @intCast(fi.pixel_stride[comp]);
        const ws: u5 = @intCast(fi.w_sub[comp]);
        const hs: u5 = @intCast(fi.h_sub[comp]);
        const ip: [4]?*anyopaque = in.*.data;
        const op: [4]?*anyopaque = out.*.data;
        const src: [*]const u8 = @ptrCast(ip[p] orelse return c.GST_FLOW_ERROR);
        const dst: [*]u8 = @ptrCast(op[p] orelse return c.GST_FLOW_ERROR);
        const is: [4]c.gint = in.*.info.stride;
        const os: [4]c.gint = out.*.info.stride;
        const ss: usize = @intCast(is[p]);
        const ds: usize = @intCast(os[p]);
        const x: usize = if (s.luma >= 0) @as(usize, @intCast(s.x & ~@as(c.gint, 1))) * ps else @as(usize, @intCast(s.x >> ws)) * ps;
        const y: usize = @intCast(s.y >> hs);
        const ow: usize = @intCast((out.*.info.width + (@as(c.gint, 1) << ws) - 1) >> ws);
        const oh: usize = @intCast((out.*.info.height + (@as(c.gint, 1) << hs) - 1) >> hs);
        const row = ow * ps;
        var j: usize = 0;
        while (j < oh) : (j += 1) @memcpy(dst[j * ds ..][0..row], src[(y + j) * ss + x ..][0..row]);
        if (s.luma >= 0 and s.x & 1 != 0) {
            const lo: usize = @intCast(s.luma);
            const sx: usize = @intCast(s.x);
            j = 0;
            while (j < oh) : (j += 1) {
                var i: usize = 0;
                while (i + 1 < ow) : (i += 1) dst[j * ds + i * 2 + lo] = src[(y + j) * ss + (sx + i) * 2 + lo];
            }
        }
    }
    return c.GST_FLOW_OK;
}

fn transformFrame(vf: [*c]c.GstVideoFilter, in: [*c]c.GstVideoFrame, out: [*c]c.GstVideoFrame) callconv(.c) c.GstFlowReturn {
    return copyFrame(me(vf), in, out);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const flags = cm.RW | c.GST_PARAM_MUTABLE_PLAYING | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(oc, PROP_LEFT, c.g_param_spec_int("left", "Left", "Pixels to crop at left (-1 to auto-crop)", -1, std.math.maxInt(c.gint), 0, flags));
    c.g_object_class_install_property(oc, PROP_RIGHT, c.g_param_spec_int("right", "Right", "Pixels to crop at right (-1 to auto-crop)", -1, std.math.maxInt(c.gint), 0, flags));
    c.g_object_class_install_property(oc, PROP_TOP, c.g_param_spec_int("top", "Top", "Pixels to crop at top (-1 to auto-crop)", -1, std.math.maxInt(c.gint), 0, flags));
    c.g_object_class_install_property(oc, PROP_BOTTOM, c.g_param_spec_int("bottom", "Bottom", "Pixels to crop at bottom (-1 to auto-crop)", -1, std.math.maxInt(c.gint), 0, flags));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&sink_t));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&src_t));
    c.gst_element_class_set_static_metadata(ec, "Crop", "Filter/Effect/Video", "Crops video into a user-defined region", "Tim-Philipp Müller <tim centricular net>");
    const btc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    btc.transform_caps = transformCaps;
    btc.passthrough_on_same_caps = 0;
    const vfc: *c.GstVideoFilterClass = @ptrCast(@alignCast(k));
    vfc.set_info = setInfo;
    vfc.transform_frame = transformFrame;
    _ = c._gst_debug_category_new("videocrop", 0, "videocrop element");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.left = 0;
    s.right = 0;
    s.top = 0;
    s.bottom = 0;
    s.x = 0;
    s.y = 0;
    s.luma = -1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_video_filter_get_type(), "GstVideoCrop", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "videocrop", c.GST_RANK_NONE, getType()) != 0;
}
