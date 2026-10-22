const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const spec = @import("spec.zig");

const FILE = "../plugins/tracers/gstleaks.c";
const N: ?*anyopaque = null;

const TRACE_DISABLED: c.gint = -1;
const TRACE_NONE: c.gint = c.GST_STACK_TRACE_SHOW_NONE;
const TRACE_FULL: c.gint = c.GST_STACK_TRACE_SHOW_FULL;

const PROP_FILTERS = 1;
const PROP_CHECK_REFS = 2;
const PROP_STACK_TRACES_FLAGS = 3;
const PROP_LOG_LEAKS_ON_DEINIT = 4;

const GOBJECT = 0;
const MINI_OBJECT = 1;

const Self = extern struct {
    parent: c.GstTracer,
    objects: ?*c.GHashTable,
    filter: [*c]c.GArray,
    added: ?*c.GHashTable,
    removed: ?*c.GHashTable,
    unhandled_filter: ?*c.GHashTable,
    unhandled_filter_count: c.gint,
    done: c.gboolean,
    check_refs: c.gboolean,
    log_leaks: c.gboolean,
    trace_flags: c.gint,
};

const Class = extern struct {
    parent: c.GstTracerClass,
    get_live_objects: ?*const fn (*Self) callconv(.c) [*c]c.GstStructure,
    log_live_objects: ?*const fn (*Self) callconv(.c) void,
    activity_start_tracking: ?*const fn (*Self) callconv(.c) void,
    activity_get_checkpoint: ?*const fn (*Self) callconv(.c) [*c]c.GstStructure,
    activity_log_checkpoint: ?*const fn (*Self) callconv(.c) void,
    activity_stop_tracking: ?*const fn (*Self) callconv(.c) void,
};

const RefInfo = extern struct {
    reffed: c.gboolean,
    trace: [*c]u8,
    new_refcount: c.gint,
    ts: u64,
};

const RefInfos = extern struct {
    creation_trace: [*c]u8,
    kind: c.gint,
    refing_infos: [*c]c.GList,
};

const ObjectLog = extern struct {
    object: c.gpointer,
    type_qname: c.GQuark,
};

const Leak = extern struct {
    obj: c.gpointer,
    type: c.GType,
    ref_count: c.guint,
    desc: [*c]u8,
    infos: *RefInfos,
};

var once: cm.Once = .{};
var flags_type: c.GType = 0;
var parent_class: ?*c.GObjectClass = null;
var tr_alive: ?*c.GstTracerRecord = null;
var tr_refings: ?*c.GstTracerRecord = null;
var tr_added: ?*c.GstTracerRecord = null;
var tr_removed: ?*c.GstTracerRecord = null;
var instances: c.GQueue = std.mem.zeroes(c.GQueue);
var instances_lock: c.GMutex = std.mem.zeroes(c.GMutex);

var signal_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var signal_loop: ?*c.GMainLoop = null;
var signal_thread: ?*c.GThread = null;
var signal_users: c.gint = 0;

