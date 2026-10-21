const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const util = @import("util.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Clock = c.GstClock;
const Class = c.GstClockClass;
const Entry = c.GstClockEntry;
const Time = c.GstClockTime;
const NONE: u64 = std.math.maxInt(u64);
const SECOND: u64 = 1000000000;

pub const EntryImpl = extern struct {
    entry: Entry,
    clock: *c.GWeakRef,
    destroy: c.GDestroyNotify,
    ready: c.gboolean,
    lock: c.GMutex,
    seq: u32,
    padding: [16]c.gpointer,
};

const Private = extern struct {
    slave_lock: c.GMutex,
    sync_cond: c.GCond,
    internal: Time,
    external: Time,
    num: Time,
    denom: Time,
    last: Time,
    resolution: Time,
    master: [*c]Clock,
    filling: c.gboolean,
    window_size: c.gint,
    window_threshold: c.gint,
    index: c.gint,
    timeout: Time,
    times: [*c]Time,
    times_temp: [*c]Time,
    slave_id: c.GstClockID,
    pre: c.gint,
    post: c.gint,
    synced: c.gboolean,
    weak: *c.GWeakRef,
};

const PROP_WINDOW_SIZE = 1;
const PROP_WINDOW_THRESHOLD = 2;
const PROP_TIMEOUT = 3;

var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var synced_signal: c.guint = 0;

fn priv(p: anytype) *Private {
    const base: [*]u8 = @ptrCast(@constCast(p));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

pub fn classOf(p: anytype) *Class {
    return gtype.classPeek(Class, p);
}

fn isClock(p: anytype) bool {
    return gtype.instanceOf(p, gst_clock_get_type());
}

fn flagged(p: [*c]Clock, flag: c.guint) bool {
    return p[0].object.flags & flag != 0;
}

pub fn impl(id: c.GstClockID) *EntryImpl {
    return @ptrCast(@alignCast(id.?));
}

pub export fn gst_clock_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type(), "GstClock", Class, Clock, classInit, instanceInit, c.G_TYPE_FLAG_ABSTRACT);
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
    gc.finalize = finalize;
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const flags = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, PROP_WINDOW_SIZE, c.g_param_spec_int("window-size", "Window size", "The size of the window used to calculate rate and offset", 2, 1024, 32, flags));
    c.g_object_class_install_property(gc, PROP_WINDOW_THRESHOLD, c.g_param_spec_int("window-threshold", "Window threshold", "The threshold to start calculating rate and offset", 2, 1024, 4, flags));
    c.g_object_class_install_property(gc, PROP_TIMEOUT, c.g_param_spec_uint64("timeout", "Timeout", "The amount of time, in nanoseconds, to sample master and slave clocks", 0, NONE, SECOND / 10, flags));
    synced_signal = c.g_signal_new("synced", @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type, c.G_SIGNAL_RUN_LAST, 0, null, null, null, @as(c.GType, 1 << c.G_TYPE_FUNDAMENTAL_SHIFT), @as(c.guint, 1), @as(c.GType, c.G_TYPE_BOOLEAN));
}

fn allocTimes(d: *Private) void {
    const n: usize = @intCast(d.window_size);
    d.times = @ptrCast(@alignCast(c.g_realloc(d.times, 4 * n * @sizeOf(Time))));
    d.times_temp = d.times + 2 * n;
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Clock = @ptrCast(@alignCast(instance));
    const d = priv(p);
    p[0].priv = @ptrCast(d);
    d.num = 1;
    d.denom = 1;
    c.g_mutex_init(&d.slave_lock);
    c.g_cond_init(&d.sync_cond);
    d.window_size = 32;
    d.window_threshold = 4;
    d.filling = 1;
    d.timeout = SECOND / 10;
    d.times = null;
    allocTimes(d);
    @memset(d.times[0 .. 4 * 32], 0);
    d.weak = @ptrCast(@alignCast(c.g_atomic_rc_box_alloc0(@sizeOf(c.GWeakRef))));
    c.g_weak_ref_init(d.weak, p);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    object.lock(o);
    _ = object.gst_object_replace(@ptrCast(&priv(o).master), null);
    object.unlock(o);
    parent_class.?.dispose.?(o);
}

