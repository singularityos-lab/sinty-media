const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const defs = @import("defs.zig");
const that = defs.that;

comptime {
    @import("../abi.zig").check(@This());
}

const Msg = c.GstRTSPMessage;
const OK = c.GST_RTSP_OK;
const EINVAL = c.GST_RTSP_EINVAL;
const ENOTIMPL = c.GST_RTSP_ENOTIMPL;

const Field = extern struct {
    field: c.GstRTSPHeaderField,
    value: [*c]u8,
    key: [*c]u8,
};

var msg_once: gtype.Once = .{};
var param_once: gtype.Once = .{};
var cred_once: gtype.Once = .{};

fn fields(m: [*c]const Msg) []Field {
    const a = m[0].hdr_fields;
    if (a == null or a[0].len == 0) return &.{};
    return @as([*]Field, @ptrCast(@alignCast(a[0].data)))[0..a[0].len];
}

fn newFields() [*c]c.GArray {
    return c.g_array_new(0, 0, @sizeOf(Field));
}

fn alloc() [*c]Msg {
    return @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Msg))));
}

fn boxedCopy(m: ?*anyopaque) callconv(.c) ?*anyopaque {
    var copy: [*c]Msg = null;
    if (gst_rtsp_message_copy(@ptrCast(@alignCast(m)), &copy) == OK) return copy;
    return null;
}

fn boxedFree(m: ?*anyopaque) callconv(.c) void {
    _ = gst_rtsp_message_free(@ptrCast(@alignCast(m)));
}

pub export fn gst_rtsp_msg_get_type() c.GType {
    return msg_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstRTSPMessage", boxedCopy, boxedFree);
        }
    }.f);
}

pub export fn gst_rtsp_message_new(out: [*c][*c]Msg) c.GstRTSPResult {
    if (!that(out != null, "gst_rtsp_message_new", "msg != NULL")) return EINVAL;
    out.* = alloc();
    return gst_rtsp_message_init(out.*);
}

pub export fn gst_rtsp_message_init(m: [*c]Msg) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_init", "msg != NULL")) return EINVAL;
    _ = gst_rtsp_message_unset(m);
    m[0].type = c.GST_RTSP_MESSAGE_INVALID;
    m[0].hdr_fields = newFields();
    return OK;
}

pub export fn gst_rtsp_message_get_type(m: [*c]Msg) c.GstRTSPMsgType {
    if (!that(m != null, "gst_rtsp_message_get_type", "msg != NULL")) return c.GST_RTSP_MESSAGE_INVALID;
    return m[0].type;
}

pub export fn gst_rtsp_message_new_request(out: [*c][*c]Msg, method: c.GstRTSPMethod, uri: [*c]const u8) c.GstRTSPResult {
    const f = "gst_rtsp_message_new_request";
    if (!that(out != null, f, "msg != NULL")) return EINVAL;
    if (!that(uri != null, f, "uri != NULL")) return EINVAL;
    out.* = alloc();
    return gst_rtsp_message_init_request(out.*, method, uri);
}

pub export fn gst_rtsp_message_init_request(m: [*c]Msg, method: c.GstRTSPMethod, uri: [*c]const u8) c.GstRTSPResult {
    const f = "gst_rtsp_message_init_request";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(uri != null, f, "uri != NULL")) return EINVAL;
    _ = gst_rtsp_message_unset(m);
    m[0].type = c.GST_RTSP_MESSAGE_REQUEST;
    m[0].type_data.request.method = method;
    m[0].type_data.request.uri = c.g_strdup(uri);
    m[0].type_data.request.version = c.GST_RTSP_VERSION_1_0;
    m[0].hdr_fields = newFields();
    return OK;
}

