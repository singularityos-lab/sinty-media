const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const tcp = @import("common.zig");

const FILE = "../gst/tcp/gsttcpserversrc.c";
const PROP_HOST = 1;
const PROP_PORT = 2;
const PROP_CURRENT_PORT = 3;
const PROP_STATS = 4;
const OPEN: c.guint = c.GST_BASE_SRC_FLAG_LAST;
const BACKLOG = 1;
const MAX_READ_SIZE = 4 * 1024;

const Self = extern struct {
    parent: c.GstPushSrc,
    current_port: c.gint,
    server_port: c.gint,
    host: [*c]u8,
    server_socket: ?*c.GSocket,
    client_socket: ?*c.GSocket,
    cancellable: ?*c.GCancellable,
    bytes_received: u64,
    stats: ?*c.GstStructure,
};

const Class = extern struct {
    parent: c.GstPushSrcClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstPushSrcClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn setOpen(s: *Self, on: bool) void {
    if (on) cm.obj(s).flags |= OPEN else cm.obj(s).flags &= ~OPEN;
}

fn closeSocket(sock: ?*c.GSocket) void {
    var err: [*c]c.GError = null;
    if (c.g_socket_close(sock, &err) == 0) c.g_clear_error(&err);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.cancellable) |x| c.g_object_unref(x);
    s.cancellable = null;
    if (s.server_socket) |x| c.g_object_unref(x);
    s.server_socket = null;
    if (s.client_socket) |x| c.g_object_unref(x);
    s.client_socket = null;
    c.g_free(s.host);
    s.host = null;
    if (s.stats) |x| c.gst_structure_free(x);
    s.stats = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn fail(s: *Self, code: c.gint, debug: [*c]u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, null, debug, FILE, "gst_tcp_server_src_create", line);
}

fn create(p: [*c]c.GstPushSrc, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(p);
    if (!tcp.flagSet(s, OPEN)) return c.GST_FLOW_FLUSHING;
    var err: [*c]c.GError = null;
    if (s.client_socket == null) {
        s.client_socket = c.g_socket_accept(s.server_socket, s.cancellable, &err);
        if (s.client_socket == null) {
            var ret: c.GstFlowReturn = c.GST_FLOW_FLUSHING;
            if (!tcp.isCancelled(err)) {
                fail(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf("Failed to accept client: %s", err.*.message), 338);
                ret = c.GST_FLOW_ERROR;
            }
            c.g_clear_error(&err);
            return ret;
        }
        closeSocket(s.server_socket);
    }
    var avail = c.g_socket_get_available_bytes(s.client_socket);
    if (avail < 0) {
        fail(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup("Failed to get available bytes from socket"), 360);
        return c.GST_FLOW_ERROR;
    }
    if (avail == 0) {
        const cond: c.GIOCondition = c.G_IO_IN | c.G_IO_PRI | c.G_IO_ERR | c.G_IO_HUP;
        if (c.g_socket_condition_wait(s.client_socket, cond, s.cancellable, &err) == 0) {
            var ret: c.GstFlowReturn = c.GST_FLOW_FLUSHING;
            if (!tcp.isCancelled(err)) {
                fail(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf("Select failed: %s", err.*.message), 351);
                ret = c.GST_FLOW_ERROR;
            }
            c.g_clear_error(&err);
            return ret;
        }
        const now = c.g_socket_condition_check(s.client_socket, cond);
        if (now & c.G_IO_ERR != 0) {
            fail(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup("Socket in error state"), 257);
            out.* = null;
            return c.GST_FLOW_ERROR;
        } else if (now & c.G_IO_HUP != 0) {
            out.* = null;
            return c.GST_FLOW_EOS;
        }
        avail = c.g_socket_get_available_bytes(s.client_socket);
        if (avail < 0) {
            fail(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup("Failed to get available bytes from socket"), 360);
            return c.GST_FLOW_ERROR;
        }
    }
    var map: c.GstMapInfo = undefined;
    var read: isize = 0;
    var rret: isize = 0;
    if (avail > 0) {
        read = @min(avail, MAX_READ_SIZE);
        out.* = c.gst_buffer_new_allocate(null, @intCast(read), null);
        _ = c.gst_buffer_map(out.*, &map, c.GST_MAP_READWRITE);
        rret = c.g_socket_receive(s.client_socket, @ptrCast(map.data), @intCast(read), s.cancellable, &err);
    } else out.* = null;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (rret == 0) {
        ret = c.GST_FLOW_EOS;
        if (out.* != null) {
            c.gst_buffer_unmap(out.*, &map);
            c.gst_buffer_unref(out.*);
        }
        out.* = null;
    } else if (rret < 0) {
        if (tcp.isCancelled(err)) {
            ret = c.GST_FLOW_FLUSHING;
        } else {
            ret = c.GST_FLOW_ERROR;
            fail(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup_printf("Failed to read from socket: %s", err.*.message), 301);
        }
        c.gst_buffer_unmap(out.*, &map);
        c.gst_buffer_unref(out.*);
        out.* = null;
    } else {
        c.gst_buffer_unmap(out.*, &map);
        c.gst_buffer_resize(out.*, 0, rret);
        s.bytes_received += @intCast(read);
    }
    c.g_clear_error(&err);
    return ret;
}

