const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const tcp = @import("common.zig");
const mh = @import("multihandle.zig");

const FILE = "../gst/tcp/gstmultifdsink.c";
const PROP_HANDLE_READ = 1;

const Sink = extern struct {
    base: mh.Sink,
    fdset: ?*c.GstPoll,
    handle_read: c.gboolean,
};

const Class = extern struct {
    base: mh.Class,
    add: ?*const fn (*Sink, c_int) callconv(.c) void,
    add_full: ?*const fn (*Sink, c_int, c.gint, c.GstFormat, u64, c.GstFormat, u64) callconv(.c) void,
    remove: ?*const fn (*Sink, c_int) callconv(.c) void,
    remove_flush: ?*const fn (*Sink, c_int) callconv(.c) void,
    get_stats: ?*const fn (*Sink, c_int) callconv(.c) ?*c.GstStructure,
    wait: ?*const fn (*Sink, ?*c.GstPoll) callconv(.c) void,
};

const Client = extern struct {
    base: mh.Client,
    gfd: c.GstPollFD,
    is_socket: c.gboolean,
};

const SIG_ADD = 0;
const SIG_ADD_FULL = 1;
const SIG_REMOVE = 2;
const SIG_REMOVE_FLUSH = 3;
const SIG_GET_STATS = 4;
const SIG_CLIENT_ADDED = 5;
const SIG_CLIENT_REMOVED = 6;
const SIG_CLIENT_FD_REMOVED = 7;

var signals = [_]c.guint{0} ** 8;
var once: cm.Once = .{};

fn me(p: anytype) *Sink {
    return @ptrCast(@alignCast(p));
}

fn handleOf(fd: c_int) mh.Handle {
    var h: mh.Handle = .{ .pointer = null };
    h.fd = fd;
    return h;
}

fn emitAdded(s: *mh.Sink, h: mh.Handle) callconv(.c) void {
    c.g_signal_emit(s, signals[SIG_CLIENT_ADDED], 0, h.fd);
}

fn emitRemoved(s: *mh.Sink, h: mh.Handle, status: c.gint) callconv(.c) void {
    c.g_signal_emit(s, signals[SIG_CLIENT_REMOVED], 0, h.fd, status);
}

fn clientFree(m: *mh.Sink, cl: *mh.Client) callconv(.c) void {
    c.g_signal_emit(m, signals[SIG_CLIENT_FD_REMOVED], 0, cl.handle.fd);
}

fn addFd(s: *Sink, fd: c_int) callconv(.c) void {
    mh.add(&s.base, handleOf(fd));
}

fn addFull(s: *Sink, fd: c_int, sync: c.gint, min_format: c.GstFormat, min_value: u64, max_format: c.GstFormat, max_value: u64) callconv(.c) void {
    mh.addFull(&s.base, handleOf(fd), sync, min_format, min_value, max_format, max_value);
}

fn removeFd(s: *Sink, fd: c_int) callconv(.c) void {
    mh.remove(&s.base, handleOf(fd));
}

fn removeFlush(s: *Sink, fd: c_int) callconv(.c) void {
    mh.removeFlush(&s.base, handleOf(fd));
}

fn getStats(s: *Sink, fd: c_int) callconv(.c) ?*c.GstStructure {
    return mh.getStats(&s.base, handleOf(fd));
}

fn newClient(m: *mh.Sink, h: mh.Handle, sync_method: c.gint) callconv(.c) ?*mh.Client {
    const s = me(m);
    const cl: *Client = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Client))));
    cl.base.handle = h;
    c.gst_poll_fd_init(&cl.gfd);
    cl.gfd.fd = h.fd;
    mh.clientInit(&cl.base, sync_method);
    handleDebug(h, &cl.base.debug);
    _ = c.fcntl(h.fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK));
    _ = c.gst_poll_add_fd(s.fdset, &cl.gfd);
    if (s.handle_read != 0) {
        const flags = c.fcntl(h.fd, c.F_GETFL, @as(c_int, 0));
        if ((flags & c.O_ACCMODE) != c.O_WRONLY) _ = c.gst_poll_fd_ctl_read(s.fdset, &cl.gfd, 1);
    }
    var st: c.struct_stat = undefined;
    if (c.fstat(h.fd, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFSOCK) {
        cl.is_socket = 1;
        _ = mh.setupDscpClient(m, &cl.base);
    }
    return &cl.base;
}

fn clientFd(cl: *mh.Client) callconv(.c) c_int {
    return @as(*Client, @ptrCast(@alignCast(cl))).gfd.fd;
}

