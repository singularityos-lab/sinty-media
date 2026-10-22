const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const N: ?*anyopaque = null;
const Msg = c.GstRTSPMessage;

var esc_buf: [4096]u8 = undefined;

fn esc(s: []const u8) []const u8 {
    var w: usize = 0;
    for (s) |ch| {
        if (w + 4 > esc_buf.len) break;
        if (ch >= 0x20 and ch < 0x7f and ch != '\\') {
            esc_buf[w] = ch;
            w += 1;
        } else w += (std.fmt.bufPrint(esc_buf[w..], "\\x{x:0>2}", .{ch}) catch unreachable).len;
    }
    return esc_buf[0..w];
}

var port_text: [16]u8 = undefined;
var port_len: usize = 0;

fn masked(s: []const u8, buf: *std.ArrayList(u8)) void {
    const al = std.heap.c_allocator;
    var lines = std.mem.splitSequence(u8, s, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Date: ")) {
            buf.appendSlice(al, "Date: DATE|") catch unreachable;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(line, "x-sessioncookie: ")) {
            buf.appendSlice(al, "x-sessioncookie: COOKIE|") catch unreachable;
            continue;
        }
        var i: usize = 0;
        while (i < line.len) {
            if (port_len > 0 and std.mem.startsWith(u8, line[i..], port_text[0..port_len])) {
                buf.appendSlice(al, "PORT") catch unreachable;
                i += port_len;
            } else {
                buf.append(al, line[i]) catch unreachable;
                i += 1;
            }
        }
        buf.append(al, '|') catch unreachable;
    }
}

fn show(tag: []const u8, text: []const u8) void {
    var b = std.ArrayList(u8).empty;
    defer b.deinit(std.heap.c_allocator);
    masked(text, &b);
    out("{s} {s}", .{ tag, b.items });
}

fn dumpMsg(tag: []const u8, m: [*c]Msg) void {
    const t = c.gst_rtsp_message_get_type(m);
    var method: c.GstRTSPMethod = 0;
    var uri: [*c]const u8 = null;
    var ver: c.GstRTSPVersion = 0;
    var code: c.GstRTSPStatusCode = 0;
    var reason: [*c]const u8 = null;
    var ch: u8 = 0;
    switch (t) {
        c.GST_RTSP_MESSAGE_REQUEST, c.GST_RTSP_MESSAGE_HTTP_REQUEST => {
            _ = c.gst_rtsp_message_parse_request(m, &method, &uri, &ver);
            var b = std.ArrayList(u8).empty;
            defer b.deinit(std.heap.c_allocator);
            masked(std.mem.span(uri), &b);
            out("{s} type={d} req method={d} uri={s} ver={d}", .{ tag, t, method, b.items, ver });
        },
        c.GST_RTSP_MESSAGE_RESPONSE, c.GST_RTSP_MESSAGE_HTTP_RESPONSE => {
            _ = c.gst_rtsp_message_parse_response(m, &code, &reason, &ver);
            out("{s} type={d} resp code={d} reason={s} ver={d}", .{ tag, t, code, z(reason), ver });
        },
        c.GST_RTSP_MESSAGE_DATA => {
            _ = c.gst_rtsp_message_parse_data(m, &ch);
            out("{s} type={d} data ch={d}", .{ tag, t, ch });
        },
        else => out("{s} type={d}", .{ tag, t }),
    }
    if (t != c.GST_RTSP_MESSAGE_DATA and t != c.GST_RTSP_MESSAGE_INVALID) {
        const s = c.g_string_new("");
        _ = c.gst_rtsp_message_append_headers(m, s);
        show("  headers", s[0].str[0..s[0].len]);
        _ = c.g_string_free(s, 1);
    }
    var bb: [*c]c.GstBuffer = null;
    _ = c.gst_rtsp_message_get_body_buffer(m, &bb);
    out("  has body buffer {d}", .{c.gst_rtsp_message_has_body_buffer(m)});
    var data: [*c]u8 = null;
    var size: c.guint = 0;
    _ = c.gst_rtsp_message_get_body(m, &data, &size);
    if (data != null) out("  body [{d}] {s}", .{ size, esc(data[0..size]) }) else out("  no body", .{});
}

