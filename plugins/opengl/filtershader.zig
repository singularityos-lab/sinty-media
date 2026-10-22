const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglfiltershader.c";

const Prop = enum(c.guint) { shader = 1, vertex, fragment, uniforms, update_shader };

const Self = extern struct {
    filter: c.GstGLFilter,
    shader: ?*c.GstGLShader,
    vertex: [*c]u8,
    fragment: [*c]u8,
    update_shader: c.gboolean,
    uniforms: ?*c.GstStructure,
    new_source: c.gboolean,
    new_uniforms: c.gboolean,
    time: f64,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

extern fn graphene_vec2_get_type() c.GType;
extern fn graphene_vec3_get_type() c.GType;
extern fn graphene_vec4_get_type() c.GType;
extern fn graphene_matrix_get_type() c.GType;
extern fn graphene_vec2_get_x(?*const anyopaque) f32;
extern fn graphene_vec2_get_y(?*const anyopaque) f32;
extern fn graphene_vec3_get_x(?*const anyopaque) f32;
extern fn graphene_vec3_get_y(?*const anyopaque) f32;
extern fn graphene_vec3_get_z(?*const anyopaque) f32;
extern fn graphene_vec4_get_x(?*const anyopaque) f32;
extern fn graphene_vec4_get_y(?*const anyopaque) f32;
extern fn graphene_vec4_get_z(?*const anyopaque) f32;
extern fn graphene_vec4_get_w(?*const anyopaque) f32;
extern fn graphene_matrix_to_float(?*const anyopaque, *[16]f32) void;

var once: cm.Once = .{};
var parent_gl: *c.GstGLBaseFilterClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var sig_create: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    c.g_free(s.vertex);
    s.vertex = null;
    c.g_free(s.fragment);
    s.fragment = null;
    if (s.uniforms != null) c.gst_structure_free(s.uniforms);
    s.uniforms = null;
    parent_obj.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.shader) => {
            cm.lock(s);
            _ = c.gst_object_replace(@ptrCast(&s.shader), @ptrCast(@alignCast(c.g_value_get_object(v))));
            s.new_source = 0;
            cm.unlock(s);
        },
        @intFromEnum(Prop.vertex) => {
            cm.lock(s);
            c.g_free(s.vertex);
            s.vertex = c.g_value_dup_string(v);
            s.new_source = 1;
            cm.unlock(s);
        },
        @intFromEnum(Prop.fragment) => {
            cm.lock(s);
            c.g_free(s.fragment);
            s.fragment = c.g_value_dup_string(v);
            s.new_source = 1;
            cm.unlock(s);
        },
        @intFromEnum(Prop.uniforms) => {
            cm.lock(s);
            if (s.uniforms != null) c.gst_structure_free(s.uniforms);
            s.uniforms = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
            s.new_uniforms = 1;
            cm.unlock(s);
        },
        @intFromEnum(Prop.update_shader) => {
            cm.lock(s);
            s.update_shader = c.g_value_get_boolean(v);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 250),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        @intFromEnum(Prop.shader) => c.g_value_set_object(v, s.shader),
        @intFromEnum(Prop.vertex) => c.g_value_set_string(v, s.vertex),
        @intFromEnum(Prop.fragment) => c.g_value_set_string(v, s.fragment),
        @intFromEnum(Prop.uniforms) => c.g_value_set_boxed(v, s.uniforms),
        else => cm.warnInvalid(FILE, o, id, spec, 283),
    }
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    s.new_source = 1;
    parent_gl.gl_stop.?(bf);
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    return parent_gl.gl_start.?(bf);
}

fn filter(f: [*c]c.GstGLFilter, in: [*c]c.GstBuffer, out: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const s = me(f);
    const none = std.math.maxInt(u64);
    if (in[0].pts != none) {
        s.time = @as(f64, @floatFromInt(in[0].pts)) / @as(f64, @floatFromInt(@as(u64, c.GST_SECOND)));
    } else if (in[0].dts != none) {
        s.time = @as(f64, @floatFromInt(in[0].dts)) / @as(f64, @floatFromInt(@as(u64, c.GST_SECOND)));
    } else {
        const t = c.g_get_monotonic_time();
        if (t != -1) s.time = @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(@as(u64, c.GST_USECOND)));
    }
    return c.gst_gl_filter_filter_texture(f, in, out);
}

