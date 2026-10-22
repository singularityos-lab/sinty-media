const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const check = @import("check.zig");
const libm = @import("../libm.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Binding = c.GstControlBinding;
const Direct = c.GstDirectControlBinding;
const Argb = c.GstARGBControlBinding;
const Proxy = c.GstProxyControlBinding;
const Source = c.GstControlSource;
const NONE: u64 = std.math.maxInt(u64);

var direct_once: gtype.Once = .{};
var argb_once: gtype.Once = .{};
var proxy_once: gtype.Once = .{};
var direct_parent: ?*c.GObjectClass = null;
var argb_parent: ?*c.GObjectClass = null;
var proxy_parent: ?*c.GObjectClass = null;

fn isDirect(p: anytype) bool {
    return gtype.instanceOf(p, gst_direct_control_binding_get_type());
}

fn isArgb(p: anytype) bool {
    return gtype.instanceOf(p, gst_argb_control_binding_get_type());
}

fn bind(p: anytype) *Binding {
    return @ptrCast(@alignCast(p));
}

fn clamp01(s: f64) f64 {
    return std.math.clamp(s, 0.0, 1.0);
}

fn Conv(comptime T: type, comptime Spec: type, comptime set: anytype) type {
    return struct {
        fn cast(x: f64) T {
            const info = @typeInfo(T);
            if (info == .float) return @floatCast(x);
            if (info.int.bits == 32) {
                if (info.int.signedness == .signed) return @bitCast(check.toI32(x));
                return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(check.toI64(x))))));
            }
            if (info.int.signedness == .signed) return @bitCast(check.toI64(x));
            return @bitCast(check.toU64(x));
        }

        fn round(x: f64) f64 {
            return if (T == f32 or T == f64) x else libm.rint(x);
        }

        fn scaled(self: *Direct, s0: f64) T {
            const ps: *Spec = @ptrCast(@alignCast(bind(self).pspec));
            const s = clamp01(s0);
            const lo = cast(round(toF(ps.minimum) * (1 - s)));
            const hi = cast(round(toF(ps.maximum) * s));
            return if (T == f32 or T == f64) lo + hi else lo +% hi;
        }

        fn gvalue(self: [*c]Direct, s: f64, d: [*c]c.GValue) callconv(.c) void {
            set(d, scaled(self, s));
        }

        fn value(self: [*c]Direct, s: f64, d: c.gpointer) callconv(.c) void {
            const p: *align(1) T = @ptrCast(d);
            p.* = scaled(self, s);
        }

        fn absGvalue(_: [*c]Direct, s: f64, d: [*c]c.GValue) callconv(.c) void {
            set(d, cast(round(s)));
        }

        fn absValue(_: [*c]Direct, s: f64, d: c.gpointer) callconv(.c) void {
            const p: *align(1) T = @ptrCast(d);
            p.* = cast(round(s));
        }
    };
}

fn toF(x: anytype) f64 {
    return switch (@typeInfo(@TypeOf(x))) {
        .float => @floatCast(x),
        else => @floatFromInt(x),
    };
}

fn boolG(_: [*c]Direct, s: f64, d: [*c]c.GValue) callconv(.c) void {
    c.g_value_set_boolean(d, check.toI32(clamp01(s) + 0.5));
}

fn boolV(_: [*c]Direct, s: f64, d: c.gpointer) callconv(.c) void {
    const p: *align(1) c.gboolean = @ptrCast(d);
    p.* = check.toI32(clamp01(s) + 0.5);
}

fn enumIndex(self: [*c]Direct, s: f64) c.gint {
    const ps: *c.GParamSpecEnum = @ptrCast(@alignCast(bind(self).pspec));
    const e = ps.enum_class;
    const i = check.toI32(clamp01(s) * toF(e.*.n_values - 1));
    return e.*.values[@intCast(i)].value;
}

fn enumG(self: [*c]Direct, s: f64, d: [*c]c.GValue) callconv(.c) void {
    c.g_value_set_enum(d, enumIndex(self, s));
}

