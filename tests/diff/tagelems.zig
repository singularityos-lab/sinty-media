const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const NONE = @as(?*anyopaque, null);
const PNG = "\x89PNG\r\n\x1a\n";

fn findPng(tf: [*c]c.GstTypeFind, _: c.gpointer) callconv(.c) void {
    const d = c.gst_type_find_peek(tf, 0, 8);
    if (d != null and std.mem.eql(u8, d[0..8], PNG)) c.gst_type_find_suggest_empty_simple(tf, c.GST_TYPE_FIND_MAXIMUM, "image/png");
}

var blob: [16384]u8 = undefined;
var blob_len: usize = 0;

fn put(d: []const u8) void {
    @memcpy(blob[blob_len..][0..d.len], d);
    blob_len += d.len;
}

fn putU32(v: u32) void {
    std.mem.writeInt(u32, blob[blob_len..][0..4], v, .big);
    blob_len += 4;
}

fn makeBlob(start: ?[]const u8, content: usize, end: ?[]const u8) void {
    blob_len = 0;
    if (start) |s| {
        put("STAG");
        putU32(@intCast(8 + s.len));
        put(s);
    }
    if (content > 0) {
        put(PNG);
        var i: usize = 8;
        while (i < content) : (i += 1) put(&[_]u8{@truncate(i *% 7)});
    }
    if (end) |e| {
        put(e);
        put("ETAG");
        putU32(@intCast(8 + e.len));
    }
}

fn identify(_: [*c]c.GstTagDemux, b: [*c]c.GstBuffer, start: c.gboolean, size: [*c]c.guint) callconv(.c) c.gboolean {
    var h: [8]u8 = undefined;
    if (c.gst_buffer_extract(b, 0, &h, 8) < 8) return 0;
    if (start != 0) {
        if (!std.mem.eql(u8, h[0..4], "STAG")) return 0;
        size.* = 8;
    } else {
        if (!std.mem.eql(u8, h[0..4], "ETAG")) return 0;
        size.* = std.mem.readInt(u32, h[4..8], .big);
    }
    out("  identify start={d} size={d}", .{ start, size.* });
    return 1;
}

fn parseTag(_: [*c]c.GstTagDemux, b: [*c]c.GstBuffer, start: c.gboolean, size: [*c]c.guint, tags: [*c][*c]c.GstTagList) callconv(.c) c.GstTagDemuxResult {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &info);
    out("  parse start={d} size={d} have={d} offset={d}", .{ start, size.*, info.size, @as(i64, @bitCast(b.*.offset)) });
    if (start != 0) {
        const claimed = std.mem.readInt(u32, info.data[4..8], .big);
        if (size.* != claimed) {
            size.* = claimed;
            return c.GST_TAG_DEMUX_RESULT_AGAIN;
        }
        const t = c.g_strndup(@ptrCast(info.data + 8), info.size - 8);
        tags.* = c.gst_tag_list_new(c.GST_TAG_TITLE, t, NONE);
        c.g_free(t);
        return c.GST_TAG_DEMUX_RESULT_OK;
    }
    const t = c.g_strndup(@ptrCast(info.data), info.size - 8);
    defer c.g_free(t);
    tags.* = c.gst_tag_list_new(c.GST_TAG_ARTIST, t, c.GST_TAG_TITLE, "end title", NONE);
    if (c.g_str_has_prefix(t, "broken") != 0) {
        size.* -= 2;
        return c.GST_TAG_DEMUX_RESULT_BROKEN_TAG;
    }
    return c.GST_TAG_DEMUX_RESULT_OK;
}

fn demuxClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const tk: *c.GstTagDemuxClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, c.gst_caps_new_any()));
    tk.min_start_size = 8;
    tk.min_end_size = 8;
    tk.identify_tag = identify;
    tk.parse_tag = parseTag;
}

var lock = std.mem.zeroes(c.GMutex);
var cond = std.mem.zeroes(c.GCond);
var got_eos = false;

fn sinkChain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    var sum: u32 = 0;
    for (info.data[0..info.size]) |x| sum = sum *% 31 +% x;
    out("  buffer offset={d} end={d} size={d} sum={x} head={x}", .{ @as(i64, @bitCast(b.*.offset)), @as(i64, @bitCast(b.*.offset_end)), info.size, sum, info.data[0..@min(4, info.size)] });
    c.gst_buffer_unmap(b, &info);
    c.gst_buffer_unref(b);
    return c.GST_FLOW_OK;
}

