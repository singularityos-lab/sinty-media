const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/tcp/gstmultihandlesink.c";

pub const OPEN: c.guint = c.GST_ELEMENT_FLAG_LAST;

pub const RECOVER_NONE = 0;
pub const RECOVER_LATEST = 1;
pub const RECOVER_SOFT_LIMIT = 2;
pub const RECOVER_KEYFRAME = 3;

pub const SYNC_LATEST = 0;
pub const SYNC_NEXT_KEYFRAME = 1;
pub const SYNC_LATEST_KEYFRAME = 2;
pub const SYNC_BURST = 3;
pub const SYNC_BURST_KEYFRAME = 4;
pub const SYNC_BURST_WITH_KEYFRAME = 5;

pub const STATUS_OK = 0;
pub const STATUS_CLOSED = 1;
pub const STATUS_REMOVED = 2;
pub const STATUS_SLOW = 3;
pub const STATUS_ERROR = 4;
pub const STATUS_DUPLICATE = 5;
pub const STATUS_FLUSHING = 6;

const PROP_BUFFERS_QUEUED = 1;
const PROP_BYTES_QUEUED = 2;
const PROP_TIME_QUEUED = 3;
const PROP_UNIT_FORMAT = 4;
const PROP_UNITS_MAX = 5;
const PROP_UNITS_SOFT_MAX = 6;
const PROP_BUFFERS_MAX = 7;
const PROP_BUFFERS_SOFT_MAX = 8;
const PROP_TIME_MIN = 9;
const PROP_BYTES_MIN = 10;
const PROP_BUFFERS_MIN = 11;
const PROP_RECOVER_POLICY = 12;
const PROP_TIMEOUT = 13;
const PROP_SYNC_METHOD = 14;
const PROP_BYTES_TO_SERVE = 15;
const PROP_BYTES_SERVED = 16;
const PROP_BURST_FORMAT = 17;
const PROP_BURST_VALUE = 18;
const PROP_QOS_DSCP = 19;
const PROP_RESEND_STREAMHEADER = 20;
const PROP_NUM_HANDLES = 21;

pub const Handle = extern union {
    pointer: ?*anyopaque,
    fd: c_int,
};

pub const Client = extern struct {
    handle: Handle,
    debug: [30]u8,
    bufpos: c.gint,
    flushcount: c.gint,
    status: c.gint,
    sending: [*c]c.GSList,
    bufoffset: c.gint,
    discont: c.gboolean,
    new_connection: c.gboolean,
    currently_removing: c.gboolean,
    sync_method: c.gint,
    burst_min_format: c.GstFormat,
    burst_min_value: u64,
    burst_max_format: c.GstFormat,
    burst_max_value: u64,
    caps: [*c]c.GstCaps,
    bytes_sent: u64,
    connect_time: u64,
    connect_time_monotonic: u64,
    disconnect_time: u64,
    disconnect_time_monotonic: u64,
    last_activity_time: u64,
    last_activity_time_monotonic: u64,
    dropped_buffers: u64,
    avg_queue_size: u64,
    first_buffer_ts: u64,
    last_buffer_ts: u64,
};

pub const Sink = extern struct {
    parent: c.GstBaseSink,
    bytes_to_serve: u64,
    bytes_served: u64,
    clientslock: c.GRecMutex,
    clients: [*c]c.GList,
    clients_cookie: c.guint,
    handle_hash: ?*c.GHashTable,
    qos_dscp: c.gint,
    bufqueue: [*c]c.GArray,
    running: c.gboolean,
    thread: ?*c.GThread,
    unit_format: c.GstFormat,
    units_max: i64,
    units_soft_max: i64,
    recover_policy: c.gint,
    timeout: u64,
    def_sync_method: c.gint,
    def_burst_format: c.GstFormat,
    def_burst_value: u64,
    bytes_min: c.gint,
    time_min: i64,
    buffers_min: c.gint,
    resend_streamheader: c.gboolean,
    buffers_queued: c.gint,
    bytes_queued: c.gint,
    time_queued: c.gint,
};

