const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const base = @import("base.zig");

const Self = extern struct {
    parent: base.Self,
};

var text_t = cm.staticTemplate("text_sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "text/x-raw, format = { pango-markup, utf8 }");
var once: cm.Once = .{};

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &text_t);
    c.gst_element_class_set_static_metadata(ec, "Text overlay", "Filter/Editor/Video", "Adds text strings on top of a video buffer", "David Schleef <ds@schleef.org>, Zeeshan Ali <zeeshan.ali@nokia.com>");
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(base.getType(), "GstTextOverlay", base.Class, Self, classInit, null);
        }
    }.f);
}
