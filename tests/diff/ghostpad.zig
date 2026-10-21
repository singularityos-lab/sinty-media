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

fn name(p: anytype) []const u8 {
    if (p == null) return "(null)";
    return str(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

fn flags(p: anytype) c.guint32 {
    return @as(*c.GstObject, @ptrCast(@alignCast(p))).flags;
}

var chained: u32 = 0;

fn chain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    chained += 1;
    out("  chain size {d}", .{c.gst_buffer_get_size(b)});
    c.gst_buffer_unref(b);
    return c.GST_FLOW_OK;
}

fn chainList(_: ?*c.GstPad, _: [*c]c.GstObject, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    out("  chain list {d}", .{c.gst_buffer_list_length(l)});
    c.gst_mini_object_unref(@ptrCast(@alignCast(l)));
    return c.GST_FLOW_OK;
}

fn getrange(_: ?*c.GstPad, _: [*c]c.GstObject, offset: u64, size: c.guint, b: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    out("  getrange {d} {d}", .{ offset, size });
    b.* = c.gst_buffer_new_allocate(null, size, null);
    return c.GST_FLOW_OK;
}

fn eventOk(_: ?*c.GstPad, _: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    c.gst_event_unref(e);
    return 1;
}

fn schedQuery(_: ?*c.GstPad, _: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q.*.type == c.GST_QUERY_SCHEDULING) {
        c.gst_query_set_scheduling(q, c.GST_SCHEDULING_FLAG_SEEKABLE, 1, -1, 0);
        c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PULL);
        c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
        return 1;
    }
    return 0;
}

fn dumpLinks(p: ?*c.GstPad) void {
    const it = c.gst_pad_iterate_internal_links(p);
    if (it == null) {
        out("  links none", .{});
        return;
    }
    var v = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &v) == c.GST_ITERATOR_OK) {
        out("  link {s}", .{name(c.g_value_get_object(&v))});
        _ = c.g_value_reset(&v);
    }
    c.g_value_unset(&v);
    c.gst_iterator_free(it);
}

fn modeName(p: ?*c.GstPad) []const u8 {
    return if (c.gst_pad_is_active(p) != 0) "on" else "off";
}

fn peerName(p: ?*c.GstPad) []const u8 {
    const q = c.gst_pad_get_peer(p);
    if (q == null) return "(null)";
    c.gst_object_unref(q);
    return name(q);
}

