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
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_push_src_get_type(), "TCSrc", @sizeOf(c.GstPushSrcClass), srcClass, @sizeOf(c.GstPushSrc), srcInit, 0);
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
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_sink_get_type(), "TCSink", @sizeOf(c.GstBaseSinkClass), sinkClass, @sizeOf(c.GstBaseSink), null, 0);
    return S.v;
}

fn padName(p: anytype) []const u8 {
    return str(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

const Mux = extern struct {
    parent: c.GstElement,
    srcpad: ?*c.GstPad,
    collect: [*c]c.GstCollectPads,
    started: c.gboolean,
};

var bytes_mode = false;

fn pushHeaders(m: *Mux) void {
    if (m.started != 0) return;
    m.started = 1;
    _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_stream_start("cp"));
    const caps = c.gst_caps_from_string("x-test/a");
    _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_caps(caps));
    c.gst_caps_unref(caps);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_segment(&seg));
}

fn bufferFn(_: [*c]c.GstCollectPads, d: [*c]c.GstCollectData, b: [*c]c.GstBuffer, user: c.gpointer) callconv(.c) c.GstFlowReturn {
    const m: *Mux = @ptrCast(@alignCast(user));
    pushHeaders(m);
    if (b == null) {
        note("  buffer fn eos data null {d}", .{@intFromBool(d == null)});
        _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_eos());
        return c.GST_FLOW_EOS;
    }
    note("  buffer fn {s} pts={d} dts={d} cdts={d} pos={d} state={x}", .{ padName(d[0].pad), t(b[0].pts), t(b[0].dts), d[0].ABI.abi.dts, t(d[0].segment.position), d[0].state });
    return c.gst_pad_push(m.srcpad, b);
}

fn collected(p: [*c]c.GstCollectPads, user: c.gpointer) callconv(.c) c.GstFlowReturn {
    const m: *Mux = @ptrCast(@alignCast(user));
    pushHeaders(m);
    const avail = c.gst_collect_pads_available(p);
    note("  collected available={d}", .{avail});
    var all_eos = true;
    var l = p[0].data;
    while (l != null) : (l = l[0].next) {
        const d: [*c]c.GstCollectData = @ptrCast(@alignCast(l[0].data));
        if (d[0].state & c.GST_COLLECT_PADS_STATE_EOS == 0) all_eos = false;
        const pk = c.gst_collect_pads_peek(p, d);
        const rb = c.gst_collect_pads_read_buffer(p, d, 2);
        note("    {s} state={x} peek={d} read={d} pos={d}", .{ padName(d[0].pad), d[0].state, if (pk != null) @as(i64, @intCast(c.gst_buffer_get_size(pk))) else -1, if (rb != null) @as(i64, @intCast(c.gst_buffer_get_size(rb))) else -1, d[0].pos });
        if (pk != null) c.gst_buffer_unref(pk);
        if (rb != null) c.gst_buffer_unref(rb);
        if (avail > 0) {
            const tb = c.gst_collect_pads_take_buffer(p, d, 1);
            note("    take={d} pos={d}", .{ if (tb != null) @as(i64, @intCast(c.gst_buffer_get_size(tb))) else -1, d[0].pos });
            if (tb != null) c.gst_buffer_unref(tb);
            note("    flush={d} pos={d}", .{ c.gst_collect_pads_flush(p, d, 2), d[0].pos });
            const rest = c.gst_collect_pads_pop(p, d);
            note("    pop={d}", .{if (rest != null) @as(i64, @intCast(c.gst_buffer_get_size(rest))) else -1});
            if (rest != null) c.gst_buffer_unref(rest);
        }
    }
    if (all_eos) {
        note("  collected all eos", .{});
        _ = c.gst_pad_push_event(m.srcpad, c.gst_event_new_eos());
        return c.GST_FLOW_EOS;
    }
    return c.GST_FLOW_OK;
}

var mux_parent: ?*c.GstElementClass = null;

fn muxRequest(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, _: [*c]const u8, _: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const m: *Mux = @ptrCast(@alignCast(e));
    var nm: [16]u8 = undefined;
    const name = std.fmt.bufPrintZ(&nm, "sink_{d}", .{e[0].numsinkpads}) catch unreachable;
    const pad = c.gst_pad_new_from_template(templ, name.ptr);
    const d = c.gst_collect_pads_add_pad(m.collect, pad, @sizeOf(c.GstCollectData), null, 1);
    note("  add pad {s} state={x} dts={d} fmt={d}", .{ padName(pad), d[0].state, d[0].ABI.abi.dts, d[0].segment.format });
    _ = c.gst_element_add_pad(e, pad);
    return pad;
}

