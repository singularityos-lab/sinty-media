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

fn sinkChain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    const first: i32 = if (info.size > 0) info.data[0] else -1;
    c.gst_buffer_unmap(b, &info);
    note("  buffer size={d} pts={d} dts={d} dur={d} off={d} end={d} flags={x} first={d}", .{ c.gst_buffer_get_size(b), t(b[0].pts), t(b[0].dts), t(b[0].duration), t(b[0].offset), t(b[0].offset_end), b[0].mini_object.flags, first });
    c.gst_buffer_unref(b);
    return c.GST_FLOW_OK;
}

fn sinkEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    switch (ev[0].type) {
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(ev, &seg);
            note("  event segment fmt={d} rate={d} start={d} stop={d} time={d} pos={d} base={d} dur={d} flags={d}", .{ seg[0].format, seg[0].rate, t(seg[0].start), t(seg[0].stop), t(seg[0].time), t(seg[0].position), t(seg[0].base), t(seg[0].duration), seg[0].flags });
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            const s = c.gst_caps_to_string(caps);
            note("  event caps {s}", .{str(s)});
            c.g_free(s);
        },
        c.GST_EVENT_STREAM_START => {
            var id: [*c]const u8 = null;
            c.gst_event_parse_stream_start(ev, &id);
            var gid: c.guint = 0;
            note("  event stream-start group={d} idlen={d}", .{ c.gst_event_parse_group_id(ev, &gid), std.mem.len(id) });
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(ev, &tags);
            const s = c.gst_tag_list_to_string(tags);
            note("  event tag {s}", .{str(s)});
            c.g_free(s);
        },
        else => note("  event {s}", .{str(c.gst_event_type_get_name(ev[0].type))}),
    }
    return c.gst_pad_event_default(pad, parent, ev);
}

fn sinkInit(instance: [*c]c.GTypeInstance, klass: c.gpointer) callconv(.c) void {
    const templ = c.gst_element_class_get_pad_template(@ptrCast(@alignCast(klass)), "sink");
    const pad = c.gst_pad_new_from_template(templ, "sink");
    c.gst_pad_set_chain_function_full(pad, sinkChain, null, null);
    c.gst_pad_set_event_function_full(pad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(@alignCast(instance)), pad);
}

fn sinkClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string(sink_caps);
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "TestSink", "Sink", "s", "x");
}

var sink_caps: [*c]const u8 = "ANY";

fn sinkType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_element_get_type(), "TestRecordSink", @sizeOf(c.GstElementClass), sinkClass, @sizeOf(c.GstElement), sinkInit, 0);
    return S.v;
}

const BytesSrc = extern struct {
    parent: c.GstBaseSrc,
    total: u64,
    fail_at: i64,
    seekable: c.gboolean,
    start_ok: c.gboolean,
};

fn bs(s: anytype) *BytesSrc {
    return @ptrCast(@alignCast(s));
}

fn bytesStart(s: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    note("  vfunc start", .{});
    return bs(s).start_ok;
}

fn bytesStop(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    note("  vfunc stop", .{});
    return 1;
}

fn bytesSize(s: [*c]c.GstBaseSrc, size: [*c]u64) callconv(.c) c.gboolean {
    size.* = bs(s).total;
    return 1;
}

fn bytesSeekable(s: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return bs(s).seekable;
}

fn bytesFill(s: [*c]c.GstBaseSrc, off: u64, len: c.guint, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    if (bs(s).fail_at >= 0 and off >= @as(u64, @intCast(bs(s).fail_at))) return c.GST_FLOW_ERROR;
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_WRITE);
    for (0..info.size) |i| info.data[i] = @truncate(off + i);
    c.gst_buffer_unmap(b, &info);
    c.gst_buffer_set_size(b, len);
    b[0].offset = off;
    b[0].offset_end = off + len;
    return c.GST_FLOW_OK;
}

fn bytesDoSeek(s: [*c]c.GstBaseSrc, seg: [*c]c.GstSegment) callconv(.c) c.gboolean {
    note("  vfunc do_seek fmt={d} start={d} stop={d}", .{ seg[0].format, t(seg[0].start), t(seg[0].stop) });
    return bytes_parent.?.do_seek.?(s, seg);
}

var bytes_parent: ?*c.GstBaseSrcClass = null;

