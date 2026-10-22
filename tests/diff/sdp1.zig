const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const N: ?*anyopaque = null;

const texts = [_][:0]const u8{
    "v=0\r\no=- 123456 2 IN IP4 127.0.0.1\r\ns=Session\r\ni=Info here\r\nu=http://x/y\r\ne=a@b.c\r\ne=d@e.f\r\np=+1 555\r\nc=IN IP4 224.2.1.1/127/3\r\nb=AS:512\r\nb=CT:1024\r\nt=2873397496 2873404696\r\nr=7d 1h 0 25h\r\nt=0 0\r\nz=2882844526 -1h 2898848070 0\r\nk=clear:secret\r\na=recvonly\r\na=tool:gst\r\nm=audio 49170 RTP/AVP 0 8 97\r\ni=audio stream\r\nc=IN IP4 10.0.0.1\r\nc=IN IP6 FF15::101/3\r\nb=AS:64\r\nk=prompt\r\na=rtpmap:97 opus/48000/2\r\na=fmtp:97 minptime=10;useinbandfec=1; stereo = 1 ;media=x;Clock-Rate=4\r\na=rtcp-fb:97 nack\r\na=rtcp-fb:* ccm fir\r\na=rtcp-fb:97 nack pli\r\na=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\na=extmap:2/sendrecv urn:x attr1 attr2\r\na=extmap:15 bad\r\na=extmap:3/ urn:y\r\na=ssrc:1234 cname:foo\r\na=ssrc:99 msid:a b\r\na=ssrc:bad x\r\na=rid:1 send pt=97;max-width=1280\r\na=rid:2 recv\r\na=rid:b@d send\r\na=control:trackID=1\r\na=x-custom:val\r\nm=video 51372/2 RTP/AVP 96 31 34\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1\r\na=framesize:96 320-240\r\na=rtpmap:31 H261/90000\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n",
    "v=1\nm=audio 0 RTP/AVP 3\nm=video 0 RTP/AVP 98\na=rtpmap:98 VP8/90000\n",
    "  \n\nv=0\r\ns\r\nX=junk\r\nm=audio\r\nc=IN\r\nb=nocolon\r\nk=\r\na=\r\na=onlykey\r\n",
    "v=0\r\nm=video 1 RTP/AVP 96\r\na=rtpmap:96\r\na=rtpmap:96 \r\nm=video 1 RTP/AVP 100\r\na=rtpmap:100 RAW\r\nm=audio 1 RTP/AVP 101\r\na=rtpmap:101 telephone-event/8000/\r\nm=audio 1 RTP/AVP 102\r\na=rtpmap:102 L16\r\na=fmtp:102",
    "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 level-asymmetry-allowed=1;profile-level-id=640c1f\r\n",
};

fn dumpCaps(tag: []const u8, caps: [*c]c.GstCaps) void {
    if (caps == null) {
        out("  {s} null", .{tag});
        return;
    }
    const s = c.gst_caps_to_string(caps);
    out("  {s} {s}", .{ tag, z(s) });
    c.g_free(s);
}

fn mediaCaps(msg: [*c]c.GstSDPMessage) void {
    var i: c.guint = 0;
    while (i < c.gst_sdp_message_medias_len(msg)) : (i += 1) {
        const media = c.gst_sdp_message_get_media(msg, i);
        var f: c.guint = 0;
        while (f < c.gst_sdp_media_formats_len(media)) : (f += 1) {
            const pt = c.atoi(c.gst_sdp_media_get_format(media, f));
            const caps = c.gst_sdp_media_get_caps_from_media(media, pt);
            if (caps != null) {
                const caps2 = c.gst_caps_make_writable(caps);
                const r = c.gst_sdp_media_attributes_to_caps(media, caps2);
                out("  attrs result {d}", .{r});
                dumpCaps("media caps", caps2);
                var nm: [*c]c.GstSDPMedia = null;
                _ = c.gst_sdp_media_new(&nm);
                out("  set from caps {d}", .{c.gst_sdp_media_set_media_from_caps(caps2, nm)});
                const t = c.gst_sdp_media_as_text(nm);
                out("  back {s}", .{z(t)});
                c.g_free(t);
                _ = c.gst_sdp_media_free(nm);
                c.gst_caps_unref(caps2);
            } else out("  no caps for {d}", .{pt});
        }
    }
    const mc = c.gst_caps_new_empty_simple("application/x-rtp");
    out("  msg attrs {d}", .{c.gst_sdp_message_attributes_to_caps(msg, mc)});
    dumpCaps("msg caps", mc);
    c.gst_caps_unref(mc);
}

