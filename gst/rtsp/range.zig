const std = @import("std");
const c = @import("../c.zig").c;
const that = @import("defs.zig").that;

comptime {
    @import("../abi.zig").check(@This());
}

const Range = c.GstRTSPTimeRange;
const Time = c.GstRTSPTime;
const Time2 = c.GstRTSPTime2;
const OK = c.GST_RTSP_OK;
const EINVAL = c.GST_RTSP_EINVAL;
const NONE: u64 = std.math.maxInt(u64);
const SECOND: f64 = @floatFromInt(c.GST_SECOND);
const SEC: u64 = c.GST_SECOND;

fn strtod(s: [*c]const u8) f64 {
    var buf = [_]u8{0} ** c.G_ASCII_DTOSTR_BUF_SIZE;
    _ = c.g_strlcpy(&buf, s, buf.len);
    _ = c.g_strdelimit(&buf, ",", '.');
    return c.g_ascii_strtod(&buf, null);
}

fn nptTime(s: [*c]const u8, t: *Time) c.GstRTSPResult {
    if (c.strncmp(s, "now", 3) == 0) {
        t.type = c.GST_RTSP_TIME_NOW;
    } else if (s[0] == 0 or s[0] == '-') {
        t.type = c.GST_RTSP_TIME_END;
    } else if (c.strstr(s, ":") != null) {
        var h: c_int = 0;
        var m: c_int = 0;
        if (c.sscanf(s, "%2d:%2d:", &h, &m) != 2) return EINVAL;
        var p: [*c]const u8 = c.strchr(s, ':');
        p = c.strchr(p + 1, ':');
        if (p == null) return EINVAL;
        t.type = c.GST_RTSP_TIME_SECONDS;
        t.seconds = @as(f64, @floatFromInt((h * 60 + m) * 60)) + strtod(p + 1);
    } else {
        t.type = c.GST_RTSP_TIME_SECONDS;
        t.seconds = strtod(s);
    }
    return OK;
}

fn nptRange(s: [*c]const u8, r: *Range) c.GstRTSPResult {
    r.unit = c.GST_RTSP_RANGE_NPT;
    const dash: [*c]const u8 = c.strstr(s, "-");
    if (dash == null) return EINVAL;
    const res = nptTime(s, &r.min);
    if (res != OK) return res;
    const res2 = nptTime(dash + 1, &r.max);
    if (r.min.type == c.GST_RTSP_TIME_END and r.max.type == c.GST_RTSP_TIME_END) return EINVAL;
    return res2;
}

fn utcTime(s: [*c]const u8, t: *Time, t2: *Time2) c.GstRTSPResult {
    if (s[0] == 0) {
        t.type = c.GST_RTSP_TIME_END;
        return OK;
    }
    const tee: [*c]const u8 = c.strchr(s, 'T');
    if (tee == null or tee != s + 8) return EINVAL;
    if (c.strchr(tee + 1, 'Z') == null) return EINVAL;
    t.type = c.GST_RTSP_TIME_UTC;
    var y: c_int = 0;
    var mo: c_int = 0;
    var d: c_int = 0;
    var h: c_int = 0;
    var mi: c_int = 0;
    var sec: f64 = 0;
    if (c.sscanf(s, "%4d%2d%2dT%2d%2d%lfZ", &y, &mo, &d, &h, &mi, &sec) != 6) return EINVAL;
    t2.year = @bitCast(y);
    t2.month = @intCast(mo);
    t2.day = @intCast(d);
    t.seconds = @as(f64, @floatFromInt((h * 60 + mi) * 60)) + sec;
    return OK;
}

fn utcRange(s: [*c]const u8, r: *Range) c.GstRTSPResult {
    r.unit = c.GST_RTSP_RANGE_CLOCK;
    const dash: [*c]const u8 = c.strstr(s, "-");
    if (dash == null or dash == s) return EINVAL;
    const res = utcTime(s, &r.min, &r.min2);
    if (res != OK) return res;
    return utcTime(dash + 1, &r.max, &r.max2);
}

