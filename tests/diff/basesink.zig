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

const TimeSrc = extern struct {
    parent: c.GstPushSrc,
    count: u32,
    total: u32,
    step: u64,
};

fn tsrc(s: anytype) *TimeSrc {
    return @ptrCast(@alignCast(s));
}

fn timeCreate(s: [*c]c.GstPushSrc, out_buf: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const x = tsrc(s);
    if (x.count >= x.total) return c.GST_FLOW_EOS;
    const b = c.gst_buffer_new_allocate(null, 4, null);
    b[0].pts = x.count * x.step;
    b[0].duration = x.step;
    b[0].offset = x.count;
    x.count += 1;
    out_buf.* = b;
    return c.GST_FLOW_OK;
}

fn timeClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string("x-test/time");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "TimeSrc", "Source", "t", "x");
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).create = timeCreate;
    @as(*c.GstBaseSrcClass, @ptrCast(@alignCast(k))).is_seekable = alwaysTrue;
    @as(*c.GstBaseSrcClass, @ptrCast(@alignCast(k))).do_seek = timeSeek;
}

fn alwaysTrue(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 1;
}

fn timeSeek(s: [*c]c.GstBaseSrc, seg: [*c]c.GstSegment) callconv(.c) c.gboolean {
    const x = tsrc(s);
    x.count = @intCast(seg[0].start / x.step);
    seg[0].time = seg[0].start;
    return 1;
}

fn timeInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_src_set_format(@ptrCast(@alignCast(instance)), c.GST_FORMAT_TIME);
    tsrc(instance).total = 5;
    tsrc(instance).step = 10 * MS;
}

fn timeType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_push_src_get_type(), "TestTimeSrc", @sizeOf(c.GstPushSrcClass), timeClass, @sizeOf(TimeSrc), timeInit, 0);
    return S.v;
}

const BytesSrc = extern struct {
    parent: c.GstBaseSrc,
};

fn bytesSize(_: [*c]c.GstBaseSrc, size: [*c]u64) callconv(.c) c.gboolean {
    size.* = 100;
    return 1;
}

fn bytesFill(_: [*c]c.GstBaseSrc, off: u64, len: c.guint, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_WRITE);
    for (0..info.size) |i| info.data[i] = @truncate(off + i);
    c.gst_buffer_unmap(b, &info);
    c.gst_buffer_set_size(b, len);
    return c.GST_FLOW_OK;
}

fn bytesClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string("ANY");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "BytesSrc", "Source", "b", "x");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.get_size = bytesSize;
    bc.is_seekable = alwaysTrue;
    bc.fill = bytesFill;
}

fn bytesType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_src_get_type(), "TestBytesSrc2", @sizeOf(c.GstBaseSrcClass), bytesClass, @sizeOf(BytesSrc), null, 0);
    return S.v;
}

const RecSink = extern struct {
    parent: c.GstBaseSink,
    sleep_first: c.gboolean,
    rendered: u32,
};

fn rs(s: anytype) *RecSink {
    return @ptrCast(@alignCast(s));
}

fn sinkRender(s: [*c]c.GstBaseSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const x = rs(s);
    note("  render pts={d} size={d} flags={x}", .{ t(b[0].pts), c.gst_buffer_get_size(b), b[0].mini_object.flags & 0xffff });
    if (x.sleep_first != 0 and x.rendered == 0) c.g_usleep(200000);
    x.rendered += 1;
    return c.GST_FLOW_OK;
}

fn sinkPreroll(_: [*c]c.GstBaseSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    note("  preroll pts={d}", .{t(b[0].pts)});
    return c.GST_FLOW_OK;
}

var sink_parent: ?*c.GstBaseSinkClass = null;

fn sinkEvent(s: [*c]c.GstBaseSink, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    note("  sink event {s}", .{str(c.gst_event_type_get_name(ev[0].type))});
    return sink_parent.?.event.?(s, ev);
}

