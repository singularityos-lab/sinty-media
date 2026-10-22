const std = @import("std");
const c = @import("../c.zig").c;
const m = @import("message.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const that = m.that;
const OK = c.GST_SDP_OK;
const EINVAL = c.GST_SDP_EINVAL;
const N: ?*anyopaque = null;
const Media = c.GstSDPMedia;
const Attr = c.GstSDPAttribute;
const Result = c.GstSDPResult;
const Str = [*c]u8;
const CStr = [*c]const u8;

fn at(comptime T: type, a: [*c]c.GArray, i: c.guint) *T {
    return @ptrCast(@alignCast(a[0].data + @as(usize, i) * @sizeOf(T)));
}

fn isSpace(ch: u8) bool {
    return c.g_ascii_isspace(@as(c.gchar, @bitCast(ch)));
}

fn skipSpaces(p: *[*c]u8) void {
    while (p.*[0] != 0 and isSpace(p.*[0])) p.* += 1;
}

fn parseInt(p: *[*c]u8, del: CStr) c.gint {
    const t = p.*;
    p.* = c.strstr(p.*, del);
    if (p.* == null) return -1;
    const prev = p.*[0];
    p.*[0] = 0;
    const r = c.atoi(t);
    p.*[0] = prev;
    p.* += 1;
    return r;
}

fn parseString(p: *[*c]u8, del: CStr) Str {
    const t = p.*;
    const f = c.strstr(p.*, del);
    if (f == null) {
        p.* = t;
        return null;
    }
    f[0] = 0;
    p.* = f + 1;
    return t;
}

fn attributeForPt(media: [*c]const Media, name: CStr, pt: c.gint) CStr {
    var i: c.guint = 0;
    while (true) : (i += 1) {
        const a = m.gst_sdp_media_get_attribute_val_n(media, name, i);
        if (a == null) return null;
        var val: c.gint = 0;
        if (c.sscanf(a, "%d ", &val) != 1) continue;
        if (val == pt) return a;
    }
}

fn parseRtpmap(rtpmap: CStr, payload: *c.gint, name: *Str, rate: *c.gint, params: *Str) bool {
    const orig = c.g_strdup(rtpmap);
    defer c.g_free(orig);
    var p: [*c]u8 = orig;
    payload.* = parseInt(&p, " ");
    if (payload.* == -1) return false;
    skipSpaces(&p);
    if (p[0] == 0) return false;
    const n = parseString(&p, "/");
    if (n == null) {
        name.* = c.g_strdup(p);
        rate.* = -1;
        params.* = null;
        return true;
    }
    name.* = c.g_strdup(n);
    const t = p;
    p = c.strstr(p, "/");
    if (p == null) {
        rate.* = c.atoi(t);
        params.* = null;
        return true;
    }
    p += 1;
    rate.* = c.atoi(t);
    params.* = if (p[0] == 0) null else c.g_strdup(p);
    return true;
}

fn rtcpFb(media: [*c]const Media, pt: c.gint, caps: [*c]c.GstCaps) void {
    const s = c.gst_caps_get_structure(caps, 0);
    var i: c.guint = 0;
    while (true) : (i += 1) {
        const fb = m.gst_sdp_media_get_attribute_val_n(media, "rtcp-fb", i);
        if (fb == null) break;
        const to_free = c.g_strdup(fb);
        defer c.g_free(to_free);
        var p: [*c]u8 = to_free;
        var all = false;
        var payload: c.gint = 0;
        if (p[0] == '*') {
            p += 1;
            all = true;
        } else payload = parseInt(&p, " ");
        if (all or (payload != -1 and payload == pt)) {
            skipSpaces(&p);
            const key = c.g_strdup_printf("rtcp-fb-%s", p);
            var t: [*c]u8 = key;
            while (true) {
                t = c.strchr(t, ' ');
                if (t == null) break;
                t[0] = '-';
                t += 1;
            }
            c.gst_structure_set(s, key, c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), N);
            c.g_free(key);
        }
    }
}

