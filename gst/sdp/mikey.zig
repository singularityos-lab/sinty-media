const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const that = @import("message.zig").that;

comptime {
    @import("../abi.zig").check(@This());
}

const N: ?*anyopaque = null;
const Payload = c.GstMIKEYPayload;
const Msg = c.GstMIKEYMessage;
const KEMAC = c.GstMIKEYPayloadKEMAC;
const PT = c.GstMIKEYPayloadT;
const PKE = c.GstMIKEYPayloadPKE;
const SP = c.GstMIKEYPayloadSP;
const Param = c.GstMIKEYPayloadSPParam;
const RAND = c.GstMIKEYPayloadRAND;
const KeyData = c.GstMIKEYPayloadKeyData;
const Map = c.GstMIKEYMapSRTP;
const BAD: c.guint = std.math.maxInt(c.guint);

var payload_once: gtype.Once = .{};
var message_once: gtype.Once = .{};

fn miniRef(p: c.gpointer) callconv(.c) c.gpointer {
    return c.gst_mini_object_ref(@ptrCast(@alignCast(p)));
}

fn miniUnref(p: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

pub export fn gst_mikey_payload_get_type() c.GType {
    return payload_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstMIKEYPayload", miniRef, miniUnref);
        }
    }.f);
}

pub export fn gst_mikey_message_get_type() c.GType {
    return message_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstMIKEYMessage", miniRef, miniUnref);
        }
    }.f);
}

fn unrefPayload(p: [*c]Payload) void {
    c.gst_mini_object_unref(@ptrCast(p));
}

fn copyPayload(p: [*c]const Payload) [*c]Payload {
    return @ptrCast(@alignCast(c.gst_mini_object_copy(@ptrCast(p))));
}

fn destroyPayload(p: c.gpointer) callconv(.c) void {
    unrefPayload(@as(*[*c]Payload, @ptrCast(@alignCast(p))).*);
}

fn initArray(comptime T: type, field: [*c][*c]c.GArray, clearFn: c.GDestroyNotify) void {
    if (field.* != null) {
        _ = c.g_array_set_size(field.*, 0);
    } else {
        field.* = c.g_array_new(0, 1, @sizeOf(T));
        c.g_array_set_clear_func(field.*, clearFn);
    }
}

fn freeArray(field: [*c][*c]c.GArray) void {
    if (field.* != null) _ = c.g_array_free(field.*, 1);
    field.* = null;
}

fn memdup(field: [*c][*c]u8, data: ?*const anyopaque, len: usize) void {
    c.g_free(field.*);
    field.* = @ptrCast(c.g_memdup2(data, len));
}

fn freeDup(field: [*c][*c]u8) void {
    c.g_free(field.*);
    field.* = null;
}

fn at(comptime T: type, a: [*c]c.GArray, i: c.guint) *T {
    return @ptrCast(@alignCast(a[0].data + @as(usize, i) * @sizeOf(T)));
}

fn macLen(alg: c.GstMIKEYMacAlg) c.guint {
    return switch (alg) {
        c.GST_MIKEY_MAC_NULL => 0,
        c.GST_MIKEY_MAC_HMAC_SHA_1_160 => 20,
        else => BAD,
    };
}

fn tsLen(t: c.GstMIKEYTSType) c.guint {
    return switch (t) {
        c.GST_MIKEY_TS_TYPE_NTP_UTC, c.GST_MIKEY_TS_TYPE_NTP => 8,
        c.GST_MIKEY_TS_TYPE_COUNTER => 4,
        else => BAD,
    };
}

fn check(comptime f: []const u8, p: [*c]const Payload, comptime t: c_int, comptime texpr: []const u8) bool {
    if (!that(p != null, f, "payload != NULL")) return false;
    return that(p[0].type == t, f, "payload->type == " ++ texpr);
}

pub export fn gst_mikey_payload_kemac_set(payload: [*c]Payload, enc: c.GstMIKEYEncAlg, mac: c.GstMIKEYMacAlg) c.gboolean {
    if (!check("gst_mikey_payload_kemac_set", payload, c.GST_MIKEY_PT_KEMAC, "GST_MIKEY_PT_KEMAC")) return 0;
    const p: *KEMAC = @ptrCast(@alignCast(payload));
    p.enc_alg = enc;
    p.mac_alg = mac;
    initArray([*c]Payload, &p.subpayloads, destroyPayload);
    return 1;
}

fn kemacDispose(o: [*c]c.GstMiniObject) callconv(.c) c.gboolean {
    freeArray(&@as(*KEMAC, @ptrCast(@alignCast(o))).subpayloads);
    return 1;
}

fn kemacCopy(o: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    const src: *const KEMAC = @ptrCast(@alignCast(o));
    const cp: *KEMAC = @ptrCast(@alignCast(c.g_memdup2(src, @sizeOf(KEMAC))));
    cp.subpayloads = null;
    _ = gst_mikey_payload_kemac_set(&cp.pt, src.enc_alg, src.mac_alg);
    var i: c.guint = 0;
    while (i < src.subpayloads[0].len) : (i += 1) _ = gst_mikey_payload_kemac_add_sub(&cp.pt, copyPayload(at([*c]Payload, src.subpayloads, i).*));
    return @ptrCast(cp);
}

pub export fn gst_mikey_payload_kemac_get_n_sub(payload: [*c]const Payload) c.guint {
    if (!check("gst_mikey_payload_kemac_get_n_sub", payload, c.GST_MIKEY_PT_KEMAC, "GST_MIKEY_PT_KEMAC")) return 0;
    return @as(*const KEMAC, @ptrCast(@alignCast(payload))).subpayloads[0].len;
}

pub export fn gst_mikey_payload_kemac_get_sub(payload: [*c]const Payload, idx: c.guint) [*c]const Payload {
    if (!check("gst_mikey_payload_kemac_get_sub", payload, c.GST_MIKEY_PT_KEMAC, "GST_MIKEY_PT_KEMAC")) return null;
    const p: *const KEMAC = @ptrCast(@alignCast(payload));
    if (p.subpayloads[0].len <= idx) return null;
    return at([*c]Payload, p.subpayloads, idx).*;
}

pub export fn gst_mikey_payload_kemac_remove_sub(payload: [*c]Payload, idx: c.guint) c.gboolean {
    const f = "gst_mikey_payload_kemac_remove_sub";
    if (!check(f, payload, c.GST_MIKEY_PT_KEMAC, "GST_MIKEY_PT_KEMAC")) return 0;
    const p: *KEMAC = @ptrCast(@alignCast(payload));
    if (!that(p.subpayloads[0].len > idx, f, "p->subpayloads->len > idx")) return 0;
    _ = c.g_array_remove_index(p.subpayloads, idx);
    return 1;
}

pub export fn gst_mikey_payload_kemac_add_sub(payload: [*c]Payload, newpay: [*c]Payload) c.gboolean {
    if (!check("gst_mikey_payload_kemac_add_sub", payload, c.GST_MIKEY_PT_KEMAC, "GST_MIKEY_PT_KEMAC")) return 0;
    var np = newpay;
    _ = c.g_array_append_vals(@as(*KEMAC, @ptrCast(@alignCast(payload))).subpayloads, @ptrCast(&np), 1);
    return 1;
}

pub export fn gst_mikey_payload_pke_set(payload: [*c]Payload, C: c.GstMIKEYCacheType, len: c.guint16, data: [*c]const u8) c.gboolean {
    if (!check("gst_mikey_payload_pke_set", payload, c.GST_MIKEY_PT_PKE, "GST_MIKEY_PT_PKE")) return 0;
    const p: *PKE = @ptrCast(@alignCast(payload));
    p.C = C;
    p.data_len = len;
    memdup(&p.data, data, len);
    return 1;
}

fn pkeDispose(o: [*c]c.GstMiniObject) callconv(.c) c.gboolean {
    freeDup(&@as(*PKE, @ptrCast(@alignCast(o))).data);
    return 1;
}

