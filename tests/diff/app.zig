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
var log_buf: [131072]u8 = undefined;
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

fn describe(gt: c.GType) void {
    out("type {s} parent {s}", .{ str(c.g_type_name(gt)), str(c.g_type_name(c.g_type_parent(gt))) });
    out("  uri handler {d}", .{c.g_type_is_a(gt, c.gst_uri_handler_get_type())});
    const k = c.g_type_class_ref(gt);
    defer c.g_type_class_unref(k);
    var n: c.guint = 0;
    const specs = c.g_object_class_list_properties(@ptrCast(@alignCast(k)), &n);
    for (0..n) |i| {
        const s = specs[i];
        if (s[0].owner_type != gt) continue;
        const dv = c.g_param_spec_get_default_value(s);
        const ds = c.g_strdup_value_contents(dv);
        out("  prop {s} type={s} flags={x} default={s} blurb={s}", .{ str(s[0].name), str(c.g_type_name(s[0].value_type)), s[0].flags, str(ds), str(c.g_param_spec_get_blurb(s)) });
        c.g_free(ds);
    }
    c.g_free(@ptrCast(specs));
    var ns: c.guint = 0;
    const ids = c.g_signal_list_ids(gt, &ns);
    for (0..ns) |i| {
        var q: c.GSignalQuery = undefined;
        c.g_signal_query(ids[i], &q);
        out("  signal {s} flags={x} ret={s} n={d}", .{ str(q.signal_name), q.signal_flags, str(c.g_type_name(q.return_type & ~@as(c.GType, 1))), q.n_params });
        for (0..q.n_params) |j| out("    param {s} static={d}", .{ str(c.g_type_name(q.param_types[j] & ~@as(c.GType, 1))), q.param_types[j] & 1 });
    }
    c.g_free(ids);
    const tp = c.gst_element_class_get_pad_template(@ptrCast(@alignCast(k)), if (c.g_type_is_a(gt, c.gst_base_src_get_type()) != 0) "src" else "sink");
    const tc = c.gst_pad_template_get_caps(tp);
    const tcs = c.gst_caps_to_string(tc);
    out("  template {s}", .{str(tcs)});
    c.g_free(tcs);
    c.gst_caps_unref(tc);
    out("  longname {s}", .{str(c.gst_element_class_get_metadata(@ptrCast(@alignCast(k)), "long-name"))});
}

fn enumDump(gt: c.GType) void {
    const k: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(gt)));
    defer c.g_type_class_unref(k);
    out("enum {s}", .{str(c.g_type_name(gt))});
    for (0..k.n_values) |i| out("  {d} {s} {s}", .{ k.values[i].value, str(k.values[i].value_name), str(k.values[i].value_nick) });
}

fn mkBuf(n: u64, size: usize) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, size, null);
    _ = c.gst_buffer_memset(b, 0, @truncate(n), size);
    b[0].pts = n * 10 * MS;
    b[0].duration = 10 * MS;
    return b;
}

fn sampleInfo(label: []const u8, s: ?*c.GstSample) void {
    if (s == null) {
        out("  {s} null", .{label});
        return;
    }
    const b = c.gst_sample_get_buffer(s);
    const l = c.gst_sample_get_buffer_list(s);
    const caps = c.gst_sample_get_caps(s);
    const seg = c.gst_sample_get_segment(s);
    const cs = if (caps != null) c.gst_caps_to_string(caps) else c.g_strdup("(none)");
    out("  {s} buf={d} pts={d} size={d} flags={x} list={d} caps={s} seg fmt={d} start={d} base={d}", .{ label, @intFromBool(b != null), if (b != null) t(b[0].pts) else -2, if (b != null) c.gst_buffer_get_size(b) else 0, if (b != null) b[0].mini_object.flags & 0xffff else 0, if (l != null) c.gst_buffer_list_length(l) else 0, str(cs), seg[0].format, t(seg[0].start), t(seg[0].base) });
    c.g_free(cs);
}