fn clearWeak(p: c.gpointer) callconv(.c) void {
    c.g_weak_ref_clear(@ptrCast(@alignCast(p)));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const d = priv(o);
    c.g_mutex_lock(&d.slave_lock);
    if (d.slave_id != null) {
        gst_clock_id_unschedule(d.slave_id);
        gst_clock_id_unref(d.slave_id);
        d.slave_id = null;
    }
    c.g_free(d.times);
    d.times = null;
    d.times_temp = null;
    c.g_mutex_unlock(&d.slave_lock);
    c.g_atomic_rc_box_release_full(d.weak, clearWeak);
    c.g_mutex_clear(&d.slave_lock);
    c.g_cond_clear(&d.sync_cond);
    parent_class.?.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const d = priv(o);
    switch (id) {
        PROP_WINDOW_SIZE => {
            c.g_mutex_lock(&d.slave_lock);
            d.window_size = c.g_value_get_int(v);
            d.window_threshold = @min(d.window_threshold, d.window_size);
            allocTimes(d);
            d.filling = 1;
            d.index = 0;
            c.g_mutex_unlock(&d.slave_lock);
        },
        PROP_WINDOW_THRESHOLD => {
            c.g_mutex_lock(&d.slave_lock);
            d.window_threshold = @min(c.g_value_get_int(v), d.window_size);
            c.g_mutex_unlock(&d.slave_lock);
        },
        PROP_TIMEOUT => gst_clock_set_timeout(@ptrCast(o), c.g_value_get_uint64(v)),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const d = priv(o);
    switch (id) {
        PROP_WINDOW_SIZE => {
            c.g_mutex_lock(&d.slave_lock);
            c.g_value_set_int(v, d.window_size);
            c.g_mutex_unlock(&d.slave_lock);
        },
        PROP_WINDOW_THRESHOLD => {
            c.g_mutex_lock(&d.slave_lock);
            c.g_value_set_int(v, d.window_threshold);
            c.g_mutex_unlock(&d.slave_lock);
        },
        PROP_TIMEOUT => c.g_value_set_uint64(v, gst_clock_get_timeout(@ptrCast(o))),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn newEntry(clock: [*c]Clock, time: Time, interval: Time, kind: c.GstClockEntryType) c.GstClockID {
    const e: *EntryImpl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(EntryImpl))));
    e.entry.refcount = 1;
    e.entry.clock = clock;
    e.clock = @ptrCast(@alignCast(c.g_atomic_rc_box_acquire(priv(clock).weak)));
    e.entry.type = kind;
    e.entry.time = time;
    e.entry.interval = interval;
    e.entry.status = c.GST_CLOCK_OK;
    return @ptrCast(e);
}

fn reinit(clock: [*c]Clock, id: c.GstClockID, time: Time, interval: Time, kind: c.GstClockEntryType) c.gboolean {
    const e = &impl(id).entry;
    if (!check.that(e.status != c.GST_CLOCK_BUSY, "gst_clock_entry_reinit", "entry->status != GST_CLOCK_BUSY")) return 0;
    if (!check.that(gst_clock_id_uses_clock(id, clock) != 0, "gst_clock_entry_reinit", "gst_clock_id_uses_clock ((GstClockID) entry, clock)")) return 0;
    e.type = kind;
    e.time = time;
    e.interval = interval;
    e.status = c.GST_CLOCK_OK;
    e.unscheduled = 0;
    e.woken_up = 0;
    return 1;
}

