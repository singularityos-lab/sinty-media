const std = @import("std");
const c = @import("c").c;
const d = @import("plugdump.zig");

var hashes: [2][64]u64 = undefined;
var counts = [2]usize{ 0, 0 };

fn grab(_: ?*c.GstElement, buf: [*c]c.GstBuffer, _: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const k: usize = @intFromPtr(data);
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buf, &map, c.GST_MAP_READ) == 0) return;
    defer c.gst_buffer_unmap(buf, &map);
    var s: u64 = 0;
    for (0..map.size) |i| s = s *% 31 +% map.data[i];
    if (counts[k] < 64) hashes[k][counts[k]] = s;
    counts[k] += 1;
}

fn launch(desc: [*:0]const u8, k: usize) *c.GstElement {
    var err: [*c]c.GError = null;
    const p: *c.GstElement = @ptrCast(c.gst_parse_launch(desc, &err));
    const sink = c.gst_bin_get_by_name(@ptrCast(p), "out");
    if (sink != null) {
        c.g_object_set(sink, "signal-handoffs", @as(c.gboolean, 1), @as(?*anyopaque, null));
        _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&grab), @ptrFromInt(k), null, 0);
        c.gst_object_unref(sink);
    }
    return p;
}

fn shared() void {
    counts = .{ 0, 0 };
    const desc = "sintymediasrc source=\"videotestsrc is-live=true pattern=ball\" ! video/x-raw,format=RGBA,width=64,height=48,framerate=30/1 ! fakesink name=out";
    const a = launch(desc, 0);
    const b = launch(desc, 1);
    _ = c.gst_element_set_state(a, c.GST_STATE_PLAYING);
    _ = c.gst_element_set_state(b, c.GST_STATE_PLAYING);
    c.g_usleep(1500 * 1000);
    _ = c.gst_element_set_state(a, c.GST_STATE_NULL);
    _ = c.gst_element_set_state(b, c.GST_STATE_NULL);
    c.gst_object_unref(a);
    c.gst_object_unref(b);
    var common: usize = 0;
    for (hashes[0][0..@min(counts[0], 64)]) |h| {
        for (hashes[1][0..@min(counts[1], 64)]) |g| {
            if (h == g) {
                common += 1;
                break;
            }
        }
    }
    d.out("shared a={} b={} common={}", .{ counts[0] > 20, counts[1] > 20, common > 20 });
}

const FakeDevice = extern struct {
    parent: c.GstDevice,
};

const FakeClass = extern struct {
    parent: c.GstDeviceClass,
};

fn fakeCreate(_: [*c]c.GstDevice, name: [*c]const u8) callconv(.c) [*c]c.GstElement {
    const e = c.gst_element_factory_make("v4l2src", name);
    if (e != null) c.g_object_set(e, "device", "/dev/video-sinty-test", @as(?*anyopaque, null));
    return e;
}

fn fakeClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const dc: *c.GstDeviceClass = @ptrCast(@alignCast(k));
    dc.create_element = fakeCreate;
}

fn hook() void {
    const t = c.g_type_register_static_simple(c.gst_device_get_type(), "SintyFakeCamera", @sizeOf(FakeClass), fakeClassInit, @sizeOf(FakeDevice), null, 0);
    const dev = c.g_object_new(t, "display-name", "fake", "device-class", "Video/Source", @as(?*anyopaque, null));
    const e = c.gst_device_create_element(@ptrCast(@alignCast(dev)), "cam");
    if (e == null) {
        d.out("hook none", .{});
        return;
    }
    const f = c.gst_element_get_factory(e);
    var src: [*c]u8 = null;
    const name = @as(*c.GstObject, @ptrCast(@alignCast(f))).name;
    if (std.mem.eql(u8, std.mem.span(name), "sintymediasrc")) c.g_object_get(e, "source", &src, @as(?*anyopaque, null));
    d.out("hook {s} {s} {s}", .{ std.mem.span(name), std.mem.span(c.gst_object_get_name(@ptrCast(e))), if (src != null) std.mem.span(src) else "-" });
    c.g_free(src);
    _ = c.gst_object_ref_sink(e);
    c.gst_object_unref(e);
    c.g_object_unref(dev);
}

pub fn main() void {
    c.gst_init(null, null);
    if (c.g_getenv("MD_HOLD") != null) {
        const p = launch("sintymediasrc isolated=true source=\"videotestsrc is-live=true\" ! fakesink name=out", 0);
        _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
        c.g_usleep(3000 * 1000);
        _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
        c.gst_object_unref(p);
        d.out("hold frames={}", .{counts[0] > 10});
        return;
    }
    d.run("videotestsrc num-buffers=5 pattern=smpte ! video/x-raw,format=RGBA,width=64,height=48 ! fakesink name=out");
    d.run("sintymediasrc source=\"videotestsrc num-buffers=5 pattern=smpte\" ! video/x-raw,format=RGBA,width=64,height=48 ! fakesink name=out");
    d.run("sintymediasrc isolated=true source=\"videotestsrc num-buffers=5 pattern=smpte\" ! video/x-raw,format=RGBA,width=64,height=48 ! fakesink name=out");
    d.run("sintymediasrc source=\"audiotestsrc num-buffers=3 samplesperbuffer=512\" ! audio/x-raw,format=S16LE,rate=48000,channels=1 ! fakesink name=out");
    d.run("sintymediasrc source=\"nonexistentthing\" ! fakesink");
    d.run("sintymediasrc socket-path=/nonexistent/sock source=videotestsrc ! fakesink");
    shared();
    hook();
    d.out("done", .{});
}
