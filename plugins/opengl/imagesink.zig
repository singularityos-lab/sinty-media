const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");
const sinkbin = @import("sinkbin.zig");

const FILE = "../ext/gl/gstglimagesink.c";
const APIS = c.GST_GL_API_OPENGL | c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL3;
const PROFILE = c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY;
const TT = ", texture-target = (string) { 2D, external-oes } ";
const CAPS = el.capsWithFeatures("memory:GLMemory", "RGBA") ++ TT ++ " ; " ++ el.capsWithFeatures("memory:GLMemory,meta:GstVideoOverlayComposition", "RGBA") ++ TT;
const NONE = std.math.maxInt(u64);

const Prop = enum(c.guint) { display = 1, rotate_method, force_aspect_ratio, pixel_aspect_ratio, context, handle_events, ignore_alpha, mview_layout, mview_flags, mview_downmix, last };
const BinProp = enum(c.guint) { rotate_method = 1, force_aspect_ratio, pixel_aspect_ratio, handle_events, context, ignore_alpha, show_preroll_frame, mview_layout, mview_flags, mview_downmix, last };

const Self = extern struct {
    video_sink: c.GstVideoSink,
    window_id: c.guintptr,
    new_window_id: c.guintptr,
    mouse_sig_id: c.gulong,
    key_sig_id: c.gulong,
    mouse_scroll_sig_id: c.gulong,
    x: c.gint,
    y: c.gint,
    width: c.gint,
    height: c.gint,
    in_info: c.GstVideoInfo,
    in_caps: [*c]c.GstCaps,
    out_info: c.GstVideoInfo,
    out_caps: [*c]c.GstCaps,
    texture_target: c.GstGLTextureTarget,
    padded_width: c.gint,
    padded_height: c.gint,
    display: ?*c.GstGLDisplay,
    context: ?*c.GstGLContext,
    other_context: ?*c.GstGLContext,
    handle_events: c.gboolean,
    ignore_alpha: c.gboolean,
    convert_views: ?*c.GstGLViewConvert,
    input_buffer: [*c]c.GstBuffer,
    input_buffer2: [*c]c.GstBuffer,
    next_tex: c.guint,
    next_buffer: [*c]c.GstBuffer,
    next_buffer2: [*c]c.GstBuffer,
    next_sync: [*c]c.GstBuffer,
    next_sync_meta: ?*c.GstGLSyncMeta,
    to_quit: c.gint,
    keep_aspect_ratio: c.gboolean,
    par_n: c.gint,
    par_d: c.gint,
    drawing_lock: c.GMutex,
    stored_buffer: [2][*c]c.GstBuffer,
    stored_sync: [*c]c.GstBuffer,
    stored_sync_meta: ?*c.GstGLSyncMeta,
    redisplay_texture: c.GLuint,
    need_resize_window: c.gboolean,
    window_resized: c.gboolean,
    window_width: c.guint,
    window_height: c.guint,
    display_rect: c.GstVideoRectangle,
    redisplay_shader: ?*c.GstGLShader,
    vao: c.GLuint,
    vbo_indices: c.GLuint,
    vertex_buffer: c.GLuint,
    attr_position: c.GLint,
    attr_texture: c.GLint,
    mview_output_mode: c.GstVideoMultiviewMode,
    mview_output_flags: c.GstVideoMultiviewFlags,
    output_mode_changed: c.gboolean,
    mview_downmix_mode: c.GstGLStereoDownmix,
    overlay_compositor: ?*c.GstGLOverlayCompositor,
    current_rotate_method: c.GstVideoOrientationMethod,
    rotate_method: c.GstVideoOrientationMethod,
    transform_matrix: ?*const [16]f32,
};

const Class = extern struct {
    parent: c.GstVideoSinkClass,
};

const vertices = [_]f32{ 1, 1, 0, 1, 0, -1, 1, 0, 0, 0, -1, -1, 0, 0, 1, 1, -1, 0, 1, 1 };
const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

