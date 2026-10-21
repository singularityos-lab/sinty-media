const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const factory = @import("elementfactory.zig");
const feature = @import("pluginfeature.zig");
const preset = @import("preset.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Element = c.GstElement;
const Bin = c.GstBin;
const Caps = c.GstCaps;
const alloc = std.heap.c_allocator;

pub const Context = extern struct {
    missing_elements: ?*c.GList,

    pub const Header = c.struct__GstParseContext;
};

var context_once: gtype.Once = .{};

fn tr(s: [*c]const u8) [*c]const u8 {
    return c.g_dgettext("gstreamer-1.0", s);
}

pub export fn gst_parse_error_quark() c.GQuark {
    const S = struct {
        var q: c.GQuark = 0;
    };
    if (S.q == 0) S.q = c.g_quark_from_static_string("gst_parse_error");
    return S.q;
}

pub export fn gst_parse_context_get_type() c.GType {
    return context_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstParseContext", @ptrCast(&gst_parse_context_copy), @ptrCast(&gst_parse_context_free));
        }
    }.f);
}

pub export fn gst_parse_context_new() [*c]Context {
    const ctx: [*c]Context = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Context))));
    ctx[0].missing_elements = null;
    return ctx;
}

pub export fn gst_parse_context_copy(ctx: [*c]const Context) [*c]Context {
    const r = gst_parse_context_new();
    if (ctx != null) {
        var q = std.mem.zeroes(c.GQueue);
        var l = ctx[0].missing_elements;
        while (l) |n| : (l = n.next) c.g_queue_push_tail(&q, c.g_strdup(@ptrCast(n.data)));
        r[0].missing_elements = q.head;
    }
    return r;
}

pub export fn gst_parse_context_free(ctx: [*c]Context) void {
    if (ctx == null) return;
    c.g_list_free_full(ctx[0].missing_elements, c.g_free);
    c.g_free(ctx);
}

pub export fn gst_parse_context_get_missing_elements(ctx: [*c]Context) [*c][*c]u8 {
    if (!check.that(ctx != null, "gst_parse_context_get_missing_elements", "context != NULL")) return null;
    const len = c.g_list_length(ctx[0].missing_elements);
    if (len == 0) return null;
    const arr: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc((len + 1) * @sizeOf([*c]u8))));
    var i: usize = 0;
    var l = ctx[0].missing_elements;
    while (l) |n| : (l = n.next) {
        arr[i] = c.g_strdup(@ptrCast(n.data));
        i += 1;
    }
    arr[i] = null;
    return arr;
}

const Kind = enum { assignment, preset, padref, ref, binref, identifier, link, link_all, url, op, eof };

const Token = struct {
    kind: Kind,
    text: [*c]u8 = null,
    ch: u8 = 0,
};

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == 0x0b or ch == 0x0c or ch == '\r';
}

fn identStart(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn identChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '%' or ch == ':';
}

const Lexer = struct {
    s: []const u8,
    i: usize = 0,

    fn at(l: *const Lexer, k: usize) u8 {
        return if (k < l.s.len) l.s[k] else 0;
    }

    fn ident(l: *const Lexer, k: usize) usize {
        if (!identStart(l.at(k))) return 0;
        var j = k + 1;
        while (identChar(l.at(j))) j += 1;
        return j - k;
    }

    fn charRun(l: *const Lexer, k: usize) usize {
        var j = k;
        while (j < l.s.len) {
            if (l.s[j] == '\\' and j + 1 < l.s.len and l.s[j + 1] != '\n') {
                j += 2;
            } else if (!isSpace(l.s[j])) {
                j += 1;
            } else break;
        }
        return j - k;
    }

    fn quoted(l: *const Lexer, k: usize, q: u8) usize {
        if (l.at(k) != q) return 0;
        var best: usize = 0;
        var j = k + 1;
        while (j < l.s.len) : (j += 1) {
            if (l.s[j] != q) continue;
            best = j + 1 - k;
            if (l.s[j - 1] != '\\' or j - 1 == k) break;
        }
        return best;
    }

    fn string(l: *const Lexer, k: usize) usize {
        return @max(l.charRun(k), @max(l.quoted(k, '"'), l.quoted(k, '\'')));
    }

    fn assign(l: *const Lexer, k: usize) usize {
        var j = k;
        while (isSpace(l.at(j))) j += 1;
        if (l.at(j) != '=') return 0;
        j += 1;
        while (isSpace(l.at(j))) j += 1;
        return j - k;
    }

    fn assignment(l: *const Lexer, k: usize) usize {
        const a = l.ident(k);
        if (a == 0) return 0;
        const b = l.assign(k + a);
        if (b == 0) return 0;
        const s = l.string(k + a + b);
        if (s == 0) return 0;
        return a + b + s;
    }

    fn presetTok(l: *const Lexer, k: usize) usize {
        if (!std.mem.startsWith(u8, l.s[k..], "@preset")) return 0;
        const b = l.assign(k + 7);
        if (b == 0) return 0;
        const s = l.string(k + 7 + b);
        if (s == 0) return 0;
        return 7 + b + s;
    }

    fn padref(l: *const Lexer, k: usize) usize {
        if (l.at(k) != '.') return 0;
        const a = l.ident(k + 1);
        return if (a == 0) 0 else a + 1;
    }

    fn ref(l: *const Lexer, k: usize) usize {
        const a = l.ident(k);
        if (a == 0 or l.at(k + a) != '.') return 0;
        return a + 1 + l.ident(k + a + 1);
    }

    fn binref(l: *const Lexer, k: usize) usize {
        const a = l.ident(k);
        if (a == 0) return 0;
        var j = k + a;
        while (isSpace(l.at(j))) j += 1;
        if (l.at(j) != '.') return 0;
        j += 1;
        while (isSpace(l.at(j))) j += 1;
        if (l.at(j) != '(') return 0;
        return j + 1 - k;
    }

    fn mimeChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '-';
    }

    fn mimetype(l: *const Lexer, k: usize) usize {
        var j = k;
        while (mimeChar(l.at(j))) j += 1;
        if (j == k or l.at(j) != '/') return 0;
        const slash = j;
        j += 1;
        while (mimeChar(l.at(j))) j += 1;
        if (j == slash + 1) return 0;
        return j - k;
    }

    fn linkTok(l: *const Lexer, k: usize) usize {
        const first = l.at(k);
        if (first != '!' and first != ':') return 0;
        var j = k + 1;
        while (isSpace(l.at(j))) j += 1;
        const mt = l.mimetype(j);
        if (mt == 0) return 1;
        var p = j + mt;
        var colon: ?usize = null;
        while (p < l.s.len) {
            const ch = l.s[p];
            if (ch == '\\' and p + 1 < l.s.len and l.s[p + 1] != '\n') {
                p += 2;
            } else if (ch == '!') {
                return p + 1 - k;
            } else if (ch == ';') {
                if (l.s[p - 1] == ',') {
                    p += 1;
                    continue;
                }
                var m = p + 1;
                while (isSpace(l.at(m))) m += 1;
                const mt2 = l.mimetype(m);
                if (mt2 == 0) break;
                p = m + mt2;
            } else {
                if (ch == ':') colon = p;
                p += 1;
            }
        }
        if (colon) |cl| return cl + 1 - k;
        return 1;
    }

    fn protocol(l: *const Lexer, k: usize) usize {
        if (!std.ascii.isAlphabetic(l.at(k))) return 0;
        var j = k + 1;
        while (true) {
            const ch = l.at(j);
            if (std.ascii.isAlphanumeric(ch) or ch == '+' or ch == ',' or ch == '-' or ch == '.') j += 1 else break;
        }
        return j - k;
    }

    fn url(l: *const Lexer, k: usize) usize {
        var best: usize = 0;
        const p = l.protocol(k);
        if (p > 0 and std.mem.startsWith(u8, l.s[k + p ..], "://")) {
            best = p + 3;
            best = @max(best, p + 3 + l.string(k + p + 3));
        }
        var j = k;
        if (std.mem.indexOfScalar(u8, "\".{identifr}", l.at(j)) != null and l.at(j) != 0 and l.at(j + 1) == '/') j += 1;
        if (l.at(j) == '/') {
            const s = l.string(j + 1);
            if (s > 0) best = @max(best, j + 1 + s - k);
        }
        if (l.at(k) == '/') {
            const s = l.string(k + 1);
            if (s > 0) best = @max(best, 1 + s);
        }
        return best;
    }

    fn next(l: *Lexer) Token {
        while (l.i < l.s.len and isSpace(l.s[l.i])) l.i += 1;
        if (l.i >= l.s.len) return .{ .kind = .eof };
        const k = l.i;
        const cands = [_]struct { Kind, usize }{
            .{ .assignment, l.assignment(k) },
            .{ .preset, l.presetTok(k) },
            .{ .padref, l.padref(k) },
            .{ .ref, l.ref(k) },
            .{ .binref, l.binref(k) },
            .{ .identifier, l.ident(k) },
            .{ .link, l.linkTok(k) },
            .{ .url, l.url(k) },
            .{ .op, if (std.mem.indexOfScalar(u8, "(){}.!:,;=", l.s[k]) != null) @as(usize, 1) else 0 },
        };
        var kind: Kind = .op;
        var len: usize = 0;
        for (cands) |cd| if (cd[1] > len) {
            kind = cd[0];
            len = cd[1];
        };
        if (len == 0) {
            l.i += 1;
            return .{ .kind = .op, .ch = l.s[k] };
        }
        l.i += len;
        const text = l.s[k .. k + len];
        return switch (kind) {
            .assignment, .ref, .identifier => .{ .kind = kind, .text = c.g_strndup(text.ptr, text.len) },
            .preset => blk: {
                const eq = std.mem.indexOfScalar(u8, text, '=').?;
                break :blk .{ .kind = .preset, .text = c.g_strndup(text.ptr + eq + 1, text.len - eq - 1) };
            },
            .padref => .{ .kind = .padref, .text = c.g_strndup(text.ptr + 1, text.len - 1) },
            .binref => blk: {
                var e: usize = 0;
                while (!isSpace(text[e]) and text[e] != '.') e += 1;
                break :blk .{ .kind = .binref, .text = c.g_strndup(text.ptr, e) };
            },
            .link => linkToken(text),
            .url => blk: {
                const u = c.g_strndup(text.ptr, text.len);
                unescape(u);
                break :blk .{ .kind = .url, .text = u };
            },
            else => .{ .kind = .op, .ch = text[0] },
        };
    }
};