fn defsTest() void {
    out("defs", .{});
    var r: c_int = -18;
    while (r <= 2) : (r += 1) {
        const s = c.gst_rtsp_strresult(r);
        out("  result {d} {s}", .{ r, z(s) });
        c.g_free(s);
    }
    var bit: c.guint = 0;
    while (bit < 14) : (bit += 1) out("  method {d} {s}", .{ bit, z(c.gst_rtsp_method_as_text(@as(c.GstRTSPMethod, 1) << @intCast(bit))) });
    out("  method 0 {s}", .{z(c.gst_rtsp_method_as_text(0))});
    for ([_]c.GstRTSPVersion{ 0, 0x10, 0x11, 0x20, 0x30 }) |v| out("  version {d} {s}", .{ v, z(c.gst_rtsp_version_as_text(v)) });
    var h: c.GstRTSPHeaderField = 0;
    while (h <= 89) : (h += 1) out("  header {d} {s} multi={d}", .{ h, z(c.gst_rtsp_header_as_text(h)), c.gst_rtsp_header_allow_multiple(h) });
    var code: c.GstRTSPStatusCode = 0;
    while (code < 600) : (code += 1) {
        const t = c.gst_rtsp_status_as_text(code);
        if (t != null) out("  status {d} {s}", .{ code, z(t) });
    }
    for ([_][*:0]const u8{ "cseq", "CSEQ", "Content-Length", "x-sessioncookie", "X-SESSIONCOOKIE", "rate-control", "Unknown", "" }) |n| out("  find {s} {d}", .{ z(n), c.gst_rtsp_find_header_field(n) });
    for ([_][*:0]const u8{ "play", "SETUP", "get_parameter", "post", "bogus" }) |n| out("  find method {s} {d}", .{ z(n), c.gst_rtsp_find_method(n) });
    for ([_]c.GstRTSPMethod{ 0, 0x7ff, 0x1fff, 0x24, 1 << 3 }) |m| {
        const s = c.gst_rtsp_options_as_text(m);
        out("  options {x} {s}", .{ m, z(s) });
        c.g_free(s);
    }
    for ([_][*:0]const u8{ "OPTIONS, DESCRIBE,PLAY , junk, TEARDOWN", "", "get,post" }) |s| out("  options from {s} {x}", .{ z(s), c.gst_rtsp_options_from_text(s) });
    const d = c.gst_rtsp_generate_digest_auth_response(null, "DESCRIBE", "realm", "user", "pass", "rtsp://h/x", "nonce123");
    out("  digest {s}", .{z(d)});
    c.g_free(d);
    const d2 = c.gst_rtsp_generate_digest_auth_response("SHA-256", "DESCRIBE", "realm", "user", "pass", "rtsp://h/x", "n");
    out("  digest other {d}", .{@intFromBool(d2 == null)});
    const d3 = c.gst_rtsp_generate_digest_auth_response_from_md5("MD5", "PLAY", "0123456789abcdef0123456789abcdef", "rtsp://h/x", "n");
    out("  digest md5 {s}", .{z(d3)});
    c.g_free(d3);
    out("  digest short {d}", .{@intFromBool(c.gst_rtsp_generate_digest_auth_response_from_md5(null, "PLAY", "abc", "u", "n") == null)});
    out("  digest null {d}", .{@intFromBool(c.gst_rtsp_generate_digest_auth_response(null, "X", null, "u", "p", "u", "n") == null)});
}

fn urlTest() void {
    out("url", .{});
    for ([_][*:0]const u8{ "rtsp://example.com/media", "rtsp://user:pa%20ss@host:8554/a/b%2Fc/d?x=1&y", "rtspu://[::1]:9000/path", "rtsps://[fe80::1]/", "rtsph://host", "RTSPT://HOST:12/x", "rtspsh://a@b@c/d", "http://host/x", "rtsp:/nope", "rtsp://h?q=1", "rtsp://[bad/x", "rts://short/x", "rtspsu://u@h:7/p%41%00%zz" }) |s| {
        var u: [*c]c.GstRTSPUrl = null;
        const r = c.gst_rtsp_url_parse(s, &u);
        if (r != 0) {
            out("  {s} -> {d}", .{ z(s), r });
            continue;
        }
        out("  {s} -> t={x} fam={d} user={s} pass={s} host={s} port={d} path={s} query={s}", .{ z(s), u[0].transports, u[0].family, z(u[0].user), z(u[0].passwd), z(u[0].host), u[0].port, z(u[0].abspath), z(u[0].query) });
        var p: u16 = 0;
        _ = c.gst_rtsp_url_get_port(u, &p);
        const ru = c.gst_rtsp_url_get_request_uri(u);
        const rc = c.gst_rtsp_url_get_request_uri_with_control(u, "trackID=1");
        const rc2 = c.gst_rtsp_url_get_request_uri_with_control(u, "rtsp://other/abs");
        out("    port={d} uri={s} ctl={s} abs={s}", .{ p, z(ru), z(rc), z(rc2) });
        c.g_free(ru);
        c.g_free(rc);
        c.g_free(rc2);
        const parts = c.gst_rtsp_url_decode_path_components(u);
        var i: usize = 0;
        while (parts[i] != null) : (i += 1) out("    part {d} {s}", .{ i, esc(std.mem.span(parts[i])) });
        c.g_strfreev(parts);
        const cp = c.gst_rtsp_url_copy(u);
        _ = c.gst_rtsp_url_set_port(cp, 1234);
        const cu = c.gst_rtsp_url_get_request_uri(cp);
        out("    copy {s}", .{z(cu)});
        c.g_free(cu);
        c.gst_rtsp_url_free(cp);
        c.gst_rtsp_url_free(u);
    }
    out("  boxed {s}", .{z(c.g_type_name(c.gst_rtsp_url_get_type()))});
}

fn rangeTest() void {
    out("range", .{});
    for ([_][*:0]const u8{ "npt=0-", "npt=now-", "npt=1.5-30.25", "npt=-20", "npt=00:01:02.5-01:00:00", "npt=1:2-3", "npt=-", "npt=5", "npt=1,5-2,25", "clock=19961108T142300Z-19961108T143520Z", "clock=19961108T142300.25Z-", "clock=-19961108T143520Z", "clock=1996T1Z-", "smpte=10:07:00-10:07:33:05.01", "smpte-30-drop=00:00:01:15-", "smpte-25=10:00:00:12.5-10:00:01", "smpte=1:2-3:4:5", "smpte=-1:00:00", "foo=1-2", "npt=0.000000001-1e3" }) |s| {
        var r: [*c]c.GstRTSPTimeRange = null;
        const res = c.gst_rtsp_range_parse(s, &r);
        if (res != 0) {
            out("  {s} -> {d}", .{ z(s), res });
            continue;
        }
        const t = c.gst_rtsp_range_to_string(r);
        var a: u64 = 0;
        var b: u64 = 0;
        _ = c.gst_rtsp_range_get_times(r, &a, &b);
        out("  {s} -> unit={d} min={d}/{d} max={d}/{d} f={d}/{d} y={d}/{d}/{d} text={s} times={d},{d}", .{ z(s), r[0].unit, r[0].min.type, r[0].min.seconds, r[0].max.type, r[0].max.seconds, r[0].min2.frames, r[0].max2.frames, r[0].min2.year, r[0].min2.month, r[0].min2.day, z(t), a, b });
        c.g_free(t);
        for ([_]c.GstRTSPRangeUnit{ c.GST_RTSP_RANGE_NPT, c.GST_RTSP_RANGE_SMPTE, c.GST_RTSP_RANGE_SMPTE_25, c.GST_RTSP_RANGE_CLOCK, c.GST_RTSP_RANGE_SMPTE_30_DROP }) |u| {
            var cp = r[0];
            const ok = c.gst_rtsp_range_convert_units(&cp, u);
            const ct = if (ok != 0) c.gst_rtsp_range_to_string(&cp) else null;
            out("    to {d}: {d} {s}", .{ u, ok, z(ct) });
            c.g_free(ct);
        }
        c.gst_rtsp_range_free(r);
    }
}

