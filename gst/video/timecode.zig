const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const TC = c.GstVideoTimeCode;
const Interval = c.GstVideoTimeCodeInterval;
const DROP = c.GST_VIDEO_TIME_CODE_FLAGS_DROP_FRAME;
const INTERLACED = c.GST_VIDEO_TIME_CODE_FLAGS_INTERLACED;
const SECOND: i64 = c.GST_SECOND;
const FILE = "../gst-libs/gst/video/gstvideotimecode.c";

fn assert(ok: bool, line: c_int, comptime func: [*:0]const u8, comptime expr: [*:0]const u8) void {
    if (!ok) c.g_assertion_message_expr(check.DOMAIN, FILE, line, func, expr);
}

fn ug(v: u64) c.gint {
    return @bitCast(@as(u32, @truncate(v)));
}

fn ig(v: c.guint) c.gint {
    return @bitCast(v);
}

fn u(v: i64) u64 {
    return @bitCast(v);
}

fn valid(tc: *allowzero const TC) bool {
    const cfg = tc.config;
    if (cfg.fps_n == 0 or cfg.fps_d == 0) return false;
    if (tc.hours >= 24 or tc.minutes >= 60 or tc.seconds >= 60) return false;
    const fr = (cfg.fps_n +% (cfg.fps_d >> 1)) / cfg.fps_d;
    if (cfg.fps_d > cfg.fps_n) {
        if (tc.frames > 0) return false;
        const s: u64 = tc.seconds +% 60 *% (tc.minutes +% 60 *% tc.hours);
        if ((s *% cfg.fps_n) % cfg.fps_d != 0) return false;
    } else if (tc.frames >= fr and (cfg.fps_n != 0 or cfg.fps_d != 1)) return false;
    if (cfg.fps_d == 1001) {
        if (cfg.fps_n % 30000 != 0 and cfg.fps_n != 24000) return false;
    } else if (cfg.fps_n >= cfg.fps_d and cfg.fps_n % cfg.fps_d != 0) return false;
    if (cfg.flags & DROP != 0 and (cfg.fps_d != 1001 or cfg.fps_n == 24000)) return false;
    if (cfg.flags & DROP != 0 and tc.minutes % 10 != 0 and tc.seconds == 0 and tc.frames < fr / 15) return false;
    return true;
}

pub export fn gst_video_time_code_is_valid(tc: [*c]const TC) c.gboolean {
    if (!check.that(tc != null, "gst_video_time_code_is_valid", "tc != NULL")) return 0;
    return @intFromBool(valid(&tc[0]));
}

fn checkValid(tc: [*c]const TC, comptime fname: []const u8) bool {
    return check.that(gst_video_time_code_is_valid(tc) != 0, fname, "gst_video_time_code_is_valid (tc)");
}

pub export fn gst_video_time_code_to_string(tc: [*c]const TC) [*c]u8 {
    const t = &tc[0];
    const top = !(t.config.flags & INTERLACED != 0 and t.field_count == 1);
    const sep: c_int = if (t.config.flags & DROP != 0) (if (top) ';' else ',') else (if (top) ':' else '.');
    return c.g_strdup_printf("%02d:%02d:%02d%c%02d", t.hours, t.minutes, t.seconds, sep, t.frames);
}

pub export fn gst_video_time_code_to_date_time(tc: [*c]const TC) ?*c.GDateTime {
    if (!checkValid(tc, "gst_video_time_code_to_date_time")) return null;
    const t = &tc[0];
    if (t.config.latest_daily_jam == null) {
        c.g_free(gst_video_time_code_to_string(tc));
        return null;
    }
    var ret = c.g_date_time_ref(t.config.latest_daily_jam);
    var ns = gst_video_time_code_nsec_since_daily_jam(tc);
    const hours: c.gint = @truncate(@as(i64, @bitCast(ns / u(SECOND) / 60 / 60)));
    ns -%= u(@as(i64, hours) *% SECOND *% 60 *% 60);
    const minutes: c.gint = @truncate(@as(i64, @bitCast(ns / u(SECOND) / 60)));
    ns -%= u(@as(i64, minutes) *% SECOND *% 60);
    var seconds: f64 = @as(f64, @floatFromInt(ns)) / 1000000000.0;
    if (t.config.flags & INTERLACED != 0 and t.field_count == 1) {
        var sub: f64 = 0;
        c.gst_util_fraction_to_double(ig(t.config.fps_d), ig(2 *% t.config.fps_n), &sub);
        seconds -= sub;
    }
    var ret2 = c.g_date_time_add_seconds(ret, seconds);
    c.g_date_time_unref(ret);
    ret = c.g_date_time_add_minutes(ret2, minutes);
    c.g_date_time_unref(ret2);
    ret2 = c.g_date_time_add_hours(ret, hours);
    c.g_date_time_unref(ret);
    return ret2;
}

