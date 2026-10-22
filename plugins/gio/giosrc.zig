const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const gio = @import("element.zig");
const base = @import("basesrc.zig");

const FILE = "../gst/gio/gstgiosrc.c";
const PROP_LOCATION = 1;
const PROP_FILE = 2;
const PROP_GROWING_FILE = 3;

const Self = extern struct {
    parent: base.Self,
    file: ?*c.GFile,
    is_growing: c.gboolean,
    monitor: ?*c.GFileMonitor,
    monitoring_mainloop: ?*c.GMainLoop,
    changed: c.gboolean,
    waiting_for_data: c.gboolean,
};

const Class = extern struct {
    parent: base.Class,
};

var once: cm.Once = .{};
var parent: ?*base.Class = null;
var sig_waiting: c.guint = 0;
var sig_done: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn state(s: *Self) c.GstState {
    return @as(*c.GstElement, @ptrCast(@alignCast(s))).current_state;
}

fn checkDeleted(s: *Self) bool {
    if (c.g_file_query_exists(s.file, s.parent.cancel) == 0) {
        const uri = c.g_file_get_uri(s.file);
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, null, c.g_strdup_printf("The underlying file %s is not available anymore", uri), FILE, "gst_gio_src_check_deleted", 118);
        c.g_free(uri);
        return true;
    }
    return false;
}

fn fileChanged(p: c.gpointer) callconv(.c) void {
    const s = me(p);
    cm.lock(s);
    s.changed = 1;
    if (s.monitoring_mainloop) |l| c.g_main_loop_quit(l);
    cm.unlock(s);
    _ = checkDeleted(s);
}

fn waitedForData(b: *base.Self) callconv(.c) void {
    const s = me(b);
    s.waiting_for_data = 0;
    c.g_signal_emit(b, sig_done, 0);
}

fn waitForData(b: *base.Self) callconv(.c) c.gboolean {
    const s = me(b);
    if (!cm.that(s.monitor == null, "gst_gio_src_wait_for_data", "!src->monitor")) return 0;
    if (checkDeleted(s)) return 0;
    cm.lock(s);
    if (s.is_growing == 0) {
        cm.unlock(s);
        return 0;
    }
    s.monitor = c.g_file_monitor(s.file, c.G_FILE_MONITOR_NONE, b.cancel, null);
    if (s.monitor == null) {
        cm.unlock(s);
        return 0;
    }
    _ = c.g_signal_connect_data(s.monitor, "changed", @ptrCast(&fileChanged), s, null, c.G_CONNECT_SWAPPED);
    cm.unlock(s);
    if (s.waiting_for_data == 0) {
        c.g_signal_emit(s, sig_waiting, 0);
        s.waiting_for_data = 1;
    }
    const ctx = c.g_main_context_new();
    c.g_main_context_push_thread_default(ctx);
    cm.lock(s);
    s.changed = 0;
    s.monitoring_mainloop = c.g_main_loop_new(ctx, 0);
    const growing = s.is_growing != 0;
    cm.unlock(s);
    if (growing) c.g_main_loop_run(s.monitoring_mainloop);
    _ = c.g_signal_handlers_disconnect_matched(s.monitor, c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA, 0, 0, null, @constCast(@ptrCast(&fileChanged)), s);
    cm.lock(s);
    c.g_object_unref(s.monitor);
    s.monitor = null;
    c.g_main_loop_unref(s.monitoring_mainloop);
    s.monitoring_mainloop = null;
    cm.unlock(s);
    c.g_main_context_pop_thread_default(ctx);
    c.g_main_context_unref(ctx);
    return s.changed;
}

fn quitLoop(s: *Self) void {
    while (s.monitoring_mainloop) |l| {
        if (c.g_main_loop_is_running(l) == 0) {
            cm.unlock(s);
            c.g_thread_yield();
            cm.lock(s);
            continue;
        }
        c.g_main_loop_quit(l);
        break;
    }
}

