const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

var gst_rtsp_result_once: gtype.Once = .{};

pub export fn gst_rtsp_result_get_type() c.GType {
    return gst_rtsp_result_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_OK), .value_name = "GST_RTSP_OK", .value_nick = "ok" },
            .{ .value = @intCast(c.GST_RTSP_OK_REDIRECT), .value_name = "GST_RTSP_OK_REDIRECT", .value_nick = "ok-redirect" },
            .{ .value = @intCast(c.GST_RTSP_ERROR), .value_name = "GST_RTSP_ERROR", .value_nick = "error" },
            .{ .value = @intCast(c.GST_RTSP_EINVAL), .value_name = "GST_RTSP_EINVAL", .value_nick = "einval" },
            .{ .value = @intCast(c.GST_RTSP_EINTR), .value_name = "GST_RTSP_EINTR", .value_nick = "eintr" },
            .{ .value = @intCast(c.GST_RTSP_ENOMEM), .value_name = "GST_RTSP_ENOMEM", .value_nick = "enomem" },
            .{ .value = @intCast(c.GST_RTSP_ERESOLV), .value_name = "GST_RTSP_ERESOLV", .value_nick = "eresolv" },
            .{ .value = @intCast(c.GST_RTSP_ENOTIMPL), .value_name = "GST_RTSP_ENOTIMPL", .value_nick = "enotimpl" },
            .{ .value = @intCast(c.GST_RTSP_ESYS), .value_name = "GST_RTSP_ESYS", .value_nick = "esys" },
            .{ .value = @intCast(c.GST_RTSP_EPARSE), .value_name = "GST_RTSP_EPARSE", .value_nick = "eparse" },
            .{ .value = @intCast(c.GST_RTSP_EWSASTART), .value_name = "GST_RTSP_EWSASTART", .value_nick = "ewsastart" },
            .{ .value = @intCast(c.GST_RTSP_EWSAVERSION), .value_name = "GST_RTSP_EWSAVERSION", .value_nick = "ewsaversion" },
            .{ .value = @intCast(c.GST_RTSP_EEOF), .value_name = "GST_RTSP_EEOF", .value_nick = "eeof" },
            .{ .value = @intCast(c.GST_RTSP_ENET), .value_name = "GST_RTSP_ENET", .value_nick = "enet" },
            .{ .value = @intCast(c.GST_RTSP_ENOTIP), .value_name = "GST_RTSP_ENOTIP", .value_nick = "enotip" },
            .{ .value = @intCast(c.GST_RTSP_ETIMEOUT), .value_name = "GST_RTSP_ETIMEOUT", .value_nick = "etimeout" },
            .{ .value = @intCast(c.GST_RTSP_ETGET), .value_name = "GST_RTSP_ETGET", .value_nick = "etget" },
            .{ .value = @intCast(c.GST_RTSP_ETPOST), .value_name = "GST_RTSP_ETPOST", .value_nick = "etpost" },
            .{ .value = @intCast(c.GST_RTSP_ELAST), .value_name = "GST_RTSP_ELAST", .value_nick = "elast" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPResult"), &values);
        }
    }.f);
}

var gst_rtsp_event_once: gtype.Once = .{};

pub export fn gst_rtsp_event_get_type() c.GType {
    return gst_rtsp_event_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTSP_EV_READ), .value_name = "GST_RTSP_EV_READ", .value_nick = "read" },
            .{ .value = @intCast(c.GST_RTSP_EV_WRITE), .value_name = "GST_RTSP_EV_WRITE", .value_nick = "write" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTSPEvent"), &values);
        }
    }.f);
}

var gst_rtsp_family_once: gtype.Once = .{};

pub export fn gst_rtsp_family_get_type() c.GType {
    return gst_rtsp_family_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_FAM_NONE), .value_name = "GST_RTSP_FAM_NONE", .value_nick = "none" },
            .{ .value = @intCast(c.GST_RTSP_FAM_INET), .value_name = "GST_RTSP_FAM_INET", .value_nick = "inet" },
            .{ .value = @intCast(c.GST_RTSP_FAM_INET6), .value_name = "GST_RTSP_FAM_INET6", .value_nick = "inet6" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPFamily"), &values);
        }
    }.f);
}

var gst_rtsp_state_once: gtype.Once = .{};

pub export fn gst_rtsp_state_get_type() c.GType {
    return gst_rtsp_state_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_STATE_INVALID), .value_name = "GST_RTSP_STATE_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTSP_STATE_INIT), .value_name = "GST_RTSP_STATE_INIT", .value_nick = "init" },
            .{ .value = @intCast(c.GST_RTSP_STATE_READY), .value_name = "GST_RTSP_STATE_READY", .value_nick = "ready" },
            .{ .value = @intCast(c.GST_RTSP_STATE_SEEKING), .value_name = "GST_RTSP_STATE_SEEKING", .value_nick = "seeking" },
            .{ .value = @intCast(c.GST_RTSP_STATE_PLAYING), .value_name = "GST_RTSP_STATE_PLAYING", .value_nick = "playing" },
            .{ .value = @intCast(c.GST_RTSP_STATE_RECORDING), .value_name = "GST_RTSP_STATE_RECORDING", .value_nick = "recording" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPState"), &values);
        }
    }.f);
}