fn sinkSetCaps(_: [*c]c.GstBaseSink, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = c.gst_caps_to_string(caps);
    note("  set_caps {s}", .{str(s)});
    c.g_free(s);
    return 1;
}

fn sinkStart(_: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    note("  sink start", .{});
    return 1;
}

fn sinkStop(_: [*c]c.GstBaseSink) callconv(.c) c.gboolean {
    note("  sink stop", .{});
    return 1;
}

fn sinkClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    sink_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const caps = c.gst_caps_from_string("ANY");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "RecSink", "Sink", "r", "x");
    const bc: *c.GstBaseSinkClass = @ptrCast(@alignCast(k));
    bc.render = sinkRender;
    bc.preroll = sinkPreroll;
    bc.event = sinkEvent;
    bc.set_caps = sinkSetCaps;
    bc.start = sinkStart;
    bc.stop = sinkStop;
}

fn sinkType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_sink_get_type(), "TestRecSink", @sizeOf(c.GstBaseSinkClass), sinkClass, @sizeOf(RecSink), null, 0);
    return S.v;
}

var qos_count: u32 = 0;
var msg_buf: [65536]u8 = undefined;
var msg_len: usize = 0;

fn mnote(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(msg_buf[msg_len..], fmt ++ "\n", args) catch return;
    msg_len += s.len;
}

fn flushAll() void {
    flushLog();
    _ = std.c.write(1, &msg_buf, msg_len);
    msg_len = 0;
}

fn messages(bus: ?*c.GstBus, until: c.GstMessageType, timeout: u64) void {
    while (true) {
        const m = c.gst_bus_timed_pop(bus, timeout) orelse {
            mnote("  bus timeout", .{});
            flushAll();
            return;
        };
        defer c.gst_message_unref(m);
        const ty = m[0].type;
        const src: [*c]c.GstObject = @ptrCast(@alignCast(m[0].src));
        const from = str(src[0].name);
        if (!std.mem.eql(u8, from, "sink")) {
            if (ty & until == 0) continue;
        }
        if (ty == c.GST_MESSAGE_LATENCY) continue;
        switch (ty) {
            c.GST_MESSAGE_STATE_CHANGED => {
                var o: c.GstState = 0;
                var n: c.GstState = 0;
                var p: c.GstState = 0;
                c.gst_message_parse_state_changed(m, &o, &n, &p);
                mnote("  msg state {d}->{d} pending {d}", .{ o, n, p });
            },
            c.GST_MESSAGE_QOS => qos_count += 1,
            c.GST_MESSAGE_STEP_DONE => {
                var f: c.GstFormat = 0;
                var amount: u64 = 0;
                var rate: f64 = 0;
                var flush: c.gboolean = 0;
                var inter: c.gboolean = 0;
                var dur: u64 = 0;
                var eos: c.gboolean = 0;
                c.gst_message_parse_step_done(m, &f, &amount, &rate, &flush, &inter, &dur, &eos);
                mnote("  msg step-done fmt={d} amount={d} rate={d} flush={d} inter={d} eos={d}", .{ f, amount, rate, flush, inter, eos });
            },
            c.GST_MESSAGE_STEP_START => {
                var active: c.gboolean = 0;
                var f: c.GstFormat = 0;
                var amount: u64 = 0;
                c.gst_message_parse_step_start(m, &active, &f, &amount, null, null, null);
                mnote("  msg step-start active={d} fmt={d} amount={d}", .{ active, f, amount });
            },
            c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
                var e: [*c]c.GError = null;
                var dbg: [*c]u8 = null;
                if (ty == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
                mnote("  msg {s} {s} | {s}", .{ str(c.gst_message_type_get_name(ty)), str(e[0].message), str(dbg) });
                c.g_clear_error(&e);
                c.g_free(dbg);
            },
            else => {
                mnote("  msg {s}", .{str(c.gst_message_type_get_name(ty))});
            },
        }
        if (ty & until != 0) {
            c.g_usleep(20000);
            flushAll();
            return;
        }
    }
}