pub export fn gst_clock_single_shot_id_reinit(clock: [*c]Clock, id: c.GstClockID, time: Time) c.gboolean {
    if (!check.that(time != NONE, "gst_clock_single_shot_id_reinit", "GST_CLOCK_TIME_IS_VALID (time)")) return 0;
    return reinit(clock, id, time, NONE, c.GST_CLOCK_ENTRY_SINGLE);
}

pub export fn gst_clock_periodic_id_reinit(clock: [*c]Clock, id: c.GstClockID, start: Time, interval: Time) c.gboolean {
    const f = "gst_clock_periodic_id_reinit";
    if (!check.that(start != NONE, f, "GST_CLOCK_TIME_IS_VALID (start_time)")) return 0;
    if (!check.that(interval != NONE, f, "GST_CLOCK_TIME_IS_VALID (interval)")) return 0;
    return reinit(clock, id, start, interval, c.GST_CLOCK_ENTRY_PERIODIC);
}

pub export fn gst_clock_id_ref(id: c.GstClockID) c.GstClockID {
    if (!check.that(id != null, "gst_clock_id_ref", "id != NULL")) return null;
    _ = @atomicRmw(c.gint, &impl(id).entry.refcount, .Add, 1, .seq_cst);
    return id;
}

pub export fn gst_clock_id_unref(id: c.GstClockID) void {
    if (!check.that(id != null, "gst_clock_id_unref", "id != NULL")) return;
    const e = impl(id);
    if (@atomicRmw(c.gint, &e.entry.refcount, .Sub, 1, .seq_cst) != 1) return;
    if (e.entry.destroy_data) |d| d(e.entry.user_data);
    if (e.destroy) |d| d(e);
    c.g_atomic_rc_box_release_full(e.clock, clearWeak);
    c.g_free(e);
}

pub export fn gst_clock_new_single_shot_id(clock: [*c]Clock, time: Time) c.GstClockID {
    const f = "gst_clock_new_single_shot_id";
    if (!check.that(isClock(clock), f, "GST_IS_CLOCK (clock)")) return null;
    if (!check.that(time != NONE, f, "GST_CLOCK_TIME_IS_VALID (time)")) return null;
    return newEntry(clock, time, NONE, c.GST_CLOCK_ENTRY_SINGLE);
}

pub export fn gst_clock_new_periodic_id(clock: [*c]Clock, start: Time, interval: Time) c.GstClockID {
    const f = "gst_clock_new_periodic_id";
    if (!check.that(isClock(clock), f, "GST_IS_CLOCK (clock)")) return null;
    if (!check.that(start != NONE, f, "GST_CLOCK_TIME_IS_VALID (start_time)")) return null;
    if (!check.that(interval != 0, f, "interval != 0")) return null;
    if (!check.that(interval != NONE, f, "GST_CLOCK_TIME_IS_VALID (interval)")) return null;
    return newEntry(clock, start, interval, c.GST_CLOCK_ENTRY_PERIODIC);
}

pub export fn gst_clock_id_compare_func(a: c.gconstpointer, b: c.gconstpointer) c.gint {
    const ta = impl(@constCast(a)).entry.time;
    const tb = impl(@constCast(b)).entry.time;
    if (ta > tb) return 1;
    if (ta < tb) return -1;
    return 0;
}

pub export fn gst_clock_id_get_time(id: c.GstClockID) Time {
    if (!check.that(id != null, "gst_clock_id_get_time", "id != NULL")) return NONE;
    return impl(id).entry.time;
}

fn owner(id: c.GstClockID) [*c]Clock {
    return @ptrCast(@alignCast(c.g_weak_ref_get(impl(id).clock)));
}

