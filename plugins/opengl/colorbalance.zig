const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglcolorbalance.c";
const OVERLAY = "meta:GstVideoOverlayComposition";

const P = struct {
    const CONTRAST = 1;
    const BRIGHTNESS = 2;
    const HUE = 3;
    const SATURATION = 4;
};

const GL_CAPS = "video/x-raw(memory:GLMemory), format = (string) RGBA, width = " ++ el.SIZE ++ ", height = " ++ el.SIZE ++ ", framerate = " ++ el.FPS ++ ", texture-target = (string) { 2D, external-oes }  ; video/x-raw(memory:GLMemory," ++ OVERLAY ++ "), format = (string) RGBA, width = " ++ el.SIZE ++ ", height = " ++ el.SIZE ++ ", framerate = " ++ el.FPS ++ ", texture-target = (string) { 2D, external-oes }";
const FULL_CAPS = GL_CAPS ++ " ; " ++ el.DMA_DRM_CAPS ++ " ; " ++ el.capsWithFeatures("memory:DMABuf," ++ OVERLAY, "DMA_DRM");

const EXT = "#extension GL_OES_EGL_image_external : require\n";
const SAMPLER_EXT = "uniform samplerExternalOES tex;\n";
const SAMPLER_2D = "uniform sampler2D tex;\n";
const FRAG = "uniform mat4 yuva_balance_matrix;\nuniform vec4 yuva_balance_constant;\nvarying vec2 v_texcoord;\n#define from_yuv_bt601_offset vec4(-0.0625, -0.5, -0.5, 0.0)\n#define from_yuv_coeff_mat mat4(1.164, 0.000, 1.596, 0.0,  1.164,-0.391,-0.813, 0.0,  1.164, 2.018, 0.000, 0.0, 0.0,   0.0,   0.0,   1.0)\nvoid main () {\n  vec4 rgba = texture2D (tex, v_texcoord);\n  vec4 yuva = rgba * yuva_balance_matrix + yuva_balance_constant;\n  yuva = clamp(yuva, 0.0, 1.0);\n  gl_FragColor = yuva * from_yuv_coeff_mat + from_yuv_bt601_offset * from_yuv_coeff_mat;\n}\n";

const Self = extern struct {
    filter: c.GstGLFilter,
    shader: ?*c.GstGLShader,
    contrast: f64,
    brightness: f64,
    hue: f64,
    saturation: f64,
    channels: [*c]c.GList,
    matrix: [16]f32,
    constant: [4]f32,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, FULL_CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, FULL_CAPS);
var internal = c.GstStaticCaps{ .caps = null, .string = GL_CAPS, ._gst_reserved = .{null} ** 4 };
var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;
var parent_gl: *c.GstGLBaseFilterClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn internalCaps(_: [*c]c.GstGLFilter, dir: c.GstPadDirection, caps: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    var np: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(c.gst_static_caps_get(&internal))));
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(np)) : (i += 1) c.gst_structure_remove_field(c.gst_caps_get_structure(np, i), "texture-target");
    const tmp = c.gst_caps_intersect_full(caps, np, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(np);
    np = null;
    i = 0;
    while (i < c.gst_caps_get_size(tmp)) : (i += 1) {
        const s = c.gst_caps_get_structure(tmp, i);
        if (dir == c.GST_PAD_SINK) {
            c.gst_structure_set(s, "texture-target", c.G_TYPE_STRING, c.gst_gl_texture_target_to_string(c.GST_GL_TEXTURE_TARGET_2D), @as(?*anyopaque, null));
        } else c.gst_structure_remove_field(s, "texture-target");
    }
    return tmp;
}

fn passthrough(s: *Self) bool {
    return s.contrast == 1.0 and s.brightness == 0.0 and s.hue == 0.0 and s.saturation == 1.0;
}