fn handleDebug(h: mh.Handle, out: [*c]u8) callconv(.c) void {
    _ = c.g_snprintf(out, 30, "[fd %5d]", h.fd);
}

fn hashKey(h: mh.Handle) callconv(.c) ?*anyopaque {
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, h.fd))));
}

fn hashChanged(m: *mh.Sink) callconv(.c) void {
    c.gst_poll_restart(me(m).fdset);
}

fn hashAdding(m: *mh.Sink, cl: *mh.Client) callconv(.c) void {
    _ = c.gst_poll_fd_ctl_write(me(m).fdset, &@as(*Client, @ptrCast(@alignCast(cl))).gfd, 1);
}

fn hashRemoving(m: *mh.Sink, cl: *mh.Client) callconv(.c) void {
    _ = c.gst_poll_remove_fd(me(m).fdset, &@as(*Client, @ptrCast(@alignCast(cl))).gfd);
}

fn handleRead(cl: *Client) bool {
    const fd = cl.gfd.fd;
    var avail: c_int = 0;
    if (c.ioctl(fd, c.FIONREAD, &avail) < 0) {
        cl.base.status = mh.STATUS_ERROR;
        return false;
    }
    if (avail == 0) {
        cl.base.status = mh.STATUS_CLOSED;
        return false;
    }
    if (avail < 0) {
        cl.base.status = mh.STATUS_ERROR;
        return false;
    }
    var dummy: [512]u8 = undefined;
    while (avail > 0) {
        const n = c.read(fd, &dummy, @intCast(@min(avail, dummy.len)));
        if (n < -1) {
            cl.base.status = mh.STATUS_ERROR;
            return false;
        } else if (n == 0) {
            cl.base.status = mh.STATUS_ERROR;
            return false;
        }
        avail -= @intCast(n);
    }
    return true;
}

fn handleWrite(s: *Sink, cl: *Client) bool {
    const m = &s.base;
    const k = mh.klass(m);
    const fd = cl.base.handle.fd;
    const flushing = cl.base.status == mh.STATUS_FLUSHING;
    while (true) {
        const t = @as(u64, @intCast(c.g_get_real_time())) * c.GST_USECOND;
        const tm = mh.monotonic();
        if (cl.base.sending == null) {
            if (cl.base.bufpos == -1) {
                _ = c.gst_poll_fd_ctl_write(s.fdset, &cl.gfd, 0);
                if (cl.base.flushcount == 0) {
                    cl.base.status = mh.STATUS_REMOVED;
                    return false;
                }
                return true;
            }
            if (cl.base.new_connection != 0 and !flushing) {
                const pos = mh.newClientPosition(m, &cl.base);
                if (pos < 0) {
                    _ = c.gst_poll_fd_ctl_write(s.fdset, &cl.gfd, 0);
                    return true;
                }
                cl.base.new_connection = 0;
                cl.base.bufpos = pos;
            }
            if (cl.base.flushcount == 0) {
                cl.base.status = mh.STATUS_REMOVED;
                return false;
            }
            const b = @as([*c][*c]c.GstBuffer, @ptrCast(@alignCast(m.bufqueue.*.data)))[@intCast(cl.base.bufpos)];
            cl.base.bufpos -= 1;
            const ts = cm.buf(b).pts;
            if (cl.base.first_buffer_ts == c.GST_CLOCK_TIME_NONE) cl.base.first_buffer_ts = ts;
            if (ts != c.GST_CLOCK_TIME_NONE) cl.base.last_buffer_ts = ts;
            if (cl.base.flushcount != -1) cl.base.flushcount -= 1;
            _ = k.client_queue_buffer.?(m, &cl.base, b);
            cl.base.bufoffset = 0;
        }
        if (cl.base.sending == null) continue;
        const head: [*c]c.GstBuffer = @ptrCast(@alignCast(cl.base.sending.*.data));
        var map: c.GstMapInfo = undefined;
        if (c.gst_buffer_map(head, &map, c.GST_MAP_READ) == 0) return false;
        const left: usize = map.size - @as(usize, @intCast(cl.base.bufoffset));
        const at = map.data + @as(usize, @intCast(cl.base.bufoffset));
        const wrote: isize = if (cl.is_socket != 0) c.send(fd, at, left, c.MSG_NOSIGNAL) else c.write(fd, at, left);
        const errno = std.c._errno().*;
        c.gst_buffer_unmap(head, &map);
        if (wrote < 0) {
            if (errno == @intFromEnum(std.posix.E.AGAIN)) return true;
            cl.base.status = if (errno == @intFromEnum(std.posix.E.CONNRESET)) mh.STATUS_CLOSED else mh.STATUS_ERROR;
            return false;
        }
        var more = true;
        if (@as(usize, @intCast(wrote)) < left) {
            cl.base.bufoffset += @intCast(wrote);
            more = false;
        } else {
            cl.base.sending = c.g_slist_remove(cl.base.sending, head);
            c.gst_buffer_unref(head);
            cl.base.bufoffset = 0;
        }
        cl.base.bytes_sent +%= @intCast(wrote);
        cl.base.last_activity_time = t;
        cl.base.last_activity_time_monotonic = tm;
        m.bytes_served +%= @intCast(wrote);
        if (!more) return true;
    }
}

