const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const N: ?*anyopaque = null;
const NONE: u64 = std.math.maxInt(u64);

fn hex(tag: []const u8, p: [*c]const u8, n: usize) void {
    var line: [512]u8 = undefined;
    var w: usize = 0;
    const m = @min(n, 200);
    for (0..m) |i| {
        _ = std.fmt.bufPrint(line[w .. w + 2], "{x:0>2}", .{p[i]}) catch unreachable;
        w += 2;
    }
    out("  {s} [{d}] {s}", .{ tag, n, line[0..w] });
}

fn bufHex(tag: []const u8, b: [*c]c.GstBuffer) void {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    hex(tag, map.data, map.size);
    c.gst_buffer_unmap(b, &map);
}

fn bufInfo(tag: []const u8, b: [*c]c.GstBuffer) void {
    out("  {s} pts={d} dts={d} dur={d} off={d} flags={x} n={d}", .{ tag, b[0].pts, b[0].dts, b[0].duration, b[0].offset, b[0].mini_object.flags, c.gst_buffer_n_memory(b) });
}

fn rtpHeader(tag: []const u8, b: [*c]c.GstBuffer) void {
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    if (c.gst_rtp_buffer_map(b, c.GST_MAP_READ, &rtp) == 0) {
        out("  {s} not rtp", .{tag});
        return;
    }
    defer c.gst_rtp_buffer_unmap(&rtp);
    out("  {s} v={d} p={d} x={d} m={d} pt={d} seq={d} ts={d} ssrc={x} cc={d} hlen={d} plen={d} len={d}", .{ tag, c.gst_rtp_buffer_get_version(&rtp), c.gst_rtp_buffer_get_padding(&rtp), c.gst_rtp_buffer_get_extension(&rtp), c.gst_rtp_buffer_get_marker(&rtp), c.gst_rtp_buffer_get_payload_type(&rtp), c.gst_rtp_buffer_get_seq(&rtp), c.gst_rtp_buffer_get_timestamp(&rtp), c.gst_rtp_buffer_get_ssrc(&rtp), c.gst_rtp_buffer_get_csrc_count(&rtp), c.gst_rtp_buffer_get_header_len(&rtp), c.gst_rtp_buffer_get_payload_len(&rtp), c.gst_rtp_buffer_get_packet_len(&rtp) });
    var i: u8 = 0;
    while (i < c.gst_rtp_buffer_get_csrc_count(&rtp)) : (i += 1) out("    csrc {d} {x}", .{ i, c.gst_rtp_buffer_get_csrc(&rtp, i) });
    var bits: u16 = 0;
    var data: c.gpointer = null;
    var wl: c.guint = 0;
    if (c.gst_rtp_buffer_get_extension_data(&rtp, &bits, &data, &wl) != 0) {
        out("    ext bits={x} words={d}", .{ bits, wl });
        hex("ext", @ptrCast(data), wl * 4);
    }
    hex("payload", @ptrCast(c.gst_rtp_buffer_get_payload(&rtp)), c.gst_rtp_buffer_get_payload_len(&rtp));
}

fn rtpBuffers() void {
    out("rtp buffers", .{});
    out("  calc {d} {d} {d}", .{ c.gst_rtp_buffer_calc_header_len(3), c.gst_rtp_buffer_calc_packet_len(100, 4, 2), c.gst_rtp_buffer_calc_payload_len(200, 8, 1) });
    out("  bad calc {d}", .{c.gst_rtp_buffer_calc_header_len(16)});
    const b = c.gst_rtp_buffer_new_allocate(10, 4, 2);
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    out("  map {d}", .{c.gst_rtp_buffer_map(b, c.GST_MAP_READWRITE, &rtp)});
    c.gst_rtp_buffer_set_marker(&rtp, 1);
    c.gst_rtp_buffer_set_payload_type(&rtp, 96);
    c.gst_rtp_buffer_set_seq(&rtp, 65535);
    c.gst_rtp_buffer_set_timestamp(&rtp, 0xdeadbeef);
    c.gst_rtp_buffer_set_ssrc(&rtp, 0x11223344);
    c.gst_rtp_buffer_set_csrc(&rtp, 0, 0xaaaa);
    c.gst_rtp_buffer_set_csrc(&rtp, 1, 0xbbbb);
    const pl: [*c]u8 = @ptrCast(c.gst_rtp_buffer_get_payload(&rtp));
    for (0..10) |i| pl[i] = @intCast(i * 3);
    out("  add one {d}", .{c.gst_rtp_buffer_add_extension_onebyte_header(&rtp, 1, "ab", 2)});
    out("  add one {d}", .{c.gst_rtp_buffer_add_extension_onebyte_header(&rtp, 2, "xyz", 3)});
    out("  add one again {d}", .{c.gst_rtp_buffer_add_extension_onebyte_header(&rtp, 1, "q", 1)});
    var d: c.gpointer = null;
    var sz: c.guint = 0;
    var nth: c.guint = 0;
    while (c.gst_rtp_buffer_get_extension_onebyte_header(&rtp, 1, nth, &d, &sz) != 0) : (nth += 1) hex("one id1", @ptrCast(d), sz);
    out("  missing {d}", .{c.gst_rtp_buffer_get_extension_onebyte_header(&rtp, 5, 0, &d, &sz)});
    c.gst_rtp_buffer_unmap(&rtp);
    rtpHeader("b", b);
    bufHex("raw", b);
    _ = c.gst_rtp_buffer_map(b, c.GST_MAP_READ, &rtp);
    const sub = c.gst_rtp_buffer_get_payload_subbuffer(&rtp, 2, 5);
    bufHex("sub", sub);
    c.gst_buffer_unref(sub);
    const all = c.gst_rtp_buffer_get_payload_buffer(&rtp);
    bufHex("all", all);
    c.gst_buffer_unref(all);
    const bytes = c.gst_rtp_buffer_get_payload_bytes(&rtp);
    var bl: usize = 0;
    hex("bytes", @ptrCast(c.g_bytes_get_data(bytes, &bl)), bl);
    c.g_bytes_unref(bytes);
    var bits: u16 = 0;
    const eb = c.gst_rtp_buffer_get_extension_bytes(&rtp, &bits);
    hex("extbytes", @ptrCast(c.g_bytes_get_data(eb, &bl)), bl);
    out("  from bytes {d}", .{c.gst_rtp_buffer_get_extension_onebyte_header_from_bytes(eb, bits, 2, 0, &d, &sz)});
    hex("frombytes", @ptrCast(d), sz);
    c.g_bytes_unref(eb);
    c.gst_rtp_buffer_unmap(&rtp);
    const w = c.gst_buffer_make_writable(b);
    _ = c.gst_rtp_buffer_map(w, c.GST_MAP_READWRITE, &rtp);
    c.gst_rtp_buffer_remove_extension_data(&rtp);
    c.gst_rtp_buffer_pad_to(&rtp, 0);
    c.gst_rtp_buffer_unmap(&rtp);
    rtpHeader("removed", w);
    c.gst_buffer_unref(w);

    const t = c.gst_rtp_buffer_new_allocate(4, 0, 0);
    _ = c.gst_rtp_buffer_map(t, c.GST_MAP_READWRITE, &rtp);
    out("  two {d}", .{c.gst_rtp_buffer_add_extension_twobytes_header(&rtp, 5, 9, "hello", 5)});
    out("  two {d}", .{c.gst_rtp_buffer_add_extension_twobytes_header(&rtp, 5, 200, "", 0)});
    var app: u8 = 0;
    out("  get two {d}", .{c.gst_rtp_buffer_get_extension_twobytes_header(&rtp, &app, 9, 0, &d, &sz)});
    hex("two", @ptrCast(d), sz);
    out("  appbits {d}", .{app});
    out("  ext set {d}", .{c.gst_rtp_buffer_set_extension_data(&rtp, 0x1234, 3)});
    c.gst_rtp_buffer_set_packet_len(&rtp, 40);
    c.gst_rtp_buffer_set_version(&rtp, 2);
    c.gst_rtp_buffer_set_padding(&rtp, 0);
    c.gst_rtp_buffer_set_extension(&rtp, 1);
    c.gst_rtp_buffer_unmap(&rtp);
    rtpHeader("two", t);
    c.gst_buffer_unref(t);

    var raw = [_]u8{ 0xa0, 0x08, 0x00, 0x05, 0, 0, 0, 9, 0, 0, 0, 7, 1, 2, 3, 4, 5, 0, 0, 3 };
    const pb = c.gst_rtp_buffer_new_copy_data(&raw, raw.len);
    rtpHeader("padded", pb);
    _ = c.gst_rtp_buffer_map(pb, c.GST_MAP_READ | c.GST_RTP_BUFFER_MAP_FLAG_SKIP_PADDING, &rtp);
    out("  skip padding plen={d} p={d}", .{ c.gst_rtp_buffer_get_payload_len(&rtp), c.gst_rtp_buffer_get_padding(&rtp) });
    c.gst_rtp_buffer_unmap(&rtp);
    c.gst_buffer_unref(pb);
    for ([_]u8{ 0x80, 0x40, 0xa0 }, [_]usize{ 8, 12, 12 }) |h0, n| {
        var bad = [_]u8{ h0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 0 };
        bad[n - 1] = 0x20;
        const bb = c.gst_rtp_buffer_new_copy_data(&bad, n);
        out("  bad map {d}", .{c.gst_rtp_buffer_map(bb, c.GST_MAP_READ, &rtp)});
        if (rtp.buffer != null) c.gst_rtp_buffer_unmap(&rtp);
        c.gst_buffer_unref(bb);
    }
    for ([_][2]u16{ .{ 1, 2 }, .{ 2, 1 }, .{ 65535, 0 }, .{ 0, 65535 }, .{ 100, 100 }, .{ 0, 32768 } }) |p| out("  cmp {d} {d} = {d}", .{ p[0], p[1], c.gst_rtp_buffer_compare_seqnum(p[0], p[1]) });
    var ext: u64 = NONE;
    for ([_]u32{ 10, 4000000000, 100, 4294967295, 5, 2147483648 }) |ts| out("  ext {d} -> {d}", .{ ts, c.gst_rtp_buffer_ext_timestamp(&ext, ts) });
    for ([_]u8{ 0, 3, 8, 9, 13, 14, 25, 26, 31, 32, 33, 34, 35, 96, 127 }) |pt| {
        const info = c.gst_rtp_payload_info_for_pt(pt);
        if (info == null) {
            out("  pt {d} none rate={d}", .{ pt, c.gst_rtp_buffer_default_clock_rate(pt) });
        } else out("  pt {d} {s} {s} {d} {s} rate={d}", .{ pt, z(info[0].media), z(info[0].encoding_name), info[0].clock_rate, z(info[0].encoding_parameters), c.gst_rtp_buffer_default_clock_rate(pt) });
    }
    for ([_][2][*:0]const u8{ .{ "audio", "OPUS" }, .{ "video", "h264" }, .{ "audio", "PCMU" }, .{ "video", "VP8" }, .{ "application", "rtx" }, .{ "audio", "nope" }, .{ "video", "H265" }, .{ "audio", "MPA" } }) |q| {
        const info = c.gst_rtp_payload_info_for_name(q[0], q[1]);
        if (info == null) {
            out("  name {s} none", .{z(q[1])});
        } else out("  name {s} pt={d} {s} {d} br={d}", .{ z(q[1]), info[0].payload_type, z(info[0].encoding_name), info[0].clock_rate, info[0].bitrate });
    }
}

