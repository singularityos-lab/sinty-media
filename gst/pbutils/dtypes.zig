const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const prof = @import("encprofile.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Caps = c.GstCaps;
const OStream = ?*c.GstDiscovererStreamInfo;
const OInfo = ?*c.GstDiscovererInfo;
const OAudio = ?*c.GstDiscovererAudioInfo;
const OVideo = ?*c.GstDiscovererVideoInfo;
const OSub = ?*c.GstDiscovererSubtitleInfo;
const OContainer = ?*c.GstDiscovererContainerInfo;

pub const Stream = extern struct {
    parent: c.GObject,
    previous: ?*Stream,
    next: ?*Stream,
    caps: [*c]Caps,
    tags: ?*c.GstTagList,
    toc: ?*c.GstToc,
    stream_id: [*c]u8,
    misc: ?*c.GstStructure,
    stream_number: c.gint,
};

pub const Container = extern struct {
    parent: Stream,
    streams: [*c]c.GList,
    tags: ?*c.GstTagList,
};

pub const Audio = extern struct {
    parent: Stream,
    channel_mask: u64,
    channels: c.guint,
    sample_rate: c.guint,
    depth: c.guint,
    bitrate: c.guint,
    max_bitrate: c.guint,
    language: [*c]u8,
};

pub const Video = extern struct {
    parent: Stream,
    width: c.guint,
    height: c.guint,
    depth: c.guint,
    framerate_num: c.guint,
    framerate_denom: c.guint,
    par_num: c.guint,
    par_denom: c.guint,
    interlaced: c.gboolean,
    bitrate: c.guint,
    max_bitrate: c.guint,
    is_image: c.gboolean,
};

pub const Subtitle = extern struct {
    parent: Stream,
    language: [*c]u8,
};

pub const Info = extern struct {
    parent: c.GObject,
    uri: [*c]u8,
    result: c.GstDiscovererResult,
    stream_info: ?*Stream,
    stream_list: [*c]c.GList,
    duration: u64,
    misc: ?*c.GstStructure,
    tags: ?*c.GstTagList,
    toc: ?*c.GstToc,
    live: c.gboolean,
    seekable: c.gboolean,
    missing: *c.GPtrArray,
};

var stream_once: gtype.Once = .{};
var container_once: gtype.Once = .{};
var audio_once: gtype.Once = .{};
var video_once: gtype.Once = .{};
var sub_once: gtype.Once = .{};
var info_once: gtype.Once = .{};
var stream_parent: ?*c.GObjectClass = null;
var container_parent: ?*c.GObjectClass = null;
var audio_parent: ?*c.GObjectClass = null;
var sub_parent: ?*c.GObjectClass = null;
var info_parent: ?*c.GObjectClass = null;

pub fn stream(p: anytype) *Stream {
    return @ptrCast(@alignCast(p));
}

pub fn info(p: anytype) *Info {
    return @ptrCast(@alignCast(p));
}

pub fn isStream(p: anytype) bool {
    return gtype.instanceOf(p, gst_discoverer_stream_info_get_type());
}

pub fn isContainer(p: anytype) bool {
    return gtype.instanceOf(p, gst_discoverer_container_info_get_type());
}

pub fn isAudio(p: anytype) bool {
    return gtype.instanceOf(p, gst_discoverer_audio_info_get_type());
}

pub fn isVideo(p: anytype) bool {
    return gtype.instanceOf(p, gst_discoverer_video_info_get_type());
}

pub fn isSubtitle(p: anytype) bool {
    return gtype.instanceOf(p, gst_discoverer_subtitle_info_get_type());
}

pub fn isInfo(p: anytype) bool {
    return gtype.instanceOf(p, gst_discoverer_info_get_type());
}

fn streamFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s = stream(o);
    if (s.next) |n| c.g_object_unref(n);
    if (s.caps != null) c.gst_mini_object_unref(@ptrCast(s.caps));
    if (s.tags) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    if (s.toc) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    c.g_free(s.stream_id);
    if (s.misc) |m| c.gst_structure_free(m);
    stream_parent.?.finalize.?(o);
}

fn streamClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    stream_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = streamFinalize;
}

fn streamInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    stream(inst).stream_number = -1;
}

pub export fn gst_discoverer_stream_info_get_type() c.GType {
    return stream_once.get(struct {
        fn f() c.GType {
            return gtype.object(c.g_object_get_type, "GstDiscovererStreamInfo", c.GObjectClass, Stream, streamClassInit, streamInit, 0);
        }
    }.f);
}