var gst_rtsp_version_once: gtype.Once = .{};

pub export fn gst_rtsp_version_get_type() c.GType {
    return gst_rtsp_version_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_VERSION_INVALID), .value_name = "GST_RTSP_VERSION_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTSP_VERSION_1_0), .value_name = "GST_RTSP_VERSION_1_0", .value_nick = "1-0" },
            .{ .value = @intCast(c.GST_RTSP_VERSION_1_1), .value_name = "GST_RTSP_VERSION_1_1", .value_nick = "1-1" },
            .{ .value = @intCast(c.GST_RTSP_VERSION_2_0), .value_name = "GST_RTSP_VERSION_2_0", .value_nick = "2-0" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPVersion"), &values);
        }
    }.f);
}

var gst_rtsp_method_once: gtype.Once = .{};

pub export fn gst_rtsp_method_get_type() c.GType {
    return gst_rtsp_method_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTSP_INVALID), .value_name = "GST_RTSP_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTSP_DESCRIBE), .value_name = "GST_RTSP_DESCRIBE", .value_nick = "describe" },
            .{ .value = @intCast(c.GST_RTSP_ANNOUNCE), .value_name = "GST_RTSP_ANNOUNCE", .value_nick = "announce" },
            .{ .value = @intCast(c.GST_RTSP_GET_PARAMETER), .value_name = "GST_RTSP_GET_PARAMETER", .value_nick = "get-parameter" },
            .{ .value = @intCast(c.GST_RTSP_OPTIONS), .value_name = "GST_RTSP_OPTIONS", .value_nick = "options" },
            .{ .value = @intCast(c.GST_RTSP_PAUSE), .value_name = "GST_RTSP_PAUSE", .value_nick = "pause" },
            .{ .value = @intCast(c.GST_RTSP_PLAY), .value_name = "GST_RTSP_PLAY", .value_nick = "play" },
            .{ .value = @intCast(c.GST_RTSP_RECORD), .value_name = "GST_RTSP_RECORD", .value_nick = "record" },
            .{ .value = @intCast(c.GST_RTSP_REDIRECT), .value_name = "GST_RTSP_REDIRECT", .value_nick = "redirect" },
            .{ .value = @intCast(c.GST_RTSP_SETUP), .value_name = "GST_RTSP_SETUP", .value_nick = "setup" },
            .{ .value = @intCast(c.GST_RTSP_SET_PARAMETER), .value_name = "GST_RTSP_SET_PARAMETER", .value_nick = "set-parameter" },
            .{ .value = @intCast(c.GST_RTSP_TEARDOWN), .value_name = "GST_RTSP_TEARDOWN", .value_nick = "teardown" },
            .{ .value = @intCast(c.GST_RTSP_GET), .value_name = "GST_RTSP_GET", .value_nick = "get" },
            .{ .value = @intCast(c.GST_RTSP_POST), .value_name = "GST_RTSP_POST", .value_nick = "post" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTSPMethod"), &values);
        }
    }.f);
}

var gst_rtsp_auth_method_once: gtype.Once = .{};

pub export fn gst_rtsp_auth_method_get_type() c.GType {
    return gst_rtsp_auth_method_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_AUTH_NONE), .value_name = "GST_RTSP_AUTH_NONE", .value_nick = "none" },
            .{ .value = @intCast(c.GST_RTSP_AUTH_BASIC), .value_name = "GST_RTSP_AUTH_BASIC", .value_nick = "basic" },
            .{ .value = @intCast(c.GST_RTSP_AUTH_DIGEST), .value_name = "GST_RTSP_AUTH_DIGEST", .value_nick = "digest" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPAuthMethod"), &values);
        }
    }.f);
}

var gst_rtsp_header_field_once: gtype.Once = .{};

