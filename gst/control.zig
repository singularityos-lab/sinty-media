const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const object = @import("object.zig");
const binding = @import("controlbinding.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Obj = c.GstObject;
const Binding = c.GstControlBinding;
const NONE: c.GstClockTime = std.math.maxInt(u64);

pub fn dropBindings(o: *Obj) void {
    var l = o.control_bindings;
    while (l != null) : (l = l.*.next) object.gst_object_unparent(@ptrCast(@alignCast(l.*.data)));
    c.g_list_free(o.control_bindings);
    o.control_bindings = null;
}

fn find(o: [*c]Obj, name: [*c]const u8) [*c]Binding {
    var l = o[0].control_bindings;
    while (l != null) : (l = l.*.next) {
        const b: [*c]Binding = @ptrCast(@alignCast(l.*.data));
        if (c.strcmp(b[0].name, name) == 0) return b;
    }
    return null;
}

pub export fn gst_object_suggest_next_sync(o: [*c]Obj) c.GstClockTime {
    if (!check.that(object.isObject(o), "gst_object_suggest_next_sync", "GST_IS_OBJECT (object)")) return NONE;
    if (!check.that(o[0].control_rate != NONE, "gst_object_suggest_next_sync", "object->control_rate != GST_CLOCK_TIME_NONE")) return NONE;
    object.lock(o);
    defer object.unlock(o);
    return o[0].last_sync +% o[0].control_rate;
}

pub export fn gst_object_sync_values(o: [*c]Obj, ts: c.GstClockTime) c.gboolean {
    if (!check.that(object.isObject(o), "gst_object_sync_values", "GST_IS_OBJECT (object)")) return 0;
    if (!check.that(ts != NONE, "gst_object_sync_values", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (o[0].control_bindings == null) return 1;
    c.g_object_freeze_notify(@ptrCast(o));
    var ok: c.gboolean = 1;
    var l = o[0].control_bindings;
    while (l != null) : (l = l.*.next) ok &= binding.gst_control_binding_sync_values(@ptrCast(@alignCast(l.*.data)), o, ts, o[0].last_sync);
    o[0].last_sync = ts;
    c.g_object_thaw_notify(@ptrCast(o));
    return ok;
}

pub export fn gst_object_has_active_control_bindings(o: [*c]Obj) c.gboolean {
    if (!check.that(object.isObject(o), "gst_object_has_active_control_bindings", "GST_IS_OBJECT (object)")) return 0;
    object.lock(o);
    defer object.unlock(o);
    var l = o[0].control_bindings;
    while (l != null) : (l = l.*.next) if (binding.gst_control_binding_is_disabled(@ptrCast(@alignCast(l.*.data))) == 0) return 1;
    return 0;
}

pub export fn gst_object_set_control_bindings_disabled(o: [*c]Obj, disabled: c.gboolean) void {
    if (!check.that(object.isObject(o), "gst_object_set_control_bindings_disabled", "GST_IS_OBJECT (object)")) return;
    object.lock(o);
    defer object.unlock(o);
    var l = o[0].control_bindings;
    while (l != null) : (l = l.*.next) binding.gst_control_binding_set_disabled(@ptrCast(@alignCast(l.*.data)), disabled);
}

pub export fn gst_object_set_control_binding_disabled(o: [*c]Obj, name: [*c]const u8, disabled: c.gboolean) void {
    if (!check.that(object.isObject(o), "gst_object_set_control_binding_disabled", "GST_IS_OBJECT (object)")) return;
    if (!check.that(name != null, "gst_object_set_control_binding_disabled", "property_name")) return;
    object.lock(o);
    defer object.unlock(o);
    const b = find(o, name);
    if (b != null) binding.gst_control_binding_set_disabled(b, disabled);
}

pub export fn gst_object_add_control_binding(o: [*c]Obj, b: [*c]Binding) c.gboolean {
    if (!check.that(object.isObject(o), "gst_object_add_control_binding", "GST_IS_OBJECT (object)")) return 0;
    if (!check.that(binding.isBinding(b), "gst_object_add_control_binding", "GST_IS_CONTROL_BINDING (binding)")) return 0;
    if (!check.that(b[0].pspec != null, "gst_object_add_control_binding", "binding->pspec")) return 0;
    object.lock(o);
    defer object.unlock(o);
    const old = find(o, b[0].name);
    if (old != null) {
        o[0].control_bindings = c.g_list_remove(o[0].control_bindings, old);
        object.gst_object_unparent(@ptrCast(old));
    }
    o[0].control_bindings = c.g_list_prepend(o[0].control_bindings, b);
    _ = object.gst_object_set_parent(@ptrCast(b), o);
    return 1;
}

pub export fn gst_object_get_control_binding(o: [*c]Obj, name: [*c]const u8) [*c]Binding {
    if (!check.that(object.isObject(o), "gst_object_get_control_binding", "GST_IS_OBJECT (object)")) return null;
    if (!check.that(name != null, "gst_object_get_control_binding", "property_name")) return null;
    object.lock(o);
    defer object.unlock(o);
    const b = find(o, name);
    if (b != null) _ = object.gst_object_ref(b);
    return b;
}

pub export fn gst_object_remove_control_binding(o: [*c]Obj, b: [*c]Binding) c.gboolean {
    if (!check.that(object.isObject(o), "gst_object_remove_control_binding", "GST_IS_OBJECT (object)")) return 0;
    if (!check.that(binding.isBinding(b), "gst_object_remove_control_binding", "GST_IS_CONTROL_BINDING (binding)")) return 0;
    object.lock(o);
    defer object.unlock(o);
    const node = c.g_list_find(o[0].control_bindings, b);
    if (node == null) return 0;
    o[0].control_bindings = c.g_list_delete_link(o[0].control_bindings, node);
    object.gst_object_unparent(@ptrCast(b));
    return 1;
}

pub export fn gst_object_get_value(o: [*c]Obj, name: [*c]const u8, ts: c.GstClockTime) [*c]c.GValue {
    if (!check.that(object.isObject(o), "gst_object_get_value", "GST_IS_OBJECT (object)")) return null;
    if (!check.that(name != null, "gst_object_get_value", "property_name")) return null;
    if (!check.that(ts != NONE, "gst_object_get_value", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return null;
    object.lock(o);
    defer object.unlock(o);
    const b = find(o, name);
    return if (b != null) binding.gst_control_binding_get_value(b, ts) else null;
}

pub export fn gst_object_get_value_array(o: [*c]Obj, name: [*c]const u8, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: c.gpointer) c.gboolean {
    if (!check.that(object.isObject(o), "gst_object_get_value_array", "GST_IS_OBJECT (object)")) return 0;
    if (!check.that(name != null, "gst_object_get_value_array", "property_name")) return 0;
    if (!check.that(ts != NONE, "gst_object_get_value_array", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(interval != NONE, "gst_object_get_value_array", "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (!check.that(values != null, "gst_object_get_value_array", "values")) return 0;
    object.lock(o);
    defer object.unlock(o);
    const b = find(o, name);
    return if (b != null) binding.gst_control_binding_get_value_array(b, ts, interval, n, values) else 0;
}

pub export fn gst_object_get_g_value_array(o: [*c]Obj, name: [*c]const u8, ts: c.GstClockTime, interval: c.GstClockTime, n: c.guint, values: [*c]c.GValue) c.gboolean {
    if (!check.that(object.isObject(o), "gst_object_get_g_value_array", "GST_IS_OBJECT (object)")) return 0;
    if (!check.that(name != null, "gst_object_get_g_value_array", "property_name")) return 0;
    if (!check.that(ts != NONE, "gst_object_get_g_value_array", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return 0;
    if (!check.that(interval != NONE, "gst_object_get_g_value_array", "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    if (!check.that(values != null, "gst_object_get_g_value_array", "values")) return 0;
    object.lock(o);
    defer object.unlock(o);
    const b = find(o, name);
    return if (b != null) binding.gst_control_binding_get_g_value_array(b, ts, interval, n, values) else 0;
}

pub export fn gst_object_get_control_rate(o: [*c]Obj) c.GstClockTime {
    if (!check.that(object.isObject(o), "gst_object_get_control_rate", "GST_IS_OBJECT (object)")) return 0;
    return o[0].control_rate;
}

pub export fn gst_object_set_control_rate(o: [*c]Obj, rate: c.GstClockTime) void {
    if (!check.that(object.isObject(o), "gst_object_set_control_rate", "GST_IS_OBJECT (object)")) return;
    o[0].control_rate = rate;
}
