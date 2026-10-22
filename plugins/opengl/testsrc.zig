const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstgltestsrc.c";
const PROP_PATTERN = 1;
const PROP_IS_LIVE = 2;
const SECOND: f32 = @floatFromInt(c.GST_SECOND);
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;

const Pattern = enum(c_int) { smpte, snow, black, white, red, green, blue, checkers1, checkers2, checkers4, checkers8, circular, blink, mandelbrot };

const Rgb = struct { r: f32, g: f32, b: f32 };

const WHITE = 0;
const BLACK = 7;
const NEG_I = 8;
const POS_Q = 9;
const SUPER_BLACK = 10;
const DARK_GREY = 11;

const colors = [_]Rgb{
    .{ .r = 1, .g = 1, .b = 1 },
    .{ .r = 1, .g = 1, .b = 0 },
    .{ .r = 0, .g = 1, .b = 1 },
    .{ .r = 0, .g = 1, .b = 0 },
    .{ .r = 1, .g = 0, .b = 1 },
    .{ .r = 1, .g = 0, .b = 0 },
    .{ .r = 0, .g = 0, .b = 1 },
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 0, .g = 0, .b = 0.5 },
    .{ .r = 0, .g = 0.5, .b = 1 },
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 19.0 / 256.0, .g = 19.0 / 256.0, .b = 19.0 / 256.0 },
};

const positions = [_]f32{ -1, 1, 0, 1, 1, 1, 0, 1, 1, -1, 0, 1, -1, -1, 0, 1 };
const quad = [_]u16{ 0, 1, 2, 0, 2, 3 };

const SMPTE_VERT = "attribute vec4 position;\nattribute vec4 a_color;\nvarying vec4 color;\nvoid main()\n{\n  gl_Position = position;\n  color = a_color;\n}";
const SMPTE_FRAG = "varying vec4 color;\nvoid main()\n{\n  gl_FragColor = color;\n}";
const SNOW_VERT = "attribute vec4 position;\nvarying vec2 out_uv;\nvoid main()\n{\n   gl_Position = position;\n   out_uv = position.xy;\n}";
const SNOW_FRAG = "uniform float time;\nvarying vec2 out_uv;\n\nfloat rand(vec2 co){\n    return fract(sin(dot(co.xy, vec2(12.9898,78.233))) * 43758.5453);\n}\nvoid main()\n{\n  gl_FragColor = vec4(rand(time * out_uv));\n}";
const CHECKERS_VERT = "attribute vec4 position;\nvarying vec2 uv;\nvoid main()\n{\n  gl_Position = position;\n  uv = position.xy - 1.0;\n}";
const CHECKERS_FRAG = "uniform float checker_width;\nuniform float width;\nuniform float height;\nvarying vec2 uv;\nvoid main()\n{\n  vec2 xy_mod = floor (0.5 * uv * vec2(width, height) / (checker_width));\n  float result = mod (xy_mod.x + xy_mod.y, 2.0);\n  gl_FragColor.r = step (result, 0.5);\n  gl_FragColor.g = 1.0 - gl_FragColor.r;\n  gl_FragColor.ba = vec2(0.0, 1.0);\n}";
const MANDEL_VERT = "attribute vec4 position;\nuniform float aspect_ratio;\nvarying vec2 fractal_position;\nvoid main()\n{\n  gl_Position = position;\n  fractal_position = vec2(position.y * 0.5 - 0.3, aspect_ratio * position.x * 0.5);\n  fractal_position *= 2.5;\n}";
const MANDEL_FRAG = "uniform float time;\nvarying vec2 fractal_position;\nconst vec4 K = vec4(1.0, 0.66, 0.33, 3.0);\nvec4 hsv_to_rgb(float hue, float saturation, float value) {\n  vec4 p = abs(fract(vec4(hue) + K) * 6.0 - K.wwww);\n  return value * mix(K.xxxx, clamp(p - K.xxxx, 0.0, 1.0), saturation);\n}\nvec4 i_to_rgb(int i) {\n  float hue = float(i) / 100.0 + sin(time);\n  return hsv_to_rgb(hue, 0.5, 0.8);\n}\nvec2 pow_2_complex(vec2 c) {\n  return vec2(c.x*c.x - c.y*c.y, 2.0 * c.x * c.y);\n}\nvec2 mandelbrot(vec2 c, vec2 c0) {\n  return pow_2_complex(c) + c0;\n}\nvec4 iterate_pixel(vec2 position) {\n  vec2 c = vec2(0);\n  for (int i=0; i < 20; i++) {\n    if (c.x*c.x + c.y*c.y > 2.0*2.0)\n      return i_to_rgb(i);\n    c = mandelbrot(c, position);\n  }\n  return vec4(0, 0, 0, 1);\n}\nvoid main() {\n  gl_FragColor = iterate_pixel(fractal_position);\n}";
const CIRCULAR_VERT = "attribute vec4 position;\nvarying vec2 uv;\nvoid main()\n{\n  gl_Position = position;\n  uv = position.xy;\n}";
const CIRCULAR_FRAG = "uniform float aspect_ratio;\nvarying vec2 uv;\n#define PI 3.14159265\nvoid main() {\n  float dist = 0.5 * sqrt(uv.x * uv.x + uv.y / aspect_ratio * uv.y / aspect_ratio);\n  float seg = floor(dist * 16.0);\n  if (seg <= 0.0 || seg >= 8.0) {\n    gl_FragColor = vec4(vec3(0.0), 1.0);\n  } else {\n    float d = floor (256.0 * dist * 200.0 * pow (2.0, - (seg - 1.0) / 4.0) + 0.5) / 128.0;\n    gl_FragColor = vec4 (vec3(sin (d * PI) * 0.5 + 0.5), 1.0);\n  }\n}";

