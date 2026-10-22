const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const basic = @import("basic.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const NONE = basic.NONE;
const SECOND = basic.SECOND;
const FILE = "../libs/gst/net/gstnetclientclock.c";
const DEFAULT_ADDRESS = "127.0.0.1";
const DEFAULT_PORT = 5637;
const MIN_UPDATE = SECOND / 20;
const WINDOW = 9;
const MAX_SKIPPED = 5;

const Internal = extern struct {
    clock: c.GstSystemClock,
    thread: ?*c.GThread,
    socket: ?*c.GSocket,
    servaddr: ?*c.GSocketAddress,
    cancel: ?*c.GCancellable,
    made_cancel_fd: c.gboolean,
    marked_corrupted: c.gboolean,
    timeout_expiration: u64,
    roundtrip_limit: u64,
    rtt_avg: u64,
    minimum_update_interval: u64,
    last_remote_poll_interval: u64,
    last_remote_time: u64,
    skipped_updates: c.guint,
    last_rtts: [WINDOW]u64,
    last_rtts_missing: c.gint,
    address: [*c]u8,
    port: c.gint,
    is_ntp: c.gboolean,
    qos_dscp: c.gint,
    busses: [*c]c.GList,
};

const InternalClass = extern struct {
    parent: c.GstSystemClockClass,
};

const Client = c.GstNetClientClock;

const Priv = extern struct {
    internal_clock: [*c]c.GstClock,
    roundtrip_limit: u64,
    minimum_update_interval: u64,
    base_time: u64,
    internal_base_time: u64,
    address: [*c]u8,
    port: c.gint,
    qos_dscp: c.gint,
    bus: [*c]c.GstBus,
    is_ntp: c.gboolean,
    synced_id: c.gulong,
};

const Cache = struct {
    clock: [*c]c.GstClock,
    clocks: [*c]c.GList,
    remove_id: c.GstClockID,
};

var internal_once: gtype.Once = .{};
var client_once: gtype.Once = .{};
var ntp_once: gtype.Once = .{};
var internal_parent: ?*c.GObjectClass = null;
var client_parent: ?*c.GObjectClass = null;
var client_offset: c.gint = 0;
var cat: ?*c.GstDebugCategory = null;
var clocks_lock: gtype.Lock = .{};
var clocks: [*c]c.GList = null;

fn obj(p: anytype) *c.GstObject {
    return @ptrCast(@alignCast(p));
}

fn lock(p: anytype) void {
    c.g_mutex_lock(&obj(p).lock);
}

fn unlock(p: anytype) void {
    c.g_mutex_unlock(&obj(p).lock);
}

fn clk(p: anytype) [*c]c.GstClock {
    return @ptrCast(@alignCast(p));
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log(basic.DOMAIN, c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", FILE, line, "property", id, spec.*.name, c.g_type_name(spec.*.g_type_instance.g_class.*.g_type), c.g_type_name(o.*.g_type_instance.g_class.*.g_type));
}

fn logErr(o: anytype, comptime func: [:0]const u8, line: c_int, comptime fmt: [:0]const u8, args: anytype) void {
    @call(.auto, c.gst_debug_log, .{ cat, @as(c.GstDebugLevel, c.GST_LEVEL_ERROR), FILE, func.ptr, line, @as([*c]c.GObject, @ptrCast(@alignCast(o))), fmt.ptr } ++ args);
}

fn internalInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Internal = @ptrCast(@alignCast(inst));
    obj(s).flags |= c.GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC;
    s.port = DEFAULT_PORT;
    s.address = c.g_strdup(DEFAULT_ADDRESS);
    s.is_ntp = 0;
    s.qos_dscp = -1;
    _ = c.gst_clock_set_timeout(clk(s), SECOND);
    s.thread = null;
    s.servaddr = null;
    s.rtt_avg = NONE;
    s.roundtrip_limit = SECOND;
    s.minimum_update_interval = MIN_UPDATE;
    s.last_remote_poll_interval = NONE;
    s.skipped_updates = 0;
    s.last_rtts_missing = WINDOW;
    s.marked_corrupted = 0;
}

fn internalFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Internal = @ptrCast(@alignCast(o));
    if (s.thread != null) internalStop(s);
    c.g_free(s.address);
    s.address = null;
    if (s.servaddr) |a| c.g_object_unref(a);
    s.servaddr = null;
    if (s.socket) |sock| {
        if (c.g_socket_close(sock, null) == 0) logErr(s, "gst_net_client_internal_clock_finalize", 258, "Failed to close socket", .{});
        c.g_object_unref(sock);
        s.socket = null;
    }
    if (s.busses != null) c.g_log(basic.DOMAIN, c.G_LOG_LEVEL_WARNING, "%s:%d:%s: runtime check failed: (%s)", FILE, @as(c_int, 263), "gst_net_client_internal_clock_finalize", "self->busses == NULL");
    internal_parent.?.finalize.?(o);
}

