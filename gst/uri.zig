const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const core = @import("core.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Mini = c.GstMiniObject;
const List = ?*c.GList;

pub const Uri = extern struct {
    mini_object: Mini,
    scheme: [*c]u8,
    userinfo: [*c]u8,
    host: [*c]u8,
    port: c.guint,
    path: List,
    query: ?*c.GHashTable,
    fragment: [*c]u8,

    pub const Header = c.struct__GstUri;
};

const NO_PORT: c.guint = c.GST_URI_NO_PORT;
const SUBDELIMS = "!$&'()*+,;=";
const IN_PATH_ELEMENT = SUBDELIMS ++ ":@";
const IN_PATH = IN_PATH_ELEMENT ++ "/";
const IN_USERINFO = SUBDELIMS ++ ":";

pub export var _gst_uri_type: c.GType = 0;
var type_once: gtype.Once = .{};

fn of(p: anytype) [*c]Uri {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn isUri(p: anytype) bool {
    return p != null and @as([*c]Mini, @ptrCast(@alignCast(@constCast(p))))[0].type == gst_uri_get_type();
}

pub export fn gst_uri_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            _gst_uri_type = c.g_boxed_type_register_static("GstUri", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
            return _gst_uri_type;
        }
    }.f);
}

fn create() [*c]Uri {
    if (!check.that(core.gst_is_initialized() != 0, "_gst_uri_new", "gst_is_initialized ()")) return null;
    const u: [*c]Uri = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Uri))));
    mini.gst_mini_object_init(@ptrCast(u), 0, gst_uri_get_type(), copyHook, null, freeHook);
    return u;
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    const u = of(m);
    if (!check.that(isUri(u), "_gst_uri_free", "GST_IS_URI (uri)")) return;
    c.g_free(u[0].scheme);
    c.g_free(u[0].userinfo);
    c.g_free(u[0].host);
    c.g_list_free_full(u[0].path, c.g_free);
    if (u[0].query) |q| c.g_hash_table_unref(q);
    c.g_free(u[0].fragment);
    c.g_free(u);
}

fn copyTable(orig: ?*c.GHashTable) ?*c.GHashTable {
    const o = orig orelse return null;
    const t = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, c.g_free);
    var it: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&it, o);
    var k: c.gpointer = null;
    var v: c.gpointer = null;
    while (c.g_hash_table_iter_next(&it, &k, &v) != 0) _ = c.g_hash_table_insert(t, c.g_strdup(@ptrCast(k)), c.g_strdup(@ptrCast(v)));
    return t;
}

fn dupList(l: List) List {
    return c.g_list_copy_deep(l, @ptrCast(&c.g_strdup), null);
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    const o = of(src);
    if (!check.that(isUri(o), "_gst_uri_copy", "GST_IS_URI (orig_uri)")) return null;
    const n = create();
    if (n == null) return null;
    n[0].scheme = c.g_strdup(o[0].scheme);
    n[0].userinfo = c.g_strdup(o[0].userinfo);
    n[0].host = c.g_strdup(o[0].host);
    n[0].port = o[0].port;
    n[0].path = dupList(o[0].path);
    n[0].query = copyTable(o[0].query);
    n[0].fragment = c.g_strdup(o[0].fragment);
    return @ptrCast(n);
}

fn compareLists(a: List, b: List) c.gint {
    var x = a;
    var y = b;
    while (x != null or y != null) {
        const xn = x orelse return -1;
        const yn = y orelse return 1;
        const r = c.g_strcmp0(@ptrCast(xn.data), @ptrCast(yn.data));
        if (r != 0) return r;
        x = xn.next;
        y = yn.next;
    }
    return 0;
}

fn firstUpper(s: [*c]const u8) [*c]const u8 {
    if (s == null) return null;
    var p = s;
    while (p[0] != 0) : (p += 1) if (std.ascii.isUpper(p[0])) return p;
    return null;
}

fn lowercase(s: [*c]u8) bool {
    if (s == null) return false;
    var changed = false;
    var p = s;
    while (p[0] != 0) : (p += 1) if (std.ascii.isUpper(p[0])) {
        p[0] = std.ascii.toLower(p[0]);
        changed = true;
    };
    return changed;
}

