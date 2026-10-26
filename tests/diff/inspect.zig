const std = @import("std");
const c = @import("c").c;

pub fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

pub fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn base(p: [*c]const u8) []const u8 {
    const s = z(p);
    return if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
}

fn typeChain(t: c.GType) void {
    var x = t;
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    while (x != 0) : (x = c.g_type_parent(x)) {
        const s = std.fmt.bufPrint(buf[n..], "{s} ", .{z(c.g_type_name(x))}) catch break;
        n += s.len;
    }
    out("  chain {s}", .{buf[0..n]});
    var ni: c.guint = 0;
    const ifs = c.g_type_interfaces(t, &ni);
    var i: c.guint = 0;
    while (i < ni) : (i += 1) out("  iface {s}", .{z(c.g_type_name(ifs[i]))});
    c.g_free(ifs);
}

fn valueStr(v: *c.GValue) [*c]u8 {
    if (v.g_type == c.g_value_array_get_type() and c.g_value_get_boxed(v) == null) return c.g_strdup("NULL");
    return c.g_strdup_value_contents(v);
}

fn props(cls: c.gpointer) void {
    var n: c.guint = 0;
    const specs = c.g_object_class_list_properties(@ptrCast(@alignCast(cls)), &n);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const p = specs[i];
        var dv = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&dv, p[0].value_type);
        c.g_param_value_set_default(p, &dv);
        const ds = valueStr(&dv);
        out("  prop {s} {s} owner={s} flags={d} default={s}", .{ z(p[0].name), z(c.g_type_name(p[0].value_type)), z(c.g_type_name(p[0].owner_type)), p[0].flags, z(ds) });
        out("    nick={s} blurb={s}", .{ z(c.g_param_spec_get_nick(p)), z(c.g_param_spec_get_blurb(p)) });
        const pt = @as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class[0].g_type;
        out("    spec {s}", .{z(c.g_type_name(pt))});
        if (std.mem.eql(u8, z(c.g_type_name(pt)), "GParamInt")) {
            const q: *c.GParamSpecInt = @ptrCast(@alignCast(p));
            out("    range {d} {d}", .{ q.minimum, q.maximum });
        }
        if (c.g_type_is_a(p[0].value_type, c.G_TYPE_ENUM) != 0) {
            const ec: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(p[0].value_type)));
            var j: c.guint = 0;
            while (j < ec.n_values) : (j += 1) out("    enum {d} {s} {s}", .{ ec.values[j].value, z(ec.values[j].value_nick), z(ec.values[j].value_name) });
            c.g_type_class_unref(ec);
        }
        if (c.g_type_is_a(p[0].value_type, c.G_TYPE_FLAGS) != 0) {
            const fc: *c.GFlagsClass = @ptrCast(@alignCast(c.g_type_class_ref(p[0].value_type)));
            var j: c.guint = 0;
            while (j < fc.n_values) : (j += 1) out("    flag {d} {s} {s}", .{ fc.values[j].value, z(fc.values[j].value_nick), z(fc.values[j].value_name) });
            c.g_type_class_unref(fc);
        }
        c.g_free(ds);
        c.g_value_unset(&dv);
    }
    c.g_free(@ptrCast(specs));
}

fn signals(t: c.GType) void {
    var x = t;
    while (x != 0 and x != c.gst_element_get_type()) : (x = c.g_type_parent(x)) {
        var n: c.guint = 0;
        const ids = c.g_signal_list_ids(x, &n);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            var q: c.GSignalQuery = undefined;
            c.g_signal_query(ids[i], &q);
            var buf: [512]u8 = undefined;
            var m: usize = 0;
            var j: c.guint = 0;
            while (j < q.n_params) : (j += 1) {
                const s = std.fmt.bufPrint(buf[m..], "{s},", .{z(c.g_type_name(q.param_types[j] & ~@as(c.GType, c.G_SIGNAL_TYPE_STATIC_SCOPE)))}) catch break;
                m += s.len;
            }
            out("  signal {s} on {s} ret={s} flags={d} params={s}", .{ z(q.signal_name), z(c.g_type_name(q.itype)), z(c.g_type_name(q.return_type)), q.signal_flags, buf[0..m] });
        }
        c.g_free(ids);
    }
}

