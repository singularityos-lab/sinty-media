const std = @import("std");
const c = @import("c.zig").c;
const feature = @import("pluginfeature.zig");
const plugin = @import("plugin.zig");
const factory = @import("elementfactory.zig");
const registry = @import("registry.zig");

const Plugin = plugin.Plugin;
const Feature = feature.Feature;

pub const MAGIC = "SINTYREG";
pub const FORMAT: u32 = 1;

pub const Writer = struct {
    buf: *c.GByteArray,

    pub fn init() Writer {
        return .{ .buf = c.g_byte_array_new() };
    }

    pub fn deinit(w: *Writer) void {
        _ = c.g_byte_array_free(w.buf, 1);
    }

    pub fn bytes(w: *Writer) []const u8 {
        return w.buf.data[0..w.buf.len];
    }

    pub fn raw(w: *Writer, b: []const u8) void {
        _ = c.g_byte_array_append(w.buf, b.ptr, @intCast(b.len));
    }

    pub fn int(w: *Writer, comptime T: type, v: T) void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        w.raw(&b);
    }

    pub fn str(w: *Writer, s: [*c]const u8) void {
        if (s == null) return w.int(u32, std.math.maxInt(u32));
        const span = std.mem.span(s);
        w.int(u32, @intCast(span.len));
        w.raw(span);
    }

    pub fn strv(w: *Writer, v: [*c]const [*c]const u8) void {
        if (v == null) return w.int(u32, std.math.maxInt(u32));
        var n: u32 = 0;
        while (v[n] != null) n += 1;
        w.int(u32, n);
        var i: u32 = 0;
        while (i < n) : (i += 1) w.str(v[i]);
    }

    pub fn structure(w: *Writer, s: [*c]const c.GstStructure) void {
        if (s == null) return w.str(null);
        const t = c.gst_structure_to_string(s);
        defer c.g_free(t);
        w.str(t);
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn take(r: *Reader, n: usize) error{Truncated}![]const u8 {
        if (r.data.len - r.pos < n) return error.Truncated;
        defer r.pos += n;
        return r.data[r.pos .. r.pos + n];
    }

    pub fn int(r: *Reader, comptime T: type) error{Truncated}!T {
        const b = try r.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }

    pub fn dup(r: *Reader) error{Truncated}![*c]u8 {
        const n = try r.int(u32);
        if (n == std.math.maxInt(u32)) return null;
        const b = try r.take(n);
        return c.g_strndup(b.ptr, b.len);
    }

    pub fn intern(r: *Reader) error{Truncated}![*c]const u8 {
        const n = try r.int(u32);
        if (n == std.math.maxInt(u32)) return null;
        const b = try r.take(n);
        const tmp = c.g_strndup(b.ptr, b.len);
        defer c.g_free(tmp);
        return c.g_intern_string(tmp);
    }

    pub fn strv(r: *Reader) error{Truncated}![*c][*c]u8 {
        const n = try r.int(u32);
        if (n == std.math.maxInt(u32)) return null;
        if (n > r.data.len - r.pos) return error.Truncated;
        const arr: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc0((n + 1) * @sizeOf([*c]u8))));
        errdefer c.g_strfreev(arr);
        var i: u32 = 0;
        while (i < n) : (i += 1) arr[i] = try r.dup();
        return arr;
    }

    pub fn structure(r: *Reader) error{ Truncated, Corrupt }![*c]c.GstStructure {
        const s = try r.dup();
        if (s == null) return null;
        defer c.g_free(s);
        const st = c.gst_structure_from_string(s, null);
        if (st == null) return error.Corrupt;
        return st;
    }
};

pub const Error = error{ Truncated, Corrupt };

pub const Kind = struct {
    name: [:0]const u8,
    get_type: *const fn () callconv(.c) c.GType,
    save: *const fn (*Writer, [*c]Feature) void,
    load: *const fn (*Reader) Error![*c]Feature,
};

fn saveElement(w: *Writer, f: [*c]Feature) void {
    const ef = factory.of(f);
    w.structure(@ptrCast(@alignCast(ef[0].metadata)));
    w.int(u32, @bitCast(ef[0].uri_type));
    w.strv(@ptrCast(ef[0].uri_protocols));
    var n: u32 = 0;
    var l = ef[0].interfaces;
    while (l) |x| : (l = x.next) n += 1;
    w.int(u32, n);
    l = ef[0].interfaces;
    while (l) |x| : (l = x.next) w.str(@ptrCast(x.data));
    n = 0;
    l = ef[0].staticpadtemplates;
    while (l) |x| : (l = x.next) n += 1;
    w.int(u32, n);
    l = ef[0].staticpadtemplates;
    while (l) |x| : (l = x.next) {
        const t: [*c]c.GstStaticPadTemplate = @ptrCast(@alignCast(x.data));
        w.str(t[0].name_template);
        w.int(u32, @bitCast(t[0].direction));
        w.int(u32, @bitCast(t[0].presence));
        w.str(t[0].static_caps.string);
    }
}

