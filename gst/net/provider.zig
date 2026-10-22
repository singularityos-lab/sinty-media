const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const basic = @import("basic.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Provider = c.GstNetTimeProvider;

const Priv = extern struct {
    address: [*c]u8,
    port: c_int,
    qos_dscp: c.gint,
    thread: ?*c.GThread,
    clock: [*c]c.GstClock,
    active: c.gboolean,
    socket: ?*c.GSocket,
    cancel: ?*c.GCancellable,
    made_cancel_fd: c.gboolean,
};

var once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;
var cat: ?*c.GstDebugCategory = null;

const FILE = "../libs/gst/net/gstnettimeprovider.c";
const DEFAULT_ADDRESS = "0.0.0.0";

fn priv(s: anytype) *Priv {
    const p: [*]u8 = @ptrCast(s);
    return @ptrCast(@alignCast(p + @as(usize, @bitCast(@as(isize, offset)))));
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log(basic.DOMAIN, c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", FILE, line, "property", id, spec.*.name, c.g_type_name(spec.*.g_type_instance.g_class.*.g_type), c.g_type_name(o.*.g_type_instance.g_class.*.g_type));
}

fn thread(data: c.gpointer) callconv(.c) c.gpointer {
    const s: *Provider = @ptrCast(@alignCast(data));
    const p = priv(s);
    const cancel = p.cancel;
    const sock = p.socket;
    var cur: c.gint = -1;
    while (true) {
        var err: [*c]c.GError = null;
        if (c.g_socket_condition_wait(sock, c.G_IO_IN, cancel, &err) == 0) {
            if (err.*.code == c.G_IO_ERROR_CANCELLED) {
                c.g_error_free(err);
                break;
            }
            c.g_usleep(100000);
            c.g_error_free(err);
            continue;
        }
        var sender: ?*c.GSocketAddress = null;
        const packet = basic.gst_net_time_packet_receive(sock, &sender, &err);
        if (err != null) {
            c.g_usleep(100000);
            c.g_error_free(err);
            continue;
        }
        const want = @atomicLoad(c.gint, &p.qos_dscp, .seq_cst);
        if (cur != want and basic.gst_net_utils_set_socket_tos(sock, want) != 0) cur = want;
        if (@atomicLoad(c.gboolean, &p.active, .seq_cst) != 0) {
            packet.*.remote_time = c.gst_clock_get_time(p.clock);
            _ = basic.gst_net_time_packet_send(packet, sock, sender, null);
        }
        if (sender) |a| c.g_object_unref(a);
        c.g_free(packet);
    }
    return null;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = priv(o);
    switch (id) {
        1 => p.port = c.g_value_get_int(v),
        2 => {
            c.g_free(p.address);
            p.address = if (c.g_value_get_string(v) == null) c.g_strdup(DEFAULT_ADDRESS) else c.g_value_dup_string(v);
        },
        3 => _ = c.gst_object_replace(@ptrCast(&p.clock), @ptrCast(@alignCast(c.g_value_get_object(v)))),
        4 => @atomicStore(c.gboolean, &p.active, c.g_value_get_boolean(v), .seq_cst),
        5 => @atomicStore(c.gint, &p.qos_dscp, c.g_value_get_int(v), .seq_cst),
        else => warnInvalid(o, id, spec, 268),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = priv(o);
    switch (id) {
        1 => c.g_value_set_int(v, p.port),
        2 => c.g_value_set_string(v, p.address),
        3 => c.g_value_set_object(v, p.clock),
        4 => c.g_value_set_boolean(v, @atomicLoad(c.gboolean, &p.active, .seq_cst)),
        5 => c.g_value_set_int(v, p.qos_dscp),
        else => warnInvalid(o, id, spec, 296),
    }
}

fn start(s: *Provider, error_out: [*c][*c]c.GError) bool {
    const p = priv(s);
    var err: [*c]c.GError = null;
    var inet: ?*c.GInetAddress = null;
    if (p.address != null) {
        inet = c.g_inet_address_new_from_string(p.address);
        if (inet == null) {
            err = c.g_error_new(c.g_io_error_quark(), c.G_IO_ERROR_FAILED, "Failed to parse address '%s'", p.address);
            c.gst_debug_log(cat, c.GST_LEVEL_ERROR, FILE, "gst_net_time_provider_start", 380, @ptrCast(s), "invalid address: %s", p.address);
            c.g_propagate_error(error_out, err);
            return false;
        }
    } else inet = c.g_inet_address_new_any(c.G_SOCKET_FAMILY_IPV4);
    const sock = c.g_socket_new(c.g_inet_address_get_family(inet), c.G_SOCKET_TYPE_DATAGRAM, c.G_SOCKET_PROTOCOL_UDP, &err);
    if (sock == null) {
        c.gst_debug_log(cat, c.GST_LEVEL_ERROR, FILE, "gst_net_time_provider_start", 386, @ptrCast(s), "could not create socket: %s", err.*.message);
        c.g_propagate_error(error_out, err);
        c.g_object_unref(inet);
        return false;
    }
    const sa = c.g_inet_socket_address_new(inet, @intCast(p.port));
    if (c.g_socket_bind(sock, sa, 1, &err) == 0) {
        c.g_object_unref(sa);
        c.g_object_unref(inet);
        c.gst_debug_log(cat, c.GST_LEVEL_ERROR, FILE, "gst_net_time_provider_start", 393, @ptrCast(s), "bind failed: %s", err.*.message);
        c.g_propagate_error(error_out, err);
        c.g_object_unref(sock);
        return false;
    }
    c.g_object_unref(sa);
    c.g_object_unref(inet);
    const bound = c.g_socket_get_local_address(sock, null);
    const port: c_int = c.g_inet_socket_address_get_port(@ptrCast(bound));
    const addr = c.g_inet_address_to_string(c.g_inet_socket_address_get_address(@ptrCast(bound)));
    if (c.g_strcmp0(addr, p.address) != 0) {
        c.g_free(p.address);
        p.address = addr;
        c.g_object_notify(@ptrCast(s), "address");
    } else c.g_free(addr);
    if (port != p.port) {
        p.port = port;
        c.g_object_notify(@ptrCast(s), "port");
    }
    c.g_object_unref(bound);
    p.socket = sock;
    p.cancel = c.g_cancellable_new();
    var dummy: c.GPollFD = undefined;
    p.made_cancel_fd = c.g_cancellable_make_pollfd(p.cancel, &dummy);
    p.thread = c.g_thread_try_new("GstNetTimeProvider", thread, s, &err);
    if (p.thread == null) {
        c.gst_debug_log(cat, c.GST_LEVEL_ERROR, FILE, "gst_net_time_provider_start", 400, @ptrCast(s), "could not create thread: %s", err.*.message);
        c.g_propagate_error(error_out, err);
        c.g_object_unref(p.socket);
        p.socket = null;
        c.g_object_unref(p.cancel);
        p.cancel = null;
        return false;
    }
    return true;
}

fn stop(s: *Provider) void {
    const p = priv(s);
    if (!basic.that(p.thread != null, "gst_net_time_provider_stop", "self->priv->thread != NULL")) return;
    c.g_cancellable_cancel(p.cancel);
    _ = c.g_thread_join(p.thread);
    p.thread = null;
    if (p.made_cancel_fd != 0) c.g_cancellable_release_fd(p.cancel);
    c.g_object_unref(p.cancel);
    p.cancel = null;
    c.g_object_unref(p.socket);
    p.socket = null;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Provider = @ptrCast(@alignCast(o));
    const p = priv(s);
    if (p.thread != null) stop(s);
    c.g_free(p.address);
    p.address = null;
    if (p.clock != null) c.gst_object_unref(p.clock);
    p.clock = null;
    parent.?.finalize.?(o);
}

fn initableInit(i: ?*c.GInitable, _: ?*c.GCancellable, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    return @intFromBool(start(@ptrCast(@alignCast(i)), err));
}

fn ifaceInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const iface: *c.GInitableIface = @ptrCast(@alignCast(g));
    iface.init = initableInit;
}

fn instanceInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Provider = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(priv(s));
    const p = priv(s);
    p.port = 5637;
    p.address = c.g_strdup(DEFAULT_ADDRESS);
    p.qos_dscp = -1;
    p.thread = null;
    p.active = 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    c.g_type_class_adjust_private_offset(k, &offset);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = finalize;
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const ss = c.G_PARAM_STATIC_STRINGS;
    const co = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | ss;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_int("port", "port", "The port to receive the packets from, 0=allocate", 0, 65535, 5637, co));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_string("address", "address", "The address to bind on, as a dotted quad (x.x.x.x)", DEFAULT_ADDRESS, co));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_object("clock", "Clock", "The clock to export over the network", c.gst_clock_get_type(), co));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_boolean("active", "Active", "TRUE if the clock will respond to queries over the network", 1, c.G_PARAM_READWRITE | ss));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_int("qos-dscp", "QoS diff srv code point", "Quality of Service, differentiated services code point (-1 default)", -1, 63, -1, c.G_PARAM_READWRITE | ss));
}

pub export fn gst_net_time_provider_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstNetTimeProvider", c.GstNetTimeProviderClass, Provider, classInit, instanceInit, 0);
            offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            cat = c._gst_debug_category_new("nettime", 0, "Network time provider");
            const info = c.GInterfaceInfo{ .interface_init = ifaceInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.g_initable_get_type(), &info);
            return t;
        }
    }.f);
}

pub export fn gst_net_time_provider_new(clock: [*c]c.GstClock, address: [*c]const u8, port: c.gint) [*c]Provider {
    const F = "gst_net_time_provider_new";
    if (!basic.that(clock != null and gtype.instanceOf(clock, c.gst_clock_get_type()), F, "clock && GST_IS_CLOCK (clock)")) return null;
    if (!basic.that(port >= 0 and port <= 65535, F, "port >= 0 && port <= G_MAXUINT16")) return null;
    const r = c.g_initable_new(gst_net_time_provider_get_type(), null, null, "clock", clock, "address", address, "port", port, @as(?*anyopaque, null));
    if (r != null) _ = c.g_object_ref_sink(r);
    return @ptrCast(@alignCast(r));
}