const flag_values = [_]c.GFlagsValue{
    .{ .value = @bitCast(TRACE_DISABLED), .value_name = "Disabled", .value_nick = "disabled" },
    .{ .value = @bitCast(TRACE_NONE), .value_name = "None", .value_nick = "none" },
    .{ .value = @bitCast(TRACE_FULL), .value_name = "Full", .value_nick = "full" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn flagsType() c.GType {
    if (flags_type == 0) flags_type = c.g_flags_register_static("GstLeaksStackTraceFlags", &flag_values);
    return flags_type;
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn freeRefInfo(p: c.gpointer) callconv(.c) void {
    const r: *RefInfo = @ptrCast(@alignCast(p));
    c.g_free(r.trace);
    c.g_free(r);
}

fn freeRefInfos(p: c.gpointer) callconv(.c) void {
    const r: *RefInfos = @ptrCast(@alignCast(p));
    c.g_list_free_full(r.refing_infos, freeRefInfo);
    c.g_free(r.creation_trace);
    c.g_free(r);
}

fn setFilters(s: *Self, filters: [*c]const u8) void {
    const tmp = c.g_strsplit(filters, ",", -1);
    s.filter = c.g_array_sized_new(0, 0, @sizeOf(c.GType), c.g_strv_length(tmp));
    var i: usize = 0;
    while (tmp[i] != null) : (i += 1) {
        var t = c.g_type_from_name(tmp[i]);
        if (t == 0) {
            if (s.unhandled_filter == null) s.unhandled_filter = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, null);
            _ = c.g_hash_table_add(s.unhandled_filter, c.g_strdup(tmp[i]));
            _ = @atomicRmw(c.gint, &s.unhandled_filter_count, .Add, 1, .seq_cst);
            continue;
        }
        _ = c.g_array_append_vals(s.filter, &t, 1);
    }
    c.g_strfreev(tmp);
}

fn expandUnhandled(k: c.gpointer, _: c.gpointer, data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    var t = c.g_type_from_name(@ptrCast(k));
    if (t == 0) return 0;
    _ = @atomicRmw(c.gint, &s.unhandled_filter_count, .Sub, 1, .seq_cst);
    _ = c.g_array_append_vals(s.filter, &t, 1);
    return 1;
}

fn shouldHandle(s: *Self, t: c.GType) bool {
    if (s.filter == null) return true;
    if (t == 0) return false;
    if (@atomicLoad(c.gint, &s.unhandled_filter_count, .seq_cst) != 0) {
        cm.lock(s);
        _ = c.g_hash_table_foreach_remove(s.unhandled_filter, expandUnhandled, s);
        cm.unlock(s);
    }
    const types: [*]c.GType = @ptrCast(@alignCast(s.filter[0].data));
    for (types[0..s.filter[0].len]) |f| if (c.g_type_is_a(t, f) != 0) return true;
    return false;
}

fn miniType(o: c.gpointer) c.GType {
    return @as(*c.GstMiniObject, @ptrCast(@alignCast(o))).type;
}

fn objectLog(o: c.gpointer, kind: c.gint) *ObjectLog {
    const l: *ObjectLog = @ptrCast(@alignCast(c.g_malloc(@sizeOf(ObjectLog))));
    l.object = o;
    l.type_qname = c.g_type_qname(if (kind == GOBJECT) cm.typeOf(o) else miniType(o));
    return l;
}

fn destroyed(s: *Self, o: c.gpointer, kind: c.gint) void {
    cm.lock(s);
    defer cm.unlock(s);
    if (s.done != 0) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "object %p destroyed while the leaks tracer was finalizing. Some threads are still running?", o);
        return;
    }
    _ = c.g_hash_table_remove(s.objects, o);
    if (s.removed) |r| _ = c.g_hash_table_add(r, objectLog(o, kind));
}

fn weakCb(data: c.gpointer, o: [*c]c.GObject) callconv(.c) void {
    destroyed(me(data), o, GOBJECT);
}

fn miniWeakCb(data: c.gpointer, o: [*c]c.GstMiniObject) callconv(.c) void {
    destroyed(me(data), o, MINI_OBJECT);
}

fn created(s: *Self, o: c.gpointer, t: c.GType, kind: c.gint) void {
    if (!shouldHandle(s, t)) return;
    const infos: *RefInfos = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(RefInfos))));
    infos.kind = kind;
    if (kind == GOBJECT) {
        c.g_object_weak_ref(@ptrCast(@alignCast(o)), weakCb, s);
    } else c.gst_mini_object_weak_ref(@ptrCast(@alignCast(o)), miniWeakCb, s);
    cm.lock(s);
    if (s.trace_flags != TRACE_DISABLED) infos.creation_trace = c.gst_debug_get_stack_trace(@bitCast(s.trace_flags));
    _ = c.g_hash_table_insert(s.objects, o, infos);
    if (s.added) |a| _ = c.g_hash_table_add(a, objectLog(o, kind));
    cm.unlock(s);
}

fn miniCreated(t: ?*anyopaque, _: u64, o: [*c]c.GstMiniObject) callconv(.c) void {
    created(me(t), o, miniType(o), MINI_OBJECT);
}

fn objectCreated(t: ?*anyopaque, _: u64, o: ?*c.GstObject) callconv(.c) void {
    const ty = cm.typeOf(o);
    if (c.g_type_is_a(ty, c.gst_tracer_get_type()) != 0) return;
    created(me(t), o, ty, GOBJECT);
}

