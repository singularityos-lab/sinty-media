const std = @import("std");
const c = @import("c").c;
const d = @import("plugdump.zig");

pub fn main() void {
    c.gst_init(null, null);
    d.inspect("cdparanoia");
    d.inspect("libvisual");
    d.run("cdparanoiasrc device=/nonexistent/cdrom track=1 ! fakesink name=out");
    d.run("cdparanoiasrc generic-device=/nonexistent/sg0 ! fakesink name=out");
    const A = "audiotestsrc num-buffers=6 wave=sine ! audio/x-raw,format=S16LE,rate=44100,channels=";
    const V = " ! video/x-raw,width=64,height=48,framerate=30/1 ! fakesink name=out";
    inline for ([_][]const u8{ "lv_analyzer", "lv_scope", "corona", "jakdaw", "nastyfft", "flower" }) |actor| {
        d.run(A ++ "2 ! libvisual_" ++ actor ++ V);
    }
    inline for ([_][]const u8{ "bumpscope", "oinksie", "jess", "infinite" }) |actor| {
        d.run(A ++ "2 ! libvisual_" ++ actor ++ " ! video/x-raw,width=64,height=48,framerate=30/1 ! fakesink");
    }
    d.run(A ++ "1 ! libvisual_lv_scope ! video/x-raw,format=RGB16,width=32,height=32,framerate=15/1 ! fakesink name=out");
    d.run("audiotestsrc num-buffers=6 ! audio/x-raw,format=S16LE,rate=22500,channels=2 ! libvisual_lv_analyzer ! video/x-raw,format=BGR,width=40,height=30 ! fakesink name=out");
    d.out("done", .{});
}
