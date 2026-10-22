const cm = @import("../common.zig");
const c = cm.c;

pub const VIDEO: c.guint = 1 << 0;
pub const AUDIO: c.guint = 1 << 1;
pub const TEXT: c.guint = 1 << 2;
pub const VIS: c.guint = 1 << 3;
pub const SOFT_VOLUME: c.guint = 1 << 4;
pub const NATIVE_AUDIO: c.guint = 1 << 5;
pub const NATIVE_VIDEO: c.guint = 1 << 6;
pub const DOWNLOAD: c.guint = 1 << 7;
pub const BUFFERING: c.guint = 1 << 8;
pub const DEINTERLACE: c.guint = 1 << 9;
pub const SOFT_COLORBALANCE: c.guint = 1 << 10;
pub const FORCE_FILTERS: c.guint = 1 << 11;
pub const FORCE_SW_DECODERS: c.guint = 1 << 12;

const values = [_]c.GFlagsValue{
    .{ .value = VIDEO, .value_name = "Render the video stream", .value_nick = "video" },
    .{ .value = AUDIO, .value_name = "Render the audio stream", .value_nick = "audio" },
    .{ .value = TEXT, .value_name = "Render subtitles", .value_nick = "text" },
    .{ .value = VIS, .value_name = "Render visualisation when no video is present", .value_nick = "vis" },
    .{ .value = SOFT_VOLUME, .value_name = "Use software volume", .value_nick = "soft-volume" },
    .{ .value = NATIVE_AUDIO, .value_name = "Only use native audio formats", .value_nick = "native-audio" },
    .{ .value = NATIVE_VIDEO, .value_name = "Only use native video formats", .value_nick = "native-video" },
    .{ .value = DOWNLOAD, .value_name = "Attempt progressive download buffering", .value_nick = "download" },
    .{ .value = BUFFERING, .value_name = "Buffer demuxed/parsed data", .value_nick = "buffering" },
    .{ .value = DEINTERLACE, .value_name = "Deinterlace video if necessary", .value_nick = "deinterlace" },
    .{ .value = SOFT_COLORBALANCE, .value_name = "Use software color balance", .value_nick = "soft-colorbalance" },
    .{ .value = FORCE_FILTERS, .value_name = "Force audio/video filter(s) to be applied", .value_nick = "force-filters" },
    .{ .value = FORCE_SW_DECODERS, .value_name = "Force only software-based decoders (no effect for playbin3)", .value_nick = "force-sw-decoders" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

var flags_once: cm.Once = .{};

pub fn flagsType() c.GType {
    return flags_once.get(struct {
        fn f() c.GType {
            return c.g_flags_register_static("GstPlayFlags", &values);
        }
    }.f);
}

pub const SELECT_TRY: c.gint = 0;
pub const SELECT_EXPOSE: c.gint = 1;
pub const SELECT_SKIP: c.gint = 2;

const select_values = [_]c.GEnumValue{
    .{ .value = SELECT_TRY, .value_name = "GST_AUTOPLUG_SELECT_TRY", .value_nick = "try" },
    .{ .value = SELECT_EXPOSE, .value_name = "GST_AUTOPLUG_SELECT_EXPOSE", .value_nick = "expose" },
    .{ .value = SELECT_SKIP, .value_name = "GST_AUTOPLUG_SELECT_SKIP", .value_nick = "skip" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

var select_once: cm.Once = .{};

pub fn selectType() c.GType {
    return select_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstAutoplugSelectResult", &select_values);
        }
    }.f);
}