fn internalSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Internal = @ptrCast(@alignCast(o));
    switch (id) {
        1 => {
            lock(s);
            c.g_free(s.address);
            s.address = c.g_value_dup_string(v);
            if (s.address == null) s.address = c.g_strdup(DEFAULT_ADDRESS);
            unlock(s);
        },
        2 => {
            lock(s);
            s.port = c.g_value_get_int(v);
            unlock(s);
        },
        8 => {
            lock(s);
            s.is_ntp = c.g_value_get_boolean(v);
            unlock(s);
        },
        else => warnInvalid(o, id, spec, 295),
    }
}

fn internalGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Internal = @ptrCast(@alignCast(o));
    switch (id) {
        1 => {
            lock(s);
            c.g_value_set_string(v, s.address);
            unlock(s);
        },
        2 => c.g_value_set_int(v, s.port),
        8 => c.g_value_set_boolean(v, s.is_ntp),
        else => warnInvalid(o, id, spec, 319),
    }
}

fn internalConstructed(o: [*c]c.GObject) callconv(.c) void {
    const s: *Internal = @ptrCast(@alignCast(o));
    internal_parent.?.constructed.?(o);
    if (!internalStart(s)) {
        c.g_log(basic.DOMAIN, c.G_LOG_LEVEL_WARNING, "failed to start clock '%s'", obj(s).name);
        s.marked_corrupted = 1;
    }
}

fn compareTime(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const x: *const u64 = @ptrCast(@alignCast(a));
    const y: *const u64 = @ptrCast(@alignCast(b));
    return if (x.* < y.*) -1 else if (x.* > y.*) 1 else 0;
}

fn adjust(s: *Internal, t: u64, i: u64, e: u64, n: u64, d: u64) u64 {
    return c.gst_clock_adjust_with_calibration(clk(s), t, i, e, n, d);
}

