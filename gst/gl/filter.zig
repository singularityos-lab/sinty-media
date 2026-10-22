const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const basefilter = @import("basefilter.zig");
const bufferpool = @import("bufferpool.zig");
const framebuffer = @import("framebuffer.zig");
const format = @import("format.zig");
const memory = @import("memory.zig");
const shader = @import("shader.zig");
const syncmeta = @import("syncmeta.zig");
const debug = @import("debug.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Filter = c.GstGLFilter;
const OFilter = [*c]Filter;
const Class = c.GstGLFilterClass;
const OTrans = [*c]c.GstBaseTransform;
const OCtx = [*c]c.GstGLContext;
const FILE = "gstglfilter.c";
const Z = @as([*c]const u8, null);

const RGBA_GL = "video/x-raw(memory:GLMemory), format = (string) RGBA, width = (int) [ 1, max ], height = (int) [ 1, max ], framerate = (fraction) [ 0, max ],texture-target = (string) 2D";
const RGBA_ANY = "video/x-raw(ANY), format = (string) RGBA, width = (int) [ 1, max ], height = (int) [ 1, max ], framerate = (fraction) [ 0, max ],texture-target = (string) 2D";

var src_template = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = RGBA_GL ++ " ; " ++ RGBA_ANY, ._gst_reserved = std.mem.zeroes([4]c.gpointer) } };
var sink_template = c.GstStaticPadTemplate{ .name_template = "sink", .direction = c.GST_PAD_SINK, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = RGBA_ANY ++ " ; " ++ RGBA_GL, ._gst_reserved = std.mem.zeroes([4]c.gpointer) } };

var once: gtype.Once = .{};
var parent: ?*c.GstGLBaseFilterClass = null;

fn fl(p: anytype) OFilter {
    return @ptrCast(@alignCast(p));
}

fn klass(f: anytype) *Class {
    return gtype.classPeek(Class, f);
}

fn tparent() *c.GstBaseTransformClass {
    return @ptrCast(@alignCast(parent.?));
}

fn vt(ctx: OCtx) *c.GstGLFuncs {
    return @ptrCast(ctx[0].gl_vtable);
}

fn ctxOf(f: OFilter) OCtx {
    return f[0].parent.context;
}

pub export fn gst_gl_filter_add_rgba_pad_templates(k: [*c]Class) void {
    const ec: [*c]c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_template);
    c.gst_element_class_add_static_pad_template(ec, &sink_template);
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/" ++ FILE, line, "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 174);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, _: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 185);
}

fn stop(t: OTrans) callconv(.c) c.gboolean {
    _ = c.gst_mini_object_replace(@ptrCast(&fl(t)[0].out_caps), null);
    return tparent().stop.?(t);
}

fn glStop(bf: [*c]c.GstGLBaseFilter) callconv(.c) void {
    const f = fl(bf);
    const gl = vt(bf[0].context);
    if (f[0].vao != 0) {
        gl.DeleteVertexArrays.?(1, &f[0].vao);
        f[0].vao = 0;
    }
    if (f[0].vertex_buffer != 0) {
        gl.DeleteBuffers.?(1, &f[0].vertex_buffer);
        f[0].vertex_buffer = 0;
    }
    if (f[0].vbo_indices != 0) {
        gl.DeleteBuffers.?(1, &f[0].vbo_indices);
        f[0].vbo_indices = 0;
    }
    if (f[0].fbo != null) {
        c.gst_object_unref(f[0].fbo);
        f[0].fbo = null;
    }
    f[0].default_shader = null;
    f[0].draw_attr_position_loc = -1;
    f[0].draw_attr_texture_loc = -1;
    parent.?.gl_stop.?(bf);
}

