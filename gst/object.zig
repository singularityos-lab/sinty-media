const std = @import("std");
const c = @import("c.zig").c;
const gtype = @import("gtype.zig");
const check = @import("check.zig");
const tracer = @import("tracer.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Obj = c.GstObject;
const NONE: c.GstClockTime = std.math.maxInt(u64);
const G_TYPE_STRING: c.GType = 16 << c.G_TYPE_FUNDAMENTAL_SHIFT;
const G_TYPE_PARAM: c.GType = 19 << c.G_TYPE_FUNDAMENTAL_SHIFT;

const PROP_NAME = 1;
const PROP_PARENT = 2;

var type_once: gtype.Once = .{};
var base_class: ?*c.GObjectClass = null;
var pspecs: [3]?*c.GParamSpec = .{ null, null, null };
var deep_notify: c.guint = 0;

var name_guard: c.GMutex = std.mem.zeroes(c.GMutex);
var name_counters: ?*c.GHashTable = null;

fn registerType() c.GType {
    return gtype.object(c.g_initially_unowned_get_type(), "GstObject", c.GstObjectClass, Obj, classInit, instanceInit, c.G_TYPE_FLAG_ABSTRACT);
}

pub export fn gst_object_get_type() c.GType {
    return type_once.get(registerType);
}

pub fn of(p: anytype) *Obj {
    return @ptrCast(@alignCast(@constCast(p)));
}

pub fn lock(p: anytype) void {
    c.g_mutex_lock(&of(p).lock);
}

pub fn unlock(p: anytype) void {
    c.g_mutex_unlock(&of(p).lock);
}

pub fn isObject(p: anytype) bool {
    return gtype.instanceOf(p, gst_object_get_type());
}

pub fn warnBadProperty(o: [*c]c.GObject, id: c.guint, pspec: ?*c.GParamSpec) void {
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "invalid %s id %u for \"%s\" of type '%s' in '%s'", "property", id, pspec.?.name, c.g_type_name(pspec.?.g_type_instance.g_class.*.g_type), c.g_type_name(gtype.typeOf(o)));
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const o: *Obj = @ptrCast(@alignCast(instance));
    c.g_mutex_init(&o.lock);
    o.parent = null;
    o.name = null;
    o.flags = 0;
    o.control_rate = 100 * c.GST_MSECOND;
    o.last_sync = NONE;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    const oc: *c.GstObjectClass = @ptrCast(@alignCast(klass));
    base_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const static = c.G_PARAM_STATIC_NAME | c.G_PARAM_STATIC_NICK | c.G_PARAM_STATIC_BLURB;
    pspecs[PROP_NAME] = c.g_param_spec_string("name", "Name", "The name of the object", null, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | static | c.GST_PARAM_DOC_SHOW_DEFAULT);
    pspecs[PROP_PARENT] = c.g_param_spec_object("parent", "Parent", "The parent of the object", gst_object_get_type(), c.G_PARAM_READWRITE | static | c.GST_PARAM_DOC_SHOW_DEFAULT);
    c.g_object_class_install_properties(gc, 3, @ptrCast(&pspecs));
    deep_notify = c.g_signal_new("deep-notify", @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type, c.G_SIGNAL_RUN_FIRST | c.G_SIGNAL_NO_RECURSE | c.G_SIGNAL_DETAILED | c.G_SIGNAL_NO_HOOKS, @offsetOf(c.GstObjectClass, "deep_notify"), null, null, null, @as(c.GType, 1 << c.G_TYPE_FUNDAMENTAL_SHIFT), @as(c.guint, 2), gst_object_get_type(), G_TYPE_PARAM);
    oc.path_string_separator = "/";
    gc.dispatch_properties_changed = propertiesChanged;
    gc.constructed = constructed;
    gc.dispose = dispose;
    gc.finalize = finalize;
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    of(o).flags |= c.GST_OBJECT_FLAG_CONSTRUCTED;
    tracer.emit(.object_created, .{@as([*c]Obj, of(o))});
    if (base_class.?.constructed) |f| f(o);
}

