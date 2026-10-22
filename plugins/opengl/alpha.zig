const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglalpha.c";
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;
const CTL = cm.RW | c.GST_PARAM_CONTROLLABLE;

const ALPHA_FRAG = "varying vec2 v_texcoord;\nuniform sampler2D tex;\nuniform float alpha;\nvoid main () {\n  vec4 rgba = texture2D (tex, v_texcoord);\n  rgba.a = alpha;\n  gl_FragColor = rgba;\n}\n";
const CHROMA_FRAG = "varying vec2 v_texcoord;\nuniform sampler2D tex;\nuniform float cb;\nuniform float cr;\nuniform float kg;\nuniform float accept_angle_tg;\nuniform float accept_angle_ctg;\nuniform float one_over_kc;\nuniform float kfgy_scale;\nuniform float noise_level2;\nuniform float smin;\nuniform float smax;\n#define from_yuv_bt601_offset vec3(-0.0625, -0.5, -0.5)\n#define from_yuv_bt601_rcoeff vec3(1.1640625, 0.000, 1.787)\n#define from_yuv_bt601_gcoeff vec3(1.1640625,-0.213,-0.531)\n#define from_yuv_bt601_bcoeff vec3(1.1640625, 2.112, 0.000)\n#define from_rgb_bt601_offset vec3(0.0625, 0.5, 0.5)\n#define from_rgb_bt601_ycoeff vec3( 0.2578125, 0.50390625, 0.09765625)\n#define from_rgb_bt601_ucoeff vec3(-0.1484375,-0.28906250, 0.43750000)\n#define from_rgb_bt601_vcoeff vec3( 0.4375000,-0.36718750,-0.07031250)\n#define PI 3.14159265\n\nvec3 yuv_to_rgb (vec3 val) {\n  vec3 rgb;\n  val += from_yuv_bt601_offset;\n  rgb.r = dot(val, from_yuv_bt601_rcoeff);\n  rgb.g = dot(val, from_yuv_bt601_gcoeff);\n  rgb.b = dot(val, from_yuv_bt601_bcoeff);\n  return rgb;\n}\nvec3 rgb_to_yuv (vec3 val) {\n  vec3 yuv;\n  yuv.r = dot(val.rgb, from_rgb_bt601_ycoeff);\n  yuv.g = dot(val.rgb, from_rgb_bt601_ucoeff);\n  yuv.b = dot(val.rgb, from_rgb_bt601_vcoeff);\n  yuv += from_rgb_bt601_offset;\n  return yuv;\n}\nvec4 chroma_keying_yuv (vec4 yuva) {\n  float y, u, v;\n  y = yuva.x;\n  u = yuva.y-0.5;\n  v = yuva.z-0.5;\n  if (y < smin || y > smax) {\n    return yuva;\n  }\n  vec4 new;\n  float tmp, tmp1;\n  float x = clamp ((u * cb + v * cr) * 2.0, -0.5, 0.5);\n  float z = clamp ((v * cb - u * cr) * 2.0, -0.5, 0.5);\n  if (abs(z) > min (0.5, x * accept_angle_tg * 0.0625)) {\n    return yuva;\n  }\n  float x1 = min (0.5, abs(z * accept_angle_ctg * 0.0625));\n  float y1 = z;\n  tmp1 = max (0.0, x-x1);\n  float b_alpha = yuva.a * (1.0 - clamp (tmp1 * one_over_kc, 0.0, 1.0));\n  tmp = min (1.0, tmp1 * kfgy_scale * 0.0625);\n  new.x = max (y-tmp, 0.0);//y < tmp ? 0.0 : y - tmp;\n  new.y = clamp ((x1 * cb - y1 * cr) * 2.0, -0.5, 0.5)+0.5;\n  new.z = clamp ((y1 * cb + x1 * cr) * 2.0, -0.5, 0.5)+0.5;\n  new.a = z * z + (x - kg) * (x - kg) < noise_level2 ? 0.0 : b_alpha;\n  return new;\n}\nvoid main () {\n  vec4 yuva;\n  vec4 rgba = texture2D (tex, v_texcoord);\n  yuva.xyz = rgb_to_yuv (rgba.rgb);\n  yuva.a = rgba.a;\n  yuva = chroma_keying_yuv (yuva);\n  rgba.rgb = yuv_to_rgb (yuva.xyz);\n  rgba.a = yuva.a;\n  gl_FragColor = rgba;\n}\n";

