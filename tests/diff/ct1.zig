const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const MS: u64 = 1_000_000;
const SEC: u64 = 1_000_000_000;
const NONE: u64 = std.math.maxInt(u64);

const Target = extern struct {
    parent: c.GstObject,
    i: c.gint,
    u: c.guint,
    l: c.glong,
    ul: c.gulong,
    i64: c.gint64,
    u64: c.guint64,
    f: c.gfloat,
    d: c.gdouble,
    b: c.gboolean,
    e: c.gint,
    color: c.guint,
    s: [*c]u8,
};

const TargetClass = extern struct {
    parent: c.GstObjectClass,
};

fn tof(o: anytype) *Target {
    return @ptrCast(@alignCast(o));
}

fn targetSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const t = tof(o);
    switch (id) {
        1 => t.i = c.g_value_get_int(v),
        2 => t.u = c.g_value_get_uint(v),
        3 => t.l = c.g_value_get_long(v),
        4 => t.ul = c.g_value_get_ulong(v),
        5 => t.i64 = c.g_value_get_int64(v),
        6 => t.u64 = c.g_value_get_uint64(v),
        7 => t.f = c.g_value_get_float(v),
        8 => t.d = c.g_value_get_double(v),
        9 => t.b = c.g_value_get_boolean(v),
        10 => t.e = c.g_value_get_enum(v),
        11 => t.color = c.g_value_get_uint(v),
        12 => {
            c.g_free(t.s);
            t.s = c.g_value_dup_string(v);
        },
        else => {},
    }
}

fn targetGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const t = tof(o);
    switch (id) {
        1 => c.g_value_set_int(v, t.i),
        2 => c.g_value_set_uint(v, t.u),
        3 => c.g_value_set_long(v, t.l),
        4 => c.g_value_set_ulong(v, t.ul),
        5 => c.g_value_set_int64(v, t.i64),
        6 => c.g_value_set_uint64(v, t.u64),
        7 => c.g_value_set_float(v, t.f),
        8 => c.g_value_set_double(v, t.d),
        9 => c.g_value_set_boolean(v, t.b),
        10 => c.g_value_set_enum(v, t.e),
        11 => c.g_value_set_uint(v, t.color),
        12 => c.g_value_set_string(v, t.s),
        else => {},
    }
}

fn targetClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = targetSet;
    gc.get_property = targetGet;
    const f = c.G_PARAM_READWRITE | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_int("i", "i", "i", -100, 300, 0, f));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_uint("u", "u", "u", 5, 1000, 5, f));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_long("l", "l", "l", -5000000000, 7000000000, 0, f));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_ulong("ul", "ul", "ul", 0, std.math.maxInt(c.gulong), 0, f));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_int64("i64", "i64", "i64", std.math.minInt(i64), std.math.maxInt(i64), 0, f));
    c.g_object_class_install_property(gc, 6, c.g_param_spec_uint64("u64", "u64", "u64", 10, 1 << 40, 10, f));
    c.g_object_class_install_property(gc, 7, c.g_param_spec_float("f", "f", "f", -2.5, 2.5, 0, f));
    c.g_object_class_install_property(gc, 8, c.g_param_spec_double("d", "d", "d", -1.0, 10.0, 0, f));
    c.g_object_class_install_property(gc, 9, c.g_param_spec_boolean("b", "b", "b", 0, f));
    c.g_object_class_install_property(gc, 10, c.g_param_spec_enum("e", "e", "e", c.gst_format_get_type(), c.GST_FORMAT_DEFAULT, f));
    c.g_object_class_install_property(gc, 11, c.g_param_spec_uint("color", "color", "color", 0, std.math.maxInt(c.guint), 0, f));
    c.g_object_class_install_property(gc, 12, c.g_param_spec_string("s", "s", "s", null, f));
}

var target_type: c.GType = 0;

fn targetType() c.GType {
    if (target_type == 0) target_type = c.g_type_register_static_simple(c.gst_object_get_type(), "CtTarget", @sizeOf(TargetClass), targetClassInit, @sizeOf(Target), null, 0);
    return target_type;
}

fn logger(domain: [*c]const u8, level: c.GLogLevelFlags, msg: [*c]const u8, _: c.gpointer) callconv(.c) void {
    out("  log {s} {d} {s}", .{ str(domain), level & c.G_LOG_LEVEL_MASK, str(msg) });
}

fn bits(x: f64) u64 {
    return @bitCast(x);
}