fn smpteTime(s: [*c]const u8, t: *Time, t2: *Time2, limit: [*c]const u8) c.GstRTSPResult {
    if (s[0] == 0) {
        t.type = c.GST_RTSP_TIME_END;
        return OK;
    }
    var h: c_int = 0;
    var m: c_int = 0;
    var sec: c_int = 0;
    if (c.sscanf(s, "%2d:%2d:%2d", &h, &m, &sec) != 3) return EINVAL;
    t.type = c.GST_RTSP_TIME_FRAMES;
    t.seconds = @floatFromInt((h * 60 + m) * 60 + sec);
    var p: [*c]const u8 = c.strchr(s, ':');
    p = c.strchr(p + 1, ':');
    p = c.strchr(p + 1, ':');
    if (p != null and (limit == null or @intFromPtr(p) < @intFromPtr(limit))) t2.frames = strtod(p + 1);
    return OK;
}

fn smpteRange(s: [*c]const u8, r: *Range) c.GstRTSPResult {
    const dash: [*c]const u8 = c.strstr(s, "-");
    if (dash == null or dash == s) return EINVAL;
    const res = smpteTime(s, &r.min, &r.min2, dash);
    if (res != OK) return res;
    return smpteTime(dash + 1, &r.max, &r.max2, null);
}

pub export fn gst_rtsp_range_parse(text: [*c]const u8, out: [*c][*c]Range) c.GstRTSPResult {
    const f = "gst_rtsp_range_parse";
    if (!that(text != null, f, "rangestr != NULL")) return EINVAL;
    if (!that(out != null, f, "range != NULL")) return EINVAL;
    const r: *Range = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Range))));
    const has = struct {
        fn g(s: [*c]const u8, p: [*:0]const u8) bool {
            return c.g_str_has_prefix(s, p) != 0;
        }
    }.g;
    var res: c.GstRTSPResult = EINVAL;
    if (has(text, "npt=")) {
        res = nptRange(text + 4, r);
    } else if (has(text, "clock=")) {
        res = utcRange(text + 6, r);
    } else if (has(text, "smpte=")) {
        r.unit = c.GST_RTSP_RANGE_SMPTE;
        res = smpteRange(text + 6, r);
    } else if (has(text, "smpte-30-drop=")) {
        r.unit = c.GST_RTSP_RANGE_SMPTE_30_DROP;
        res = smpteRange(text + 14, r);
    } else if (has(text, "smpte-25=")) {
        r.unit = c.GST_RTSP_RANGE_SMPTE_25;
        res = smpteRange(text + 9, r);
    }
    if (res != OK) {
        gst_rtsp_range_free(r);
        return EINVAL;
    }
    out.* = r;
    return OK;
}

fn appendDouble(s: [*c]c.GString, value: f64, precision: c.guint) void {
    var buf = [_]u8{0} ** c.G_ASCII_DTOSTR_BUF_SIZE;
    const prec = precision + 1;
    var v = value;
    if (v != 0.0) v += 4.9 * std.math.pow(f64, 10.0, -@as(f64, @floatFromInt(prec)));
    _ = c.g_ascii_dtostr(&buf, buf.len, v);
    if (std.mem.indexOfScalar(u8, &buf, '.')) |dot| {
        if (dot + prec < buf.len) buf[dot + prec] = 0;
        var len = std.mem.indexOfScalar(u8, &buf, 0).?;
        while (buf[len - 1] == '0') {
            len -= 1;
            buf[len] = 0;
        }
        if (buf[len - 1] == '.') {
            len -= 1;
            buf[len] = 0;
        }
    }
    _ = c.g_string_append(s, &buf);
}

