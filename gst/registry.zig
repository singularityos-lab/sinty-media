const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const core = @import("core.zig");
const feature = @import("pluginfeature.zig");
const plugin = @import("plugin.zig");
const factory = @import("elementfactory.zig");
const regcache = @import("regcache.zig");
const loader = @import("pluginloader.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub const Registry = extern struct {
    object: c.GstObject,
    priv: *Private,

    pub const Header = c.struct__GstRegistry;
};

const RegistryClass = extern struct {
    parent_class: c.GstObjectClass,
    reserved: [4]c.gpointer,
};

pub const Private = extern struct {
    plugins: ?*c.GList,
    features: ?*c.GList,
    n_plugins: c.guint,
    feature_hash: ?*c.GHashTable,
    basename_hash: ?*c.GHashTable,
    cookie: u32,
    lists: [3]?*c.GList,
    cookies: [3]u32,
};

const Plugin = plugin.Plugin;
const Feature = feature.Feature;

var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var plugin_added: c.guint = 0;
var feature_added: c.guint = 0;
var default_lock = std.mem.zeroes(c.GMutex);
var default_registry: [*c]Registry = null;
var fork_enabled = true;
pub export var _gst_disable_registry_cache: c.gboolean = 0;

fn cacheFlag() *c.gboolean {
    return gtype.lookup(?*c.gboolean, "_gst_disable_registry_cache") orelse &_gst_disable_registry_cache;
}
var reuse_scanner = true;

pub const Sorted = struct {
    get_type: *const fn () callconv(.c) c.GType,
    sort: ?c.GCompareFunc,
};

const sorted = [_]Sorted{
    .{ .get_type = factory.gst_element_factory_get_type, .sort = null },
    .{ .get_type = @import("typefind.zig").gst_type_find_factory_get_type, .sort = @import("typefind.zig").rankCompare },
    .{ .get_type = @import("device.zig").gst_device_provider_factory_get_type, .sort = null },
};

fn of(p: anytype) [*c]Registry {
    return @ptrCast(@alignCast(p));
}

fn isRegistry(p: anytype) bool {
    return gtype.instanceOf(p, gst_registry_get_type());
}

pub export fn gst_registry_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstRegistry", RegistryClass, Registry, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    const none: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    plugin_added = c.g_signal_new("plugin-added", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, none, @as(c.guint, 1), plugin.gst_plugin_get_type());
    feature_added = c.g_signal_new("feature-added", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, none, @as(c.guint, 1), feature.gst_plugin_feature_get_type());
    @as(*c.GObjectClass, @ptrCast(@alignCast(klass))).finalize = finalize;
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const r = of(instance);
    const base: [*]u8 = @ptrCast(instance);
    r[0].priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
    r[0].priv.feature_hash = c.g_hash_table_new(c.g_str_hash, c.g_str_equal);
    r[0].priv.basename_hash = c.g_hash_table_new(c.g_str_hash, c.g_str_equal);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const r = of(o);
    const d = r[0].priv;
    const plugins = d.plugins;
    d.plugins = null;
    d.n_plugins = 0;
    var l = plugins;
    while (l) |n| : (l = n.next) if (n.data != null) c.gst_object_unref(n.data);
    c.g_list_free(plugins);
    const feats = d.features;
    d.features = null;
    l = feats;
    while (l) |n| : (l = n.next) if (n.data != null) object.gst_object_unparent(@ptrCast(@alignCast(n.data)));
    c.g_list_free(feats);
    c.g_hash_table_destroy(d.feature_hash);
    d.feature_hash = null;
    c.g_hash_table_destroy(d.basename_hash);
    d.basename_hash = null;
    for (&d.lists) |*cached| if (cached.* != null) feature.gst_plugin_feature_list_free(cached.*);
    parent_class.?.finalize.?(o);
}

pub export fn gst_registry_get() [*c]Registry {
    c.g_mutex_lock(&default_lock);
    defer c.g_mutex_unlock(&default_lock);
    if (default_registry == null) {
        default_registry = of(c.g_object_new(gst_registry_get_type(), @as([*c]const u8, null)));
        _ = object.gst_object_ref_sink(default_registry);
    }
    return default_registry;
}