const matrices = [_][16]f32{
    .{ 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    .{ -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    .{ 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    .{ -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    .{ 0, -1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    .{ 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var bin_once: cm.Once = .{};
var rotate_once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_bs: *c.GstBaseSinkClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var sig_draw: c.guint = 0;
var sig_reshape: c.guint = 0;
var bin_sig_draw: c.guint = 0;
var bin_sig_reshape: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn lock(s: *Self) void {
    c.g_mutex_lock(&s.drawing_lock);
}

fn unlock(s: *Self) void {
    c.g_mutex_unlock(&s.drawing_lock);
}

fn gl(s: *Self) *c.GstGLFuncs {
    return @ptrCast(@alignCast(s.context.?.gl_vtable));
}

fn sinkpad(s: *Self) ?*c.GstPad {
    return @as(*c.GstBaseSink, @ptrCast(@alignCast(s))).sinkpad;
}

fn rotateType() c.GType {
    return rotate_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_VIDEO_ORIENTATION_IDENTITY, .value_name = "Identity (no rotation)", .value_nick = "none" },
            .{ .value = c.GST_VIDEO_ORIENTATION_90R, .value_name = "Rotate clockwise 90 degrees", .value_nick = "clockwise" },
            .{ .value = c.GST_VIDEO_ORIENTATION_180, .value_name = "Rotate 180 degrees", .value_nick = "rotate-180" },
            .{ .value = c.GST_VIDEO_ORIENTATION_90L, .value_name = "Rotate counter-clockwise 90 degrees", .value_nick = "counterclockwise" },
            .{ .value = c.GST_VIDEO_ORIENTATION_HORIZ, .value_name = "Flip horizontally", .value_nick = "horizontal-flip" },
            .{ .value = c.GST_VIDEO_ORIENTATION_VERT, .value_name = "Flip vertically", .value_nick = "vertical-flip" },
            .{ .value = c.GST_VIDEO_ORIENTATION_UL_LR, .value_name = "Flip across upper left/lower right diagonal", .value_nick = "upper-left-diagonal" },
            .{ .value = c.GST_VIDEO_ORIENTATION_UR_LL, .value_name = "Flip across upper right/lower left diagonal", .value_nick = "upper-right-diagonal" },
            .{ .value = c.GST_VIDEO_ORIENTATION_AUTO, .value_name = "Select rotate method based on image-orientation tag", .value_nick = "automatic" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstGLRotateMethod", &values);
        }
    }.f);
}

fn binSet(o: [*c]c.GObject, _: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const b: *sinkbin.Self = @ptrCast(@alignCast(o));
    c.g_object_set_property(@ptrCast(b.sink), spec[0].name, v);
}

fn binGet(o: [*c]c.GObject, _: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const b: *sinkbin.Self = @ptrCast(@alignCast(o));
    c.g_object_get_property(@ptrCast(b.sink), spec[0].name, v);
}

fn onReshape(_: *Self, ctx: ?*c.GstGLContext, w: c.guint, h: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    var ret: c.gboolean = 0;
    c.g_signal_emit(data, bin_sig_reshape, 0, ctx, w, h, &ret);
    return ret;
}

fn onDraw(_: *Self, ctx: ?*c.GstGLContext, sample: ?*c.GstSample, data: c.gpointer) callconv(.c) c.gboolean {
    var ret: c.gboolean = 0;
    c.g_signal_emit(data, bin_sig_draw, 0, ctx, sample, &ret);
    return ret;
}

fn binInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const sink = c.g_object_new(getType(), null);
    _ = c.g_signal_connect_data(sink, "client-reshape", @ptrCast(&onReshape), inst, null, 0);
    _ = c.g_signal_connect_data(sink, "client-draw", @ptrCast(&onDraw), inst, null, 0);
    sinkbin.finishInitWith(inst, @ptrCast(@alignCast(sink)));
}

fn installCommon(oc: *c.GObjectClass, rotate: c.guint, aspect: c.guint, par: c.guint, ctx: c.guint, events: c.guint, alpha: c.guint) void {
    c.g_object_class_install_property(oc, rotate, c.g_param_spec_enum("rotate-method", "rotate method", "rotate method", rotateType(), 0, cm.RW));
    c.g_object_class_install_property(oc, aspect, c.g_param_spec_boolean("force-aspect-ratio", "Force aspect ratio", "When enabled, scaling will respect original aspect ratio", 1, cm.RW));
    c.g_object_class_install_property(oc, par, c.gst_param_spec_fraction("pixel-aspect-ratio", "Pixel Aspect Ratio", "The pixel aspect ratio of the device", 0, 1, std.math.maxInt(c.gint), 1, 1, 1, cm.RW));
    c.g_object_class_install_property(oc, ctx, c.g_param_spec_object("context", "OpenGL context", "Get OpenGL context", c.gst_gl_context_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, events, c.g_param_spec_boolean("handle-events", "Handle XEvents", "When enabled, XEvents will be selected and handled", 1, cm.RW));
    c.g_object_class_install_property(oc, alpha, c.g_param_spec_boolean("ignore-alpha", "Ignore Alpha", "When enabled, alpha will be ignored and converted to black", 1, cm.RW));
}

fn installMview(oc: *c.GObjectClass, layout: c.guint, flags: c.guint, downmix: c.guint) void {
    c.g_object_class_install_property(oc, layout, c.g_param_spec_enum("output-multiview-mode", "Output Multiview Mode", "Choose output mode for multiview/3D video", c.gst_video_multiview_mode_get_type(), c.GST_VIDEO_MULTIVIEW_MODE_MONO, cm.RW));
    c.g_object_class_install_property(oc, flags, c.g_param_spec_flags("output-multiview-flags", "Output Multiview Flags", "Output multiview layout modifier flags", c.gst_video_multiview_flags_get_type(), c.GST_VIDEO_MULTIVIEW_FLAGS_NONE, cm.RW));
    c.g_object_class_install_property(oc, downmix, c.g_param_spec_enum("output-multiview-downmix-mode", "Mode for mono downmixed output", "Output anaglyph type to generate when downmixing to mono", c.gst_gl_stereo_downmix_get_type(), c.GST_GL_STEREO_DOWNMIX_ANAGLYPH_GREEN_MAGENTA_DUBOIS, cm.RW));
}

fn binClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.get_property = binGet;
    oc.set_property = binSet;
    c.g_object_class_install_property(oc, @intFromEnum(BinProp.rotate_method), c.g_param_spec_enum("rotate-method", "rotate method", "rotate method", rotateType(), 0, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(BinProp.force_aspect_ratio), c.g_param_spec_boolean("force-aspect-ratio", "Force aspect ratio", "When enabled, scaling will respect original aspect ratio", 1, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(BinProp.handle_events), c.g_param_spec_boolean("handle-events", "Handle XEvents", "When enabled, XEvents will be selected and handled", 1, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(BinProp.ignore_alpha), c.g_param_spec_boolean("ignore-alpha", "Ignore Alpha", "When enabled, alpha will be ignored and converted to black", 1, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(BinProp.context), c.g_param_spec_object("context", "OpenGL context", "Get OpenGL context", c.gst_gl_context_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, @intFromEnum(BinProp.pixel_aspect_ratio), c.gst_param_spec_fraction("pixel-aspect-ratio", "Pixel Aspect Ratio", "The pixel aspect ratio of the device", 0, 1, std.math.maxInt(c.gint), 1, 1, 1, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(BinProp.show_preroll_frame), c.g_param_spec_boolean("show-preroll-frame", "Show preroll frame", "Whether to render video frames during preroll", 1, cm.RW | c.G_PARAM_CONSTRUCT));
    installMview(oc, @intFromEnum(BinProp.mview_layout), @intFromEnum(BinProp.mview_flags), @intFromEnum(BinProp.mview_downmix));
    _ = c.gst_video_overlay_install_properties(oc, @intFromEnum(BinProp.last));
    bin_sig_draw = c.g_signal_new("client-draw", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_BOOLEAN, 2, c.gst_gl_context_get_type(), c.gst_sample_get_type());
    bin_sig_reshape = c.g_signal_new("client-reshape", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_BOOLEAN, 3, c.gst_gl_context_get_type(), c.G_TYPE_UINT, c.G_TYPE_UINT);
    c.gst_type_mark_as_plugin_api(rotateType(), 0);
}

fn binType() c.GType {
    return bin_once.get(struct {
        fn f() c.GType {
            return cm.register(sinkbin.getType(), "GstGLImageSinkBin", sinkbin.Class, sinkbin.Self, binClassInit, binInit);
        }
    }.f);
}

fn displayToStream(s: *Self, x: f64, y: f64, sx: *f64, sy: *f64) void {
    const w: f64 = @floatFromInt(s.out_info.width);
    const h: f64 = @floatFromInt(s.out_info.height);
    const r = s.display_rect;
    sx.* = if (r.w > 0) (x - @as(f64, @floatFromInt(r.x))) / @as(f64, @floatFromInt(r.w)) * w else 0;
    if (sx.* < 0) sx.* = 0;
    if (sx.* > w) sx.* = w;
    sy.* = if (r.h > 0) (y - @as(f64, @floatFromInt(r.y))) / @as(f64, @floatFromInt(r.h)) * h else 0;
    if (sy.* < 0) sy.* = 0;
    if (sy.* > h) sy.* = h;
}

fn setRotateMethod(s: *Self, method_in: c.GstVideoOrientationMethod, from_tag: bool) void {
    var tag: c.GstVideoOrientationMethod = c.GST_VIDEO_ORIENTATION_IDENTITY;
    lock(s);
    defer unlock(s);
    if (from_tag) tag = method_in else s.rotate_method = method_in;
    const m = if (s.rotate_method == c.GST_VIDEO_ORIENTATION_AUTO) tag else s.rotate_method;
    if (m == s.current_rotate_method) return;
    switch (m) {
        c.GST_VIDEO_ORIENTATION_IDENTITY => s.transform_matrix = null,
        c.GST_VIDEO_ORIENTATION_90R => s.transform_matrix = &matrices[0],
        c.GST_VIDEO_ORIENTATION_180 => s.transform_matrix = &matrices[1],
        c.GST_VIDEO_ORIENTATION_90L => s.transform_matrix = &matrices[2],
        c.GST_VIDEO_ORIENTATION_HORIZ => s.transform_matrix = &matrices[3],
        c.GST_VIDEO_ORIENTATION_VERT => s.transform_matrix = &matrices[4],
        c.GST_VIDEO_ORIENTATION_UL_LR => s.transform_matrix = &matrices[5],
        c.GST_VIDEO_ORIENTATION_UR_LL => s.transform_matrix = &matrices[6],
        else => {
            c.g_assertion_message_expr("GStreamer", FILE, 588, "gst_glimage_sink_set_rotate_method", null);
            return;
        },
    }
    s.output_mode_changed = 1;
    s.current_rotate_method = m;
}

fn navSend(nav: ?*c.GstNavigation, ev: [*c]c.GstEvent) callconv(.c) void {
    const s = me(nav);
    if (s.context == null) {
        c.gst_event_unref(ev);
        return;
    }
    var e: [*c]c.GstEvent = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev)));
    const window = c.gst_gl_context_get_window(s.context);
    if (!cm.that(window != null and c.g_type_check_instance_is_a(@ptrCast(window), c.gst_gl_window_get_type()) != 0, "gst_glimage_sink_navigation_send_event", "GST_IS_GL_WINDOW (window)")) return;
    var w: c.guint = @bitCast(s.video_sink.width);
    var h: c.guint = @bitCast(s.video_sink.height);
    c.gst_gl_window_get_surface_dimensions(window, &w, &h);
    var x: f64 = 0;
    var y: f64 = 0;
    if (w != 0 and h != 0 and c.gst_navigation_event_get_coordinates(e, &x, &y) != 0) {
        var sx: f64 = 0;
        var sy: f64 = 0;
        displayToStream(s, x, y, &sx, &sy);
        _ = c.gst_navigation_event_set_coordinates(e, sx, sy);
    }
    if (w != 0 and h != 0 and c.gst_navigation_event_get_type(e) == c.GST_NAVIGATION_EVENT_MOUSE_SCROLL) {
        var dx: f64 = 0;
        var dy: f64 = 0;
        _ = c.gst_navigation_event_parse_mouse_scroll_event(e, &x, &y, &dx, &dy);
        const ow: f64 = @floatFromInt(s.out_info.width);
        const oh: f64 = @floatFromInt(s.out_info.height);
        const sdx = if (dx != 0 and s.display_rect.w > 0) dx * (ow / @as(f64, @floatFromInt(s.display_rect.w))) else dx;
        const sdy = if (dy != 0 and s.display_rect.h > 0) dy * (oh / @as(f64, @floatFromInt(s.display_rect.h))) else dy;
        _ = c.gst_mini_object_replace(@ptrCast(&e), @ptrCast(c.gst_navigation_event_new_mouse_scroll(x, y, sdx, sdy, c.GST_NAVIGATION_MODIFIER_NONE)));
    }
    _ = c.gst_mini_object_ref(@ptrCast(e));
    if (c.gst_pad_push_event(sinkpad(s), e) == 0) _ = c.gst_element_post_message(@ptrCast(s), c.gst_navigation_message_new_event(@ptrCast(s), e));
    c.gst_event_unref(e);
    c.gst_object_unref(window);
}

fn navInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstNavigationInterface = @ptrCast(@alignCast(iface));
    i.send_event_simple = navSend;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.rotate_method) => setRotateMethod(s, @intCast(c.g_value_get_enum(v)), false),
        @intFromEnum(Prop.force_aspect_ratio) => s.keep_aspect_ratio = c.g_value_get_boolean(v),
        @intFromEnum(Prop.pixel_aspect_ratio) => {
            s.par_n = c.gst_value_get_fraction_numerator(v);
            s.par_d = c.gst_value_get_fraction_denominator(v);
        },
        @intFromEnum(Prop.handle_events) => handleEvents(@ptrCast(s), c.g_value_get_boolean(v)),
        @intFromEnum(Prop.ignore_alpha) => s.ignore_alpha = c.g_value_get_boolean(v),
        @intFromEnum(Prop.mview_layout), @intFromEnum(Prop.mview_flags), @intFromEnum(Prop.mview_downmix) => {
            lock(s);
            switch (id) {
                @intFromEnum(Prop.mview_layout) => s.mview_output_mode = c.g_value_get_enum(v),
                @intFromEnum(Prop.mview_flags) => s.mview_output_flags = c.g_value_get_flags(v),
                else => s.mview_downmix_mode = @intCast(c.g_value_get_enum(v)),
            }
            s.output_mode_changed = 1;
            unlock(s);
        },
        else => if (c.gst_video_overlay_set_property(o, @intFromEnum(Prop.last), id, v) == 0) cm.warnInvalid(FILE, o, id, spec, 882),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.rotate_method) => c.g_value_set_enum(v, @intCast(s.current_rotate_method)),
        @intFromEnum(Prop.force_aspect_ratio) => c.g_value_set_boolean(v, s.keep_aspect_ratio),
        @intFromEnum(Prop.pixel_aspect_ratio) => c.gst_value_set_fraction(v, s.par_n, s.par_d),
        @intFromEnum(Prop.context) => c.g_value_set_object(v, s.context),
        @intFromEnum(Prop.handle_events) => c.g_value_set_boolean(v, s.handle_events),
        @intFromEnum(Prop.ignore_alpha) => c.g_value_set_boolean(v, s.ignore_alpha),
        @intFromEnum(Prop.mview_layout) => c.g_value_set_enum(v, s.mview_output_mode),
        @intFromEnum(Prop.mview_flags) => c.g_value_set_flags(v, s.mview_output_flags),
        @intFromEnum(Prop.mview_downmix) => c.g_value_set_enum(v, @intCast(s.mview_downmix_mode)),
        else => cm.warnInvalid(FILE, o, id, spec, 940),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&me(o).drawing_lock);
    parent_obj.finalize.?(o);
}

fn keyEvent(_: ?*c.GstGLWindow, name: [*c]u8, key: [*c]u8, s: *Self) callconv(.c) void {
    var e: [*c]c.GstEvent = null;
    if (c.g_strcmp0("key-press", name) == 0) {
        e = c.gst_navigation_event_new_key_press(key, c.GST_NAVIGATION_MODIFIER_NONE);
    } else if (c.g_strcmp0("key-release", name) == 0) {
        e = c.gst_navigation_event_new_key_release(key, c.GST_NAVIGATION_MODIFIER_NONE);
    }
    if (e != null) c.gst_navigation_send_event_simple(@ptrCast(s), e);
}

fn mouseEvent(_: ?*c.GstGLWindow, name: [*c]u8, button: c_int, x: f64, y: f64, s: *Self) callconv(.c) void {
    var e: [*c]c.GstEvent = null;
    if (c.g_strcmp0("mouse-button-press", name) == 0) {
        e = c.gst_navigation_event_new_mouse_button_press(button, x, y, c.GST_NAVIGATION_MODIFIER_NONE);
    } else if (c.g_strcmp0("mouse-button-release", name) == 0) {
        e = c.gst_navigation_event_new_mouse_button_release(button, x, y, c.GST_NAVIGATION_MODIFIER_NONE);
    } else if (c.g_strcmp0("mouse-move", name) == 0) {
        e = c.gst_navigation_event_new_mouse_move(x, y, c.GST_NAVIGATION_MODIFIER_NONE);
    }
    if (e != null) c.gst_navigation_send_event_simple(@ptrCast(s), e);
}

fn scrollEvent(_: ?*c.GstGLWindow, x: f64, y: f64, dx: f64, dy: f64, s: *Self) callconv(.c) void {
    c.gst_navigation_send_event_simple(@ptrCast(s), c.gst_navigation_event_new_mouse_scroll(x, y, dx, dy, c.GST_NAVIGATION_MODIFIER_NONE));
}

fn setContextField(s: *Self, ctx: ?*c.GstGLContext) void {
    lock(s);
    const old = s.context;
    s.context = ctx;
    unlock(s);
    if (old != null) c.gst_object_unref(old);
}

fn setOther(s: *Self, ctx: ?*c.GstGLContext) void {
    lock(s);
    if (s.other_context != null) c.gst_object_unref(s.other_context);
    s.other_context = ctx;
    unlock(s);
}

fn setDisplay(s: *Self, d: ?*c.GstGLDisplay) void {
    lock(s);
    if (s.display != null) c.gst_object_unref(s.display);
    s.display = d;
    unlock(s);
}

fn contextError(s: *Self, err: [*c]c.GError) bool {
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(err[0].message), null, FILE, "_ensure_gl_setup", 1159);
    setContextField(s, null);
    var e = err;
    c.g_clear_error(&e);
    return false;
}

fn ensureSetup(s: *Self) bool {
    if (s.context != null) return true;
    var err: [*c]c.GError = null;
    cm.lock(s.display);
    while (true) {
        setContextField(s, null);
        var other: ?*c.GstGLContext = if (s.other_context != null) @ptrCast(@alignCast(c.gst_object_ref(s.other_context))) else c.gst_gl_display_get_gl_context_for_thread(s.display, null);
        var ctx: ?*c.GstGLContext = null;
        c.g_signal_emit_by_name(s.display, "create-context", other, &ctx);
        if (ctx == null) {
            ctx = c.gst_gl_context_new(s.display);
            if (ctx == null) {
                c.g_set_error(&err, c.gst_gl_context_error_quark(), c.GST_GL_CONTEXT_ERROR_FAILED, "Failed to create GL context");
                if (other != null) c.gst_object_unref(other);
                cm.unlock(s.display);
                return contextError(s, err);
            }
            const win = c.gst_gl_display_create_window(ctx.?.display);
            c.gst_gl_window_set_request_output_surface(win, 1);
            _ = c.gst_gl_context_set_window(ctx, win);
            if (win != null) c.gst_object_unref(win);
            if (c.gst_gl_context_create(ctx, other, &err) == 0) {
                if (other != null) c.gst_object_unref(other);
                c.gst_object_unref(ctx);
                cm.unlock(s.display);
                return contextError(s, err);
            }
        }
        setContextField(s, ctx);
        const window = c.gst_gl_context_get_window(s.context);
        if (s.window_id == 0 and s.new_window_id == 0) c.gst_video_overlay_prepare_window_handle(@ptrCast(s));
        if (s.window_id != s.new_window_id) {
            s.window_id = s.new_window_id;
            c.gst_gl_window_set_window_handle(window, s.window_id);
        }
        c.gst_gl_window_handle_events(window, s.handle_events);
        c.gst_gl_window_set_resize_callback(window, @ptrCast(&onResize), c.gst_object_ref(s), c.gst_object_unref);
        c.gst_gl_window_set_draw_callback(window, @ptrCast(&onDrawWindow), c.gst_object_ref(s), c.gst_object_unref);
        c.gst_gl_window_set_close_callback(window, @ptrCast(&onClose), c.gst_object_ref(s), c.gst_object_unref);
        s.key_sig_id = c.g_signal_connect_data(window, "key-event", @ptrCast(&keyEvent), s, null, 0);
        s.mouse_sig_id = c.g_signal_connect_data(window, "mouse-event", @ptrCast(&mouseEvent), s, null, 0);
        s.mouse_scroll_sig_id = c.g_signal_connect_data(window, "scroll-event", @ptrCast(&scrollEvent), s, null, 0);
        _ = c.gst_gl_window_set_render_rectangle(window, s.x, s.y, s.width, s.height);
        if (other != null) c.gst_object_unref(other);
        other = null;
        c.gst_object_unref(window);
        if (c.gst_gl_display_add_context(s.display, s.context) != 0) break;
    }
    cm.unlock(s.display);
    return true;
}

fn event(bs: [*c]c.GstBaseSink, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (e[0].type == c.GST_EVENT_TAG) {
        var tags: ?*c.GstTagList = null;
        c.gst_event_parse_tag(e, @ptrCast(&tags));
        var m: c.GstVideoOrientationMethod = 0;
        if (c.gst_video_orientation_from_tag(tags, &m) != 0) setRotateMethod(me(bs), m, true);
    }
    return parent_bs.event.?(bs, e);
}

fn clearBuffers(s: *Self) void {
    _ = c.gst_buffer_replace(&s.input_buffer, null);
    _ = c.gst_buffer_replace(&s.input_buffer2, null);
    _ = c.gst_buffer_replace(&s.next_buffer, null);
    _ = c.gst_buffer_replace(&s.next_buffer2, null);
    _ = c.gst_buffer_replace(&s.next_sync, null);
}

fn takeStored(s: *Self) [2][*c]c.GstBuffer {
    s.redisplay_texture = 0;
    const b = s.stored_buffer;
    s.stored_buffer = .{ null, null };
    s.stored_sync_meta = null;
    s.next_sync_meta = null;
    return b;
}

fn query(bs: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bs);
    switch (q[0].type) {
        c.GST_QUERY_CONTEXT => {
            lock(s);
            const ctx: ?*c.GstGLContext = if (s.context != null) @ptrCast(@alignCast(c.gst_object_ref(s.context))) else null;
            const other: ?*c.GstGLContext = if (s.other_context != null) @ptrCast(@alignCast(c.gst_object_ref(s.other_context))) else null;
            const disp: ?*c.GstGLDisplay = if (s.display != null) @ptrCast(@alignCast(c.gst_object_ref(s.display))) else null;
            unlock(s);
            const res = c.gst_gl_handle_context_query(@ptrCast(s), q, disp, ctx, other);
            if (ctx != null) c.gst_object_unref(ctx);
            if (other != null) c.gst_object_unref(other);
            if (disp != null) c.gst_object_unref(disp);
            if (res != 0) return res;
            return 0;
        },
        c.GST_QUERY_DRAIN => {
            lock(s);
            var b = takeStored(s);
            unlock(s);
            _ = c.gst_buffer_replace(&b[0], null);
            _ = c.gst_buffer_replace(&b[1], null);
            clearBuffers(s);
            return parent_bs.query.?(bs, q);
        },
        else => return parent_bs.query.?(bs, q),
    }
}

