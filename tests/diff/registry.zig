const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn name(p: anytype) []const u8 {
    if (p == null) return "(null)";
    return str(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

fn flags(p: anytype) c.guint32 {
    return @as(*c.GstObject, @ptrCast(@alignCast(p))).flags;
}

fn byName(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return c.strcmp(@as(*const c.GstObject, @ptrCast(@alignCast(a))).name, @as(*const c.GstObject, @ptrCast(@alignCast(b))).name);
}

fn byPluginName(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return c.strcmp(c.gst_plugin_get_name(@ptrCast(@constCast(a))), c.gst_plugin_get_name(@ptrCast(@constCast(b))));
}

fn strv(v: [*c]const [*c]const u8) void {
    if (v == null) {
        out("    (none)", .{});
        return;
    }
    var i: usize = 0;
    while (v[i] != null) : (i += 1) out("    {s}", .{str(v[i])});
}

fn ours(p: ?*c.GstPlugin) bool {
    const f = c.gst_plugin_get_filename(p);
    return f == null or c.strstr(f, "testplugins") != null;
}

fn dumpPlugins() void {
    const reg = c.gst_registry_get();
    var list = c.gst_registry_get_plugin_list(reg);
    list = c.g_list_sort(list, byPluginName);
    var l: ?*c.GList = list;
    while (l) |n| : (l = n.next) {
        const p: ?*c.GstPlugin = @ptrCast(@alignCast(n.data));
        if (!ours(p)) continue;
        const fname = c.gst_plugin_get_filename(p);
        const base = if (fname != null) c.g_path_get_basename(fname) else null;
        const static = fname == null;
        out("plugin {s} [{s}] v{s} {s} src={s} pkg={s} origin={s} date={s} file={s}", .{ str(c.gst_plugin_get_name(p)), str(c.gst_plugin_get_description(p)), str(c.gst_plugin_get_version(p)), str(c.gst_plugin_get_license(p)), str(c.gst_plugin_get_source(p)), if (static) "-" else str(c.gst_plugin_get_package(p)), if (static) "-" else str(c.gst_plugin_get_origin(p)), str(c.gst_plugin_get_release_date_string(p)), str(base) });
        c.g_free(base);
        out("  flags blacklisted {d} cached {d} loaded {d}", .{ @intFromBool(flags(p) & c.GST_PLUGIN_FLAG_BLACKLISTED != 0), @intFromBool(flags(p) & c.GST_PLUGIN_FLAG_CACHED != 0), c.gst_plugin_is_loaded(p) });
        const infos = c.gst_plugin_get_status_infos(p);
        out("  infos", .{});
        strv(@ptrCast(infos));
        c.g_strfreev(infos);
        const cd = c.gst_plugin_get_cache_data(p);
        out("  cache data {s}", .{if (cd != null) str(c.gst_structure_get_name(cd)) else "(none)"});
    }
    c.gst_plugin_list_free(list);
}

fn dumpFeatures() void {
    const reg = c.gst_registry_get();
    var list = c.gst_registry_get_feature_list(reg, c.gst_element_factory_get_type());
    list = c.g_list_sort(list, byName);
    var l: ?*c.GList = list;
    while (l) |n| : (l = n.next) {
        const f: ?*c.GstElementFactory = @ptrCast(@alignCast(n.data));
        const pf: ?*c.GstPluginFeature = @ptrCast(f);
        const pn = c.gst_plugin_feature_get_plugin_name(pf);
        if (pn == null or (c.strcmp(pn, "sintytest") != 0 and c.strcmp(pn, "staticelements") != 0)) continue;
        out("feature {s} rank {d} plugin {s} type {s}", .{ name(f), c.gst_plugin_feature_get_rank(pf), str(pn), str(c.g_type_name(c.G_TYPE_FROM_INSTANCE(f))) });
        const keys = c.gst_element_factory_get_metadata_keys(f);
        if (keys != null) {
            var i: usize = 0;
            while (keys[i] != null) : (i += 1) out("  meta {s} = {s}", .{ str(keys[i]), str(c.gst_element_factory_get_metadata(f, keys[i])) });
        }
        c.g_strfreev(keys);
        out("  templates {d}", .{c.gst_element_factory_get_num_pad_templates(f)});
        var t: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
        while (t) |m| : (t = m.next) {
            const st: *c.GstStaticPadTemplate = @ptrCast(@alignCast(m.data));
            out("    {s} dir {d} presence {d} caps {s}", .{ str(st.name_template), st.direction, st.presence, str(st.static_caps.string) });
        }
        out("  uri type {d} handler {d} skipdoc {d}", .{ c.gst_element_factory_get_uri_type(f), c.gst_element_factory_has_interface(f, "GstURIHandler"), c.gst_element_factory_get_skip_documentation(f) });
        strv(c.gst_element_factory_get_uri_protocols(f));
    }
    c.gst_plugin_feature_list_free(list);
}

var suggested: [256]u8 = undefined;
var suggested_len: usize = 0;

fn peek(data: c.gpointer, offset: i64, size: c.guint) callconv(.c) [*c]const u8 {
    const bytes: [*]const u8 = @ptrCast(data);
    if (offset < 0 or offset + size > 8) return null;
    return bytes + @as(usize, @intCast(offset));
}

fn suggest(_: c.gpointer, probability: c.guint, caps: ?*c.GstCaps) callconv(.c) void {
    const s = c.gst_caps_to_string(caps);
    defer c.g_free(s);
    const w = std.fmt.bufPrint(suggested[suggested_len..], "{d}:{s};", .{ probability, std.mem.span(s) }) catch return;
    suggested_len += w.len;
}

fn dumpTypefind() void {
    var list = c.gst_type_find_factory_get_list();
    var l: ?*c.GList = list;
    while (l) |n| : (l = n.next) {
        const f: ?*c.GstTypeFindFactory = @ptrCast(@alignCast(n.data));
        if (c.strstr(name(f).ptr, "sinty") == null) continue;
        const caps = c.gst_type_find_factory_get_caps(f);
        const cs = if (caps != null) c.gst_caps_to_string(caps) else null;
        out("typefind {s} rank {d} caps {s} has fn {d}", .{ name(f), c.gst_plugin_feature_get_rank(@ptrCast(f)), str(cs), c.gst_type_find_factory_has_function(f) });
        c.g_free(cs);
        strv(c.gst_type_find_factory_get_extensions(f));
        var data = "STY1abcd".*;
        var find = c.GstTypeFind{ .peek = peek, .suggest = suggest, .data = &data, .get_length = null, ._gst_reserved = .{null} ** 4 };
        suggested_len = 0;
        c.gst_type_find_factory_call_function(f, &find);
        out("  suggested {s} length {d}", .{ suggested[0..suggested_len], c.gst_type_find_get_length(&find) });
    }
    c.gst_plugin_feature_list_free(list);
    list = null;
    const t = c.gst_dynamic_type_factory_load("SintyDynType");
    out("dynamic {s}", .{str(c.g_type_name(t))});
    out("dynamic missing {d}", .{c.gst_dynamic_type_factory_load("NoSuchType")});
}

fn printErr(label: []const u8, e: [*c]c.GError) void {
    if (e == null) {
        out("{s}: no error", .{label});
        return;
    }
    out("{s}: {s} {d} {s}", .{ label, str(c.g_quark_to_string(e.*.domain)), e.*.code, str(e.*.message) });
    c.g_error_free(e);
}

fn exercise() void {
    const p = c.gst_registry_find_plugin(c.gst_registry_get(), "sintytest");
    out("before make loaded {d}", .{c.gst_plugin_is_loaded(p)});
    const e = c.gst_element_factory_make("sintytestsrc", "s1");
    out("make {s} factory {s} loaded {d}", .{ name(e), name(c.gst_element_get_factory(e)), c.gst_plugin_is_loaded(p) });
    var err: [*c]c.GError = null;
    out("set uri {d}", .{c.gst_uri_handler_set_uri(@ptrCast(e), "SINTY://host/x", &err)});
    printErr("  err", err);
    err = null;
    const u = c.gst_uri_handler_get_uri(@ptrCast(e));
    out("get uri {s} type {d}", .{ str(u), c.gst_uri_handler_get_uri_type(@ptrCast(e)) });
    c.g_free(u);
    out("set bad {d}", .{c.gst_uri_handler_set_uri(@ptrCast(e), "sinty://bad", &err)});
    printErr("  err", err);
    err = null;
    out("set wrong proto {d}", .{c.gst_uri_handler_set_uri(@ptrCast(e), "http://x", &err)});
    printErr("  err", err);
    err = null;
    out("set invalid {d}", .{c.gst_uri_handler_set_uri(@ptrCast(e), "nope", &err)});
    printErr("  err", err);
    err = null;
    strv(c.gst_uri_handler_get_protocols(@ptrCast(e)));
    c.gst_object_unref(e);
    const m = c.gst_element_make_from_uri(c.GST_URI_SRC, "stest://foo", null, &err);
    out("from uri {d} {s}", .{ @intFromBool(m != null), str(c.g_type_name(if (m != null) c.G_TYPE_FROM_INSTANCE(m) else 0)) });
    printErr("  err", err);
    err = null;
    if (m != null) c.gst_object_unref(m);
    _ = c.gst_element_make_from_uri(c.GST_URI_SINK, "stest://foo", null, &err);
    printErr("sink from uri", err);
    err = null;
    _ = c.gst_element_make_from_uri(c.GST_URI_SRC, "nosuch://foo", null, &err);
    printErr("unsupported", err);
    err = null;
    _ = c.gst_element_make_from_uri(c.GST_URI_SRC, "bad uri", null, &err);
    printErr("invalid", err);
    err = null;
    _ = c.gst_element_make_from_uri(c.GST_URI_SRC, "sinty://bad", null, &err);
    printErr("refused", err);
    err = null;
    out("supported {d} {d} {d}", .{ c.gst_uri_protocol_is_supported(c.GST_URI_SRC, "SINTY"), c.gst_uri_protocol_is_supported(c.GST_URI_SINK, "sinty"), c.gst_uri_protocol_is_supported(c.GST_URI_SRC, "x") });
    var list = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_SRC | c.GST_ELEMENT_FACTORY_TYPE_SINK, c.GST_RANK_MARGINAL);
    var l: ?*c.GList = list;
    while (l) |n| : (l = n.next) if (c.strstr(name(n.data).ptr, "sinty") != null) out("  listed {s}", .{name(n.data)});
    const caps = c.gst_caps_from_string("audio/x-raw, rate=(int)44100, channels=(int)1");
    const filtered = c.gst_element_factory_list_filter(list, caps, c.GST_PAD_SRC, 0);
    l = @ptrCast(filtered);
    while (l) |n| : (l = n.next) out("  filtered {s}", .{name(n.data)});
    c.gst_plugin_feature_list_free(filtered);
    c.gst_plugin_feature_list_free(list);
    list = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_SINK | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO, c.GST_RANK_NONE);
    l = @ptrCast(list);
    while (l) |n| : (l = n.next) if (c.strstr(name(n.data).ptr, "sinty") != null) out("  video sink {s}", .{name(n.data)});
    c.gst_plugin_feature_list_free(list);
    const f = c.gst_element_factory_find("sintytestsrc");
    out("can src any {d} all {d} sink any {d}", .{ c.gst_element_factory_can_src_any_caps(f, caps), c.gst_element_factory_can_src_all_caps(f, caps), c.gst_element_factory_can_sink_any_caps(f, caps) });
    out("is type src {d} audio {d} video {d}", .{ c.gst_element_factory_list_is_type(f, c.GST_ELEMENT_FACTORY_TYPE_SRC), c.gst_element_factory_list_is_type(f, c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO), c.gst_element_factory_list_is_type(f, c.GST_ELEMENT_FACTORY_TYPE_SRC | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO) });
    c.gst_caps_unref(caps);
    out("version {d} {d} {d}", .{ c.gst_registry_check_feature_version(c.gst_registry_get(), "sintytestsrc", 1, 2, 3), c.gst_registry_check_feature_version(c.gst_registry_get(), "sintytestsrc", 1, 2, 4), c.gst_registry_check_feature_version(c.gst_registry_get(), "nosuch", 0, 0, 0) });
    out("element type {s}", .{str(c.g_type_name(c.gst_element_factory_get_element_type(f)))});
    c.gst_object_unref(f);
    const pl = c.gst_element_factory_make_full("pipeline", "name", "pp", "delay", @as(u64, 5), @as([*c]const u8, null));
    var d: u64 = 0;
    c.g_object_get(pl, "delay", &d, @as([*c]const u8, null));
    out("pipeline {s} delay {d} factory {s}", .{ name(pl), d, name(c.gst_element_get_factory(pl)) });
    c.gst_object_unref(pl);
    out("load fail {d} crash plugin {d}", .{ @intFromBool(c.gst_plugin_load_by_name("sintyfail") == null), @intFromBool(c.gst_plugin_load_by_name("sintycrash") == null) });
    out("no factory {d}", .{@intFromBool(c.gst_element_factory_make("nosuchelement", null) == null)});
    const byp = c.gst_registry_get_feature_list_by_plugin(c.gst_registry_get(), "sintytest");
    out("by plugin {d}", .{c.g_list_length(byp)});
    const wrong = c.gst_registry_find_feature(c.gst_registry_get(), "sintytestsrc", c.gst_type_find_factory_get_type());
    out("wrong type null {d}", .{@intFromBool(wrong == null)});
    c.gst_plugin_feature_list_free(byp);
    c.gst_object_unref(p);
}

