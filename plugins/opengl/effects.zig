const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");
const glsl = @import("effects/glsl.zig");

const FILE = "../ext/gl/gstgleffects.c";
const PROP_EFFECT = 1 << 1;
const PROP_HSWAP = 1 << 2;
const PROP_INVERT = 1 << 3;
const N_MID = 5;
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;
const API = c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3;

const Effect = enum(c.gint) { identity, mirror, squeeze, stretch, tunnel, fisheye, twirl, bulge, square, heat, sepia, xpro, lumaxpro, xray, sin, glow, sobel, blur, laplacian };

const Curve = enum(usize) { heat, sepia, xpro, luma_xpro, xray };

const curves = @embedFile("data/curves.bin");

const Descriptor = extern struct {
    effect: c.gint,
    supported_properties: c.guint,
    filter_name: [*c]const u8,
    filter_longname: [*c]const u8,
};

const names = [_][2][*:0]const u8{
    .{ "Do nothing Effect", "identity" },
    .{ "Mirror Effect", "mirror" },
    .{ "Squeeze Effect", "squeeze" },
    .{ "Stretch Effect", "stretch" },
    .{ "Light Tunnel Effect", "tunnel" },
    .{ "FishEye Effect", "fisheye" },
    .{ "Twirl Effect", "twirl" },
    .{ "Bulge Effect", "bulge" },
    .{ "Square Effect", "square" },
    .{ "Heat Signature Effect", "heat" },
    .{ "Sepia Toning Effect", "sepia" },
    .{ "Cross Processing Effect", "xpro" },
    .{ "Luma Cross Processing Effect", "lumaxpro" },
    .{ "Glowing negative effect", "xray" },
    .{ "All Grey but Red Effect", "sin" },
    .{ "Glow Lighting Effect", "glow" },
    .{ "Sobel edge detection Effect", "sobel" },
    .{ "Blur with 9x9 separable convolution Effect", "blur" },
    .{ "Laplacian Convolution Demo Effect", "laplacian" },
};

var values = blk: {
    var v: [names.len + 1]c.GEnumValue = undefined;
    for (names, 0..) |n, i| v[i] = .{ .value = @intCast(i), .value_name = n[0], .value_nick = n[1] };
    v[names.len] = .{ .value = 0, .value_name = null, .value_nick = null };
    break :blk v;
};

var descriptors = blk: {
    var d: [names.len + 1]Descriptor = undefined;
    for (names, 0..) |n, i| {
        d[i] = .{ .effect = @intCast(i), .supported_properties = 0, .filter_name = n[1], .filter_longname = n[0] };
        if (i == @intFromEnum(Effect.sobel) or i == @intFromEnum(Effect.laplacian)) d[i].supported_properties = PROP_INVERT;
    }
    d[names.len] = .{ .effect = 0, .supported_properties = 0, .filter_name = null, .filter_longname = null };
    break :blk d;
};

const Self = extern struct {
    filter: c.GstGLFilter,
    current_effect: c.gint,
    intexture: [*c]c.GstGLMemory,
    midtexture: [N_MID][*c]c.GstGLMemory,
    outtexture: [*c]c.GstGLMemory,
    curve: [5]c.GLuint,
    shaderstable: ?*c.GHashTable,
    horizontal_swap: c.gboolean,
    invert: c.gboolean,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
    filter_descriptor: ?*const Descriptor,
};

var once: cm.Once = .{};
var enum_once: cm.Once = .{};
var registered: usize = 0;
var parent: *c.GstBaseTransformClass = undefined;
var parent_gl: *c.GstGLBaseFilterClass = undefined;
var glow_kernel: [9]f32 = .{0} ** 9;
var xray_kernel: [9]f32 = .{0} ** 9;
var blur_kernel: [9]f32 = .{0} ** 9;
var glow_ready = false;
var xray_ready = false;
var blur_once: usize = 0;

