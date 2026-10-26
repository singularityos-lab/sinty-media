const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const priv = struct {
    extern fn gst_webrtc_dtls_transport_new(c.guint) ?*anyopaque;
    extern fn gst_webrtc_dtls_transport_set_transport(?*anyopaque, [*c]c.GstWebRTCICETransport) void;
    extern fn gst_webrtc_rtp_sender_new() ?*anyopaque;
    extern fn gst_webrtc_rtp_receiver_new() ?*anyopaque;
    extern fn gst_webrtc_data_channel_on_open(?*anyopaque) void;
    extern fn gst_webrtc_data_channel_on_close(?*anyopaque) void;
    extern fn gst_webrtc_data_channel_on_error(?*anyopaque, [*c]c.GError) void;
    extern fn gst_webrtc_data_channel_on_message_data(?*anyopaque, ?*c.GBytes) void;
    extern fn gst_webrtc_data_channel_on_message_string(?*anyopaque, [*c]const u8) void;
    extern fn gst_webrtc_data_channel_on_buffered_amount_low(?*anyopaque) void;
    extern fn gst_webrtc_ice_transport_connection_state_change([*c]c.GstWebRTCICETransport, c.GstWebRTCICEConnectionState) void;
    extern fn gst_webrtc_ice_transport_gathering_state_change([*c]c.GstWebRTCICETransport, c.GstWebRTCICEGatheringState) void;
    extern fn gst_webrtc_ice_transport_selected_pair_change([*c]c.GstWebRTCICETransport) void;
    extern fn gst_webrtc_ice_transport_new_candidate([*c]c.GstWebRTCICETransport, c.guint, c.GstWebRTCICEComponent, [*c]const u8) void;
    extern fn gst_webrtc_rtp_sender_set_priority(?*anyopaque, c.GstWebRTCPriorityType) void;
};

const DataChannelClass = extern struct {
    parent: c.GObjectClass,
    send_data: ?*const fn (?*anyopaque, ?*c.GBytes, [*c][*c]c.GError) callconv(.c) c.gboolean,
    send_string: ?*const fn (?*anyopaque, [*c]const u8, [*c][*c]c.GError) callconv(.c) c.gboolean,
    close: ?*const fn (?*anyopaque) callconv(.c) void,
    padding: [4]c.gpointer,
};

const enum_types = [_]*const fn () callconv(.c) c.GType{
    c.gst_webrtc_ice_tcp_candidate_type_get_type,      c.gst_webrtc_ice_candidate_protocol_type_get_type,
    c.gst_webrtc_ice_candidate_type_get_type,          c.gst_webrtc_dtls_transport_state_get_type,
    c.gst_webrtc_dtls_role_get_type,                   c.gst_webrtc_ice_gathering_state_get_type,
    c.gst_webrtc_ice_connection_state_get_type,        c.gst_webrtc_signaling_state_get_type,
    c.gst_webrtc_peer_connection_state_get_type,       c.gst_webrtc_ice_role_get_type,
    c.gst_webrtc_ice_component_get_type,               c.gst_webrtc_sdp_type_get_type,
    c.gst_webrtc_rtp_transceiver_direction_get_type,   c.gst_webrtc_dtls_setup_get_type,
    c.gst_webrtc_stats_type_get_type,                  c.gst_webrtc_fec_type_get_type,
    c.gst_webrtc_sctp_transport_state_get_type,        c.gst_webrtc_priority_type_get_type,
    c.gst_webrtc_data_channel_state_get_type,          c.gst_webrtc_bundle_policy_get_type,
    c.gst_webrtc_ice_transport_policy_get_type,        c.gst_webrtc_kind_get_type,
    c.gst_webrtc_error_get_type,
};

const object_types = [_]*const fn () callconv(.c) c.GType{
    c.gst_webrtc_ice_get_type,              c.gst_webrtc_ice_stream_get_type,
    c.gst_webrtc_ice_transport_get_type,    c.gst_webrtc_dtls_transport_get_type,
    c.gst_webrtc_data_channel_get_type,     c.gst_webrtc_rtp_sender_get_type,
    c.gst_webrtc_rtp_receiver_get_type,     c.gst_webrtc_rtp_transceiver_get_type,
    c.gst_webrtc_sctp_transport_get_type,
};

const boxed_types = [_]*const fn () callconv(.c) c.GType{
    c.gst_webrtc_session_description_get_type, c.gst_webrtc_ice_candidate_get_type,
    c.gst_webrtc_ice_candidate_pair_get_type,  c.gst_webrtc_ice_candidate_stats_get_type,
};

