const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const core = @import("core.zig");
const feature = @import("pluginfeature.zig");
const factory = @import("elementfactory.zig");
const registry = @import("registry.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Handler = c.GstURIHandler;
const Iface = c.GstURIHandlerInterface;

var type_once: gtype.Once = .{};
var debug_cat: [*c]c.GstDebugCategory = null;

const UNSAFE_ALL = 0x1;
const UNSAFE_ALLOW_PLUS = 0x2;
const UNSAFE_PATH = 0x4;
const UNSAFE_DOS_PATH = 0x8;
const UNSAFE_HOST = 0x10;
const UNSAFE_SLASHES = 0x20;

const acceptable = [96]u8{
    0x00, 0x3F, 0x20, 0x20, 0x20, 0x00, 0x2C, 0x3F, 0x3F, 0x3F, 0x3F, 0x22, 0x20, 0x3F, 0x3F, 0x1C,
    0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x38, 0x20, 0x20, 0x2C, 0x20, 0x2C,
    0x30, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F,
    0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x20, 0x20, 0x20, 0x20, 0x3F,
    0x20, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F,
    0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x20, 0x20, 0x20, 0x3F, 0x20,
};

const HEX = "0123456789ABCDEF";

pub export fn gst_uri_handler_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = c.g_type_register_static_simple(c.G_TYPE_INTERFACE, "GstURIHandler", @sizeOf(Iface), null, 0, null, 0);
            debug_cat = info._gst_debug_category_new("GST_URI", c.GST_DEBUG_BOLD, "handling of URIs");
            return t;
        }
    }.f);
}

pub export fn gst_uri_error_quark() c.GQuark {
    return c.g_quark_from_static_string("gst-uri-error-quark");
}

fn tr(s: [*c]const u8) [*c]const u8 {
    return c.g_dgettext("gstreamer-1.0", s);
}

fn okChar(ch: u8, mask: u8) bool {
    return ch >= 32 and ch < 128 and acceptable[ch - 32] & mask != 0;
}

pub fn escape(s: [*c]const u8, mask: u8) [*c]u8 {
    if (s == null) return null;
    const in = std.mem.span(s);
    var bad: usize = 0;
    var m = mask;
    for (in) |ch| {
        if (!okChar(ch, m)) bad += 1;
        if (m == UNSAFE_HOST and (bad != 0 or ch == '/')) m = UNSAFE_PATH;
    }
    const out: [*]u8 = @ptrCast(c.g_malloc(in.len + bad * 2 + 1));
    var q: usize = 0;
    m = mask;
    for (in) |ch| {
        if (!okChar(ch, m)) {
            out[q] = '%';
            out[q + 1] = HEX[ch >> 4];
            out[q + 2] = HEX[ch & 15];
            q += 3;
        } else {
            out[q] = ch;
            q += 1;
        }
        if (m == UNSAFE_HOST and (!okChar(ch, m) or ch == '/')) m = UNSAFE_PATH;
    }
    out[q] = 0;
    return out;
}

fn hexVal(ch: u8) i32 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'A'...'F' => ch - 'A' + 10,
        'a'...'f' => ch - 'a' + 10,
        else => -1,
    };
}

pub fn unescape(s: [*c]const u8, illegal: ?[]const u8) [*c]u8 {
    if (s == null) return null;
    const in = std.mem.span(s);
    const out: [*]u8 = @ptrCast(c.g_malloc(in.len + 1));
    var i: usize = 0;
    var q: usize = 0;
    while (i < in.len) : (i += 1) {
        var ch: i32 = in[i];
        if (in[i] == '%') {
            const hi = if (i + 1 < in.len) hexVal(in[i + 1]) else -1;
            const lo = if (hi >= 0 and i + 2 < in.len) hexVal(in[i + 2]) else -1;
            ch = if (hi < 0 or lo < 0) -1 else (hi << 4) | lo;
            if (ch <= 0 or (illegal != null and std.mem.indexOfScalar(u8, illegal.?, @intCast(ch)) != null)) {
                c.g_free(out);
                return null;
            }
            i += 2;
        }
        out[q] = @intCast(ch);
        q += 1;
    }
    out[q] = 0;
    return out;
}