pub fn main() void {
    c.gst_init(null, null);
    var q: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_ghost_pad_get_type(), &q);
    out("ghost sizes {d} {d}", .{ q.instance_size, q.class_size });
    c.g_type_query(c.gst_proxy_pad_get_type(), &q);
    out("proxy sizes {d} {d} parent {s}", .{ q.instance_size, q.class_size, str(c.g_type_name(c.g_type_parent(c.gst_ghost_pad_get_type()))) });

    const g = c.gst_ghost_pad_new_no_target("g", c.GST_PAD_SINK);
    const gi: ?*c.GstPad = @ptrCast(c.gst_proxy_pad_get_internal(@ptrCast(g)));
    out("ghost {s} flags 0x{x} internal {s} dir {d} flags 0x{x} parent {s}", .{ name(g), flags(g), name(gi), c.gst_pad_get_direction(gi), flags(gi), name(@as(*c.GstObject, @ptrCast(@alignCast(gi))).parent) });
    const back: ?*c.GstPad = @ptrCast(c.gst_proxy_pad_get_internal(@ptrCast(gi)));
    out("back is ghost {d} target null {d}", .{ @intFromBool(back == g), @intFromBool(c.gst_ghost_pad_get_target(@ptrCast(g)) == null) });
    c.gst_object_unref(back);
    dumpLinks(g);
    dumpLinks(gi);

    const t = c.gst_pad_new("t", c.GST_PAD_SINK);
    c.gst_pad_set_chain_function_full(t, chain, null, null);
    c.gst_pad_set_chain_list_function_full(t, chainList, null, null);
    c.gst_pad_set_event_function_full(t, eventOk, null, null);
    out("set target {d}", .{c.gst_ghost_pad_set_target(@ptrCast(g), t)});
    const tg = c.gst_ghost_pad_get_target(@ptrCast(g));
    out("target {s} peer of internal {s}", .{ name(tg), peerName(gi) });
    c.gst_object_unref(tg);
    out("set same internal {d}", .{c.gst_ghost_pad_set_target(@ptrCast(g), gi)});

    const s = c.gst_pad_new("s", c.GST_PAD_SRC);
    out("link {d}", .{c.gst_pad_link(s, g)});
    out("active s {d} g {d} t {d}", .{ c.gst_pad_set_active(s, 1), c.gst_pad_set_active(g, 1), c.gst_pad_set_active(t, 1) });
    out("modes {s} {s} {s} {s}", .{ modeName(s), modeName(g), modeName(gi), modeName(t) });
    _ = c.gst_pad_push_event(s, c.gst_event_new_stream_start("x"));
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_BYTES);
    _ = c.gst_pad_push_event(s, c.gst_event_new_segment(&seg));
    out("push {d}", .{c.gst_pad_push(s, c.gst_buffer_new_allocate(null, 9, null))});
    const l = c.gst_buffer_list_new();
    c.gst_buffer_list_insert(l, -1, c.gst_buffer_new_allocate(null, 1, null));
    c.gst_buffer_list_insert(l, -1, c.gst_buffer_new_allocate(null, 2, null));
    out("push list {d}", .{c.gst_pad_push_list(s, l)});
    out("chained {d} sticky on target {d}", .{ chained, @intFromBool(c.gst_pad_get_sticky_event(t, c.GST_EVENT_SEGMENT, 0) != null) });
    out("deactivate g {d} modes {s} {s} {s}", .{ c.gst_pad_set_active(g, 0), modeName(g), modeName(gi), modeName(t) });
    out("clear target {d} null {d}", .{ c.gst_ghost_pad_set_target(@ptrCast(g), null), @intFromBool(c.gst_ghost_pad_get_target(@ptrCast(g)) == null) });
    out("push untargeted {d}", .{c.gst_pad_push(s, c.gst_buffer_new())});

    const pt = c.gst_pad_new("pt", c.GST_PAD_SRC);
    c.gst_pad_set_getrange_function_full(pt, getrange, null, null);
    c.gst_pad_set_query_function_full(pt, schedQuery, null, null);
    const gs = c.gst_ghost_pad_new("gs", pt);
    const ps = c.gst_pad_new("ps", c.GST_PAD_SINK);
    out("ghost src {s} link {d}", .{ name(gs), c.gst_pad_link(gs, ps) });
    out("pull activate {d} modes {s} {s} {s}", .{ c.gst_pad_activate_mode(ps, c.GST_PAD_MODE_PULL, 1), modeName(ps), modeName(gs), modeName(pt) });
    var b: [*c]c.GstBuffer = null;
    out("pull {d}", .{c.gst_pad_pull_range(ps, 4, 6, &b)});
    if (b != null) {
        out("  pulled {d}", .{c.gst_buffer_get_size(b)});
        c.gst_buffer_unref(b);
    }
    const sq = c.gst_query_new_scheduling();
    out("sched query via ghost {d} has pull {d}", .{ c.gst_pad_peer_query(ps, sq), c.gst_query_has_scheduling_mode(sq, c.GST_PAD_MODE_PULL) });
    c.gst_query_unref(sq);
    out("pull deactivate {d} modes {s} {s} {s}", .{ c.gst_pad_activate_mode(ps, c.GST_PAD_MODE_PULL, 0), modeName(ps), modeName(gs), modeName(pt) });

    var tmpl = c.GstStaticPadTemplate{ .name_template = "src_%u", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_REQUEST, .static_caps = .{ .caps = null, .string = "ANY" } };
    const templ = c.gst_static_pad_template_get(&tmpl);
    const gt = c.gst_ghost_pad_new_no_target_from_template("src_0", templ);
    out("from template {s} tmpl {d} internal tmpl {d}", .{ name(gt), @intFromBool(c.gst_pad_get_pad_template(gt) == templ), blk: {
        const ii: ?*c.GstPad = @ptrCast(c.gst_proxy_pad_get_internal(@ptrCast(gt)));
        defer c.gst_object_unref(ii);
        break :blk @intFromBool(c.gst_pad_get_pad_template(ii) == templ);
    } });
    const pt2 = c.gst_pad_new("pt2", c.GST_PAD_SRC);
    const gt2 = c.gst_ghost_pad_new_from_template("src_1", pt2, templ);
    out("from template target {s}", .{name(c.gst_ghost_pad_get_target(@ptrCast(gt2)))});
    out("construct {d}", .{c.gst_ghost_pad_construct(@ptrCast(gt2))});

    const tk = c.gst_pad_new("tk", c.GST_PAD_SINK);
    _ = c.gst_pad_unlink(s, g);
    _ = c.gst_pad_link(s, tk);
    out("new on linked null {d}", .{@intFromBool(c.gst_ghost_pad_new("bad", tk) == null)});
    out("new sink template mismatch null {d}", .{@intFromBool(c.gst_ghost_pad_new_from_template("bad", t, templ) == null)});
    out("unknown null {d}", .{@intFromBool(c.gst_ghost_pad_new_no_target("u", c.GST_PAD_UNKNOWN) == null)});
    out("not proxy null {d}", .{@intFromBool(c.gst_proxy_pad_get_internal(@ptrCast(t)) == null)});

    const bin = c.gst_bin_new("outer");
    const inner = c.gst_bin_new("inner");
    const e1 = c.gst_bin_new("e1");
    const e2 = c.gst_bin_new("e2");
    const p1 = c.gst_pad_new("out", c.GST_PAD_SRC);
    const p2 = c.gst_pad_new("in", c.GST_PAD_SINK);
    _ = c.gst_element_add_pad(e1, p1);
    _ = c.gst_element_add_pad(e2, p2);
    _ = c.gst_bin_add(@ptrCast(inner), e1);
    _ = c.gst_bin_add(@ptrCast(bin), inner);
    _ = c.gst_bin_add(@ptrCast(bin), e2);
    out("maybe ghosting {d} peer {s}", .{ c.gst_pad_link_maybe_ghosting(p1, p2), peerName(p2) });
    var it = c.gst_element_iterate_src_pads(inner);
    var v = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &v) == c.GST_ITERATOR_OK) {
        const gp: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&v)));
        out("  inner pad {s} ghost {d} target {s}", .{ name(gp), @intFromBool(c.g_type_check_instance_is_a(@ptrCast(@alignCast(gp)), c.gst_ghost_pad_get_type()) != 0), name(c.gst_ghost_pad_get_target(@ptrCast(gp))) });
        _ = c.g_value_reset(&v);
    }
    c.g_value_unset(&v);
    c.gst_iterator_free(it);
    it = null;

    c.gst_object_unref(gi);
    _ = c.gst_object_ref_sink(g);
    c.gst_object_unref(g);
    out("after dispose s peer {s}", .{peerName(s)});
    _ = c.gst_object_ref_sink(gs);
    c.gst_object_unref(gs);
    out("after dispose ps peer null {d} pt peer null {d}", .{ @intFromBool(c.gst_pad_get_peer(ps) == null), @intFromBool(c.gst_pad_get_peer(pt) == null) });
    c.gst_object_unref(bin);
    out("done", .{});
}
