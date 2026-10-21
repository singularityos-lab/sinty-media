const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const va = @import("varargs.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Proxy = c.GstChildProxy;
const Iface = c.GstChildProxyInterface;
const NONE_TYPE: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;

var type_once: gtype.Once = .{};
var added_signal: c.guint = 0;
var removed_signal: c.guint = 0;
var signals_ready = false;

pub fn isProxy(p: anytype) bool {
    return gtype.instanceOf(p, gst_child_proxy_get_type());
}

fn iface(p: ?*Proxy) *Iface {
    return @ptrCast(@alignCast(c.g_type_interface_peek(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class, gst_child_proxy_get_type())));
}

fn nameOf(p: anytype) [*c]const u8 {
    if (!object.isObject(p)) return "";
    return object.of(p).name;
}

pub export fn gst_child_proxy_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            var t_info = std.mem.zeroes(c.GTypeInfo);
            t_info.class_size = @sizeOf(Iface);
            t_info.base_init = baseInit;
            t_info.class_init = classInit;
            const t = c.g_type_register_static(2 << c.G_TYPE_FUNDAMENTAL_SHIFT, "GstChildProxy", &t_info, 0);
            c.g_type_interface_add_prerequisite(t, 20 << c.G_TYPE_FUNDAMENTAL_SHIFT);
            return t;
        }
    }.f);
}

fn baseInit(klass: c.gpointer) callconv(.c) void {
    if (signals_ready) return;
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    const obj: c.GType = 20 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    const str: c.GType = 16 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    added_signal = c.g_signal_new("child-added", t, c.G_SIGNAL_RUN_FIRST, @offsetOf(Iface, "child_added"), null, null, null, NONE_TYPE, @as(c.guint, 2), obj, str);
    removed_signal = c.g_signal_new("child-removed", t, c.G_SIGNAL_RUN_FIRST, @offsetOf(Iface, "child_removed"), null, null, null, NONE_TYPE, @as(c.guint, 2), obj, str);
    signals_ready = true;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    @as(*Iface, @ptrCast(@alignCast(klass))).get_child_by_name = defaultByName;
}

pub export fn gst_child_proxy_get_child_by_name_recurse(p: ?*Proxy, name: [*c]const u8) [*c]c.GObject {
    if (!check.that(p != null, "gst_child_proxy_get_child_by_name_recurse", "child_proxy != NULL")) return null;
    if (!check.that(name != null, "gst_child_proxy_get_child_by_name_recurse", "name != NULL")) return null;
    const names = c.g_strsplit(name, "::", -1);
    defer c.g_strfreev(names);
    var cur = names;
    var obj: [*c]c.GObject = null;
    var next: [*c]c.GObject = null;
    if (cur[0] != null) obj = @ptrCast(@alignCast(c.g_object_ref(p)));
    while (cur[0] != null) : (cur += 1) {
        if (!isProxy(obj)) {
            c.gst_object_unref(obj);
            next = null;
            break;
        }
        next = gst_child_proxy_get_child_by_name(@ptrCast(obj), cur[0]);
        c.gst_object_unref(obj);
        if (next == null) break;
        obj = next;
    }
    return next;
}

fn defaultByName(p: ?*Proxy, name: [*c]const u8) callconv(.c) [*c]c.GObject {
    if (!check.that(isProxy(p), "gst_child_proxy_default_get_child_by_name", "GST_IS_CHILD_PROXY (parent)")) return null;
    if (!check.that(name != null, "gst_child_proxy_default_get_child_by_name", "name != NULL")) return null;
    const n = gst_child_proxy_get_children_count(p);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const o = gst_child_proxy_get_child_by_index(p, i);
        if (o == null) continue;
        if (object.isObject(o)) {
            const on = c.gst_object_get_name(@ptrCast(o));
            if (on == null) {
                c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "child %u of parent %s has no name", i, nameOf(p));
            } else {
                const eq = c.g_str_equal(on, name) != 0;
                c.g_free(on);
                if (eq) return o;
            }
        }
        c.gst_object_unref(o);
    }
    return null;
}