fn bytesClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    bytes_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const caps = c.gst_caps_from_string(src_caps);
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "BytesSrc", "Source", "b", "x");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.start = bytesStart;
    bc.stop = bytesStop;
    bc.get_size = bytesSize;
    bc.is_seekable = bytesSeekable;
    bc.fill = bytesFill;
    bc.do_seek = bytesDoSeek;
}

var src_caps: [*c]const u8 = "ANY";

fn bytesInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const b = bs(instance);
    b.total = 250;
    b.fail_at = -1;
    b.seekable = 1;
    b.start_ok = 1;
}

fn bytesType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_src_get_type(), "TestBytesSrc", @sizeOf(c.GstBaseSrcClass), bytesClass, @sizeOf(BytesSrc), bytesInit, 0);
    return S.v;
}

var push_count: u32 = 0;

fn pushCreate(s: [*c]c.GstPushSrc, out_buf: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    push_count += 1;
    if (push_count > 4) return c.GST_FLOW_EOS;
    const b = c.gst_buffer_new_allocate(null, 8, null);
    b[0].pts = push_count * 1000;
    b[0].duration = 1000;
    _ = s;
    out_buf.* = b;
    return c.GST_FLOW_OK;
}

fn pushClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string("audio/x-raw, rate=(int)[ 8000, 96000 ], channels=(int){ 2, 1 }");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "PushTest", "Source", "p", "x");
    const pc: *c.GstPushSrcClass = @ptrCast(@alignCast(k));
    pc.create = pushCreate;
}

fn pushInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_src_set_format(@ptrCast(@alignCast(instance)), c.GST_FORMAT_TIME);
}

fn pushType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_push_src_get_type(), "TestPushSrc", @sizeOf(c.GstPushSrcClass), pushClass, @sizeOf(c.GstPushSrc), pushInit, 0);
    return S.v;
}

fn messages(bus: ?*c.GstBus, until: c.GstMessageType) void {
    while (true) {
        const m = c.gst_bus_timed_pop(bus, c.GST_SECOND) orelse {
            out("  bus timeout", .{});
            return;
        };
        defer c.gst_message_unref(m);
        const ty = m[0].type;
        switch (ty) {
            c.GST_MESSAGE_ERROR => {
                var e: [*c]c.GError = null;
                var dbg: [*c]u8 = null;
                c.gst_message_parse_error(m, &e, &dbg);
                var details: [*c]const c.GstStructure = null;
                c.gst_message_parse_error_details(m, &details);
                const ds = if (details != null) c.gst_structure_to_string(details) else null;
                out("  msg error {s} code={d} {s} | {s} | {s}", .{ str(c.g_quark_to_string(e[0].domain)), e[0].code, str(e[0].message), str(dbg), str(ds) });
                c.g_free(ds);
                c.g_clear_error(&e);
                c.g_free(dbg);
            },
            c.GST_MESSAGE_STATE_CHANGED, c.GST_MESSAGE_STREAM_START, c.GST_MESSAGE_ASYNC_DONE, c.GST_MESSAGE_LATENCY, c.GST_MESSAGE_NEW_CLOCK, c.GST_MESSAGE_STREAM_STATUS => {},
            else => out("  msg {s} from {s}", .{ str(c.gst_message_type_get_name(ty)), str(@as([*c]c.GstObject, @ptrCast(@alignCast(m[0].src)))[0].name) }),
        }
        if (ty & until != 0) return;
    }
}

fn pipeline(src: [*c]c.GstElement) [*c]c.GstElement {
    const p = c.gst_pipeline_new("p");
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "sink", @as(?*anyopaque, null))));
    _ = c.gst_bin_add(@ptrCast(p), src);
    _ = c.gst_bin_add(@ptrCast(p), sink);
    out("  link {d}", .{c.gst_element_link(src, sink)});
    return p;
}

fn run(p: [*c]c.GstElement, label: []const u8) void {
    out("== {s}", .{label});
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    messages(bus, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    flushLog();
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus);
}

fn makeBytes(name: [*c]const u8) [*c]c.GstElement {
    return @ptrCast(@alignCast(c.g_object_new(bytesType(), "name", name, @as(?*anyopaque, null))));
}

