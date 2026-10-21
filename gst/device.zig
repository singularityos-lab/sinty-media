const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const object = @import("object.zig");
const core = @import("core.zig");
const feature = @import("pluginfeature.zig");
const plugin = @import("plugin.zig");
const registry = @import("registry.zig");
const regcache = @import("regcache.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Device = c.GstDevice;
const Provider = c.GstDeviceProvider;
const ProviderClass = c.GstDeviceProviderClass;
const Element = c.GstElement;

const DevicePrivate = extern struct {
    caps: [*c]c.GstCaps,
    device_class: [*c]u8,
    display_name: [*c]u8,
    properties: [*c]c.GstStructure,
};

const ProviderPrivate = extern struct {
    bus: [*c]c.GstBus,
    start_lock: c.GMutex,
    started_count: c.gint,
    hidden_providers: ?*c.GList,
};

pub const Factory = extern struct {
    feature: feature.Feature,
    type: c.GType,
    provider: [*c]Provider,
    metadata: c.gpointer,
    reserved: [4]c.gpointer,

    pub const Header = c.struct__GstDeviceProviderFactory;
};

const FactoryClass = extern struct {
    parent: feature.FeatureClass,
    reserved: [4]c.gpointer,
};

const PROP_DISPLAY_NAME = 1;
const PROP_CAPS = 2;
const PROP_DEVICE_CLASS = 3;
const PROP_PROPERTIES = 4;

var device_once: gtype.Once = .{};
var device_offset: c.gint = 0;
var device_parent: ?*c.GObjectClass = null;
var removed_signal: c.guint = 0;

var provider_once: gtype.Once = .{};
var provider_offset: c.gint = 0;
var provider_parent: ?*c.GObjectClass = null;
var hidden_signal: c.guint = 0;
var unhidden_signal: c.guint = 0;
pub export var __gst_deviceproviderclass_factory: c.GQuark = 0;

var factory_once: gtype.Once = .{};
var factory_parent: ?*c.GObjectClass = null;
var factory_cat: [*c]c.GstDebugCategory = null;

fn privOf(comptime T: type, p: anytype, offset: c.gint) *T {
    const base: [*]u8 = @ptrCast(@constCast(p));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
}

fn dpriv(d: anytype) *DevicePrivate {
    return @ptrCast(@alignCast(@as([*c]Device, @ptrCast(@alignCast(d)))[0].priv));
}

fn ppriv(p: anytype) *ProviderPrivate {
    return @ptrCast(@alignCast(@as([*c]Provider, @ptrCast(@alignCast(p)))[0].priv));
}

pub fn isDevice(p: anytype) bool {
    return gtype.instanceOf(p, gst_device_get_type());
}

fn isProvider(p: anytype) bool {
    return gtype.instanceOf(p, gst_device_provider_get_type());
}

fn isFactory(p: anytype) bool {
    return gtype.instanceOf(p, gst_device_provider_factory_get_type());
}

fn fof(p: anytype) [*c]Factory {
    return @ptrCast(@alignCast(p));
}

fn deviceClass(d: anytype) *c.GstDeviceClass {
    return gtype.classPeek(c.GstDeviceClass, d);
}

fn providerClass(p: anytype) *ProviderClass {
    return gtype.classPeek(ProviderClass, p);
}

pub export fn gst_device_get_type() c.GType {
    return device_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstDevice", c.GstDeviceClass, Device, deviceClassInit, deviceInit, c.G_TYPE_FLAG_ABSTRACT);
            device_offset = c.g_type_add_instance_private(t, @sizeOf(DevicePrivate));
            return t;
        }
    }.f);
}

fn deviceClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &device_offset);
    device_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.get_property = deviceGet;
    gc.set_property = deviceSet;
    gc.finalize = deviceFinalize;
    const fl = c.G_PARAM_STATIC_STRINGS | c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY;
    c.g_object_class_install_property(gc, PROP_DISPLAY_NAME, c.g_param_spec_string("display-name", "Display Name", "The user-friendly name of the device", "", fl));
    c.g_object_class_install_property(gc, PROP_CAPS, c.g_param_spec_boxed("caps", "Device Caps", "The possible caps of a device", c.gst_caps_get_type(), fl));
    c.g_object_class_install_property(gc, PROP_DEVICE_CLASS, c.g_param_spec_string("device-class", "Device Class", "The Class of the device", "", fl));
    c.g_object_class_install_property(gc, PROP_PROPERTIES, c.g_param_spec_boxed("properties", "Properties", "The extra properties of the device", c.gst_structure_get_type(), fl));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    removed_signal = c.g_signal_new("removed", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, 1 << c.G_TYPE_FUNDAMENTAL_SHIFT, @as(c.guint, 0));
}