fn pkeCopy(o: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    const src: *const PKE = @ptrCast(@alignCast(o));
    const cp: *PKE = @ptrCast(@alignCast(c.g_memdup2(src, @sizeOf(PKE))));
    cp.data = null;
    _ = gst_mikey_payload_pke_set(&cp.pt, src.C, src.data_len, src.data);
    return @ptrCast(cp);
}

pub export fn gst_mikey_payload_t_set(payload: [*c]Payload, t: c.GstMIKEYTSType, ts: [*c]const u8) c.gboolean {
    if (!check("gst_mikey_payload_t_set", payload, c.GST_MIKEY_PT_T, "GST_MIKEY_PT_T")) return 0;
    const len = tsLen(t);
    if (len == BAD) return 0;
    const p: *PT = @ptrCast(@alignCast(payload));
    p.type = t;
    memdup(&p.ts_value, ts, len);
    return 1;
}

fn tDispose(o: [*c]c.GstMiniObject) callconv(.c) c.gboolean {
    freeDup(&@as(*PT, @ptrCast(@alignCast(o))).ts_value);
    return 1;
}

fn tCopy(o: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    const src: *const PT = @ptrCast(@alignCast(o));
    const cp: *PT = @ptrCast(@alignCast(c.g_memdup2(src, @sizeOf(PT))));
    cp.ts_value = null;
    _ = gst_mikey_payload_t_set(&cp.pt, src.type, src.ts_value);
    return @ptrCast(cp);
}

fn paramClear(p: c.gpointer) callconv(.c) void {
    freeDup(&@as(*Param, @ptrCast(@alignCast(p))).val);
}

pub export fn gst_mikey_payload_sp_set(payload: [*c]Payload, policy: c.guint, proto: c.GstMIKEYSecProto) c.gboolean {
    if (!check("gst_mikey_payload_sp_set", payload, c.GST_MIKEY_PT_SP, "GST_MIKEY_PT_SP")) return 0;
    const p: *SP = @ptrCast(@alignCast(payload));
    p.policy = policy;
    p.proto = proto;
    initArray(Param, &p.params, paramClear);
    return 1;
}

fn spDispose(o: [*c]c.GstMiniObject) callconv(.c) c.gboolean {
    freeArray(&@as(*SP, @ptrCast(@alignCast(o))).params);
    return 1;
}

fn spCopy(o: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    const src: *const SP = @ptrCast(@alignCast(o));
    const cp: *SP = @ptrCast(@alignCast(c.g_memdup2(src, @sizeOf(SP))));
    cp.params = null;
    _ = gst_mikey_payload_sp_set(&cp.pt, src.policy, src.proto);
    var i: c.guint = 0;
    while (i < src.params[0].len) : (i += 1) {
        const prm = at(Param, src.params, i);
        _ = gst_mikey_payload_sp_add_param(&cp.pt, prm.type, prm.len, prm.val);
    }
    return @ptrCast(cp);
}

pub export fn gst_mikey_payload_sp_get_n_params(payload: [*c]const Payload) c.guint {
    if (!check("gst_mikey_payload_sp_get_n_params", payload, c.GST_MIKEY_PT_SP, "GST_MIKEY_PT_SP")) return 0;
    return @as(*const SP, @ptrCast(@alignCast(payload))).params[0].len;
}

pub export fn gst_mikey_payload_sp_get_param(payload: [*c]const Payload, idx: c.guint) [*c]const Param {
    if (!check("gst_mikey_payload_sp_get_param", payload, c.GST_MIKEY_PT_SP, "GST_MIKEY_PT_SP")) return null;
    const p: *const SP = @ptrCast(@alignCast(payload));
    if (p.params[0].len <= idx) return null;
    return at(Param, p.params, idx);
}

pub export fn gst_mikey_payload_sp_remove_param(payload: [*c]Payload, idx: c.guint) c.gboolean {
    const f = "gst_mikey_payload_sp_remove_param";
    if (!check(f, payload, c.GST_MIKEY_PT_SP, "GST_MIKEY_PT_SP")) return 0;
    const p: *SP = @ptrCast(@alignCast(payload));
    if (!that(p.params[0].len > idx, f, "p->params->len > idx")) return 0;
    _ = c.g_array_remove_index(p.params, idx);
    return 1;
}

pub export fn gst_mikey_payload_sp_add_param(payload: [*c]Payload, t: u8, len: u8, val: [*c]const u8) c.gboolean {
    if (!check("gst_mikey_payload_sp_add_param", payload, c.GST_MIKEY_PT_SP, "GST_MIKEY_PT_SP")) return 0;
    var prm = std.mem.zeroes(Param);
    prm.type = t;
    prm.len = len;
    memdup(&prm.val, val, len);
    _ = c.g_array_append_vals(@as(*SP, @ptrCast(@alignCast(payload))).params, &prm, 1);
    return 1;
}

pub export fn gst_mikey_payload_rand_set(payload: [*c]Payload, len: u8, rand: [*c]const u8) c.gboolean {
    if (!check("gst_mikey_payload_rand_set", payload, c.GST_MIKEY_PT_RAND, "GST_MIKEY_PT_RAND")) return 0;
    const p: *RAND = @ptrCast(@alignCast(payload));
    p.len = len;
    memdup(&p.rand, rand, len);
    return 1;
}

fn randDispose(o: [*c]c.GstMiniObject) callconv(.c) c.gboolean {
    freeDup(&@as(*RAND, @ptrCast(@alignCast(o))).rand);
    return 1;
}

fn randCopy(o: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    const src: *const RAND = @ptrCast(@alignCast(o));
    const cp: *RAND = @ptrCast(@alignCast(c.g_memdup2(src, @sizeOf(RAND))));
    cp.rand = null;
    _ = gst_mikey_payload_rand_set(&cp.pt, src.len, src.rand);
    return @ptrCast(cp);
}

pub export fn gst_mikey_payload_key_data_set_key(payload: [*c]Payload, kt: c.GstMIKEYKeyDataType, len: c.guint16, data: [*c]const u8) c.gboolean {
    const f = "gst_mikey_payload_key_data_set_key";
    if (!check(f, payload, c.GST_MIKEY_PT_KEY_DATA, "GST_MIKEY_PT_KEY_DATA")) return 0;
    if (!that(len > 0 and data != null, f, "key_len > 0 && key_data != NULL")) return 0;
    const p: *KeyData = @ptrCast(@alignCast(payload));
    p.key_type = kt;
    p.key_len = len;
    memdup(&p.key_data, data, len);
    return 1;
}

pub export fn gst_mikey_payload_key_data_set_salt(payload: [*c]Payload, len: c.guint16, data: [*c]const u8) c.gboolean {
    const f = "gst_mikey_payload_key_data_set_salt";
    if (!check(f, payload, c.GST_MIKEY_PT_KEY_DATA, "GST_MIKEY_PT_KEY_DATA")) return 0;
    if (!that((len == 0 and data == null) or (len > 0 and data != null), f, "(salt_len == 0 && salt_data == NULL) || (salt_len > 0 && salt_data != NULL)")) return 0;
    const p: *KeyData = @ptrCast(@alignCast(payload));
    p.salt_len = len;
    memdup(&p.salt_data, data, len);
    return 1;
}

pub export fn gst_mikey_payload_key_data_set_spi(payload: [*c]Payload, len: u8, data: [*c]const u8) c.gboolean {
    const f = "gst_mikey_payload_key_data_set_spi";
    if (!check(f, payload, c.GST_MIKEY_PT_KEY_DATA, "GST_MIKEY_PT_KEY_DATA")) return 0;
    if (!that((len == 0 and data == null) or (len > 0 and data != null), f, "(spi_len == 0 && spi_data == NULL) || (spi_len > 0 && spi_data != NULL)")) return 0;
    const p: *KeyData = @ptrCast(@alignCast(payload));
    p.kv_type = c.GST_MIKEY_KV_SPI;
    p.kv_len[0] = len;
    memdup(&p.kv_data[0], data, len);
    p.kv_len[1] = 0;
    freeDup(&p.kv_data[1]);
    return 1;
}