pub export fn gst_rtsp_header_field_get_type() c.GType {
    return gst_rtsp_header_field_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_HDR_INVALID), .value_name = "GST_RTSP_HDR_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTSP_HDR_ACCEPT), .value_name = "GST_RTSP_HDR_ACCEPT", .value_nick = "accept" },
            .{ .value = @intCast(c.GST_RTSP_HDR_ACCEPT_ENCODING), .value_name = "GST_RTSP_HDR_ACCEPT_ENCODING", .value_nick = "accept-encoding" },
            .{ .value = @intCast(c.GST_RTSP_HDR_ACCEPT_LANGUAGE), .value_name = "GST_RTSP_HDR_ACCEPT_LANGUAGE", .value_nick = "accept-language" },
            .{ .value = @intCast(c.GST_RTSP_HDR_ALLOW), .value_name = "GST_RTSP_HDR_ALLOW", .value_nick = "allow" },
            .{ .value = @intCast(c.GST_RTSP_HDR_AUTHORIZATION), .value_name = "GST_RTSP_HDR_AUTHORIZATION", .value_nick = "authorization" },
            .{ .value = @intCast(c.GST_RTSP_HDR_BANDWIDTH), .value_name = "GST_RTSP_HDR_BANDWIDTH", .value_nick = "bandwidth" },
            .{ .value = @intCast(c.GST_RTSP_HDR_BLOCKSIZE), .value_name = "GST_RTSP_HDR_BLOCKSIZE", .value_nick = "blocksize" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CACHE_CONTROL), .value_name = "GST_RTSP_HDR_CACHE_CONTROL", .value_nick = "cache-control" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CONFERENCE), .value_name = "GST_RTSP_HDR_CONFERENCE", .value_nick = "conference" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CONNECTION), .value_name = "GST_RTSP_HDR_CONNECTION", .value_nick = "connection" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CONTENT_BASE), .value_name = "GST_RTSP_HDR_CONTENT_BASE", .value_nick = "content-base" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CONTENT_ENCODING), .value_name = "GST_RTSP_HDR_CONTENT_ENCODING", .value_nick = "content-encoding" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CONTENT_LANGUAGE), .value_name = "GST_RTSP_HDR_CONTENT_LANGUAGE", .value_nick = "content-language" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CONTENT_LENGTH), .value_name = "GST_RTSP_HDR_CONTENT_LENGTH", .value_nick = "content-length" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CONTENT_LOCATION), .value_name = "GST_RTSP_HDR_CONTENT_LOCATION", .value_nick = "content-location" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CONTENT_TYPE), .value_name = "GST_RTSP_HDR_CONTENT_TYPE", .value_nick = "content-type" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CSEQ), .value_name = "GST_RTSP_HDR_CSEQ", .value_nick = "cseq" },
            .{ .value = @intCast(c.GST_RTSP_HDR_DATE), .value_name = "GST_RTSP_HDR_DATE", .value_nick = "date" },
            .{ .value = @intCast(c.GST_RTSP_HDR_EXPIRES), .value_name = "GST_RTSP_HDR_EXPIRES", .value_nick = "expires" },
            .{ .value = @intCast(c.GST_RTSP_HDR_FROM), .value_name = "GST_RTSP_HDR_FROM", .value_nick = "from" },
            .{ .value = @intCast(c.GST_RTSP_HDR_IF_MODIFIED_SINCE), .value_name = "GST_RTSP_HDR_IF_MODIFIED_SINCE", .value_nick = "if-modified-since" },
            .{ .value = @intCast(c.GST_RTSP_HDR_LAST_MODIFIED), .value_name = "GST_RTSP_HDR_LAST_MODIFIED", .value_nick = "last-modified" },
            .{ .value = @intCast(c.GST_RTSP_HDR_PROXY_AUTHENTICATE), .value_name = "GST_RTSP_HDR_PROXY_AUTHENTICATE", .value_nick = "proxy-authenticate" },
            .{ .value = @intCast(c.GST_RTSP_HDR_PROXY_REQUIRE), .value_name = "GST_RTSP_HDR_PROXY_REQUIRE", .value_nick = "proxy-require" },
            .{ .value = @intCast(c.GST_RTSP_HDR_PUBLIC), .value_name = "GST_RTSP_HDR_PUBLIC", .value_nick = "public" },
            .{ .value = @intCast(c.GST_RTSP_HDR_RANGE), .value_name = "GST_RTSP_HDR_RANGE", .value_nick = "range" },
            .{ .value = @intCast(c.GST_RTSP_HDR_REFERER), .value_name = "GST_RTSP_HDR_REFERER", .value_nick = "referer" },
            .{ .value = @intCast(c.GST_RTSP_HDR_REQUIRE), .value_name = "GST_RTSP_HDR_REQUIRE", .value_nick = "require" },
            .{ .value = @intCast(c.GST_RTSP_HDR_RETRY_AFTER), .value_name = "GST_RTSP_HDR_RETRY_AFTER", .value_nick = "retry-after" },
            .{ .value = @intCast(c.GST_RTSP_HDR_RTP_INFO), .value_name = "GST_RTSP_HDR_RTP_INFO", .value_nick = "rtp-info" },
            .{ .value = @intCast(c.GST_RTSP_HDR_SCALE), .value_name = "GST_RTSP_HDR_SCALE", .value_nick = "scale" },
            .{ .value = @intCast(c.GST_RTSP_HDR_SESSION), .value_name = "GST_RTSP_HDR_SESSION", .value_nick = "session" },
            .{ .value = @intCast(c.GST_RTSP_HDR_SERVER), .value_name = "GST_RTSP_HDR_SERVER", .value_nick = "server" },
            .{ .value = @intCast(c.GST_RTSP_HDR_SPEED), .value_name = "GST_RTSP_HDR_SPEED", .value_nick = "speed" },
            .{ .value = @intCast(c.GST_RTSP_HDR_TRANSPORT), .value_name = "GST_RTSP_HDR_TRANSPORT", .value_nick = "transport" },
            .{ .value = @intCast(c.GST_RTSP_HDR_UNSUPPORTED), .value_name = "GST_RTSP_HDR_UNSUPPORTED", .value_nick = "unsupported" },
            .{ .value = @intCast(c.GST_RTSP_HDR_USER_AGENT), .value_name = "GST_RTSP_HDR_USER_AGENT", .value_nick = "user-agent" },
            .{ .value = @intCast(c.GST_RTSP_HDR_VIA), .value_name = "GST_RTSP_HDR_VIA", .value_nick = "via" },
            .{ .value = @intCast(c.GST_RTSP_HDR_WWW_AUTHENTICATE), .value_name = "GST_RTSP_HDR_WWW_AUTHENTICATE", .value_nick = "www-authenticate" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CLIENT_CHALLENGE), .value_name = "GST_RTSP_HDR_CLIENT_CHALLENGE", .value_nick = "client-challenge" },
            .{ .value = @intCast(c.GST_RTSP_HDR_REAL_CHALLENGE1), .value_name = "GST_RTSP_HDR_REAL_CHALLENGE1", .value_nick = "real-challenge1" },
            .{ .value = @intCast(c.GST_RTSP_HDR_REAL_CHALLENGE2), .value_name = "GST_RTSP_HDR_REAL_CHALLENGE2", .value_nick = "real-challenge2" },
            .{ .value = @intCast(c.GST_RTSP_HDR_REAL_CHALLENGE3), .value_name = "GST_RTSP_HDR_REAL_CHALLENGE3", .value_nick = "real-challenge3" },
            .{ .value = @intCast(c.GST_RTSP_HDR_SUBSCRIBE), .value_name = "GST_RTSP_HDR_SUBSCRIBE", .value_nick = "subscribe" },
            .{ .value = @intCast(c.GST_RTSP_HDR_ALERT), .value_name = "GST_RTSP_HDR_ALERT", .value_nick = "alert" },
            .{ .value = @intCast(c.GST_RTSP_HDR_CLIENT_ID), .value_name = "GST_RTSP_HDR_CLIENT_ID", .value_nick = "client-id" },
            .{ .value = @intCast(c.GST_RTSP_HDR_COMPANY_ID), .value_name = "GST_RTSP_HDR_COMPANY_ID", .value_nick = "company-id" },
            .{ .value = @intCast(c.GST_RTSP_HDR_GUID), .value_name = "GST_RTSP_HDR_GUID", .value_nick = "guid" },
            .{ .value = @intCast(c.GST_RTSP_HDR_REGION_DATA), .value_name = "GST_RTSP_HDR_REGION_DATA", .value_nick = "region-data" },
            .{ .value = @intCast(c.GST_RTSP_HDR_MAX_ASM_WIDTH), .value_name = "GST_RTSP_HDR_MAX_ASM_WIDTH", .value_nick = "max-asm-width" },
            .{ .value = @intCast(c.GST_RTSP_HDR_LANGUAGE), .value_name = "GST_RTSP_HDR_LANGUAGE", .value_nick = "language" },
            .{ .value = @intCast(c.GST_RTSP_HDR_PLAYER_START_TIME), .value_name = "GST_RTSP_HDR_PLAYER_START_TIME", .value_nick = "player-start-time" },
            .{ .value = @intCast(c.GST_RTSP_HDR_LOCATION), .value_name = "GST_RTSP_HDR_LOCATION", .value_nick = "location" },
            .{ .value = @intCast(c.GST_RTSP_HDR_ETAG), .value_name = "GST_RTSP_HDR_ETAG", .value_nick = "etag" },
            .{ .value = @intCast(c.GST_RTSP_HDR_IF_MATCH), .value_name = "GST_RTSP_HDR_IF_MATCH", .value_nick = "if-match" },
            .{ .value = @intCast(c.GST_RTSP_HDR_ACCEPT_CHARSET), .value_name = "GST_RTSP_HDR_ACCEPT_CHARSET", .value_nick = "accept-charset" },
            .{ .value = @intCast(c.GST_RTSP_HDR_SUPPORTED), .value_name = "GST_RTSP_HDR_SUPPORTED", .value_nick = "supported" },
            .{ .value = @intCast(c.GST_RTSP_HDR_VARY), .value_name = "GST_RTSP_HDR_VARY", .value_nick = "vary" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_ACCELERATE_STREAMING), .value_name = "GST_RTSP_HDR_X_ACCELERATE_STREAMING", .value_nick = "x-accelerate-streaming" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_ACCEPT_AUTHENT), .value_name = "GST_RTSP_HDR_X_ACCEPT_AUTHENT", .value_nick = "x-accept-authent" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_ACCEPT_PROXY_AUTHENT), .value_name = "GST_RTSP_HDR_X_ACCEPT_PROXY_AUTHENT", .value_nick = "x-accept-proxy-authent" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_BROADCAST_ID), .value_name = "GST_RTSP_HDR_X_BROADCAST_ID", .value_nick = "x-broadcast-id" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_BURST_STREAMING), .value_name = "GST_RTSP_HDR_X_BURST_STREAMING", .value_nick = "x-burst-streaming" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_NOTICE), .value_name = "GST_RTSP_HDR_X_NOTICE", .value_nick = "x-notice" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_PLAYER_LAG_TIME), .value_name = "GST_RTSP_HDR_X_PLAYER_LAG_TIME", .value_nick = "x-player-lag-time" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_PLAYLIST), .value_name = "GST_RTSP_HDR_X_PLAYLIST", .value_nick = "x-playlist" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_PLAYLIST_CHANGE_NOTICE), .value_name = "GST_RTSP_HDR_X_PLAYLIST_CHANGE_NOTICE", .value_nick = "x-playlist-change-notice" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_PLAYLIST_GEN_ID), .value_name = "GST_RTSP_HDR_X_PLAYLIST_GEN_ID", .value_nick = "x-playlist-gen-id" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_PLAYLIST_SEEK_ID), .value_name = "GST_RTSP_HDR_X_PLAYLIST_SEEK_ID", .value_nick = "x-playlist-seek-id" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_PROXY_CLIENT_AGENT), .value_name = "GST_RTSP_HDR_X_PROXY_CLIENT_AGENT", .value_nick = "x-proxy-client-agent" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_PROXY_CLIENT_VERB), .value_name = "GST_RTSP_HDR_X_PROXY_CLIENT_VERB", .value_nick = "x-proxy-client-verb" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_RECEDING_PLAYLISTCHANGE), .value_name = "GST_RTSP_HDR_X_RECEDING_PLAYLISTCHANGE", .value_nick = "x-receding-playlistchange" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_RTP_INFO), .value_name = "GST_RTSP_HDR_X_RTP_INFO", .value_nick = "x-rtp-info" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_STARTUPPROFILE), .value_name = "GST_RTSP_HDR_X_STARTUPPROFILE", .value_nick = "x-startupprofile" },
            .{ .value = @intCast(c.GST_RTSP_HDR_TIMESTAMP), .value_name = "GST_RTSP_HDR_TIMESTAMP", .value_nick = "timestamp" },
            .{ .value = @intCast(c.GST_RTSP_HDR_AUTHENTICATION_INFO), .value_name = "GST_RTSP_HDR_AUTHENTICATION_INFO", .value_nick = "authentication-info" },
            .{ .value = @intCast(c.GST_RTSP_HDR_HOST), .value_name = "GST_RTSP_HDR_HOST", .value_nick = "host" },
            .{ .value = @intCast(c.GST_RTSP_HDR_PRAGMA), .value_name = "GST_RTSP_HDR_PRAGMA", .value_nick = "pragma" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_SERVER_IP_ADDRESS), .value_name = "GST_RTSP_HDR_X_SERVER_IP_ADDRESS", .value_nick = "x-server-ip-address" },
            .{ .value = @intCast(c.GST_RTSP_HDR_X_SESSIONCOOKIE), .value_name = "GST_RTSP_HDR_X_SESSIONCOOKIE", .value_nick = "x-sessioncookie" },
            .{ .value = @intCast(c.GST_RTSP_HDR_RTCP_INTERVAL), .value_name = "GST_RTSP_HDR_RTCP_INTERVAL", .value_nick = "rtcp-interval" },
            .{ .value = @intCast(c.GST_RTSP_HDR_KEYMGMT), .value_name = "GST_RTSP_HDR_KEYMGMT", .value_nick = "keymgmt" },
            .{ .value = @intCast(c.GST_RTSP_HDR_PIPELINED_REQUESTS), .value_name = "GST_RTSP_HDR_PIPELINED_REQUESTS", .value_nick = "pipelined-requests" },
            .{ .value = @intCast(c.GST_RTSP_HDR_MEDIA_PROPERTIES), .value_name = "GST_RTSP_HDR_MEDIA_PROPERTIES", .value_nick = "media-properties" },
            .{ .value = @intCast(c.GST_RTSP_HDR_SEEK_STYLE), .value_name = "GST_RTSP_HDR_SEEK_STYLE", .value_nick = "seek-style" },
            .{ .value = @intCast(c.GST_RTSP_HDR_ACCEPT_RANGES), .value_name = "GST_RTSP_HDR_ACCEPT_RANGES", .value_nick = "accept-ranges" },
            .{ .value = @intCast(c.GST_RTSP_HDR_FRAMES), .value_name = "GST_RTSP_HDR_FRAMES", .value_nick = "frames" },
            .{ .value = @intCast(c.GST_RTSP_HDR_RATE_CONTROL), .value_name = "GST_RTSP_HDR_RATE_CONTROL", .value_nick = "rate-control" },
            .{ .value = @intCast(c.GST_RTSP_HDR_LAST), .value_name = "GST_RTSP_HDR_LAST", .value_nick = "last" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPHeaderField"), &values);
        }
    }.f);
}