pub export fn gst_rtsp_message_parse_request(m: [*c]Msg, method: [*c]c.GstRTSPMethod, uri: [*c][*c]const u8, version: [*c]c.GstRTSPVersion) c.GstRTSPResult {
    const f = "gst_rtsp_message_parse_request";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(m[0].type == c.GST_RTSP_MESSAGE_REQUEST or m[0].type == c.GST_RTSP_MESSAGE_HTTP_REQUEST, f, "msg->type == GST_RTSP_MESSAGE_REQUEST || msg->type == GST_RTSP_MESSAGE_HTTP_REQUEST")) return EINVAL;
    if (method != null) method.* = m[0].type_data.request.method;
    if (uri != null) uri.* = m[0].type_data.request.uri;
    if (version != null) version.* = m[0].type_data.request.version;
    return OK;
}

pub export fn gst_rtsp_message_new_response(out: [*c][*c]Msg, code: c.GstRTSPStatusCode, reason: [*c]const u8, req: [*c]const Msg) c.GstRTSPResult {
    if (!that(out != null, "gst_rtsp_message_new_response", "msg != NULL")) return EINVAL;
    out.* = alloc();
    return gst_rtsp_message_init_response(out.*, code, reason, req);
}

pub export fn gst_rtsp_message_init_response(m: [*c]Msg, code: c.GstRTSPStatusCode, reason: [*c]const u8, req: [*c]const Msg) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_init_response", "msg != NULL")) return EINVAL;
    _ = gst_rtsp_message_unset(m);
    const why = if (reason == null) defs.gst_rtsp_status_as_text(code) else reason;
    m[0].type = c.GST_RTSP_MESSAGE_RESPONSE;
    m[0].type_data.response.code = code;
    m[0].type_data.response.reason = c.g_strdup(why);
    m[0].type_data.response.version = c.GST_RTSP_VERSION_1_0;
    m[0].hdr_fields = newFields();
    if (req == null) return OK;
    if (req[0].type == c.GST_RTSP_MESSAGE_HTTP_REQUEST) {
        m[0].type = c.GST_RTSP_MESSAGE_HTTP_RESPONSE;
        const v = req[0].type_data.request.version;
        m[0].type_data.response.version = if (v != c.GST_RTSP_VERSION_INVALID) v else c.GST_RTSP_VERSION_1_1;
        return OK;
    }
    var h: [*c]u8 = null;
    if (gst_rtsp_message_get_header(req, c.GST_RTSP_HDR_CSEQ, &h, 0) == OK) _ = gst_rtsp_message_add_header(m, c.GST_RTSP_HDR_CSEQ, h);
    if (gst_rtsp_message_get_header(req, c.GST_RTSP_HDR_SESSION, &h, 0) == OK) {
        const own = c.g_strdup(h);
        const semi = c.strchr(own, ';');
        if (semi != null) semi[0] = 0;
        _ = c.g_strchomp(own);
        _ = gst_rtsp_message_take_header(m, c.GST_RTSP_HDR_SESSION, own);
    }
    return OK;
}

pub export fn gst_rtsp_message_parse_response(m: [*c]Msg, code: [*c]c.GstRTSPStatusCode, reason: [*c][*c]const u8, version: [*c]c.GstRTSPVersion) c.GstRTSPResult {
    const f = "gst_rtsp_message_parse_response";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(m[0].type == c.GST_RTSP_MESSAGE_RESPONSE or m[0].type == c.GST_RTSP_MESSAGE_HTTP_RESPONSE, f, "msg->type == GST_RTSP_MESSAGE_RESPONSE || msg->type == GST_RTSP_MESSAGE_HTTP_RESPONSE")) return EINVAL;
    if (code != null) code.* = m[0].type_data.response.code;
    if (reason != null) reason.* = m[0].type_data.response.reason;
    if (version != null) version.* = m[0].type_data.response.version;
    return OK;
}

pub export fn gst_rtsp_message_new_data(out: [*c][*c]Msg, channel: u8) c.GstRTSPResult {
    if (!that(out != null, "gst_rtsp_message_new_data", "msg != NULL")) return EINVAL;
    out.* = alloc();
    return gst_rtsp_message_init_data(out.*, channel);
}

