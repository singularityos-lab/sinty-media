const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const SEC: u64 = c.GST_SECOND;
const MSEC: u64 = c.GST_MSECOND;

pub const State = struct {
    state: c_int = 0,
    buf: [*c]c.GString = null,
    start_time: u64 = 0,
    duration: u64 = 0,
    max_duration: u64 = 0,
    segment: [*c]c.GstSegment = null,
    user_data: ?*anyopaque = null,
    have_internal_fps: bool = false,
    fps_n: c.gint = 0,
    fps_d: c.gint = 0,
    line_position: u8 = 0,
    line_number: c.gint = 0,
    text_position: u8 = 0,
    text_size: u8 = 0,
    vertical: [*c]u8 = null,
    alignment: [*c]u8 = null,
    allowed_tags: ?[]const [*:0]const u8 = null,
    allows_tag_attributes: bool = false,
};

pub const Parser = *const fn (*State, [*c]const u8) [*c]u8;

pub const srt_tags = [_][*:0]const u8{ "i", "b", "u" };
pub const vtt_tags = [_][*:0]const u8{ "i", "b", "c", "u", "v", "ruby", "rt" };

fn off(a: anytype, b: anytype) usize {
    return @intFromPtr(a) - @intFromPtr(b);
}

pub fn clip(st: *State) bool {
    var cs: u64 = 0;
    var ce: u64 = 0;
    if (c.gst_segment_clip(st.segment, c.GST_FORMAT_TIME, st.start_time, st.start_time +% st.duration, &cs, &ce) == 0) return false;
    st.start_time = cs;
    st.duration = ce -% cs;
    return true;
}

pub fn mdvdsub(st: *State, line_in: [*c]const u8) [*c]u8 {
    var start_frame: c.guint = 0;
    var end_frame: c.guint = 0;
    if (c.sscanf(line_in, "{%u}{%u}", &start_frame, &end_frame) != 2) return null;
    var line = c.strchr(line_in, '}');
    if (line == null) return null;
    line = c.strchr(line + 1, '}');
    if (line == null) return null;
    line += 1;
    if (start_frame == 1 and end_frame == 1) {
        const rest = c.g_strdup(line);
        _ = c.g_strdelimit(rest, ",", '.');
        var end: [*c]u8 = null;
        const fps = c.g_ascii_strtod(rest, &end);
        if (end != rest) c.gst_util_double_to_fraction(fps, &st.fps_n, &st.fps_d);
        c.g_free(rest);
        return null;
    }
    const scale = SEC * @as(u64, @bitCast(@as(i64, st.fps_d)));
    const n: u64 = @bitCast(@as(i64, st.fps_n));
    st.start_time = c.gst_util_uint64_scale(start_frame, scale, n);
    st.duration = c.gst_util_uint64_scale(end_frame -% start_frame, scale, n);
    if (!clip(st)) return null;
    const markup = c.g_string_new(null);
    while (true) {
        var italic = false;
        var bold = false;
        var fontsize: c.guint = 0;
        if (c.strncmp(line, "{y:i}", 5) == 0) {
            italic = true;
            line = c.strchr(line, '}') + 1;
        }
        if (c.strncmp(line, "{y:b}", 5) == 0) {
            bold = true;
            line = c.strchr(line, '}') + 1;
        }
        if (c.sscanf(line, "{s:%u}", &fontsize) == 1) {
            line = c.strchr(line, '}');
            if (line == null) {
                _ = c.g_string_free(markup, 1);
                return null;
            }
            line += 1;
        }
        if (c.g_str_has_prefix(line, "/") != 0) {
            italic = true;
            line += 1;
        }
        const split = c.strchr(line, '|');
        const chunk = c.g_markup_escape_text(line, if (split != null) @intCast(off(split, line)) else @intCast(c.strlen(line)));
        if (c.g_str_has_suffix(chunk, "/") != 0) chunk[c.strlen(chunk) - 1] = 0;
        _ = c.g_string_append(markup, "<span");
        if (italic) _ = c.g_string_append(markup, " style=\"italic\"");
        if (bold) _ = c.g_string_append(markup, " weight=\"bold\"");
        if (fontsize != 0) c.g_string_append_printf(markup, " size=\"%u\"", fontsize *% 1000);
        c.g_string_append_printf(markup, ">%s</span>", chunk);
        c.g_free(chunk);
        if (split == null) break;
        _ = c.g_string_append(markup, "\n");
        line = split + 1;
    }
    return c.g_string_free(markup, 0);
}

