const std = @import("std");
const c = @import("../c.zig").c;
const defs = @import("defs.zig");
const that = defs.that;

comptime {
    @import("../abi.zig").check(@This());
}

const Trans = c.GstRTSPTransport;
const OK = c.GST_RTSP_OK;
const EINVAL = c.GST_RTSP_EINVAL;

const Map = struct {
    n: ?[:0]const u8,
    mode: c.GstRTSPTransMode,
    profile: c.GstRTSPProfile,
    lower: c.GstRTSPLowerTrans,
    media: ?[:0]const u8,
    managers: [2]?[:0]const u8,
};

const maps = [_]Map{
    .{ .n = "rtp", .mode = c.GST_RTSP_TRANS_RTP, .profile = c.GST_RTSP_PROFILE_AVP, .lower = c.GST_RTSP_LOWER_TRANS_UDP_MCAST, .media = "application/x-rtp", .managers = .{ "rtpbin", "rtpdec" } },
    .{ .n = "srtp", .mode = c.GST_RTSP_TRANS_RTP, .profile = c.GST_RTSP_PROFILE_SAVP, .lower = c.GST_RTSP_LOWER_TRANS_UDP_MCAST, .media = "application/x-srtp", .managers = .{ "rtpbin", "rtpdec" } },
    .{ .n = "rtpf", .mode = c.GST_RTSP_TRANS_RTP, .profile = c.GST_RTSP_PROFILE_AVPF, .lower = c.GST_RTSP_LOWER_TRANS_UDP_MCAST, .media = "application/x-rtp", .managers = .{ "rtpbin", "rtpdec" } },
    .{ .n = "srtpf", .mode = c.GST_RTSP_TRANS_RTP, .profile = c.GST_RTSP_PROFILE_SAVPF, .lower = c.GST_RTSP_LOWER_TRANS_UDP_MCAST, .media = "application/x-srtp", .managers = .{ "rtpbin", "rtpdec" } },
    .{ .n = "x-real-rdt", .mode = c.GST_RTSP_TRANS_RDT, .profile = c.GST_RTSP_PROFILE_AVP, .lower = c.GST_RTSP_LOWER_TRANS_UNKNOWN, .media = "application/x-rdt", .managers = .{ "rdtmanager", null } },
    .{ .n = "x-pn-tng", .mode = c.GST_RTSP_TRANS_RDT, .profile = c.GST_RTSP_PROFILE_AVP, .lower = c.GST_RTSP_LOWER_TRANS_UNKNOWN, .media = "application/x-rdt", .managers = .{ "rdtmanager", null } },
    .{ .n = null, .mode = c.GST_RTSP_TRANS_UNKNOWN, .profile = c.GST_RTSP_PROFILE_UNKNOWN, .lower = c.GST_RTSP_LOWER_TRANS_UNKNOWN, .media = null, .managers = .{ null, null } },
};

const profiles = [_]struct { n: ?[:0]const u8, p: c.GstRTSPProfile }{
    .{ .n = "avp", .p = c.GST_RTSP_PROFILE_AVP },
    .{ .n = "savp", .p = c.GST_RTSP_PROFILE_SAVP },
    .{ .n = "avpf", .p = c.GST_RTSP_PROFILE_AVPF },
    .{ .n = "savpf", .p = c.GST_RTSP_PROFILE_SAVPF },
    .{ .n = null, .p = c.GST_RTSP_PROFILE_UNKNOWN },
};

const lowers = [_]struct { n: ?[:0]const u8, l: c.GstRTSPLowerTrans }{
    .{ .n = "udp", .l = c.GST_RTSP_LOWER_TRANS_UDP },
    .{ .n = "mcast", .l = c.GST_RTSP_LOWER_TRANS_UDP_MCAST },
    .{ .n = "tcp", .l = c.GST_RTSP_LOWER_TRANS_TCP },
    .{ .n = null, .l = c.GST_RTSP_LOWER_TRANS_UNKNOWN },
};