fn removeDots(path: List) List {
    if (path == null) return null;
    var out: List = dupList(path);
    var e = out;
    while (e) |node| {
        const next = node.next;
        if (node.data == null and node != out and next != null) {
            out = c.g_list_delete_link(out, node);
        } else if (c.g_strcmp0(@ptrCast(node.data), ".") == 0) {
            c.g_free(node.data);
            out = c.g_list_delete_link(out, node);
        } else if (c.g_strcmp0(@ptrCast(node.data), "..") == 0) {
            const before: List = node.prev;
            if (before) |prev| {
                if (prev != out or prev.data != null) {
                    c.g_free(prev.data);
                    out = c.g_list_delete_link(out, prev);
                }
            }
            c.g_free(node.data);
            if (next != null) {
                out = c.g_list_delete_link(out, node);
            } else node.data = null;
        }
        e = next;
    }
    return out;
}

fn normalizePath(path: *List) bool {
    const n = removeDots(path.*);
    if (compareLists(n, path.*) != 0) {
        c.g_list_free_full(path.*, c.g_free);
        path.* = n;
        return true;
    }
    c.g_list_free_full(n, c.g_free);
    return false;
}

fn merge(base: List, path: List) List {
    var copy = dupList(path);
    if (base == null) {
        if (copy != null and copy.?.data != null) copy = c.g_list_prepend(copy, null);
        return copy;
    }
    var ret = dupList(base);
    const last = c.g_list_last(ret);
    ret = c.g_list_remove_link(ret, last);
    c.g_list_free_full(last, c.g_free);
    return c.g_list_concat(ret, copy);
}

fn escape(s: [*c]const u8, allowed: [*c]const u8) [*c]u8 {
    return c.g_uri_escape_string(s, allowed, 0);
}

fn escapeQuery(s: [*c]const u8) [*c]u8 {
    const r = c.g_uri_escape_string(s, "!$'()*,;:@/?= ", 0);
    var p = r;
    while (p[0] != 0) : (p += 1) if (p[0] == ' ') {
        p[0] = '+';
    };
    return r;
}

fn pctOf(sep: u8) [4]u8 {
    var buf: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "%{X:0>2}", .{sep}) catch {};
    buf[3] = 0;
    return buf;
}

fn decodeSeps(s: [*c]u8, pct: *const [4]u8, sep: u8) void {
    var p = c.strcasestr(s, pct);
    while (p != null) {
        p[0] = sep;
        _ = c.memmove(p + 1, p + 3, c.strlen(p + 3) + 1);
        p = c.strcasestr(p + 1, pct);
    }
}

fn toList(str: [*c]const u8, sep: [*c]const u8, convert: bool, unescape_it: bool) List {
    if (str == null) return null;
    const pct = pctOf(sep[0]);
    const parts = c.g_strsplit(str, sep, -1);
    defer c.g_strfreev(parts);
    var out: List = null;
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) {
        var elem = parts[i];
        if (elem[0] == 0) {
            out = c.g_list_prepend(out, null);
            continue;
        }
        if (convert and !unescape_it) decodeSeps(elem, &pct, sep[0]);
        if (unescape_it) {
            parts[i] = c.g_uri_unescape_string(elem, null);
            c.g_free(elem);
            elem = parts[i];
        }
        out = c.g_list_prepend(out, c.g_strdup(elem));
    }
    return c.g_list_reverse(out);
}

fn toTable(str: [*c]const u8, part_sep: [*c]const u8, kv_sep: [*c]const u8, convert: bool, unescape_it: bool) ?*c.GHashTable {
    if (str == null) return null;
    const t = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, c.g_free);
    const pct_part = pctOf(part_sep[0]);
    const pct_kv = pctOf(kv_sep[0]);
    const parts = c.g_strsplit(str, part_sep, -1);
    defer c.g_strfreev(parts);
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) {
        const part = parts[i];
        if (convert and !unescape_it) decodeSeps(part, &pct_part, part_sep[0]);
        const kv = c.g_strstr_len(part, -1, kv_sep);
        var key: [*c]u8 = null;
        var value: [*c]u8 = null;
        if (kv == null) {
            key = if (unescape_it) c.g_uri_unescape_string(part, null) else c.g_strdup(part);
        } else if (unescape_it) {
            key = c.g_uri_unescape_segment(part, kv, null);
            value = c.g_uri_unescape_string(kv + 1, null);
        } else {
            key = c.g_strndup(part, @intFromPtr(kv) - @intFromPtr(part));
            value = c.g_strdup(kv + 1);
        }
        if (convert and !unescape_it) {
            decodeSeps(key, &pct_kv, kv_sep[0]);
            if (value != null) decodeSeps(value, &pct_kv, kv_sep[0]);
        }
        _ = c.g_hash_table_insert(t, key, value);
    }
    return t;
}

