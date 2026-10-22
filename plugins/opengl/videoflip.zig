const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglvideoflip.c";
const PROP_METHOD = 1;
const PROP_VIDEO_DIRECTION = 2;
const CAPS = "video/x-raw(memory:GLMemory), format = (string) RGBA, width = " ++ el.SIZE ++ ", height = " ++ el.SIZE ++ ", framerate = " ++ el.FPS ++ ", texture-target = (string) 2D";

const Self = extern struct {
    bin: c.GstBin,
    srcpad: ?*c.GstPad,
    sinkpad: ?*c.GstPad,
    input_capsfilter: [*c]c.GstElement,
    transformation: [*c]c.GstElement,
    output_capsfilter: [*c]c.GstElement,
    sink_probe: c.gulong,
    src_probe: c.gulong,
    input_caps: [*c]c.GstCaps,
    method: c.GstVideoOrientationMethod,
    tag_method: c.GstVideoOrientationMethod,
    active_method: c.GstVideoOrientationMethod,
    aspect: f32,
};

const Class = extern struct {
    parent: c.GstBinClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var method_once: cm.Once = .{};
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn methodType() c.GType {
    return method_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_VIDEO_ORIENTATION_IDENTITY, .value_name = "Identity (no rotation)", .value_nick = "none" },
            .{ .value = c.GST_VIDEO_ORIENTATION_90R, .value_name = "Rotate clockwise 90 degrees", .value_nick = "clockwise" },
            .{ .value = c.GST_VIDEO_ORIENTATION_180, .value_name = "Rotate 180 degrees", .value_nick = "rotate-180" },
            .{ .value = c.GST_VIDEO_ORIENTATION_90L, .value_name = "Rotate counter-clockwise 90 degrees", .value_nick = "counterclockwise" },
            .{ .value = c.GST_VIDEO_ORIENTATION_HORIZ, .value_name = "Flip horizontally", .value_nick = "horizontal-flip" },
            .{ .value = c.GST_VIDEO_ORIENTATION_VERT, .value_name = "Flip vertically", .value_nick = "vertical-flip" },
            .{ .value = c.GST_VIDEO_ORIENTATION_UL_LR, .value_name = "Flip across upper left/lower right diagonal", .value_nick = "upper-left-diagonal" },
            .{ .value = c.GST_VIDEO_ORIENTATION_UR_LL, .value_name = "Flip across upper right/lower left diagonal", .value_nick = "upper-right-diagonal" },
            .{ .value = c.GST_VIDEO_ORIENTATION_AUTO, .value_name = "Select flip method based on image-orientation tag", .value_nick = "automatic" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstGLVideoFlipMethod", &values);
        }
    }.f);
}

fn transformCaps(s: *Self, caps: [*c]c.GstCaps) [*c]c.GstCaps {
    const out = c.gst_caps_copy(caps);
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(out)) : (i += 1) {
        const st = c.gst_caps_get_structure(out, i);
        var w: c.gint = 0;
        var h: c.gint = 0;
        if (c.gst_structure_get_int(st, "width", &w) == 0 or c.gst_structure_get_int(st, "height", &h) == 0) continue;
        switch (s.active_method) {
            c.GST_VIDEO_ORIENTATION_90R, c.GST_VIDEO_ORIENTATION_90L, c.GST_VIDEO_ORIENTATION_UL_LR, c.GST_VIDEO_ORIENTATION_UR_LL => {
                c.gst_structure_set(st, "width", c.G_TYPE_INT, h, "height", c.G_TYPE_INT, w, @as(?*anyopaque, null));
                var pn: c.gint = 0;
                var pd: c.gint = 0;
                if (c.gst_structure_get_fraction(st, "pixel-aspect-ratio", &pn, &pd) != 0 and (pn != 1 or pd != 1)) {
                    var v = std.mem.zeroes(c.GValue);
                    _ = c.g_value_init(&v, c.gst_fraction_get_type());
                    c.gst_value_set_fraction(&v, pd, pn);
                    c.gst_structure_set_value(st, "pixel-aspect-ratio", &v);
                    c.g_value_unset(&v);
                }
            },
            c.GST_VIDEO_ORIENTATION_IDENTITY, c.GST_VIDEO_ORIENTATION_180, c.GST_VIDEO_ORIENTATION_HORIZ, c.GST_VIDEO_ORIENTATION_VERT => {},
            else => c.g_assertion_message_expr("GStreamer", FILE, 304, "_transform_caps", null),
        }
    }
    return out;
}

