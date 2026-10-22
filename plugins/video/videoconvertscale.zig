const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/videoconvertscale/gstvideoconvertscale.c";
const SIZE = "(int) [ 1, 32767]";
const TAIL = ", width = " ++ SIZE ++ ", height = " ++ SIZE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE;
const CAPS = "video/x-raw, format = (string) " ++ c.GST_VIDEO_FORMATS_ALL ++ TAIL ++ ";video/x-raw(ANY), format = (string) " ++ c.GST_VIDEO_FORMATS_ANY ++ TAIL;
const MAXI = std.math.maxInt(c.gint);

const PROP_METHOD = 1;
const PROP_ADD_BORDERS = 2;
const PROP_SHARPNESS = 3;
const PROP_SHARPEN = 4;
const PROP_DITHER = 5;
const PROP_SUBMETHOD = 6;
const PROP_ENVELOPE = 7;
const PROP_N_THREADS = 8;
const PROP_DITHER_QUANTIZATION = 9;
const PROP_CHROMA_RESAMPLER = 10;
const PROP_ALPHA_MODE = 11;
const PROP_ALPHA_VALUE = 12;
const PROP_CHROMA_MODE = 13;
const PROP_MATRIX_MODE = 14;
const PROP_GAMMA_MODE = 15;
const PROP_PRIMARIES_MODE = 16;
const PROP_CONVERTER_CONFIG = 17;

const NEAREST = 0;
const BILINEAR = 1;
const FOUR_TAP = 2;
const LANCZOS = 3;
const BILINEAR2 = 4;
const SINC = 5;
const HERMITE = 6;
const SPLINE = 7;
const CATROM = 8;
const MITCHELL = 9;

const Priv = struct {
    method: c.gint = BILINEAR,
    add_borders: bool = true,
    sharpness: f64 = 1.0,
    sharpen: f64 = 0.0,
    submethod: c.gint = 0,
    envelope: f64 = 2.0,
    n_threads: c.guint = 1,
    n_threads_set: bool = false,
    dither: c.gint = c.GST_VIDEO_DITHER_BAYER,
    dither_quantization: c.guint = 1,
    chroma_resampler: c.gint = c.GST_VIDEO_RESAMPLER_METHOD_LINEAR,
    alpha_mode: c.gint = c.GST_VIDEO_ALPHA_MODE_COPY,
    chroma_mode: c.gint = c.GST_VIDEO_CHROMA_MODE_FULL,
    matrix_mode: c.gint = c.GST_VIDEO_MATRIX_MODE_FULL,
    gamma_mode: c.gint = c.GST_VIDEO_GAMMA_MODE_NONE,
    primaries_mode: c.gint = c.GST_VIDEO_PRIMARIES_MODE_NONE,
    alpha_value: f64 = 1.0,
    convert: ?*c.GstVideoConverter = null,
    config: ?*c.GstStructure = null,
    config_changed: bool = false,
    borders_h: c.gint = 0,
    borders_w: c.gint = 0,
    pool: ?*c.GstTaskPool = null,
    pool_persistent: bool = false,
};

const Self = extern struct {
    parent: c.GstVideoFilter,
    p: *Priv,
};

const Class = extern struct {
    parent: c.GstVideoFilterClass,
    scales: c.gboolean,
    converts: c.gboolean,
};

var once: cm.Once = .{};
var convert_once: cm.Once = .{};
var scale_once: cm.Once = .{};
var method_once: cm.Once = .{};
var parent: ?*c.GstVideoFilterClass = null;
var scale_parent: ?*c.GObjectClass = null;
var size_quark: c.GQuark = 0;
var scale_quark: c.GQuark = 0;
var matrix_quark: c.GQuark = 0;
var caps_once: usize = 0;
var caps_list: [*c]c.GstCaps = null;
var static_caps = c.GstStaticCaps{ .caps = null, .string = CAPS, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };

