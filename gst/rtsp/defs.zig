const std = @import("std");
const c = @import("../c.zig").c;

comptime {
    @import("../abi.zig").check(@This());
}

pub const DOMAIN = "GStreamer-RTSP";

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
    return ok;
}

const methods = [_][:0]const u8{ "DESCRIBE", "ANNOUNCE", "GET_PARAMETER", "OPTIONS", "PAUSE", "PLAY", "RECORD", "REDIRECT", "SETUP", "SET_PARAMETER", "TEARDOWN", "GET", "POST" };

const Header = struct { n: [:0]const u8, multi: bool = false };

const headers = [_]Header{
    .{ .n = "Accept", .multi = true },
    .{ .n = "Accept-Encoding", .multi = true },
    .{ .n = "Accept-Language", .multi = true },
    .{ .n = "Allow", .multi = true },
    .{ .n = "Authorization" },
    .{ .n = "Bandwidth" },
    .{ .n = "Blocksize" },
    .{ .n = "Cache-Control", .multi = true },
    .{ .n = "Conference" },
    .{ .n = "Connection", .multi = true },
    .{ .n = "Content-Base" },
    .{ .n = "Content-Encoding", .multi = true },
    .{ .n = "Content-Language", .multi = true },
    .{ .n = "Content-Length" },
    .{ .n = "Content-Location" },
    .{ .n = "Content-Type" },
    .{ .n = "CSeq" },
    .{ .n = "Date" },
    .{ .n = "Expires" },
    .{ .n = "From" },
    .{ .n = "If-Modified-Since" },
    .{ .n = "Last-Modified" },
    .{ .n = "Proxy-Authenticate", .multi = true },
    .{ .n = "Proxy-Require", .multi = true },
    .{ .n = "Public", .multi = true },
    .{ .n = "Range" },
    .{ .n = "Referer" },
    .{ .n = "Require", .multi = true },
    .{ .n = "Retry-After" },
    .{ .n = "RTP-Info", .multi = true },
    .{ .n = "Scale" },
    .{ .n = "Session" },
    .{ .n = "Server" },
    .{ .n = "Speed" },
    .{ .n = "Transport", .multi = true },
    .{ .n = "Unsupported" },
    .{ .n = "User-Agent" },
    .{ .n = "Via", .multi = true },
    .{ .n = "WWW-Authenticate", .multi = true },
    .{ .n = "ClientChallenge" },
    .{ .n = "RealChallenge1" },
    .{ .n = "RealChallenge2" },
    .{ .n = "RealChallenge3" },
    .{ .n = "Subscribe" },
    .{ .n = "Alert" },
    .{ .n = "ClientID" },
    .{ .n = "CompanyID" },
    .{ .n = "GUID" },
    .{ .n = "RegionData" },
    .{ .n = "SupportsMaximumASMBandwidth" },
    .{ .n = "Language" },
    .{ .n = "PlayerStarttime" },
    .{ .n = "Location" },
    .{ .n = "ETag" },
    .{ .n = "If-Match", .multi = true },
    .{ .n = "Accept-Charset", .multi = true },
    .{ .n = "Supported", .multi = true },
    .{ .n = "Vary", .multi = true },
    .{ .n = "X-Accelerate-Streaming" },
    .{ .n = "X-Accept-Authentication" },
    .{ .n = "X-Accept-Proxy-Authentication" },
    .{ .n = "X-Broadcast-Id" },
    .{ .n = "X-Burst-Streaming" },
    .{ .n = "X-Notice" },
    .{ .n = "X-Player-Lag-Time" },
    .{ .n = "X-Playlist" },
    .{ .n = "X-Playlist-Change-Notice" },
    .{ .n = "X-Playlist-Gen-Id" },
    .{ .n = "X-Playlist-Seek-Id" },
    .{ .n = "X-Proxy-Client-Agent" },
    .{ .n = "X-Proxy-Client-Verb" },
    .{ .n = "X-Receding-PlaylistChange" },
    .{ .n = "X-RTP-Info" },
    .{ .n = "X-StartupProfile" },
    .{ .n = "Timestamp" },
    .{ .n = "Authentication-Info" },
    .{ .n = "Host" },
    .{ .n = "Pragma", .multi = true },
    .{ .n = "X-Server-IP-Address" },
    .{ .n = "x-sessioncookie" },
    .{ .n = "RTCP-Interval" },
    .{ .n = "KeyMgmt" },
    .{ .n = "Pipelined-Requests" },
    .{ .n = "Media-Properties" },
    .{ .n = "Seek-Style" },
    .{ .n = "Accept-Ranges" },
    .{ .n = "Frames" },
    .{ .n = "Rate-Control" },
};