pub fn stripTrailingNewlines(txt: [*c]u8) void {
    if (txt == null) return;
    var len = c.strlen(txt);
    while (len > 1 and txt[len - 1] == '\n') : (len -= 1) txt[len - 1] = 0;
}

fn allowedTag(tags: []const [*:0]const u8, start: [*c]const u8, len: usize, caseless: bool) ?[*:0]const u8 {
    for (tags) |t| {
        if (c.strlen(t) != len) continue;
        const same = if (caseless) c.g_ascii_strncasecmp(t, start, len) == 0 else c.strncmp(t, start, len) == 0;
        if (same) return t;
    }
    return null;
}

fn attrChar(ch: u8) bool {
    return c.g_ascii_isalnum(ch) or ch == '.' or ch == ' ' or ch == '\t' or ch == '(' or ch == ')';
}

fn unescapeFormatting(txt: [*c]u8, tags: []const [*:0]const u8, attrs: bool) void {
    if (c.strstr(txt, "&lt;") == null) return;
    const out = c.g_string_new("");
    var p: [*c]const u8 = txt;
    while (p[0] != 0) {
        var lt: [*c]const u8 = c.strstr(p, "&lt;");
        if (lt == null) {
            _ = c.g_string_append(out, p);
            break;
        }
        _ = c.g_string_append_len(out, p, @intCast(off(lt, p)));
        lt += 4;
        const gt: [*c]const u8 = c.strstr(lt, "&gt;");
        if (gt == null) {
            _ = c.g_string_append(out, lt - 4);
            break;
        }
        var closing = false;
        var ts = lt;
        if (ts[0] == '/') {
            closing = true;
            ts += 1;
        }
        while (ts[0] == ' ' or ts[0] == '\t') ts += 1;
        var te = ts;
        while (c.g_ascii_isalnum(te[0])) te += 1;
        const tl = off(te, ts);
        if (allowedTag(tags, ts, tl, false) == null) {
            _ = c.g_string_append_len(out, lt - 4, @intCast(off(gt + 4, lt - 4)));
            p = gt + 4;
            continue;
        }
        _ = c.g_string_append_c(out, '<');
        if (closing) _ = c.g_string_append_c(out, '/');
        _ = c.g_string_append_len(out, ts, @intCast(tl));
        if (attrs) {
            const as = te;
            while (@intFromPtr(te) < @intFromPtr(gt) and attrChar(te[0])) te += 1;
            _ = c.g_string_append_len(out, as, @intCast(off(te, as)));
        }
        _ = c.g_string_append_c(out, '>');
        p = gt + 4;
    }
    _ = c.strcpy(txt, out.*.str);
    _ = c.g_string_free(out, 1);
}

fn removeUnhandledTags(txt: [*c]u8) void {
    var pos = txt;
    while (pos != null and pos[0] != 0) : (pos += 1) {
        if (c.strncmp(pos, "&lt;", 4) != 0) continue;
        const gt = c.strstr(pos + 4, "&gt;");
        if (gt == null) continue;
        var tag = pos + 4;
        if (tag[0] == '/') tag += 1;
        const l = c.g_ascii_tolower(tag[0]);
        if (l < 'a' or l > 'z') continue;
        const stop = gt + 4;
        _ = c.memmove(pos, stop, c.strlen(stop) + 1);
        pos -= 1;
    }
}

