const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstfdsrc.c";
const NONE = cm.CLOCK_NONE;
const PROP_FD = 1;
const PROP_TIMEOUT = 2;
const PROP_IS_LIVE = 3;

const Self = extern struct {
    parent: c.GstPushSrc,
    new_fd: c.gint,
    fd: c.gint,
    seekable_fd: c.gboolean,
    size: u64,
    timeout: u64,
    uri: [*c]u8,
    fdset: ?*c.GstPoll,
    curoffset: c.gulong,
};

const Class = extern struct {
    parent: c.GstPushSrcClass,
    timeout: ?*const fn ([*c]c.GstElement) callconv(.c) void,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstBaseSrcClass = null;
var protocols = [_][*c]const u8{ "fd", null };

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn base(p: anytype) [*c]c.GstBaseSrc {
    return @ptrCast(@alignCast(p));
}

fn errno() c_int {
    return std.c._errno().*;
}

fn state(s: *Self) c.GstState {
    return @as(*c.GstElement, @ptrCast(@alignCast(s))).current_state;
}

fn resError(s: *Self, code: c.gint, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, null, dbg, FILE, "gst_fd_src_" ++ func, line);
}

fn updateFd(s: *Self, size: u64) void {
    if (s.fdset) |set| {
        var pfd = c.GstPollFD{ .fd = -1, .idx = -1 };
        if (s.fd >= 0) {
            pfd.fd = s.fd;
            _ = c.gst_poll_remove_fd(set, &pfd);
        }
        pfd.fd = s.new_fd;
        _ = c.gst_poll_add_fd(set, &pfd);
        _ = c.gst_poll_fd_ctl_read(set, &pfd, 1);
    }
    if (s.fd == s.new_fd) return;
    s.fd = s.new_fd;
    s.size = size;
    c.g_free(s.uri);
    s.uri = c.g_strdup_printf("fd://%d", s.fd);
    var st: c.struct_stat = undefined;
    const seekable = c.fstat(s.fd, &st) >= 0 and (st.st_mode & c.S_IFMT) == c.S_IFREG and c.lseek(s.fd, 0, c.SEEK_CUR) >= 0;
    s.seekable_fd = @intFromBool(seekable);
    c.gst_base_src_set_dynamic_size(base(s), @intFromBool(seekable));
}

fn start(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    s.curoffset = 0;
    s.fdset = c.gst_poll_new(1);
    if (s.fdset == null) {
        resError(s, c.GST_RESOURCE_ERROR_OPEN_READ_WRITE, c.g_strdup_printf("system error: %s", c.g_strerror(errno())), "start", 306);
        return 0;
    }
    updateFd(s, NONE);
    return 1;
}

fn stop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(b);
    if (s.fdset) |set| {
        c.gst_poll_free(set);
        s.fdset = null;
    }
    return 1;
}

fn flushing(b: [*c]c.GstBaseSrc, on: c.gboolean) c.gboolean {
    const s = me(b);
    cm.lock(s);
    c.gst_poll_set_flushing(s.fdset, on);
    cm.unlock(s);
    return 1;
}

fn unlock(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return flushing(b, 1);
}

fn unlockStop(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return flushing(b, 0);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_FD => {
            s.new_fd = c.g_value_get_int(v);
            cm.lock(s);
            if (state(s) <= c.GST_STATE_READY) updateFd(s, NONE);
            cm.unlock(s);
        },
        PROP_TIMEOUT => s.timeout = c.g_value_get_uint64(v),
        PROP_IS_LIVE => c.gst_base_src_set_live(base(s), c.g_value_get_boolean(v)),
        else => cm.warnInvalid(FILE, o, id, spec, 382),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_FD => c.g_value_set_int(v, s.fd),
        PROP_TIMEOUT => c.g_value_set_uint64(v, s.timeout),
        PROP_IS_LIVE => c.g_value_set_boolean(v, c.gst_base_src_is_live(base(s))),
        else => cm.warnInvalid(FILE, o, id, spec, 404),
    }
}

fn waitReadable(s: *Self) c.GstFlowReturn {
    const timeout: u64 = if (s.timeout > 0) s.timeout *% 1000 else NONE;
    while (true) {
        const r = c.gst_poll_wait(s.fdset, timeout);
        if (r > 0) return c.GST_FLOW_OK;
        if (r == 0) {
            const st = c.gst_structure_new("GstFdSrcTimeout", "timeout", c.G_TYPE_UINT64, s.timeout, @as(?*anyopaque, null));
            _ = c.gst_element_post_message(@ptrCast(@alignCast(s)), c.gst_message_new_element(cm.obj(s), st));
            continue;
        }
        const e = errno();
        if (e == c.EINTR or e == c.EAGAIN) continue;
        if (e == c.EBUSY) return c.GST_FLOW_FLUSHING;
        resError(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup_printf("poll on file descriptor: %s.", c.g_strerror(e)), "create", 507);
        return c.GST_FLOW_ERROR;
    }
}

