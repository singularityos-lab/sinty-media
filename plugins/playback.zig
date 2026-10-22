const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const streamsynchronizer = @import("playback/streamsynchronizer.zig");
const playsink = @import("playback/playsink.zig");
const subtitleoverlay = @import("playback/subtitleoverlay.zig");
const urisourcebin = @import("playback/urisourcebin.zig");
const parsebin = @import("playback/parsebin.zig");
const decodebin3 = @import("playback/decodebin3.zig");
const uridecodebin3 = @import("playback/uridecodebin3.zig");
const playbin3 = @import("playback/playbin3.zig");
const decodebin2 = @import("playback/decodebin2.zig");

var init_done: usize = 0;

fn elementInit() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        c.gst_pb_utils_init();
        _ = c.bindtextdomain("gst-plugins-base-1.0", "/usr/share/locale");
        _ = c.bind_textdomain_codeset("gst-plugins-base-1.0", "UTF-8");
        c.g_once_init_leave(&init_done, 1);
    }
}

fn add(p: ?*c.GstPlugin, name: [*c]const u8, rank: c.guint, t: c.GType) bool {
    elementInit();
    return c.gst_element_register(p, name, rank, t) != 0;
}

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    var ok = false;
    ok = add(p, "playbin3", c.GST_RANK_NONE, playbin3.getType()) or ok;
    ok = add(p, "playsink", c.GST_RANK_NONE, playsink.getType()) or ok;
    ok = add(p, "subtitleoverlay", c.GST_RANK_NONE, subtitleoverlay.getType()) or ok;
    ok = add(p, "decodebin", c.GST_RANK_NONE, decodebin2.getType()) or ok;
    ok = add(p, "decodebin3", c.GST_RANK_NONE, decodebin3.getType()) or ok;
    ok = add(p, "uridecodebin3", c.GST_RANK_NONE, uridecodebin3.getType()) or ok;
    ok = add(p, "parsebin", c.GST_RANK_NONE, parsebin.getType()) or ok;
    ok = add(p, "urisourcebin", c.GST_RANK_NONE, urisourcebin.getType()) or ok;
    ok = add(p, "streamsynchronizer", c.GST_RANK_NONE, streamsynchronizer.getType()) or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "playback",
    .description = "various playback elements",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_playback_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_playback_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
