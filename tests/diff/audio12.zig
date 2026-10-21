const std = @import("std");
const c = @import("c").c;

var main_thread: ?*c.GThread = null;
var log_lock: c.GMutex = undefined;
var log_buf: [1 << 20]u8 = undefined;
var log_len: usize = 0;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    if (c.g_thread_self() != main_thread) {
        c.g_mutex_lock(&log_lock);
        @memcpy(log_buf[log_len..][0..s.len], s);
        log_len += s.len;
        c.g_mutex_unlock(&log_lock);
        return;
    }
    _ = std.c.write(1, s.ptr, s.len);
}

fn flushLog() void {
    c.g_mutex_lock(&log_lock);
    const hdr = "  streaming:\n";
    _ = std.c.write(1, hdr.ptr, hdr.len);
    _ = std.c.write(1, &log_buf, log_len);
    log_len = 0;
    c.g_mutex_unlock(&log_lock);
}

const NONE = @as(?*anyopaque, null);
const NOPROP = @as([*c]const u8, null);

var log_events = true;

fn probe(_: ?*c.GstPad, pinfo: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (!@atomicLoad(bool, &log_events, .seq_cst)) return c.GST_PAD_PROBE_OK;
    const e: [*c]c.GstEvent = @ptrCast(@alignCast(pinfo.*.data));
    switch (e.*.type) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            const s = c.gst_caps_to_string(caps);
            out("  event caps {s}", .{s});
            c.g_free(s);
        },
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            out("  event segment format {d} rate {d} start {d} stop {d} time {d}", .{ seg.*.format, seg.*.rate, seg.*.start, seg.*.stop, seg.*.time });
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(e, @ptrCast(&tags));
            const s = c.gst_tag_list_to_string(tags);
            out("  event tag {s}", .{s});
            c.g_free(s);
        },
        else => out("  event {s}", .{c.gst_event_type_get_name(e.*.type)}),
    }
    return c.GST_PAD_PROBE_OK;
}


fn hashBuf(b: [*c]c.GstBuffer) u64 {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    var h: u64 = 0xcbf29ce484222325;
    for (map.data[0..map.size]) |x| h = (h ^ x) *% 0x100000001b3;
    c.gst_buffer_unmap(b, &map);
    return h;
}

fn busDump(pipe: [*c]c.GstElement) void {
    const bus = c.gst_element_get_bus(pipe);
    while (c.gst_bus_pop(bus)) |m| {
        if (m.*.type == c.GST_MESSAGE_ERROR or m.*.type == c.GST_MESSAGE_WARNING) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            if (m.*.type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
            out("  bus {s} {s} {d} {s} | {s}", .{ c.gst_message_type_get_name(m.*.type), c.g_quark_to_string(e.*.domain), e.*.code, e.*.message, if (dbg != null) std.mem.span(dbg) else "-" });
            c.g_error_free(e);
            c.g_free(dbg);
        } else if (m.*.type == c.GST_MESSAGE_LATENCY) out("  bus latency", .{});
        c.gst_message_unref(m);
    }
    c.gst_object_unref(bus);
}

var data_only = false;
var opens: u32 = 0;

fn addTrack(s: [*c]c.GstAudioCdSrc, num: c.guint, start: c.guint, end: c.guint, audio: bool) void {
    var t = std.mem.zeroes(c.GstAudioCdSrcTrack);
    t.is_audio = @intFromBool(audio);
    t.num = num;
    t.start = start;
    t.end = end;
    if (num == 2) {
        t.tags = c.gst_tag_list_new_empty();
        c.gst_tag_list_add(t.tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_TITLE, "Second", NONE);
    }
    out("  add_track {d} -> {d}", .{ num, c.gst_audio_cd_src_add_track(s, &t) });
}

fn cdOpen(s: [*c]c.GstAudioCdSrc, device: [*c]const u8) callconv(.c) c.gboolean {
    opens += 1;
    out("  open {s}", .{device});
    if (data_only) {
        addTrack(s, 1, 0, 99, false);
        return 1;
    }
    addTrack(s, 1, 0, 299, true);
    addTrack(s, 2, 300, 449, true);
    addTrack(s, 3, 450, 520, true);
    addTrack(s, 4, 500, 600, true);
    addTrack(s, 5, 700, 900, false);
    return 1;
}

