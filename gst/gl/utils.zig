const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const display = @import("display.zig");
const format = @import("format.zig");
const egl_context = @import("egl/context.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const OCtx = [*c]c.GstGLContext;
const ODisp = [*c]c.GstGLDisplay;
const DISPLAY_CONTEXT = "gst.gl.GLDisplay";
const X11_CONTEXT = "gst.x11.display.handle";
const WAYLAND_CONTEXT = "GstWaylandDisplayHandleContextType";
const APP_CONTEXT = "gst.gl.app_context";
const LOCAL_CONTEXT = "gst.gl.local_context";
const DRM_INVALID: u32 = 0;
const Z = @as([*c]const u8, null);

var utils_done: usize = 0;
var ctx_done: usize = 0;

fn initDebug() void {
    if (c.g_once_init_enter(&utils_done) != 0) {
        _ = c._gst_debug_category_new("glutils", 0, "OpenGL Utilities");
        c.g_once_init_leave(&utils_done, 1);
    }
}

fn initContextDebug() void {
    if (c.g_once_init_enter(&ctx_done) != 0) {
        _ = c._gst_debug_get_category("GST_CONTEXT");
        c.g_once_init_leave(&ctx_done, 1);
    }
}

fn padQuery(item: [*c]const c.GValue, value: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    initContextDebug();
    const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(item)));
    if (c.gst_pad_peer_query(pad, @ptrCast(@alignCast(data))) != 0) {
        c.g_value_set_boolean(value, 1);
        return 0;
    }
    return 1;
}

pub fn runQuery(element: ?*c.GstElement, q: ?*c.GstQuery, dir: c.GstPadDirection) bool {
    var res = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&res, c.G_TYPE_BOOLEAN);
    c.g_value_set_boolean(&res, 0);
    const it = if (dir == c.GST_PAD_SRC) c.gst_element_iterate_src_pads(element) else c.gst_element_iterate_sink_pads(element);
    while (c.gst_iterator_fold(it, padQuery, &res, q) == c.GST_ITERATOR_RESYNC) c.gst_iterator_resync(it);
    c.gst_iterator_free(it);
    return c.g_value_get_boolean(&res) != 0;
}

fn contextQuery(element: ?*c.GstElement, t: [*:0]const u8) void {
    initContextDebug();
    const q = c.gst_query_new_context(t);
    var ctx: ?*c.GstContext = null;
    if (runQuery(element, q, c.GST_PAD_SRC) or runQuery(element, q, c.GST_PAD_SINK)) {
        c.gst_query_parse_context(q, &ctx);
        c.gst_element_set_context(element, ctx);
    } else {
        _ = c.gst_element_post_message(element, c.gst_message_new_need_context(@ptrCast(element), t));
    }
    c.gst_query_unref(q);
}

pub export fn gst_gl_element_propagate_display_context(element: ?*c.GstElement, d: ODisp) void {
    if (d == null) return;
    initContextDebug();
    const ctx = c.gst_context_new(DISPLAY_CONTEXT, 1);
    display.gst_context_set_gl_display(ctx, d);
    c.gst_element_set_context(element, ctx);
    _ = c.gst_element_post_message(element, c.gst_message_new_have_context(@ptrCast(element), ctx));
}

pub export fn gst_gl_ensure_element_data(element: c.gpointer, dptr: [*c]ODisp, optr: [*c]OCtx) c.gboolean {
    const fname = "gst_gl_ensure_element_data";
    initDebug();
    if (!check.that(element != null, fname, "element != NULL")) return 0;
    if (!check.that(dptr != null, fname, "display_ptr != NULL")) return 0;
    if (!check.that(optr != null, fname, "other_context_ptr != NULL")) return 0;
    const el: ?*c.GstElement = @ptrCast(@alignCast(element));
    if (dptr[0] != null) return 1;
    contextQuery(el, DISPLAY_CONTEXT);
    if (dptr[0] == null) contextQuery(el, X11_CONTEXT);
    if (dptr[0] == null) contextQuery(el, WAYLAND_CONTEXT);
    if (dptr[0] == null) {
        dptr[0] = display.gst_gl_display_new();
        gst_gl_element_propagate_display_context(el, dptr[0]);
    }
    if (optr[0] == null) contextQuery(el, APP_CONTEXT);
    return @intFromBool(dptr[0] != null);
}