fn dump(cs: [*c]c.GstControlSource, name: []const u8) void {
    out(" {s}", .{name});
    const times = [_]u64{ 0, 1, 5 * MS, 99 * MS, 100 * MS, 150 * MS, 250 * MS, 333 * MS, 500 * MS, 777 * MS, SEC, 2 * SEC, 5 * SEC };
    for (times) |t| {
        var v: f64 = 0;
        const r = c.gst_control_source_get_value(cs, t, &v);
        out("  get {d} -> {d} {x}", .{ t, r, if (r != 0) bits(v) else 0 });
    }
    var arr: [40]f64 = undefined;
    const r = c.gst_control_source_get_value_array(cs, 0, 37 * MS, arr.len, &arr);
    var h = std.hash.Fnv1a_64.init();
    for (arr) |x| h.update(std.mem.asBytes(&x));
    out("  array {d} {x} first {x} last {x}", .{ r, h.final(), bits(arr[0]), bits(arr[39]) });
}

fn onPoint(_: ?*anyopaque, cp: [*c]c.GstControlPoint, tag: c.gpointer) callconv(.c) void {
    out("  signal {s} {d} {x}", .{ str(@ptrCast(tag)), cp.*.timestamp, bits(cp.*.value) });
}

fn points(cs: [*c]c.GstControlSource) [*c]c.GstTimedValueControlSource {
    const t: [*c]c.GstTimedValueControlSource = @ptrCast(@alignCast(cs));
    _ = c.gst_timed_value_control_source_set(t, 0, 0.0);
    _ = c.gst_timed_value_control_source_set(t, 100 * MS, 1.0);
    _ = c.gst_timed_value_control_source_set(t, 250 * MS, 0.25);
    _ = c.gst_timed_value_control_source_set(t, 500 * MS, 0.8);
    _ = c.gst_timed_value_control_source_set(t, SEC, 0.1);
    return t;
}

