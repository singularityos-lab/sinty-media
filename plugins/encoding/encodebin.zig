const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const base = @import("basebin.zig");

const Class = extern struct {
    parent: base.Class,
};

var single_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var multi_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var once: cm.Once = .{};
var once2: cm.Once = .{};
var init_done: ?*anyopaque = null;

fn elementInit() void {
    if (c.g_once_init_enter_pointer(@ptrCast(&init_done)) != 0) {
        _ = c.bindtextdomain("gst-plugins-base-1.0", "/usr/share/locale");
        _ = c.bind_textdomain_codeset("gst-plugins-base-1.0", "UTF-8");
        c.g_once_init_leave_pointer(@ptrCast(&init_done), @ptrFromInt(1));
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &single_t);
    c.gst_element_class_set_static_metadata(ec, "Encoder Bin", "Generic/Bin/Encoder", "Convenience encoding/muxing element", "Edward Hervey <edward.hervey@collabora.co.uk>");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = base.me(inst);
    const templ = c.gst_static_pad_template_get(&single_t);
    s.srcpad = c.gst_ghost_pad_new_no_target_from_template("src", templ);
    c.gst_object_unref(templ);
    _ = c.gst_pad_set_active(s.srcpad, 1);
    _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
}

fn class2Init(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.gst_element_class_add_static_pad_template(@ptrCast(@alignCast(k)), &multi_t);
}

fn init2(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(base.getType(), "GstEncodeBin", Class, base.Self, classInit, init);
        }
    }.f);
}

pub fn getType2() c.GType {
    return once2.get(struct {
        fn f() c.GType {
            return cm.register(base.getType(), "GstEncodeBin2", Class, base.Self, class2Init, init2);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    elementInit();
    return c.gst_element_register(p, "encodebin", c.GST_RANK_NONE, getType()) != 0;
}

pub fn register2(p: ?*c.GstPlugin) bool {
    elementInit();
    return c.gst_element_register(p, "encodebin2", c.GST_RANK_NONE, getType2()) != 0;
}
