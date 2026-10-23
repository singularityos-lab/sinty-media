const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const sys = @import("sys.zig");
const V = sys.v;
const caps = @import("caps.zig");
const gu = struct {
    const GUdevClient = opaque {};
    const GUdevDevice = opaque {};
    extern fn g_udev_client_new(subsystems: [*c]const [*c]const u8) ?*GUdevClient;
    extern fn g_udev_client_query_by_subsystem(client: ?*GUdevClient, subsystem: [*c]const u8) [*c]c.GList;
    extern fn g_udev_device_get_property(dev: ?*GUdevDevice, key: [*c]const u8) [*c]const u8;
    extern fn g_udev_device_has_property(dev: ?*GUdevDevice, key: [*c]const u8) c.gboolean;
    extern fn g_udev_device_get_property_as_int(dev: ?*GUdevDevice, key: [*c]const u8) c.gint;
    extern fn g_udev_device_get_device_file(dev: ?*GUdevDevice) [*c]const u8;
    extern fn g_udev_device_get_sysfs_path(dev: ?*GUdevDevice) [*c]const u8;
    const g_list_delete_link = c.g_list_delete_link;
    fn g_object_unref(o: anytype) void {
        c.g_object_unref(@ptrCast(o));
    }
};

const Device = extern struct {
    parent: c.GstDevice,
    device_path: [*c]u8,
    syspath: [*c]u8,
    element: [*c]const u8,
};

const DeviceClass = extern struct {
    parent: c.GstDeviceClass,
};

const Provider = extern struct {
    parent: c.GstDeviceProvider,
    context: ?*c.GMainContext,
    loop: ?*c.GMainLoop,
    thread: ?*c.GThread,
    started: c.gboolean,
    cond: c.GCond,
};

const ProviderClass = extern struct {
    parent: c.GstDeviceProviderClass,
};

var dev_once: cm.Once = .{};
var prov_once: cm.Once = .{};
var dev_parent: *c.GObjectClass = undefined;
var prov_parent: *c.GObjectClass = undefined;

fn devSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const d: *Device = @ptrCast(@alignCast(o));
    if (id == 1) d.device_path = c.g_value_dup_string(v) else cm.warnInvalid("../sys/v4l2/gstv4l2deviceprovider.c", o, id, spec, 612);
}

fn devGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const d: *Device = @ptrCast(@alignCast(o));
    if (id == 1) c.g_value_set_string(v, d.device_path) else cm.warnInvalid("../sys/v4l2/gstv4l2deviceprovider.c", o, id, spec, 593);
}

fn devFinalize(o: [*c]c.GObject) callconv(.c) void {
    const d: *Device = @ptrCast(@alignCast(o));
    c.g_free(d.device_path);
    c.g_free(d.syspath);
    dev_parent.finalize.?(o);
}

fn createElement(dev: [*c]c.GstDevice, name: [*c]const u8) callconv(.c) [*c]c.GstElement {
    const d: *Device = @ptrCast(@alignCast(dev));
    const e = c.gst_element_factory_make(d.element, name);
    if (e != null) c.g_object_set(e, "device", d.device_path, @as(?*anyopaque, null));
    return e;
}

fn devClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    dev_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const dc: *c.GstDeviceClass = @ptrCast(@alignCast(k));
    dc.create_element = createElement;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.get_property = devGet;
    oc.set_property = devSet;
    oc.finalize = devFinalize;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_string("device-path", "Device Path", "The Path of the device node", "", c.G_PARAM_STATIC_STRINGS | c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY));
}

fn deviceType() c.GType {
    return dev_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_device_get_type(), "GstV4l2Device", DeviceClass, Device, devClassInit, null);
        }
    }.f);
}