fn fixUpMarkup(p_txt: *[*c]u8, tags: []const [*:0]const u8) void {
    const open = c.g_ptr_array_new_with_free_func(c.g_free);
    var n_open: c.guint = 0;
    var cur = p_txt.*;
    while (cur[0] != 0) {
        var next = c.strchr(cur, '<');
        if (next == null) break;
        var offset: usize = 0;
        var closing = false;
        for (tags) |t| {
            var ts: [*c]const u8 = next + 1;
            closing = ts[0] == '/';
            if (closing) ts += 1;
            while (ts[0] == ' ' or ts[0] == '\t') ts += 1;
            var te = ts;
            while (c.g_ascii_isalnum(te[0])) te += 1;
            const tl = off(te, ts);
            if (c.strlen(t) == tl and c.g_ascii_strncasecmp(t, ts, tl) == 0) {
                if (te[0] == ' ' or te[0] == '\t' or te[0] == '.') {
                    while (te[0] != 0 and te[0] != '>' and attrChar(te[0])) te += 1;
                }
                if (te[0] == '>') {
                    offset = off(te, next + 1);
                    if (!closing) {
                        c.g_ptr_array_add(open, c.g_ascii_strdown(t, -1));
                        n_open += 1;
                    }
                    break;
                }
            }
            offset = 0;
        }
        if (offset == 0) {
            next += 1;
            cur = next;
            continue;
        }
        if (!closing) {
            next += offset;
            cur = next;
            continue;
        }
        const te = c.strchr(next, '>');
        const last: [*c]const u8 = if (n_open > 0) @ptrCast(open.*.pdata[n_open - 1]) else null;
        if (n_open == 0 or c.g_ascii_strncasecmp(next + 2, last, c.strlen(last)) != 0) {
            _ = c.memmove(next, te + 1, c.strlen(te + 1) + 1);
            cur = next;
            continue;
        }
        n_open -= 1;
        _ = c.g_ptr_array_remove_index(open, n_open);
        cur = te + 1;
    }
    if (n_open > 0) {
        const s = c.g_string_new(p_txt.*);
        while (n_open > 0) : (n_open -= 1) {
            _ = c.g_string_append_c(s, '<');
            _ = c.g_string_append_c(s, '/');
            _ = c.g_string_append(s, @as([*c]const u8, @ptrCast(open.*.pdata[n_open - 1])));
            _ = c.g_string_append_c(s, '>');
        }
        c.g_free(p_txt.*);
        p_txt.* = c.g_string_free(s, 0);
    }
    _ = c.g_ptr_array_free(open, 1);
}

fn subripTime(in: [*c]const u8, t: *u64) bool {
    var ts = in;
    while (ts[0] == ' ') ts += 1;
    var s = std.mem.zeroes([128]u8);
    _ = c.g_strlcpy(&s, ts, s.len);
    const end = c.strstr(&s, "-->");
    if (end != null) end[0] = 0;
    _ = c.g_strchomp(&s);
    _ = c.g_strdelimit(&s, " ", '0');
    _ = c.g_strdelimit(&s, ".", ',');
    var p = c.strchr(&s, ',');
    if (p == null) return false;
    if (off(p, &s) > "hhh:mm:ss,".len + 1) return false;
    p += 1;
    var len = c.strlen(p);
    if (len > 3) {
        p[3] = 0;
    } else while (len < 3) : (len += 1) {
        _ = c.g_strlcat(p + len, "0", 2);
    }
    var hour: c.guint = 0;
    var min: c.guint = 0;
    var sec: c.guint = 0;
    var msec: c.guint = 0;
    if (c.sscanf(&s, "%u:%u:%u,%u", &hour, &min, &sec, &msec) != 4) {
        hour = 0;
        if (c.sscanf(&s, "%u:%u,%u", &min, &sec, &msec) != 3) return false;
    }
    const whole: c.guint = hour *% 3600 +% min *% 60 +% sec;
    t.* = @as(u64, whole) *% SEC +% @as(u64, msec) *% MSEC;
    return true;
}