fn roundTrip(text: [:0]const u8) void {
    var msg: [*c]c.GstSDPMessage = null;
    out("parse {d}", .{c.gst_sdp_message_new_from_text(text.ptr, &msg)});
    const t = c.gst_sdp_message_as_text(msg);
    out("text {s}", .{z(t)});
    const uri = c.gst_sdp_message_as_uri("rtsp", msg);
    out("uri {s}", .{z(uri)});
    var msg2: [*c]c.GstSDPMessage = null;
    _ = c.gst_sdp_message_new(&msg2);
    out("parse uri {d}", .{c.gst_sdp_message_parse_uri(uri, msg2)});
    const t2 = c.gst_sdp_message_as_text(msg2);
    out("same {d}", .{@intFromBool(std.mem.eql(u8, z(t), z(t2)))});
    var cp: [*c]c.GstSDPMessage = null;
    _ = c.gst_sdp_message_copy(msg, &cp);
    const t3 = c.gst_sdp_message_as_text(cp);
    out("copy same {d}", .{@intFromBool(std.mem.eql(u8, z(t), z(t3)))});
    _ = c.gst_sdp_message_dump(msg);
    mediaCaps(msg);
    for ([_][*c]u8{ t, uri, t2, t3 }) |x| c.g_free(x);
    _ = c.gst_sdp_message_free(msg);
    _ = c.gst_sdp_message_free(msg2);
    _ = c.gst_sdp_message_free(cp);
}

