const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

var gst_rtcp_type_once: gtype.Once = .{};

pub export fn gst_rtcp_type_get_type() c.GType {
    return gst_rtcp_type_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTCP_TYPE_INVALID), .value_name = "GST_RTCP_TYPE_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTCP_TYPE_SR), .value_name = "GST_RTCP_TYPE_SR", .value_nick = "sr" },
            .{ .value = @intCast(c.GST_RTCP_TYPE_RR), .value_name = "GST_RTCP_TYPE_RR", .value_nick = "rr" },
            .{ .value = @intCast(c.GST_RTCP_TYPE_SDES), .value_name = "GST_RTCP_TYPE_SDES", .value_nick = "sdes" },
            .{ .value = @intCast(c.GST_RTCP_TYPE_BYE), .value_name = "GST_RTCP_TYPE_BYE", .value_nick = "bye" },
            .{ .value = @intCast(c.GST_RTCP_TYPE_APP), .value_name = "GST_RTCP_TYPE_APP", .value_nick = "app" },
            .{ .value = @intCast(c.GST_RTCP_TYPE_RTPFB), .value_name = "GST_RTCP_TYPE_RTPFB", .value_nick = "rtpfb" },
            .{ .value = @intCast(c.GST_RTCP_TYPE_PSFB), .value_name = "GST_RTCP_TYPE_PSFB", .value_nick = "psfb" },
            .{ .value = @intCast(c.GST_RTCP_TYPE_XR), .value_name = "GST_RTCP_TYPE_XR", .value_nick = "xr" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTCPType"), &values);
        }
    }.f);
}

var gst_rtcpfb_type_once: gtype.Once = .{};

pub export fn gst_rtcpfb_type_get_type() c.GType {
    return gst_rtcpfb_type_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTCP_FB_TYPE_INVALID), .value_name = "GST_RTCP_FB_TYPE_INVALID", .value_nick = "fb-type-invalid" },
            .{ .value = @intCast(c.GST_RTCP_RTPFB_TYPE_NACK), .value_name = "GST_RTCP_RTPFB_TYPE_NACK", .value_nick = "rtpfb-type-nack" },
            .{ .value = @intCast(c.GST_RTCP_RTPFB_TYPE_TMMBR), .value_name = "GST_RTCP_RTPFB_TYPE_TMMBR", .value_nick = "rtpfb-type-tmmbr" },
            .{ .value = @intCast(c.GST_RTCP_RTPFB_TYPE_TMMBN), .value_name = "GST_RTCP_RTPFB_TYPE_TMMBN", .value_nick = "rtpfb-type-tmmbn" },
            .{ .value = @intCast(c.GST_RTCP_RTPFB_TYPE_RTCP_SR_REQ), .value_name = "GST_RTCP_RTPFB_TYPE_RTCP_SR_REQ", .value_nick = "rtpfb-type-rtcp-sr-req" },
            .{ .value = @intCast(c.GST_RTCP_RTPFB_TYPE_TWCC), .value_name = "GST_RTCP_RTPFB_TYPE_TWCC", .value_nick = "rtpfb-type-twcc" },
            .{ .value = @intCast(c.GST_RTCP_PSFB_TYPE_PLI), .value_name = "GST_RTCP_PSFB_TYPE_PLI", .value_nick = "psfb-type-pli" },
            .{ .value = @intCast(c.GST_RTCP_PSFB_TYPE_SLI), .value_name = "GST_RTCP_PSFB_TYPE_SLI", .value_nick = "psfb-type-sli" },
            .{ .value = @intCast(c.GST_RTCP_PSFB_TYPE_RPSI), .value_name = "GST_RTCP_PSFB_TYPE_RPSI", .value_nick = "psfb-type-rpsi" },
            .{ .value = @intCast(c.GST_RTCP_PSFB_TYPE_AFB), .value_name = "GST_RTCP_PSFB_TYPE_AFB", .value_nick = "psfb-type-afb" },
            .{ .value = @intCast(c.GST_RTCP_PSFB_TYPE_FIR), .value_name = "GST_RTCP_PSFB_TYPE_FIR", .value_nick = "psfb-type-fir" },
            .{ .value = @intCast(c.GST_RTCP_PSFB_TYPE_TSTR), .value_name = "GST_RTCP_PSFB_TYPE_TSTR", .value_nick = "psfb-type-tstr" },
            .{ .value = @intCast(c.GST_RTCP_PSFB_TYPE_TSTN), .value_name = "GST_RTCP_PSFB_TYPE_TSTN", .value_nick = "psfb-type-tstn" },
            .{ .value = @intCast(c.GST_RTCP_PSFB_TYPE_VBCN), .value_name = "GST_RTCP_PSFB_TYPE_VBCN", .value_nick = "psfb-type-vbcn" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTCPFBType"), &values);
        }
    }.f);
}

