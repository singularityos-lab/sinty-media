const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const value = @import("value.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Fields = enum(c_int) { invalid = 0, y, ym, ymd, ymd_hm, ymd_hms };

const Impl = extern struct {
    mini: c.GstMiniObject,
    dt: ?*c.GDateTime,
    fields: Fields,
};

const DT = c.GstDateTime;

pub export var _gst_date_time_type: c.GType = 0;
var type_once: gtype.Once = .{};

fn of(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

pub export fn gst_date_time_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstDateTime", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

fn release(m: [*c]c.GstMiniObject) callconv(.c) void {
    c.g_date_time_unref(of(m).dt);
    c.g_free(m);
}

pub export fn gst_date_time_new_from_g_date_time(dt: ?*c.GDateTime) ?*DT {
    const d = dt orelse return null;
    const p: *Impl = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Impl))));
    mini.gst_mini_object_init(@ptrCast(p), 0, gst_date_time_get_type(), null, null, release);
    p.dt = d;
    p.fields = .ymd_hms;
    return @ptrCast(p);
}

pub export fn gst_date_time_to_g_date_time(p: ?*DT) ?*c.GDateTime {
    if (!check.that(p != null, "gst_date_time_to_g_date_time", "datetime != NULL")) return null;
    if (of(p).fields != .ymd_hms) return null;
    return c.g_date_time_add(of(p).dt, 0);
}

fn has(comptime func: []const u8, p: ?*const DT, min: Fields) c.gboolean {
    if (!check.that(p != null, func, "datetime != NULL")) return 0;
    return @intFromBool(@intFromEnum(of(p).fields) >= @intFromEnum(min));
}

pub export fn gst_date_time_has_year(p: ?*const DT) c.gboolean {
    return has("gst_date_time_has_year", p, .y);
}
pub export fn gst_date_time_has_month(p: ?*const DT) c.gboolean {
    return has("gst_date_time_has_month", p, .ym);
}
pub export fn gst_date_time_has_day(p: ?*const DT) c.gboolean {
    return has("gst_date_time_has_day", p, .ymd);
}
pub export fn gst_date_time_has_time(p: ?*const DT) c.gboolean {
    return has("gst_date_time_has_time", p, .ymd_hm);
}
pub export fn gst_date_time_has_second(p: ?*const DT) c.gboolean {
    return has("gst_date_time_has_second", p, .ymd_hms);
}

fn part(comptime func: []const u8, p: ?*const DT, min: Fields, comptime get: anytype) c.gint {
    if (!check.that(p != null, func, "datetime != NULL")) return 0;
    if (@intFromEnum(of(p).fields) < @intFromEnum(min)) return -1;
    return get(of(p).dt);
}

pub export fn gst_date_time_get_year(p: ?*const DT) c.gint {
    if (!check.that(p != null, "gst_date_time_get_year", "datetime != NULL")) return 0;
    return c.g_date_time_get_year(of(p).dt);
}
pub export fn gst_date_time_get_month(p: ?*const DT) c.gint {
    return part("gst_date_time_get_month", p, .ym, c.g_date_time_get_month);
}
pub export fn gst_date_time_get_day(p: ?*const DT) c.gint {
    return part("gst_date_time_get_day", p, .ymd, c.g_date_time_get_day_of_month);
}
pub export fn gst_date_time_get_hour(p: ?*const DT) c.gint {
    return part("gst_date_time_get_hour", p, .ymd_hm, c.g_date_time_get_hour);
}
pub export fn gst_date_time_get_minute(p: ?*const DT) c.gint {
    return part("gst_date_time_get_minute", p, .ymd_hm, c.g_date_time_get_minute);
}
pub export fn gst_date_time_get_second(p: ?*const DT) c.gint {
    return part("gst_date_time_get_second", p, .ymd_hms, c.g_date_time_get_second);
}
pub export fn gst_date_time_get_microsecond(p: ?*const DT) c.gint {
    return part("gst_date_time_get_microsecond", p, .ymd_hms, c.g_date_time_get_microsecond);
}

