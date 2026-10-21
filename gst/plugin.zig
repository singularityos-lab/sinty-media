const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const registry = @import("registry.zig");
const core = @import("core.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub const Plugin = extern struct {
    object: c.GstObject,
    desc: c.GstPluginDesc,
    filename: [*c]u8,
    basename: [*c]u8,
    module: ?*c.GModule,
    file_size: c.off_t,
    file_mtime: c.time_t,
    registered: c.gboolean,
    priv: *Private,
    reserved: [4]c.gpointer,

    pub const Header = c.struct__GstPlugin;
};

const PluginClass = extern struct {
    object_class: c.GstObjectClass,
    reserved: [4]c.gpointer,
};

pub const Private = extern struct {
    deps: ?*c.GList,
    status_info: [*c]c.GstStructure,
    cache_data: [*c]c.GstStructure,
};

pub const Dep = extern struct {
    flags: c.GstPluginDependencyFlags,
    env_vars: [*c][*c]u8,
    paths: [*c][*c]u8,
    names: [*c][*c]u8,
    env_hash: c.guint,
    stat_hash: c.guint,
};

const Desc = c.GstPluginDesc;
const Obj = c.GstObject;

var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var inited = false;
var whitelist: [*c][*c]u8 = null;
var loading = std.mem.zeroes(c.GRecMutex);
var fault_file: [*c]const u8 = null;
var fault_set = false;
var old_action: c.struct_sigaction = undefined;
pub var api_quark: c.GQuark = 0;
pub var api_flags_quark: c.GQuark = 0;

const known_licenses = [_][]const u8{ "LGPL", "GPL", "QPL", "GPL/QPL", "MPL", "MPL-2.0", "BSD", "MIT/X11", "0BSD", "Apache 2.0", "Proprietary", "unknown" };

pub fn of(p: anytype) [*c]Plugin {
    return @ptrCast(@alignCast(p));
}

pub fn isPlugin(p: anytype) bool {
    return gtype.instanceOf(p, gst_plugin_get_type());
}

pub export fn gst_plugin_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstPlugin", PluginClass, Plugin, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(klass))).finalize = finalize;
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = of(instance);
    const base: [*]u8 = @ptrCast(instance);
    p[0].priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p = of(o);
    c.g_free(p[0].filename);
    c.g_free(p[0].basename);
    var l = p[0].priv.deps;
    while (l) |n| : (l = n.next) freeDep(@ptrCast(@alignCast(n.data)));
    c.g_list_free(p[0].priv.deps);
    p[0].priv.deps = null;
    if (p[0].priv.cache_data != null) c.gst_structure_free(p[0].priv.cache_data);
    if (p[0].priv.status_info != null) c.gst_structure_free(p[0].priv.status_info);
    parent_class.?.finalize.?(o);
}

pub export fn gst_plugin_error_quark() c.GQuark {
    const S = struct {
        var q: c.GQuark = 0;
    };
    if (S.q == 0) S.q = c.g_quark_from_static_string("gst_plugin_error");
    return S.q;
}

pub fn initialize() void {
    inited = true;
    api_quark = c.g_quark_from_static_string("plugin-api");
    api_flags_quark = c.g_quark_from_static_string("plugin-api-flags");
    const w = c.g_getenv("GST_PLUGIN_LOADING_WHITELIST");
    if (w != null and w[0] != 0) whitelist = c.g_strsplit(w, ":", -1);
}

fn registerStatic(desc: *const Desc, data: c.gpointer) c.gboolean {
    const p = of(c.g_object_new(gst_plugin_get_type(), @as([*c]const u8, null)));
    if (registerFunc(p, desc, data) == null) return 0;
    return registry.gst_registry_add_plugin(registry.gst_registry_get(), p);
}

