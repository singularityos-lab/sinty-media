const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const enums = @import("enums.zig");
const format = @import("format.zig");
const framebuffer = @import("framebuffer.zig");
const glsl = @import("glsl.zig");
const glslstage = @import("glslstage.zig");
const shader = @import("shader.zig");
const shaderstrings = @import("shaderstrings.zig");
const memory = @import("memory.zig");
const basememory = @import("basememory.zig");
const syncmeta = @import("syncmeta.zig");
const utils = @import("utils.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const View = c.GstGLViewConvert;
const OView = [*c]View;
const Class = c.GstGLViewConvertClass;
const OCtx = [*c]c.GstGLContext;
const OBuf = [*c]c.GstBuffer;
const OCaps = [*c]c.GstCaps;
const OMem = [*c]c.GstGLMemory;
const Mode = c.GstVideoMultiviewMode;
const Flags = c.GstVideoMultiviewFlags;

const MONO = c.GST_VIDEO_MULTIVIEW_MODE_MONO;
const NONE = c.GST_VIDEO_MULTIVIEW_MODE_NONE;
const SEPARATED = c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED;
const FBF = c.GST_VIDEO_MULTIVIEW_MODE_FRAME_BY_FRAME;
const HALF = c.GST_VIDEO_MULTIVIEW_FLAGS_HALF_ASPECT;
const EXACT: c.guint = c.GST_FLAG_SET_MASK_EXACT;
const MAXINT: c.gint = std.math.maxInt(c.gint);

const CAPS = "video/x-raw(memory:GLMemory), format = (string) RGBA, width = (int) [ 1, max ], height = (int) [ 1, max ], framerate = (fraction) [ 0, max ], texture-target = (string) { 2D, rectangle, external-oes } ";
var caps_template = c.GstStaticCaps{ .caps = null, .string = CAPS, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };

const PROP_INPUT_LAYOUT = 1;
const PROP_INPUT_FLAGS = 2;
const PROP_OUTPUT_LAYOUT = 3;
const PROP_OUTPUT_FLAGS = 4;
const PROP_DOWNMIX = 5;

const Priv = struct {
    result: c.gboolean,
    input_mode: Mode,
    input_flags: Flags,
    output_mode: Mode,
    output_flags: Flags,
    primary_in: OBuf,
    aux_in: OBuf,
    primary_out: OBuf,
    aux_out: OBuf,
    in_tex: [c.GST_VIDEO_MAX_PLANES]OMem,
    out_tex: [c.GST_VIDEO_MAX_PLANES]OMem,
    n_out_tex: c.guint,
    vao: c.GLuint,
    vbo: c.GLuint,
    ibo: c.GLuint,
    attr_pos: c.GLuint,
    attr_tex: c.GLuint,
};

const DOWNMIX = [3][2][9]f32{
    .{
        .{ -0.062, 0.284, -0.015, -0.158, 0.668, -0.027, -0.039, 0.143, 0.021 },
        .{ 0.529, -0.016, 0.009, 0.705, -0.015, 0.075, 0.024, -0.065, 0.937 },
    },
    .{
        .{ 0.437, -0.062, -0.048, 0.449, -0.062, -0.050, 0.164, -0.024, -0.017 },
        .{ -0.011, 0.377, -0.026, -0.032, 0.761, -0.093, -0.007, 0.009, 1.234 },
    },
    .{
        .{ 1.062, -0.026, -0.038, -0.205, 0.908, -0.173, 0.299, 0.068, 0.022 },
        .{ -0.016, 0.006, 0.094, -0.123, 0.062, 0.185, -0.017, -0.017, 0.911 },
    },
};

const IDENTITY = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

const OES = "#extension GL_OES_EGL_image_external : require \n";
const HEADER = "uniform sampler2D tex_l;\nuniform sampler2D tex_r;\nuniform float width;\nuniform float height;\nuniform mat3 downmix[2];\nuniform vec2 tex_scale[2];\nuniform vec2 offsets[2];\n";
const INPUT = "  vec2 l_tex = v_texcoord * tex_scale[0] + offsets[0];\n  vec2 r_tex = v_texcoord * tex_scale[1] + offsets[1];\n  l = texture2D(tex_l, l_tex).rgba;\n  r = texture2D(tex_r, r_tex).rgba;\n";
const OUT_DOWNMIX = "  vec3 lcol = l.rgb * l.a + vec3(1.0-l.a);\n  vec3 rcol = r.rgb * r.a + vec3(1.0-r.a);\n  if (l.a + r.a > 0.0) {\n    lcol = clamp (downmix[0] * lcol, 0.0, 1.0);\n    rcol = clamp (downmix[1] * rcol, 0.0, 1.0);\n    gl_FragColor = vec4 (lcol + rcol, 1.0);\n  } else {\n    gl_FragColor = vec4 (0.0);\n  }\n";
const OUT_LEFT = "  gl_FragColor = l;\n";
const OUT_RIGHT = "  gl_FragColor = r;\n";
const OUT_SBS = "  if (v_texcoord.x < 0.5) {\n    gl_FragColor = l;\n  } else {\n    gl_FragColor = r;\n  };\n";
const OUT_TB = "if (v_texcoord.y < 0.5) {\n  gl_FragColor = l;\n} else {\n  gl_FragColor = r;\n};\n";
const OUT_COLS = "if (int(mod(l_tex.x * width, 2.0)) == 0) {\n  gl_FragColor = l;\n} else {\n  gl_FragColor = r;\n};\n";
const OUT_ROWS = "if (int(mod(l_tex.y * height, 2.0)) == 0) {\n  gl_FragColor = l;\n} else {\n  gl_FragColor = r;\n};\n";
const OUT_CHECKER = "if (int(mod(l_tex.x * width, 2.0)) == \n    int(mod(l_tex.y * height, 2.0))) {\n  gl_FragColor = l;\n} else {\n  gl_FragColor = r;\n};\n";
const OUT_SEPARATED = "gl_FragData[0] = l;\ngl_FragData[1] = r;\n";

const VERTICES = [20]c.GLfloat{ 1, -1, 0, 1, 0, -1, -1, 0, 0, 0, -1, 1, 0, 0, 1, 1, 1, 0, 1, 1 };
const INDICES = [6]c.GLushort{ 0, 1, 2, 0, 2, 3 };

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn vc(p: anytype) OView {
    return @ptrCast(@alignCast(p));
}

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(vc(p)[0].priv));
}

fn vt(ctx: OCtx) *c.GstGLFuncs {
    return @ptrCast(ctx[0].gl_vtable);
}

fn isView(p: anytype) bool {
    return gtype.instanceOf(p, gst_gl_view_convert_get_type());
}

