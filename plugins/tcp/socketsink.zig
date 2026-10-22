const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const tcp = @import("common.zig");
const mh = @import("multihandle.zig");

const FILE = "../gst/tcp/gstmultisocketsink.c";
const SERVER_FILE = "../gst/tcp/gsttcpserversink.c";
const PROP_SEND_DISPATCHED = 1;
const PROP_SEND_MESSAGES = 2;
const SERVER_PROP_HOST = 1;
const SERVER_PROP_PORT = 2;
const SERVER_PROP_CURRENT_PORT = 3;
const SERVER_BACKLOG = 5;
const CMSG_MAX = 255;
const ALL_CONDITIONS: c.GIOCondition = c.G_IO_IN | c.G_IO_OUT | c.G_IO_PRI | c.G_IO_ERR | c.G_IO_HUP;
const READ_CONDITIONS: c.GIOCondition = c.G_IO_IN | c.G_IO_PRI | c.G_IO_ERR | c.G_IO_HUP;

pub const Sink = extern struct {
    base: mh.Sink,
    main_context: ?*c.GMainContext,
    cancellable: ?*c.GCancellable,
    send_dispatched: c.gboolean,
    send_messages: c.gboolean,
};

pub const Class = extern struct {
    base: mh.Class,
    add: ?*const fn (*Sink, ?*c.GSocket) callconv(.c) void,
    add_full: ?*const fn (*Sink, ?*c.GSocket, c.gint, c.GstFormat, u64, c.GstFormat, u64) callconv(.c) void,
    remove: ?*const fn (*Sink, ?*c.GSocket) callconv(.c) void,
    remove_flush: ?*const fn (*Sink, ?*c.GSocket) callconv(.c) void,
    get_stats: ?*const fn (*Sink, ?*c.GSocket) callconv(.c) ?*c.GstStructure,
};

const Client = extern struct {
    base: mh.Client,
    source: ?*c.GSource,
    condition: c.GIOCondition,
};

const Server = extern struct {
    base: Sink,
    current_port: c.gint,
    server_port: c.gint,
    host: [*c]u8,
    server_socket: ?*c.GSocket,
    server_source: ?*c.GSource,
};

const ServerClass = extern struct {
    base: Class,
};

const SIG_ADD = 0;
const SIG_ADD_FULL = 1;
const SIG_REMOVE = 2;
const SIG_REMOVE_FLUSH = 3;
const SIG_GET_STATS = 4;
const SIG_CLIENT_ADDED = 5;
const SIG_CLIENT_REMOVED = 6;
const SIG_CLIENT_SOCKET_REMOVED = 7;

var signals = [_]c.guint{0} ** 8;
var once: cm.Once = .{};
var server_once: cm.Once = .{};
var parent: ?*mh.Class = null;
var server_parent: ?*Class = null;

fn me(p: anytype) *Sink {
    return @ptrCast(@alignCast(p));
}

fn handleOf(sock: ?*c.GSocket) mh.Handle {
    return .{ .pointer = sock };
}

fn socketOf(h: mh.Handle) ?*c.GSocket {
    return @ptrCast(@alignCast(h.pointer));
}

fn emitAdded(s: *mh.Sink, h: mh.Handle) callconv(.c) void {
    c.g_signal_emit(s, signals[SIG_CLIENT_ADDED], 0, socketOf(h));
}

fn emitRemoved(s: *mh.Sink, h: mh.Handle, status: c.gint) callconv(.c) void {
    c.g_signal_emit(s, signals[SIG_CLIENT_REMOVED], 0, socketOf(h), status);
}

fn addSocket(s: *Sink, sock: ?*c.GSocket) callconv(.c) void {
    mh.add(&s.base, handleOf(sock));
}

fn addFull(s: *Sink, sock: ?*c.GSocket, sync: c.gint, min_format: c.GstFormat, min_value: u64, max_format: c.GstFormat, max_value: u64) callconv(.c) void {
    mh.addFull(&s.base, handleOf(sock), sync, min_format, min_value, max_format, max_value);
}

fn removeSocket(s: *Sink, sock: ?*c.GSocket) callconv(.c) void {
    mh.remove(&s.base, handleOf(sock));
}