var methods = [_]c.GEnumValue{
    .{ .value = NEAREST, .value_name = "Nearest Neighbour", .value_nick = "nearest-neighbour" },
    .{ .value = BILINEAR, .value_name = "Bilinear (2-tap)", .value_nick = "bilinear" },
    .{ .value = FOUR_TAP, .value_name = "4-tap Sinc", .value_nick = "4-tap" },
    .{ .value = LANCZOS, .value_name = "Lanczos", .value_nick = "lanczos" },
    .{ .value = BILINEAR2, .value_name = "Bilinear (multi-tap)", .value_nick = "bilinear2" },
    .{ .value = SINC, .value_name = "Sinc (multi-tap)", .value_nick = "sinc" },
    .{ .value = HERMITE, .value_name = "Hermite (multi-tap)", .value_nick = "hermite" },
    .{ .value = SPLINE, .value_name = "Spline (multi-tap)", .value_nick = "spline" },
    .{ .value = CATROM, .value_name = "Catmull-Rom (multi-tap)", .value_nick = "catrom" },
    .{ .value = MITCHELL, .value_name = "Mitchell (multi-tap)", .value_nick = "mitchell" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn methodType() c.GType {
    return method_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstVideoScaleMethod", &methods);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn klass(p: anytype) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class));
}

fn filt(p: anytype) *c.GstVideoFilter {
    return @ptrCast(@alignCast(p));
}

fn trans(p: anytype) [*c]c.GstBaseTransform {
    return @ptrCast(@alignCast(p));
}

fn capsList() [*c]c.GstCaps {
    if (c.g_once_init_enter(&caps_once) != 0) {
        caps_list = c.gst_static_caps_get(&static_caps);
        c.g_once_init_leave(&caps_once, 1);
    }
    return caps_list;
}

fn filterMeta(_: [*c]c.GstBaseTransform, _: [*c]c.GstQuery, api: c.GType, _: ?*const c.GstStructure) callconv(.c) c.gboolean {
    return @intFromBool(api != c.gst_video_crop_meta_api_get_type());
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = me(o).p;
    cm.lock(o);
    switch (id) {
        PROP_METHOD => p.method = c.g_value_get_enum(v),
        PROP_ADD_BORDERS => {
            p.add_borders = c.g_value_get_boolean(v) != 0;
            cm.unlock(o);
            c.gst_base_transform_reconfigure_src(trans(o));
            return;
        },
        PROP_SHARPNESS => p.sharpness = c.g_value_get_double(v),
        PROP_SHARPEN => p.sharpen = c.g_value_get_double(v),
        PROP_SUBMETHOD => p.submethod = c.g_value_get_int(v),
        PROP_ENVELOPE => p.envelope = c.g_value_get_double(v),
        PROP_N_THREADS => {
            p.n_threads = c.g_value_get_uint(v);
            p.n_threads_set = true;
        },
        PROP_DITHER => p.dither = c.g_value_get_enum(v),
        PROP_CHROMA_RESAMPLER => p.chroma_resampler = c.g_value_get_enum(v),
        PROP_ALPHA_MODE => p.alpha_mode = c.g_value_get_enum(v),
        PROP_ALPHA_VALUE => p.alpha_value = c.g_value_get_double(v),
        PROP_CHROMA_MODE => p.chroma_mode = c.g_value_get_enum(v),
        PROP_MATRIX_MODE => p.matrix_mode = c.g_value_get_enum(v),
        PROP_GAMMA_MODE => p.gamma_mode = c.g_value_get_enum(v),
        PROP_PRIMARIES_MODE => p.primaries_mode = c.g_value_get_enum(v),
        PROP_DITHER_QUANTIZATION => p.dither_quantization = c.g_value_get_uint(v),
        PROP_CONVERTER_CONFIG => {
            if (p.config) |s| c.gst_structure_free(s);
            p.config = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
            p.config_changed = true;
        },
        else => cm.warnInvalid(FILE, o, id, spec, 554),
    }
    cm.unlock(o);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = me(o).p;
    cm.lock(o);
    defer cm.unlock(o);
    switch (id) {
        PROP_METHOD => c.g_value_set_enum(v, p.method),
        PROP_ADD_BORDERS => c.g_value_set_boolean(v, @intFromBool(p.add_borders)),
        PROP_SHARPNESS => c.g_value_set_double(v, p.sharpness),
        PROP_SHARPEN => c.g_value_set_double(v, p.sharpen),
        PROP_SUBMETHOD => c.g_value_set_int(v, p.submethod),
        PROP_ENVELOPE => c.g_value_set_double(v, p.envelope),
        PROP_N_THREADS => c.g_value_set_uint(v, p.n_threads),
        PROP_DITHER => c.g_value_set_enum(v, p.dither),
        PROP_CHROMA_RESAMPLER => c.g_value_set_enum(v, p.chroma_resampler),
        PROP_ALPHA_MODE => c.g_value_set_enum(v, p.alpha_mode),
        PROP_ALPHA_VALUE => c.g_value_set_double(v, p.alpha_value),
        PROP_CHROMA_MODE => c.g_value_set_enum(v, p.chroma_mode),
        PROP_MATRIX_MODE => c.g_value_set_enum(v, p.matrix_mode),
        PROP_GAMMA_MODE => c.g_value_set_enum(v, p.gamma_mode),
        PROP_PRIMARIES_MODE => c.g_value_set_enum(v, p.primaries_mode),
        PROP_DITHER_QUANTIZATION => c.g_value_set_uint(v, p.dither_quantization),
        PROP_CONVERTER_CONFIG => c.g_value_set_boxed(v, p.config),
        else => cm.warnInvalid(FILE, o, id, spec, 620),
    }
}

fn setContext(el: [*c]c.GstElement, ctx: ?*c.GstContext) callconv(.c) void {
    const p = me(el).p;
    if (c.gst_context_has_context_type(ctx, c.GST_TASK_POOL_CONTEXT_TYPE) != 0) {
        var pool: ?*c.GstTaskPool = null;
        _ = c.gst_context_get_task_pool(ctx, &pool);
        cm.lock(el);
        if (p.pool) |old| c.gst_object_unref(old);
        p.pool = pool;
        p.pool_persistent = c.gst_context_is_persistent(ctx) != 0;
        cm.unlock(el);
    }
    @as(*c.GstElementClass, @ptrCast(@alignCast(parent.?))).set_context.?(el, ctx);
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const p = me(el).p;
    const r = @as(*c.GstElementClass, @ptrCast(@alignCast(parent.?))).change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) {
        cm.lock(el);
        if (!p.pool_persistent) {
            if (p.pool) |pool| c.gst_object_unref(pool);
            p.pool = null;
        }
        cm.unlock(el);
    }
    return r;
}

fn supportedFeatures(f: ?*const c.GstCapsFeatures) bool {
    if (c.gst_caps_features_is_any(f) != 0) return false;
    var i: c.guint = 0;
    while (i < c.gst_caps_features_get_size(f)) : (i += 1) {
        const id = c.gst_caps_features_get_nth_id_str(f, i);
        if (c.gst_id_str_is_equal_to_str(id, c.GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY) != 0) continue;
        if (c.gst_id_str_is_equal_to_str(id, c.GST_CAPS_FEATURE_FORMAT_INTERLACED) != 0) continue;
        if (c.gst_id_str_is_equal_to_str(id, c.GST_CAPS_FEATURE_META_GST_VIDEO_OVERLAY_COMPOSITION) != 0) continue;
        return false;
    }
    return true;
}

fn transformCaps(bt: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const k = klass(bt);
    var ret = c.gst_caps_new_empty();
    const n = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        var s = c.gst_caps_get_structure(caps, i);
        const f = c.gst_caps_get_features(caps, i);
        if (i > 0 and c.gst_caps_is_subset_structure_full(ret, s, f) != 0) continue;
        s = c.gst_structure_copy(s);
        if (supportedFeatures(f)) {
            if (k.scales != 0) {
                c.gst_structure_set_static_str(s, "width", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, MAXI), "height", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, MAXI), @as(?*anyopaque, null));
                if (c.gst_structure_has_field(s, "pixel-aspect-ratio") != 0) c.gst_structure_set_static_str(s, "pixel-aspect-ratio", c.gst_fraction_range_get_type(), @as(c.gint, 1), @as(c.gint, MAXI), @as(c.gint, MAXI), @as(c.gint, 1), @as(?*anyopaque, null));
            }
            if (k.converts != 0) c.gst_structure_remove_fields(s, "format", "colorimetry", "chroma-site", @as(?*anyopaque, null));
        }
        c.gst_caps_append_structure_full(ret, s, c.gst_caps_features_copy(f));
    }
    if (filter != null) {
        const x = c.gst_caps_intersect_full(filter, ret, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_mini_object_unref(@ptrCast(ret));
        ret = x;
    }
    return ret;
}

fn transformMeta(bt: [*c]c.GstBaseTransform, outbuf: [*c]c.GstBuffer, meta: [*c]c.GstMeta, inbuf: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const vf = filt(bt);
    const p = me(bt).p;
    const info = meta[0].info;
    var tags = [_][*c]const u8{ c.GST_META_TAG_VIDEO_STR, c.GST_META_TAG_VIDEO_ORIENTATION_STR, c.GST_META_TAG_VIDEO_SIZE_STR, null };
    if (c.gst_meta_api_type_tags_contain_only(info[0].api, @ptrCast(&tags)) == 0) return @as(*c.GstBaseTransformClass, @ptrCast(@alignCast(parent.?))).transform_meta.?(bt, outbuf, meta, inbuf);
    if (c.gst_meta_api_type_has_tag(info[0].api, size_quark) == 0) return 1;
    const tf = info[0].transform_func orelse return 0;
    var mt: c.GstVideoMetaTransformMatrix = undefined;
    var st = c.GstVideoMetaTransform{ .in_info = &vf.in_info, .out_info = &vf.out_info };
    const in_rect = c.GstVideoRectangle{ .x = 0, .y = 0, .w = vf.in_info.width, .h = vf.in_info.height };
    const out_rect = c.GstVideoRectangle{ .x = @divTrunc(p.borders_w, 2), .y = @divTrunc(p.borders_h, 2), .w = vf.out_info.width - p.borders_w, .h = vf.out_info.height - p.borders_h };
    c.gst_video_meta_transform_matrix_init(&mt, &vf.in_info, &in_rect, &vf.out_info, &out_rect);
    if (tf(outbuf, meta, inbuf, matrix_quark, &mt) == 0) _ = tf(outbuf, meta, inbuf, scale_quark, &st);
    return 0;
}

