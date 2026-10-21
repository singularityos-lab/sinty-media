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

const SEC: c.GstClockTime = 1_000_000_000;
const NONE: c.GstClockTime = std.math.maxInt(u64);

const Target = extern struct {
    parent: c.GstObject,
    volume: f64,
    count: c.gint,
    flag: c.gboolean,
    fixed: f64,
    ctor: f64,
    big: u64,
    level: c.gfloat,
    label: [*c]u8,
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
        1 => t.volume = c.g_value_get_double(v),
        2 => t.count = c.g_value_get_int(v),
        3 => t.flag = c.g_value_get_boolean(v),
        4 => t.fixed = c.g_value_get_double(v),
        5 => t.ctor = c.g_value_get_double(v),
        6 => t.big = c.g_value_get_uint64(v),
        7 => t.level = c.g_value_get_float(v),
        8 => {
            c.g_free(t.label);
            t.label = c.g_value_dup_string(v);
        },
        else => {},
    }
}

fn targetGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const t = tof(o);
    switch (id) {
        1 => c.g_value_set_double(v, t.volume),
        2 => c.g_value_set_int(v, t.count),
        3 => c.g_value_set_boolean(v, t.flag),
        4 => c.g_value_set_double(v, t.fixed),
        5 => c.g_value_set_double(v, t.ctor),
        6 => c.g_value_set_uint64(v, t.big),
        7 => c.g_value_set_float(v, t.level),
        8 => c.g_value_set_string(v, t.label),
        else => {},
    }
}

fn targetClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = targetSet;
    gc.get_property = targetGet;
    const rw = c.G_PARAM_READWRITE | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_double("volume", "v", "v", 0, 10, 1, rw));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_int("count", "c", "c", -100, 100, 0, rw));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_boolean("flag", "f", "f", 0, rw));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_double("fixed", "x", "x", 0, 10, 0, c.G_PARAM_READWRITE));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_double("ctor", "k", "k", 0, 10, 0, rw | c.G_PARAM_CONSTRUCT_ONLY));
    c.g_object_class_install_property(gc, 6, c.g_param_spec_uint64("big", "b", "b", 0, 1000, 0, rw));
    c.g_object_class_install_property(gc, 7, c.g_param_spec_float("level", "l", "l", 0, 10, 0, rw));
    c.g_object_class_install_property(gc, 8, c.g_param_spec_string("label", "s", "s", null, rw));
}

fn targetType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_object_get_type(), "CtlTarget", @sizeOf(TargetClass), targetClass, @sizeOf(Target), null, 0);
    return S.t;
}

fn linear(_: [*c]c.GstControlSource, ts: c.GstClockTime, v: [*c]f64) callconv(.c) c.gboolean {
    if (ts > 20 * SEC) return 0;
    v.* = @as(f64, @floatFromInt(ts)) / @as(f64, @floatFromInt(SEC));
    return 1;
}

fn linearArray(s: [*c]c.GstControlSource, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]f64) callconv(.c) c.gboolean {
    var i: c.guint = 0;
    while (i < n) : (i += 1) if (linear(s, ts + interval * i, &values[i]) == 0) return 0;
    return 1;
}

fn sourceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: [*c]c.GstControlSource = @ptrCast(@alignCast(instance));
    s[0].get_value = linear;
    s[0].get_value_array = linearArray;
}

fn sourceType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_control_source_get_type(), "CtlSource", @sizeOf(c.GstControlSourceClass), null, @sizeOf(c.GstControlSource), sourceInit, 0);
    return S.t;
}

fn bareSourceType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_control_source_get_type(), "CtlBareSource", @sizeOf(c.GstControlSourceClass), null, @sizeOf(c.GstControlSource), null, 0);
    return S.t;
}

const Bind = extern struct {
    parent: c.GstControlBinding,
    src: [*c]c.GstControlSource,
};

var src_global: [*c]c.GstControlSource = null;

fn bindInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const b: *Bind = @ptrCast(@alignCast(instance));
    b.src = src_global;
}