fn enums() void {
    for (enum_types) |f| {
        const t = f();
        out("enum {s} flags={d}", .{ z(c.g_type_name(t)), @intFromBool(c.g_type_is_a(t, c.G_TYPE_FLAGS) != 0) });
        const ec: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
        var i: c.guint = 0;
        while (i < ec.n_values) : (i += 1) out("  {d} {s} {s}", .{ ec.values[i].value, z(ec.values[i].value_name), z(ec.values[i].value_nick) });
        c.g_type_class_unref(ec);
    }
    out("quark {s}", .{z(c.g_quark_to_string(c.gst_webrtc_error_quark()))});
    var i: c_int = -1;
    while (i < 8) : (i += 1) out("sdp type {d} {s}", .{ i, z(c.gst_webrtc_sdp_type_to_string(@bitCast(i))) });
    for (boxed_types) |f| {
        const t = f();
        out("boxed {s} fund={s}", .{ z(c.g_type_name(t)), z(c.g_type_name(c.g_type_fundamental(t))) });
    }
}

fn sessionDescription() void {
    var msg: [*c]c.GstSDPMessage = null;
    _ = c.gst_sdp_message_new_from_text("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n", &msg);
    const d = c.gst_webrtc_session_description_new(c.GST_WEBRTC_SDP_TYPE_ANSWER, msg);
    out("desc type={d} same={d}", .{ d.*.type, @intFromBool(d.*.sdp == msg) });
    const d2 = c.gst_webrtc_session_description_copy(d);
    const s = c.gst_sdp_message_as_text(d2.*.sdp);
    out("copy type={d} distinct={d} text={s}", .{ d2.*.type, @intFromBool(d2.*.sdp != msg), z(s) });
    c.g_free(s);
    out("copy null={d}", .{@intFromBool(c.gst_webrtc_session_description_copy(null) == null)});
    const d3: *c.GstWebRTCSessionDescription = @ptrCast(@alignCast(c.g_boxed_copy(c.gst_webrtc_session_description_get_type(), d2)));
    out("boxed copy type={d}", .{d3.type});
    c.g_boxed_free(c.gst_webrtc_session_description_get_type(), d3);
    const d4 = c.gst_webrtc_session_description_new(c.GST_WEBRTC_SDP_TYPE_OFFER, null);
    const d5 = c.gst_webrtc_session_description_copy(d4);
    out("empty copy type={d} sdp={d}", .{ d5.*.type, @intFromBool(d5.*.sdp == null) });
    c.gst_webrtc_session_description_free(d5);
    c.gst_webrtc_session_description_free(d4);
    c.gst_webrtc_session_description_free(d2);
    c.gst_webrtc_session_description_free(d);
}

fn stats(ip: [*c]const u8) *c.GstWebRTCICECandidateStats {
    const s: *c.GstWebRTCICECandidateStats = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstWebRTCICECandidateStats))));
    s.ipaddr = c.g_strdup(ip);
    s.port = 5000;
    s.url = c.g_strdup("stun:x");
    s.ABI.abi.foundation = c.g_strdup("f1");
    s.ABI.abi.related_address = null;
    s.ABI.abi.username_fragment = c.g_strdup("uf");
    return s;
}

fn showStats(tag: []const u8, s: [*c]c.GstWebRTCICECandidateStats) void {
    if (s == null) return out("{s} null", .{tag});
    out("{s} ip={s} url={s} foundation={s} related={s} ufrag={s}", .{ tag, z(s.*.ipaddr), z(s.*.url), z(s.*.ABI.abi.foundation), z(s.*.ABI.abi.related_address), z(s.*.ABI.abi.username_fragment) });
}