const Pkt = c.GstRTCPPacket;

fn dumpPacket(p: *Pkt) void {
    const t = c.gst_rtcp_packet_get_type(p);
    out("  packet type={d} count={d} len={d} pad={d} off={d}", .{ t, c.gst_rtcp_packet_get_count(p), c.gst_rtcp_packet_get_length(p), c.gst_rtcp_packet_get_padding(p), p.offset });
    switch (t) {
        c.GST_RTCP_TYPE_SR, c.GST_RTCP_TYPE_RR => {
            if (t == c.GST_RTCP_TYPE_SR) {
                var ssrc: u32 = 0;
                var ntp: u64 = 0;
                var rt: u32 = 0;
                var pc: u32 = 0;
                var oc: u32 = 0;
                c.gst_rtcp_packet_sr_get_sender_info(p, &ssrc, &ntp, &rt, &pc, &oc);
                out("    sr {x} {d} {d} {d} {d}", .{ ssrc, ntp, rt, pc, oc });
            } else out("    rr ssrc {x}", .{c.gst_rtcp_packet_rr_get_ssrc(p)});
            const n = c.gst_rtcp_packet_get_rb_count(p);
            var i: c.guint = 0;
            while (i < n) : (i += 1) {
                var ssrc: u32 = 0;
                var fl: u8 = 0;
                var lost: i32 = 0;
                var hs: u32 = 0;
                var j: u32 = 0;
                var lsr: u32 = 0;
                var dlsr: u32 = 0;
                c.gst_rtcp_packet_get_rb(p, i, &ssrc, &fl, &lost, &hs, &j, &lsr, &dlsr);
                out("    rb {x} {d} {d} {d} {d} {d} {d}", .{ ssrc, fl, lost, hs, j, lsr, dlsr });
            }
            out("    pse len {d}", .{c.gst_rtcp_packet_get_profile_specific_ext_length(p)});
            var data: [*c]u8 = null;
            var len: c.guint = 0;
            if (c.gst_rtcp_packet_get_profile_specific_ext(p, &data, &len) != 0) hex("pse", data, len);
            if (c.gst_rtcp_packet_copy_profile_specific_ext(p, &data, &len) != 0) {
                hex("pse copy", data, len);
                c.g_free(data);
            }
        },
        c.GST_RTCP_TYPE_SDES => {
            out("    items {d}", .{c.gst_rtcp_packet_sdes_get_item_count(p)});
            var more = c.gst_rtcp_packet_sdes_first_item(p) != 0;
            while (more) : (more = c.gst_rtcp_packet_sdes_next_item(p) != 0) {
                out("    item ssrc {x}", .{c.gst_rtcp_packet_sdes_get_ssrc(p)});
                var e = c.gst_rtcp_packet_sdes_first_entry(p) != 0;
                while (e) : (e = c.gst_rtcp_packet_sdes_next_entry(p) != 0) {
                    var ty: c.GstRTCPSDESType = 0;
                    var len: u8 = 0;
                    var data: [*c]u8 = null;
                    _ = c.gst_rtcp_packet_sdes_get_entry(p, &ty, &len, &data);
                    var copy: [*c]u8 = null;
                    _ = c.gst_rtcp_packet_sdes_copy_entry(p, null, null, &copy);
                    out("    entry {d} {d} {s} {s}", .{ ty, len, z(c.gst_rtcp_sdes_type_to_name(ty)), z(copy) });
                    c.g_free(copy);
                }
            }
        },
        c.GST_RTCP_TYPE_BYE => {
            const n = c.gst_rtcp_packet_bye_get_ssrc_count(p);
            var i: c.guint = 0;
            while (i < n) : (i += 1) out("    bye {x}", .{c.gst_rtcp_packet_bye_get_nth_ssrc(p, i)});
            const r = c.gst_rtcp_packet_bye_get_reason(p);
            out("    reason {d} {s}", .{ c.gst_rtcp_packet_bye_get_reason_len(p), z(r) });
            c.g_free(r);
        },
        c.GST_RTCP_TYPE_APP => {
            const name = c.gst_rtcp_packet_app_get_name(p);
            out("    app sub={d} ssrc={x} name={s} dlen={d}", .{ c.gst_rtcp_packet_app_get_subtype(p), c.gst_rtcp_packet_app_get_ssrc(p), name[0..4], c.gst_rtcp_packet_app_get_data_length(p) });
            const data = c.gst_rtcp_packet_app_get_data(p);
            if (data != null) hex("app data", data, @as(usize, c.gst_rtcp_packet_app_get_data_length(p)) * 4);
        },
        c.GST_RTCP_TYPE_RTPFB, c.GST_RTCP_TYPE_PSFB => {
            out("    fb type={d} sender={x} media={x} fci={d}", .{ c.gst_rtcp_packet_fb_get_type(p), c.gst_rtcp_packet_fb_get_sender_ssrc(p), c.gst_rtcp_packet_fb_get_media_ssrc(p), c.gst_rtcp_packet_fb_get_fci_length(p) });
            const fci = c.gst_rtcp_packet_fb_get_fci(p);
            if (fci != null) hex("fci", fci, @as(usize, c.gst_rtcp_packet_fb_get_fci_length(p)) * 4) else out("    no fci", .{});
        },
        c.GST_RTCP_TYPE_XR => dumpXr(p),
        else => {},
    }
}