fn lock(r: [*c]Registry) void {
    object.lock(r);
}

fn unlock(r: [*c]Registry) void {
    object.unlock(r);
}

fn byBasename(r: [*c]Registry, name: [*c]const u8) [*c]Plugin {
    return plugin.of(c.g_hash_table_lookup(r[0].priv.basename_hash, name));
}

fn dropPluginLocked(r: [*c]Registry, p: [*c]Plugin) void {
    r[0].priv.plugins = c.g_list_remove(r[0].priv.plugins, p);
    r[0].priv.n_plugins -= 1;
    if (p[0].basename != null) _ = c.g_hash_table_remove(r[0].priv.basename_hash, p[0].basename);
}

pub export fn gst_registry_add_plugin(r: [*c]Registry, p: [*c]Plugin) c.gboolean {
    if (!check.that(isRegistry(r), "gst_registry_add_plugin", "GST_IS_REGISTRY (registry)")) return 0;
    if (!check.that(plugin.isPlugin(p), "gst_registry_add_plugin", "GST_IS_PLUGIN (plugin)")) return 0;
    lock(r);
    if (p[0].basename != null) {
        const old = byBasename(r, p[0].basename);
        if (old != null) {
            if (p[0].object.flags & c.GST_PLUGIN_FLAG_BLACKLISTED != 0 and c.strcmp(p[0].filename, old[0].filename) != 0) {
                _ = object.gst_object_ref_sink(p);
                c.gst_object_unref(p);
                unlock(r);
                return 0;
            }
            dropPluginLocked(r, old);
            c.gst_object_unref(old);
        }
    }
    r[0].priv.plugins = c.g_list_prepend(r[0].priv.plugins, p);
    r[0].priv.n_plugins += 1;
    if (p[0].basename != null) _ = c.g_hash_table_replace(r[0].priv.basename_hash, p[0].basename, p);
    _ = object.gst_object_ref_sink(p);
    unlock(r);
    c.g_signal_emit(r, plugin_added, 0, p);
    return 1;
}

fn dropFeaturesOf(r: [*c]Registry, p: [*c]Plugin) void {
    var l = r[0].priv.features;
    while (l) |n| {
        const next = n.next;
        const f = feature.of(n.data);
        if (f != null and f[0].plugin == p) {
            r[0].priv.features = c.g_list_delete_link(r[0].priv.features, n);
            _ = c.g_hash_table_remove(r[0].priv.feature_hash, feature.nameOf(f));
            object.gst_object_unparent(@ptrCast(f));
        }
        l = next;
    }
    r[0].priv.cookie +%= 1;
}

pub export fn gst_registry_remove_plugin(r: [*c]Registry, p: [*c]Plugin) void {
    if (!check.that(isRegistry(r), "gst_registry_remove_plugin", "GST_IS_REGISTRY (registry)")) return;
    if (!check.that(plugin.isPlugin(p), "gst_registry_remove_plugin", "GST_IS_PLUGIN (plugin)")) return;
    lock(r);
    dropPluginLocked(r, p);
    dropFeaturesOf(r, p);
    unlock(r);
    c.gst_object_unref(p);
}

pub export fn gst_registry_add_feature(r: [*c]Registry, f: [*c]Feature) c.gboolean {
    const fname = "gst_registry_add_feature";
    if (!check.that(isRegistry(r), fname, "GST_IS_REGISTRY (registry)")) return 0;
    if (!check.that(feature.isFeature(f), fname, "GST_IS_PLUGIN_FEATURE (feature)")) return 0;
    if (!check.that(feature.nameOf(f) != null, fname, "GST_OBJECT_NAME (feature) != NULL")) return 0;
    if (!check.that(f[0].plugin_name != null, fname, "feature->plugin_name != NULL")) return 0;
    lock(r);
    const old = feature.of(c.g_hash_table_lookup(r[0].priv.feature_hash, feature.nameOf(f)));
    if (old != null) r[0].priv.features = c.g_list_remove(r[0].priv.features, old);
    r[0].priv.features = c.g_list_prepend(r[0].priv.features, f);
    _ = c.g_hash_table_replace(r[0].priv.feature_hash, @constCast(feature.nameOf(f)), f);
    if (old != null) object.gst_object_unparent(@ptrCast(old));
    _ = object.gst_object_set_parent(@ptrCast(f), @ptrCast(r));
    r[0].priv.cookie +%= 1;
    unlock(r);
    c.g_signal_emit(r, feature_added, 0, f);
    return 1;
}

