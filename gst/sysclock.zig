const std = @import("std");
const linux = std.os.linux;
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const clock = @import("clock.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Clock = c.GstClock;
const SysClock = c.GstSystemClock;
const Entry = c.GstClockEntry;
const Time = c.GstClockTime;
const EntryImpl = clock.EntryImpl;
const NONE: u64 = std.math.maxInt(u64);
const USECOND: i64 = 1000;
const MSECOND: i64 = 1000000;
const MIN_WAIT: i64 = 100;

const Private = extern struct {
    thread: ?*c.GThread,
    starting: c.gboolean,
    stopping: c.gboolean,
    entries: [*c]c.GList,
    changed: c.GCond,
    kind: c.GstClockType,
};

const PROP_CLOCK_TYPE = 1;

var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var the_clock: [*c]Clock = null;
var external_default = false;
var global_lock: c.GMutex = std.mem.zeroes(c.GMutex);

fn priv(p: anytype) *Private {
    const base: [*]u8 = @ptrCast(@constCast(p));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

fn nowOf(id: linux.clockid_t) Time {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(id, &ts)) != .SUCCESS) return NONE;
    return @as(u64, @intCast(ts.sec)) * 1000000000 + @as(u64, @intCast(ts.nsec));
}

pub fn monotonic() Time {
    return nowOf(.MONOTONIC);
}

pub fn realtime() Time {
    return nowOf(.REALTIME);
}

fn posixId(kind: c.GstClockType) linux.clockid_t {
    return switch (kind) {
        c.GST_CLOCK_TYPE_MONOTONIC => .MONOTONIC,
        c.GST_CLOCK_TYPE_TAI => @enumFromInt(11),
        else => .REALTIME,
    };
}

fn objLock(p: anytype) *c.GMutex {
    return &object.of(p).lock;
}

fn entryOf(e: anytype) *EntryImpl {
    return @ptrCast(@alignCast(e));
}

fn ensure(e: *EntryImpl) void {
    if (e.ready != 0) return;
    c.g_mutex_init(&e.lock);
    e.destroy = clearEntry;
    e.ready = 1;
}

fn clearEntry(p: c.gpointer) callconv(.c) void {
    c.g_mutex_clear(&entryOf(p).lock);
}

fn broadcast(e: *EntryImpl) void {
    _ = @atomicRmw(u32, &e.seq, .Add, 1, .seq_cst);
    _ = linux.futex_3arg(&e.seq, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
}

fn waitUntil(e: *EntryImpl, end: i64) bool {
    if (end < 0) return false;
    const sampled = @atomicLoad(u32, &e.seq, .seq_cst);
    c.g_mutex_unlock(&e.lock);
    const ts = linux.timespec{ .sec = @divTrunc(end, 1000000000), .nsec = @rem(end, 1000000000) };
    const r = linux.futex(&e.seq, .{ .cmd = .WAIT_BITSET, .private = true }, sampled, .{ .timeout = &ts }, null, 0xffffffff);
    c.g_mutex_lock(&e.lock);
    return linux.errno(r) != .TIMEDOUT;
}

fn sleepUntil(end: i64) bool {
    const ts = linux.timespec{ .sec = @divTrunc(end, 1000000000), .nsec = @rem(end, 1000000000) };
    return linux.errno(linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &ts, null)) == .SUCCESS;
}