pub export fn gst_uri_new(scheme: [*c]const u8, userinfo: [*c]const u8, host: [*c]const u8, port: c.guint, path: [*c]const u8, query: [*c]const u8, fragment: [*c]const u8) [*c]Uri {
    const u = create();
    if (u == null) return null;
    u[0].scheme = c.g_strdup(scheme);
    u[0].userinfo = c.g_strdup(userinfo);
    u[0].host = c.g_strdup(host);
    u[0].port = port;
    u[0].path = toList(path, "/", false, false);
    u[0].query = toTable(query, "&", "=", true, false);
    u[0].fragment = c.g_strdup(fragment);
    return u;
}

pub export fn gst_uri_new_with_base(base: [*c]Uri, scheme: [*c]const u8, userinfo: [*c]const u8, host: [*c]const u8, port: c.guint, path: [*c]const u8, query: [*c]const u8, fragment: [*c]const u8) [*c]Uri {
    if (!check.that(base == null or isUri(base), "gst_uri_new_with_base", "base == NULL || GST_IS_URI (base)")) return null;
    const rel = gst_uri_new(scheme, userinfo, host, port, path, query, fragment);
    const u = gst_uri_join(base, rel);
    gst_uri_unref(rel);
    return u;
}

fn parse(text: [*c]const u8, unescape_it: bool) [*c]Uri {
    const u = create();
    if (u == null or text == null) return u;
    var s = text;
    while (s[0] == 0x0b or std.ascii.isWhitespace(s[0])) s += 1;
    var i: usize = 0;
    if (std.ascii.isAlphabetic(s[0])) {
        i = 1;
        while (std.ascii.isAlphanumeric(s[i]) or s[i] == '+' or s[i] == '-' or s[i] == '.') i += 1;
    }
    if (i > 0 and s[i] == ':') {
        u[0].scheme = c.g_strndup(s, i);
        s += i + 1;
    }
    if (s[0] == '/' and s[1] == '/') {
        s += 2;
        const eoa = s + c.strcspn(s, "/?#");
        const eoui = c.strchr(s, '@');
        if (eoui != null and @intFromPtr(eoui) < @intFromPtr(eoa)) {
            u[0].userinfo = if (unescape_it) c.g_uri_unescape_segment(s, eoui, null) else c.g_strndup(s, @intFromPtr(eoui) - @intFromPtr(s));
            s = eoui + 1;
        }
        var eoh: [*c]const u8 = undefined;
        var reoh: [*c]const u8 = undefined;
        if (s[0] == '[') {
            eoh = c.strchr(s, ']');
            if (eoh == null or @intFromPtr(eoh) > @intFromPtr(eoa)) {
                gst_uri_unref(u);
                return null;
            }
            reoh = eoh + 1;
            s += 1;
        } else {
            eoh = c.strchr(s, ':');
            if (eoh == null or @intFromPtr(eoh) > @intFromPtr(eoa)) eoh = eoa;
            reoh = eoh;
        }
        if (eoh != s) u[0].host = c.g_uri_unescape_segment(s, eoh, null);
        s = reoh;
        if (@intFromPtr(s) < @intFromPtr(eoa)) {
            if (s[0] != ':' or c.strspn(s + 1, "0123456789") != @intFromPtr(eoa) - @intFromPtr(s) - 1) {
                gst_uri_unref(u);
                return null;
            }
            s += 1;
            while (@intFromPtr(s) < @intFromPtr(eoa)) : (s += 1) u[0].port = u[0].port *% 10 +% @as(c.guint, s[0] - '0');
        }
        s = eoa;
    }
    var rest: [*c]const u8 = s;
    if (rest[0] != 0) {
        const len = c.strcspn(rest, "?#");
        if (rest[len] == 0) {
            u[0].path = toList(rest, "/", false, true);
            rest = null;
        } else {
            if (len > 0) {
                const p = c.g_strndup(rest, len);
                u[0].path = toList(p, "/", false, true);
                c.g_free(p);
            }
            rest += len;
        }
    }
    if (rest != null and rest[0] == '?') {
        rest += 1;
        const eoq = c.strchr(rest, '#');
        if (eoq == null) {
            u[0].query = toTable(rest, "&", "=", true, true);
            rest = null;
        } else {
            if (eoq != rest) {
                const q = c.g_strndup(rest, @intFromPtr(eoq) - @intFromPtr(rest));
                u[0].query = toTable(q, "&", "=", true, true);
                c.g_free(q);
            }
            rest = eoq;
        }
    }
    if (rest != null and rest[0] == '#') u[0].fragment = if (unescape_it) c.g_uri_unescape_string(rest + 1, null) else c.g_strdup(rest + 1);
    return u;
}