fn containerFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Container = @ptrCast(@alignCast(o));
    var l = s.streams;
    while (l != null) : (l = l[0].next) c.g_object_unref(l[0].data);
    gst_discoverer_stream_info_list_free(s.streams);
    if (s.tags) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    container_parent.?.finalize.?(o);
}

fn containerClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    container_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = containerFinalize;
}

pub export fn gst_discoverer_container_info_get_type() c.GType {
    return container_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_discoverer_stream_info_get_type, "GstDiscovererContainerInfo", c.GObjectClass, Container, containerClassInit, null, 0);
        }
    }.f);
}

fn audioFinalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_free(@as(*Audio, @ptrCast(@alignCast(o))).language);
    audio_parent.?.finalize.?(o);
}

fn audioClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    audio_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = audioFinalize;
}

pub export fn gst_discoverer_audio_info_get_type() c.GType {
    return audio_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_discoverer_stream_info_get_type, "GstDiscovererAudioInfo", c.GObjectClass, Audio, audioClassInit, null, 0);
        }
    }.f);
}

fn subFinalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_free(@as(*Subtitle, @ptrCast(@alignCast(o))).language);
    sub_parent.?.finalize.?(o);
}

fn subClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    sub_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = subFinalize;
}

pub export fn gst_discoverer_subtitle_info_get_type() c.GType {
    return sub_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_discoverer_stream_info_get_type, "GstDiscovererSubtitleInfo", c.GObjectClass, Subtitle, subClassInit, null, 0);
        }
    }.f);
}

fn videoClassInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

pub export fn gst_discoverer_video_info_get_type() c.GType {
    return video_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_discoverer_stream_info_get_type, "GstDiscovererVideoInfo", c.GObjectClass, Video, videoClassInit, null, 0);
        }
    }.f);
}

fn infoFinalize(o: [*c]c.GObject) callconv(.c) void {
    const i = info(o);
    c.g_free(i.uri);
    if (i.stream_info) |s| c.g_object_unref(s);
    if (i.misc) |m| c.gst_structure_free(m);
    c.g_list_free(i.stream_list);
    if (i.tags) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    if (i.toc) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    c.g_ptr_array_unref(i.missing);
    info_parent.?.finalize.?(o);
}

fn infoClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    info_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = infoFinalize;
}

fn infoInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    info(inst).missing = c.g_ptr_array_new_null_terminated(16, c.g_free, 1);
}

pub export fn gst_discoverer_info_get_type() c.GType {
    return info_once.get(struct {
        fn f() c.GType {
            return gtype.object(c.g_object_get_type, "GstDiscovererInfo", c.GObjectClass, Info, infoClassInit, infoInit, 0);
        }
    }.f);
}

pub fn new(t: c.GType) c.gpointer {
    return c.g_object_new(t, @as([*c]const u8, null));
}

fn copyStream(src: *Stream, map: ?*c.GHashTable) *Stream {
    const t = gtype.typeOf(src);
    var ret: *Stream = undefined;
    if (t == gst_discoverer_container_info_get_type()) {
        const s: *Container = @ptrCast(src);
        const d: *Container = @ptrCast(@alignCast(new(t)));
        var l = s.streams;
        while (l != null) : (l = l[0].next) {
            const sub = copyStream(stream(l[0].data), map);
            d.streams = c.g_list_append(d.streams, sub);
            if (map != null) _ = c.g_hash_table_insert(map, l[0].data, sub);
        }
        if (s.tags) |tg| d.tags = c.gst_tag_list_copy(tg);
        ret = &d.parent;
    } else if (t == gst_discoverer_audio_info_get_type()) {
        const s: *Audio = @ptrCast(src);
        const d: *Audio = @ptrCast(@alignCast(new(t)));
        d.channels = s.channels;
        d.channel_mask = s.channel_mask;
        d.sample_rate = s.sample_rate;
        d.depth = s.depth;
        d.bitrate = s.bitrate;
        d.max_bitrate = s.max_bitrate;
        d.language = c.g_strdup(s.language);
        ret = &d.parent;
    } else if (t == gst_discoverer_video_info_get_type()) {
        const s: *Video = @ptrCast(src);
        const d: *Video = @ptrCast(@alignCast(new(t)));
        const p = d.parent;
        d.* = s.*;
        d.parent = p;
        ret = &d.parent;
    } else if (t == gst_discoverer_subtitle_info_get_type()) {
        const s: *Subtitle = @ptrCast(src);
        const d: *Subtitle = @ptrCast(@alignCast(new(t)));
        d.language = c.g_strdup(s.language);
        ret = &d.parent;
    } else ret = stream(new(gst_discoverer_stream_info_get_type()));
    if (src.next) |n| {
        ret.next = copyStream(n, map);
        ret.next.?.previous = ret;
    }
    if (src.caps != null) ret.caps = c.gst_caps_copy(src.caps);
    if (src.tags) |tg| ret.tags = c.gst_tag_list_copy(tg);
    if (src.toc) |tc| ret.toc = @ptrCast(c.gst_mini_object_ref(@ptrCast(@alignCast(tc))));
    if (src.stream_id != null) ret.stream_id = c.g_strdup(src.stream_id);
    if (src.misc) |m| ret.misc = c.gst_structure_copy(m);
    if (map != null) _ = c.g_hash_table_insert(map, src, ret);
    ret.stream_number = src.stream_number;
    return ret;
}