fn candidates() void {
    const s = stats("10.0.0.1");
    const s2 = c.gst_webrtc_ice_candidate_stats_copy(s);
    showStats("stats copy", s2);
    out("stats distinct={d}", .{@intFromBool(s2.*.ipaddr != s.ipaddr)});
    c.gst_webrtc_ice_candidate_stats_free(s2);
    c.gst_webrtc_ice_candidate_stats_free(null);
    const cand: *c.GstWebRTCICECandidate = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstWebRTCICECandidate))));
    cand.candidate = c.g_strdup("candidate:1 1 UDP 1 10.0.0.1 5000 typ host");
    cand.sdp_mid = c.g_strdup("0");
    cand.stats = s;
    const cc = c.gst_webrtc_ice_candidate_copy(cand);
    out("cand copy {s} mid={s}", .{ z(cc.*.candidate), z(cc.*.sdp_mid) });
    showStats("cand stats", cc.*.stats);
    const pair: *c.GstWebRTCICECandidatePair = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstWebRTCICECandidatePair))));
    pair.local = cand;
    pair.remote = cc;
    const pc = c.gst_webrtc_ice_candidate_pair_copy(pair);
    out("pair copy local={s} remote={s}", .{ z(pc.*.local.*.candidate), z(pc.*.remote.*.sdp_mid) });
    const pb: *c.GstWebRTCICECandidatePair = @ptrCast(@alignCast(c.g_boxed_copy(c.gst_webrtc_ice_candidate_pair_get_type(), pc)));
    showStats("boxed pair", pb.local.*.stats);
    c.g_boxed_free(c.gst_webrtc_ice_candidate_pair_get_type(), pb);
    c.gst_webrtc_ice_candidate_pair_free(pc);
    c.gst_webrtc_ice_candidate_pair_free(pair);
    c.gst_webrtc_ice_candidate_free(null);
    c.gst_webrtc_ice_candidate_pair_free(null);
}

fn types() void {
    for (object_types) |f| ins.gobject(f());
}

var notifies: [256]u8 = undefined;
var notify_len: usize = 0;

fn onNotify(_: ?*c.GObject, p: [*c]c.GParamSpec, _: c.gpointer) callconv(.c) void {
    const s = std.fmt.bufPrint(notifies[notify_len..], "{s} ", .{z(p.*.name)}) catch return;
    notify_len += s.len;
}

fn watch(o: c.gpointer) void {
    notify_len = 0;
    _ = c.g_signal_connect_data(o, "notify", @ptrCast(&onNotify), null, null, 0);
}

fn notified(tag: []const u8) void {
    out("{s} notify: {s}", .{ tag, notifies[0..notify_len] });
    notify_len = 0;
}

fn enumProp(o: c.gpointer, name: [*c]const u8) c_int {
    var v: c_int = -99;
    c.g_object_get(o, name, &v, @as(?*anyopaque, null));
    return v;
}

var ice_transport_type: c.GType = 0;
var stream_type: c.GType = 0;
var ice_type: c.GType = 0;
var channel_type: c.GType = 0;
var calls: [512]u8 = undefined;
var calls_len: usize = 0;

fn call(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(calls[calls_len..], fmt ++ " ", args) catch return;
    calls_len += s.len;
}

fn showCalls(tag: []const u8) void {
    out("{s} calls: {s}", .{ tag, calls[0..calls_len] });
    calls_len = 0;
}

fn selectedPair(_: [*c]c.GstWebRTCICETransport) callconv(.c) [*c]c.GstWebRTCICECandidatePair {
    call("selected-pair", .{});
    return null;
}

fn transportClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const kl: *c.GstWebRTCICETransportClass = @ptrCast(@alignCast(k));
    kl.get_selected_candidate_pair = selectedPair;
}

fn registerTransport() void {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_webrtc_ice_transport_get_type(), &q);
    ice_transport_type = c.g_type_register_static_simple(c.gst_webrtc_ice_transport_get_type(), "TestIceTransport", q.class_size, transportClassInit, q.instance_size, null, 0);
}

fn onSelected(_: ?*anyopaque, _: c.gpointer) callconv(.c) void {
    out("  on-selected-candidate-pair-change", .{});
}

fn iceTransport() void {
    registerTransport();
    const t: [*c]c.GstWebRTCICETransport = @ptrCast(@alignCast(c.g_object_new(ice_transport_type, "component", @as(c_int, 1), @as(?*anyopaque, null))));
    out("transport component={d} state={d} gathering={d} fields={d} {d} {d}", .{ enumProp(t, "component"), enumProp(t, "state"), enumProp(t, "gathering-state"), t.*.component, t.*.state, t.*.role });
    watch(t);
    priv.gst_webrtc_ice_transport_connection_state_change(t, c.GST_WEBRTC_ICE_CONNECTION_STATE_CONNECTED);
    priv.gst_webrtc_ice_transport_gathering_state_change(t, c.GST_WEBRTC_ICE_GATHERING_STATE_COMPLETE);
    notified("transport");
    out("transport state={d} gathering={d}", .{ enumProp(t, "state"), enumProp(t, "gathering-state") });
    _ = c.g_signal_connect_data(t, "on-selected-candidate-pair-change", @ptrCast(&onSelected), null, null, 0);
    priv.gst_webrtc_ice_transport_selected_pair_change(t);
    out("selected null={d}", .{@intFromBool(c.gst_webrtc_ice_transport_get_selected_candidate_pair(t) == null)});
    showCalls("transport");
    priv.gst_webrtc_ice_transport_new_candidate(t, 0, c.GST_WEBRTC_ICE_COMPONENT_RTP, "candidate:x");
    dtls(t);
    c.gst_object_unref(t);
}

