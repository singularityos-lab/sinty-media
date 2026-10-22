const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");
const bin = @import("mixerbin.zig");
const layout = @import("../padlayout.zig");

const FILE = "../ext/gl/gstglvideomixer.c";
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;
const CTL = cm.RW | c.GST_PARAM_CONTROLLABLE;
const PROP_BACKGROUND = 1;

const MIX_FRAG = "uniform sampler2D texture;                     \nuniform float alpha;\nvarying vec2 v_texcoord;                            \nvoid main()                                         \n{                                                   \n  vec4 rgba = texture2D(texture, v_texcoord);\n  gl_FragColor = vec4(rgba.rgb, rgba.a * alpha);\n}                                                   \n";
const CHECKER_VERT = "attribute vec4 a_position;\nvoid main()\n{\n   gl_Position = a_position;\n}\n";
const CHECKER_FRAG = "const float blocksize = 8.0;\nvoid main ()\n{\n  vec4 high = vec4(0.667, 0.667, 0.667, 1.0);\n  vec4 low = vec4(0.333, 0.333, 0.333, 1.0);\n  if (mod(gl_FragCoord.x, blocksize * 2.0) >= blocksize) {\n    if (mod(gl_FragCoord.y, blocksize * 2.0) >= blocksize)\n      gl_FragColor = low;\n    else\n      gl_FragColor = high;\n  } else {\n    if (mod(gl_FragCoord.y, blocksize * 2.0) < blocksize)\n      gl_FragColor = low;\n    else\n      gl_FragColor = high;\n  }\n}\n";

const P = enum(c.guint) { xpos = 1, ypos, width, height, alpha, eq_rgb, eq_alpha, src_rgb, src_alpha, dst_rgb, dst_alpha, red, green, blue, const_alpha, zorder, repeat_after_eos, crop_left, crop_right, crop_top, crop_bottom, sizing_policy, xalign, yalign };

const Background = enum(c.gint) { checker, black, white, transparent };

const SATURATE = 14;

const Pad = extern struct {
    parent: el.MixerPad,
    xpos: c.gint,
    ypos: c.gint,
    width: c.gint,
    height: c.gint,
    xalign: f64,
    yalign: f64,
    alpha: f64,
    sizing_policy: c.gint,
    blend_equation_rgb: c.gint,
    blend_equation_alpha: c.gint,
    blend_function_src_rgb: c.gint,
    blend_function_src_alpha: c.gint,
    blend_function_dst_rgb: c.gint,
    blend_function_dst_alpha: c.gint,
    blend_constant_color_red: f64,
    blend_constant_color_green: f64,
    blend_constant_color_blue: f64,
    blend_constant_color_alpha: f64,
    crop_left: c.gint,
    crop_right: c.gint,
    crop_top: c.gint,
    crop_bottom: c.gint,
    geometry_change: c.gboolean,
    vertex_buffer: c.GLuint,
    m_matrix: [16]f32,
    copy_meta: c.gboolean,
};

const PadClass = extern struct {
    parent: c.GstGLMixerPadClass,
};

const Input = extern struct {
    pad: layout.Pad,
    proxy_priv: c.gpointer,
    ghost_priv: c.gpointer,
    segment: c.GstSegment,
    mixer_pad: ?*c.GstPad,
};

const Self = extern struct {
    mixer: c.GstGLMixer,
    background: c.gint,
    shader: ?*c.GstGLShader,
    checker: ?*c.GstGLShader,
    vao: c.guint,
    vbo_indices: c.guint,
    checker_vbo: c.guint,
    out_tex: [*c]c.GstGLMemory,
    output_geo_change: c.gboolean,
};

const Class = extern struct {
    parent: c.GstGLMixerClass,
};

const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, el.capsWithFeatures("memory:GLMemory", "RGBA"));
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var input_once: cm.Once = .{};
var bin_once: cm.Once = .{};
var bg_once: cm.Once = .{};
var eq_once: cm.Once = .{};
var fn_once: cm.Once = .{};
var sizing_once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_agg: *c.GstAggregatorClass = undefined;
var parent_vagg: *c.GstVideoAggregatorClass = undefined;
var parent_bm: *c.GstGLBaseMixerClass = undefined;
var parent_input: *c.GObjectClass = undefined;
var parent_bin: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn padOf(p: anytype) *Pad {
    return @ptrCast(@alignCast(p));
}

fn ctxOf(s: *Self) [*c]c.GstGLContext {
    return @as(*c.GstGLBaseMixer, @ptrCast(@alignCast(s))).context;
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(ctxOf(s)[0].gl_vtable));
}

fn vinfo(s: *Self) *c.GstVideoInfo {
    return &@as(*c.GstVideoAggregator, @ptrCast(@alignCast(s))).info;
}

fn enumType(o: *cm.Once, comptime name: [:0]const u8, comptime vals: []const [2][:0]const u8) c.GType {
    const S = struct {
        var values = blk: {
            var v: [vals.len + 1]c.GEnumValue = undefined;
            for (vals, 0..) |x, i| v[i] = .{ .value = @intCast(i), .value_name = x[0], .value_nick = x[1] };
            v[vals.len] = .{ .value = 0, .value_name = null, .value_nick = null };
            break :blk v;
        };
        fn f() c.GType {
            return c.g_enum_register_static(name, &values);
        }
    };
    return o.get(S.f);
}

fn backgroundType() c.GType {
    return enumType(&bg_once, "GstGLVideoMixerBackground", &.{ .{ "Checker pattern", "checker" }, .{ "Black", "black" }, .{ "White", "white" }, .{ "Transparent Background to enable further compositing", "transparent" } });
}

fn equationType() c.GType {
    return enumType(&eq_once, "GstGLVideoMixerBlendEquation", &.{ .{ "Add", "add" }, .{ "Subtract", "subtract" }, .{ "Reverse Subtract", "reverse-subtract" } });
}

