const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");
const g3 = @import("graphene.zig");

const FILE = "../ext/gl/gstgltransformation.c";
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;
const MAXF = std.math.floatMax(f32);

const Prop = enum(c.guint) { fov = 1, ortho, translation_x, translation_y, translation_z, rotation_x, rotation_y, rotation_z, scale_x, scale_y, mvp, pivot_x, pivot_y, pivot_z };

const Self = extern struct {
    filter: c.GstGLFilter,
    shader: ?*c.GstGLShader,
    vao: c.GLuint,
    vbo_indices: c.GLuint,
    vertex_buffer: c.GLuint,
    attr_position: c.GLint,
    attr_texture: c.GLint,
    in_tex: [*c]c.GstGLMemory,
    out_tex: [*c]c.GstGLMemory,
    xrotation: f32,
    yrotation: f32,
    zrotation: f32,
    xscale: f32,
    yscale: f32,
    xtranslation: f32,
    ytranslation: f32,
    ztranslation: f32,
    xpivot: f32,
    ypivot: f32,
    zpivot: f32,
    fov: f32,
    aspect: f32,
    znear: f32,
    zfar: f32,
    ortho: c.gboolean,
    model_matrix: *g3.Matrix,
    view_matrix: *g3.Matrix,
    projection_matrix: *g3.Matrix,
    inv_model_matrix: *g3.Matrix,
    inv_view_matrix: *g3.Matrix,
    inv_projection_matrix: *g3.Matrix,
    mvp_matrix: *g3.Matrix,
    camera_position: *g3.Vec3,
    downstream_supports_affine_meta: c.gboolean,
    caps_change: c.gboolean,
};

const Class = extern struct {
    parent: c.GstGLFilterClass,
};

const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;
var parent_gl: *c.GstGLBaseFilterClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(el.base(s).context[0].gl_vtable));
}

fn narrow(x: f64) f32 {
    return @floatCast(x);
}

fn buildMvp(s: *Self) void {
    const bt: [*c]c.GstBaseTransform = @ptrCast(s);
    if (s.filter.out_info.finfo == null) {
        _ = g3.graphene_matrix_init_identity(s.model_matrix);
        _ = g3.graphene_matrix_init_identity(s.view_matrix);
        _ = g3.graphene_matrix_init_identity(s.projection_matrix);
    } else {
        const a: f64 = s.aspect;
        const translation = g3.Point3d{ .x = narrow(s.xtranslation * 2.0 * a), .y = narrow(s.ytranslation * 2.0), .z = narrow(s.ztranslation * 2.0) };
        var pivot = g3.Point3d{ .x = -s.xpivot * s.aspect, .y = s.ypivot, .z = -s.zpivot };
        var neg: g3.Point3d = undefined;
        var center: g3.Vec3 = undefined;
        var up: g3.Vec3 = undefined;
        _ = g3.graphene_vec3_init(s.camera_position, 0, 0, 1);
        _ = g3.graphene_vec3_init(&center, 0, 0, 0);
        _ = g3.graphene_vec3_init(&up, 0, 1, 0);
        _ = g3.graphene_matrix_init_translate(s.model_matrix, &pivot);
        g3.graphene_matrix_scale(s.model_matrix, s.xscale, s.yscale, 1);
        g3.graphene_matrix_rotate(s.model_matrix, s.xrotation, g3.graphene_vec3_x_axis());
        g3.graphene_matrix_rotate(s.model_matrix, s.yrotation, g3.graphene_vec3_y_axis());
        g3.graphene_matrix_rotate(s.model_matrix, s.zrotation, g3.graphene_vec3_z_axis());
        g3.graphene_point3d_scale(&pivot, -1, &neg);
        g3.graphene_matrix_translate(s.model_matrix, &neg);
        g3.graphene_matrix_translate(s.model_matrix, &translation);
        if (s.ortho != 0) {
            _ = g3.graphene_matrix_init_ortho(s.projection_matrix, -s.aspect, s.aspect, -1, 1, s.znear, s.zfar);
        } else {
            _ = g3.graphene_matrix_init_perspective(s.projection_matrix, s.fov, s.aspect, s.znear, s.zfar);
        }
        _ = g3.graphene_matrix_init_look_at(s.view_matrix, s.camera_position, &center, &up);
        const cur = c.gst_base_transform_is_passthrough(bt) != 0;
        const pass = s.xtranslation == 0 and s.ytranslation == 0 and s.ztranslation == 0 and s.xrotation == 0 and s.yrotation == 0 and s.zrotation == 0 and s.xscale == 1 and s.yscale == 1 and c.gst_video_info_is_equal(&s.filter.in_info, &s.filter.out_info) != 0;
        c.gst_base_transform_set_passthrough(bt, @intFromBool(pass));
        if (cur != pass) c.gst_base_transform_reconfigure_src(bt);
    }
    var mv: g3.Matrix = undefined;
    g3.graphene_matrix_multiply(s.model_matrix, s.view_matrix, &mv);
    g3.graphene_matrix_multiply(&mv, s.projection_matrix, s.mvp_matrix);
    _ = g3.graphene_matrix_inverse(s.model_matrix, s.inv_model_matrix);
    _ = g3.graphene_matrix_inverse(s.view_matrix, s.inv_view_matrix);
    _ = g3.graphene_matrix_inverse(s.projection_matrix, s.inv_projection_matrix);
}