pub export fn gst_discoverer_info_copy(ptr: OInfo) OInfo {
    if (!check.that(ptr != null, "gst_discoverer_info_copy", "ptr != NULL")) return null;
    const s = info(ptr);
    const map = c.g_hash_table_new(c.g_direct_hash, null);
    const d = info(new(gst_discoverer_info_get_type()));
    d.uri = c.g_strdup(s.uri);
    if (s.stream_info) |si| d.stream_info = copyStream(si, map);
    d.duration = s.duration;
    d.result = s.result;
    d.seekable = s.seekable;
    d.live = s.live;
    if (s.misc) |m| d.misc = c.gst_structure_copy(m);
    var l = s.stream_list;
    while (l != null) : (l = l[0].next) {
        const ns = c.g_hash_table_lookup(map, l[0].data);
        if (ns == null) c.g_assertion_message_expr(check.DOMAIN, "../gst-libs/gst/pbutils/gstdiscoverer-types.c", 446, "gst_discoverer_info_copy", "new_stream != NULL");
        d.stream_list = c.g_list_append(d.stream_list, ns);
    }
    if (s.tags) |tg| d.tags = c.gst_tag_list_copy(tg);
    if (s.toc) |tc| d.toc = @ptrCast(c.gst_mini_object_ref(@ptrCast(@alignCast(tc))));
    for (0..s.missing.len) |i| c.g_ptr_array_add(d.missing, c.g_strdup(@ptrCast(s.missing.pdata[i])));
    c.g_hash_table_destroy(map);
    return @ptrCast(d);
}

pub export fn gst_discoverer_stream_info_list_free(infos: [*c]c.GList) void {
    var l = infos;
    while (l != null) : (l = l[0].next) c.g_object_unref(l[0].data);
    c.g_list_free(infos);
}

pub export fn gst_discoverer_info_get_streams(i: OInfo, t: c.GType) [*c]c.GList {
    var res: [*c]c.GList = null;
    var l = info(i).stream_list;
    while (l != null) : (l = l[0].next) {
        if (gtype.instanceOf(l[0].data, t)) res = c.g_list_append(res, c.g_object_ref(l[0].data));
    }
    return res;
}

pub export fn gst_discoverer_info_get_audio_streams(i: OInfo) [*c]c.GList {
    return gst_discoverer_info_get_streams(i, gst_discoverer_audio_info_get_type());
}

pub export fn gst_discoverer_info_get_video_streams(i: OInfo) [*c]c.GList {
    return gst_discoverer_info_get_streams(i, gst_discoverer_video_info_get_type());
}

pub export fn gst_discoverer_info_get_subtitle_streams(i: OInfo) [*c]c.GList {
    return gst_discoverer_info_get_streams(i, gst_discoverer_subtitle_info_get_type());
}

pub export fn gst_discoverer_info_get_container_streams(i: OInfo) [*c]c.GList {
    return gst_discoverer_info_get_streams(i, gst_discoverer_container_info_get_type());
}

pub export fn gst_discoverer_stream_info_get_stream_type_nick(i: OStream) [*c]const c.gchar {
    if (isContainer(i)) return "container";
    if (isAudio(i)) return "audio";
    if (isVideo(i)) return if (gst_discoverer_video_info_is_image(@ptrCast(i)) != 0) "video(image)" else "video";
    if (isSubtitle(i)) return "subtitles";
    return "unknown";
}