fn handleClients(s: *Sink) void {
    const m = &s.base;
    while (true) {
        const result = c.gst_poll_wait(s.fdset, if (m.timeout != 0) m.timeout else c.GST_CLOCK_TIME_NONE);
        if (result == 0) {
            const t = mh.monotonic();
            mh.clientsLock(m);
            var l = m.clients;
            while (l != null) {
                const next = l.*.next;
                const cl: *mh.Client = @ptrCast(@alignCast(l.*.data));
                if (m.timeout > 0 and t -% cl.last_activity_time_monotonic > m.timeout) {
                    cl.status = mh.STATUS_SLOW;
                    mh.removeClientLink(m, l);
                }
                l = next;
            }
            mh.clientsUnlock(m);
            return;
        } else if (result < 0) {
            const errno = std.c._errno().*;
            if (errno == @intFromEnum(std.posix.E.BADF)) {
                mh.clientsLock(m);
                restart: while (true) {
                    const cookie = m.clients_cookie;
                    var l = m.clients;
                    while (l != null) {
                        if (cookie != m.clients_cookie) continue :restart;
                        const next = l.*.next;
                        const cl: *Client = @ptrCast(@alignCast(l.*.data));
                        if (c.fcntl(cl.gfd.fd, c.F_GETFL) == -1 and std.c._errno().* == @intFromEnum(std.posix.E.BADF)) {
                            cl.base.status = mh.STATUS_ERROR;
                            mh.removeClientLink(m, l);
                        }
                        l = next;
                    }
                    break;
                }
                mh.clientsUnlock(m);
                continue;
            } else if (errno == @intFromEnum(std.posix.E.INTR)) {
                continue;
            } else if (errno == @intFromEnum(std.posix.E.BUSY)) {
                return;
            }
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_READ, null, c.g_strdup_printf("select failed: %s (%d)", c.g_strerror(errno), errno), FILE, "gst_multi_fd_sink_handle_clients", 979);
            return;
        }
        break;
    }
    const k: *Class = @ptrCast(@alignCast(mh.klass(m)));
    if (k.wait) |f| f(s, s.fdset);
    mh.clientsLock(m);
    defer mh.clientsUnlock(m);
    restart: while (true) {
        const cookie = m.clients_cookie;
        var l = m.clients;
        while (l != null) {
            if (cookie != m.clients_cookie) continue :restart;
            const next = l.*.next;
            const cl: *Client = @ptrCast(@alignCast(l.*.data));
            defer l = next;
            if (cl.base.status != mh.STATUS_FLUSHING and cl.base.status != mh.STATUS_OK) {
                mh.removeClientLink(m, l);
                continue;
            }
            if (c.gst_poll_fd_has_closed(s.fdset, &cl.gfd) != 0) {
                cl.base.status = mh.STATUS_CLOSED;
                mh.removeClientLink(m, l);
                continue;
            }
            if (c.gst_poll_fd_has_error(s.fdset, &cl.gfd) != 0) {
                cl.base.status = mh.STATUS_ERROR;
                mh.removeClientLink(m, l);
                continue;
            }
            if (c.gst_poll_fd_can_read(s.fdset, &cl.gfd) != 0 and !handleRead(cl)) {
                mh.removeClientLink(m, l);
                continue;
            }
            if (c.gst_poll_fd_can_write(s.fdset, &cl.gfd) != 0 and !handleWrite(s, cl)) {
                mh.removeClientLink(m, l);
                continue;
            }
        }
        break;
    }
}

fn thread(m: *mh.Sink) callconv(.c) ?*anyopaque {
    while (@atomicLoad(c.gboolean, &m.running, .seq_cst) != 0) handleClients(me(m));
    return null;
}

