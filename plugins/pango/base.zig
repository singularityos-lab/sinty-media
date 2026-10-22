const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pc = @import("pc.zig").p;

const FILE = "../ext/pango/gstbasetextoverlay.c";
const NONE = std.math.maxInt(u64);
const SIZE = "(int) [ 1, max ]";
const FPS = "(fraction) [ 0, max ]";
const CTL = cm.RW | c.GST_PARAM_CONTROLLABLE;
const COMPOSITION = "meta:GstVideoOverlayComposition";
const SCALE = 1024;
const BOX_PAD = 6;

pub fn capsMake(comptime features: []const u8, comptime formats: []const u8) [:0]const u8 {
    const head = if (features.len == 0) "video/x-raw" else "video/x-raw(" ++ features ++ ")";
    return head ++ ", format = (string) " ++ formats ++ ", width = " ++ SIZE ++ ", height = " ++ SIZE ++ ", framerate = " ++ FPS;
}

const SW_CAPS = capsMake("", c.GST_VIDEO_OVERLAY_COMPOSITION_BLEND_FORMATS);
const ALL_CAPS = SW_CAPS ++ ";" ++ capsMake("ANY", c.GST_VIDEO_FORMATS_ALL);

pub const VAlign = enum(c.gint) { baseline, bottom, top, pos, center, absolute };
pub const HAlign = enum(c.gint) { left, center, right, unused, pos, absolute };

const Prop = enum(c.guint) { text = 1, shading, shading_value, halignment, valignment, xpad, ypad, deltax, deltay, xpos, ypos, x_absolute, y_absolute, wrap_mode, font_desc, silent, line_alignment, wait_text, auto_adjust_size, vertical_render, scale_mode, scale_par, color, draw_shadow, draw_outline, outline_color, text_x, text_y, text_width, text_height, alt_render };

pub const Rect = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub const Self = extern struct {
    element: c.GstElement,
    video_sinkpad: ?*c.GstPad,
    text_sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    pango_context: ?*pc.PangoContext,
    segment: c.GstSegment,
    text_segment: c.GstSegment,
    text_buffer: [*c]c.GstBuffer,
    text_buffer_running_time: c.GstClockTime,
    text_buffer_running_time_end: c.GstClockTime,
    text_linked: c.gboolean,
    video_flushing: c.gboolean,
    video_eos: c.gboolean,
    text_flushing: c.gboolean,
    text_eos: c.gboolean,
    lock: c.GMutex,
    cond: c.GCond,
    info: c.GstVideoInfo,
    format: c.GstVideoFormat,
    width: c.gint,
    height: c.gint,
    xpad: c.gint,
    ypad: c.gint,
    deltax: c.gint,
    deltay: c.gint,
    xpos: f64,
    ypos: f64,
    default_text: [*c]u8,
    want_shading: c.gboolean,
    silent: c.gboolean,
    wait_text: c.gboolean,
    color: c.guint,
    outline_color: c.guint,
    layout: ?*pc.PangoLayout,
    auto_adjust_size: c.gboolean,
    draw_shadow: c.gboolean,
    draw_outline: c.gboolean,
    shading_value: c.gint,
    use_vertical_render: c.gboolean,
    valign: c.gint,
    halign: c.gint,
    wrap_mode: c.gint,
    line_align: c.gint,
    scale_mode: c.gint,
    scale_par_n: c.gint,
    scale_par_d: c.gint,
    alt_render: c.gboolean,
    have_pango_markup: c.gboolean,
    need_render: c.gboolean,
    text_image: [*c]c.GstBuffer,
    render_width: c.gint,
    render_height: c.gint,
    render_scale: f64,
    text_width: c.guint,
    text_height: c.guint,
    text_x: c.gint,
    text_y: c.gint,
    window_width: c.gint,
    window_height: c.gint,
    shadow_offset: f64,
    outline_offset: f64,
    ink_rect: Rect,
    logical_rect: Rect,
    attach_compo_to_buffer: c.gboolean,
    composition: ?*c.GstVideoOverlayComposition,
};

pub const Class = extern struct {
    parent: c.GstElementClass,
    get_text: ?*const fn (*Self, [*c]c.GstBuffer) callconv(.c) [*c]u8,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, ALL_CAPS);
var video_t = cm.staticTemplate("video_sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, ALL_CAPS);
var sw_caps = c.GstStaticCaps{ .caps = null, .string = SW_CAPS.ptr, ._gst_reserved = .{null} ** 4 };
var once: cm.Once = .{};
var valign_once: cm.Once = .{};
var halign_once: cm.Once = .{};
var wrap_once: cm.Once = .{};
var line_once: cm.Once = .{};
var scale_once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var alt_idx: c.gint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn klass(s: *Self) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(s))).g_class));
}

pub fn lock(s: *Self) void {
    c.g_mutex_lock(&s.lock);
}

pub fn unlock(s: *Self) void {
    c.g_mutex_unlock(&s.lock);
}

fn broadcast(s: *Self) void {
    c.g_cond_broadcast(&s.cond);
}

fn enumType(o: *cm.Once, comptime name: [:0]const u8, comptime vals: []const struct { c.gint, [:0]const u8, [:0]const u8 }) c.GType {
    const S = struct {
        var values = blk: {
            var v: [vals.len + 1]c.GEnumValue = undefined;
            for (vals, 0..) |x, i| v[i] = .{ .value = x[0], .value_name = x[1], .value_nick = x[2] };
            v[vals.len] = .{ .value = 0, .value_name = null, .value_nick = null };
            break :blk v;
        };
        fn f() c.GType {
            return c.g_enum_register_static(name, &values);
        }
    };
    return o.get(S.f);
}

fn valignType() c.GType {
    return enumType(&valign_once, "GstBaseTextOverlayVAlign", &.{ .{ 0, "baseline", "baseline" }, .{ 1, "bottom", "bottom" }, .{ 2, "top", "top" }, .{ 3, "position", "Absolute position clamped to canvas" }, .{ 4, "center", "center" }, .{ 5, "absolute", "Absolute position" } });
}

fn halignType() c.GType {
    return enumType(&halign_once, "GstBaseTextOverlayHAlign", &.{ .{ 0, "left", "left" }, .{ 1, "center", "center" }, .{ 2, "right", "right" }, .{ 4, "position", "Absolute position clamped to canvas" }, .{ 5, "absolute", "Absolute position" } });
}

fn wrapType() c.GType {
    return enumType(&wrap_once, "GstBaseTextOverlayWrapMode", &.{ .{ -1, "none", "none" }, .{ pc.PANGO_WRAP_WORD, "word", "word" }, .{ pc.PANGO_WRAP_CHAR, "char", "char" }, .{ pc.PANGO_WRAP_WORD_CHAR, "wordchar", "wordchar" } });
}

fn lineType() c.GType {
    return enumType(&line_once, "GstBaseTextOverlayLineAlign", &.{ .{ pc.PANGO_ALIGN_LEFT, "left", "left" }, .{ pc.PANGO_ALIGN_CENTER, "center", "center" }, .{ pc.PANGO_ALIGN_RIGHT, "right", "right" } });
}

fn scaleType() c.GType {
    return enumType(&scale_once, "GstBaseTextOverlayScaleMode", &.{ .{ 0, "none", "none" }, .{ 1, "par", "par" }, .{ 2, "display", "display" }, .{ 3, "user", "user" } });
}

fn defaultText(s: *Self, _: [*c]c.GstBuffer) callconv(.c) [*c]u8 {
    return c.g_strdup(s.default_text);
}