fn deviceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const d: [*c]Device = @ptrCast(@alignCast(instance));
    d[0].priv = @ptrCast(privOf(DevicePrivate, instance, device_offset));
}

fn deviceFinalize(o: [*c]c.GObject) callconv(.c) void {
    const p = dpriv(o);
    _ = c.gst_caps_replace(&p.caps, null);
    if (p.properties != null) c.gst_structure_free(p.properties);
    c.g_free(p.display_name);
    c.g_free(p.device_class);
    device_parent.?.finalize.?(o);
}

fn deviceGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const d: [*c]Device = @ptrCast(@alignCast(o));
    const p = dpriv(d);
    switch (id) {
        PROP_DISPLAY_NAME => c.g_value_take_string(v, gst_device_get_display_name(d)),
        PROP_CAPS => if (p.caps != null) c.g_value_take_boxed(v, gst_device_get_caps(d)),
        PROP_DEVICE_CLASS => c.g_value_take_string(v, gst_device_get_device_class(d)),
        PROP_PROPERTIES => if (p.properties != null) c.g_value_take_boxed(v, gst_device_get_properties(d)),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn deviceSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = dpriv(o);
    switch (id) {
        PROP_DISPLAY_NAME => p.display_name = c.g_value_dup_string(v),
        PROP_CAPS => _ = c.gst_caps_replace(&p.caps, @ptrCast(@alignCast(c.g_value_get_boxed(v)))),
        PROP_DEVICE_CLASS => p.device_class = c.g_value_dup_string(v),
        PROP_PROPERTIES => {
            if (p.properties != null) c.gst_structure_free(p.properties);
            p.properties = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
        },
        else => object.warnBadProperty(o, id, pspec),
    }
}

pub export fn gst_device_create_element(d: [*c]Device, name: [*c]const u8) [*c]Element {
    const k = deviceClass(d);
    if (!check.that(isDevice(d), "gst_device_create_element", "GST_IS_DEVICE (device)")) return null;
    const e = if (k.create_element) |f| f(d, name) else null;
    if (e != null and c.g_object_is_floating(e) == 0) c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "The created element should be floating, this is probably caused by faulty bindings");
    return e;
}

pub export fn gst_device_get_caps(d: [*c]Device) [*c]c.GstCaps {
    if (!check.that(isDevice(d), "gst_device_get_caps", "GST_IS_DEVICE (device)")) return null;
    const p = dpriv(d);
    return if (p.caps != null) c.gst_caps_ref(p.caps) else null;
}

pub export fn gst_device_get_display_name(d: [*c]Device) [*c]u8 {
    if (!check.that(isDevice(d), "gst_device_get_display_name", "GST_IS_DEVICE (device)")) return null;
    const p = dpriv(d);
    return c.g_strdup(if (p.display_name != null) p.display_name else "");
}

pub export fn gst_device_get_device_class(d: [*c]Device) [*c]u8 {
    if (!check.that(isDevice(d), "gst_device_get_device_class", "GST_IS_DEVICE (device)")) return null;
    const p = dpriv(d);
    return c.g_strdup(if (p.device_class != null) p.device_class else "");
}

pub export fn gst_device_get_properties(d: [*c]Device) [*c]c.GstStructure {
    if (!check.that(isDevice(d), "gst_device_get_properties", "GST_IS_DEVICE (device)")) return null;
    const p = dpriv(d);
    return if (p.properties != null) c.gst_structure_copy(p.properties) else null;
}

pub export fn gst_device_reconfigure_element(d: [*c]Device, e: [*c]Element) c.gboolean {
    const k = deviceClass(d);
    if (!check.that(isDevice(d), "gst_device_reconfigure_element", "GST_IS_DEVICE (device)")) return 0;
    return if (k.reconfigure_element) |f| f(d, e) else 0;
}

pub fn classMatches(klass: [*c]const u8, classes: [*c][*c]u8) bool {
    var cl = classes;
    if (cl == null) return true;
    while (cl[0] != null) : (cl += 1) {
        if (cl[0][0] == 0) continue;
        const found = c.strstr(klass, cl[0]);
        if (found == null) return false;
        if (found != klass and (found - 1)[0] != '/') return false;
        const len = c.strlen(cl[0]);
        if (found[len] != 0 and found[len] != '/') return false;
    }
    return true;
}

pub export fn gst_device_has_classesv(d: [*c]Device, classes: [*c][*c]u8) c.gboolean {
    if (!check.that(isDevice(d), "gst_device_has_classesv", "GST_IS_DEVICE (device)")) return 0;
    if (classes == null) return 1;
    return @intFromBool(classMatches(dpriv(d).device_class, classes));
}