var gst_rtcpsdes_type_once: gtype.Once = .{};

pub export fn gst_rtcpsdes_type_get_type() c.GType {
    return gst_rtcpsdes_type_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTCP_SDES_INVALID), .value_name = "GST_RTCP_SDES_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTCP_SDES_END), .value_name = "GST_RTCP_SDES_END", .value_nick = "end" },
            .{ .value = @intCast(c.GST_RTCP_SDES_CNAME), .value_name = "GST_RTCP_SDES_CNAME", .value_nick = "cname" },
            .{ .value = @intCast(c.GST_RTCP_SDES_NAME), .value_name = "GST_RTCP_SDES_NAME", .value_nick = "name" },
            .{ .value = @intCast(c.GST_RTCP_SDES_EMAIL), .value_name = "GST_RTCP_SDES_EMAIL", .value_nick = "email" },
            .{ .value = @intCast(c.GST_RTCP_SDES_PHONE), .value_name = "GST_RTCP_SDES_PHONE", .value_nick = "phone" },
            .{ .value = @intCast(c.GST_RTCP_SDES_LOC), .value_name = "GST_RTCP_SDES_LOC", .value_nick = "loc" },
            .{ .value = @intCast(c.GST_RTCP_SDES_TOOL), .value_name = "GST_RTCP_SDES_TOOL", .value_nick = "tool" },
            .{ .value = @intCast(c.GST_RTCP_SDES_NOTE), .value_name = "GST_RTCP_SDES_NOTE", .value_nick = "note" },
            .{ .value = @intCast(c.GST_RTCP_SDES_PRIV), .value_name = "GST_RTCP_SDES_PRIV", .value_nick = "priv" },
            .{ .value = @intCast(c.GST_RTCP_SDES_H323_CADDR), .value_name = "GST_RTCP_SDES_H323_CADDR", .value_nick = "h323-caddr" },
            .{ .value = @intCast(c.GST_RTCP_SDES_APSI), .value_name = "GST_RTCP_SDES_APSI", .value_nick = "apsi" },
            .{ .value = @intCast(c.GST_RTCP_SDES_RGRP), .value_name = "GST_RTCP_SDES_RGRP", .value_nick = "rgrp" },
            .{ .value = @intCast(c.GST_RTCP_SDES_RTP_STREAM_ID), .value_name = "GST_RTCP_SDES_RTP_STREAM_ID", .value_nick = "rtp-stream-id" },
            .{ .value = @intCast(c.GST_RTCP_SDES_REPAIRED_RTP_STREAM_ID), .value_name = "GST_RTCP_SDES_REPAIRED_RTP_STREAM_ID", .value_nick = "repaired-rtp-stream-id" },
            .{ .value = @intCast(c.GST_RTCP_SDES_CCID), .value_name = "GST_RTCP_SDES_CCID", .value_nick = "ccid" },
            .{ .value = @intCast(c.GST_RTCP_SDES_MID), .value_name = "GST_RTCP_SDES_MID", .value_nick = "mid" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTCPSDESType"), &values);
        }
    }.f);
}

var gst_rtcpxr_type_once: gtype.Once = .{};