fn transportTest() void {
    out("transport", .{});
    for ([_][*:0]const u8{ "RTP/AVP;unicast;client_port=5000-5001", "RTP/AVP/TCP;interleaved=0-1;ssrc=DEADBEEF;mode=\"PLAY,RECORD\"", "rtp/savpf;multicast;destination=224.2.0.1;ttl=16;port=3456-3457;layers=2", "RTP/AVP/UDP;unicast;source=1.2.3.4;server_port=6970-6971;append;mode=record", "x-real-rdt/udp;client_port=6970", "x-pn-tng/tcp;interleaved=4", "RTP/AVPF;client_port=1", "RTP/AVP;unicast;unicast", "RTP/AVP/TCP;multicast", "RTP;unicast", "", "RTP/XYZ", "RTP/AVP;ttl=300", "RTP/AVP;interleaved=300", "RTP/AVP;client_port=-1", "RTP/AVP;client_port=70000", "RTP/AVP;client_port= 5", "RTP/AVP;ssrc=zz", "RTP/AVP;mode=pause", "RTP/AVP;foo=bar;;", "RTP/AVP;client_port=5000-x", "RTP/AVP/MCAST;layers=4294967296" }) |s| {
        var t: [*c]c.GstRTSPTransport = null;
        _ = c.gst_rtsp_transport_new(&t);
        const r = c.gst_rtsp_transport_parse(s, t);
        const text = c.gst_rtsp_transport_as_text(t);
        var media: [*c]const u8 = null;
        _ = c.gst_rtsp_transport_get_media_type(t, &media);
        out("  {s} -> {d} trans={d} prof={d} lower={d} dst={s} src={s} il={d}-{d} port={d}-{d} cp={d}-{d} sp={d}-{d} ttl={d} layers={d} ssrc={x} play={d} rec={d} app={d} media={s} text={s}", .{ z(s), r, t[0].trans, t[0].profile, t[0].lower_transport, z(t[0].destination), z(t[0].source), t[0].interleaved.min, t[0].interleaved.max, t[0].port.min, t[0].port.max, t[0].client_port.min, t[0].client_port.max, t[0].server_port.min, t[0].server_port.max, t[0].ttl, t[0].layers, t[0].ssrc, t[0].mode_play, t[0].mode_record, t[0].append, z(media), z(text) });
        c.g_free(text);
        _ = c.gst_rtsp_transport_free(t);
    }
    for ([_]c.GstRTSPTransMode{ 0, 1, 2, 4 }) |mode| {
        var mime: [*c]const u8 = null;
        var m0: [*c]const u8 = null;
        var m1: [*c]const u8 = null;
        var m2: [*c]const u8 = null;
        _ = c.gst_rtsp_transport_get_mime(mode, &mime);
        _ = c.gst_rtsp_transport_get_manager(mode, &m0, 0);
        _ = c.gst_rtsp_transport_get_manager(mode, &m1, 1);
        _ = c.gst_rtsp_transport_get_manager(mode, &m2, 2);
        out("  mode {d} mime={s} mgr={s},{s},{s}", .{ mode, z(mime), z(m0), z(m1), z(m2) });
    }
    var t: c.GstRTSPTransport = std.mem.zeroes(c.GstRTSPTransport);
    _ = c.gst_rtsp_transport_init(&t);
    t.lower_transport = c.GST_RTSP_LOWER_TRANS_TCP;
    t.interleaved.min = 300;
    out("  bad text {d}", .{@intFromBool(c.gst_rtsp_transport_as_text(&t) == null)});
    t.trans = 0;
    out("  unknown text {d}", .{@intFromBool(c.gst_rtsp_transport_as_text(&t) == null)});
}

