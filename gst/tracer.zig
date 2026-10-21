const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const object = @import("object.zig");
const core = @import("core.zig");
const util = @import("util.zig");
const va = @import("varargs.zig");
const feature = @import("pluginfeature.zig");
const plugin = @import("plugin.zig");
const registry = @import("registry.zig");
const regcache = @import("regcache.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Tracer = c.GstTracer;
const TracerClass = c.GstTracerClass;

pub const Factory = extern struct {
    feature: feature.Feature,
    type: c.GType,
    reserved: [4]c.gpointer,

    pub const Header = c.struct__GstTracerFactory;
};

const FactoryClass = extern struct {
    parent: feature.FeatureClass,
    reserved: [4]c.gpointer,
};

pub const Record = extern struct {
    parent: c.GstObject,
    spec: [*c]c.GstStructure,
    format: [*c]u8,

    pub const Header = c.struct__GstTracerRecord;
};

const RecordClass = extern struct {
    parent_class: c.GstObjectClass,
};

const TracerPrivate = extern struct {
    params: [*c]u8,
};

const ClassPrivate = extern struct {
    use_structure_params: c.gboolean,
};

const Hook = extern struct {
    tracer: [*c]Tracer,
    func: c.GCallback,
};

pub const Id = enum(usize) {
    pad_push_pre,
    pad_push_post,
    pad_push_list_pre,
    pad_push_list_post,
    pad_pull_range_pre,
    pad_pull_range_post,
    pad_push_event_pre,
    pad_push_event_post,
    pad_query_pre,
    pad_query_post,
    element_post_message_pre,
    element_post_message_post,
    element_query_pre,
    element_query_post,
    element_new,
    element_add_pad,
    element_remove_pad,
    bin_add_pre,
    bin_add_post,
    bin_remove_pre,
    bin_remove_post,
    pad_link_pre,
    pad_link_post,
    pad_unlink_pre,
    pad_unlink_post,
    element_change_state_pre,
    element_change_state_post,
    mini_object_created,
    mini_object_destroyed,
    object_created,
    object_destroyed,
    mini_object_reffed,
    mini_object_unreffed,
    object_reffed,
    object_unreffed,
    plugin_feature_loaded,
    pad_chain_pre,
    pad_chain_post,
    pad_chain_list_pre,
    pad_chain_list_post,
    pad_send_event_pre,
    pad_send_event_post,
    memory_init,
    memory_free_pre,
    memory_free_post,
    pool_buffer_queued,
    pool_buffer_dequeued,
    none,
};

const names = [_][*:0]const u8{
    "pad-push-pre",             "pad-push-post",             "pad-push-list-pre",     "pad-push-list-post",
    "pad-pull-range-pre",       "pad-pull-range-post",       "pad-push-event-pre",    "pad-push-event-post",
    "pad-query-pre",            "pad-query-post",            "element-post-message-pre", "element-post-message-post",
    "element-query-pre",        "element-query-post",        "element-new",           "element-add-pad",
    "element-remove-pad",       "bin-add-pre",               "bin-add-post",          "bin-remove-pre",
    "bin-remove-post",          "pad-link-pre",              "pad-link-post",         "pad-unlink-pre",
    "pad-unlink-post",          "element-change-state-pre",  "element-change-state-post", "mini-object-created",
    "mini-object-destroyed",    "object-created",            "object-destroyed",      "mini-object-reffed",
    "mini-object-unreffed",     "object-reffed",             "object-unreffed",       "plugin-feature-loaded",
    "pad-chain-pre",            "pad-chain-post",            "pad-chain-list-pre",    "pad-chain-list-post",
    "pad-send-event-pre",       "pad-send-event-post",       "memory-init",           "memory-free-pre",
    "memory-free-post",         "pool-buffer-queued",        "pool-buffer-dequeued",  "none",
};

comptime {
    std.debug.assert(names.len == @typeInfo(Id).@"enum".fields.len);
}

pub var quarks: [names.len]c.GQuark = .{0} ** names.len;
pub var enabled = false;
var tracers: ?*c.GHashTable = null;

const PROP_PARAMS = 1;

var tracer_once: gtype.Once = .{};
var tracer_offset: c.gint = 0;
var tracer_parent: ?*c.GObjectClass = null;
var factory_once: gtype.Once = .{};
var record_once: gtype.Once = .{};
var record_parent: ?*c.GObjectClass = null;
var debug_cat: [*c]c.GstDebugCategory = null;

fn hooksFor(key: c.GQuark) ?*c.GList {
    return @ptrCast(@alignCast(c.g_hash_table_lookup(tracers, @ptrFromInt(key))));
}

pub inline fn emit(comptime id: Id, args: anytype) void {
    if (!enabled) return;
    fire(id, args);
}

fn fire(comptime id: Id, args: anytype) void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const F = switch (fields.len) {
        1 => *const fn ([*c]Tracer, c.GstClockTime, fields[0].type) callconv(.c) void,
        2 => *const fn ([*c]Tracer, c.GstClockTime, fields[0].type, fields[1].type) callconv(.c) void,
        3 => *const fn ([*c]Tracer, c.GstClockTime, fields[0].type, fields[1].type, fields[2].type) callconv(.c) void,
        else => @compileError("unsupported hook arity"),
    };
    const ts: c.GstClockTime = @bitCast(@as(i64, @bitCast(util.gst_util_get_timestamp())) -% @as(i64, @bitCast(core.start_time)));
    for ([_]c.GQuark{ quarks[@intFromEnum(id)], 0 }) |key| {
        var l = hooksFor(key);
        while (l) |n| : (l = n.next) {
            const h: *Hook = @ptrCast(@alignCast(n.data));
            const f: F = @ptrCast(h.func);
            @call(.auto, f, .{ h.tracer, ts } ++ args);
        }
    }
}