pub export fn gst_rtsp_message_init_data(m: [*c]Msg, channel: u8) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_init_data", "msg != NULL")) return EINVAL;
    _ = gst_rtsp_message_unset(m);
    m[0].type = c.GST_RTSP_MESSAGE_DATA;
    m[0].type_data.data.channel = channel;
    return OK;
}

pub export fn gst_rtsp_message_parse_data(m: [*c]Msg, channel: [*c]u8) c.GstRTSPResult {
    const f = "gst_rtsp_message_parse_data";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(m[0].type == c.GST_RTSP_MESSAGE_DATA, f, "msg->type == GST_RTSP_MESSAGE_DATA")) return EINVAL;
    if (channel != null) channel.* = m[0].type_data.data.channel;
    return OK;
}

pub export fn gst_rtsp_message_unset(m: [*c]Msg) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_unset", "msg != NULL")) return EINVAL;
    switch (m[0].type) {
        c.GST_RTSP_MESSAGE_INVALID, c.GST_RTSP_MESSAGE_DATA => {},
        c.GST_RTSP_MESSAGE_REQUEST, c.GST_RTSP_MESSAGE_HTTP_REQUEST => c.g_free(m[0].type_data.request.uri),
        c.GST_RTSP_MESSAGE_RESPONSE, c.GST_RTSP_MESSAGE_HTTP_RESPONSE => c.g_free(m[0].type_data.response.reason),
        else => {
            c.g_log(defs.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", "../gst-libs/gst/rtsp/gstrtspmessage.c", @as(c_int, 495), "gst_rtsp_message_unset");
            return EINVAL;
        },
    }
    if (m[0].hdr_fields != null) {
        for (fields(m)) |kv| {
            c.g_free(kv.value);
            c.g_free(kv.key);
        }
        _ = c.g_array_free(m[0].hdr_fields, 1);
    }
    c.g_free(m[0].body);
    _ = c.gst_mini_object_replace(@ptrCast(&m[0].body_buffer), null);
    m[0] = std.mem.zeroes(Msg);
    return OK;
}

pub export fn gst_rtsp_message_free(m: [*c]Msg) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_free", "msg != NULL")) return EINVAL;
    const r = gst_rtsp_message_unset(m);
    if (r == OK) c.g_free(m);
    return r;
}

pub export fn gst_rtsp_message_copy(m: [*c]const Msg, out: [*c][*c]Msg) c.GstRTSPResult {
    if (!that(out != null, "gst_rtsp_message_copy", "copy != NULL")) return EINVAL;
    out.* = null;
    if (m == null) return EINVAL;
    const r = gst_rtsp_message_new(out);
    if (r != OK) return r;
    const cp = out.*;
    cp[0].type = m[0].type;
    switch (m[0].type) {
        c.GST_RTSP_MESSAGE_INVALID => {},
        c.GST_RTSP_MESSAGE_REQUEST, c.GST_RTSP_MESSAGE_HTTP_REQUEST => {
            cp[0].type_data.request.method = m[0].type_data.request.method;
            cp[0].type_data.request.uri = c.g_strdup(m[0].type_data.request.uri);
            cp[0].type_data.request.version = m[0].type_data.request.version;
        },
        c.GST_RTSP_MESSAGE_RESPONSE, c.GST_RTSP_MESSAGE_HTTP_RESPONSE => {
            cp[0].type_data.response.code = m[0].type_data.response.code;
            cp[0].type_data.response.reason = c.g_strdup(m[0].type_data.response.reason);
            cp[0].type_data.response.version = m[0].type_data.response.version;
        },
        c.GST_RTSP_MESSAGE_DATA => cp[0].type_data.data.channel = m[0].type_data.data.channel,
        else => return EINVAL,
    }
    for (fields(m)) |kv| {
        var dup = Field{ .field = kv.field, .value = c.g_strdup(kv.value), .key = c.g_strdup(kv.key) };
        _ = c.g_array_append_vals(cp[0].hdr_fields, &dup, 1);
    }
    if (m[0].body != null) {
        _ = gst_rtsp_message_set_body(cp, m[0].body, m[0].body_size);
    } else _ = gst_rtsp_message_set_body_buffer(cp, m[0].body_buffer);
    return OK;
}