fn install(oc: *c.GObjectClass, id: Prop, spec: [*c]c.GParamSpec) void {
    c.g_object_class_install_property(oc, @intFromEnum(id), spec);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    _ = c._gst_debug_category_new("basetextoverlay", 0, "Base Text Overlay");
    parent_el = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    parent_obj = @ptrCast(@alignCast(parent_el));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &video_t);
    ec.change_state = changeState;
    @as(*Class, @ptrCast(@alignCast(k))).get_text = defaultText;
    const maxi = std.math.maxInt(c.gint);
    const mini = std.math.minInt(c.gint);
    const maxd = std.math.floatMax(f64);
    install(oc, .text, c.g_param_spec_string("text", "text", "Text to be display.", "", CTL));
    install(oc, .shading, c.g_param_spec_boolean("shaded-background", "shaded background", "Whether to shade the background under the text area", 0, cm.RW));
    install(oc, .shading_value, c.g_param_spec_uint("shading-value", "background shading value", "Shading value to apply if shaded-background is true", 1, 255, 80, cm.RW | c.GST_PARAM_DOC_SHOW_DEFAULT));
    install(oc, .valignment, c.g_param_spec_enum("valignment", "vertical alignment", "Vertical alignment of the text", valignType(), 0, cm.RW));
    install(oc, .halignment, c.g_param_spec_enum("halignment", "horizontal alignment", "Horizontal alignment of the text", halignType(), 1, cm.RW | c.GST_PARAM_DOC_SHOW_DEFAULT));
    install(oc, .xpad, c.g_param_spec_int("xpad", "horizontal paddding", "Horizontal paddding when using left/right alignment", 0, maxi, 25, cm.RW));
    install(oc, .ypad, c.g_param_spec_int("ypad", "vertical padding", "Vertical padding when using top/bottom alignment", 0, maxi, 25, cm.RW));
    install(oc, .deltax, c.g_param_spec_int("deltax", "X position modifier", "Shift X position to the left or to the right. Unit is pixels.", mini, maxi, 0, CTL));
    install(oc, .deltay, c.g_param_spec_int("deltay", "Y position modifier", "Shift Y position up or down. Unit is pixels.", mini, maxi, 0, CTL));
    install(oc, .text_x, c.g_param_spec_int("text-x", "horizontal position.", "Resulting X position of font rendering.", -maxi, maxi, 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    install(oc, .text_y, c.g_param_spec_int("text-y", "vertical position", "Resulting Y position of font rendering.", -maxi, maxi, 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    install(oc, .text_width, c.g_param_spec_uint("text-width", "width", "Resulting width of font rendering", 0, maxi, 1, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    install(oc, .text_height, c.g_param_spec_uint("text-height", "height", "Resulting height of font rendering", 0, maxi, 1, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    install(oc, .xpos, c.g_param_spec_double("xpos", "horizontal position", "Horizontal position when using clamped position alignment", 0, 1, 0.5, CTL));
    install(oc, .ypos, c.g_param_spec_double("ypos", "vertical position", "Vertical position when using clamped position alignment", 0, 1, 0.5, CTL));
    install(oc, .x_absolute, c.g_param_spec_double("x-absolute", "horizontal position", "Horizontal position when using absolute alignment", -maxd, maxd, 0.5, CTL));
    install(oc, .y_absolute, c.g_param_spec_double("y-absolute", "vertical position", "Vertical position when using absolute alignment", -maxd, maxd, 0.5, CTL));
    install(oc, .wrap_mode, c.g_param_spec_enum("wrap-mode", "wrap mode", "Whether to wrap the text and if so how.", wrapType(), pc.PANGO_WRAP_WORD_CHAR, cm.RW));
    install(oc, .font_desc, c.g_param_spec_string("font-desc", "font description", "Pango font description of font to be used for rendering. See documentation of pango_font_description_from_string for syntax.", "", cm.RW));
    install(oc, .color, c.g_param_spec_uint("color", "Color", "Color to use for text (big-endian ARGB).", 0, std.math.maxInt(u32), 0xffffffff, CTL));
    install(oc, .outline_color, c.g_param_spec_uint("outline-color", "Text Outline Color", "Color to use for outline the text (big-endian ARGB).", 0, std.math.maxInt(u32), 0xff000000, CTL));
    install(oc, .line_alignment, c.g_param_spec_enum("line-alignment", "line alignment", "Alignment of text lines relative to each other.", lineType(), pc.PANGO_ALIGN_CENTER, cm.RW));
    install(oc, .silent, c.g_param_spec_boolean("silent", "silent", "Whether to render the text string", 0, CTL));
    install(oc, .draw_shadow, c.g_param_spec_boolean("draw-shadow", "draw-shadow", "Whether to draw shadow", 1, cm.RW));
    install(oc, .draw_outline, c.g_param_spec_boolean("draw-outline", "draw-outline", "Whether to draw outline", 1, cm.RW));
    install(oc, .wait_text, c.g_param_spec_boolean("wait-text", "Wait Text", "Whether to wait for subtitles", 1, cm.RW));
    install(oc, .auto_adjust_size, c.g_param_spec_boolean("auto-resize", "auto resize", "Automatically adjust font size to screen-size.", 1, cm.RW));
    install(oc, .vertical_render, c.g_param_spec_boolean("vertical-render", "vertical render", "Vertical Render.", 0, cm.RW));
    install(oc, .scale_mode, c.g_param_spec_enum("scale-mode", "scale mode", "Scale text to compensate for and avoid distortion by subsequent video scaling.", scaleType(), 0, cm.RW));
    install(oc, .scale_par, c.gst_param_spec_fraction("scale-pixel-aspect-ratio", "scale pixel aspect ratio", "Pixel aspect ratio of video scale to compensate for in user scale-mode", 1, 100, 100, 1, 1, 1, cm.RW));
    install(oc, .alt_render, c.g_param_spec_boolean("response-time-compensation", "Display Response Time Compensation", "Render twice in a moving pattern to mitigate display response time causing ghosting", 0, cm.RW));
    c.gst_type_mark_as_plugin_api(halignType(), 0);
    c.gst_type_mark_as_plugin_api(valignType(), 0);
    c.gst_type_mark_as_plugin_api(lineType(), 0);
    c.gst_type_mark_as_plugin_api(scaleType(), 0);
    c.gst_type_mark_as_plugin_api(wrapType(), 0);
    c.gst_type_mark_as_plugin_api(getType(), 0);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.default_text);
    if (s.composition != null) c.gst_mini_object_unref(@ptrCast(@alignCast(s.composition)));
    s.composition = null;
    if (s.text_image != null) c.gst_buffer_unref(s.text_image);
    s.text_image = null;
    if (s.layout != null) pc.g_object_unref(s.layout);
    s.layout = null;
    if (s.text_buffer != null) c.gst_buffer_unref(s.text_buffer);
    s.text_buffer = null;
    if (s.pango_context != null) pc.g_object_unref(s.pango_context);
    s.pango_context = null;
    c.g_mutex_clear(&s.lock);
    c.g_cond_clear(&s.cond);
    parent_obj.finalize.?(o);
}

fn adjustFont(s: *Self, desc: ?*const pc.PangoFontDescription) void {
    const size = @divTrunc(pc.pango_font_description_get_size(desc), SCALE);
    s.shadow_offset = @as(f64, @floatFromInt(size)) / 13.0;
    s.outline_offset = @as(f64, @floatFromInt(size)) / 15.0;
    if (s.outline_offset < 1.0) s.outline_offset = 1.0;
}

fn init(inst: [*c]c.GTypeInstance, k: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const fontmap = pc.pango_cairo_font_map_new();
    s.pango_context = pc.pango_font_map_create_context(fontmap);
    pc.g_object_unref(fontmap);
    pc.pango_context_set_base_gravity(s.pango_context, pc.PANGO_GRAVITY_SOUTH);
    var t = c.gst_static_pad_template_get(&video_t);
    s.video_sinkpad = c.gst_pad_new_from_template(t, "video_sink");
    c.gst_object_unref(t);
    c.gst_pad_set_event_function_full(s.video_sinkpad, videoEvent, null, null);
    c.gst_pad_set_chain_function_full(s.video_sinkpad, videoChain, null, null);
    c.gst_pad_set_query_function_full(s.video_sinkpad, videoQuery, null, null);
    @as(*c.GstObject, @ptrCast(@alignCast(s.video_sinkpad))).flags |= c.GST_PAD_FLAG_PROXY_ALLOCATION;
    _ = c.gst_element_add_pad(@ptrCast(s), s.video_sinkpad);
    t = c.gst_element_class_get_pad_template(@ptrCast(@alignCast(k)), "text_sink");
    if (t != null) {
        s.text_sinkpad = c.gst_pad_new_from_template(t, "text_sink");
        c.gst_pad_set_event_function_full(s.text_sinkpad, textEvent, null, null);
        c.gst_pad_set_chain_function_full(s.text_sinkpad, textChain, null, null);
        c.gst_pad_set_link_function_full(s.text_sinkpad, textLink, null, null);
        c.gst_pad_set_unlink_function_full(s.text_sinkpad, textUnlink, null, null);
        _ = c.gst_element_add_pad(@ptrCast(s), s.text_sinkpad);
    }
    t = c.gst_static_pad_template_get(&src_t);
    s.srcpad = c.gst_pad_new_from_template(t, "src");
    c.gst_object_unref(t);
    c.gst_pad_set_event_function_full(s.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(s.srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
    s.layout = pc.pango_layout_new(s.pango_context);
    adjustFont(s, pc.pango_context_get_font_description(s.pango_context));
    s.color = 0xffffffff;
    s.outline_color = 0xff000000;
    s.halign = @intFromEnum(HAlign.center);
    s.valign = @intFromEnum(VAlign.baseline);
    s.xpad = 25;
    s.ypad = 25;
    s.xpos = 0.5;
    s.ypos = 0.5;
    s.wrap_mode = pc.PANGO_WRAP_WORD_CHAR;
    s.shading_value = 80;
    s.draw_shadow = 1;
    s.draw_outline = 1;
    s.wait_text = 1;
    s.auto_adjust_size = 1;
    s.default_text = c.g_strdup("");
    s.need_render = 1;
    s.scale_par_n = 1;
    s.scale_par_d = 1;
    s.line_align = pc.PANGO_ALIGN_CENTER;
    pc.pango_layout_set_alignment(s.layout, @intCast(s.line_align));
    s.text_buffer_running_time = NONE;
    s.text_buffer_running_time_end = NONE;
    s.width = 1;
    s.height = 1;
    s.window_width = 1;
    s.window_height = 1;
    s.text_width = 1;
    s.text_height = 1;
    s.render_width = 1;
    s.render_height = 1;
    s.render_scale = 1.0;
    c.g_mutex_init(&s.lock);
    c.g_cond_init(&s.cond);
    c.gst_segment_init(&s.segment, c.GST_FORMAT_TIME);
}

fn setWrapMode(s: *Self, width: c.gint) void {
    if (s.wrap_mode == -1) {
        pc.pango_layout_set_width(s.layout, -1);
    } else pc.pango_layout_set_width(s.layout, width *% SCALE);
    pc.pango_layout_set_wrap(s.layout, @bitCast(s.wrap_mode));
}

fn setcapsText(s: *Self, caps: [*c]c.GstCaps) bool {
    const st = c.gst_caps_get_structure(caps, 0);
    const format = c.gst_structure_get_string(st, "format");
    s.have_pango_markup = @intFromBool(std.mem.orderZ(u8, format, "pango-markup") == .eq);
    return true;
}

fn canHandle(caps: [*c]c.GstCaps) bool {
    const sw = c.gst_static_caps_get(&sw_caps);
    const ok = c.gst_caps_is_subset(caps, sw) != 0;
    c.gst_caps_unref(sw);
    return ok;
}

fn setSrcCaps(s: *Self, caps: [*c]c.GstCaps) bool {
    return c.gst_pad_push_event(s.srcpad, c.gst_event_new_caps(caps)) != 0;
}

fn negotiate(s: *Self, caps_in: [*c]c.GstCaps) bool {
    _ = c.gst_pad_check_reconfigure(s.srcpad);
    const caps = if (caps_in == null) c.gst_pad_get_current_caps(s.video_sinkpad) else c.gst_caps_ref(caps_in);
    if (caps == null or c.gst_caps_is_empty(caps) != 0) {
        if (caps != null) c.gst_caps_unref(caps);
        c.gst_pad_mark_reconfigure(s.srcpad);
        return false;
    }
    var upstream_meta = false;
    var caps_meta = false;
    var alloc_meta = false;
    var ret = true;
    const f = c.gst_caps_get_features(caps, 0);
    if (f != null) upstream_meta = c.gst_caps_features_contains(f, COMPOSITION) != 0;
    var width: c.guint = @bitCast(s.width);
    var height: c.guint = @bitCast(s.height);
    var overlay_caps: [*c]c.GstCaps = undefined;
    if (upstream_meta) {
        overlay_caps = c.gst_caps_ref(caps);
    } else {
        overlay_caps = c.gst_caps_copy(caps);
        c.gst_caps_features_add(c.gst_caps_get_features(overlay_caps, 0), COMPOSITION);
        const peer = c.gst_pad_peer_query_caps(s.srcpad, overlay_caps);
        caps_meta = c.gst_caps_is_empty(peer) == 0;
        c.gst_caps_unref(peer);
    }
    if (upstream_meta or caps_meta) {
        ret = setSrcCaps(s, overlay_caps);
        const q = c.gst_query_new_allocation(overlay_caps, 0);
        if (c.gst_pad_peer_query(s.srcpad, q) == 0) {
            if (s.video_flushing != 0) ret = false;
        }
        var idx: c.guint = 0;
        alloc_meta = c.gst_query_find_allocation_meta(q, c.gst_video_overlay_composition_meta_api_get_type(), &idx) != 0;
        if (alloc_meta) {
            var params: ?*const c.GstStructure = null;
            _ = c.gst_query_parse_nth_allocation_meta(q, idx, &params);
            if (params != null) _ = c.gst_structure_get(params, "width", c.G_TYPE_UINT, &width, "height", c.G_TYPE_UINT, &height, @as(?*anyopaque, null));
        }
        c.gst_query_unref(q);
    }
    s.window_width = @bitCast(width);
    s.window_height = @bitCast(height);
    updateRenderSize(s);
    var attach = false;
    if (upstream_meta) {
        attach = true;
    } else if (caps_meta) {
        attach = if (alloc_meta) true else !canHandle(caps);
    } else ret = canHandle(caps);
    if (!attach and ret) ret = setSrcCaps(s, caps);
    s.attach_compo_to_buffer = @intFromBool(attach);
    if (!ret) c.gst_pad_mark_reconfigure(s.srcpad);
    c.gst_caps_unref(overlay_caps);
    c.gst_caps_unref(caps);
    return ret;
}

fn setcaps(s: *Self, caps: [*c]c.GstCaps) bool {
    var prev = c.gst_pad_get_current_caps(s.video_sinkpad);
    if (prev != null and c.gst_caps_is_equal(prev, caps) != 0) {
        c.gst_caps_unref(prev);
        return true;
    }
    if (prev != null) c.gst_caps_unref(prev);
    prev = null;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return false;
    if (info.width != s.info.width or info.height != s.info.height) s.need_render = 1;
    s.info = info;
    s.format = info.finfo[0].format;
    s.width = info.width;
    s.height = info.height;
    var ret = negotiate(s, caps);
    lock(s);
    if (s.attach_compo_to_buffer == 0 and !canHandle(caps)) ret = false;
    unlock(s);
    return ret;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    lock(s);
    switch (id) {
        @intFromEnum(Prop.text) => {
            c.g_free(s.default_text);
            s.default_text = c.g_value_dup_string(v);
        },
        @intFromEnum(Prop.shading) => s.want_shading = c.g_value_get_boolean(v),
        @intFromEnum(Prop.xpad) => s.xpad = c.g_value_get_int(v),
        @intFromEnum(Prop.ypad) => s.ypad = c.g_value_get_int(v),
        @intFromEnum(Prop.deltax) => s.deltax = c.g_value_get_int(v),
        @intFromEnum(Prop.deltay) => s.deltay = c.g_value_get_int(v),
        @intFromEnum(Prop.xpos), @intFromEnum(Prop.x_absolute) => s.xpos = c.g_value_get_double(v),
        @intFromEnum(Prop.ypos), @intFromEnum(Prop.y_absolute) => s.ypos = c.g_value_get_double(v),
        @intFromEnum(Prop.valignment) => s.valign = c.g_value_get_enum(v),
        @intFromEnum(Prop.halignment) => s.halign = c.g_value_get_enum(v),
        @intFromEnum(Prop.wrap_mode) => s.wrap_mode = c.g_value_get_enum(v),
        @intFromEnum(Prop.font_desc) => {
            const desc = pc.pango_font_description_from_string(c.g_value_get_string(v));
            if (desc != null) {
                pc.pango_layout_set_font_description(s.layout, desc);
                adjustFont(s, desc);
                pc.pango_font_description_free(desc);
            }
        },
        @intFromEnum(Prop.color) => s.color = c.g_value_get_uint(v),
        @intFromEnum(Prop.outline_color) => s.outline_color = c.g_value_get_uint(v),
        @intFromEnum(Prop.silent) => s.silent = c.g_value_get_boolean(v),
        @intFromEnum(Prop.draw_shadow) => s.draw_shadow = c.g_value_get_boolean(v),
        @intFromEnum(Prop.draw_outline) => s.draw_outline = c.g_value_get_boolean(v),
        @intFromEnum(Prop.line_alignment) => {
            s.line_align = c.g_value_get_enum(v);
            pc.pango_layout_set_alignment(s.layout, @intCast(s.line_align));
        },
        @intFromEnum(Prop.wait_text) => s.wait_text = c.g_value_get_boolean(v),
        @intFromEnum(Prop.auto_adjust_size) => s.auto_adjust_size = c.g_value_get_boolean(v),
        @intFromEnum(Prop.vertical_render) => {
            s.use_vertical_render = c.g_value_get_boolean(v);
            if (s.use_vertical_render != 0) {
                s.valign = @intFromEnum(VAlign.top);
                s.halign = @intFromEnum(HAlign.right);
                s.line_align = pc.PANGO_ALIGN_LEFT;
                pc.pango_layout_set_alignment(s.layout, @intCast(s.line_align));
            }
        },
        @intFromEnum(Prop.scale_mode) => s.scale_mode = c.g_value_get_enum(v),
        @intFromEnum(Prop.scale_par) => {
            s.scale_par_n = c.gst_value_get_fraction_numerator(v);
            s.scale_par_d = c.gst_value_get_fraction_denominator(v);
        },
        @intFromEnum(Prop.shading_value) => s.shading_value = @bitCast(c.g_value_get_uint(v)),
        @intFromEnum(Prop.alt_render) => s.alt_render = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 1206),
    }
    s.need_render = 1;
    unlock(s);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    lock(s);
    switch (id) {
        @intFromEnum(Prop.text) => c.g_value_set_string(v, s.default_text),
        @intFromEnum(Prop.shading) => c.g_value_set_boolean(v, s.want_shading),
        @intFromEnum(Prop.xpad) => c.g_value_set_int(v, s.xpad),
        @intFromEnum(Prop.ypad) => c.g_value_set_int(v, s.ypad),
        @intFromEnum(Prop.deltax) => c.g_value_set_int(v, s.deltax),
        @intFromEnum(Prop.deltay) => c.g_value_set_int(v, s.deltay),
        @intFromEnum(Prop.xpos), @intFromEnum(Prop.x_absolute) => c.g_value_set_double(v, s.xpos),
        @intFromEnum(Prop.ypos), @intFromEnum(Prop.y_absolute) => c.g_value_set_double(v, s.ypos),
        @intFromEnum(Prop.valignment) => c.g_value_set_enum(v, s.valign),
        @intFromEnum(Prop.halignment) => c.g_value_set_enum(v, s.halign),
        @intFromEnum(Prop.wrap_mode) => c.g_value_set_enum(v, s.wrap_mode),
        @intFromEnum(Prop.silent) => c.g_value_set_boolean(v, s.silent),
        @intFromEnum(Prop.draw_shadow) => c.g_value_set_boolean(v, s.draw_shadow),
        @intFromEnum(Prop.draw_outline) => c.g_value_set_boolean(v, s.draw_outline),
        @intFromEnum(Prop.line_alignment) => c.g_value_set_enum(v, s.line_align),
        @intFromEnum(Prop.wait_text) => c.g_value_set_boolean(v, s.wait_text),
        @intFromEnum(Prop.auto_adjust_size) => c.g_value_set_boolean(v, s.auto_adjust_size),
        @intFromEnum(Prop.vertical_render) => c.g_value_set_boolean(v, s.use_vertical_render),
        @intFromEnum(Prop.scale_mode) => c.g_value_set_enum(v, s.scale_mode),
        @intFromEnum(Prop.scale_par) => c.gst_value_set_fraction(v, s.scale_par_n, s.scale_par_d),
        @intFromEnum(Prop.color) => c.g_value_set_uint(v, s.color),
        @intFromEnum(Prop.outline_color) => c.g_value_set_uint(v, s.outline_color),
        @intFromEnum(Prop.shading_value) => c.g_value_set_uint(v, @bitCast(s.shading_value)),
        @intFromEnum(Prop.alt_render) => c.g_value_set_boolean(v, s.alt_render),
        @intFromEnum(Prop.font_desc) => {
            const desc = pc.pango_layout_get_font_description(s.layout);
            if (desc == null) c.g_value_set_string(v, "") else c.g_value_take_string(v, pc.pango_font_description_to_string(desc));
        },
        @intFromEnum(Prop.text_x) => c.g_value_set_int(v, s.text_x),
        @intFromEnum(Prop.text_y) => c.g_value_set_int(v, s.text_y),
        @intFromEnum(Prop.text_width) => c.g_value_set_uint(v, s.text_width),
        @intFromEnum(Prop.text_height) => c.g_value_set_uint(v, s.text_height),
        else => cm.warnInvalid(FILE, o, id, spec, 1326),
    }
    s.need_render = 1;
    unlock(s);
}

fn srcQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_CAPS) {
        var filter: [*c]c.GstCaps = null;
        c.gst_query_parse_caps(q, &filter);
        const caps = srcCaps(pad, me(parent), filter);
        c.gst_query_set_caps_result(q, caps);
        c.gst_caps_unref(caps);
        return 1;
    }
    return c.gst_pad_query_default(pad, parent, q);
}

fn toUint(x: f64) c.guint {
    if (x <= -1.0 or x >= 4294967296.0 or std.math.isNan(x)) return @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(@max(@min(x, 9.0e18), -9.0e18))))));
    return @intFromFloat(@trunc(x));
}

fn updateRenderSize(s: *Self) void {
    const va = @as(f64, @floatFromInt(s.width)) / @as(f64, @floatFromInt(s.height));
    const wa = @as(f64, @floatFromInt(s.window_width)) / @as(f64, @floatFromInt(s.window_height));
    var tw: c.guint = 0;
    var th: c.guint = 0;
    if (va >= wa) {
        tw = @bitCast(s.window_width);
        th = toUint(wa * @as(f64, @floatFromInt(s.window_height)) / va);
    } else if (va < wa) {
        tw = toUint(va * @as(f64, @floatFromInt(s.window_width)) / wa);
        th = @bitCast(s.window_height);
    }
    if (@as(c.guint, @bitCast(s.render_width)) == tw and @as(c.guint, @bitCast(s.render_height)) == th) return;
    s.need_render = 1;
    s.render_width = @bitCast(tw);
    s.render_height = @bitCast(th);
    s.render_scale = @as(f64, @floatFromInt(s.render_width)) / @as(f64, @floatFromInt(s.width));
}

fn srcEvent(_: ?*c.GstPad, parent: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(parent);
    if (s.text_linked != 0) {
        _ = c.gst_mini_object_ref(@ptrCast(e));
        const ret = c.gst_pad_push_event(s.video_sinkpad, e);
        _ = c.gst_pad_push_event(s.text_sinkpad, e);
        return ret;
    }
    return c.gst_pad_push_event(s.video_sinkpad, e);
}

fn addFeature(caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const out = c.gst_caps_copy(caps);
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(out)) : (i += 1) {
        const f = c.gst_caps_get_features(out, i);
        if (c.gst_caps_features_is_any(f) == 0) c.gst_caps_features_add(f, COMPOSITION);
    }
    c.gst_caps_append(out, c.gst_caps_intersect_full(caps, filter, c.GST_CAPS_INTERSECT_FIRST));
    return out;
}