fn removeFlush(s: *Sink, sock: ?*c.GSocket) callconv(.c) void {
    mh.removeFlush(&s.base, handleOf(sock));
}

fn getStats(s: *Sink, sock: ?*c.GSocket) callconv(.c) ?*c.GstStructure {
    return mh.getStats(&s.base, handleOf(sock));
}

fn newClient(m: *mh.Sink, h: mh.Handle, sync_method: c.gint) callconv(.c) ?*mh.Client {
    const cl: *Client = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Client))));
    cl.base.handle = handleOf(@ptrCast(@alignCast(c.g_object_ref(h.pointer))));
    mh.clientInit(&cl.base, sync_method);
    handleDebug(h, &cl.base.debug);
    c.g_socket_set_blocking(socketOf(h), 0);
    hashAdding(m, &cl.base);
    _ = mh.setupDscpClient(m, &cl.base);
    return &cl.base;
}

fn clientFd(cl: *mh.Client) callconv(.c) c_int {
    return c.g_socket_get_fd(socketOf(cl.handle));
}

fn clientFree(m: *mh.Sink, cl: *mh.Client) callconv(.c) void {
    c.g_signal_emit(m, signals[SIG_CLIENT_SOCKET_REMOVED], 0, socketOf(cl.handle));
    c.g_object_unref(cl.handle.pointer);
}

fn handleDebug(h: mh.Handle, out: [*c]u8) callconv(.c) void {
    _ = c.g_snprintf(out, 30, "[socket %p]", h.pointer);
}

fn hashKey(h: mh.Handle) callconv(.c) ?*anyopaque {
    return h.pointer;
}

fn ensureCondition(s: *Sink, cl: *Client, condition: c.GIOCondition) void {
    if (cl.condition == condition) return;
    if (cl.source) |src| {
        c.g_source_destroy(src);
        c.g_source_unref(src);
    }
    var cond = condition;
    if (cond != 0 and s.main_context != null) {
        cl.source = c.g_socket_create_source(socketOf(cl.base.handle), cond, s.cancellable);
        c.g_source_set_callback(cl.source, @ptrCast(&socketCondition), c.gst_object_ref(s), c.gst_object_unref);
        _ = c.g_source_attach(cl.source, s.main_context);
    } else {
        cl.source = null;
        cond = 0;
    }
    cl.condition = cond;
}

fn hashAdding(m: *mh.Sink, cl: *mh.Client) callconv(.c) void {
    ensureCondition(me(m), @ptrCast(@alignCast(cl)), ALL_CONDITIONS);
}

fn hashRemoving(m: *mh.Sink, cl: *mh.Client) callconv(.c) void {
    ensureCondition(me(m), @ptrCast(@alignCast(cl)), 0);
}

fn stopSending(s: *Sink, cl: *Client) void {
    ensureCondition(s, cl, READ_CONDITIONS);
}

fn handleRead(s: *Sink, cl: *Client) bool {
    const sock = socketOf(cl.base.handle);
    var avail = c.g_socket_get_available_bytes(sock);
    if (avail < 0) return true;
    const event = s.send_messages != 0 and avail > 0;
    var dummy: [256]u8 = undefined;
    const mem: [*c]u8 = if (event) @ptrCast(c.g_malloc(@intCast(avail))) else &dummy;
    const room: isize = if (event) avail else dummy.len;
    var at = mem;
    var ok = true;
    var first = true;
    var err: [*c]c.GError = null;
    while (true) {
        const n = c.g_socket_receive(sock, @ptrCast(at), @intCast(@min(avail, room)), s.cancellable, &err);
        if (first and n == 0) {
            cl.base.status = mh.STATUS_CLOSED;
            ok = false;
            break;
        } else if (n < 0) {
            if (err.*.code == c.G_IO_ERROR_WOULD_BLOCK) break;
            cl.base.status = mh.STATUS_ERROR;
            ok = false;
            break;
        }
        avail -= n;
        if (event) at += @intCast(n);
        first = false;
        if (avail <= 0) break;
    }
    c.g_clear_error(&err);
    if (event) {
        if (ok) {
            const b = c.gst_buffer_new_wrapped(mem, @intCast(room));
            const st = c.gst_structure_new("GstNetworkMessage", "object", c.G_TYPE_OBJECT, sock, "buffer", c.gst_buffer_get_type(), b, @as(?*anyopaque, null));
            c.gst_buffer_unref(b);
            _ = c.gst_pad_push_event(@as(*c.GstBaseSink, @ptrCast(@alignCast(s))).sinkpad, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_UPSTREAM, st));
        } else c.g_free(mem);
    }
    return ok;
}

