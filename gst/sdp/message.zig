const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const mikey = @import("mikey.zig");

comptime {
    @import("../abi.zig").check(@This());
}

pub const DOMAIN = "GStreamer-SDP";

const OK = c.GST_SDP_OK;
const EINVAL = c.GST_SDP_EINVAL;
const N: ?*anyopaque = null;

const Msg = c.GstSDPMessage;
const Media = c.GstSDPMedia;
const Conn = c.GstSDPConnection;
const Bw = c.GstSDPBandwidth;
const Time = c.GstSDPTime;
const Zone = c.GstSDPZone;
const Attr = c.GstSDPAttribute;
const Result = c.GstSDPResult;
const Str = [*c]u8;
const CStr = [*c]const u8;

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as(CStr, func ++ ""), @as(CStr, expr ++ ""));
    return ok;
}

fn replace(field: [*c]Str, v: CStr) void {
    c.g_free(field.*);
    field.* = c.g_strdup(v);
}

fn clear(field: [*c]Str) void {
    c.g_free(field.*);
    field.* = null;
}

fn at(comptime T: type, a: [*c]c.GArray, i: c.guint) *T {
    return @ptrCast(@alignCast(a[0].data + @as(usize, i) * @sizeOf(T)));
}

fn initArray(comptime T: type, field: [*c][*c]c.GArray, comptime f: anytype) void {
    if (field.* != null) {
        var i: c.guint = 0;
        while (i < field.*[0].len) : (i += 1) _ = f(at(T, field.*, i));
        _ = c.g_array_set_size(field.*, 0);
    } else field.* = c.g_array_new(0, 1, @sizeOf(T));
}

fn freeArray(field: [*c][*c]c.GArray) void {
    if (field.* != null) _ = c.g_array_free(field.*, 1);
    field.* = null;
}

fn clearStr(p: *Str) c.gint {
    clear(p);
    return 0;
}

fn insertAt(a: [*c]c.GArray, idx: c.gint, v: anytype) void {
    if (idx == -1) {
        _ = c.g_array_append_vals(a, @ptrCast(v), 1);
    } else _ = c.g_array_insert_vals(a, @bitCast(idx), @ptrCast(v), 1);
}

var msg_type: gtype.Once = .{};

fn boxedCopy(p: c.gpointer) callconv(.c) c.gpointer {
    if (p == null) return null;
    var cp: [*c]Msg = null;
    if (gst_sdp_message_copy(@ptrCast(@alignCast(p)), &cp) == OK) return cp;
    return null;
}

fn boxedFree(p: c.gpointer) callconv(.c) void {
    _ = gst_sdp_message_free(@ptrCast(@alignCast(p)));
}

pub export fn gst_sdp_message_get_type() c.GType {
    return msg_type.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstSDPMessage", boxedCopy, boxedFree);
        }
    }.f);
}

fn originInit(o: [*c]c.GstSDPOrigin) void {
    clear(&o[0].username);
    clear(&o[0].sess_id);
    clear(&o[0].sess_version);
    clear(&o[0].nettype);
    clear(&o[0].addrtype);
    clear(&o[0].addr);
}

fn keyInit(k: [*c]c.GstSDPKey) void {
    clear(&k[0].type);
    clear(&k[0].data);
}

pub export fn gst_sdp_message_new(msg: [*c][*c]Msg) Result {
    if (!that(msg != null, "gst_sdp_message_new", "msg != NULL")) return EINVAL;
    const m: [*c]Msg = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Msg))));
    msg.* = m;
    return gst_sdp_message_init(m);
}

pub export fn gst_sdp_message_new_from_text(text: CStr, msg: [*c][*c]Msg) Result {
    const r = gst_sdp_message_new(msg);
    if (r != OK) return r;
    return gst_sdp_message_parse_buffer(text, @truncate(c.strlen(text)), msg.*);
}

pub export fn gst_sdp_message_init(msg: [*c]Msg) Result {
    if (!that(msg != null, "gst_sdp_message_init", "msg != NULL")) return EINVAL;
    const m = &msg[0];
    clear(&m.version);
    originInit(&m.origin);
    clear(&m.session_name);
    clear(&m.information);
    clear(&m.uri);
    initArray(Str, &m.emails, clearStr);
    initArray(Str, &m.phones, clearStr);
    _ = gst_sdp_connection_clear(&m.connection);
    initArray(Bw, &m.bandwidths, gst_sdp_bandwidth_clear);
    initArray(Time, &m.times, gst_sdp_time_clear);
    initArray(Zone, &m.zones, gst_sdp_zone_clear);
    keyInit(&m.key);
    initArray(Attr, &m.attributes, gst_sdp_attribute_clear);
    initArray(Media, &m.medias, gst_sdp_media_uninit);
    return OK;
}

pub export fn gst_sdp_message_uninit(msg: [*c]Msg) Result {
    if (!that(msg != null, "gst_sdp_message_uninit", "msg != NULL")) return EINVAL;
    _ = gst_sdp_message_init(msg);
    const m = &msg[0];
    freeArray(&m.emails);
    freeArray(&m.phones);
    freeArray(&m.bandwidths);
    freeArray(&m.times);
    freeArray(&m.zones);
    freeArray(&m.attributes);
    freeArray(&m.medias);
    return OK;
}

pub export fn gst_sdp_message_copy(msg: [*c]const Msg, copy: [*c][*c]Msg) Result {
    if (!that(msg != null, "gst_sdp_message_copy", "msg != NULL")) return EINVAL;
    _ = gst_sdp_message_new(copy);
    const cp = copy.*;
    const m = &msg[0];
    replace(&cp[0].version, m.version);
    _ = gst_sdp_message_set_origin(cp, m.origin.username, m.origin.sess_id, m.origin.sess_version, m.origin.nettype, m.origin.addrtype, m.origin.addr);
    replace(&cp[0].session_name, m.session_name);
    replace(&cp[0].information, m.information);
    replace(&cp[0].uri, m.uri);
    var i: c.guint = 0;
    while (i < m.emails[0].len) : (i += 1) _ = gst_sdp_message_add_email(cp, gst_sdp_message_get_email(msg, i));
    i = 0;
    while (i < m.phones[0].len) : (i += 1) _ = gst_sdp_message_add_phone(cp, gst_sdp_message_get_phone(msg, i));
    _ = gst_sdp_message_set_connection(cp, m.connection.nettype, m.connection.addrtype, m.connection.address, m.connection.ttl, m.connection.addr_number);
    i = 0;
    while (i < m.bandwidths[0].len) : (i += 1) {
        const bw = at(Bw, m.bandwidths, i);
        _ = gst_sdp_message_add_bandwidth(cp, bw.bwtype, bw.bandwidth);
    }
    i = 0;
    while (i < m.times[0].len) : (i += 1) {
        const t = at(Time, m.times, i);
        var repeat: [*c]CStr = null;
        if (t.repeat != null) {
            const n = t.repeat[0].len;
            repeat = @ptrCast(@alignCast(c.g_malloc0((@as(usize, n) + 1) * @sizeOf(CStr))));
            var j: c.guint = 0;
            while (j < n) : (j += 1) repeat[j] = at(Str, t.repeat, j).*;
            repeat[n] = null;
        }
        _ = gst_sdp_message_add_time(cp, t.start, t.stop, repeat);
        c.g_free(@ptrCast(repeat));
    }
    i = 0;
    while (i < m.zones[0].len) : (i += 1) {
        const z = at(Zone, m.zones, i);
        _ = gst_sdp_message_add_zone(cp, z.time, z.typed_time);
    }
    _ = gst_sdp_message_set_key(cp, m.key.type, m.key.data);
    i = 0;
    while (i < m.attributes[0].len) : (i += 1) {
        const a = at(Attr, m.attributes, i);
        _ = gst_sdp_message_add_attribute(cp, a.key, a.value);
    }
    i = 0;
    while (i < m.medias[0].len) : (i += 1) {
        var mc: [*c]Media = null;
        if (gst_sdp_media_copy(at(Media, m.medias, i), &mc) == OK) {
            _ = gst_sdp_message_add_media(cp, mc);
            _ = gst_sdp_media_free(mc);
        }
    }
    return OK;
}

pub export fn gst_sdp_message_free(msg: [*c]Msg) Result {
    if (!that(msg != null, "gst_sdp_message_free", "msg != NULL")) return EINVAL;
    _ = gst_sdp_message_uninit(msg);
    c.g_free(msg);
    return OK;
}