fn cdClose(_: [*c]c.GstAudioCdSrc) callconv(.c) void {
    out("  close", .{});
}

fn cdRead(_: [*c]c.GstAudioCdSrc, sector: c.gint) callconv(.c) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, 2352, null);
    _ = c.gst_buffer_memset(b, 0, @truncate(@as(c_uint, @bitCast(sector))), 2352);
    return b;
}

fn cdClassInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    const k: *c.GstAudioCdSrcClass = @ptrCast(@alignCast(kl));
    k.open = cdOpen;
    k.close = cdClose;
    k.read_sector = cdRead;
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(kl)), "Fake CD", "Source/File", "test", "test");
}

fn cdType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_audio_cd_src_get_type(), "FakeCdSrc", @sizeOf(c.GstAudioCdSrcClass), cdClassInit, @sizeOf(c.GstAudioCdSrc), null, 0);
    return S.t;
}

fn queries(src: [*c]c.GstElement) void {
    const pad = c.gst_element_get_static_pad(src, "src");
    const track = c.gst_format_get_by_nick("track");
    const sector = c.gst_format_get_by_nick("sector");
    for ([_]c.GstFormat{ c.GST_FORMAT_TIME, c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT, track, sector }) |f| {
        var d: i64 = 0;
        var p: i64 = 0;
        const dr = c.gst_pad_query_duration(pad, f, &d);
        const pr = c.gst_pad_query_position(pad, f, &p);
        out("  fmt {s} duration {d} {d} position {d} {d}", .{ c.gst_format_get_name(f), dr, d, pr, p });
    }
    const conv = [_][3]i64{ .{ track, 1, c.GST_FORMAT_TIME }, .{ sector, 75, c.GST_FORMAT_TIME }, .{ c.GST_FORMAT_TIME, 2 * 1000000000, sector }, .{ c.GST_FORMAT_TIME, 5 * 1000000000, track }, .{ c.GST_FORMAT_BYTES, 1000000, track }, .{ c.GST_FORMAT_DEFAULT, 44100, c.GST_FORMAT_BYTES }, .{ track, 9, c.GST_FORMAT_TIME }, .{ c.GST_FORMAT_BYTES, -8, c.GST_FORMAT_BYTES + 0 } };
    for (conv) |cv| {
        var v: i64 = 0;
        const r = c.gst_pad_query_convert(pad, @intCast(cv[0]), cv[1], @intCast(cv[2]), &v);
        out("  convert {d}:{d} -> {d} = {d} {d}", .{ cv[0], cv[1], cv[2], r, v });
    }
    c.gst_object_unref(pad);
}

fn pull(sink: [*c]c.GstElement, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var sample: ?*c.GstSample = null;
        c.g_signal_emit_by_name(sink, "try-pull-sample", @as(u64, 5 * c.GST_SECOND), &sample);
        if (sample == null) {
            out("  no sample", .{});
            return;
        }
        const b = c.gst_sample_get_buffer(sample);
        out("  buf pts {d} dur {d} size {d} hash {x}", .{ b.*.pts, b.*.duration, c.gst_buffer_get_size(b), hashBuf(b) });
        c.gst_sample_unref(sample);
    }
}