fn adjustH264(caps: [*c]c.GstCaps) void {
    const s = c.gst_caps_get_structure(caps, 0);
    if (c.g_strcmp0(c.gst_structure_get_string(s, "encoding-name"), "H264") != 0 or c.g_strcmp0(c.gst_structure_get_string(s, "level-asymmetry-allowed"), "1") != 0) return;
    const pli = c.gst_structure_get_string(s, "profile-level-id");
    if (pli == null) return;
    const v = c.strtol(pli, null, 16);
    const sps = [2]u8{ @truncate(@as(c_ulong, @bitCast(v >> 16))), @truncate(@as(c_ulong, @bitCast(v >> 8))) };
    c.gst_structure_set(s, "profile", c.G_TYPE_STRING, c.gst_codec_utils_h264_get_profile(&sps, 2), N);
    c.gst_structure_remove_fields(s, "level-asymmetry-allowed", N);
}

fn dynamic(pt: c.gint) bool {
    return pt >= 96 and pt <= 127;
}

pub export fn gst_sdp_media_get_caps_from_media(media: [*c]const Media, pt: c.gint) [*c]c.GstCaps {
    if (!that(media != null, "gst_sdp_media_get_caps_from_media", "media != NULL")) return null;
    var name: Str = null;
    var rate: c.gint = -1;
    var params: Str = null;
    var payload: c.gint = 0;
    var fmtp: Str = null;
    var framesize: Str = null;
    defer {
        c.g_free(framesize);
        c.g_free(fmtp);
        c.g_free(name);
        c.g_free(params);
    }
    var rtpmap = attributeForPt(media, "rtpmap", pt);
    if (rtpmap != null and !parseRtpmap(rtpmap, &payload, &name, &rate, &params)) rtpmap = null;
    if (rtpmap == null and pt >= 96) return null;
    if (rate <= 0) {
        var info: [*c]const c.GstRTPPayloadInfo = null;
        if (dynamic(pt)) {
            const tmp = c.g_ascii_strdown(media[0].media, -1);
            info = c.gst_rtp_payload_info_for_name(tmp, name);
            c.g_free(tmp);
        } else info = c.gst_rtp_payload_info_for_pt(@intCast(pt & 0xff));
        if (info != null) {
            rate = @bitCast(info[0].clock_rate);
            if (rate == 0) rate = -1;
        }
        if (rate == -1) return null;
    }
    var tmp = c.g_ascii_strdown(media[0].media, -1);
    const caps = c.gst_caps_new_simple("application/x-unknown", "media", c.G_TYPE_STRING, tmp, "payload", c.G_TYPE_INT, pt, N);
    c.g_free(tmp);
    const s = c.gst_caps_get_structure(caps, 0);
    c.gst_structure_set(s, "clock-rate", c.G_TYPE_INT, rate, N);
    if (name != null) {
        tmp = c.g_ascii_strup(name, -1);
        c.gst_structure_set(s, "encoding-name", c.G_TYPE_STRING, tmp, N);
        c.g_free(tmp);
    }
    if (params != null) {
        tmp = c.g_ascii_strdown(params, -1);
        c.gst_structure_set(s, "encoding-params", c.G_TYPE_STRING, tmp, N);
        c.g_free(tmp);
    }
    fmtp = c.g_strdup(attributeForPt(media, "fmtp", pt));
    if (fmtp != null) {
        var p: [*c]u8 = fmtp;
        const fp = parseInt(&p, " ");
        if (fp != -1 and fp == pt) {
            const pairs = c.g_strsplit(p, ";", 0);
            var i: usize = 0;
            while (pairs[i] != null) : (i += 1) {
                const valpos = c.strstr(pairs[i], "=");
                var val: CStr = "1";
                if (valpos != null) {
                    valpos[0] = 0;
                    val = c.g_strstrip(valpos + 1);
                }
                var key: CStr = c.g_strstrip(pairs[i]);
                for ([_]CStr{ "media", "payload", "clock-rate", "encoding-name", "encoding-params" }) |r| {
                    if (c.g_ascii_strcasecmp(r, key) == 0) {
                        key = "";
                        break;
                    }
                }
                if (c.strlen(key) > 0) {
                    tmp = c.g_ascii_strdown(key, -1);
                    c.gst_structure_set(s, tmp, c.G_TYPE_STRING, val, N);
                    c.g_free(tmp);
                }
            }
            c.g_strfreev(pairs);
        }
    }
    framesize = c.g_strdup(m.gst_sdp_media_get_attribute_val(media, "framesize"));
    if (framesize != null) {
        var p: [*c]u8 = framesize;
        payload = parseInt(&p, " ");
        if (payload != -1 and payload == pt) c.gst_structure_set(s, "a-framesize", c.G_TYPE_STRING, p, N);
    }
    adjustH264(caps);
    rtcpFb(media, pt, caps);
    return caps;
}

