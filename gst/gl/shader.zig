const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const va = @import("../varargs.zig");
const context = @import("context.zig");
const glsl = @import("glsl.zig");
const stage = @import("glslstage.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Shader = c.GstGLShader;
const OShader = [*c]Shader;
const OStage = [*c]c.GstGLSLStage;
const OCtx = [*c]c.GstGLContext;

const PROP_LINKED = 1;

const Priv = struct {
    program: c.GLuint,
    stages: ?*c.GList,
    linked: bool,
    uniforms: ?*c.GHashTable,
    vtable: glsl.Funcs,
};

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn pv(s: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Shader, @ptrCast(@alignCast(s))).priv));
}

fn isShader(s: anytype) bool {
    return gtype.instanceOf(s, gst_gl_shader_get_type());
}

fn valid(s: anytype, comptime fname: []const u8) bool {
    return check.that(isShader(s), fname, "GST_IS_GL_SHADER (shader)");
}

fn validStage(s: anytype, comptime fname: []const u8) bool {
    return check.that(stage.isStage(s), fname, "GST_IS_GLSL_STAGE (stage)");
}

fn lock(s: anytype) void {
    c.g_mutex_lock(&@as(*Shader, @ptrCast(@alignCast(s))).parent.lock);
}

fn unlock(s: anytype) void {
    c.g_mutex_unlock(&@as(*Shader, @ptrCast(@alignCast(s))).parent.lock);
}

fn cleanup(_: OCtx, data: c.gpointer) callconv(.c) void {
    const s: OShader = @ptrCast(@alignCast(data));
    lock(s);
    gst_gl_shader_release_unlocked(s);
    if (pv(s).program != 0) pv(s).vtable.DeleteProgram.?(pv(s).program);
    unlock(s);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Shader = @ptrCast(@alignCast(o));
    c.gst_gl_context_thread_add(s.context, cleanup, s);
    pv(s).program = 0;
    c.g_hash_table_destroy(pv(s).uniforms);
    if (s.context != null) {
        c.gst_object_unref(s.context);
        s.context = null;
    }
    parent.?.finalize.?(o);
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/gstglshader.c", line, "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 135);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_LINKED) {
        c.g_value_set_boolean(v, @intFromBool(pv(o).linked));
        return;
    }
    warnInvalid(o, id, spec, 151);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_LINKED, c.g_param_spec_boolean("linked", "Linked", "Shader link status", 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Shader = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(s).* = std.mem.zeroes(Priv);
    pv(s).uniforms = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, null);
}

pub export fn gst_gl_shader_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLShader", c.GstGLShaderClass, Shader, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glshader", 0, "shader");
            return t;
        }
    }.f);
}

fn uniformLocation(s: OShader, name: [*c]const u8) c.GLint {
    const p = pv(s);
    if (!check.that(p.linked, "_get_uniform_location", "priv->linked")) return 0;
    var value: c.gpointer = null;
    if (c.g_hash_table_lookup_extended(p.uniforms, name, null, &value) == 0) {
        const loc = s[0].context[0].gl_vtable[0].GetUniformLocation.?(p.program, name);
        _ = c.g_hash_table_insert(p.uniforms, c.g_strdup(name), @ptrFromInt(@as(usize, @bitCast(@as(isize, loc)))));
        return loc;
    }
    return @truncate(@as(isize, @bitCast(@intFromPtr(value))));
}