fn dispose(go: [*c]c.GObject) callconv(.c) void {
    const o = of(go);
    lock(o);
    if (o.parent != null) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "\nTrying to dispose object \"%s\", but it still has a parent \"%s\".\nYou need to let the parent manage the object instead of unreffing the object directly.\n", o.name, o.parent.*.name);
        unlock(o);
        _ = gst_object_ref(o);
        return;
    }
    unlock(o);
    @import("control.zig").dropBindings(o);
    if (base_class.?.dispose) |f| f(go);
}

fn finalize(go: [*c]c.GObject) callconv(.c) void {
    const o = of(go);
    c.g_signal_handlers_destroy(go);
    c.g_free(o.name);
    c.g_mutex_clear(&o.lock);
    tracer.emit(.object_destroyed, .{@as([*c]Obj, o)});
    if (base_class.?.finalize) |f| f(go);
}

fn propertiesChanged(go: [*c]c.GObject, n: c.guint, list: [*c][*c]c.GParamSpec) callconv(.c) void {
    base_class.?.dispatch_properties_changed.?(go, n, list);
    var up = gst_object_get_parent(of(go));
    while (up != null) {
        for (list[0..n]) |p| c.g_signal_emit(up, deep_notify, c.g_quark_from_string(p.*.name), go, p);
        const next = gst_object_get_parent(up);
        gst_object_unref(up);
        up = next;
    }
}

pub export fn gst_object_ref(p: c.gpointer) c.gpointer {
    if (!check.that(p != null, "gst_object_ref", "object != NULL")) return null;
    tracer.emit(.object_reffed, .{ @as([*c]Obj, @ptrCast(@alignCast(p))), @as(c.gint, @intCast(@as(*c.GObject, @ptrCast(@alignCast(p))).ref_count + 1)) });
    return c.g_object_ref(p);
}

pub export fn gst_object_unref(p: c.gpointer) void {
    if (!check.that(p != null, "gst_object_unref", "object != NULL")) return;
    if (!check.that(@as(*c.GObject, @ptrCast(@alignCast(p))).ref_count > 0, "gst_object_unref", "((GObject *) object)->ref_count > 0")) return;
    tracer.emit(.object_unreffed, .{ @as([*c]Obj, @ptrCast(@alignCast(p))), @as(c.gint, @intCast(@as(*c.GObject, @ptrCast(@alignCast(p))).ref_count - 1)) });
    c.g_object_unref(p);
}

pub export fn gst_object_ref_sink(p: c.gpointer) c.gpointer {
    if (!check.that(p != null, "gst_object_ref_sink", "object != NULL")) return null;
    return c.g_object_ref_sink(p);
}

pub export fn gst_clear_object(slot: [*c][*c]Obj) void {
    const o = slot.*;
    if (o != null) {
        slot.* = null;
        gst_object_unref(o);
    }
}

pub export fn gst_object_replace(slot: [*c][*c]Obj, new: [*c]Obj) c.gboolean {
    if (!check.that(slot != null, "gst_object_replace", "oldobj != NULL")) return 0;
    const p: *?*Obj = @ptrCast(slot);
    const want: ?*Obj = @ptrCast(new);
    var old = @atomicLoad(?*Obj, p, .acquire);
    if (old == want) return 0;
    if (want) |w| _ = gst_object_ref(w);
    while (@cmpxchgWeak(?*Obj, p, old, want, .acq_rel, .acquire)) |seen| {
        old = seen;
        if (old == want) break;
    }
    if (old) |o| gst_object_unref(o);
    return @intFromBool(old != want);
}