fn messageTest() void {
    out("message", .{});
    var req: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_request(&req, c.GST_RTSP_SETUP, "rtsp://h/x");
    _ = c.gst_rtsp_message_add_header(req, c.GST_RTSP_HDR_CSEQ, "5");
    _ = c.gst_rtsp_message_add_header(req, c.GST_RTSP_HDR_SESSION, "abcd ; timeout=60 ");
    _ = c.gst_rtsp_message_add_header(req, c.GST_RTSP_HDR_TRANSPORT, "RTP/AVP;unicast");
    _ = c.gst_rtsp_message_add_header(req, c.GST_RTSP_HDR_TRANSPORT, "RTP/AVP/TCP");
    _ = c.gst_rtsp_message_add_header_by_name(req, "X-Custom", "one");
    _ = c.gst_rtsp_message_add_header_by_name(req, "x-custom", "two");
    _ = c.gst_rtsp_message_add_header_by_name(req, "Accept", "application/sdp");
    _ = c.gst_rtsp_message_take_header_by_name(req, "X-Other", c.g_strdup("v"));
    dumpMsg("req", req);
    var v: [*c]u8 = null;
    out("  get {d} {s}", .{ c.gst_rtsp_message_get_header(req, c.GST_RTSP_HDR_TRANSPORT, &v, 1), z(v) });
    out("  get {d}", .{c.gst_rtsp_message_get_header(req, c.GST_RTSP_HDR_TRANSPORT, &v, 2)});
    out("  by name {d} {s}", .{ c.gst_rtsp_message_get_header_by_name(req, "X-CUSTOM", &v, 1), z(v) });
    out("  by name {d} {s}", .{ c.gst_rtsp_message_get_header_by_name(req, "accept", &v, 0), z(v) });
    out("  by name {d}", .{c.gst_rtsp_message_get_header_by_name(req, "x-none", &v, -1)});
    var resp: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_response(&resp, c.GST_RTSP_STS_OK, null, req);
    _ = c.gst_rtsp_message_set_body(resp, "v=0\r\n", 5);
    dumpMsg("resp", resp);
    var cp: [*c]Msg = null;
    _ = c.gst_rtsp_message_copy(resp, &cp);
    dumpMsg("copy", cp);
    out("  remove {d} {d}", .{ c.gst_rtsp_message_remove_header(req, c.GST_RTSP_HDR_TRANSPORT, 0), c.gst_rtsp_message_remove_header(req, c.GST_RTSP_HDR_TRANSPORT, -1) });
    out("  remove name {d} {d}", .{ c.gst_rtsp_message_remove_header_by_name(req, "x-custom", -1), c.gst_rtsp_message_remove_header_by_name(req, "cseq", 0) });
    dumpMsg("req2", req);
    const body = c.gst_buffer_new_wrapped(c.g_strdup("payload"), 7);
    _ = c.gst_rtsp_message_take_body_buffer(req, body);
    out("  has {d}", .{c.gst_rtsp_message_has_body_buffer(req)});
    var cp2: [*c]Msg = null;
    _ = c.gst_rtsp_message_copy(req, &cp2);
    dumpMsg("copybuf", cp2);
    var stolen: [*c]c.GstBuffer = null;
    _ = c.gst_rtsp_message_steal_body_buffer(cp2, &stolen);
    out("  stolen {d} size={d}", .{ @intFromBool(stolen != null), cp2[0].body_size });
    c.gst_buffer_unref(stolen);
    var sd: [*c]u8 = null;
    var ss: c.guint = 0;
    _ = c.gst_rtsp_message_steal_body(req, &sd, &ss);
    out("  steal body [{d}] {s}", .{ ss, sd[0..ss] });
    c.g_free(sd);
    var http: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_request(&http, c.GST_RTSP_GET, "/tunnel");
    http[0].type = c.GST_RTSP_MESSAGE_HTTP_REQUEST;
    http[0].type_data.request.version = c.GST_RTSP_VERSION_1_1;
    var hr: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_response(&hr, 777, "Custom", http);
    dumpMsg("httpresp", hr);
    var dm: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_data(&dm, 3);
    _ = c.gst_rtsp_message_set_body(dm, "\x01\x02\x03", 3);
    dumpMsg("data", dm);
    _ = c.gst_rtsp_message_dump(req);
    _ = c.gst_rtsp_message_dump(resp);
    _ = c.gst_rtsp_message_dump(hr);
    _ = c.gst_rtsp_message_dump(dm);
    _ = c.gst_rtsp_message_dump(http);
    out("  bad parse {d}", .{c.gst_rtsp_message_parse_data(req, null)});
    var auth: [*c]Msg = null;
    _ = c.gst_rtsp_message_new(&auth);
    _ = c.gst_rtsp_message_init_response(auth, 401, null, null);
    _ = c.gst_rtsp_message_add_header(auth, c.GST_RTSP_HDR_WWW_AUTHENTICATE, "Digest realm=\"r \\\"q\\\"\", nonce=\"abc\", stale=FALSE, Basic realm=\"b\"");
    _ = c.gst_rtsp_message_add_header(auth, c.GST_RTSP_HDR_WWW_AUTHENTICATE, "  Negotiate xyz, Basic   realm=plain,  qop=auth");
    _ = c.gst_rtsp_message_add_header(auth, c.GST_RTSP_HDR_AUTHORIZATION, "Basic dXNlcjpwYXNz");
    _ = c.gst_rtsp_message_add_header(auth, c.GST_RTSP_HDR_PROXY_AUTHENTICATE, "Digest");
    for ([_]c.GstRTSPHeaderField{ c.GST_RTSP_HDR_WWW_AUTHENTICATE, c.GST_RTSP_HDR_AUTHORIZATION, c.GST_RTSP_HDR_PROXY_AUTHENTICATE, c.GST_RTSP_HDR_CSEQ }) |f| {
        const creds = c.gst_rtsp_message_parse_auth_credentials(auth, f);
        var i: usize = 0;
        if (creds == null) {
            out("  creds {d} null", .{f});
            continue;
        }
        while (creds[i] != null) : (i += 1) {
            out("  cred {d} scheme={d} auth={s}", .{ f, creds[i][0].scheme, z(creds[i][0].authorization) });
            const ct = c.gst_rtsp_auth_credential_get_type();
            const dup: [*c]c.GstRTSPAuthCredential = @ptrCast(@alignCast(c.g_boxed_copy(ct, creds[i])));
            var p = dup[0].params;
            while (p != null and p[0] != null) : (p += 1) out("    param {s}={s}", .{ z(p[0][0].name), z(p[0][0].value) });
            c.g_boxed_free(ct, dup);
        }
        out("  creds {d} n={d}", .{ f, i });
        c.gst_rtsp_auth_credentials_free(creds);
    }
    out("  boxed {s} {s} {s}", .{ z(c.g_type_name(c.gst_rtsp_msg_get_type())), z(c.g_type_name(c.gst_rtsp_auth_param_get_type())), z(c.g_type_name(c.gst_rtsp_auth_credential_get_type())) });
    for ([_][*c]Msg{ req, resp, cp, cp2, http, hr, dm, auth }) |m| _ = c.gst_rtsp_message_free(m);
}

