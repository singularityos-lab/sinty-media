const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const object = @import("object.zig");
const device = @import("device.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Monitor = c.GstDeviceMonitor;
const Provider = c.GstDeviceProvider;
const Device = c.GstDevice;

const Private = extern struct {
    started: c.gboolean,
    start_thread: ?*c.GThread,
    bus: [*c]c.GstBus,
    providers: [*c]c.GPtrArray,
    filters: [*c]c.GPtrArray,
    started_providers: ?*c.GSList,
    last_id: c.guint,
    hidden: ?*c.GList,
    show_all: c.gboolean,
};

const Filter = extern struct {
    id: c.guint,
    classesv: [*c][*c]u8,
    caps: [*c]c.GstCaps,
};

const PROP_SHOW_ALL = 1;

var type_once: gtype.Once = .{};
var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var debug_cat: [*c]c.GstDebugCategory = null;

fn priv(m: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Monitor, @ptrCast(@alignCast(m)))[0].priv));
}

fn isMonitor(m: anytype) bool {
    return gtype.instanceOf(m, gst_device_monitor_get_type());
}

fn providerAt(m: [*c]Monitor, i: c.guint) [*c]Provider {
    return @ptrCast(@alignCast(priv(m).providers[0].pdata[i]));
}

fn filterAt(m: [*c]Monitor, i: c.guint) *Filter {
    return @ptrCast(@alignCast(priv(m).filters[0].pdata[i]));
}

fn copyFilter(f: *Filter) *Filter {
    const n: *Filter = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Filter))));
    n.classesv = c.g_strdupv(f.classesv);
    n.caps = if (f.caps != null) c.gst_caps_ref(f.caps) else null;
    return n;
}

fn freeFilter(p: c.gpointer) callconv(.c) void {
    const f: *Filter = @ptrCast(@alignCast(p));
    c.g_strfreev(f.classesv);
    if (f.caps != null) c.gst_caps_unref(f.caps);
    c.g_free(f);
}

pub export fn gst_device_monitor_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstDeviceMonitor", c.GstDeviceMonitorClass, Monitor, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.get_property = getProperty;
    gc.set_property = setProperty;
    gc.dispose = dispose;
    debug_cat = info._gst_debug_category_new("devicemonitor", 0, "debugging info for the device monitor");
    c.g_object_class_install_property(gc, PROP_SHOW_ALL, c.g_param_spec_boolean("show-all", "Show All", "Show all devices, even those from hidden providers", 0, c.G_PARAM_STATIC_STRINGS | c.G_PARAM_READWRITE));
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const m: [*c]Monitor = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    m[0].priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
    const d = priv(m);
    d.show_all = 0;
    d.bus = c.gst_bus_new();
    c.gst_bus_set_flushing(d.bus, 1);
    d.providers = c.g_ptr_array_new();
    d.filters = c.g_ptr_array_new_with_free_func(freeFilter);
    d.started_providers = null;
    d.started = 0;
    d.start_thread = null;
    d.last_id = 1;
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_SHOW_ALL => c.g_value_set_boolean(v, gst_device_monitor_get_show_all_devices(@ptrCast(@alignCast(o)))),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_SHOW_ALL => gst_device_monitor_set_show_all_devices(@ptrCast(@alignCast(o)), c.g_value_get_boolean(v)),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn factoryName(p: [*c]Provider) [*c]const u8 {
    const f = device.gst_device_provider_get_factory(p);
    return if (f != null) f[0].feature.object.name else null;
}

fn hiddenProvider(m: [*c]Monitor, hidden: ?*c.GList, p: [*c]Provider) bool {
    if (priv(m).show_all != 0) return false;
    return c.g_list_find_custom(hidden, factoryName(p), @ptrCast(&c.g_strcmp0)) != null;
}

