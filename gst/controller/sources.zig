const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const check = @import("check.zig");
const libm = @import("../libm.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Source = c.GstControlSource;
const Timed = c.GstTimedValueControlSource;
const Point = c.GstControlPoint;
const NONE: u64 = std.math.maxInt(u64);
const NAN = std.math.nan(f64);

var timed_once: gtype.Once = .{};
var interp_once: gtype.Once = .{};
var trigger_once: gtype.Once = .{};
var lfo_once: gtype.Once = .{};
var point_once: gtype.Once = .{};
var mode_once: gtype.Once = .{};
var wave_once: gtype.Once = .{};

var timed_parent: ?*c.GObjectClass = null;
var lfo_parent: ?*c.GObjectClass = null;
var interp_offset: c.gint = 0;
var trigger_offset: c.gint = 0;
var lfo_offset: c.gint = 0;

const VALUE_CHANGED = 0;
const VALUE_ADDED = 1;
const VALUE_REMOVED = 2;
var signals: [3]c.guint = .{ 0, 0, 0 };

fn toF(x: u64) f64 {
    return @floatFromInt(x);
}

pub export fn gst_control_point_free(cp: [*c]Point) void {
    if (!check.that(cp != null, "gst_control_point_free", "cp")) return;
    c.g_free(cp);
}

pub export fn gst_control_point_copy(cp: [*c]Point) [*c]Point {
    return @ptrCast(@alignCast(c.g_memdup2(cp, @sizeOf(Point))));
}

fn copyBoxed(p: c.gconstpointer) callconv(.c) c.gpointer {
    return gst_control_point_copy(@ptrCast(@alignCast(@constCast(p))));
}

fn freeBoxed(p: c.gpointer) callconv(.c) void {
    gst_control_point_free(@ptrCast(@alignCast(p)));
}

pub export fn gst_control_point_get_type() c.GType {
    return point_once.get(struct {
        fn f() c.GType {
            return gtype.boxed(c.g_intern_static_string("GstControlPoint"), copyBoxed, freeBoxed);
        }
    }.f);
}

pub export fn gst_interpolation_mode_get_type() c.GType {
    return mode_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_INTERPOLATION_MODE_NONE, .value_name = "GST_INTERPOLATION_MODE_NONE", .value_nick = "none" },
            .{ .value = c.GST_INTERPOLATION_MODE_LINEAR, .value_name = "GST_INTERPOLATION_MODE_LINEAR", .value_nick = "linear" },
            .{ .value = c.GST_INTERPOLATION_MODE_CUBIC, .value_name = "GST_INTERPOLATION_MODE_CUBIC", .value_nick = "cubic" },
            .{ .value = c.GST_INTERPOLATION_MODE_CUBIC_MONOTONIC, .value_name = "GST_INTERPOLATION_MODE_CUBIC_MONOTONIC", .value_nick = "cubic-monotonic" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstInterpolationMode"), &values);
        }
    }.f);
}

pub export fn gst_lfo_waveform_get_type() c.GType {
    return wave_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_LFO_WAVEFORM_SINE, .value_name = "GST_LFO_WAVEFORM_SINE", .value_nick = "sine" },
            .{ .value = c.GST_LFO_WAVEFORM_SQUARE, .value_name = "GST_LFO_WAVEFORM_SQUARE", .value_nick = "square" },
            .{ .value = c.GST_LFO_WAVEFORM_SAW, .value_name = "GST_LFO_WAVEFORM_SAW", .value_nick = "saw" },
            .{ .value = c.GST_LFO_WAVEFORM_REVERSE_SAW, .value_name = "GST_LFO_WAVEFORM_REVERSE_SAW", .value_nick = "reverse-saw" },
            .{ .value = c.GST_LFO_WAVEFORM_TRIANGLE, .value_name = "GST_LFO_WAVEFORM_TRIANGLE", .value_nick = "triangle" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstLFOWaveform"), &values);
        }
    }.f);
}

fn isTimed(p: anytype) bool {
    return gtype.instanceOf(p, gst_timed_value_control_source_get_type());
}

fn src(s: *Timed) *Source {
    return @ptrCast(s);
}

fn reset(s: *Timed) void {
    src(s).get_value = null;
    src(s).get_value_array = null;
    if (s.values) |v| c.g_sequence_free(v);
    s.values = null;
    s.nvalues = 0;
    s.valid_cache = 0;
}

fn order(a: u64, b: u64) c.gint {
    return if (a < b) -1 else if (a == b) 0 else 1;
}

fn comparePoints(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const x: *const Point = @ptrCast(@alignCast(a));
    const y: *const Point = @ptrCast(@alignCast(b));
    return order(x.timestamp, y.timestamp);
}