fn enumV(self: [*c]Direct, s: f64, d: c.gpointer) callconv(.c) void {
    const p: *align(1) c.gint = @ptrCast(d);
    p.* = enumIndex(self, s);
}

fn install(self: *Direct, comptime C: type, size: c.gint) void {
    if (self.ABI.abi.want_absolute != 0) {
        self.convert_g_value = C.absGvalue;
        self.convert_value = C.absValue;
    } else {
        self.convert_g_value = C.gvalue;
        self.convert_value = C.value;
    }
    self.byte_size = size;
}

fn directConstructor(t: c.GType, n: c.guint, params: [*c]c.GObjectConstructParam) callconv(.c) [*c]c.GObject {
    const o = direct_parent.?.constructor.?(t, n, params);
    const self: *Direct = @ptrCast(@alignCast(o));
    const b = bind(self);
    if (b.pspec != null) {
        var ty = b.pspec.*.value_type;
        var base = ty;
        _ = c.g_value_init(&self.cur_value, ty);
        while (true) {
            ty = c.g_type_parent(ty);
            if (ty == 0) break;
            base = ty;
        }
        switch (base) {
            c.G_TYPE_INT => install(self, Conv(c.gint, c.GParamSpecInt, c.g_value_set_int), 4),
            c.G_TYPE_UINT => install(self, Conv(c.guint, c.GParamSpecUInt, c.g_value_set_uint), 4),
            c.G_TYPE_LONG => install(self, Conv(c.glong, c.GParamSpecLong, c.g_value_set_long), 8),
            c.G_TYPE_ULONG => install(self, Conv(c.gulong, c.GParamSpecULong, c.g_value_set_ulong), 8),
            c.G_TYPE_INT64 => install(self, Conv(c.gint64, c.GParamSpecInt64, c.g_value_set_int64), 8),
            c.G_TYPE_UINT64 => install(self, Conv(c.guint64, c.GParamSpecUInt64, c.g_value_set_uint64), 8),
            c.G_TYPE_FLOAT => install(self, Conv(f32, c.GParamSpecFloat, c.g_value_set_float), 4),
            c.G_TYPE_DOUBLE => install(self, Conv(f64, c.GParamSpecDouble, c.g_value_set_double), 8),
            c.G_TYPE_BOOLEAN => {
                self.convert_g_value = boolG;
                self.convert_value = boolV;
                self.byte_size = @sizeOf(c.gboolean);
            },
            c.G_TYPE_ENUM => {
                self.convert_g_value = enumG;
                self.convert_value = enumV;
                self.byte_size = @sizeOf(c.gint);
            },
            else => b.pspec = null,
        }
    }
    return o;
}

const DIRECT_FILE = "../libs/gst/controller/gstdirectcontrolbinding.c";

fn directSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const self: *Direct = @ptrCast(@alignCast(o));
    switch (id) {
        1 => {
            if (self.cs != null) c.gst_object_unref(self.cs);
            self.cs = @ptrCast(@alignCast(c.g_value_dup_object(v)));
        },
        2 => self.ABI.abi.want_absolute = c.g_value_get_boolean(v),
        else => check.warnInvalid(o, id, spec, DIRECT_FILE, 316),
    }
}

fn directGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const self: *Direct = @ptrCast(@alignCast(o));
    switch (id) {
        1 => c.g_value_set_object(v, self.cs),
        2 => c.g_value_set_boolean(v, self.ABI.abi.want_absolute),
        else => check.warnInvalid(o, id, spec, DIRECT_FILE, 335),
    }
}

fn directDispose(o: [*c]c.GObject) callconv(.c) void {
    const self: *Direct = @ptrCast(@alignCast(o));
    if (self.cs != null) _ = c.gst_object_replace(@ptrCast(&self.cs), null);
    direct_parent.?.dispose.?(o);
}

