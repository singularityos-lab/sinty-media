const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const object = @import("object.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Binding = c.GstControlBinding;
const BindingClass = c.GstControlBindingClass;
const Source = c.GstControlSource;
const NONE: c.GstClockTime = std.math.maxInt(u64);

const Private = extern struct {
    object: c.GWeakRef,
};

const PROP_OBJECT = 1;
const PROP_NAME = 2;

var binding_once: gtype.Once = .{};
var binding_offset: c.gint = 0;
var binding_parent: ?*c.GObjectClass = null;
var binding_cat: [*c]c.GstDebugCategory = null;

var source_once: gtype.Once = .{};
var source_cat: [*c]c.GstDebugCategory = null;

fn priv(b: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]Binding, @ptrCast(@alignCast(b)))[0].ABI.abi.priv));
}

fn of(b: anytype) [*c]Binding {
    return @ptrCast(@alignCast(b));
}

pub fn isBinding(p: anytype) bool {
    return gtype.instanceOf(p, gst_control_binding_get_type());
}

fn isSource(p: anytype) bool {
    return gtype.instanceOf(p, gst_control_source_get_type());
}

fn valid(t: c.GstClockTime) bool {
    return t != NONE;
}

fn warn(b: ?*anyopaque, text: [*c]const u8) void {
    info.logText(binding_cat, c.GST_LEVEL_WARNING, "../gst/gstcontrolbinding.c", "gst_control_binding", 0, @ptrCast(@alignCast(b)), null, text);
}

pub export fn gst_control_binding_get_type() c.GType {
    return binding_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type, "GstControlBinding", BindingClass, Binding, bindingClassInit, bindingInit, c.G_TYPE_FLAG_ABSTRACT);
            binding_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            binding_cat = info._gst_debug_category_new("gstcontrolbinding", 0, "dynamic parameter control source attachment");
            return t;
        }
    }.f);
}

fn bindingClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &binding_offset);
    binding_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.constructor = construct;
    gc.set_property = bindingSet;
    gc.get_property = bindingGet;
    gc.dispose = bindingDispose;
    gc.finalize = bindingFinalize;
    const fl = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS;
    var pspecs = [_]?*c.GParamSpec{
        null,
        c.g_param_spec_object("object", "Object", "The object of the property", object.gst_object_get_type(), fl),
        c.g_param_spec_string("name", "Name", "The name of the property", null, fl),
    };
    c.g_object_class_install_properties(gc, pspecs.len, @ptrCast(&pspecs));
}

fn bindingInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const base: [*]u8 = @ptrCast(instance);
    const p: *Private = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, binding_offset)))));
    of(instance)[0].ABI.abi.priv = @ptrCast(p);
    c.g_weak_ref_init(&p.object, null);
}

fn construct(t: c.GType, n: c.guint, params: [*c]c.GObjectConstructParam) callconv(.c) [*c]c.GObject {
    const go = binding_parent.?.constructor.?(t, n, params);
    const b = of(go);
    const target: ?*c.GObject = @ptrCast(@alignCast(c.g_weak_ref_get(&priv(b).object)));
    const o = target orelse {
        warn(null, "no object set");
        return go;
    };
    defer object.gst_object_unref(o);
    const pspec = c.g_object_class_find_property(@ptrCast(@alignCast(o.g_type_instance.g_class)), b[0].name);
    if (pspec == null) {
        const text = c.g_strdup_printf("class '%s' has no property '%s'", c.g_type_name(gtype.typeOf(o)), b[0].name);
        defer c.g_free(text);
        warn(o, text);
        return go;
    }
    const want = c.G_PARAM_WRITABLE | c.GST_PARAM_CONTROLLABLE;
    if (pspec[0].flags & (want | c.G_PARAM_CONSTRUCT_ONLY) == want) {
        b[0].pspec = pspec;
    } else {
        const text = c.g_strdup_printf("property '%s' on class '%s' needs to be writeable, controllable and not construct_only", b[0].name, c.g_type_name(gtype.typeOf(o)));
        defer c.g_free(text);
        warn(o, text);
    }
    return go;
}