fn send(s: *Sink, sock: ?*c.GSocket, b: [*c]c.GstBuffer, offset: usize, err: [*c][*c]c.GError) isize {
    var maps: [8]c.GstMapInfo = undefined;
    var vec: [8]c.GOutputVector = std.mem.zeroes([8]c.GOutputVector);
    var idx: c.guint = 0;
    var len: c.guint = 0;
    var skip: usize = 0;
    if (c.gst_buffer_find_memory(b, offset, c.gst_buffer_get_size(b) - offset, &idx, &len, &skip) == 0) {
        c.g_log(null, c.G_LOG_LEVEL_ERROR, "Unable to map memory at offset %lu, buffer length is %lu", offset, c.gst_buffer_get_size(b));
        return -1;
    }
    var mapped: usize = 0;
    while (mapped < len and mapped < vec.len) : (mapped += 1) {
        const mem = c.gst_buffer_peek_memory(b, idx + @as(c.guint, @intCast(mapped)));
        maps[mapped] = std.mem.zeroes(c.GstMapInfo);
        _ = c.gst_memory_map(mem, &maps[mapped], c.GST_MAP_READ);
        const start: usize = if (mapped == 0) skip else 0;
        vec[mapped] = .{ .buffer = maps[mapped].data + start, .size = maps[mapped].size - start };
    }
    var msgs: [CMSG_MAX]?*c.GSocketControlMessage = undefined;
    var count: usize = 0;
    var state: c.gpointer = null;
    const api = c.gst_net_control_message_meta_api_get_type();
    while (count < CMSG_MAX) {
        const meta = c.gst_buffer_iterate_meta(b, &state);
        if (meta == null) break;
        if (meta.*.info.*.api == api) {
            msgs[count] = @as(*c.GstNetControlMessageMeta, @ptrCast(@alignCast(meta))).message;
            count += 1;
        }
    }
    const wrote = c.g_socket_send_message(sock, null, &vec, @intCast(mapped), @ptrCast(&msgs), @intCast(count), 0, s.cancellable, err);
    for (0..mapped) |i| c.gst_memory_unmap(maps[i].memory, &maps[i]);
    return wrote;
}

fn handleWrite(s: *Sink, cl: *Client) bool {
    const m = &s.base;
    const k = mh.klass(m);
    const t = @as(u64, @intCast(c.g_get_real_time())) * c.GST_USECOND;
    const tm = mh.monotonic();
    const flushing = cl.base.status == mh.STATUS_FLUSHING;
    var err: [*c]c.GError = null;
    while (true) {
        if (cl.base.sending == null) {
            if (cl.base.bufpos == -1) {
                stopSending(s, cl);
                if (cl.base.flushcount == 0) {
                    cl.base.status = mh.STATUS_REMOVED;
                    return false;
                }
                return true;
            }
            if (cl.base.new_connection != 0 and !flushing) {
                const pos = mh.newClientPosition(m, &cl.base);
                if (pos < 0) {
                    stopSending(s, cl);
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
        const wrote = send(s, socketOf(cl.base.handle), head, @intCast(cl.base.bufoffset), &err);
        if (wrote < 0) {
            if (c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_CLOSED) != 0) {
                cl.base.status = mh.STATUS_CLOSED;
                c.g_clear_error(&err);
                return false;
            } else if (c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_WOULD_BLOCK) != 0) {
                c.g_clear_error(&err);
                return true;
            }
            c.g_clear_error(&err);
            cl.base.status = mh.STATUS_ERROR;
            return false;
        }
        const left: isize = @as(isize, @intCast(c.gst_buffer_get_size(head))) - cl.base.bufoffset;
        if (wrote < left) {
            cl.base.bufoffset += @intCast(wrote);
        } else {
            if (s.send_dispatched != 0) {
                const st = c.gst_structure_new("GstNetworkMessageDispatched", "object", c.G_TYPE_OBJECT, socketOf(cl.base.handle), "buffer", c.gst_buffer_get_type(), head, @as(?*anyopaque, null));
                _ = c.gst_pad_push_event(@as(*c.GstBaseSink, @ptrCast(@alignCast(s))).sinkpad, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_UPSTREAM, st));
            }
            cl.base.sending = c.g_slist_remove(cl.base.sending, head);
            c.gst_buffer_unref(head);
            cl.base.bufoffset = 0;
        }
        cl.base.bytes_sent +%= @intCast(wrote);
        cl.base.last_activity_time = t;
        cl.base.last_activity_time_monotonic = tm;
        m.bytes_served +%= @intCast(wrote);
    }
}