fn newWithStages(ctx: OCtx, err: [*c][*c]c.GError, ap: *va.VaList) OShader {
    if (!check.that(context.isContext(ctx), "_new_with_stages_va_list", "GST_IS_GL_CONTEXT (context)")) return null;
    const s: OShader = @ptrCast(@alignCast(c.g_object_new(gst_gl_shader_get_type(), @as([*c]const u8, null))));
    _ = c.gst_object_ref_sink(s);
    s[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    var bail = false;
    while (true) {
        const st = @cVaArg(ap, OStage);
        if (st == null) break;
        if (bail) {
            c.gst_object_unref(st);
            continue;
        }
        if (stage.gst_glsl_stage_compile(st, err) == 0) {
            c.gst_object_unref(st);
            bail = true;
            continue;
        }
        if (gst_gl_shader_attach(s, st) == 0) {
            c.g_set_error(err, glsl.gst_glsl_error_quark(), c.GST_GLSL_ERROR_PROGRAM, "Failed to attach stage to program");
            bail = true;
        }
    }
    if (bail) {
        c.gst_object_unref(s);
        return null;
    }
    return s;
}

pub export fn gst_gl_shader_new_link_with_stages(ctx: OCtx, err: [*c][*c]c.GError, ...) callconv(.c) OShader {
    var ap = @cVaStart();
    const s = newWithStages(ctx, err, &ap);
    @cVaEnd(&ap);
    if (s == null) return null;
    if (gst_gl_shader_link(s, err) == 0) return null;
    return s;
}

pub export fn gst_gl_shader_new_with_stages(ctx: OCtx, err: [*c][*c]c.GError, ...) callconv(.c) OShader {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return newWithStages(ctx, err, &ap);
}

pub export fn gst_gl_shader_new(ctx: OCtx) OShader {
    return gst_gl_shader_new_with_stages(ctx, null, @as(OStage, null));
}

pub export fn gst_gl_shader_new_default(ctx: OCtx, err: [*c][*c]c.GError) OShader {
    return gst_gl_shader_new_link_with_stages(ctx, err, stage.gst_glsl_stage_new_default_vertex(ctx), stage.gst_glsl_stage_new_default_fragment(ctx), @as(OStage, null));
}

pub export fn gst_gl_shader_is_linked(s: OShader) c.gboolean {
    if (!valid(s, "gst_gl_shader_is_linked")) return 0;
    lock(s);
    defer unlock(s);
    return @intFromBool(pv(s).linked);
}

fn ensureProgram(s: OShader) bool {
    const p = pv(s);
    if (p.program != 0) return true;
    p.program = p.vtable.CreateProgram.?();
    return p.program != 0;
}

pub export fn gst_gl_shader_get_program_handle(s: OShader) c_int {
    if (!valid(s, "gst_gl_shader_get_program_handle")) return 0;
    lock(s);
    defer unlock(s);
    return @bitCast(pv(s).program);
}

fn assertGl(ok: bool, line: c_int, comptime func: []const u8, comptime expr: [*:0]const u8) void {
    if (!ok) check.assertFail("gstglshader.c", line, func, expr);
}

pub export fn gst_gl_shader_detach_unlocked(s: OShader, st: OStage) void {
    const fname = "gst_gl_shader_detach_unlocked";
    if (!valid(s, fname)) return;
    if (!validStage(st, fname)) return;
    const p = pv(s);
    if (!glsl.fillFuncs(&p.vtable, s[0].context)) return;
    if (p.program == 0) return;
    const elem = c.g_list_find(p.stages, st) orelse return;
    const h = stage.gst_glsl_stage_get_handle(st);
    if (h == 0) return;
    const gl = &s[0].context[0].gl_vtable[0];
    if (gl.IsProgram) |f| assertGl(f(p.program) != 0, 403, "gst_gl_shader_detach_unlocked", "shader->context->gl_vtable->IsProgram (shader->priv->program_handle)");
    if (gl.IsShader) |f| assertGl(f(h) != 0, 406, "gst_gl_shader_detach_unlocked", "shader->context->gl_vtable->IsShader (stage_handle)");
    p.vtable.DetachShader.?(p.program, h);
    p.stages = c.g_list_delete_link(p.stages, elem);
    c.gst_object_unref(st);
}

pub export fn gst_gl_shader_detach(s: OShader, st: OStage) void {
    const fname = "gst_gl_shader_detach";
    if (!valid(s, fname)) return;
    if (!validStage(st, fname)) return;
    lock(s);
    gst_gl_shader_detach_unlocked(s, st);
    unlock(s);
}

fn drop(st: OStage) c.gboolean {
    _ = c.gst_object_ref_sink(st);
    c.gst_object_unref(st);
    return 0;
}

pub export fn gst_gl_shader_attach_unlocked(s: OShader, st: OStage) c.gboolean {
    const fname = "gst_gl_shader_attach_unlocked";
    if (!valid(s, fname)) return 0;
    if (!validStage(st, fname)) return 0;
    const p = pv(s);
    if (!glsl.fillFuncs(&p.vtable, s[0].context)) return drop(st);
    if (!ensureProgram(s)) return drop(st);
    if (c.g_list_find(p.stages, st) != null) {
        _ = drop(st);
        return 1;
    }
    const h = stage.gst_glsl_stage_get_handle(st);
    if (h == 0) return drop(st);
    const gl = &s[0].context[0].gl_vtable[0];
    if (gl.IsProgram) |f| assertGl(f(p.program) != 0, 467, "gst_gl_shader_attach_unlocked", "shader->context->gl_vtable->IsProgram (shader->priv->program_handle)");
    if (gl.IsShader) |f| assertGl(f(h) != 0, 470, "gst_gl_shader_attach_unlocked", "shader->context->gl_vtable->IsShader (stage_handle)");
    p.stages = c.g_list_prepend(p.stages, c.gst_object_ref_sink(st));
    p.vtable.AttachShader.?(p.program, h);
    return 1;
}

pub export fn gst_gl_shader_attach(s: OShader, st: OStage) c.gboolean {
    const fname = "gst_gl_shader_attach";
    if (!valid(s, fname)) return 0;
    if (!validStage(st, fname)) return 0;
    lock(s);
    defer unlock(s);
    return gst_gl_shader_attach_unlocked(s, st);
}

pub export fn gst_gl_shader_compile_attach_stage(s: OShader, st: OStage, err: [*c][*c]c.GError) c.gboolean {
    if (!validStage(st, "gst_gl_shader_compile_attach_stage")) return 0;
    if (stage.gst_glsl_stage_compile(st, err) == 0) return 0;
    if (gst_gl_shader_attach(s, st) == 0) {
        c.g_set_error(err, glsl.gst_glsl_error_quark(), c.GST_GLSL_ERROR_COMPILE, "Failed to attach stage to shader");
        return 0;
    }
    return 1;
}

pub export fn gst_gl_shader_link(s: OShader, err: [*c][*c]c.GError) c.gboolean {
    if (!valid(s, "gst_gl_shader_link")) return 0;
    lock(s);
    const p = pv(s);
    const gl = &s[0].context[0].gl_vtable[0];
    if (p.linked) {
        unlock(s);
        return 1;
    }
    const q = glsl.gst_glsl_error_quark();
    if (!glsl.fillFuncs(&p.vtable, s[0].context)) {
        c.g_set_error(err, q, c.GST_GLSL_ERROR_PROGRAM, "Failed to retrieve required GLSL functions");
        unlock(s);
        return 0;
    }
    if (!ensureProgram(s)) {
        c.g_set_error(err, q, c.GST_GLSL_ERROR_PROGRAM, "Failed to create GL program object");
        unlock(s);
        return 0;
    }
    var e = p.stages;
    while (e) |n| : (e = n.next) {
        const st: OStage = @ptrCast(@alignCast(n.data));
        if (stage.gst_glsl_stage_compile(st, err) == 0) {
            unlock(s);
            return 0;
        }
        if (gst_gl_shader_attach_unlocked(s, st) == 0) {
            c.g_set_error(err, q, c.GST_GLSL_ERROR_COMPILE, "Failed to attach shader %p to program %p", st, s);
            unlock(s);
            return 0;
        }
    }
    gl.LinkProgram.?(p.program);
    var status: c.GLint = c.GL_FALSE;
    p.vtable.GetProgramiv.?(p.program, c.GL_LINK_STATUS, &status);
    var buf: [2048]u8 = undefined;
    var len: c.GLsizei = 0;
    p.vtable.GetProgramInfoLog.?(p.program, buf.len - 1, &len, &buf);
    buf[@intCast(len)] = 0;
    if (status != c.GL_TRUE) {
        c.g_set_error(err, q, c.GST_GLSL_ERROR_LINK, "Shader Linking failed:\n%s", &buf);
        p.linked = false;
        unlock(s);
        return 0;
    }
    p.linked = true;
    unlock(s);
    c.g_object_notify(@ptrCast(s), "linked");
    return 1;
}

pub export fn gst_gl_shader_release_unlocked(s: OShader) void {
    if (!valid(s, "gst_gl_shader_release_unlocked")) return;
    const p = pv(s);
    var e = p.stages;
    while (e) |n| {
        const next = n.next;
        gst_gl_shader_detach_unlocked(s, @ptrCast(@alignCast(n.data)));
        e = next;
    }
    c.g_list_free_full(p.stages, c.gst_object_unref);
    p.stages = null;
    p.linked = false;
    c.g_hash_table_remove_all(p.uniforms);
    c.g_object_notify(@ptrCast(s), "linked");
}

pub export fn gst_gl_shader_release(s: OShader) void {
    if (!valid(s, "gst_gl_shader_release")) return;
    lock(s);
    gst_gl_shader_release_unlocked(s);
    unlock(s);
}

pub export fn gst_gl_shader_use(s: OShader) void {
    const fname = "gst_gl_shader_use";
    if (!valid(s, fname)) return;
    if (!check.that(pv(s).program != 0, fname, "priv->program_handle")) return;
    pv(s).vtable.UseProgram.?(pv(s).program);
}

pub export fn gst_gl_context_clear_shader(ctx: OCtx) void {
    if (!check.that(context.isContext(ctx), "gst_gl_context_clear_shader", "GST_IS_GL_CONTEXT (context)")) return;
    const gl = &ctx[0].gl_vtable[0];
    if (gl.CreateProgram != null) {
        gl.UseProgram.?(0);
    } else if (gl.CreateProgramObject != null) {
        gl.UseProgramObject.?(0);
    }
}

fn pre(s: OShader, name: [*c]const u8, comptime fname: []const u8) ?c.GLint {
    if (!check.that(s != null, fname, "shader != NULL")) return null;
    if (!check.that(pv(s).program != 0, fname, "shader->priv->program_handle != 0")) return null;
    return uniformLocation(s, name);
}

fn vt(s: OShader) *c.GstGLFuncs {
    return @ptrCast(s[0].context[0].gl_vtable);
}

pub export fn gst_gl_shader_set_uniform_1f(s: OShader, name: [*c]const u8, v0: f32) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_1f") orelse return;
    vt(s).Uniform1f.?(l, v0);
}

