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

fn byName(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return c.g_strcmp0(@as(*const c.GstObject, @ptrCast(@alignCast(a))).name, @as(*const c.GstObject, @ptrCast(@alignCast(b))).name);
}

var indent_buf = [_]u8{' '} ** 64;

fn pads(e: ?*c.GstElement, depth: usize) void {
    var list: ?*c.GList = c.g_list_copy(e.?.pads);
    list = c.g_list_sort(list, byName);
    var l = list;
    while (l) |n| : (l = n.next) {
        const p: ?*c.GstPad = @ptrCast(@alignCast(n.data));
        const peer = c.gst_pad_get_peer(p);
        var pe: ?*c.GstObject = null;
        if (peer != null) pe = c.gst_object_get_parent(@ptrCast(@alignCast(peer)));
        const ghost = c.g_type_check_instance_is_a(@ptrCast(@alignCast(p)), c.gst_ghost_pad_get_type()) != 0;
        out("{s}  pad {s}{s} -> {s}:{s}", .{ indent_buf[0 .. depth * 2], name(p), if (ghost) " (ghost)" else "", name(pe), name(peer) });
        if (pe != null) c.gst_object_unref(pe);
        if (peer != null) c.gst_object_unref(peer);
    }
    c.g_list_free(list);
}

fn describe(e: ?*c.GstElement, depth: usize) void {
    if (e == null) {
        out("{s}(null)", .{indent_buf[0 .. depth * 2]});
        return;
    }
    out("{s}{s} [{s}]", .{ indent_buf[0 .. depth * 2], name(e), str(c.g_type_name(c.G_TYPE_FROM_INSTANCE(e))) });
    pads(e, depth);
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(e)), c.gst_bin_get_type()) == 0) return;
    const b: *c.GstBin = @ptrCast(@alignCast(e));
    var list: ?*c.GList = c.g_list_copy(b.children);
    list = c.g_list_sort(list, byName);
    var l = list;
    while (l) |n| : (l = n.next) describe(@ptrCast(@alignCast(n.data)), depth + 1);
    c.g_list_free(list);
}

fn report(e: ?*c.GstElement, err: [*c]c.GError, ctx: ?*c.GstParseContext) void {
    if (err != null) {
        out("  error {s} {d}: {s}", .{ str(c.g_quark_to_string(err.*.domain)), err.*.code, str(err.*.message) });
        c.g_error_free(err);
    }
    if (ctx != null) {
        const miss = c.gst_parse_context_get_missing_elements(ctx);
        if (miss != null) {
            var i: usize = 0;
            while (miss[i] != null) : (i += 1) out("  missing {s}", .{str(miss[i])});
        }
        c.g_strfreev(miss);
    }
    describe(e, 1);
}

fn run(desc: [*c]const u8, flags: c.GstParseFlags) ?*c.GstElement {
    out("== [{s}] flags {d}", .{ str(desc), flags });
    var err: [*c]c.GError = null;
    const ctx = c.gst_parse_context_new();
    const e = c.gst_parse_launch_full(desc, ctx, flags, &err);
    report(e, err, ctx);
    c.gst_parse_context_free(ctx);
    return e;
}

fn drop(e: ?*c.GstElement) void {
    if (e != null) {
        _ = c.gst_object_ref_sink(e);
        c.gst_object_unref(e);
    }
}

fn intProp(e: ?*c.GstElement, prop: [*c]const u8) c.gint {
    var v: c.gint = -1;
    c.g_object_get(e, prop, &v, @as([*c]const u8, null));
    return v;
}

fn strProp(e: ?*c.GstElement, prop: [*c]const u8) [*c]u8 {
    var v: [*c]u8 = null;
    c.g_object_get(e, prop, &v, @as([*c]const u8, null));
    return v;
}

fn byNameIn(e: ?*c.GstElement, n: [*c]const u8) ?*c.GstElement {
    return c.gst_bin_get_by_name(@ptrCast(@alignCast(e)), n);
}

