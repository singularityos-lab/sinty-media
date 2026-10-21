const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const xmp = @import("xmp.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Data = struct { schemas: ?*c.GSList, lock: c.GMutex };

var type_once: gtype.Once = .{};
var key: c.GQuark = 0;
var create_lock = std.mem.zeroes(c.GMutex);

pub export fn gst_tag_xmp_writer_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = c.g_type_register_static_simple(c.G_TYPE_INTERFACE, "GstTagXmpWriter", @sizeOf(c.GstTagXmpWriterInterface), null, 0, null, 0);
            key = c.g_quark_from_static_string("GST_TAG_XMP_WRITER");
            c.g_type_interface_add_prerequisite(t, c.gst_element_get_type());
            return t;
        }
    }.f);
}

fn isWriter(p: ?*c.GstTagXmpWriter) bool {
    return gtype.instanceOf(p, gst_tag_xmp_writer_get_type());
}

fn cmp(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return c.strcmp(@ptrCast(a), @ptrCast(b));
}

fn addUnlocked(d: *Data, schema: [*c]const u8) void {
    if (c.g_slist_find_custom(d.schemas, schema, cmp) == null) d.schemas = c.g_slist_prepend(d.schemas, c.g_strdup(schema));
}

fn addAllUnlocked(d: *Data) void {
    const s = xmp.gst_tag_xmp_list_schemas();
    var i: usize = 0;
    while (s[i] != null) : (i += 1) addUnlocked(d, s[i]);
}

fn freeList(d: *Data) void {
    var it = d.schemas;
    while (it) |n| : (it = n.next) c.g_free(n.data);
    c.g_slist_free(d.schemas);
}

fn freeData(p: c.gpointer) callconv(.c) void {
    const d: *Data = @ptrCast(@alignCast(p));
    if (d.schemas != null) freeList(d);
    c.g_mutex_clear(&d.lock);
    c.g_free(d);
}

fn dataOf(w: ?*c.GstTagXmpWriter) *Data {
    const obj: *c.GObject = @ptrCast(@alignCast(w));
    if (c.g_object_get_qdata(obj, key)) |p| return @ptrCast(@alignCast(p));
    c.g_mutex_lock(&create_lock);
    defer c.g_mutex_unlock(&create_lock);
    if (c.g_object_get_qdata(obj, key)) |p| return @ptrCast(@alignCast(p));
    const d: *Data = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Data))));
    c.g_mutex_init(&d.lock);
    d.schemas = null;
    addAllUnlocked(d);
    c.g_object_set_qdata_full(obj, key, d, freeData);
    return d;
}

pub export fn gst_tag_xmp_writer_add_all_schemas(w: ?*c.GstTagXmpWriter) void {
    if (!check.that(isWriter(w), "gst_tag_xmp_writer_add_all_schemas", "GST_IS_TAG_XMP_WRITER (config)")) return;
    const d = dataOf(w);
    c.g_mutex_lock(&d.lock);
    addAllUnlocked(d);
    c.g_mutex_unlock(&d.lock);
}

pub export fn gst_tag_xmp_writer_add_schema(w: ?*c.GstTagXmpWriter, schema: [*c]const u8) void {
    if (!check.that(isWriter(w), "gst_tag_xmp_writer_add_schema", "GST_IS_TAG_XMP_WRITER (config)")) return;
    const d = dataOf(w);
    c.g_mutex_lock(&d.lock);
    addUnlocked(d, schema);
    c.g_mutex_unlock(&d.lock);
}

pub export fn gst_tag_xmp_writer_has_schema(w: ?*c.GstTagXmpWriter, schema: [*c]const u8) c.gboolean {
    if (!check.that(isWriter(w), "gst_tag_xmp_writer_has_schema", "GST_IS_TAG_XMP_WRITER (config)")) return 0;
    const d = dataOf(w);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    var it = d.schemas;
    while (it) |n| : (it = n.next) {
        if (c.strcmp(@ptrCast(n.data), schema) == 0) return 1;
    }
    return 0;
}

pub export fn gst_tag_xmp_writer_remove_schema(w: ?*c.GstTagXmpWriter, schema: [*c]const u8) void {
    if (!check.that(isWriter(w), "gst_tag_xmp_writer_remove_schema", "GST_IS_TAG_XMP_WRITER (config)")) return;
    const d = dataOf(w);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    var it = d.schemas;
    while (it) |n| : (it = n.next) {
        if (c.strcmp(@ptrCast(n.data), schema) == 0) {
            c.g_free(n.data);
            d.schemas = c.g_slist_delete_link(d.schemas, n);
            return;
        }
    }
}

pub export fn gst_tag_xmp_writer_remove_all_schemas(w: ?*c.GstTagXmpWriter) void {
    if (!check.that(isWriter(w), "gst_tag_xmp_writer_remove_all_schemas", "GST_IS_TAG_XMP_WRITER (config)")) return;
    const d = dataOf(w);
    c.g_mutex_lock(&d.lock);
    if (d.schemas != null) freeList(d);
    d.schemas = null;
    c.g_mutex_unlock(&d.lock);
}

pub export fn gst_tag_xmp_writer_tag_list_to_xmp_buffer(w: ?*c.GstTagXmpWriter, list: [*c]const c.GstTagList, read_only: c.gboolean) [*c]c.GstBuffer {
    if (!check.that(isWriter(w), "gst_tag_xmp_writer_tag_list_to_xmp_buffer", "GST_IS_TAG_XMP_WRITER (config)")) return null;
    const d = dataOf(w);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    if (d.schemas == null) return null;
    const arr: [*c][*c]const u8 = @ptrCast(@alignCast(c.g_malloc0((c.g_slist_length(d.schemas) + 1) * @sizeOf(usize))));
    var i: usize = 0;
    var it = d.schemas;
    while (it) |n| : (it = n.next) {
        arr[i] = @ptrCast(n.data);
        i += 1;
    }
    const buf = xmp.gst_tag_list_to_xmp_buffer(list, read_only, arr);
    c.g_free(@ptrCast(arr));
    return buf;
}