fn enums() void {
    out("enums", .{});
    const types = [_]c.GType{ c.gst_rtsp_result_get_type(), c.gst_rtsp_event_get_type(), c.gst_rtsp_family_get_type(), c.gst_rtsp_state_get_type(), c.gst_rtsp_version_get_type(), c.gst_rtsp_method_get_type(), c.gst_rtsp_auth_method_get_type(), c.gst_rtsp_header_field_get_type(), c.gst_rtsp_status_code_get_type(), c.gst_rtsp_msg_type_get_type(), c.gst_rtsp_range_unit_get_type(), c.gst_rtsp_time_type_get_type(), c.gst_rtsp_trans_mode_get_type(), c.gst_rtsp_profile_get_type(), c.gst_rtsp_lower_trans_get_type() };
    for (types) |t| {
        out("  {s}", .{z(c.g_type_name(t))});
        const k = c.g_type_class_ref(t);
        defer c.g_type_class_unref(k);
        if (c.g_type_is_a(t, c.G_TYPE_FLAGS) != 0) {
            const fk: *c.GFlagsClass = @ptrCast(@alignCast(k));
            for (0..fk.n_values) |i| out("    {d} {s} {s}", .{ fk.values[i].value, z(fk.values[i].value_name), z(fk.values[i].value_nick) });
        } else {
            const ek: *c.GEnumClass = @ptrCast(@alignCast(k));
            for (0..ek.n_values) |i| out("    {d} {s} {s}", .{ ek.values[i].value, z(ek.values[i].value_name), z(ek.values[i].value_nick) });
        }
    }
    out("  ext iface {s} fund={d}", .{ z(c.g_type_name(c.gst_rtsp_extension_get_type())), @intFromBool(c.g_type_fundamental(c.gst_rtsp_extension_get_type()) == c.g_type_fundamental(c.g_type_from_name("GTypePlugin"))) });
}

fn listener() ?*c.GSocket {
    var err: [*c]c.GError = null;
    const s = c.g_socket_new(c.G_SOCKET_FAMILY_IPV4, c.G_SOCKET_TYPE_STREAM, c.G_SOCKET_PROTOCOL_TCP, &err);
    const lo = c.g_inet_address_new_loopback(c.G_SOCKET_FAMILY_IPV4);
    const addr = c.g_inet_socket_address_new(lo, 0);
    _ = c.g_socket_bind(s, addr, 1, &err);
    _ = c.g_socket_listen(s, &err);
    c.g_object_unref(addr);
    c.g_object_unref(lo);
    const local = c.g_socket_get_local_address(s, &err);
    const port = c.g_inet_socket_address_get_port(@ptrCast(local));
    c.g_object_unref(local);
    port_len = (std.fmt.bufPrint(&port_text, ":{d}", .{port}) catch unreachable).len;
    return s;
}

fn connectTo(scheme: []const u8, path: []const u8) ?*c.GstRTSPConnection {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{s}://127.0.0.1{s}{s}", .{ scheme, port_text[0..port_len], path }) catch unreachable;
    var u: [*c]c.GstRTSPUrl = null;
    _ = c.gst_rtsp_url_parse(s.ptr, &u);
    var conn: ?*c.GstRTSPConnection = null;
    _ = c.gst_rtsp_connection_create(u, &conn);
    c.gst_rtsp_url_free(u);
    return conn;
}

const folded = "RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 3\r\nX-Folded: a\r\n b\r\n\r\nxyz";
const badseq = "RTSP/1.0 200 OK\r\nCSeq: 99\r\n\r\n";
const datamsg = "$\x00\x00\x02hi";