fn findPoint(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const x: *const Point = @ptrCast(@alignCast(a));
    const t: *const u64 = @ptrCast(@alignCast(b));
    return order(x.timestamp, t.*);
}

fn point(it: ?*c.GSequenceIter) *Point {
    return @ptrCast(@alignCast(c.g_sequence_get(it)));
}

fn setInternal(s: *Timed, ts: u64, value: f64) void {
    c.g_mutex_lock(&s.lock);
    var t = ts;
    if (s.values != null) {
        const it = c.g_sequence_lookup(s.values, &t, findPoint, null);
        if (it != null) {
            const cp = point(it);
            cp.value = value;
            c.g_mutex_unlock(&s.lock);
            c.g_signal_emit(s, signals[VALUE_CHANGED], 0, cp);
            s.valid_cache = 0;
            return;
        }
    } else s.values = c.g_sequence_new(freeBoxed);
    const cp: *Point = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Point))));
    cp.timestamp = ts;
    cp.value = value;
    _ = c.g_sequence_insert_sorted(s.values, cp, comparePoints, null);
    s.nvalues += 1;
    c.g_mutex_unlock(&s.lock);
    c.g_signal_emit(s, signals[VALUE_ADDED], 0, cp);
    s.valid_cache = 0;
}

pub export fn gst_timed_value_control_source_find_control_point_iter(s: [*c]Timed, ts: c.GstClockTime) ?*c.GSequenceIter {
    if (s.*.values == null) return null;
    var t = ts;
    const it = c.g_sequence_search(s.*.values, &t, findPoint, null);
    if (c.g_sequence_iter_is_begin(it) != 0) return null;
    return c.g_sequence_iter_prev(it);
}