fn bindingDispose(go: [*c]c.GObject) callconv(.c) void {
    const b = of(go);
    if (b[0].object != null) c.g_object_remove_weak_pointer(@ptrCast(@alignCast(b[0].object)), @ptrCast(&b[0].object));
    b[0].object = null;
    c.g_weak_ref_clear(&priv(b).object);
    binding_parent.?.dispose.?(go);
}

fn bindingFinalize(go: [*c]c.GObject) callconv(.c) void {
    c.g_free(of(go)[0].name);
    binding_parent.?.finalize.?(go);
}

fn bindingSet(go: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const b = of(go);
    switch (id) {
        PROP_OBJECT => {
            b[0].object = @ptrCast(@alignCast(c.g_value_get_object(v)));
            c.g_object_add_weak_pointer(@ptrCast(@alignCast(b[0].object)), @ptrCast(&b[0].object));
            c.g_weak_ref_set(&priv(b).object, b[0].object);
        },
        PROP_NAME => b[0].name = c.g_value_dup_string(v),
        else => object.warnBadProperty(go, id, pspec),
    }
}

fn bindingGet(go: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const b = of(go);
    switch (id) {
        PROP_OBJECT => c.g_value_take_object(v, c.g_weak_ref_get(&priv(b).object)),
        PROP_NAME => c.g_value_set_string(v, b[0].name),
        else => object.warnBadProperty(go, id, pspec),
    }
}

fn classOf(b: [*c]Binding) *BindingClass {
    return gtype.classPeek(BindingClass, b);
}

