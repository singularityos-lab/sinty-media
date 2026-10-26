const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const common = @import("common.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Ice = c.GstWebRTCICE;
const Class = c.GstWebRTCICEClass;
const Stream = c.GstWebRTCICEStream;
const Stats = c.GstWebRTCICECandidateStats;

const FILE = "../gst-libs/gst/webrtc/ice.c";

var once: gtype.Once = .{};

fn class(ice: anytype) *Class {
    return gtype.classPeek(Class, ice);
}

fn isIce(ice: anytype) bool {
    return gtype.instanceOf(ice, gst_webrtc_ice_get_type());
}

pub export fn gst_webrtc_ice_add_stream(ice: [*c]Ice, session_id: c.guint) [*c]Stream {
    if (!common.that(isIce(ice), "gst_webrtc_ice_add_stream", "GST_IS_WEBRTC_ICE (ice)")) return null;
    const f = class(ice).add_stream orelse return null;
    return f(ice, session_id);
}

pub export fn gst_webrtc_ice_find_transport(ice: [*c]Ice, stream: [*c]Stream, component: c.GstWebRTCICEComponent) [*c]c.GstWebRTCICETransport {
    if (!common.that(isIce(ice), "gst_webrtc_ice_find_transport", "GST_IS_WEBRTC_ICE (ice)")) return null;
    const f = class(ice).find_transport orelse return null;
    return f(ice, stream, component);
}

pub export fn gst_webrtc_ice_add_candidate(ice: [*c]Ice, stream: [*c]Stream, candidate: [*c]const u8, promise: ?*c.GstPromise) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_add_candidate", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).add_candidate orelse return;
    f(ice, stream, candidate, promise);
}

pub export fn gst_webrtc_ice_set_remote_credentials(ice: [*c]Ice, stream: [*c]Stream, ufrag: [*c]const u8, pwd: [*c]const u8) c.gboolean {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_remote_credentials", "GST_IS_WEBRTC_ICE (ice)")) return 0;
    const f = class(ice).set_remote_credentials orelse return 0;
    return f(ice, stream, ufrag, pwd);
}

pub export fn gst_webrtc_ice_add_turn_server(ice: [*c]Ice, uri: [*c]const u8) c.gboolean {
    if (!common.that(isIce(ice), "gst_webrtc_ice_add_turn_server", "GST_IS_WEBRTC_ICE (ice)")) return 0;
    const f = class(ice).add_turn_server orelse return 0;
    return f(ice, uri);
}

pub export fn gst_webrtc_ice_set_local_credentials(ice: [*c]Ice, stream: [*c]Stream, ufrag: [*c]const u8, pwd: [*c]const u8) c.gboolean {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_local_credentials", "GST_IS_WEBRTC_ICE (ice)")) return 0;
    const f = class(ice).set_local_credentials orelse return 0;
    return f(ice, stream, ufrag, pwd);
}

pub export fn gst_webrtc_ice_gather_candidates(ice: [*c]Ice, stream: [*c]Stream) c.gboolean {
    if (!common.that(isIce(ice), "gst_webrtc_ice_gather_candidates", "GST_IS_WEBRTC_ICE (ice)")) return 0;
    const f = class(ice).gather_candidates orelse return 0;
    return f(ice, stream);
}

pub export fn gst_webrtc_ice_set_is_controller(ice: [*c]Ice, controller: c.gboolean) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_is_controller", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).set_is_controller orelse return;
    f(ice, controller);
}

pub export fn gst_webrtc_ice_get_is_controller(ice: [*c]Ice) c.gboolean {
    if (!common.that(isIce(ice), "gst_webrtc_ice_get_is_controller", "GST_IS_WEBRTC_ICE (ice)")) return 0;
    const f = class(ice).get_is_controller orelse return 0;
    return f(ice);
}

pub export fn gst_webrtc_ice_set_force_relay(ice: [*c]Ice, force_relay: c.gboolean) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_force_relay", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).set_force_relay orelse return;
    f(ice, force_relay);
}

pub export fn gst_webrtc_ice_set_tos(ice: [*c]Ice, stream: [*c]Stream, tos: c.guint) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_tos", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).set_tos orelse return;
    f(ice, stream, tos);
}

pub export fn gst_webrtc_ice_get_local_candidates(ice: [*c]Ice, stream: [*c]Stream) [*c][*c]Stats {
    if (!common.that(isIce(ice), "gst_webrtc_ice_get_local_candidates", "GST_IS_WEBRTC_ICE (ice)")) return null;
    const f = class(ice).get_local_candidates orelse return null;
    return f(ice, stream);
}

pub export fn gst_webrtc_ice_get_remote_candidates(ice: [*c]Ice, stream: [*c]Stream) [*c][*c]Stats {
    if (!common.that(isIce(ice), "gst_webrtc_ice_get_remote_candidates", "GST_IS_WEBRTC_ICE (ice)")) return null;
    const f = class(ice).get_remote_candidates orelse return null;
    return f(ice, stream);
}