fn showEvent(prefix: []const u8, ev: [*c]c.GstEvent) void {
    const s = c.gst_event_get_structure(ev);
    const st = if (s != null) c.gst_structure_to_string(s) else null;
    out("  {s} {s} {s}", .{ prefix, str(c.gst_event_type_get_name(ev.*.type)), str(st) });
    c.g_free(st);
}

fn sinkEvent(_: ?*c.GstPad, _: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (ev.*.type == c.GST_EVENT_STREAM_START) {
        out("  event stream-start", .{});
    } else showEvent("event", ev);
    if (ev.*.type == c.GST_EVENT_EOS) {
        c.g_mutex_lock(&lock);
        got_eos = true;
        c.g_cond_signal(&cond);
        c.g_mutex_unlock(&lock);
    }
    c.gst_event_unref(ev);
    return 1;
}

fn upEvent(_: ?*c.GstPad, _: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    showEvent("upstream", ev);
    c.gst_event_unref(ev);
    return 1;
}

var pull_ok = true;

fn upQuery(_: ?*c.GstPad, _: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    switch (q.*.type) {
        c.GST_QUERY_SCHEDULING => {
            c.gst_query_set_scheduling(q, c.GST_SCHEDULING_FLAG_SEEKABLE, 1, -1, 0);
            if (pull_ok) c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PULL);
            c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
            return 1;
        },
        c.GST_QUERY_DURATION => {
            var f: c.GstFormat = 0;
            c.gst_query_parse_duration(q, &f, null);
            if (f != c.GST_FORMAT_BYTES) return 0;
            c.gst_query_set_duration(q, f, @intCast(blob_len));
            return 1;
        },
        c.GST_QUERY_POSITION => {
            c.gst_query_set_position(q, c.GST_FORMAT_BYTES, 100);
            return 1;
        },
        else => return 0,
    }
}

fn upRange(_: ?*c.GstPad, _: [*c]c.GstObject, offset: u64, length: c.guint, b: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    out("  pull {d}+{d}", .{ offset, length });
    if (offset >= blob_len) return c.GST_FLOW_EOS;
    const n = @min(length, blob_len - offset);
    const nb = c.gst_buffer_new_allocate(null, n, null);
    _ = c.gst_buffer_fill(nb, 0, &blob[offset], n);
    nb.*.offset = offset;
    b[0] = nb;
    return c.GST_FLOW_OK;
}

fn drainBus(bus: ?*c.GstBus) void {
    while (true) {
        const m = c.gst_bus_pop(bus);
        if (m == null) return;
        if (m.*.type == c.GST_MESSAGE_ERROR) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &e, &dbg);
            out("  bus error {s} {d}: {s} | {s}", .{ str(c.g_quark_to_string(e.*.domain)), e.*.code, str(e.*.message), str(dbg) });
            c.g_error_free(e);
            c.g_free(dbg);
        } else out("  bus {s}", .{str(c.gst_message_type_get_name(m.*.type))});
        c.gst_message_unref(m);
    }
}

const Rig = struct { e: [*c]c.GstElement, up: ?*c.GstPad, down: ?*c.GstPad, bus: ?*c.GstBus };

fn rig(t: c.GType) Rig {
    const e: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(t, null)));
    const bus = c.gst_bus_new();
    c.gst_element_set_bus(e, bus);
    const up = c.gst_pad_new("up", c.GST_PAD_SRC);
    c.gst_pad_set_event_function_full(up, upEvent, null, null);
    c.gst_pad_set_query_function_full(up, upQuery, null, null);
    c.gst_pad_set_getrange_function_full(up, upRange, null, null);
    const down = c.gst_pad_new("down", c.GST_PAD_SINK);
    c.gst_pad_set_chain_function_full(down, sinkChain, null, null);
    c.gst_pad_set_event_function_full(down, sinkEvent, null, null);
    _ = c.gst_pad_link(up, c.gst_element_get_static_pad(e, "sink"));
    _ = c.gst_pad_link(c.gst_element_get_static_pad(e, "src"), down);
    return .{ .e = e, .up = up, .down = down, .bus = bus };
}

fn done(r: Rig) void {
    _ = c.gst_element_set_state(r.e, c.GST_STATE_NULL);
    drainBus(r.bus);
    c.gst_object_unref(r.e);
    c.gst_object_unref(r.up);
    c.gst_object_unref(r.down);
    c.gst_object_unref(r.bus);
}