pub export fn gst_uri_from_string(text: [*c]const u8) [*c]Uri {
    return parse(text, true);
}

pub export fn gst_uri_from_string_escaped(text: [*c]const u8) [*c]Uri {
    return parse(text, false);
}

pub export fn gst_uri_from_string_with_base(base: [*c]Uri, text: [*c]const u8) [*c]Uri {
    if (!check.that(base == null or isUri(base), "gst_uri_from_string_with_base", "base == NULL || GST_IS_URI (base)")) return null;
    const rel = gst_uri_from_string(text);
    if (rel == null) return null;
    const u = gst_uri_join(base, rel);
    gst_uri_unref(rel);
    return u;
}

fn normalizedEqual(a: [*c]const u8, b: [*c]const u8) bool {
    var na: [*c]u8 = null;
    var nb: [*c]u8 = null;
    defer {
        c.g_free(na);
        c.g_free(nb);
    }
    var x = a;
    var y = b;
    if (firstUpper(a) != null) {
        na = c.g_strdup(a);
        _ = lowercase(na);
        x = na;
    }
    if (firstUpper(b) != null) {
        nb = c.g_strdup(b);
        _ = lowercase(nb);
        y = nb;
    }
    return c.g_strcmp0(x, y) == 0;
}

pub export fn gst_uri_equal(a: [*c]const Uri, b: [*c]const Uri) c.gboolean {
    if (!check.that((a == null or isUri(a)) and (b == null or isUri(b)), "gst_uri_equal", "(first == NULL || GST_IS_URI (first)) && (second == NULL || GST_IS_URI (second))")) return 0;
    if (a == b) return 1;
    if (a == null or b == null) return 0;
    if (a[0].port != b[0].port) return 0;
    if (c.g_strcmp0(a[0].userinfo, b[0].userinfo) != 0) return 0;
    if (c.g_strcmp0(a[0].fragment, b[0].fragment) != 0) return 0;
    if (!normalizedEqual(a[0].scheme, b[0].scheme)) return 0;
    if (!normalizedEqual(a[0].host, b[0].host)) return 0;
    var pa = dupList(a[0].path);
    _ = normalizePath(&pa);
    var pb = dupList(b[0].path);
    _ = normalizePath(&pb);
    const r = compareLists(pa, pb);
    c.g_list_free_full(pa, c.g_free);
    c.g_list_free_full(pb, c.g_free);
    if (r != 0) return 0;
    if ((a[0].query == null) != (b[0].query == null)) return 0;
    if (a[0].query) |qa| {
        const qb = b[0].query.?;
        if (c.g_hash_table_size(qa) != c.g_hash_table_size(qb)) return 0;
        var it: c.GHashTableIter = undefined;
        c.g_hash_table_iter_init(&it, qa);
        var k: c.gpointer = null;
        var v: c.gpointer = null;
        while (c.g_hash_table_iter_next(&it, &k, &v) != 0) {
            if (c.g_hash_table_contains(qb, k) == 0) return 0;
            if (c.g_strcmp0(@ptrCast(c.g_hash_table_lookup(qb, k)), @ptrCast(v)) != 0) return 0;
        }
    }
    return 1;
}

pub export fn gst_uri_join(base: [*c]Uri, ref: [*c]Uri) [*c]Uri {
    const f = "gst_uri_join";
    if (!check.that((base == null or isUri(base)) and (ref == null or isUri(ref)), f, "(base_uri == NULL || GST_IS_URI (base_uri)) && (ref_uri == NULL || GST_IS_URI (ref_uri))")) return null;
    if (base == null and ref == null) return null;
    if (base == null) return gst_uri_ref(ref);
    if (ref == null) return gst_uri_ref(base);
    const t = create();
    if (t == null) return t;
    var scheme = ref[0].scheme;
    if (scheme != null and c.g_strcmp0(base[0].scheme, scheme) == 0) scheme = null;
    if (scheme != null) {
        t[0].scheme = c.g_strdup(scheme);
        t[0].userinfo = c.g_strdup(ref[0].userinfo);
        t[0].host = c.g_strdup(ref[0].host);
        t[0].port = ref[0].port;
        t[0].path = removeDots(ref[0].path);
        t[0].query = copyTable(ref[0].query);
    } else {
        if (ref[0].host != null) {
            t[0].userinfo = c.g_strdup(ref[0].userinfo);
            t[0].host = c.g_strdup(ref[0].host);
            t[0].port = ref[0].port;
            t[0].path = removeDots(ref[0].path);
            t[0].query = copyTable(ref[0].query);
        } else {
            if (ref[0].path == null) {
                t[0].path = dupList(base[0].path);
                t[0].query = copyTable(if (ref[0].query != null) ref[0].query else base[0].query);
            } else {
                if (ref[0].path.?.data == null) {
                    t[0].path = removeDots(ref[0].path);
                } else {
                    const m = merge(base[0].path, ref[0].path);
                    t[0].path = removeDots(m);
                    c.g_list_free_full(m, c.g_free);
                }
                t[0].query = copyTable(ref[0].query);
            }
            t[0].userinfo = c.g_strdup(base[0].userinfo);
            t[0].host = c.g_strdup(base[0].host);
            t[0].port = base[0].port;
        }
        t[0].scheme = c.g_strdup(base[0].scheme);
    }
    t[0].fragment = c.g_strdup(ref[0].fragment);
    return t;
}