pub export fn gst_sdp_address_is_multicast(nettype: CStr, _: CStr, addr: CStr) c.gboolean {
    if (!that(addr != null, "gst_sdp_address_is_multicast", "addr")) return 0;
    if (nettype != null and c.strcmp(nettype, "IN") != 0) return 0;
    const ia = c.g_inet_address_new_from_string(addr);
    if (ia == null) return 0;
    const r = c.g_inet_address_get_is_multicast(ia);
    c.g_object_unref(ia);
    return r;
}

fn connText(lines: [*c]c.GString, conn: [*c]const Conn) void {
    c.g_string_append_printf(lines, "c=%s %s %s", conn[0].nettype, conn[0].addrtype, conn[0].address);
    if (gst_sdp_address_is_multicast(conn[0].nettype, conn[0].addrtype, conn[0].address) != 0) {
        if (c.strcmp(conn[0].addrtype, "IP4") == 0) c.g_string_append_printf(lines, "/%u", conn[0].ttl);
        if (conn[0].addr_number > 1) c.g_string_append_printf(lines, "/%u", conn[0].addr_number);
    }
    c.g_string_append_printf(lines, "\r\n");
}

fn keyText(lines: [*c]c.GString, k: [*c]const c.GstSDPKey) void {
    if (k[0].type == null) return;
    c.g_string_append_printf(lines, "k=%s", k[0].type);
    if (k[0].data != null) c.g_string_append_printf(lines, ":%s", k[0].data);
    c.g_string_append_printf(lines, "\r\n");
}

fn attrsText(lines: [*c]c.GString, attrs: [*c]c.GArray) void {
    var i: c.guint = 0;
    while (i < attrs[0].len) : (i += 1) {
        const a = at(Attr, attrs, i);
        if (a.key == null) continue;
        c.g_string_append_printf(lines, "a=%s", a.key);
        if (a.value != null and a.value[0] != 0) c.g_string_append_printf(lines, ":%s", a.value);
        c.g_string_append_printf(lines, "\r\n");
    }
}

fn bwText(lines: [*c]c.GString, bws: [*c]c.GArray) void {
    var i: c.guint = 0;
    while (i < bws[0].len) : (i += 1) {
        const b = at(Bw, bws, i);
        c.g_string_append_printf(lines, "b=%s:%u\r\n", b.bwtype, b.bandwidth);
    }
}

pub export fn gst_sdp_message_as_text(msg: [*c]const Msg) Str {
    if (!that(msg != null, "gst_sdp_message_as_text", "msg != NULL")) return null;
    const m = &msg[0];
    const lines = c.g_string_new("");
    if (m.version != null) c.g_string_append_printf(lines, "v=%s\r\n", m.version);
    const o = &m.origin;
    if (o.sess_id != null and o.sess_version != null and o.nettype != null and o.addrtype != null and o.addr != null)
        c.g_string_append_printf(lines, "o=%s %s %s %s %s %s\r\n", if (o.username != null) o.username else @as(CStr, "-"), o.sess_id, o.sess_version, o.nettype, o.addrtype, o.addr);
    if (m.session_name != null) c.g_string_append_printf(lines, "s=%s\r\n", m.session_name);
    if (m.information != null) c.g_string_append_printf(lines, "i=%s\r\n", m.information);
    if (m.uri != null) c.g_string_append_printf(lines, "u=%s\r\n", m.uri);
    var i: c.guint = 0;
    while (i < m.emails[0].len) : (i += 1) c.g_string_append_printf(lines, "e=%s\r\n", at(Str, m.emails, i).*);
    i = 0;
    while (i < m.phones[0].len) : (i += 1) c.g_string_append_printf(lines, "p=%s\r\n", at(Str, m.phones, i).*);
    if (m.connection.nettype != null and m.connection.addrtype != null and m.connection.address != null) connText(lines, &m.connection);
    bwText(lines, m.bandwidths);
    if (m.times[0].len == 0) {
        c.g_string_append_printf(lines, "t=0 0\r\n");
    } else {
        i = 0;
        while (i < m.times[0].len) : (i += 1) {
            const t = at(Time, m.times, i);
            c.g_string_append_printf(lines, "t=%s %s\r\n", t.start, t.stop);
            if (t.repeat != null) {
                c.g_string_append_printf(lines, "r=%s", at(Str, t.repeat, 0).*);
                var j: c.guint = 1;
                while (j < t.repeat[0].len) : (j += 1) c.g_string_append_printf(lines, " %s", at(Str, t.repeat, j).*);
                c.g_string_append_printf(lines, "\r\n");
            }
        }
    }
    if (m.zones[0].len > 0) {
        var z = at(Zone, m.zones, 0);
        c.g_string_append_printf(lines, "z=%s %s", z.time, z.typed_time);
        i = 1;
        while (i < m.zones[0].len) : (i += 1) {
            z = at(Zone, m.zones, i);
            c.g_string_append_printf(lines, " %s %s", z.time, z.typed_time);
        }
        c.g_string_append_printf(lines, "\r\n");
    }
    keyText(lines, &m.key);
    attrsText(lines, m.attributes);
    i = 0;
    while (i < m.medias[0].len) : (i += 1) {
        const s = gst_sdp_media_as_text(at(Media, m.medias, i));
        c.g_string_append_printf(lines, "%s", s);
        c.g_free(s);
    }
    return c.g_string_free(lines, 0);
}

fn hexToInt(ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'A'...'F' => ch - 'A' + 10,
        'a'...'f' => ch - 'a' + 10,
        else => 0,
    };
}

pub export fn gst_sdp_message_parse_uri(uri: CStr, msg: [*c]Msg) Result {
    if (!that(uri != null, "gst_sdp_message_parse_uri", "uri != NULL")) return EINVAL;
    if (!that(msg != null, "gst_sdp_message_parse_uri", "msg != NULL")) return EINVAL;
    const colon = c.strstr(uri, "://");
    if (colon == null) return EINVAL;
    const slash = c.strstr(colon + 3, "/");
    if (slash == null) return EINVAL;
    const hash = c.strstr(slash + 1, "#");
    if (hash == null) return EINVAL;
    const lines = c.g_string_new("");
    var p: CStr = hash + 1;
    while (p[0] != 0) : (p += 1) {
        switch (p[0]) {
            '&' => c.g_string_append_printf(lines, "\r\n"),
            '+' => _ = c.g_string_append_c(lines, ' '),
            '%' => {
                const a = p[1];
                if (a != 0) {
                    const b = p[2];
                    if (b != 0) {
                        _ = c.g_string_append_c(lines, @bitCast((hexToInt(a) << 4) | hexToInt(b)));
                        p += 2;
                    }
                } else p += 1;
            },
            else => _ = c.g_string_append_c(lines, @bitCast(p[0])),
        }
    }
    const message = c.g_string_free(lines, 0);
    const r = gst_sdp_message_parse_buffer(message, @truncate(c.strlen(message)), msg);
    c.g_free(message);
    return r;
}

const acceptable = [96]u8{
    0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0,
};

const hex = "0123456789ABCDEF";

pub export fn gst_sdp_message_as_uri(scheme: CStr, msg: [*c]const Msg) Str {
    if (!that(scheme != null, "gst_sdp_message_as_uri", "scheme != NULL")) return null;
    if (!that(msg != null, "gst_sdp_message_as_uri", "msg != NULL")) return null;
    const ser = gst_sdp_message_as_text(msg);
    const lines = c.g_string_new("");
    c.g_string_append_printf(lines, "%s:///#", scheme);
    var first = true;
    var p: [*c]u8 = ser;
    while (p[0] != 0) : (p += 1) {
        if (first) {
            c.g_string_append_printf(lines, "%c=", @as(c_int, @as(i8, @bitCast(p[0]))));
            if ((p + 1)[0] != 0) p += 1;
            first = false;
            continue;
        }
        const ch = p[0];
        if (ch == '\r') continue;
        if (ch == '\n') {
            if ((p + 1)[0] != 0) _ = c.g_string_append_c(lines, '&');
            first = true;
        } else if (ch == ' ') {
            _ = c.g_string_append_c(lines, '+');
        } else if (ch >= 32 and ch < 128 and acceptable[ch - 32] != 0) {
            _ = c.g_string_append_c(lines, @bitCast(ch));
        } else {
            c.g_string_append_printf(lines, "%%%c%c", @as(c_int, hex[(ch >> 4) & 0xf]), @as(c_int, hex[ch & 0xf]));
        }
    }
    const r = c.g_string_free(lines, 0);
    c.g_free(ser);
    return r;
}