fn setUniform(id: ?*const c.GstIdStr, v: [*c]const c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const shader: ?*c.GstGLShader = @ptrCast(@alignCast(data));
    const name = c.gst_id_str_as_str(id);
    const t = v[0].g_type;
    if (t == c.G_TYPE_INT) {
        c.gst_gl_shader_set_uniform_1i(shader, name, c.g_value_get_int(v));
    } else if (t == c.G_TYPE_FLOAT) {
        c.gst_gl_shader_set_uniform_1f(shader, name, c.g_value_get_float(v));
    } else if (t == graphene_vec2_get_type()) {
        const p = c.g_value_get_boxed(v);
        c.gst_gl_shader_set_uniform_2f(shader, name, graphene_vec2_get_x(p), graphene_vec2_get_y(p));
    } else if (t == graphene_vec3_get_type()) {
        const p = c.g_value_get_boxed(v);
        c.gst_gl_shader_set_uniform_3f(shader, name, graphene_vec3_get_x(p), graphene_vec3_get_y(p), graphene_vec3_get_z(p));
    } else if (t == graphene_vec4_get_type()) {
        const p = c.g_value_get_boxed(v);
        c.gst_gl_shader_set_uniform_4f(shader, name, graphene_vec4_get_x(p), graphene_vec4_get_y(p), graphene_vec4_get_z(p), graphene_vec4_get_w(p));
    } else if (t == graphene_matrix_get_type()) {
        var m: [16]f32 = undefined;
        graphene_matrix_to_float(c.g_value_get_boxed(v), &m);
        c.gst_gl_shader_set_uniform_matrix_4fv(shader, name, 1, 0, &m);
    }
    return 1;
}

fn updateUniforms(s: *Self) void {
    if (s.new_uniforms != 0 and s.uniforms != null) {
        c.gst_gl_shader_use(s.shader);
        _ = c.gst_structure_foreach_id_str(s.uniforms, setUniform, s.shader);
        s.new_uniforms = 0;
    }
}

fn adopt(s: *Self, shader: ?*c.GstGLShader) ?*c.GstGLShader {
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.new_source = 0;
    s.shader = @ptrCast(@alignCast(c.gst_object_ref(shader)));
    s.new_uniforms = 1;
    updateUniforms(s);
    cm.unlock(s);
    return shader;
}

fn fail(s: *Self, shader: ?*c.GstGLShader, err: [*c]c.GError) ?*c.GstGLShader {
    if (shader != null) c.gst_object_unref(shader);
    cm.unlock(s);
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(err[0].message), null, FILE, "_maybe_recompile_shader", 518);
    return null;
}

fn compileStage(shader: ?*c.GstGLShader, stage: ?*c.GstGLSLStage, err: *[*c]c.GError) bool {
    if (c.gst_gl_shader_compile_attach_stage(shader, stage, err) == 0) {
        c.gst_object_unref(stage);
        return false;
    }
    return true;
}