fn objLock(p: anytype) void {
    c.g_mutex_lock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn objUnlock(p: anytype) void {
    c.g_mutex_unlock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn clearBuf(b: *OBuf) void {
    _ = c.gst_buffer_replace(b, null);
}

fn clearIo(p: *Priv) void {
    clearBuf(&p.primary_in);
    clearBuf(&p.aux_in);
    clearBuf(&p.primary_out);
    clearBuf(&p.aux_out);
}

fn flagset() c.GType {
    return c.gst_video_multiview_flagset_get_type();
}

fn setFlags(s: [*c]c.GstStructure, flags: c.guint, mask: c.guint) void {
    c.gst_structure_set(s, "multiview-flags", flagset(), flags, mask, @as(?*anyopaque, null));
}

fn holds(v: [*c]const c.GValue, t: c.GType) bool {
    return c.g_type_check_value_holds(@constCast(v), t) != 0;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const v = vc(o);
    gst_gl_view_convert_reset(v);
    clearIo(pv(v));
    if (v[0].context != null) {
        c.gst_object_unref(v[0].context);
        v[0].context = null;
    }
    parent.?.finalize.?(o);
}

pub export fn gst_gl_view_convert_new() OView {
    const v = c.g_object_new(gst_gl_view_convert_get_type(), null);
    _ = c.gst_object_ref_sink(v);
    return vc(v);
}

fn resetGl(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const p = pv(data);
    const gl = vt(ctx);
    if (p.vao != 0) {
        gl.DeleteVertexArrays.?(1, &p.vao);
        p.vao = 0;
    }
    if (p.vbo != 0) {
        gl.DeleteBuffers.?(1, &p.vbo);
        p.vbo = 0;
    }
    if (p.ibo != 0) {
        gl.DeleteBuffers.?(1, &p.ibo);
        p.ibo = 0;
    }
}

pub export fn gst_gl_view_convert_set_context(v: OView, ctx: OCtx) void {
    if (!check.that(isView(v), "gst_gl_view_convert_set_context", "GST_IS_GL_VIEW_CONVERT (viewconvert)")) return;
    var old: OCtx = null;
    objLock(v);
    if (ctx != v[0].context) {
        gst_gl_view_convert_reset(v);
        old = v[0].context;
        v[0].context = if (ctx != null) @ptrCast(@alignCast(c.gst_object_ref(ctx))) else null;
    }
    objUnlock(v);
    if (old != null) c.gst_object_unref(old);
}

fn setFormat(v: OView, in: *const c.GstVideoInfo, from: c.GstGLTextureTarget, out: *const c.GstVideoInfo, to: c.GstGLTextureTarget) bool {
    if (!check.that(isView(v), "_view_convert_set_format", "GST_IS_GL_VIEW_CONVERT (viewconvert)")) return false;
    if (c.gst_video_info_is_equal(in, &v[0].in_info) != 0 and c.gst_video_info_is_equal(out, &v[0].out_info) != 0 and v[0].from_texture_target == from and v[0].to_texture_target == to) return true;
    if (in.finfo[0].format != c.GST_VIDEO_FORMAT_RGBA or out.finfo[0].format != c.GST_VIDEO_FORMAT_RGBA) return false;
    const pass = c.gst_video_info_is_equal(in, out) != 0 and from == to;
    if (!pass and to != c.GST_GL_TEXTURE_TARGET_2D and to != c.GST_GL_TEXTURE_TARGET_RECTANGLE) return false;
    objLock(v);
    gst_gl_view_convert_reset(v);
    v[0].in_info = in.*;
    v[0].out_info = out.*;
    v[0].from_texture_target = from;
    v[0].to_texture_target = to;
    v[0].caps_passthrough = @intFromBool(pass);
    clearIo(pv(v));
    objUnlock(v);
    return true;
}

fn targetOf(s: ?*const c.GstStructure) c.GstGLTextureTarget {
    if (c.gst_structure_has_field_typed(s, "texture-target", c.G_TYPE_STRING) == 0) return c.GST_GL_TEXTURE_TARGET_2D;
    return format.gst_gl_texture_target_from_string(c.gst_structure_get_string(s, "texture-target"));
}

pub export fn gst_gl_view_convert_set_caps(v: OView, in_caps: OCaps, out_caps: OCaps) c.gboolean {
    const fname = "gst_gl_view_convert_set_caps";
    if (!check.that(isView(v), fname, "GST_IS_GL_VIEW_CONVERT (viewconvert)")) return 0;
    if (!check.that(isCaps(in_caps), fname, "GST_IS_CAPS (in_caps)")) return 0;
    if (!check.that(isCaps(out_caps), fname, "GST_IS_CAPS (out_caps)")) return 0;
    if (c.gst_caps_features_contains(c.gst_caps_get_features(in_caps, 0), "memory:GLMemory") == 0) return 0;
    if (c.gst_caps_features_contains(c.gst_caps_get_features(out_caps, 0), "memory:GLMemory") == 0) return 0;
    var in: c.GstVideoInfo = undefined;
    var out: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&in, in_caps) == 0) return 0;
    if (c.gst_video_info_from_caps(&out, out_caps) == 0) return 0;
    const from = targetOf(c.gst_caps_get_structure(in_caps, 0));
    const to = targetOf(c.gst_caps_get_structure(out_caps, 0));
    if (to == c.GST_GL_TEXTURE_TARGET_NONE or from == c.GST_GL_TEXTURE_TARGET_NONE) return 0;
    return @intFromBool(setFormat(v, &in, from, &out, to));
}

fn isCaps(p: anytype) bool {
    if (p == null) return false;
    return @as(*c.GstMiniObject, @ptrCast(@alignCast(p))).type == c.gst_caps_get_type();
}

fn halve(out: [*c]c.GValue, in: [*c]const c.GValue) bool {
    if (holds(in, c.G_TYPE_INT)) {
        _ = c.g_value_init(out, c.G_TYPE_INT);
        c.g_value_set_int(out, @max(@divTrunc(c.g_value_get_int(in), 2), 1));
    } else if (holds(in, c.gst_fraction_get_type())) {
        const num = c.gst_value_get_fraction_numerator(in);
        var den = c.gst_value_get_fraction_denominator(in);
        _ = c.g_value_init(out, c.gst_fraction_get_type());
        if ((num != 1 or den != MAXINT) and (num != MAXINT or den != 1)) den = if (den > @divTrunc(MAXINT, 2)) MAXINT else den * 2;
        c.gst_value_set_fraction(out, num, den);
    } else if (holds(in, c.gst_int_range_get_type())) {
        var lo = c.gst_value_get_int_range_min(in);
        var hi = c.gst_value_get_int_range_max(in);
        const step = c.gst_value_get_int_range_step(in);
        _ = c.g_value_init(out, c.gst_int_range_get_type());
        if (lo != 1) lo = @max(1, @divTrunc(lo, 2));
        if (hi != MAXINT) hi = @max(1, @divTrunc(hi, 2));
        c.gst_value_set_int_range_step(out, lo, hi, @max(1, @divTrunc(step, 2)));
    } else if (holds(in, c.gst_fraction_range_get_type())) {
        var lo = std.mem.zeroes(c.GValue);
        var hi = std.mem.zeroes(c.GValue);
        _ = halve(&lo, c.gst_value_get_fraction_range_min(in));
        _ = halve(&hi, c.gst_value_get_fraction_range_max(in));
        _ = c.g_value_init(out, c.gst_fraction_range_get_type());
        c.gst_value_set_fraction_range(out, &lo, &hi);
        c.g_value_unset(&lo);
        c.g_value_unset(&hi);
    } else if (holds(in, c.gst_value_list_get_type())) {
        _ = c.g_value_init(out, c.gst_value_list_get_type());
        var i: c.guint = 0;
        while (i < c.gst_value_list_get_size(in)) : (i += 1) {
            var t = std.mem.zeroes(c.GValue);
            if (!halve(&t, c.gst_value_list_get_value(in, i))) {
                c.g_value_unset(out);
                return false;
            }
            c.gst_value_list_append_and_take_value(out, &t);
        }
    } else return false;
    return true;
}

fn double(out: [*c]c.GValue, in: [*c]const c.GValue) bool {
    if (holds(in, c.G_TYPE_INT)) {
        const n = c.g_value_get_int(in);
        _ = c.g_value_init(out, c.G_TYPE_INT);
        c.g_value_set_int(out, if (n <= @divTrunc(MAXINT, 2)) n * 2 else MAXINT);
    } else if (holds(in, c.gst_fraction_get_type())) {
        var num = c.gst_value_get_fraction_numerator(in);
        const den = c.gst_value_get_fraction_denominator(in);
        _ = c.g_value_init(out, c.gst_fraction_get_type());
        if ((num != 1 or den != MAXINT) and (num != MAXINT or den != 1)) num = if (num > @divTrunc(MAXINT, 2)) MAXINT else num * 2;
        c.gst_value_set_fraction(out, num, den);
    } else if (holds(in, c.gst_int_range_get_type())) {
        var lo = c.gst_value_get_int_range_min(in);
        var hi = c.gst_value_get_int_range_max(in);
        const step = @min(@divTrunc(MAXINT, 2), c.gst_value_get_int_range_step(in));
        if (lo != 1) lo = @min(@divTrunc(MAXINT, 2), lo) * 2;
        if (hi != MAXINT) hi = @min(@divTrunc(MAXINT, 2), hi) * 2;
        _ = c.g_value_init(out, c.gst_int_range_get_type());
        c.gst_value_set_int_range_step(out, lo, hi, step);
    } else if (holds(in, c.gst_fraction_range_get_type())) {
        var lo = std.mem.zeroes(c.GValue);
        var hi = std.mem.zeroes(c.GValue);
        _ = double(&lo, c.gst_value_get_fraction_range_min(in));
        _ = double(&hi, c.gst_value_get_fraction_range_max(in));
        _ = c.g_value_init(out, c.gst_fraction_range_get_type());
        c.gst_value_set_fraction_range(out, &lo, &hi);
        c.g_value_unset(&lo);
        c.g_value_unset(&hi);
    } else if (holds(in, c.gst_value_list_get_type())) {
        _ = c.g_value_init(out, c.gst_value_list_get_type());
        var i: c.guint = 0;
        while (i < c.gst_value_list_get_size(in)) : (i += 1) {
            var t = std.mem.zeroes(c.GValue);
            if (!double(&t, c.gst_value_list_get_value(in, i))) {
                c.g_value_unset(out);
                return false;
            }
            c.gst_value_list_append_and_take_value(out, &t);
        }
    } else return false;
    return true;
}

