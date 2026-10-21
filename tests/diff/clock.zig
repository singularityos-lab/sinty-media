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

var ticks = std.atomic.Value(u32).init(0);

fn onTick(_: [*c]c.GstClock, t: c.GstClockTime, _: c.GstClockID, data: c.gpointer) callconv(.c) c.gboolean {
    _ = data;
    _ = t;
    _ = ticks.fetchAdd(1, .seq_cst);
    return 1;
}

fn onBad(_: [*c]c.GstClock, t: c.GstClockTime, _: c.GstClockID, _: c.gpointer) callconv(.c) c.gboolean {
    out("bad callback time {d}", .{t});
    return 1;
}

var destroyed: u32 = 0;

fn onDestroy(_: c.gpointer) callconv(.c) void {
    destroyed += 1;
}

pub fn main() void {
    c.gst_init(null, null);
    const clock = c.gst_system_clock_obtain();
    const again = c.gst_system_clock_obtain();
    out("same {d} name {s} type {s} parent {s}", .{ @intFromBool(clock == again), str(clock.*.object.name), str(c.g_type_name(c.G_TYPE_FROM_INSTANCE(clock))), str(c.g_type_name(c.g_type_parent(c.G_TYPE_FROM_INSTANCE(clock)))) });
    c.gst_object_unref(again);
    out("flags 0x{x} abstract {d}", .{ clock.*.object.flags, c.G_TYPE_IS_ABSTRACT(c.gst_clock_get_type()) });
    var ws: c.gint = 0;
    var wt: c.gint = 0;
    var to: u64 = 0;
    var kind: c.gint = 0;
    c.g_object_get(clock, "window-size", &ws, "window-threshold", &wt, "timeout", &to, "clock-type", &kind, @as([*c]const u8, null));
    out("props {d} {d} {d} {d}", .{ ws, wt, to, kind });
    out("resolution {d} timeout {d} mono {d} synced {d}", .{ c.gst_clock_get_resolution(clock), c.gst_clock_get_timeout(clock), c.gst_clock_is_system_monotonic(clock), c.gst_clock_is_synced(clock) });
    const t1 = c.gst_clock_get_time(clock);
    const t2 = c.gst_clock_get_time(clock);
    out("monotonic {d}", .{@intFromBool(t2 >= t1 and t1 > 0)});
    var a: u64 = 0;
    var b: u64 = 0;
    var n: u64 = 0;
    var d: u64 = 0;
    c.gst_clock_get_calibration(clock, &a, &b, &n, &d);
    out("calibration {d} {d} {d} {d}", .{ a, b, n, d });
    out("adjust {d} {d} {d} {d}", .{ c.gst_clock_adjust_with_calibration(clock, 1000, 500, 2000, 2, 1), c.gst_clock_adjust_with_calibration(clock, 100, 500, 2000, 2, 1), c.gst_clock_adjust_with_calibration(clock, 100, 500, 200, 3, 0), c.gst_clock_unadjust_with_calibration(clock, 3000, 500, 2000, 2, 1) });
    out("unadjust {d} {d}", .{ c.gst_clock_unadjust_with_calibration(clock, 100, 500, 2000, 2, 1), c.gst_clock_unadjust_with_calibration(clock, 100, 500, 2000, 0, 7) });
    c.gst_clock_set_calibration(clock, 0, 0, 0, 0);
    c.gst_clock_set_calibration(clock, 0, 0, c.GST_CLOCK_TIME_NONE, 1);
    const xy = [_]u64{ 0, 10, 100, 210, 200, 410, 300, 610, 400, 805 };
    var mn: u64 = 0;
    var md: u64 = 0;
    var bb: u64 = 0;
    var xb: u64 = 0;
    var r2: f64 = 0;
    const ok = c.gst_calculate_linear_regression(&xy, null, 5, &mn, &md, &bb, &xb, &r2);
    out("regression {d} {d}/{d} b {d} xbase {d} r2 {d:.6}", .{ ok, mn, md, bb, xb, r2 });
    const big = [_]u64{ 1 << 40, 1 << 41, (1 << 40) + 5000000000, (1 << 41) + 9000000000, (1 << 40) + 9000000000, (1 << 41) + 17000000000 };
    const ok2 = c.gst_calculate_linear_regression(&big, null, 3, &mn, &md, &bb, &xb, &r2);
    out("regression big {d} {d}/{d} b {d} xbase {d} r2 {d:.6}", .{ ok2, mn, md, bb, xb, r2 });
    const flat = [_]u64{ 5, 1, 5, 2 };
    out("regression flat {d}", .{c.gst_calculate_linear_regression(&flat, null, 2, &mn, &md, &bb, &xb, &r2)});
    var i: u64 = 0;
    var applied: c.gboolean = 0;
    while (i < 6) : (i += 1) applied = c.gst_clock_add_observation_unapplied(clock, 1000 * i, 2000 * i + 7, &r2, &a, &b, &n, &d);
    out("observation {d} {d} {d} {d}/{d} r2 {d:.3}", .{ applied, a, b, n, d, r2 });
    out("set master {d}", .{c.gst_clock_set_master(clock, null)});
    const now = c.gst_clock_get_time(clock);
    const past = c.gst_clock_new_single_shot_id(clock, now - 1000000);
    var jitter: c.GstClockTimeDiff = 0;
    const r = c.gst_clock_id_wait(past, &jitter);
    out("past wait {d} jitter positive {d} time ok {d} uses {d}", .{ r, @intFromBool(jitter > 0), @intFromBool(c.gst_clock_id_get_time(past) == now - 1000000), c.gst_clock_id_uses_clock(past, clock) });
    const owner = c.gst_clock_id_get_clock(past);
    out("owner same {d}", .{@intFromBool(owner == clock)});
    c.gst_object_unref(owner);
    out("reinit {d}", .{c.gst_clock_single_shot_id_reinit(clock, past, c.gst_clock_get_time(clock) + 3000000)});
    const r2w = c.gst_clock_id_wait(past, &jitter);
    out("future wait {d} late {d}", .{ r2w, @intFromBool(c.gst_clock_get_time(clock) >= c.gst_clock_id_get_time(past)) });
    c.gst_clock_id_unref(past);
    out("bad ids {d} {d}", .{ @intFromBool(c.gst_clock_new_single_shot_id(clock, c.GST_CLOCK_TIME_NONE) == null), @intFromBool(c.gst_clock_new_periodic_id(clock, 0, 0) == null) });
    const periodic = c.gst_clock_new_periodic_id(clock, c.gst_clock_get_time(clock), 2000000);
    out("async {d}", .{c.gst_clock_id_wait_async(periodic, onTick, null, onDestroy)});
    while (ticks.load(.seq_cst) < 4) _ = c.g_usleep(1000);
    c.gst_clock_id_unschedule(periodic);
    c.g_usleep(10000);
    const seen = ticks.load(.seq_cst);
    c.g_usleep(10000);
    out("stopped {d} destroyed {d}", .{ @intFromBool(ticks.load(.seq_cst) == seen), destroyed });
    out("unscheduled wait {d}", .{c.gst_clock_id_wait(periodic, null)});
    c.gst_clock_id_unref(periodic);
    out("destroyed after unref {d}", .{destroyed});
    const single = c.gst_clock_new_single_shot_id(clock, c.gst_clock_get_time(clock) + 50000000);
    out("async single {d}", .{c.gst_clock_id_wait_async(single, onTick, null, null)});
    c.gst_clock_id_unschedule(single);
    c.gst_clock_id_unref(single);
    const ent: [*c]c.GstClockEntry = @ptrCast(@alignCast(c.gst_clock_new_single_shot_id(clock, 5)));
    ent.*.time = c.GST_CLOCK_TIME_NONE;
    out("badtime {d} {d}", .{ c.gst_clock_id_wait(@ptrCast(ent), null), c.gst_clock_id_wait_async(@ptrCast(ent), onBad, null, null) });
    c.gst_clock_id_unref(@ptrCast(ent));
    const mono = c.g_object_new(c.gst_system_clock_get_type(), "clock-type", c.GST_CLOCK_TYPE_REALTIME, @as([*c]const u8, null));
    out("realtime is system mono {d} ref floating {d}", .{ c.gst_clock_is_system_monotonic(@ptrCast(@alignCast(mono))), c.g_object_is_floating(mono) });
    const rt = c.gst_clock_get_time(@ptrCast(@alignCast(mono)));
    out("realtime plausible {d}", .{@intFromBool(rt > 1600000000 * @as(u64, 1000000000))});
    c.g_object_unref(mono);
    c.gst_object_unref(clock);
}