fn editing() void {
    var msg: [*c]c.GstSDPMessage = null;
    _ = c.gst_sdp_message_new(&msg);
    _ = c.gst_sdp_message_set_version(msg, "0");
    _ = c.gst_sdp_message_set_origin(msg, null, "1", "2", "IN", "IP6", "::1");
    _ = c.gst_sdp_message_set_session_name(msg, "edit");
    _ = c.gst_sdp_message_set_information(msg, "inf");
    _ = c.gst_sdp_message_set_uri(msg, "u");
    _ = c.gst_sdp_message_add_email(msg, "e1");
    _ = c.gst_sdp_message_insert_email(msg, 0, "e0");
    _ = c.gst_sdp_message_replace_email(msg, 1, "e1b");
    _ = c.gst_sdp_message_add_phone(msg, "p1");
    _ = c.gst_sdp_message_add_phone(msg, "p2");
    _ = c.gst_sdp_message_remove_phone(msg, 0);
    _ = c.gst_sdp_message_set_connection(msg, "IN", "IP4", "239.1.1.1", 5, 2);
    _ = c.gst_sdp_message_add_bandwidth(msg, "AS", 10);
    var bw: c.GstSDPBandwidth = undefined;
    _ = c.gst_sdp_bandwidth_set(&bw, "TIAS", 20);
    _ = c.gst_sdp_message_insert_bandwidth(msg, 0, &bw);
    _ = c.gst_sdp_bandwidth_set(&bw, "RR", 30);
    _ = c.gst_sdp_message_replace_bandwidth(msg, 1, &bw);
    var rep = [_:null]?[*:0]const u8{ "1h", "2h" };
    _ = c.gst_sdp_message_add_time(msg, "10", "20", @ptrCast(&rep));
    _ = c.gst_sdp_message_add_time(msg, "30", "40", null);
    var tm: c.GstSDPTime = undefined;
    _ = c.gst_sdp_time_set(&tm, "50", "60", null);
    _ = c.gst_sdp_message_insert_time(msg, 1, &tm);
    _ = c.gst_sdp_message_remove_time(msg, 0);
    _ = c.gst_sdp_message_add_zone(msg, "1", "-1h");
    var zn: c.GstSDPZone = undefined;
    _ = c.gst_sdp_zone_set(&zn, "2", "0");
    _ = c.gst_sdp_message_replace_zone(msg, 0, &zn);
    _ = c.gst_sdp_message_set_key(msg, "base64", "AAAA");
    _ = c.gst_sdp_message_add_attribute(msg, "a", "1");
    _ = c.gst_sdp_message_add_attribute(msg, "a", "2");
    _ = c.gst_sdp_message_add_attribute(msg, "flag", null);
    _ = c.gst_sdp_message_add_attribute(msg, "empty", "");
    var at: c.GstSDPAttribute = undefined;
    _ = c.gst_sdp_attribute_set(&at, "ins", "x");
    _ = c.gst_sdp_message_insert_attribute(msg, 1, &at);
    out("val_n {s} {s} {s}", .{ z(c.gst_sdp_message_get_attribute_val_n(msg, "a", 1)), z(c.gst_sdp_message_get_attribute_val(msg, "a")), z(c.gst_sdp_message_get_attribute_val_n(msg, "a", 5)) });
    var media: [*c]c.GstSDPMedia = null;
    _ = c.gst_sdp_media_new(&media);
    _ = c.gst_sdp_media_set_media(media, "audio");
    _ = c.gst_sdp_media_set_port_info(media, 5004, 2);
    _ = c.gst_sdp_media_set_proto(media, "RTP/AVP");
    _ = c.gst_sdp_media_add_format(media, "0");
    _ = c.gst_sdp_media_insert_format(media, 0, "8");
    _ = c.gst_sdp_media_replace_format(media, 1, "9");
    _ = c.gst_sdp_media_add_format(media, "10");
    _ = c.gst_sdp_media_remove_format(media, 2);
    out("fmt oob {s}", .{z(c.gst_sdp_media_get_format(media, 9))});
    _ = c.gst_sdp_media_set_information(media, "mi");
    _ = c.gst_sdp_media_add_connection(media, "IN", "IP4", "1.2.3.4", 0, 0);
    var conn: c.GstSDPConnection = undefined;
    _ = c.gst_sdp_connection_set(&conn, "IN", "IP4", "232.0.0.1", 9, 4);
    out("ins conn {d}", .{c.gst_sdp_media_insert_connection(media, 0, &conn)});
    _ = c.gst_sdp_connection_set(&conn, "IN", "IP6", "ff02::1", 1, 1);
    out("rep conn {d}", .{c.gst_sdp_media_replace_connection(media, 1, &conn)});
    out("rep conn oob {d}", .{c.gst_sdp_media_replace_connection(media, 7, &conn)});
    _ = c.gst_sdp_media_add_bandwidth(media, "AS", 1);
    _ = c.gst_sdp_bandwidth_set(&bw, "CT", 2);
    _ = c.gst_sdp_media_insert_bandwidth(media, -1, &bw);
    _ = c.gst_sdp_media_remove_bandwidth(media, 0);
    _ = c.gst_sdp_media_set_key(media, "uri", "http://k");
    _ = c.gst_sdp_media_add_attribute(media, "sendonly", null);
    _ = c.gst_sdp_attribute_set(&at, "ptime", "20");
    _ = c.gst_sdp_media_insert_attribute(media, 0, &at);
    _ = c.gst_sdp_attribute_set(&at, "maxptime", "40");
    _ = c.gst_sdp_media_replace_attribute(media, 1, &at);
    out("media attr {s} {d}", .{ z(c.gst_sdp_media_get_attribute_val(media, "ptime")), @intFromBool(c.gst_sdp_media_get_attribute(media, 5) == null) });
    out("media {s} {d} {d} {s} {s}", .{ z(c.gst_sdp_media_get_media(media)), c.gst_sdp_media_get_port(media), c.gst_sdp_media_get_num_ports(media), z(c.gst_sdp_media_get_proto(media)), z(c.gst_sdp_media_get_information(media)) });
    out("add media {d}", .{c.gst_sdp_message_add_media(msg, media)});
    _ = c.gst_sdp_media_free(media);
    _ = c.gst_sdp_media_new(&media);
    _ = c.gst_sdp_media_set_media(media, "video");
    _ = c.gst_sdp_message_add_media(msg, media);
    _ = c.gst_sdp_media_free(media);
    const t = c.gst_sdp_message_as_text(msg);
    out("edited {s}", .{z(t)});
    c.g_free(t);
    out("remove media {d}", .{c.gst_sdp_message_remove_media(msg, 1)});
    out("lens {d} {d} {d} {d} {d} {d} {d}", .{ c.gst_sdp_message_emails_len(msg), c.gst_sdp_message_phones_len(msg), c.gst_sdp_message_bandwidths_len(msg), c.gst_sdp_message_times_len(msg), c.gst_sdp_message_zones_len(msg), c.gst_sdp_message_attributes_len(msg), c.gst_sdp_message_medias_len(msg) });
    const o = c.gst_sdp_message_get_origin(msg);
    out("origin {s} {s}", .{ z(o.*.username), z(o.*.addr) });
    out("multicast {d} {d} {d} {d}", .{ c.gst_sdp_address_is_multicast("IN", "IP4", "224.0.0.1"), c.gst_sdp_address_is_multicast("IN", "IP4", "10.0.0.1"), c.gst_sdp_address_is_multicast("XX", "IP4", "224.0.0.1"), c.gst_sdp_address_is_multicast(null, null, "ff02::1") });
    _ = c.gst_sdp_message_init(msg);
    const t2 = c.gst_sdp_message_as_text(msg);
    out("after init {s}", .{z(t2)});
    c.g_free(t2);
    _ = c.gst_sdp_message_uninit(msg);
    c.g_free(msg);
    out("bad uri {d} {d} {d}", .{ gstUri("rtsp:/x"), gstUri("rtsp://host"), gstUri("rtsp://host/x") });
    var m2: [*c]c.GstSDPMessage = null;
    _ = c.gst_sdp_message_new(&m2);
    out("uri pct {d}", .{c.gst_sdp_message_parse_uri("sdp:///#v=0&s=a%20b%2&c=%", m2)});
    const t3 = c.gst_sdp_message_as_text(m2);
    out("uri text {s}", .{z(t3)});
    c.g_free(t3);
    _ = c.gst_sdp_message_free(m2);
}