fn floatField(s: *Self, id: c.guint) ?*f32 {
    return switch (id) {
        @intFromEnum(Prop.fov) => &s.fov,
        @intFromEnum(Prop.translation_x) => &s.xtranslation,
        @intFromEnum(Prop.translation_y) => &s.ytranslation,
        @intFromEnum(Prop.translation_z) => &s.ztranslation,
        @intFromEnum(Prop.rotation_x) => &s.xrotation,
        @intFromEnum(Prop.rotation_y) => &s.yrotation,
        @intFromEnum(Prop.rotation_z) => &s.zrotation,
        @intFromEnum(Prop.scale_x) => &s.xscale,
        @intFromEnum(Prop.scale_y) => &s.yscale,
        @intFromEnum(Prop.pivot_x) => &s.xpivot,
        @intFromEnum(Prop.pivot_y) => &s.ypivot,
        @intFromEnum(Prop.pivot_z) => &s.zpivot,
        else => null,
    };
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (floatField(s, id)) |f| {
        f.* = c.g_value_get_float(v);
    } else if (id == @intFromEnum(Prop.ortho)) {
        s.ortho = c.g_value_get_boolean(v);
    } else cm.warnInvalid(FILE, o, id, spec, 454);
    buildMvp(s);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (floatField(s, id)) |f| {
        c.g_value_set_float(v, f.*);
    } else if (id == @intFromEnum(Prop.ortho)) {
        c.g_value_set_boolean(v, s.ortho);
    } else if (id == @intFromEnum(Prop.mvp)) {
        c.g_value_set_boxed(v, s.mvp_matrix);
    } else cm.warnInvalid(FILE, o, id, spec, 511);
}

fn setCaps(f: [*c]c.GstGLFilter, _: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(f);
    s.aspect = narrow(@as(f64, @floatFromInt(f[0].out_info.width)) / @as(f64, @floatFromInt(f[0].out_info.height)));
    s.caps_change = 1;
    buildMvp(s);
    return 1;
}