fn hasExtmap(media: [*c]Media, id: c.guint) bool {
    var sp: [5]u8 = undefined;
    var sl: [5]u8 = undefined;
    _ = c.g_snprintf(&sp, 5, "%u ", id);
    _ = c.g_snprintf(&sl, 5, "%u/", id);
    var i: c.guint = 0;
    while (true) : (i += 1) {
        const v = m.gst_sdp_media_get_attribute_val_n(media, "extmap", i);
        if (v == null) return false;
        if (c.g_str_has_prefix(v, &sp) != 0 or c.g_str_has_prefix(v, &sl) != 0) return true;
    }
}

fn h264Profile(profile: CStr, idc: *u8, flags: *u8) bool {
    if (!that(profile != null, "h264_get_profile_idc", "profile")) return false;
    const CSF0: u8 = 0x80;
    const CSF1: u8 = 0x40;
    const CSF3: u8 = 0x10;
    const CSF4: u8 = 0x08;
    const CSF5: u8 = 0x04;
    flags.* = 0;
    const t = [_]struct { n: [*:0]const u8, i: u8, f: u8 }{
        .{ .n = "constrained-baseline", .i = 66, .f = CSF0 | CSF1 },
        .{ .n = "baseline", .i = 66, .f = CSF0 },
        .{ .n = "main", .i = 77, .f = CSF1 },
        .{ .n = "extended", .i = 88, .f = CSF3 },
        .{ .n = "constrained-high", .i = 100, .f = CSF4 | CSF5 },
        .{ .n = "progressive-high", .i = 100, .f = CSF4 },
        .{ .n = "high-10", .i = 110, .f = 0 },
        .{ .n = "high-10-intra", .i = 110, .f = CSF3 },
        .{ .n = "progressive-high-10", .i = 110, .f = CSF4 },
        .{ .n = "high-4:2:2", .i = 122, .f = 0 },
        .{ .n = "high-4:2:2-intra", .i = 122, .f = CSF3 },
        .{ .n = "high-4:4:4", .i = 244, .f = 0 },
        .{ .n = "high-4:4:4-intra", .i = 244, .f = CSF3 },
        .{ .n = "cavlc-4:4:4-intra", .i = 44, .f = 0 },
        .{ .n = "multiview-high", .i = 118, .f = 0 },
        .{ .n = "stereo-high", .i = 128, .f = 0 },
        .{ .n = "scalable-baseline", .i = 83, .f = 0 },
        .{ .n = "scalable-constrained-baseline", .i = 83, .f = CSF5 },
        .{ .n = "scalable-high", .i = 86, .f = 0 },
        .{ .n = "scalable-constrained-high", .i = 86, .f = CSF5 },
        .{ .n = "scalable-high-intra", .i = 86, .f = CSF3 },
    };
    for (t) |e| {
        if (c.strcmp(profile, e.n) == 0) {
            idc.* = e.i;
            flags.* = e.f;
            return true;
        }
    }
    return false;
}

fn arrayString(arr: [*c]const c.GValue, i: c.guint) CStr {
    return c.g_value_get_string(c.gst_value_array_get_value(arr, i));
}

