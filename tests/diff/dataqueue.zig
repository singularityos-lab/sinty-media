const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

var destroyed: u32 = 0;
fn destroy(p: c.gpointer) callconv(.c) void {
    const it: *c.GstDataQueueItem = @ptrCast(@alignCast(p));
    destroyed += 1;
    if (it.object != null) c.gst_mini_object_unref(it.object);
    c.g_free(p);
}

fn item(size: c.guint, dur: u64, visible: bool, obj: ?*c.GstMiniObject) *c.GstDataQueueItem {
    const it: *c.GstDataQueueItem = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstDataQueueItem))));
    it.object = obj;
    it.size = size;
    it.duration = dur;
    it.visible = @intFromBool(visible);
    it.destroy = destroy;
    return it;
}

var limit: c.guint = 3;
fn checkFull(_: ?*c.GstDataQueue, visible: c.guint, bytes: c.guint, time: u64, _: c.gpointer) callconv(.c) c.gboolean {
    _ = bytes;
    _ = time;
    return @intFromBool(visible >= limit);
}

var fulls: u32 = 0;
var empties: u32 = 0;
fn onFull(q: ?*c.GstDataQueue, _: c.gpointer) callconv(.c) void {
    fulls += 1;
    _ = q;
}
fn onEmpty(_: ?*c.GstDataQueue, _: c.gpointer) callconv(.c) void {
    empties += 1;
}
fn sigFull(_: ?*c.GstDataQueue, _: c.gpointer) callconv(.c) void {
    out("signal full", .{});
}
fn sigEmpty(_: ?*c.GstDataQueue, _: c.gpointer) callconv(.c) void {
    out("signal empty", .{});
}

fn level(q: ?*c.GstDataQueue, label: []const u8) void {
    var l: c.GstDataQueueSize = undefined;
    c.gst_data_queue_get_level(q, &l);
    var vb: c.guint = 0;
    var vv: c.guint = 0;
    var vt: u64 = 0;
    c.g_object_get(q, "current-level-bytes", &vb, "current-level-visible", &vv, "current-level-time", &vt, @as(?*anyopaque, null));
    out("{s}: visible={d} bytes={d} time={d} props {d} {d} {d} empty={d} full={d}", .{ label, l.visible, l.bytes, l.time, vv, vb, vt, c.gst_data_queue_is_empty(q), c.gst_data_queue_is_full(q) });
}

fn popper(data: c.gpointer) callconv(.c) c.gpointer {
    const q: ?*c.GstDataQueue = @ptrCast(@alignCast(data));
    var it: [*c]c.GstDataQueueItem = null;
    const r = c.gst_data_queue_pop(q, &it);
    if (r != 0) destroy(it);
    return @ptrFromInt(@as(usize, @intCast(r)) + 10);
}

fn pusher(data: c.gpointer) callconv(.c) c.gpointer {
    const q: ?*c.GstDataQueue = @ptrCast(@alignCast(data));
    return @ptrFromInt(@as(usize, @intCast(c.gst_data_queue_push(q, item(1, 1, true, null)))) + 10);
}

