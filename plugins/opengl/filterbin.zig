const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglfilterbin.c";
const PROP_FILTER = 1;

pub const Self = extern struct {
    parent: c.GstBin,
    srcpad: ?*c.GstPad,
    sinkpad: ?*c.GstPad,
    upload: [*c]c.GstElement,
    in_convert: [*c]c.GstElement,
    filter: [*c]c.GstElement,
    out_convert: [*c]c.GstElement,
    download: [*c]c.GstElement,
};

pub const Class = extern struct {
    parent: c.GstBinClass,
    create_element: ?*const fn () callconv(.c) [*c]c.GstElement,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "video/x-raw(ANY)");
var once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var sig_create: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn klass(p: anytype) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class));
}

fn bin(s: *Self) [*c]c.GstBin {
    return &s.parent;
}

fn connect(s: *Self) bool {
    _ = c.gst_object_set_name(@ptrCast(s.filter), "filter");
    var ok = c.gst_bin_add(bin(s), s.filter) != 0;
    ok = c.gst_element_link_pads(s.in_convert, "src", s.filter, "sink") != 0 and ok;
    ok = c.gst_element_link_pads(s.filter, "src", s.out_convert, "sink") != 0 and ok;
    return ok;
}

fn setFilter(s: *Self, f: [*c]c.GstElement) bool {
    if (!cm.that(c.g_type_check_instance_is_a(@ptrCast(f), c.gst_element_get_type()) != 0, "gst_gl_filter_bin_set_filter", "GST_IS_ELEMENT (filter)")) return false;
    if (s.filter != null) {
        _ = c.gst_element_set_locked_state(s.filter, 1);
        _ = c.gst_bin_remove(bin(s), s.filter);
        _ = c.gst_element_set_state(s.filter, c.GST_STATE_NULL);
        c.gst_object_unref(s.filter);
        s.filter = null;
    }
    s.filter = f;
    _ = c.gst_object_ref_sink(f);
    if (!connect(s)) {
        c.gst_object_unref(s.filter);
        s.filter = null;
        return false;
    }
    return true;
}

pub fn finishInit(p: anytype) void {
    const s = me(p);
    const e = if (klass(s).create_element) |f| f() else null;
    if (e != null) _ = setFilter(s, e);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.filter != null) c.gst_object_unref(s.filter);
    parent_obj.finalize.?(o);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_FILTER) {
        c.g_value_set_object(v, me(o).filter);
    } else cm.warnInvalid(FILE, o, id, spec, 236);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_FILTER) {
        _ = setFilter(me(o), @ptrCast(@alignCast(c.g_value_get_object(v))));
    } else cm.warnInvalid(FILE, o, id, spec, 252);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY and s.filter == null) {
        if (klass(s).create_element) |f| s.filter = f();
        if (s.filter == null) {
            c.g_signal_emit(e, sig_create, 0, &s.filter);
            if (s.filter != null and c.g_object_is_floating(s.filter) != 0) _ = c.gst_object_ref_sink(s.filter);
        }
        if (s.filter == null) return c.GST_STATE_CHANGE_FAILURE;
        if (!connect(s)) return c.GST_STATE_CHANGE_FAILURE;
    }
    return parent_el.change_state.?(e, t);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const caps = c.gst_gl_upload_get_input_template_caps();
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.g_object_class_install_property(oc, PROP_FILTER, c.g_param_spec_object("filter", "GL filter element", "The GL filter chain to use", c.gst_element_get_type(), cm.MUTABLE_READY | cm.RW));
    sig_create = c.g_signal_new("create-element", c.G_TYPE_FROM_CLASS(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.gst_element_get_type(), 0);
    c.gst_element_class_set_static_metadata(ec, "GL Filter Bin", "Filter/Video", "Infrastructure to process GL textures", "Matthew Waters <matthew@centricular.com>");
}

fn ghost(s: *Self, e: [*c]c.GstElement, comptime name: [:0]const u8) ?*c.GstPad {
    const p = c.gst_element_get_static_pad(e, name.ptr);
    if (p == null) return null;
    defer c.gst_object_unref(p);
    const g = c.gst_ghost_pad_new(name.ptr, p);
    _ = c.gst_element_add_pad(@ptrCast(s), g);
    return g;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.upload = c.gst_element_factory_make("glupload", null);
    s.in_convert = c.gst_element_factory_make("glcolorconvert", null);
    s.out_convert = c.gst_element_factory_make("glcolorconvert", null);
    s.download = c.gst_element_factory_make("gldownload", null);
    _ = c.gst_bin_add(bin(s), s.upload);
    _ = c.gst_bin_add(bin(s), s.in_convert);
    _ = c.gst_bin_add(bin(s), s.out_convert);
    _ = c.gst_bin_add(bin(s), s.download);
    _ = c.gst_element_link_pads(s.upload, "src", s.in_convert, "sink");
    _ = c.gst_element_link_pads(s.out_convert, "src", s.download, "sink");
    s.srcpad = ghost(s, s.download, "src");
    s.sinkpad = ghost(s, s.upload, "sink");
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_bin_get_type(), "GstGLFilterBin", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("glfilterbin", 0, "glfilterbin element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glfilterbin", c.GST_RANK_NONE, getType());
}