pub export fn gst_clock_id_wait(id: c.GstClockID, jitter: [*c]c.GstClockTimeDiff) c.GstClockReturn {
    if (!check.that(id != null, "gst_clock_id_wait", "id != NULL")) return c.GST_CLOCK_ERROR;
    const e = &impl(id).entry;
    const requested = e.time;
    const clock = owner(id);
    if (clock == null) return c.GST_CLOCK_ERROR;
    defer c.gst_object_unref(clock);
    if (requested == NONE) return c.GST_CLOCK_BADTIME;
    const wait = classOf(clock).wait orelse return c.GST_CLOCK_UNSUPPORTED;
    const r = wait(clock, e, jitter);
    if (e.type == c.GST_CLOCK_ENTRY_PERIODIC) e.time = requested +% e.interval;
    return r;
}

pub export fn gst_clock_id_wait_async(id: c.GstClockID, func: c.GstClockCallback, data: c.gpointer, destroy: c.GDestroyNotify) c.GstClockReturn {
    const f = "gst_clock_id_wait_async";
    if (!check.that(id != null, f, "id != NULL")) return c.GST_CLOCK_ERROR;
    if (!check.that(func != null, f, "func != NULL")) return c.GST_CLOCK_ERROR;
    const e = &impl(id).entry;
    const clock = owner(id);
    if (clock == null) return c.GST_CLOCK_ERROR;
    defer c.gst_object_unref(clock);
    if (e.time == NONE) {
        _ = func.?(clock, NONE, id, data);
        return c.GST_CLOCK_BADTIME;
    }
    const wait = classOf(clock).wait_async orelse return c.GST_CLOCK_UNSUPPORTED;
    e.func = func;
    e.user_data = data;
    e.destroy_data = destroy;
    return wait(clock, e);
}

pub export fn gst_clock_id_unschedule(id: c.GstClockID) void {
    if (!check.that(id != null, "gst_clock_id_unschedule", "id != NULL")) return;
    const clock = owner(id);
    if (clock == null) return;
    defer c.gst_object_unref(clock);
    if (classOf(clock).unschedule) |u| u(clock, &impl(id).entry);
}

pub export fn gst_clock_id_get_clock(id: c.GstClockID) [*c]Clock {
    if (!check.that(id != null, "gst_clock_id_get_clock", "id != NULL")) return null;
    return owner(id);
}

pub export fn gst_clock_id_uses_clock(id: c.GstClockID, clock: [*c]Clock) c.gboolean {
    if (!check.that(id != null, "gst_clock_id_uses_clock", "id != NULL")) return 0;
    if (!check.that(clock != null, "gst_clock_id_uses_clock", "clock != NULL")) return 0;
    const have = owner(id);
    defer if (have != null) c.gst_object_unref(have);
    return @intFromBool(have == clock);
}

pub export fn gst_clock_set_resolution(clock: [*c]Clock, resolution: Time) Time {
    const f = "gst_clock_set_resolution";
    if (!check.that(isClock(clock), f, "GST_IS_CLOCK (clock)")) return 0;
    if (!check.that(resolution != 0, f, "resolution != 0")) return 0;
    const d = priv(clock);
    if (classOf(clock).change_resolution) |change| d.resolution = change(clock, d.resolution, resolution);
    return d.resolution;
}

pub export fn gst_clock_get_resolution(clock: [*c]Clock) Time {
    if (!check.that(isClock(clock), "gst_clock_get_resolution", "GST_IS_CLOCK (clock)")) return 0;
    if (classOf(clock).get_resolution) |get| return get(clock);
    return 1;
}

pub export fn gst_clock_adjust_with_calibration(_: [*c]Clock, target: Time, internal: Time, external: Time, num_in: Time, denom_in: Time) Time {
    var num = num_in;
    var denom = denom_in;
    if (denom == 0) {
        num = 1;
        denom = 1;
    }
    if (target >= internal) return util.gst_util_uint64_scale(target - internal, num, denom) +% external;
    const back = util.gst_util_uint64_scale(internal - target, num, denom);
    return if (external > back) external - back else 0;
}

pub export fn gst_clock_adjust_unlocked(clock: [*c]Clock, internal: Time) Time {
    const d = priv(clock);
    const r = gst_clock_adjust_with_calibration(clock, internal, d.internal, d.external, d.num, d.denom);
    d.last = @max(r, d.last);
    return d.last;
}

