const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pw = @import("pw.zig");

const spa_dict = opaque {};
const sm_registry = opaque {};
const Added = *const fn (?*anyopaque, u32, ?*const spa_dict) callconv(.c) void;
const Removed = *const fn (?*anyopaque, u32) callconv(.c) void;

extern fn sm_registry_new(loop: ?*pw.pw_thread_loop, core: ?*pw.pw_core, added: Added, removed: Removed, data: ?*anyopaque) ?*sm_registry;
extern fn sm_registry_sync(r: ?*sm_registry) c_int;
extern fn sm_registry_destroy(r: ?*sm_registry) void;
extern fn sm_dict_lookup(d: ?*const spa_dict, key: [*:0]const u8) ?[*:0]const u8;
extern fn sm_dict_size(d: ?*const spa_dict) u32;
extern fn sm_dict_key(d: ?*const spa_dict, i: u32) ?[*:0]const u8;
extern fn sm_dict_value(d: ?*const spa_dict, i: u32) ?[*:0]const u8;

const PROP_SERIAL = 1;

const Device = extern struct {
    parent: c.GstDevice,
    serial: [*c]u8,
    id: u32,
};

const DeviceClass = extern struct {
    parent: c.GstDeviceClass,
};

const Session = struct {
    loop: ?*pw.pw_thread_loop = null,
    context: ?*pw.pw_context = null,
    core: ?*pw.pw_core = null,
    registry: ?*sm_registry = null,
    owner: ?*Provider = null,
    found: [*c]c.GList = null,
};

const Provider = extern struct {
    parent: c.GstDeviceProvider,
    session: ?*Session,
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
    if (id == PROP_SERIAL) {
        c.g_free(d.serial);
        d.serial = c.g_value_dup_string(v);
    } else cm.warnInvalid("gstpipewiredeviceprovider.c", o, id, spec, 0);
}

fn devGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const d: *Device = @ptrCast(@alignCast(o));
    if (id == PROP_SERIAL) c.g_value_set_string(v, d.serial) else cm.warnInvalid("gstpipewiredeviceprovider.c", o, id, spec, 0);
}

fn devFinalize(o: [*c]c.GObject) callconv(.c) void {
    const d: *Device = @ptrCast(@alignCast(o));
    c.g_free(d.serial);
    dev_parent.finalize.?(o);
}

fn createElement(dev: [*c]c.GstDevice, name: [*c]const u8) callconv(.c) [*c]c.GstElement {
    const d: *Device = @ptrCast(@alignCast(dev));
    const e = c.gst_element_factory_make("pipewiresrc", name);
    if (e != null) c.g_object_set(e, "target-object", d.serial, @as(?*anyopaque, null));
    return e;
}

fn reconfigureElement(dev: [*c]c.GstDevice, e: [*c]c.GstElement) callconv(.c) c.gboolean {
    const d: *Device = @ptrCast(@alignCast(dev));
    const f = c.gst_element_get_factory(e) orelse return 0;
    if (!std.mem.eql(u8, std.mem.span(@as(*c.GstObject, @ptrCast(@alignCast(f))).name), "pipewiresrc")) return 0;
    c.g_object_set(e, "target-object", d.serial, @as(?*anyopaque, null));
    return 1;
}

fn devClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    dev_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const dc: *c.GstDeviceClass = @ptrCast(@alignCast(k));
    dc.create_element = createElement;
    dc.reconfigure_element = reconfigureElement;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.get_property = devGet;
    oc.set_property = devSet;
    oc.finalize = devFinalize;
    c.g_object_class_install_property(oc, PROP_SERIAL, c.g_param_spec_string("serial", "Serial", "The PipeWire object serial", null, c.G_PARAM_STATIC_STRINGS | c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY));
}

fn deviceType() c.GType {
    return dev_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_device_get_type(), "GstPipeWireDevice", DeviceClass, Device, devClassInit, null);
        }
    }.f);
}

fn wanted(props: ?*const spa_dict) bool {
    const class = sm_dict_lookup(props, "media.class") orelse return false;
    if (!std.mem.eql(u8, std.mem.span(class), "Video/Source")) return false;
    if (sm_dict_lookup(props, "object.serial") == null) return false;
    if (sm_dict_lookup(props, "device.api")) |api| {
        if (std.mem.eql(u8, std.mem.span(api), "v4l2")) return false;
    }
    return true;
}

fn makeDevice(id: u32, props: ?*const spa_dict) ?*c.GstDevice {
    if (!wanted(props)) return null;
    const st = c.gst_structure_new_empty("pipewire-proplist") orelse return null;
    defer c.gst_structure_free(st);
    var i: u32 = 0;
    while (i < sm_dict_size(props)) : (i += 1) {
        const key = sm_dict_key(props, i) orelse continue;
        const value = sm_dict_value(props, i) orelse continue;
        c.gst_structure_set(st, key, c.G_TYPE_STRING, value, @as(?*anyopaque, null));
    }
    const label = sm_dict_lookup(props, "node.description") orelse sm_dict_lookup(props, "node.nick") orelse sm_dict_lookup(props, "node.name") orelse "PipeWire camera";
    const caps = c.gst_caps_new_empty_simple("video/x-raw");
    defer c.gst_caps_unref(caps);
    const d: *Device = @ptrCast(@alignCast(c.g_object_new(deviceType(), "serial", sm_dict_lookup(props, "object.serial").?, "display-name", label, "caps", caps, "device-class", "Video/Source", "properties", st, @as(?*anyopaque, null))));
    d.id = id;
    return &d.parent;
}