fn dumpXr(p: *Pkt) void {
    out("    xr ssrc {x}", .{c.gst_rtcp_packet_xr_get_ssrc(p)});
    var more = c.gst_rtcp_packet_xr_first_rb(p) != 0;
    while (more) : (more = c.gst_rtcp_packet_xr_next_rb(p) != 0) {
        const t = c.gst_rtcp_packet_xr_get_block_type(p);
        out("    block type={d} len={d}", .{ t, c.gst_rtcp_packet_xr_get_block_length(p) });
        var ssrc: u32 = 0;
        var th: u8 = 0;
        var b: u16 = 0;
        var e: u16 = 0;
        switch (t) {
            c.GST_RTCP_XR_TYPE_LRLE, c.GST_RTCP_XR_TYPE_DRLE => {
                var n: u32 = 0;
                _ = c.gst_rtcp_packet_xr_get_rle_info(p, &ssrc, &th, &b, &e, &n);
                out("      rle {x} {d} {d} {d} {d}", .{ ssrc, th, b, e, n });
                var i: c.guint = 0;
                var ch: u16 = 0;
                while (c.gst_rtcp_packet_xr_get_rle_nth_chunk(p, i, &ch) != 0) : (i += 1) out("      chunk {x}", .{ch});
            },
            c.GST_RTCP_XR_TYPE_PRT => {
                _ = c.gst_rtcp_packet_xr_get_prt_info(p, &ssrc, &th, &b, &e);
                out("      prt {x} {d} {d} {d}", .{ ssrc, th, b, e });
                var seq: u16 = b -% 1;
                while (seq <= e) : (seq += 1) {
                    var rt: u32 = 0;
                    out("      prt seq {d} {d} {d}", .{ seq, c.gst_rtcp_packet_xr_get_prt_by_seq(p, seq, &rt), rt });
                }
            },
            c.GST_RTCP_XR_TYPE_RRT => {
                var ts: u64 = 0;
                out("      rrt {d} {d}", .{ c.gst_rtcp_packet_xr_get_rrt(p, &ts), ts });
            },
            c.GST_RTCP_XR_TYPE_DLRR => {
                var i: c.guint = 0;
                var lrr: u32 = 0;
                var dl: u32 = 0;
                while (c.gst_rtcp_packet_xr_get_dlrr_block(p, i, &ssrc, &lrr, &dl) != 0) : (i += 1) out("      dlrr {x} {d} {d}", .{ ssrc, lrr, dl });
            },
            c.GST_RTCP_XR_TYPE_SSUMM => {
                _ = c.gst_rtcp_packet_xr_get_summary_info(p, &ssrc, &b, &e);
                var lost: u32 = 0;
                var dup: u32 = 0;
                _ = c.gst_rtcp_packet_xr_get_summary_pkt(p, &lost, &dup);
                var j = [_]u32{ 0, 0, 0, 0 };
                _ = c.gst_rtcp_packet_xr_get_summary_jitter(p, &j[0], &j[1], &j[2], &j[3]);
                var v4: c.gboolean = 0;
                var tt = [_]u8{ 0, 0, 0, 0 };
                const ok = c.gst_rtcp_packet_xr_get_summary_ttl(p, &v4, &tt[0], &tt[1], &tt[2], &tt[3]);
                out("      ssumm {x} {d} {d} lost={d} dup={d} j={d},{d},{d},{d} ttl={d} {d} {d},{d},{d},{d}", .{ ssrc, b, e, lost, dup, j[0], j[1], j[2], j[3], ok, v4, tt[0], tt[1], tt[2], tt[3] });
            },
            c.GST_RTCP_XR_TYPE_VOIP_METRICS => {
                _ = c.gst_rtcp_packet_xr_get_voip_metrics_ssrc(p, &ssrc);
                var a = [_]u8{0} ** 12;
                var s = [_]u16{0} ** 7;
                _ = c.gst_rtcp_packet_xr_get_voip_packet_metrics(p, &a[0], &a[1]);
                _ = c.gst_rtcp_packet_xr_get_voip_burst_metrics(p, &a[2], &a[3], &s[0], &s[1]);
                _ = c.gst_rtcp_packet_xr_get_voip_delay_metrics(p, &s[2], &s[3]);
                _ = c.gst_rtcp_packet_xr_get_voip_signal_metrics(p, &a[4], &a[5], &a[6], &a[7]);
                _ = c.gst_rtcp_packet_xr_get_voip_quality_metrics(p, &a[8], &a[9], &a[10], &a[11]);
                var g: u8 = 0;
                var rx: u8 = 0;
                _ = c.gst_rtcp_packet_xr_get_voip_configuration_params(p, &g, &rx);
                _ = c.gst_rtcp_packet_xr_get_voip_jitter_buffer_params(p, &s[4], &s[5], &s[6]);
                out("      voip {x} {any} {any} {d} {d}", .{ ssrc, a, s, g, rx });
            },
            else => {},
        }
    }
}

fn dumpRtcp(tag: []const u8, b: [*c]c.GstBuffer) void {
    out(" {s} valid={d} reduced={d}", .{ tag, c.gst_rtcp_buffer_validate(b), c.gst_rtcp_buffer_validate_reduced(b) });
    bufHex("rtcp", b);
    var r = std.mem.zeroes(c.GstRTCPBuffer);
    _ = c.gst_rtcp_buffer_map(b, c.GST_MAP_READ, &r);
    defer _ = c.gst_rtcp_buffer_unmap(&r);
    out("  count {d}", .{c.gst_rtcp_buffer_get_packet_count(&r)});
    var p: Pkt = undefined;
    var more = c.gst_rtcp_buffer_get_first_packet(&r, &p) != 0;
    while (more) : (more = c.gst_rtcp_packet_move_to_next(&p) != 0) dumpPacket(&p);
}

const Bytes = struct {
    d: [256]u8 = [_]u8{0} ** 256,
    n: usize = 0,

    fn b8(s: *Bytes, v: u8) void {
        s.d[s.n] = v;
        s.n += 1;
    }

    fn b16(s: *Bytes, v: u16) void {
        std.mem.writeInt(u16, s.d[s.n..][0..2], v, .big);
        s.n += 2;
    }

    fn b32(s: *Bytes, v: u32) void {
        std.mem.writeInt(u32, s.d[s.n..][0..4], v, .big);
        s.n += 4;
    }
};

