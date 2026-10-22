const std = @import("std");
const cm = @import("../common.zig");
const writer = @import("writer.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstfilesink.c";
const DOMAIN = "gstreamer-1.0";

const PROP_LOCATION = 1;
const PROP_BUFFER_MODE = 2;
const PROP_BUFFER_SIZE = 3;
const PROP_APPEND = 4;
const PROP_O_SYNC = 5;
const PROP_MAX_TRANSIENT_ERROR_TIMEOUT = 6;
const PROP_FILE_MODE = 7;

const BUF_DEFAULT = -1;
const BUF_FULL = 0;
const BUF_LINE = 1;
const BUF_UNBUFFERED = 2;
const MODE_TRUNC = 1;
const MODE_APPEND = 2;
const MODE_OVERWRITE = 3;
const DEFAULT_BUFFER_SIZE = 64 * 1024;

const Self = extern struct {
    parent: c.GstBaseSink,
    filename: [*c]u8,
    uri: [*c]u8,
    file: ?*c.FILE,
    seekable: c.gboolean,
    current_pos: c.guint64,
    buffer_mode: c.gint,
    buffer_size: c.guint,
    buffer: [*c]u8,
    allocated_buffer_size: c.gsize,
    buffer_list: ?*c.GstBufferList,
    current_buffer_size: c.gsize,
    append: c.gboolean,
    o_sync: c.gboolean,
    max_transient_error_timeout: c.gint,
    flushing: c.gboolean,
    file_mode: c.gint,
};

const Class = extern struct {
    parent: c.GstBaseSinkClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var file_once: cm.Once = .{};
var buf_once: cm.Once = .{};
var parent: ?*c.GstBaseSinkClass = null;
var protocols = [_][*c]const u8{ "file", null };

var file_modes = [_]c.GEnumValue{
    .{ .value = MODE_TRUNC, .value_name = "Truncate file (mode wb)", .value_nick = "truncate" },
    .{ .value = MODE_APPEND, .value_name = "Append file (mode ab)", .value_nick = "output" },
    .{ .value = MODE_OVERWRITE, .value_name = "Overwrite file without truncating (mode rb+)", .value_nick = "overwrite" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

var buf_modes = [_]c.GEnumValue{
    .{ .value = BUF_DEFAULT, .value_name = "Default buffering", .value_nick = "default" },
    .{ .value = BUF_FULL, .value_name = "Fully buffered", .value_nick = "full" },
    .{ .value = BUF_LINE, .value_name = "Line buffered (deprecated, like full)", .value_nick = "line" },
    .{ .value = BUF_UNBUFFERED, .value_name = "Unbuffered", .value_nick = "unbuffered" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn fileModeType() c.GType {
    return file_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstFileSinkFileMode", &file_modes);
        }
    }.f);
}

fn bufModeType() c.GType {
    return buf_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstFileSinkBufferMode", &buf_modes);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn bsink(p: anytype) [*c]c.GstBaseSink {
    return @ptrCast(@alignCast(p));
}

fn errno() c_int {
    return std.c._errno().*;
}

fn sysError() [*c]u8 {
    return c.g_strdup_printf("system error: %s", c.g_strerror(errno()));
}

fn resErr(s: *Self, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, text, debug, FILE, func, line);
}

fn fopen(name: [*c]const u8, mode: [*c]const u8, sync: bool) ?*c.FILE {
    var flags: c_int = 0;
    if (c.strcmp(mode, "wb") == 0) {
        flags = c.O_WRONLY | c.O_CREAT | c.O_TRUNC;
    } else if (c.strcmp(mode, "ab") == 0) {
        flags = c.O_WRONLY | c.O_CREAT | c.O_APPEND;
    } else flags = c.O_RDWR | c.O_CREAT;
    if (sync) flags |= c.O_SYNC;
    const h = c.open(name, flags, @as(c_uint, 0o666));
    if (h < 0) return null;
    return c.fdopen(h, mode);
}

fn fd(s: *Self) c_int {
    return c.fileno(s.file);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
    c.g_free(s.uri);
    s.uri = null;
    c.g_free(s.filename);
    s.filename = null;
}

fn setLocation(s: *Self, location: [*c]const u8, err: [*c][*c]c.GError) bool {
    if (s.file != null) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Changing the `location' property on filesink when a file is open is not supported.");
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_STATE, "Changing the 'location' property on filesink when a file is open is not supported");
        return false;
    }
    c.g_free(s.filename);
    c.g_free(s.uri);
    if (location != null) {
        s.filename = c.g_strdup(location);
        s.uri = c.gst_filename_to_uri(location, null);
    } else {
        s.filename = null;
        s.uri = null;
    }
    return true;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_LOCATION => _ = setLocation(s, c.g_value_get_string(v), null),
        PROP_BUFFER_MODE => s.buffer_mode = c.g_value_get_enum(v),
        PROP_BUFFER_SIZE => s.buffer_size = c.g_value_get_uint(v),
        PROP_APPEND => s.append = c.g_value_get_boolean(v),
        PROP_FILE_MODE => s.file_mode = c.g_value_get_enum(v),
        PROP_O_SYNC => s.o_sync = c.g_value_get_boolean(v),
        PROP_MAX_TRANSIENT_ERROR_TIMEOUT => s.max_transient_error_timeout = c.g_value_get_int(v),
        else => cm.warnInvalid(FILE, o, id, spec, 413),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_LOCATION => c.g_value_set_string(v, s.filename),
        PROP_BUFFER_MODE => c.g_value_set_enum(v, s.buffer_mode),
        PROP_BUFFER_SIZE => c.g_value_set_uint(v, s.buffer_size),
        PROP_APPEND => c.g_value_set_boolean(v, s.append),
        PROP_FILE_MODE => c.g_value_set_enum(v, s.file_mode),
        PROP_O_SYNC => c.g_value_set_boolean(v, s.o_sync),
        PROP_MAX_TRANSIENT_ERROR_TIMEOUT => c.g_value_set_int(v, s.max_transient_error_timeout),
        else => cm.warnInvalid(FILE, o, id, spec, 447),
    }
}

fn openFile(s: *Self) bool {
    if (s.filename == null or s.filename[0] == 0) {
        resErr(s, c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(cm.tr(DOMAIN, "No file name specified for writing.")), null, "gst_file_sink_open_file", 502);
        return false;
    }
    const sync = s.o_sync != 0;
    s.file = if (s.append != 0 or s.file_mode == MODE_APPEND) fopen(s.filename, "ab", sync) else if (s.file_mode == MODE_OVERWRITE) fopen(s.filename, "rb+", sync) else fopen(s.filename, "wb", sync);
    if (s.file == null) {
        const dbg = sysError();
        resErr(s, c.GST_RESOURCE_ERROR_OPEN_WRITE, c.g_strdup_printf(cm.tr(DOMAIN, "Could not open file \"%s\" for writing."), s.filename), dbg, "gst_file_sink_open_file", 508);
        return false;
    }
    s.current_pos = 0;
    s.seekable = @intFromBool(doSeek(s, 0));
    c.g_free(s.buffer);
    s.buffer = null;
    if (s.buffer_list != null) c.gst_mini_object_unref(@ptrCast(@alignCast(s.buffer_list)));
    s.buffer_list = null;
    if (s.buffer_mode != BUF_UNBUFFERED) {
        if (s.buffer_size == 0) {
            s.buffer_size = DEFAULT_BUFFER_SIZE;
            c.g_object_notify(@ptrCast(@alignCast(s)), "buffer-size");
        }
        if (s.buffer_mode == BUF_FULL) {
            s.buffer = @ptrCast(c.g_malloc(s.buffer_size));
            s.allocated_buffer_size = s.buffer_size;
        } else s.buffer_list = c.gst_buffer_list_new();
        s.current_buffer_size = 0;
    }
    return true;
}

fn closeFile(s: *Self) void {
    if (s.file != null) {
        if (flushBuffer(s) != c.GST_FLOW_OK) resErr(s, c.GST_RESOURCE_ERROR_CLOSE, c.g_strdup_printf(cm.tr(DOMAIN, "Error closing file \"%s\"."), s.filename), null, "gst_file_sink_close_file", 520);
        if (c.fclose(s.file) != 0) {
            const dbg = sysError();
            resErr(s, c.GST_RESOURCE_ERROR_CLOSE, c.g_strdup_printf(cm.tr(DOMAIN, "Error closing file \"%s\"."), s.filename), dbg, "gst_file_sink_close_file", 524);
        }
        s.file = null;
    }
    c.g_free(s.buffer);
    s.buffer = null;
    s.allocated_buffer_size = 0;
    if (s.buffer_list != null) {
        c.gst_mini_object_unref(@ptrCast(@alignCast(s.buffer_list)));
        s.buffer_list = null;
    }
    s.current_buffer_size = 0;
}

fn query(b: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(b);
    var fmt: c.GstFormat = 0;
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            c.gst_query_parse_position(q, &fmt, null);
            if (fmt == c.GST_FORMAT_DEFAULT or fmt == c.GST_FORMAT_BYTES) {
                c.gst_query_set_position(q, c.GST_FORMAT_BYTES, @bitCast(s.current_pos + s.current_buffer_size));
                return 1;
            }
            return 0;
        },
        c.GST_QUERY_FORMATS => {
            c.gst_query_set_formats(q, 2, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_BYTES);
            return 1;
        },
        c.GST_QUERY_URI => {
            c.gst_query_set_uri(q, s.uri);
            return 1;
        },
        c.GST_QUERY_SEEKING => {
            c.gst_query_parse_seeking(q, &fmt, null, null, null);
            if (fmt == c.GST_FORMAT_BYTES or fmt == c.GST_FORMAT_DEFAULT) {
                c.gst_query_set_seeking(q, c.GST_FORMAT_BYTES, s.seekable, 0, -1);
            } else c.gst_query_set_seeking(q, fmt, 0, 0, -1);
            return 1;
        },
        else => return parent.?.query.?(b, q),
    }
}

fn currentOffset(s: *Self, pos: *u64) bool {
    _ = c.ftello(s.file);
    const r = c.lseek(fd(s), 0, c.SEEK_CUR);
    if (r != -1) pos.* = @bitCast(r);
    return r != -1;
}

fn doSeek(s: *Self, off: u64) bool {
    if (flushBuffer(s) != c.GST_FLOW_OK) return false;
    if (c.fseeko(s.file, @bitCast(off), c.SEEK_SET) != 0) return false;
    if (c.lseek(fd(s), @bitCast(off), c.SEEK_SET) == -1) return false;
    _ = currentOffset(s, &s.current_pos);
    return true;
}

fn event(b: [*c]c.GstBaseSink, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(b);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(ev, &seg);
            if (seg[0].format == c.GST_FORMAT_BYTES and s.current_pos + s.current_buffer_size != seg[0].start) {
                if (!doSeek(s, seg[0].start)) {
                    const dbg = sysError();
                    resErr(s, c.GST_RESOURCE_ERROR_SEEK, c.g_strdup_printf(cm.tr(DOMAIN, "Error while seeking in file \"%s\"."), s.filename), dbg, "gst_file_sink_event", 709);
                    c.gst_mini_object_unref(@ptrCast(ev));
                    return 0;
                }
            }
        },
        c.GST_EVENT_FLUSH_STOP => {
            if (s.current_pos != 0 and s.seekable != 0) {
                _ = doSeek(s, 0);
                if (c.ftruncate(fd(s), 0) != 0) {
                    const dbg = sysError();
                    resErr(s, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf(cm.tr(DOMAIN, "Error while writing to file \"%s\"."), s.filename), dbg, "gst_file_sink_event", 724);
                    c.gst_mini_object_unref(@ptrCast(ev));
                    return 0;
                }
            }
            if (s.buffer_list != null) {
                c.gst_mini_object_unref(@ptrCast(@alignCast(s.buffer_list)));
                s.buffer_list = c.gst_buffer_list_new();
            }
            s.current_buffer_size = 0;
        },
        c.GST_EVENT_EOS => {
            if (flushBuffer(s) != c.GST_FLOW_OK) {
                resErr(s, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf(cm.tr(DOMAIN, "Error while writing to file \"%s\"."), s.filename), null, "gst_file_sink_event", 717);
                c.gst_mini_object_unref(@ptrCast(ev));
                return 0;
            }
        },
        else => {},
    }
    return parent.?.event.?(b, ev);
}

fn retry(s: *Self, comptime what: enum { mem, buffer, list }, data: anytype, size: usize) c.GstFlowReturn {
    while (true) {
        var written: u64 = 0;
        const flow = switch (what) {
            .mem => writer.mem(s, fd(s), null, data, size, &written, s.max_transient_error_timeout, s.current_pos, &s.flushing),
            .buffer => writer.buffer(s, fd(s), null, data, &written, s.max_transient_error_timeout, s.current_pos, &s.flushing),
            .list => writer.list(s, fd(s), null, data, &written, s.max_transient_error_timeout, s.current_pos, &s.flushing),
        };
        s.current_pos += written;
        if (flow != c.GST_FLOW_FLUSHING) return flow;
        const w = c.gst_base_sink_wait_preroll(bsink(s));
        if (w != c.GST_FLOW_OK) return w;
    }
}

fn renderListInternal(s: *Self, l: ?*c.GstBufferList) c.GstFlowReturn {
    if (c.gst_buffer_list_length(l) == 0) return c.GST_FLOW_OK;
    return retry(s, .list, l, 0);
}

fn flushBuffer(s: *Self) c.GstFlowReturn {
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (s.buffer != null and s.current_buffer_size != 0) {
        ret = retry(s, .mem, @as([*]const u8, @ptrCast(s.buffer)), s.current_buffer_size);
    } else if (s.buffer_list != null and s.current_buffer_size != 0) {
        const n = c.gst_buffer_list_length(s.buffer_list);
        if (n > 0) {
            ret = renderListInternal(s, s.buffer_list);
            c.gst_buffer_list_remove(s.buffer_list, 0, n);
        }
    }
    s.current_buffer_size = 0;
    return ret;
}

fn syncAfter(b: [*c][*c]c.GstBuffer, _: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    if (cm.buf(b[0]).mini_object.flags & c.GST_BUFFER_FLAG_SYNC_AFTER != 0) {
        @as(*c.gboolean, @ptrCast(@alignCast(data))).* = 1;
        return 0;
    }
    return 1;
}

fn accumulate(b: [*c][*c]c.GstBuffer, _: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    const p: *c.guint = @ptrCast(@alignCast(data));
    p.* +%= @truncate(c.gst_buffer_get_size(b[0]));
    return 1;
}

fn doFsync(s: *Self, comptime func: []const u8, line: c.gint) c.GstFlowReturn {
    var r: c_int = 0;
    while (true) {
        r = c.fsync(fd(s));
        if (!(r < 0 and errno() == c.EINTR)) break;
    }
    if (r != 0) {
        resErr(s, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf(cm.tr(DOMAIN, "Error while writing to file \"%s\"."), s.filename), c.g_strdup_printf("%s", c.g_strerror(errno())), func, line);
        return c.GST_FLOW_ERROR;
    }
    return c.GST_FLOW_OK;
}

fn queueBuffer(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    const size = c.gst_buffer_get_size(b);
    if (s.buffer != null) {
        if (s.current_buffer_size + size > s.allocated_buffer_size) {
            const f = flushBuffer(s);
            if (f != c.GST_FLOW_OK) return f;
        }
        if (size > s.allocated_buffer_size) return retry(s, .buffer, b, 0);
        s.current_buffer_size += c.gst_buffer_extract(b, 0, s.buffer + s.current_buffer_size, size);
        return c.GST_FLOW_OK;
    }
    s.current_buffer_size += size;
    c.gst_buffer_list_insert(s.buffer_list, -1, c.gst_buffer_ref(b));
    if (s.current_buffer_size > s.buffer_size) return flushBuffer(s);
    return c.GST_FLOW_OK;
}

fn renderList(b: [*c]c.GstBaseSink, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    const n = c.gst_buffer_list_length(l);
    if (n == 0) return c.GST_FLOW_OK;
    var sync: c.gboolean = 0;
    _ = c.gst_buffer_list_foreach(l, syncAfter, &sync);
    var flow: c.GstFlowReturn = c.GST_FLOW_OK;
    if (sync != 0 or (s.buffer == null and s.buffer_list == null)) {
        flow = flushBuffer(s);
        if (flow == c.GST_FLOW_OK) flow = renderListInternal(s, l);
    } else {
        var size: c.guint = 0;
        _ = c.gst_buffer_list_foreach(l, accumulate, &size);
        if (s.buffer != null) {
            var i: c.guint = 0;
            while (i < n and flow == c.GST_FLOW_OK) : (i += 1) {
                const bf = c.gst_buffer_list_get(l, i);
                const bs = c.gst_buffer_get_size(bf);
                if (s.current_buffer_size + bs > s.allocated_buffer_size) {
                    flow = flushBuffer(s);
                    if (flow != c.GST_FLOW_OK) return flow;
                }
                if (bs > s.allocated_buffer_size) {
                    flow = retry(s, .buffer, bf, 0);
                } else {
                    s.current_buffer_size += c.gst_buffer_extract(bf, 0, s.buffer + s.current_buffer_size, bs);
                    flow = c.GST_FLOW_OK;
                }
            }
        } else {
            var i: c.guint = 0;
            while (i < n) : (i += 1) c.gst_buffer_list_insert(s.buffer_list, -1, c.gst_buffer_ref(c.gst_buffer_list_get(l, i)));
            s.current_buffer_size += size;
            flow = if (s.current_buffer_size > s.buffer_size) flushBuffer(s) else c.GST_FLOW_OK;
        }
    }
    if (flow == c.GST_FLOW_OK and sync != 0) flow = doFsync(s, "gst_file_sink_render_list", 977);
    return flow;
}

fn render(b: [*c]c.GstBaseSink, buffer: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(b);
    const sync = cm.buf(buffer).mini_object.flags & c.GST_BUFFER_FLAG_SYNC_AFTER != 0;
    const n = c.gst_buffer_n_memory(buffer);
    var flow: c.GstFlowReturn = c.GST_FLOW_OK;
    if (n > 0 and (sync or (s.buffer == null and s.buffer_list == null))) {
        flow = flushBuffer(s);
        if (flow == c.GST_FLOW_OK) flow = retry(s, .buffer, buffer, 0);
    } else if (n > 0) {
        flow = queueBuffer(s, buffer);
        if (flow != c.GST_FLOW_OK and s.buffer != null) return flow;
    }
    if (flow == c.GST_FLOW_OK and sync) flow = doFsync(s, "gst_file_sink_render", 1061);
    return flow;
}

fn start(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = me(b);
    @atomicStore(c.gboolean, &s.flushing, 0, .seq_cst);
    return @intFromBool(openFile(s));
}

fn stop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    closeFile(me(b));
    return 1;
}

fn unlockFn(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    @atomicStore(c.gboolean, &me(b).flushing, 1, .seq_cst);
    return 1;
}

fn unlockStop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    @atomicStore(c.gboolean, &me(b).flushing, 0, .seq_cst);
    return 1;
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SINK;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return &protocols;
}

fn getUri(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    return c.g_strdup(me(h).uri);
}

fn setUri(h: ?*c.GstURIHandler, uri: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const s = me(h);
    var location: [*c]u8 = null;
    if (c.g_str_has_prefix(uri, "file://localhost/") != 0) {
        const tmp = c.g_strconcat("file://", uri + 16, @as(?*anyopaque, null));
        location = c.gst_uri_get_location(tmp);
        c.g_free(tmp);
    } else if (c.strcmp(uri, "file://") == 0) {
        _ = setLocation(s, null, null);
        return 1;
    } else location = c.gst_uri_get_location(uri);
    if (location == null) {
        c.g_set_error_literal(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, "File URI without location");
        return 0;
    }
    defer c.g_free(location);
    if (c.g_path_is_absolute(location) == 0) {
        c.g_set_error_literal(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, "File URI location must be an absolute path");
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
    oc.dispose = dispose;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_LOCATION, c.g_param_spec_string("location", "File Location", "Location of the file to write", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_MODE, c.g_param_spec_enum("buffer-mode", "Buffering mode", "The buffering mode to use", bufModeType(), BUF_DEFAULT, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_SIZE, c.g_param_spec_uint("buffer-size", "Buffering size", "Size of buffer in number of bytes for line or full buffer-mode", 0, std.math.maxInt(c.guint), DEFAULT_BUFFER_SIZE, cm.RW));
    c.g_object_class_install_property(oc, PROP_FILE_MODE, c.g_param_spec_enum("file-mode", "File Mode", "Specify file mode used to open file", fileModeType(), MODE_TRUNC, cm.RW));
    c.g_object_class_install_property(oc, PROP_APPEND, c.g_param_spec_boolean("append", "Append", "Append to an already existing file", 0, cm.RW | c.G_PARAM_DEPRECATED));
    c.g_object_class_install_property(oc, PROP_O_SYNC, c.g_param_spec_boolean("o-sync", "Synchronous IO", "Open the file with O_SYNC for enabling synchronous IO", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_MAX_TRANSIENT_ERROR_TIMEOUT, c.g_param_spec_int("max-transient-error-timeout", "Max Transient Error Timeout", "Retry up to this many ms on transient errors (currently EACCES)", 0, std.math.maxInt(c.gint), 0, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "File Sink", "Sink/File", "Write stream to a file", "Thomas Vander Stichele <thomas at apestaart dot org>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.start = start;
    bc.stop = stop;
    bc.query = query;
    bc.render = render;
    bc.render_list = renderList;
    bc.event = event;
    bc.unlock = unlockFn;
    bc.unlock_stop = unlockStop;
    c.gst_type_mark_as_plugin_api(bufModeType(), 0);
    c.gst_type_mark_as_plugin_api(fileModeType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.filename = null;
    s.file = null;
    s.current_pos = 0;
    s.buffer_mode = BUF_DEFAULT;
    s.buffer_size = DEFAULT_BUFFER_SIZE;
    s.append = 0;
    s.file_mode = MODE_TRUNC;
    c.gst_base_sink_set_sync(bsink(s), 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_sink_get_type(), "GstFileSink", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &info);
            _ = c._gst_debug_category_new("filesink", 0, "filesink element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "filesink", c.GST_RANK_PRIMARY, getType()) != 0;
}