pub export fn gst_device_has_classes(d: [*c]Device, classes: [*c]const u8) c.gboolean {
    if (!check.that(isDevice(d), "gst_device_has_classes", "GST_IS_DEVICE (device)")) return 0;
    if (classes == null) return 1;
    const v = c.g_strsplit(classes, "/", 0);
    defer c.g_strfreev(v);
    return gst_device_has_classesv(d, v);
}

pub export fn gst_device_provider_get_type() c.GType {
    return provider_once.get(struct {
        fn f() c.GType {
            const tinfo = c.GTypeInfo{ .class_size = @sizeOf(ProviderClass), .base_init = providerBaseInit, .base_finalize = null, .class_init = providerClassInit, .class_finalize = null, .class_data = null, .instance_size = @sizeOf(Provider), .n_preallocs = 0, .instance_init = providerInit, .value_table = null };
            const t = c.g_type_register_static(object.gst_object_get_type(), "GstDeviceProvider", &tinfo, c.G_TYPE_FLAG_ABSTRACT);
            provider_offset = c.g_type_add_instance_private(t, @sizeOf(ProviderPrivate));
            __gst_deviceproviderclass_factory = c.g_quark_from_static_string("GST_DEVICEPROVIDERCLASS_FACTORY");
            return t;
        }
    }.f);
}

fn providerBaseInit(klass: c.gpointer) callconv(.c) void {
    const k: *ProviderClass = @ptrCast(@alignCast(klass));
    k.metadata = if (k.metadata != null) c.gst_structure_copy(@ptrCast(@alignCast(k.metadata))) else c.gst_structure_new_empty("metadata");
    k.factory = @ptrCast(@alignCast(c.g_type_get_qdata(@as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type, __gst_deviceproviderclass_factory)));
}

fn providerClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    provider_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    if (provider_offset != 0) c.g_type_class_adjust_private_offset(klass, &provider_offset);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.dispose = providerDispose;
    gc.finalize = providerFinalize;
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    const none: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    const str: c.GType = 16 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    hidden_signal = c.g_signal_new("provider-hidden", t, c.G_SIGNAL_RUN_FIRST, 0, null, null, null, none, @as(c.guint, 1), str);
    unhidden_signal = c.g_signal_new("provider-unhidden", t, c.G_SIGNAL_RUN_FIRST, 0, null, null, null, none, @as(c.guint, 1), str);
}

fn providerInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Provider = @ptrCast(@alignCast(instance));
    p[0].priv = @ptrCast(privOf(ProviderPrivate, instance, provider_offset));
    const d = ppriv(p);
    c.g_mutex_init(&d.start_lock);
    d.started_count = 0;
    d.bus = c.gst_bus_new();
    c.gst_bus_set_flushing(d.bus, 1);
}

fn unparentEach(list: *?*c.GList) void {
    var l = list.*;
    list.* = null;
    while (l) |n| : (l = n.next) object.gst_object_unparent(@ptrCast(@alignCast(n.data)));
    c.g_list_free(l);
}

fn clearDevices(p: [*c]Provider) void {
    const devs: ?*c.GList = p[0].devices;
    p[0].devices = null;
    var l = devs;
    while (l) |n| : (l = n.next) object.gst_object_unparent(@ptrCast(@alignCast(n.data)));
    c.g_list_free(devs);
    const d = ppriv(p);
    c.g_list_free_full(d.hidden_providers, c.g_free);
    d.hidden_providers = null;
}

fn providerDispose(o: [*c]c.GObject) callconv(.c) void {
    const p: [*c]Provider = @ptrCast(@alignCast(o));
    _ = object.gst_object_replace(@ptrCast(&ppriv(p).bus), null);
    object.lock(p);
    clearDevices(p);
    object.unlock(p);
    provider_parent.?.dispose.?(o);
}

fn providerFinalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&ppriv(o).start_lock);
    provider_parent.?.finalize.?(o);
}

fn isProviderClass(k: anytype) bool {
    return k != null and c.g_type_check_class_is_a(@ptrCast(@alignCast(k)), gst_device_provider_get_type()) != 0;
}

fn metaOf(k: [*c]ProviderClass) [*c]c.GstStructure {
    return @ptrCast(@alignCast(k[0].metadata));
}

