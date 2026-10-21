const std = @import("std");
const linux = std.os.linux;
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const fields = @import("fields.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Task = c.GstTask;
const Pool = c.GstTaskPool;
const Shared = c.GstSharedTaskPool;

const TaskPrivate = extern struct {
    enter: c.GstTaskThreadFunc,
    enter_data: c.gpointer,
    enter_notify: c.GDestroyNotify,
    leave: c.GstTaskThreadFunc,
    leave_data: c.gpointer,
    leave_notify: c.GDestroyNotify,
    pool: [*c]Pool,
    id: c.gpointer,
    pool_id: [*c]Pool,
};

const SharedPrivate = extern struct { max_threads: c.guint };

var task_offset: c.gint = 0;
var shared_offset: c.gint = 0;
var task_parent: ?*c.GObjectClass = null;
var pool_parent: ?*c.GObjectClass = null;
var task_once: gtype.Once = .{};
var pool_once: gtype.Once = .{};
var shared_once: gtype.Once = .{};
var pool_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var global_pool: [*c]Pool = null;
var task_cat: [*c]c.GstDebugCategory = null;
var pool_cat: [*c]c.GstDebugCategory = null;

fn at(comptime T: type, p: anytype, offset: c.gint) *T {
    const base: [*]u8 = @ptrCast(@constCast(p));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, offset)))));
}

fn priv(t: anytype) *TaskPrivate {
    return at(TaskPrivate, t, task_offset);
}

fn isTask(p: anytype) bool {
    return gtype.instanceOf(p, gst_task_get_type());
}

fn isPool(p: anytype) bool {
    return gtype.instanceOf(p, gst_task_pool_get_type());
}

fn state(t: [*c]Task) c.GstTaskState {
    return @atomicLoad(c.GstTaskState, &t[0].state, .seq_cst);
}

fn setState(t: [*c]Task, s: c.GstTaskState) void {
    @atomicStore(c.GstTaskState, &t[0].state, s, .seq_cst);
}

fn objLock(p: anytype) *c.GMutex {
    return &object.of(p).lock;
}

fn signal(t: [*c]Task) void {
    c.g_cond_signal(&t[0].cond);
}

fn wait(t: [*c]Task) void {
    c.g_cond_wait(&t[0].cond, objLock(t));
}

fn stateName(s: c.GstTaskState) [*c]const u8 {
    return switch (s) {
        c.GST_TASK_STARTED => "started",
        c.GST_TASK_PAUSED => "paused",
        c.GST_TASK_STOPPED => "stopped",
        else => "(unknown)",
    };
}

pub export fn gst_task_get_type() c.GType {
    return task_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type, "GstTask", c.GstTaskClass, Task, taskClassInit, taskInit, 0);
            task_offset = c.g_type_add_instance_private(t, @sizeOf(TaskPrivate));
            task_cat = info._gst_debug_category_new("task", 0, "Processing tasks");
            return t;
        }
    }.f);
}

fn taskClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &task_offset);
    task_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(klass))).finalize = taskFinalize;
}

fn taskInit(instance: [*c]c.GTypeInstance, klass: c.gpointer) callconv(.c) void {
    const t: [*c]Task = @ptrCast(@alignCast(instance));
    const k: *c.GstTaskClass = @ptrCast(@alignCast(klass));
    t[0].priv = @ptrCast(priv(t));
    t[0].running = 0;
    t[0].thread = null;
    t[0].lock = null;
    c.g_cond_init(&t[0].cond);
    setState(t, c.GST_TASK_STOPPED);
    c.g_mutex_lock(&pool_lock);
    if (global_pool == null) {
        global_pool = gst_task_pool_new();
        gst_task_pool_prepare(global_pool, null);
        global_pool[0].object.flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
    }
    k.pool = global_pool;
    priv(t).pool = @ptrCast(@alignCast(c.gst_object_ref(k.pool)));
    c.g_mutex_unlock(&pool_lock);
}