fn setContext(e: [*c]c.GstElement, ctx: ?*c.GstContext) callconv(.c) void {
    const s = me(e);
    var disp: ?*c.GstGLDisplay = null;
    var other: ?*c.GstGLContext = null;
    _ = c.gst_gl_handle_set_context(e, ctx, @ptrCast(&disp), @ptrCast(&other));
    if (disp != null) setDisplay(s, disp);
    if (other != null) setOther(s, other);
    if (s.display != null) c.gst_gl_display_filter_gl_api(s.display, APIS);
    parent_el.set_context.?(e, ctx);
}

fn cleanupTrampoline(data: c.gpointer) callconv(.c) void {
    cleanupGlthread(me(data));
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            if (c.gst_gl_ensure_element_data(s, @ptrCast(&s.display), @ptrCast(&s.other_context)) == 0) return c.GST_STATE_CHANGE_FAILURE;
            c.gst_gl_display_filter_gl_api(s.display, APIS);
            if (!ensureSetup(s)) return c.GST_STATE_CHANGE_FAILURE;
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => @atomicStore(c.gint, &s.to_quit, 0, .seq_cst),
        else => {},
    }
    const ret = parent_el.change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lock(s);
            var b = takeStored(s);
            if (s.stored_sync != null) c.gst_buffer_unref(s.stored_sync);
            s.stored_sync = null;
            unlock(s);
            _ = c.gst_buffer_replace(&b[0], null);
            _ = c.gst_buffer_replace(&b[1], null);
            _ = c.gst_object_replace(@ptrCast(&s.convert_views), null);
            clearBuffers(s);
            s.window_id = 0;
            s.video_sink.width = 1;
            s.video_sink.height = 1;
            if (s.out_caps != null) c.gst_caps_unref(s.out_caps);
            s.out_caps = null;
            if (s.in_caps != null) c.gst_caps_unref(s.in_caps);
            s.in_caps = null;
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (s.overlay_compositor != null) c.gst_object_unref(s.overlay_compositor);
            s.overlay_compositor = null;
            lock(s);
            const ctx: ?*c.GstGLContext = if (s.context != null) @ptrCast(@alignCast(c.gst_object_ref(s.context))) else null;
            unlock(s);
            if (ctx != null) {
                const window = c.gst_gl_context_get_window(ctx);
                c.gst_gl_window_send_message(window, cleanupTrampoline, s);
                c.gst_gl_window_set_resize_callback(window, null, null, null);
                c.gst_gl_window_set_draw_callback(window, null, null, null);
                c.gst_gl_window_set_close_callback(window, null, null, null);
                disconnect(window, &s.key_sig_id);
                disconnect(window, &s.mouse_sig_id);
                disconnect(window, &s.mouse_scroll_sig_id);
                c.gst_object_unref(window);
                setContextField(s, null);
                c.gst_object_unref(ctx);
            }
            s.window_id = 0;
            setOther(s, null);
            setDisplay(s, null);
        },
        else => {},
    }
    return ret;
}

