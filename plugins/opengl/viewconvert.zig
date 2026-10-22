const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglviewconvert.c";

const Prop = enum(c.guint) { input_layout = 1, input_flags, output_layout, output_flags, downmix };

const Self = extern struct {
    filter: c.GstGLFilter,
    viewconvert: ?*c.GstGLViewConvert,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.viewconvert != null) c.gst_object_unref(s.viewconvert);
    s.viewconvert = null;
    parent_obj.dispose.?(o);
}

fn asGl(caps: [*c]c.GstCaps) [*c]c.GstCaps {
    const copy = c.gst_caps_copy(caps);
    c.gst_caps_set_simple(copy, "format", c.G_TYPE_STRING, "RGBA", @as(?*anyopaque, null));
    c.gst_caps_set_features(copy, 0, c.gst_caps_features_new_single_static_str(c.GST_CAPS_FEATURE_MEMORY_GL_MEMORY));
    return copy;
}

fn setCaps(f: [*c]c.GstGLFilter, incaps: [*c]c.GstCaps, outcaps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const in = asGl(incaps);
    const out = asGl(outcaps);
    const ok = c.gst_gl_view_convert_set_caps(me(f).viewconvert, in, out);
    c.gst_caps_unref(in);
    c.gst_caps_unref(out);
    return ok;
}

fn internalCaps(f: [*c]c.GstGLFilter, dir: c.GstPadDirection, caps: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    return c.gst_gl_view_convert_transform_caps(me(f).viewconvert, dir, caps, null);
}

fn fixate(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, other: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const res = c.gst_gl_view_convert_fixate_caps(me(bt).viewconvert, dir, caps, other);
    if (c.gst_caps_is_empty(res) != 0) return res;
    return parent.fixate_caps.?(bt, dir, caps, res);
}

fn stop(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    c.gst_gl_view_convert_reset(me(bt).viewconvert);
    return parent.stop.?(bt);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.input_layout), @intFromEnum(Prop.input_flags), @intFromEnum(Prop.output_layout), @intFromEnum(Prop.output_flags) => {
            c.g_object_set_property(@ptrCast(@alignCast(s.viewconvert)), spec[0].name, v);
            c.gst_base_transform_reconfigure_src(@ptrCast(s));
        },
        @intFromEnum(Prop.downmix) => c.g_object_set_property(@ptrCast(@alignCast(s.viewconvert)), spec[0].name, v),
        else => cm.warnInvalid(FILE, o, id, spec, 293),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id >= 1 and id <= 5) c.g_object_get_property(@ptrCast(@alignCast(me(o).viewconvert)), spec[0].name, v) else cm.warnInvalid(FILE, o, id, spec, 314);
}

fn submit(bt: [*c]c.GstBaseTransform, discont: c.gboolean, input: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    const ret = parent.submit_input_buffer.?(bt, discont, input);
    if (ret != c.GST_FLOW_OK or bt[0].queued_buf == null) return ret;
    c.gst_gl_view_convert_set_context(s.viewconvert, el.base(bt).context);
    const r = c.gst_gl_view_convert_submit_input_buffer(s.viewconvert, discont, input);
    bt[0].queued_buf = null;
    return r;
}

fn generate(bt: [*c]c.GstBaseTransform, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const ret = c.gst_gl_view_convert_get_output(me(bt).viewconvert, out);
    if (ret != c.GST_FLOW_OK) cm.elementError(bt, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup("failed to perform view conversion on input buffer"), null, FILE, "gst_gl_view_convert_element_generate_output_buffer", 358);
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL Multiview/3D conversion filter", "Filter", "Convert stereoscopic/multiview video formats", "Jan Schmidt <jan@centricular.com>, Matthew Waters <matthew@centricular.com>");
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.set_caps = setCaps;
    fc.transform_internal_caps = internalCaps;
    const bt = el.baseTransformClass(k);
    bt.stop = stop;
    bt.fixate_caps = fixate;
    bt.submit_input_buffer = submit;
    bt.generate_output = generate;
    c.g_object_class_install_property(oc, @intFromEnum(Prop.input_layout), c.g_param_spec_enum("input-mode-override", "Input Multiview Mode Override", "Override any input information about multiview layout", c.gst_video_multiview_frame_packing_get_type(), c.GST_VIDEO_MULTIVIEW_MODE_NONE, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.input_flags), c.g_param_spec_flags("input-flags-override", "Input Multiview Flags Override", "Override any input information about multiview layout flags", c.gst_video_multiview_flags_get_type(), c.GST_VIDEO_MULTIVIEW_FLAGS_NONE, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.output_layout), c.g_param_spec_enum("output-mode-override", "Output Multiview Mode Override", "Override automatic output mode selection for multiview layout", c.gst_video_multiview_mode_get_type(), c.GST_VIDEO_MULTIVIEW_MODE_NONE, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.output_flags), c.g_param_spec_flags("output-flags-override", "Output Multiview Flags Override", "Override automatic negotiation for output multiview layout flags", c.gst_video_multiview_flags_get_type(), c.GST_VIDEO_MULTIVIEW_FLAGS_NONE, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.downmix), c.g_param_spec_enum("downmix-mode", "Mode for mono downmixed output", "Output anaglyph type to generate when downmixing to mono", c.gst_gl_stereo_downmix_get_type(), c.GST_GL_STEREO_DOWNMIX_ANAGLYPH_GREEN_MAGENTA_DUBOIS, cm.RW));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    me(inst).viewconvert = c.gst_gl_view_convert_new();
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLViewConvertElement", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("glview_convertelement", 0, "glview_convert element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glviewconvert", c.GST_RANK_NONE, getType());
}