pub export fn gst_gl_handle_set_context(element: ?*c.GstElement, ctx: ?*c.GstContext, dptr: [*c]ODisp, optr: [*c]OCtx) c.gboolean {
    const fname = "gst_gl_handle_set_context";
    initDebug();
    if (!check.that(dptr != null, fname, "display != NULL")) return 0;
    if (!check.that(optr != null, fname, "other_context != NULL")) return 0;
    if (ctx == null) return 0;
    var dr: ODisp = null;
    var cr: OCtx = null;
    const t = c.gst_context_get_context_type(ctx);
    if (c.g_strcmp0(t, DISPLAY_CONTEXT) == 0) {
        if (display.gst_context_get_gl_display(ctx, &dr) == 0) return 0;
    } else if (c.g_strcmp0(t, X11_CONTEXT) == 0) {
        var p: ?*anyopaque = null;
        if (c.gst_structure_get(c.gst_context_get_structure(ctx), "display", c.G_TYPE_POINTER, &p, Z) != 0) dr = @ptrCast(c.gst_gl_display_x11_new_with_display(@ptrCast(p)));
    } else if (c.g_strcmp0(t, WAYLAND_CONTEXT) == 0) {
        var p: ?*anyopaque = null;
        if (c.gst_structure_get(c.gst_context_get_structure(ctx), "display", c.G_TYPE_POINTER, &p, Z) != 0) dr = @ptrCast(c.gst_gl_display_wayland_new_with_display(@ptrCast(p)));
    } else if (c.g_strcmp0(t, APP_CONTEXT) == 0) {
        if (c.gst_structure_get(c.gst_context_get_structure(ctx), "context", context.gst_gl_context_get_type(), &cr, Z) != 0) {
            const cd = context.gst_gl_context_get_display(cr);
            const ed = dptr[0];
            if (ed != null and display.gst_gl_display_get_handle_type(ed) & display.gst_gl_display_get_handle_type(cd) == 0) {
                const msg: [*c]const u8 = "Cannot set a GL context with a different display type";
                c.gst_element_message_full(element, c.GST_MESSAGE_WARNING, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_SETTINGS, c.g_strdup_printf("%s", msg), c.g_strdup_printf("%s", msg), "../gst-libs/gst/gl/gstglutils.c", "gst_gl_handle_set_context", 392);
                c.gst_object_unref(cr);
                cr = null;
            }
            c.gst_object_unref(cd);
        }
    }
    if (dr != null) {
        const old = dptr[0];
        dptr[0] = dr;
        if (old != null) c.gst_object_unref(old);
    }
    if (cr != null) {
        const old = optr[0];
        optr[0] = cr;
        if (old != null) c.gst_object_unref(old);
    }
    return 1;
}

fn contextFor(q: ?*c.GstQuery, t: [*:0]const u8) ?*c.GstContext {
    var old: ?*c.GstContext = null;
    c.gst_query_parse_context(q, &old);
    return if (old != null) c.gst_context_copy(old) else c.gst_context_new(t, 1);
}

fn finish(q: ?*c.GstQuery, ctx: ?*c.GstContext) c.gboolean {
    c.gst_query_set_context(q, ctx);
    c.gst_context_unref(ctx);
    return 1;
}

