const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");

pub fn main() void {
    c.gst_init(null, null);
    const names = [_][*c]const u8{ "appsrc", "appsink", "audioconvert", "audioresample", "videoconvertscale", "videoconvert", "videoscale", "volume", "audiotestsrc", "videotestsrc", "streamsynchronizer" };
    for (names) |n| ins.element(n);
    ins.out("done", .{});
}