pub export fn gst_plugin_register_static(major: c.gint, minor: c.gint, name: [*c]const u8, description: [*c]const u8, init: c.GstPluginInitFunc, version: [*c]const u8, license: [*c]const u8, source: [*c]const u8, package: [*c]const u8, origin: [*c]const u8) c.gboolean {
    const f = "gst_plugin_register_static";
    if (!check.that(name != null, f, "name != NULL")) return 0;
    if (!check.that(description != null, f, "description != NULL")) return 0;
    if (!check.that(init != null, f, "init_func != NULL")) return 0;
    if (!check.that(version != null, f, "version != NULL")) return 0;
    if (!check.that(license != null, f, "license != NULL")) return 0;
    if (!check.that(source != null, f, "source != NULL")) return 0;
    if (!check.that(package != null, f, "package != NULL")) return 0;
    if (!check.that(origin != null, f, "origin != NULL")) return 0;
    if (!check.that(inited, f, "_gst_plugin_inited != FALSE")) return 0;
    const desc = Desc{ .major_version = major, .minor_version = minor, .name = name, .description = description, .plugin_init = init, .version = version, .license = license, .source = source, .package = package, .origin = origin, .release_datetime = null, ._gst_reserved = .{null} ** 4 };
    return registerStatic(&desc, null);
}

pub export fn gst_plugin_register_static_full(major: c.gint, minor: c.gint, name: [*c]const u8, description: [*c]const u8, init: c.GstPluginInitFullFunc, version: [*c]const u8, license: [*c]const u8, source: [*c]const u8, package: [*c]const u8, origin: [*c]const u8, data: c.gpointer) c.gboolean {
    const f = "gst_plugin_register_static_full";
    if (!check.that(name != null, f, "name != NULL")) return 0;
    if (!check.that(description != null, f, "description != NULL")) return 0;
    if (!check.that(init != null, f, "init_full_func != NULL")) return 0;
    if (!check.that(version != null, f, "version != NULL")) return 0;
    if (!check.that(license != null, f, "license != NULL")) return 0;
    if (!check.that(source != null, f, "source != NULL")) return 0;
    if (!check.that(package != null, f, "package != NULL")) return 0;
    if (!check.that(origin != null, f, "origin != NULL")) return 0;
    if (!check.that(inited, f, "_gst_plugin_inited != FALSE")) return 0;
    const desc = Desc{ .major_version = major, .minor_version = minor, .name = name, .description = description, .plugin_init = @ptrCast(init), .version = version, .license = license, .source = source, .package = package, .origin = origin, .release_datetime = null, ._gst_reserved = .{null} ** 4 };
    return registerStatic(&desc, data);
}

fn matchesEntry(desc: *const Desc, filename: [*c]const u8, pattern: [*c]const u8) bool {
    const pat = std.mem.span(pattern);
    if (std.mem.eql(u8, pat, "*")) return true;
    var name_part: []const u8 = pat;
    if (std.mem.indexOfScalar(u8, pat, '@')) |at| {
        const sep = pat[at..];
        if (!std.mem.eql(u8, sep, "@*") and !std.mem.eql(u8, sep, "@")) {
            if (filename != null and !std.mem.startsWith(u8, std.mem.span(filename), sep[1..])) return false;
        }
        name_part = pat[0..at];
    }
    const name = std.mem.trim(u8, name_part, " \t\n\r\x0b\x0c");
    if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) return false;
    if (std.mem.indexOfScalar(u8, name, ',') == null)
        return std.mem.eql(u8, std.mem.span(desc.source), name) or std.mem.eql(u8, std.mem.span(desc.name), name);
    var it = std.mem.splitScalar(u8, name, ',');
    while (it.next()) |n| if (std.mem.eql(u8, std.mem.span(desc.name), std.mem.trim(u8, n, " \t\n\r\x0b\x0c"))) return true;
    return false;
}

pub fn whitelisted(desc: *const Desc, filename: [*c]const u8) bool {
    if (whitelist == null) return true;
    var i: usize = 0;
    while (whitelist[i] != null) : (i += 1) if (matchesEntry(desc, filename, whitelist[i])) return true;
    return false;
}

pub fn haveWhitelist() bool {
    return whitelist != null;
}

pub fn whitelistHash() u32 {
    var hash: u32 = 0;
    if (whitelist == null) return 0;
    var i: usize = 0;
    while (whitelist[i] != null) : (i += 1) hash ^= c.g_str_hash(whitelist[i]);
    return hash;
}

fn knownLicense(l: [*c]const u8) bool {
    const s = std.mem.span(l);
    for (known_licenses) |k| if (std.mem.eql(u8, s, k)) return true;
    return false;
}

fn intern(s: [*c]const u8) [*c]const u8 {
    return c.g_intern_string(s);
}