fn probeDevice(path: [*c]const u8, name: [*c]const u8, props: *c.GstStructure) ?*c.GstDevice {
    defer c.gst_structure_free(props);
    var st: V.struct_stat = undefined;
    if (V.stat(path, &st) == -1 or st.st_mode & V.S_IFMT != V.S_IFCHR) return null;
    const fd = V.open(path, V.O_RDWR | V.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = V.close(fd);
    var cap = std.mem.zeroes(V.struct_v4l2_capability);
    if (sys.xioctl(fd, sys.QUERYCAP, &cap) < 0) return null;
    const dcaps = if (cap.capabilities & V.V4L2_CAP_DEVICE_CAPS != 0) cap.device_caps else cap.capabilities;
    c.gst_structure_set(props, "device.api", c.G_TYPE_STRING, "v4l2", @as(?*anyopaque, null));
    c.gst_structure_set(props, "device.path", c.G_TYPE_STRING, path, @as(?*anyopaque, null));
    c.gst_structure_set(props, "v4l2.device.driver", c.G_TYPE_STRING, &cap.driver, @as(?*anyopaque, null));
    c.gst_structure_set(props, "v4l2.device.card", c.G_TYPE_STRING, &cap.card, @as(?*anyopaque, null));
    c.gst_structure_set(props, "v4l2.device.bus_info", c.G_TYPE_STRING, &cap.bus_info, @as(?*anyopaque, null));
    c.gst_structure_set(props, "v4l2.device.version", c.G_TYPE_UINT, cap.version, @as(?*anyopaque, null));
    c.gst_structure_set(props, "v4l2.device.capabilities", c.G_TYPE_UINT, cap.capabilities, @as(?*anyopaque, null));
    c.gst_structure_set(props, "v4l2.device.device_caps", c.G_TYPE_UINT, cap.device_caps, @as(?*anyopaque, null));
    if (dcaps & (V.V4L2_CAP_VIDEO_CAPTURE | V.V4L2_CAP_VIDEO_CAPTURE_MPLANE) == 0) return null;
    if (dcaps & V.V4L2_CAP_TOUCH != 0) return null;
    if (dcaps & (V.V4L2_CAP_VIDEO_OUTPUT | V.V4L2_CAP_VIDEO_OUTPUT_MPLANE) != 0) return null;
    var list: std.ArrayListUnmanaged(caps.Desc) = .empty;
    defer list.deinit(std.heap.c_allocator);
    if (!caps.formats(fd, &list)) return null;
    var par = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&par, c.gst_fraction_get_type());
    defer c.g_value_unset(&par);
    var cc = std.mem.zeroes(V.struct_v4l2_cropcap);
    cc.type = V.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (sys.xioctl(fd, sys.CROPCAP, &cc) >= 0 and cc.pixelaspect.numerator != 0 and cc.pixelaspect.denominator != 0) {
        c.gst_value_set_fraction(&par, @intCast(cc.pixelaspect.numerator), @intCast(cc.pixelaspect.denominator));
    } else c.gst_value_set_fraction(&par, 1, 1);
    const probed = caps.probe(fd, list.items, &par);
    defer c.gst_caps_unref(probed);
    if (c.gst_caps_is_empty(probed) != 0) return null;
    const label: [*c]const u8 = if (name != null) name else @ptrCast(&cap.card);
    const d: *Device = @ptrCast(@alignCast(c.g_object_new(deviceType(), "device-path", path, "display-name", label, "caps", probed, "device-class", "Video/Source", "properties", props, @as(?*anyopaque, null))));
    d.element = "v4l2src";
    return &d.parent;
}

fn probe(_: [*c]c.GstDeviceProvider) callconv(.c) [*c]c.GList {
    var out: [*c]c.GList = null;
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "/dev/video", "/dev/v4l2/video" }) |prefix| {
        var i: u32 = 0;
        while (i < 64) : (i += 1) {
            const path = std.fmt.bufPrintZ(&buf, "{s}{d}", .{ prefix, i }) catch continue;
            const props = c.gst_structure_new("v4l2-proplist", "device.path", c.G_TYPE_STRING, path.ptr, "udev-probed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 0), @as(?*anyopaque, null)).?;
            if (probeDevice(path.ptr, null, props)) |d| {
                _ = c.gst_object_ref_sink(d);
                out = c.g_list_prepend(out, d);
            }
        }
    }
    return out;
}

fn prop(dev: ?*gu.GUdevDevice, key: [*c]const u8) [*c]const u8 {
    const v = gu.g_udev_device_get_property(dev, key);
    return if (v != null and v[0] != 0) v else null;
}