pub export fn gst_video_time_code_init_from_date_time(tc: [*c]TC, fps_n: c.guint, fps_d: c.guint, dt: ?*c.GDateTime, flags: c.GstVideoTimeCodeFlags, field_count: c.guint) void {
    if (gst_video_time_code_init_from_date_time_full(tc, fps_n, fps_d, dt, flags, field_count) == 0)
        _ = check.that(gst_video_time_code_is_valid(tc) != 0, "gst_video_time_code_init_from_date_time", "gst_video_time_code_is_valid (tc)");
}

pub export fn gst_video_time_code_init_from_date_time_full(tc: [*c]TC, fps_n: c.guint, fps_d: c.guint, dt: ?*c.GDateTime, flags: c.GstVideoTimeCodeFlags, field_count: c.guint) c.gboolean {
    const fname = "gst_video_time_code_init_from_date_time_full";
    if (!check.that(tc != null, fname, "tc != NULL")) return 0;
    if (!check.that(dt != null, fname, "dt != NULL")) return 0;
    if (!check.that(fps_n != 0 and fps_d != 0, fname, "fps_n != 0 && fps_d != 0")) return 0;
    gst_video_time_code_clear(tc);
    const jam = c.g_date_time_new_local(c.g_date_time_get_year(dt), c.g_date_time_get_month(dt), c.g_date_time_get_day_of_month(dt), 0, 0, 0.0);
    if (fps_d > fps_n) {
        const s32: c.gint = c.g_date_time_get_second(dt) +% 60 *% (c.g_date_time_get_minute(dt) +% 60 *% c.g_date_time_get_hour(dt));
        var sec: u64 = u(s32);
        sec -%= (sec *% fps_n) % fps_d;
        var min = sec / 60;
        sec %= 60;
        const hour = min / 60;
        min %= 60;
        gst_video_time_code_init(tc, fps_n, fps_d, jam, flags, @truncate(hour), @truncate(min), @truncate(sec), 0, field_count);
    } else {
        var frames = c.gst_util_uint64_scale_round(u(@as(i64, c.g_date_time_get_microsecond(dt)) *% 1000), fps_n, u(@as(i64, fps_d) *% SECOND));
        var add = false;
        if ((frames == fps_n and fps_d == 1) or (frames == fps_n / 1000 and fps_d == 1001)) {
            frames -%= 1;
            add = true;
        }
        gst_video_time_code_init(tc, fps_n, fps_d, jam, flags, @bitCast(c.g_date_time_get_hour(dt)), @bitCast(c.g_date_time_get_minute(dt)), @bitCast(c.g_date_time_get_second(dt)), @truncate(frames), field_count);
        const t = &tc[0];
        if (t.config.flags & DROP != 0) {
            const df = (t.config.fps_n +% (t.config.fps_d >> 1)) / (15 *% t.config.fps_d);
            if (t.minutes % 10 != 0 and t.seconds == 0 and t.frames < df) t.frames = df;
        }
        if (add) gst_video_time_code_increment_frame(tc);
    }
    c.g_date_time_unref(jam);
    return gst_video_time_code_is_valid(tc);
}

pub export fn gst_video_time_code_nsec_since_daily_jam(tc: [*c]const TC) c_ulong {
    if (!checkValid(tc, "gst_video_time_code_nsec_since_daily_jam")) return std.math.maxInt(u64);
    const frames = gst_video_time_code_frames_since_daily_jam(tc);
    return c.gst_util_uint64_scale(frames, u(SECOND *% @as(i64, tc[0].config.fps_d)), tc[0].config.fps_n);
}

