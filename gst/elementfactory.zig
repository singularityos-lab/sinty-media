const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const core = @import("core.zig");
const va = @import("varargs.zig");
const element = @import("element.zig");
const feature = @import("pluginfeature.zig");
const plugin = @import("plugin.zig");
const registry = @import("registry.zig");
const urihandler = @import("urihandler.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub const Factory = extern struct {
    parent: feature.Feature,
    type: c.GType,
    metadata: c.gpointer,
    staticpadtemplates: ?*c.GList,
    numpadtemplates: c.guint,
    uri_type: c.GstURIType,
    uri_protocols: [*c][*c]u8,
    interfaces: ?*c.GList,
    reserved: [4]c.gpointer,

    pub const Header = c.struct__GstElementFactory;
};

const FactoryClass = extern struct {
    parent_class: feature.FeatureClass,
    reserved: [4]c.gpointer,
};

const Element = c.GstElement;
const Caps = c.GstCaps;
const Templ = c.GstStaticPadTemplate;

var type_once: gtype.Once = .{};
var parent_class: ?*c.GObjectClass = null;
var debug_cat: [*c]c.GstDebugCategory = null;

pub fn of(p: anytype) [*c]Factory {
    return @ptrCast(@alignCast(p));
}

pub fn isFactory(p: anytype) bool {
    return gtype.instanceOf(p, gst_element_factory_get_type());
}

pub export fn gst_element_factory_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(feature.gst_plugin_feature_get_type(), "GstElementFactory", FactoryClass, Factory, classInit, instanceInit, 0);
            debug_cat = info._gst_debug_category_new("GST_ELEMENT_FACTORY", c.GST_DEBUG_BOLD | c.GST_DEBUG_FG_WHITE | c.GST_DEBUG_BG_RED, "element factories keep information about installed elements");
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(klass))).finalize = finalize;
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    of(instance)[0].uri_type = c.GST_URI_UNKNOWN;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    cleanup(of(o));
    parent_class.?.finalize.?(o);
}

pub fn cleanup(f: [*c]Factory) void {
    if (f[0].metadata != null) {
        c.gst_structure_free(@ptrCast(@alignCast(f[0].metadata)));
        f[0].metadata = null;
    }
    f[0].type = 0;
    var l = f[0].staticpadtemplates;
    while (l) |n| : (l = n.next) {
        const t: [*c]Templ = @ptrCast(@alignCast(n.data));
        c.gst_static_caps_cleanup(&t[0].static_caps);
        c.g_free(t);
    }
    c.g_list_free(f[0].staticpadtemplates);
    f[0].staticpadtemplates = null;
    f[0].numpadtemplates = 0;
    f[0].uri_type = c.GST_URI_UNKNOWN;
    c.g_strfreev(f[0].uri_protocols);
    f[0].uri_protocols = null;
    c.g_list_free(f[0].interfaces);
    f[0].interfaces = null;
}

pub export fn gst_element_factory_find(name: [*c]const u8) [*c]Factory {
    if (!check.that(name != null, "gst_element_factory_find", "name != NULL")) return null;
    return of(registry.gst_registry_find_feature(registry.gst_registry_get(), name, gst_element_factory_get_type()));
}

fn metaOk(k: *c.GstElementClass, name: [*c]const u8, key: [*c]const u8) bool {
    const v = element.gst_element_class_get_metadata(k, key);
    if (v != null and v[0] != 0) return true;
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Element factory metadata for '%s' has no valid %s field", name, key);
    return false;
}

pub fn addInterface(f: [*c]Factory, name: [*c]const u8) void {
    f[0].interfaces = c.g_list_prepend(f[0].interfaces, @constCast(c.g_intern_string(name)));
}

