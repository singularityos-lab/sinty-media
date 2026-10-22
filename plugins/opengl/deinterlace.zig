const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstgldeinterlace.c";
const PROP_METHOD = 1;
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;

const GREEDYH = "uniform sampler2D tex;\nuniform sampler2D tex_prev;\nuniform float max_comb;\nuniform float motion_threshold;\nuniform float motion_sense;\nuniform float width;\nuniform float height;\nvarying vec2 v_texcoord;\nvoid main () {\n  if (int(mod(v_texcoord.y * height, 2.0)) == 0) {\n    gl_FragColor = vec4(texture2D(tex_prev, v_texcoord).rgb, 1.0);\n  } else {\n    vec2 texcoord_L1_a1, texcoord_L3_a1, texcoord_L1, texcoord_L3, texcoord_L1_1, texcoord_L3_1;\n    vec3 L1_a1, L3_a1, L1, L3, L1_1, L3_1;\n    texcoord_L1 = vec2(v_texcoord.x, v_texcoord.y - 1.0 / height);\n    texcoord_L3 = vec2(v_texcoord.x, v_texcoord.y + 1.0 / height);\n    L1 = texture2D(tex_prev, texcoord_L1).rgb;\n    L3 = texture2D(tex_prev, texcoord_L3).rgb;\n    if (v_texcoord.x == 1.0 && v_texcoord.y == 1.0) {\n      L1_1 = L1;\n      L3_1 = L3;\n    } else {\n      texcoord_L1_1 = vec2(v_texcoord.x + 1.0 / width, v_texcoord.y - 1.0 / height);\n      texcoord_L3_1 = vec2(v_texcoord.x + 1.0 / width, v_texcoord.y + 1.0 / height);\n      L1_1 = texture2D(tex_prev, texcoord_L1_1).rgb;\n      L3_1 = texture2D(tex_prev, texcoord_L3_1).rgb;\n    }\n    if (int(ceil(v_texcoord.x + v_texcoord.y)) == 0) {\n      L1_a1 = L1;\n      L3_a1 = L3;\n    } else {\n      texcoord_L1_a1 = vec2(v_texcoord.x - 1.0 / width, v_texcoord.y - 1.0 / height);\n      texcoord_L3_a1 = vec2(v_texcoord.x - 1.0 / width, v_texcoord.y + 1.0 / height);\n      L1_a1 = texture2D(tex_prev, texcoord_L1_a1).rgb;\n      L3_a1 = texture2D(tex_prev, texcoord_L3_a1).rgb;\n    }\n    vec3 avg_a1 = (L1_a1 + L3_a1) / 2.0;\n    vec3 avg = (L1 + L3) / 2.0;\n    vec3 avg_1 = (L1_1 + L3_1) / 2.0;\n    vec3 avg_s = (avg_a1 + avg_1) / 2.0;\n    vec3 avg_sc = (avg_s + avg) / 2.0;\n    vec3 L2 = texture2D(tex, v_texcoord).rgb;\n    vec3 LP2 = texture2D(tex_prev, v_texcoord).rgb;\n    vec3 best;\n    if (abs(L2.r - avg_sc.r) < abs(LP2.r - avg_sc.r)) {\n      best.r = L2.r;\n    } else {\n      best.r = LP2.r;\n    }\n    if (abs(L2.g - avg_sc.g) < abs(LP2.g - avg_sc.g)) {\n      best.g = L2.g;\n    } else {\n      best.g = LP2.g;\n    }\n    if (abs(L2.b - avg_sc.b) < abs(LP2.b - avg_sc.b)) {\n      best.b = L2.b;\n    } else {\n      best.b = LP2.b;\n    }\n    vec3 last;\n    last.r = clamp(best.r, max(min(L1.r, L3.r) - max_comb, 0.0), min(max(L1.r, L3.r) + max_comb, 1.0));\n    last.g = clamp(best.g, max(min(L1.g, L3.g) - max_comb, 0.0), min(max(L1.g, L3.g) + max_comb, 1.0));\n    last.b = clamp(best.b, max(min(L1.b, L3.b) - max_comb, 0.0), min(max(L1.b, L3.b) + max_comb, 1.0));\n    const vec3 luma = vec3 (0.299011, 0.586987, 0.114001);    float mov = min(max(abs(dot(L2 - LP2, luma)) - motion_threshold, 0.0) * motion_sense, 1.0);\n    last = last * (1.0 - mov) + avg_sc * mov;\n    gl_FragColor = vec4(last, 1.0);\n  }\n}\n";
const VFIR = "uniform sampler2D tex;\nuniform float width;\nuniform float height;\nvarying vec2 v_texcoord;\nvoid main()\n{\n  vec2 topcoord, botcoord;\n  vec4 cur_color, top_color, bot_color;\n  topcoord.x = v_texcoord.x;\n  botcoord.x = v_texcoord.x;\n  if (v_texcoord.y == 0.0 || v_texcoord.y == 1.0) {\n    topcoord.y = v_texcoord.y ;\n    botcoord.y = v_texcoord.y ;\n  }\n  else {\n    topcoord.y = v_texcoord.y - 1.0/height;\n    botcoord.y = v_texcoord.y + 1.0/height;\n  }\n  cur_color = texture2D(tex, v_texcoord);\n  top_color = texture2D(tex, topcoord);\n  bot_color = texture2D(tex, botcoord);\n  gl_FragColor = 0.5*cur_color + 0.25*top_color + 0.25*bot_color;\n}";

