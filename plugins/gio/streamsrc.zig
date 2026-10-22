const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const gio = @import("element.zig");
const base = @import("basesrc.zig");

const FILE = "../gst/gio/gstgiostreamsrc.c";
const PROP_STREAM = 1;

const Self = extern struct {
    parent: base.Self,
    stream: ?*c.GInputStream,
};

const Class = extern struct {
    parent: base.Class,
};

var once: cm.Once = .{};
var parent: ?*base.Class = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.stream) |x| c.g_object_unref(x);
    s.stream = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id != PROP_STREAM) return cm.warnInvalid(FILE, o, id, spec, 161);
    const st = @as(*c.GstElement, @ptrCast(@alignCast(s))).current_state;
    if (st == c.GST_STATE_PLAYING or st == c.GST_STATE_PAUSED) return;
    const stream = c.g_value_dup_object(v);
    if (s.stream) |x| c.g_object_unref(x);
    s.stream = @ptrCast(@alignCast(stream));
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != PROP_STREAM) return cm.warnInvalid(FILE, o, id, spec, 177);
    c.g_value_set_object(v, me(o).stream);
}

fn getStream(b: *base.Self) callconv(.c) ?*c.GInputStream {
    const s = me(b);
    return if (s.stream) |x| @ptrCast(@alignCast(c.g_object_ref(x))) else null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("gio_stream_src", 0, "GIO source");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_STREAM, c.g_param_spec_object("stream", "Stream", "Stream to read from", c.g_input_stream_get_type(), cm.RW));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "GIO stream source", "Source", "Read from any GIO stream", "Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    const gc: *base.Class = @ptrCast(@alignCast(k));
    gc.get_stream = getStream;
}

fn init(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(base.getType(), "GstGioStreamSrc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    gio.pluginInit(p);
    return c.gst_element_register(p, "giostreamsrc", c.GST_RANK_NONE, getType()) != 0;
}