fn worldRay(s: *Self, x: f32, y: f32, ray: *g3.Ray) void {
    const w: f32 = @floatFromInt(s.filter.in_info.width);
    const h: f32 = @floatFromInt(s.filter.in_info.height);
    var screen: g3.Vec2 = undefined;
    _ = g3.graphene_vec2_init(&screen, narrow((2.0 * @as(f64, x) / w - 1.0) / s.aspect), narrow(1.0 - 2.0 * @as(f64, y) / h));
    var clip: g3.Point3d = undefined;
    var eye: g3.Point3d = undefined;
    _ = g3.graphene_point3d_init(&clip, g3.graphene_vec2_get_x(&screen), g3.graphene_vec2_get_y(&screen), -1);
    g3.graphene_matrix_transform_point3d(s.inv_projection_matrix, &clip, &eye);
    var eye3: g3.Vec3 = undefined;
    _ = g3.graphene_vec3_init(&eye3, eye.x, eye.y, -1);
    if (s.ortho != 0) {
        var dir: g3.Vec3 = undefined;
        _ = g3.graphene_vec3_init(&dir, 0, 0, 1);
        _ = g3.graphene_ray_init_from_vec3(ray, &eye3, &dir);
    } else {
        var dir: g3.Vec3 = undefined;
        g3.graphene_matrix_transform_vec3(s.inv_view_matrix, &eye3, &dir);
        g3.graphene_vec3_normalize(&dir, &dir);
        _ = g3.graphene_ray_init_from_vec3(ray, s.camera_position, &dir);
    }
}

fn toModel(s: *Self, x: f64, y: f64, rx: *f64, ry: *f64) bool {
    const w: f64 = @floatFromInt(s.filter.in_info.width);
    const h: f64 = @floatFromInt(s.filter.in_info.height);
    var p = [4]g3.Point3d{ .{ .x = -s.aspect, .y = 1, .z = 0 }, .{ .x = s.aspect, .y = 1, .z = 0 }, .{ .x = -s.aspect, .y = -1, .z = 0 }, .{ .x = s.aspect, .y = -1, .z = 0 } };
    var world: [4]g3.Point3d = undefined;
    for (0..4) |i| g3.graphene_matrix_transform_point3d(s.model_matrix, &p[i], &world[i]);
    var plane: g3.Plane = undefined;
    _ = g3.graphene_plane_init_from_points(&plane, &world[2], &world[1], &world[0]);
    var ray: g3.Ray = undefined;
    worldRay(s, narrow(x), narrow(y), &ray);
    const t = g3.graphene_ray_get_distance_to_plane(&ray, &plane);
    var wp: g3.Point3d = undefined;
    g3.graphene_ray_get_position_at(&ray, t, &wp);
    var model: g3.Point3d = undefined;
    g3.graphene_matrix_transform_point3d(s.inv_model_matrix, &wp, &model);
    const nx = (@as(f64, model.x) + 1.0) * w / 2;
    const ny = (1.0 - @as(f64, model.y)) * h / 2;
    if (nx < 0 or nx > w or ny < 0 or ny > h) return false;
    rx.* = nx;
    ry.* = ny;
    return true;
}

fn srcEvent(bt: [*c]c.GstBaseTransform, event: [*c]c.GstEvent) callconv(.c) c.gboolean {
    var e = event;
    if (e[0].type == c.GST_EVENT_NAVIGATION) {
        e = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(e)));
        var x: f64 = 0;
        var y: f64 = 0;
        if (c.gst_navigation_event_get_coordinates(e, &x, &y) != 0) {
            var nx: f64 = 0;
            var ny: f64 = 0;
            if (!toModel(me(bt), x, y, &nx, &ny)) {
                c.gst_event_unref(e);
                return 1;
            }
            _ = c.gst_navigation_event_set_coordinates(e, nx, ny);
        }
    }
    return parent.src_event.?(bt, e);
}

fn filterMeta(_: [*c]c.GstBaseTransform, _: [*c]c.GstQuery, api: c.GType, _: ?*const c.GstStructure) callconv(.c) c.gboolean {
    return @intFromBool(api == c.gst_video_affine_transformation_meta_api_get_type() or api == c.gst_gl_sync_meta_api_get_type());
}

