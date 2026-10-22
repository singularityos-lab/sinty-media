const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const textoverlay = @import("pango/textoverlay.zig");
const timeoverlay = @import("pango/timeoverlay.zig");
const clockoverlay = @import("pango/clockoverlay.zig");
const textrender = @import("pango/textrender.zig");

var init_once: usize = 0;

fn elementInit() void {
    if (c.g_once_init_enter(&init_once) != 0) {
        _ = c._gst_debug_category_new("pango", 0, "Pango elements");
        c.g_once_init_leave(&init_once, 1);
    }
}

fn reg(p: ?*c.GstPlugin, name: [*:0]const u8, t: c.GType) bool {
    elementInit();
    return c.gst_element_register(p, name, c.GST_RANK_NONE, t) != 0;
}

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    var ok = false;
    ok = reg(p, "textoverlay", textoverlay.getType()) or ok;
    ok = reg(p, "timeoverlay", timeoverlay.getType()) or ok;
    ok = reg(p, "clockoverlay", clockoverlay.getType()) or ok;
    ok = reg(p, "textrender", textrender.getType()) or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "pango",
    .description = "Pango-based text rendering and overlay",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_pango_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_pango_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
