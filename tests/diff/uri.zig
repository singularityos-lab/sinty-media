const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn segs(u: ?*c.GstUri) void {
    const l = c.gst_uri_get_path_segments(u);
    var n: ?*c.GList = l;
    var buf: [1024]u8 = undefined;
    var w: usize = 0;
    while (n) |x| : (n = x.next) {
        const s = if (x.data != null) std.mem.span(@as([*c]const u8, @ptrCast(x.data))) else "<null>";
        const piece = std.fmt.bufPrint(buf[w..], "[{s}]", .{s}) catch break;
        w += piece.len;
    }
    out("    segs {s}", .{buf[0..w]});
    c.g_list_free_full(l, c.g_free);
}

fn show(label: []const u8, u: ?*c.GstUri) void {
    if (u == null) {
        out("{s}: (null)", .{label});
        return;
    }
    const s = c.gst_uri_to_string(u);
    const p = c.gst_uri_get_path(u);
    const ps = c.gst_uri_get_path_string(u);
    const q = c.gst_uri_get_query_string(u);
    out("{s}: {s}", .{ label, str(s) });
    out("    scheme {s} userinfo {s} host {s} port {d} path {s} pathstr {s} query {s} frag {s} normalized {d}", .{ str(c.gst_uri_get_scheme(u)), str(c.gst_uri_get_userinfo(u)), str(c.gst_uri_get_host(u)), c.gst_uri_get_port(u), str(p), str(ps), str(q), str(c.gst_uri_get_fragment(u)), c.gst_uri_is_normalized(u) });
    segs(u);
    c.g_free(s);
    c.g_free(p);
    c.g_free(ps);
    c.g_free(q);
}

const inputs = [_][*c]const u8{
    "http://user:pw@Example.COM:8080/a/b/../c/./d?x=1&y=two%20words#frag%20ment",
    "file:///tmp/a%20b/c",
    "file:/tmp/x",
    "rtsp://[::1]:554/stream",
    "rtsp://[::1/stream",
    "http://host:80x/",
    "  mailto:someone@example.com",
    "relative/path?q",
    "/abs/path/",
    "?only=query",
    "#justfrag",
    "HTTP://HOST/A%2Fb",
    "",
    "s3://bucket/key/with/trailing/",
    "http://h/p?a=1&b&c=",
    "foo:",
    "//noscheme.host/x",
};

const rel = [_][*c]const u8{ "g", "./g", "g/", "/g", "//g", "?y", "g?y", "#s", "g#s", "g?y#s", ";x", "g;x", "", ".", "./", "..", "../", "../g", "../..", "../../", "../../g", "../../../g", "/./g", "/../g", "g.", ".g", "g..", "..g", "./../g", "./g/.", "g/./h", "g/../h", "http:g" };