var gst_rtsp_status_code_once: gtype.Once = .{};

pub export fn gst_rtsp_status_code_get_type() c.GType {
    return gst_rtsp_status_code_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_STS_INVALID), .value_name = "GST_RTSP_STS_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTSP_STS_CONTINUE), .value_name = "GST_RTSP_STS_CONTINUE", .value_nick = "continue" },
            .{ .value = @intCast(c.GST_RTSP_STS_OK), .value_name = "GST_RTSP_STS_OK", .value_nick = "ok" },
            .{ .value = @intCast(c.GST_RTSP_STS_CREATED), .value_name = "GST_RTSP_STS_CREATED", .value_nick = "created" },
            .{ .value = @intCast(c.GST_RTSP_STS_LOW_ON_STORAGE), .value_name = "GST_RTSP_STS_LOW_ON_STORAGE", .value_nick = "low-on-storage" },
            .{ .value = @intCast(c.GST_RTSP_STS_MULTIPLE_CHOICES), .value_name = "GST_RTSP_STS_MULTIPLE_CHOICES", .value_nick = "multiple-choices" },
            .{ .value = @intCast(c.GST_RTSP_STS_MOVED_PERMANENTLY), .value_name = "GST_RTSP_STS_MOVED_PERMANENTLY", .value_nick = "moved-permanently" },
            .{ .value = @intCast(c.GST_RTSP_STS_MOVE_TEMPORARILY), .value_name = "GST_RTSP_STS_MOVE_TEMPORARILY", .value_nick = "move-temporarily" },
            .{ .value = @intCast(c.GST_RTSP_STS_SEE_OTHER), .value_name = "GST_RTSP_STS_SEE_OTHER", .value_nick = "see-other" },
            .{ .value = @intCast(c.GST_RTSP_STS_NOT_MODIFIED), .value_name = "GST_RTSP_STS_NOT_MODIFIED", .value_nick = "not-modified" },
            .{ .value = @intCast(c.GST_RTSP_STS_USE_PROXY), .value_name = "GST_RTSP_STS_USE_PROXY", .value_nick = "use-proxy" },
            .{ .value = @intCast(c.GST_RTSP_STS_REDIRECT_TEMPORARILY), .value_name = "GST_RTSP_STS_REDIRECT_TEMPORARILY", .value_nick = "redirect-temporarily" },
            .{ .value = @intCast(c.GST_RTSP_STS_REDIRECT_PERMANENTLY), .value_name = "GST_RTSP_STS_REDIRECT_PERMANENTLY", .value_nick = "redirect-permanently" },
            .{ .value = @intCast(c.GST_RTSP_STS_BAD_REQUEST), .value_name = "GST_RTSP_STS_BAD_REQUEST", .value_nick = "bad-request" },
            .{ .value = @intCast(c.GST_RTSP_STS_UNAUTHORIZED), .value_name = "GST_RTSP_STS_UNAUTHORIZED", .value_nick = "unauthorized" },
            .{ .value = @intCast(c.GST_RTSP_STS_PAYMENT_REQUIRED), .value_name = "GST_RTSP_STS_PAYMENT_REQUIRED", .value_nick = "payment-required" },
            .{ .value = @intCast(c.GST_RTSP_STS_FORBIDDEN), .value_name = "GST_RTSP_STS_FORBIDDEN", .value_nick = "forbidden" },
            .{ .value = @intCast(c.GST_RTSP_STS_NOT_FOUND), .value_name = "GST_RTSP_STS_NOT_FOUND", .value_nick = "not-found" },
            .{ .value = @intCast(c.GST_RTSP_STS_METHOD_NOT_ALLOWED), .value_name = "GST_RTSP_STS_METHOD_NOT_ALLOWED", .value_nick = "method-not-allowed" },
            .{ .value = @intCast(c.GST_RTSP_STS_NOT_ACCEPTABLE), .value_name = "GST_RTSP_STS_NOT_ACCEPTABLE", .value_nick = "not-acceptable" },
            .{ .value = @intCast(c.GST_RTSP_STS_PROXY_AUTH_REQUIRED), .value_name = "GST_RTSP_STS_PROXY_AUTH_REQUIRED", .value_nick = "proxy-auth-required" },
            .{ .value = @intCast(c.GST_RTSP_STS_REQUEST_TIMEOUT), .value_name = "GST_RTSP_STS_REQUEST_TIMEOUT", .value_nick = "request-timeout" },
            .{ .value = @intCast(c.GST_RTSP_STS_GONE), .value_name = "GST_RTSP_STS_GONE", .value_nick = "gone" },
            .{ .value = @intCast(c.GST_RTSP_STS_LENGTH_REQUIRED), .value_name = "GST_RTSP_STS_LENGTH_REQUIRED", .value_nick = "length-required" },
            .{ .value = @intCast(c.GST_RTSP_STS_PRECONDITION_FAILED), .value_name = "GST_RTSP_STS_PRECONDITION_FAILED", .value_nick = "precondition-failed" },
            .{ .value = @intCast(c.GST_RTSP_STS_REQUEST_ENTITY_TOO_LARGE), .value_name = "GST_RTSP_STS_REQUEST_ENTITY_TOO_LARGE", .value_nick = "request-entity-too-large" },
            .{ .value = @intCast(c.GST_RTSP_STS_REQUEST_URI_TOO_LARGE), .value_name = "GST_RTSP_STS_REQUEST_URI_TOO_LARGE", .value_nick = "request-uri-too-large" },
            .{ .value = @intCast(c.GST_RTSP_STS_UNSUPPORTED_MEDIA_TYPE), .value_name = "GST_RTSP_STS_UNSUPPORTED_MEDIA_TYPE", .value_nick = "unsupported-media-type" },
            .{ .value = @intCast(c.GST_RTSP_STS_PARAMETER_NOT_UNDERSTOOD), .value_name = "GST_RTSP_STS_PARAMETER_NOT_UNDERSTOOD", .value_nick = "parameter-not-understood" },
            .{ .value = @intCast(c.GST_RTSP_STS_CONFERENCE_NOT_FOUND), .value_name = "GST_RTSP_STS_CONFERENCE_NOT_FOUND", .value_nick = "conference-not-found" },
            .{ .value = @intCast(c.GST_RTSP_STS_NOT_ENOUGH_BANDWIDTH), .value_name = "GST_RTSP_STS_NOT_ENOUGH_BANDWIDTH", .value_nick = "not-enough-bandwidth" },
            .{ .value = @intCast(c.GST_RTSP_STS_SESSION_NOT_FOUND), .value_name = "GST_RTSP_STS_SESSION_NOT_FOUND", .value_nick = "session-not-found" },
            .{ .value = @intCast(c.GST_RTSP_STS_METHOD_NOT_VALID_IN_THIS_STATE), .value_name = "GST_RTSP_STS_METHOD_NOT_VALID_IN_THIS_STATE", .value_nick = "method-not-valid-in-this-state" },
            .{ .value = @intCast(c.GST_RTSP_STS_HEADER_FIELD_NOT_VALID_FOR_RESOURCE), .value_name = "GST_RTSP_STS_HEADER_FIELD_NOT_VALID_FOR_RESOURCE", .value_nick = "header-field-not-valid-for-resource" },
            .{ .value = @intCast(c.GST_RTSP_STS_INVALID_RANGE), .value_name = "GST_RTSP_STS_INVALID_RANGE", .value_nick = "invalid-range" },
            .{ .value = @intCast(c.GST_RTSP_STS_PARAMETER_IS_READONLY), .value_name = "GST_RTSP_STS_PARAMETER_IS_READONLY", .value_nick = "parameter-is-readonly" },
            .{ .value = @intCast(c.GST_RTSP_STS_AGGREGATE_OPERATION_NOT_ALLOWED), .value_name = "GST_RTSP_STS_AGGREGATE_OPERATION_NOT_ALLOWED", .value_nick = "aggregate-operation-not-allowed" },
            .{ .value = @intCast(c.GST_RTSP_STS_ONLY_AGGREGATE_OPERATION_ALLOWED), .value_name = "GST_RTSP_STS_ONLY_AGGREGATE_OPERATION_ALLOWED", .value_nick = "only-aggregate-operation-allowed" },
            .{ .value = @intCast(c.GST_RTSP_STS_UNSUPPORTED_TRANSPORT), .value_name = "GST_RTSP_STS_UNSUPPORTED_TRANSPORT", .value_nick = "unsupported-transport" },
            .{ .value = @intCast(c.GST_RTSP_STS_DESTINATION_UNREACHABLE), .value_name = "GST_RTSP_STS_DESTINATION_UNREACHABLE", .value_nick = "destination-unreachable" },
            .{ .value = @intCast(c.GST_RTSP_STS_KEY_MANAGEMENT_FAILURE), .value_name = "GST_RTSP_STS_KEY_MANAGEMENT_FAILURE", .value_nick = "key-management-failure" },
            .{ .value = @intCast(c.GST_RTSP_STS_INTERNAL_SERVER_ERROR), .value_name = "GST_RTSP_STS_INTERNAL_SERVER_ERROR", .value_nick = "internal-server-error" },
            .{ .value = @intCast(c.GST_RTSP_STS_NOT_IMPLEMENTED), .value_name = "GST_RTSP_STS_NOT_IMPLEMENTED", .value_nick = "not-implemented" },
            .{ .value = @intCast(c.GST_RTSP_STS_BAD_GATEWAY), .value_name = "GST_RTSP_STS_BAD_GATEWAY", .value_nick = "bad-gateway" },
            .{ .value = @intCast(c.GST_RTSP_STS_SERVICE_UNAVAILABLE), .value_name = "GST_RTSP_STS_SERVICE_UNAVAILABLE", .value_nick = "service-unavailable" },
            .{ .value = @intCast(c.GST_RTSP_STS_GATEWAY_TIMEOUT), .value_name = "GST_RTSP_STS_GATEWAY_TIMEOUT", .value_nick = "gateway-timeout" },
            .{ .value = @intCast(c.GST_RTSP_STS_RTSP_VERSION_NOT_SUPPORTED), .value_name = "GST_RTSP_STS_RTSP_VERSION_NOT_SUPPORTED", .value_nick = "rtsp-version-not-supported" },
            .{ .value = @intCast(c.GST_RTSP_STS_OPTION_NOT_SUPPORTED), .value_name = "GST_RTSP_STS_OPTION_NOT_SUPPORTED", .value_nick = "option-not-supported" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPStatusCode"), &values);
        }
    }.f);
}