pub export fn gst_date_time_get_time_zone_offset(p: ?*const DT) c.gfloat {
    if (!check.that(p != null, "gst_date_time_get_time_zone_offset", "datetime != NULL")) return 0;
    if (gst_date_time_has_time(p) == 0) return std.math.floatMax(f32);
    const usec = c.g_date_time_get_utc_offset(of(p).dt);
    return @floatCast(@as(f64, @floatFromInt(@divTrunc(usec, c.G_USEC_PER_SEC))) / 3600.0);
}

pub export fn gst_date_time_new_y(y: c.gint) ?*DT {
    return gst_date_time_new(0, y, -1, -1, -1, -1, -1);
}
pub export fn gst_date_time_new_ym(y: c.gint, m: c.gint) ?*DT {
    return gst_date_time_new(0, y, m, -1, -1, -1, -1);
}
pub export fn gst_date_time_new_ymd(y: c.gint, m: c.gint, d: c.gint) ?*DT {
    return gst_date_time_new(0, y, m, d, -1, -1, -1);
}

pub export fn gst_date_time_new_from_unix_epoch_local_time(secs: c.gint64) ?*DT {
    return gst_date_time_new_from_g_date_time(c.g_date_time_new_from_unix_local(secs));
}
pub export fn gst_date_time_new_from_unix_epoch_utc(secs: c.gint64) ?*DT {
    return gst_date_time_new_from_g_date_time(c.g_date_time_new_from_unix_utc(secs));
}

fn withMicros(base: ?*c.GDateTime, usecs: c.gint64) ?*DT {
    const b = base orelse return null;
    const frac: f64 = @floatFromInt(@rem(usecs, c.G_USEC_PER_SEC));
    const out = c.g_date_time_add_seconds(b, frac / @as(f64, c.G_USEC_PER_SEC));
    c.g_date_time_unref(b);
    return gst_date_time_new_from_g_date_time(out);
}

pub export fn gst_date_time_new_from_unix_epoch_local_time_usecs(usecs: c.gint64) ?*DT {
    return withMicros(c.g_date_time_new_from_unix_local(@divTrunc(usecs, c.G_USEC_PER_SEC)), usecs);
}
pub export fn gst_date_time_new_from_unix_epoch_utc_usecs(usecs: c.gint64) ?*DT {
    return withMicros(c.g_date_time_new_from_unix_utc(@divTrunc(usecs, c.G_USEC_PER_SEC)), usecs);
}

fn validParts(y: c.gint, m: c.gint, d: c.gint, h: c.gint, mi: c.gint, s: f64) bool {
    if (y <= 0 or y > 9999) return false;
    if ((m <= 0 or m > 12) and m != -1) return false;
    if ((d <= 0 or d > 31) and d != -1) return false;
    if ((h < 0 or h >= 24) and h != -1) return false;
    if ((mi < 0 or mi >= 60) and mi != -1) return false;
    if ((s < 0 or s >= 60) and s != -1) return false;
    return true;
}

fn settle(m: *c.gint, d: *c.gint, h: *c.gint, mi: *c.gint, s: *f64) Fields {
    if (m.* == -1) {
        m.* = 1;
        d.* = 1;
        h.* = 0;
        mi.* = 0;
        s.* = 0;
        return .y;
    }
    if (d.* == -1) {
        d.* = 1;
        h.* = 0;
        mi.* = 0;
        s.* = 0;
        return .ym;
    }
    if (h.* == -1) {
        h.* = 0;
        mi.* = 0;
        s.* = 0;
        return .ymd;
    }
    if (s.* == -1) {
        s.* = 0;
        return .ymd_hm;
    }
    return .ymd_hms;
}

pub export fn gst_date_time_new_local_time(y: c.gint, m_in: c.gint, d_in: c.gint, h_in: c.gint, mi_in: c.gint, s_in: c.gdouble) ?*DT {
    if (!validParts(y, m_in, d_in, h_in, mi_in, s_in)) return null;
    var m = m_in;
    var d = d_in;
    var h = h_in;
    var mi = mi_in;
    var s = s_in;
    const fields = settle(&m, &d, &h, &mi, &s);
    const out = gst_date_time_new_from_g_date_time(c.g_date_time_new_local(y, m, d, h, mi, s)) orelse return null;
    of(out).fields = fields;
    return out;
}