pub export fn gst_clock_unadjust_with_calibration(_: [*c]Clock, target: Time, internal: Time, external: Time, num_in: Time, denom_in: Time) Time {
    var num = num_in;
    var denom = denom_in;
    if (num == 0) {
        num = 1;
        denom = 1;
    }
    if (target >= external) return util.gst_util_uint64_scale(target - external, denom, num) +% internal;
    const back = util.gst_util_uint64_scale(external - target, denom, num);
    return if (internal > back) internal - back else 0;
}

pub export fn gst_clock_unadjust_unlocked(clock: [*c]Clock, external: Time) Time {
    const d = priv(clock);
    return gst_clock_unadjust_with_calibration(clock, external, d.internal, d.external, d.num, d.denom);
}

pub export fn gst_clock_get_internal_time(clock: [*c]Clock) Time {
    if (!check.that(isClock(clock), "gst_clock_get_internal_time", "GST_IS_CLOCK (clock)")) return NONE;
    if (flagged(clock, c.GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC) and priv(clock).synced == 0)
        info.gst_debug_log(info.GST_CAT_CLOCK, c.GST_LEVEL_WARNING, "../gst/gstclock.c", "gst_clock_get_internal_time", 0, @ptrCast(clock), "called get_internal_time() before syncing");
    const get = classOf(clock).get_internal_time orelse return 0;
    return get(clock);
}

fn seqBegin(d: *Private) c.gint {
    return @atomicLoad(c.gint, &d.post, .seq_cst);
}

fn seqRetry(clock: [*c]Clock, d: *Private, seq: c.gint) bool {
    if (seq == @atomicLoad(c.gint, &d.pre, .seq_cst)) return false;
    object.lock(clock);
    object.unlock(clock);
    return true;
}

pub export fn gst_clock_get_time(clock: [*c]Clock) Time {
    if (!check.that(isClock(clock), "gst_clock_get_time", "GST_IS_CLOCK (clock)")) return NONE;
    const d = priv(clock);
    while (true) {
        const raw = gst_clock_get_internal_time(clock);
        const seq = seqBegin(d);
        const r = gst_clock_adjust_unlocked(clock, raw);
        if (!seqRetry(clock, d, seq)) return r;
    }
}

pub export fn gst_clock_set_calibration(clock: [*c]Clock, internal: Time, external: Time, num: Time, denom: Time) void {
    const f = "gst_clock_set_calibration";
    if (!check.that(isClock(clock), f, "GST_IS_CLOCK (clock)")) return;
    if (!check.that(internal != NONE, f, "GST_CLOCK_TIME_IS_VALID (internal)")) return;
    if (!check.that(external != NONE, f, "GST_CLOCK_TIME_IS_VALID (external)")) return;
    if (!check.that(num != NONE, f, "rate_num != GST_CLOCK_TIME_NONE")) return;
    if (!check.that(denom > 0 and denom != NONE, f, "rate_denom > 0 && rate_denom != GST_CLOCK_TIME_NONE")) return;
    const d = priv(clock);
    object.lock(clock);
    _ = @atomicRmw(c.gint, &d.pre, .Add, 1, .seq_cst);
    d.internal = internal;
    d.external = external;
    d.num = num;
    d.denom = denom;
    _ = @atomicRmw(c.gint, &d.post, .Add, 1, .seq_cst);
    object.unlock(clock);
}

pub export fn gst_clock_get_calibration(clock: [*c]Clock, internal: [*c]Time, external: [*c]Time, num: [*c]Time, denom: [*c]Time) void {
    if (!check.that(isClock(clock), "gst_clock_get_calibration", "GST_IS_CLOCK (clock)")) return;
    const d = priv(clock);
    while (true) {
        const seq = seqBegin(d);
        if (num != null) num.* = d.num;
        if (denom != null) denom.* = d.denom;
        if (external != null) external.* = d.external;
        if (internal != null) internal.* = d.internal;
        if (!seqRetry(clock, d, seq)) return;
    }
}