pub export fn gst_rtcpxr_type_get_type() c.GType {
    return gst_rtcpxr_type_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTCP_XR_TYPE_INVALID), .value_name = "GST_RTCP_XR_TYPE_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTCP_XR_TYPE_LRLE), .value_name = "GST_RTCP_XR_TYPE_LRLE", .value_nick = "lrle" },
            .{ .value = @intCast(c.GST_RTCP_XR_TYPE_DRLE), .value_name = "GST_RTCP_XR_TYPE_DRLE", .value_nick = "drle" },
            .{ .value = @intCast(c.GST_RTCP_XR_TYPE_PRT), .value_name = "GST_RTCP_XR_TYPE_PRT", .value_nick = "prt" },
            .{ .value = @intCast(c.GST_RTCP_XR_TYPE_RRT), .value_name = "GST_RTCP_XR_TYPE_RRT", .value_nick = "rrt" },
            .{ .value = @intCast(c.GST_RTCP_XR_TYPE_DLRR), .value_name = "GST_RTCP_XR_TYPE_DLRR", .value_nick = "dlrr" },
            .{ .value = @intCast(c.GST_RTCP_XR_TYPE_SSUMM), .value_name = "GST_RTCP_XR_TYPE_SSUMM", .value_nick = "ssumm" },
            .{ .value = @intCast(c.GST_RTCP_XR_TYPE_VOIP_METRICS), .value_name = "GST_RTCP_XR_TYPE_VOIP_METRICS", .value_nick = "voip-metrics" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTCPXRType"), &values);
        }
    }.f);
}

var gst_rtp_buffer_flags_once: gtype.Once = .{};

pub export fn gst_rtp_buffer_flags_get_type() c.GType {
    return gst_rtp_buffer_flags_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTP_BUFFER_FLAG_RETRANSMISSION), .value_name = "GST_RTP_BUFFER_FLAG_RETRANSMISSION", .value_nick = "retransmission" },
            .{ .value = @intCast(c.GST_RTP_BUFFER_FLAG_REDUNDANT), .value_name = "GST_RTP_BUFFER_FLAG_REDUNDANT", .value_nick = "redundant" },
            .{ .value = @intCast(c.GST_RTP_BUFFER_FLAG_LAST), .value_name = "GST_RTP_BUFFER_FLAG_LAST", .value_nick = "last" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTPBufferFlags"), &values);
        }
    }.f);
}

var gst_rtp_buffer_map_flags_once: gtype.Once = .{};

pub export fn gst_rtp_buffer_map_flags_get_type() c.GType {
    return gst_rtp_buffer_map_flags_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTP_BUFFER_MAP_FLAG_SKIP_PADDING), .value_name = "GST_RTP_BUFFER_MAP_FLAG_SKIP_PADDING", .value_nick = "skip-padding" },
            .{ .value = @intCast(c.GST_RTP_BUFFER_MAP_FLAG_LAST), .value_name = "GST_RTP_BUFFER_MAP_FLAG_LAST", .value_nick = "last" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTPBufferMapFlags"), &values);
        }
    }.f);
}

var gst_rtp_profile_once: gtype.Once = .{};

pub export fn gst_rtp_profile_get_type() c.GType {
    return gst_rtp_profile_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTP_PROFILE_UNKNOWN), .value_name = "GST_RTP_PROFILE_UNKNOWN", .value_nick = "unknown" },
            .{ .value = @intCast(c.GST_RTP_PROFILE_AVP), .value_name = "GST_RTP_PROFILE_AVP", .value_nick = "avp" },
            .{ .value = @intCast(c.GST_RTP_PROFILE_SAVP), .value_name = "GST_RTP_PROFILE_SAVP", .value_nick = "savp" },
            .{ .value = @intCast(c.GST_RTP_PROFILE_AVPF), .value_name = "GST_RTP_PROFILE_AVPF", .value_nick = "avpf" },
            .{ .value = @intCast(c.GST_RTP_PROFILE_SAVPF), .value_name = "GST_RTP_PROFILE_SAVPF", .value_nick = "savpf" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTPProfile"), &values);
        }
    }.f);
}

var gst_rtp_header_extension_flags_once: gtype.Once = .{};

pub export fn gst_rtp_header_extension_flags_get_type() c.GType {
    return gst_rtp_header_extension_flags_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTP_HEADER_EXTENSION_ONE_BYTE), .value_name = "GST_RTP_HEADER_EXTENSION_ONE_BYTE", .value_nick = "one-byte" },
            .{ .value = @intCast(c.GST_RTP_HEADER_EXTENSION_TWO_BYTE), .value_name = "GST_RTP_HEADER_EXTENSION_TWO_BYTE", .value_nick = "two-byte" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTPHeaderExtensionFlags"), &values);
        }
    }.f);
}

var gst_rtp_header_extension_direction_once: gtype.Once = .{};