fn collectHidden(hidden: *?*c.GList, p: [*c]Provider) void {
    const obs = device.gst_device_provider_get_hidden_providers(p);
    if (obs == null) return;
    var i: usize = 0;
    while (obs[i] != null) : (i += 1) hidden.* = c.g_list_prepend(hidden.*, obs[i]);
    c.g_free(@ptrCast(obs));
}

fn deviceMatches(dev: [*c]Device, f: *Filter) bool {
    const caps = device.gst_device_get_caps(dev);
    defer if (caps != null) c.gst_caps_unref(caps);
    return c.gst_caps_can_intersect(f.caps, caps) != 0 and device.gst_device_has_classesv(dev, f.classesv) != 0;
}

fn busSync(_: ?*c.GstBus, msg: [*c]c.GstMessage, data: c.gpointer) callconv(.c) c.GstBusSyncReply {
    const m: [*c]Monitor = @ptrCast(@alignCast(data));
    const t = msg[0].type;
    if (t == c.GST_MESSAGE_DEVICE_ADDED or t == c.GST_MESSAGE_DEVICE_REMOVED or t == c.GST_MESSAGE_DEVICE_CHANGED) {
        var dev: [*c]Device = null;
        if (t == c.GST_MESSAGE_DEVICE_ADDED)
            c.gst_message_parse_device_added(msg, &dev)
        else if (t == c.GST_MESSAGE_DEVICE_REMOVED)
            c.gst_message_parse_device_removed(msg, &dev)
        else
            c.gst_message_parse_device_changed(msg, &dev, null);
        object.lock(m);
        const p: [*c]Provider = @ptrCast(@alignCast(msg[0].src));
        var matches = true;
        if (p != null and hiddenProvider(m, priv(m).hidden, p)) {
            matches = false;
        } else {
            var i: c.guint = 0;
            while (i < priv(m).filters[0].len) : (i += 1) {
                matches = deviceMatches(dev, filterAt(m, i));
                if (matches) break;
            }
        }
        object.unlock(m);
        c.gst_object_unref(dev);
        if (matches) _ = c.gst_bus_post(priv(m).bus, c.gst_message_ref(msg));
    }
    c.gst_message_unref(msg);
    return c.GST_BUS_DROP;
}

fn onHidden(_: [*c]Provider, name: [*c]const u8, data: c.gpointer) callconv(.c) void {
    const m: [*c]Monitor = @ptrCast(@alignCast(data));
    object.lock(m);
    priv(m).hidden = c.g_list_prepend(priv(m).hidden, c.g_strdup(name));
    object.unlock(m);
}

fn onUnhidden(_: [*c]Provider, name: [*c]const u8, data: c.gpointer) callconv(.c) void {
    const m: [*c]Monitor = @ptrCast(@alignCast(data));
    object.lock(m);
    if (c.g_list_find_custom(priv(m).hidden, name, @ptrCast(&c.g_strcmp0))) |found| {
        c.g_free(found.*.data);
        priv(m).hidden = c.g_list_delete_link(priv(m).hidden, found);
    }
    object.unlock(m);
}

fn removeProvider(m: [*c]Monitor, i: c.guint) void {
    const p = providerAt(m, i);
    _ = c.g_ptr_array_remove_index(priv(m).providers, i);
    const bus = device.gst_device_provider_get_bus(p);
    c.gst_bus_set_sync_handler(bus, null, null, null);
    c.gst_object_unref(bus);
    _ = c.g_signal_handlers_disconnect_matched(p, c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA, 0, 0, null, @constCast(@ptrCast(&onHidden)), m);
    _ = c.g_signal_handlers_disconnect_matched(p, c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA, 0, 0, null, @constCast(@ptrCast(&onUnhidden)), m);
    c.gst_object_unref(p);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const m: [*c]Monitor = @ptrCast(@alignCast(o));
    const d = priv(m);
    if (d.started != 0) c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "gst_device_monitor_dispose: disposed without stopping, started providers were leaked");
    if (d.start_thread != null) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: runtime check failed: (%s)", "gst_device_monitor_dispose", "!self->priv->start_thread");
    if (d.providers != null) {
        while (d.providers[0].len > 0) removeProvider(m, d.providers[0].len - 1);
        c.g_ptr_array_unref(d.providers);
        d.providers = null;
    }
    if (d.filters != null) {
        c.g_ptr_array_unref(d.filters);
        d.filters = null;
    }
    if (d.hidden != null) {
        c.g_list_free_full(d.hidden, c.g_free);
        d.hidden = null;
    }
    _ = object.gst_object_replace(@ptrCast(&d.bus), null);
    parent_class.?.dispose.?(o);
}