fn directFinalize(o: [*c]c.GObject) callconv(.c) void {
    const self: *Direct = @ptrCast(@alignCast(o));
    if (self.cur_value.g_type != 0) c.g_value_unset(&self.cur_value);
    direct_parent.?.finalize.?(o);
}

fn directSync(b: [*c]Binding, object: [*c]c.GstObject, ts: c.GstClockTime, last: c.GstClockTime) callconv(.c) c.gboolean {
    const self: *Direct = @ptrCast(@alignCast(b));
    if (!check.that(isDirect(b), "gst_direct_control_binding_sync_values", "GST_IS_DIRECT_CONTROL_BINDING (self)")) return 0;
    if (!check.that(b.*.pspec != null, "gst_direct_control_binding_sync_values", "GST_CONTROL_BINDING_PSPEC (self)")) return 0;
    var v: f64 = 0;
    const ret = c.gst_control_source_get_value(self.cs, ts, &v);
    if (ret != 0 and (ts < last or v != self.last_value)) {
        self.convert_g_value.?(self, v, &self.cur_value);
        c.g_object_set_property(@ptrCast(object), b.*.name, &self.cur_value);
        self.last_value = v;
    }
    return ret;
}

fn directValue(b: [*c]Binding, ts: c.GstClockTime) callconv(.c) [*c]c.GValue {
    const self: *Direct = @ptrCast(@alignCast(b));
    if (!check.that(isDirect(b), "gst_direct_control_binding_get_value", "GST_IS_DIRECT_CONTROL_BINDING (self)")) return null;
    if (!check.that(ts != NONE, "gst_direct_control_binding_get_value", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return null;
    if (!check.that(b.*.pspec != null, "gst_direct_control_binding_get_value", "GST_CONTROL_BINDING_PSPEC (self)")) return null;
    var v: f64 = 0;
    if (c.gst_control_source_get_value(self.cs, ts, &v) == 0) return null;
    const d: [*c]c.GValue = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
    _ = c.g_value_init(d, b.*.pspec.*.value_type);
    self.convert_g_value.?(self, v, d);
    return d;
}

fn directArray(b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, out: c.gpointer) callconv(.c) c.gboolean {
    const self: *Direct = @ptrCast(@alignCast(b));
    const F = "gst_direct_control_binding_get_value_array";
    if (!check.that(isDirect(b), F, "GST_IS_DIRECT_CONTROL_BINDING (self)")) return 0;
    if (!check.that(ts != NONE, F, "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(interval != NONE, F, "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (!check.that(out != null, F, "values")) return 0;
    if (!check.that(b.*.pspec != null, F, "GST_CONTROL_BINDING_PSPEC (self)")) return 0;
    const conv = self.convert_value.?;
    const size: usize = @intCast(self.byte_size);
    const src: [*]f64 = @ptrCast(@alignCast(c.g_malloc0_n(n, @sizeOf(f64))));
    defer c.g_free(src);
    const res = c.gst_control_source_get_value_array(self.cs, ts, interval, n, src);
    if (res != 0) {
        var p: [*]u8 = @ptrCast(out);
        for (0..n) |i| {
            if (!std.math.isNan(src[i])) conv(self, src[i], p);
            p += size;
        }
    }
    return res;
}

fn directGArray(b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.GValue) callconv(.c) c.gboolean {
    const self: *Direct = @ptrCast(@alignCast(b));
    const F = "gst_direct_control_binding_get_g_value_array";
    if (!check.that(isDirect(b), F, "GST_IS_DIRECT_CONTROL_BINDING (self)")) return 0;
    if (!check.that(ts != NONE, F, "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(interval != NONE, F, "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (!check.that(values != null, F, "values")) return 0;
    if (!check.that(b.*.pspec != null, F, "GST_CONTROL_BINDING_PSPEC (self)")) return 0;
    const conv = self.convert_g_value.?;
    const ty = b.*.pspec.*.value_type;
    const src: [*]f64 = @ptrCast(@alignCast(c.g_malloc0_n(n, @sizeOf(f64))));
    defer c.g_free(src);
    const res = c.gst_control_source_get_value_array(self.cs, ts, interval, n, src);
    if (res != 0) {
        for (0..n) |i| {
            if (!std.math.isNan(src[i])) {
                _ = c.g_value_init(&values[i], ty);
                conv(self, src[i], &values[i]);
            }
        }
    }
    return res;
}

fn directInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const self: *Direct = @ptrCast(@alignCast(inst));
    self.last_value = std.math.floatMax(f64);
}

fn directClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    direct_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.constructor = directConstructor;
    gc.set_property = directSet;
    gc.get_property = directGet;
    gc.dispose = directDispose;
    gc.finalize = directFinalize;
    const bc: *c.GstControlBindingClass = @ptrCast(@alignCast(k));
    bc.sync_values = directSync;
    bc.get_value = directValue;
    bc.get_value_array = directArray;
    bc.get_g_value_array = directGArray;
    var props = [_][*c]c.GParamSpec{
        null,
        c.g_param_spec_object("control-source", "ControlSource", "The control source", c.gst_control_source_get_type(), c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS),
        c.g_param_spec_boolean("absolute", "Absolute", "Whether the control values are absolute", 0, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS),
    };
    c.g_object_class_install_properties(gc, props.len, &props);
}

pub export fn gst_direct_control_binding_get_type() c.GType {
    return direct_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_control_binding_get_type, "GstDirectControlBinding", c.GstDirectControlBindingClass, Direct, directClassInit, directInit, 0);
            _ = c._gst_debug_category_new("gstdirectcontrolbinding", 0, "dynamic parameter control source attachment");
            return t;
        }
    }.f);
}