fn cstr(s: ?[:0]const u8) [*c]const u8 {
    return if (s) |v| v.ptr else null;
}

pub export fn gst_rtsp_transport_new(out: [*c][*c]Trans) c.GstRTSPResult {
    if (!that(out != null, "gst_rtsp_transport_new", "transport != NULL")) return EINVAL;
    const t: [*c]Trans = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Trans))));
    out.* = t;
    return gst_rtsp_transport_init(t);
}

pub export fn gst_rtsp_transport_init(t: [*c]Trans) c.GstRTSPResult {
    if (!that(t != null, "gst_rtsp_transport_init", "transport != NULL")) return EINVAL;
    c.g_free(t[0].destination);
    c.g_free(t[0].source);
    t[0] = std.mem.zeroes(Trans);
    t[0].trans = c.GST_RTSP_TRANS_RTP;
    t[0].profile = c.GST_RTSP_PROFILE_AVP;
    t[0].lower_transport = c.GST_RTSP_LOWER_TRANS_UDP_MCAST;
    t[0].mode_play = 1;
    t[0].mode_record = 0;
    inline for (.{ "interleaved", "port", "client_port", "server_port" }) |n| {
        @field(t[0], n).min = -1;
        @field(t[0], n).max = -1;
    }
    return OK;
}

pub export fn gst_rtsp_transport_get_mime(mode: c.GstRTSPTransMode, mime: [*c][*c]const u8) c.GstRTSPResult {
    if (!that(mime != null, "gst_rtsp_transport_get_mime", "mime != NULL")) return EINVAL;
    mime.* = cstr(find(mode, c.GST_RTSP_PROFILE_AVP).media);
    return OK;
}

fn find(mode: c.GstRTSPTransMode, profile: c.GstRTSPProfile) Map {
    for (maps) |m| {
        if (m.n == null or (m.mode == mode and m.profile == profile)) return m;
    }
    unreachable;
}

pub export fn gst_rtsp_transport_get_media_type(t: [*c]Trans, media: [*c][*c]const u8) c.GstRTSPResult {
    const f = "gst_rtsp_transport_get_media_type";
    if (!that(t != null, f, "transport != NULL")) return EINVAL;
    if (!that(media != null, f, "media_type != NULL")) return EINVAL;
    media.* = cstr(find(t[0].trans, t[0].profile).media);
    return OK;
}

pub export fn gst_rtsp_transport_get_manager(mode: c.GstRTSPTransMode, manager: [*c][*c]const u8, option: c.guint) c.GstRTSPResult {
    if (!that(manager != null, "gst_rtsp_transport_get_manager", "manager != NULL")) return EINVAL;
    const m = for (maps) |m| {
        if (m.n == null or m.mode == mode) break m;
    } else unreachable;
    manager.* = if (option < 2) cstr(m.managers[option]) else null;
    return OK;
}

fn checkRange(s: [*c]const u8, end: *[*c]u8, v: *c.gint) bool {
    const n = c.strtol(s, end, 10);
    if (n < std.math.minInt(c.gint) or n > std.math.maxInt(c.gint)) return false;
    v.* = @intCast(n);
    return true;
}

fn tail(p: [*c]const u8) bool {
    return p[0] == 0 or p[0] == ';';
}

fn parseRange(s: [*c]const u8, r: *c.GstRTSPRange) bool {
    if (!rangeOk(s, r)) {
        r.min = -1;
        r.max = -1;
        return false;
    }
    return true;
}

fn rangeOk(s: [*c]const u8, r: *c.GstRTSPRange) bool {
    if (c.g_ascii_isspace(s[0]) or s[0] == '+' or s[0] == '-') return false;
    var end: [*c]u8 = null;
    const minus: [*c]const u8 = c.strstr(s, "-");
    if (minus != null) {
        if (c.g_ascii_isspace(minus[1]) or minus[1] == '+' or minus[1] == '-') return false;
        if (!checkRange(s, &end, &r.min) or s == end or end != minus) return false;
        return checkRange(minus + 1, &end, &r.max) and tail(end);
    }
    if (!checkRange(s, &end, &r.min) or s == end or !tail(end)) return false;
    r.max = -1;
    return true;
}

