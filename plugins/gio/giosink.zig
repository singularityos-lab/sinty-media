const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const gio = @import("element.zig");
const base = @import("basesink.zig");

const FILE = "../gst/gio/gstgiosink.c";
const FUNC = "gst_gio_sink_get_stream";
const PROP_LOCATION = 1;
const PROP_FILE = 2;

const Self = extern struct {
    parent: base.Self,
    file: ?*c.GFile,
};

const Class = extern struct {
    parent: base.Class,
};

var once: cm.Once = .{};
var parent: ?*base.Class = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn running(s: *Self) bool {
    const st = @as(*c.GstElement, @ptrCast(@alignCast(s))).current_state;
    return st == c.GST_STATE_PLAYING or st == c.GST_STATE_PAUSED;
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
            if (running(s)) return;
            cm.lock(s);
            if (s.file) |f| c.g_object_unref(f);
            const uri = c.g_value_get_string(v);
            s.file = if (uri != null) c.g_file_new_for_uri(uri) else null;
            cm.unlock(s);
        },
        PROP_FILE => {
            if (running(s)) return;
            cm.lock(s);
            if (s.file) |f| c.g_object_unref(f);
            s.file = @ptrCast(@alignCast(c.g_value_dup_object(v)));
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 223),
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
        else => cm.warnInvalid(FILE, o, id, spec, 255),
    }
}

fn openError(s: *Self, code: c.gint, debug: [*c]u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, null, debug, FILE, FUNC, line);
}

fn postFile(s: *Self, name: [*c]const u8, uri: [*c]const u8) void {
    const st = c.gst_structure_new(name, "file", c.g_file_get_type(), s.file, "uri", c.G_TYPE_STRING, uri, @as(?*anyopaque, null));
    _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_element(@ptrCast(s), st));
}

fn getStream(b: *base.Self) callconv(.c) ?*c.GOutputStream {
    const s = me(b);
    if (s.file == null) {
        openError(s, c.GST_RESOURCE_ERROR_OPEN_WRITE, c.g_strdup("No location or GFile given"), 270);
        return null;
    }
    var uri = c.g_file_get_uri(s.file);
    if (uri == null) uri = c.g_strdup("(null)");
    defer c.g_free(uri);
    var err: [*c]c.GError = null;
    const stream: ?*c.GOutputStream = @ptrCast(c.g_file_create(s.file, c.G_FILE_CREATE_NONE, b.cancel, &err));
    if (stream != null) return stream;
    if (!gio.gioError(s, "g_file_create", &err, null)) {
        if (gio.ioError(err, c.G_IO_ERROR_NOT_FOUND)) {
            openError(s, c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("Could not open location %s for writing: %s", uri, err.*.message), 289);
        } else if (gio.ioError(err, c.G_IO_ERROR_EXISTS)) {
            postFile(s, "file-exists", uri);
            openError(s, c.GST_RESOURCE_ERROR_OPEN_WRITE, c.g_strdup_printf("Location %s already exists: %s", uri, err.*.message), 297);
        } else if (gio.ioError(err, c.G_IO_ERROR_NOT_MOUNTED)) {
            postFile(s, "not-mounted", uri);
            openError(s, c.GST_RESOURCE_ERROR_OPEN_WRITE, c.g_strdup_printf("Location %s not mounted: %s", uri, err.*.message), 305);
        } else {
            openError(s, c.GST_RESOURCE_ERROR_OPEN_WRITE, c.g_strdup_printf("Could not open location %s for writing: %s", uri, err.*.message), 308);
        }
        c.g_clear_error(&err);
    }
    return null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("gio_sink", 0, "GIO sink");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_LOCATION, c.g_param_spec_string("location", "Location", "URI location to write to", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_FILE, c.g_param_spec_object("file", "File", "GFile to write to", c.g_file_get_type(), cm.RW));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "GIO sink", "Sink/File", "Write to any GIO-supported location", "Ren\xc3\xa9 Stadler <mail@renestadler.de>, Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    const gc: *base.Class = @ptrCast(@alignCast(k));
    gc.get_stream = getStream;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    me(inst).parent.close_on_stop = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(base.getType(), "GstGioSink", Class, Self, classInit, init);
            gio.addUriHandler(t);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    gio.pluginInit(p);
    return c.gst_element_register(p, "giosink", c.GST_RANK_SECONDARY, getType()) != 0;
}
