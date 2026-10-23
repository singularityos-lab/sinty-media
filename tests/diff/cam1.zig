const std = @import("std");
const c = @import("c").c;
const d = @import("plugdump.zig");

var frames: u32 = 0;
var distinct: u32 = 0;
var last: u64 = 0;

fn grab(_: ?*c.GstElement, buf: [*c]c.GstBuffer, _: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buf, &map, c.GST_MAP_READ) == 0) return;
    defer c.gst_buffer_unmap(buf, &map);
    var s: u64 = 0;
    var i: usize = 0;
    while (i < map.size) : (i += 997) s = s *% 31 +% map.data[i];
    if (s != last) distinct += 1;
    last = s;
    frames += 1;
}

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

pub fn main() void {
    c.gst_init(null, null);
    const mon = c.gst_device_monitor_new();
    const filter = c.gst_caps_new_empty_simple("video/x-raw");
    _ = c.gst_device_monitor_add_filter(mon, "Video/Source", filter);
    c.gst_caps_unref(filter);
    _ = c.gst_device_monitor_start(mon);
    var list = c.gst_device_monitor_get_devices(mon);
    d.out("devices {d}", .{c.g_list_length(list)});
    var first: ?*c.GstDevice = null;
    var l = list;
    while (l != null) : (l = l[0].next) {
        const dev: *c.GstDevice = @ptrCast(@alignCast(l[0].data));
        const name = c.gst_device_get_display_name(dev);
        const cls = c.gst_device_get_device_class(dev);
        const caps = c.gst_device_get_caps(dev);
        const cs = c.gst_caps_to_string(caps);
        const props = c.gst_device_get_properties(dev);
        const path = if (props != null) c.gst_structure_get_string(props, "device.path") else null;
        d.out("device {s} class {s} path {s} structures {d}", .{ z(name), z(cls), z(path), c.gst_caps_get_size(caps) });
        d.out("  caps {s}", .{z(cs)[0..@min(z(cs).len, 400)]});
        if (first == null) first = @ptrCast(@alignCast(c.gst_object_ref(dev)));
        c.g_free(name);
        c.g_free(cls);
        c.g_free(cs);
        c.gst_caps_unref(caps);
        if (props != null) c.gst_structure_free(props);
    }
    c.g_list_free_full(list, c.gst_object_unref);
    list = null;
    c.gst_device_monitor_stop(mon);
    c.gst_object_unref(mon);
    const dev = first orelse {
        d.out("no camera", .{});
        return;
    };
    const src = c.gst_device_create_element(dev, "cam");
    c.gst_object_unref(dev);
    if (src == null) {
        d.out("create failed", .{});
        return;
    }
    const f = c.gst_element_get_factory(src);
    d.out("source {s}", .{z(@as(*c.GstObject, @ptrCast(@alignCast(f))).name)});
    const p = c.gst_pipeline_new("cam");
    const conv = c.gst_element_factory_make("videoconvert", null);
    const cf = c.gst_element_factory_make("capsfilter", null);
    const sink = c.gst_element_factory_make("fakesink", "out");
    const rgba = c.gst_caps_from_string("video/x-raw,format=RGBA");
    c.g_object_set(cf, "caps", rgba, @as(?*anyopaque, null));
    c.gst_caps_unref(rgba);
    c.g_object_set(sink, "signal-handoffs", @as(c.gboolean, 1), "sync", @as(c.gboolean, 0), @as(?*anyopaque, null));
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&grab), null, null, 0);
    c.gst_bin_add_many(@ptrCast(p), src, conv, cf, sink, @as(?*anyopaque, null));
    _ = c.gst_element_link_many(src, conv, cf, sink, @as(?*anyopaque, null));
    d.out("state {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    const msg = c.gst_bus_timed_pop_filtered(bus, 4 * c.GST_SECOND, c.GST_MESSAGE_ERROR);
    if (msg != null) {
        var e: [*c]c.GError = null;
        var dbg: [*c]u8 = null;
        c.gst_message_parse_error(msg, &e, &dbg);
        d.out("error {s} | {s}", .{ z(e[0].message), z(dbg) });
        c.gst_message_unref(msg);
    }
    const pad = c.gst_element_get_static_pad(cf, "src");
    const caps = c.gst_pad_get_current_caps(pad);
    const cs = if (caps != null) c.gst_caps_to_string(caps) else null;
    d.out("negotiated {s}", .{z(cs)});
    c.g_free(cs);
    if (caps != null) c.gst_caps_unref(caps);
    c.gst_object_unref(pad);
    c.gst_object_unref(bus);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
    d.out("frames {d} distinct {d}", .{ frames, distinct });
}
