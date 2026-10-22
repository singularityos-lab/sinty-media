const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const writer = @import("writer.zig");

const FILE = "../plugins/elements/gstfdsink.c";
const NONE = cm.CLOCK_NONE;
const PROP_FD = 1;

const Self = extern struct {
    parent: c.GstBaseSink,
    uri: [*c]u8,
    fdset: ?*c.GstPoll,
    fd: c_int,
    current_pos: u64,
    seekable: c.gboolean,
    unlock: c.gboolean,
};

const Class = extern struct {
    parent: c.GstBaseSinkClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstBaseSinkClass = null;
var protocols = [_][*c]const u8{ "fd", null };

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn errno() c_int {
    return std.c._errno().*;
}

fn resError(s: *Self, code: c.gint, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, null, dbg, FILE, "gst_fd_sink_" ++ func, line);
}

fn query(b: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(b);
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            var f: c.GstFormat = 0;
            c.gst_query_parse_position(q, &f, null);
            if (f != c.GST_FORMAT_DEFAULT and f != c.GST_FORMAT_BYTES) return 0;
            c.gst_query_set_position(q, c.GST_FORMAT_BYTES, @bitCast(s.current_pos));
        },
        c.GST_QUERY_FORMATS => c.gst_query_set_formats(q, 2, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_BYTES),
        c.GST_QUERY_URI => c.gst_query_set_uri(q, s.uri),
        c.GST_QUERY_SEEKING => {
            var f: c.GstFormat = 0;
            c.gst_query_parse_seeking(q, &f, null, null, null);
            if (f == c.GST_FORMAT_BYTES or f == c.GST_FORMAT_DEFAULT) {
                c.gst_query_set_seeking(q, c.GST_FORMAT_BYTES, s.seekable, 0, -1);
            } else c.gst_query_set_seeking(q, f, 0, 0, -1);
        },
        else => return parent.?.query.?(b, q),
    }
    return 1;
}

fn writeLoop(s: *Self, data: anytype) c.GstFlowReturn {
    var skip: u64 = 0;
    while (true) {
        var w: u64 = 0;
        const r = if (@TypeOf(data) == [*c]c.GstBuffer)
            writer.buffer(s, s.fd, s.fdset, data, skip, &w, 0, NONE, null)
        else
            writer.list(s, s.fd, s.fdset, data, skip, &w, 0, NONE, null);
        s.current_pos +%= w;
        skip +%= w;
        if (s.unlock == 0 or r != c.GST_FLOW_FLUSHING) return r;
        const p = c.gst_base_sink_wait_preroll(@ptrCast(@alignCast(s)));
        if (p != c.GST_FLOW_OK) return p;
    }
}

fn render(b: [*c]c.GstBaseSink, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return writeLoop(me(b), buf);
}

fn renderList(b: [*c]c.GstBaseSink, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    if (c.gst_buffer_list_length(l) == 0) return c.GST_FLOW_OK;
    return writeLoop(me(b), l);
}

fn checkFd(s: *Self, fd: c_int, err: [*c][*c]c.GError) bool {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) >= 0) {
        if ((st.st_mode & c.S_IFMT) != c.S_IFREG) return true;
        if (c.lseek(fd, 0, c.SEEK_CUR) != -1) return true;
        const e = errno();
        if (e != c.EINVAL and e != c.EBADF) return true;
    }
    resError(s, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf("File descriptor %d is not valid: %s", fd, c.g_strerror(errno())), "check_fd", 360);
    c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_REFERENCE, "File descriptor %d is not valid: %s", fd, c.g_strerror(errno()));
    return false;
}

fn doSeek(s: *Self, off: u64) bool {
    if (c.lseek(s.fd, @bitCast(off), c.SEEK_SET) == -1) return false;
    s.current_pos = off;
    return true;
}

fn pollFor(set: ?*c.GstPoll, fd: c_int) void {
    var pfd = c.GstPollFD{ .fd = fd, .idx = -1 };
    _ = c.gst_poll_add_fd(set, &pfd);
    _ = c.gst_poll_fd_ctl_write(set, &pfd, 1);
}

