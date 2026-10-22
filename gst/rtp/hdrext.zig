const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const buf = @import("buffer.zig");
const that = buf.that;

comptime {
    @import("../abi.zig").check(@This());
}

const Ext = c.GstRTPHeaderExtension;
const Class = c.GstRTPHeaderExtensionClass;
const MAX_ID = 256;
const URI_KEY = c.GST_RTP_HEADER_EXTENSION_URI_METADATA_KEY;
const DEFAULT: c.GstRTPHeaderExtensionDirection = c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDRECV | c.GST_RTP_HEADER_EXTENSION_DIRECTION_INHERITED;

const Private = struct {
    id: c.guint,
    wants_update: c.gboolean,
    direction: c.GstRTPHeaderExtensionDirection,
};

var once: gtype.Once = .{};
var offset: c.gint = 0;
var cat: [*c]c.GstDebugCategory = null;

fn priv(e: anytype) *Private {
    const p: [*]u8 = @ptrCast(@constCast(e));
    return @ptrCast(@alignCast(p + @as(usize, @bitCast(@as(isize, offset)))));
}

fn klass(e: anytype) *Class {
    return gtype.classPeek(Class, e);
}

fn isExt(e: anytype) bool {
    return gtype.instanceOf(e, gst_rtp_header_extension_get_type());
}

fn isCaps(caps: anytype) bool {
    return caps != null and @as(*const c.GstMiniObject, @ptrCast(@alignCast(caps))).type == c.gst_caps_get_type();
}

fn warn(e: ?*anyopaque, text: [*c]const u8) void {
    c.gst_debug_log(cat, c.GST_LEVEL_WARNING, "../gst-libs/gst/rtp/gstrtphdrext.c", "gst_rtp_header_extension_set_attributes_from_caps", 0, @ptrCast(@alignCast(e)), "%s", text);
}

pub export fn gst_rtp_hdrext_set_ntp_64(data: c.gpointer, size: c.guint, ntp: c.guint64) c.gboolean {
    const f = "gst_rtp_hdrext_set_ntp_64";
    if (!that(data != null, f, "data != NULL")) return 0;
    if (!that(size >= c.GST_RTP_HDREXT_NTP_64_SIZE, f, "size >= GST_RTP_HDREXT_NTP_64_SIZE")) return 0;
    const d: *[8]u8 = @ptrCast(data);
    std.mem.writeInt(u64, d, ntp, .big);
    return 1;
}

pub export fn gst_rtp_hdrext_get_ntp_64(data: c.gpointer, size: c.guint, ntp: [*c]c.guint64) c.gboolean {
    const f = "gst_rtp_hdrext_get_ntp_64";
    if (!that(data != null, f, "data != NULL")) return 0;
    if (!that(size >= c.GST_RTP_HDREXT_NTP_64_SIZE, f, "size >= GST_RTP_HDREXT_NTP_64_SIZE")) return 0;
    const d: *const [8]u8 = @ptrCast(data);
    if (ntp != null) ntp.* = std.mem.readInt(u64, d, .big);
    return 1;
}

pub export fn gst_rtp_hdrext_set_ntp_56(data: c.gpointer, size: c.guint, ntp: c.guint64) c.gboolean {
    const f = "gst_rtp_hdrext_set_ntp_56";
    if (!that(data != null, f, "data != NULL")) return 0;
    if (!that(size >= c.GST_RTP_HDREXT_NTP_56_SIZE, f, "size >= GST_RTP_HDREXT_NTP_56_SIZE")) return 0;
    const d: *[7]u8 = @ptrCast(data);
    std.mem.writeInt(u56, d, @truncate(ntp), .big);
    return 1;
}

pub export fn gst_rtp_hdrext_get_ntp_56(data: c.gpointer, size: c.guint, ntp: [*c]c.guint64) c.gboolean {
    const f = "gst_rtp_hdrext_get_ntp_56";
    if (!that(data != null, f, "data != NULL")) return 0;
    if (!that(size >= c.GST_RTP_HDREXT_NTP_56_SIZE, f, "size >= GST_RTP_HDREXT_NTP_56_SIZE")) return 0;
    const d: *const [7]u8 = @ptrCast(data);
    if (ntp != null) ntp.* = std.mem.readInt(u56, d, .big);
    return 1;
}