fn startPre(m: *mh.Sink) callconv(.c) c.gboolean {
    const s = me(m);
    s.fdset = c.gst_poll_new(1);
    if (s.fdset == null) {
        const errno = std.c._errno().*;
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ_WRITE, null, c.g_strdup_printf("system error: %s", c.g_strerror(errno)), FILE, "gst_multi_fd_sink_start_pre", 1111);
        return 0;
    }
    return 1;
}

fn removeAll(_: c.gpointer, _: c.gpointer, _: c.gpointer) callconv(.c) c.gboolean {
    return 1;
}

fn stopPre(m: *mh.Sink) callconv(.c) void {
    c.gst_poll_set_flushing(me(m).fdset, 1);
}

fn stopPost(m: *mh.Sink) callconv(.c) void {
    const s = me(m);
    if (s.fdset) |set| {
        c.gst_poll_free(set);
        s.fdset = null;
    }
    _ = c.g_hash_table_foreach_remove(m.handle_hash, removeAll, s);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_HANDLE_READ => me(o).handle_read = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 1072),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        PROP_HANDLE_READ => c.g_value_set_boolean(v, me(o).handle_read),
        else => cm.warnInvalid(FILE, o, id, spec, 1091),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const t = cm.typeOfClass(k);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_HANDLE_READ, c.g_param_spec_boolean("handle-read", "Handle Read", "Handle client reads and discard the data", 1, cm.RW));
    const action = c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION;
    signals[SIG_ADD] = c.g_signal_new("add", t, action, @offsetOf(Class, "add"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), c.G_TYPE_INT);
    signals[SIG_ADD_FULL] = c.g_signal_new("add-full", t, action, @offsetOf(Class, "add_full"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 6), c.G_TYPE_INT, mh.syncMethodType(), c.gst_format_get_type(), c.G_TYPE_UINT64, c.gst_format_get_type(), c.G_TYPE_UINT64);
    signals[SIG_REMOVE] = c.g_signal_new("remove", t, action, @offsetOf(Class, "remove"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), c.G_TYPE_INT);
    signals[SIG_REMOVE_FLUSH] = c.g_signal_new("remove-flush", t, action, @offsetOf(Class, "remove_flush"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), c.G_TYPE_INT);
    signals[SIG_GET_STATS] = c.g_signal_new("get-stats", t, action, @offsetOf(Class, "get_stats"), null, null, null, c.gst_structure_get_type(), @as(c.guint, 1), c.G_TYPE_INT);
    signals[SIG_CLIENT_ADDED] = c.g_signal_new("client-added", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), c.G_TYPE_INT);
    signals[SIG_CLIENT_REMOVED] = c.g_signal_new("client-removed", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, @as(c.guint, 2), c.G_TYPE_INT, mh.clientStatusType());
    signals[SIG_CLIENT_FD_REMOVED] = c.g_signal_new("client-fd-removed", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), c.G_TYPE_INT);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Multi filedescriptor sink", "Sink/Network", "Send data to multiple filedescriptors", "Thomas Vander Stichele <thomas at apestaart dot org>, Wim Taymans <wim@fluendo.com>");
    const fc: *Class = @ptrCast(@alignCast(k));
    fc.add = addFd;
    fc.add_full = addFull;
    fc.remove = removeFd;
    fc.remove_flush = removeFlush;
    fc.get_stats = getStats;
    const mc: *mh.Class = &fc.base;
    mc.emit_client_added = emitAdded;
    mc.emit_client_removed = emitRemoved;
    mc.stop_pre = stopPre;
    mc.stop_post = stopPost;
    mc.start_pre = startPre;
    mc.thread = thread;
    mc.new_client = newClient;
    mc.client_free = clientFree;
    mc.client_get_fd = clientFd;
    mc.handle_debug = handleDebug;
    mc.handle_hash_key = hashKey;
    mc.hash_changed = hashChanged;
    mc.hash_adding = hashAdding;
    mc.hash_removing = hashRemoving;
    _ = c._gst_debug_category_new("multifdsink", 0, "FD sink");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.base.handle_hash = c.g_hash_table_new(c.g_direct_hash, c.g_direct_equal);
    s.handle_read = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(mh.getType(), "GstMultiFdSink", Class, Sink, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    tcp.elementInit();
    return c.gst_element_register(p, "multifdsink", c.GST_RANK_NONE, getType()) != 0;
}