fn requestPool(s: *Self) void {
    cm.lock(s);
    const have = s.p.pool != null;
    cm.unlock(s);
    if (have) return;
    _ = c.gst_element_post_message(@ptrCast(@alignCast(s)), c.gst_message_new_need_context(cm.obj(s), c.GST_TASK_POOL_CONTEXT_TYPE));
}

fn createConverter(s: *Self, in: [*c]c.GstVideoInfo, out: [*c]c.GstVideoInfo, config: ?*c.GstStructure) ?*c.GstVideoConverter {
    requestPool(s);
    cm.lock(s);
    var pool: ?*c.GstTaskPool = null;
    if (s.p.pool) |pl| {
        pool = @ptrCast(@alignCast(c.gst_object_ref(pl)));
        if (cm.isA(pool, c.gst_shared_task_pool_get_type()) and (!s.p.n_threads_set or s.p.n_threads == 0)) {
            c.gst_structure_set(config, c.GST_VIDEO_CONVERTER_OPT_THREADS, c.G_TYPE_UINT, c.gst_shared_task_pool_get_max_threads(@ptrCast(@alignCast(pool))), @as(?*anyopaque, null));
        }
    }
    cm.unlock(s);
    defer if (pool) |pl| c.gst_object_unref(pl);
    if (pool != null) return c.gst_video_converter_new_with_pool(in, out, config, pool);
    return c.gst_video_converter_new(in, out, config);
}

fn methodOptions(o: ?*c.GstStructure, m: c.gint) void {
    const RM = c.GST_VIDEO_CONVERTER_OPT_RESAMPLER_METHOD;
    const T = c.gst_video_resampler_method_get_type();
    const N: ?*anyopaque = null;
    switch (m) {
        NEAREST => c.gst_structure_set_static_str(o, RM, T, c.GST_VIDEO_RESAMPLER_METHOD_NEAREST, N),
        BILINEAR => c.gst_structure_set_static_str(o, RM, T, c.GST_VIDEO_RESAMPLER_METHOD_LINEAR, c.GST_VIDEO_RESAMPLER_OPT_MAX_TAPS, c.G_TYPE_INT, @as(c.gint, 2), N),
        FOUR_TAP => c.gst_structure_set_static_str(o, RM, T, c.GST_VIDEO_RESAMPLER_METHOD_SINC, c.GST_VIDEO_RESAMPLER_OPT_MAX_TAPS, c.G_TYPE_INT, @as(c.gint, 4), N),
        LANCZOS => c.gst_structure_set_static_str(o, RM, T, c.GST_VIDEO_RESAMPLER_METHOD_LANCZOS, N),
        BILINEAR2 => c.gst_structure_set_static_str(o, RM, T, c.GST_VIDEO_RESAMPLER_METHOD_LINEAR, N),
        SINC => c.gst_structure_set_static_str(o, RM, T, c.GST_VIDEO_RESAMPLER_METHOD_SINC, N),
        HERMITE, SPLINE, CATROM, MITCHELL => {
            const bc: [2]f64 = switch (m) {
                HERMITE => .{ 0.0, 0.0 },
                SPLINE => .{ 1.0, 0.0 },
                CATROM => .{ 0.0, 0.5 },
                else => .{ 1.0 / 3.0, 1.0 / 3.0 },
            };
            c.gst_structure_set_static_str(o, RM, T, c.GST_VIDEO_RESAMPLER_METHOD_CUBIC, c.GST_VIDEO_RESAMPLER_OPT_CUBIC_B, c.G_TYPE_DOUBLE, bc[0], c.GST_VIDEO_RESAMPLER_OPT_CUBIC_C, c.G_TYPE_DOUBLE, bc[1], N);
        },
        else => {},
    }
}

fn dar(i: *c.GstVideoInfo) [2]c.gint {
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (c.gst_util_fraction_multiply(i.width, i.height, i.par_n, i.par_d, &n, &d) == 0) return .{ -1, -1 };
    return .{ n, d };
}

fn borders(s: *Self, in: *c.GstVideoInfo, out: *c.GstVideoInfo) void {
    const p = s.p;
    const from = dar(in);
    const to = dar(out);
    p.borders_w = 0;
    p.borders_h = 0;
    if ((to[0] == from[0] and to[1] == from[1]) or !p.add_borders) return;
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (from[0] == -1 or from[1] == -1 or c.gst_util_fraction_multiply(from[0], from[1], out.par_d, out.par_n, &n, &d) == 0) return;
    const to_h: c.gint = @intCast(c.gst_util_uint64_scale_int(@intCast(out.width), d, n));
    if (to_h <= out.height) {
        p.borders_h = out.height - to_h;
        return;
    }
    const to_w: c.gint = @intCast(c.gst_util_uint64_scale_int(@intCast(out.height), n, d));
    if (!(to_w <= out.width)) c.g_assertion_message_expr(null, FILE, 946, "gst_video_convert_scale_set_info", "to_w <= out_info->width");
    p.borders_w = out.width - to_w;
}

fn hasAlpha(i: *const c.GstVideoInfo) bool {
    return i.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_ALPHA != 0;
}