fn rate(t: *allowzero const TC) struct { ff: f64, nom: c.guint } {
    var ff: f64 = 0;
    c.gst_util_fraction_to_double(ig(t.config.fps_n), ig(t.config.fps_d), &ff);
    const nom: c.guint = if (t.config.fps_d == 1001) t.config.fps_n / 1000 else @intFromFloat(ff);
    return .{ .ff = ff, .nom = nom };
}

fn dropMul(t: *allowzero const TC, line: c_int, comptime func: [*:0]const u8) c.guint {
    assert(t.config.fps_n % 30000 == 0, line, func, "tc->config.fps_n % 30000 == 0");
    return 2 *% (t.config.fps_n / 30000);
}

pub export fn gst_video_time_code_frames_since_daily_jam(tc: [*c]const TC) c_ulong {
    if (!checkValid(tc, "gst_video_time_code_frames_since_daily_jam")) return std.math.maxInt(u64);
    const t = &tc[0];
    const r = rate(t);
    if (t.config.flags & DROP != 0) {
        const ffm: c.guint = @intFromFloat(60 * r.ff);
        const ffh: c.guint = @intFromFloat(3600 * r.ff);
        const dm = dropMul(t, 395, "gst_video_time_code_frames_since_daily_jam");
        const tens: c.guint = @bitCast(@as(c.gint, @intCast(t.minutes / 10)));
        return t.frames +% r.nom *% t.seconds +% ffm *% t.minutes +% dm *% tens +% ffh *% t.hours;
    }
    if (t.config.fps_d > t.config.fps_n) return c.gst_util_uint64_scale(t.seconds +% 60 *% (t.minutes +% 60 *% t.hours), t.config.fps_n, t.config.fps_d);
    return t.frames +% r.nom *% (t.seconds +% 60 *% (t.minutes +% 60 *% t.hours));
}

pub export fn gst_video_time_code_increment_frame(tc: [*c]TC) void {
    gst_video_time_code_add_frames(tc, 1);
}

pub export fn gst_video_time_code_add_frames(tc: [*c]TC, frames: c_long) void {
    const fname = "gst_video_time_code_add_frames";
    if (!checkValid(tc, fname)) return;
    const t = &tc[0];
    const r = rate(t);
    const nom = r.nom;
    const sixty: u64 = 60;
    var h: u64 = 0;
    var min_new: u64 = 0;
    var sec_new: u64 = 0;
    var frames_new: u64 = 0;
    if (t.config.flags & DROP != 0) {
        const ffm: c.guint = @intFromFloat(60 * r.ff);
        const ffh: c.guint = @intFromFloat(3600 * r.ff);
        const dm = dropMul(t, 472, "gst_video_time_code_add_frames");
        const tens: c.guint = @bitCast(@as(c.gint, @intCast(t.minutes / 10)));
        const fc: u64 = u(frames +% @as(i64, t.frames) +% @as(i64, nom *% t.seconds) +% @as(i64, ffm *% t.minutes) +% @as(i64, dm *% tens) +% @as(i64, ffh *% t.hours));
        h = c.gst_util_uint64_scale_int(fc, 1, ig(ffh));
        const denom = sixty *% nom;
        var tmp1 = (fc -% h *% ffh) / denom;
        const tmp2 = fc +% dm *% tmp1;
        tmp1 = (fc -% h *% ffh) / (sixty *% 10 *% nom);
        const tmp3 = dm *% tmp1 +% h *% ffh;
        min_new = c.gst_util_uint64_scale_int(tmp2 -% tmp3, 1, ug(denom));
        const mtens: u64 = dm *% @as(c.guint, @bitCast(@as(c.gint, @truncate(@as(i64, @bitCast(min_new / 10))))));
        sec_new = (fc -% ffm *% min_new -% mtens -% ffh *% h) / nom;
        frames_new = fc -% nom *% sec_new -% ffm *% min_new -% mtens -% ffh *% h;
    } else if (t.config.fps_d > t.config.fps_n) {
        frames_new = u(frames) +% c.gst_util_uint64_scale(t.seconds +% 60 *% (t.minutes +% 60 *% t.hours), t.config.fps_n, t.config.fps_d);
        sec_new = c.gst_util_uint64_scale(frames_new, t.config.fps_d, t.config.fps_n);
        frames_new = 0;
        min_new = sec_new / 60;
        sec_new %= 60;
        h = min_new / 60;
        min_new %= 60;
    } else {
        const fc: u64 = u(frames +% @as(i64, t.frames)) +% nom *% (t.seconds +% sixty *% (t.minutes +% sixty *% t.hours));
        h = c.gst_util_uint64_scale_int(fc, 1, ug(nom *% sixty *% sixty));
        min_new = c.gst_util_uint64_scale_int(fc -% nom *% sixty *% sixty *% h, 1, ug(nom *% sixty));
        sec_new = c.gst_util_uint64_scale_int(fc -% nom *% sixty *% (min_new +% sixty *% h), 1, ig(nom));
        frames_new = fc -% nom *% (sec_new +% sixty *% (min_new +% sixty *% h));
        if (frames_new > nom) frames_new = 0;
    }
    assert(min_new < 60, 535, "gst_video_time_code_add_frames", "min_new < 60");
    assert(sec_new < 60, 536, "gst_video_time_code_add_frames", "sec_new < 60");
    assert(frames_new < nom or (nom == 0 and frames_new == 0), 537, "gst_video_time_code_add_frames", "frames_new < ff_nom || (ff_nom == 0 && frames_new == 0)");
    t.hours = @truncate(h % 24);
    t.minutes = @truncate(min_new);
    t.seconds = @truncate(sec_new);
    t.frames = @truncate(frames_new);
}

