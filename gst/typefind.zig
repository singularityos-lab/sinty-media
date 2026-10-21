const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const va = @import("varargs.zig");
const feature = @import("pluginfeature.zig");
const plugin = @import("plugin.zig");
const registry = @import("registry.zig");
const regcache = @import("regcache.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub const Factory = extern struct {
    feature: feature.Feature,
    function: c.GstTypeFindFunction,
    extensions: [*c][*c]u8,
    caps: [*c]c.GstCaps,
    user_data: c.gpointer,
    user_data_notify: c.GDestroyNotify,
    reserved: [4]c.gpointer,

    pub const Header = c.struct__GstTypeFindFactory;
};

const FactoryClass = extern struct {
    parent: feature.FeatureClass,
    reserved: [4]c.gpointer,
};

const Find = c.GstTypeFind;

var factory_once: gtype.Once = .{};
var find_once: gtype.Once = .{};
var parent_class: ?*c.GObjectClass = null;
pub var debug_cat: [*c]c.GstDebugCategory = null;

pub fn of(p: anytype) [*c]Factory {
    return @ptrCast(@alignCast(p));
}

pub fn isFactory(p: anytype) bool {
    return gtype.instanceOf(p, gst_type_find_factory_get_type());
}

pub export fn gst_type_find_get_type() c.GType {
    return find_once.get(struct {
        fn f() c.GType {
            return c.g_pointer_type_register_static("GstTypeFind");
        }
    }.f);
}

pub export fn gst_type_find_factory_get_type() c.GType {
    return factory_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(feature.gst_plugin_feature_get_type, "GstTypeFindFactory", FactoryClass, Factory, classInit, instanceInit, 0);
            debug_cat = info._gst_debug_category_new("GST_TYPEFIND", c.GST_DEBUG_FG_GREEN, "typefinding subsystem");
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(klass))).dispose = dispose;
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const f = of(instance);
    f[0].user_data = f;
    f[0].user_data_notify = null;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const f = of(o);
    if (f[0].caps != null) {
        c.gst_caps_unref(f[0].caps);
        f[0].caps = null;
    }
    if (f[0].extensions != null) {
        c.g_strfreev(f[0].extensions);
        f[0].extensions = null;
    }
    if (f[0].user_data_notify != null and f[0].user_data != null) {
        f[0].user_data_notify.?(f[0].user_data);
        f[0].user_data = null;
    }
    parent_class.?.dispose.?(o);
}

pub export fn gst_type_find_register(p: [*c]plugin.Plugin, name: [*c]const u8, rank: c.guint, func: c.GstTypeFindFunction, extensions: [*c]const u8, caps: [*c]c.GstCaps, data: c.gpointer, notify: c.GDestroyNotify) c.gboolean {
    if (!check.that(name != null, "gst_type_find_register", "name != NULL")) return 0;
    const f = of(c.g_object_new(gst_type_find_factory_get_type(), @as([*c]const u8, null)));
    _ = c.gst_object_set_name(@ptrCast(f), name);
    feature.gst_plugin_feature_set_rank(@ptrCast(f), rank);
    if (extensions != null) f[0].extensions = c.g_strsplit(extensions, ",", -1);
    _ = c.gst_caps_replace(&f[0].caps, caps);
    f[0].function = func;
    f[0].user_data = data;
    f[0].user_data_notify = notify;
    feature.bindPlugin(@ptrCast(f), p);
    f[0].feature.loaded = 1;
    _ = registry.gst_registry_add_feature(registry.gst_registry_get(), @ptrCast(f));
    return 1;
}

pub export fn gst_type_find_peek(find: [*c]Find, offset: c.gint64, size: c.guint) [*c]const u8 {
    if (!check.that(find[0].peek != null, "gst_type_find_peek", "find->peek != NULL")) return null;
    return find[0].peek.?(find[0].data, offset, size);
}

pub export fn gst_type_find_suggest(find: [*c]Find, probability: c.guint, caps: [*c]c.GstCaps) void {
    const f = "gst_type_find_suggest";
    if (!check.that(find[0].suggest != null, f, "find->suggest != NULL")) return;
    if (!check.that(probability <= 100, f, "probability <= 100")) return;
    if (!check.that(caps != null, f, "caps != NULL")) return;
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, f, "gst_caps_is_fixed (caps)")) return;
    find[0].suggest.?(find[0].data, probability, caps);
}