pub export fn gst_sdp_message_set_version(msg: [*c]Msg, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_set_version", "msg != NULL")) return EINVAL;
    replace(&msg[0].version, v);
    return OK;
}

pub export fn gst_sdp_message_get_version(msg: [*c]const Msg) CStr {
    if (!that(msg != null, "gst_sdp_message_get_version", "msg != NULL")) return null;
    return msg[0].version;
}

pub export fn gst_sdp_message_set_origin(msg: [*c]Msg, username: CStr, sess_id: CStr, sess_version: CStr, nettype: CStr, addrtype: CStr, addr: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_set_origin", "msg != NULL")) return EINVAL;
    const o = &msg[0].origin;
    replace(&o.username, username);
    replace(&o.sess_id, sess_id);
    replace(&o.sess_version, sess_version);
    replace(&o.nettype, nettype);
    replace(&o.addrtype, addrtype);
    replace(&o.addr, addr);
    return OK;
}

pub export fn gst_sdp_message_get_origin(msg: [*c]const Msg) [*c]const c.GstSDPOrigin {
    if (!that(msg != null, "gst_sdp_message_get_origin", "msg != NULL")) return null;
    return &msg[0].origin;
}

pub export fn gst_sdp_message_set_session_name(msg: [*c]Msg, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_set_session_name", "msg != NULL")) return EINVAL;
    replace(&msg[0].session_name, v);
    return OK;
}

pub export fn gst_sdp_message_get_session_name(msg: [*c]const Msg) CStr {
    if (!that(msg != null, "gst_sdp_message_get_session_name", "msg != NULL")) return null;
    return msg[0].session_name;
}

pub export fn gst_sdp_message_set_information(msg: [*c]Msg, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_set_information", "msg != NULL")) return EINVAL;
    replace(&msg[0].information, v);
    return OK;
}

pub export fn gst_sdp_message_get_information(msg: [*c]const Msg) CStr {
    if (!that(msg != null, "gst_sdp_message_get_information", "msg != NULL")) return null;
    return msg[0].information;
}

pub export fn gst_sdp_message_set_uri(msg: [*c]Msg, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_set_uri", "msg != NULL")) return EINVAL;
    replace(&msg[0].uri, v);
    return OK;
}

pub export fn gst_sdp_message_get_uri(msg: [*c]const Msg) CStr {
    if (!that(msg != null, "gst_sdp_message_get_uri", "msg != NULL")) return null;
    return msg[0].uri;
}

pub export fn gst_sdp_message_emails_len(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_sdp_message_emails_len", "msg != NULL")) return 0;
    return msg[0].emails[0].len;
}

pub export fn gst_sdp_message_get_email(msg: [*c]const Msg, idx: c.guint) CStr {
    if (!that(msg != null, "gst_sdp_message_get_email", "msg != NULL")) return null;
    return at(Str, msg[0].emails, idx).*;
}

pub export fn gst_sdp_message_insert_email(msg: [*c]Msg, idx: c.gint, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_insert_email", "msg != NULL")) return EINVAL;
    var s: Str = c.g_strdup(v);
    insertAt(msg[0].emails, idx, &s);
    return OK;
}

pub export fn gst_sdp_message_replace_email(msg: [*c]Msg, idx: c.guint, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_replace_email", "msg != NULL")) return EINVAL;
    const p = at(Str, msg[0].emails, idx);
    clear(p);
    p.* = c.g_strdup(v);
    return OK;
}

pub export fn gst_sdp_message_remove_email(msg: [*c]Msg, idx: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_remove_email", "msg != NULL")) return EINVAL;
    clear(at(Str, msg[0].emails, idx));
    _ = c.g_array_remove_index(msg[0].emails, idx);
    return OK;
}

pub export fn gst_sdp_message_add_email(msg: [*c]Msg, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_add_email", "msg != NULL")) return EINVAL;
    return gst_sdp_message_insert_email(msg, -1, v);
}

pub export fn gst_sdp_message_phones_len(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_sdp_message_phones_len", "msg != NULL")) return 0;
    return msg[0].phones[0].len;
}

pub export fn gst_sdp_message_get_phone(msg: [*c]const Msg, idx: c.guint) CStr {
    if (!that(msg != null, "gst_sdp_message_get_phone", "msg != NULL")) return null;
    return at(Str, msg[0].phones, idx).*;
}

pub export fn gst_sdp_message_insert_phone(msg: [*c]Msg, idx: c.gint, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_insert_phone", "msg != NULL")) return EINVAL;
    var s: Str = c.g_strdup(v);
    insertAt(msg[0].phones, idx, &s);
    return OK;
}

pub export fn gst_sdp_message_replace_phone(msg: [*c]Msg, idx: c.guint, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_replace_phone", "msg != NULL")) return EINVAL;
    const p = at(Str, msg[0].phones, idx);
    clear(p);
    p.* = c.g_strdup(v);
    return OK;
}

pub export fn gst_sdp_message_remove_phone(msg: [*c]Msg, idx: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_remove_phone", "msg != NULL")) return EINVAL;
    clear(at(Str, msg[0].phones, idx));
    _ = c.g_array_remove_index(msg[0].phones, idx);
    return OK;
}

pub export fn gst_sdp_message_add_phone(msg: [*c]Msg, v: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_add_phone", "msg != NULL")) return EINVAL;
    return gst_sdp_message_insert_phone(msg, -1, v);
}

pub export fn gst_sdp_message_set_connection(msg: [*c]Msg, nettype: CStr, addrtype: CStr, address: CStr, ttl: c.guint, addr_number: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_set_connection", "msg != NULL")) return EINVAL;
    const k = &msg[0].connection;
    replace(&k.nettype, nettype);
    replace(&k.addrtype, addrtype);
    replace(&k.address, address);
    k.ttl = ttl;
    k.addr_number = addr_number;
    return OK;
}

pub export fn gst_sdp_message_get_connection(msg: [*c]const Msg) [*c]const Conn {
    if (!that(msg != null, "gst_sdp_message_get_connection", "msg != NULL")) return null;
    return &msg[0].connection;
}

pub export fn gst_sdp_bandwidth_set(bw: [*c]Bw, bwtype: CStr, bandwidth: c.guint) Result {
    if (!that(bw != null, "gst_sdp_bandwidth_set", "bw != NULL")) return EINVAL;
    bw[0].bwtype = c.g_strdup(bwtype);
    bw[0].bandwidth = bandwidth;
    return OK;
}

pub export fn gst_sdp_bandwidth_clear(bw: [*c]Bw) Result {
    if (!that(bw != null, "gst_sdp_bandwidth_clear", "bw != NULL")) return EINVAL;
    clear(&bw[0].bwtype);
    bw[0].bandwidth = 0;
    return OK;
}

pub export fn gst_sdp_message_bandwidths_len(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_sdp_message_bandwidths_len", "msg != NULL")) return 0;
    return msg[0].bandwidths[0].len;
}

pub export fn gst_sdp_message_get_bandwidth(msg: [*c]const Msg, idx: c.guint) [*c]const Bw {
    if (!that(msg != null, "gst_sdp_message_get_bandwidth", "msg != NULL")) return null;
    return at(Bw, msg[0].bandwidths, idx);
}

pub export fn gst_sdp_message_insert_bandwidth(msg: [*c]Msg, idx: c.gint, bw: [*c]Bw) Result {
    if (!that(msg != null, "gst_sdp_message_insert_bandwidth", "msg != NULL")) return EINVAL;
    var v: Bw = bw[0];
    insertAt(msg[0].bandwidths, idx, &v);
    return OK;
}

pub export fn gst_sdp_message_replace_bandwidth(msg: [*c]Msg, idx: c.guint, bw: [*c]Bw) Result {
    if (!that(msg != null, "gst_sdp_message_replace_bandwidth", "msg != NULL")) return EINVAL;
    const v = at(Bw, msg[0].bandwidths, idx);
    _ = gst_sdp_bandwidth_clear(v);
    v.* = bw[0];
    return OK;
}

pub export fn gst_sdp_message_remove_bandwidth(msg: [*c]Msg, idx: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_remove_bandwidth", "msg != NULL")) return EINVAL;
    _ = gst_sdp_bandwidth_clear(at(Bw, msg[0].bandwidths, idx));
    _ = c.g_array_remove_index(msg[0].bandwidths, idx);
    return OK;
}

pub export fn gst_sdp_message_add_bandwidth(msg: [*c]Msg, bwtype: CStr, bandwidth: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_add_bandwidth", "msg != NULL")) return EINVAL;
    var bw: Bw = undefined;
    _ = gst_sdp_bandwidth_set(&bw, bwtype, bandwidth);
    return gst_sdp_message_insert_bandwidth(msg, -1, &bw);
}

