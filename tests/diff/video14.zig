const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn show(prefix: []const u8, s: ?*const c.GstStructure) void {
    const str = c.gst_structure_to_string(s);
    out("{s} {s}", .{ prefix, str });
    c.g_free(str);
}

pub fn main() void {
    c.gst_init(null, null);
    const p = c.gst_video_dmabuf_pool_new();
    out("type {s} parent {s}", .{ c.g_type_name(c.gst_video_dmabuf_pool_get_type()), c.g_type_name(c.g_type_parent(c.gst_video_dmabuf_pool_get_type())) });
    out("options {s}", .{c.gst_buffer_pool_get_options(p)[0]});
    const caps = c.gst_caps_from_string("video/x-raw, format=NV12, width=64, height=32");
    const udma = c.gst_udmabuf_allocator_get();
    out("udmabuf {d}", .{@intFromBool(udma != null)});
    if (udma != null) c.gst_object_unref(udma);
    for (0..6) |k| {
        const cfg = c.gst_buffer_pool_get_config(p);
        c.gst_buffer_pool_config_set_params(cfg, caps, 3072, 1, 4);
        if (k & 1 != 0) c.gst_buffer_pool_config_add_option(cfg, c.GST_BUFFER_POOL_OPTION_VIDEO_META);
        if (k & 2 != 0) c.gst_buffer_pool_config_add_option(cfg, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT);
        if (k & 4 != 0) {
            var params = c.GstAllocationParams{ .flags = 0, .@"align" = 31, .prefix = 0, .padding = 0 };
            c.gst_buffer_pool_config_set_allocator(cfg, c.gst_allocator_find(null), &params);
        }
        const r = c.gst_buffer_pool_set_config(p, cfg);
        out("set_config {d}: {d}", .{ k, r });
        show("  now", c.gst_buffer_pool_get_config(p));
    }
    out("active {d}", .{c.gst_buffer_pool_set_active(p, 1)});
    out("inactive {d}", .{c.gst_buffer_pool_set_active(p, 0)});
    c.gst_caps_unref(caps);
    c.gst_object_unref(p);
}