fn reffed(s: *Self, o: c.gpointer, t: c.GType, count: c.gint, up: bool, ts: u64) void {
    if (s.check_refs == 0) return;
    if (!shouldHandle(s, t)) return;
    cm.lock(s);
    defer cm.unlock(s);
    const infos: ?*RefInfos = @ptrCast(@alignCast(c.g_hash_table_lookup(s.objects, o)));
    const inf = infos orelse return;
    const r: *RefInfo = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(RefInfo))));
    r.ts = ts;
    r.new_refcount = count;
    r.reffed = @intFromBool(up);
    if (s.trace_flags != TRACE_DISABLED) r.trace = c.gst_debug_get_stack_trace(@bitCast(s.trace_flags));
    inf.refing_infos = c.g_list_prepend(inf.refing_infos, r);
}

fn objectReffed(t: ?*anyopaque, ts: u64, o: ?*c.GstObject, n: c.gint) callconv(.c) void {
    reffed(me(t), o, cm.typeOf(o), n, true, ts);
}

fn objectUnreffed(t: ?*anyopaque, ts: u64, o: ?*c.GstObject, n: c.gint) callconv(.c) void {
    reffed(me(t), o, cm.typeOf(o), n, false, ts);
}

fn miniReffed(t: ?*anyopaque, ts: u64, o: [*c]c.GstMiniObject, n: c.gint) callconv(.c) void {
    reffed(me(t), o, miniType(o), n, true, ts);
}

fn miniUnreffed(t: ?*anyopaque, ts: u64, o: [*c]c.GstMiniObject, n: c.gint) callconv(.c) void {
    reffed(me(t), o, miniType(o), n, false, ts);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.log_leaks = 1;
    s.check_refs = 0;
    s.trace_flags = TRACE_DISABLED;
    s.objects = c.g_hash_table_new_full(null, null, null, freeRefInfos);
    if (c.g_getenv("GST_LEAKS_TRACER_SIG") != null) setupSignals();
    c.g_mutex_lock(&instances_lock);
    c.g_queue_push_tail(&instances, s);
    c.g_mutex_unlock(&instances_lock);
}

fn constructed(ob: [*c]c.GObject) callconv(.c) void {
    const s = me(ob);
    spec.hook(ob, "mini-object-created", &miniCreated);
    spec.hook(ob, "object-created", &objectCreated);
    if (s.check_refs != 0) {
        spec.hook(ob, "object-reffed", &objectReffed);
        spec.hook(ob, "mini-object-reffed", &miniReffed);
        spec.hook(ob, "mini-object-unreffed", &miniUnreffed);
        spec.hook(ob, "object-unreffed", &objectUnreffed);
    }
    parent_class.?.constructed.?(ob);
}

fn newLeak(o: c.gpointer, t: c.GType, rc: c.guint, infos: *RefInfos) *Leak {
    const l: *Leak = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Leak))));
    l.obj = o;
    l.type = t;
    l.ref_count = rc;
    l.desc = c.gst_info_strdup_printf("%" ++ "p\x07A", o);
    l.infos = infos;
    return l;
}

fn freeLeak(p: c.gpointer) callconv(.c) void {
    const l: *Leak = @ptrCast(@alignCast(p));
    c.g_free(l.desc);
    c.g_free(l);
}

fn sortLeaks(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const x: *const Leak = @ptrCast(@alignCast(a));
    const y: *const Leak = @ptrCast(@alignCast(b));
    return c.g_strcmp0(c.g_type_name(x.type), c.g_type_name(y.type));
}

fn leaksList(s: *Self) [*c]c.GList {
    var l: [*c]c.GList = null;
    var it: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&it, s.objects);
    var o: c.gpointer = null;
    var inf: c.gpointer = null;
    while (c.g_hash_table_iter_next(&it, &o, &inf) != 0) {
        const infos: *RefInfos = @ptrCast(@alignCast(inf));
        var t: c.GType = 0;
        var rc: c.guint = 0;
        if (infos.kind == GOBJECT) {
            if (@as(*c.GstObject, @ptrCast(@alignCast(o))).flags & c.GST_OBJECT_FLAG_MAY_BE_LEAKED != 0) continue;
            t = cm.typeOf(o);
            rc = @as(*c.GObject, @ptrCast(@alignCast(o))).ref_count;
        } else {
            const m: *c.GstMiniObject = @ptrCast(@alignCast(o));
            if (m.flags & c.GST_MINI_OBJECT_FLAG_MAY_BE_LEAKED != 0) continue;
            t = m.type;
            rc = @bitCast(m.refcount);
        }
        l = c.g_list_prepend(l, newLeak(o, t, rc, infos));
    }
    l = c.g_list_sort(l, sortLeaks);
    return c.g_list_reverse(l);
}