pub export fn gst_mikey_payload_key_data_set_interval(payload: [*c]Payload, vf_len: u8, vf: [*c]const u8, vt_len: u8, vt: [*c]const u8) c.gboolean {
    const f = "gst_mikey_payload_key_data_set_interval";
    if (!check(f, payload, c.GST_MIKEY_PT_KEY_DATA, "GST_MIKEY_PT_KEY_DATA")) return 0;
    if (!that((vf_len == 0 and vf == null) or (vf_len > 0 and vf != null), f, "(vf_len == 0 && vf_data == NULL) || (vf_len > 0 && vf_data != NULL)")) return 0;
    if (!that((vt_len == 0 and vt == null) or (vt_len > 0 and vt != null), f, "(vt_len == 0 && vt_data == NULL) || (vt_len > 0 && vt_data != NULL)")) return 0;
    const p: *KeyData = @ptrCast(@alignCast(payload));
    p.kv_type = c.GST_MIKEY_KV_INTERVAL;
    p.kv_len[0] = vf_len;
    memdup(&p.kv_data[0], vf, vf_len);
    p.kv_len[1] = vt_len;
    memdup(&p.kv_data[1], vt, vt_len);
    return 1;
}

fn keyDispose(o: [*c]c.GstMiniObject) callconv(.c) c.gboolean {
    const p: *KeyData = @ptrCast(@alignCast(o));
    freeDup(&p.key_data);
    freeDup(&p.salt_data);
    freeDup(&p.kv_data[0]);
    freeDup(&p.kv_data[1]);
    return 1;
}

fn keyCopy(o: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    const src: *const KeyData = @ptrCast(@alignCast(o));
    const cp: *KeyData = @ptrCast(@alignCast(c.g_memdup2(src, @sizeOf(KeyData))));
    cp.key_data = null;
    cp.salt_data = null;
    cp.kv_data = .{ null, null };
    _ = gst_mikey_payload_key_data_set_key(&cp.pt, src.key_type, src.key_len, src.key_data);
    _ = gst_mikey_payload_key_data_set_salt(&cp.pt, src.salt_len, src.salt_data);
    if (src.kv_type == c.GST_MIKEY_KV_SPI) {
        _ = gst_mikey_payload_key_data_set_spi(&cp.pt, src.kv_len[0], src.kv_data[0]);
    } else if (src.kv_type == c.GST_MIKEY_KV_INTERVAL) {
        _ = gst_mikey_payload_key_data_set_interval(&cp.pt, src.kv_len[0], src.kv_data[0], src.kv_len[1], src.kv_data[1]);
    } else {
        freeDup(&cp.kv_data[0]);
        freeDup(&cp.kv_data[1]);
    }
    return @ptrCast(cp);
}

fn payloadFree(o: [*c]c.GstMiniObject) callconv(.c) void {
    c.g_free(o);
}

pub export fn gst_mikey_payload_new(t: c.GstMIKEYPayloadType) [*c]Payload {
    var len: usize = 0;
    var copy: c.GstMiniObjectCopyFunction = null;
    var dispose: c.GstMiniObjectDisposeFunction = null;
    switch (t) {
        c.GST_MIKEY_PT_KEMAC => {
            len = @sizeOf(KEMAC);
            dispose = kemacDispose;
            copy = kemacCopy;
        },
        c.GST_MIKEY_PT_T => {
            len = @sizeOf(PT);
            dispose = tDispose;
            copy = tCopy;
        },
        c.GST_MIKEY_PT_PKE => {
            len = @sizeOf(PKE);
            dispose = pkeDispose;
            copy = pkeCopy;
        },
        c.GST_MIKEY_PT_DH, c.GST_MIKEY_PT_SIGN, c.GST_MIKEY_PT_ID, c.GST_MIKEY_PT_CERT, c.GST_MIKEY_PT_CHASH, c.GST_MIKEY_PT_V, c.GST_MIKEY_PT_SP => {
            len = @sizeOf(SP);
            dispose = spDispose;
            copy = spCopy;
        },
        c.GST_MIKEY_PT_RAND => {
            len = @sizeOf(RAND);
            dispose = randDispose;
            copy = randCopy;
        },
        c.GST_MIKEY_PT_KEY_DATA => {
            len = @sizeOf(KeyData);
            dispose = keyDispose;
            copy = keyCopy;
        },
        else => {},
    }
    if (len == 0) return null;
    const r: [*c]Payload = @ptrCast(@alignCast(c.g_malloc0(len)));
    c.gst_mini_object_init(@ptrCast(r), 0, gst_mikey_payload_get_type(), copy, dispose, payloadFree);
    r[0].type = t;
    r[0].len = @intCast(len);
    return r;
}

fn messageCopy(o: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    const msg: [*c]const Msg = @ptrCast(@alignCast(o));
    const cp = gst_mikey_message_new();
    _ = gst_mikey_message_set_info(cp, msg[0].version, msg[0].type, msg[0].V, msg[0].prf_func, msg[0].CSB_id, msg[0].map_type);
    var i: c.guint = 0;
    while (i < msg[0].map_info[0].len) : (i += 1) {
        const s = gst_mikey_message_get_cs_srtp(msg, i);
        _ = gst_mikey_message_add_cs_srtp(cp, s[0].policy, s[0].ssrc, s[0].roc);
    }
    i = 0;
    while (i < msg[0].payloads[0].len) : (i += 1) _ = gst_mikey_message_add_payload(cp, copyPayload(gst_mikey_message_get_payload(msg, i)));
    return @ptrCast(cp);
}

fn messageFree(o: [*c]c.GstMiniObject) callconv(.c) void {
    const msg: [*c]Msg = @ptrCast(@alignCast(o));
    freeArray(&msg[0].map_info);
    freeArray(&msg[0].payloads);
    c.g_free(msg);
}

pub export fn gst_mikey_message_new() [*c]Msg {
    const r: [*c]Msg = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Msg))));
    c.gst_mini_object_init(@ptrCast(r), 0, gst_mikey_message_get_type(), messageCopy, null, messageFree);
    initArray(Map, &r[0].map_info, null);
    initArray([*c]Payload, &r[0].payloads, destroyPayload);
    return r;
}

pub export fn gst_mikey_message_new_from_bytes(bytes: ?*c.GBytes, info: ?*c.GstMIKEYDecryptInfo, err: [*c][*c]c.GError) [*c]Msg {
    if (!that(bytes != null, "gst_mikey_message_new_from_bytes", "bytes != NULL")) return null;
    var size: usize = 0;
    const d = c.g_bytes_get_data(bytes, &size);
    return gst_mikey_message_new_from_data(d, size, info, err);
}

pub export fn gst_mikey_message_set_info(msg: [*c]Msg, version: u8, t: c.GstMIKEYType, V: c.gboolean, prf: c.GstMIKEYPRFFunc, csb: c.guint32, map: c.GstMIKEYMapType) c.gboolean {
    if (!that(msg != null, "gst_mikey_message_set_info", "msg != NULL")) return 0;
    msg[0].version = version;
    msg[0].type = t;
    msg[0].V = V;
    msg[0].prf_func = prf;
    msg[0].CSB_id = csb;
    msg[0].map_type = map;
    return 1;
}

pub export fn gst_mikey_message_get_n_cs(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_mikey_message_get_n_cs", "msg != NULL")) return 0;
    return msg[0].map_info[0].len;
}

fn srtpCheck(comptime f: []const u8, msg: [*c]const Msg) bool {
    if (!that(msg != null, f, "msg != NULL")) return false;
    return that(msg[0].map_type == c.GST_MIKEY_MAP_TYPE_SRTP, f, "msg->map_type == GST_MIKEY_MAP_TYPE_SRTP");
}

