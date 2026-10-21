const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const factory = @import("elementfactory.zig");
const feature = @import("pluginfeature.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Meta = c.GstProtectionMeta;
const Buffer = c.GstBuffer;

var api_once: gtype.Once = .{};
var info_lock = std.mem.zeroes(c.GMutex);
var info: [*c]const c.GstMetaInfo = null;

pub export fn gst_protection_meta_api_get_type() c.GType {
    return api_once.get(struct {
        fn f() c.GType {
            var tags = [_][*c]const u8{null};
            return c.gst_meta_api_type_register("GstProtectionMetaAPI", @ptrCast(&tags));
        }
    }.f);
}

fn metaInit(m: [*c]c.GstMeta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    @as(*Meta, @ptrCast(@alignCast(m))).info = null;
    return 1;
}

fn metaFree(m: [*c]c.GstMeta, _: [*c]Buffer) callconv(.c) void {
    const pm: *Meta = @ptrCast(@alignCast(m));
    if (pm.info != null) c.gst_structure_free(pm.info);
}

fn metaTransform(dest: [*c]Buffer, m: [*c]c.GstMeta, _: [*c]Buffer, kind: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    if (kind != @import("meta.zig")._gst_meta_transform_copy) return 0;
    const copy: *c.GstMetaTransformCopy = @ptrCast(@alignCast(data));
    if (copy.region != 0) return 0;
    _ = gst_buffer_add_protection_meta(dest, c.gst_structure_copy(@as(*Meta, @ptrCast(@alignCast(m))).info));
    return 1;
}

pub export fn gst_protection_meta_get_info() [*c]const c.GstMetaInfo {
    c.g_mutex_lock(&info_lock);
    defer c.g_mutex_unlock(&info_lock);
    if (info == null) info = c.gst_meta_register(gst_protection_meta_api_get_type(), "GstProtectionMeta", @sizeOf(Meta), metaInit, metaFree, metaTransform);
    return info;
}

pub export fn gst_buffer_add_protection_meta(b: [*c]Buffer, s: [*c]c.GstStructure) [*c]Meta {
    if (!check.that(b != null and b[0].mini_object.type == @import("buffer.zig")._gst_buffer_type, "gst_buffer_add_protection_meta", "GST_IS_BUFFER (buffer)")) return null;
    if (!check.that(s != null, "gst_buffer_add_protection_meta", "info != NULL")) return null;
    const m: [*c]Meta = @ptrCast(@alignCast(c.gst_buffer_add_meta(b, gst_protection_meta_get_info(), null)));
    m[0].info = s;
    return m;
}

fn factoryCheck(f: [*c]factory.Factory, ids: [*c][*c]const u8) [*c]const u8 {
    var walk = factory.gst_element_factory_get_static_pad_templates(f);
    while (walk) |n| : (walk = n.next) {
        const caps = c.gst_static_pad_template_get_caps(@ptrCast(@alignCast(n.data)));
        defer c.gst_caps_unref(caps);
        var i: c.guint = 0;
        while (i < c.gst_caps_get_size(caps)) : (i += 1) {
            const st = c.gst_caps_get_structure(caps, i);
            if (c.gst_structure_has_field_typed(st, c.GST_PROTECTION_SYSTEM_ID_CAPS_FIELD, c.G_TYPE_STRING) == 0) continue;
            const id = c.gst_structure_get_string(st, c.GST_PROTECTION_SYSTEM_ID_CAPS_FIELD);
            var j: usize = 0;
            while (ids[j] != null) : (j += 1) if (c.g_ascii_strcasecmp(ids[j], id) == 0) return ids[j];
        }
    }
    return null;
}

fn decryptors() ?*c.GList {
    return factory.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_DECRYPTOR, c.GST_RANK_MARGINAL);
}

pub export fn gst_protection_select_system(ids: [*c][*c]const u8) [*c]const u8 {
    const list = decryptors();
    defer feature.gst_plugin_feature_list_free(list);
    var l = list;
    while (l) |n| : (l = n.next) {
        const r = factoryCheck(@ptrCast(@alignCast(n.data)), ids);
        if (r != null) return r;
    }
    return null;
}

pub export fn gst_protection_filter_systems_by_available_decryptors(ids: [*c][*c]const u8) [*c][*c]u8 {
    const list = decryptors();
    defer feature.gst_plugin_feature_list_free(list);
    const count = c.g_list_length(list);
    if (count == 0) return null;
    const out: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc((count + 1) * @sizeOf([*c]u8))));
    var i: usize = 0;
    var l = list;
    while (l) |n| : (l = n.next) {
        const r = factoryCheck(@ptrCast(@alignCast(n.data)), ids);
        if (r != null) {
            out[i] = c.g_strdup(r);
            i += 1;
        }
    }
    out[i] = null;
    if (out[0] == null) {
        c.g_free(@ptrCast(out));
        return null;
    }
    return out;
}
