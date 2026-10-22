const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const spec = @import("spec.zig");

const N: ?*anyopaque = null;
const SEC: u64 = 1_000_000_000;
const WINDOW_SUBDIV = 100;

const Value = extern struct {
    ts: u64,
    val: u64,
};

const Values = extern struct {
    window: u64,
    values: c.GQueue,
};

const Self = extern struct {
    parent: c.GstTracer,
    tvs_proc: ?*Values,
    main_thread_id: ?*anyopaque,
    tproc_base: u64,
};

const Class = extern struct {
    parent: c.GstTracerClass,
};

const ThreadStats = extern struct {
    tthread: u64,
    tvs_thread: ?*Values,
};

var once: cm.Once = .{};
var parent_class: ?*c.GObjectClass = null;
var num_cpus: c_long = 1;
var tr_proc: ?*c.GstTracerRecord = null;
var tr_thread: ?*c.GstTracerRecord = null;
var proc_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var key: c.GPrivate = .{ .p = null, .notify = freeStats, .future = .{ null, null } };

fn makeValues(window: u64) *Values {
    const v: *Values = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Values))));
    v.window = window;
    c.g_queue_init(&v.values);
    return v;
}

fn freeValues(v: *Values) void {
    c.g_queue_foreach(&v.values, @ptrCast(&c.g_free), null);
    c.g_queue_clear(&v.values);
    c.g_free(v);
}

fn diff(a: u64, b: u64) i64 {
    return @as(i64, @bitCast(b)) -% @as(i64, @bitCast(a));
}

fn update(self: *Values, nts: u64, nval: u64, dts: *u64, dval: *u64) bool {
    const q = &self.values;
    var node = q.tail;
    var lv: ?*Value = null;
    var dt: i64 = 0;
    while (node != null) {
        lv = @ptrCast(@alignCast(node[0].data));
        dt = diff(lv.?.ts, nts);
        if (dt < @as(i64, @bitCast(self.window))) break;
        node = node[0].prev;
    }
    var ret = false;
    if (node != null) {
        dts.* = @bitCast(dt);
        dval.* = @bitCast(diff(lv.?.val, nval));
        while (q.tail != node) c.g_free(c.g_queue_pop_tail(q));
        ret = true;
    } else {
        dts.* = nts;
        dval.* = nval;
    }
    const head: ?*Value = if (q.head != null) @ptrCast(@alignCast(q.head[0].data)) else null;
    if (head == null or diff(head.?.ts, nts) > @as(i64, @bitCast(self.window / WINDOW_SUBDIV))) {
        const n: *Value = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Value))));
        n.ts = nts;
        n.val = nval;
        c.g_queue_push_head(q, n);
    }
    return ret;
}

fn freeStats(p: c.gpointer) callconv(.c) void {
    const s: *ThreadStats = @ptrCast(@alignCast(p));
    freeValues(s.tvs_thread.?);
    c.g_free(s);
}

fn cpuTime(clock: std.c.clockid_t) u64 {
    var now: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock, &now) != 0) return 0;
    return @as(u64, @intCast(now.sec)) * SEC + @as(u64, @intCast(now.nsec));
}

fn load(v: u64, ts: u64) c.guint {
    return @truncate(c.gst_util_uint64_scale(v, 1000, ts));
}

fn doStats(obj: ?*anyopaque, ts: u64) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(obj));
    const tid = c.g_thread_self();
    var tproc = cpuTime(std.c.CLOCK.PROCESS_CPUTIME_ID);
    const tthread = cpuTime(std.c.CLOCK.THREAD_CPUTIME_ID);
    var stats: ?*ThreadStats = @ptrCast(@alignCast(c.g_private_get(&key)));
    if (stats == null) {
        stats = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(ThreadStats))));
        stats.?.tvs_thread = makeValues(SEC);
        c.g_private_set(&key, stats);
    }
    const st = stats.?;
    st.tthread = tthread;
    if (@as(?*anyopaque, @ptrCast(tid)) == self.main_thread_id) {
        self.main_thread_id = null;
        if (tproc > ts) {
            self.tproc_base = tproc - ts;
            st.tthread -%= self.tproc_base;
        }
    }
    tproc -%= self.tproc_base;
    var dts: u64 = 0;
    var dproc: u64 = 0;
    var avg = load(st.tthread, ts);
    _ = update(st.tvs_thread.?, ts, st.tthread, &dts, &dproc);
    var cur = load(dproc, dts);
    c.gst_tracer_record_log(tr_thread, @as(u64, @intFromPtr(tid)), ts, @as(c.guint, @min(avg, 1000)), @as(c.guint, @min(cur, 1000)), st.tthread);
    const cpus: u64 = @intCast(num_cpus);
    avg = load(tproc / cpus, ts);
    c.g_mutex_lock(&proc_lock);
    _ = update(self.tvs_proc.?, ts, tproc, &dts, &dproc);
    c.g_mutex_unlock(&proc_lock);
    cur = load(dproc / cpus, dts);
    c.gst_tracer_record_log(tr_proc, @as(u64, @intCast(std.c.getpid())), ts, @as(c.guint, @min(avg, 1000)), @as(c.guint, @min(cur, 1000)), tproc);
}

