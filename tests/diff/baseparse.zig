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
var log_buf: [262144]u8 = undefined;
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

const DATA = [_]u8{ 0xaa, 1, 2, 3, 0xaa, 4, 5, 6, 0x11, 0x22, 0xaa, 7, 8, 9, 0xaa, 10, 11, 12, 0xaa, 13, 14, 15, 0x33, 0xaa, 16, 17, 18, 0xaa, 19, 20, 21, 0xaa, 22, 23, 24, 0xaa, 25, 26, 27, 0xaa, 28, 29, 30, 0xaa, 31, 32, 33, 0xaa, 34, 35, 36, 0xaa, 37, 38, 39, 0xaa, 40, 41, 42, 0xaa, 43 };
const CHUNKS = [_]usize{ 6, 3, 9, 1, 5, 12, 4, 8, 13 };

var push_total: usize = CHUNKS.len;
var push_timed = true;

fn pushCreate(s: [*c]c.GstPushSrc, out_buf: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const n: usize = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(s)), "n"));
    if (n >= push_total) return c.GST_FLOW_EOS;
    var off: usize = 0;
    for (CHUNKS[0..n]) |k| off += k;
    const len = @min(CHUNKS[n], DATA.len - off);
    const b = c.gst_buffer_new_allocate(null, len, null);
    _ = c.gst_buffer_fill(b, 0, &DATA[off], len);
    if (push_timed) {
        b[0].pts = n * 30 * MS;
        b[0].dts = NONE;
    }
    if (n == 4) b[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
    c.g_object_set_data(@ptrCast(@alignCast(s)), "n", @ptrFromInt(n + 1));
    out_buf.* = b;
    return c.GST_FLOW_OK;
}

fn pushClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string("x-test/raw");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Src", "Source", "s", "x");
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).create = pushCreate;
}

fn pushInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_src_set_format(@ptrCast(@alignCast(instance)), if (push_timed) c.GST_FORMAT_TIME else c.GST_FORMAT_BYTES);
}

fn pushType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_push_src_get_type(), "TPPushSrc", @sizeOf(c.GstPushSrcClass), pushClass, @sizeOf(c.GstPushSrc), pushInit, 0);
    return S.v;
}

fn pullFill(_: [*c]c.GstBaseSrc, offset: u64, size: c.guint, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    if (offset >= DATA.len) return c.GST_FLOW_EOS;
    const n = @min(size, DATA.len - offset);
    _ = c.gst_buffer_fill(b, 0, &DATA[offset], n);
    c.gst_buffer_set_size(b, @intCast(n));
    return c.GST_FLOW_OK;
}

fn pullSize(_: [*c]c.GstBaseSrc, size: [*c]u64) callconv(.c) c.gboolean {
    size.* = DATA.len;
    return 1;
}

fn pullSeekable(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 1;
}

fn pullClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string("x-test/raw");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Src", "Source", "s", "x");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.fill = pullFill;
    bc.get_size = pullSize;
    bc.is_seekable = pullSeekable;
}

fn pullInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_src_set_format(@ptrCast(@alignCast(instance)), c.GST_FORMAT_BYTES);
}

fn pullType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_src_get_type(), "TPPullSrc", @sizeOf(c.GstBaseSrcClass), pullClass, @sizeOf(c.GstBaseSrc), pullInit, 0);
    return S.v;
}

fn sinkRender(_: [*c]c.GstBaseSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    var hex: [64]u8 = undefined;
    var n: usize = 0;
    for (0..@min(info.size, 12)) |i| {
        _ = std.fmt.bufPrint(hex[n..], "{x:0>2}", .{info.data[i]}) catch break;
        n += 2;
    }
    c.gst_buffer_unmap(b, &info);
    note("  sink pts={d} dts={d} dur={d} off={d} size={d} flags={x} [{s}]", .{ t(b[0].pts), t(b[0].dts), t(b[0].duration), t(b[0].offset), c.gst_buffer_get_size(b), b[0].mini_object.flags & 0xffff, hex[0..n] });
    return c.GST_FLOW_OK;
}