extern fn expf(f32) f32;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(el.base(s).context[0].gl_vtable));
}

fn gaussian(k: []f32, size: usize, sigma: f32) void {
    if (!cm.that(size % 2 != 0, "fill_gaussian_kernel", "(size % 2) != 0")) return;
    var sum: f32 = 0;
    const l: i32 = @intCast((size - 1) / 2);
    for (0..size) |i| {
        const x = @as(f32, @floatFromInt(@as(i32, @intCast(i)) - l)) / sigma;
        const xd: f64 = x;
        k[i] = expf(@floatCast(-0.5 * (xd * xd)));
        sum += k[i];
    }
    for (0..size) |i| k[i] /= sum;
}

fn effectType() c.GType {
    return enum_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstGLEffectsEffect", &values);
        }
    }.f);
}

fn shaderFor(s: *Self, name: [*:0]const u8, src: [*:0]const u8) ?*c.GstGLShader {
    const ctx = el.base(s).context;
    var shader: ?*c.GstGLShader = @ptrCast(@alignCast(c.g_hash_table_lookup(s.shaderstable, name)));
    if (shader == null) {
        var err: [*c]c.GError = null;
        var frags = [2][*c]const u8{ c.gst_gl_shader_string_get_highest_precision(ctx, c.GST_GLSL_VERSION_NONE, PROFILE), src };
        shader = c.gst_gl_shader_new_link_with_stages(ctx, &err, c.gst_glsl_stage_new_default_vertex(ctx), c.gst_glsl_stage_new_with_strings(ctx, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, PROFILE, 2, &frags), @as(?*anyopaque, null));
        if (shader == null) cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("Failed to initialize %s shader", name), null, FILE, "gst_gl_effects_get_fragment_shader", 587);
        s.filter.draw_attr_position_loc = c.gst_gl_shader_get_attribute_location(shader, "a_position");
        s.filter.draw_attr_texture_loc = c.gst_gl_shader_get_attribute_location(shader, "a_texcoord");
    }
    _ = c.g_hash_table_insert(s.shaderstable, @ptrCast(@constCast(name)), shader);
    return shader;
}

fn render(s: *Self, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory, shader: ?*c.GstGLShader) void {
    _ = c.gst_gl_filter_render_to_target_with_shader(&s.filter, in, out, shader);
}

fn simple(s: *Self, name: [*:0]const u8, src: [*:0]const u8) void {
    render(s, s.intexture, s.outtexture, shaderFor(s, name, src));
}

fn use(shader: ?*c.GstGLShader) ?*c.GstGLShader {
    c.gst_gl_shader_use(shader);
    return shader;
}

fn width(info: *const c.GstVideoInfo) f32 {
    return @floatFromInt(info.width);
}

fn height(info: *const c.GstVideoInfo) f32 {
    return @floatFromInt(info.height);
}

fn identity(s: *Self) void {
    const ctx = el.base(s).context;
    var shader: ?*c.GstGLShader = @ptrCast(@alignCast(c.g_hash_table_lookup(s.shaderstable, "identity0")));
    if (shader == null) {
        var err: [*c]c.GError = null;
        shader = c.gst_gl_shader_new_default(ctx, &err);
        if (shader == null) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("Failed to initialize identity shader: %s", err[0].message), null, "../ext/gl/effects/gstgleffectidentity.c", "gst_gl_effects_identity", 38);
            return;
        }
        _ = c.g_hash_table_insert(s.shaderstable, @ptrCast(@constCast("identity0")), shader);
    }
    c.gst_gl_shader_use(shader);
    render(s, s.intexture, s.outtexture, shader);
}

