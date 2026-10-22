const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const base = @import("basememory.zig");
const memory = @import("memory.zig");
const shader = @import("shader.zig");
const stage = @import("glslstage.zig");
const strings = @import("shaderstrings.zig");
const syncmeta = @import("syncmeta.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Comp = c.GstGLOverlayCompositor;
const OComp = [*c]Comp;
const OCtx = [*c]c.GstGLContext;
const Z = @as([*c]const u8, null);

const FRAGMENT = "varying vec2 v_texcoord;\nuniform sampler2D tex;\nvoid main(void)\n{\n  vec4 t = texture2D(tex, v_texcoord);\n  gl_FragColor = t.bgra;\n}";

const Overlay = extern struct {
    parent: c.GstObject,
    context: OCtx,
    vao: c.GLuint,
    index_buffer: c.GLuint,
    position_buffer: c.GLuint,
    texcoord_buffer: c.GLuint,
    position_attrib: c.GLint,
    texcoord_attrib: c.GLint,
    positions: [16]c.GLfloat,
    texture_id: c.GLuint,
    gl_memory: [*c]c.GstGLMemory,
    rectangle: ?*c.GstVideoOverlayRectangle,
    yinvert: c.gboolean,
};

var overlay_once: gtype.Once = .{};
var overlay_parent: ?*c.GObjectClass = null;
var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn ov(p: anytype) *Overlay {
    return @ptrCast(@alignCast(p));
}

fn vt(ctx: OCtx) *c.GstGLFuncs {
    return @ptrCast(ctx[0].gl_vtable);
}

const TEXCOORDS = [_]c.GLfloat{ 1, 0, 0, 0, 0, 1, 1, 1 };
const INDICES = [_]c.GLushort{ 0, 1, 2, 0, 2, 3 };

fn initVertex(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const gl = vt(ctx);
    const o = ov(data);
    if (gl.GenVertexArrays) |f| {
        f(1, &o.vao);
        gl.BindVertexArray.?(o.vao);
    }
    const pa: c.GLuint = @bitCast(o.position_attrib);
    const ta: c.GLuint = @bitCast(o.texcoord_attrib);
    gl.GenBuffers.?(1, &o.position_buffer);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, o.position_buffer);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, 16 * @sizeOf(c.GLfloat), &o.positions, c.GL_STATIC_DRAW);
    gl.VertexAttribPointer.?(pa, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(c.GLfloat), null);
    gl.GenBuffers.?(1, &o.texcoord_buffer);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, o.texcoord_buffer);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, 8 * @sizeOf(c.GLfloat), &TEXCOORDS, c.GL_STATIC_DRAW);
    gl.VertexAttribPointer.?(ta, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(c.GLfloat), null);
    gl.GenBuffers.?(1, &o.index_buffer);
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, o.index_buffer);
    gl.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(INDICES)), &INDICES, c.GL_STATIC_DRAW);
    gl.EnableVertexAttribArray.?(pa);
    gl.EnableVertexAttribArray.?(ta);
    if (gl.GenVertexArrays != null) gl.BindVertexArray.?(0);
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
}

fn freeVertex(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const gl = vt(ctx);
    const o = ov(data);
    if (o.vao != 0) {
        gl.DeleteVertexArrays.?(1, &o.vao);
        o.vao = 0;
    }
    inline for (.{ "position_buffer", "texcoord_buffer", "index_buffer" }) |f| {
        if (@field(o, f) != 0) {
            gl.DeleteBuffers.?(1, &@field(o, f));
            @field(o, f) = 0;
        }
    }
}

fn bindVertex(o: *Overlay) void {
    const gl = vt(o.context);
    const pa: c.GLuint = @bitCast(o.position_attrib);
    const ta: c.GLuint = @bitCast(o.texcoord_attrib);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, o.position_buffer);
    gl.VertexAttribPointer.?(pa, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(c.GLfloat), null);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, o.texcoord_buffer);
    gl.VertexAttribPointer.?(ta, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(c.GLfloat), null);
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, o.index_buffer);
    gl.EnableVertexAttribArray.?(pa);
    gl.EnableVertexAttribArray.?(ta);
}

