const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const feature = @import("pluginfeature.zig");
const plugin = @import("plugin.zig");
const registry = @import("registry.zig");
const regcache = @import("regcache.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub const Factory = extern struct {
    feature: feature.Feature,
    meta_info: [*c]const c.GstMetaInfo,

    pub const Header = c.struct__GstMetaFactory;
};

const FactoryClass = extern struct {
    parent: feature.FeatureClass,
};

var type_once: gtype.Once = .{};
var debug_cat: [*c]c.GstDebugCategory = null;

fn of(p: anytype) [*c]Factory {
    return @ptrCast(@alignCast(p));
}

fn classInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {
    debug_cat = info._gst_debug_category_new("GST_META_FACTORY", c.GST_DEBUG_BOLD, "Meta factories allow automatically loading a GstMetaInfo from a plugin");
}

pub export fn gst_meta_factory_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.object(feature.gst_plugin_feature_get_type, "GstMetaFactory", FactoryClass, Factory, classInit, null, 0);
        }
    }.f);
}

pub export fn gst_meta_factory_load(name: [*c]const u8) [*c]const c.GstMetaInfo {
    if (!check.that(name != null, "gst_meta_factory_find", "name != NULL")) return null;
    const found = registry.gst_registry_find_feature(registry.gst_registry_get(), name, gst_meta_factory_get_type());
    if (found == null) return null;
    const f = of(feature.gst_plugin_feature_load(found));
    if (f == null) return null;
    return f[0].meta_info;
}

pub export fn gst_meta_factory_register(p: [*c]plugin.Plugin, meta_info: [*c]const c.GstMetaInfo) c.gboolean {
    const name = c.g_type_name(meta_info[0].type);
    const reg = registry.gst_registry_get();
    const existing = registry.gst_registry_lookup_feature(reg, name);
    if (existing != null) {
        existing[0].loaded = 1;
        of(existing)[0].meta_info = meta_info;
        c.gst_object_unref(existing);
        return 1;
    }
    const f = of(c.g_object_new(gst_meta_factory_get_type(), @as([*c]const u8, null)));
    _ = c.gst_object_set_name(@ptrCast(f), name);
    feature.bindPlugin(@ptrCast(f), p);
    f[0].feature.loaded = 1;
    f[0].meta_info = meta_info;
    _ = registry.gst_registry_add_feature(reg, @ptrCast(f));
    return 1;
}

fn save(_: *regcache.Writer, _: [*c]feature.Feature) void {}

fn load(_: *regcache.Reader) regcache.Error![*c]feature.Feature {
    return @ptrCast(@alignCast(c.g_object_new(gst_meta_factory_get_type(), @as([*c]const u8, null))));
}

pub const kind = regcache.Kind{ .name = "GstMetaFactory", .get_type = gst_meta_factory_get_type, .save = save, .load = load };
