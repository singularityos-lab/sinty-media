const std = @import("std");
const c = @import("../c.zig").c;
const defs = @import("defs.zig");
const msgs = @import("message.zig");
const urls = @import("url.zig");
const that = defs.that;

comptime {
    @import("../abi.zig").check(@This());
}

const Msg = c.GstRTSPMessage;
const Result = c.GstRTSPResult;
const OK = c.GST_RTSP_OK;
const EINVAL = c.GST_RTSP_EINVAL;
const TUNNELID_LEN = 24;
const NONE: u64 = std.math.maxInt(u64);
const SEC: u64 = c.GST_SECOND;

const Tunnel = enum(c_int) { none, get, post, complete };

const Decode = extern struct {
    state: c.gint = 0,
    save: c.guint = 0,
    out: [3]u8 = .{ 0, 0, 0 },
    cout: c.guint = 0,
    coutl: c.guint = 0,
};

const Serialized = extern struct {
    borrowed: c.gboolean = 0,
    data: [*c]u8 = null,
    data_size: c.guint = 0,
    data_is_header: c.gboolean = 0,
    body_data: [*c]u8 = null,
    body_data_size: c.guint = 0,
    body_buffer: [*c]c.GstBuffer = null,
    header: [4]u8 = .{ 0, 0, 0, 0 },
    data_offset: c.guint = 0,
    body_offset: c.guint = 0,
    id: c.guint = 0,

    fn clear(s: *Serialized) void {
        if (s.borrowed == 0) {
            c.g_free(s.body_data);
            _ = c.gst_mini_object_replace(@ptrCast(&s.body_buffer), null);
        }
        c.g_free(s.data);
    }

    fn head(s: *Serialized) [*c]u8 {
        return if (s.data_is_header != 0) &s.header else s.data;
    }

    fn bodySize(s: *Serialized) c.guint {
        if (s.body_data != null) return s.body_data_size;
        if (s.body_buffer != null) return @intCast(c.gst_buffer_get_size(s.body_buffer));
        return 0;
    }
};

const Extra = extern struct {
    key: [*c]u8,
    value: [*c]u8,
};

const Conn = struct {
    url: [*c]c.GstRTSPUrl = null,
    version: c.GstRTSPVersion = 0,
    server: bool = false,
    client: ?*c.GSocketClient = null,
    stream0: ?*c.GIOStream = null,
    stream1: ?*c.GIOStream = null,
    input: ?*c.GInputStream = null,
    output: ?*c.GOutputStream = null,
    control: ?*c.GInputStream = null,
    read_socket: ?*c.GSocket = null,
    write_socket: ?*c.GSocket = null,
    socket0: ?*c.GSocket = null,
    socket1: ?*c.GSocket = null,
    read_used: bool = false,
    write_used: bool = false,
    socket_lock: c.GMutex = std.mem.zeroes(c.GMutex),
    manual_http: bool = false,
    may_cancel: bool = true,
    cancel_lock: c.GMutex = std.mem.zeroes(c.GMutex),
    cancellable: ?*c.GCancellable = null,
    tunnelid: [TUNNELID_LEN]u8 = [_]u8{0} ** TUNNELID_LEN,
    tunneled: bool = false,
    ignore_x_server_reply: bool = false,
    tstate: Tunnel = .none,
    remote_ip: [*c]u8 = null,
    local_ip: [*c]u8 = null,
    read_ahead: c.gint = 0,
    initial: [*c]u8 = null,
    initial_offset: usize = 0,
    remember_session_id: bool = true,
    cseq: c.gint = 1,
    session_id: [512]u8 = [_]u8{0} ** 512,
    timeout: c.gint = 60,
    timer: ?*c.GTimer = null,
    auth_method: c.GstRTSPAuthMethod = c.GST_RTSP_AUTH_NONE,
    username: [*c]u8 = null,
    passwd: [*c]u8 = null,
    auth_params: ?*c.GHashTable = null,
    content_length_limit: c.guint = std.math.maxInt(c.guint),
    tls_database: ?*c.GTlsDatabase = null,
    tls_interaction: ?*c.GTlsInteraction = null,
    accept_func: c.GstRTSPConnectionAcceptCertificateFunc = null,
    accept_notify: c.GDestroyNotify = null,
    accept_data: c.gpointer = null,
    ctx: Decode = .{},
    ctxp: ?*Decode = null,
    proxy_host: [*c]u8 = null,
    proxy_port: c.guint = 0,
    extra: [*c]c.GArray = null,
};

fn of(p: anytype) *Conn {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn str(s: [*c]const u8) [*c]const u8 {
    return s;
}

fn resultOf(err: [*c]c.GError, default: Result) Result {
    if (err == null) return OK;
    if (err[0].domain != c.g_io_error_quark()) return default;
    return switch (err[0].code) {
        c.G_IO_ERROR_TIMED_OUT => c.GST_RTSP_ETIMEOUT,
        c.G_IO_ERROR_INVALID_ARGUMENT => EINVAL,
        c.G_IO_ERROR_CANCELLED, c.G_IO_ERROR_WOULD_BLOCK => c.GST_RTSP_EINTR,
        else => default,
    };
}

fn tlsAccept(tls: ?*c.GTlsConnection, cert: ?*c.GTlsCertificate, errors: c.GTlsCertificateFlags, data: c.gpointer) callconv(.c) c.gboolean {
    const conn = of(data);
    var accept = false;
    var flags = errors;
    if (conn.tls_database != null) {
        var err: [*c]c.GError = null;
        const identity = c.g_tls_client_connection_get_server_identity(@ptrCast(tls));
        flags = c.g_tls_database_verify_chain(conn.tls_database, cert, c.G_TLS_DATABASE_PURPOSE_AUTHENTICATE_SERVER, identity, c.g_tls_connection_get_interaction(tls), c.G_TLS_DATABASE_VERIFY_NONE, null, &err);
        if (err != null) {
            c.g_clear_error(&err);
            return 0;
        }
        accept = flags & gst_rtsp_connection_get_tls_validation_flags(@ptrCast(conn)) == 0;
    }
    if (!accept) {
        if (conn.accept_func) |f| accept = f(tls, cert, flags, conn.accept_data) != 0;
    }
    return @intFromBool(accept);
}

fn clientEvent(_: ?*c.GSocketClient, event: c.GSocketClientEvent, _: ?*c.GSocketConnectable, stream: ?*c.GIOStream, data: c.gpointer) callconv(.c) void {
    if (event != c.G_SOCKET_CLIENT_TLS_HANDSHAKING) return;
    const conn = of(data);
    _ = c.g_signal_connect_data(stream, "accept-certificate", @ptrCast(&tlsAccept), conn, null, 0);
    c.g_tls_connection_set_interaction(@ptrCast(stream), conn.tls_interaction);
}

fn resetStream0(conn: *Conn) void {
    if (conn.stream0 != null) {
        c.g_object_unref(conn.stream0);
        conn.stream0 = null;
        conn.socket0 = null;
    }
    conn.input = null;
    conn.output = null;
    c.g_free(conn.remote_ip);
    conn.remote_ip = null;
    conn.read_socket = null;
    conn.write_socket = null;
    conn.read_used = false;
    conn.write_used = false;
    conn.control = null;
}

fn cancellable(conn: *Conn) ?*c.GCancellable {
    c.g_mutex_lock(&conn.cancel_lock);
    defer c.g_mutex_unlock(&conn.cancel_lock);
    return if (conn.cancellable != null) @ptrCast(@alignCast(c.g_object_ref(conn.cancellable))) else null;
}

fn drop(obj: anytype) void {
    if (obj != null) c.g_object_unref(obj);
}

pub export fn gst_rtsp_connection_create(url: [*c]const c.GstRTSPUrl, out: [*c]?*c.GstRTSPConnection) Result {
    const f = "gst_rtsp_connection_create";
    if (!that(out != null, f, "conn != NULL")) return EINVAL;
    if (!that(url != null, f, "url != NULL")) return EINVAL;
    const conn: *Conn = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Conn))));
    conn.* = .{};
    conn.cancellable = c.g_cancellable_new();
    c.g_mutex_init(&conn.cancel_lock);
    conn.client = c.g_socket_client_new();
    if (url[0].transports & c.GST_RTSP_LOWER_TRANS_TLS != 0) c.g_socket_client_set_tls(conn.client, 1);
    _ = c.g_signal_connect_data(conn.client, "event", @ptrCast(&clientEvent), conn, null, 0);
    conn.url = urls.gst_rtsp_url_copy(url);
    conn.timer = c.g_timer_new();
    conn.extra = c.g_array_new(0, 0, @sizeOf(Extra));
    out.* = @ptrCast(conn);
    return OK;
}

fn addresses(sock: ?*c.GSocket, ip: ?*[*c]u8, port: ?*u16, remote: bool, err: *[*c]c.GError) bool {
    const addr = if (remote) c.g_socket_get_remote_address(sock, err) else c.g_socket_get_local_address(sock, err);
    if (addr == null) return false;
    defer c.g_object_unref(addr);
    if (ip) |p| p.* = c.g_inet_address_to_string(c.g_inet_socket_address_get_address(@ptrCast(addr)));
    if (port) |p| p.* = c.g_inet_socket_address_get_port(@ptrCast(addr));
    return true;
}

pub export fn gst_rtsp_connection_create_from_socket(sock: ?*c.GSocket, ip: [*c]const u8, port: c.guint16, initial: [*c]const u8, out: [*c]?*c.GstRTSPConnection) Result {
    const f = "gst_rtsp_connection_create_from_socket";
    if (!that(c.g_type_check_instance_is_a(@ptrCast(sock), c.g_socket_get_type()) != 0, f, "G_IS_SOCKET (socket)")) return EINVAL;
    if (!that(ip != null, f, "ip != NULL")) return EINVAL;
    if (!that(out != null, f, "conn != NULL")) return EINVAL;
    out.* = null;
    var err: [*c]c.GError = null;
    var local: [*c]u8 = null;
    if (!addresses(sock, &local, null, false, &err)) {
        const r = resultOf(err, c.GST_RTSP_ERROR);
        c.g_clear_error(&err);
        return r;
    }
    const url: [*c]c.GstRTSPUrl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstRTSPUrl))));
    url[0].host = c.g_strdup(ip);
    url[0].port = port;
    var handle: ?*c.GstRTSPConnection = null;
    const r = gst_rtsp_connection_create(url, &handle);
    urls.gst_rtsp_url_free(url);
    if (r != OK) {
        c.g_free(local);
        return r;
    }
    const conn = of(handle);
    const stream: ?*c.GIOStream = @ptrCast(c.g_socket_connection_factory_create_connection(sock));
    conn.server = true;
    conn.socket0 = sock;
    conn.stream0 = stream;
    conn.read_socket = sock;
    conn.write_socket = sock;
    c.g_mutex_init(&conn.socket_lock);
    conn.input = c.g_io_stream_get_input_stream(stream);
    conn.output = c.g_io_stream_get_output_stream(stream);
    conn.remote_ip = c.g_strdup(ip);
    conn.local_ip = local;
    conn.initial = c.g_strdup(initial);
    out.* = handle;
    return OK;
}

pub export fn gst_rtsp_connection_accept(sock: ?*c.GSocket, out: [*c]?*c.GstRTSPConnection, cancel: ?*c.GCancellable) Result {
    const f = "gst_rtsp_connection_accept";
    if (!that(c.g_type_check_instance_is_a(@ptrCast(sock), c.g_socket_get_type()) != 0, f, "G_IS_SOCKET (socket)")) return EINVAL;
    if (!that(out != null, f, "conn != NULL")) return EINVAL;
    out.* = null;
    var err: [*c]c.GError = null;
    const client = c.g_socket_accept(sock, cancel, &err);
    if (client == null) {
        const r = resultOf(err, c.GST_RTSP_ESYS);
        c.g_clear_error(&err);
        return r;
    }
    defer c.g_object_unref(client);
    var ip: [*c]u8 = null;
    var port: u16 = 0;
    if (!addresses(client, &ip, &port, true, &err)) {
        const r = resultOf(err, c.GST_RTSP_ERROR);
        c.g_clear_error(&err);
        if (c.g_socket_close(client, &err) == 0) c.g_clear_error(&err);
        return r;
    }
    defer c.g_free(ip);
    return gst_rtsp_connection_create_from_socket(client, ip, port, null, out);
}

pub export fn gst_rtsp_connection_get_tls(h: ?*c.GstRTSPConnection, err: [*c][*c]c.GError) ?*c.GTlsConnection {
    const conn = of(h);
    if (c.g_type_check_instance_is_a(@ptrCast(conn.stream0), c.g_tls_connection_get_type()) != 0) return @ptrCast(conn.stream0);
    if (conn.server) {
        const tls: ?*c.GTlsConnection = @ptrCast(c.g_tls_server_connection_new(conn.stream0, null, err));
        if (tls != null) {
            c.g_object_unref(conn.stream0);
            conn.stream0 = @ptrCast(tls);
            conn.input = c.g_io_stream_get_input_stream(conn.stream0);
            conn.output = c.g_io_stream_get_output_stream(conn.stream0);
        }
        return tls;
    }
    c.g_set_error(err, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_FAILED, "client not connected with TLS");
    return null;
}

pub export fn gst_rtsp_connection_set_tls_validation_flags(h: ?*c.GstRTSPConnection, flags: c.GTlsCertificateFlags) c.gboolean {
    if (!that(h != null, "gst_rtsp_connection_set_tls_validation_flags", "conn != NULL")) return 0;
    const res = c.g_socket_client_get_tls(of(h).client);
    if (res != 0) c.g_socket_client_set_tls_validation_flags(of(h).client, flags);
    return res;
}