pub export fn gst_timed_value_control_source_set(s: [*c]Timed, ts: c.GstClockTime, value: c.gdouble) c.gboolean {
    if (!check.that(isTimed(s), "gst_timed_value_control_source_set", "GST_IS_TIMED_VALUE_CONTROL_SOURCE (self)")) return 0;
    if (!check.that(ts != NONE, "gst_timed_value_control_source_set", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    setInternal(s, ts, value);
    return 1;
}

pub export fn gst_timed_value_control_source_set_from_list(s: [*c]Timed, list: [*c]const c.GSList) c.gboolean {
    if (!check.that(isTimed(s), "gst_timed_value_control_source_set_from_list", "GST_IS_TIMED_VALUE_CONTROL_SOURCE (self)")) return 0;
    var res: c.gboolean = 0;
    var n = list;
    while (n != null) : (n = n.*.next) {
        const tv: *c.GstTimedValue = @ptrCast(@alignCast(n.*.data));
        if (tv.timestamp != NONE) {
            setInternal(s, tv.timestamp, tv.value);
            res = 1;
        }
    }
    return res;
}

pub export fn gst_timed_value_control_source_unset(s: [*c]Timed, ts: c.GstClockTime) c.gboolean {
    if (!check.that(isTimed(s), "gst_timed_value_control_source_unset", "GST_IS_TIMED_VALUE_CONTROL_SOURCE (self)")) return 0;
    if (!check.that(ts != NONE, "gst_timed_value_control_source_unset", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    var res: c.gboolean = 0;
    var cp: ?*Point = null;
    var t = ts;
    c.g_mutex_lock(&s.*.lock);
    if (s.*.values != null) {
        const it = c.g_sequence_lookup(s.*.values, &t, findPoint, null);
        if (it != null) {
            cp = gst_control_point_copy(point(it));
            c.g_sequence_remove(it);
            s.*.nvalues -= 1;
            s.*.valid_cache = 0;
            res = 1;
        }
    }
    c.g_mutex_unlock(&s.*.lock);
    if (cp) |p| {
        c.g_signal_emit(s, signals[VALUE_REMOVED], 0, p);
        c.g_free(p);
    }
    return res;
}

pub export fn gst_timed_value_control_source_unset_all(s: [*c]Timed) void {
    if (!check.that(isTimed(s), "gst_timed_value_control_source_unset_all", "GST_IS_TIMED_VALUE_CONTROL_SOURCE (self)")) return;
    c.g_mutex_lock(&s.*.lock);
    if (s.*.values) |v| c.g_sequence_free(v);
    s.*.values = null;
    s.*.nvalues = 0;
    s.*.valid_cache = 0;
    c.g_mutex_unlock(&s.*.lock);
}

fn appendPoint(p: c.gpointer, q: c.gpointer) callconv(.c) void {
    c.g_queue_push_tail(@ptrCast(@alignCast(q)), p);
}

pub export fn gst_timed_value_control_source_get_all(s: [*c]Timed) [*c]c.GList {
    if (!check.that(isTimed(s), "gst_timed_value_control_source_get_all", "GST_IS_TIMED_VALUE_CONTROL_SOURCE (self)")) return null;
    var q = std.mem.zeroes(c.GQueue);
    c.g_mutex_lock(&s.*.lock);
    if (s.*.values != null) c.g_sequence_foreach(s.*.values, appendPoint, &q);
    c.g_mutex_unlock(&s.*.lock);
    return q.head;
}

const Fill = struct { arr: [*]c.GstTimedValue, i: usize };

fn fillValue(p: c.gpointer, d: c.gpointer) callconv(.c) void {
    const cp: *Point = @ptrCast(@alignCast(p));
    const f: *Fill = @ptrCast(@alignCast(d));
    f.arr[f.i] = .{ .timestamp = cp.timestamp, .value = cp.value };
    f.i += 1;
}

pub export fn gst_timed_value_control_source_list_control_points(s: [*c]Timed, n: [*c]c.gsize) [*c]c.GstTimedValue {
    if (!check.that(isTimed(s), "gst_timed_value_control_source_list_control_points", "GST_IS_TIMED_VALUE_CONTROL_SOURCE (self)")) return null;
    if (!check.that(n != null, "gst_timed_value_control_source_list_control_points", "n_control_points != NULL")) return null;
    c.g_mutex_lock(&s.*.lock);
    defer c.g_mutex_unlock(&s.*.lock);
    if (s.*.values == null or s.*.nvalues == 0) {
        n.* = 0;
        return null;
    }
    const arr: [*]c.GstTimedValue = @ptrCast(@alignCast(c.g_malloc_n(@intCast(s.*.nvalues), @sizeOf(c.GstTimedValue))));
    var f = Fill{ .arr = arr, .i = 0 };
    c.g_sequence_foreach(s.*.values, fillValue, &f);
    n.* = @intCast(s.*.nvalues);
    return arr;
}

pub export fn gst_timed_value_control_source_get_count(s: [*c]Timed) c.gint {
    if (!check.that(isTimed(s), "gst_timed_value_control_source_get_count", "GST_IS_TIMED_VALUE_CONTROL_SOURCE (self)")) return 0;
    return s.*.nvalues;
}

pub export fn gst_timed_value_control_invalidate_cache(s: [*c]Timed) void {
    if (!check.that(isTimed(s), "gst_timed_value_control_invalidate_cache", "GST_IS_TIMED_VALUE_CONTROL_SOURCE (self)")) return;
    s.*.valid_cache = 0;
}

fn timedInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Timed = @ptrCast(@alignCast(inst));
    c.g_mutex_init(&s.lock);
}

fn timedFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Timed = @ptrCast(@alignCast(o));
    c.g_mutex_lock(&s.lock);
    reset(s);
    c.g_mutex_unlock(&s.lock);
    c.g_mutex_clear(&s.lock);
    timed_parent.?.finalize.?(o);
}

fn timedClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    timed_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    signals[VALUE_CHANGED] = c.g_signal_new("value-changed", t, c.G_SIGNAL_RUN_FIRST, 0, null, null, null, c.G_TYPE_NONE, 1, gst_control_point_get_type());
    signals[VALUE_ADDED] = c.g_signal_new("value-added", t, c.G_SIGNAL_RUN_FIRST, 0, null, null, null, c.G_TYPE_NONE, 1, gst_control_point_get_type());
    signals[VALUE_REMOVED] = c.g_signal_new("value-removed", t, c.G_SIGNAL_RUN_FIRST, 0, null, null, null, c.G_TYPE_NONE, 1, gst_control_point_get_type());
    gc.finalize = timedFinalize;
}

pub export fn gst_timed_value_control_source_get_type() c.GType {
    return timed_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_control_source_get_type, "GstTimedValueControlSource", c.GstTimedValueControlSourceClass, Timed, timedClassInit, timedInit, c.G_TYPE_FLAG_ABSTRACT);
            _ = c._gst_debug_category_new("timedvaluecontrolsource", 0, "timed value control source base class");
            return t;
        }
    }.f);
}

fn nearest(s: *Timed, ts: u64, cp1: *?*Point, cp2: *?*Point) bool {
    var it = gst_timed_value_control_source_find_control_point_iter(s, ts) orelse return false;
    cp1.* = point(it);
    it = c.g_sequence_iter_next(it) orelse {
        cp2.* = null;
        return true;
    };
    cp2.* = if (c.g_sequence_iter_is_end(it) == 0) point(it) else null;
    return true;
}

