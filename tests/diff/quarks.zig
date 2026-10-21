const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    const before = c.g_quark_from_string("sinty-probe-before");
    c.gst_init(null, null);
    const after = c.g_quark_from_string("sinty-probe-after");
    out("before {d} after {d}", .{ before, after });
    var q: c.GQuark = 1;
    while (q < after) : (q += 1) {
        const name = std.mem.span(c.g_quark_to_string(q));
        const id = for ([_][]const u8{ "GStreamer (Ubuntu)", "https://launchpad.net/ubuntu/+source/gstreamer1.0", "sinty-media", "https://sinty.dev" }) |x| {
            if (std.mem.eql(u8, x, name)) break true;
        } else false;
        out("Q {s}", .{if (id) "<identity>" else name});
    }
    for ([_][*c]const u8{ "title", "artist", "copyright", "datetime", "description", "keywords", "video-codec", "user-rating", "device-manufacturer", "device-model", "application-name", "image-orientation", "geo-location-latitude", "geo-location-longitude", "geo-location-elevation", "geo-location-country", "geo-location-city", "geo-location-sublocation", "GstStructure", "caps", "format", "width" }) |s| out("{s} {d}", .{ std.mem.span(s), c.g_quark_try_string(s) });
}