fn addFormat(s: ?*const c.GstStructure, media: [*c]Media) Result {
    if (!that(media != null, "_add_media_format_from_structure", "media != NULL")) return EINVAL;
    if (!that(s != null, "_add_media_format_from_structure", "s != NULL")) return EINVAL;
    var pt: c.gint = 0;
    if (c.gst_structure_get_int(s, "payload", &pt) == 0) return EINVAL;
    var tmp = c.g_strdup_printf("%d", pt);
    _ = m.gst_sdp_media_add_format(media, tmp);
    c.g_free(tmp);
    var rate: c.gint = 0;
    if (c.gst_structure_get_int(s, "clock-rate", &rate) == 0) return EINVAL;
    const enc = c.gst_structure_get_string(s, "encoding-name");
    const params = c.gst_structure_get_string(s, "encoding-params");
    if (enc != null) {
        tmp = if (params != null) c.g_strdup_printf("%d %s/%d/%s", pt, enc, rate, params) else c.g_strdup_printf("%d %s/%d", pt, enc, rate);
        _ = m.gst_sdp_media_add_attribute(media, "rtpmap", tmp);
        c.g_free(tmp);
    }
    for ([_]struct { k: [*:0]const u8, f: [*:0]const u8 }{ .{ .k = "rtcp-fb-nack", .f = "%d nack" }, .{ .k = "rtcp-fb-nack-pli", .f = "%d nack pli" }, .{ .k = "rtcp-fb-ccm-fir", .f = "%d ccm fir" }, .{ .k = "rtcp-fb-transport-cc", .f = "%d transport-cc" } }) |e| {
        var b: c.gboolean = 0;
        if (c.gst_structure_get_boolean(s, e.k, &b) != 0 and b != 0) {
            tmp = c.g_strdup_printf(e.f, pt);
            _ = m.gst_sdp_media_add_attribute(media, "rtcp-fb", tmp);
            c.g_free(tmp);
        }
    }
    const fmtp = c.g_string_new("");
    c.g_string_append_printf(fmtp, "%d ", pt);
    var first = true;
    const n = c.gst_structure_n_fields(s);
    var j: c.guint = 0;
    while (j < n) : (j += 1) {
        const fname = c.gst_structure_nth_field_name(s, j);
        var skip = false;
        for ([_][*:0]const u8{ "media", "payload", "clock-rate", "encoding-name", "encoding-params", "ssrc", "timestamp-offset", "seqnum-offset" }) |k| {
            if (c.strcmp(fname, k) == 0) skip = true;
        }
        for ([_][*:0]const u8{ "srtp-", "srtcp-", "x-gst-rtsp-server-rtx-time", "rtcp-fb-", "ssrc-" }) |k| {
            if (c.g_str_has_prefix(fname, k) != 0) skip = true;
        }
        if (skip) continue;
        if (c.strcmp(fname, "a-framesize") == 0) {
            const fv = c.gst_structure_get_string(s, fname);
            if (fv != null) {
                tmp = c.g_strdup_printf("%d %s", pt, fv);
                _ = m.gst_sdp_media_add_attribute(media, fname + 2, tmp);
                c.g_free(tmp);
            }
            continue;
        }
        if (c.g_str_has_prefix(fname, "a-") != 0) {
            const fv = c.gst_structure_get_string(s, fname);
            if (fv != null) _ = m.gst_sdp_media_add_attribute(media, fname + 2, fv);
            continue;
        }
        if (c.g_str_has_prefix(fname, "x-") != 0) {
            const fv = c.gst_structure_get_string(s, fname);
            if (fv != null) _ = m.gst_sdp_media_add_attribute(media, fname, fv);
            continue;
        }
        if (c.g_str_has_prefix(fname, "extmap-") != 0) {
            var end: [*c]u8 = null;
            const id64 = c.strtoull(fname + 7, &end, 10);
            const id: c.guint = @truncate(id64);
            if (end[0] != 0 or id == 0 or id == 15 or id > 9999) continue;
            if (hasExtmap(media, id)) continue;
            const fv = c.gst_structure_get_string(s, fname);
            if (fv != null) {
                tmp = c.g_strdup_printf("%u %s", id, fv);
                _ = m.gst_sdp_media_add_attribute(media, "extmap", tmp);
                c.g_free(tmp);
            } else {
                const arr = c.gst_structure_get_value(s, fname);
                if (arr != null and c.g_type_check_value_holds(@constCast(arr), c.gst_value_array_get_type()) != 0 and c.gst_value_array_get_size(arr) == 3) {
                    const dir = arrayString(arr, 0);
                    const ename = arrayString(arr, 1);
                    const eattrs = arrayString(arr, 2);
                    if (ename == null or ename[0] == 0) continue;
                    const hasDir = dir != null and dir[0] != 0;
                    const hasAttrs = eattrs != null and eattrs[0] != 0;
                    tmp = if (hasDir and hasAttrs) c.g_strdup_printf("%u/%s %s %s", id, dir, ename, eattrs) else if (hasDir) c.g_strdup_printf("%u/%s %s", id, dir, ename) else if (hasAttrs) c.g_strdup_printf("%u %s %s", id, ename, eattrs) else c.g_strdup_printf("%u %s", id, ename);
                    _ = m.gst_sdp_media_add_attribute(media, "extmap", tmp);
                    c.g_free(tmp);
                }
            }
            continue;
        }
        if (c.g_str_has_prefix(fname, "rid-") != 0) {
            const rid = fname + 4;
            if (rid[0] == 0) continue;
            const fv = c.gst_structure_get_string(s, fname);
            if (fv != null) {
                tmp = c.g_strdup_printf("%s %s", rid, fv);
                _ = m.gst_sdp_media_add_attribute(media, "rid", tmp);
                c.g_free(tmp);
            } else {
                const arr = c.gst_structure_get_value(s, fname);
                if (arr != null and c.g_type_check_value_holds(@constCast(arr), c.gst_value_array_get_type()) != 0 and c.gst_value_array_get_size(arr) > 1) {
                    const str = c.g_string_new(null);
                    c.g_string_append_printf(str, "%s ", rid);
                    const an = c.gst_value_array_get_size(arr);
                    var i: c.guint = 0;
                    while (i < an) : (i += 1) {
                        const v = arrayString(arr, i);
                        if (i == 0) {
                            c.g_string_append_printf(str, "%s", v);
                        } else {
                            _ = c.g_string_append_c(str, if (i == 1) ' ' else ';');
                            c.g_string_append_printf(str, "%s", v);
                        }
                    }
                    _ = m.gst_sdp_media_add_attribute(media, "rid", str[0].str);
                    _ = c.g_string_free(str, 1);
                }
            }
            continue;
        }
        const fv = c.gst_structure_get_string(s, fname);
        if (fv != null) {
            if (c.g_strcmp0(c.gst_structure_get_string(s, "encoding-name"), "H264") == 0 and c.g_strcmp0(fname, "profile") == 0) {
                c.g_string_append_printf(fmtp, "%slevel-asymmetry-allowed=1", @as(CStr, if (first) "" else ";"));
                if (c.gst_structure_has_field(s, "profile-level-id") == 0) {
                    var idc: u8 = 0;
                    var flags: u8 = 0;
                    if (h264Profile(fv, &idc, &flags)) c.g_string_append_printf(fmtp, ";profile-level-id=%02x%02x1f", @as(c_uint, idc), @as(c_uint, flags));
                }
            } else c.g_string_append_printf(fmtp, "%s%s=%s", @as(CStr, if (first) "" else ";"), fname, fv);
            first = false;
        }
    }
    if (!first) {
        tmp = c.g_string_free(fmtp, 0);
        _ = m.gst_sdp_media_add_attribute(media, "fmtp", tmp);
        c.g_free(tmp);
    } else _ = c.g_string_free(fmtp, 1);
    return OK;
}