fn current(s: *Self) ?*c.GstGLShader {
    const ctx = el.base(s).context;
    cm.lock(s);
    if (s.shader == null or s.update_shader != 0) {
        s.update_shader = 0;
        cm.unlock(s);
        var made: ?*c.GstGLShader = null;
        c.g_signal_emit(s, sig_create, 0, &made);
        cm.lock(s);
        if (made != null) return adopt(s, made);
    }
    if (s.shader != null) {
        const sh: ?*c.GstGLShader = @ptrCast(@alignCast(c.gst_object_ref(s.shader)));
        updateUniforms(s);
        cm.unlock(s);
        return sh;
    }
    if (s.new_source == 0) {
        cm.unlock(s);
        return null;
    }
    var err: [*c]c.GError = null;
    const shader = c.gst_gl_shader_new(ctx);
    const vert = if (s.vertex != null) c.gst_glsl_stage_new_with_string(ctx, c.GL_VERTEX_SHADER, c.GST_GLSL_VERSION_NONE, c.GST_GLSL_PROFILE_NONE, s.vertex) else c.gst_glsl_stage_new_default_vertex(ctx);
    if (vert == null) {
        c.g_set_error(&err, c.gst_glsl_error_quark(), c.GST_GLSL_ERROR_COMPILE, "Failed to create shader vertex stage");
        return fail(s, shader, err);
    }
    if (!compileStage(shader, vert, &err)) return fail(s, shader, err);
    const frag = if (s.fragment != null) c.gst_glsl_stage_new_with_string(ctx, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, c.GST_GLSL_PROFILE_NONE, s.fragment) else c.gst_glsl_stage_new_default_fragment(ctx);
    if (frag == null) {
        c.g_set_error(&err, c.gst_glsl_error_quark(), c.GST_GLSL_ERROR_COMPILE, "Failed to create shader fragment stage");
        return fail(s, shader, err);
    }
    if (!compileStage(shader, frag, &err)) return fail(s, shader, err);
    if (c.gst_gl_shader_link(shader, &err) == 0) return fail(s, shader, err);
    return adopt(s, shader);
}

fn draw(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    const s = me(f);
    const g: *c.GstGLFuncs = @ptrCast(@alignCast(el.base(f).context[0].gl_vtable));
    const shader = current(s) orelse return 0;
    g.ClearColor.?(0, 0, 0, 1);
    g.Clear.?(c.GL_COLOR_BUFFER_BIT);
    c.gst_gl_shader_use(shader);
    c.gst_gl_shader_set_uniform_1i(shader, "tex", 0);
    c.gst_gl_shader_set_uniform_1f(shader, "width", @floatFromInt(f[0].out_info.width));
    c.gst_gl_shader_set_uniform_1f(shader, "height", @floatFromInt(f[0].out_info.height));
    c.gst_gl_shader_set_uniform_1f(shader, "time", @floatCast(s.time));
    f[0].draw_attr_position_loc = c.gst_gl_shader_get_attribute_location(shader, "a_position");
    f[0].draw_attr_texture_loc = c.gst_gl_shader_get_attribute_location(shader, "a_texcoord");
    g.ActiveTexture.?(c.GL_TEXTURE0);
    g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(in));
    c.gst_gl_filter_draw_fullscreen_quad(f);
    c.gst_object_unref(shader);
    return 1;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    _ = c.gst_gl_filter_render_to_target(f, in, out, draw, null);
    return @intFromBool(me(f).shader != null);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, @intFromEnum(Prop.shader), c.g_param_spec_object("shader", "Shader object", "GstGLShader to use", c.gst_gl_shader_get_type(), cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.vertex), c.g_param_spec_string("vertex", "Vertex Source", "GLSL vertex source", null, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.fragment), c.g_param_spec_string("fragment", "Fragment Source", "GLSL fragment source", null, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.uniforms), c.g_param_spec_boxed("uniforms", "GLSL Uniforms", "GLSL Uniforms", c.gst_structure_get_type(), cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.update_shader), c.g_param_spec_boolean("update-shader", "Update Shader", "Emit the 'create-shader' signal for the next frame", 0, c.G_PARAM_WRITABLE | c.G_PARAM_STATIC_STRINGS));
    sig_create = c.g_signal_new("create-shader", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.gst_gl_shader_get_type(), 0);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL fragment shader filter", "Filter/Effect", "Perform operations with a GLSL shader", "<matthew@centricular.com>");
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.filter = filter;
    fc.filter_texture = filterTexture;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL3;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    me(inst).new_source = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLFilterShader", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("glshader", 0, "glshader element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glshader", c.GST_RANK_NONE, getType());
}