pub export fn gst_rtsp_message_take_header(m: [*c]Msg, field: c.GstRTSPHeaderField, value: [*c]u8) c.GstRTSPResult {
    const f = "gst_rtsp_message_take_header";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(value != null, f, "value != NULL")) return EINVAL;
    var kv = Field{ .field = field, .value = value, .key = null };
    _ = c.g_array_append_vals(m[0].hdr_fields, &kv, 1);
    return OK;
}

pub export fn gst_rtsp_message_add_header(m: [*c]Msg, field: c.GstRTSPHeaderField, value: [*c]const u8) c.GstRTSPResult {
    return gst_rtsp_message_take_header(m, field, c.g_strdup(value));
}

pub export fn gst_rtsp_message_remove_header(m: [*c]Msg, field: c.GstRTSPHeaderField, index: c.gint) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_remove_header", "msg != NULL")) return EINVAL;
    var res = ENOTIMPL;
    var i: c.guint = 0;
    var n: c.gint = 0;
    while (i < m[0].hdr_fields[0].len) {
        const kv = fields(m)[i];
        if (kv.field == field and (index == -1 or blk: {
            const hit = n == index;
            n += 1;
            break :blk hit;
        })) {
            c.g_free(kv.value);
            _ = c.g_array_remove_index(m[0].hdr_fields, i);
            res = OK;
            if (index != -1) break;
        } else i += 1;
    }
    return res;
}

pub export fn gst_rtsp_message_get_header(m: [*c]const Msg, field: c.GstRTSPHeaderField, value: [*c][*c]u8, index: c.gint) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_get_header", "msg != NULL")) return EINVAL;
    if (value != null) value.* = null;
    if (m[0].hdr_fields == null) return ENOTIMPL;
    var n: c.gint = 0;
    for (fields(m)) |kv| {
        if (kv.field != field) continue;
        const hit = n == index;
        n += 1;
        if (hit) {
            if (value != null) value.* = kv.value;
            return OK;
        }
    }
    return ENOTIMPL;
}

pub export fn gst_rtsp_message_add_header_by_name(m: [*c]Msg, header: [*c]const u8, value: [*c]const u8) c.GstRTSPResult {
    const f = "gst_rtsp_message_add_header_by_name";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(header != null, f, "header != NULL")) return EINVAL;
    if (!that(value != null, f, "value != NULL")) return EINVAL;
    const field = defs.gst_rtsp_find_header_field(header);
    if (field != c.GST_RTSP_HDR_INVALID) return gst_rtsp_message_take_header(m, field, c.g_strdup(value));
    return gst_rtsp_message_take_header_by_name(m, header, c.g_strdup(value));
}

pub export fn gst_rtsp_message_take_header_by_name(m: [*c]Msg, header: [*c]const u8, value: [*c]u8) c.GstRTSPResult {
    const f = "gst_rtsp_message_take_header_by_name";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(header != null, f, "header != NULL")) return EINVAL;
    if (!that(value != null, f, "value != NULL")) return EINVAL;
    var kv = Field{ .field = c.GST_RTSP_HDR_INVALID, .value = value, .key = c.g_strdup(header) };
    _ = c.g_array_append_vals(m[0].hdr_fields, &kv, 1);
    return OK;
}

fn findByName(m: [*c]const Msg, header: [*c]const u8, index: c.gint) ?usize {
    if (m[0].hdr_fields == null) return null;
    const field = defs.gst_rtsp_find_header_field(header);
    var n: c.gint = 0;
    for (fields(m), 0..) |kv, i| {
        if (kv.field != field) continue;
        if (kv.key != null and c.g_ascii_strcasecmp(kv.key, header) != 0) continue;
        if (index < 0) return i;
        const hit = n == index;
        n += 1;
        if (hit) return i;
    }
    return null;
}

