const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const fm = @import("formats.zig");
const ent = @import("entities.zig");

const MSEC: u64 = c.GST_MSECOND;
const ITALIC = 'i';
const SPAN = 's';
const RUBY = 'r';
const RT = 't';
const CLEAR = '0';

const Context = struct {
    buf: [*c]c.GString,
    rubybuf: [*c]c.GString,
    resultbuf: [*c]c.GString,
    state: [*c]c.GString,
    html: [*c]c.GString,
    has_result: bool = false,
    in_sync: bool = false,
    time1: u64 = 0,
    time2: u64 = 0,
};

fn ctx(st: *fm.State) *Context {
    return @ptrCast(@alignCast(st.user_data.?));
}

fn off(a: anytype, b: anytype) usize {
    return @intFromPtr(a) - @intFromPtr(b);
}

fn unescape(text_in: [*c]const u8) [*c]u8 {
    var text = text_in;
    const out = c.g_string_new(null);
    outer: while (text[0] != 0) {
        if (text[0] == '&') {
            text += 1;
            if (c.g_ascii_strncasecmp(text, "nbsp", 4) == 0) {
                _ = c.g_string_append_unichar(out, 160);
                text += 4;
                if (text[0] == ';') text += 1;
                continue;
            }
            for (ent.xml) |e| {
                if (c.g_ascii_strncasecmp(text, e.name.ptr, e.name.len) == 0 and text[e.name.len] == ';') {
                    _ = c.g_string_append_c(out, '&');
                    _ = c.g_string_append_len(out, e.name.ptr, @intCast(e.name.len));
                    _ = c.g_string_append_c(out, ';');
                    text += e.name.len + 1;
                    continue :outer;
                }
            }
            for (ent.html) |e| {
                if (c.strncmp(text, e.name.ptr, e.name.len) == 0 and text[e.name.len] == ';') {
                    _ = c.g_string_append_unichar(out, e.code);
                    text += e.name.len + 1;
                    continue :outer;
                }
            }
            if (text[0] == '#') {
                text += 1;
                var hex = false;
                if (text[0] == 'x') {
                    hex = true;
                    text += 1;
                }
                std.c._errno().* = 0;
                var end: [*c]u8 = null;
                const l: c.gunichar = @truncate(c.strtoul(text, &end, if (hex) 16 else 10));
                if (end == text or std.c._errno().* != 0) continue;
                _ = c.g_string_append_unichar(out, l);
                text = end;
                if (text[0] == ';') text += 1;
                continue;
            }
            _ = c.g_string_append(out, "&amp;");
        } else if (c.g_ascii_isspace(text[0])) {
            _ = c.g_string_append_c(out, ' ');
            text += 1;
            while (text[0] != 0 and c.g_ascii_isspace(text[0])) text += 1;
        } else {
            _ = c.g_string_append_c(out, text[0]);
            text += 1;
        }
    }
    return c.g_string_free(out, 0);
}

fn token(s: [*c]const u8, delim: [*c]const u8, first: *[*c]u8) [*c]const u8 {
    const next = c.strstr(s, delim);
    first.* = if (next != null) c.g_strndup(s, off(next, s)) else c.g_strdup(s);
    return next;
}

fn hasTag(str: [*c]c.GString, tag: u8) bool {
    return c.strrchr(str.*.str, tag) != null;
}

fn push(x: *Context, s: u8) void {
    _ = c.g_string_append_c(x.state, s);
}