fn schemeEnd(s: [*c]const u8) usize {
    var i: usize = 0;
    if (std.ascii.isAlphabetic(s[0])) {
        i = 1;
        while (std.ascii.isAlphanumeric(s[i]) or s[i] == '+' or s[i] == '-' or s[i] == '.') i += 1;
    }
    return i;
}

pub export fn gst_uri_protocol_is_valid(protocol: [*c]const u8) c.gboolean {
    if (!check.that(protocol != null, "gst_uri_protocol_is_valid", "protocol != NULL")) return 0;
    const n = schemeEnd(protocol);
    return @intFromBool(protocol[n] == 0 and n >= 2);
}

pub export fn gst_uri_is_valid(uri: [*c]const u8) c.gboolean {
    if (!check.that(uri != null, "gst_uri_is_valid", "uri != NULL")) return 0;
    const n = schemeEnd(uri);
    return @intFromBool(uri[n] == ':' and n >= 2);
}

pub export fn gst_uri_get_protocol(uri: [*c]const u8) [*c]u8 {
    if (gst_uri_is_valid(uri) == 0) return null;
    const colon = c.strstr(uri, ":");
    return c.g_ascii_strdown(uri, @intCast(@intFromPtr(colon) - @intFromPtr(uri)));
}

pub export fn gst_uri_has_protocol(uri: [*c]const u8, protocol: [*c]const u8) c.gboolean {
    if (!check.that(protocol != null, "gst_uri_has_protocol", "protocol != NULL")) return 0;
    if (gst_uri_is_valid(uri) == 0) return 0;
    const colon = c.strstr(uri, ":");
    if (colon == null) return 0;
    return @intFromBool(c.g_ascii_strncasecmp(uri, protocol, @intFromPtr(colon) - @intFromPtr(uri)) == 0);
}

pub export fn gst_uri_get_location(uri: [*c]const u8) [*c]u8 {
    if (gst_uri_is_valid(uri) == 0) return null;
    const sep = c.strstr(uri, "://");
    if (sep == null) return null;
    return unescape(sep + 3, "/");
}

pub export fn gst_uri_construct(protocol: [*c]const u8, location: [*c]const u8) [*c]u8 {
    if (!check.that(gst_uri_protocol_is_valid(protocol) != 0, "gst_uri_construct", "gst_uri_protocol_is_valid (protocol)")) return null;
    if (!check.that(location != null, "gst_uri_construct", "location != NULL")) return null;
    const lower = c.g_ascii_strdown(protocol, -1);
    const esc = escape(location, UNSAFE_PATH);
    const r = c.g_strdup_printf("%s://%s", lower, esc);
    c.g_free(esc);
    c.g_free(lower);
    return r;
}

const Search = struct { kind: c.GstURIType, protocol: [*c]const u8 };

fn searchFilter(f: ?*c.GstPluginFeature, data: c.gpointer) callconv(.c) c.gboolean {
    if (!factory.isFactory(f)) return 0;
    const s: *Search = @ptrCast(@alignCast(data));
    const ef = factory.of(f);
    if (ef[0].uri_type != s.kind) return 0;
    const protos = ef[0].uri_protocols;
    if (protos == null) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Factory '%s' implements GstUriHandler interface but returned no supported protocols!", feature.nameOf(f));
        return 0;
    }
    var p = protos;
    while (p[0] != null) : (p += 1) if (c.g_ascii_strcasecmp(p[0], s.protocol) == 0) return 1;
    return 0;
}

fn byRank(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const fa = feature.of(@constCast(a));
    const fb = feature.of(@constCast(b));
    const diff = @as(c.gint, @bitCast(fb[0].rank)) -% @as(c.gint, @bitCast(fa[0].rank));
    if (diff != 0) return diff;
    return c.g_strcmp0(feature.nameOf(fa), feature.nameOf(fb));
}

fn factoriesFor(kind: c.GstURIType, protocol: [*c]const u8) ?*c.GList {
    if (!check.that(protocol != null, "get_element_factories_from_uri_protocol", "protocol")) return null;
    var s = Search{ .kind = kind, .protocol = protocol };
    return registry.gst_registry_feature_filter(registry.gst_registry_get(), searchFilter, 0, &s);
}