fn disconnect(window: ?*c.GstGLWindow, id: *c.gulong) void {
    if (id.* != 0) c.g_signal_handler_disconnect(window, id.*);
    id.* = 0;
}

fn getTimes(bs: [*c]c.GstBaseSink, b: [*c]c.GstBuffer, start: [*c]c.GstClockTime, end: [*c]c.GstClockTime) callconv(.c) void {
    const s = me(bs);
    if (b[0].pts == NONE) return;
    start.* = b[0].pts;
    if (b[0].duration != NONE) {
        end.* = start.* + b[0].duration;
    } else if (s.out_info.fps_n > 0) {
        end.* = start.* + c.gst_util_uint64_scale_int(c.GST_SECOND, s.out_info.fps_d, s.out_info.fps_n);
    }
}

fn getCaps(bs: [*c]c.GstBaseSink, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const tmp = c.gst_pad_get_pad_template_caps(bs[0].sinkpad);
    var res = tmp;
    if (filter != null) {
        res = c.gst_caps_intersect_full(filter, tmp, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(tmp);
    }
    return c.gst_gl_overlay_compositor_add_caps(res);
}

fn scaleU(v: c.gint, n: c.guint, d: c.guint) c.gint {
    return @bitCast(@as(c.guint, @truncate(c.gst_util_uint64_scale_int(@bitCast(@as(i64, v)), @bitCast(n), @bitCast(d)))));
}

fn configureDisplay(s: *Self, info: *const c.GstVideoInfo) bool {
    const w = info.width;
    const h = info.height;
    var pn = info.par_n;
    const pd = info.par_d;
    if (pn == 0) pn = 1;
    var dpn: c.gint = 1;
    var dpd: c.gint = 1;
    if (s.par_n != 0 and s.par_d != 0) {
        dpn = s.par_n;
        dpd = s.par_d;
    }
    var num: c.guint = 0;
    var den: c.guint = 0;
    if (c.gst_video_calculate_display_ratio(&num, &den, @bitCast(w), @bitCast(h), @bitCast(pn), @bitCast(pd), @bitCast(dpn), @bitCast(dpd)) == 0) return false;
    if (@as(c.guint, @bitCast(h)) % den == 0) {
        s.video_sink.width = scaleU(h, num, den);
        s.video_sink.height = h;
    } else if (@as(c.guint, @bitCast(w)) % num == 0) {
        s.video_sink.width = w;
        s.video_sink.height = scaleU(w, den, num);
    } else {
        s.video_sink.width = scaleU(h, num, den);
        s.video_sink.height = h;
    }
    return true;
}

fn modesEqual(a: c.GstVideoMultiviewMode, b: c.GstVideoMultiviewMode) bool {
    if (a == b) return true;
    if (a == c.GST_VIDEO_MULTIVIEW_MODE_NONE and b == c.GST_VIDEO_MULTIVIEW_MODE_MONO) return true;
    return a == c.GST_VIDEO_MULTIVIEW_MODE_MONO and b == c.GST_VIDEO_MULTIVIEW_MODE_NONE;
}

fn updateOutput(s: *Self) bool {
    const out = &s.out_info;
    const pre_w = out.width;
    const pre_h = out.height;
    const cur_w = s.in_info.width;
    const cur_h = s.in_info.height;
    out.* = s.in_info;
    const prev = s.texture_target;
    s.padded_width = out.width;
    s.padded_height = out.height;
    if (!modesEqual(s.mview_output_mode, s.in_info.ABI.abi.multiview_mode)) {
        c.gst_video_multiview_video_info_change_mode(out, s.mview_output_mode, s.mview_output_flags);
        if (s.convert_views == null) {
            s.convert_views = c.gst_gl_view_convert_new();
            c.gst_gl_view_convert_set_context(s.convert_views, s.context);
        }
    } else if (s.convert_views != null) {
        c.gst_object_unref(s.convert_views);
        s.convert_views = null;
    }
    const ret = configureDisplay(s, out);
    if (s.convert_views != null and s.display_rect.w > 0 and s.display_rect.h > 0) {
        const nw = s.display_rect.w;
        const nh = s.display_rect.h;
        if (nw != out.width or nh != out.height) {
            var fn_: c.gint = 0;
            var fd: c.gint = 0;
            var pn: c.gint = 0;
            var pd: c.gint = 0;
            if (c.gst_util_fraction_multiply(out.width, out.height, out.par_n, out.par_d, &fn_, &fd) == 0 or c.gst_util_fraction_multiply(fn_, fd, nh, nw, &pn, &pd) == 0) {
                pn = s.par_n;
                pd = s.par_d;
            }
            out.par_n = pn;
            out.par_d = pd;
            out.width = nw;
            out.height = nh;
        }
    }
    const st = c.gst_caps_get_structure(s.in_caps, 0);
    var target = c.gst_structure_get_string(st, "texture-target");
    if (target == null) target = "2D";
    s.texture_target = c.gst_gl_texture_target_from_string(target);
    if (s.texture_target == 0) return false;
    const caps = c.gst_video_info_to_caps(out);
    c.gst_caps_set_features(caps, 0, c.gst_caps_features_new_single_static_str(c.GST_CAPS_FEATURE_MEMORY_GL_MEMORY));
    c.gst_caps_set_simple(caps, "texture-target", c.G_TYPE_STRING, target, @as(?*anyopaque, null));
    if (s.convert_views != null) {
        c.gst_caps_set_simple(caps, "texture-target", c.G_TYPE_STRING, "2D", @as(?*anyopaque, null));
        s.texture_target = c.GST_GL_TEXTURE_TARGET_2D;
        unlock(s);
        _ = c.gst_gl_view_convert_set_caps(s.convert_views, s.in_caps, caps);
        c.g_object_set(s.convert_views, "downmix-mode", s.mview_downmix_mode, @as(?*anyopaque, null));
        lock(s);
    }
    if (s.out_caps != null) c.gst_caps_unref(s.out_caps);
    s.out_caps = caps;
    if ((pre_w != 0 and pre_w != cur_w) or (pre_h != 0 and pre_h != cur_h)) s.need_resize_window = 1;
    if (prev != c.GST_GL_TEXTURE_TARGET_NONE and s.texture_target != prev) {
        const window = c.gst_gl_context_get_window(s.context);
        c.gst_gl_window_send_message(window, cleanupTrampoline, s);
        c.gst_object_unref(window);
    }
    s.output_mode_changed = 0;
    if (s.context != null) {
        const window = c.gst_gl_context_get_window(s.context);
        if (window != null) {
            c.gst_gl_window_queue_resize(window);
            c.gst_object_unref(window);
        }
    }
    return ret;
}

fn setCaps(bs: [*c]c.GstBaseSink, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bs);
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    if (!ensureSetup(s)) return 0;
    lock(s);
    defer unlock(s);
    if (s.in_caps != null) c.gst_caps_unref(s.in_caps);
    s.in_caps = c.gst_caps_ref(caps);
    s.in_info = info;
    return @intFromBool(updateOutput(s));
}

