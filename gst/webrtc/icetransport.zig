const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const common = @import("common.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Transport = c.GstWebRTCICETransport;
const Class = c.GstWebRTCICETransportClass;

const FILE = "../gst-libs/gst/webrtc/icetransport.c";

var once: gtype.Once = .{};
var selected_signal: c.guint = 0;
var candidate_signal: c.guint = 0;

pub export fn gst_webrtc_ice_transport_connection_state_change(ice: [*c]Transport, state: c.GstWebRTCICEConnectionState) void {
    common.objectLock(ice);
    ice.*.state = state;
    common.objectUnlock(ice);
    c.g_object_notify(@ptrCast(@alignCast(ice)), "state");
}

pub export fn gst_webrtc_ice_transport_gathering_state_change(ice: [*c]Transport, state: c.GstWebRTCICEGatheringState) void {
    common.objectLock(ice);
    ice.*.gathering_state = state;
    common.objectUnlock(ice);
    c.g_object_notify(@ptrCast(@alignCast(ice)), "gathering-state");
}

pub export fn gst_webrtc_ice_transport_selected_pair_change(ice: [*c]Transport) void {
    c.g_signal_emit(ice, selected_signal, 0);
}

pub export fn gst_webrtc_ice_transport_new_candidate(ice: [*c]Transport, stream_id: c.guint, component: c.GstWebRTCICEComponent, attr: [*c]const u8) void {
    _ = stream_id;
    _ = component;
    c.g_signal_emit(ice, candidate_signal, 0, attr);
}

pub export fn gst_webrtc_ice_transport_get_selected_candidate_pair(transport: [*c]Transport) [*c]c.GstWebRTCICECandidatePair {
    const f = gtype.classPeek(Class, transport).get_selected_candidate_pair orelse return null;
    return f(transport);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const t: *Transport = @ptrCast(@alignCast(o));
    switch (id) {
        1 => t.component = @intCast(c.g_value_get_enum(v)),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const t: *Transport = @ptrCast(@alignCast(o));
    switch (id) {
        1 => c.g_value_set_enum(v, @intCast(t.component)),
        2 => c.g_value_set_enum(v, @intCast(t.state)),
        3 => c.g_value_set_enum(v, @intCast(t.gathering_state)),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const ss = c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_enum("component", "ICE component", "The ICE component of this transport", c.gst_webrtc_ice_component_get_type(), 0, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | ss));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_enum("state", "ICE connection state", "The ICE connection state of this transport", c.gst_webrtc_ice_connection_state_get_type(), 0, c.G_PARAM_READABLE | ss));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_enum("gathering-state", "ICE gathering state", "The ICE gathering state of this transport", c.gst_webrtc_ice_gathering_state_get_type(), 0, c.G_PARAM_READABLE | ss));
    const t = gc.g_type_class.g_type;
    selected_signal = c.g_signal_new("on-selected-candidate-pair-change", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 0);
    candidate_signal = c.g_signal_new("on-new-candidate", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 1, c.G_TYPE_STRING);
}

pub export fn gst_webrtc_ice_transport_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstWebRTCICETransport", Class, Transport, classInit, null, c.G_TYPE_FLAG_ABSTRACT);
            common.category("webrtcicetransport");
            return t;
        }
    }.f);
}