pub export fn gst_rtsp_connection_get_tls_validation_flags(h: ?*c.GstRTSPConnection) c.GTlsCertificateFlags {
    if (!that(h != null, "gst_rtsp_connection_get_tls_validation_flags", "conn != NULL")) return 0;
    return c.g_socket_client_get_tls_validation_flags(of(h).client);
}

fn swap(slot: anytype, v: anytype) void {
    if (v != null) _ = c.g_object_ref(v);
    const old = slot.*;
    slot.* = v;
    drop(old);
}

fn refd(v: anytype) @TypeOf(v) {
    if (v != null) _ = c.g_object_ref(v);
    return v;
}

pub export fn gst_rtsp_connection_set_tls_database(h: ?*c.GstRTSPConnection, db: ?*c.GTlsDatabase) void {
    if (!that(h != null, "gst_rtsp_connection_set_tls_database", "conn != NULL")) return;
    swap(&of(h).tls_database, db);
}

pub export fn gst_rtsp_connection_get_tls_database(h: ?*c.GstRTSPConnection) ?*c.GTlsDatabase {
    if (!that(h != null, "gst_rtsp_connection_get_tls_database", "conn != NULL")) return null;
    return refd(of(h).tls_database);
}

pub export fn gst_rtsp_connection_set_tls_interaction(h: ?*c.GstRTSPConnection, i: ?*c.GTlsInteraction) void {
    if (!that(h != null, "gst_rtsp_connection_set_tls_interaction", "conn != NULL")) return;
    swap(&of(h).tls_interaction, i);
}

pub export fn gst_rtsp_connection_get_tls_interaction(h: ?*c.GstRTSPConnection) ?*c.GTlsInteraction {
    if (!that(h != null, "gst_rtsp_connection_get_tls_interaction", "conn != NULL")) return null;
    return refd(of(h).tls_interaction);
}

pub export fn gst_rtsp_connection_set_accept_certificate_func(h: ?*c.GstRTSPConnection, func: c.GstRTSPConnectionAcceptCertificateFunc, data: c.gpointer, notify: c.GDestroyNotify) void {
    const conn = of(h);
    if (conn.accept_notify) |n| n(conn.accept_data);
    conn.accept_func = func;
    conn.accept_data = data;
    conn.accept_notify = notify;
}

fn tunnelUri(url: [*c]c.GstRTSPUrl, port: u16) [*c]u8 {
    const v6 = url[0].family == c.GST_RTSP_FAM_INET6;
    return c.g_strdup_printf("http://%s%s%s:%d%s%s%s", str(if (v6) "[" else ""), url[0].host, str(if (v6) "]" else ""), @as(c_int, port), url[0].abspath, str(if (url[0].query != null) "?" else ""), str(if (url[0].query != null) url[0].query else ""));
}

fn extras(conn: *Conn) []Extra {
    const a = conn.extra;
    if (a[0].len == 0) return &.{};
    return @as([*]Extra, @ptrCast(@alignCast(a[0].data)))[0..a[0].len];
}

fn addExtras(m: [*c]Msg, conn: *Conn) void {
    for (extras(conn)) |h| {
        _ = msgs.gst_rtsp_message_remove_header_by_name(m, h.key, -1);
        _ = msgs.gst_rtsp_message_add_header_by_name(m, h.key, h.value);
    }
}

fn tunnelRequest(conn: *Conn, method: c.GstRTSPMethod, uri: [*c]const u8, host: [*c]const u8, timeout: i64) Result {
    var m: [*c]Msg = null;
    const r = msgs.gst_rtsp_message_new_request(&m, method, uri);
    if (r != OK) return r;
    defer _ = msgs.gst_rtsp_message_free(m);
    m[0].type = c.GST_RTSP_MESSAGE_HTTP_REQUEST;
    const add = msgs.gst_rtsp_message_add_header;
    _ = add(m, c.GST_RTSP_HDR_X_SESSIONCOOKIE, &conn.tunnelid);
    _ = add(m, c.GST_RTSP_HDR_ACCEPT, "application/x-rtsp-tunnelled");
    if (method == c.GST_RTSP_POST) _ = add(m, c.GST_RTSP_HDR_CONTENT_TYPE, "application/x-rtsp-tunnelled");
    _ = add(m, c.GST_RTSP_HDR_CACHE_CONTROL, "no-cache");
    _ = add(m, c.GST_RTSP_HDR_PRAGMA, "no-cache");
    if (method == c.GST_RTSP_POST) {
        _ = add(m, c.GST_RTSP_HDR_EXPIRES, "Sun, 9 Jan 1972 00:00:00 GMT");
        _ = add(m, c.GST_RTSP_HDR_CONTENT_LENGTH, "32767");
    }
    _ = add(m, c.GST_RTSP_HDR_HOST, host);
    addExtras(m, conn);
    conn.tunneled = false;
    const s = gst_rtsp_connection_send_usec(@ptrCast(conn), m, timeout);
    conn.tunneled = true;
    return s;
}

fn setupTunneling(conn: *Conn, timeout: i64, req_uri: *[*c]u8, resp: [*c]Msg) Result {
    const url = conn.url;
    var port: u16 = 0;
    _ = urls.gst_rtsp_url_get_port(url, &port);
    const host = c.g_strdup_printf("%s:%d", url[0].host, @as(c_int, port));
    defer c.g_free(host);
    for (0..TUNNELID_LEN) |i| conn.tunnelid[i] = @intCast(c.g_random_int_range('a', 'z'));
    conn.tunnelid[TUNNELID_LEN - 1] = 0;
    var r = tunnelRequest(conn, c.GST_RTSP_GET, req_uri.*, host, timeout);
    if (r != OK) return r;
    const old = conn.manual_http;
    conn.manual_http = true;
    r = gst_rtsp_connection_receive_usec(@ptrCast(conn), resp, timeout);
    if (r != OK) {
        conn.manual_http = false;
        return r;
    }
    conn.manual_http = old;
    if (resp[0].type != c.GST_RTSP_MESSAGE_HTTP_RESPONSE) return c.GST_RTSP_ERROR;
    switch (resp[0].type_data.response.code) {
        c.GST_RTSP_STS_OK => {},
        c.GST_RTSP_STS_MOVED_PERMANENTLY, c.GST_RTSP_STS_MOVE_TEMPORARILY, c.GST_RTSP_STS_REDIRECT_TEMPORARILY, c.GST_RTSP_STS_REDIRECT_PERMANENTLY => {
            var loc: [*c]u8 = null;
            _ = msgs.gst_rtsp_message_get_header(resp, c.GST_RTSP_HDR_LOCATION, &loc, 0);
            if (loc == null) return c.GST_RTSP_ERROR;
            c.g_free(req_uri.*);
            req_uri.* = c.g_strdup(loc);
            return c.GST_RTSP_OK_REDIRECT;
        },
        else => return c.GST_RTSP_ERROR,
    }
    var value: [*c]u8 = null;
    if (!conn.ignore_x_server_reply and msgs.gst_rtsp_message_get_header(resp, c.GST_RTSP_HDR_X_SERVER_IP_ADDRESS, &value, 0) == OK) {
        c.g_free(url[0].host);
        url[0].host = c.g_strdup(value);
        c.g_free(conn.remote_ip);
        conn.remote_ip = c.g_strdup(value);
    }
    const target = tunnelUri(url, port);
    defer c.g_free(target);
    var err: [*c]c.GError = null;
    const cc = cancellable(conn);
    var request: [*c]u8 = null;
    defer c.g_free(request);
    const sc = if (conn.proxy_host != null) blk: {
        request = c.g_strdup(target);
        break :blk c.g_socket_client_connect_to_host(conn.client, conn.proxy_host, @intCast(conn.proxy_port), cc, &err);
    } else blk: {
        request = c.g_strdup_printf("%s%s%s", url[0].abspath, str(if (url[0].query != null) "?" else ""), str(if (url[0].query != null) url[0].query else ""));
        break :blk c.g_socket_client_connect_to_uri(conn.client, target, 0, cc, &err);
    };
    drop(cc);
    if (sc == null) {
        const res = resultOf(err, c.GST_RTSP_ERROR);
        c.g_clear_error(&err);
        return res;
    }
    const sock = c.g_socket_connection_get_socket(sc);
    c.g_free(conn.remote_ip);
    conn.remote_ip = null;
    if (!addresses(sock, &conn.remote_ip, null, true, &err)) {
        const res = resultOf(err, c.GST_RTSP_ERROR);
        c.g_object_unref(sc);
        c.g_clear_error(&err);
        return res;
    }
    conn.stream1 = @ptrCast(sc);
    conn.socket1 = sock;
    conn.write_socket = sock;
    conn.output = c.g_io_stream_get_output_stream(conn.stream1);
    conn.control = null;
    return tunnelRequest(conn, c.GST_RTSP_POST, request, host, timeout);
}

pub export fn gst_rtsp_connection_connect_with_response_usec(h: ?*c.GstRTSPConnection, timeout: c.gint64, resp: [*c]Msg) Result {
    const f = "gst_rtsp_connection_connect_with_response_usec";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    const conn = of(h);
    if (!that(conn.url != null, f, "conn->url != NULL")) return EINVAL;
    if (!that(conn.stream0 == null, f, "conn->stream0 == NULL")) return EINVAL;
    const to: u64 = @bitCast(timeout *% 1000);
    c.g_socket_client_set_timeout(conn.client, @truncate((to +% SEC - 1) / SEC));
    const url = conn.url;
    var port: u16 = 0;
    _ = urls.gst_rtsp_url_get_port(url, &port);
    var target = if (conn.tunneled) tunnelUri(url, port) else urls.gst_rtsp_url_get_request_uri(url);
    var request: [*c]u8 = null;
    var uri: ?*c.GstUri = null;
    var redirects: c.guint = 0;
    var res: Result = OK;
    defer {
        c.g_free(target);
        c.g_free(request);
    }
    while (res == OK) {
        const cc = cancellable(conn);
        c.g_free(request);
        request = null;
        var err: [*c]c.GError = null;
        var sc: ?*c.GSocketConnection = null;
        if (conn.proxy_host != null) {
            sc = c.g_socket_client_connect_to_host(conn.client, conn.proxy_host, @intCast(conn.proxy_port), cc, &err);
            request = c.g_strdup(target);
        } else {
            if (uri != null) port = @intCast(c.gst_uri_get_port(uri));
            sc = c.g_socket_client_connect_to_uri(conn.client, target, port, cc, &err);
            if (uri == null) {
                request = c.g_strdup_printf("%s%s%s", url[0].abspath, str(if (url[0].query != null) "?" else ""), str(if (url[0].query != null) url[0].query else ""));
            } else {
                const path = c.gst_uri_get_path(uri);
                const query = c.gst_uri_get_query_string(uri);
                request = c.g_strdup_printf("%s%s%s", path, str(if (query != null) "?" else ""), str(if (query != null) query else ""));
                c.g_free(path);
                c.g_free(query);
            }
        }
        drop(cc);
        if (sc == null) {
            res = resultOf(err, c.GST_RTSP_ERROR);
            c.g_clear_error(&err);
            return res;
        }
        const sock = c.g_socket_connection_get_socket(sc);
        var ip: [*c]u8 = null;
        if (!addresses(sock, &ip, null, true, &err)) {
            res = resultOf(err, c.GST_RTSP_ERROR);
            c.g_object_unref(sc);
            c.g_clear_error(&err);
            return res;
        }
        c.g_free(conn.remote_ip);
        conn.remote_ip = ip;
        conn.stream0 = @ptrCast(sc);
        conn.socket0 = sock;
        conn.read_socket = sock;
        conn.write_socket = sock;
        conn.read_used = false;
        conn.write_used = false;
        conn.input = c.g_io_stream_get_input_stream(conn.stream0);
        conn.output = c.g_io_stream_get_output_stream(conn.stream0);
        conn.control = null;
        if (!conn.tunneled) break;
        res = setupTunneling(conn, timeout, &request, resp);
        if (res == OK) {
            res = c.GST_RTSP_OK_REDIRECT;
            continue;
        }
        if (res != c.GST_RTSP_OK_REDIRECT) return res;
        if (conn.proxy_host != null) return c.GST_RTSP_ERROR;
        resetStream0(conn);
        c.g_free(target);
        target = request;
        request = null;
        if (uri != null) c.gst_uri_unref(uri);
        uri = c.gst_uri_from_string(target);
        if (uri == null) return c.GST_RTSP_ERROR;
        conn.url[0].abspath = c.gst_uri_get_path(uri);
        conn.url[0].host = c.g_strdup(c.gst_uri_get_host(uri));
        conn.url[0].port = @intCast(c.gst_uri_get_port(uri));
        conn.url[0].query = c.gst_uri_get_query_string(uri);
        res = OK;
        redirects += 1;
        if (redirects > 5) return c.GST_RTSP_ERROR;
    }
    return res;
}

