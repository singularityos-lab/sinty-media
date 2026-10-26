const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const vp9dec = @import("va/vp9dec.zig");

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    c.gst_plugin_add_dependency_simple(p, null, "/dev/dri", "renderD", c.GST_PLUGIN_DEPENDENCY_FLAG_FILE_NAME_IS_PREFIX);
    _ = vp9dec.register(p);
    return 1;
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "va",
    .description = "VA-API codecs plugin",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-bad",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_va_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_va_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