fn byFeature(caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const out = c.gst_caps_new_empty();
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) {
        const feats = c.gst_caps_features_copy(c.gst_caps_get_features(caps, i));
        const simple = c.gst_caps_new_full(c.gst_structure_copy(c.gst_caps_get_structure(caps, i)), @as(?*anyopaque, null));
        c.gst_caps_set_features(simple, 0, feats);
        var filtered: [*c]c.GstCaps = undefined;
        if (c.gst_caps_features_contains(feats, COMPOSITION) != 0) {
            c.gst_caps_append(out, c.gst_caps_copy(simple));
            c.gst_caps_features_remove(feats, COMPOSITION);
            filtered = c.gst_caps_ref(simple);
        } else filtered = c.gst_caps_intersect_full(simple, filter, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(simple);
        c.gst_caps_append(out, filtered);
    }
    return out;
}

fn peerCaps(pad: ?*c.GstPad, other: ?*c.GstPad, filter: [*c]c.GstCaps, comptime sink_side: bool) [*c]c.GstCaps {
    var overlay_filter: [*c]c.GstCaps = null;
    if (filter != null) {
        const sw = c.gst_static_caps_get(&sw_caps);
        overlay_filter = if (sink_side) addFeature(filter, sw) else byFeature(filter, sw);
        c.gst_caps_unref(sw);
    }
    const peer = c.gst_pad_peer_query_caps(other, overlay_filter);
    if (overlay_filter != null) c.gst_caps_unref(overlay_filter);
    var caps: [*c]c.GstCaps = undefined;
    if (peer != null) {
        if (c.gst_caps_is_any(peer) != 0) {
            const t = c.gst_pad_get_pad_template_caps(other);
            caps = c.gst_caps_copy(t);
            c.gst_caps_unref(t);
        } else {
            const sw = c.gst_static_caps_get(&sw_caps);
            caps = if (sink_side) byFeature(peer, sw) else addFeature(peer, sw);
            c.gst_caps_unref(sw);
        }
        c.gst_caps_unref(peer);
    } else caps = c.gst_pad_get_pad_template_caps(pad);
    if (filter != null) {
        const x = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = x;
    }
    return caps;
}