fn uris() void {
    out("proto {s} valid {d} {d} {d}", .{ str(c.gst_uri_get_protocol("HTTP://x")), c.gst_uri_is_valid("a:b"), c.gst_uri_is_valid("ab:c"), c.gst_uri_protocol_is_valid("x+y.z-") });
    out("has {d} {d}", .{ c.gst_uri_has_protocol("file:///x", "FILE"), c.gst_uri_has_protocol("file:///x", "fil") });
    out("location {s} {s}", .{ str(c.gst_uri_get_location("file:///a%20b/c")), str(c.gst_uri_get_location("file:///a%2Fb")) });
    out("construct {s}", .{str(c.gst_uri_construct("FILE", "/tmp/a b#c?d"))});
    out("filename {s}", .{str(c.gst_filename_to_uri("/a/./b/../c d", null))});
}

fn stageArg() u8 {
    var buf: [4096]u8 = undefined;
    const fd = c.open("/proc/self/cmdline", c.O_RDONLY);
    if (fd < 0) return '1';
    const n = c.read(fd, &buf, buf.len);
    _ = c.close(fd);
    if (n <= 0) return '1';
    const data = buf[0..@intCast(n)];
    const end = std.mem.indexOfScalar(u8, data, 0) orelse return '1';
    if (end + 1 >= data.len) return '1';
    return data[end + 1];
}