fn toCurve(s: *Self, rgb: bool, which: Curve, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) void {
    const ctx = el.base(s).context;
    const shader = if (rgb) shaderFor(s, "rgb_to_curve", glsl.rgbToCurve) else shaderFor(s, "luma_to_curve", glsl.lumaToCurve);
    if (shader == null) return;
    const g = gl(s);
    if (c.gst_gl_context_check_gl_version(ctx, c.GST_GL_API_OPENGL, 1, 0) != 0) {
        g.MatrixMode.?(c.GL_PROJECTION);
        g.LoadIdentity.?();
    }
    const i = @intFromEnum(which);
    if (s.curve[i] == 0) {
        g.GenTextures.?(1, &s.curve[i]);
        g.BindTexture.?(c.GL_TEXTURE_2D, s.curve[i]);
        g.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        g.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        g.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        g.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        g.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RGB, 256, 1, 0, c.GL_RGB, c.GL_UNSIGNED_BYTE, curves[i * 768 ..].ptr);
    }
    c.gst_gl_shader_use(shader);
    g.ActiveTexture.?(c.GL_TEXTURE2);
    g.BindTexture.?(c.GL_TEXTURE_2D, s.curve[i]);
    c.gst_gl_shader_set_uniform_1i(shader, "curve", 2);
    render(s, in, out, shader);
}

fn laplacian(s: *Self) void {
    const k = [9]f32{ 0, -1, 0, -1, 4, -1, 0, -1, 0 };
    const sh = use(shaderFor(s, "conv0", glsl.conv9));
    c.gst_gl_shader_set_uniform_1f(sh, "height", height(&s.filter.in_info));
    c.gst_gl_shader_set_uniform_1f(sh, "width", width(&s.filter.in_info));
    c.gst_gl_shader_set_uniform_1fv(sh, "kernel", 9, &k);
    c.gst_gl_shader_set_uniform_1i(sh, "invert", s.invert);
    render(s, s.intexture, s.outtexture, sh);
}

fn sobel(s: *Self) void {
    const m = &s.midtexture;
    render(s, s.intexture, m[0], shaderFor(s, "desat0", glsl.desaturate));
    var sh = use(shaderFor(s, "hconv0", glsl.sepSobelHconv3));
    c.gst_gl_shader_set_uniform_1f(sh, "height", height(&s.filter.out_info));
    render(s, m[0], m[1], sh);
    sh = use(shaderFor(s, "vconv0", glsl.sepSobelVconv3));
    c.gst_gl_shader_set_uniform_1f(sh, "width", width(&s.filter.out_info));
    render(s, m[1], m[0], sh);
    sh = use(shaderFor(s, "len0", glsl.sepSobelLength));
    c.gst_gl_shader_set_uniform_1i(sh, "invert", s.invert);
    render(s, m[0], s.outtexture, sh);
}

fn blur(s: *Self) void {
    if (c.g_once_init_enter(&blur_once) != 0) {
        gaussian(&blur_kernel, 7, 3);
        c.g_once_init_leave(&blur_once, 1);
    }
    var sh = use(shaderFor(s, "hconv0", glsl.hconv7));
    c.gst_gl_shader_set_uniform_1f(sh, "gauss_width", width(&s.filter.in_info));
    c.gst_gl_shader_set_uniform_1fv(sh, "kernel", 7, &blur_kernel);
    render(s, s.intexture, s.midtexture[0], sh);
    sh = use(shaderFor(s, "vconv0", glsl.vconv7));
    c.gst_gl_shader_set_uniform_1f(sh, "gauss_height", height(&s.filter.in_info));
    c.gst_gl_shader_set_uniform_1fv(sh, "kernel", 7, &blur_kernel);
    render(s, s.midtexture[0], s.outtexture, sh);
}

