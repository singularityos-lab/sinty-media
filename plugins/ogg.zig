const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const demux = @import("ogg/demux.zig");
const mux = @import("ogg/mux.zig");
const parse = @import("ogg/parse.zig");

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    var ok = false;
    ok = demux.register(p) or ok;
    ok = mux.register(p) or ok;
    ok = parse.registerOgm(p) or ok;
    ok = parse.registerOggParse(p) or ok;
    ok = parse.registerAvi(p) or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "ogg",
    .description = "ogg stream manipulation (info about ogg: http://xiph.org)",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_ogg_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_ogg_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