fn order(a: anytype, b: @TypeOf(a)) ?c.gint {
    if (a > b) return 1;
    if (a < b) return -1;
    return null;
}

pub export fn gst_video_time_code_compare(tc1: [*c]const TC, tc2: [*c]const TC) c.gint {
    const fname = "gst_video_time_code_compare";
    if (!check.that(gst_video_time_code_is_valid(tc1) != 0, fname, "gst_video_time_code_is_valid (tc1)")) return -1;
    if (!check.that(gst_video_time_code_is_valid(tc2) != 0, fname, "gst_video_time_code_is_valid (tc2)")) return -1;
    const a = &tc1[0];
    const b = &tc2[0];
    if (a.config.latest_daily_jam == null or b.config.latest_daily_jam == null) {
        if (order(a.hours, b.hours)) |r| return r;
        if (order(a.minutes, b.minutes)) |r| return r;
        if (order(a.seconds, b.seconds)) |r| return r;
        const n1 = c.gst_util_uint64_scale(u(SECOND), a.frames *% a.config.fps_n, a.config.fps_d);
        const n2 = c.gst_util_uint64_scale(u(SECOND), b.frames *% b.config.fps_n, b.config.fps_d);
        if (order(n1, n2)) |r| return r;
        if (a.config.flags & INTERLACED != 0) {
            if (order(a.field_count, b.field_count)) |r| return r;
        }
        return 0;
    }
    const d1 = gst_video_time_code_to_date_time(tc1);
    const d2 = gst_video_time_code_to_date_time(tc2);
    const ret = c.g_date_time_compare(d1, d2);
    c.g_date_time_unref(d1);
    c.g_date_time_unref(d2);
    return ret;
}

pub export fn gst_video_time_code_new(fps_n: c.guint, fps_d: c.guint, jam: ?*c.GDateTime, flags: c.GstVideoTimeCodeFlags, hours: c.guint, minutes: c.guint, seconds: c.guint, frames: c.guint, field_count: c.guint) [*c]TC {
    const tc: [*c]TC = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(TC))));
    gst_video_time_code_init(tc, fps_n, fps_d, jam, flags, hours, minutes, seconds, frames, field_count);
    return tc;
}

pub export fn gst_video_time_code_new_empty() [*c]TC {
    const tc: [*c]TC = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(TC))));
    gst_video_time_code_clear(tc);
    return tc;
}

fn fromString(v: [*c]const c.GValue, dest: [*c]c.GValue) callconv(.c) void {
    c.g_value_take_boxed(dest, gst_video_time_code_new_from_string(c.g_value_get_string(v)));
}

fn toString(v: [*c]const c.GValue, dest: [*c]c.GValue) callconv(.c) void {
    const tc: [*c]const TC = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    c.g_value_take_string(dest, gst_video_time_code_to_string(tc));
}