fn dtls(it: [*c]c.GstWebRTCICETransport) void {
    const d = priv.gst_webrtc_dtls_transport_new(7);
    var sid: c.guint = 0;
    var tr: ?*anyopaque = null;
    var client: c.gboolean = 2;
    var cert: [*c]u8 = null;
    c.g_object_get(d, "session-id", &sid, "transport", &tr, "client", &client, "certificate", &cert, @as(?*anyopaque, null));
    out("dtls sid={d} transport={d} state={d} client={d} cert={d} floating={d}", .{ sid, @intFromBool(tr == null), enumProp(d, "state"), client, @intFromBool(cert != null), @intFromBool(c.g_object_is_floating(d) != 0) });
    c.g_free(cert);
    watch(d);
    priv.gst_webrtc_dtls_transport_set_transport(d, it);
    priv.gst_webrtc_dtls_transport_set_transport(d, it);
    notified("dtls");
    c.g_object_get(d, "transport", &tr, @as(?*anyopaque, null));
    out("dtls transport same={d} refs={d}", .{ @intFromBool(tr == @as(?*anyopaque, @ptrCast(it))), @as(*c.GObject, @ptrCast(@alignCast(it))).ref_count });
    c.g_object_unref(tr);
    c.g_object_set(d, "client", @as(c.gboolean, 1), @as(?*anyopaque, null));
    c.g_object_get(d, "client", &client, @as(?*anyopaque, null));
    out("dtls client={d}", .{client});
    rtp(d);
    c.gst_object_unref(d);
}

fn rtp(d: ?*anyopaque) void {
    _ = d;
    const s = priv.gst_webrtc_rtp_sender_new();
    const r = priv.gst_webrtc_rtp_receiver_new();
    var tr: ?*anyopaque = @ptrFromInt(1);
    c.g_object_get(s, "transport", &tr, @as(?*anyopaque, null));
    out("sender priority={d} transport={d} floating={d}", .{ enumProp(s, "priority"), @intFromBool(tr == null), @intFromBool(c.g_object_is_floating(s) != 0) });
    watch(s);
    priv.gst_webrtc_rtp_sender_set_priority(s, c.GST_WEBRTC_PRIORITY_TYPE_HIGH);
    c.g_object_set(s, "priority", @as(c_int, c.GST_WEBRTC_PRIORITY_TYPE_MEDIUM), @as(?*anyopaque, null));
    notified("sender");
    out("sender priority={d}", .{enumProp(s, "priority")});
    tr = @ptrFromInt(1);
    c.g_object_get(r, "transport", &tr, @as(?*anyopaque, null));
    out("receiver transport={d}", .{@intFromBool(tr == null)});
    const caps = c.gst_caps_from_string("application/x-rtp,media=audio");
    var q: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_webrtc_rtp_transceiver_get_type(), &q);
    const xtype = c.g_type_register_static_simple(c.gst_webrtc_rtp_transceiver_get_type(), "TestTransceiver", q.class_size, null, q.instance_size, null, 0);
    const x = c.g_object_new(xtype, "sender", s, "receiver", r, "mlineindex", @as(c.guint, 3), "codec-preferences", caps, @as(?*anyopaque, null));
    c.gst_caps_unref(caps);
    const xt: [*c]c.GstObject = @ptrCast(@alignCast(x));
    out("transceiver sender-parent={d} receiver-parent={d} floating={d}", .{ @intFromBool(@as([*c]c.GstObject, @ptrCast(@alignCast(s))).*.parent == xt), @intFromBool(@as([*c]c.GstObject, @ptrCast(@alignCast(r))).*.parent == xt), @intFromBool(c.g_object_is_floating(x) != 0) });
    var ml: c.guint = 0;
    var mid: [*c]u8 = null;
    var cp: [*c]c.GstCaps = null;
    var snd: ?*anyopaque = null;
    c.g_object_get(x, "mlineindex", &ml, "mid", &mid, "codec-preferences", &cp, "sender", &snd, @as(?*anyopaque, null));
    const cs = c.gst_caps_to_string(cp);
    out("transceiver mline={d} mid={s} dir={d} cur={d} kind={d} caps={s} sender={d}", .{ ml, z(mid), enumProp(x, "direction"), enumProp(x, "current-direction"), enumProp(x, "kind"), z(cs), @intFromBool(snd == s) });
    c.g_free(cs);
    c.gst_caps_unref(cp);
    c.g_object_unref(snd);
    c.g_object_set(x, "direction", @as(c_int, c.GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_SENDRECV), "codec-preferences", @as(?*anyopaque, null), @as(?*anyopaque, null));
    cp = @ptrFromInt(8);
    c.g_object_get(x, "codec-preferences", &cp, @as(?*anyopaque, null));
    out("transceiver dir={d} caps={d}", .{ enumProp(x, "direction"), @intFromBool(cp == null) });
    out("refs sender={d} receiver={d}", .{ @as(*c.GObject, @ptrCast(@alignCast(s))).ref_count, @as(*c.GObject, @ptrCast(@alignCast(r))).ref_count });
    c.gst_object_unref(s);
    c.gst_object_unref(r);
    c.gst_object_unref(x);
}