fn gstUri(u: [*:0]const u8) c_int {
    var m: [*c]c.GstSDPMessage = null;
    _ = c.gst_sdp_message_new(&m);
    defer _ = c.gst_sdp_message_free(m);
    return c.gst_sdp_message_parse_uri(u, m);
}

fn fromStructure() void {
    const s = c.gst_structure_from_string("application/x-rtp, media=(string)video, payload=(int)96, clock-rate=(int)90000, encoding-name=(string)H264, encoding-params=(string)x, profile=(string)constrained-high, packetization-mode=(string)1, a-framesize=(string)640-480, a-recvonly=(string)\"\", x-foo=(string)bar, ssrc=(uint)5, srtp-key=(string)k, rtcp-fb-nack=(boolean)true, rtcp-fb-nack-pli=(boolean)true, rtcp-fb-ccm-fir=(boolean)false, rtcp-fb-transport-cc=(boolean)true, extmap-1=(string)urn:a, extmap-2=(string)<\"sendonly\", \"urn:b\", \"z\">, extmap-3=(string)<\"\", \"urn:c\", \"\">, extmap-15=(string)bad, extmap-x=(string)bad, rid-a=(string)send, rid-b=(string)<\"recv\", \"max-fps=30\", \"max-br=1\">, rid-=(string)x, num=(int)4", null);
    var media: [*c]c.GstSDPMedia = null;
    _ = c.gst_sdp_media_new(&media);
    out("from struct {d}", .{c.gst_sdp_media_add_media_from_structure(s, media)});
    const t = c.gst_sdp_media_as_text(media);
    out("struct media {s}", .{z(t)});
    c.g_free(t);
    _ = c.gst_sdp_media_free(media);
    c.gst_structure_free(s);
    for ([_][:0]const u8{ "application/x-rtp, media=(string)audio", "application/x-rtp, media=(string)audio, payload=(int)0", "application/x-rtp, payload=(int)0, clock-rate=(int)8000", "application/x-rtp, media=(string)video, payload=(int)96, clock-rate=(int)90000, encoding-name=(string)H264, profile=(string)wat, profile-level-id=(string)42", "application/x-rtp, media=(string)video, payload=(int)96, clock-rate=(int)90000, encoding-name=(string)H264, profile=(string)baseline" }) |str| {
        const st = c.gst_structure_from_string(str.ptr, null);
        _ = c.gst_sdp_media_new(&media);
        out("struct {d}", .{c.gst_sdp_media_add_media_from_structure(st, media)});
        const tt = c.gst_sdp_media_as_text(media);
        out("  {s}", .{z(tt)});
        c.g_free(tt);
        _ = c.gst_sdp_media_free(media);
        c.gst_structure_free(st);
    }
    out("keymgmt {s}", .{z(c.gst_sdp_make_keymgmt("rtsp://a", "QUJD"))});
}