pub export fn gst_type_find_suggest_empty_simple(find: [*c]Find, probability: c.guint, media: [*c]const u8) void {
    const f = "gst_type_find_suggest_empty_simple";
    if (!check.that(find[0].suggest != null, f, "find->suggest != NULL")) return;
    if (!check.that(probability <= 100, f, "probability <= 100")) return;
    if (!check.that(media != null, f, "media_type != NULL")) return;
    const caps = c.gst_caps_new_empty_simple(media);
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, f, "gst_caps_is_fixed (caps)")) return;
    find[0].suggest.?(find[0].data, probability, caps);
    c.gst_caps_unref(caps);
}

pub export fn gst_type_find_suggest_simple(find: [*c]Find, probability: c.guint, media: [*c]const u8, field: [*c]const u8, ...) callconv(.c) void {
    const f = "gst_type_find_suggest_simple";
    if (!check.that(find[0].suggest != null, f, "find->suggest != NULL")) return;
    if (!check.that(probability <= 100, f, "probability <= 100")) return;
    if (!check.that(media != null, f, "media_type != NULL")) return;
    const caps = c.gst_caps_new_empty();
    var ap = @cVaStart();
    const s = c.gst_structure_new_valist(media, field, va.toC(&ap));
    @cVaEnd(&ap);
    c.gst_caps_append_structure(caps, s);
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, f, "gst_caps_is_fixed (caps)")) return;
    find[0].suggest.?(find[0].data, probability, caps);
    c.gst_caps_unref(caps);
}

pub export fn gst_type_find_get_length(find: [*c]Find) c.guint64 {
    if (find[0].get_length == null) return 0;
    return find[0].get_length.?(find[0].data);
}

pub export fn gst_type_find_factory_get_list() ?*c.GList {
    return registry.gst_registry_get_feature_list(registry.gst_registry_get(), gst_type_find_factory_get_type());
}

pub export fn gst_type_find_factory_get_caps(f: [*c]Factory) [*c]c.GstCaps {
    if (!check.that(isFactory(f), "gst_type_find_factory_get_caps", "GST_IS_TYPE_FIND_FACTORY (factory)")) return null;
    return f[0].caps;
}

pub export fn gst_type_find_factory_get_extensions(f: [*c]Factory) [*c]const [*c]const u8 {
    if (!check.that(isFactory(f), "gst_type_find_factory_get_extensions", "GST_IS_TYPE_FIND_FACTORY (factory)")) return null;
    return @ptrCast(f[0].extensions);
}

pub export fn gst_type_find_factory_call_function(f: [*c]Factory, find: [*c]Find) void {
    const fname = "gst_type_find_factory_call_function";
    if (!check.that(isFactory(f), fname, "GST_IS_TYPE_FIND_FACTORY (factory)")) return;
    if (!check.that(find != null, fname, "find != NULL")) return;
    if (!check.that(find[0].peek != null, fname, "find->peek != NULL")) return;
    if (!check.that(find[0].suggest != null, fname, "find->suggest != NULL")) return;
    const loaded = of(feature.gst_plugin_feature_load(@ptrCast(f)));
    if (loaded == null) return;
    if (loaded[0].function) |func| func(find, loaded[0].user_data);
    c.gst_object_unref(loaded);
}

pub export fn gst_type_find_factory_has_function(f: [*c]Factory) c.gboolean {
    if (!check.that(isFactory(f), "gst_type_find_factory_has_function", "GST_IS_TYPE_FIND_FACTORY (factory)")) return 0;
    return @intFromBool(f[0].function != null);
}

pub fn rankCompare(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const fa = feature.of(@constCast(a));
    const fb = feature.of(@constCast(b));
    if (fa[0].rank != fb[0].rank) return @as(c.gint, @bitCast(fb[0].rank)) -% @as(c.gint, @bitCast(fa[0].rank));
    return c.strcmp(feature.nameOf(fa), feature.nameOf(fb));
}

fn save(w: *regcache.Writer, f: [*c]feature.Feature) void {
    const tf = of(f);
    w.strv(@ptrCast(tf[0].extensions));
    if (tf[0].caps != null) {
        const s = c.gst_caps_to_string(tf[0].caps);
        defer c.g_free(s);
        w.str(s);
    } else w.str(null);
}

fn load(r: *regcache.Reader) regcache.Error![*c]feature.Feature {
    const tf = of(c.g_object_new(gst_type_find_factory_get_type(), @as([*c]const u8, null)));
    errdefer c.gst_object_unref(tf);
    tf[0].extensions = try r.strv();
    const caps = try r.dup();
    defer c.g_free(caps);
    if (caps != null) tf[0].caps = c.gst_caps_from_string(caps);
    return @ptrCast(tf);
}

pub const kind = regcache.Kind{ .name = "GstTypeFindFactory", .get_type = gst_type_find_factory_get_type, .save = save, .load = load };