pub export fn gst_uri_join_strings(base_s: [*c]const u8, ref_s: [*c]const u8) [*c]u8 {
    const base = gst_uri_from_string(base_s);
    if (base == null) return null;
    defer gst_uri_unref(base);
    const r = gst_uri_from_string_with_base(base, ref_s);
    if (r == null) return null;
    defer gst_uri_unref(r);
    return gst_uri_to_string(r);
}

pub export fn gst_uri_is_writable(u: [*c]const Uri) c.gboolean {
    if (!check.that(isUri(u), "gst_uri_is_writable", "GST_IS_URI (uri)")) return 0;
    return mini.gst_mini_object_is_writable(@ptrCast(u));
}

pub export fn gst_uri_make_writable(u: [*c]Uri) [*c]Uri {
    if (!check.that(isUri(u), "gst_uri_make_writable", "GST_IS_URI (uri)")) return null;
    return @ptrCast(mini.gst_mini_object_make_writable(@ptrCast(u)));
}

pub export fn gst_uri_to_string_with_keys(u: [*c]const Uri, keys: ?*const c.GList) [*c]u8 {
    if (!check.that(isUri(u), "gst_uri_to_string_with_keys", "GST_IS_URI (uri)")) return null;
    const s = c.g_string_new(null);
    if (u[0].scheme != null) c.g_string_append_printf(s, "%s:", u[0].scheme);
    if (u[0].userinfo != null or u[0].host != null or u[0].port != NO_PORT or c.g_strcmp0(u[0].scheme, "file") == 0) _ = c.g_string_append(s, "//");
    if (u[0].userinfo != null) {
        const e = escape(u[0].userinfo, IN_USERINFO);
        c.g_string_append_printf(s, "%s@", e);
        c.g_free(e);
    }
    if (u[0].host != null) {
        if (c.strchr(u[0].host, ':') != null) {
            const e = escape(u[0].host, SUBDELIMS ++ ":");
            c.g_string_append_printf(s, "[%s]", e);
            c.g_free(e);
        } else {
            const e = escape(u[0].host, SUBDELIMS);
            _ = c.g_string_append(s, e);
            c.g_free(e);
        }
    }
    if (u[0].port != NO_PORT) c.g_string_append_printf(s, ":%u", u[0].port);
    if (u[0].path != null) {
        const e = gst_uri_get_path_string(u);
        _ = c.g_string_append(s, e);
        c.g_free(e);
    }
    if (u[0].query != null) {
        const e = if (keys != null) gst_uri_get_query_string_ordered(u, keys) else gst_uri_get_query_string(u);
        if (e != null) {
            _ = c.g_string_append(s, "?");
            _ = c.g_string_append(s, e);
            c.g_free(e);
        }
    }
    if (u[0].fragment != null) {
        const e = escape(u[0].fragment, IN_PATH ++ "?");
        c.g_string_append_printf(s, "#%s", e);
        c.g_free(e);
    }
    return c.g_string_free(s, 0);
}

pub export fn gst_uri_to_string(u: [*c]const Uri) [*c]u8 {
    return gst_uri_to_string_with_keys(u, null);
}

pub export fn gst_uri_is_normalized(u: [*c]const Uri) c.gboolean {
    if (u == null) return 1;
    if (!check.that(isUri(u), "gst_uri_is_normalized", "GST_IS_URI (uri)")) return 0;
    if (firstUpper(u[0].scheme) != null or firstUpper(u[0].host) != null) return 0;
    const n = removeDots(u[0].path);
    defer c.g_list_free_full(n, c.g_free);
    return @intFromBool(compareLists(n, u[0].path) == 0);
}

