const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglfilterapp.c";

const Self = extern struct {
    filter: c.GstGLFilter,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

const Draw = struct {
    app: *Self,
    in: [*c]c.GstGLMemory,
    out: [*c]c.GstGLMemory,
};

var once: cm.Once = .{};
var parent_gl: *c.GstGLBaseFilterClass = undefined;
var sig_draw: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    cm.warnInvalid(FILE, o, id, spec, 137);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, _: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    cm.warnInvalid(FILE, o, id, spec, 148);
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    const f: *c.GstGLFilter = @ptrCast(@alignCast(bf));
    var err: [*c]c.GError = null;
    f.default_shader = c.gst_gl_shader_new_default(bf[0].context, &err);
    if (f.default_shader == null) {
        cm.elementError(f, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Failed to create the default shader"), c.g_strdup(err[0].message), FILE, "gst_gl_filter_app_gl_start", 161);
        c.g_clear_error(&err);
        return 0;
    }
    return parent_gl.gl_start.?(bf);
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const f: *c.GstGLFilter = @ptrCast(@alignCast(bf));
    if (f.default_shader != null) c.gst_object_unref(f.default_shader);
    f.default_shader = null;
    parent_gl.gl_stop.?(bf);
}

fn setCaps(_: [*c]c.GstGLFilter, _: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    return 1;
}

fn emit(data: c.gpointer) callconv(.c) c.gboolean {
    const d: *Draw = @ptrCast(@alignCast(data));
    var drawn: c.gboolean = 0;
    c.g_signal_emit(d.app, sig_draw, 0, d.in[0].tex_id, c.gst_gl_memory_get_texture_width(d.out), c.gst_gl_memory_get_texture_height(d.out), &drawn);
    return @intFromBool(drawn == 0);
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    var d = Draw{ .app = me(f), .in = in, .out = out };
    if (c.gst_gl_framebuffer_draw_to_texture(f[0].fbo, out, emit, &d) != 0) _ = c.gst_gl_filter_render_to_target_with_shader(f, in, out, f[0].default_shader);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.set_caps = setCaps;
    fc.filter_texture = filterTexture;
    sig_draw = c.g_signal_new("client-draw", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_BOOLEAN, 3, c.G_TYPE_UINT, c.G_TYPE_UINT, c.G_TYPE_UINT);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL application filter", "Filter/Effect", "Use client callbacks to define the scene", "Julien Isorce <julien.isorce@gmail.com>");
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL3;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLFilterApp", Class, Self, classInit, null);
            _ = c._gst_debug_category_new("glfilterapp", 0, "glfilterapp element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glfilterapp", c.GST_RANK_NONE, getType());
}