const Attr = struct { name: [*:0]const u8, location: c.gint, n: c.gint, offset: usize, stride: c.gint };

const N_QUADS = 21;
const Vertex = extern struct { x: f32, y: f32, z: f32, w: f32, r: f32, g: f32, b: f32 };

const Impl = struct {
    src: *Self,
    kind: Pattern,
    ctx: ?*c.GstGLContext = null,
    shader: ?*c.GstGLShader = null,
    snow_shader: ?*c.GstGLShader = null,
    color_shader: ?*c.GstGLShader = null,
    snow_position: c.gint = -1,
    vao: c.GLuint = 0,
    vbo: c.GLuint = 0,
    vbo_indices: c.GLuint = 0,
    attrs: [4]Attr = undefined,
    n_attrs: usize = 0,
    vertices: ?*const anyopaque = null,
    vertices_size: usize = 0,
    indices: ?[*]const u16 = null,
    index_offset: usize = 0,
    n_indices: c.GLsizei = 0,
    owned: bool = false,
    color: Rgb = colors[WHITE],
    checker: c.guint = 0,

    fn gl(p: *Impl) *c.GstGLFuncs {
        return @ptrCast(@alignCast(p.ctx.?.gl_vtable));
    }

    fn bind(p: *Impl) void {
        const g = p.gl();
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, p.vbo_indices);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vbo);
        for (p.attrs[0..p.n_attrs]) |*a| {
            if (a.location == -1) a.location = c.gst_gl_shader_get_attribute_location(p.shader, a.name);
            g.VertexAttribPointer.?(@bitCast(a.location), a.n, c.GL_FLOAT, c.GL_FALSE, a.stride, @ptrFromInt(a.offset));
            g.EnableVertexAttribArray.?(@bitCast(a.location));
        }
    }

    fn unbind(p: *Impl) void {
        const g = p.gl();
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        for (p.attrs[0..p.n_attrs]) |a| g.DisableVertexAttribArray.?(@bitCast(a.location));
    }

    fn setupBuffers(p: *Impl) bool {
        const g = p.gl();
        if (p.vbo != 0) return true;
        if (g.GenVertexArrays != null) {
            g.GenVertexArrays.?(1, &p.vao);
            g.BindVertexArray.?(p.vao);
        }
        g.GenBuffers.?(1, &p.vbo);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vbo);
        g.BufferData.?(c.GL_ARRAY_BUFFER, @intCast(p.vertices_size), p.vertices, c.GL_STATIC_DRAW);
        g.GenBuffers.?(1, &p.vbo_indices);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, p.vbo_indices);
        g.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, p.n_indices * 2, p.indices, c.GL_STATIC_DRAW);
        if (g.GenVertexArrays != null) {
            p.bind();
            g.BindVertexArray.?(0);
        }
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
        return true;
    }

    fn draw(p: *Impl) bool {
        if (!cm.that(p.ctx != null, "_src_shader_fill_bound_fbo", "src->base.context")) return false;
        if (!cm.that(p.shader != null, "_src_shader_fill_bound_fbo", "src->shader")) return false;
        const g = p.gl();
        c.gst_gl_shader_use(p.shader);
        if (g.GenVertexArrays != null) g.BindVertexArray.?(p.vao);
        p.bind();
        g.DrawElements.?(c.GL_TRIANGLES, p.n_indices, c.GL_UNSIGNED_SHORT, @ptrFromInt(p.index_offset));
        if (g.GenVertexArrays != null) {
            g.BindVertexArray.?(0);
        } else p.unbind();
        c.gst_gl_context_clear_shader(p.ctx);
        return true;
    }

    fn link(p: *Impl, vert: [*:0]const u8, frag: [*:0]const u8) ?*c.GstGLShader {
        var frags = [2][*c]const u8{ c.gst_gl_shader_string_get_highest_precision(p.ctx, c.GST_GLSL_VERSION_NONE, PROFILE), frag };
        var err: [*c]c.GError = null;
        const s = c.gst_gl_shader_new_link_with_stages(p.ctx, &err, c.gst_glsl_stage_new_with_string(p.ctx, c.GL_VERTEX_SHADER, c.GST_GLSL_VERSION_NONE, PROFILE, vert), c.gst_glsl_stage_new_with_strings(p.ctx, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, PROFILE, 2, &frags), @as(?*anyopaque, null));
        c.g_clear_error(&err);
        return s;
    }

    fn quadOnly(p: *Impl) void {
        p.n_attrs = 1;
        p.attrs[0] = .{ .name = "position", .location = -1, .n = 4, .offset = 0, .stride = 16 };
        p.vertices = &positions;
        p.vertices_size = @sizeOf(@TypeOf(positions));
        p.indices = &quad;
        p.n_indices = 6;
    }

    fn replaceShader(p: *Impl, s: ?*c.GstGLShader) void {
        if (p.shader != null) c.gst_object_unref(p.shader);
        p.shader = s;
    }

    fn initShader(p: *Impl, vert: [*:0]const u8, frag: [*:0]const u8) bool {
        if (p.shader != null) c.gst_object_unref(p.shader);
        p.shader = p.link(vert, frag);
        if (p.shader == null) return false;
        p.quadOnly();
        return true;
    }

    fn initSmpte(p: *Impl) bool {
        const coord: [*]Vertex = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Vertex) * N_QUADS * 4)));
        const idx: [*]u16 = @ptrCast(@alignCast(c.g_malloc0(2 * N_QUADS * 6)));
        var ci: usize = 0;
        const rows = [_][2]f32{ .{ 1.0 / 3.0, -1.0 }, .{ 0.5, 1.0 / 3.0 } };
        for (rows) |r| {
            for (0..7) |i| {
                const x0 = -1.0 + @as(f32, @floatFromInt(i)) * (2.0 / 7.0);
                const x1 = -1.0 + @as(f32, @floatFromInt(i + 1)) * (2.0 / 7.0);
                coord[ci * 4 + 0].x = x0;
                coord[ci * 4 + 0].y = r[0];
                coord[ci * 4 + 1].x = x1;
                coord[ci * 4 + 1].y = r[0];
                coord[ci * 4 + 2].x = x1;
                coord[ci * 4 + 2].y = r[1];
                coord[ci * 4 + 3].x = x0;
                coord[ci * 4 + 3].y = r[1];
                ci += 1;
            }
        }
        for (0..3) |i| {
            const x0 = -1.0 + @as(f32, @floatFromInt(i)) / 3.0;
            const x1 = -1.0 + @as(f32, @floatFromInt(i + 1)) / 3.0;
            setQuad(coord, ci, x0, x1, 1.0, 0.5);
            ci += 1;
        }
        for (0..3) |i| {
            const x0 = @as(f32, @floatFromInt(i)) / 6.0;
            const x1 = @as(f32, @floatFromInt(i + 1)) / 6.0;
            setQuad(coord, ci, x0, x1, 1.0, 0.5);
            ci += 1;
        }
        for (0..N_QUADS - 1) |i| {
            var k: usize = if (i < 7) i else if ((i - 7) & 1 != 0) BLACK else 13 -% i;
            k = switch (i) {
                14 => NEG_I,
                15 => WHITE,
                16 => POS_Q,
                17 => SUPER_BLACK,
                18 => BLACK,
                19 => DARK_GREY,
                else => k,
            };
            for (0..4) |j| {
                coord[i * 4 + j].z = 0;
                coord[i * 4 + j].w = 1;
                coord[i * 4 + j].r = colors[k].r;
                coord[i * 4 + j].g = colors[k].g;
                coord[i * 4 + j].b = colors[k].b;
            }
            for (0..6) |j| idx[i * 6 + j] = @intCast(i * 4 + quad[j]);
        }
        setQuad(coord, ci, 0.5, 1.0, 1.0, 0.5);
        for (0..4) |j| {
            coord[ci * 4 + j].z = 0;
            coord[ci * 4 + j].w = 1;
        }
        for (0..6) |j| idx[ci * 6 + j] = @intCast(ci * 4 + quad[j]);
        if (p.color_shader != null) c.gst_object_unref(p.color_shader);
        p.color_shader = p.link(SMPTE_VERT, SMPTE_FRAG);
        if (p.color_shader == null) {
            c.g_free(coord);
            c.g_free(idx);
            return false;
        }
        if (p.snow_shader != null) c.gst_object_unref(p.snow_shader);
        p.snow_shader = p.link(SNOW_VERT, SNOW_FRAG);
        if (p.snow_shader == null) {
            c.g_free(coord);
            c.g_free(idx);
            return false;
        }
        p.snow_position = -1;
        p.n_attrs = 2;
        p.attrs[0] = .{ .name = "position", .location = -1, .n = 4, .offset = 0, .stride = @sizeOf(Vertex) };
        p.attrs[1] = .{ .name = "a_color", .location = -1, .n = 3, .offset = 16, .stride = @sizeOf(Vertex) };
        p.replaceShader(@ptrCast(@alignCast(c.gst_object_ref(p.color_shader))));
        p.vertices = coord;
        p.vertices_size = @sizeOf(Vertex) * N_QUADS * 4;
        p.indices = idx;
        p.n_indices = N_QUADS * 6;
        p.owned = true;
        return true;
    }

    fn setQuad(coord: [*]Vertex, ci: usize, x0: f32, x1: f32, y0: f32, y1: f32) void {
        coord[ci * 4 + 0].x = x0;
        coord[ci * 4 + 0].y = y0;
        coord[ci * 4 + 1].x = x1;
        coord[ci * 4 + 1].y = y0;
        coord[ci * 4 + 2].x = x1;
        coord[ci * 4 + 2].y = y1;
        coord[ci * 4 + 3].x = x0;
        coord[ci * 4 + 3].y = y1;
    }

    fn time(p: *Impl) f32 {
        return @as(f32, @floatFromInt(p.src.parent.running_time)) / SECOND;
    }

    fn init(p: *Impl, ctx: ?*c.GstGLContext, info: *const c.GstVideoInfo) bool {
        p.ctx = ctx;
        const w: f32 = @floatFromInt(info.width);
        const h: f32 = @floatFromInt(info.height);
        switch (p.kind) {
            .smpte => if (!p.initSmpte()) return false,
            .snow => if (!p.initShader(SNOW_VERT, SNOW_FRAG)) return false,
            .checkers1, .checkers2, .checkers4, .checkers8 => {
                if (!p.initShader(CHECKERS_VERT, CHECKERS_FRAG)) return false;
                c.gst_gl_shader_use(p.shader);
                c.gst_gl_shader_set_uniform_1f(p.shader, "checker_width", @floatFromInt(p.checker));
                c.gst_gl_shader_set_uniform_1f(p.shader, "width", w);
                c.gst_gl_shader_set_uniform_1f(p.shader, "height", h);
                c.gst_gl_context_clear_shader(ctx);
            },
            .mandelbrot, .circular => {
                if (!p.initShader(if (p.kind == .mandelbrot) MANDEL_VERT else CIRCULAR_VERT, if (p.kind == .mandelbrot) MANDEL_FRAG else CIRCULAR_FRAG)) return false;
                c.gst_gl_shader_use(p.shader);
                c.gst_gl_shader_set_uniform_1f(p.shader, "aspect_ratio", w / h);
                c.gst_gl_context_clear_shader(ctx);
            },
            else => return true,
        }
        return p.setupBuffers();
    }

    fn clearColor(p: *Impl) bool {
        const g = p.gl();
        g.ClearColor.?(p.color.r, p.color.g, p.color.b, 1.0);
        g.Clear.?(c.GL_COLOR_BUFFER_BIT);
        return true;
    }

    fn timed(p: *Impl) bool {
        if (!cm.that(p.ctx != null, "_src_mandelbrot_fill_bound_fbo", "src->base.context")) return false;
        if (!cm.that(p.shader != null, "_src_mandelbrot_fill_bound_fbo", "src->shader")) return false;
        c.gst_gl_shader_use(p.shader);
        c.gst_gl_shader_set_uniform_1f(p.shader, "time", p.time());
        return p.draw();
    }

    fn fillSmpte(p: *Impl) bool {
        p.n_attrs = 2;
        p.replaceShader(@ptrCast(@alignCast(c.gst_object_ref(p.color_shader))));
        p.n_indices = (N_QUADS - 1) * 6;
        p.index_offset = 0;
        if (!p.draw()) return false;
        const color_pos = p.attrs[0].location;
        p.attrs[0].location = p.snow_position;
        p.n_attrs = 1;
        p.replaceShader(@ptrCast(@alignCast(c.gst_object_ref(p.snow_shader))));
        p.n_indices = 6;
        p.index_offset = (N_QUADS - 1) * 6 * 2;
        c.gst_gl_shader_use(p.snow_shader);
        c.gst_gl_shader_set_uniform_1f(p.snow_shader, "time", p.time());
        if (!p.draw()) return false;
        p.snow_position = p.attrs[0].location;
        p.attrs[0].location = color_pos;
        return true;
    }

    fn fill(p: *Impl) bool {
        return switch (p.kind) {
            .smpte => p.fillSmpte(),
            .snow => blk: {
                if (!cm.that(p.ctx != null, "_src_snow_fill_bound_fbo", "src->base.context")) break :blk false;
                if (!cm.that(p.shader != null, "_src_snow_fill_bound_fbo", "src->shader")) break :blk false;
                c.gst_gl_shader_use(p.shader);
                c.gst_gl_shader_set_uniform_1f(p.shader, "time", p.time());
                break :blk p.draw();
            },
            .checkers1, .checkers2, .checkers4, .checkers8 => p.draw(),
            .mandelbrot, .circular => p.timed(),
            .blink => blk: {
                p.color = if (p.color.r > 0.5) colors[BLACK] else colors[WHITE];
                break :blk p.clearColor();
            },
            else => p.clearColor(),
        };
    }

    fn deinit(p: *Impl) void {
        if (p.ctx) |_| {
            const g = p.gl();
            if (p.shader != null) c.gst_object_unref(p.shader);
            p.shader = null;
            if (p.vao != 0) g.DeleteVertexArrays.?(1, &p.vao);
            p.vao = 0;
            if (p.vbo != 0) g.DeleteBuffers.?(1, &p.vbo);
            p.vbo = 0;
            if (p.vbo_indices != 0) g.DeleteBuffers.?(1, &p.vbo_indices);
            p.vbo_indices = 0;
        }
    }

    fn free(p: *Impl) void {
        switch (p.kind) {
            .black, .white, .red, .green, .blue, .blink => {},
            else => p.deinit(),
        }
        if (p.owned) {
            c.g_free(@constCast(p.vertices));
            c.g_free(@constCast(@ptrCast(p.indices)));
        }
        if (p.snow_shader != null) c.gst_object_unref(p.snow_shader);
        if (p.color_shader != null) c.gst_object_unref(p.color_shader);
        c.g_free(p);
    }

    fn new(src: *Self, kind: Pattern) *Impl {
        const p: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
        p.* = .{ .src = src, .kind = kind };
        p.color = switch (kind) {
            .black => colors[BLACK],
            .red => colors[5],
            .green => colors[3],
            .blue => colors[6],
            else => colors[WHITE],
        };
        p.checker = switch (kind) {
            .checkers1 => 1,
            .checkers2 => 2,
            .checkers4 => 4,
            .checkers8 => 8,
            else => 0,
        };
        return p;
    }
};