fn setActive(s: *Self, method: c.GstVideoOrientationMethod, caps: [*c]c.GstCaps) void {
    var rot: f32 = 0;
    var sx: f32 = 1;
    var sy: f32 = 1;
    const a: f64 = s.aspect;
    switch (method) {
        c.GST_VIDEO_ORIENTATION_90R => {
            sx = @floatCast(sx * a);
            sy = @floatCast(sy * (1.0 / a));
            rot = 90;
        },
        c.GST_VIDEO_ORIENTATION_180 => rot = 180,
        c.GST_VIDEO_ORIENTATION_90L => {
            sx = @floatCast(sx * a);
            sy = @floatCast(sy * (1.0 / a));
            rot = 270;
        },
        c.GST_VIDEO_ORIENTATION_HORIZ => sx *= -1,
        c.GST_VIDEO_ORIENTATION_UR_LL => {
            sx = @floatCast(sx * -a);
            sy = @floatCast(sy * (1.0 / a));
            rot = 90;
        },
        c.GST_VIDEO_ORIENTATION_VERT => {
            sx *= -1;
            rot = 180;
        },
        c.GST_VIDEO_ORIENTATION_UL_LR => {
            sx = @floatCast(sx * -a);
            sy = @floatCast(sy * (1.0 / a));
            rot = 270;
        },
        else => {},
    }
    s.active_method = method;
    const out = transformCaps(s, caps);
    _ = c.gst_caps_replace(&s.input_caps, caps);
    const src = c.gst_element_get_static_pad(s.transformation, "src");
    const templ = c.gst_pad_get_pad_template_caps(src);
    c.gst_object_unref(src);
    c.gst_caps_append(out, c.gst_caps_ref(templ));
    cm.unlock(s);
    c.g_object_set(s.input_capsfilter, "caps", caps, @as(?*anyopaque, null));
    c.g_object_set(s.output_capsfilter, "caps", out, @as(?*anyopaque, null));
    c.g_object_set(s.transformation, "rotation-z", @as(f64, rot), "scale-x", @as(f64, sx), "scale-y", @as(f64, sy), @as(?*anyopaque, null));
    c.gst_caps_unref(out);
    cm.lock(s);
}

fn setMethod(s: *Self, m: c.GstVideoOrientationMethod, from_tag: bool) void {
    cm.lock(s);
    defer cm.unlock(s);
    if (m == c.GST_VIDEO_ORIENTATION_CUSTOM) return;
    if (from_tag) s.tag_method = m else s.method = m;
    const active = if (s.method == c.GST_VIDEO_ORIENTATION_AUTO) s.tag_method else s.method;
    if (s.input_caps != null) setActive(s, active, s.input_caps) else s.active_method = active;
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (parent_obj.constructed) |f| f(o);
    if (s.method == c.GST_VIDEO_ORIENTATION_IDENTITY) setMethod(s, c.GST_VIDEO_ORIENTATION_IDENTITY, false);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    _ = c.gst_caps_replace(&me(o).input_caps, null);
    parent_obj.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_METHOD or id == PROP_VIDEO_DIRECTION) setMethod(me(o), @intCast(c.g_value_get_enum(v)), false) else cm.warnInvalid(FILE, o, id, spec, 428);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_METHOD or id == PROP_VIDEO_DIRECTION) c.g_value_set_enum(v, @intCast(me(o).method)) else cm.warnInvalid(FILE, o, id, spec, 445);
}

fn forward(target: ?*c.GstPad, q: [*c]c.GstQuery, peer: bool) c.GstPadProbeReturn {
    const ok = if (peer) c.gst_pad_peer_query(target, q) else c.gst_pad_query(target, q);
    return if (ok != 0) c.GST_PAD_PROBE_HANDLED else c.GST_PAD_PROBE_DROP;
}