fn onAdded(data: ?*anyopaque, id: u32, props: ?*const spa_dict) callconv(.c) void {
    const s: *Session = @ptrCast(@alignCast(data));
    const d = makeDevice(id, props) orelse return;
    if (s.owner) |p| {
        c.gst_device_provider_device_add(&p.parent, d);
    } else {
        s.found = c.g_list_prepend(s.found, c.gst_object_ref_sink(d));
    }
}

fn onRemoved(data: ?*anyopaque, id: u32) callconv(.c) void {
    const s: *Session = @ptrCast(@alignCast(data));
    const p = s.owner orelse return;
    const list = c.gst_device_provider_get_devices(&p.parent);
    defer c.g_list_free_full(list, c.gst_object_unref);
    var it = list;
    while (it != null) : (it = it[0].next) {
        const o: *c.GTypeInstance = @ptrCast(@alignCast(it[0].data));
        if (c.g_type_check_instance_is_a(o, deviceType()) == 0) continue;
        const d: *Device = @ptrCast(@alignCast(it[0].data));
        if (d.id == id) {
            c.gst_device_provider_device_remove(&p.parent, &d.parent);
            break;
        }
    }
}

fn close(s: *Session) void {
    if (s.loop) |l| {
        pw.pw_thread_loop_lock(l);
        if (s.registry) |r| sm_registry_destroy(r);
        if (s.core) |core| _ = pw.pw_core_disconnect(core);
        pw.pw_thread_loop_unlock(l);
        pw.pw_thread_loop_stop(l);
    }
    if (s.context) |x| pw.pw_context_destroy(x);
    if (s.loop) |l| pw.pw_thread_loop_destroy(l);
    var it = s.found;
    while (it != null) : (it = it[0].next) c.gst_object_unref(it[0].data);
    c.g_list_free(s.found);
    std.heap.c_allocator.destroy(s);
}

fn open(owner: ?*Provider) ?*Session {
    pw.pw_init(null, null);
    const s = std.heap.c_allocator.create(Session) catch return null;
    s.* = .{ .owner = owner };
    s.loop = pw.pw_thread_loop_new("pw-dev-prvdr", null);
    if (s.loop == null) {
        close(s);
        return null;
    }
    s.context = pw.pw_context_new(pw.pw_thread_loop_get_loop(s.loop), null, 0);
    if (s.context == null or pw.pw_thread_loop_start(s.loop) < 0) {
        close(s);
        return null;
    }
    pw.pw_thread_loop_lock(s.loop);
    s.core = pw.pw_context_connect(s.context, null, 0);
    if (s.core != null) {
        s.registry = sm_registry_new(s.loop, s.core, onAdded, onRemoved, s);
        if (s.registry != null) _ = sm_registry_sync(s.registry);
    }
    pw.pw_thread_loop_unlock(s.loop);
    if (s.registry == null) {
        close(s);
        return null;
    }
    return s;
}

fn probe(_: [*c]c.GstDeviceProvider) callconv(.c) [*c]c.GList {
    const s = open(null) orelse return null;
    const out = s.found;
    s.found = null;
    close(s);
    return c.g_list_reverse(out);
}

fn start(dp: [*c]c.GstDeviceProvider) callconv(.c) c.gboolean {
    const p: *Provider = @ptrCast(@alignCast(dp));
    if (p.session == null) p.session = open(p);
    return 1;
}

fn stop(dp: [*c]c.GstDeviceProvider) callconv(.c) void {
    const p: *Provider = @ptrCast(@alignCast(dp));
    if (p.session) |s| close(s);
    p.session = null;
}

fn provInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: *Provider = @ptrCast(@alignCast(inst));
    p.session = null;
}

fn provClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    prov_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const pc: *c.GstDeviceProviderClass = @ptrCast(@alignCast(k));
    pc.probe = probe;
    pc.start = start;
    pc.stop = stop;
    c.gst_device_provider_class_set_static_metadata(pc, "PipeWire Device Provider", "Source/Video", "List and provide PipeWire camera devices", "Wim Taymans <wim.taymans@gmail.com>");
}

fn providerType() c.GType {
    return prov_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_device_provider_get_type(), "GstPipeWireDeviceProvider", ProviderClass, Provider, provClassInit, provInit);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_device_provider_register(p, "pipewiredeviceprovider", c.GST_RANK_PRIMARY + 1, providerType()) != 0;
}
