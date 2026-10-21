const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Meta = c.GstMeta;
const Info = c.GstMetaInfo;
const Buffer = c.GstBuffer;

pub const Item = extern struct {
    next: ?*Item,
    seq_num: c.guint64,
    meta: Meta,
};

pub fn itemSize(info: [*c]const Info) usize {
    return info[0].size + @sizeOf(Item) - @sizeOf(Meta);
}

pub fn itemOf(m: [*c]const Meta) *Item {
    const base = @intFromPtr(m) - @offsetOf(Item, "meta");
    return @ptrFromInt(base);
}

const InfoImpl = extern struct {
    info: Info,
    custom_transform: c.GstCustomMetaTransformFunction,
    custom_data: c.gpointer,
    custom_destroy: c.GDestroyNotify,
    is_custom: c.gboolean,
};

pub export var _gst_meta_transform_copy: c.GQuark = 0;
pub export var _gst_meta_tag_memory: c.GQuark = 0;
pub export var _gst_meta_tag_memory_reference: c.GQuark = 0;
var tags_quark: c.GQuark = 0;
var aggregator_quark: c.GQuark = 0;

var registry: ?*c.GHashTable = null;
var lock: c.GRWLock = std.mem.zeroes(c.GRWLock);

pub fn initialize() void {
    c.g_rw_lock_init(&lock);
    registry = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, null, c.g_free);
    _gst_meta_transform_copy = c.g_quark_from_static_string("gst-copy");
    _gst_meta_tag_memory = c.g_quark_from_static_string("memory");
    _gst_meta_tag_memory_reference = c.g_quark_from_static_string("memory-reference");
    tags_quark = c.g_quark_from_static_string("tags");
    aggregator_quark = c.g_quark_from_static_string("GstAllocationMetaParamsAggregator");
}

pub export fn gst_meta_api_type_register(api: [*c]const u8, tags: [*c][*c]const u8) c.GType {
    if (!check.that(api != null, "gst_meta_api_type_register", "api != NULL")) return 0;
    if (!check.that(tags != null, "gst_meta_api_type_register", "tags != NULL")) return 0;
    const t = c.g_pointer_type_register_static(api);
    if (t != 0) {
        var i: usize = 0;
        while (tags[i] != null) : (i += 1) c.g_type_set_qdata(t, c.g_quark_from_string(tags[i]), @ptrFromInt(1));
    }
    c.g_type_set_qdata(t, tags_quark, @ptrCast(c.g_strdupv(@ptrCast(@constCast(tags)))));
    return t;
}

fn impl(info: [*c]const Info) *InfoImpl {
    return @ptrCast(@alignCast(@constCast(info)));
}

fn customInit(m: [*c]Meta, _: c.gpointer, buf: [*c]Buffer) callconv(.c) c.gboolean {
    const cm: *c.GstCustomMeta = @ptrCast(@alignCast(m));
    cm.structure = c.gst_structure_new_empty(c.g_type_name(m[0].info[0].type));
    _ = c.gst_structure_set_parent_refcount(cm.structure, &buf[0].mini_object.refcount);
    return 1;
}

fn customFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    const cm: *c.GstCustomMeta = @ptrCast(@alignCast(m));
    _ = c.gst_structure_set_parent_refcount(cm.structure, null);
    c.gst_structure_free(cm.structure);
}

fn customTransform(dest: [*c]Buffer, m: [*c]Meta, src: [*c]Buffer, kind: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const cm: *c.GstCustomMeta = @ptrCast(@alignCast(m));
    const info = impl(m[0].info);
    if (info.custom_transform) |f| return f(dest, cm, src, kind, data, info.custom_data);
    if (kind != _gst_meta_transform_copy) return 0;
    const out: *c.GstCustomMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(dest, m[0].info, null)));
    _ = c.gst_structure_set_parent_refcount(out.structure, null);
    _ = c.gst_structure_take(&out.structure, c.gst_structure_copy(cm.structure));
    _ = c.gst_structure_set_parent_refcount(out.structure, &dest[0].mini_object.refcount);
    return 1;
}