pub export fn gst_registry_remove_feature(r: [*c]Registry, f: [*c]Feature) void {
    if (!check.that(isRegistry(r), "gst_registry_remove_feature", "GST_IS_REGISTRY (registry)")) return;
    if (!check.that(feature.isFeature(f), "gst_registry_remove_feature", "GST_IS_PLUGIN_FEATURE (feature)")) return;
    lock(r);
    r[0].priv.features = c.g_list_remove(r[0].priv.features, f);
    _ = c.g_hash_table_remove(r[0].priv.feature_hash, feature.nameOf(f));
    r[0].priv.cookie +%= 1;
    unlock(r);
    object.gst_object_unparent(@ptrCast(f));
}

fn snapshot(r: [*c]Registry, list: ?*c.GList, n: usize) []c.gpointer {
    const arr: [*]c.gpointer = @ptrCast(@alignCast(c.g_malloc(@max(n, 1) * @sizeOf(c.gpointer))));
    var i: usize = 0;
    var l = list;
    while (l) |x| : (l = x.next) {
        arr[i] = c.gst_object_ref(x.data);
        i += 1;
    }
    _ = r;
    return arr[0..i];
}

fn runFilter(items: []c.gpointer, filter: anytype, first: c.gboolean, data: c.gpointer) ?*c.GList {
    var out: ?*c.GList = null;
    for (items) |it| {
        if (filter == null or filter.?(@ptrCast(@alignCast(it)), data) != 0) {
            out = c.g_list_prepend(out, c.gst_object_ref(it));
            if (first != 0) break;
        }
    }
    for (items) |it| c.gst_object_unref(it);
    c.g_free(@ptrCast(items.ptr));
    return out;
}

pub export fn gst_registry_plugin_filter(r: [*c]Registry, filter: c.GstPluginFilter, first: c.gboolean, data: c.gpointer) ?*c.GList {
    if (!check.that(isRegistry(r), "gst_registry_plugin_filter", "GST_IS_REGISTRY (registry)")) return null;
    lock(r);
    const items = snapshot(r, r[0].priv.plugins, r[0].priv.n_plugins);
    unlock(r);
    return runFilter(items, filter, first, data);
}

pub export fn gst_registry_feature_filter(r: [*c]Registry, filter: c.GstPluginFeatureFilter, first: c.gboolean, data: c.gpointer) ?*c.GList {
    if (!check.that(isRegistry(r), "gst_registry_feature_filter", "GST_IS_REGISTRY (registry)")) return null;
    lock(r);
    const items = snapshot(r, r[0].priv.features, c.g_hash_table_size(r[0].priv.feature_hash));
    unlock(r);
    return runFilter(items, filter, first, data);
}

pub export fn gst_registry_find_plugin(r: [*c]Registry, name: [*c]const u8) [*c]Plugin {
    if (!check.that(isRegistry(r), "gst_registry_find_plugin", "GST_IS_REGISTRY (registry)")) return null;
    if (!check.that(name != null, "gst_registry_find_plugin", "name != NULL")) return null;
    lock(r);
    defer unlock(r);
    var l = r[0].priv.plugins;
    while (l) |x| : (l = x.next) {
        const p = plugin.of(x.data);
        if (p[0].desc.name != null and c.strcmp(p[0].desc.name, name) == 0) return plugin.of(c.gst_object_ref(p));
    }
    return null;
}