fn functionType() c.GType {
    return enumType(&fn_once, "GstGLVideoMixerBlendFunction", &.{
        .{ "Zero", "zero" },
        .{ "One", "one" },
        .{ "Source Color", "src-color" },
        .{ "One Minus Source Color", "one-minus-src-color" },
        .{ "Destination Color", "dst-color" },
        .{ "One Minus Destination Color", "one-minus-dst-color" },
        .{ "Source Alpha", "src-alpha" },
        .{ "One Minus Source Alpha", "one-minus-src-alpha" },
        .{ "Destination Alpha", "dst-alpha" },
        .{ "One Minus Destination Alpha", "one-minus-dst-alpha" },
        .{ "Constant Color", "constant-color" },
        .{ "One Minus Constant Color", "one-minus-contant-color" },
        .{ "Constant Alpha", "constant-alpha" },
        .{ "One Minus Constant Alpha", "one-minus-contant-alpha" },
        .{ "Source Alpha Saturate", "src-alpha-saturate" },
    });
}

fn sizingType() c.GType {
    return enumType(&sizing_once, "GstGLVideoMixerSizingPolicy", &.{
        .{ "None: Image is scaled to fill configured destination rectangle without padding or keeping the aspect ratio", "none" },
        .{ "Keep Aspect Ratio: Image is scaled to fit destination rectangle specified by GstGLVideoMixerPad:{xpos, ypos, width, height} with preserved aspect ratio. The empty space of the resulting image will be distributed in the destination rectangle according to the GstGLVideoMixerPad:{xalign, yalign} values", "keep-aspect-ratio" },
    });
}

fn install(oc: *c.GObjectClass, id: P, spec: [*c]c.GParamSpec) void {
    c.g_object_class_install_property(oc, @intFromEnum(id), spec);
}

fn installPadProps(oc: *c.GObjectClass, input: bool) void {
    const maxi = std.math.maxInt(c.gint);
    const mini = std.math.minInt(c.gint);
    if (input) {
        install(oc, .zorder, c.g_param_spec_uint("zorder", "Z-Order", "Z Order of the picture", 0, 10000, 0, CTL));
        install(oc, .repeat_after_eos, c.g_param_spec_boolean("repeat-after-eos", "Repeat After EOS", "Aggregate the last frame on pads that are EOS till they are released", 0, CTL));
    }
    install(oc, .xpos, c.g_param_spec_int("xpos", "X Position", "X Position of the picture", mini, maxi, 0, CTL));
    install(oc, .ypos, c.g_param_spec_int("ypos", "Y Position", "Y Position of the picture", mini, maxi, 0, CTL));
    install(oc, .width, c.g_param_spec_int("width", "Width", "Width of the picture", mini, maxi, 0, CTL));
    install(oc, .height, c.g_param_spec_int("height", "Height", "Height of the picture", mini, maxi, 0, CTL));
    install(oc, .alpha, c.g_param_spec_double("alpha", "Alpha", "Alpha of the picture", 0, 1, 1, CTL));
    install(oc, .eq_rgb, c.g_param_spec_enum("blend-equation-rgb", "Blend Equation RGB", "Blend Equation for RGB", equationType(), 0, CTL));
    install(oc, .eq_alpha, c.g_param_spec_enum("blend-equation-alpha", "Blend Equation Alpha", "Blend Equation for Alpha", equationType(), 0, CTL));
    install(oc, .src_rgb, c.g_param_spec_enum("blend-function-src-rgb", "Blend Function Source RGB", "Blend Function for Source RGB", functionType(), 6, CTL));
    install(oc, .src_alpha, c.g_param_spec_enum("blend-function-src-alpha", "Blend Function Source Alpha", "Blend Function for Source Alpha", functionType(), 1, CTL));
    install(oc, .dst_rgb, c.g_param_spec_enum("blend-function-dst-rgb", "Blend Function Destination RGB", "Blend Function for Destination RGB", functionType(), 7, CTL));
    install(oc, .dst_alpha, c.g_param_spec_enum("blend-function-dst-alpha", "Blend Function Destination Alpha", "Blend Function for Destination Alpha", functionType(), 7, CTL));
    install(oc, .red, c.g_param_spec_double("blend-constant-color-red", "Blend Constant Color Red", "Blend Constant Color Red", 0, 1, 0, CTL));
    install(oc, .green, c.g_param_spec_double("blend-constant-color-green", "Blend Constant Color Green", "Blend Constant Color Green", 0, 1, 0, CTL));
    install(oc, .blue, c.g_param_spec_double("blend-constant-color-blue", "Blend Constant Color Green", "Blend Constant Color Green", 0, 1, 0, CTL));
    install(oc, .const_alpha, c.g_param_spec_double("blend-constant-color-alpha", "Blend Constant Color Alpha", "Blend Constant Color Alpha", 0, 1, 0, CTL));
    install(oc, .crop_left, c.g_param_spec_int("crop-left", "Crop Left", "Crop left of the picture", 0, maxi, 0, CTL));
    install(oc, .crop_right, c.g_param_spec_int("crop-right", "Crop Right", "Crop right of the picture", 0, maxi, 0, CTL));
    install(oc, .crop_top, c.g_param_spec_int("crop-top", "Crop Top", "Crop top of the picture", 0, maxi, 0, CTL));
    install(oc, .crop_bottom, c.g_param_spec_int("crop-bottom", "Crop Bottom", "Crop bottom of the picture", 0, maxi, 0, CTL));
    install(oc, .sizing_policy, c.g_param_spec_enum("sizing-policy", "Sizing policy", "Sizing policy to use for image scaling", sizingType(), 0, CTL));
    install(oc, .xalign, c.g_param_spec_double("xalign", "X alignment", "X alignment of the picture", 0, 1, 0.5, CTL));
    install(oc, .yalign, c.g_param_spec_double("yalign", "Y alignment", "Y alignment of the picture", 0, 1, 0.5, CTL));
}

fn inputGet(o: [*c]c.GObject, _: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const i: *Input = @ptrCast(@alignCast(o));
    if (i.mixer_pad != null) c.g_object_get_property(@ptrCast(@alignCast(i.mixer_pad)), spec[0].name, v);
}

fn inputSet(o: [*c]c.GObject, _: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const i: *Input = @ptrCast(@alignCast(o));
    if (i.mixer_pad != null) c.g_object_set_property(@ptrCast(@alignCast(i.mixer_pad)), spec[0].name, v);
}

fn inputDispose(o: [*c]c.GObject) callconv(.c) void {
    const i: *Input = @ptrCast(@alignCast(o));
    if (i.mixer_pad != null) c.gst_object_unref(i.mixer_pad);
    i.mixer_pad = null;
    parent_input.dispose.?(o);
}