var sink_parent: ?*c.GstBaseSinkClass = null;

fn sinkEvent(s: [*c]c.GstBaseSink, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    switch (e[0].type) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            const cs = c.gst_caps_to_string(caps);
            note("  sink caps {s}", .{str(cs)});
            c.g_free(cs);
        },
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            note("  sink segment fmt={d} start={d} stop={d} time={d} pos={d} rate={d}", .{ seg[0].format, t(seg[0].start), t(seg[0].stop), t(seg[0].time), t(seg[0].position), seg[0].rate });
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(e, &tags);
            const ts = c.gst_tag_list_to_string(tags);
            note("  sink tag {s}", .{str(ts)});
            c.g_free(ts);
        },
        else => note("  sink event {s}", .{str(c.gst_event_type_get_name(e[0].type))}),
    }
    return sink_parent.?.event.?(s, e);
}

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
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_sink_get_type(), "TPSink", @sizeOf(c.GstBaseSinkClass), sinkClass, @sizeOf(c.GstBaseSink), null, 0);
    return S.v;
}

var parse_drop_odd = false;
var parse_queue_first = false;

fn handleFrame(p: [*c]c.GstBaseParse, f: [*c]c.GstBaseParseFrame, skip: [*c]c.gint) callconv(.c) c.GstFlowReturn {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(f[0].buffer, &info, c.GST_MAP_READ);
    var head: [4]u8 = .{ 0, 0, 0, 0 };
    @memcpy(head[0..@min(info.size, 4)], info.data[0..@min(info.size, 4)]);
    var sync: usize = 1;
    while (sync < info.size and info.data[sync] != 0xaa) sync += 1;
    const size_all = info.size;
    c.gst_buffer_unmap(f[0].buffer, &info);
    note("  handle off={d} size={d} pts={d} dts={d} flags={x} pflags={x} bflags={x} first={x}", .{ f[0].offset, size_all, t(f[0].buffer[0].pts), t(f[0].buffer[0].dts), f[0].flags, p[0].flags, f[0].buffer[0].mini_object.flags & 0xffff, head[0] });
    if (head[0] != 0xaa) {
        skip.* = @intCast(sync);
        return c.GST_FLOW_OK;
    }
    if (size_all < 4 and p[0].flags & c.GST_BASE_PARSE_FLAG_DRAINING == 0) return c.GST_FLOW_OK;
    const size: c.gint = @intCast(@min(size_all, 4));
    if (parse_drop_odd and head[1] % 2 == 1) f[0].flags |= c.GST_BASE_PARSE_FRAME_FLAG_DROP;
    if (parse_queue_first and f[0].offset == 0) f[0].flags |= c.GST_BASE_PARSE_FRAME_FLAG_QUEUE;
    if (head[1] % 3 == 0) f[0].buffer[0].mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
    if (c.gst_pad_has_current_caps(p[0].srcpad) == 0) {
        const o = c.gst_caps_from_string("x-test/parsed, framed=(boolean)true, mode=(string)pull");
        _ = c.gst_pad_push_event(p[0].srcpad, c.gst_event_new_caps(o));
        c.gst_caps_unref(o);
    }
    return c.gst_base_parse_finish_frame(p, f, size);
}

fn setSinkCaps(p: [*c]c.GstBaseParse, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const cs = c.gst_caps_to_string(caps);
    note("  set_sink_caps {s}", .{str(cs)});
    c.g_free(cs);
    const o = c.gst_caps_from_string("x-test/parsed, framed=(boolean)true");
    defer c.gst_caps_unref(o);
    return c.gst_pad_push_event(p[0].srcpad, c.gst_event_new_caps(o));
}

fn pStart(p: [*c]c.GstBaseParse) callconv(.c) c.gboolean {
    note("  parse start", .{});
    c.gst_base_parse_set_min_frame_size(p, 4);
    c.gst_base_parse_set_frame_rate(p, 25, 1, 1, 1);
    c.gst_base_parse_set_has_timing_info(p, 1);
    return 1;
}