fn pushRun(label: []const u8, t: c.GType, chunk: usize, offsets: bool, time_seg: bool) void {
    out("{s}", .{label});
    pull_ok = false;
    const r = rig(t);
    _ = c.gst_pad_set_active(r.down, 1);
    _ = c.gst_pad_set_active(r.up, 1);
    _ = c.gst_element_set_state(r.e, c.GST_STATE_PAUSED);
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_stream_start("s1"));
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, if (time_seg) c.GST_FORMAT_TIME else c.GST_FORMAT_BYTES);
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_segment(&seg));
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new_empty("early")));
    var off: usize = 0;
    while (off < blob_len) : (off += chunk) {
        const n = @min(chunk, blob_len - off);
        const b = c.gst_buffer_new_allocate(null, n, null);
        _ = c.gst_buffer_fill(b, 0, &blob[off], n);
        if (offsets) b.*.offset = off;
        if (time_seg) {
            b.*.pts = off * 1000;
            b.*.duration = n * 1000;
        }
        const fr = c.gst_pad_push(r.up, b);
        out("  push {d} -> {s}", .{ off, str(c.gst_flow_get_name(fr)) });
        if (fr != c.GST_FLOW_OK) break;
    }
    var q = c.gst_query_new_duration(c.GST_FORMAT_BYTES);
    var dur: i64 = 0;
    if (c.gst_pad_peer_query(r.down, q) != 0) c.gst_query_parse_duration(q, null, &dur);
    out("  duration {d}", .{dur});
    c.gst_query_unref(q);
    q = c.gst_query_new_position(c.GST_FORMAT_BYTES);
    if (c.gst_pad_peer_query(r.down, q) != 0) c.gst_query_parse_position(q, null, &dur);
    out("  position {d}", .{dur});
    c.gst_query_unref(q);
    _ = c.gst_pad_push_event(r.down, c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 10, c.GST_SEEK_TYPE_END, 0));
    _ = c.gst_pad_push_event(r.down, c.gst_event_new_seek(1.0, c.GST_FORMAT_TIME, 0, c.GST_SEEK_TYPE_SET, 5, c.GST_SEEK_TYPE_NONE, -1));
    _ = c.gst_pad_push_event(r.down, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_UPSTREAM, c.gst_structure_new_empty("upward")));
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_eos());
    drainBus(r.bus);
    done(r);
}

fn waitEos() void {
    c.g_mutex_lock(&lock);
    const end = c.g_get_monotonic_time() + 5 * c.G_TIME_SPAN_SECOND;
    while (!got_eos) {
        if (c.g_cond_wait_until(&cond, &lock, end) == 0) break;
    }
    got_eos = false;
    c.g_mutex_unlock(&lock);
}

fn pullRun(label: []const u8, t: c.GType) void {
    out("{s}", .{label});
    pull_ok = true;
    got_eos = false;
    const r = rig(t);
    _ = c.gst_pad_set_active(r.down, 1);
    _ = c.gst_element_set_state(r.e, c.GST_STATE_PAUSED);
    waitEos();
    drainBus(r.bus);
    done(r);
}

fn downstreamPull(label: []const u8, t: c.GType) void {
    out("{s}", .{label});
    pull_ok = true;
    const r = rig(t);
    const src = c.gst_element_get_static_pad(r.e, "src");
    out("  activate {d}", .{c.gst_pad_activate_mode(src, c.GST_PAD_MODE_PULL, 1)});
    var off: u64 = 0;
    while (true) {
        var b: [*c]c.GstBuffer = null;
        const fr = c.gst_pad_get_range(src, off, 3000, &b);
        out("  range {d} -> {s}", .{ off, str(c.gst_flow_get_name(fr)) });
        if (fr != c.GST_FLOW_OK) break;
        off += c.gst_buffer_get_size(b);
        _ = sinkChain(null, null, b);
    }
    const q = c.gst_query_new_duration(c.GST_FORMAT_BYTES);
    var dur: i64 = 0;
    if (c.gst_pad_query(src, q) != 0) c.gst_query_parse_duration(q, null, &dur);
    out("  duration {d}", .{dur});
    c.gst_query_unref(q);
    _ = c.gst_pad_activate_mode(src, c.GST_PAD_MODE_PULL, 0);
    c.gst_object_unref(src);
    drainBus(r.bus);
    done(r);
}