fn glow(s: *Self) void {
    const g = gl(s);
    const m = &s.midtexture;
    if (!glow_ready) {
        gaussian(&glow_kernel, 7, 10);
        glow_ready = true;
    }
    render(s, s.intexture, m[0], shaderFor(s, "luma_threshold", glsl.lumaThreshold));
    var sh = use(shaderFor(s, "hconv7", glsl.hconv7));
    c.gst_gl_shader_set_uniform_1fv(sh, "kernel", 7, &glow_kernel);
    c.gst_gl_shader_set_uniform_1f(sh, "gauss_width", width(&s.filter.out_info));
    render(s, m[0], m[1], sh);
    sh = use(shaderFor(s, "vconv7", glsl.vconv7));
    c.gst_gl_shader_set_uniform_1fv(sh, "kernel", 7, &glow_kernel);
    c.gst_gl_shader_set_uniform_1f(sh, "gauss_height", height(&s.filter.out_info));
    render(s, m[1], m[2], sh);
    sh = use(shaderFor(s, "sum", glsl.sum));
    g.ActiveTexture.?(c.GL_TEXTURE2);
    g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(s.intexture));
    c.gst_gl_shader_set_uniform_1f(sh, "alpha", 1);
    c.gst_gl_shader_set_uniform_1i(sh, "base", 2);
    g.ActiveTexture.?(c.GL_TEXTURE1);
    g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(m[2]));
    c.gst_gl_shader_set_uniform_1f(sh, "beta", 1.0 / 3.5);
    c.gst_gl_shader_set_uniform_1i(sh, "blend", 1);
    render(s, m[2], s.outtexture, sh);
}

fn xray(s: *Self) void {
    const g = gl(s);
    const m = &s.midtexture;
    if (!xray_ready) {
        gaussian(&xray_kernel, 7, 1.5);
        xray_ready = true;
    }
    toCurve(s, false, .xray, s.intexture, m[0]);
    var sh = use(shaderFor(s, "hconv7", glsl.hconv7));
    c.gst_gl_shader_set_uniform_1fv(sh, "kernel", 9, &xray_kernel);
    c.gst_gl_shader_set_uniform_1f(sh, "gauss_width", width(&s.filter.in_info));
    render(s, m[0], m[1], sh);
    sh = use(shaderFor(s, "vconv7", glsl.vconv7));
    c.gst_gl_shader_set_uniform_1fv(sh, "kernel", 9, &xray_kernel);
    c.gst_gl_shader_set_uniform_1f(sh, "gauss_height", height(&s.filter.out_info));
    render(s, m[1], m[2], sh);
    render(s, s.intexture, m[3], shaderFor(s, "desaturate", glsl.desaturate));
    sh = use(shaderFor(s, "sobel_hconv3", glsl.sepSobelHconv3));
    c.gst_gl_shader_set_uniform_1f(sh, "width", width(&s.filter.out_info));
    render(s, m[3], m[4], sh);
    sh = use(shaderFor(s, "sobel_vconv3", glsl.sepSobelVconv3));
    c.gst_gl_shader_set_uniform_1f(sh, "height", height(&s.filter.out_info));
    render(s, m[4], m[3], sh);
    sh = use(shaderFor(s, "sobel_length", glsl.sepSobelLength));
    c.gst_gl_shader_set_uniform_1i(sh, "invert", 1);
    render(s, m[3], m[4], sh);
    sh = use(shaderFor(s, "multiply", glsl.multiply));
    g.ActiveTexture.?(c.GL_TEXTURE2);
    g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(m[2]));
    c.gst_gl_shader_set_uniform_1i(sh, "base", 2);
    g.ActiveTexture.?(c.GL_TEXTURE1);
    g.BindTexture.?(c.GL_TEXTURE_2D, c.gst_gl_memory_get_texture_id(m[4]));
    c.gst_gl_shader_set_uniform_1f(sh, "alpha", 0.5);
    c.gst_gl_shader_set_uniform_1i(sh, "blend", 1);
    render(s, m[4], s.outtexture, sh);
}