fn processLeak(leak: *Leak, ret: ?*c.GValue) void {
    var s: [*c]c.GstStructure = null;
    if (ret == null) {
        c.gst_tracer_record_log(tr_alive, c.g_type_name(leak.type), leak.obj, leak.desc, leak.ref_count, if (leak.infos.creation_trace != null) leak.infos.creation_trace else @as([*c]u8, @constCast("")));
    } else {
        var ov = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&ov, leak.type);
        if (leak.infos.kind == GOBJECT) {
            c.g_value_take_object(&ov, leak.obj);
        } else c.g_value_take_boxed(&ov, leak.obj);
        s = c.gst_structure_new_empty("object-alive");
        c.gst_structure_take_value(s, "object", &ov);
        c.gst_structure_set(s, "ref-count", c.G_TYPE_UINT, leak.ref_count, "trace", c.G_TYPE_STRING, leak.infos.creation_trace, N);
        var sv = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&sv, c.gst_structure_get_type());
        c.g_value_take_boxed(&sv, s);
        c.gst_value_list_append_and_take_value(ret, &sv);
    }
    var refings = std.mem.zeroes(c.GValue);
    if (leak.infos.refing_infos != null) _ = c.g_value_init(&refings, c.gst_value_list_get_type());
    var r = c.g_list_last(leak.infos.refing_infos);
    while (r != null) : (r = r[0].prev) {
        const ri: *RefInfo = @ptrCast(@alignCast(r[0].data));
        const what: [*:0]const u8 = if (ri.reffed != 0) "reffed" else "unreffed";
        if (ret == null) {
            c.gst_tracer_record_log(tr_refings, ri.ts, c.g_type_name(leak.type), leak.obj, what, ri.new_refcount, if (ri.trace != null) ri.trace else @as([*c]u8, @constCast("")));
        } else {
            const rs = c.gst_structure_new_empty("object-refings");
            c.gst_structure_set(rs, "ts", c.G_TYPE_UINT64, ri.ts, "desc", c.G_TYPE_STRING, what, "ref-count", c.G_TYPE_UINT, ri.new_refcount, "trace", c.G_TYPE_STRING, ri.trace, N);
            var rv = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&rv, c.gst_structure_get_type());
            c.g_value_take_boxed(&rv, rs);
            c.gst_value_list_append_and_take_value(&refings, &rv);
        }
    }
    if (ret != null and leak.infos.refing_infos != null) c.gst_structure_take_value(s, "ref-infos", &refings);
}

fn processLeaks(s: *Self, ret: ?*c.GValue) bool {
    const leaks = leaksList(s);
    if (leaks == null) return false;
    var l = leaks;
    while (l != null) : (l = l[0].next) processLeak(@ptrCast(@alignCast(l[0].data)), ret);
    c.g_list_free_full(leaks, freeLeak);
    return true;
}

fn finalize(ob: [*c]c.GObject) callconv(.c) void {
    const s = me(ob);
    s.done = 1;
    var leaks = false;
    if (s.log_leaks != 0) leaks = processLeaks(s, null);
    var it: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&it, s.objects);
    var o: c.gpointer = null;
    var inf: c.gpointer = null;
    while (c.g_hash_table_iter_next(&it, &o, &inf) != 0) {
        const infos: *RefInfos = @ptrCast(@alignCast(inf));
        if (infos.kind == GOBJECT) {
            c.g_object_weak_unref(@ptrCast(@alignCast(o)), weakCb, s);
        } else c.gst_mini_object_weak_unref(@ptrCast(@alignCast(o)), miniWeakCb, s);
    }
    c.g_hash_table_unref(s.objects);
    s.objects = null;
    if (s.filter != null) _ = c.g_array_free(s.filter, 1);
    if (s.added) |x| c.g_hash_table_unref(x);
    s.added = null;
    if (s.removed) |x| c.g_hash_table_unref(x);
    s.removed = null;
    if (s.unhandled_filter) |x| c.g_hash_table_unref(x);
    s.unhandled_filter = null;
    c.g_mutex_lock(&instances_lock);
    _ = c.g_queue_remove(&instances, s);
    c.g_mutex_unlock(&instances_lock);
    cleanupSignals();
    if (leaks) c.g_log(null, c.G_LOG_LEVEL_WARNING, "Leaks detected and logged under GST_DEBUG=GST_TRACER:7");
    parent_class.?.finalize.?(ob);
}