fn negotiationError(t: OTrans, line: c.gint) void {
    check.elementMessage(t, c.GST_MESSAGE_ERROR, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Error calculating the output scaled size - integer overflow"), FILE, "gst_gl_filter_fixate_caps", line);
}

fn getInt(s: ?*c.GstStructure, f: [*:0]const u8) c.gint {
    var v: c.gint = 0;
    _ = c.gst_structure_get_int(s, f, &v);
    return v;
}

fn scale(v: c.gint, n: c.gint, d: c.gint) c.gint {
    return @truncate(@as(i64, @bitCast(c.gst_util_uint64_scale_int(@bitCast(@as(i64, v)), n, d))));
}

fn setWH(s: ?*c.GstStructure, w: c.gint, h: c.gint) void {
    c.gst_structure_set(s, "width", c.G_TYPE_INT, w, "height", c.G_TYPE_INT, h, Z);
}

fn setPar(s: ?*c.GstStructure, n: c.gint, d: c.gint) void {
    if (c.gst_structure_has_field(s, "pixel-aspect-ratio") != 0 or n != d) c.gst_structure_set(s, "pixel-aspect-ratio", c.gst_fraction_get_type(), n, d, Z);
}

fn fixateSize(t: OTrans, ins: ?*c.GstStructure, outs: ?*c.GstStructure, from_par: [*c]const c.GValue, to_par_in: [*c]const c.GValue) void {
    var to_par = to_par_in;
    if (!check.that(c.gst_value_is_fixed(from_par) != 0, "gst_gl_filter_fixate_caps", "gst_value_is_fixed (from_par)")) return;
    const fpn = c.gst_value_get_fraction_numerator(from_par);
    const fpd = c.gst_value_get_fraction_denominator(from_par);
    const fw = getInt(ins, "width");
    const fh = getInt(ins, "height");
    var w = getInt(outs, "width");
    var h = getInt(outs, "height");
    if (w != 0 and h != 0) {
        if (c.gst_value_is_fixed(to_par) == 0 and c.gst_structure_has_field(outs, "pixel-aspect-ratio") != 0) _ = c.gst_structure_fixate_field_nearest_fraction(outs, "pixel-aspect-ratio", 1, 1);
        return;
    }
    var dn: c.gint = 0;
    var dd: c.gint = 0;
    if (c.gst_util_fraction_multiply(fw, fh, fpn, fpd, &dn, &dd) == 0) return negotiationError(t, 329);
    var num: c.gint = 0;
    var den: c.gint = 0;
    if (h != 0 or w != 0) {
        if (c.gst_value_is_fixed(to_par) == 0) {
            _ = c.gst_structure_fixate_field_nearest_fraction(outs, "pixel-aspect-ratio", 1, 1);
            to_par = c.gst_structure_get_value(outs, "pixel-aspect-ratio");
        }
        const tpn = c.gst_value_get_fraction_numerator(to_par);
        const tpd = c.gst_value_get_fraction_denominator(to_par);
        if (c.gst_util_fraction_multiply(dn, dd, tpd, tpn, &num, &den) == 0) return negotiationError(t, if (h != 0) 364 else 397);
        if (h != 0) {
            w = scale(h, num, den);
            _ = c.gst_structure_fixate_field_nearest_int(outs, "width", w);
        } else {
            h = scale(w, den, num);
            _ = c.gst_structure_fixate_field_nearest_int(outs, "height", h);
        }
        return;
    }
    if (c.gst_value_is_fixed(to_par) != 0) {
        const tpn = c.gst_value_get_fraction_numerator(to_par);
        const tpd = c.gst_value_get_fraction_denominator(to_par);
        if (c.gst_util_fraction_multiply(dn, dd, tpn, tpd, &num, &den) == 0) return negotiationError(t, 416);
        var tmp = c.gst_structure_copy(outs);
        _ = c.gst_structure_fixate_field_nearest_int(tmp, "height", fh);
        var sh = getInt(tmp, "height");
        w = scale(sh, num, den);
        _ = c.gst_structure_fixate_field_nearest_int(tmp, "width", w);
        var sw = getInt(tmp, "width");
        c.gst_structure_free(tmp);
        if (sw == w) return setWH(outs, sw, sh);
        const f_h = sh;
        const f_w = sw;
        tmp = c.gst_structure_copy(outs);
        _ = c.gst_structure_fixate_field_nearest_int(tmp, "width", fw);
        sw = getInt(tmp, "width");
        h = scale(sw, den, num);
        _ = c.gst_structure_fixate_field_nearest_int(tmp, "height", h);
        sh = getInt(tmp, "height");
        c.gst_structure_free(tmp);
        if (sh == h) return setWH(outs, sw, sh);
        return setWH(outs, f_w, f_h);
    }
    var tmp = c.gst_structure_copy(outs);
    _ = c.gst_structure_fixate_field_nearest_int(tmp, "height", fh);
    const sh = getInt(tmp, "height");
    _ = c.gst_structure_fixate_field_nearest_int(tmp, "width", fw);
    const sw = getInt(tmp, "width");
    var tpn: c.gint = 0;
    var tpd: c.gint = 0;
    if (c.gst_util_fraction_multiply(dn, dd, sh, sw, &tpn, &tpd) == 0) {
        negotiationError(t, 485);
        c.gst_structure_free(tmp);
        return;
    }
    if (c.gst_structure_has_field(tmp, "pixel-aspect-ratio") == 0) c.gst_structure_set_value(tmp, "pixel-aspect-ratio", to_par);
    _ = c.gst_structure_fixate_field_nearest_fraction(tmp, "pixel-aspect-ratio", tpn, tpd);
    var spn: c.gint = 0;
    var spd: c.gint = 0;
    _ = c.gst_structure_get_fraction(tmp, "pixel-aspect-ratio", &spn, &spd);
    c.gst_structure_free(tmp);
    if (spn == tpn and spd == tpd) {
        setWH(outs, sw, sh);
        return setPar(outs, spn, spd);
    }
    if (c.gst_util_fraction_multiply(dn, dd, spd, spn, &num, &den) == 0) return negotiationError(t, 514);
    w = scale(sh, num, den);
    tmp = c.gst_structure_copy(outs);
    _ = c.gst_structure_fixate_field_nearest_int(tmp, "width", w);
    var tmp2 = getInt(tmp, "width");
    c.gst_structure_free(tmp);
    if (tmp2 == w) {
        setWH(outs, tmp2, sh);
        return setPar(outs, spn, spd);
    }
    h = scale(sw, den, num);
    tmp = c.gst_structure_copy(outs);
    _ = c.gst_structure_fixate_field_nearest_int(tmp, "height", h);
    tmp2 = getInt(tmp, "height");
    c.gst_structure_free(tmp);
    if (tmp2 == h) {
        setWH(outs, sw, tmp2);
        return setPar(outs, spn, spd);
    }
    setWH(outs, sw, sh);
    setPar(outs, spn, spd);
}

fn fixateCaps(t: OTrans, dir: c.GstPadDirection, caps: ?*c.GstCaps, other_in: ?*c.GstCaps) callconv(.c) ?*c.GstCaps {
    var other: ?*c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(other_in)));
    other = c.gst_caps_truncate(other);
    const ins = c.gst_caps_get_structure(caps, 0);
    const outs = c.gst_caps_get_structure(other, 0);
    var from_par = c.gst_structure_get_value(ins, "pixel-aspect-ratio");
    var to_par = c.gst_structure_get_value(outs, "pixel-aspect-ratio");
    var fpar = std.mem.zeroes(c.GValue);
    var tpar = std.mem.zeroes(c.GValue);
    if (dir == c.GST_PAD_SINK) {
        if (from_par == null) {
            _ = c.g_value_init(&fpar, c.gst_fraction_get_type());
            c.gst_value_set_fraction(&fpar, 1, 1);
            from_par = &fpar;
        }
        if (to_par == null) {
            _ = c.g_value_init(&tpar, c.gst_fraction_get_type());
            c.gst_value_set_fraction(&tpar, 1, 1);
            to_par = &tpar;
        }
    } else {
        if (to_par == null) {
            _ = c.g_value_init(&tpar, c.gst_fraction_get_type());
            c.gst_value_set_fraction(&tpar, 1, 1);
            to_par = &tpar;
            c.gst_structure_set(outs, "pixel-aspect-ratio", c.gst_fraction_get_type(), @as(c_int, 1), @as(c_int, 1), Z);
        }
        if (from_par == null) {
            _ = c.g_value_init(&fpar, c.gst_fraction_get_type());
            c.gst_value_set_fraction(&fpar, 1, 1);
            from_par = &fpar;
        }
    }
    fixateSize(t, ins, outs, from_par, to_par);
    other = c.gst_caps_fixate(other);
    if (from_par == &fpar) c.g_value_unset(&fpar);
    if (to_par == &tpar) c.g_value_unset(&tpar);
    return other;
}