fn validStream(i: OStream, comptime fname: []const u8) bool {
    return check.that(isStream(i), fname, "GST_IS_DISCOVERER_STREAM_INFO (info)");
}

pub export fn gst_discoverer_stream_info_get_previous(i: OStream) OStream {
    if (!validStream(i, "gst_discoverer_stream_info_get_previous")) return null;
    return if (stream(i).previous) |p| @ptrCast(c.g_object_ref(p)) else null;
}

pub export fn gst_discoverer_stream_info_get_next(i: OStream) OStream {
    if (!validStream(i, "gst_discoverer_stream_info_get_next")) return null;
    return if (stream(i).next) |n| @ptrCast(c.g_object_ref(n)) else null;
}

pub export fn gst_discoverer_stream_info_get_caps(i: OStream) [*c]Caps {
    if (!validStream(i, "gst_discoverer_stream_info_get_caps")) return null;
    const cp = stream(i).caps;
    return if (cp != null) c.gst_caps_ref(cp) else null;
}

pub export fn gst_discoverer_stream_info_get_tags(i: OStream) ?*const c.GstTagList {
    if (!validStream(i, "gst_discoverer_stream_info_get_tags")) return null;
    return stream(i).tags;
}

pub export fn gst_discoverer_stream_info_get_toc(i: OStream) ?*const c.GstToc {
    if (!validStream(i, "gst_discoverer_stream_info_get_toc")) return null;
    return stream(i).toc;
}

pub export fn gst_discoverer_stream_info_get_stream_id(i: OStream) [*c]const c.gchar {
    if (!validStream(i, "gst_discoverer_stream_info_get_stream_id")) return null;
    return stream(i).stream_id;
}

pub export fn gst_discoverer_stream_info_get_misc(i: OStream) ?*const c.GstStructure {
    if (!validStream(i, "gst_discoverer_stream_info_get_misc")) return null;
    return stream(i).misc;
}

pub export fn gst_discoverer_stream_info_get_stream_number(i: OStream) c.gint {
    if (!validStream(i, "gst_discoverer_stream_info_get_stream_number")) return -1;
    return stream(i).stream_number;
}

pub export fn gst_discoverer_container_info_get_streams(i: OContainer) [*c]c.GList {
    if (!check.that(isContainer(i), "gst_discoverer_container_info_get_streams", "GST_IS_DISCOVERER_CONTAINER_INFO (info)")) return null;
    var res: [*c]c.GList = null;
    var l = @as(*Container, @ptrCast(@alignCast(i))).streams;
    while (l != null) : (l = l[0].next) res = c.g_list_append(res, c.g_object_ref(l[0].data));
    return res;
}

pub export fn gst_discoverer_container_info_get_tags(i: ?*const c.GstDiscovererContainerInfo) ?*const c.GstTagList {
    if (!check.that(isContainer(i), "gst_discoverer_container_info_get_tags", "GST_IS_DISCOVERER_CONTAINER_INFO (info)")) return null;
    return @as(*const Container, @ptrCast(@alignCast(i))).tags;
}

fn field(comptime T: type, comptime Ptr: type, comptime gt: fn () callconv(.c) c.GType, comptime fname: []const u8, comptime expr: []const u8, comptime name: []const u8, comptime R: type, comptime fail: R) fn (Ptr) callconv(.c) R {
    return struct {
        fn f(i: Ptr) callconv(.c) R {
            if (!check.that(gtype.instanceOf(i, gt()), fname, expr)) return fail;
            return @field(@as(*const T, @ptrCast(@alignCast(i))), name);
        }
    }.f;
}

const AUDIO_EXPR = "G_TYPE_CHECK_INSTANCE_TYPE((info), (gst_discoverer_audio_info_get_type ()))";
const VIDEO_EXPR = "G_TYPE_CHECK_INSTANCE_TYPE((info), (gst_discoverer_video_info_get_type ()))";
const SUB_EXPR = "G_TYPE_CHECK_INSTANCE_TYPE((info), (gst_discoverer_subtitle_info_get_type ()))";
const INFO_EXPR = "G_TYPE_CHECK_INSTANCE_TYPE((info), (gst_discoverer_info_get_type ()))";