fn nearest2(s: *Timed, ts: u64, cp1: *?*Point, cp2: *?*Point, next: *u64) void {
    cp1.* = null;
    cp2.* = null;
    var it2: ?*c.GSequenceIter = null;
    if (gst_timed_value_control_source_find_control_point_iter(s, ts)) |it1| {
        cp1.* = point(it1);
        it2 = c.g_sequence_iter_next(it1);
    } else if (s.values != null) {
        it2 = c.g_sequence_get_begin_iter(s.values);
    }
    if (it2 != null and c.g_sequence_iter_is_end(it2) == 0) {
        cp2.* = point(it2);
        next.* = cp2.*.?.timestamp;
    } else next.* = NONE;
}

const Mode = enum { none, linear, cubic, mono };

fn linear(t1: u64, v1: f64, t2: u64, v2: f64, ts: u64) f64 {
    if (t2 == NONE) return v1;
    const slope = (v2 - v1) / toF(t2 -% t1);
    return v1 + toF(ts -% t1) * slope;
}

fn cubicCache(s: *Timed) void {
    const n: usize = @intCast(s.nvalues);
    const buf: [*]f64 = @ptrCast(@alignCast(c.g_malloc0(n * 6 * @sizeOf(f64))));
    defer c.g_free(buf);
    const o = buf[0..n];
    const p = buf[n .. 2 * n];
    const q = buf[2 * n .. 3 * n];
    const h = buf[3 * n .. 4 * n];
    const b = buf[4 * n .. 5 * n];
    const z = buf[5 * n .. 6 * n];
    var it = c.g_sequence_get_begin_iter(s.values);
    var cp = point(it);
    var x = cp.timestamp;
    var y = cp.value;
    p[0] = 1.0;
    it = c.g_sequence_iter_next(it);
    cp = point(it);
    var xn = cp.timestamp;
    var yn = cp.value;
    h[0] = toF(xn -% x);
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        const yp = y;
        x = xn;
        y = yn;
        it = c.g_sequence_iter_next(it);
        cp = point(it);
        xn = cp.timestamp;
        yn = cp.value;
        h[i] = toF(xn -% x);
        o[i] = h[i - 1];
        p[i] = 2.0 * (h[i - 1] + h[i]);
        q[i] = h[i];
        b[i] = (yn - y) / h[i] - (y - yp) / h[i - 1];
    }
    p[n - 1] = 1.0;
    i = 1;
    while (i + 1 < n) : (i += 1) {
        const a = o[i] / p[i - 1];
        p[i] -= a * q[i - 1];
        b[i] -= a * b[i - 1];
    }
    i = n - 2;
    while (i > 0) : (i -= 1) z[i] = (b[i] - q[i] * z[i + 1]) / p[i];
    it = c.g_sequence_get_begin_iter(s.values);
    for (0..n) |k| {
        cp = point(it);
        cp.cache.cubic.h = h[k];
        cp.cache.cubic.z = z[k];
        it = c.g_sequence_iter_next(it);
    }
}

fn monoCache(s: *Timed) void {
    const n: usize = @intCast(s.nvalues);
    const buf: [*]f64 = @ptrCast(@alignCast(c.g_malloc0(n * 4 * @sizeOf(f64))));
    defer c.g_free(buf);
    const dxs = buf[0..n];
    const ms = buf[2 * n .. 3 * n];
    const c1s = buf[3 * n .. 4 * n];
    var it = c.g_sequence_get_begin_iter(s.values);
    var cp = point(it);
    var xn = cp.timestamp;
    var yn = cp.value;
    for (0..n - 1) |i| {
        const x = xn;
        const y = yn;
        it = c.g_sequence_iter_next(it);
        cp = point(it);
        xn = cp.timestamp;
        yn = cp.value;
        const dx = toF(xn -% x);
        const dy = yn - y;
        dxs[i] = dx;
        buf[n + i] = dy;
        ms[i] = dy / dx;
    }
    c1s[0] = ms[0];
    for (1..n) |i| {
        const m = ms[i - 1];
        const mn = ms[i];
        if (m * mn <= 0) {
            c1s[i] = 0.0;
        } else {
            const dx = dxs[i];
            const dxn = dxs[i + 1];
            const sum = dx + dxn;
            c1s[i] = 3.0 * sum / ((sum + dxn) / m + (sum + dx) / mn);
        }
    }
    c1s[n - 1] = ms[n - 1];
    it = c.g_sequence_get_begin_iter(s.values);
    for (0..n - 1) |i| {
        cp = point(it);
        const c1 = c1s[i];
        const m = ms[i];
        const inv = 1.0 / dxs[i];
        const common = c1 + c1s[i + 1] - m - m;
        cp.cache.cubic_monotonic.c1s = c1;
        cp.cache.cubic_monotonic.c2s = (m - c1 - common) * inv;
        cp.cache.cubic_monotonic.c3s = common * inv * inv;
        it = c.g_sequence_iter_next(it);
    }
}

