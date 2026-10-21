const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Preset = c.GstPreset;
const Iface = c.GstPresetInterface;
const KeyFile = c.GKeyFile;

const HEADER = "_presets_";
const HEADER_NAME = "element-name";
const HEADER_VERSION = "version";
const DATADIR = "/usr/share";

var type_once: gtype.Once = .{};
var quark: c.GQuark = 0;
var user_quark: c.GQuark = 0;
var app_quark: c.GQuark = 0;
var system_quark: c.GQuark = 0;
var app_dir: [*c]u8 = null;

fn typeOf(p: ?*Preset) c.GType {
    return @as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class.*.g_type;
}

fn typeName(p: ?*Preset) [*c]const u8 {
    return c.g_type_name(typeOf(p));
}

fn ifaceOf(p: ?*Preset) *Iface {
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(p));
    return @ptrCast(@alignCast(c.g_type_interface_peek(inst.g_class, gst_preset_get_type())));
}

fn isPreset(p: ?*Preset) bool {
    return gtype.instanceOf(p, gst_preset_get_type());
}

fn isProxy(p: ?*Preset) bool {
    return gtype.instanceOf(p, c.gst_child_proxy_get_type());
}

fn cachedPath(t: c.GType, q: c.GQuark, dir: [*c]const u8, name: [*c]const u8, mkdir: bool) [*c]const u8 {
    const have: [*c]const u8 = @ptrCast(c.g_type_get_qdata(t, q));
    if (have != null) return have;
    const path = c.g_strdup_printf("%s/%s.prs", dir, name);
    if (mkdir) _ = c.g_mkdir_with_parents(dir, 0o755);
    c.g_type_set_qdata(t, q, path);
    return path;
}

fn userPath(p: ?*Preset) [*c]const u8 {
    const dir = c.g_build_filename(c.g_get_user_data_dir(), "gstreamer-1.0", "presets", @as([*c]const u8, null));
    defer c.g_free(dir);
    return cachedPath(typeOf(p), user_quark, dir, typeName(p), true);
}

fn appPath(p: ?*Preset) [*c]const u8 {
    if (app_dir == null) return null;
    return cachedPath(typeOf(p), app_quark, app_dir, typeName(p), false);
}

fn systemPath(p: ?*Preset) [*c]const u8 {
    const dir = c.g_build_filename(DATADIR, "gstreamer-1.0", "presets", @as([*c]const u8, null));
    defer c.g_free(dir);
    return cachedPath(typeOf(p), system_quark, dir, typeName(p), true);
}

fn skip(prop: [*c]c.GParamSpec) bool {
    return prop[0].flags & c.G_PARAM_READWRITE != c.G_PARAM_READWRITE or prop[0].flags & c.G_PARAM_CONSTRUCT_ONLY != 0;
}

fn parseVersion(s: [*c]const u8) u64 {
    if (s == null) return 0;
    var parts: [4]u64 = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    var i: usize = 0;
    while (n < 4) {
        const start = i;
        while (s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == start) break;
        parts[n] = std.fmt.parseInt(u32, s[start..i], 10) catch 0;
        n += 1;
        if (s[i] != '.') break;
        i += 1;
    }
    if (n <= 1) return 0;
    return ((((parts[0] << 8 | parts[1]) << 8) | parts[2]) << 8) | parts[3];
}

fn openFile(p: ?*Preset, path: [*c]const u8, version: ?*u64) ?*KeyFile {
    const kf = c.g_key_file_new() orelse return null;
    var err: [*c]c.GError = null;
    if (c.g_key_file_load_from_file(kf, path, c.G_KEY_FILE_KEEP_COMMENTS | c.G_KEY_FILE_KEEP_TRANSLATIONS, &err) == 0 or err != null) {
        if (err != null) c.g_error_free(err);
        c.g_key_file_free(kf);
        return null;
    }
    const name = c.g_key_file_get_value(kf, HEADER, HEADER_NAME, null);
    defer c.g_free(name);
    if (name == null or c.strcmp(name, typeName(p)) != 0) {
        c.g_key_file_free(kf);
        return null;
    }
    if (version) |v| {
        const s = c.g_key_file_get_value(kf, HEADER, HEADER_VERSION, null);
        v.* = parseVersion(s);
        c.g_free(s);
    }
    return kf;
}