fn logLiveForeach(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    logLive(me(data));
}

fn usr1(_: c.gpointer) callconv(.c) c.gboolean {
    c.g_mutex_lock(&instances_lock);
    c.g_queue_foreach(&instances, logLiveForeach, null);
    c.g_mutex_unlock(&instances_lock);
    return 1;
}

fn usr2Foreach(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    const t = me(data);
    if (t.added == null) {
        startTracking(t);
    } else logCheckpoint(t);
}

fn usr2(_: c.gpointer) callconv(.c) c.gboolean {
    c.g_mutex_lock(&instances_lock);
    c.g_queue_foreach(&instances, usr2Foreach, null);
    c.g_mutex_unlock(&instances_lock);
    return 1;
}

const ThreadData = extern struct {
    lock: c.GMutex,
    cond: c.GCond,
    ready: c.gboolean,
};

fn unlockMutex(p: c.gpointer) callconv(.c) c.gboolean {
    c.g_mutex_unlock(@ptrCast(@alignCast(p)));
    return 0;
}

fn signalThread(p: c.gpointer) callconv(.c) c.gpointer {
    const d: *ThreadData = @ptrCast(@alignCast(p));
    const ctx = c.g_main_context_new();
    signal_loop = c.g_main_loop_new(ctx, 0);
    const us = c.g_idle_source_new();
    c.g_source_set_callback(us, unlockMutex, &d.lock, null);
    _ = c.g_source_attach(us, ctx);
    const s1 = c.g_unix_signal_source_new(@intCast(@intFromEnum(std.posix.SIG.USR1)));
    c.g_source_set_callback(s1, usr1, null, null);
    _ = c.g_source_attach(s1, ctx);
    const s2 = c.g_unix_signal_source_new(@intCast(@intFromEnum(std.posix.SIG.USR2)));
    c.g_source_set_callback(s2, usr2, null, null);
    _ = c.g_source_attach(s2, ctx);
    c.g_mutex_lock(&d.lock);
    d.ready = 1;
    c.g_cond_broadcast(&d.cond);
    c.g_main_loop_run(signal_loop);
    c.g_source_destroy(s1);
    c.g_source_destroy(s2);
    c.g_main_loop_unref(signal_loop);
    signal_loop = null;
    c.g_main_context_unref(ctx);
    return null;
}

fn forkPrepare() callconv(.c) void {
    c.g_mutex_lock(&signal_lock);
}

fn forkParent() callconv(.c) void {
    c.g_mutex_unlock(&signal_lock);
}

fn forkChild() callconv(.c) void {
    signal_users = 0;
    signal_thread = null;
    c.g_mutex_unlock(&signal_lock);
}

extern fn pthread_atfork(prepare: ?*const fn () callconv(.c) void, parent: ?*const fn () callconv(.c) void, child: ?*const fn () callconv(.c) void) c_int;

fn setupSignals() void {
    c.g_mutex_lock(&signal_lock);
    defer c.g_mutex_unlock(&signal_lock);
    signal_users += 1;
    if (signal_users != 1) return;
    _ = pthread_atfork(forkPrepare, forkParent, forkChild);
    var d: ThreadData = undefined;
    d.ready = 0;
    c.g_mutex_init(&d.lock);
    c.g_cond_init(&d.cond);
    signal_thread = c.g_thread_new("gstleak-signal", signalThread, &d);
    c.g_mutex_lock(&d.lock);
    while (d.ready == 0) c.g_cond_wait(&d.cond, &d.lock);
    c.g_mutex_unlock(&d.lock);
    c.g_mutex_clear(&d.lock);
    c.g_cond_clear(&d.cond);
}

fn cleanupSignals() void {
    c.g_mutex_lock(&signal_lock);
    defer c.g_mutex_unlock(&signal_lock);
    signal_users -= 1;
    if (signal_users != 0) return;
    c.g_main_loop_quit(signal_loop);
    _ = c.g_thread_join(signal_thread);
    signal_thread = null;
    c.gst_object_unref(tr_added);
    tr_added = null;
    c.gst_object_unref(tr_removed);
    tr_removed = null;
}

fn getLive(s: *Self) callconv(.c) [*c]c.GstStructure {
    var live = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&live, c.gst_value_list_get_type());
    cm.lock(s);
    _ = processLeaks(s, &live);
    cm.unlock(s);
    const info = c.gst_structure_new_empty("live-objects-info");
    c.gst_structure_take_value(info, "live-objects-list", &live);
    return info;
}

