const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const tcp = @import("common.zig");

const SRC_FILE = "../gst/tcp/gsttcpclientsrc.c";
const SINK_FILE = "../gst/tcp/gsttcpclientsink.c";
const DOMAIN = "gst-plugins-base-1.0";
const PROP_HOST = 1;
const PROP_PORT = 2;
const PROP_TIMEOUT = 3;
const PROP_STATS = 4;
const SRC_OPEN: c.guint = c.GST_BASE_SRC_FLAG_LAST;
const SINK_OPEN: c.guint = c.GST_ELEMENT_FLAG_LAST;
const MAX_READ_SIZE = 4 * 1024;

const Src = extern struct {
    parent: c.GstPushSrc,
    port: c.gint,
    host: [*c]u8,
    timeout: c.guint,
    socket: ?*c.GSocket,
    cancellable: ?*c.GCancellable,
    bytes_received: u64,
    stats: ?*c.GstStructure,
};

const SrcClass = extern struct {
    parent: c.GstPushSrcClass,
};

const Sink = extern struct {
    parent: c.GstBaseSink,
    port: c.gint,
    host: [*c]u8,
    socket: ?*c.GSocket,
    cancellable: ?*c.GCancellable,
    data_written: usize,
};

const SinkClass = extern struct {
    parent: c.GstBaseSinkClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_once: cm.Once = .{};
var sink_once: cm.Once = .{};
var src_parent: ?*c.GstPushSrcClass = null;
var sink_parent: ?*c.GstBaseSinkClass = null;

fn src(p: anytype) *Src {
    return @ptrCast(@alignCast(p));
}

fn sink(p: anytype) *Sink {
    return @ptrCast(@alignCast(p));
}

fn setFlag(o: anytype, f: c.guint, on: bool) void {
    if (on) cm.obj(o).flags |= f else cm.obj(o).flags &= ~f;
}

fn openError(o: anytype, comptime file: []const u8, comptime func: []const u8, debug: [*c]u8, line: c.gint) void {
    cm.elementError(o, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, null, debug, file, func, line);
}

fn connect(o: anytype, host: [*c]u8, port: c.gint, cancel: ?*c.GCancellable, socket: *?*c.GSocket, timeout: ?c.guint, comptime file: []const u8, comptime func: []const u8, lines: [3]c.gint) bool {
    var err: [*c]c.GError = null;
    var addrs = tcp.getAddresses(o, host, cancel, &err);
    if (addrs == null) {
        if (!tcp.isCancelled(err)) openError(o, file, func, c.g_strdup_printf("Failed to resolve host '%s': %s", host, err.*.message), lines[0]);
        c.g_clear_error(&err);
        return false;
    }
    var cur = addrs;
    var saddr: ?*c.GSocketAddress = null;
    while (cur != null) {
        c.g_clear_error(&err);
        if (socket.*) |x| c.g_object_unref(x);
        socket.* = tcp.createSocket(o, &cur, @intCast(port), &saddr, &err);
        if (socket.* == null) {
            c.g_list_free_full(addrs, c.g_object_unref);
            openError(o, file, func, c.g_strdup_printf("Failed to create socket: %s", err.*.message), lines[1]);
            c.g_clear_error(&err);
            return false;
        }
        if (timeout) |t| c.g_socket_set_timeout(socket.*, t);
        if (c.g_socket_connect(socket.*, saddr, cancel, &err) != 0) break;
        c.g_object_unref(saddr);
        saddr = null;
        if (tcp.isCancelled(err)) break;
    }
    if (err != null) {
        c.g_list_free_full(addrs, c.g_object_unref);
        addrs = null;
        if (!tcp.isCancelled(err)) openError(o, file, func, c.g_strdup_printf("Failed to connect to host '%s:%d': %s", host, port, err.*.message), lines[2]);
        c.g_clear_error(&err);
        return false;
    }
    c.g_list_free_full(addrs, c.g_object_unref);
    if (saddr) |x| c.g_object_unref(x);
    return true;
}

fn srcFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s = src(o);
    if (s.cancellable) |x| c.g_object_unref(x);
    s.cancellable = null;
    if (s.socket) |x| c.g_object_unref(x);
    s.socket = null;
    c.g_free(s.host);
    s.host = null;
    if (s.stats) |x| c.gst_structure_free(x);
    s.stats = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(src_parent.?))).finalize.?(o);
}