fn cubic(s: *Timed, cp1: *Point, cp2: ?*Point, ts: u64) f64 {
    if (s.valid_cache == 0) {
        cubicCache(s);
        s.valid_cache = 1;
    }
    const p2 = cp2 orelse return cp1.value;
    const d1 = toF(ts -% cp1.timestamp);
    const d2 = toF(p2.timestamp -% ts);
    const h = cp1.cache.cubic.h;
    var out = (p2.cache.cubic.z * d1 * d1 * d1 + cp1.cache.cubic.z * d2 * d2 * d2) / h;
    out += (p2.value / h - h * p2.cache.cubic.z) * d1;
    out += (cp1.value / h - h * cp1.cache.cubic.z) * d2;
    return out;
}

fn mono(s: *Timed, cp1: *Point, cp2: ?*Point, ts: u64) f64 {
    if (s.valid_cache == 0) {
        monoCache(s);
        s.valid_cache = 1;
    }
    if (cp2 == null) return cp1.value;
    const d = toF(ts -% cp1.timestamp);
    const d2 = d * d;
    var out = cp1.value + cp1.cache.cubic_monotonic.c1s * d;
    out += cp1.cache.cubic_monotonic.c2s * d2;
    out += cp1.cache.cubic_monotonic.c3s * d * d2;
    return out;
}

fn eval(comptime m: Mode, s: *Timed, cp1: *Point, cp2: ?*Point, ts: u64) f64 {
    return switch (m) {
        .none => cp1.value,
        .linear => linear(cp1.timestamp, cp1.value, if (cp2) |p| p.timestamp else NONE, if (cp2) |p| p.value else 0.0, ts),
        .cubic => cubic(s, cp1, cp2, ts),
        .mono => mono(s, cp1, cp2, ts),
    };
}

fn Interp(comptime m: Mode) type {
    return struct {
        fn get(cs: [*c]Source, ts: c.GstClockTime, value: [*c]c.gdouble) callconv(.c) c.gboolean {
            const s: *Timed = @ptrCast(cs);
            if ((m == .cubic or m == .mono) and s.nvalues <= 2) return Interp(.linear).get(cs, ts, value);
            c.g_mutex_lock(&s.lock);
            defer c.g_mutex_unlock(&s.lock);
            var cp1: ?*Point = null;
            var cp2: ?*Point = null;
            if (m == .none) {
                const it = gst_timed_value_control_source_find_control_point_iter(s, ts) orelse return 0;
                value.* = point(it).value;
                return 1;
            }
            if (!nearest(s, ts, &cp1, &cp2)) return 0;
            value.* = eval(m, s, cp1.?, cp2, ts);
            return 1;
        }

        fn array(cs: [*c]Source, ts0: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.gdouble) callconv(.c) c.gboolean {
            const s: *Timed = @ptrCast(cs);
            if ((m == .cubic or m == .mono) and s.nvalues <= 2) return Interp(.linear).array(cs, ts0, interval, n, values);
            c.g_mutex_lock(&s.lock);
            defer c.g_mutex_unlock(&s.lock);
            var ret: c.gboolean = 0;
            var ts = ts0;
            var next: u64 = 0;
            var cp1: ?*Point = null;
            var cp2: ?*Point = null;
            for (0..n) |i| {
                if (ts >= next) nearest2(s, ts, &cp1, &cp2, &next);
                if (cp1) |p| {
                    values[i] = eval(m, s, p, cp2, ts);
                    ret = 1;
                } else values[i] = NAN;
                ts +%= interval;
            }
            return ret;
        }
    };
}

const InterpPriv = extern struct { mode: c.GstInterpolationMode };

fn interpPriv(s: anytype) *InterpPriv {
    const p: [*]u8 = @ptrCast(s);
    return @ptrCast(@alignCast(p + @as(usize, @bitCast(@as(isize, interp_offset)))));
}

fn setMode(s: *c.GstInterpolationControlSource, mode: c.gint) bool {
    if (mode >= 4 or mode < 0) return false;
    const t: *Timed = @ptrCast(s);
    const cs = src(t);
    c.g_mutex_lock(&t.lock);
    switch (mode) {
        0 => {
            cs.get_value = Interp(.none).get;
            cs.get_value_array = Interp(.none).array;
        },
        1 => {
            cs.get_value = Interp(.linear).get;
            cs.get_value_array = Interp(.linear).array;
        },
        2 => {
            cs.get_value = Interp(.cubic).get;
            cs.get_value_array = Interp(.cubic).array;
        },
        else => {
            cs.get_value = Interp(.mono).get;
            cs.get_value_array = Interp(.mono).array;
        },
    }
    gst_timed_value_control_invalidate_cache(t);
    interpPriv(s).mode = @intCast(mode);
    c.g_mutex_unlock(&t.lock);
    return true;
}