fn logLive(s: *Self) callconv(.c) void {
    cm.lock(s);
    _ = processLeaks(s, null);
    cm.unlock(s);
}

fn freeLog(p: c.gpointer) callconv(.c) void {
    c.g_free(p);
}

fn startTracking(s: *Self) callconv(.c) void {
    cm.lock(s);
    defer cm.unlock(s);
    if (s.added != null) return;
    s.added = c.g_hash_table_new_full(null, null, freeLog, null);
    s.removed = c.g_hash_table_new_full(null, null, freeLog, null);
}

fn checkpoint(r: ?*c.GstTracerRecord, kind: [*c]const u8, h: ?*c.GHashTable, ret: ?*c.GValue) void {
    var it: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&it, h);
    var o: c.gpointer = null;
    while (c.g_hash_table_iter_next(&it, &o, null) != 0) {
        const ol: *ObjectLog = @ptrCast(@alignCast(o));
        const tn = c.g_quark_to_string(ol.type_qname);
        if (ret == null) {
            c.gst_tracer_record_log(r, tn, ol.object);
        } else {
            const s = c.gst_structure_new_empty(kind);
            c.gst_structure_set(s, "type-name", c.G_TYPE_STRING, tn, N);
            var av = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&av, c.G_TYPE_STRING);
            c.g_value_take_string(&av, c.g_strdup_printf("%p", ol.object));
            c.gst_structure_take_value(s, "address", &av);
            var sv = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&sv, c.gst_structure_get_type());
            c.g_value_take_boxed(&sv, s);
            c.gst_value_list_append_and_take_value(ret, &sv);
        }
    }
}

fn getCheckpoint(s: *Self) callconv(.c) [*c]c.GstStructure {
    var added = std.mem.zeroes(c.GValue);
    var removed = std.mem.zeroes(c.GValue);
    const st = c.gst_structure_new_empty("activity-checkpoint");
    _ = c.g_value_init(&added, c.gst_value_list_get_type());
    _ = c.g_value_init(&removed, c.gst_value_list_get_type());
    cm.lock(s);
    checkpoint(tr_added, "objects-created", s.added, &added);
    checkpoint(tr_removed, "objects-removed", s.removed, &removed);
    c.g_hash_table_remove_all(s.added);
    c.g_hash_table_remove_all(s.removed);
    cm.unlock(s);
    c.gst_structure_take_value(st, "objects-created-list", &added);
    c.gst_structure_take_value(st, "objects-removed-list", &removed);
    return st;
}

fn logCheckpoint(s: *Self) callconv(.c) void {
    cm.lock(s);
    checkpoint(tr_added, null, s.added, null);
    checkpoint(tr_removed, null, s.removed, null);
    c.g_hash_table_remove_all(s.added);
    c.g_hash_table_remove_all(s.removed);
    cm.unlock(s);
}

fn stopTracking(s: *Self) callconv(.c) void {
    cm.lock(s);
    if (s.added) |x| c.g_hash_table_destroy(x);
    s.added = null;
    if (s.removed) |x| c.g_hash_table_destroy(x);
    s.removed = null;
    cm.unlock(s);
}

fn getProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, sp: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_CHECK_REFS => c.g_value_set_boolean(v, s.check_refs),
        PROP_STACK_TRACES_FLAGS => c.g_value_set_flags(v, @bitCast(s.trace_flags)),
        PROP_LOG_LEAKS_ON_DEINIT => c.g_value_set_boolean(v, s.log_leaks),
        PROP_FILTERS => {
            const str = c.g_string_new("");
            if (s.filter != null) {
                const types: [*]c.GType = @ptrCast(@alignCast(s.filter[0].data));
                for (types[0..s.filter[0].len], 0..) |t, i| {
                    if (i > 0) _ = c.g_string_append_c(str, ',');
                    _ = c.g_string_append(str, c.g_type_name(t));
                }
            }
            c.g_value_take_string(v, c.g_string_free(str, 0));
        },
        else => cm.warnInvalid(FILE, ob, id, sp, 1126),
    }
}