fn videosinkCaps(pad: ?*c.GstPad, s: *Self, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    return peerCaps(pad, s.srcpad, filter, true);
}

fn srcCaps(pad: ?*c.GstPad, s: *Self, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    return peerCaps(pad, s.video_sinkpad, filter, false);
}

fn toInt(x: f64) c.gint {
    if (std.math.isNan(x) or x >= 2147483648.0 or x <= -2147483649.0) return std.math.minInt(c.gint);
    return @intFromFloat(@trunc(x));
}

fn getPos(s: *Self, xpos: *c.gint, ypos: *c.gint) void {
    const w = s.logical_rect.width;
    const h = s.logical_rect.height;
    xpos.* = s.ink_rect.x - s.logical_rect.x;
    switch (s.halign) {
        @intFromEnum(HAlign.left) => xpos.* = @max(0, xpos.* + s.xpad),
        @intFromEnum(HAlign.center) => xpos.* += @divTrunc(s.width - w, 2),
        @intFromEnum(HAlign.right) => {
            xpos.* += s.width - w - s.xpad;
            xpos.* = @min(s.width - s.ink_rect.width, xpos.*);
        },
        @intFromEnum(HAlign.pos) => {
            xpos.* += toInt(@as(f64, @floatFromInt(s.width)) * s.xpos) - @divTrunc(w, 2);
            const hi = s.width - s.ink_rect.width;
            xpos.* = if (xpos.* > hi) hi else if (xpos.* < 0) 0 else xpos.*;
            if (xpos.* < 0) xpos.* = 0;
        },
        @intFromEnum(HAlign.absolute) => xpos.* = toInt(@as(f64, @floatFromInt(@as(c.guint, @bitCast(s.width)) -% s.text_width)) * s.xpos),
        else => xpos.* = 0,
    }
    xpos.* += s.deltax;
    ypos.* = s.ink_rect.y - s.logical_rect.y;
    switch (s.valign) {
        @intFromEnum(VAlign.bottom) => {
            ypos.* += s.height - h - s.ypad;
            ypos.* = @min(s.height - s.ink_rect.height, ypos.*);
        },
        @intFromEnum(VAlign.baseline) => ypos.* += s.height - h - s.ypad,
        @intFromEnum(VAlign.top) => {
            ypos.* += s.ypad;
            ypos.* = toInt(@max(0.0, @as(f64, @floatFromInt(ypos.*))));
        },
        @intFromEnum(VAlign.pos) => {
            ypos.* = toInt(@as(f64, @floatFromInt(s.height)) * s.ypos) - @divTrunc(h, 2);
            const hi = s.height - s.ink_rect.height;
            ypos.* = if (ypos.* > hi) hi else if (ypos.* < 0) 0 else ypos.*;
        },
        @intFromEnum(VAlign.absolute) => ypos.* = toInt(@as(f64, @floatFromInt(@as(c.guint, @bitCast(s.height)) -% s.text_height)) * s.ypos),
        @intFromEnum(VAlign.center) => ypos.* = @divTrunc(s.height - h, 2),
        else => ypos.* = s.ypad,
    }
    ypos.* += s.deltay;
    s.text_x = xpos.*;
    s.text_y = ypos.*;
}