pub export fn gst_tracer_get_type() c.GType {
    return tracer_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type, "GstTracer", TracerClass, Tracer, tracerClassInit, tracerInit, c.G_TYPE_FLAG_ABSTRACT);
            tracer_offset = c.g_type_add_instance_private(t, @sizeOf(TracerPrivate));
            c.g_type_add_class_private(t, @sizeOf(ClassPrivate));
            return t;
        }
    }.f);
}

fn tracerClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &tracer_offset);
    tracer_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    gc.dispose = tracerDispose;
    c.g_object_class_install_property(gc, PROP_PARAMS, c.g_param_spec_string("params", "Params", "Extra configuration parameters", null, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS));
}

fn tpriv(t: anytype) *TracerPrivate {
    return @ptrCast(@alignCast(@as([*c]Tracer, @ptrCast(@alignCast(t)))[0].priv));
}

fn tracerInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const t: [*c]Tracer = @ptrCast(@alignCast(instance));
    const base: [*]u8 = @ptrCast(instance);
    t[0].priv = @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, tracer_offset)))));
}

fn tracerDispose(o: [*c]c.GObject) callconv(.c) void {
    c.g_free(tpriv(o).params);
    tracer_parent.?.dispose.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_PARAMS => {
            c.g_free(tpriv(o).params);
            tpriv(o).params = c.g_value_dup_string(v);
        },
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_PARAMS => c.g_value_set_string(v, tpriv(o).params),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn isTracerClass(k: anytype) bool {
    return k != null and c.g_type_check_class_is_a(@ptrCast(@alignCast(k)), gst_tracer_get_type()) != 0;
}

fn classPriv(k: [*c]TracerClass) *ClassPrivate {
    return @ptrCast(@alignCast(c.g_type_class_get_private(@ptrCast(@alignCast(k)), gst_tracer_get_type())));
}

pub export fn gst_tracer_class_uses_structure_params(k: [*c]TracerClass) c.gboolean {
    if (!check.that(isTracerClass(k), "gst_tracer_class_uses_structure_params", "GST_IS_TRACER_CLASS (tracer_class)")) return 0;
    return classPriv(k).use_structure_params;
}

pub export fn gst_tracer_class_set_use_structure_params(k: [*c]TracerClass, v: c.gboolean) void {
    if (!check.that(isTracerClass(k), "gst_tracer_class_set_use_structure_params", "GST_IS_TRACER_CLASS (tracer_class)")) return;
    classPriv(k).use_structure_params = v;
}

fn fof(p: anytype) [*c]Factory {
    return @ptrCast(@alignCast(p));
}

pub export fn gst_tracer_factory_get_type() c.GType {
    return factory_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(feature.gst_plugin_feature_get_type, "GstTracerFactory", FactoryClass, Factory, null, null, 0);
            debug_cat = info._gst_debug_category_new("GST_TRACER", c.GST_DEBUG_FG_BLUE, "tracing subsystem");
            return t;
        }
    }.f);
}