pub export fn gst_device_provider_class_add_metadata(k: [*c]ProviderClass, key: [*c]const u8, v: [*c]const u8) void {
    const f = "gst_device_provider_class_add_metadata";
    if (!check.that(isProviderClass(k), f, "GST_IS_DEVICE_PROVIDER_CLASS (klass)")) return;
    if (!check.that(key != null, f, "key != NULL")) return;
    if (!check.that(v != null, f, "value != NULL")) return;
    c.gst_structure_set(metaOf(k), key, c.G_TYPE_STRING, v, @as([*c]const u8, null));
}

fn takeStatic(s: [*c]c.GstStructure, key: [*c]const u8, v: [*c]const u8) void {
    var gv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, c.G_TYPE_STRING);
    c.g_value_set_static_string(&gv, v);
    c.gst_structure_take_value(s, key, &gv);
}

pub export fn gst_device_provider_class_add_static_metadata(k: [*c]ProviderClass, key: [*c]const u8, v: [*c]const u8) void {
    const f = "gst_device_provider_class_add_static_metadata";
    if (!check.that(isProviderClass(k), f, "GST_IS_DEVICE_PROVIDER_CLASS (klass)")) return;
    if (!check.that(key != null, f, "key != NULL")) return;
    if (!check.that(v != null, f, "value != NULL")) return;
    takeStatic(metaOf(k), key, v);
}

fn nonEmpty(s: [*c]const u8) bool {
    return s != null and s[0] != 0;
}

fn metadataArgs(comptime f: []const u8, k: [*c]ProviderClass, longname: [*c]const u8, classification: [*c]const u8, description: [*c]const u8, author: [*c]const u8) bool {
    if (!check.that(isProviderClass(k), f, "GST_IS_DEVICE_PROVIDER_CLASS (klass)")) return false;
    if (!check.that(nonEmpty(longname), f, "longname != NULL && *longname != '\\0'")) return false;
    if (!check.that(nonEmpty(classification), f, "classification != NULL && *classification != '\\0'")) return false;
    if (!check.that(nonEmpty(description), f, "description != NULL && *description != '\\0'")) return false;
    if (!check.that(nonEmpty(author), f, "author != NULL && *author != '\\0'")) return false;
    return true;
}

pub export fn gst_device_provider_class_set_metadata(k: [*c]ProviderClass, longname: [*c]const u8, classification: [*c]const u8, description: [*c]const u8, author: [*c]const u8) void {
    if (!metadataArgs("gst_device_provider_class_set_metadata", k, longname, classification, description, author)) return;
    c.gst_structure_set(metaOf(k), c.GST_ELEMENT_METADATA_LONGNAME, c.G_TYPE_STRING, longname, c.GST_ELEMENT_METADATA_KLASS, c.G_TYPE_STRING, classification, c.GST_ELEMENT_METADATA_DESCRIPTION, c.G_TYPE_STRING, description, c.GST_ELEMENT_METADATA_AUTHOR, c.G_TYPE_STRING, author, @as([*c]const u8, null));
}

pub export fn gst_device_provider_class_set_static_metadata(k: [*c]ProviderClass, longname: [*c]const u8, classification: [*c]const u8, description: [*c]const u8, author: [*c]const u8) void {
    if (!metadataArgs("gst_device_provider_class_set_static_metadata", k, longname, classification, description, author)) return;
    const s = metaOf(k);
    takeStatic(s, c.GST_ELEMENT_METADATA_LONGNAME, longname);
    takeStatic(s, c.GST_ELEMENT_METADATA_KLASS, classification);
    takeStatic(s, c.GST_ELEMENT_METADATA_DESCRIPTION, description);
    takeStatic(s, c.GST_ELEMENT_METADATA_AUTHOR, author);
}

pub export fn gst_device_provider_class_get_metadata(k: [*c]ProviderClass, key: [*c]const u8) [*c]const u8 {
    if (!check.that(isProviderClass(k), "gst_device_provider_class_get_metadata", "GST_IS_DEVICE_PROVIDER_CLASS (klass)")) return null;
    if (!check.that(key != null, "gst_device_provider_class_get_metadata", "key != NULL")) return null;
    return c.gst_structure_get_string(metaOf(k), key);
}

pub export fn gst_device_provider_get_metadata(p: [*c]Provider, key: [*c]const u8) [*c]const u8 {
    if (!check.that(isProvider(p), "gst_device_provider_get_metadata", "GST_IS_DEVICE_PROVIDER (provider)")) return null;
    if (!check.that(key != null, "gst_device_provider_get_metadata", "key != NULL")) return null;
    return gst_device_provider_class_get_metadata(providerClass(p), key);
}

