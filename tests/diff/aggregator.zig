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

const NONE = std.math.maxInt(u64);
const MS: u64 = 1_000_000;

fn t(v: u64) i64 {
    return if (v == NONE) -1 else @intCast(v);
}

var log_lock = std.mem.zeroes(c.GMutex);
var log_buf: [65536]u8 = undefined;
var log_len: usize = 0;

fn note(comptime fmt: []const u8, args: anytype) void {
    c.g_mutex_lock(&log_lock);
    defer c.g_mutex_unlock(&log_lock);
    const s = std.fmt.bufPrint(log_buf[log_len..], fmt ++ "\n", args) catch return;
    log_len += s.len;
}

fn flushLog() void {
    c.g_mutex_lock(&log_lock);
    defer c.g_mutex_unlock(&log_lock);
    _ = std.c.write(1, &log_buf, log_len);
    log_len = 0;
}

fn obj(p: anytype) [*c]c.GObject {
    return @ptrCast(@alignCast(p));
}

fn srcCreate(s: [*c]c.GstPushSrc, out_buf: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const n: usize = @intFromPtr(c.g_object_get_data(obj(s), "n"));
    const total: usize = @intFromPtr(c.g_object_get_data(obj(s), "total"));
    const step: usize = @intFromPtr(c.g_object_get_data(obj(s), "step"));
    if (n >= total) return c.GST_FLOW_EOS;
    const b = c.gst_buffer_new_allocate(null, 4 + n, null);
    _ = c.gst_buffer_memset(b, 0, @truncate(n + step), 4 + n);
    b[0].pts = n * step * MS;
    b[0].duration = step * MS;
    c.g_object_set_data(obj(s), "n", @ptrFromInt(n + 1));
    out_buf.* = b;
    return c.GST_FLOW_OK;
}

fn srcClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string("x-test/a");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Src", "Source", "s", "x");
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).create = srcCreate;
}

fn srcInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_src_set_format(@ptrCast(@alignCast(instance)), c.GST_FORMAT_TIME);
}

fn srcType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_push_src_get_type(), "TASrc", @sizeOf(c.GstPushSrcClass), srcClass, @sizeOf(c.GstPushSrc), srcInit, 0);
    return S.v;
}

fn sinkRender(_: [*c]c.GstBaseSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    note("  sink got pts={d} dur={d} size={d}", .{ t(b[0].pts), t(b[0].duration), c.gst_buffer_get_size(b) });
    return c.GST_FLOW_OK;
}

fn sinkEvent(s: [*c]c.GstBaseSink, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    note("  sink event {s}", .{str(c.gst_event_type_get_name(ev[0].type))});
    if (ev[0].type == c.GST_EVENT_CAPS) {
        var caps: [*c]c.GstCaps = null;
        c.gst_event_parse_caps(ev, &caps);
        const cs = c.gst_caps_to_string(caps);
        note("    caps {s}", .{str(cs)});
        c.g_free(cs);
    }
    if (ev[0].type == c.GST_EVENT_SEGMENT) {
        var seg: [*c]const c.GstSegment = null;
        c.gst_event_parse_segment(ev, &seg);
        note("    segment fmt={d} start={d} pos={d} rate={d}", .{ seg[0].format, t(seg[0].start), t(seg[0].position), seg[0].rate });
    }
    if (ev[0].type == c.GST_EVENT_STREAM_START) {
        var id: [*c]const u8 = null;
        c.gst_event_parse_stream_start(ev, &id);
        note("    stream id len={d} prefix={s}", .{ std.mem.len(id), str(id)[0..@min(4, std.mem.len(id))] });
    }
    return sink_parent.?.event.?(s, ev);
}

var sink_parent: ?*c.GstBaseSinkClass = null;