fn defaultName(o: *Obj) bool {
    const q = c.g_type_qname(gtype.typeOf(o));
    c.g_mutex_lock(&name_guard);
    if (name_counters == null) name_counters = c.g_hash_table_new(null, null);
    const key: c.gpointer = @ptrFromInt(q);
    const n: c_int = @intCast(@intFromPtr(c.g_hash_table_lookup(name_counters, key)));
    _ = c.g_hash_table_insert(name_counters, key, @ptrFromInt(@as(usize, @intCast(n + 1))));
    c.g_mutex_unlock(&name_guard);
    var base = std.mem.span(c.g_quark_to_string(q));
    if (std.mem.startsWith(u8, base, "Gst")) base = base[3..];
    const sep: [*c]const u8 = if (base.len > 0 and std.ascii.isDigit(base[base.len - 1])) "-" else "";
    const name = c.g_strdup_printf("%.*s%s%d", @as(c_int, @intCast(base.len)), base.ptr, sep, n);
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) name[i] = std.ascii.toLower(name[i]);
    lock(o);
    defer unlock(o);
    if (o.parent != null) {
        c.g_free(name);
        return false;
    }
    c.g_free(o.name);
    o.name = name;
    return true;
}

fn rename(o: *Obj, name: [*c]const u8) bool {
    lock(o);
    if (o.parent != null) {
        unlock(o);
        return false;
    }
    if (name == null) {
        unlock(o);
        return defaultName(o);
    }
    c.g_free(o.name);
    o.name = c.g_strdup(name);
    unlock(o);
    return true;
}

pub export fn gst_object_set_name(o: [*c]Obj, name: [*c]const u8) c.gboolean {
    if (!check.that(isObject(o), "gst_object_set_name", "GST_IS_OBJECT (object)")) return 0;
    if (!rename(o, name)) return 0;
    c.g_object_notify_by_pspec(@ptrCast(o), pspecs[PROP_NAME]);
    return 1;
}

pub export fn gst_object_get_name(o: [*c]Obj) [*c]u8 {
    if (!check.that(isObject(o), "gst_object_get_name", "GST_IS_OBJECT (object)")) return null;
    lock(o);
    defer unlock(o);
    return c.g_strdup(o.*.name);
}

pub export fn gst_object_set_parent(o: [*c]Obj, parent: [*c]Obj) c.gboolean {
    const func = "gst_object_set_parent";
    if (!check.that(isObject(o), func, "GST_IS_OBJECT (object)")) return 0;
    if (!check.that(isObject(parent), func, "GST_IS_OBJECT (parent)")) return 0;
    if (!check.that(o != parent, func, "object != parent")) return 0;
    lock(o);
    defer unlock(o);
    if (o.*.parent != null) {
        _ = gst_object_ref_sink(o);
        gst_object_unref(o);
        return 0;
    }
    o.*.parent = parent;
    _ = gst_object_ref_sink(o);
    return 1;
}

pub export fn gst_object_get_parent(o: [*c]Obj) [*c]Obj {
    if (!check.that(isObject(o), "gst_object_get_parent", "GST_IS_OBJECT (object)")) return null;
    lock(o);
    defer unlock(o);
    const p = o.*.parent;
    if (p != null) _ = gst_object_ref(p);
    return p;
}

pub export fn gst_object_get_toplevel(o: [*c]Obj) [*c]Obj {
    if (!check.that(isObject(o), "gst_object_get_toplevel", "GST_IS_OBJECT (object)")) return null;
    var top: [*c]Obj = @ptrCast(@alignCast(gst_object_ref(o)));
    while (true) {
        const up = gst_object_get_parent(top);
        if (up == null) return top;
        gst_object_unref(top);
        top = up;
    }
}

pub export fn gst_object_unparent(o: [*c]Obj) void {
    if (!check.that(isObject(o), "gst_object_unparent", "GST_IS_OBJECT (object)")) return;
    lock(o);
    if (o.*.parent == null) {
        unlock(o);
        return;
    }
    o.*.parent = null;
    unlock(o);
    gst_object_unref(o);
}

pub export fn gst_object_has_as_parent(o: [*c]Obj, parent: [*c]Obj) c.gboolean {
    if (!isObject(o) or !isObject(parent)) return 0;
    lock(o);
    defer unlock(o);
    return @intFromBool(o.*.parent == parent);
}

pub export fn gst_object_has_as_ancestor(o: [*c]Obj, ancestor: [*c]Obj) c.gboolean {
    if (o == null or ancestor == null) return 0;
    var cur: [*c]Obj = @ptrCast(@alignCast(gst_object_ref(o)));
    while (cur != null) {
        if (cur == ancestor) {
            gst_object_unref(cur);
            return 1;
        }
        const up = gst_object_get_parent(cur);
        gst_object_unref(cur);
        cur = up;
    }
    return 0;
}