const Method = enum(c.gint) { vfir, greedyh };

const Self = extern struct {
    filter: c.GstGLFilter,
    shaderstable: ?*c.GHashTable,
    prev_buffer: [*c]c.GstBuffer,
    prev_tex: [*c]c.GstGLMemory,
    current_method: c.gint,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var once: cm.Once = .{};
var method_once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn methodType() c.GType {
    return method_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "Blur Vertical", .value_nick = "vfir" },
            .{ .value = 1, .value_name = "Motion Adaptive: Advanced Detection", .value_nick = "greedyh" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstGLDeinterlaceMethod", &values);
        }
    }.f);
}

fn setMethod(s: *Self, m: c.gint) void {
    if (m != 0 and m != 1) {
        c.g_assertion_message_expr("GStreamer", FILE, 231, "gst_gl_deinterlace_set_method", null);
        return;
    }
    s.current_method = m;
}

fn start(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    me(bt).shaderstable = c.g_hash_table_new(c.g_str_hash, c.g_str_equal);
    return parent.start.?(bt);
}

fn clean(_: c.gpointer, v: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_object_unref(v);
}

fn stop(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(bt);
    _ = c.gst_buffer_replace(&s.prev_buffer, null);
    if (s.shaderstable != null) {
        c.g_hash_table_foreach(s.shaderstable, clean, s);
        c.g_hash_table_unref(s.shaderstable);
        s.shaderstable = null;
    }
    return parent.stop.?(bt);
}

fn internalCaps(_: [*c]c.GstGLFilter, dir: c.GstPadDirection, caps: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const res = c.gst_caps_copy(caps);
    var n = c.gst_caps_get_size(res);
    while (n > 0) : (n -= 1) {
        if (dir == c.GST_PAD_SINK) c.gst_structure_remove_field(c.gst_caps_get_structure(res, n - 1), "interlace-mode");
    }
    return res;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_METHOD) setMethod(me(o), c.g_value_get_enum(v)) else cm.warnInvalid(FILE, o, id, spec, 364);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_METHOD) c.g_value_set_enum(v, me(o).current_method) else cm.warnInvalid(FILE, o, id, spec, 380);
}

fn initFbo(_: [*c]c.GstGLFilter) callconv(.c) c.gboolean {
    return 1;
}

fn shaderFor(f: [*c]c.GstGLFilter, name: [*:0]const u8, src: [*:0]const u8) ?*c.GstGLShader {
    const s = me(f);
    const ctx = el.base(f).context;
    var shader: ?*c.GstGLShader = @ptrCast(@alignCast(c.g_hash_table_lookup(s.shaderstable, name)));
    var frags = [2][*c]const u8{ c.gst_gl_shader_string_get_highest_precision(ctx, c.GST_GLSL_VERSION_NONE, PROFILE), src };
    if (shader == null) {
        var err: [*c]c.GError = null;
        shader = c.gst_gl_shader_new_link_with_stages(ctx, &err, c.gst_glsl_stage_new_default_vertex(ctx), c.gst_glsl_stage_new_with_strings(ctx, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, PROFILE, 2, &frags), @as(?*anyopaque, null));
        if (shader == null) cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("Failed to initialize %s shader", name), null, FILE, "gst_gl_deinterlace_get_fragment_shader", 443);
        f[0].draw_attr_position_loc = c.gst_gl_shader_get_attribute_location(shader, "a_position");
        f[0].draw_attr_texture_loc = c.gst_gl_shader_get_attribute_location(shader, "a_texcoord");
    }
    _ = c.g_hash_table_insert(s.shaderstable, @ptrCast(@constCast(name)), shader);
    return shader;
}

