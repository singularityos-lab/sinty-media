const std = @import("std");
const c = @import("c.zig").c;
const value = @import("value.zig");
const vtypes = @import("vtypes.zig");
const vbasic = @import("vbasic.zig");
const vlist = @import("vlist.zig");

const Value = c.GValue;
const Cursor = [*c]u8;

fn skipSpace(p: Cursor) Cursor {
    var r = p;
    while (std.ascii.isWhitespace(r[0])) r += 1;
    return r;
}

pub fn parseSimpleStringDelim(str: Cursor, end: *Cursor, delim: u8) bool {
    var p = str;
    while (p[0] != 0 and vbasic.isStringChar(p[0]) and p[0] != delim) p += 1;
    end.* = p;
    return p != str or p[0] == delim;
}

pub fn parseSimpleString(str: Cursor, end: *Cursor) bool {
    return parseSimpleStringDelim(str, end, 0);
}

pub fn parseString(start: Cursor, end: *Cursor, next: *Cursor, unescape: bool) bool {
    if (start[0] == 0) return false;
    if (start[0] != '"') {
        const ok = parseSimpleStringDelim(start, end, 0);
        next.* = end.*;
        return ok;
    }
    var r = start + 1;
    var w = start;
    while (r[0] != '"') {
        if (r[0] == 0) return false;
        if (r[0] == '\\') {
            r += 1;
            if (r[0] == 0) return false;
        }
        if (unescape) {
            w[0] = r[0];
            w += 1;
        }
        r += 1;
    }
    r += 1;
    end.* = if (unescape) w else r;
    next.* = r;
    return true;
}

fn typeAt(start: Cursor, stop: Cursor) c.GType {
    const saved = stop[0];
    stop[0] = 0;
    defer stop[0] = saved;
    return value.typeFromAbbr(start);
}

pub fn parseTypeCast(text: Cursor, after: *Cursor, container: *c.GType, default_type: *c.GType) bool {
    var p = skipSpace(text);
    if (p[0] != '(') return false;
    p = skipSpace(p + 1);
    var name = p;
    var name_end: Cursor = undefined;
    if (!parseSimpleStringDelim(p, &name_end, '/')) return false;
    if (p[0] == '/') {
        p = skipSpace(p + 1);
        name = p;
        if (!parseSimpleStringDelim(p, &name_end, 0)) return false;
        container.* = typeAt(name, name_end);
        if (container.* == 0) return false;
    } else {
        p = skipSpace(name_end);
        if (p[0] == ')') {
            default_type.* = typeAt(name, name_end);
            if (default_type.* == 0) return false;
        } else if (p[0] == '/') {
            default_type.* = typeAt(name, name_end);
            if (default_type.* == 0) return false;
            p = skipSpace(p + 1);
            name = p;
            if (!parseSimpleStringDelim(p, &name_end, 0)) return false;
            container.* = typeAt(name, name_end);
            if (container.* == 0) return false;
        } else return false;
    }
    p = skipSpace(name_end);
    if (p[0] != ')') return false;
    after.* = skipSpace(p + 1);
    return true;
}

fn parseRange(text: Cursor, after: *Cursor, out: [*c]Value, t: c.GType) bool {
    if (text[0] != '[') return false;
    var p = text + 1;
    var parts = [3]Value{ std.mem.zeroes(Value), std.mem.zeroes(Value), std.mem.zeroes(Value) };
    var has_step = false;
    const ok = blk: {
        if (!parseValue(p, &p, &parts[0], t, null)) break :blk false;
        p = skipSpace(p);
        if (p[0] != ',') break :blk false;
        p = skipSpace(p + 1);
        if (!parseValue(p, &p, &parts[1], t, null)) break :blk false;
        p = skipSpace(p);
        const t0 = parts[0].g_type;
        if ((t0 == c.G_TYPE_INT or t0 == c.G_TYPE_INT64) and p[0] == ',') {
            p = skipSpace(p + 1);
            if (!parseValue(p, &p, &parts[2], t, null)) break :blk false;
            p = skipSpace(p);
            has_step = true;
        }
        if (p[0] != ']') break :blk false;
        break :blk true;
    };
    if (!ok) {
        for (&parts) |*v| if (v.g_type != 0) c.g_value_unset(v);
        return false;
    }
    p += 1;
    const t0 = parts[0].g_type;
    if (t0 != parts[1].g_type) return false;
    if (has_step and t0 != parts[2].g_type) return false;
    if (t0 == c.G_TYPE_DOUBLE) {
        _ = c.g_value_init(out, value._gst_double_range_type);
        vtypes.gst_value_set_double_range(out, parts[0].data[0].v_double, parts[1].data[0].v_double);
    } else if (t0 == c.G_TYPE_INT) {
        _ = c.g_value_init(out, value._gst_int_range_type);
        const step = if (has_step) parts[2].data[0].v_int else 1;
        vtypes.gst_value_set_int_range_step(out, parts[0].data[0].v_int, parts[1].data[0].v_int, step);
    } else if (t0 == c.G_TYPE_INT64) {
        _ = c.g_value_init(out, value._gst_int64_range_type);
        const step = if (has_step) parts[2].data[0].v_int64 else 1;
        vtypes.gst_value_set_int64_range_step(out, parts[0].data[0].v_int64, parts[1].data[0].v_int64, step);
    } else if (t0 == value._gst_fraction_type) {
        _ = c.g_value_init(out, value._gst_fraction_range_type);
        vtypes.gst_value_set_fraction_range(out, &parts[0], &parts[1]);
    } else {
        for (&parts) |*v| if (v.g_type != 0) c.g_value_unset(v);
        return false;
    }
    after.* = p;
    return true;
}