fn interpInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *c.GstInterpolationControlSource = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(interpPriv(s));
    _ = setMode(s, c.GST_INTERPOLATION_MODE_NONE);
}

fn interpSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *c.GstInterpolationControlSource = @ptrCast(@alignCast(o));
    if (id == 1) {
        _ = setMode(s, c.g_value_get_enum(v));
    } else check.warnInvalid(o, id, spec, "../libs/gst/controller/gstinterpolationcontrolsource.c", 706);
}

fn interpGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *c.GstInterpolationControlSource = @ptrCast(@alignCast(o));
    if (id == 1) {
        c.g_value_set_enum(v, @intCast(interpPriv(s).mode));
    } else check.warnInvalid(o, id, spec, "../libs/gst/controller/gstinterpolationcontrolsource.c", 723);
}

fn interpClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(k, &interp_offset);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = interpSet;
    gc.get_property = interpGet;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_enum("mode", "Mode", "Interpolation mode", gst_interpolation_mode_get_type(), c.GST_INTERPOLATION_MODE_NONE, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
}

pub export fn gst_interpolation_control_source_get_type() c.GType {
    return interp_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(gst_timed_value_control_source_get_type, "GstInterpolationControlSource", c.GstInterpolationControlSourceClass, c.GstInterpolationControlSource, interpClassInit, interpInit, 0);
            interp_offset = c.g_type_add_instance_private(t, @sizeOf(InterpPriv));
            _ = c._gst_debug_category_new("interpolation control source", 0, "timeline value interpolating control source");
            return t;
        }
    }.f);
}

pub export fn gst_interpolation_control_source_new() [*c]Source {
    const cs = c.g_object_new(gst_interpolation_control_source_get_type(), null);
    _ = c.gst_object_ref_sink(cs);
    return @ptrCast(@alignCast(cs));
}

const TriggerPriv = extern struct { tolerance: i64 };

fn triggerPriv(s: anytype) *TriggerPriv {
    const p: [*]u8 = @ptrCast(s);
    return @ptrCast(@alignCast(p + @as(usize, @bitCast(@as(isize, trigger_offset)))));
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn trigger(s: *Timed, it0: *c.GSequenceIter, ts: u64) f64 {
    const tol = triggerPriv(s).tolerance;
    var cp = point(it0);
    if (diff(cp.timestamp, ts) <= tol) return cp.value;
    const it = c.g_sequence_iter_next(it0);
    if (it != null and c.g_sequence_iter_is_end(it) == 0) {
        cp = point(it);
        if (diff(ts, cp.timestamp) <= tol) return cp.value;
    }
    return NAN;
}

fn triggerGet(cs: [*c]Source, ts: c.GstClockTime, value: [*c]c.gdouble) callconv(.c) c.gboolean {
    const s: *Timed = @ptrCast(cs);
    c.g_mutex_lock(&s.lock);
    defer c.g_mutex_unlock(&s.lock);
    const it = gst_timed_value_control_source_find_control_point_iter(s, ts) orelse return 0;
    value.* = trigger(s, it, ts);
    return @intFromBool(!std.math.isNan(value.*));
}

fn triggerArray(cs: [*c]Source, ts0: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.gdouble) callconv(.c) c.gboolean {
    const s: *Timed = @ptrCast(cs);
    c.g_mutex_lock(&s.lock);
    defer c.g_mutex_unlock(&s.lock);
    var ret: c.gboolean = 0;
    var ts = ts0;
    var next: u64 = 0;
    var it1: ?*c.GSequenceIter = null;
    var triggered = false;
    for (0..n) |i| {
        var val = NAN;
        if (ts >= next) {
            it1 = gst_timed_value_control_source_find_control_point_iter(s, ts);
            const it2 = if (it1) |x| c.g_sequence_iter_next(x) else if (s.values != null) c.g_sequence_get_begin_iter(s.values) else null;
            next = if (it2 != null and c.g_sequence_iter_is_end(it2) == 0) point(it2).timestamp else NONE;
            const x = it1 orelse return 0;
            val = trigger(s, x, ts);
            if (!std.math.isNan(val)) ret = 1;
            triggered = true;
        } else if (triggered) {
            const x = it1 orelse return 0;
            val = trigger(s, x, ts);
            if (!std.math.isNan(val)) ret = 1;
            triggered = false;
        }
        values[i] = val;
        ts +%= interval;
    }
    return ret;
}

fn triggerInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *c.GstTriggerControlSource = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(triggerPriv(s));
    const cs: *Source = @ptrCast(@alignCast(inst));
    cs.get_value = triggerGet;
    cs.get_value_array = triggerArray;
}

