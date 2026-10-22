const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglcolorconvertelement.c";

const Self = extern struct {
    parent: c.GstGLBaseFilter,
    convert: ?*c.GstGLColorConvert,
};

const Class = extern struct {
    parent: c.GstGLBaseFilterClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, c.GST_GL_COLOR_CONVERT_VIDEO_CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, c.GST_GL_COLOR_CONVERT_VIDEO_CAPS);
var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;
var parent_el: *c.GstElementClass = undefined;
var parent_gl: *c.GstGLBaseFilterClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn drop(s: *Self) void {
    if (s.convert != null) c.gst_object_unref(s.convert);
    s.convert = null;
}

fn glStop(f: [*c]c.GstGLBaseFilter) callconv(.c) void {
    drop(me(f));
    parent_gl.gl_stop.?(f);
}

fn glSetCaps(f: [*c]c.GstGLBaseFilter, in: [*c]c.GstCaps, out: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(f);
    if (s.convert == null and f[0].context != null) s.convert = c.gst_gl_color_convert_new(f[0].context);
    return c.gst_gl_color_convert_set_caps(s.convert, in, out);
}

fn transformCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bt);
    const bf = el.base(bt);
    if (bf.display != null and c.gst_gl_base_filter_find_gl_context(bf) == 0) return c.gst_caps_new_empty();
    const ctx = c.gst_gl_base_filter_get_gl_context(bf);
    defer if (ctx != null) c.gst_object_unref(ctx);
    if (s.convert == null and ctx != null) s.convert = c.gst_gl_color_convert_new(ctx);
    return c.gst_gl_color_convert_transform_caps(ctx, dir, caps, filter);
}

fn decideAllocation(bt: [*c]c.GstBaseTransform, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (parent.decide_allocation.?(bt, q) == 0) return 0;
    return c.gst_gl_color_convert_decide_allocation(me(bt).convert, q);
}

fn prepareOutput(bt: [*c]c.GstBaseTransform, in: [*c]c.GstBuffer, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    const k: *c.GstBaseTransformClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(bt)).g_class));
    if (c.gst_base_transform_is_passthrough(bt) != 0) {
        out.* = in;
        return c.GST_FLOW_OK;
    }
    if (s.convert == null) return c.GST_FLOW_NOT_NEGOTIATED;
    out.* = c.gst_gl_color_convert_perform(s.convert, in);
    if (out.* == null) {
        cm.elementError(bt, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Failed to convert video buffer"), null, FILE, "gst_gl_color_convert_element_prepare_output_buffer", 232);
        return c.GST_FLOW_ERROR;
    }
    if (in == out.*) {
        c.gst_buffer_unref(out.*);
    } else _ = k.copy_metadata.?(bt, in, out.*);
    return c.GST_FLOW_OK;
}

fn transformMeta(bt: [*c]c.GstBaseTransform, out: [*c]c.GstBuffer, meta: [*c]c.GstMeta, in: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    if (!el.videoTagsOnly(meta, false)) return parent.transform_meta.?(bt, out, meta, in);
    return 1;
}

fn fixateCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, other: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    return c.gst_gl_color_convert_fixate_caps(el.base(bt).context, dir, caps, other);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const ret = parent_el.change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) drop(me(e));
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    const bt = el.baseTransformClass(k);
    bt.transform_caps = transformCaps;
    bt.get_unit_size = el.unitSize;
    bt.filter_meta = el.keepMeta;
    bt.decide_allocation = decideAllocation;
    bt.prepare_output_buffer = prepareOutput;
    bt.transform = el.noTransform;
    bt.fixate_caps = fixateCaps;
    bt.transform_meta = transformMeta;
    bt.passthrough_on_same_caps = 1;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "OpenGL color converter", "Filter/Converter/Video", "Converts between color spaces using OpenGL shaders", "Matthew Waters <matthew@centricular.com>");
    const fc: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    fc.gl_stop = glStop;
    fc.gl_set_caps = glSetCaps;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_transform_set_prefer_passthrough(@ptrCast(@alignCast(inst)), 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_base_filter_get_type(), "GstGLColorConvertElement", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("glconvertelement", 0, "convert");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glcolorconvert", c.GST_RANK_NONE, getType());
}