fn renderStart(_: [*c]c.GstTagMux, l: [*c]const c.GstTagList) callconv(.c) [*c]c.GstBuffer {
    const s = c.gst_tag_list_to_string(l);
    defer c.g_free(s);
    out("  render start {s}", .{str(s)});
    const t = c.g_strdup_printf("HEAD[%s]", s);
    return c.gst_buffer_new_wrapped(t, c.strlen(t));
}

fn renderEnd(_: [*c]c.GstTagMux, l: [*c]const c.GstTagList) callconv(.c) [*c]c.GstBuffer {
    out("  render end {d}", .{c.gst_tag_list_n_tags(l)});
    const t = c.g_strdup("TAIL");
    return c.gst_buffer_new_wrapped(t, 4);
}

fn muxClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const mk: *c.GstTagMuxClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, c.gst_caps_new_any()));
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, c.gst_caps_new_empty_simple("application/x-test-tagged")));
    mk.render_start_tag = renderStart;
    mk.render_end_tag = renderEnd;
}

fn bareClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const mk: *c.GstTagMuxClass = @ptrCast(@alignCast(k));
    mk.render_start_tag = null;
    mk.render_end_tag = renderEnd;
}

fn muxRun(label: []const u8, t: c.GType, setter: bool) void {
    out("{s}", .{label});
    const r = rig(t);
    _ = c.gst_pad_set_active(r.down, 1);
    _ = c.gst_pad_set_active(r.up, 1);
    _ = c.gst_element_set_state(r.e, c.GST_STATE_PAUSED);
    if (setter) {
        c.gst_tag_setter_add_tags(@ptrCast(r.e), c.GST_TAG_MERGE_APPEND, c.GST_TAG_ALBUM, "Setter Album", c.GST_TAG_TITLE, "Setter Title", NONE);
        c.gst_tag_setter_set_tag_merge_mode(@ptrCast(r.e), c.GST_TAG_MERGE_KEEP);
    }
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_stream_start("m1"));
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_tag(c.gst_tag_list_new(c.GST_TAG_TITLE, "Event Title", NONE)));
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_tag(c.gst_tag_list_new(c.GST_TAG_ARTIST, "Event Artist", NONE)));
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_segment(&seg));
    c.gst_segment_init(&seg, c.GST_FORMAT_BYTES);
    seg.start = 5;
    seg.time = 5;
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_segment(&seg));
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const b = c.gst_buffer_new_allocate(null, 100 + i, null);
        _ = c.gst_buffer_memset(b, 0, @truncate(i + 65), 100 + i);
        if (i != 1) b.*.offset = i * 200;
        out("  push -> {s}", .{str(c.gst_flow_get_name(c.gst_pad_push(r.up, b)))});
    }
    seg.start = 900;
    _ = c.gst_pad_push_event(r.up, c.gst_event_new_segment(&seg));
    out("  eos -> {d}", .{c.gst_pad_push_event(r.up, c.gst_event_new_eos())});
    drainBus(r.bus);
    done(r);
}

fn writerClassInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