fn start(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = me(b);
    if (!checkFd(s, s.fd, null)) return 0;
    s.fdset = c.gst_poll_new(1);
    if (s.fdset == null) {
        resError(s, c.GST_RESOURCE_ERROR_OPEN_READ_WRITE, c.g_strdup_printf("system error: %s", c.g_strerror(errno())), "start", 400);
        return 0;
    }
    pollFor(s.fdset, s.fd);
    s.current_pos = 0;
    s.seekable = @intFromBool(doSeek(s, 0));
    return 1;
}

fn stop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = me(b);
    if (s.fdset) |set| {
        c.gst_poll_free(set);
        s.fdset = null;
    }
    return 1;
}

fn flushing(b: [*c]c.GstBaseSink, on: c.gboolean) c.gboolean {
    const s = me(b);
    cm.lock(s);
    s.unlock = on;
    c.gst_poll_set_flushing(s.fdset, on);
    cm.unlock(s);
    return 1;
}

fn unlock(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    return flushing(b, 1);
}

fn unlockStop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    return flushing(b, 0);
}

fn updateFd(s: *Self, fd: c_int, err: [*c][*c]c.GError) bool {
    if (fd < 0) {
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_REFERENCE, "File descriptor %d is not valid", fd);
        return false;
    }
    if (!checkFd(s, fd, err)) return false;
    cm.lock(s);
    if (s.fdset) |set| {
        var old = c.GstPollFD{ .fd = s.fd, .idx = -1 };
        _ = c.gst_poll_remove_fd(set, &old);
        pollFor(set, fd);
    }
    s.fd = fd;
    c.g_free(s.uri);
    s.uri = c.g_strdup_printf("fd://%d", s.fd);
    cm.unlock(s);
    return true;
}

fn event(b: [*c]c.GstBaseSink, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(b);
    if (cm.eventType(ev) == c.GST_EVENT_SEGMENT) {
        var seg: [*c]const c.GstSegment = null;
        c.gst_event_parse_segment(ev, &seg);
        if (seg[0].format == c.GST_FORMAT_BYTES and s.current_pos != seg[0].start and !doSeek(s, seg[0].start)) {
            resError(s, c.GST_RESOURCE_ERROR_SEEK, c.g_strdup_printf("Error while seeking on file descriptor %d: %s", s.fd, c.g_strerror(errno())), "event", 594);
            c.gst_mini_object_unref(@ptrCast(ev));
            return 0;
        }
    }
    return parent.?.event.?(b, ev);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_FD => _ = updateFd(me(o), c.g_value_get_int(v), null),
        else => cm.warnInvalid(FILE, o, id, spec, 502),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_FD => c.g_value_set_int(v, me(o).fd),
        else => cm.warnInvalid(FILE, o, id, spec, 520),
    }
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SINK;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return @ptrCast(&protocols);
}

fn getUri(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    return c.g_strdup(me(h).uri);
}

fn setUri(h: ?*c.GstURIHandler, uri: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    var fd: c_int = -1;
    if (c.sscanf(uri, "fd://%d", &fd) != 1) {
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, "File descriptor URI could not be parsed");
        return 0;
    }
    return @intFromBool(updateFd(me(h), fd, err));
}

fn uriInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstURIHandlerInterface = @ptrCast(@alignCast(g));
    i.get_type = uriType;
    i.get_protocols = uriProtocols;
    i.get_uri = getUri;
    i.set_uri = setUri;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.uri);
    s.uri = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Filedescriptor Sink", "Sink/File", "Write data to a file descriptor", "Erik Walthinsen <omega@cse.ogi.edu>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.render = render;
    bc.render_list = renderList;
    bc.start = start;
    bc.stop = stop;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    bc.event = event;
    bc.query = query;
    c.g_object_class_install_property(oc, PROP_FD, c.g_param_spec_int("fd", "fd", "An open file descriptor to write to", 0, std.math.maxInt(c.gint), 1, cm.RW));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.fd = 1;
    s.uri = c.g_strdup_printf("fd://%d", s.fd);
    s.current_pos = 0;
    c.gst_base_sink_set_sync(@ptrCast(@alignCast(inst)), 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_base_sink_get_type(), "GstFdSink", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &info);
            _ = c._gst_debug_category_new("fdsink", 0, "fdsink element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "fdsink", c.GST_RANK_NONE, getType()) != 0;
}