fn showMikey(msg: [*c]c.GstMIKEYMessage, full: bool) void {
    if (msg == null) {
        out("  mikey null", .{});
        return;
    }
    out("  mikey v{d} t{d} V{d} prf{d} map{d} ncs {d} npay {d}", .{ msg.*.version, msg.*.type, msg.*.V, msg.*.prf_func, msg.*.map_type, c.gst_mikey_message_get_n_cs(msg), c.gst_mikey_message_get_n_payloads(msg) });
    if (full) out("  csb {d}", .{msg.*.CSB_id});
    var i: c.guint = 0;
    while (i < c.gst_mikey_message_get_n_cs(msg)) : (i += 1) {
        const s = c.gst_mikey_message_get_cs_srtp(msg, i);
        out("  cs {d} {d} {d}", .{ s.*.policy, s.*.ssrc, s.*.roc });
    }
    i = 0;
    while (i < c.gst_mikey_message_get_n_payloads(msg)) : (i += 1) {
        const p = c.gst_mikey_message_get_payload(msg, i);
        out("  payload {d} len {d}", .{ p.*.type, p.*.len });
        if (p.*.type == c.GST_MIKEY_PT_SP) {
            var k: c.guint = 0;
            while (k < c.gst_mikey_payload_sp_get_n_params(p)) : (k += 1) {
                const prm = c.gst_mikey_payload_sp_get_param(p, k);
                out("   param {d} {d} {d}", .{ prm.*.type, prm.*.len, prm.*.val[0] });
            }
        }
        if (p.*.type == c.GST_MIKEY_PT_KEMAC) {
            var k: c.guint = 0;
            while (k < c.gst_mikey_payload_kemac_get_n_sub(p)) : (k += 1) {
                const sub = c.gst_mikey_payload_kemac_get_sub(p, k);
                out("   sub {d}", .{sub.*.type});
                if (sub.*.type == c.GST_MIKEY_PT_KEY_DATA) {
                    const kd: *const c.GstMIKEYPayloadKeyData = @ptrCast(@alignCast(sub));
                    out("   key {d} {d} salt {d} kv {d} {d} {d}", .{ kd.key_type, kd.key_len, kd.salt_len, kd.kv_type, kd.kv_len[0], kd.kv_len[1] });
                }
            }
        }
        if (full and p.*.type == c.GST_MIKEY_PT_RAND) {
            const r: *const c.GstMIKEYPayloadRAND = @ptrCast(@alignCast(p));
            out("   rand {d}", .{r.len});
        }
    }
}

fn hexOut(tag: []const u8, b: ?*c.GBytes) void {
    var size: usize = 0;
    const d: [*c]const u8 = @ptrCast(c.g_bytes_get_data(b, &size));
    var buf: [4096]u8 = undefined;
    var o: usize = 0;
    for (0..size) |i| {
        _ = std.fmt.bufPrint(buf[o..], "{x:0>2}", .{d[i]}) catch break;
        o += 2;
    }
    out("  {s} {d} {s}", .{ tag, size, buf[0..o] });
}