fn timeText(t: *const Time, t2: *const Time2, s: [*c]c.GString) bool {
    switch (t.type) {
        c.GST_RTSP_TIME_SECONDS => appendDouble(s, t.seconds + @as(f64, if (t.seconds != 0) 0.00000000005 else 0), 9),
        c.GST_RTSP_TIME_NOW => _ = c.g_string_append(s, "now"),
        c.GST_RTSP_TIME_END => {},
        c.GST_RTSP_TIME_FRAMES => {
            const sec: i64 = @intFromFloat(t.seconds);
            const si: c_int = @truncate(sec);
            c.g_string_append_printf(s, "%d:%02d:%02d", @divTrunc(si, 3600), @as(c_int, @truncate(@divTrunc(@rem(sec, 3600), 60))), @rem(si, 60));
            if (t2.frames > 0.0) {
                c.g_string_append_printf(s, ":%s", @as([*c]const u8, if (t2.frames < 10) "0" else ""));
                appendDouble(s, t2.frames + 0.005, 2);
            }
        },
        c.GST_RTSP_TIME_UTC => {
            var sec: i64 = @intFromFloat(t.seconds);
            const h: c_int = @truncate(@divTrunc(sec, 3600));
            sec -= @as(i64, h) * 3600;
            const m: c_int = @truncate(@divTrunc(sec, 60));
            sec = (@as(i64, h) * 60 + m) * 60;
            var rest = t.seconds - @as(f64, @floatFromInt(sec));
            if (rest != 0) rest += 0.00000000005;
            c.g_string_append_printf(s, "%04d%02d%02dT%02d%02d%s", t2.year, t2.month, t2.day, h, m, @as([*c]const u8, if (rest < 10) "0" else ""));
            appendDouble(s, rest, 9);
            _ = c.g_string_append(s, "Z");
        },
        else => return false,
    }
    return true;
}

pub export fn gst_rtsp_range_to_string(r: [*c]const Range) [*c]u8 {
    if (!that(r != null, "gst_rtsp_range_to_string", "range != NULL")) return null;
    const rr: *const Range = @ptrCast(r);
    const head: [*:0]const u8 = switch (r[0].unit) {
        c.GST_RTSP_RANGE_NPT => "npt=",
        c.GST_RTSP_RANGE_SMPTE, c.GST_RTSP_RANGE_SMPTE_30_DROP => "smpte=",
        c.GST_RTSP_RANGE_SMPTE_25 => "smpte-25=",
        c.GST_RTSP_RANGE_CLOCK => "clock=",
        else => {
            c.g_log(@import("defs.zig").DOMAIN, c.G_LOG_LEVEL_WARNING, "time range unit not yet implemented");
            return null;
        },
    };
    const s = c.g_string_new(head);
    if (!timeText(&rr.min, &rr.min2, s) or blk: {
        _ = c.g_string_append(s, "-");
        break :blk !timeText(&rr.max, &rr.max2, s);
    }) {
        _ = c.g_string_free(s, 1);
        return null;
    }
    return c.g_string_free(s, 0);
}

pub export fn gst_rtsp_range_free(r: [*c]Range) void {
    if (!that(r != null, "gst_rtsp_range_free", "range != NULL")) return;
    c.g_free(r);
}

fn seconds(t: *const Time) c.GstClockTime {
    if (t.seconds < @as(f64, @floatFromInt(std.math.maxInt(c_int)))) {
        var n: c_int = 0;
        var d: c_int = 0;
        c.gst_util_double_to_fraction(t.seconds, &n, &d);
        return c.gst_util_uint64_scale_int(c.GST_SECOND, n, d);
    }
    return c.gst_util_gdouble_to_guint64(t.seconds * SECOND);
}

fn frames(t2: *const Time2, unit: c.GstRTSPRangeUnit) c.GstClockTime {
    var n: c_int = 0;
    var d: c_int = 0;
    c.gst_util_double_to_fraction(t2.frames, &n, &d);
    if (unit == c.GST_RTSP_RANGE_SMPTE_25) {
        d *%= 25;
    } else {
        n *%= 1001;
        d *%= 30003;
    }
    return c.gst_util_uint64_scale_int(c.GST_SECOND, n, d);
}