fn decideAllocation(bt: [*c]c.GstBaseTransform, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (parent.decide_allocation.?(bt, q) == 0) return 0;
    me(bt).downstream_supports_affine_meta = c.gst_query_find_allocation_meta(q, c.gst_video_affine_transformation_meta_api_get_type(), null);
    return 1;
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const s = me(bf);
    const g = gl(s);
    if (s.vao != 0) g.DeleteVertexArrays.?(1, &s.vao);
    s.vao = 0;
    if (s.vertex_buffer != 0) g.DeleteBuffers.?(1, &s.vertex_buffer);
    s.vertex_buffer = 0;
    if (s.vbo_indices != 0) g.DeleteBuffers.?(1, &s.vbo_indices);
    s.vbo_indices = 0;
    if (s.shader != null) c.gst_object_unref(s.shader);
    s.shader = null;
    parent_gl.gl_stop.?(bf);
}

fn glStart(bf: [*c]c.GstGLBaseFilter) callconv(.c) c.gboolean {
    const s = me(bf);
    if (parent_gl.gl_start.?(bf) == 0) return 0;
    if (c.gst_gl_context_get_gl_api(bf[0].context) == 0) return 1;
    const frag = c.gst_gl_shader_string_fragment_get_default(bf[0].context, c.GST_GLSL_VERSION_NONE, PROFILE);
    defer c.g_free(frag);
    return el.genShader(bf[0].context, c.gst_gl_shader_string_vertex_mat4_vertex_transform, frag, &s.shader);
}

fn prepareOutput(bt: [*c]c.GstBaseTransform, in: [*c]c.GstBuffer, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    if (s.downstream_supports_affine_meta != 0 and c.gst_video_info_is_equal(&s.filter.in_info, &s.filter.out_info) != 0) {
        out.* = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(in)));
        const api = c.gst_video_affine_transformation_meta_api_get_type();
        var af: [*c]c.GstVideoAffineTransformationMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(out.*, api)));
        if (af == null) af = c.gst_buffer_add_video_affine_transformation_meta(out.*);
        var up: [16]f32 = undefined;
        var down: [16]f32 = undefined;
        c.gst_gl_get_affine_transformation_meta_as_ndc(af, &up);
        var um: g3.Matrix = undefined;
        var t1: g3.Matrix = undefined;
        var t2: g3.Matrix = undefined;
        var inv_aspect: g3.Matrix = undefined;
        var yflip: g3.Matrix = undefined;
        _ = g3.graphene_matrix_init_from_float(&um, &up);
        _ = g3.graphene_matrix_init_scale(&inv_aspect, s.aspect, -1, 1);
        _ = g3.graphene_matrix_init_scale(&yflip, 1, -1, 1);
        g3.graphene_matrix_multiply(&um, &inv_aspect, &t2);
        g3.graphene_matrix_multiply(&t2, s.mvp_matrix, &t1);
        g3.graphene_matrix_multiply(&t1, &yflip, &t2);
        g3.graphene_matrix_to_float(&t2, &down);
        c.gst_gl_set_affine_transformation_meta_from_ndc(af, &down);
        return c.GST_FLOW_OK;
    }
    return parent.prepare_output_buffer.?(bt, in, out);
}

fn filter(f: [*c]c.GstGLFilter, in: [*c]c.GstBuffer, out: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const s = me(f);
    if (s.downstream_supports_affine_meta != 0 and c.gst_video_info_is_equal(&f[0].in_info, &f[0].out_info) != 0) return 1;
    return c.gst_gl_filter_filter_texture(f, in, out);
}

fn filterTexture(f: [*c]c.GstGLFilter, in: [*c]c.GstGLMemory, out: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    me(f).in_tex = in;
    _ = c.gst_gl_framebuffer_draw_to_texture(f[0].fbo, out, draw, f);
    return 1;
}