fn cueSettings(st: *State, settings: [*c]const u8) void {
    const parts = c.g_strsplit_set(settings, " \t", -1);
    var v: i16 = 0;
    var vertical = false;
    var alignment = false;
    var p = parts;
    while (p[0] != null) : (p += 1) {
        const s = p[0];
        switch (s[0]) {
            'T' => if (c.sscanf(s, "T:%hi%%", &v) > 0) {
                st.text_position = @truncate(@as(u16, @bitCast(v)));
            },
            'D' => if (c.strlen(s) > 2) {
                vertical = true;
                c.g_free(st.vertical);
                st.vertical = c.g_strdup(s + 2);
            },
            'L' => if (c.g_str_has_suffix(s, "%") != 0) {
                if (c.sscanf(s, "L:%hi%%", &v) > 0) st.line_position = @truncate(@as(u16, @bitCast(v)));
            } else {
                if (c.sscanf(s, "L:%hi", &v) > 0) st.line_number = v;
            },
            'S' => if (c.sscanf(s, "S:%hi%%", &v) > 0) {
                st.text_size = @truncate(@as(u16, @bitCast(v)));
            },
            'A' => if (c.strlen(s) > 2) {
                c.g_free(st.alignment);
                st.alignment = c.g_strdup(s + 2);
                alignment = true;
            },
            else => {},
        }
    }
    c.g_strfreev(parts);
    if (!vertical) {
        c.g_free(st.vertical);
        st.vertical = c.g_strdup("");
    }
    if (!alignment) {
        c.g_free(st.alignment);
        st.alignment = c.g_strdup("");
    }
}

fn appendLine(st: *State, line: [*c]const u8) void {
    if (st.buf.*.len != 0) _ = c.g_string_append_c(st.buf, '\n');
    _ = c.g_string_append(st.buf, line);
}

pub fn subrip(st: *State, line: [*c]const u8) [*c]u8 {
    switch (st.state) {
        0 => {
            var endptr: [*c]u8 = null;
            std.c._errno().* = 0;
            const id = c.g_ascii_strtoull(line, &endptr, 10);
            const e = std.c._errno().*;
            if (id == std.math.maxInt(u64) and e == c.ERANGE) {
                st.state = 1;
            } else if (id == 0 and e == c.EINVAL) {
                st.state = 1;
            } else if (endptr != line and endptr[0] == 0) st.state = 1;
            return null;
        },
        1 => {
            var ts: u64 = 0;
            var te: u64 = 0;
            const end_time = c.strstr(line, " --> ");
            if (end_time != null and subripTime(line, &ts) and subripTime(end_time + 5, &te) and st.start_time <= te) {
                st.state = 2;
                st.start_time = ts;
                st.duration = te -% ts;
            } else st.state = 0;
            return null;
        },
        2 => {
            if (!clip(st)) {
                st.state = 0;
                return null;
            }
            appendLine(st, line);
            if (c.strlen(line) != 0) return null;
            if (c.g_utf8_validate(st.buf.*.str, @intCast(st.buf.*.len), null) == 0) {
                _ = c.g_string_truncate(st.buf, 0);
                return null;
            }
            var ret = c.g_markup_escape_text(st.buf.*.str, @intCast(st.buf.*.len));
            _ = c.g_string_truncate(st.buf, 0);
            st.state = 0;
            const tags = st.allowed_tags orelse &.{};
            unescapeFormatting(ret, tags, st.allows_tag_attributes);
            removeUnhandledTags(ret);
            stripTrailingNewlines(ret);
            fixUpMarkup(&ret, tags);
            return ret;
        },
        else => {
            _ = cm.that(false, "parse_subrip", "NULL");
            return null;
        },
    }
}

pub fn lrc(st: *State, line: [*c]const u8) [*c]u8 {
    if (line[0] != '[') return null;
    var m: c.gint = 0;
    var s: c.gint = 0;
    var cc: c.gint = 0;
    if (c.sscanf(line, "[%u:%02u.%03u]", &m, &s, &cc) != 3 and c.sscanf(line, "[%u:%02u.%02u]", &m, &s, &cc) != 3) return null;
    const start = c.strchr(line, ']');
    if (start == null) return null;
    const milli: u64 = if (off(start, line) == 9) 10 else 1;
    st.start_time = c.gst_util_uint64_scale(@bitCast(@as(i64, m)), 60 * SEC, 1) +% c.gst_util_uint64_scale(@bitCast(@as(i64, s)), SEC, 1) +% c.gst_util_uint64_scale(@bitCast(@as(i64, cc)), milli * MSEC, 1);
    st.duration = cm.CLOCK_NONE;
    return c.g_strdup(start + 1);
}