fn isCaps(caps: anytype) bool {
    return caps != null and @as(*const c.GstMiniObject, @ptrCast(@alignCast(caps))).type == c.gst_caps_get_type();
}

pub export fn gst_sdp_media_set_media_from_caps(caps: [*c]const c.GstCaps, media: [*c]Media) Result {
    if (!that(media != null, "gst_sdp_media_set_media_from_caps", "media != NULL")) return EINVAL;
    if (!that(isCaps(caps), "gst_sdp_media_set_media_from_caps", "caps != NULL && GST_IS_CAPS (caps)")) return EINVAL;
    return gst_sdp_media_add_media_from_structure(c.gst_caps_get_structure(caps, 0), media);
}

pub export fn gst_sdp_media_add_media_from_structure(s: ?*const c.GstStructure, media: [*c]Media) Result {
    if (!that(media != null, "gst_sdp_media_add_media_from_structure", "media != NULL")) return EINVAL;
    if (!that(s != null and c.gst_structure_get_type() == @as(*const c.GType, @ptrCast(@alignCast(s))).*, "gst_sdp_media_add_media_from_structure", "structure != NULL && GST_IS_STRUCTURE (structure)")) return EINVAL;
    const ms = c.gst_structure_get_string(s, "media");
    if (ms == null) return EINVAL;
    _ = m.gst_sdp_media_set_media(media, ms);
    return addFormat(s, media);
}