fn linkToken(text: []const u8) Token {
    var all = text[0] == ':';
    if (text.len == 1) return .{ .kind = if (all) .link_all else .link };
    var b: usize = 1;
    while (isSpace(text[b])) b += 1;
    var e = text.len - 1;
    if (text[e] == ':') all = true;
    while (e > b and isSpace(text[e - 1])) e -= 1;
    return .{ .kind = if (all) .link_all else .link, .text = c.g_strndup(text.ptr + b, e - b) };
}

pub fn unescape(str: [*c]u8) void {
    var w: usize = 0;
    var r: usize = 0;
    var in_quotes = false;
    while (str[r] != 0) {
        if (str[r] == '\\' and !in_quotes) {
            r += 1;
            if (str[r] == 0) break;
        } else if (str[r] == '"' and (!in_quotes or str[r - 1] != '\\')) {
            in_quotes = !in_quotes;
        }
        str[w] = str[r];
        w += 1;
        r += 1;
    }
    str[w] = 0;
}

fn asciiString(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-+/:.", ch) != null;
}

fn unwrap(s: [*c]const u8) [*c]u8 {
    if (s == null) return null;
    const ret = c.g_strdup(s);
    var r: usize = 0;
    var w: usize = 0;
    while (ret[r] != 0) {
        if (asciiString(ret[r])) {
            ret[w] = ret[r];
            w += 1;
            r += 1;
        } else if (ret[r] == '\\') {
            r += 1;
            if (ret[r] >= '0' and ret[r] <= '3') {
                if (ret[r + 1] < '0' or ret[r + 1] > '7' or ret[r + 2] < '0' or ret[r + 2] > '7') {
                    c.g_free(ret);
                    return null;
                }
                ret[w] = ((ret[r] - '0') << 6) + ((ret[r + 1] - '0') << 3) + (ret[r + 2] - '0');
                w += 1;
                r += 3;
            } else {
                if (ret[r] == 0) {
                    c.g_free(ret);
                    return null;
                }
                ret[w] = ret[r];
                w += 1;
                r += 1;
            }
        } else {
            ret[w] = ret[r];
            w += 1;
            r += 1;
        }
    }
    ret[w] = 0;
    return ret;
}

const Ref = struct {
    element: [*c]Element = null,
    name: [*c]u8 = null,
    pads: std.ArrayListUnmanaged([*c]u8) = .empty,

    fn free(r: *Ref) void {
        if (r.element != null) c.gst_object_unref(r.element);
        c.g_free(r.name);
        for (r.pads.items) |p| c.g_free(p);
        r.pads.deinit(alloc);
        r.* = .{};
    }
};

const Link = struct {
    src: Ref = .{},
    sink: Ref = .{},
    caps: [*c]Caps = null,
    all: bool = false,

    fn free(l: *Link) void {
        l.src.free();
        l.sink.free();
        if (l.caps != null) c.gst_caps_unref(l.caps);
        alloc.destroy(l);
    }
};

const Chain = struct {
    elements: std.ArrayListUnmanaged([*c]Element) = .empty,
    first: Ref = .{},
    last: Ref = .{},

    fn free(ch: *Chain) void {
        ch.first.free();
        ch.last.free();
        for (ch.elements.items) |e| if (e != null) c.gst_object_unref(e);
        ch.elements.deinit(alloc);
        alloc.destroy(ch);
    }
};