var gst_rtsp_msg_type_once: gtype.Once = .{};

pub export fn gst_rtsp_msg_type_get_type() c.GType {
    return gst_rtsp_msg_type_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_MESSAGE_INVALID), .value_name = "GST_RTSP_MESSAGE_INVALID", .value_nick = "invalid" },
            .{ .value = @intCast(c.GST_RTSP_MESSAGE_REQUEST), .value_name = "GST_RTSP_MESSAGE_REQUEST", .value_nick = "request" },
            .{ .value = @intCast(c.GST_RTSP_MESSAGE_RESPONSE), .value_name = "GST_RTSP_MESSAGE_RESPONSE", .value_nick = "response" },
            .{ .value = @intCast(c.GST_RTSP_MESSAGE_HTTP_REQUEST), .value_name = "GST_RTSP_MESSAGE_HTTP_REQUEST", .value_nick = "http-request" },
            .{ .value = @intCast(c.GST_RTSP_MESSAGE_HTTP_RESPONSE), .value_name = "GST_RTSP_MESSAGE_HTTP_RESPONSE", .value_nick = "http-response" },
            .{ .value = @intCast(c.GST_RTSP_MESSAGE_DATA), .value_name = "GST_RTSP_MESSAGE_DATA", .value_nick = "data" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPMsgType"), &values);
        }
    }.f);
}

