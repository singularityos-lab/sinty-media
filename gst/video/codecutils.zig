const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Frame = c.GstVideoCodecFrame;
const State = c.GstVideoCodecState;

fn unrefEvent(p: c.gpointer) callconv(.c) void {
    c.gst_event_unref(@ptrCast(@alignCast(p)));
}

fn freeFrame(f: [*c]Frame) void {
    if (f[0].input_buffer != null) c.gst_buffer_unref(f[0].input_buffer);
    if (f[0].output_buffer != null) c.gst_buffer_unref(f[0].output_buffer);
    c.g_list_free_full(f[0].events, unrefEvent);
    f[0].events = null;
    if (f[0].user_data_destroy_notify) |n| n(f[0].user_data);
    c.g_free(f);
}

pub export fn gst_video_codec_frame_set_user_data(f: [*c]Frame, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (f[0].user_data_destroy_notify) |n| n(f[0].user_data);
    f[0].user_data = data;
    f[0].user_data_destroy_notify = notify;
}

pub export fn gst_video_codec_frame_get_user_data(f: [*c]Frame) c.gpointer {
    return f[0].user_data;
}

pub export fn gst_video_codec_frame_ref(f: [*c]Frame) [*c]Frame {
    if (!check.that(f != null, "gst_video_codec_frame_ref", "frame != NULL")) return null;
    _ = @atomicRmw(c.gint, &f[0].ref_count, .Add, 1, .seq_cst);
    return f;
}

pub export fn gst_video_codec_frame_unref(f: [*c]Frame) void {
    const fname = "gst_video_codec_frame_unref";
    if (!check.that(f != null, fname, "frame != NULL")) return;
    if (!check.that(f[0].ref_count > 0, fname, "frame->ref_count > 0")) return;
    if (@atomicRmw(c.gint, &f[0].ref_count, .Sub, 1, .seq_cst) == 1) freeFrame(f);
}

pub export fn gst_video_codec_state_ref(s: [*c]State) [*c]State {
    if (!check.that(s != null, "gst_video_codec_state_ref", "state != NULL")) return null;
    _ = @atomicRmw(c.gint, &s[0].ref_count, .Add, 1, .seq_cst);
    return s;
}

fn freeState(s: [*c]State) void {
    if (s[0].caps != null) c.gst_caps_unref(s[0].caps);
    if (s[0].allocation_caps != null) c.gst_caps_unref(s[0].allocation_caps);
    if (s[0].codec_data != null) c.gst_buffer_unref(s[0].codec_data);
    if (s[0].mastering_display_info != null) c.g_free(s[0].mastering_display_info);
    if (s[0].content_light_level != null) c.g_free(s[0].content_light_level);
    c.g_free(s);
}

pub export fn gst_video_codec_state_unref(s: [*c]State) void {
    const fname = "gst_video_codec_state_unref";
    if (!check.that(s != null, fname, "state != NULL")) return;
    if (!check.that(s[0].ref_count > 0, fname, "state->ref_count > 0")) return;
    if (@atomicRmw(c.gint, &s[0].ref_count, .Sub, 1, .seq_cst) == 1) freeState(s);
}

fn frameCopy(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_video_codec_frame_ref(@ptrCast(@alignCast(p)));
}

fn frameFree(p: c.gpointer) callconv(.c) void {
    gst_video_codec_frame_unref(@ptrCast(@alignCast(p)));
}

fn stateCopy(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_video_codec_state_ref(@ptrCast(@alignCast(p)));
}

fn stateFree(p: c.gpointer) callconv(.c) void {
    gst_video_codec_state_unref(@ptrCast(@alignCast(p)));
}

var frame_once: gtype.Once = .{};
var state_once: gtype.Once = .{};

pub export fn gst_video_codec_frame_get_type() c.GType {
    return frame_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoCodecFrame", frameCopy, frameFree);
        }
    }.f);
}

pub export fn gst_video_codec_state_get_type() c.GType {
    return state_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoCodecState", stateCopy, stateFree);
        }
    }.f);
}