fn socketCondition(sock: ?*c.GSocket, condition: c.GIOCondition, data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const m = &s.base;
    mh.clientsLock(m);
    defer mh.clientsUnlock(m);
    const link: [*c]c.GList = @ptrCast(@alignCast(c.g_hash_table_lookup(m.handle_hash, sock)));
    if (link == null) return 0;
    const cl: *Client = @ptrCast(@alignCast(link.*.data));
    if (cl.base.status != mh.STATUS_FLUSHING and cl.base.status != mh.STATUS_OK) {
        mh.removeClientLink(m, link);
        return 0;
    }
    if (condition & c.G_IO_ERR != 0) {
        cl.base.status = mh.STATUS_ERROR;
        mh.removeClientLink(m, link);
        return 0;
    } else if (condition & c.G_IO_HUP != 0) {
        cl.base.status = mh.STATUS_CLOSED;
        mh.removeClientLink(m, link);
        return 0;
    }
    if (condition & (c.G_IO_IN | c.G_IO_PRI) != 0 and !handleRead(s, cl)) {
        mh.removeClientLink(m, link);
        return 0;
    }
    if (condition & c.G_IO_OUT != 0 and !handleWrite(s, cl)) {
        mh.removeClientLink(m, link);
        return 0;
    }
    return 1;
}

fn timeoutFired(data: c.gpointer) callconv(.c) c.gboolean {
    const m: *mh.Sink = @ptrCast(@alignCast(data));
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
    return 0;
}

fn thread(m: *mh.Sink) callconv(.c) ?*anyopaque {
    const s = me(m);
    while (@atomicLoad(c.gboolean, &m.running, .seq_cst) != 0) {
        var timer: ?*c.GSource = null;
        if (m.timeout > 0) {
            timer = c.g_timeout_source_new(@intCast(m.timeout / @as(u64, c.GST_MSECOND)));
            c.g_source_set_callback(timer, timeoutFired, c.gst_object_ref(s), c.gst_object_unref);
            _ = c.g_source_attach(timer, s.main_context);
        }
        _ = c.g_main_context_iteration(s.main_context, 1);
        if (timer) |src| {
            c.g_source_destroy(src);
            c.g_source_unref(src);
        }
    }
    return null;
}

fn startPre(m: *mh.Sink) callconv(.c) c.gboolean {
    const s = me(m);
    s.main_context = c.g_main_context_new();
    mh.clientsLock(m);
    var l = m.clients;
    while (l != null) : (l = l.*.next) {
        const cl: *Client = @ptrCast(@alignCast(l.*.data));
        if (cl.source == null) hashAdding(m, &cl.base);
    }
    mh.clientsUnlock(m);
    return 1;
}

fn removeAll(_: c.gpointer, _: c.gpointer, _: c.gpointer) callconv(.c) c.gboolean {
    return 1;
}

fn stopPre(m: *mh.Sink) callconv(.c) void {
    if (me(m).main_context) |ctx| c.g_main_context_wakeup(ctx);
}