fn setComposition(s: *Self) void {
    if (s.text_image != null) {
        var x: c.gint = 0;
        var y: c.gint = 0;
        getPos(s, &x, &y);
        const rw = s.ink_rect.width;
        const rh = s.ink_rect.height;
        _ = c.gst_buffer_add_video_meta(s.text_image, c.GST_VIDEO_FRAME_FLAG_NONE, c.GST_VIDEO_OVERLAY_COMPOSITION_FORMAT_RGB, s.text_width, s.text_height);
        const rect = c.gst_video_overlay_rectangle_new_raw(s.text_image, x, y, @bitCast(rw), @bitCast(rh), c.GST_VIDEO_OVERLAY_FORMAT_FLAG_PREMULTIPLIED_ALPHA);
        var alt: ?*c.GstVideoOverlayRectangle = null;
        if (s.alt_render != 0) {
            const nx = @divTrunc(s.window_width - x, rw);
            const ny = @divTrunc(s.window_height - y, rh);
            if (!(nx < 2 and ny < 2)) {
                const ax = x + @divTrunc(alt_idx, ny) * rw;
                const ay = y + @rem(alt_idx, ny) * rh;
                alt = c.gst_video_overlay_rectangle_new_raw(s.text_image, ax, ay, @bitCast(rw), @bitCast(rh), c.GST_VIDEO_OVERLAY_FORMAT_FLAG_PREMULTIPLIED_ALPHA);
                alt_idx += 1;
                alt_idx = @rem(alt_idx, nx * ny);
            }
        }
        if (s.composition != null) c.gst_mini_object_unref(@ptrCast(@alignCast(s.composition)));
        s.composition = c.gst_video_overlay_composition_new(rect);
        if (alt != null) {
            c.gst_video_overlay_composition_add_rectangle(s.composition, alt);
            c.gst_mini_object_unref(@ptrCast(@alignCast(alt)));
        }
        c.gst_mini_object_unref(@ptrCast(@alignCast(rect)));
    } else if (s.composition != null) {
        c.gst_mini_object_unref(@ptrCast(@alignCast(s.composition)));
        s.composition = null;
    }
}

fn notForeground(attr: [*c]pc.PangoAttribute, _: pc.gpointer) callconv(.c) pc.gboolean {
    return @intFromBool(attr[0].klass[0].type != pc.PANGO_ATTR_FOREGROUND);
}

fn ceilI(x: f64) c.gint {
    return toInt(@ceil(x));
}