var gst_rtsp_range_unit_once: gtype.Once = .{};

pub export fn gst_rtsp_range_unit_get_type() c.GType {
    return gst_rtsp_range_unit_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_RANGE_SMPTE), .value_name = "GST_RTSP_RANGE_SMPTE", .value_nick = "smpte" },
            .{ .value = @intCast(c.GST_RTSP_RANGE_SMPTE_30_DROP), .value_name = "GST_RTSP_RANGE_SMPTE_30_DROP", .value_nick = "smpte-30-drop" },
            .{ .value = @intCast(c.GST_RTSP_RANGE_SMPTE_25), .value_name = "GST_RTSP_RANGE_SMPTE_25", .value_nick = "smpte-25" },
            .{ .value = @intCast(c.GST_RTSP_RANGE_NPT), .value_name = "GST_RTSP_RANGE_NPT", .value_nick = "npt" },
            .{ .value = @intCast(c.GST_RTSP_RANGE_CLOCK), .value_name = "GST_RTSP_RANGE_CLOCK", .value_nick = "clock" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPRangeUnit"), &values);
        }
    }.f);
}

var gst_rtsp_time_type_once: gtype.Once = .{};

pub export fn gst_rtsp_time_type_get_type() c.GType {
    return gst_rtsp_time_type_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = @intCast(c.GST_RTSP_TIME_SECONDS), .value_name = "GST_RTSP_TIME_SECONDS", .value_nick = "seconds" },
            .{ .value = @intCast(c.GST_RTSP_TIME_NOW), .value_name = "GST_RTSP_TIME_NOW", .value_nick = "now" },
            .{ .value = @intCast(c.GST_RTSP_TIME_END), .value_name = "GST_RTSP_TIME_END", .value_nick = "end" },
            .{ .value = @intCast(c.GST_RTSP_TIME_FRAMES), .value_name = "GST_RTSP_TIME_FRAMES", .value_nick = "frames" },
            .{ .value = @intCast(c.GST_RTSP_TIME_UTC), .value_name = "GST_RTSP_TIME_UTC", .value_nick = "utc" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstRTSPTimeType"), &values);
        }
    }.f);
}