fn scaleField(in: ?*const c.GstStructure, field: [*c]const u8, comptime f: fn ([*c]c.GValue, [*c]const c.GValue) bool) [*c]c.GstStructure {
    const v = c.gst_structure_get_value(in, field);
    if (v == null) return c.gst_structure_copy(in);
    var t = std.mem.zeroes(c.GValue);
    if (!f(&t, v)) return null;
    const out = c.gst_structure_copy(in);
    c.gst_structure_set_value(out, field, &t);
    c.g_value_unset(&t);
    return out;
}

fn halveField(in: ?*const c.GstStructure, field: [*c]const u8) [*c]c.GstStructure {
    return scaleField(in, field, halve);
}

fn doubleField(in: ?*const c.GstStructure, field: [*c]const u8) [*c]c.GstStructure {
    return scaleField(in, field, double);
}

fn featuresCopy(f: ?*c.GstCapsFeatures) ?*c.GstCapsFeatures {
    return if (f != null) c.gst_caps_features_copy(f) else null;
}

fn doubleCaps(in: OCaps, field: [*c]const u8) OCaps {
    var out = c.gst_caps_new_empty();
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(in)) : (i += 1) {
        const r = doubleField(c.gst_caps_get_structure(in, i), field);
        out = c.gst_caps_merge_structure_full(out, r, featuresCopy(c.gst_caps_get_features(in, i)));
    }
    return out;
}

fn expandPar(in: OCaps, vertical: bool) OCaps {
    var out = c.gst_caps_new_empty();
    while (c.gst_caps_get_size(in) > 0) {
        const feat = featuresCopy(c.gst_caps_get_features(in, 0));
        const s = c.gst_caps_steal_structure(in, 0);
        var flags: c.guint = 0;
        var mask: c.guint = 0;
        if (c.gst_structure_get_flagset(s, "multiview-flags", &flags, &mask) == 0 or mask & HALF == 0) {
            c.gst_caps_append_structure_full(out, s, feat);
            continue;
        }
        if (c.gst_structure_has_field(s, "pixel-aspect-ratio") == 0) {
            setFlags(s, flags & ~@as(c.guint, HALF), mask & ~@as(c.guint, HALF));
            c.gst_caps_append_structure_full(out, s, feat);
            continue;
        }
        out = c.gst_caps_merge_structure_full(out, c.gst_structure_copy(s), featuresCopy(feat));
        var t: [*c]c.GstStructure = undefined;
        if (flags & HALF != 0) {
            t = if (vertical) halveField(s, "pixel-aspect-ratio") else doubleField(s, "pixel-aspect-ratio");
            setFlags(t, flags & ~@as(c.guint, HALF), mask | HALF);
        } else {
            t = if (vertical) doubleField(s, "pixel-aspect-ratio") else halveField(s, "pixel-aspect-ratio");
            setFlags(t, flags | HALF, mask | HALF);
        }
        out = c.gst_caps_merge_structure_full(out, t, featuresCopy(feat));
        c.gst_structure_free(s);
        if (feat != null) c.gst_caps_features_free(feat);
    }
    c.gst_caps_unref(in);
    return out;
}

fn monoVariant(s: [*c]c.GstStructure, flags: c.guint, mask: c.guint) [*c]c.GstStructure {
    const n = c.gst_structure_copy(s);
    c.gst_structure_set_value(n, "multiview-mode", c.gst_video_multiview_get_mono_modes());
    if (flags & HALF != 0) setFlags(n, flags & ~@as(c.guint, HALF), mask & ~@as(c.guint, HALF));
    return n;
}

fn modesMatch(in: [*c]const c.GValue, modes: [*c]const c.GValue) bool {
    return c.gst_value_intersect(null, in, modes) != 0;
}

fn expandStructure(out_caps: OCaps, s: [*c]c.GstStructure, feat: ?*c.GstCapsFeatures) OCaps {
    var expanded = c.gst_caps_new_empty();
    var flags: c.guint = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE;
    var mask: c.guint = EXACT;
    if (c.gst_structure_has_field(s, "multiview-mode") == 0) c.gst_structure_set(s, "multiview-mode", c.G_TYPE_STRING, c.gst_video_multiview_mode_to_caps_string(MONO), @as(?*anyopaque, null));
    if (c.gst_structure_has_field(s, "multiview-flags") == 0) setFlags(s, flags, mask) else _ = c.gst_structure_get_flagset(s, "multiview-flags", &flags, &mask);
    const modes = c.gst_structure_get_value(s, "multiview-mode");
    var mono = c.gst_caps_new_empty();
    if (modesMatch(modes, c.gst_video_multiview_get_mono_modes())) c.gst_caps_append_structure_full(mono, monoVariant(s, flags, mask), featuresCopy(feat));
    if (modesMatch(modes, c.gst_video_multiview_get_unpacked_modes())) c.gst_caps_append_structure_full(mono, monoVariant(s, flags, mask), featuresCopy(feat));
    if (modesMatch(modes, c.gst_video_multiview_get_doubled_height_modes())) {
        var n = halveField(s, "height");
        c.gst_structure_set_value(n, "multiview-mode", c.gst_video_multiview_get_mono_modes());
        if (flags & HALF != 0) {
            const h = halveField(n, "pixel-aspect-ratio");
            setFlags(s, flags & ~@as(c.guint, HALF), mask | HALF);
            c.gst_structure_free(n);
            n = h;
        }
        mono = c.gst_caps_merge_structure_full(mono, n, featuresCopy(feat));
    }
    if (modesMatch(modes, c.gst_video_multiview_get_doubled_width_modes())) {
        var n = halveField(s, "width");
        c.gst_structure_set_value(n, "multiview-mode", c.gst_video_multiview_get_mono_modes());
        if (flags & HALF != 0) {
            const h = doubleField(n, "pixel-aspect-ratio");
            setFlags(s, flags & ~@as(c.guint, HALF), mask | HALF);
            c.gst_structure_free(n);
            n = h;
        }
        mono = c.gst_caps_merge_structure_full(mono, n, featuresCopy(feat));
    }
    if (modesMatch(modes, c.gst_video_multiview_get_doubled_size_modes())) {
        const w = halveField(s, "width");
        const wh = halveField(w, "height");
        c.gst_structure_free(w);
        c.gst_structure_set_value(wh, "multiview-mode", c.gst_video_multiview_get_mono_modes());
        mono = c.gst_caps_merge_structure_full(mono, wh, featuresCopy(feat));
    }
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(mono)) : (i += 1) {
        const m = c.gst_caps_get_structure(mono, i);
        c.gst_structure_remove_fields(m, "views", @as(?*anyopaque, null));
        if (c.gst_structure_get_flagset(m, "multiview-flags", &flags, &mask) != 0) setFlags(m, flags, mask & (HALF | c.GST_VIDEO_MULTIVIEW_FLAGS_MIXED_MONO));
    }
    var t = c.gst_caps_copy(mono);
    i = 0;
    while (i < c.gst_caps_get_size(t)) : (i += 1) {
        const m = c.gst_caps_get_structure(t, i);
        c.gst_structure_remove_fields(m, "views", @as(?*anyopaque, null));
        if (c.gst_structure_get_flagset(m, "multiview-flags", &flags, &mask) != 0) setFlags(m, flags, 0);
    }
    expanded = c.gst_caps_merge(expanded, t);
    t = c.gst_caps_copy(mono);
    c.gst_caps_set_value(t, "multiview-mode", c.gst_video_multiview_get_unpacked_modes());
    i = 0;
    while (i < c.gst_caps_get_size(t)) : (i += 1) {
        const m = c.gst_caps_get_structure(t, i);
        c.gst_structure_set(m, "views", c.G_TYPE_INT, @as(c_int, 2), @as(?*anyopaque, null));
        if (c.gst_structure_get_flagset(m, "multiview-flags", &flags, &mask) != 0) setFlags(m, flags, 0);
    }
    expanded = c.gst_caps_merge(expanded, t);
    t = doubleCaps(mono, "height");
    c.gst_caps_set_value(t, "multiview-mode", c.gst_video_multiview_get_doubled_height_modes());
    expanded = c.gst_caps_merge(expanded, expandPar(t, true));
    t = doubleCaps(mono, "width");
    c.gst_caps_set_value(t, "multiview-mode", c.gst_video_multiview_get_doubled_width_modes());
    expanded = c.gst_caps_merge(expanded, expandPar(t, false));
    const tw = doubleCaps(mono, "width");
    t = doubleCaps(tw, "height");
    c.gst_caps_unref(tw);
    c.gst_caps_set_value(t, "multiview-mode", c.gst_video_multiview_get_doubled_size_modes());
    expanded = c.gst_caps_merge(expanded, t);
    c.gst_caps_unref(mono);
    if (c.gst_caps_is_empty(expanded) != 0) {
        c.gst_caps_unref(expanded);
        return out_caps;
    }
    t = c.gst_caps_copy(expanded);
    c.gst_caps_set_simple(t, "width", c.gst_int_range_get_type(), @as(c_int, 1), MAXINT, "height", c.gst_int_range_get_type(), @as(c_int, 1), MAXINT, @as(?*anyopaque, null));
    return c.gst_caps_merge(c.gst_caps_merge(out_caps, expanded), t);
}