fn uniforms(s: *Self) void {
    const ct = s.contrast;
    const hc = s.saturation * @cos(s.hue * std.math.pi);
    const hs = s.saturation * @sin(s.hue * std.math.pi);
    const m = [16]f64{
        0.256816 * ct,                  0.504154 * ct,                 0.0979137 * ct,                 0,
        -0.148246 * hc + 0.439271 * hs, -0.29102 * hc - 0.367833 * hs, 0.439266 * hc - 0.071438 * hs,  0,
        0.148246 * hs + 0.439271 * hc,  0.29102 * hs - 0.367833 * hc,  -0.439266 * hs - 0.071438 * hc, 0,
        0,                              0,                             0,                              1,
    };
    for (m, 0..) |v, i| s.matrix[i] = @floatCast(v);
    s.constant[0] = @floatCast(0.0625 * ct + ct * ((16.0 * 219.0 / 256.0 / 256.0) / (219.0 / 256.0)) + s.brightness - (16.0 / 256.0));
    s.constant[1] = 0.5;
    s.constant[2] = 0.5;
    s.constant[3] = 0;
}

fn update(s: *Self) void {
    const bt: [*c]c.GstBaseTransform = @ptrCast(s);
    cm.lock(s);
    const pt = passthrough(s);
    uniforms(s);
    cm.unlock(s);
    const cur = c.gst_base_transform_is_passthrough(bt) != 0;
    c.gst_base_transform_set_passthrough(bt, @intFromBool(pt));
    if (cur != pt) c.gst_base_transform_reconfigure_src(bt);
}

fn createShader(s: *Self) bool {
    const bf = el.base(s);
    const f = &s.filter;
    if (s.shader != null) {
        c.gst_object_unref(s.shader);
        s.shader = null;
    }
    var frags: [4][*c]const u8 = undefined;
    var n: usize = 0;
    if (f.in_texture_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) {
        frags[n] = EXT;
        n += 1;
    }
    frags[n] = c.gst_gl_shader_string_get_highest_precision(bf.context, c.GST_GLSL_VERSION_NONE, c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY);
    n += 1;
    switch (f.in_texture_target) {
        c.GST_GL_TEXTURE_TARGET_2D => frags[n] = SAMPLER_2D,
        c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES => frags[n] = SAMPLER_EXT,
        else => return false,
    }
    n += 1;
    frags[n] = FRAG;
    n += 1;
    var err: [*c]c.GError = null;
    s.shader = c.gst_gl_shader_new_link_with_stages(bf.context, &err, c.gst_glsl_stage_new_default_vertex(bf.context), c.gst_glsl_stage_new_with_strings(bf.context, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY, @intCast(n), &frags), @as(?*anyopaque, null));
    if (s.shader == null) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Failed to initialize colorbalance shader"), c.g_strdup(if (err != null) err[0].message else "Unknown error"), FILE, "_create_shader", 340);
        c.g_clear_error(&err);
        return false;
    }
    f.draw_attr_position_loc = c.gst_gl_shader_get_attribute_location(s.shader, "a_position");
    f.draw_attr_texture_loc = c.gst_gl_shader_get_attribute_location(s.shader, "a_texcoord");
    return true;
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    if (!createShader(me(bf))) return 0;
    return parent_gl.gl_start.?(bf);
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    parent_gl.gl_stop.?(bf);
}

fn beforeTransform(bt: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) void {
    el.syncValues(bt, b);
}

fn transformMeta(bt: [*c]c.GstBaseTransform, out: [*c]c.GstBuffer, meta: [*c]c.GstMeta, in: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    if (!el.videoTagsOnly(meta, true)) return parent.transform_meta.?(bt, out, meta, in);
    return 1;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    const s = me(f);
    if (s.shader == null) _ = createShader(s);
    c.gst_gl_shader_use(s.shader);
    cm.lock(s);
    c.gst_gl_shader_set_uniform_matrix_4fv(s.shader, "yuva_balance_matrix", 1, 0, &s.matrix);
    c.gst_gl_shader_set_uniform_4fv(s.shader, "yuva_balance_constant", 1, &s.constant);
    cm.unlock(s);
    _ = c.gst_gl_filter_render_to_target_with_shader(f, in, out, s.shader);
    return 1;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    var l = s.channels;
    while (l != null) : (l = l[0].next) {
        c.g_object_unref(l[0].data);
        l[0].data = null;
    }
    if (s.channels != null) c.g_list_free(s.channels);
    parent_obj.finalize.?(o);
}