pub export fn gst_sdp_time_set(t: [*c]Time, start: CStr, stop: CStr, repeat_in: [*c]CStr) Result {
    if (!that(t != null, "gst_sdp_time_set", "t != NULL")) return EINVAL;
    t[0].start = c.g_strdup(start);
    t[0].stop = c.g_strdup(stop);
    if (repeat_in != null) {
        t[0].repeat = c.g_array_new(0, 1, @sizeOf(Str));
        var r = repeat_in;
        while (r[0] != null) : (r += 1) {
            var s: Str = c.g_strdup(r[0]);
            _ = c.g_array_append_vals(t[0].repeat, @ptrCast(&s), 1);
        }
    } else t[0].repeat = null;
    return OK;
}

pub export fn gst_sdp_time_clear(t: [*c]Time) Result {
    if (!that(t != null, "gst_sdp_time_clear", "t != NULL")) return EINVAL;
    clear(&t[0].start);
    clear(&t[0].stop);
    initArray(Str, &t[0].repeat, clearStr);
    freeArray(&t[0].repeat);
    return OK;
}

pub export fn gst_sdp_message_times_len(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_sdp_message_times_len", "msg != NULL")) return 0;
    return msg[0].times[0].len;
}

pub export fn gst_sdp_message_get_time(msg: [*c]const Msg, idx: c.guint) [*c]const Time {
    if (!that(msg != null, "gst_sdp_message_get_time", "msg != NULL")) return null;
    return at(Time, msg[0].times, idx);
}

pub export fn gst_sdp_message_insert_time(msg: [*c]Msg, idx: c.gint, t: [*c]Time) Result {
    if (!that(msg != null, "gst_sdp_message_insert_time", "msg != NULL")) return EINVAL;
    var v: Time = t[0];
    insertAt(msg[0].times, idx, &v);
    return OK;
}

pub export fn gst_sdp_message_replace_time(msg: [*c]Msg, idx: c.guint, t: [*c]Time) Result {
    if (!that(msg != null, "gst_sdp_message_replace_time", "msg != NULL")) return EINVAL;
    const v = at(Time, msg[0].times, idx);
    _ = gst_sdp_time_clear(v);
    v.* = t[0];
    return OK;
}

pub export fn gst_sdp_message_remove_time(msg: [*c]Msg, idx: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_remove_time", "msg != NULL")) return EINVAL;
    _ = gst_sdp_time_clear(at(Time, msg[0].times, idx));
    _ = c.g_array_remove_index(msg[0].times, idx);
    return OK;
}

pub export fn gst_sdp_message_add_time(msg: [*c]Msg, start: CStr, stop: CStr, repeat: [*c]CStr) Result {
    if (!that(msg != null, "gst_sdp_message_add_time", "msg != NULL")) return EINVAL;
    var t: Time = undefined;
    _ = gst_sdp_time_set(&t, start, stop, repeat);
    _ = c.g_array_append_vals(msg[0].times, @ptrCast(&t), 1);
    return OK;
}

pub export fn gst_sdp_zone_set(z: [*c]Zone, adj_time: CStr, typed_time: CStr) Result {
    if (!that(z != null, "gst_sdp_zone_set", "zone != NULL")) return EINVAL;
    z[0].time = c.g_strdup(adj_time);
    z[0].typed_time = c.g_strdup(typed_time);
    return OK;
}

pub export fn gst_sdp_zone_clear(z: [*c]Zone) Result {
    if (!that(z != null, "gst_sdp_zone_clear", "zone != NULL")) return EINVAL;
    clear(&z[0].time);
    clear(&z[0].typed_time);
    return OK;
}

pub export fn gst_sdp_message_zones_len(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_sdp_message_zones_len", "msg != NULL")) return 0;
    return msg[0].zones[0].len;
}

pub export fn gst_sdp_message_get_zone(msg: [*c]const Msg, idx: c.guint) [*c]const Zone {
    if (!that(msg != null, "gst_sdp_message_get_zone", "msg != NULL")) return null;
    return at(Zone, msg[0].zones, idx);
}

pub export fn gst_sdp_message_insert_zone(msg: [*c]Msg, idx: c.gint, z: [*c]Zone) Result {
    if (!that(msg != null, "gst_sdp_message_insert_zone", "msg != NULL")) return EINVAL;
    var v: Zone = z[0];
    insertAt(msg[0].zones, idx, &v);
    return OK;
}

pub export fn gst_sdp_message_replace_zone(msg: [*c]Msg, idx: c.guint, z: [*c]Zone) Result {
    if (!that(msg != null, "gst_sdp_message_replace_zone", "msg != NULL")) return EINVAL;
    const v = at(Zone, msg[0].zones, idx);
    _ = gst_sdp_zone_clear(v);
    v.* = z[0];
    return OK;
}

pub export fn gst_sdp_message_remove_zone(msg: [*c]Msg, idx: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_remove_zone", "msg != NULL")) return EINVAL;
    _ = gst_sdp_zone_clear(at(Zone, msg[0].zones, idx));
    _ = c.g_array_remove_index(msg[0].zones, idx);
    return OK;
}

pub export fn gst_sdp_message_add_zone(msg: [*c]Msg, adj_time: CStr, typed_time: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_add_zone", "msg != NULL")) return EINVAL;
    var z: Zone = undefined;
    _ = gst_sdp_zone_set(&z, adj_time, typed_time);
    _ = c.g_array_append_vals(msg[0].zones, @ptrCast(&z), 1);
    return OK;
}

pub export fn gst_sdp_message_set_key(msg: [*c]Msg, kind: CStr, data: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_set_key", "msg != NULL")) return EINVAL;
    replace(&msg[0].key.type, kind);
    replace(&msg[0].key.data, data);
    return OK;
}

pub export fn gst_sdp_message_get_key(msg: [*c]const Msg) [*c]const c.GstSDPKey {
    if (!that(msg != null, "gst_sdp_message_get_key", "msg != NULL")) return null;
    return &msg[0].key;
}

pub export fn gst_sdp_attribute_set(a: [*c]Attr, key: CStr, value: CStr) Result {
    if (!that(a != null, "gst_sdp_attribute_set", "attr != NULL")) return EINVAL;
    if (!that(key != null, "gst_sdp_attribute_set", "key != NULL")) return EINVAL;
    a[0].key = c.g_strdup(key);
    a[0].value = c.g_strdup(value);
    return OK;
}

pub export fn gst_sdp_attribute_clear(a: [*c]Attr) Result {
    if (!that(a != null, "gst_sdp_attribute_clear", "attr != NULL")) return EINVAL;
    clear(&a[0].key);
    clear(&a[0].value);
    return OK;
}

pub export fn gst_sdp_message_attributes_len(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_sdp_message_attributes_len", "msg != NULL")) return 0;
    return msg[0].attributes[0].len;
}

pub export fn gst_sdp_message_get_attribute(msg: [*c]const Msg, idx: c.guint) [*c]const Attr {
    if (!that(msg != null, "gst_sdp_message_get_attribute", "msg != NULL")) return null;
    return at(Attr, msg[0].attributes, idx);
}

fn attrValN(attrs: [*c]c.GArray, key: CStr, nth_in: c.guint) CStr {
    var nth = nth_in;
    var i: c.guint = 0;
    while (i < attrs[0].len) : (i += 1) {
        const a = at(Attr, attrs, i);
        if (c.strcmp(a.key, key) == 0) {
            if (nth == 0) return a.value;
            nth -= 1;
        }
    }
    return null;
}

pub export fn gst_sdp_message_get_attribute_val_n(msg: [*c]const Msg, key: CStr, nth: c.guint) CStr {
    if (!that(msg != null, "gst_sdp_message_get_attribute_val_n", "msg != NULL")) return null;
    if (!that(key != null, "gst_sdp_message_get_attribute_val_n", "key != NULL")) return null;
    return attrValN(msg[0].attributes, key, nth);
}

pub export fn gst_sdp_message_get_attribute_val(msg: [*c]const Msg, key: CStr) CStr {
    return gst_sdp_message_get_attribute_val_n(msg, key, 0);
}

pub export fn gst_sdp_message_insert_attribute(msg: [*c]Msg, idx: c.gint, a: [*c]Attr) Result {
    if (!that(msg != null, "gst_sdp_message_insert_attribute", "msg != NULL")) return EINVAL;
    var v: Attr = a[0];
    insertAt(msg[0].attributes, idx, &v);
    return OK;
}