fn findTransport(_: [*c]c.GstWebRTCICEStream, comp: c.GstWebRTCICEComponent) callconv(.c) [*c]c.GstWebRTCICETransport {
    call("stream-find {d}", .{comp});
    return null;
}

fn streamGather(_: [*c]c.GstWebRTCICEStream) callconv(.c) c.gboolean {
    call("stream-gather", .{});
    return 1;
}

fn streamClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const kl: *c.GstWebRTCICEStreamClass = @ptrCast(@alignCast(k));
    kl.find_transport = findTransport;
    kl.gather_candidates = streamGather;
}

fn iceStream() void {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_webrtc_ice_stream_get_type(), &q);
    stream_type = c.g_type_register_static_simple(c.gst_webrtc_ice_stream_get_type(), "TestIceStream", q.class_size, streamClassInit, q.instance_size, null, 0);
    const s: [*c]c.GstWebRTCICEStream = @ptrCast(@alignCast(c.g_object_new(stream_type, "stream-id", @as(c.guint, 4), @as(?*anyopaque, null))));
    out("stream id={d}", .{s.*.stream_id});
    _ = c.gst_webrtc_ice_stream_find_transport(s, c.GST_WEBRTC_ICE_COMPONENT_RTCP);
    out("stream gather={d}", .{c.gst_webrtc_ice_stream_gather_candidates(s)});
    showCalls("stream");
    ice(s);
    c.gst_object_unref(s);
}