fn removeSize(caps: ?*c.GstCaps) ?*c.GstCaps {
    const res = c.gst_caps_new_empty();
    const n = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        var st = c.gst_caps_get_structure(caps, i);
        const f = c.gst_caps_get_features(caps, i);
        if (i > 0 and c.gst_caps_is_subset_structure_full(res, st, f) != 0) continue;
        st = c.gst_structure_copy(st);
        c.gst_structure_set(st, "width", c.gst_int_range_get_type(), @as(c_int, 1), @as(c_int, std.math.maxInt(c_int)), "height", c.gst_int_range_get_type(), @as(c_int, 1), @as(c_int, std.math.maxInt(c_int)), Z);
        if (c.gst_structure_has_field(st, "pixel-aspect-ratio") != 0) c.gst_structure_set(st, "pixel-aspect-ratio", c.gst_fraction_range_get_type(), @as(c_int, 1), @as(c_int, std.math.maxInt(c_int)), @as(c_int, std.math.maxInt(c_int)), @as(c_int, 1), Z);
        c.gst_caps_append_structure_full(res, st, c.gst_caps_features_copy(f));
    }
    return res;
}

fn ensureFeatures(caps: ?*c.GstCaps, name: [*:0]const u8) ?*c.GstCaps {
    const r = c.gst_caps_copy(caps);
    const n = c.gst_caps_get_size(r);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const f = c.gst_caps_get_features(r, i);
        if (c.gst_caps_features_is_any(f) == 0 and c.gst_caps_features_contains(f, name) == 0) c.gst_caps_features_add(f, "memory:GLMemory");
    }
    return r;
}

