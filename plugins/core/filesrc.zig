const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstfilesrc.c";
const DOMAIN = "gstreamer-1.0";
const PROP_LOCATION = 1;

const Self = extern struct {
    parent: c.GstBaseSrc,
    filename: [*c]u8,
    uri: [*c]u8,
    fd: c_int,
    read_position: c.guint64,
    touch: c.gboolean,
    using_mmap: c.gboolean,
    sequential: c.gboolean,
    is_regular: c.gboolean,
    seekable: c.gboolean,
};

const Class = extern struct {
    parent: c.GstBaseSrcClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstBaseSrcClass = null;
var protocols = [_][*c]const u8{ "file", null };

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn isMine(o: anytype) bool {
    return cm.isA(o, getType());
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.filename);
    c.g_free(s.uri);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn setLocation(s: *Self, location: [*c]const u8, err: [*c][*c]c.GError) bool {
    cm.lock(s);
    const state = @as(*c.GstElement, @ptrCast(@alignCast(s))).current_state;
    if (state != c.GST_STATE_READY and state != c.GST_STATE_NULL) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "Changing the `location' property on filesrc when a file is open is not supported.");
        if (err != null) c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_STATE, "Changing the `location' property on filesrc when a file is open is not supported.");
        cm.unlock(s);
        return false;
    }
    cm.unlock(s);
    c.g_free(s.filename);
    c.g_free(s.uri);
    if (location == null) {
        s.filename = null;
        s.uri = null;
    } else {
        s.filename = c.g_strdup(location);
        s.uri = c.gst_filename_to_uri(location, null);
    }
    c.g_object_notify(@ptrCast(@alignCast(s)), "location");
    return true;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (!cm.that(isMine(o), "gst_file_src_set_property", "GST_IS_FILE_SRC (object)")) return;
    if (id == PROP_LOCATION) {
        _ = setLocation(me(o), c.g_value_get_string(v), null);
    } else cm.warnInvalid(FILE, o, id, spec, 277);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (!cm.that(isMine(o), "gst_file_src_get_property", "GST_IS_FILE_SRC (object)")) return;
    if (id == PROP_LOCATION) {
        c.g_value_set_string(v, me(o).filename);
    } else cm.warnInvalid(FILE, o, id, spec, 297);
}

fn sysError() [*c]u8 {
    return c.g_strdup_printf("system error: %s", c.g_strerror(std.c._errno().*));
}

fn fill(b: [*c]c.GstBaseSrc, offset: c.guint64, length: c.guint, buffer: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    if (offset != cm.CLOCK_NONE and s.read_position != offset) {
        const res = c.lseek(s.fd, @bitCast(offset), c.SEEK_SET);
        if (res == -1 or @as(u64, @bitCast(res)) != offset) {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_READ, null, sysError(), FILE, "gst_file_src_fill", 377);
            return c.GST_FLOW_ERROR;
        }
        s.read_position = offset;
    }
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buffer, &info, c.GST_MAP_WRITE) == 0) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, null, c.g_strdup("Can't write to buffer"), FILE, "gst_file_src_fill", 396);
        return c.GST_FLOW_ERROR;
    }
    var read: c.guint = 0;
    var left = length;
    while (left > 0) {
        std.c._errno().* = 0;
        const r = c.read(s.fd, info.data + read, left);
        if (r < 0) {
            const e = std.c._errno().*;
            if (e == c.EAGAIN or e == c.EINTR) continue;
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_READ, null, sysError(), FILE, "gst_file_src_fill", 382);
            c.gst_buffer_unmap(buffer, &info);
            c.gst_buffer_resize(buffer, 0, 0);
            return c.GST_FLOW_ERROR;
        }
        if (r == 0) {
            if (read > 0) break;
            c.gst_buffer_unmap(buffer, &info);
            c.gst_buffer_resize(buffer, 0, 0);
            return c.GST_FLOW_EOS;
        }
        const n: c.guint = @intCast(r);
        left -= n;
        read += n;
        s.read_position += n;
    }
    c.gst_buffer_unmap(buffer, &info);
    if (read != length) c.gst_buffer_resize(buffer, 0, read);
    cm.buf(buffer).offset = offset;
    cm.buf(buffer).offset_end = offset +% read;
    return c.GST_FLOW_OK;
}

fn isSeekable(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return me(b).seekable;
}

