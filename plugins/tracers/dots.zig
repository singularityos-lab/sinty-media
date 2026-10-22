const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/tracers/gstdots.c";
const N: ?*anyopaque = null;
const PROP_NO_DELETE = 1;

const Self = extern struct {
    parent: c.GstTracer,
    no_delete: c.gboolean,
    output_dir: [*c]u8,
    snapshot: ?*c.GstTracer,
};

const Class = extern struct {
    parent: c.GstTracerClass,
};

var once: cm.Once = .{};
var parent_class: ?*c.GObjectClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_NO_DELETE) {
        me(ob).no_delete = c.g_value_get_boolean(v);
    } else cm.warnInvalid(FILE, ob, id, spec, 91);
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_NO_DELETE) {
        c.g_value_set_boolean(v, me(ob).no_delete);
    } else cm.warnInvalid(FILE, ob, id, spec, 107);
}

fn finalize(ob: [*c]c.GObject) callconv(.c) void {
    const s = me(ob);
    c.g_free(s.output_dir);
    if (s.snapshot) |t| c.gst_object_unref(t);
    parent_class.?.finalize.?(ob);
}

fn clean(root: [*c]const u8) void {
    var paths: [*c]c.GSList = null;
    var dirs: [*c]c.GSList = c.g_slist_prepend(null, c.g_strdup(root));
    while (dirs != null) {
        const cur: [*c]u8 = @ptrCast(dirs[0].data);
        dirs = c.g_slist_delete_link(dirs, dirs);
        var err: [*c]c.GError = null;
        const dir = c.g_dir_open(cur, 0, &err);
        if (dir == null) {
            c.g_clear_error(&err);
            c.g_free(cur);
            continue;
        }
        while (c.g_dir_read_name(dir)) |name| {
            const p = c.g_build_filename(cur, name, N);
            if (c.g_file_test(p, c.G_FILE_TEST_IS_DIR) != 0) {
                dirs = c.g_slist_prepend(dirs, p);
            } else if (c.g_str_has_suffix(p, ".dot") != 0) {
                paths = c.g_slist_prepend(paths, p);
            } else c.g_free(p);
        }
        c.g_dir_close(dir);
        c.g_free(cur);
    }
    var l = paths;
    while (l != null) : (l = l[0].next) _ = c.g_unlink(@ptrCast(l[0].data));
    c.g_slist_free_full(paths, c.g_free);
}

fn snapshotTracer(s: *Self) bool {
    const feat = c.gst_registry_lookup_feature(c.gst_registry_get(), "pipeline-snapshot");
    if (feat == null) return false;
    const loaded = c.gst_plugin_feature_load(feat);
    c.gst_object_unref(feat);
    if (loaded == null) return false;
    const factory: ?*c.GstTracerFactory = @ptrCast(@alignCast(loaded));
    const t = c.gst_tracer_factory_get_tracer_type(factory);
    const k = c.g_type_class_ref(t);
    if (c.g_object_class_find_property(@ptrCast(@alignCast(k)), "dots-viewer-ws-url") != null) {
        s.snapshot = @ptrCast(@alignCast(c.g_object_new(t, "dot-dir", s.output_dir, "dots-viewer-ws-url", "ws://127.0.0.1:3000/snapshot/", "folder-mode", @as(c.gint, 1), N)));
    } else s.snapshot = @ptrCast(@alignCast(c.g_object_new(t, @as([*c]const u8, null))));
    c.gst_object_unref(factory);
    c.g_type_class_unref(k);
    return s.snapshot != null;
}

fn setupDir(s: *Self) void {
    const env = c.g_getenv("GST_DEBUG_DUMP_DOT_DIR");
    if (env != null) {
        s.output_dir = c.g_strdup(env);
    } else {
        s.output_dir = c.g_build_filename(c.g_get_user_cache_dir(), "gstreamer-dots", N);
        _ = c.g_setenv("GST_DEBUG_DUMP_DOT_DIR", s.output_dir, 1);
    }
    _ = c.g_mkdir_with_parents(s.output_dir, 0o755);
    if (s.no_delete == 0) clean(s.output_dir);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.no_delete = 0;
    s.snapshot = null;
    setupDir(s);
    _ = snapshotTracer(s);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    gc.finalize = finalize;
    c.gst_tracer_class_set_use_structure_params(@ptrCast(@alignCast(k)), 1);
    c.g_object_class_install_property(gc, PROP_NO_DELETE, c.g_param_spec_boolean("no-delete", "No Delete", "Don't delete existing .dot files on startup", 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    _ = c._gst_debug_category_new("dots", 0, "dots tracer");
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_tracer_get_type(), "GstDotsTracer", Class, Self, classInit, init);
        }
    }.f);
}