fn levels(src: [*c]c.GstAppSrc, sink: [*c]c.GstAppSink) void {
    if (src != null) out("  src level bytes={d} buffers={d} time={d}", .{ c.gst_app_src_get_current_level_bytes(src), c.gst_app_src_get_current_level_buffers(src), t(c.gst_app_src_get_current_level_time(src)) });
    if (sink != null) out("  sink level bytes={d} buffers={d} time={d}", .{ c.gst_app_sink_get_current_level_bytes(sink), c.gst_app_sink_get_current_level_buffers(sink), t(c.gst_app_sink_get_current_level_time(sink)) });
}

fn counters(o: c.gpointer, label: []const u8) void {
    var in: u64 = 0;
    var o2: u64 = 0;
    var d: u64 = 0;
    c.g_object_get(o, "in", &in, "out", &o2, "dropped", &d, @as(?*anyopaque, null));
    out("  {s} in={d} out={d} dropped={d}", .{ label, in, o2, d });
}

const Pipe = struct {
    p: [*c]c.GstElement,
    src: [*c]c.GstAppSrc,
    sink: [*c]c.GstAppSink,
};

fn pipe(format: c.GstFormat) Pipe {
    const p = c.gst_pipeline_new("p");
    const src: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(c.gst_app_src_get_type(), "name", "src", "format", format, @as(?*anyopaque, null))));
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(c.gst_app_sink_get_type(), "name", "sink", "sync", @as(c.gboolean, 0), @as(?*anyopaque, null))));
    _ = c.gst_bin_add(@ptrCast(p), src);
    _ = c.gst_bin_add(@ptrCast(p), sink);
    _ = c.gst_element_link(src, sink);
    return .{ .p = p, .src = @ptrCast(@alignCast(src)), .sink = @ptrCast(@alignCast(sink)) };
}

fn drainBus(p: [*c]c.GstElement) void {
    const bus = c.gst_element_get_bus(p);
    defer c.gst_object_unref(bus);
    while (c.gst_bus_pop_filtered(bus, c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_EOS | c.GST_MESSAGE_DURATION_CHANGED)) |m| {
        if (m[0].type == c.GST_MESSAGE_ERROR or m[0].type == c.GST_MESSAGE_WARNING) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
            out("  bus {s}: {s}", .{ str(c.gst_message_type_get_name(m[0].type)), str(e[0].message) });
            c.g_clear_error(&e);
            c.g_free(dbg);
        } else out("  bus {s} from {s}", .{ str(c.gst_message_type_get_name(m[0].type)), str(@as(*c.GstObject, @ptrCast(@alignCast(m[0].src))).name) });
        c.gst_message_unref(m);
    }
}

fn waitEos(p: [*c]c.GstElement) void {
    const bus = c.gst_element_get_bus(p);
    defer c.gst_object_unref(bus);
    const m = c.gst_bus_timed_pop_filtered(bus, 3 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m == null) {
        out("  bus timeout", .{});
        return;
    }
    out("  bus {s}", .{str(c.gst_message_type_get_name(m[0].type))});
    c.gst_message_unref(m);
}