pub export fn gst_system_clock_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(clock.gst_clock_get_type, "GstSystemClock", c.GstSystemClockClass, SysClock, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.dispose = dispose;
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    c.g_object_class_install_property(gc, PROP_CLOCK_TYPE, c.g_param_spec_enum("clock-type", "Clock type", "The type of underlying clock implementation used", c.gst_clock_type_get_type(), c.GST_CLOCK_TYPE_MONOTONIC, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    const k: *c.GstClockClass = @ptrCast(@alignCast(klass));
    k.get_internal_time = internalTime;
    k.get_resolution = resolution;
    k.wait = waitJitter;
    k.wait_async = waitAsync;
    k.unschedule = unschedule;
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]SysClock = @ptrCast(@alignCast(instance));
    p[0].clock.object.flags |= c.GST_CLOCK_FLAG_CAN_DO_SINGLE_SYNC | c.GST_CLOCK_FLAG_CAN_DO_SINGLE_ASYNC | c.GST_CLOCK_FLAG_CAN_DO_PERIODIC_SYNC | c.GST_CLOCK_FLAG_CAN_DO_PERIODIC_ASYNC;
    const d = priv(p);
    p[0].priv = @ptrCast(d);
    d.kind = c.GST_CLOCK_TYPE_MONOTONIC;
    c.g_cond_init(&d.changed);
}

fn unrefEntry(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    clock.gst_clock_id_unref(data);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const d = priv(o);
    c.g_mutex_lock(objLock(o));
    d.stopping = 1;
    var node = d.entries;
    while (node != null) : (node = node[0].next) {
        const e = entryOf(node[0].data);
        e.entry.status = c.GST_CLOCK_UNSCHEDULED;
        if (node[0].prev == null) {
            c.g_mutex_lock(&e.lock);
            broadcast(e);
            c.g_mutex_unlock(&e.lock);
        }
    }
    c.g_cond_broadcast(&d.changed);
    c.g_mutex_unlock(objLock(o));
    if (d.thread) |t| _ = c.g_thread_join(t);
    d.thread = null;
    c.g_list_foreach(d.entries, unrefEntry, null);
    c.g_list_free(d.entries);
    d.entries = null;
    c.g_cond_clear(&d.changed);
    parent_class.?.dispose.?(o);
    if (the_clock == @as([*c]Clock, @ptrCast(@alignCast(o)))) the_clock = null;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_CLOCK_TYPE) priv(o).kind = @intCast(c.g_value_get_enum(v)) else object.warnBadProperty(o, id, pspec);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_CLOCK_TYPE) c.g_value_set_enum(v, @intCast(priv(o).kind)) else object.warnBadProperty(o, id, pspec);
}

pub export fn gst_system_clock_set_default(new: [*c]Clock) void {
    c.g_mutex_lock(&global_lock);
    defer c.g_mutex_unlock(&global_lock);
    if (the_clock != null) c.gst_object_unref(the_clock);
    external_default = new != null;
    if (new != null) _ = c.g_object_ref(new);
    the_clock = new;
}

pub export fn gst_system_clock_obtain() [*c]Clock {
    c.g_mutex_lock(&global_lock);
    if (the_clock == null) {
        const o = c.g_object_new(gst_system_clock_get_type(), "name", "GstSystemClock", @as([*c]const u8, null));
        _ = object.gst_object_ref_sink(o);
        the_clock = @ptrCast(@alignCast(o));
        the_clock[0].object.flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
    }
    const r = the_clock;
    c.g_mutex_unlock(&global_lock);
    _ = c.gst_object_ref(r);
    return r;
}

fn asyncThread(data: c.gpointer) callconv(.c) c.gpointer {
    const p: [*c]Clock = @ptrCast(@alignCast(data));
    const d = priv(p);
    const lock = objLock(p);
    c.g_mutex_lock(lock);
    d.starting = 0;
    c.g_cond_broadcast(&d.changed);
    outer: while (d.stopping == 0) {
        while (d.entries == null) {
            c.g_cond_wait(&d.changed, lock);
            if (d.stopping != 0) break :outer;
        }
        const e = entryOf(d.entries[0].data);
        c.g_mutex_lock(&e.lock);
        const status = e.entry.status;
        var drop = true;
        if (status == c.GST_CLOCK_UNSCHEDULED) {
            c.g_mutex_unlock(lock);
            c.g_mutex_unlock(&e.lock);
        } else {
            if (status != c.GST_CLOCK_OK and status != c.GST_CLOCK_EARLY)
                info.gst_debug_log(info.GST_CAT_CLOCK, c.GST_LEVEL_ERROR, "../gst/gstsystemclock.c", "gst_system_clock_async_thread", 0, @ptrCast(p), "unexpected status %d for entry %p", status, e);
            e.entry.status = c.GST_CLOCK_BUSY;
            const requested = e.entry.time;
            c.g_mutex_unlock(lock);
            const r = waitUnlocked(p, e, null, false);
            switch (r) {
                c.GST_CLOCK_OK, c.GST_CLOCK_EARLY => {
                    c.g_mutex_unlock(&e.lock);
                    if (e.entry.func) |func| _ = func(p, e.entry.time, @ptrCast(e), e.entry.user_data);
                    if (e.entry.type == c.GST_CLOCK_ENTRY_PERIODIC) {
                        c.g_mutex_lock(lock);
                        e.entry.time = requested +% e.entry.interval;
                        d.entries = c.g_list_sort(d.entries, clock.gst_clock_id_compare_func);
                        drop = false;
                    }
                },
                c.GST_CLOCK_BUSY => {
                    e.entry.status = c.GST_CLOCK_OK;
                    c.g_mutex_unlock(&e.lock);
                    c.g_mutex_lock(lock);
                    drop = false;
                },
                c.GST_CLOCK_UNSCHEDULED => c.g_mutex_unlock(&e.lock),
                else => {
                    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: strange result %d waiting for %p, skipping", p[0].object.name, r, e);
                    c.g_mutex_unlock(&e.lock);
                },
            }
        }
        if (drop) {
            c.g_mutex_lock(lock);
            d.entries = c.g_list_remove(d.entries, e);
            clock.gst_clock_id_unref(@ptrCast(e));
        }
    }
    c.g_cond_broadcast(&d.changed);
    c.g_mutex_unlock(lock);
    return null;
}

