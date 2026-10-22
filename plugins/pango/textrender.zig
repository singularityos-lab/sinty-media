const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pc = @import("pc.zig").p;
const base = @import("base.zig");

const FILE = "../ext/pango/gsttextrender.c";
const SCALE = 1024;
const A = 3;
const R = 2;
const G = 1;
const B = 0;

const Prop = enum(c.guint) { halignment = 1, valignment, line_alignment, xpad, ypad, font_desc };

const Self = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    width: c.gint,
    height: c.gint,
    layout: ?*pc.PangoLayout,
    shadow_offset: f64,
    outline_offset: f64,
    text_image: [*c]u8,
    image_width: c.gint,
    image_height: c.gint,
    baseline_y: c.gint,
    use_ARGB: c.gboolean,
    pango_context: ?*pc.PangoContext,
    valign: c.gint,
    halign: c.gint,
    line_align: c.gint,
    xpad: c.gint,
    ypad: c.gint,
    segment_event: [*c]c.GstEvent,
    have_pango_markup: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, base.capsMake("", "{ AYUV, ARGB } "));
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "text/x-raw, format = { pango-markup, utf8 }");
var once: cm.Once = .{};
var valign_once: cm.Once = .{};
var halign_once: cm.Once = .{};
var line_once: cm.Once = .{};
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn enumType(o: *cm.Once, comptime name: [:0]const u8, comptime vals: []const struct { c.gint, [:0]const u8 }) c.GType {
    const S = struct {
        var values = blk: {
            var v: [vals.len + 1]c.GEnumValue = undefined;
            for (vals, 0..) |x, i| v[i] = .{ .value = x[0], .value_name = x[1], .value_nick = x[1] };
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
    return enumType(&valign_once, "GstTextRenderVAlign", &.{ .{ 0, "baseline" }, .{ 1, "bottom" }, .{ 2, "top" } });
}

fn halignType() c.GType {
    return enumType(&halign_once, "GstTextRenderHAlign", &.{ .{ 0, "left" }, .{ 1, "center" }, .{ 2, "right" } });
}

fn lineType() c.GType {
    return enumType(&line_once, "GstTextRenderLineAlign", &.{ .{ pc.PANGO_ALIGN_LEFT, "left" }, .{ pc.PANGO_ALIGN_CENTER, "center" }, .{ pc.PANGO_ALIGN_RIGHT, "right" } });
}

fn adjustFont(s: *Self, desc: ?*const pc.PangoFontDescription) void {
    const size = @divTrunc(pc.pango_font_description_get_size(desc), SCALE);
    s.shadow_offset = @as(f64, @floatFromInt(size)) / 13.0;
    s.outline_offset = @as(f64, @floatFromInt(size)) / 15.0;
    if (s.outline_offset < 1.0) s.outline_offset = 1.0;
}

fn toInt(x: f64) c.gint {
    if (std.math.isNan(x) or x >= 2147483648.0 or x <= -2147483649.0) return std.math.minInt(c.gint);
    return @intFromFloat(@trunc(x));
}

fn render(s: *Self) void {
    var ink: pc.PangoRectangle = undefined;
    var logical: pc.PangoRectangle = undefined;
    pc.pango_layout_get_pixel_extents(s.layout, &ink, &logical);
    const width = toInt(@as(f64, @floatFromInt(logical.width)) + s.shadow_offset);
    const height = toInt(@as(f64, @floatFromInt(logical.height + logical.y)) + s.shadow_offset);
    const shadow = pc.cairo_image_surface_create(pc.CAIRO_FORMAT_A8, width, height);
    const crs = pc.cairo_create(shadow);
    pc.cairo_set_operator(crs, pc.CAIRO_OPERATOR_CLEAR);
    pc.cairo_paint(crs);
    pc.cairo_set_operator(crs, pc.CAIRO_OPERATOR_OVER);
    pc.cairo_save(crs);
    pc.cairo_set_source_rgba(crs, 0.0, 0.0, 0.0, 0.5);
    pc.cairo_translate(crs, s.shadow_offset, s.shadow_offset);
    pc.pango_cairo_show_layout(crs, s.layout);
    pc.cairo_restore(crs);
    pc.cairo_save(crs);
    pc.cairo_set_source_rgb(crs, 0.0, 0.0, 0.0);
    pc.cairo_set_line_width(crs, s.outline_offset);
    pc.pango_cairo_layout_path(crs, s.layout);
    pc.cairo_stroke(crs);
    pc.cairo_restore(crs);
    pc.cairo_destroy(crs);
    s.text_image = @ptrCast(c.g_realloc(s.text_image, @intCast(4 *% width *% height)));
    const surface = pc.cairo_image_surface_create_for_data(s.text_image, pc.CAIRO_FORMAT_ARGB32, width, height, width * 4);
    const cr = pc.cairo_create(surface);
    pc.cairo_set_operator(cr, pc.CAIRO_OPERATOR_CLEAR);
    pc.cairo_paint(cr);
    pc.cairo_set_operator(cr, pc.CAIRO_OPERATOR_OVER);
    pc.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    pc.cairo_save(cr);
    pc.pango_cairo_show_layout(cr, s.layout);
    pc.cairo_restore(cr);
    pc.cairo_set_operator(cr, pc.CAIRO_OPERATOR_DEST_OVER);
    pc.cairo_set_source_surface(cr, shadow, 0.0, 0.0);
    pc.cairo_paint(cr);
    pc.cairo_destroy(cr);
    pc.cairo_surface_destroy(shadow);
    pc.cairo_surface_destroy(surface);
    s.image_width = width;
    s.image_height = height;
}

fn checkArgb(s: *Self) void {
    const peer = c.gst_pad_get_allowed_caps(s.srcpad);
    if (peer == null) return;
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(peer)) : (i += 1) {
        const st = c.gst_caps_get_structure(peer, i);
        if (c.gst_structure_has_name(st, "video/x-raw") == 0) continue;
        const fmt = c.gst_structure_get_string(st, "format");
        if (fmt == null) continue;
        const info = c.gst_video_format_get_info(c.gst_video_format_from_string(fmt));
        if (info == null) continue;
        s.use_ARGB = @intFromBool(info[0].flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0);
    }
    c.gst_caps_unref(peer);
}

fn srcSetcaps(s: *Self, caps: [*c]c.GstCaps) bool {
    const st = c.gst_caps_get_structure(caps, 0);
    var w: c.gint = 0;
    var h: c.gint = 0;
    _ = c.gst_structure_get_int(st, "width", &w);
    _ = c.gst_structure_get_int(st, "height", &h);
    if (w >= s.image_width and h >= s.image_height) {
        s.width = w;
        s.height = h;
    }
    checkArgb(s);
    return c.gst_pad_push_event(s.srcpad, c.gst_event_new_caps(caps)) != 0;
}

fn fixate(s: *Self, caps_in: [*c]c.GstCaps) [*c]c.GstCaps {
    var caps: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(c.gst_caps_truncate(caps_in))));
    const st = c.gst_caps_get_structure(caps, 0);
    _ = c.gst_structure_fixate_field_nearest_int(st, "width", @max(s.image_width, 720));
    _ = c.gst_structure_fixate_field_nearest_int(st, "height", @max(s.image_height + s.ypad, 576));
    caps = c.gst_caps_fixate(caps);
    return caps;
}