fn convert(b: [*c]c.GstControlBinding, d: f64, v: [*c]c.GValue) void {
    const t = c.g_type_fundamental(b[0].pspec[0].value_type);
    _ = c.g_value_init(v, b[0].pspec[0].value_type);
    switch (t >> c.G_TYPE_FUNDAMENTAL_SHIFT) {
        15 => c.g_value_set_double(v, d),
        6 => c.g_value_set_int(v, @intFromFloat(d)),
        5 => c.g_value_set_boolean(v, @intFromBool(d >= 1)),
        11 => c.g_value_set_uint64(v, @intFromFloat(d)),
        14 => c.g_value_set_float(v, @floatCast(d)),
        else => {},
    }
}

fn bindSync(b: [*c]c.GstControlBinding, o: [*c]c.GstObject, ts: c.GstClockTime, last: c.GstClockTime) callconv(.c) c.gboolean {
    const self: *Bind = @ptrCast(@alignCast(b));
    var d: f64 = 0;
    out("  sync {s} ts={d} last={d}", .{ str(b[0].name), ts / SEC, if (last == NONE) -1 else @as(i64, @intCast(last / SEC)) });
    if (c.gst_control_source_get_value(self.src, ts, &d) == 0) return 0;
    var v = std.mem.zeroes(c.GValue);
    convert(b, d, &v);
    c.g_object_set_property(@ptrCast(o), b[0].name, &v);
    c.g_value_unset(&v);
    return 1;
}

fn bindGet(b: [*c]c.GstControlBinding, ts: c.GstClockTime) callconv(.c) [*c]c.GValue {
    const self: *Bind = @ptrCast(@alignCast(b));
    var d: f64 = 0;
    if (c.gst_control_source_get_value(self.src, ts, &d) == 0) return null;
    const v: [*c]c.GValue = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
    convert(b, d, v);
    return v;
}

fn bindArray(b: [*c]c.GstControlBinding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: c.gpointer) callconv(.c) c.gboolean {
    const self: *Bind = @ptrCast(@alignCast(b));
    var i: c.guint = 0;
    const t = c.g_type_fundamental(b[0].pspec[0].value_type) >> c.G_TYPE_FUNDAMENTAL_SHIFT;
    while (i < n) : (i += 1) {
        var d: f64 = 0;
        if (c.gst_control_source_get_value(self.src, ts + interval * i, &d) == 0) return 0;
        switch (t) {
            15 => @as([*c]f64, @ptrCast(@alignCast(values)))[i] = d,
            6, 12 => @as([*c]c.gint, @ptrCast(@alignCast(values)))[i] = @intFromFloat(d),
            5 => @as([*c]c.gboolean, @ptrCast(@alignCast(values)))[i] = @intFromBool(d >= 1),
            11 => @as([*c]u64, @ptrCast(@alignCast(values)))[i] = @intFromFloat(d),
            14 => @as([*c]f32, @ptrCast(@alignCast(values)))[i] = @floatCast(d),
            else => {},
        }
    }
    return 1;
}

fn bindClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const bc: *c.GstControlBindingClass = @ptrCast(@alignCast(k));
    bc.sync_values = bindSync;
    bc.get_value = bindGet;
    bc.get_value_array = bindArray;
}

fn bindType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_control_binding_get_type(), "CtlBind", @sizeOf(c.GstControlBindingClass), bindClass, @sizeOf(Bind), bindInit, 0);
    return S.t;
}

fn bareBindType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_control_binding_get_type(), "CtlBareBind", @sizeOf(c.GstControlBindingClass), null, @sizeOf(c.GstControlBinding), null, 0);
    return S.t;
}

fn make(t: c.GType, o: ?*anyopaque, name: [*c]const u8) [*c]c.GstControlBinding {
    return @ptrCast(@alignCast(if (o) |p| c.g_object_new(t, "object", p, "name", name, @as(?*anyopaque, null)) else c.g_object_new(t, "name", name, @as(?*anyopaque, null))));
}

fn state(o: *Target) void {
    out("  state volume={d:.3} count={d} flag={d} big={d} level={d:.2}", .{ o.volume, o.count, o.flag, o.big, o.level });
}

fn notified(_: [*c]c.GObject, p: [*c]c.GParamSpec, _: c.gpointer) callconv(.c) void {
    out("  notify {s}", .{str(p[0].name)});
}