fn copyDesc(dst: *Desc, src: *const Desc) void {
    dst.major_version = src.major_version;
    dst.minor_version = src.minor_version;
    dst.name = intern(src.name);
    dst.description = intern(src.description);
    dst.plugin_init = src.plugin_init;
    dst.version = intern(src.version);
    dst.license = intern(src.license);
    dst.source = intern(src.source);
    dst.package = intern(src.package);
    dst.origin = intern(src.origin);
    dst.release_datetime = intern(src.release_datetime);
}

fn registerFunc(p: [*c]Plugin, desc: *const Desc, data: c.gpointer) [*c]Plugin {
    if (desc.major_version != 1 or desc.minor_version > 28) return null;
    if (desc.license == null or desc.description == null or desc.source == null or desc.package == null or desc.origin == null) return null;
    _ = knownLicense(desc.license);
    copyDesc(@ptrCast(&p[0].desc), desc);
    if (p[0].module) |m| c.g_module_make_resident(m);
    const ok = if (data != null)
        @as(c.GstPluginInitFullFunc, @ptrCast(desc.plugin_init)).?(@ptrCast(p), data)
    else
        desc.plugin_init.?(@ptrCast(p));
    if (ok == 0) return null;
    return p;
}

fn faultHandler(sig: c_int) callconv(.c) void {
    faultRestore();
    if (sig == c.SIGSEGV) {
        c.g_print("\nERROR: ");
        c.g_print("Caught a segmentation fault while loading plugin file:\n");
        c.g_print("%s\n\n", fault_file);
        c.g_print("Please either:\n");
        c.g_print("- remove it and restart.\n");
        c.g_print("- run with --gst-disable-segtrap --gst-disable-registry-fork and debug.\n");
        std.c.exit(-1);
    }
    c.g_print("Caught unhandled signal on plugin loading\n");
}

fn faultSetup() void {
    if (core.gst_segtrap_is_enabled() == 0 or fault_set) return;
    fault_set = true;
    var action = std.mem.zeroes(c.struct_sigaction);
    action.__sigaction_handler.sa_handler = faultHandler;
    _ = c.sigaction(c.SIGSEGV, &action, &old_action);
}

fn faultRestore() void {
    if (!fault_set) return;
    fault_set = false;
    _ = c.sigaction(c.SIGSEGV, &old_action, null);
}

fn number(s: *[*c]const u8) u64 {
    var end: [*c]u8 = null;
    const v = c.g_ascii_strtoull(s.*, &end, 10);
    s.* = end;
    return v;
}

fn validRelease(dt: [*c]const u8) bool {
    var s = dt;
    if (!std.ascii.isDigit(s[0])) return false;
    var v = number(&s);
    if (v < 2000 or v > 2100 or s[0] != '-') return false;
    s += 1;
    v = number(&s);
    if (v == 0 or v > 12 or s[0] != '-') return false;
    s += 1;
    v = number(&s);
    if (v == 0 or v > 32) return false;
    if (s[0] == 'T' or s[0] == ' ') {
        s += 1;
        v = number(&s);
        if (v > 24 or s[0] != ':') return false;
        s += 1;
        v = number(&s);
        if (v > 59 or s[0] != 'Z') return false;
        s += 1;
    }
    return s[0] == 0;
}

pub fn symbolName(filename: [*c]const u8) [*c]u8 {
    const b = c.g_path_get_basename(filename);
    defer c.g_free(b);
    var s: []u8 = std.mem.span(b);
    for (s) |*ch| if (ch.* == '-') {
        ch.* = '_';
    };
    if (std.mem.startsWith(u8, s, "libgst")) s = s[6..] else if (std.mem.startsWith(u8, s, "lib")) s = s[3..] else if (std.mem.startsWith(u8, s, "gst")) s = s[3..];
    if (std.mem.indexOfScalar(u8, s, '.')) |dot| s = s[0..dot];
    return c.g_strdup_printf("gst_plugin_%.*s_get_desc", @as(c_int, @intCast(s.len)), s.ptr);
}

fn pluginError(err: [*c][*c]c.GError, comptime fmt: [*c]const u8, args: anytype) void {
    @call(.auto, c.g_set_error, .{ err, gst_plugin_error_quark(), c.GST_PLUGIN_ERROR_MODULE, fmt } ++ args);
}

fn descField(err: [*c][*c]c.GError, filename: [*c]const u8, value: [*c]const u8, comptime field: [:0]const u8) bool {
    if (value != null and value[0] != 0) return true;
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Plugin description for '%s' has no valid %s field", filename, field.ptr);
    pluginError(err, "Plugin %s has invalid plugin description field '%s'", .{ filename, field.ptr });
    return false;
}