fn isDiscont(b: [*c]c.GstBuffer) c.gboolean {
    return @intFromBool(b[0].mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0);
}

fn prepareNext(s: *Self) bool {
    if (s.input_buffer == null) return true;
    var in2: [*c]c.GstBuffer = null;
    if (s.in_info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_FRAME_BY_FRAME) {
        if (s.input_buffer2 == null) return true;
        in2 = c.gst_buffer_ref(s.input_buffer2);
    }
    const in = c.gst_buffer_ref(s.input_buffer);
    var conv: ?*c.GstGLViewConvert = null;
    if (s.convert_views != null and (s.in_info.ABI.abi.multiview_mode != s.out_info.ABI.abi.multiview_mode or s.in_info.ABI.abi.multiview_flags != s.out_info.ABI.abi.multiview_flags)) conv = @ptrCast(@alignCast(c.gst_object_ref(s.convert_views)));
    unlock(s);
    var next: [*c]c.GstBuffer = null;
    var next2: [*c]c.GstBuffer = null;
    var info: *c.GstVideoInfo = undefined;
    if (conv != null) {
        info = &s.out_info;
        var ok = c.gst_gl_view_convert_submit_input_buffer(s.convert_views, isDiscont(in), in) == c.GST_FLOW_OK;
        if (!ok) _ = c.gst_buffer_replace(&in2, null);
        if (ok and in2 != null) ok = c.gst_gl_view_convert_submit_input_buffer(s.convert_views, isDiscont(in2), in2) == c.GST_FLOW_OK;
        if (ok) ok = c.gst_gl_view_convert_get_output(s.convert_views, &next) == c.GST_FLOW_OK;
        if (ok and info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_FRAME_BY_FRAME) ok = c.gst_gl_view_convert_get_output(s.convert_views, &next2) == c.GST_FLOW_OK;
        c.gst_object_unref(conv);
        if (!ok) {
            lock(s);
            return false;
        }
        if (next == null) {
            lock(s);
            return true;
        }
    } else {
        next = in;
        info = &s.in_info;
    }
    if (s.overlay_compositor == null) {
        s.overlay_compositor = c.gst_gl_overlay_compositor_new(s.context);
        if (s.overlay_compositor == null) {
            c.gst_buffer_unref(next);
            lock(s);
            return false;
        }
    }
    c.gst_gl_overlay_compositor_upload_overlays(s.overlay_compositor, next);
    var sync: ?*c.GstGLSyncMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(next, c.gst_gl_sync_meta_api_get_type())));
    var next_sync: [*c]c.GstBuffer = null;
    if (sync == null) {
        next_sync = c.gst_buffer_new();
        sync = c.gst_buffer_add_gl_sync_meta(s.context, next_sync);
        c.gst_gl_sync_meta_set_sync_point(sync, s.context);
    }
    var frame: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&frame, info, next, c.GST_MAP_READ | c.GST_MAP_GL) == 0) {
        c.gst_buffer_unref(next);
        lock(s);
        return false;
    }
    lock(s);
    s.next_tex = @as(*align(1) const c.guint, @ptrCast(frame.data[0])).*;
    const old = s.next_buffer;
    s.next_buffer = next;
    const old2 = s.next_buffer2;
    s.next_buffer2 = next2;
    const old_sync = s.next_sync;
    s.next_sync = next_sync;
    s.next_sync_meta = sync;
    unlock(s);
    if (old != null) c.gst_buffer_unref(old);
    if (old2 != null) c.gst_buffer_unref(old2);
    if (old_sync != null) c.gst_buffer_unref(old_sync);
    c.gst_video_frame_unmap(&frame);
    lock(s);
    return true;
}