pub export fn gst_uri_protocol_is_supported(kind: c.GstURIType, protocol: [*c]const u8) c.gboolean {
    if (!check.that(protocol != null, "gst_uri_protocol_is_supported", "protocol")) return 0;
    const l = factoriesFor(kind, protocol);
    if (l == null) return 0;
    c.g_list_free(l);
    return 1;
}

fn validType(t: c.GstURIType) bool {
    return t == c.GST_URI_SRC or t == c.GST_URI_SINK;
}

pub export fn gst_element_make_from_uri(kind: c.GstURIType, uri: [*c]const u8, name: [*c]const u8, err: [*c][*c]c.GError) [*c]c.GstElement {
    const f = "gst_element_make_from_uri";
    if (!check.that(core.gst_is_initialized() != 0, f, "gst_is_initialized ()")) return null;
    if (!check.that(validType(kind), f, "GST_URI_TYPE_IS_VALID (type)")) return null;
    if (!check.that(err == null or err.* == null, f, "error == NULL || *error == NULL")) return null;
    if (gst_uri_is_valid(uri) == 0) {
        c.g_set_error(err, gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, tr("Invalid URI: %s"), uri);
        return null;
    }
    const proto = gst_uri_get_protocol(uri);
    var list = factoriesFor(kind, proto);
    if (list == null) {
        c.g_set_error(err, gst_uri_error_quark(), c.GST_URI_ERROR_UNSUPPORTED_PROTOCOL, tr("No URI handler for the %s protocol found"), proto);
        c.g_free(proto);
        return null;
    }
    c.g_free(proto);
    list = c.g_list_sort(list, byRank);
    var ret: [*c]c.GstElement = null;
    var w = list;
    while (w) |n| : (w = n.next) {
        var uerr: [*c]c.GError = null;
        ret = factory.gst_element_factory_create(@ptrCast(@alignCast(n.data)), name);
        if (ret == null) continue;
        if (gst_uri_handler_set_uri(@ptrCast(ret), uri, &uerr) != 0) break;
        if (err != null and err.* == null) c.g_propagate_error(err, uerr) else c.g_error_free(uerr);
        c.gst_object_unref(ret);
        ret = null;
    }
    feature.gst_plugin_feature_list_free(list);
    if (ret != null) c.g_clear_error(err);
    return ret;
}

fn isHandler(h: anytype) bool {
    return gtype.instanceOf(h, gst_uri_handler_get_type());
}

fn ifaceOf(h: ?*Handler) ?*Iface {
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(h));
    return @ptrCast(@alignCast(c.g_type_interface_peek(inst.g_class, gst_uri_handler_get_type())));
}

fn typeOf(h: ?*Handler) c.GType {
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(h));
    return inst.g_class.*.g_type;
}

pub export fn gst_uri_handler_get_uri_type(h: ?*Handler) c.GstURIType {
    const f = "gst_uri_handler_get_uri_type";
    if (!check.that(isHandler(h), f, "GST_IS_URI_HANDLER (handler)")) return c.GST_URI_UNKNOWN;
    const i = ifaceOf(h);
    if (!check.that(i != null, f, "iface != NULL")) return c.GST_URI_UNKNOWN;
    if (!check.that(i.?.get_type != null, f, "iface->get_type != NULL")) return c.GST_URI_UNKNOWN;
    const r = i.?.get_type.?(typeOf(h));
    if (!check.that(validType(r), f, "GST_URI_TYPE_IS_VALID (ret)")) return c.GST_URI_UNKNOWN;
    return r;
}

pub export fn gst_uri_handler_get_protocols(h: ?*Handler) [*c]const [*c]const u8 {
    const f = "gst_uri_handler_get_protocols";
    if (!check.that(isHandler(h), f, "GST_IS_URI_HANDLER (handler)")) return null;
    const i = ifaceOf(h);
    if (!check.that(i != null, f, "iface != NULL")) return null;
    if (!check.that(i.?.get_protocols != null, f, "iface->get_protocols != NULL")) return null;
    const r = i.?.get_protocols.?(typeOf(h));
    if (!check.that(r != null, f, "ret != NULL")) return null;
    return r;
}