pub export fn gst_device_monitor_get_devices(m: [*c]Monitor) ?*c.GList {
    if (!check.that(isMonitor(m), "gst_device_monitor_get_devices", "GST_IS_DEVICE_MONITOR (monitor)")) return null;
    const d = priv(m);
    var providers = std.mem.zeroes(c.GQueue);
    var filters = std.mem.zeroes(c.GQueue);
    var devices = std.mem.zeroes(c.GQueue);
    var hidden: ?*c.GList = null;
    object.lock(m);
    if (d.filters[0].len == 0 or d.providers[0].len == 0) {
        object.unlock(m);
        return null;
    }
    var i: c.guint = 0;
    while (i < d.providers[0].len) : (i += 1) collectHidden(&hidden, providerAt(m, i));
    i = 0;
    while (i < d.providers[0].len) : (i += 1) {
        const p = providerAt(m, i);
        if (!hiddenProvider(m, hidden, p)) c.g_queue_push_tail(&providers, c.gst_object_ref(p));
    }
    i = 0;
    while (i < d.filters[0].len) : (i += 1) c.g_queue_push_tail(&filters, copyFilter(filterAt(m, i)));
    object.unlock(m);
    var l: ?*c.GList = providers.head;
    while (l) |n| : (l = n.next) {
        const devs = device.gst_device_provider_get_devices(@ptrCast(@alignCast(n.data)));
        var item: ?*c.GList = devs;
        while (item) |x| : (item = x.next) {
            const dev: [*c]Device = @ptrCast(@alignCast(x.data));
            var fl: ?*c.GList = filters.head;
            while (fl) |y| : (fl = y.next) {
                if (deviceMatches(dev, @ptrCast(@alignCast(y.data)))) {
                    c.g_queue_push_tail(&devices, c.gst_object_ref(dev));
                    break;
                }
            }
        }
        c.g_list_free_full(devs, c.gst_object_unref);
    }
    c.g_list_free_full(hidden, c.g_free);
    c.g_queue_clear_full(&providers, c.gst_object_unref);
    c.g_queue_clear_full(&filters, freeFilter);
    return devices.head;
}

fn startThread(data: c.gpointer) callconv(.c) c.gpointer {
    const m: [*c]Monitor = @ptrCast(@alignCast(data));
    const d = priv(m);
    var started: ?*c.GSList = null;
    var pending = std.mem.zeroes(c.GQueue);
    object.lock(m);
    run: {
        if (d.started == 0) {
            object.unlock(m);
            break :run;
        }
        var i: c.guint = 0;
        while (i < d.providers[0].len) : (i += 1) c.g_queue_push_tail(&pending, c.gst_object_ref(providerAt(m, i)));
        while (c.g_queue_pop_head(&pending)) |raw| {
            var p: [*c]Provider = @ptrCast(@alignCast(raw));
            object.unlock(m);
            if (device.gst_device_provider_start(p) != 0) {
                started = c.g_slist_prepend(started, p);
            } else {
                c.gst_object_unref(p);
                p = null;
            }
            object.lock(m);
            if (d.started == 0) {
                object.unlock(m);
                if (p != null) {
                    device.gst_device_provider_stop(p);
                    c.gst_object_unref(p);
                    started = c.g_slist_delete_link(started, started);
                }
                c.g_queue_clear_full(&pending, c.gst_object_unref);
                started = null;
                break :run;
            }
            if (started != null) d.started_providers = started;
        }
        if (d.started_providers == null) d.started = 0;
        if (d.start_thread) |t| c.g_thread_unref(t);
        d.start_thread = null;
        object.unlock(m);
    }
    _ = c.gst_bus_post(d.bus, c.gst_message_new_device_monitor_started(@ptrCast(m), @intFromBool(started != null)));
    c.gst_object_unref(m);
    return null;
}