pub const Class = extern struct {
    parent: c.GstBaseSinkClass,
    clear: ?*const fn (*Sink) callconv(.c) void,
    stop_pre: ?*const fn (*Sink) callconv(.c) void,
    stop_post: ?*const fn (*Sink) callconv(.c) void,
    start_pre: ?*const fn (*Sink) callconv(.c) c.gboolean,
    thread: ?*const fn (*Sink) callconv(.c) ?*anyopaque,
    client_queue_buffer: ?*const fn (*Sink, *Client, [*c]c.GstBuffer) callconv(.c) c.gboolean,
    client_get_fd: ?*const fn (*Client) callconv(.c) c_int,
    client_free: ?*const fn (*Sink, *Client) callconv(.c) void,
    handle_debug: ?*const fn (Handle, [*c]u8) callconv(.c) void,
    handle_hash_key: ?*const fn (Handle) callconv(.c) ?*anyopaque,
    hash_changed: ?*const fn (*Sink) callconv(.c) void,
    hash_adding: ?*const fn (*Sink, *Client) callconv(.c) void,
    hash_removing: ?*const fn (*Sink, *Client) callconv(.c) void,
    new_client: ?*const fn (*Sink, Handle, c.gint) callconv(.c) ?*Client,
    init: ?*const fn (*Sink) callconv(.c) c.gboolean,
    close: ?*const fn (*Sink) callconv(.c) c.gboolean,
    removed: ?*const fn (*Sink, Handle) callconv(.c) void,
    emit_client_added: ?*const fn (*Sink, Handle) callconv(.c) void,
    emit_client_removed: ?*const fn (*Sink, Handle, c.gint) callconv(.c) void,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var recover_once: cm.Once = .{};
var sync_once: cm.Once = .{};
var status_once: cm.Once = .{};
var parent: ?*c.GstBaseSinkClass = null;
var sig_clear: c.guint = 0;

const recover_values = [_]c.GEnumValue{
    .{ .value = RECOVER_NONE, .value_name = "Do not try to recover", .value_nick = "none" },
    .{ .value = RECOVER_LATEST, .value_name = "Resync client to latest buffer", .value_nick = "latest" },
    .{ .value = RECOVER_SOFT_LIMIT, .value_name = "Resync client to soft limit", .value_nick = "soft-limit" },
    .{ .value = RECOVER_KEYFRAME, .value_name = "Resync client to most recent keyframe", .value_nick = "keyframe" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

const sync_values = [_]c.GEnumValue{
    .{ .value = SYNC_LATEST, .value_name = "Serve starting from the latest buffer", .value_nick = "latest" },
    .{ .value = SYNC_NEXT_KEYFRAME, .value_name = "Serve starting from the next keyframe", .value_nick = "next-keyframe" },
    .{ .value = SYNC_LATEST_KEYFRAME, .value_name = "Serve everything since the latest keyframe (burst)", .value_nick = "latest-keyframe" },
    .{ .value = SYNC_BURST, .value_name = "Serve burst-value data to client", .value_nick = "burst" },
    .{ .value = SYNC_BURST_KEYFRAME, .value_name = "Serve burst-value data starting on a keyframe", .value_nick = "burst-keyframe" },
    .{ .value = SYNC_BURST_WITH_KEYFRAME, .value_name = "Serve burst-value data preferably starting on a keyframe", .value_nick = "burst-with-keyframe" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

const status_values = [_]c.GEnumValue{
    .{ .value = STATUS_OK, .value_name = "ok", .value_nick = "ok" },
    .{ .value = STATUS_CLOSED, .value_name = "Closed", .value_nick = "closed" },
    .{ .value = STATUS_REMOVED, .value_name = "Removed", .value_nick = "removed" },
    .{ .value = STATUS_SLOW, .value_name = "Too slow", .value_nick = "slow" },
    .{ .value = STATUS_ERROR, .value_name = "Error", .value_nick = "error" },
    .{ .value = STATUS_DUPLICATE, .value_name = "Duplicate", .value_nick = "duplicate" },
    .{ .value = STATUS_FLUSHING, .value_name = "Flushing", .value_nick = "flushing" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

pub fn recoverPolicyType() c.GType {
    return recover_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstMultiHandleSinkRecoverPolicy", &recover_values);
        }
    }.f);
}

pub fn syncMethodType() c.GType {
    return sync_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstMultiHandleSinkSyncMethod", &sync_values);
        }
    }.f);
}

pub fn clientStatusType() c.GType {
    return status_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstMultiHandleSinkClientStatus", &status_values);
        }
    }.f);
}

pub fn me(p: anytype) *Sink {
    return @ptrCast(@alignCast(p));
}

pub fn klass(s: *Sink) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(s))).g_class));
}

pub fn clientsLock(s: *Sink) void {
    c.g_rec_mutex_lock(&s.clientslock);
}

pub fn clientsUnlock(s: *Sink) void {
    c.g_rec_mutex_unlock(&s.clientslock);
}

fn now() u64 {
    return @as(u64, @intCast(c.g_get_real_time())) * c.GST_USECOND;
}

pub fn monotonic() u64 {
    return @as(u64, @intCast(c.g_get_monotonic_time())) * c.GST_USECOND;
}

fn queued(s: *Sink, i: c.guint) [*c]c.GstBuffer {
    return @as([*c][*c]c.GstBuffer, @ptrCast(@alignCast(s.bufqueue.*.data)))[i];
}

fn isDelta(b: [*c]c.GstBuffer) bool {
    return (@as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags & c.GST_BUFFER_FLAG_DELTA_UNIT) != 0;
}

pub fn clientInit(cl: *Client, sync_method: c.gint) void {
    cl.status = STATUS_OK;
    cl.bufpos = -1;
    cl.flushcount = -1;
    cl.bufoffset = 0;
    cl.sending = null;
    cl.bytes_sent = 0;
    cl.dropped_buffers = 0;
    cl.avg_queue_size = 0;
    cl.first_buffer_ts = c.GST_CLOCK_TIME_NONE;
    cl.last_buffer_ts = c.GST_CLOCK_TIME_NONE;
    cl.new_connection = 1;
    cl.sync_method = sync_method;
    cl.currently_removing = 0;
    cl.connect_time = now();
    cl.connect_time_monotonic = monotonic();
    cl.disconnect_time = 0;
    cl.disconnect_time_monotonic = 0;
    cl.last_activity_time = cl.connect_time;
    cl.last_activity_time_monotonic = cl.connect_time_monotonic;
}