fn prepare(f: [*c]c.GstGLFilter, name: [*:0]const u8, src: [*:0]const u8) ?*c.GstGLShader {
    const ctx = el.base(f).context;
    const shader = shaderFor(f, name, src) orelse return null;
    const g: *c.GstGLFuncs = @ptrCast(@alignCast(ctx[0].gl_vtable));
    if (c.gst_gl_context_check_gl_version(ctx, c.GST_GL_API_OPENGL, 1, 0) != 0) {
        g.MatrixMode.?(c.GL_PROJECTION);
        g.LoadIdentity.?();
    }
    c.gst_gl_shader_use(shader);
    return shader;
}

fn size(f: [*c]c.GstGLFilter, shader: ?*c.GstGLShader) void {
    c.gst_gl_shader_set_uniform_1f(shader, "width", @floatFromInt(f[0].out_info.width));
    c.gst_gl_shader_set_uniform_1f(shader, "height", @floatFromInt(f[0].out_info.height));
}

fn vfir(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    const shader = prepare(f, "vfir", VFIR) orelse return 0;
    const g: *c.GstGLFuncs = @ptrCast(@alignCast(el.base(f).context[0].gl_vtable));
    g.ActiveTexture.?(c.GL_TEXTURE0);
    g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(in));
    c.gst_gl_shader_set_uniform_1i(shader, "tex", 0);
    size(f, shader);
    c.gst_gl_filter_draw_fullscreen_quad(f);
    return 1;
}

fn greedyh(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    const s = me(f);
    const shader = prepare(f, "greedhy", GREEDYH) orelse return 0;
    const g: *c.GstGLFuncs = @ptrCast(@alignCast(el.base(f).context[0].gl_vtable));
    if (s.prev_tex != null) {
        g.ActiveTexture.?(c.GL_TEXTURE1);
        c.gst_gl_shader_set_uniform_1i(shader, "tex_prev", 1);
        g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(s.prev_tex));
    }
    g.ActiveTexture.?(c.GL_TEXTURE0);
    g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(in));
    c.gst_gl_shader_set_uniform_1i(shader, "tex", 0);
    c.gst_gl_shader_set_uniform_1f(shader, "max_comb", 5.0 / 255.0);
    c.gst_gl_shader_set_uniform_1f(shader, "motion_threshold", 25.0 / 255.0);
    c.gst_gl_shader_set_uniform_1f(shader, "motion_sense", 30.0 / 255.0);
    size(f, shader);
    c.gst_gl_filter_draw_fullscreen_quad(f);
    s.prev_tex = in;
    return 1;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    const func: c.GstGLFilterRenderFunc = if (me(f).current_method == @intFromEnum(Method.greedyh)) greedyh else vfir;
    _ = c.gst_gl_filter_render_to_target(f, in, out, func, f);
    return 1;
}

fn filter(f: [*c]c.GstGLFilter, in: [*c]c.GstBuffer, out: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    _ = c.gst_gl_filter_filter_texture(f, in, out);
    _ = c.gst_buffer_replace(&me(f).prev_buffer, in);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL deinterlacing filter", "Deinterlace", "Deinterlacing based on fragment shaders", "Julien Isorce <julien.isorce@mail.com>");
    c.g_object_class_install_property(oc, PROP_METHOD, c.g_param_spec_enum("method", "Deinterlace Method", "Select which deinterlace method apply to GL video texture", methodType(), 0, cm.RW));
    const bt = el.baseTransformClass(k);
    bt.start = start;
    bt.stop = stop;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.transform_internal_caps = internalCaps;
    fc.filter = filter;
    fc.filter_texture = filterTexture;
    fc.init_fbo = initFbo;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL3;
    c.gst_type_mark_as_plugin_api(methodType(), 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLDeinterlace", Class, Self, classInit, null);
            _ = c._gst_debug_category_new("gldeinterlace", 0, "gldeinterlace element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "gldeinterlace", c.GST_RANK_NONE, getType());
}