fn pipeline(src: [*c]c.GstElement, sink: [*c]c.GstElement) [*c]c.GstElement {
    const p = c.gst_pipeline_new("p");
    _ = c.gst_bin_add(@ptrCast(p), src);
    _ = c.gst_bin_add(@ptrCast(p), sink);
    _ = c.gst_element_link(src, sink);
    return p;
}

fn mkSink() [*c]c.GstElement {
    return @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "sink", @as(?*anyopaque, null))));
}

fn mkTime(total: u32) [*c]c.GstElement {
    const e: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(timeType(), "name", "src", @as(?*anyopaque, null))));
    tsrc(e).total = total;
    return e;
}

fn props(e: [*c]c.GstElement) void {
    var sync: c.gboolean = 0;
    var ml: i64 = 0;
    var qos: c.gboolean = 0;
    var async_: c.gboolean = 0;
    var tso: i64 = 0;
    var els: c.gboolean = 0;
    var bs: c.guint = 0;
    var rd: u64 = 0;
    var tt: u64 = 0;
    var mb: u64 = 0;
    var pd: u64 = 0;
    c.g_object_get(e, "sync", &sync, "max-lateness", &ml, "qos", &qos, "async", &async_, "ts-offset", &tso, "enable-last-sample", &els, "blocksize", &bs, "render-delay", &rd, "throttle-time", &tt, "max-bitrate", &mb, "processing-deadline", &pd, @as(?*anyopaque, null));
    out("  props sync={d} ml={d} qos={d} async={d} tso={d} els={d} bs={d} rd={d} tt={d} mb={d} pd={d}", .{ sync, ml, qos, async_, tso, els, bs, rd, tt, mb, pd });
}

fn stats(e: [*c]c.GstElement) void {
    var s: [*c]c.GstStructure = null;
    c.g_object_get(e, "stats", &s, @as(?*anyopaque, null));
    var r: u64 = 0;
    var d: u64 = 0;
    _ = c.gst_structure_get_uint64(s, "rendered", &r);
    _ = c.gst_structure_get_uint64(s, "dropped", &d);
    out("  stats rendered={d} dropped={d}", .{ r, d });
    c.gst_structure_free(s);
}

fn lastSample(e: [*c]c.GstElement) void {
    var sample: ?*c.GstSample = null;
    c.g_object_get(e, "last-sample", &sample, @as(?*anyopaque, null));
    if (sample == null) {
        out("  last-sample none", .{});
        return;
    }
    const b = c.gst_sample_get_buffer(sample);
    const caps = c.gst_sample_get_caps(sample);
    const cs = if (caps != null) c.gst_caps_to_string(caps) else null;
    out("  last-sample pts={d} caps={s}", .{ t(b[0].pts), str(cs) });
    c.g_free(cs);
    c.gst_sample_unref(sample);
}