fn overlayFinalize(obj: [*c]c.GObject) callconv(.c) void {
    const o = ov(obj);
    if (o.gl_memory != null) c.gst_memory_unref(@ptrCast(o.gl_memory));
    if (o.context != null) {
        c.gst_gl_context_thread_add(o.context, freeVertex, o);
        c.gst_object_unref(o.context);
    }
    c.gst_mini_object_unref(@ptrCast(@alignCast(o.rectangle)));
    overlay_parent.?.finalize.?(obj);
}

fn overlayClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    overlay_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = overlayFinalize;
}

fn overlayType() c.GType {
    return overlay_once.get(struct {
        fn f() c.GType {
            return gtype.object(c.gst_object_get_type, "GstGLCompositionOverlay", c.GstObjectClass, Overlay, overlayClassInit, null, 0);
        }
    }.f);
}

fn addTransformation(o: *Overlay, buf: [*c]c.GstBuffer) void {
    const meta = c.gst_buffer_get_video_meta(buf);
    if (meta == null) return;
    var x: c.gint = 0;
    var y: c.gint = 0;
    var w: c.guint = 0;
    var h: c.guint = 0;
    _ = c.gst_video_overlay_rectangle_get_render_rectangle(o.rectangle, &x, &y, &w, &h);
    const fw: f32 = @floatFromInt(meta[0].width);
    const fh: f32 = @floatFromInt(meta[0].height);
    var rx: f32 = @as(f32, @floatFromInt(x)) / fw;
    var ry: f32 = @as(f32, @floatFromInt(y)) / fh;
    var rw: f32 = @as(f32, @floatFromInt(w)) / fw;
    var rh: f32 = @as(f32, @floatFromInt(h)) / fh;
    rx = @floatCast(@as(f64, rx) * 2.0 - 1.0);
    ry = @floatCast((1.0 - @as(f64, ry)) * 2.0 - 1.0);
    rw = @floatCast(@as(f64, rw) * 2.0);
    rh = @floatCast(@as(f64, rh) * 2.0);
    const ys: f32 = if (o.yinvert != 0) -1.0 else 1.0;
    o.positions = .{ rx + rw, ry * ys, 0, 1, rx, ry * ys, 0, 1, rx, (ry - rh) * ys, 0, 1, rx + rw, (ry - rh) * ys, 0, 1 };
    c.gst_gl_context_thread_add(o.context, freeVertex, o);
    c.gst_gl_context_thread_add(o.context, initVertex, o);
}

fn overlayNew(ctx: OCtx, rect: ?*c.GstVideoOverlayRectangle, pa: c.GLint, ta: c.GLint) *Overlay {
    const o = ov(c.g_object_new(overlayType(), Z));
    o.gl_memory = null;
    o.texture_id = std.math.maxInt(c.GLuint);
    o.rectangle = @ptrCast(c.gst_mini_object_ref(@ptrCast(@alignCast(rect))));
    o.context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    o.vao = 0;
    o.position_attrib = pa;
    o.texcoord_attrib = ta;
    return o;
}

fn unmapFree(data: c.gpointer) callconv(.c) void {
    const f: *c.GstVideoFrame = @ptrCast(@alignCast(data));
    c.gst_video_frame_unmap(f);
    c.g_free(f);
}

