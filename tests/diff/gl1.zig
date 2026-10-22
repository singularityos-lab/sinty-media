const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn owned(p: [*c]u8) []const u8 {
    return z(p);
}

fn api(a: c.GstGLAPI) void {
    const s = c.gst_gl_api_to_string(a);
    out("api {d} -> {s} -> {d}", .{ a, z(s), c.gst_gl_api_from_string(s) });
    c.g_free(s);
}

fn glslPure() void {
    const vs = [_]c.GstGLSLVersion{ 0, 100, 110, 120, 130, 140, 150, 300, 310, 320, 330, 400, 410, 420, 430, 440, 450, 999 };
    const ps = [_]c.GstGLSLProfile{ 0, 1, 2, 4, 3, 6, 7 };
    for (vs) |v| {
        out("ver {d} {s} {d}", .{ v, z(c.gst_glsl_version_to_string(v)), c.gst_glsl_version_from_string(c.gst_glsl_version_to_string(v)) });
        for (ps) |p| {
            const s = c.gst_glsl_version_profile_to_string(v, p);
            out("vp {d} {d} {s}", .{ v, p, z(s) });
            c.g_free(s);
        }
    }
    for (ps) |p| out("prof {d} {s} {d}", .{ p, z(c.gst_glsl_profile_to_string(p)), c.gst_glsl_profile_from_string(c.gst_glsl_profile_to_string(p)) });
    const strs = [_][*c]const u8{ "100", " 300 es ", "330 core", "150 compatibility", "120", "120 core", "#version 450", "#  version 310 es", "# version", "abc", "3000", "330 foo", "#version 100 es", "140 es", "  #version 150 core  ", null };
    for (strs) |s| {
        var v: c.GstGLSLVersion = 77;
        var p: c.GstGLSLProfile = 77;
        const r = c.gst_glsl_version_profile_from_string(s, &v, &p);
        out("parse '{s}' {d} {d} {d}", .{ z(s), r, v, p });
    }
    const srcs = [_][*c]const u8{ "#version 330 core\nvoid main(){}", "// c\n#version 300 es\n", "/* x */ #version 150\n", "/* multi\nline */\n#version 120\n", "void main(){}\n#version 330\n", "  \n\t#version 450 core\n", "#define X\n#version 330\n", null };
    for (srcs) |s| {
        var v: c.GstGLSLVersion = 77;
        var p: c.GstGLSLProfile = 77;
        const r = c.gst_glsl_string_get_version_profile(s, &v, &p);
        out("src {d} {d} {d}", .{ r, v, p });
    }
    const apis = [_]c.GstGLAPI{ c.GST_GL_API_GLES2, c.GST_GL_API_OPENGL, c.GST_GL_API_OPENGL3, c.GST_GL_API_GLES1 };
    for (apis) |a| {
        var maj: c.gint = 1;
        while (maj <= 4) : (maj += 1) {
            var min: c.gint = 0;
            while (min <= 6) : (min += 1) out("g2s {d} {d}.{d} {d}", .{ a, maj, min, c.gst_gl_version_to_glsl_version(a, maj, min) });
        }
    }
}