pub export fn gst_mikey_message_get_cs_srtp(msg: [*c]const Msg, idx: c.guint) [*c]const Map {
    if (!srtpCheck("gst_mikey_message_get_cs_srtp", msg)) return null;
    if (msg[0].map_info[0].len <= idx) return null;
    return at(Map, msg[0].map_info, idx);
}

pub export fn gst_mikey_message_insert_cs_srtp(msg: [*c]Msg, idx: c.gint, map: [*c]const Map) c.gboolean {
    const f = "gst_mikey_message_insert_cs_srtp";
    if (!srtpCheck(f, msg)) return 0;
    if (!that(map != null, f, "map != NULL")) return 0;
    if (!that(idx == -1 or msg[0].map_info[0].len > idx, f, "idx == -1 || msg->map_info->len > idx")) return 0;
    if (idx == -1) {
        _ = c.g_array_append_vals(msg[0].map_info, map, 1);
    } else _ = c.g_array_insert_vals(msg[0].map_info, @bitCast(idx), map, 1);
    return 1;
}

pub export fn gst_mikey_message_replace_cs_srtp(msg: [*c]Msg, idx: c.gint, map: [*c]const Map) c.gboolean {
    const f = "gst_mikey_message_replace_cs_srtp";
    if (!srtpCheck(f, msg)) return 0;
    if (!that(map != null, f, "map != NULL")) return 0;
    if (!that(msg[0].map_info[0].len > idx, f, "msg->map_info->len > idx")) return 0;
    at(Map, msg[0].map_info, @bitCast(idx)).* = map[0];
    return 1;
}

pub export fn gst_mikey_message_remove_cs_srtp(msg: [*c]Msg, idx: c.gint) c.gboolean {
    const f = "gst_mikey_message_remove_cs_srtp";
    if (!srtpCheck(f, msg)) return 0;
    if (!that(msg[0].map_info[0].len > idx, f, "msg->map_info->len > idx")) return 0;
    _ = c.g_array_remove_index(msg[0].map_info, @bitCast(idx));
    return 1;
}

pub export fn gst_mikey_message_add_cs_srtp(msg: [*c]Msg, policy: u8, ssrc: c.guint32, roc: c.guint32) c.gboolean {
    if (!srtpCheck("gst_mikey_message_add_cs_srtp", msg)) return 0;
    var v = Map{ .policy = policy, .ssrc = ssrc, .roc = roc };
    return gst_mikey_message_insert_cs_srtp(msg, -1, &v);
}

pub export fn gst_mikey_message_get_n_payloads(msg: [*c]const Msg) c.guint {
    if (!that(msg != null, "gst_mikey_message_get_n_payloads", "msg != NULL")) return 0;
    return msg[0].payloads[0].len;
}

pub export fn gst_mikey_message_get_payload(msg: [*c]const Msg, idx: c.guint) [*c]const Payload {
    if (!that(msg != null, "gst_mikey_message_get_payload", "msg != NULL")) return null;
    if (idx >= msg[0].payloads[0].len) return null;
    return at([*c]Payload, msg[0].payloads, idx).*;
}

pub export fn gst_mikey_message_find_payload(msg: [*c]const Msg, t: c.GstMIKEYPayloadType, idx: c.guint) [*c]const Payload {
    var count: c.guint = 0;
    var i: c.guint = 0;
    while (i < msg[0].payloads[0].len) : (i += 1) {
        const p = at([*c]Payload, msg[0].payloads, i).*;
        if (p[0].type == t) {
            if (count == idx) return p;
            count += 1;
        }
    }
    return null;
}

pub export fn gst_mikey_message_remove_payload(msg: [*c]Msg, idx: c.guint) c.gboolean {
    const f = "gst_mikey_message_remove_payload";
    if (!that(msg != null, f, "msg != NULL")) return 0;
    if (!that(msg[0].payloads[0].len > idx, f, "msg->payloads->len > idx")) return 0;
    _ = c.g_array_remove_index(msg[0].payloads, idx);
    return 1;
}

pub export fn gst_mikey_message_insert_payload(msg: [*c]Msg, idx: c.guint, payload: [*c]Payload) c.gboolean {
    const f = "gst_mikey_message_insert_payload";
    if (!that(msg != null, f, "msg != NULL")) return 0;
    if (!that(payload != null, f, "payload != NULL")) return 0;
    const sidx: c.gint = @bitCast(idx);
    if (!that(sidx == -1 or msg[0].payloads[0].len > idx, f, "idx == -1 || msg->payloads->len > idx")) return 0;
    var p = payload;
    if (sidx == -1) {
        _ = c.g_array_append_vals(msg[0].payloads, @ptrCast(&p), 1);
    } else _ = c.g_array_insert_vals(msg[0].payloads, idx, @ptrCast(&p), 1);
    return 1;
}

pub export fn gst_mikey_message_add_payload(msg: [*c]Msg, payload: [*c]Payload) c.gboolean {
    return gst_mikey_message_insert_payload(msg, @bitCast(@as(c.gint, -1)), payload);
}

pub export fn gst_mikey_message_replace_payload(msg: [*c]Msg, idx: c.guint, payload: [*c]Payload) c.gboolean {
    const f = "gst_mikey_message_replace_payload";
    if (!that(msg != null, f, "msg != NULL")) return 0;
    if (!that(payload != null, f, "payload != NULL")) return 0;
    if (!that(msg[0].payloads[0].len > idx, f, "msg->payloads->len > idx")) return 0;
    const slot = at([*c]Payload, msg[0].payloads, idx);
    unrefPayload(slot.*);
    slot.* = payload;
    return 1;
}

pub export fn gst_mikey_message_add_pke(msg: [*c]Msg, C: c.GstMIKEYCacheType, len: c.guint16, data: [*c]const u8) c.gboolean {
    if (!that(msg != null, "gst_mikey_message_add_pke", "msg != NULL")) return 0;
    const p = gst_mikey_payload_new(c.GST_MIKEY_PT_PKE);
    if (gst_mikey_payload_pke_set(p, C, len, data) == 0) {
        unrefPayload(p);
        return 0;
    }
    return gst_mikey_message_add_payload(msg, p);
}

pub export fn gst_mikey_message_add_t(msg: [*c]Msg, t: c.GstMIKEYTSType, ts: [*c]const u8) c.gboolean {
    if (!that(msg != null, "gst_mikey_message_add_t", "msg != NULL")) return 0;
    const p = gst_mikey_payload_new(c.GST_MIKEY_PT_T);
    if (gst_mikey_payload_t_set(p, t, ts) == 0) {
        unrefPayload(p);
        return 0;
    }
    return gst_mikey_message_add_payload(msg, p);
}

pub export fn gst_mikey_message_add_t_now_ntp_utc(msg: [*c]Msg) c.gboolean {
    const now: u64 = @bitCast(c.g_get_real_time());
    var ntp = c.gst_util_uint64_scale(now, @as(u64, 1) << 32, 1000000);
    ntp +%= @as(u64, 2208988800) << 32;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, ntp, .big);
    return gst_mikey_message_add_t(msg, c.GST_MIKEY_TS_TYPE_NTP_UTC, &bytes);
}

pub export fn gst_mikey_message_add_rand(msg: [*c]Msg, len: u8, rand: [*c]const u8) c.gboolean {
    const f = "gst_mikey_message_add_rand";
    if (!that(msg != null, f, "msg != NULL")) return 0;
    if (!that(len != 0 and rand != null, f, "len != 0 && rand != NULL")) return 0;
    const p = gst_mikey_payload_new(c.GST_MIKEY_PT_RAND);
    if (gst_mikey_payload_rand_set(p, len, rand) == 0) {
        unrefPayload(p);
        return 0;
    }
    return gst_mikey_message_add_payload(msg, p);
}