fn inputClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_input = el.parentOf(c.GObjectClass, k);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = inputSet;
    oc.get_property = inputGet;
    oc.dispose = inputDispose;
    installPadProps(oc, true);
}

fn inputType() c.GType {
    return input_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_ghost_pad_get_type(), "GstGLVideoMixerInput", c.GstGhostPadClass, Input, inputClassInit, null);
        }
    }.f);
}

const bound = [_][*:0]const u8{ "zorder", "xpos", "ypos", "width", "height", "alpha", "blend-equation-rgb", "blend-equation-alpha", "blend-function-src-rgb", "blend-function-src-alpha", "blend-function-dst-rgb", "blend-function-dst-alpha", "blend-constant-color-red", "blend-constant-color-green", "blend-constant-color-blue", "blend-constant-color-alpha", "sizing-policy", "xalign", "yalign" };

fn createInput(_: *bin.Self, mixer_pad: ?*c.GstPad) callconv(.c) ?*c.GstGhostPad {
    const input: *Input = @ptrCast(@alignCast(c.g_object_new(inputType(), "name", el.padName(mixer_pad), "direction", @as(c.gint, @bitCast(@as(*layout.Pad, @ptrCast(@alignCast(mixer_pad))).direction)), @as(?*anyopaque, null))));
    for (bound) |prop| _ = c.gst_object_add_control_binding(@ptrCast(@alignCast(mixer_pad)), c.gst_proxy_control_binding_new(@ptrCast(@alignCast(mixer_pad)), prop, @ptrCast(input), prop));
    input.mixer_pad = @ptrCast(@alignCast(c.gst_object_ref(mixer_pad)));
    return @ptrCast(input);
}

fn binConstructed(o: [*c]c.GObject) callconv(.c) void {
    if (parent_bin.constructed) |f| f(o);
    const b: *bin.Self = @ptrCast(@alignCast(o));
    const m = c.g_object_new(getType(), "force-live", b.force_live, "latency", b.latency, "start-time-selection", b.start_time_selection, "start-time", b.start_time, "min-upstream-latency", b.min_upstream_latency, @as(?*anyopaque, null));
    bin.finishInitWith(b, @ptrCast(@alignCast(m)));
}

fn binGet(o: [*c]c.GObject, _: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const b: *bin.Self = @ptrCast(@alignCast(o));
    if (b.mixer != null) c.g_object_get_property(@ptrCast(b.mixer), spec[0].name, v);
}

fn binSet(o: [*c]c.GObject, _: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const b: *bin.Self = @ptrCast(@alignCast(o));
    if (b.mixer != null) c.g_object_set_property(@ptrCast(b.mixer), spec[0].name, v);
}

fn binClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_bin = el.parentOf(c.GObjectClass, k);
    const mc: *bin.Class = @ptrCast(@alignCast(k));
    mc.create_input_pad = createInput;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.constructed = binConstructed;
    oc.set_property = binSet;
    oc.get_property = binGet;
    c.g_object_class_install_property(oc, PROP_BACKGROUND, c.g_param_spec_enum("background", "Background", "Background type", backgroundType(), 0, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const caps = c.gst_gl_upload_get_input_template_caps();
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new_with_gtype("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, caps, inputType()));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(ec, "OpenGL video_mixer bin", "Bin/Filter/Effect/Video/Compositor", "OpenGL video_mixer bin", "Matthew Waters <matthew@centricular.com>");
    c.gst_type_mark_as_plugin_api(inputType(), 0);
}

fn binType() c.GType {
    return bin_once.get(struct {
        fn f() c.GType {
            return cm.register(bin.getType(), "GstGLVideoMixerBin", bin.Class, bin.Self, binClassInit, null);
        }
    }.f);
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = padOf(inst);
    p.alpha = 1;
    p.blend_function_src_rgb = 6;
    p.blend_function_src_alpha = 1;
    p.blend_function_dst_rgb = 7;
    p.blend_function_dst_alpha = 7;
    p.xalign = 0.5;
    p.yalign = 0.5;
    p.m_matrix = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}

fn padGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = padOf(o);
    switch (id) {
        @intFromEnum(P.xpos) => c.g_value_set_int(v, p.xpos),
        @intFromEnum(P.ypos) => c.g_value_set_int(v, p.ypos),
        @intFromEnum(P.width) => c.g_value_set_int(v, p.width),
        @intFromEnum(P.height) => c.g_value_set_int(v, p.height),
        @intFromEnum(P.alpha) => c.g_value_set_double(v, p.alpha),
        @intFromEnum(P.eq_rgb) => c.g_value_set_enum(v, p.blend_equation_rgb),
        @intFromEnum(P.eq_alpha) => c.g_value_set_enum(v, p.blend_equation_alpha),
        @intFromEnum(P.src_rgb) => c.g_value_set_enum(v, p.blend_function_src_rgb),
        @intFromEnum(P.src_alpha) => c.g_value_set_enum(v, p.blend_function_src_alpha),
        @intFromEnum(P.dst_rgb) => c.g_value_set_enum(v, p.blend_function_dst_rgb),
        @intFromEnum(P.dst_alpha) => c.g_value_set_enum(v, p.blend_function_dst_alpha),
        @intFromEnum(P.red) => c.g_value_set_double(v, p.blend_constant_color_red),
        @intFromEnum(P.green) => c.g_value_set_double(v, p.blend_constant_color_green),
        @intFromEnum(P.blue) => c.g_value_set_double(v, p.blend_constant_color_blue),
        @intFromEnum(P.const_alpha) => c.g_value_set_double(v, p.blend_constant_color_alpha),
        @intFromEnum(P.crop_left) => c.g_value_set_int(v, p.crop_left),
        @intFromEnum(P.crop_right) => c.g_value_set_int(v, p.crop_right),
        @intFromEnum(P.crop_top) => c.g_value_set_int(v, p.crop_top),
        @intFromEnum(P.crop_bottom) => c.g_value_set_int(v, p.crop_bottom),
        @intFromEnum(P.sizing_policy) => c.g_value_set_enum(v, p.sizing_policy),
        @intFromEnum(P.xalign) => c.g_value_set_double(v, p.xalign),
        @intFromEnum(P.yalign) => c.g_value_set_double(v, p.yalign),
        else => cm.warnInvalid(FILE, o, id, spec, 1115),
    }
}

fn setInt(field: *c.gint, v: [*c]const c.GValue, change: *c.gboolean) void {
    const n = c.g_value_get_int(v);
    if (n != field.*) change.* = 1;
    field.* = n;
}

fn setAlign(field: *f64, v: [*c]const c.GValue, change: *c.gboolean) void {
    const n = c.g_value_get_double(v);
    const d = if (n > field.*) n - field.* else field.* - n;
    if (!(d < std.math.floatEps(f64))) change.* = 1;
    field.* = n;
}

fn padSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = padOf(o);
    const mix = c.gst_object_get_parent(@as(*c.GstObject, @ptrCast(@alignCast(p))));
    cm.lock(p);
    const ch = &p.geometry_change;
    switch (id) {
        @intFromEnum(P.xpos) => setInt(&p.xpos, v, ch),
        @intFromEnum(P.ypos) => setInt(&p.ypos, v, ch),
        @intFromEnum(P.width) => setInt(&p.width, v, ch),
        @intFromEnum(P.height) => setInt(&p.height, v, ch),
        @intFromEnum(P.alpha) => p.alpha = c.g_value_get_double(v),
        @intFromEnum(P.eq_rgb) => p.blend_equation_rgb = c.g_value_get_enum(v),
        @intFromEnum(P.eq_alpha) => p.blend_equation_alpha = c.g_value_get_enum(v),
        @intFromEnum(P.src_rgb) => p.blend_function_src_rgb = c.g_value_get_enum(v),
        @intFromEnum(P.src_alpha) => p.blend_function_src_alpha = c.g_value_get_enum(v),
        @intFromEnum(P.dst_rgb) => p.blend_function_dst_rgb = c.g_value_get_enum(v),
        @intFromEnum(P.dst_alpha) => p.blend_function_dst_alpha = c.g_value_get_enum(v),
        @intFromEnum(P.red) => p.blend_constant_color_red = c.g_value_get_double(v),
        @intFromEnum(P.green) => p.blend_constant_color_green = c.g_value_get_double(v),
        @intFromEnum(P.blue) => p.blend_constant_color_blue = c.g_value_get_double(v),
        @intFromEnum(P.const_alpha) => p.blend_constant_color_alpha = c.g_value_get_double(v),
        @intFromEnum(P.crop_left) => setInt(&p.crop_left, v, ch),
        @intFromEnum(P.crop_right) => setInt(&p.crop_right, v, ch),
        @intFromEnum(P.crop_top) => setInt(&p.crop_top, v, ch),
        @intFromEnum(P.crop_bottom) => setInt(&p.crop_bottom, v, ch),
        @intFromEnum(P.sizing_policy) => {
            const n = c.g_value_get_enum(v);
            if (n != p.sizing_policy) ch.* = 1;
            p.sizing_policy = n;
        },
        @intFromEnum(P.xalign) => setAlign(&p.xalign, v, ch),
        @intFromEnum(P.yalign) => setAlign(&p.yalign, v, ch),
        else => cm.warnInvalid(FILE, o, id, spec, 1229),
    }
    cm.unlock(p);
    c.gst_object_unref(mix);
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = padSet;
    oc.get_property = padGet;
    installPadProps(oc, false);
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_gl_mixer_pad_get_type(), "GstGLVideoMixerPad", PadClass, Pad, padClassInit, padInit);
        }
    }.f);
}