fn elementSpec(pspec: [*c]c.GParamSpec) [*c]c.GParamSpec {
    if (pspec == null) return null;
    const arr: *c.GstParamSpecArray = @ptrCast(@alignCast(pspec));
    return arr.element_spec;
}

fn parseAnyList(text: Cursor, after: *Cursor, out: [*c]Value, t_in: c.GType, open: u8, close: u8, pspec: [*c]c.GParamSpec) bool {
    var p = text;
    var t = t_in;
    var container = out.*.g_type;
    var default_type = t_in;
    if (parseTypeCast(p, &p, &container, &default_type)) {
        if (container == 0) container = value._gst_value_list_type;
        if (out.*.g_type != container) return false;
        t = default_type;
    }
    const spec = elementSpec(pspec);
    if (p[0] != open) return false;
    p = skipSpace(p + 1);
    const l = vlist.of(out);
    while (p[0] != close) {
        if (p[0] == ',') {
            p = skipSpace(p + 1);
            if (p[0] == ',') return false;
            continue;
        }
        var item = std.mem.zeroes(Value);
        if (!parseValue(p, &p, &item, t, spec)) return false;
        vlist.pushTake(l, &item);
        p = skipSpace(p);
        if (p[0] != ',' and p[0] != close) return false;
    }
    after.* = p + 1;
    return true;
}

pub fn parseList(text: Cursor, after: *Cursor, out: [*c]Value, t: c.GType, pspec: [*c]c.GParamSpec) bool {
    return parseAnyList(text, after, out, t, '{', '}', pspec);
}

pub fn parseArray(text: Cursor, after: *Cursor, out: [*c]Value, t: c.GType, pspec: [*c]c.GParamSpec) bool {
    return parseAnyList(text, after, out, t, '<', '>', pspec);
}

fn parseStructOrCaps(text: Cursor, after: *Cursor, t: c.GType, out: [*c]Value) bool {
    if (text[0] != '[') return false;
    const body = text + 1;
    var depth: usize = 1;
    var p = body;
    while (p[0] != 0) : (p += 1) {
        if (p[0] == ']') depth -= 1 else if (p[0] == '[') depth += 1;
        if (depth == 0) break;
    }
    if (p[0] == 0) return false;
    after.* = p + 1;
    const saved = p[0];
    p[0] = 0;
    _ = c.g_value_init(out, t);
    var start: Cursor = undefined;
    var stop: Cursor = undefined;
    var next: Cursor = undefined;
    var ok = false;
    if (@import("structure.zig").parseName(body, &start, &stop, &next, true)) ok = value.gst_value_deserialize(out, body) != 0;
    if (!ok) {
        p[0] = saved;
        c.g_value_unset(out);
    }
    return ok;
}

fn parseBracketed(text: Cursor, after: *Cursor, out: [*c]Value, t: c.GType) bool {
    const st = c.gst_structure_get_type();
    const ct = c.gst_caps_get_type();
    var p = text;
    if ((t == ct or t == st) and parseStructOrCaps(text, &p, t, out)) {
        after.* = p;
        return true;
    }
    p = text;
    if (parseRange(text, &p, out, t)) {
        after.* = p;
        return true;
    }
    if (t != 0) return false;
    for ([_]c.GType{ st, ct }) |candidate| {
        p = text;
        if (parseStructOrCaps(text, &p, candidate, out)) {
            after.* = p;
            return true;
        }
    }
    return false;
}

const guesses = [_]*const fn () c.GType{
    struct {
        fn f() c.GType {
            return c.G_TYPE_INT;
        }
    }.f,
    struct {
        fn f() c.GType {
            return c.G_TYPE_DOUBLE;
        }
    }.f,
    struct {
        fn f() c.GType {
            return value._gst_fraction_type;
        }
    }.f,
    struct {
        fn f() c.GType {
            return value._gst_flagset_type;
        }
    }.f,
    struct {
        fn f() c.GType {
            return c.G_TYPE_BOOLEAN;
        }
    }.f,
    struct {
        fn f() c.GType {
            return c.G_TYPE_STRING;
        }
    }.f,
};