pub export fn gst_plugin_load_file(filename: [*c]const u8, err: [*c][*c]c.GError) [*c]Plugin {
    return loadForRegistry(filename, null, err);
}

pub fn loadForRegistry(filename: [*c]const u8, reg_in: [*c]registry.Registry, err: [*c][*c]c.GError) [*c]Plugin {
    if (!check.that(filename != null, "_priv_gst_plugin_load_file_for_registry", "filename != NULL")) return null;
    const reg = if (reg_in != null) reg_in else registry.gst_registry_get();
    c.g_rec_mutex_lock(&loading);
    defer c.g_rec_mutex_unlock(&loading);
    var p = registry.gst_registry_lookup(reg, filename);
    var fresh = true;
    if (p != null) {
        if (p[0].module != null) return p;
        if (c.g_strcmp0(p[0].filename, filename) == 0) fresh = false;
    }
    const fail = struct {
        fn f(pl: [*c]Plugin) [*c]Plugin {
            if (pl != null) c.gst_object_unref(pl);
            return null;
        }
    }.f;
    var st: c.struct_stat = undefined;
    if (c.stat(filename, &st) != 0) {
        pluginError(err, "Problem accessing file %s: %s", .{ filename, c.g_strerror(std.c._errno().*) });
        return fail(p);
    }
    var flags: c.GModuleFlags = c.G_MODULE_BIND_LOCAL;
    if (c.strstr(filename, "libgstpython") != null) flags |= c.G_MODULE_BIND_LAZY;
    const module = c.g_module_open(filename, flags);
    if (module == null) {
        const msg = c.g_module_error();
        pluginError(err, "Opening module failed: %s", .{msg});
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Failed to load plugin '%s': %s", filename, msg);
        return fail(p);
    }
    const sym = symbolName(filename);
    var ptr: c.gpointer = null;
    var found = c.g_module_symbol(module, sym, &ptr) != 0;
    c.g_free(sym);
    if (found) {
        const get: *const fn () callconv(.c) *const Desc = @ptrCast(ptr);
        ptr = @constCast(get());
    } else found = c.g_module_symbol(module, "gst_plugin_desc", &ptr) != 0;
    if (!found) {
        pluginError(err, "File \"%s\" is not a GStreamer plugin", .{filename});
        _ = c.g_module_close(module);
        return fail(p);
    }
    const desc: *const Desc = @ptrCast(@alignCast(ptr));
    if (haveWhitelist() and !whitelisted(desc, filename)) {
        pluginError(err, "Not loading plugin file \"%s\", not in whitelist", .{filename});
        _ = c.g_module_close(module);
        return fail(p);
    }
    if (fresh) {
        if (p != null) c.gst_object_unref(p);
        p = of(c.g_object_new(gst_plugin_get_type(), @as([*c]const u8, null)));
        p[0].file_mtime = st.st_mtim.tv_sec;
        p[0].file_size = st.st_size;
        p[0].filename = c.g_strdup(filename);
        p[0].basename = c.g_path_get_basename(filename);
    }
    p[0].module = module;
    if (fresh) {
        if (!descField(err, filename, desc.name, "name")) return fail(p);
        if (!descField(err, filename, desc.description, "description")) return fail(p);
        if (!descField(err, filename, desc.version, "version")) return fail(p);
        if (!descField(err, filename, desc.license, "license")) return fail(p);
        if (!descField(err, filename, desc.source, "source")) return fail(p);
        if (!descField(err, filename, desc.package, "package")) return fail(p);
        if (!descField(err, filename, desc.origin, "origin")) return fail(p);
        if (desc.name[0] == '"') c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Invalid plugin name '%s' - fix your GST_PLUGIN_DEFINE (remove quotes around plugin name)", desc.name);
        if (desc.release_datetime != null and !validRelease(desc.release_datetime)) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "GstPluginDesc for '%s' has invalid datetime '%s'", filename, desc.release_datetime);
            pluginError(err, "Plugin %s has invalid plugin description field 'release_datetime'", .{filename});
            return fail(p);
        }
    }
    faultSetup();
    fault_file = p[0].filename;
    if (registerFunc(p, desc, null) == null) {
        faultRestore();
        pluginError(err, "File \"%s\" appears to be a GStreamer plugin, but it failed to initialize", .{filename});
        return fail(p);
    }
    faultRestore();
    fault_file = null;
    if (fresh) {
        _ = c.gst_object_ref(p);
        _ = registry.gst_registry_add_plugin(reg, p);
    }
    return p;
}