fn run(s: *Self) void {
    switch (@as(Effect, @enumFromInt(s.current_effect))) {
        .identity => identity(s),
        .mirror => simple(s, "mirror", glsl.mirror),
        .squeeze => simple(s, "squeeze", glsl.squeeze),
        .stretch => simple(s, "stretch", glsl.stretch),
        .tunnel => simple(s, "tunnel", glsl.tunnel),
        .fisheye => simple(s, "fisheye", glsl.fisheye),
        .twirl => simple(s, "twirl", glsl.twirl),
        .bulge => simple(s, "bulge", glsl.bulge),
        .square => simple(s, "square", glsl.square),
        .heat => toCurve(s, false, .heat, s.intexture, s.outtexture),
        .sepia => toCurve(s, false, .sepia, s.intexture, s.outtexture),
        .xpro => toCurve(s, true, .xpro, s.intexture, s.outtexture),
        .lumaxpro => toCurve(s, false, .luma_xpro, s.intexture, s.outtexture),
        .xray => xray(s),
        .sin => simple(s, "sin", glsl.sin),
        .glow => glow(s),
        .sobel => sobel(s),
        .blur => blur(s),
        .laplacian => laplacian(s),
    }
}

fn setEffect(s: *Self, e: c.gint) void {
    if (e < 0 or e > @intFromEnum(Effect.laplacian)) {
        c.g_assertion_message_expr("GStreamer", FILE, 274, "gst_gl_effects_set_effect", null);
        return;
    }
    const k: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(s))).g_class));
    k.supported_gl_api = API;
    s.current_effect = e;
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    const s = me(bf);
    if (parent_gl.gl_start.?(bf) == 0) return 0;
    const alloc: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(c.gst_allocator_find(c.GST_GL_MEMORY_ALLOCATOR_NAME)));
    const params: [*c]c.GstGLAllocationParams = @ptrCast(c.gst_gl_video_allocation_params_new(bf[0].context, null, &s.filter.out_info, 0, null, c.GST_GL_TEXTURE_TARGET_2D, c.GST_GL_RGBA));
    for (&s.midtexture) |*t| {
        if (t.* != null) c.gst_memory_unref(@ptrCast(t.*));
        t.* = @ptrCast(@alignCast(c.gst_gl_base_memory_alloc(alloc, params)));
    }
    c.gst_object_unref(alloc);
    c.gst_gl_allocation_params_free(params);
    return 1;
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    const g = gl(s);
    for (s.midtexture) |t| c.gst_memory_unref(@ptrCast(t));
    for (&s.curve) |*t| {
        g.DeleteTextures.?(1, t);
        t.* = 0;
    }
    parent_gl.gl_stop.?(bf);
}

fn clean(_: c.gpointer, v: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_object_unref(v);
}

fn stop(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(bt);
    c.g_hash_table_foreach(s.shaderstable, clean, s);
    c.g_hash_table_unref(s.shaderstable);
    s.shaderstable = null;
    return parent.stop.?(bt);
}

fn start(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(bt);
    s.shaderstable = c.g_hash_table_new(c.g_str_hash, c.g_str_equal);
    s.midtexture = .{null} ** N_MID;
    s.curve = .{0} ** 5;
    return parent.start.?(bt);
}

