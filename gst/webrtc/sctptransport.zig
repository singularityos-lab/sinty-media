const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const types = @import("types.zig");

comptime {
    @import("../abi.zig").check(@This());
}

var once: gtype.Once = .{};

fn getProperty(_: [*c]c.GObject, _: c.guint, _: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.get_property = getProperty;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_object("transport", "WebRTC DTLS Transport", "DTLS transport used for this SCTP transport", c.gst_webrtc_dtls_transport_get_type(), ro));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_enum("state", "WebRTC SCTP Transport state", "WebRTC SCTP Transport state", c.gst_webrtc_sctp_transport_state_get_type(), c.GST_WEBRTC_SCTP_TRANSPORT_STATE_NEW, ro));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_uint64("max-message-size", "Maximum message size", "Maximum message size as reported by the transport", 0, std.math.maxInt(c.guint64), 0, ro));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_uint("max-channels", "Maximum number of channels", "Maximum number of channels", 0, std.math.maxInt(c.guint16), 0, ro));
}

pub export fn gst_webrtc_sctp_transport_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(c.gst_object_get_type, "GstWebRTCSCTPTransport", types.SctpTransportClass, types.SctpTransport, classInit, null, c.G_TYPE_FLAG_ABSTRACT);
        }
    }.f);
}