pub fn setupDscpClient(s: *Sink, cl: *Client) c_int {
    if (s.qos_dscp < 0) return 0;
    const fd = klass(s).client_get_fd.?(cl);
    var sa: c.struct_sockaddr_storage = undefined;
    var len: c.socklen_t = @sizeOf(c.struct_sockaddr_storage);
    const r = c.getsockname(fd, .{ .__sockaddr__ = @ptrCast(&sa) }, &len);
    if (r < 0) return r;
    var family: c_int = sa.ss_family;
    if (family == c.AF_INET6) {
        const in6: *c.struct_sockaddr_in6 = @ptrCast(@alignCast(&sa));
        const b = in6.sin6_addr.__in6_u.__u6_addr8;
        const mapped = std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff;
        if (mapped) family = c.AF_INET;
    }
    var tos: c_int = (s.qos_dscp & 0x3f) << 2;
    return switch (family) {
        c.AF_INET => c.setsockopt(fd, c.IPPROTO_IP, c.IP_TOS, &tos, @sizeOf(c_int)),
        c.AF_INET6 => c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_TCLASS, &tos, @sizeOf(c_int)),
        else => 0,
    };
}

fn setupDscp(s: *Sink) void {
    clientsLock(s);
    defer clientsUnlock(s);
    var l = s.clients;
    while (l != null) : (l = l.*.next) _ = setupDscpClient(s, @ptrCast(@alignCast(l.*.data)));
}

fn debugOf(s: *Sink, h: Handle, out: *[30]u8) void {
    klass(s).handle_debug.?(h, out);
}

pub fn addFull(s: *Sink, h: Handle, sync_method: c.gint, min_format: c.GstFormat, min_value: u64, max_format: c.GstFormat, max_value: u64) void {
    const k = klass(s);
    if (s.running == 0) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "Element %s must be set to READY, PAUSED or PLAYING state before clients can be added", cm.obj(s).name);
        return;
    }
    if (min_format == max_format and max_value != std.math.maxInt(u64) and min_value != std.math.maxInt(u64) and max_value < min_value) return;
    clientsLock(s);
    if (c.g_hash_table_lookup(s.handle_hash, k.handle_hash_key.?(h)) != null) {
        clientsUnlock(s);
        k.emit_client_removed.?(s, h, STATUS_DUPLICATE);
        return;
    }
    const cl = k.new_client.?(s, h, sync_method).?;
    s.clients = c.g_list_prepend(s.clients, cl);
    _ = c.g_hash_table_insert(s.handle_hash, k.handle_hash_key.?(cl.handle), s.clients);
    s.clients_cookie +%= 1;
    cl.burst_min_format = min_format;
    cl.burst_min_value = min_value;
    cl.burst_max_format = max_format;
    cl.burst_max_value = max_value;
    if (k.hash_changed) |f| f(s);
    clientsUnlock(s);
    k.emit_client_added.?(s, h);
}

pub fn add(s: *Sink, h: Handle) void {
    addFull(s, h, s.def_sync_method, s.def_burst_format, s.def_burst_value, s.def_burst_format, std.math.maxInt(u64));
}

fn lookup(s: *Sink, h: Handle) [*c]c.GList {
    return @ptrCast(@alignCast(c.g_hash_table_lookup(s.handle_hash, klass(s).handle_hash_key.?(h))));
}

pub fn remove(s: *Sink, h: Handle) void {
    clientsLock(s);
    defer clientsUnlock(s);
    const link = lookup(s, h);
    if (link == null) return;
    const cl: *Client = @ptrCast(@alignCast(link.*.data));
    if (cl.status != STATUS_OK) return;
    cl.status = STATUS_REMOVED;
    removeClientLink(s, link);
    if (klass(s).hash_changed) |f| f(s);
}

pub fn removeFlush(s: *Sink, h: Handle) void {
    clientsLock(s);
    defer clientsUnlock(s);
    const link = lookup(s, h);
    if (link == null) return;
    const cl: *Client = @ptrCast(@alignCast(link.*.data));
    if (cl.status != STATUS_OK) return;
    cl.flushcount = cl.bufpos + 1;
    cl.status = STATUS_FLUSHING;
}

fn clear(s: *Sink) callconv(.c) void {
    clientsLock(s);
    defer clientsUnlock(s);
    restart: while (true) {
        const cookie = s.clients_cookie;
        var l = s.clients;
        while (l != null) {
            if (cookie != s.clients_cookie) continue :restart;
            const next = l.*.next;
            const cl: *Client = @ptrCast(@alignCast(l.*.data));
            cl.status = STATUS_REMOVED;
            removeClientLink(s, l);
            l = next;
        }
        break;
    }
    if (klass(s).hash_changed) |f| f(s);
}

pub fn getStats(s: *Sink, h: Handle) ?*c.GstStructure {
    clientsLock(s);
    var result: ?*c.GstStructure = null;
    const link = lookup(s, h);
    if (link != null) {
        const cl: *Client = @ptrCast(@alignCast(link.*.data));
        const interval = if (cl.disconnect_time_monotonic == 0) monotonic() -% cl.connect_time_monotonic else cl.disconnect_time_monotonic -% cl.connect_time_monotonic;
        result = c.gst_structure_new_empty("multihandlesink-stats");
        c.gst_structure_set(result, "bytes-sent", c.G_TYPE_UINT64, cl.bytes_sent, "connect-time", c.G_TYPE_UINT64, cl.connect_time, "connect-time-monotonic", c.G_TYPE_UINT64, cl.connect_time_monotonic, "disconnect-time", c.G_TYPE_UINT64, cl.disconnect_time, "disconnect-time-monotonic", c.G_TYPE_UINT64, cl.disconnect_time_monotonic, "connect-duration", c.G_TYPE_UINT64, interval, "last-activity-time-monotonic", c.G_TYPE_UINT64, cl.last_activity_time_monotonic, "buffers-dropped", c.G_TYPE_UINT64, cl.dropped_buffers, "first-buffer-ts", c.G_TYPE_UINT64, cl.first_buffer_ts, "last-buffer-ts", c.G_TYPE_UINT64, cl.last_buffer_ts, @as(?*anyopaque, null));
    }
    clientsUnlock(s);
    return result orelse c.gst_structure_new_empty("multihandlesink-stats");
}