fn plainTest() void {
    out("connection", .{});
    const ls = listener();
    defer c.g_object_unref(ls);
    const cl = connectTo("rtsp", "/stream");
    out("  connect {d} tunneled={d} url={s}", .{ c.gst_rtsp_connection_connect_usec(cl, 2000000), c.gst_rtsp_connection_is_tunneled(cl), z(c.gst_rtsp_connection_get_url(cl)[0].abspath) });
    out("  ip {s} read={d} write={d}", .{ z(c.gst_rtsp_connection_get_ip(cl)), @intFromBool(c.gst_rtsp_connection_get_read_socket(cl) != null), @intFromBool(c.gst_rtsp_connection_get_write_socket(cl) != null) });
    var sv: ?*c.GstRTSPConnection = null;
    out("  accept {d} ip={s}", .{ c.gst_rtsp_connection_accept(ls, &sv, null), z(c.gst_rtsp_connection_get_ip(sv)) });
    out("  auth {d} {d} {d} {d}", .{ c.gst_rtsp_connection_set_auth(cl, c.GST_RTSP_AUTH_DIGEST, "a:b", "p"), c.gst_rtsp_connection_set_auth(cl, c.GST_RTSP_AUTH_NONE, null, "p"), c.gst_rtsp_connection_set_auth(cl, c.GST_RTSP_AUTH_BASIC, "a:b", "p"), c.gst_rtsp_connection_set_auth(cl, c.GST_RTSP_AUTH_BASIC, "user", "pass") });
    var req: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_request(&req, c.GST_RTSP_OPTIONS, "rtsp://127.0.0.1/stream");
    _ = c.gst_rtsp_message_add_header(req, c.GST_RTSP_HDR_USER_AGENT, "test");
    out("  send {d}", .{c.gst_rtsp_connection_send_usec(cl, req, 1000000)});
    var got = std.mem.zeroes(Msg);
    _ = c.gst_rtsp_message_init(&got);
    out("  receive {d}", .{c.gst_rtsp_connection_receive_usec(sv, &got, 1000000)});
    dumpMsg("  srv got", &got);
    var resp: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_response(&resp, c.GST_RTSP_STS_UNAUTHORIZED, null, &got);
    _ = c.gst_rtsp_message_add_header(resp, c.GST_RTSP_HDR_WWW_AUTHENTICATE, "Digest realm=\"r\", nonce=\"n1\", opaque=\"op\"");
    _ = c.gst_rtsp_message_add_header(resp, c.GST_RTSP_HDR_SESSION, "sess42;timeout=33");
    _ = c.gst_rtsp_message_set_body(resp, "hello", 5);
    out("  reply {d}", .{c.gst_rtsp_connection_send_usec(sv, resp, 1000000)});
    var back = std.mem.zeroes(Msg);
    _ = c.gst_rtsp_message_init(&back);
    out("  client receive {d}", .{c.gst_rtsp_connection_receive_usec(cl, &back, 1000000)});
    dumpMsg("  cli got", &back);
    _ = c.gst_rtsp_message_unset(&got);
    _ = c.gst_rtsp_message_unset(&back);
    c.gst_rtsp_connection_set_auth_param(cl, "REALM", "r");
    c.gst_rtsp_connection_set_auth_param(cl, "nonce", "n1");
    c.gst_rtsp_connection_set_auth_param(cl, "Opaque", "op");
    _ = c.gst_rtsp_connection_set_auth(cl, c.GST_RTSP_AUTH_DIGEST, "user", "pass");
    _ = c.gst_rtsp_message_init_request(req, c.GST_RTSP_DESCRIBE, "rtsp://127.0.0.1/stream");
    var two = [_]Msg{ std.mem.zeroes(Msg), std.mem.zeroes(Msg) };
    _ = c.gst_rtsp_message_init_request(&two[0], c.GST_RTSP_PLAY, "rtsp://127.0.0.1/stream");
    _ = c.gst_rtsp_message_add_header(&two[0], c.GST_RTSP_HDR_RANGE, "npt=0-");
    _ = c.gst_rtsp_message_init_data(&two[1], 1);
    _ = c.gst_rtsp_message_take_body_buffer(&two[1], c.gst_buffer_new_wrapped(c.g_strdup("rtpdata!"), 8));
    out("  send {d} multi {d}", .{ c.gst_rtsp_connection_send_usec(cl, req, 1000000), c.gst_rtsp_connection_send_messages_usec(cl, &two, 2, 1000000) });
    for (0..3) |k| {
        _ = c.gst_rtsp_message_init(&got);
        out("  receive {d} {d}", .{ k, c.gst_rtsp_connection_receive_usec(sv, &got, 1000000) });
        dumpMsg("  srv got", &got);
        _ = c.gst_rtsp_message_unset(&got);
    }
    _ = c.gst_rtsp_message_unset(&two[0]);
    _ = c.gst_rtsp_message_unset(&two[1]);
    out("  write {d}", .{c.gst_rtsp_connection_write_usec(sv, folded, folded.len, 1000000)});
    _ = c.gst_rtsp_message_init(&back);
    out("  client receive {d}", .{c.gst_rtsp_connection_receive_usec(cl, &back, 1000000)});
    dumpMsg("  cli got", &back);
    _ = c.gst_rtsp_message_unset(&back);
    out("  write bad {d}", .{c.gst_rtsp_connection_write_usec(sv, badseq, badseq.len, 1000000)});
    _ = c.gst_rtsp_message_init(&back);
    out("  client receive bad cseq {d}", .{c.gst_rtsp_connection_receive_usec(cl, &back, 1000000)});
    _ = c.gst_rtsp_message_unset(&back);
    out("  write raw {d}", .{c.gst_rtsp_connection_write_usec(cl, "abc", 3, 1000000)});
    var raw: [3]u8 = undefined;
    out("  read raw {d} {s}", .{ c.gst_rtsp_connection_read_usec(sv, &raw, 3, 1000000), raw[0..] });
    var rev: c.GstRTSPEvent = 0;
    out("  poll {d} {d}", .{ c.gst_rtsp_connection_poll_usec(cl, c.GST_RTSP_EV_WRITE, &rev, 100000), rev });
    out("  qos {d}", .{c.gst_rtsp_connection_set_qos_dscp(cl, 10)});
    out("  timeout positive {d}", .{@intFromBool(c.gst_rtsp_connection_next_timeout_usec(cl) > 0)});
    out("  remember {d}", .{c.gst_rtsp_connection_get_remember_session_id(cl)});
    c.gst_rtsp_connection_set_remember_session_id(cl, 0);
    c.gst_rtsp_connection_set_ip(cl, "1.2.3.4");
    out("  set ip {s} tunnelid={d} ign={d}", .{ z(c.gst_rtsp_connection_get_ip(cl)), @intFromBool(c.gst_rtsp_connection_get_tunnelid(cl) == null), c.gst_rtsp_connection_get_ignore_x_server_reply(cl) });
    c.gst_rtsp_connection_set_tunneled(cl, 1);
    out("  flush {d} {d} close {d}", .{ c.gst_rtsp_connection_flush(cl, 1), c.gst_rtsp_connection_flush(cl, 0), c.gst_rtsp_connection_close(sv) });
    var err: [*c]c.GError = null;
    out("  tls none {d} {s}", .{ @intFromBool(c.gst_rtsp_connection_get_tls(cl, &err) == null), z(if (err != null) err[0].message else null) });
    c.g_clear_error(&err);
    out("  tls flags {d} {d}", .{ c.gst_rtsp_connection_set_tls_validation_flags(cl, 0), c.gst_rtsp_connection_get_tls_validation_flags(cl) });
    _ = c.gst_rtsp_message_free(req);
    _ = c.gst_rtsp_message_free(resp);
    _ = c.gst_rtsp_connection_free(cl);
    _ = c.gst_rtsp_connection_free(sv);
}

var watch_log: std.ArrayList(u8) = .empty;
var loop_count: c_int = 0;

fn wlog(comptime f: []const u8, a: anytype) void {
    var b: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&b, f ++ "\n", a) catch unreachable;
    watch_log.appendSlice(std.heap.c_allocator, s) catch unreachable;
}