fn formatsPure() void {
    var f: c.GstVideoFormat = 1;
    while (f < 140) : (f += 1) {
        var sw = [_]c_int{ 9, 9, 9, 9 };
        var inv = [_]c_int{ 9, 9, 9, 9 };
        const r = c.gst_gl_video_format_swizzle(f, &sw);
        c.gst_gl_swizzle_invert(&sw, &inv);
        out("swz {d} {d} {any} {any}", .{ f, r, sw, inv });
    }
    const gls = [_]c.guint{ c.GST_GL_RGBA, c.GST_GL_RGB, c.GST_GL_RG, c.GST_GL_RED, c.GST_GL_LUMINANCE, c.GST_GL_LUMINANCE_ALPHA, c.GST_GL_ALPHA, c.GST_GL_RGBA8, c.GST_GL_RGB8, c.GST_GL_RGB565, c.GST_GL_RGBA16, c.GST_GL_RG8, c.GST_GL_R8, c.GST_GL_R16, c.GST_GL_RG16, c.GST_GL_RGB10_A2, c.GST_GL_DEPTH_COMPONENT16, c.GST_GL_DEPTH24_STENCIL8, c.GST_GL_RGB16 };
    for (gls) |g| {
        var u: c.GstGLFormat = 0;
        var t: c.guint = 0;
        c.gst_gl_format_type_from_sized_gl_format(g, &u, &t);
        out("fmt {d} n={d} unsized={d} type={d}", .{ g, c.gst_gl_format_n_components(g), u, t });
    }
    const types = [_]c.guint{ c.GL_UNSIGNED_BYTE, c.GL_UNSIGNED_SHORT, c.GL_UNSIGNED_SHORT_5_6_5, 0x8368 };
    for (gls) |g| {
        for (types) |t| out("nb {d} {d} {d}", .{ g, t, c.gst_gl_format_type_n_bytes(g, t) });
    }
    var t: c.GstGLTextureTarget = 0;
    while (t < 5) : (t += 1) out("tgt {d} {s} {d} {d} {s}", .{ t, z(c.gst_gl_texture_target_to_string(t)), c.gst_gl_texture_target_to_gl(t), c.gst_gl_texture_target_from_gl(c.gst_gl_texture_target_to_gl(t)), z(c.gst_gl_texture_target_to_buffer_pool_option(t)) });
    out("tfs {d} {d} {d} {d}", .{ c.gst_gl_texture_target_from_string("2D"), c.gst_gl_texture_target_from_string("rectangle"), c.gst_gl_texture_target_from_string("external-oes"), c.gst_gl_texture_target_from_string("x") });
    var mask: c.guint = 1;
    while (mask < 16) : (mask += 1) {
        var v = std.mem.zeroes(c.GValue);
        const r = c.gst_gl_value_set_texture_target_from_mask(&v, mask);
        const s = c.gst_value_serialize(&v);
        out("mask {d} {d} {s} {d}", .{ mask, r, z(s), c.gst_gl_value_get_texture_target_mask(&v) });
        c.g_free(s);
        c.g_value_unset(&v);
    }
    const vfs = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_NV12_4L4, c.GST_VIDEO_FORMAT_v210, c.GST_VIDEO_FORMAT_A420 };
    for (vfs) |vf| {
        var info: c.GstVideoInfo = undefined;
        _ = c.gst_video_info_set_format(&info, vf, 33, 17);
        var al: c.GstVideoAlignment = undefined;
        c.gst_video_alignment_reset(&al);
        al.padding_top = 2;
        al.padding_bottom = 3;
        var p: c.guint = 0;
        while (p < info.finfo[0].n_planes) : (p += 1) out("plane {d} {d} size={d} {d} start={d} {d}", .{ vf, p, c.gst_gl_get_plane_data_size(&info, null, p), c.gst_gl_get_plane_data_size(&info, &al, p), c.gst_gl_get_plane_start(&info, null, p), c.gst_gl_get_plane_start(&info, &al, p) });
    }
    var a: [16]f32 = undefined;
    var b: [16]f32 = undefined;
    for (0..16) |i| {
        a[i] = @floatFromInt(i);
        b[i] = @as(f32, @floatFromInt(16 - i)) * 0.5;
    }
    var r: [16]f32 = undefined;
    c.gst_gl_multiply_matrix4(&a, &b, &r);
    out("mul {any}", .{r});
    var nd: [16]f32 = undefined;
    c.gst_gl_get_affine_transformation_meta_as_ndc(null, &nd);
    out("ndc {any}", .{nd});
    out("cav {s} {s} {s}", .{ z(c.gst_gl_config_caveat_to_string(0)), z(c.gst_gl_config_caveat_to_string(1)), z(c.gst_gl_config_caveat_to_string(2)) });
    out("names {s} {s} {s}", .{ z(c.GST_GL_CONFIG_ATTRIB_CONFIG_ID_NAME), z(c.GST_GL_CONFIG_ATTRIB_MAX_PBUFFER_PIXELS_NAME), z(c.GST_GL_CONFIG_ATTRIB_NATIVE_RENDERABLE_NAME) });
    out("strs {d} {d} {d}", .{ std.mem.span(@as([*:0]const u8, @ptrCast(c.gst_gl_shader_string_vertex_default))).len, std.mem.span(@as([*:0]const u8, @ptrCast(c.gst_gl_shader_string_fragment_default))).len, std.mem.span(@as([*:0]const u8, @ptrCast(c.gst_gl_shader_string_fragment_external_oes_default))).len });
    out("ext {d} {d} {d} {d}", .{ c.gst_gl_check_extension("GL_A", "GL_B GL_A GL_C"), c.gst_gl_check_extension("GL_A", "GL_AB"), c.gst_gl_check_extension("GL_A", ""), c.gst_gl_check_extension(null, "x") });
    out("egl {s} {s} {s}", .{ z(c.gst_egl_get_error_string(c.EGL_SUCCESS)), z(c.gst_egl_get_error_string(c.EGL_BAD_SURFACE)), z(c.gst_egl_get_error_string(7)) });
}