fn addAuth(conn: *Conn, m: [*c]Msg) void {
    switch (conn.auth_method) {
        c.GST_RTSP_AUTH_BASIC => {
            if (conn.username == null or conn.passwd == null) return;
            const pair = c.g_strdup_printf("%s:%s", conn.username, conn.passwd);
            defer c.g_free(pair);
            const enc = c.g_base64_encode(pair, std.mem.len(pair));
            defer c.g_free(enc);
            _ = msgs.gst_rtsp_message_take_header(m, c.GST_RTSP_HDR_AUTHORIZATION, c.g_strdup_printf("Basic %s", enc));
        },
        c.GST_RTSP_AUTH_DIGEST => {
            if (conn.auth_params == null or conn.username == null or conn.passwd == null) return;
            const realm: [*c]const u8 = @ptrCast(c.g_hash_table_lookup(conn.auth_params, "realm"));
            const nonce: [*c]const u8 = @ptrCast(c.g_hash_table_lookup(conn.auth_params, "nonce"));
            if (realm == null or nonce == null) return;
            const method = defs.gst_rtsp_method_as_text(m[0].type_data.request.method);
            const uri = m[0].type_data.request.uri;
            const response = defs.gst_rtsp_generate_digest_auth_response(null, method, realm, conn.username, conn.passwd, uri, nonce);
            var auth = c.g_strdup_printf("Digest username=\"%s\", realm=\"%s\", nonce=\"%s\", uri=\"%s\", response=\"%s\"", conn.username, realm, nonce, uri, response);
            c.g_free(response);
            const opq: [*c]const u8 = @ptrCast(c.g_hash_table_lookup(conn.auth_params, "opaque"));
            if (opq != null) {
                const more = c.g_strdup_printf("%s, opaque=\"%s\"", auth, opq);
                c.g_free(auth);
                auth = more;
            }
            _ = msgs.gst_rtsp_message_remove_header(m, c.GST_RTSP_HDR_AUTHORIZATION, -1);
            _ = msgs.gst_rtsp_message_take_header(m, c.GST_RTSP_HDR_AUTHORIZATION, auth);
        },
        else => {},
    }
}

pub export fn gst_rtsp_connection_connect_usec(h: ?*c.GstRTSPConnection, timeout: c.gint64) Result {
    var resp = std.mem.zeroes(Msg);
    _ = msgs.gst_rtsp_message_init(&resp);
    const r = gst_rtsp_connection_connect_with_response_usec(h, timeout, &resp);
    _ = msgs.gst_rtsp_message_unset(&resp);
    return r;
}