fn reverse(v: [*c][*c]u8) void {
    if (v == null) return;
    var n: usize = 0;
    while (v[n] != null) n += 1;
    std.mem.reverse([*c]u8, v[0..n]);
}

fn loadElement(r: *Reader) Error![*c]Feature {
    const ef = factory.of(c.g_object_new(factory.gst_element_factory_get_type(), @as([*c]const u8, null)));
    errdefer c.gst_object_unref(ef);
    ef[0].metadata = try r.structure();
    ef[0].uri_type = @bitCast(try r.int(u32));
    ef[0].uri_protocols = try r.strv();
    reverse(ef[0].uri_protocols);
    var n = try r.int(u32);
    while (n > 0) : (n -= 1) {
        const s = try r.intern();
        if (s == null) return error.Corrupt;
        factory.addInterface(ef, s);
    }
    n = try r.int(u32);
    while (n > 0) : (n -= 1) {
        const t: *c.GstStaticPadTemplate = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstStaticPadTemplate))));
        t.name_template = try r.intern();
        t.direction = @bitCast(try r.int(u32));
        t.presence = @bitCast(try r.int(u32));
        t.static_caps.string = try r.intern();
        ef[0].staticpadtemplates = c.g_list_prepend(ef[0].staticpadtemplates, t);
        ef[0].numpadtemplates += 1;
    }
    return @ptrCast(ef);
}

pub const kinds = [_]Kind{
    .{ .name = "GstElementFactory", .get_type = factory.gst_element_factory_get_type, .save = saveElement, .load = loadElement },
    @import("typefind.zig").kind,
    @import("dynamictype.zig").kind,
    @import("device.zig").kind,
};

fn kindFor(f: [*c]Feature) ?*const Kind {
    const t = @as(*c.GTypeInstance, @ptrCast(@alignCast(f))).g_class.*.g_type;
    for (&kinds) |*k| if (k.get_type() == t) return k;
    return null;
}

fn kindNamed(name: []const u8) ?*const Kind {
    for (&kinds) |*k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}

pub fn savePlugin(w: *Writer, reg: [*c]registry.Registry, p: [*c]Plugin) void {
    const d = &p[0].desc;
    w.str(d.name);
    w.str(d.description);
    w.str(d.version);
    w.str(d.license);
    w.str(d.source);
    w.str(d.package);
    w.str(d.origin);
    w.str(d.release_datetime);
    w.str(p[0].filename);
    w.int(i64, p[0].file_size);
    w.int(i64, p[0].file_mtime);
    w.int(u32, p[0].object.flags & c.GST_PLUGIN_FLAG_BLACKLISTED);
    var n: u32 = 0;
    var l = p[0].priv.deps;
    while (l) |x| : (l = x.next) n += 1;
    w.int(u32, n);
    l = p[0].priv.deps;
    while (l) |x| : (l = x.next) {
        const dep: *plugin.Dep = @ptrCast(@alignCast(x.data));
        w.int(u32, @bitCast(dep.flags));
        w.strv(@ptrCast(dep.env_vars));
        w.strv(@ptrCast(dep.paths));
        w.strv(@ptrCast(dep.names));
        w.int(u32, dep.env_hash);
        w.int(u32, dep.stat_hash);
    }
    w.structure(p[0].priv.cache_data);
    w.structure(p[0].priv.status_info);
    const feats = registry.featuresOf(reg, p);
    defer feature.gst_plugin_feature_list_free(feats);
    n = 0;
    l = feats;
    while (l) |x| : (l = x.next) {
        if (kindFor(feature.of(x.data)) != null) n += 1;
    }
    w.int(u32, n);
    l = c.g_list_last(feats);
    while (l) |x| : (l = x.prev) {
        const f = feature.of(x.data);
        const k = kindFor(f) orelse continue;
        w.str(k.name);
        w.str(feature.nameOf(f));
        w.int(u32, f[0].rank);
        k.save(w, f);
    }
}