fn merge(system: ?*KeyFile, user: ?*KeyFile) void {
    var s = c.g_key_file_get_comment(user, null, null, null);
    if (s != null) {
        _ = c.g_key_file_set_comment(system, null, null, s, null);
        c.g_free(s);
    }
    var ng: c.gsize = 0;
    const groups = c.g_key_file_get_groups(user, &ng);
    defer c.g_strfreev(groups);
    var i: usize = 0;
    while (i < ng) : (i += 1) {
        const grp = groups[i];
        s = c.g_key_file_get_comment(user, grp, null, null);
        if (s != null) {
            _ = c.g_key_file_set_comment(system, grp, null, s, null);
            c.g_free(s);
        }
        if (grp[0] == '_') continue;
        if (c.g_key_file_has_group(system, grp) != 0) _ = c.g_key_file_remove_group(system, grp, null);
        var nk: c.gsize = 0;
        const keys = c.g_key_file_get_keys(user, grp, &nk, null);
        defer c.g_strfreev(keys);
        var j: usize = 0;
        while (j < nk) : (j += 1) {
            s = c.g_key_file_get_comment(user, grp, keys[j], null);
            if (s != null) {
                _ = c.g_key_file_set_comment(system, grp, keys[j], s, null);
                c.g_free(s);
            }
            s = c.g_key_file_get_value(user, grp, keys[j], null);
            c.g_key_file_set_value(system, grp, keys[j], s);
            c.g_free(s);
        }
    }
}

const Versioned = struct { kf: ?*KeyFile, version: u64 };

fn newer(_: void, a: Versioned, b: Versioned) bool {
    return a.version > b.version;
}

fn adopt(presets: *?*KeyFile, version: *u64, kf: ?*KeyFile, v: u64) bool {
    if (version.* > v) {
        merge(presets.*, kf);
        c.g_key_file_free(kf);
        return true;
    }
    if (presets.*) |old| c.g_key_file_free(old);
    presets.* = kf;
    version.* = v;
    return false;
}

fn keyfile(p: ?*Preset) ?*KeyFile {
    const t = typeOf(p);
    if (c.g_type_get_qdata(t, quark)) |kf| return @ptrCast(kf);
    var v_user: u64 = 0;
    var v_app: u64 = 0;
    var v_system: u64 = 0;
    var version: u64 = 0;
    var merged = false;
    const user_path = userPath(p);
    const app_path = appPath(p);
    const in_user = openFile(p, user_path, &v_user);
    const in_app = if (app_path != null) openFile(p, app_path, &v_app) else null;
    var env: std.ArrayListUnmanaged(Versioned) = .empty;
    defer env.deinit(std.heap.c_allocator);
    if (c.g_getenv("GST_PRESET_PATH")) |envvar| {
        const dirs = c.g_strsplit(envvar, ":", -1);
        defer c.g_strfreev(dirs);
        var i: usize = 0;
        while (dirs[i] != null) : (i += 1) {
            const path = c.g_strdup_printf("%s/%s.prs", dirs[i], typeName(p));
            var v: u64 = 0;
            const kf = openFile(p, path, &v);
            c.g_free(path);
            if (kf != null) env.append(std.heap.c_allocator, .{ .kf = kf, .version = v }) catch {};
        }
    }
    var presets: ?*KeyFile = null;
    const in_system = openFile(p, systemPath(p), &v_system);
    if (in_system != null) {
        presets = in_system;
        version = v_system;
    }
    std.mem.sort(Versioned, env.items, {}, newer);
    for (env.items) |e| _ = adopt(&presets, &version, e.kf, e.version);
    if (in_app != null) _ = adopt(&presets, &version, in_app, v_app);
    if (in_user != null) {
        if (version > v_user) {
            merge(presets, in_user);
            c.g_key_file_free(in_user);
            merged = true;
        } else {
            if (presets) |old| c.g_key_file_free(old);
            presets = in_user;
        }
    }
    if (presets == null) {
        presets = c.g_key_file_new();
        c.g_key_file_set_string(presets, HEADER, HEADER_NAME, typeName(p));
    }
    c.g_type_set_qdata(t, quark, presets);
    if (merged) _ = saveFile(p);
    return presets;
}

fn byString(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const x: *const [*c]const u8 = @ptrCast(@alignCast(a));
    const y: *const [*c]const u8 = @ptrCast(@alignCast(b));
    return c.g_strcmp0(x.*, y.*);
}