fn srcGetCaps(_: [*c]c.GstBaseSrc, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    return if (filter != null) c.gst_caps_ref(filter) else c.gst_caps_new_any();
}

fn srcReadError(s: *Src, debug: [*c]u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_READ, null, debug, SRC_FILE, "gst_tcp_client_src_create", line);
}

fn srcCreate(p: [*c]c.GstPushSrc, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = src(p);
    if (!tcp.flagSet(s, SRC_OPEN)) return c.GST_FLOW_FLUSHING;
    var err: [*c]c.GError = null;
    var avail = c.g_socket_get_available_bytes(s.socket);
    if (avail < 0) {
        srcReadError(s, c.g_strdup("Failed to get available bytes from socket"), 341);
        return c.GST_FLOW_ERROR;
    }
    if (avail == 0) {
        const cond: c.GIOCondition = c.G_IO_IN | c.G_IO_PRI | c.G_IO_ERR | c.G_IO_HUP;
        if (c.g_socket_condition_wait(s.socket, cond, s.cancellable, &err) == 0) {
            var ret: c.GstFlowReturn = c.GST_FLOW_FLUSHING;
            if (!tcp.isCancelled(err)) {
                srcReadError(s, c.g_strdup_printf("Select failed: %s", err.*.message), 332);
                ret = c.GST_FLOW_ERROR;
            }
            c.g_clear_error(&err);
            return ret;
        }
        const now = c.g_socket_condition_check(s.socket, cond);
        if (now & c.G_IO_ERR != 0) {
            srcReadError(s, c.g_strdup("Socket in error state"), 256);
            out.* = null;
            return c.GST_FLOW_ERROR;
        } else if (now & c.G_IO_HUP != 0) {
            out.* = null;
            return c.GST_FLOW_EOS;
        }
        avail = c.g_socket_get_available_bytes(s.socket);
        if (avail < 0) {
            srcReadError(s, c.g_strdup("Failed to get available bytes from socket"), 341);
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
        rret = c.g_socket_receive(s.socket, @ptrCast(map.data), @intCast(read), s.cancellable, &err);
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
            srcReadError(s, c.g_strdup_printf("Failed to read from socket: %s", err.*.message), 300);
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

fn srcStats(s: *Src) ?*c.GstStructure {
    if (s.stats) |x| return c.gst_structure_copy(x);
    const st = c.gst_structure_new("GstTCPClientSrcStats", "bytes-received", c.G_TYPE_UINT64, s.bytes_received, @as(?*anyopaque, null));
    if (s.socket != null) tcp.statsFromSocket(st, s.socket);
    return st;
}

fn srcSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = src(o);
    switch (id) {
        PROP_HOST => {
            if (c.g_value_get_string(v) == null) {
                c.g_log(null, c.G_LOG_LEVEL_WARNING, "host property cannot be NULL");
                return;
            }
            c.g_free(s.host);
            s.host = c.g_value_dup_string(v);
        },
        PROP_PORT => s.port = c.g_value_get_int(v),
        PROP_TIMEOUT => s.timeout = c.g_value_get_uint(v),
        else => cm.warnInvalid(SRC_FILE, o, id, spec, 375),
    }
}

fn srcGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = src(o);
    switch (id) {
        PROP_HOST => c.g_value_set_string(v, s.host),
        PROP_PORT => c.g_value_set_int(v, s.port),
        PROP_TIMEOUT => c.g_value_set_uint(v, s.timeout),
        PROP_STATS => c.g_value_take_boxed(v, srcStats(s)),
        else => cm.warnInvalid(SRC_FILE, o, id, spec, 400),
    }
}

fn srcStart(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = src(b);
    s.bytes_received = 0;
    if (s.stats) |x| c.gst_structure_free(x);
    s.stats = null;
    if (!connect(s, s.host, s.port, s.cancellable, &s.socket, s.timeout, SRC_FILE, "gst_tcp_client_src_start", .{ 471, 480, 491 })) {
        if (s.socket != null) {
            setFlag(s, SRC_OPEN, true);
            _ = srcStop(b);
        }
        return 0;
    }
    setFlag(s, SRC_OPEN, true);
    return 1;
}

fn srcStop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = src(b);
    if (s.socket) |sock| {
        s.stats = srcStats(s);
        var err: [*c]c.GError = null;
        if (c.g_socket_close(sock, &err) == 0) c.g_clear_error(&err);
        c.g_object_unref(sock);
        s.socket = null;
    }
    setFlag(s, SRC_OPEN, false);
    return 1;
}