fn sources() void {
    out("interpolation", .{});
    const modes = [_][]const u8{ "none", "linear", "cubic", "cubic-monotonic" };
    for (0..4) |m| {
        const cs = c.gst_interpolation_control_source_new();
        const t = points(cs);
        c.g_object_set(cs, "mode", @as(c.gint, @intCast(m)), @as(?*anyopaque, null));
        var mode: c.gint = -1;
        c.g_object_get(cs, "mode", &mode, @as(?*anyopaque, null));
        out(" mode {d} count {d}", .{ mode, c.gst_timed_value_control_source_get_count(t) });
        dump(cs, modes[m]);
        _ = c.gst_timed_value_control_source_set(t, 300 * MS, 0.9);
        dump(cs, "after insert");
        _ = c.gst_timed_value_control_source_unset(t, 100 * MS);
        dump(cs, "after unset");
        c.gst_object_unref(cs);
    }
    const two = c.gst_interpolation_control_source_new();
    c.g_object_set(two, "mode", @as(c.gint, c.GST_INTERPOLATION_MODE_CUBIC), @as(?*anyopaque, null));
    const tt: [*c]c.GstTimedValueControlSource = @ptrCast(@alignCast(two));
    _ = c.gst_timed_value_control_source_set(tt, 10 * MS, 0.5);
    _ = c.gst_timed_value_control_source_set(tt, 400 * MS, 0.2);
    dump(two, "cubic two points");
    c.g_object_set(two, "mode", @as(c.gint, 9), @as(?*anyopaque, null));
    var mode: c.gint = -1;
    c.g_object_get(two, "mode", &mode, @as(?*anyopaque, null));
    out(" bad mode kept {d}", .{mode});
    c.gst_object_unref(two);

    out("timed api", .{});
    const cs = c.gst_interpolation_control_source_new();
    const t: [*c]c.GstTimedValueControlSource = @ptrCast(@alignCast(cs));
    _ = c.g_signal_connect_data(cs, "value-added", @ptrCast(&onPoint), @constCast("added"), null, 0);
    _ = c.g_signal_connect_data(cs, "value-changed", @ptrCast(&onPoint), @constCast("changed"), null, 0);
    _ = c.g_signal_connect_data(cs, "value-removed", @ptrCast(&onPoint), @constCast("removed"), null, 0);
    var n: c.gsize = 7;
    out(" empty list {d} {d}", .{ @intFromBool(c.gst_timed_value_control_source_list_control_points(t, &n) == null), n });
    out(" empty all {d}", .{@intFromBool(c.gst_timed_value_control_source_get_all(t) == null)});
    out(" unset missing {d}", .{c.gst_timed_value_control_source_unset(t, 5)});
    _ = points(cs);
    out(" set again {d}", .{c.gst_timed_value_control_source_set(t, 250 * MS, 0.75)});
    out(" set none {d}", .{c.gst_timed_value_control_source_set(t, NONE, 0.75)});
    var tv = [_]c.GstTimedValue{ .{ .timestamp = 3 * SEC, .value = 0.3 }, .{ .timestamp = NONE, .value = 0.4 }, .{ .timestamp = 4 * SEC, .value = 0.5 } };
    var l: [*c]c.GSList = null;
    for (&tv) |*x| l = c.g_slist_append(l, x);
    out(" from list {d}", .{c.gst_timed_value_control_source_set_from_list(t, l)});
    c.g_slist_free(l);
    const arr = c.gst_timed_value_control_source_list_control_points(t, &n);
    for (0..n) |i| out("  point {d} {x}", .{ arr[i].timestamp, bits(arr[i].value) });
    c.g_free(arr);
    var all = c.gst_timed_value_control_source_get_all(t);
    var k: usize = 0;
    var it = all;
    while (it != null) : (it = it.*.next) k += 1;
    out(" all {d}", .{k});
    c.g_list_free(all);
    all = null;
    const fi = c.gst_timed_value_control_source_find_control_point_iter(t, 260 * MS);
    if (fi != null) {
        const cp: *c.GstControlPoint = @ptrCast(@alignCast(c.g_sequence_get(fi)));
        out(" find {d}", .{cp.timestamp});
    }
    out(" find before {d}", .{@intFromBool(c.gst_timed_value_control_source_find_control_point_iter(t, 0) != null)});
    c.gst_timed_value_control_invalidate_cache(t);
    c.gst_timed_value_control_source_unset_all(t);
    out(" after unset all {d}", .{c.gst_timed_value_control_source_get_count(t)});
    var cpv = c.GstControlPoint{ .timestamp = 42, .value = 4.2, .cache = undefined };
    const cp2 = c.gst_control_point_copy(&cpv);
    out(" copy {d} {x}", .{ cp2.*.timestamp, bits(cp2.*.value) });
    const bx: [*c]c.GstControlPoint = @ptrCast(@alignCast(c.g_boxed_copy(c.gst_control_point_get_type(), cp2)));
    out(" boxed {d} {s}", .{ bx.*.timestamp, str(c.g_type_name(c.gst_control_point_get_type())) });
    c.g_boxed_free(c.gst_control_point_get_type(), bx);
    c.gst_control_point_free(cp2);
    c.gst_object_unref(cs);

    out("trigger", .{});
    for ([_]i64{ 0, @intCast(10 * MS), @intCast(60 * MS) }) |tol| {
        const tr = c.gst_trigger_control_source_new();
        _ = points(tr);
        c.g_object_set(tr, "tolerance", tol, @as(?*anyopaque, null));
        var got: i64 = -1;
        c.g_object_get(tr, "tolerance", &got, @as(?*anyopaque, null));
        out(" tolerance {d}", .{got});
        dump(tr, "trigger");
        var arr2: [12]f64 = undefined;
        const r = c.gst_control_source_get_value_array(tr, 95 * MS, 5 * MS, arr2.len, &arr2);
        out("  dense {d}", .{r});
        for (arr2) |x| out("   {x}", .{bits(x)});
        c.gst_object_unref(tr);
    }
    const empty = c.gst_trigger_control_source_new();
    var arr3: [3]f64 = undefined;
    out(" empty trigger {d}", .{c.gst_control_source_get_value_array(empty, 0, MS, 3, &arr3)});
    c.gst_object_unref(empty);

    out("lfo", .{});
    const waves = [_][]const u8{ "sine", "square", "saw", "reverse-saw", "triangle" };
    const fresh = c.gst_lfo_control_source_new();
    var w: c.gint = -1;
    var fr: f64 = 0;
    var am: f64 = 0;
    var of: f64 = 0;
    var ts: u64 = 9;
    c.g_object_get(fresh, "waveform", &w, "frequency", &fr, "amplitude", &am, "offset", &of, "timeshift", &ts, @as(?*anyopaque, null));
    out(" defaults {d} {x} {x} {x} {d}", .{ w, bits(fr), bits(am), bits(of), ts });
    dump(fresh, "default");
    c.gst_object_unref(fresh);
    for (0..5) |i| {
        const lfo = c.gst_lfo_control_source_new();
        c.g_object_set(lfo, "waveform", @as(c.gint, @intCast(i)), "frequency", @as(f64, 3.0), "amplitude", @as(f64, 0.4), "offset", @as(f64, 0.5), "timeshift", @as(u64, 70 * MS), @as(?*anyopaque, null));
        dump(lfo, waves[i]);
        c.gst_object_unref(lfo);
    }
    const bad = c.gst_lfo_control_source_new();
    c.g_object_set(bad, "frequency", @as(f64, 2e9), @as(?*anyopaque, null));
    c.g_object_set(bad, "waveform", @as(c.gint, 7), @as(?*anyopaque, null));
    c.g_object_get(bad, "waveform", &w, "frequency", &fr, @as(?*anyopaque, null));
    out(" bad {d} {x}", .{ w, bits(fr) });
    c.gst_object_unref(bad);
}