pub export fn gst_direct_control_binding_new(object: [*c]c.GstObject, name: [*c]const u8, cs: [*c]Source) [*c]Binding {
    return @ptrCast(@alignCast(c.g_object_new(gst_direct_control_binding_get_type(), "object", object, "name", name, "control-source", cs, @as(?*anyopaque, null))));
}

pub export fn gst_direct_control_binding_new_absolute(object: [*c]c.GstObject, name: [*c]const u8, cs: [*c]Source) [*c]Binding {
    return @ptrCast(@alignCast(c.g_object_new(gst_direct_control_binding_get_type(), "object", object, "name", name, "control-source", cs, "absolute", @as(c.gboolean, 1), @as(?*anyopaque, null))));
}

fn channel(x: f64) u32 {
    return @intFromFloat(@trunc(clamp01(x) * 255));
}

fn pack(a: f64, r: f64, g: f64, b: f64) u32 {
    return (channel(a) << 24) | (channel(r) << 16) | (channel(g) << 8) | channel(b);
}

fn argbConstructor(t: c.GType, n: c.guint, params: [*c]c.GObjectConstructParam) callconv(.c) [*c]c.GObject {
    const o = argb_parent.?.constructor.?(t, n, params);
    const self: *Argb = @ptrCast(@alignCast(o));
    const b = bind(self);
    if (b.pspec != null) {
        if (b.pspec.*.value_type != c.G_TYPE_UINT) {
            b.pspec = null;
        } else _ = c.g_value_init(&self.cur_value, c.G_TYPE_UINT);
    }
    return o;
}

const ARGB_FILE = "../libs/gst/controller/gstargbcontrolbinding.c";

fn argbSlot(self: *Argb, id: c.guint) ?*[*c]Source {
    return switch (id) {
        1 => &self.cs_a,
        2 => &self.cs_r,
        3 => &self.cs_g,
        4 => &self.cs_b,
        else => null,
    };
}

fn argbSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const self: *Argb = @ptrCast(@alignCast(o));
    const slot = argbSlot(self, id) orelse return check.warnInvalid(o, id, spec, ARGB_FILE, 187);
    _ = c.gst_object_replace(@ptrCast(slot), @ptrCast(@alignCast(c.g_value_get_object(v))));
}