const Receiver = struct {
    lock: c.GMutex = std.mem.zeroes(c.GMutex),
    reason: [*c]u8 = null,
    refs: std.atomic.Value(u32) = .init(1),

    fn unref(p: c.gpointer) callconv(.c) void {
        const r: *Receiver = @ptrCast(@alignCast(p));
        if (r.refs.fetchSub(1, .acq_rel) != 1) return;
        c.g_mutex_clear(&r.lock);
        c.g_free(r.reason);
        alloc.destroy(r);
    }
};

const Graph = struct {
    err: [*c][*c]c.GError,
    ctx: [*c]Context,
    flags: c.GstParseFlags,
    links: std.ArrayListUnmanaged(*Link) = .empty,
    receiver: ?*Receiver = null,

    fn fail(g: *Graph, code: c.gint, comptime fmt: [*c]const u8, args: anytype) void {
        if (g.err == null or g.err.* != null) return;
        @call(.auto, c.g_set_error, .{ g.err, gst_parse_error_quark(), code, tr(fmt) } ++ args);
        g.appendReason();
    }

    fn appendReason(g: *Graph) void {
        const r = g.receiver orelse return;
        const e = g.err.*;
        c.g_mutex_lock(&r.lock);
        defer c.g_mutex_unlock(&r.lock);
        if (r.reason == null) return;
        const msg = c.g_strdup_printf("%s -- %s", e[0].message, r.reason);
        c.g_free(e[0].message);
        e[0].message = msg;
    }

    fn missing(g: *Graph, name: [*c]const u8) void {
        if (g.ctx != null) g.ctx[0].missing_elements = c.g_list_append(g.ctx[0].missing_elements, c.g_strdup(name));
    }

    fn addLink(g: *Graph, l: *Link) void {
        if (l.src.element == null and l.src.name == null) {
            g.fail(c.GST_PARSE_ERROR_LINK, "link has no source [sink=%s@%p]", .{ if (l.sink.name != null) l.sink.name else @as([*c]const u8, ""), l.sink.element });
            l.free();
        } else if (l.sink.element == null and l.sink.name == null) {
            g.fail(c.GST_PARSE_ERROR_LINK, "link has no sink [source=%s@%p]", .{ if (l.src.name != null) l.src.name else @as([*c]const u8, ""), l.src.element });
            l.free();
        } else g.links.append(alloc, l) catch {};
    }
};

fn splitAssignment(value: [*c]u8) [*c]u8 {
    var p = value;
    while (!isSpace(p[0]) and p[0] != '=') p += 1;
    if (p[0] == '=') {
        p[0] = 0;
    } else {
        p[0] = 0;
        p += 1;
        while (isSpace(p[0])) p += 1;
    }
    p += 1;
    while (isSpace(p[0])) p += 1;
    const len = c.strlen(p);
    if (p[0] == '"' and len > 0 and p[len - 1] == '"') {
        p += 1;
        p[len - 2] = 0;
    }
    unescape(p);
    return p;
}

fn collect(pspec: [*c]c.GParamSpec, value: [*c]const u8, v: *c.GValue) bool {
    _ = c.g_value_init(v, pspec[0].value_type);
    if (c.gst_value_deserialize_with_pspec(v, value, pspec) != 0) return true;
    if (c.g_type_is_a(pspec[0].value_type, c.gst_element_get_type()) != 0) {
        const b = gst_parse_bin_from_description_full(value, 1, null, c.GST_PARSE_FLAG_NO_SINGLE_ELEMENT_BINS | c.GST_PARSE_FLAG_PLACE_IN_BIN, null);
        if (b != null) {
            c.g_value_set_object(v, b);
            return true;
        }
    }
    return false;
}

fn applyPreset(value: [*c]u8, e: [*c]Element, g: *Graph) void {
    if (e == null) return;
    if (!gtype.instanceOf(e, preset.gst_preset_get_type())) {
        g.fail(c.GST_PARSE_ERROR_COULD_NOT_SET_PROPERTY, "Element \"%s\" is not a GstPreset", .{e[0].object.name});
        return;
    }
    if (value == null or value[0] == 0) return;
    unescape(value);
    if (preset.gst_preset_load_preset(@ptrCast(e), value) == 0)
        g.fail(c.GST_PARSE_ERROR_COULD_NOT_SET_PROPERTY, "could not set preset \"%s\" in element \"%s\"", .{ value, e[0].object.name });
}

const DelayedSet = struct {
    name: [*c]u8,
    value: [*c]u8,
    signal: c.gulong = 0,

    fn free(data: c.gpointer, _: ?*c.GClosure) callconv(.c) void {
        const d: *DelayedSet = @ptrCast(@alignCast(data));
        c.g_free(d.name);
        c.g_free(d.value);
        alloc.destroy(d);
    }
};

fn isProxy(o: anytype) bool {
    return gtype.instanceOf(o, c.gst_child_proxy_get_type());
}

fn addDelayedSet(proxy: ?*c.GstChildProxy, name: [*c]const u8, value: [*c]const u8) void {
    const d = alloc.create(DelayedSet) catch return;
    d.* = .{ .name = c.g_strdup(name), .value = c.g_strdup(value) };
    d.signal = c.g_signal_connect_data(proxy, "child-added", @ptrCast(&newChild), d, DelayedSet.free, 0);
    const names = c.g_strsplit(name, "::", -1);
    defer c.g_strfreev(names);
    var cur: usize = 0;
    var parent = c.gst_child_proxy_get_child_by_name(proxy, names[cur]);
    cur += 1;
    while (parent != null and names[cur] != null) {
        if (!isProxy(parent)) break;
        const child = c.gst_child_proxy_get_child_by_name(@ptrCast(parent), names[cur]);
        if (child == null and names[cur + 1] != null) {
            const sub = c.g_strjoinv("::", names + cur);
            addDelayedSet(@ptrCast(parent), sub, value);
            c.g_free(sub);
        }
        c.gst_object_unref(parent);
        parent = child;
        cur += 1;
    }
    if (parent != null) c.gst_object_unref(parent);
}

fn splitChildren(name: [*c]const u8, children: *[*c]u8, property: *[*c]u8) bool {
    const prop = c.g_strrstr(name, "::");
    if (prop == null) return false;
    property.* = c.g_strdup(prop + 2);
    children.* = c.g_strndup(name, c.strlen(name) - c.strlen(prop));
    return true;
}