fn upload(o: *Overlay, buf: [*c]c.GstBuffer) void {
    const flags = c.gst_video_overlay_rectangle_get_flags(o.rectangle);
    var alpha: c.GstVideoOverlayFormatFlags = 0;
    if (flags & c.GST_VIDEO_OVERLAY_FORMAT_FLAG_PREMULTIPLIED_ALPHA != 0 or vt(o.context).BlendFuncSeparate == null) alpha = c.GST_VIDEO_OVERLAY_FORMAT_FLAG_PREMULTIPLIED_ALPHA;
    const comp = c.gst_video_overlay_rectangle_get_pixels_unscaled_argb(o.rectangle, alpha);
    const frame: *c.GstVideoFrame = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstVideoFrame))));
    const vm = c.gst_buffer_get_video_meta(comp);
    var info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&info, vm[0].format, vm[0].width, vm[0].height);
    info.stride[0] = vm[0].stride[0];
    if (c.gst_video_frame_map(frame, &info, comp, c.GST_MAP_READ) == 0) {
        c.g_free(frame);
        return;
    }
    const al: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(memory.gst_gl_memory_allocator_get_default(o.context)));
    addTransformation(o, buf);
    const params = memory.gst_gl_video_allocation_params_new_wrapped_data(o.context, null, &frame.info, 0, null, c.GST_GL_TEXTURE_TARGET_2D, c.GST_GL_RGBA, frame.data[0], frame, unmapFree);
    const mem: [*c]c.GstGLMemory = @ptrCast(@alignCast(base.gst_gl_base_memory_alloc(al, @ptrCast(params))));
    base.gst_gl_allocation_params_free(@ptrCast(params));
    c.gst_object_unref(al);
    const ob = c.gst_buffer_new();
    c.gst_buffer_append_memory(ob, @ptrCast(mem));
    var gf: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&gf, &frame.info, ob, c.GST_MAP_READ | c.GST_MAP_GL) == 0) {
        c.gst_buffer_unref(ob);
        unmapFree(frame);
        return;
    }
    _ = c.gst_memory_ref(@ptrCast(mem));
    o.gl_memory = mem;
    o.texture_id = mem[0].tex_id;
    c.gst_buffer_unref(ob);
    c.gst_video_frame_unmap(&gf);
}

fn draw(o: *Overlay) void {
    const gl = vt(o.context);
    if (gl.GenVertexArrays != null) gl.BindVertexArray.?(o.vao) else bindVertex(o);
    if (o.texture_id != std.math.maxInt(c.GLuint)) gl.BindTexture.?(c.GL_TEXTURE_2D, o.texture_id);
    gl.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
}

const Priv = struct {
    yinvert: c.gboolean,
};

const PROP_YINVERT = 1;

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(p)) + @as(usize, @bitCast(@as(isize, priv_offset)))));
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/gstgloverlaycompositor.c", line, "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_YINVERT) {
        pv(o).yinvert = c.g_value_get_boolean(v);
        return;
    }
    warnInvalid(o, id, spec, 463);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_YINVERT) {
        c.g_value_set_boolean(v, pv(o).yinvert);
        return;
    }
    warnInvalid(o, id, spec, 480);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const comp: OComp = @ptrCast(@alignCast(o));
    c.g_queue_free_full(comp[0].overlays, c.gst_object_unref);
    if (comp[0].context != null) c.gst_object_unref(comp[0].context);
    if (comp[0].shader != null) {
        c.gst_object_unref(comp[0].shader);
        comp[0].shader = null;
    }
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_YINVERT, c.g_param_spec_boolean("yinvert", "Y-Invert", "Whether to invert the output across a horizintal axis", 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    pv(inst).yinvert = 0;
    @as(OComp, @ptrCast(@alignCast(inst)))[0].overlays = c.g_queue_new();
}

pub export fn gst_gl_overlay_compositor_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLOverlayCompositor", c.GstGLOverlayCompositorClass, Comp, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("gloverlaycompositor", 0, "overlaycompositor");
            return t;
        }
    }.f);
}

fn initGl(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const comp: OComp = @ptrCast(@alignCast(data));
    var err: [*c]c.GError = null;
    const p: c.GstGLSLProfile = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;
    var frag = [2][*c]const u8{ strings.gst_gl_shader_string_get_highest_precision(ctx, c.GST_GLSL_VERSION_NONE, p), FRAGMENT };
    comp[0].shader = shader.gst_gl_shader_new_link_with_stages(ctx, &err, stage.gst_glsl_stage_new_default_vertex(ctx), stage.gst_glsl_stage_new_with_strings(ctx, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, p, 2, &frag), @as(?*anyopaque, null));
    if (comp[0].shader == null) return;
    comp[0].position_attrib = shader.gst_gl_shader_get_attribute_location(comp[0].shader, "a_position");
    comp[0].texcoord_attrib = shader.gst_gl_shader_get_attribute_location(comp[0].shader, "a_texcoord");
}