pub fn removeClientLink(s: *Sink, link: [*c]c.GList) void {
    const cl: *Client = @ptrCast(@alignCast(link.*.data));
    const k = klass(s);
    if (cl.currently_removing != 0) return;
    cl.currently_removing = 1;
    k.hash_removing.?(s, cl);
    cl.disconnect_time = now();
    cl.disconnect_time_monotonic = monotonic();
    c.g_slist_free_full(cl.sending, cm.unrefEvent);
    cl.sending = null;
    if (cl.caps != null) c.gst_caps_unref(cl.caps);
    cl.caps = null;
    clientsUnlock(s);
    k.emit_client_removed.?(s, cl.handle, cl.status);
    clientsLock(s);
    _ = c.g_hash_table_remove(s.handle_hash, k.handle_hash_key.?(cl.handle));
    s.clients = c.g_list_remove(s.clients, cl);
    s.clients_cookie +%= 1;
    if (k.removed) |f| f(s, cl.handle);
    clientsUnlock(s);
    k.client_free.?(s, cl);
    c.g_free(cl);
    clientsLock(s);
}

fn streamheader(caps: [*c]c.GstCaps) ?*const c.GValue {
    const st = c.gst_caps_get_structure(caps, 0);
    if (c.gst_structure_has_field(st, "streamheader") == 0) return null;
    return c.gst_structure_get_value(st, "streamheader");
}

fn clientQueueBuffer(s: *Sink, cl: *Client, b: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const caps = c.gst_pad_get_current_caps(@as(*c.GstBaseSink, @ptrCast(@alignCast(s))).sinkpad);
    var send = false;
    if (cl.caps == null) {
        if (caps != null) {
            send = true;
            cl.caps = c.gst_caps_ref(caps);
        }
    } else {
        if (caps != null and c.gst_caps_is_equal(caps, cl.caps) == 0) {
            if (streamheader(caps)) |fresh| {
                if (streamheader(cl.caps)) |old| {
                    send = s.resend_streamheader != 0 and c.gst_value_compare(old, fresh) != c.GST_VALUE_EQUAL;
                } else send = true;
            }
        }
        _ = c.gst_caps_replace(&cl.caps, caps);
    }
    if (send) {
        if (streamheader(caps)) |sh| {
            const n = c.gst_value_array_get_size(sh);
            for (0..n) |i| {
                const hb = c.gst_value_get_buffer(c.gst_value_array_get_value(sh, @intCast(i)));
                cl.sending = c.g_slist_append(cl.sending, c.gst_buffer_ref(hb));
            }
        }
    }
    if (caps != null) c.gst_caps_unref(caps);
    cl.sending = c.g_slist_append(cl.sending, c.gst_buffer_ref(b));
    return 1;
}

fn findSyncframe(s: *Sink, idx: c.gint, dir: c.gint) c.gint {
    const len: c.gint = @intCast(s.bufqueue.*.len);
    var i = idx;
    while (i >= 0 and i < len) : (i += dir) {
        if (!isDelta(queued(s, @intCast(i)))) return i;
    }
    return -1;
}

fn buffersMax(s: *Sink, max: i64) c.gint {
    const len = s.bufqueue.*.len;
    switch (s.unit_format) {
        c.GST_FORMAT_BUFFERS => return @truncate(max),
        c.GST_FORMAT_TIME => {
            var first: u64 = c.GST_CLOCK_TIME_NONE;
            for (0..len) |i| {
                const ts = cm.buf(queued(s, @intCast(i))).pts;
                if (ts == c.GST_CLOCK_TIME_NONE) continue;
                if (first == c.GST_CLOCK_TIME_NONE) first = ts;
                const diff: i64 = @bitCast(first -% ts);
                if (diff > max) return @intCast(i + 1);
            }
            return @intCast(len + 1);
        },
        c.GST_FORMAT_BYTES => {
            var acc: c.gint = 0;
            for (0..len) |i| {
                acc +%= @truncate(@as(i64, @intCast(c.gst_buffer_get_size(queued(s, @intCast(i))))));
                if (acc > max) return @intCast(i + 1);
            }
            return @intCast(len + 1);
        },
        else => return @truncate(max),
    }
}

fn findLimits(s: *Sink, min_idx: *c.gint, bytes_min0: c.gint, buffers_min: c.gint, time_min0: i64, max_idx: *c.gint, bytes_max: c.gint, _: c.gint, time_max: i64) bool {
    const len: c.gint = @intCast(s.bufqueue.*.len);
    if (buffers_min != -1 and len < buffers_min) {
        min_idx.* = len - 1;
        max_idx.* = len - 1;
        return false;
    }
    var bytes_min = bytes_min0;
    var time_min = time_min0;
    var result = false;
    var first: u64 = c.GST_CLOCK_TIME_NONE;
    var bytes: c.gint = 0;
    min_idx.* = -1;
    max_idx.* = -1;
    var max_hit = false;
    var i: c.gint = 0;
    while (true) {
        if (bytes_min == -1 and time_min == -1 and min_idx.* == -1) min_idx.* = @max(i - 1, 0);
        if (max_hit) {
            max_idx.* = i - 1;
            result = min_idx.* != -1;
            break;
        }
        const b = queued(s, @intCast(i));
        bytes +%= @truncate(@as(i64, @intCast(c.gst_buffer_get_size(b))));
        const ts = cm.buf(b).pts;
        if (ts != c.GST_CLOCK_TIME_NONE) {
            if (first == c.GST_CLOCK_TIME_NONE) first = ts;
            const span: i64 = @bitCast(first -% ts);
            if (time_min != -1 and span >= time_min) time_min = -1;
            if (time_max != -1 and span >= time_max) max_hit = true;
        }
        if (bytes_min != -1 and bytes >= bytes_min) bytes_min = -1;
        if (bytes_max != -1 and bytes >= bytes_max) max_hit = true;
        i += 1;
        if (i >= len) break;
    }
    if (max_idx.* == -1) max_idx.* = len - 1;
    if (min_idx.* == -1) min_idx.* = max_idx.*;
    return result;
}

