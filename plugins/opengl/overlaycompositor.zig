const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstgloverlaycompositorelement.c";
const OVERLAY = "meta:GstVideoOverlayComposition";
const TT = ", texture-target=(string) { 2D, rectangle } ";
const CAPS = el.capsWithFeatures("memory:GLMemory," ++ OVERLAY, "RGBA") ++ TT ++ "; " ++ el.capsWithFeatures("memory:GLMemory", "RGBA") ++ TT ++ "; " ++ el.capsWithFeatures("ANY", "RGBA") ++ TT;

const Self = extern struct {
    filter: c.GstGLFilter,
    shader: ?*c.GstGLShader,
    overlay_compositor: ?*c.GstGLOverlayCompositor,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;
var parent_gl: *c.GstGLBaseFilterClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn internalCaps(_: [*c]c.GstGLFilter, dir: c.GstPadDirection, caps: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    if (dir == c.GST_PAD_SRC) return c.gst_gl_overlay_compositor_add_caps(c.gst_caps_copy(caps));
    const ret = c.gst_caps_copy(caps);
    const removed = c.gst_caps_copy(caps);
    for (0..c.gst_caps_get_size(removed)) |i| {
        var feat = c.gst_caps_get_features(removed, @intCast(i));
        if (feat != null and c.gst_caps_features_contains(feat, OVERLAY) != 0) {
            feat = c.gst_caps_features_copy(feat);
            c.gst_caps_features_remove(feat, OVERLAY);
            c.gst_caps_set_features(removed, @intCast(i), feat);
        }
    }
    return c.gst_caps_merge(ret, removed);
}

fn sizeOf(q: [*c]c.GstQuery, w: *c.guint, h: *c.guint) void {
    var caps: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(q, &caps, null);
    if (caps == null) return;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) != 0) {
        w.* = @intCast(info.width);
        h.* = @intCast(info.height);
    }
}

fn proposeAllocation(bt: [*c]c.GstBaseTransform, decide: [*c]c.GstQuery, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (parent.propose_allocation.?(bt, decide, q) == 0) return 0;
    var w: c.guint = 0;
    var h: c.guint = 0;
    if (decide != null) sizeOf(decide, &w, &h);
    if ((w == 0 or h == 0) and q != null) sizeOf(q, &w, &h);
    if (w != 0 and h != 0) {
        const meta = c.gst_structure_new("GstVideoOverlayCompositionMeta", "width", c.G_TYPE_UINT, w, "height", c.G_TYPE_UINT, h, @as(?*anyopaque, null));
        if (q != null) c.gst_query_add_allocation_meta(q, c.gst_video_overlay_composition_meta_api_get_type(), meta);
        c.gst_structure_free(meta);
    }
    return 1;
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    if (s.overlay_compositor != null) {
        c.gst_gl_overlay_compositor_free_overlays(s.overlay_compositor);
        c.gst_object_unref(s.overlay_compositor);
    }
    s.overlay_compositor = null;
    parent_gl.gl_stop.?(bf);
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    const s = me(bf);
    s.overlay_compositor = c.gst_gl_overlay_compositor_new(bf[0].context);
    c.g_object_set(s.overlay_compositor, "yinvert", @as(c.gboolean, 1), @as(?*anyopaque, null));
    var err: [*c]c.GError = null;
    s.shader = c.gst_gl_shader_new_default(bf[0].context, &err);
    if (s.shader == null) {
        cm.elementError(bf, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Failed to compile identity shader"), c.g_strdup(err[0].message), FILE, "gst_gl_overlay_compositor_element_gl_start", 267);
        c.g_clear_error(&err);
        return 0;
    }
    return parent_gl.gl_start.?(bf);
}

fn prepareOutput(bt: [*c]c.GstBaseTransform, in: [*c]c.GstBuffer, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    if (c.gst_base_transform_is_passthrough(bt) == 0) {
        if (s.overlay_compositor == null) return c.GST_FLOW_NOT_NEGOTIATED;
        var state: c.gpointer = null;
        const api = c.gst_video_overlay_composition_meta_api_get_type();
        while (c.gst_buffer_iterate_meta_filtered(in, &state, api)) |m| {
            const om: *c.GstVideoOverlayCompositionMeta = @ptrCast(@alignCast(m));
            if (c.gst_video_overlay_composition_n_rectangles(om.overlay) > 0) return parent.prepare_output_buffer.?(bt, in, out);
        }
    }
    out.* = in;
    return c.GST_FLOW_OK;
}

fn filter(f: [*c]c.GstGLFilter, in: [*c]c.GstBuffer, out: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    if (in == out) return 1;
    c.gst_gl_overlay_compositor_upload_overlays(me(f).overlay_compositor, in);
    return c.gst_gl_filter_filter_texture(f, in, out);
}

fn draw(f: [*c]c.GstGLFilter, _: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    c.gst_gl_overlay_compositor_draw_overlays(me(f).overlay_compositor);
    return 1;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    _ = c.gst_gl_filter_render_to_target_with_shader(f, in, out, me(f).shader);
    _ = c.gst_gl_filter_render_to_target(f, null, out, draw, null);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "OpenGL overlaying filter", "Filter/Effect", "Flatten a stream containing GstVideoOverlayCompositionMeta", "<matthew@centricular.com>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    const bt = el.baseTransformClass(k);
    bt.passthrough_on_same_caps = 1;
    bt.propose_allocation = proposeAllocation;
    bt.prepare_output_buffer = prepareOutput;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.filter = filter;
    fc.filter_texture = filterTexture;
    fc.transform_internal_caps = internalCaps;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL3;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLOverlayCompositorElement", Class, Self, classInit, null);
            _ = c._gst_debug_category_new("gloverlaycompositorelement", 0, "gloverlaycompositor element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "gloverlaycompositor", c.GST_RANK_NONE, getType());
}