pub export fn gst_gl_shader_set_uniform_1i(s: OShader, name: [*c]const u8, v0: c_int) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_1i") orelse return;
    vt(s).Uniform1i.?(l, v0);
}

pub export fn gst_gl_shader_set_uniform_2f(s: OShader, name: [*c]const u8, v0: f32, v1: f32) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_2f") orelse return;
    vt(s).Uniform2f.?(l, v0, v1);
}

pub export fn gst_gl_shader_set_uniform_2i(s: OShader, name: [*c]const u8, v0: c_int, v1: c_int) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_2i") orelse return;
    vt(s).Uniform2i.?(l, v0, v1);
}

pub export fn gst_gl_shader_set_uniform_3f(s: OShader, name: [*c]const u8, v0: f32, v1: f32, v2: f32) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_3f") orelse return;
    vt(s).Uniform3f.?(l, v0, v1, v2);
}

pub export fn gst_gl_shader_set_uniform_3i(s: OShader, name: [*c]const u8, v0: c_int, v1: c_int, v2: c_int) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_3i") orelse return;
    vt(s).Uniform3i.?(l, v0, v1, v2);
}

pub export fn gst_gl_shader_set_uniform_4f(s: OShader, name: [*c]const u8, v0: f32, v1: f32, v2: f32, v3: f32) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_4f") orelse return;
    vt(s).Uniform4f.?(l, v0, v1, v2, v3);
}