pub export fn gst_date_time_new_now_local_time() ?*DT {
    return gst_date_time_new_from_g_date_time(c.g_date_time_new_now_local());
}
pub export fn gst_date_time_new_now_utc() ?*DT {
    return gst_date_time_new_from_g_date_time(c.g_date_time_new_now_utc());
}

pub fn compare(a: ?*const DT, b: ?*const DT) c.gint {
    if (of(a).fields != of(b).fields) return c.GST_VALUE_UNORDERED;
    const diff = c.g_date_time_to_unix(of(a).dt) - c.g_date_time_to_unix(of(b).dt);
    if (diff < 0) return c.GST_VALUE_LESS_THAN;
    if (diff > 0) return c.GST_VALUE_GREATER_THAN;
    return c.GST_VALUE_EQUAL;
}

pub export fn gst_date_time_new(tz: c.gfloat, y: c.gint, m_in: c.gint, d_in: c.gint, h_in: c.gint, mi_in: c.gint, s_in: c.gdouble) ?*DT {
    if (!validParts(y, m_in, d_in, h_in, mi_in, s_in)) return null;
    if (tz < -12.0 or tz > 12.0) return null;
    if ((h_in < 0 or mi_in < 0) and (h_in != -1 or mi_in != -1 or s_in != -1 or tz != 0.0)) return null;
    const abs_tz = @abs(tz);
    const tzh: c.gint = @intFromFloat(abs_tz);
    const tzm: c.gint = @intFromFloat((abs_tz - @as(f32, @floatFromInt(tzh))) * 60);
    var buf: [6]u8 = undefined;
    _ = c.g_snprintf(&buf, 6, "%c%02d%02d", @as(c_int, if (tz >= 0) '+' else '-'), tzh, tzm);
    const zone = c.g_time_zone_new_identifier(&buf) orelse return null;
    var m = m_in;
    var d = d_in;
    var h = h_in;
    var mi = mi_in;
    var s = s_in;
    const fields = settle(&m, &d, &h, &mi, &s);
    const g = c.g_date_time_new(zone, y, m, d, h, mi, s);
    c.g_time_zone_unref(zone);
    const out = gst_date_time_new_from_g_date_time(g) orelse return null;
    of(out).fields = fields;
    return out;
}

pub fn serialize(p: ?*DT, usecs: bool) [*c]u8 {
    const s = c.g_string_new(null);
    const f = of(p).fields;
    c.g_string_append_printf(s, "%04u", @as(c.guint, @bitCast(gst_date_time_get_year(p))));
    done: {
        if (f == .y) break :done;
        c.g_string_append_printf(s, "-%02u", @as(c.guint, @bitCast(gst_date_time_get_month(p))));
        if (f == .ym) break :done;
        c.g_string_append_printf(s, "-%02u", @as(c.guint, @bitCast(gst_date_time_get_day(p))));
        if (f == .ymd) break :done;
        c.g_string_append_printf(s, "T%02u:%02u", @as(c.guint, @bitCast(gst_date_time_get_hour(p))), @as(c.guint, @bitCast(gst_date_time_get_minute(p))));
        if (f != .ymd_hm) {
            c.g_string_append_printf(s, ":%02u", @as(c.guint, @bitCast(gst_date_time_get_second(p))));
            if (usecs) {
                const us: c.guint = @bitCast(gst_date_time_get_microsecond(p));
                if (us != 0) {
                    c.g_string_append_printf(s, ".%06u", us);
                    while (s.*.str[s.*.len - 1] == '0') _ = c.g_string_truncate(s, s.*.len - 1);
                }
            }
        }
        const off = gst_date_time_get_time_zone_offset(p);
        if (off == 0) {
            _ = c.g_string_append_c(s, 'Z');
        } else {
            const a = @abs(off);
            const hh: c.guint = @intFromFloat(a);
            const mm: c.guint = @intFromFloat((a - @as(f32, @floatFromInt(hh))) * 60);
            _ = c.g_string_append_c(s, if (off >= 0) '+' else '-');
            c.g_string_append_printf(s, "%02u%02u", hh, mm);
        }
    }
    return c.g_string_free(s, 0);
}