fn basic() void {
    out("== basic", .{});
    const x = pipe(c.GST_FORMAT_TIME);
    const caps = c.gst_caps_from_string("x-test/a, rate=(int)5");
    c.gst_app_src_set_caps(x.src, caps);
    c.gst_app_src_set_caps(x.src, caps);
    c.gst_caps_unref(caps);
    c.gst_app_src_set_duration(x.src, 50 * MS);
    for (0..3) |i| out("  push {d} {s}", .{ i, str(c.gst_flow_get_name(c.gst_app_src_push_buffer(x.src, mkBuf(i, 8 + i)))) });
    levels(x.src, null);
    out("  paused {d}", .{c.gst_element_set_state(x.p, c.GST_STATE_PAUSED)});
    out("  get_state {d}", .{c.gst_element_get_state(x.p, null, null, 3 * c.GST_SECOND)});
    sampleInfo("preroll", c.gst_app_sink_pull_preroll(x.sink));
    sampleInfo("try preroll again", c.gst_app_sink_try_pull_preroll(x.sink, 0));
    out("  playing {d}", .{c.gst_element_set_state(x.p, c.GST_STATE_PLAYING)});
    for (0..3) |_| {
        const s = c.gst_app_sink_pull_sample(x.sink);
        sampleInfo("sample", s);
        if (s != null) c.gst_mini_object_unref(@ptrCast(@alignCast(s)));
    }
    const l = c.gst_buffer_list_new();
    c.gst_buffer_list_insert(l, -1, mkBuf(3, 4));
    c.gst_buffer_list_insert(l, -1, mkBuf(4, 4));
    out("  push list {s}", .{str(c.gst_flow_get_name(c.gst_app_src_push_buffer_list(x.src, l)))});
    for (0..2) |_| {
        const s = c.gst_app_sink_try_pull_sample(x.sink, 2 * c.GST_SECOND);
        sampleInfo("sample", s);
        if (s != null) c.gst_mini_object_unref(@ptrCast(@alignCast(s)));
    }
    out("  try pull empty null {d}", .{@intFromBool(c.gst_app_sink_try_pull_sample(x.sink, 10 * MS) == null)});
    out("  eos {s}", .{str(c.gst_flow_get_name(c.gst_app_src_end_of_stream(x.src)))});
    out("  push after eos {s}", .{str(c.gst_flow_get_name(c.gst_app_src_push_buffer(x.src, mkBuf(9, 1))))});
    waitEos(x.p);
    out("  sink eos {d}", .{c.gst_app_sink_is_eos(x.sink)});
    out("  pull after eos null {d}", .{@intFromBool(c.gst_app_sink_pull_sample(x.sink) == null)});
    var dur: i64 = 0;
    out("  duration {d} {d}", .{ c.gst_element_query_duration(@ptrCast(x.src), c.GST_FORMAT_TIME, &dur), dur });
    counters(x.src, "src");
    counters(x.sink, "sink");
    drainBus(x.p);
    out("  null {d}", .{c.gst_element_set_state(x.p, c.GST_STATE_NULL)});
    out("  sink eos after stop {d}", .{c.gst_app_sink_is_eos(x.sink)});
    c.gst_object_unref(x.p);
}

var need_count: u32 = 0;
var enough_count: u32 = 0;

fn onNeed(_: [*c]c.GstAppSrc, len: c.guint, _: c.gpointer) callconv(.c) void {
    need_count += 1;
    if (need_count <= 2) note("  need-data cb len={d}", .{len});
}

fn onEnough(_: [*c]c.GstAppSrc, _: c.gpointer) callconv(.c) void {
    enough_count += 1;
    note("  enough-data cb", .{});
}

fn onSeek(_: [*c]c.GstAppSrc, off: u64, _: c.gpointer) callconv(.c) c.gboolean {
    note("  seek-data cb {d}", .{off});
    return 1;
}

fn destroyNote(d: c.gpointer) callconv(.c) void {
    note("  destroy {s}", .{str(@ptrCast(d))});
}

fn leaky() void {
    for ([_]c.GstAppLeakyType{ c.GST_APP_LEAKY_TYPE_NONE, c.GST_APP_LEAKY_TYPE_UPSTREAM, c.GST_APP_LEAKY_TYPE_DOWNSTREAM }) |lt| {
        out("== src leaky {d}", .{lt});
        const src: [*c]c.GstAppSrc = @ptrCast(@alignCast(c.g_object_new(c.gst_app_src_get_type(), "name", "s", "max-buffers", @as(u64, 2), "format", c.GST_FORMAT_TIME, @as(?*anyopaque, null))));
        _ = c.gst_object_ref_sink(src);
        c.gst_app_src_set_leaky_type(src, lt);
        c.g_object_set(src, "silent", @as(c.gboolean, 0), @as(?*anyopaque, null));
        var cbs = std.mem.zeroes(c.GstAppSrcCallbacks);
        cbs.need_data = onNeed;
        cbs.enough_data = onEnough;
        cbs.seek_data = onSeek;
        enough_count = 0;
        c.gst_app_src_set_callbacks(src, &cbs, @constCast("cbs"), destroyNote);
        for (0..5) |i| out("  push {d} {s}", .{ i, str(c.gst_flow_get_name(c.gst_app_src_push_buffer(src, mkBuf(i, 10)))) });
        flushLog();
        levels(src, null);
        counters(src, "src");
        out("  enough {d}", .{enough_count});
        _ = c.gst_element_set_state(@ptrCast(src), c.GST_STATE_PAUSED);
        _ = c.gst_element_set_state(@ptrCast(src), c.GST_STATE_NULL);
        c.gst_object_unref(src);
        flushLog();
    }
    for ([_]c.GstAppLeakyType{ c.GST_APP_LEAKY_TYPE_DOWNSTREAM, c.GST_APP_LEAKY_TYPE_UPSTREAM }) |lt| {
        out("== sink leaky {d}", .{lt});
        const x = pipe(c.GST_FORMAT_TIME);
        c.gst_app_sink_set_max_buffers(x.sink, 2);
        c.gst_app_sink_set_leaky_type(x.sink, lt);
        c.gst_app_src_set_max_bytes(x.src, 0);
        const caps = c.gst_caps_from_string("x-test/b");
        c.gst_app_src_set_caps(x.src, caps);
        c.gst_caps_unref(caps);
        for (0..6) |i| _ = c.gst_app_src_push_buffer(x.src, mkBuf(i, 3));
        _ = c.gst_app_src_end_of_stream(x.src);
        out("  playing {d}", .{c.gst_element_set_state(x.p, c.GST_STATE_PLAYING)});
        waitEos(x.p);
        levels(null, x.sink);
        out("  drop {d}", .{c.gst_app_sink_get_drop(x.sink)});
        while (c.gst_app_sink_try_pull_sample(x.sink, 0)) |s| {
            sampleInfo("left", s);
            c.gst_mini_object_unref(@ptrCast(@alignCast(s)));
        }
        counters(x.sink, "sink");
        _ = c.gst_element_set_state(x.p, c.GST_STATE_NULL);
        c.gst_object_unref(x.p);
    }
}