fn upload(s: *Self) void {
    const g = gl(s);
    const a = s.aspect;
    const v = [_]f32{ -a, -1, 0, 1, 0, 0, a, -1, 0, 1, 1, 0, a, 1, 0, 1, 1, 1, -a, 1, 0, 1, 0, 1 };
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.vertex_buffer);
    g.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(v)), &v, c.GL_STATIC_DRAW);
}

fn bind(s: *Self) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.vertex_buffer);
    g.VertexAttribPointer.?(@bitCast(s.attr_position), 4, c.GL_FLOAT, c.GL_FALSE, 24, null);
    g.VertexAttribPointer.?(@bitCast(s.attr_texture), 2, c.GL_FLOAT, c.GL_FALSE, 24, @ptrFromInt(16));
    g.EnableVertexAttribArray.?(@bitCast(s.attr_position));
    g.EnableVertexAttribArray.?(@bitCast(s.attr_texture));
}

fn unbind(s: *Self) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    g.DisableVertexAttribArray.?(@bitCast(s.attr_position));
    g.DisableVertexAttribArray.?(@bitCast(s.attr_texture));
}

fn draw(data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const g = gl(s);
    const ctx = el.base(s).context;
    c.gst_gl_context_clear_shader(ctx);
    g.BindTexture.?(c.GL_TEXTURE_2D, 0);
    g.ClearColor.?(0, 0, 0, 0);
    g.Clear.?(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
    c.gst_gl_shader_use(s.shader);
    g.ActiveTexture.?(c.GL_TEXTURE0);
    g.BindTexture.?(c.GL_TEXTURE_2D, s.in_tex[0].tex_id);
    c.gst_gl_shader_set_uniform_1i(s.shader, "texture", 0);
    var m: [16]f32 = undefined;
    g3.graphene_matrix_to_float(s.mvp_matrix, &m);
    c.gst_gl_shader_set_uniform_matrix_4fv(s.shader, "u_transformation", 1, c.GL_FALSE, &m);
    const vao = g.GenVertexArrays != null;
    if (s.vertex_buffer == 0) {
        s.attr_position = c.gst_gl_shader_get_attribute_location(s.shader, "a_position");
        s.attr_texture = c.gst_gl_shader_get_attribute_location(s.shader, "a_texcoord");
        if (vao) {
            g.GenVertexArrays.?(1, &s.vao);
            g.BindVertexArray.?(s.vao);
        }
        g.GenBuffers.?(1, &s.vertex_buffer);
        g.GenBuffers.?(1, &s.vbo_indices);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
        g.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, c.GL_STATIC_DRAW);
        s.caps_change = 1;
    }
    if (vao) g.BindVertexArray.?(s.vao);
    if (s.caps_change != 0) upload(s);
    bind(s);
    g.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    if (vao) g.BindVertexArray.?(0) else unbind(s);
    c.gst_gl_context_clear_shader(ctx);
    s.caps_change = 0;
    return 1;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    g3.graphene_matrix_free(s.model_matrix);
    g3.graphene_matrix_free(s.view_matrix);
    g3.graphene_matrix_free(s.projection_matrix);
    g3.graphene_matrix_free(s.inv_model_matrix);
    g3.graphene_matrix_free(s.inv_view_matrix);
    g3.graphene_matrix_free(s.inv_projection_matrix);
    g3.graphene_matrix_free(s.mvp_matrix);
    g3.graphene_vec3_free(s.camera_position);
    parent_obj.finalize.?(o);
}