fn xrBytes() Bytes {
    var s = Bytes{};
    s.b8(0x80);
    s.b8(207);
    s.b16(36);
    s.b32(0xabcdef01);
    s.b8(4);
    s.b8(0);
    s.b16(2);
    s.b32(0x01020304);
    s.b32(0x05060708);
    s.b8(5);
    s.b8(0);
    s.b16(3);
    s.b32(0x1111);
    s.b32(222);
    s.b32(333);
    s.b8(1);
    s.b8(2);
    s.b16(3);
    s.b32(0x2222);
    s.b16(10);
    s.b16(20);
    s.b16(0x8001);
    s.b16(0x4002);
    s.b8(3);
    s.b8(1);
    s.b16(4);
    s.b32(0x3333);
    s.b16(5);
    s.b16(7);
    s.b32(1000);
    s.b32(2000);
    s.b8(6);
    s.b8(0x80 | 0x40 | 0x20 | 0x08);
    s.b16(9);
    s.b32(0x4444);
    s.b16(1);
    s.b16(50);
    for (0..6) |i| s.b32(@intCast(100 + i));
    for (0..4) |i| s.b8(@intCast(60 + i));
    s.b8(7);
    s.b8(0);
    s.b16(8);
    s.b32(0x5555);
    for (0..28) |i| s.b8(@intCast(i + 1));
    return s;
}

fn rtcpTests() void {
    out("rtcp", .{});
    const b = c.gst_rtcp_buffer_new(1400);
    var r = std.mem.zeroes(c.GstRTCPBuffer);
    _ = c.gst_rtcp_buffer_map(b, c.GST_MAP_READWRITE, &r);
    var p: Pkt = undefined;
    out("  add sr {d}", .{c.gst_rtcp_buffer_add_packet(&r, c.GST_RTCP_TYPE_SR, &p)});
    c.gst_rtcp_packet_sr_set_sender_info(&p, 0x1234, 0xe1234567_89abcdef, 90000, 10, 1000);
    out("  rb {d}", .{c.gst_rtcp_packet_add_rb(&p, 0x55, 12, -3, 70000, 9, 8, 7)});
    out("  rb {d}", .{c.gst_rtcp_packet_add_rb(&p, 0x66, 255, 0x7fffff, 1, 2, 3, 4)});
    out("  rr count {d}", .{c.gst_rtcp_packet_get_rb_count(&p)});
    out("  add rr {d}", .{c.gst_rtcp_buffer_add_packet(&r, c.GST_RTCP_TYPE_RR, &p)});
    c.gst_rtcp_packet_rr_set_ssrc(&p, 0x77);
    out("  rb {d}", .{c.gst_rtcp_packet_add_rb(&p, 0x88, 1, -100, 2, 3, 4, 5)});
    const pse = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    out("  pse {d}", .{c.gst_rtcp_packet_add_profile_specific_ext(&p, &pse, 8)});
    out("  rb after pse {d}", .{c.gst_rtcp_packet_add_rb(&p, 0x99, 1, 1, 1, 1, 1, 1)});
    c.gst_rtcp_packet_set_rb(&p, 0, 1, 2, 3, 4, 5, 6, 7);
    out("  add sdes {d}", .{c.gst_rtcp_buffer_add_packet(&r, c.GST_RTCP_TYPE_SDES, &p)});
    out("  item {d}", .{c.gst_rtcp_packet_sdes_add_item(&p, 0xaaaa)});
    out("  entry {d}", .{c.gst_rtcp_packet_sdes_add_entry(&p, c.GST_RTCP_SDES_CNAME, 9, "user@host")});
    out("  entry {d}", .{c.gst_rtcp_packet_sdes_add_entry(&p, c.GST_RTCP_SDES_NAME, 4, "Name")});
    out("  item {d}", .{c.gst_rtcp_packet_sdes_add_item(&p, 0xbbbb)});
    out("  entry {d}", .{c.gst_rtcp_packet_sdes_add_entry(&p, c.GST_RTCP_SDES_TOOL, 3, "gst")});
    out("  add bye {d}", .{c.gst_rtcp_buffer_add_packet(&r, c.GST_RTCP_TYPE_BYE, &p)});
    var ss = [_]u32{ 1, 2, 3 };
    out("  ssrcs {d}", .{c.gst_rtcp_packet_bye_add_ssrcs(&p, &ss, 3)});
    out("  reason {d}", .{c.gst_rtcp_packet_bye_set_reason(&p, "going away")});
    out("  add app {d}", .{c.gst_rtcp_buffer_add_packet(&r, c.GST_RTCP_TYPE_APP, &p)});
    c.gst_rtcp_packet_app_set_subtype(&p, 5);
    c.gst_rtcp_packet_app_set_ssrc(&p, 0xcafe);
    c.gst_rtcp_packet_app_set_name(&p, "TEST");
    out("  app len {d}", .{c.gst_rtcp_packet_app_set_data_length(&p, 2)});
    const ad = c.gst_rtcp_packet_app_get_data(&p);
    for (0..8) |i| ad[i] = @intCast(0x40 + i);
    out("  add rtpfb {d}", .{c.gst_rtcp_buffer_add_packet(&r, c.GST_RTCP_TYPE_RTPFB, &p)});
    c.gst_rtcp_packet_fb_set_type(&p, c.GST_RTCP_RTPFB_TYPE_NACK);
    c.gst_rtcp_packet_fb_set_sender_ssrc(&p, 0x10);
    c.gst_rtcp_packet_fb_set_media_ssrc(&p, 0x20);
    out("  fci {d}", .{c.gst_rtcp_packet_fb_set_fci_length(&p, 1)});
    const fci = c.gst_rtcp_packet_fb_get_fci(&p);
    fci[0] = 0;
    fci[1] = 42;
    fci[2] = 0;
    fci[3] = 5;
    out("  add psfb {d}", .{c.gst_rtcp_buffer_add_packet(&r, c.GST_RTCP_TYPE_PSFB, &p)});
    c.gst_rtcp_packet_fb_set_type(&p, c.GST_RTCP_PSFB_TYPE_PLI);
    out("  add invalid {d}", .{c.gst_rtcp_buffer_add_packet(&r, 199, &p)});
    out("  bad guard {d}", .{c.gst_rtcp_packet_bye_get_ssrc_count(&p)});
    out("  bad guard {d}", .{c.gst_rtcp_packet_sdes_get_item_count(&p)});
    _ = c.gst_rtcp_buffer_unmap(&r);
    dumpRtcp("compound", b);

    _ = c.gst_rtcp_buffer_map(b, c.GST_MAP_READWRITE, &r);
    _ = c.gst_rtcp_buffer_get_first_packet(&r, &p);
    _ = c.gst_rtcp_packet_move_to_next(&p);
    out("  remove {d}", .{c.gst_rtcp_packet_remove(&p)});
    out("  after remove type {d}", .{p.type});
    _ = c.gst_rtcp_buffer_unmap(&r);
    dumpRtcp("removed", b);
    c.gst_buffer_unref(b);

    var x = xrBytes();
    const xb = c.gst_rtcp_buffer_new_copy_data(&x.d, @intCast(x.n));
    dumpRtcp("xr", xb);
    c.gst_buffer_unref(xb);

    var bad = [_]u8{ 0x81, 201, 0, 1, 0, 0, 0, 1, 0x80, 202, 0, 0 };
    out("  validate {d} {d}", .{ c.gst_rtcp_buffer_validate_data(&bad, bad.len), c.gst_rtcp_buffer_validate_data_reduced(&bad, bad.len) });
    var sr = [_]u8{ 0x80, 200, 0, 0, 0xa0, 202, 0, 1, 0, 0, 0, 4 };
    out("  validate pad {d}", .{c.gst_rtcp_buffer_validate_data(&sr, sr.len)});
    out("  validate short {d}", .{c.gst_rtcp_buffer_validate_data(&sr, 3)});
    var sr2 = [_]u8{ 0x80, 200, 0, 0, 0x40, 202, 0, 0 };
    out("  validate ver {d}", .{c.gst_rtcp_buffer_validate_data(&sr2, sr2.len)});
    var red = [_]u8{ 0x80, 205, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2 };
    out("  validate reduced {d} {d}", .{ c.gst_rtcp_buffer_validate_data(&red, red.len), c.gst_rtcp_buffer_validate_data_reduced(&red, red.len) });
    for ([_]u64{ 0, 1000000000, 1729000000123456789 }) |u| {
        const n = c.gst_rtcp_unix_to_ntp(u);
        out("  ntp {d} -> {d} -> {d}", .{ u, n, c.gst_rtcp_ntp_to_unix(n) });
    }
    var t: c_int = -1;
    while (t < 18) : (t += 1) out("  sdes {d} {s}", .{ t, z(c.gst_rtcp_sdes_type_to_name(t)) });
    for ([_][*c]const u8{ "cname", "location", "mid", "rtp-stream-id", "priv", "weird", "", null }) |n| out("  sdes name {s} {d}", .{ z(n), c.gst_rtcp_sdes_name_to_type(n) });
}