fn observe(s: *Internal, l1: u64, r1: u64, r2: u64, l2: u64) void {
    var timeout: u64 = 0;
    var r_squared: f64 = 0;
    var discont: i64 = 0;
    var min_guess: u64 = 0;
    var before: u64 = 0;
    lock(s);
    const limit = s.roundtrip_limit;
    if (s.last_remote_time > r1 or s.marked_corrupted != 0) {
        if (s.marked_corrupted == 0) {
            logErr(s, "gst_net_client_internal_clock_observe_times", 650, "Remote clock time reverted, mark clock invalid", .{});
            s.marked_corrupted = 1;
        }
        unlock(s);
        _ = c.gst_clock_set_synced(clk(s), 0);
        return;
    }
    s.last_remote_time = r1;
    const min_interval = if (s.last_remote_poll_interval != NONE and s.last_remote_poll_interval > s.minimum_update_interval) s.last_remote_poll_interval else s.minimum_update_interval;
    unlock(s);
    const bogus = struct {
        fn f(x: *Internal) void {
            x.timeout_expiration = c.gst_util_get_timestamp() +% SECOND / 4;
        }
    }.f;
    if (l2 < l1 or r2 < r1) return bogus(s);
    const rtt: u64 = @bitCast(diff(l1, l2) -% diff(r1, r2));
    if (limit > 0 and rtt > limit) return bogus(s);
    for (1..WINDOW) |i| s.last_rtts[i - 1] = s.last_rtts[i];
    s.last_rtts[WINDOW - 1] = rtt;
    if (s.last_rtts_missing != 0) {
        s.last_rtts_missing -= 1;
    } else {
        var sorted = s.last_rtts;
        c.g_sort_array(&sorted, WINDOW, @sizeOf(u64), compareTime, null);
        if (rtt > 2 *% sorted[WINDOW / 2]) return bogus(s);
    }
    if (s.rtt_avg == NONE) {
        s.rtt_avg = rtt;
    } else if (rtt < s.rtt_avg) {
        s.rtt_avg = (3 *% s.rtt_avg +% rtt) / 4;
    } else s.rtt_avg = (15 *% s.rtt_avg +% rtt) / 16;
    if (rtt > 2 *% s.rtt_avg) return bogus(s);
    const local_avg = (l2 +% l1) / 2;
    const remote_avg = (r2 +% r1) / 2;
    var oi: u64 = 0;
    var oe: u64 = 0;
    var on: u64 = 0;
    var od: u64 = 0;
    c.gst_clock_get_calibration(clk(s), &oi, &oe, &on, &od);
    var it = oi;
    var et = oe;
    var rn = on;
    var rd = od;
    min_guess = adjust(s, l1, it, et, rn, rd);
    before = adjust(s, l2, it, et, rn, rd);
    const maxd = s.rtt_avg / 4;
    const md: i64 = @bitCast(maxd);
    const synched = diff(remote_avg, min_guess) < md and diff(before, remote_avg) < md;
    if (c.gst_clock_add_observation_unapplied(clk(s), local_avg, remote_avg, &r_squared, &it, &et, &rn, &rd) != 0) {
        discont = diff(before, adjust(s, l2, it, et, rn, rd));
        if (synched and @abs(discont) > maxd) {
            var off: i64 = 0;
            if (discont > 0) {
                off = md -% discont;
                if (-off > @as(i64, @bitCast(et))) {
                    et = 0;
                } else et = @bitCast(@as(i64, @bitCast(et)) +% off);
            } else {
                off = -(md +% discont);
                et = @bitCast(@as(i64, @bitCast(et)) +% off);
            }
            discont +%= off;
        }
        const now_synched = diff(remote_avg, adjust(s, l1, it, et, rn, rd)) < md and diff(adjust(s, l2, it, et, rn, rd), remote_avg) < md;
        if (synched or now_synched or s.skipped_updates > MAX_SKIPPED) {
            c.gst_clock_set_calibration(clk(s), it, et, rn, rd);
            const f = (1e-3 / (1 - @min(r_squared, 0.99999))) * 1e9;
            timeout = if (f >= 18446744073709551616.0) 0 else @intFromFloat(f);
            timeout = @min(timeout, c.gst_clock_get_timeout(clk(s)));
            s.skipped_updates = 0;
            _ = c.gst_clock_set_synced(clk(s), 1);
        } else {
            it = oi;
            et = oe;
            rn = on;
            rd = od;
            discont = 0;
            s.skipped_updates += 1;
        }
    }
    if (rtt < min_interval) timeout = @max(min_interval - rtt, timeout);
    lock(s);
    if (s.busses != null) {
        const st = c.gst_structure_new("gst-netclock-statistics", "synchronised", c.G_TYPE_BOOLEAN, @as(c.gboolean, @intFromBool(synched)), "rtt", c.G_TYPE_UINT64, rtt, "rtt-average", c.G_TYPE_UINT64, s.rtt_avg, "local", c.G_TYPE_UINT64, local_avg, "remote", c.G_TYPE_UINT64, remote_avg, "discontinuity", c.G_TYPE_INT64, discont, "remote-min-estimate", c.G_TYPE_UINT64, min_guess, "remote-max-estimate", c.G_TYPE_UINT64, before, "remote-min-error", c.G_TYPE_INT64, diff(remote_avg, min_guess), "remote-max-error", c.G_TYPE_INT64, diff(remote_avg, before), "request-send", c.G_TYPE_UINT64, l1, "request-receive", c.G_TYPE_UINT64, l2, "r-squared", c.G_TYPE_DOUBLE, r_squared, "timeout", c.G_TYPE_UINT64, timeout, "internal-time", c.G_TYPE_UINT64, it, "external-time", c.G_TYPE_UINT64, et, "rate-num", c.G_TYPE_UINT64, rn, "rate-den", c.G_TYPE_UINT64, rd, "rate", c.G_TYPE_DOUBLE, @as(f64, @floatFromInt(rn)) / @as(f64, @floatFromInt(rd)), "local-clock-offset", c.G_TYPE_INT64, diff(it, et), @as(?*anyopaque, null));
        const msg = c.gst_message_new_element(obj(s), st);
        var l = s.busses;
        while (l != null) : (l = l.*.next) _ = c.gst_bus_post(@ptrCast(@alignCast(l.*.data)), @ptrCast(c.gst_mini_object_ref(@ptrCast(msg))));
        c.gst_mini_object_unref(@ptrCast(msg));
    }
    unlock(s);
    s.timeout_expiration = c.gst_util_get_timestamp() +% timeout;
}