fn burstUnits(s: *Sink, min_idx: *c.gint, min_format: c.GstFormat, min_value: u64, max_idx: *c.gint, max_format: c.GstFormat, max_value: u64) bool {
    var bytes_min: c.gint = -1;
    var buffers_min: c.gint = -1;
    var bytes_max: c.gint = -1;
    var buffers_max: c.gint = -1;
    var time_min: i64 = -1;
    var time_max: i64 = -1;
    switch (min_format) {
        c.GST_FORMAT_BUFFERS => buffers_min = @truncate(@as(i64, @bitCast(min_value))),
        c.GST_FORMAT_TIME => time_min = @bitCast(min_value),
        c.GST_FORMAT_BYTES => bytes_min = @truncate(@as(i64, @bitCast(min_value))),
        else => {},
    }
    switch (max_format) {
        c.GST_FORMAT_BUFFERS => buffers_max = @truncate(@as(i64, @bitCast(max_value))),
        c.GST_FORMAT_TIME => time_max = @bitCast(max_value),
        c.GST_FORMAT_BYTES => bytes_max = @truncate(@as(i64, @bitCast(max_value))),
        else => {},
    }
    return findLimits(s, min_idx, bytes_min, buffers_min, time_min, max_idx, bytes_max, buffers_max, time_max);
}

pub fn newClientPosition(s: *Sink, cl: *Client) c.gint {
    switch (cl.sync_method) {
        SYNC_LATEST => return cl.bufpos,
        SYNC_NEXT_KEYFRAME => {
            const r = findSyncframe(s, cl.bufpos, -1);
            if (r == -1) cl.bufpos = -1;
            return r;
        },
        SYNC_LATEST_KEYFRAME => {
            const r = findSyncframe(s, 0, 1);
            if (r == -1) {
                cl.bufpos = -1;
                cl.sync_method = SYNC_NEXT_KEYFRAME;
            }
            return r;
        },
        SYNC_BURST => {
            var r: c.gint = 0;
            var max: c.gint = 0;
            _ = burstUnits(s, &r, cl.burst_min_format, cl.burst_min_value, &max, cl.burst_max_format, cl.burst_max_value);
            if (max != -1 and max <= r) r = @max(max - 1, 0);
            return r;
        },
        SYNC_BURST_KEYFRAME => {
            var lo: c.gint = 0;
            var hi: c.gint = 0;
            _ = burstUnits(s, &lo, cl.burst_min_format, cl.burst_min_value, &hi, cl.burst_max_format, cl.burst_max_value);
            const next = findSyncframe(s, lo, 1);
            if (next != -1 and next < hi) return next;
            const prev = findSyncframe(s, lo, -1);
            if (prev != -1) return prev;
            cl.bufpos = -1;
            cl.sync_method = SYNC_NEXT_KEYFRAME;
            return -1;
        },
        SYNC_BURST_WITH_KEYFRAME => {
            var lo: c.gint = 0;
            var hi: c.gint = 0;
            _ = burstUnits(s, &lo, cl.burst_min_format, cl.burst_min_value, &hi, cl.burst_max_format, cl.burst_max_value);
            const next = findSyncframe(s, lo, 1);
            if (next != -1 and next < hi) return next;
            if (hi != -1 and hi <= lo) return @max(hi - 1, 0);
            return lo;
        },
        else => {
            c.g_log(null, c.G_LOG_LEVEL_WARNING, "unknown sync method %d", cl.sync_method);
            return cl.bufpos;
        },
    }
}

fn recoverClient(s: *Sink, cl: *Client) c.gint {
    switch (s.recover_policy) {
        RECOVER_NONE => return cl.bufpos,
        RECOVER_LATEST => return -1,
        RECOVER_KEYFRAME => {
            var pos = @min(@as(c.gint, @intCast(s.bufqueue.*.len)) - 1, buffersMax(s, s.units_soft_max) - 1);
            while (pos >= 0) : (pos -= 1) {
                if (!isDelta(queued(s, @intCast(pos)))) break;
            }
            return pos;
        },
        else => return buffersMax(s, s.units_soft_max),
    }
}

