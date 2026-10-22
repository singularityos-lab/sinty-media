const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const el = @import("opengl/element.zig");
const upload = @import("opengl/upload.zig");
const download = @import("opengl/download.zig");
const colorconvert = @import("opengl/colorconvert.zig");
const colorbalance = @import("opengl/colorbalance.zig");
const filterbin = @import("opengl/filterbin.zig");
const sinkbin = @import("opengl/sinkbin.zig");
const srcbin = @import("opengl/srcbin.zig");
const mixerbin = @import("opengl/mixerbin.zig");
const colorscale = @import("opengl/colorscale.zig");
const testsrc = @import("opengl/testsrc.zig");
const filtercube = @import("opengl/filtercube.zig");
const effects = @import("opengl/effects.zig");
const filtershader = @import("opengl/filtershader.zig");
const filterapp = @import("opengl/filterapp.zig");
const deinterlace = @import("opengl/deinterlace.zig");
const viewconvert = @import("opengl/viewconvert.zig");
const stereosplit = @import("opengl/stereosplit.zig");
const stereomix = @import("opengl/stereomix.zig");
const alpha = @import("opengl/alpha.zig");
const overlaycompositor = @import("opengl/overlaycompositor.zig");
const mosaic = @import("opengl/mosaic.zig");
const filterglass = @import("opengl/filterglass.zig");
const transformation = @import("opengl/transformation.zig");
const videoflip = @import("opengl/videoflip.zig");
const differencematte = @import("opengl/differencematte.zig");
const overlay = @import("opengl/overlay.zig");
const videomixer = @import("opengl/videomixer.zig");
const imagesink = @import("opengl/imagesink.zig");

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    el.init();
    var ok = false;
    ok = imagesink.register(p) or ok;
    ok = upload.register(p) or ok;
    ok = download.register(p) or ok;
    ok = colorconvert.register(p) or ok;
    ok = colorbalance.register(p) or ok;
    ok = filterbin.register(p) or ok;
    ok = sinkbin.register(p) or ok;
    ok = srcbin.register(p) or ok;
    ok = mixerbin.register(p) or ok;
    ok = filtercube.register(p) or ok;
    ok = transformation.register(p) or ok;
    ok = videoflip.register(p) or ok;
    ok = effects.register(p) or ok;
    ok = colorscale.register(p) or ok;
    ok = videomixer.register(p) or ok;
    ok = filtershader.register(p) or ok;
    ok = filterapp.register(p) or ok;
    ok = viewconvert.register(p) or ok;
    ok = stereosplit.register(p) or ok;
    ok = stereomix.register(p) or ok;
    ok = deinterlace.register(p) or ok;
    ok = alpha.register(p) or ok;
    ok = overlaycompositor.register(p) or ok;
    ok = overlay.register(p) or ok;
    ok = filterglass.register(p) or ok;
    ok = mosaic.register(p) or ok;
    ok = differencematte.register(p) or ok;
    ok = testsrc.register(p) or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "opengl",
    .description = "OpenGL plugin",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_opengl_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_opengl_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