pub export fn gst_element_register(p: [*c]plugin.Plugin, name: [*c]const u8, rank: c.guint, t: c.GType) c.gboolean {
    if (!check.that(name != null, "gst_element_register", "name != NULL")) return 0;
    if (!check.that(c.g_type_is_a(t, element.gst_element_get_type()) != 0, "gst_element_register", "g_type_is_a (type, GST_TYPE_ELEMENT)")) return 0;
    const reg = registry.gst_registry_get();
    const existing = registry.gst_registry_lookup_feature(reg, name);
    if (existing != null) {
        defer c.gst_object_unref(existing);
        if (existing[0].plugin == p) {
            const ef = of(existing);
            ef[0].type = t;
            existing[0].loaded = 1;
            c.g_type_set_qdata(t, element.__gst_elementclass_factory, ef);
            return 1;
        }
    }
    const f = of(c.g_object_new(gst_element_factory_get_type(), @as([*c]const u8, null)));
    _ = c.gst_object_set_name(@ptrCast(f), name);
    c.g_type_set_qdata(t, element.__gst_elementclass_factory, f);
    const k: *c.GstElementClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
    if (!metaOk(k, name, c.GST_ELEMENT_METADATA_LONGNAME) or !metaOk(k, name, c.GST_ELEMENT_METADATA_KLASS) or !metaOk(k, name, c.GST_ELEMENT_METADATA_DESCRIPTION) or !metaOk(k, name, c.GST_ELEMENT_METADATA_AUTHOR)) {
        cleanup(f);
        return 0;
    }
    f[0].type = t;
    f[0].metadata = c.gst_structure_copy(@ptrCast(@alignCast(k.metadata)));
    var l: ?*c.GList = k.padtemplates;
    while (l) |n| : (l = n.next) {
        const pt: [*c]c.GstPadTemplate = @ptrCast(@alignCast(n.data));
        const caps = c.gst_caps_to_string(pt[0].caps);
        const nt: *Templ = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Templ))));
        nt.name_template = c.g_intern_string(pt[0].name_template);
        nt.direction = pt[0].direction;
        nt.presence = pt[0].presence;
        nt.static_caps = .{ .caps = null, .string = c.g_intern_string(caps), ._gst_reserved = .{null} ** 4 };
        f[0].staticpadtemplates = c.g_list_append(f[0].staticpadtemplates, nt);
        c.g_free(caps);
    }
    f[0].numpadtemplates = @intCast(k.numpadtemplates);
    if (c.g_type_is_a(t, urihandler.gst_uri_handler_get_type()) != 0) {
        const iface: ?*c.GstURIHandlerInterface = @ptrCast(@alignCast(c.g_type_interface_peek(k, urihandler.gst_uri_handler_get_type())));
        if (iface == null or iface.?.get_type == null or iface.?.get_protocols == null) {
            cleanup(f);
            return 0;
        }
        f[0].uri_type = iface.?.get_type.?(t);
        if (f[0].uri_type != c.GST_URI_SRC and f[0].uri_type != c.GST_URI_SINK) {
            cleanup(f);
            return 0;
        }
        f[0].uri_protocols = c.g_strdupv(@ptrCast(@constCast(iface.?.get_protocols.?(t))));
        if (f[0].uri_protocols == null) {
            cleanup(f);
            return 0;
        }
    }
    var n_ifaces: c.guint = 0;
    const ifaces = c.g_type_interfaces(t, &n_ifaces);
    var i: c.guint = 0;
    while (i < n_ifaces) : (i += 1) addInterface(f, c.g_type_name(ifaces[i]));
    c.g_free(ifaces);
    feature.bindPlugin(@ptrCast(f), p);
    feature.gst_plugin_feature_set_rank(@ptrCast(f), rank);
    f[0].parent.loaded = 1;
    _ = registry.gst_registry_add_feature(reg, @ptrCast(f));
    return 1;
}

pub export fn gst_element_type_set_skip_documentation(t: c.GType) void {
    if (!check.that(c.g_type_is_a(t, element.gst_element_get_type()) != 0, "gst_element_type_set_skip_documentation", "g_type_is_a (type, GST_TYPE_ELEMENT)")) return;
    c.g_type_set_qdata(t, element.__gst_elementclass_skip_doc, @ptrFromInt(1));
}