fn prepare(bs: [*c]c.GstBaseSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bs);
    if (s.video_sink.width < 1 or s.video_sink.height < 1) return c.GST_FLOW_NOT_NEGOTIATED;
    if (!ensureSetup(s)) return c.GST_FLOW_NOT_NEGOTIATED;
    const sync: ?*c.GstGLSyncMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_gl_sync_meta_api_get_type())));
    if (sync != null) c.gst_gl_sync_meta_wait(sync, s.context);
    lock(s);
    if (s.window_resized != 0) {
        s.window_resized = 0;
        unlock(s);
        _ = c.gst_pad_push_event(bs[0].sinkpad, c.gst_event_new_reconfigure());
        lock(s);
    }
    var target = &s.input_buffer;
    if (s.in_info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_FRAME_BY_FRAME and b[0].mini_object.flags & c.GST_VIDEO_BUFFER_FLAG_FIRST_IN_BUNDLE == 0) target = &s.input_buffer2;
    const old = target.*;
    target.* = c.gst_buffer_ref(b);
    if (s.output_mode_changed != 0) _ = updateOutput(s);
    if (!prepareNext(s)) {
        unlock(s);
        if (old != null) c.gst_buffer_unref(old);
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Failed to convert multiview video buffer"), null, FILE, "gst_glimage_sink_prepare", 1922);
        return c.GST_FLOW_ERROR;
    }
    unlock(s);
    if (old != null) c.gst_buffer_unref(old);
    if (s.window_id != s.new_window_id) {
        const window = c.gst_gl_context_get_window(s.context);
        s.window_id = s.new_window_id;
        c.gst_gl_window_set_window_handle(window, s.window_id);
        c.gst_object_unref(window);
    }
    return c.GST_FLOW_OK;
}

fn showFrame(vs: [*c]c.GstVideoSink, _: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(vs);
    if (!redisplay(s)) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Window redisplay failed"), null, FILE, "gst_glimage_sink_show_frame", 1960);
        return c.GST_FLOW_ERROR;
    }
    if (@atomicLoad(c.gint, &s.to_quit, .seq_cst) != 0) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Quit requested"), null, FILE, "gst_glimage_sink_show_frame", 1950);
        return c.GST_FLOW_ERROR;
    }
    return c.GST_FLOW_OK;
}

fn setWindowHandle(o: ?*c.GstVideoOverlay, id: c.guintptr) callconv(.c) void {
    if (!cm.that(c.g_type_check_instance_is_a(@ptrCast(@alignCast(o)), getType()) != 0, "gst_glimage_sink_set_window_handle", "GST_IS_GLIMAGE_SINK (overlay)")) return;
    me(o).new_window_id = id;
}

fn expose(o: ?*c.GstVideoOverlay) callconv(.c) void {
    const s = me(o);
    if (s.display == null) return;
    if (s.window_id != 0 and s.window_id != s.new_window_id) {
        const window = c.gst_gl_context_get_window(s.context);
        s.window_id = s.new_window_id;
        c.gst_gl_window_set_window_handle(window, s.window_id);
        c.gst_object_unref(window);
    }
    _ = redisplay(s);
}

fn handleEvents(o: ?*c.GstVideoOverlay, on: c.gboolean) callconv(.c) void {
    const s = me(o);
    s.handle_events = on;
    if (s.context != null) {
        const window = c.gst_gl_context_get_window(s.context);
        c.gst_gl_window_handle_events(window, on);
        c.gst_object_unref(window);
    }
}

fn setRenderRectangle(o: ?*c.GstVideoOverlay, x: c.gint, y: c.gint, w: c.gint, h: c.gint) callconv(.c) void {
    const s = me(o);
    if (s.context != null) {
        const window = c.gst_gl_context_get_window(s.context);
        _ = c.gst_gl_window_set_render_rectangle(window, x, y, w, h);
        c.gst_object_unref(window);
    }
    s.x = x;
    s.y = y;
    s.width = w;
    s.height = h;
}

fn overlayInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstVideoOverlayInterface = @ptrCast(@alignCast(iface));
    i.set_window_handle = setWindowHandle;
    i.set_render_rectangle = setRenderRectangle;
    i.handle_events = handleEvents;
    i.expose = expose;
}

fn proposeAllocation(bs: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bs);
    if (!ensureSetup(s)) return 0;
    lock(s);
    const ctx: ?*c.GstGLContext = if (s.context != null) @ptrCast(@alignCast(c.gst_object_ref(s.context))) else null;
    unlock(s);
    if (ctx == null) return 0;
    defer c.gst_object_unref(ctx);
    var caps: [*c]c.GstCaps = null;
    var need_pool: c.gboolean = 0;
    c.gst_query_parse_allocation(q, &caps, &need_pool);
    if (caps == null) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    const size: c.guint = @intCast(info.size);
    var pool: [*c]c.GstBufferPool = null;
    if (need_pool != 0) {
        pool = c.gst_gl_buffer_pool_new(ctx);
        const config = c.gst_buffer_pool_get_config(pool);
        c.gst_buffer_pool_config_set_params(config, caps, size, 0, 0);
        c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_GL_SYNC_META);
        if (c.gst_buffer_pool_set_config(pool, config) == 0) {
            c.g_object_unref(pool);
            return 0;
        }
    }
    c.gst_query_add_allocation_pool(q, pool, size, 2, 0);
    if (pool != null) c.g_object_unref(pool);
    const funcs: *c.GstGLFuncs = @ptrCast(@alignCast(ctx.?.gl_vtable));
    if (funcs.FenceSync != null) c.gst_query_add_allocation_meta(q, c.gst_gl_sync_meta_api_get_type(), null);
    var meta: ?*c.GstStructure = null;
    if (s.window_width != 0 and s.window_height != 0) meta = c.gst_structure_new("GstVideoOverlayCompositionMeta", "width", c.G_TYPE_UINT, s.window_width, "height", c.G_TYPE_UINT, s.window_height, @as(?*anyopaque, null));
    c.gst_query_add_allocation_meta(q, c.gst_video_overlay_composition_meta_api_get_type(), meta);
    c.gst_query_add_allocation_meta(q, c.gst_video_affine_transformation_meta_api_get_type(), null);
    if (meta != null) c.gst_structure_free(meta);
    return 1;
}