fn newChild(proxy: ?*c.GstChildProxy, _: [*c]c.GObject, name: [*c]const u8, data: c.gpointer) callconv(.c) void {
    const set: *DelayedSet = @ptrCast(@alignCast(data));
    var target: [*c]c.GObject = null;
    var pspec: [*c]c.GParamSpec = null;
    var v = std.mem.zeroes(c.GValue);
    defer {
        if (v.g_type != 0) c.g_value_unset(&v);
        if (target != null) c.gst_object_unref(target);
    }
    if (c.gst_child_proxy_lookup(proxy, set.name, &target, &pspec) != 0) {
        const ok = collect(pspec, set.value, &v);
        c.g_signal_handler_disconnect(proxy, set.signal);
        if (ok) c.g_object_set_property(target, pspec[0].name, &v);
        return;
    }
    const len = c.strlen(name);
    if (c.strlen(set.name) > len + 2 and c.strncmp(set.name, name, len) == 0 and c.strncmp(set.name + len, "::", 2) == 0) {
        var children: [*c]u8 = null;
        var prop: [*c]u8 = null;
        if (!splitChildren(set.name, &children, &prop)) return;
        const child = c.gst_child_proxy_get_child_by_name_recurse(proxy, children);
        c.g_free(children);
        c.g_free(prop);
        if (child == null) {
            addDelayedSet(proxy, set.name, set.value);
        } else {
            c.gst_object_unref(child);
            const text = c.g_strdup(tr("No such property."));
            const dbg = c.g_strdup_printf(tr("no property \"%s\" in element \"%s\""), set.name, @as([*c]Element, @ptrCast(@alignCast(proxy)))[0].object.name);
            c.gst_element_message_full(@ptrCast(@alignCast(proxy)), c.GST_MESSAGE_WARNING, c.gst_parse_error_quark(), c.GST_PARSE_ERROR_NO_SUCH_PROPERTY, text, dbg, "../gst/parse/grammar.y", "gst_parse_new_child", 381);
        }
    }
}

const Proxied = struct { name: [*c]u8, value: [*c]u8 };

fn makeElement(g: *Graph, name: [*c]const u8, values: []const [*c]u8, presets: []const [*c]u8) [*c]Element {
    const f = factory.gst_element_factory_find(name);
    if (f == null) {
        g.fail(c.GST_PARSE_ERROR_NO_SUCH_ELEMENT, "no element \"%s\"", .{name});
        return null;
    }
    const loaded = factory.of(feature.gst_plugin_feature_load(@ptrCast(f)));
    c.gst_object_unref(f);
    const et = factory.gst_element_factory_get_element_type(loaded);
    const klass: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(et)));
    defer c.g_type_class_unref(klass);
    defer c.gst_object_unref(loaded);
    const proxy = c.g_type_is_a(et, c.gst_child_proxy_get_type()) != 0;
    var names: std.ArrayListUnmanaged([*c]const u8) = .empty;
    defer names.deinit(alloc);
    var vals: std.ArrayListUnmanaged(c.GValue) = .empty;
    defer {
        for (vals.items) |*v| c.g_value_unset(v);
        vals.deinit(alloc);
    }
    var proxied: std.ArrayListUnmanaged(Proxied) = .empty;
    defer proxied.deinit(alloc);
    for (values) |raw| {
        const value = splitAssignment(raw);
        if (proxy and c.strstr(raw, "::") != null) {
            proxied.insert(alloc, 0, .{ .name = raw, .value = value }) catch {};
            continue;
        }
        const pspec = c.g_object_class_find_property(klass, raw);
        if (pspec == null) {
            g.fail(c.GST_PARSE_ERROR_NO_SUCH_PROPERTY, "no property \"%s\" in element \"%s\"", .{ raw, name });
            return null;
        }
        var v = std.mem.zeroes(c.GValue);
        if (!collect(pspec, value, &v)) {
            g.fail(c.GST_PARSE_ERROR_COULD_NOT_SET_PROPERTY, "could not set property \"%s\" in element \"%s\" to \"%s\"", .{ raw, name, value });
            c.g_value_unset(&v);
            return null;
        }
        names.append(alloc, raw) catch {};
        vals.append(alloc, v) catch {};
    }
    const ret = factory.gst_element_factory_create_with_properties(loaded, @intCast(names.items.len), @ptrCast(names.items.ptr), vals.items.ptr);
    for (proxied.items) |pp| {
        var target: [*c]c.GObject = null;
        var pspec: [*c]c.GParamSpec = null;
        if (c.gst_child_proxy_lookup(@ptrCast(ret), pp.name, &target, &pspec) == 0) {
            var children: [*c]u8 = null;
            var property: [*c]u8 = null;
            if (!splitChildren(pp.name, &children, &property)) continue;
            target = c.gst_child_proxy_get_child_by_name_recurse(@ptrCast(ret), children);
            c.g_free(children);
            c.g_free(property);
            if (target == null) {
                addDelayedSet(@ptrCast(ret), pp.name, pp.value);
            } else {
                c.gst_object_unref(target);
                g.fail(c.GST_PARSE_ERROR_NO_SUCH_PROPERTY, "no property \"%s\" in element \"%s\"", .{ pp.name, ret[0].object.name });
                return ret;
            }
        } else {
            var v = std.mem.zeroes(c.GValue);
            if (!collect(pspec, pp.value, &v)) {
                g.fail(c.GST_PARSE_ERROR_COULD_NOT_SET_PROPERTY, "could not set property \"%s\" in child of element \"%s\" to \"%s\"", .{ pp.name, name, pp.value });
                c.g_value_unset(&v);
                return ret;
            }
            c.g_object_set_property(target, pspec[0].name, &v);
            c.g_value_unset(&v);
            c.gst_object_unref(target);
        }
    }
    for (presets) |p| applyPreset(p, ret, g);
    return ret;
}

fn findChild(proxy: ?*c.GstChildProxy, name: [*c]const u8) bool {
    var obj: [*c]c.GObject = @ptrCast(@alignCast(c.g_object_ref(proxy)));
    const names = c.g_strsplit(name, "::", -1);
    defer c.g_strfreev(names);
    var cur: usize = 0;
    while (names[cur + 1] != null) {
        if (!isProxy(obj)) break;
        const next = c.gst_child_proxy_get_child_by_name(@ptrCast(obj), names[cur]);
        if (next == null) break;
        c.gst_object_unref(obj);
        obj = next;
        cur += 1;
    }
    c.gst_object_unref(obj);
    return names[cur + 1] == null;
}

fn setOn(value: [*c]u8, e: [*c]Element, g: *Graph) void {
    defer c.g_free(value);
    if (e == null) return;
    const pos = splitAssignment(value);
    var pspec: [*c]c.GParamSpec = null;
    var target: [*c]c.GObject = null;
    var v = std.mem.zeroes(c.GValue);
    defer {
        if (v.g_type != 0) c.g_value_unset(&v);
        if (target != null) c.gst_object_unref(target);
    }
    if (isProxy(e) and c.strstr(value, "::") != null) {
        if (c.gst_child_proxy_lookup(@ptrCast(e), value, &target, &pspec) == 0) {
            if (!findChild(@ptrCast(e), value)) {
                addDelayedSet(@ptrCast(e), value, pos);
            } else {
                g.fail(c.GST_PARSE_ERROR_COULD_NOT_SET_PROPERTY, "could not set property \"%s\" in element \"%s\" to \"%s\"", .{ value, e[0].object.name, pos });
                return;
            }
        }
    } else {
        pspec = c.g_object_class_find_property(gtype.classPeek(c.GObjectClass, e), value);
        if (pspec != null) {
            target = @ptrCast(@alignCast(c.g_object_ref(e)));
        } else g.fail(c.GST_PARSE_ERROR_NO_SUCH_PROPERTY, "no property \"%s\" in element \"%s\"", .{ value, e[0].object.name });
    }
    if (pspec != null and target != null) {
        if (!collect(pspec, pos, &v)) {
            g.fail(c.GST_PARSE_ERROR_COULD_NOT_SET_PROPERTY, "could not set property \"%s\" in element \"%s\" to \"%s\"", .{ value, e[0].object.name, pos });
            return;
        }
        c.g_object_set_property(target, pspec[0].name, &v);
    }
}