fn muxRelease(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const m: *Mux = @ptrCast(@alignCast(e));
    note("  remove {d}", .{c.gst_collect_pads_remove_pad(m.collect, pad)});
    _ = c.gst_element_remove_pad(e, pad);
}

fn muxChange(e: [*c]c.GstElement, tr: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const m: *Mux = @ptrCast(@alignCast(e));
    if (tr == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        m.started = 0;
        c.gst_collect_pads_start(m.collect);
    }
    if (tr == c.GST_STATE_CHANGE_PAUSED_TO_READY) c.gst_collect_pads_stop(m.collect);
    return mux_parent.?.change_state.?(e, tr);
}

fn muxSrcEvent(pad: ?*c.GstPad, _: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const m: *Mux = @ptrCast(@alignCast(@as(*c.GstObject, @ptrCast(@alignCast(pad))).parent));
    return c.gst_collect_pads_src_event_default(m.collect, pad, ev);
}

fn muxFinalize(o: [*c]c.GObject) callconv(.c) void {
    const m: *Mux = @ptrCast(@alignCast(o));
    c.gst_object_unref(m.collect);
    @as(*c.GObjectClass, @ptrCast(mux_parent.?)).finalize.?(o);
}

fn muxClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    mux_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const caps = c.gst_caps_from_string("x-test/a");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Mux", "Muxer", "m", "x");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.request_new_pad = muxRequest;
    ec.release_pad = muxRelease;
    ec.change_state = muxChange;
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = muxFinalize;
}

fn muxInit(instance: [*c]c.GTypeInstance, k: c.gpointer) callconv(.c) void {
    const m: *Mux = @ptrCast(@alignCast(instance));
    m.srcpad = c.gst_pad_new_from_template(c.gst_element_class_get_pad_template(@ptrCast(@alignCast(k)), "src"), "src");
    c.gst_pad_set_event_function_full(m.srcpad, muxSrcEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(m), m.srcpad);
    m.collect = c.gst_collect_pads_new();
    if (bytes_mode) {
        c.gst_collect_pads_set_function(m.collect, collected, m);
    } else {
        c.gst_collect_pads_set_buffer_function(m.collect, bufferFn, m);
        c.gst_collect_pads_set_clip_function(m.collect, c.gst_collect_pads_clip_running_time, m);
    }
}

fn muxType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_element_get_type(), "TCMux", @sizeOf(c.GstElementClass), muxClass, @sizeOf(Mux), muxInit, 0);
    return S.v;
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

