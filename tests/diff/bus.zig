const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn name(m: [*c]c.GstMessage) []const u8 {
    if (m == null) return "none";
    return str(c.gst_message_type_get_name(m.*.type));
}

var sync_seen: u32 = 0;

fn dropApps(_: [*c]c.GstBus, m: [*c]c.GstMessage, _: c.gpointer) callconv(.c) c.GstBusSyncReply {
    sync_seen += 1;
    if (m.*.type == c.GST_MESSAGE_APPLICATION) {
        c.gst_mini_object_unref(@ptrCast(m));
        return c.GST_BUS_DROP;
    }
    return c.GST_BUS_PASS;
}

fn onSync(_: [*c]c.GstBus, m: [*c]c.GstMessage, _: c.gpointer) callconv(.c) void {
    out("sync-message {s}", .{name(m)});
}

fn onEos(_: [*c]c.GstBus, m: [*c]c.GstMessage, _: c.gpointer) callconv(.c) void {
    out("detailed eos {s}", .{name(m)});
}

var watch_count: u32 = 0;

fn onWatch(_: [*c]c.GstBus, m: [*c]c.GstMessage, data: c.gpointer) callconv(.c) c.gboolean {
    watch_count += 1;
    out("watch {s}", .{name(m)});
    if (m.*.type == c.GST_MESSAGE_EOS) c.g_main_loop_quit(@ptrCast(data));
    return 1;
}

var notified: u32 = 0;

fn onNotify(_: c.gpointer) callconv(.c) void {
    notified += 1;
}

fn asyncReply(_: [*c]c.GstBus, _: [*c]c.GstMessage, _: c.gpointer) callconv(.c) c.GstBusSyncReply {
    return c.GST_BUS_ASYNC;
}

fn poster(data: c.gpointer) callconv(.c) c.gpointer {
    const bus: [*c]c.GstBus = @ptrCast(@alignCast(data));
    c.g_usleep(20000);
    _ = c.gst_bus_post(bus, c.gst_message_new_eos(null));
    return null;
}