fn dateString(buf: []u8) void {
    const wk = [_][*:0]const u8{ "", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const mo = [_][*:0]const u8{ "", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const now = c.g_date_time_new_now_utc();
    defer c.g_date_time_unref(now);
    _ = c.g_snprintf(buf.ptr, @intCast(buf.len), "%s, %02u %s %04u %02u:%02u:%02u GMT", wk[@intCast(c.g_date_time_get_day_of_week(now))], c.g_date_time_get_day_of_month(now), mo[@intCast(c.g_date_time_get_month(now))], c.g_date_time_get_year(now), c.g_date_time_get_hour(now), c.g_date_time_get_minute(now), c.g_date_time_get_second(now));
}

fn writeBytes(stream: ?*c.GOutputStream, data: [*c]const u8, idx: *c.guint, size: c.guint, block: bool, cc: ?*c.GCancellable) Result {
    if (idx.* > size) return c.GST_RTSP_ERROR;
    var left = size - idx.*;
    var err: [*c]c.GError = null;
    while (left != 0) {
        const r = if (block) c.g_output_stream_write(stream, data + idx.*, left, cc, &err) else c.g_pollable_output_stream_write_nonblocking(@ptrCast(stream), data + idx.*, left, cc, &err);
        if (r <= 0) {
            if (r == 0) return c.GST_RTSP_EEOF;
            const res = resultOf(err, c.GST_RTSP_ESYS);
            c.g_clear_error(&err);
            return res;
        }
        left -= @intCast(r);
        idx.* += @intCast(r);
    }
    return OK;
}

fn writevBytes(stream: ?*c.GOutputStream, vectors_in: [*c]c.GOutputVector, count: usize, written_out: *usize, block: bool, cc: ?*c.GCancellable) Result {
    var vectors = vectors_in;
    var n = count;
    var total: usize = 0;
    var err: [*c]c.GError = null;
    var written: usize = 0;
    while (n > 0) {
        var res: c.GPollableReturn = c.G_POLLABLE_RETURN_OK;
        if (block) {
            if (c.g_output_stream_writev(stream, vectors, n, &written, cc, &err) == 0) res = c.G_POLLABLE_RETURN_FAILED;
        } else {
            res = c.g_pollable_output_stream_writev_nonblocking(@ptrCast(stream), vectors, n, &written, cc, &err);
        }
        if (res != c.G_POLLABLE_RETURN_OK) {
            written_out.* = total;
            if (res == c.G_POLLABLE_RETURN_WOULD_BLOCK) return c.GST_RTSP_EINTR;
            if (written == 0) {
                c.g_clear_error(&err);
                return c.GST_RTSP_EEOF;
            }
            const r = resultOf(err, c.GST_RTSP_ESYS);
            c.g_clear_error(&err);
            return r;
        }
        total += written;
        while (written > 0 and written >= vectors[0].size) {
            written -= vectors[0].size;
            vectors += 1;
            n -= 1;
        }
        if (written > 0) {
            vectors[0].size -= written;
            vectors[0].buffer = @as([*c]const u8, @ptrCast(vectors[0].buffer)) + written;
        }
    }
    written_out.* = total;
    return OK;
}

fn fillRaw(conn: *Conn, buf: [*c]u8, size: c.guint, block: bool, err: *[*c]c.GError) c.gint {
    var out: c.gint = 0;
    if (conn.initial != null) {
        const rest = conn.initial + conn.initial_offset;
        const left = std.mem.len(rest);
        const n = @min(left, size);
        @memcpy(buf[0..n], rest[0..n]);
        out = @intCast(n);
        if (left == n) {
            c.g_free(conn.initial);
            conn.initial = null;
            conn.initial_offset = 0;
        } else conn.initial_offset += n;
    }
    if (size > @as(c.guint, @intCast(out))) {
        const count = size - @as(c.guint, @intCast(out));
        const cc = if (conn.may_cancel) cancellable(conn) else null;
        const r = if (block) c.g_input_stream_read(conn.input, buf + @as(usize, @intCast(out)), count, cc, err) else c.g_pollable_input_stream_read_nonblocking(@ptrCast(conn.input), buf + @as(usize, @intCast(out)), count, cc, err);
        drop(cc);
        if (r < 0) {
            if (out == 0) {
                out = @intCast(r);
            } else c.g_clear_error(err);
        } else out += @intCast(r);
    }
    return out;
}

fn fill(conn: *Conn, buffer: [*c]u8, total: c.guint, block: bool, err: *[*c]c.GError) c.gint {
    const ctx = conn.ctxp orelse return fillRaw(conn, buffer, total, block, err);
    var buf = buffer;
    var size = total;
    var out: c.gint = 0;
    while (size > 0) {
        while (size > 0 and ctx.cout < ctx.coutl) {
            buf[0] = ctx.out[ctx.cout];
            ctx.cout += 1;
            buf += 1;
            size -= 1;
            out += 1;
        }
        if (size == 0) break;
        var in: [4]u8 = undefined;
        const r = fillRaw(conn, &in, in.len, block, err);
        if (r <= 0) {
            if (out == 0) {
                out = r;
            } else c.g_clear_error(err);
            break;
        }
        ctx.cout = 0;
        ctx.coutl = @intCast(c.g_base64_decode_step(&in, @intCast(r), &ctx.out, &ctx.state, &ctx.save));
    }
    return out;
}

fn readBytes(conn: *Conn, buf: [*c]u8, idx: *c.guint, size: c.guint, block: bool) Result {
    if (idx.* > size) return c.GST_RTSP_ERROR;
    if (conn.input == null) return EINVAL;
    var left = size - idx.*;
    var err: [*c]c.GError = null;
    while (left != 0) {
        const r = fill(conn, buf + idx.*, left, block, &err);
        if (r <= 0) {
            if (r == 0) return c.GST_RTSP_EEOF;
            if (err == null) return EINVAL;
            const res = resultOf(err, c.GST_RTSP_ESYS);
            c.g_clear_error(&err);
            return res;
        }
        left -= @intCast(r);
        idx.* += @intCast(r);
    }
    return OK;
}

const AHEAD_EOH = -1;
const AHEAD_CRLF = -2;
const AHEAD_CRLFCR = -3;

fn readLine(conn: *Conn, buf: [*c]u8, idx: *c.guint, size: c.guint, block: bool) Result {
    outer: while (true) {
        var ch: u8 = 0;
        var i: c.guint = 0;
        switch (conn.read_ahead) {
            AHEAD_EOH => {
                conn.read_ahead = 0;
                break;
            },
            AHEAD_CRLF => ch = '\n',
            AHEAD_CRLFCR => ch = '\r',
            0 => {
                const r = readBytes(conn, &ch, &i, 1, block);
                if (r != OK) return r;
            },
            else => {
                ch = @truncate(@as(c.guint, @bitCast(conn.read_ahead)));
                conn.read_ahead = 0;
            },
        }
        if (ch == '\r' or ch == '\n') {
            while (true) {
                var ahead: u8 = 0;
                i = 0;
                const r = readBytes(conn, &ahead, &i, 1, block);
                if (r != OK) return r;
                if (ahead == ' ' or ahead == '\t') {
                    if (conn.read_ahead == AHEAD_CRLFCR) {
                        conn.read_ahead = ahead;
                        break :outer;
                    }
                    ch = ' ';
                    conn.read_ahead = ahead;
                    break;
                } else if (conn.read_ahead == AHEAD_CRLFCR) {
                    conn.read_ahead = if (ahead == '\r' or ahead == '\n') AHEAD_EOH else ahead;
                    break :outer;
                } else if (conn.read_ahead == AHEAD_CRLF) {
                    if (ahead == '\r') {
                        conn.read_ahead = AHEAD_CRLFCR;
                        continue;
                    }
                    conn.read_ahead = if (ahead == '\n') AHEAD_EOH else ahead;
                    break :outer;
                } else if (ch == ahead) {
                    conn.read_ahead = AHEAD_EOH;
                    break :outer;
                } else if (ch == '\r' and ahead == '\n') {
                    conn.read_ahead = AHEAD_CRLF;
                    continue;
                } else {
                    conn.read_ahead = ahead;
                    break :outer;
                }
            }
        }
        if (idx.* < size - 1) {
            buf[idx.*] = ch;
            idx.* += 1;
        }
    }
    buf[idx.*] = 0;
    return OK;
}

fn secondsOf(timeout: i64) c.guint {
    const ns: u64 = @bitCast(timeout *% 1000);
    return @truncate((ns +% SEC - 1) / SEC);
}

fn useSocket(conn: *Conn, read: bool, timeout: i64) void {
    c.g_mutex_lock(&conn.socket_lock);
    defer c.g_mutex_unlock(&conn.socket_lock);
    const s = if (read) conn.read_socket else conn.write_socket;
    if (read) conn.read_used = true else conn.write_used = true;
    const secs = secondsOf(timeout);
    if (secs > c.g_socket_get_timeout(s)) c.g_socket_set_timeout(s, secs);
}

fn releaseSocket(conn: *Conn, read: bool) void {
    c.g_mutex_lock(&conn.socket_lock);
    defer c.g_mutex_unlock(&conn.socket_lock);
    if (read) {
        conn.read_used = false;
        if (conn.read_socket != conn.write_socket or !conn.write_used) c.g_socket_set_timeout(conn.read_socket, 0);
    } else {
        conn.write_used = false;
        if (conn.write_socket != conn.read_socket or !conn.read_used) c.g_socket_set_timeout(conn.write_socket, 0);
    }
}

pub export fn gst_rtsp_connection_write_usec(h: ?*c.GstRTSPConnection, data: [*c]const u8, size: c.guint, timeout: c.gint64) Result {
    const f = "gst_rtsp_connection_write_usec";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    if (!that(data != null or size == 0, f, "data != NULL || size == 0")) return EINVAL;
    const conn = of(h);
    if (!that(conn.output != null, f, "conn->output_stream != NULL")) return EINVAL;
    var off: c.guint = 0;
    useSocket(conn, false, timeout);
    const cc = cancellable(conn);
    const r = writeBytes(conn.output, data, &off, size, true, cc);
    drop(cc);
    releaseSocket(conn, false);
    return r;
}

fn serialize(conn: *Conn, m: [*c]Msg, s: *Serialized) bool {
    s.* = .{ .borrowed = 1 };
    var text: [*c]c.GString = null;
    const rq = &m[0].type_data.request;
    const rs = &m[0].type_data.response;
    switch (m[0].type) {
        c.GST_RTSP_MESSAGE_REQUEST => {
            text = c.g_string_new("");
            c.g_string_append_printf(text, "%s %s RTSP/%s\r\nCSeq: %d\r\n", defs.gst_rtsp_method_as_text(rq.method), rq.uri, defs.gst_rtsp_version_as_text(rq.version), conn.cseq);
            conn.cseq += 1;
            if (conn.session_id[0] != 0) {
                _ = msgs.gst_rtsp_message_remove_header(m, c.GST_RTSP_HDR_SESSION, -1);
                _ = msgs.gst_rtsp_message_add_header(m, c.GST_RTSP_HDR_SESSION, &conn.session_id);
            }
            addAuth(conn, m);
        },
        c.GST_RTSP_MESSAGE_RESPONSE => {
            text = c.g_string_new("");
            c.g_string_append_printf(text, "RTSP/%s %d %s\r\n", defs.gst_rtsp_version_as_text(rs.version), rs.code, rs.reason);
        },
        c.GST_RTSP_MESSAGE_HTTP_REQUEST => {
            text = c.g_string_new("");
            c.g_string_append_printf(text, "%s %s HTTP/%s\r\n", defs.gst_rtsp_method_as_text(rq.method), rq.uri, defs.gst_rtsp_version_as_text(rq.version));
            addAuth(conn, m);
        },
        c.GST_RTSP_MESSAGE_HTTP_RESPONSE => {
            text = c.g_string_new("");
            c.g_string_append_printf(text, "HTTP/%s %d %s\r\n", defs.gst_rtsp_version_as_text(rq.version), rs.code, rs.reason);
        },
        c.GST_RTSP_MESSAGE_DATA => {
            s.header = .{ '$', m[0].type_data.data.channel, @truncate(m[0].body_size >> 8), @truncate(m[0].body_size) };
            s.data_is_header = 1;
            s.data_size = 4;
            if (m[0].body != null) {
                s.body_data = m[0].body;
                s.body_data_size = m[0].body_size;
            } else s.body_buffer = m[0].body_buffer;
            return true;
        },
        else => {
            c.g_log(defs.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", "../gst-libs/gst/rtsp/gstrtspconnection.c", @as(c_int, 2022), "serialize_message");
            return false;
        },
    }
    var date: [100]u8 = undefined;
    dateString(&date);
    _ = msgs.gst_rtsp_message_remove_header(m, c.GST_RTSP_HDR_DATE, -1);
    _ = msgs.gst_rtsp_message_add_header(m, c.GST_RTSP_HDR_DATE, &date);
    _ = msgs.gst_rtsp_message_append_headers(m, text);
    if (m[0].body_size > 0) {
        c.g_string_append_printf(text, "%s: %d\r\n", defs.gst_rtsp_header_as_text(c.GST_RTSP_HDR_CONTENT_LENGTH), m[0].body_size);
        _ = c.g_string_append(text, "\r\n");
        if (m[0].body != null) {
            s.body_data = m[0].body;
            s.body_data_size = m[0].body_size;
        } else s.body_buffer = m[0].body_buffer;
    } else _ = c.g_string_append(text, "\r\n");
    s.data_size = @intCast(text[0].len);
    s.data = @ptrCast(c.g_string_free(text, 0));
    return true;
}

pub export fn gst_rtsp_connection_send_usec(h: ?*c.GstRTSPConnection, m: [*c]Msg, timeout: c.gint64) Result {
    const f = "gst_rtsp_connection_send_usec";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    if (!that(m != null, f, "message != NULL")) return EINVAL;
    return gst_rtsp_connection_send_messages_usec(h, m, 1, timeout);
}

fn tunnelEncode(s: *Serialized) void {
    var len: usize = s.data_size + s.bodySize();
    len = (len / 3 + 1) * 4 + 4 + 1;
    const start: [*c]u8 = @ptrCast(c.g_malloc0(len));
    var p = start;
    var state: c.gint = 0;
    var save: c.gint = 0;
    p += c.g_base64_encode_step(s.head(), s.data_size, 0, p, &state, &save);
    if (s.body_data != null) {
        p += c.g_base64_encode_step(s.body_data, s.body_data_size, 0, p, &state, &save);
    } else if (s.body_buffer != null) {
        const n = c.gst_buffer_n_memory(s.body_buffer);
        for (0..n) |j| {
            const mem = c.gst_buffer_peek_memory(s.body_buffer, @intCast(j));
            var map: c.GstMapInfo = undefined;
            _ = c.gst_memory_map(mem, &map, c.GST_MAP_READ);
            p += c.g_base64_encode_step(map.data, map.size, 0, p, &state, &save);
            c.gst_memory_unmap(mem, &map);
        }
    }
    p += c.g_base64_encode_close(0, p, &state, &save);
    s.clear();
    s.* = .{ .data = start, .data_size = @intCast(@intFromPtr(p) - @intFromPtr(start)) };
}

fn vectorize(list: []Serialized, vecs: *std.ArrayList(c.GOutputVector), maps: *std.ArrayList(c.GstMapInfo), partial: bool) usize {
    const al = std.heap.c_allocator;
    var total: usize = 0;
    for (list) |*s| {
        if (!partial or s.data_offset < s.data_size) {
            const off = if (partial) s.data_offset else 0;
            const v = c.GOutputVector{ .buffer = s.head() + off, .size = s.data_size - off };
            vecs.append(al, v) catch unreachable;
            total += v.size;
        }
        if (s.body_data != null) {
            const off = if (partial) s.body_offset else 0;
            if (off < s.body_data_size) {
                const v = c.GOutputVector{ .buffer = s.body_data + off, .size = s.body_data_size - off };
                vecs.append(al, v) catch unreachable;
                total += v.size;
            }
        } else if (s.body_buffer != null) {
            const n = c.gst_buffer_n_memory(s.body_buffer);
            var at: usize = 0;
            for (0..n) |j| {
                const mem = c.gst_buffer_peek_memory(s.body_buffer, @intCast(j));
                const msize = mem[0].size;
                const body_off: usize = if (partial) s.body_offset else 0;
                if (at + msize <= body_off) {
                    at += msize;
                    continue;
                }
                const skip = if (at < body_off) body_off - at else 0;
                at += msize;
                var map: c.GstMapInfo = undefined;
                _ = c.gst_memory_map(mem, &map, c.GST_MAP_READ);
                maps.append(al, map) catch unreachable;
                const v = c.GOutputVector{ .buffer = map.data + skip, .size = map.size - skip };
                vecs.append(al, v) catch unreachable;
                total += v.size;
            }
        }
    }
    return total;
}

fn unmapAll(maps: *std.ArrayList(c.GstMapInfo)) void {
    for (maps.items) |*m| c.gst_memory_unmap(m.memory, m);
    maps.deinit(std.heap.c_allocator);
}

pub export fn gst_rtsp_connection_send_messages_usec(h: ?*c.GstRTSPConnection, ms: [*c]Msg, n: c.guint, timeout: c.gint64) Result {
    const f = "gst_rtsp_connection_send_messages_usec";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    if (!that(ms != null or n == 0, f, "messages != NULL || n_messages == 0")) return EINVAL;
    const conn = of(h);
    const al = std.heap.c_allocator;
    const list = al.alloc(Serialized, n) catch unreachable;
    defer al.free(list);
    @memset(list, .{});
    for (list, 0..) |*s, i| {
        if (!serialize(conn, &ms[i], s)) {
            for (list) |*x| x.clear();
            c.g_log(defs.DOMAIN, c.G_LOG_LEVEL_WARNING, "Wrong message");
            return EINVAL;
        }
        if (conn.tunneled) tunnelEncode(s);
    }
    var vecs = std.ArrayList(c.GOutputVector).empty;
    defer vecs.deinit(al);
    var maps = std.ArrayList(c.GstMapInfo).empty;
    _ = vectorize(list, &vecs, &maps, false);
    useSocket(conn, false, timeout);
    const cc = cancellable(conn);
    var written: usize = 0;
    const r = writevBytes(conn.output, vecs.items.ptr, vecs.items.len, &written, true, cc);
    drop(cc);
    releaseSocket(conn, false);
    unmapAll(&maps);
    for (list) |*s| c.g_free(s.data);
    return r;
}

fn parseString(dest: []u8, src: *[*c]u8) Result {
    var res: Result = OK;
    var i: usize = 0;
    while (c.g_ascii_isspace(src.*[0])) src.* += 1;
    while (!c.g_ascii_isspace(src.*[0]) and src.*[0] != 0) : (src.* += 1) {
        if (i < dest.len - 1) {
            dest[i] = src.*[0];
            i += 1;
        } else res = c.GST_RTSP_EPARSE;
    }
    dest[i] = 0;
    return res;
}

fn protocolVersion(proto: [*c]u8, kind: *c.GstRTSPMsgType, version: *c.GstRTSPVersion) Result {
    const slash = c.strchr(proto, '/');
    if (slash == null) return c.GST_RTSP_EPARSE;
    slash[0] = 0;
    var major: c.guint = 0;
    var minor: c.guint = 0;
    var dummy: u8 = 0;
    var res: Result = OK;
    if (c.sscanf(slash + 1, "%u.%u%c", &major, &minor, &dummy) != 2) res = c.GST_RTSP_EPARSE;
    const v: c.GstRTSPVersion = @intCast(major *% 0x10 +% minor);
    if (c.g_ascii_strcasecmp(proto, "RTSP") == 0) {
        if (v != c.GST_RTSP_VERSION_1_0 and v != c.GST_RTSP_VERSION_2_0) {
            version.* = c.GST_RTSP_VERSION_INVALID;
            res = c.GST_RTSP_ERROR;
        }
    } else if (c.g_ascii_strcasecmp(proto, "HTTP") == 0) {
        if (kind.* == c.GST_RTSP_MESSAGE_REQUEST) {
            kind.* = c.GST_RTSP_MESSAGE_HTTP_REQUEST;
        } else if (kind.* == c.GST_RTSP_MESSAGE_RESPONSE) kind.* = c.GST_RTSP_MESSAGE_HTTP_RESPONSE;
        if (v != c.GST_RTSP_VERSION_1_0 and v != c.GST_RTSP_VERSION_1_1 and v != c.GST_RTSP_VERSION_2_0) res = c.GST_RTSP_ERROR;
    } else res = c.GST_RTSP_EPARSE;
    if (res == OK) version.* = v;
    return res;
}

fn responseStatus(buf: [*c]u8, mp: [*c]Msg) Result {
    const m: [*]Msg = @ptrCast(mp);
    var res: Result = OK;
    var ver: [20]u8 = undefined;
    var code_text: [4]u8 = undefined;
    var p: [*c]u8 = buf;
    if (parseString(&ver, &p) != OK) res = c.GST_RTSP_EPARSE;
    if (parseString(&code_text, &p) != OK) res = c.GST_RTSP_EPARSE;
    const code = c.atoi(&code_text);
    if (code_text[0] == 0 or code < 0 or code >= 600) res = c.GST_RTSP_EPARSE;
    while (c.g_ascii_isspace(p[0])) p += 1;
    if (msgs.gst_rtsp_message_init_response(m, @bitCast(code), p, null) != OK) res = c.GST_RTSP_EPARSE;
    const r2 = protocolVersion(&ver, &m[0].type, &m[0].type_data.response.version);
    return if (res == OK) r2 else res;
}

fn requestLine(buf: [*c]u8, mp: [*c]Msg) Result {
    const m: [*]Msg = @ptrCast(mp);
    var res: Result = OK;
    var ver: [20]u8 = undefined;
    var method_text: [20]u8 = undefined;
    var url: [4096]u8 = undefined;
    var p: [*c]u8 = buf;
    if (parseString(&method_text, &p) != OK) res = c.GST_RTSP_EPARSE;
    const method = defs.gst_rtsp_find_method(&method_text);
    if (parseString(&url, &p) != OK) res = c.GST_RTSP_EPARSE;
    if (url[0] == 0) res = c.GST_RTSP_EPARSE;
    if (parseString(&ver, &p) != OK) res = c.GST_RTSP_EPARSE;
    if (p[0] != 0) res = c.GST_RTSP_EPARSE;
    if (msgs.gst_rtsp_message_init_request(m, method, &url) != OK) res = c.GST_RTSP_EPARSE;
    const r2 = protocolVersion(&ver, &m[0].type, &m[0].type_data.request.version);
    if (res == OK) res = r2;
    const rq = &m[0].type_data.request;
    const http = rq.method == c.GST_RTSP_GET or rq.method == c.GST_RTSP_POST;
    if ((m[0].type == c.GST_RTSP_MESSAGE_REQUEST and http) or (m[0].type == c.GST_RTSP_MESSAGE_HTTP_REQUEST and !http)) {
        rq.method = c.GST_RTSP_INVALID;
        if (res == OK) res = c.GST_RTSP_ERROR;
    }
    return res;
}

fn parseLine(buf: [*c]u8, m: [*c]Msg) Result {
    const line = buf;
    var value: [*c]u8 = c.strchr(line, ':');
    if (value == null or value == line) return c.GST_RTSP_EPARSE;
    if ((value - 1)[0] == ' ') (value - 1)[0] = 0;
    value[0] = 0;
    value += 1;
    const field = defs.gst_rtsp_find_header_field(line);
    const auth = field == c.GST_RTSP_HDR_PROXY_AUTHENTICATE or field == c.GST_RTSP_HDR_WWW_AUTHENTICATE;
    while (value[0] != 0) {
        if (value[0] == ' ') value += 1;
        var next: [*c]u8 = if (defs.gst_rtsp_header_allow_multiple(field) == 0) value + std.mem.len(value) else value;
        var comma: [*c]u8 = null;
        var quoted = false;
        var comment: c.guint = 0;
        while (next[0] != 0) : (next += 1) {
            if ((quoted or comment != 0) and next[0] == '\\' and next[1] != 0) {
                next += 1;
            } else if (comment == 0 and next[0] == '"') {
                quoted = !quoted;
            } else if (!quoted and next[0] == '(') {
                comment += 1;
            } else if (comment != 0 and next[0] == ')') {
                comment -= 1;
            } else if (!quoted and comment == 0) {
                if (auth) {
                    if (next[0] == ',') {
                        if (next[1] == ' ') next += 1;
                        comma = next;
                    } else if (next[0] == ' ' and next[1] != ',' and next[1] != '=' and comma != null) {
                        var cur = next;
                        while (cur[0] != 0) : (cur += 1) {
                            if (!c.g_ascii_isspace(cur[0])) {
                                next = comma;
                                comma = null;
                                break;
                            }
                        }
                        break;
                    }
                } else if (next[0] == ',') break;
            }
        }
        if (m[0].type == c.GST_RTSP_MESSAGE_REQUEST and field == c.GST_RTSP_HDR_SESSION) {
            next = value;
            while (next[0] != 0 and next[0] != ';') next += 1;
        }
        if (value != next and (next - 1)[0] == ' ') (next - 1)[0] = 0;
        if (next[0] != 0) {
            next[0] = 0;
            next += 1;
        }
        if (value[0] != 0) {
            if (field != c.GST_RTSP_HDR_INVALID) {
                _ = msgs.gst_rtsp_message_add_header(m, field, value);
            } else _ = msgs.gst_rtsp_message_add_header_by_name(m, line, value);
        }
        value = next;
    }
    return OK;
}

fn normalizeLine(buf: [*c]u8) void {
    var p = buf;
    while (p[0] != 0) {
        if (!c.g_ascii_isspace(p[0])) {
            p += 1;
            continue;
        }
        p[0] = ' ';
        p += 1;
        var t = p;
        while (c.g_ascii_isspace(t[0])) t += 1;
        if (t != p) {
            const n = std.mem.len(t) + 1;
            std.mem.copyForwards(u8, p[0..n], t[0..n]);
        }
    }
}

fn cseqValid(conn: *Conn, m: [*c]Msg) Result {
    if (m[0].type != c.GST_RTSP_MESSAGE_RESPONSE and m[0].type != c.GST_RTSP_MESSAGE_REQUEST) return OK;
    var h: [*c]u8 = null;
    if (msgs.gst_rtsp_message_get_header(m, c.GST_RTSP_HDR_CSEQ, &h, 0) != OK) return c.GST_RTSP_EPARSE;
    std.c._errno().* = 0;
    const v = c.g_ascii_strtoll(h, null, 10);
    if (std.c._errno().* != 0 or v < 0) return c.GST_RTSP_EPARSE;
    if (m[0].type == c.GST_RTSP_MESSAGE_RESPONSE and (conn.cseq == 0 or conn.cseq < v)) return c.GST_RTSP_EPARSE;
    return OK;
}

const S_START = 0;
const S_DATA_HEADER = 1;
const S_DATA_BODY = 2;
const S_READ_LINES = 3;
const S_END = 4;

const Builder = extern struct {
    state: c.gint = S_START,
    status: Result = OK,
    buffer: [4096]u8 = [_]u8{0} ** 4096,
    offset: c.guint = 0,
    line: c.guint = 0,
    body_data: [*c]u8 = null,
    body_len: c.guint = 0,

    fn reset(b: *Builder) void {
        c.g_free(b.body_data);
        b.* = .{};
    }
};

fn sessionFrom(conn: *Conn, id: [*c]const u8) void {
    var maxlen: usize = conn.session_id.len - 1;
    var i: usize = 0;
    while (i < maxlen and id[i] != 0) : (i += 1) {
        if (id[i] != ';') continue;
        maxlen = i;
        i += 1;
        while (c.g_ascii_isspace(id[i])) i += 1;
        if (c.g_str_has_prefix(id + i, "timeout=") != 0) {
            const to = c.atoi(id + i + 8);
            if (to > 0) conn.timeout = to;
        }
        break;
    }
    if (conn.remember_session_id) {
        _ = c.strncpy(&conn.session_id, id, maxlen);
        conn.session_id[maxlen] = 0;
    }
}

fn buildNext(b: *Builder, m: [*c]Msg, conn: *Conn, block: bool) Result {
    const res = buildLoop(b, m, conn, block);
    conn.may_cancel = true;
    return res;
}

fn buildLoop(b: *Builder, m: [*c]Msg, conn: *Conn, block: bool) Result {
    while (true) {
        switch (b.state) {
            S_START => {
                b.offset = 0;
                const r = readBytes(conn, &b.buffer, &b.offset, 1, block);
                if (r != OK) return r;
                const ch = b.buffer[0];
                if (ch == '$') {
                    b.state = S_DATA_HEADER;
                    conn.may_cancel = false;
                } else if (ch == '\n' or ch == '\r') {
                    b.offset = 0;
                } else {
                    b.line = 0;
                    b.state = S_READ_LINES;
                    conn.may_cancel = false;
                }
            },
            S_DATA_HEADER => {
                const r = readBytes(conn, &b.buffer, &b.offset, 4, block);
                if (r != OK) return r;
                _ = msgs.gst_rtsp_message_init_data(m, b.buffer[1]);
                b.body_len = (@as(c.guint, b.buffer[2]) << 8) | b.buffer[3];
                b.body_data = @ptrCast(c.g_malloc(b.body_len + 1));
                b.body_data[b.body_len] = 0;
                b.offset = 0;
                b.state = S_DATA_BODY;
            },
            S_DATA_BODY => {
                const r = readBytes(conn, b.body_data, &b.offset, b.body_len, block);
                if (r != OK) return r;
                _ = msgs.gst_rtsp_message_take_body(m, b.body_data, b.body_len + 1);
                b.body_data = null;
                b.body_len = 0;
                b.state = S_END;
            },
            S_READ_LINES => {
                var r = readLine(conn, &b.buffer, &b.offset, b.buffer.len, block);
                if (r != OK) return r;
                if (b.buffer[0] == 0) {
                    var hv: [*c]u8 = null;
                    const has_len = msgs.gst_rtsp_message_get_header(m, c.GST_RTSP_HDR_CONTENT_LENGTH, &hv, 0) == OK;
                    const tunnel_post = m[0].type == c.GST_RTSP_MESSAGE_HTTP_REQUEST and m[0].type_data.request.method == c.GST_RTSP_POST and msgs.gst_rtsp_message_get_header(m, c.GST_RTSP_HDR_X_SESSIONCOOKIE, null, 0) == OK;
                    if (has_len and !tunnel_post) {
                        std.c._errno().* = 0;
                        const len = c.g_ascii_strtoll(hv, null, 10);
                        if (std.c._errno().* != 0 or len < 0) return c.GST_RTSP_EPARSE;
                        if (len > conn.content_length_limit) return c.GST_RTSP_ENOMEM;
                        b.body_len = @intCast(len);
                        b.body_data = @ptrCast(c.g_try_malloc(@as(usize, b.body_len) + 1));
                        if (b.body_data == null) return c.GST_RTSP_ENOMEM;
                        b.body_data[b.body_len] = 0;
                        b.offset = 0;
                        b.state = S_DATA_BODY;
                    } else b.state = S_END;
                    continue;
                }
                normalizeLine(&b.buffer);
                if (b.line == 0) {
                    const head = b.buffer[0..4];
                    b.status = if (std.mem.eql(u8, head, "RTSP") or std.mem.eql(u8, head, "HTTP")) responseStatus(&b.buffer, m) else requestLine(&b.buffer, m);
                } else {
                    r = parseLine(&b.buffer, m);
                    if (r != OK) b.status = r;
                }
                if (b.status != OK) return b.status;
                b.line += 1;
                b.offset = 0;
            },
            S_END => {
                conn.may_cancel = true;
                const r = cseqValid(conn, m);
                if (r != OK) return r;
                if (m[0].type == c.GST_RTSP_MESSAGE_DATA) return OK;
                var cookie: [*c]u8 = null;
                if (m[0].type == c.GST_RTSP_MESSAGE_HTTP_REQUEST and !conn.manual_http and conn.tstate == .none and msgs.gst_rtsp_message_get_header(m, c.GST_RTSP_HDR_X_SESSIONCOOKIE, &cookie, 0) == OK) {
                    _ = c.strncpy(&conn.tunnelid, cookie, TUNNELID_LEN);
                    conn.tunnelid[TUNNELID_LEN - 1] = 0;
                    conn.tunneled = true;
                }
                var sid: [*c]u8 = null;
                if (m[0].type == c.GST_RTSP_MESSAGE_RESPONSE and msgs.gst_rtsp_message_get_header(m, c.GST_RTSP_HDR_SESSION, &sid, 0) == OK) sessionFrom(conn, sid);
                return b.status;
            },
            else => return c.GST_RTSP_ERROR,
        }
    }
}

pub export fn gst_rtsp_connection_read_usec(h: ?*c.GstRTSPConnection, data: [*c]u8, size: c.guint, timeout: c.gint64) Result {
    const f = "gst_rtsp_connection_read_usec";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    if (!that(data != null, f, "data != NULL")) return EINVAL;
    const conn = of(h);
    if (!that(conn.read_socket != null, f, "conn->read_socket != NULL")) return EINVAL;
    if (size == 0) return OK;
    var off: c.guint = 0;
    useSocket(conn, true, timeout);
    const r = readBytes(conn, data, &off, size, true);
    releaseSocket(conn, true);
    return r;
}

fn tunnelReply(conn: *Conn, status: c.GstRTSPStatusCode, req: [*c]const Msg) [*c]Msg {
    const code: c.GstRTSPStatusCode = if (defs.gst_rtsp_status_as_text(status) == null) c.GST_RTSP_STS_INTERNAL_SERVER_ERROR else status;
    var m: [*c]Msg = null;
    if (msgs.gst_rtsp_message_new_response(&m, code, null, req) != OK) return null;
    const add = msgs.gst_rtsp_message_add_header;
    _ = add(m, c.GST_RTSP_HDR_SERVER, "GStreamer RTSP Server");
    _ = add(m, c.GST_RTSP_HDR_CONNECTION, "close");
    _ = add(m, c.GST_RTSP_HDR_CACHE_CONTROL, "no-store");
    _ = add(m, c.GST_RTSP_HDR_PRAGMA, "no-cache");
    if (code == c.GST_RTSP_STS_OK) {
        if (conn.local_ip != null) _ = add(m, c.GST_RTSP_HDR_X_SERVER_IP_ADDRESS, conn.local_ip);
        _ = add(m, c.GST_RTSP_HDR_CONTENT_TYPE, "application/x-rtsp-tunnelled");
    }
    return m;
}

pub export fn gst_rtsp_connection_receive_usec(h: ?*c.GstRTSPConnection, m: [*c]Msg, timeout: c.gint64) Result {
    const f = "gst_rtsp_connection_receive_usec";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    if (!that(m != null, f, "message != NULL")) return EINVAL;
    const conn = of(h);
    if (!that(conn.read_socket != null, f, "conn->read_socket != NULL")) return EINVAL;
    useSocket(conn, true, timeout);
    var b = Builder{};
    var res = buildNext(&b, m, conn, true);
    releaseSocket(conn, true);
    if (res == OK and !conn.manual_http) {
        if (m[0].type == c.GST_RTSP_MESSAGE_HTTP_REQUEST) {
            const method = m[0].type_data.request.method;
            if (conn.tstate == .none and method == c.GST_RTSP_GET) {
                conn.tstate = .get;
                const reply = tunnelReply(conn, c.GST_RTSP_STS_OK, m);
                res = gst_rtsp_connection_send_usec(h, reply, timeout);
                _ = msgs.gst_rtsp_message_free(reply);
                if (res == OK) res = c.GST_RTSP_ETGET;
            } else if (conn.tstate == .none and method == c.GST_RTSP_POST) {
                conn.tstate = .post;
                res = c.GST_RTSP_ETPOST;
            } else res = c.GST_RTSP_EPARSE;
        } else if (m[0].type == c.GST_RTSP_MESSAGE_HTTP_RESPONSE) res = c.GST_RTSP_EPARSE;
    }
    b.reset();
    if (res != OK) _ = msgs.gst_rtsp_message_unset(m);
    return res;
}

pub export fn gst_rtsp_connection_close(h: ?*c.GstRTSPConnection) Result {
    if (!that(h != null, "gst_rtsp_connection_close", "conn != NULL")) return EINVAL;
    const conn = of(h);
    if (conn.stream0 != null) {
        c.g_object_unref(conn.stream0);
        conn.stream0 = null;
        conn.socket0 = null;
    }
    if (conn.stream1 != null) {
        c.g_object_unref(conn.stream1);
        conn.stream1 = null;
        conn.socket1 = null;
    }
    conn.input = null;
    conn.output = null;
    conn.control = null;
    c.g_free(conn.remote_ip);
    conn.remote_ip = null;
    c.g_free(conn.local_ip);
    conn.local_ip = null;
    conn.read_ahead = 0;
    c.g_free(conn.initial);
    conn.initial = null;
    conn.initial_offset = 0;
    conn.write_socket = null;
    conn.read_socket = null;
    conn.write_used = false;
    conn.read_used = false;
    conn.tunneled = false;
    conn.tstate = .none;
    conn.ctxp = null;
    c.g_free(conn.username);
    conn.username = null;
    c.g_free(conn.passwd);
    conn.passwd = null;
    gst_rtsp_connection_clear_auth_params(h);
    conn.timeout = 60;
    conn.cseq = 0;
    conn.session_id[0] = 0;
    return OK;
}

pub export fn gst_rtsp_connection_free(h: ?*c.GstRTSPConnection) Result {
    if (!that(h != null, "gst_rtsp_connection_free", "conn != NULL")) return EINVAL;
    const conn = of(h);
    const res = gst_rtsp_connection_close(h);
    c.g_mutex_lock(&conn.cancel_lock);
    drop(conn.cancellable);
    conn.cancellable = null;
    c.g_mutex_unlock(&conn.cancel_lock);
    c.g_mutex_clear(&conn.cancel_lock);
    drop(conn.client);
    drop(conn.tls_database);
    drop(conn.tls_interaction);
    if (conn.accept_notify) |n| n(conn.accept_data);
    c.g_timer_destroy(conn.timer);
    urls.gst_rtsp_url_free(conn.url);
    c.g_free(conn.proxy_host);
    for (extras(conn)) |e| {
        c.g_free(e.key);
        c.g_free(e.value);
    }
    _ = c.g_array_free(conn.extra, 1);
    c.g_free(conn);
    return res;
}

pub export fn gst_rtsp_connection_poll_usec(h: ?*c.GstRTSPConnection, events: c.GstRTSPEvent, revents: [*c]c.GstRTSPEvent, timeout: c.gint64) Result {
    const f = "gst_rtsp_connection_poll_usec";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    if (!that(events != 0, f, "events != 0")) return EINVAL;
    if (!that(revents != null, f, "revents != NULL")) return EINVAL;
    const conn = of(h);
    if (!that(conn.read_socket != null, f, "conn->read_socket != NULL")) return EINVAL;
    if (!that(conn.write_socket != null, f, "conn->write_socket != NULL")) return EINVAL;
    const ctx = c.g_main_context_new();
    if (timeout != 0) {
        const ts = c.g_timeout_source_new(@intCast(@divTrunc(timeout, 1000)));
        c.g_source_set_dummy_callback(ts);
        _ = c.g_source_attach(ts, ctx);
        c.g_source_unref(ts);
    }
    const cc = cancellable(conn);
    if (events & c.GST_RTSP_EV_READ != 0) {
        const rs = c.g_socket_create_source(conn.read_socket, c.G_IO_IN | c.G_IO_PRI, cc);
        c.g_source_set_dummy_callback(rs);
        _ = c.g_source_attach(rs, ctx);
        c.g_source_unref(rs);
    }
    if (events & c.GST_RTSP_EV_WRITE != 0) {
        const ws = c.g_socket_create_source(conn.write_socket, c.G_IO_OUT, cc);
        c.g_source_set_dummy_callback(ws);
        _ = c.g_source_attach(ws, ctx);
        c.g_source_unref(ws);
    }
    drop(cc);
    while (c.g_main_context_iteration(ctx, 1) == 0) {}
    c.g_main_context_unref(ctx);
    revents.* = 0;
    if (events & c.GST_RTSP_EV_READ != 0 and c.g_socket_condition_check(conn.read_socket, c.G_IO_IN | c.G_IO_PRI) & (c.G_IO_IN | c.G_IO_PRI) != 0) revents.* |= c.GST_RTSP_EV_READ;
    if (events & c.GST_RTSP_EV_WRITE != 0 and c.g_socket_condition_check(conn.write_socket, c.G_IO_OUT) & c.G_IO_OUT != 0) revents.* |= c.GST_RTSP_EV_WRITE;
    return if (revents.* == 0) c.GST_RTSP_ETIMEOUT else OK;
}

pub export fn gst_rtsp_connection_next_timeout_usec(h: ?*c.GstRTSPConnection) c.gint64 {
    if (!that(h != null, "gst_rtsp_connection_next_timeout_usec", "conn != NULL")) return 1;
    const conn = of(h);
    var ct = conn.timeout;
    if (ct >= 20) {
        ct -= 5;
    } else if (ct >= 5) {
        ct -= @divTrunc(ct, 5);
    } else if (ct >= 1) ct -= 1;
    var usec: c.gulong = 0;
    const elapsed = c.g_timer_elapsed(conn.timer, &usec);
    if (elapsed >= @as(f64, @floatFromInt(ct))) return 0;
    const sec: i64 = @intFromFloat(@as(f64, @floatFromInt(ct)) - elapsed);
    usec = if (usec <= c.G_USEC_PER_SEC) c.G_USEC_PER_SEC - usec else 0;
    return @as(i64, @intCast(usec)) + sec * c.G_USEC_PER_SEC;
}

pub export fn gst_rtsp_connection_reset_timeout(h: ?*c.GstRTSPConnection) Result {
    if (!that(h != null, "gst_rtsp_connection_reset_timeout", "conn != NULL")) return EINVAL;
    c.g_timer_start(of(h).timer);
    return OK;
}

pub export fn gst_rtsp_connection_flush(h: ?*c.GstRTSPConnection, flush: c.gboolean) Result {
    if (!that(h != null, "gst_rtsp_connection_flush", "conn != NULL")) return EINVAL;
    const conn = of(h);
    if (flush != 0) {
        const cc = cancellable(conn);
        c.g_cancellable_cancel(cc);
        drop(cc);
    } else {
        c.g_mutex_lock(&conn.cancel_lock);
        drop(conn.cancellable);
        conn.cancellable = c.g_cancellable_new();
        c.g_mutex_unlock(&conn.cancel_lock);
    }
    return OK;
}

pub export fn gst_rtsp_connection_set_proxy(h: ?*c.GstRTSPConnection, host: [*c]const u8, port: c.guint) Result {
    if (!that(h != null, "gst_rtsp_connection_set_proxy", "conn != NULL")) return EINVAL;
    c.g_free(of(h).proxy_host);
    of(h).proxy_host = c.g_strdup(host);
    of(h).proxy_port = port;
    return OK;
}

pub export fn gst_rtsp_connection_set_auth(h: ?*c.GstRTSPConnection, method: c.GstRTSPAuthMethod, user: [*c]const u8, pass: [*c]const u8) Result {
    if (!that(h != null, "gst_rtsp_connection_set_auth", "conn != NULL")) return EINVAL;
    const colon = struct {
        fn f(s: [*c]const u8) bool {
            return c.g_strrstr(s, ":") != null;
        }
    }.f;
    if (method == c.GST_RTSP_AUTH_DIGEST and (user == null or pass == null or colon(user))) return EINVAL;
    if (method == c.GST_RTSP_AUTH_NONE and (user == null or pass == null)) return EINVAL;
    if (method == c.GST_RTSP_AUTH_BASIC and colon(user)) return EINVAL;
    const conn = of(h);
    c.g_free(conn.username);
    c.g_free(conn.passwd);
    conn.auth_method = method;
    conn.username = c.g_strdup(user);
    conn.passwd = c.g_strdup(pass);
    return OK;
}

fn caseHash(key: c.gconstpointer) callconv(.c) c.guint {
    const p: [*c]const u8 = @ptrCast(key);
    var h: c.guint = c.g_ascii_toupper(p[0]);
    if (h != 0) {
        var i: usize = 1;
        while (p[i] != 0) : (i += 1) h = (h << 5) -% h +% c.g_ascii_toupper(p[i]);
    }
    return h;
}

fn caseEqual(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gboolean {
    return @intFromBool(c.g_ascii_strcasecmp(@ptrCast(a), @ptrCast(b)) == 0);
}

pub export fn gst_rtsp_connection_set_auth_param(h: ?*c.GstRTSPConnection, param: [*c]const u8, value: [*c]const u8) void {
    const f = "gst_rtsp_connection_set_auth_param";
    if (!that(h != null, f, "conn != NULL")) return;
    if (!that(param != null, f, "param != NULL")) return;
    const conn = of(h);
    if (conn.auth_params == null) conn.auth_params = c.g_hash_table_new_full(caseHash, caseEqual, c.g_free, c.g_free);
    _ = c.g_hash_table_insert(conn.auth_params, c.g_strdup(param), c.g_strdup(value));
}

pub export fn gst_rtsp_connection_clear_auth_params(h: ?*c.GstRTSPConnection) void {
    if (!that(h != null, "gst_rtsp_connection_clear_auth_params", "conn != NULL")) return;
    const conn = of(h);
    if (conn.auth_params != null) {
        c.g_hash_table_destroy(conn.auth_params);
        conn.auth_params = null;
    }
}

extern fn getsockname(fd: c_int, addr: *anyopaque, len: *c.socklen_t) c_int;

fn qos(sock: ?*c.GSocket, dscp: c.guint) Result {
    if (sock == null) return OK;
    const fd = c.g_socket_get_fd(sock);
    var sa = std.mem.zeroes(c.struct_sockaddr_storage);
    var len: c.socklen_t = @sizeOf(c.struct_sockaddr_storage);
    if (getsockname(fd, @ptrCast(&sa), &len) < 0) return c.GST_RTSP_ESYS;
    var af: c_int = sa.ss_family;
    if (af == c.AF_INET6) {
        const s6: *c.struct_sockaddr_in6 = @ptrCast(@alignCast(&sa));
        const b = @as(*const [16]u8, @ptrCast(&s6.sin6_addr));
        if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) af = c.AF_INET;
    }
    const tos: c_int = @intCast((dscp & 0x3f) << 2);
    const r = switch (af) {
        c.AF_INET => c.setsockopt(fd, c.IPPROTO_IP, c.IP_TOS, &tos, @sizeOf(c_int)),
        c.AF_INET6 => c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_TCLASS, &tos, @sizeOf(c_int)),
        else => return c.GST_RTSP_ERROR,
    };
    return if (r < 0) c.GST_RTSP_ESYS else OK;
}

pub export fn gst_rtsp_connection_set_qos_dscp(h: ?*c.GstRTSPConnection, dscp: c.guint) Result {
    const f = "gst_rtsp_connection_set_qos_dscp";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    const conn = of(h);
    if (!that(conn.read_socket != null, f, "conn->read_socket != NULL")) return EINVAL;
    if (!that(conn.write_socket != null, f, "conn->write_socket != NULL")) return EINVAL;
    const r = qos(conn.socket0, dscp);
    return if (r == OK) qos(conn.socket1, dscp) else r;
}

pub export fn gst_rtsp_connection_set_content_length_limit(h: ?*c.GstRTSPConnection, limit: c.guint) void {
    if (!that(h != null, "gst_rtsp_connection_set_content_length_limit", "conn != NULL")) return;
    of(h).content_length_limit = limit;
}

pub export fn gst_rtsp_connection_get_url(h: ?*const c.GstRTSPConnection) [*c]c.GstRTSPUrl {
    if (!that(h != null, "gst_rtsp_connection_get_url", "conn != NULL")) return null;
    return of(h).url;
}

pub export fn gst_rtsp_connection_get_ip(h: ?*const c.GstRTSPConnection) [*c]const u8 {
    if (!that(h != null, "gst_rtsp_connection_get_ip", "conn != NULL")) return null;
    return of(h).remote_ip;
}

pub export fn gst_rtsp_connection_set_ip(h: ?*c.GstRTSPConnection, ip: [*c]const u8) void {
    if (!that(h != null, "gst_rtsp_connection_set_ip", "conn != NULL")) return;
    c.g_free(of(h).remote_ip);
    of(h).remote_ip = c.g_strdup(ip);
}

pub export fn gst_rtsp_connection_get_read_socket(h: ?*const c.GstRTSPConnection) ?*c.GSocket {
    const f = "gst_rtsp_connection_get_read_socket";
    if (!that(h != null, f, "conn != NULL")) return null;
    if (!that(of(h).read_socket != null, f, "conn->read_socket != NULL")) return null;
    return of(h).read_socket;
}

pub export fn gst_rtsp_connection_get_write_socket(h: ?*const c.GstRTSPConnection) ?*c.GSocket {
    const f = "gst_rtsp_connection_get_write_socket";
    if (!that(h != null, f, "conn != NULL")) return null;
    if (!that(of(h).write_socket != null, f, "conn->write_socket != NULL")) return null;
    return of(h).write_socket;
}

pub export fn gst_rtsp_connection_set_http_mode(h: ?*c.GstRTSPConnection, enable: c.gboolean) void {
    if (!that(h != null, "gst_rtsp_connection_set_http_mode", "conn != NULL")) return;
    of(h).manual_http = enable != 0;
}

pub export fn gst_rtsp_connection_set_tunneled(h: ?*c.GstRTSPConnection, tunneled: c.gboolean) void {
    const f = "gst_rtsp_connection_set_tunneled";
    if (!that(h != null, f, "conn != NULL")) return;
    if (!that(of(h).read_socket == null, f, "conn->read_socket == NULL")) return;
    if (!that(of(h).write_socket == null, f, "conn->write_socket == NULL")) return;
    of(h).tunneled = tunneled != 0;
}

pub export fn gst_rtsp_connection_is_tunneled(h: ?*const c.GstRTSPConnection) c.gboolean {
    if (!that(h != null, "gst_rtsp_connection_is_tunneled", "conn != NULL")) return 0;
    return @intFromBool(of(h).tunneled);
}

pub export fn gst_rtsp_connection_get_tunnelid(h: ?*const c.GstRTSPConnection) [*c]const u8 {
    if (!that(h != null, "gst_rtsp_connection_get_tunnelid", "conn != NULL")) return null;
    if (!of(h).tunneled) return null;
    return &of(h).tunnelid;
}

pub export fn gst_rtsp_connection_set_ignore_x_server_reply(h: ?*c.GstRTSPConnection, ignore: c.gboolean) void {
    if (!that(h != null, "gst_rtsp_connection_set_ignore_x_server_reply", "conn != NULL")) return;
    of(h).ignore_x_server_reply = ignore != 0;
}

pub export fn gst_rtsp_connection_get_ignore_x_server_reply(h: ?*const c.GstRTSPConnection) c.gboolean {
    if (!that(h != null, "gst_rtsp_connection_get_ignore_x_server_reply", "conn != NULL")) return 0;
    return @intFromBool(of(h).ignore_x_server_reply);
}

pub export fn gst_rtsp_connection_add_extra_http_request_header(h: ?*c.GstRTSPConnection, key: [*c]const u8, value: [*c]const u8) void {
    var e = Extra{ .key = c.g_strdup(key), .value = c.g_strdup(value) };
    _ = c.g_array_append_vals(of(h).extra, &e, 1);
}

pub export fn gst_rtsp_connection_do_tunnel(h: ?*c.GstRTSPConnection, h2: ?*c.GstRTSPConnection) Result {
    const f = "gst_rtsp_connection_do_tunnel";
    if (!that(h != null, f, "conn != NULL")) return EINVAL;
    const conn = of(h);
    if (h2 != null) {
        const other = of(h2);
        const t1 = conn.tstate;
        const t2 = other.tstate;
        if (!that((t1 == .get and t2 == .post) or (t1 == .post and t2 == .get), f, "(ts1 == TUNNEL_STATE_GET && ts2 == TUNNEL_STATE_POST) || (ts1 == TUNNEL_STATE_POST && ts2 == TUNNEL_STATE_GET)")) return EINVAL;
        if (!that(std.mem.eql(u8, &conn.tunnelid, &other.tunnelid), f, "!memcmp (conn2->tunnelid, conn->tunnelid, TUNNELID_LEN)")) return EINVAL;
        if (t1 == .get) {
            conn.socket1 = other.socket0;
            conn.stream1 = other.stream0;
            conn.input = other.input;
            conn.control = c.g_io_stream_get_input_stream(conn.stream0);
            other.output = null;
        } else {
            conn.socket1 = conn.socket0;
            conn.stream1 = conn.stream0;
            conn.socket0 = other.socket0;
            conn.stream0 = other.stream0;
            conn.output = other.output;
            conn.control = c.g_io_stream_get_input_stream(conn.stream0);
        }
        c.g_mutex_lock(&other.cancel_lock);
        c.g_cancellable_cancel(other.cancellable);
        other.write_socket = null;
        other.read_socket = null;
        other.socket0 = null;
        other.stream0 = null;
        other.socket1 = null;
        other.stream1 = null;
        other.input = null;
        other.control = null;
        drop(other.cancellable);
        other.cancellable = null;
        c.g_mutex_unlock(&other.cancel_lock);
        conn.write_socket = conn.socket0;
        conn.read_socket = conn.socket1;
        conn.tstate = .complete;
        c.g_free(conn.initial);
        conn.initial = other.initial;
        other.initial = null;
        conn.initial_offset = other.initial_offset;
    }
    conn.ctx = .{};
    conn.ctxp = &conn.ctx;
    return OK;
}

pub export fn gst_rtsp_connection_set_remember_session_id(h: ?*c.GstRTSPConnection, remember: c.gboolean) void {
    of(h).remember_session_id = remember != 0;
    if (remember == 0) of(h).session_id[0] = 0;
}

pub export fn gst_rtsp_connection_get_remember_session_id(h: ?*c.GstRTSPConnection) c.gboolean {
    return @intFromBool(of(h).remember_session_id);
}

const Watch = extern struct {
    source: c.GSource,
    conn: ?*c.GstRTSPConnection,
    builder: Builder,
    message: Msg,
    readsrc: [*c]c.GSource,
    writesrc: [*c]c.GSource,
    controlsrc: [*c]c.GSource,
    keep_running: c.gboolean,
    id: c.guint,
    lock: c.GMutex,
    messages: ?*c.GstVecDeque,
    messages_bytes: usize,
    messages_count: c.guint,
    max_bytes: usize,
    max_messages: c.guint,
    not_full: c.GCond,
    flushing: c.gboolean,
    funcs: c.GstRTSPWatchFuncs,
    user_data: c.gpointer,
    notify: c.GDestroyNotify,

    fn c_(w: *Watch) *Conn {
        return of(w.conn);
    }

    fn full(w: *Watch) bool {
        return (w.max_bytes != 0 and w.messages_bytes >= w.max_bytes) or (w.max_messages != 0 and w.messages_count >= w.max_messages);
    }

    fn src(w: *Watch) [*c]c.GSource {
        return &w.source;
    }

    fn removeChild(w: *Watch, slot: *[*c]c.GSource, guarded: bool) void {
        if (slot.* == null) return;
        if (!guarded or c.g_source_is_destroyed(w.src()) == 0) c.g_source_remove_child_source(w.src(), slot.*);
        c.g_source_unref(slot.*);
        slot.* = null;
    }

    fn addControl(w: *Watch) void {
        const ctl = w.c_().control;
        if (ctl == null) {
            w.controlsrc = null;
            return;
        }
        w.controlsrc = c.g_pollable_input_stream_create_source(@ptrCast(ctl), null);
        c.g_source_set_callback(w.controlsrc, @ptrCast(&readGetChannel), w, null);
        c.g_source_add_child_source(w.src(), w.controlsrc);
    }

    fn fail(w: *Watch, res: Result, m: [*c]Msg, id: c.guint) void {
        if (w.funcs.error_full) |f| {
            _ = f(@ptrCast(w), res, m, id, w.user_data);
        } else if (w.funcs.@"error") |f| _ = f(@ptrCast(w), res, w.user_data);
    }

    fn closed(w: *Watch) c.gboolean {
        if (w.funcs.closed) |f| _ = f(@ptrCast(w), w.user_data);
        w.keep_running = 0;
        return 0;
    }
};

fn wof(p: anytype) *Watch {
    return @ptrCast(@alignCast(p));
}

fn prepare(s: [*c]c.GSource, timeout: [*c]c.gint) callconv(.c) c.gboolean {
    const w = wof(s);
    if (w.c_().initial != null) return 1;
    timeout.* = w.c_().timeout *% 1000;
    return 0;
}

fn check(_: [*c]c.GSource) callconv(.c) c.gboolean {
    return 0;
}

fn readGetChannel(stream: ?*c.GPollableInputStream, data: c.gpointer) callconv(.c) c.gboolean {
    const w = wof(data);
    var buf: [1024]u8 = undefined;
    var err: [*c]c.GError = null;
    const n = c.g_pollable_input_stream_read_nonblocking(stream, &buf, buf.len, null, &err);
    if (n == 0) return w.closed();
    if (n < 0) {
        const benign = c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_WOULD_BLOCK) != 0 or c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_TIMED_OUT) != 0;
        c.g_clear_error(&err);
        if (benign) return 1;
        w.fail(c.GST_RTSP_ESYS, &w.message, 0);
        return w.closed();
    }
    return 1;
}