pub export fn gst_registry_find_feature(r: [*c]Registry, name: [*c]const u8, t: c.GType) [*c]Feature {
    const fname = "gst_registry_find_feature";
    if (!check.that(isRegistry(r), fname, "GST_IS_REGISTRY (registry)")) return null;
    if (!check.that(name != null, fname, "name != NULL")) return null;
    if (!check.that(c.g_type_is_a(t, feature.gst_plugin_feature_get_type()) != 0, fname, "g_type_is_a (type, GST_TYPE_PLUGIN_FEATURE)")) return null;
    const f = gst_registry_lookup_feature(r, name);
    if (f != null and !gtype.instanceOf(f, t)) {
        c.gst_object_unref(f);
        return null;
    }
    return f;
}

fn sameType(f: [*c]Feature, t: c.GType) bool {
    return t == 0 or @as(*c.GTypeInstance, @ptrCast(@alignCast(f))).g_class.*.g_type == t;
}

fn cachedList(r: [*c]Registry, slot: usize, t: c.GType, sort: ?c.GCompareFunc) ?*c.GList {
    lock(r);
    defer unlock(r);
    const d = r[0].priv;
    if (d.lists[slot] == null or d.cookie != d.cookies[slot]) {
        if (d.lists[slot] != null) feature.gst_plugin_feature_list_free(d.lists[slot]);
        d.lists[slot] = null;
        var l = d.features;
        while (l) |x| : (l = x.next) {
            if (sameType(feature.of(x.data), t)) d.lists[slot] = c.g_list_prepend(d.lists[slot], c.gst_object_ref(x.data));
        }
        if (sort) |s| d.lists[slot] = c.g_list_sort(d.lists[slot], s);
        d.cookies[slot] = d.cookie;
    }
    return feature.gst_plugin_feature_list_copy(d.lists[slot]);
}

fn typeFilter(f: ?*c.GstPluginFeature, data: c.gpointer) callconv(.c) c.gboolean {
    return @intFromBool(sameType(feature.of(f), @intFromPtr(data)));
}

pub export fn gst_registry_get_feature_list(r: [*c]Registry, t: c.GType) ?*c.GList {
    if (!check.that(isRegistry(r), "gst_registry_get_feature_list", "GST_IS_REGISTRY (registry)")) return null;
    if (!check.that(c.g_type_is_a(t, feature.gst_plugin_feature_get_type()) != 0, "gst_registry_get_feature_list", "g_type_is_a (type, GST_TYPE_PLUGIN_FEATURE)")) return null;
    for (sorted, 0..) |entry, i| if (entry.get_type() == t) return cachedList(r, i, t, entry.sort);
    return gst_registry_feature_filter(r, typeFilter, 0, @ptrFromInt(t));
}

pub export fn gst_registry_get_plugin_list(r: [*c]Registry) ?*c.GList {
    if (!check.that(isRegistry(r), "gst_registry_get_plugin_list", "GST_IS_REGISTRY (registry)")) return null;
    lock(r);
    defer unlock(r);
    const list: ?*c.GList = c.g_list_copy(r[0].priv.plugins);
    var l = list;
    while (l) |x| : (l = x.next) _ = c.gst_object_ref(x.data);
    return list;
}

pub export fn gst_registry_lookup_feature(r: [*c]Registry, name: [*c]const u8) [*c]Feature {
    if (!check.that(isRegistry(r), "gst_registry_lookup_feature", "GST_IS_REGISTRY (registry)")) return null;
    if (!check.that(name != null, "gst_registry_lookup_feature", "name != NULL")) return null;
    lock(r);
    defer unlock(r);
    const f = c.g_hash_table_lookup(r[0].priv.feature_hash, name);
    if (f != null) _ = c.gst_object_ref(f);
    return feature.of(f);
}

fn lookupBasename(r: [*c]Registry, name: [*c]const u8) [*c]Plugin {
    lock(r);
    defer unlock(r);
    const p = byBasename(r, name);
    if (p != null) _ = c.gst_object_ref(p);
    return p;
}