pub export fn gst_mikey_message_add_rand_len(msg: [*c]Msg, len: u8) c.gboolean {
    const p: *RAND = @ptrCast(@alignCast(gst_mikey_payload_new(c.GST_MIKEY_PT_RAND)));
    p.len = len;
    p.rand = @ptrCast(c.g_malloc(len));
    var i: usize = 0;
    while (i < len) : (i += 1) p.rand[i] = @intCast(c.g_random_int_range(0, 256));
    return gst_mikey_message_add_payload(msg, &p.pt);
}

const Writer = struct {
    arr: [*c]c.GByteArray,
    data: [*c]u8,

    fn ensure(w: *Writer, n: usize) void {
        const off = @intFromPtr(w.data) - @intFromPtr(w.arr[0].data);
        _ = c.g_byte_array_set_size(w.arr, @intCast(off + n));
        w.data = w.arr[0].data + off;
    }
};

fn nextType(payloads: [*c]c.GArray, i: c.guint) u8 {
    if (i + 1 < payloads[0].len) return @intCast(at([*c]Payload, payloads, i + 1).*[0].type);
    return c.GST_MIKEY_PT_LAST;
}

fn be16(p: [*c]u8, v: c.guint16) void {
    std.mem.writeInt(u16, p[0..2], v, .big);
}

fn payloadsToBytes(payloads: [*c]c.GArray, arr: [*c]c.GByteArray, ptr: *[*c]u8, offset: c.guint) c.guint {
    const len = arr[0].len;
    const start = @intFromPtr(ptr.*) - @intFromPtr(arr[0].data);
    var w = Writer{ .arr = arr, .data = ptr.* + offset };
    var i: c.guint = 0;
    while (i < payloads[0].len) : (i += 1) {
        const payload = at([*c]Payload, payloads, i).*;
        const nt = nextType(payloads, i);
        switch (payload[0].type) {
            c.GST_MIKEY_PT_KEMAC => {
                const p: *KEMAC = @ptrCast(@alignCast(payload));
                const ml = macLen(p.mac_alg);
                if (ml == BAD) continue;
                w.ensure(4);
                w.data[0] = nt;
                w.data[1] = @intCast(p.enc_alg);
                const enc_len = payloadsToBytes(p.subpayloads, w.arr, &w.data, 4);
                be16(w.data + 2, @truncate(enc_len));
                w.data += enc_len;
                w.ensure(5 + ml);
                w.data[4] = @intCast(p.mac_alg);
                w.data += 5 + ml;
            },
            c.GST_MIKEY_PT_T => {
                const p: *PT = @ptrCast(@alignCast(payload));
                const tl = tsLen(p.type);
                if (tl == BAD) continue;
                w.ensure(2 + tl);
                w.data[0] = nt;
                w.data[1] = @intCast(p.type);
                @memcpy(w.data[2..][0..tl], p.ts_value[0..tl]);
                w.data += 2 + tl;
            },
            c.GST_MIKEY_PT_PKE => {
                const p: *PKE = @ptrCast(@alignCast(payload));
                w.ensure(3 + @as(usize, p.data_len));
                w.data[0] = nt;
                const clen: u16 = @intFromBool((@as(c_int, @intCast(p.C)) << 14) != 0 or (p.data_len & 0x3fff) != 0);
                be16(w.data + 1, clen);
                if (p.data_len > 0) @memcpy(w.data[3..][0..p.data_len], p.data[0..p.data_len]);
                w.data += 3 + @as(usize, p.data_len);
            },
            c.GST_MIKEY_PT_SP => {
                const p: *SP = @ptrCast(@alignCast(payload));
                var plen: c.guint = 0;
                var k: c.guint = 0;
                while (k < p.params[0].len) : (k += 1) plen += 2 + @as(c.guint, at(Param, p.params, k).len);
                w.ensure(5 + plen);
                w.data[0] = nt;
                w.data[1] = @truncate(p.policy);
                w.data[2] = @intCast(p.proto);
                be16(w.data + 3, @truncate(plen));
                w.data += 5;
                k = 0;
                while (k < p.params[0].len) : (k += 1) {
                    const prm = at(Param, p.params, k);
                    w.data[0] = prm.type;
                    w.data[1] = prm.len;
                    if (prm.len > 0) @memcpy(w.data[2..][0..prm.len], prm.val[0..prm.len]);
                    w.data += 2 + @as(usize, prm.len);
                }
            },
            c.GST_MIKEY_PT_RAND => {
                const p: *RAND = @ptrCast(@alignCast(payload));
                w.ensure(2 + @as(usize, p.len));
                w.data[0] = nt;
                w.data[1] = p.len;
                if (p.len > 0) @memcpy(w.data[2..][0..p.len], p.rand[0..p.len]);
                w.data += 2 + @as(usize, p.len);
            },
            c.GST_MIKEY_PT_KEY_DATA => {
                const p: *KeyData = @ptrCast(@alignCast(payload));
                w.ensure(4 + @as(usize, p.key_len));
                w.data[0] = nt;
                w.data[1] = @truncate(((@as(c.guint, @intCast(p.key_type)) | @as(c.guint, @intFromBool(p.salt_len != 0))) << 4) | (@as(c.guint, @intCast(p.kv_type)) & 0xf));
                be16(w.data + 2, p.key_len);
                if (p.key_len > 0) @memcpy(w.data[4..][0..p.key_len], p.key_data[0..p.key_len]);
                w.data += 4 + @as(usize, p.key_len);
                if (p.salt_len > 0) {
                    w.ensure(2 + @as(usize, p.salt_len));
                    be16(w.data, p.salt_len);
                    @memcpy(w.data[2..][0..p.salt_len], p.salt_data[0..p.salt_len]);
                    w.data += 2 + @as(usize, p.salt_len);
                }
                const nkv: usize = if (p.kv_type == c.GST_MIKEY_KV_SPI) 1 else if (p.kv_type == c.GST_MIKEY_KV_INTERVAL) 2 else 0;
                for (0..nkv) |k| {
                    const l = p.kv_len[k];
                    w.ensure(1 + @as(usize, l));
                    w.data[0] = l;
                    if (l > 0) @memcpy(w.data[1..][0..l], p.kv_data[k][0..l]);
                    w.data += 1 + @as(usize, l);
                }
            },
            else => {},
        }
    }
    ptr.* = arr[0].data + start;
    return arr[0].len - len;
}

pub export fn gst_mikey_message_to_bytes(msg: [*c]Msg, _: ?*c.GstMIKEYEncryptInfo, _: [*c][*c]c.GError) ?*c.GBytes {
    const arr = c.g_byte_array_new();
    var w = Writer{ .arr = arr, .data = arr[0].data };
    const nt: u8 = if (msg[0].payloads[0].len == 0) c.GST_MIKEY_PT_LAST else @intCast(at([*c]Payload, msg[0].payloads, 0).*[0].type);
    const n_cs = msg[0].map_info[0].len;
    w.ensure(10 + 9 * @as(usize, n_cs));
    w.data[0] = msg[0].version;
    w.data[1] = @intCast(msg[0].type);
    w.data[2] = nt;
    w.data[3] = (if (msg[0].V != 0) @as(u8, 0x80) else 0) | @as(u8, @intCast(msg[0].prf_func & 0x7f));
    std.mem.writeInt(u32, w.data[4..8], msg[0].CSB_id, .big);
    w.data[8] = @truncate(n_cs);
    w.data[9] = @intCast(msg[0].map_type);
    w.data += 10;
    var i: c.guint = 0;
    while (i < n_cs) : (i += 1) {
        const info = at(Map, msg[0].map_info, i);
        w.data[0] = info.policy;
        std.mem.writeInt(u32, w.data[1..5], info.ssrc, .big);
        std.mem.writeInt(u32, w.data[5..9], info.roc, .big);
        w.data += 9;
    }
    _ = payloadsToBytes(msg[0].payloads, w.arr, &w.data, 0);
    return c.g_byte_array_free_to_bytes(arr);
}

const PSK = 0;
const PK = 1;
const KEMAC_STATE = 2;
const OTHER = 3;