fn renderPangocairo(s: *Self, str: [*c]const u8, len: c.gint) void {
    var sx: f64 = 1.0;
    var sy: f64 = 1.0;
    if (s.auto_adjust_size != 0) {
        sx = @as(f64, @floatFromInt(s.width)) / 640.0;
        sy = sx;
    }
    if (s.scale_mode != 0) {
        var pn: c.gint = 1;
        var pd: c.gint = 1;
        switch (s.scale_mode) {
            1 => {
                pn = s.info.par_n;
                pd = s.info.par_d;
            },
            2 => if (c.gst_util_fraction_multiply(s.window_width, s.window_height, s.height, s.width, &pn, &pd) == 0) {
                pn = 1;
                pd = 1;
            },
            3 => {
                pn = s.scale_par_n;
                pd = s.scale_par_d;
            },
            else => {},
        }
        if (pn == 0 or pd == 0) {
            pn = 1;
            pd = 1;
        }
        const fn_: f64 = @floatFromInt(pn);
        const fd: f64 = @floatFromInt(pd);
        if (s.use_vertical_render != 0) sy *= fd / fn_ else sy *= fn_ / fd;
    }
    const so: f64 = if (s.draw_shadow != 0) @ceil(s.shadow_offset) else 0.0;
    const oo: f64 = if (s.draw_outline != 0) @ceil(s.outline_offset) else 0.0;
    const xpad: c.gint = if (s.halign == @intFromEnum(HAlign.left) or s.halign == @intFromEnum(HAlign.right)) s.xpad else 0;
    const ypad: c.gint = if (s.valign == @intFromEnum(VAlign.top) or s.valign == @intFromEnum(VAlign.bottom)) s.ypad else 0;
    pc.pango_layout_set_width(s.layout, -1);
    pc.pango_layout_set_markup(s.layout, str, len);
    var ink: pc.PangoRectangle = undefined;
    var logical: pc.PangoRectangle = undefined;
    pc.pango_layout_get_pixel_extents(s.layout, &ink, &logical);
    var uw: c.gint = toInt(@as(f64, @floatFromInt(ink.width)) + so + oo);
    var width: c.gint = ceilI(@as(f64, @floatFromInt(uw)) * sx);
    var full = false;
    if (s.use_vertical_render != 0) {
        if (width + ypad > s.height) {
            width = s.height - ypad;
            full = true;
        }
    } else if (width + xpad > s.width) {
        width = s.width - xpad;
        full = true;
    }
    if (full) {
        uw = toInt(@as(f64, @floatFromInt(width)) / sx);
        setWrapMode(s, toInt(@as(f64, @floatFromInt(uw)) - so - oo));
        pc.pango_layout_get_pixel_extents(s.layout, &ink, &logical);
        uw = toInt(@as(f64, @floatFromInt(ink.width)) + so + oo);
        width = ceilI(@as(f64, @floatFromInt(uw)) * sx);
    }
    var uh: c.gint = toInt(@as(f64, @floatFromInt(ink.height)) + so + oo);
    var height: c.gint = ceilI(@as(f64, @floatFromInt(uh)) * sy);
    if (s.use_vertical_render != 0) {
        if (height + xpad > s.width) {
            height = s.width - xpad;
            uh = toInt(@as(f64, @floatFromInt(width)) / sy);
        }
    } else if (height + ypad > s.height) {
        height = s.height - ypad;
        uh = toInt(@as(f64, @floatFromInt(height)) / sy);
    }
    const half = @ceil(oo / 2.0);
    s.ink_rect.x = ceilI((@as(f64, @floatFromInt(ink.x)) - half) * sx);
    s.ink_rect.y = ceilI((@as(f64, @floatFromInt(ink.y)) - half) * sy);
    s.ink_rect.width = width;
    s.ink_rect.height = height;
    s.logical_rect.x = ceilI((@as(f64, @floatFromInt(logical.x)) - half) * sx);
    s.logical_rect.y = ceilI((@as(f64, @floatFromInt(logical.y)) - half) * sy);
    s.logical_rect.width = ceilI((@as(f64, @floatFromInt(logical.width)) + so + oo) * sx);
    s.logical_rect.height = ceilI((@as(f64, @floatFromInt(logical.height)) + so + oo) * sy);
    if (s.use_vertical_render != 0) {
        var t = s.ink_rect;
        s.ink_rect = .{ .x = t.y, .y = t.x, .width = t.height, .height = t.width };
        s.ink_rect.x += s.ink_rect.width;
        t = s.logical_rect;
        s.logical_rect = .{ .x = t.y, .y = t.x, .width = t.height, .height = t.width };
        s.logical_rect.x += s.logical_rect.width;
    }
    width = ceilI(@as(f64, @floatFromInt(width)) * s.render_scale);
    height = ceilI(@as(f64, @floatFromInt(height)) * s.render_scale);
    sx *= s.render_scale;
    sy *= s.render_scale;
    if (width <= 0 or height <= 0) return;
    if (uh <= 0 or uw <= 0) return;
    if (s.use_vertical_render != 0) std.mem.swap(f64, &sx, &sy);
    var m: pc.cairo_matrix_t = undefined;
    pc.cairo_matrix_init_scale(&m, sx, sy);
    if (s.use_vertical_render != 0) {
        pc.cairo_matrix_translate(&m, @as(f64, @floatFromInt(uh)) / 2.0, @as(f64, @floatFromInt(uw)) / 2.0);
        pc.cairo_matrix_rotate(&m, std.math.pi / 2.0);
        pc.cairo_matrix_translate(&m, -(@as(f64, @floatFromInt(uw)) / 2.0), -(@as(f64, @floatFromInt(uh)) / 2.0));
        std.mem.swap(c.gint, &width, &height);
    }
    pc.cairo_matrix_translate(&m, half - @as(f64, @floatFromInt(ink.x)), half - @as(f64, @floatFromInt(ink.y)));
    const buffer = c.gst_buffer_new_allocate(null, @intCast(4 * width * height), null);
    _ = c.gst_buffer_replace(&s.text_image, buffer);
    c.gst_buffer_unref(buffer);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buffer, &map, c.GST_MAP_READWRITE);
    const surface = pc.cairo_image_surface_create_for_data(map.data, pc.CAIRO_FORMAT_ARGB32, width, height, width * 4);
    const cr = pc.cairo_create(surface);
    pc.cairo_set_operator(cr, pc.CAIRO_OPERATOR_CLEAR);
    pc.cairo_paint(cr);
    pc.cairo_set_operator(cr, pc.CAIRO_OPERATOR_OVER);
    pc.cairo_set_matrix(cr, &m);
    if (s.draw_shadow != 0) {
        const origin = pc.pango_attr_list_ref(pc.pango_layout_get_attributes(s.layout));
        const tmp = pc.pango_attr_list_copy(origin);
        const filtered = pc.pango_attr_list_filter(tmp, notForeground, null);
        pc.pango_attr_list_unref(tmp);
        pc.cairo_save(cr);
        pc.cairo_translate(cr, s.shadow_offset, s.shadow_offset);
        pc.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.5);
        pc.pango_layout_set_attributes(s.layout, filtered);
        pc.pango_cairo_show_layout(cr, s.layout);
        pc.pango_layout_set_attributes(s.layout, origin);
        pc.pango_attr_list_unref(filtered);
        pc.pango_attr_list_unref(origin);
        pc.cairo_restore(cr);
    }
    if (s.draw_outline != 0) {
        const col = s.outline_color;
        pc.cairo_save(cr);
        pc.cairo_set_source_rgba(cr, chan(col, 16), chan(col, 8), chan(col, 0), chan(col, 24));
        pc.cairo_set_line_width(cr, s.outline_offset);
        pc.pango_cairo_layout_path(cr, s.layout);
        pc.cairo_stroke(cr);
        pc.cairo_restore(cr);
    }
    const col = s.color;
    pc.cairo_save(cr);
    pc.cairo_set_source_rgba(cr, chan(col, 16), chan(col, 8), chan(col, 0), chan(col, 24));
    pc.pango_cairo_show_layout(cr, s.layout);
    pc.cairo_restore(cr);
    pc.cairo_destroy(cr);
    pc.cairo_surface_destroy(surface);
    c.gst_buffer_unmap(buffer, &map);
    if (width != 0) s.text_width = @bitCast(width);
    if (height != 0) s.text_height = @bitCast(height);
    setComposition(s);
}

fn chan(col: c.guint, comptime shift: u5) f64 {
    return @as(f64, @floatFromInt((col >> shift) & 0xff)) / 255.0;
}

fn clampByte(v: c.gint) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn shadeBytes(s: *Self, row: [*]u8, x0: c.gint, x1: c.gint, step: usize, first: usize, count: usize) void {
    var j = x0;
    while (j < x1) : (j += 1) {
        const base = @as(usize, @intCast(j)) * step;
        for (first..first + count) |k| row[base + k] = clampByte(@as(c.gint, row[base + k]) - s.shading_value);
    }
}

fn subScale(sub: c.guint, v: c.gint) c.gint {
    return -(-v >> @intCast(sub));
}

fn shadeBackground(s: *Self, frame: *c.GstVideoFrame, x0_in: c.gint, x1_in: c.gint, y0_in: c.gint, y1_in: c.gint) void {
    var x0 = std.math.clamp(x0_in - BOX_PAD, 0, s.width);
    var x1 = std.math.clamp(x1_in + BOX_PAD, 0, s.width);
    var y0 = std.math.clamp(y0_in - BOX_PAD, 0, s.height);
    var y1 = std.math.clamp(y1_in + BOX_PAD, 0, s.height);
    const data: [*]u8 = @ptrCast(frame.data[0]);
    const stride: usize = @intCast(frame.info.stride[0]);
    switch (s.format) {
        c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_YV12, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_NV21, c.GST_VIDEO_FORMAT_Y41B, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_YUV9, c.GST_VIDEO_FORMAT_YVU9, c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_A420 => {
            var i = y0;
            while (i < y1) : (i += 1) shadeBytes(s, data + @as(usize, @intCast(i)) * stride, x0, x1, 1, 0, 1);
        },
        c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_VYUY, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_v308, c.GST_VIDEO_FORMAT_IYU2 => {
            const fi = frame.info.finfo[0];
            const cdata: [*]u8 = @ptrCast(frame.data[fi.plane[0]]);
            const cstride: usize = @intCast(frame.info.stride[fi.plane[0]]);
            const pstride: usize = @intCast(fi.pixel_stride[0]);
            const comp = cdata + fi.poffset[0];
            if (x0 != 0) x0 = subScale(fi.w_sub[0], x0);
            if (x1 != 0) x1 = subScale(fi.w_sub[0], x1);
            if (y0 != 0) y0 = subScale(fi.h_sub[0], y0);
            if (y1 != 0) y1 = subScale(fi.h_sub[0], y1);
            var i = y0;
            while (i < y1) : (i += 1) shadeBytes(s, comp + @as(usize, @intCast(i)) * cstride, x0, x1, pstride, 0, 1);
        },
        c.GST_VIDEO_FORMAT_xRGB, c.GST_VIDEO_FORMAT_xBGR, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_RGBx => {
            var i = y0;
            while (i < y1) : (i += 1) shadeBytes(s, data + @as(usize, @intCast(i)) * stride, x0, x1, 4, 0, 4);
        },
        c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_ABGR => {
            var i = y0;
            while (i < y1) : (i += 1) shadeBytes(s, data + @as(usize, @intCast(i)) * stride, x0, x1, 4, 1, 3);
        },
        c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_BGRA => {
            var i = y0;
            while (i < y1) : (i += 1) shadeBytes(s, data + @as(usize, @intCast(i)) * stride, x0, x1, 4, 0, 3);
        },
        c.GST_VIDEO_FORMAT_BGR, c.GST_VIDEO_FORMAT_RGB => {
            var i = y0;
            while (i < y1) : (i += 1) shadeBytes(s, data + @as(usize, @intCast(i)) * stride, x0, x1, 3, 0, 3);
        },
        c.GST_VIDEO_FORMAT_IYU1 => {
            var i = y0;
            while (i < y1) : (i += 1) {
                var p = data + @as(usize, @intCast(i)) * stride + @as(usize, @intCast(@divTrunc(x0, 2) * 3)) + 1;
                var x = x0;
                while (x < x1) : (x += 2) {
                    p[0] = clampByte(@as(c.gint, p[0]) - s.shading_value);
                    p[1] = clampByte(@as(c.gint, p[1]) - s.shading_value);
                    p += 3;
                }
            }
        },
        else => {},
    }
}