pub export fn gst_child_proxy_get_child_by_name(p: ?*Proxy, name: [*c]const u8) [*c]c.GObject {
    if (!check.that(isProxy(p), "gst_child_proxy_get_child_by_name", "GST_IS_CHILD_PROXY (parent)")) return null;
    if (iface(p).get_child_by_name) |f| return f(p, name);
    return null;
}

pub export fn gst_child_proxy_get_child_by_index(p: ?*Proxy, idx: c.guint) [*c]c.GObject {
    if (!check.that(isProxy(p), "gst_child_proxy_get_child_by_index", "GST_IS_CHILD_PROXY (parent)")) return null;
    if (iface(p).get_child_by_index) |f| return f(p, idx);
    return null;
}

pub export fn gst_child_proxy_get_children_count(p: ?*Proxy) c.guint {
    if (!check.that(isProxy(p), "gst_child_proxy_get_children_count", "GST_IS_CHILD_PROXY (parent)")) return 0;
    if (iface(p).get_children_count) |f| return f(p);
    return 0;
}

pub export fn gst_child_proxy_lookup(p: ?*Proxy, name: [*c]const u8, target: [*c][*c]c.GObject, pspec: [*c][*c]c.GParamSpec) c.gboolean {
    if (!check.that(isProxy(p), "gst_child_proxy_lookup", "GST_IS_CHILD_PROXY (object)")) return 0;
    if (!check.that(name != null, "gst_child_proxy_lookup", "name != NULL")) return 0;
    var prop: [*c]const u8 = c.g_strrstr(name, "::");
    var child: [*c]c.GObject = null;
    if (prop == null) {
        child = @ptrCast(@alignCast(c.gst_object_ref(p)));
        prop = name;
    } else {
        prop += 2;
        const path = c.g_strndup(name, @intCast(prop - name - 2));
        child = gst_child_proxy_get_child_by_name_recurse(p, path);
        c.g_free(path);
        if (child == null) return 0;
    }
    defer c.gst_object_unref(child);
    const spec = c.g_object_class_find_property(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(child))).g_class)), prop);
    if (spec == null) return 0;
    if (pspec != null) pspec.* = spec;
    if (target != null) {
        _ = c.g_object_ref(child);
        target.* = child;
    }
    return 1;
}

pub export fn gst_child_proxy_get_property(p: ?*Proxy, name: [*c]const u8, v: [*c]c.GValue) void {
    const f = "gst_child_proxy_get_property";
    if (!check.that(isProxy(p), f, "GST_IS_CHILD_PROXY (object)")) return;
    if (!check.that(name != null, f, "name != NULL")) return;
    if (!check.that(v != null, f, "value != NULL")) return;
    var target: [*c]c.GObject = null;
    var pspec: [*c]c.GParamSpec = null;
    if (gst_child_proxy_lookup(p, name, &target, &pspec) == 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "no property %s in object %s", name, nameOf(p));
        return;
    }
    if (v[0].g_type == 0) _ = c.g_value_init(v, pspec[0].value_type);
    c.g_object_get_property(target, pspec[0].name, v);
    c.gst_object_unref(target);
}

fn copyOut(v: *c.GValue, ap: *va.VaList) callconv(.c) [*c]u8 {
    const vtab = c.g_type_value_table_peek(v.g_type);
    var cv: [8]va.CValue = std.mem.zeroes([8]va.CValue);
    var n: c.guint = 0;
    var fmt = vtab[0].lcopy_format;
    while (fmt[0] != 0) : (fmt += 1) {
        cv[n].v_pointer = @cVaArg(ap, c.gpointer);
        n += 1;
    }
    return vtab[0].lcopy_value.?(v, n, @ptrCast(&cv), 0);
}