fn enums() void {
    out("enums", .{});
    const types = [_]c.GType{ c.gst_rtcp_type_get_type(), c.gst_rtcpfb_type_get_type(), c.gst_rtcpsdes_type_get_type(), c.gst_rtcpxr_type_get_type(), c.gst_rtp_buffer_flags_get_type(), c.gst_rtp_buffer_map_flags_get_type(), c.gst_rtp_profile_get_type(), c.gst_rtp_header_extension_flags_get_type(), c.gst_rtp_header_extension_direction_get_type(), c.gst_rtp_payload_get_type() };
    for (types) |t| {
        out("  {s} flags={d}", .{ z(c.g_type_name(t)), @intFromBool(c.g_type_is_a(t, c.G_TYPE_FLAGS) != 0) });
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
}

fn metaTest() void {
    out("meta", .{});
    const b = c.gst_buffer_new();
    const ssrc: u32 = 0x42;
    const csrc = [_]u32{ 1, 2, 3 };
    const m = c.gst_buffer_add_rtp_source_meta(b, &ssrc, &csrc, 3);
    out("  count {d} valid={d}", .{ c.gst_rtp_source_meta_get_source_count(m), m[0].ssrc_valid });
    const more = [_]u32{ 9, 10 };
    out("  append {d} count {d}", .{ c.gst_rtp_source_meta_append_csrc(m, &more, 2), c.gst_rtp_source_meta_get_source_count(m) });
    const lots = [_]u32{0} ** 12;
    out("  append many {d}", .{c.gst_rtp_source_meta_append_csrc(m, &lots, 12)});
    const cp = c.gst_buffer_copy(b);
    const m2 = c.gst_buffer_get_rtp_source_meta(cp);
    out("  copied ssrc={x} n={d} {any}", .{ m2[0].ssrc, m2[0].csrc_count, m2[0].csrc[0..m2[0].csrc_count] });
    out("  set none {d} count {d}", .{ c.gst_rtp_source_meta_set_ssrc(m2, null), c.gst_rtp_source_meta_get_source_count(m2) });
    out("  info {s} api {s}", .{ z(c.g_type_name(c.gst_rtp_source_meta_get_info()[0].type)), z(c.g_type_name(c.gst_rtp_source_meta_api_get_type())) });
    out("  bad {d}", .{@intFromBool(c.gst_buffer_add_rtp_source_meta(b, null, null, 16) == null)});
    c.gst_buffer_unref(cp);
    c.gst_buffer_unref(b);
}

const URI = "urn:sinty:test-ext";

fn extFlags(_: [*c]c.GstRTPHeaderExtension) callconv(.c) c.GstRTPHeaderExtensionFlags {
    return c.GST_RTP_HEADER_EXTENSION_ONE_BYTE | c.GST_RTP_HEADER_EXTENSION_TWO_BYTE;
}

fn extMax(_: [*c]c.GstRTPHeaderExtension, _: [*c]const c.GstBuffer) callconv(.c) c.gsize {
    return 4;
}

fn extWrite(_: [*c]c.GstRTPHeaderExtension, in: [*c]const c.GstBuffer, flags: c.GstRTPHeaderExtensionFlags, _: [*c]c.GstBuffer, data: [*c]u8, size: c.gsize) callconv(.c) c.gssize {
    const v: u8 = if (in[0].pts == NONE) 0xee else @truncate(in[0].pts / 1000000);
    out("    ext write flags={d} room={d} v={d}", .{ flags, size, v });
    data[0] = 0xaa;
    data[1] = v;
    data[2] = 0x55;
    return 3;
}

fn extRead(_: [*c]c.GstRTPHeaderExtension, flags: c.GstRTPHeaderExtensionFlags, data: [*c]const u8, size: c.gsize, b: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    out("    ext read flags={d}", .{flags});
    hex("ext data", data, size);
    b[0].offset_end = data[1];
    return 1;
}

fn extAttrs(_: [*c]c.GstRTPHeaderExtension, d: c.GstRTPHeaderExtensionDirection, a: [*c]const u8) callconv(.c) c.gboolean {
    out("    ext attrs dir={d} attrs={s}", .{ d, z(a) });
    return @intFromBool(a == null or !std.mem.eql(u8, std.mem.span(a), "reject"));
}

fn extClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const xk: *c.GstRTPHeaderExtensionClass = @ptrCast(@alignCast(k));
    xk.get_supported_flags = extFlags;
    xk.get_max_size = extMax;
    xk.write = extWrite;
    xk.read = extRead;
    xk.set_attributes = extAttrs;
    c.gst_element_class_set_static_metadata(@ptrCast(xk), "Test ext", "Network/Extension/RTPHeader", "test", "x");
    c.gst_rtp_header_extension_class_set_uri(xk, URI);
}

fn extType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_rtp_header_extension_get_type(), "TestRtpExt", @sizeOf(c.GstRTPHeaderExtensionClass), extClass, @sizeOf(c.GstRTPHeaderExtension), null, 0);
    return S.v;
}

