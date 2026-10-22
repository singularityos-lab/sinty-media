const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");
const glsl = @import("effects/glsl.zig");
const img = @import("img.zig").p;

const FILE = "../ext/gl/gstgldifferencematte.c";
const PROP_LOCATION = 1;
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;

const Self = extern struct {
    filter: c.GstGLFilter,
    identity_shader: ?*c.GstGLShader,
    shader: [4]?*c.GstGLShader,
    location: [*c]u8,
    bg_has_changed: c.gboolean,
    pixbuf: [*c]u8,
    pbuf_width: c.gint,
    pbuf_height: c.gint,
    savedbgtexture: [*c]c.GstGLMemory,
    newbgtexture: [*c]c.GstGLMemory,
    midtexture: [4][*c]c.GstGLMemory,
    intexture: [*c]c.GstGLMemory,
    kernel: [7]f32,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

var once: cm.Once = .{};
var parent_gl: *c.GstGLBaseFilterClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

extern fn expf(f32) f32;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(el.base(s).context[0].gl_vtable));
}

fn gaussian(k: []f32, sigma: f32) void {
    var sum: f32 = 0;
    const l: i32 = @intCast((k.len - 1) / 2);
    for (k, 0..) |*v, i| {
        const x: f64 = @as(f32, @floatFromInt(@as(i32, @intCast(i)) - l)) / sigma;
        v.* = expf(@floatCast(-0.5 * (x * x)));
        sum += v.*;
    }
    for (k) |*v| v.* /= sum;
}

fn fail(s: *Self, what: [*:0]const u8, err: [*c]c.GError, line: c.gint) c.gboolean {
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(what), c.g_strdup(err[0].message), FILE, "gst_gl_differencematte_gl_start", line);
    return 0;
}

fn link(ctx: [*c]c.GstGLContext, src: [*:0]const u8, err: *[*c]c.GError) ?*c.GstGLShader {
    var frags = [2][*c]const u8{ c.gst_gl_shader_string_get_highest_precision(ctx, c.GST_GLSL_VERSION_NONE, PROFILE), src };
    return c.gst_gl_shader_new_link_with_stages(ctx, err, c.gst_glsl_stage_new_default_vertex(ctx), c.gst_glsl_stage_new_with_strings(ctx, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, PROFILE, 2, &frags), @as(?*anyopaque, null));
}

fn texture(ctx: [*c]c.GstGLContext, alloc: [*c]c.GstGLBaseMemoryAllocator, info: *const c.GstVideoInfo) [*c]c.GstGLMemory {
    const params: [*c]c.GstGLAllocationParams = @ptrCast(c.gst_gl_video_allocation_params_new(ctx, null, info, 0, null, c.GST_GL_TEXTURE_TARGET_2D, c.GST_GL_RGBA));
    defer c.gst_gl_allocation_params_free(params);
    return @ptrCast(@alignCast(c.gst_gl_base_memory_alloc(alloc, params)));
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    const s = me(bf);
    const ctx = bf[0].context;
    if (parent_gl.gl_start.?(bf) == 0) return 0;
    const alloc: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(c.gst_gl_memory_allocator_get_default(ctx)));
    for (&s.midtexture) |*t| t.* = texture(ctx, alloc, &s.filter.out_info);
    c.gst_object_unref(alloc);
    var err: [*c]c.GError = null;
    s.identity_shader = c.gst_gl_shader_new_default(ctx, &err);
    if (s.identity_shader == null) return fail(s, "Failed to compile identity shader", err, 113);
    s.shader[0] = link(ctx, glsl.difference, &err);
    if (s.shader[0] == null) return fail(s, "Failed to compile difference shader", err, 131);
    s.shader[1] = link(ctx, glsl.hconv7, &err);
    if (s.shader[1] == null) return fail(s, "Failed to compile convolution shader", err, 144);
    s.shader[2] = link(ctx, glsl.vconv7, &err);
    if (s.shader[2] == null) return fail(s, "Failed to compile convolution shader", err, 157);
    s.shader[3] = link(ctx, glsl.textureInterp, &err);
    if (s.shader[3] == null) return fail(s, "Failed to compile interpolation shader", err, 170);
    s.filter.draw_attr_position_loc = c.gst_gl_shader_get_attribute_location(s.shader[2], "a_position");
    s.filter.draw_attr_texture_loc = c.gst_gl_shader_get_attribute_location(s.shader[2], "a_texcoord");
    return 1;
}

