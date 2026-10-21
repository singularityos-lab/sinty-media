const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

var runs = std.atomic.Value(u32).init(0);
var task_ptr: [*c]c.GstTask = null;
var name_buf: [32]u8 = .{0} ** 32;

fn body(_: c.gpointer) callconv(.c) void {
    const n = runs.fetchAdd(1, .seq_cst);
    if (n == 0) {
        var b: [17]u8 = .{0} ** 17;
        _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.GET_NAME), @intFromPtr(&b), 0, 0, 0);
        @memcpy(name_buf[0..17], &b);
    }
    if (n == 4) _ = c.gst_task_pause(task_ptr);
    c.g_usleep(1000);
}

var entered: u32 = 0;
var left: u32 = 0;
var freed: u32 = 0;

fn enter(_: [*c]c.GstTask, _: ?*c.GThread, _: c.gpointer) callconv(.c) void {
    entered += 1;
}

fn leave(_: [*c]c.GstTask, _: ?*c.GThread, _: c.gpointer) callconv(.c) void {
    left += 1;
}

fn free(_: c.gpointer) callconv(.c) void {
    freed += 1;
}

var shared_hits = std.atomic.Value(u32).init(0);

fn sharedWork(_: c.gpointer) callconv(.c) void {
    c.g_usleep(5000);
    _ = shared_hits.fetchAdd(1, .seq_cst);
}

pub fn main() void {
    c.gst_init(null, null);
    out("null func {d}", .{@intFromBool(c.gst_task_new(null, null, null) == null)});
    var lock: c.GRecMutex = undefined;
    c.g_rec_mutex_init(&lock);
    const t = c.gst_task_new(body, null, free);
    task_ptr = t;
    _ = c.gst_object_set_name(@ptrCast(t), "averyveryverylongtaskname");
    out("state {d} floating {d} start no lock {d}", .{ c.gst_task_get_state(t), c.g_object_is_floating(t), c.gst_task_start(t) });
    c.gst_task_set_lock(t, &lock);
    c.gst_task_set_enter_callback(t, enter, null, null);
    c.gst_task_set_leave_callback(t, leave, null, free);
    c.gst_task_set_leave_callback(t, leave, null, free);
    out("freed after reset {d}", .{freed});
    out("start {d} state {d}", .{ c.gst_task_start(t), c.gst_task_get_state(t) });
    while (c.gst_task_get_state(t) != c.GST_TASK_PAUSED) c.g_usleep(1000);
    c.g_usleep(20000);
    out("paused runs {d} name {s}", .{ runs.load(.seq_cst), std.mem.sliceTo(&name_buf, 0) });
    out("resume {d} state {d}", .{ c.gst_task_resume(t), c.gst_task_get_state(t) });
    while (runs.load(.seq_cst) < 10) c.g_usleep(1000);
    out("stop {d} join {d} state {d} entered {d} left {d}", .{ c.gst_task_stop(t), c.gst_task_join(t), c.gst_task_get_state(t), entered, left });
    out("resume stopped {d}", .{c.gst_task_resume(t)});
    const pool = c.gst_task_get_pool(t);
    out("pool type {s}", .{std.mem.span(c.g_type_name(c.G_TYPE_FROM_INSTANCE(pool)))});
    c.gst_object_unref(pool);
    c.gst_object_unref(t);
    out("freed {d}", .{freed});
    const sp = c.gst_shared_task_pool_new();
    out("shared max {d}", .{c.gst_shared_task_pool_get_max_threads(@ptrCast(sp))});
    c.gst_shared_task_pool_set_max_threads(@ptrCast(sp), 2);
    c.gst_task_pool_prepare(sp, null);
    const id1 = c.gst_task_pool_push(sp, sharedWork, null, null);
    const id2 = c.gst_task_pool_push(sp, sharedWork, null, null);
    c.gst_task_pool_join(sp, id1);
    c.gst_task_pool_join(sp, id2);
    out("shared hits {d} max {d} ids {d}", .{ shared_hits.load(.seq_cst), c.gst_shared_task_pool_get_max_threads(@ptrCast(sp)), @intFromBool(id1 != null and id2 != null) });
    c.gst_task_pool_cleanup(sp);
    var err: [*c]c.GError = null;
    const none = c.gst_task_pool_push(sp, sharedWork, null, &err);
    out("after cleanup {d} err {d}", .{ @intFromBool(none == null), @intFromBool(err != null) });
    const dp = c.gst_task_pool_new();
    var err2: [*c]c.GError = null;
    _ = c.gst_task_pool_push(dp, sharedWork, null, &err2);
    out("unprepared err {s}", .{if (err2 != null) std.mem.span(err2.*.message) else "none"});
    const ctx = c.gst_context_new(c.GST_TASK_POOL_CONTEXT_TYPE, 1);
    c.gst_context_set_task_pool(ctx, sp);
    var back: [*c]c.GstTaskPool = null;
    out("ctx get {d} same {d}", .{ c.gst_context_get_task_pool(ctx, &back), @intFromBool(back == sp) });
    c.gst_object_unref(back);
    c.gst_context_set_task_pool(ctx, null);
    out("ctx cleared {d}", .{c.gst_context_get_task_pool(ctx, &back)});
    c.gst_context_unref(ctx);
    c.gst_object_unref(sp);
    c.gst_object_unref(dp);
}