fn getSize(b: [*c]c.GstBaseSrc, size: [*c]c.guint64) callconv(.c) c.gboolean {
    const s = me(b);
    if (s.seekable == 0) return 0;
    var st: c.struct_stat = undefined;
    if (c.fstat(s.fd, &st) < 0) return 0;
    size[0] = @intCast(st.st_size);
    return 1;
}

fn openError(s: *Self, code: c.gint, text: [*c]u8, debug: [*c]u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, text, debug, FILE, "gst_file_src_start", line);
}

fn start(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    if (s.filename == null or s.filename[0] == 0) {
        openError(s, c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(cm.tr(DOMAIN, "No file name specified for reading.")), null, 577);
        return 0;
    }
    s.fd = c.open(s.filename, c.O_RDONLY);
    if (s.fd < 0) {
        if (std.c._errno().* == c.ENOENT) {
            openError(s, c.GST_RESOURCE_ERROR_NOT_FOUND, null, c.g_strdup_printf("No such file \"%s\"", s.filename), 585);
        } else {
            const dbg = sysError();
            openError(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf(cm.tr(DOMAIN, "Could not open file \"%s\" for reading."), s.filename), dbg, 589);
        }
        return 0;
    }
    var st: c.struct_stat = undefined;
    if (c.fstat(s.fd, &st) < 0) {
        openError(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf(cm.tr(DOMAIN, "Could not get info on \"%s\"."), s.filename), null, 598);
        _ = c.close(s.fd);
        return 0;
    }
    const kind = st.st_mode & c.S_IFMT;
    if (kind == c.S_IFDIR) {
        openError(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf(cm.tr(DOMAIN, "\"%s\" is a directory."), s.filename), null, 604);
        _ = c.close(s.fd);
        return 0;
    }
    if (kind == c.S_IFSOCK) {
        openError(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf(cm.tr(DOMAIN, "File \"%s\" is a socket."), s.filename), null, 611);
        _ = c.close(s.fd);
        return 0;
    }
    if (kind == c.S_IFREG) s.is_regular = 1;
    s.read_position = 0;
    if (c.lseek(s.fd, 0, c.SEEK_END) == -1) {
        s.seekable = 0;
    } else {
        if (c.lseek(s.fd, 0, c.SEEK_SET) == -1) {
            s.seekable = 0;
            openError(s, c.GST_RESOURCE_ERROR_OPEN_READ, null, c.g_strdup_printf("Could not seek back to zero after seek test in file \"%s\"", s.filename), 618);
            _ = c.close(s.fd);
            return 0;
        }
        s.seekable = 1;
    }
    s.seekable = @intFromBool(s.seekable != 0 and s.is_regular != 0);
    c.gst_base_src_set_dynamic_size(b, s.seekable);
    return 1;
}

fn stop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    _ = c.close(s.fd);
    s.fd = 0;
    s.is_regular = 0;
    return 1;
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SRC;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return &protocols;
}

fn getUri(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    return c.g_strdup(me(h).uri);
}

fn setUri(h: ?*c.GstURIHandler, uri: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const s = me(h);
    if (c.strcmp(uri, "file://") == 0) {
        _ = setLocation(s, null, null);
        return 1;
    }
    var host: [*c]u8 = null;
    const location = c.g_filename_from_uri(uri, &host, err);
    defer c.g_free(location);
    defer c.g_free(host);
    if (location == null or (err != null and err[0] != null)) return 0;
    if (host != null and c.strcmp(host, "localhost") != 0) {
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, "File URI with invalid hostname '%s'", host);
        return 0;
    }
    return @intFromBool(setLocation(s, location, err));
}

fn uriInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(g));
    i.get_type = uriType;
    i.get_protocols = uriProtocols;
    i.get_uri = getUri;
    i.set_uri = setUri;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_LOCATION, c.g_param_spec_string("location", "File Location", "Location of the file to read", null, cm.RW | cm.MUTABLE_READY));
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "File Source", "Source/File", "Read from arbitrary point in a file", "Erik Walthinsen <omega@cse.ogi.edu>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.start = start;
    bc.stop = stop;
    bc.is_seekable = isSeekable;
    bc.get_size = getSize;
    bc.fill = fill;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.filename = null;
    s.fd = 0;
    s.uri = null;
    s.is_regular = 0;
    c.gst_base_src_set_blocksize(@ptrCast(@alignCast(s)), 4 * 1024);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_src_get_type(), "GstFileSrc", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &info);
            _ = c._gst_debug_category_new("filesrc", 0, "filesrc element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "filesrc", c.GST_RANK_PRIMARY, getType()) != 0;
}
