const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");

const elements = .{
    @import("core/capsfilter.zig"),
    @import("core/fakesrc.zig"),
    @import("core/identity.zig"),
    @import("core/queue.zig"),
    @import("core/tee.zig"),
    @import("core/filesrc.zig"),
    @import("core/filesink.zig"),
    @import("core/fakesink.zig"),
};

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    var ok = false;
    inline for (elements) |e| ok = e.register(p) or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "coreelements",
    .description = "GStreamer core elements",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gstreamer",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_coreelements_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_coreelements_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