fn props(o: *Target) void {
    out("  props i {d} u {d} l {d} ul {d} i64 {d} u64 {d} f {x} d {x} b {d} e {d} color {x}", .{ o.i, o.u, o.l, o.ul, o.i64, o.u64, @as(u32, @bitCast(o.f)), bits(o.d), o.b, o.e, o.color });
}

const names = [_][:0]const u8{ "i", "u", "l", "ul", "i64", "u64", "f", "d", "b", "e" };

fn bindings(absolute: bool) void {
    out("direct absolute={}", .{absolute});
    const o: *Target = @ptrCast(@alignCast(c.g_object_new(targetType(), null)));
    _ = c.gst_object_ref_sink(o);
    const cs = c.gst_interpolation_control_source_new();
    const t: [*c]c.GstTimedValueControlSource = @ptrCast(@alignCast(cs));
    c.g_object_set(cs, "mode", @as(c.gint, c.GST_INTERPOLATION_MODE_LINEAR), @as(?*anyopaque, null));
    if (absolute) {
        _ = c.gst_timed_value_control_source_set(t, 0, -3.5);
        _ = c.gst_timed_value_control_source_set(t, SEC, 12.5);
    } else {
        _ = c.gst_timed_value_control_source_set(t, 0, -0.2);
        _ = c.gst_timed_value_control_source_set(t, SEC, 1.3);
    }
    for (names) |nm| {
        const b = if (absolute) c.gst_direct_control_binding_new_absolute(@ptrCast(o), nm.ptr, cs) else c.gst_direct_control_binding_new(@ptrCast(o), nm.ptr, cs);
        var abs: c.gboolean = 7;
        var got: ?*anyopaque = null;
        c.g_object_get(b, "absolute", &abs, "control-source", &got, @as(?*anyopaque, null));
        if (got) |g| c.gst_object_unref(g);
        out(" bind {s} abs {d} same {d} add {d}", .{ nm, abs, @intFromBool(got == @as(?*anyopaque, @ptrCast(cs))), c.gst_object_add_control_binding(@ptrCast(o), b) });
    }
    for ([_]u64{ 0, 125 * MS, 250 * MS, 377 * MS, 500 * MS, 625 * MS, 750 * MS, 900 * MS, SEC, 2 * SEC }) |ts| {
        out(" sync {d} -> {d}", .{ ts, c.gst_object_sync_values(@ptrCast(o), ts) });
        props(o);
    }
    for (names) |nm| {
        const b = c.gst_object_get_control_binding(@ptrCast(o), nm.ptr);
        const v = c.gst_control_binding_get_value(b, 333 * MS);
        if (v != null) {
            const s = c.g_strdup_value_contents(v);
            out(" value {s} {s}", .{ nm, str(s) });
            c.g_free(s);
            c.g_value_unset(v);
            c.g_free(v);
        }
        var raw: [16]u64 = .{0} ** 16;
        const r = c.gst_control_binding_get_value_array(b, 0, 70 * MS, 16, &raw);
        var h = std.hash.Fnv1a_64.init();
        h.update(std.mem.asBytes(&raw));
        out(" array {s} {d} {x}", .{ nm, r, h.final() });
        var gv = std.mem.zeroes([6]c.GValue);
        const gr = c.gst_control_binding_get_g_value_array(b, 0, 190 * MS, 6, &gv);
        out(" garray {s} {d}", .{ nm, gr });
        for (&gv) |*x| {
            if (x.g_type != 0) {
                const s = c.g_strdup_value_contents(x);
                out("  {s}", .{str(s)});
                c.g_free(s);
                c.g_value_unset(x);
            }
        }
        c.gst_object_unref(b);
    }
    const sb = c.gst_direct_control_binding_new(@ptrCast(o), "s", cs);
    out(" string binding pspec {d}", .{@intFromBool(sb.*.pspec != null)});
    _ = c.gst_object_ref_sink(sb);
    c.gst_object_unref(sb);
    c.gst_object_unref(cs);
    c.gst_object_unref(o);
}