fn hdrextTest() void {
    out("hdrext", .{});
    var d = [_]u8{0} ** 8;
    var v: u64 = 0;
    out("  ntp64 {d} {d}", .{ c.gst_rtp_hdrext_set_ntp_64(&d, 8, 0x0102030405060708), c.gst_rtp_hdrext_get_ntp_64(&d, 8, &v) });
    out("  {x}", .{v});
    out("  ntp56 {d} {d}", .{ c.gst_rtp_hdrext_set_ntp_56(&d, 7, 0xff01020304050607), c.gst_rtp_hdrext_get_ntp_56(&d, 7, &v) });
    out("  {x}", .{v});
    out("  small {d}", .{c.gst_rtp_hdrext_get_ntp_64(&d, 4, &v)});
    _ = c.gst_element_register(null, "testrtpext", c.GST_RANK_MARGINAL, extType());
    const l = c.gst_rtp_get_header_extension_list();
    var names = std.ArrayList([]const u8).empty;
    var it = l;
    while (it != null) : (it = it[0].next) names.append(std.heap.c_allocator, z(@as(*c.GstObject, @ptrCast(@alignCast(it[0].data))).name)) catch unreachable;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.f);
    for (names.items) |n| out("  factory {s}", .{n});
    c.gst_plugin_feature_list_free(l);
    const e = c.gst_rtp_header_extension_create_from_uri(URI);
    out("  created {d} uri={s} id={d} dir={d}", .{ @intFromBool(e != null), z(c.gst_rtp_header_extension_get_uri(e)), c.gst_rtp_header_extension_get_id(e), c.gst_rtp_header_extension_get_direction(e) });
    out("  none {d}", .{@intFromBool(c.gst_rtp_header_extension_create_from_uri("urn:none") == null)});
    c.gst_rtp_header_extension_set_id(e, 300);
    c.gst_rtp_header_extension_set_id(e, 3);
    const field = c.gst_rtp_header_extension_get_sdp_caps_field_name(e);
    out("  field {s} flags={d}", .{ z(field), c.gst_rtp_header_extension_get_supported_flags(e) });
    c.g_free(field);
    for ([_]c.GstRTPHeaderExtensionDirection{ c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDRECV | c.GST_RTP_HEADER_EXTENSION_DIRECTION_INHERITED, c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDONLY, c.GST_RTP_HEADER_EXTENSION_DIRECTION_RECVONLY, c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDRECV, c.GST_RTP_HEADER_EXTENSION_DIRECTION_INACTIVE, 9 }) |dir| {
        c.gst_rtp_header_extension_set_direction(e, dir);
        const caps = c.gst_caps_new_empty_simple("application/x-rtp");
        out("  dir {d} caps {d}", .{ c.gst_rtp_header_extension_get_direction(e), c.gst_rtp_header_extension_set_caps_from_attributes(e, caps) });
        const s = c.gst_caps_to_string(caps);
        out("   {s}", .{z(s)});
        c.g_free(s);
        c.gst_caps_unref(caps);
    }
    const caps = c.gst_caps_new_empty_simple("application/x-rtp");
    _ = c.gst_rtp_header_extension_set_caps_from_attributes_helper(e, caps, "a=1");
    const s = c.gst_caps_to_string(caps);
    out("  helper {s}", .{z(s)});
    c.g_free(s);
    c.gst_caps_unref(caps);
    for ([_][*:0]const u8{ "application/x-rtp, extmap-3=(string)urn:sinty:test-ext", "application/x-rtp, extmap-3=(string)URN:SINTY:TEST-EXT", "application/x-rtp, extmap-3=(string)urn:other", "application/x-rtp, extmap-3=<\"sendonly\", \"urn:sinty:test-ext\", \"x y\">", "application/x-rtp, extmap-3=<\"\", \"urn:sinty:test-ext\", \"\">", "application/x-rtp, extmap-3=<\"bogus\", \"urn:sinty:test-ext\", \"\">", "application/x-rtp, extmap-3=<\"recvonly\", \"urn:sinty:test-ext\", \"reject\">", "application/x-rtp, extmap-3=(int)5", "application/x-rtp, extmap-4=(string)urn:sinty:test-ext" }) |text| {
        const cc = c.gst_caps_from_string(text);
        out("  attrs {s} -> {d} dir={d}", .{ z(text), c.gst_rtp_header_extension_set_attributes_from_caps(e, cc), c.gst_rtp_header_extension_get_direction(e) });
        c.gst_caps_unref(cc);
    }
    out("  wants {d}", .{c.gst_rtp_header_extension_wants_update_non_rtp_src_caps(e)});
    c.gst_rtp_header_extension_set_wants_update_non_rtp_src_caps(e, 1);
    const wc = c.gst_caps_new_empty_simple("video/x-raw");
    out("  update {d} wants {d} sink {d}", .{ c.gst_rtp_header_extension_update_non_rtp_src_caps(e, wc), c.gst_rtp_header_extension_wants_update_non_rtp_src_caps(e), c.gst_rtp_header_extension_set_non_rtp_sink_caps(e, wc) });
    c.gst_caps_unref(wc);
    const in = c.gst_buffer_new();
    in[0].pts = 7000000;
    const ob = c.gst_buffer_new();
    var room = [_]u8{0} ** 8;
    out("  max {d} write {d}", .{ c.gst_rtp_header_extension_get_max_size(e, in), c.gst_rtp_header_extension_write(e, in, c.GST_RTP_HEADER_EXTENSION_ONE_BYTE, ob, &room, room.len) });
    out("  read {d} off_end {d}", .{ c.gst_rtp_header_extension_read(e, c.GST_RTP_HEADER_EXTENSION_ONE_BYTE, &room, 3, ob), ob[0].offset_end });
    c.gst_buffer_unref(in);
    c.gst_buffer_unref(ob);
    c.gst_object_unref(e);
}

var captured: std.ArrayList([*c]c.GstBuffer) = .empty;

fn sinkChain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    captured.append(std.heap.c_allocator, b) catch unreachable;
    return c.GST_FLOW_OK;
}

fn sinkEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    switch (ev[0].type) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            const s = c.gst_caps_to_string(caps);
            out("  sink caps {s}", .{z(s)});
            c.g_free(s);
        },
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(ev, &seg);
            out("  sink segment fmt={d} rate={d} ar={d} start={d} stop={d} time={d} pos={d} base={d}", .{ seg[0].format, seg[0].rate, seg[0].applied_rate, seg[0].start, seg[0].stop, seg[0].time, seg[0].position, seg[0].base });
        },
        c.GST_EVENT_GAP => {
            var ts: u64 = 0;
            var dur: u64 = 0;
            c.gst_event_parse_gap(ev, &ts, &dur);
            var fl: c.GstGapFlags = 0;
            c.gst_event_parse_gap_flags(ev, &fl);
            out("  sink gap {d} {d} {d}", .{ ts, dur, fl });
        },
        else => out("  sink event {s}", .{z(c.gst_event_type_get_name(ev[0].type))}),
    }
    return c.gst_pad_event_default(pad, parent, ev);
}

fn drain(tag: []const u8, rtp: bool) void {
    for (captured.items) |b| {
        bufInfo(tag, b);
        if (rtp) rtpHeader(tag, b) else bufHex(tag, b);
        c.gst_buffer_unref(b);
    }
    captured.clearRetainingCapacity();
}

fn sinkPad() ?*c.GstPad {
    const p = c.gst_pad_new("tsink", c.GST_PAD_SINK);
    c.gst_pad_set_chain_function_full(p, sinkChain, null, null);
    c.gst_pad_set_event_function_full(p, sinkEvent, null, null);
    _ = c.gst_pad_set_active(p, 1);
    return p;
}

fn srcPad() ?*c.GstPad {
    const p = c.gst_pad_new("tsrc", c.GST_PAD_SRC);
    _ = c.gst_pad_set_active(p, 1);
    return p;
}

fn startStream(src: ?*c.GstPad, caps: [*:0]const u8) void {
    _ = c.gst_pad_push_event(src, c.gst_event_new_stream_start("rtp1"));
    const cc = c.gst_caps_from_string(caps);
    _ = c.gst_pad_push_event(src, c.gst_event_new_caps(cc));
    c.gst_caps_unref(cc);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    const ev = c.gst_event_new_segment(&seg);
    c.gst_event_set_seqnum(ev, 77);
    _ = c.gst_pad_push_event(src, ev);
}

fn templ(k: c.gpointer, name: [*:0]const u8, dir: c.GstPadDirection, caps: [*:0]const u8) void {
    const cc = c.gst_caps_from_string(caps);
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new(name, dir, c.GST_PAD_ALWAYS, cc));
    c.gst_caps_unref(cc);
}

fn payHandle(p: [*c]c.GstRTPBasePayload, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const n: c.guint = @intCast(c.gst_buffer_get_size(b));
    const o = c.gst_rtp_base_payload_allocate_output_buffer(p, n, 0, 1);
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    _ = c.gst_rtp_buffer_map(o, c.GST_MAP_WRITE, &rtp);
    _ = c.gst_buffer_extract(b, 0, c.gst_rtp_buffer_get_payload(&rtp), n);
    c.gst_rtp_buffer_set_csrc(&rtp, 0, 0xc0c0);
    c.gst_rtp_buffer_unmap(&rtp);
    o[0].pts = b[0].pts;
    o[0].offset = b[0].offset;
    out("    filled {d} {d}", .{ c.gst_rtp_base_payload_is_filled(p, n, 30000000), c.gst_rtp_base_payload_get_source_count(p, b) });
    c.gst_buffer_unref(b);
    return c.gst_rtp_base_payload_push(p, o);
}

