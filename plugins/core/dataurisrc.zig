const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstdataurisrc.c";
const DOMAIN = "gstreamer-1.0";
const PROP_URI = 1;

const Self = extern struct {
    parent: c.GstBaseSrc,
    uri: [*c]u8,
    buffer: [*c]c.GstBuffer,
};

const Class = extern struct {
    parent: c.GstBaseSrcClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstBaseSrcClass = null;
var protocols = [_][*c]const u8{ "data", null };

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn base(p: anytype) [*c]c.GstBaseSrc {
    return @ptrCast(@alignCast(p));
}

fn getCaps(b: [*c]c.GstBaseSrc, _: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    cm.lock(b);
    defer cm.unlock(b);
    const caps = c.gst_pad_get_current_caps(b[0].srcpad);
    return if (caps != null) caps else c.gst_caps_new_any();
}

fn getSize(b: [*c]c.GstBaseSrc, size: [*c]u64) callconv(.c) c.gboolean {
    const s = me(b);
    cm.lock(s);
    defer cm.unlock(s);
    if (s.buffer == null) {
        size[0] = cm.CLOCK_NONE;
        return 0;
    }
    size[0] = c.gst_buffer_get_size(s.buffer);
    return 1;
}

fn isSeekable(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 1;
}

fn create(b: [*c]c.GstBaseSrc, off: u64, size: c.guint, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    cm.lock(s);
    if (s.buffer == null) {
        cm.unlock(s);
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, null, null, FILE, "gst_data_uri_src_create", 259);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    defer cm.unlock(s);
    if (off + size > c.gst_buffer_get_size(s.buffer)) return c.GST_FLOW_EOS;
    if (out[0] != null) {
        var info: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(s.buffer, &info, c.GST_MAP_READ);
        const n = c.gst_buffer_fill(out[0], 0, info.data + off, size);
        c.gst_buffer_unmap(s.buffer, &info);
        c.gst_buffer_set_size(out[0], @intCast(n));
    } else out[0] = c.gst_buffer_copy_region(s.buffer, c.GST_BUFFER_COPY_ALL, off, size);
    return c.GST_FLOW_OK;
}

fn start(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    cm.lock(s);
    const ok = s.uri != null and s.uri[0] != 0 and s.buffer != null;
    cm.unlock(s);
    if (!ok) cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup(cm.tr(DOMAIN, "No valid data URI specified, or the data URI could not be parsed.")), c.g_strdup_printf("%s", s.uri), FILE, "gst_data_uri_src_start", 282);
    return @intFromBool(ok);
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SRC;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return @ptrCast(&protocols);
}

fn getUri(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    const s = me(h);
    cm.lock(s);
    defer cm.unlock(s);
    return c.g_strdup(s.uri);
}

const Params = struct {
    base64: bool = false,
    charset: [*c]u8 = null,
};

fn parseParams(from: [*c]const u8, to: [*c]const u8) Params {
    var p: Params = .{};
    const all = c.g_strndup(from, @intCast(to - from));
    const parts = c.g_strsplit(all, ";", -1);
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) {
        if (c.strcmp("base64", parts[i]) == 0) {
            p.base64 = true;
        } else if (c.strncmp("charset=", parts[i], 8) == 0) {
            c.g_free(p.charset);
            p.charset = c.g_strdup(parts[i] + 8);
        }
    }
    c.g_free(all);
    c.g_strfreev(parts);
    return p;
}

fn setUri(h: ?*c.GstURIHandler, orig: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const s = me(h);
    cm.lock(s);
    if (@as(*c.GstElement, @ptrCast(@alignCast(s))).current_state >= c.GST_STATE_PAUSED) {
        cm.unlock(s);
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_STATE, "Changing the 'uri' property on dataurisrc while it is running is not supported");
        return 0;
    }
    cm.unlock(s);
    if (orig == null or c.g_ascii_strncasecmp("data:", orig, 5) != 0) return badUri(err, "Invalid data URI");
    const uri = orig + 5;
    var params: [*c]const u8 = c.strchr(uri, ';');
    const comma: [*c]const u8 = c.strchr(uri, ',');
    if (comma == null) return badUri(err, "Invalid data URI");
    if (params != null and params > comma) params = null;
    const mime = if (comma != uri and params != uri) c.g_strndup(uri, @intCast((if (params != null) params else comma) - uri)) else c.g_strdup("text/plain");
    defer c.g_free(mime);
    const p: Params = if (params != null) parseParams(params + 1, comma) else .{};
    defer c.g_free(p.charset);
    var size: c.gsize = 0;
    var data: c.gpointer = undefined;
    if (p.base64) {
        data = c.g_base64_decode(comma + 1, &size);
    } else {
        const raw = c.g_uri_unescape_string(comma + 1, null);
        if (raw == null) return badUri(err, "Could not parse data encoded in data URI");
        size = c.strlen(raw);
        data = raw;
    }
    if (c.strcmp("text/plain", mime) == 0 and p.charset != null and c.g_ascii_strcasecmp("US-ASCII", p.charset) != 0 and c.g_ascii_strcasecmp("UTF-8", p.charset) != 0) {
        var read: c.gsize = 0;
        var written: c.gsize = 0;
        const conv = c.g_convert_with_fallback(@ptrCast(data), @intCast(size), "UTF-8", p.charset, @constCast("*"), &read, &written, null);
        c.g_free(data);
        data = conv;
        size = written;
    }
    const b = c.gst_buffer_new_wrapped(data, size);
    var caps = c.gst_type_find_helper_for_buffer(cm.obj(s), b, null);
    if (caps == null) caps = c.gst_caps_new_empty_simple(mime);
    _ = c.gst_base_src_set_caps(base(s), caps);
    c.gst_mini_object_unref(@ptrCast(caps));
    cm.lock(s);
    _ = c.gst_mini_object_replace(@ptrCast(&s.buffer), @ptrCast(b));
    c.gst_buffer_unref(b);
    c.g_free(s.uri);
    s.uri = c.g_strdup(orig);
    cm.unlock(s);
    return 1;
}

fn badUri(err: [*c][*c]c.GError, msg: [*c]const u8) c.gboolean {
    c.g_set_error_literal(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, msg);
    return 0;
}

fn uriInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(g));
    i.get_type = uriType;
    i.get_protocols = uriProtocols;
    i.get_uri = getUri;
    i.set_uri = setUri;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_URI => _ = setUri(@ptrCast(o), c.g_value_get_string(v), null),
        else => cm.warnInvalid(FILE, o, id, spec, 154),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_URI => c.g_value_take_string(v, getUri(@ptrCast(o))),
        else => cm.warnInvalid(FILE, o, id, spec, 171),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.uri);
    s.uri = null;
    if (s.buffer != null) c.gst_buffer_unref(s.buffer);
    s.buffer = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_URI, c.g_param_spec_string("uri", "URI", "URI that should be used", null, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "data: URI source element", "Source", "Handles data: uris", "Philippe Normand <pnormand@igalia.com>, Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    _ = c._gst_debug_category_new("dataurisrc", 0, "data: URI source");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.get_caps = getCaps;
    bc.get_size = getSize;
    bc.is_seekable = isSeekable;
    bc.create = create;
    bc.start = start;
}

fn init(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_src_get_type(), "GstDataURISrc", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "dataurisrc", c.GST_RANK_PRIMARY, getType()) != 0;
}