fn serialize(v: [*c]const c.GValue) callconv(.c) [*c]u8 {
    return gst_video_time_code_to_string(@ptrCast(@alignCast(c.g_value_get_boxed(v))));
}

fn deserialize(dest: [*c]c.GValue, s: [*c]const u8) callconv(.c) c.gboolean {
    const tc = gst_video_time_code_new_from_string(s);
    if (tc == null) return 0;
    c.g_value_take_boxed(dest, tc);
    return 1;
}

fn scan(s: [*c]const u8, comptime fmt: [*:0]const u8, v: *[4]c.guint) bool {
    return c.sscanf(s, fmt, &v[0], &v[1], &v[2], &v[3]) == 4;
}

pub export fn gst_video_time_code_new_from_string(s: [*c]const u8) [*c]TC {
    var v: [4]c.guint = undefined;
    if (scan(s, "%02u:%02u:%02u:%02u", &v) or scan(s, "%02u:%02u:%02u.%02u", &v))
        return gst_video_time_code_new(0, 1, null, c.GST_VIDEO_TIME_CODE_FLAGS_NONE, v[0], v[1], v[2], v[3], 0);
    if (scan(s, "%02u:%02u:%02u;%02u", &v) or scan(s, "%02u:%02u:%02u,%02u", &v))
        return gst_video_time_code_new(0, 1, null, DROP, v[0], v[1], v[2], v[3], 0);
    return null;
}

pub export fn gst_video_time_code_new_from_date_time(fps_n: c.guint, fps_d: c.guint, dt: ?*c.GDateTime, flags: c.GstVideoTimeCodeFlags, field_count: c.guint) [*c]TC {
    const tc = gst_video_time_code_new_empty();
    _ = gst_video_time_code_init_from_date_time_full(tc, fps_n, fps_d, dt, flags, field_count);
    return tc;
}

pub export fn gst_video_time_code_new_from_date_time_full(fps_n: c.guint, fps_d: c.guint, dt: ?*c.GDateTime, flags: c.GstVideoTimeCodeFlags, field_count: c.guint) [*c]TC {
    const tc = gst_video_time_code_new_empty();
    if (gst_video_time_code_init_from_date_time_full(tc, fps_n, fps_d, dt, flags, field_count) == 0) {
        gst_video_time_code_free(tc);
        return null;
    }
    return tc;
}

pub export fn gst_video_time_code_init(tc: [*c]TC, fps_n: c.guint, fps_d: c.guint, jam: ?*c.GDateTime, flags: c.GstVideoTimeCodeFlags, hours: c.guint, minutes: c.guint, seconds: c.guint, frames: c.guint, field_count: c.guint) void {
    const t = &tc[0];
    t.hours = hours;
    t.minutes = minutes;
    t.seconds = seconds;
    t.frames = frames;
    t.field_count = field_count;
    t.config.fps_n = fps_n;
    t.config.fps_d = fps_d;
    t.config.latest_daily_jam = if (jam != null) c.g_date_time_ref(jam) else null;
    t.config.flags = flags;
}

pub export fn gst_video_time_code_clear(tc: [*c]TC) void {
    const t = &tc[0];
    t.hours = 0;
    t.minutes = 0;
    t.seconds = 0;
    t.frames = 0;
    t.field_count = 0;
    t.config.fps_n = 0;
    t.config.fps_d = 1;
    if (t.config.latest_daily_jam != null) c.g_date_time_unref(t.config.latest_daily_jam);
    t.config.latest_daily_jam = null;
    t.config.flags = 0;
}

pub export fn gst_video_time_code_copy(tc: [*c]const TC) [*c]TC {
    const t = &tc[0];
    return gst_video_time_code_new(t.config.fps_n, t.config.fps_d, t.config.latest_daily_jam, t.config.flags, t.hours, t.minutes, t.seconds, t.frames, t.field_count);
}

pub export fn gst_video_time_code_free(tc: [*c]TC) void {
    if (tc[0].config.latest_daily_jam != null) c.g_date_time_unref(tc[0].config.latest_daily_jam);
    c.g_free(tc);
}