fn paySetCaps(p: [*c]c.GstRTPBasePayload, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    c.gst_rtp_base_payload_set_options(p, "application", 1, "X-TEST", 90000);
    return c.gst_rtp_base_payload_set_outcaps(p, "extra", c.G_TYPE_STRING, "v", "ptime", c.G_TYPE_UINT, @as(c.guint, 20), N);
}

fn payClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const pk: *c.GstRTPBasePayloadClass = @ptrCast(@alignCast(k));
    pk.handle_buffer = payHandle;
    pk.set_caps = paySetCaps;
    templ(k, "src", c.GST_PAD_SRC, "application/x-rtp");
    templ(k, "sink", c.GST_PAD_SINK, "application/x-test");
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "TestPay", "Codec/Payloader/Network/RTP", "t", "x");
}

fn payType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_rtp_base_payload_get_type(), "TestRtpPay", @sizeOf(c.GstRTPBasePayloadClass), payClass, @sizeOf(c.GstRTPBasePayload), null, 0);
    return S.v;
}

fn depayProcess(_: [*c]c.GstRTPBaseDepayload, rtp: [*c]c.GstRTPBuffer) callconv(.c) [*c]c.GstBuffer {
    return c.gst_rtp_buffer_get_payload_buffer(rtp);
}

fn depaySetCaps(d: [*c]c.GstRTPBaseDepayload, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = c.gst_caps_get_structure(caps, 0);
    var rate: c.gint = 0;
    _ = c.gst_structure_get_int(s, "clock-rate", &rate);
    d[0].clock_rate = @intCast(rate);
    const cc = c.gst_caps_new_empty_simple("application/x-test");
    defer c.gst_caps_unref(cc);
    return c.gst_pad_push_event(d[0].srcpad, c.gst_event_new_caps(cc));
}

fn depayClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const dk: *c.GstRTPBaseDepayloadClass = @ptrCast(@alignCast(k));
    dk.process_rtp_packet = depayProcess;
    dk.set_caps = depaySetCaps;
    templ(k, "sink", c.GST_PAD_SINK, "application/x-rtp");
    templ(k, "src", c.GST_PAD_SRC, "application/x-test");
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "TestDepay", "Codec/Depayloader/Network/RTP", "t", "x");
}

fn depayType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_rtp_base_depayload_get_type(), "TestRtpDepay", @sizeOf(c.GstRTPBaseDepayloadClass), depayClass, @sizeOf(c.GstRTPBaseDepayload), null, 0);
    return S.v;
}

fn chunk(n: usize, base: u8, pts: u64, off: u64) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, n, null);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
    for (0..n) |i| map.data[i] = base +% @as(u8, @truncate(i));
    c.gst_buffer_unmap(b, &map);
    b[0].pts = pts;
    b[0].offset = off;
    return b;
}

fn statsOf(e: anytype) void {
    var s: ?*c.GstStructure = null;
    c.g_object_get(e, "stats", &s, N);
    const t = c.gst_structure_to_string(s);
    out("  stats {s}", .{z(t)});
    c.g_free(t);
    c.gst_structure_free(s);
}

fn payloadTest() void {
    out("payload", .{});
    const pay: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(payType(), "ssrc", @as(c.guint, 0x1234), "timestamp-offset", @as(c.guint, 1000), "seqnum-offset", @as(c.gint, 10), "pt", @as(c.guint, 100), N)));
    const depay: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(depayType(), "source-info", @as(c.gboolean, 1), N)));
    var u: c.guint = 0;
    var i: c.gint = 0;
    var i64v: i64 = 0;
    c.g_object_get(pay, "mtu", &u, N);
    out("  mtu {d}", .{u});
    c.g_object_get(pay, "seqnum-offset", &i, "max-ptime", &i64v, N);
    out("  seqnum-offset {d} max-ptime {d}", .{ i, i64v });
    const e: ?*c.GstRTPHeaderExtension = @ptrCast(@alignCast(c.g_object_new(extType(), null)));
    _ = c.gst_object_ref_sink(e);
    c.gst_rtp_header_extension_set_id(e, 1);
    c.g_signal_emit_by_name(pay, "add-extension", e);
    c.gst_object_unref(e);
    const src = srcPad();
    const sink = sinkPad();
    _ = c.gst_pad_link(src, c.gst_element_get_static_pad(pay, "sink"));
    _ = c.gst_pad_link(c.gst_element_get_static_pad(pay, "src"), c.gst_element_get_static_pad(depay, "sink"));
    _ = c.gst_pad_link(c.gst_element_get_static_pad(depay, "src"), sink);
    const probe = struct {
        fn f(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
            const b: [*c]c.GstBuffer = @ptrCast(@alignCast(info[0].data));
            bufInfo("wire", b);
            rtpHeader("wire", b);
            return c.GST_PAD_PROBE_OK;
        }
    }.f;
    _ = c.gst_pad_add_probe(c.gst_element_get_static_pad(pay, "src"), c.GST_PAD_PROBE_TYPE_BUFFER, probe, null, null);
    _ = c.gst_element_set_state(depay, c.GST_STATE_PLAYING);
    _ = c.gst_element_set_state(pay, c.GST_STATE_PLAYING);
    startStream(src, "application/x-test");
    for (0..3) |k| out("  push {d}", .{c.gst_pad_push(src, chunk(5 + k, @intCast(k * 16), k * 20000000, NONE))});
    out("  push nopts {d}", .{c.gst_pad_push(src, chunk(2, 0xf0, NONE, NONE))});
    drain("out", false);
    var ex: c.GValue = std.mem.zeroes(c.GValue);
    c.g_object_get_property(@ptrCast(pay), "extensions", &ex);
    out("  pay extensions {d}", .{c.gst_value_array_get_size(&ex)});
    c.g_value_unset(&ex);
    c.g_object_get_property(@ptrCast(depay), "extensions", &ex);
    out("  depay extensions {d}", .{c.gst_value_array_get_size(&ex)});
    c.g_value_unset(&ex);
    c.g_object_get(pay, "seqnum", &u, N);
    out("  seqnum {d}", .{u});
    c.g_object_get(pay, "timestamp", &u, N);
    out("  timestamp {d}", .{u});
    statsOf(pay);
    statsOf(depay);
    c.g_signal_emit_by_name(pay, "clear-extensions");
    _ = c.gst_pad_push_event(src, c.gst_event_new_eos());
    _ = c.gst_element_set_state(pay, c.GST_STATE_NULL);
    _ = c.gst_element_set_state(depay, c.GST_STATE_NULL);
    _ = c.gst_pad_set_active(src, 0);
    _ = c.gst_pad_set_active(sink, 0);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    c.gst_object_unref(pay);
    c.gst_object_unref(depay);
}

fn rtpPacket(seq: u16, ts: u32, ssrc: u32, pts: u64) [*c]c.GstBuffer {
    const b = c.gst_rtp_buffer_new_allocate(3, 0, 0);
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    _ = c.gst_rtp_buffer_map(b, c.GST_MAP_WRITE, &rtp);
    c.gst_rtp_buffer_set_seq(&rtp, seq);
    c.gst_rtp_buffer_set_timestamp(&rtp, ts);
    c.gst_rtp_buffer_set_ssrc(&rtp, ssrc);
    c.gst_rtp_buffer_set_payload_type(&rtp, 96);
    const p: [*c]u8 = @ptrCast(c.gst_rtp_buffer_get_payload(&rtp));
    p[0] = @truncate(seq);
    p[1] = 0;
    p[2] = 0x99;
    c.gst_rtp_buffer_unmap(&rtp);
    b[0].pts = pts;
    return b;
}