fn queueBuffer(s: *Sink, b: [*c]c.GstBuffer) void {
    const k = klass(s);
    clientsLock(s);
    var held = b;
    _ = c.g_array_prepend_vals(s.bufqueue, @ptrCast(&held), 1);
    var len: c.gint = @intCast(s.bufqueue.*.len);
    const max_buffers: c.gint = if (s.units_max > 0) buffersMax(s, s.units_max) else -1;
    const soft_max: c.gint = if (s.units_soft_max > 0) buffersMax(s, s.units_soft_max) else -1;
    var l = s.clients;
    while (l != null) : (l = l.*.next) {
        const cl: *Client = @ptrCast(@alignCast(l.*.data));
        cl.bufpos += 1;
        if (soft_max > 0 and cl.bufpos >= soft_max) {
            const pos = recoverClient(s, cl);
            if (pos != cl.bufpos) {
                cl.dropped_buffers +%= @intCast(cl.bufpos - pos);
                cl.bufpos = pos;
                cl.discont = 1;
            }
        }
    }
    var usage: c.gint = 0;
    var changed = false;
    const t = monotonic();
    restart: while (true) {
        const cookie = s.clients_cookie;
        l = s.clients;
        while (l != null) {
            if (cookie != s.clients_cookie) continue :restart;
            const next = l.*.next;
            const cl: *Client = @ptrCast(@alignCast(l.*.data));
            if ((max_buffers > 0 and cl.bufpos >= max_buffers) or (s.timeout > 0 and t -% cl.last_activity_time_monotonic > s.timeout)) {
                cl.status = STATUS_SLOW;
                cl.bufpos = -1;
                removeClientLink(s, l);
                changed = true;
                l = next;
                continue;
            } else if (cl.bufpos == 0 or cl.new_connection != 0) {
                k.hash_adding.?(s, cl);
                changed = true;
            }
            usage = @max(usage, cl.bufpos);
            l = next;
        }
        break;
    }
    var lo: c.gint = 0;
    var hi: c.gint = 0;
    _ = findLimits(s, &lo, s.bytes_min, s.buffers_min, s.time_min, &hi, -1, -1, -1);
    usage = @max(usage, lo);
    if (s.def_sync_method == SYNC_LATEST_KEYFRAME or s.def_sync_method == SYNC_BURST_KEYFRAME) {
        var limit = len;
        if (soft_max > 0) limit = @min(limit, soft_max);
        var i: c.gint = 0;
        while (i < limit) : (i += 1) {
            if (!isDelta(queued(s, @intCast(i)))) {
                usage = @max(usage, i);
                break;
            }
        }
    }
    var i = len - 1;
    while (i > usage) : (i -= 1) {
        len -= 1;
        const old = queued(s, @intCast(i));
        _ = c.g_array_remove_index(s.bufqueue, @intCast(i));
        c.gst_buffer_unref(old);
    }
    s.buffers_queued = usage + 1;
    clientsUnlock(s);
    if (changed) if (k.hash_changed) |f| f(s);
}

fn inCaps(s: *Sink, b: [*c]c.GstBuffer) bool {
    const caps = c.gst_pad_get_current_caps(@as(*c.GstBaseSink, @ptrCast(@alignCast(s))).sinkpad);
    if (caps == null) return false;
    defer c.gst_caps_unref(caps);
    const sh = streamheader(caps) orelse return false;
    if (c.gst_value_array_get_type() != @as(*const c.GValue, sh).g_type) return false;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &map);
    const n = c.gst_value_array_get_size(sh);
    for (0..n) |i| {
        const v = c.gst_value_array_get_value(sh, @intCast(i));
        if (@as(*const c.GValue, v).g_type != c.gst_buffer_get_type()) continue;
        const other = c.gst_value_get_buffer(v);
        if (other == b) return true;
        var m2: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(other, &m2, c.GST_MAP_READ);
        const same = map.size == m2.size and std.mem.eql(u8, map.data[0..map.size], m2.data[0..m2.size]);
        c.gst_buffer_unmap(other, &m2);
        if (same) return true;
    }
    return false;
}

fn render(bs: [*c]c.GstBaseSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bs);
    if (!cm.that(cm.obj(s).flags & OPEN != 0, "gst_multi_handle_sink_render", "GST_OBJECT_FLAG_IS_SET (sink, GST_MULTI_HANDLE_SINK_OPEN)")) return c.GST_FLOW_FLUSHING;
    const header = (@as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags & c.GST_BUFFER_FLAG_HEADER) != 0;
    const held = c.gst_buffer_ref(b);
    if (header and inCaps(s, b)) {
        c.gst_buffer_unref(held);
    } else {
        queueBuffer(s, held);
        s.bytes_to_serve +%= c.gst_buffer_get_size(held);
    }
    return c.GST_FLOW_OK;
}

fn start(s: *Sink) bool {
    if (cm.obj(s).flags & OPEN != 0) return true;
    const k = klass(s);
    if (k.start_pre.?(s) == 0) return false;
    s.bytes_to_serve = 0;
    s.bytes_served = 0;
    if (k.init) |f| _ = f(s);
    s.running = 1;
    s.thread = c.g_thread_new("multihandlesink", @ptrCast(k.thread.?), s);
    cm.obj(s).flags |= OPEN;
    return true;
}