pub export fn gst_rtp_header_extension_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstRTPHeaderExtension", Class, Ext, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            cat = c._gst_debug_category_new("rtphdrext", 0, "RTP Header Extensions");
            return t;
        }
    }.f);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(k, &offset);
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.set_caps_from_attributes = defaultCapsFromAttributes;
}

fn init(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = priv(instance);
    p.* = .{ .id = std.math.maxInt(u32), .wants_update = 0, .direction = DEFAULT };
}

pub export fn gst_rtp_header_extension_class_set_uri(k: [*c]Class, uri: [*c]const u8) void {
    c.gst_element_class_add_metadata(@ptrCast(k), URI_KEY, uri);
}

pub export fn gst_rtp_header_extension_get_uri(e: [*c]Ext) [*c]const u8 {
    if (!that(isExt(e), "gst_rtp_header_extension_get_uri", "GST_IS_RTP_HEADER_EXTENSION (ext)")) return null;
    return c.gst_element_class_get_metadata(@ptrCast(klass(e)), URI_KEY);
}

pub export fn gst_rtp_header_extension_get_supported_flags(e: [*c]Ext) c.GstRTPHeaderExtensionFlags {
    const f = "gst_rtp_header_extension_get_supported_flags";
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    const k = klass(e);
    if (!that(k.get_supported_flags != null, f, "klass->get_supported_flags != NULL")) return 0;
    return k.get_supported_flags.?(e);
}

pub export fn gst_rtp_header_extension_get_max_size(e: [*c]Ext, meta: [*c]const c.GstBuffer) c.gsize {
    const f = "gst_rtp_header_extension_get_max_size";
    if (!that(buf.isBuffer(meta), f, "GST_IS_BUFFER (input_meta)")) return 0;
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    const k = klass(e);
    if (!that(k.get_max_size != null, f, "klass->get_max_size != NULL")) return 0;
    return k.get_max_size.?(e, meta);
}

pub export fn gst_rtp_header_extension_write(e: [*c]Ext, meta: [*c]const c.GstBuffer, flags: c.GstRTPHeaderExtensionFlags, out: [*c]c.GstBuffer, data: [*c]u8, size: c.gsize) c.gssize {
    const f = "gst_rtp_header_extension_write";
    if (!that(buf.isBuffer(meta), f, "GST_IS_BUFFER (input_meta)")) return -1;
    if (!that(buf.isBuffer(out), f, "GST_IS_BUFFER (output)")) return -1;
    if (!that(buf.writable(out), f, "gst_buffer_is_writable (output)")) return -1;
    if (!that(data != null, f, "data != NULL")) return -1;
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return -1;
    if (!that(priv(e).id <= MAX_ID, f, "priv->ext_id <= MAX_RTP_EXT_ID")) return -1;
    const k = klass(e);
    if (!that(k.write != null, f, "klass->write != NULL")) return -1;
    return k.write.?(e, meta, flags, out, data, size);
}