const Method = enum(c.gint) { set, green, blue, custom };

const Prop = enum(c.guint) { method = 1, alpha, target_r, target_g, target_b, angle, noise_level, black_sensitivity, white_sensitivity };

const matrix = [_]f32{ 0.2578125, 0.50390625, 0.09765625, 0.0625, -0.1484375, -0.28906250, 0.43750000, 0.5, 0.4375000, -0.36718750, -0.07031250, 0.5 };

const Self = extern struct {
    filter: c.GstGLFilter,
    alpha_shader: ?*c.GstGLShader,
    chroma_key_shader: ?*c.GstGLShader,
    alpha: f64,
    target_r: c.guint,
    target_g: c.guint,
    target_b: c.guint,
    method: c.gint,
    angle: f32,
    noise_level: f32,
    black_sensitivity: c.guint,
    white_sensitivity: c.guint,
    cb: f32,
    cr: f32,
    kg: f32,
    accept_angle_tg: f32,
    accept_angle_ctg: f32,
    one_over_kc: f32,
    kfgy_scale: f32,
    noise_level2: f32,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var once: cm.Once = .{};
var method_once: cm.Once = .{};
var parent_gl: *c.GstGLBaseFilterClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn methodType() c.GType {
    return method_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "Set/adjust alpha channel", .value_nick = "set" },
            .{ .value = 1, .value_name = "Chroma Key on pure green", .value_nick = "green" },
            .{ .value = 2, .value_name = "Chroma Key on pure blue", .value_nick = "blue" },
            .{ .value = 3, .value_name = "Chroma Key on custom RGB values", .value_nick = "custom" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstGLAlphaMethod", &values);
        }
    }.f);
}

fn wrap(v_in: f32, a: f32, b: f32) f32 {
    var v = v_in;
    const from = @min(a, b);
    const to = @max(a, b);
    if (!std.math.isFinite(to) or !std.math.isFinite(from) or !std.math.isFinite(v)) return v;
    const diff = to - from;
    while (v < from) v += diff;
    while (v > to) v -= diff;
    return v;
}

fn update(s: *Self) void {
    const bt: [*c]c.GstBaseTransform = @ptrCast(s);
    cm.lock(s);
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    switch (s.method) {
        @intFromEnum(Method.green) => g = 1,
        @intFromEnum(Method.blue) => b = 1,
        else => {
            r = @floatCast(@as(f64, @floatFromInt(s.target_r)) / 255.0);
            g = @floatCast(@as(f64, @floatFromInt(s.target_g)) / 255.0);
            b = @floatCast(@as(f64, @floatFromInt(s.target_b)) / 255.0);
        },
    }
    const m = matrix;
    const y = m[0] * r + m[1] * g + m[2] * b + m[3];
    const u = m[4] * r + m[5] * g + m[6] * b;
    const v = m[8] * r + m[9] * g + m[10] * b;
    const kgl: f32 = @floatCast(@sqrt(@as(f64, u * u + v * v)));
    s.cb = @floatCast(@as(f64, u / kgl) * 0.5);
    s.cr = @floatCast(@as(f64, v / kgl) * 0.5);
    const rad = std.math.pi * @as(f64, s.angle) / 180;
    var tmp: f32 = @floatCast(15 * @tan(rad));
    s.accept_angle_tg = @min(tmp, 255);
    tmp = @floatCast(15 / @tan(rad));
    s.accept_angle_ctg = @min(tmp, 255);
    s.one_over_kc = wrap(2 / kgl - 255, 0, 256);
    tmp = 15 * y / kgl;
    s.kfgy_scale = @min(tmp, 255);
    s.kg = @floatCast(if (@as(f64, kgl) < 0.5) @as(f64, kgl) else 0.5);
    const nl: f64 = s.noise_level;
    s.noise_level2 = @floatCast(nl / 256.0 * nl / 256.0);
    const pass = s.method == @intFromEnum(Method.set) and s.alpha == 1.0;
    cm.unlock(s);
    const cur = c.gst_base_transform_is_passthrough(bt) != 0;
    c.gst_base_transform_set_passthrough(bt, @intFromBool(pass));
    if (cur != pass) c.gst_base_transform_reconfigure_src(bt);
}