fn query(e: [*c]c.GstElement) void {
    var v: i64 = 0;
    const ok = c.gst_element_query_position(e, c.GST_FORMAT_TIME, &v);
    out("  position {d} known={d}", .{ ok, @intFromBool(v >= 0) });
    out("  duration {d}", .{c.gst_element_query_duration(e, c.GST_FORMAT_TIME, &v)});
    var pc: i64 = 0;
    out("  percent dur {d} {d}", .{ c.gst_element_query_duration(e, c.GST_FORMAT_PERCENT, &pc), pc });
    const q = c.gst_query_new_latency();
    out("  latency {d}", .{c.gst_element_query(e, q)});
    var live: c.gboolean = 0;
    var mn: u64 = 0;
    var mx: u64 = 0;
    c.gst_query_parse_latency(q, &live, &mn, &mx);
    out("    {d} {d} {d}", .{ live, mn, t(mx) });
    c.gst_query_unref(q);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    out("type {s} abstract {d}", .{ str(c.g_type_name(c.gst_base_sink_get_type())), c.g_type_test_flags(c.gst_base_sink_get_type(), c.G_TYPE_FLAG_ABSTRACT) });
    const s0 = mkSink();
    _ = c.gst_object_ref_sink(s0);
    props(s0);
    const b0: *c.GstBaseSink = @ptrCast(@alignCast(s0));
    out("  fields mode={d} pull={d} push={d} sync={d} ml={d} flags={x}", .{ b0.pad_mode, b0.can_activate_pull, b0.can_activate_push, b0.sync, b0.max_lateness, b0.element.object.flags });
    c.g_object_set(s0, "sync", @as(c.gboolean, 0), "max-lateness", @as(i64, 5), "qos", @as(c.gboolean, 1), "async", @as(c.gboolean, 0), "ts-offset", @as(i64, -7), "enable-last-sample", @as(c.gboolean, 0), "blocksize", @as(c.guint, 9), "render-delay", @as(u64, 3), "throttle-time", @as(u64, 4), "max-bitrate", @as(u64, 8000), "processing-deadline", @as(u64, 11), @as(?*anyopaque, null));
    props(s0);
    out("  api {d} {d} {d} {d} {d} {d} {d} {d}", .{ c.gst_base_sink_get_sync(b0), c.gst_base_sink_get_max_lateness(b0), c.gst_base_sink_is_qos_enabled(b0), c.gst_base_sink_is_async_enabled(b0), c.gst_base_sink_get_ts_offset(b0), c.gst_base_sink_is_last_sample_enabled(b0), c.gst_base_sink_get_drop_out_of_segment(b0), c.gst_base_sink_get_latency(b0) });
    c.gst_base_sink_set_drop_out_of_segment(b0, 0);
    out("  drop {d} render-delay {d} deadline {d} throttle {d} bitrate {d} blocksize {d}", .{ c.gst_base_sink_get_drop_out_of_segment(b0), c.gst_base_sink_get_render_delay(b0), c.gst_base_sink_get_processing_deadline(b0), c.gst_base_sink_get_throttle_time(b0), c.gst_base_sink_get_max_bitrate(b0), c.gst_base_sink_get_blocksize(b0) });
    var live: c.gboolean = 0;
    var ul: c.gboolean = 0;
    var mn: u64 = 0;
    var mx: u64 = 0;
    out("  query_latency {d} {d} {d} {d} {d}", .{ c.gst_base_sink_query_latency(b0, &live, &ul, &mn, &mx), live, ul, mn, t(mx) });
    lastSample(s0);
    stats(s0);
    c.gst_object_unref(s0);

    out("== bytes no sync", .{});
    const p1 = pipeline(@ptrCast(@alignCast(c.g_object_new(bytesType(), "name", "src", "blocksize", @as(c.guint, 40), @as(?*anyopaque, null)))), mkSink());
    const k1 = c.gst_bin_get_by_name(@ptrCast(p1), "sink");
    c.g_object_set(k1, "sync", @as(c.gboolean, 0), @as(?*anyopaque, null));
    out("  paused {d}", .{c.gst_element_set_state(p1, c.GST_STATE_PAUSED)});
    var st: c.GstState = 0;
    out("  get_state {d}", .{c.gst_element_get_state(p1, &st, null, 5 * c.GST_SECOND)});
    flushLog();
    lastSample(k1);
    query(k1);
    out("  playing {d}", .{c.gst_element_set_state(p1, c.GST_STATE_PLAYING)});
    const bus1 = c.gst_element_get_bus(p1);
    messages(bus1, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR, 5 * c.GST_SECOND);
    stats(k1);
    lastSample(k1);
    out("  null {d}", .{c.gst_element_set_state(p1, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus1);
    c.gst_object_unref(k1);
    c.gst_object_unref(p1);

    out("== time sync", .{});
    const p2 = pipeline(mkTime(5), mkSink());
    const k2 = c.gst_bin_get_by_name(@ptrCast(p2), "sink");
    out("  playing {d}", .{c.gst_element_set_state(p2, c.GST_STATE_PLAYING)});
    const bus2 = c.gst_element_get_bus(p2);
    messages(bus2, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR, 5 * c.GST_SECOND);
    stats(k2);
    query(k2);
    out("  null {d}", .{c.gst_element_set_state(p2, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus2);
    c.gst_object_unref(k2);
    c.gst_object_unref(p2);

    out("== seek and step", .{});
    const p3 = pipeline(mkTime(50), mkSink());
    const k3 = c.gst_bin_get_by_name(@ptrCast(p3), "sink");
    const bus3 = c.gst_element_get_bus(p3);
    out("  paused {d}", .{c.gst_element_set_state(p3, c.GST_STATE_PAUSED)});
    out("  get_state {d}", .{c.gst_element_get_state(p3, &st, null, 5 * c.GST_SECOND)});
    messages(bus3, c.GST_MESSAGE_ASYNC_DONE, c.GST_SECOND);
    out("  seek {d}", .{c.gst_element_seek_simple(p3, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_FLUSH, 200 * MS)});
    out("  get_state {d}", .{c.gst_element_get_state(p3, &st, null, 5 * c.GST_SECOND)});
    messages(bus3, c.GST_MESSAGE_ASYNC_DONE, c.GST_SECOND);
    lastSample(k3);
    out("  step {d}", .{c.gst_element_send_event(p3, c.gst_event_new_step(c.GST_FORMAT_BUFFERS, 2, 1.0, 1, 0))});
    messages(bus3, c.GST_MESSAGE_STEP_DONE, c.GST_SECOND);
    out("  get_state {d}", .{c.gst_element_get_state(p3, &st, null, 5 * c.GST_SECOND)});
    lastSample(k3);
    out("  null {d}", .{c.gst_element_set_state(p3, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus3);
    c.gst_object_unref(k3);
    c.gst_object_unref(p3);

    out("== late drop", .{});
    const p4 = pipeline(mkTime(6), mkSink());
    const k4 = c.gst_bin_get_by_name(@ptrCast(p4), "sink");
    rs(k4).sleep_first = 1;
    c.g_object_set(k4, "max-lateness", @as(i64, 20 * MS), "qos", @as(c.gboolean, 1), @as(?*anyopaque, null));
    qos_count = 0;
    out("  playing {d}", .{c.gst_element_set_state(p4, c.GST_STATE_PLAYING)});
    const bus4 = c.gst_element_get_bus(p4);
    messages(bus4, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR, 5 * c.GST_SECOND);
    stats(k4);
    out("  qos messages {d}", .{@intFromBool(qos_count > 0)});
    out("  null {d}", .{c.gst_element_set_state(p4, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus4);
    c.gst_object_unref(k4);
    c.gst_object_unref(p4);

    out("== pull mode", .{});
    const s5 = mkSink();
    const b5: *c.GstBaseSink = @ptrCast(@alignCast(s5));
    b5.can_activate_pull = 1;
    c.g_object_set(s5, "sync", @as(c.gboolean, 0), "blocksize", @as(c.guint, 30), @as(?*anyopaque, null));
    const p5 = pipeline(@ptrCast(@alignCast(c.g_object_new(bytesType(), "name", "src", @as(?*anyopaque, null)))), s5);
    out("  paused {d}", .{c.gst_element_set_state(p5, c.GST_STATE_PAUSED)});
    out("  get_state {d}", .{c.gst_element_get_state(p5, &st, null, 5 * c.GST_SECOND)});
    const bus5 = c.gst_element_get_bus(p5);
    messages(bus5, c.GST_MESSAGE_ASYNC_DONE, c.GST_SECOND);
    out("  mode {d}", .{b5.pad_mode});
    var dur: i64 = 0;
    out("  duration bytes {d} {d}", .{ c.gst_element_query_duration(s5, c.GST_FORMAT_BYTES, &dur), dur });
    out("  null {d}", .{c.gst_element_set_state(p5, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus5);
    c.gst_object_unref(p5);

    out("== no async", .{});
    const s6 = mkSink();
    c.g_object_set(s6, "async", @as(c.gboolean, 0), "sync", @as(c.gboolean, 0), @as(?*anyopaque, null));
    const p6 = pipeline(mkTime(2), s6);
    out("  paused {d}", .{c.gst_element_set_state(p6, c.GST_STATE_PAUSED)});
    c.g_usleep(100000);
    flushLog();
    out("  playing {d}", .{c.gst_element_set_state(p6, c.GST_STATE_PLAYING)});
    const bus6 = c.gst_element_get_bus(p6);
    messages(bus6, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR, 5 * c.GST_SECOND);
    out("  null {d}", .{c.gst_element_set_state(p6, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus6);
    c.gst_object_unref(p6);

    out("== direct pad use", .{});
    const s7 = mkSink();
    _ = c.gst_object_ref_sink(s7);
    const pad = c.gst_element_get_static_pad(s7, "sink");
    c.g_object_set(s7, "sync", @as(c.gboolean, 0), "async", @as(c.gboolean, 0), @as(?*anyopaque, null));
    out("  playing {d}", .{c.gst_element_set_state(s7, c.GST_STATE_PLAYING)});
    out("  buffer before segment {s}", .{str(c.gst_flow_get_name(c.gst_pad_chain(pad, c.gst_buffer_new_allocate(null, 3, null))))});
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = 100 * MS;
    seg.stop = 200 * MS;
    out("  segment {d}", .{c.gst_pad_send_event(pad, c.gst_event_new_segment(&seg))});
    for ([_]u64{ 50, 150, 250 }) |pts| {
        const b = c.gst_buffer_new_allocate(null, 1, null);
        b[0].pts = pts * MS;
        out("  chain {d} -> {s}", .{ pts, str(c.gst_flow_get_name(c.gst_pad_chain(pad, b))) });
    }
    const list = c.gst_buffer_list_new();
    for ([_]u64{ 160, 170 }) |pts| {
        const b = c.gst_buffer_new_allocate(null, 2, null);
        b[0].pts = pts * MS;
        c.gst_buffer_list_insert(list, -1, b);
    }
    out("  chain list {s}", .{str(c.gst_flow_get_name(c.gst_pad_chain_list(pad, list)))});
    out("  gap {d}", .{c.gst_pad_send_event(pad, c.gst_event_new_gap(180 * MS, 5 * MS))});
    const tags = c.gst_tag_list_new_empty();
    out("  tag {d}", .{c.gst_pad_send_event(pad, c.gst_event_new_tag(tags))});
    out("  eos {d}", .{c.gst_pad_send_event(pad, c.gst_event_new_eos())});
    out("  after eos {s}", .{str(c.gst_flow_get_name(c.gst_pad_chain(pad, c.gst_buffer_new_allocate(null, 1, null))))});
    out("  event after eos {d}", .{c.gst_pad_send_event(pad, c.gst_event_new_segment(&seg))});
    flushLog();
    const q = c.gst_query_new_accept_caps(c.gst_caps_from_string("x/y"));
    out("  accept caps {d}", .{c.gst_pad_query(pad, q)});
    c.gst_query_unref(q);
    const dq = c.gst_query_new_drain();
    out("  drain {d}", .{c.gst_pad_query(pad, dq)});
    c.gst_query_unref(dq);
    stats(s7);
    _ = c.gst_element_set_state(s7, c.GST_STATE_NULL);
    flushLog();
    c.gst_object_unref(pad);
    c.gst_object_unref(s7);

    out("crit {d}", .{c.gst_base_sink_get_sync(null)});
    c.gst_base_sink_set_render_delay(null, 1);
    out("crit {d}", .{@intFromBool(c.gst_base_sink_get_stats(null) == null)});
    out("done", .{});
}