fn argbGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const self: *Argb = @ptrCast(@alignCast(o));
    const slot = argbSlot(self, id) orelse return check.warnInvalid(o, id, spec, ARGB_FILE, 212);
    c.g_value_set_object(v, slot.*);
}

fn argbDispose(o: [*c]c.GObject) callconv(.c) void {
    const self: *Argb = @ptrCast(@alignCast(o));
    for (1..5) |i| _ = c.gst_object_replace(@ptrCast(argbSlot(self, @intCast(i)).?), null);
    argb_parent.?.dispose.?(o);
}

fn argbFinalize(o: [*c]c.GObject) callconv(.c) void {
    const self: *Argb = @ptrCast(@alignCast(o));
    c.g_value_unset(&self.cur_value);
    argb_parent.?.finalize.?(o);
}

fn argbValues(self: *Argb, ts: u64, out: *[4]f64) c.gboolean {
    out.* = .{ 1.0, 0.0, 0.0, 0.0 };
    var ret: c.gboolean = 1;
    for (0..4) |i| {
        const cs = argbSlot(self, @intCast(i + 1)).?.*;
        if (cs != null) ret &= c.gst_control_source_get_value(cs, ts, &out[i]);
    }
    return ret;
}

fn argbSync(b: [*c]Binding, object: [*c]c.GstObject, ts: c.GstClockTime, last: c.GstClockTime) callconv(.c) c.gboolean {
    const self: *Argb = @ptrCast(@alignCast(b));
    if (!check.that(isArgb(b), "gst_argb_control_binding_sync_values", "GST_IS_ARGB_CONTROL_BINDING (self)")) return 0;
    if (!check.that(b.*.pspec != null, "gst_argb_control_binding_sync_values", "GST_CONTROL_BINDING_PSPEC (self)")) return 0;
    var v: [4]f64 = undefined;
    const ret = argbValues(self, ts, &v);
    if (ret != 0) {
        const val = pack(v[0], v[1], v[2], v[3]);
        if (ts < last or val != self.last_value) {
            c.g_value_set_uint(&self.cur_value, val);
            c.g_object_set_property(@ptrCast(object), b.*.name, &self.cur_value);
            self.last_value = val;
        }
    }
    return ret;
}