fn setInfo(vf: [*c]c.GstVideoFilter, _: [*c]c.GstCaps, in: [*c]c.GstVideoInfo, _: [*c]c.GstCaps, out: [*c]c.GstVideoInfo) callconv(.c) c.gboolean {
    const s = me(vf);
    const p = s.p;
    if (p.convert) |cv| c.gst_video_converter_free(cv);
    p.convert = null;
    borders(s, in, out);
    if (in[0].interlace_mode != out[0].interlace_mode) return 0;
    var options: ?*c.GstStructure = null;
    if (p.config) |cfg| {
        options = c.gst_structure_copy(cfg);
    } else {
        var tmp = in[0];
        tmp.colorimetry.transfer = out[0].colorimetry.transfer;
        const need_dither = p.dither_quantization > 1 and p.dither != c.GST_VIDEO_DITHER_NONE;
        const need_alpha = hasAlpha(out) and (p.alpha_mode == c.GST_VIDEO_ALPHA_MODE_SET or (p.alpha_mode == c.GST_VIDEO_ALPHA_MODE_MULT and p.alpha_value != 1.0));
        if (c.gst_video_info_is_equal(&tmp, out) != 0 and c.gst_video_transfer_function_is_equivalent(in[0].colorimetry.transfer, in[0].finfo[0].bits, out[0].colorimetry.transfer, out[0].finfo[0].bits) != 0 and !need_dither and !need_alpha) {
            c.gst_base_transform_set_passthrough(trans(vf), 1);
            return 1;
        }
        c.gst_base_transform_set_passthrough(trans(vf), 0);
        options = c.gst_structure_new_static_str_empty("videoconvertscale");
        methodOptions(options, p.method);
        c.gst_structure_set_static_str(options, c.GST_VIDEO_RESAMPLER_OPT_ENVELOPE, c.G_TYPE_DOUBLE, p.envelope, c.GST_VIDEO_RESAMPLER_OPT_SHARPNESS, c.G_TYPE_DOUBLE, p.sharpness, c.GST_VIDEO_RESAMPLER_OPT_SHARPEN, c.G_TYPE_DOUBLE, p.sharpen, c.GST_VIDEO_CONVERTER_OPT_DEST_X, c.G_TYPE_INT, @divTrunc(p.borders_w, 2), c.GST_VIDEO_CONVERTER_OPT_DEST_Y, c.G_TYPE_INT, @divTrunc(p.borders_h, 2), c.GST_VIDEO_CONVERTER_OPT_DEST_WIDTH, c.G_TYPE_INT, out[0].width - p.borders_w, c.GST_VIDEO_CONVERTER_OPT_DEST_HEIGHT, c.G_TYPE_INT, out[0].height - p.borders_h, c.GST_VIDEO_CONVERTER_OPT_DITHER_METHOD, c.gst_video_dither_method_get_type(), p.dither, c.GST_VIDEO_CONVERTER_OPT_DITHER_QUANTIZATION, c.G_TYPE_UINT, p.dither_quantization, c.GST_VIDEO_CONVERTER_OPT_CHROMA_RESAMPLER_METHOD, c.gst_video_resampler_method_get_type(), p.chroma_resampler, c.GST_VIDEO_CONVERTER_OPT_ALPHA_MODE, c.gst_video_alpha_mode_get_type(), p.alpha_mode, c.GST_VIDEO_CONVERTER_OPT_ALPHA_VALUE, c.G_TYPE_DOUBLE, p.alpha_value, c.GST_VIDEO_CONVERTER_OPT_CHROMA_MODE, c.gst_video_chroma_mode_get_type(), p.chroma_mode, c.GST_VIDEO_CONVERTER_OPT_MATRIX_MODE, c.gst_video_matrix_mode_get_type(), p.matrix_mode, c.GST_VIDEO_CONVERTER_OPT_GAMMA_MODE, c.gst_video_gamma_mode_get_type(), p.gamma_mode, c.GST_VIDEO_CONVERTER_OPT_PRIMARIES_MODE, c.gst_video_primaries_mode_get_type(), p.primaries_mode, c.GST_VIDEO_CONVERTER_OPT_THREADS, c.G_TYPE_UINT, p.n_threads, @as(?*anyopaque, null));
    }
    p.convert = createConverter(s, in, out, options);
    return @intFromBool(p.convert != null);
}

const COLORSPACE = c.GST_VIDEO_FORMAT_FLAG_YUV | c.GST_VIDEO_FORMAT_FLAG_RGB | c.GST_VIDEO_FORMAT_FLAG_GRAY;

fn cleanFlags(f: c.GstVideoFormatFlags) c.GstVideoFormatFlags {
    return f & ~@as(c.GstVideoFormatFlags, c.GST_VIDEO_FORMAT_FLAG_LE | c.GST_VIDEO_FORMAT_FLAG_COMPLEX | c.GST_VIDEO_FORMAT_FLAG_UNPACK);
}

fn score(in: [*c]const c.GstVideoFormatInfo, v: [*c]const c.GValue, min: *c.gint, best: *[*c]const c.GstVideoFormatInfo) void {
    const t = c.gst_video_format_get_info(c.gst_video_format_from_string(c.g_value_get_string(v)));
    if (t == null or t[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) return;
    if (in == t) {
        min.* = 0;
        best.* = t;
        return;
    }
    var loss: c.gint = 1;
    const fi = cleanFlags(in[0].flags);
    const ft = cleanFlags(t[0].flags);
    const P = c.GST_VIDEO_FORMAT_FLAG_PALETTE;
    const A = c.GST_VIDEO_FORMAT_FLAG_ALPHA;
    if (ft & P != fi & P) {
        loss += 1;
        if (ft & P != 0) loss += 64;
    }
    if (ft & COLORSPACE != fi & COLORSPACE) {
        loss += 2;
        if (ft & c.GST_VIDEO_FORMAT_FLAG_GRAY != 0) loss += 128;
    }
    if (ft & A != fi & A) {
        loss += 1;
        if (fi & A != 0) loss += 8;
    }
    if (in[0].h_sub[1] != t[0].h_sub[1]) {
        loss += 1;
        if (in[0].h_sub[1] < t[0].h_sub[1]) loss += 32;
    }
    if (in[0].w_sub[1] != t[0].w_sub[1]) {
        loss += 1;
        if (in[0].w_sub[1] < t[0].w_sub[1]) loss += 16;
    }
    if (in[0].bits != t[0].bits) {
        loss += 1;
        if (in[0].bits > t[0].bits) loss += 4;
    }
    if (loss < min.*) {
        best.* = t;
        min.* = loss;
    }
}

fn fixateFormat(caps: [*c]c.GstCaps, result: [*c]c.GstCaps) void {
    const fmt = c.gst_structure_get_string(c.gst_caps_get_structure(caps, 0), "format");
    if (fmt == null) return;
    const in = c.gst_video_format_get_info(c.gst_video_format_from_string(fmt));
    if (in == null) return;
    const outs = c.gst_caps_get_structure(result, 0);
    var best: [*c]const c.GstVideoFormatInfo = null;
    var min: c.gint = MAXI;
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(result)) : (i += 1) {
        const t = c.gst_caps_get_structure(result, i);
        const f = c.gst_structure_get_value(t, "format");
        c.gst_structure_remove_fields(t, "height", "width", "pixel-aspect-ratio", "display-aspect-ratio", @as(?*anyopaque, null));
        if (f == null) continue;
        if (f[0].g_type == c.gst_value_list_get_type()) {
            var j: c.guint = 0;
            while (j < c.gst_value_list_get_size(f)) : (j += 1) {
                const v = c.gst_value_list_get_value(f, j);
                if (v[0].g_type != c.G_TYPE_STRING) continue;
                score(in, v, &min, &best);
                if (min == 0) break;
            }
        } else if (f[0].g_type == c.G_TYPE_STRING) score(in, f, &min, &best);
    }
    if (best != null) c.gst_structure_set_static_str(outs, "format", c.G_TYPE_STRING, best[0].name, @as(?*anyopaque, null));
}