fn sinkClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    sink_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const caps = c.gst_caps_from_string("ANY");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Sink", "Sink", "k", "x");
    @as(*c.GstBaseSinkClass, @ptrCast(@alignCast(k))).render = sinkRender;
    @as(*c.GstBaseSinkClass, @ptrCast(@alignCast(k))).event = sinkEvent;
}

fn sinkType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_sink_get_type(), "TASink", @sizeOf(c.GstBaseSinkClass), sinkClass, @sizeOf(c.GstBaseSink), null, 0);
    return S.v;
}

fn padName(p: anytype) []const u8 {
    return str(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

fn aggAggregate(a: [*c]c.GstAggregator, timeout: c.gboolean) callconv(.c) c.GstFlowReturn {
    const e: *c.GstElement = @ptrCast(@alignCast(a));
    var all_eos = true;
    var min: u64 = NONE;
    var size: usize = 0;
    var l: ?*c.GList = e.sinkpads;
    while (l) |n| : (l = n.next) {
        const p: ?*c.GstAggregatorPad = @ptrCast(@alignCast(n.data));
        const peek = c.gst_aggregator_pad_peek_buffer(p);
        const has = c.gst_aggregator_pad_has_buffer(p);
        const eos = c.gst_aggregator_pad_is_eos(p);
        var level: u64 = 0;
        c.g_object_get(n.data, "current-level-buffers", &level, @as(?*anyopaque, null));
        note("  aggregate timeout={d} pad {s} has={d} eos={d} level={d} peek={d}", .{ timeout, padName(n.data), has, eos, level, if (peek != null) t(peek[0].pts) else -2 });
        if (peek != null) c.gst_buffer_unref(peek);
        const b = c.gst_aggregator_pad_pop_buffer(p);
        if (b != null) {
            all_eos = false;
            if (b[0].pts < min) min = b[0].pts;
            size += c.gst_buffer_get_size(b);
            c.gst_buffer_unref(b);
        } else if (eos == 0) all_eos = false;
    }
    if (all_eos) {
        note("  aggregate all eos", .{});
        return c.GST_FLOW_EOS;
    }
    c.gst_aggregator_selected_samples(a, min, NONE, 10 * MS, null);
    const o = c.gst_buffer_new_allocate(null, size, null);
    o[0].pts = min;
    o[0].duration = 10 * MS;
    var tq: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_pad_get_type(), &tq);
    const seg: *c.GstSegment = @ptrCast(@alignCast(@as([*]u8, @ptrCast(a[0].srcpad)) + tq.instance_size));
    seg.position = min +% 10 * MS;
    const r = c.gst_aggregator_finish_buffer(a, o);
    note("  finish -> {s}", .{str(c.gst_flow_get_name(r))});
    return r;
}

fn aggStart(_: [*c]c.GstAggregator) callconv(.c) c.gboolean {
    note("  agg start", .{});
    return 1;
}

fn aggStop(_: [*c]c.GstAggregator) callconv(.c) c.gboolean {
    note("  agg stop", .{});
    return 1;
}

fn aggNegotiated(_: [*c]c.GstAggregator, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const cs = c.gst_caps_to_string(caps);
    note("  negotiated {s}", .{str(cs)});
    c.g_free(cs);
    return 1;
}

fn aggClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    var caps = c.gst_caps_from_string("x-test/a");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new_with_gtype("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps, c.gst_aggregator_pad_get_type()));
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new_with_gtype("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, caps, c.gst_aggregator_pad_get_type()));
    c.gst_caps_unref(caps);
    caps = c.gst_caps_from_string("x-test/a");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("fixed", c.GST_PAD_SINK, c.GST_PAD_REQUEST, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Agg", "Muxer", "a", "x");
    const bc: *c.GstAggregatorClass = @ptrCast(@alignCast(k));
    bc.aggregate = aggAggregate;
    bc.start = aggStart;
    bc.stop = aggStop;
    bc.negotiated_src_caps = aggNegotiated;
    bc.get_next_time = c.gst_aggregator_simple_get_next_time;
}

fn aggType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_aggregator_get_type(), "TAAgg", @sizeOf(c.GstAggregatorClass), aggClass, @sizeOf(c.GstAggregator), null, 0);
    return S.v;
}

fn onSamples(_: ?*anyopaque, seg: [*c]c.GstSegment, pts: u64, dts: u64, dur: u64, info: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    note("  samples-selected seg fmt={d} pts={d} dts={d} dur={d} info={d}", .{ seg[0].format, t(pts), t(dts), t(dur), @intFromBool(info == null) });
}

fn onConsumed(p: ?*anyopaque, b: [*c]c.GstBuffer, _: ?*anyopaque) callconv(.c) void {
    note("  buffer-consumed {s} pts={d}", .{ padName(p), t(b[0].pts) });
}

fn messages(bus: ?*c.GstBus) void {
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 3 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING) orelse {
            out("  bus timeout", .{});
            return;
        };
        defer c.gst_message_unref(m);
        if (m[0].type == c.GST_MESSAGE_EOS) {
            out("  msg eos", .{});
            return;
        }
        var e: [*c]c.GError = null;
        var dbg: [*c]u8 = null;
        if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
        out("  msg {s}: {s} | {s}", .{ str(c.gst_message_type_get_name(m[0].type)), str(e[0].message), str(dbg) });
        c.g_clear_error(&e);
        c.g_free(dbg);
        if (m[0].type == c.GST_MESSAGE_ERROR) return;
    }
}

