const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const src = @import("v4l2/src.zig");
const provider = @import("v4l2/provider.zig");

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    var paths = [_][*c]const u8{ "/dev", "/dev/v4l2", null };
    var names = [_][*c]const u8{ "video", null };
    c.gst_plugin_add_dependency(p, null, &paths, &names, c.GST_PLUGIN_DEPENDENCY_FLAG_FILE_NAME_IS_PREFIX);
    var ok = src.register(p);
    ok = provider.register(p) or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "video4linux2",
    .description = "elements for Video 4 Linux",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-good",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_video4linux2_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_video4linux2_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
