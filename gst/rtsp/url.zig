const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const that = @import("defs.zig").that;

comptime {
    @import("../abi.zig").check(@This());
}

const Url = c.GstRTSPUrl;
const T = c.GST_RTSP_LOWER_TRANS_TCP;
const U = c.GST_RTSP_LOWER_TRANS_UDP;
const M = c.GST_RTSP_LOWER_TRANS_UDP_MCAST;
const H = c.GST_RTSP_LOWER_TRANS_HTTP;
const S = c.GST_RTSP_LOWER_TRANS_TLS;

const schemes = [_]struct { n: [:0]const u8, t: c.GstRTSPLowerTrans }{
    .{ .n = "rtsp", .t = T | U | M },
    .{ .n = "rtspu", .t = U | M },
    .{ .n = "rtspt", .t = T },
    .{ .n = "rtsph", .t = H | T },
    .{ .n = "rtsps", .t = T | U | M | S },
    .{ .n = "rtspsu", .t = U | M | S },
    .{ .n = "rtspst", .t = T | S },
    .{ .n = "rtspsh", .t = H | T | S },
};

var once: gtype.Once = .{};

pub export fn gst_rtsp_url_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstRTSPUrl", @ptrCast(&gst_rtsp_url_copy), @ptrCast(&gst_rtsp_url_free));
        }
    }.f);
}

fn diff(a: [*c]const u8, b: [*c]const u8) usize {
    return @intFromPtr(a) - @intFromPtr(b);
}

pub export fn gst_rtsp_url_parse(text: [*c]const u8, out: [*c][*c]Url) c.GstRTSPResult {
    const f = "gst_rtsp_url_parse";
    if (!that(text != null, f, "urlstr != NULL")) return c.GST_RTSP_EINVAL;
    if (!that(out != null, f, "url != NULL")) return c.GST_RTSP_EINVAL;
    out.* = null;
    const r: [*c]Url = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Url))));
    if (!parse(text, r)) {
        gst_rtsp_url_free(r);
        return c.GST_RTSP_EINVAL;
    }
    out.* = r;
    return c.GST_RTSP_OK;
}

fn parse(text: [*c]const u8, r: [*c]Url) bool {
    var p = text;
    var col: [*c]const u8 = c.strstr(p, "://");
    if (col == null) return false;
    for (schemes) |s| {
        if (c.g_ascii_strncasecmp(s.n.ptr, p, diff(col, p)) == 0) {
            r[0].transports = s.t;
            p = col + 3;
            break;
        }
    }
    if (r[0].transports == c.GST_RTSP_LOWER_TRANS_UNKNOWN) return false;
    var delim: [*c]const u8 = c.strpbrk(p, "/?");
    var at: [*c]const u8 = c.strchr(p, '@');
    if (at != null and delim != null and @intFromPtr(at) > @intFromPtr(delim)) at = null;
    if (at != null) {
        col = c.strchr(p, ':');
        if (col != null and @intFromPtr(col) < @intFromPtr(at)) {
            r[0].passwd = c.g_uri_unescape_segment(col + 1, at, null);
        } else col = at;
        r[0].user = c.g_uri_unescape_segment(p, col, null);
        p = at + 1;
    }
    var end: [*c]const u8 = null;
    if (p[0] == '[') {
        r[0].family = c.GST_RTSP_FAM_INET6;
        p += 1;
        end = c.strchr(p, ']');
        if (end == null or (delim != null and @intFromPtr(end) >= @intFromPtr(delim))) return false;
        col = if (end[1] == ':') end + 1 else null;
    } else {
        r[0].family = c.GST_RTSP_FAM_INET;
        col = c.strchr(p, ':');
        if (col != null and delim != null and @intFromPtr(col) >= @intFromPtr(delim)) col = null;
        end = if (col != null) col else delim;
    }
    if (end == null) {
        r[0].host = c.g_strdup(p);
    } else {
        r[0].host = c.g_strndup(p, diff(end, p));
        r[0].port = if (col != null) @truncate(c.strtoul(col + 1, null, 10)) else 0;
    }
    p = delim;
    if (p != null and p[0] == '/') {
        delim = c.strchr(p, '?');
        r[0].abspath = if (delim == null) c.g_strdup(p) else c.g_strndup(p, diff(delim, p));
        p = delim;
    } else r[0].abspath = c.g_strdup("");
    if (p != null and p[0] == '?') r[0].query = c.g_strdup(p + 1);
    return true;
}