fn taskFinalize(o: [*c]c.GObject) callconv(.c) void {
    const t: [*c]Task = @ptrCast(@alignCast(o));
    const d = priv(t);
    if (d.enter_notify) |n| n(d.enter_data);
    if (d.leave_notify) |n| n(d.leave_data);
    if (t[0].notify) |n| n(t[0].user_data);
    c.gst_object_unref(d.pool);
    c.g_cond_clear(&t[0].cond);
    task_parent.?.finalize.?(o);
}

fn nameThread(t: [*c]Task) void {
    object.lock(t);
    defer object.unlock(t);
    var buf: [17]u8 = .{0} ** 17;
    const n = t[0].object.name;
    const src: []const u8 = if (n == null) "(NULL)" else std.mem.span(n);
    const len = @min(src.len, 16);
    @memcpy(buf[0..len], src[0..len]);
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr(&buf), 0, 0, 0);
}

fn run(data: c.gpointer) callconv(.c) void {
    const t: [*c]Task = @ptrCast(@alignCast(data));
    const d = priv(t);
    const self = c.g_thread_self();
    object.lock(t);
    body: {
        if (state(t) == c.GST_TASK_STOPPED) break :body;
        const lock = t[0].lock;
        if (lock == null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "starting task without a lock");
            break :body;
        }
        t[0].thread = self;
        object.unlock(t);
        if (d.enter) |f| f(t, self, d.enter_data);
        c.g_rec_mutex_lock(lock);
        nameThread(t);
        while (state(t) != c.GST_TASK_STOPPED) {
            object.lock(t);
            while (t[0].state == c.GST_TASK_PAUSED) {
                c.g_rec_mutex_unlock(lock);
                signal(t);
                wait(t);
                object.unlock(t);
                c.g_rec_mutex_lock(lock);
                object.lock(t);
            }
            if (state(t) == c.GST_TASK_STOPPED) {
                object.unlock(t);
                break;
            }
            object.unlock(t);
            t[0].func.?(t[0].user_data);
        }
        c.g_rec_mutex_unlock(lock);
        object.lock(t);
        t[0].thread = null;
    }
    if (d.leave) |f| {
        object.unlock(t);
        f(t, self, d.leave_data);
        object.lock(t);
    }
    t[0].running = 0;
    signal(t);
    object.unlock(t);
    c.gst_object_unref(t);
}

pub export fn gst_task_cleanup_all() void {
    const k: ?*c.GstTaskClass = @ptrCast(@alignCast(c.g_type_class_peek(gst_task_get_type())));
    if (k) |klass| if (klass.pool != null) {
        c.g_mutex_lock(&pool_lock);
        gst_task_pool_cleanup(klass.pool);
        c.gst_object_unref(klass.pool);
        klass.pool = null;
        global_pool = null;
        c.g_mutex_unlock(&pool_lock);
    };
}

pub export fn gst_task_new(func: c.GstTaskFunction, data: c.gpointer, notify: c.GDestroyNotify) [*c]Task {
    if (!check.that(func != null, "gst_task_new", "func != NULL")) return null;
    const t: [*c]Task = @ptrCast(@alignCast(c.g_object_new(gst_task_get_type(), @as([*c]const u8, null))));
    t[0].func = func;
    t[0].user_data = data;
    t[0].notify = notify;
    _ = object.gst_object_ref_sink(t);
    return t;
}

pub export fn gst_task_set_lock(t: [*c]Task, m: [*c]c.GRecMutex) void {
    if (!check.that(isTask(t), "gst_task_set_lock", "GST_IS_TASK (task)")) return;
    object.lock(t);
    if (t[0].running != 0) {
        object.unlock(t);
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "cannot call set_lock on a running task");
        return;
    }
    t[0].lock = m;
    object.unlock(t);
}

pub export fn gst_task_get_pool(t: [*c]Task) [*c]Pool {
    if (!check.that(isTask(t), "gst_task_get_pool", "GST_IS_TASK (task)")) return null;
    object.lock(t);
    defer object.unlock(t);
    return @ptrCast(@alignCast(c.gst_object_ref(priv(t).pool)));
}