pub export fn gst_device_monitor_start(m: [*c]Monitor) c.gboolean {
    if (!check.that(isMonitor(m), "gst_device_monitor_start", "GST_IS_DEVICE_MONITOR (monitor)")) return 0;
    const d = priv(m);
    object.lock(m);
    defer object.unlock(m);
    if (d.started != 0) return 1;
    if (d.filters[0].len == 0) _ = addFilter(m, null, null);
    if (d.providers[0].len == 0) return 0;
    d.start_thread = c.g_thread_try_new("gst_device_monitor_start", startThread, m, null);
    if (d.start_thread == null) return 0;
    _ = c.gst_object_ref(m);
    d.started = 1;
    c.gst_bus_set_flushing(d.bus, 0);
    return 1;
}

pub export fn gst_device_monitor_stop(m: [*c]Monitor) void {
    if (!check.that(isMonitor(m), "gst_device_monitor_stop", "GST_IS_DEVICE_MONITOR (monitor)")) return;
    const d = priv(m);
    c.gst_bus_set_flushing(d.bus, 1);
    object.lock(m);
    if (d.started == 0) {
        object.unlock(m);
        return;
    }
    var started = d.started_providers;
    d.started_providers = null;
    d.started = 0;
    const thread = d.start_thread;
    d.start_thread = null;
    object.unlock(m);
    if (thread) |t| _ = c.g_thread_join(t);
    while (started) |n| {
        const p: [*c]Provider = @ptrCast(@alignCast(n.data));
        device.gst_device_provider_stop(p);
        started = c.g_slist_delete_link(started, n);
        c.gst_object_unref(p);
    }
}

fn addFilter(m: [*c]Monitor, classes: [*c]const u8, caps: [*c]c.GstCaps) c.guint {
    const d = priv(m);
    const f: *Filter = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Filter))));
    f.id = d.last_id;
    d.last_id += 1;
    f.caps = if (caps != null) c.gst_caps_ref(caps) else c.gst_caps_new_any();
    if (classes != null) f.classesv = c.g_strsplit(classes, "/", 0);
    var matched = false;
    var factories = device.gst_device_provider_factory_list_get_device_providers(1);
    while (factories) |n| {
        const fac: [*c]device.Factory = @ptrCast(@alignCast(n.data));
        if (device.gst_device_provider_factory_has_classesv(fac, f.classesv) != 0) {
            var p = device.gst_device_provider_factory_get(fac);
            if (p != null) {
                var i: c.guint = 0;
                while (i < d.providers[0].len) : (i += 1) if (providerAt(m, i) == p) {
                    c.gst_object_unref(p);
                    p = null;
                    matched = true;
                    break;
                };
            }
            if (p != null) {
                const bus = device.gst_device_provider_get_bus(p);
                collectHidden(&d.hidden, p);
                _ = c.g_signal_connect_data(p, "provider-hidden", @ptrCast(&onHidden), m, null, 0);
                _ = c.g_signal_connect_data(p, "provider-unhidden", @ptrCast(&onUnhidden), m, null, 0);
                matched = true;
                c.gst_bus_set_sync_handler(bus, busSync, m, null);
                c.gst_object_unref(bus);
                c.g_ptr_array_add(d.providers, p);
            }
        }
        factories = c.g_list_remove(factories, fac);
        c.gst_object_unref(fac);
    }
    c.g_ptr_array_add(d.filters, f);
    return if (matched) f.id else 0;
}