fn pop(x: *Context, s: u8) void {
    const str = c.g_string_new("");
    const cs = x.state;
    var i: isize = @as(isize, @intCast(cs.*.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const ch = cs.*.str[@intCast(i)];
        switch (ch) {
            ITALIC => _ = c.g_string_append(str, "</i>"),
            SPAN => _ = c.g_string_append(str, "</span>"),
            RT => {
                _ = c.g_string_append(x.rubybuf, "</span>");
                if (hasTag(cs, ITALIC)) _ = c.g_string_append(x.rubybuf, "</i>");
            },
            else => {},
        }
        if (ch == s) {
            _ = c.g_string_append(x.buf, str.*.str);
            _ = c.g_string_free(str, 1);
            _ = c.g_string_truncate(cs, @intCast(i));
            return;
        }
    }
    if (s == CLEAR) {
        _ = c.g_string_append(x.buf, str.*.str);
        _ = c.g_string_truncate(cs, 0);
    }
    _ = c.g_string_free(str, 1);
}

fn startSync(x: *Context, atts: [*c][*c]u8) void {
    pop(x, CLEAR);
    var i: usize = 0;
    while (atts[i] != null) : (i += 2) {
        const value = atts[i + 1];
        if (value == null) continue;
        if (c.g_ascii_strcasecmp("start", atts[i]) != 0) continue;
        if (x.resultbuf.*.len == 0) x.time1 = x.time2;
        x.time2 = @as(u64, @bitCast(@as(i64, c.atoi(value)))) *% MSEC;
        x.time2 = @max(x.time2, x.time1);
        _ = c.g_string_append(x.resultbuf, x.buf.*.str);
        x.has_result = x.resultbuf.*.len != 0;
        _ = c.g_string_truncate(x.buf, 0);
    }
}

const colors = [_][2][*:0]const u8{
    .{ "aqua", "#00ffff" },
    .{ "crimson", "#dc143c" },
    .{ "fuchsia", "#ff00ff" },
    .{ "indigo", "#4b0082" },
    .{ "lime", "#00ff00" },
    .{ "olive", "#808000" },
    .{ "silver", "#c0c0c0" },
    .{ "teal", "#008080" },
};

fn startFont(x: *Context, atts: [*c][*c]u8) void {
    pop(x, SPAN);
    _ = c.g_string_append(x.buf, "<span");
    var i: usize = 0;
    while (atts[i] != null) : (i += 2) {
        var value: [*c]const u8 = atts[i + 1];
        if (value == null) continue;
        if (c.g_ascii_strcasecmp("color", atts[i]) == 0) {
            var sharp: [*c]const u8 = "";
            const len = c.strlen(value);
            if (!(value[0] == '#' and len == 7)) {
                var r: [*c]u8 = null;
                if (c.strtol(value, &r, 16) >= 0 and @intFromPtr(r) == @intFromPtr(value + 6) and len == 6) sharp = "#";
            }
            for (colors) |pair| {
                if (c.g_ascii_strcasecmp(pair[0], value) == 0) {
                    value = pair[1];
                    break;
                }
            }
            c.g_string_append_printf(x.buf, " foreground=\"%s%s\"", sharp, value);
        } else if (c.g_ascii_strcasecmp("face", atts[i]) == 0) {
            c.g_string_append_printf(x.buf, " font_family=\"%s\"", value);
        }
    }
    _ = c.g_string_append_c(x.buf, '>');
    push(x, SPAN);
}

fn startElement(x: *Context, name: [*c]const u8, atts: [*c][*c]u8) void {
    if (c.g_ascii_strcasecmp("sync", name) == 0) {
        startSync(x, atts);
        x.in_sync = true;
    } else if (c.g_ascii_strcasecmp("font", name) == 0) {
        startFont(x, atts);
    } else if (c.g_ascii_strcasecmp("ruby", name) == 0) {
        push(x, RUBY);
    } else if (c.g_ascii_strcasecmp("br", name) == 0) {
        _ = c.g_string_append_c(x.buf, '\n');
    } else if (c.g_ascii_strcasecmp("rt", name) == 0) {
        if (hasTag(x.state, ITALIC)) _ = c.g_string_append(x.rubybuf, "<i>");
        _ = c.g_string_append(x.rubybuf, "<span size='xx-small' rise='-100'>");
        push(x, RT);
    } else if (c.g_ascii_strcasecmp("i", name) == 0) {
        _ = c.g_string_append(x.buf, "<i>");
        push(x, ITALIC);
    }
}

fn endElement(x: *Context, name: [*c]const u8) void {
    if (c.g_ascii_strcasecmp("sync", name) == 0) {
        x.in_sync = false;
    } else if (c.g_ascii_strcasecmp("body", name) == 0 or c.g_ascii_strcasecmp("sami", name) == 0) {
        if (x.buf.*.len != 0) {
            if (x.resultbuf.*.len == 0) x.time1 = x.time2;
            x.time2 = cm.CLOCK_NONE;
            _ = c.g_string_append(x.resultbuf, x.buf.*.str);
            x.has_result = x.resultbuf.*.len != 0;
            _ = c.g_string_truncate(x.buf, 0);
        }
    } else if (c.g_ascii_strcasecmp("font", name) == 0) {
        pop(x, SPAN);
    } else if (c.g_ascii_strcasecmp("ruby", name) == 0) {
        pop(x, RUBY);
    } else if (c.g_ascii_strcasecmp("i", name) == 0) {
        pop(x, ITALIC);
    }
}

fn onText(x: *Context, t: [*c]const u8) void {
    if (!x.in_sync) return;
    if (hasTag(x.state, RT)) {
        _ = c.g_string_append_c(x.rubybuf, ' ');
        _ = c.g_string_append(x.rubybuf, t);
        _ = c.g_string_append_c(x.rubybuf, ' ');
    } else _ = c.g_string_append(x.buf, t);
}

fn handleElement(x: *Context, s: [*c]const u8, close: bool) void {
    var name: [*c]u8 = null;
    var next = token(s, " ", &name);
    var count: usize = 0;
    if (next != null) {
        var found: [*c]const u8 = next + 1;
        while (true) {
            found = c.strchr(found, '=');
            if (found == null) break;
            found += 1;
            count += 1;
        }
    }
    const attrs: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc0(@sizeOf([*c]u8) * (count + 1) * 2)));
    var i: usize = 0;
    while (i < count and next != null) : (i += 2) {
        var an: [*c]u8 = null;
        var av: [*c]u8 = null;
        next = token(next + 1, "=", &an);
        if (next == null) {
            c.g_free(an);
            break;
        }
        next = token(next + 1, " ", &av);
        if (av[0] == '"' or av[0] == '\'') {
            const tmp = c.g_strdup(av + 1);
            c.g_free(av);
            av = tmp;
        }
        const len = c.strlen(av);
        if (len > 0 and (av[len - 1] == '"' or av[len - 1] == '\'')) av[len - 1] = 0;
        attrs[i] = an;
        attrs[i + 1] = av;
    }
    startElement(x, name, attrs);
    if (close) endElement(x, name);
    c.g_strfreev(attrs);
    c.g_free(name);
}