fn customSerialize(m: [*c]const Meta, data: [*c]c.GstByteArrayInterface, _: [*c]c.guint8) callconv(.c) c.gboolean {
    const cm: *const c.GstCustomMeta = @ptrCast(@alignCast(m));
    const s = c.gst_structure_serialize_full(cm.structure, c.GST_SERIALIZE_FLAG_STRICT);
    if (s == null) return 0;
    defer c.g_free(s);
    return c.gst_byte_array_interface_append_data(data, @ptrCast(s), std.mem.len(s) + 1);
}

fn customDeserialize(info: [*c]const Info, buf: [*c]Buffer, data: [*c]const c.guint8, size: c.gsize, version: c.guint8) callconv(.c) [*c]Meta {
    if (version != 0 or size < 1 or data[size - 1] != 0) return null;
    const s = c.gst_structure_new_from_string(@ptrCast(data));
    if (s == null) return null;
    const m = c.gst_buffer_add_meta(buf, info, null);
    const cm: *c.GstCustomMeta = @ptrCast(@alignCast(m));
    _ = c.gst_structure_set_parent_refcount(cm.structure, null);
    _ = c.gst_structure_take(&cm.structure, s);
    _ = c.gst_structure_set_parent_refcount(cm.structure, &buf[0].mini_object.refcount);
    return m;
}

pub export fn gst_custom_meta_get_structure(m: [*c]c.GstCustomMeta) [*c]c.GstStructure {
    if (!check.that(m != null, "gst_custom_meta_get_structure", "meta != NULL")) return null;
    if (!check.that(gst_meta_info_is_custom(m[0].meta.info) != 0, "gst_custom_meta_get_structure", "gst_meta_info_is_custom (((GstMeta *) meta)->info)")) return null;
    return m[0].structure;
}

pub export fn gst_custom_meta_has_name(m: [*c]c.GstCustomMeta, name: [*c]const u8) c.gboolean {
    if (!check.that(m != null, "gst_custom_meta_has_name", "meta != NULL")) return 0;
    if (!check.that(gst_meta_info_is_custom(m[0].meta.info) != 0, "gst_custom_meta_has_name", "gst_meta_info_is_custom (((GstMeta *) meta)->info)")) return 0;
    return c.gst_structure_has_name(m[0].structure, name);
}

pub export fn gst_meta_register_custom(name: [*c]const u8, tags: [*c][*c]const u8, transform: c.GstCustomMetaTransformFunction, data: c.gpointer, destroy: c.GDestroyNotify) [*c]const Info {
    const api_name = c.g_strdup_printf("%s-api", name);
    if (!check.that(tags != null, "gst_meta_register_custom", "tags != NULL")) return null;
    if (!check.that(name != null, "gst_meta_register_custom", "name != NULL")) return null;
    const api = gst_meta_api_type_register(api_name, tags);
    c.g_free(api_name);
    if (api == 0) return null;
    const info = gst_meta_info_new(api, name, @sizeOf(c.GstCustomMeta));
    if (info == null) return null;
    info[0].init_func = customInit;
    info[0].free_func = customFree;
    info[0].transform_func = customTransform;
    info[0].serialize_func = customSerialize;
    info[0].deserialize_func = customDeserialize;
    const im = impl(info);
    im.is_custom = 1;
    im.custom_transform = transform;
    im.custom_data = data;
    im.custom_destroy = destroy;
    return gst_meta_info_register(info);
}

pub export fn gst_meta_register_custom_simple(name: [*c]const u8) [*c]const Info {
    var none = [_][*c]const u8{null};
    return gst_meta_register_custom(name, &none, null, null, null);
}

pub export fn gst_meta_info_is_custom(info: [*c]const Info) c.gboolean {
    if (!check.that(info != null, "gst_meta_info_is_custom", "info != NULL")) return 0;
    return impl(info).is_custom;
}

pub export fn gst_meta_api_type_has_tag(api: c.GType, tag: c.GQuark) c.gboolean {
    if (!check.that(api != 0, "gst_meta_api_type_has_tag", "api != 0")) return 0;
    if (!check.that(tag != 0, "gst_meta_api_type_has_tag", "tag != 0")) return 0;
    return @intFromBool(c.g_type_get_qdata(api, tag) != null);
}