fn bind(s: *Self) void {
    const g = gl(s);
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.vertex_buffer);
    g.VertexAttribPointer.?(@bitCast(s.attr_position), 3, c.GL_FLOAT, c.GL_FALSE, 20, null);
    g.VertexAttribPointer.?(@bitCast(s.attr_texture), 2, c.GL_FLOAT, c.GL_FALSE, 20, @ptrFromInt(12));
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

fn initRedisplay(data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const g = gl(s);
    const vert = c.gst_glsl_stage_new_with_string(s.context, c.GL_VERTEX_SHADER, c.GST_GLSL_VERSION_NONE, PROFILE, c.gst_gl_shader_string_vertex_mat4_vertex_transform);
    var frag: ?*c.GstGLSLStage = null;
    if (s.texture_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) {
        const str = c.gst_gl_shader_string_fragment_external_oes_get_default(s.context, c.GST_GLSL_VERSION_NONE, PROFILE);
        frag = c.gst_glsl_stage_new_with_string(s.context, c.GL_FRAGMENT_SHADER, c.GST_GLSL_VERSION_NONE, PROFILE, str);
        c.g_free(str);
    } else frag = c.gst_glsl_stage_new_default_fragment(s.context);
    if (vert == null or frag == null) {
        if (vert != null) c.gst_object_unref(vert);
        if (frag != null) c.gst_object_unref(frag);
        cleanupGlthread(s);
        return;
    }
    var err: [*c]c.GError = null;
    s.redisplay_shader = c.gst_gl_shader_new_link_with_stages(s.context, &err, vert, frag, @as(?*anyopaque, null));
    if (s.redisplay_shader == null) {
        c.g_clear_error(&err);
        cleanupGlthread(s);
        return;
    }
    s.attr_position = c.gst_gl_shader_get_attribute_location(s.redisplay_shader, "a_position");
    s.attr_texture = c.gst_gl_shader_get_attribute_location(s.redisplay_shader, "a_texcoord");
    const vao = g.GenVertexArrays != null;
    if (vao) {
        g.GenVertexArrays.?(1, &s.vao);
        g.BindVertexArray.?(s.vao);
    }
    if (s.vertex_buffer == 0) {
        g.GenBuffers.?(1, &s.vertex_buffer);
        g.BindBuffer.?(c.GL_ARRAY_BUFFER, s.vertex_buffer);
        g.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_STATIC_DRAW);
    }
    if (s.vbo_indices == 0) {
        g.GenBuffers.?(1, &s.vbo_indices);
        g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, s.vbo_indices);
        g.BufferData.?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, c.GL_STATIC_DRAW);
    }
    if (vao) {
        bind(s);
        g.BindVertexArray.?(0);
    }
    g.BindBuffer.?(c.GL_ELEMENT_ARRAY_BUFFER, 0);
    g.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
}

fn cleanupGlthread(s: *Self) void {
    const g = gl(s);
    if (s.redisplay_shader != null) c.gst_object_unref(s.redisplay_shader);
    s.redisplay_shader = null;
    if (s.vao != 0) g.DeleteVertexArrays.?(1, &s.vao);
    s.vao = 0;
    if (s.vertex_buffer != 0) g.DeleteBuffers.?(1, &s.vertex_buffer);
    s.vertex_buffer = 0;
    if (s.vbo_indices != 0) g.DeleteBuffers.?(1, &s.vbo_indices);
    s.vbo_indices = 0;
    if (s.overlay_compositor != null) c.gst_gl_overlay_compositor_free_overlays(s.overlay_compositor);
}

fn onResize(s: *Self, width: c.gint, height: c.gint) callconv(.c) void {
    var reshape: c.gboolean = 0;
    c.g_signal_emit(s, sig_reshape, 0, s.context, width, height, &reshape);
    lock(s);
    defer unlock(s);
    const g = gl(s);
    const w: c.guint = @intCast(@max(1, width));
    const h: c.guint = @intCast(@max(1, height));
    s.window_resized = @intFromBool((s.window_width != w or s.window_height != h) and s.window_width != 0 and s.window_height != 0);
    s.window_width = w;
    s.window_height = h;
    c.gst_gl_insert_debug_marker(s.context, "%s window resize to %ix%i", el.padName(s), w, h);
    if (reshape == 0) {
        if (s.keep_aspect_ratio != 0) {
            var src = c.GstVideoRectangle{ .x = 0, .y = 0, .w = 0, .h = 0 };
            const r = s.current_rotate_method;
            if (r == c.GST_VIDEO_ORIENTATION_90R or r == c.GST_VIDEO_ORIENTATION_90L or r == c.GST_VIDEO_ORIENTATION_UL_LR or r == c.GST_VIDEO_ORIENTATION_UR_LL) {
                src.h = s.video_sink.width;
                src.w = s.video_sink.height;
            } else {
                src.w = s.video_sink.width;
                src.h = s.video_sink.height;
            }
            src.w = @max(1, src.w);
            src.h = @max(1, src.h);
            const dst = c.GstVideoRectangle{ .x = 0, .y = 0, .w = @bitCast(w), .h = @bitCast(h) };
            var res: c.GstVideoRectangle = undefined;
            c.gst_video_sink_center_rect(src, dst, &res, 1);
            if (res.w != s.display_rect.w or res.h != s.display_rect.h) s.output_mode_changed = 1;
            s.display_rect = res;
        } else {
            if (@as(c.gint, @bitCast(w)) != s.display_rect.w or @as(c.gint, @bitCast(h)) != s.display_rect.h) s.output_mode_changed = 1;
            s.display_rect = .{ .x = 0, .y = 0, .w = @bitCast(w), .h = @bitCast(h) };
        }
        g.Viewport.?(s.display_rect.x, s.display_rect.y, s.display_rect.w, s.display_rect.h);
    } else {
        var dims: [4]c.GLint = undefined;
        g.GetIntegerv.?(c.GL_VIEWPORT, &dims);
        s.display_rect = .{ .x = dims[0], .y = dims[1], .w = dims[2], .h = dims[3] };
    }
}