fn unrefMem(m: *[*c]c.GstGLMemory) void {
    if (m.* != null) c.gst_memory_unref(@ptrCast(m.*));
    m.* = null;
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    unrefMem(&s.savedbgtexture);
    unrefMem(&s.newbgtexture);
    if (s.identity_shader != null) c.gst_object_unref(s.identity_shader);
    s.identity_shader = null;
    for (&s.shader, &s.midtexture) |*sh, *t| {
        if (sh.* != null) c.gst_object_unref(sh.*);
        sh.* = null;
        unrefMem(t);
    }
    if (s.pixbuf != null) std.c.free(s.pixbuf);
    s.pixbuf = null;
    s.bg_has_changed = 0;
    parent_gl.gl_stop.?(bf);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_free(me(o).location);
    parent_obj.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id == PROP_LOCATION) {
        c.g_free(s.location);
        s.bg_has_changed = 1;
        s.location = c.g_value_dup_string(v);
    } else cm.warnInvalid(FILE, o, id, spec, 304);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_LOCATION) c.g_value_set_string(v, me(o).location) else cm.warnInvalid(FILE, o, id, spec, 320);
}

fn pixbufTexture(s: *Self) void {
    const ctx = el.base(s).context;
    const alloc: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(c.gst_gl_memory_allocator_get_default(ctx)));
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&info, c.GST_VIDEO_FORMAT_RGBA, @bitCast(s.pbuf_width), @bitCast(s.pbuf_height));
    s.newbgtexture = texture(ctx, alloc, &info);
    if (s.savedbgtexture == null) s.savedbgtexture = texture(ctx, alloc, &s.filter.out_info);
    c.gst_object_unref(alloc);
}

fn bindTex(g: *c.GstGLFuncs, unit: c.GLenum, tex: c.guint) void {
    g.ActiveTexture.?(unit);
    g.BindTexture.?(c.GL_TEXTURE_2D, tex);
}

fn diff(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    const s = me(f);
    const g = gl(s);
    c.gst_gl_shader_use(s.shader[0]);
    bindTex(g, c.GL_TEXTURE0, c.gst_gl_memory_get_texture_id(in));
    c.gst_gl_shader_set_uniform_1i(s.shader[0], "current", 0);
    bindTex(g, c.GL_TEXTURE1, c.gst_gl_memory_get_texture_id(s.savedbgtexture));
    c.gst_gl_shader_set_uniform_1i(s.shader[0], "saved", 1);
    c.gst_gl_filter_draw_fullscreen_quad(f);
    return 1;
}

fn blur(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, i: usize, name: [*:0]const u8, size: c.gint) void {
    const s = me(f);
    c.gst_gl_shader_use(s.shader[i]);
    bindTex(gl(s), c.GL_TEXTURE0, c.gst_gl_memory_get_texture_id(in));
    c.gst_gl_shader_set_uniform_1i(s.shader[i], "tex", 0);
    c.gst_gl_shader_set_uniform_1fv(s.shader[i], "kernel", 7, &s.kernel);
    c.gst_gl_shader_set_uniform_1f(s.shader[i], name, @floatFromInt(size));
    c.gst_gl_filter_draw_fullscreen_quad(f);
}

fn hblur(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    blur(f, in, 1, "gauss_width", f[0].out_info.width);
    return 1;
}

fn vblur(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    blur(f, in, 2, "gauss_height", f[0].out_info.height);
    return 1;
}

fn interp(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    const s = me(f);
    const g = gl(s);
    c.gst_gl_shader_use(s.shader[3]);
    bindTex(g, c.GL_TEXTURE0, c.gst_gl_memory_get_texture_id(in));
    c.gst_gl_shader_set_uniform_1i(s.shader[3], "blend", 0);
    bindTex(g, c.GL_TEXTURE1, s.newbgtexture[0].tex_id);
    c.gst_gl_shader_set_uniform_1i(s.shader[3], "base", 1);
    bindTex(g, c.GL_TEXTURE2, s.midtexture[2][0].tex_id);
    c.gst_gl_shader_set_uniform_1i(s.shader[3], "alpha", 2);
    c.gst_gl_filter_draw_fullscreen_quad(f);
    return 1;
}