fn argbValue(b: [*c]Binding, ts: c.GstClockTime) callconv(.c) [*c]c.GValue {
    const self: *Argb = @ptrCast(@alignCast(b));
    if (!check.that(isArgb(b), "gst_argb_control_binding_get_value", "GST_IS_ARGB_CONTROL_BINDING (self)")) return null;
    if (!check.that(ts != NONE, "gst_argb_control_binding_get_value", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return null;
    if (!check.that(b.*.pspec != null, "gst_argb_control_binding_get_value", "GST_CONTROL_BINDING_PSPEC (self)")) return null;
    var v: [4]f64 = undefined;
    if (argbValues(self, ts, &v) == 0) return null;
    const d: [*c]c.GValue = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
    _ = c.g_value_init(d, c.G_TYPE_UINT);
    c.g_value_set_uint(d, pack(v[0], v[1], v[2], v[3]));
    return d;
}

fn argbFill(self: *Argb, ts: u64, interval: u64, n: c.guint, bufs: *[4]?[*]f64) c.gboolean {
    var ret: c.gboolean = 1;
    for (0..4) |i| {
        bufs[i] = null;
        const cs = argbSlot(self, @intCast(i + 1)).?.*;
        if (cs != null) {
            bufs[i] = @ptrCast(@alignCast(c.g_malloc0_n(n, @sizeOf(f64))));
            ret &= c.gst_control_source_get_value_array(cs, ts, interval, n, bufs[i].?);
        }
    }
    return ret;
}

fn argbAt(bufs: *[4]?[*]f64, i: usize) u32 {
    var v = [4]f64{ 1.0, 0.0, 0.0, 0.0 };
    for (0..4) |k| {
        if (bufs[k]) |p| {
            if (!std.math.isNan(p[i])) v[k] = p[i];
        }
    }
    return pack(v[0], v[1], v[2], v[3]);
}

fn argbArray(b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, out: c.gpointer) callconv(.c) c.gboolean {
    const self: *Argb = @ptrCast(@alignCast(b));
    const F = "gst_argb_control_binding_get_value_array";
    if (!check.that(isArgb(b), F, "GST_IS_ARGB_CONTROL_BINDING (self)")) return 0;
    if (!check.that(ts != NONE, F, "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(interval != NONE, F, "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (!check.that(out != null, F, "values")) return 0;
    if (!check.that(b.*.pspec != null, F, "GST_CONTROL_BINDING_PSPEC (self)")) return 0;
    var bufs: [4]?[*]f64 = undefined;
    const ret = argbFill(self, ts, interval, n, &bufs);
    defer for (bufs) |p| c.g_free(p);
    if (ret != 0) {
        const vals: [*]align(1) u32 = @ptrCast(out);
        for (0..n) |i| vals[i] = argbAt(&bufs, i);
    }
    return ret;
}

fn argbGArray(b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.GValue) callconv(.c) c.gboolean {
    const self: *Argb = @ptrCast(@alignCast(b));
    const F = "gst_argb_control_binding_get_g_value_array";
    if (!check.that(isArgb(b), F, "GST_IS_ARGB_CONTROL_BINDING (self)")) return 0;
    if (!check.that(ts != NONE, F, "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(interval != NONE, F, "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (!check.that(values != null, F, "values")) return 0;
    if (!check.that(b.*.pspec != null, F, "GST_CONTROL_BINDING_PSPEC (self)")) return 0;
    var bufs: [4]?[*]f64 = undefined;
    const ret = argbFill(self, ts, interval, n, &bufs);
    defer for (bufs) |p| c.g_free(p);
    if (ret != 0) {
        for (0..n) |i| {
            _ = c.g_value_init(&values[i], c.G_TYPE_UINT);
            c.g_value_set_uint(&values[i], argbAt(&bufs, i));
        }
    }
    return ret;
}

fn argbInit(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

fn argbClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    argb_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.constructor = argbConstructor;
    gc.set_property = argbSet;
    gc.get_property = argbGet;
    gc.dispose = argbDispose;
    gc.finalize = argbFinalize;
    const bc: *c.GstControlBindingClass = @ptrCast(@alignCast(k));
    bc.sync_values = argbSync;
    bc.get_value = argbValue;
    bc.get_value_array = argbArray;
    bc.get_g_value_array = argbGArray;
    const f = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS;
    const t = c.gst_control_source_get_type();
    var props = [_][*c]c.GParamSpec{
        null,
        c.g_param_spec_object("control-source-a", "ControlSource A", "The control source for the alpha color component", t, f),
        c.g_param_spec_object("control-source-r", "ControlSource R", "The control source for the red color component", t, f),
        c.g_param_spec_object("control-source-g", "ControlSource G", "The control source for the green color component", t, f),
        c.g_param_spec_object("control-source-b", "ControlSource B", "The control source for the blue color component", t, f),
    };
    c.g_object_class_install_properties(gc, props.len, &props);
}

pub export fn gst_argb_control_binding_get_type() c.GType {
    return argb_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_control_binding_get_type, "GstARGBControlBinding", c.GstARGBControlBindingClass, Argb, argbClassInit, argbInit, 0);
            _ = c._gst_debug_category_new("gstargbcontrolbinding", 0, "dynamic parameter control source attachment");
            return t;
        }
    }.f);
}

pub export fn gst_argb_control_binding_new(object: [*c]c.GstObject, name: [*c]const u8, a: [*c]Source, r: [*c]Source, g: [*c]Source, b: [*c]Source) [*c]Binding {
    return @ptrCast(@alignCast(c.g_object_new(gst_argb_control_binding_get_type(), "object", object, "name", name, "control-source-a", a, "control-source-r", r, "control-source-g", g, "control-source-b", b, @as(?*anyopaque, null))));
}

fn target(self: *Proxy) ?struct { o: *c.GstObject, b: [*c]Binding } {
    const o: *c.GstObject = @ptrCast(@alignCast(c.g_weak_ref_get(&self.ref_object) orelse return null));
    const b = c.gst_object_get_control_binding(o, self.property_name);
    if (b == null) {
        c.gst_object_unref(o);
        return null;
    }
    return .{ .o = o, .b = b };
}

fn release(t: anytype) void {
    c.gst_object_unref(t.b);
    c.gst_object_unref(t.o);
}

fn proxySync(b: [*c]Binding, _: [*c]c.GstObject, ts: c.GstClockTime, last: c.GstClockTime) callconv(.c) c.gboolean {
    const t = target(@ptrCast(@alignCast(b))) orelse return 1;
    defer release(t);
    return c.gst_control_binding_sync_values(t.b, t.o, ts, last);
}

fn proxyValue(b: [*c]Binding, ts: c.GstClockTime) callconv(.c) [*c]c.GValue {
    const t = target(@ptrCast(@alignCast(b))) orelse return null;
    defer release(t);
    return c.gst_control_binding_get_value(t.b, ts);
}

fn proxyArray(b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: c.gpointer) callconv(.c) c.gboolean {
    const t = target(@ptrCast(@alignCast(b))) orelse return 0;
    defer release(t);
    return c.gst_control_binding_get_value_array(t.b, ts, interval, n, values);
}

fn proxyGArray(b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.GValue) callconv(.c) c.gboolean {
    const t = target(@ptrCast(@alignCast(b))) orelse return 0;
    defer release(t);
    return c.gst_control_binding_get_g_value_array(t.b, ts, interval, n, values);
}

fn proxyInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const self: *Proxy = @ptrCast(@alignCast(inst));
    c.g_weak_ref_init(&self.ref_object, null);
}

fn proxyFinalize(o: [*c]c.GObject) callconv(.c) void {
    const self: *Proxy = @ptrCast(@alignCast(o));
    c.g_weak_ref_clear(&self.ref_object);
    c.g_free(self.property_name);
    proxy_parent.?.finalize.?(o);
}

fn proxyClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    proxy_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const bc: *c.GstControlBindingClass = @ptrCast(@alignCast(k));
    bc.sync_values = proxySync;
    bc.get_value = proxyValue;
    bc.get_value_array = proxyArray;
    bc.get_g_value_array = proxyGArray;
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = proxyFinalize;
}