pub export fn gst_element_factory_get_skip_documentation(f: [*c]Factory) c.gboolean {
    if (!check.that(isFactory(f), "gst_element_factory_get_skip_documentation", "GST_IS_ELEMENT_FACTORY (factory)")) return 1;
    return @intFromBool(c.g_type_get_qdata(f[0].type, element.__gst_elementclass_skip_doc) != null);
}

fn loaded(f: [*c]Factory) [*c]Factory {
    return of(feature.gst_plugin_feature_load(@ptrCast(f)));
}

pub export fn gst_element_factory_create_with_properties(f_in: [*c]Factory, n: c.guint, names: [*c][*c]const u8, values: [*c]const c.GValue) [*c]Element {
    if (!check.that(f_in != null, "gst_element_factory_create_with_properties", "factory != NULL")) return null;
    const f = loaded(f_in);
    if (f == null) return null;
    if (f[0].type == 0) {
        c.gst_object_unref(f);
        return null;
    }
    const e: [*c]Element = @ptrCast(@alignCast(c.g_object_new_with_properties(f[0].type, n, names, values)));
    if (e == null) {
        c.gst_object_unref(f);
        _ = check.that(false, "gst_element_factory_create_with_properties", "element != NULL");
        return null;
    }
    const k = element.classOf(e);
    if (@cmpxchgStrong(?*c.GstElementFactory, &k.elementfactory, null, @ptrCast(f), .seq_cst, .seq_cst) != null)
        c.gst_object_unref(f)
    else
        @as(*c.GstObject, @ptrCast(@alignCast(f))).flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
    if (c.g_object_is_floating(e) == 0) c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "The created element should be floating, this is probably caused by faulty bindings");
    return e;
}

fn collectProps(first: [*c]const u8, ap: *va.VaList, t: c.GType, n: *c.guint, names: *[*c][*c]const u8, values: *[*c]c.GValue) callconv(.c) c.gboolean {
    if (first == null) return 0;
    if (!check.that(c.g_type_fundamental(t) == c.G_TYPE_OBJECT, "gst_element_factory_property_valist_to_array", "G_TYPE_IS_OBJECT (object_type)")) return 0;
    const klass: ?*c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
    if (klass == null) return 0;
    defer c.g_type_class_unref(klass);
    var cap: usize = 16;
    var nm: [*c][*c]const u8 = @ptrCast(@alignCast(c.g_malloc0(cap * @sizeOf([*c]const u8))));
    var vals: [*c]c.GValue = @ptrCast(@alignCast(c.g_malloc0(cap * @sizeOf(c.GValue))));
    var count: usize = 0;
    var name = first;
    while (name != null) {
        const pspec = c.g_object_class_find_property(klass, name);
        if (pspec == null) {
            c.g_free(@ptrCast(nm));
            c.g_free(vals);
            return 0;
        }
        if (count == cap) {
            cap *= 2;
            nm = @ptrCast(@alignCast(c.g_realloc(@ptrCast(nm), cap * @sizeOf([*c]const u8))));
            vals = @ptrCast(@alignCast(c.g_realloc(vals, cap * @sizeOf(c.GValue))));
            @memset(vals[count..cap], std.mem.zeroes(c.GValue));
        }
        nm[count] = name;
        vals[count] = std.mem.zeroes(c.GValue);
        const err = va.collect(@ptrCast(&vals[count]), pspec[0].value_type, ap);
        if (err != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "%s", err);
            c.g_free(err);
            c.g_free(@ptrCast(nm));
            c.g_free(vals);
            return 0;
        }
        count += 1;
        name = @cVaArg(ap, [*c]const u8);
    }
    n.* = @intCast(count);
    names.* = nm;
    values.* = vals;
    return 1;
}