pub export fn gst_gl_handle_context_query(element: ?*c.GstElement, q: ?*c.GstQuery, d: ODisp, gl_ctx: OCtx, other: OCtx) c.gboolean {
    const fname = "gst_gl_handle_context_query";
    initDebug();
    if (!check.that(gtype.instanceOf(element, c.gst_element_get_type()), fname, "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(q != null and @as(*c.GstMiniObject, @ptrCast(@alignCast(q))).type == c.gst_query_get_type(), fname, "GST_IS_QUERY (query)")) return 0;
    if (!check.that(d == null or display.isDisplay(d), fname, "display == NULL || GST_IS_GL_DISPLAY (display)")) return 0;
    if (!check.that(gl_ctx == null or context.isContext(gl_ctx), fname, "gl_context == NULL || GST_IS_GL_CONTEXT (gl_context)")) return 0;
    if (!check.that(other == null or context.isContext(other), fname, "other_context == NULL || GST_IS_GL_CONTEXT (other_context)")) return 0;
    var t: [*c]const u8 = null;
    _ = c.gst_query_parse_context_type(q, &t);
    if (d != null and c.g_strcmp0(t, DISPLAY_CONTEXT) == 0) {
        const ctx = contextFor(q, DISPLAY_CONTEXT);
        display.gst_context_set_gl_display(ctx, d);
        return finish(q, ctx);
    } else if (d != null and c.g_strcmp0(t, X11_CONTEXT) == 0) {
        const ctx = contextFor(q, X11_CONTEXT);
        if (display.gst_gl_display_get_handle_type(d) & c.GST_GL_DISPLAY_TYPE_X11 != 0) {
            const h = display.gst_gl_display_get_handle(d);
            if (h != 0) {
                c.gst_structure_set(c.gst_context_writable_structure(ctx), "display", c.G_TYPE_POINTER, h, Z);
                return finish(q, ctx);
            }
        }
    } else if (d != null and c.g_strcmp0(t, WAYLAND_CONTEXT) == 0) {
        const ctx = contextFor(q, WAYLAND_CONTEXT);
        if (display.gst_gl_display_get_handle_type(d) & c.GST_GL_DISPLAY_TYPE_WAYLAND != 0) {
            const h = display.gst_gl_display_get_handle(d);
            if (h != 0) {
                c.gst_structure_set(c.gst_context_writable_structure(ctx), "display", c.G_TYPE_POINTER, h, Z);
                return finish(q, ctx);
            }
        }
    } else if (other != null and c.g_strcmp0(t, APP_CONTEXT) == 0) {
        const ctx = contextFor(q, APP_CONTEXT);
        c.gst_structure_set(c.gst_context_writable_structure(ctx), "context", context.gst_gl_context_get_type(), other, Z);
        return finish(q, ctx);
    } else if (gl_ctx != null and c.g_strcmp0(t, LOCAL_CONTEXT) == 0) {
        const ctx = contextFor(q, LOCAL_CONTEXT);
        c.gst_structure_set(c.gst_context_writable_structure(ctx), "context", context.gst_gl_context_get_type(), gl_ctx, Z);
        return finish(q, ctx);
    }
    return 0;
}

pub export fn gst_gl_query_local_gl_context(element: ?*c.GstElement, dir: c.GstPadDirection, cptr: [*c]OCtx) c.gboolean {
    const fname = "gst_gl_query_local_gl_context";
    if (!check.that(gtype.instanceOf(element, c.gst_element_get_type()), fname, "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(cptr != null, fname, "context_ptr != NULL")) return 0;
    if (cptr[0] != null) return 1;
    const q = c.gst_query_new_context(LOCAL_CONTEXT);
    if (runQuery(element, q, dir)) {
        var ctx: ?*c.GstContext = null;
        c.gst_query_parse_context(q, &ctx);
        if (ctx != null) _ = c.gst_structure_get(c.gst_context_get_structure(ctx), "context", context.gst_gl_context_get_type(), cptr, Z);
    }
    c.gst_query_unref(q);
    return @intFromBool(cptr[0] != null);
}

pub export fn gst_gl_get_plane_data_size(info: [*c]const c.GstVideoInfo, valign: [*c]const c.GstVideoAlignment, plane: c.guint) c.gsize {
    const fi = info[0].finfo;
    if (fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_TILED != 0) {
        const stride: c.gsize = @bitCast(@as(isize, info[0].stride[plane]));
        const x: c.gint = @intCast(stride & 0xffff);
        const y: c.gint = @intCast(stride >> 16);
        const ts: c.gint = @bitCast(fi[0].tile_info[plane].size);
        return @bitCast(@as(isize, x * y * ts));
    }
    var comp: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
    c.gst_video_format_info_component(fi, plane, &comp);
    var h: c.gint = info[0].height;
    if (valign != null) h += @bitCast(valign[0].padding_top + valign[0].padding_bottom);
    const n: c.gint = @as(c.gint, 1) << @intCast(fi[0].h_sub[c.GST_VIDEO_COMP_U]);
    h = (h + n - 1) & ~(n - 1);
    h = -((-h) >> @intCast(fi[0].h_sub[@intCast(comp[0])]));
    return @bitCast(@as(isize, info[0].stride[plane]) * @as(isize, h));
}

pub export fn gst_gl_get_plane_start(info: [*c]const c.GstVideoInfo, valign: [*c]const c.GstVideoAlignment, plane: c.guint) c.gsize {
    var start: c.gsize = 0;
    var i: c.guint = 0;
    while (i < plane) : (i += 1) start += gst_gl_get_plane_data_size(info, valign, i);
    return info[0].offset[plane] -% start;
}

pub export fn gst_gl_value_get_texture_target_mask(v: [*c]const c.GValue) c.GstGLTextureTarget {
    if (!check.that(v != null, "gst_gl_value_get_texture_target_mask", "targets != NULL")) return c.GST_GL_TEXTURE_TARGET_NONE;
    var mask: c.guint = 0;
    if (c.g_type_check_value_holds(v, c.G_TYPE_STRING) != 0) {
        const t = format.gst_gl_texture_target_from_string(c.g_value_get_string(v));
        if (t != 0) mask |= @as(c.guint, 1) << @intCast(t);
    } else if (c.g_type_check_value_holds(v, c.gst_value_list_get_type()) != 0) {
        const n = c.gst_value_list_get_size(v);
        var j: c.guint = 0;
        while (j < n) : (j += 1) {
            const t = format.gst_gl_texture_target_from_string(c.g_value_get_string(c.gst_value_list_get_value(v, j)));
            if (t != 0) mask |= @as(c.guint, 1) << @intCast(t);
        }
    }
    return mask;
}

pub export fn gst_gl_value_set_texture_target(v: [*c]c.GValue, t: c.GstGLTextureTarget) c.gboolean {
    const fname = "gst_gl_value_set_texture_target";
    if (!check.that(v != null, fname, "value != NULL")) return 0;
    if (!check.that(t != c.GST_GL_TEXTURE_TARGET_NONE, fname, "target != GST_GL_TEXTURE_TARGET_NONE")) return 0;
    const s = format.gst_gl_texture_target_to_string(t);
    if (s == null) return 0;
    c.g_value_set_static_string(v, s);
    return 1;
}

pub export fn gst_gl_value_set_texture_target_from_mask(v: [*c]c.GValue, mask: c.GstGLTextureTarget) c.gboolean {
    const fname = "gst_gl_value_set_texture_target_from_mask";
    if (!check.that(v != null, fname, "value != NULL")) return 0;
    if (!check.that(mask != c.GST_GL_TEXTURE_TARGET_NONE, fname, "target_mask != GST_GL_TEXTURE_TARGET_NONE")) return 0;
    if (mask & (mask -% 1) == 0) {
        _ = c.g_value_init(v, c.G_TYPE_STRING);
        return gst_gl_value_set_texture_target(v, std.math.log2_int(c.guint, mask));
    }
    var item = std.mem.zeroes(c.GValue);
    var ok: c.gboolean = 0;
    _ = c.g_value_init(v, c.gst_value_list_get_type());
    _ = c.g_value_init(&item, c.G_TYPE_STRING);
    const all = [_]c.GstGLTextureTarget{ c.GST_GL_TEXTURE_TARGET_2D, c.GST_GL_TEXTURE_TARGET_RECTANGLE, c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES };
    for (all) |t| {
        if (mask & (@as(c.guint, 1) << @intCast(t)) != 0) {
            _ = gst_gl_value_set_texture_target(&item, t);
            c.gst_value_list_append_value(v, &item);
            ok = 1;
        }
    }
    c.g_value_unset(&item);
    return ok;
}

const IDENTITY = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
const FROM_NDC = [16]f32{ 0.5, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0.5, 0, 0.5, 0.5, 0.5, 1 };
const TO_NDC = [16]f32{ 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, -1, -1, -1, 1 };

pub export fn gst_gl_multiply_matrix4(a: [*c]const f32, b: [*c]const f32, r: [*c]f32) void {
    const fname = "gst_gl_multiply_matrix4";
    if (!check.that(a != null, fname, "a != NULL")) return;
    if (!check.that(b != null, fname, "b != NULL")) return;
    if (!check.that(r != null, fname, "result != NULL")) return;
    var tmp = [_]f32{0} ** 16;
    for (0..4) |i| {
        for (0..4) |j| {
            for (0..4) |k| tmp[j + i * 4] += a[k + i * 4] * b[j + k * 4];
        }
    }
    for (0..16) |i| r[i] = tmp[i];
}

pub export fn gst_gl_get_affine_transformation_meta_as_ndc(meta: [*c]c.GstVideoAffineTransformationMeta, m: [*c]f32) void {
    if (!check.that(m != null, "gst_gl_get_affine_transformation_meta_as_ndc", "matrix != NULL")) return;
    if (meta == null) {
        for (0..16) |i| m[i] = IDENTITY[i];
        return;
    }
    var tmp: [16]f32 = undefined;
    gst_gl_multiply_matrix4(&FROM_NDC, &meta[0].matrix, &tmp);
    gst_gl_multiply_matrix4(&tmp, &TO_NDC, m);
}

pub export fn gst_gl_set_affine_transformation_meta_from_ndc(meta: [*c]c.GstVideoAffineTransformationMeta, m: [*c]const f32) void {
    const fname = "gst_gl_set_affine_transformation_meta_from_ndc";
    if (!check.that(meta != null, fname, "meta != NULL")) return;
    if (!check.that(m != null, fname, "matrix != NULL")) return;
    var tmp: [16]f32 = undefined;
    gst_gl_multiply_matrix4(&TO_NDC, m, &tmp);
    gst_gl_multiply_matrix4(&tmp, &FROM_NDC, &meta[0].matrix);
}

fn appendDrm(ctx: OCtx, f: c.GstVideoFormat, flags: c.GstGLDrmFormatFlags, out: *c.GPtrArray) void {
    const external = flags & c.GST_GL_DRM_FORMAT_INCLUDE_EXTERNAL != 0;
    if (flags & c.GST_GL_DRM_FORMAT_DIRECT_IMPORT != 0) {
        if (f != c.GST_VIDEO_FORMAT_RGBA) return;
        egl_context.appendDrmFormats(ctx, out, external);
        return;
    }
    var modifier: u64 = 0;
    const fourcc = c.gst_video_dma_drm_format_from_gst_format(f, &modifier);
    if (fourcc == DRM_INVALID) return;
    if (flags & c.GST_GL_DRM_FORMAT_LINEAR_ONLY != 0 and modifier != 0) return;
    if (egl_context.supportsModifierFor(ctx, fourcc, modifier, external) or (flags & c.GST_GL_DRM_FORMAT_INCLUDE_EMULATED != 0 and c.gst_egl_image_can_emulate(ctx, f) != 0))
        c.g_ptr_array_add(out, c.gst_video_dma_drm_fourcc_to_string(fourcc, modifier));
}

fn holdsString(v: [*c]const c.GValue) bool {
    return c.g_type_check_value_holds(v, c.G_TYPE_STRING) != 0;
}

fn holdsList(v: [*c]const c.GValue) bool {
    return v != null and v[0].g_type == c.gst_value_list_get_type();
}

pub export fn gst_gl_dma_buf_transform_gst_formats_to_drm_formats(ctx: OCtx, src: [*c]const c.GValue, flags: c.GstGLDrmFormatFlags, dst: [*c]c.GValue) c.gboolean {
    if (!egl_context.isEgl(ctx)) return 0;
    const all = c.g_ptr_array_new();
    if (holdsString(src)) {
        const f = c.gst_video_format_from_string(c.g_value_get_string(src));
        if (f != c.GST_VIDEO_FORMAT_UNKNOWN) appendDrm(ctx, f, flags, all);
    } else if (holdsList(src)) {
        const n = c.gst_value_list_get_size(src);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const f = c.gst_video_format_from_string(c.g_value_get_string(c.gst_value_list_get_value(src, i)));
            if (f == c.GST_VIDEO_FORMAT_UNKNOWN) continue;
            appendDrm(ctx, f, flags, all);
        }
    }
    defer c.g_ptr_array_unref(all);
    if (all[0].len == 0) return 0;
    if (all[0].len == 1) {
        _ = c.g_value_init(dst, c.G_TYPE_STRING);
        c.g_value_take_string(dst, @ptrCast(all[0].pdata[0]));
        return 1;
    }
    var item = std.mem.zeroes(c.GValue);
    _ = c.gst_value_list_init(dst, all[0].len);
    for (0..all[0].len) |i| {
        _ = c.g_value_init(&item, c.G_TYPE_STRING);
        c.g_value_take_string(&item, @ptrCast(all[0].pdata[i]));
        c.gst_value_list_append_value(dst, &item);
        c.g_value_unset(&item);
    }
    return 1;
}

fn fromDrm(ctx: OCtx, s: [*c]const u8, flags: c.GstGLDrmFormatFlags) c.GstVideoFormat {
    var modifier: u64 = 0;
    const fourcc = c.gst_video_dma_drm_fourcc_from_string(s, &modifier);
    if (fourcc == DRM_INVALID) return c.GST_VIDEO_FORMAT_UNKNOWN;
    if (flags & c.GST_GL_DRM_FORMAT_LINEAR_ONLY != 0 and modifier != 0) return c.GST_VIDEO_FORMAT_UNKNOWN;
    const f: c.GstVideoFormat = if (flags & c.GST_GL_DRM_FORMAT_DIRECT_IMPORT != 0) c.GST_VIDEO_FORMAT_RGBA else c.gst_video_dma_drm_format_to_gst_format(fourcc, modifier);
    if (f == c.GST_VIDEO_FORMAT_UNKNOWN) return f;
    if (!egl_context.supportsModifierFor(ctx, fourcc, modifier, flags & c.GST_GL_DRM_FORMAT_INCLUDE_EXTERNAL != 0) and !(flags & c.GST_GL_DRM_FORMAT_INCLUDE_EMULATED != 0 and c.gst_egl_image_can_emulate(ctx, f) != 0)) return c.GST_VIDEO_FORMAT_UNKNOWN;
    return f;
}

pub export fn gst_gl_dma_buf_transform_drm_formats_to_gst_formats(ctx: OCtx, src: [*c]const c.GValue, flags: c.GstGLDrmFormatFlags, dst: [*c]c.GValue) c.gboolean {
    if (!egl_context.isEgl(ctx)) return 0;
    var list: std.ArrayList(c.GstVideoFormat) = .empty;
    defer list.deinit(std.heap.c_allocator);
    if (holdsString(src)) {
        const f = fromDrm(ctx, c.g_value_get_string(src), flags);
        if (f != c.GST_VIDEO_FORMAT_UNKNOWN) list.append(std.heap.c_allocator, f) catch return 0;
    } else if (holdsList(src)) {
        const n = c.gst_value_list_get_size(src);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const f = fromDrm(ctx, c.g_value_get_string(c.gst_value_list_get_value(src, i)), flags);
            if (f == c.GST_VIDEO_FORMAT_UNKNOWN) continue;
            list.append(std.heap.c_allocator, f) catch return 0;
        }
    }
    if (list.items.len == 0) return 0;
    if (list.items.len == 1) {
        _ = c.g_value_init(dst, c.G_TYPE_STRING);
        c.g_value_set_string(dst, c.gst_video_format_to_string(list.items[0]));
        return 1;
    }
    var item = std.mem.zeroes(c.GValue);
    _ = c.gst_value_list_init(dst, @intCast(list.items.len));
    for (list.items) |f| {
        _ = c.g_value_init(&item, c.G_TYPE_STRING);
        c.g_value_set_string(&item, c.gst_video_format_to_string(f));
        c.gst_value_list_append_value(dst, &item);
        c.g_value_unset(&item);
    }
    return 1;
}