fn argb() void {
    out("argb", .{});
    const o: *Target = @ptrCast(@alignCast(c.g_object_new(targetType(), null)));
    _ = c.gst_object_ref_sink(o);
    var cs: [4][*c]c.GstControlSource = undefined;
    for (0..4) |i| {
        cs[i] = c.gst_interpolation_control_source_new();
        c.g_object_set(cs[i], "mode", @as(c.gint, c.GST_INTERPOLATION_MODE_LINEAR), @as(?*anyopaque, null));
        const t: [*c]c.GstTimedValueControlSource = @ptrCast(@alignCast(cs[i]));
        _ = c.gst_timed_value_control_source_set(t, @as(u64, i) * 100 * MS, 0.1 * @as(f64, @floatFromInt(i)));
        _ = c.gst_timed_value_control_source_set(t, SEC, 1.0 - 0.2 * @as(f64, @floatFromInt(i)));
    }
    const b = c.gst_argb_control_binding_new(@ptrCast(o), "color", cs[0], cs[1], cs[2], cs[3]);
    out(" add {d}", .{c.gst_object_add_control_binding(@ptrCast(o), b)});
    for ([_]u64{ 0, 50 * MS, 150 * MS, 333 * MS, 700 * MS, SEC }) |ts| {
        out(" sync {d} -> {d} color {x}", .{ ts, c.gst_object_sync_values(@ptrCast(o), ts), o.color });
    }
    const v = c.gst_control_binding_get_value(b, 444 * MS);
    if (v != null) {
        out(" value {x}", .{c.g_value_get_uint(v)});
        c.g_value_unset(v);
        c.g_free(v);
    }
    var raw: [10]u32 = undefined;
    out(" array {d}", .{c.gst_control_binding_get_value_array(b, 0, 110 * MS, 10, &raw)});
    for (raw) |x| out("  {x}", .{x});
    var gv = std.mem.zeroes([4]c.GValue);
    out(" garray {d}", .{c.gst_control_binding_get_g_value_array(b, 0, 300 * MS, 4, &gv)});
    for (&gv) |*x| {
        out("  {x}", .{c.g_value_get_uint(x)});
        c.g_value_unset(x);
    }
    var a: ?*anyopaque = null;
    c.g_object_get(b, "control-source-a", &a, @as(?*anyopaque, null));
    out(" a same {d}", .{@intFromBool(a == @as(?*anyopaque, @ptrCast(cs[0])))});
    if (a) |p| c.gst_object_unref(p);
    const only = c.gst_argb_control_binding_new(@ptrCast(o), "u", null, cs[1], null, null);
    _ = c.gst_object_add_control_binding(@ptrCast(o), only);
    out(" partial sync {d} color {x} u {d}", .{ c.gst_object_sync_values(@ptrCast(o), 600 * MS), o.color, o.u });
    const wrong = c.gst_argb_control_binding_new(@ptrCast(o), "d", cs[0], null, null, null);
    out(" wrong pspec {d}", .{@intFromBool(wrong.*.pspec != null)});
    _ = c.gst_object_ref_sink(wrong);
    c.gst_object_unref(wrong);
    for (cs) |x| c.gst_object_unref(x);
    c.gst_object_unref(o);
}