pub export fn gst_registry_lookup(r: [*c]Registry, filename: [*c]const u8) [*c]Plugin {
    if (!check.that(isRegistry(r), "gst_registry_lookup", "GST_IS_REGISTRY (registry)")) return null;
    if (!check.that(filename != null, "gst_registry_lookup", "filename != NULL")) return null;
    const b = c.g_path_get_basename(filename);
    if (b == null) return null;
    defer c.g_free(b);
    return lookupBasename(r, b);
}

const Scan = struct {
    reg: [*c]Registry,
    state: enum { idle, off, running },
    helper: ?*loader.Loader = null,
    changed: bool = false,

    fn init(reg: [*c]Registry) Scan {
        var fork = fork_enabled;
        if (fork) if (c.g_getenv("GST_REGISTRY_FORK")) |e| {
            fork = std.mem.orderZ(u8, e, "no") != .eq;
        };
        return .{ .reg = reg, .state = if (fork) .idle else .off };
    }

    fn clear(s: *Scan) void {
        if (s.helper) |h| {
            s.changed = loader.destroy(h) or s.changed;
            s.helper = null;
        }
    }

    fn file(s: *Scan, filename: [*c]const u8, size: c.off_t, mtime: c.time_t) bool {
        if (s.state == .idle) {
            s.helper = loader.create(s.reg);
            s.state = if (s.helper != null) .running else .off;
        }
        if (s.state == .running and !loader.load(s.helper.?, filename, size, mtime)) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "External plugin loader failed. This most likely means that the plugin loader helper binary was not found or could not be run. You might need to set the GST_PLUGIN_SCANNER environment variable if your setup is unusual. This should normally not be required though.");
            s.state = .off;
        }
        var changed = false;
        if (s.state == .off) {
            const p = plugin.loadForRegistry(filename, s.reg, null);
            if (p != null) {
                p[0].registered = 1;
                c.gst_object_unref(p);
                changed = true;
            }
        }
        if (!reuse_scanner) {
            s.clear();
            if (s.state != .off) s.state = .idle;
        }
        return changed;
    }
};

fn skipDir(parent: [*c]const u8, name: [*c]const u8) bool {
    const n = std.mem.span(name);
    const p = std.mem.span(parent);
    if (std.mem.startsWith(u8, n, "hotdoc-private-")) return true;
    if (std.mem.eql(u8, n, "gst-integration-testsuites")) return true;
    if (std.mem.endsWith(u8, n, ".dSYM") or std.mem.endsWith(u8, p, ".dSYM")) return true;
    if (std.mem.indexOf(u8, p, "/target/")) |at| {
        const rest = p[at + 7 ..];
        if (std.mem.endsWith(u8, rest, "/debug") or std.mem.endsWith(u8, rest, "/release")) {
            if (n[0] == '.' or std.mem.eql(u8, n, "build") or std.mem.eql(u8, n, "deps") or std.mem.eql(u8, n, "incremental")) return true;
        }
    }
    if (n[0] != '.') return false;
    return std.mem.eql(u8, n, ".debug") or std.mem.eql(u8, n, ".git") or std.mem.eql(u8, n, ".deps");
}

fn scanLevel(s: *Scan, path: [*c]const u8, level: c_int) bool {
    const dir = c.g_dir_open(path, 0, null) orelse return false;
    defer c.g_dir_close(dir);
    var changed = false;
    while (c.g_dir_read_name(dir)) |ent| {
        const full = c.g_build_filename(path, ent, @as([*c]const u8, null));
        defer c.g_free(full);
        var st: c.struct_stat = undefined;
        if (c.stat(full, &st) < 0) continue;
        if (st.st_mode & c.S_IFDIR != 0) {
            if (skipDir(path, ent)) continue;
            if (level > 0) changed = scanLevel(s, full, level - 1) or changed;
            continue;
        }
        if (st.st_mode & c.S_IFREG == 0) continue;
        if (c.g_str_has_suffix(ent, ".so") == 0) continue;
        if (c.g_str_has_prefix(ent, "libgstvalve") != 0 or c.g_str_has_prefix(ent, "libgstselector") != 0) continue;
        const p = lookupBasename(s.reg, ent);
        if (p == null) {
            changed = s.file(full, st.st_size, st.st_mtim.tv_sec) or changed;
            continue;
        }
        defer c.gst_object_unref(p);
        if (p[0].registered != 0) continue;
        const env = plugin.envChanged(p);
        if (p[0].file_mtime == st.st_mtim.tv_sec and p[0].file_size == st.st_size and !env and !plugin.filesChanged(p) and c.strcmp(p[0].filename, full) == 0) {
            p[0].object.flags &= ~@as(c.guint32, c.GST_PLUGIN_FLAG_CACHED);
            p[0].registered = 1;
        } else {
            gst_registry_remove_plugin(s.reg, p);
            changed = s.file(full, st.st_size, st.st_mtim.tv_sec) or changed;
        }
    }
    return changed;
}