fn iAddStream(_: [*c]c.GstWebRTCICE, id: c.guint) callconv(.c) [*c]c.GstWebRTCICEStream {
    call("add-stream {d}", .{id});
    return null;
}
fn iFind(_: [*c]c.GstWebRTCICE, _: [*c]c.GstWebRTCICEStream, comp: c.GstWebRTCICEComponent) callconv(.c) [*c]c.GstWebRTCICETransport {
    call("find {d}", .{comp});
    return null;
}
fn iGather(_: [*c]c.GstWebRTCICE, _: [*c]c.GstWebRTCICEStream) callconv(.c) c.gboolean {
    call("gather", .{});
    return 1;
}
fn iAddCand(_: [*c]c.GstWebRTCICE, _: [*c]c.GstWebRTCICEStream, cand: [*c]const u8, _: ?*c.GstPromise) callconv(.c) void {
    call("add-candidate {s}", .{z(cand)});
}
fn iLocal(_: [*c]c.GstWebRTCICE, _: [*c]c.GstWebRTCICEStream, u: [*c]const u8, p: [*c]const u8) callconv(.c) c.gboolean {
    call("local {s}/{s}", .{ z(u), z(p) });
    return 1;
}
fn iRemote(_: [*c]c.GstWebRTCICE, _: [*c]c.GstWebRTCICEStream, u: [*c]const u8, p: [*c]const u8) callconv(.c) c.gboolean {
    call("remote {s}/{s}", .{ z(u), z(p) });
    return 0;
}
fn iTurnAdd(_: [*c]c.GstWebRTCICE, u: [*c]const u8) callconv(.c) c.gboolean {
    call("add-turn {s}", .{z(u)});
    return 1;
}
fn iSetCtl(_: [*c]c.GstWebRTCICE, v: c.gboolean) callconv(.c) void {
    call("set-controller {d}", .{v});
}
fn iGetCtl(_: [*c]c.GstWebRTCICE) callconv(.c) c.gboolean {
    call("get-controller", .{});
    return 1;
}
fn iRelay(_: [*c]c.GstWebRTCICE, v: c.gboolean) callconv(.c) void {
    call("relay {d}", .{v});
}
fn iSetStr(_: [*c]c.GstWebRTCICE, u: [*c]const u8) callconv(.c) void {
    call("set {s}", .{z(u)});
}
fn iGetStr(_: [*c]c.GstWebRTCICE) callconv(.c) [*c]u8 {
    call("get", .{});
    return c.g_strdup("uri");
}
fn iTos(_: [*c]c.GstWebRTCICE, _: [*c]c.GstWebRTCICEStream, tos: c.guint) callconv(.c) void {
    call("tos {d}", .{tos});
}
fn iOnCand(_: [*c]c.GstWebRTCICE, _: c.GstWebRTCICEOnCandidateFunc, data: c.gpointer, _: c.GDestroyNotify) callconv(.c) void {
    call("on-candidate {d}", .{@intFromPtr(data)});
}
fn iCands(_: [*c]c.GstWebRTCICE, _: [*c]c.GstWebRTCICEStream) callconv(.c) [*c][*c]c.GstWebRTCICECandidateStats {
    call("candidates", .{});
    return null;
}
fn iPair(_: [*c]c.GstWebRTCICE, _: [*c]c.GstWebRTCICEStream, l: [*c][*c]c.GstWebRTCICECandidateStats, r: [*c][*c]c.GstWebRTCICECandidateStats) callconv(.c) c.gboolean {
    call("pair", .{});
    l.* = null;
    r.* = null;
    return 0;
}
fn iClose(_: [*c]c.GstWebRTCICE, p: ?*c.GstPromise) callconv(.c) void {
    call("close {d}", .{@intFromBool(p == null)});
}

fn iceClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const kl: *c.GstWebRTCICEClass = @ptrCast(@alignCast(k));
    kl.add_stream = iAddStream;
    kl.find_transport = iFind;
    kl.gather_candidates = iGather;
    kl.add_candidate = iAddCand;
    kl.set_local_credentials = iLocal;
    kl.set_remote_credentials = iRemote;
    kl.add_turn_server = iTurnAdd;
    kl.set_is_controller = iSetCtl;
    kl.get_is_controller = iGetCtl;
    kl.set_force_relay = iRelay;
    kl.set_stun_server = iSetStr;
    kl.get_stun_server = iGetStr;
    kl.set_turn_server = iSetStr;
    kl.get_turn_server = iGetStr;
    kl.set_http_proxy = iSetStr;
    kl.get_http_proxy = iGetStr;
    kl.set_tos = iTos;
    kl.set_on_ice_candidate = iOnCand;
    kl.get_local_candidates = iCands;
    kl.get_remote_candidates = iCands;
    kl.get_selected_pair = iPair;
    kl.close = iClose;
}

