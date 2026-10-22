const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const lv = @import("lv.zig").p;

const FILE = "../ext/libvisual/visual.c";
const SAMPLES = 512;
const SRC_CAPS = "video/x-raw, format = (string)  { BGRx, BGR, RGB16 } , width = (int) [ 1, max ], height = (int) [ 1, max ], framerate = (fraction) [ 0, max ]";
const SINK_CAPS = "audio/x-raw, format = (string) S16LE, layout = (string) interleaved, channels = (int) { 1, 2 }, rate = (int) { 8000, 11250, 22500, 32000, 44100, 48000, 96000 }";

pub const Self = extern struct {
    element: c.GstAudioVisualizer,
    audio: ?*lv.VisAudio,
    video: ?*lv.VisVideo,
    actor: ?*lv.VisActor,
};

pub const Class = extern struct {
    parent: c.GstAudioVisualizerClass,
    plugin: ?*lv.VisPluginRef,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, SINK_CAPS);
var once: cm.Once = .{};
var parent_obj: *c.GObjectClass = undefined;

fn me(x: anytype) *Self {
    return @ptrCast(@alignCast(x));
}

fn klass(s: *Self) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(s))).g_class));
}

fn unref(o: anytype) void {
    _ = lv.visual_object_unref(@ptrCast(@alignCast(o)));
}

fn clearActors(s: *Self) void {
    if (s.actor != null) unref(s.actor);
    s.actor = null;
    if (s.video != null) unref(s.video);
    s.video = null;
    if (s.audio != null) unref(s.audio);
    s.audio = null;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    clearActors(me(o));
    parent_obj.finalize.?(o);
}

fn initError(s: *Self, detail: [*:0]const u8, line: c.gint) bool {
    cm.elementError(s, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_INIT, null, c.g_strdup(detail), FILE, "gst_visual_setup", line);
    clearActors(s);
    return false;
}

fn setup(bs: [*c]c.GstAudioVisualizer) callconv(.c) c.gboolean {
    const s = me(bs);
    clearActors(s);
    const fi = bs[0].vinfo.finfo[0];
    var depth: c.gint = @intCast(fi.pixel_stride[0]);
    if (fi.bits >= 8) depth *= 8;
    s.actor = lv.visual_actor_new(klass(s).plugin.?.info[0].plugname);
    s.video = lv.visual_video_new();
    s.audio = lv.visual_audio_new();
    if (s.actor == null or s.video == null) return @intFromBool(initError(s, "could not create actors", 199));
    if (lv.visual_actor_realize(s.actor) != 0) return @intFromBool(initError(s, "could not realize actor", 206));
    _ = lv.visual_actor_set_video(s.actor, s.video);
    _ = lv.visual_video_set_depth(s.video, lv.visual_video_depth_enum_from_value(depth));
    _ = lv.visual_video_set_dimension(s.video, bs[0].vinfo.width, bs[0].vinfo.height);
    _ = lv.visual_actor_video_negotiate(s.actor, 0, 0, 0);
    return 1;
}

fn render(bs: [*c]c.GstAudioVisualizer, audio: [*c]c.GstBuffer, video: [*c]c.GstVideoFrame) callconv(.c) c.gboolean {
    const s = me(bs);
    _ = lv.visual_video_set_buffer(s.video, video[0].data[0]);
    _ = lv.visual_video_set_pitch(s.video, video[0].info.stride[0]);
    const channels = bs[0].ainfo.channels;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(audio, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(audio, &map);
    var a: [*]align(1) const u16 = @ptrCast(map.data);
    var ldata: [SAMPLES]u16 = undefined;
    var rdata: [SAMPLES]u16 = undefined;
    const lbuf = lv.visual_buffer_new_with_buffer(&ldata, @sizeOf(@TypeOf(ldata)), null);
    const rbuf = lv.visual_buffer_new_with_buffer(&rdata, @sizeOf(@TypeOf(rdata)), null);
    for (0..SAMPLES) |i| {
        if (channels == 2) {
            ldata[i] = a[0];
            rdata[i] = a[1];
            a += 2;
        } else {
            ldata[i] = a[0];
            rdata[i] = a[0];
            a += 1;
        }
    }
    const rate: lv.VisAudioSampleRateType = switch (bs[0].ainfo.rate) {
        8000 => lv.VISUAL_AUDIO_SAMPLE_RATE_8000,
        11250 => lv.VISUAL_AUDIO_SAMPLE_RATE_11250,
        22500 => lv.VISUAL_AUDIO_SAMPLE_RATE_22500,
        32000 => lv.VISUAL_AUDIO_SAMPLE_RATE_32000,
        44100 => lv.VISUAL_AUDIO_SAMPLE_RATE_44100,
        48000 => lv.VISUAL_AUDIO_SAMPLE_RATE_48000,
        96000 => lv.VISUAL_AUDIO_SAMPLE_RATE_96000,
        else => {
            unref(lbuf);
            unref(rbuf);
            return 0;
        },
    };
    _ = lv.visual_audio_samplepool_input_channel(s.audio.?.samplepool, lbuf, rate, lv.VISUAL_AUDIO_SAMPLE_FORMAT_S16, @constCast(lv.VISUAL_AUDIO_CHANNEL_LEFT));
    _ = lv.visual_audio_samplepool_input_channel(s.audio.?.samplepool, rbuf, rate, lv.VISUAL_AUDIO_SAMPLE_FORMAT_S16, @constCast(lv.VISUAL_AUDIO_CHANNEL_RIGHT));
    unref(lbuf);
    unref(rbuf);
    _ = lv.visual_audio_analyze(s.audio);
    _ = lv.visual_actor_run(s.actor, s.audio);
    _ = lv.visual_video_set_buffer(s.video, null);
    return 1;
}

pub fn classInit(k: c.gpointer, data: c.gpointer) callconv(.c) void {
    const kl: *Class = @ptrCast(@alignCast(k));
    kl.plugin = @ptrCast(@alignCast(data));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    if (data == null) {
        parent_obj = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    } else {
        const info = kl.plugin.?.info;
        const longname = c.g_strdup_printf("libvisual %s plugin v.%s", info[0].name, info[0].version);
        c.gst_element_class_add_static_pad_template(ec, &src_t);
        c.gst_element_class_add_static_pad_template(ec, &sink_t);
        c.gst_element_class_set_metadata(ec, longname, "Visualization", info[0].about, "Benjamin Otte <otte@gnome.org>");
        c.g_free(longname);
    }
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
    const sc: *c.GstAudioVisualizerClass = @ptrCast(@alignCast(k));
    sc.setup = setup;
    sc.render = render;
    c.gst_type_mark_as_plugin_api(getType(), 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_audio_visualizer_get_type(), "GstVisual", Class, Self, classInit, null);
        }
    }.f);
}
