const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const build = @import("build_options");

const FILE = "../gst/gio/gstgioelement.c";

var protocols: [*c]const [*c]const u8 = null;
var protocols_once: c.GOnce = .{ .status = c.G_ONCE_STATUS_NOTCALLED, .retval = null };
var init_done: ?*anyopaque = null;

pub fn ioError(e: [*c]c.GError, code: c.gint) bool {
    return c.g_error_matches(e, c.g_io_error_quark(), code) != 0;
}

pub fn isSeekable(stream: anytype) bool {
    return cm.isA(stream, c.g_seekable_get_type()) and c.g_seekable_can_seek(@ptrCast(@alignCast(stream))) != 0;
}

pub fn gioError(el: anytype, comptime func: []const u8, err: *[*c]c.GError, ret: ?*c.GstFlowReturn) bool {
    var handled = true;
    if (ret) |r| r.* = c.GST_FLOW_ERROR;
    if (ioError(err.*, c.G_IO_ERROR_CANCELLED)) {
        if (ret) |r| r.* = c.GST_FLOW_FLUSHING;
    } else if (err.* != null) {
        handled = false;
    } else {
        cm.elementError(el, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_FAILED, null, c.g_strdup_printf("%s call failed without error set", (func ++ "").ptr), FILE, "gst_gio_error", 58);
    }
    if (handled) c.g_clear_error(err);
    return handled;
}

pub fn seek(el: anytype, stream: anytype, offset: c.guint64, cancel: ?*c.GCancellable) c.GstFlowReturn {
    var err: [*c]c.GError = null;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (c.g_seekable_seek(@ptrCast(@alignCast(stream)), @bitCast(offset), c.G_SEEK_SET, cancel, &err) != 0) return c.GST_FLOW_OK;
    if (!gioError(el, "g_seekable_seek", &err, &ret)) {
        cm.elementError(el, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SEEK, null, c.g_strdup_printf("Could not seek: %s", err.*.message), FILE, "gst_gio_seek", 83);
        c.g_clear_error(&err);
    }
    return ret;
}

fn makeProtocols(_: c.gpointer) callconv(.c) c.gpointer {
    const schemes = c.g_vfs_get_supported_uri_schemes(c.g_vfs_get_default());
    const num: usize = if (schemes != null) c.g_strv_length(@constCast(@ptrCast(schemes))) else 0;
    if (num == 0) return null;
    const ours: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc0((num + 1) * @sizeOf([*c]u8))));
    var j: usize = 0;
    for (0..num) |i| {
        const s = schemes[i];
        if (c.strcmp(s, "http") == 0 or c.strcmp(s, "https") == 0 or c.strcmp(s, "cdda") == 0) continue;
        ours[j] = c.g_strdup(s);
        j += 1;
    }
    return @ptrCast(ours);
}

fn uriTypeSink(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SINK;
}

fn uriTypeSrc(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SRC;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    if (protocols == null) protocols = @ptrCast(@alignCast(c.g_once_impl(&protocols_once, makeProtocols, null)));
    return protocols;
}

fn getUri(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    if (!cm.that(cm.isA(h, c.gst_element_get_type()), "gst_gio_uri_handler_get_uri", "GST_IS_ELEMENT (element)")) return null;
    var uri: [*c]u8 = null;
    c.g_object_get(@ptrCast(h), "location", &uri, @as(?*anyopaque, null));
    return uri;
}

fn setUri(h: ?*c.GstURIHandler, uri: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    if (!cm.that(cm.isA(h, c.gst_element_get_type()), "gst_gio_uri_handler_set_uri", "GST_IS_ELEMENT (element)")) return 0;
    const state = @as(*c.GstElement, @ptrCast(@alignCast(h))).current_state;
    if (state == c.GST_STATE_PLAYING or state == c.GST_STATE_PAUSED) {
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_STATE, "Changing the 'location' property while the element is running is not supported");
        return 0;
    }
    c.g_object_set(@ptrCast(h), "location", uri, @as(?*anyopaque, null));
    return 1;
}

fn uriInit(g: c.gpointer, data: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(g));
    i.get_type = if (data != null) uriTypeSink else uriTypeSrc;
    i.get_protocols = uriProtocols;
    i.get_uri = getUri;
    i.set_uri = setUri;
}

pub fn addUriHandler(t: c.GType) void {
    const sink = c.g_type_is_a(t, c.gst_base_sink_get_type()) != 0;
    const info = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = if (sink) @ptrFromInt(1) else null };
    c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &info);
}

pub fn pluginInit(p: ?*c.GstPlugin) void {
    if (c.g_once_init_enter_pointer(@ptrCast(&init_done)) != 0) {
        _ = c._gst_debug_category_new("gio", 0, "GIO elements");
        c.gst_plugin_add_dependency_simple(p, null, build.gio_module_dir ++ "", null, c.GST_PLUGIN_DEPENDENCY_FLAG_NONE);
        c.gst_plugin_add_dependency_simple(p, null, build.gio_prefix ++ "/share/gvfs/mounts", null, c.GST_PLUGIN_DEPENDENCY_FLAG_NONE);
        c.g_once_init_leave_pointer(@ptrCast(&init_done), @ptrFromInt(1));
    }
}