const Reader = struct {
    d: [*c]const u8,
    size: usize,

    fn has(r: *Reader, n: usize) bool {
        return r.size >= n;
    }

    fn advance(r: *Reader, n: usize) void {
        r.d += n;
        r.size -= n;
    }

    fn be16At(r: *Reader, off: usize) u16 {
        return std.mem.readInt(u16, r.d[off..][0..2], .big);
    }
};

fn payloadsFromBytes(state: c_int, payloads: [*c]c.GArray, data: [*c]const u8, size: usize, first: u8) bool {
    var r = Reader{ .d = data, .size = size };
    var next = first;
    while (next != c.GST_MIKEY_PT_LAST) {
        var p: [*c]Payload = null;
        const ok = blk: switch (next) {
            c.GST_MIKEY_PT_KEMAC => {
                if (!r.has(5)) break :blk false;
                next = r.d[0];
                const enc: c.GstMIKEYEncAlg = r.d[1];
                const enc_len = r.be16At(2);
                if (!r.has(5 + @as(usize, enc_len))) break :blk false;
                const enc_data = r.d + 4;
                r.advance(enc_len);
                const mac: c.GstMIKEYMacAlg = r.d[4];
                const ml = macLen(mac);
                if (ml == BAD) break :blk false;
                if (!r.has(5 + ml)) break :blk false;
                r.advance(5 + ml);
                p = gst_mikey_payload_new(c.GST_MIKEY_PT_KEMAC);
                _ = gst_mikey_payload_kemac_set(p, enc, mac);
                const np: u8 = if (state == PSK) c.GST_MIKEY_PT_KEY_DATA else if (state == PK) c.GST_MIKEY_PT_ID else break :blk false;
                _ = payloadsFromBytes(KEMAC_STATE, @as(*KEMAC, @ptrCast(@alignCast(p))).subpayloads, enc_data, enc_len, np);
                _ = c.g_array_append_vals(payloads, @ptrCast(&p), 1);
                break :blk true;
            },
            c.GST_MIKEY_PT_T => {
                if (!r.has(2)) break :blk false;
                next = r.d[0];
                const t: c.GstMIKEYTSType = r.d[1];
                const tl = tsLen(t);
                if (tl == BAD) break :blk false;
                if (!r.has(2 + tl)) break :blk false;
                const v = r.d + 2;
                r.advance(2 + tl);
                p = gst_mikey_payload_new(c.GST_MIKEY_PT_T);
                _ = gst_mikey_payload_t_set(p, t, v);
                _ = c.g_array_append_vals(payloads, @ptrCast(&p), 1);
                break :blk true;
            },
            c.GST_MIKEY_PT_PKE => {
                if (!r.has(3)) break :blk false;
                next = r.d[0];
                const clen = r.be16At(1);
                const dl = clen & 0x3fff;
                if (!r.has(3 + @as(usize, dl))) break :blk false;
                const v = r.d + 3;
                r.advance(3 + @as(usize, dl));
                p = gst_mikey_payload_new(c.GST_MIKEY_PT_PKE);
                _ = gst_mikey_payload_pke_set(p, clen >> 14, dl, v);
                _ = c.g_array_append_vals(payloads, @ptrCast(&p), 1);
                break :blk true;
            },
            c.GST_MIKEY_PT_DH => {
                if (!r.has(2)) break :blk false;
                next = r.d[0];
                const dl: usize = switch (r.d[1]) {
                    0 => 1536 / 8,
                    1 => 768 / 8,
                    2 => 1024 / 8,
                    else => break :blk false,
                };
                if (!r.has(2 + dl)) break :blk false;
                r.advance(2 + dl);
                if (!r.has(1)) break :blk false;
                const kv = r.d[0] & 0x0f;
                r.advance(1);
                switch (kv) {
                    c.GST_MIKEY_KV_NULL => {},
                    c.GST_MIKEY_KV_SPI => {
                        if (!r.has(1)) break :blk false;
                        const l: usize = r.d[0];
                        if (!r.has(1 + l)) break :blk false;
                        r.advance(1 + l);
                    },
                    c.GST_MIKEY_KV_INTERVAL => {
                        for (0..2) |_| {
                            if (!r.has(1)) break :blk false;
                            const l: usize = r.d[0];
                            if (!r.has(1 + l)) break :blk false;
                            r.advance(1 + l);
                        }
                    },
                    else => break :blk false,
                }
                break :blk true;
            },
            c.GST_MIKEY_PT_SIGN => {
                next = c.GST_MIKEY_PT_LAST;
                if (!r.has(2)) break :blk false;
                const sl: usize = r.be16At(0) & 0x0fff;
                if (!r.has(2 + sl)) break :blk false;
                r.advance(2 + sl);
                break :blk true;
            },
            c.GST_MIKEY_PT_ID, c.GST_MIKEY_PT_CERT => {
                if (!r.has(4)) break :blk false;
                next = r.d[0];
                const cl: usize = r.be16At(2);
                if (!r.has(4 + cl)) break :blk false;
                r.advance(4 + cl);
                break :blk true;
            },
            c.GST_MIKEY_PT_CHASH => {
                if (!r.has(2)) break :blk false;
                next = r.d[0];
                const hl: usize = switch (r.d[1]) {
                    0 => 160 / 8,
                    1 => 128 / 8,
                    else => break :blk false,
                };
                if (!r.has(2 + hl)) break :blk false;
                r.advance(2 + hl);
                break :blk true;
            },
            c.GST_MIKEY_PT_V => {
                if (!r.has(2)) break :blk false;
                next = r.d[0];
                const vl: usize = switch (r.d[1]) {
                    c.GST_MIKEY_MAC_NULL => 0,
                    c.GST_MIKEY_MAC_HMAC_SHA_1_160 => 160 / 8,
                    else => break :blk false,
                };
                if (!r.has(2 + vl)) break :blk false;
                r.advance(2 + vl);
                break :blk true;
            },
            c.GST_MIKEY_PT_SP => {
                if (!r.has(5)) break :blk false;
                next = r.d[0];
                const policy = r.d[1];
                const proto: c.GstMIKEYSecProto = r.d[2];
                var plen: u16 = r.be16At(3);
                r.advance(5);
                p = gst_mikey_payload_new(c.GST_MIKEY_PT_SP);
                _ = gst_mikey_payload_sp_set(p, policy, proto);
                if (!r.has(plen)) break :blk false;
                while (plen != 0) {
                    if (!r.has(2)) break :blk false;
                    const t = r.d[0];
                    const l = r.d[1];
                    if (!r.has(2 + @as(usize, l))) break :blk false;
                    _ = gst_mikey_payload_sp_add_param(p, t, l, r.d + 2);
                    r.advance(2 + @as(usize, l));
                    plen -%= 2 + @as(u16, l);
                }
                _ = c.g_array_append_vals(payloads, @ptrCast(&p), 1);
                break :blk true;
            },
            c.GST_MIKEY_PT_RAND => {
                if (!r.has(2)) break :blk false;
                next = r.d[0];
                const l = r.d[1];
                if (!r.has(2 + @as(usize, l))) break :blk false;
                const v = r.d + 2;
                r.advance(2 + @as(usize, l));
                p = gst_mikey_payload_new(c.GST_MIKEY_PT_RAND);
                _ = gst_mikey_payload_rand_set(p, l, v);
                _ = c.g_array_append_vals(payloads, @ptrCast(&p), 1);
                break :blk true;
            },
            c.GST_MIKEY_PT_ERR => {
                if (!r.has(4)) break :blk false;
                next = r.d[0];
                r.advance(4);
                break :blk true;
            },
            c.GST_MIKEY_PT_KEY_DATA => {
                if (!r.has(4)) break :blk false;
                next = r.d[0];
                const kt: c.GstMIKEYKeyDataType = r.d[1] >> 4;
                const kv: c.GstMIKEYKVType = r.d[1] & 0xf;
                const kl = r.be16At(2);
                if (!r.has(4 + @as(usize, kl))) break :blk false;
                const kd = r.d + 4;
                r.advance(4 + @as(usize, kl));
                var sl: u16 = 0;
                var sd: [*c]const u8 = null;
                if (kt & 1 != 0) {
                    if (!r.has(2)) break :blk false;
                    sl = r.be16At(0);
                    if (!r.has(2 + @as(usize, sl))) break :blk false;
                    sd = r.d + 2;
                    r.advance(2 + @as(usize, sl));
                }
                p = gst_mikey_payload_new(c.GST_MIKEY_PT_KEY_DATA);
                _ = gst_mikey_payload_key_data_set_key(p, kt & 2, kl, kd);
                if (sl > 0) _ = gst_mikey_payload_key_data_set_salt(p, sl, sd);
                if (kv == c.GST_MIKEY_KV_SPI) {
                    if (!r.has(1)) break :blk false;
                    const l = r.d[0];
                    if (!r.has(1 + @as(usize, l))) break :blk false;
                    const v = r.d + 1;
                    r.advance(1 + @as(usize, l));
                    _ = gst_mikey_payload_key_data_set_spi(p, l, v);
                } else if (kv == c.GST_MIKEY_KV_INTERVAL) {
                    if (!r.has(1)) break :blk false;
                    const fl = r.d[0];
                    if (!r.has(1 + @as(usize, fl))) break :blk false;
                    const fd = r.d + 1;
                    r.advance(1 + @as(usize, fl));
                    if (!r.has(1)) break :blk false;
                    const tl = r.d[0];
                    if (!r.has(1 + @as(usize, tl))) break :blk false;
                    const td = r.d + 1;
                    r.advance(1 + @as(usize, tl));
                    _ = gst_mikey_payload_key_data_set_interval(p, fl, fd, tl, td);
                } else if (kv != c.GST_MIKEY_KV_NULL) break :blk false;
                _ = c.g_array_append_vals(payloads, @ptrCast(&p), 1);
                break :blk true;
            },
            c.GST_MIKEY_PT_GEN_EXT => {
                if (!r.has(4)) break :blk false;
                next = r.d[0];
                const el: usize = r.be16At(2);
                if (!r.has(4 + el)) break :blk false;
                r.advance(4 + el);
                break :blk true;
            },
            else => false,
        };
        if (!ok) {
            if (p != null) unrefPayload(p);
            return false;
        }
    }
    return true;
}