const DelayedLink = struct {
    src_pad: [*c]u8,
    sink_pad: [*c]u8,
    sink: [*c]Element,
    caps: [*c]Caps,
    added: c.gulong = 0,
    no_more: c.gulong = 0,
    all: bool,

    fn free(data: c.gpointer, _: ?*c.GClosure) callconv(.c) void {
        const d: *DelayedLink = @ptrCast(@alignCast(data));
        c.g_free(d.src_pad);
        c.g_free(d.sink_pad);
        if (d.caps != null) c.gst_caps_unref(d.caps);
        alloc.destroy(d);
    }
};

fn padDesc(e: [*c]Element, pad: [*c]const u8, buf: []u8) [:0]const u8 {
    const n = e[0].object.name;
    return std.fmt.bufPrintZ(buf, "{s} {s} of {s} named {s}", .{ if (pad != null) "pad" else "some", if (pad != null) std.mem.span(pad) else "pad", std.mem.span(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(e))).g_class.*.g_type)), if (n != null) std.mem.span(n) else "(NULL)" }) catch "";
}

fn noMorePads(src: [*c]Element, data: c.gpointer) callconv(.c) void {
    const d: *DelayedLink = @ptrCast(@alignCast(data));
    if (d.all) return;
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    const dbg = c.g_strdup_printf("failed delayed linking %s to %s", padDesc(src, d.src_pad, &a).ptr, padDesc(d.sink, d.sink_pad, &b).ptr);
    c.gst_element_message_full(src, c.GST_MESSAGE_WARNING, c.gst_parse_error_quark(), c.GST_PARSE_ERROR_DELAYED_LINK, c.g_strdup(tr("Delayed linking failed.")), dbg, "../gst/parse/grammar.y", "gst_parse_no_more_pads", 732);
}

fn foundPad(src: [*c]Element, _: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const d: *DelayedLink = @ptrCast(@alignCast(data));
    if (c.gst_element_link_pads_filtered(src, d.src_pad, d.sink, d.sink_pad, d.caps) == 0) return;
    if (!d.all) {
        c.g_signal_handler_disconnect(src, d.no_more);
        c.g_signal_handler_disconnect(src, d.added);
    }
}

fn delayedLink(src: [*c]Element, src_pad: [*c]const u8, sink: [*c]Element, sink_pad: [*c]const u8, caps: [*c]Caps, all: bool) bool {
    var templs: ?*c.GList = c.gst_element_class_get_pad_template_list(gtype.classPeek(c.GstElementClass, src));
    while (templs) |n| : (templs = n.next) {
        const t: [*c]c.GstPadTemplate = @ptrCast(@alignCast(n.data));
        if (t[0].direction != c.GST_PAD_SRC or t[0].presence != c.GST_PAD_SOMETIMES) continue;
        const d = alloc.create(DelayedLink) catch return false;
        d.* = .{ .src_pad = c.g_strdup(src_pad), .sink = sink, .sink_pad = c.g_strdup(sink_pad), .caps = if (caps != null) c.gst_caps_copy(caps) else null, .all = all };
        d.added = c.g_signal_connect_data(src, "pad-added", @ptrCast(&foundPad), d, DelayedLink.free, 0);
        d.no_more = c.g_signal_connect_data(src, "no-more-pads", @ptrCast(&noMorePads), d, null, 0);
        return true;
    }
    return false;
}

fn canDoCaps(e: [*c]Element, dir: c.GstPadDirection, caps: [*c]Caps) bool {
    const it = if (dir == c.GST_PAD_SRC) c.gst_element_iterate_src_pads(e) else c.gst_element_iterate_sink_pads(e);
    defer c.gst_iterator_free(it);
    var can = false;
    while (!can) {
        var v = std.mem.zeroes(c.GValue);
        switch (c.gst_iterator_next(it, &v)) {
            c.GST_ITERATOR_OK => {
                const p: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&v)));
                var pc = c.gst_pad_get_current_caps(p);
                if (pc == null) pc = c.gst_pad_query_caps(p, null);
                can = c.gst_caps_can_intersect(pc, caps) != 0;
                c.gst_caps_unref(pc);
                c.g_value_unset(&v);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => break,
        }
    }
    return can;
}

fn performLink(l: *Link, g: *Graph) void {
    defer l.free();
    const src = l.src.element;
    const sink = l.sink.element;
    const srcs = l.src.pads.items;
    const sinks = l.sink.pads.items;
    ok: {
        if (srcs.len == 0 or sinks.len == 0) {
            const sp: [*c]const u8 = if (srcs.len > 0) srcs[0] else null;
            const kp: [*c]const u8 = if (sinks.len > 0) sinks[0] else null;
            if (c.gst_element_link_pads_filtered(src, sp, sink, kp, l.caps) != 0) {
                if (!l.all) break :ok;
                while (c.gst_element_link_pads_filtered(src, sp, sink, kp, l.caps) != 0) {}
            }
            if (delayedLink(src, sp, sink, kp, l.caps, l.all) or l.all) break :ok;
            return linkError(l, g);
        }
        if (srcs.len != sinks.len) return linkError(l, g);
        for (srcs, sinks) |sp, kp| {
            if (c.gst_element_link_pads_filtered(src, sp, sink, kp, l.caps) != 0) continue;
            if (delayedLink(src, sp, sink, kp, l.caps, l.all)) continue;
            return linkError(l, g);
        }
    }
}

fn linkError(l: *Link, g: *Graph) void {
    const src = l.src.element;
    const sink = l.sink.element;
    const sn = src[0].object.name;
    const kn = sink[0].object.name;
    if (l.caps == null) return g.fail(c.GST_PARSE_ERROR_LINK, "could not link %s to %s", .{ sn, kn });
    const cs = c.gst_caps_to_string(l.caps);
    defer c.g_free(cs);
    const a = canDoCaps(src, c.GST_PAD_SRC, l.caps);
    const b = canDoCaps(sink, c.GST_PAD_SINK, l.caps);
    if (!a and b) {
        g.fail(c.GST_PARSE_ERROR_LINK, "could not link %s to %s, %s can't handle caps %s", .{ sn, kn, sn, cs });
    } else if (a and !b) {
        g.fail(c.GST_PARSE_ERROR_LINK, "could not link %s to %s, %s can't handle caps %s", .{ sn, kn, kn, cs });
    } else if (!a and !b) {
        g.fail(c.GST_PARSE_ERROR_LINK, "could not link %s to %s, neither element can handle caps %s", .{ sn, kn, cs });
    } else g.fail(c.GST_PARSE_ERROR_LINK, "could not link %s to %s with caps %s", .{ sn, kn, cs });
}

const Abort = error{Abort};