fn timeOf(unit: c.GstRTSPRangeUnit, t: *const Time, t2: *const Time2) c.GstClockTime {
    return switch (t.type) {
        c.GST_RTSP_TIME_SECONDS => seconds(t),
        c.GST_RTSP_TIME_UTC => blk: {
            const bt = c.g_date_time_new_utc(1900, 1, 1, 0, 0, 0.0);
            const dt = c.g_date_time_new_utc(@bitCast(t2.year), @intCast(t2.month), @intCast(t2.day), 0, 0, 0.0);
            const span = c.g_date_time_difference(dt, bt);
            c.g_date_time_unref(bt);
            c.g_date_time_unref(dt);
            break :blk seconds(t) +% @as(u64, @bitCast(span *% 1000));
        },
        c.GST_RTSP_TIME_FRAMES => seconds(t) +% frames(t2, unit),
        else => NONE,
    };
}

pub export fn gst_rtsp_range_get_times(r: [*c]const Range, min: [*c]c.GstClockTime, max: [*c]c.GstClockTime) c.gboolean {
    if (!that(r != null, "gst_rtsp_range_get_times", "range != NULL")) return 0;
    const rr: *const Range = @ptrCast(r);
    if (min != null) min.* = timeOf(rr.unit, &rr.min, &rr.min2);
    if (max != null) max.* = timeOf(rr.unit, &rr.max, &rr.max2);
    return 1;
}

fn setTime(t: *Time, t2: *Time2, unit: c.GstRTSPRangeUnit, ct: c.GstClockTime) void {
    t.* = std.mem.zeroes(Time);
    t2.* = std.mem.zeroes(Time2);
    if (ct == NONE) {
        t.type = c.GST_RTSP_TIME_END;
        return;
    }
    const sub: f64 = @floatFromInt(ct % SEC);
    switch (unit) {
        c.GST_RTSP_RANGE_SMPTE, c.GST_RTSP_RANGE_SMPTE_30_DROP => {
            t.seconds = @floatFromInt(ct / SEC);
            t2.frames = 30003 * sub / (1001 * SECOND);
            t.type = c.GST_RTSP_TIME_FRAMES;
        },
        c.GST_RTSP_RANGE_SMPTE_25 => {
            t.seconds = @floatFromInt(ct / SEC);
            t2.frames = 25 * sub / SECOND;
            t.type = c.GST_RTSP_TIME_FRAMES;
        },
        c.GST_RTSP_RANGE_NPT => {
            t.seconds = @as(f64, @floatFromInt(ct)) / SECOND;
            t.type = c.GST_RTSP_TIME_SECONDS;
        },
        c.GST_RTSP_RANGE_CLOCK => {
            const bt = c.g_date_time_new_utc(1900, 1, 1, 0, 0, 0.0);
            const dt = c.g_date_time_add_seconds(bt, @floatFromInt(ct / SEC));
            t2.year = @bitCast(c.g_date_time_get_year(dt));
            t2.month = @intCast(c.g_date_time_get_month(dt));
            t2.day = @intCast(c.g_date_time_get_day_of_month(dt));
            t.seconds = @floatFromInt(c.g_date_time_get_hour(dt) * 3600);
            t.seconds += @floatFromInt(c.g_date_time_get_minute(dt) * 60);
            t.seconds += c.g_date_time_get_seconds(dt);
            t.seconds += sub / SECOND;
            t.type = c.GST_RTSP_TIME_UTC;
            c.g_date_time_unref(bt);
            c.g_date_time_unref(dt);
        },
        else => {},
    }
    if (t.seconds < 0.000000001) t.seconds = 0;
    if (t2.frames < 0.000000001) t2.frames = 0;
}

pub export fn gst_rtsp_range_convert_units(rp: [*c]Range, unit: c.GstRTSPRangeUnit) c.gboolean {
    const r: *Range = @ptrCast(rp);
    if (r.unit == unit) return 1;
    if (r.min.type == c.GST_RTSP_TIME_NOW or r.max.type == c.GST_RTSP_TIME_NOW) return 0;
    setTime(&r.min, &r.min2, unit, timeOf(r.unit, &r.min, &r.min2));
    setTime(&r.max, &r.max2, unit, timeOf(r.unit, &r.max, &r.max2));
    r.unit = unit;
    return 1;
}