fn scanPath(s: *Scan, path: [*c]const u8) bool {
    return scanLevel(s, path, 10);
}

pub export fn gst_registry_scan_path(r: [*c]Registry, path: [*c]const u8) c.gboolean {
    if (!check.that(isRegistry(r), "gst_registry_scan_path", "GST_IS_REGISTRY (registry)")) return 0;
    if (!check.that(path != null, "gst_registry_scan_path", "path != NULL")) return 0;
    var s = Scan.init(r);
    var res = scanPath(&s, path);
    s.clear();
    res = res or s.changed;
    return @intFromBool(res);
}

fn byPluginName(f: ?*c.GstPluginFeature, data: c.gpointer) callconv(.c) c.gboolean {
    return @intFromBool(c.strcmp(feature.of(f)[0].plugin_name, @ptrCast(data)) == 0);
}

pub export fn gst_registry_get_feature_list_by_plugin(r: [*c]Registry, name: [*c]const u8) ?*c.GList {
    if (!check.that(isRegistry(r), "gst_registry_get_feature_list_by_plugin", "GST_IS_REGISTRY (registry)")) return null;
    if (!check.that(name != null, "gst_registry_get_feature_list_by_plugin", "name != NULL")) return null;
    return gst_registry_feature_filter(r, byPluginName, 0, @constCast(name));
}

pub fn featuresOf(r: [*c]Registry, p: [*c]Plugin) ?*c.GList {
    lock(r);
    defer unlock(r);
    var out: ?*c.GList = null;
    var l = r[0].priv.features;
    while (l) |x| : (l = x.next) {
        if (feature.of(x.data)[0].plugin == p) out = c.g_list_prepend(out, c.gst_object_ref(x.data));
    }
    return out;
}

pub fn cleanup() void {
    c.g_mutex_lock(&default_lock);
    const r = default_registry;
    default_registry = null;
    c.g_mutex_unlock(&default_lock);
    if (r != null) c.gst_object_unref(r);
}

pub export fn gst_registry_check_feature_version(r: [*c]Registry, name: [*c]const u8, major: c.guint, minor: c.guint, micro: c.guint) c.gboolean {
    if (!check.that(name != null, "gst_registry_check_feature_version", "feature_name != NULL")) return 0;
    const f = gst_registry_lookup_feature(r, name);
    if (f == null) return 0;
    defer c.gst_object_unref(f);
    return feature.gst_plugin_feature_check_version(f, major, minor, micro);
}

pub fn libDir() [*c]u8 {
    var dl: c.Dl_info = undefined;
    if (c.dladdr(@ptrCast(&core.gst_init), &dl) == 0 or dl.dli_fname == null) return null;
    var buf: [4096]u8 = undefined;
    if (c.realpath(dl.dli_fname, &buf) != null) return c.g_path_get_dirname(&buf);
    return c.g_path_get_dirname(dl.dli_fname);
}

pub fn dropCached(r: [*c]Registry) void {
    _ = removeCached(r);
}

fn removeCached(r: [*c]Registry) bool {
    lock(r);
    defer unlock(r);
    var changed = false;
    var l = r[0].priv.plugins;
    while (l) |x| {
        const next = x.next;
        const p = plugin.of(x.data);
        if (p[0].object.flags & c.GST_PLUGIN_FLAG_CACHED != 0) {
            r[0].priv.plugins = c.g_list_delete_link(r[0].priv.plugins, x);
            r[0].priv.n_plugins -= 1;
            if (p[0].basename != null) _ = c.g_hash_table_remove(r[0].priv.basename_hash, p[0].basename);
            dropFeaturesOf(r, p);
            c.gst_object_unref(p);
            changed = true;
        }
        l = next;
    }
    return changed;
}