const Parser = struct {
    lx: Lexer,
    tok: Token,
    g: *Graph,

    fn advance(p: *Parser) void {
        p.tok = p.lx.next();
    }

    fn take(p: *Parser) [*c]u8 {
        const t = p.tok.text;
        p.advance();
        return t;
    }

    fn isOp(p: *Parser, ch: u8) bool {
        return p.tok.kind == .op and p.tok.ch == ch;
    }

    fn startsChain(p: *Parser) bool {
        return switch (p.tok.kind) {
            .identifier, .binref, .url, .ref => true,
            .op => p.tok.ch == '(',
            else => false,
        };
    }

    fn pads(p: *Parser, out: *std.ArrayListUnmanaged([*c]u8)) void {
        if (p.tok.kind != .padref) return;
        out.append(alloc, p.take()) catch {};
        p.morePads(out);
    }

    fn morePads(p: *Parser, out: *std.ArrayListUnmanaged([*c]u8)) void {
        while (p.isOp(',')) {
            const save = p.lx;
            p.advance();
            if (p.tok.kind != .identifier) {
                p.lx = save;
                p.tok = .{ .kind = .op, .ch = ',' };
                return;
            }
            out.append(alloc, p.take()) catch {};
        }
    }

    fn elementary(p: *Parser) Abort!*Chain {
        if (p.tok.kind == .binref or p.isOp('(')) return p.bin();
        const name = p.take();
        defer c.g_free(name);
        var values: std.ArrayListUnmanaged([*c]u8) = .empty;
        var presets: std.ArrayListUnmanaged([*c]u8) = .empty;
        defer {
            for (values.items) |v| c.g_free(v);
            values.deinit(alloc);
            for (presets.items) |v| c.g_free(v);
            presets.deinit(alloc);
        }
        while (true) {
            if (p.tok.kind == .assignment) {
                values.append(alloc, p.take()) catch {};
            } else if (p.tok.kind == .preset) {
                presets.append(alloc, p.take()) catch {};
            } else break;
        }
        const ch = alloc.create(Chain) catch return error.Abort;
        ch.* = .{};
        const e = makeElement(p.g, name, values.items, presets.items);
        if (e == null) {
            p.g.missing(name);
        } else {
            ch.first.element = @ptrCast(@alignCast(c.gst_object_ref(e)));
            ch.last.element = @ptrCast(@alignCast(c.gst_object_ref(e)));
            ch.elements.append(alloc, e) catch {};
        }
        return ch;
    }

    fn reference(p: *Parser) Ref {
        var r = Ref{};
        const text = p.take();
        const dot = c.strchr(text, '.');
        dot[0] = 0;
        var tail: std.ArrayListUnmanaged([*c]u8) = .empty;
        p.morePads(&tail);
        if (dot[1] != 0) r.pads.append(alloc, c.g_strdup(dot + 1)) catch {};
        r.pads.appendSlice(alloc, tail.items) catch {};
        tail.deinit(alloc);
        r.name = text;
        return r;
    }

    fn newLink(p: *Parser) *Link {
        const l = alloc.create(Link) catch unreachable;
        l.* = .{ .all = p.tok.kind == .link_all };
        const text = p.take();
        if (text != null) {
            const s = unwrap(text);
            l.caps = c.gst_caps_from_string(s);
            c.g_free(s);
            if (l.caps == null) p.g.fail(c.GST_PARSE_ERROR_LINK, "could not parse caps \"%s\"", .{text});
            c.g_free(text);
        }
        return l;
    }

    fn uriElement(p: *Parser, kind: c.GstURIType, text: [*c]u8) [*c]Element {
        const e = c.gst_element_make_from_uri(kind, text, null, null);
        if (e == null) {
            if (kind == c.GST_URI_SINK)
                p.g.fail(c.GST_PARSE_ERROR_NO_SUCH_ELEMENT, "no sink element for URI \"%s\"", .{text})
            else
                p.g.fail(c.GST_PARSE_ERROR_NO_SUCH_ELEMENT, "no source element for URI \"%s\"", .{text});
        }
        return e;
    }

    fn chain(p: *Parser) Abort!*Chain {
        var cur: *Chain = undefined;
        switch (p.tok.kind) {
            .url => {
                const text = p.take();
                defer c.g_free(text);
                cur = alloc.create(Chain) catch return error.Abort;
                cur.* = .{};
                const e = p.uriElement(c.GST_URI_SRC, text);
                if (e != null) {
                    cur.last.element = @ptrCast(@alignCast(c.gst_object_ref(e)));
                    cur.elements.append(alloc, e) catch {};
                }
            },
            .ref => {
                cur = alloc.create(Chain) catch return error.Abort;
                cur.* = .{};
                cur.last = p.reference();
            },
            else => {
                cur = try p.elementary();
                p.pads(&cur.last.pads);
            },
        }
        while (p.tok.kind == .link or p.tok.kind == .link_all) {
            const l = p.newLink();
            if (p.tok.kind == .url) {
                const text = p.take();
                defer c.g_free(text);
                const e = p.uriElement(c.GST_URI_SINK, text);
                l.sink.element = if (e != null) @ptrCast(@alignCast(c.gst_object_ref(e))) else null;
                l.src = cur.last;
                cur.last = .{};
                p.g.addLink(l);
                if (e != null) cur.elements.append(alloc, e) catch {};
                return cur;
            }
            if (p.tok.kind == .ref) {
                l.sink = p.reference();
                l.src = cur.last;
                cur.last = .{};
                p.g.addLink(l);
                return cur;
            }
            var before: std.ArrayListUnmanaged([*c]u8) = .empty;
            p.pads(&before);
            if (!(p.tok.kind == .identifier or p.tok.kind == .binref or p.isOp('('))) {
                for (before.items) |x| c.g_free(x);
                before.deinit(alloc);
                l.free();
                return error.Abort;
            }
            const next = try p.elementary();
            l.src = cur.last;
            l.sink = next.first;
            before.appendSlice(alloc, l.sink.pads.items) catch {};
            l.sink.pads.deinit(alloc);
            l.sink.pads = before;
            next.first = .{};
            p.g.addLink(l);
            next.first = cur.first;
            cur.first = .{};
            cur.last = .{};
            cur.elements.appendSlice(alloc, next.elements.items) catch {};
            next.elements.deinit(alloc);
            next.elements = cur.elements;
            cur.elements = .empty;
            cur.free();
            cur = next;
            p.pads(&cur.last.pads);
        }
        if (cur.last.name != null) {
            p.g.fail(c.GST_PARSE_ERROR_SYNTAX, "unexpected reference \"%s\" - ignoring", .{cur.last.name});
            c.g_free(cur.last.name);
            cur.last.name = null;
        }
        if (cur.last.pads.items.len > 0) {
            p.g.fail(c.GST_PARSE_ERROR_SYNTAX, "unexpected pad-reference \"%s\" - ignoring", .{cur.last.pads.items[0]});
            for (cur.last.pads.items) |x| c.g_free(x);
            cur.last.pads.clearRetainingCapacity();
        }
        return cur;
    }

    fn merge(acc: ?*Chain, next: *Chain) *Chain {
        const a = acc orelse return next;
        a.last.free();
        next.first.free();
        next.first = a.first;
        a.first = .{};
        a.elements.appendSlice(alloc, next.elements.items) catch {};
        next.elements.deinit(alloc);
        next.elements = a.elements;
        a.elements = .empty;
        a.free();
        return next;
    }

    fn chainList(p: *Parser, inside: bool) Abort!?*Chain {
        var acc: ?*Chain = null;
        errdefer if (acc) |a| a.free();
        while (true) {
            if (p.tok.kind == .eof) {
                if (inside) {
                    p.g.fail(c.GST_PARSE_ERROR_SYNTAX, "syntax error", .{});
                    return error.Abort;
                }
                return acc;
            }
            if (inside and p.isOp(')')) return acc;
            if (p.startsChain()) {
                const ch = p.chain() catch {
                    p.g.fail(c.GST_PARSE_ERROR_SYNTAX, "syntax error", .{});
                    p.recover();
                    continue;
                };
                acc = merge(acc, ch);
                continue;
            }
            p.g.fail(c.GST_PARSE_ERROR_SYNTAX, "syntax error", .{});
            if (p.tok.text != null) c.g_free(p.tok.text);
            p.advance();
        }
    }

    fn recover(p: *Parser) void {
        if (p.tok.text != null and !p.startsChain()) {
            c.g_free(p.tok.text);
            p.advance();
        }
    }

    fn bin(p: *Parser) Abort!*Chain {
        const name: [*c]u8 = if (p.tok.kind == .binref) p.take() else blk: {
            p.advance();
            break :blk c.g_strdup("bin");
        };
        defer c.g_free(name);
        var assigns: std.ArrayListUnmanaged([*c]u8) = .empty;
        defer assigns.deinit(alloc);
        while (p.tok.kind == .assignment) assigns.append(alloc, p.take()) catch {};
        const inner = p.chainList(true) catch |e| {
            for (assigns.items) |a| c.g_free(a);
            return e;
        };
        p.advance();
        var ch = inner orelse blk: {
            p.g.fail(c.GST_PARSE_ERROR_EMPTY_BIN, "specified empty bin \"%s\", not allowed", .{name});
            const empty = alloc.create(Chain) catch return error.Abort;
            empty.* = .{};
            break :blk empty;
        };
        const b: [*c]Element = c.gst_element_factory_make(name, null);
        if (b == null) {
            p.g.missing(name);
            p.g.fail(c.GST_PARSE_ERROR_NO_SUCH_ELEMENT, "no bin \"%s\", unpacking elements", .{name});
            for (assigns.items) |a| c.g_free(a);
            assigns.clearRetainingCapacity();
        } else {
            for (ch.elements.items) |e| _ = c.gst_bin_add(@ptrCast(b), e);
            ch.elements.clearRetainingCapacity();
            ch.elements.append(alloc, b) catch {};
        }
        for (assigns.items) |a| setOn(a, b, p.g);
        _ = &ch;
        return ch;
    }
};