fn create(p: [*c]c.GstPushSrc, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(p);
    const w = waitReadable(s);
    if (w != c.GST_FLOW_OK) return w;
    const size = base(s)[0].blocksize;
    const b = c.gst_buffer_new_allocate(null, size, null);
    if (b == null) return c.GST_FLOW_ERROR;
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &info, c.GST_MAP_WRITE) == 0) {
        resError(s, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup("Can't write to buffer"), "create", 540);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_ERROR;
    }
    var n: isize = undefined;
    while (true) {
        n = c.read(s.fd, info.data, size);
        if (!(n == -1 and errno() == c.EINTR)) break;
    }
    if (n < 0) {
        resError(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup_printf("read on file descriptor: %s.", c.g_strerror(errno())), "create", 531);
        c.gst_buffer_unmap(b, &info);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_ERROR;
    }
    c.gst_buffer_unmap(b, &info);
    c.gst_buffer_resize(b, 0, n);
    if (n == 0) {
        c.gst_buffer_unref(b);
        return c.GST_FLOW_EOS;
    }
    cm.buf(b).offset = s.curoffset;
    cm.buf(b).pts = NONE;
    s.curoffset +%= @intCast(n);
    out[0] = b;
    return c.GST_FLOW_OK;
}

fn query(b: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.queryType(q) == c.GST_QUERY_URI) {
        c.gst_query_set_uri(q, me(b).uri);
        return 1;
    }
    return parent.?.query.?(b, q);
}

fn isSeekable(b: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return me(b).seekable_fd;
}

fn getSize(b: [*c]c.GstBaseSrc, size: [*c]u64) callconv(.c) c.gboolean {
    const s = me(b);
    if (s.size != NONE) {
        size[0] = s.size;
        return 1;
    }
    if (s.seekable_fd == 0) return 0;
    var st: c.struct_stat = undefined;
    if (c.fstat(s.fd, &st) < 0) return 0;
    size[0] = @intCast(st.st_size);
    return 1;
}

fn doSeek(b: [*c]c.GstBaseSrc, seg: [*c]c.GstSegment) callconv(.c) c.gboolean {
    const s = me(b);
    const off = seg[0].start;
    if (off == s.curoffset) return 1;
    const r: c_int = @truncate(c.lseek(s.fd, @bitCast(off), c.SEEK_SET));
    if (r < 0 or @as(u64, @intCast(r)) != off) return 0;
    seg[0].position = seg[0].start;
    seg[0].time = seg[0].start;
    return 1;
}

fn uriType(_: c.GType) callconv(.c) c.GstURIType {
    return c.GST_URI_SRC;
}

fn uriProtocols(_: c.GType) callconv(.c) [*c]const [*c]const u8 {
    return @ptrCast(&protocols);
}

fn getUri(h: ?*c.GstURIHandler) callconv(.c) [*c]u8 {
    return c.g_strdup(me(h).uri);
}

fn sizeParam(uri: [*c]const u8) u64 {
    const q = c.g_strstr_len(uri, -1, "?");
    if (q == null) return NONE;
    var sp = c.g_strstr_len(q, -1, "size=");
    if (sp == null) return NONE;
    sp += 5;
    var end: [*c]u8 = null;
    std.c._errno().* = 0;
    const v = c.g_ascii_strtoull(sp, &end, 10);
    if ((v == 0 and errno() == c.EINVAL) or v == std.math.maxInt(u64) or end == sp) return NONE;
    return v;
}

fn setUri(h: ?*c.GstURIHandler, uri: [*c]const u8, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const s = me(h);
    const proto = c.gst_uri_get_protocol(uri);
    const ok = c.strcmp(proto, "fd") == 0;
    c.g_free(proto);
    if (!ok) {
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, "Wrong protocol for fdsrc in uri: '%s'", uri);
        return 0;
    }
    var fd: c_int = -1;
    if (c.sscanf(uri, "fd://%d", &fd) != 1 or fd < 0) {
        c.g_set_error(err, c.gst_uri_error_quark(), c.GST_URI_ERROR_BAD_URI, "Bad file descriptor number in uri: '%s'", uri);
        return 0;
    }
    const size = sizeParam(uri);
    s.new_fd = fd;
    cm.lock(s);
    if (state(s) <= c.GST_STATE_READY) updateFd(s, size);
    cm.unlock(s);
    return 1;
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
    c.g_object_class_install_property(oc, PROP_FD, c.g_param_spec_int("fd", "fd", "An open file descriptor to read from", 0, std.math.maxInt(c.gint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_TIMEOUT, c.g_param_spec_uint64("timeout", "Timeout", "Post a message after timeout microseconds (0 = disabled)", 0, std.math.maxInt(u64), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_IS_LIVE, c.g_param_spec_boolean("is-live", "is-live", "Act like a live source", 0, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Filedescriptor Source", "Source/File", "Read from a file descriptor", "Erik Walthinsen <omega@cse.ogi.edu>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.start = start;
    bc.stop = stop;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    bc.is_seekable = isSeekable;
    bc.get_size = getSize;
    bc.do_seek = doSeek;
    bc.query = query;
    const pc: *c.GstPushSrcClass = @ptrCast(@alignCast(k));
    pc.create = create;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.new_fd = 0;
    s.seekable_fd = 0;
    s.fd = -1;
    s.size = NONE;
    s.timeout = 0;
    s.uri = c.g_strdup_printf("fd://0");
    s.curoffset = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_push_src_get_type(), "GstFdSrc", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = uriInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_uri_handler_get_type(), &info);
            _ = c._gst_debug_category_new("fdsrc", 0, "fdsrc element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "fdsrc", c.GST_RANK_NONE, getType()) != 0;
}