pub export fn gst_webrtc_ice_get_selected_pair(ice: [*c]Ice, stream: [*c]Stream, local_stats: [*c][*c]Stats, remote_stats: [*c][*c]Stats) c.gboolean {
    if (!common.that(isIce(ice), "gst_webrtc_ice_get_selected_pair", "GST_IS_WEBRTC_ICE (ice)")) return 0;
    const f = class(ice).get_selected_pair orelse return 0;
    return f(ice, stream, local_stats, remote_stats);
}

pub export fn gst_webrtc_ice_set_on_ice_candidate(ice: [*c]Ice, func: c.GstWebRTCICEOnCandidateFunc, user_data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_on_ice_candidate", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).set_on_ice_candidate orelse return;
    f(ice, func, user_data, notify);
}

pub export fn gst_webrtc_ice_set_stun_server(ice: [*c]Ice, uri: [*c]const u8) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_stun_server", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).set_stun_server orelse return;
    f(ice, uri);
}

pub export fn gst_webrtc_ice_get_stun_server(ice: [*c]Ice) [*c]u8 {
    if (!common.that(isIce(ice), "gst_webrtc_ice_get_stun_server", "GST_IS_WEBRTC_ICE (ice)")) return null;
    const f = class(ice).get_stun_server orelse return null;
    return f(ice);
}

pub export fn gst_webrtc_ice_set_turn_server(ice: [*c]Ice, uri: [*c]const u8) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_turn_server", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).set_turn_server orelse return;
    f(ice, uri);
}

pub export fn gst_webrtc_ice_get_turn_server(ice: [*c]Ice) [*c]u8 {
    if (!common.that(isIce(ice), "gst_webrtc_ice_get_turn_server", "GST_IS_WEBRTC_ICE (ice)")) return null;
    const f = class(ice).get_turn_server orelse return null;
    return f(ice);
}

pub export fn gst_webrtc_ice_set_http_proxy(ice: [*c]Ice, uri: [*c]const u8) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_set_http_proxy", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).set_http_proxy orelse return;
    f(ice, uri);
}

pub export fn gst_webrtc_ice_get_http_proxy(ice: [*c]Ice) [*c]u8 {
    if (!common.that(isIce(ice), "gst_webrtc_ice_get_http_proxy", "GST_IS_WEBRTC_ICE (ice)")) return null;
    const f = class(ice).get_http_proxy orelse return null;
    return f(ice);
}

pub export fn gst_webrtc_ice_close(ice: [*c]Ice, promise: ?*c.GstPromise) void {
    if (!common.that(isIce(ice), "gst_webrtc_ice_close", "GST_IS_WEBRTC_ICE (ice)")) return;
    const f = class(ice).close orelse return;
    f(ice, promise);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const ice: *Ice = @ptrCast(@alignCast(o));
    switch (id) {
        1 => {
            ice.min_rtp_port = c.g_value_get_uint(v);
            if (ice.min_rtp_port > ice.max_rtp_port) c.g_log(common.DOMAIN, c.G_LOG_LEVEL_WARNING, "Set min-rtp-port to %u which is larger than max-rtp-port %u", ice.min_rtp_port, ice.max_rtp_port);
        },
        2 => {
            ice.max_rtp_port = c.g_value_get_uint(v);
            if (ice.min_rtp_port > ice.max_rtp_port) c.g_log(common.DOMAIN, c.G_LOG_LEVEL_WARNING, "Set max-rtp-port to %u which is smaller than min-rtp-port %u", ice.max_rtp_port, ice.min_rtp_port);
        },
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const ice: *Ice = @ptrCast(@alignCast(o));
    switch (id) {
        1 => c.g_value_set_uint(v, ice.min_rtp_port),
        2 => c.g_value_set_uint(v, ice.max_rtp_port),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const flags = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_uint("min-rtp-port", "ICE RTP candidate min port", "Minimum port for local rtp port range. min-rtp-port must be <= max-rtp-port", 0, 65535, 0, flags));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_uint("max-rtp-port", "ICE RTP candidate max port", "Maximum port for local rtp port range. max-rtp-port must be >= min-rtp-port", 0, 65535, 65535, flags));
    _ = c.g_signal_new_class_handler("add-local-ip-address", gc.g_type_class.g_type, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, null, null, null, c.g_cclosure_marshal_generic, c.G_TYPE_BOOLEAN, 1, c.G_TYPE_STRING);
}

pub export fn gst_webrtc_ice_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstWebRTCICE", Class, Ice, classInit, null, c.G_TYPE_FLAG_ABSTRACT);
            common.category("webrtcice");
            return t;
        }
    }.f);
}