fn resolve(r: *Ref, top: [*c]Element) i32 {
    if (r.element != null) return 0;
    if (r.name == null) return -2;
    if (gtype.instanceOf(top, c.gst_bin_get_type())) {
        r.element = c.gst_bin_get_by_name_recurse_up(@ptrCast(top), r.name);
    } else {
        r.element = if (c.strcmp(top[0].object.name, r.name) == 0) @ptrCast(@alignCast(c.gst_object_ref(top))) else null;
    }
    return if (r.element != null) 0 else -1;
}

fn onBusMessage(_: ?*c.GstBus, m: [*c]c.GstMessage, data: c.gpointer) callconv(.c) c.GstBusSyncReply {
    const r: *Receiver = @ptrCast(@alignCast(data));
    if (m[0].type != c.GST_MESSAGE_ERROR) return c.GST_BUS_PASS;
    var err: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    c.gst_message_parse_error(m, &err, &dbg);
    const src = m[0].src;
    const tname: [*c]const u8 = if (src != null) c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(src))).g_class.*.g_type) else "";
    const explanation = c.gst_info_strdup_printf("%s %" ++ "p\x07A" ++ " posted an error message: %s", tname, src, err[0].message);
    c.g_mutex_lock(&r.lock);
    if (r.reason == null) r.reason = c.g_strdup(explanation);
    c.g_mutex_unlock(&r.lock);
    c.g_free(explanation);
    c.g_error_free(err);
    c.g_free(dbg);
    return c.GST_BUS_PASS;
}

fn launch(str: [*c]const u8, err: [*c][*c]c.GError, ctx: [*c]Context, flags: c.GstParseFlags) [*c]Element {
    var g = Graph{ .err = err, .ctx = ctx, .flags = flags };
    defer g.links.deinit(alloc);
    var p = Parser{ .lx = .{ .s = std.mem.span(str) }, .tok = undefined, .g = &g };
    p.advance();
    const top = p.chainList(false) catch {
        g.fail(c.GST_PARSE_ERROR_SYNTAX, "Unrecoverable syntax error while parsing pipeline %s", .{str});
        for (g.links.items) |l| l.free();
        return null;
    };
    if (top == null) g.fail(c.GST_PARSE_ERROR_EMPTY, "empty pipeline not allowed", .{});
    const ch = top orelse blk: {
        const empty = alloc.create(Chain) catch return null;
        empty.* = .{};
        break :blk empty;
    };
    var b: [*c]Element = null;
    var temp_bus: [*c]c.GstBus = null;
    var old_bus: [*c]c.GstBus = null;
    if (ch.elements.items.len > 1) {
        b = c.gst_element_factory_make(if (flags & c.GST_PARSE_FLAG_PLACE_IN_BIN != 0) "bin" else "pipeline", null);
        old_bus = c.gst_element_get_bus(b);
        temp_bus = c.gst_bus_new();
        const r = alloc.create(Receiver) catch null;
        if (r) |rc| {
            rc.* = .{};
            c.g_mutex_init(&rc.lock);
            _ = rc.refs.fetchAdd(1, .acq_rel);
            g.receiver = rc;
            c.gst_bus_set_sync_handler(temp_bus, onBusMessage, rc, Receiver.unref);
        }
        c.gst_element_set_bus(b, temp_bus);
        for (ch.elements.items) |e| if (e != null) {
            _ = c.gst_bin_add(@ptrCast(b), e);
        };
        ch.elements.clearRetainingCapacity();
        ch.elements.append(alloc, b) catch {};
    }
    const ret: [*c]Element = if (ch.elements.items.len > 0) ch.elements.items[0] else null;
    ch.elements.clearRetainingCapacity();
    ch.free();
    for (g.links.items) |l| {
        const rs = resolve(&l.src, ret);
        if (rs != 0) {
            if (rs == -1) g.fail(c.GST_PARSE_ERROR_NO_SUCH_ELEMENT, "No src-element named \"%s\" - omitting link", .{l.src.name}) else g.fail(c.GST_PARSE_ERROR_NO_SUCH_ELEMENT, "No src-element found - omitting link", .{});
            l.free();
            continue;
        }
        const rk = resolve(&l.sink, ret);
        if (rk != 0) {
            if (rk == -1) g.fail(c.GST_PARSE_ERROR_NO_SUCH_ELEMENT, "No sink-element named \"%s\" - omitting link", .{l.src.name}) else g.fail(c.GST_PARSE_ERROR_NO_SUCH_ELEMENT, "No sink-element found - omitting link", .{});
            l.free();
            continue;
        }
        performLink(l, &g);
    }
    if (b != null and temp_bus != null) {
        c.gst_element_set_bus(b, old_bus);
        if (g.receiver) |rc| Receiver.unref(rc);
        g.receiver = null;
        c.gst_object_unref(temp_bus);
        if (old_bus != null) c.gst_object_unref(old_bus);
    }
    return ret;
}