fn setStr(s: *c.GstStructure, key: [*c]const u8, v: [*c]const u8) void {
    if (v != null and v[0] != 0) c.gst_structure_set(s, key, c.G_TYPE_STRING, v, @as(?*anyopaque, null));
}

fn fromUdev(dev: ?*gu.GUdevDevice) ?*c.GstDevice {
    const path = gu.g_udev_device_get_device_file(dev);
    if (path == null) return null;
    const props = c.gst_structure_new("v4l2deviceprovider", "udev-probed", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), @as(?*anyopaque, null)).?;
    const sysfs = gu.g_udev_device_get_sysfs_path(dev);
    var str = prop(dev, "ID_PATH");
    if (str == null) str = sysfs;
    setStr(props, "device.bus_path", str);
    setStr(props, "sysfs.path", sysfs);
    setStr(props, "udev.id", prop(dev, "ID_ID"));
    setStr(props, "device.bus", prop(dev, "ID_BUS"));
    setStr(props, "device.subsystem", prop(dev, "SUBSYSTEM"));
    setStr(props, "device.vendor.id", prop(dev, "ID_VENDOR_ID"));
    str = prop(dev, "ID_VENDOR_FROM_DATABASE");
    if (str == null) str = prop(dev, "ID_VENDOR_ENC");
    if (str == null) str = prop(dev, "ID_VENDOR");
    setStr(props, "device.vendor.name", str);
    setStr(props, "device.product.id", prop(dev, "ID_MODEL_ID"));
    var name = prop(dev, "ID_V4L_PRODUCT");
    if (name == null) name = prop(dev, "ID_MODEL_FROM_DATABASE");
    if (name == null) name = prop(dev, "ID_MODEL_ENC");
    if (name == null) name = prop(dev, "ID_MODEL");
    setStr(props, "device.product.name", name);
    setStr(props, "device.serial", prop(dev, "ID_SERIAL"));
    setStr(props, "device.capabilities", prop(dev, "ID_V4L_CAPABILITIES"));
    const d = probeDevice(path, name, props) orelse return null;
    @as(*Device, @ptrCast(@alignCast(d))).syspath = c.g_strdup(sysfs);
    return d;
}

fn isV4l2(dev: ?*gu.GUdevDevice) bool {
    if (gu.g_udev_device_has_property(dev, "ID_V4L_VERSION") == 0) return true;
    return gu.g_udev_device_get_property_as_int(dev, "ID_V4L_VERSION") == 2;
}

fn onUevent(_: ?*gu.GUdevClient, action: [*c]const u8, dev: ?*gu.GUdevDevice, data: c.gpointer) callconv(.c) void {
    const p: *c.GstDeviceProvider = @ptrCast(@alignCast(data));
    if (!isV4l2(dev)) return;
    if (std.mem.eql(u8, std.mem.span(action), "add")) {
        if (fromUdev(dev)) |d| c.gst_device_provider_device_add(p, d);
    } else if (std.mem.eql(u8, std.mem.span(action), "remove")) {
        const sysfs = gu.g_udev_device_get_sysfs_path(dev);
        var found: ?*c.GstDevice = null;
        cm.lock(p);
        var l = p.devices;
        while (l != null) : (l = l[0].next) {
            const d: *Device = @ptrCast(@alignCast(l[0].data));
            if (d.syspath != null and sysfs != null and c.g_strcmp0(d.syspath, sysfs) == 0) {
                found = @ptrCast(@alignCast(c.gst_object_ref(d)));
                break;
            }
        }
        cm.unlock(p);
        if (found) |d| {
            c.gst_device_provider_device_remove(p, d);
            c.gst_object_unref(d);
        }
    }
}