pub export fn gst_uri_handler_get_uri(h: ?*Handler) [*c]u8 {
    const f = "gst_uri_handler_get_uri";
    if (!check.that(isHandler(h), f, "GST_IS_URI_HANDLER (handler)")) return null;
    const i = ifaceOf(h);
    if (!check.that(i != null, f, "iface != NULL")) return null;
    if (!check.that(i.?.get_uri != null, f, "iface->get_uri != NULL")) return null;
    const r = i.?.get_uri.?(h);
    if (r != null and !check.that(gst_uri_is_valid(r) != 0, f, "gst_uri_is_valid (ret)")) return null;
    return r;
}

pub export fn gst_uri_handler_set_uri(h: ?*Handler, uri: [*c]const u8, err: [*c][*c]c.GError) c.gboolean {
    const f = "gst_uri_handler_set_uri";
    if (!check.that(isHandler(h), f, "GST_IS_URI_HANDLER (handler)")) return 0;
    if (!check.that(err == null or err.* == null, f, "error == NULL || *error == NULL")) return 0;
    const i = ifaceOf(h);
    if (!check.that(i != null, f, "iface != NULL")) return 0;
    if (!check.that(i.?.set_uri != null, f, "iface->set_uri != NULL")) return 0;
    if (gst_uri_is_valid(uri) == 0) {
        c.g_set_error(err, gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, tr("Invalid URI: %s"), uri);
        return 0;
    }
    const proto = gst_uri_get_protocol(uri);
    defer c.g_free(proto);
    if (i.?.get_protocols) |gp| {
        const protos = gp(typeOf(h));
        if (protos != null) {
            var found = false;
            var p = protos;
            while (p[0] != null) : (p += 1) if (c.g_ascii_strcasecmp(proto, p[0]) == 0) {
                found = true;
                break;
            };
            if (!found) {
                c.g_set_error(err, gst_uri_error_quark(), c.GST_URI_ERROR_UNSUPPORTED_PROTOCOL, tr("URI scheme '%s' not supported"), proto);
                return 0;
            }
        }
    }
    return i.?.set_uri.?(h, uri, err);
}

fn canonical(path: [*c]const u8) [*c]u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(std.heap.c_allocator);
    var it = std.mem.splitScalar(u8, std.mem.span(path), '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..") and parts.items.len > 0) {
            _ = parts.pop();
            continue;
        }
        parts.append(std.heap.c_allocator, seg) catch return null;
    }
    const n = parts.items.len + @as(usize, if (path[0] == '/') 1 else 0);
    const arr: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc0((n + 1) * @sizeOf([*c]u8))));
    var k: usize = 0;
    if (path[0] == '/') {
        arr[0] = c.g_strdup("/");
        k = 1;
    }
    for (parts.items) |seg| {
        arr[k] = c.g_strndup(seg.ptr, seg.len);
        k += 1;
    }
    const r = c.g_build_filenamev(arr);
    c.g_strfreev(arr);
    return r;
}

fn hasRelatives(p: [*c]const u8) bool {
    return c.strstr(p, "/./") != null or c.strstr(p, "/../") != null;
}

pub export fn gst_filename_to_uri(filename: [*c]const u8, err: [*c][*c]c.GError) [*c]u8 {
    if (!check.that(filename != null, "gst_filename_to_uri", "filename != NULL")) return null;
    if (!check.that(err == null or err.* == null, "gst_filename_to_uri", "error == NULL || *error == NULL")) return null;
    var abs: [*c]u8 = null;
    defer c.g_free(abs);
    if (c.g_path_is_absolute(filename) != 0) {
        if (!hasRelatives(filename)) return c.g_filename_to_uri(filename, null, err);
        abs = c.g_strdup(filename);
    } else {
        const cwd = c.g_get_current_dir();
        abs = c.g_build_filename(cwd, filename, @as([*c]const u8, null));
        c.g_free(cwd);
        if (!hasRelatives(abs)) return c.g_filename_to_uri(abs, null, err);
    }
    const clean = canonical(abs);
    defer c.g_free(clean);
    return c.g_filename_to_uri(clean, null, err);
}