pub export fn gst_sdp_message_replace_attribute(msg: [*c]Msg, idx: c.guint, a: [*c]Attr) Result {
    if (!that(msg != null, "gst_sdp_message_replace_attribute", "msg != NULL")) return EINVAL;
    const v = at(Attr, msg[0].attributes, idx);
    _ = gst_sdp_attribute_clear(v);
    v.* = a[0];
    return OK;
}

pub export fn gst_sdp_message_remove_attribute(msg: [*c]Msg, idx: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_remove_attribute", "msg != NULL")) return EINVAL;
    _ = gst_sdp_attribute_clear(at(Attr, msg[0].attributes, idx));
    _ = c.g_array_remove_index(msg[0].attributes, idx);
    return OK;
}

pub export fn gst_sdp_message_add_attribute(msg: [*c]Msg, key: CStr, value: CStr) Result {
    if (!that(msg != null, "gst_sdp_message_add_attribute", "msg != NULL")) return EINVAL;
    if (!that(key != null, "gst_sdp_message_add_attribute", "key != NULL")) return EINVAL;
    var a: Attr = undefined;
    _ = gst_sdp_attribute_set(&a, key, value);
    _ = c.g_array_append_vals(msg[0].attributes, @ptrCast(&a), 1);
    return OK;
}

pub export fn gst_sdp_message_medias_len(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_sdp_message_medias_len", "msg != NULL")) return 0;
    return msg[0].medias[0].len;
}

pub export fn gst_sdp_message_get_media(msg: [*c]const Msg, idx: c.guint) [*c]const Media {
    if (!that(msg != null, "gst_sdp_message_get_media", "msg != NULL")) return null;
    return at(Media, msg[0].medias, idx);
}

pub export fn gst_sdp_message_add_media(msg: [*c]Msg, media: [*c]Media) Result {
    if (!that(msg != null, "gst_sdp_message_add_media", "msg != NULL")) return EINVAL;
    if (!that(media != null, "gst_sdp_message_add_media", "media != NULL")) return EINVAL;
    const len = msg[0].medias[0].len;
    _ = c.g_array_set_size(msg[0].medias, len + 1);
    at(Media, msg[0].medias, len).* = media[0];
    media[0] = std.mem.zeroes(Media);
    return OK;
}

pub export fn gst_sdp_message_remove_media(msg: [*c]Msg, idx: c.guint) Result {
    if (!that(msg != null, "gst_sdp_message_remove_media", "msg != NULL")) return EINVAL;
    if (!that(idx <= gst_sdp_message_medias_len(msg), "gst_sdp_message_remove_media", "idx <= gst_sdp_message_medias_len (msg)")) return EINVAL;
    _ = gst_sdp_media_uninit(at(Media, msg[0].medias, idx));
    _ = c.g_array_remove_index(msg[0].medias, idx);
    return OK;
}

pub export fn gst_sdp_media_new(media: [*c][*c]Media) Result {
    if (!that(media != null, "gst_sdp_media_new", "media != NULL")) return EINVAL;
    const m: [*c]Media = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Media))));
    media.* = m;
    return gst_sdp_media_init(m);
}

pub export fn gst_sdp_media_init(media: [*c]Media) Result {
    if (!that(media != null, "gst_sdp_media_init", "media != NULL")) return EINVAL;
    const m = &media[0];
    clear(&m.media);
    m.port = 0;
    m.num_ports = 0;
    clear(&m.proto);
    initArray(Str, &m.fmts, clearStr);
    clear(&m.information);
    initArray(Conn, &m.connections, gst_sdp_connection_clear);
    initArray(Bw, &m.bandwidths, gst_sdp_bandwidth_clear);
    keyInit(&m.key);
    initArray(Attr, &m.attributes, gst_sdp_attribute_clear);
    return OK;
}

pub export fn gst_sdp_media_uninit(media: [*c]Media) Result {
    if (!that(media != null, "gst_sdp_media_uninit", "media != NULL")) return EINVAL;
    _ = gst_sdp_media_init(media);
    freeArray(&media[0].fmts);
    freeArray(&media[0].connections);
    freeArray(&media[0].bandwidths);
    freeArray(&media[0].attributes);
    return OK;
}

pub export fn gst_sdp_media_free(media: [*c]Media) Result {
    if (!that(media != null, "gst_sdp_media_free", "media != NULL")) return EINVAL;
    _ = gst_sdp_media_uninit(media);
    c.g_free(media);
    return OK;
}

pub export fn gst_sdp_media_copy(media: [*c]const Media, copy: [*c][*c]Media) Result {
    if (!that(media != null, "gst_sdp_media_copy", "media != NULL")) return EINVAL;
    _ = gst_sdp_media_new(copy);
    const cp = copy.*;
    const m = &media[0];
    replace(&cp[0].media, m.media);
    cp[0].port = m.port;
    cp[0].num_ports = m.num_ports;
    replace(&cp[0].proto, m.proto);
    var i: c.guint = 0;
    while (i < m.fmts[0].len) : (i += 1) _ = gst_sdp_media_add_format(cp, gst_sdp_media_get_format(media, i));
    replace(&cp[0].information, m.information);
    i = 0;
    while (i < m.connections[0].len) : (i += 1) {
        const k = at(Conn, m.connections, i);
        _ = gst_sdp_media_add_connection(cp, k.nettype, k.addrtype, k.address, k.ttl, k.addr_number);
    }
    i = 0;
    while (i < m.bandwidths[0].len) : (i += 1) {
        const b = at(Bw, m.bandwidths, i);
        _ = gst_sdp_media_add_bandwidth(cp, b.bwtype, b.bandwidth);
    }
    _ = gst_sdp_media_set_key(cp, m.key.type, m.key.data);
    i = 0;
    while (i < m.attributes[0].len) : (i += 1) {
        const a = at(Attr, m.attributes, i);
        _ = gst_sdp_media_add_attribute(cp, a.key, a.value);
    }
    return OK;
}

pub export fn gst_sdp_media_as_text(media: [*c]const Media) Str {
    if (!that(media != null, "gst_sdp_media_as_text", "media != NULL")) return null;
    const m = &media[0];
    const lines = c.g_string_new("");
    if (m.media != null) c.g_string_append_printf(lines, "m=%s", m.media);
    c.g_string_append_printf(lines, " %u", m.port);
    if (m.num_ports > 1) c.g_string_append_printf(lines, "/%u", m.num_ports);
    c.g_string_append_printf(lines, " %s", m.proto);
    var i: c.guint = 0;
    while (i < m.fmts[0].len) : (i += 1) c.g_string_append_printf(lines, " %s", gst_sdp_media_get_format(media, i));
    c.g_string_append_printf(lines, "\r\n");
    if (m.information != null) c.g_string_append_printf(lines, "i=%s", m.information);
    i = 0;
    while (i < m.connections[0].len) : (i += 1) {
        const k = at(Conn, m.connections, i);
        if (k.nettype != null and k.addrtype != null and k.address != null) connText(lines, k);
    }
    bwText(lines, m.bandwidths);
    keyText(lines, &m.key);
    attrsText(lines, m.attributes);
    return c.g_string_free(lines, 0);
}

pub export fn gst_sdp_media_get_media(media: [*c]const Media) CStr {
    if (!that(media != null, "gst_sdp_media_get_media", "media != NULL")) return null;
    return media[0].media;
}

pub export fn gst_sdp_media_set_media(media: [*c]Media, med: CStr) Result {
    if (!that(media != null, "gst_sdp_media_set_media", "media != NULL")) return EINVAL;
    if (!that(med != null, "gst_sdp_media_set_media", "med != NULL")) return EINVAL;
    replace(&media[0].media, med);
    return OK;
}

pub export fn gst_sdp_media_get_port(media: [*c]const Media) c.guint {
    if (!that(media != null, "gst_sdp_media_get_port", "media != NULL")) return 0;
    return media[0].port;
}

pub export fn gst_sdp_media_get_num_ports(media: [*c]const Media) c.guint {
    if (!that(media != null, "gst_sdp_media_get_num_ports", "media != NULL")) return 0;
    return media[0].num_ports;
}

pub export fn gst_sdp_media_set_port_info(media: [*c]Media, port: c.guint, num_ports: c.guint) Result {
    if (!that(media != null, "gst_sdp_media_set_port_info", "media != NULL")) return EINVAL;
    media[0].port = port;
    media[0].num_ports = num_ports;
    return OK;
}

