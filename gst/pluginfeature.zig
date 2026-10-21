const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const tracer = @import("tracer.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const plugin = @import("plugin.zig");
const registry = @import("registry.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub const Feature = extern struct {
    object: c.GstObject,
    loaded: c.gboolean,
    rank: c.guint,
    plugin_name: [*c]const u8,
    plugin: [*c]plugin.Plugin,
    reserved: [4]c.gpointer,

    pub const Header = c.struct__GstPluginFeature;
};

pub const FeatureClass = extern struct {
    parent_class: c.GstObjectClass,
    reserved: [4]c.gpointer,
};

var type_once: gtype.Once = .{};
var parent_class: ?*c.GObjectClass = null;

pub fn of(p: anytype) [*c]Feature {
    return @ptrCast(@alignCast(p));
}

pub fn isFeature(p: anytype) bool {
    return gtype.instanceOf(p, gst_plugin_feature_get_type());
}

pub fn nameOf(f: anytype) [*c]const u8 {
    return of(f)[0].object.name;
}

pub export fn gst_plugin_feature_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.object(object.gst_object_get_type, "GstPluginFeature", FeatureClass, Feature, classInit, null, c.G_TYPE_FLAG_ABSTRACT);
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(klass))).finalize = finalize;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const f = of(o);
    if (f[0].plugin != null) c.g_object_remove_weak_pointer(@ptrCast(f[0].plugin), @ptrCast(&f[0].plugin));
    parent_class.?.finalize.?(o);
}

pub fn bindPlugin(f: [*c]Feature, p: [*c]plugin.Plugin) void {
    if (p != null and p[0].desc.name != null) {
        f[0].plugin_name = p[0].desc.name;
        f[0].plugin = p;
        c.g_object_add_weak_pointer(@ptrCast(p), @ptrCast(&f[0].plugin));
    } else {
        f[0].plugin_name = "NULL";
        f[0].plugin = null;
    }
}

pub export fn gst_plugin_feature_load(f: [*c]Feature) [*c]Feature {
    if (!check.that(f != null, "gst_plugin_feature_load", "feature != NULL")) return null;
    if (!check.that(isFeature(f), "gst_plugin_feature_load", "GST_IS_PLUGIN_FEATURE (feature)")) return null;
    if (f[0].loaded != 0) return of(c.gst_object_ref(f));
    const p = plugin.gst_plugin_load_by_name(f[0].plugin_name);
    if (p == null) return null;
    c.gst_object_unref(p);
    const real = registry.gst_registry_lookup_feature(registry.gst_registry_get(), nameOf(f));
    if (real == null) return null;
    if (real[0].loaded == 0) {
        c.gst_object_unref(real);
        return null;
    }
    tracer.emit(.plugin_feature_loaded, .{real});
    return real;
}

pub export fn gst_plugin_feature_set_rank(f: [*c]Feature, rank: c.guint) void {
    if (!check.that(f != null, "gst_plugin_feature_set_rank", "feature != NULL")) return;
    if (!check.that(isFeature(f), "gst_plugin_feature_set_rank", "GST_IS_PLUGIN_FEATURE (feature)")) return;
    f[0].rank = rank;
}

pub export fn gst_plugin_feature_get_rank(f: [*c]Feature) c.guint {
    if (!check.that(isFeature(f), "gst_plugin_feature_get_rank", "GST_IS_PLUGIN_FEATURE (feature)")) return c.GST_RANK_NONE;
    return f[0].rank;
}

pub export fn gst_plugin_feature_get_plugin(f: [*c]Feature) [*c]plugin.Plugin {
    if (!check.that(isFeature(f), "gst_plugin_feature_get_plugin", "GST_IS_PLUGIN_FEATURE (feature)")) return null;
    if (f[0].plugin == null) return null;
    return @ptrCast(@alignCast(c.gst_object_ref(f[0].plugin)));
}

pub export fn gst_plugin_feature_get_plugin_name(f: [*c]Feature) [*c]const u8 {
    if (!check.that(isFeature(f), "gst_plugin_feature_get_plugin_name", "GST_IS_PLUGIN_FEATURE (feature)")) return null;
    if (f[0].plugin == null) return null;
    return plugin.gst_plugin_get_name(f[0].plugin);
}

