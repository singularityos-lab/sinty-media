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

var src_t = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "ANY" } };
var sink_t = c.GstStaticPadTemplate{ .name_template = "sink", .direction = c.GST_PAD_SINK, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "ANY" } };

const Kind = enum(c_int) { source = 0, filter = 1, sink = 2 };

var base_change: ?*const fn ([*c]c.GstElement, c.GstStateChange) callconv(.c) c.GstStateChangeReturn = null;
var async_sink = false;

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    out("  {s} change {s}", .{ str(@as(*c.GstObject, @ptrCast(@alignCast(e))).name), str(c.gst_state_change_get_name(t)) });
    const r = base_change.?(e, t);
    const is_sink = @as(*c.GstObject, @ptrCast(@alignCast(e))).flags & c.GST_ELEMENT_FLAG_SINK != 0;
    if (async_sink and is_sink and t == c.GST_STATE_CHANGE_READY_TO_PAUSED) return c.GST_STATE_CHANGE_ASYNC;
    return r;
}

fn query(e: [*c]c.GstElement, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q.*.type == c.GST_QUERY_DURATION) {
        const n = str(@as(*c.GstObject, @ptrCast(@alignCast(e))).name);
        c.gst_query_set_duration(q, c.GST_FORMAT_TIME, @as(i64, @intCast(n.len)) * 1000);
        return 1;
    }
    return 0;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &src_t);
    c.gst_element_class_add_static_pad_template(ek, &sink_t);
    c.gst_element_class_set_static_metadata(ek, "T", "Generic", "t", "n");
    base_change = ek.change_state;
    ek.change_state = changeState;
    ek.query = query;
}

fn testType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_element_get_type(), "BinTestElem", @sizeOf(c.GstElementClass), classInit, @sizeOf(c.GstElement), null, 0);
    return S.t;
}

fn make(name: [*c]const u8, kind: Kind) [*c]c.GstElement {
    const e: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(testType(), "name", name, @as([*c]const u8, null))));
    if (kind != .source) _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&sink_t, "sink"));
    if (kind != .sink) _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&src_t, "src"));
    const o: *c.GstObject = @ptrCast(@alignCast(e));
    if (kind == .source) o.flags |= c.GST_ELEMENT_FLAG_SOURCE;
    if (kind == .sink) o.flags |= c.GST_ELEMENT_FLAG_SINK;
    return e;
}

fn onAdded(_: [*c]c.GstBin, e: [*c]c.GstElement, _: c.gpointer) callconv(.c) void {
    out("  element-added {s}", .{str(@as(*c.GstObject, @ptrCast(@alignCast(e))).name)});
}

fn onDeep(_: [*c]c.GstBin, sub: [*c]c.GstBin, e: [*c]c.GstElement, _: c.gpointer) callconv(.c) void {
    out("  deep-added {s} in {s}", .{ str(@as(*c.GstObject, @ptrCast(@alignCast(e))).name), str(@as(*c.GstObject, @ptrCast(@alignCast(sub))).name) });
}

fn onChild(_: ?*c.GstChildProxy, o: [*c]c.GObject, name: [*c]const u8, _: c.gpointer) callconv(.c) void {
    _ = o;
    out("  child-added {s}", .{str(name)});
}

fn drain(bus: [*c]c.GstBus) void {
    while (true) {
        const m = c.gst_bus_pop(bus);
        if (m == null) break;
        const src = if (m.*.src != null) str(m.*.src.*.name) else "-";
        if (m.*.type == c.GST_MESSAGE_STATE_CHANGED) {
            var o: c.GstState = 0;
            var n: c.GstState = 0;
            var p: c.GstState = 0;
            c.gst_message_parse_state_changed(m, &o, &n, &p);
            out("  msg {s} state-changed {s}->{s} ({s})", .{ src, str(c.gst_state_get_name(o)), str(c.gst_state_get_name(n)), str(c.gst_state_get_name(p)) });
        } else out("  msg {s} {s}", .{ src, str(c.gst_message_type_get_name(m.*.type)) });
        c.gst_mini_object_unref(@ptrCast(m));
    }
}

fn names(it: [*c]c.GstIterator) void {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var v = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &v) == c.GST_ITERATOR_OK) {
        const nm = str(@as(*c.GstObject, @ptrCast(@alignCast(c.g_value_get_object(&v)))).name);
        @memcpy(buf[n .. n + nm.len], nm);
        n += nm.len;
        buf[n] = ' ';
        n += 1;
        _ = c.g_value_reset(&v);
    }
    c.g_value_unset(&v);
    c.gst_iterator_free(it);
    out("  [{s}]", .{buf[0..n]});
}