fn mikeys() void {
    const msg = c.gst_mikey_message_new();
    _ = c.gst_mikey_message_set_info(msg, 1, c.GST_MIKEY_TYPE_PSK_INIT, 1, c.GST_MIKEY_PRF_MIKEY_1, 0x01020304, c.GST_MIKEY_MAP_TYPE_SRTP);
    _ = c.gst_mikey_message_add_cs_srtp(msg, 0, 0xdeadbeef, 7);
    _ = c.gst_mikey_message_add_cs_srtp(msg, 1, 0x11, 0);
    var mp = c.GstMIKEYMapSRTP{ .policy = 2, .ssrc = 3, .roc = 4 };
    _ = c.gst_mikey_message_insert_cs_srtp(msg, 0, &mp);
    _ = c.gst_mikey_message_replace_cs_srtp(msg, 2, &mp);
    _ = c.gst_mikey_message_remove_cs_srtp(msg, 0);
    const ts = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    _ = c.gst_mikey_message_add_t(msg, c.GST_MIKEY_TS_TYPE_NTP_UTC, &ts);
    out("bad t {d}", .{c.gst_mikey_message_add_t(msg, 7, &ts)});
    _ = c.gst_mikey_message_add_rand(msg, 4, &ts);
    _ = c.gst_mikey_message_add_pke(msg, c.GST_MIKEY_CACHE_ALWAYS, 3, &ts);
    const sp = c.gst_mikey_payload_new(c.GST_MIKEY_PT_SP);
    _ = c.gst_mikey_payload_sp_set(sp, 0, c.GST_MIKEY_SEC_PROTO_SRTP);
    var v: u8 = c.GST_MIKEY_ENC_AES_CM_128;
    _ = c.gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_ENC_ALG, 1, &v);
    v = 32;
    _ = c.gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_ENC_KEY_LEN, 1, &v);
    v = 4;
    _ = c.gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_AUTH_KEY_LEN, 1, &v);
    _ = c.gst_mikey_payload_sp_add_param(sp, 99, 1, &v);
    _ = c.gst_mikey_payload_sp_remove_param(sp, 3);
    _ = c.gst_mikey_message_add_payload(msg, sp);
    const kemac = c.gst_mikey_payload_new(c.GST_MIKEY_PT_KEMAC);
    _ = c.gst_mikey_payload_kemac_set(kemac, c.GST_MIKEY_ENC_NULL, c.GST_MIKEY_MAC_NULL);
    const kd = c.gst_mikey_payload_new(c.GST_MIKEY_PT_KEY_DATA);
    const key = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6 };
    _ = c.gst_mikey_payload_key_data_set_key(kd, c.GST_MIKEY_KD_TEK, 16, &key);
    _ = c.gst_mikey_payload_key_data_set_salt(kd, 4, &key);
    _ = c.gst_mikey_payload_key_data_set_spi(kd, 2, &key);
    _ = c.gst_mikey_payload_kemac_add_sub(kemac, kd);
    const kd2 = c.gst_mikey_payload_new(c.GST_MIKEY_PT_KEY_DATA);
    _ = c.gst_mikey_payload_key_data_set_key(kd2, c.GST_MIKEY_KD_TGK, 2, &key);
    _ = c.gst_mikey_payload_key_data_set_interval(kd2, 1, &key, 3, &key);
    _ = c.gst_mikey_payload_kemac_add_sub(kemac, kd2);
    _ = c.gst_mikey_message_add_payload(msg, kemac);
    out("find {d} {d}", .{ @intFromBool(c.gst_mikey_message_find_payload(msg, c.GST_MIKEY_PT_KEMAC, 0) != null), @intFromBool(c.gst_mikey_message_find_payload(msg, c.GST_MIKEY_PT_RAND, 1) != null) });
    showMikey(msg, true);
    const bytes = c.gst_mikey_message_to_bytes(msg, null, null);
    hexOut("bytes", bytes);
    var size: usize = 0;
    const d = c.g_bytes_get_data(bytes, &size);
    const back = c.gst_mikey_message_new_from_data(d, size, null, null);
    showMikey(back, true);
    const b64 = c.gst_mikey_message_base64_encode(msg);
    out("b64 {s}", .{z(b64)});
    const caps = c.gst_caps_new_empty_simple("application/x-srtp");
    out("to caps {d}", .{c.gst_mikey_message_to_caps(back, caps)});
    dumpCaps("mikey caps", caps);
    const fc = c.gst_mikey_message_new_from_caps(caps);
    showMikey(fc, false);
    if (fc != null) c.gst_mini_object_unref(@ptrCast(fc));
    for ([_][:0]const u8{ "application/x-srtp, srtp-key=(buffer)0102030405060708090a0b0c0d0e0f10, srtp-cipher=(string)aes-256-gcm, srtp-auth=(string)hmac-sha1-32, mki=(buffer)0a0b", "application/x-srtp, srtp-key=(buffer)00, srtcp-cipher=(string)aes-128-icm, srtcp-auth=(string)hmac-sha1-80", "application/x-srtp, srtp-key=(buffer)00", "application/x-srtp, srtp-key=(buffer)00, srtp-cipher=(string)rot13", "application/x-srtp" }) |s| {
        const cc = c.gst_caps_from_string(s.ptr);
        const m = c.gst_mikey_message_new_from_caps(cc);
        out("from caps {s}", .{s});
        showMikey(m, false);
        if (m != null) {
            const c2 = c.gst_caps_new_empty_simple("x");
            out("  back {d}", .{c.gst_mikey_message_to_caps(m, c2)});
            dumpCaps("back caps", c2);
            c.gst_caps_unref(c2);
            c.gst_mini_object_unref(@ptrCast(m));
        }
        c.gst_caps_unref(cc);
    }
    for (0..@min(size, 140)) |cut| {
        const m = c.gst_mikey_message_new_from_data(d, cut, null, null);
        if (m != null) {
            out("cut {d} ok", .{cut});
            c.gst_mini_object_unref(@ptrCast(m));
        }
    }
    var corrupt: [256]u8 = undefined;
    @memcpy(corrupt[0..size], @as([*]const u8, @ptrCast(d))[0..size]);
    var i: usize = 0;
    while (i < size) : (i += 3) {
        const saved = corrupt[i];
        corrupt[i] ^= 0x5a;
        const m = c.gst_mikey_message_new_from_data(&corrupt, size, null, null);
        out("flip {d} {d}", .{ i, @intFromBool(m != null) });
        if (m != null) {
            showMikey(m, true);
            c.gst_mini_object_unref(@ptrCast(m));
        }
        corrupt[i] = saved;
    }
    const kemac_b64 = c.gst_sdp_make_keymgmt("rtsp://h/s", b64);
    var sm: [*c]c.GstSDPMessage = null;
    _ = c.gst_sdp_message_new(&sm);
    _ = c.gst_sdp_message_add_attribute(sm, "key-mgmt", kemac_b64);
    var pm: [*c]c.GstMIKEYMessage = null;
    out("parse keymgmt {d}", .{c.gst_sdp_message_parse_keymgmt(sm, &pm)});
    showMikey(pm, true);
    if (pm != null) c.gst_mini_object_unref(@ptrCast(pm));
    const ac = c.gst_caps_new_empty_simple("application/x-rtp");
    out("msg attrs w/ mikey {d}", .{c.gst_sdp_message_attributes_to_caps(sm, ac)});
    dumpCaps("mikey msg caps", ac);
    c.gst_caps_unref(ac);
    var media: [*c]c.GstSDPMedia = null;
    _ = c.gst_sdp_media_new(&media);
    _ = c.gst_sdp_media_add_attribute(media, "key-mgmt", "mikey AAAA");
    _ = c.gst_sdp_media_add_attribute(media, "other", "1");
    pm = null;
    out("media keymgmt bad {d}", .{c.gst_sdp_media_parse_keymgmt(media, &pm)});
    _ = c.gst_sdp_media_remove_attribute(media, 0);
    _ = c.gst_sdp_media_add_attribute(media, "key-mgmt", c.gst_sdp_make_keymgmt("u", b64) + 0);
    const mc = c.gst_caps_new_empty_simple("application/x-rtp");
    out("media attrs w/ mikey {d}", .{c.gst_sdp_media_attributes_to_caps(media, mc)});
    dumpCaps("mikey media caps", mc);
    c.gst_caps_unref(mc);
    _ = c.gst_sdp_media_free(media);
    _ = c.gst_sdp_message_free(sm);
    c.g_free(kemac_b64);
    c.g_free(b64);
    c.gst_mini_object_unref(@ptrCast(back));
    c.g_bytes_unref(bytes);
    c.gst_caps_unref(caps);
    c.gst_mini_object_unref(@ptrCast(msg));
    out("types {s} {s} {s}", .{ z(c.g_type_name(c.gst_sdp_message_get_type())), z(c.g_type_name(c.gst_mikey_message_get_type())), z(c.g_type_name(c.gst_mikey_payload_get_type())) });
}

pub fn main() void {
    c.gst_init(null, null);
    for (texts) |t| roundTrip(t);
    editing();
    fromStructure();
    mikeys();
}