fn sendRequest(s: *Internal) void {
    if (s.is_ntp != 0) {
        var p = basic.Ntp{};
        p.transmit = c.gst_clock_get_internal_time(clk(s));
        _ = basic.sendTo(s.socket, s.servaddr, basic.ntpSerialize(p), basic.NTP_SIZE, null);
    } else {
        const p = basic.gst_net_time_packet_new(null);
        p.*.local_time = c.gst_clock_get_internal_time(clk(s));
        _ = basic.gst_net_time_packet_send(p, s.socket, s.servaddr, null);
        c.g_free(p);
    }
}

fn internalThread(data: c.gpointer) callconv(.c) c.gpointer {
    const s: *Internal = @ptrCast(@alignCast(data));
    const sock = s.socket;
    var cur: c.gint = -1;
    c.g_socket_set_blocking(sock, 1);
    c.g_socket_set_timeout(sock, 0);
    while (c.g_cancellable_is_cancelled(s.cancel) == 0) {
        const exp = s.timeout_expiration;
        const now = c.gst_util_get_timestamp();
        const wait: i64 = if (now >= exp or exp - now <= 1000000) 0 else @intCast((exp - now) / 1000);
        var err: [*c]c.GError = null;
        if (c.g_socket_condition_timed_wait(sock, c.G_IO_IN, wait, s.cancel, &err) == 0) {
            if (err.*.code == c.G_IO_ERROR_CANCELLED) {
                c.g_clear_error(&err);
                break;
            } else if (err.*.code == c.G_IO_ERROR_TIMED_OUT) {
                const want = s.qos_dscp;
                if (cur != want and basic.gst_net_utils_set_socket_tos(sock, want) != 0) cur = want;
                sendRequest(s);
                s.timeout_expiration = c.gst_util_get_timestamp() +% c.gst_clock_get_timeout(clk(s));
            } else c.g_usleep(100000);
            c.g_clear_error(&err);
            continue;
        }
        const local = c.gst_clock_get_internal_time(clk(s));
        if (s.is_ntp != 0) {
            var buf: [basic.NTP_SIZE]u8 = undefined;
            const got: ?basic.Ntp = if (basic.receive(sock, null, &err, &buf) < 0) null else basic.ntpParse(&buf, &err);
            if (got) |p| {
                if (p.poll != NONE) s.last_remote_poll_interval = p.poll;
                observe(s, p.origin, p.receive, p.transmit, local);
            } else if (err != null) {
                const q = basic.ntpQuark();
                if (c.g_error_matches(err, q, basic.NTP_WRONG_VERSION) != 0 or c.g_error_matches(err, q, basic.NTP_KOD_DENY) != 0) {
                    logErr(s, "gst_net_client_internal_clock_thread", 784, "fatal receive error: %s", .{err.*.message});
                    c.g_clear_error(&err);
                    break;
                } else if (c.g_error_matches(err, q, basic.NTP_KOD_RATE) != 0) {
                    if (s.last_remote_poll_interval == NONE) s.minimum_update_interval *%= 2;
                    s.timeout_expiration = c.gst_util_get_timestamp() +% c.gst_clock_get_timeout(clk(s));
                }
                c.g_clear_error(&err);
            }
        } else {
            const p = basic.gst_net_time_packet_receive(sock, null, &err);
            if (p != null) {
                observe(s, p.*.local_time, p.*.remote_time, p.*.remote_time, local);
                c.g_free(p);
            } else if (err != null) c.g_clear_error(&err);
        }
    }
    return null;
}

