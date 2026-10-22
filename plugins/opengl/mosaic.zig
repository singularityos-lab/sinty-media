const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglmosaic.c";
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;

const VERT = "uniform mat4 u_matrix;                                       \nuniform float xrot_degree, yrot_degree, zrot_degree;         \nattribute vec4 a_position;                                   \nattribute vec2 a_texCoord;                                   \nvarying vec2 v_texCoord;                                     \nvoid main()                                                  \n{                                                            \n   float PI = 3.14159265;                                    \n   float xrot = xrot_degree*2.0*PI/360.0;                    \n   float yrot = yrot_degree*2.0*PI/360.0;                    \n   float zrot = zrot_degree*2.0*PI/360.0;                    \n   mat4 matX = mat4 (                                        \n            1.0,        0.0,        0.0, 0.0,                \n            0.0,  cos(xrot),  sin(xrot), 0.0,                \n            0.0, -sin(xrot),  cos(xrot), 0.0,                \n            0.0,        0.0,        0.0, 1.0 );              \n   mat4 matY = mat4 (                                        \n      cos(yrot),        0.0, -sin(yrot), 0.0,                \n            0.0,        1.0,        0.0, 0.0,                \n      sin(yrot),        0.0,  cos(yrot), 0.0,                \n            0.0,        0.0,       0.0,  1.0 );              \n   mat4 matZ = mat4 (                                        \n      cos(zrot),  sin(zrot),        0.0, 0.0,                \n     -sin(zrot),  cos(zrot),        0.0, 0.0,                \n            0.0,        0.0,        1.0, 0.0,                \n            0.0,        0.0,        0.0, 1.0 );              \n   gl_Position = u_matrix * matZ * matY * matX * a_position; \n   v_texCoord = a_texCoord;                                  \n}                                                            \n";
const FRAG = "uniform sampler2D s_texture;                    \nvarying vec2 v_texCoord;                            \nvoid main()                                         \n{                                                   \n  gl_FragColor = texture2D( s_texture, v_texCoord );\n}                                                   \n";

const vertices = [_]f32{
    1,  1,  -1, 1, 0, 1,  -1, -1, 1, 1, -1, -1, -1, 0, 1, -1, 1,  -1, 0, 0,
    1,  1,  1,  1, 0, 1,  -1, 1,  0, 0, 1,  -1, -1, 0, 1, 1,  1,  -1, 1, 1,
    -1, 1,  1,  1, 0, -1, 1,  -1, 1, 1, -1, -1, -1, 0, 1, -1, -1, 1,  0, 0,
    1,  -1, 1,  1, 0, -1, -1, 1,  0, 0, -1, -1, -1, 0, 1, 1,  -1, -1, 1, 1,
    1,  1,  1,  1, 0, 1,  1,  -1, 1, 1, -1, 1,  -1, 0, 1, -1, 1,  1,  0, 0,
    1,  1,  1,  1, 0, -1, 1,  1,  0, 0, -1, -1, 1,  0, 1, 1,  -1, 1,  1, 1,
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

const Self = extern struct {
    mixer: c.GstGLMixer,
    shader: ?*c.GstGLShader,
    out_tex: [*c]c.GstGLMemory,
    attr_position_loc: c.GLint,
    attr_texture_loc: c.GLint,
    vertex_buffer: c.GLuint,
    vbo_indices: c.GLuint,
    vao: c.GLuint,
    xrot: f32,
    yrot: f32,
    zrot: f32,
};

const Class = extern struct {
    parent: c.GstGLMixerClass,
};

var once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_bm: *c.GstGLBaseMixerClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn ctxOf(s: *Self) [*c]c.GstGLContext {
    return @as(*c.GstGLBaseMixer, @ptrCast(@alignCast(s))).context;
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(ctxOf(s)[0].gl_vtable));
}

fn requestPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, caps: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    return el.requestPadAnnounced(parent_el, e, templ, name, caps);
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    el.releasePadAnnounced(parent_el, e, pad);
}

fn glStop(bm: [*c]c.GstGLBaseMixer) callconv(.c) void {
    const s = me(bm);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    s.attr_position_loc = -1;
    s.attr_texture_loc = -1;
    s.xrot = 0;
    s.yrot = 0;
    s.zrot = 0;
    parent_bm.gl_stop.?(bm);
}