pub export fn gst_plugin_get_name(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_name", "plugin != NULL")) return null;
    return p[0].desc.name;
}

pub export fn gst_plugin_get_description(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_description", "plugin != NULL")) return null;
    return p[0].desc.description;
}

pub export fn gst_plugin_get_filename(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_filename", "plugin != NULL")) return null;
    return p[0].filename;
}

pub export fn gst_plugin_get_version(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_version", "plugin != NULL")) return null;
    return p[0].desc.version;
}

pub export fn gst_plugin_get_license(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_license", "plugin != NULL")) return null;
    return p[0].desc.license;
}

pub export fn gst_plugin_get_source(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_source", "plugin != NULL")) return null;
    return p[0].desc.source;
}

pub export fn gst_plugin_get_package(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_package", "plugin != NULL")) return null;
    return p[0].desc.package;
}

pub export fn gst_plugin_get_origin(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_origin", "plugin != NULL")) return null;
    return p[0].desc.origin;
}

pub export fn gst_plugin_get_release_date_string(p: [*c]Plugin) [*c]const u8 {
    if (!check.that(p != null, "gst_plugin_get_release_date_string", "plugin != NULL")) return null;
    return p[0].desc.release_datetime;
}

pub export fn gst_plugin_is_loaded(p: [*c]Plugin) c.gboolean {
    if (!check.that(p != null, "gst_plugin_is_loaded", "plugin != NULL")) return 0;
    if (p[0].filename == null) return 1;
    c.g_rec_mutex_lock(&loading);
    defer c.g_rec_mutex_unlock(&loading);
    return @intFromBool(p[0].module != null);
}

pub export fn gst_plugin_get_cache_data(p: [*c]Plugin) [*c]const c.GstStructure {
    if (!check.that(isPlugin(p), "gst_plugin_get_cache_data", "GST_IS_PLUGIN (plugin)")) return null;
    return p[0].priv.cache_data;
}

pub export fn gst_plugin_set_cache_data(p: [*c]Plugin, data: [*c]c.GstStructure) void {
    if (!check.that(isPlugin(p), "gst_plugin_set_cache_data", "GST_IS_PLUGIN (plugin)")) return;
    if (!check.that(data != null and data[0].type == @import("structure.zig")._gst_structure_type, "gst_plugin_set_cache_data", "GST_IS_STRUCTURE (cache_data)")) return;
    if (p[0].priv.cache_data != null) c.gst_structure_free(p[0].priv.cache_data);
    p[0].priv.cache_data = data;
}

pub export fn gst_plugin_load_by_name(name: [*c]const u8) [*c]Plugin {
    const p = registry.gst_registry_find_plugin(registry.gst_registry_get(), name);
    if (p == null) return null;
    if (gst_plugin_is_loaded(p) != 0) return p;
    var err: [*c]c.GError = null;
    const loaded = gst_plugin_load_file(p[0].filename, &err);
    c.gst_object_unref(p);
    if (loaded == null) {
        c.g_error_free(err);
        return null;
    }
    return loaded;
}

pub export fn gst_plugin_load(p: [*c]Plugin) [*c]Plugin {
    if (gst_plugin_is_loaded(p) != 0) return of(c.gst_object_ref(p));
    var err: [*c]c.GError = null;
    const loaded = gst_plugin_load_file(p[0].filename, &err);
    if (loaded == null) {
        c.g_error_free(err);
        return null;
    }
    return loaded;
}

pub export fn gst_plugin_list_free(list: ?*c.GList) void {
    var g = list;
    while (g) |n| : (g = n.next) c.gst_object_unref(n.data);
    c.g_list_free(list);
}

fn envHash(dep: *Dep) c.guint {
    var hash: c.guint = 0;
    var e = dep.env_vars;
    if (e == null) return 0;
    while (e[0] != null) : (e += 1) {
        hash = hash << 5;
        if (!std.ascii.isAlphanumeric(e[0][0])) continue;
        var buf: [256]u8 = undefined;
        _ = c.g_strlcpy(&buf, e[0], buf.len);
        _ = c.g_strdelimit(&buf, "/\\", 0);
        if (c.g_getenv(&buf)) |v| hash +%= c.g_str_hash(v);
    }
    return hash;
}