pub export fn gst_task_set_pool(t: [*c]Task, pool: [*c]Pool) void {
    if (!check.that(isTask(t), "gst_task_set_pool", "GST_IS_TASK (task)")) return;
    if (!check.that(isPool(pool), "gst_task_set_pool", "GST_IS_TASK_POOL (pool)")) return;
    const d = priv(t);
    object.lock(t);
    var old: [*c]Pool = null;
    if (d.pool != pool) {
        old = d.pool;
        d.pool = @ptrCast(@alignCast(c.gst_object_ref(pool)));
    }
    object.unlock(t);
    if (old != null) c.gst_object_unref(old);
}

fn setCallback(comptime f: []const u8, t: [*c]Task, func: *c.GstTaskThreadFunc, data: *c.gpointer, notify: *c.GDestroyNotify, new_func: c.GstTaskThreadFunc, new_data: c.gpointer, new_notify: c.GDestroyNotify) void {
    if (!check.that(t != null, f, "task != NULL")) return;
    if (!check.that(isTask(t), f, "GST_IS_TASK (task)")) return;
    object.lock(t);
    if (notify.*) |old| {
        const od = data.*;
        data.* = null;
        notify.* = null;
        object.unlock(t);
        old(od);
        object.lock(t);
    }
    func.* = new_func;
    data.* = new_data;
    notify.* = new_notify;
    object.unlock(t);
}

pub export fn gst_task_set_enter_callback(t: [*c]Task, func: c.GstTaskThreadFunc, data: c.gpointer, notify: c.GDestroyNotify) void {
    const d = priv(t);
    setCallback("gst_task_set_enter_callback", t, &d.enter, &d.enter_data, &d.enter_notify, func, data, notify);
}

pub export fn gst_task_set_leave_callback(t: [*c]Task, func: c.GstTaskThreadFunc, data: c.gpointer, notify: c.GDestroyNotify) void {
    const d = priv(t);
    setCallback("gst_task_set_leave_callback", t, &d.leave, &d.leave_data, &d.leave_notify, func, data, notify);
}

pub export fn gst_task_get_state(t: [*c]Task) c.GstTaskState {
    if (!check.that(isTask(t), "gst_task_get_state", "GST_IS_TASK (task)")) return c.GST_TASK_STOPPED;
    return state(t);
}

fn start(t: [*c]Task) bool {
    const d = priv(t);
    _ = c.gst_object_ref(t);
    t[0].running = 1;
    d.pool_id = @ptrCast(@alignCast(c.gst_object_ref(d.pool)));
    var err: [*c]c.GError = null;
    d.id = gst_task_pool_push(d.pool_id, run, t, &err);
    if (err == null) return true;
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "failed to create thread: %s", err[0].message);
    c.g_error_free(err);
    return false;
}

fn change(t: [*c]Task, s: c.GstTaskState) bool {
    if (s != c.GST_TASK_STOPPED and t[0].lock == null) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "task without a lock can't be set to state %s", stateName(s));
        return false;
    }
    const old = state(t);
    if (old == s) return true;
    setState(t, s);
    return switch (old) {
        c.GST_TASK_STOPPED => if (t[0].running == 0) start(t) else true,
        c.GST_TASK_PAUSED => blk: {
            signal(t);
            break :blk true;
        },
        else => true,
    };
}

pub export fn gst_task_set_state(t: [*c]Task, s: c.GstTaskState) c.gboolean {
    if (!check.that(isTask(t), "gst_task_set_state", "GST_IS_TASK (task)")) return 0;
    object.lock(t);
    defer object.unlock(t);
    return @intFromBool(change(t, s));
}

pub export fn gst_task_start(t: [*c]Task) c.gboolean {
    return gst_task_set_state(t, c.GST_TASK_STARTED);
}

pub export fn gst_task_stop(t: [*c]Task) c.gboolean {
    return gst_task_set_state(t, c.GST_TASK_STOPPED);
}