fn link(s: *Self, src: [*:0]const u8, what: [*:0]const u8, line: c.gint) ?*c.GstGLShader {
    const ctx = el.base(s).context;
    var err: [*c]c.GError = null;
    var frags = [2][*c]const u8{ c.gst_gl_shader_string_get_highest_precision(ctx, c.GST_GLSL_VERSION_NONE, PROFILE), src };
    const sh = c.gst_gl_shader_new_link_with_stages(ctx, &err, c.gst_glsl_stage_new_default_vertex(ctx), c.gst_glsl_stage_new_with_strings(ctx, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, PROFILE, 2, &frags), @as(?*anyopaque, null));
    if (sh == null) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(what), c.g_strdup(if (err != null) err[0].message else "Unknown error"), FILE, "_create_shader", line);
        c.g_clear_error(&err);
    }
    return sh;
}

fn createShader(s: *Self) bool {
    if (s.alpha_shader != null) c.gst_object_unref(s.alpha_shader);
    s.alpha_shader = link(s, ALPHA_FRAG, "Failed to initialize alpha shader", 362);
    if (s.alpha_shader == null) return false;
    if (s.chroma_key_shader != null) c.gst_object_unref(s.chroma_key_shader);
    s.chroma_key_shader = link(s, CHROMA_FRAG, "Failed to initialize chroma key shader", 380);
    if (s.chroma_key_shader == null) return false;
    s.filter.draw_attr_position_loc = c.gst_gl_shader_get_attribute_location(s.alpha_shader, "a_position");
    s.filter.draw_attr_texture_loc = c.gst_gl_shader_get_attribute_location(s.alpha_shader, "a_texcoord");
    return true;
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    if (!createShader(me(bf))) return 0;
    return parent_gl.gl_start.?(bf);
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    if (s.alpha_shader != null) c.gst_object_unref(s.alpha_shader);
    s.alpha_shader = null;
    if (s.chroma_key_shader != null) c.gst_object_unref(s.chroma_key_shader);
    s.chroma_key_shader = null;
    parent_gl.gl_stop.?(bf);
}

fn beforeTransform(bt: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) void {
    el.syncValues(bt, b);
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    const s = me(f);
    if (s.alpha_shader == null) _ = createShader(s);
    cm.lock(s);
    var sh: ?*c.GstGLShader = undefined;
    if (s.method == @intFromEnum(Method.set)) {
        sh = s.alpha_shader;
        c.gst_gl_shader_use(sh);
        c.gst_gl_shader_set_uniform_1f(sh, "alpha", @floatCast(s.alpha));
    } else {
        sh = s.chroma_key_shader;
        c.gst_gl_shader_use(sh);
        c.gst_gl_shader_set_uniform_1f(sh, "cb", s.cb);
        c.gst_gl_shader_set_uniform_1f(sh, "cr", s.cr);
        c.gst_gl_shader_set_uniform_1f(sh, "kg", s.kg);
        c.gst_gl_shader_set_uniform_1f(sh, "accept_angle_tg", s.accept_angle_tg);
        c.gst_gl_shader_set_uniform_1f(sh, "accept_angle_ctg", s.accept_angle_ctg);
        c.gst_gl_shader_set_uniform_1f(sh, "one_over_kc", s.one_over_kc);
        c.gst_gl_shader_set_uniform_1f(sh, "kfgy_scale", s.kfgy_scale);
        c.gst_gl_shader_set_uniform_1f(sh, "noise_level2", s.noise_level2);
        c.gst_gl_shader_set_uniform_1f(sh, "smin", @floatCast(0.5 - @as(f64, @floatFromInt(s.black_sensitivity)) / 255.0));
        c.gst_gl_shader_set_uniform_1f(sh, "smax", @floatCast(0.5 + @as(f64, @floatFromInt(s.white_sensitivity)) / 255.0));
    }
    cm.unlock(s);
    _ = c.gst_gl_filter_render_to_target_with_shader(f, in, out, sh);
    return 1;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    switch (id) {
        @intFromEnum(Prop.method) => s.method = c.g_value_get_enum(v),
        @intFromEnum(Prop.alpha) => s.alpha = c.g_value_get_double(v),
        @intFromEnum(Prop.target_r) => s.target_r = c.g_value_get_uint(v),
        @intFromEnum(Prop.target_g) => s.target_g = c.g_value_get_uint(v),
        @intFromEnum(Prop.target_b) => s.target_b = c.g_value_get_uint(v),
        @intFromEnum(Prop.angle) => s.angle = c.g_value_get_float(v),
        @intFromEnum(Prop.noise_level) => s.noise_level = c.g_value_get_float(v),
        @intFromEnum(Prop.black_sensitivity) => s.black_sensitivity = c.g_value_get_uint(v),
        @intFromEnum(Prop.white_sensitivity) => s.white_sensitivity = c.g_value_get_uint(v),
        else => cm.warnInvalid(FILE, o, id, spec, 609),
    }
    cm.unlock(s);
    update(s);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.method) => c.g_value_set_enum(v, s.method),
        @intFromEnum(Prop.alpha) => c.g_value_set_double(v, s.alpha),
        @intFromEnum(Prop.target_r) => c.g_value_set_uint(v, s.target_r),
        @intFromEnum(Prop.target_g) => c.g_value_set_uint(v, s.target_g),
        @intFromEnum(Prop.target_b) => c.g_value_set_uint(v, s.target_b),
        @intFromEnum(Prop.angle) => c.g_value_set_float(v, s.angle),
        @intFromEnum(Prop.noise_level) => c.g_value_set_float(v, s.noise_level),
        @intFromEnum(Prop.black_sensitivity) => c.g_value_set_uint(v, s.black_sensitivity),
        @intFromEnum(Prop.white_sensitivity) => c.g_value_set_uint(v, s.white_sensitivity),
        else => cm.warnInvalid(FILE, o, id, spec, 651),
    }
}