fn onNewSample(sk: [*c]c.GstAppSink, _: c.gpointer) callconv(.c) c.GstFlowReturn {
    const s = c.gst_app_sink_pull_sample(sk);
    const b = c.gst_sample_get_buffer(s);
    note("  new-sample cb pts={d}", .{t(b[0].pts)});
    c.gst_mini_object_unref(@ptrCast(@alignCast(s)));
    return c.GST_FLOW_OK;
}

fn onEos(_: [*c]c.GstAppSink, _: c.gpointer) callconv(.c) void {
    note("  eos cb", .{});
}

fn onEvent(sk: [*c]c.GstAppSink, _: c.gpointer) callconv(.c) c.gboolean {
    const o = c.gst_app_sink_try_pull_object(sk, 0);
    if (o == null) return 0;
    if (o[0].type == c._gst_event_type) {
        note("  new-event cb {s}", .{str(c.gst_event_type_get_name(@as(*c.GstEvent, @ptrCast(@alignCast(o))).type))});
    } else note("  new-event cb got {s}", .{str(c.g_type_name(o[0].type))});
    c.gst_mini_object_unref(o);
    return 0;
}

fn onPreroll(_: [*c]c.GstAppSink, _: c.gpointer) callconv(.c) c.GstFlowReturn {
    note("  new-preroll cb", .{});
    return c.GST_FLOW_OK;
}

fn sigSample(sk: ?*anyopaque, _: c.gpointer) callconv(.c) c.GstFlowReturn {
    var s: ?*c.GstSample = null;
    c.g_signal_emit_by_name(sk, "pull-sample", &s);
    note("  new-sample signal pts={d}", .{t(c.gst_sample_get_buffer(s)[0].pts)});
    c.gst_mini_object_unref(@ptrCast(@alignCast(s)));
    return c.GST_FLOW_OK;
}

fn sigNeed(_: ?*anyopaque, len: c.guint, _: c.gpointer) callconv(.c) void {
    need_count += 1;
    if (need_count <= 1) note("  need-data signal {d}", .{len});
}