fn ice(s: [*c]c.GstWebRTCICEStream) void {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_webrtc_ice_get_type(), &q);
    ice_type = c.g_type_register_static_simple(c.gst_webrtc_ice_get_type(), "TestIce", q.class_size, iceClassInit, q.instance_size, null, 0);
    const i: [*c]c.GstWebRTCICE = @ptrCast(@alignCast(c.g_object_new(ice_type, @as([*c]const u8, null))));
    out("ice ports {d} {d}", .{ i.*.min_rtp_port, i.*.max_rtp_port });
    c.g_object_set(i, "min-rtp-port", @as(c.guint, 70000), @as(?*anyopaque, null));
    c.g_object_set(i, "max-rtp-port", @as(c.guint, 100), @as(?*anyopaque, null));
    c.g_object_set(i, "min-rtp-port", @as(c.guint, 200), @as(?*anyopaque, null));
    c.g_object_set(i, "min-rtp-port", @as(c.guint, 50), @as(?*anyopaque, null));
    var mn: c.guint = 0;
    var mx: c.guint = 0;
    c.g_object_get(i, "min-rtp-port", &mn, "max-rtp-port", &mx, @as(?*anyopaque, null));
    out("ice ports {d} {d}", .{ mn, mx });
    _ = c.gst_webrtc_ice_add_stream(i, 9);
    _ = c.gst_webrtc_ice_find_transport(i, s, c.GST_WEBRTC_ICE_COMPONENT_RTP);
    _ = c.gst_webrtc_ice_gather_candidates(i, s);
    c.gst_webrtc_ice_add_candidate(i, s, "cand", null);
    out("ice local={d} remote={d} turn={d}", .{ c.gst_webrtc_ice_set_local_credentials(i, s, "u", "p"), c.gst_webrtc_ice_set_remote_credentials(i, s, "U", "P"), c.gst_webrtc_ice_add_turn_server(i, "turn://x") });
    c.gst_webrtc_ice_set_is_controller(i, 1);
    out("ice controller={d}", .{c.gst_webrtc_ice_get_is_controller(i)});
    c.gst_webrtc_ice_set_force_relay(i, 1);
    c.gst_webrtc_ice_set_stun_server(i, "stun://a");
    c.gst_webrtc_ice_set_turn_server(i, "turn://b");
    c.gst_webrtc_ice_set_http_proxy(i, "http://c");
    const a = c.gst_webrtc_ice_get_stun_server(i);
    const b = c.gst_webrtc_ice_get_turn_server(i);
    const d = c.gst_webrtc_ice_get_http_proxy(i);
    out("ice uris {s} {s} {s}", .{ z(a), z(b), z(d) });
    c.g_free(a);
    c.g_free(b);
    c.g_free(d);
    c.gst_webrtc_ice_set_tos(i, s, 46);
    c.gst_webrtc_ice_set_on_ice_candidate(i, null, @ptrFromInt(5), null);
    _ = c.gst_webrtc_ice_get_local_candidates(i, s);
    _ = c.gst_webrtc_ice_get_remote_candidates(i, s);
    var l: [*c]c.GstWebRTCICECandidateStats = undefined;
    var r: [*c]c.GstWebRTCICECandidateStats = undefined;
    out("ice pair={d}", .{c.gst_webrtc_ice_get_selected_pair(i, s, &l, &r)});
    c.gst_webrtc_ice_close(i, null);
    showCalls("ice");
    var ok: c.gboolean = 7;
    c.g_signal_emit_by_name(i, "add-local-ip-address", "10.1.1.1", &ok);
    out("ice add-local-ip-address={d}", .{ok});
    c.gst_object_unref(i);
}

fn dcSendData(_: ?*anyopaque, data: ?*c.GBytes, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    call("send-data {d} err={d}", .{ c.g_bytes_get_size(data), @intFromBool(err == null) });
    if (err != null) c.g_set_error_literal(err, c.gst_webrtc_error_quark(), c.GST_WEBRTC_ERROR_DATA_CHANNEL_FAILURE, "nope");
    return 0;
}
fn dcSendString(_: ?*anyopaque, s: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    call("send-string {s} err={d}", .{ z(s), @intFromBool(err == null) });
    return 1;
}
fn dcClose(_: ?*anyopaque) callconv(.c) void {
    call("close", .{});
}

fn channelClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const kl: *DataChannelClass = @ptrCast(@alignCast(k));
    kl.send_data = dcSendData;
    kl.send_string = dcSendString;
    kl.close = dcClose;
}

fn onOpen(_: ?*anyopaque, _: c.gpointer) callconv(.c) void {
    out("  on-open", .{});
}
fn onClose(_: ?*anyopaque, _: c.gpointer) callconv(.c) void {
    out("  on-close", .{});
}
fn onLow(_: ?*anyopaque, _: c.gpointer) callconv(.c) void {
    out("  on-buffered-amount-low", .{});
}
fn onError(_: ?*anyopaque, e: [*c]c.GError, _: c.gpointer) callconv(.c) void {
    out("  on-error {s}", .{z(e.*.message)});
}
fn onData(_: ?*anyopaque, b: ?*c.GBytes, _: c.gpointer) callconv(.c) void {
    out("  on-message-data {d}", .{c.g_bytes_get_size(b)});
}
fn onString(_: ?*anyopaque, s: [*c]const u8, _: c.gpointer) callconv(.c) void {
    out("  on-message-string {s}", .{z(s)});
}