fn setProperty(ob: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, sp: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(ob);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_CHECK_REFS => s.check_refs = c.g_value_get_boolean(v),
        PROP_STACK_TRACES_FLAGS => s.trace_flags = @bitCast(c.g_value_get_flags(v)),
        PROP_LOG_LEAKS_ON_DEINIT => s.log_leaks = c.g_value_get_boolean(v),
        PROP_FILTERS => {
            if (s.filter != null) {
                _ = c.g_array_free(s.filter, 1);
                s.filter = null;
            }
            const f = c.g_value_get_string(v);
            if (f != null) setFilters(s, f);
        },
        else => cm.warnInvalid(FILE, ob, id, sp, 1160),
    }
}

fn bare(t: c.GType) [*c]c.GstStructure {
    return spec.make("value", &.{.{ .gtype = t }});
}

fn action(k: c.gpointer, name: [*:0]const u8, comptime field: []const u8, ret: c.GType) void {
    _ = c.g_signal_new(name, cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @offsetOf(Class, field), null, null, null, ret, 0);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    c.gst_tracer_class_set_use_structure_params(@ptrCast(@alignCast(k)), 1);
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.constructed = constructed;
    gc.finalize = finalize;
    gc.get_property = getProperty;
    gc.set_property = setProperty;
    const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS | c.G_PARAM_CONSTRUCT_ONLY;
    c.g_object_class_install_property(gc, PROP_FILTERS, c.g_param_spec_string("filters", "Type Filters", "Comma-separated list of GObject types to track", null, RW));
    c.g_object_class_install_property(gc, PROP_CHECK_REFS, c.g_param_spec_boolean("check-refs", "Check References", "Whether to track ref/unref operations", 0, RW));
    c.g_object_class_install_property(gc, PROP_STACK_TRACES_FLAGS, c.g_param_spec_flags("stack-traces-flags", "Stack Trace Flags", "Stack trace collection mode", flagsType(), @bitCast(TRACE_DISABLED), RW));
    c.g_object_class_install_property(gc, PROP_LOG_LEAKS_ON_DEINIT, c.g_param_spec_boolean("log-leaks-on-deinit", "Log Leaks", "Whether to log leaks on shutdown", 1, RW));
    const S = c.gst_structure_get_type();
    tr_alive = c.gst_tracer_record_new("object-alive.class", "type-name", S, bare(c.G_TYPE_STRING), "address", S, bare(c.G_TYPE_POINTER), "description", S, bare(c.G_TYPE_STRING), "ref-count", S, bare(c.G_TYPE_UINT), "trace", S, bare(c.G_TYPE_STRING), N);
    spec.maybeLeaked(tr_alive);
    tr_refings = c.gst_tracer_record_new("object-refings.class", "ts", S, bare(c.G_TYPE_UINT64), "type-name", S, bare(c.G_TYPE_STRING), "address", S, bare(c.G_TYPE_POINTER), "description", S, bare(c.G_TYPE_STRING), "ref-count", S, bare(c.G_TYPE_UINT), "trace", S, bare(c.G_TYPE_STRING), N);
    spec.maybeLeaked(tr_refings);
    tr_added = c.gst_tracer_record_new("object-added.class", "type-name", S, bare(c.G_TYPE_STRING), "address", S, bare(c.G_TYPE_POINTER), N);
    spec.maybeLeaked(tr_added);
    tr_removed = c.gst_tracer_record_new("object-removed.class", "type-name", S, bare(c.G_TYPE_STRING), "address", S, bare(c.G_TYPE_POINTER), N);
    spec.maybeLeaked(tr_removed);
    action(k, "get-live-objects", "get_live_objects", S);
    action(k, "log-live-objects", "log_live_objects", c.G_TYPE_NONE);
    action(k, "activity-start-tracking", "activity_start_tracking", c.G_TYPE_NONE);
    action(k, "activity-get-checkpoint", "activity_get_checkpoint", S);
    action(k, "activity-log-checkpoint", "activity_log_checkpoint", c.G_TYPE_NONE);
    action(k, "activity-stop-tracking", "activity_stop_tracking", c.G_TYPE_NONE);
    const lc: *Class = @ptrCast(@alignCast(k));
    lc.get_live_objects = getLive;
    lc.log_live_objects = logLive;
    lc.activity_start_tracking = startTracking;
    lc.activity_get_checkpoint = getCheckpoint;
    lc.activity_log_checkpoint = logCheckpoint;
    lc.activity_stop_tracking = stopTracking;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            _ = c._gst_debug_category_new("leaks", 0, "leaks tracer");
            return cm.register(c.gst_tracer_get_type(), "GstLeaksTracer", Class, Self, classInit, init);
        }
    }.f);
}