pub export fn gst_gl_shader_set_uniform_4i(s: OShader, name: [*c]const u8, v0: c_int, v1: c_int, v2: c_int, v3: c_int) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_4i") orelse return;
    vt(s).Uniform4i.?(l, v0, v1, v2, v3);
}

pub export fn gst_gl_shader_set_uniform_1fv(s: OShader, name: [*c]const u8, n: c.guint, v: [*c]const f32) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_1fv") orelse return;
    vt(s).Uniform1fv.?(l, @bitCast(n), v);
}

pub export fn gst_gl_shader_set_uniform_2fv(s: OShader, name: [*c]const u8, n: c.guint, v: [*c]const f32) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_2fv") orelse return;
    vt(s).Uniform2fv.?(l, @bitCast(n), v);
}

pub export fn gst_gl_shader_set_uniform_3fv(s: OShader, name: [*c]const u8, n: c.guint, v: [*c]const f32) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_3fv") orelse return;
    vt(s).Uniform3fv.?(l, @bitCast(n), v);
}

pub export fn gst_gl_shader_set_uniform_4fv(s: OShader, name: [*c]const u8, n: c.guint, v: [*c]const f32) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_4fv") orelse return;
    vt(s).Uniform4fv.?(l, @bitCast(n), v);
}

pub export fn gst_gl_shader_set_uniform_1iv(s: OShader, name: [*c]const u8, n: c.guint, v: [*c]const c_int) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_1iv") orelse return;
    vt(s).Uniform1iv.?(l, @bitCast(n), v);
}