fn defaultNames(p: ?*Preset) callconv(.c) [*c][*c]u8 {
    const presets = keyfile(p) orelse return null;
    var n: c.gsize = 0;
    const groups = c.g_key_file_get_groups(presets, &n);
    if (groups == null) return null;
    var i: usize = 0;
    while (i < n) {
        if (groups[i][0] == '_') {
            c.g_free(groups[i]);
            n -= 1;
            groups[i] = groups[n];
            groups[n] = null;
        } else i += 1;
    }
    if (n == 0) {
        c.g_strfreev(groups);
        return null;
    }
    c.g_sort_array(@ptrCast(groups), n, @sizeOf([*c]u8), byString, null);
    return groups;
}

fn appendProps(result: *std.ArrayListUnmanaged([*c]u8), klass: *c.GObjectClass, prefix: [*c]const u8) void {
    var n: c.guint = 0;
    const props = c.g_object_class_list_properties(klass, &n);
    defer c.g_free(@ptrCast(props));
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        if (skip(props[i])) continue;
        const name = if (prefix != null) c.g_strdup_printf("%s::%s", prefix, props[i][0].name) else c.g_strdup(props[i][0].name);
        result.append(std.heap.c_allocator, name) catch {};
    }
}

fn defaultPropertyNames(p: ?*Preset) callconv(.c) [*c][*c]u8 {
    var result: std.ArrayListUnmanaged([*c]u8) = .empty;
    defer result.deinit(std.heap.c_allocator);
    appendProps(&result, gtype.classPeek(c.GObjectClass, p), null);
    if (isProxy(p)) {
        const n = c.gst_child_proxy_get_children_count(@ptrCast(p));
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const child = c.gst_child_proxy_get_child_by_index(@ptrCast(p), i);
            appendProps(&result, gtype.classPeek(c.GObjectClass, child), @as([*c]c.GstObject, @ptrCast(@alignCast(child)))[0].name);
            c.gst_object_unref(child);
        }
    }
    const arr: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc((result.items.len + 1) * @sizeOf([*c]u8))));
    for (result.items, 0..) |s, i| arr[i] = s;
    arr[result.items.len] = null;
    return arr;
}

fn lookupProperty(p: ?*Preset, name: [*c]const u8) [*c]c.GParamSpec {
    var prop: [*c]c.GParamSpec = null;
    if (isProxy(p)) {
        _ = c.gst_child_proxy_lookup(@ptrCast(p), name, null, &prop);
    } else prop = c.g_object_class_find_property(gtype.classPeek(c.GObjectClass, p), name);
    return prop;
}

fn defaultLoad(p: ?*Preset, name: [*c]const u8) callconv(.c) c.gboolean {
    const presets = keyfile(p) orelse return 0;
    if (c.g_key_file_has_group(presets, name) == 0) return 0;
    const props = gst_preset_get_property_names(p);
    if (props == null) return 0;
    defer c.g_strfreev(props);
    var i: usize = 0;
    while (props[i] != null) : (i += 1) {
        const str = c.g_key_file_get_value(presets, name, props[i], null);
        if (str == null) continue;
        defer c.g_free(str);
        const prop = lookupProperty(p, props[i]);
        if (prop == null) continue;
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, prop[0].value_type);
        if (c.gst_value_deserialize(&v, str) != 0) {
            if (isProxy(p)) c.gst_child_proxy_set_property(@ptrCast(p), props[i], &v) else c.g_object_set_property(@ptrCast(@alignCast(p)), props[i], &v);
        }
        c.g_value_unset(&v);
    }
    return 1;
}

fn saveFile(p: ?*Preset) bool {
    const path = userPath(p);
    const presets = keyfile(p) orelse {
        _ = c.unlink(path);
        return false;
    };
    const bak = c.g_strdup_printf("%s.bak", path);
    var backup = true;
    if (c.g_file_test(bak, c.G_FILE_TEST_EXISTS) != 0 and c.unlink(bak) != 0) backup = false;
    if (backup) _ = c.rename(path, bak);
    c.g_free(bak);
    c.g_key_file_set_string(presets, HEADER, HEADER_VERSION, "1.28.2");
    var err: [*c]c.GError = null;
    var size: c.gsize = 0;
    const data = c.g_key_file_to_data(presets, &size, &err);
    defer c.g_free(data);
    if (data == null) {
        if (err != null) c.g_error_free(err);
        return false;
    }
    if (c.g_file_set_contents(path, data, @intCast(size), &err) == 0) {
        if (err != null) c.g_error_free(err);
        return false;
    }
    return true;
}