fn defaultInternalCaps(_: OFilter, _: c.GstPadDirection, caps: ?*c.GstCaps, _: ?*c.GstCaps) callconv(.c) ?*c.GstCaps {
    return removeSize(caps);
}

fn transformCaps(t: OTrans, dir: c.GstPadDirection, caps: ?*c.GstCaps, fc: ?*c.GstCaps) callconv(.c) ?*c.GstCaps {
    const f = fl(t);
    var tmp: ?*c.GstCaps = undefined;
    if (c.gst_base_transform_is_passthrough(t) != 0) {
        tmp = @ptrCast(c.gst_mini_object_ref(@ptrCast(caps)));
    } else {
        const it = klass(f).transform_internal_caps.?(f, dir, caps, null);
        tmp = ensureFeatures(it, "memory:GLMemory");
        c.gst_mini_object_unref(@ptrCast(it));
    }
    if (fc != null) {
        const r = c.gst_caps_intersect_full(fc, tmp, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_mini_object_unref(@ptrCast(tmp));
        return r;
    }
    return tmp;
}

fn unitSize(_: OTrans, caps: ?*c.GstCaps, size: [*c]c.gsize) callconv(.c) c.gboolean {
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) != 0) size[0] = info.size;
    return 1;
}

fn glSetCaps(bf: [*c]c.GstGLBaseFilter, _: ?*c.GstCaps, _: ?*c.GstCaps) callconv(.c) c.gboolean {
    const f = fl(bf);
    if (f[0].fbo != null) c.gst_object_unref(f[0].fbo);
    f[0].fbo = framebuffer.gst_gl_framebuffer_new_with_default_depth(bf[0].context, @bitCast(f[0].out_info.width), @bitCast(f[0].out_info.height));
    if (f[0].fbo == null) {
        check.elementMessage(f, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Could not generate FBO"), null, FILE, "gst_gl_filter_gl_set_caps", 721);
        return 0;
    }
    if (klass(f).init_fbo) |ifbo| {
        if (ifbo(f) == 0) {
            check.elementMessage(f, c.GST_MESSAGE_ERROR, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_INIT, c.g_strdup("Subclass failed to initialize."), null, FILE, "gst_gl_filter_gl_set_caps", 727);
            return 0;
        }
    }
    return 1;
}

fn targetOf(s: ?*c.GstStructure) c.GstGLTextureTarget {
    if (c.gst_structure_has_field_typed(s, "texture-target", c.G_TYPE_STRING) != 0) return format.gst_gl_texture_target_from_string(c.gst_structure_get_string(s, "texture-target"));
    return c.GST_GL_TEXTURE_TARGET_2D;
}

fn setCaps(t: OTrans, in: ?*c.GstCaps, out: ?*c.GstCaps) callconv(.c) c.gboolean {
    const f = fl(t);
    if (c.gst_video_info_from_caps(&f[0].in_info, in) == 0) return 0;
    if (c.gst_video_info_from_caps(&f[0].out_info, out) == 0) return 0;
    const from = targetOf(c.gst_caps_get_structure(in, 0));
    const to = targetOf(c.gst_caps_get_structure(out, 0));
    if (to == c.GST_GL_TEXTURE_TARGET_NONE or from == c.GST_GL_TEXTURE_TARGET_NONE) return 0;
    if (klass(f).set_caps) |sc| {
        if (sc(f, in, out) == 0) return 0;
    }
    _ = c.gst_mini_object_replace(@ptrCast(&f[0].out_caps), @ptrCast(out));
    f[0].in_texture_target = from;
    f[0].out_texture_target = to;
    return tparent().set_caps.?(t, in, out);
}

fn proposeAllocation(t: OTrans, _: ?*c.GstQuery, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const ctx = basefilter.gst_gl_base_filter_get_gl_context(@ptrCast(t));
    if (ctx == null) return 0;
    defer c.gst_object_unref(ctx);
    var caps: ?*c.GstCaps = null;
    var need: c.gboolean = 0;
    c.gst_query_parse_allocation(q, &caps, &need);
    if (caps == null) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    const size: c.guint = @truncate(info.size);
    var pool: [*c]c.GstBufferPool = null;
    if (need != 0) {
        pool = bufferpool.gst_gl_buffer_pool_new(ctx);
        const cfg = c.gst_buffer_pool_get_config(pool);
        c.gst_buffer_pool_config_set_params(cfg, caps, size, 0, 0);
        if (c.gst_buffer_pool_set_config(pool, cfg) == 0) {
            c.gst_object_unref(pool);
            return 0;
        }
    }
    c.gst_query_add_allocation_pool(q, pool, size, 1, 0);
    if (pool != null) c.gst_object_unref(pool);
    if (vt(ctx).FenceSync != null) c.gst_query_add_allocation_meta(q, syncmeta.gst_gl_sync_meta_api_get_type(), null);
    return 1;
}

fn decideAllocation(t: OTrans, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    var caps: ?*c.GstCaps = null;
    c.gst_query_parse_allocation(q, &caps, null);
    if (caps == null) return 0;
    if (tparent().decide_allocation.?(t, q) == 0) return 0;
    const ctx = basefilter.gst_gl_base_filter_get_gl_context(@ptrCast(t));
    if (ctx == null) return 0;
    var pool: [*c]c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    var update = false;
    if (c.gst_query_get_n_allocation_pools(q) > 0) {
        c.gst_query_parse_nth_allocation_pool(q, 0, &pool, &size, &min, &max);
        update = true;
    } else {
        var vi: c.GstVideoInfo = undefined;
        c.gst_video_info_init(&vi);
        _ = c.gst_video_info_from_caps(&vi, caps);
        size = @truncate(vi.size);
    }
    if (pool == null or !gtype.instanceOf(pool, bufferpool.gst_gl_buffer_pool_get_type())) {
        if (pool != null) c.gst_object_unref(pool);
        pool = bufferpool.gst_gl_buffer_pool_new(ctx);
    }
    const cfg = c.gst_buffer_pool_get_config(pool);
    c.gst_buffer_pool_config_set_params(cfg, caps, size, min, max);
    c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionVideoMeta");
    if (c.gst_query_find_allocation_meta(q, syncmeta.gst_gl_sync_meta_api_get_type(), null) != 0) c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionGLSyncMeta");
    _ = c.gst_buffer_pool_set_config(pool, cfg);
    if (update) c.gst_query_set_nth_allocation_pool(q, 0, pool, size, min, max) else c.gst_query_add_allocation_pool(q, pool, size, min, max);
    c.gst_object_unref(pool);
    c.gst_object_unref(ctx);
    return 1;
}

pub export fn gst_gl_filter_filter_texture(f: OFilter, input: [*c]c.GstBuffer, output: [*c]c.GstBuffer) c.gboolean {
    var gf: c.GstVideoFrame = undefined;
    var of: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&gf, &f[0].in_info, input, c.GST_MAP_READ | c.GST_MAP_GL) == 0) return 0;
    defer c.gst_video_frame_unmap(&gf);
    const in_tex = gf.map[0].memory;
    if (memory.gst_is_gl_memory(in_tex) == 0) return 0;
    if (c.gst_video_frame_map(&of, &f[0].out_info, output, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) return 0;
    const out_tex = of.map[0].memory;
    if (!check.that(memory.gst_is_gl_memory(out_tex) != 0, "gst_gl_filter_filter_texture", "gst_is_gl_memory (out_tex)")) return 0;
    const ft = klass(f).filter_texture orelse check.assertFail(FILE, 868, "gst_gl_filter_filter_texture", "filter_class->filter_texture");
    const r = ft(f, @ptrCast(@alignCast(in_tex)), @ptrCast(@alignCast(out_tex)));
    c.gst_video_frame_unmap(&of);
    return r;
}