fn srcUnlock(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    c.g_cancellable_cancel(src(b).cancellable);
    return 1;
}

fn srcUnlockStop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = src(b);
    c.g_object_unref(s.cancellable);
    s.cancellable = c.g_cancellable_new();
    return 1;
}

fn srcClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    src_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = srcSetProperty;
    oc.get_property = srcGetProperty;
    oc.finalize = srcFinalize;
    c.g_object_class_install_property(oc, PROP_HOST, c.g_param_spec_string("host", "Host", "The host IP address to receive packets from", tcp.DEFAULT_HOST, cm.RW));
    c.g_object_class_install_property(oc, PROP_PORT, c.g_param_spec_int("port", "Port", "The port to receive packets from", 0, tcp.HIGHEST_PORT, tcp.DEFAULT_PORT, cm.RW));
    c.g_object_class_install_property(oc, PROP_TIMEOUT, c.g_param_spec_uint("timeout", "timeout", "Value in seconds to timeout a blocking I/O. 0 = No timeout. ", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_STATS, c.g_param_spec_boxed("stats", "Stats", "Retrieve a statistics structure", c.gst_structure_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "TCP client source", "Source/Network", "Receive data as a client over the network via TCP", "Thomas Vander Stichele <thomas at apestaart dot org>");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.get_caps = srcGetCaps;
    bc.start = srcStart;
    bc.stop = srcStop;
    bc.unlock = srcUnlock;
    bc.unlock_stop = srcUnlockStop;
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).create = srcCreate;
    _ = c._gst_debug_category_new("tcpclientsrc", 0, "TCP Client Source");
}

fn srcInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = src(inst);
    s.port = tcp.DEFAULT_PORT;
    s.host = c.g_strdup(tcp.DEFAULT_HOST);
    s.timeout = 0;
    s.socket = null;
    s.cancellable = c.g_cancellable_new();
    setFlag(s, SRC_OPEN, false);
}

pub fn srcType() c.GType {
    return src_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_push_src_get_type(), "GstTCPClientSrc", SrcClass, Src, srcClassInit, srcInit);
        }
    }.f);
}

pub fn registerSrc(p: ?*c.GstPlugin) bool {
    tcp.elementInit();
    return c.gst_element_register(p, "tcpclientsrc", c.GST_RANK_NONE, srcType()) != 0;
}

fn sinkFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s = sink(o);
    if (s.cancellable) |x| c.g_object_unref(x);
    s.cancellable = null;
    if (s.socket) |x| c.g_object_unref(x);
    s.socket = null;
    c.g_free(s.host);
    s.host = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(sink_parent.?))).finalize.?(o);
}

fn sinkSetCaps(_: [*c]c.GstBaseSink, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    return 1;
}

fn sinkRender(b: [*c]c.GstBaseSink, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = sink(b);
    if (!cm.that(tcp.flagSet(s, SINK_OPEN), "gst_tcp_client_sink_render", "GST_OBJECT_FLAG_IS_SET (sink, GST_TCP_CLIENT_SINK_OPEN)")) return c.GST_FLOW_FLUSHING;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buf, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(buf, &map);
    var written: usize = 0;
    var err: [*c]c.GError = null;
    while (written < map.size) {
        const r = c.g_socket_send(s.socket, @ptrCast(map.data + written), map.size - written, s.cancellable, &err);
        if (r < 0) {
            var ret: c.GstFlowReturn = c.GST_FLOW_FLUSHING;
            if (!tcp.isCancelled(err)) {
                cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf(cm.tr(DOMAIN, "Error while sending data to \"%s:%d\"."), s.host, s.port), c.g_strdup_printf("Only %lu of %lu bytes written: %s", written, map.size, err.*.message), SINK_FILE, "gst_tcp_client_sink_render", 217);
                ret = c.GST_FLOW_ERROR;
            }
            c.g_clear_error(&err);
            return ret;
        }
        written += @intCast(r);
    }
    s.data_written += written;
    return c.GST_FLOW_OK;
}