fn slaveTick(master: [*c]Clock, _: Time, _: c.GstClockID, data: c.gpointer) callconv(.c) c.gboolean {
    const clock: [*c]Clock = @ptrCast(@alignCast(data));
    if (gst_clock_is_synced(clock) == 0) return 1;
    const stime = gst_clock_get_internal_time(clock);
    const mtime = gst_clock_get_time(master);
    var r2: f64 = 0;
    _ = gst_clock_add_observation(clock, stime, mtime, &r2);
    return 1;
}

fn unrefObject(p: c.gpointer) callconv(.c) void {
    c.gst_object_unref(p);
}

pub export fn gst_clock_set_master(clock: [*c]Clock, master: [*c]Clock) c.gboolean {
    const f = "gst_clock_set_master";
    if (!check.that(isClock(clock), f, "GST_IS_CLOCK (clock)")) return 0;
    if (!check.that(master != clock, f, "master != clock")) return 0;
    object.lock(clock);
    if (master != null and !flagged(clock, c.GST_CLOCK_FLAG_CAN_SET_MASTER)) {
        object.unlock(clock);
        return 0;
    }
    if (master != null and gst_clock_is_synced(master) == 0) {
        object.unlock(clock);
        return 0;
    }
    object.unlock(clock);
    const d = priv(clock);
    c.g_mutex_lock(&d.slave_lock);
    if (d.slave_id != null) {
        gst_clock_id_unschedule(d.slave_id);
        gst_clock_id_unref(d.slave_id);
        d.slave_id = null;
    }
    if (master != null) {
        d.filling = 1;
        d.index = 0;
        d.slave_id = gst_clock_new_periodic_id(master, gst_clock_get_time(master), d.timeout);
        _ = gst_clock_id_wait_async(d.slave_id, slaveTick, c.gst_object_ref(clock), unrefObject);
    }
    c.g_mutex_unlock(&d.slave_lock);
    object.lock(clock);
    _ = object.gst_object_replace(@ptrCast(&d.master), @ptrCast(master));
    object.unlock(clock);
    return 1;
}

pub export fn gst_clock_get_master(clock: [*c]Clock) [*c]Clock {
    if (!check.that(isClock(clock), "gst_clock_get_master", "GST_IS_CLOCK (clock)")) return null;
    object.lock(clock);
    defer object.unlock(clock);
    const m = priv(clock).master;
    return if (m != null) @ptrCast(@alignCast(c.gst_object_ref(m))) else null;
}

pub export fn gst_clock_add_observation(clock: [*c]Clock, internal: Time, external: Time, r_squared: [*c]c.gdouble) c.gboolean {
    var xbase: Time = 0;
    var b: Time = 0;
    var num: Time = 0;
    var denom: Time = 0;
    if (gst_clock_add_observation_unapplied(clock, internal, external, r_squared, &xbase, &b, &num, &denom) == 0) return 0;
    gst_clock_set_calibration(clock, xbase, b, num, denom);
    return 1;
}