pub export fn gst_video_time_code_add_interval(tc: [*c]const TC, inter: [*c]const Interval) [*c]TC {
    if (!checkValid(tc, "gst_video_time_code_add_interval")) return null;
    const t = &tc[0];
    const ret = gst_video_time_code_new(t.config.fps_n, t.config.fps_d, t.config.latest_daily_jam, t.config.flags, inter[0].hours, inter[0].minutes, inter[0].seconds, inter[0].frames, 0);
    const df = (t.config.fps_n +% (t.config.fps_d >> 1)) / (t.config.fps_d *% 15);
    var fix = t.config.flags & DROP != 0 and ret[0].minutes % 10 != 0 and ret[0].seconds == 0 and ret[0].frames < df;
    if (fix) {
        ret[0].minutes -%= 1;
        ret[0].seconds = 59;
        ret[0].frames = df *% 14;
    }
    if (gst_video_time_code_is_valid(ret) == 0) {
        gst_video_time_code_free(ret);
        return null;
    }
    var add: c.guint = @truncate(gst_video_time_code_frames_since_daily_jam(tc));
    if (fix and t.minutes % 10 == 0 and t.frames <= df) {
        add +%= df;
        fix = false;
    }
    gst_video_time_code_add_frames(ret, add);
    if (fix and ret[0].minutes % 10 == 0 and t.frames > df) gst_video_time_code_add_frames(ret, df);
    return ret;
}

fn copyBoxed(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_video_time_code_copy(@ptrCast(@alignCast(p)));
}

fn freeBoxed(p: c.gpointer) callconv(.c) void {
    gst_video_time_code_free(@ptrCast(@alignCast(p)));
}

var table: c.GstValueTable = std.mem.zeroes(c.GstValueTable);
var tc_once: gtype.Once = .{};

pub export fn gst_video_time_code_get_type() c.GType {
    return tc_once.get(struct {
        fn f() c.GType {
            const t = gtype.boxed("GstVideoTimeCode", copyBoxed, freeBoxed);
            table.type = t;
            table.compare = @ptrCast(&gst_video_time_code_compare);
            table.serialize = serialize;
            table.deserialize = deserialize;
            c.gst_value_register(&table);
            c.g_value_register_transform_func(t, c.G_TYPE_STRING, toString);
            c.g_value_register_transform_func(c.G_TYPE_STRING, t, fromString);
            return t;
        }
    }.f);
}

pub export fn gst_video_time_code_interval_new(hours: c.guint, minutes: c.guint, seconds: c.guint, frames: c.guint) [*c]Interval {
    const tc: [*c]Interval = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Interval))));
    gst_video_time_code_interval_init(tc, hours, minutes, seconds, frames);
    return tc;
}

pub export fn gst_video_time_code_interval_new_from_string(s: [*c]const u8) [*c]Interval {
    var v: [4]c.guint = undefined;
    if (scan(s, "%02u:%02u:%02u:%02u", &v) or scan(s, "%02u:%02u:%02u;%02u", &v) or scan(s, "%02u:%02u:%02u.%02u", &v) or scan(s, "%02u:%02u:%02u,%02u", &v))
        return gst_video_time_code_interval_new(v[0], v[1], v[2], v[3]);
    return null;
}

pub export fn gst_video_time_code_interval_init(tc: [*c]Interval, hours: c.guint, minutes: c.guint, seconds: c.guint, frames: c.guint) void {
    tc[0].hours = hours;
    tc[0].minutes = minutes;
    tc[0].seconds = seconds;
    tc[0].frames = frames;
}

pub export fn gst_video_time_code_interval_clear(tc: [*c]Interval) void {
    tc[0] = std.mem.zeroes(Interval);
}

pub export fn gst_video_time_code_interval_copy(tc: [*c]const Interval) [*c]Interval {
    return gst_video_time_code_interval_new(tc[0].hours, tc[0].minutes, tc[0].seconds, tc[0].frames);
}

pub export fn gst_video_time_code_interval_free(tc: [*c]Interval) void {
    c.g_free(tc);
}

fn icopy(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_video_time_code_interval_copy(@ptrCast(@alignCast(p)));
}

fn ifree(p: c.gpointer) callconv(.c) void {
    c.g_free(p);
}

var interval_once: gtype.Once = .{};

pub export fn gst_video_time_code_interval_get_type() c.GType {
    return interval_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoTimeCodeInterval", icopy, ifree);
        }
    }.f);
}