fn stopPost(m: *mh.Sink) callconv(.c) void {
    const s = me(m);
    if (s.main_context) |ctx| {
        c.g_main_context_unref(ctx);
        s.main_context = null;
    }
    _ = c.g_hash_table_foreach_remove(m.handle_hash, removeAll, s);
}

fn unlock(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = me(b);
    c.g_cancellable_cancel(s.cancellable);
    if (s.main_context) |ctx| c.g_main_context_wakeup(ctx);
    return 1;
}

fn unlockStop(b: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    const s = me(b);
    c.g_object_unref(s.cancellable);
    s.cancellable = c.g_cancellable_new();
    return 1;
}

fn proposeAllocation(_: [*c]c.GstBaseSink, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    c.gst_query_add_allocation_meta(q, c.gst_net_control_message_meta_api_get_type(), null);
    return 1;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SEND_DISPATCHED => s.send_dispatched = c.g_value_get_boolean(v),
        PROP_SEND_MESSAGES => s.send_messages = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 1187),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SEND_DISPATCHED => c.g_value_set_boolean(v, s.send_dispatched),
        PROP_SEND_MESSAGES => c.g_value_set_boolean(v, s.send_messages),
        else => cm.warnInvalid(FILE, o, id, spec, 1206),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.cancellable) |x| c.g_object_unref(x);
    s.cancellable = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const t = cm.typeOfClass(k);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.g_object_class_install_property(oc, PROP_SEND_DISPATCHED, c.g_param_spec_boolean("send-dispatched", "Send Dispatched", "If GstNetworkMessageDispatched events should be pushed", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_SEND_MESSAGES, c.g_param_spec_boolean("send-messages", "Send Messages", "If GstNetworkMessage events should be pushed", 0, cm.RW));
    const action = c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION;
    const sock = c.g_socket_get_type();
    signals[SIG_ADD] = c.g_signal_new("add", t, action, @offsetOf(Class, "add"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), sock);
    signals[SIG_ADD_FULL] = c.g_signal_new("add-full", t, action, @offsetOf(Class, "add_full"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 6), sock, mh.syncMethodType(), c.gst_format_get_type(), c.G_TYPE_UINT64, c.gst_format_get_type(), c.G_TYPE_UINT64);
    signals[SIG_REMOVE] = c.g_signal_new("remove", t, action, @offsetOf(Class, "remove"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), sock);
    signals[SIG_REMOVE_FLUSH] = c.g_signal_new("remove-flush", t, action, @offsetOf(Class, "remove_flush"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), sock);
    signals[SIG_GET_STATS] = c.g_signal_new("get-stats", t, action, @offsetOf(Class, "get_stats"), null, null, null, c.gst_structure_get_type(), @as(c.guint, 1), sock);
    signals[SIG_CLIENT_ADDED] = c.g_signal_new("client-added", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), c.G_TYPE_OBJECT);
    signals[SIG_CLIENT_REMOVED] = c.g_signal_new("client-removed", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, @as(c.guint, 2), sock, mh.clientStatusType());
    signals[SIG_CLIENT_SOCKET_REMOVED] = c.g_signal_new("client-socket-removed", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), sock);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Multi socket sink", "Sink/Network", "Send data to multiple sockets", "Thomas Vander Stichele <thomas at apestaart dot org>, Wim Taymans <wim@fluendo.com>, Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    bc.propose_allocation = proposeAllocation;
    const sc: *Class = @ptrCast(@alignCast(k));
    sc.add = addSocket;
    sc.add_full = addFull;
    sc.remove = removeSocket;
    sc.remove_flush = removeFlush;
    sc.get_stats = getStats;
    const mc: *mh.Class = &sc.base;
    mc.emit_client_added = emitAdded;
    mc.emit_client_removed = emitRemoved;
    mc.stop_pre = stopPre;
    mc.stop_post = stopPost;
    mc.start_pre = startPre;
    mc.thread = thread;
    mc.new_client = newClient;
    mc.client_get_fd = clientFd;
    mc.client_free = clientFree;
    mc.handle_debug = handleDebug;
    mc.handle_hash_key = hashKey;
    mc.hash_adding = hashAdding;
    mc.hash_removing = hashRemoving;
    _ = c._gst_debug_category_new("multisocketsink", 0, "Multi socket sink");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.base.handle_hash = c.g_hash_table_new(c.g_direct_hash, c.g_int_equal);
    s.cancellable = c.g_cancellable_new();
    s.send_dispatched = 0;
    s.send_messages = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(mh.getType(), "GstMultiSocketSink", Class, Sink, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    tcp.elementInit();
    return c.gst_element_register(p, "multisocketsink", c.GST_RANK_NONE, getType()) != 0;
}