pub fn loadPlugin(r: *Reader, reg: [*c]registry.Registry) Error![*c]Plugin {
    const p = plugin.of(c.g_object_new(plugin.gst_plugin_get_type(), @as([*c]const u8, null)));
    var added = false;
    errdefer if (!added) c.gst_object_unref(p);
    const d = &p[0].desc;
    d.major_version = 1;
    d.minor_version = 28;
    d.name = try r.intern();
    d.description = try r.intern();
    d.version = try r.intern();
    d.license = try r.intern();
    d.source = try r.intern();
    d.package = try r.intern();
    d.origin = try r.intern();
    d.release_datetime = try r.intern();
    if (d.name == null) return error.Corrupt;
    p[0].filename = try r.dup();
    if (p[0].filename != null) p[0].basename = c.g_path_get_basename(p[0].filename);
    p[0].file_size = try r.int(i64);
    p[0].file_mtime = try r.int(i64);
    p[0].object.flags |= (try r.int(u32)) | c.GST_PLUGIN_FLAG_CACHED;
    var n = try r.int(u32);
    while (n > 0) : (n -= 1) {
        const dep: *plugin.Dep = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(plugin.Dep))));
        plugin.appendDep(p, dep);
        dep.flags = @bitCast(try r.int(u32));
        dep.env_vars = try r.strv();
        dep.paths = try r.strv();
        dep.names = try r.strv();
        dep.env_hash = try r.int(u32);
        dep.stat_hash = try r.int(u32);
    }
    p[0].priv.cache_data = try r.structure();
    p[0].priv.status_info = try r.structure();
    _ = registry.gst_registry_add_plugin(reg, p);
    added = true;
    n = try r.int(u32);
    while (n > 0) : (n -= 1) {
        const kname = try r.dup();
        defer c.g_free(kname);
        if (kname == null) return error.Corrupt;
        const k = kindNamed(std.mem.span(kname)) orelse return error.Corrupt;
        const name = try r.dup();
        defer c.g_free(name);
        if (name == null) return error.Corrupt;
        const rank = try r.int(u32);
        const f = try k.load(r);
        _ = c.gst_object_set_name(@ptrCast(f), name);
        f[0].rank = rank;
        feature.bindPlugin(f, p);
        _ = registry.gst_registry_add_feature(reg, f);
    }
    return p;
}

pub fn header(w: *Writer) void {
    w.raw(MAGIC);
    w.int(u32, FORMAT);
    w.str("1.28.2");
}

pub fn checkHeader(r: *Reader) bool {
    const m = r.take(MAGIC.len) catch return false;
    if (!std.mem.eql(u8, m, MAGIC)) return false;
    if ((r.int(u32) catch return false) != FORMAT) return false;
    const v = r.dup() catch return false;
    defer c.g_free(v);
    return v != null and std.mem.orderZ(u8, v, "1.28.2") == .eq;
}

pub fn write(reg: [*c]registry.Registry, path: [*c]const u8) bool {
    var w = Writer.init();
    defer w.deinit();
    header(&w);
    const plugins = registry.gst_registry_get_plugin_list(reg);
    defer plugin.gst_plugin_list_free(plugins);
    var n: u32 = 0;
    var l = plugins;
    while (l) |x| : (l = x.next) {
        if (plugin.of(x.data)[0].filename != null) n += 1;
    }
    w.int(u32, n);
    l = plugins;
    while (l) |x| : (l = x.next) {
        const p = plugin.of(x.data);
        if (p[0].filename != null) savePlugin(&w, reg, p);
    }
    const dir = c.g_path_get_dirname(path);
    defer c.g_free(dir);
    _ = c.g_mkdir_with_parents(dir, 0o777);
    const tmp = c.g_strconcat(path, ".tmpXXXXXX", @as([*c]const u8, null));
    defer c.g_free(tmp);
    const fd = c.g_mkstemp(tmp);
    if (fd < 0) return false;
    const data = w.bytes();
    var off: usize = 0;
    while (off < data.len) {
        const k = c.write(fd, data.ptr + off, data.len - off);
        if (k <= 0) {
            _ = c.close(fd);
            _ = c.unlink(tmp);
            return false;
        }
        off += @intCast(k);
    }
    if (c.fsync(fd) != 0 or c.close(fd) != 0) {
        _ = c.unlink(tmp);
        return false;
    }
    if (c.rename(tmp, path) != 0) {
        _ = c.unlink(tmp);
        return false;
    }
    return true;
}

pub fn read(reg: [*c]registry.Registry, path: [*c]const u8) bool {
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(path, &contents, &len, null) == 0) return false;
    defer c.g_free(contents);
    var r = Reader{ .data = contents[0..len] };
    if (!checkHeader(&r)) return false;
    var n = r.int(u32) catch return false;
    while (n > 0) : (n -= 1) {
        _ = loadPlugin(&r, reg) catch {
            registry.dropCached(reg);
            return false;
        };
    }
    return true;
}