const Self = extern struct {
    parent: c.GstGLBaseSrc,
    set_pattern: c.gint,
    active_pattern: c.gint,
    fbo: ?*c.GstGLFramebuffer,
    impl: ?*Impl,
};

const Class = extern struct {
    parent: c.GstGLBaseSrcClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "video/x-raw(memory:GLMemory), format = (string) RGBA, width = " ++ el.SIZE ++ ", height = " ++ el.SIZE ++ ", framerate = " ++ el.FPS ++ ",texture-target = (string) 2D");
var once: cm.Once = .{};
var pattern_once: cm.Once = .{};
var parent: *c.GstBaseSrcClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn patternType() c.GType {
    return pattern_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "SMPTE 100% color bars", .value_nick = "smpte" },
            .{ .value = 1, .value_name = "Random (television snow)", .value_nick = "snow" },
            .{ .value = 2, .value_name = "100% Black", .value_nick = "black" },
            .{ .value = 3, .value_name = "100% White", .value_nick = "white" },
            .{ .value = 4, .value_name = "Red", .value_nick = "red" },
            .{ .value = 5, .value_name = "Green", .value_nick = "green" },
            .{ .value = 6, .value_name = "Blue", .value_nick = "blue" },
            .{ .value = 7, .value_name = "Checkers 1px", .value_nick = "checkers-1" },
            .{ .value = 8, .value_name = "Checkers 2px", .value_nick = "checkers-2" },
            .{ .value = 9, .value_name = "Checkers 4px", .value_nick = "checkers-4" },
            .{ .value = 10, .value_name = "Checkers 8px", .value_nick = "checkers-8" },
            .{ .value = 11, .value_name = "Circular", .value_nick = "circular" },
            .{ .value = 12, .value_name = "Blink", .value_nick = "blink" },
            .{ .value = 13, .value_name = "Mandelbrot Fractal", .value_nick = "mandelbrot" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstGLTestSrcPattern", &values);
        }
    }.f);
}

