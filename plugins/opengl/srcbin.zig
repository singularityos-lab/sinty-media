const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const PROP_SRC = 1;

pub const Self = extern struct {
    parent: c.GstBin,
    srcpad: ?*c.GstPad,
    src: [*c]c.GstElement,
    convert: [*c]c.GstElement,
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

fn connect(s: *Self) bool {
    _ = c.gst_object_set_name(@ptrCast(s.src), "src");
    var ok = c.gst_bin_add(&s.parent, s.src) != 0;
    ok = c.gst_element_link_pads(s.src, "src", s.convert, "sink") != 0 and ok;
    return ok;
}

fn setSrc(s: *Self, e: [*c]c.GstElement) bool {
    if (!cm.that(c.g_type_check_instance_is_a(@ptrCast(e), c.gst_element_get_type()) != 0, "gst_gl_src_bin_set_src", "GST_IS_ELEMENT (src)")) return false;
    if (s.src != null) {
        _ = c.gst_element_set_locked_state(s.src, 1);
        _ = c.gst_bin_remove(&s.parent, s.src);
        _ = c.gst_element_set_state(s.src, c.GST_STATE_NULL);
        c.gst_object_unref(s.src);
        s.src = null;
    }
    s.src = e;
    _ = c.gst_object_ref_sink(e);
    if (!connect(s)) {
        c.gst_object_unref(s.src);
        s.src = null;
        return false;
    }
    return true;
}

pub fn finishInit(p: anytype) void {
    const s = me(p);
    const e = if (klass(s).create_element) |f| f() else null;
    if (e != null) _ = setSrc(s, e);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    if (me(o).src != null) c.gst_object_unref(me(o).src);
    parent_obj.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id == PROP_SRC) {
        _ = setSrc(s, @ptrCast(@alignCast(c.g_value_get_object(v))));
    } else if (s.src != null) c.g_object_set_property(@ptrCast(s.src), spec[0].name, v);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id == PROP_SRC) {
        c.g_value_set_object(v, s.src);
    } else if (s.src != null) c.g_object_get_property(@ptrCast(s.src), spec[0].name, v);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY and s.src == null) {
        if (klass(s).create_element) |f| s.src = f();
        if (s.src == null) {
            c.g_signal_emit(e, sig_create, 0, &s.src);
            if (s.src != null and c.g_object_is_floating(s.src) != 0) _ = c.gst_object_ref_sink(s.src);
        }
        if (s.src == null) return c.GST_STATE_CHANGE_FAILURE;
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
    c.g_object_class_install_property(oc, PROP_SRC, c.g_param_spec_object("src", "GL src element", "The GL src chain to use", c.gst_element_get_type(), cm.MUTABLE_READY | cm.RW));
    sig_create = c.g_signal_new("create-element", c.G_TYPE_FROM_CLASS(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.gst_element_get_type(), 0);
    c.gst_element_class_set_static_metadata(ec, "GL Src Bin", "Source/Video", "Infrastructure to process GL textures", "Matthew Waters <matthew@centricular.com>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.download = c.gst_element_factory_make("gldownload", null);
    s.convert = c.gst_element_factory_make("glcolorconvert", null);
    _ = c.gst_bin_add(&s.parent, s.download);
    _ = c.gst_bin_add(&s.parent, s.convert);
    _ = c.gst_element_link_pads(s.convert, "src", s.download, "sink");
    const p = c.gst_element_get_static_pad(s.download, "src");
    if (p != null) {
        s.srcpad = c.gst_ghost_pad_new("src", p);
        _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
        c.gst_object_unref(p);
    }
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_bin_get_type(), "GstGLSrcBin", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("glsrcbin", 0, "OpenGL Video Src Bin");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glsrcbin", c.GST_RANK_NONE, getType());
}