pub export fn gst_device_provider_get_devices(p: [*c]Provider) ?*c.GList {
    if (!check.that(isProvider(p), "gst_device_provider_get_devices", "GST_IS_DEVICE_PROVIDER (provider)")) return null;
    const k = providerClass(p);
    const d = ppriv(p);
    c.g_mutex_lock(&d.start_lock);
    defer c.g_mutex_unlock(&d.start_lock);
    var devices: ?*c.GList = null;
    if (d.started_count > 0) {
        object.lock(p);
        var l: ?*c.GList = p[0].devices;
        while (l) |n| : (l = n.next) devices = c.g_list_prepend(devices, c.gst_object_ref(n.data));
        object.unlock(p);
    } else if (k.probe) |probe| {
        devices = probe(p);
        var l = devices;
        while (l) |n| : (l = n.next) if (c.g_object_is_floating(n.data) != 0) {
            _ = c.g_object_ref_sink(n.data);
        };
    }
    return devices;
}

pub export fn gst_device_provider_start(p: [*c]Provider) c.gboolean {
    if (!check.that(isProvider(p), "gst_device_provider_start", "GST_IS_DEVICE_PROVIDER (provider)")) return 0;
    const k = providerClass(p);
    const d = ppriv(p);
    c.g_mutex_lock(&d.start_lock);
    defer c.g_mutex_unlock(&d.start_lock);
    if (d.started_count > 0) {
        d.started_count += 1;
        return 1;
    }
    c.gst_bus_set_flushing(d.bus, 0);
    var ok = true;
    if (k.start) |start| {
        ok = start(p) != 0;
    } else {
        const devices = k.probe.?(p);
        var l: ?*c.GList = devices;
        while (l) |n| : (l = n.next) {
            const floating = c.g_object_is_floating(n.data) != 0;
            gst_device_provider_device_add(p, @ptrCast(@alignCast(n.data)));
            if (!floating) c.g_object_unref(n.data);
        }
        c.g_list_free(devices);
    }
    if (ok) {
        d.started_count += 1;
    } else if (d.started_count == 0) c.gst_bus_set_flushing(d.bus, 1);
    return @intFromBool(ok);
}

pub export fn gst_device_provider_stop(p: [*c]Provider) void {
    if (!check.that(isProvider(p), "gst_device_provider_stop", "GST_IS_DEVICE_PROVIDER (provider)")) return;
    const k = providerClass(p);
    const d = ppriv(p);
    c.g_mutex_lock(&d.start_lock);
    defer c.g_mutex_unlock(&d.start_lock);
    if (d.started_count == 1) {
        c.gst_bus_set_flushing(d.bus, 1);
        if (k.stop) |stop| stop(p);
        object.lock(p);
        clearDevices(p);
        object.unlock(p);
    } else if (d.started_count < 1) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Trying to stop a GstDeviceProvider %s which is already stopped", p[0].parent.name);
    }
    d.started_count -= 1;
}

pub export fn gst_device_provider_get_factory(p: [*c]Provider) [*c]Factory {
    if (!check.that(isProvider(p), "gst_device_provider_get_factory", "GST_IS_DEVICE_PROVIDER (provider)")) return null;
    return @ptrCast(@alignCast(providerClass(p).factory));
}

pub export fn gst_device_provider_can_monitor(p: [*c]Provider) c.gboolean {
    if (!check.that(isProvider(p), "gst_device_provider_can_monitor", "GST_IS_DEVICE_PROVIDER (provider)")) return 0;
    return @intFromBool(providerClass(p).start != null);
}

pub export fn gst_device_provider_get_bus(p: [*c]Provider) [*c]c.GstBus {
    if (!check.that(isProvider(p), "gst_device_provider_get_bus", "GST_IS_DEVICE_PROVIDER (provider)")) return null;
    return @ptrCast(@alignCast(c.gst_object_ref(ppriv(p).bus)));
}

pub export fn gst_device_provider_device_add(p: [*c]Provider, dev: [*c]Device) void {
    if (!check.that(isProvider(p), "gst_device_provider_device_add", "GST_IS_DEVICE_PROVIDER (provider)")) return;
    if (!check.that(isDevice(dev), "gst_device_provider_device_add", "GST_IS_DEVICE (device)")) return;
    if (object.gst_object_set_parent(@ptrCast(dev), @ptrCast(p)) == 0) return;
    object.lock(p);
    _ = c.gst_object_ref(dev);
    p[0].devices = c.g_list_prepend(p[0].devices, dev);
    object.unlock(p);
    _ = c.gst_bus_post(ppriv(p).bus, c.gst_message_new_device_added(@ptrCast(p), dev));
    c.gst_object_unref(dev);
}