pub export fn gst_mikey_message_new_from_data(data: ?*const anyopaque, size: c_ulong, _: ?*c.GstMIKEYDecryptInfo, _: [*c][*c]c.GError) [*c]Msg {
    if (!that(data != null, "gst_mikey_message_new_from_data", "data != NULL")) return null;
    const msg = gst_mikey_message_new();
    var r = Reader{ .d = @ptrCast(data), .size = size };
    blk: {
        if (!r.has(10)) break :blk;
        msg[0].version = r.d[0];
        if (msg[0].version != c.GST_MIKEY_VERSION) break :blk;
        msg[0].type = r.d[1];
        const next = r.d[2];
        msg[0].V = @intFromBool(r.d[3] & 0x80 != 0);
        msg[0].prf_func = r.d[3] & 0x7f;
        msg[0].CSB_id = std.mem.readInt(u32, r.d[4..8], .big);
        const n_cs: usize = r.d[8];
        msg[0].map_type = r.d[9];
        r.advance(10);
        if (!r.has(n_cs * 9)) break :blk;
        for (0..n_cs) |_| {
            var map = Map{ .policy = r.d[0], .ssrc = std.mem.readInt(u32, r.d[1..5], .big), .roc = std.mem.readInt(u32, r.d[5..9], .big) };
            _ = gst_mikey_message_insert_cs_srtp(msg, -1, &map);
            r.advance(9);
        }
        const state: c_int = if (msg[0].type == c.GST_MIKEY_TYPE_PSK_INIT) PSK else if (msg[0].type == c.GST_MIKEY_TYPE_PK_INIT) PK else OTHER;
        if (!payloadsFromBytes(state, msg[0].payloads, r.d, r.size, next)) break :blk;
        return msg;
    }
    c.gst_mini_object_unref(@ptrCast(msg));
    return null;
}

const AES_128 = 16;
const AES_256 = 32;
const HMAC_32 = 4;
const HMAC_80 = 10;

fn cipherIs(cipher: [*c]const u8, name: [*:0]const u8) bool {
    return c.g_strcmp0(cipher, name) == 0;
}

fn authAlg(cipher: [*c]const u8, out: *u8) bool {
    if (cipherIs(cipher, "aes-128-icm") or cipherIs(cipher, "aes-256-icm")) {
        out.* = c.GST_MIKEY_MAC_HMAC_SHA_1_160;
    } else if (cipherIs(cipher, "aes-128-gcm") or cipherIs(cipher, "aes-256-gcm")) {
        out.* = c.GST_MIKEY_MAC_NULL;
    } else return false;
    return true;
}

fn encAlg(cipher: [*c]const u8, out: *u8) bool {
    if (cipherIs(cipher, "aes-128-icm") or cipherIs(cipher, "aes-256-icm")) {
        out.* = c.GST_MIKEY_ENC_AES_CM_128;
    } else if (cipherIs(cipher, "aes-128-gcm") or cipherIs(cipher, "aes-256-gcm")) {
        out.* = c.GST_MIKEY_ENC_AES_GCM_128;
    } else return false;
    return true;
}

fn encKeyLen(cipher: [*c]const u8, out: *u8) bool {
    if (cipherIs(cipher, "aes-128-icm") or cipherIs(cipher, "aes-128-gcm")) {
        out.* = AES_128;
    } else if (cipherIs(cipher, "aes-256-icm") or cipherIs(cipher, "aes-256-gcm")) {
        out.* = AES_256;
    } else return false;
    return true;
}

fn authKeyLen(auth: [*c]const u8, cipher: [*c]const u8, out: *u8) bool {
    if (cipherIs(cipher, "aes-128-gcm") or cipherIs(cipher, "aes-256-gcm")) {
        out.* = 0;
    } else if (cipherIs(auth, "hmac-sha1-32")) {
        out.* = HMAC_32;
    } else if (cipherIs(auth, "hmac-sha1-80")) {
        out.* = HMAC_80;
    } else return false;
    return true;
}

fn isCaps(caps: anytype) bool {
    return caps != null and @as(*const c.GstMiniObject, @ptrCast(@alignCast(caps))).type == c.gst_caps_get_type();
}

fn isBuffer(b: anytype) bool {
    return b != null and @as(*const c.GstMiniObject, @ptrCast(@alignCast(b))).type == c.gst_buffer_get_type();
}