fn delBuffer(ctx: [*c]c.GstGLContext, data: c.gpointer) callconv(.c) void {
    const g: *c.GstGLFuncs = @ptrCast(@alignCast(ctx[0].gl_vtable));
    g.DeleteBuffers.?(1, @ptrCast(@alignCast(data)));
}

fn requestPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, caps: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    return el.requestPadAnnounced(parent_el, e, templ, name, caps);
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const p = padOf(pad);
    c.gst_child_proxy_child_removed(@ptrCast(e), @ptrCast(@alignCast(pad)), el.padName(pad));
    _ = c.gst_object_ref(pad);
    parent_el.release_pad.?(e, pad);
    if (p.vertex_buffer != 0) {
        c.gst_gl_context_thread_add(ctxOf(me(e)), delBuffer, &p.vertex_buffer);
        p.vertex_buffer = 0;
    }
    c.gst_object_unref(pad);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_BACKGROUND) me(o).background = c.g_value_get_enum(v) else cm.warnInvalid(FILE, o, id, spec, 1364);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_BACKGROUND) c.g_value_set_enum(v, me(o).background) else cm.warnInvalid(FILE, o, id, spec, 1380);
}

fn proposeAllocation(agg: [*c]c.GstAggregator, pad: ?*c.GstAggregatorPad, decide: [*c]c.GstQuery, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (parent_agg.propose_allocation.?(agg, pad, decide, q) == 0) return 0;
    c.gst_query_add_allocation_meta(q, c.gst_video_affine_transformation_meta_api_get_type(), null);
    return 1;
}

fn alignRect(src: *const c.GstVideoRectangle, dst: *const c.GstVideoRectangle, res: *c.GstVideoRectangle, xa: f64, ya: f64) void {
    if (!cm.that(src.h != 0, "align_rect", "src->h != 0")) return;
    if (!cm.that(dst.h != 0, "align_rect", "dst->h != 0")) return;
    const sr = @as(f64, @floatFromInt(src.w)) / @as(f64, @floatFromInt(src.h));
    const dr = @as(f64, @floatFromInt(dst.w)) / @as(f64, @floatFromInt(dst.h));
    if (sr > dr) {
        res.w = dst.w;
        res.h = @intFromFloat(@as(f64, @floatFromInt(dst.w)) / sr);
        res.x = dst.x;
        res.y = @intFromFloat(@as(f64, @floatFromInt(dst.y)) + @as(f64, @floatFromInt(dst.h - res.h)) * ya);
    } else if (sr < dr) {
        res.w = @intFromFloat(@as(f64, @floatFromInt(dst.h)) * sr);
        res.h = dst.h;
        res.x = @intFromFloat(@as(f64, @floatFromInt(dst.x)) + @as(f64, @floatFromInt(dst.w - res.w)) * xa);
        res.y = dst.y;
    } else res.* = dst.*;
}