pub export fn gst_rtsp_message_remove_header_by_name(m: [*c]Msg, header: [*c]const u8, index: c.gint) c.GstRTSPResult {
    const f = "gst_rtsp_message_remove_header_by_name";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(header != null, f, "header != NULL")) return EINVAL;
    var res = ENOTIMPL;
    while (findByName(m, header, index)) |pos| {
        const kv = fields(m)[pos];
        c.g_free(kv.value);
        c.g_free(kv.key);
        _ = c.g_array_remove_index(m[0].hdr_fields, @intCast(pos));
        res = OK;
        if (index >= 0) break;
    }
    return res;
}

pub export fn gst_rtsp_message_get_header_by_name(m: [*c]Msg, header: [*c]const u8, value: [*c][*c]u8, index: c.gint) c.GstRTSPResult {
    const f = "gst_rtsp_message_get_header_by_name";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(header != null, f, "header != NULL")) return EINVAL;
    if (value != null) value.* = null;
    const pos = findByName(m, header, index) orelse return ENOTIMPL;
    if (value != null) value.* = fields(m)[pos].value;
    return OK;
}

fn keyOf(kv: Field) [*c]const u8 {
    return if (kv.key != null) kv.key else defs.gst_rtsp_header_as_text(kv.field);
}

pub export fn gst_rtsp_message_append_headers(m: [*c]const Msg, s: [*c]c.GString) c.GstRTSPResult {
    const f = "gst_rtsp_message_append_headers";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(s != null, f, "str != NULL")) return EINVAL;
    for (fields(m)) |kv| c.g_string_append_printf(s, "%s: %s\r\n", keyOf(kv), kv.value);
    return OK;
}

pub export fn gst_rtsp_message_set_body(m: [*c]Msg, data: [*c]const u8, size: c.guint) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_set_body", "msg != NULL")) return EINVAL;
    return gst_rtsp_message_take_body(m, @ptrCast(c.g_memdup2(data, size)), size);
}

pub export fn gst_rtsp_message_take_body(m: [*c]Msg, data: [*c]u8, size: c.guint) c.GstRTSPResult {
    const f = "gst_rtsp_message_take_body";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(data != null or size == 0, f, "data != NULL || size == 0")) return EINVAL;
    _ = c.gst_mini_object_replace(@ptrCast(&m[0].body_buffer), null);
    c.g_free(m[0].body);
    m[0].body = data;
    m[0].body_size = size;
    return OK;
}

fn flatten(m: [*c]Msg) void {
    if (m[0].body_buffer == null) return;
    var n: usize = 0;
    var data: c.gpointer = null;
    c.gst_buffer_extract_dup(m[0].body_buffer, 0, c.gst_buffer_get_size(m[0].body_buffer), &data, &n);
    m[0].body = @ptrCast(data);
    _ = c.gst_mini_object_replace(@ptrCast(&m[0].body_buffer), null);
    m[0].body_size = @intCast(n);
}

pub export fn gst_rtsp_message_get_body(m: [*c]const Msg, data: [*c][*c]u8, size: [*c]c.guint) c.GstRTSPResult {
    const f = "gst_rtsp_message_get_body";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(data != null, f, "data != NULL")) return EINVAL;
    if (!that(size != null, f, "size != NULL")) return EINVAL;
    flatten(@constCast(m));
    data.* = m[0].body;
    size.* = m[0].body_size;
    return OK;
}

pub export fn gst_rtsp_message_steal_body(m: [*c]Msg, data: [*c][*c]u8, size: [*c]c.guint) c.GstRTSPResult {
    const f = "gst_rtsp_message_steal_body";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(data != null, f, "data != NULL")) return EINVAL;
    if (!that(size != null, f, "size != NULL")) return EINVAL;
    flatten(m);
    data.* = m[0].body;
    size.* = m[0].body_size;
    m[0].body = null;
    m[0].body_size = 0;
    return OK;
}

pub export fn gst_rtsp_message_set_body_buffer(m: [*c]Msg, b: [*c]c.GstBuffer) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_set_body_buffer", "msg != NULL")) return EINVAL;
    if (b != null) _ = c.gst_mini_object_ref(@ptrCast(b));
    return gst_rtsp_message_take_body_buffer(m, b);
}