pub fn element(name: [*c]const u8) void {
    const f = c.gst_element_factory_find(name);
    if (f == null) {
        out("factory {s} missing", .{z(name)});
        return;
    }
    defer c.gst_object_unref(f);
    const plugin = c.gst_plugin_feature_get_plugin(@ptrCast(f));
    out("factory {s} rank={d} plugin={s}", .{ z(name), c.gst_plugin_feature_get_rank(@ptrCast(f)), z(c.gst_plugin_feature_get_plugin_name(@ptrCast(f))) });
    if (plugin != null) {
        out("  plugin desc={s} version={s} license={s} source={s} file={s}", .{ z(c.gst_plugin_get_description(plugin)), z(c.gst_plugin_get_version(plugin)), z(c.gst_plugin_get_license(plugin)), z(c.gst_plugin_get_source(plugin)), base(c.gst_plugin_get_filename(plugin)) });
        c.gst_object_unref(plugin);
    }
    const keys = c.gst_element_factory_get_metadata_keys(f);
    if (keys != null) {
        var i: usize = 0;
        while (keys[i] != null) : (i += 1) out("  meta {s} = {s}", .{ z(keys[i]), z(c.gst_element_factory_get_metadata(f, keys[i])) });
        c.g_strfreev(keys);
    }
    var l = c.gst_element_factory_get_static_pad_templates(f);
    while (l != null) : (l = l[0].next) {
        const t: *c.GstStaticPadTemplate = @ptrCast(@alignCast(l[0].data));
        out("  template {s} dir={d} presence={d} caps={s}", .{ z(t.name_template), t.direction, t.presence, z(t.static_caps.string) });
    }
    out("  uri type={d}", .{c.gst_element_factory_get_uri_type(f)});
    const protos = c.gst_element_factory_get_uri_protocols(f);
    if (protos != null) {
        var i: usize = 0;
        while (protos[i] != null) : (i += 1) out("  protocol {s}", .{z(protos[i])});
    }
    const e = c.gst_element_factory_create(f, null);
    if (e == null) {
        out("  create failed", .{});
        return;
    }
    const t = @as(*c.GTypeInstance, @ptrCast(@alignCast(e))).g_class[0].g_type;
    out("  type {s} name={s}", .{ z(c.g_type_name(t)), z(@as(*c.GstObject, @ptrCast(@alignCast(e))).name) });
    typeChain(t);
    props(@as(*c.GTypeInstance, @ptrCast(@alignCast(e))).g_class);
    signals(t);
    var it = c.gst_element_iterate_pads(e);
    var v = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &v) == c.GST_ITERATOR_OK) {
        const p: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&v)));
        const caps = c.gst_pad_query_caps(p, null);
        const cs = c.gst_caps_to_string(caps);
        const pn = c.gst_object_get_name(@ptrCast(@alignCast(p)));
        out("  pad {s} dir={d} caps={s}", .{ z(pn), c.gst_pad_get_direction(p), z(cs) });
        c.g_free(pn);
        c.g_free(cs);
        c.gst_caps_unref(caps);
        _ = c.g_value_reset(&v);
    }
    c.g_value_unset(&v);
    c.gst_iterator_free(it);
    it = null;
    _ = c.gst_object_ref_sink(e);
    c.gst_object_unref(e);
}

pub fn gobject(t: c.GType) void {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(t, &q);
    out("type {s} abstract={d} class={d} instance={d}", .{ z(c.g_type_name(t)), @intFromBool(c.g_type_test_flags(t, c.G_TYPE_FLAG_ABSTRACT) != 0), q.class_size, q.instance_size });
    typeChain(t);
    const cls = c.g_type_class_ref(t);
    props(cls);
    c.g_type_class_unref(cls);
    signals(t);
}