pub export fn gst_gl_overlay_compositor_new(ctx: OCtx) OComp {
    const comp: OComp = @ptrCast(@alignCast(c.g_object_new(gst_gl_overlay_compositor_get_type(), Z)));
    _ = c.gst_object_ref_sink(comp);
    comp[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    c.gst_gl_context_thread_add(comp[0].context, initGl, comp);
    return comp;
}

pub export fn gst_gl_overlay_compositor_free_overlays(comp: OComp) void {
    c.g_queue_clear_full(comp[0].overlays, c.gst_object_unref);
}

fn findOverlay(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const o: *const Overlay = @ptrCast(@alignCast(a));
    return if (@intFromPtr(o.rectangle) == @intFromPtr(b)) 0 else 1;
}

pub export fn gst_gl_overlay_compositor_upload_overlays(comp: OComp, buf: [*c]c.GstBuffer) void {
    const p = pv(comp);
    var old = comp[0].overlays[0].head;
    c.g_queue_init(comp[0].overlays);
    var state: c.gpointer = null;
    while (true) {
        const meta = c.gst_buffer_iterate_meta_filtered(buf, &state, c.gst_video_overlay_composition_meta_api_get_type());
        if (meta == null) break;
        const om: [*c]c.GstVideoOverlayCompositionMeta = @ptrCast(@alignCast(meta));
        const n = c.gst_video_overlay_composition_n_rectangles(om[0].overlay);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const rect = c.gst_video_overlay_composition_get_rectangle(om[0].overlay, i);
            const l = c.g_list_find_custom(old, rect, findOverlay);
            if (l == null) {
                const o = overlayNew(comp[0].context, rect, comp[0].position_attrib, comp[0].texcoord_attrib);
                _ = c.gst_object_ref_sink(o);
                o.yinvert = p.yinvert;
                upload(o, buf);
                c.g_queue_push_tail(comp[0].overlays, o);
            } else {
                old = c.g_list_remove_link(old, l);
                c.g_queue_push_tail_link(comp[0].overlays, l);
            }
            const sm = c.gst_buffer_get_meta(buf, syncmeta.gst_gl_sync_meta_api_get_type());
            if (sm != null) syncmeta.gst_gl_sync_meta_set_sync_point(@ptrCast(@alignCast(sm)), comp[0].context);
        }
    }
    c.g_list_free_full(old, c.gst_object_unref);
}

pub export fn gst_gl_overlay_compositor_draw_overlays(comp: OComp) void {
    const gl = vt(comp[0].context);
    if (c.g_queue_is_empty(comp[0].overlays) != 0) return;
    gl.Enable.?(c.GL_BLEND);
    shader.gst_gl_shader_use(comp[0].shader);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    shader.gst_gl_shader_set_uniform_1i(comp[0].shader, "tex", 0);
    var l: ?*c.GList = comp[0].overlays[0].head;
    while (l) |n| : (l = n.next) {
        const o = ov(n.data);
        const flags = c.gst_video_overlay_rectangle_get_flags(o.rectangle);
        if (flags & c.GST_VIDEO_OVERLAY_FORMAT_FLAG_PREMULTIPLIED_ALPHA != 0 or gl.BlendFuncSeparate == null) {
            gl.BlendFunc.?(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        } else {
            gl.BlendFuncSeparate.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        }
        draw(o);
    }
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);
    gl.Disable.?(c.GL_BLEND);
}

pub export fn gst_gl_overlay_compositor_add_caps(caps: ?*c.GstCaps) ?*c.GstCaps {
    const comp = c.gst_caps_copy(caps);
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(comp)) : (i += 1) {
        const f = c.gst_caps_get_features(comp, i);
        if (c.gst_caps_features_is_any(f) == 0) c.gst_caps_features_add(f, "meta:GstVideoOverlayComposition");
    }
    return c.gst_caps_merge(comp, caps);
}