fn scaleInt(v: c.gint, n: c.guint, d: c.guint) c.gint {
    return @truncate(@as(i64, @bitCast(c.gst_util_uint64_scale_int(@bitCast(@as(i64, v)), @bitCast(n), @bitCast(d)))));
}

const Size = struct { w: c.gint = 0, h: c.gint = 0, x: c.gint = 0, y: c.gint = 0 };

fn outputSize(p: *Pad, par_n: c.gint, par_d: c.gint) Size {
    const info = &p.parent.parent.info;
    var r = Size{};
    if (info.finfo == null or info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) return r;
    var pw: c.gint = undefined;
    var ph: c.gint = undefined;
    if (p.width <= 0) {
        const crop = p.crop_left + p.crop_right;
        pw = if (info.width > crop) info.width - crop else 0;
    } else pw = p.width;
    if (p.height <= 0) {
        const crop = p.crop_top + p.crop_bottom;
        ph = if (info.height > crop) info.height - crop else 0;
    } else ph = p.height;
    var dn: c.guint = 0;
    var dd: c.guint = 0;
    if (c.gst_video_calculate_display_ratio(&dn, &dd, @bitCast(pw), @bitCast(ph), @bitCast(info.par_n), @bitCast(info.par_d), @bitCast(par_n), @bitCast(par_d)) == 0) return r;
    if (p.sizing_policy == 0) {
        if (@as(c.guint, @bitCast(ph)) % dn == 0) {
            pw = scaleInt(ph, dn, dd);
        } else if (@as(c.guint, @bitCast(pw)) % dd == 0) {
            ph = scaleInt(pw, dd, dn);
        } else pw = scaleInt(ph, dn, dd);
    } else if (p.sizing_policy == 1) {
        var fn_: c.gint = undefined;
        var fd: c.gint = undefined;
        var tn: c.gint = undefined;
        var td: c.gint = undefined;
        var num: c.gint = undefined;
        var den: c.gint = undefined;
        if (c.gst_util_fraction_multiply(info.width, info.height, info.par_n, info.par_d, &fn_, &fd) == 0) {
            fn_ = -1;
            fd = -1;
        }
        if (c.gst_util_fraction_multiply(pw, ph, par_n, par_d, &tn, &td) == 0) {
            tn = -1;
            td = -1;
        }
        if (fn_ != tn or fd != td) {
            if (fn_ != -1 and fd != -1 and c.gst_util_fraction_multiply(fn_, fd, par_d, par_n, &num, &den) != 0) {
                var src = c.GstVideoRectangle{ .x = 0, .y = 0, .w = pw, .h = scaleInt(pw, @bitCast(den), @bitCast(num)) };
                if (src.h == 0) {
                    pw = 0;
                    ph = 0;
                } else {
                    const dst = c.GstVideoRectangle{ .x = 0, .y = 0, .w = pw, .h = ph };
                    var rst = c.GstVideoRectangle{ .x = 0, .y = 0, .w = 0, .h = 0 };
                    alignRect(&src, &dst, &rst, p.xalign, p.yalign);
                    r.x = rst.x;
                    r.y = rst.y;
                    pw = rst.w;
                    ph = rst.h;
                }
            } else {
                r.x = 0;
                r.y = 0;
                pw = 0;
                ph = 0;
            }
        }
    }
    r.w = pw;
    r.h = ph;
    return r;
}

fn sinkpads(s: *Self) [*c]c.GList {
    return @as(*c.GstElement, @ptrCast(@alignCast(s))).sinkpads;
}

fn updateCaps(vagg: [*c]c.GstVideoAggregator, caps: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(vagg);
    cm.lock(s);
    var l = sinkpads(s);
    while (l != null) : (l = l[0].next) {
        const info = &padOf(l[0].data).parent.parent.info;
        if (info.finfo == null or info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) continue;
        const mode = info.ABI.abi.multiview_mode;
        if (mode != c.GST_VIDEO_MULTIVIEW_MODE_NONE and mode != c.GST_VIDEO_MULTIVIEW_MODE_MONO) {
            cm.unlock(s);
            return null;
        }
    }
    cm.unlock(s);
    const templ = c.gst_pad_get_pad_template_caps(@as(*c.GstAggregator, @ptrCast(@alignCast(s))).srcpad);
    return c.gst_caps_intersect(caps, templ);
}

fn fixateCaps(agg: [*c]c.GstAggregator, caps: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(agg);
    var bw: c.gint = 0;
    var bh: c.gint = 0;
    var bn: c.gint = 0;
    var bd: c.gint = 0;
    var best: f64 = 0;
    const ret: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps)));
    var st = c.gst_caps_get_structure(ret, 0);
    if (c.gst_structure_has_field(st, "pixel-aspect-ratio") == 0) c.gst_structure_set(st, "pixel-aspect-ratio", c.gst_fraction_get_type(), @as(c.gint, 1), @as(c.gint, 1), @as(?*anyopaque, null));
    _ = c.gst_structure_fixate_field_nearest_fraction(st, "pixel-aspect-ratio", 1, 1);
    var pn: c.gint = 0;
    var pd: c.gint = 0;
    _ = c.gst_structure_get_fraction(st, "pixel-aspect-ratio", &pn, &pd);
    cm.lock(s);
    var l = sinkpads(s);
    while (l != null) : (l = l[0].next) {
        const p = padOf(l[0].data);
        const info = &p.parent.parent.info;
        const z = outputSize(p, pn, pd);
        if (z.w == 0 or z.h == 0) continue;
        const tw = z.w + @max(p.xpos + z.x, 0);
        const th = z.h + @max(p.ypos + z.y, 0);
        if (bw < tw) bw = tw;
        if (bh < th) bh = th;
        var cur: f64 = 0;
        if (info.fps_d != 0) c.gst_util_fraction_to_double(info.fps_n, info.fps_d, &cur);
        if (best < cur) {
            best = cur;
            bn = info.fps_n;
            bd = info.fps_d;
        }
    }
    cm.unlock(s);
    if (bn <= 0 or bd <= 0 or best == 0) {
        bn = 25;
        bd = 1;
    }
    st = c.gst_caps_get_structure(ret, 0);
    _ = c.gst_structure_fixate_field_nearest_int(st, "width", bw);
    _ = c.gst_structure_fixate_field_nearest_int(st, "height", bh);
    _ = c.gst_structure_fixate_field_nearest_fraction(st, "framerate", bn, bd);
    return c.gst_caps_fixate(ret);
}