fn status(code: c.GstRTSPStatusCode) ?[:0]const u8 {
    return switch (code) {
        c.GST_RTSP_STS_CONTINUE => "Continue",
        c.GST_RTSP_STS_OK => "OK",
        c.GST_RTSP_STS_CREATED => "Created",
        c.GST_RTSP_STS_LOW_ON_STORAGE => "Low on Storage Space",
        c.GST_RTSP_STS_MULTIPLE_CHOICES => "Multiple Choices",
        c.GST_RTSP_STS_MOVED_PERMANENTLY => "Moved Permanently",
        c.GST_RTSP_STS_MOVE_TEMPORARILY => "Move Temporarily",
        c.GST_RTSP_STS_SEE_OTHER => "See Other",
        c.GST_RTSP_STS_NOT_MODIFIED => "Not Modified",
        c.GST_RTSP_STS_USE_PROXY => "Use Proxy",
        c.GST_RTSP_STS_BAD_REQUEST => "Bad Request",
        c.GST_RTSP_STS_UNAUTHORIZED => "Unauthorized",
        c.GST_RTSP_STS_PAYMENT_REQUIRED => "Payment Required",
        c.GST_RTSP_STS_FORBIDDEN => "Forbidden",
        c.GST_RTSP_STS_NOT_FOUND => "Not Found",
        c.GST_RTSP_STS_METHOD_NOT_ALLOWED => "Method Not Allowed",
        c.GST_RTSP_STS_NOT_ACCEPTABLE => "Not Acceptable",
        c.GST_RTSP_STS_PROXY_AUTH_REQUIRED => "Proxy Authentication Required",
        c.GST_RTSP_STS_REQUEST_TIMEOUT => "Request Time-out",
        c.GST_RTSP_STS_GONE => "Gone",
        c.GST_RTSP_STS_LENGTH_REQUIRED => "Length Required",
        c.GST_RTSP_STS_PRECONDITION_FAILED => "Precondition Failed",
        c.GST_RTSP_STS_REQUEST_ENTITY_TOO_LARGE => "Request Entity Too Large",
        c.GST_RTSP_STS_REQUEST_URI_TOO_LARGE => "Request-URI Too Large",
        c.GST_RTSP_STS_UNSUPPORTED_MEDIA_TYPE => "Unsupported Media Type",
        c.GST_RTSP_STS_PARAMETER_NOT_UNDERSTOOD => "Parameter Not Understood",
        c.GST_RTSP_STS_CONFERENCE_NOT_FOUND => "Conference Not Found",
        c.GST_RTSP_STS_NOT_ENOUGH_BANDWIDTH => "Not Enough Bandwidth",
        c.GST_RTSP_STS_SESSION_NOT_FOUND => "Session Not Found",
        c.GST_RTSP_STS_METHOD_NOT_VALID_IN_THIS_STATE => "Method Not Valid in This State",
        c.GST_RTSP_STS_HEADER_FIELD_NOT_VALID_FOR_RESOURCE => "Header Field Not Valid for Resource",
        c.GST_RTSP_STS_INVALID_RANGE => "Invalid Range",
        c.GST_RTSP_STS_PARAMETER_IS_READONLY => "Parameter Is Read-Only",
        c.GST_RTSP_STS_AGGREGATE_OPERATION_NOT_ALLOWED => "Aggregate operation not allowed",
        c.GST_RTSP_STS_ONLY_AGGREGATE_OPERATION_ALLOWED => "Only aggregate operation allowed",
        c.GST_RTSP_STS_UNSUPPORTED_TRANSPORT => "Unsupported transport",
        c.GST_RTSP_STS_DESTINATION_UNREACHABLE => "Destination unreachable",
        c.GST_RTSP_STS_KEY_MANAGEMENT_FAILURE => "Key management failure",
        c.GST_RTSP_STS_INTERNAL_SERVER_ERROR => "Internal Server Error",
        c.GST_RTSP_STS_NOT_IMPLEMENTED => "Not Implemented",
        c.GST_RTSP_STS_BAD_GATEWAY => "Bad Gateway",
        c.GST_RTSP_STS_SERVICE_UNAVAILABLE => "Service Unavailable",
        c.GST_RTSP_STS_GATEWAY_TIMEOUT => "Gateway Time-out",
        c.GST_RTSP_STS_RTSP_VERSION_NOT_SUPPORTED => "RTSP Version not supported",
        c.GST_RTSP_STS_OPTION_NOT_SUPPORTED => "Option not supported",
        else => null,
    };
}