fn guessScalar(raw: [*c]u8, len: usize, out: [*c]Value) bool {
    const quoted = len >= 2 and raw[0] == '"' and raw[len - 1] == '"';
    for (guesses) |g| {
        const t = g();
        _ = c.g_value_init(out, t);
        if (t != c.G_TYPE_STRING and quoted) {
            raw[len - 1] = 0;
            const ok = value.gst_value_deserialize(out, raw + 1) != 0;
            raw[len - 1] = '"';
            if (ok) {
                c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Received a structure string that contains '=%s'. Reading as a %s value, rather than a string value. This is undesired behaviour, and with GStreamer 1.22  onward, this will be interpreted as a string value instead because it is wrapped in '\"' quotes. If you want to guarantee this value is read as a string, before this change, use '=(string)%s' instead. If you want to read in a %s value, leave its value unquoted.", raw, c.g_type_name(t), raw, c.g_type_name(t));
                return true;
            }
        } else if (value.gst_value_deserialize(out, raw) != 0) return true;
        c.g_value_unset(out);
    }
    return false;
}

pub fn parseValue(text: Cursor, after: *Cursor, out: [*c]Value, t_in: c.GType, pspec: [*c]c.GParamSpec) bool {
    var p = text;
    var t = t_in;
    var container: c.GType = 0;
    var default_type = t_in;
    if (parseTypeCast(p, &p, &container, &default_type)) {
        if (container != 0 and out.*.g_type != 0 and out.*.g_type != container) return false;
        t = default_type;
    } else if (pspec != null) {
        t = pspec.*.value_type;
    }
    p = skipSpace(p);
    var ok = false;
    switch (p[0]) {
        '[' => ok = parseBracketed(p, &p, out, t),
        '{' => {
            _ = c.g_value_init(out, if (container == 0) value._gst_value_list_type else container);
            ok = parseList(p, &p, out, t, pspec);
        },
        '<' => {
            if (t == c.g_strv_get_type()) {
                _ = c.g_value_init(out, t);
                var q: [*c]const u8 = p;
                ok = parseStrv(p, &q, out);
                p = @constCast(q);
            } else {
                _ = c.g_value_init(out, value._gst_value_array_type);
                ok = parseArray(p, &p, out, t, pspec);
            }
        },
        else => {
            const start = p;
            var stop: Cursor = undefined;
            if (t == 0) {
                if (!parseString(p, &stop, &p, false)) return false;
                const len = @intFromPtr(stop) - @intFromPtr(start);
                const raw = c.g_strndup(start, len);
                defer c.g_free(raw);
                ok = guessScalar(raw, len, out);
            } else {
                _ = c.g_value_init(out, t);
                if (!parseString(p, &stop, &p, false)) return false;
                const raw = c.g_strndup(start, @intFromPtr(stop) - @intFromPtr(start));
                defer c.g_free(raw);
                ok = value.gst_value_deserialize_with_pspec(out, raw, pspec) != 0;
                if (!ok) c.g_value_unset(out);
            }
        },
    }
    after.* = p;
    return ok;
}

pub fn parseStrv(text: [*c]const u8, after: *[*c]const u8, out: [*c]Value) bool {
    if (text[0] != '<') return false;
    var p = text + 1;
    while (std.ascii.isWhitespace(p[0])) p += 1;
    const arr = c.g_ptr_array_new_with_free_func(c.g_free);
    while (p[0] != '>') {
        if (p[0] != '"') {
            _ = c.g_ptr_array_free(arr, 1);
            return false;
        }
        p += 1;
        const start = p;
        var escaped = false;
        while (p[0] != '"') {
            if (p[0] == '\\') {
                escaped = true;
                p += 1;
            }
            if (p[0] == 0) {
                _ = c.g_ptr_array_free(arr, 1);
                return false;
            }
            p += 1;
        }
        p += 1;
        const piece = c.g_strndup(start, @intFromPtr(p) - @intFromPtr(start) - 1);
        if (escaped) {
            var r: usize = 0;
            var w: usize = 0;
            while (piece[r] != 0) : ({
                r += 1;
                w += 1;
            }) {
                if (piece[r] == '\\') r += 1;
                piece[w] = piece[r];
            }
            piece[w] = 0;
        }
        c.g_ptr_array_add(arr, piece);
        while (std.ascii.isWhitespace(p[0])) p += 1;
        if (p[0] == ',') {
            p += 1;
            while (std.ascii.isWhitespace(p[0])) p += 1;
        }
    }
    c.g_ptr_array_add(arr, null);
    c.g_value_take_boxed(out, @ptrCast(c.g_ptr_array_free(arr, 0)));
    after.* = p + 1;
    return true;
}