fn internalStart(s: *Internal) bool {
    const F = "gst_net_client_internal_clock_start";
    if (!basic.that(s.address != null, F, "self->address != NULL")) return false;
    if (!basic.that(s.servaddr == null, F, "self->servaddr == NULL")) return false;
    var err: [*c]c.GError = null;
    var inet = c.g_inet_address_new_from_string(s.address);
    if (inet == null) {
        const resolver = c.g_resolver_get_default();
        const results = c.g_resolver_lookup_by_name(resolver, s.address, null, &err);
        if (results == null) {
            logErr(s, F, 949, "resolving '%s' failed: %s", .{ s.address, err.*.message });
            c.g_clear_error(&err);
            c.g_object_unref(resolver);
            return false;
        }
        inet = @ptrCast(@alignCast(c.g_object_ref(results.*.data)));
        c.g_resolver_free_addresses(results);
        c.g_object_unref(resolver);
    }
    const family = c.g_inet_address_get_family(inet);
    const servaddr = c.g_inet_socket_address_new(inet, @intCast(s.port));
    c.g_object_unref(inet);
    const sock = c.g_socket_new(family, c.G_SOCKET_TYPE_DATAGRAM, c.G_SOCKET_PROTOCOL_UDP, &err);
    if (sock == null) {
        logErr(s, F, 926, "socket_new() failed: %s", .{err.*.message});
        c.g_error_free(err);
        c.g_object_unref(servaddr);
        return false;
    }
    const any = c.g_inet_address_new_any(family);
    const anyaddr = c.g_inet_socket_address_new(any, 0);
    _ = c.g_socket_bind(sock, anyaddr, 1, &err);
    c.g_object_unref(anyaddr);
    c.g_object_unref(any);
    if (err != null) {
        logErr(s, F, 933, "bind failed: %s", .{err.*.message});
        c.g_error_free(err);
        c.g_object_unref(sock);
        c.g_object_unref(servaddr);
        return false;
    }
    const mine = c.g_socket_get_local_address(sock, &err);
    if (mine == null) {
        logErr(s, F, 941, "get_local_address() failed: %s", .{err.*.message});
        c.g_error_free(err);
        c.g_object_unref(sock);
        c.g_object_unref(servaddr);
        return false;
    }
    c.g_object_unref(mine);
    s.cancel = c.g_cancellable_new();
    var dummy: c.GPollFD = undefined;
    s.made_cancel_fd = c.g_cancellable_make_pollfd(s.cancel, &dummy);
    s.socket = sock;
    s.servaddr = servaddr;
    s.thread = c.g_thread_try_new("GstNetClientInternalClock", internalThread, s, &err);
    if (err != null) {
        logErr(s, F, 957, "could not create thread: %s", .{err.*.message});
        c.g_object_unref(s.servaddr);
        s.servaddr = null;
        c.g_object_unref(s.socket);
        s.socket = null;
        c.g_error_free(err);
        return false;
    }
    return true;
}

fn internalStop(s: *Internal) void {
    if (s.thread == null) return;
    c.g_cancellable_cancel(s.cancel);
    _ = c.g_thread_join(s.thread);
    s.thread = null;
    if (s.made_cancel_fd != 0) c.g_cancellable_release_fd(s.cancel);
    c.g_object_unref(s.cancel);
    s.cancel = null;
    c.g_object_unref(s.servaddr);
    s.servaddr = null;
    c.g_object_unref(s.socket);
    s.socket = null;
}

fn internalClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    internal_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = internalFinalize;
    gc.get_property = internalGet;
    gc.set_property = internalSet;
    gc.constructed = internalConstructed;
    const f = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_string("address", "address", "The IP address of the machine providing a time server", DEFAULT_ADDRESS, f));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_int("port", "port", "The port on which the remote server is listening", 0, 65535, DEFAULT_PORT, f));
    c.g_object_class_install_property(gc, 8, c.g_param_spec_boolean("is-ntp", "Is NTP", "The clock is using the NTPv4 protocol", 0, f));
}

fn internalType() c.GType {
    return internal_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_system_clock_get_type, "GstNetClientInternalClock", InternalClass, Internal, internalClassInit, internalInit, 0);
            cat = c._gst_debug_category_new("netclock", 0, "Network client clock");
            return t;
        }
    }.f);
}

fn priv(s: anytype) *Priv {
    const p: [*]u8 = @ptrCast(s);
    return @ptrCast(@alignCast(p + @as(usize, @bitCast(@as(isize, client_offset)))));
}

fn internalOf(p: anytype) *Internal {
    return @ptrCast(@alignCast(p));
}

fn clientInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s: *Client = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(priv(s));
    const p = priv(s);
    obj(s).flags |= c.GST_CLOCK_FLAG_CAN_SET_MASTER | c.GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC;
    p.port = DEFAULT_PORT;
    p.address = c.g_strdup(DEFAULT_ADDRESS);
    p.qos_dscp = -1;
    p.roundtrip_limit = SECOND;
    p.minimum_update_interval = MIN_UPDATE;
    const sys = c.gst_system_clock_obtain();
    p.base_time = 0;
    p.internal_base_time = c.gst_clock_get_time(sys);
    c.gst_object_unref(sys);
}