pub export fn gst_sdp_make_keymgmt(uri: CStr, base64: CStr) Str {
    if (!that(uri != null, "gst_sdp_make_keymgmt", "uri != NULL")) return null;
    if (!that(base64 != null, "gst_sdp_make_keymgmt", "base64 != NULL")) return null;
    return c.g_strdup_printf("prot=mikey;uri=\"%s\";data=\"%s\"", uri, base64);
}

fn parseKeymgmt(keymgmt: CStr, out: *[*c]c.GstMIKEYMessage) bool {
    const orig = c.g_strdup(keymgmt);
    var p: [*c]u8 = orig;
    skipSpaces(&p);
    if (p[0] == 0) {
        c.g_free(orig);
        return false;
    }
    const kmpid = parseString(&p, " ");
    if (kmpid == null or c.g_str_equal(kmpid, "mikey") == 0) {
        c.g_free(orig);
        return false;
    }
    var size: usize = 0;
    const data = c.g_base64_decode(p, &size);
    c.g_free(orig);
    if (data == null) return false;
    out.* = c.gst_mikey_message_new_from_data(data, size, null, null);
    c.g_free(data);
    return out.* != null;
}

fn keymgmtFrom(attrs: [*c]c.GArray, out: [*c][*c]c.GstMIKEYMessage) Result {
    var i: c.guint = 0;
    while (i < attrs[0].len) : (i += 1) {
        const a = at(Attr, attrs, i);
        if (c.g_str_equal(a.key, "key-mgmt") != 0) return @intFromBool(parseKeymgmt(a.value, @ptrCast(out)));
    }
    return OK;
}

pub export fn gst_sdp_message_parse_keymgmt(msg: [*c]const c.GstSDPMessage, out: [*c][*c]c.GstMIKEYMessage) Result {
    if (!that(msg != null, "gst_sdp_message_parse_keymgmt", "msg != NULL")) return EINVAL;
    return keymgmtFrom(msg[0].attributes, out);
}

pub export fn gst_sdp_media_parse_keymgmt(media: [*c]const Media, out: [*c][*c]c.GstMIKEYMessage) Result {
    if (!that(media != null, "gst_sdp_media_parse_keymgmt", "media != NULL")) return EINVAL;
    return keymgmtFrom(media[0].attributes, out);
}

fn attrsToCaps(attrs: [*c]c.GArray, caps: [*c]c.GstCaps) void {
    if (attrs[0].len == 0) return;
    const s = c.gst_caps_get_structure(caps, 0);
    var i: c.guint = 0;
    while (i < attrs[0].len) : (i += 1) {
        const a = at(Attr, attrs, i);
        var skip = false;
        for ([_][*:0]const u8{ "fmtp", "rtpmap", "control", "range", "framesize", "key-mgmt", "extmap", "ssrc", "rid", "source-filter" }) |k| {
            if (c.strcmp(a.key, k) == 0) skip = true;
        }
        if (skip) continue;
        if (a.value != null and c.g_utf8_validate(a.value, -1, null) == 0) continue;
        var key: CStr = a.key;
        var tofree: Str = null;
        if (c.g_str_has_prefix(key, "x-") == 0) {
            tofree = c.g_strdup_printf("a-%s", key);
            key = tofree;
        }
        c.gst_structure_set(s, key, c.G_TYPE_STRING, a.value, N);
        c.g_free(tofree);
    }
}