pub export fn gst_rtp_header_extension_read(e: [*c]Ext, flags: c.GstRTPHeaderExtensionFlags, data: [*c]const u8, size: c.gsize, b: [*c]c.GstBuffer) c.gboolean {
    const f = "gst_rtp_header_extension_read";
    if (!that(buf.isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return 0;
    if (!that(buf.writable(b), f, "gst_buffer_is_writable (buffer)")) return 0;
    if (!that(data != null, f, "data != NULL")) return 0;
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    if (!that(priv(e).id <= MAX_ID, f, "priv->ext_id <= MAX_RTP_EXT_ID")) return 0;
    const k = klass(e);
    if (!that(k.read != null, f, "klass->read != NULL")) return 0;
    return k.read.?(e, flags, data, size, b);
}

pub export fn gst_rtp_header_extension_get_id(e: [*c]Ext) c.guint {
    if (!that(isExt(e), "gst_rtp_header_extension_get_id", "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    return priv(e).id;
}

pub export fn gst_rtp_header_extension_set_id(e: [*c]Ext, id: c.guint) void {
    const f = "gst_rtp_header_extension_set_id";
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return;
    if (!that(id < MAX_ID, f, "ext_id < MAX_RTP_EXT_ID")) return;
    priv(e).id = id;
}

fn same(a: [*c]const u8, b: [*c]const u8) bool {
    if (a == null or b == null) return a == b;
    return c.g_ascii_strcasecmp(a, b) == 0;
}

fn typeName(v: [*c]const c.GValue) [*c]const u8 {
    return c.g_type_name(v[0].g_type);
}

const directions = [_]struct { n: [*:0]const u8, d: c.GstRTPHeaderExtensionDirection }{
    .{ .n = "", .d = DEFAULT },
    .{ .n = "sendrecv", .d = c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDRECV },
    .{ .n = "sendonly", .d = c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDONLY },
    .{ .n = "recvonly", .d = c.GST_RTP_HEADER_EXTENSION_DIRECTION_RECVONLY },
    .{ .n = "inactive", .d = c.GST_RTP_HEADER_EXTENSION_DIRECTION_INACTIVE },
};

fn isString(v: [*c]const c.GValue) bool {
    return v != null and c.g_type_check_value_holds(@constCast(v), c.G_TYPE_STRING) != 0;
}

fn arrayMember(e: [*c]Ext, v: [*c]const c.GValue, comptime which: []const u8) ?[*c]const u8 {
    if (isString(v)) return c.g_value_get_string(v);
    const t = c.g_strdup_printf("Caps should hold an array of 3 strings, but " ++ which ++ " member is %s instead", typeName(v));
    defer c.g_free(t);
    warn(e, t);
    return null;
}

pub export fn gst_rtp_header_extension_set_attributes_from_caps(e: [*c]Ext, caps: ?*const c.GstCaps) c.gboolean {
    const f = "gst_rtp_header_extension_set_attributes_from_caps";
    if (!that(isCaps(caps), f, "GST_IS_CAPS (caps)")) return 0;
    if (!that(c.gst_caps_is_fixed(caps) != 0, f, "gst_caps_is_fixed (caps)")) return 0;
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    const p = priv(e);
    if (!that(p.id <= MAX_ID, f, "priv->ext_id <= MAX_RTP_EXT_ID")) return 0;
    const k = klass(e);
    const s = c.gst_caps_get_structure(caps, 0);
    if (!that(s != null, f, "structure != NULL")) return 0;
    const field = c.g_strdup_printf("extmap-%u", p.id);
    defer c.g_free(field);
    if (!that(c.gst_structure_has_field(s, field) != 0, f, "gst_structure_has_field (structure, field_name)")) return 0;
    const v = c.gst_structure_get_value(s, field);
    var direction = DEFAULT;
    var attributes: [*c]const u8 = "";
    const uri = gst_rtp_header_extension_get_uri(e);
    if (isString(v)) {
        const got = c.g_value_get_string(v);
        if (!same(got, uri)) {
            const t = c.g_strdup_printf("Field %s, URI doesn't match RTP Header extension:  \"%s\", expected \"%s\"", field, got, uri);
            defer c.g_free(t);
            warn(e, t);
            return 0;
        }
    } else if (c.g_type_check_value_holds(@constCast(v), c.gst_value_array_get_type()) != 0 and c.gst_value_array_get_size(v) == 3) {
        const dir = arrayMember(e, c.gst_value_array_get_value(v, 0), "first") orelse return 0;
        const hit = for (directions) |d| {
            if (same(dir, d.n)) break d.d;
        } else {
            const t = c.g_strdup_printf("Unexpected direction \"%s\", expected one of: sendrecv, sendonly, recvonly or inactive", dir);
            defer c.g_free(t);
            warn(e, t);
            return 0;
        };
        direction = hit;
        const got = arrayMember(e, c.gst_value_array_get_value(v, 1), "second") orelse return 0;
        if (!same(got, uri)) {
            const t = c.g_strdup_printf("URI doesn't match RTP Header extension: \"%s\", expected \"%s\"", got, uri);
            defer c.g_free(t);
            warn(e, t);
            return 0;
        }
        attributes = arrayMember(e, c.gst_value_array_get_value(v, 2), "third") orelse return 0;
    } else {
        const t = c.g_strdup_printf("Caps field %s should be either a string containing the URI or an array of 3 strings containing the direction, URI and attributes, but contains %s", field, typeName(v));
        defer c.g_free(t);
        warn(e, t);
        return 0;
    }
    if (direction == DEFAULT and p.direction & c.GST_RTP_HEADER_EXTENSION_DIRECTION_INHERITED != 0) direction = p.direction;
    const ok: c.gboolean = if (k.set_attributes) |set| set(e, direction, attributes) else 1;
    if (ok != 0) p.direction = direction;
    return ok;
}

pub export fn gst_rtp_header_extension_wants_update_non_rtp_src_caps(e: [*c]Ext) c.gboolean {
    if (!that(isExt(e), "gst_rtp_header_extension_wants_update_non_rtp_src_caps", "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    return priv(e).wants_update;
}

pub export fn gst_rtp_header_extension_set_wants_update_non_rtp_src_caps(e: [*c]Ext, state: c.gboolean) void {
    if (!that(isExt(e), "gst_rtp_header_extension_set_wants_update_non_rtp_src_caps", "GST_IS_RTP_HEADER_EXTENSION (ext)")) return;
    priv(e).wants_update = state;
}

pub export fn gst_rtp_header_extension_set_non_rtp_sink_caps(e: [*c]Ext, caps: ?*const c.GstCaps) c.gboolean {
    const f = "gst_rtp_header_extension_set_non_rtp_sink_caps";
    if (!that(isCaps(caps), f, "GST_IS_CAPS (caps)")) return 0;
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    if (!that(priv(e).id <= MAX_ID, f, "priv->ext_id <= MAX_RTP_EXT_ID")) return 0;
    return if (klass(e).set_non_rtp_sink_caps) |set| set(e, caps) else 1;
}

fn writableCaps(caps: ?*c.GstCaps) bool {
    return c.gst_mini_object_is_writable(@ptrCast(caps)) != 0;
}

pub export fn gst_rtp_header_extension_update_non_rtp_src_caps(e: [*c]Ext, caps: ?*c.GstCaps) c.gboolean {
    const f = "gst_rtp_header_extension_update_non_rtp_src_caps";
    if (!that(isCaps(caps), f, "GST_IS_CAPS (caps)")) return 0;
    if (!that(writableCaps(caps), f, "gst_caps_is_writable (caps)")) return 0;
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    const p = priv(e);
    if (!that(p.id <= MAX_ID, f, "priv->ext_id <= MAX_RTP_EXT_ID")) return 0;
    p.wants_update = 0;
    return if (klass(e).update_non_rtp_src_caps) |up| up(e, caps) else 1;
}

pub export fn gst_rtp_header_extension_set_caps_from_attributes(e: [*c]Ext, caps: ?*c.GstCaps) c.gboolean {
    const f = "gst_rtp_header_extension_set_caps_from_attributes";
    if (!that(isCaps(caps), f, "GST_IS_CAPS (caps)")) return 0;
    if (!that(writableCaps(caps), f, "gst_caps_is_writable (caps)")) return 0;
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return 0;
    if (!that(priv(e).id <= MAX_ID, f, "priv->ext_id <= MAX_RTP_EXT_ID")) return 0;
    const k = klass(e);
    if (!that(k.set_caps_from_attributes != null, f, "klass->set_caps_from_attributes != NULL")) return 0;
    return k.set_caps_from_attributes.?(e, caps);
}

pub export fn gst_rtp_header_extension_get_sdp_caps_field_name(e: [*c]Ext) [*c]u8 {
    const f = "gst_rtp_header_extension_get_sdp_caps_field_name";
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return null;
    if (!that(priv(e).id <= MAX_ID, f, "priv->ext_id <= MAX_RTP_EXT_ID")) return null;
    return c.g_strdup_printf("extmap-%u", priv(e).id);
}

fn directionName(d: c.GstRTPHeaderExtensionDirection) [*c]const u8 {
    if (d & c.GST_RTP_HEADER_EXTENSION_DIRECTION_INHERITED != 0) return "";
    if (d & c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDRECV == c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDRECV) return "sendrecv";
    if (d & c.GST_RTP_HEADER_EXTENSION_DIRECTION_SENDONLY != 0) return "sendonly";
    if (d & c.GST_RTP_HEADER_EXTENSION_DIRECTION_RECVONLY != 0) return "recvonly";
    return "inactive";
}

pub export fn gst_rtp_header_extension_set_caps_from_attributes_helper(e: [*c]Ext, caps: ?*c.GstCaps, attributes: [*c]const u8) c.gboolean {
    const p = priv(e);
    const field = gst_rtp_header_extension_get_sdp_caps_field_name(e);
    defer c.g_free(field);
    const s = c.gst_caps_get_structure(caps, 0);
    const uri = gst_rtp_header_extension_get_uri(e);
    if (p.direction & c.GST_RTP_HEADER_EXTENSION_DIRECTION_INHERITED != 0 and (attributes == null or attributes[0] == 0)) {
        c.gst_structure_set(s, field, c.G_TYPE_STRING, uri, @as(?*anyopaque, null));
        return 1;
    }
    var arr = std.mem.zeroes(c.GValue);
    var val = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    _ = c.g_value_init(&val, c.G_TYPE_STRING);
    for ([_][*c]const u8{ directionName(p.direction), uri, attributes }) |t| {
        c.g_value_set_string(&val, t);
        c.gst_value_array_append_value(&arr, &val);
    }
    c.gst_structure_set_value(s, field, &arr);
    c.g_value_unset(&val);
    c.g_value_unset(&arr);
    return 1;
}

fn defaultCapsFromAttributes(e: [*c]Ext, caps: ?*c.GstCaps) callconv(.c) c.gboolean {
    return gst_rtp_header_extension_set_caps_from_attributes_helper(e, caps, null);
}

fn filter(feature: ?*c.GstPluginFeature, data: c.gpointer) callconv(.c) c.gboolean {
    if (!gtype.instanceOf(feature, c.gst_element_factory_get_type())) return 0;
    if (c.gst_plugin_feature_get_rank(feature) < c.GST_RANK_MARGINAL) return 0;
    const fac: ?*c.GstElementFactory = @ptrCast(feature);
    const k = c.gst_element_factory_get_metadata(fac, c.GST_ELEMENT_METADATA_KLASS);
    if (k == null) return 0;
    const ks = std.mem.span(k);
    for ([_][]const u8{ "Network", "Extension", "RTPHeader" }) |w| {
        if (std.mem.indexOf(u8, ks, w) == null) return 0;
    }
    const furi = c.gst_element_factory_get_metadata(fac, URI_KEY);
    if (furi == null) return 0;
    const uri: [*c]const u8 = @ptrCast(data);
    if (uri != null and c.g_strcmp0(uri, furi) != 0) return 0;
    return 1;
}

pub export fn gst_rtp_get_header_extension_list() [*c]c.GList {
    return c.gst_registry_feature_filter(c.gst_registry_get(), filter, 0, null);
}

pub export fn gst_rtp_header_extension_create_from_uri(uri: [*c]const u8) [*c]Ext {
    const l = c.gst_registry_feature_filter(c.gst_registry_get(), filter, 1, @constCast(uri));
    if (l == null) return null;
    const el = c.gst_element_factory_create(@ptrCast(@alignCast(l[0].data)), null);
    c.g_list_free_full(l, c.gst_object_unref);
    _ = c.gst_object_ref_sink(el);
    return @ptrCast(@alignCast(el));
}

pub export fn gst_rtp_header_extension_set_direction(e: [*c]Ext, d: c.GstRTPHeaderExtensionDirection) void {
    const f = "gst_rtp_header_extension_set_direction";
    if (!that(isExt(e), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return;
    if (!that(d <= DEFAULT, f, "direction <= GST_RTP_HEADER_EXTENSION_DIRECTION_DEFAULT")) return;
    priv(e).direction = d;
}

pub export fn gst_rtp_header_extension_get_direction(e: [*c]Ext) c.GstRTPHeaderExtensionDirection {
    if (!that(isExt(e), "gst_rtp_header_extension_get_direction", "GST_IS_RTP_HEADER_EXTENSION (ext)")) return DEFAULT;
    return priv(e).direction;
}

pub fn accumulate(_: ?*c.GSignalInvocationHint, acc: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const e = c.g_value_get_object(ret);
    if (e == null) return 1;
    c.g_value_set_object(acc, e);
    return 0;
}

fn extmapId(name: [*c]const u8) ?c.guint {
    var end: [*c]u8 = null;
    std.c._errno().* = 0;
    const id = c.g_ascii_strtoull(name + "extmap-".len, &end, 10);
    if (std.c._errno().* != 0 or (id == 0 and @intFromPtr(name) == @intFromPtr(end))) return null;
    return @truncate(id);
}

fn extmapUri(v: [*c]const c.GValue) [*c]const u8 {
    if (isString(v)) return c.g_value_get_string(v);
    if (c.g_type_check_value_holds(@constCast(v), c.gst_value_array_get_type()) != 0) {
        const s = c.gst_value_array_get_value(v, 1);
        if (isString(s)) return c.g_value_get_string(s);
    }
    return null;
}

fn items(a: [*c]c.GPtrArray) []?*Ext {
    if (a[0].len == 0) return &.{};
    return @as([*]?*Ext, @ptrCast(@alignCast(a[0].pdata)))[0..a[0].len];
}

pub fn syncFromCaps(owner: anytype, list: [*c]c.GPtrArray, sig: c.guint, caps: [*c]c.GstCaps) bool {
    const lockable: *c.GstObject = @ptrCast(@alignCast(owner));
    const s = c.gst_caps_get_structure(caps, 0);
    const n: c.guint = @intCast(c.gst_structure_n_fields(s));
    const have = c.g_ptr_array_new_with_free_func(c.gst_object_unref);
    defer c.g_ptr_array_unref(have);
    const add = c.g_ptr_array_new();
    defer c.g_ptr_array_unref(add);
    const drop = c.g_ptr_array_new();
    defer c.g_ptr_array_unref(drop);
    c.g_mutex_lock(&lockable.lock);
    for (items(list)) |e| c.g_ptr_array_add(have, c.gst_object_ref(e));
    c.g_mutex_unlock(&lockable.lock);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const name = c.gst_structure_nth_field_name(s, i);
        if (c.g_str_has_prefix(name, "extmap-") == 0) continue;
        const id = extmapId(name) orelse return false;
        const uri = extmapUri(c.gst_structure_get_value(s, name));
        if (uri == null) return false;
        var found = false;
        for (items(have)) |e| {
            if (gst_rtp_header_extension_get_id(@ptrCast(e)) != id) continue;
            if (c.g_strcmp0(uri, gst_rtp_header_extension_get_uri(@ptrCast(e))) == 0) {
                if (gst_rtp_header_extension_set_attributes_from_caps(@ptrCast(e), caps) == 0) return false;
                found = true;
            } else c.g_ptr_array_add(drop, e);
            break;
        }
        if (found) continue;
        var e: [*c]Ext = null;
        c.g_signal_emit(owner, sig, 0, id, uri, &e);
        if (e != null and gst_rtp_header_extension_get_id(e) != id) {
            c.g_log(buf.DOMAIN, c.G_LOG_LEVEL_WARNING, "'request-extension' signal provided an rtp header extension for uri '%s' that does not match the requested extension id %u", uri, id);
            c.gst_object_unref(e);
            e = null;
        }
        if (e != null and gst_rtp_header_extension_set_attributes_from_caps(e, caps) == 0) {
            c.g_object_unref(e);
            return false;
        }
        if (e != null) c.g_ptr_array_add(add, e);
    }
    c.g_mutex_lock(&lockable.lock);
    for (items(drop)) |e| _ = c.g_ptr_array_remove_fast(list, e);
    for (items(add)) |e| c.g_ptr_array_add(list, e);
    c.g_mutex_unlock(&lockable.lock);
    return true;
}
