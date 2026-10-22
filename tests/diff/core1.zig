const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");

pub fn main() void {
    c.gst_init(null, null);
    const names = [_][*c]const u8{ "capsfilter", "clocksync", "concat", "dataurisrc", "downloadbuffer", "fakesrc", "fakesink", "fdsrc", "fdsink", "filesrc", "funnel", "identity", "input-selector", "output-selector", "queue", "queue2", "filesink", "tee", "typefind", "multiqueue", "valve", "streamiddemux" };
    for (names) |n| ins.element(n);
    ins.out("done", .{});
}