fn writable(comptime f: []const u8, u: [*c]const Uri) bool {
    return check.that(isUri(u) and gst_uri_is_writable(u) != 0, f, "GST_IS_URI (uri) && gst_uri_is_writable (uri)");
}

pub export fn gst_uri_normalize(u: [*c]Uri) c.gboolean {
    if (!writable("gst_uri_normalize", u)) return 0;
    const a = lowercase(u[0].scheme);
    const b = lowercase(u[0].host);
    const d = normalizePath(@ptrCast(&u[0].path));
    return @intFromBool(a or b or d);
}

fn setStr(slot: *[*c]u8, v: [*c]const u8) void {
    if (slot.* == v) return;
    c.g_free(slot.*);
    slot.* = c.g_strdup(v);
}

pub export fn gst_uri_get_scheme(u: [*c]const Uri) [*c]const u8 {
    if (!check.that(u == null or isUri(u), "gst_uri_get_scheme", "uri == NULL || GST_IS_URI (uri)")) return null;
    return if (u != null) u[0].scheme else null;
}

pub export fn gst_uri_set_scheme(u: [*c]Uri, v: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(v == null);
    if (!writable("gst_uri_set_scheme", u)) return 0;
    setStr(@ptrCast(&u[0].scheme), v);
    return 1;
}

pub export fn gst_uri_get_userinfo(u: [*c]const Uri) [*c]const u8 {
    if (!check.that(u == null or isUri(u), "gst_uri_get_userinfo", "uri == NULL || GST_IS_URI (uri)")) return null;
    return if (u != null) u[0].userinfo else null;
}

pub export fn gst_uri_set_userinfo(u: [*c]Uri, v: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(v == null);
    if (!writable("gst_uri_set_userinfo", u)) return 0;
    setStr(@ptrCast(&u[0].userinfo), v);
    return 1;
}

pub export fn gst_uri_get_host(u: [*c]const Uri) [*c]const u8 {
    if (!check.that(u == null or isUri(u), "gst_uri_get_host", "uri == NULL || GST_IS_URI (uri)")) return null;
    return if (u != null) u[0].host else null;
}

pub export fn gst_uri_set_host(u: [*c]Uri, v: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(v == null);
    if (!writable("gst_uri_set_host", u)) return 0;
    setStr(@ptrCast(&u[0].host), v);
    return 1;
}

pub export fn gst_uri_get_port(u: [*c]const Uri) c.guint {
    if (!check.that(u == null or isUri(u), "gst_uri_get_port", "uri == NULL || GST_IS_URI (uri)")) return NO_PORT;
    return if (u != null) u[0].port else NO_PORT;
}

pub export fn gst_uri_set_port(u: [*c]Uri, port: c.guint) c.gboolean {
    if (u == null) return @intFromBool(port == NO_PORT);
    if (!writable("gst_uri_set_port", u)) return 0;
    u[0].port = port;
    return 1;
}

fn joinPath(u: [*c]const Uri, escaped: bool) [*c]u8 {
    const s = c.g_string_new(null);
    var sep: [*c]const u8 = "";
    var l = u[0].path;
    while (l) |n| : (l = n.next) {
        _ = c.g_string_append(s, sep);
        if (n.data != null) {
            if (escaped) {
                const e = escape(@ptrCast(n.data), IN_PATH_ELEMENT);
                _ = c.g_string_append(s, e);
                c.g_free(e);
            } else _ = c.g_string_append(s, @ptrCast(n.data));
        }
        sep = "/";
    }
    return c.g_string_free(s, 0);
}

pub export fn gst_uri_get_path(u: [*c]const Uri) [*c]u8 {
    if (u == null) return null;
    if (!check.that(isUri(u), "gst_uri_get_path", "GST_IS_URI (uri)")) return null;
    if (u[0].path == null) return null;
    return joinPath(u, false);
}

pub export fn gst_uri_set_path(u: [*c]Uri, path: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(path == null);
    if (!writable("gst_uri_set_path", u)) return 0;
    c.g_list_free_full(u[0].path, c.g_free);
    u[0].path = toList(path, "/", false, false);
    return 1;
}