fn withMode(caps: OCaps, mode: Mode, flags: Flags) OCaps {
    const f = c.gst_caps_new_simple("video/x-raw", "multiview-mode", c.G_TYPE_STRING, c.gst_video_multiview_mode_to_caps_string(mode), "multiview-flags", flagset(), @as(c.guint, @bitCast(flags)), EXACT, @as(?*anyopaque, null));
    if (mode == SEPARATED or mode == FBF) c.gst_caps_set_simple(f, "views", c.G_TYPE_INT, @as(c_int, 2), @as(?*anyopaque, null));
    c.gst_caps_set_features(f, 0, c.gst_caps_features_new_any());
    const r = c.gst_caps_intersect_full(caps, f, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(f);
    return r;
}

fn withModes(caps: OCaps, modes: [*c]const c.GValue) OCaps {
    const f = c.gst_caps_new_empty_simple("video/x-raw");
    c.gst_caps_set_value(f, "multiview-mode", modes);
    c.gst_caps_set_features(f, 0, c.gst_caps_features_new_any());
    const r = c.gst_caps_intersect_full(caps, f, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(f);
    return r;
}

pub export fn gst_gl_view_convert_transform_caps(v: OView, dir: c.GstPadDirection, in_caps: OCaps, _: OCaps) OCaps {
    const base = c.gst_static_caps_get(&caps_template);
    if (!check.that(isView(v), "gst_gl_view_convert_transform_caps", "GST_IS_GL_VIEW_CONVERT (viewconvert)")) return null;
    const caps = c.gst_caps_intersect(in_caps, base);
    c.gst_caps_unref(base);
    var out: OCaps = undefined;
    if (dir == c.GST_PAD_SINK) {
        out = c.gst_caps_copy(caps);
        if (v[0].input_mode_override != NONE) c.gst_caps_set_simple(out, "multiview-mode", c.G_TYPE_STRING, c.gst_video_multiview_mode_to_caps_string(v[0].input_mode_override), "multiview-flags", flagset(), @as(c.guint, @bitCast(v[0].input_flags_override)), EXACT, @as(?*anyopaque, null));
    } else out = c.gst_caps_new_empty();
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) out = expandStructure(out, c.gst_caps_get_structure(caps, i), c.gst_caps_get_features(caps, i));
    if (c.gst_caps_is_empty(out) == 0) {
        if (dir == c.GST_PAD_SINK and v[0].output_mode_override != NONE) {
            const t = withMode(out, v[0].output_mode_override, v[0].output_flags_override);
            c.gst_caps_unref(out);
            out = t;
        } else if (v[0].input_mode_override != NONE) {
            out = c.gst_caps_merge(out, withMode(out, v[0].input_mode_override, v[0].input_flags_override));
        }
        if (dir == c.GST_PAD_SRC) {
            const t = withMode(caps, MONO, c.GST_VIDEO_MULTIVIEW_FLAGS_NONE);
            if (c.gst_caps_is_empty(t) == 0) {
                c.gst_structure_remove_fields(c.gst_caps_get_structure(t, 0), "multiview-mode", "multiview-flags", @as(?*anyopaque, null));
                out = c.gst_caps_merge(out, t);
            } else c.gst_caps_unref(t);
        }
    }
    c.gst_caps_unref(caps);
    i = 0;
    const n = c.gst_caps_get_size(out);
    while (i < n) : (i += 1) c.gst_structure_remove_fields(c.gst_caps_get_structure(out, i), "texture-target", @as(?*anyopaque, null));
    return out;
}

fn targetMask(t: [*c]const c.GValue) c.guint {
    if (t == null) return 1 << c.GST_GL_TEXTURE_TARGET_2D;
    var m: c.guint = 0;
    if (t[0].g_type == c.G_TYPE_STRING) {
        const x = format.gst_gl_texture_target_from_string(c.g_value_get_string(t));
        if (x != 0) m |= @as(c.guint, 1) << @intCast(x);
    } else if (t[0].g_type == c.gst_value_list_get_type()) {
        var j: c.guint = 0;
        while (j < c.gst_value_list_get_size(t)) : (j += 1) {
            const x = format.gst_gl_texture_target_from_string(c.g_value_get_string(c.gst_value_list_get_value(t, j)));
            if (x != 0) m |= @as(c.guint, 1) << @intCast(x);
        }
    }
    return m;
}

fn fixateTarget(dir: c.GstPadDirection, caps: OCaps, other_in: OCaps) OCaps {
    const other = c.gst_caps_make_writable(other_in);
    const s = c.gst_caps_get_structure(caps, 0);
    const so = c.gst_caps_get_structure(other, 0);
    const mine = targetMask(c.gst_structure_get_value(s, "texture-target"));
    const theirs = targetMask(c.gst_structure_get_value(so, "texture-target"));
    var r = mine & theirs;
    if (r == 0) return c.gst_caps_fixate(other);
    const T2D: c.guint = 1 << c.GST_GL_TEXTURE_TARGET_2D;
    const TRECT: c.guint = 1 << c.GST_GL_TEXTURE_TARGET_RECTANGLE;
    const TOES: c.guint = 1 << c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES;
    if (dir == c.GST_PAD_SINK) r &= T2D | TRECT else r = if (mine & T2D != 0) std.math.maxInt(c.guint) else theirs;
    var item = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&item, c.G_TYPE_STRING);
    if (r & T2D != 0) c.g_value_set_static_string(&item, "2D") else if (r & TRECT != 0) c.g_value_set_static_string(&item, "rectangle") else if (r & TOES != 0) c.g_value_set_static_string(&item, "external-oes");
    c.gst_structure_set_value(so, "texture-target", &item);
    c.g_value_unset(&item);
    return c.gst_caps_fixate(other);
}

fn swapIfNonEmpty(other: *OCaps, t: OCaps) bool {
    if (c.gst_caps_is_empty(t) != 0) {
        c.gst_caps_unref(t);
        return false;
    }
    c.gst_caps_unref(other.*);
    other.* = t;
    return true;
}