fn updateCache(cache: *Cache) void {
    var limit: u64 = 0;
    var interval: u64 = 0;
    var dscp: c.gint = -1;
    var busses: [*c]c.GList = null;
    const ic = internalOf(cache.clock);
    lock(cache.clock);
    c.g_list_free_full(ic.busses, c.gst_object_unref);
    var l = cache.clocks;
    while (l != null) : (l = l.*.next) {
        const p = priv(l.*.data);
        if (p.bus != null) busses = c.g_list_prepend(busses, c.gst_object_ref(p.bus));
        limit = if (limit == 0) p.roundtrip_limit else @max(limit, p.roundtrip_limit);
        interval = if (interval == 0) p.minimum_update_interval else @min(interval, p.minimum_update_interval);
        dscp = @max(dscp, p.qos_dscp);
    }
    ic.busses = busses;
    ic.roundtrip_limit = limit;
    ic.minimum_update_interval = interval;
    ic.qos_dscp = dscp;
    unlock(cache.clock);
}

fn removeCache(_: [*c]c.GstClock, _: c.GstClockTime, _: c.GstClockID, data: c.gpointer) callconv(.c) c.gboolean {
    const cache: *Cache = @ptrCast(@alignCast(data));
    clocks_lock.lock();
    if (cache.clocks == null) {
        c.gst_clock_id_unref(cache.remove_id);
        c.gst_object_unref(cache.clock);
        clocks = c.g_list_remove(clocks, cache);
        std.heap.c_allocator.destroy(cache);
    }
    clocks_lock.unlock();
    return 1;
}

fn clientFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Client = @ptrCast(@alignCast(o));
    const p = priv(s);
    if (p.internal_clock != null) {
        if (p.synced_id != 0) c.g_signal_handler_disconnect(p.internal_clock, p.synced_id);
        p.synced_id = 0;
        clocks_lock.lock();
        var l = clocks;
        while (l != null) : (l = l.*.next) {
            const cache: *Cache = @ptrCast(@alignCast(l.*.data));
            if (cache.clock == p.internal_clock) {
                cache.clocks = c.g_list_remove(cache.clocks, s);
                if (cache.clocks != null) {
                    updateCache(cache);
                } else {
                    const sys = c.gst_system_clock_obtain();
                    var t = c.gst_clock_get_time(sys);
                    if (internalOf(cache.clock).marked_corrupted == 0) t +%= 60 * SECOND;
                    cache.remove_id = c.gst_clock_new_single_shot_id(sys, t);
                    _ = c.gst_clock_id_wait_async(cache.remove_id, removeCache, cache, null);
                    c.gst_object_unref(sys);
                }
                break;
            }
        }
        clocks_lock.unlock();
    }
    c.g_free(p.address);
    p.address = null;
    if (p.bus != null) c.gst_object_unref(p.bus);
    p.bus = null;
    client_parent.?.finalize.?(o);
}

fn clientSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Client = @ptrCast(@alignCast(o));
    const p = priv(s);
    var update = false;
    switch (id) {
        1 => {
            lock(s);
            c.g_free(p.address);
            p.address = c.g_value_dup_string(v);
            if (p.address == null) p.address = c.g_strdup(DEFAULT_ADDRESS);
            unlock(s);
        },
        2 => {
            lock(s);
            p.port = c.g_value_get_int(v);
            unlock(s);
        },
        3 => {
            lock(s);
            p.roundtrip_limit = c.g_value_get_uint64(v);
            unlock(s);
            update = true;
        },
        4 => {
            lock(s);
            p.minimum_update_interval = c.g_value_get_uint64(v);
            unlock(s);
            update = true;
        },
        5 => {
            lock(s);
            if (p.bus != null) c.gst_object_unref(p.bus);
            p.bus = @ptrCast(@alignCast(c.g_value_dup_object(v)));
            unlock(s);
            update = true;
        },
        6 => {
            p.base_time = c.g_value_get_uint64(v);
            const sys = c.gst_system_clock_obtain();
            p.internal_base_time = c.gst_clock_get_time(sys);
            c.gst_object_unref(sys);
        },
        9 => {
            lock(s);
            p.qos_dscp = c.g_value_get_int(v);
            unlock(s);
            update = true;
        },
        else => warnInvalid(o, id, spec, 1295),
    }
    if (update and p.internal_clock != null) {
        clocks_lock.lock();
        var l = clocks;
        while (l != null) : (l = l.*.next) {
            const cache: *Cache = @ptrCast(@alignCast(l.*.data));
            if (cache.clock == p.internal_clock) updateCache(cache);
        }
        clocks_lock.unlock();
    }
}