pub fn webvtt(st: *State, line: [*c]const u8) [*c]u8 {
    if (st.state != 0 and st.state != 1) return subrip(st, line);
    var ts: u64 = 0;
    var te: u64 = 0;
    var settings: [*c]const u8 = null;
    const end_time = c.strstr(line, " --> ");
    if (end_time != null and subripTime(line, &ts) and subripTime(end_time + 5, &te) and st.start_time <= te) {
        st.state = 2;
        st.start_time = ts;
        st.duration = te -% ts;
        settings = c.strstr(end_time + 5, " ");
    } else st.state = 0;
    st.text_position = 0;
    st.text_size = 0;
    st.line_position = 0;
    st.line_number = 0;
    if (settings != null) {
        cueSettings(st, settings + 1);
    } else {
        c.g_free(st.vertical);
        st.vertical = c.g_strdup("");
        c.g_free(st.alignment);
        st.alignment = c.g_strdup("");
    }
    return null;
}

pub fn unescapeBr(text: [*c]u8) void {
    var read = text;
    var write = text;
    if (read[0] == 0 or read[1] == 0 or read[2] == 0 or read[3] == 0) return;
    while (true) {
        if (c.strncmp(read, "[br]", 4) == 0) {
            write[0] = '\n';
            read += 4;
        } else {
            write[0] = read[0];
            read += 1;
        }
        write += 1;
        if (read[0] == 0) break;
    }
    write[0] = 0;
}

pub fn subviewer(st: *State, line: [*c]const u8) [*c]u8 {
    switch (st.state) {
        0 => {
            var v = [_]c.guint{0} ** 8;
            if (c.sscanf(line, "%u:%u:%u.%u,%u:%u:%u.%u", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) == 8) {
                st.state = 1;
                st.start_time = (@as(u64, v[0]) *% 3600 +% v[1] *% 60 +% v[2]) *% SEC +% @as(u64, v[3]) *% MSEC;
                st.duration = (@as(u64, v[4]) *% 3600 +% v[5] *% 60 +% v[6]) *% SEC +% @as(u64, v[7]) *% MSEC -% st.start_time;
            }
            return null;
        },
        1 => {
            if (!clip(st)) {
                st.state = 0;
                return null;
            }
            appendLine(st, line);
            if (c.strlen(line) != 0) return null;
            const ret = c.g_strdup(st.buf.*.str);
            unescapeBr(ret);
            stripTrailingNewlines(ret);
            _ = c.g_string_truncate(st.buf, 0);
            st.state = 0;
            return ret;
        },
        else => unreachable,
    }
}

pub fn mpsub(st: *State, line: [*c]const u8) [*c]u8 {
    switch (st.state) {
        0 => {
            var t1: f32 = 0;
            var t2: f32 = 0;
            if (c.sscanf(line, "%f %f", &t1, &t2) == 2) {
                st.state = 1;
                const secs: f32 = @floatFromInt(SEC);
                const add = @as(f32, @floatFromInt(st.duration)) + secs * t1;
                st.start_time = toU64(@as(f32, @floatFromInt(st.start_time)) + add);
                st.duration = toU64(secs * t2);
            }
            return null;
        },
        1 => {
            if (!clip(st)) {
                st.state = 0;
                return null;
            }
            appendLine(st, line);
            if (c.strlen(line) != 0) return null;
            const ret = c.g_strdup(st.buf.*.str);
            _ = c.g_string_truncate(st.buf, 0);
            st.state = 0;
            return ret;
        },
        else => unreachable,
    }
}

fn cvtt(x: f32) i64 {
    if (std.math.isNan(x) or x >= 9223372036854775808.0 or x < -9223372036854775808.0) return std.math.minInt(i64);
    return @intFromFloat(x);
}

fn toU64(x: f32) u64 {
    const top: f32 = 9223372036854775808.0;
    if (std.math.isNan(x) or x < top) return @bitCast(cvtt(x));
    return @as(u64, @bitCast(cvtt(x - top))) ^ 0x8000000000000000;
}

