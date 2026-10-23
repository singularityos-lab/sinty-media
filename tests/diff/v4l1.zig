const std = @import("std");
const c = @import("c").c;
const d = @import("plugdump.zig");

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn element(name: [*c]const u8) void {
    const f = c.gst_element_factory_find(name) orelse {
        d.out("no element {s}", .{z(name)});
        return;
    };
    defer c.gst_object_unref(f);
    d.out("element {s} rank {d}", .{ z(name), c.gst_plugin_feature_get_rank(@ptrCast(f)) });
    for ([_][*c]const u8{ c.GST_ELEMENT_METADATA_LONGNAME, c.GST_ELEMENT_METADATA_KLASS, c.GST_ELEMENT_METADATA_DESCRIPTION, c.GST_ELEMENT_METADATA_AUTHOR }) |k| d.out("  meta {s}", .{z(c.gst_element_factory_get_metadata(f, k))});
    var t = c.gst_element_factory_get_static_pad_templates(f);
    while (t != null) : (t = t[0].next) {
        const pt: *c.GstStaticPadTemplate = @ptrCast(@alignCast(t[0].data));
        d.out("  template {s} {d} {d} {s}", .{ z(pt.name_template), pt.direction, pt.presence, z(pt.static_caps.string) });
    }
    var n: c.guint = 0;
    const protos = c.gst_element_factory_get_uri_protocols(f);
    if (protos != null) {
        while (protos[n] != null) : (n += 1) d.out("  uri {s}", .{z(protos[n])});
    }
    d.out("  uri type {d}", .{c.gst_element_factory_get_uri_type(f)});
    const e = c.gst_element_factory_create(f, null);
    d.describe(@ptrCast(e));
    c.gst_object_unref(e);
}

fn provider(name: [*c]const u8) void {
    const f = c.gst_device_provider_factory_find(name) orelse {
        d.out("no provider {s}", .{z(name)});
        return;
    };
    defer c.gst_object_unref(f);
    d.out("provider {s} rank {d}", .{ z(name), c.gst_plugin_feature_get_rank(@ptrCast(f)) });
    for ([_][*c]const u8{ c.GST_ELEMENT_METADATA_LONGNAME, c.GST_ELEMENT_METADATA_KLASS, c.GST_ELEMENT_METADATA_DESCRIPTION, c.GST_ELEMENT_METADATA_AUTHOR }) |k| d.out("  meta {s}", .{z(c.gst_device_provider_factory_get_metadata(f, k))});
    const p = c.gst_device_provider_factory_get(f);
    if (p == null) return;
    const list = c.gst_device_provider_get_devices(p);
    d.out("  devices {d}", .{c.g_list_length(list)});
    c.g_list_free_full(list, c.gst_object_unref);
    c.gst_object_unref(p);
}

pub fn main() void {
    c.gst_init(null, null);
    const pl = c.gst_registry_find_plugin(c.gst_registry_get(), "video4linux2");
    if (pl != null) {
        d.out("plugin {s} {s} {s}", .{ z(c.gst_plugin_get_name(pl)), z(c.gst_plugin_get_description(pl)), z(c.gst_plugin_get_license(pl)) });
        c.gst_object_unref(pl);
    }
    element("v4l2src");
    provider("v4l2deviceprovider");
    d.run("v4l2src device=/nonexistent/video9 ! fakesink");
    d.run("v4l2src device=/dev/null ! fakesink");
    d.run("v4l2src device=/etc ! fakesink");
    const e = c.gst_element_make_from_uri(c.GST_URI_SRC, "v4l2:///dev/video7", null, null);
    if (e != null) {
        var dev: [*c]u8 = null;
        c.g_object_get(e, "device", &dev, @as(?*anyopaque, null));
        const uri = c.gst_uri_handler_get_uri(@ptrCast(e));
        d.out("uri {s} {s}", .{ z(dev), z(uri) });
        c.g_free(dev);
        c.g_free(uri);
        c.gst_object_unref(e);
    }
    d.out("done", .{});
}