var gst_rtsp_trans_mode_once: gtype.Once = .{};

pub export fn gst_rtsp_trans_mode_get_type() c.GType {
    return gst_rtsp_trans_mode_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTSP_TRANS_UNKNOWN), .value_name = "GST_RTSP_TRANS_UNKNOWN", .value_nick = "unknown" },
            .{ .value = @intCast(c.GST_RTSP_TRANS_RTP), .value_name = "GST_RTSP_TRANS_RTP", .value_nick = "rtp" },
            .{ .value = @intCast(c.GST_RTSP_TRANS_RDT), .value_name = "GST_RTSP_TRANS_RDT", .value_nick = "rdt" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTSPTransMode"), &values);
        }
    }.f);
}

var gst_rtsp_profile_once: gtype.Once = .{};

pub export fn gst_rtsp_profile_get_type() c.GType {
    return gst_rtsp_profile_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTSP_PROFILE_UNKNOWN), .value_name = "GST_RTSP_PROFILE_UNKNOWN", .value_nick = "unknown" },
            .{ .value = @intCast(c.GST_RTSP_PROFILE_AVP), .value_name = "GST_RTSP_PROFILE_AVP", .value_nick = "avp" },
            .{ .value = @intCast(c.GST_RTSP_PROFILE_SAVP), .value_name = "GST_RTSP_PROFILE_SAVP", .value_nick = "savp" },
            .{ .value = @intCast(c.GST_RTSP_PROFILE_AVPF), .value_name = "GST_RTSP_PROFILE_AVPF", .value_nick = "avpf" },
            .{ .value = @intCast(c.GST_RTSP_PROFILE_SAVPF), .value_name = "GST_RTSP_PROFILE_SAVPF", .value_nick = "savpf" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTSPProfile"), &values);
        }
    }.f);
}