fn queries(src: [*c]c.GstElement) void {
    const pad = c.gst_element_get_static_pad(src, "src");
    defer c.gst_object_unref(pad);
    var v: i64 = 0;
    out("  pos bytes {d} {d}", .{ c.gst_pad_query_position(pad, c.GST_FORMAT_BYTES, &v), v });
    out("  pos percent {d} {d}", .{ c.gst_pad_query_position(pad, c.GST_FORMAT_PERCENT, &v), v });
    out("  pos time {d} {d}", .{ c.gst_pad_query_position(pad, c.GST_FORMAT_TIME, &v), v });
    out("  dur bytes {d} {d}", .{ c.gst_pad_query_duration(pad, c.GST_FORMAT_BYTES, &v), v });
    out("  dur percent {d} {d}", .{ c.gst_pad_query_duration(pad, c.GST_FORMAT_PERCENT, &v), v });
    var q = c.gst_query_new_seeking(c.GST_FORMAT_BYTES);
    var sk: c.gboolean = 0;
    var a: i64 = 0;
    var b: i64 = 0;
    out("  seeking {d}", .{c.gst_pad_query(pad, q)});
    c.gst_query_parse_seeking(q, null, &sk, &a, &b);
    out("    {d} {d} {d}", .{ sk, a, b });
    c.gst_query_unref(q);
    q = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
    out("  seeking time {d}", .{c.gst_pad_query(pad, q)});
    c.gst_query_unref(q);
    q = c.gst_query_new_segment(c.GST_FORMAT_BYTES);
    out("  segment {d}", .{c.gst_pad_query(pad, q)});
    var rate: f64 = 0;
    var f: c.GstFormat = 0;
    c.gst_query_parse_segment(q, &rate, &f, &a, &b);
    out("    {d} {d} {d} {d}", .{ rate, f, a, b });
    c.gst_query_unref(q);
    q = c.gst_query_new_formats();
    var n: c.guint = 0;
    out("  formats {d}", .{c.gst_pad_query(pad, q)});
    c.gst_query_parse_n_formats(q, &n);
    out("    n {d}", .{n});
    c.gst_query_unref(q);
    out("  convert same {d} {d}", .{ c.gst_pad_query_convert(pad, c.GST_FORMAT_BYTES, 42, c.GST_FORMAT_BYTES, &v), v });
    out("  convert other {d}", .{c.gst_pad_query_convert(pad, c.GST_FORMAT_BYTES, 42, c.GST_FORMAT_TIME, &v)});
    q = c.gst_query_new_latency();
    var live: c.gboolean = 0;
    var mn: u64 = 0;
    var mx: u64 = 0;
    out("  latency {d}", .{c.gst_pad_query(pad, q)});
    c.gst_query_parse_latency(q, &live, &mn, &mx);
    out("    {d} {d} {d}", .{ live, mn, mx });
    c.gst_query_unref(q);
    q = c.gst_query_new_scheduling();
    out("  scheduling {d}", .{c.gst_pad_query(pad, q)});
    var flags: c.GstSchedulingFlags = 0;
    var mi: c.gint = 0;
    var ma: c.gint = 0;
    var al: c.gint = 0;
    c.gst_query_parse_scheduling(q, &flags, &mi, &ma, &al);
    out("    flags {d} {d} {d} {d} modes {d} pull {d}", .{ flags, mi, ma, al, c.gst_query_get_n_scheduling_modes(q), c.gst_query_has_scheduling_mode(q, c.GST_PAD_MODE_PULL) });
    c.gst_query_unref(q);
    q = c.gst_query_new_buffering(c.GST_FORMAT_PERCENT);
    out("  buffering {d}", .{c.gst_pad_query(pad, q)});
    var est: i64 = 0;
    c.gst_query_parse_buffering_range(q, &f, &a, &b, &est);
    out("    {d} {d} {d} {d}", .{ f, a, b, est });
    c.gst_query_unref(q);
    q = c.gst_query_new_buffering(c.GST_FORMAT_BYTES);
    out("  buffering bytes {d}", .{c.gst_pad_query(pad, q)});
    c.gst_query_parse_buffering_range(q, &f, &a, &b, &est);
    out("    {d} {d} {d} {d}", .{ f, a, b, est });
    c.gst_query_unref(q);
    const caps = c.gst_pad_query_caps(pad, null);
    const cs = c.gst_caps_to_string(caps);
    out("  caps {s}", .{str(cs)});
    c.g_free(cs);
    c.gst_caps_unref(caps);
    q = c.gst_query_new_uri();
    out("  uri {d}", .{c.gst_pad_query(pad, q)});
    c.gst_query_unref(q);
    q = c.gst_query_new_drain();
    out("  drain {d}", .{c.gst_pad_query(pad, q)});
    c.gst_query_unref(q);
}