fn clientGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Client = @ptrCast(@alignCast(o));
    const p = priv(s);
    switch (id) {
        1 => {
            lock(s);
            c.g_value_set_string(v, p.address);
            unlock(s);
        },
        2 => c.g_value_set_int(v, p.port),
        3 => {
            lock(s);
            c.g_value_set_uint64(v, p.roundtrip_limit);
            unlock(s);
        },
        4 => {
            lock(s);
            c.g_value_set_uint64(v, p.minimum_update_interval);
            unlock(s);
        },
        5 => {
            lock(s);
            c.g_value_set_object(v, p.bus);
            unlock(s);
        },
        6 => c.g_value_set_uint64(v, p.base_time),
        7 => c.g_value_set_object(v, p.internal_clock),
        9 => {
            lock(s);
            c.g_value_set_int(v, p.qos_dscp);
            unlock(s);
        },
        else => warnInvalid(o, id, spec, 1356),
    }
}

fn syncedCb(_: [*c]c.GstClock, synced: c.gboolean, self: [*c]c.GstClock) callconv(.c) void {
    _ = c.gst_clock_set_synced(self, synced);
}

fn clientConstructed(o: [*c]c.GObject) callconv(.c) void {
    const s: *Client = @ptrCast(@alignCast(o));
    const p = priv(s);
    client_parent.?.constructed.?(o);
    var cache: ?*Cache = null;
    clocks_lock.lock();
    var l = clocks;
    while (l != null) : (l = l.*.next) {
        const tmp: *Cache = @ptrCast(@alignCast(l.*.data));
        const ic = internalOf(tmp.clock);
        if (ic.marked_corrupted != 0) continue;
        if (std.mem.orderZ(u8, ic.address, p.address) == .eq and ic.port == p.port) {
            cache = tmp;
            if (tmp.remove_id != null) {
                c.gst_clock_id_unschedule(tmp.remove_id);
                tmp.remove_id = null;
            }
            break;
        }
    }
    if (cache == null) {
        const ic: *Internal = @ptrCast(@alignCast(c.g_object_new(internalType(), "address", p.address, "port", p.port, "is-ntp", p.is_ntp, @as(?*anyopaque, null))));
        _ = c.gst_object_ref_sink(ic);
        if (ic.marked_corrupted != 0) {
            c.gst_object_unref(ic);
        } else {
            const nc = std.heap.c_allocator.create(Cache) catch unreachable;
            nc.* = .{ .clock = clk(ic), .clocks = null, .remove_id = null };
            clocks = c.g_list_prepend(clocks, nc);
            obj(ic).flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
            cache = nc;
        }
    }
    if (cache) |cc| {
        cc.clocks = c.g_list_prepend(cc.clocks, s);
        lock(cc.clock);
        if (c.gst_clock_is_synced(cc.clock) != 0) _ = c.gst_clock_set_synced(clk(s), 1);
        p.synced_id = c.g_signal_connect_data(cc.clock, "synced", @ptrCast(&syncedCb), s, null, 0);
        unlock(cc.clock);
        p.internal_clock = cc.clock;
    }
    clocks_lock.unlock();
    if (cache == null) _ = c.gst_clock_set_synced(clk(s), 0);
}

fn clientInternalTime(k: [*c]c.GstClock) callconv(.c) c.GstClockTime {
    const p = priv(k);
    if (p.internal_clock == null) return p.base_time;
    if (c.gst_clock_is_synced(p.internal_clock) == 0) {
        const now = c.gst_clock_get_internal_time(p.internal_clock);
        return c.gst_clock_adjust_with_calibration(p.internal_clock, now, p.internal_base_time, p.base_time, 1, 1);
    }
    return c.gst_clock_get_time(p.internal_clock);
}