pub export fn gst_element_factory_create_valist(f_in: [*c]Factory, first: [*c]const u8, ap_c: va.CVaList) [*c]Element {
    if (!check.that(f_in != null, "gst_element_factory_create_valist", "factory != NULL")) return null;
    const f = loaded(f_in);
    if (f == null) return null;
    defer c.gst_object_unref(f);
    if (f[0].type == 0) return null;
    if (first == null) return gst_element_factory_create_with_properties(f, 0, null, null);
    var n: c.guint = 0;
    var names: [*c][*c]const u8 = null;
    var values: [*c]c.GValue = null;
    if (collectProps(first, va.fromC(ap_c), f[0].type, &n, &names, &values) == 0) return null;
    const e = gst_element_factory_create_with_properties(f, n, names, values);
    c.g_free(@ptrCast(names));
    var i = n;
    while (i > 0) {
        i -= 1;
        c.g_value_unset(&values[i]);
    }
    c.g_free(values);
    return e;
}

pub export fn gst_element_factory_create_full(f: [*c]Factory, first: [*c]const u8, ...) callconv(.c) [*c]Element {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return gst_element_factory_create_valist(f, first, va.toC(&ap));
}

pub export fn gst_element_factory_create(f: [*c]Factory, name: [*c]const u8) [*c]Element {
    if (name != null) return gst_element_factory_create_full(f, "name", name, @as([*c]const u8, null));
    return gst_element_factory_create_with_properties(f, 0, null, null);
}

pub export fn gst_element_factory_make_with_properties(name: [*c]const u8, n: c.guint, names: [*c][*c]const u8, values: [*c]const c.GValue) [*c]Element {
    const fname = "gst_element_factory_make_with_properties";
    if (!check.that(name != null, fname, "factoryname != NULL")) return null;
    if (!check.that(core.gst_is_initialized() != 0, fname, "gst_is_initialized ()")) return null;
    const f = gst_element_factory_find(name);
    if (f == null) return null;
    defer c.gst_object_unref(f);
    return gst_element_factory_create_with_properties(f, n, names, values);
}

pub export fn gst_element_factory_make_valist(name: [*c]const u8, first: [*c]const u8, ap: va.CVaList) [*c]Element {
    const fname = "gst_element_factory_make_valist";
    if (!check.that(name != null, fname, "factoryname != NULL")) return null;
    if (!check.that(core.gst_is_initialized() != 0, fname, "gst_is_initialized ()")) return null;
    const f = gst_element_factory_find(name);
    if (f == null) return null;
    defer c.gst_object_unref(f);
    return gst_element_factory_create_valist(f, first, ap);
}

pub export fn gst_element_factory_make_full(name: [*c]const u8, first: [*c]const u8, ...) callconv(.c) [*c]Element {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return gst_element_factory_make_valist(name, first, va.toC(&ap));
}

pub export fn gst_element_factory_make(name: [*c]const u8, element_name: [*c]const u8) [*c]Element {
    if (element_name != null) return gst_element_factory_make_full(name, "name", element_name, @as([*c]const u8, null));
    return gst_element_factory_make_with_properties(name, 0, null, null);
}

pub export fn gst_element_factory_get_element_type(f: [*c]Factory) c.GType {
    if (!check.that(isFactory(f), "gst_element_factory_get_element_type", "GST_IS_ELEMENT_FACTORY (factory)")) return 0;
    return f[0].type;
}

pub export fn gst_element_factory_get_metadata(f: [*c]Factory, key: [*c]const u8) [*c]const u8 {
    if (!check.that(isFactory(f), "gst_element_factory_get_metadata", "GST_IS_ELEMENT_FACTORY (factory)")) return null;
    return c.gst_structure_get_string(@ptrCast(@alignCast(f[0].metadata)), key);
}

pub export fn gst_element_factory_get_metadata_keys(f: [*c]Factory) [*c][*c]u8 {
    if (!check.that(isFactory(f), "gst_element_factory_get_metadata_keys", "GST_IS_ELEMENT_FACTORY (factory)")) return null;
    const md: [*c]c.GstStructure = @ptrCast(@alignCast(f[0].metadata));
    if (md == null) return null;
    const num: c.guint = @intCast(c.gst_structure_n_fields(md));
    if (num == 0) return null;
    const arr: [*c][*c]u8 = @ptrCast(@alignCast(c.g_malloc((num + 1) * @sizeOf([*c]u8))));
    var i: c.guint = 0;
    while (i < num) : (i += 1) arr[i] = c.g_strdup(c.gst_structure_nth_field_name(md, i));
    arr[num] = null;
    return arr;
}