fn callbacks() void {
    out("== callbacks", .{});
    const x = pipe(c.GST_FORMAT_TIME);
    var cbs = std.mem.zeroes(c.GstAppSinkCallbacks);
    cbs.new_sample = onNewSample;
    cbs.eos = onEos;
    cbs.new_preroll = onPreroll;
    cbs.new_event = onEvent;
    c.gst_app_sink_set_callbacks(x.sink, &cbs, @constCast("sinkcbs"), destroyNote);
    const caps = c.gst_caps_from_string("x-test/c");
    c.gst_app_src_set_caps(x.src, caps);
    c.gst_caps_unref(caps);
    for (0..3) |i| _ = c.gst_app_src_push_buffer(x.src, mkBuf(i, 2));
    _ = c.gst_app_src_end_of_stream(x.src);
    _ = c.gst_element_set_state(x.p, c.GST_STATE_PLAYING);
    waitEos(x.p);
    flushLog();
    _ = c.gst_element_set_state(x.p, c.GST_STATE_NULL);
    c.gst_object_unref(x.p);
    flushLog();

    out("== signals", .{});
    const y = pipe(c.GST_FORMAT_TIME);
    c.gst_app_sink_set_emit_signals(y.sink, 1);
    _ = c.g_signal_connect_data(y.sink, "new-sample", @ptrCast(&sigSample), null, null, 0);
    need_count = 0;
    _ = c.g_signal_connect_data(y.src, "need-data", @ptrCast(&sigNeed), null, null, 0);
    var ret: c.GstFlowReturn = 99;
    const b = mkBuf(7, 5);
    c.g_signal_emit_by_name(y.src, "push-buffer", b, &ret);
    c.gst_buffer_unref(b);
    out("  push-buffer signal {s}", .{str(c.gst_flow_get_name(ret))});
    const smp = c.gst_sample_new(mkBuf(8, 6), c.gst_caps_from_string("x-test/d"), null, null);
    c.g_signal_emit_by_name(y.src, "push-sample", smp, &ret);
    out("  push-sample signal {s}", .{str(c.gst_flow_get_name(ret))});
    c.gst_mini_object_unref(@ptrCast(@alignCast(smp)));
    c.g_signal_emit_by_name(y.src, "end-of-stream", &ret);
    out("  end-of-stream signal {s}", .{str(c.gst_flow_get_name(ret))});
    _ = c.gst_element_set_state(y.p, c.GST_STATE_PLAYING);
    waitEos(y.p);
    flushLog();
    out("  need count positive {d}", .{@intFromBool(need_count > 0)});
    _ = c.gst_element_set_state(y.p, c.GST_STATE_NULL);
    c.gst_object_unref(y.p);
    flushLog();
}

fn simple() void {
    out("== simple callbacks", .{});
    const sc = c.gst_app_sink_simple_callbacks_new();
    c.gst_app_sink_simple_callbacks_set_new_sample(sc, onNewSample, @constCast("ns"), destroyNote);
    c.gst_app_sink_simple_callbacks_set_new_sample(sc, onNewSample, @constCast("ns2"), destroyNote);
    c.gst_app_sink_simple_callbacks_set_eos(sc, onEos, @constCast("eos"), destroyNote);
    const boxed = c.g_boxed_copy(c.gst_app_sink_simple_callbacks_get_type(), sc);
    c.g_boxed_free(c.gst_app_sink_simple_callbacks_get_type(), boxed);
    const ss = c.gst_app_src_simple_callbacks_new();
    c.gst_app_src_simple_callbacks_set_need_data(ss, onNeed, @constCast("nd"), destroyNote);
    c.gst_app_src_simple_callbacks_set_enough_data(ss, onEnough, null, null);
    c.gst_app_src_simple_callbacks_set_seek_data(ss, onSeek, null, null);
    const x = pipe(c.GST_FORMAT_TIME);
    c.gst_app_sink_set_simple_callbacks(x.sink, sc);
    c.gst_app_src_set_simple_callbacks(x.src, ss);
    c.gst_app_sink_simple_callbacks_set_new_preroll(sc, onPreroll, null, null);
    flushLog();
    const caps = c.gst_caps_from_string("x-test/e");
    c.gst_app_src_set_caps(x.src, caps);
    c.gst_caps_unref(caps);
    need_count = 0;
    for (0..2) |i| _ = c.gst_app_src_push_buffer(x.src, mkBuf(i, 2));
    _ = c.gst_app_src_end_of_stream(x.src);
    _ = c.gst_element_set_state(x.p, c.GST_STATE_PLAYING);
    waitEos(x.p);
    _ = c.gst_element_set_state(x.p, c.GST_STATE_NULL);
    flushLog();
    c.gst_object_unref(x.p);
    flushLog();
}

