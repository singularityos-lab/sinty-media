const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    var ok = c.gst_element_register(p, "appsrc", c.GST_RANK_NONE, c.gst_app_src_get_type()) != 0;
    ok = c.gst_element_register(p, "appsink", c.GST_RANK_NONE, c.gst_app_sink_get_type()) != 0 or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "app",
    .description = "Elements used to communicate with applications",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_app_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_app_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