fn xmpWriter() void {
    out("xmpwriter", .{});
    const t = c.g_type_register_static_simple(c.gst_element_get_type(), "TestXmpWriter", @sizeOf(c.GstElementClass), writerClassInit, @sizeOf(c.GstElement), null, 0);
    const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
    c.g_type_add_interface_static(t, c.gst_tag_xmp_writer_get_type(), &info);
    out("  iface {s} prereq-ok {d}", .{ str(c.g_type_name(c.gst_tag_xmp_writer_get_type())), @intFromBool(c.g_type_is_a(t, c.gst_tag_xmp_writer_get_type()) != 0) });
    const w: ?*c.GstTagXmpWriter = @ptrCast(c.g_object_new(t, null));
    const l = c.gst_tag_list_new(c.GST_TAG_TITLE, "XT", c.GST_TAG_DEVICE_MODEL, "Cam", c.GST_TAG_ARTIST, "Ar", NONE);
    const show = struct {
        fn f(wr: ?*c.GstTagXmpWriter, list: [*c]c.GstTagList, tag: []const u8) void {
            const b = c.gst_tag_xmp_writer_tag_list_to_xmp_buffer(wr, list, 1);
            if (b == null) {
                out("  {s} (null)", .{tag});
                return;
            }
            var mi: c.GstMapInfo = undefined;
            _ = c.gst_buffer_map(b, &mi, c.GST_MAP_READ);
            out("  {s} {d}\n{s}", .{ tag, mi.size, mi.data[0..mi.size] });
            c.gst_buffer_unmap(b, &mi);
            c.gst_buffer_unref(b);
        }
    }.f;
    out("  has dc {d} tiff {d} bogus {d}", .{ c.gst_tag_xmp_writer_has_schema(w, "dc"), c.gst_tag_xmp_writer_has_schema(w, "tiff"), c.gst_tag_xmp_writer_has_schema(w, "bogus") });
    show(w, l, "all");
    c.gst_tag_xmp_writer_remove_schema(w, "dc");
    c.gst_tag_xmp_writer_remove_schema(w, "nope");
    show(w, l, "no dc");
    c.gst_tag_xmp_writer_remove_all_schemas(w);
    show(w, l, "none");
    c.gst_tag_xmp_writer_add_schema(w, "dc");
    c.gst_tag_xmp_writer_add_schema(w, "dc");
    c.gst_tag_xmp_writer_add_schema(w, "custom");
    out("  has dc {d} custom {d}", .{ c.gst_tag_xmp_writer_has_schema(w, "dc"), c.gst_tag_xmp_writer_has_schema(w, "custom") });
    show(w, l, "dc only");
    c.gst_tag_xmp_writer_add_all_schemas(w);
    show(w, l, "all again");
    const el = c.gst_pad_new("x", c.GST_PAD_SRC);
    c.gst_tag_xmp_writer_add_schema(@ptrCast(el), "dc");
    out("  bad has {d}", .{c.gst_tag_xmp_writer_has_schema(null, "dc")});
    _ = c.gst_tag_xmp_writer_tag_list_to_xmp_buffer(@ptrCast(el), l, 0);
    c.gst_object_unref(el);
    c.gst_tag_list_unref(l);
    c.g_object_unref(w);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    _ = c.gst_type_find_register(null, "sinty-test-png", c.GST_RANK_PRIMARY, findPng, null, null, null, null);
    out("demux type {s} abstract {d} mux {s} abstract {d} setter {d}", .{ str(c.g_type_name(c.gst_tag_demux_get_type())), @intFromBool(c.G_TYPE_IS_ABSTRACT(c.gst_tag_demux_get_type()) != 0), str(c.g_type_name(c.gst_tag_mux_get_type())), @intFromBool(c.G_TYPE_IS_ABSTRACT(c.gst_tag_mux_get_type()) != 0), @intFromBool(c.g_type_is_a(c.gst_tag_mux_get_type(), c.gst_tag_setter_get_type()) != 0) });
    const dt = c.g_type_register_static_simple(c.gst_tag_demux_get_type(), "TestTagDemux", @sizeOf(c.GstTagDemuxClass), demuxClassInit, @sizeOf(c.GstTagDemux), null, 0);
    const mt = c.g_type_register_static_simple(c.gst_tag_mux_get_type(), "TestTagMux", @sizeOf(c.GstTagMuxClass), muxClassInit, @sizeOf(c.GstTagMux), null, 0);
    const bt = c.g_type_register_static_simple(c.gst_tag_mux_get_type(), "BareTagMux", @sizeOf(c.GstTagMuxClass), bareClassInit, @sizeOf(c.GstTagMux), null, 0);
    const tk = c.g_type_class_ref(dt);
    const tl = c.gst_element_class_get_pad_template_list(@ptrCast(@alignCast(tk)));
    out("demux templates {d}", .{c.g_list_length(tl)});
    makeBlob("Hello Start", 10000, "Tail Artist");
    pushRun("push offsets", dt, 3000, true, false);
    pushRun("push no offsets", dt, 4096, false, false);
    pushRun("push time", dt, 2500, true, true);
    makeBlob("Short", 300, null);
    pushRun("push short eos", dt, 100, true, false);
    makeBlob(null, 0, null);
    put("garbage-without-type");
    pushRun("push untyped", dt, 7, true, false);
    makeBlob("Hello Start", 10000, "Tail Artist");
    pullRun("pull both", dt);
    makeBlob(null, 9000, "broken tail");
    pullRun("pull broken end", dt);
    makeBlob(null, 5000, null);
    pullRun("pull no tags", dt);
    makeBlob("only", 0, null);
    pullRun("pull no data", dt);
    makeBlob("Hello Start", 10000, "Tail Artist");
    downstreamPull("downstream pull", dt);
    muxRun("mux", mt, false);
    muxRun("mux setter", mt, true);
    muxRun("mux bare", bt, false);
    xmpWriter();
}
