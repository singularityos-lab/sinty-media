const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const fm = @import("formats.zig");

const SEC: u64 = c.GST_SECOND;
const MIN: u64 = 60 * SEC;
const HOUR: u64 = 60 * MIN;

const Context = struct {
    timescale: c.gint = 1000,
    absolute: bool = true,
    start_time: u64 = 0,
    markup_open: bool = false,
    need_markup: bool = false,
    font: [*c]u8 = null,
    font_size: c.gint = 12,
    bg_color: [*c]u8 = null,
    fg_color: [*c]u8 = null,
    bold: bool = false,
    italic: bool = false,
};

fn ctx(st: *fm.State) *Context {
    return @ptrCast(@alignCast(st.user_data.?));
}

pub fn init(st: *fm.State) void {
    const x: *Context = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Context))));
    x.* = .{};
    st.user_data = x;
}

pub fn deinit(st: *fm.State) void {
    if (st.user_data == null) return;
    const x = ctx(st);
    c.g_free(x.font);
    c.g_free(x.bg_color);
    c.g_free(x.fg_color);
    c.g_free(x);
    st.user_data = null;
}

fn toColon(line: [*c]const u8) ?usize {
    var i: usize = 0;
    while (line[i] != ':' and line[i] != '}') i += 1;
    if (line[i] != ':') return null;
    return i + 1;
}

fn readStr(line: [*c]const u8, end: [*c]const u8) [*c]u8 {
    var i = toColon(line) orelse return null;
    while (line[i] == ' ') i += 1;
    return c.g_strndup(line + i, @intFromPtr(end) -% @intFromPtr(line + i));
}

fn readInt(line: [*c]const u8) c.gint {
    const i = toColon(line) orelse return 0;
    return c.atoi(line + i);
}

fn readColor(line: [*c]const u8, r: *c.gint, g: *c.gint, b: *c.gint) bool {
    var i = toColon(line) orelse return false;
    r.* = c.atoi(line + i);
    while (line[i] != '}' and line[i] != ',') i += 1;
    if (line[i] != ',') return false;
    i += 1;
    g.* = c.atoi(line + i);
    while (line[i] != '}' and line[i] != ',') i += 1;
    if (line[i] != ',') return false;
    i += 1;
    b.* = c.atoi(line + i);
    return true;
}

fn makeColor(r: c.gint, g: c.gint, b: c.gint) [*c]u8 {
    return c.g_strdup_printf("#%02X%02X%02X", @divTrunc(r, 256), @divTrunc(g, 256), @divTrunc(b, 256));
}

fn parseTag(st: *fm.State, line: [*c]const u8, index: *c.gint) bool {
    const x = ctx(st);
    const at = line + @as(usize, @intCast(index.*));
    const next = c.strchr(at, '}');
    if (next == null) return false;
    const next_index: c.gint = @intCast(1 + (@intFromPtr(next) - @intFromPtr(line)));
    index.* += 1;
    const p = line + @as(usize, @intCast(index.*));
    const close = line + @as(usize, @intCast(next_index - 1));
    var r: c.gint = 0;
    var g: c.gint = 0;
    var b: c.gint = 0;
    if (c.strncmp(p, "QTtext", 6) == 0) {} else if (c.strncmp(p, "font", 4) == 0) {
        const s = readStr(p + 4, close);
        if (s != null) {
            c.g_free(x.font);
            x.font = s;
            x.need_markup = true;
        }
    } else if (c.strncmp(p, "size", 4) == 0) {
        const v = readInt(p + 4);
        x.font_size = if (v == 0) 12 else v;
        x.need_markup = true;
    } else if (c.strncmp(p, "textColor", 9) == 0) {
        if (readColor(p + 9, &r, &g, &b)) x.fg_color = makeColor(r, g, b);
        x.need_markup = true;
    } else if (c.strncmp(p, "backColor", 9) == 0) {
        if (readColor(p + 9, &r, &g, &b)) {
            x.bg_color = makeColor(r, g, b);
        } else {
            c.g_free(x.bg_color);
            x.bg_color = null;
        }
        x.need_markup = true;
    } else if (c.strncmp(p, "plain", 5) == 0) {
        x.bold = false;
        x.italic = false;
        x.need_markup = true;
    } else if (c.strncmp(p, "bold", 4) == 0) {
        x.bold = true;
        x.italic = false;
        x.need_markup = true;
    } else if (c.strncmp(p, "italic", 6) == 0) {
        x.bold = false;
        x.italic = true;
        x.need_markup = true;
    } else if (c.strncmp(p, "timescale", 9) == 0) {
        const v = readInt(p + 9);
        x.timescale = if (v == 0) 1000 else v;
    } else if (c.strncmp(p, "timestamps", 10) == 0) {
        const found = c.strstr(p + 10, "relative");
        x.absolute = !(@intFromPtr(found) < @intFromPtr(line + @as(usize, @intCast(next_index))));
    }
    index.* = next_index;
    return true;
}