pub export fn gst_gl_view_convert_fixate_caps(v: OView, dir: c.GstPadDirection, caps: OCaps, other_in: OCaps) OCaps {
    if (!check.that(isView(v), "gst_gl_view_convert_fixate_caps", "GST_IS_GL_VIEW_CONVERT (viewconvert)")) return null;
    var other = c.gst_caps_make_writable(other_in);
    if (dir == c.GST_PAD_SINK) {
        if (v[0].output_mode_override != NONE) {
            const t = withMode(other, v[0].output_mode_override, v[0].output_flags_override);
            c.gst_caps_unref(other);
            other = t;
        } else {
            var info: c.GstVideoInfo = undefined;
            if (c.gst_video_info_from_caps(&info, caps) != 0) {
                var mode = info.ABI.abi.multiview_mode;
                var flags = info.ABI.abi.multiview_flags;
                if (v[0].input_mode_override != NONE) {
                    mode = v[0].input_mode_override;
                    flags = v[0].input_flags_override;
                }
                if (swapIfNonEmpty(&other, withMode(other, mode, flags))) return other;
            }
            _ = swapIfNonEmpty(&other, withModes(other, c.gst_video_multiview_get_unpacked_modes()));
        }
    } else if (v[0].input_mode_override != NONE) {
        _ = swapIfNonEmpty(&other, withMode(other, v[0].input_mode_override, v[0].input_flags_override));
    }
    return fixateTarget(dir, caps, other);
}

pub export fn gst_gl_view_convert_reset(v: OView) void {
    if (!check.that(isView(v), "gst_gl_view_convert_reset", "GST_IS_GL_VIEW_CONVERT (viewconvert)")) return;
    if (v[0].shader != null) {
        c.gst_object_unref(v[0].shader);
        v[0].shader = null;
    }
    if (v[0].fbo != null) {
        c.gst_object_unref(v[0].fbo);
        v[0].fbo = null;
    }
    if (v[0].context != null) c.gst_gl_context_thread_add(v[0].context, resetGl, v);
    v[0].initted = 0;
    v[0].reconfigure = 0;
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/gstglviewconvert.c", line, "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, val: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const v = vc(o);
    switch (id) {
        PROP_INPUT_LAYOUT => v[0].input_mode_override = c.g_value_get_enum(val),
        PROP_INPUT_FLAGS => v[0].input_flags_override = @bitCast(c.g_value_get_flags(val)),
        PROP_OUTPUT_LAYOUT => v[0].output_mode_override = c.g_value_get_enum(val),
        PROP_OUTPUT_FLAGS => v[0].output_flags_override = @bitCast(c.g_value_get_flags(val)),
        PROP_DOWNMIX => v[0].downmix_mode = @bitCast(c.g_value_get_enum(val)),
        else => warnInvalid(o, id, spec, 1404),
    }
    objLock(v);
    v[0].reconfigure = 1;
    objUnlock(v);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, val: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const v = vc(o);
    switch (id) {
        PROP_INPUT_LAYOUT => c.g_value_set_enum(val, v[0].input_mode_override),
        PROP_INPUT_FLAGS => c.g_value_set_flags(val, @bitCast(v[0].input_flags_override)),
        PROP_OUTPUT_LAYOUT => c.g_value_set_enum(val, v[0].output_mode_override),
        PROP_OUTPUT_FLAGS => c.g_value_set_flags(val, @bitCast(v[0].output_flags_override)),
        PROP_DOWNMIX => c.g_value_set_enum(val, @bitCast(v[0].downmix_mode)),
        else => warnInvalid(o, id, spec, 1434),
    }
}

pub export fn gst_gl_view_convert_perform(v: OView, in: OBuf) OBuf {
    if (gst_gl_view_convert_submit_input_buffer(v, @intFromBool(@as(*c.GstMiniObject, @ptrCast(in)).flags & c.GST_BUFFER_FLAG_DISCONT != 0), c.gst_buffer_ref(in)) != c.GST_FLOW_OK) return null;
    var out: OBuf = null;
    if (gst_gl_view_convert_get_output(v, &out) != c.GST_FLOW_OK) return null;
    return out;
}

fn fragmentSource(v: OView, sh: [*c]c.GstGLShader, in_mode: Mode, out_mode: Mode, ver: c.GstGLSLVersion, prof: c.GstGLSLProfile) [*c]u8 {
    const mono_in = in_mode == NONE or in_mode == MONO or in_mode == c.GST_VIDEO_MULTIVIEW_MODE_LEFT or in_mode == c.GST_VIDEO_MULTIVIEW_MODE_RIGHT;
    var outputs: c_int = 1;
    const out_str: [*:0]const u8 = switch (out_mode) {
        c.GST_VIDEO_MULTIVIEW_MODE_LEFT => OUT_LEFT,
        c.GST_VIDEO_MULTIVIEW_MODE_RIGHT => OUT_RIGHT,
        c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE_QUINCUNX, c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE => OUT_SBS,
        c.GST_VIDEO_MULTIVIEW_MODE_TOP_BOTTOM => OUT_TB,
        c.GST_VIDEO_MULTIVIEW_MODE_COLUMN_INTERLEAVED => OUT_COLS,
        c.GST_VIDEO_MULTIVIEW_MODE_ROW_INTERLEAVED => OUT_ROWS,
        SEPARATED, FBF => blk: {
            outputs = 2;
            break :blk OUT_SEPARATED;
        },
        c.GST_VIDEO_MULTIVIEW_MODE_CHECKERBOARD => OUT_CHECKER,
        else => if (mono_in) OUT_LEFT else OUT_DOWNMIX,
    };
    const s = c.g_string_new(null);
    if (v[0].from_texture_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) _ = c.g_string_append(s, OES);
    _ = c.g_string_append(s, shaderstrings.gst_gl_shader_string_get_highest_precision(v[0].context, ver, prof));
    _ = c.g_string_append(s, HEADER);
    const core = prof == c.GST_GLSL_PROFILE_CORE;
    const es = prof == c.GST_GLSL_PROFILE_ES;
    if ((core and ver >= c.GST_GLSL_VERSION_330) or (es and ver >= c.GST_GLSL_VERSION_300)) {
        if (outputs > 1) {
            var i: c_int = 0;
            while (i < outputs) : (i += 1) c.g_string_append_printf(s, "layout(location = %d) out vec4 fragColor_%d;\n", i, i);
        } else _ = c.g_string_append(s, "layout (location = 0) out vec4 fragColor;\n");
    } else if (core and ver >= c.GST_GLSL_VERSION_150) {
        if (outputs > 1) {
            var i: c_int = 0;
            while (i < outputs) : (i += 1) {
                const name = c.g_strdup_printf("fragColor_%d", i);
                c.g_string_append_printf(s, "out vec4 %s;\n", name);
                shader.gst_gl_shader_bind_frag_data_location(sh, @intCast(i), name);
                c.g_free(name);
            }
        } else {
            _ = c.g_string_append(s, "out vec4 fragColor;\n");
            shader.gst_gl_shader_bind_frag_data_location(sh, 0, "fragColor");
        }
    }
    const varying: [*:0]const u8 = if ((es and ver >= c.GST_GLSL_VERSION_300) or (core and ver >= c.GST_GLSL_VERSION_150)) "in" else "varying";
    c.g_string_append_printf(s, "\n%s vec2 v_texcoord;\nvoid main() {\nvec4 l, r;\n", varying);
    _ = c.g_string_append(s, INPUT);
    _ = c.g_string_append(s, out_str);
    _ = c.g_string_append(s, "\n}");
    const src = c.g_string_free(s, 0);
    var v2 = ver;
    var p2 = prof;
    const r = glsl.mangle(src, c.GL_FRAGMENT_SHADER, c.GST_GL_TEXTURE_TARGET_2D, v[0].from_texture_target, v[0].context, &v2, &p2);
    c.g_free(src);
    return r;
}