fn sinkSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = sink(o);
    switch (id) {
        PROP_HOST => {
            if (c.g_value_get_string(v) == null) {
                c.g_log(null, c.G_LOG_LEVEL_WARNING, "host property cannot be NULL");
                return;
            }
            c.g_free(s.host);
            s.host = c.g_value_dup_string(v);
        },
        PROP_PORT => s.port = c.g_value_get_int(v),
        else => cm.warnInvalid(SINK_FILE, o, id, spec, 252),
    }
}

fn sinkGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = sink(o);
    switch (id) {
        PROP_HOST => c.g_value_set_string(v, s.host),
        PROP_PORT => c.g_value_set_int(v, s.port),
        else => cm.warnInvalid(SINK_FILE, o, id, spec, 274),
    }
}

fn sinkStart(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = sink(b);
    if (tcp.flagSet(s, SINK_OPEN)) return 1;
    if (!connect(s, s.host, s.port, s.cancellable, &s.socket, null, SINK_FILE, "gst_tcp_client_sink_start", .{ 346, 355, 366 })) {
        if (s.socket != null) {
            setFlag(s, SINK_OPEN, true);
            _ = sinkStop(b);
        }
        return 0;
    }
    setFlag(s, SINK_OPEN, true);
    s.data_written = 0;
    return 1;
}

fn sinkStop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = sink(b);
    if (!tcp.flagSet(s, SINK_OPEN)) return 1;
    if (s.socket) |sock| {
        var err: [*c]c.GError = null;
        if (c.g_socket_close(sock, &err) == 0) c.g_clear_error(&err);
        c.g_object_unref(sock);
        s.socket = null;
    }
    setFlag(s, SINK_OPEN, false);
    return 1;
}

fn sinkUnlock(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    c.g_cancellable_cancel(sink(b).cancellable);
    return 1;
}

fn sinkUnlockStop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = sink(b);
    c.g_object_unref(s.cancellable);
    s.cancellable = c.g_cancellable_new();
    return 1;
}

fn sinkClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    sink_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = sinkSetProperty;
    oc.get_property = sinkGetProperty;
    oc.finalize = sinkFinalize;
    c.g_object_class_install_property(oc, PROP_HOST, c.g_param_spec_string("host", "Host", "The host/IP to send the packets to", tcp.DEFAULT_HOST, cm.RW));
    c.g_object_class_install_property(oc, PROP_PORT, c.g_param_spec_int("port", "Port", "The port to send the packets to", 0, tcp.HIGHEST_PORT, tcp.DEFAULT_PORT, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "TCP client sink", "Sink/Network", "Send data as a client over the network via TCP", "Thomas Vander Stichele <thomas at apestaart dot org>");
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.start = sinkStart;
    bc.stop = sinkStop;
    bc.set_caps = sinkSetCaps;
    bc.render = sinkRender;
    bc.unlock = sinkUnlock;
    bc.unlock_stop = sinkUnlockStop;
    _ = c._gst_debug_category_new("tcpclientsink", 0, "TCP sink");
}

fn sinkInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = sink(inst);
    s.host = c.g_strdup(tcp.DEFAULT_HOST);
    s.port = tcp.DEFAULT_PORT;
    s.socket = null;
    s.cancellable = c.g_cancellable_new();
    setFlag(s, SINK_OPEN, false);
}

pub fn sinkType() c.GType {
    return sink_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_base_sink_get_type(), "GstTCPClientSink", SinkClass, Sink, sinkClassInit, sinkInit);
        }
    }.f);
}

pub fn registerSink(p: ?*c.GstPlugin) bool {
    tcp.elementInit();
    return c.gst_element_register(p, "tcpclientsink", c.GST_RANK_NONE, sinkType()) != 0;
}