fn unpremultiply(a: u8, x: u8) u8 {
    if (a == 0) return 0;
    const v = (@as(c_int, x) * 255 + @divTrunc(@as(c_int, a), 2));
    return @intCast(@min(@divTrunc(v, a), 255));
}

fn clamp255(v: c_int) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn toAyuv(s: *Self, pix: [*]u8, xpos: c.gint, ypos: c.gint, stride: c.gint) void {
    var y: c.gint = 0;
    while (y < s.image_height and ypos + y < s.height) : (y += 1) {
        var p = pix + @as(usize, @intCast((ypos + y) * stride + xpos * 4));
        var bitp = s.text_image + @as(usize, @intCast(y * s.image_width * 4));
        var n: c.gint = 0;
        while (n < s.image_width and n < s.width) : (n += 1) {
            const b0 = bitp[B];
            const g0 = bitp[G];
            const r0 = bitp[R];
            const a = bitp[A];
            bitp += 4;
            const b: c_int = unpremultiply(a, b0);
            const g: c_int = unpremultiply(a, g0);
            const r: c_int = unpremultiply(a, r0);
            p[0] = a;
            p[1] = clamp255(((19595 * r) >> 16) + ((38470 * g) >> 16) + ((7471 * b) >> 16));
            p[2] = clamp255(-((11059 * r) >> 16) - ((21709 * g) >> 16) + ((32768 * b) >> 16) + 128);
            p[3] = clamp255(((32768 * r) >> 16) - ((27439 * g) >> 16) - ((5329 * b) >> 16) + 128);
            p += 4;
        }
    }
}