fn bindBuffer(v: OView) void {
    const gl = vt(v[0].context);
    const p = pv(v);
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, p.ibo);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vbo);
    gl.VertexAttribPointer.?(p.attr_pos, 3, c.GL_FLOAT, c.GL_FALSE, 5 * @sizeOf(c.GLfloat), null);
    gl.VertexAttribPointer.?(p.attr_tex, 2, c.GL_FLOAT, c.GL_FALSE, 5 * @sizeOf(c.GLfloat), @ptrFromInt(3 * @sizeOf(c.GLfloat)));
    gl.EnableVertexAttribArray.?(p.attr_pos);
    gl.EnableVertexAttribArray.?(p.attr_tex);
}

fn unbindBuffer(v: OView) void {
    const gl = vt(v[0].context);
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DisableVertexAttribArray.?(pv(v).attr_pos);
    gl.DisableVertexAttribArray.?(pv(v).attr_tex);
}

fn flagDiffers(a: Flags, b: Flags, f: c_int) bool {
    const m: Flags = @bitCast(f);
    return (a & m) != (b & m);
}

fn dropShader(v: OView) bool {
    c.gst_object_unref(v[0].shader);
    v[0].shader = null;
    return false;
}

fn buildShader(v: OView, in_mode: Mode, out_mode: Mode) bool {
    var ver: c.GstGLSLVersion = 0;
    var prof: c.GstGLSLProfile = 0;
    var err: [*c]c.GError = null;
    v[0].shader = shader.gst_gl_shader_new(v[0].context);
    const vsrc = glsl.mangle(shaderstrings.gst_gl_shader_string_vertex_mat4_vertex_transform, c.GL_VERTEX_SHADER, c.GST_GL_TEXTURE_TARGET_2D, v[0].from_texture_target, v[0].context, &ver, &prof);
    const vp = glsl.gst_glsl_version_profile_to_string(ver, prof);
    const header = c.g_strdup_printf("#version %s\n", vp);
    c.g_free(vp);
    var strs = [2][*c]const u8{ header, vsrc };
    const vert = glslstage.gst_glsl_stage_new_with_strings(v[0].context, c.GL_VERTEX_SHADER, ver, prof, 2, &strs);
    c.g_free(vsrc);
    if (shader.gst_gl_shader_compile_attach_stage(v[0].shader, vert, &err) == 0) {
        c.g_free(header);
        return dropShader(v);
    }
    const fsrc = fragmentSource(v, v[0].shader, in_mode, out_mode, ver, prof);
    strs[1] = fsrc;
    const frag = glslstage.gst_glsl_stage_new_with_strings(v[0].context, c.GL_FRAGMENT_SHADER, ver, prof, 2, &strs);
    c.g_free(header);
    if (shader.gst_gl_shader_compile_attach_stage(v[0].shader, frag, &err) == 0) {
        c.g_free(fsrc);
        return dropShader(v);
    }
    c.g_free(fsrc);
    if (shader.gst_gl_shader_link(v[0].shader, &err) == 0) return dropShader(v);
    return true;
}

fn initConvert(v: OView) bool {
    const p = pv(v);
    const in_mode = p.input_mode;
    const out_mode = p.output_mode;
    const in_flags = p.input_flags;
    const out_flags = p.output_flags;
    var scale = [2][2]f32{ .{ 1, 1 }, .{ 1, 1 } };
    var off = [2][2]f32{ .{ 0, 0 }, .{ 0, 0 } };
    const gl = vt(v[0].context);
    if (v[0].reconfigure != 0) gst_gl_view_convert_reset(v);
    if (v[0].initted != 0) return true;
    if (gl.CreateProgramObject == null and gl.CreateProgram == null) return false;
    if ((out_mode == SEPARATED or out_mode == FBF) and gl.DrawBuffers == null) return false;
    const swap = flagDiffers(in_flags, out_flags, c.GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_VIEW_FIRST);
    const li: usize = if (swap) 1 else 0;
    const ri: usize = 1 - li;
    if (in_mode == c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE or in_mode == c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE_QUINCUNX) {
        off[ri][0] += 0.5 * scale[ri][0];
        scale[0][0] *= 0.5;
        scale[1][0] *= 0.5;
    } else if (in_mode == c.GST_VIDEO_MULTIVIEW_MODE_TOP_BOTTOM) {
        off[ri][1] += 0.5 * scale[ri][1];
        scale[0][1] *= 0.5;
        scale[1][1] *= 0.5;
    }
    const flips = [_]struct { f: c_int, view: usize, axis: usize }{
        .{ .f = c.GST_VIDEO_MULTIVIEW_FLAGS_LEFT_FLIPPED, .view = li, .axis = 1 },
        .{ .f = c.GST_VIDEO_MULTIVIEW_FLAGS_LEFT_FLOPPED, .view = li, .axis = 0 },
        .{ .f = c.GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_FLIPPED, .view = ri, .axis = 1 },
        .{ .f = c.GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_FLOPPED, .view = ri, .axis = 0 },
    };
    for (flips) |fl| {
        if (flagDiffers(in_flags, out_flags, fl.f)) {
            off[fl.view][fl.axis] += scale[fl.view][fl.axis];
            scale[fl.view][fl.axis] *= -1.0;
        }
    }
    if (out_mode == c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE or out_mode == c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE_QUINCUNX) {
        off[1][0] -= scale[1][0];
        scale[0][0] *= 2.0;
        scale[1][0] *= 2.0;
    } else if (out_mode == c.GST_VIDEO_MULTIVIEW_MODE_TOP_BOTTOM) {
        off[1][1] -= scale[1][1];
        scale[0][1] *= 2.0;
        scale[1][1] *= 2.0;
    }
    if (!buildShader(v, in_mode, out_mode)) return false;
    const sh = v[0].shader;
    p.attr_pos = @bitCast(shader.gst_gl_shader_get_attribute_location(sh, "a_position"));
    p.attr_tex = @bitCast(shader.gst_gl_shader_get_attribute_location(sh, "a_texcoord"));
    shader.gst_gl_shader_use(sh);
    shader.gst_gl_shader_set_uniform_2fv(sh, "tex_scale", 2, &scale[0]);
    shader.gst_gl_shader_set_uniform_2fv(sh, "offsets", 2, &off[0]);
    shader.gst_gl_shader_set_uniform_1f(sh, "width", @floatFromInt(v[0].out_info.width));
    shader.gst_gl_shader_set_uniform_1f(sh, "height", @floatFromInt(v[0].out_info.height));
    shader.gst_gl_shader_set_uniform_matrix_3fv(sh, "downmix", 2, 0, &DOWNMIX[@intCast(v[0].downmix_mode)][0][0]);
    shader.gst_gl_shader_set_uniform_matrix_4fv(sh, "u_transformation", 1, 0, &IDENTITY);
    if (in_mode == SEPARATED or in_mode == FBF) {
        shader.gst_gl_shader_set_uniform_1i(sh, "tex_l", @intCast(li));
        shader.gst_gl_shader_set_uniform_1i(sh, "tex_r", @intCast(ri));
    } else {
        shader.gst_gl_shader_set_uniform_1i(sh, "tex_l", 0);
        shader.gst_gl_shader_set_uniform_1i(sh, "tex_r", 0);
    }
    shader.gst_gl_context_clear_shader(v[0].context);
    v[0].fbo = framebuffer.gst_gl_framebuffer_new_with_default_depth(v[0].context, @intCast(v[0].out_info.width), @intCast(v[0].out_info.height));
    if (v[0].fbo == null) return false;
    if (p.vbo == 0) {
        if (gl.GenVertexArrays) |gen| {
            gen(1, &p.vao);
            gl.BindVertexArray.?(p.vao);
        }
        gl.GenBuffers.?(1, &p.vbo);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, p.vbo);
        gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(VERTICES)), &VERTICES, c.GL_STATIC_DRAW);
        gl.GenBuffers.?(1, &p.ibo);
        gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, p.ibo);
        gl.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(INDICES)), &INDICES, c.GL_STATIC_DRAW);
        if (gl.GenVertexArrays != null) {
            bindBuffer(v);
            gl.BindVertexArray.?(0);
        }
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
        gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    }
    v[0].initted = 1;
    return true;
}

fn multiView(mode: Mode) bool {
    return mode == SEPARATED or mode == FBF;
}