pub export fn gst_gl_shader_set_uniform_2iv(s: OShader, name: [*c]const u8, n: c.guint, v: [*c]const c_int) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_2iv") orelse return;
    vt(s).Uniform2iv.?(l, @bitCast(n), v);
}

pub export fn gst_gl_shader_set_uniform_3iv(s: OShader, name: [*c]const u8, n: c.guint, v: [*c]const c_int) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_3iv") orelse return;
    vt(s).Uniform3iv.?(l, @bitCast(n), v);
}

pub export fn gst_gl_shader_set_uniform_4iv(s: OShader, name: [*c]const u8, n: c.guint, v: [*c]const c_int) void {
    const l = pre(s, name, "gst_gl_shader_set_uniform_4iv") orelse return;
    vt(s).Uniform4iv.?(l, @bitCast(n), v);
}

fn matrix(comptime field: []const u8, comptime fname: []const u8, s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    const l = pre(s, name, fname) orelse return;
    @field(vt(s), field).?(l, n, @intCast(t), v);
}

pub export fn gst_gl_shader_set_uniform_matrix_2fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix2fv", "gst_gl_shader_set_uniform_matrix_2fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_set_uniform_matrix_3fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix3fv", "gst_gl_shader_set_uniform_matrix_3fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_set_uniform_matrix_4fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix4fv", "gst_gl_shader_set_uniform_matrix_4fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_set_uniform_matrix_2x3fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix2x3fv", "gst_gl_shader_set_uniform_matrix_2x3fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_set_uniform_matrix_2x4fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix2x4fv", "gst_gl_shader_set_uniform_matrix_2x4fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_set_uniform_matrix_3x2fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix3x2fv", "gst_gl_shader_set_uniform_matrix_3x2fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_set_uniform_matrix_3x4fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix3x4fv", "gst_gl_shader_set_uniform_matrix_3x4fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_set_uniform_matrix_4x2fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix4x2fv", "gst_gl_shader_set_uniform_matrix_4x2fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_set_uniform_matrix_4x3fv(s: OShader, name: [*c]const u8, n: c.gint, t: c.gboolean, v: [*c]const f32) void {
    matrix("UniformMatrix4x3fv", "gst_gl_shader_set_uniform_matrix_4x3fv", s, name, n, t, v);
}

pub export fn gst_gl_shader_get_attribute_location(s: OShader, name: [*c]const u8) c.GLint {
    const fname = "gst_gl_shader_get_attribute_location";
    if (!check.that(s != null, fname, "shader != NULL")) return -1;
    if (!check.that(pv(s).program != 0, fname, "shader->priv->program_handle != 0")) return -1;
    return vt(s).GetAttribLocation.?(pv(s).program, name);
}

pub export fn gst_gl_shader_bind_attribute_location(s: OShader, index: c.GLuint, name: [*c]const u8) void {
    const fname = "gst_gl_shader_bind_attribute_location";
    if (!check.that(s != null, fname, "shader != NULL")) return;
    if (!check.that(pv(s).program != 0, fname, "shader->priv->program_handle != 0")) return;
    vt(s).BindAttribLocation.?(pv(s).program, index, name);
}

pub export fn gst_gl_shader_bind_frag_data_location(s: OShader, index: c.guint, name: [*c]const u8) void {
    const fname = "gst_gl_shader_bind_frag_data_location";
    if (!check.that(s != null, fname, "shader != NULL")) return;
    if (!ensureProgram(s) and !check.that(pv(s).program != 0, fname, "shader->priv->program_handle")) return;
    if (!check.that(vt(s).BindFragDataLocation != null, fname, "shader->context->gl_vtable->BindFragDataLocation")) return;
    vt(s).BindFragDataLocation.?(pv(s).program, index, name);
}