fn internalTime(p: [*c]Clock) callconv(.c) Time {
    return switch (priv(p).kind) {
        c.GST_CLOCK_TYPE_MONOTONIC => monotonic(),
        c.GST_CLOCK_TYPE_REALTIME => realtime(),
        else => |k| nowOf(posixId(k)),
    };
}

fn resolution(p: [*c]Clock) callconv(.c) Time {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_getres(posixId(priv(p).kind), &ts)) != .SUCCESS) return NONE;
    return @as(u64, @intCast(ts.sec)) * 1000000000 + @as(u64, @intCast(ts.nsec));
}

fn diffOf(now: Time, target: Time) i64 {
    return @as(i64, @bitCast(target)) -% @as(i64, @bitCast(now));
}

fn waitUnlocked(p: [*c]Clock, e: *EntryImpl, jitter: [*c]c.GstClockTimeDiff, restart: bool) c.GstClockReturn {
    c.g_mutex_unlock(&e.lock);
    var now = clock.gst_clock_get_time(p);
    var mono = c.g_get_monotonic_time();
    c.g_mutex_lock(&e.lock);
    var status = e.entry.status;
    if (status == c.GST_CLOCK_UNSCHEDULED) return status;
    const target = e.entry.time;
    var diff = diffOf(now, target);
    if (jitter != null) jitter.* = -%diff;
    if (diff <= MIN_WAIT) {
        status = if (diff == 0) c.GST_CLOCK_OK else c.GST_CLOCK_EARLY;
        e.entry.status = status;
        return status;
    }
    while (true) {
        var woke: bool = undefined;
        if (diff <= 500 * USECOND) {
            c.g_mutex_unlock(&e.lock);
            woke = sleepUntil(mono * 1000 + diff);
            c.g_mutex_lock(&e.lock);
        } else {
            if (diff < 2 * MSECOND) diff -= 500 * USECOND;
            woke = waitUntil(e, mono * 1000 + diff);
        }
        status = e.entry.status;
        if (status == c.GST_CLOCK_UNSCHEDULED) return status;
        if (status != c.GST_CLOCK_BUSY)
            info.gst_debug_log(info.GST_CAT_CLOCK, c.GST_LEVEL_ERROR, "../gst/gstsystemclock.c", "gst_system_clock_id_wait_jitter_unlocked", 0, @ptrCast(p), "unexpected status %d for entry %p", status, e);
        e.entry.status = c.GST_CLOCK_DONE;
        if (woke and !restart) return status;
        c.g_mutex_unlock(&e.lock);
        now = clock.gst_clock_get_time(p);
        mono = c.g_get_monotonic_time();
        c.g_mutex_lock(&e.lock);
        status = e.entry.status;
        if (status == c.GST_CLOCK_UNSCHEDULED) return status;
        diff = diffOf(now, target);
        if (diff <= MIN_WAIT) {
            e.entry.status = c.GST_CLOCK_OK;
            return c.GST_CLOCK_OK;
        }
        e.entry.status = c.GST_CLOCK_BUSY;
    }
}