fn portOk(r: c.GstRTSPRange) bool {
    return r.min >= 0 and r.min < 65536 and r.max < 65536;
}

fn eql(a: [*c]const u8, b: [:0]const u8) bool {
    return c.strcmp(a, b.ptr) == 0;
}

fn has(a: [*c]const u8, b: [*:0]const u8) bool {
    return c.g_str_has_prefix(a, b) != 0;
}

const DELIVERY = 1 << 0;
const DESTINATION = 1 << 1;
const SOURCE = 1 << 2;
const INTERLEAVED = 1 << 3;
const APPEND = 1 << 4;
const TTL = 1 << 5;
const LAYERS = 1 << 6;
const PORT = 1 << 7;
const CLIENT_PORT = 1 << 8;
const SERVER_PORT = 1 << 9;
const SSRC = 1 << 10;
const MODE = 1 << 11;

fn number(s: [*c]const u8, base: c.guint, max: u64) ?u64 {
    var v: u64 = 0;
    if (c.g_ascii_string_to_unsigned(s, base, 0, max, &v, null) == 0) return null;
    return v;
}

fn parseParams(split: [*c][*c]u8, tp: [*c]Trans) bool {
    const t: [*]Trans = @ptrCast(tp);
    var seen: c.guint = 0;
    var i: usize = 1;
    while (split[i] != null) : (i += 1) {
        const p = split[i];
        const bit: c.guint = if (eql(p, "multicast") or eql(p, "unicast")) DELIVERY else if (has(p, "destination=")) DESTINATION else if (has(p, "source=")) SOURCE else if (has(p, "layers=")) LAYERS else if (has(p, "mode=")) MODE else if (eql(p, "append")) APPEND else if (has(p, "interleaved=")) INTERLEAVED else if (has(p, "ttl=")) TTL else if (has(p, "port=")) PORT else if (has(p, "client_port=")) CLIENT_PORT else if (has(p, "server_port=")) SERVER_PORT else if (has(p, "ssrc=")) SSRC else 0;
        if (bit == 0) {
            if (p[0] != 0) c.g_log(defs.DOMAIN, c.G_LOG_LEVEL_WARNING, "unknown transport field \"%s\"", p);
            continue;
        }
        if (seen & bit != 0) return false;
        seen |= bit;
        switch (bit) {
            DELIVERY => {
                if (eql(p, "multicast")) {
                    if (t[0].lower_transport == c.GST_RTSP_LOWER_TRANS_TCP) return false;
                    t[0].lower_transport = c.GST_RTSP_LOWER_TRANS_UDP_MCAST;
                } else if (t[0].lower_transport == c.GST_RTSP_LOWER_TRANS_UDP_MCAST) t[0].lower_transport = c.GST_RTSP_LOWER_TRANS_UDP;
            },
            DESTINATION => t[0].destination = c.g_strdup(p + 12),
            SOURCE => t[0].source = c.g_strdup(p + 7),
            LAYERS => t[0].layers = @intCast(number(p + 7, 10, std.math.maxInt(c.guint)) orelse return false),
            MODE => {
                t[0].mode_play = @intFromBool(c.strstr(p + 5, "play") != null);
                t[0].mode_record = @intFromBool(c.strstr(p + 5, "record") != null);
                if (t[0].mode_play == 0 and t[0].mode_record == 0) return false;
            },
            APPEND => t[0].append = 1,
            INTERLEAVED => {
                _ = parseRange(p + 12, &t[0].interleaved);
                const r = t[0].interleaved;
                if (!(r.min >= 0 and r.min < 256 and r.max < 256)) return false;
            },
            TTL => t[0].ttl = @intCast(number(p + 4, 10, 255) orelse return false),
            PORT => if (parseRange(p + 5, &t[0].port) and !portOk(t[0].port)) return false,
            CLIENT_PORT => if (parseRange(p + 12, &t[0].client_port) and !portOk(t[0].client_port)) return false,
            SERVER_PORT => if (parseRange(p + 12, &t[0].server_port) and !portOk(t[0].server_port)) return false,
            SSRC => t[0].ssrc = @intCast(number(p + 5, 16, std.math.maxInt(c.guint)) orelse return false),
            else => unreachable,
        }
    }
    return true;
}

