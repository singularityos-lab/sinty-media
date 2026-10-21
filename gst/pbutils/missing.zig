const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const init = @import("init.zig");
const desc = @import("desc.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Caps = c.GstCaps;
const Msg = c.GstMessage;
const VNONE = @as(?*anyopaque, null);

const Kind = enum { unknown, urisource, urisink, element, decoder, encoder };

fn kindOf(s: ?*const c.GstStructure) Kind {
    const t = c.gst_structure_get_string(s, "type");
    if (!check.that(t != null, "missing_structure_get_type", "type != NULL")) return .unknown;
    const n = std.mem.span(@as([*:0]const u8, @ptrCast(t)));
    inline for (.{ Kind.urisource, Kind.urisink, Kind.element, Kind.decoder, Kind.encoder }) |k| {
        if (std.mem.eql(u8, n, @tagName(k))) return k;
    }
    return .unknown;
}

fn stringDetail(s: ?*const c.GstStructure) ?[*c]u8 {
    if (c.g_type_is_a(c.gst_structure_get_field_type(s, "detail"), c.G_TYPE_STRING) == 0) return null;
    const d = c.gst_structure_get_string(s, "detail");
    if (d == null or d[0] == 0) return null;
    return c.g_strdup(d);
}

fn capsDetail(s: ?*const c.GstStructure) ?[*c]Caps {
    if (c.g_type_is_a(c.gst_structure_get_field_type(s, "detail"), c.gst_caps_get_type()) == 0) return null;
    const caps = c.gst_value_get_caps(c.gst_structure_get_value(s, "detail"));
    if (c.gst_caps_is_empty(caps) != 0 or c.gst_caps_is_any(caps) != 0) return null;
    return c.gst_caps_copy(caps);
}

fn element(e: ?*c.GstElement, s: ?*c.GstStructure) [*c]Msg {
    return c.gst_message_new_element(@ptrCast(e), s);
}

fn stringMessage(e: ?*c.GstElement, arg: [*c]const c.gchar, comptime fname: []const u8, comptime argname: []const u8, comptime kind: [*:0]const u8, describe: *const fn ([*c]const c.gchar) callconv(.c) [*c]c.gchar) [*c]Msg {
    if (!check.that(e != null, fname, "element != NULL")) return null;
    if (!check.that(check.isElement(e), fname, "GST_IS_ELEMENT (element)")) return null;
    if (!check.that(arg != null, fname, argname ++ " != NULL")) return null;
    const d = describe(arg);
    const s = c.gst_structure_new("missing-plugin", "type", c.G_TYPE_STRING, kind, "detail", c.G_TYPE_STRING, arg, "name", c.G_TYPE_STRING, d, VNONE);
    c.g_free(d);
    return element(e, s);
}

fn validCaps(caps: [*c]const Caps, comptime fname: []const u8, comptime n: []const u8) bool {
    if (!check.that(caps != null, fname, n ++ " != NULL")) return false;
    if (!check.that(check.isCaps(caps), fname, "GST_IS_CAPS (" ++ n ++ ")")) return false;
    if (!check.that(c.gst_caps_is_any(caps) == 0, fname, "!gst_caps_is_any (" ++ n ++ ")")) return false;
    if (!check.that(c.gst_caps_is_empty(caps) == 0, fname, "!gst_caps_is_empty (" ++ n ++ ")")) return false;
    return check.that(c.gst_caps_is_fixed(caps) != 0, fname, "gst_caps_is_fixed (" ++ n ++ ")");
}

fn capsMessage(e: ?*c.GstElement, caps: [*c]const Caps, comptime fname: []const u8, comptime n: []const u8, comptime kind: [*:0]const u8, describe: *const fn ([*c]const Caps) callconv(.c) [*c]c.gchar) [*c]Msg {
    if (!check.that(e != null, fname, "element != NULL")) return null;
    if (!check.that(check.isElement(e), fname, "GST_IS_ELEMENT (element)")) return null;
    if (!validCaps(caps, fname, n)) return null;
    const d = describe(caps);
    const clean = desc.cleanCaps(caps);
    const s = c.gst_structure_new("missing-plugin", "type", c.G_TYPE_STRING, kind, "detail", c.gst_caps_get_type(), clean, "name", c.G_TYPE_STRING, d, VNONE);
    c.gst_caps_unref(clean);
    c.g_free(d);
    return element(e, s);
}

pub export fn gst_missing_uri_source_message_new(e: ?*c.GstElement, protocol: [*c]const c.gchar) [*c]Msg {
    return stringMessage(e, protocol, "gst_missing_uri_source_message_new", "protocol", "urisource", desc.gst_pb_utils_get_source_description);
}

pub export fn gst_missing_uri_sink_message_new(e: ?*c.GstElement, protocol: [*c]const c.gchar) [*c]Msg {
    return stringMessage(e, protocol, "gst_missing_uri_sink_message_new", "protocol", "urisink", desc.gst_pb_utils_get_sink_description);
}

pub export fn gst_missing_element_message_new(e: ?*c.GstElement, factory_name: [*c]const c.gchar) [*c]Msg {
    return stringMessage(e, factory_name, "gst_missing_element_message_new", "factory_name", "element", desc.gst_pb_utils_get_element_description);
}

pub export fn gst_missing_decoder_message_new(e: ?*c.GstElement, decode_caps: [*c]const Caps) [*c]Msg {
    return capsMessage(e, decode_caps, "gst_missing_decoder_message_new", "decode_caps", "decoder", desc.gst_pb_utils_get_decoder_description);
}

pub export fn gst_missing_encoder_message_new(e: ?*c.GstElement, encode_caps: [*c]const Caps) [*c]Msg {
    return capsMessage(e, encode_caps, "gst_missing_encoder_message_new", "encode_caps", "encoder", desc.gst_pb_utils_get_encoder_description);
}

fn header(d: [*c]u8) *c.GString {
    const s = c.g_string_new("gstreamer|");
    c.g_string_append_printf(s, "%s|", @as([*c]const u8, "1.0"));
    const prog = c.g_get_prgname();
    if (prog != null) c.g_string_append_printf(s, "%s|", prog) else c.g_string_append_printf(s, "pid/%lu|", @as(c_ulong, @intCast(std.c.getpid())));
    if (d != null) {
        _ = c.g_strdelimit(d, "|", '#');
        c.g_string_append_printf(s, "%s|", d);
    } else _ = c.g_string_append(s, "|");
    return s;
}

pub export fn gst_missing_plugin_message_get_installer_detail(msg: [*c]Msg) [*c]c.gchar {
    if (!check.that(gst_is_missing_plugin_message(msg) != 0, "gst_missing_plugin_message_get_installer_detail", "gst_is_missing_plugin_message (msg)")) return null;
    const st = c.gst_message_get_structure(msg);
    const k = kindOf(st);
    if (k == .unknown) return null;
    const t = c.gst_structure_get_string(st, "type");
    const d = gst_missing_plugin_message_get_description(msg);
    const s = header(d);
    c.g_free(d);
    var detail: [*c]u8 = null;
    switch (k) {
        .urisource, .urisink, .element => detail = stringDetail(st) orelse {
            _ = c.g_string_free(s, 1);
            return null;
        },
        .decoder, .encoder => {
            const caps = capsDetail(st) orelse {
                _ = c.g_string_free(s, 1);
                return null;
            };
            detail = c.gst_caps_to_string(caps);
            c.gst_caps_unref(caps);
        },
        .unknown => unreachable,
    }
    c.g_string_append_printf(s, "%s-%s", t, detail);
    c.g_free(detail);
    return c.g_string_free(s, 0);
}

pub export fn gst_missing_plugin_message_set_stream_id(msg: [*c]Msg, stream_id: [*c]const c.gchar) void {
    if (!check.that(gst_is_missing_plugin_message(msg) != 0, "gst_missing_plugin_message_set_stream_id", "gst_is_missing_plugin_message (msg)")) return;
    c.gst_structure_set(@constCast(c.gst_message_get_structure(msg)), "stream-id", c.G_TYPE_STRING, stream_id, VNONE);
}

pub export fn gst_missing_plugin_message_get_stream_id(msg: [*c]Msg) [*c]const c.gchar {
    if (!check.that(gst_is_missing_plugin_message(msg) != 0, "gst_missing_plugin_message_get_stream_id", "gst_is_missing_plugin_message (msg)")) return null;
    return c.gst_structure_get_string(c.gst_message_get_structure(msg), "stream-id");
}

pub export fn gst_missing_plugin_message_get_description(msg: [*c]Msg) [*c]c.gchar {
    if (!check.that(gst_is_missing_plugin_message(msg) != 0, "gst_missing_plugin_message_get_description", "gst_is_missing_plugin_message (msg)")) return null;
    const st = c.gst_message_get_structure(msg);
    const name = c.gst_structure_get_string(st, "name");
    if (name != null and name[0] != 0) return c.g_strdup(name);
    const k = kindOf(st);
    var r: [*c]u8 = null;
    switch (k) {
        .urisource, .urisink, .element => if (stringDetail(st)) |d| {
            r = switch (k) {
                .urisource => desc.gst_pb_utils_get_source_description(d),
                .urisink => desc.gst_pb_utils_get_sink_description(d),
                else => desc.gst_pb_utils_get_element_description(d),
            };
            c.g_free(d);
        },
        .decoder, .encoder => if (capsDetail(st)) |caps| {
            r = if (k == .decoder) desc.gst_pb_utils_get_decoder_description(caps) else desc.gst_pb_utils_get_encoder_description(caps);
            c.gst_caps_unref(caps);
        },
        .unknown => {},
    }
    if (r != null) return r;
    return c.g_strdup(init.tr(switch (k) {
        .urisource => "Unknown source element",
        .urisink => "Unknown sink element",
        .element => "Unknown element",
        .decoder => "Unknown decoder element",
        .encoder => "Unknown encoder element",
        .unknown => "Plugin or element of unknown type",
    }));
}

pub export fn gst_is_missing_plugin_message(msg: [*c]Msg) c.gboolean {
    if (!check.that(msg != null, "gst_is_missing_plugin_message", "msg != NULL")) return 0;
    if (!check.that(check.isMessage(msg), "gst_is_missing_plugin_message", "GST_IS_MESSAGE (msg)")) return 0;
    const st = c.gst_message_get_structure(msg);
    if (msg[0].type != c.GST_MESSAGE_ELEMENT or st == null) return 0;
    return c.gst_structure_has_name(st, "missing-plugin");
}

fn detailNew(d: [*c]u8, kind: [*c]const u8, detail: [*c]const u8) [*c]c.gchar {
    const s = header(d);
    c.g_free(d);
    c.g_string_append_printf(s, "%s-%s", kind, detail);
    return c.g_string_free(s, 0);
}

pub export fn gst_missing_uri_source_installer_detail_new(protocol: [*c]const c.gchar) [*c]c.gchar {
    if (!check.that(protocol != null, "gst_missing_uri_source_installer_detail_new", "protocol != NULL")) return null;
    return detailNew(desc.gst_pb_utils_get_source_description(protocol), "urisource", protocol);
}

pub export fn gst_missing_uri_sink_installer_detail_new(protocol: [*c]const c.gchar) [*c]c.gchar {
    if (!check.that(protocol != null, "gst_missing_uri_sink_installer_detail_new", "protocol != NULL")) return null;
    return detailNew(desc.gst_pb_utils_get_sink_description(protocol), "urisink", protocol);
}

pub export fn gst_missing_element_installer_detail_new(factory_name: [*c]const c.gchar) [*c]c.gchar {
    if (!check.that(factory_name != null, "gst_missing_element_installer_detail_new", "factory_name != NULL")) return null;
    return detailNew(desc.gst_pb_utils_get_element_description(factory_name), "element", factory_name);
}

fn capsDetailNew(caps: [*c]const Caps, d: [*c]u8, kind: [*c]const u8) [*c]c.gchar {
    const clean = desc.cleanCaps(caps);
    const cs = c.gst_caps_to_string(clean);
    const r = detailNew(d, kind, cs);
    c.g_free(cs);
    c.gst_caps_unref(clean);
    return r;
}

pub export fn gst_missing_decoder_installer_detail_new(decode_caps: [*c]const Caps) [*c]c.gchar {
    if (!validCaps(decode_caps, "gst_missing_decoder_installer_detail_new", "decode_caps")) return null;
    return capsDetailNew(decode_caps, desc.gst_pb_utils_get_decoder_description(decode_caps), "decoder");
}

pub export fn gst_missing_encoder_installer_detail_new(encode_caps: [*c]const Caps) [*c]c.gchar {
    if (!validCaps(encode_caps, "gst_missing_encoder_installer_detail_new", "encode_caps")) return null;
    return capsDetailNew(encode_caps, desc.gst_pb_utils_get_encoder_description(encode_caps), "encoder");
}