fn readDone(w: *Watch) c.gboolean {
    _ = msgs.gst_rtsp_message_unset(&w.message);
    w.builder.reset();
    return 1;
}

fn dispatchRead(stream: ?*c.GPollableInputStream, data: c.gpointer) callconv(.c) c.gboolean {
    const w = wof(data);
    const conn = w.c_();
    if (@as(?*c.GPollableInputStream, @ptrCast(conn.input)) != stream) return w.closed();
    var res = buildNext(&w.builder, &w.message, conn, false);
    if (res == c.GST_RTSP_EINTR) return 1;
    if (res == c.GST_RTSP_EEOF) {
        c.g_mutex_lock(&w.lock);
        w.removeChild(&w.readsrc, true);
        if (conn.stream1 != null) {
            c.g_object_unref(conn.stream1);
            conn.stream1 = null;
            conn.socket1 = null;
            conn.input = null;
        }
        c.g_mutex_unlock(&w.lock);
        if (conn.tstate != .complete) return w.closed();
        conn.tstate = .get;
        if (w.funcs.tunnel_lost) |f| res = f(@ptrCast(w), w.user_data);
        c.g_mutex_lock(&w.lock);
        if (conn.control != null and w.controlsrc == null) w.addControl();
        c.g_mutex_unlock(&w.lock);
        return readDone(w);
    }
    if (res != OK) {
        w.fail(res, &w.message, 0);
        return w.closed();
    }
    if (!conn.manual_http and w.message.type == c.GST_RTSP_MESSAGE_HTTP_REQUEST) {
        const method = w.message.type_data.request.method;
        if (conn.tstate == .none and method == c.GST_RTSP_GET) {
            conn.tstate = .get;
            const code = if (w.funcs.tunnel_start) |f| f(@ptrCast(w), w.user_data) else c.GST_RTSP_STS_OK;
            const reply = tunnelReply(conn, code, &w.message);
            if (w.funcs.tunnel_http_response) |f| _ = f(@ptrCast(w), &w.message, reply, w.user_data);
            _ = gst_rtsp_watch_send_message(@ptrCast(w), reply, null);
            _ = msgs.gst_rtsp_message_free(reply);
            return readDone(w);
        } else if (conn.tstate == .none and method == c.GST_RTSP_POST) {
            conn.tstate = .post;
            if (w.funcs.tunnel_complete) |f| _ = f(@ptrCast(w), w.user_data);
            return readDone(w);
        }
    }
    if (!conn.manual_http) {
        if (w.message.type == c.GST_RTSP_MESSAGE_HTTP_REQUEST) {
            w.message.type = c.GST_RTSP_MESSAGE_REQUEST;
            w.message.type_data.request.method = c.GST_RTSP_INVALID;
            if (w.message.type_data.request.version != c.GST_RTSP_VERSION_1_0) w.message.type_data.request.version = c.GST_RTSP_VERSION_INVALID;
            res = c.GST_RTSP_EPARSE;
        } else if (w.message.type == c.GST_RTSP_MESSAGE_HTTP_RESPONSE) {
            w.message.type = c.GST_RTSP_MESSAGE_RESPONSE;
            if (w.message.type_data.response.version != c.GST_RTSP_VERSION_1_0) w.message.type_data.response.version = c.GST_RTSP_VERSION_INVALID;
            res = c.GST_RTSP_EPARSE;
        }
    }
    if (res != OK) {
        w.fail(res, &w.message, 0);
        return w.closed();
    }
    if (w.funcs.message_received) |f| _ = f(@ptrCast(w), &w.message, w.user_data);
    return readDone(w);
}