fn findChannel(s: *Self, label: [*c]const u8) [*c]c.GstColorBalanceChannel {
    var l = s.channels;
    while (l != null) : (l = l[0].next) {
        const ch: [*c]c.GstColorBalanceChannel = @ptrCast(@alignCast(l[0].data));
        if (c.g_ascii_strcasecmp(ch[0].label, label) == 0) return ch;
    }
    return null;
}

fn isSelf(b: anytype) bool {
    return c.g_type_check_instance_is_a(@ptrCast(@alignCast(b)), getType()) != 0;
}

fn listChannels(b: ?*c.GstColorBalance) callconv(.c) [*c]const c.GList {
    const f = "gst_gl_color_balance_colorbalance_list_channels";
    if (!cm.that(b != null, f, "glcolorbalance != NULL")) return null;
    if (!cm.that(isSelf(b), f, "GST_IS_GL_COLOR_BALANCE (glcolorbalance)")) return null;
    return me(b).channels;
}

fn is(label: [*c]const u8, comptime name: [:0]const u8) bool {
    return c.g_ascii_strcasecmp(label, name.ptr) == 0;
}

fn setValue(b: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel, value: c.gint) callconv(.c) void {
    const f = "gst_gl_color_balance_colorbalance_set_value";
    if (!cm.that(b != null, f, "vb != NULL")) return;
    if (!cm.that(isSelf(b), f, "GST_IS_GL_COLOR_BALANCE (vb)")) return;
    if (!cm.that(ch[0].label != null, f, "channel->label != NULL")) return;
    const s = me(b);
    const v: f64 = @floatFromInt(value);
    var changed = false;
    cm.lock(s);
    const slot: ?*f64 = if (is(ch[0].label, "HUE")) &s.hue else if (is(ch[0].label, "SATURATION")) &s.saturation else if (is(ch[0].label, "BRIGHTNESS")) &s.brightness else if (is(ch[0].label, "CONTRAST")) &s.contrast else null;
    if (slot) |x| {
        const centered = is(ch[0].label, "HUE") or is(ch[0].label, "BRIGHTNESS");
        const nv = (v + 1000.0) * 2.0 / 2000.0 - @as(f64, if (centered) 1.0 else 0.0);
        changed = nv != x.*;
        x.* = nv;
    }
    cm.unlock(s);
    if (changed) {
        update(s);
        c.gst_color_balance_value_changed(b, ch, c.gst_color_balance_get_value(b, ch));
    }
}

fn getValue(b: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel) callconv(.c) c.gint {
    const f = "gst_gl_color_balance_colorbalance_get_value";
    if (!cm.that(b != null, f, "vb != NULL")) return 0;
    if (!cm.that(isSelf(b), f, "GST_IS_GL_COLOR_BALANCE (vb)")) return 0;
    if (!cm.that(ch[0].label != null, f, "channel->label != NULL")) return 0;
    const s = me(b);
    const l = ch[0].label;
    const v: f64 = if (is(l, "HUE")) (s.hue + 1) * 2000.0 / 2.0 - 1000.0 else if (is(l, "SATURATION")) s.saturation * 2000.0 / 2.0 - 1000.0 else if (is(l, "BRIGHTNESS")) (s.brightness + 1) * 2000.0 / 2.0 - 1000.0 else if (is(l, "CONTRAST")) s.contrast * 2000.0 / 2.0 - 1000.0 else 0;
    return @intFromFloat(v);
}

