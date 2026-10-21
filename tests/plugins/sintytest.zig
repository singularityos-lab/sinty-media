const std = @import("std");
const c = @import("c").c;

var src_t = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "audio/x-raw, rate=(int)44100, channels=(int)[ 1, 2 ]" } };
var sink_t = c.GstStaticPadTemplate{ .name_template = "sink_%u", .direction = c.GST_PAD_SINK, .presence = c.GST_PAD_REQUEST, .static_caps = .{ .caps = null, .string = "ANY" } };

const Instance = extern struct {
    element: c.GstElement,
    uri: [*c]u8,
};

var protocols = [_][*c]const u8{ "sinty", "stest", null };

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SRC;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return &protocols;
}

fn getUri(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    const self: *Instance = @ptrCast(@alignCast(h));
    return c.g_strdup(self.uri);
}

fn setUri(h: ?*c.GstURIHandler, uri: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const self: *Instance = @ptrCast(@alignCast(h));
    if (c.strstr(uri, "bad") != null) {
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_REFERENCE, "refused %s", uri);
        return 0;
    }
    c.g_free(self.uri);
    self.uri = c.g_strdup(uri);
    return 1;
}

fn ifaceInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(g));
    i.get_type = uriType;
    i.get_protocols = uriProtocols;
    i.get_uri = getUri;
    i.set_uri = setUri;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &src_t);
    c.gst_element_class_add_static_pad_template(ek, &sink_t);
    c.gst_element_class_set_static_metadata(ek, "Sinty test source", "Source/Audio", "Produces nothing for tests", "Sinty <dev@sinty.dev>");
    c.gst_element_class_add_static_metadata(ek, "doc-uri", "https://sinty.dev/doc");
}

fn srcType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) {
        S.t = c.g_type_register_static_simple(c.gst_element_get_type(), "SintyTestSrc", @sizeOf(c.GstElementClass), classInit, @sizeOf(Instance), null, 0);
        const info = c.GInterfaceInfo{ .interface_init = ifaceInit, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(S.t, c.gst_uri_handler_get_type(), &info);
    }
    return S.t;
}

fn sinkType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_element_get_type(), "SintyTestSink", @sizeOf(c.GstElementClass), sinkClassInit, @sizeOf(c.GstElement), null, 0);
    return S.t;
}

fn sinkClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &sink_t);
    c.gst_element_class_set_static_metadata(ek, "Sinty test sink", "Sink/Video/Hardware", "Eats", "Sinty");
}

fn badType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_element_get_type(), "SintyTestBad", @sizeOf(c.GstElementClass), null, @sizeOf(c.GstElement), null, 0);
    return S.t;
}

fn typefind(find: ?*c.GstTypeFind, data: c.gpointer) callconv(.c) void {
    const head = c.gst_type_find_peek(find, 0, 4);
    if (head == null) return;
    if (std.mem.eql(u8, head[0..4], "STY1")) c.gst_type_find_suggest_simple(find, c.GST_TYPE_FIND_MAXIMUM, "application/x-sinty", "version", c.G_TYPE_INT, @as(c_int, 1), @as([*c]const u8, null));
    if (data != null) c.gst_type_find_suggest_empty_simple(find, c.GST_TYPE_FIND_POSSIBLE, @ptrCast(data));
}

fn dynType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.G_TYPE_OBJECT, "SintyDynType", @sizeOf(c.GObjectClass), null, @sizeOf(c.GObject), null, 0);
    return S.t;
}

fn init(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    _ = c.gst_type_find_register(p, "sintytypefind", c.GST_RANK_PRIMARY, typefind, "sty,sinty", c.gst_caps_from_string("application/x-sinty"), null, null);
    _ = c.gst_type_find_register(p, "sintyhint", c.GST_RANK_PRIMARY, typefind, null, null, @constCast("text/x-sinty-hint"), null);
    _ = c.gst_dynamic_type_register(p, dynType());
    _ = c.gst_element_register(p, "sintytestsrc", c.GST_RANK_SECONDARY, srcType());
    _ = c.gst_element_register(p, "sintytestsink", c.GST_RANK_PRIMARY + 1, sinkType());
    _ = c.gst_element_register(p, "sintytestbad", c.GST_RANK_NONE, badType());
    c.gst_plugin_add_dependency_simple(p, "SINTY_TEST_ENV", "/nonexistent/sinty", "foo.conf", c.GST_PLUGIN_DEPENDENCY_FLAG_NONE);
    c.gst_plugin_add_status_info(p, "loaded fine");
    c.gst_plugin_set_cache_data(p, c.gst_structure_new_empty("sinty-cache"));
    return 1;
}

export var gst_plugin_desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "sintytest",
    .description = "Sinty test plugin",
    .plugin_init = init,
    .version = "1.2.3",
    .license = "LGPL",
    .source = "sinty-media",
    .package = "sinty-media tests",
    .origin = "https://sinty.dev",
    .release_datetime = "2026-10-21",
    ._gst_reserved = .{null} ** 4,
};

export fn gst_plugin_sintytest_get_desc() *const c.GstPluginDesc {
    return &gst_plugin_desc;
}
