const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglfiltercube.c";

const VERT = "attribute vec4 a_position;                                   \nattribute vec2 a_texcoord;                                   \nuniform mat4 u_matrix;                                       \nuniform float xrot_degree, yrot_degree, zrot_degree;         \nvarying vec2 v_texcoord;                                     \nvoid main()                                                  \n{                                                            \n   float PI = 3.14159265;                                    \n   float xrot = xrot_degree*2.0*PI/360.0;                    \n   float yrot = yrot_degree*2.0*PI/360.0;                    \n   float zrot = zrot_degree*2.0*PI/360.0;                    \n   mat4 matX = mat4 (                                        \n            1.0,        0.0,        0.0, 0.0,                \n            0.0,  cos(xrot),  sin(xrot), 0.0,                \n            0.0, -sin(xrot),  cos(xrot), 0.0,                \n            0.0,        0.0,        0.0, 1.0 );              \n   mat4 matY = mat4 (                                        \n      cos(yrot),        0.0, -sin(yrot), 0.0,                \n            0.0,        1.0,        0.0, 0.0,                \n      sin(yrot),        0.0,  cos(yrot), 0.0,                \n            0.0,        0.0,       0.0,  1.0 );              \n   mat4 matZ = mat4 (                                        \n      cos(zrot),  sin(zrot),        0.0, 0.0,                \n     -sin(zrot),  cos(zrot),        0.0, 0.0,                \n            0.0,        0.0,        1.0, 0.0,                \n            0.0,        0.0,        0.0, 1.0 );              \n   gl_Position = u_matrix * matZ * matY * matX * a_position; \n   v_texcoord = a_texcoord;                                  \n}                                                            \n";
const FRAG = "varying vec2 v_texcoord;                            \nuniform sampler2D s_texture;                        \nvoid main()                                         \n{                                                   \n  gl_FragColor = texture2D( s_texture, v_texcoord );\n}                                                   \n";

const faces = [_][4][3]f32{
    .{ .{ 1, 1, -1 }, .{ 1, -1, -1 }, .{ -1, -1, -1 }, .{ -1, 1, -1 } },
    .{ .{ 1, 1, 1 }, .{ -1, 1, 1 }, .{ -1, -1, 1 }, .{ 1, -1, 1 } },
    .{ .{ 1, 1, 1 }, .{ 1, -1, 1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 } },
    .{ .{ -1, 1, 1 }, .{ -1, 1, -1 }, .{ -1, -1, -1 }, .{ -1, -1, 1 } },
    .{ .{ 1, -1, 1 }, .{ -1, -1, 1 }, .{ -1, -1, -1 }, .{ 1, -1, -1 } },
    .{ .{ 1, 1, 1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 }, .{ -1, 1, 1 } },
};
const uvs = [_][4][2]f32{
    .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } },
    .{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } },
    .{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } },
    .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } },
    .{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } },
    .{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } },
};

const vertices = blk: {
    var v: [6 * 4 * 5]f32 = undefined;
    for (0..6) |f| for (0..4) |i| {
        const o = (f * 4 + i) * 5;
        v[o] = faces[f][i][0];
        v[o + 1] = faces[f][i][1];
        v[o + 2] = faces[f][i][2];
        v[o + 3] = uvs[f][i][0];
        v[o + 4] = uvs[f][i][1];
    };
    break :blk v;
};

const indices = blk: {
    var v: [36]u16 = undefined;
    for (0..6) |f| {
        const b: u16 = @intCast(f * 4);
        v[f * 6 ..][0..6].* = .{ b, b + 1, b + 2, b, b + 2, b + 3 };
    }
    break :blk v;
};

const matrix = [16]f32{ 0.5, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 1 };

const Prop = enum(c.guint) { red = 1, green, blue, fovy, aspect, znear, zfar };

const Self = extern struct {
    filter: c.GstGLFilter,
    shader: ?*c.GstGLShader,
    in_tex: ?*c.GstGLMemory,
    vao: c.GLuint,
    vertex_buffer: c.GLuint,
    vbo_indices: c.GLuint,
    attr_position: c.GLint,
    attr_texture: c.GLint,
    red: f32,
    green: f32,
    blue: f32,
    fovy: f64,
    aspect: f64,
    znear: f64,
    zfar: f64,
    xrot: f32,
    yrot: f32,
    zrot: f32,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var once: cm.Once = .{};
var parent_gl: *c.GstGLBaseFilterClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(el.base(s).context[0].gl_vtable));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.red) => s.red = c.g_value_get_float(v),
        @intFromEnum(Prop.green) => s.green = c.g_value_get_float(v),
        @intFromEnum(Prop.blue) => s.blue = c.g_value_get_float(v),
        @intFromEnum(Prop.fovy) => s.fovy = c.g_value_get_double(v),
        @intFromEnum(Prop.aspect) => s.aspect = c.g_value_get_double(v),
        @intFromEnum(Prop.znear) => s.znear = c.g_value_get_double(v),
        @intFromEnum(Prop.zfar) => s.zfar = c.g_value_get_double(v),
        else => cm.warnInvalid(FILE, o, id, spec, 229),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.red) => c.g_value_set_float(v, s.red),
        @intFromEnum(Prop.green) => c.g_value_set_float(v, s.green),
        @intFromEnum(Prop.blue) => c.g_value_set_float(v, s.blue),
        @intFromEnum(Prop.fovy) => c.g_value_set_double(v, s.fovy),
        @intFromEnum(Prop.aspect) => c.g_value_set_double(v, s.aspect),
        @intFromEnum(Prop.znear) => c.g_value_set_double(v, s.znear),
        @intFromEnum(Prop.zfar) => c.g_value_set_double(v, s.zfar),
        else => cm.warnInvalid(FILE, o, id, spec, 263),
    }
}