pub export fn gst_task_pause(t: [*c]Task) c.gboolean {
    return gst_task_set_state(t, c.GST_TASK_PAUSED);
}

pub export fn gst_task_resume(t: [*c]Task) c.gboolean {
    if (!check.that(isTask(t), "gst_task_resume", "GST_IS_TASK (task)")) return 0;
    object.lock(t);
    defer object.unlock(t);
    if (state(t) == c.GST_TASK_STOPPED) return 0;
    return @intFromBool(change(t, c.GST_TASK_STARTED));
}

pub export fn gst_task_join(t: [*c]Task) c.gboolean {
    if (!check.that(isTask(t), "gst_task_join", "GST_IS_TASK (task)")) return 0;
    const d = priv(t);
    object.lock(t);
    if (c.g_thread_self() == t[0].thread) {
        object.unlock(t);
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "\nTrying to join task %p from its thread would deadlock.\nYou cannot change the state of an element from its streaming\nthread. Use g_idle_add() or post a GstMessage on the bus to\nschedule the state change from the main thread.\n", t);
        return 0;
    }
    setState(t, c.GST_TASK_STOPPED);
    signal(t);
    while (t[0].running != 0) wait(t);
    t[0].thread = null;
    const pool = d.pool_id;
    const id = d.id;
    d.pool_id = null;
    d.id = null;
    object.unlock(t);
    if (pool != null) {
        if (id != null) gst_task_pool_join(pool, id);
        c.gst_object_unref(pool);
    }
    return 1;
}

const Job = struct { func: c.GstTaskPoolFunction, data: c.gpointer };

fn poolClass(p: [*c]Pool) *c.GstTaskPoolClass {
    return gtype.classPeek(c.GstTaskPoolClass, p);
}

pub export fn gst_task_pool_get_type() c.GType {
    return pool_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type, "GstTaskPool", c.GstTaskPoolClass, Pool, poolClassInit, null, 0);
            pool_cat = info._gst_debug_category_new("taskpool", 0, "Thread pool");
            return t;
        }
    }.f);
}

fn poolClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    pool_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const k: *c.GstTaskPoolClass = @ptrCast(@alignCast(klass));
    k.prepare = defaultPrepare;
    k.cleanup = defaultCleanup;
    k.push = defaultPush;
    k.join = noop;
    k.dispose_handle = noop;
}

fn noop(_: [*c]Pool, _: c.gpointer) callconv(.c) void {}

fn defaultRun(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(data));
    const job = j.*;
    std.heap.c_allocator.destroy(j);
    job.func.?(job.data);
}

fn defaultPrepare(p: [*c]Pool, err: [*c][*c]c.GError) callconv(.c) void {
    object.lock(p);
    p[0].pool = c.g_thread_pool_new(defaultRun, p, -1, 0, err);
    object.unlock(p);
}

fn defaultCleanup(p: [*c]Pool) callconv(.c) void {
    object.lock(p);
    const tp = p[0].pool;
    p[0].pool = null;
    object.unlock(p);
    if (tp != null) c.g_thread_pool_free(tp, 0, 1);
}

fn defaultPush(p: [*c]Pool, func: c.GstTaskPoolFunction, data: c.gpointer, err: [*c][*c]c.GError) callconv(.c) c.gpointer {
    const j = std.heap.c_allocator.create(Job) catch return null;
    j.* = .{ .func = func, .data = data };
    object.lock(p);
    defer object.unlock(p);
    if (p[0].pool != null) {
        _ = c.g_thread_pool_push(p[0].pool, j, err);
    } else {
        std.heap.c_allocator.destroy(j);
        c.g_set_error_literal(err, c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, "No thread pool");
    }
    return null;
}

pub export fn gst_task_pool_new() [*c]Pool {
    const p = c.g_object_new(gst_task_pool_get_type(), @as([*c]const u8, null));
    _ = object.gst_object_ref_sink(p);
    return @ptrCast(@alignCast(p));
}