pub export fn gst_date_time_to_iso8601_string(p: ?*DT) [*c]u8 {
    if (!check.that(p != null, "gst_date_time_to_iso8601_string", "datetime != NULL")) return null;
    if (of(p).fields == .invalid) return null;
    return serialize(p, false);
}

const Scan = struct {
    s: []const u8,
    i: usize = 0,

    fn int(self: *Scan, width: usize) ?c.gint {
        while (self.i < self.s.len and std.ascii.isWhitespace(self.s[self.i])) self.i += 1;
        const start = self.i;
        var j = self.i;
        if (j < self.s.len and (self.s[j] == '-' or self.s[j] == '+') and j - start < width) j += 1;
        const digits = j;
        while (j < self.s.len and j - start < width and std.ascii.isDigit(self.s[j])) j += 1;
        if (j == digits) return null;
        self.i = j;
        return std.fmt.parseInt(c.gint, self.s[start..j], 10) catch null;
    }

    fn lit(self: *Scan, ch: u8) bool {
        if (self.i < self.s.len and self.s[self.i] == ch) {
            self.i += 1;
            return true;
        }
        return false;
    }
};

fn scanYmd(s: []const u8, y: *c.gint, m: *c.gint, d: *c.gint) c_int {
    var sc = Scan{ .s = s };
    y.* = sc.int(4) orelse return 0;
    if (!sc.lit('-')) return 1;
    m.* = sc.int(2) orelse return 1;
    if (!sc.lit('-')) return 2;
    d.* = sc.int(2) orelse return 2;
    return 3;
}

fn scanTz(pos: []const u8, colon: bool, h: *c.gint, m: *c.gint) bool {
    var sc = Scan{ .s = pos };
    const w: usize = if (colon) 64 else 2;
    h.* = sc.int(w) orelse return false;
    if (colon and !sc.lit(':')) return false;
    m.* = sc.int(w) orelse return false;
    return true;
}

fn leadingUint(p: [*c]const u8, end: *[*c]const u8) u64 {
    var e: [*c]u8 = null;
    const v = c.g_ascii_strtoull(p, &e, 10);
    end.* = e;
    return v;
}