fn again(exe: [*:0]const u8, stage: [*:0]const u8) void {
    var args = [_:null]?[*:0]const u8{ exe, stage };
    _ = std.c.execve(exe, &args, std.c.environ);
}

pub fn main() void {
    const stage = stageArg();
    var exe: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return;
    exe[@intCast(n)] = 0;
    const exe_z: [*:0]const u8 = @ptrCast(&exe);
    const dir = std.fs.path.dirname(exe[0..@intCast(n)]).?;
    var buf: [4096]u8 = undefined;
    const plugins = std.fmt.bufPrintZ(&buf, "{s}/../testplugins", .{dir}) catch return;
    _ = c.setenv("GST_PLUGIN_SYSTEM_PATH", plugins.ptr, 1);
    var rbuf: [4096]u8 = undefined;
    const reg = std.fmt.bufPrintZ(&rbuf, "{s}/../reg-{d}.bin", .{ dir, c.getpid() }) catch return;
    _ = c.setenv("GST_REGISTRY", reg.ptr, 1);
    _ = c.setenv("GST_PLUGIN_SCANNER", "/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner", 1);
    _ = c.unsetenv("GST_PLUGIN_PATH");
    _ = c.unsetenv("GST_PLUGIN_PATH_1_0");
    if (stage == '3') _ = c.setenv("GST_REGISTRY_UPDATE", "no", 1);
    out("stage {c}", .{stage});
    c.gst_init(null, null);
    dumpPlugins();
    dumpFeatures();
    dumpTypefind();
    if (stage == '1') {
        exercise();
        uris();
        again(exe_z, "2");
        return;
    }
    if (stage == '2') {
        exercise();
        again(exe_z, "3");
        return;
    }
    _ = c.unlink(reg.ptr);
    out("done", .{});
}
