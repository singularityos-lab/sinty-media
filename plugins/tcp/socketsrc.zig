const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const tcp = @import("common.zig");

const FILE = "../gst/tcp/gstsocketsrc.c";
const PROP_SOCKET = 1;
const PROP_CAPS = 2;
const PROP_SEND_MESSAGES = 3;

const Self = extern struct {
    parent: c.GstPushSrc,
    caps: [*c]c.GstCaps,
    socket: ?*c.GSocket,
    send_messages: c.gboolean,
    cancellable: ?*c.GCancellable,
};

const Class = extern struct {
    parent: c.GstPushSrcClass,
    connection_closed_by_peer: ?*const fn (*Self) callconv(.c) void,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstBaseSrcClass = null;
var sig_closed: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn socketRef(s: *Self) ?*c.GSocket {
    cm.lock(s);
    defer cm.unlock(s);
    return if (s.socket) |x| @ptrCast(@alignCast(c.g_object_ref(x))) else null;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.caps != null) c.gst_caps_unref(s.caps);
    if (s.cancellable) |x| c.g_object_unref(x);
    s.cancellable = null;
    if (s.socket) |x| c.g_object_unref(x);
    s.socket = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn event(b: [*c]c.GstBaseSrc, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(b);
    if (cm.eventType(e) != c.GST_EVENT_CUSTOM_UPSTREAM) return parent.?.event.?(b, e);
    var res: c.gboolean = 0;
    if (s.send_messages != 0 and c.gst_event_has_name(e, "GstNetworkMessage") != 0) {
        const st = c.gst_event_get_structure(e);
        if (socketRef(s)) |socket| {
            defer c.g_object_unref(socket);
            var buf: [*c]c.GstBuffer = null;
            _ = c.gst_structure_get(st, "buffer", c.gst_buffer_get_type(), &buf, @as(?*anyopaque, null));
            if (buf != null) {
                var map: c.GstMapInfo = undefined;
                _ = c.gst_buffer_map(buf, &map, c.GST_MAP_READ);
                var err: [*c]c.GError = null;
                const ret = c.g_socket_send_with_blocking(socket, @ptrCast(map.data), map.size, 0, s.cancellable, &err);
                c.gst_buffer_unmap(buf, &map);
                if (ret == -1) {
                    c.g_clear_error(&err);
                } else res = 1;
                c.gst_buffer_unref(buf);
            }
        }
    }
    return res;
}

fn getCaps(b: [*c]c.GstBaseSrc, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(b);
    cm.lock(s);
    const caps = if (s.caps != null) c.gst_caps_ref(s.caps) else null;
    cm.unlock(s);
    if (caps != null) {
        if (filter == null) return caps;
        const r = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        return r;
    }
    return if (filter != null) c.gst_caps_ref(filter) else c.gst_caps_new_any();
}

fn fill(p: [*c]c.GstPushSrc, out: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(p);
    var socket = socketRef(s) orelse {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, null, c.g_strdup("Cannot receive: No socket set on socketsrc"), FILE, "gst_socket_src_fill", 381);
        return c.GST_FLOW_ERROR;
    };
    var err: [*c]c.GError = null;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    while (true) {
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(out, &map, c.GST_MAP_READWRITE);
        var vec = c.GInputVector{ .buffer = map.data, .size = map.size };
        var messages: [*c]?*c.GSocketControlMessage = null;
        var n: c.gint = 0;
        var flags: c.gint = 0;
        const rret = c.g_socket_receive_message(socket, null, &vec, 1, @ptrCast(&messages), &n, &flags, s.cancellable, &err);
        c.gst_buffer_unmap(out, &map);
        for (0..@intCast(n)) |i| {
            _ = c.gst_buffer_add_net_control_message_meta(out, messages[i]);
            c.g_object_unref(messages[i]);
            messages[i] = null;
        }
        c.g_free(@ptrCast(messages));
        if (rret == 0) {
            c.g_signal_emit(s, sig_closed, 0);
            const other = socketRef(s);
            if (other != null and other != socket) {
                c.g_object_unref(socket);
                socket = other.?;
                continue;
            }
            if (other) |x| c.g_object_unref(x);
            ret = c.GST_FLOW_EOS;
        } else if (rret < 0) {
            if (tcp.isCancelled(err)) {
                ret = c.GST_FLOW_FLUSHING;
            } else {
                ret = c.GST_FLOW_ERROR;
                cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_READ, null, c.g_strdup_printf("Failed to read from socket: %s", err.*.message), FILE, "gst_socket_src_fill", 358);
            }
        } else c.gst_buffer_resize(out, 0, rret);
        break;
    }
    c.g_clear_error(&err);
    c.g_object_unref(socket);
    return ret;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SOCKET => {
            const socket: ?*c.GSocket = @ptrCast(@alignCast(c.g_value_dup_object(v)));
            cm.lock(s);
            const old = s.socket;
            s.socket = socket;
            cm.unlock(s);
            if (old) |x| c.g_object_unref(x);
        },
        PROP_CAPS => {
            const val = c.gst_value_get_caps(v);
            const caps = if (val == null) c.gst_caps_new_any() else c.gst_caps_copy(val);
            cm.lock(s);
            const old = s.caps;
            s.caps = caps;
            cm.unlock(s);
            if (old != null) c.gst_caps_unref(old);
            c.gst_pad_mark_reconfigure(@as(*c.GstBaseSrc, @ptrCast(@alignCast(s))).srcpad);
        },
        PROP_SEND_MESSAGES => s.send_messages = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 429),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SOCKET => c.g_value_set_object(v, s.socket),
        PROP_CAPS => {
            cm.lock(s);
            c.gst_value_set_caps(v, s.caps);
            cm.unlock(s);
        },
        PROP_SEND_MESSAGES => c.g_value_set_boolean(v, s.send_messages),
        else => cm.warnInvalid(FILE, o, id, spec, 453),
    }
}

fn unlock(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    c.g_cancellable_cancel(me(b).cancellable);
    return 1;
}

fn unlockStop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    c.g_cancellable_reset(me(b).cancellable);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.g_object_class_install_property(oc, PROP_SOCKET, c.g_param_spec_object("socket", "Socket", "The socket to receive packets from", c.g_socket_get_type(), cm.RW));
    c.g_object_class_install_property(oc, PROP_CAPS, c.g_param_spec_boxed("caps", "Caps", "The caps of the source pad", c.gst_caps_get_type(), cm.RW));
    c.g_object_class_install_property(oc, PROP_SEND_MESSAGES, c.g_param_spec_boolean("send-messages", "Send Messages", "If GstNetworkMessage events should be handled", 0, cm.RW));
    sig_closed = c.g_signal_new("connection-closed-by-peer", cm.typeOfClass(k), c.G_SIGNAL_RUN_FIRST, @offsetOf(Class, "connection_closed_by_peer"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 0));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "socket source", "Source/Network", "Receive data from a socket", "Thomas Vander Stichele <thomas at apestaart dot org>, William Manley <will@williammanley.net>");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.event = event;
    bc.get_caps = getCaps;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).fill = fill;
    _ = c._gst_debug_category_new("socketsrc", 0, "Socket Source");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.socket = null;
    s.cancellable = c.g_cancellable_new();
    s.send_messages = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_push_src_get_type(), "GstSocketSrc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    tcp.elementInit();
    return c.gst_element_register(p, "socketsrc", c.GST_RANK_NONE, getType()) != 0;
}