fn htmlParse(x: *Context, t: [*c]const u8, len: usize) void {
    _ = c.g_string_append_len(x.html, t, @intCast(len));
    var next: [*c]const u8 = x.html.*.str;
    while (true) {
        if (next[0] == '<') {
            if (c.strchr(next, '>') == null) return;
            var element: [*c]u8 = null;
            next = token(next, ">", &element);
            next += 1;
            if (c.g_str_has_suffix(element, "/") != 0) {
                element[c.strlen(element) - 1] = 0;
                handleElement(x, element + 1, true);
            } else if (element[1] == '/') {
                endElement(x, element + 2);
            } else handleElement(x, element + 1, false);
            c.g_free(element);
        } else if (c.strchr(next, '<') != null) {
            var piece: [*c]u8 = null;
            next = token(next, "<", &piece);
            piece = c.g_strstrip(piece);
            onText(x, piece);
            c.g_free(piece);
        } else {
            const piece = c.g_strstrip(@constCast(next));
            onText(x, piece);
            _ = c.g_string_assign(x.html, "");
            return;
        }
    }
}

pub fn init(st: *fm.State) void {
    if (st.user_data != null) c.g_assertion_message_expr(null, "../gst/subparse/samiparse.c", 839, "sami_context_init", "state->user_data == NULL");
    const x: *Context = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Context))));
    x.* = .{ .buf = c.g_string_new(""), .rubybuf = c.g_string_new(""), .resultbuf = c.g_string_new(""), .state = c.g_string_new(""), .html = c.g_string_new(null) };
    st.user_data = x;
}

pub fn deinit(st: *fm.State) void {
    if (st.user_data == null) return;
    const x = ctx(st);
    _ = c.g_string_free(x.html, 1);
    _ = c.g_string_free(x.buf, 1);
    _ = c.g_string_free(x.rubybuf, 1);
    _ = c.g_string_free(x.resultbuf, 1);
    _ = c.g_string_free(x.state, 1);
    c.g_free(x);
    st.user_data = null;
}

pub fn reset(st: *fm.State) void {
    if (st.user_data == null) return;
    const x = ctx(st);
    _ = c.g_string_truncate(x.buf, 0);
    _ = c.g_string_truncate(x.rubybuf, 0);
    _ = c.g_string_truncate(x.resultbuf, 0);
    _ = c.g_string_truncate(x.state, 0);
    x.has_result = false;
    x.in_sync = false;
    x.time1 = 0;
    x.time2 = 0;
}

pub fn parse(st: *fm.State, line: [*c]const u8) [*c]u8 {
    const x = ctx(st);
    const u = unescape(line);
    htmlParse(x, u, c.strlen(u));
    c.g_free(u);
    if (!x.has_result) return null;
    if (x.rubybuf.*.len != 0) {
        _ = c.g_string_append_c(x.rubybuf, '\n');
        _ = c.g_string_prepend(x.resultbuf, x.rubybuf.*.str);
        _ = c.g_string_truncate(x.rubybuf, 0);
    }
    const ret = c.g_string_free(x.resultbuf, 0);
    x.resultbuf = c.g_string_new("");
    st.start_time = x.time1;
    st.duration = x.time2 -% x.time1;
    x.has_result = false;
    return ret;
}