fn extmapToCaps(attrs: [*c]c.GArray, caps: [*c]c.GstCaps) Result {
    if (!that(attrs != null, "gst_sdp_media_add_extmap_attributes", "attributes != NULL")) return EINVAL;
    if (!that(isCaps(caps), "gst_sdp_media_add_extmap_attributes", "caps != NULL && GST_IS_CAPS (caps)")) return EINVAL;
    const s = c.gst_caps_get_structure(caps, 0);
    var i: c.guint = 0;
    while (i < attrs[0].len) : (i += 1) {
        const a = at(Attr, attrs, i);
        if (c.strcmp(a.key, "extmap") != 0) continue;
        const to_free = c.g_strdup(a.value);
        defer c.g_free(to_free);
        var p: [*c]u8 = to_free;
        var tmp: [*c]u8 = null;
        const id: c.guint = @truncate(c.strtoul(p, &tmp, 10));
        var dir: CStr = "";
        if (id == 0 or id == 15 or id > 9999 or (tmp[0] != ' ' and tmp[0] != '/')) continue;
        if (tmp[0] == '/') {
            p = tmp + 1;
            const d = parseString(&p, " ");
            if (d == null or d[0] == 0) continue;
            dir = d;
        } else p = tmp;
        skipSpaces(&p);
        var ename: CStr = p;
        var eattrs: CStr = "";
        tmp = c.strstr(p, " ");
        if (tmp != null) {
            ename = p;
            tmp[0] = 0;
            p = tmp + 1;
            skipSpaces(&p);
            eattrs = p;
        }
        if (ename == null or ename[0] == 0) continue;
        const key = c.g_strdup_printf("extmap-%u", id);
        if (dir[0] != 0 or eattrs[0] != 0) {
            var arr = std.mem.zeroes(c.GValue);
            var val = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&arr, c.gst_value_array_get_type());
            _ = c.g_value_init(&val, c.G_TYPE_STRING);
            c.g_value_set_string(&val, dir);
            c.gst_value_array_append_value(&arr, &val);
            c.g_value_set_string(&val, ename);
            c.gst_value_array_append_value(&arr, &val);
            c.g_value_set_string(&val, eattrs);
            c.gst_value_array_append_value(&arr, &val);
            c.gst_structure_set_value(s, key, &arr);
            c.g_value_unset(&val);
            c.g_value_unset(&arr);
        } else c.gst_structure_set(s, key, c.G_TYPE_STRING, ename, N);
        c.g_free(key);
    }
    return OK;
}

fn ssrcToCaps(attrs: [*c]c.GArray, caps: [*c]c.GstCaps) Result {
    if (!that(attrs != null, "gst_sdp_media_add_ssrc_attributes", "attributes != NULL")) return EINVAL;
    if (!that(isCaps(caps), "gst_sdp_media_add_ssrc_attributes", "caps != NULL && GST_IS_CAPS (caps)")) return EINVAL;
    const s = c.gst_caps_get_structure(caps, 0);
    var i: c.guint = 0;
    while (i < attrs[0].len) : (i += 1) {
        const a = at(Attr, attrs, i);
        if (c.strcmp(a.key, "ssrc") != 0) continue;
        const to_free = c.g_strdup(a.value);
        defer c.g_free(to_free);
        var p: [*c]u8 = to_free;
        var tmp: [*c]u8 = null;
        const ssrc: u32 = @truncate(c.strtoul(p, &tmp, 10));
        if (tmp[0] != ' ') continue;
        p = tmp;
        skipSpaces(&p);
        tmp = c.strstr(p, ":");
        var sattr: CStr = null;
        var sval: CStr = "";
        if (tmp != null) {
            sattr = p;
            tmp[0] = 0;
            sval = tmp + 1;
        }
        if (sattr == null or sattr[0] == 0) continue;
        const key = c.g_strdup_printf("ssrc-%u-%s", ssrc, sattr);
        c.gst_structure_set(s, key, c.G_TYPE_STRING, sval, N);
        c.g_free(key);
    }
    return OK;
}