pub fn dks(st: *State, line: [*c]const u8) [*c]u8 {
    var h: c.guint = 0;
    var m: c.guint = 0;
    var s: c.guint = 0;
    switch (st.state) {
        0 => {
            if (c.sscanf(line, "[%u:%u:%u]", &h, &m, &s) == 3) {
                st.start_time = (@as(u64, h) *% 3600 +% m *% 60 +% s) *% SEC;
                var text = line;
                while (text[0] != 0 and text[0] != ']') text += 1;
                if (text[0] == ']') text += 1;
                if (text[0] != 0) {
                    st.state = 1;
                    _ = c.g_string_append(st.buf, text);
                }
            }
            return null;
        },
        1 => {
            if (c.sscanf(line, "[%u:%u:%u]", &h, &m, &s) != 3) return null;
            st.state = 0;
            st.duration = (@as(u64, h) *% 3600 +% m *% 60 +% s) *% SEC -% st.start_time;
            if (!clip(st)) return null;
            const ret = c.g_strdup(st.buf.*.str);
            _ = c.g_string_truncate(st.buf, 0);
            unescapeBr(ret);
            return ret;
        },
        else => unreachable,
    }
}

fn tmplayerFlush(st: *State) [*c]u8 {
    const ret = c.g_strndup(st.buf.*.str, st.buf.*.len);
    _ = c.g_strdelimit(ret, "|", '\n');
    _ = c.g_string_truncate(st.buf, 0);
    return ret;
}

pub fn tmplayer(st: *State, line: [*c]const u8) [*c]u8 {
    const line_num = st.state;
    st.state += 1;
    var ts: u64 = cm.CLOCK_NONE;
    var text: [*c]const u8 = null;
    var ret: [*c]u8 = null;
    var divc: u8 = 0;
    var h: c.guint = 0;
    var m: c.guint = 0;
    var s: c.guint = 0;
    var l: c.guint = 1;
    if (c.sscanf(line, "%u:%02u:%02u,%u%c", &h, &m, &s, &l, &divc) == 5 and divc == '=') {
        ts = SEC *% @as(u64, (h *% 60 +% m) *% 60 +% s);
        text = c.strchr(line, '=');
    } else if (c.sscanf(line, "%u:%02u:%02u%c", &h, &m, &s, &divc) == 4 and (divc == '=' or divc == ':')) {
        ts = SEC *% @as(u64, (h *% 60 +% m) *% 60 +% s);
        text = c.strchr(line + 6, divc);
    } else if (line[0] == 0 and st.buf.*.len > 0 and st.start_time != cm.CLOCK_NONE) {
        ret = tmplayerFlush(st);
        st.duration = cm.CLOCK_NONE;
        return ret;
    } else return null;
    if (text == null or text[1] == 0 or (l == 1 and st.buf.*.len > 0)) {
        if (st.start_time != cm.CLOCK_NONE and st.start_time < ts and line_num > 0) {
            ret = tmplayerFlush(st);
            st.duration = ts -% st.start_time;
            if (text != null) _ = c.g_string_append(st.buf, text + 1);
        }
    } else {
        if (l > 1) _ = c.g_string_append_c(st.buf, '\n');
        _ = c.g_string_append(st.buf, text + 1);
        st.start_time = ts;
    }
    return ret;
}

pub fn mpl2(st: *State, orig: [*c]const u8) [*c]u8 {
    st.state += 1;
    var dc_start: c.gint = 0;
    var dc_stop: c.gint = 0;
    if (c.sscanf(orig, "[%u][%u]", &dc_start, &dc_stop) != 2) return null;
    st.start_time = SEC / 10 *% @as(u64, @bitCast(@as(i64, dc_start)));
    st.duration = (SEC / 10 *% @as(u64, @bitCast(@as(i64, dc_stop)))) -% st.start_time;
    var line = c.strchr(orig, ']');
    if (line == null) return null;
    line = c.strchr(line + 1, ']');
    if (line == null) return null;
    line += 1;
    const markup = c.g_string_new(null);
    while (true) {
        while (line[0] == ' ' or line[0] == '\t') line += 1;
        var italics = false;
        if (line[0] == '/') {
            italics = true;
            _ = c.g_string_append(markup, "<i>");
            line += 1;
        }
        const sep = c.strchr(line, '|');
        const chunk = c.g_markup_escape_text(line, if (sep != null) @intCast(off(sep, line)) else -1);
        _ = c.g_string_append(markup, chunk);
        c.g_free(chunk);
        if (italics) _ = c.g_string_append(markup, "</i>");
        if (sep == null) break;
        _ = c.g_string_append(markup, "\n");
        line = sep + 1;
    }
    return c.g_strstrip(c.g_string_free(markup, 0));
}