fn triggerSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const t: *Timed = @ptrCast(@alignCast(o));
    if (id == 1) {
        c.g_mutex_lock(&t.lock);
        triggerPriv(o).tolerance = c.g_value_get_int64(v);
        c.g_mutex_unlock(&t.lock);
    } else check.warnInvalid(o, id, spec, "../libs/gst/controller/gsttriggercontrolsource.c", 229);
}

fn triggerGetProp(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == 1) {
        c.g_value_set_int64(v, triggerPriv(o).tolerance);
    } else check.warnInvalid(o, id, spec, "../libs/gst/controller/gsttriggercontrolsource.c", 245);
}

fn triggerClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(k, &trigger_offset);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = triggerSet;
    gc.get_property = triggerGetProp;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_int64("tolerance", "Tolerance", "Amount of ns a control time can be off to still trigger", 0, std.math.maxInt(i64), 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
}

pub export fn gst_trigger_control_source_get_type() c.GType {
    return trigger_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(gst_timed_value_control_source_get_type, "GstTriggerControlSource", c.GstTriggerControlSourceClass, c.GstTriggerControlSource, triggerClassInit, triggerInit, 0);
            trigger_offset = c.g_type_add_instance_private(t, @sizeOf(TriggerPriv));
            _ = c._gst_debug_category_new("trigger control source", 0, "timeline value trigger control source");
            return t;
        }
    }.f);
}

pub export fn gst_trigger_control_source_new() [*c]Source {
    const cs = c.g_object_new(gst_trigger_control_source_get_type(), null);
    _ = c.gst_object_ref_sink(cs);
    return @ptrCast(@alignCast(cs));
}

const LfoPriv = extern struct {
    waveform: c.GstLFOWaveform,
    frequency: f64,
    period: u64,
    timeshift: u64,
    amplitude: f64,
    offset: f64,
};

const Lfo = c.GstLFOControlSource;

fn lfoPriv(s: anytype) *LfoPriv {
    const p: [*]u8 = @ptrCast(s);
    return @ptrCast(@alignCast(p + @as(usize, @bitCast(@as(isize, lfo_offset)))));
}

fn pos(ts0: u64, shift: u64, period: u64) u64 {
    var ts = ts0;
    while (ts < shift) ts +%= period;
    ts -%= shift;
    return ts % period;
}

const Wave = enum { sine, square, saw, rsaw, triangle };

fn wave(comptime w: Wave, p: *LfoPriv, ts: u64) f64 {
    const amp = p.amplitude;
    const x = pos(ts, p.timeshift, p.period);
    const at = toF(x);
    const per = toF(p.period);
    const r: f64 = switch (w) {
        .sine => libm.sin(2.0 * std.math.pi * (p.frequency / 1e9) * at) * amp,
        .square => if (x >= p.period / 2) amp else -amp,
        .saw => -((at - per / 2.0) * ((2.0 * amp) / per)),
        .rsaw => (at - per / 2.0) * ((2.0 * amp) / per),
        .triangle => if (at <= 0.25 * per) at * ((4.0 * amp) / per) else if (at <= 0.75 * per) -(at - per / 2.0) * ((4.0 * amp) / per) else -(per - at) * ((4.0 * amp) / per),
    };
    return r + p.offset;
}

fn Osc(comptime w: Wave) type {
    return struct {
        fn get(cs: [*c]Source, ts: c.GstClockTime, value: [*c]c.gdouble) callconv(.c) c.gboolean {
            const s: *Lfo = @ptrCast(@alignCast(cs));
            _ = c.gst_object_sync_values(@ptrCast(s), ts);
            c.g_mutex_lock(&s.lock);
            value.* = wave(w, lfoPriv(s), ts);
            c.g_mutex_unlock(&s.lock);
            return 1;
        }

        fn array(cs: [*c]Source, ts0: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.gdouble) callconv(.c) c.gboolean {
            const s: *Lfo = @ptrCast(@alignCast(cs));
            var ts = ts0;
            for (0..n) |i| {
                _ = c.gst_object_sync_values(@ptrCast(s), ts);
                c.g_mutex_lock(&s.lock);
                values[i] = wave(w, lfoPriv(s), ts);
                c.g_mutex_unlock(&s.lock);
                ts +%= interval;
            }
            return 1;
        }
    };
}