fn subsamplingSame(a: *const c.GstVideoInfo, b: *const c.GstVideoInfo) bool {
    const n = a.finfo[0].n_components;
    if (n != b.finfo[0].n_components) return false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a.finfo[0].w_sub[i] != b.finfo[0].w_sub[i] or a.finfo[0].h_sub[i] != b.finfo[0].h_sub[i]) return false;
    }
    return true;
}

fn isKind(i: *const c.GstVideoInfo, f: c.GstVideoFormatFlags) bool {
    return i.finfo[0].flags & f != 0;
}

fn transferColorimetry(in_caps: [*c]c.GstCaps, out_caps: [*c]c.GstCaps) void {
    const outs = c.gst_caps_get_structure(out_caps, 0);
    const ins = c.gst_caps_get_structure(in_caps, 0);
    const have_col = c.gst_structure_has_field(outs, "colorimetry") != 0;
    const have_site = c.gst_structure_has_field(outs, "chroma-site") != 0;
    if (have_col and have_site) return;
    var in: c.GstVideoInfo = undefined;
    var out: c.GstVideoInfo = undefined;
    const in_col = c.gst_structure_get_value(ins, "colorimetry");
    if (c.gst_video_info_from_caps(&in, in_caps) == 0) return;
    const tmp = c.gst_caps_fixate(c.gst_caps_copy(out_caps));
    const ts = c.gst_caps_get_structure(tmp, 0);
    if (c.gst_structure_has_field(ts, "width") == 0) c.gst_structure_set_value_static_str(ts, "width", c.gst_structure_get_value(ins, "width"));
    if (c.gst_structure_has_field(ts, "height") == 0) c.gst_structure_set_value_static_str(ts, "height", c.gst_structure_get_value(ins, "height"));
    const ok = c.gst_video_info_from_caps(&out, tmp) != 0;
    c.gst_mini_object_unref(@ptrCast(tmp));
    if (!ok) return;
    const YUV = c.GST_VIDEO_FORMAT_FLAG_YUV;
    if (!have_col and in_col != null) {
        if ((isKind(&out, YUV) and isKind(&in, YUV)) or (isKind(&out, c.GST_VIDEO_FORMAT_FLAG_RGB) and isKind(&in, c.GST_VIDEO_FORMAT_FLAG_RGB)) or (isKind(&out, c.GST_VIDEO_FORMAT_FLAG_GRAY) and isKind(&in, c.GST_VIDEO_FORMAT_FLAG_GRAY))) {
            c.gst_structure_set_value_static_str(outs, "colorimetry", in_col);
        } else {
            out.colorimetry.primaries = in.colorimetry.primaries;
            out.colorimetry.transfer = in.colorimetry.transfer;
            const str = c.gst_video_colorimetry_to_string(&out.colorimetry);
            c.gst_caps_set_simple_static_str(out_caps, "colorimetry", c.G_TYPE_STRING, str, @as(?*anyopaque, null));
            c.g_free(str);
        }
    }
    if (!have_site and isKind(&out, YUV) and isKind(&in, YUV)) {
        const site = c.gst_structure_get_value(ins, "chroma-site");
        if (site != null and subsamplingSame(&in, &out)) c.gst_structure_set_value_static_str(outs, "chroma-site", site);
    }
}

fn fixedFormat(dir: c.GstPadDirection, caps: [*c]c.GstCaps, other: [*c]c.GstCaps) [*c]c.GstCaps {
    var res = c.gst_caps_intersect(other, caps);
    if (c.gst_caps_is_empty(res) != 0) {
        c.gst_mini_object_unref(@ptrCast(res));
        res = c.gst_caps_copy(other);
    }
    res = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(res))));
    fixateFormat(caps, res);
    res = c.gst_caps_fixate(res);
    if (dir == c.GST_PAD_SINK) {
        if (c.gst_caps_is_subset(caps, res) != 0) {
            _ = c.gst_mini_object_replace(@ptrCast(&res), @ptrCast(caps));
        } else transferColorimetry(caps, res);
    }
    return res;
}

fn frac(v: [*c]const c.GValue) [2]i64 {
    return .{ c.gst_value_get_fraction_numerator(v), c.gst_value_get_fraction_denominator(v) };
}

fn mul(a: i64, b: i64, x: i64, y: i64) [2]i64 {
    var n: i64 = 0;
    var d: i64 = 0;
    if (c.gst_util_fraction_multiply_int64(a, b, x, y, &n, &d) != 0) return .{ n, d };
    var d1: f64 = 0;
    var d2: f64 = 0;
    c.gst_util_fraction_to_double(@intCast(a), @intCast(b), &d1);
    c.gst_util_fraction_to_double(@intCast(x), @intCast(y), &d2);
    var rn: c.gint = 0;
    var rd: c.gint = 0;
    c.gst_util_double_to_fraction(d1 * d2, &rn, &rd);
    return .{ rn, rd };
}