var gst_rtsp_lower_trans_once: gtype.Once = .{};

pub export fn gst_rtsp_lower_trans_get_type() c.GType {
    return gst_rtsp_lower_trans_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = @intCast(c.GST_RTSP_LOWER_TRANS_UNKNOWN), .value_name = "GST_RTSP_LOWER_TRANS_UNKNOWN", .value_nick = "unknown" },
            .{ .value = @intCast(c.GST_RTSP_LOWER_TRANS_UDP), .value_name = "GST_RTSP_LOWER_TRANS_UDP", .value_nick = "udp" },
            .{ .value = @intCast(c.GST_RTSP_LOWER_TRANS_UDP_MCAST), .value_name = "GST_RTSP_LOWER_TRANS_UDP_MCAST", .value_nick = "udp-mcast" },
            .{ .value = @intCast(c.GST_RTSP_LOWER_TRANS_TCP), .value_name = "GST_RTSP_LOWER_TRANS_TCP", .value_nick = "tcp" },
            .{ .value = @intCast(c.GST_RTSP_LOWER_TRANS_HTTP), .value_name = "GST_RTSP_LOWER_TRANS_HTTP", .value_nick = "http" },
            .{ .value = @intCast(c.GST_RTSP_LOWER_TRANS_TLS), .value_name = "GST_RTSP_LOWER_TRANS_TLS", .value_nick = "tls" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstRTSPLowerTrans"), &values);
        }
    }.f);
}