pub export fn gst_object_has_ancestor(o: [*c]Obj, ancestor: [*c]Obj) c.gboolean {
    return gst_object_has_as_ancestor(o, ancestor);
}

pub export fn gst_object_check_uniqueness(list: [*c]c.GList, name: [*c]const u8) c.gboolean {
    if (!check.that(name != null, "gst_object_check_uniqueness", "name != NULL")) return 0;
    var l = list;
    while (l != null) : (l = l.*.next) {
        const child = of(l.*.data);
        lock(child);
        const same = std.mem.orderZ(u8, child.name, name) == .eq;
        unlock(child);
        if (same) return 0;
    }
    return 1;
}

fn setProperty(go: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_NAME => _ = rename(of(go), c.g_value_get_string(v)),
        PROP_PARENT => _ = gst_object_set_parent(of(go), @ptrCast(@alignCast(c.g_value_get_object(v)))),
        else => warnBadProperty(go, id, pspec),
    }
}

fn getProperty(go: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_NAME => c.g_value_take_string(v, gst_object_get_name(of(go))),
        PROP_PARENT => c.g_value_take_object(v, gst_object_get_parent(of(go))),
        else => warnBadProperty(go, id, pspec),
    }
}

pub export fn gst_object_get_path_string(o: [*c]Obj) [*c]u8 {
    var chain: [*c]c.GSList = c.g_slist_prepend(null, gst_object_ref(o));
    var cur: c.gpointer = o;
    while (isObject(cur)) {
        const up = gst_object_get_parent(of(cur));
        if (up == null) break;
        chain = c.g_slist_prepend(chain, up);
        cur = up;
    }
    var path: [*c]u8 = c.g_strdup("");
    var it = chain;
    while (it != null) : (it = it.*.next) {
        const item = it.*.data;
        const type_name: [*c]const u8 = if (gtype.instanceOf(item, 20 << c.G_TYPE_FUNDAMENTAL_SHIFT)) c.g_type_name(gtype.typeOf(item)) else null;
        var part: [*c]u8 = undefined;
        var sep: [*c]const u8 = "/";
        if (isObject(item)) {
            const name = gst_object_get_name(of(item));
            part = c.g_strdup_printf("%s:%s", type_name, name);
            sep = gtype.classPeek(c.GstObjectClass, item).path_string_separator;
            gst_object_unref(item);
            c.g_free(name);
        } else if (type_name != null) {
            part = c.g_strdup_printf("%s:%p", type_name, item);
        } else part = c.g_strdup_printf("%p", item);
        const joined = c.g_strjoin(sep, path, part, @as(?*anyopaque, null));
        c.g_free(path);
        c.g_free(part);
        path = joined;
    }
    c.g_slist_free(chain);
    return path;
}

pub export fn gst_object_default_deep_notify(go: [*c]c.GObject, orig: [*c]Obj, pspec: [*c]c.GParamSpec, excluded: [*c][*c]u8) void {
    _ = go;
    if (pspec.*.flags & c.G_PARAM_READABLE == 0) {
        const path = gst_object_get_path_string(orig);
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Parameter %s not readable in %s.", pspec.*.name, path);
        c.g_free(path);
        return;
    }
    var e = excluded;
    while (e != null and e.* != null) : (e += 1) {
        if (std.mem.orderZ(u8, pspec.*.name, e.*) == .eq) return;
    }
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, pspec.*.value_type);
    c.g_object_get_property(@ptrCast(orig), pspec.*.name, &v);
    const text = if (c.g_type_check_value_holds(&v, G_TYPE_STRING) != 0) c.g_value_dup_string(&v) else @import("value.zig").gst_value_serialize(&v);
    const path = gst_object_get_path_string(orig);
    c.g_print("%s: %s = %s\n", path, pspec.*.name, text);
    c.g_free(path);
    c.g_free(text);
    c.g_value_unset(&v);
}