var g_ctx: [*c]c.GstGLContext = null;

fn inThread(ctx: [*c]c.GstGLContext, _: c.gpointer) callconv(.c) void {
    out("thread current={d}", .{@intFromBool(c.gst_gl_context_get_current() == ctx)});
    const gl = &ctx[0].gl_vtable[0];
    out("vt gen={d} fbo={d} vao={d} sync={d} blit={d} pbo={d} debug={d} img={d}", .{ @intFromBool(gl.GenTextures != null), @intFromBool(gl.GenFramebuffers != null), @intFromBool(gl.GenVertexArrays != null), @intFromBool(gl.FenceSync != null), @intFromBool(gl.BlitFramebuffer != null), @intFromBool(gl.MapBufferRange != null), @intFromBool(gl.DebugMessageCallback != null), @intFromBool(gl.EGLImageTargetTexture2D != null) });
    out("cur ctx {d}", .{@intFromBool(c.gst_gl_context_get_current_gl_context(c.GST_GL_PLATFORM_EGL) != 0)});
    var v: c.GstGLSLVersion = 0;
    while (v <= 450) : (v += 10) {
        const ps = [_]c.GstGLSLProfile{ 0, 1, 2, 4 };
        for (ps) |p| {
            const s = c.gst_gl_context_supports_glsl_profile_version(ctx, v, p);
            if (s != 0) out("sup {d} {d}", .{ v, p });
        }
    }
    out("prec {d} {d} {s}", .{ c.gst_gl_context_supports_precision(ctx, 100, 1), c.gst_gl_context_supports_precision_highp(ctx, 100, 1), z(c.gst_gl_shader_string_get_highest_precision(ctx, 100, 1)) });
    const fb = c.gst_gl_framebuffer_new_with_default_depth(ctx, 16, 8);
    var w: c.guint = 0;
    var h: c.guint = 0;
    c.gst_gl_framebuffer_get_effective_dimensions(fb, &w, &h);
    out("fb {d} {d}x{d}", .{ @intFromBool(c.gst_gl_framebuffer_get_id(fb) != 0), w, h });
    c.gst_object_unref(fb);
    var err: [*c]c.GError = null;
    const sh = c.gst_gl_shader_new_default(ctx, &err);
    out("shader {d} err={s} linked={d}", .{ @intFromBool(sh != null), if (err != null) z(err[0].message) else "-", if (sh != null) c.gst_gl_shader_is_linked(sh) else -1 });
    if (sh != null) {
        out("attr {d} {d}", .{ c.gst_gl_shader_get_attribute_location(sh, "a_position"), c.gst_gl_shader_get_attribute_location(sh, "a_texcoord") });
        c.gst_gl_shader_use(sh);
        c.gst_gl_shader_set_uniform_1i(sh, "tex", 0);
        c.gst_gl_context_clear_shader(ctx);
        c.gst_object_unref(sh);
    }
    var vs = c.gst_glsl_stage_new_default_vertex(ctx);
    out("stage {d} {d} {d}", .{ c.gst_glsl_stage_get_shader_type(vs), c.gst_glsl_stage_get_version(vs), c.gst_glsl_stage_get_profile(vs) });
    out("compile {d}", .{c.gst_glsl_stage_compile(vs, null)});
    c.gst_object_unref(vs);
    vs = c.gst_glsl_stage_new_with_string(ctx, c.GL_FRAGMENT_SHADER, 0, 0, "void main() { gl_FragColor = vec4(1.0); oops }");
    err = null;
    out("bad {d}", .{c.gst_glsl_stage_compile(vs, &err)});
    out("bad err {d} {d}", .{ @intFromBool(err != null), if (err != null) err[0].code else -1 });
    c.g_clear_error(&err);
    c.gst_object_unref(vs);
}