fn run(label: []const u8, totals: []const usize, steps: []const usize, bytes: bool) void {
    out("== {s}", .{label});
    bytes_mode = bytes;
    const p = c.gst_pipeline_new("p");
    const mux: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(muxType(), "name", "mux", @as(?*anyopaque, null))));
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "sink", "sync", @as(c.gboolean, 0), @as(?*anyopaque, null))));
    _ = c.gst_bin_add(@ptrCast(p), mux);
    _ = c.gst_bin_add(@ptrCast(p), sink);
    for (totals, 0..) |n, i| {
        var nm: [8]u8 = undefined;
        const s = mkSrc((std.fmt.bufPrintZ(&nm, "s{d}", .{i}) catch unreachable).ptr, n, steps[i]);
        _ = c.gst_bin_add(@ptrCast(p), s);
        const sp = c.gst_element_get_static_pad(s, "src");
        const kp = c.gst_element_request_pad_simple(mux, "sink_%u");
        flushLog();
        out("  requested {s} link {d}", .{ padName(kp), c.gst_pad_link(sp, kp) });
        c.gst_object_unref(sp);
        c.gst_object_unref(kp);
    }
    out("  link {d}", .{c.gst_element_link(mux, sink)});
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    messages(bus);
    flushLog();
    const kp = c.gst_element_get_static_pad(mux, "sink_0");
    const q = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
    var seekable: c.gboolean = 7;
    out("  sink seeking {d}", .{c.gst_pad_query(kp, q)});
    c.gst_query_parse_seeking(q, null, &seekable, null, null);
    out("  seekable {d}", .{seekable});
    c.gst_query_unref(q);
    c.gst_object_unref(kp);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus);
    c.gst_object_unref(p);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    const ct = c.gst_collect_pads_get_type();
    out("type {s} parent {s} abstract {d}", .{ str(c.g_type_name(ct)), str(c.g_type_name(c.g_type_parent(ct))), c.g_type_test_flags(ct, c.G_TYPE_FLAG_ABSTRACT) });
    const cp = c.gst_collect_pads_new();
    out("  floating {d} refcount {d} available {d}", .{ c.g_object_is_floating(cp), @as(*c.GObject, @ptrCast(@alignCast(cp))).ref_count, c.gst_collect_pads_available(cp) });
    const tmpl = c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, c.gst_caps_new_any());
    const pad = c.gst_pad_new_from_template(tmpl, "manual");
    _ = c.gst_object_ref_sink(pad);
    const d = c.gst_collect_pads_add_pad(cp, pad, @sizeOf(c.GstCollectData) + 16, null, 0);
    out("  data state={x} pos={d} collect ok {d} priv {d}", .{ d[0].state, d[0].pos, @intFromBool(d[0].collect == cp), @intFromBool(c.gst_pad_get_element_private(pad) == @as(c.gpointer, @ptrCast(d))) });
    out("  pad active {d}", .{c.gst_pad_is_active(pad)});
    c.gst_collect_pads_set_waiting(cp, d, 0);
    out("  waiting off state={x}", .{d[0].state});
    c.gst_collect_pads_set_waiting(cp, d, 1);
    out("  waiting on state={x}", .{d[0].state});
    out("  peek null {d} pop null {d} flush {d} read null {d} take null {d}", .{ @intFromBool(c.gst_collect_pads_peek(cp, d) == null), @intFromBool(c.gst_collect_pads_pop(cp, d) == null), c.gst_collect_pads_flush(cp, d, 4), @intFromBool(c.gst_collect_pads_read_buffer(cp, d, 4) == null), @intFromBool(c.gst_collect_pads_take_buffer(cp, d, 4) == null) });
    out("  chain before start {s}", .{str(c.gst_flow_get_name(c.gst_pad_chain(pad, c.gst_buffer_new())))});
    c.gst_collect_pads_set_flushing(cp, 1);
    out("  flushing state={x} padflag={d}", .{ d[0].state, @intFromBool(@as(*c.GstObject, @ptrCast(@alignCast(pad))).flags & c.GST_PAD_FLAG_FLUSHING != 0) });
    c.gst_collect_pads_set_flushing(cp, 0);
    out("  unflushed state={x}", .{d[0].state});
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = 100 * MS;
    d[0].segment = seg;
    const b = c.gst_buffer_new();
    b[0].pts = 150 * MS;
    b[0].dts = 50 * MS;
    var o: [*c]c.GstBuffer = null;
    _ = c.gst_collect_pads_clip_running_time(cp, d, b, &o, null);
    out("  clip pts={d} dts={d} cdts={d}", .{ t(o[0].pts), t(o[0].dts), d[0].ABI.abi.dts });
    c.gst_buffer_unref(o);
    const b2 = c.gst_buffer_new();
    b2[0].pts = 20 * MS;
    o = null;
    _ = c.gst_collect_pads_clip_running_time(cp, d, b2, &o, null);
    out("  clip before start null {d}", .{@intFromBool(o == null)});
    const b3 = c.gst_buffer_new();
    b3[0].pts = 120 * MS;
    b3[0].dts = 120 * MS;
    o = null;
    _ = c.gst_collect_pads_clip_running_time(cp, d, b3, &o, null);
    out("  clip dts pos pts={d} dts={d} cdts={d}", .{ t(o[0].pts), t(o[0].dts), d[0].ABI.abi.dts });
    c.gst_buffer_unref(o);
    const b4 = c.gst_buffer_new();
    o = null;
    _ = c.gst_collect_pads_clip_running_time(cp, d, b4, &o, null);
    out("  clip none same {d}", .{@intFromBool(o == b4)});
    c.gst_buffer_unref(o);
    out("  remove {d} again {d}", .{ c.gst_collect_pads_remove_pad(cp, pad), c.gst_collect_pads_remove_pad(cp, pad) });
    out("  priv after remove null {d} active {d}", .{ @intFromBool(c.gst_pad_get_element_private(pad) == null), c.gst_pad_is_active(pad) });
    c.gst_collect_pads_start(cp);
    c.gst_collect_pads_stop(cp);
    c.gst_object_unref(pad);
    c.gst_object_unref(tmpl);
    c.gst_object_unref(cp);

    run("merge two", &.{ 3, 4 }, &.{ 10, 7 }, false);
    run("merge three", &.{ 2, 3, 1 }, &.{ 5, 10, 20 }, false);
    run("bytes", &.{ 3, 2 }, &.{ 10, 10 }, true);

    out("crit", .{});
    c.gst_collect_pads_start(null);
    _ = c.gst_collect_pads_add_pad(null, null, 0, null, 0);
    out("  available {d}", .{c.gst_collect_pads_available(null)});
    c.gst_collect_pads_set_function(null, null, null);
    out("done", .{});
}