pub export fn gst_uri_get_path_string(u: [*c]const Uri) [*c]u8 {
    if (u == null) return null;
    if (!check.that(isUri(u), "gst_uri_get_path_string", "GST_IS_URI (uri)")) return null;
    if (u[0].path == null) return null;
    return joinPath(u, true);
}

pub export fn gst_uri_set_path_string(u: [*c]Uri, path: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(path == null);
    if (!writable("gst_uri_set_path_string", u)) return 0;
    c.g_list_free_full(u[0].path, c.g_free);
    u[0].path = toList(path, "/", false, true);
    return 1;
}

pub export fn gst_uri_get_path_segments(u: [*c]const Uri) List {
    if (!check.that(u == null or isUri(u), "gst_uri_get_path_segments", "uri == NULL || GST_IS_URI (uri)")) return null;
    return if (u != null) dupList(u[0].path) else null;
}

pub export fn gst_uri_set_path_segments(u: [*c]Uri, segments: List) c.gboolean {
    if (!check.that(u == null or isUri(u), "gst_uri_set_path_segments", "uri == NULL || GST_IS_URI (uri)")) return 0;
    if (u == null) {
        if (segments != null) c.g_list_free_full(segments, c.g_free);
        return @intFromBool(segments == null);
    }
    if (!check.that(gst_uri_is_writable(u) != 0, "gst_uri_set_path_segments", "gst_uri_is_writable (uri)")) return 0;
    c.g_list_free_full(u[0].path, c.g_free);
    u[0].path = segments;
    return 1;
}

fn dropTrailingEmpty(u: [*c]Uri) void {
    const last = c.g_list_last(u[0].path) orelse return;
    if (last.*.data == null) u[0].path = c.g_list_delete_link(u[0].path, last);
}

pub export fn gst_uri_append_path(u: [*c]Uri, rel: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(rel == null);
    if (!writable("gst_uri_append_path", u)) return 0;
    if (rel == null) return 1;
    if (u[0].path != null) dropTrailingEmpty(u);
    var l = toList(rel, "/", false, false);
    if (l != null and l.?.data == null) l = c.g_list_delete_link(l, l);
    u[0].path = c.g_list_concat(u[0].path, l);
    return 1;
}

pub export fn gst_uri_append_path_segment(u: [*c]Uri, seg: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(seg == null);
    if (!writable("gst_uri_append_path_segment", u)) return 0;
    if (seg == null) return 1;
    if (u[0].path != null) dropTrailingEmpty(u);
    u[0].path = c.g_list_append(u[0].path, c.g_strdup(seg));
    return 1;
}

fn appendPair(s: *c.GString, sep: [*c]const u8, key: [*c]const u8, value: [*c]const u8) void {
    _ = c.g_string_append(s, sep);
    const k = escapeQuery(key);
    _ = c.g_string_append(s, k);
    c.g_free(k);
    if (value != null) {
        const v = escapeQuery(value);
        c.g_string_append_printf(s, "=%s", v);
        c.g_free(v);
    }
}

pub export fn gst_uri_get_query_string(u: [*c]const Uri) [*c]u8 {
    if (u == null) return null;
    if (!check.that(isUri(u), "gst_uri_get_query_string", "GST_IS_URI (uri)")) return null;
    const q = u[0].query orelse return null;
    const s = c.g_string_new(null);
    var it: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&it, q);
    var k: c.gpointer = null;
    var v: c.gpointer = null;
    var sep: [*c]const u8 = "";
    while (c.g_hash_table_iter_next(&it, &k, &v) != 0) {
        appendPair(s, sep, @ptrCast(k), @ptrCast(v));
        sep = "&";
    }
    return c.g_string_free(s, 0);
}

pub export fn gst_uri_set_query_string(u: [*c]Uri, query: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(query == null);
    if (!writable("gst_uri_set_query_string", u)) return 0;
    if (u[0].query) |q| c.g_hash_table_unref(q);
    u[0].query = toTable(query, "&", "=", true, true);
    return 1;
}

pub export fn gst_uri_get_query_string_ordered(u: [*c]const Uri, keys: ?*const c.GList) [*c]u8 {
    if (u == null) return null;
    if (!check.that(isUri(u), "gst_uri_get_query_string_ordered", "GST_IS_URI (uri)")) return null;
    const q = u[0].query orelse return null;
    var s: ?*c.GString = null;
    var sep: [*c]const u8 = "";
    var l = keys;
    while (l) |n| : (l = n.next) {
        const key: [*c]const u8 = @ptrCast(n.data);
        if (c.g_hash_table_contains(q, key) == 0) continue;
        if (s == null) s = c.g_string_new(null);
        appendPair(s.?, sep, key, @ptrCast(c.g_hash_table_lookup(q, key)));
        sep = "&";
    }
    return if (s) |str| c.g_string_free(str, 0) else null;
}