pub export fn gst_tracer_register(p: [*c]plugin.Plugin, name: [*c]const u8, t: c.GType) c.gboolean {
    if (!check.that(name != null, "gst_tracer_register", "name != NULL")) return 0;
    if (!check.that(c.g_type_is_a(t, gst_tracer_get_type()) != 0, "gst_tracer_register", "g_type_is_a (type, GST_TYPE_TRACER)")) return 0;
    const reg = registry.gst_registry_get();
    const existing = registry.gst_registry_lookup_feature(reg, name);
    if (existing != null) {
        fof(existing)[0].type = t;
        existing[0].loaded = 1;
        c.gst_object_unref(existing);
        return 1;
    }
    const f = fof(c.g_object_new(gst_tracer_factory_get_type(), @as([*c]const u8, null)));
    _ = c.gst_object_set_name(@ptrCast(f), name);
    feature.gst_plugin_feature_set_rank(@ptrCast(f), c.GST_RANK_NONE);
    f[0].type = t;
    feature.bindPlugin(@ptrCast(f), p);
    f[0].feature.loaded = 1;
    _ = registry.gst_registry_add_feature(reg, @ptrCast(f));
    return 1;
}

pub export fn gst_tracer_factory_get_list() ?*c.GList {
    return registry.gst_registry_get_feature_list(registry.gst_registry_get(), gst_tracer_factory_get_type());
}

pub export fn gst_tracer_factory_get_tracer_type(f: [*c]Factory) c.GType {
    if (!check.that(gtype.instanceOf(f, gst_tracer_factory_get_type()), "gst_tracer_factory_get_tracer_type", "GST_IS_TRACER_FACTORY (factory)")) return 0;
    return f[0].type;
}

pub export fn gst_tracer_record_get_type() c.GType {
    return record_once.get(struct {
        fn f() c.GType {
            return gtype.object(object.gst_object_get_type, "GstTracerRecord", RecordClass, Record, recordClassInit, null, 0);
        }
    }.f);
}

fn recordClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    record_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(klass))).dispose = recordDispose;
}

fn recordDispose(o: [*c]c.GObject) callconv(.c) void {
    const r: [*c]Record = @ptrCast(@alignCast(o));
    if (r[0].spec != null) {
        c.gst_structure_free(r[0].spec);
        r[0].spec = null;
    }
    c.g_free(r[0].format);
    r[0].format = null;
    record_parent.?.dispose.?(o);
}

fn conversion(t: c.GType) []const u8 {
    const fund = c.g_type_fundamental(t);
    if (t == c.G_TYPE_INT or t == c.G_TYPE_BOOLEAN) return "%i";
    if (t == c.G_TYPE_UINT) return "%u";
    if (t == c.G_TYPE_FLOAT) return "%f";
    if (t == c.G_TYPE_DOUBLE) return "%lf";
    if (t == c.G_TYPE_STRING or t == c.g_gtype_get_type()) return "%s";
    if (t == c.G_TYPE_INT64) return "%" ++ "li";
    if (t == c.G_TYPE_UINT64) return "%" ++ "lu";
    if (t == c.gst_structure_get_type()) return "%p\x07a";
    if (fund == c.G_TYPE_ENUM or fund == c.G_TYPE_FLAGS) return "%i";
    if (t == c.G_TYPE_POINTER) return "%p";
    return "%p\x07a";
}

fn appendTemplate(s: *c.GString, field: [*c]const u8, t: c.GType) void {
    _ = c.g_string_append_len(s, ", ", 2);
    _ = c.g_string_append(s, field);
    _ = c.g_string_append_len(s, "=(", 2);
    _ = c.g_string_append(s, @import("value.zig").abbrOf(t));
    _ = c.g_string_append_c(s, ')');
    const conv = conversion(t);
    _ = c.g_string_append_len(s, conv.ptr, @intCast(conv.len));
}