pub fn main() void {
    c.gst_init(null, null);
    for (inputs) |in| {
        const u = c.gst_uri_from_string(in);
        show(std.mem.span(in), u);
        if (u != null) {
            const e = c.gst_uri_from_string_escaped(in);
            const es = if (e != null) c.gst_uri_to_string(e) else null;
            out("    escaped-parse {s}", .{str(es)});
            c.g_free(es);
            if (e != null) c.gst_uri_unref(e);
            const cp = c.gst_uri_copy(u);
            out("    equal copy {d} writable {d}", .{ c.gst_uri_equal(u, cp), c.gst_uri_is_writable(cp) });
            const w = c.gst_uri_make_writable(cp);
            out("    normalize {d}", .{c.gst_uri_normalize(w)});
            show("    normalized", w);
            out("    equal after normalize {d}", .{c.gst_uri_equal(u, w)});
            c.gst_uri_unref(w);
            c.gst_uri_unref(u);
        }
    }
    const base = c.gst_uri_from_string("http://a/b/c/d;p?q");
    for (rel) |r| {
        const j = c.gst_uri_from_string_with_base(base, r);
        const s = if (j != null) c.gst_uri_to_string(j) else null;
        out("join [{s}] -> {s}", .{ str(r), str(s) });
        c.g_free(s);
        if (j != null) c.gst_uri_unref(j);
    }
    c.gst_uri_unref(base);
    out("join strings {s}", .{str(c.gst_uri_join_strings("http://x/y/z", "../w?k=v"))});
    out("join bad {s}", .{str(c.gst_uri_join_strings("http://[bad", "x"))});
    const n = c.gst_uri_new("HTTP", "me", "Host", 99, "/a b/c", "k=v&k2=%3Dx&flag", "f g");
    show("new", n);
    const keys = c.gst_uri_get_query_keys(n);
    out("    keys {d} has k2 {d} k2={s} flag={s}", .{ c.g_list_length(keys), c.gst_uri_query_has_key(n, "k2"), str(c.gst_uri_get_query_value(n, "k2")), str(c.gst_uri_get_query_value(n, "flag")) });
    c.g_list_free(keys);
    var order: ?*c.GList = null;
    order = c.g_list_append(order, @constCast("flag"));
    order = c.g_list_append(order, @constCast("missing"));
    order = c.g_list_append(order, @constCast("k"));
    const os = c.gst_uri_get_query_string_ordered(n, order);
    out("    ordered {s}", .{str(os)});
    c.g_free(os);
    const ws = c.gst_uri_to_string_with_keys(n, order);
    out("    with keys {s}", .{str(ws)});
    c.g_free(ws);
    c.g_list_free(order);
    out("    set value {d} remove {d} remove missing {d}", .{ c.gst_uri_set_query_value(n, "new", "a&b"), c.gst_uri_remove_query_key(n, "k"), c.gst_uri_remove_query_key(n, "nope") });
    out("    set scheme {d} host {d} port {d} userinfo {d} fragment {d}", .{ c.gst_uri_set_scheme(n, "rtsp"), c.gst_uri_set_host(n, "::1"), c.gst_uri_set_port(n, c.GST_URI_NO_PORT), c.gst_uri_set_userinfo(n, null), c.gst_uri_set_fragment(n, "t=10,20") });
    out("    append {d} {d} {d}", .{ c.gst_uri_append_path(n, "x/y/"), c.gst_uri_append_path_segment(n, "z w"), c.gst_uri_append_path(n, "/q") });
    show("modified", n);
    const mf = c.gst_uri_get_media_fragment_table(n);
    out("    media t={s}", .{str(@ptrCast(c.g_hash_table_lookup(mf, "t")))});
    c.g_hash_table_unref(mf);
    out("    set path {d} set path string {d}", .{ c.gst_uri_set_path(n, "/raw%20/p"), 0 });
    show("path set", n);
    _ = c.gst_uri_set_path_string(n, "/esc%20aped/p");
    show("path string set", n);
    _ = c.gst_uri_set_query_string(n, "a=1&b=%26");
    show("query string set", n);
    const tbl = c.gst_uri_get_query_table(n);
    _ = c.gst_uri_set_query_table(n, null);
    show("query cleared", n);
    _ = c.gst_uri_set_query_table(n, tbl);
    c.g_hash_table_unref(tbl);
    show("query restored", n);
    out("null getters {s} {d} {d}", .{ str(c.gst_uri_get_scheme(null)), c.gst_uri_get_port(null), c.gst_uri_set_scheme(null, null) });
    const nn = c.gst_uri_new(null, null, null, c.GST_URI_NO_PORT, null, null, null);
    show("empty", nn);
    out("equal empty {d} {d}", .{ c.gst_uri_equal(nn, null), c.gst_uri_equal(null, null) });
    c.gst_uri_unref(nn);
    const r1 = c.gst_uri_ref(n);
    c.gst_uri_unref(r1);
    var cl: ?*c.GstUri = c.gst_uri_copy(n);
    c.gst_clear_uri(&cl);
    out("cleared {d}", .{@intFromBool(cl == null)});
    c.gst_uri_unref(n);
    out("type {s}", .{str(c.g_type_name(c.gst_uri_get_type()))});
    out("done", .{});
}
