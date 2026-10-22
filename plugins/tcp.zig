const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const socketsrc = @import("tcp/socketsrc.zig");
const client = @import("tcp/client.zig");
const serversrc = @import("tcp/serversrc.zig");
const socketsink = @import("tcp/socketsink.zig");
const fdsink = @import("tcp/fdsink.zig");

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    var ok = socketsrc.register(p);
    ok = client.registerSink(p) or ok;
    ok = client.registerSrc(p) or ok;
    ok = socketsink.registerServer(p) or ok;
    ok = serversrc.register(p) or ok;
    ok = fdsink.register(p) or ok;
    ok = socketsink.register(p) or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "tcp",
    .description = "transfer data over the network via TCP",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_tcp_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_tcp_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