fn draw(ctx: OCtx, v: OView) bool {
    const p = pv(v);
    const gl = vt(ctx);
    const rts = [3]c.GLenum{ c.GL_COLOR_ATTACHMENT0, c.GL_COLOR_ATTACHMENT1, c.GL_COLOR_ATTACHMENT2 };
    const target = format.gst_gl_texture_target_to_gl(v[0].from_texture_target);
    framebuffer.gst_gl_framebuffer_bind(v[0].fbo);
    const views: c.gint = if (multiView(p.output_mode)) v[0].out_info.views else 1;
    var i: c.gint = 0;
    while (i < views) : (i += 1) framebuffer.gst_gl_framebuffer_attach(v[0].fbo, @intCast(c.GL_COLOR_ATTACHMENT0 + i), @ptrCast(p.out_tex[@intCast(i)]));
    if (gl.DrawBuffers) |db| db(views, &rts) else if (gl.DrawBuffer) |d| d(c.GL_COLOR_ATTACHMENT0);
    var w: c.guint = 0;
    var h: c.guint = 0;
    framebuffer.gst_gl_framebuffer_get_effective_dimensions(v[0].fbo, &w, &h);
    gl.Viewport.?(0, 0, @intCast(w), @intCast(h));
    shader.gst_gl_shader_use(v[0].shader);
    var m: [16]f32 = undefined;
    utils.gst_gl_get_affine_transformation_meta_as_ndc(@ptrCast(@alignCast(c.gst_buffer_get_meta(p.primary_in, c.gst_video_affine_transformation_meta_api_get_type()))), &m);
    shader.gst_gl_shader_set_uniform_matrix_4fv(v[0].shader, "u_transformation", 1, 0, &m);
    if (gl.BindVertexArray) |b| b(p.vao);
    bindBuffer(v);
    if (multiView(p.input_mode)) {
        if (p.in_tex[1] == null) return false;
        gl.ActiveTexture.?(c.GL_TEXTURE1);
        gl.BindTexture.?(target, p.in_tex[1][0].tex_id);
    }
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(target, p.in_tex[0][0].tex_id);
    gl.ClearColor.?(0, 0, 0, 1);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
    gl.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    if (gl.BindVertexArray) |b| b(0) else unbindBuffer(v);
    if (gl.DrawBuffer) |d| d(c.GL_COLOR_ATTACHMENT0);
    shader.gst_gl_context_clear_shader(ctx);
    framebuffer.gst_gl_context_clear_framebuffer(ctx);
    return true;
}

fn genBuffer(v: OView, target: *OBuf) bool {
    target.* = c.gst_buffer_new();
    const alloc = memory.gst_gl_memory_allocator_get_default(v[0].context);
    const params = memory.gst_gl_video_allocation_params_new(v[0].context, null, &v[0].out_info, 0, null, v[0].to_texture_target, 0);
    if (memory.gst_gl_memory_setup_buffer(alloc, target.*, params, null, null, 0) == 0) {
        basememory.gst_gl_allocation_params_free(@ptrCast(params));
        c.gst_object_unref(alloc);
        return false;
    }
    c.gst_object_unref(alloc);
    const info = &v[0].out_info;
    const meta = c.gst_buffer_add_video_meta_full(target.*, 0, info.finfo[0].format, @intCast(info.width), @intCast(info.height), info.finfo[0].n_planes, &info.offset, &info.stride);
    if (params[0].valign != null) _ = c.gst_video_meta_set_alignment(meta, params[0].valign[0]);
    basememory.gst_gl_allocation_params_free(@ptrCast(params));
    return true;
}

fn peekMem(b: OBuf, i: c.guint) OMem {
    return @ptrCast(@alignCast(c.gst_buffer_peek_memory(b, i)));
}

fn mem(m: anytype) [*c]c.GstMemory {
    return @ptrCast(@alignCast(m));
}

fn waitSync(b: OBuf, ctx: OCtx) void {
    if (b == null) return;
    const sm = c.gst_buffer_get_meta(b, syncmeta.gst_gl_sync_meta_api_get_type());
    if (sm != null) syncmeta.gst_gl_sync_meta_wait(@ptrCast(@alignCast(sm)), ctx);
}

fn addSync(b: OBuf, ctx: OCtx) void {
    if (b == null) return;
    const sm = syncmeta.gst_buffer_add_gl_sync_meta(ctx, b);
    if (sm != null) syncmeta.gst_gl_sync_meta_set_sync_point(sm, ctx);
}