fn segments() void {
    out("== segment change", .{});
    const x = pipe(c.GST_FORMAT_TIME);
    c.g_object_set(x.src, "handle-segment-change", @as(c.gboolean, 1), @as(?*anyopaque, null));
    c.gst_app_sink_set_buffer_list_support(x.sink, 1);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    const caps = c.gst_caps_from_string("x-test/f");
    for (0..4) |i| {
        if (i == 2) {
            seg.base = 100 * MS;
            seg.start = 20 * MS;
        }
        const s = c.gst_sample_new(mkBuf(i, 3), caps, &seg, null);
        out("  push sample {d} {s}", .{ i, str(c.gst_flow_get_name(c.gst_app_src_push_sample(x.src, s))) });
        c.gst_mini_object_unref(@ptrCast(@alignCast(s)));
    }
    const l = c.gst_buffer_list_new();
    c.gst_buffer_list_insert(l, -1, mkBuf(5, 4));
    c.gst_buffer_list_insert(l, -1, mkBuf(6, 4));
    const sl = c.gst_sample_new(null, caps, &seg, null);
    c.gst_sample_set_buffer_list(sl, l);
    c.gst_mini_object_unref(@ptrCast(@alignCast(l)));
    out("  push list sample {s}", .{str(c.gst_flow_get_name(c.gst_app_src_push_sample(x.src, sl)))});
    c.gst_mini_object_unref(@ptrCast(@alignCast(sl)));
    c.gst_caps_unref(caps);
    levels(x.src, null);
    _ = c.gst_app_src_end_of_stream(x.src);
    _ = c.gst_element_set_state(x.p, c.GST_STATE_PLAYING);
    var n: usize = 0;
    while (n < 10) : (n += 1) {
        const o = c.gst_app_sink_try_pull_object(x.sink, 2 * c.GST_SECOND);
        if (o == null) break;
        if (o[0].type == c._gst_event_type) {
            out("  object event {s}", .{str(c.gst_event_type_get_name(@as(*c.GstEvent, @ptrCast(@alignCast(o))).type))});
        } else sampleInfo("object sample", @ptrCast(@alignCast(o)));
        c.gst_mini_object_unref(o);
    }
    levels(null, x.sink);
    waitEos(x.p);
    _ = c.gst_element_set_state(x.p, c.GST_STATE_NULL);
    c.gst_object_unref(x.p);
}