fn stop(s: *Sink) void {
    if (cm.obj(s).flags & OPEN == 0) return;
    const k = klass(s);
    s.running = 0;
    k.stop_pre.?(s);
    if (s.thread) |t| {
        _ = c.g_thread_join(t);
        s.thread = null;
    }
    k.clear.?(s);
    if (k.close) |f| _ = f(s);
    k.stop_post.?(s);
    var i: c.gint = @as(c.gint, @intCast(s.bufqueue.*.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const old = queued(s, @intCast(i));
        c.gst_buffer_unref(old);
        _ = c.g_array_remove_index(s.bufqueue, @intCast(i));
    }
    cm.obj(s).flags &= ~OPEN;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (c.g_thread_self() == s.thread) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "\nTrying to change %s's state from its streaming thread would deadlock.\nYou cannot change the state of an element from its streaming\nthread. Use g_idle_add() or post a GstMessage on the bus to\nschedule the state change from the main thread.\n", cm.obj(s).name);
        return c.GST_STATE_CHANGE_FAILURE;
    }
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY and !start(s)) return c.GST_STATE_CHANGE_FAILURE;
    const ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent.?))).change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) stop(s);
    return ret;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_BUFFERS_MAX => s.units_max = c.g_value_get_int(v),
        PROP_BUFFERS_SOFT_MAX => s.units_soft_max = c.g_value_get_int(v),
        PROP_TIME_MIN => s.time_min = c.g_value_get_int64(v),
        PROP_BYTES_MIN => s.bytes_min = c.g_value_get_int(v),
        PROP_BUFFERS_MIN => s.buffers_min = c.g_value_get_int(v),
        PROP_UNIT_FORMAT => s.unit_format = @bitCast(c.g_value_get_enum(v)),
        PROP_UNITS_MAX => s.units_max = c.g_value_get_int64(v),
        PROP_UNITS_SOFT_MAX => s.units_soft_max = c.g_value_get_int64(v),
        PROP_RECOVER_POLICY => s.recover_policy = c.g_value_get_enum(v),
        PROP_TIMEOUT => s.timeout = c.g_value_get_uint64(v),
        PROP_SYNC_METHOD => s.def_sync_method = c.g_value_get_enum(v),
        PROP_BURST_FORMAT => s.def_burst_format = @bitCast(c.g_value_get_enum(v)),
        PROP_BURST_VALUE => s.def_burst_value = c.g_value_get_uint64(v),
        PROP_QOS_DSCP => {
            s.qos_dscp = c.g_value_get_int(v);
            setupDscp(s);
        },
        PROP_RESEND_STREAMHEADER => s.resend_streamheader = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 1978),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_BUFFERS_MAX => c.g_value_set_int(v, @truncate(s.units_max)),
        PROP_BUFFERS_SOFT_MAX => c.g_value_set_int(v, @truncate(s.units_soft_max)),
        PROP_TIME_MIN => c.g_value_set_int64(v, s.time_min),
        PROP_BYTES_MIN => c.g_value_set_int(v, s.bytes_min),
        PROP_BUFFERS_MIN => c.g_value_set_int(v, s.buffers_min),
        PROP_BUFFERS_QUEUED => c.g_value_set_uint(v, @bitCast(s.buffers_queued)),
        PROP_BYTES_QUEUED => c.g_value_set_uint(v, @bitCast(s.bytes_queued)),
        PROP_TIME_QUEUED => c.g_value_set_uint64(v, @intCast(s.time_queued)),
        PROP_UNIT_FORMAT => c.g_value_set_enum(v, @bitCast(s.unit_format)),
        PROP_UNITS_MAX => c.g_value_set_int64(v, s.units_max),
        PROP_UNITS_SOFT_MAX => c.g_value_set_int64(v, s.units_soft_max),
        PROP_RECOVER_POLICY => c.g_value_set_enum(v, s.recover_policy),
        PROP_TIMEOUT => c.g_value_set_uint64(v, s.timeout),
        PROP_SYNC_METHOD => c.g_value_set_enum(v, s.def_sync_method),
        PROP_BYTES_TO_SERVE => c.g_value_set_uint64(v, s.bytes_to_serve),
        PROP_BYTES_SERVED => c.g_value_set_uint64(v, s.bytes_served),
        PROP_BURST_FORMAT => c.g_value_set_enum(v, @bitCast(s.def_burst_format)),
        PROP_BURST_VALUE => c.g_value_set_uint64(v, s.def_burst_value),
        PROP_QOS_DSCP => c.g_value_set_int(v, s.qos_dscp),
        PROP_RESEND_STREAMHEADER => c.g_value_set_boolean(v, s.resend_streamheader),
        PROP_NUM_HANDLES => c.g_value_set_uint(v, c.g_hash_table_size(s.handle_hash)),
        else => cm.warnInvalid(FILE, o, id, spec, 2057),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_rec_mutex_clear(&s.clientslock);
    _ = c.g_array_free(s.bufqueue, 1);
    c.g_hash_table_destroy(s.handle_hash);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const rw = cm.RW;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, PROP_BUFFERS_MAX, c.g_param_spec_int("buffers-max", "Buffers max", "max number of buffers to queue for a client (-1 = no limit)", -1, std.math.maxInt(c.gint), -1, rw));
    c.g_object_class_install_property(oc, PROP_BUFFERS_SOFT_MAX, c.g_param_spec_int("buffers-soft-max", "Buffers soft max", "Recover client when going over this limit (-1 = no limit)", -1, std.math.maxInt(c.gint), -1, rw));
    c.g_object_class_install_property(oc, PROP_BYTES_MIN, c.g_param_spec_int("bytes-min", "Bytes min", "min number of bytes to queue (-1 = as little as possible)", -1, std.math.maxInt(c.gint), -1, rw));
    c.g_object_class_install_property(oc, PROP_TIME_MIN, c.g_param_spec_int64("time-min", "Time min", "min amount of time to queue (in nanoseconds) (-1 = as little as possible)", -1, std.math.maxInt(i64), -1, rw));
    c.g_object_class_install_property(oc, PROP_BUFFERS_MIN, c.g_param_spec_int("buffers-min", "Buffers min", "min number of buffers to queue (-1 = as few as possible)", -1, std.math.maxInt(c.gint), -1, rw));
    c.g_object_class_install_property(oc, PROP_UNIT_FORMAT, c.g_param_spec_enum("unit-format", "Units format", "The unit to measure the max/soft-max/queued properties", c.gst_format_get_type(), c.GST_FORMAT_BUFFERS, rw));
    c.g_object_class_install_property(oc, PROP_UNITS_MAX, c.g_param_spec_int64("units-max", "Units max", "max number of units to queue (-1 = no limit)", -1, std.math.maxInt(i64), -1, rw));
    c.g_object_class_install_property(oc, PROP_UNITS_SOFT_MAX, c.g_param_spec_int64("units-soft-max", "Units soft max", "Recover client when going over this limit (-1 = no limit)", -1, std.math.maxInt(i64), -1, rw));
    c.g_object_class_install_property(oc, PROP_BUFFERS_QUEUED, c.g_param_spec_uint("buffers-queued", "Buffers queued", "Number of buffers currently queued", 0, std.math.maxInt(c.guint), 0, ro));
    c.g_object_class_install_property(oc, PROP_RECOVER_POLICY, c.g_param_spec_enum("recover-policy", "Recover Policy", "How to recover when client reaches the soft max", recoverPolicyType(), RECOVER_NONE, rw));
    c.g_object_class_install_property(oc, PROP_TIMEOUT, c.g_param_spec_uint64("timeout", "Timeout", "Maximum inactivity timeout in nanoseconds for a client (0 = no limit)", 0, std.math.maxInt(u64), 0, rw));
    c.g_object_class_install_property(oc, PROP_SYNC_METHOD, c.g_param_spec_enum("sync-method", "Sync Method", "How to sync new clients to the stream", syncMethodType(), SYNC_LATEST, rw));
    c.g_object_class_install_property(oc, PROP_BYTES_TO_SERVE, c.g_param_spec_uint64("bytes-to-serve", "Bytes to serve", "Number of bytes received to serve to clients", 0, std.math.maxInt(u64), 0, ro));
    c.g_object_class_install_property(oc, PROP_BYTES_SERVED, c.g_param_spec_uint64("bytes-served", "Bytes served", "Total number of bytes send to all clients", 0, std.math.maxInt(u64), 0, ro));
    c.g_object_class_install_property(oc, PROP_BURST_FORMAT, c.g_param_spec_enum("burst-format", "Burst format", "The format of the burst units (when sync-method is burst[[-with]-keyframe])", c.gst_format_get_type(), c.GST_FORMAT_UNDEFINED, rw));
    c.g_object_class_install_property(oc, PROP_BURST_VALUE, c.g_param_spec_uint64("burst-value", "Burst value", "The amount of burst expressed in burst-format", 0, std.math.maxInt(u64), 0, rw));
    c.g_object_class_install_property(oc, PROP_QOS_DSCP, c.g_param_spec_int("qos-dscp", "QoS diff srv code point", "Quality of Service, differentiated services code point (-1 default)", -1, 63, -1, rw));
    c.g_object_class_install_property(oc, PROP_RESEND_STREAMHEADER, c.g_param_spec_boolean("resend-streamheader", "Resend streamheader", "Resend the streamheader if it changes in the caps", 1, rw));
    c.g_object_class_install_property(oc, PROP_NUM_HANDLES, c.g_param_spec_uint("num-handles", "Number of handles", "The current number of client handles", 0, std.math.maxInt(c.guint), 0, ro));
    sig_clear = c.g_signal_new("clear", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @offsetOf(Class, "clear"), null, null, null, c.G_TYPE_NONE, @as(c.guint, 0));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Multi socket sink", "Sink/Network", "Send data to multiple sockets", "Thomas Vander Stichele <thomas at apestaart dot org>, Wim Taymans <wim@fluendo.com>, Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    ec.change_state = changeState;
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.render = render;
    const mc: *Class = @ptrCast(@alignCast(k));
    mc.client_queue_buffer = clientQueueBuffer;
    mc.clear = clear;
    _ = c._gst_debug_category_new("multihandlesink", 0, "Multi socket sink");
    c.gst_type_mark_as_plugin_api(recoverPolicyType(), 0);
    c.gst_type_mark_as_plugin_api(syncMethodType(), 0);
    c.gst_type_mark_as_plugin_api(clientStatusType(), 0);
    c.gst_type_mark_as_plugin_api(cm.typeOfClass(k), 0);
}

fn instanceInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    cm.obj(s).flags &= ~OPEN;
    c.g_rec_mutex_init(&s.clientslock);
    s.clients = null;
    s.bufqueue = c.g_array_new(0, 1, @sizeOf([*c]c.GstBuffer));
    s.unit_format = c.GST_FORMAT_BUFFERS;
    s.units_max = -1;
    s.units_soft_max = -1;
    s.time_min = -1;
    s.bytes_min = -1;
    s.buffers_min = -1;
    s.recover_policy = RECOVER_NONE;
    s.timeout = 0;
    s.def_sync_method = SYNC_LATEST;
    s.def_burst_format = c.GST_FORMAT_UNDEFINED;
    s.def_burst_value = 0;
    s.qos_dscp = -1;
    s.resend_streamheader = 1;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_base_sink_get_type(), c.g_intern_static_string("GstMultiHandleSink"), @sizeOf(Class), classInit, @sizeOf(Sink), instanceInit, c.G_TYPE_FLAG_ABSTRACT);
        }
    }.f);
}