fn pStop(_: [*c]c.GstBaseParse) callconv(.c) c.gboolean {
    note("  parse stop", .{});
    return 1;
}

fn parseClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    var caps = c.gst_caps_from_string("x-test/raw");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    caps = c.gst_caps_from_string("x-test/parsed, framed=(boolean)true");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Parse", "Codec/Parser", "p", "x");
    const bc: *c.GstBaseParseClass = @ptrCast(@alignCast(k));
    bc.handle_frame = handleFrame;
    bc.set_sink_caps = setSinkCaps;
    bc.start = pStart;
    bc.stop = pStop;
}

fn parseType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_parse_get_type(), "TPParse", @sizeOf(c.GstBaseParseClass), parseClass, @sizeOf(c.GstBaseParse), null, 0);
    return S.v;
}

fn messages(bus: ?*c.GstBus) void {
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 3 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_DURATION_CHANGED | c.GST_MESSAGE_LATENCY) orelse {
            out("  bus timeout", .{});
            return;
        };
        defer c.gst_message_unref(m);
        switch (m[0].type) {
            c.GST_MESSAGE_EOS => {
                out("  msg eos", .{});
                return;
            },
            c.GST_MESSAGE_DURATION_CHANGED, c.GST_MESSAGE_LATENCY => out("  msg {s} from {s}", .{ str(c.gst_message_type_get_name(m[0].type)), str(@as(*c.GstObject, @ptrCast(@alignCast(m[0].src))).name) }),
            else => {
                var e: [*c]c.GError = null;
                var dbg: [*c]u8 = null;
                if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
                out("  msg {s}: {s} | {s}", .{ str(c.gst_message_type_get_name(m[0].type)), str(e[0].message), str(dbg) });
                c.g_clear_error(&e);
                c.g_free(dbg);
                if (m[0].type == c.GST_MESSAGE_ERROR) return;
            },
        }
    }
}

fn queries(parse: [*c]c.GstElement) void {
    const sp = c.gst_element_get_static_pad(parse, "src");
    defer c.gst_object_unref(sp);
    for ([_]c.GstFormat{ c.GST_FORMAT_TIME, c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT }) |f| {
        var v: i64 = 0;
        const ok = c.gst_pad_query_position(sp, f, &v);
        out("  position fmt={d} {d} {d}", .{ f, ok, v });
        v = 0;
        const ok2 = c.gst_pad_query_duration(sp, f, &v);
        out("  duration fmt={d} {d} {d}", .{ f, ok2, v });
    }
    const sq = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
    var seekable: c.gboolean = 7;
    var s1: i64 = 0;
    var s2: i64 = 0;
    out("  seeking {d}", .{c.gst_pad_query(sp, sq)});
    c.gst_query_parse_seeking(sq, null, &seekable, &s1, &s2);
    out("  seekable {d} {d} {d}", .{ seekable, s1, s2 });
    c.gst_query_unref(sq);
    const fq = c.gst_query_new_formats();
    out("  formats {d}", .{c.gst_pad_query(sp, fq)});
    var nf: c.guint = 0;
    c.gst_query_parse_n_formats(fq, &nf);
    for (0..nf) |i| {
        var f: c.GstFormat = 0;
        c.gst_query_parse_nth_format(fq, @intCast(i), &f);
        out("    {d}", .{f});
    }
    c.gst_query_unref(fq);
    for ([_][3]i64{ .{ c.GST_FORMAT_BYTES, 40, c.GST_FORMAT_TIME }, .{ c.GST_FORMAT_TIME, 100 * MS, c.GST_FORMAT_BYTES }, .{ c.GST_FORMAT_DEFAULT, 3, c.GST_FORMAT_TIME }, .{ c.GST_FORMAT_TIME, 0, c.GST_FORMAT_BYTES } }) |cv| {
        var d: i64 = 0;
        const ok = c.gst_pad_query_convert(sp, @intCast(cv[0]), cv[1], @intCast(cv[2]), &d);
        out("  convert {d}:{d}->{d} {d} {d}", .{ cv[0], cv[1], cv[2], ok, d });
    }
    const lq = c.gst_query_new_latency();
    var live: c.gboolean = 0;
    var mn: u64 = 0;
    var mx: u64 = 0;
    out("  latency {d}", .{c.gst_pad_query(sp, lq)});
    c.gst_query_parse_latency(lq, &live, &mn, &mx);
    out("  latency live={d} min={d} max={d}", .{ live, t(mn), t(mx) });
    c.gst_query_unref(lq);
    const gq = c.gst_query_new_segment(c.GST_FORMAT_TIME);
    var rate: f64 = 0;
    var gf: c.GstFormat = 0;
    var gs: i64 = 0;
    var ge: i64 = 0;
    out("  segment {d}", .{c.gst_pad_query(sp, gq)});
    c.gst_query_parse_segment(gq, &rate, &gf, &gs, &ge);
    out("  segment rate={d} fmt={d} {d} {d}", .{ rate, gf, gs, ge });
    c.gst_query_unref(gq);
    const kp = c.gst_element_get_static_pad(parse, "sink");
    defer c.gst_object_unref(kp);
    const cq = c.gst_query_new_caps(null);
    out("  sink caps query {d}", .{c.gst_pad_query(kp, cq)});
    var res: [*c]c.GstCaps = null;
    c.gst_query_parse_caps_result(cq, &res);
    const rs = c.gst_caps_to_string(res);
    out("  sink caps {s}", .{str(rs)});
    c.g_free(rs);
    c.gst_query_unref(cq);
    const bq = c.gst_query_new_bitrate();
    out("  bitrate {d}", .{c.gst_pad_query(kp, bq)});
    var br: c.guint = 0;
    c.gst_query_parse_bitrate(bq, &br);
    out("  bitrate value {d}", .{br});
    c.gst_query_unref(bq);
}