pub fn main() void {
    c.gst_init(null, null);
    const q = c.gst_data_queue_new(checkFull, onFull, onEmpty, null);
    out("type {s}", .{std.mem.span(c.g_type_name(c.gst_data_queue_get_type()))});
    level(q, "new");
    out("push {d}", .{c.gst_data_queue_push(q, item(100, 10, true, null))});
    out("push {d}", .{c.gst_data_queue_push(q, item(50, 5, false, @ptrCast(c.gst_buffer_new())))});
    out("push {d}", .{c.gst_data_queue_push(q, item(25, 7, true, @ptrCast(c.gst_event_new_eos())))});
    level(q, "three");
    out("force {d}", .{c.gst_data_queue_push_force(q, item(1, 1, true, null))});
    level(q, "forced");
    var it: [*c]c.GstDataQueueItem = null;
    out("peek {d} size {d}", .{ c.gst_data_queue_peek(q, &it), it[0].size });
    out("pop {d} size {d}", .{ c.gst_data_queue_pop(q, &it), it[0].size });
    destroy(it);
    level(q, "popped");
    out("drop event {d}", .{c.gst_data_queue_drop_head(q, c.gst_event_get_type())});
    out("drop caps {d}", .{c.gst_data_queue_drop_head(q, c.gst_caps_get_type())});
    level(q, "dropped");
    out("drop buffer {d} destroyed {d}", .{ c.gst_data_queue_drop_head(q, c._gst_buffer_type), destroyed });
    c.gst_data_queue_flush(q);
    level(q, "flushed");
    out("destroyed {d}", .{destroyed});

    const th = c.g_thread_new("pop", popper, q);
    c.g_usleep(100000);
    out("empties while waiting {d}", .{empties});
    _ = c.gst_data_queue_push(q, item(9, 9, true, null));
    out("popper {d}", .{@intFromPtr(c.g_thread_join(th))});

    limit = 1;
    _ = c.gst_data_queue_push(q, item(1, 1, true, null));
    const th2 = c.g_thread_new("push", pusher, q);
    c.g_usleep(100000);
    out("fulls {d}", .{fulls});
    c.gst_data_queue_limits_changed(q);
    c.g_usleep(50000);
    limit = 5;
    c.gst_data_queue_limits_changed(q);
    out("pusher {d}", .{@intFromPtr(c.g_thread_join(th2))});
    level(q, "after limits");

    limit = 1;
    const th3 = c.g_thread_new("push", pusher, q);
    c.g_usleep(100000);
    c.gst_data_queue_set_flushing(q, 1);
    out("flushing pusher {d}", .{@intFromPtr(c.g_thread_join(th3))});
    out("flushing ops {d} {d} {d} {d}", .{ c.gst_data_queue_push(q, item(1, 1, true, null)), c.gst_data_queue_push_force(q, item(1, 1, true, null)), c.gst_data_queue_pop(q, &it), c.gst_data_queue_peek(q, &it) });
    c.gst_data_queue_flush(q);
    const th4 = c.g_thread_new("pop", popper, q);
    out("flushing popper {d}", .{@intFromPtr(c.g_thread_join(th4))});
    c.gst_data_queue_set_flushing(q, 0);
    const th5 = c.g_thread_new("pop", popper, q);
    c.g_usleep(100000);
    c.gst_data_queue_set_flushing(q, 1);
    out("flushed waiting popper {d}", .{@intFromPtr(c.g_thread_join(th5))});
    c.gst_data_queue_set_flushing(q, 0);
    c.g_object_unref(q);

    const sq = c.gst_data_queue_new(checkFull, null, null, null);
    _ = c.g_signal_connect_data(sq, "full", @ptrCast(&sigFull), null, null, 0);
    _ = c.g_signal_connect_data(sq, "empty", @ptrCast(&sigEmpty), null, null, 0);
    limit = 1;
    _ = c.gst_data_queue_push(sq, item(1, 1, true, null));
    const th6 = c.g_thread_new("push", pusher, sq);
    c.g_usleep(100000);
    c.gst_data_queue_set_flushing(sq, 1);
    out("sig pusher {d}", .{@intFromPtr(c.g_thread_join(th6))});
    c.gst_data_queue_set_flushing(sq, 0);
    c.gst_data_queue_flush(sq);
    const th7 = c.g_thread_new("pop", popper, sq);
    c.g_usleep(100000);
    c.gst_data_queue_set_flushing(sq, 1);
    out("sig popper {d}", .{@intFromPtr(c.g_thread_join(th7))});
    _ = c.gst_data_queue_push_force(sq, item(1, 1, true, null));
    c.gst_data_queue_set_flushing(sq, 0);
    _ = c.gst_data_queue_push_force(sq, item(1, 1, true, null));
    c.g_object_unref(sq);
    out("destroyed total {d}", .{destroyed});

    out("crit new {d}", .{@intFromBool(c.gst_data_queue_new(null, null, null, null) == null)});
    out("done", .{});
}