fn stats(s: *Self) ?*c.GstStructure {
    if (s.stats) |x| return c.gst_structure_copy(x);
    const st = c.gst_structure_new("GstTCPServerSrcStats", "bytes-received", c.G_TYPE_UINT64, s.bytes_received, @as(?*anyopaque, null));
    if (s.client_socket != null) tcp.statsFromSocket(st, s.client_socket);
    return st;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_HOST => {
            if (c.g_value_get_string(v) == null) {
                c.g_log(null, c.G_LOG_LEVEL_WARNING, "host property cannot be NULL");
                return;
            }
            c.g_free(s.host);
            s.host = c.g_value_dup_string(v);
        },
        PROP_PORT => s.server_port = c.g_value_get_int(v),
        else => cm.warnInvalid(FILE, o, id, spec, 386),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_HOST => c.g_value_set_string(v, s.host),
        PROP_PORT => c.g_value_set_int(v, s.server_port),
        PROP_CURRENT_PORT => c.g_value_set_int(v, @atomicLoad(c.gint, &s.current_port, .seq_cst)),
        PROP_STATS => c.g_value_take_boxed(v, stats(s)),
        else => cm.warnInvalid(FILE, o, id, spec, 411),
    }
}

fn startError(s: *Self, debug: [*c]u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, null, debug, FILE, "gst_tcp_server_src_start", line);
}

fn start(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    var err: [*c]c.GError = null;
    s.bytes_received = 0;
    if (s.stats) |x| c.gst_structure_free(x);
    s.stats = null;
    const addrs = tcp.getAddresses(s, s.host, s.cancellable, &err);
    if (addrs == null) {
        if (!tcp.isCancelled(err)) startError(s, c.g_strdup_printf("Failed to resolve host '%s': %s", s.host, err.*.message), 491);
        c.g_clear_error(&err);
        return 0;
    }
    var cur = addrs;
    var saddr: ?*c.GSocketAddress = null;
    s.server_socket = tcp.createSocket(s, &cur, @intCast(s.server_port), &saddr, &err);
    c.g_list_free_full(addrs, c.g_object_unref);
    if (s.server_socket == null) {
        startError(s, c.g_strdup_printf("Failed to create socket: %s", err.*.message), 481);
        c.g_clear_error(&err);
        return 0;
    }
    if (c.g_socket_bind(s.server_socket, saddr, 1, &err) == 0) {
        if (!tcp.isCancelled(err)) startError(s, c.g_strdup_printf("Failed to bind on host '%s:%d': %s", s.host, s.server_port, err.*.message), 502);
        c.g_clear_error(&err);
        c.g_object_unref(saddr);
        _ = stop(b);
        return 0;
    }
    c.g_object_unref(saddr);
    c.g_socket_set_listen_backlog(s.server_socket, BACKLOG);
    if (c.g_socket_listen(s.server_socket, &err) == 0) {
        if (!tcp.isCancelled(err)) startError(s, c.g_strdup_printf("Failed to listen on host '%s:%d': %s", s.host, s.server_port, err.*.message), 516);
        c.g_clear_error(&err);
        _ = stop(b);
        return 0;
    }
    setOpen(s, true);
    var bound = s.server_port;
    if (bound == 0) {
        const local = c.g_socket_get_local_address(s.server_socket, null);
        bound = c.g_inet_socket_address_get_port(@ptrCast(local));
        c.g_object_unref(local);
    }
    @atomicStore(c.gint, &s.current_port, bound, .seq_cst);
    c.g_object_notify(@ptrCast(s), "current-port");
    return 1;
}

fn stop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    if (s.client_socket) |sock| {
        s.stats = stats(s);
        closeSocket(sock);
        c.g_object_unref(sock);
        s.client_socket = null;
    }
    if (s.server_socket) |sock| {
        closeSocket(sock);
        c.g_object_unref(sock);
        s.server_socket = null;
        @atomicStore(c.gint, &s.current_port, 0, .seq_cst);
        c.g_object_notify(@ptrCast(s), "current-port");
    }
    setOpen(s, false);
    return 1;
}

fn unlock(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    c.g_cancellable_cancel(me(b).cancellable);
    return 1;
}

fn unlockStop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    c.g_object_unref(s.cancellable);
    s.cancellable = c.g_cancellable_new();
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.g_object_class_install_property(oc, PROP_HOST, c.g_param_spec_string("host", "Host", "The hostname to listen as", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_PORT, c.g_param_spec_int("port", "Port", "The port to listen to (0=random available port)", 0, tcp.HIGHEST_PORT, tcp.DEFAULT_PORT, cm.RW));
    c.g_object_class_install_property(oc, PROP_CURRENT_PORT, c.g_param_spec_int("current-port", "current-port", "The port number the socket is currently bound to", 0, tcp.HIGHEST_PORT, 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_STATS, c.g_param_spec_boxed("stats", "Stats", "Retrieve a statistics structure", c.gst_structure_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "TCP server source", "Source/Network", "Receive data as a server over the network via TCP", "Thomas Vander Stichele <thomas at apestaart dot org>");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.start = start;
    bc.stop = stop;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).create = create;
    _ = c._gst_debug_category_new("tcpserversrc", 0, "TCP Server Source");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.server_port = tcp.DEFAULT_PORT;
    s.host = c.g_strdup(tcp.DEFAULT_HOST);
    s.server_socket = null;
    s.client_socket = null;
    s.cancellable = c.g_cancellable_new();
    setOpen(s, false);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_push_src_get_type(), "GstTCPServerSrc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    tcp.elementInit();
    return c.gst_element_register(p, "tcpserversrc", c.GST_RANK_NONE, getType()) != 0;
}
