const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglfilterglass.c";

const GLASS_FRAG = "uniform sampler2D tex;\nvarying float alpha;\nvoid main () {\n  float p = 0.0525;\n  float L1 = p*1.0;\n  float L2 = 1.0 - L1;\n  float L3 = 1.0 - L1;\n  float w = 1.0;\n  float r = L1;\n  if (gl_TexCoord[0].x < L1 && gl_TexCoord[0].y < L1)\n      r = sqrt( (gl_TexCoord[0].x - L1) * (gl_TexCoord[0].x - L1) + (gl_TexCoord[0].y - L1) * (gl_TexCoord[0].y - L1) );\n  else if (gl_TexCoord[0].x > L2 && gl_TexCoord[0].y < L1)\n      r = sqrt( (gl_TexCoord[0].x - L2) * (gl_TexCoord[0].x - L2) + (gl_TexCoord[0].y - L1) * (gl_TexCoord[0].y - L1) );\n  else if (gl_TexCoord[0].x > L2 && gl_TexCoord[0].y > L3)\n      r = sqrt( (gl_TexCoord[0].x - L2) * (gl_TexCoord[0].x - L2) + (gl_TexCoord[0].y - L3) * (gl_TexCoord[0].y - L3) );\n  else if (gl_TexCoord[0].x < L1 && gl_TexCoord[0].y > L3)\n      r = sqrt( (gl_TexCoord[0].x - L1) * (gl_TexCoord[0].x - L1) + (gl_TexCoord[0].y - L3) * (gl_TexCoord[0].y - L3) );\n  if (r > L1)\n      w = 0.0;\n  vec4 color = texture2D (tex, gl_TexCoord[0].st);\n  gl_FragColor = vec4(color.rgb, alpha * w);\n}\n";
const GLASS_VERT = "uniform float yrot;\nuniform float aspect;\nconst float fovy = 80.0;\nconst float znear = 1.0;\nconst float zfar = 5000.0;\nvarying float alpha;\nvoid main () {\n   float f = 1.0/(tan(radians(fovy/2.0)));\n   float rot = radians (yrot);\n   // replacement for gluPerspective\n   mat4 perspective = mat4 (\n            f/aspect, 0.0,  0.0,                      0.0,\n            0.0,      f,    0.0,                      0.0,\n            0.0,      0.0, (znear+zfar)/(znear-zfar), 2.0*znear*zfar/(znear-zfar),\n            0.0,      0.0, -1.0,                      0.0 );\n   mat4 trans = mat4 (\n            1.0, 0.0, 0.0, 0.0,\n            0.0, 1.0, 0.0, 0.0,\n            0.0, 0.0, 1.0, -3.0,\n            0.0, 0.0, 0.0, 1.0 );\n   mat4 rotation = mat4 (\n            cos(rot),  0.0, sin(rot), 0.0,\n            0.0,       1.0, 0.0,      0.0,\n            -sin(rot), 0.0, cos(rot), 0.0,\n            0.0,       0.0, 0.0,      1.0 );\n  gl_Position = trans * perspective * rotation * gl_ModelViewProjectionMatrix * gl_Vertex;\n  gl_TexCoord[0] = gl_MultiTexCoord0;\n  alpha = gl_Color.a;\n}\n";
const PASS_VERT = "void main () {\n  gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;\n  gl_FrontColor = gl_Color;\n}\n";
const PASS_FRAG = "void main () {\n  gl_FragColor = gl_Color;\n}\n";

const Self = extern struct {
    filter: c.GstGLFilter,
    passthrough_shader: ?*c.GstGLShader,
    shader: ?*c.GstGLShader,
    timestamp: i64,
    in_tex: [*c]c.GstGLMemory,
    out_tex: [*c]c.GstGLMemory,
    start_time: i64,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(el.base(s).context[0].gl_vtable));
}

fn stop(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(bt);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    if (s.passthrough_shader != null) c.gst_object_unref(s.passthrough_shader);
    s.passthrough_shader = null;
    s.start_time = 0;
    return parent.stop.?(bt);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    cm.warnInvalid(FILE, o, id, spec, 213);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, _: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    cm.warnInvalid(FILE, o, id, spec, 226);
}

fn initShader(f: [*c]c.GstGLFilter) callconv(.c) c.gboolean {
    const s = me(f);
    const ctx = el.base(f).context;
    var ret = el.genShader(ctx, GLASS_VERT, GLASS_FRAG, &s.shader);
    if (ret != 0) ret = el.genShader(ctx, PASS_VERT, PASS_FRAG, &s.passthrough_shader);
    return ret;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    me(f).in_tex = in;
    _ = c.gst_gl_framebuffer_draw_to_texture(f[0].fbo, out, draw, f);
    return 1;
}