pub export fn gst_rtsp_url_copy(u: [*c]const Url) [*c]Url {
    if (!that(u != null, "gst_rtsp_url_copy", "url != NULL")) return null;
    const r: [*c]Url = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Url))));
    r[0].transports = u[0].transports;
    r[0].family = u[0].family;
    r[0].user = c.g_strdup(u[0].user);
    r[0].passwd = c.g_strdup(u[0].passwd);
    r[0].host = c.g_strdup(u[0].host);
    r[0].port = u[0].port;
    r[0].abspath = c.g_strdup(u[0].abspath);
    r[0].query = c.g_strdup(u[0].query);
    return r;
}

pub export fn gst_rtsp_url_free(u: [*c]Url) void {
    if (u == null) return;
    c.g_free(u[0].user);
    c.g_free(u[0].passwd);
    c.g_free(u[0].host);
    c.g_free(u[0].abspath);
    c.g_free(u[0].query);
    c.g_free(u);
}

pub export fn gst_rtsp_url_set_port(u: [*c]Url, port: c.guint16) c.GstRTSPResult {
    if (!that(u != null, "gst_rtsp_url_set_port", "url != NULL")) return c.GST_RTSP_EINVAL;
    u[0].port = port;
    return c.GST_RTSP_OK;
}

pub export fn gst_rtsp_url_get_port(u: [*c]const Url, port: [*c]c.guint16) c.GstRTSPResult {
    const f = "gst_rtsp_url_get_port";
    if (!that(u != null, f, "url != NULL")) return c.GST_RTSP_EINVAL;
    if (!that(port != null, f, "port != NULL")) return c.GST_RTSP_EINVAL;
    port.* = if (u[0].port != 0) u[0].port else c.GST_RTSP_DEFAULT_PORT;
    return c.GST_RTSP_OK;
}

pub export fn gst_rtsp_url_get_request_uri(u: [*c]const Url) [*c]u8 {
    if (!that(u != null, "gst_rtsp_url_get_request_uri", "url != NULL")) return null;
    const v6 = u[0].family == c.GST_RTSP_FAM_INET6;
    const pre: [*c]const u8 = if (v6) "[" else "";
    const post: [*c]const u8 = if (v6) "]" else "";
    const qmark: [*c]const u8 = if (u[0].query != null) "?" else "";
    const q: [*c]const u8 = if (u[0].query != null) u[0].query else "";
    const scheme: [*c]const u8 = if (u[0].transports & S != 0) "rtsps" else "rtsp";
    if (u[0].port != 0) return c.g_strdup_printf("%s://%s%s%s:%u%s%s%s", scheme, pre, u[0].host, post, @as(c.guint, u[0].port), u[0].abspath, qmark, q);
    return c.g_strdup_printf("%s://%s%s%s%s%s%s", scheme, pre, u[0].host, post, u[0].abspath, qmark, q);
}

pub export fn gst_rtsp_url_get_request_uri_with_control(u: [*c]const Url, control: [*c]const u8) [*c]u8 {
    if (!that(u != null, "gst_rtsp_url_get_request_uri_with_control", "url != NULL")) return null;
    const base = gst_rtsp_url_get_request_uri(u);
    defer c.g_free(base);
    return c.gst_uri_join_strings(base, control);
}

fn hexval(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn unescape(s: [*c]u8) void {
    var len = std.mem.len(s);
    var i: usize = 0;
    while (i + 2 < len) : (i += 1) {
        if (s[i] != '%') continue;
        const a = hexval(s[i + 1]) orelse continue;
        const b = hexval(s[i + 2]) orelse continue;
        if (a == 0 and b == 0) continue;
        s[i] = a * 16 + b;
        std.mem.copyForwards(u8, s[i + 1 .. len - 2], s[i + 3 .. len]);
        len -= 2;
        s[len] = 0;
    }
}

pub export fn gst_rtsp_url_decode_path_components(u: [*c]const Url) [*c][*c]u8 {
    const f = "gst_rtsp_url_decode_path_components";
    if (!that(u != null, f, "url != NULL")) return null;
    if (!that(u[0].abspath != null, f, "url->abspath != NULL")) return null;
    const parts = c.g_strsplit(u[0].abspath, "/", -1);
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) unescape(parts[i]);
    return parts;
}