pub export fn gst_rtp_header_extension_direction_get_type() c.GType {
    return gst_rtp_header_extension_direction_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTP_HEADER_EXTENSION_DIRECTION_INACTIVE), .value_name = "GST_RTP_HEADER_EXTENSION_DIRECTION_INACTIVE", .value_nick = "inactive" },
            .{ .value = @intCast(c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDONLY), .value_name = "GST_RTP_HEADER_EXTENSION_DIRECTION_SENDONLY", .value_nick = "sendonly" },
            .{ .value = @intCast(c.GST_RTP_HEADER_EXTENSION_DIRECTION_RECVONLY), .value_name = "GST_RTP_HEADER_EXTENSION_DIRECTION_RECVONLY", .value_nick = "recvonly" },
            .{ .value = @intCast(c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDRECV), .value_name = "GST_RTP_HEADER_EXTENSION_DIRECTION_SENDRECV", .value_nick = "sendrecv" },
            .{ .value = @intCast(c.GST_RTP_HEADER_EXTENSION_DIRECTION_INHERITED), .value_name = "GST_RTP_HEADER_EXTENSION_DIRECTION_INHERITED", .value_nick = "inherited" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTPHeaderExtensionDirection"), &values);
        }
    }.f);
}

var gst_rtp_payload_once: gtype.Once = .{};

pub export fn gst_rtp_payload_get_type() c.GType {
    return gst_rtp_payload_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_PCMU), .value_name = "GST_RTP_PAYLOAD_PCMU", .value_nick = "pcmu" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_1016), .value_name = "GST_RTP_PAYLOAD_1016", .value_nick = "1016" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_G721), .value_name = "GST_RTP_PAYLOAD_G721", .value_nick = "g721" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_GSM), .value_name = "GST_RTP_PAYLOAD_GSM", .value_nick = "gsm" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_G723), .value_name = "GST_RTP_PAYLOAD_G723", .value_nick = "g723" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_DVI4_8000), .value_name = "GST_RTP_PAYLOAD_DVI4_8000", .value_nick = "dvi4-8000" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_DVI4_16000), .value_name = "GST_RTP_PAYLOAD_DVI4_16000", .value_nick = "dvi4-16000" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_LPC), .value_name = "GST_RTP_PAYLOAD_LPC", .value_nick = "lpc" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_PCMA), .value_name = "GST_RTP_PAYLOAD_PCMA", .value_nick = "pcma" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_G722), .value_name = "GST_RTP_PAYLOAD_G722", .value_nick = "g722" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_L16_STEREO), .value_name = "GST_RTP_PAYLOAD_L16_STEREO", .value_nick = "l16-stereo" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_L16_MONO), .value_name = "GST_RTP_PAYLOAD_L16_MONO", .value_nick = "l16-mono" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_QCELP), .value_name = "GST_RTP_PAYLOAD_QCELP", .value_nick = "qcelp" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_CN), .value_name = "GST_RTP_PAYLOAD_CN", .value_nick = "cn" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_MPA), .value_name = "GST_RTP_PAYLOAD_MPA", .value_nick = "mpa" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_G728), .value_name = "GST_RTP_PAYLOAD_G728", .value_nick = "g728" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_DVI4_11025), .value_name = "GST_RTP_PAYLOAD_DVI4_11025", .value_nick = "dvi4-11025" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_DVI4_22050), .value_name = "GST_RTP_PAYLOAD_DVI4_22050", .value_nick = "dvi4-22050" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_G729), .value_name = "GST_RTP_PAYLOAD_G729", .value_nick = "g729" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_CELLB), .value_name = "GST_RTP_PAYLOAD_CELLB", .value_nick = "cellb" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_JPEG), .value_name = "GST_RTP_PAYLOAD_JPEG", .value_nick = "jpeg" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_NV), .value_name = "GST_RTP_PAYLOAD_NV", .value_nick = "nv" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_H261), .value_name = "GST_RTP_PAYLOAD_H261", .value_nick = "h261" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_MPV), .value_name = "GST_RTP_PAYLOAD_MPV", .value_nick = "mpv" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_MP2T), .value_name = "GST_RTP_PAYLOAD_MP2T", .value_nick = "mp2t" },
            .{ .value = @intCast(c.GST_RTP_PAYLOAD_H263), .value_name = "GST_RTP_PAYLOAD_H263", .value_nick = "h263" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTPPayload"), &values);
        }
    }.f);
}