pub export fn gst_rtsp_transport_parse(str: [*c]const u8, t: [*c]Trans) c.GstRTSPResult {
    const f = "gst_rtsp_transport_parse";
    if (!that(t != null, f, "transport != NULL")) return EINVAL;
    if (!that(str != null, f, "str != NULL")) return EINVAL;
    _ = gst_rtsp_transport_init(t);
    const down = c.g_ascii_strdown(str, -1);
    const split = c.g_strsplit(down, ";", 0);
    c.g_free(down);
    defer c.g_strfreev(split);
    if (split[0] == null) return EINVAL;
    const parts = c.g_strsplit(split[0], "/", 0);
    if (parts[0] == null or parts[1] == null) {
        c.g_strfreev(parts);
        return EINVAL;
    }
    t[0].trans = for (maps) |m| {
        if (m.n == null or eql(parts[0], m.n.?)) break m.mode;
    } else unreachable;
    var count: usize = 1;
    if (t[0].trans != c.GST_RTSP_TRANS_RDT) {
        t[0].profile = for (profiles) |p| {
            if (p.n == null or eql(parts[1], p.n.?)) break p.p;
        } else unreachable;
        count = 2;
    } else t[0].profile = c.GST_RTSP_PROFILE_AVP;
    if (parts[count] != null) {
        t[0].lower_transport = for (lowers) |l| {
            if (l.n == null or eql(parts[count], l.n.?)) break l.l;
        } else unreachable;
    } else t[0].lower_transport = find(t[0].trans, t[0].profile).lower;
    c.g_strfreev(parts);
    if (t[0].trans == c.GST_RTSP_TRANS_UNKNOWN or t[0].profile == c.GST_RTSP_PROFILE_UNKNOWN or t[0].lower_transport == c.GST_RTSP_LOWER_TRANS_UNKNOWN) return c.GST_RTSP_ERROR;
    return if (parseParams(split, t)) OK else EINVAL;
}

fn rangeText(r: c.GstRTSPRange) [*c]u8 {
    if (r.min < 0) return null;
    if (r.max < 0) return c.g_strdup_printf("%d", r.min);
    return c.g_strdup_printf("%d-%d", r.min, r.max);
}

fn modeName(t: [*c]Trans) [*c]const u8 {
    for (maps) |m| {
        if (m.n == null) return null;
        if (m.mode == t[0].trans) return m.n.?.ptr;
    }
    return null;
}

fn profileName(t: [*c]Trans) [*c]const u8 {
    for (profiles) |p| {
        if (p.n == null) return null;
        if (p.p == t[0].profile) return p.n.?.ptr;
    }
    return null;
}

fn lowerName(t: [*c]Trans) [*c]const u8 {
    if (t[0].lower_transport == c.GST_RTSP_LOWER_TRANS_UDP_MCAST) return "udp";
    for (lowers) |l| {
        if (l.n == null) return null;
        if (l.l == t[0].lower_transport) return l.n.?.ptr;
    }
    return null;
}

fn portText(r: c.GstRTSPRange) [*c]u8 {
    return if (r.max > 0) rangeText(r) else c.g_strdup_printf("%d", r.min);
}