fn resetPad(_: [*c]c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const p = padOf(pad);
    if (p.vertex_buffer != 0) gl(s).DeleteBuffers.?(1, &p.vertex_buffer);
    p.vertex_buffer = 0;
    return 1;
}

fn resetGl(s: *Self) void {
    const g = gl(s);
    if (s.vao != 0) g.DeleteVertexArrays.?(1, &s.vao);
    s.vao = 0;
    if (s.vbo_indices != 0) g.DeleteBuffers.?(1, &s.vbo_indices);
    s.vbo_indices = 0;
    if (s.checker_vbo != 0) g.DeleteBuffers.?(1, &s.checker_vbo);
    s.checker_vbo = 0;
    _ = c.gst_element_foreach_sink_pad(@ptrCast(@alignCast(s)), resetPad, s);
}

const Mouse = struct { event: [*c]c.GstEvent, res: bool };

fn mouseEvent(e: [*c]c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    _ = e;
    const d: *Mouse = @ptrCast(@alignCast(data));
    const p = padOf(pad);
    const info = &p.parent.parent.info;
    if (info.finfo == null or info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) return 1;
    const st = c.gst_structure_copy(c.gst_event_get_structure(d.event));
    var ex: f64 = 0;
    var ey: f64 = 0;
    _ = c.gst_structure_get(st, "pointer_x", c.G_TYPE_DOUBLE, &ex, "pointer_y", c.G_TYPE_DOUBLE, &ey, @as(?*anyopaque, null));
    const z = outputSize(p, info.par_n, info.par_d);
    const rx = z.x + p.xpos;
    const ry = z.y + p.ypos;
    const px: c.gint = @intFromFloat(ex);
    const py: c.gint = @intFromFloat(ey);
    if (px >= rx and px <= rx + z.w and py >= ry and py <= ry + z.h) {
        const w: f64 = @floatFromInt(info.width);
        const h: f64 = @floatFromInt(info.height);
        const x = (ex - @as(f64, @floatFromInt(rx))) * (w / @as(f64, @floatFromInt(z.w)));
        const y = (ey - @as(f64, @floatFromInt(ry))) * (h / @as(f64, @floatFromInt(z.h)));
        c.gst_structure_set(st, "pointer_x", c.G_TYPE_DOUBLE, x, "pointer_y", c.G_TYPE_DOUBLE, y, @as(?*anyopaque, null));
        if (c.gst_pad_push_event(pad, c.gst_event_new_navigation(st)) != 0) d.res = true;
    } else c.gst_structure_free(st);
    return 1;
}

fn srcEvent(agg: [*c]c.GstAggregator, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (e[0].type == c.GST_EVENT_NAVIGATION) {
        switch (c.gst_navigation_event_get_type(e)) {
            c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_PRESS, c.GST_NAVIGATION_EVENT_MOUSE_BUTTON_RELEASE, c.GST_NAVIGATION_EVENT_MOUSE_MOVE, c.GST_NAVIGATION_EVENT_MOUSE_SCROLL => {
                var d = Mouse{ .event = e, .res = false };
                _ = c.gst_element_foreach_sink_pad(@ptrCast(agg), mouseEvent, &d);
                c.gst_event_unref(e);
                return @intFromBool(d.res);
            },
            else => {},
        }
    }
    return parent_agg.src_event.?(agg, e);
}

fn glStop(bm: [*c]c.GstGLBaseMixer) callconv(.c) void {
    const s = me(bm);
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    if (s.checker != null) c.gst_object_unref(s.checker);
    s.checker = null;
    resetGl(s);
    parent_bm.gl_stop.?(bm);
}

fn glStart(bm: [*c]c.GstGLBaseMixer) callconv(.c) c.gboolean {
    const s = me(bm);
    s.output_geo_change = 1;
    if (s.shader == null) {
        const frag = c.g_strdup_printf("%s%s", c.gst_gl_shader_string_get_highest_precision(bm[0].context, c.GST_GLSL_VERSION_NONE, PROFILE), MIX_FRAG);
        _ = el.genShader(bm[0].context, c.gst_gl_shader_string_vertex_mat4_vertex_transform, frag, &s.shader);
        c.g_free(frag);
    }
    return parent_bm.gl_start.?(bm);
}

fn render(_: [*c]c.GstGLContext, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const fbo = c.gst_gl_mixer_get_framebuffer(@ptrCast(s));
    _ = c.gst_gl_framebuffer_draw_to_texture(fbo, s.out_tex, draw, s);
    if (fbo != null) c.gst_object_unref(fbo);
}

fn processTextures(m: [*c]c.GstGLMixer, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    const s = me(m);
    s.out_tex = out;
    c.gst_gl_context_thread_add(ctxOf(s), render, s);
    return 1;
}

fn initIndices(s: *Self) void {
    const g = gl(s);
    if (s.vbo_indices != 0) return;
    g.GenBuffers.?(1, &s.vbo_indices);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
    g.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, c.GL_STATIC_DRAW);
}

fn drawChecker(s: *Self) bool {
    const g = gl(s);
    const v = [_]f32{ -1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0 };
    if (s.checker == null) {
        const frag = c.g_strdup_printf("%s%s", c.gst_gl_shader_string_get_highest_precision(ctxOf(s), c.GST_GLSL_VERSION_NONE, PROFILE), CHECKER_FRAG);
        defer c.g_free(frag);
        if (el.genShader(ctxOf(s), CHECKER_VERT, frag, &s.checker) == 0) return false;
    }
    c.gst_gl_shader_use(s.checker);
    const loc: c.GLuint = @bitCast(c.gst_gl_shader_get_attribute_location(s.checker, "a_position"));
    initIndices(s);
    if (s.checker_vbo == 0) {
        g.GenBuffers.?(1, &s.checker_vbo);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.checker_vbo);
        g.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(v)), &v, c.GL_STATIC_DRAW);
    } else {
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.checker_vbo);
    }
    g.VertexAttribPointer.?(loc, 3, c.GL_FLOAT, c.GL_FALSE, 12, null);
    g.EnableVertexAttribArray.?(loc);
    g.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    g.DisableVertexAttribArray.?(loc);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    return true;
}