fn clientClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    client_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    c.g_type_class_adjust_private_offset(k, &client_offset);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = clientFinalize;
    gc.get_property = clientGet;
    gc.set_property = clientSet;
    gc.constructed = clientConstructed;
    const ss = c.G_PARAM_STATIC_STRINGS;
    const ctor = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | ss;
    const rw = c.G_PARAM_READWRITE | ss;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_string("address", "address", "The IP address of the machine providing a time server", DEFAULT_ADDRESS, ctor));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_int("port", "port", "The port on which the remote server is listening", 0, 65535, DEFAULT_PORT, ctor));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_object("bus", "bus", "A GstBus on which to send clock status information", c.gst_bus_get_type(), rw));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_uint64("round-trip-limit", "round-trip limit", "Maximum tolerable round-trip interval for packets, in nanoseconds (0 = no limit)", 0, NONE, SECOND, rw));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_uint64("minimum-update-interval", "minimum update interval", "Minimum polling interval for packets, in nanoseconds(0 = no limit)", 0, NONE, MIN_UPDATE, rw));
    c.g_object_class_install_property(gc, 6, c.g_param_spec_uint64("base-time", "Base Time", "Initial time that is reported before synchronization", 0, NONE, 0, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | ss));
    c.g_object_class_install_property(gc, 7, c.g_param_spec_object("internal-clock", "Internal Clock", "Internal clock that directly slaved to the remote clock", c.gst_clock_get_type(), c.G_PARAM_READABLE | ss));
    c.g_object_class_install_property(gc, 9, c.g_param_spec_int("qos-dscp", "QoS diff srv code point", "Quality of Service, differentiated services code point (-1 default)", -1, 63, -1, rw));
    const cc: *c.GstClockClass = @ptrCast(@alignCast(k));
    cc.get_internal_time = clientInternalTime;
}

pub export fn gst_net_client_clock_get_type() c.GType {
    return client_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_system_clock_get_type, "GstNetClientClock", c.GstNetClientClockClass, Client, clientClassInit, clientInit, 0);
            client_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = internalType();
            return t;
        }
    }.f);
}

fn checkNew(comptime F: []const u8, addr: [*c]const u8, port: c.gint, base: u64) bool {
    if (!basic.that(addr != null, F, "remote_address != NULL")) return false;
    if (!basic.that(port > 0, F, "remote_port > 0")) return false;
    if (!basic.that(port <= 65535, F, "remote_port <= G_MAXUINT16")) return false;
    return basic.that(base != NONE, F, "base_time != GST_CLOCK_TIME_NONE");
}

pub export fn gst_net_client_clock_new(name: [*c]const u8, addr: [*c]const u8, port: c.gint, base: c.GstClockTime) [*c]c.GstClock {
    if (!checkNew("gst_net_client_clock_new", addr, port, base)) return null;
    const r = c.g_object_new(gst_net_client_clock_get_type(), "name", name, "address", addr, "port", port, "base-time", base, @as(?*anyopaque, null));
    _ = c.gst_object_ref_sink(r);
    return @ptrCast(@alignCast(r));
}

fn ntpInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    priv(inst).is_ntp = 1;
}

fn ntpClassInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

pub export fn gst_ntp_clock_get_type() c.GType {
    return ntp_once.get(struct {
        fn f() c.GType {
            return gtype.object(gst_net_client_clock_get_type, "GstNtpClock", c.GstNtpClockClass, c.GstNtpClock, ntpClassInit, ntpInit, 0);
        }
    }.f);
}

pub export fn gst_ntp_clock_new(name: [*c]const u8, addr: [*c]const u8, port: c.gint, base: c.GstClockTime) [*c]c.GstClock {
    if (!checkNew("gst_ntp_clock_new", addr, port, base)) return null;
    const r = c.g_object_new(gst_ntp_clock_get_type(), "name", name, "address", addr, "port", port, "base-time", base, @as(?*anyopaque, null));
    _ = c.gst_object_ref_sink(r);
    return @ptrCast(@alignCast(r));
}

pub export fn gst_net_client_clock_deinit() void {
    clocks_lock.lock();
    const list = clocks;
    clocks = null;
    var l = list;
    while (l != null) : (l = l.*.next) {
        const cache: *Cache = @ptrCast(@alignCast(l.*.data));
        if (cache.remove_id != null) {
            c.gst_clock_id_unschedule(cache.remove_id);
            c.gst_clock_id_unref(cache.remove_id);
        }
        c.gst_object_unref(cache.clock);
        std.heap.c_allocator.destroy(cache);
    }
    c.g_list_free(list);
    clocks_lock.unlock();
}