pub export fn gst_date_time_new_from_iso8601_string(text: [*c]const u8) ?*DT {
    if (!check.that(text != null, "gst_date_time_new_from_iso8601_string", "string != NULL")) return null;
    var y: c.gint = -1;
    var mo: c.gint = -1;
    var d: c.gint = -1;
    var h: c.gint = -1;
    var mi: c.gint = -1;
    var tzh: c.gint = -99;
    var tzm: c.gint = -99;
    var sec: f64 = -1.0;
    var tz: f32 = 0;
    const all = std.mem.span(text);
    if (all.len < 4 or !std.ascii.isDigit(all[0]) or !std.ascii.isDigit(all[1])) return null;
    var p: [*c]const u8 = text;
    full: {
        if (std.ascii.isDigit(all[2]) and std.ascii.isDigit(all[3])) {
            var got = scanYmd(all, &y, &mo, &d);
            if (got == 0) return null;
            if (got == 3 and d <= 0) {
                got = 2;
                d = -1;
            }
            if (got >= 2 and mo <= 0) {
                got = 1;
                mo = -1;
                d = -1;
            }
            if (y <= 0 or y > 9999 or mo > 12 or d > 31) return null;
            if (all.len < 16) break :full;
            p += 10;
            if (!(p[0] == 'T' or p[0] == '-' or p[0] == ' ')) break :full;
            p += 1;
        }
        var end: [*c]const u8 = undefined;
        const hv = leadingUint(p, &end);
        p = end;
        h = @truncate(@as(i64, @bitCast(hv)));
        if (h > 24 or p[0] != ':') break :full;
        const mv = leadingUint(p + 1, &end);
        p = end;
        mi = @truncate(@as(i64, @bitCast(mv)));
        if (mi > 59) break :full;
        if (p[0] == ':') {
            const sv = leadingUint(p + 1, &end);
            p = end;
            const s32: c.gint = @truncate(@as(i64, @bitCast(sv)));
            if (s32 > 59) {
                sec = -1.0;
            } else {
                sec = @floatFromInt(s32);
                if (p[0] == '.' or p[0] == ',') {
                    const start = p + 1;
                    const us = leadingUint(start, &end);
                    p = end;
                    if (us != std.math.maxInt(u64) and @intFromPtr(p) > @intFromPtr(start)) {
                        const digits: f64 = @floatFromInt(@intFromPtr(p) - @intFromPtr(start));
                        sec += @as(f64, @floatFromInt(us)) / std.math.pow(f64, 10.0, digits);
                    }
                }
            }
        }
        if (p[0] != 'Z') {
            const plus = c.strrchr(p, '+');
            const minus = c.strrchr(p, '-');
            const pos: [*c]const u8 = if (plus != null) plus + 1 else if (minus != null) minus + 1 else null;
            if (pos != null and std.mem.len(pos) >= 3) {
                const rest = std.mem.span(pos);
                if (scanTz(rest, rest[2] == ':', &tzh, &tzm)) {
                    if (minus != null and minus + 1 == pos) {
                        tzh = -tzh;
                        tzm = -tzm;
                    }
                    tz = @floatCast(@as(f64, @floatFromInt(tzh * 60 + tzm)) / 60.0);
                }
            }
        }
        if (y == -1 or mo == -1 or d == -1) {
            var now = c.g_date_time_new_now_utc() orelse return null;
            if (tz != 0) {
                const moved = c.g_date_time_add_minutes(now, 60 * tzh + tzm);
                c.g_date_time_unref(now);
                now = moved orelse return null;
            }
            c.g_date_time_get_ymd(now, &y, &mo, &d);
            c.g_date_time_unref(now);
        }
        return gst_date_time_new(tz, y, mo, d, h, mi, sec);
    }
    if (y == -1) return null;
    return gst_date_time_new_ymd(y, mo, d);
}

pub export fn gst_date_time_ref(p: ?*DT) ?*DT {
    return @ptrCast(mini.gst_mini_object_ref(@ptrCast(@alignCast(p))));
}

pub export fn gst_date_time_unref(p: ?*DT) void {
    mini.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

fn compareValues(a: [*c]const c.GValue, b: [*c]const c.GValue) callconv(.c) c.gint {
    const x: ?*const DT = @ptrCast(@alignCast(c.g_value_get_boxed(a)));
    const y: ?*const DT = @ptrCast(@alignCast(c.g_value_get_boxed(b)));
    if (x == y) return c.GST_VALUE_EQUAL;
    if (x == null or y == null) return c.GST_VALUE_LESS_THAN;
    return compare(x, y);
}

fn serializeValue(v: [*c]const c.GValue) callconv(.c) [*c]u8 {
    const p: ?*DT = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    if (p == null) return c.g_strdup("null");
    return serialize(p, true);
}

fn deserializeValue(dest: [*c]c.GValue, s: [*c]const u8) callconv(.c) c.gboolean {
    if (s == null or std.mem.orderZ(u8, s, "null") == .eq) return 0;
    const p = gst_date_time_new_from_iso8601_string(s) orelse return 0;
    c.g_value_take_boxed(dest, p);
    return 1;
}

var value_table: c.GstValueTable = .{};

pub fn initialize() void {
    _gst_date_time_type = gst_date_time_get_type();
    value_table = .{ .type = _gst_date_time_type, .compare = compareValues, .serialize = serializeValue, .deserialize = deserializeValue, .hash = @import("vhash.zig").dateTime };
    value.gst_value_register(&value_table);
}