fn dispatch(s: [*c]c.GSource, _: c.GSourceFunc, _: c.gpointer) callconv(.c) c.gboolean {
    const w = wof(s);
    const conn = w.c_();
    if (conn.initial != null) _ = dispatchRead(@ptrCast(conn.input), w);
    return w.keep_running;
}

fn queued(w: *Watch, i: usize) *Serialized {
    return @ptrCast(@alignCast(c.gst_vec_deque_peek_nth_struct(w.messages, @intCast(i))));
}

fn dispatchWrite(stream: ?*c.GPollableOutputStream, data: c.gpointer) callconv(.c) c.gboolean {
    const w = wof(data);
    const conn = w.c_();
    const al = std.heap.c_allocator;
    if (@as(?*c.GPollableOutputStream, @ptrCast(conn.output)) != stream or w.messages == null) return 0;
    c.g_mutex_lock(&w.lock);
    while (true) {
        if (@as(?*c.GPollableOutputStream, @ptrCast(conn.output)) != stream or w.messages == null) {
            c.g_mutex_unlock(&w.lock);
            return 0;
        }
        const n = c.gst_vec_deque_get_length(w.messages);
        if (n == 0) {
            if (w.writesrc != null) {
                w.removeChild(&w.writesrc, true);
                w.addControl();
            }
            break;
        }
        var list = al.alloc(Serialized, n) catch unreachable;
        defer al.free(list);
        for (0..n) |i| list[i] = queued(w, i).*;
        var vecs = std.ArrayList(c.GOutputVector).empty;
        defer vecs.deinit(al);
        var maps = std.ArrayList(c.GstMapInfo).empty;
        const want = vectorize(list, &vecs, &maps, true);
        var ids = std.ArrayList(c.guint).empty;
        defer ids.deinit(al);
        const cc = cancellable(conn);
        var written: usize = 0;
        const res = writevBytes(conn.output, vecs.items.ptr, vecs.items.len, &written, false, cc);
        drop(cc);
        unmapAll(&maps);
        if (written == want) {
            while (c.gst_vec_deque_get_length(w.messages) > 0) {
                const m: *Serialized = @ptrCast(@alignCast(c.gst_vec_deque_pop_head_struct(w.messages)));
                if (m.id != 0) ids.append(al, m.id) catch unreachable;
                m.clear();
            }
            w.messages_bytes -= written;
        } else if (written > 0) {
            var dropped: usize = 0;
            for (0..n) |i| {
                const m = queued(w, i);
                const head_left = m.data_size - m.data_offset;
                if (written >= head_left) {
                    written -= head_left;
                    w.messages_bytes -= head_left;
                    m.data_offset = m.data_size;
                    const body = m.bodySize();
                    if (written + m.body_offset >= body) {
                        written -= body - m.body_offset;
                        w.messages_bytes -= body - m.body_offset;
                        m.body_offset = body;
                        dropped += 1;
                        if (m.id != 0) ids.append(al, m.id) catch unreachable;
                        m.clear();
                    } else {
                        m.body_offset += @intCast(written);
                        w.messages_bytes -= written;
                        written = 0;
                    }
                } else {
                    m.data_offset += @intCast(written);
                    w.messages_bytes -= written;
                    written = 0;
                }
            }
            while (dropped > 0) : (dropped -= 1) _ = c.gst_vec_deque_pop_head_struct(w.messages);
            w.messages_bytes -= written;
        }
        if (!w.full()) c.g_cond_signal(&w.not_full);
        c.g_mutex_unlock(&w.lock);
        for (ids.items) |id| {
            w.messages_count -%= 1;
            if (w.funcs.message_sent) |f| _ = f(@ptrCast(w), id, w.user_data);
        }
        if (res == c.GST_RTSP_EINTR) return 1;
        if (res != OK) {
            if (w.funcs.error_full) |f| {
                for (0..c.gst_vec_deque_get_length(w.messages)) |i| {
                    const m = queued(w, i);
                    if (m.id != 0) _ = f(@ptrCast(w), res, null, m.id, w.user_data);
                }
            } else if (w.funcs.@"error") |f| _ = f(@ptrCast(w), res, w.user_data);
            return 0;
        }
        c.g_mutex_lock(&w.lock);
    }
    c.g_mutex_unlock(&w.lock);
    return 1;
}