fn onMessage(w: ?*c.GstRTSPWatch, m: [*c]Msg, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    loop_count += 1;
    var method: c.GstRTSPMethod = 0;
    var uri: [*c]const u8 = null;
    _ = c.gst_rtsp_message_parse_request(m, &method, &uri, null);
    wlog("watch got method={d} uri={s}", .{ method, z(uri) });
    var resp: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_response(&resp, c.GST_RTSP_STS_OK, null, m);
    var id: c.guint = 0;
    const r = c.gst_rtsp_watch_send_message(w, resp, &id);
    wlog("watch send {d} id={d}", .{ r, id });
    _ = c.gst_rtsp_message_free(resp);
    return c.GST_RTSP_OK;
}

fn onSent(_: ?*c.GstRTSPWatch, id: c.guint, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    wlog("watch sent {d}", .{id});
    loop_count += 1;
    return c.GST_RTSP_OK;
}

fn onClosed(_: ?*c.GstRTSPWatch, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    wlog("watch closed", .{});
    loop_count += 1;
    return c.GST_RTSP_OK;
}

fn onError(_: ?*c.GstRTSPWatch, r: c.GstRTSPResult, _: [*c]Msg, id: c.guint, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    wlog("watch error {d} id={d}", .{ r, id });
    return c.GST_RTSP_OK;
}

fn notify(_: c.gpointer) callconv(.c) void {
    wlog("watch notify", .{});
}

fn spin(ctx: ?*c.GMainContext, until: c_int) void {
    var guard: usize = 0;
    while (loop_count < until and guard < 2000) : (guard += 1) _ = c.g_main_context_iteration(ctx, 0);
}

fn watchTest() void {
    out("watch", .{});
    const ls = listener();
    defer c.g_object_unref(ls);
    const cl = connectTo("rtsp", "/w");
    _ = c.gst_rtsp_connection_connect_usec(cl, 2000000);
    var sv: ?*c.GstRTSPConnection = null;
    _ = c.gst_rtsp_connection_accept(ls, &sv, null);
    var funcs = std.mem.zeroes(c.GstRTSPWatchFuncs);
    funcs.message_received = onMessage;
    funcs.message_sent = onSent;
    funcs.closed = onClosed;
    funcs.error_full = onError;
    const ctx = c.g_main_context_new();
    const w = c.gst_rtsp_watch_new(sv, &funcs, null, notify);
    c.gst_rtsp_watch_set_send_backlog(w, 0, 100);
    var bytes: usize = 0;
    var count: c.guint = 0;
    c.gst_rtsp_watch_get_send_backlog(w, &bytes, &count);
    out("  backlog {d} {d}", .{ bytes, count });
    _ = c.gst_rtsp_watch_attach(w, ctx);
    var req: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_request(&req, c.GST_RTSP_OPTIONS, "rtsp://127.0.0.1/w");
    _ = c.gst_rtsp_connection_send_usec(cl, req, 1000000);
    _ = c.gst_rtsp_message_init_request(req, c.GST_RTSP_TEARDOWN, "rtsp://127.0.0.1/w");
    _ = c.gst_rtsp_connection_send_usec(cl, req, 1000000);
    spin(ctx, 4);
    for (0..2) |_| {
        var back = std.mem.zeroes(Msg);
        _ = c.gst_rtsp_message_init(&back);
        out("  client receive {d}", .{c.gst_rtsp_connection_receive_usec(cl, &back, 1000000)});
        dumpMsg("  cli got", &back);
        _ = c.gst_rtsp_message_unset(&back);
    }
    var id: c.guint = 0;
    out("  write data {d} id={d}", .{ c.gst_rtsp_watch_write_data(w, @ptrCast(c.g_memdup2(datamsg, datamsg.len)), datamsg.len, &id), id });
    spin(ctx, 5);
    var dm = std.mem.zeroes(Msg);
    _ = c.gst_rtsp_message_init(&dm);
    out("  client data {d}", .{c.gst_rtsp_connection_receive_usec(cl, &dm, 1000000)});
    dumpMsg("  cli got", &dm);
    _ = c.gst_rtsp_message_unset(&dm);
    out("  wait backlog {d}", .{c.gst_rtsp_watch_wait_backlog_usec(w, 1000)});
    c.gst_rtsp_watch_set_flushing(w, 1);
    out("  flushing write {d}", .{c.gst_rtsp_watch_write_data(w, @ptrCast(c.g_strdup("x")), 1, null)});
    c.gst_rtsp_watch_set_flushing(w, 0);
    _ = c.gst_rtsp_connection_close(cl);
    spin(ctx, 6);
    c.g_source_destroy(@ptrCast(@alignCast(w)));
    c.gst_rtsp_watch_unref(w);
    c.g_main_context_unref(ctx);
    out("{s}", .{watch_log.items});
    _ = c.gst_rtsp_message_free(req);
    _ = c.gst_rtsp_connection_free(cl);
    _ = c.gst_rtsp_connection_free(sv);
}

var server_log: std.ArrayList(u8) = .empty;

fn slog(comptime f: []const u8, a: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&b, f ++ "\n", a) catch unreachable;
    server_log.appendSlice(std.heap.c_allocator, s) catch unreachable;
}

const Tun = struct {
    ls: ?*c.GSocket,
    ctx: ?*c.GMainContext = null,
    get: ?*c.GstRTSPConnection = null,
    post: ?*c.GstRTSPConnection = null,
    gw: ?*c.GstRTSPWatch = null,
    pw: ?*c.GstRTSPWatch = null,
    done: bool = false,
    started: bool = false,
};

var tun: Tun = .{ .ls = null };

fn tStart(_: ?*c.GstRTSPWatch, _: c.gpointer) callconv(.c) c.GstRTSPStatusCode {
    slog("tunnel start", .{});
    tun.started = true;
    return c.GST_RTSP_STS_OK;
}