pub fn envChanged(p: [*c]Plugin) bool {
    var l = p[0].priv.deps;
    while (l) |n| : (l = n.next) {
        const dep: *Dep = @ptrCast(@alignCast(n.data));
        if (dep.env_hash != envHash(dep)) return true;
    }
    return false;
}

fn queueHas(q: *c.GQueue, s: [*c]const u8) bool {
    return c.g_queue_find_custom(q, s, @ptrCast(&c.strcmp)) != null;
}

fn envPaths(dep: *Dep, q: *c.GQueue) void {
    var e = dep.env_vars;
    if (e == null) return;
    while (e[0] != null) : (e += 1) {
        if (!std.ascii.isAlphanumeric(e[0][0])) continue;
        const parts = c.g_strsplit_set(e[0], "/\\", 2);
        defer c.g_strfreev(parts);
        const val = c.g_getenv(parts[0]);
        if (parts[1] != null) _ = c.g_strdelimit(parts[1], "/\\", '/');
        if (val == null or val[0] == 0) continue;
        const arr = c.g_strsplit(val, ":", -1);
        defer c.g_strfreev(arr);
        var i: usize = 0;
        while (arr[i] != null) : (i += 1) {
            if (c.g_path_is_absolute(arr[i]) == 0) continue;
            const full = if (parts[1] != null) c.g_build_filename(arr[i], parts[1], @as([*c]const u8, null)) else c.g_strdup(arr[i]);
            if (!queueHas(q, full)) c.g_queue_push_tail(q, full) else c.g_free(full);
        }
    }
}

fn statHash(st: *const c.struct_stat) c.guint {
    if (st.st_mode & (c.S_IFDIR | c.S_IFREG | c.S_IFBLK | c.S_IFCHR) == 0) return std.math.maxInt(c.guint);
    const size: c.guint = @truncate(@as(u64, @bitCast(@as(i64, st.st_size))));
    const mtime: c.guint = @truncate(@as(u64, @bitCast(@as(i64, st.st_mtim.tv_sec))));
    const ctime: c.guint = @truncate(@as(u64, @bitCast(@as(i64, st.st_ctim.tv_sec))));
    return ((size << 3) +% (mtime << 5)) ^ ctime;
}

fn nameMatches(entry: [*c]const u8, names: [*c]const [*c]const u8, flags: c.GstPluginDependencyFlags) bool {
    if (names == null or names[0] == null or names[0][0] == 0) return true;
    var n = names;
    while (n[0] != null) : (n += 1) {
        if (flags & c.GST_PLUGIN_DEPENDENCY_FLAG_FILE_NAME_IS_SUFFIX != 0 and c.g_str_has_suffix(entry, n[0]) != 0) return true;
        if (flags & c.GST_PLUGIN_DEPENDENCY_FLAG_FILE_NAME_IS_PREFIX != 0 and c.g_str_has_prefix(entry, n[0]) != 0) return true;
        if (c.strcmp(entry, n[0]) == 0) return true;
    }
    return false;
}

fn scanDir(path: [*c]const u8, names: [*c]const [*c]const u8, flags: c.GstPluginDependencyFlags) c.guint {
    const recurse = flags & c.GST_PLUGIN_DEPENDENCY_FLAG_RECURSE != 0;
    var err: [*c]c.GError = null;
    const dir = c.g_dir_open(path, 0, &err);
    if (dir == null) {
        c.g_error_free(err);
        return std.math.maxInt(c.guint);
    }
    defer c.g_dir_close(dir);
    var hash: c.guint = 0;
    while (c.g_dir_read_name(dir)) |entry| {
        const match = nameMatches(entry, names, flags);
        if (!match and !recurse) continue;
        const full = c.g_build_filename(path, entry, @as([*c]const u8, null));
        defer c.g_free(full);
        var st: c.struct_stat = undefined;
        const fh: c.guint = if (c.stat(full, &st) < 0)
            std.math.maxInt(c.guint)
        else if (match)
            statHash(&st)
        else if (st.st_mode & c.S_IFDIR != 0)
            scanDir(full, names, flags)
        else
            continue;
        hash +%= fh;
    }
    return hash;
}