pub export fn gst_meta_api_type_get_tags(api: c.GType) [*c]const [*c]const u8 {
    if (!check.that(api != 0, "gst_meta_api_type_get_tags", "api != 0")) return null;
    const tags: [*c]const [*c]const u8 = @ptrCast(@alignCast(c.g_type_get_qdata(api, tags_quark)));
    if (tags[0] == null) return null;
    return tags;
}

pub export fn gst_meta_api_type_tags_contain_only(api: c.GType, valid: [*c][*c]const u8) c.gboolean {
    if (!check.that(api != 0, "gst_meta_api_type_tags_contain_only", "api != 0")) return 0;
    if (!check.that(valid != null, "gst_meta_api_type_tags_contain_only", "valid_tags != NULL")) return 0;
    const tags: [*c]const [*c]const u8 = @ptrCast(@alignCast(c.g_type_get_qdata(api, tags_quark)));
    if (tags == null) return 1;
    var i: usize = 0;
    while (tags[i] != null) : (i += 1) if (c.g_strv_contains(valid, tags[i]) == 0) return 0;
    return 1;
}

pub export fn gst_meta_api_type_aggregate_params(api: c.GType, out: [*c][*c]c.GstStructure, p0: [*c]const c.GstStructure, p1: [*c]const c.GstStructure) c.gboolean {
    if (!check.that(api != 0, "gst_meta_api_type_aggregate_params", "api != 0")) return 0;
    if (!check.that(out != null, "gst_meta_api_type_aggregate_params", "aggregated_params != NULL")) return 0;
    const f: c.GstAllocationMetaParamsAggregator = @ptrCast(c.g_type_get_qdata(api, aggregator_quark));
    const agg = f orelse return 0;
    return agg(out, p0, p1);
}

pub export fn gst_meta_api_type_set_params_aggregator(api: c.GType, agg: c.GstAllocationMetaParamsAggregator) void {
    if (!check.that(api != 0, "gst_meta_api_type_set_params_aggregator", "api != 0")) return;
    if (!check.that(agg != null, "gst_meta_api_type_set_params_aggregator", "aggregator != NULL")) return;
    c.g_type_set_qdata(api, aggregator_quark, @constCast(@ptrCast(agg)));
}

pub export fn gst_meta_info_new(api: c.GType, name: [*c]const u8, size: c.gsize) [*c]Info {
    if (!check.that(api != 0, "gst_meta_info_new", "api != 0")) return null;
    if (!check.that(name != null, "gst_meta_info_new", "impl != NULL")) return null;
    if (!check.that(size != 0, "gst_meta_info_new", "size != 0")) return null;
    const t = c.g_pointer_type_register_static(name);
    const im: *InfoImpl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(InfoImpl))));
    im.info.api = api;
    im.info.type = t;
    im.info.size = size;
    return &im.info;
}

pub export fn gst_meta_info_register(info: [*c]Info) [*c]const Info {
    if (info[0].type == 0) {
        c.g_free(info);
        return null;
    }
    c.g_rw_lock_writer_lock(&lock);
    defer c.g_rw_lock_writer_unlock(&lock);
    _ = c.g_hash_table_insert(registry, @constCast(c.g_intern_string(c.g_type_name(info[0].type))), info);
    return info;
}

pub export fn gst_meta_register(api: c.GType, name: [*c]const u8, size: c.gsize, init: c.GstMetaInitFunction, free: c.GstMetaFreeFunction, transform: c.GstMetaTransformFunction) [*c]const Info {
    if (init == null) c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Registering meta implementation '%s' without init function", name);
    const info = gst_meta_info_new(api, name, size);
    if (info == null) return null;
    info[0].init_func = init;
    info[0].free_func = free;
    info[0].transform_func = transform;
    impl(info).is_custom = 0;
    return gst_meta_info_register(info);
}