pub export fn gst_parse_launch_full(desc: [*c]const u8, ctx: [*c]Context, flags: c.GstParseFlags, err: [*c][*c]c.GError) [*c]Element {
    if (!check.that(desc != null, "gst_parse_launch_full", "pipeline_description != NULL")) return null;
    if (!check.that(err == null or err.* == null, "gst_parse_launch_full", "error == NULL || *error == NULL")) return null;
    var mine: [*c]c.GError = null;
    var e = launch(desc, &mine, ctx, flags);
    if (mine != null and e != null and flags & c.GST_PARSE_FLAG_FATAL_ERRORS != 0) {
        c.gst_object_unref(e);
        e = null;
    }
    if (mine != null) c.g_propagate_error(err, mine);
    return e;
}

pub export fn gst_parse_launch(desc: [*c]const u8, err: [*c][*c]c.GError) [*c]Element {
    return gst_parse_launch_full(desc, null, c.GST_PARSE_FLAG_NONE, err);
}

fn escapeArg(s: [*c]const u8) [*c]u8 {
    const out = c.g_string_sized_new(c.strlen(s));
    var in_quotes = false;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (s[i] == '"' and (!in_quotes or (i > 0 and s[i - 1] != '\\'))) in_quotes = !in_quotes;
        if (s[i] == ' ' and !in_quotes) _ = c.g_string_append_c(out, '\\');
        _ = c.g_string_append_c(out, s[i]);
    }
    return c.g_string_free(out, 0);
}

pub export fn gst_parse_launchv_full(argv: [*c][*c]const u8, ctx: [*c]Context, flags: c.GstParseFlags, err: [*c][*c]c.GError) [*c]Element {
    if (!check.that(argv != null, "gst_parse_launchv_full", "argv != NULL")) return null;
    if (!check.that(err == null or err.* == null, "gst_parse_launchv_full", "error == NULL || *error == NULL")) return null;
    const str = c.g_string_sized_new(1024);
    var i: usize = 0;
    while (argv[i] != null) : (i += 1) {
        const t = escapeArg(argv[i]);
        _ = c.g_string_append(str, t);
        c.g_free(t);
        _ = c.g_string_append_c(str, ' ');
    }
    const e = gst_parse_launch_full(str[0].str, ctx, flags, err);
    _ = c.g_string_free(str, 1);
    return e;
}

pub export fn gst_parse_launchv(argv: [*c][*c]const u8, err: [*c][*c]c.GError) [*c]Element {
    return gst_parse_launchv_full(argv, null, c.GST_PARSE_FLAG_NONE, err);
}

fn unlinkedOf(e: [*c]Element, dir: c.GstPadDirection) ?*c.GstPad {
    const it = if (dir == c.GST_PAD_SRC) c.gst_element_iterate_src_pads(e) else c.gst_element_iterate_sink_pads(e);
    defer c.gst_iterator_free(it);
    var v = std.mem.zeroes(c.GValue);
    defer if (v.g_type != 0) c.g_value_unset(&v);
    while (true) {
        switch (c.gst_iterator_next(it, &v)) {
            c.GST_ITERATOR_OK => {
                const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&v)));
                const peer = c.gst_pad_get_peer(pad);
                if (peer == null) return @ptrCast(@alignCast(c.gst_object_ref(pad)));
                c.gst_object_unref(peer);
                _ = c.g_value_reset(&v);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => return null,
        }
    }
}

pub export fn gst_bin_find_unlinked_pad(b: [*c]Bin, dir: c.GstPadDirection) ?*c.GstPad {
    if (!check.that(gtype.instanceOf(b, c.gst_bin_get_type()), "gst_bin_find_unlinked_pad", "GST_IS_BIN (bin)")) return null;
    if (!check.that(dir != c.GST_PAD_UNKNOWN, "gst_bin_find_unlinked_pad", "direction != GST_PAD_UNKNOWN")) return null;
    const it = c.gst_bin_iterate_recurse(b);
    defer c.gst_iterator_free(it);
    var v = std.mem.zeroes(c.GValue);
    defer if (v.g_type != 0) c.g_value_unset(&v);
    while (true) {
        switch (c.gst_iterator_next(it, &v)) {
            c.GST_ITERATOR_OK => {
                const pad = unlinkedOf(@ptrCast(@alignCast(c.g_value_get_object(&v))), dir);
                if (pad != null) return pad;
                _ = c.g_value_reset(&v);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => return null,
        }
    }
}

pub export fn gst_parse_bin_from_description_full(desc: [*c]const u8, ghost: c.gboolean, ctx: [*c]Context, flags: c.GstParseFlags, err: [*c][*c]c.GError) [*c]Element {
    if (!check.that(desc != null, "gst_parse_bin_from_description_full", "bin_description != NULL")) return null;
    if (!check.that(err == null or err.* == null, "gst_parse_bin_from_description_full", "err == NULL || *err == NULL")) return null;
    var e: [*c]Element = undefined;
    if (flags & c.GST_PARSE_FLAG_NO_SINGLE_ELEMENT_BINS != 0) {
        e = gst_parse_launch_full(desc, ctx, flags, err);
    } else {
        const d = c.g_strdup_printf("bin.( %s )", desc);
        e = gst_parse_launch_full(d, ctx, flags, err);
        c.g_free(d);
    }
    if (e == null or (err != null and err.* != null)) {
        if (e != null) c.gst_object_unref(e);
        return null;
    }
    if (!gtype.instanceOf(e, c.gst_bin_get_type())) return e;
    if (ghost != 0) {
        if (gst_bin_find_unlinked_pad(@ptrCast(e), c.GST_PAD_SRC)) |pad| {
            _ = c.gst_element_add_pad(e, c.gst_ghost_pad_new("src", pad));
            c.gst_object_unref(pad);
        }
        if (gst_bin_find_unlinked_pad(@ptrCast(e), c.GST_PAD_SINK)) |pad| {
            _ = c.gst_element_add_pad(e, c.gst_ghost_pad_new("sink", pad));
            c.gst_object_unref(pad);
        }
    }
    return e;
}

pub export fn gst_parse_bin_from_description(desc: [*c]const u8, ghost: c.gboolean, err: [*c][*c]c.GError) [*c]Element {
    return gst_parse_bin_from_description_full(desc, ghost, null, c.GST_PARSE_FLAG_NONE, err);
}