fn templateField(field: [*c]const c.GstIdStr, v: [*c]const c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const s: *c.GString = @ptrCast(@alignCast(data));
    if (v[0].g_type != c.gst_structure_get_type()) return 0;
    const sub = c.gst_value_get_structure(v);
    var t: c.GType = 0;
    var flags: c.GstTracerValueFlags = c.GST_TRACER_VALUE_FLAGS_NONE;
    _ = c.gst_structure_get(sub, "type", c.g_gtype_get_type(), &t, "flags", c.gst_tracer_value_flags_get_type(), &flags, @as([*c]const u8, null));
    const name = c.gst_id_str_as_str(field);
    if (flags & c.GST_TRACER_VALUE_FLAGS_OPTIONAL != 0) {
        const opt = c.g_strconcat("have-", name, @as([*c]const u8, null));
        appendTemplate(s, opt, c.G_TYPE_BOOLEAN);
        c.g_free(opt);
    }
    appendTemplate(s, name, t);
    return 1;
}

fn buildFormat(r: [*c]Record) void {
    const name = c.gst_structure_get_name(r[0].spec);
    if (!check.that(c.g_str_has_suffix(name, ".class") != 0, "gst_tracer_record_build_format", "g_str_has_suffix (name, \".class\")")) return;
    const base = c.g_strndup(name, c.strlen(name) - 6);
    defer c.g_free(base);
    const s = c.g_string_sized_new(64);
    _ = c.g_string_append(s, base);
    _ = c.gst_structure_foreach_id_str(r[0].spec, templateField, s);
    _ = c.g_string_append_c(s, ';');
    r[0].format = c.g_string_free(s, 0);
}

pub export fn gst_tracer_record_new(name: [*c]const u8, first: [*c]const u8, ...) callconv(.c) [*c]Record {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const s = c.gst_structure_new_empty(name);
    var field = first;
    while (field != null) {
        const t = @cVaArg(&ap, c.GType);
        if (t != c.gst_structure_get_type()) {
            c.gst_structure_free(s);
            return null;
        }
        var v = std.mem.zeroes(c.GValue);
        const err = va.collect(&v, t, &ap);
        if (err != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "%s", err);
            c.g_free(err);
            break;
        }
        c.gst_structure_take_value(s, field, &v);
        field = @cVaArg(&ap, [*c]const u8);
    }
    const r: [*c]Record = @ptrCast(@alignCast(c.g_object_new(gst_tracer_record_get_type(), @as([*c]const u8, null))));
    _ = object.gst_object_ref_sink(r);
    r[0].spec = s;
    buildFormat(r);
    return r;
}

pub export fn gst_tracer_record_log(r: [*c]Record, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    if (c.GST_LEVEL_TRACE <= info._gst_debug_min)
        info.gst_debug_log_valist(debug_cat, c.GST_LEVEL_TRACE, "", "", 0, null, r[0].format, va.toC(&ap));
}

fn registerHookId(t: [*c]Tracer, detail: c.GQuark, func: c.GCallback) void {
    const key: c.gpointer = @ptrFromInt(detail);
    var list: ?*c.GList = @ptrCast(@alignCast(c.g_hash_table_lookup(tracers, key)));
    const h: *Hook = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Hook))));
    h.tracer = @ptrCast(@alignCast(c.gst_object_ref(t)));
    h.func = func;
    list = c.g_list_prepend(list, h);
    _ = c.g_hash_table_replace(tracers, key, list);
    enabled = true;
}

pub export fn gst_tracing_register_hook(t: [*c]Tracer, detail: [*c]const u8, func: c.GCallback) void {
    registerHookId(t, c.g_quark_try_string(detail), func);
}

pub export fn gst_tracing_get_active_tracers() ?*c.GList {
    if (!enabled or tracers == null) return null;
    var out: ?*c.GList = null;
    const values = c.g_hash_table_get_values(tracers);
    var l: ?*c.GList = values;
    while (l) |n| : (l = n.next) {
        var t: ?*c.GList = @ptrCast(@alignCast(n.data));
        while (t) |m| : (t = m.next) {
            const h: *Hook = @ptrCast(@alignCast(m.data));
            if (c.g_list_index(out, h.tracer) >= 0) continue;
            out = c.g_list_prepend(out, c.gst_object_ref(h.tracer));
        }
    }
    c.g_list_free(values);
    return out;
}