fn initFbo(_: [*c]c.GstGLFilter) callconv(.c) c.gboolean {
    return 1;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    const s = me(f);
    s.intexture = in;
    s.outtexture = out;
    if (s.horizontal_swap == 1) {
        const ctx = el.base(s).context;
        if (c.gst_gl_context_get_gl_api(ctx) & c.GST_GL_API_OPENGL != 0) {
            const mirror = [16]f32{ -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
            gl(s).MatrixMode.?(c.GL_MODELVIEW);
            gl(s).LoadMatrixf.?(&mirror);
        }
    }
    run(s);
    return 1;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_EFFECT => setEffect(s, c.g_value_get_enum(v)),
        PROP_HSWAP => s.horizontal_swap = c.g_value_get_boolean(v),
        PROP_INVERT => s.invert = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 493),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_EFFECT => c.g_value_set_enum(v, s.current_effect),
        PROP_HSWAP => c.g_value_set_boolean(v, s.horizontal_swap),
        PROP_INVERT => c.g_value_set_boolean(v, s.invert),
        else => cm.warnInvalid(FILE, o, id, spec, 515),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const bt = el.baseTransformClass(k);
    bt.start = start;
    bt.stop = stop;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.filter_texture = filterTexture;
    fc.init_fbo = initFbo;
    @as(*Class, @ptrCast(@alignCast(k))).filter_descriptor = null;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Gstreamer OpenGL Effects", "Filter/Effect/Video", "GL Shading Language effects", "Filippo Argiolas <filippo.argiolas@gmail.com>");
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL3;
    c.gst_type_mark_as_plugin_api(effectType(), 0);
    c.gst_type_mark_as_plugin_api(getType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.horizontal_swap = 0;
    s.invert = 0;
    s.current_effect = @intFromEnum(Effect.identity);
}

fn filterClassInit(k: c.gpointer, data: c.gpointer) callconv(.c) void {
    const d: ?*const Descriptor = @ptrCast(@alignCast(data));
    @as(*Class, @ptrCast(@alignCast(k))).filter_descriptor = d;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    if (d) |desc| {
        const text = c.g_strdup_printf("GL Shading Language effects - %s", desc.filter_longname);
        c.gst_element_class_set_metadata(@ptrCast(@alignCast(k)), desc.filter_longname, "Filter/Effect/Video", text, "Filippo Argiolas <filippo.argiolas@gmail.com>");
        c.g_free(text);
    } else {
        c.g_object_class_install_property(oc, PROP_EFFECT, c.g_param_spec_enum("effect", "Effect", "Select which effect apply to GL video texture", effectType(), 0, cm.RW));
    }
    c.g_object_class_install_property(oc, PROP_HSWAP, c.g_param_spec_boolean("hswap", "Horizontal Swap", "Switch video texture left to right, useful with webcams", 0, cm.RW));
    if (d == null or d.?.supported_properties & PROP_INVERT != 0)
        c.g_object_class_install_property(oc, PROP_INVERT, c.g_param_spec_boolean("invert", "Invert the colors for sobel effect", "Invert colors to get dark edges on bright background when using sobel effect", 0, cm.RW));
}

fn filterInit(inst: [*c]c.GTypeInstance, k: c.gpointer) callconv(.c) void {
    const cls: *Class = @ptrCast(@alignCast(k));
    setEffect(me(inst), cls.filter_descriptor.?.effect);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLEffects", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("gleffects", 0, "gleffects element");
            return t;
        }
    }.f);
}

fn subtype(name: [*c]const u8, data: ?*const Descriptor) c.GType {
    const info = c.GTypeInfo{
        .class_size = @sizeOf(Class),
        .base_init = null,
        .base_finalize = null,
        .class_init = filterClassInit,
        .class_finalize = null,
        .class_data = data,
        .instance_size = @sizeOf(Self),
        .n_preallocs = 0,
        .instance_init = if (data != null) filterInit else null,
        .value_table = null,
    };
    return c.g_type_register_static(getType(), name, &info, 0);
}

pub fn register(p: ?*c.GstPlugin) bool {
    el.init();
    if (c.g_once_init_enter(&registered) != 0) {
        const generic = subtype("GstGLEffectsGeneric", null);
        if (c.gst_element_register(p, "gleffects", c.GST_RANK_NONE, generic) != 0) {
            for (&descriptors) |*d| {
                if (d.filter_name == null) break;
                const name = c.g_strdup_printf("gleffects_%s", d.filter_name);
                _ = c.gst_element_register(p, name, c.GST_RANK_NONE, subtype(name, d));
                c.g_free(name);
            }
        }
        c.g_once_init_leave(&registered, generic);
    }
    return registered != 0;
}