pub export fn gst_rtsp_message_take_body_buffer(m: [*c]Msg, b: [*c]c.GstBuffer) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_take_body_buffer", "msg != NULL")) return EINVAL;
    c.g_free(m[0].body);
    m[0].body = null;
    if (m[0].body_buffer != null) c.gst_buffer_unref(m[0].body_buffer);
    m[0].body_buffer = b;
    m[0].body_size = if (b != null) @intCast(c.gst_buffer_get_size(b)) else 0;
    return OK;
}

pub export fn gst_rtsp_message_get_body_buffer(m: [*c]const Msg, b: [*c][*c]c.GstBuffer) c.GstRTSPResult {
    const f = "gst_rtsp_message_get_body_buffer";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(b != null, f, "buffer != NULL")) return EINVAL;
    b.* = m[0].body_buffer;
    return OK;
}

pub export fn gst_rtsp_message_steal_body_buffer(m: [*c]Msg, b: [*c][*c]c.GstBuffer) c.GstRTSPResult {
    const f = "gst_rtsp_message_steal_body_buffer";
    if (!that(m != null, f, "msg != NULL")) return EINVAL;
    if (!that(b != null, f, "buffer != NULL")) return EINVAL;
    b.* = m[0].body_buffer;
    if (m[0].body_buffer != null) {
        m[0].body_buffer = null;
        m[0].body_size = 0;
    }
    return OK;
}

pub export fn gst_rtsp_message_has_body_buffer(m: [*c]const Msg) c.gboolean {
    if (!that(m != null, "gst_rtsp_message_has_body_buffer", "msg != NULL")) return EINVAL;
    return @intFromBool(m[0].body_buffer != null);
}

fn dumpHeaders(m: [*c]Msg) void {
    for (fields(m)) |kv| c.g_print("   key: '%s', value: '%s'\n", keyOf(kv), kv.value);
}

fn dumpBody(m: [*c]Msg) void {
    var b: [*c]c.GstBuffer = null;
    _ = gst_rtsp_message_get_body_buffer(m, &b);
    if (b != null) {
        c.gst_util_dump_buffer(b);
        return;
    }
    var data: [*c]u8 = null;
    var size: c.guint = 0;
    _ = gst_rtsp_message_get_body(m, &data, &size);
    if (data != null) c.gst_util_dump_mem(data, size);
}

pub export fn gst_rtsp_message_dump(m: [*c]Msg) c.GstRTSPResult {
    if (!that(m != null, "gst_rtsp_message_dump", "msg != NULL")) return EINVAL;
    const rq = &m[0].type_data.request;
    const rs = &m[0].type_data.response;
    switch (m[0].type) {
        c.GST_RTSP_MESSAGE_REQUEST => {
            c.g_print("RTSP request message %p\n", m);
            c.g_print(" request line:\n");
            c.g_print("   method: '%s'\n", defs.gst_rtsp_method_as_text(rq.method));
            c.g_print("   uri:    '%s'\n", rq.uri);
            c.g_print("   version: '%s'\n", defs.gst_rtsp_version_as_text(rq.version));
            c.g_print(" headers:\n");
            dumpHeaders(m);
            c.g_print(" body:\n");
            dumpBody(m);
        },
        c.GST_RTSP_MESSAGE_RESPONSE => {
            c.g_print("RTSP response message %p\n", m);
            c.g_print(" status line:\n");
            c.g_print("   code:   '%d'\n", rs.code);
            c.g_print("   reason: '%s'\n", rs.reason);
            c.g_print("   version: '%s'\n", defs.gst_rtsp_version_as_text(rs.version));
            c.g_print(" headers:\n");
            dumpHeaders(m);
            dumpBody(m);
        },
        c.GST_RTSP_MESSAGE_HTTP_REQUEST => {
            c.g_print("HTTP request message %p\n", m);
            c.g_print(" request line:\n");
            c.g_print("   method:  '%s'\n", defs.gst_rtsp_method_as_text(rq.method));
            c.g_print("   uri:     '%s'\n", rq.uri);
            c.g_print("   version: '%s'\n", defs.gst_rtsp_version_as_text(rq.version));
            c.g_print(" headers:\n");
            dumpHeaders(m);
            c.g_print(" body:\n");
            dumpBody(m);
        },
        c.GST_RTSP_MESSAGE_HTTP_RESPONSE => {
            c.g_print("HTTP response message %p\n", m);
            c.g_print(" status line:\n");
            c.g_print("   code:    '%d'\n", rs.code);
            c.g_print("   reason:  '%s'\n", rs.reason);
            c.g_print("   version: '%s'\n", defs.gst_rtsp_version_as_text(rs.version));
            c.g_print(" headers:\n");
            dumpHeaders(m);
            dumpBody(m);
        },
        c.GST_RTSP_MESSAGE_DATA => {
            c.g_print("RTSP data message %p\n", m);
            c.g_print(" channel: '%d'\n", @as(c_int, m[0].type_data.data.channel));
            c.g_print(" size:    '%d'\n", m[0].body_size);
            dumpBody(m);
        },
        else => {
            c.g_print("unsupported message type %d\n", m[0].type);
            return EINVAL;
        },
    }
    return OK;
}