fn pngWarning(_: ?*img.png_struct, msg: [*c]const u8) callconv(.c) void {
    c.g_log(null, c.G_LOG_LEVEL_WARNING, "%s\n", msg);
}

fn load(s: *Self) bool {
    if (el.base(s).context == null) return true;
    const fp = img.fopen(s.location, "rb") orelse return false;
    defer _ = img.fclose(fp);
    var png = img.png_create_read_struct(img.PNG_LIBPNG_VER_STRING, null, null, null) orelse return false;
    img.png_set_error_fn(png, null, null, pngWarning);
    var info = img.png_create_info_struct(png);
    if (info == null) {
        img.png_destroy_read_struct(@ptrCast(&png), null, null);
        return false;
    }
    img.png_init_io(png, fp);
    img.png_set_sig_bytes(png, 0);
    img.png_read_info(png, info);
    var w: img.png_uint_32 = 0;
    var h: img.png_uint_32 = 0;
    var depth: c_int = 0;
    var color: c_int = 0;
    var interlace: c_int = 0;
    _ = img.png_get_IHDR(png, info, &w, &h, &depth, &color, &interlace, null, null);
    if (color == img.PNG_COLOR_TYPE_RGB) {
        img.png_set_filler(png, 0xff, img.PNG_FILLER_AFTER);
        color = img.PNG_COLOR_TYPE_RGB_ALPHA;
    }
    if (color != img.PNG_COLOR_TYPE_RGB_ALPHA) {
        img.png_destroy_read_struct(@ptrCast(&png), null, null);
        return false;
    }
    s.pbuf_width = @bitCast(w);
    s.pbuf_height = @bitCast(h);
    s.pixbuf = @ptrCast(std.c.malloc(@as(usize, w) * h * 4));
    const rows: [*][*c]u8 = @ptrCast(@alignCast(std.c.malloc(@sizeOf([*c]u8) * h)));
    for (0..h) |y| rows[y] = s.pixbuf + y * w * 4;
    img.png_read_image(png, @ptrCast(rows));
    std.c.free(@ptrCast(rows));
    img.png_read_end(png, info);
    img.png_destroy_read_struct(@ptrCast(&png), @ptrCast(&info), null);
    return true;
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    const s = me(f);
    s.intexture = in;
    if (s.bg_has_changed != 0 and s.location != null) {
        if (!load(s)) s.pixbuf = null;
        pixbufTexture(s);
        _ = c.gst_gl_filter_render_to_target_with_shader(f, in, s.savedbgtexture, s.identity_shader);
        if (s.pixbuf != null) std.c.free(s.pixbuf);
        s.pixbuf = null;
        s.bg_has_changed = 0;
    }
    if (s.savedbgtexture != null) {
        _ = c.gst_gl_filter_render_to_target(f, in, s.midtexture[0], diff, null);
        _ = c.gst_gl_filter_render_to_target(f, s.midtexture[0], s.midtexture[1], hblur, null);
        _ = c.gst_gl_filter_render_to_target(f, s.midtexture[1], s.midtexture[2], vblur, null);
        _ = c.gst_gl_filter_render_to_target(f, in, out, interp, null);
    } else {
        _ = c.gst_gl_filter_render_to_target_with_shader(f, in, out, s.identity_shader);
    }
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.filter_texture = filterTexture;
    c.g_object_class_install_property(oc, PROP_LOCATION, c.g_param_spec_string("location", "Background image location", "Background image location", null, cm.RW));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Gstreamer OpenGL DifferenceMatte", "Filter/Effect/Video", "Saves a background frame and replace it with a pixbuf", "Filippo Argiolas <filippo.argiolas@gmail.com>");
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    gaussian(&me(inst).kernel, 30);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLDifferenceMatte", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("gldifferencematte", 0, "gldifferencematte element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "gldifferencematte", c.GST_RANK_NONE, getType());
}