pub export fn gst_sdp_media_get_proto(media: [*c]const Media) CStr {
    if (!that(media != null, "gst_sdp_media_get_proto", "media != NULL")) return null;
    return media[0].proto;
}

pub export fn gst_sdp_media_set_proto(media: [*c]Media, proto: CStr) Result {
    if (!that(media != null, "gst_sdp_media_set_proto", "media != NULL")) return EINVAL;
    replace(&media[0].proto, proto);
    return OK;
}

pub export fn gst_sdp_media_formats_len(media: [*c]const Media) c.guint {
    if (!that(media != null, "gst_sdp_media_formats_len", "media != NULL")) return 0;
    return media[0].fmts[0].len;
}

pub export fn gst_sdp_media_get_format(media: [*c]const Media, idx: c.guint) CStr {
    if (!that(media != null, "gst_sdp_media_get_format", "media != NULL")) return null;
    if (idx >= media[0].fmts[0].len) return null;
    return at(Str, media[0].fmts, idx).*;
}

pub export fn gst_sdp_media_insert_format(media: [*c]Media, idx: c.gint, format: CStr) Result {
    if (!that(media != null, "gst_sdp_media_insert_format", "media != NULL")) return EINVAL;
    if (!that(format != null, "gst_sdp_media_insert_format", "format != NULL")) return EINVAL;
    var s: Str = c.g_strdup(format);
    insertAt(media[0].fmts, idx, &s);
    return OK;
}

pub export fn gst_sdp_media_replace_format(media: [*c]Media, idx: c.guint, format: CStr) Result {
    if (!that(media != null, "gst_sdp_media_replace_format", "media != NULL")) return EINVAL;
    if (!that(format != null, "gst_sdp_media_replace_format", "format != NULL")) return EINVAL;
    const p = at(Str, media[0].fmts, idx);
    c.g_free(p.*);
    p.* = c.g_strdup(format);
    return OK;
}

pub export fn gst_sdp_media_remove_format(media: [*c]Media, idx: c.guint) Result {
    if (!that(media != null, "gst_sdp_media_remove_format", "media != NULL")) return EINVAL;
    c.g_free(at(Str, media[0].fmts, idx).*);
    _ = c.g_array_remove_index(media[0].fmts, idx);
    return OK;
}

pub export fn gst_sdp_media_add_format(media: [*c]Media, format: CStr) Result {
    if (!that(media != null, "gst_sdp_media_add_format", "media != NULL")) return EINVAL;
    if (!that(format != null, "gst_sdp_media_add_format", "format != NULL")) return EINVAL;
    var s: Str = c.g_strdup(format);
    _ = c.g_array_append_vals(media[0].fmts, @ptrCast(&s), 1);
    return OK;
}

pub export fn gst_sdp_media_get_information(media: [*c]const Media) CStr {
    if (!that(media != null, "gst_sdp_media_get_information", "media != NULL")) return null;
    return media[0].information;
}

pub export fn gst_sdp_media_set_information(media: [*c]Media, information: CStr) Result {
    if (!that(media != null, "gst_sdp_media_set_information", "media != NULL")) return EINVAL;
    replace(&media[0].information, information);
    return OK;
}

pub export fn gst_sdp_connection_set(conn: [*c]Conn, nettype: CStr, addrtype: CStr, address: CStr, ttl: c.guint, addr_number: c.guint) Result {
    const f = "gst_sdp_connection_set";
    if (!that(conn != null, f, "conn != NULL")) return EINVAL;
    if (!that(nettype != null, f, "nettype != NULL")) return EINVAL;
    if (!that(addrtype != null, f, "addrtype != NULL")) return EINVAL;
    if (!that(address != null, f, "address != NULL")) return EINVAL;
    conn[0].nettype = c.g_strdup(nettype);
    conn[0].addrtype = c.g_strdup(addrtype);
    conn[0].address = c.g_strdup(address);
    conn[0].ttl = ttl;
    conn[0].addr_number = addr_number;
    return OK;
}

pub export fn gst_sdp_connection_clear(conn: [*c]Conn) Result {
    if (!that(conn != null, "gst_sdp_connection_clear", "conn != NULL")) return EINVAL;
    clear(&conn[0].nettype);
    clear(&conn[0].addrtype);
    clear(&conn[0].address);
    conn[0].ttl = 0;
    conn[0].addr_number = 0;
    return OK;
}

pub export fn gst_sdp_media_connections_len(media: [*c]const Media) c.guint {
    if (!that(media != null, "gst_sdp_media_connections_len", "media != NULL")) return 0;
    return media[0].connections[0].len;
}

pub export fn gst_sdp_media_get_connection(media: [*c]const Media, idx: c.guint) [*c]const Conn {
    if (!that(media != null, "gst_sdp_media_get_connection", "media != NULL")) return null;
    if (!that(idx < media[0].connections[0].len, "gst_sdp_media_get_connection", "idx < media->connections->len")) return null;
    return at(Conn, media[0].connections, idx);
}

pub export fn gst_sdp_media_insert_connection(media: [*c]Media, idx: c.gint, conn: [*c]Conn) Result {
    const f = "gst_sdp_media_insert_connection";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(conn != null, f, "conn != NULL")) return EINVAL;
    if (!that(idx == -1 or idx < media[0].connections[0].len, f, "idx == -1 || idx < media->connections->len")) return EINVAL;
    var v = conn[0];
    insertAt(media[0].connections, idx, &v);
    return OK;
}

pub export fn gst_sdp_media_replace_connection(media: [*c]Media, idx: c.guint, conn: [*c]Conn) Result {
    const f = "gst_sdp_media_replace_connection";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(conn != null, f, "conn != NULL")) return EINVAL;
    if (!that(idx < media[0].connections[0].len, f, "idx < media->connections->len")) return EINVAL;
    const v = at(Conn, media[0].connections, idx);
    _ = gst_sdp_connection_clear(v);
    v.* = conn[0];
    return OK;
}

pub export fn gst_sdp_media_remove_connection(media: [*c]Media, idx: c.guint) Result {
    const f = "gst_sdp_media_remove_connection";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(idx < media[0].connections[0].len, f, "idx < media->connections->len")) return EINVAL;
    _ = gst_sdp_connection_clear(at(Conn, media[0].connections, idx));
    _ = c.g_array_remove_index(media[0].connections, idx);
    return OK;
}

pub export fn gst_sdp_media_add_connection(media: [*c]Media, nettype: CStr, addrtype: CStr, address: CStr, ttl: c.guint, addr_number: c.guint) Result {
    const f = "gst_sdp_media_add_connection";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(nettype != null, f, "nettype != NULL")) return EINVAL;
    if (!that(addrtype != null, f, "addrtype != NULL")) return EINVAL;
    if (!that(address != null, f, "address != NULL")) return EINVAL;
    var k: Conn = undefined;
    _ = gst_sdp_connection_set(&k, nettype, addrtype, address, ttl, addr_number);
    _ = c.g_array_append_vals(media[0].connections, @ptrCast(&k), 1);
    return OK;
}

pub export fn gst_sdp_media_bandwidths_len(media: [*c]const Media) c.guint {
    if (!that(media != null, "gst_sdp_media_bandwidths_len", "media != NULL")) return 0;
    return media[0].bandwidths[0].len;
}

pub export fn gst_sdp_media_get_bandwidth(media: [*c]const Media, idx: c.guint) [*c]const Bw {
    if (!that(media != null, "gst_sdp_media_get_bandwidth", "media != NULL")) return null;
    return at(Bw, media[0].bandwidths, idx);
}

pub export fn gst_sdp_media_insert_bandwidth(media: [*c]Media, idx: c.gint, bw: [*c]Bw) Result {
    const f = "gst_sdp_media_insert_bandwidth";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(bw != null, f, "bw != NULL")) return EINVAL;
    if (!that(idx == -1 or idx < media[0].bandwidths[0].len, f, "idx == -1 || idx < media->bandwidths->len")) return EINVAL;
    var v = bw[0];
    insertAt(media[0].bandwidths, idx, &v);
    return OK;
}

pub export fn gst_sdp_media_replace_bandwidth(media: [*c]Media, idx: c.guint, bw: [*c]Bw) Result {
    const f = "gst_sdp_media_replace_bandwidth";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(bw != null, f, "bw != NULL")) return EINVAL;
    if (!that(idx < media[0].bandwidths[0].len, f, "idx < media->bandwidths->len")) return EINVAL;
    const v = at(Bw, media[0].bandwidths, idx);
    _ = gst_sdp_bandwidth_clear(v);
    v.* = bw[0];
    return OK;
}