fn filterGl(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const f = fl(data);
    debug.gst_gl_insert_debug_marker(ctx, "processing in element %s", f[0].parent.parent.element.object.name);
    f[0].gl_result = if (klass(f).filter) |fc| fc(f, f[0].inbuf, f[0].outbuf) else gst_gl_filter_filter_texture(f, f[0].inbuf, f[0].outbuf);
}

fn transform(t: OTrans, in: [*c]c.GstBuffer, out: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const f = fl(t);
    const k = klass(f);
    if (f[0].parent.display == null) return c.GST_FLOW_NOT_NEGOTIATED;
    const ctx = ctxOf(f);
    if (k.filter == null and k.filter_texture == null) check.assertFail(FILE, 909, "gst_gl_filter_transform", "filter_class->filter || filter_class->filter_texture");
    const ism = c.gst_buffer_get_meta(in, syncmeta.gst_gl_sync_meta_api_get_type());
    if (ism != null) syncmeta.gst_gl_sync_meta_wait(@ptrCast(@alignCast(ism)), ctx);
    f[0].inbuf = in;
    f[0].outbuf = out;
    c.gst_gl_context_thread_add(ctx, filterGl, f);
    const ok = f[0].gl_result;
    const osm = c.gst_buffer_get_meta(out, syncmeta.gst_gl_sync_meta_api_get_type());
    if (osm != null) syncmeta.gst_gl_sync_meta_set_sync_point(@ptrCast(@alignCast(osm)), ctx);
    if (in != out) _ = c.gst_buffer_add_parent_buffer_meta(out, in);
    return if (ok != 0) c.GST_FLOW_OK else c.GST_FLOW_ERROR;
}