pub export fn gst_meta_get_info(name: [*c]const u8) [*c]const Info {
    if (!check.that(name != null, "gst_meta_get_info", "impl != NULL")) return null;
    c.g_rw_lock_reader_lock(&lock);
    defer c.g_rw_lock_reader_unlock(&lock);
    return @ptrCast(@alignCast(c.g_hash_table_lookup(registry, name)));
}

pub export fn gst_meta_get_seqnum(m: [*c]const Meta) c.guint64 {
    if (!check.that(m != null, "gst_meta_get_seqnum", "meta != NULL")) return 0;
    return itemOf(m).seq_num;
}

pub export fn gst_meta_compare_seqnum(a: [*c]const Meta, b: [*c]const Meta) c.gint {
    const x = gst_meta_get_seqnum(a);
    const y = gst_meta_get_seqnum(b);
    if (x == y) return 0;
    return if (x < y) -1 else 1;
}

fn putU32(p: [*c]u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .little);
}

pub export fn gst_meta_serialize(m: [*c]const Meta, data: [*c]c.GstByteArrayInterface) c.gboolean {
    if (!check.that(m != null, "gst_meta_serialize", "meta != NULL")) return 0;
    if (!check.that(data != null, "gst_meta_serialize", "data != NULL")) return 0;
    const ser = m[0].info[0].serialize_func orelse return 0;
    const name = c.g_type_name(m[0].info[0].type);
    const name_len: u32 = @intCast(std.mem.len(name));
    const orig = data[0].len;
    var version: u8 = 0;
    const header: u8 = @truncate(2 * 4 + name_len + 2);
    if (c.gst_byte_array_interface_set_size(data, data[0].len + header) == 0) return 0;
    if (ser(m, data, &version) != 0) {
        const h = data[0].data + orig;
        putU32(h, @intCast(data[0].len - orig));
        putU32(h + 4, name_len);
        @memcpy(h[8 .. 8 + name_len + 1], name[0 .. name_len + 1]);
        h[header - 1] = version;
        return 1;
    }
    _ = c.gst_byte_array_interface_set_size(data, orig);
    return 0;
}

const ByteArrayImpl = extern struct {
    parent: c.GstByteArrayInterface,
    array: [*c]c.GByteArray,
};

fn byteArrayResize(self: [*c]c.GstByteArrayInterface, len: c.gsize) callconv(.c) c.gboolean {
    const b: *ByteArrayImpl = @ptrCast(@alignCast(self));
    _ = c.g_byte_array_set_size(b.array, @intCast(len));
    self[0].data = b.array[0].data;
    return 1;
}

pub export fn gst_meta_serialize_simple(m: [*c]const Meta, data: [*c]c.GByteArray) c.gboolean {
    var b = ByteArrayImpl{ .parent = .{}, .array = data };
    c.gst_byte_array_interface_init(&b.parent);
    b.parent.data = data[0].data;
    b.parent.len = data[0].len;
    b.parent.resize = byteArrayResize;
    return gst_meta_serialize(m, &b.parent);
}

pub export fn gst_meta_deserialize(buf: [*c]Buffer, data: [*c]const c.guint8, size: c.gsize, consumed: [*c]c.guint32) [*c]Meta {
    const f = "gst_meta_deserialize";
    if (!check.that(buf != null and buf[0].mini_object.type == c.gst_buffer_get_type(), f, "GST_IS_BUFFER (buffer)")) return null;
    if (!check.that(data != null, f, "data != NULL")) return null;
    if (!check.that(consumed != null, f, "consumed != NULL")) return null;
    consumed.* = 0;
    if (size < 8) return null;
    const total = std.mem.readInt(u32, data[0..4], .little);
    const name_len = std.mem.readInt(u32, data[4..8], .little);
    const header: u32 = 8 + name_len + 2;
    if (size < total or total < header) return null;
    const version = data[header - 1];
    const name: [*c]const u8 = data + 8;
    if (name[name_len] != 0) return null;
    consumed.* = total;
    var info = gst_meta_get_info(name);
    if (info == null) {
        info = @import("metafactory.zig").gst_meta_factory_load(name);
        if (info == null) return null;
    }
    const de = info[0].deserialize_func orelse return null;
    return de(info, buf, data + header, total - header, version);
}