pub export fn gst_sdp_media_remove_bandwidth(media: [*c]Media, idx: c.guint) Result {
    const f = "gst_sdp_media_remove_bandwidth";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(idx < media[0].bandwidths[0].len, f, "idx < media->bandwidths->len")) return EINVAL;
    _ = gst_sdp_bandwidth_clear(at(Bw, media[0].bandwidths, idx));
    _ = c.g_array_remove_index(media[0].bandwidths, idx);
    return OK;
}

pub export fn gst_sdp_media_add_bandwidth(media: [*c]Media, bwtype: CStr, bandwidth: c.guint) Result {
    const f = "gst_sdp_media_add_bandwidth";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(bwtype != null, f, "bwtype != NULL")) return EINVAL;
    var b: Bw = undefined;
    _ = gst_sdp_bandwidth_set(&b, bwtype, bandwidth);
    _ = c.g_array_append_vals(media[0].bandwidths, @ptrCast(&b), 1);
    return OK;
}

pub export fn gst_sdp_media_set_key(media: [*c]Media, kind: CStr, data: CStr) Result {
    if (!that(media != null, "gst_sdp_media_set_key", "media != NULL")) return EINVAL;
    replace(&media[0].key.type, kind);
    replace(&media[0].key.data, data);
    return OK;
}

pub export fn gst_sdp_media_get_key(media: [*c]const Media) [*c]const c.GstSDPKey {
    if (!that(media != null, "gst_sdp_media_get_key", "media != NULL")) return null;
    return &media[0].key;
}

pub export fn gst_sdp_media_attributes_len(media: [*c]const Media) c.guint {
    if (!that(media != null, "gst_sdp_media_attributes_len", "media != NULL")) return 0;
    return media[0].attributes[0].len;
}

pub export fn gst_sdp_media_add_attribute(media: [*c]Media, key: CStr, value: CStr) Result {
    const f = "gst_sdp_media_add_attribute";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(key != null, f, "key != NULL")) return EINVAL;
    var a: Attr = undefined;
    _ = gst_sdp_attribute_set(&a, key, value);
    _ = c.g_array_append_vals(media[0].attributes, @ptrCast(&a), 1);
    return OK;
}

pub export fn gst_sdp_media_get_attribute(media: [*c]const Media, idx: c.guint) [*c]const Attr {
    if (!that(media != null, "gst_sdp_media_get_attribute", "media != NULL")) return null;
    if (!that(idx < media[0].attributes[0].len, "gst_sdp_media_get_attribute", "idx < media->attributes->len")) return null;
    return at(Attr, media[0].attributes, idx);
}

pub export fn gst_sdp_media_get_attribute_val_n(media: [*c]const Media, key: CStr, nth: c.guint) CStr {
    if (!that(media != null, "gst_sdp_media_get_attribute_val_n", "media != NULL")) return null;
    if (!that(key != null, "gst_sdp_media_get_attribute_val_n", "key != NULL")) return null;
    return attrValN(media[0].attributes, key, nth);
}

pub export fn gst_sdp_media_get_attribute_val(media: [*c]const Media, key: CStr) CStr {
    if (!that(media != null, "gst_sdp_media_get_attribute_val", "media != NULL")) return null;
    if (!that(key != null, "gst_sdp_media_get_attribute_val", "key != NULL")) return null;
    return gst_sdp_media_get_attribute_val_n(media, key, 0);
}

pub export fn gst_sdp_media_insert_attribute(media: [*c]Media, idx: c.gint, a: [*c]Attr) Result {
    const f = "gst_sdp_media_insert_attribute";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(a != null, f, "attr != NULL")) return EINVAL;
    if (!that(idx == -1 or idx < media[0].attributes[0].len, f, "idx == -1 || idx < media->attributes->len")) return EINVAL;
    var v = a[0];
    insertAt(media[0].attributes, idx, &v);
    return OK;
}

pub export fn gst_sdp_media_replace_attribute(media: [*c]Media, idx: c.guint, a: [*c]Attr) Result {
    const f = "gst_sdp_media_replace_attribute";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(a != null, f, "attr != NULL")) return EINVAL;
    if (!that(idx < media[0].attributes[0].len, f, "idx < media->attributes->len")) return EINVAL;
    const v = at(Attr, media[0].attributes, idx);
    _ = gst_sdp_attribute_clear(v);
    v.* = a[0];
    return OK;
}

pub export fn gst_sdp_media_remove_attribute(media: [*c]Media, idx: c.guint) Result {
    const f = "gst_sdp_media_remove_attribute";
    if (!that(media != null, f, "media != NULL")) return EINVAL;
    if (!that(idx < media[0].attributes[0].len, f, "idx < media->attributes->len")) return EINVAL;
    _ = gst_sdp_attribute_clear(at(Attr, media[0].attributes, idx));
    _ = c.g_array_remove_index(media[0].attributes, idx);
    return OK;
}

fn isSpace(ch: u8) bool {
    return c.g_ascii_isspace(@as(c.gchar, @bitCast(ch)));
}

fn readString(dest: []u8, src: *[*c]u8) void {
    var idx: usize = 0;
    while (isSpace(src.*[0])) src.* += 1;
    while (!isSpace(src.*[0]) and src.*[0] != 0) {
        if (idx < dest.len - 1) {
            dest[idx] = src.*[0];
            idx += 1;
        }
        src.* += 1;
    }
    dest[idx] = 0;
}

fn readStringDel(dest: []u8, del: u8, src: *[*c]u8) void {
    var idx: usize = 0;
    while (isSpace(src.*[0])) src.* += 1;
    while (src.*[0] != del and src.*[0] != 0) {
        if (idx < dest.len - 1) {
            dest[idx] = src.*[0];
            idx += 1;
        }
        src.* += 1;
    }
    dest[idx] = 0;
}

const Ctx = struct {
    media_state: bool,
    msg: [*c]Msg,
    media: [*c]Media,
};

fn parseLine(ctx: *Ctx, kind: u8, buffer: [*c]u8) void {
    var str: [8192]u8 = undefined;
    var p = buffer;
    switch (kind) {
        'v' => _ = gst_sdp_message_set_version(ctx.msg, buffer),
        'o' => {
            const o = &ctx.msg[0].origin;
            for ([_][*c]Str{ &o.username, &o.sess_id, &o.sess_version, &o.nettype, &o.addrtype, &o.addr }) |f| {
                readString(&str, &p);
                replace(f, &str);
            }
        },
        's' => replace(&ctx.msg[0].session_name, buffer),
        'i' => if (!ctx.media_state) replace(&ctx.msg[0].information, buffer) else replace(&ctx.media[0].information, buffer),
        'u' => replace(&ctx.msg[0].uri, buffer),
        'e' => _ = gst_sdp_message_add_email(ctx.msg, buffer),
        'p' => _ = gst_sdp_message_add_phone(ctx.msg, buffer),
        'c' => {
            var conn = std.mem.zeroes(Conn);
            var s2 = p;
            while (true) {
                s2 = c.strchr(s2, '/');
                if (s2 == null) break;
                s2[0] = ' ';
                s2 += 1;
            }
            readString(&str, &p);
            replace(&conn.nettype, &str);
            readString(&str, &p);
            replace(&conn.addrtype, &str);
            readString(&str, &p);
            replace(&conn.address, &str);
            if (c.strcmp(conn.addrtype, "IP4") == 0) {
                readString(&str, &p);
                conn.ttl = @truncate(c.strtoul(&str, null, 10));
            }
            readString(&str, &p);
            conn.addr_number = @truncate(c.strtoul(&str, null, 10));
            if (!ctx.media_state) {
                _ = gst_sdp_message_set_connection(ctx.msg, conn.nettype, conn.addrtype, conn.address, conn.ttl, conn.addr_number);
            } else _ = gst_sdp_media_add_connection(ctx.media, conn.nettype, conn.addrtype, conn.address, conn.ttl, conn.addr_number);
            _ = gst_sdp_connection_clear(&conn);
        },
        'b' => {
            var str2: [32]u8 = undefined;
            readStringDel(&str, ':', &p);
            if (p[0] != 0) p += 1;
            readString(&str2, &p);
            const v: c.guint = @bitCast(c.atoi(&str2));
            if (!ctx.media_state) {
                _ = gst_sdp_message_add_bandwidth(ctx.msg, &str, v);
            } else _ = gst_sdp_media_add_bandwidth(ctx.media, &str, v);
        },
        't' => {},
        'k' => {
            readStringDel(&str, ':', &p);
            if (p[0] != 0) p += 1;
            if (!ctx.media_state) {
                _ = gst_sdp_message_set_key(ctx.msg, &str, p);
            } else _ = gst_sdp_media_set_key(ctx.media, &str, p);
        },
        'a' => {
            readStringDel(&str, ':', &p);
            if (p[0] != 0) p += 1;
            if (!ctx.media_state) {
                _ = gst_sdp_message_add_attribute(ctx.msg, &str, p);
            } else _ = gst_sdp_media_add_attribute(ctx.media, &str, p);
        },
        'm' => {
            ctx.media_state = true;
            var nm = std.mem.zeroes(Media);
            _ = gst_sdp_media_init(&nm);
            readString(&str, &p);
            replace(&nm.media, &str);
            readString(&str, &p);
            const slash = c.g_strrstr(&str, "/");
            if (slash != null) {
                slash[0] = 0;
                nm.port = @bitCast(c.atoi(&str));
                nm.num_ports = @bitCast(c.atoi(slash + 1));
            } else {
                nm.port = @bitCast(c.atoi(&str));
                nm.num_ports = 0;
            }
            readString(&str, &p);
            replace(&nm.proto, &str);
            while (true) {
                readString(&str, &p);
                _ = gst_sdp_media_add_format(&nm, &str);
                if (p[0] == 0) break;
            }
            _ = gst_sdp_message_add_media(ctx.msg, &nm);
            ctx.media = at(Media, ctx.msg[0].medias, ctx.msg[0].medias[0].len - 1);
        },
        else => {},
    }
}