pub export fn gst_device_provider_device_remove(p: [*c]Provider, dev: [*c]Device) void {
    if (!check.that(isProvider(p), "gst_device_provider_device_remove", "GST_IS_DEVICE_PROVIDER (provider)")) return;
    if (!check.that(isDevice(dev), "gst_device_provider_device_remove", "GST_IS_DEVICE (device)")) return;
    object.lock(p);
    const item = c.g_list_find(p[0].devices, dev);
    if (item != null) p[0].devices = c.g_list_delete_link(p[0].devices, item);
    object.unlock(p);
    const msg = c.gst_message_new_device_removed(@ptrCast(p), dev);
    c.g_signal_emit(dev, removed_signal, 0);
    _ = c.gst_bus_post(ppriv(p).bus, msg);
    if (item != null) object.gst_object_unparent(@ptrCast(dev));
}

pub export fn gst_device_provider_get_hidden_providers(p: [*c]Provider) [*c][*c]u8 {
    if (!check.that(isProvider(p), "gst_device_provider_get_hidden_providers", "GST_IS_DEVICE_PROVIDER (provider)")) return null;
    object.lock(p);
    defer object.unlock(p);
    const hidden = ppriv(p).hidden_providers;
    const len = c.g_list_length(hidden);
    if (len == 0) return null;
    const res: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc((len + 1) * @sizeOf([*c]u8))));
    var i: usize = 0;
    var l = hidden;
    while (l) |n| : (l = n.next) {
        res[i] = c.g_strdup(@ptrCast(n.data));
        i += 1;
    }
    res[i] = null;
    return res;
}

fn findName(list: ?*c.GList, name: [*c]const u8) ?*c.GList {
    return c.g_list_find_custom(list, name, @ptrCast(&c.g_strcmp0));
}

pub export fn gst_device_provider_hide_provider(p: [*c]Provider, name: [*c]const u8) void {
    if (!check.that(isProvider(p), "gst_device_provider_hide_provider", "GST_IS_DEVICE_PROVIDER (provider)")) return;
    if (!check.that(name != null, "gst_device_provider_hide_provider", "name != NULL")) return;
    object.lock(p);
    const d = ppriv(p);
    const fresh = findName(d.hidden_providers, name) == null;
    if (fresh) d.hidden_providers = c.g_list_prepend(d.hidden_providers, c.g_strdup(name));
    object.unlock(p);
    if (fresh) c.g_signal_emit(p, hidden_signal, 0, name);
}

pub export fn gst_device_provider_unhide_provider(p: [*c]Provider, name: [*c]const u8) void {
    if (!check.that(isProvider(p), "gst_device_provider_unhide_provider", "GST_IS_DEVICE_PROVIDER (provider)")) return;
    if (!check.that(name != null, "gst_device_provider_unhide_provider", "name != NULL")) return;
    object.lock(p);
    const d = ppriv(p);
    var gone: c.gpointer = null;
    if (findName(d.hidden_providers, name)) |found| {
        gone = found.data;
        d.hidden_providers = c.g_list_delete_link(d.hidden_providers, found);
    }
    object.unlock(p);
    if (gone != null) {
        c.g_signal_emit(p, unhidden_signal, 0, gone);
        c.g_free(gone);
    }
}

pub export fn gst_device_provider_device_changed(p: [*c]Provider, dev: [*c]Device, changed: [*c]Device) void {
    const f = "gst_device_provider_device_changed";
    if (!check.that(isProvider(p), f, "GST_IS_DEVICE_PROVIDER (provider)")) return;
    if (!check.that(isDevice(dev), f, "GST_IS_DEVICE (device)")) return;
    if (!check.that(isDevice(changed), f, "GST_IS_DEVICE (changed_device)")) return;
    object.lock(p);
    const item = c.g_list_find(p[0].devices, changed);
    if (item == null) {
        object.unlock(p);
        return;
    }
    if (object.gst_object_set_parent(@ptrCast(dev), @ptrCast(p)) == 0) {
        object.unlock(p);
        return;
    }
    item[0].data = dev;
    object.unlock(p);
    _ = c.gst_bus_post(ppriv(p).bus, c.gst_message_new_device_changed(@ptrCast(p), dev, changed));
    object.gst_object_unparent(@ptrCast(changed));
}

pub export fn gst_device_provider_is_started(p: [*c]Provider) c.gboolean {
    if (!check.that(isProvider(p), "gst_device_provider_is_started", "GST_IS_DEVICE_PROVIDER (provider)")) return 0;
    const d = ppriv(p);
    c.g_mutex_lock(&d.start_lock);
    defer c.g_mutex_unlock(&d.start_lock);
    return @intFromBool(d.started_count > 0);
}