fn server(p: anytype) *Server {
    return @ptrCast(@alignCast(p));
}

fn serverError(s: *Server, code: c.gint, debug: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), code, null, debug, SERVER_FILE, func, line);
}

fn serverCondition(_: ?*c.GSocket, condition: c.GIOCondition, data: c.gpointer) callconv(.c) c.gboolean {
    const s = server(data);
    if (condition & c.G_IO_ERR != 0) {
        serverError(s, c.GST_RESOURCE_ERROR_READ, c.g_strdup("client connection failed"), "gst_tcp_server_sink_socket_condition", 236);
        return 0;
    }
    if (condition & (c.G_IO_IN | c.G_IO_PRI) != 0) {
        var err: [*c]c.GError = null;
        const client = c.g_socket_accept(s.server_socket, s.base.cancellable, &err);
        if (client == null) {
            serverError(s, c.GST_RESOURCE_ERROR_OPEN_WRITE, c.g_strdup_printf("Could not accept client on server socket %p: %s", s.server_socket, err.*.message), "gst_tcp_server_sink_handle_server_read", 200);
            c.g_clear_error(&err);
            return 0;
        }
        mh.add(&s.base.base, handleOf(client));
        c.g_object_unref(client);
    }
    return 1;
}

fn serverClose(m: *mh.Sink) callconv(.c) c.gboolean {
    const s = server(m);
    if (s.server_source) |src| {
        c.g_source_destroy(src);
        c.g_source_unref(src);
        s.server_source = null;
    }
    if (s.server_socket) |sock| {
        var err: [*c]c.GError = null;
        if (c.g_socket_close(sock, &err) == 0) c.g_clear_error(&err);
        c.g_object_unref(sock);
        s.server_socket = null;
        @atomicStore(c.gint, &s.current_port, 0, .seq_cst);
        c.g_object_notify(@ptrCast(s), "current-port");
    }
    return 1;
}

fn serverRemoved(_: *mh.Sink, h: mh.Handle) callconv(.c) void {
    var err: [*c]c.GError = null;
    if (c.g_socket_close(socketOf(h), &err) == 0) c.g_clear_error(&err);
}

fn serverInitSend(m: *mh.Sink) callconv(.c) c.gboolean {
    const s = server(m);
    const func = "gst_tcp_server_sink_init_send";
    var err: [*c]c.GError = null;
    const addrs = tcp.getAddresses(s, s.host, s.base.cancellable, &err);
    if (addrs == null) {
        if (!tcp.isCancelled(err)) serverError(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf("Failed to resolve host '%s': %s", s.host, err.*.message), func, 379);
        c.g_clear_error(&err);
        return 0;
    }
    var cur = addrs;
    var saddr: ?*c.GSocketAddress = null;
    s.server_socket = tcp.createSocket(s, &cur, @intCast(s.server_port), &saddr, &err);
    c.g_list_free_full(addrs, c.g_object_unref);
    if (s.server_socket == null) {
        serverError(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf("Failed to create socket: %s", err.*.message), func, 369);
        c.g_clear_error(&err);
        return 0;
    }
    c.g_socket_set_blocking(s.server_socket, 0);
    if (c.g_socket_bind(s.server_socket, saddr, 1, &err) == 0) {
        if (!tcp.isCancelled(err)) serverError(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf("Failed to bind on host '%s:%d': %s", s.host, s.server_port, err.*.message), func, 390);
        c.g_clear_error(&err);
        c.g_object_unref(saddr);
        _ = serverClose(m);
        return 0;
    }
    c.g_object_unref(saddr);
    c.g_socket_set_listen_backlog(s.server_socket, SERVER_BACKLOG);
    if (c.g_socket_listen(s.server_socket, &err) == 0) {
        if (!tcp.isCancelled(err)) serverError(s, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf("Failed to listen on host '%s:%d': %s", s.host, s.server_port, err.*.message), func, 404);
        c.g_clear_error(&err);
        _ = serverClose(m);
        return 0;
    }
    var bound = s.server_port;
    if (bound == 0) {
        const local = c.g_socket_get_local_address(s.server_socket, null);
        bound = c.g_inet_socket_address_get_port(@ptrCast(local));
        c.g_object_unref(local);
    }
    @atomicStore(c.gint, &s.current_port, bound, .seq_cst);
    c.g_object_notify(@ptrCast(s), "current-port");
    s.server_source = c.g_socket_create_source(s.server_socket, ALL_CONDITIONS, s.base.cancellable);
    c.g_source_set_callback(s.server_source, @ptrCast(&serverCondition), c.gst_object_ref(s), c.gst_object_unref);
    _ = c.g_source_attach(s.server_source, s.base.main_context);
    return 1;
}