pub export fn gst_device_monitor_add_filter(m: [*c]Monitor, classes: [*c]const u8, caps: [*c]c.GstCaps) c.guint {
    if (!check.that(isMonitor(m), "gst_device_monitor_add_filter", "GST_IS_DEVICE_MONITOR (monitor)")) return 0;
    if (!check.that(priv(m).started == 0, "gst_device_monitor_add_filter", "!monitor->priv->started")) return 0;
    object.lock(m);
    defer object.unlock(m);
    return addFilter(m, classes, caps);
}

pub export fn gst_device_monitor_remove_filter(m: [*c]Monitor, id: c.guint) c.gboolean {
    const fname = "gst_device_monitor_remove_filter";
    if (!check.that(isMonitor(m), fname, "GST_IS_DEVICE_MONITOR (monitor)")) return 0;
    if (!check.that(priv(m).started == 0, fname, "!monitor->priv->started")) return 0;
    if (!check.that(id > 0, fname, "filter_id > 0")) return 0;
    const d = priv(m);
    object.lock(m);
    defer object.unlock(m);
    var removed = false;
    var i: c.guint = 0;
    while (i < d.filters[0].len) : (i += 1) if (filterAt(m, i).id == id) {
        _ = c.g_ptr_array_remove_index(d.filters, i);
        removed = true;
        break;
    };
    if (!removed) return 0;
    i = 0;
    while (i < d.providers[0].len) {
        const fac = device.gst_device_provider_get_factory(providerAt(m, i));
        var valid = false;
        var j: c.guint = 0;
        while (j < d.filters[0].len) : (j += 1) if (device.gst_device_provider_factory_has_classesv(fac, filterAt(m, j).classesv) != 0) {
            valid = true;
            break;
        };
        if (valid) i += 1 else removeProvider(m, i);
    }
    return 1;
}

pub export fn gst_device_monitor_new() [*c]Monitor {
    const m: [*c]Monitor = @ptrCast(@alignCast(c.g_object_new(gst_device_monitor_get_type(), @as([*c]const u8, null))));
    _ = object.gst_object_ref_sink(m);
    return m;
}

pub export fn gst_device_monitor_get_bus(m: [*c]Monitor) [*c]c.GstBus {
    if (!check.that(isMonitor(m), "gst_device_monitor_get_bus", "GST_IS_DEVICE_MONITOR (monitor)")) return null;
    return @ptrCast(@alignCast(c.gst_object_ref(priv(m).bus)));
}

pub export fn gst_device_monitor_get_providers(m: [*c]Monitor) [*c][*c]u8 {
    if (!check.that(isMonitor(m), "gst_device_monitor_get_providers", "GST_IS_DEVICE_MONITOR (monitor)")) return null;
    object.lock(m);
    defer object.unlock(m);
    const len = priv(m).providers[0].len;
    if (len == 0) return null;
    const res: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc((len + 1) * @sizeOf([*c]u8))));
    var i: c.guint = 0;
    while (i < len) : (i += 1) res[i] = c.g_strdup(factoryName(providerAt(m, i)));
    res[len] = null;
    return res;
}

pub export fn gst_device_monitor_set_show_all_devices(m: [*c]Monitor, show: c.gboolean) void {
    if (!check.that(isMonitor(m), "gst_device_monitor_set_show_all_devices", "GST_IS_DEVICE_MONITOR (monitor)")) return;
    object.lock(m);
    priv(m).show_all = show;
    object.unlock(m);
}

pub export fn gst_device_monitor_get_show_all_devices(m: [*c]Monitor) c.gboolean {
    if (!check.that(isMonitor(m), "gst_device_monitor_get_show_all_devices", "GST_IS_DEVICE_MONITOR (monitor)")) return 0;
    object.lock(m);
    defer object.unlock(m);
    return priv(m).show_all;
}
