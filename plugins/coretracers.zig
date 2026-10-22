const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");

const tracers = .{
    .{ "dots", @import("tracers/dots.zig") },
    .{ "latency", @import("tracers/latency.zig") },
    .{ "log", @import("tracers/log.zig") },
    .{ "rusage", @import("tracers/rusage.zig") },
    .{ "stats", @import("tracers/stats.zig") },
    .{ "leaks", @import("tracers/leaks.zig") },
    .{ "factories", @import("tracers/factories.zig") },
};

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    inline for (tracers) |t| {
        if (c.gst_tracer_register(p, t[0], t[1].getType()) == 0) return 0;
    }
    return 1;
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "coretracers",
    .description = "GStreamer core tracers",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gstreamer",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_coretracers_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_coretracers_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