pub export fn gst_rtsp_strresult(r: c.GstRTSPResult) [*c]u8 {
    const t: ?[*:0]const u8 = switch (r) {
        c.GST_RTSP_OK => "OK",
        c.GST_RTSP_ESYS => "System error",
        c.GST_RTSP_ENET => "Network error",
        c.GST_RTSP_ERROR => "Generic error",
        c.GST_RTSP_EINVAL => "Invalid parameter specified",
        c.GST_RTSP_EINTR => "Operation interrupted",
        c.GST_RTSP_ENOMEM => "Out of memory",
        c.GST_RTSP_ERESOLV => "Cannot resolve host",
        c.GST_RTSP_ENOTIMPL => "Function not implemented",
        c.GST_RTSP_EPARSE => "Parse error",
        c.GST_RTSP_EWSASTART => "Error on WSAStartup",
        c.GST_RTSP_EWSAVERSION => "Windows sockets are not version 0x202",
        c.GST_RTSP_EEOF => "Received end-of-file",
        c.GST_RTSP_ENOTIP => "Host is not a valid IP address",
        c.GST_RTSP_ETIMEOUT => "Timeout while waiting for server response",
        c.GST_RTSP_ETGET => "Tunnel GET request received",
        c.GST_RTSP_ETPOST => "Tunnel POST request received",
        else => null,
    };
    if (t) |s| return c.g_strdup(s);
    return c.g_strdup_printf("Unknown error (%d)", r);
}

pub export fn gst_rtsp_method_as_text(m: c.GstRTSPMethod) [*c]const u8 {
    if (m == c.GST_RTSP_INVALID) return null;
    const i = @ctz(m);
    return if (i < methods.len) methods[i].ptr else null;
}

pub export fn gst_rtsp_version_as_text(v: c.GstRTSPVersion) [*c]const u8 {
    return switch (v) {
        c.GST_RTSP_VERSION_1_0 => "1.0",
        c.GST_RTSP_VERSION_1_1 => "1.1",
        c.GST_RTSP_VERSION_2_0 => "2.0",
        else => "0.0",
    };
}

pub export fn gst_rtsp_header_as_text(f: c.GstRTSPHeaderField) [*c]const u8 {
    if (f == c.GST_RTSP_HDR_INVALID or f < 1 or f > headers.len) return null;
    return headers[@intCast(f - 1)].n.ptr;
}

pub export fn gst_rtsp_status_as_text(code: c.GstRTSPStatusCode) [*c]const u8 {
    return if (status(code)) |s| s.ptr else null;
}

pub export fn gst_rtsp_find_header_field(name: [*c]const u8) c.GstRTSPHeaderField {
    for (headers, 1..) |h, i| {
        if (c.g_ascii_strcasecmp(h.n.ptr, name) == 0) return @intCast(i);
    }
    return c.GST_RTSP_HDR_INVALID;
}

pub export fn gst_rtsp_find_method(name: [*c]const u8) c.GstRTSPMethod {
    for (methods, 0..) |m, i| {
        if (c.g_ascii_strcasecmp(m.ptr, name) == 0) return @as(c.GstRTSPMethod, 1) << @intCast(i);
    }
    return c.GST_RTSP_INVALID;
}