fn onDrawWindow(s: *Self) callconv(.c) void {
    if (!cm.that(c.g_type_check_instance_is_a(@ptrCast(@alignCast(s)), getType()) != 0, "gst_glimage_sink_on_draw", "GST_IS_GLIMAGE_SINK (gl_sink)")) return;
    const target = c.gst_gl_texture_target_to_gl(s.texture_target);
    lock(s);
    defer unlock(s);
    const g = gl(s);
    if (s.redisplay_texture == 0) return;
    const window = c.gst_gl_context_get_window(s.context);
    window[0].is_drawing = 1;
    c.gst_gl_insert_debug_marker(s.context, "%s element drawing texture %u", el.padName(s), s.redisplay_texture);
    if (s.stored_sync_meta != null) c.gst_gl_sync_meta_wait(s.stored_sync_meta, c.gst_gl_context_get_current());
    c.gst_gl_context_clear_shader(s.context);
    g.BindTexture.?(target, 0);
    if (c.gst_gl_window_controls_viewport(window) == 0) g.Viewport.?(s.display_rect.x, s.display_rect.y, s.display_rect.w, s.display_rect.h);
    const segment = &@as(*c.GstBaseSink, @ptrCast(@alignCast(s))).segment;
    var redraw: c.gboolean = 0;
    var sample = c.gst_sample_new(s.stored_buffer[0], s.out_caps, segment, null);
    c.g_signal_emit(s, sig_draw, 0, s.context, sample, &redraw);
    c.gst_sample_unref(sample);
    if (s.stored_buffer[1] != null) {
        sample = c.gst_sample_new(s.stored_buffer[1], s.out_caps, segment, null);
        c.g_signal_emit(s, sig_draw, 0, s.context, sample, &redraw);
        c.gst_sample_unref(sample);
    }
    if (redraw == 0) {
        const alpha: f32 = if (s.ignore_alpha != 0) 1 else 0;
        g.ClearColor.?(0, 0, 0, alpha);
        g.Clear.?(c.GL_COLOR_BUFFER_BIT);
        if (s.ignore_alpha != 0) {
            g.BlendColor.?(0, 0, 0, alpha);
            if (g.BlendFuncSeparate) |f| f(c.GL_SRC_ALPHA, c.GL_CONSTANT_COLOR, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA) else g.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_CONSTANT_COLOR);
            g.BlendEquation.?(c.GL_FUNC_ADD);
            g.Enable.?(c.GL_BLEND);
        }
        c.gst_gl_shader_use(s.redisplay_shader);
        if (g.GenVertexArrays != null) g.BindVertexArray.?(s.vao);
        bind(s);
        g.ActiveTexture.?(c.GL_TEXTURE0);
        g.BindTexture.?(target, s.redisplay_texture);
        c.gst_gl_shader_set_uniform_1i(s.redisplay_shader, "tex", 0);
        const vm: [*c]c.GstVideoMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(s.stored_buffer[0], c.gst_video_meta_api_get_type())));
        if (vm != null and (vm[0].width != @as(c.guint, @bitCast(s.padded_width)) or vm[0].height != @as(c.guint, @bitCast(s.padded_height)))) {
            const sx: f32 = @floatCast(@as(f64, @floatFromInt(s.out_info.width)) / @as(f64, @floatFromInt(vm[0].width)));
            const sy: f32 = @floatCast(@as(f64, @floatFromInt(s.out_info.height)) / @as(f64, @floatFromInt(vm[0].height)));
            const crop = [_]f32{ 1, 1, 0, sx, 0, -1, 1, 0, 0, 0, -1, -1, 0, 0, sy, 1, -1, 0, sx, sy };
            g.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(crop)), &crop, c.GL_STATIC_DRAW);
            s.padded_width = @bitCast(vm[0].width);
            s.padded_height = @bitCast(vm[0].height);
        }
        var m: [16]f32 = undefined;
        const af: [*c]c.GstVideoAffineTransformationMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(s.stored_buffer[0], c.gst_video_affine_transformation_meta_api_get_type())));
        c.gst_gl_get_affine_transformation_meta_as_ndc(af, &m);
        if (s.transform_matrix) |t| c.gst_gl_multiply_matrix4(&m, t, &m);
        c.gst_gl_shader_set_uniform_matrix_4fv(s.redisplay_shader, "u_transformation", 1, 0, &m);
        g.DrawElements.?(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
        g.BindTexture.?(target, 0);
        c.gst_gl_context_clear_shader(s.context);
        if (g.GenVertexArrays != null) g.BindVertexArray.?(0) else unbind(s);
        if (s.ignore_alpha != 0) g.Disable.?(c.GL_BLEND);
        c.gst_gl_overlay_compositor_draw_overlays(s.overlay_compositor);
    }
    window[0].is_drawing = 0;
    c.gst_object_unref(window);
}

fn onClose(s: *Self) callconv(.c) void {
    lock(s);
    const window: ?*c.GstGLWindow = if (s.context != null) c.gst_gl_context_get_window(s.context) else null;
    unlock(s);
    if (window != null) {
        disconnect(window, &s.key_sig_id);
        disconnect(window, &s.mouse_sig_id);
        disconnect(window, &s.mouse_scroll_sig_id);
        c.gst_object_unref(window);
    }
    @atomicStore(c.gint, &s.to_quit, 1, .seq_cst);
}

fn redisplayInitTrampoline(data: c.gpointer) callconv(.c) void {
    initRedisplay(data);
}

fn redisplay(s: *Self) bool {
    var resize = s.need_resize_window != 0;
    const window = c.gst_gl_context_get_window(s.context) orelse return false;
    defer c.gst_object_unref(window);
    const handler = c.g_signal_handler_find(@as(*c.GstObject, @ptrCast(@alignCast(s))).parent, c.G_SIGNAL_MATCH_ID, bin_sig_draw, 0, null, null, null);
    if (s.redisplay_shader == null and (handler == 0 or s.other_context == null)) {
        c.gst_gl_window_send_message(window, redisplayInitTrampoline, s);
        if (s.redisplay_shader == null) return false;
        resize = true;
    }
    if (resize) {
        s.need_resize_window = 0;
        c.gst_gl_window_set_preferred_size(window, s.video_sink.width, s.video_sink.height);
        c.gst_gl_window_show(window);
    }
    lock(s);
    if (s.window_resized != 0) {
        s.window_resized = 0;
        unlock(s);
        _ = c.gst_pad_push_event(sinkpad(s), c.gst_event_new_reconfigure());
        lock(s);
    }
    if (s.output_mode_changed != 0 and s.input_buffer != null) {
        _ = updateOutput(s);
        _ = prepareNext(s);
    }
    if (s.next_buffer == null) {
        unlock(s);
        return true;
    }
    s.redisplay_texture = s.next_tex;
    var old = s.stored_buffer;
    s.stored_buffer[0] = c.gst_buffer_ref(s.next_buffer);
    s.stored_buffer[1] = if (s.next_buffer2 != null) c.gst_buffer_ref(s.next_buffer2) else null;
    const old_sync = s.stored_sync;
    s.stored_sync = if (s.next_sync != null) c.gst_buffer_ref(s.next_sync) else null;
    s.stored_sync_meta = s.next_sync_meta;
    unlock(s);
    _ = c.gst_buffer_replace(&old[0], null);
    _ = c.gst_buffer_replace(&old[1], null);
    if (old_sync != null) c.gst_buffer_unref(old_sync);
    c.gst_gl_window_draw(window);
    return true;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_bs = el.parentOf(c.GstBaseSinkClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    installCommon(oc, @intFromEnum(Prop.rotate_method), @intFromEnum(Prop.force_aspect_ratio), @intFromEnum(Prop.pixel_aspect_ratio), @intFromEnum(Prop.context), @intFromEnum(Prop.handle_events), @intFromEnum(Prop.ignore_alpha));
    installMview(oc, @intFromEnum(Prop.mview_layout), @intFromEnum(Prop.mview_flags), @intFromEnum(Prop.mview_downmix));
    _ = c.gst_video_overlay_install_properties(oc, @intFromEnum(Prop.last));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "OpenGL video sink", "Sink/Video", "A videosink based on OpenGL", "Julien Isorce <julien.isorce@gmail.com>");
    sig_draw = c.g_signal_new("client-draw", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_BOOLEAN, 2, c.gst_gl_context_get_type(), c.gst_sample_get_type());
    sig_reshape = c.g_signal_new("client-reshape", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_BOOLEAN, 3, c.gst_gl_context_get_type(), c.G_TYPE_UINT, c.G_TYPE_UINT);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    oc.finalize = finalize;
    ec.change_state = changeState;
    ec.set_context = setContext;
    const bs: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bs.event = event;
    bs.query = query;
    bs.set_caps = setCaps;
    bs.get_caps = getCaps;
    bs.get_times = getTimes;
    bs.prepare = prepare;
    bs.propose_allocation = proposeAllocation;
    const vs: *c.GstVideoSinkClass = @ptrCast(@alignCast(k));
    vs.show_frame = showFrame;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.keep_aspect_ratio = 1;
    s.par_n = 0;
    s.par_d = 1;
    s.handle_events = 1;
    s.ignore_alpha = 1;
    s.mview_output_mode = c.GST_VIDEO_MULTIVIEW_MODE_MONO;
    s.mview_output_flags = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE;
    s.mview_downmix_mode = c.GST_GL_STEREO_DOWNMIX_ANAGLYPH_GREEN_MAGENTA_DUBOIS;
    s.current_rotate_method = c.GST_VIDEO_ORIENTATION_IDENTITY;
    c.g_mutex_init(&s.drawing_lock);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_video_sink_get_type(), "GstGLImageSink", Class, Self, classInit, init);
            const ov = c.GInterfaceInfo{ .interface_init = overlayInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_video_overlay_get_type(), &ov);
            const nav = c.GInterfaceInfo{ .interface_init = navInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_navigation_get_type(), &nav);
            _ = c._gst_debug_category_new("glimagesink", 0, "OpenGL Video Sink");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    const a = el.register(p, "glimagesink", c.GST_RANK_SECONDARY, binType());
    const b = el.register(p, "glimagesinkelement", c.GST_RANK_NONE, getType());
    return a or b;
}