fn audioField(comptime name: []const u8, comptime R: type, comptime fail: R) fn (?*const c.GstDiscovererAudioInfo) callconv(.c) R {
    return field(Audio, ?*const c.GstDiscovererAudioInfo, gst_discoverer_audio_info_get_type, "gst_discoverer_audio_info_get_" ++ name, AUDIO_EXPR, name, R, fail);
}

fn videoField(comptime name: []const u8, comptime R: type, comptime fail: R) fn (?*const c.GstDiscovererVideoInfo) callconv(.c) R {
    return field(Video, ?*const c.GstDiscovererVideoInfo, gst_discoverer_video_info_get_type, "gst_discoverer_video_info_get_" ++ name, VIDEO_EXPR, name, R, fail);
}

fn infoField(comptime name: []const u8, comptime R: type, comptime fail: R) fn (?*const c.GstDiscovererInfo) callconv(.c) R {
    return field(Info, ?*const c.GstDiscovererInfo, gst_discoverer_info_get_type, "gst_discoverer_info_get_" ++ name, INFO_EXPR, name, R, fail);
}

comptime {
    @export(&audioField("channels", c.guint, 0), .{ .name = "gst_discoverer_audio_info_get_channels" });
    @export(&audioField("channel_mask", u64, std.math.maxInt(u64)), .{ .name = "gst_discoverer_audio_info_get_channel_mask" });
    @export(&audioField("sample_rate", c.guint, 0), .{ .name = "gst_discoverer_audio_info_get_sample_rate" });
    @export(&audioField("depth", c.guint, 0), .{ .name = "gst_discoverer_audio_info_get_depth" });
    @export(&audioField("bitrate", c.guint, 0), .{ .name = "gst_discoverer_audio_info_get_bitrate" });
    @export(&audioField("max_bitrate", c.guint, 0), .{ .name = "gst_discoverer_audio_info_get_max_bitrate" });
    @export(&audioField("language", [*c]u8, null), .{ .name = "gst_discoverer_audio_info_get_language" });
    @export(&videoField("width", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_width" });
    @export(&videoField("height", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_height" });
    @export(&videoField("depth", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_depth" });
    @export(&videoField("framerate_num", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_framerate_num" });
    @export(&videoField("framerate_denom", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_framerate_denom" });
    @export(&videoField("par_num", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_par_num" });
    @export(&videoField("par_denom", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_par_denom" });
    @export(&videoField("bitrate", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_bitrate" });
    @export(&videoField("max_bitrate", c.guint, 0), .{ .name = "gst_discoverer_video_info_get_max_bitrate" });
    @export(&field(Subtitle, ?*const c.GstDiscovererSubtitleInfo, gst_discoverer_subtitle_info_get_type, "gst_discoverer_subtitle_info_get_language", SUB_EXPR, "language", [*c]u8, null), .{ .name = "gst_discoverer_subtitle_info_get_language" });
    @export(&infoField("uri", [*c]u8, null), .{ .name = "gst_discoverer_info_get_uri" });
    @export(&infoField("result", c.GstDiscovererResult, c.GST_DISCOVERER_OK), .{ .name = "gst_discoverer_info_get_result" });
    @export(&infoField("duration", u64, std.math.maxInt(u64)), .{ .name = "gst_discoverer_info_get_duration" });
    @export(&infoField("seekable", c.gboolean, 0), .{ .name = "gst_discoverer_info_get_seekable" });
    @export(&infoField("live", c.gboolean, 0), .{ .name = "gst_discoverer_info_get_live" });
    @export(&infoField("misc", ?*c.GstStructure, null), .{ .name = "gst_discoverer_info_get_misc" });
    @export(&infoField("tags", ?*c.GstTagList, null), .{ .name = "gst_discoverer_info_get_tags" });
    @export(&infoField("toc", ?*c.GstToc, null), .{ .name = "gst_discoverer_info_get_toc" });
}

pub export fn gst_discoverer_video_info_is_interlaced(i: ?*const c.GstDiscovererVideoInfo) c.gboolean {
    if (!check.that(isVideo(i), "gst_discoverer_video_info_is_interlaced", "GST_IS_DISCOVERER_VIDEO_INFO (info)")) return 0;
    return @as(*const Video, @ptrCast(@alignCast(i))).interlaced;
}

pub export fn gst_discoverer_video_info_is_image(i: ?*const c.GstDiscovererVideoInfo) c.gboolean {
    if (!check.that(isVideo(i), "gst_discoverer_video_info_is_image", "GST_IS_DISCOVERER_VIDEO_INFO (info)")) return 0;
    return @as(*const Video, @ptrCast(@alignCast(i))).is_image;
}

pub export fn gst_discoverer_info_get_stream_info(i: OInfo) OStream {
    if (!check.that(isInfo(i), "gst_discoverer_info_get_stream_info", "GST_IS_DISCOVERER_INFO (info)")) return null;
    return if (info(i).stream_info) |s| @ptrCast(c.g_object_ref(s)) else null;
}

pub export fn gst_discoverer_info_get_stream_list(i: OInfo) [*c]c.GList {
    if (!check.that(isInfo(i), "gst_discoverer_info_get_stream_list", "GST_IS_DISCOVERER_INFO (info)")) return null;
    var res: [*c]c.GList = null;
    var l = info(i).stream_list;
    while (l != null) : (l = l[0].next) res = c.g_list_append(res, c.g_object_ref(l[0].data));
    return res;
}

pub export fn gst_discoverer_info_get_missing_elements_installer_details(i: ?*const c.GstDiscovererInfo) [*c][*c]const c.gchar {
    const x: *const Info = @ptrCast(@alignCast(i));
    if (x.result != c.GST_DISCOVERER_MISSING_PLUGINS) return null;
    return @ptrCast(x.missing.pdata);
}

fn cleanStreamCaps(s: anytype) [*c]Caps {
    const caps: [*c]Caps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(gst_discoverer_stream_info_get_caps(@ptrCast(s)))));
    c.gst_structure_remove_fields(c.gst_caps_get_structure(caps, 0), "codec_data", "streamheader", "parsed", "colorimetry", "framed", "stream-format", "alignment", "tier", "level", "profile", "chroma-format", "bit-depth-luma", "bit-depth-chroma", @as([*c]const u8, null));
    return caps;
}

fn profileRecurse(top_in: ?*c.GstEncodingProfile, si: OStream) ?*c.GstEncodingProfile {
    var top = top_in;
    var profile: ?*c.GstEncodingProfile = null;
    const caps = cleanStreamCaps(si);
    if (isAudio(si)) {
        profile = @ptrCast(prof.gst_encoding_audio_profile_new(caps, null, null, 0));
    } else if (isVideo(si)) {
        profile = @ptrCast(prof.gst_encoding_video_profile_new(caps, null, null, 0));
    } else if (isContainer(si)) {
        const streams = gst_discoverer_container_info_get_streams(@ptrCast(si));
        if (top == null or !prof.isContainer(top)) {
            const prev = top;
            top = @ptrCast(prof.gst_encoding_container_profile_new("auto-generated", "Automatically generated from GstDiscovererInfo", caps, null));
            if (prev != null) _ = prof.gst_encoding_container_profile_add_profile(@ptrCast(top), prev);
        }
        var l = streams;
        while (l != null) : (l = l[0].next) _ = profileRecurse(top, @ptrCast(l[0].data));
        gst_discoverer_stream_info_list_free(streams);
    }
    c.gst_mini_object_unref(@ptrCast(caps));
    if (profile != null) {
        const sid = gst_discoverer_stream_info_get_stream_id(si);
        if (sid != null) {
            const sub = c.strchr(sid, '/');
            prof.gst_encoding_profile_set_name(profile, if (sub != null) sub else sid);
        }
        if (prof.isContainer(top)) _ = prof.gst_encoding_container_profile_add_profile(@ptrCast(top), profile);
    }
    if (top == null and profile != null) top = profile;
    const next = gst_discoverer_stream_info_get_next(si);
    if (next != null) return profileRecurse(top, next);
    return top;
}

pub export fn gst_encoding_profile_from_discoverer(i: OInfo) ?*c.GstEncodingProfile {
    if (i == null or gst_discoverer_info_get_result_(i) != c.GST_DISCOVERER_OK) return null;
    const si = gst_discoverer_info_get_stream_info(i);
    if (si == null) return null;
    const p = profileRecurse(null, si);
    if (prof.isContainer(p) and prof.gst_encoding_container_profile_get_profiles(@ptrCast(p)) == null) {
        c.g_object_unref(p);
        return null;
    }
    return p;
}

fn gst_discoverer_info_get_result_(i: OInfo) c.GstDiscovererResult {
    if (!check.that(isInfo(i), "gst_discoverer_info_get_result", INFO_EXPR)) return c.GST_DISCOVERER_OK;
    return info(i).result;
}
