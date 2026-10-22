const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const context = @import("context.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const OCtx = [*c]c.GstGLContext;
const Version = c.GstGLSLVersion;
const Profile = c.GstGLSLProfile;
const ES = c.GST_GLSL_PROFILE_ES;
const CORE = c.GST_GLSL_PROFILE_CORE;
const COMPAT = c.GST_GLSL_PROFILE_COMPATIBILITY;
const NONE = c.GST_GLSL_PROFILE_NONE;

const VERSIONS = [_]Version{ 100, 110, 120, 130, 140, 150, 300, 310, 320, 330, 400, 410, 420, 430, 440, 450 };
const VERSION_NAMES = [_][*:0]const u8{ "100", "110", "120", "130", "140", "150", "300", "310", "320", "330", "400", "410", "420", "430", "440", "450" };
const PROFILES = [_]struct { p: Profile, n: [*:0]const u8 }{ .{ .p = ES, .n = "es" }, .{ .p = CORE, .n = "core" }, .{ .p = COMPAT, .n = "compatibility" } };

var done: usize = 0;

fn initDebug() void {
    if (c.g_once_init_enter(&done) != 0) {
        _ = c._gst_debug_category_new("glsl", 0, "OpenGL Shading Language");
        c.g_once_init_leave(&done, 1);
    }
}

pub export fn gst_glsl_error_quark() c.GQuark {
    return c.g_quark_from_static_string("gst-glsl-error-quark");
}

pub export fn gst_glsl_version_to_string(v: Version) [*c]const u8 {
    if (v == c.GST_GLSL_VERSION_NONE) return null;
    for (VERSIONS, 0..) |x, i| {
        if (x == v) return VERSION_NAMES[i];
    }
    return null;
}

fn stripped(s: [*c]const u8) [*c]u8 {
    return c.g_strstrip(c.g_strdup(s));
}

pub export fn gst_glsl_version_from_string(s: [*c]const u8) Version {
    if (s == null) return 0;
    const str = stripped(s);
    defer c.g_free(str);
    for (VERSION_NAMES, 0..) |n, i| {
        if (c.g_strcmp0(str, n) == 0) return VERSIONS[i];
    }
    return 0;
}

pub export fn gst_glsl_profile_to_string(p: Profile) [*c]const u8 {
    if (p == NONE) return null;
    if (p & (p -% 1) != 0) return null;
    for (PROFILES) |e| {
        if (e.p == p) return e.n;
    }
    return null;
}

pub export fn gst_glsl_profile_from_string(s: [*c]const u8) Profile {
    if (s == null) return NONE;
    const str = stripped(s);
    defer c.g_free(str);
    for (PROFILES) |e| {
        if (c.g_strcmp0(str, e.n) == 0) return e.p;
    }
    return NONE;
}

fn isEsVersion(v: Version) bool {
    return v == 100 or v == 300 or v == 310 or v == 320;
}

pub fn validVersionProfile(v: Version, p: Profile) bool {
    if (v == c.GST_GLSL_VERSION_NONE) return true;
    if (v <= 150 and p == NONE) return true;
    if (isEsVersion(v)) return p == ES;
    if (v == 150 or v >= 330) return p == NONE or p == CORE or p == COMPAT;
    if (v <= 140) return p == NONE or p == COMPAT;
    return false;
}

pub export fn gst_glsl_version_profile_to_string(v: Version, p: Profile) [*c]u8 {
    if (!validVersionProfile(v, p)) return null;
    const vs = gst_glsl_version_to_string(v);
    const ps = if (v <= 140) null else gst_glsl_profile_to_string(p);
    if (vs == null) return null;
    if (ps != null) return c.g_strdup_printf("%s %s", vs, ps);
    return c.g_strdup(vs);
}

fn fixup(v: *Version, p: *Profile) void {
    if (isEsVersion(v.*)) {
        p.* = ES;
    } else if (v.* <= 140) {
        p.* = COMPAT;
    } else if (p.* == NONE and v.* >= 150) {
        p.* = CORE;
    }
}

fn versionDirective(str: [*c]const u8) [*c]const u8 {
    if (str == null or str[0] == 0) return null;
    var i: usize = 0;
    while (true) {
        i += 1;
        if (str[i] == 0 or str[i] == '\n' or str[i] == '\r') return null;
        if (!std.ascii.isWhitespace(str[i])) break;
    }
    if (c.g_strstr_len(str + i, 7, "version") != null) return str + i + 7;
    return null;
}

pub export fn gst_glsl_version_profile_from_string(s: [*c]const u8, vret: [*c]Version, pret: [*c]Profile) c.gboolean {
    initDebug();
    var v: Version = c.GST_GLSL_VERSION_NONE;
    var p: Profile = NONE;
    ok: {
        if (s == null) break :ok;
        const str = c.g_strdup(s);
        var vs: [*c]u8 = c.g_strstrip(str);
        if (str[0] == '#') {
            const d = versionDirective(vs);
            if (d == null) {
                c.g_free(str);
                break :ok;
            }
            vs = @constCast(d);
        }
        vs = c.g_strstrip(vs);
        var i: usize = 0;
        while (vs != null and vs[i] != 0 and std.ascii.isDigit(vs[i])) i += 1;
        if (i != 3) {
            c.g_free(str);
            break :ok;
        }
        if (vs[i] != 0) {
            vs[i] = 0;
            i += 1;
            p = gst_glsl_profile_from_string(c.g_strstrip(vs + i));
        }
        v = gst_glsl_version_from_string(vs);
        c.g_free(str);
        if (v == 0) break :ok;
        if (!validVersionProfile(v, p)) break :ok;
        if (v <= 140 and p != NONE) break :ok;
        fixup(&v, &p);
        if (pret != null) pret[0] = p;
        if (vret != null) vret[0] = v;
        return 1;
    }
    if (pret != null) pret[0] = NONE;
    if (vret != null) vret[0] = c.GST_GLSL_VERSION_NONE;
    return 0;
}

pub fn findVersion(str: [*c]const u8) [*c]const u8 {
    initDebug();
    var sl = false;
    var ml = false;
    var newline = true;
    var i: usize = 0;
    while (str != null and str[i] != 0 and i < 1024) : (i += 1) {
        if (str[i] == '\n' or str[i] == '\r') {
            newline = true;
            sl = false;
            continue;
        }
        defer newline = false;
        if (std.ascii.isWhitespace(str[i]) or sl) continue;
        if (ml) {
            if (c.g_strstr_len(str + i, 2, "*/") != null) {
                ml = false;
                i += 1;
            }
            continue;
        }
        if (c.g_strstr_len(str + i, 2, "//") != null) {
            sl = true;
            i += 1;
            continue;
        }
        if (c.g_strstr_len(str + i, 2, "/*") != null) {
            ml = true;
            i += 1;
            continue;
        }
        if (str[i] == '#') {
            if (newline and versionDirective(str + i) != null) return str + i;
            break;
        }
    }
    return null;
}

pub export fn gst_glsl_string_get_version_profile(s: [*c]const u8, v: [*c]Version, p: [*c]Profile) c.gboolean {
    const vp = findVersion(s);
    if (vp != null and gst_glsl_version_profile_from_string(vp, v, p) != 0) return 1;
    if (v != null) v[0] = c.GST_GLSL_VERSION_NONE;
    if (p != null) p[0] = NONE;
    return 0;
}

pub export fn gst_gl_version_to_glsl_version(api: c.GstGLAPI, maj: c.gint, min: c.gint) Version {
    if (!check.that(api != c.GST_GL_API_NONE, "gst_gl_version_to_glsl_version", "gl_api != GST_GL_API_NONE")) return 0;
    initDebug();
    if (api & c.GST_GL_API_GLES2 != 0) {
        if (maj == 2 and min == 0) return 100;
        if (maj == 3 and min >= 0 and min <= 2) return @bitCast(maj * 100 + min * 10);
        return 0;
    }
    if (api & (c.GST_GL_API_OPENGL3 | c.GST_GL_API_OPENGL) != 0) {
        if (maj > 3 or (maj == 3 and min >= 3)) return @bitCast(maj * 100 + min * 10);
        if (maj == 3 and min == 2) return 150;
        if (maj == 3 and min == 1) return 140;
        if (maj == 3 and min == 0) return 130;
        if (maj == 2 and min == 1) return 120;
        if (maj == 2 and min == 0) return 110;
        return 0;
    }
    return 0;
}

const ver = context.gst_gl_context_check_gl_version;

pub export fn gst_gl_context_supports_glsl_profile_version(ctx: OCtx, v: Version, p: Profile) c.gboolean {
    if (!check.that(context.isContext(ctx), "gst_gl_context_supports_glsl_profile_version", "GST_IS_GL_CONTEXT (context)")) return 0;
    if (!validVersionProfile(v, p)) return 0;
    if (p != NONE) {
        const api = context.gst_gl_context_get_gl_api(ctx);
        if (ver(ctx, c.GST_GL_API_GLES2, 2, 0) != 0) {
            if (p & ES == 0) return 0;
        } else if (api & c.GST_GL_API_OPENGL != 0) {
            if (p & COMPAT == 0) return 0;
        } else if (api & c.GST_GL_API_OPENGL3 != 0) {
            if (p & (CORE | ES) == 0) return 0;
        } else check.assertFail("gstglsl.c", 583, "gst_gl_context_supports_glsl_profile_version", null);
    }
    if (v != c.GST_GLSL_VERSION_NONE) {
        if (ver(ctx, c.GST_GL_API_GLES2, 3, 1) != 0) {
            if (v > 310) return 0;
        } else if (ver(ctx, c.GST_GL_API_GLES2, 3, 0) != 0) {
            if (v > 300) return 0;
        } else if (ver(ctx, c.GST_GL_API_GLES2, 2, 0) != 0) {
            if (v > 100) return 0;
        }
        var maj: c.gint = 0;
        var min: c.gint = 0;
        context.gst_gl_context_get_gl_version(ctx, &maj, &min);
        const g = gst_gl_version_to_glsl_version(context.gst_gl_context_get_gl_api(ctx), maj, min);
        if (v > g) return 0;
        if (ver(ctx, c.GST_GL_API_OPENGL3, 1, 0) != 0 and v < 150 and v != 100) return 0;
        if (ver(ctx, c.GST_GL_API_OPENGL, 1, 0) != 0 and v < 110) return 0;
    }
    return 1;
}

fn F(comptime name: []const u8) type {
    return @FieldType(c.GstGLFuncs, name);
}

pub const Funcs = struct {
    initialized: bool = false,
    CreateProgram: F("CreateProgram") = null,
    DeleteProgram: F("DeleteProgram") = null,
    UseProgram: F("UseProgram") = null,
    GetAttachedShaders: F("GetAttachedShaders") = null,
    CreateShader: F("CreateShader") = null,
    DeleteShader: F("DeleteShader") = null,
    AttachShader: F("AttachShader") = null,
    DetachShader: F("DetachShader") = null,
    GetShaderiv: F("GetShaderiv") = null,
    GetProgramiv: F("GetProgramiv") = null,
    GetShaderInfoLog: F("GetShaderInfoLog") = null,
    GetProgramInfoLog: F("GetProgramInfoLog") = null,
};

pub fn fillFuncs(t: *Funcs, ctx: OCtx) bool {
    if (t.initialized) return true;
    const gl = &ctx[0].gl_vtable[0];
    if (gl.CreateProgram != null) {
        t.CreateProgram = gl.CreateProgram;
        t.DeleteProgram = gl.DeleteProgram;
        t.UseProgram = gl.UseProgram;
        t.CreateShader = gl.CreateShader;
        t.DeleteShader = gl.DeleteShader;
        t.AttachShader = gl.AttachShader;
        t.DetachShader = gl.DetachShader;
        t.GetAttachedShaders = gl.GetAttachedShaders;
        t.GetShaderInfoLog = gl.GetShaderInfoLog;
        t.GetShaderiv = gl.GetShaderiv;
        t.GetProgramInfoLog = gl.GetProgramInfoLog;
        t.GetProgramiv = gl.GetProgramiv;
    } else if (gl.CreateProgramObject != null) {
        t.CreateProgram = gl.CreateProgramObject;
        t.DeleteProgram = gl.DeleteObject;
        t.UseProgram = gl.UseProgramObject;
        t.CreateShader = gl.CreateShaderObject;
        t.DeleteShader = gl.DeleteObject;
        t.AttachShader = gl.AttachObject;
        t.DetachShader = gl.DetachObject;
        t.GetAttachedShaders = gl.GetAttachedObjects;
        t.GetShaderInfoLog = gl.GetInfoLog;
        t.GetShaderiv = gl.GetObjectParameteriv;
        t.GetProgramInfoLog = gl.GetInfoLog;
        t.GetProgramiv = gl.GetObjectParameteriv;
    } else {
        t.initialized = false;
        return false;
    }
    t.initialized = true;
    return true;
}

fn replace(pattern: [*:0]const u8, str: [*c]const u8, with: [*:0]const u8, literal: bool) [*c]u8 {
    const re = c.g_regex_new(pattern, 0, 0, null);
    defer c.g_regex_unref(re);
    return if (literal) c.g_regex_replace_literal(re, str, -1, 0, with, 0, null) else c.g_regex_replace(re, str, -1, 0, with, 0, null);
}

fn hasEssl3(ctx: OCtx) bool {
    return context.gst_gl_context_check_feature(ctx, "GL_OES_EGL_image_external_essl3") != 0;
}

fn mangleExternal(str: [*c]const u8, ctx: OCtx, to: c.GstGLTextureTarget, v: Version, p: Profile) [*c]u8 {
    if (to == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES and p == ES and v >= 300 and hasEssl3(ctx))
        return replace("(#[ \\t]*extension[ \\t]+)GL_OES_EGL_image_external([ \\t]*:[ \\t]*\\S+[ \\t]*\\R)", str, "\\1GL_OES_EGL_image_external_essl3\\2", false);
    return c.g_strdup(str);
}

fn targetName(t: c.GstGLTextureTarget, comptime names: [3][*:0]const u8) ?[*:0]const u8 {
    return switch (t) {
        c.GST_GL_TEXTURE_TARGET_2D => names[0],
        c.GST_GL_TEXTURE_TARGET_RECTANGLE => names[1],
        c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES => names[2],
        else => null,
    };
}

fn regexOr(pattern: [*c]u8, str: [*c]const u8, with: ?[*:0]const u8) [*c]u8 {
    defer c.g_free(pattern);
    const re = c.g_regex_new(pattern, 0, 0, null);
    defer c.g_regex_unref(re);
    const r = c.g_regex_replace_literal(re, str, -1, 0, with, 0, null);
    return if (r != null) r else c.g_strdup(str);
}

fn mangleTexture(str: [*c]const u8, ctx: OCtx, from: c.GstGLTextureTarget, to: c.GstGLTextureTarget, v: Version, p: Profile) [*c]u8 {
    const names = [3][*:0]const u8{ "texture2D", "texture2DRect", "texture2D" };
    const fs = targetName(from, names);
    const ts: ?[*:0]const u8 = if (p == CORE or (p == ES and v >= 300 and (to != c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES or hasEssl3(ctx)))) "texture" else targetName(to, names);
    return regexOr(c.g_strdup_printf("%s(?=\\s*\\()", fs), str, ts);
}

fn mangleSampler(str: [*c]const u8, from: c.GstGLTextureTarget, to: c.GstGLTextureTarget) [*c]u8 {
    const names = [3][*:0]const u8{ "sampler2D", "sampler2DRect", "samplerExternalOES" };
    return regexOr(c.g_strdup_printf("%s(?=\\s)", targetName(from, names)), str, targetName(to, names));
}

fn mangleVarying(str: [*c]const u8, t: c.guint, v: Version, p: Profile) [*c]u8 {
    const modern = p == CORE or (p == ES and v >= 300);
    if (t == c.GL_VERTEX_SHADER and modern) {
        const a = replace("varying(?=\\s)", str, "out", true);
        defer c.g_free(a);
        return replace("attribute(?=\\s)", a, "in", true);
    }
    if (t == c.GL_FRAGMENT_SHADER and modern) return replace("varying(?=\\s)", str, "in", true);
    return c.g_strdup(str);
}

fn mangleFragColor(str: [*c]const u8) [*c]u8 {
    const a = replace("gl_FragColor", str, "fragColor", true);
    defer c.g_free(a);
    return replace("gl_FragData\\[(\\d+)\\]", a, "fragColor_\\1", false);
}

fn versionFromApi(ctx: OCtx, to: c.GstGLTextureTarget, v: *Version, p: *Profile) void {
    const api = context.gst_gl_context_get_gl_api(ctx);
    var maj: c.gint = 0;
    var min: c.gint = 0;
    context.gst_gl_context_get_gl_version(ctx, &maj, &min);
    v.* = c.GST_GLSL_VERSION_NONE;
    p.* = NONE;
    if (api & c.GST_GL_API_OPENGL3 != 0) {
        if (maj > 3 or min >= 3) {
            v.* = 330;
            p.* = CORE;
        } else {
            v.* = 150;
        }
    } else if (api & c.GST_GL_API_GLES2 != 0) {
        if (maj >= 3 and (to != c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES or hasEssl3(ctx))) {
            v.* = 300;
            p.* = ES;
        } else if (maj >= 2) {
            v.* = 100;
            p.* = ES;
        }
    } else if (api & c.GST_GL_API_OPENGL != 0) {
        v.* = if (maj >= 3) 130 else 110;
        p.* = COMPAT;
    }
}

pub fn mangle(str: [*c]const u8, t: c.guint, from: c.GstGLTextureTarget, to: c.GstGLTextureTarget, ctx: OCtx, v: *Version, p: *Profile) [*c]u8 {
    initDebug();
    if (!check.that(context.isContext(ctx), "_gst_glsl_mangle_shader", "GST_IS_GL_CONTEXT (context)")) return null;
    versionFromApi(ctx, to, v, p);
    const a = mangleExternal(str, ctx, to, v.*, p.*);
    const b = mangleTexture(a, ctx, from, to, v.*, p.*);
    c.g_free(a);
    const d = mangleSampler(b, from, to);
    c.g_free(b);
    var e = mangleVarying(d, t, v.*, p.*);
    c.g_free(d);
    if (t == c.GL_FRAGMENT_SHADER and ((p.* == ES and v.* >= 300) or (p.* == CORE and v.* >= 150))) {
        const f = mangleFragColor(e);
        c.g_free(e);
        e = f;
    }
    return e;
}

pub export fn gst_gl_context_supports_precision(ctx: OCtx, _: Version, p: Profile) c.gboolean {
    if (!check.that(context.isContext(ctx), "gst_gl_context_supports_precision", "GST_IS_GL_CONTEXT (context)")) return 0;
    if (p & ES == 0) return 0;
    const es2 = ver(ctx, c.GST_GL_API_GLES2, 2, 0) != 0 or context.gst_gl_context_check_feature(ctx, "GL_ARB_ES2_compatibility") != 0;
    return @intFromBool(es2 and ctx[0].gl_vtable[0].GetShaderPrecisionFormat != null);
}

pub export fn gst_gl_context_supports_precision_highp(ctx: OCtx, v: Version, p: Profile) c.gboolean {
    if (!check.that(context.isContext(ctx), "gst_gl_context_supports_precision_highp", "GST_IS_GL_CONTEXT (context)")) return 0;
    if (gst_gl_context_supports_precision(ctx, v, p) == 0) return 0;
    var vr = [2]c.GLint{ 0, 0 };
    var vp: c.GLint = 0;
    var fr = [2]c.GLint{ 0, 0 };
    var fp: c.GLint = 0;
    const f = ctx[0].gl_vtable[0].GetShaderPrecisionFormat.?;
    f(c.GL_VERTEX_SHADER, c.GL_HIGH_FLOAT, &vr, &vp);
    f(c.GL_FRAGMENT_SHADER, c.GL_HIGH_FLOAT, &fr, &fp);
    return @intFromBool(vr[0] != 0 and vr[1] != 0 and vp != 0 and fr[0] != 0 and fr[1] != 0 and fp != 0);
}