pub export fn gst_element_factory_get_num_pad_templates(f: [*c]Factory) c.guint {
    if (!check.that(isFactory(f), "gst_element_factory_get_num_pad_templates", "GST_IS_ELEMENT_FACTORY (factory)")) return 0;
    return f[0].numpadtemplates;
}

pub export fn gst_element_factory_get_static_pad_templates(f: [*c]Factory) ?*const c.GList {
    if (!check.that(isFactory(f), "gst_element_factory_get_static_pad_templates", "GST_IS_ELEMENT_FACTORY (factory)")) return null;
    return f[0].staticpadtemplates;
}

pub export fn gst_element_factory_get_uri_type(f: [*c]Factory) c.GstURIType {
    if (!check.that(isFactory(f), "gst_element_factory_get_uri_type", "GST_IS_ELEMENT_FACTORY (factory)")) return c.GST_URI_UNKNOWN;
    return f[0].uri_type;
}

pub export fn gst_element_factory_get_uri_protocols(f: [*c]Factory) [*c]const [*c]const u8 {
    if (!check.that(isFactory(f), "gst_element_factory_get_uri_protocols", "GST_IS_ELEMENT_FACTORY (factory)")) return null;
    return @ptrCast(f[0].uri_protocols);
}

pub export fn gst_element_factory_has_interface(f: [*c]Factory, name: [*c]const u8) c.gboolean {
    if (!check.that(isFactory(f), "gst_element_factory_has_interface", "GST_IS_ELEMENT_FACTORY (factory)")) return 0;
    var l = f[0].interfaces;
    while (l) |n| : (l = n.next) if (c.strcmp(@ptrCast(n.data), name) == 0) return 1;
    return 0;
}

fn has(k: [*c]const u8, s: [*c]const u8) bool {
    return c.strstr(k, s) != null;
}

pub export fn gst_element_factory_list_is_type(f: [*c]Factory, t: c.GstElementFactoryListType) c.gboolean {
    const k = gst_element_factory_get_metadata(f, c.GST_ELEMENT_METADATA_KLASS);
    if (k == null) return 0;
    const checks = [_]struct { c.GstElementFactoryListType, [*c]const u8, ?[*c]const u8 }{
        .{ c.GST_ELEMENT_FACTORY_TYPE_SINK, "Sink", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_SRC, "Source", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_DECODER, "Decoder", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_ENCODER, "Encoder", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_MUXER, "Muxer", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_DEMUXER, "Demux", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_PARSER, "Parser", "Codec" },
        .{ c.GST_ELEMENT_FACTORY_TYPE_TIMESTAMPER, "Timestamper", "Codec" },
        .{ c.GST_ELEMENT_FACTORY_TYPE_DEPAYLOADER, "Depayloader", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_PAYLOADER, "Payloader", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_FORMATTER, "Formatter", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_DECRYPTOR, "Decryptor", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_ENCRYPTOR, "Encryptor", null },
        .{ c.GST_ELEMENT_FACTORY_TYPE_HARDWARE, "Hardware", null },
    };
    var res = false;
    for (checks) |ch| {
        if (res) break;
        if (t & ch[0] != 0) res = has(k, ch[1]) and (ch[2] == null or has(k, ch[2].?));
    }
    const media = c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_SUBTITLE | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_METADATA;
    if ((res or t & (c.GST_ELEMENT_FACTORY_TYPE_MAX_ELEMENTS - 1) == 0) and t & media != 0) {
        res = (t & c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO != 0 and has(k, "Audio")) or
            (t & c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO != 0 and has(k, "Video")) or
            (t & c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE != 0 and has(k, "Image")) or
            (t & c.GST_ELEMENT_FACTORY_TYPE_MEDIA_SUBTITLE != 0 and has(k, "Subtitle")) or
            (t & c.GST_ELEMENT_FACTORY_TYPE_MEDIA_METADATA != 0 and has(k, "Metadata"));
    }
    return @intFromBool(res);
}