fn overflow(bt: [*c]c.GstBaseTransform, line: c.gint) void {
    cm.elementError(bt, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Error calculating the output scaled size - integer overflow"), FILE, "gst_video_convert_scale_fixate_size", line);
}

fn nearestInt(s: ?*c.GstStructure, field: [*c]const u8, target: i64) c.gint {
    _ = c.gst_structure_fixate_field_nearest_int(s, field, @truncate(target));
    var v: c.gint = 0;
    _ = c.gst_structure_get_int(s, field, &v);
    return v;
}

fn setFrac(s: ?*c.GstStructure, n: c.gint, d: c.gint) void {
    c.gst_structure_set_static_str(s, "pixel-aspect-ratio", c.gst_fraction_get_type(), n, d, @as(?*anyopaque, null));
}

fn setInt(s: ?*c.GstStructure, field: [*c]const u8, v: c.gint) void {
    c.gst_structure_set_static_str(s, field, c.G_TYPE_INT, v, @as(?*anyopaque, null));
}

fn tryPar(outs: ?*c.GstStructure, to_par: [*c]const c.GValue, field: [*c]const u8, from: i64, dar_n: i64, dar_d: i64, other: i64, other_is_h: bool) struct { set: c.gint, pn: c.gint, pd: c.gint, exact: bool } {
    const tmp = c.gst_structure_copy(outs);
    defer c.gst_structure_free(tmp);
    const set = nearestInt(tmp, field, from);
    const tp = if (other_is_h) mul(dar_n, dar_d, other, set) else mul(dar_n, dar_d, set, other);
    if (c.gst_structure_has_field(tmp, "pixel-aspect-ratio") == 0) c.gst_structure_set_value_static_str(tmp, "pixel-aspect-ratio", to_par);
    _ = c.gst_structure_fixate_field_nearest_fraction(tmp, "pixel-aspect-ratio", @truncate(tp[0]), @truncate(tp[1]));
    var pn: c.gint = 0;
    var pd: c.gint = 0;
    _ = c.gst_structure_get_fraction(tmp, "pixel-aspect-ratio", &pn, &pd);
    return .{ .set = set, .pn = pn, .pd = pd, .exact = pn == tp[0] and pd == tp[1] };
}

fn fixateSize(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, other_in: [*c]c.GstCaps) [*c]c.GstCaps {
    var other = c.gst_caps_truncate(other_in);
    other = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(other))));
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
            _ = c.g_value_init(&tpar, c.gst_fraction_range_get_type());
            c.gst_value_set_fraction_range_full(&tpar, 1, MAXI, MAXI, 1);
            to_par = &tpar;
        }
    } else {
        if (to_par == null) {
            _ = c.g_value_init(&tpar, c.gst_fraction_get_type());
            c.gst_value_set_fraction(&tpar, 1, 1);
            to_par = &tpar;
            setFrac(outs, 1, 1);
        }
        if (from_par == null) {
            _ = c.g_value_init(&fpar, c.gst_fraction_get_type());
            c.gst_value_set_fraction(&fpar, 1, 1);
            from_par = &fpar;
        }
    }
    defer {
        if (fpar.g_type != 0) c.g_value_unset(&fpar);
        if (tpar.g_type != 0) c.g_value_unset(&tpar);
    }
    if (!cm.that(c.gst_value_is_fixed(from_par) != 0, "gst_video_convert_scale_fixate_size", "gst_value_is_fixed (from_par)")) return other;
    sizeBody(bt, ins, outs, from_par, to_par);
    return c.gst_caps_fixate(other);
}

fn sizeBody(bt: [*c]c.GstBaseTransform, ins: ?*c.GstStructure, outs: ?*c.GstStructure, from_par: [*c]const c.GValue, to_par: [*c]const c.GValue) void {
    const fp = frac(from_par);
    var wi: c.gint = 0;
    var hi: c.gint = 0;
    _ = c.gst_structure_get(ins, "width", c.G_TYPE_INT, &wi, "height", c.G_TYPE_INT, &hi, @as(?*anyopaque, null));
    const from_w: i64 = wi;
    const from_h: i64 = hi;
    wi = 0;
    hi = 0;
    _ = c.gst_structure_get(outs, "width", c.G_TYPE_INT, &wi, "height", c.G_TYPE_INT, &hi, @as(?*anyopaque, null));
    const w: i64 = wi;
    const h: i64 = hi;
    const has_par = c.gst_structure_has_field(outs, "pixel-aspect-ratio") != 0;
    if (w != 0 and h != 0) {
        if (c.gst_value_is_fixed(to_par) == 0) {
            var n: c.guint = 0;
            var d: c.guint = 0;
            if (c.gst_video_calculate_display_ratio(&n, &d, @intCast(from_w), @intCast(from_h), @intCast(fp[0]), @intCast(fp[1]), @intCast(w), @intCast(h)) != 0) {
                if (has_par) {
                    _ = c.gst_structure_fixate_field_nearest_fraction(outs, "pixel-aspect-ratio", @intCast(n), @intCast(d));
                } else if (n != d) setFrac(outs, @intCast(n), @intCast(d));
            }
        }
        return;
    }
    const dr = mul(from_w, from_h, fp[0], fp[1]);
    if (h != 0 or w != 0) {
        const use_h = h != 0;
        const known = if (use_h) h else w;
        const field: [*c]const u8 = if (use_h) "width" else "height";
        if (c.gst_value_is_fixed(to_par) != 0) {
            const tp = frac(to_par);
            const nd = mul(dr[0], dr[1], tp[1], tp[0]);
            const v: u64 = if (use_h) c.gst_util_uint64_scale_int_round(@intCast(known), @intCast(nd[0]), @intCast(nd[1])) else @as(c.guint, @truncate(c.gst_util_uint64_scale_int_round(@intCast(known), @intCast(nd[1]), @intCast(nd[0]))));
            if (v > MAXI) return overflow(bt, if (use_h) 1621 else 1699);
            _ = c.gst_structure_fixate_field_nearest_int(outs, field, @intCast(v));
            return;
        }
        const r = tryPar(outs, to_par, field, if (use_h) from_w else from_h, dr[0], dr[1], known, use_h);
        if (r.exact) {
            if (has_par or r.pn != r.pd) c.gst_structure_set_static_str(outs, field, c.G_TYPE_INT, r.set, "pixel-aspect-ratio", c.gst_fraction_get_type(), r.pn, r.pd, @as(?*anyopaque, null));
            return;
        }
        const nd = mul(dr[0], dr[1], r.pd, r.pn);
        const v: u64 = if (use_h) c.gst_util_uint64_scale_int_round(@intCast(known), @intCast(nd[0]), @intCast(nd[1])) else c.gst_util_uint64_scale_int_round(@intCast(known), @intCast(nd[1]), @intCast(nd[0]));
        if (v > MAXI) return overflow(bt, if (use_h) 1670 else 1747);
        _ = c.gst_structure_fixate_field_nearest_int(outs, field, @intCast(@as(c.guint, @truncate(v))));
        if (has_par or r.pn != r.pd) setFrac(outs, r.pn, r.pd);
        return;
    }
    if (c.gst_value_is_fixed(to_par) != 0) {
        const tp = frac(to_par);
        const nd = mul(dr[0], dr[1], tp[0], tp[1]);
        var tmp = c.gst_structure_copy(outs);
        var set_h = nearestInt(tmp, "height", from_h);
        const tw = c.gst_util_uint64_scale_int_round(@intCast(set_h), @intCast(nd[0]), @intCast(nd[1]));
        if (tw > MAXI) {
            c.gst_structure_free(tmp);
            return overflow(bt, 1777);
        }
        const ww: i64 = @intCast(@as(c.guint, @truncate(tw)));
        var set_w = nearestInt(tmp, "width", ww);
        c.gst_structure_free(tmp);
        if (set_w == ww) {
            c.gst_structure_set_static_str(outs, "width", c.G_TYPE_INT, set_w, "height", c.G_TYPE_INT, set_h, @as(?*anyopaque, null));
            return;
        }
        var f_h = set_h;
        var f_w = set_w;
        tmp = c.gst_structure_copy(outs);
        set_w = nearestInt(tmp, "width", from_w);
        const th = c.gst_util_uint64_scale_int_round(@intCast(set_w), @intCast(nd[1]), @intCast(nd[0]));
        if (th > MAXI) {
            c.gst_structure_free(tmp);
            return overflow(bt, 1805);
        }
        const hh: i64 = @intCast(@as(c.guint, @truncate(th)));
        set_h = nearestInt(tmp, "height", hh);
        c.gst_structure_free(tmp);
        if (set_h == hh) {
            c.gst_structure_set_static_str(outs, "width", c.G_TYPE_INT, set_w, "height", c.G_TYPE_INT, set_h, @as(?*anyopaque, null));
            return;
        }
        if (@as(i64, set_w) * @as(i64, @intCast(@abs(@as(i64, set_h) - hh))) < @as(i64, @intCast(@abs(@as(i64, f_w) - ww))) * f_h) {
            f_h = set_h;
            f_w = set_w;
        }
        c.gst_structure_set_static_str(outs, "width", c.G_TYPE_INT, f_w, "height", c.G_TYPE_INT, f_h, @as(?*anyopaque, null));
        return;
    }
    var tmp = c.gst_structure_copy(outs);
    const set_h = nearestInt(tmp, "height", from_h);
    const set_w = nearestInt(tmp, "width", from_w);
    const tp = mul(dr[0], dr[1], set_h, set_w);
    if (c.gst_structure_has_field(tmp, "pixel-aspect-ratio") == 0) c.gst_structure_set_value_static_str(tmp, "pixel-aspect-ratio", to_par);
    _ = c.gst_structure_fixate_field_nearest_fraction(tmp, "pixel-aspect-ratio", @truncate(tp[0]), @truncate(tp[1]));
    var pn: c.gint = 0;
    var pd: c.gint = 0;
    _ = c.gst_structure_get_fraction(tmp, "pixel-aspect-ratio", &pn, &pd);
    c.gst_structure_free(tmp);
    const finish = struct {
        fn f(o: ?*c.GstStructure, hp: bool, a: c.gint, b: c.gint, n: c.gint, d: c.gint) void {
            c.gst_structure_set_static_str(o, "width", c.G_TYPE_INT, a, "height", c.G_TYPE_INT, b, @as(?*anyopaque, null));
            if (hp or n != d) setFrac(o, n, d);
        }
    }.f;
    if (pn == tp[0] and pd == tp[1]) return finish(outs, has_par, set_w, set_h, pn, pd);
    const nd = mul(dr[0], dr[1], pd, pn);
    const ww: i64 = @bitCast(c.gst_util_uint64_scale_round(@intCast(set_h), @intCast(nd[0]), @intCast(nd[1])));
    tmp = c.gst_structure_copy(outs);
    const t2 = nearestInt(tmp, "width", ww);
    c.gst_structure_free(tmp);
    if (t2 == ww) return finish(outs, has_par, t2, set_h, pn, pd);
    const hh: i64 = @bitCast(c.gst_util_uint64_scale_round(@intCast(set_w), @intCast(nd[1]), @intCast(nd[0])));
    tmp = c.gst_structure_copy(outs);
    const t3 = nearestInt(tmp, "height", hh);
    c.gst_structure_free(tmp);
    if (t3 == hh) return finish(outs, has_par, set_w, t3, pn, pd);
    finish(outs, has_par, set_w, set_h, pn, pd);
}

