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

fn createElement(_: ?*c.GstDevice, name: [*c]const u8) callconv(.c) ?*c.GstElement {
    return c.gst_element_factory_make("sintytestsrc", name);
}

fn devClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const dk: *c.GstDeviceClass = @ptrCast(@alignCast(k));
    dk.create_element = createElement;
}

fn devType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_device_get_type(), "SintyTestDevice", @sizeOf(c.GstDeviceClass), devClassInit, @sizeOf(c.GstDevice), null, 0);
    return S.t;
}

fn makeDevice(name: [*c]const u8, klass: [*c]const u8, caps: [*c]const u8) ?*c.GstDevice {
    const cp = c.gst_caps_from_string(caps);
    defer c.gst_caps_unref(cp);
    const props = c.gst_structure_new("props", "card", c.G_TYPE_INT, @as(c_int, 3), @as([*c]const u8, null));
    defer c.gst_structure_free(props);
    return @ptrCast(@alignCast(c.g_object_new(devType(), "display-name", name, "device-class", klass, "caps", cp, "properties", props, @as([*c]const u8, null))));
}

fn probe(_: ?*c.GstDeviceProvider) callconv(.c) ?*c.GList {
    var l: ?*c.GList = null;
    l = c.g_list_append(l, makeDevice("Sinty Mic", "Audio/Source", "audio/x-raw"));
    l = c.g_list_append(l, makeDevice("Sinty Cam", "Video/Source", "video/x-raw"));
    return l;
}

fn providerClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const pk: *c.GstDeviceProviderClass = @ptrCast(@alignCast(k));
    pk.probe = probe;
    c.gst_device_provider_class_set_static_metadata(pk, "Sinty devices", "Source/Audio/Video", "Lists test devices", "Sinty");
}

fn providerType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_device_provider_get_type(), "SintyTestProvider", @sizeOf(c.GstDeviceProviderClass), providerClassInit, @sizeOf(c.GstDeviceProvider), null, 0);
    return S.t;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "  [trace] " ++ fmt ++ "\n", args) catch return;
    _ = std.c.write(1, t.ptr, t.len);
}

fn nm(o: anytype) []const u8 {
    if (o == null) return "(null)";
    const n = @as(*c.GstObject, @ptrCast(@alignCast(o))).name;
    return if (n == null) "(null)" else std.mem.span(n);
}

fn onPushPre(_: ?*c.GObject, _: u64, pad: ?*c.GstPad, buf: [*c]c.GstBuffer) callconv(.c) void {
    say("push-pre {s} size {d}", .{ nm(pad), c.gst_buffer_get_size(buf) });
}

fn onPushPost(_: ?*c.GObject, _: u64, pad: ?*c.GstPad, res: c.GstFlowReturn) callconv(.c) void {
    say("push-post {s} {d}", .{ nm(pad), res });
}

fn onLinkPost(_: ?*c.GObject, _: u64, src: ?*c.GstPad, sink: ?*c.GstPad, res: c.GstPadLinkReturn) callconv(.c) void {
    say("link-post {s}->{s} {d}", .{ nm(src), nm(sink), res });
}

fn onUnlinkPost(_: ?*c.GObject, _: u64, src: ?*c.GstPad, sink: ?*c.GstPad, res: c.gboolean) callconv(.c) void {
    say("unlink-post {s}->{s} {d}", .{ nm(src), nm(sink), res });
}

fn onElementNew(_: ?*c.GObject, _: u64, e: ?*c.GstElement) callconv(.c) void {
    say("element-new {s}", .{std.mem.span(c.g_type_name(c.G_TYPE_FROM_INSTANCE(e)))});
}

fn onBinAddPost(_: ?*c.GObject, _: u64, b: ?*c.GstBin, e: ?*c.GstElement, res: c.gboolean) callconv(.c) void {
    say("bin-add-post {s} {s} {d}", .{ nm(b), nm(e), res });
}

fn onBinRemovePost(_: ?*c.GObject, _: u64, b: ?*c.GstBin, res: c.gboolean) callconv(.c) void {
    say("bin-remove-post {s} {d}", .{ nm(b), res });
}

fn onPost(_: ?*c.GObject, _: u64, e: ?*c.GstElement, m: [*c]c.GstMessage) callconv(.c) void {
    say("post-pre {s} {s}", .{ nm(e), std.mem.span(c.gst_message_type_get_name(m.*.type)) });
}

fn onStatePost(_: ?*c.GObject, _: u64, e: ?*c.GstElement, t: c.GstStateChange, r: c.GstStateChangeReturn) callconv(.c) void {
    say("state-post {s} {s} {d}", .{ nm(e), std.mem.span(c.gst_state_change_get_name(t)), r });
}

fn onQueryPost(_: ?*c.GObject, _: u64, pad: ?*c.GstPad, q: [*c]c.GstQuery, res: c.gboolean) callconv(.c) void {
    say("pad-query-post {s} {s} {d}", .{ nm(pad), std.mem.span(c.gst_query_type_get_name(q.*.type)), res });
}

fn onEventPre(_: ?*c.GObject, _: u64, pad: ?*c.GstPad, e: [*c]c.GstEvent) callconv(.c) void {
    say("push-event-pre {s} {s}", .{ nm(pad), std.mem.span(c.gst_event_type_get_name(e.*.type)) });
}

fn onSendEventPost(_: ?*c.GObject, _: u64, pad: ?*c.GstPad, r: c.GstFlowReturn) callconv(.c) void {
    say("send-event-post {s} {d}", .{ nm(pad), r });
}

fn onFeature(_: ?*c.GObject, _: u64, f: ?*c.GstPluginFeature) callconv(.c) void {
    say("feature-loaded {s}", .{nm(f)});
}

fn tracerInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const t: ?*c.GstTracer = @ptrCast(@alignCast(instance));
    c.gst_tracing_register_hook(t, "pad-push-pre", @ptrCast(&onPushPre));
    c.gst_tracing_register_hook(t, "pad-push-post", @ptrCast(&onPushPost));
    c.gst_tracing_register_hook(t, "pad-link-post", @ptrCast(&onLinkPost));
    c.gst_tracing_register_hook(t, "pad-unlink-post", @ptrCast(&onUnlinkPost));
    c.gst_tracing_register_hook(t, "element-new", @ptrCast(&onElementNew));
    c.gst_tracing_register_hook(t, "bin-add-post", @ptrCast(&onBinAddPost));
    c.gst_tracing_register_hook(t, "bin-remove-post", @ptrCast(&onBinRemovePost));
    c.gst_tracing_register_hook(t, "element-post-message-pre", @ptrCast(&onPost));
    c.gst_tracing_register_hook(t, "element-change-state-post", @ptrCast(&onStatePost));
    c.gst_tracing_register_hook(t, "pad-query-post", @ptrCast(&onQueryPost));
    c.gst_tracing_register_hook(t, "pad-push-event-pre", @ptrCast(&onEventPre));
    c.gst_tracing_register_hook(t, "pad-send-event-post", @ptrCast(&onSendEventPost));
    c.gst_tracing_register_hook(t, "plugin-feature-loaded", @ptrCast(&onFeature));
}

fn tracerType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_tracer_get_type(), "SintyTestTracer", @sizeOf(c.GstTracerClass), null, @sizeOf(c.GstTracer), tracerInit, 0);
    return S.t;
}

fn init(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    _ = c.gst_tracer_register(p, "sintytracer", tracerType());
    _ = c.gst_device_provider_register(p, "sintydevprov", c.GST_RANK_PRIMARY, providerType());
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