fn props(e: [*c]c.GstElement) void {
    var bsz: c.guint = 0;
    var nb: c.gint = 0;
    var tf: c.gboolean = 0;
    var dt: c.gboolean = 0;
    var ae: c.gboolean = 0;
    c.g_object_get(e, "blocksize", &bsz, "num-buffers", &nb, "typefind", &tf, "do-timestamp", &dt, "automatic-eos", &ae, @as(?*anyopaque, null));
    out("  props blocksize={d} num-buffers={d} typefind={d} do-timestamp={d} automatic-eos={d}", .{ bsz, nb, tf, dt, ae });
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    out("types {s} {s} abstract {d} {d}", .{ str(c.g_type_name(c.gst_base_src_get_type())), str(c.g_type_name(c.gst_push_src_get_type())), c.g_type_test_flags(c.gst_base_src_get_type(), c.G_TYPE_FLAG_ABSTRACT), c.g_type_test_flags(c.gst_push_src_get_type(), c.G_TYPE_FLAG_ABSTRACT) });
    const s0 = makeBytes("s0");
    _ = c.gst_object_ref_sink(s0);
    props(s0);
    const b0: *c.GstBaseSrc = @ptrCast(@alignCast(s0));
    out("  fields live={d} blocksize={d} push={d} fmt={d} nb={d} left={d} flags={x}", .{ b0.is_live, b0.blocksize, b0.can_activate_push, b0.segment.format, b0.num_buffers, b0.num_buffers_left, b0.element.object.flags });
    out("  api live={d} async={d} blocksize={d} dots={d}", .{ c.gst_base_src_is_live(b0), c.gst_base_src_is_async(b0), c.gst_base_src_get_blocksize(b0), c.gst_base_src_get_do_timestamp(b0) });
    var live: c.gboolean = 0;
    var mn: u64 = 0;
    var mx: u64 = 0;
    out("  latency {d} {d} {d} {d}", .{ c.gst_base_src_query_latency(b0, &live, &mn, &mx), live, mn, mx });
    c.gst_base_src_set_do_timestamp(b0, 1);
    out("  dots fmt {d}", .{b0.segment.format});
    c.gst_base_src_set_do_timestamp(b0, 0);
    c.gst_base_src_set_format(b0, c.GST_FORMAT_BYTES);
    c.g_object_set(s0, "blocksize", @as(c.guint, 64), "num-buffers", @as(c.gint, 7), "automatic-eos", @as(c.gboolean, 0), @as(?*anyopaque, null));
    props(s0);
    out("  pool {d}", .{@intFromBool(c.gst_base_src_get_buffer_pool(b0) == null)});
    queries(s0);
    flushLog();
    const pad0 = c.gst_element_get_static_pad(s0, "src");
    out("  activate pull {d}", .{c.gst_pad_activate_mode(pad0, c.GST_PAD_MODE_PULL, 1)});
    flushLog();
    var gb: [*c]c.GstBuffer = null;
    for ([_][2]u64{ .{ 0, 10 }, .{ 100, 30 }, .{ 240, 30 }, .{ 250, 1 }, .{ 300, 5 } }) |r| {
        gb = null;
        const ret = c.gst_pad_get_range(pad0, r[0], @intCast(r[1]), &gb);
        if (ret == c.GST_FLOW_OK) {
            out("  range {d}+{d}: ok size {d} dts {d} off {d}", .{ r[0], r[1], c.gst_buffer_get_size(gb), t(gb[0].dts), t(gb[0].offset) });
            c.gst_buffer_unref(gb);
        } else out("  range {d}+{d}: {s}", .{ r[0], r[1], str(c.gst_flow_get_name(ret)) });
    }
    const provided = c.gst_buffer_new_allocate(null, 16, null);
    gb = provided;
    out("  range into {s} same {d}", .{ str(c.gst_flow_get_name(c.gst_pad_get_range(pad0, 5, 16, &gb))), @intFromBool(gb == provided) });
    c.gst_buffer_unref(gb);
    queries(s0);
    out("  deactivate {d}", .{c.gst_pad_activate_mode(pad0, c.GST_PAD_MODE_PULL, 0)});
    flushLog();
    gb = null;
    out("  range after stop {s}", .{str(c.gst_flow_get_name(c.gst_pad_get_range(pad0, 0, 1, &gb)))});
    c.gst_object_unref(pad0);
    c.gst_object_unref(s0);

    const s1 = makeBytes("s1");
    c.g_object_set(s1, "blocksize", @as(c.guint, 100), @as(?*anyopaque, null));
    const p1 = pipeline(s1);
    run(p1, "bytes push");
    c.gst_object_unref(p1);

    const s2 = makeBytes("s2");
    c.g_object_set(s2, "blocksize", @as(c.guint, 40), "num-buffers", @as(c.gint, 3), @as(?*anyopaque, null));
    const p2 = pipeline(s2);
    run(p2, "num-buffers");
    c.gst_object_unref(p2);

    const s3 = makeBytes("s3");
    c.g_object_set(s3, "blocksize", @as(c.guint, 60), @as(?*anyopaque, null));
    const p3 = pipeline(s3);
    out("== seek before start {d}", .{c.gst_element_send_event(s3, c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 100, c.GST_SEEK_TYPE_SET, 200))});
    run(p3, "pending seek");
    c.gst_object_unref(p3);

    const s4 = makeBytes("s4");
    bs(s4).fail_at = 100;
    c.g_object_set(s4, "blocksize", @as(c.guint, 50), @as(?*anyopaque, null));
    const p4 = pipeline(s4);
    run(p4, "fill error");
    c.gst_object_unref(p4);

    const s5 = makeBytes("s5");
    bs(s5).start_ok = 0;
    const p5 = pipeline(s5);
    out("== start fails", .{});
    out("  playing {d}", .{c.gst_element_set_state(p5, c.GST_STATE_PLAYING)});
    const bus5 = c.gst_element_get_bus(p5);
    messages(bus5, c.GST_MESSAGE_ERROR);
    c.gst_object_unref(bus5);
    _ = c.gst_element_set_state(p5, c.GST_STATE_NULL);
    flushLog();
    c.gst_object_unref(p5);

    const s6 = makeBytes("s6");
    c.g_object_set(s6, "blocksize", @as(c.guint, 1000), @as(?*anyopaque, null));
    const p6 = pipeline(s6);
    out("  paused {d}", .{c.gst_element_set_state(p6, c.GST_STATE_PAUSED)});
    _ = c.gst_element_get_state(p6, null, null, c.GST_CLOCK_TIME_NONE);
    c.g_usleep(100000);
    flushLog();
    out("== tag + eos events", .{});
    const tags = c.gst_tag_list_new_empty();
    c.gst_tag_list_add(tags, c.GST_TAG_MERGE_APPEND, "title", "hello", @as(?*anyopaque, null));
    out("  tag {d}", .{c.gst_element_send_event(s6, c.gst_event_new_tag(tags))});
    out("  eos {d}", .{c.gst_element_send_event(s6, c.gst_event_new_eos())});
    out("  seek nonseekable path {d}", .{c.gst_element_send_event(s6, c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 10, c.GST_SEEK_TYPE_NONE, -1))});
    const bus6 = c.gst_element_get_bus(p6);
    messages(bus6, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    c.gst_object_unref(bus6);
    flushLog();
    _ = c.gst_element_set_state(p6, c.GST_STATE_NULL);
    flushLog();
    c.gst_object_unref(p6);

    push_count = 0;
    src_caps = "ANY";
    sink_caps = "audio/x-raw, rate=(int)44100";
    const s7: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(pushType(), "name", "push", @as(?*anyopaque, null))));
    const p7 = pipeline(s7);
    run(p7, "push src negotiate");
    c.gst_object_unref(p7);

    push_count = 0;
    const s8: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(pushType(), "name", "live", @as(?*anyopaque, null))));
    c.gst_base_src_set_live(@ptrCast(@alignCast(s8)), 1);
    const p8 = pipeline(s8);
    out("== live", .{});
    out("  paused {d}", .{c.gst_element_set_state(p8, c.GST_STATE_PAUSED)});
    c.g_usleep(50000);
    flushLog();
    out("  playing {d}", .{c.gst_element_set_state(p8, c.GST_STATE_PLAYING)});
    const bus8 = c.gst_element_get_bus(p8);
    messages(bus8, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    c.gst_object_unref(bus8);
    flushLog();
    _ = c.gst_element_set_state(p8, c.GST_STATE_NULL);
    flushLog();
    c.gst_object_unref(p8);

    out("crit {d}", .{c.gst_base_src_is_live(null)});
    c.gst_base_src_set_blocksize(null, 1);
    out("crit {d}", .{c.gst_base_src_wait_playing(null)});
    out("done", .{});
}