fn defaultSave(p: ?*Preset, name: [*c]const u8) callconv(.c) c.gboolean {
    const presets = keyfile(p) orelse return 0;
    const props = gst_preset_get_property_names(p);
    if (props == null) return 0;
    defer c.g_strfreev(props);
    var i: usize = 0;
    while (props[i] != null) : (i += 1) {
        const prop = lookupProperty(p, props[i]);
        if (prop == null or prop[0].flags & c.G_PARAM_DEPRECATED != 0) continue;
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, prop[0].value_type);
        if (isProxy(p)) c.gst_child_proxy_get_property(@ptrCast(p), props[i], &v) else c.g_object_get_property(@ptrCast(@alignCast(p)), props[i], &v);
        const str = c.gst_value_serialize(&v);
        if (str != null) {
            c.g_key_file_set_string(presets, name, props[i], str);
            c.g_free(str);
        }
        c.g_value_unset(&v);
    }
    return @intFromBool(saveFile(p));
}

fn defaultRename(p: ?*Preset, old: [*c]const u8, new: [*c]const u8) callconv(.c) c.gboolean {
    const presets = keyfile(p) orelse return 0;
    if (c.g_key_file_has_group(presets, old) == 0) return 0;
    var s = c.g_key_file_get_comment(presets, old, null, null);
    if (s != null) {
        _ = c.g_key_file_set_comment(presets, new, null, s, null);
        c.g_free(s);
    }
    var n: c.gsize = 0;
    const keys = c.g_key_file_get_keys(presets, old, &n, null);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        s = c.g_key_file_get_comment(presets, old, keys[i], null);
        if (s != null) {
            _ = c.g_key_file_set_comment(presets, new, keys[i], s, null);
            c.g_free(s);
        }
        s = c.g_key_file_get_value(presets, old, keys[i], null);
        c.g_key_file_set_value(presets, new, keys[i], s);
        c.g_free(s);
    }
    c.g_strfreev(keys);
    _ = c.g_key_file_remove_group(presets, old, null);
    return @intFromBool(saveFile(p));
}

fn defaultDelete(p: ?*Preset, name: [*c]const u8) callconv(.c) c.gboolean {
    const presets = keyfile(p) orelse return 0;
    if (c.g_key_file_has_group(presets, name) == 0) return 0;
    _ = c.g_key_file_remove_group(presets, name, null);
    return @intFromBool(saveFile(p));
}

fn defaultSetMeta(p: ?*Preset, name: [*c]const u8, tag: [*c]const u8, value: [*c]const u8) callconv(.c) c.gboolean {
    const presets = keyfile(p) orelse return 0;
    const key = c.g_strdup_printf("_meta/%s", tag);
    if (value != null and value[0] != 0) c.g_key_file_set_value(presets, name, key, value) else _ = c.g_key_file_remove_key(presets, name, key, null);
    c.g_free(key);
    return @intFromBool(saveFile(p));
}

fn defaultGetMeta(p: ?*Preset, name: [*c]const u8, tag: [*c]const u8, value: [*c][*c]u8) callconv(.c) c.gboolean {
    const presets = keyfile(p) orelse {
        value.* = null;
        return 0;
    };
    const key = c.g_strdup_printf("_meta/%s", tag);
    value.* = c.g_key_file_get_value(presets, name, key, null);
    c.g_free(key);
    return 1;
}

pub export fn gst_preset_get_preset_names(p: ?*Preset) [*c][*c]u8 {
    if (!check.that(isPreset(p), "gst_preset_get_preset_names", "GST_IS_PRESET (preset)")) return null;
    return ifaceOf(p).get_preset_names.?(p);
}

pub export fn gst_preset_get_property_names(p: ?*Preset) [*c][*c]u8 {
    if (!check.that(isPreset(p), "gst_preset_get_property_names", "GST_IS_PRESET (preset)")) return null;
    return ifaceOf(p).get_property_names.?(p);
}

pub export fn gst_preset_load_preset(p: ?*Preset, name: [*c]const u8) c.gboolean {
    if (!check.that(isPreset(p), "gst_preset_load_preset", "GST_IS_PRESET (preset)")) return 0;
    if (!check.that(name != null, "gst_preset_load_preset", "name")) return 0;
    return ifaceOf(p).load_preset.?(p, name);
}