fn background(s: *Self) bool {
    const g = gl(s);
    const color: [4]f32 = switch (s.background) {
        @intFromEnum(Background.black) => .{ 0, 0, 0, 1 },
        @intFromEnum(Background.white) => .{ 1, 1, 1, 1 },
        @intFromEnum(Background.transparent) => .{ 0, 0, 0, 0 },
        @intFromEnum(Background.checker) => return drawChecker(s),
        else => return true,
    };
    g.ClearColor.?(color[0], color[1], color[2], color[3]);
    g.Clear.?(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
    return true;
}

fn equationGl(e: c.gint) c.GLenum {
    return switch (e) {
        0 => c.GL_FUNC_ADD,
        1 => c.GL_FUNC_SUBTRACT,
        2 => c.GL_FUNC_REVERSE_SUBTRACT,
        else => 0,
    };
}

fn functionGl(f: c.gint) c.GLenum {
    const table = [_]c.GLenum{ c.GL_ZERO, c.GL_ONE, c.GL_SRC_COLOR, c.GL_ONE_MINUS_SRC_COLOR, c.GL_DST_COLOR, c.GL_ONE_MINUS_DST_COLOR, c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_DST_ALPHA, c.GL_ONE_MINUS_DST_ALPHA, c.GL_CONSTANT_COLOR, c.GL_ONE_MINUS_CONSTANT_COLOR, c.GL_CONSTANT_ALPHA, c.GL_ONE_MINUS_CONSTANT_ALPHA, c.GL_SRC_ALPHA_SATURATE };
    return if (f >= 0 and f < table.len) table[@intCast(f)] else 0;
}

fn blendState(s: *Self, p: *Pad) bool {
    const g = gl(s);
    const separate = p.blend_equation_rgb != p.blend_equation_alpha or p.blend_function_src_rgb != p.blend_function_src_alpha or p.blend_function_dst_rgb != p.blend_function_dst_alpha;
    if (separate and (g.BlendFuncSeparate == null or g.BlendEquationSeparate == null)) return false;
    if (p.blend_function_dst_rgb == SATURATE or p.blend_function_dst_alpha == SATURATE) return false;
    const er = equationGl(p.blend_equation_rgb);
    const ea = equationGl(p.blend_equation_alpha);
    const sr = functionGl(p.blend_function_src_rgb);
    const sa = functionGl(p.blend_function_src_alpha);
    const dr = functionGl(p.blend_function_dst_rgb);
    const da = functionGl(p.blend_function_dst_alpha);
    if (g.BlendEquationSeparate) |f| f(er, ea) else g.BlendEquation.?(er);
    if (g.BlendFuncSeparate) |f| f(sr, dr, sa, da) else g.BlendFunc.?(sr, dr);
    g.BlendColor.?(@floatCast(p.blend_constant_color_red), @floatCast(p.blend_constant_color_green), @floatCast(p.blend_constant_color_blue), @floatCast(p.blend_constant_color_alpha));
    return true;
}

fn cropCoord(crop: c.gint, size: c.guint, comptime far: bool) f32 {
    if (crop == 0) return if (far) 1 else 0;
    const r = @as(f32, @floatFromInt(crop)) / @as(f32, @floatFromInt(size));
    return if (far) @floatCast(1.0 - @as(f64, r)) else r;
}

fn uploadGeometry(s: *Self, p: *Pad, iw: c.guint, ih: c.guint) void {
    const g = gl(s);
    const out = vinfo(s);
    const ow: f32 = @floatFromInt(out.width);
    const oh: f32 = @floatFromInt(out.height);
    var v = [_]f32{ -1, -1, 0, 0, 0, 1, -1, 0, 1, 0, 1, 1, 0, 1, 1, -1, 1, 0, 0, 1 };
    const z = outputSize(p, out.par_n, out.par_d);
    const w = @as(f32, @floatFromInt(z.w)) / ow;
    const h = @as(f32, @floatFromInt(z.h)) / oh;
    p.m_matrix[0] = w;
    p.m_matrix[5] = h;
    p.m_matrix[12] = @floatCast(2.0 * @as(f64, @as(f32, @floatFromInt(p.xpos + z.x))) / ow - (1.0 - @as(f64, w)));
    p.m_matrix[13] = @floatCast(2.0 * @as(f64, @as(f32, @floatFromInt(p.ypos + z.y))) / oh - (1.0 - @as(f64, h)));
    v[3] = cropCoord(p.crop_left, iw, false);
    v[18] = v[3];
    v[8] = cropCoord(p.crop_right, iw, true);
    v[13] = v[8];
    v[4] = cropCoord(p.crop_top, ih, false);
    v[9] = v[4];
    v[14] = cropCoord(p.crop_bottom, ih, true);
    v[19] = v[14];
    if (p.vertex_buffer == 0) g.GenBuffers.?(1, &p.vertex_buffer);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vertex_buffer);
    g.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(v)), &v, c.GL_STATIC_DRAW);
    p.geometry_change = 0;
}