fn tComplete(_: ?*c.GstRTSPWatch, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    slog("tunnel complete same id {d}", .{@intFromBool(std.mem.eql(u8, std.mem.span(c.gst_rtsp_connection_get_tunnelid(tun.get)), std.mem.span(c.gst_rtsp_connection_get_tunnelid(tun.post))))});
    slog("do tunnel {d}", .{c.gst_rtsp_connection_do_tunnel(tun.get, tun.post)});
    c.gst_rtsp_watch_reset(tun.gw);
    c.g_source_destroy(@ptrCast(@alignCast(tun.pw)));
    return c.GST_RTSP_OK;
}

fn tHttp(_: ?*c.GstRTSPWatch, req: [*c]Msg, resp: [*c]Msg, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    var method: c.GstRTSPMethod = 0;
    _ = c.gst_rtsp_message_parse_request(req, &method, null, null);
    var code: c.GstRTSPStatusCode = 0;
    _ = c.gst_rtsp_message_parse_response(resp, &code, null, null);
    slog("tunnel http response method={d} code={d}", .{ method, code });
    return c.GST_RTSP_OK;
}

fn tMessage(w: ?*c.GstRTSPWatch, m: [*c]Msg, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    var method: c.GstRTSPMethod = 0;
    var uri: [*c]const u8 = null;
    _ = c.gst_rtsp_message_parse_request(m, &method, &uri, null);
    slog("tunneled request method={d} uri={s}", .{ method, z(uri) });
    var resp: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_response(&resp, c.GST_RTSP_STS_OK, null, m);
    _ = c.gst_rtsp_message_add_header(resp, c.GST_RTSP_HDR_PUBLIC, "OPTIONS");
    slog("tunneled reply {d}", .{c.gst_rtsp_watch_send_message(w, resp, null)});
    _ = c.gst_rtsp_message_free(resp);
    tun.done = true;
    return c.GST_RTSP_OK;
}

fn tError(_: ?*c.GstRTSPWatch, r: c.GstRTSPResult, _: [*c]Msg, _: c.guint, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    slog("tunnel error {d}", .{r});
    return c.GST_RTSP_OK;
}

fn tClosed(_: ?*c.GstRTSPWatch, _: c.gpointer) callconv(.c) c.GstRTSPResult {
    return c.GST_RTSP_OK;
}

fn tunnelServer(_: c.gpointer) callconv(.c) c.gpointer {
    var funcs = std.mem.zeroes(c.GstRTSPWatchFuncs);
    funcs.tunnel_start = tStart;
    funcs.tunnel_complete = tComplete;
    funcs.tunnel_http_response = tHttp;
    funcs.message_received = tMessage;
    funcs.error_full = tError;
    funcs.closed = tClosed;
    const ctx = c.g_main_context_new();
    slog("accept get {d}", .{c.gst_rtsp_connection_accept(tun.ls, &tun.get, null)});
    tun.gw = c.gst_rtsp_watch_new(tun.get, &funcs, null, null);
    _ = c.gst_rtsp_watch_attach(tun.gw, ctx);
    var wait: usize = 0;
    while (!tun.started and wait < 200000) : (wait += 1) _ = c.g_main_context_iteration(ctx, 0);
    slog("accept post {d}", .{c.gst_rtsp_connection_accept(tun.ls, &tun.post, null)});
    tun.pw = c.gst_rtsp_watch_new(tun.post, &funcs, null, null);
    _ = c.gst_rtsp_watch_attach(tun.pw, ctx);
    var guard: usize = 0;
    while (!tun.done and guard < 200000) : (guard += 1) _ = c.g_main_context_iteration(ctx, 0);
    var tail: usize = 0;
    while (tail < 200) : (tail += 1) _ = c.g_main_context_iteration(ctx, 0);
    slog("server done {d}", .{@intFromBool(tun.done)});
    c.g_source_destroy(@ptrCast(@alignCast(tun.gw)));
    c.gst_rtsp_watch_unref(tun.gw);
    c.gst_rtsp_watch_unref(tun.pw);
    c.g_main_context_unref(ctx);
    return null;
}

fn tunnelTest() void {
    out("tunnel", .{});
    const ls = listener();
    defer c.g_object_unref(ls);
    tun.ls = ls;
    const th = c.g_thread_new("srv", tunnelServer, null);
    const cl = connectTo("rtsph", "/t");
    c.gst_rtsp_connection_set_tunneled(cl, 1);
    c.gst_rtsp_connection_add_extra_http_request_header(cl, "X-Extra", "1");
    var resp = std.mem.zeroes(Msg);
    _ = c.gst_rtsp_message_init(&resp);
    out("  connect {d} tunneled={d}", .{ c.gst_rtsp_connection_connect_with_response_usec(cl, 2000000, &resp), c.gst_rtsp_connection_is_tunneled(cl) });
    dumpMsg("  tunnel resp", &resp);
    _ = c.gst_rtsp_message_unset(&resp);
    var req: [*c]Msg = null;
    _ = c.gst_rtsp_message_new_request(&req, c.GST_RTSP_OPTIONS, "rtsp://127.0.0.1/t");
    out("  send {d}", .{c.gst_rtsp_connection_send_usec(cl, req, 2000000)});
    var back = std.mem.zeroes(Msg);
    _ = c.gst_rtsp_message_init(&back);
    out("  receive {d}", .{c.gst_rtsp_connection_receive_usec(cl, &back, 2000000)});
    dumpMsg("  cli got", &back);
    _ = c.gst_rtsp_message_unset(&back);
    _ = c.g_thread_join(th);
    out("{s}", .{server_log.items});
    _ = c.gst_rtsp_message_free(req);
    _ = c.gst_rtsp_connection_free(cl);
}

pub fn main() void {
    c.gst_init(null, null);
    defsTest();
    urlTest();
    rangeTest();
    transportTest();
    messageTest();
    enums();
    plainTest();
    watchTest();
    tunnelTest();
}