fn gradient(s: *Self) void {
    const g = gl(s);
    const mesh = [_]f32{
        -1, -1,  0, 0, 0, 0,   1,
        1,  -1,  0, 0, 0, 0,   1,
        1,  0.8, 0, 0, 0, 0.2, 1,
        -1, 0.8, 0, 0, 0, 0.2, 1,
        -1, 1,   0, 0, 0, 0.2, 1,
        1,  1,   0, 0, 0, 0.2, 1,
    };
    const idx = [_]u16{ 0, 1, 2, 0, 2, 3, 2, 3, 4, 2, 4, 5 };
    g.ClientActiveTexture.?(c.GL_TEXTURE0);
    g.EnableClientState.?(c.GL_VERTEX_ARRAY);
    g.EnableClientState.?(c.GL_COLOR_ARRAY);
    g.VertexPointer.?(3, c.GL_FLOAT, 28, &mesh);
    g.ColorPointer.?(4, c.GL_FLOAT, 28, &mesh[3]);
    g.DrawElements.?(c.GL_TRIANGLES, 12, c.GL_UNSIGNED_SHORT, &idx);
    g.DisableClientState.?(c.GL_VERTEX_ARRAY);
    g.DisableClientState.?(c.GL_COLOR_ARRAY);
}

fn plane(s: *Self, w: c.gint, h: c.gint, tex: c.guint, cx: f32, cy: f32, start: f32, end: f32, reversed: bool, rotation: f32) void {
    const g = gl(s);
    const top = if (reversed) cy - 1 else cy + 1;
    const bottom = if (reversed) cy + 1 else cy - 1;
    const l: f32 = @floatCast(@as(f64, cx) - 1.6);
    const r: f32 = @floatCast(@as(f64, cx) + 1.6);
    const mesh = [_]f32{
        l, top,    0, 0, 1, 1, 1, 1, start,
        r, top,    0, 1, 1, 1, 1, 1, start,
        r, bottom, 0, 1, 0, 1, 1, 1, end,
        l, bottom, 0, 0, 0, 1, 1, 1, end,
    };
    const idx = [_]u16{ 0, 1, 2, 0, 2, 3 };
    g.ActiveTexture.?(c.GL_TEXTURE0);
    g.BindTexture.?(c.GL_TEXTURE_2D, tex);
    c.gst_gl_shader_set_uniform_1i(s.shader, "tex", 0);
    c.gst_gl_shader_set_uniform_1f(s.shader, "yrot", rotation);
    c.gst_gl_shader_set_uniform_1f(s.shader, "aspect", @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h)));
    g.ClientActiveTexture.?(c.GL_TEXTURE0);
    g.EnableClientState.?(c.GL_TEXTURE_COORD_ARRAY);
    g.EnableClientState.?(c.GL_VERTEX_ARRAY);
    g.EnableClientState.?(c.GL_COLOR_ARRAY);
    g.VertexPointer.?(3, c.GL_FLOAT, 36, &mesh);
    g.TexCoordPointer.?(2, c.GL_FLOAT, 36, &mesh[3]);
    g.ColorPointer.?(4, c.GL_FLOAT, 36, &mesh[5]);
    g.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, &idx);
    g.DisableClientState.?(c.GL_TEXTURE_COORD_ARRAY);
    g.DisableClientState.?(c.GL_VERTEX_ARRAY);
    g.DisableClientState.?(c.GL_COLOR_ARRAY);
}

fn draw(data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const g = gl(s);
    const w = s.filter.out_info.width;
    const h = s.filter.out_info.height;
    const tex = s.in_tex[0].tex_id;
    if (s.start_time == 0) {
        s.start_time = c.g_get_real_time();
    } else {
        var left = @divTrunc(s.timestamp, 1000) - (c.g_get_real_time() - s.start_time);
        left -= 1000000 / 25;
        if (left > 2000) return 0;
    }
    c.gst_gl_shader_use(s.passthrough_shader);
    gradient(s);
    var rotation: f32 = 0;
    if (s.start_time != 0) {
        const passed = c.g_get_real_time() - s.start_time;
        rotation = @floatCast(@sin(@as(f64, @floatFromInt(passed)) / 1200000.0) * 45.0);
    }
    g.Enable.?(c.GL_BLEND);
    g.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.gst_gl_shader_use(s.shader);
    plane(s, w, h, tex, 0, 2, 0.3, 0, true, rotation);
    plane(s, w, h, tex, 0, 0, 1, 1, false, rotation);
    c.gst_gl_context_clear_shader(el.base(s).context);
    g.Disable.?(c.GL_BLEND);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL glass filter", "Filter/Effect/Video", "Glass Filter", "Julien Isorce <julien.isorce@gmail.com>");
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.filter_texture = filterTexture;
    fc.init_fbo = initShader;
    el.baseTransformClass(k).stop = stop;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.supported_gl_api = c.GST_GL_API_OPENGL;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLFilterGlass", Class, Self, classInit, null);
            _ = c._gst_debug_category_new("glfilterglass", 0, "glfilterglass element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glfilterglass", c.GST_RANK_NONE, getType());
}
