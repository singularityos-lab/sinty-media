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

fn cmpInt(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    return @as(c.gint, @intCast(@intFromPtr(a))) - @as(c.gint, @intCast(@intFromPtr(b)));
}

pub fn main() void {
    c.gst_init(null, null);
    const pool = c.gst_buffer_pool_new();
    var config = c.gst_buffer_pool_get_config(pool);
    out("default config {s}", .{str(c.gst_structure_to_string(config))});
    const caps = c.gst_caps_from_string("video/x-raw, format=(string)RGBA, width=(int)4, height=(int)4");
    c.gst_buffer_pool_config_set_params(config, caps, 64, 2, 3);
    c.gst_buffer_pool_config_add_option(config, "GstBufferPoolOptionVideoMeta");
    c.gst_buffer_pool_config_add_option(config, "GstBufferPoolOptionVideoMeta");
    c.gst_buffer_pool_config_add_option(config, "other");
    out("options n {d} first {s} has {d} {d}", .{ c.gst_buffer_pool_config_n_options(config), str(c.gst_buffer_pool_config_get_option(config, 0)), c.gst_buffer_pool_config_has_option(config, "other"), c.gst_buffer_pool_config_has_option(config, "x") });
    out("config {s}", .{str(c.gst_structure_to_string(config))});
    out("validate {d} {d}", .{ c.gst_buffer_pool_config_validate_params(config, caps, 64, 2, 3), c.gst_buffer_pool_config_validate_params(config, caps, 128, 2, 3) });
    out("set config {d} active before {d}", .{ c.gst_buffer_pool_set_config(pool, config), c.gst_buffer_pool_is_active(pool) });
    out("has option {d}", .{c.gst_buffer_pool_has_option(pool, "GstBufferPoolOptionVideoMeta")});
    out("activate {d} active {d}", .{ c.gst_buffer_pool_set_active(pool, 1), c.gst_buffer_pool_is_active(pool) });
    config = c.gst_buffer_pool_get_config(pool);
    out("set config while active {d}", .{c.gst_buffer_pool_set_config(pool, config)});
    var bufs: [4][*c]c.GstBuffer = .{ null, null, null, null };
    var params = std.mem.zeroes(c.GstBufferPoolAcquireParams);
    params.flags = c.GST_BUFFER_POOL_ACQUIRE_FLAG_DONTWAIT;
    for (&bufs, 0..) |*b, i| {
        const r = c.gst_buffer_pool_acquire_buffer(pool, b, &params);
        out("acquire {d}: {d} size {d} pool {d}", .{ i, r, if (b.* != null) c.gst_buffer_get_size(b.*) else 0, @intFromBool(b.* != null and b.*.*.pool == pool) });
    }
    bufs[0].*.pts = 5;
    c.gst_mini_object_unref(@ptrCast(bufs[0]));
    var again: [*c]c.GstBuffer = null;
    out("reacquire {d} same {d} pts reset {d}", .{ c.gst_buffer_pool_acquire_buffer(pool, &again, &params), @intFromBool(again == bufs[0]), @intFromBool(again.*.pts == std.math.maxInt(u64)) });
    c.gst_buffer_set_size(bufs[1], 10);
    c.gst_mini_object_unref(@ptrCast(bufs[1]));
    c.gst_mini_object_unref(@ptrCast(bufs[2]));
    c.gst_mini_object_unref(@ptrCast(again));
    c.gst_buffer_pool_set_flushing(pool, 1);
    var f: [*c]c.GstBuffer = null;
    out("flushing acquire {d}", .{c.gst_buffer_pool_acquire_buffer(pool, &f, &params)});
    c.gst_buffer_pool_set_flushing(pool, 0);
    out("deactivate {d}", .{c.gst_buffer_pool_set_active(pool, 0)});
    out("acquire inactive {d}", .{c.gst_buffer_pool_acquire_buffer(pool, &f, &params)});
    c.gst_object_unref(pool);

    const q = c.gst_vec_deque_new(2);
    var i: usize = 1;
    while (i <= 20) : (i += 1) c.gst_vec_deque_push_tail(q, @ptrFromInt(i));
    out("len {d} head {d} tail {d} nth5 {d}", .{ c.gst_vec_deque_get_length(q), @intFromPtr(c.gst_vec_deque_peek_head(q)), @intFromPtr(c.gst_vec_deque_peek_tail(q)), @intFromPtr(c.gst_vec_deque_peek_nth(q, 5)) });
    var k: usize = 0;
    while (k < 7) : (k += 1) _ = c.gst_vec_deque_pop_head(q);
    c.gst_vec_deque_push_sorted(q, @ptrFromInt(15), cmpInt, null);
    out("find 15 {d} drop {d} poptail {d}", .{ c.gst_vec_deque_find(q, null, @ptrFromInt(15)), @intFromPtr(c.gst_vec_deque_drop_element(q, 3)), @intFromPtr(c.gst_vec_deque_pop_tail(q)) });
    var line: [512]u8 = undefined;
    var len: usize = 0;
    while (c.gst_vec_deque_pop_head(q)) |p| {
        const s = std.fmt.bufPrint(line[len..], "{d} ", .{@intFromPtr(p)}) catch break;
        len += s.len;
    }
    out("rest {s}", .{line[0..len]});
    c.gst_vec_deque_free(q);
}
