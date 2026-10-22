const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const audio = @import("rawparse/audio.zig");
const video = @import("rawparse/video.zig");
const unaligned = @import("rawparse/unaligned.zig");

const UnalignedAudio = unaligned.Bin("unalignedaudioparse", "GstUnalignedAudioParse", "rawaudioparse", audio.UNALIGNED_CAPS, "audio/x-raw, format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout = (string) { interleaved, non-interleaved }", "Codec/Parser/Bin/Audio", "Parse unaligned raw audio data", "Unaligned raw audio parser");
const UnalignedVideo = unaligned.Bin("unalignedvideoparse", "GstUnalignedVideoParse", "rawvideoparse", video.UNALIGNED_CAPS, video.RAW_CAPS, "Codec/Parser/Bin/Video", "Parse unaligned raw video data", "Unaligned raw video parser");

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    var ok = UnalignedAudio.register(p);
    ok = UnalignedVideo.register(p) or ok;
    ok = audio.register(p) or ok;
    ok = video.register(p) or ok;
    return @intFromBool(ok);
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "rawparse",
    .description = "Parses byte streams into raw frames",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_rawparse_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_rawparse_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
