const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const common = @import("common.zig");
const types = @import("types.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Dtls = types.DtlsTransport;

const FILE = "../gst-libs/gst/webrtc/dtlstransport.c";

var once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;

pub export fn gst_webrtc_dtls_transport_new(session_id: c.guint) ?*Dtls {
    return @ptrCast(@alignCast(c.g_object_new(gst_webrtc_dtls_transport_get_type(), "session-id", session_id, @as(?*anyopaque, null))));
}

pub export fn gst_webrtc_dtls_transport_set_transport(transport: ?*Dtls, ice: [*c]c.GstWebRTCICETransport) void {
    const F = "gst_webrtc_dtls_transport_set_transport";
    if (!common.that(gtype.instanceOf(transport, gst_webrtc_dtls_transport_get_type()), F, "GST_IS_WEBRTC_DTLS_TRANSPORT (transport)")) return;
    if (!common.that(gtype.instanceOf(ice, c.gst_webrtc_ice_transport_get_type()), F, "GST_IS_WEBRTC_ICE_TRANSPORT (ice)")) return;
    const t = transport.?;
    common.objectLock(t);
    const changed = c.gst_object_replace(@ptrCast(&t.transport), @ptrCast(@alignCast(ice)));
    common.objectUnlock(t);
    if (changed != 0) c.g_object_notify(@ptrCast(t), "transport");
}

fn element(e: [*c]c.GstElement) ?*c.GObject {
    return if (e == null) null else @ptrCast(@alignCast(e));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const t: *Dtls = @ptrCast(@alignCast(o));
    switch (id) {
        1 => t.session_id = c.g_value_get_uint(v),
        4 => if (element(t.dtlssrtpenc)) |e| c.g_object_set_property(e, "is-client", v),
        5 => if (element(t.dtlssrtpdec)) |e| c.g_object_set_property(e, "pem", v),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const t: *Dtls = @ptrCast(@alignCast(o));
    common.objectLock(t);
    defer common.objectUnlock(t);
    switch (id) {
        1 => c.g_value_set_uint(v, t.session_id),
        2 => c.g_value_set_object(v, t.transport),
        3 => c.g_value_set_enum(v, @intCast(t.state)),
        4 => if (element(t.dtlssrtpenc)) |e| c.g_object_get_property(e, "is-client", v),
        5 => if (element(t.dtlssrtpdec)) |e| c.g_object_get_property(e, "pem", v),
        6 => if (element(t.dtlssrtpdec)) |e| c.g_object_get_property(e, "peer-pem", v),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn onConnectionState(obj: ?*c.GObject, _: [*c]c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const t: *Dtls = @ptrCast(@alignCast(data));
    var state: c.gint = 0;
    c.g_object_get(obj, "connection-state", &state, @as(?*anyopaque, null));
    t.state = switch (state) {
        0 => c.GST_WEBRTC_DTLS_TRANSPORT_STATE_NEW,
        1 => c.GST_WEBRTC_DTLS_TRANSPORT_STATE_CLOSED,
        3 => c.GST_WEBRTC_DTLS_TRANSPORT_STATE_CONNECTING,
        4 => c.GST_WEBRTC_DTLS_TRANSPORT_STATE_CONNECTED,
        else => c.GST_WEBRTC_DTLS_TRANSPORT_STATE_FAILED,
    };
    c.g_object_notify(@ptrCast(t), "state");
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    if (parent.?.constructed) |f| f(o);
    const t: *Dtls = @ptrCast(@alignCast(o));
    const id = c.g_strdup_printf("rtp_%u_%u", t.session_id, c.g_random_int());
    defer c.g_free(id);
    t.dtlssrtpenc = c.gst_element_factory_make("dtlssrtpenc", null);
    if (t.dtlssrtpenc != null) {
        _ = c.gst_object_ref_sink(t.dtlssrtpenc);
        c.g_object_set(t.dtlssrtpenc, "connection-id", id, "is-client", t.client, "rtp-sync", @as(c.gboolean, 0), @as(?*anyopaque, null));
        _ = c.g_signal_connect_data(t.dtlssrtpenc, "notify::connection-state", @ptrCast(&onConnectionState), t, null, 0);
    }
    t.dtlssrtpdec = c.gst_element_factory_make("dtlssrtpdec", null);
    if (t.dtlssrtpdec != null) {
        _ = c.gst_object_ref_sink(t.dtlssrtpdec);
        c.g_object_set(t.dtlssrtpdec, "connection-id", id, @as(?*anyopaque, null));
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const t: *Dtls = @ptrCast(@alignCast(o));
    if (t.dtlssrtpdec != null) c.gst_object_unref(t.dtlssrtpdec);
    t.dtlssrtpdec = null;
    if (t.dtlssrtpenc != null) c.gst_object_unref(t.dtlssrtpenc);
    t.dtlssrtpenc = null;
    parent.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const t: *Dtls = @ptrCast(@alignCast(o));
    if (t.transport != null) c.gst_object_unref(t.transport);
    t.transport = null;
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.constructed = constructed;
    gc.dispose = dispose;
    gc.finalize = finalize;
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const ss = c.G_PARAM_STATIC_STRINGS;
    const ro = c.G_PARAM_READABLE | ss;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_uint("session-id", "Session ID", "Unique session ID", 0, std.math.maxInt(c.guint), 0, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | ss));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_object("transport", "ICE transport", "ICE transport used by this dtls transport", c.gst_webrtc_ice_transport_get_type(), ro));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_enum("state", "DTLS state", "State of the DTLS transport", c.gst_webrtc_dtls_transport_state_get_type(), c.GST_WEBRTC_DTLS_TRANSPORT_STATE_NEW, ro));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_boolean("client", "DTLS client", "Are we the client in the DTLS handshake?", 0, c.G_PARAM_READWRITE | ss));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_string("certificate", "DTLS certificate", "DTLS certificate", null, c.G_PARAM_READWRITE | ss));
    c.g_object_class_install_property(gc, 6, c.g_param_spec_string("remote-certificate", "Remote DTLS certificate", "Remote DTLS certificate", null, ro));
}

pub export fn gst_webrtc_dtls_transport_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstWebRTCDTLSTransport", types.DtlsTransportClass, Dtls, classInit, null, 0);
            common.category("webrtcdtlstransport");
            return t;
        }
    }.f);
}
