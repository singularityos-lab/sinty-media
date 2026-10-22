const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const glsl = @import("glsl.zig");
const strings = @import("shaderstrings.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Stage = c.GstGLSLStage;
const OStage = [*c]Stage;
const OCtx = [*c]c.GstGLContext;

const GEOMETRY = 0x8DD9;
const COMPUTE = 0x91B9;
const TESS_CONTROL = 0x8E88;
const TESS_EVALUATION = 0x8E87;
const ES2_HEADER: [*c]const u8 = "#version 100\n";

pub const Priv = struct {
    vtable: glsl.Funcs,
    type: c.GLenum,
    handle: c.GLuint,
    version: c.GstGLSLVersion,
    profile: c.GstGLSLProfile,
    strings: [*c][*c]u8,
    n_strings: c.gint,
    compiled: bool,
};

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

pub fn pv(s: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Stage, @ptrCast(@alignCast(s))).priv));
}

pub fn isStage(s: anytype) bool {
    return gtype.instanceOf(s, gst_glsl_stage_get_type());
}

fn valid(s: anytype, comptime fname: []const u8) bool {
    return check.that(isStage(s), fname, "GST_IS_GLSL_STAGE (stage)");
}

fn deleteShader(_: OCtx, data: c.gpointer) callconv(.c) void {
    const p = pv(data);
    if (p.handle != 0) p.vtable.DeleteShader.?(p.handle);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Stage = @ptrCast(@alignCast(o));
    const p = pv(s);
    c.gst_gl_context_thread_add(s.context, deleteShader, s);
    if (s.context != null) {
        c.gst_object_unref(s.context);
        s.context = null;
    }
    var i: c.gint = 0;
    while (i < p.n_strings) : (i += 1) c.g_free(p.strings[@intCast(i)]);
    c.g_free(@ptrCast(p.strings));
    p.strings = null;
    parent.?.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, _: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec);
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/gstglslstage.c", @as(c_int, 104), "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Stage = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(s).* = std.mem.zeroes(Priv);
}

pub export fn gst_glsl_stage_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLSLStage", c.GstGLSLStageClass, Stage, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glslstage", 0, "GLSL Stage");
            return t;
        }
    }.f);
}

fn validType(t: c.guint) bool {
    return t == c.GL_VERTEX_SHADER or t == c.GL_FRAGMENT_SHADER or t == TESS_CONTROL or t == TESS_EVALUATION or t == GEOMETRY or t == COMPUTE;
}

fn typeName(t: c.GLenum) [*c]const u8 {
    return switch (t) {
        c.GL_VERTEX_SHADER => "vertex",
        c.GL_FRAGMENT_SHADER => "fragment",
        TESS_CONTROL => "tessellation control",
        TESS_EVALUATION => "tessellation evaluation",
        GEOMETRY => "geometry",
        COMPUTE => "compute",
        else => "unknown",
    };
}