pub export fn gst_uri_get_query_table(u: [*c]const Uri) ?*c.GHashTable {
    if (u == null) return null;
    if (!check.that(isUri(u), "gst_uri_get_query_table", "GST_IS_URI (uri)")) return null;
    const q = u[0].query orelse return null;
    return c.g_hash_table_ref(q);
}

pub export fn gst_uri_set_query_table(u: [*c]Uri, table: ?*c.GHashTable) c.gboolean {
    if (u == null) return @intFromBool(table == null);
    if (!writable("gst_uri_set_query_table", u)) return 0;
    if (u[0].query == table) return 1;
    const old = u[0].query;
    u[0].query = if (table) |t| c.g_hash_table_ref(t) else null;
    if (old) |o| c.g_hash_table_unref(o);
    return 1;
}

pub export fn gst_uri_set_query_value(u: [*c]Uri, key: [*c]const u8, value: [*c]const u8) c.gboolean {
    if (u == null) return 0;
    if (!writable("gst_uri_set_query_value", u)) return 0;
    if (u[0].query == null) u[0].query = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, c.g_free);
    _ = c.g_hash_table_insert(u[0].query, c.g_strdup(key), c.g_strdup(value));
    return 1;
}

pub export fn gst_uri_remove_query_key(u: [*c]Uri, key: [*c]const u8) c.gboolean {
    if (u == null) return 0;
    if (!writable("gst_uri_remove_query_key", u)) return 0;
    const q = u[0].query orelse return 0;
    const r = c.g_hash_table_remove(q, key);
    if (r != 0 and c.g_hash_table_size(q) == 0) {
        c.g_hash_table_unref(q);
        u[0].query = null;
    }
    return r;
}

pub export fn gst_uri_query_has_key(u: [*c]const Uri, key: [*c]const u8) c.gboolean {
    if (u == null) return 0;
    if (!check.that(isUri(u), "gst_uri_query_has_key", "GST_IS_URI (uri)")) return 0;
    const q = u[0].query orelse return 0;
    return c.g_hash_table_contains(q, key);
}

pub export fn gst_uri_get_query_value(u: [*c]const Uri, key: [*c]const u8) [*c]const u8 {
    if (u == null) return null;
    if (!check.that(isUri(u), "gst_uri_get_query_value", "GST_IS_URI (uri)")) return null;
    const q = u[0].query orelse return null;
    return @ptrCast(c.g_hash_table_lookup(q, key));
}

pub export fn gst_uri_get_query_keys(u: [*c]const Uri) List {
    if (u == null) return null;
    if (!check.that(isUri(u), "gst_uri_get_query_keys", "GST_IS_URI (uri)")) return null;
    const q = u[0].query orelse return null;
    return c.g_hash_table_get_keys(q);
}

pub export fn gst_uri_get_fragment(u: [*c]const Uri) [*c]const u8 {
    if (!check.that(u == null or isUri(u), "gst_uri_get_fragment", "uri == NULL || GST_IS_URI (uri)")) return null;
    return if (u != null) u[0].fragment else null;
}

pub export fn gst_uri_set_fragment(u: [*c]Uri, v: [*c]const u8) c.gboolean {
    if (u == null) return @intFromBool(v == null);
    if (!writable("gst_uri_set_fragment", u)) return 0;
    setStr(@ptrCast(&u[0].fragment), v);
    return 1;
}

pub export fn gst_uri_get_media_fragment_table(u: [*c]const Uri) ?*c.GHashTable {
    if (!check.that(u == null or isUri(u), "gst_uri_get_media_fragment_table", "uri == NULL || GST_IS_URI (uri)")) return null;
    if (u[0].fragment == null) return null;
    return toTable(u[0].fragment, "&", "=", true, true);
}

pub export fn gst_uri_copy(u: [*c]const Uri) [*c]Uri {
    return @ptrCast(mini.gst_mini_object_copy(@ptrCast(u)));
}

pub export fn gst_uri_ref(u: [*c]Uri) [*c]Uri {
    return @ptrCast(mini.gst_mini_object_ref(@ptrCast(u)));
}

pub export fn gst_uri_unref(u: [*c]Uri) void {
    mini.gst_mini_object_unref(@ptrCast(u));
}

pub export fn gst_clear_uri(slot: [*c][*c]Uri) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}
