const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

var gst_webrtc_ice_tcp_candidate_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ICE_TCP_CANDIDATE_TYPE_ACTIVE", .value_nick = "active" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ICE_TCP_CANDIDATE_TYPE_PASSIVE", .value_nick = "passive" },
    .{ .value = 2, .value_name = "GST_WEBRTC_ICE_TCP_CANDIDATE_TYPE_SO", .value_nick = "so" },
    .{ .value = 3, .value_name = "GST_WEBRTC_ICE_TCP_CANDIDATE_TYPE_NONE", .value_nick = "none" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_ice_tcp_candidate_type_once: gtype.Once = .{};
fn gst_webrtc_ice_tcp_candidate_type_register() c.GType {
    return c.g_enum_register_static("GstWebRTCICETcpCandidateType", &gst_webrtc_ice_tcp_candidate_type_values);
}
pub export fn gst_webrtc_ice_tcp_candidate_type_get_type() c.GType {
    return gst_webrtc_ice_tcp_candidate_type_once.get(gst_webrtc_ice_tcp_candidate_type_register);
}

var gst_webrtc_ice_candidate_protocol_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ICE_CANDIDATE_PROTOCOL_TYPE_TCP", .value_nick = "tcp" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ICE_CANDIDATE_PROTOCOL_TYPE_UDP", .value_nick = "udp" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_ice_candidate_protocol_type_once: gtype.Once = .{};
fn gst_webrtc_ice_candidate_protocol_type_register() c.GType {
    return c.g_enum_register_static("GstWebRTCICECandidateProtocolType", &gst_webrtc_ice_candidate_protocol_type_values);
}
pub export fn gst_webrtc_ice_candidate_protocol_type_get_type() c.GType {
    return gst_webrtc_ice_candidate_protocol_type_once.get(gst_webrtc_ice_candidate_protocol_type_register);
}

var gst_webrtc_ice_candidate_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ICE_CANDIDATE_TYPE_HOST", .value_nick = "host" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ICE_CANDIDATE_TYPE_SERVER_REFLEXIVE", .value_nick = "server-reflexive" },
    .{ .value = 2, .value_name = "GST_WEBRTC_ICE_CANDIDATE_TYPE_PEER_REFLEXIVE", .value_nick = "peer-reflexive" },
    .{ .value = 3, .value_name = "GST_WEBRTC_ICE_CANDIDATE_TYPE_RELAYED", .value_nick = "relayed" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_ice_candidate_type_once: gtype.Once = .{};
fn gst_webrtc_ice_candidate_type_register() c.GType {
    return c.g_enum_register_static("GstWebRTCICECandidateType", &gst_webrtc_ice_candidate_type_values);
}
pub export fn gst_webrtc_ice_candidate_type_get_type() c.GType {
    return gst_webrtc_ice_candidate_type_once.get(gst_webrtc_ice_candidate_type_register);
}

var gst_webrtc_dtls_transport_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_DTLS_TRANSPORT_STATE_NEW", .value_nick = "new" },
    .{ .value = 1, .value_name = "GST_WEBRTC_DTLS_TRANSPORT_STATE_CLOSED", .value_nick = "closed" },
    .{ .value = 2, .value_name = "GST_WEBRTC_DTLS_TRANSPORT_STATE_FAILED", .value_nick = "failed" },
    .{ .value = 3, .value_name = "GST_WEBRTC_DTLS_TRANSPORT_STATE_CONNECTING", .value_nick = "connecting" },
    .{ .value = 4, .value_name = "GST_WEBRTC_DTLS_TRANSPORT_STATE_CONNECTED", .value_nick = "connected" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_dtls_transport_state_once: gtype.Once = .{};
fn gst_webrtc_dtls_transport_state_register() c.GType {
    return c.g_enum_register_static("GstWebRTCDTLSTransportState", &gst_webrtc_dtls_transport_state_values);
}
pub export fn gst_webrtc_dtls_transport_state_get_type() c.GType {
    return gst_webrtc_dtls_transport_state_once.get(gst_webrtc_dtls_transport_state_register);
}

var gst_webrtc_dtls_role_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_DTLS_ROLE_CLIENT", .value_nick = "client" },
    .{ .value = 1, .value_name = "GST_WEBRTC_DTLS_ROLE_SERVER", .value_nick = "server" },
    .{ .value = 2, .value_name = "GST_WEBRTC_DTLS_ROLE_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_dtls_role_once: gtype.Once = .{};
fn gst_webrtc_dtls_role_register() c.GType {
    return c.g_enum_register_static("GstWebRTCDTLSRole", &gst_webrtc_dtls_role_values);
}
pub export fn gst_webrtc_dtls_role_get_type() c.GType {
    return gst_webrtc_dtls_role_once.get(gst_webrtc_dtls_role_register);
}

var gst_webrtc_ice_gathering_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ICE_GATHERING_STATE_NEW", .value_nick = "new" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ICE_GATHERING_STATE_GATHERING", .value_nick = "gathering" },
    .{ .value = 2, .value_name = "GST_WEBRTC_ICE_GATHERING_STATE_COMPLETE", .value_nick = "complete" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_ice_gathering_state_once: gtype.Once = .{};
fn gst_webrtc_ice_gathering_state_register() c.GType {
    return c.g_enum_register_static("GstWebRTCICEGatheringState", &gst_webrtc_ice_gathering_state_values);
}
pub export fn gst_webrtc_ice_gathering_state_get_type() c.GType {
    return gst_webrtc_ice_gathering_state_once.get(gst_webrtc_ice_gathering_state_register);
}

var gst_webrtc_ice_connection_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ICE_CONNECTION_STATE_NEW", .value_nick = "new" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ICE_CONNECTION_STATE_CHECKING", .value_nick = "checking" },
    .{ .value = 2, .value_name = "GST_WEBRTC_ICE_CONNECTION_STATE_CONNECTED", .value_nick = "connected" },
    .{ .value = 3, .value_name = "GST_WEBRTC_ICE_CONNECTION_STATE_COMPLETED", .value_nick = "completed" },
    .{ .value = 4, .value_name = "GST_WEBRTC_ICE_CONNECTION_STATE_FAILED", .value_nick = "failed" },
    .{ .value = 5, .value_name = "GST_WEBRTC_ICE_CONNECTION_STATE_DISCONNECTED", .value_nick = "disconnected" },
    .{ .value = 6, .value_name = "GST_WEBRTC_ICE_CONNECTION_STATE_CLOSED", .value_nick = "closed" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_ice_connection_state_once: gtype.Once = .{};
fn gst_webrtc_ice_connection_state_register() c.GType {
    return c.g_enum_register_static("GstWebRTCICEConnectionState", &gst_webrtc_ice_connection_state_values);
}
pub export fn gst_webrtc_ice_connection_state_get_type() c.GType {
    return gst_webrtc_ice_connection_state_once.get(gst_webrtc_ice_connection_state_register);
}

var gst_webrtc_signaling_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_SIGNALING_STATE_STABLE", .value_nick = "stable" },
    .{ .value = 1, .value_name = "GST_WEBRTC_SIGNALING_STATE_CLOSED", .value_nick = "closed" },
    .{ .value = 2, .value_name = "GST_WEBRTC_SIGNALING_STATE_HAVE_LOCAL_OFFER", .value_nick = "have-local-offer" },
    .{ .value = 3, .value_name = "GST_WEBRTC_SIGNALING_STATE_HAVE_REMOTE_OFFER", .value_nick = "have-remote-offer" },
    .{ .value = 4, .value_name = "GST_WEBRTC_SIGNALING_STATE_HAVE_LOCAL_PRANSWER", .value_nick = "have-local-pranswer" },
    .{ .value = 5, .value_name = "GST_WEBRTC_SIGNALING_STATE_HAVE_REMOTE_PRANSWER", .value_nick = "have-remote-pranswer" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_signaling_state_once: gtype.Once = .{};
fn gst_webrtc_signaling_state_register() c.GType {
    return c.g_enum_register_static("GstWebRTCSignalingState", &gst_webrtc_signaling_state_values);
}
pub export fn gst_webrtc_signaling_state_get_type() c.GType {
    return gst_webrtc_signaling_state_once.get(gst_webrtc_signaling_state_register);
}

var gst_webrtc_peer_connection_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_PEER_CONNECTION_STATE_NEW", .value_nick = "new" },
    .{ .value = 1, .value_name = "GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTING", .value_nick = "connecting" },
    .{ .value = 2, .value_name = "GST_WEBRTC_PEER_CONNECTION_STATE_CONNECTED", .value_nick = "connected" },
    .{ .value = 3, .value_name = "GST_WEBRTC_PEER_CONNECTION_STATE_DISCONNECTED", .value_nick = "disconnected" },
    .{ .value = 4, .value_name = "GST_WEBRTC_PEER_CONNECTION_STATE_FAILED", .value_nick = "failed" },
    .{ .value = 5, .value_name = "GST_WEBRTC_PEER_CONNECTION_STATE_CLOSED", .value_nick = "closed" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_peer_connection_state_once: gtype.Once = .{};
fn gst_webrtc_peer_connection_state_register() c.GType {
    return c.g_enum_register_static("GstWebRTCPeerConnectionState", &gst_webrtc_peer_connection_state_values);
}
pub export fn gst_webrtc_peer_connection_state_get_type() c.GType {
    return gst_webrtc_peer_connection_state_once.get(gst_webrtc_peer_connection_state_register);
}

var gst_webrtc_ice_role_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ICE_ROLE_CONTROLLED", .value_nick = "controlled" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ICE_ROLE_CONTROLLING", .value_nick = "controlling" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_ice_role_once: gtype.Once = .{};
fn gst_webrtc_ice_role_register() c.GType {
    return c.g_enum_register_static("GstWebRTCICERole", &gst_webrtc_ice_role_values);
}
pub export fn gst_webrtc_ice_role_get_type() c.GType {
    return gst_webrtc_ice_role_once.get(gst_webrtc_ice_role_register);
}

var gst_webrtc_ice_component_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ICE_COMPONENT_RTP", .value_nick = "rtp" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ICE_COMPONENT_RTCP", .value_nick = "rtcp" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_ice_component_once: gtype.Once = .{};
fn gst_webrtc_ice_component_register() c.GType {
    return c.g_enum_register_static("GstWebRTCICEComponent", &gst_webrtc_ice_component_values);
}
pub export fn gst_webrtc_ice_component_get_type() c.GType {
    return gst_webrtc_ice_component_once.get(gst_webrtc_ice_component_register);
}

var gst_webrtc_sdp_type_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_WEBRTC_SDP_TYPE_OFFER", .value_nick = "offer" },
    .{ .value = 2, .value_name = "GST_WEBRTC_SDP_TYPE_PRANSWER", .value_nick = "pranswer" },
    .{ .value = 3, .value_name = "GST_WEBRTC_SDP_TYPE_ANSWER", .value_nick = "answer" },
    .{ .value = 4, .value_name = "GST_WEBRTC_SDP_TYPE_ROLLBACK", .value_nick = "rollback" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_sdp_type_once: gtype.Once = .{};
fn gst_webrtc_sdp_type_register() c.GType {
    return c.g_enum_register_static("GstWebRTCSDPType", &gst_webrtc_sdp_type_values);
}
pub export fn gst_webrtc_sdp_type_get_type() c.GType {
    return gst_webrtc_sdp_type_once.get(gst_webrtc_sdp_type_register);
}

var gst_webrtc_rtp_transceiver_direction_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_INACTIVE", .value_nick = "inactive" },
    .{ .value = 2, .value_name = "GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDONLY", .value_nick = "sendonly" },
    .{ .value = 3, .value_name = "GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_RECVONLY", .value_nick = "recvonly" },
    .{ .value = 4, .value_name = "GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDRECV", .value_nick = "sendrecv" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_rtp_transceiver_direction_once: gtype.Once = .{};
fn gst_webrtc_rtp_transceiver_direction_register() c.GType {
    return c.g_enum_register_static("GstWebRTCRTPTransceiverDirection", &gst_webrtc_rtp_transceiver_direction_values);
}
pub export fn gst_webrtc_rtp_transceiver_direction_get_type() c.GType {
    return gst_webrtc_rtp_transceiver_direction_once.get(gst_webrtc_rtp_transceiver_direction_register);
}

var gst_webrtc_dtls_setup_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_DTLS_SETUP_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_WEBRTC_DTLS_SETUP_ACTPASS", .value_nick = "actpass" },
    .{ .value = 2, .value_name = "GST_WEBRTC_DTLS_SETUP_ACTIVE", .value_nick = "active" },
    .{ .value = 3, .value_name = "GST_WEBRTC_DTLS_SETUP_PASSIVE", .value_nick = "passive" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_dtls_setup_once: gtype.Once = .{};
fn gst_webrtc_dtls_setup_register() c.GType {
    return c.g_enum_register_static("GstWebRTCDTLSSetup", &gst_webrtc_dtls_setup_values);
}
pub export fn gst_webrtc_dtls_setup_get_type() c.GType {
    return gst_webrtc_dtls_setup_once.get(gst_webrtc_dtls_setup_register);
}

var gst_webrtc_stats_type_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_WEBRTC_STATS_CODEC", .value_nick = "codec" },
    .{ .value = 2, .value_name = "GST_WEBRTC_STATS_INBOUND_RTP", .value_nick = "inbound-rtp" },
    .{ .value = 3, .value_name = "GST_WEBRTC_STATS_OUTBOUND_RTP", .value_nick = "outbound-rtp" },
    .{ .value = 4, .value_name = "GST_WEBRTC_STATS_REMOTE_INBOUND_RTP", .value_nick = "remote-inbound-rtp" },
    .{ .value = 5, .value_name = "GST_WEBRTC_STATS_REMOTE_OUTBOUND_RTP", .value_nick = "remote-outbound-rtp" },
    .{ .value = 6, .value_name = "GST_WEBRTC_STATS_CSRC", .value_nick = "csrc" },
    .{ .value = 7, .value_name = "GST_WEBRTC_STATS_PEER_CONNECTION", .value_nick = "peer-connection" },
    .{ .value = 8, .value_name = "GST_WEBRTC_STATS_DATA_CHANNEL", .value_nick = "data-channel" },
    .{ .value = 9, .value_name = "GST_WEBRTC_STATS_STREAM", .value_nick = "stream" },
    .{ .value = 10, .value_name = "GST_WEBRTC_STATS_TRANSPORT", .value_nick = "transport" },
    .{ .value = 11, .value_name = "GST_WEBRTC_STATS_CANDIDATE_PAIR", .value_nick = "candidate-pair" },
    .{ .value = 12, .value_name = "GST_WEBRTC_STATS_LOCAL_CANDIDATE", .value_nick = "local-candidate" },
    .{ .value = 13, .value_name = "GST_WEBRTC_STATS_REMOTE_CANDIDATE", .value_nick = "remote-candidate" },
    .{ .value = 14, .value_name = "GST_WEBRTC_STATS_CERTIFICATE", .value_nick = "certificate" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_stats_type_once: gtype.Once = .{};
fn gst_webrtc_stats_type_register() c.GType {
    return c.g_enum_register_static("GstWebRTCStatsType", &gst_webrtc_stats_type_values);
}
pub export fn gst_webrtc_stats_type_get_type() c.GType {
    return gst_webrtc_stats_type_once.get(gst_webrtc_stats_type_register);
}

var gst_webrtc_fec_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_FEC_TYPE_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_WEBRTC_FEC_TYPE_ULP_RED", .value_nick = "ulp-red" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_fec_type_once: gtype.Once = .{};
fn gst_webrtc_fec_type_register() c.GType {
    return c.g_enum_register_static("GstWebRTCFECType", &gst_webrtc_fec_type_values);
}
pub export fn gst_webrtc_fec_type_get_type() c.GType {
    return gst_webrtc_fec_type_once.get(gst_webrtc_fec_type_register);
}

var gst_webrtc_sctp_transport_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_SCTP_TRANSPORT_STATE_NEW", .value_nick = "new" },
    .{ .value = 1, .value_name = "GST_WEBRTC_SCTP_TRANSPORT_STATE_CONNECTING", .value_nick = "connecting" },
    .{ .value = 2, .value_name = "GST_WEBRTC_SCTP_TRANSPORT_STATE_CONNECTED", .value_nick = "connected" },
    .{ .value = 3, .value_name = "GST_WEBRTC_SCTP_TRANSPORT_STATE_CLOSED", .value_nick = "closed" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_sctp_transport_state_once: gtype.Once = .{};
fn gst_webrtc_sctp_transport_state_register() c.GType {
    return c.g_enum_register_static("GstWebRTCSCTPTransportState", &gst_webrtc_sctp_transport_state_values);
}
pub export fn gst_webrtc_sctp_transport_state_get_type() c.GType {
    return gst_webrtc_sctp_transport_state_once.get(gst_webrtc_sctp_transport_state_register);
}

var gst_webrtc_priority_type_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_WEBRTC_PRIORITY_TYPE_VERY_LOW", .value_nick = "very-low" },
    .{ .value = 2, .value_name = "GST_WEBRTC_PRIORITY_TYPE_LOW", .value_nick = "low" },
    .{ .value = 3, .value_name = "GST_WEBRTC_PRIORITY_TYPE_MEDIUM", .value_nick = "medium" },
    .{ .value = 4, .value_name = "GST_WEBRTC_PRIORITY_TYPE_HIGH", .value_nick = "high" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_priority_type_once: gtype.Once = .{};
fn gst_webrtc_priority_type_register() c.GType {
    return c.g_enum_register_static("GstWebRTCPriorityType", &gst_webrtc_priority_type_values);
}
pub export fn gst_webrtc_priority_type_get_type() c.GType {
    return gst_webrtc_priority_type_once.get(gst_webrtc_priority_type_register);
}

var gst_webrtc_data_channel_state_values = [_]c.GEnumValue{
    .{ .value = 1, .value_name = "GST_WEBRTC_DATA_CHANNEL_STATE_CONNECTING", .value_nick = "connecting" },
    .{ .value = 2, .value_name = "GST_WEBRTC_DATA_CHANNEL_STATE_OPEN", .value_nick = "open" },
    .{ .value = 3, .value_name = "GST_WEBRTC_DATA_CHANNEL_STATE_CLOSING", .value_nick = "closing" },
    .{ .value = 4, .value_name = "GST_WEBRTC_DATA_CHANNEL_STATE_CLOSED", .value_nick = "closed" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_data_channel_state_once: gtype.Once = .{};
fn gst_webrtc_data_channel_state_register() c.GType {
    return c.g_enum_register_static("GstWebRTCDataChannelState", &gst_webrtc_data_channel_state_values);
}
pub export fn gst_webrtc_data_channel_state_get_type() c.GType {
    return gst_webrtc_data_channel_state_once.get(gst_webrtc_data_channel_state_register);
}

var gst_webrtc_bundle_policy_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_BUNDLE_POLICY_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_WEBRTC_BUNDLE_POLICY_BALANCED", .value_nick = "balanced" },
    .{ .value = 2, .value_name = "GST_WEBRTC_BUNDLE_POLICY_MAX_COMPAT", .value_nick = "max-compat" },
    .{ .value = 3, .value_name = "GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE", .value_nick = "max-bundle" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_bundle_policy_once: gtype.Once = .{};
fn gst_webrtc_bundle_policy_register() c.GType {
    return c.g_enum_register_static("GstWebRTCBundlePolicy", &gst_webrtc_bundle_policy_values);
}
pub export fn gst_webrtc_bundle_policy_get_type() c.GType {
    return gst_webrtc_bundle_policy_once.get(gst_webrtc_bundle_policy_register);
}

var gst_webrtc_ice_transport_policy_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ICE_TRANSPORT_POLICY_ALL", .value_nick = "all" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ICE_TRANSPORT_POLICY_RELAY", .value_nick = "relay" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_ice_transport_policy_once: gtype.Once = .{};
fn gst_webrtc_ice_transport_policy_register() c.GType {
    return c.g_enum_register_static("GstWebRTCICETransportPolicy", &gst_webrtc_ice_transport_policy_values);
}
pub export fn gst_webrtc_ice_transport_policy_get_type() c.GType {
    return gst_webrtc_ice_transport_policy_once.get(gst_webrtc_ice_transport_policy_register);
}

var gst_webrtc_kind_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_KIND_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_WEBRTC_KIND_AUDIO", .value_nick = "audio" },
    .{ .value = 2, .value_name = "GST_WEBRTC_KIND_VIDEO", .value_nick = "video" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_kind_once: gtype.Once = .{};
fn gst_webrtc_kind_register() c.GType {
    return c.g_enum_register_static("GstWebRTCKind", &gst_webrtc_kind_values);
}
pub export fn gst_webrtc_kind_get_type() c.GType {
    return gst_webrtc_kind_once.get(gst_webrtc_kind_register);
}

var gst_webrtc_error_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_WEBRTC_ERROR_DATA_CHANNEL_FAILURE", .value_nick = "data-channel-failure" },
    .{ .value = 1, .value_name = "GST_WEBRTC_ERROR_DTLS_FAILURE", .value_nick = "dtls-failure" },
    .{ .value = 2, .value_name = "GST_WEBRTC_ERROR_FINGERPRINT_FAILURE", .value_nick = "fingerprint-failure" },
    .{ .value = 3, .value_name = "GST_WEBRTC_ERROR_SCTP_FAILURE", .value_nick = "sctp-failure" },
    .{ .value = 4, .value_name = "GST_WEBRTC_ERROR_SDP_SYNTAX_ERROR", .value_nick = "sdp-syntax-error" },
    .{ .value = 5, .value_name = "GST_WEBRTC_ERROR_HARDWARE_ENCODER_NOT_AVAILABLE", .value_nick = "hardware-encoder-not-available" },
    .{ .value = 6, .value_name = "GST_WEBRTC_ERROR_ENCODER_ERROR", .value_nick = "encoder-error" },
    .{ .value = 7, .value_name = "GST_WEBRTC_ERROR_INVALID_STATE", .value_nick = "invalid-state" },
    .{ .value = 8, .value_name = "GST_WEBRTC_ERROR_INTERNAL_FAILURE", .value_nick = "internal-failure" },
    .{ .value = 9, .value_name = "GST_WEBRTC_ERROR_INVALID_MODIFICATION", .value_nick = "invalid-modification" },
    .{ .value = 10, .value_name = "GST_WEBRTC_ERROR_TYPE_ERROR", .value_nick = "type-error" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_webrtc_error_once: gtype.Once = .{};
fn gst_webrtc_error_register() c.GType {
    return c.g_enum_register_static("GstWebRTCError", &gst_webrtc_error_values);
}
pub export fn gst_webrtc_error_get_type() c.GType {
    return gst_webrtc_error_once.get(gst_webrtc_error_register);
}