pub fn renderText(s: *Self, text: [*c]const u8, len_in: c.gint) void {
    if (s.need_render == 0) return;
    var len = len_in;
    if (text != null and len < 0) len = @intCast(std.mem.len(text));
    const str = if (text != null) c.g_strndup(text, @intCast(len)) else c.g_strdup(" ");
    _ = c.g_strdelimit(str, "\r\t", ' ');
    renderPangocairo(s, str, @intCast(std.mem.len(str)));
    c.g_free(str);
    s.need_render = 0;
}

fn pushFrame(s: *Self, frame_in: [*c]c.GstBuffer) c.GstFlowReturn {
    var buf = frame_in;
    if (s.composition != null) {
        if (c.gst_pad_check_reconfigure(s.srcpad) != 0) {
            if (!negotiate(s, null)) {
                c.gst_pad_mark_reconfigure(s.srcpad);
                c.gst_buffer_unref(buf);
                const flushing = @as(*c.GstObject, @ptrCast(@alignCast(s.srcpad))).flags & c.GST_PAD_FLAG_FLUSHING != 0;
                return if (flushing) c.GST_FLOW_FLUSHING else c.GST_FLOW_NOT_NEGOTIATED;
            }
        }
        buf = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(buf)));
        if (s.attach_compo_to_buffer != 0) {
            _ = c.gst_buffer_add_video_overlay_composition_meta(buf, s.composition);
        } else {
            var frame: c.GstVideoFrame = undefined;
            if (c.gst_video_frame_map(&frame, &s.info, buf, c.GST_MAP_READWRITE) == 0) {
                c.gst_buffer_unref(buf);
                return c.GST_FLOW_OK;
            }
            if (s.want_shading != 0) {
                var x: c.gint = 0;
                var y: c.gint = 0;
                getPos(s, &x, &y);
                shadeBackground(s, &frame, x, x +% @as(c.gint, @bitCast(s.text_width)), y, y +% @as(c.gint, @bitCast(s.text_height)));
            }
            _ = c.gst_video_overlay_composition_blend(s.composition, &frame);
            c.gst_video_frame_unmap(&frame);
        }
    }
    return c.gst_pad_push(s.srcpad, buf);
}

fn textLink(_: ?*c.GstPad, parent: ?*c.GstObject, _: ?*c.GstPad) callconv(.c) c.GstPadLinkReturn {
    if (parent == null) return c.GST_PAD_LINK_REFUSED;
    me(parent).text_linked = 1;
    return c.GST_PAD_LINK_OK;
}

fn textUnlink(_: ?*c.GstPad, parent: ?*c.GstObject) callconv(.c) void {
    const s = me(parent);
    s.text_linked = 0;
    c.gst_segment_init(&s.text_segment, c.GST_FORMAT_UNDEFINED);
}

fn popText(s: *Self) void {
    if (!cm.that(c.g_type_check_instance_is_a(@ptrCast(@alignCast(s)), getType()) != 0, "gst_base_text_overlay_pop_text", "GST_IS_BASE_TEXT_OVERLAY (overlay)")) return;
    if (s.text_buffer != null) {
        c.gst_buffer_unref(s.text_buffer);
        s.text_buffer = null;
        s.text_buffer_running_time = NONE;
        s.text_buffer_running_time_end = NONE;
    }
    broadcast(s);
}

fn textEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(parent);
    switch (e[0].type) {
        c.GST_EVENT_STREAM_START, c.GST_EVENT_FLUSH_STOP => {
            lock(s);
            s.text_flushing = 0;
            s.text_eos = 0;
            popText(s);
            c.gst_segment_init(&s.text_segment, c.GST_FORMAT_TIME);
            unlock(s);
            c.gst_event_unref(e);
            return 1;
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            const ok = setcapsText(s, caps);
            c.gst_event_unref(e);
            return @intFromBool(ok);
        },
        c.GST_EVENT_SEGMENT => {
            s.text_eos = 0;
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            if (seg[0].format == c.GST_FORMAT_TIME) {
                lock(s);
                c.gst_segment_copy_into(seg, &s.text_segment);
                unlock(s);
            } else {
                c.gst_element_message_full(@ptrCast(s), c.GST_MESSAGE_WARNING, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_MUX, null, c.g_strdup("received non-TIME newsegment event on text input"), FILE, "gst_base_text_overlay_text_event", 2520);
            }
            c.gst_event_unref(e);
            lock(s);
            broadcast(s);
            unlock(s);
            return 1;
        },
        c.GST_EVENT_GAP => {
            var start: c.GstClockTime = 0;
            var dur: c.GstClockTime = 0;
            c.gst_event_parse_gap(e, &start, &dur);
            if (dur != NONE) start +%= dur;
            s.text_segment.position = start;
            lock(s);
            broadcast(s);
            unlock(s);
            c.gst_event_unref(e);
            return 1;
        },
        c.GST_EVENT_FLUSH_START => {
            lock(s);
            s.text_flushing = 1;
            broadcast(s);
            unlock(s);
            c.gst_event_unref(e);
            return 1;
        },
        c.GST_EVENT_EOS => {
            lock(s);
            s.text_eos = 1;
            broadcast(s);
            unlock(s);
            c.gst_event_unref(e);
            return 1;
        },
        else => return c.gst_pad_event_default(pad, parent, e),
    }
}

pub fn videoEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(parent);
    switch (e[0].type) {
        c.GST_EVENT_STREAM_START => {
            lock(s);
            s.video_flushing = 0;
            s.video_eos = 0;
            c.gst_segment_init(&s.segment, c.GST_FORMAT_TIME);
            unlock(s);
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            const ok = setcaps(s, caps);
            c.gst_event_unref(e);
            return @intFromBool(ok);
        },
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            if (seg[0].format == c.GST_FORMAT_TIME) {
                c.gst_segment_copy_into(seg, &s.segment);
            } else {
                c.gst_element_message_full(@ptrCast(s), c.GST_MESSAGE_WARNING, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_MUX, null, c.g_strdup("received non-TIME newsegment event on video input"), FILE, "gst_base_text_overlay_video_event", 2638);
            }
        },
        c.GST_EVENT_EOS => {
            lock(s);
            s.video_eos = 1;
            unlock(s);
        },
        c.GST_EVENT_FLUSH_START => {
            lock(s);
            s.video_flushing = 1;
            broadcast(s);
            unlock(s);
        },
        c.GST_EVENT_FLUSH_STOP => {
            lock(s);
            s.video_flushing = 0;
            s.video_eos = 0;
            c.gst_segment_init(&s.segment, c.GST_FORMAT_TIME);
            unlock(s);
        },
        else => {},
    }
    return c.gst_pad_event_default(pad, parent, e);
}

fn videoQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_CAPS) {
        var filter: [*c]c.GstCaps = null;
        c.gst_query_parse_caps(q, &filter);
        const caps = videosinkCaps(pad, me(parent), filter);
        c.gst_query_set_caps_result(q, caps);
        c.gst_caps_unref(caps);
        return 1;
    }
    return c.gst_pad_query_default(pad, parent, q);
}