pub export fn gst_plugin_feature_list_free(list: ?*c.GList) void {
    var g = list;
    while (g) |n| : (g = n.next) c.gst_object_unref(n.data);
    c.g_list_free(list);
}

pub export fn gst_plugin_feature_list_copy(list: ?*c.GList) ?*c.GList {
    var out: ?*c.GList = null;
    var g = list;
    while (g) |n| : (g = n.next) out = c.g_list_prepend(out, c.gst_object_ref(n.data));
    return c.g_list_reverse(out);
}

pub export fn gst_plugin_feature_list_debug(_: ?*c.GList) void {}

fn versionAtLeast(v: [*c]const u8, major: c.guint, minor: c.guint, micro: c.guint) bool {
    const s = std.mem.span(v);
    var got: [3]c.guint = undefined;
    var i: usize = 0;
    for (&got, 0..) |*g, n| {
        if (n > 0) {
            if (i >= s.len or s[i] != '.') return false;
            i += 1;
        }
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return false;
        g.* = std.fmt.parseInt(c.guint, s[start..i], 10) catch return false;
    }
    const want = [3]c.guint{ major, minor, micro };
    for (got, want) |a, b| {
        if (a > b) return true;
        if (a < b) return false;
    }
    return true;
}

pub export fn gst_plugin_feature_check_version(f: [*c]Feature, major: c.guint, minor: c.guint, micro: c.guint) c.gboolean {
    if (!check.that(f != null, "gst_plugin_feature_check_version", "feature != NULL")) return 0;
    if (!check.that(isFeature(f), "gst_plugin_feature_check_version", "GST_IS_PLUGIN_FEATURE (feature)")) return 0;
    const p = registry.gst_registry_find_plugin(registry.gst_registry_get(), f[0].plugin_name);
    if (p == null) return 0;
    defer c.gst_object_unref(p);
    const v = plugin.gst_plugin_get_version(p);
    if (!check.that(v != null, "gst_plugin_feature_check_version", "ver_str != NULL")) return 0;
    return @intFromBool(versionAtLeast(v, major, minor, micro));
}

pub export fn gst_plugin_feature_rank_compare_func(a: c.gconstpointer, b: c.gconstpointer) c.gint {
    const fa = of(@constCast(a));
    const fb = of(@constCast(b));
    const diff = @as(c.gint, @bitCast(fb[0].rank)) -% @as(c.gint, @bitCast(fa[0].rank));
    if (diff != 0) return diff;
    return c.strcmp(nameOf(fa), nameOf(fb));
}

fn parseRank(s: []const u8) ?c.guint {
    if (s.len == 0) return null;
    if (std.ascii.isDigit(s[0])) return std.fmt.parseInt(c.guint, s, 10) catch null;
    const named = [_]struct { []const u8, c.guint }{
        .{ "NONE", c.GST_RANK_NONE },     .{ "MARGINAL", c.GST_RANK_MARGINAL },
        .{ "SECONDARY", c.GST_RANK_SECONDARY }, .{ "PRIMARY", c.GST_RANK_PRIMARY },
        .{ "MAX", std.math.maxInt(c.gint) },
    };
    for (named) |n| if (std.ascii.eqlIgnoreCase(s, n[0])) return n[1];
    return null;
}

pub fn applyRankEnv() void {
    const env = c.g_getenv("GST_PLUGIN_FEATURE_RANK") orelse return;
    var items = std.mem.splitScalar(u8, std.mem.span(env), ',');
    while (items.next()) |item| {
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
        const name = std.mem.trim(u8, item[0..colon], " \t\r\n");
        const rank = parseRank(std.mem.trim(u8, item[colon + 1 ..], " \t\r\n")) orelse continue;
        if (name.len == 0) continue;
        const z = c.g_strndup(name.ptr, name.len);
        defer c.g_free(z);
        const f = registry.gst_registry_find_feature(registry.gst_registry_get(), z, @import("elementfactory.zig").gst_element_factory_get_type());
        if (f == null) continue;
        gst_plugin_feature_set_rank(f, rank);
        c.gst_object_unref(f);
    }
}