const cases = [_][*c]const u8{
    "sintysrc ! sintysink",
    "sintysrc num=3 label=\"hello world\" ! sintyfilter ! sintysink",
    "sintysrc name=s ! sintysink s. ! sintysink",
    "sintysrc ! audio/x-raw ! sintysink",
    "sintysrc ! video/x-raw ! sintysink",
    "sintysrc ! audio/x-raw ! video/x-raw ! sintysink",
    "sintysrc ! nosuchelement ! sintysink",
    "( sintysrc ! sintysink )",
    "bin.( sintysrc ) ! sintysink",
    "sintysrc",
    "",
    "   ",
    "sintysrc !",
    "sintysrc ! ! sintysink",
    "sintysrc nosuch=1 ! sintysink",
    "sintysrc num=abc ! sintysink",
    "sintysrc num=500 ! sintysink",
    "sintytee name=t ! sintysink t. ! sintysink t. ! sintysink",
    "sintydemux name=d d.src_1 ! sintysink",
    "sintydemux name=d d. ! sintysink d. ! sintysink",
    "sintysrc ! .sink sintyfilter name=f ! sintysink",
    "sintychildbin inner::num=7 inner::label=kid",
    "sintychildbin missing::num=7",
    "sintysrc @preset=fast ! sintysink",
    "sintysrc @preset=nosuch ! sintysink",
    "sintysink @preset=fast",
    "sintysrc ! sintysink sintysrc ! sintysink",
    "( sintysrc",
    "sintysrc )",
    "sintysrc ! ( sintyfilter ) ! sintysink",
    "sintysrc ! sintyfilter : sintysink",
    "nosuch.( sintysrc ! sintysink )",
    "( )",
    "sintysrc ! nobody.",
    "sintysrc name=a a.src ! sintysink",
    "sintysrc name=a a.src,src ! sintysink",
    "sintysrc ! \"audio/x-raw, rate=(int)44100\" ! sintysink",
    "sintysrc label=\"a\\\"b\" ! sintysink",
    "sintysrc label=a\\ b ! sintysink",
    "sintysrc label='x y' ! sintysink",
    "sintysrc target=\"sintyfilter name=inner\" ! sintysink",
    "sintysrc ! sintysink name=k k.",
    "sintysrc ! sintysink . sintysrc",
    "sintysrc name=dup ! sintysink name=dup",
    "sintysrc ! audio/x-raw;video/x-raw ! sintysink",
    "sintysrc ! audio/x-raw,rate=44100 : sintysink",
    "sintysrc ! sinty://foo",
    "sinty://bar ! sintysink",
    "sintysrc ! sintysink name=x ( name=b sintysrc ! sintysink )",
    "sintysrc,x ! sintysink",
    "sintysrc ! { sintysink }",
    "sintysrc ! sintysink =",
};

fn setupEnv(dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    _ = c.setenv("GST_PLUGIN_SYSTEM_PATH", (std.fmt.bufPrintZ(&buf, "{s}/../testplugins", .{dir}) catch return).ptr, 1);
    _ = c.setenv("GST_REGISTRY", (std.fmt.bufPrintZ(&buf, "{s}/../preg-{d}.bin", .{ dir, c.getpid() }) catch return).ptr, 1);
    _ = c.setenv("XDG_DATA_HOME", (std.fmt.bufPrintZ(&buf, "{s}/../testxdg-{d}", .{ dir, c.getpid() }) catch return).ptr, 1);
    const pdir = std.fmt.bufPrintZ(&buf, "{s}/../testpresets", .{dir}) catch return;
    _ = c.g_mkdir_with_parents(pdir.ptr, 0o755);
    _ = c.setenv("GST_PRESET_PATH", pdir.ptr, 1);
    var fbuf: [4096]u8 = undefined;
    const file = std.fmt.bufPrintZ(&fbuf, "{s}/SintySrc.prs", .{pdir}) catch return;
    const text = "[_presets_]\nelement-name=SintySrc\nversion=1.0\n\n[fast]\nnum=42\nlabel=quick\n";
    _ = c.g_file_set_contents(file.ptr, text, text.len, null);
    _ = c.setenv("GST_PLUGIN_SCANNER", "/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner", 1);
    _ = c.unsetenv("GST_PLUGIN_PATH");
    _ = c.unsetenv("GST_PLUGIN_PATH_1_0");
}