fn setWave(s: *Lfo, w: c.gint) bool {
    if (w >= 5 or w < 0) return false;
    const cs: *Source = @ptrCast(s);
    switch (w) {
        0 => {
            cs.get_value = Osc(.sine).get;
            cs.get_value_array = Osc(.sine).array;
        },
        1 => {
            cs.get_value = Osc(.square).get;
            cs.get_value_array = Osc(.square).array;
        },
        2 => {
            cs.get_value = Osc(.saw).get;
            cs.get_value_array = Osc(.saw).array;
        },
        3 => {
            cs.get_value = Osc(.rsaw).get;
            cs.get_value_array = Osc(.rsaw).array;
        },
        else => {
            cs.get_value = Osc(.triangle).get;
            cs.get_value_array = Osc(.triangle).array;
        },
    }
    lfoPriv(s).waveform = @intCast(w);
    return true;
}

fn lfoInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Lfo = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(lfoPriv(s));
    const p = lfoPriv(s);
    p.waveform = @intFromBool(setWave(s, c.GST_LFO_WAVEFORM_SINE));
    p.frequency = 1.0;
    p.amplitude = 1.0;
    p.period = 1000000000;
    p.timeshift = 0;
    c.g_mutex_init(&s.lock);
}

fn lfoFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Lfo = @ptrCast(@alignCast(o));
    const cs: *Source = @ptrCast(s);
    cs.get_value = null;
    cs.get_value_array = null;
    c.g_mutex_clear(&s.lock);
    lfo_parent.?.finalize.?(o);
}

const LFO_FILE = "../libs/gst/controller/gstlfocontrolsource.c";

fn lfoSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Lfo = @ptrCast(@alignCast(o));
    const p = lfoPriv(s);
    switch (id) {
        1 => {
            c.g_mutex_lock(&s.lock);
            _ = setWave(s, c.g_value_get_enum(v));
            c.g_mutex_unlock(&s.lock);
        },
        2 => {
            const f = c.g_value_get_double(v);
            if (!check.that(check.toU64(1e9 / f) != 0, "gst_lfo_control_source_set_property", "((GstClockTime) (GST_SECOND / frequency)) != 0")) return;
            c.g_mutex_lock(&s.lock);
            p.frequency = f;
            p.period = check.toU64(1e9 / f);
            c.g_mutex_unlock(&s.lock);
        },
        3 => {
            c.g_mutex_lock(&s.lock);
            p.timeshift = c.g_value_get_uint64(v);
            c.g_mutex_unlock(&s.lock);
        },
        4 => {
            c.g_mutex_lock(&s.lock);
            p.amplitude = c.g_value_get_double(v);
            c.g_mutex_unlock(&s.lock);
        },
        5 => {
            c.g_mutex_lock(&s.lock);
            p.offset = c.g_value_get_double(v);
            c.g_mutex_unlock(&s.lock);
        },
        else => check.warnInvalid(o, id, spec, LFO_FILE, 496),
    }
}

fn lfoGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = lfoPriv(o);
    switch (id) {
        1 => c.g_value_set_enum(v, @intCast(p.waveform)),
        2 => c.g_value_set_double(v, p.frequency),
        3 => c.g_value_set_uint64(v, p.timeshift),
        4 => c.g_value_set_double(v, p.amplitude),
        5 => c.g_value_set_double(v, p.offset),
        else => check.warnInvalid(o, id, spec, LFO_FILE, 524),
    }
}

fn lfoClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    lfo_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    c.g_type_class_adjust_private_offset(k, &lfo_offset);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = lfoFinalize;
    gc.set_property = lfoSet;
    gc.get_property = lfoGet;
    const rw = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    const ctl = rw | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_enum("waveform", "Waveform", "Waveform", gst_lfo_waveform_get_type(), c.GST_LFO_WAVEFORM_SINE, rw));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_double("frequency", "Frequency", "Frequency of the waveform", std.math.floatMin(f64), std.math.floatMax(f64), 1.0, ctl));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_uint64("timeshift", "Timeshift", "Timeshift of the waveform to the right", 0, std.math.maxInt(u64), 0, ctl));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_double("amplitude", "Amplitude", "Amplitude of the waveform", 0.0, 1.0, 1.0, ctl));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_double("offset", "Offset", "Offset of the waveform", 0.0, 1.0, 1.0, ctl));
}

pub export fn gst_lfo_control_source_get_type() c.GType {
    return lfo_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_control_source_get_type, "GstLFOControlSource", c.GstLFOControlSourceClass, Lfo, lfoClassInit, lfoInit, 0);
            lfo_offset = c.g_type_add_instance_private(t, @sizeOf(LfoPriv));
            _ = c._gst_debug_category_new("lfo control source", 0, "low frequency oscillator control source");
            return t;
        }
    }.f);
}

pub export fn gst_lfo_control_source_new() [*c]Source {
    const cs = c.g_object_new(gst_lfo_control_source_get_type(), null);
    _ = c.gst_object_ref_sink(cs);
    return @ptrCast(@alignCast(cs));
}
