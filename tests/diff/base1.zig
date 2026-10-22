const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");

pub fn main() void {
    c.gst_init(null, null);
    const names = [_][*c]const u8{ "appsrc", "appsink", "audioconvert" };
    for (names) |n| ins.element(n);
    ins.out("done", .{});
}