fn balanceType(_: ?*c.GstColorBalance) callconv(.c) c.GstColorBalanceType {
    return c.GST_COLOR_BALANCE_HARDWARE;
}

fn balanceInit(i: c.gpointer, _: c.gpointer) callconv(.c) void {
    const f: *c.GstColorBalanceInterface = @ptrCast(@alignCast(i));
    f.list_channels = listChannels;
    f.set_value = setValue;
    f.get_value = getValue;
    f.get_balance_type = balanceType;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    var label: ?[*:0]const u8 = null;
    cm.lock(s);
    switch (id) {
        P.CONTRAST, P.BRIGHTNESS, P.HUE, P.SATURATION => {
            const d = c.g_value_get_double(v);
            const slot = switch (id) {
                P.CONTRAST => &s.contrast,
                P.BRIGHTNESS => &s.brightness,
                P.HUE => &s.hue,
                else => &s.saturation,
            };
            if (d != slot.*) label = switch (id) {
                P.CONTRAST => "CONTRAST",
                P.BRIGHTNESS => "BRIGHTNESS",
                P.HUE => "HUE",
                else => "SATURATION",
            };
            slot.* = d;
        },
        else => cm.warnInvalid(FILE, o, id, spec, 702),
    }
    cm.unlock(s);
    update(s);
    if (label) |l| {
        const ch = findChannel(s, l);
        c.gst_color_balance_value_changed(@ptrCast(s), ch, c.gst_color_balance_get_value(@ptrCast(s), ch));
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        P.CONTRAST => c.g_value_set_double(v, s.contrast),
        P.BRIGHTNESS => c.g_value_set_double(v, s.brightness),
        P.HUE => c.g_value_set_double(v, s.hue),
        P.SATURATION => c.g_value_set_double(v, s.saturation),
        else => cm.warnInvalid(FILE, o, id, spec, 737),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    _ = c._gst_debug_category_new("glcolorbalance", 0, "glcolorbalance");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const CTL = c.GST_PARAM_CONTROLLABLE | cm.RW;
    const i = c.g_object_class_install_property;
    i(oc, P.CONTRAST, c.g_param_spec_double("contrast", "Contrast", "contrast", 0.0, 2.0, 1.0, CTL));
    i(oc, P.BRIGHTNESS, c.g_param_spec_double("brightness", "Brightness", "brightness", -1.0, 1.0, 0.0, CTL));
    i(oc, P.HUE, c.g_param_spec_double("hue", "Hue", "hue", -1.0, 1.0, 0.0, CTL));
    i(oc, P.SATURATION, c.g_param_spec_double("saturation", "Saturation", "saturation", 0.0, 2.0, 1.0, CTL));
    c.gst_element_class_set_static_metadata(ec, "Video balance", "Filter/Effect/Video", "Adjusts brightness, contrast, hue, saturation on a video stream", "Matthew Waters <matthew@centricular.com>");
    const bt = el.baseTransformClass(k);
    bt.before_transform = beforeTransform;
    bt.transform_ip_on_passthrough = 0;
    bt.transform_meta = transformMeta;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.filter_texture = filterTexture;
    fc.transform_internal_caps = internalCaps;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.contrast = 1.0;
    s.brightness = 0.0;
    s.hue = 0.0;
    s.saturation = 1.0;
    update(s);
    for ([_][*:0]const u8{ "HUE", "SATURATION", "BRIGHTNESS", "CONTRAST" }) |n| {
        const ch: [*c]c.GstColorBalanceChannel = @ptrCast(@alignCast(c.g_object_new(c.gst_color_balance_channel_get_type(), null)));
        ch[0].label = c.g_strdup(n);
        ch[0].min_value = -1000;
        ch[0].max_value = 1000;
        s.channels = c.g_list_append(s.channels, ch);
    }
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLColorBalance", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = balanceInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_color_balance_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glcolorbalance", c.GST_RANK_NONE, getType());
}