fn setCaps(f: [*c]c.GstGLFilter, _: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(f);
    if (s.aspect == 0) s.aspect = @as(f64, @floatFromInt(f[0].out_info.width)) / @as(f64, @floatFromInt(f[0].out_info.height));
    return 1;
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    const g = gl(s);
    if (s.vao != 0) g.DeleteVertexArrays.?(1, &s.vao);
    s.vao = 0;
    if (s.vertex_buffer != 0) g.DeleteBuffers.?(1, &s.vertex_buffer);
    s.vertex_buffer = 0;
    if (s.vbo_indices != 0) g.DeleteBuffers.?(1, &s.vbo_indices);
    s.vbo_indices = 0;
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    parent_gl.gl_stop.?(bf);
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    const s = me(bf);
    s.xrot = 0;
    s.yrot = 0;
    s.zrot = 0;
    const frag = c.g_strdup_printf("%s%s", c.gst_gl_shader_string_get_highest_precision(bf[0].context, c.GST_GLSL_VERSION_NONE, c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY), FRAG);
    defer c.g_free(frag);
    return el.genShader(bf[0].context, VERT, frag, &s.shader);
}

fn bind(s: *Self) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.vertex_buffer);
    s.attr_position = c.gst_gl_shader_get_attribute_location(s.shader, "a_position");
    s.attr_texture = c.gst_gl_shader_get_attribute_location(s.shader, "a_texcoord");
    g.VertexAttribPointer.?(@bitCast(s.attr_position), 3, c.GL_FLOAT, c.GL_FALSE, 20, null);
    g.VertexAttribPointer.?(@bitCast(s.attr_texture), 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(12));
    g.EnableVertexAttribArray.?(@bitCast(s.attr_position));
    g.EnableVertexAttribArray.?(@bitCast(s.attr_texture));
}

fn unbind(s: *Self) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    g.DisableVertexAttribArray.?(@bitCast(s.attr_position));
    g.DisableVertexAttribArray.?(@bitCast(s.attr_texture));
}

fn draw(data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const g = gl(s);
    g.Enable.?(c.GL_DEPTH_TEST);
    g.ClearColor.?(s.red, s.green, s.blue, 0);
    g.Clear.?(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
    c.gst_gl_shader_use(s.shader);
    g.ActiveTexture.?(c.GL_TEXTURE0);
    g.BindTexture.?(c.GL_TEXTURE_2D, s.in_tex.?.tex_id);
    c.gst_gl_shader_set_uniform_1i(s.shader, "s_texture", 0);
    c.gst_gl_shader_set_uniform_1f(s.shader, "xrot_degree", s.xrot);
    c.gst_gl_shader_set_uniform_1f(s.shader, "yrot_degree", s.yrot);
    c.gst_gl_shader_set_uniform_1f(s.shader, "zrot_degree", s.zrot);
    c.gst_gl_shader_set_uniform_matrix_4fv(s.shader, "u_matrix", 1, c.GL_FALSE, &matrix);
    const vao = g.GenVertexArrays != null;
    if (s.vertex_buffer == 0) {
        if (vao) {
            g.GenVertexArrays.?(1, &s.vao);
            g.BindVertexArray.?(s.vao);
        }
        g.GenBuffers.?(1, &s.vertex_buffer);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.vertex_buffer);
        g.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_STATIC_DRAW);
        g.GenBuffers.?(1, &s.vbo_indices);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
        g.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, c.GL_STATIC_DRAW);
        if (vao) {
            bind(s);
            g.BindVertexArray.?(0);
        }
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    }
    if (vao) g.BindVertexArray.?(s.vao);
    bind(s);
    g.DrawElements.?(c.GL_TRIANGLES, 36, c.GL_UNSIGNED_SHORT, null);
    if (vao) g.BindVertexArray.?(0) else unbind(s);
    g.Disable.?(c.GL_DEPTH_TEST);
    s.xrot += 0.3;
    s.yrot += 0.2;
    s.zrot += 0.4;
    return 1;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    me(f).in_tex = in;
    return c.gst_gl_framebuffer_draw_to_texture(f[0].fbo, out, draw, f);
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
    c.g_object_class_install_property(oc, @intFromEnum(Prop.red), c.g_param_spec_float("red", "Red", "Background red color", 0, 1, 0, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.green), c.g_param_spec_float("green", "Green", "Background green color", 0, 1, 0, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.blue), c.g_param_spec_float("blue", "Blue", "Background blue color", 0, 1, 0, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.fovy), c.g_param_spec_double("fovy", "Fovy", "Field of view angle in degrees", 0, 180, 45, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.aspect), c.g_param_spec_double("aspect", "Aspect", "Field of view in the x direction", 0, 100, 0, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.znear), c.g_param_spec_double("znear", "Znear", "Specifies the distance from the viewer to the near clipping plane", 0, 100, 0.1, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.zfar), c.g_param_spec_double("zfar", "Zfar", "Specifies the distance from the viewer to the far clipping plane", 0, 1000, 100, cm.RW));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL cube filter", "Filter/Effect/Video", "Map input texture on the 6 cube faces", "Julien Isorce <julien.isorce@gmail.com>");
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL3;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.fovy = 45;
    s.aspect = 0;
    s.znear = 0.1;
    s.zfar = 100;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLFilterCube", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("glfiltercube", 0, "glfiltercube element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glfiltercube", c.GST_RANK_NONE, getType());
}
