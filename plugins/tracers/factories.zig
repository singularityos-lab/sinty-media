const cm = @import("../common.zig");
const c = cm.c;
const spec = @import("spec.zig");

const N: ?*anyopaque = null;

const Self = extern struct {
    parent: c.GstTracer,
};

const Class = extern struct {
    parent: c.GstTracerClass,
};

var once: cm.Once = .{};
var tr_used: ?*c.GstTracerRecord = null;

fn names(f: ?*c.GstPluginFeature, factory: *[*c]const u8, plugin_name: *[*c]const u8) void {
    factory.* = c.gst_plugin_feature_get_name(f);
    plugin_name.* = c.gst_plugin_feature_get_plugin_name(f);
    if (factory.* == null) factory.* = "";
    if (plugin_name.* == null) plugin_name.* = "";
}

fn elementNew(_: ?*anyopaque, ts: u64, el: ?*c.GstElement) callconv(.c) void {
    const factory = c.gst_element_get_factory(el) orelse return;
    const f: ?*c.GstPluginFeature = @ptrCast(factory);
    var fname: [*c]const u8 = null;
    var pname: [*c]const u8 = null;
    names(f, &fname, &pname);
    var src: [*c]const u8 = "Unknown";
    const p = c.gst_plugin_feature_get_plugin(f);
    if (p != null) src = c.gst_plugin_get_source(p);
    c.gst_tracer_record_log(tr_used, spec.thread(), ts, "element", fname, pname, src);
    if (p != null) c.gst_object_unref(p);
}

fn featureLoaded(_: ?*anyopaque, ts: u64, f: ?*c.GstPluginFeature) callconv(.c) void {
    if (cm.isA(f, c.gst_element_factory_get_type())) return;
    const kind: [*:0]const u8 = if (cm.isA(f, c.gst_type_find_factory_get_type()))
        "typefind"
    else if (cm.isA(f, c.gst_device_provider_factory_get_type()))
        "device-provider"
    else if (cm.isA(f, c.gst_dynamic_type_factory_get_type()))
        "dynamic-type"
    else
        unreachable;
    var fname: [*c]const u8 = null;
    var pname: [*c]const u8 = null;
    names(f, &fname, &pname);
    var src: [*c]const u8 = "Unknown";
    const p = c.gst_plugin_feature_get_plugin(f);
    if (p != null) src = c.gst_plugin_get_source(p);
    if (src == null) src = "";
    c.gst_tracer_record_log(tr_used, spec.thread(), ts, kind, fname, pname, src);
    if (p != null) c.gst_object_unref(p);
}

fn classInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {
    tr_used = c.gst_tracer_record_new("factory-used.class", "thread-id", c.gst_structure_get_type(), spec.threadId(), "ts", c.gst_structure_get_type(), spec.ts(), "factory-type", c.gst_structure_get_type(), spec.value(c.G_TYPE_STRING, "type name of the factory"), "factory", c.gst_structure_get_type(), spec.value(c.G_TYPE_STRING, "name of the object factory"), "plugin", c.gst_structure_get_type(), spec.value(c.G_TYPE_STRING, "name of the plugin"), "source-module", c.gst_structure_get_type(), spec.value(c.G_TYPE_STRING, "name of the source module this feature is from"), N);
    spec.maybeLeaked(tr_used);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    spec.hook(inst, "element-new", &elementNew);
    spec.hook(inst, "plugin-feature-loaded", &featureLoaded);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_tracer_get_type(), "GstFactoriesTracer", Class, Self, classInit, init);
        }
    }.f);
}