pub export fn gst_child_proxy_get_valist(p: ?*Proxy, first: [*c]const u8, ap_c: va.CVaList) void {
    if (!check.that(isProxy(p), "gst_child_proxy_get_valist", "GST_IS_CHILD_PROXY (object)")) return;
    const ap = va.fromC(ap_c);
    var name = first;
    while (name != null) {
        var target: [*c]c.GObject = null;
        var pspec: [*c]c.GParamSpec = null;
        if (gst_child_proxy_lookup(p, name, &target, &pspec) == 0) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "no property %s in object %s", name, nameOf(p));
            return;
        }
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, pspec[0].value_type);
        c.g_object_get_property(target, pspec[0].name, &v);
        c.gst_object_unref(target);
        const err = copyOut(&v, ap);
        if (err != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "error copying value %s in object %s: %s", pspec[0].name, nameOf(p), err);
            c.g_value_unset(&v);
            return;
        }
        c.g_value_unset(&v);
        name = @cVaArg(ap, [*c]const u8);
    }
}

pub export fn gst_child_proxy_get(p: ?*Proxy, first: [*c]const u8, ...) callconv(.c) void {
    if (!check.that(isProxy(p), "gst_child_proxy_get", "GST_IS_CHILD_PROXY (object)")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    gst_child_proxy_get_valist(p, first, va.toC(&ap));
}

pub export fn gst_child_proxy_set_property(p: ?*Proxy, name: [*c]const u8, v: [*c]const c.GValue) void {
    const f = "gst_child_proxy_set_property";
    if (!check.that(isProxy(p), f, "GST_IS_CHILD_PROXY (object)")) return;
    if (!check.that(name != null, f, "name != NULL")) return;
    if (!check.that(v != null and v[0].g_type != 0, f, "G_IS_VALUE (value)")) return;
    var target: [*c]c.GObject = null;
    var pspec: [*c]c.GParamSpec = null;
    if (gst_child_proxy_lookup(p, name, &target, &pspec) == 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "cannot set property %s on object %s", name, nameOf(p));
        return;
    }
    c.g_object_set_property(target, pspec[0].name, v);
    c.gst_object_unref(target);
}

pub export fn gst_child_proxy_set_valist(p: ?*Proxy, first: [*c]const u8, ap_c: va.CVaList) void {
    if (!check.that(isProxy(p), "gst_child_proxy_set_valist", "GST_IS_CHILD_PROXY (object)")) return;
    const ap = va.fromC(ap_c);
    var name = first;
    while (name != null) {
        var target: [*c]c.GObject = null;
        var pspec: [*c]c.GParamSpec = null;
        if (gst_child_proxy_lookup(p, name, &target, &pspec) == 0) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "no property %s in object %s", name, nameOf(p));
            return;
        }
        var v = std.mem.zeroes(c.GValue);
        const err = va.collect(&v, pspec[0].value_type, ap);
        if (err != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "error copying value %s in object %s: %s", pspec[0].name, nameOf(p), err);
            c.g_value_unset(&v);
            c.gst_object_unref(target);
            c.g_free(err);
            return;
        }
        c.g_object_set_property(target, pspec[0].name, &v);
        c.gst_object_unref(target);
        c.g_value_unset(&v);
        name = @cVaArg(ap, [*c]const u8);
    }
}

pub export fn gst_child_proxy_set(p: ?*Proxy, first: [*c]const u8, ...) callconv(.c) void {
    if (!check.that(isProxy(p), "gst_child_proxy_set", "GST_IS_CHILD_PROXY (object)")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    gst_child_proxy_set_valist(p, first, va.toC(&ap));
}

pub export fn gst_child_proxy_child_added(p: ?*Proxy, child: [*c]c.GObject, name: [*c]const u8) void {
    c.g_signal_emit(p, added_signal, 0, child, name);
}

pub export fn gst_child_proxy_child_removed(p: ?*Proxy, child: [*c]c.GObject, name: [*c]const u8) void {
    c.g_signal_emit(p, removed_signal, 0, child, name);
}