pub fn main() void {
    c.gst_init(null, null);
    out("types {s} {s} abstract {d} {d}", .{ str(c.g_type_name(c.gst_control_binding_get_type())), str(c.g_type_name(c.gst_control_source_get_type())), c.g_type_test_flags(c.gst_control_binding_get_type(), c.G_TYPE_FLAG_ABSTRACT), c.g_type_test_flags(c.gst_control_source_get_type(), c.G_TYPE_FLAG_ABSTRACT) });
    out("parents {s} {s}", .{ str(c.g_type_name(c.g_type_parent(c.gst_control_binding_get_type()))), str(c.g_type_name(c.g_type_parent(c.gst_control_source_get_type()))) });
    const bk: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(c.gst_control_binding_get_type())));
    var np: c.guint = 0;
    const props = c.g_object_class_list_properties(bk, &np);
    for (props[0..np]) |p| out("binding prop {s} flags={d} owner={s} type={s}", .{ str(p.*.name), p.*.flags, str(c.g_type_name(p.*.owner_type)), str(c.g_type_name(p.*.value_type)) });
    c.g_free(@ptrCast(props));

    const o: *Target = @ptrCast(@alignCast(c.g_object_new(targetType(), "name", "tgt", @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(o);
    _ = c.g_signal_connect_data(o, "notify", @ptrCast(&notified), null, null, 0);
    out("rate {d} next {d}", .{ c.gst_object_get_control_rate(@ptrCast(o)), c.gst_object_suggest_next_sync(@ptrCast(o)) });
    out("sync without bindings {d}", .{c.gst_object_sync_values(@ptrCast(o), 0)});
    out("active none {d}", .{c.gst_object_has_active_control_bindings(@ptrCast(o))});

    src_global = @ptrCast(@alignCast(c.g_object_new(sourceType(), @as([*c]const u8, null))));
    _ = c.gst_object_ref_sink(src_global);

    for ([_][*c]const u8{ "volume", "count", "flag", "fixed", "ctor", "nothere", "big", "level", "label" }) |name| {
        const b = make(bindType(), o, name);
        var bo: ?*anyopaque = null;
        var bn: [*c]u8 = null;
        c.g_object_get(b, "object", &bo, "name", &bn, @as(?*anyopaque, null));
        out("bind {s}: pspec {d} name={s} object={d} floating={d} disabled={d}", .{ str(name), @intFromBool(b[0].pspec != null), str(bn), @intFromBool(bo == @as(?*anyopaque, o)), c.g_object_is_floating(b), c.gst_control_binding_is_disabled(b) });
        c.g_free(bn);
        if (bo) |p| c.g_object_unref(p);
        if (b[0].pspec != null) {
            out("  add {d} parent={d}", .{ c.gst_object_add_control_binding(@ptrCast(o), b), @intFromBool(b[0].parent.parent == @as([*c]c.GstObject, @ptrCast(o))) });
        } else {
            out("  add refused {d}", .{c.gst_object_add_control_binding(@ptrCast(o), b)});
            _ = c.gst_object_ref_sink(b);
            c.gst_object_unref(b);
        }
    }
    var l = o.parent.control_bindings;
    while (l != null) : (l = l.*.next) out("order {s}", .{str(@as([*c]c.GstControlBinding, @ptrCast(@alignCast(l.*.data)))[0].name)});
    out("active {d}", .{c.gst_object_has_active_control_bindings(@ptrCast(o))});

    for ([_]c.GstClockTime{ 0, 2 * SEC, 5 * SEC, 25 * SEC }) |ts| {
        out("sync at {d} -> {d}", .{ ts / SEC, c.gst_object_sync_values(@ptrCast(o), ts) });
        state(o);
        out("  last {d} next {d}", .{ o.parent.last_sync / SEC, c.gst_object_suggest_next_sync(@ptrCast(o)) });
    }

    for ([_][*c]const u8{ "volume", "count", "flag", "big", "level", "missing" }) |name| {
        const v = c.gst_object_get_value(@ptrCast(o), name, 3 * SEC);
        if (v == null) {
            out("value {s} null", .{str(name)});
            continue;
        }
        const s = c.g_strdup_value_contents(v);
        out("value {s} {s} {s}", .{ str(name), str(c.g_type_name(v[0].g_type)), str(s) });
        c.g_free(s);
        c.g_value_unset(v);
        c.g_free(v);
    }
    var doubles: [4]f64 = undefined;
    out("array volume {d} {d:.1} {d:.1} {d:.1} {d:.1}", .{ c.gst_object_get_value_array(@ptrCast(o), "volume", SEC, SEC / 2, 4, &doubles), doubles[0], doubles[1], doubles[2], doubles[3] });
    var ints: [3]c.gint = undefined;
    out("array count {d} {d} {d} {d}", .{ c.gst_object_get_value_array(@ptrCast(o), "count", 4 * SEC, SEC, 3, &ints), ints[0], ints[1], ints[2] });
    out("array beyond {d}", .{c.gst_object_get_value_array(@ptrCast(o), "volume", 19 * SEC, SEC, 4, &doubles)});
    out("array missing {d}", .{c.gst_object_get_value_array(@ptrCast(o), "nope", 0, SEC, 4, &doubles)});

    for ([_][*c]const u8{ "volume", "count", "flag", "big", "level" }) |name| {
        var vals = std.mem.zeroes([3]c.GValue);
        const r = c.gst_object_get_g_value_array(@ptrCast(o), name, 2 * SEC, SEC, 3, &vals);
        out("gvalues {s} {d}", .{ str(name), r });
        if (r == 0) continue;
        for (&vals) |*v| {
            const s = c.g_strdup_value_contents(v);
            out("  {s} {s}", .{ str(c.g_type_name(v.g_type)), str(s) });
            c.g_free(s);
            c.g_value_unset(v);
        }
    }

    const got = c.gst_object_get_control_binding(@ptrCast(o), "count");
    out("get count {d} ref={d}", .{ @intFromBool(got != null), got[0].parent.object.ref_count });
    c.gst_object_set_control_binding_disabled(@ptrCast(o), "count", 1);
    out("count disabled {d} active {d}", .{ c.gst_control_binding_is_disabled(got), c.gst_object_has_active_control_bindings(@ptrCast(o)) });
    out("sync disabled direct {d}", .{c.gst_control_binding_sync_values(got, @ptrCast(o), 6 * SEC, 0)});
    out("sync at 6 -> {d}", .{c.gst_object_sync_values(@ptrCast(o), 6 * SEC)});
    state(o);
    c.gst_object_set_control_bindings_disabled(@ptrCast(o), 1);
    out("all disabled active {d}", .{c.gst_object_has_active_control_bindings(@ptrCast(o))});
    out("sync at 7 -> {d}", .{c.gst_object_sync_values(@ptrCast(o), 7 * SEC)});
    state(o);
    c.gst_object_set_control_bindings_disabled(@ptrCast(o), 0);
    c.gst_object_set_control_binding_disabled(@ptrCast(o), "nothere", 1);
    out("re-enabled active {d}", .{c.gst_object_has_active_control_bindings(@ptrCast(o))});

    out("remove count {d}", .{c.gst_object_remove_control_binding(@ptrCast(o), got)});
    out("remove again {d}", .{c.gst_object_remove_control_binding(@ptrCast(o), got)});
    out("after remove parent={d} ref={d}", .{ @intFromBool(got[0].parent.parent == null), got[0].parent.object.ref_count });
    c.gst_object_unref(got);
    out("get count after {d}", .{@intFromBool(c.gst_object_get_control_binding(@ptrCast(o), "count") == null)});

    const repl = make(bindType(), o, "volume");
    const prev = c.gst_object_get_control_binding(@ptrCast(o), "volume");
    out("replace volume {d}", .{c.gst_object_add_control_binding(@ptrCast(o), repl)});
    out("  old parent null {d} new same {d}", .{ @intFromBool(prev[0].parent.parent == null), @intFromBool(c.gst_object_get_control_binding(@ptrCast(o), "volume") == repl) });
    c.gst_object_unref(repl);
    c.gst_object_unref(prev);
    l = o.parent.control_bindings;
    while (l != null) : (l = l.*.next) out("order {s}", .{str(@as([*c]c.GstControlBinding, @ptrCast(@alignCast(l.*.data)))[0].name)});

    const bare = make(bareBindType(), o, "count");
    _ = c.gst_object_ref_sink(bare);
    out("bare sync {d}", .{c.gst_control_binding_sync_values(bare, @ptrCast(o), 0, NONE)});
    out("bare value null {d}", .{@intFromBool(c.gst_control_binding_get_value(bare, 0) == null)});
    out("bare array {d}", .{c.gst_control_binding_get_value_array(bare, 0, SEC, 2, &ints)});
    var gv = std.mem.zeroes([2]c.GValue);
    out("bare gvalues {d}", .{c.gst_control_binding_get_g_value_array(bare, 0, SEC, 2, &gv)});
    c.gst_object_unref(bare);
    const bare_label = make(bareBindType(), o, "label");
    _ = c.gst_object_ref_sink(bare_label);
    out("label pspec {d}", .{@intFromBool(bare_label[0].pspec != null)});
    if (bare_label[0].pspec != null) {
        out("label gvalues {d} pspec after {d}", .{ c.gst_control_binding_get_g_value_array(bare_label, 0, SEC, 2, &gv), @intFromBool(bare_label[0].pspec != null) });
    }
    c.gst_object_unref(bare_label);

    const orphan = make(bindType(), null, "volume");
    _ = c.gst_object_ref_sink(orphan);
    out("orphan pspec {d}", .{@intFromBool(orphan[0].pspec != null)});
    c.gst_object_unref(orphan);

    const bs: [*c]c.GstControlSource = @ptrCast(@alignCast(c.g_object_new(bareSourceType(), @as([*c]const u8, null))));
    _ = c.gst_object_ref_sink(bs);
    var d: f64 = 0;
    out("bare source {d} {d}", .{ c.gst_control_source_get_value(bs, 0, &d), c.gst_control_source_get_value_array(bs, 0, SEC, 1, &d) });
    out("source {d} {d:.1}", .{ c.gst_control_source_get_value(src_global, 3 * SEC, &d), d });
    c.gst_object_unref(bs);

    out("crit source {d}", .{c.gst_control_source_get_value(src_global, NONE, &d)});
    out("crit source array {d}", .{c.gst_control_source_get_value_array(src_global, 0, NONE, 1, &d)});
    out("crit not source {d}", .{c.gst_control_source_get_value(@ptrCast(o), 0, &d)});
    out("crit sync {d}", .{c.gst_object_sync_values(@ptrCast(o), NONE)});
    out("crit get {d}", .{@intFromBool(c.gst_object_get_value(@ptrCast(o), null, 0) == null)});
    out("crit get ts {d}", .{@intFromBool(c.gst_object_get_value(@ptrCast(o), "volume", NONE) == null)});
    out("crit array {d}", .{c.gst_object_get_value_array(@ptrCast(o), "volume", 0, SEC, 1, null)});
    out("crit garray {d}", .{c.gst_object_get_g_value_array(@ptrCast(o), "volume", 0, NONE, 1, &gv)});
    out("crit add {d}", .{c.gst_object_add_control_binding(@ptrCast(o), @ptrCast(src_global))});
    out("crit remove {d}", .{c.gst_object_remove_control_binding(null, null)});
    out("crit binding {d}", .{c.gst_control_binding_is_disabled(null)});
    c.gst_control_binding_set_disabled(null, 1);
    c.gst_object_set_control_binding_disabled(@ptrCast(o), null, 1);
    out("crit getb {d}", .{@intFromBool(c.gst_object_get_control_binding(@ptrCast(o), null) == null)});
    out("crit rate {d}", .{c.gst_object_get_control_rate(null)});
    c.gst_object_set_control_rate(@ptrCast(o), 40 * 1_000_000);
    out("rate {d} next {d}", .{ c.gst_object_get_control_rate(@ptrCast(o)), c.gst_object_suggest_next_sync(@ptrCast(o)) });
    c.gst_object_set_control_rate(@ptrCast(o), NONE);
    out("crit next {d}", .{c.gst_object_suggest_next_sync(@ptrCast(o))});

    const name_before = c.gst_object_get_name(@ptrCast(c.gst_object_get_control_binding(@ptrCast(o), "flag")));
    out("binding object name {s}", .{str(name_before)});
    c.g_free(name_before);
    c.gst_object_unref(o);
    c.gst_object_unref(src_global);
    out("done", .{});
}