pub export fn gst_preset_save_preset(p: ?*Preset, name: [*c]const u8) c.gboolean {
    if (!check.that(isPreset(p), "gst_preset_save_preset", "GST_IS_PRESET (preset)")) return 0;
    if (!check.that(name != null, "gst_preset_save_preset", "name")) return 0;
    return ifaceOf(p).save_preset.?(p, name);
}

pub export fn gst_preset_rename_preset(p: ?*Preset, old: [*c]const u8, new: [*c]const u8) c.gboolean {
    if (!check.that(isPreset(p), "gst_preset_rename_preset", "GST_IS_PRESET (preset)")) return 0;
    if (!check.that(old != null, "gst_preset_rename_preset", "old_name")) return 0;
    if (!check.that(new != null, "gst_preset_rename_preset", "new_name")) return 0;
    return ifaceOf(p).rename_preset.?(p, old, new);
}

pub export fn gst_preset_delete_preset(p: ?*Preset, name: [*c]const u8) c.gboolean {
    if (!check.that(isPreset(p), "gst_preset_delete_preset", "GST_IS_PRESET (preset)")) return 0;
    if (!check.that(name != null, "gst_preset_delete_preset", "name")) return 0;
    return ifaceOf(p).delete_preset.?(p, name);
}

pub export fn gst_preset_set_meta(p: ?*Preset, name: [*c]const u8, tag: [*c]const u8, value: [*c]const u8) c.gboolean {
    if (!check.that(isPreset(p), "gst_preset_set_meta", "GST_IS_PRESET (preset)")) return 0;
    if (!check.that(name != null, "gst_preset_set_meta", "name")) return 0;
    if (!check.that(tag != null, "gst_preset_set_meta", "tag")) return 0;
    return ifaceOf(p).set_meta.?(p, name, tag, value);
}

pub export fn gst_preset_get_meta(p: ?*Preset, name: [*c]const u8, tag: [*c]const u8, value: [*c][*c]u8) c.gboolean {
    if (!check.that(isPreset(p), "gst_preset_get_meta", "GST_IS_PRESET (preset)")) return 0;
    if (!check.that(name != null, "gst_preset_get_meta", "name")) return 0;
    if (!check.that(tag != null, "gst_preset_get_meta", "tag")) return 0;
    if (!check.that(value != null, "gst_preset_get_meta", "value")) return 0;
    return ifaceOf(p).get_meta.?(p, name, tag, value);
}

pub export fn gst_preset_set_app_dir(dir: [*c]const u8) c.gboolean {
    if (!check.that(dir != null, "gst_preset_set_app_dir", "app_dir")) return 0;
    if (app_dir != null) return 0;
    app_dir = c.g_strdup(dir);
    return 1;
}

pub export fn gst_preset_get_app_dir() [*c]const u8 {
    return app_dir;
}

pub export fn gst_preset_is_editable(p: ?*Preset) c.gboolean {
    const i = ifaceOf(p);
    return @intFromBool(i.save_preset != null and i.delete_preset != null);
}

fn classInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *Iface = @ptrCast(@alignCast(g));
    i.get_preset_names = defaultNames;
    i.get_property_names = defaultPropertyNames;
    i.load_preset = defaultLoad;
    i.save_preset = defaultSave;
    i.rename_preset = defaultRename;
    i.delete_preset = defaultDelete;
    i.set_meta = defaultSetMeta;
    i.get_meta = defaultGetMeta;
}

fn baseInit(_: c.gpointer) callconv(.c) void {
    if (quark != 0) return;
    quark = c.g_quark_from_static_string("GstPreset::presets");
    user_quark = c.g_quark_from_static_string("GstPreset::user_path");
    app_quark = c.g_quark_from_static_string("GstPreset::app_path");
    system_quark = c.g_quark_from_static_string("GstPreset::system_path");
}

pub export fn gst_preset_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const info = c.GTypeInfo{ .class_size = @sizeOf(Iface), .base_init = baseInit, .base_finalize = null, .class_init = classInit, .class_finalize = null, .class_data = null, .instance_size = 0, .n_preallocs = 0, .instance_init = null, .value_table = null };
            return c.g_type_register_static(c.G_TYPE_INTERFACE, "GstPreset", &info, 0);
        }
    }.f);
}