fn queries() void {
    out("== queries", .{});
    const src: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(c.gst_app_src_get_type(), "name", "q", @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(src);
    const a: [*c]c.GstAppSrc = @ptrCast(@alignCast(src));
    c.gst_app_src_set_size(a, 1234);
    c.gst_app_src_set_stream_type(a, c.GST_APP_STREAM_TYPE_RANDOM_ACCESS);
    c.gst_app_src_set_latency(a, 3 * MS, 7 * MS);
    const pad = c.gst_element_get_static_pad(src, "src");
    var v: i64 = 0;
    out("  dur bytes {d} {d}", .{ c.gst_pad_query_duration(pad, c.GST_FORMAT_BYTES, &v), v });
    out("  dur time {d} {d}", .{ c.gst_pad_query_duration(pad, c.GST_FORMAT_TIME, &v), v });
    const sq = c.gst_query_new_scheduling();
    out("  scheduling {d} modes {d} pull {d}", .{ c.gst_pad_query(pad, sq), c.gst_query_get_n_scheduling_modes(sq), c.gst_query_has_scheduling_mode(sq, c.GST_PAD_MODE_PULL) });
    c.gst_query_unref(sq);
    const lq = c.gst_query_new_latency();
    var live: c.gboolean = 0;
    var mn: u64 = 0;
    var mx: u64 = 0;
    out("  latency {d}", .{c.gst_pad_query(pad, lq)});
    c.gst_query_parse_latency(lq, &live, &mn, &mx);
    out("  latency live={d} {d} {d}", .{ live, t(mn), t(mx) });
    c.gst_query_unref(lq);
    var min_l: i64 = 0;
    var max_l: i64 = 0;
    c.g_object_get(src, "min-latency", &min_l, "max-latency", &max_l, @as(?*anyopaque, null));
    out("  latency props {d} {d}", .{ min_l, max_l });
    c.gst_object_unref(pad);
    const uh: ?*c.GstURIHandler = @ptrCast(@alignCast(src));
    const protos = c.gst_uri_handler_get_protocols(uh);
    out("  uri type {d} proto {s} uri {s}", .{ c.gst_uri_handler_get_uri_type(uh), str(protos[0]), str(c.gst_uri_handler_get_uri(uh)) });
    var err: [*c]c.GError = null;
    out("  set uri {d} uri {s}", .{ c.gst_uri_handler_set_uri(uh, "appsrc://x", &err), str(c.gst_uri_handler_get_uri(uh)) });
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(c.gst_app_sink_get_type(), "name", "k", @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(sink);
    const sh: ?*c.GstURIHandler = @ptrCast(@alignCast(sink));
    out("  sink uri type {d} proto {s} uri {s}", .{ c.gst_uri_handler_get_uri_type(sh), str(c.gst_uri_handler_get_protocols(sh)[0]), str(c.gst_uri_handler_get_uri(sh)) });
    const k: [*c]c.GstAppSink = @ptrCast(@alignCast(sink));
    c.gst_app_sink_set_max_time(k, 0x1_0000_0005);
    c.gst_app_sink_set_max_bytes(k, 0x2_0000_0007);
    out("  sink max time {d} bytes {d}", .{ c.gst_app_sink_get_max_time(k), c.gst_app_sink_get_max_bytes(k) });
    var mt: u64 = 0;
    c.g_object_get(sink, "max-time", &mt, @as(?*anyopaque, null));
    out("  sink max-time prop {d}", .{mt});
    const caps = c.gst_caps_from_string("x-test/g");
    c.gst_app_sink_set_caps(k, caps);
    const kp = c.gst_element_get_static_pad(sink, "sink");
    const qc = c.gst_pad_query_caps(kp, null);
    const qs = c.gst_caps_to_string(qc);
    out("  sink caps query {s} same {d}", .{ str(qs), @intFromBool(c.gst_app_sink_get_caps(k) == caps) });
    c.g_free(qs);
    c.gst_caps_unref(qc);
    c.gst_caps_unref(caps);
    const seq = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
    var sk: c.gboolean = 7;
    out("  sink seeking {d}", .{c.gst_pad_query(kp, seq)});
    c.gst_query_parse_seeking(seq, null, &sk, null, null);
    out("  sink seekable {d}", .{sk});
    c.gst_query_unref(seq);
    c.gst_object_unref(kp);
    out("  sink is eos (not started) {d}", .{c.gst_app_sink_is_eos(k)});
    out("  pull unstarted null {d}", .{@intFromBool(c.gst_app_sink_try_pull_sample(k, 0) == null)});
    c.gst_object_unref(sink);
    c.gst_object_unref(src);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    enumDump(c.gst_app_stream_type_get_type());
    enumDump(c.gst_app_leaky_type_get_type());
    describe(c.gst_app_src_get_type());
    describe(c.gst_app_sink_get_type());
    out("boxed {s} {s}", .{ str(c.g_type_name(c.gst_app_src_simple_callbacks_get_type())), str(c.g_type_name(c.gst_app_sink_simple_callbacks_get_type())) });
    basic();
    leaky();
    callbacks();
    simple();
    segments();
    queries();
    out("crit", .{});
    c.gst_app_src_set_caps(null, null);
    out("  size {d} type {d} dur {d}", .{ c.gst_app_src_get_size(null), c.gst_app_src_get_stream_type(null), t(c.gst_app_src_get_duration(null)) });
    out("  levels {d} {d}", .{ c.gst_app_src_get_current_level_bytes(null), c.gst_app_sink_get_max_buffers(null) });
    out("  push {d}", .{c.gst_app_src_push_buffer(null, null)});
    out("  sink eos {d}", .{c.gst_app_sink_is_eos(null)});
    c.gst_app_src_set_callbacks(null, null, null, null);
    c.gst_app_sink_simple_callbacks_unref(null);
    const sc = c.gst_app_sink_simple_callbacks_new();
    const x: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(c.gst_app_sink_get_type(), null)));
    _ = c.gst_object_ref_sink(x);
    c.gst_app_sink_set_simple_callbacks(@ptrCast(@alignCast(x)), sc);
    c.gst_app_sink_simple_callbacks_set_eos(sc, onEos, null, null);
    c.g_object_set(x, "no-such-thing", @as(c.gint, 1), @as(?*anyopaque, null));
    c.gst_object_unref(x);
    flushLog();
    out("done", .{});
}