fn textChain(_: ?*c.GstPad, parent: ?*c.GstObject, buffer: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(parent);
    var buf = buffer;
    lock(s);
    if (s.text_flushing != 0) {
        unlock(s);
        c.gst_buffer_unref(buf);
        return c.GST_FLOW_FLUSHING;
    }
    if (s.text_eos != 0) {
        unlock(s);
        c.gst_buffer_unref(buf);
        return c.GST_FLOW_EOS;
    }
    var cs: u64 = 0;
    var ce: u64 = 0;
    var in_seg = true;
    if (buf[0].pts != NONE) {
        const stop = if (buf[0].duration != NONE) buf[0].pts +% buf[0].duration else NONE;
        in_seg = c.gst_segment_clip(&s.text_segment, c.GST_FORMAT_TIME, buf[0].pts, stop, &cs, &ce) != 0;
    }
    if (in_seg) {
        buf = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(buf)));
        if (buf[0].pts != NONE) buf[0].pts = cs;
        if (buf[0].duration != NONE) buf[0].duration = ce -% cs;
        while (s.text_buffer != null) {
            c.g_cond_wait(&s.cond, &s.lock);
            if (s.text_flushing != 0) {
                unlock(s);
                c.gst_buffer_unref(buf);
                return c.GST_FLOW_FLUSHING;
            }
        }
        s.text_buffer_running_time = NONE;
        s.text_buffer_running_time_end = NONE;
        if (buf[0].pts != NONE) {
            const start = buf[0].pts;
            s.text_segment.position = cs;
            s.text_buffer_running_time = c.gst_segment_to_running_time(&s.text_segment, c.GST_FORMAT_TIME, start);
            if (buf[0].duration != NONE) s.text_buffer_running_time_end = c.gst_segment_to_running_time(&s.text_segment, c.GST_FORMAT_TIME, start +% buf[0].duration);
        }
        s.text_buffer = buf;
        buf = null;
        s.need_render = 1;
        broadcast(s);
    }
    unlock(s);
    if (buf != null) c.gst_buffer_unref(buf);
    return c.GST_FLOW_OK;
}

fn renderFromBuffer(s: *Self) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(s.text_buffer, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(s.text_buffer, &map);
    var in_text: [*c]u8 = @ptrCast(map.data);
    const size = map.size;
    if (size == 0) {
        renderText(s, " ", 1);
        return;
    }
    if (c.g_utf8_validate(in_text, @intCast(size), null) == 0) {
        in_text = c.g_strndup(in_text, size);
        var end: [*c]const u8 = null;
        while (c.g_utf8_validate(in_text, @intCast(size), &end) == 0 and end != null) @constCast(end)[0] = '*';
    }
    const text = if (s.have_pango_markup != 0) c.g_strndup(in_text, size) else c.g_markup_escape_text(in_text, @intCast(size));
    if (text != null and text[0] != 0) {
        var n = std.mem.len(text);
        while (n > 0 and (text[n - 1] == '\n' or text[n - 1] == '\r')) n -= 1;
        renderText(s, text, @intCast(n));
    } else renderText(s, " ", 1);
    c.g_free(text);
    if (in_text != @as([*c]u8, @ptrCast(map.data))) c.g_free(in_text);
}

fn videoChain(_: ?*c.GstPad, parent: ?*c.GstObject, buffer: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(parent);
    var buf = buffer;
    if (buf[0].pts == NONE) {
        c.gst_buffer_unref(buf);
        return c.GST_FLOW_OK;
    }
    const start = buf[0].pts;
    var stop: u64 = if (buf[0].duration == NONE) NONE else start +% buf[0].duration;
    if (stop == NONE and start < s.segment.start) {
        c.gst_buffer_unref(buf);
        return c.GST_FLOW_OK;
    }
    var cs: u64 = 0;
    var ce: u64 = 0;
    if (c.gst_segment_clip(&s.segment, c.GST_FORMAT_TIME, start, stop, &cs, &ce) == 0) {
        c.gst_buffer_unref(buf);
        return c.GST_FLOW_OK;
    }
    if (cs != start or (stop != NONE and ce != stop)) {
        buf = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(buf)));
        buf[0].pts = cs;
        if (stop != NONE) buf[0].duration = ce -% cs;
    }
    if (stop == NONE) {
        stop = if (s.info.fps_n != 0 and s.info.fps_d != 0) start +% c.gst_util_uint64_scale_int(c.GST_SECOND, s.info.fps_d, s.info.fps_n) else start +% 1;
    }
    _ = c.gst_object_sync_values(@ptrCast(s), buf[0].pts);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var text: [*c]u8 = null;
    while (true) {
        lock(s);
        if (s.video_flushing != 0) {
            unlock(s);
            c.gst_buffer_unref(buf);
            return c.GST_FLOW_FLUSHING;
        }
        if (s.video_eos != 0) {
            unlock(s);
            c.gst_buffer_unref(buf);
            return c.GST_FLOW_EOS;
        }
        if (s.silent != 0) {
            unlock(s);
            ret = c.gst_pad_push(s.srcpad, buf);
            s.segment.position = cs;
            return ret;
        }
        if (s.text_linked == 0) {
            const k = klass(s);
            text = if (k.get_text) |f| f(s, buf) else c.g_strdup(s.default_text);
            unlock(s);
            if (text != null and text[0] != 0) {
                renderText(s, text, -1);
                ret = pushFrame(s, buf);
            } else ret = c.gst_pad_push(s.srcpad, buf);
            break;
        }
        if (s.text_buffer != null) {
            var pop = false;
            var valid = true;
            const trt = s.text_buffer_running_time;
            const trte = s.text_buffer_running_time_end;
            if (trt == NONE or trte == NONE) {
                pop = true;
                valid = false;
            }
            const vrt = c.gst_segment_to_running_time(&s.segment, c.GST_FORMAT_TIME, start);
            const vrte = c.gst_segment_to_running_time(&s.segment, c.GST_FORMAT_TIME, stop);
            if (valid and trte <= vrt) {
                popText(s);
                unlock(s);
                continue;
            } else if (valid and vrte <= trt) {
                unlock(s);
                ret = c.gst_pad_push(s.srcpad, buf);
            } else {
                renderFromBuffer(s);
                unlock(s);
                ret = pushFrame(s, buf);
                if (valid and trte <= vrte) pop = true;
            }
            if (pop) {
                lock(s);
                popText(s);
                unlock(s);
            }
            break;
        }
        var wait = s.text_eos == 0 and s.wait_text != 0;
        if (s.text_segment.format == c.GST_FORMAT_TIME) {
            const vrt = c.gst_segment_to_running_time(&s.segment, c.GST_FORMAT_TIME, buf[0].pts);
            const tsr = c.gst_segment_to_running_time(&s.text_segment, c.GST_FORMAT_TIME, s.text_segment.start);
            const tpr = c.gst_segment_to_running_time(&s.text_segment, c.GST_FORMAT_TIME, s.text_segment.position);
            if ((tsr != NONE and vrt < tsr) or (tpr != NONE and vrt < tpr)) wait = false;
        }
        if (wait) {
            c.g_cond_wait(&s.cond, &s.lock);
            unlock(s);
            continue;
        }
        unlock(s);
        ret = c.gst_pad_push(s.srcpad, buf);
        break;
    }
    c.g_free(text);
    s.segment.position = cs;
    return ret;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        lock(s);
        s.text_flushing = 1;
        s.video_flushing = 1;
        popText(s);
        unlock(s);
    }
    const ret = parent_el.change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        lock(s);
        s.text_flushing = 0;
        s.video_flushing = 0;
        s.video_eos = 0;
        s.text_eos = 0;
        c.gst_segment_init(&s.segment, c.GST_FORMAT_TIME);
        c.gst_segment_init(&s.text_segment, c.GST_FORMAT_TIME);
        unlock(s);
    }
    return ret;
}

pub fn setMonospace(s: *Self) void {
    s.valign = @intFromEnum(VAlign.top);
    s.halign = @intFromEnum(HAlign.left);
    const ctx = s.pango_context;
    pc.pango_context_set_language(ctx, pc.pango_language_from_string("en_US"));
    pc.pango_context_set_base_dir(ctx, pc.PANGO_DIRECTION_LTR);
    const fd = pc.pango_font_description_new();
    pc.pango_font_description_set_family_static(fd, "Monospace");
    pc.pango_font_description_set_style(fd, pc.PANGO_STYLE_NORMAL);
    pc.pango_font_description_set_variant(fd, pc.PANGO_VARIANT_NORMAL);
    pc.pango_font_description_set_weight(fd, pc.PANGO_WEIGHT_NORMAL);
    pc.pango_font_description_set_stretch(fd, pc.PANGO_STRETCH_NORMAL);
    pc.pango_font_description_set_size(fd, 18 * SCALE);
    pc.pango_context_set_font_description(ctx, fd);
    pc.pango_font_description_free(fd);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const info = c.GTypeInfo{
                .class_size = @sizeOf(Class),
                .base_init = null,
                .base_finalize = null,
                .class_init = classInit,
                .class_finalize = null,
                .class_data = null,
                .instance_size = @sizeOf(Self),
                .n_preallocs = 0,
                .instance_init = init,
                .value_table = null,
            };
            return c.g_type_register_static(c.gst_element_get_type(), "GstBaseTextOverlay", &info, 0);
        }
    }.f);
}