fn waitJitter(p: [*c]Clock, entry: [*c]Entry, jitter: [*c]c.GstClockTimeDiff) callconv(.c) c.GstClockReturn {
    const e = entryOf(entry);
    c.g_mutex_lock(objLock(p));
    ensure(e);
    c.g_mutex_unlock(objLock(p));
    c.g_mutex_lock(&e.lock);
    defer c.g_mutex_unlock(&e.lock);
    const status = e.entry.status;
    if (status == c.GST_CLOCK_UNSCHEDULED) return status;
    if (status != c.GST_CLOCK_OK)
        info.gst_debug_log(info.GST_CAT_CLOCK, c.GST_LEVEL_ERROR, "../gst/gstsystemclock.c", "gst_system_clock_id_wait_jitter", 0, @ptrCast(p), "unexpected status %d for entry %p", status, e);
    e.entry.status = c.GST_CLOCK_BUSY;
    return waitUnlocked(p, e, jitter, true);
}

fn startAsync(p: [*c]Clock) bool {
    const d = priv(p);
    if (d.thread != null) return true;
    d.starting = 1;
    var err: [*c]c.GError = null;
    d.thread = c.g_thread_try_new("GstSystemClock", asyncThread, p, &err);
    if (err != null) {
        d.starting = 0;
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "could not create async clock thread: %s", err[0].message);
        c.g_error_free(err);
        return false;
    }
    while (d.starting != 0) c.g_cond_wait(&d.changed, objLock(p));
    return true;
}

fn waitAsync(p: [*c]Clock, entry: [*c]Entry) callconv(.c) c.GstClockReturn {
    const d = priv(p);
    const e = entryOf(entry);
    c.g_mutex_lock(objLock(p));
    defer c.g_mutex_unlock(objLock(p));
    if (!startAsync(p)) return c.GST_CLOCK_ERROR;
    ensure(e);
    c.g_mutex_lock(&e.lock);
    if (e.entry.status == c.GST_CLOCK_UNSCHEDULED) {
        c.g_mutex_unlock(&e.lock);
        return c.GST_CLOCK_UNSCHEDULED;
    }
    c.g_mutex_unlock(&e.lock);
    const head: ?*EntryImpl = if (d.entries != null) entryOf(d.entries[0].data) else null;
    _ = clock.gst_clock_id_ref(@ptrCast(e));
    d.entries = c.g_list_insert_sorted(d.entries, e, clock.gst_clock_id_compare_func);
    if (d.entries[0].data == @as(c.gpointer, @ptrCast(e))) {
        if (head) |h| {
            c.g_mutex_lock(&h.lock);
            if (h.entry.status == c.GST_CLOCK_BUSY) broadcast(h);
            c.g_mutex_unlock(&h.lock);
        } else c.g_cond_broadcast(&d.changed);
    }
    return c.GST_CLOCK_OK;
}

fn unschedule(p: [*c]Clock, entry: [*c]Entry) callconv(.c) void {
    const e = entryOf(entry);
    c.g_mutex_lock(objLock(p));
    defer c.g_mutex_unlock(objLock(p));
    ensure(e);
    c.g_mutex_lock(&e.lock);
    const status = e.entry.status;
    e.entry.status = c.GST_CLOCK_UNSCHEDULED;
    if (status == c.GST_CLOCK_BUSY) broadcast(e);
    c.g_mutex_unlock(&e.lock);
}

pub export fn gst_clock_is_system_monotonic(p: [*c]Clock) c.gboolean {
    if (!check.that(gtype.instanceOf(p, clock.gst_clock_get_type()), "gst_clock_is_system_monotonic", "GST_IS_CLOCK (clock)")) return 0;
    if (gtype.typeOf(p) != gst_system_clock_get_type()) return 0;
    if (priv(p).kind != c.GST_CLOCK_TYPE_MONOTONIC) return 0;
    c.g_mutex_lock(&global_lock);
    defer c.g_mutex_unlock(&global_lock);
    return @intFromBool(p == the_clock);
}