const Filter = struct { kind: c.GstElementFactoryListType, minrank: c.GstRank };

fn elementFilter(f: ?*c.GstPluginFeature, data: c.gpointer) callconv(.c) c.gboolean {
    if (!isFactory(f)) return 0;
    const d: *Filter = @ptrCast(@alignCast(data));
    return @intFromBool(feature.gst_plugin_feature_get_rank(@ptrCast(@alignCast(f))) >= d.minrank and gst_element_factory_list_is_type(of(f), d.kind) != 0);
}

pub export fn gst_element_factory_list_get_elements(t: c.GstElementFactoryListType, minrank: c.GstRank) ?*c.GList {
    var d = Filter{ .kind = t, .minrank = minrank };
    const l = registry.gst_registry_feature_filter(registry.gst_registry_get(), elementFilter, 0, &d);
    return c.g_list_sort(l, feature.gst_plugin_feature_rank_compare_func);
}

pub export fn gst_element_factory_list_filter(list: ?*c.GList, caps: [*c]const Caps, dir: c.GstPadDirection, subset: c.gboolean) ?*c.GList {
    var out = std.mem.zeroes(c.GQueue);
    var l = list;
    while (l) |n| : (l = n.next) {
        const f = of(n.data);
        var w = f[0].staticpadtemplates;
        while (w) |m| : (w = m.next) {
            const t: [*c]Templ = @ptrCast(@alignCast(m.data));
            if (t[0].direction != dir) continue;
            const tc = c.gst_static_caps_get(&t[0].static_caps);
            const ok = if (subset != 0) c.gst_caps_is_subset(caps, tc) != 0 else c.gst_caps_can_intersect(caps, tc) != 0;
            c.gst_caps_unref(tc);
            if (ok) {
                c.g_queue_push_tail(&out, c.gst_object_ref(f));
                break;
            }
        }
    }
    return out.head;
}

fn accepts(f: [*c]Factory, caps: [*c]const Caps, dir: c.GstPadDirection, comptime all: bool) c.gboolean {
    const fname = if (all) "gst_element_factory_can_accept_all_caps_in_direction" else "gst_element_factory_can_accept_any_caps_in_direction";
    if (!check.that(f != null, fname, "factory != NULL")) return 0;
    if (!check.that(caps != null, fname, "caps != NULL")) return 0;
    var w = f[0].staticpadtemplates;
    while (w) |m| : (w = m.next) {
        const t: [*c]Templ = @ptrCast(@alignCast(m.data));
        if (t[0].direction != dir) continue;
        const tc = c.gst_static_caps_get(&t[0].static_caps);
        const ok = if (all) c.gst_caps_is_always_compatible(caps, tc) != 0 else c.gst_caps_can_intersect(caps, tc) != 0;
        c.gst_caps_unref(tc);
        if (ok) return 1;
    }
    return 0;
}

pub export fn gst_element_factory_can_sink_all_caps(f: [*c]Factory, caps: [*c]const Caps) c.gboolean {
    return accepts(f, caps, c.GST_PAD_SINK, true);
}

pub export fn gst_element_factory_can_src_all_caps(f: [*c]Factory, caps: [*c]const Caps) c.gboolean {
    return accepts(f, caps, c.GST_PAD_SRC, true);
}

pub export fn gst_element_factory_can_sink_any_caps(f: [*c]Factory, caps: [*c]const Caps) c.gboolean {
    return accepts(f, caps, c.GST_PAD_SINK, false);
}

pub export fn gst_element_factory_can_src_any_caps(f: [*c]Factory, caps: [*c]const Caps) c.gboolean {
    return accepts(f, caps, c.GST_PAD_SRC, false);
}