pub fn main() void {
    c.gst_init(null, null);
    const bus = c.gst_bus_new();
    out("type {s} floating {d} pending {d} flags {d}", .{ str(c.g_type_name(c.G_TYPE_FROM_INSTANCE(bus))), c.g_object_is_floating(bus), c.gst_bus_have_pending(bus), bus.*.object.flags });
    _ = c.gst_bus_post(bus, c.gst_message_new_eos(null));
    _ = c.gst_bus_post(bus, c.gst_message_new_application(null, c.gst_structure_new_empty("app")));
    _ = c.gst_bus_post(bus, c.gst_message_new_latency(null));
    out("pending {d} peek {s}", .{ c.gst_bus_have_pending(bus), name(c.gst_bus_peek(bus)) });
    const f = c.gst_bus_pop_filtered(bus, c.GST_MESSAGE_LATENCY);
    out("filtered {s} pending {d} next {s}", .{ name(f), c.gst_bus_have_pending(bus), name(c.gst_bus_pop(bus)) });
    out("timed empty {s}", .{name(c.gst_bus_timed_pop(bus, 10000000))});
    out("bad types {s}", .{name(c.gst_bus_pop_filtered(bus, 0))});
    c.gst_bus_set_sync_handler(bus, dropApps, null, onNotify);
    c.gst_bus_enable_sync_message_emission(bus);
    _ = c.g_signal_connect_data(bus, "sync-message", @ptrCast(&onSync), null, null, 0);
    _ = c.g_signal_connect_data(bus, "sync-message::eos", @ptrCast(&onEos), null, null, 0);
    _ = c.gst_bus_post(bus, c.gst_message_new_application(null, c.gst_structure_new_empty("app")));
    _ = c.gst_bus_post(bus, c.gst_message_new_eos(null));
    out("sync seen {d} pending {s}", .{ sync_seen, name(c.gst_bus_pop(bus)) });
    c.gst_bus_disable_sync_message_emission(bus);
    c.gst_bus_disable_sync_message_emission(bus);
    c.gst_bus_set_sync_handler(bus, null, null, null);
    out("notified {d}", .{notified});
    c.gst_bus_set_flushing(bus, 1);
    out("post flushing {d} flags {d}", .{ c.gst_bus_post(bus, c.gst_message_new_eos(null)), bus.*.object.flags });
    c.gst_bus_set_flushing(bus, 0);
    var fd: c.GPollFD = undefined;
    c.gst_bus_get_pollfd(bus, &fd);
    out("pollfd valid {d} events {d}", .{ @intFromBool(fd.fd >= 0), fd.events });
    const loop = c.g_main_loop_new(null, 0);
    const id = c.gst_bus_add_watch(bus, onWatch, loop);
    out("watch id {d} second {d}", .{ @intFromBool(id > 0), c.gst_bus_add_watch(bus, onWatch, loop) });
    _ = c.gst_bus_post(bus, c.gst_message_new_latency(null));
    _ = c.gst_bus_post(bus, c.gst_message_new_eos(null));
    c.g_main_loop_run(loop);
    out("watch count {d} remove {d} again {d}", .{ watch_count, c.gst_bus_remove_watch(bus), c.gst_bus_remove_watch(bus) });
    c.gst_bus_add_signal_watch(bus);
    c.gst_bus_add_signal_watch(bus);
    out("remove signal via watch {d}", .{c.gst_bus_remove_watch(bus)});
    c.gst_bus_remove_signal_watch(bus);
    c.gst_bus_remove_signal_watch(bus);
    c.gst_bus_remove_signal_watch(bus);
    const th = c.g_thread_new("poster", poster, bus);
    const got = c.gst_bus_poll(bus, c.GST_MESSAGE_EOS, c.GST_SECOND);
    _ = c.g_thread_join(th);
    out("poll {s}", .{name(got)});
    out("poll timeout {s}", .{name(c.gst_bus_poll(bus, c.GST_MESSAGE_ERROR, 30 * c.GST_MSECOND))});
    const th2 = c.g_thread_new("poster", poster, bus);
    const waited = c.gst_bus_timed_pop_filtered(bus, c.GST_CLOCK_TIME_NONE, c.GST_MESSAGE_EOS);
    _ = c.g_thread_join(th2);
    out("blocking pop {s}", .{name(waited)});
    c.gst_bus_set_sync_handler(bus, asyncReply, null, null);
    const th3 = c.g_thread_new("poster", poster, bus);
    const am = c.gst_bus_timed_pop(bus, c.GST_SECOND);
    out("async flag {d}", .{@intFromBool(am.*.mini_object.flags & c.GST_MINI_OBJECT_FLAG_LAST != 0)});
    c.gst_mini_object_unref(@ptrCast(am));
    _ = c.g_thread_join(th3);
    c.gst_bus_set_sync_handler(bus, null, null, null);
    const quiet = c.g_object_new(c.gst_bus_get_type(), "enable-async", @as(c.gboolean, 0), @as([*c]const u8, null));
    out("no async post {d} pending {d}", .{ c.gst_bus_post(@ptrCast(@alignCast(quiet)), c.gst_message_new_eos(null)), c.gst_bus_have_pending(@ptrCast(@alignCast(quiet))) });
    out("no async timed {s}", .{name(c.gst_bus_timed_pop(@ptrCast(@alignCast(quiet)), 1000))});
    c.g_object_unref(quiet);
    const ps = c.gst_poll_new(1);
    var pipe: [2]c_int = undefined;
    _ = std.c.pipe(&pipe);
    var pfd: c.GstPollFD = undefined;
    c.gst_poll_fd_init(&pfd);
    pfd.fd = pipe[0];
    out("poll add {d} read {d} wait {d}", .{ c.gst_poll_add_fd(ps, &pfd), c.gst_poll_fd_ctl_read(ps, &pfd, 1), c.gst_poll_wait(ps, 0) });
    _ = std.c.write(pipe[1], "x", 1);
    out("poll wait {d} can read {d} closed {d}", .{ c.gst_poll_wait(ps, c.GST_SECOND), c.gst_poll_fd_can_read(ps, &pfd), c.gst_poll_fd_has_closed(ps, &pfd) });
    _ = std.c.close(pipe[1]);
    _ = c.gst_poll_wait(ps, c.GST_SECOND);
    out("closed {d} remove {d} twice {d}", .{ c.gst_poll_fd_has_closed(ps, &pfd), c.gst_poll_remove_fd(ps, &pfd), c.gst_poll_remove_fd(ps, &pfd) });
    c.gst_poll_set_flushing(ps, 1);
    out("flushing wait {d}", .{c.gst_poll_wait(ps, 0)});
    c.gst_poll_free(ps);
    const tm = c.gst_poll_new_timer();
    out("timer write {d} {d} read {d} {d} {d}", .{ c.gst_poll_write_control(tm), c.gst_poll_write_control(tm), c.gst_poll_read_control(tm), c.gst_poll_read_control(tm), c.gst_poll_read_control(tm) });
    c.gst_poll_free(tm);
    c.gst_object_unref(bus);
}