const Cb = struct {
    filter: OFilter,
    func: c.GstGLFilterRenderFunc,
    in_tex: [*c]c.GstGLMemory,
    data: c.gpointer,
};

fn glcb(data: c.gpointer) callconv(.c) c.gboolean {
    const cb: *Cb = @ptrCast(@alignCast(data));
    return cb.func.?(cb.filter, cb.in_tex, cb.data);
}

pub export fn gst_gl_filter_render_to_target(f: OFilter, input: [*c]c.GstGLMemory, output: [*c]c.GstGLMemory, func: c.GstGLFilterRenderFunc, data: c.gpointer) c.gboolean {
    var cb = Cb{ .filter = f, .func = func, .in_tex = input, .data = data };
    return framebuffer.gst_gl_framebuffer_draw_to_texture(f[0].fbo, output, glcb, &cb);
}

fn attributes(f: OFilter) void {
    if (f[0].default_shader == null) return;
    if (f[0].valid_attributes != 0) return;
    if (f[0].draw_attr_position_loc == -1) f[0].draw_attr_position_loc = shader.gst_gl_shader_get_attribute_location(f[0].default_shader, "a_position");
    if (f[0].draw_attr_texture_loc == -1) f[0].draw_attr_texture_loc = shader.gst_gl_shader_get_attribute_location(f[0].default_shader, "a_texcoord");
    f[0].valid_attributes = 1;
}

fn drawWithShader(f: OFilter, in_tex: [*c]c.GstGLMemory, _: c.gpointer) callconv(.c) c.gboolean {
    const ctx = ctxOf(f);
    const gl = vt(ctx);
    if (context.gst_gl_context_get_gl_api(ctx) & c.GST_GL_API_OPENGL != 0) {
        gl.MatrixMode.?(c.GL_PROJECTION);
        gl.LoadIdentity.?();
    }
    attributes(f);
    shader.gst_gl_shader_use(f[0].default_shader);
    gl.ActiveTexture.?(c.GL_TEXTURE1);
    gl.BindTexture.?(format.gst_gl_texture_target_to_gl(f[0].in_texture_target), memory.gst_gl_memory_get_texture_id(in_tex));
    shader.gst_gl_shader_set_uniform_1i(f[0].default_shader, "tex", 1);
    shader.gst_gl_shader_set_uniform_1f(f[0].default_shader, "width", @floatFromInt(f[0].out_info.width));
    shader.gst_gl_shader_set_uniform_1f(f[0].default_shader, "height", @floatFromInt(f[0].out_info.height));
    gst_gl_filter_draw_fullscreen_quad(f);
    return 1;
}