fn scanPath(path: [*c]const u8, names_in: [*c]const [*c]const u8, flags: c.GstPluginDependencyFlags) c.guint {
    const empty = [_][*c]const u8{ "", null };
    const names: [*c]const [*c]const u8 = if (names_in == null or names_in[0] == null) &empty else names_in;
    const partial = flags & (c.GST_PLUGIN_DEPENDENCY_FLAG_FILE_NAME_IS_SUFFIX | c.GST_PLUGIN_DEPENDENCY_FLAG_FILE_NAME_IS_PREFIX) != 0;
    if (flags & c.GST_PLUGIN_DEPENDENCY_FLAG_RECURSE != 0 or partial) return scanDir(path, names, flags);
    var hash: c.guint = 0;
    var i: usize = 0;
    while (names[i] != null) : (i += 1) {
        const full = c.g_build_filename(path, names[i], @as([*c]const u8, null));
        defer c.g_free(full);
        var st: c.struct_stat = undefined;
        hash +%= if (c.stat(full, &st) < 0) std.math.maxInt(c.guint) else statHash(&st);
    }
    return hash;
}

fn depStatHash(dep: *Dep) c.guint {
    var q = std.mem.zeroes(c.GQueue);
    envPaths(dep, &q);
    if (q.length == 0 or dep.flags & c.GST_PLUGIN_DEPENDENCY_FLAG_PATHS_ARE_DEFAULT_ONLY == 0) {
        var pp = dep.paths;
        if (pp != null) while (pp[0] != null) : (pp += 1) {
            var full: [*c]u8 = undefined;
            if (dep.flags & c.GST_PLUGIN_DEPENDENCY_FLAG_PATHS_ARE_RELATIVE_TO_EXE != 0 and c.g_path_is_absolute(pp[0]) == 0) {
                if (core.executablePath() == null) continue;
                const appdir = c.g_path_get_dirname(core.executablePath());
                full = c.g_build_filename(appdir, pp[0], @as([*c]const u8, null));
                c.g_free(appdir);
            } else full = c.g_strdup(pp[0]);
            if (!queueHas(&q, full)) c.g_queue_push_tail(&q, full) else c.g_free(full);
        };
    }
    var hash: c.guint = 0;
    while (c.g_queue_pop_head(&q)) |path| {
        hash +%= scanPath(@ptrCast(path), @ptrCast(dep.names), dep.flags);
        c.g_free(path);
    }
    return hash;
}

pub fn filesChanged(p: [*c]Plugin) bool {
    var l = p[0].priv.deps;
    while (l) |n| : (l = n.next) {
        const dep: *Dep = @ptrCast(@alignCast(n.data));
        if (dep.stat_hash != depStatHash(dep)) return true;
    }
    return false;
}

pub fn freeDep(dep: *Dep) void {
    c.g_strfreev(dep.env_vars);
    c.g_strfreev(dep.paths);
    c.g_strfreev(dep.names);
    c.g_free(dep);
}

fn strvEqual(a: [*c]const [*c]const u8, b: [*c]const [*c]const u8) bool {
    if (a == b) return true;
    if (a == null or b == null) return false;
    var i: usize = 0;
    while (a[i] != null and b[i] != null) : (i += 1) if (c.strcmp(a[i], b[i]) != 0) return false;
    return a[i] == b[i];
}

pub fn appendDep(p: [*c]Plugin, dep: *Dep) void {
    p[0].priv.deps = c.g_list_append(p[0].priv.deps, dep);
}

pub export fn gst_plugin_add_dependency(p: [*c]Plugin, env_vars: [*c][*c]const u8, paths: [*c][*c]const u8, names: [*c][*c]const u8, flags: c.GstPluginDependencyFlags) void {
    if (!check.that(isPlugin(p), "gst_plugin_add_dependency", "GST_IS_PLUGIN (plugin)")) return;
    if ((env_vars == null or env_vars[0] == null) and (paths == null or paths[0] == null)) return;
    var l = p[0].priv.deps;
    while (l) |n| : (l = n.next) {
        const d: *Dep = @ptrCast(@alignCast(n.data));
        if (d.flags == flags and strvEqual(@ptrCast(d.env_vars), env_vars) and strvEqual(@ptrCast(d.paths), paths) and strvEqual(@ptrCast(d.names), names)) return;
    }
    const dep: *Dep = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Dep))));
    dep.env_vars = c.g_strdupv(@ptrCast(@constCast(env_vars)));
    dep.paths = c.g_strdupv(@ptrCast(@constCast(paths)));
    dep.names = c.g_strdupv(@ptrCast(@constCast(names)));
    dep.flags = flags;
    dep.env_hash = envHash(dep);
    dep.stat_hash = depStatHash(dep);
    appendDep(p, dep);
}