pub export fn gst_device_provider_factory_get_type() c.GType {
    return factory_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(feature.gst_plugin_feature_get_type(), "GstDeviceProviderFactory", FactoryClass, Factory, factoryClassInit, null, 0);
            factory_cat = info._gst_debug_category_new("GST_DEVICE_PROVIDER_FACTORY", c.GST_DEBUG_BOLD | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_RED, "device provider factories keep information about installed device providers");
            return t;
        }
    }.f);
}

fn factoryClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    factory_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(klass))).finalize = factoryFinalize;
}

fn cleanup(f: [*c]Factory) void {
    if (f[0].metadata != null) {
        c.gst_structure_free(@ptrCast(@alignCast(f[0].metadata)));
        f[0].metadata = null;
    }
    f[0].type = 0;
}

fn factoryFinalize(o: [*c]c.GObject) callconv(.c) void {
    const f = fof(o);
    cleanup(f);
    const p = @atomicLoad([*c]Provider, &f[0].provider, .seq_cst);
    if (p != null) c.gst_object_unref(p);
    factory_parent.?.finalize.?(o);
}

pub export fn gst_device_provider_factory_find(name: [*c]const u8) [*c]Factory {
    if (!check.that(name != null, "gst_device_provider_factory_find", "name != NULL")) return null;
    return fof(registry.gst_registry_find_feature(registry.gst_registry_get(), name, gst_device_provider_factory_get_type()));
}

fn metaOk(k: [*c]ProviderClass, name: [*c]const u8, key: [*c]const u8) bool {
    const v = gst_device_provider_class_get_metadata(k, key);
    if (v != null and v[0] != 0) return true;
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Device provider factory metadata for '%s' has no valid %s field", name, key);
    return false;
}

pub export fn gst_device_provider_register(p: [*c]plugin.Plugin, name: [*c]const u8, rank: c.guint, t: c.GType) c.gboolean {
    if (!check.that(name != null, "gst_device_provider_register", "name != NULL")) return 0;
    if (!check.that(c.g_type_is_a(t, gst_device_provider_get_type()) != 0, "gst_device_provider_register", "g_type_is_a (type, GST_TYPE_DEVICE_PROVIDER)")) return 0;
    const reg = registry.gst_registry_get();
    const existing = registry.gst_registry_lookup_feature(reg, name);
    if (existing != null) {
        const f = fof(existing);
        f[0].type = t;
        existing[0].loaded = 1;
        c.g_type_set_qdata(t, __gst_deviceproviderclass_factory, f);
        c.gst_object_unref(existing);
        return 1;
    }
    const f = fof(c.g_object_new(gst_device_provider_factory_get_type(), @as([*c]const u8, null)));
    _ = c.gst_object_set_name(@ptrCast(f), name);
    c.g_type_set_qdata(t, __gst_deviceproviderclass_factory, f);
    const k: [*c]ProviderClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
    if (!metaOk(k, name, c.GST_ELEMENT_METADATA_LONGNAME) or !metaOk(k, name, c.GST_ELEMENT_METADATA_KLASS) or !metaOk(k, name, c.GST_ELEMENT_METADATA_DESCRIPTION) or !metaOk(k, name, c.GST_ELEMENT_METADATA_AUTHOR)) {
        cleanup(f);
        return 0;
    }
    f[0].type = t;
    f[0].metadata = c.gst_structure_copy(metaOf(k));
    feature.bindPlugin(@ptrCast(f), p);
    feature.gst_plugin_feature_set_rank(@ptrCast(f), rank);
    f[0].feature.loaded = 1;
    _ = registry.gst_registry_add_feature(reg, @ptrCast(f));
    return 1;
}

pub export fn gst_device_provider_factory_get(f_in: [*c]Factory) [*c]Provider {
    if (!check.that(f_in != null, "gst_device_provider_factory_get", "factory != NULL")) return null;
    const f = fof(feature.gst_plugin_feature_load(@ptrCast(f_in)));
    if (f == null) return null;
    if (f[0].type == 0) {
        c.gst_object_unref(f);
        return null;
    }
    const existing = @atomicLoad([*c]Provider, &f[0].provider, .seq_cst);
    if (existing != null) {
        c.gst_object_unref(f);
        return @ptrCast(@alignCast(c.gst_object_ref(existing)));
    }
    var p: [*c]Provider = @ptrCast(@alignCast(c.g_object_new(f[0].type, @as([*c]const u8, null))));
    if (p == null) {
        c.gst_object_unref(f);
        _ = check.that(false, "gst_device_provider_factory_get", "device_provider != NULL");
        return null;
    }
    const k = providerClass(p);
    if (@cmpxchgStrong(?*c.GstDeviceProviderFactory, &k.factory, null, @ptrCast(f), .seq_cst, .seq_cst) != null)
        c.gst_object_unref(f)
    else
        f[0].feature.object.flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
    _ = object.gst_object_ref_sink(p);
    if (@cmpxchgStrong([*c]Provider, &f[0].provider, null, p, .seq_cst, .seq_cst) != null) {
        c.gst_object_unref(p);
        p = @atomicLoad([*c]Provider, &f[0].provider, .seq_cst);
    }
    return @ptrCast(@alignCast(c.gst_object_ref(p)));
}