fn finalize(ob: [*c]c.GObject) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(ob));
    freeValues(self.tvs_proc.?);
    parent_class.?.finalize.?(ob);
}

fn load3(d: [*:0]const u8, flags: bool) [*c]c.GstStructure {
    if (flags) return spec.make("value", &.{ .{ .gtype = c.G_TYPE_UINT }, .{ .desc = d }, .{ .flags = c.GST_TRACER_VALUE_FLAGS_AGGREGATED }, .{ .min_u = 0 }, .{ .max_u = 1000 } });
    return spec.make("value", &.{ .{ .gtype = c.G_TYPE_UINT }, .{ .desc = d }, .{ .min_u = 0 }, .{ .max_u = 1000 } });
}

fn timeSpec(d: [*:0]const u8) [*c]c.GstStructure {
    return spec.make("value", &.{ .{ .gtype = c.G_TYPE_UINT64 }, .{ .desc = d }, .{ .flags = c.GST_TRACER_VALUE_FLAGS_AGGREGATED }, .{ .min_u64 = 0 }, .{ .max_u64 = ~@as(u64, 0) } });
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    c.gst_tracer_class_set_use_structure_params(@ptrCast(@alignCast(k)), 1);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = finalize;
    num_cpus = std.c.sysconf(84);
    if (num_cpus == -1) {
        num_cpus = std.c.sysconf(83);
        if (num_cpus == -1) num_cpus = 1;
    }
    const S = c.gst_structure_get_type();
    tr_thread = c.gst_tracer_record_new("thread-rusage.class", "thread-id", S, spec.threadId(), "ts", S, spec.ts(), "average-cpuload", S, load3("average cpu usage per thread in ‰", true), "current-cpuload", S, load3("current cpu usage per thread in ‰", false), "time", S, timeSpec("time spent in thread in ns"), N);
    tr_proc = c.gst_tracer_record_new("proc-rusage.class", "process-id", S, spec.scope(c.G_TYPE_UINT64, c.GST_TRACER_VALUE_SCOPE_PROCESS), "ts", S, spec.ts(), "average-cpuload", S, load3("average cpu usage per process in ‰", true), "current-cpuload", S, load3("current cpu usage per process in ‰", false), "time", S, timeSpec("time spent in process in ns"), N);
    spec.maybeLeaked(tr_thread);
    spec.maybeLeaked(tr_proc);
}

const hooks = [_][*:0]const u8{ "pad-push-pre", "pad-push-post", "pad-push-list-pre", "pad-push-list-post", "pad-pull-range-pre", "pad-pull-range-post", "pad-push-event-pre", "pad-push-event-post", "pad-query-pre", "pad-query-post", "element-post-message-pre", "element-post-message-post", "element-query-pre", "element-query-post", "element-new", "element-add-pad", "element-remove-pad", "element-change-state-pre", "element-change-state-post", "bin-add-pre", "bin-add-post", "bin-remove-pre", "bin-remove-post", "pad-link-pre", "pad-link-post", "pad-unlink-pre", "pad-unlink-post" };

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(inst));
    for (hooks) |h| spec.hook(inst, h, &doStats);
    self.tvs_proc = makeValues(SEC);
    self.main_thread_id = c.g_thread_self();
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            _ = c._gst_debug_category_new("rusage", 0, "rusage tracer");
            return cm.register(c.gst_tracer_get_type(), "GstRUsageTracer", Class, Self, classInit, init);
        }
    }.f);
}