pub export fn gst_plugin_add_dependency_simple(p: [*c]Plugin, env_vars: [*c]const u8, paths: [*c]const u8, names: [*c]const u8, flags: c.GstPluginDependencyFlags) void {
    const e = if (env_vars != null) c.g_strsplit_set(env_vars, ":;,", -1) else null;
    const pa = if (paths != null) c.g_strsplit_set(paths, ":;,", -1) else null;
    const n = if (names != null) c.g_strsplit_set(names, ",", -1) else null;
    gst_plugin_add_dependency(p, @ptrCast(e), @ptrCast(pa), @ptrCast(n), flags);
    c.g_strfreev(e);
    c.g_strfreev(pa);
    c.g_strfreev(n);
}

fn addStatus(p: [*c]Plugin, comptime f: []const u8, field: [*c]const u8, msg: [*c]const u8) void {
    if (!check.that(isPlugin(p), f, "GST_IS_PLUGIN (plugin)")) return;
    if (!check.that(msg != null, f, "message != NULL")) return;
    var sv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&sv, c.G_TYPE_STRING);
    c.g_value_set_string(&sv, msg);
    var existing: [*c]const c.GValue = null;
    if (p[0].priv.status_info == null)
        p[0].priv.status_info = c.gst_structure_new_empty("plugin-status-info")
    else
        existing = c.gst_structure_get_value(p[0].priv.status_info, field);
    if (existing != null) {
        c.gst_value_list_append_and_take_value(@constCast(existing), &sv);
    } else {
        var lv = std.mem.zeroes(c.GValue);
        _ = c.gst_value_list_init(&lv, 1);
        c.gst_value_list_append_and_take_value(&lv, &sv);
        c.gst_structure_take_value(p[0].priv.status_info, field, &lv);
    }
}

pub export fn gst_plugin_add_status_error(p: [*c]Plugin, msg: [*c]const u8) void {
    addStatus(p, "gst_plugin_add_status_message", "error-message", msg);
}

pub export fn gst_plugin_add_status_warning(p: [*c]Plugin, msg: [*c]const u8) void {
    addStatus(p, "gst_plugin_add_status_message", "warning-message", msg);
}

pub export fn gst_plugin_add_status_info(p: [*c]Plugin, msg: [*c]const u8) void {
    addStatus(p, "gst_plugin_add_status_message", "info-message", msg);
}

fn statusList(p: [*c]Plugin, field: [*c]const u8) [*c][*c]u8 {
    if (!check.that(isPlugin(p), "gst_plugin_get_status_messages", "GST_IS_PLUGIN (plugin)")) return null;
    if (p[0].priv.status_info == null) return null;
    const lv = c.gst_structure_get_value(p[0].priv.status_info, field);
    if (lv == null) return null;
    const n = c.gst_value_list_get_size(lv);
    if (n == 0) return null;
    const arr: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc0((n + 1) * @sizeOf([*c]u8))));
    var i: c.guint = 0;
    while (i < n) : (i += 1) arr[i] = c.g_value_dup_string(c.gst_value_list_get_value(lv, i));
    return arr;
}

pub export fn gst_plugin_get_status_errors(p: [*c]Plugin) [*c][*c]u8 {
    return statusList(p, "error-message");
}

pub export fn gst_plugin_get_status_warnings(p: [*c]Plugin) [*c][*c]u8 {
    return statusList(p, "warning-message");
}

pub export fn gst_plugin_get_status_infos(p: [*c]Plugin) [*c][*c]u8 {
    return statusList(p, "info-message");
}

pub export fn gst_type_mark_as_plugin_api(t: c.GType, flags: c.GstPluginAPIFlags) void {
    c.g_type_set_qdata(t, api_quark, @ptrFromInt(1));
    c.g_type_set_qdata(t, api_flags_quark, @ptrFromInt(@as(usize, flags)));
}

pub export fn gst_type_is_plugin_api(t: c.GType, flags: [*c]c.GstPluginAPIFlags) c.gboolean {
    const ret = c.g_type_get_qdata(t, api_quark) != null;
    if (ret and flags != null) flags.* = @intCast(@intFromPtr(c.g_type_get_qdata(t, api_flags_quark)));
    return @intFromBool(ret);
}