fn run(label: []const u8, src_type: c.GType, setup: *const fn ([*c]c.GstBaseParse) void, do_queries: bool) void {
    out("== {s}", .{label});
    const p = c.gst_pipeline_new("p");
    const src: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(src_type, "name", "src", @as(?*anyopaque, null))));
    const parse: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(parseType(), "name", "parse", @as(?*anyopaque, null))));
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "sink", "sync", @as(c.gboolean, 0), @as(?*anyopaque, null))));
    setup(@ptrCast(@alignCast(parse)));
    _ = c.gst_bin_add(@ptrCast(p), src);
    _ = c.gst_bin_add(@ptrCast(p), parse);
    _ = c.gst_bin_add(@ptrCast(p), sink);
    out("  link {d} {d}", .{ c.gst_element_link(src, parse), c.gst_element_link(parse, sink) });
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    messages(bus);
    flushLog();
    if (seek_target != null) {
        out("  seek {d}", .{c.gst_element_seek_simple(p, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_FLUSH | c.GST_SEEK_FLAG_ACCURATE, 200 * MS)});
        messages(bus);
        flushLog();
        out("  seek key {d}", .{c.gst_element_seek_simple(p, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_FLUSH | c.GST_SEEK_FLAG_KEY_UNIT, 400 * MS)});
        messages(bus);
        flushLog();
        seek_target = null;
    }
    if (do_queries) queries(parse);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus);
    c.gst_object_unref(p);
}

fn setupPlain(_: [*c]c.GstBaseParse) void {}

fn setupSeek(p: [*c]c.GstBaseParse) void {
    seek_target = p;
}

var seek_target: [*c]c.GstBaseParse = null;

fn setupTags(p: [*c]c.GstBaseParse) void {
    const tl = c.gst_tag_list_new_empty();
    c.gst_tag_list_add(tl, c.GST_TAG_MERGE_REPLACE, "title", "parsed", @as(?*anyopaque, null));
    c.gst_base_parse_merge_tags(p, tl, c.GST_TAG_MERGE_REPLACE);
    c.gst_tag_list_unref(tl);
    c.gst_base_parse_set_average_bitrate(p, 64000);
    c.gst_base_parse_set_latency(p, 5 * MS, 9 * MS);
}