pub export fn gst_task_pool_prepare(p: [*c]Pool, err: [*c][*c]c.GError) void {
    if (!check.that(isPool(p), "gst_task_pool_prepare", "GST_IS_TASK_POOL (pool)")) return;
    if (poolClass(p).prepare) |f| f(p, err);
}

pub export fn gst_task_pool_cleanup(p: [*c]Pool) void {
    if (!check.that(isPool(p), "gst_task_pool_cleanup", "GST_IS_TASK_POOL (pool)")) return;
    if (poolClass(p).cleanup) |f| f(p);
}

pub export fn gst_task_pool_push(p: [*c]Pool, func: c.GstTaskPoolFunction, data: c.gpointer, err: [*c][*c]c.GError) c.gpointer {
    if (!check.that(isPool(p), "gst_task_pool_push", "GST_IS_TASK_POOL (pool)")) return null;
    const push = poolClass(p).push orelse {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "pushing tasks on pool %p is not supported", p);
        return null;
    };
    return push(p, func, data, err);
}

pub export fn gst_task_pool_join(p: [*c]Pool, id: c.gpointer) void {
    if (!check.that(isPool(p), "gst_task_pool_join", "GST_IS_TASK_POOL (pool)")) return;
    if (poolClass(p).join) |f| f(p, id);
}

pub export fn gst_task_pool_dispose_handle(p: [*c]Pool, id: c.gpointer) void {
    if (!check.that(isPool(p), "gst_task_pool_dispose_handle", "GST_IS_TASK_POOL (pool)")) return;
    if (poolClass(p).dispose_handle) |f| f(p, id);
}

pub export fn gst_context_set_task_pool(ctx: ?*c.GstContext, p: [*c]Pool) void {
    const f = "gst_context_set_task_pool";
    if (!check.that(ctx != null, f, "context != NULL")) return;
    if (!check.that(c.gst_context_is_writable(ctx) != 0, f, "gst_context_is_writable (context)")) return;
    if (!check.that(p == null or isPool(p), f, "pool == NULL || GST_IS_TASK_POOL (pool)")) return;
    const s = c.gst_context_writable_structure(ctx);
    if (p != null) fields.set(s, "pool", gst_task_pool_get_type(), p) else c.gst_structure_remove_field(s, "pool");
}

pub export fn gst_context_get_task_pool(ctx: ?*c.GstContext, out: [*c][*c]Pool) c.gboolean {
    const f = "gst_context_get_task_pool";
    if (!check.that(out != null, f, "pool != NULL")) return 0;
    if (!check.that(ctx != null, f, "context != NULL")) return 0;
    if (!check.that(c.gst_context_has_context_type(ctx, c.GST_TASK_POOL_CONTEXT_TYPE) != 0, f, "gst_context_has_context_type (context, GST_TASK_POOL_CONTEXT_TYPE)")) return 0;
    const v = c.gst_structure_get_value(c.gst_context_get_structure(ctx), "pool");
    if (v == null) {
        out.* = null;
        return 0;
    }
    if (!check.that(c.g_type_is_a(v[0].g_type, gst_task_pool_get_type()) != 0, f, "g_type_is_a (v->g_type, GST_TYPE_TASK_POOL)")) return 0;
    out.* = @ptrCast(@alignCast(c.g_value_dup_object(v)));
    return 1;
}

const SharedJob = struct {
    done: bool,
    func: c.GstTaskPoolFunction,
    data: c.gpointer,
    lock: c.GMutex,
    cond: c.GCond,
    refs: c.gint,
};

fn jobRef(j: *SharedJob) *SharedJob {
    _ = @atomicRmw(c.gint, &j.refs, .Add, 1, .seq_cst);
    return j;
}

fn jobUnref(j: *SharedJob) void {
    if (@atomicRmw(c.gint, &j.refs, .Sub, 1, .seq_cst) != 1) return;
    c.g_mutex_clear(&j.lock);
    c.g_cond_clear(&j.cond);
    std.heap.c_allocator.destroy(j);
}