pub fn main() void {
    c.gst_init(null, null);
    var q: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_bin_get_type(), &q);
    out("sizes bin {d} {d} iface {d}", .{ q.instance_size, q.class_size, c.g_type_is_a(c.gst_bin_get_type(), c.gst_child_proxy_get_type()) });
    const bin: [*c]c.GstBin = @ptrCast(@alignCast(c.g_object_new(c.gst_bin_get_type(), "name", "top", @as([*c]const u8, null))));
    _ = c.gst_object_ref_sink(bin);
    const klass = @as(*c.GstElementClass, @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(bin))).g_class)));
    out("meta {s} / {s}", .{ str(c.gst_element_class_get_metadata(klass, "long-name")), str(c.gst_element_class_get_metadata(klass, "author")) });
    _ = c.g_signal_connect_data(bin, "element-added", @ptrCast(&onAdded), null, null, 0);
    _ = c.g_signal_connect_data(bin, "deep-element-added", @ptrCast(&onDeep), null, null, 0);
    _ = c.g_signal_connect_data(bin, "child-added", @ptrCast(&onChild), null, null, 0);
    const bus = c.gst_bus_new();
    c.gst_element_set_bus(@ptrCast(bin), bus);
    const s = make("source", .source);
    const f = make("filter", .filter);
    const k = make("sink", .sink);
    c.gst_bin_add_many(bin, s, f, k, @as([*c]c.GstElement, null));
    out("children {d} flags 0x{x} dup {d}", .{ bin.*.numchildren, @as(*c.GstObject, @ptrCast(@alignCast(bin))).flags, c.gst_bin_add(bin, make("sink", .sink)) });
    out("link {d} {d}", .{ c.gst_element_link(s, f), c.gst_element_link(f, k) });
    names(c.gst_bin_iterate_sorted(bin));
    names(c.gst_bin_iterate_elements(bin));
    names(c.gst_bin_iterate_sinks(bin));
    names(c.gst_bin_iterate_sources(bin));
    const sub: [*c]c.GstBin = @ptrCast(@alignCast(c.g_object_new(c.gst_bin_get_type(), "name", "sub", @as([*c]const u8, null))));
    _ = c.gst_bin_add(sub, make("inner", .filter));
    _ = c.gst_bin_add(bin, @ptrCast(sub));
    names(c.gst_bin_iterate_recurse(bin));
    const byname = c.gst_bin_get_by_name(bin, "inner");
    out("by name {s} up {d} missing {d}", .{ str(@as(*c.GstObject, @ptrCast(@alignCast(byname))).name), @intFromBool(c.gst_bin_get_by_name_recurse_up(sub, "filter") == f), @intFromBool(c.gst_bin_get_by_name(bin, "nope") == null) });
    var nm: [*c]u8 = null;
    c.gst_child_proxy_get(@ptrCast(bin), "sub::inner::name", &nm, @as([*c]const u8, null));
    out("proxy get {s} count {d}", .{ str(nm), c.gst_child_proxy_get_children_count(@ptrCast(bin)) });
    c.gst_child_proxy_set(@ptrCast(bin), "message-forward", @as(c.gboolean, 0), @as([*c]const u8, null));
    c.gst_child_proxy_set(@ptrCast(bin), "nope::x", @as(c.gint, 1), @as([*c]const u8, null));
    drain(bus);
    out("ready {d}", .{c.gst_element_set_state(@ptrCast(bin), c.GST_STATE_READY)});
    drain(bus);
    out("playing {d}", .{c.gst_element_set_state(@ptrCast(bin), c.GST_STATE_PLAYING)});
    drain(bus);
    var dur: i64 = 0;
    out("duration {d} {d}", .{ c.gst_element_query_duration(@ptrCast(bin), c.GST_FORMAT_TIME, &dur), dur });
    _ = c.gst_element_post_message(k, c.gst_message_new_eos(@ptrCast(k)));
    drain(bus);
    out("null {d}", .{c.gst_element_set_state(@ptrCast(bin), c.GST_STATE_NULL)});
    drain(bus);
    async_sink = true;
    out("async paused {d}", .{c.gst_element_set_state(@ptrCast(bin), c.GST_STATE_PAUSED)});
    drain(bus);
    var st: c.GstState = 0;
    var pe: c.GstState = 0;
    out("get {d} {s} {s}", .{ c.gst_element_get_state(@ptrCast(bin), &st, &pe, 0), str(c.gst_state_get_name(st)), str(c.gst_state_get_name(pe)) });
    _ = c.gst_element_post_message(k, c.gst_message_new_async_start(@ptrCast(k)));
    _ = c.gst_element_continue_state(k, c.GST_STATE_CHANGE_SUCCESS);
    _ = c.gst_element_post_message(k, c.gst_message_new_async_done(@ptrCast(k), c.GST_CLOCK_TIME_NONE));
    out("get after {d} {s} {s}", .{ c.gst_element_get_state(@ptrCast(bin), &st, &pe, c.GST_SECOND), str(c.gst_state_get_name(st)), str(c.gst_state_get_name(pe)) });
    drain(bus);
    async_sink = false;
    out("null again {d}", .{c.gst_element_set_state(@ptrCast(bin), c.GST_STATE_NULL)});
    drain(bus);
    _ = c.gst_object_ref(k);
    out("remove {d} again {d} children {d} flags 0x{x}", .{ c.gst_bin_remove(bin, k), c.gst_bin_remove(bin, k), bin.*.numchildren, @as(*c.GstObject, @ptrCast(@alignCast(bin))).flags });
    c.gst_object_unref(k);
    c.gst_bin_set_suppressed_flags(bin, c.GST_ELEMENT_FLAG_SOURCE);
    out("suppressed {d}", .{c.gst_bin_get_suppressed_flags(bin)});
    drain(bus);
    c.gst_object_unref(bin);
    out("done", .{});
}