pub export fn gst_proxy_control_binding_get_type() c.GType {
    return proxy_once.get(struct {
        fn f() c.GType {
            return gtype.object(c.gst_control_binding_get_type, "GstProxyControlBinding", c.GstProxyControlBindingClass, Proxy, proxyClassInit, proxyInit, 0);
        }
    }.f);
}

pub export fn gst_proxy_control_binding_new(object: [*c]c.GstObject, name: [*c]const u8, ref: [*c]c.GstObject, ref_name: [*c]const u8) [*c]Binding {
    const F = "gst_proxy_control_binding_new";
    if (!check.that(gtype.instanceOf(object, c.gst_object_get_type()), F, "GST_IS_OBJECT (object)")) return null;
    if (!check.that(name != null, F, "property_name != NULL")) return null;
    if (!check.that(gtype.instanceOf(ref, c.gst_object_get_type()), F, "GST_IS_OBJECT (ref_object)")) return null;
    if (!check.that(ref_name != null, F, "ref_property_name != NULL")) return null;
    const cb: *Proxy = @ptrCast(@alignCast(c.g_object_new(gst_proxy_control_binding_get_type(), "object", object, "name", name, @as(?*anyopaque, null))));
    c.g_weak_ref_set(&cb.ref_object, ref);
    cb.property_name = c.g_strdup(ref_name);
    return @ptrCast(cb);
}