pub export fn gst_gl_filter_render_to_target_with_shader(f: OFilter, input: [*c]c.GstGLMemory, output: [*c]c.GstGLMemory, sh: [*c]c.GstGLShader) void {
    if (f[0].default_shader != sh) f[0].valid_attributes = 0;
    f[0].default_shader = sh;
    _ = gst_gl_filter_render_to_target(f, input, output, drawWithShader, null);
}

const VERTICES = [_]c.GLfloat{ -1, -1, 0, 0, 0, 1, -1, 0, 1, 0, 1, 1, 0, 1, 1, -1, 1, 0, 0, 1 };
const INDICES = [_]c.GLushort{ 0, 1, 2, 0, 2, 3 };

fn bindBuffer(f: OFilter) void {
    const gl = vt(ctxOf(f));
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, f[0].vbo_indices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, f[0].vertex_buffer);
    attributes(f);
    const pa: c.GLuint = @bitCast(f[0].draw_attr_position_loc);
    const ta: c.GLuint = @bitCast(f[0].draw_attr_texture_loc);
    gl.VertexAttribPointer.?(pa, 3, c.GL_FLOAT, c.GL_FALSE, 5 * @sizeOf(c.GLfloat), null);
    gl.VertexAttribPointer.?(ta, 2, c.GL_FLOAT, c.GL_FALSE, 5 * @sizeOf(c.GLfloat), @ptrFromInt(3 * @sizeOf(c.GLfloat)));
    gl.EnableVertexAttribArray.?(pa);
    gl.EnableVertexAttribArray.?(ta);
}

fn unbindBuffer(f: OFilter) void {
    const gl = vt(ctxOf(f));
    gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DisableVertexAttribArray.?(@bitCast(f[0].draw_attr_position_loc));
    gl.DisableVertexAttribArray.?(@bitCast(f[0].draw_attr_texture_loc));
}

pub export fn gst_gl_filter_draw_fullscreen_quad(f: OFilter) void {
    const gl = vt(ctxOf(f));
    if (f[0].vertex_buffer == 0) {
        if (gl.GenVertexArrays) |g| {
            g(1, &f[0].vao);
            gl.BindVertexArray.?(f[0].vao);
        }
        gl.GenBuffers.?(1, &f[0].vertex_buffer);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, f[0].vertex_buffer);
        gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(VERTICES)), &VERTICES, c.GL_STATIC_DRAW);
        gl.GenBuffers.?(1, &f[0].vbo_indices);
        gl.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, f[0].vbo_indices);
        gl.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(INDICES)), &INDICES, c.GL_STATIC_DRAW);
    }
    if (gl.GenVertexArrays != null) gl.BindVertexArray.?(f[0].vao);
    bindBuffer(f);
    gl.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    if (gl.GenVertexArrays != null) gl.BindVertexArray.?(0) else unbindBuffer(f);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.transform_caps = transformCaps;
    tc.fixate_caps = fixateCaps;
    tc.transform = transform;
    tc.stop = stop;
    tc.set_caps = setCaps;
    tc.propose_allocation = proposeAllocation;
    tc.decide_allocation = decideAllocation;
    tc.get_unit_size = unitSize;
    const bc: *c.GstGLBaseFilterClass = @ptrCast(@alignCast(k));
    bc.gl_stop = glStop;
    bc.gl_set_caps = glSetCaps;
    @as(*Class, @ptrCast(@alignCast(k))).transform_internal_caps = defaultInternalCaps;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const f = fl(inst);
    f[0].draw_attr_position_loc = -1;
    f[0].draw_attr_texture_loc = -1;
}

pub export fn gst_gl_filter_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(basefilter.gst_gl_base_filter_get_type, "GstGLFilter", Class, Filter, classInit, init, 0);
            _ = c._gst_debug_category_new("glfilter", 0, "glfilter element");
            return t;
        }
    }.f);
}