fn fixate(bs: [*c]c.GstBaseSrc, caps_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const caps: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps_in)));
    const s = c.gst_caps_get_structure(caps, 0);
    _ = c.gst_structure_fixate_field_nearest_int(s, "width", 320);
    _ = c.gst_structure_fixate_field_nearest_int(s, "height", 240);
    _ = c.gst_structure_fixate_field_nearest_fraction(s, "framerate", 30, 1);
    return parent.fixate.?(bs, caps);
}

fn seekable(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 1;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_PATTERN => me(o).set_pattern = c.g_value_get_enum(v),
        PROP_IS_LIVE => c.gst_base_src_set_live(@ptrCast(@alignCast(o)), c.g_value_get_boolean(v)),
        else => {},
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_PATTERN => c.g_value_set_enum(v, me(o).set_pattern),
        PROP_IS_LIVE => c.g_value_set_boolean(v, c.gst_base_src_is_live(@ptrCast(@alignCast(o)))),
        else => cm.warnInvalid(FILE, o, id, spec, 236),
    }
}

fn callback(data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    if (s.impl == null or s.set_pattern != s.active_pattern) {
        if (s.impl) |p| p.free();
        s.impl = null;
        if (s.set_pattern < 0 or s.set_pattern > 13) return 0;
        const p = Impl.new(s, @enumFromInt(s.set_pattern));
        s.impl = p;
        if (!p.init(s.parent.context, &s.parent.out_info)) return 0;
        s.active_pattern = s.set_pattern;
    }
    return @intFromBool(s.impl.?.fill());
}