fn finalize(s: [*c]c.GSource) callconv(.c) void {
    const w = wof(s);
    if (w.notify) |n| n(w.user_data);
    w.builder.reset();
    _ = msgs.gst_rtsp_message_unset(&w.message);
    while (c.gst_vec_deque_get_length(w.messages) > 0) {
        const m: *Serialized = @ptrCast(@alignCast(c.gst_vec_deque_pop_head_struct(w.messages)));
        m.clear();
    }
    c.gst_vec_deque_free(w.messages);
    w.messages = null;
    w.messages_bytes = 0;
    w.messages_count = 0;
    c.g_cond_clear(&w.not_full);
    if (w.readsrc != null) c.g_source_unref(w.readsrc);
    if (w.writesrc != null) c.g_source_unref(w.writesrc);
    if (w.controlsrc != null) c.g_source_unref(w.controlsrc);
    c.g_mutex_clear(&w.lock);
}

var source_funcs = c.GSourceFuncs{ .prepare = prepare, .check = check, .dispatch = dispatch, .finalize = finalize, .closure_callback = null, .closure_marshal = null };

pub export fn gst_rtsp_watch_new(h: ?*c.GstRTSPConnection, funcs: [*c]c.GstRTSPWatchFuncs, data: c.gpointer, notify: c.GDestroyNotify) ?*c.GstRTSPWatch {
    const f = "gst_rtsp_watch_new";
    if (!that(h != null, f, "conn != NULL")) return null;
    if (!that(funcs != null, f, "funcs != NULL")) return null;
    if (!that(of(h).read_socket != null, f, "conn->read_socket != NULL")) return null;
    if (!that(of(h).write_socket != null, f, "conn->write_socket != NULL")) return null;
    const w = wof(c.g_source_new(&source_funcs, @sizeOf(Watch)));
    w.conn = h;
    w.builder = .{};
    c.g_mutex_init(&w.lock);
    w.messages = c.gst_vec_deque_new_for_struct(@sizeOf(Serialized), 10);
    c.g_cond_init(&w.not_full);
    gst_rtsp_watch_reset(@ptrCast(w));
    w.keep_running = 1;
    w.flushing = 0;
    w.funcs = funcs[0];
    w.user_data = data;
    w.notify = notify;
    return @ptrCast(w);
}