fn fixateCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, other_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const format = fixedFormat(dir, caps, other_in);
    if (c.gst_caps_is_empty(format) != 0) return format;
    var other = fixateSize(bt, dir, caps, other_in);
    if (c.gst_caps_get_size(other) == 1) {
        const fs = c.gst_caps_get_structure(format, 0);
        other = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(other))));
        const os = c.gst_caps_get_structure(other, 0);
        for ([_][*c]const u8{ "format", "colorimetry", "chroma-site" }) |field| {
            if (c.gst_structure_has_field(fs, field) != 0) {
                c.gst_structure_set_static_str(os, field, c.G_TYPE_STRING, c.gst_structure_get_string(fs, field), @as(?*anyopaque, null));
            } else c.gst_structure_remove_field(os, field);
        }
    }
    c.gst_mini_object_unref(@ptrCast(format));
    return other;
}

fn transformFrame(vf: [*c]c.GstVideoFilter, in: [*c]c.GstVideoFrame, out: [*c]c.GstVideoFrame) callconv(.c) c.GstFlowReturn {
    const s = me(vf);
    const p = s.p;
    if (p.config_changed) {
        const options = c.gst_structure_copy(p.config);
        c.gst_video_converter_free(p.convert);
        p.convert = createConverter(s, &vf[0].in_info, &vf[0].out_info, options);
        p.config_changed = false;
    }
    c.gst_video_converter_frame(p.convert, in, out);
    return c.GST_FLOW_OK;
}