fn bind(s: *Self) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.vertex_buffer);
    g.VertexAttribPointer.?(@bitCast(s.attr_position_loc), 3, c.GL_FLOAT, c.GL_FALSE, 20, null);
    g.VertexAttribPointer.?(@bitCast(s.attr_texture_loc), 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(12));
    g.EnableVertexAttribArray.?(@bitCast(s.attr_position_loc));
    g.EnableVertexAttribArray.?(@bitCast(s.attr_texture_loc));
}

fn unbind(s: *Self) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    g.DisableVertexAttribArray.?(@bitCast(s.attr_position_loc));
    g.DisableVertexAttribArray.?(@bitCast(s.attr_texture_loc));
}

fn draw(data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const g = gl(s);
    const ctx = ctxOf(s);
    c.gst_gl_context_clear_shader(ctx);
    g.BindTexture.?(c.GL_TEXTURE_2D, 0);
    g.Enable.?(c.GL_DEPTH_TEST);
    g.ClearColor.?(0, 0, 0, 0);
    g.Clear.?(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
    c.gst_gl_shader_use(s.shader);
    if (s.attr_position_loc == -1) s.attr_position_loc = c.gst_gl_shader_get_attribute_location(s.shader, "a_position");
    if (s.attr_texture_loc == -1) s.attr_texture_loc = c.gst_gl_shader_get_attribute_location(s.shader, "a_texCoord");
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
    }
    if (vao) g.BindVertexArray.?(s.vao);
    bind(s);
    cm.lock(s);
    var count: usize = 0;
    var walk = @as(*c.GstElement, @ptrCast(@alignCast(s))).sinkpads;
    while (walk != null) : (walk = walk[0].next) {
        const pad: *el.MixerPad = @ptrCast(@alignCast(walk[0].data));
        if (count >= 6) break;
        const tex = pad.current_texture;
        if (tex == 0 or pad.parent.info.width <= 0 or pad.parent.info.height <= 0) {
            count += 1;
            continue;
        }
        g.ActiveTexture.?(c.GL_TEXTURE0);
        g.BindTexture.?(c.GL_TEXTURE_2D, tex);
        g.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, @ptrFromInt(12 * count));
        count += 1;
    }
    cm.unlock(s);
    if (vao) g.BindVertexArray.?(0) else unbind(s);
    g.BindTexture.?(c.GL_TEXTURE_2D, 0);
    g.Disable.?(c.GL_DEPTH_TEST);
    c.gst_gl_context_clear_shader(ctx);
    s.xrot += 0.6;
    s.yrot += 0.4;
    s.zrot += 0.8;
    return 1;
}

fn render(_: [*c]c.GstGLContext, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const fbo = c.gst_gl_mixer_get_framebuffer(@ptrCast(s));
    if (s.shader == null) {
        const frag = c.g_strdup_printf("%s%s", c.gst_gl_shader_string_get_highest_precision(ctxOf(s), c.GST_GLSL_VERSION_NONE, PROFILE), FRAG);
        _ = el.genShader(ctxOf(s), VERT, frag, &s.shader);
        c.g_free(frag);
    }
    _ = c.gst_gl_framebuffer_draw_to_texture(fbo, s.out_tex, draw, s);
    if (fbo != null) c.gst_object_unref(fbo);
}

fn processTextures(m: [*c]c.GstGLMixer, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    const s = me(m);
    s.out_tex = out;
    c.gst_gl_context_thread_add(ctxOf(s), render, s);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_bm = el.parentOf(c.GstGLBaseMixerClass, k);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    c.gst_element_class_set_static_metadata(ec, "OpenGL mosaic", "Filter/Effect/Video", "OpenGL mosaic", "Julien Isorce <julien.isorce@gmail.com>");
    const bm: *c.GstGLBaseMixerClass = @ptrCast(@alignCast(k));
    bm.gl_stop = glStop;
    const mc: *c.GstGLMixerClass = @ptrCast(@alignCast(k));
    mc.process_textures = processTextures;
    c.gst_gl_mixer_class_add_rgba_pad_templates(mc);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.attr_position_loc = -1;
    s.attr_texture_loc = -1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_mixer_get_type(), "GstGLMosaic", Class, Self, classInit, init);
            el.addSinkpadProxy(t);
            _ = c._gst_debug_category_new("glmosaic", 0, "glmosaic element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glmosaic", c.GST_RANK_NONE, getType());
}