fn run(label: []const u8, mode: c_int, uri: ?[*c]const u8) void {
    out("run {s}", .{label});
    const pipe = c.gst_pipeline_new("p");
    const src: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(cdType(), "name", "cd", "mode", mode, NONE)));
    const sink = c.gst_element_factory_make("appsink", "out");
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), "max-buffers", @as(c.guint, 4), NONE);
    if (uri) |u| {
        var err: [*c]c.GError = null;
        out("  set uri {s} -> {d}", .{ u, c.gst_uri_handler_set_uri(@ptrCast(src), u, &err) });
        if (err != null) {
            out("  uri error {s}", .{err.*.message});
            c.g_error_free(err);
        }
    }
    const kp = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(kp, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
    c.gst_object_unref(kp);
    _ = c.gst_bin_add(@ptrCast(pipe), src);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    _ = c.gst_element_link(src, sink);
    out("  paused {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PAUSED)});
    _ = c.gst_element_get_state(pipe, null, null, 5 * c.GST_SECOND);
    var tr: c.guint = 0;
    c.g_object_get(src, "track", &tr, NONE);
    const gu = c.gst_uri_handler_get_uri(@ptrCast(src));
    out("  track prop {d} uri {s}", .{ tr, gu });
    c.g_free(gu);
    queries(src);
    @atomicStore(bool, &log_events, true, .seq_cst);
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    pull(sink, 3);
    @atomicStore(bool, &log_events, false, .seq_cst);
    const track = c.gst_format_get_by_nick("track");
    out("  seek track 2 {d}", .{c.gst_element_seek(src, 1.0, track, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 2, c.GST_SEEK_TYPE_NONE, -1)});
    pull(sink, 2);
    out("  seek sector {d}", .{c.gst_element_seek(src, 1.0, c.gst_format_get_by_nick("sector"), c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 10, c.GST_SEEK_TYPE_NONE, -1)});
    out("  seek time {d}", .{c.gst_element_seek_simple(src, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_FLUSH, c.GST_SECOND / 2)});
    pull(sink, 1);
    out("  toc select {d}", .{c.gst_element_send_event(src, c.gst_event_new_toc_select("audiocd-track-001"))});
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    flushLog();
    busDump(pipe);
    c.gst_object_unref(pipe);
}

pub fn main() void {
    main_thread = c.g_thread_self();
    c.g_mutex_init(&log_lock);
    c.gst_init(null, null);
    const t = c.gst_audio_cd_src_get_type();
    out("type {s} abstract {d} parent {s} urihandler {d}", .{ c.g_type_name(t), @intFromBool(c.g_type_test_flags(t, c.G_TYPE_FLAG_ABSTRACT) != 0), c.g_type_name(c.g_type_parent(t)), c.g_type_is_a(t, c.gst_uri_handler_get_type()) });
    const o: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(cdType(), NOPROP)));
    _ = c.gst_object_ref_sink(o);
    var n: c.guint = 0;
    const ps = c.g_object_class_list_properties(@ptrCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class), &n);
    for (ps[0..n]) |p| {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, p.*.value_type);
        c.g_object_get_property(@ptrCast(@alignCast(o)), p.*.name, &v);
        const s = c.g_strdup_value_contents(&v);
        out("prop {s} owner {s} flags {d} = {s}", .{ p.*.name, c.g_type_name(p.*.owner_type), p.*.flags, s });
        c.g_free(s);
        c.g_value_unset(&v);
    }
    c.g_free(@ptrCast(ps));
    c.g_object_set(o, "device", "///dev/sr7", "track", @as(c.guint, 5), NONE);
    var dev: [*c]u8 = null;
    var tr: c.guint = 0;
    c.g_object_get(o, "device", &dev, "track", &tr, NONE);
    out("device {s} track {d}", .{ dev, tr });
    c.g_free(dev);
    const prots = c.gst_uri_handler_get_protocols(@ptrCast(o));
    out("protocol {s} type {d}", .{ prots[0], c.gst_uri_handler_get_uri_type(@ptrCast(o)) });
    for ([_][*c]const u8{ "cdda://3", "cdda://", "cdda:///dev/sr1#4", "cdda://0", "cdda://x" }) |u| {
        var err: [*c]c.GError = null;
        const r = c.gst_uri_handler_set_uri(@ptrCast(o), u, &err);
        const g = c.gst_uri_handler_get_uri(@ptrCast(o));
        c.g_object_get(o, "device", &dev, "track", &tr, NONE);
        out("uri {s} -> {d} get {s} device {s} track {d} err {s}", .{ u, r, g, dev, tr, if (err != null) std.mem.span(err.*.message) else "-" });
        c.g_free(dev);
        c.g_free(g);
        if (err != null) c.g_error_free(err);
    }
    var bad = std.mem.zeroes(c.GstAudioCdSrcTrack);
    out("add bad {d}", .{c.gst_audio_cd_src_add_track(@ptrCast(o), &bad)});
    out("add null {d}", .{c.gst_audio_cd_src_add_track(@ptrCast(o), null)});
    c.gst_object_unref(o);
    run("normal", 0, null);
    run("continuous", 1, null);
    run("uri-track-3", 0, "cdda://3");
    out("opens {d}", .{opens});
}