fn mkSrc(name: [*c]const u8, total: usize, step: usize) [*c]c.GstElement {
    const s: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(srcType(), "name", name, @as(?*anyopaque, null))));
    c.g_object_set_data(obj(s), "total", @ptrFromInt(total));
    c.g_object_set_data(obj(s), "step", @ptrFromInt(step));
    return s;
}

fn run(label: []const u8, totals: []const usize, signals: bool) void {
    out("== {s}", .{label});
    const p = c.gst_pipeline_new("p");
    const agg: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(aggType(), "name", "agg", "emit-signals", @as(c.gboolean, @intFromBool(signals)), @as(?*anyopaque, null))));
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "sink", "sync", @as(c.gboolean, 0), @as(?*anyopaque, null))));
    _ = c.gst_bin_add(@ptrCast(p), agg);
    _ = c.gst_bin_add(@ptrCast(p), sink);
    if (signals) _ = c.g_signal_connect_data(agg, "samples-selected", @ptrCast(&onSamples), null, null, 0);
    for (totals, 0..) |n, i| {
        var nm: [8]u8 = undefined;
        const s = mkSrc((std.fmt.bufPrintZ(&nm, "s{d}", .{i}) catch unreachable).ptr, n, 10);
        _ = c.gst_bin_add(@ptrCast(p), s);
        const sp = c.gst_element_get_static_pad(s, "src");
        const kp = c.gst_element_request_pad_simple(agg, "sink_%u");
        out("  requested {s} link {d}", .{ padName(kp), c.gst_pad_link(sp, kp) });
        if (signals and i == 0) {
            c.g_object_set(kp, "emit-signals", @as(c.gboolean, 1), @as(?*anyopaque, null));
            _ = c.g_signal_connect_data(kp, "buffer-consumed", @ptrCast(&onConsumed), null, null, 0);
        }
        c.gst_object_unref(sp);
        c.gst_object_unref(kp);
    }
    out("  link {d}", .{c.gst_element_link(agg, sink)});
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    messages(bus);
    flushLog();
    const a: [*c]c.GstAggregator = @ptrCast(@alignCast(agg));
    out("  latency {d}", .{t(c.gst_aggregator_get_latency(a))});
    const q = c.gst_query_new_latency();
    const sp = c.gst_element_get_static_pad(agg, "src");
    const ok = c.gst_pad_query(sp, q);
    var live: c.gboolean = 0;
    var min: u64 = 0;
    var max: u64 = 0;
    c.gst_query_parse_latency(q, &live, &min, &max);
    out("  latency query {d} live={d} min={d} max={d}", .{ ok, live, t(min), t(max) });
    c.gst_query_unref(q);
    var pos: i64 = 0;
    out("  src position {d} {d}", .{ c.gst_pad_query_position(sp, c.GST_FORMAT_TIME, &pos), pos });
    const sq = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
    var seekable: c.gboolean = 7;
    out("  seeking {d}", .{c.gst_pad_query(sp, sq)});
    c.gst_query_parse_seeking(sq, null, &seekable, null, null);
    out("  seekable {d}", .{seekable});
    c.gst_query_unref(sq);
    c.gst_object_unref(sp);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus);
    c.gst_object_unref(p);
}