fn propertyList(k: *c.GObjectClass) [*c]u8 {
    var n: c.guint = 0;
    const props = c.g_object_class_list_properties(k, &n);
    defer c.g_free(@ptrCast(props));
    const s = c.g_string_new(null);
    if (n == 0) {
        _ = c.g_string_append(s, "No properties available");
        return c.g_string_free(s, 0);
    }
    _ = c.g_string_append(s, "Available properties:");
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const p = props[i];
        if (p[0].flags & (c.G_PARAM_CONSTRUCT | c.G_PARAM_CONSTRUCT_ONLY) == 0 or p[0].flags & c.G_PARAM_WRITABLE == 0) continue;
        const pname = c.g_param_spec_get_name(p);
        if (c.g_strcmp0(pname, "parent") == 0 or c.g_strcmp0(pname, "params") == 0) continue;
        var def = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&def, p[0].value_type);
        c.g_param_value_set_default(p, &def);
        const ds = c.g_strdup_value_contents(&def);
        const blurb = c.g_param_spec_get_blurb(p);
        c.g_string_append_printf(s, "\n  '%s' (%s) (Default: %s): %s", pname, c.g_type_name(@as(*c.GTypeInstance, @ptrCast(p)).g_class.*.g_type), ds, if (blurb != null) blurb else @as([*c]const u8, "(no description available)"));
        c.g_free(ds);
        c.g_value_unset(&def);
    }
    return c.g_string_free(s, 0);
}

fn createTracer(f: [*c]Factory, name: [*c]const u8, params: [*c]const u8) void {
    const k: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(f[0].type)));
    defer c.g_type_class_unref(k);
    var names_arr: [*c][*c]const u8 = null;
    var values: [*c]c.GValue = null;
    var n: c.gint = 1;
    var st: [*c]c.GstStructure = null;
    var avail: [*c]u8 = null;
    var t: [*c]Tracer = null;
    build: {
        if (gst_tracer_class_uses_structure_params(@ptrCast(k)) != 0) {
            if (params == null) {
                n = 0;
                t = @ptrCast(@alignCast(c.g_object_new_with_properties(f[0].type, 0, null, null)));
                break :build;
            }
            const full = c.g_strdup_printf("%s,%s", name, params);
            st = c.gst_structure_from_string(full, null);
            c.g_free(full);
            if (st == null) {
                avail = propertyList(k);
                c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Can't instantiate `%s` tracer: invalid parameters '%s'\n  %s\n", name, params, avail);
                break :build;
            }
            n = c.gst_structure_n_fields(st);
            names_arr = @ptrCast(@alignCast(c.g_malloc0(@as(usize, @intCast(n)) * @sizeOf([*c]const u8))));
            values = @ptrCast(@alignCast(c.g_malloc0(@as(usize, @intCast(n)) * @sizeOf(c.GValue))));
            var i: c.gint = 0;
            while (i < n) : (i += 1) {
                const fname = c.gst_structure_nth_field_name(st, @intCast(i));
                const fv = c.gst_structure_get_value(st, fname);
                const pspec = c.g_object_class_find_property(k, fname);
                const idx: usize = @intCast(i);
                if (pspec == null) {
                    avail = propertyList(k);
                    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Can't instantiate `%s` tracer: property '%s' not found\n  %s\n", name, fname, avail);
                    break :build;
                }
                if (fv[0].g_type == pspec[0].value_type) {
                    names_arr[idx] = fname;
                    _ = c.g_value_init(&values[idx], fv[0].g_type);
                    c.g_value_copy(fv, &values[idx]);
                } else if (fv[0].g_type == c.G_TYPE_STRING) {
                    names_arr[idx] = fname;
                    _ = c.g_value_init(&values[idx], pspec[0].value_type);
                    if (c.gst_value_deserialize_with_pspec(&values[idx], c.g_value_get_string(fv), pspec) == 0) {
                        avail = propertyList(k);
                        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Can't instantiate `%s` tracer: invalid property '%s' value: '%s'\n  %s\n", name, fname, c.g_value_get_string(fv), avail);
                        break :build;
                    }
                } else {
                    avail = propertyList(k);
                    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Can't instantiate `%s` tracer: property '%s' type mismatch, expected %s, got %s\n  %s\n", name, fname, c.g_type_name(pspec[0].value_type), c.g_type_name(fv[0].g_type), avail);
                    break :build;
                }
            }
        } else {
            names_arr = @ptrCast(@alignCast(c.g_malloc0(@sizeOf([*c]const u8))));
            names_arr[0] = "params";
            values = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GValue))));
            _ = c.g_value_init(&values[0], c.G_TYPE_STRING);
            c.g_value_set_string(&values[0], params);
        }
        t = @ptrCast(@alignCast(c.g_object_new_with_properties(f[0].type, @intCast(n), names_arr, values)));
    }
    c.g_free(avail);
    if (st != null) c.gst_structure_free(st);
    if (values != null) {
        var j: usize = 0;
        while (j < @as(usize, @intCast(n))) : (j += 1) if (values[j].g_type != 0) c.g_value_unset(&values[j]);
    }
    c.g_free(@ptrCast(names_arr));
    c.g_free(values);
    if (t == null) return;
    _ = object.gst_object_ref_sink(t);
    if (!registered(t)) gst_tracing_register_hook(t, "none", null);
    c.gst_object_unref(t);
}