pub export fn gst_mikey_message_new_from_caps(caps: [*c]c.GstCaps) [*c]Msg {
    const f = "gst_mikey_message_new_from_caps";
    if (!that(isCaps(caps), f, "caps != NULL && GST_IS_CAPS (caps)")) return null;
    const s = c.gst_caps_get_structure(caps, 0);
    if (!that(s != null, f, "s != NULL")) return null;
    const val = c.gst_structure_get_value(s, "srtp-key");
    if (val == null) return null;
    const key = c.gst_value_get_buffer(val);
    if (!isBuffer(key)) return null;
    var cipher = c.gst_structure_get_string(s, "srtp-cipher");
    var auth = c.gst_structure_get_string(s, "srtp-auth");
    if (cipher == null) cipher = c.gst_structure_get_string(s, "srtcp-cipher");
    if (auth == null) auth = c.gst_structure_get_string(s, "srtcp-auth");
    var enc: u8 = 0;
    var aalg: u8 = 0;
    var ekl: u8 = 0;
    var akl: u8 = 0;
    if (cipher != null and (!encAlg(cipher, &enc) or !authAlg(cipher, &aalg) or !encKeyLen(cipher, &ekl) or (auth != null and !authKeyLen(auth, cipher, &akl)))) return null;
    const msg = gst_mikey_message_new();
    _ = gst_mikey_message_set_info(msg, c.GST_MIKEY_VERSION, c.GST_MIKEY_TYPE_PSK_INIT, 0, c.GST_MIKEY_PRF_MIKEY_1, c.g_random_int(), c.GST_MIKEY_MAP_TYPE_SRTP);
    if (cipher != null or auth != null) {
        _ = gst_mikey_message_add_t_now_ntp_utc(msg);
        _ = gst_mikey_message_add_rand_len(msg, 16);
        const sp = gst_mikey_payload_new(c.GST_MIKEY_PT_SP);
        _ = gst_mikey_payload_sp_set(sp, 0, c.GST_MIKEY_SEC_PROTO_SRTP);
        if (cipher != null) {
            _ = gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_ENC_ALG, 1, &enc);
            _ = gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_ENC_KEY_LEN, 1, &ekl);
        }
        if (auth != null) {
            _ = gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_AUTH_ALG, 1, &aalg);
            _ = gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_AUTH_KEY_LEN, 1, &akl);
        }
        var byte: u8 = 1;
        if (cipher != null) {
            _ = gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_SRTP_ENC, 1, &byte);
            _ = gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_SRTCP_ENC, 1, &byte);
        }
        if (auth != null) _ = gst_mikey_payload_sp_add_param(sp, c.GST_MIKEY_SP_SRTP_SRTP_AUTH, 1, &byte);
        _ = gst_mikey_message_add_payload(msg, sp);
    }
    const kemac = gst_mikey_payload_new(c.GST_MIKEY_PT_KEMAC);
    _ = gst_mikey_payload_kemac_set(kemac, c.GST_MIKEY_ENC_NULL, c.GST_MIKEY_MAC_NULL);
    const pkd = gst_mikey_payload_new(c.GST_MIKEY_PT_KEY_DATA);
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(key, &info, c.GST_MAP_READ);
    _ = gst_mikey_payload_key_data_set_key(pkd, c.GST_MIKEY_KD_TEK, @truncate(info.size), info.data);
    c.gst_buffer_unmap(key, &info);
    const mki_val = c.gst_structure_get_value(s, "mki");
    if (mki_val != null) {
        const mki = c.gst_value_get_buffer(mki_val);
        if (isBuffer(mki) and c.gst_buffer_get_size(mki) > 0) {
            _ = c.gst_buffer_map(mki, &info, c.GST_MAP_READ);
            _ = gst_mikey_payload_key_data_set_spi(pkd, @truncate(info.size), info.data);
            c.gst_buffer_unmap(mki, &info);
        }
    }
    _ = gst_mikey_payload_kemac_add_sub(kemac, pkd);
    _ = gst_mikey_message_add_payload(msg, kemac);
    return msg;
}

pub export fn gst_mikey_message_to_caps(msg: [*c]const Msg, caps: [*c]c.GstCaps) c.gboolean {
    var cipher: [*:0]const u8 = "aes-128-icm";
    var auth: [*:0]const u8 = "hmac-sha1-80";
    const srtp = gst_mikey_message_get_cs_srtp(msg, 0);
    if (srtp == null) return 0;
    const sp = gst_mikey_message_find_payload(msg, c.GST_MIKEY_PT_SP, srtp[0].policy);
    if (sp != null) {
        const p: *const SP = @ptrCast(@alignCast(sp));
        if (p.proto != c.GST_MIKEY_SEC_PROTO_SRTP) return 0;
        var enc: c.guint = c.GST_MIKEY_ENC_NULL;
        const n = gst_mikey_payload_sp_get_n_params(sp);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const prm = gst_mikey_payload_sp_get_param(sp, i);
            const v = prm[0].val[0];
            switch (prm[0].type) {
                c.GST_MIKEY_SP_SRTP_ENC_ALG => {
                    enc = v;
                    switch (v) {
                        c.GST_MIKEY_ENC_NULL => cipher = "null",
                        c.GST_MIKEY_ENC_AES_CM_128, c.GST_MIKEY_ENC_AES_KW_128 => cipher = "aes-128-icm",
                        c.GST_MIKEY_ENC_AES_GCM_128 => cipher = "aes-128-gcm",
                        else => {},
                    }
                },
                c.GST_MIKEY_SP_SRTP_ENC_KEY_LEN => switch (v) {
                    AES_128 => {
                        if (enc == c.GST_MIKEY_ENC_AES_CM_128 or enc == c.GST_MIKEY_ENC_AES_KW_128) {
                            cipher = "aes-128-icm";
                        } else if (enc == c.GST_MIKEY_ENC_AES_GCM_128) cipher = "aes-128-gcm";
                    },
                    AES_256 => {
                        if (enc == c.GST_MIKEY_ENC_AES_CM_128 or enc == c.GST_MIKEY_ENC_AES_KW_128) {
                            cipher = "aes-256-icm";
                        } else if (enc == c.GST_MIKEY_ENC_AES_GCM_128) cipher = "aes-256-gcm";
                    },
                    else => {},
                },
                c.GST_MIKEY_SP_SRTP_AUTH_ALG => switch (v) {
                    c.GST_MIKEY_MAC_NULL => auth = "null",
                    c.GST_MIKEY_MAC_HMAC_SHA_1_160 => auth = "hmac-sha1-80",
                    else => {},
                },
                c.GST_MIKEY_SP_SRTP_AUTH_KEY_LEN => switch (v) {
                    HMAC_32 => auth = "hmac-sha1-32",
                    HMAC_80 => auth = "hmac-sha1-80",
                    else => {},
                },
                else => {},
            }
        }
    }
    const km = gst_mikey_message_find_payload(msg, c.GST_MIKEY_PT_KEMAC, 0);
    if (km == null) return 0;
    const p: *const KEMAC = @ptrCast(@alignCast(km));
    if (p.enc_alg != c.GST_MIKEY_ENC_NULL or p.mac_alg != c.GST_MIKEY_MAC_NULL) return 0;
    const sub = gst_mikey_payload_kemac_get_sub(km, 0);
    if (sub == null or sub[0].type != c.GST_MIKEY_PT_KEY_DATA) return 0;
    const pkd: *const KeyData = @ptrCast(@alignCast(sub));
    var buf = c.gst_buffer_new_memdup(pkd.key_data, pkd.key_len);
    if (pkd.salt_len != 0) buf = c.gst_buffer_append(buf, c.gst_buffer_new_memdup(pkd.salt_data, pkd.salt_len));
    c.gst_caps_set_simple(caps, "srtp-key", c.gst_buffer_get_type(), buf, N);
    c.gst_buffer_unref(buf);
    c.gst_caps_set_simple(caps, "roc", c.G_TYPE_UINT, srtp[0].roc, N);
    if (pkd.kv_type == c.GST_MIKEY_KV_SPI and pkd.kv_len[0] > 0) {
        const mki = c.gst_buffer_new_memdup(pkd.kv_data[0], pkd.kv_len[0]);
        c.gst_caps_set_simple(caps, "mki", c.gst_buffer_get_type(), mki, N);
        c.gst_buffer_unref(mki);
    }
    c.gst_caps_set_simple(caps, "srtp-cipher", c.G_TYPE_STRING, cipher, "srtp-auth", c.G_TYPE_STRING, auth, "srtcp-cipher", c.G_TYPE_STRING, cipher, "srtcp-auth", c.G_TYPE_STRING, auth, N);
    return 1;
}

pub export fn gst_mikey_message_base64_encode(msg: [*c]Msg) [*c]u8 {
    if (!that(msg != null, "gst_mikey_message_base64_encode", "msg != NULL")) return null;
    const bytes = gst_mikey_message_to_bytes(msg, null, null);
    var size: usize = 0;
    const d = c.g_bytes_get_data(bytes, &size);
    const r = c.g_base64_encode(@ptrCast(d), size);
    c.g_bytes_unref(bytes);
    return r;
}