fn request(agg: [*c]c.GstElement, templ: [*c]const u8, name: [*c]const u8) void {
    const k: *c.GstElementClass = @ptrCast(@alignCast(@as([*c]c.GTypeInstance, @ptrCast(agg))[0].g_class));
    const tp = c.gst_element_class_get_pad_template(k, templ);
    const p = c.gst_element_request_pad(agg, tp, name, null);
    if (p == null) {
        out("  request {s} {s} -> (null)", .{ str(templ), str(name) });
        return;
    }
    out("  request {s} {s} -> {s} type {s}", .{ str(templ), str(name), padName(p), str(c.g_type_name(@as([*c]c.GTypeInstance, @ptrCast(@alignCast(p)))[0].g_class[0].g_type)) });
    c.gst_object_unref(p);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    const at = c.gst_aggregator_get_type();
    out("type {s} abstract {d} parent {s}", .{ str(c.g_type_name(at)), c.g_type_test_flags(at, c.G_TYPE_FLAG_ABSTRACT), str(c.g_type_name(c.g_type_parent(at))) });
    const pt = c.gst_aggregator_pad_get_type();
    out("pad type {s} abstract {d} parent {s}", .{ str(c.g_type_name(pt)), c.g_type_test_flags(pt, c.G_TYPE_FLAG_ABSTRACT), str(c.g_type_name(c.g_type_parent(pt))) });
    const et = c.gst_aggregator_start_time_selection_get_type();
    const ek: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(et)));
    out("enum {s} n={d}", .{ str(c.g_type_name(et)), ek.n_values });
    for (0..ek.n_values) |i| out("  {d} {s} {s}", .{ ek.values[i].value, str(ek.values[i].value_name), str(ek.values[i].value_nick) });
    c.g_type_class_unref(ek);

    const agg: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(aggType(), "name", "props", @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(agg);
    var n_props: c.guint = 0;
    const specs = c.g_object_class_list_properties(@ptrCast(@alignCast(@as([*c]c.GTypeInstance, @ptrCast(agg))[0].g_class)), &n_props);
    for (0..n_props) |i| {
        const s = specs[i];
        if (s[0].owner_type != at) continue;
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, s[0].value_type);
        c.g_object_get_property(obj(agg), s[0].name, &v);
        const cs = c.g_strdup_value_contents(&v);
        out("  prop {s} flags={x} default={s} blurb={s}", .{ str(s[0].name), s[0].flags, str(cs), str(c.g_param_spec_get_blurb(s)) });
        c.g_free(cs);
        c.g_value_unset(&v);
    }
    c.g_free(@ptrCast(specs));
    c.g_object_set(agg, "latency", @as(u64, 5 * MS), "min-upstream-latency", @as(u64, 2 * MS), "start-time-selection", @as(c.gint, 2), "start-time", @as(u64, 7 * MS), @as(?*anyopaque, null));
    var lat: u64 = 0;
    var mul: u64 = 0;
    var sts: c.gint = 0;
    var st: u64 = 0;
    c.g_object_get(agg, "latency", &lat, "min-upstream-latency", &mul, "start-time-selection", &sts, "start-time", &st, @as(?*anyopaque, null));
    out("  set latency={d} mul={d} sts={d} st={d}", .{ lat, mul, sts, st });
    const a: [*c]c.GstAggregator = @ptrCast(@alignCast(agg));
    out("  ignore inactive {d} force live {d}", .{ c.gst_aggregator_get_ignore_inactive_pads(a), c.gst_aggregator_get_force_live(a) });
    c.gst_aggregator_set_ignore_inactive_pads(a, 1);
    c.gst_aggregator_set_force_live(a, 1);
    out("  ignore inactive {d} force live {d}", .{ c.gst_aggregator_get_ignore_inactive_pads(a), c.gst_aggregator_get_force_live(a) });
    out("  pool null {d}", .{@intFromBool(c.gst_aggregator_get_buffer_pool(a) == null)});
    var alloc: ?*c.GstAllocator = @ptrFromInt(8);
    var params: c.GstAllocationParams = undefined;
    c.gst_aggregator_get_allocator(a, &alloc, &params);
    out("  allocator null {d} align {d} prefix {d}", .{ @intFromBool(alloc == null), params.@"align", params.prefix });
    out("  next time {d}", .{t(c.gst_aggregator_simple_get_next_time(a))});
    const srcpad: *c.GstObject = @ptrCast(@alignCast(a[0].srcpad));
    out("  srcpad {s} type {s}", .{ str(srcpad.name), str(c.g_type_name(@as([*c]c.GTypeInstance, @ptrCast(@alignCast(a[0].srcpad)))[0].g_class[0].g_type)) });
    request(agg, "sink_%u", null);
    request(agg, "sink_%u", null);
    request(agg, "sink_%u", "sink_7");
    request(agg, "sink_%u", null);
    request(agg, "sink_%u", "sink_x");
    request(agg, "sink_%u", "other_1");
    request(agg, "fixed", null);
    request(agg, "fixed", "custom");
    const kp = c.gst_element_get_static_pad(agg, "sink_0");
    var lvl_t: u64 = 9;
    var lvl_b: u64 = 9;
    var lvl_y: u64 = 9;
    var es: c.gboolean = 9;
    c.g_object_get(kp, "current-level-time", &lvl_t, "current-level-buffers", &lvl_b, "current-level-bytes", &lvl_y, "emit-signals", &es, @as(?*anyopaque, null));
    out("  pad levels {d} {d} {d} emit {d}", .{ lvl_t, lvl_b, lvl_y, es });
    const ap: ?*c.GstAggregatorPad = @ptrCast(@alignCast(kp));
    out("  pad eos {d} inactive {d} has {d} peek null {d} drop {d}", .{ c.gst_aggregator_pad_is_eos(ap), c.gst_aggregator_pad_is_inactive(ap), c.gst_aggregator_pad_has_buffer(ap), @intFromBool(c.gst_aggregator_pad_peek_buffer(ap) == null), c.gst_aggregator_pad_drop_buffer(ap) });
    c.gst_element_release_request_pad(agg, kp);
    c.gst_object_unref(kp);
    out("  pads after release {d}", .{@as(*c.GstElement, @ptrCast(@alignCast(agg))).numsinkpads});
    c.gst_aggregator_set_latency(a, 3 * MS, 4 * MS);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = 20 * MS;
    c.gst_aggregator_update_segment(a, &seg);
    out("  next time after segment {d}", .{t(c.gst_aggregator_simple_get_next_time(a))});
    c.gst_object_unref(agg);

    run("two pads", &.{ 3, 5 }, false);
    run("three pads signals", &.{ 2, 2, 4 }, true);
    run("single pad", &.{4}, false);

    out("crit negotiate {d}", .{c.gst_aggregator_negotiate(null)});
    out("done", .{});
}