fn skipLws(s: [*c]const u8) [*c]const u8 {
    var p = s;
    while (c.g_ascii_isspace(p[0])) p += 1;
    return p;
}

fn skipCommas(s: [*c]const u8) [*c]const u8 {
    var p = s;
    while (c.g_ascii_isspace(p[0]) or p[0] == ',') p += 1;
    return p;
}

fn skipScheme(s: [*c]const u8) [*c]const u8 {
    var p = s;
    while (p[0] != 0 and !c.g_ascii_isspace(p[0])) p += 1;
    return p;
}

fn skipItem(s: [*c]const u8) [*c]const u8 {
    var p = s;
    var quoted = false;
    while (p[0] != 0) : (p += 1) {
        if (p[0] == '"') {
            quoted = !quoted;
        } else if (quoted) {
            if (p[0] == '\\' and p[1] != 0) p += 1;
        } else if (p[0] == ',' or c.g_ascii_isspace(p[0])) break;
    }
    return p;
}

fn unquote(q: [*c]u8) void {
    var src = q + 1;
    var dst = q;
    while (src[0] != 0 and src[0] != '"') {
        if (src[0] == '\\' and src[1] != 0) src += 1;
        dst[0] = src[0];
        dst += 1;
        src += 1;
    }
    dst[0] = 0;
}

fn span(a: [*c]const u8, b: [*c]const u8) usize {
    return @intFromPtr(a) - @intFromPtr(b);
}

fn parseCredentials(out: [*c]c.GPtrArray, header: [*c]const u8, field: c.GstRTSPHeaderField) void {
    var h = header;
    while (h[0] != 0) {
        h = skipLws(h);
        if (h[0] == 0) break;
        const end = skipScheme(h);
        var scheme: c.GstRTSPAuthMethod = c.GST_RTSP_AUTH_NONE;
        if (c.g_ascii_strncasecmp(h, "basic", 5) == 0) {
            scheme = c.GST_RTSP_AUTH_BASIC;
        } else if (c.g_ascii_strncasecmp(h, "digest", 6) == 0) {
            scheme = c.GST_RTSP_AUTH_DIGEST;
        } else {
            h = end;
            continue;
        }
        const cred: [*c]c.GstRTSPAuthCredential = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstRTSPAuthCredential))));
        cred[0].scheme = scheme;
        if (end[0] != 0 and field == c.GST_RTSP_HDR_AUTHORIZATION and scheme == c.GST_RTSP_AUTH_BASIC) {
            cred[0].authorization = c.g_strdup(end + 1);
            h = end;
        } else if (end[0] != 0) {
            const params = c.g_ptr_array_new();
            h = end;
            while (h[0] != 0) {
                h = skipCommas(h);
                const item = skipItem(h);
                var eq = h;
                while (eq[0] != 0 and eq[0] != '=' and @intFromPtr(eq) < @intFromPtr(item)) eq += 1;
                if (eq[0] != '=') break;
                const prm: [*c]c.GstRTSPAuthParam = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstRTSPAuthParam))));
                prm[0].name = c.g_strndup(h, span(eq, h));
                const v = skipLws(eq + 1);
                prm[0].value = c.g_strndup(v, span(item, v));
                if (v[0] == '"') unquote(prm[0].value);
                c.g_ptr_array_add(params, prm);
                h = item;
            }
            if (params[0].len != 0) c.g_ptr_array_add(params, null);
            cred[0].params = @ptrCast(@alignCast(c.g_ptr_array_free(params, 0)));
        } else h = end;
        c.g_ptr_array_add(out, cred);
        if (field == c.GST_RTSP_HDR_AUTHORIZATION) break;
    }
}

