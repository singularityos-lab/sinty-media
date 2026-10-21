const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn capture(cat: ?*c.GstDebugCategory, level: c.GstDebugLevel, file: [*c]const u8, func: [*c]const u8, line: c.gint, _: [*c]c.GObject, m: ?*c.GstDebugMessage, _: c.gpointer) callconv(.c) void {
    if (c.strcmp(c.gst_debug_category_get_name(cat), "ctxtest") != 0) return;
    out("  log {d} {s}:{d} {s} [{s}] {s}", .{ level, str(file), line, str(func), str(c.gst_debug_message_get_id(m)), str(c.gst_debug_message_get(m)) });
}

fn tail(s: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, s, "ctxtest") orelse return s;
    return s[idx..];
}

pub fn main() void {
    c.gst_init(null, null);
    c.gst_debug_set_active(1);
    _ = c.gst_debug_remove_log_function(c.gst_debug_log_default);
    const cat = c._gst_debug_category_new("ctxtest", 0, "context test");
    c.gst_debug_category_set_threshold(cat, c.GST_LEVEL_LOG);
    c.gst_debug_add_log_function(capture, null, null);
    const b = c.gst_log_context_builder_new(cat, c.GST_LOG_CONTEXT_FLAG_THROTTLE);
    const ctx = c.gst_log_context_builder_build(b);
    out("category {s}", .{str(c.gst_debug_category_get_name(c.gst_log_context_get_category(ctx)))});
    for (0..3) |i| {
        c.gst_debug_log_with_context(ctx, c.GST_LEVEL_INFO, "a.c", "fa", @intCast(10 + i), null, "hello %d", @as(c_int, @intCast(i)));
    }
    c.gst_debug_log_with_context(ctx, c.GST_LEVEL_INFO, "b.c", "fb", 1, null, "hello %d", @as(c_int, 9));
    c.gst_debug_log_literal_with_context(ctx, c.GST_LEVEL_INFO, "a.c", "fa", 1, null, "lit");
    c.gst_debug_log_literal_with_context(ctx, c.GST_LEVEL_INFO, "a.c", "fa", 2, null, "lit");
    c.gst_debug_log_id_with_context(ctx, c.GST_LEVEL_WARNING, "a.c", "fa", 3, "obj1", "id msg %s", "x");
    c.gst_debug_log_id_with_context(ctx, c.GST_LEVEL_WARNING, "a.c", "fa", 3, "obj2", "id msg %s", "x");
    c.gst_debug_log_id_literal_with_context(ctx, c.GST_LEVEL_WARNING, "a.c", "fa", 3, "obj2", "idlit");
    c.gst_debug_log_id_literal_with_context(ctx, c.GST_LEVEL_WARNING, "a.c", "fa", 4, "obj2", "idlit");
    c.gst_debug_log_with_context(ctx, c.GST_LEVEL_TRACE, "a.c", "fa", 1, null, "below threshold");
    c.gst_log_context_reset(ctx);
    c.gst_debug_log_with_context(ctx, c.GST_LEVEL_INFO, "a.c", "fa", 99, null, "hello %d", @as(c_int, 0));
    c.gst_debug_log_with_context(ctx, c.GST_LEVEL_MEMDUMP, "a.c", "fa", 1, null, "memdump");
    const b2 = c.gst_log_context_builder_new(cat, c.GST_LOG_CONTEXT_FLAG_THROTTLE);
    _ = c.gst_log_context_builder_set_hash_flags(b2, c.GST_LOG_CONTEXT_USE_STRING_ARGS | c.GST_LOG_CONTEXT_USE_LINE_NUMBER | c.GST_LOG_CONTEXT_IGNORE_FILE);
    _ = c.gst_log_context_builder_set_interval(b2, 0);
    const ctx2 = c.gst_log_context_builder_build(b2);
    for ([_]c_int{ 1, 1, 2, 2 }) |v| c.gst_debug_log_with_context(ctx2, c.GST_LEVEL_DEBUG, "x.c", "fx", 5, null, "val %d", v);
    c.gst_debug_log_with_context(ctx2, c.GST_LEVEL_DEBUG, "other.c", "fx", 5, null, "val %d", @as(c_int, 1));
    c.gst_debug_log_with_context(ctx2, c.GST_LEVEL_DEBUG, "x.c", "fx", 6, null, "val %d", @as(c_int, 1));
    const b3 = c.gst_log_context_builder_new(cat, 0);
    const ctx3 = c.gst_log_context_builder_build(b3);
    c.gst_debug_log_with_context(ctx3, c.GST_LEVEL_INFO, "n.c", "fn", 1, null, "nothrottle");
    c.gst_debug_log_with_context(ctx3, c.GST_LEVEL_INFO, "n.c", "fn", 1, null, "nothrottle");
    c._gst_debug_log_once(cat, c.GST_LEVEL_INFO, "o.c", "fo", 1, null, "once %d", @as(c_int, 1));
    c._gst_debug_log_once(cat, c.GST_LEVEL_INFO, "o.c", "fo", 1, null, "once %d", @as(c_int, 2));
    c._gst_debug_log_once(cat, c.GST_LEVEL_INFO, "o.c", "fo", 2, null, "once %d", @as(c_int, 3));
    c._gst_debug_log_once_id(cat, c.GST_LEVEL_INFO, "o.c", "fo", 7, "theid", "once id");
    c._gst_debug_log_once_id(cat, c.GST_LEVEL_INFO, "o.c", "fo", 7, "theid", "once id");
    c.gst_log_context_free(ctx);
    c.gst_log_context_free(ctx2);
    c.gst_log_context_free(ctx3);
    c.gst_log_context_free(ctx3);
    c.gst_debug_add_ring_buffer_logger(200, 0);
    c.gst_debug_add_ring_buffer_logger(200, 0);
    for (0..5) |i| c.gst_debug_log(cat, c.GST_LEVEL_INFO, "r.c", "fr", @intCast(i), null, "ring line %d", @as(c_int, @intCast(i)));
    const logs = c.gst_debug_ring_buffer_logger_get_logs();
    var n: usize = 0;
    while (logs[n] != null) : (n += 1) {
        var it = std.mem.splitScalar(u8, std.mem.span(logs[n]), '\n');
        while (it.next()) |l| if (l.len > 0) out("  ring {s}", .{tail(l)});
    }
    out("ring threads {d}", .{n});
    c.g_strfreev(logs);
    c.gst_debug_remove_ring_buffer_logger();
    out("after remove null {d}", .{@intFromBool(c.gst_debug_ring_buffer_logger_get_logs() == null)});
    const trace = c.gst_debug_get_stack_trace(0);
    out("trace nonempty {d}", .{@intFromBool(trace != null and trace[0] != 0)});
    c.g_free(trace);
    out("done", .{});
}
