const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const pipewire = @import("pipewire/src.zig");

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    return @intFromBool(pipewire.register(p));
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "pipewire",
    .description = "PipeWire plugin",
    .plugin_init = pluginInit,
    .version = "1.6.2",
    .license = "MIT/X11",
    .source = "pipewire",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_pipewire_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_pipewire_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