pub export fn gst_rtsp_watch_reset(h: ?*c.GstRTSPWatch) void {
    const w = wof(h);
    c.g_mutex_lock(&w.lock);
    defer c.g_mutex_unlock(&w.lock);
    if (w.readsrc != null) {
        c.g_source_remove_child_source(w.src(), w.readsrc);
        c.g_source_unref(w.readsrc);
    }
    w.removeChild(&w.writesrc, false);
    w.removeChild(&w.controlsrc, false);
    const in = w.c_().input;
    if (in != null) {
        w.readsrc = c.g_pollable_input_stream_create_source(@ptrCast(in), null);
        c.g_source_set_callback(w.readsrc, @ptrCast(&dispatchRead), w, null);
        c.g_source_add_child_source(w.src(), w.readsrc);
    } else w.readsrc = null;
    w.addControl();
}

pub export fn gst_rtsp_watch_attach(h: ?*c.GstRTSPWatch, ctx: ?*c.GMainContext) c.guint {
    if (!that(h != null, "gst_rtsp_watch_attach", "watch != NULL")) return 0;
    return c.g_source_attach(@ptrCast(@alignCast(h)), ctx);
}

pub export fn gst_rtsp_watch_unref(h: ?*c.GstRTSPWatch) void {
    if (!that(h != null, "gst_rtsp_watch_unref", "watch != NULL")) return;
    c.g_source_unref(@ptrCast(@alignCast(h)));
}

pub export fn gst_rtsp_watch_set_send_backlog(h: ?*c.GstRTSPWatch, bytes: c.gsize, messages: c.guint) void {
    if (!that(h != null, "gst_rtsp_watch_set_send_backlog", "watch != NULL")) return;
    const w = wof(h);
    c.g_mutex_lock(&w.lock);
    w.max_bytes = bytes;
    w.max_messages = messages;
    if (!w.full()) c.g_cond_signal(&w.not_full);
    c.g_mutex_unlock(&w.lock);
}

pub export fn gst_rtsp_watch_get_send_backlog(h: ?*c.GstRTSPWatch, bytes: [*c]c.gsize, messages: [*c]c.guint) void {
    if (!that(h != null, "gst_rtsp_watch_get_send_backlog", "watch != NULL")) return;
    const w = wof(h);
    c.g_mutex_lock(&w.lock);
    if (bytes != null) bytes.* = w.max_bytes;
    if (messages != null) messages.* = w.max_messages;
    c.g_mutex_unlock(&w.lock);
}

fn writeSerialized(w: *Watch, all: []Serialized, id: [*c]c.guint) Result {
    const al = std.heap.c_allocator;
    var list = all;
    c.g_mutex_lock(&w.lock);
    if (w.flushing != 0) {
        c.g_mutex_unlock(&w.lock);
        for (list) |*m| m.clear();
        return c.GST_RTSP_EINTR;
    }
    var context: ?*c.GMainContext = null;
    var res: Result = OK;
    done: {
        if (c.gst_vec_deque_get_length(w.messages) == 0) {
            var vecs = std.ArrayList(c.GOutputVector).empty;
            defer vecs.deinit(al);
            var maps = std.ArrayList(c.GstMapInfo).empty;
            _ = vectorize(list, &vecs, &maps, false);
            const cc = cancellable(w.c_());
            var written: usize = 0;
            res = writevBytes(w.c_().output, vecs.items.ptr, vecs.items.len, &written, false, cc);
            drop(cc);
            unmapAll(&maps);
            if (res != c.GST_RTSP_EINTR) {
                if (id != null) id.* = 0;
                for (list) |*m| m.clear();
                break :done;
            }
            var dropped: usize = 0;
            for (list) |*m| {
                if (written >= m.data_size) {
                    m.data_offset = m.data_size;
                    written -= m.data_size;
                    const body = m.bodySize();
                    if (written >= body) {
                        m.body_offset = body;
                        written -= body;
                        dropped += 1;
                        m.clear();
                    } else {
                        m.body_offset = @intCast(written);
                        written = 0;
                    }
                } else {
                    m.data_offset = @intCast(written);
                    written = 0;
                }
            }
            list = list[dropped..];
        }
        if (w.full()) {
            c.g_mutex_unlock(&w.lock);
            for (list) |*m| m.clear();
            return c.GST_RTSP_ENOMEM;
        }
        for (list, 0..) |m, i| {
            var local = m;
            if (local.body_data != null) {
                local.body_data = @ptrCast(c.g_memdup2(local.body_data, local.body_data_size));
            } else if (local.body_buffer != null) _ = c.gst_mini_object_ref(@ptrCast(local.body_buffer));
            local.borrowed = 0;
            if (i == list.len - 1) {
                w.id +%= 1;
                if (w.id == 0) w.id = 1;
                local.id = w.id;
                if (id != null) id.* = local.id;
            } else local.id = 0;
            c.gst_vec_deque_push_tail_struct(w.messages, &local);
            w.messages_bytes += local.data_size - local.data_offset;
            w.messages_bytes += local.bodySize() - local.body_offset;
        }
        w.messages_count += 1;
        context = w.source.context;
        if (w.writesrc == null) {
            w.removeChild(&w.controlsrc, false);
            w.writesrc = c.g_pollable_output_stream_create_source(@ptrCast(w.c_().output), null);
            c.g_source_set_callback(w.writesrc, @ptrCast(&dispatchWrite), w, null);
            c.g_source_add_child_source(w.src(), w.writesrc);
        }
        res = OK;
    }
    c.g_mutex_unlock(&w.lock);
    if (context != null) c.g_main_context_wakeup(context);
    return res;
}

pub export fn gst_rtsp_watch_write_data(h: ?*c.GstRTSPWatch, data: [*c]const u8, size: c.guint, id: [*c]c.guint) Result {
    if (!that(h != null, "gst_rtsp_watch_write_serialized_messages", "watch != NULL")) return EINVAL;
    var one = [_]Serialized{.{ .data = @constCast(data), .data_size = size }};
    return writeSerialized(wof(h), &one, id);
}

pub export fn gst_rtsp_watch_send_message(h: ?*c.GstRTSPWatch, m: [*c]Msg, id: [*c]c.guint) Result {
    const f = "gst_rtsp_watch_send_message";
    if (!that(h != null, f, "watch != NULL")) return EINVAL;
    if (!that(m != null, f, "message != NULL")) return EINVAL;
    return gst_rtsp_watch_send_messages(h, m, 1, id);
}

pub export fn gst_rtsp_watch_send_messages(h: ?*c.GstRTSPWatch, ms: [*c]Msg, n: c.guint, id: [*c]c.guint) Result {
    const f = "gst_rtsp_watch_send_messages";
    if (!that(h != null, f, "watch != NULL")) return EINVAL;
    if (!that(ms != null or n == 0, f, "messages != NULL || n_messages == 0")) return EINVAL;
    const w = wof(h);
    const al = std.heap.c_allocator;
    const list = al.alloc(Serialized, n) catch unreachable;
    defer al.free(list);
    @memset(list, .{});
    for (list, 0..) |*s, i| {
        if (!serialize(w.c_(), &ms[i], s)) {
            for (list) |*x| x.clear();
            return EINVAL;
        }
    }
    return writeSerialized(w, list, id);
}

pub export fn gst_rtsp_watch_wait_backlog_usec(h: ?*c.GstRTSPWatch, timeout: c.gint64) Result {
    if (!that(h != null, "gst_rtsp_watch_wait_backlog_usec", "watch != NULL")) return EINVAL;
    const w = wof(h);
    const end = c.g_get_monotonic_time() + timeout;
    c.g_mutex_lock(&w.lock);
    defer c.g_mutex_unlock(&w.lock);
    if (w.flushing != 0) return c.GST_RTSP_EINTR;
    while (w.full()) {
        const ok = c.g_cond_wait_until(&w.not_full, &w.lock, end);
        if (w.flushing != 0) return c.GST_RTSP_EINTR;
        if (ok == 0) return c.GST_RTSP_ETIMEOUT;
    }
    return OK;
}

pub export fn gst_rtsp_watch_set_flushing(h: ?*c.GstRTSPWatch, flushing: c.gboolean) void {
    if (!that(h != null, "gst_rtsp_watch_set_flushing", "watch != NULL")) return;
    const w = wof(h);
    c.g_mutex_lock(&w.lock);
    defer c.g_mutex_unlock(&w.lock);
    w.flushing = flushing;
    c.g_cond_signal(&w.not_full);
    if (flushing == 0) return;
    while (c.gst_vec_deque_get_length(w.messages) > 0) {
        const m: *Serialized = @ptrCast(@alignCast(c.gst_vec_deque_pop_head_struct(w.messages)));
        m.clear();
    }
}

fn usecOf(tv: [*c]c.GTimeVal) i64 {
    return if (tv != null) tv[0].tv_sec * c.G_USEC_PER_SEC + tv[0].tv_usec else 0;
}

pub export fn gst_rtsp_connection_connect(h: ?*c.GstRTSPConnection, tv: [*c]c.GTimeVal) Result {
    return gst_rtsp_connection_connect_usec(h, usecOf(tv));
}

pub export fn gst_rtsp_connection_connect_with_response(h: ?*c.GstRTSPConnection, tv: [*c]c.GTimeVal, resp: [*c]Msg) Result {
    return gst_rtsp_connection_connect_with_response_usec(h, usecOf(tv), resp);
}

pub export fn gst_rtsp_connection_read(h: ?*c.GstRTSPConnection, data: [*c]u8, size: c.guint, tv: [*c]c.GTimeVal) Result {
    return gst_rtsp_connection_read_usec(h, data, size, usecOf(tv));
}

pub export fn gst_rtsp_connection_write(h: ?*c.GstRTSPConnection, data: [*c]const u8, size: c.guint, tv: [*c]c.GTimeVal) Result {
    return gst_rtsp_connection_write_usec(h, data, size, usecOf(tv));
}

pub export fn gst_rtsp_connection_send(h: ?*c.GstRTSPConnection, m: [*c]Msg, tv: [*c]c.GTimeVal) Result {
    return gst_rtsp_connection_send_usec(h, m, usecOf(tv));
}

pub export fn gst_rtsp_connection_send_messages(h: ?*c.GstRTSPConnection, ms: [*c]Msg, n: c.guint, tv: [*c]c.GTimeVal) Result {
    return gst_rtsp_connection_send_messages_usec(h, ms, n, usecOf(tv));
}

pub export fn gst_rtsp_connection_receive(h: ?*c.GstRTSPConnection, m: [*c]Msg, tv: [*c]c.GTimeVal) Result {
    return gst_rtsp_connection_receive_usec(h, m, usecOf(tv));
}

pub export fn gst_rtsp_connection_poll(h: ?*c.GstRTSPConnection, events: c.GstRTSPEvent, revents: [*c]c.GstRTSPEvent, tv: [*c]c.GTimeVal) Result {
    return gst_rtsp_connection_poll_usec(h, events, revents, usecOf(tv));
}

pub export fn gst_rtsp_connection_next_timeout(h: ?*c.GstRTSPConnection, tv: [*c]c.GTimeVal) Result {
    if (!that(tv != null, "gst_rtsp_connection_next_timeout", "timeout != NULL")) return EINVAL;
    const t = gst_rtsp_connection_next_timeout_usec(h);
    tv[0].tv_sec = @divTrunc(t, c.G_USEC_PER_SEC);
    tv[0].tv_usec = @rem(t, c.G_USEC_PER_SEC);
    return OK;
}

pub export fn gst_rtsp_watch_wait_backlog(h: ?*c.GstRTSPWatch, tv: [*c]c.GTimeVal) Result {
    return gst_rtsp_watch_wait_backlog_usec(h, usecOf(tv));
}