pub export fn gst_rtsp_message_parse_auth_credentials(m: [*c]Msg, field: c.GstRTSPHeaderField) [*c][*c]c.GstRTSPAuthCredential {
    if (!that(m != null, "gst_rtsp_message_parse_auth_credentials", "msg != NULL")) return null;
    const out = c.g_ptr_array_new();
    var h: [*c]u8 = null;
    var i: c.gint = 0;
    while (gst_rtsp_message_get_header(m, field, &h, i) == OK) : (i += 1) parseCredentials(out, h, field);
    if (out[0].len != 0) c.g_ptr_array_add(out, null);
    return @ptrCast(@alignCast(c.g_ptr_array_free(out, 0)));
}

pub export fn gst_rtsp_auth_param_copy(p: [*c]c.GstRTSPAuthParam) [*c]c.GstRTSPAuthParam {
    if (p == null) return null;
    const r: [*c]c.GstRTSPAuthParam = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstRTSPAuthParam))));
    r[0].name = c.g_strdup(p[0].name);
    r[0].value = c.g_strdup(p[0].value);
    return r;
}

pub export fn gst_rtsp_auth_param_free(p: [*c]c.GstRTSPAuthParam) void {
    if (p == null) return;
    c.g_free(p[0].name);
    c.g_free(p[0].value);
    c.g_free(p);
}

pub export fn gst_rtsp_auth_param_get_type() c.GType {
    return param_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstRTSPAuthParam", @ptrCast(&gst_rtsp_auth_param_copy), @ptrCast(&gst_rtsp_auth_param_free));
        }
    }.f);
}

fn credFree(cr: [*c]c.GstRTSPAuthCredential) callconv(.c) void {
    if (cr == null) return;
    var p = cr[0].params;
    while (p != null and p[0] != null) : (p += 1) gst_rtsp_auth_param_free(p[0]);
    c.g_free(@ptrCast(cr[0].params));
    c.g_free(cr[0].authorization);
    c.g_free(cr);
}

fn credCopy(cr: [*c]c.GstRTSPAuthCredential) callconv(.c) [*c]c.GstRTSPAuthCredential {
    if (cr == null) return null;
    const r: [*c]c.GstRTSPAuthCredential = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstRTSPAuthCredential))));
    r[0].scheme = cr[0].scheme;
    if (cr[0].params != null) {
        const n = c.g_strv_length(@ptrCast(cr[0].params));
        r[0].params = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(usize) * (n + 1))));
        for (0..n) |i| r[0].params[i] = gst_rtsp_auth_param_copy(cr[0].params[i]);
    }
    r[0].authorization = c.g_strdup(cr[0].authorization);
    return r;
}

pub export fn gst_rtsp_auth_credentials_free(list: [*c][*c]c.GstRTSPAuthCredential) void {
    if (list == null) return;
    var p = list;
    while (p[0] != null) : (p += 1) credFree(p[0]);
    c.g_free(@ptrCast(list));
}

pub export fn gst_rtsp_auth_credential_get_type() c.GType {
    return cred_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstRTSPAuthCredential", @ptrCast(&credCopy), @ptrCast(&credFree));
        }
    }.f);
}