fn scanEnvList(s: *Scan, list: [*c]const u8) bool {
    const parts = c.g_strsplit(list, ":", 0);
    defer c.g_strfreev(parts);
    var changed = false;
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) changed = scanPath(s, parts[i]) or changed;
    return changed;
}

fn envOr(a: [*:0]const u8, b: [*:0]const u8) [*c]const u8 {
    return c.g_getenv(a) orelse c.g_getenv(b);
}

fn scanAndUpdate(r: [*c]Registry, file: [*c]const u8) void {
    var s = Scan.init(r);
    var changed = false;
    var l = core.plugin_paths;
    while (l) |x| : (l = x.next) changed = scanPath(&s, @ptrCast(x.data)) or changed;
    if (envOr("GST_PLUGIN_PATH_1_0", "GST_PLUGIN_PATH")) |pp| changed = scanEnvList(&s, pp) or changed;
    if (envOr("GST_PLUGIN_SYSTEM_PATH_1_0", "GST_PLUGIN_SYSTEM_PATH")) |sp| {
        changed = scanEnvList(&s, sp) or changed;
    } else {
        const home = c.g_build_filename(c.g_get_user_data_dir(), "gstreamer-1.0", "plugins", @as([*c]const u8, null));
        changed = scanPath(&s, home) or changed;
        c.g_free(home);
        changed = scanPath(&s, std.fmt.comptimePrint("{s}", .{@import("config").plugin_dir})) or changed;
    }
    s.clear();
    changed = s.changed or changed;
    changed = removeCached(r) or changed;
    if (!changed) return;
    _ = regcache.write(r, file);
}

pub fn cacheFile() [*c]u8 {
    if (envOr("GST_REGISTRY_1_0", "GST_REGISTRY")) |f| return c.g_strdup(f);
    return c.g_build_filename(c.g_get_user_cache_dir(), "gstreamer-1.0", "sinty-registry.x86_64.bin", @as([*c]const u8, null));
}

fn ensureCurrent() void {
    const r = gst_registry_get();
    const file = cacheFile();
    defer c.g_free(file);
    var have_cache = true;
    var update = true;
    const flag = cacheFlag();
    if (flag.* == 0) {
        have_cache = regcache.read(r, file);
        flag.* = 1;
    }
    if (have_cache) {
        update = !core.registry_update_disabled;
        if (update) if (c.g_getenv("GST_REGISTRY_UPDATE")) |e| {
            update = std.mem.orderZ(u8, e, "no") != .eq;
        };
    }
    if (!update) return;
    if (c.g_getenv("GST_REGISTRY_REUSE_PLUGIN_SCANNER")) |e| reuse_scanner = std.mem.orderZ(u8, e, "no") != .eq;
    scanAndUpdate(r, file);
}

pub export fn gst_registry_fork_is_enabled() c.gboolean {
    return @intFromBool(fork_enabled);
}

pub export fn gst_registry_fork_set_enabled(enabled: c.gboolean) void {
    fork_enabled = enabled != 0;
}

pub export fn gst_update_registry() c.gboolean {
    if (!core.registry_disabled) ensureCurrent();
    var l = core.preload_plugins;
    while (l) |x| : (l = x.next) {
        var err: [*c]c.GError = null;
        const p = plugin.gst_plugin_load_file(@ptrCast(x.data), &err);
        if (p != null) {
            _ = gst_registry_add_plugin(gst_registry_get(), p);
        } else if (err != null) c.g_error_free(err);
    }
    return 1;
}

pub export fn gst_registry_get_feature_list_cookie(r: [*c]Registry) c.guint {
    if (!check.that(isRegistry(r), "gst_registry_get_feature_list_cookie", "GST_IS_REGISTRY (registry)")) return 0;
    return r[0].priv.cookie;
}