fn showMem(label: []const u8, m: [*c]c.GstMemory) void {
    if (m == null) {
        out("{s} -", .{label});
        return;
    }
    const gm: [*c]c.GstGLMemory = @ptrCast(@alignCast(m));
    out("{s} type={s} size={d} gl={d} pbo={d} egl={d} w={d} h={d} fmt={d} tgt={d} tex={d} flags={d}", .{ label, z(m[0].allocator[0].mem_type), m[0].size, c.gst_is_gl_memory(m), c.gst_is_gl_memory_pbo(m), c.gst_is_gl_memory_egl(m), c.gst_gl_memory_get_texture_width(gm), c.gst_gl_memory_get_texture_height(gm), c.gst_gl_memory_get_texture_format(gm), c.gst_gl_memory_get_texture_target(gm), @intFromBool(c.gst_gl_memory_get_texture_id(gm) != 0), m[0].mini_object.flags });
}

var g_stride: usize = 0;
var g_valid: usize = 0;

fn sum(p: [*c]const u8, n: usize) u64 {
    var s: u64 = 0;
    for (0..n) |i| {
        if (g_stride != 0 and i % g_stride >= g_valid) continue;
        s = s *% 31 +% p[i];
    }
    return s;
}

fn memoryTests(ctx: [*c]c.GstGLContext) void {
    const fmts = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_RGB16 };
    for ([_][*c]const u8{ "GLMemory", "GLMemoryPBO" }) |name| {
        const al: [*c]c.GstGLMemoryAllocator = @ptrCast(@alignCast(c.gst_allocator_find(name)));
        out("alloc {s} {d}", .{ z(name), @intFromBool(al != null) });
        for (fmts) |vf| {
            var info: c.GstVideoInfo = undefined;
            _ = c.gst_video_info_set_format(&info, vf, 20, 10);
            const buf = c.gst_buffer_new();
            const params = c.gst_gl_video_allocation_params_new(ctx, null, &info, 0, null, c.GST_GL_TEXTURE_TARGET_2D, 0);
            const ok = c.gst_gl_memory_setup_buffer(al, buf, params, null, null, 0);
            out("setup {d} n={d}", .{ ok, c.gst_buffer_n_memory(buf) });
            var i: c.guint = 0;
            while (i < c.gst_buffer_n_memory(buf)) : (i += 1) {
                const m = c.gst_buffer_peek_memory(buf, i);
                var comp: [4]c.gint = undefined;
                c.gst_video_format_info_component(info.finfo, i, &comp);
                const ci: usize = @intCast(comp[0]);
                g_stride = @intCast(info.stride[i]);
                g_valid = @as(usize, @intCast(-((-info.width) >> @intCast(info.finfo[0].w_sub[ci])))) * @as(usize, @intCast(info.finfo[0].pixel_stride[ci]));
                showMem("mem", m);
                var mi: c.GstMapInfo = undefined;
                if (c.gst_memory_map(m, &mi, c.GST_MAP_WRITE) != 0) {
                    for (0..mi.size) |k| mi.data[k] = @truncate(k * 7 + i);
                    c.gst_memory_unmap(m, &mi);
                }
                showMem("written", m);
                if (c.gst_memory_map(m, &mi, c.GST_MAP_READ | c.GST_MAP_GL) != 0) {
                    out("gl map tex={d}", .{@intFromBool(@as(*c.guint, @ptrCast(@alignCast(mi.data))).* != 0)});
                    c.gst_memory_unmap(m, &mi);
                }
                showMem("uploaded", m);
                const cp = c.gst_memory_copy(m, 0, -1);
                showMem("copy", cp);
                if (cp != null) {
                    if (c.gst_memory_map(cp, &mi, c.GST_MAP_READ) != 0) {
                        out("copy sum {d} {d}", .{ mi.size, sum(mi.data, mi.size) });
                        c.gst_memory_unmap(cp, &mi);
                    }
                    c.gst_memory_unref(cp);
                }
                if (c.gst_memory_map(m, &mi, c.GST_MAP_READ) != 0) {
                    out("read sum {d} {d}", .{ mi.size, sum(mi.data, mi.size) });
                    c.gst_memory_unmap(m, &mi);
                }
            }
            const meta = c.gst_buffer_get_video_meta(buf);
            if (meta != null) out("meta {d} {d}x{d} planes={d} off={any} stride={any}", .{ meta[0].format, meta[0].width, meta[0].height, meta[0].n_planes, meta[0].offset, meta[0].stride });
            c.gst_gl_allocation_params_free(@ptrCast(params));
            c.gst_buffer_unref(buf);
        }
        c.gst_object_unref(al);
    }
    g_stride = 0;
    const def: [*c]c.GstAllocator = @ptrCast(c.gst_gl_memory_allocator_get_default(ctx));
    out("default {s}", .{z(def[0].mem_type)});
    c.gst_object_unref(def);
    const ba: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(c.gst_allocator_find("GLBuffer")));
    const bp = c.gst_gl_buffer_allocation_params_new(ctx, 64, null, c.GL_ARRAY_BUFFER, c.GL_STATIC_DRAW);
    const bm: [*c]c.GstMemory = @ptrCast(c.gst_gl_base_memory_alloc(ba, @ptrCast(bp)));
    out("glbuffer {d} {d} {s}", .{ c.gst_is_gl_buffer(bm), bm[0].size, z(bm[0].allocator[0].mem_type) });
    var mi: c.GstMapInfo = undefined;
    if (c.gst_memory_map(bm, &mi, c.GST_MAP_WRITE) != 0) {
        for (0..mi.size) |k| mi.data[k] = @truncate(k ^ 0x5a);
        c.gst_memory_unmap(bm, &mi);
    }
    const bc = c.gst_memory_copy(bm, 0, -1);
    if (c.gst_memory_map(bc, &mi, c.GST_MAP_READ) != 0) {
        out("glbuffer copy {d} {d}", .{ mi.size, sum(mi.data, mi.size) });
        c.gst_memory_unmap(bc, &mi);
    }
    c.gst_memory_unref(bc);
    c.gst_memory_unref(bm);
    c.gst_gl_allocation_params_free(@ptrCast(bp));
    c.gst_object_unref(ba);
    const ra: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(c.gst_allocator_find("GLRenderbuffer")));
    const rp = c.gst_gl_renderbuffer_allocation_params_new(ctx, null, c.GST_GL_RGBA8, 8, 4);
    const rb: [*c]c.GstGLRenderbuffer = @ptrCast(@alignCast(c.gst_gl_base_memory_alloc(ra, @ptrCast(rp))));
    out("rb {d} {d}x{d} fmt={d} id={d} size={d}", .{ c.gst_is_gl_renderbuffer(@ptrCast(rb)), c.gst_gl_renderbuffer_get_width(rb), c.gst_gl_renderbuffer_get_height(rb), c.gst_gl_renderbuffer_get_format(rb), @intFromBool(c.gst_gl_renderbuffer_get_id(rb) != 0), rb[0].mem.mem.size });
    out("rb map {d}", .{c.gst_memory_map(@ptrCast(rb), &mi, c.GST_MAP_READ)});
    c.gst_memory_unref(@ptrCast(rb));
    c.gst_gl_allocation_params_free(@ptrCast(rp));
    c.gst_object_unref(ra);
}