fn draw(data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const g = gl(s);
    const ctx = ctxOf(s);
    c.gst_gl_context_clear_shader(ctx);
    g.BindTexture.?(c.GL_TEXTURE_2D, 0);
    g.Disable.?(c.GL_DEPTH_TEST);
    g.Disable.?(c.GL_CULL_FACE);
    const vao = g.GenVertexArrays != null;
    if (vao) {
        if (s.vao == 0) g.GenVertexArrays.?(1, &s.vao);
        g.BindVertexArray.?(s.vao);
    }
    if (!background(s)) return 0;
    c.gst_gl_shader_use(s.shader);
    const pos: c.GLuint = @bitCast(c.gst_gl_shader_get_attribute_location(s.shader, "a_position"));
    const tex: c.GLuint = @bitCast(c.gst_gl_shader_get_attribute_location(s.shader, "a_texcoord"));
    g.Enable.?(c.GL_BLEND);
    cm.lock(s);
    var l = sinkpads(s);
    while (l != null) : (l = l[0].next) {
        const p = padOf(l[0].data);
        p.copy_meta = 0;
        const info = &p.parent.parent.info;
        const iw: c.guint = @bitCast(info.width);
        const ih: c.guint = @bitCast(info.height);
        if (p.parent.current_texture == 0 or iw <= 0 or ih <= 0 or p.alpha == 0) continue;
        if (!blendState(s, p)) continue;
        p.copy_meta = 1;
        initIndices(s);
        if (s.output_geo_change != 0 or p.geometry_change != 0 or p.vertex_buffer == 0) uploadGeometry(s, p, iw, ih) else g.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vertex_buffer);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
        g.ActiveTexture.?(c.GL_TEXTURE0);
        g.BindTexture.?(c.GL_TEXTURE_2D, p.parent.current_texture);
        c.gst_gl_shader_set_uniform_1i(s.shader, "texture", 0);
        c.gst_gl_shader_set_uniform_1f(s.shader, "alpha", @floatCast(p.alpha));
        var m: [16]f32 = undefined;
        var af: [16]f32 = undefined;
        const buf = c.gst_video_aggregator_pad_get_current_buffer(@ptrCast(@alignCast(p)));
        const meta: [*c]c.GstVideoAffineTransformationMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(buf, c.gst_video_affine_transformation_meta_api_get_type())));
        c.gst_gl_get_affine_transformation_meta_as_ndc(meta, &af);
        c.gst_gl_multiply_matrix4(&af, &p.m_matrix, &m);
        c.gst_gl_shader_set_uniform_matrix_4fv(s.shader, "u_transformation", 1, 0, &m);
        g.EnableVertexAttribArray.?(pos);
        g.EnableVertexAttribArray.?(tex);
        g.VertexAttribPointer.?(pos, 3, c.GL_FLOAT, c.GL_FALSE, 20, null);
        g.VertexAttribPointer.?(tex, 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(12));
        g.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    }
    s.output_geo_change = 0;
    cm.unlock(s);
    if (vao) {
        g.BindVertexArray.?(0);
    } else {
        g.DisableVertexAttribArray.?(pos);
        g.DisableVertexAttribArray.?(tex);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        g.BindTexture.?(c.GL_TEXTURE_2D, 0);
    }
    g.Disable.?(c.GL_BLEND);
    c.gst_gl_context_clear_shader(ctx);
    return 1;
}

fn aggregateFrames(vagg: [*c]c.GstVideoAggregator, out: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(vagg);
    const ret = parent_vagg.aggregate_frames.?(vagg, out);
    if (ret != c.GST_FLOW_OK) return ret;
    var tags = [_][*c]const u8{ c.GST_META_TAG_VIDEO_STR, c.GST_META_TAG_VIDEO_ORIENTATION_STR, c.GST_META_TAG_VIDEO_SIZE_STR, c.GST_META_TAG_VIDEO_COLORSPACE_STR, null };
    const affine = c.gst_video_affine_transformation_meta_api_get_type();
    cm.lock(s);
    defer cm.unlock(s);
    var l = sinkpads(s);
    while (l != null) : (l = l[0].next) {
        const p = padOf(l[0].data);
        const info = &p.parent.parent.info;
        const buf = c.gst_video_aggregator_pad_get_current_buffer(@ptrCast(@alignCast(p)));
        if (p.copy_meta == 0) continue;
        if (c.gst_buffer_get_meta(buf, affine) != null) continue;
        const z = outputSize(p, vagg[0].info.par_n, vagg[0].info.par_d);
        var tm: c.GstVideoMetaTransformMatrix = undefined;
        const in_rect = c.GstVideoRectangle{ .x = p.crop_left, .y = p.crop_top, .w = info.width - p.crop_left - p.crop_right, .h = info.height - p.crop_top - p.crop_bottom };
        const out_rect = c.GstVideoRectangle{ .x = p.xpos + z.x, .y = p.ypos + z.y, .w = z.w, .h = z.h };
        c.gst_video_meta_transform_matrix_init(&tm, info, &in_rect, &vagg[0].info, &out_rect);
        var state: c.gpointer = null;
        while (c.gst_buffer_iterate_meta(buf, &state)) |m| {
            const mi = m[0].info;
            const f = mi[0].transform_func orelse continue;
            if (c.gst_meta_api_type_tags_contain_only(mi[0].api, @ptrCast(&tags)) == 0) continue;
            _ = f(out, m, buf, c.gst_video_meta_transform_matrix_get_quark(), &tm);
        }
    }
    return c.GST_FLOW_OK;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_agg = el.parentOf(c.GstAggregatorClass, k);
    parent_vagg = el.parentOf(c.GstVideoAggregatorClass, k);
    parent_bm = el.parentOf(c.GstGLBaseMixerClass, k);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.gst_element_class_set_static_metadata(ec, "OpenGL video_mixer", "Filter/Effect/Video/Compositor", "OpenGL video_mixer", "Matthew Waters <matthew@centricular.com>");
    c.gst_gl_mixer_class_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &sink_t, padType());
    c.g_object_class_install_property(oc, PROP_BACKGROUND, c.g_param_spec_enum("background", "Background", "Background type", backgroundType(), 0, cm.RW));
    const mc: *c.GstGLMixerClass = @ptrCast(@alignCast(k));
    mc.process_textures = processTextures;
    const bm: *c.GstGLBaseMixerClass = @ptrCast(@alignCast(k));
    bm.gl_stop = glStop;
    bm.gl_start = glStart;
    const vc: *c.GstVideoAggregatorClass = @ptrCast(@alignCast(k));
    vc.update_caps = updateCaps;
    vc.aggregate_frames = aggregateFrames;
    const ac: *c.GstAggregatorClass = @ptrCast(@alignCast(k));
    ac.src_event = srcEvent;
    ac.fixate_src_caps = fixateCaps;
    ac.propose_allocation = proposeAllocation;
    bm.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2;
    c.gst_type_mark_as_plugin_api(backgroundType(), 0);
    c.gst_type_mark_as_plugin_api(padType(), 0);
    c.gst_type_mark_as_plugin_api(equationType(), 0);
    c.gst_type_mark_as_plugin_api(functionType(), 0);
    c.gst_type_mark_as_plugin_api(sizingType(), 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_mixer_get_type(), "GstGLVideoMixer", Class, Self, classInit, null);
            el.addSinkpadProxy(t);
            _ = c._gst_debug_category_new("glvideomixer", 0, "glvideomixer element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    const a = el.register(p, "glvideomixer", c.GST_RANK_NONE, binType());
    const b = el.register(p, "glvideomixerelement", c.GST_RANK_NONE, getType());
    return a or b;
}