fn render(t: [*c]Trans, s: [*c]c.GString) bool {
    const add = struct {
        fn f(g: [*c]c.GString, v: [*c]const u8) void {
            _ = c.g_string_append(g, v);
        }
    }.f;
    const own = struct {
        fn f(g: [*c]c.GString, v: [*c]u8) void {
            if (v != null) _ = c.g_string_append(g, v);
            c.g_free(v);
        }
    }.f;
    const mode = modeName(t);
    if (mode == null) return false;
    own(s, c.g_ascii_strup(mode, -1));
    add(s, "/");
    const prof = profileName(t);
    if (prof == null) return false;
    own(s, c.g_ascii_strup(prof, -1));
    const p = t[0].profile;
    const rtp_profile = p == c.GST_RTSP_PROFILE_AVP or p == c.GST_RTSP_PROFILE_SAVP or p == c.GST_RTSP_PROFILE_AVPF or p == c.GST_RTSP_PROFILE_SAVPF;
    const lt = t[0].lower_transport;
    if (t[0].trans != c.GST_RTSP_TRANS_RTP or !rtp_profile or lt == c.GST_RTSP_LOWER_TRANS_TCP) {
        add(s, "/");
        const ln = lowerName(t);
        if (ln == null) return false;
        own(s, c.g_ascii_strup(ln, -1));
    }
    add(s, if (lt == c.GST_RTSP_LOWER_TRANS_UDP_MCAST) ";multicast" else ";unicast");
    if (t[0].destination != null) {
        add(s, ";destination=");
        add(s, t[0].destination);
    }
    if (t[0].source != null) {
        add(s, ";source=");
        add(s, t[0].source);
    }
    const il = t[0].interleaved;
    if (lt == c.GST_RTSP_LOWER_TRANS_TCP and il.min >= 0) {
        if (!(il.min < 256 and il.max < 256)) return false;
        add(s, ";interleaved=");
        own(s, rangeText(il));
    }
    if (t[0].mode_record != 0 and t[0].append != 0) add(s, ";append");
    if (lt == c.GST_RTSP_LOWER_TRANS_UDP_MCAST and t[0].ttl != 0) {
        if (t[0].ttl >= 256) return false;
        add(s, ";ttl=");
        own(s, c.g_strdup_printf("%u", t[0].ttl));
    }
    if (t[0].layers != 0) {
        add(s, ";layers=");
        own(s, c.g_strdup_printf("%u", t[0].layers));
    }
    if (lt != c.GST_RTSP_LOWER_TRANS_TCP and t[0].trans == c.GST_RTSP_TRANS_RTP) {
        if (t[0].port.min >= 0) {
            if (!(t[0].port.min < 65536 and t[0].port.max < 65536)) return false;
            add(s, ";port=");
            own(s, rangeText(t[0].port));
        }
        if (t[0].client_port.min >= 0) {
            if (!(t[0].client_port.min < 65536 and t[0].client_port.max < 65536)) return false;
            add(s, ";client_port=");
            own(s, portText(t[0].client_port));
        }
        if (t[0].server_port.min >= 0) {
            if (!(t[0].server_port.min < 65536 and t[0].server_port.max < 65536)) return false;
            add(s, ";server_port=");
            own(s, portText(t[0].server_port));
        }
    }
    if (lt != c.GST_RTSP_LOWER_TRANS_UDP_MCAST and t[0].ssrc != 0) {
        add(s, ";ssrc=");
        own(s, c.g_strdup_printf("%08X", t[0].ssrc));
    }
    if (t[0].mode_play != 0 and t[0].mode_record != 0) {
        add(s, ";mode=\"PLAY,RECORD\"");
    } else if (t[0].mode_record != 0) {
        add(s, ";mode=\"RECORD\"");
    } else if (t[0].mode_play != 0) add(s, ";mode=\"PLAY\"");
    return true;
}

pub export fn gst_rtsp_transport_as_text(t: [*c]Trans) [*c]u8 {
    if (!that(t != null, "gst_rtsp_transport_as_text", "transport != NULL")) return null;
    const s = c.g_string_new("");
    if (!render(t, s)) {
        _ = c.g_string_free(s, 1);
        return null;
    }
    return c.g_string_free(s, 0);
}

pub export fn gst_rtsp_transport_free(t: [*c]Trans) c.GstRTSPResult {
    if (!that(t != null, "gst_rtsp_transport_free", "transport != NULL")) return EINVAL;
    _ = gst_rtsp_transport_init(t);
    c.g_free(t);
    return OK;
}
