const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn num(p: c.gpointer) usize {
    return @intFromPtr(p);
}

fn cmp(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const x = @intFromPtr(a);
    const y = @intFromPtr(b);
    return if (x < y) -1 else if (x > y) @as(c.gint, 1) else 0;
}

fn cmpStruct(a: c.gconstpointer, b: c.gconstpointer, _: c.gpointer) callconv(.c) c.gint {
    const x = @as(*const u32, @ptrCast(@alignCast(a))).*;
    const y = @as(*const u32, @ptrCast(@alignCast(b))).*;
    return if (x < y) -1 else if (x > y) @as(c.gint, 1) else 0;
}

fn eq(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return if (a == b) 0 else 1;
}

var cleared: usize = 0;
fn clear(p: c.gpointer) callconv(.c) void {
    cleared += @as(*u32, @ptrCast(@alignCast(p))).*;
}

fn flowName(r: c.GstFlowReturn) []const u8 {
    return std.mem.span(c.gst_flow_get_name(r));
}

pub fn main() void {
    c.gst_init(null, null);
    const q = c.gst_queue_array_new(2);
    out("empty {d} len {d}", .{ c.gst_queue_array_is_empty(q), c.gst_queue_array_get_length(q) });
    for (1..12) |i| c.gst_queue_array_push_tail(q, @ptrFromInt(i * 10));
    out("len {d} head {d} tail {d} nth3 {d}", .{ c.gst_queue_array_get_length(q), num(c.gst_queue_array_peek_head(q)), num(c.gst_queue_array_peek_tail(q)), num(c.gst_queue_array_peek_nth(q, 3)) });
    out("pop {d} {d} tail {d}", .{ num(c.gst_queue_array_pop_head(q)), num(c.gst_queue_array_pop_head(q)), num(c.gst_queue_array_pop_tail(q)) });
    out("find 50 -> {d} miss -> {d}", .{ c.gst_queue_array_find(q, eq, @ptrFromInt(50)), @as(i32, @bitCast(c.gst_queue_array_find(q, eq, @ptrFromInt(7)))) });
    out("drop {d} len {d}", .{ num(c.gst_queue_array_drop_element(q, 2)), c.gst_queue_array_get_length(q) });
    c.gst_queue_array_push_sorted(q, @ptrFromInt(55), cmp, null);
    c.gst_queue_array_push_tail(q, @ptrFromInt(5));
    c.gst_queue_array_sort(q, cmp, null);
    var line: [256]u8 = undefined;
    var n: usize = 0;
    for (0..c.gst_queue_array_get_length(q)) |i| {
        const s = std.fmt.bufPrint(line[n..], "{d} ", .{num(c.gst_queue_array_peek_nth(q, @intCast(i)))}) catch break;
        n += s.len;
    }
    out("sorted {s}", .{line[0..n]});
    c.gst_queue_array_clear(q);
    out("cleared {d} pop {d}", .{ c.gst_queue_array_get_length(q), num(c.gst_queue_array_pop_head(q)) });
    c.gst_queue_array_free(q);

    const s = c.gst_queue_array_new_for_struct(@sizeOf(u32), 1);
    c.gst_queue_array_set_clear_func(s, clear);
    for ([_]u32{ 9, 3, 7, 1 }) |x| {
        var v = x;
        c.gst_queue_array_push_tail_struct(s, &v);
    }
    var v4: u32 = 4;
    c.gst_queue_array_push_sorted_struct(s, &v4, cmpStruct, null);
    out("struct head {d} tail {d} nth1 {d}", .{ @as(*u32, @ptrCast(@alignCast(c.gst_queue_array_peek_head_struct(s)))).*, @as(*u32, @ptrCast(@alignCast(c.gst_queue_array_peek_tail_struct(s)))).*, @as(*u32, @ptrCast(@alignCast(c.gst_queue_array_peek_nth_struct(s, 1)))).* });
    var dropped: u32 = 0;
    out("drop struct {d} {d}", .{ c.gst_queue_array_drop_struct(s, 0, &dropped), dropped });
    out("pop struct {d} {d}", .{ @as(*u32, @ptrCast(@alignCast(c.gst_queue_array_pop_head_struct(s)))).*, @as(*u32, @ptrCast(@alignCast(c.gst_queue_array_pop_tail_struct(s)))).* });
    c.gst_queue_array_free(s);
    out("clear func total {d}", .{cleared});

    const k = c.gst_flow_combiner_new();
    out("type {s}", .{std.mem.span(c.g_type_name(c.gst_flow_combiner_get_type()))});
    out("no pads ok {s} eos {s}", .{ flowName(c.gst_flow_combiner_update_flow(k, c.GST_FLOW_OK)), flowName(c.gst_flow_combiner_update_flow(k, c.GST_FLOW_EOS)) });
    var pads: [3]?*c.GstPad = undefined;
    for (&pads, 0..) |*p, i| {
        const name = [_]u8{ 'p', @intCast('0' + i), 0 };
        p.* = c.gst_pad_new(&name, c.GST_PAD_SRC);
        _ = c.gst_object_ref_sink(p.*);
        c.gst_flow_combiner_add_pad(k, p.*);
    }
    out("refs {d}", .{@as(*c.GObject, @ptrCast(@alignCast(pads[0]))).ref_count});
    const cases = [_][2]c.GstFlowReturn{
        .{ 0, c.GST_FLOW_NOT_LINKED },
        .{ 1, c.GST_FLOW_NOT_LINKED },
        .{ 2, c.GST_FLOW_NOT_LINKED },
        .{ 0, c.GST_FLOW_OK },
        .{ 0, c.GST_FLOW_EOS },
        .{ 1, c.GST_FLOW_EOS },
        .{ 2, c.GST_FLOW_EOS },
        .{ 1, c.GST_FLOW_NOT_NEGOTIATED },
        .{ 1, c.GST_FLOW_EOS },
        .{ 2, c.GST_FLOW_FLUSHING },
        .{ 2, c.GST_FLOW_OK },
        .{ 0, c.GST_FLOW_CUSTOM_SUCCESS },
        .{ 0, c.GST_FLOW_ERROR },
    };
    for (cases) |cs| out("pad{d} {s} -> {s} last {s}", .{ cs[0], flowName(cs[1]), flowName(c.gst_flow_combiner_update_pad_flow(k, pads[@intCast(cs[0])], cs[1])), flowName(c.gst_pad_get_last_flow_return(pads[@intCast(cs[0])])) });
    c.gst_flow_combiner_reset(k);
    out("reset last {s} {s}", .{ flowName(c.gst_pad_get_last_flow_return(pads[0])), flowName(c.gst_flow_combiner_update_flow(k, c.GST_FLOW_EOS)) });
    c.gst_flow_combiner_remove_pad(k, pads[1]);
    c.gst_flow_combiner_remove_pad(k, pads[1]);
    out("removed refs {d}", .{@as(*c.GObject, @ptrCast(@alignCast(pads[1]))).ref_count});
    const k2 = c.gst_flow_combiner_ref(k);
    c.gst_flow_combiner_unref(k2);
    c.gst_flow_combiner_clear(k);
    out("cleared refs {d} {d}", .{ @as(*c.GObject, @ptrCast(@alignCast(pads[0]))).ref_count, @as(*c.GObject, @ptrCast(@alignCast(pads[2]))).ref_count });
    c.gst_flow_combiner_add_pad(k, pads[0]);
    var bv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&bv, c.gst_flow_combiner_get_type());
    c.g_value_set_boxed(&bv, k);
    c.g_value_unset(&bv);
    c.gst_flow_combiner_free(k);
    out("freed refs {d}", .{@as(*c.GObject, @ptrCast(@alignCast(pads[0]))).ref_count});
    for (pads) |p| c.gst_object_unref(p);
    out("crit {s}", .{flowName(c.gst_flow_combiner_update_flow(null, c.GST_FLOW_OK))});
    out("crit {s}", .{flowName(c.gst_flow_combiner_update_pad_flow(null, null, c.GST_FLOW_OK))});
    c.gst_flow_combiner_add_pad(null, null);
    c.gst_flow_combiner_remove_pad(k2, null);
    c.gst_flow_combiner_clear(null);
    c.gst_flow_combiner_reset(null);
    c.gst_flow_combiner_unref(null);
    out("crit ref null {d}", .{@intFromBool(c.gst_flow_combiner_ref(null) == null)});
    out("done", .{});
}