fn serverSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = server(o);
    switch (id) {
        SERVER_PROP_HOST => {
            if (c.g_value_get_string(v) == null) {
                c.g_log(null, c.G_LOG_LEVEL_WARNING, "host property cannot be NULL");
                return;
            }
            c.g_free(s.host);
            s.host = c.g_value_dup_string(v);
        },
        SERVER_PROP_PORT => s.server_port = c.g_value_get_int(v),
        else => cm.warnInvalid(SERVER_FILE, o, id, spec, 263),
    }
}

fn serverGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = server(o);
    switch (id) {
        SERVER_PROP_HOST => c.g_value_set_string(v, s.host),
        SERVER_PROP_PORT => c.g_value_set_int(v, s.server_port),
        SERVER_PROP_CURRENT_PORT => c.g_value_set_int(v, @atomicLoad(c.gint, &s.current_port, .seq_cst)),
        else => cm.warnInvalid(SERVER_FILE, o, id, spec, 287),
    }
}

fn serverFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s = server(o);
    if (s.server_socket) |x| c.g_object_unref(x);
    s.server_socket = null;
    c.g_free(s.host);
    s.host = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(server_parent.?))).finalize.?(o);
}

fn serverClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    server_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = serverSetProperty;
    oc.get_property = serverGetProperty;
    oc.finalize = serverFinalize;
    c.g_object_class_install_property(oc, SERVER_PROP_HOST, c.g_param_spec_string("host", "host", "The host/IP to listen on", tcp.DEFAULT_HOST, cm.RW));
    c.g_object_class_install_property(oc, SERVER_PROP_PORT, c.g_param_spec_int("port", "port", "The port to listen to (0=random available port)", 0, tcp.HIGHEST_PORT, tcp.DEFAULT_PORT, cm.RW));
    c.g_object_class_install_property(oc, SERVER_PROP_CURRENT_PORT, c.g_param_spec_int("current-port", "current-port", "The port number the socket is currently bound to", 0, tcp.HIGHEST_PORT, 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "TCP server sink", "Sink/Network", "Send data as a server over the network via TCP", "Thomas Vander Stichele <thomas at apestaart dot org>");
    const mc: *mh.Class = @ptrCast(@alignCast(k));
    mc.init = serverInitSend;
    mc.close = serverClose;
    mc.removed = serverRemoved;
    _ = c._gst_debug_category_new("tcpserversink", 0, "TCP sink");
}

fn serverInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = server(inst);
    s.server_port = tcp.DEFAULT_PORT;
    s.host = c.g_strdup(tcp.DEFAULT_HOST);
    s.server_socket = null;
}

pub fn serverType() c.GType {
    return server_once.get(struct {
        fn f() c.GType {
            return cm.register(getType(), "GstTCPServerSink", ServerClass, Server, serverClassInit, serverInit);
        }
    }.f);
}

pub fn registerServer(p: ?*c.GstPlugin) bool {
    tcp.elementInit();
    return c.gst_element_register(p, "tcpserversink", c.GST_RANK_NONE, serverType()) != 0;
}