fn unlock(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    cm.lock(s);
    quitLoop(s);
    cm.unlock(s);
    return base.unlockParent(b);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.file) |f| c.g_object_unref(f);
    s.file = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_LOCATION => {
            if (state(s) == c.GST_STATE_PLAYING or state(s) == c.GST_STATE_PAUSED) return;
            cm.lock(s);
            if (s.file) |f| c.g_object_unref(f);
            const uri = c.g_value_get_string(v);
            s.file = if (uri != null) c.g_file_new_for_uri(uri) else null;
            cm.unlock(s);
        },
        PROP_GROWING_FILE => {
            cm.lock(s);
            const was = s.is_growing != 0;
            s.is_growing = c.g_value_get_boolean(v);
            c.gst_base_src_set_dynamic_size(@ptrCast(s), s.is_growing);
            c.gst_base_src_set_automatic_eos(@ptrCast(s), @intFromBool(s.is_growing == 0));
            if (was and s.is_growing == 0) quitLoop(s);
            cm.unlock(s);
        },
        PROP_FILE => {
            if (state(s) == c.GST_STATE_PLAYING or state(s) == c.GST_STATE_PAUSED) return;
            cm.lock(s);
            if (s.file) |f| c.g_object_unref(f);
            s.file = @ptrCast(@alignCast(c.g_value_dup_object(v)));
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 422),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_LOCATION => {
            cm.lock(s);
            if (s.file) |f| {
                const uri = c.g_file_get_uri(f);
                c.g_value_set_string(v, uri);
                c.g_free(uri);
            } else c.g_value_set_string(v, null);
            cm.unlock(s);
        },
        PROP_FILE => {
            cm.lock(s);
            c.g_value_set_object(v, s.file);
            cm.unlock(s);
        },
        PROP_GROWING_FILE => {
            cm.lock(s);
            c.g_value_set_boolean(v, s.is_growing);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 461),
    }
}

fn query(b: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(b);
    if (cm.queryType(q) != c.GST_QUERY_SCHEDULING or s.file == null) return base.queryParent(b, q);
    const scheme = c.g_file_get_uri_scheme(s.file);
    if (scheme == null) return base.queryParent(b, q);
    var flags: c.GstSchedulingFlags = 0;
    if (c.strcmp(scheme, "file") == 0) {
        flags |= c.GST_SCHEDULING_FLAG_SEEKABLE;
    } else if (c.strcmp(scheme, "http") != 0 and c.strcmp(scheme, "https") != 0) {
        c.g_free(scheme);
        return base.queryParent(b, q);
    }
    c.g_free(scheme);
    c.gst_query_set_scheduling(q, flags, 1, -1, 0);
    c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
    cm.lock(s);
    if (flags & c.GST_SCHEDULING_FLAG_SEEKABLE != 0 and s.is_growing == 0) c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PULL);
    cm.unlock(s);
    return 1;
}

fn getStream(b: *base.Self) callconv(.c) ?*c.GInputStream {
    const s = me(b);
    if (s.file == null) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, null, c.g_strdup("No location or GFile given"), FILE, "gst_gio_src_get_stream", 529);
        return null;
    }
    var uri = c.g_file_get_uri(s.file);
    if (uri == null) uri = c.g_strdup("(null)");
    defer c.g_free(uri);
    var err: [*c]c.GError = null;
    const stream: ?*c.GInputStream = @ptrCast(c.g_file_read(s.file, b.cancel, &err));
    if (stream == null and !gio.gioError(s, "g_file_read", &err, null)) {
        if (gio.ioError(err, c.G_IO_ERROR_NOT_FOUND)) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, null, c.g_strdup_printf("Could not open location %s for reading: %s", uri, err.*.message), FILE, "gst_gio_src_get_stream", 542);
        } else if (gio.ioError(err, c.G_IO_ERROR_NOT_MOUNTED)) {
            const st = c.gst_structure_new("not-mounted", "file", c.g_file_get_type(), s.file, "uri", c.G_TYPE_STRING, uri, @as(?*anyopaque, null));
            _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_element(@ptrCast(s), st));
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, null, c.g_strdup_printf("Location %s not mounted: %s", uri, err.*.message), FILE, "gst_gio_src_get_stream", 550);
        } else {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, null, c.g_strdup_printf("Could not open location %s for reading: %s", uri, err.*.message), FILE, "gst_gio_src_get_stream", 553);
        }
        c.g_clear_error(&err);
        return null;
    }
    return stream;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("gio_src", 0, "GIO source");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_LOCATION, c.g_param_spec_string("location", "Location", "URI location to read from", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_FILE, c.g_param_spec_object("file", "File", "GFile to read from", c.g_file_get_type(), cm.RW));
    c.g_object_class_install_property(oc, PROP_GROWING_FILE, c.g_param_spec_boolean("is-growing", "File is growing", "Whether the file is growing, ignoring its end", 0, cm.RW));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "GIO source", "Source/File", "Read from any GIO-supported location", "Ren\xc3\xa9 Stadler <mail@renestadler.de>, Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.query = query;
    bc.unlock = unlock;
    const gc: *base.Class = @ptrCast(@alignCast(k));
    gc.get_stream = getStream;
    gc.close_on_stop = 1;
    gc.wait_for_data = waitForData;
    gc.waited_for_data = waitedForData;
    sig_waiting = c.g_signal_new("waiting-data", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 0);
    sig_done = c.g_signal_new("done-waiting-data", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 0);
}

fn init(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(base.getType(), "GstGioSrc", Class, Self, classInit, init);
            gio.addUriHandler(t);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    gio.pluginInit(p);
    return c.gst_element_register(p, "giosrc", c.GST_RANK_SECONDARY, getType()) != 0;
}