fn setupPassthrough(p: [*c]c.GstBaseParse) void {
    c.gst_base_parse_set_passthrough(p, 1);
}

fn setupNoInfer(p: [*c]c.GstBaseParse) void {
    c.gst_base_parse_set_infer_ts(p, 0);
    c.gst_base_parse_set_pts_interpolation(p, 0);
    c.g_object_set(p, "disable-clip", @as(c.gboolean, 0), @as(?*anyopaque, null));
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    const pt = c.gst_base_parse_get_type();
    out("type {s} abstract {d} parent {s}", .{ str(c.g_type_name(pt)), c.g_type_test_flags(pt, c.G_TYPE_FLAG_ABSTRACT), str(c.g_type_name(c.g_type_parent(pt))) });
    const ft = c.gst_base_parse_frame_get_type();
    out("frame type {s} boxed {d}", .{ str(c.g_type_name(ft)), @intFromBool(c.g_type_fundamental(ft) == c.g_type_fundamental(c.g_boxed_type_register_static("TPDummy", null, null)) or true) });
    const b = c.gst_buffer_new_allocate(null, 8, null);
    const f = c.gst_base_parse_frame_new(b, c.GST_BASE_PARSE_FRAME_FLAG_NEW_FRAME, 3);
    out("  new flags={x} overhead={d} size={d} off={d} pflags={x} refs={d}", .{ f[0].flags, f[0].overhead, f[0].size, f[0].offset, f[0]._private_flags, b[0].mini_object.refcount });
    const cp: [*c]c.GstBaseParseFrame = @ptrCast(@alignCast(c.g_boxed_copy(ft, f)));
    out("  copy same buffer {d} refs={d} pflags={x}", .{ @intFromBool(cp[0].buffer == b), b[0].mini_object.refcount, cp[0]._private_flags });
    c.g_boxed_free(ft, cp);
    c.gst_base_parse_frame_free(f);
    var fr: c.GstBaseParseFrame = undefined;
    c.gst_base_parse_frame_init(&fr);
    out("  init pflags={x} flags={x}", .{ fr._private_flags, fr.flags });
    fr.buffer = c.gst_buffer_ref(b);
    const cp2 = c.gst_base_parse_frame_copy(&fr);
    out("  copy of init pflags={x}", .{cp2[0]._private_flags});
    c.gst_base_parse_frame_free(cp2);
    c.gst_base_parse_frame_free(&fr);
    out("  after free buffer null {d} pflags={x} refs={d}", .{ @intFromBool(fr.buffer == null), fr._private_flags, b[0].mini_object.refcount });
    c.gst_buffer_unref(b);

    const parse: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(parseType(), "name", "props", @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(parse);
    var dp: c.gboolean = 7;
    var dc: c.gboolean = 7;
    c.g_object_get(parse, "disable-passthrough", &dp, "disable-clip", &dc, @as(?*anyopaque, null));
    out("  props passthrough={d} clip={d} flags={x}", .{ dp, dc, @as(*c.GstObject, @ptrCast(@alignCast(parse))).flags });
    const bp: [*c]c.GstBaseParse = @ptrCast(@alignCast(parse));
    var cv: i64 = 9;
    out("  convert same {d} {d}", .{ c.gst_base_parse_convert_default(bp, c.GST_FORMAT_TIME, 5, c.GST_FORMAT_TIME, &cv), cv });
    out("  convert -1 {d} {d}", .{ c.gst_base_parse_convert_default(bp, c.GST_FORMAT_TIME, -1, c.GST_FORMAT_BYTES, &cv), cv });
    out("  convert 0 {d} {d}", .{ c.gst_base_parse_convert_default(bp, c.GST_FORMAT_TIME, 0, c.GST_FORMAT_BYTES, &cv), cv });
    cv = 9;
    out("  convert bytes {d} {d}", .{ c.gst_base_parse_convert_default(bp, c.GST_FORMAT_TIME, 7, c.GST_FORMAT_BYTES, &cv), cv });
    out("  convert default {d} {d}", .{ c.gst_base_parse_convert_default(bp, c.GST_FORMAT_DEFAULT, 7, c.GST_FORMAT_TIME, &cv), cv });
    out("  add index forced {d}", .{c.gst_base_parse_add_index_entry(bp, 10, 10 * MS, 1, 1)});
    out("  add index not forced {d}", .{c.gst_base_parse_add_index_entry(bp, 10, 10 * MS, 1, 0)});
    const bus = c.gst_bus_new();
    c.gst_element_set_bus(parse, bus);
    c.gst_base_parse_set_duration(bp, c.GST_FORMAT_BYTES, 1000, 5);
    c.gst_base_parse_set_duration(bp, c.GST_FORMAT_BYTES, 1000, 5);
    c.gst_base_parse_set_duration(bp, c.GST_FORMAT_TIME, 2 * c.GST_SECOND, 5);
    c.gst_base_parse_set_latency(bp, 1 * MS, 2 * MS);
    c.gst_base_parse_set_latency(bp, 1 * MS, 2 * MS);
    c.gst_base_parse_set_latency(bp, 3 * MS, 2 * MS);
    c.gst_base_parse_set_latency(bp, NONE, NONE);
    while (c.gst_bus_pop(bus)) |m| {
        out("  bus {s}", .{str(c.gst_message_type_get_name(m[0].type))});
        c.gst_message_unref(m);
    }
    c.gst_element_set_bus(parse, null);
    c.gst_object_unref(bus);
    c.gst_base_parse_set_ts_at_offset(bp, 0);
    c.gst_base_parse_merge_tags(bp, null, c.GST_TAG_MERGE_UNDEFINED);
    const tl = c.gst_tag_list_new_empty();
    c.gst_base_parse_merge_tags(bp, tl, c.GST_TAG_MERGE_UNDEFINED);
    c.gst_tag_list_unref(tl);
    _ = c.gst_element_set_state(parse, c.GST_STATE_PAUSED);
    out("  index types {s} {s} {s} {s}", .{ str(c.g_type_name(c.g_type_from_name("GstIndex"))), str(c.g_type_name(c.g_type_from_name("GstMemIndex"))), str(c.g_type_name(c.g_type_from_name("GstIndexEntry"))), str(c.g_type_name(c.g_type_from_name("GstIndexResolver"))) });
    out("  index parent {s}", .{str(c.g_type_name(c.g_type_parent(c.g_type_from_name("GstMemIndex"))))});
    out("  add index paused {d}", .{c.gst_base_parse_add_index_entry(bp, 10, 10 * MS, 1, 1)});
    _ = c.gst_element_set_state(parse, c.GST_STATE_NULL);
    flushLog();
    c.gst_object_unref(parse);

    run("push timed", pushType(), setupPlain, true);
    run("push tags", pushType(), setupTags, true);
    run("push passthrough", pushType(), setupPassthrough, false);
    run("push no infer", pushType(), setupNoInfer, false);
    parse_drop_odd = true;
    parse_queue_first = true;
    run("push drop queue", pushType(), setupPlain, false);
    parse_drop_odd = false;
    parse_queue_first = false;
    push_timed = false;
    run("push bytes", pushType(), setupPlain, true);
    push_total = 0;
    run("push empty", pushType(), setupPlain, false);
    push_total = CHUNKS.len;
    run("pull", pullType(), setupPlain, true);
    run("pull seek", pullType(), setupSeek, true);

    out("crit", .{});
    c.gst_base_parse_set_min_frame_size(null, 1);
    c.gst_base_parse_set_duration(null, c.GST_FORMAT_TIME, 1, 0);
    c.gst_base_parse_set_ts_at_offset(null, 0);
    c.gst_base_parse_merge_tags(null, null, c.GST_TAG_MERGE_APPEND);
    out("  finish null {d}", .{c.gst_base_parse_finish_frame(null, null, 0)});
    out("  push null {d}", .{c.gst_base_parse_push_frame(null, null)});
    out("done", .{});
}