fn poolTests(ctx: [*c]c.GstGLContext) void {
    const pool = c.gst_gl_buffer_pool_new(ctx);
    const opts = c.gst_buffer_pool_get_options(pool);
    var i: usize = 0;
    while (opts[i] != null) : (i += 1) out("opt {s}", .{z(opts[i])});
    const caps = c.gst_caps_from_string("video/x-raw(memory:GLMemory),format=RGBA,width=32,height=16,texture-target=2D");
    const cfg = c.gst_buffer_pool_get_config(pool);
    c.gst_buffer_pool_config_set_params(cfg, caps, 0, 2, 4);
    c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionVideoMeta");
    c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionGLSyncMeta");
    c.gst_buffer_pool_config_set_gl_min_free_queue_size(cfg, 1);
    out("minq {d}", .{c.gst_buffer_pool_config_get_gl_min_free_queue_size(cfg)});
    out("setcfg {d}", .{c.gst_buffer_pool_set_config(pool, cfg)});
    const cfg2 = c.gst_buffer_pool_get_config(pool);
    var cc: ?*c.GstCaps = null;
    var size: c.guint = 0;
    var mn: c.guint = 0;
    var mx: c.guint = 0;
    _ = c.gst_buffer_pool_config_get_params(cfg2, &cc, &size, &mn, &mx);
    out("cfg size={d} min={d} max={d}", .{ size, mn, mx });
    const ap = c.gst_buffer_pool_config_get_gl_allocation_params(cfg2);
    out("cfg params {d}", .{@intFromBool(ap != null)});
    if (ap != null) c.gst_gl_allocation_params_free(ap);
    c.gst_structure_free(cfg2);
    const pp = c.gst_gl_buffer_pool_get_gl_allocation_params(@ptrCast(pool));
    const vp: [*c]c.GstGLVideoAllocationParams = @ptrCast(@alignCast(pp));
    out("pool params {d} tgt={d} size={d} flags={d}", .{ @intFromBool(pp != null), vp[0].target, vp[0].v_info[0].size, vp[0].parent.alloc_flags });
    c.gst_gl_allocation_params_free(pp);
    out("active {d}", .{c.gst_buffer_pool_set_active(pool, 1)});
    var bufs: [2][*c]c.GstBuffer = undefined;
    for (&bufs) |*b| {
        b.* = null;
        out("acq {d}", .{c.gst_buffer_pool_acquire_buffer(pool, b, null)});
        if (b.* != null) {
            showMem("pmem", c.gst_buffer_peek_memory(b.*, 0));
            const sm = c.gst_buffer_get_meta(b.*, c.gst_gl_sync_meta_api_get_type());
            out("sync {d}", .{@intFromBool(sm != null)});
            if (sm != null) {
                const s: [*c]c.GstGLSyncMeta = @ptrCast(@alignCast(sm));
                c.gst_gl_sync_meta_set_sync_point(s, ctx);
                c.gst_gl_sync_meta_wait(s, ctx);
                c.gst_gl_sync_meta_wait_cpu(s, ctx);
                out("sync data {d}", .{@intFromBool(s[0].data != null)});
                const cp = c.gst_buffer_copy(b.*);
                out("copy sync {d}", .{@intFromBool(c.gst_buffer_get_meta(cp, c.gst_gl_sync_meta_api_get_type()) != null)});
                c.gst_buffer_unref(cp);
            }
        }
    }
    for (bufs) |b| {
        if (b != null) c.gst_buffer_unref(b);
    }
    out("inactive {d}", .{c.gst_buffer_pool_set_active(pool, 0)});
    c.gst_object_unref(pool);
    c.gst_caps_unref(caps);
}