fn srcEvent(bt: [*c]c.GstBaseTransform, ev_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    var ev = ev_in;
    const vf = filt(bt);
    if (cm.eventType(ev) == c.GST_EVENT_NAVIGATION and (vf.in_info.width != vf.out_info.width or vf.in_info.height != vf.out_info.height)) {
        ev = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(ev))));
        var x: f64 = 0;
        var y: f64 = 0;
        if (c.gst_navigation_event_get_coordinates(ev, &x, &y) != 0) _ = c.gst_navigation_event_set_coordinates(ev, x * @as(f64, @floatFromInt(vf.in_info.width)) / @as(f64, @floatFromInt(vf.out_info.width)), y * @as(f64, @floatFromInt(vf.in_info.height)) / @as(f64, @floatFromInt(vf.out_info.height)));
    }
    return @as(*c.GstBaseTransformClass, @ptrCast(@alignCast(parent.?))).src_event.?(bt, ev);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p = me(o).p;
    if (p.pool) |pl| c.gst_object_unref(pl);
    p.pool = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p = me(o).p;
    if (p.convert) |cv| c.gst_video_converter_free(cv);
    if (p.config) |s| c.gst_structure_free(s);
    std.heap.c_allocator.destroy(p);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("videoconvertscale", 0, "videoconvertscale element");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const CP = cm.RW | c.G_PARAM_CONSTRUCT;
    c.g_object_class_install_property(oc, PROP_METHOD, c.g_param_spec_enum("method", "method", "method", methodType(), BILINEAR, cm.RW));
    c.g_object_class_install_property(oc, PROP_ADD_BORDERS, c.g_param_spec_boolean("add-borders", "Add Borders", "Add black borders if necessary to keep the display aspect ratio", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_SHARPNESS, c.g_param_spec_double("sharpness", "Sharpness", "Sharpness of filter", 0.5, 1.5, 1.0, CP));
    c.g_object_class_install_property(oc, PROP_SHARPEN, c.g_param_spec_double("sharpen", "Sharpen", "Sharpening", 0.0, 1.0, 0.0, CP));
    c.g_object_class_install_property(oc, PROP_DITHER, c.g_param_spec_enum("dither", "Dither", "Apply dithering while converting", c.gst_video_dither_method_get_type(), c.GST_VIDEO_DITHER_BAYER, cm.RW));
    c.g_object_class_install_property(oc, PROP_ENVELOPE, c.g_param_spec_double("envelope", "Envelope", "Size of filter envelope", 1.0, 5.0, 2.0, CP));
    c.g_object_class_install_property(oc, PROP_N_THREADS, c.g_param_spec_uint("n-threads", "Threads", "Maximum number of threads to use", 0, std.math.maxInt(c.guint), 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_DITHER_QUANTIZATION, c.g_param_spec_uint("dither-quantization", "Dither Quantize", "Quantizer to use", 0, std.math.maxInt(c.guint), 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_CHROMA_RESAMPLER, c.g_param_spec_enum("chroma-resampler", "Chroma resampler", "Chroma resampler method", c.gst_video_resampler_method_get_type(), c.GST_VIDEO_RESAMPLER_METHOD_LINEAR, cm.RW));
    c.g_object_class_install_property(oc, PROP_ALPHA_MODE, c.g_param_spec_enum("alpha-mode", "Alpha Mode", "Alpha Mode to use", c.gst_video_alpha_mode_get_type(), c.GST_VIDEO_ALPHA_MODE_COPY, cm.RW));
    c.g_object_class_install_property(oc, PROP_ALPHA_VALUE, c.g_param_spec_double("alpha-value", "Alpha Value", "Alpha Value to use", 0.0, 1.0, 1.0, cm.RW));
    c.g_object_class_install_property(oc, PROP_CHROMA_MODE, c.g_param_spec_enum("chroma-mode", "Chroma Mode", "Chroma Resampling Mode", c.gst_video_chroma_mode_get_type(), c.GST_VIDEO_CHROMA_MODE_FULL, cm.RW));
    c.g_object_class_install_property(oc, PROP_MATRIX_MODE, c.g_param_spec_enum("matrix-mode", "Matrix Mode", "Matrix Conversion Mode", c.gst_video_matrix_mode_get_type(), c.GST_VIDEO_MATRIX_MODE_FULL, cm.RW));
    c.g_object_class_install_property(oc, PROP_GAMMA_MODE, c.g_param_spec_enum("gamma-mode", "Gamma Mode", "Gamma Conversion Mode", c.gst_video_gamma_mode_get_type(), c.GST_VIDEO_GAMMA_MODE_NONE, cm.RW));
    c.g_object_class_install_property(oc, PROP_PRIMARIES_MODE, c.g_param_spec_enum("primaries-mode", "Primaries Mode", "Primaries Conversion Mode", c.gst_video_primaries_mode_get_type(), c.GST_VIDEO_PRIMARIES_MODE_NONE, cm.RW));
    c.g_object_class_install_property(oc, PROP_CONVERTER_CONFIG, c.g_param_spec_boxed("converter-config", "Converter configuration", "A GstStructure describing the configuration that should be used. This configuration, if set, takes precedence over the other similar conversion properties.", c.gst_structure_get_type(), cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video colorspace converter and scaler", "Filter/Converter/Video/Scaler/Colorspace", "Resizes video and converts from one colorspace to another", "Wim Taymans <wim.taymans@gmail.com>");
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, capsList()));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, capsList()));
    ec.set_context = setContext;
    ec.change_state = changeState;
    size_quark = c.g_quark_from_static_string(c.GST_META_TAG_VIDEO_SIZE_STR);
    scale_quark = c.gst_video_meta_transform_scale_get_quark();
    matrix_quark = c.gst_video_meta_transform_matrix_get_quark();
    c.gst_type_mark_as_plugin_api(methodType(), 0);
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.transform_caps = transformCaps;
    tc.fixate_caps = fixateCaps;
    tc.filter_meta = filterMeta;
    tc.src_event = srcEvent;
    tc.transform_meta = transformMeta;
    const fc: *c.GstVideoFilterClass = @ptrCast(@alignCast(k));
    fc.set_info = setInfo;
    fc.transform_frame = transformFrame;
    const cc: *Class = @ptrCast(@alignCast(k));
    cc.converts = 1;
    cc.scales = 1;
    c.gst_type_mark_as_plugin_api(cm.typeOfClass(k), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = std.heap.c_allocator.create(Priv) catch @panic("oom");
    p.* = .{};
    me(inst).p = p;
}

fn convertClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video colorspace converter", "Filter/Converter/Video/Colorspace", "Converts video from one colorspace to another", "Wim Taymans <wim.taymans@gmail.com>");
    const cc: *Class = @ptrCast(@alignCast(k));
    cc.converts = 1;
    cc.scales = 0;
}

const PROP_GAMMA_DECODE = 1;

fn scaleGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != PROP_GAMMA_DECODE) return cm.warnInvalid("../gst/videoconvertscale/gstvideoscale.c", o, id, spec, 82);
    var mode: c.gint = 0;
    c.g_object_get(o, "gamma-mode", &mode, @as(?*anyopaque, null));
    c.g_value_set_boolean(v, @intFromBool(mode == c.GST_VIDEO_GAMMA_MODE_REMAP));
}

fn scaleSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != PROP_GAMMA_DECODE) return cm.warnInvalid("../gst/videoconvertscale/gstvideoscale.c", o, id, spec, 102);
    const mode: c.gint = if (c.g_value_get_boolean(v) != 0) c.GST_VIDEO_GAMMA_MODE_REMAP else c.GST_VIDEO_GAMMA_MODE_NONE;
    c.g_object_set(o, "gamma-mode", mode, @as(?*anyopaque, null));
}

fn scaleClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = scaleSet;
    oc.get_property = scaleGet;
    c.g_object_class_install_property(oc, PROP_GAMMA_DECODE, c.g_param_spec_boolean("gamma-decode", "Gamma Decode", "Decode gamma before scaling", 0, cm.RW | c.G_PARAM_CONSTRUCT));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video scaler", "Filter/Video/Scaler", "Resizes video", "Wim Taymans <wim.taymans@gmail.com>");
    const cc: *Class = @ptrCast(@alignCast(k));
    cc.converts = 0;
    cc.scales = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_video_filter_get_type(), "GstVideoConvertScale", Class, Self, classInit, init);
        }
    }.f);
}

fn convertType() c.GType {
    return convert_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(getType(), c.g_intern_static_string("GstVideoConvert"), @sizeOf(Class), convertClassInit, @sizeOf(Self), null, 0);
        }
    }.f);
}

fn scaleType() c.GType {
    return scale_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(getType(), c.g_intern_static_string("GstVideoScale"), @sizeOf(Class), scaleClassInit, @sizeOf(Self), null, 0);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    if (c.gst_element_register(p, "videoscale", c.GST_RANK_MARGINAL, scaleType()) == 0) return false;
    if (c.gst_element_register(p, "videoconvert", c.GST_RANK_MARGINAL, convertType()) == 0) return false;
    return c.gst_element_register(p, "videoconvertscale", c.GST_RANK_SECONDARY, getType()) != 0;
}
