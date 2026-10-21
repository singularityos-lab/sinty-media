const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Fraction = c.GstParamSpecFraction;
const Array = c.GstParamSpecArray;
const Spec = c.GParamSpec;
const Value = c.GValue;

var fraction_once: gtype.Once = .{};
var array_once: gtype.Once = .{};

fn frac(p: anytype) *Fraction {
    return @ptrCast(@alignCast(p));
}

fn arr(p: anytype) *Array {
    return @ptrCast(@alignCast(p));
}

fn fractionInit(p: [*c]Spec) callconv(.c) void {
    const f = frac(p);
    f.min_num = 0;
    f.min_den = 1;
    f.max_num = std.math.maxInt(c.gint);
    f.max_den = 1;
    f.def_num = 1;
    f.def_den = 1;
}

fn fractionDefault(p: [*c]Spec, v: [*c]Value) callconv(.c) void {
    v[0].data[0].v_int = frac(p).def_num;
    v[0].data[1].v_int = frac(p).def_den;
}

fn fractionValue(num: c.gint, den: c.gint) Value {
    var v = std.mem.zeroes(Value);
    _ = c.g_value_init(&v, c.gst_fraction_get_type());
    c.gst_value_set_fraction(&v, num, den);
    return v;
}

fn fractionValidate(p: [*c]Spec, v: [*c]Value) callconv(.c) c.gboolean {
    const f = frac(p);
    var this = fractionValue(v[0].data[0].v_int, v[0].data[1].v_int);
    var lo = fractionValue(f.min_num, f.min_den);
    var hi = fractionValue(f.max_num, f.max_den);
    defer {
        c.g_value_unset(&lo);
        c.g_value_unset(&hi);
        c.g_value_unset(&this);
    }
    var r = c.gst_value_compare(&lo, &this);
    if (r != c.GST_VALUE_LESS_THAN and r != c.GST_VALUE_EQUAL) return 1;
    r = c.gst_value_compare(&this, &hi);
    if (r != c.GST_VALUE_LESS_THAN and r != c.GST_VALUE_EQUAL) return 1;
    return 0;
}

fn fractionCmp(_: [*c]Spec, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    return c.gst_value_compare(a, b);
}

pub export fn gst_param_spec_fraction_get_type() c.GType {
    return fraction_once.get(struct {
        fn f() c.GType {
            var info = c.GParamSpecTypeInfo{ .instance_size = @sizeOf(Fraction), .n_preallocs = 0, .instance_init = fractionInit, .value_type = c.gst_fraction_get_type(), .finalize = null, .value_set_default = fractionDefault, .value_validate = fractionValidate, .values_cmp = fractionCmp };
            return c.g_param_type_register_static("GstParamFraction", &info);
        }
    }.f);
}

pub export fn gst_param_spec_fraction(name: [*c]const u8, nick: [*c]const u8, blurb: [*c]const u8, min_num: c.gint, min_den: c.gint, max_num: c.gint, max_den: c.gint, def_num: c.gint, def_den: c.gint, flags: c.GParamFlags) [*c]Spec {
    const f: *Fraction = @ptrCast(@alignCast(c.g_param_spec_internal(gst_param_spec_fraction_get_type(), name, nick, blurb, flags)));
    f.min_num = min_num;
    f.min_den = min_den;
    f.max_num = max_num;
    f.max_den = max_den;
    f.def_num = def_num;
    f.def_den = def_den;
    var spec: [*c]Spec = @ptrCast(f);
    var d = fractionValue(def_num, def_den);
    defer c.g_value_unset(&d);
    if (fractionValidate(spec, &d) != 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "GstParamSpec of type 'fraction' for property '%s' has a default value of %d/%d, which is not within the allowed range of %d/%d to %d/%d", name, def_num, def_den, min_num, min_den, max_num, max_den);
        _ = c.g_param_spec_ref(spec);
        c.g_param_spec_sink(spec);
        c.g_param_spec_unref(spec);
        spec = null;
    }
    return spec;
}

fn arrayInit(p: [*c]Spec) callconv(.c) void {
    arr(p).element_spec = null;
}

fn arrayFinalize(p: [*c]Spec) callconv(.c) void {
    const a = arr(p);
    const parent: *c.GParamSpecClass = @ptrCast(@alignCast(c.g_type_class_peek(c.g_type_parent(gst_param_spec_array_get_type()))));
    if (a.element_spec != null) {
        c.g_param_spec_unref(a.element_spec);
        a.element_spec = null;
    }
    parent.finalize.?(p);
}

fn arrayValidate(p: [*c]Spec, v: [*c]Value) callconv(.c) c.gboolean {
    const es = arr(p).element_spec;
    if (es == null) return 0;
    var changed = false;
    var i: c.guint = 0;
    while (i < c.gst_value_array_get_size(v)) : (i += 1) {
        const e: [*c]Value = @constCast(c.gst_value_array_get_value(v, i));
        if (c.g_value_type_compatible(e[0].g_type, es[0].value_type) == 0) {
            if (e[0].g_type != 0) c.g_value_unset(e);
            _ = c.g_value_init(e, es[0].value_type);
            c.g_param_value_set_default(es, e);
            changed = true;
        }
        if (c.g_param_value_validate(es, e) != 0) changed = true;
    }
    return @intFromBool(changed);
}

fn arrayCmp(p: [*c]Spec, a: [*c]const Value, b: [*c]const Value) callconv(.c) c.gint {
    if (a == null or b == null) return if (b != null) -1 else @intFromBool(a != b);
    const sa = c.gst_value_array_get_size(a);
    const sb = c.gst_value_array_get_size(b);
    if (sa != sb) return if (sa < sb) -1 else 1;
    const es = arr(p).element_spec;
    if (es == null) return 0;
    var i: c.guint = 0;
    while (i < sa) : (i += 1) {
        const x = c.gst_value_array_get_value(a, i);
        const y = c.gst_value_array_get_value(b, i);
        if (x[0].g_type != y[0].g_type) return if (x[0].g_type < y[0].g_type) -1 else 1;
        const r = c.g_param_values_cmp(es, x, y);
        if (r != 0) return r;
    }
    return 0;
}

pub export fn gst_param_spec_array_get_type() c.GType {
    return array_once.get(struct {
        fn f() c.GType {
            var info = c.GParamSpecTypeInfo{ .instance_size = @sizeOf(Array), .n_preallocs = 0, .instance_init = arrayInit, .value_type = c.gst_value_array_get_type(), .finalize = arrayFinalize, .value_set_default = null, .value_validate = arrayValidate, .values_cmp = arrayCmp };
            return c.g_param_type_register_static("GstParamArray", &info);
        }
    }.f);
}

pub export fn gst_param_spec_array(name: [*c]const u8, nick: [*c]const u8, blurb: [*c]const u8, element: [*c]Spec, flags: c.GParamFlags) [*c]Spec {
    if (!check.that(element == null or gtype.instanceOf(element, c.G_TYPE_PARAM), "gst_param_spec_array", "element_spec == NULL || G_IS_PARAM_SPEC (element_spec)")) return null;
    const a: ?*Array = @ptrCast(@alignCast(c.g_param_spec_internal(gst_param_spec_array_get_type(), name, nick, blurb, flags)));
    const spec = a orelse return null;
    if (element != null) {
        spec.element_spec = c.g_param_spec_ref(element);
        c.g_param_spec_sink(element);
    }
    return @ptrCast(spec);
}