fn sinkProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const s = me(data);
    if (info[0].type & c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM != 0) {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
        switch (e[0].type) {
            c.GST_EVENT_TAG => {
                var tags: ?*c.GstTagList = null;
                c.gst_event_parse_tag(e, @ptrCast(&tags));
                var m: c.GstVideoOrientationMethod = 0;
                if (c.gst_video_orientation_from_tag(tags, &m) != 0) setMethod(s, m, true);
            },
            c.GST_EVENT_CAPS => {
                var caps: [*c]c.GstCaps = null;
                c.gst_event_parse_caps(e, &caps);
                cm.lock(s);
                var vi: c.GstVideoInfo = undefined;
                s.aspect = if (c.gst_video_info_from_caps(&vi, caps) != 0) @as(f32, @floatFromInt(vi.width)) / @as(f32, @floatFromInt(vi.height)) else 1;
                setActive(s, s.active_method, caps);
                cm.unlock(s);
            },
            else => {},
        }
    } else if (info[0].type & c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM != 0) {
        const q: [*c]c.GstQuery = @ptrCast(@alignCast(info[0].data));
        if (q[0].type == c.GST_QUERY_CAPS or q[0].type == c.GST_QUERY_ACCEPT_CAPS) {
            const pad = c.gst_element_get_static_pad(s.transformation, "sink");
            defer c.gst_object_unref(pad);
            return forward(pad, q, false);
        }
    }
    return c.GST_PAD_PROBE_OK;
}

fn srcProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (info[0].type & c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM != 0) {
        const q: [*c]c.GstQuery = @ptrCast(@alignCast(info[0].data));
        if (q[0].type == c.GST_QUERY_CAPS or q[0].type == c.GST_QUERY_ACCEPT_CAPS) return forward(me(data).srcpad, q, true);
    }
    return c.GST_PAD_PROBE_OK;
}

fn directionInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_obj = el.parentOf(c.GObjectClass, k);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.constructed = constructed;
    c.g_object_class_install_property(oc, PROP_METHOD, c.g_param_spec_enum("method", "method", "method (deprecated, use video-direction instead)", methodType(), 0, c.GST_PARAM_CONTROLLABLE | cm.RW));
    c.g_object_class_override_property(oc, PROP_VIDEO_DIRECTION, "video-direction");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "OpenGL video flip filter", "Filter/Effect/Video", "Flip video on the GPU", "Matthew Waters <matthew@centricular.com>");
    c.gst_type_mark_as_plugin_api(methodType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const bin: [*c]c.GstBin = @ptrCast(s);
    s.method = c.GST_VIDEO_ORIENTATION_IDENTITY;
    s.aspect = 1;
    s.input_capsfilter = c.gst_element_factory_make("capsfilter", null);
    _ = c.gst_bin_add(bin, s.input_capsfilter);
    s.transformation = c.gst_element_factory_make("gltransformation", null);
    c.g_object_set(s.transformation, "ortho", @as(c.gboolean, 1), @as(?*anyopaque, null));
    _ = c.gst_bin_add(bin, s.transformation);
    s.output_capsfilter = c.gst_element_factory_make("capsfilter", null);
    _ = c.gst_bin_add(bin, s.output_capsfilter);
    _ = c.gst_element_link_pads(s.input_capsfilter, "src", s.transformation, "sink");
    _ = c.gst_element_link_pads(s.transformation, "src", s.output_capsfilter, "sink");
    var pad = c.gst_element_get_static_pad(s.input_capsfilter, "sink");
    if (pad != null) {
        s.sinkpad = c.gst_ghost_pad_new("sink", pad);
        s.sink_probe = c.gst_pad_add_probe(s.sinkpad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM, sinkProbe, s, null);
        _ = c.gst_element_add_pad(@ptrCast(s), s.sinkpad);
        c.gst_object_unref(pad);
    }
    pad = c.gst_element_get_static_pad(s.transformation, "src");
    s.src_probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM, srcProbe, s, null);
    c.gst_object_unref(pad);
    pad = c.gst_element_get_static_pad(s.output_capsfilter, "src");
    if (pad != null) {
        s.srcpad = c.gst_ghost_pad_new("src", pad);
        _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
        c.gst_object_unref(pad);
    }
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_bin_get_type(), "GstGLVideoFlip", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("glvideoflip", 0, "glvideoflip element");
            const info = c.GInterfaceInfo{ .interface_init = directionInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_video_direction_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glvideoflip", c.GST_RANK_NONE, getType());
}