pub fn main() void {
    var exe: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return;
    const dir = std.fs.path.dirname(exe[0..@intCast(n)]).?;
    setupEnv(dir);
    c.gst_init(null, null);
    for (cases) |desc| {
        const e = run(desc, c.GST_PARSE_FLAG_NONE);
        if (c.strcmp(desc, "sintysrc num=3 label=\"hello world\" ! sintyfilter ! sintysink") == 0) {
            const s = byNameIn(e, "sintysrc0");
            const l = strProp(s, "label");
            out("  num {d} label {s}", .{ intProp(s, "num"), str(l) });
            c.g_free(l);
            if (s != null) c.gst_object_unref(s);
        }
        if (c.strstr(desc, "sintydemux") != null and e != null) {
            out("  set ready {d}", .{c.gst_element_set_state(e, c.GST_STATE_READY)});
            describe(e, 1);
            const bus = c.gst_element_get_bus(e);
            while (c.gst_bus_pop(bus)) |m| {
                if (m.*.type == c.GST_MESSAGE_WARNING) {
                    var werr: [*c]c.GError = null;
                    var dbg: [*c]u8 = null;
                    c.gst_message_parse_warning(m, &werr, &dbg);
                    out("  warning {s} | {s}", .{ str(werr.*.message), str(dbg) });
                    c.g_error_free(werr);
                    c.g_free(dbg);
                }
                c.gst_message_unref(m);
            }
            c.gst_object_unref(bus);
            _ = c.gst_element_set_state(e, c.GST_STATE_NULL);
        }
        if (c.strstr(desc, "sintychildbin inner") != null and e != null) {
            const k = byNameIn(e, "inner");
            const l = strProp(k, "label");
            out("  child num {d} label {s}", .{ intProp(k, "num"), str(l) });
            c.g_free(l);
            c.gst_object_unref(k);
        }
        if (c.strstr(desc, "@preset=fast") != null and e != null) {
            const s = if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(e)), c.gst_bin_get_type()) != 0) byNameIn(e, "sintysrc0") else null;
            if (s != null) {
                const l = strProp(s, "label");
                out("  preset num {d} label {s}", .{ intProp(s, "num"), str(l) });
                c.g_free(l);
                const names = c.gst_preset_get_preset_names(@ptrCast(s));
                out("  presets {s}", .{if (names != null) str(names[0]) else "(none)"});
                c.g_strfreev(names);
                c.gst_object_unref(s);
            }
        }
        if (c.strstr(desc, "target=") != null and e != null) {
            const s = byNameIn(e, "sintysrc0");
            var t: ?*c.GstElement = null;
            c.g_object_get(s, "target", &t, @as([*c]const u8, null));
            out("  target:", .{});
            describe(t, 2);
            if (t != null) c.gst_object_unref(t);
            c.gst_object_unref(s);
        }
        drop(e);
    }
    drop(run("sintysrc ! nosuchelement ! sintysink", c.GST_PARSE_FLAG_FATAL_ERRORS));
    drop(run("sintysrc ! sintysink", c.GST_PARSE_FLAG_PLACE_IN_BIN));
    drop(run("sintysrc ! sintyfilter", c.GST_PARSE_FLAG_PLACE_IN_BIN | c.GST_PARSE_FLAG_FATAL_ERRORS));
    var err: [*c]c.GError = null;
    out("== bin from description ghost", .{});
    var e = c.gst_parse_bin_from_description("sintyfilter ! sintyfilter", 1, &err);
    report(e, err, null);
    drop(e);
    err = null;
    out("== bin from description single no-single-bins", .{});
    e = c.gst_parse_bin_from_description_full("sintyfilter", 1, null, c.GST_PARSE_FLAG_NO_SINGLE_ELEMENT_BINS, &err);
    report(e, err, null);
    drop(e);
    err = null;
    out("== bin from description error", .{});
    e = c.gst_parse_bin_from_description("nosuch", 0, &err);
    report(e, err, null);
    drop(e);
    err = null;
    out("== launchv", .{});
    var argv = [_][*c]const u8{ "sintysrc", "label=a b", "!", "sintysink", null };
    e = c.gst_parse_launchv(@ptrCast(&argv), &err);
    report(e, err, null);
    if (e != null) {
        const s = byNameIn(e, "sintysrc0");
        const l = strProp(s, "label");
        out("  label {s}", .{str(l)});
        c.g_free(l);
        c.gst_object_unref(s);
    }
    drop(e);
    const ctx = c.gst_parse_context_new();
    _ = c.gst_parse_launch_full("a1 ! a2", ctx, 0, null);
    const copy = c.gst_parse_context_copy(ctx);
    const miss = c.gst_parse_context_get_missing_elements(copy);
    out("== context copy {s} {s}", .{ str(miss[0]), str(miss[1]) });
    c.g_strfreev(miss);
    c.gst_parse_context_free(copy);
    c.gst_parse_context_free(ctx);
    out("context type {s} quark {s}", .{ str(c.g_type_name(c.gst_parse_context_get_type())), str(c.g_quark_to_string(c.gst_parse_error_quark())) });
    var buf: [4096]u8 = undefined;
    _ = c.unlink((std.fmt.bufPrintZ(&buf, "{s}/../preg-{d}.bin", .{ dir, c.getpid() }) catch return).ptr);
    out("done", .{});
}