pub export fn gst_device_provider_factory_get_by_name(name: [*c]const u8) [*c]Provider {
    if (!check.that(name != null, "gst_device_provider_factory_get_by_name", "factoryname != NULL")) return null;
    if (!check.that(core.gst_is_initialized() != 0, "gst_device_provider_factory_get_by_name", "gst_is_initialized ()")) return null;
    const f = gst_device_provider_factory_find(name);
    if (f == null) return null;
    defer c.gst_object_unref(f);
    return gst_device_provider_factory_get(f);
}

pub export fn gst_device_provider_factory_get_device_provider_type(f: [*c]Factory) c.GType {
    if (!check.that(isFactory(f), "gst_device_provider_factory_get_device_provider_type", "GST_IS_DEVICE_PROVIDER_FACTORY (factory)")) return 0;
    return f[0].type;
}

pub export fn gst_device_provider_factory_get_metadata(f: [*c]Factory, key: [*c]const u8) [*c]const u8 {
    return c.gst_structure_get_string(@ptrCast(@alignCast(f[0].metadata)), key);
}

pub export fn gst_device_provider_factory_get_metadata_keys(f: [*c]Factory) [*c][*c]u8 {
    if (!check.that(isFactory(f), "gst_device_provider_factory_get_metadata_keys", "GST_IS_DEVICE_PROVIDER_FACTORY (factory)")) return null;
    const md: [*c]c.GstStructure = @ptrCast(@alignCast(f[0].metadata));
    if (md == null) return null;
    const num: c.guint = @intCast(c.gst_structure_n_fields(md));
    if (num == 0) return null;
    const arr: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc((num + 1) * @sizeOf([*c]u8))));
    var i: c.guint = 0;
    while (i < num) : (i += 1) arr[i] = c.g_strdup(c.gst_structure_nth_field_name(md, i));
    arr[num] = null;
    return arr;
}

pub export fn gst_device_provider_factory_has_classesv(f: [*c]Factory, classes: [*c][*c]u8) c.gboolean {
    if (!check.that(isFactory(f), "gst_device_provider_factory_has_classesv", "GST_IS_DEVICE_PROVIDER_FACTORY (factory)")) return 0;
    const k = gst_device_provider_factory_get_metadata(f, c.GST_ELEMENT_METADATA_KLASS);
    if (k == null) return 0;
    return @intFromBool(classMatches(k, classes));
}

pub export fn gst_device_provider_factory_has_classes(f: [*c]Factory, classes: [*c]const u8) c.gboolean {
    if (classes == null) return 1;
    const v = c.g_strsplit(classes, "/", 0);
    defer c.g_strfreev(v);
    return gst_device_provider_factory_has_classesv(f, v);
}

fn rankFilter(f: ?*c.GstPluginFeature, data: c.gpointer) callconv(.c) c.gboolean {
    if (!isFactory(f)) return 0;
    const minrank: *c.GstRank = @ptrCast(@alignCast(data));
    return @intFromBool(feature.gst_plugin_feature_get_rank(@ptrCast(@alignCast(f))) >= minrank.*);
}

pub export fn gst_device_provider_factory_list_get_device_providers(minrank: c.GstRank) ?*c.GList {
    var r = minrank;
    const l = registry.gst_registry_feature_filter(registry.gst_registry_get(), rankFilter, 0, &r);
    return c.g_list_sort(l, feature.gst_plugin_feature_rank_compare_func);
}

fn save(w: *regcache.Writer, f: [*c]feature.Feature) void {
    w.structure(@ptrCast(@alignCast(fof(f)[0].metadata)));
}

fn load(r: *regcache.Reader) regcache.Error![*c]feature.Feature {
    const f = fof(c.g_object_new(gst_device_provider_factory_get_type(), @as([*c]const u8, null)));
    errdefer c.gst_object_unref(f);
    f[0].metadata = try r.structure();
    return @ptrCast(f);
}

pub const kind = regcache.Kind{ .name = "GstDeviceProviderFactory", .get_type = gst_device_provider_factory_get_type, .save = save, .load = load };