const option_order = [_]c.GstRTSPMethod{ c.GST_RTSP_OPTIONS, c.GST_RTSP_DESCRIBE, c.GST_RTSP_ANNOUNCE, c.GST_RTSP_GET_PARAMETER, c.GST_RTSP_PAUSE, c.GST_RTSP_PLAY, c.GST_RTSP_RECORD, c.GST_RTSP_REDIRECT, c.GST_RTSP_SETUP, c.GST_RTSP_SET_PARAMETER, c.GST_RTSP_TEARDOWN };

pub export fn gst_rtsp_options_as_text(options: c.GstRTSPMethod) [*c]u8 {
    const s = c.g_string_new("");
    for (option_order) |m| {
        if (options & m != 0) {
            _ = c.g_string_append(s, gst_rtsp_method_as_text(m));
            _ = c.g_string_append(s, ", ");
        }
    }
    if (s[0].len > 2) _ = c.g_string_truncate(s, s[0].len - 2);
    return c.g_string_free(s, 0);
}

pub export fn gst_rtsp_options_from_text(text: [*c]const u8) c.GstRTSPMethod {
    const parts = c.g_strsplit(text, ",", 0);
    defer c.g_strfreev(parts);
    var all: c.GstRTSPMethod = 0;
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) all |= gst_rtsp_find_method(c.g_strstrip(parts[i]));
    return all;
}

pub export fn gst_rtsp_header_allow_multiple(f: c.GstRTSPHeaderField) c.gboolean {
    if (f == c.GST_RTSP_HDR_INVALID or f < 1 or f > headers.len) return 0;
    return @intFromBool(headers[@intCast(f - 1)].multi);
}

fn md5Of(parts: []const []const u8) [*c]u8 {
    const sum = c.g_checksum_new(c.G_CHECKSUM_MD5);
    defer c.g_checksum_free(sum);
    for (parts) |p| c.g_checksum_update(sum, p.ptr, @intCast(p.len));
    return c.g_strdup(c.g_checksum_get_string(sum));
}

fn response(method: [*c]const u8, a1: [*c]const u8, uri: [*c]const u8, nonce: [*c]const u8) [*c]u8 {
    if (std.mem.len(a1) != 32) return null;
    const a2 = md5Of(&.{ std.mem.span(method), ":", std.mem.span(uri) });
    defer c.g_free(a2);
    return md5Of(&.{ a1[0..32], ":", std.mem.span(nonce), ":", a2[0..32] });
}

fn isMd5(algorithm: [*c]const u8) bool {
    return algorithm == null or c.g_ascii_strcasecmp(algorithm, "md5") == 0;
}

pub export fn gst_rtsp_generate_digest_auth_response(algorithm: [*c]const u8, method: [*c]const u8, realm: [*c]const u8, user: [*c]const u8, password: [*c]const u8, uri: [*c]const u8, nonce: [*c]const u8) [*c]u8 {
    const f = "gst_rtsp_generate_digest_auth_response";
    if (!that(method != null, f, "method != NULL")) return null;
    if (!that(realm != null, f, "realm != NULL")) return null;
    if (!that(user != null, f, "username != NULL")) return null;
    if (!that(password != null, f, "password != NULL")) return null;
    if (!that(uri != null, f, "uri != NULL")) return null;
    if (!that(nonce != null, f, "nonce != NULL")) return null;
    if (!isMd5(algorithm)) return null;
    const a1 = md5Of(&.{ std.mem.span(user), ":", std.mem.span(realm), ":", std.mem.span(password) });
    defer c.g_free(a1);
    return response(method, a1, uri, nonce);
}

pub export fn gst_rtsp_generate_digest_auth_response_from_md5(algorithm: [*c]const u8, method: [*c]const u8, md5: [*c]const u8, uri: [*c]const u8, nonce: [*c]const u8) [*c]u8 {
    if (!isMd5(algorithm)) return null;
    return response(method, md5, uri, nonce);
}