fn ridToCaps(attrs: [*c]c.GArray, caps: [*c]c.GstCaps) Result {
    if (!that(attrs != null, "gst_sdp_media_add_rid_attributes", "attributes != NULL")) return EINVAL;
    if (!that(isCaps(caps), "gst_sdp_media_add_rid_attributes", "caps != NULL && GST_IS_CAPS (caps)")) return EINVAL;
    if (!that(c.gst_mini_object_is_writable(@ptrCast(caps)) != 0, "gst_sdp_media_add_rid_attributes", "gst_caps_is_writable (caps)")) return EINVAL;
    const s = c.gst_caps_get_structure(caps, 0);
    var i: c.guint = 0;
    while (i < attrs[0].len) : (i += 1) {
        const a = at(Attr, attrs, i);
        if (c.strcmp(a.key, "rid") != 0) continue;
        const to_free = c.g_strdup(a.value);
        defer c.g_free(to_free);
        var p: [*c]u8 = to_free;
        const id = parseString(&p, " ");
        if (id == null or id[0] == 0) continue;
        var t: [*c]u8 = id;
        while (t[0] != 0 and (t[0] == '-' or t[0] == '_' or c.g_ascii_isalnum(@as(c.gchar, @bitCast(t[0]))))) t += 1;
        if (t[0] != 0) continue;
        skipSpaces(&p);
        var dir: CStr = parseString(&p, " ");
        var params: CStr = null;
        if (dir == null or dir[0] == 0) {
            dir = p;
        } else {
            skipSpaces(&p);
            params = p;
        }
        if (dir == null or dir[0] == 0 or (c.g_strcmp0(dir, "send") != 0 and c.g_strcmp0(dir, "recv") != 0)) continue;
        const key = c.g_strdup_printf("rid-%s", id);
        if (params != null and params[0] != 0) {
            var arr = std.mem.zeroes(c.GValue);
            var val = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&arr, c.gst_value_array_get_type());
            _ = c.g_value_init(&val, c.G_TYPE_STRING);
            c.g_value_set_string(&val, dir);
            c.gst_value_array_append_and_take_value(&arr, &val);
            while (p[0] != 0) {
                var param: CStr = parseString(&p, ";");
                var done = false;
                if (param == null) {
                    if (p[0] != 0) {
                        param = p;
                        done = true;
                    } else break;
                }
                val = std.mem.zeroes(c.GValue);
                _ = c.g_value_init(&val, c.G_TYPE_STRING);
                c.g_value_set_string(&val, param);
                c.gst_value_array_append_and_take_value(&arr, &val);
                if (done) break;
            }
            c.gst_structure_take_value(s, key, &arr);
        } else c.gst_structure_set(s, key, c.G_TYPE_STRING, dir, N);
        c.g_free(key);
    }
    return OK;
}

pub export fn gst_sdp_message_attributes_to_caps(msg: [*c]const c.GstSDPMessage, caps: [*c]c.GstCaps) Result {
    if (!that(msg != null, "gst_sdp_message_attributes_to_caps", "msg != NULL")) return EINVAL;
    if (!that(isCaps(caps), "gst_sdp_message_attributes_to_caps", "caps != NULL && GST_IS_CAPS (caps)")) return EINVAL;
    var mk: [*c]c.GstMIKEYMessage = null;
    _ = gst_sdp_message_parse_keymgmt(msg, &mk);
    defer if (mk != null) c.gst_mini_object_unref(@ptrCast(mk));
    if (mk != null and c.gst_mikey_message_to_caps(mk, caps) != 0) return EINVAL;
    attrsToCaps(msg[0].attributes, caps);
    return extmapToCaps(msg[0].attributes, caps);
}

pub export fn gst_sdp_media_attributes_to_caps(media: [*c]const Media, caps: [*c]c.GstCaps) Result {
    if (!that(media != null, "gst_sdp_media_attributes_to_caps", "media != NULL")) return EINVAL;
    if (!that(isCaps(caps), "gst_sdp_media_attributes_to_caps", "caps != NULL && GST_IS_CAPS (caps)")) return EINVAL;
    var mk: [*c]c.GstMIKEYMessage = null;
    _ = gst_sdp_media_parse_keymgmt(media, &mk);
    defer if (mk != null) c.gst_mini_object_unref(@ptrCast(mk));
    if (mk != null and c.gst_mikey_message_to_caps(mk, caps) == 0) return EINVAL;
    attrsToCaps(media[0].attributes, caps);
    var r = extmapToCaps(media[0].attributes, caps);
    if (r == OK) r = ssrcToCaps(media[0].attributes, caps);
    if (r == OK) r = ridToCaps(media[0].attributes, caps);
    return r;
}