fn floatSpec(oc: *c.GObjectClass, id: Prop, name: [*:0]const u8, nick: [*:0]const u8, blurb: [*:0]const u8, def: f32) void {
    c.g_object_class_install_property(oc, @intFromEnum(id), c.g_param_spec_float(name, nick, blurb, -MAXF, MAXF, def, cm.RW));
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_gl = el.parentOf(c.GstGLBaseFilterClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    c.gst_gl_filter_add_rgba_pad_templates(@ptrCast(@alignCast(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const bt = el.baseTransformClass(k);
    bt.src_event = srcEvent;
    bt.decide_allocation = decideAllocation;
    bt.filter_meta = filterMeta;
    const bf: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bf.gl_start = glStart;
    bf.gl_stop = glStop;
    const fc: *c.GstGLFilterClass = @ptrCast(@alignCast(k));
    fc.set_caps = setCaps;
    fc.filter = filter;
    fc.filter_texture = filterTexture;
    bt.prepare_output_buffer = prepareOutput;
    c.g_object_class_install_property(oc, @intFromEnum(Prop.fov), c.g_param_spec_float("fov", "Fov", "Field of view angle in degrees", 0, MAXF, 90, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.ortho), c.g_param_spec_boolean("ortho", "Orthographic", "Use orthographic projection", 0, cm.RW));
    floatSpec(oc, .rotation_x, "rotation-x", "X Rotation", "Rotates the video around the X-Axis in degrees.", 0);
    floatSpec(oc, .rotation_y, "rotation-y", "Y Rotation", "Rotates the video around the Y-Axis in degrees.", 0);
    floatSpec(oc, .rotation_z, "rotation-z", "Z Rotation", "Rotates the video around the Z-Axis in degrees.", 0);
    floatSpec(oc, .translation_x, "translation-x", "X Translation", "Translates the video at the X-Axis, in universal [0-1] coordinate.", 0);
    floatSpec(oc, .translation_y, "translation-y", "Y Translation", "Translates the video at the Y-Axis, in universal [0-1] coordinate.", 0);
    floatSpec(oc, .translation_z, "translation-z", "Z Translation", "Translates the video at the Z-Axis, in universal [0-1] coordinate.", 0);
    floatSpec(oc, .scale_x, "scale-x", "X Scale", "Scale multiplier for the X-Axis.", 1);
    floatSpec(oc, .scale_y, "scale-y", "Y Scale", "Scale multiplier for the Y-Axis.", 1);
    floatSpec(oc, .pivot_x, "pivot-x", "X Pivot", "Rotation pivot point X coordinate, where 0 is the center, -1 the left border, +1 the right border and <-1, >1 outside.", 0);
    floatSpec(oc, .pivot_y, "pivot-y", "Y Pivot", "Rotation pivot point X coordinate, where 0 is the center, -1 the left border, +1 the right border and <-1, >1 outside.", 0);
    floatSpec(oc, .pivot_z, "pivot-z", "Z Pivot", "Relevant for rotation in 3D space. You look into the negative Z axis direction", 0);
    c.g_object_class_install_property(oc, @intFromEnum(Prop.mvp), c.g_param_spec_boxed("mvp-matrix", "Modelview Projection Matrix", "The final Graphene 4x4 Matrix for transformation", g3.graphene_matrix_get_type(), cm.RW));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "OpenGL transformation filter", "Filter/Effect/Video", "Transform video on the GPU", "Lubosz Sarnecki <lubosz@gmail.com>, Matthew Waters <matthew@centricular.com>");
    bf.supported_gl_api = c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2;
    oc.finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.fov = 90;
    s.aspect = 1;
    s.znear = 0.1;
    s.zfar = 100;
    s.xscale = 1;
    s.yscale = 1;
    s.model_matrix = g3.graphene_matrix_alloc();
    s.view_matrix = g3.graphene_matrix_alloc();
    s.projection_matrix = g3.graphene_matrix_alloc();
    s.inv_model_matrix = g3.graphene_matrix_alloc();
    s.inv_view_matrix = g3.graphene_matrix_alloc();
    s.inv_projection_matrix = g3.graphene_matrix_alloc();
    s.mvp_matrix = g3.graphene_matrix_alloc();
    s.camera_position = g3.graphene_vec3_alloc();
    buildMvp(s);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_filter_get_type(), "GstGLTransformation", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("gltransformation", 0, "gltransformation element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "gltransformation", c.GST_RANK_NONE, getType());
}