fn registered(t: [*c]Tracer) bool {
    if (tracers == null) return false;
    const values = c.g_hash_table_get_values(tracers);
    defer c.g_list_free(values);
    var l: ?*c.GList = values;
    while (l) |n| : (l = n.next) {
        var h: ?*c.GList = @ptrCast(@alignCast(n.data));
        while (h) |m| : (h = m.next) if (@as(*Hook, @ptrCast(@alignCast(m.data))).tracer == t) return true;
    }
    return false;
}

pub fn initialize() void {
    tracers = c.g_hash_table_new(null, null);
    for (names, 0..) |n, i| quarks[i] = c.g_quark_from_static_string(n);
    const env = c.g_getenv("GST_TRACERS") orelse return;
    if (env[0] == 0) return;
    const reg = registry.gst_registry_get();
    const parts = c.g_strsplit_set(env, ";", 0);
    defer c.g_strfreev(parts);
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) {
        const item = parts[i];
        var params: [*c]u8 = c.strchr(item, '(');
        if (params != null) {
            var depth: c.guint = 1;
            var end: [*c]u8 = null;
            var j: usize = 1;
            while (params[j] != 0) : (j += 1) {
                if (params[j] == '(') depth += 1 else if (params[j] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        end = params + j;
                        break;
                    }
                }
            }
            params[0] = 0;
            params += 1;
            if (end != null) end[0] = 0;
        }
        const f = registry.gst_registry_lookup_feature(reg, item);
        if (f != null) {
            const loaded = fof(feature.gst_plugin_feature_load(f));
            if (loaded != null) {
                createTracer(loaded, item, params);
                c.gst_object_unref(loaded);
            } else c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "loading plugin containing feature %s failed!", item);
            c.gst_object_unref(f);
        } else if (item[0] != 0) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "no tracer named '%s'", item);
    }
}

pub fn deinit() void {
    enabled = false;
    if (tracers == null) return;
    const values = c.g_hash_table_get_values(tracers);
    var l: ?*c.GList = values;
    while (l) |n| : (l = n.next) {
        var t: ?*c.GList = @ptrCast(@alignCast(n.data));
        while (t) |m| : (t = m.next) {
            const h: *Hook = @ptrCast(@alignCast(m.data));
            c.gst_object_unref(h.tracer);
            c.g_free(h);
        }
        c.g_list_free(@ptrCast(@alignCast(n.data)));
    }
    c.g_list_free(values);
    c.g_hash_table_destroy(tracers);
    tracers = null;
}

fn save(_: *regcache.Writer, _: [*c]feature.Feature) void {}

fn load(_: *regcache.Reader) regcache.Error![*c]feature.Feature {
    return @ptrCast(@alignCast(c.g_object_new(gst_tracer_factory_get_type(), @as([*c]const u8, null))));
}

pub const kind = regcache.Kind{ .name = "GstTracerFactory", .get_type = gst_tracer_factory_get_type, .save = save, .load = load };