fn channel() void {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_webrtc_data_channel_get_type(), &q);
    channel_type = c.g_type_register_static_simple(c.gst_webrtc_data_channel_get_type(), "TestChannel", q.class_size, channelClassInit, q.instance_size, null, 0);
    const ch = c.g_object_new(channel_type, "label", "chat", "ordered", @as(c.gboolean, 1), "max-retransmits", @as(c_int, 3), "id", @as(c_int, 5), "priority", @as(c_int, c.GST_WEBRTC_PRIORITY_TYPE_HIGH), @as(?*anyopaque, null));
    var label: [*c]u8 = null;
    var proto: [*c]u8 = null;
    var ordered: c.gboolean = 0;
    var life: c_int = 0;
    var rt: c_int = 0;
    var id: c_int = 0;
    var neg: c.gboolean = 0;
    var ba: u64 = 1;
    var low: u64 = 1;
    c.g_object_get(ch, "label", &label, "protocol", &proto, "ordered", &ordered, "max-packet-lifetime", &life, "max-retransmits", &rt, "id", &id, "negotiated", &neg, "buffered-amount", &ba, "buffered-amount-low-threshold", &low, @as(?*anyopaque, null));
    out("channel label={s} protocol={s} ordered={d} life={d} rt={d} id={d} neg={d} ba={d} low={d} prio={d} state={d}", .{ z(label), z(proto), ordered, life, rt, id, neg, ba, low, enumProp(ch, "priority"), enumProp(ch, "ready-state") });
    c.g_free(label);
    c.g_free(proto);
    for ([_][*c]const u8{ "on-open", "on-close", "on-buffered-amount-low" }, [_]*const anyopaque{ &onOpen, &onClose, &onLow }) |n, f|
        _ = c.g_signal_connect_data(ch, n, @ptrCast(f), null, null, 0);
    _ = c.g_signal_connect_data(ch, "on-error", @ptrCast(&onError), null, null, 0);
    _ = c.g_signal_connect_data(ch, "on-message-data", @ptrCast(&onData), null, null, 0);
    _ = c.g_signal_connect_data(ch, "on-message-string", @ptrCast(&onString), null, null, 0);
    watch(ch);
    priv.gst_webrtc_data_channel_on_open(@ptrCast(ch));
    priv.gst_webrtc_data_channel_on_open(@ptrCast(ch));
    notified("open");
    const bytes = c.g_bytes_new("abcd", 4);
    priv.gst_webrtc_data_channel_on_message_data(@ptrCast(ch), bytes);
    priv.gst_webrtc_data_channel_on_message_string(@ptrCast(ch), "hi");
    priv.gst_webrtc_data_channel_on_buffered_amount_low(@ptrCast(ch));
    const e = c.g_error_new_literal(c.gst_webrtc_error_quark(), c.GST_WEBRTC_ERROR_SCTP_FAILURE, "boom");
    priv.gst_webrtc_data_channel_on_error(@ptrCast(ch), e);
    c.g_error_free(e);
    var err: [*c]c.GError = null;
    out("send data full={d} err={s}", .{ c.gst_webrtc_data_channel_send_data_full(@ptrCast(ch), bytes, &err), z(if (err != null) err.*.message else null) });
    if (err != null) c.g_error_free(err);
    out("send string full={d}", .{c.gst_webrtc_data_channel_send_string_full(@ptrCast(ch), "yo", null)});
    c.gst_webrtc_data_channel_send_data(@ptrCast(ch), bytes);
    c.gst_webrtc_data_channel_send_string(@ptrCast(ch), "dep");
    c.g_signal_emit_by_name(ch, "send-string", "sig");
    c.g_signal_emit_by_name(ch, "send-data", bytes);
    c.g_signal_emit_by_name(ch, "close");
    c.gst_webrtc_data_channel_close(@ptrCast(ch));
    showCalls("channel");
    c.g_bytes_unref(bytes);
    c.g_object_set(ch, "buffered-amount-low-threshold", @as(u64, 99), @as(?*anyopaque, null));
    priv.gst_webrtc_data_channel_on_close(@ptrCast(ch));
    priv.gst_webrtc_data_channel_on_close(@ptrCast(ch));
    priv.gst_webrtc_data_channel_on_open(@ptrCast(ch));
    notified("close");
    out("channel state={d}", .{enumProp(ch, "ready-state")});
    c.g_object_unref(ch);
}

pub fn main() void {
    c.gst_init(null, null);
    enums();
    sessionDescription();
    candidates();
    types();
    iceTransport();
    iceStream();
    channel();
    out("done", .{});
}