fn toArgb(s: *Self, pix: [*]u8, xpos: c.gint, ypos: c.gint, stride: c.gint) void {
    var i: c.gint = 0;
    while (i < s.image_height and ypos + i < s.height) : (i += 1) {
        var p = pix + @as(usize, @intCast((ypos + i) * stride + xpos * 4));
        var bitp = s.text_image + @as(usize, @intCast(i * s.image_width * 4));
        var j: c.gint = 0;
        while (j < s.image_width and j < s.width) : (j += 1) {
            p[0] = bitp[A];
            p[1] = bitp[R];
            p[2] = bitp[G];
            p[3] = bitp[B];
            const a = p[0];
            p[3] = unpremultiply(a, p[3]);
            p[2] = unpremultiply(a, p[2]);
            p[1] = unpremultiply(a, p[1]);
            bitp += 4;
            p += 4;
        }
    }
}

fn renegotiate(s: *Self) c.GstFlowReturn {
    checkArgb(s);
    const padcaps = c.gst_pad_query_caps(s.srcpad, null);
    var caps = c.gst_pad_peer_query_caps(s.srcpad, padcaps);
    c.gst_caps_unref(padcaps);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (caps == null or c.gst_caps_is_empty(caps) != 0) {
        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, null, FILE, "gst_text_render_renegotiate", 488);
        ret = c.GST_FLOW_ERROR;
    } else {
        caps = fixate(s, caps);
        if (!srcSetcaps(s, caps)) {
            cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, null, FILE, "gst_text_render_renegotiate", 496);
            ret = c.GST_FLOW_ERROR;
        }
    }
    if (caps != null) c.gst_caps_unref(caps);
    return ret;
}

fn pushSegment(s: *Self) void {
    if (s.segment_event != null) {
        _ = c.gst_pad_push_event(s.srcpad, s.segment_event);
        s.segment_event = null;
    }
}

fn chain(_: ?*c.GstPad, parent: ?*c.GstObject, inbuf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(parent);
    defer c.gst_buffer_unref(inbuf);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(inbuf, &map, c.GST_MAP_READ);
    const data = map.data;
    var size = map.size;
    while (size > 0 and (data[size - 1] == '\r' or data[size - 1] == '\n' or data[size - 1] == 0)) size -= 1;
    if (s.have_pango_markup != 0) pc.pango_layout_set_markup(s.layout, data, @intCast(size)) else pc.pango_layout_set_text(s.layout, data, @intCast(size));
    render(s);
    c.gst_buffer_unmap(inbuf, &map);
    if (c.gst_pad_check_reconfigure(s.srcpad) != 0 or c.gst_pad_has_current_caps(s.srcpad) == 0) {
        const r = renegotiate(s);
        if (r != c.GST_FLOW_OK) return r;
    }
    pushSegment(s);
    const total: usize = @intCast(s.width * s.height * 4);
    const out = c.gst_buffer_new_allocate(null, total, null);
    _ = c.gst_buffer_copy_into(out, inbuf, c.GST_BUFFER_COPY_TIMESTAMPS, 0, std.math.maxInt(usize));
    _ = c.gst_buffer_map(out, &map, c.GST_MAP_WRITE);
    const pix: [*]u8 = @ptrCast(map.data);
    if (s.use_ARGB != 0) {
        @memset(pix[0..total], 0);
    } else {
        var n: usize = 0;
        while (n < total / 4) : (n += 1) {
            pix[n * 4] = 0;
            pix[n * 4 + 1] = 0;
            pix[n * 4 + 2] = 128;
            pix[n * 4 + 3] = 128;
        }
    }
    const xpos: c.gint = switch (s.halign) {
        0 => s.xpad,
        1 => @divTrunc(s.width - s.image_width, 2),
        2 => s.width - s.image_width - s.xpad,
        else => 0,
    };
    const ypos: c.gint = switch (s.valign) {
        1 => s.height - s.image_height - s.ypad,
        0 => s.height - (s.image_height + s.ypad),
        else => s.ypad,
    };
    if (s.text_image != null) {
        if (s.use_ARGB != 0) toArgb(s, pix, xpos, ypos, s.width * 4) else toAyuv(s, pix, xpos, ypos, s.width * 4);
    }
    c.gst_buffer_unmap(out, &map);
    return c.gst_pad_push(s.srcpad, out);
}