pub export fn gst_clock_add_observation_unapplied(clock: [*c]Clock, internal_obs: Time, external_obs: Time, r_squared: [*c]c.gdouble, internal: [*c]Time, external: [*c]Time, num: [*c]Time, denom: [*c]Time) c.gboolean {
    const f = "gst_clock_add_observation_unapplied";
    if (!check.that(isClock(clock), f, "GST_IS_CLOCK (clock)")) return 0;
    if (!check.that(internal_obs != NONE, f, "GST_CLOCK_TIME_IS_VALID (internal_observation)")) return 0;
    if (!check.that(external_obs != NONE, f, "GST_CLOCK_TIME_IS_VALID (external_observation)")) return 0;
    if (!check.that(r_squared != null, f, "r_squared != NULL")) return 0;
    const d = priv(clock);
    c.g_mutex_lock(&d.slave_lock);
    defer c.g_mutex_unlock(&d.slave_lock);
    const i: usize = @intCast(d.index);
    d.times[2 * i] = internal_obs;
    d.times[2 * i + 1] = external_obs;
    d.index += 1;
    if (d.index == d.window_size) {
        d.filling = 0;
        d.index = 0;
    }
    if (d.filling != 0 and d.index < d.window_threshold) return 0;
    const n: c.guint = @intCast(if (d.filling != 0) d.index else d.window_size);
    var m_num: Time = 0;
    var m_denom: Time = 0;
    var b: Time = 0;
    var xbase: Time = 0;
    if (util.gst_calculate_linear_regression(d.times, d.times_temp, n, &m_num, &m_denom, &b, &xbase, r_squared) == 0) return 0;
    if (internal != null) internal.* = xbase;
    if (external != null) external.* = b;
    if (num != null) num.* = m_num;
    if (denom != null) denom.* = m_denom;
    return 1;
}

pub export fn gst_clock_set_timeout(clock: [*c]Clock, timeout: Time) void {
    if (!check.that(isClock(clock), "gst_clock_set_timeout", "GST_IS_CLOCK (clock)")) return;
    const d = priv(clock);
    c.g_mutex_lock(&d.slave_lock);
    d.timeout = timeout;
    c.g_mutex_unlock(&d.slave_lock);
}

pub export fn gst_clock_get_timeout(clock: [*c]Clock) Time {
    if (!check.that(isClock(clock), "gst_clock_get_timeout", "GST_IS_CLOCK (clock)")) return NONE;
    const d = priv(clock);
    c.g_mutex_lock(&d.slave_lock);
    defer c.g_mutex_unlock(&d.slave_lock);
    return d.timeout;
}

pub export fn gst_clock_wait_for_sync(clock: [*c]Clock, timeout: Time) c.gboolean {
    if (!check.that(isClock(clock), "gst_clock_wait_for_sync", "GST_IS_CLOCK (clock)")) return 0;
    const d = priv(clock);
    object.lock(clock);
    defer object.unlock(clock);
    if (!flagged(clock, c.GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC) or d.synced != 0) return 1;
    const m = &object.of(clock).lock;
    if (timeout == NONE) {
        while (d.synced == 0) c.g_cond_wait(&d.sync_cond, m);
        return 1;
    }
    const end = c.g_get_monotonic_time() + @as(i64, @bitCast(util.gst_util_uint64_scale(timeout, 1000000, SECOND)));
    while (d.synced == 0) {
        if (c.g_cond_wait_until(&d.sync_cond, m, end) == 0) return 0;
    }
    return 1;
}

pub export fn gst_clock_is_synced(clock: [*c]Clock) c.gboolean {
    if (!check.that(isClock(clock), "gst_clock_is_synced", "GST_IS_CLOCK (clock)")) return 1;
    return @intFromBool(!flagged(clock, c.GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC) or priv(clock).synced != 0);
}

pub export fn gst_clock_set_synced(clock: [*c]Clock, synced: c.gboolean) void {
    const f = "gst_clock_set_synced";
    if (!check.that(isClock(clock), f, "GST_IS_CLOCK (clock)")) return;
    if (!check.that(flagged(clock, c.GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC), f, "GST_OBJECT_FLAG_IS_SET (clock, GST_CLOCK_FLAG_NEEDS_STARTUP_SYNC)")) return;
    const d = priv(clock);
    const want: c.gboolean = @intFromBool(synced != 0);
    object.lock(clock);
    if (d.synced == want) {
        object.unlock(clock);
        return;
    }
    d.synced = want;
    c.g_cond_signal(&d.sync_cond);
    object.unlock(clock);
    c.g_signal_emit(clock, synced_signal, 0, want);
}
