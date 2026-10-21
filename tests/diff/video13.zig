const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

var seed: u32 = 5;

fn rnd() u8 {
    seed = seed *% 1103515245 +% 12345;
    return @truncate(seed >> 16);
}

fn makeSample(caps_str: [*:0]const u8, crop: bool) ?*c.GstSample {
    const caps = c.gst_caps_from_string(caps_str);
    var vi: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_from_caps(&vi, caps);
    const b = c.gst_buffer_new_allocate(null, vi.size, null);
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &mi, c.GST_MAP_WRITE);
    for (0..mi.size) |i| mi.data[i] = rnd();
    c.gst_buffer_unmap(b, &mi);
    b[0].pts = 40 * c.GST_MSECOND;
    if (crop) {
        const m: *c.GstVideoCropMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(b, c.gst_video_crop_meta_get_info(), null)));
        m.x = 4;
        m.y = 2;
        m.width = 20;
        m.height = 10;
    }
    const s = c.gst_sample_new(b, caps, null, null);
    c.gst_buffer_unref(b);
    c.gst_caps_unref(caps);
    return s;
}

fn showResult(r: ?*c.GstSample, err: [*c]c.GError) void {
    if (err != null) out("    error {d} {s}", .{ err[0].code, err[0].message });
    if (r == null) {
        out("    null", .{});
        return;
    }
    const caps = c.gst_caps_to_string(c.gst_sample_get_caps(r));
    const b = c.gst_sample_get_buffer(r);
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &mi, c.GST_MAP_READ);
    var h: u32 = 2166136261;
    for (mi.data[0..mi.size]) |x| h = (h ^ x) *% 16777619;
    out("    {s} size {d} pts {d} hash {x} crop {d}", .{ caps, mi.size, b[0].pts, h, @intFromBool(c.gst_buffer_get_meta(b, c.gst_video_crop_meta_api_get_type()) != null) });
    c.gst_buffer_unmap(b, &mi);
    c.g_free(caps);
}

const cases = [_]struct { [*:0]const u8, [*:0]const u8, bool }{
    .{ "video/x-raw, format=I420, width=32, height=16, framerate=25/1", "video/x-raw, format=RGBA, width=16, height=8", false },
    .{ "video/x-raw, format=RGBA, width=32, height=16, framerate=25/1", "video/x-raw, format=I420, width=48, height=20, framerate=30/1", false },
    .{ "video/x-raw, format=NV12, width=32, height=16", "video/x-raw, format=BGRx, width=32, height=16, pixel-aspect-ratio=1/1", true },
    .{ "video/x-raw, format=RGB, width=32, height=16", "image/png", false },
    .{ "video/x-raw, format=RGB, width=32, height=16", "image/x-nothing", false },
    .{ "video/x-raw, format=I420, width=32, height=16", "video/x-raw, format=I420, width=0, height=16", false },
};

var loop: ?*c.GMainLoop = null;
var pending: u32 = 0;

fn asyncDone(r: ?*c.GstSample, err: [*c]c.GError, ud: c.gpointer) callconv(.c) void {
    out("  async {d}", .{@intFromPtr(ud)});
    showResult(r, err);
    if (r != null) c.gst_sample_unref(r);
    if (err != null) c.g_error_free(err);
}

fn destroyed(ud: c.gpointer) callconv(.c) void {
    out("  destroy {d}", .{@intFromPtr(ud)});
    pending -= 1;
    if (pending == 0) c.g_main_loop_quit(loop);
}

pub fn main() void {
    c.gst_init(null, null);
    out("sync", .{});
    for (cases, 0..) |cs, i| {
        const s = makeSample(cs[0], cs[2]);
        const to = c.gst_caps_from_string(cs[1]);
        var err: [*c]c.GError = null;
        out("  case {d}", .{i});
        const r = c.gst_video_convert_sample(s, to, 5 * c.GST_SECOND, &err);
        showResult(r, err);
        if (r != null) c.gst_sample_unref(r);
        if (err != null) c.g_error_free(err);
        c.gst_caps_unref(to);
        c.gst_sample_unref(s);
    }
    const s0 = makeSample(cases[0][0], false);
    out("  null err", .{});
    const to0 = c.gst_caps_from_string("image/x-nothing");
    showResult(c.gst_video_convert_sample(s0, to0, 5 * c.GST_SECOND, null), null);
    _ = c.gst_video_convert_sample(null, to0, 0, null);
    _ = c.gst_video_convert_sample(s0, null, 0, null);
    const empty = c.gst_sample_new(null, null, null, null);
    _ = c.gst_video_convert_sample(empty, to0, 0, null);
    out("async", .{});
    loop = c.g_main_loop_new(null, 0);
    for (cases, 0..) |cs, i| {
        const s = makeSample(cs[0], cs[2]);
        const to = c.gst_caps_from_string(cs[1]);
        pending += 1;
        c.gst_video_convert_sample_async(s, to, 5 * c.GST_SECOND, asyncDone, @ptrFromInt(i + 1), destroyed);
        c.gst_caps_unref(to);
        c.gst_sample_unref(s);
        c.g_main_loop_run(loop);
    }
    c.gst_video_convert_sample_async(s0, to0, 0, null, null, null);
    c.gst_video_convert_sample_async(empty, to0, 0, asyncDone, null, null);
    c.gst_sample_unref(empty);
    c.gst_caps_unref(to0);
    c.gst_sample_unref(s0);
    c.g_main_loop_unref(loop);
}