fn proxy() void {
    out("proxy", .{});
    const a: *Target = @ptrCast(@alignCast(c.g_object_new(targetType(), null)));
    const b: *Target = @ptrCast(@alignCast(c.g_object_new(targetType(), null)));
    _ = c.gst_object_ref_sink(a);
    _ = c.gst_object_ref_sink(b);
    const cs = c.gst_interpolation_control_source_new();
    c.g_object_set(cs, "mode", @as(c.gint, c.GST_INTERPOLATION_MODE_LINEAR), @as(?*anyopaque, null));
    const t: [*c]c.GstTimedValueControlSource = @ptrCast(@alignCast(cs));
    _ = c.gst_timed_value_control_source_set(t, 0, 0.0);
    _ = c.gst_timed_value_control_source_set(t, SEC, 1.0);
    _ = c.gst_object_add_control_binding(@ptrCast(b), c.gst_direct_control_binding_new(@ptrCast(b), "d", cs));
    const p = c.gst_proxy_control_binding_new(@ptrCast(a), "d", @ptrCast(b), "d");
    out(" add {d}", .{c.gst_object_add_control_binding(@ptrCast(a), p)});
    out(" sync {d} a {x} b {x}", .{ c.gst_object_sync_values(@ptrCast(a), 400 * MS), bits(a.d), bits(b.d) });
    const v = c.gst_control_binding_get_value(p, 700 * MS);
    if (v != null) {
        out(" value {x}", .{bits(c.g_value_get_double(v))});
        c.g_value_unset(v);
        c.g_free(v);
    }
    var raw: [5]f64 = undefined;
    out(" array {d}", .{c.gst_control_binding_get_value_array(p, 0, 200 * MS, 5, &raw)});
    for (raw) |x| out("  {x}", .{bits(x)});
    const q = c.gst_proxy_control_binding_new(@ptrCast(a), "i", @ptrCast(b), "i");
    _ = c.gst_object_add_control_binding(@ptrCast(a), q);
    out(" missing ref binding sync {d} value {d}", .{ c.gst_object_sync_values(@ptrCast(a), 0), @intFromBool(c.gst_control_binding_get_value(q, 0) == null) });
    c.gst_object_unref(b);
    out(" dead ref sync {d} array {d}", .{ c.gst_control_binding_sync_values(p, @ptrCast(a), 0, NONE), c.gst_control_binding_get_value_array(p, 0, MS, 5, &raw) });
    out(" bad new {d}", .{@intFromBool(c.gst_proxy_control_binding_new(@ptrCast(a), null, @ptrCast(a), "d") == null)});
    c.gst_object_unref(cs);
    c.gst_object_unref(a);
}

pub fn main() void {
    c.gst_init(null, null);
    _ = c.g_log_set_handler("GStreamer-Controller", c.G_LOG_LEVEL_MASK | c.G_LOG_FLAG_FATAL | c.G_LOG_FLAG_RECURSION, logger, null);
    _ = c.g_log_set_handler("GStreamer", c.G_LOG_LEVEL_MASK | c.G_LOG_FLAG_FATAL | c.G_LOG_FLAG_RECURSION, logger, null);
    for ([_]c.GType{ c.gst_interpolation_mode_get_type(), c.gst_lfo_waveform_get_type() }) |t| {
        const k: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
        out("enum {s}", .{str(c.g_type_name(t))});
        for (0..k.n_values) |i| out("  {d} {s} {s}", .{ k.values[i].value, str(k.values[i].value_name), str(k.values[i].value_nick) });
    }
    for ([_]c.GType{ c.gst_timed_value_control_source_get_type(), c.gst_interpolation_control_source_get_type(), c.gst_trigger_control_source_get_type(), c.gst_lfo_control_source_get_type(), c.gst_direct_control_binding_get_type(), c.gst_argb_control_binding_get_type(), c.gst_proxy_control_binding_get_type() }) |t| {
        out("type {s} parent {s} abstract {d}", .{ str(c.g_type_name(t)), str(c.g_type_name(c.g_type_parent(t))), @intFromBool(c.g_type_test_flags(t, c.G_TYPE_FLAG_ABSTRACT) != 0) });
        const k: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
        var n: c.guint = 0;
        const ps = c.g_object_class_list_properties(k, &n);
        for (0..n) |i| {
            const p = ps[i];
            var dv = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&dv, p.*.value_type);
            c.g_param_value_set_default(p, &dv);
            const s = c.g_strdup_value_contents(&dv);
            out("  prop {s} {s} flags {x} nick {s} blurb {s} default {s}", .{ str(p.*.name), str(c.g_type_name(p.*.value_type)), p.*.flags, str(c.g_param_spec_get_nick(p)), str(c.g_param_spec_get_blurb(p)), str(s) });
            c.g_free(s);
            c.g_value_unset(&dv);
        }
        c.g_free(@ptrCast(ps));
        var ns: c.guint = 0;
        const ids = c.g_signal_list_ids(t, &ns);
        for (0..ns) |i| {
            var q: c.GSignalQuery = undefined;
            c.g_signal_query(ids[i], &q);
            out("  signal {s} flags {x} params {d}", .{ str(q.signal_name), q.signal_flags, q.n_params });
        }
        c.g_free(@ptrCast(ids));
    }
    sources();
    bindings(false);
    bindings(true);
    argb();
    proxy();
    out("done", .{});
}