pub export fn gst_sdp_message_parse_buffer(data: [*c]const u8, size: c.guint, msg: [*c]Msg) Result {
    const f = "gst_sdp_message_parse_buffer";
    if (!that(msg != null, f, "msg != NULL")) return EINVAL;
    if (!that(data != null, f, "data != NULL")) return EINVAL;
    if (!that(size != 0, f, "size != 0")) return EINVAL;
    var ctx = Ctx{ .media_state = false, .msg = msg, .media = null };
    var buffer: [*c]u8 = null;
    var bufsize: c.guint = 0;
    var p: usize = 0;
    const d = data;
    outer: while (true) {
        while (p < size and isSpace(d[p])) p += 1;
        if (p >= size) break;
        const kind = d[p];
        p += 1;
        if (kind == 0) break;
        if (p >= size) break;
        if (d[p] == '=') {
            p += 1;
            if (p >= size) break;
            const s = p;
            while (p < size and d[p] != '\n' and d[p] != '\r' and d[p] != 0) p += 1;
            const len: c.guint = @intCast(p - s);
            if (bufsize <= len) {
                buffer = @ptrCast(c.g_realloc(buffer, len + 1));
                bufsize = len + 1;
            }
            @memcpy(buffer[0..len], d[s..][0..len]);
            buffer[len] = 0;
            parseLine(&ctx, kind, buffer);
            if (p >= size) break :outer;
        }
        while (p < size and d[p] != '\n' and d[p] != 0) p += 1;
        if (p >= size) break;
        if (d[p] == '\n') p += 1;
    }
    c.g_free(buffer);
    return OK;
}

fn printMedia(media: [*c]Media) void {
    c.g_print("   media:       '%s'\n", strNull(media[0].media));
    c.g_print("   port:        '%u'\n", media[0].port);
    c.g_print("   num_ports:   '%u'\n", media[0].num_ports);
    c.g_print("   proto:       '%s'\n", strNull(media[0].proto));
    var i: c.guint = 0;
    if (media[0].fmts[0].len > 0) {
        c.g_print("   formats:\n");
        while (i < media[0].fmts[0].len) : (i += 1) c.g_print("    format  '%s'\n", at(Str, media[0].fmts, i).*);
    }
    c.g_print("   information: '%s'\n", strNull(media[0].information));
    if (media[0].connections[0].len > 0) {
        c.g_print("   connections:\n");
        i = 0;
        while (i < media[0].connections[0].len) : (i += 1) {
            const k = at(Conn, media[0].connections, i);
            c.g_print("    nettype:      '%s'\n", strNull(k.nettype));
            c.g_print("    addrtype:     '%s'\n", strNull(k.addrtype));
            c.g_print("    address:      '%s'\n", strNull(k.address));
            c.g_print("    ttl:          '%u'\n", k.ttl);
            c.g_print("    addr_number:  '%u'\n", k.addr_number);
        }
    }
    if (media[0].bandwidths[0].len > 0) {
        c.g_print("   bandwidths:\n");
        i = 0;
        while (i < media[0].bandwidths[0].len) : (i += 1) {
            const b = at(Bw, media[0].bandwidths, i);
            c.g_print("    type:         '%s'\n", strNull(b.bwtype));
            c.g_print("    bandwidth:    '%u'\n", b.bandwidth);
        }
    }
    c.g_print("   key:\n");
    c.g_print("    type:       '%s'\n", strNull(media[0].key.type));
    c.g_print("    data:       '%s'\n", strNull(media[0].key.data));
    if (media[0].attributes[0].len > 0) {
        c.g_print("   attributes:\n");
        i = 0;
        while (i < media[0].attributes[0].len) : (i += 1) {
            const a = at(Attr, media[0].attributes, i);
            c.g_print("    attribute '%s' : '%s'\n", a.key, a.value);
        }
    }
}

fn strNull(s: CStr) CStr {
    return if (s != null) s else "(NULL)";
}

pub export fn gst_sdp_message_dump(msg: [*c]const Msg) Result {
    if (!that(msg != null, "gst_sdp_message_dump", "msg != NULL")) return EINVAL;
    const m = &msg[0];
    c.g_print("sdp packet %p:\n", msg);
    c.g_print(" version:       '%s'\n", strNull(m.version));
    c.g_print(" origin:\n");
    c.g_print("  username:     '%s'\n", strNull(m.origin.username));
    c.g_print("  sess_id:      '%s'\n", strNull(m.origin.sess_id));
    c.g_print("  sess_version: '%s'\n", strNull(m.origin.sess_version));
    c.g_print("  nettype:      '%s'\n", strNull(m.origin.nettype));
    c.g_print("  addrtype:     '%s'\n", strNull(m.origin.addrtype));
    c.g_print("  addr:         '%s'\n", strNull(m.origin.addr));
    c.g_print(" session_name:  '%s'\n", strNull(m.session_name));
    c.g_print(" information:   '%s'\n", strNull(m.information));
    c.g_print(" uri:           '%s'\n", strNull(m.uri));
    var i: c.guint = 0;
    if (m.emails[0].len > 0) {
        c.g_print(" emails:\n");
        while (i < m.emails[0].len) : (i += 1) c.g_print("  email '%s'\n", at(Str, m.emails, i).*);
    }
    if (m.phones[0].len > 0) {
        c.g_print(" phones:\n");
        i = 0;
        while (i < m.phones[0].len) : (i += 1) c.g_print("  phone '%s'\n", at(Str, m.phones, i).*);
    }
    c.g_print(" connection:\n");
    c.g_print("  nettype:      '%s'\n", strNull(m.connection.nettype));
    c.g_print("  addrtype:     '%s'\n", strNull(m.connection.addrtype));
    c.g_print("  address:      '%s'\n", strNull(m.connection.address));
    c.g_print("  ttl:          '%u'\n", m.connection.ttl);
    c.g_print("  addr_number:  '%u'\n", m.connection.addr_number);
    if (m.bandwidths[0].len > 0) {
        c.g_print(" bandwidths:\n");
        i = 0;
        while (i < m.bandwidths[0].len) : (i += 1) {
            const b = at(Bw, m.bandwidths, i);
            c.g_print("  type:         '%s'\n", strNull(b.bwtype));
            c.g_print("  bandwidth:    '%u'\n", b.bandwidth);
        }
    }
    c.g_print(" key:\n");
    c.g_print("  type:         '%s'\n", strNull(m.key.type));
    c.g_print("  data:         '%s'\n", strNull(m.key.data));
    if (m.attributes[0].len > 0) {
        c.g_print(" attributes:\n");
        i = 0;
        while (i < m.attributes[0].len) : (i += 1) {
            const a = at(Attr, m.attributes, i);
            c.g_print("  attribute '%s' : '%s'\n", a.key, a.value);
        }
    }
    if (m.medias[0].len > 0) {
        c.g_print(" medias:\n");
        i = 0;
        while (i < m.medias[0].len) : (i += 1) {
            c.g_print("  media %u:\n", i);
            printMedia(at(Media, m.medias, i));
        }
    }
    return OK;
}