pub export fn gst_glsl_stage_new_with_strings(ctx: OCtx, t: c.guint, v: c.GstGLSLVersion, p: c.GstGLSLProfile, n: c.gint, str: [*c][*c]const u8) OStage {
    const fname = "gst_glsl_stage_new_with_strings";
    if (!check.that(context.isContext(ctx), fname, "GST_IS_GL_CONTEXT (context)")) return null;
    if (!check.that(validType(t), fname, "_is_valid_shader_type (type)")) return null;
    const s: OStage = @ptrCast(@alignCast(c.g_object_new(gst_glsl_stage_get_type(), @as([*c]const u8, null))));
    if (!glsl.fillFuncs(&pv(s).vtable, ctx)) {
        c.gst_object_unref(s);
        return null;
    }
    s[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    pv(s).type = t;
    if (gst_glsl_stage_set_strings(s, v, p, n, str) == 0) {
        c.gst_object_unref(s);
        return null;
    }
    return s;
}

pub export fn gst_glsl_stage_new_with_string(ctx: OCtx, t: c.guint, v: c.GstGLSLVersion, p: c.GstGLSLProfile, str: [*c]const u8) OStage {
    var s = str;
    return gst_glsl_stage_new_with_strings(ctx, t, v, p, 1, &s);
}

pub export fn gst_glsl_stage_new(ctx: OCtx, t: c.guint) OStage {
    return gst_glsl_stage_new_with_string(ctx, t, c.GST_GLSL_VERSION_NONE, c.GST_GLSL_PROFILE_NONE, null);
}

pub export fn gst_glsl_stage_new_default_vertex(ctx: OCtx) OStage {
    return gst_glsl_stage_new_with_string(ctx, c.GL_VERTEX_SHADER, c.GST_GLSL_VERSION_NONE, c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY, strings.gst_gl_shader_string_vertex_default);
}

pub export fn gst_glsl_stage_new_default_fragment(ctx: OCtx) OStage {
    const p: c.GstGLSLProfile = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;
    const frag = strings.gst_gl_shader_string_fragment_get_default(ctx, c.GST_GLSL_VERSION_NONE, p);
    defer c.g_free(frag);
    return gst_glsl_stage_new_with_string(ctx, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, p, frag);
}

pub export fn gst_glsl_stage_set_strings(s: OStage, v: c.GstGLSLVersion, p: c.GstGLSLProfile, n: c.gint, str: [*c][*c]const u8) c.gboolean {
    const fname = "gst_glsl_stage_set_strings";
    if (!valid(s, fname)) return 0;
    if (!check.that(n > 0, fname, "n_strings > 0")) return 0;
    if (!check.that(str != null, fname, "str != NULL")) return 0;
    if (glsl.gst_gl_context_supports_glsl_profile_version(s[0].context, v, p) == 0) return 0;
    const pr = pv(s);
    pr.version = v;
    pr.profile = p;
    var i: c.gint = 0;
    while (i < pr.n_strings) : (i += 1) c.g_free(pr.strings[@intCast(i)]);
    if (pr.n_strings < n) {
        c.g_free(@ptrCast(pr.strings));
        pr.strings = @ptrCast(@alignCast(c.g_malloc0(@sizeOf([*c]u8) * @as(usize, @intCast(n)))));
    }
    i = 0;
    while (i < n) : (i += 1) pr.strings[@intCast(i)] = c.g_strdup(str[@intCast(i)]);
    pr.n_strings = n;
    return 1;
}

pub export fn gst_glsl_stage_get_shader_type(s: OStage) c.guint {
    if (!valid(s, "gst_glsl_stage_get_shader_type")) return 0;
    return pv(s).type;
}

pub export fn gst_glsl_stage_get_handle(s: OStage) c.guint {
    const fname = "gst_glsl_stage_get_handle";
    if (!valid(s, fname)) return 0;
    if (!check.that(pv(s).compiled, fname, "stage->priv->compiled")) return 0;
    return pv(s).handle;
}

pub export fn gst_glsl_stage_get_version(s: OStage) c.GstGLSLVersion {
    if (!valid(s, "gst_glsl_stage_get_version")) return 0;
    return pv(s).version;
}

pub export fn gst_glsl_stage_get_profile(s: OStage) c.GstGLSLProfile {
    if (!valid(s, "gst_glsl_stage_get_profile")) return 0;
    return pv(s).profile;
}

const Compile = struct {
    stage: OStage,
    err: [*c][*c]c.GError,
    result: c.gboolean,
};

fn compileGl(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const d: *Compile = @ptrCast(@alignCast(data));
    const p = pv(d.stage);
    const gl = &ctx[0].gl_vtable[0];
    if (p.compiled) {
        d.result = 1;
        return;
    }
    if (p.handle == 0) p.handle = p.vtable.CreateShader.?(p.type);
    if (p.handle == 0) {
        c.g_set_error(d.err, glsl.gst_glsl_error_quark(), c.GST_GLSL_ERROR_COMPILE, "Failed to create shader object");
        d.result = 0;
        return;
    }
    var n: c.gint = p.n_strings;
    var header = false;
    if (context.gst_gl_context_check_gl_version(d.stage[0].context, c.GST_GL_API_OPENGL3, 3, 0) != 0 and p.profile & c.GST_GLSL_PROFILE_ES != 0 and glsl.findVersion(p.strings[0]) == null) {
        header = true;
        n += 1;
    }
    const src: [*c][*c]const u8 = @ptrCast(@alignCast(c.g_malloc0(@sizeOf([*c]u8) * @as(usize, @intCast(n)))));
    var i: usize = 0;
    if (header) {
        src[0] = ES2_HEADER;
        i = 1;
    }
    var j: usize = 0;
    while (j < @as(usize, @intCast(p.n_strings))) : ({
        i += 1;
        j += 1;
    }) src[i] = p.strings[j];
    gl.ShaderSource.?(p.handle, n, src, null);
    gl.CompileShader.?(p.handle);
    c.g_free(@ptrCast(src));
    var status: c.GLint = c.GL_FALSE;
    p.vtable.GetShaderiv.?(p.handle, c.GL_COMPILE_STATUS, &status);
    var buf: [2048]u8 = undefined;
    var len: c.GLsizei = 0;
    p.vtable.GetShaderInfoLog.?(p.handle, buf.len - 1, &len, &buf);
    buf[@intCast(len)] = 0;
    if (status != c.GL_TRUE) {
        c.g_set_error(d.err, glsl.gst_glsl_error_quark(), c.GST_GLSL_ERROR_COMPILE, "%s shader compilation failed:%s", typeName(p.type), &buf);
        p.vtable.DeleteShader.?(p.handle);
        d.result = 0;
        return;
    }
    d.result = 1;
}

pub export fn gst_glsl_stage_compile(s: OStage, err: [*c][*c]c.GError) c.gboolean {
    if (!valid(s, "gst_glsl_stage_compile")) return 0;
    if (pv(s).strings == null) {
        c.g_set_error(err, glsl.gst_glsl_error_quark(), c.GST_GLSL_ERROR_COMPILE, "No shader source to compile");
        return 0;
    }
    var d = Compile{ .stage = s, .err = err, .result = 0 };
    c.gst_gl_context_thread_add(s[0].context, compileGl, &d);
    pv(s).compiled = true;
    return d.result;
}