fn fillMemory(bs: [*c]c.GstGLBaseSrc, mem: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    return c.gst_gl_framebuffer_draw_to_texture(me(bs).fbo, mem, callback, bs);
}

fn glStart(bs: [*c]c.GstGLBaseSrc) callconv(.c) c.gboolean {
    me(bs).fbo = c.gst_gl_framebuffer_new_with_default_depth(bs[0].context, @intCast(bs[0].out_info.width), @intCast(bs[0].out_info.height));
    return 1;
}

fn glStop(bs: [*c]c.GstGLBaseSrc) callconv(.c) void {
    const s = me(bs);
    if (s.fbo != null) c.gst_object_unref(s.fbo);
    s.fbo = null;
    if (s.impl) |p| p.free();
    s.impl = null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseSrcClass, k);
    _ = c._gst_debug_category_new("gltestsrc", 0, "Video Test Source");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_PATTERN, c.g_param_spec_enum("pattern", "Pattern", "Type of test pattern to generate", patternType(), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_IS_LIVE, c.g_param_spec_boolean("is-live", "Is Live", "Whether to act as a live source", 0, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video test source", "Source/Video", "Creates a test video stream", "David A. Schleef <ds@schleef.org>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.is_seekable = seekable;
    bc.fixate = fixate;
    const gc: *c.GstGLBaseSrcClass = @ptrCast(@alignCast(k));
    gc.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2;
    gc.gl_start = glStart;
    gc.gl_stop = glStop;
    gc.fill_gl_memory = fillMemory;
    c.gst_type_mark_as_plugin_api(patternType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    me(inst).set_pattern = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_gl_base_src_get_type(), "GstGLTestSrc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "gltestsrc", c.GST_RANK_NONE, getType());
}