fn convertGl(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const v = vc(data);
    const p = pv(v);
    const fname = "_do_view_convert";
    if (!check.that(p.primary_out == null, fname, "priv->primary_out == NULL")) return;
    if (!check.that(p.aux_out == null, fname, "priv->auxilliary_out == NULL")) return;
    const ow: c.guint = @intCast(v[0].out_info.width);
    const oh: c.guint = @intCast(v[0].out_info.height);
    const in_views: usize = if (multiView(p.input_mode)) @intCast(v[0].in_info.views) else 1;
    const out_views: usize = if (multiView(p.output_mode)) @intCast(v[0].out_info.views) else 1;
    if (!initConvert(v) or !genBuffer(v, &p.primary_out)) {
        p.result = 0;
        return;
    }
    if (p.output_mode == FBF and !genBuffer(v, &p.aux_out)) {
        p.result = 0;
        return;
    }
    var in_map: [c.GST_VIDEO_MAX_PLANES]c.GstMapInfo = undefined;
    var out_map: [c.GST_VIDEO_MAX_PLANES]c.GstMapInfo = undefined;
    var dest: [c.GST_VIDEO_MAX_PLANES]OMem = undefined;
    var ok = true;
    var i: usize = 0;
    var j: usize = 0;
    run: {
        while (i < in_views) : (i += 1) {
            p.in_tex[i] = if (p.input_mode == FBF and i > 0) peekMem(p.aux_in, 0) else peekMem(p.primary_in, @intCast(i));
            if (memory.gst_is_gl_memory(mem(p.in_tex[i])) == 0 or c.gst_memory_map(mem(p.in_tex[i]), &in_map[i], c.GST_MAP_READ | c.GST_MAP_GL) == 0) {
                ok = false;
                break :run;
            }
        }
        while (j < out_views) : (j += 1) {
            const out = if (j > 0 and p.output_mode == FBF) peekMem(p.aux_out, 0) else peekMem(p.primary_out, @intCast(j));
            dest[j] = out;
            if (memory.gst_is_gl_memory(mem(out)) == 0) {
                ok = false;
                break :run;
            }
            const w = memory.gst_gl_memory_get_texture_width(out);
            const h = memory.gst_gl_memory_get_texture_height(out);
            if (out[0].tex_format == c.GST_GL_LUMINANCE or out[0].tex_format == c.GST_GL_LUMINANCE_ALPHA or ow != w or oh != h) {
                if (p.out_tex[j] == null) {
                    var ti: c.GstVideoInfo = undefined;
                    _ = c.gst_video_info_set_format(&ti, c.GST_VIDEO_FORMAT_RGBA, ow, oh);
                    const alloc = memory.gst_gl_memory_allocator_get_default(ctx);
                    const params = memory.gst_gl_video_allocation_params_new(ctx, null, &ti, 0, null, v[0].to_texture_target, c.GST_GL_RGBA);
                    p.out_tex[j] = @ptrCast(@alignCast(basememory.gst_gl_base_memory_alloc(@ptrCast(alloc), @ptrCast(params))));
                    basememory.gst_gl_allocation_params_free(@ptrCast(params));
                    c.gst_object_unref(alloc);
                }
            } else p.out_tex[j] = out;
            if (c.gst_memory_map(mem(p.out_tex[j]), &out_map[j], c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) {
                ok = false;
                break :run;
            }
        }
        p.n_out_tex = @intCast(out_views);
        waitSync(p.primary_in, ctx);
        waitSync(p.aux_in, ctx);
        if (!draw(ctx, v)) ok = false;
    }
    while (j > 0) {
        j -= 1;
        const out = dest[j];
        const w = memory.gst_gl_memory_get_texture_width(out);
        const h = memory.gst_gl_memory_get_texture_height(out);
        c.gst_memory_unmap(mem(p.out_tex[j]), &out_map[j]);
        if (out != p.out_tex[j]) {
            var from: c.GstMapInfo = undefined;
            var to: c.GstMapInfo = undefined;
            if (c.gst_memory_map(mem(p.out_tex[j]), &from, c.GST_MAP_READ | c.GST_MAP_GL) == 0 or c.gst_memory_map(mem(out), &to, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) {
                ok = false;
                continue;
            }
            _ = memory.gst_gl_memory_copy_into(p.out_tex[j], out[0].tex_id, v[0].to_texture_target, out[0].tex_format, @intCast(w), @intCast(h));
            c.gst_memory_unmap(mem(out), &to);
        }
        p.out_tex[j] = null;
    }
    while (i > 0) {
        i -= 1;
        c.gst_memory_unmap(mem(p.in_tex[i]), &in_map[i]);
    }
    if (!ok) {
        clearBuf(&p.primary_out);
        clearBuf(&p.aux_out);
    }
    addSync(p.primary_out, ctx);
    addSync(p.aux_out, ctx);
    p.result = @intFromBool(ok);
}

fn bufFlags(b: OBuf) *c.guint {
    return &@as(*c.GstMiniObject, @ptrCast(b)).flags;
}

pub export fn gst_gl_view_convert_submit_input_buffer(v: OView, discont: c.gboolean, input: OBuf) c.GstFlowReturn {
    const p = pv(v);
    if (discont != 0) {
        clearBuf(&p.primary_in);
        clearBuf(&p.aux_in);
    }
    var mode = v[0].input_mode_override;
    if (mode == NONE) mode = v[0].in_info.ABI.abi.multiview_mode;
    var target = &p.primary_in;
    if (mode == FBF and bufFlags(input).* & c.GST_VIDEO_BUFFER_FLAG_FIRST_IN_BUNDLE == 0) target = &p.aux_in;
    if (target.* != null) c.gst_buffer_unref(target.*);
    target.* = input;
    return c.GST_FLOW_OK;
}

fn copyOverlays(dest: OBuf, src: OBuf) void {
    var state: c.gpointer = null;
    while (true) {
        const m = c.gst_buffer_iterate_meta_filtered(src, &state, c.gst_video_overlay_composition_meta_api_get_type());
        if (m == null) break;
        const cm: *c.GstVideoOverlayCompositionMeta = @ptrCast(@alignCast(m));
        _ = c.gst_buffer_add_video_overlay_composition_meta(dest, cm.overlay);
    }
}

pub export fn gst_gl_view_convert_get_output(v: OView, out_ptr: [*c]OBuf) c.GstFlowReturn {
    const fname = "gst_gl_view_convert_get_output";
    if (!check.that(isView(v), fname, "GST_IS_GL_VIEW_CONVERT (viewconvert)")) return c.GST_FLOW_ERROR;
    if (!check.that(context.isContext(v[0].context), fname, "GST_IS_GL_CONTEXT (viewconvert->context)")) return c.GST_FLOW_ERROR;
    const p = pv(v);
    var out: OBuf = null;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    objLock(v);
    defer {
        objUnlock(v);
        out_ptr[0] = out;
    }
    if (p.primary_out != null) {
        out = p.primary_out;
        p.primary_out = null;
        return ret;
    }
    if (p.aux_out != null) {
        out = p.aux_out;
        p.aux_out = null;
        return ret;
    }
    if (p.primary_in == null) return ret;
    var in_mode = v[0].input_mode_override;
    var in_flags = v[0].input_flags_override;
    if (in_mode == NONE) {
        in_mode = v[0].in_info.ABI.abi.multiview_mode;
        in_flags = v[0].in_info.ABI.abi.multiview_flags;
    }
    if (in_mode == FBF and p.aux_in == null) return ret;
    p.input_mode = in_mode;
    p.input_flags = in_flags;
    p.output_mode = v[0].out_info.ABI.abi.multiview_mode;
    p.output_flags = v[0].out_info.ABI.abi.multiview_flags;
    defer {
        clearBuf(&p.primary_in);
        clearBuf(&p.aux_in);
    }
    if (p.input_mode == p.output_mode and p.input_flags == p.output_flags and v[0].in_info.width == v[0].out_info.width and v[0].in_info.height == v[0].out_info.height and v[0].from_texture_target == v[0].to_texture_target) {
        out = c.gst_buffer_ref(p.primary_in);
        if (in_mode == FBF) p.aux_out = c.gst_buffer_ref(p.aux_in);
        return ret;
    }
    if (v[0].to_texture_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) {
        ret = c.GST_FLOW_ERROR;
        return ret;
    }
    c.gst_gl_context_thread_add(v[0].context, convertGl, v);
    if (p.result == 0) {
        if (p.primary_out != null) c.gst_object_unref(p.primary_out);
        if (p.aux_out != null) c.gst_object_unref(p.aux_out);
        p.primary_out = null;
        p.aux_out = null;
        ret = c.GST_FLOW_ERROR;
        return ret;
    }
    out = p.primary_out;
    if (out != null) {
        _ = c.gst_buffer_copy_into(out, p.primary_in, c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_TIMESTAMPS, 0, std.math.maxInt(c.gsize));
        bufFlags(out).* |= c.GST_VIDEO_BUFFER_FLAG_FIRST_IN_BUNDLE | c.GST_VIDEO_BUFFER_FLAG_MULTIPLE_VIEW;
        copyOverlays(out, p.primary_in);
    }
    if (p.aux_out != null) {
        _ = c.gst_buffer_copy_into(p.aux_out, p.primary_out, c.GST_BUFFER_COPY_FLAGS, 0, std.math.maxInt(c.gsize));
        bufFlags(p.aux_out).* &= ~@as(c.guint, c.GST_VIDEO_BUFFER_FLAG_FIRST_IN_BUNDLE);
        copyOverlays(p.aux_out, p.primary_out);
    }
    p.primary_out = null;
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    const mt = c.gst_video_multiview_mode_get_type();
    const ft = c.gst_video_multiview_flags_get_type();
    c.g_object_class_install_property(oc, PROP_INPUT_LAYOUT, c.g_param_spec_enum("input-mode-override", "Input Multiview Mode Override", "Override any input information about multiview layout", mt, NONE, RW));
    c.g_object_class_install_property(oc, PROP_INPUT_FLAGS, c.g_param_spec_flags("input-flags-override", "Input Multiview Flags Override", "Override any input information about multiview layout flags", ft, c.GST_VIDEO_MULTIVIEW_FLAGS_NONE, RW));
    c.g_object_class_install_property(oc, PROP_OUTPUT_LAYOUT, c.g_param_spec_enum("output-mode-override", "Output Multiview Mode Override", "Override automatic output mode selection for multiview layout", mt, NONE, RW));
    c.g_object_class_install_property(oc, PROP_OUTPUT_FLAGS, c.g_param_spec_flags("output-flags-override", "Output Multiview Flags Override", "Override automatic negotiation for output multiview layout flags", ft, c.GST_VIDEO_MULTIVIEW_FLAGS_NONE, RW));
    c.g_object_class_install_property(oc, PROP_DOWNMIX, c.g_param_spec_enum("downmix-mode", "Mode for mono downmixed output", "Output anaglyph type to generate when downmixing to mono", enums.gst_gl_stereo_downmix_get_type(), c.GST_GL_STEREO_DOWNMIX_ANAGLYPH_GREEN_MAGENTA_DUBOIS, RW));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const v = vc(inst);
    v[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(v).* = std.mem.zeroes(Priv);
    v[0].shader = null;
    v[0].downmix_mode = c.GST_GL_STEREO_DOWNMIX_ANAGLYPH_GREEN_MAGENTA_DUBOIS;
    pv(v).input_mode = NONE;
    pv(v).output_mode = NONE;
    v[0].input_mode_override = NONE;
    v[0].output_mode_override = NONE;
    v[0].input_flags_override = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE;
    v[0].output_flags_override = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE;
    c.gst_video_info_init(&v[0].in_info);
    c.gst_video_info_init(&v[0].out_info);
}

pub export fn gst_gl_view_convert_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLViewConvert", Class, View, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glviewconvert", 0, "glviewconvert object");
            return t;
        }
    }.f);
}