fn install(oc: *c.GObjectClass, id: Prop, spec: [*c]c.GParamSpec) void {
    c.g_object_class_install_property(oc, @intFromEnum(id), spec);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    _ = c._gst_debug_category_new("glalpha", 0, "glalpha");
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    install(oc, .method, c.g_param_spec_enum("method", "Method", "How the alpha channels should be created", methodType(), 0, cm.RW));
    install(oc, .alpha, c.g_param_spec_double("alpha", "Alpha", "The value for the alpha channel", 0, 1, 1, CTL));
    install(oc, .target_r, c.g_param_spec_uint("target-r", "Target Red", "The red color value for custom RGB chroma keying", 0, 255, 0, CTL));
    install(oc, .target_g, c.g_param_spec_uint("target-g", "Target Green", "The green color value for custom RGB chroma keying", 0, 255, 255, CTL));
    install(oc, .target_b, c.g_param_spec_uint("target-b", "Target Blue", "The blue color value for custom RGB chroma keying", 0, 255, 0, CTL));
    install(oc, .angle, c.g_param_spec_float("angle", "Angle", "Size of the colorcube to change", 0, 90, 20, CTL));
    install(oc, .noise_level, c.g_param_spec_float("noise-level", "Noise Level", "Size of noise radius", 0, 64, 2, CTL));
    install(oc, .black_sensitivity, c.g_param_spec_uint("black-sensitivity", "Black Sensitivity", "Sensitivity to dark colors", 0, 128, 100, CTL));
    install(oc, .white_sensitivity, c.g_param_spec_uint("white-sensitivity", "White Sensitivity", "Sensitivity to bright colors", 0, 128, 100, CTL));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL Alpha Filter", "Filter/Effect/Video", "Adds an alpha channel to video using OpenGL - uniform or chroma-keying", "Matthew Waters <matthew@centricular.com>");
    const bt = el.baseTransformClass(k);
    bt.before_transform = beforeTransform;
    bt.transform_ip_on_passthrough = 0;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.filter_texture = filterTexture;
    c.gst_type_mark_as_plugin_api(methodType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.alpha = 1;
    s.method = 0;
    s.target_r = 0;
    s.target_g = 255;
    s.target_b = 0;
    s.angle = 20;
    s.noise_level = 2;
    s.black_sensitivity = 100;
    s.white_sensitivity = 100;
    update(s);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_gl_filter_get_type(), "GstGLAlpha", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glalpha", c.GST_RANK_NONE, getType());
}