fn event(pad: ?*c.GstPad, parent: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(parent);
    switch (e[0].type) {
        c.GST_EVENT_SEGMENT => {
            if (c.gst_pad_has_current_caps(s.srcpad) != 0) return c.gst_pad_push_event(s.srcpad, e);
            _ = c.gst_mini_object_replace(@ptrCast(&s.segment_event), @ptrCast(e));
            c.gst_event_unref(e);
            return 1;
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            const fmt = c.gst_structure_get_string(c.gst_caps_get_structure(caps, 0), "format");
            s.have_pango_markup = @intFromBool(std.mem.orderZ(u8, fmt, "pango-markup") == .eq);
            c.gst_event_unref(e);
            return 1;
        },
        c.GST_EVENT_GAP => {
            if (c.gst_pad_has_current_caps(s.srcpad) == 0) {
                if (renegotiate(s) != c.GST_FLOW_OK) {
                    c.gst_event_unref(e);
                    return 0;
                }
            }
            pushSegment(s);
            return c.gst_pad_event_default(pad, parent, e);
        },
        else => return c.gst_pad_event_default(pad, parent, e),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    _ = c.gst_mini_object_replace(@ptrCast(&s.segment_event), null);
    c.g_free(s.text_image);
    if (s.layout != null) pc.g_object_unref(s.layout);
    if (s.pango_context != null) pc.g_object_unref(s.pango_context);
    parent_obj.finalize.?(o);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    var t = c.gst_static_pad_template_get(&sink_t);
    s.sinkpad = c.gst_pad_new_from_template(t, "sink");
    c.gst_object_unref(t);
    c.gst_pad_set_chain_function_full(s.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(s.sinkpad, event, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.sinkpad);
    t = c.gst_static_pad_template_get(&src_t);
    s.srcpad = c.gst_pad_new_from_template(t, "src");
    c.gst_object_unref(t);
    _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
    const fontmap = pc.pango_cairo_font_map_new();
    s.pango_context = pc.pango_font_map_create_context(fontmap);
    pc.g_object_unref(fontmap);
    s.line_align = pc.PANGO_ALIGN_CENTER;
    s.layout = pc.pango_layout_new(s.pango_context);
    pc.pango_layout_set_alignment(s.layout, @intCast(s.line_align));
    s.halign = 1;
    s.valign = 0;
    s.xpad = 25;
    s.ypad = 25;
    s.width = 720;
    s.height = 576;
    s.use_ARGB = 0;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.valignment) => s.valign = c.g_value_get_enum(v),
        @intFromEnum(Prop.halignment) => s.halign = c.g_value_get_enum(v),
        @intFromEnum(Prop.line_alignment) => {
            s.line_align = c.g_value_get_enum(v);
            pc.pango_layout_set_alignment(s.layout, @intCast(s.line_align));
        },
        @intFromEnum(Prop.xpad) => s.xpad = c.g_value_get_int(v),
        @intFromEnum(Prop.ypad) => s.ypad = c.g_value_get_int(v),
        @intFromEnum(Prop.font_desc) => {
            const desc = pc.pango_font_description_from_string(c.g_value_get_string(v));
            if (desc != null) {
                cm.lock(s);
                pc.pango_layout_set_font_description(s.layout, desc);
                adjustFont(s, desc);
                pc.pango_font_description_free(desc);
                render(s);
                cm.unlock(s);
            }
        },
        else => {},
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.valignment) => c.g_value_set_enum(v, s.valign),
        @intFromEnum(Prop.halignment) => c.g_value_set_enum(v, s.halign),
        @intFromEnum(Prop.line_alignment) => c.g_value_set_enum(v, s.line_align),
        @intFromEnum(Prop.xpad) => c.g_value_set_int(v, s.xpad),
        @intFromEnum(Prop.ypad) => c.g_value_set_int(v, s.ypad),
        else => cm.warnInvalid(FILE, o, id, spec, 815),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_obj = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Text renderer", "Filter/Editor/Video", "Renders a text string to an image bitmap", "David Schleef <ds@schleef.org>, GStreamer maintainers <gstreamer-devel@lists.freedesktop.org>");
    c.g_object_class_install_property(oc, @intFromEnum(Prop.font_desc), c.g_param_spec_string("font-desc", "font description", "Pango font description of font to be used for rendering. See documentation of pango_font_description_from_string for syntax.", "", c.G_PARAM_WRITABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.valignment), c.g_param_spec_enum("valignment", "vertical alignment", "Vertical alignment of the text", valignType(), 0, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.halignment), c.g_param_spec_enum("halignment", "horizontal alignment", "Horizontal alignment of the text", halignType(), 1, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.xpad), c.g_param_spec_int("xpad", "horizontal paddding", "Horizontal paddding when using left/right alignment", 0, std.math.maxInt(c.gint), 25, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.ypad), c.g_param_spec_int("ypad", "vertical padding", "Vertical padding when using top/bottom alignment", 0, std.math.maxInt(c.gint), 25, cm.RW));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.line_alignment), c.g_param_spec_enum("line-alignment", "line alignment", "Alignment of text lines relative to each other.", lineType(), pc.PANGO_ALIGN_CENTER, cm.RW));
    c.gst_type_mark_as_plugin_api(halignType(), 0);
    c.gst_type_mark_as_plugin_api(valignType(), 0);
    c.gst_type_mark_as_plugin_api(lineType(), 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstTextRender", Class, Self, classInit, init);
        }
    }.f);
}