fn parseTimestamp(st: *fm.State, line: [*c]const u8) u64 {
    const x = ctx(st);
    var hour: c.guint = 0;
    var min: c.guint = 0;
    var sec: c.guint = 0;
    var dec: c.guint = 0;
    const ret = c.sscanf(line, "[%u:%u:%u.%u]", &hour, &min, &sec, &dec);
    if (ret != 3 and ret != 4) return 0;
    if (ret == 3) dec = 0;
    var ts = c.gst_util_uint64_scale(dec, SEC, @bitCast(@as(i64, x.timescale)));
    ts +%= @as(u64, sec) *% SEC;
    ts +%= std.math.mul(u64, min, MIN) catch return cm.CLOCK_NONE;
    ts +%= std.math.mul(u64, hour, HOUR) catch return cm.CLOCK_NONE;
    return ts;
}

fn openMarkup(st: *fm.State) void {
    const x = ctx(st);
    _ = c.g_string_append(st.buf, "<span");
    if (x.font != null) {
        c.g_string_append_printf(st.buf, " font='%s %d'", x.font, x.font_size);
    } else c.g_string_append_printf(st.buf, " font='%d'", x.font_size);
    if (x.bg_color != null) c.g_string_append_printf(st.buf, " bgcolor='%s'", x.bg_color);
    if (x.fg_color != null) c.g_string_append_printf(st.buf, " color='%s'", x.fg_color);
    if (x.bold) _ = c.g_string_append(st.buf, " weight='bold'");
    if (x.italic) _ = c.g_string_append(st.buf, " style='italic'");
    _ = c.g_string_append(st.buf, ">");
}

fn prepareText(st: *fm.State) void {
    const x = ctx(st);
    if (st.buf == null) {
        st.buf = c.g_string_sized_new(256);
    } else _ = c.g_string_append(st.buf, "\n");
    if (x.need_markup) {
        if (x.markup_open) _ = c.g_string_append(st.buf, "</span>");
        openMarkup(st);
        x.markup_open = true;
    }
}

fn takeText(st: *fm.State) [*c]u8 {
    const x = ctx(st);
    if (st.buf == null) return null;
    if (x.markup_open) _ = c.g_string_append(st.buf, "</span>");
    const ret = c.g_string_free(st.buf, 0);
    st.buf = null;
    x.markup_open = false;
    return ret;
}

pub fn parse(st: *fm.State, line: [*c]const u8) [*c]u8 {
    const x = ctx(st);
    var ret: [*c]u8 = null;
    var i: c.gint = 0;
    while (line[@intCast(i)] != 0) {
        const ch = line[@intCast(i)];
        if (ch == '{') {
            if (!parseTag(st, line, &i)) break;
        } else if (ch == '[') {
            const ts = parseTimestamp(st, line + @as(usize, @intCast(i)));
            if (st.buf != null) {
                ret = takeText(st);
                st.duration = if (x.absolute) ts -% x.start_time else ts;
                st.start_time = x.start_time;
            }
            st.buf = null;
            if (ts != 0) {
                if (x.absolute) x.start_time = ts else x.start_time +%= ts;
            }
            break;
        } else if (ch == ' ' or ch == '\t') {
            i += 1;
        } else {
            prepareText(st);
            _ = c.g_string_append(st.buf, line + @as(usize, @intCast(i)));
            break;
        }
    }
    return ret;
}