pub fn main() void {
    _ = c.setenv("GST_GL_WINDOW", "surfaceless", 1);
    _ = c.setenv("GST_GL_PLATFORM", "egl", 1);
    _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    _ = c.setenv("EGL_PLATFORM", "surfaceless", 1);
    c.gst_init(null, null);
    api(c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2);
    api(c.GST_GL_API_ANY);
    api(c.GST_GL_API_NONE);
    glslPure();
    formatsPure();
    const d = c.gst_gl_display_new();
    out("display {s} type={d} api={d} handle={d}", .{ z(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(d))).g_class[0].g_type)), c.gst_gl_display_get_handle_type(d), c.gst_gl_display_get_gl_api(d), @intFromBool(c.gst_gl_display_get_handle(d) != 0) });
    const ctx = c.gst_gl_context_new(d);
    out("context {s}", .{if (ctx != null) z(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(ctx))).g_class[0].g_type)) else "-"});
    if (ctx == null) return;
    g_ctx = ctx;
    var err: [*c]c.GError = null;
    const ok = c.gst_gl_context_create(ctx, null, &err);
    out("create {d} err={s}", .{ ok, if (err != null) z(err[0].message) else "-" });
    if (ok == 0) return;
    var maj: c.gint = 0;
    var min: c.gint = 0;
    c.gst_gl_context_get_gl_version(ctx, &maj, &min);
    out("gl api={d} plat={d} ver={d}.{d}", .{ c.gst_gl_context_get_gl_api(ctx), c.gst_gl_context_get_gl_platform(ctx), maj, min });
    c.gst_gl_context_get_gl_platform_version(ctx, &maj, &min);
    out("egl ver {d}.{d}", .{ maj, min });
    out("feat {d} {d} {d} {d}", .{ c.gst_gl_context_check_feature(ctx, "EGL_KHR_image_base"), c.gst_gl_context_check_feature(ctx, "GL_OES_EGL_image"), c.gst_gl_context_check_feature(ctx, "EGL_nope"), c.gst_gl_context_check_feature(ctx, "GL_nope") });
    out("ver checks {d} {d} {d}", .{ c.gst_gl_context_check_gl_version(ctx, c.GST_GL_API_OPENGL3, 3, 0), c.gst_gl_context_check_gl_version(ctx, c.GST_GL_API_GLES2, 2, 0), c.gst_gl_context_check_gl_version(ctx, c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3, 9, 0) });
    const cfg = c.gst_gl_context_get_config(ctx);
    out("config {s}", .{if (cfg != null) owned(c.gst_structure_to_string(cfg)) else "-"});
    if (cfg != null) c.gst_structure_free(cfg);
    const th = c.gst_gl_context_get_thread(ctx);
    out("thread {d} shared={d}", .{ @intFromBool(th != null), c.gst_gl_context_is_shared(ctx) });
    if (th != null) c.g_thread_unref(th);
    out("current main {d}", .{@intFromBool(c.gst_gl_context_get_current() != null)});
    c.gst_gl_context_thread_add(ctx, inThread, null);
    out("add {d}", .{c.gst_gl_display_add_context(d, ctx)});
    out("add again {d}", .{c.gst_gl_display_add_context(d, ctx)});
    const found = c.gst_gl_display_get_gl_context_for_thread(d, null);
    out("found {d}", .{@intFromBool(found == ctx)});
    if (found != null) c.gst_object_unref(found);
    var ens: [*c]c.GstGLContext = null;
    out("ensure {d} same={d}", .{ c.gst_gl_display_ensure_context(d, null, &ens, null), @intFromBool(ens == ctx) });
    if (ens != null) c.gst_object_unref(ens);
    const w = c.gst_gl_context_get_window(ctx);
    out("window {s} out={d} ctl={d}", .{ z(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(w))).g_class[0].g_type)), c.gst_gl_window_has_output_surface(w), c.gst_gl_window_controls_viewport(w) });
    c.gst_object_unref(w);
    memoryTests(ctx);
    poolTests(ctx);
    const other = c.gst_gl_context_new(d);
    err = null;
    out("shared create {d}", .{c.gst_gl_context_create(other, ctx, &err)});
    out("can share {d} {d} {d}", .{ c.gst_gl_context_can_share(ctx, other), c.gst_gl_context_is_shared(ctx), c.gst_gl_context_is_shared(other) });
    c.gst_object_unref(other);
    c.gst_gl_display_remove_context(d, ctx);
    const gone = c.gst_gl_display_get_gl_context_for_thread(d, null);
    out("after remove {d}", .{@intFromBool(gone != null)});
    c.gst_object_unref(ctx);
    c.gst_object_unref(d);
    out("done", .{});
}