fn depayloadTest() void {
    out("depayload", .{});
    const depay: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(depayType(), "max-reorder", @as(c.gint, 5), N)));
    const src = srcPad();
    const sink = sinkPad();
    _ = c.gst_pad_link(src, c.gst_element_get_static_pad(depay, "sink"));
    _ = c.gst_pad_link(c.gst_element_get_static_pad(depay, "src"), sink);
    _ = c.gst_element_set_state(depay, c.GST_STATE_PLAYING);
    out("  unnegotiated {d}", .{c.gst_pad_push(src, rtpPacket(1, 0, 1, 0))});
    startStream(src, "application/x-rtp, media=video, clock-rate=90000, encoding-name=X, npt-start=(guint64)1000, npt-stop=(guint64)5000000000, play-speed=2.0, clock-base=(uint)900");
    const seqs = [_]u16{ 5, 6, 8, 7, 9, 30, 31, 20, 32 };
    for (seqs, 0..) |s, k| out("  push {d} {d}", .{ s, c.gst_pad_push(src, rtpPacket(s, 900 + @as(u32, @intCast(k)) * 3000, 0x10, k * 33000000)) });
    out("  push ssrc {d}", .{c.gst_pad_push(src, rtpPacket(33, 0, 0x20, 400000000))});
    const lost = c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new("GstRTPPacketLost", "timestamp", c.G_TYPE_UINT64, @as(u64, 500000000), "duration", c.G_TYPE_UINT64, @as(u64, 20000000), N));
    out("  lost {d}", .{c.gst_pad_push_event(src, lost)});
    const fec = c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new("GstRTPPacketLost", "timestamp", c.G_TYPE_UINT64, @as(u64, 1), "duration", c.G_TYPE_UINT64, @as(u64, 2), "might-have-been-fec", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), N));
    out("  fec {d}", .{c.gst_pad_push_event(src, fec)});
    _ = c.gst_pad_push_event(src, c.gst_event_new_flush_start());
    _ = c.gst_pad_push_event(src, c.gst_event_new_flush_stop(1));
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.base = 1000;
    _ = c.gst_pad_push_event(src, c.gst_event_new_segment(&seg));
    out("  after flush {d}", .{c.gst_pad_push(src, rtpPacket(100, 50, 0x20, 600000000))});
    const list = c.gst_buffer_list_new();
    c.gst_buffer_list_insert(list, -1, rtpPacket(101, 60, 0x20, 610000000));
    c.gst_buffer_list_insert(list, -1, rtpPacket(102, 70, 0x20, 620000000));
    out("  list {d}", .{c.gst_pad_push_list(src, list)});
    var bad = [_]u8{ 1, 2, 3 };
    out("  invalid {d}", .{c.gst_pad_push(src, c.gst_buffer_new_memdup(&bad, 3))});
    drain("out", false);
    statsOf(depay);
    out("  aggregate {d}", .{c.gst_rtp_base_depayload_is_aggregate_hdrext_enabled(@ptrCast(@alignCast(depay)))});
    c.gst_rtp_base_depayload_set_aggregate_hdrext_enabled(@ptrCast(@alignCast(depay)), 1);
    c.gst_rtp_base_depayload_delayed(@ptrCast(@alignCast(depay)));
    c.gst_rtp_base_depayload_dropped(@ptrCast(@alignCast(depay)));
    c.gst_rtp_base_depayload_flush(@ptrCast(@alignCast(depay)), 1);
    out("  aggregate {d}", .{c.gst_rtp_base_depayload_is_aggregate_hdrext_enabled(@ptrCast(@alignCast(depay)))});
    _ = c.gst_element_set_state(depay, c.GST_STATE_NULL);
    _ = c.gst_pad_set_active(src, 0);
    _ = c.gst_pad_set_active(sink, 0);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    c.gst_object_unref(depay);
}

fn audioSetCaps(p: [*c]c.GstRTPBasePayload, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    c.gst_rtp_base_payload_set_options(p, "audio", 1, "L8", 8000);
    c.gst_rtp_base_audio_payload_set_sample_options(@ptrCast(@alignCast(p)), 1);
    return c.gst_rtp_base_payload_set_outcaps(p, null);
}

fn audioInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_rtp_base_audio_payload_set_sample_based(@ptrCast(@alignCast(instance)));
}

fn audioClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const pk: *c.GstRTPBasePayloadClass = @ptrCast(@alignCast(k));
    pk.set_caps = audioSetCaps;
    templ(k, "src", c.GST_PAD_SRC, "application/x-rtp");
    templ(k, "sink", c.GST_PAD_SINK, "audio/x-test");
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "TestAudioPay", "Codec/Payloader/Network/RTP", "t", "x");
}

fn audioType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_rtp_base_audio_payload_get_type(), "TestRtpAudioPay", @sizeOf(c.GstRTPBaseAudioPayloadClass), audioClass, @sizeOf(c.GstRTPBaseAudioPayload), audioInit, 0);
    return S.v;
}

fn audioTest(mtu: c.guint, min: i64, max: i64, mult: i64) void {
    out("audio mtu={d} min={d} max={d} mult={d}", .{ mtu, min, max, mult });
    const pay: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(audioType(), "ssrc", @as(c.guint, 0x77), "timestamp-offset", @as(c.guint, 0), "seqnum-offset", @as(c.gint, 0), "mtu", mtu, "min-ptime", min, "max-ptime", max, "ptime-multiple", mult, N)));
    const src = srcPad();
    const sink = sinkPad();
    _ = c.gst_pad_link(src, c.gst_element_get_static_pad(pay, "sink"));
    _ = c.gst_pad_link(c.gst_element_get_static_pad(pay, "src"), sink);
    _ = c.gst_element_set_state(pay, c.GST_STATE_PLAYING);
    startStream(src, "audio/x-test");
    out("  push {d}", .{c.gst_pad_push(src, chunk(100, 0, 0, NONE))});
    out("  push {d}", .{c.gst_pad_push(src, chunk(7, 100, 12500000, NONE))});
    out("  push {d}", .{c.gst_pad_push(src, chunk(300, 7, 13375000, NONE))});
    const d = chunk(40, 9, 100000000, NONE);
    d[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
    out("  push discont {d}", .{c.gst_pad_push(src, d)});
    var lb: c.gboolean = 1;
    c.g_object_set(pay, "buffer-list", @as(c.gboolean, 1), N);
    c.g_object_get(pay, "buffer-list", &lb, N);
    out("  buffer-list {d}", .{lb});
    const a = c.gst_rtp_base_audio_payload_get_adapter(@ptrCast(@alignCast(pay)));
    out("  adapter {d}", .{c.gst_adapter_available(a)});
    c.g_object_unref(a);
    _ = c.gst_pad_push_event(src, c.gst_event_new_eos());
    drain("pkt", true);
    out("  direct {d}", .{c.gst_rtp_base_audio_payload_push(@ptrCast(@alignCast(pay)), "abcd", 4, 5)});
    out("  flush {d}", .{c.gst_rtp_base_audio_payload_flush(@ptrCast(@alignCast(pay)), 0, NONE)});
    drain("pkt", true);
    _ = c.gst_element_set_state(pay, c.GST_STATE_NULL);
    _ = c.gst_pad_set_active(src, 0);
    _ = c.gst_pad_set_active(sink, 0);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    c.gst_object_unref(pay);
}

pub fn main() void {
    c.gst_init(null, null);
    rtpBuffers();
    rtcpTests();
    enums();
    metaTest();
    hdrextTest();
    payloadTest();
    depayloadTest();
    audioTest(1400, 0, -1, 0);
    audioTest(60, 0, -1, 0);
    audioTest(1400, 10000000, 20000000, 2000000);
}