pub export fn gst_control_binding_sync_values(b: [*c]Binding, o: [*c]c.GstObject, ts: c.GstClockTime, last: c.GstClockTime) c.gboolean {
    if (!check.that(isBinding(b), "gst_control_binding_sync_values", "GST_IS_CONTROL_BINDING (binding)")) return 0;
    if (!check.that(valid(ts), "gst_control_binding_sync_values", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (b[0].disabled != 0) return 1;
    if (classOf(b).sync_values) |f| return f(b, o, ts, last);
    warn(b, "missing sync_values implementation");
    return 0;
}

pub export fn gst_control_binding_get_value(b: [*c]Binding, ts: c.GstClockTime) [*c]c.GValue {
    if (!check.that(isBinding(b), "gst_control_binding_get_value", "GST_IS_CONTROL_BINDING (binding)")) return null;
    if (!check.that(valid(ts), "gst_control_binding_get_value", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return null;
    if (classOf(b).get_value) |f| return f(b, ts);
    warn(b, "missing get_value implementation");
    return null;
}

pub export fn gst_control_binding_get_value_array(b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: c.gpointer) c.gboolean {
    if (!check.that(isBinding(b), "gst_control_binding_get_value_array", "GST_IS_CONTROL_BINDING (binding)")) return 0;
    if (!check.that(valid(ts), "gst_control_binding_get_value_array", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(valid(interval), "gst_control_binding_get_value_array", "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (!check.that(values != null, "gst_control_binding_get_value_array", "values")) return 0;
    if (classOf(b).get_value_array) |f| return f(b, ts, interval, n, values);
    warn(b, "missing get_value_array implementation");
    return 0;
}

fn fill(comptime T: type, b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, out: [*c]c.GValue, t: c.GType, comptime set: anytype) c.gboolean {
    const raw: [*c]T = @ptrCast(@alignCast(c.g_malloc_n(n, @sizeOf(T))));
    defer c.g_free(raw);
    const ok = gst_control_binding_get_value_array(b, ts, interval, n, raw);
    if (ok == 0) return ok;
    for (0..n) |i| {
        _ = c.g_value_init(&out[i], t);
        set(&out[i], raw[i]);
    }
    return ok;
}

pub export fn gst_control_binding_get_g_value_array(b: [*c]Binding, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.GValue) c.gboolean {
    if (!check.that(isBinding(b), "gst_control_binding_get_g_value_array", "GST_IS_CONTROL_BINDING (binding)")) return 0;
    if (!check.that(valid(ts), "gst_control_binding_get_g_value_array", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(valid(interval), "gst_control_binding_get_g_value_array", "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (!check.that(values != null, "gst_control_binding_get_g_value_array", "values")) return 0;
    if (classOf(b).get_g_value_array) |f| return f(b, ts, interval, n, values);
    const base = c.g_type_fundamental(b[0].pspec[0].value_type);
    const F = c.G_TYPE_FUNDAMENTAL_SHIFT;
    return switch (base >> F) {
        6 => fill(c.gint, b, ts, interval, n, values, base, c.g_value_set_int),
        7 => fill(c.guint, b, ts, interval, n, values, base, c.g_value_set_uint),
        8 => fill(c.glong, b, ts, interval, n, values, base, c.g_value_set_long),
        9 => fill(c.gulong, b, ts, interval, n, values, base, c.g_value_set_ulong),
        10 => fill(c.gint64, b, ts, interval, n, values, base, c.g_value_set_int64),
        11 => fill(c.guint64, b, ts, interval, n, values, base, c.g_value_set_uint64),
        14 => fill(c.gfloat, b, ts, interval, n, values, base, c.g_value_set_float),
        15 => fill(c.gdouble, b, ts, interval, n, values, base, c.g_value_set_double),
        5 => fill(c.gboolean, b, ts, interval, n, values, base, c.g_value_set_boolean),
        12 => fill(c.gint, b, ts, interval, n, values, 0, c.g_value_set_enum),
        else => blk: {
            const text = c.g_strdup_printf("incomplete implementation for paramspec type '%s'", c.g_type_name(gtype.typeOf(b[0].pspec)));
            defer c.g_free(text);
            info.logText(binding_cat, c.GST_LEVEL_WARNING, "../gst/gstcontrolbinding.c", "gst_control_binding_get_g_value_array", 0, null, null, text);
            b[0].pspec = null;
            break :blk 0;
        },
    };
}

pub export fn gst_control_binding_set_disabled(b: [*c]Binding, disabled: c.gboolean) void {
    if (!check.that(isBinding(b), "gst_control_binding_set_disabled", "GST_IS_CONTROL_BINDING (binding)")) return;
    b[0].disabled = disabled;
}

pub export fn gst_control_binding_is_disabled(b: [*c]Binding) c.gboolean {
    if (!check.that(isBinding(b), "gst_control_binding_is_disabled", "GST_IS_CONTROL_BINDING (binding)")) return 1;
    return @intFromBool(b[0].disabled != 0);
}

pub export fn gst_control_source_get_type() c.GType {
    return source_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type, "GstControlSource", c.GstControlSourceClass, Source, null, null, c.G_TYPE_FLAG_ABSTRACT);
            source_cat = info._gst_debug_category_new("gstcontrolsource", 0, "dynamic parameter control sources");
            return t;
        }
    }.f);
}

fn unbound(func: [*c]const u8) void {
    info.logText(source_cat, c.GST_LEVEL_ERROR, "../gst/gstcontrolsource.c", func, 0, null, null, "Not bound to a specific property yet!");
}

pub export fn gst_control_source_get_value(s: [*c]Source, ts: c.GstClockTime, value: [*c]c.gdouble) c.gboolean {
    if (!check.that(isSource(s), "gst_control_source_get_value", "GST_IS_CONTROL_SOURCE (self)")) return 0;
    if (!check.that(valid(ts), "gst_control_source_get_value", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (s[0].get_value) |f| return f(s, ts, value);
    unbound("gst_control_source_get_value");
    return 0;
}

pub export fn gst_control_source_get_value_array(s: [*c]Source, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.gdouble) c.gboolean {
    if (!check.that(isSource(s), "gst_control_source_get_value_array", "GST_IS_CONTROL_SOURCE (self)")) return 0;
    if (!check.that(valid(ts), "gst_control_source_get_value_array", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(valid(interval), "gst_control_source_get_value_array", "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (s[0].get_value_array) |f| return f(s, ts, interval, n, values);
    unbound("gst_control_source_get_value_array");
    return 0;
}