fn sharedPriv(p: anytype) *SharedPrivate {
    return at(SharedPrivate, p, shared_offset);
}

pub export fn gst_shared_task_pool_get_type() c.GType {
    return shared_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(gst_task_pool_get_type, "GstSharedTaskPool", c.GstSharedTaskPoolClass, Shared, sharedClassInit, sharedInit, 0);
            shared_offset = c.g_type_add_instance_private(t, @sizeOf(SharedPrivate));
            return t;
        }
    }.f);
}

fn sharedClassInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &shared_offset);
    const k: *c.GstTaskPoolClass = @ptrCast(@alignCast(klass));
    k.prepare = sharedPrepare;
    k.push = sharedPush;
    k.join = sharedJoin;
    k.dispose_handle = sharedDispose;
}

fn sharedInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Shared = @ptrCast(@alignCast(instance));
    p[0].priv = @ptrCast(sharedPriv(p));
    sharedPriv(p).max_threads = 1;
}

fn sharedRun(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    const j: *SharedJob = @ptrCast(@alignCast(data));
    j.func.?(j.data);
    c.g_mutex_lock(&j.lock);
    j.done = true;
    c.g_cond_signal(&j.cond);
    c.g_mutex_unlock(&j.lock);
    jobUnref(j);
}

fn sharedPrepare(p: [*c]Pool, err: [*c][*c]c.GError) callconv(.c) void {
    object.lock(p);
    p[0].pool = c.g_thread_pool_new(sharedRun, p, @intCast(sharedPriv(p).max_threads), 0, err);
    object.unlock(p);
}

fn sharedPush(p: [*c]Pool, func: c.GstTaskPoolFunction, data: c.gpointer, err: [*c][*c]c.GError) callconv(.c) c.gpointer {
    object.lock(p);
    defer object.unlock(p);
    if (p[0].pool == null) return null;
    const j = std.heap.c_allocator.create(SharedJob) catch return null;
    j.* = .{ .done = false, .func = func, .data = data, .lock = undefined, .cond = undefined, .refs = 1 };
    c.g_mutex_init(&j.lock);
    c.g_cond_init(&j.cond);
    _ = c.g_thread_pool_push(p[0].pool, jobRef(j), err);
    return j;
}

fn sharedJoin(_: [*c]Pool, id: c.gpointer) callconv(.c) void {
    const j: *SharedJob = @ptrCast(@alignCast(id orelse return));
    c.g_mutex_lock(&j.lock);
    while (!j.done) c.g_cond_wait(&j.cond, &j.lock);
    c.g_mutex_unlock(&j.lock);
    jobUnref(j);
}

fn sharedDispose(_: [*c]Pool, id: c.gpointer) callconv(.c) void {
    jobUnref(@ptrCast(@alignCast(id orelse return)));
}

pub export fn gst_shared_task_pool_set_max_threads(p: [*c]Shared, n: c.guint) void {
    if (!check.that(gtype.instanceOf(p, gst_shared_task_pool_get_type()), "gst_shared_task_pool_set_max_threads", "GST_IS_SHARED_TASK_POOL (pool)")) return;
    object.lock(p);
    defer object.unlock(p);
    if (p[0].parent.pool != null) _ = c.g_thread_pool_set_max_threads(p[0].parent.pool, @intCast(n), null);
    sharedPriv(p).max_threads = n;
}

pub export fn gst_shared_task_pool_get_max_threads(p: [*c]Shared) c.guint {
    if (!check.that(gtype.instanceOf(p, gst_shared_task_pool_get_type()), "gst_shared_task_pool_get_max_threads", "GST_IS_SHARED_TASK_POOL (pool)")) return 0;
    object.lock(p);
    defer object.unlock(p);
    return sharedPriv(p).max_threads;
}

pub export fn gst_shared_task_pool_new() [*c]Pool {
    const p = c.g_object_new(gst_shared_task_pool_get_type(), @as([*c]const u8, null));
    _ = object.gst_object_ref_sink(p);
    return @ptrCast(@alignCast(p));
}
