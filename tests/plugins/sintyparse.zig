const std = @import("std");
const c = @import("c").c;

var any_src = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "audio/x-raw" } };
var any_sink = c.GstStaticPadTemplate{ .name_template = "sink", .direction = c.GST_PAD_SINK, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "ANY" } };
var some_src = c.GstStaticPadTemplate{ .name_template = "src_%u", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_SOMETIMES, .static_caps = .{ .caps = null, .string = "ANY" } };
var req_src = c.GstStaticPadTemplate{ .name_template = "src_%u", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_REQUEST, .static_caps = .{ .caps = null, .string = "ANY" } };

const Src = extern struct {
    element: c.GstElement,
    num: c.gint,
    label: [*c]u8,
    target: ?*c.GstElement,
};

const PROP_NUM = 1;
const PROP_LABEL = 2;
const PROP_TARGET = 3;

fn srcSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Src = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_NUM => s.num = c.g_value_get_int(v),
        PROP_LABEL => {
            c.g_free(s.label);
            s.label = c.g_value_dup_string(v);
        },
        PROP_TARGET => {
            if (s.target != null) c.gst_object_unref(s.target);
            s.target = @ptrCast(@alignCast(c.g_value_dup_object(v)));
        },
        else => {},
    }
}

fn srcGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Src = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_NUM => c.g_value_set_int(v, s.num),
        PROP_LABEL => c.g_value_set_string(v, s.label),
        PROP_TARGET => c.g_value_set_object(v, s.target),
        else => {},
    }
}

fn srcClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = srcSet;
    gc.get_property = srcGet;
    c.g_object_class_install_property(gc, PROP_NUM, c.g_param_spec_int("num", "Num", "n", 0, 100, 1, c.G_PARAM_READWRITE));
    c.g_object_class_install_property(gc, PROP_LABEL, c.g_param_spec_string("label", "Label", "l", null, c.G_PARAM_READWRITE));
    c.g_object_class_install_property(gc, PROP_TARGET, c.g_param_spec_object("target", "Target", "t", c.gst_element_get_type(), c.G_PARAM_READWRITE));
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &any_src);
    c.gst_element_class_set_static_metadata(ek, "Sinty src", "Source", "s", "Sinty");
}

fn srcInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const e: ?*c.GstElement = @ptrCast(@alignCast(instance));
    _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&any_src, "src"));
}

fn srcType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) {
        S.t = c.g_type_register_static_simple(c.gst_element_get_type(), "SintySrc", @sizeOf(c.GstElementClass), srcClassInit, @sizeOf(Src), srcInit, 0);
        const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(S.t, c.gst_preset_get_type(), &info);
    }
    return S.t;
}

fn sinkClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &any_sink);
    c.gst_element_class_set_static_metadata(ek, "Sinty sink", "Sink", "s", "Sinty");
}

fn chain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    c.gst_buffer_unref(b);
    return c.GST_FLOW_OK;
}

fn sinkInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const e: ?*c.GstElement = @ptrCast(@alignCast(instance));
    const p = c.gst_pad_new_from_static_template(&any_sink, "sink");
    c.gst_pad_set_chain_function_full(p, chain, null, null);
    _ = c.gst_element_add_pad(e, p);
}

fn simple(comptime name: [:0]const u8, class_init: c.GClassInitFunc, instance_init: c.GInstanceInitFunc) c.GType {
    const S = struct {
        const label = name;
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_element_get_type(), name, @sizeOf(c.GstElementClass), class_init, @sizeOf(c.GstElement), instance_init, 0);
    return S.t;
}

fn filterClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &any_sink);
    c.gst_element_class_add_static_pad_template(ek, &any_src);
    c.gst_element_class_set_static_metadata(ek, "Sinty filter", "Filter", "f", "Sinty");
}

fn filterInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const e: ?*c.GstElement = @ptrCast(@alignCast(instance));
    _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&any_sink, "sink"));
    _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&any_src, "src"));
}

fn requestPad(e: ?*c.GstElement, t: ?*c.GstPadTemplate, name: [*c]const u8, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    const S = struct {
        var n: c_int = 0;
    };
    const pname = if (name != null) c.g_strdup(name) else c.g_strdup_printf("src_%d", S.n);
    S.n += 1;
    const p = c.gst_pad_new_from_template(t, pname);
    c.g_free(pname);
    _ = c.gst_element_add_pad(e, p);
    return p;
}

fn teeClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &any_sink);
    c.gst_element_class_add_static_pad_template(ek, &req_src);
    c.gst_element_class_set_static_metadata(ek, "Sinty tee", "Generic", "t", "Sinty");
    ek.request_new_pad = requestPad;
}

fn teeInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const e: ?*c.GstElement = @ptrCast(@alignCast(instance));
    _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&any_sink, "sink"));
}

var demux_parent: ?*c.GstElementClass = null;

fn demuxChange(e: ?*c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY) {
        _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&some_src, "src_0"));
        _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&some_src, "src_1"));
        c.gst_element_no_more_pads(e);
    }
    return demux_parent.?.change_state.?(e, t);
}

fn demuxClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    demux_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &any_sink);
    c.gst_element_class_add_static_pad_template(ek, &some_src);
    c.gst_element_class_set_static_metadata(ek, "Sinty demux", "Demuxer", "d", "Sinty");
    ek.change_state = demuxChange;
}

var childbin_parent: ?*c.GObjectClass = null;

fn childbinConstructed(o: [*c]c.GObject) callconv(.c) void {
    childbin_parent.?.constructed.?(o);
    _ = c.gst_bin_add(@ptrCast(@alignCast(o)), c.gst_element_factory_make("sintysrc", "inner"));
}

fn childbinClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    childbin_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).constructed = childbinConstructed;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Sinty childbin", "Bin", "b", "Sinty");
}

fn childbinType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_bin_get_type(), "SintyChildBin", @sizeOf(c.GstBinClass), childbinClassInit, @sizeOf(c.GstBin), null, 0);
    return S.t;
}

fn init(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    _ = c.gst_element_register(p, "sintysrc", c.GST_RANK_NONE, srcType());
    _ = c.gst_element_register(p, "sintysink", c.GST_RANK_NONE, simple("SintySink", sinkClassInit, sinkInit));
    _ = c.gst_element_register(p, "sintyfilter", c.GST_RANK_NONE, simple("SintyFilter", filterClassInit, filterInit));
    _ = c.gst_element_register(p, "sintytee", c.GST_RANK_NONE, simple("SintyTee", teeClassInit, teeInit));
    _ = c.gst_element_register(p, "sintydemux", c.GST_RANK_NONE, simple("SintyDemux", demuxClassInit, teeInit));
    _ = c.gst_element_register(p, "sintychildbin", c.GST_RANK_NONE, childbinType());
    return 1;
}

export var gst_plugin_desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "sintyparse",
    .description = "Elements for parse tests",
    .plugin_init = init,
    .version = "1.0",
    .license = "LGPL",
    .source = "sinty-media",
    .package = "sinty-media tests",
    .origin = "https://sinty.dev",
    .release_datetime = null,
    ._gst_reserved = .{null} ** 4,
};
