const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglcolorscale.c";

const Self = extern struct {
    filter: c.GstGLFilter,
    shader: ?*c.GstGLShader,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;
var parent_gl: *c.GstGLBaseFilterClass = undefined;
var size_quark: c.GQuark = 0;
var scale_quark: c.GQuark = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    cm.warnInvalid(FILE, o, id, spec, 136);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, _: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    cm.warnInvalid(FILE, o, id, spec, 147);
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    const s = me(bf);
    var err: [*c]c.GError = null;
    const shader = c.gst_gl_shader_new_default(bf[0].context, &err);
    if (shader == null) {
        c.g_clear_error(&err);
        return 0;
    }
    s.filter.draw_attr_position_loc = c.gst_gl_shader_get_attribute_location(shader, "a_position");
    s.filter.draw_attr_texture_loc = c.gst_gl_shader_get_attribute_location(shader, "a_texcoord");
    s.shader = shader;
    return parent_gl.gl_start.?(bf);
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    parent_gl.gl_stop.?(bf);
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    if (c.gst_gl_context_get_gl_api(el.base(f).context) != 0) _ = c.gst_gl_filter_render_to_target_with_shader(f, in, out, me(f).shader);
    return 1;
}

fn transformMeta(bt: [*c]c.GstBaseTransform, out: [*c]c.GstBuffer, meta: [*c]c.GstMeta, in: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    if (!el.videoTagsOnly(meta, true)) return parent.transform_meta.?(bt, out, meta, in);
    const info = meta[0].info;
    if (c.gst_meta_api_type_has_tag(info[0].api, size_quark) != 0) {
        const s = me(bt);
        var tr = c.GstVideoMetaTransform{ .in_info = &s.filter.in_info, .out_info = &s.filter.out_info };
        if (info[0].transform_func) |f| _ = f(out, meta, in, scale_quark, &tr);
        return 0;
    }
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    size_quark = c.g_quark_from_static_string(c.GST_META_TAG_VIDEO_SIZE_STR);
    scale_quark = c.gst_video_meta_transform_scale_get_quark();
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL color scale", "Filter/Effect/Video", "Colorspace converter and video scaler", "Julien Isorce <julien.isorce@gmail.com>, Matthew Waters <matthew@centricular.com>");
    const bt = el.baseTransformClass(k);
    bt.passthrough_on_same_caps = 1;
    bt.transform_meta = transformMeta;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.filter_texture = filterTexture;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLColorscale", Class, Self, classInit, null);
            _ = c._gst_debug_category_new("glcolorscale", 0, "glcolorscale element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glcolorscale", c.GST_RANK_NONE, getType());
}