fn thread(data: c.gpointer) callconv(.c) c.gpointer {
    const p: *Provider = @ptrCast(@alignCast(data));
    cm.lock(p);
    const ctx = if (p.context) |x| c.g_main_context_ref(x) else null;
    const loop = if (p.loop) |x| c.g_main_loop_ref(x) else null;
    if (ctx == null or loop == null) {
        p.started = 1;
        c.g_cond_broadcast(&p.cond);
        cm.unlock(p);
        if (loop) |x| c.g_main_loop_unref(x);
        if (ctx) |x| c.g_main_context_unref(x);
        return null;
    }
    cm.unlock(p);
    c.g_main_context_push_thread_default(ctx);
    var subsystems = [_][*c]const u8{ "video4linux", null };
    const client = gu.g_udev_client_new(@ptrCast(&subsystems));
    _ = c.g_signal_connect_data(client, "uevent", @ptrCast(&onUevent), p, null, 0);
    var devs = gu.g_udev_client_query_by_subsystem(client, "video4linux");
    while (devs != null) {
        const ud: ?*gu.GUdevDevice = @ptrCast(@alignCast(devs[0].data));
        devs = gu.g_list_delete_link(devs, devs);
        if (isV4l2(ud)) {
            if (fromUdev(ud)) |d| c.gst_device_provider_device_add(&p.parent, d);
        }
        gu.g_object_unref(ud);
    }
    cm.lock(p);
    p.started = 1;
    c.g_cond_broadcast(&p.cond);
    cm.unlock(p);
    c.g_main_loop_run(loop);
    c.g_main_loop_unref(loop);
    gu.g_object_unref(client);
    c.g_main_context_pop_thread_default(ctx);
    c.g_main_context_unref(ctx);
    c.gst_object_unref(p);
    return null;
}

fn start(dp: [*c]c.GstDeviceProvider) callconv(.c) c.gboolean {
    const p: *Provider = @ptrCast(@alignCast(dp));
    cm.lock(p);
    p.context = c.g_main_context_new();
    p.loop = c.g_main_loop_new(p.context, 0);
    p.thread = c.g_thread_new("v4l2-dev-prvdr", thread, c.gst_object_ref(p));
    while (p.started == 0) c.g_cond_wait(&p.cond, &@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
    cm.unlock(p);
    return 1;
}

fn quit(data: c.gpointer) callconv(.c) c.gboolean {
    c.g_main_loop_quit(@ptrCast(@alignCast(data)));
    return 0;
}

fn stop(dp: [*c]c.GstDeviceProvider) callconv(.c) void {
    const p: *Provider = @ptrCast(@alignCast(dp));
    cm.lock(p);
    const ctx = p.context;
    const loop = p.loop;
    p.context = null;
    p.loop = null;
    cm.unlock(p);
    if (ctx == null or loop == null) {
        if (loop) |x| c.g_main_loop_unref(x);
        if (ctx) |x| c.g_main_context_unref(x);
        return;
    }
    const src = c.g_idle_source_new();
    c.g_source_set_callback(src, quit, loop, null);
    _ = c.g_source_attach(src, ctx);
    c.g_source_unref(src);
    _ = c.g_thread_join(p.thread);
    p.thread = null;
    p.started = 0;
    c.g_main_loop_unref(loop);
    c.g_main_context_unref(ctx);
}

fn provFinalize(o: [*c]c.GObject) callconv(.c) void {
    const p: *Provider = @ptrCast(@alignCast(o));
    c.g_cond_clear(&p.cond);
    prov_parent.finalize.?(o);
}

fn provInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: *Provider = @ptrCast(@alignCast(inst));
    c.g_cond_init(&p.cond);
}

fn provClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    prov_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const pc: *c.GstDeviceProviderClass = @ptrCast(@alignCast(k));
    pc.probe = probe;
    pc.start = start;
    pc.stop = stop;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = provFinalize;
    c.gst_device_provider_class_set_static_metadata(pc, "Video (video4linux2) Device Provider", "Source/Sink/Video", "List and monitor video4linux2 source and sink devices", "Olivier Crete <olivier.crete@collabora.com>");
}

fn providerType() c.GType {
    return prov_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_device_provider_get_type(), "GstV4l2DeviceProvider", ProviderClass, Provider, provClassInit, provInit);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_device_provider_register(p, "v4l2deviceprovider", c.GST_RANK_PRIMARY, providerType()) != 0;
}
