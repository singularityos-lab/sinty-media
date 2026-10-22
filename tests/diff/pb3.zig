const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

var sums: std.ArrayList(u8) = .empty;
var sums_lock: c.GMutex = std.mem.zeroes(c.GMutex);

fn sum(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (info[0].type & c.GST_PAD_PROBE_TYPE_BUFFER == 0) return c.GST_PAD_PROBE_OK;
    const b: [*c]c.GstBuffer = @ptrCast(@alignCast(info[0].data));
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &map, c.GST_MAP_READ) == 0) return c.GST_PAD_PROBE_OK;
    const h = std.hash.Fnv1a_64.hash(map.data[0..map.size]);
    c.gst_buffer_unmap(b, &map);
    const s = std.fmt.allocPrint(A, "    buffer pts {d} size {d} hash {x}\n", .{ b[0].pts / 1000000, map.size, h }) catch unreachable;
    c.g_mutex_lock(&sums_lock);
    sums.appendSlice(A, s) catch unreachable;
    c.g_mutex_unlock(&sums_lock);
    A.free(s);
    return c.GST_PAD_PROBE_OK;
}

fn objName(o: ?*anyopaque) []const u8 {
    const p = o orelse return "-";
    return z(@as(*c.GstObject, @ptrCast(@alignCast(p))).name);
}

fn tree(e: ?*c.GstElement, depth: usize) void {
    var pad_buf: [2048]u8 = undefined;
    var n: usize = 0;
    var pl = @as(*c.GstElement, @ptrCast(@alignCast(e))).pads;
    while (pl != null) : (pl = pl[0].next) {
        const p: ?*c.GstPad = @ptrCast(@alignCast(pl[0].data));
        const peer = c.gst_pad_get_peer(p);
        var pn: []const u8 = "-";
        var pe: []const u8 = "-";
        if (peer) |x| {
            pn = objName(x);
            pe = objName(@as(*c.GstObject, @ptrCast(@alignCast(x))).parent);
        }
        const w = std.fmt.bufPrint(pad_buf[n..], "{s}->{s}.{s} ", .{ objName(p), pe, pn }) catch break;
        n += w.len;
        if (peer) |x| c.gst_object_unref(x);
    }
    const f = c.gst_element_get_factory(e);
    const fname = if (f != null) objName(f) else z(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(e))).g_class.*.g_type));
    var ind: [32]u8 = @splat(' ');
    out("  {s}{s} ({s}) {s}", .{ ind[0 .. depth * 2], objName(e), fname, pad_buf[0..n] });
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(e)), c.gst_bin_get_type()) == 0) return;
    var kids: std.ArrayList(?*c.GstElement) = .empty;
    var l = @as(*c.GstBin, @ptrCast(@alignCast(e))).children;
    while (l != null) : (l = l[0].next) kids.append(A, @ptrCast(@alignCast(l[0].data))) catch unreachable;
    std.mem.sort(?*c.GstElement, kids.items, {}, struct {
        fn lt(_: void, a: ?*c.GstElement, b: ?*c.GstElement) bool {
            return std.mem.lessThan(u8, objName(a), objName(b));
        }
    }.lt);
    for (kids.items) |k| tree(k, depth + 1);
    kids.deinit(A);
}

fn describe(m: [*c]c.GstMessage) void {
    var err: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    switch (m[0].type) {
        c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
            if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &err, &dbg) else c.gst_message_parse_warning(m, &err, &dbg);
            out("  {s} {s} {s} {d} [{s}] [{s}]", .{ z(c.gst_message_type_get_name(m[0].type)), objName(m[0].src), z(c.g_quark_to_string(err[0].domain)), err[0].code, z(err[0].message), z(dbg) });
            c.g_error_free(err);
            c.g_free(dbg);
        },
        else => {
            const str = c.gst_structure_to_string(c.gst_message_get_structure(m));
            out("  element {s} {s}", .{ objName(m[0].src), z(str) });
            c.g_free(str);
        },
    }
}

fn textSource(caps_str: [*c]const u8, texts: []const [:0]const u8) ?*c.GstElement {
    const s = c.gst_element_factory_make("appsrc", "tsrc");
    const caps = c.gst_caps_from_string(caps_str);
    c.g_object_set(@ptrCast(s), "caps", caps, "format", @as(c.gint, c.GST_FORMAT_TIME), N);
    c.gst_caps_unref(caps);
    for (texts, 0..) |t, i| {
        const b = c.gst_buffer_new_memdup(t.ptr, t.len);
        b[0].pts = i * 200 * c.GST_MSECOND;
        b[0].duration = 200 * c.GST_MSECOND;
        var r: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(@ptrCast(s), "push-buffer", b, &r);
        c.gst_buffer_unref(b);
    }
    var r: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(@ptrCast(s), "end-of-stream", &r);
    return s;
}

const Opts = struct {
    sub_caps: ?[:0]const u8 = null,
    texts: []const [:0]const u8 = &.{ "hello", "world" },
    silent: bool = false,
    font: ?[:0]const u8 = null,
    offset: i64 = 0,
    video_caps: [:0]const u8 = "video/x-raw,format=I420,width=160,height=120,framerate=5/1",
};

fn scenario(title: []const u8, o: Opts) void {
    out("scenario {s}", .{title});
    sums.clearRetainingCapacity();
    const pipe = c.gst_pipeline_new("pipe");
    const so = c.gst_element_factory_make("subtitleoverlay", "so");
    if (so == null) {
        out("  no subtitleoverlay", .{});
        return;
    }
    if (o.silent) c.g_object_set(@ptrCast(so), "silent", @as(c.gboolean, 1), N);
    if (o.font) |f| c.g_object_set(@ptrCast(so), "font-desc", f.ptr, N);
    if (o.offset != 0) c.g_object_set(@ptrCast(so), "subtitle-ts-offset", o.offset, N);
    const v = c.gst_element_factory_make("videotestsrc", "vsrc");
    c.g_object_set(@ptrCast(v), "num-buffers", @as(c.gint, 4), N);
    const cf = c.gst_element_factory_make("capsfilter", "vcaps");
    const caps = c.gst_caps_from_string(o.video_caps.ptr);
    c.g_object_set(@ptrCast(cf), "caps", caps, N);
    c.gst_caps_unref(caps);
    const sink = c.gst_element_factory_make("fakesink", "sink");
    c.g_object_set(@ptrCast(sink), "sync", @as(c.gboolean, 0), N);
    const sp = c.gst_element_get_static_pad(sink, "sink");
    _ = c.gst_pad_add_probe(sp, c.GST_PAD_PROBE_TYPE_BUFFER, sum, null, null);
    c.gst_object_unref(sp);
    const bin: *c.GstBin = @ptrCast(@alignCast(pipe));
    _ = c.gst_bin_add(bin, v);
    _ = c.gst_bin_add(bin, cf);
    _ = c.gst_bin_add(bin, so);
    _ = c.gst_bin_add(bin, sink);
    out("  links {d} {d} {d}", .{ c.gst_element_link(v, cf), c.gst_element_link_pads(cf, "src", so, "video_sink"), c.gst_element_link(so, sink) });
    if (o.sub_caps) |sc| {
        const t = textSource(sc.ptr, o.texts);
        _ = c.gst_bin_add(bin, t);
        out("  sublink {d}", .{c.gst_element_link_pads(t, "src", so, "subtitle_sink")});
    }
    const bus = c.gst_element_get_bus(pipe);
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 5 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT);
        if (m == null) {
            out("  timeout", .{});
            break;
        }
        if (m[0].type == c.GST_MESSAGE_EOS) {
            c.gst_mini_object_unref(@ptrCast(m));
            out("  eos", .{});
            break;
        }
        describe(m);
        const e = m[0].type == c.GST_MESSAGE_ERROR;
        c.gst_mini_object_unref(@ptrCast(m));
        if (e) break;
    }
    tree(so, 0);
    out("  buffers\n{s}", .{sums.items});
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    tree(so, 0);
    var silent: c.gboolean = 0;
    var font: [*c]u8 = null;
    var off: i64 = 0;
    c.g_object_get(@ptrCast(so), "silent", &silent, "font-desc", &font, "subtitle-ts-offset", &off, N);
    out("  props silent {d} font {s} offset {d}", .{ silent, z(font), off });
    c.g_free(font);
    c.gst_object_unref(bus);
    c.gst_object_unref(pipe);
}

fn queries() void {
    out("queries", .{});
    const so = c.gst_element_factory_make("subtitleoverlay", null);
    const sub = c.gst_element_get_static_pad(so, "subtitle_sink");
    const caps = c.gst_pad_query_caps(sub, null);
    const s = c.gst_caps_to_string(caps);
    out("  subtitle caps {s}", .{z(s)});
    c.g_free(s);
    c.gst_caps_unref(caps);
    const t = c.gst_caps_from_string("text/x-raw,format=utf8");
    out("  accept {d}", .{c.gst_pad_query_accept_caps(sub, t)});
    c.gst_caps_unref(t);
    c.gst_object_unref(sub);
    const vs = c.gst_element_get_static_pad(so, "video_sink");
    const vc = c.gst_pad_query_caps(vs, null);
    const vstr = c.gst_caps_to_string(vc);
    out("  video caps {s}", .{z(vstr)});
    c.g_free(vstr);
    c.gst_caps_unref(vc);
    const f = c.gst_caps_from_string("video/x-raw,format=NV12");
    const fc = c.gst_pad_query_caps(vs, f);
    const fstr = c.gst_caps_to_string(fc);
    out("  filtered {s}", .{z(fstr)});
    c.g_free(fstr);
    c.gst_caps_unref(fc);
    c.gst_caps_unref(f);
    c.gst_object_unref(vs);
    c.gst_object_unref(so);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("subtitleoverlay");
    queries();
    scenario("no subtitles", .{});
    scenario("utf8 text", .{ .sub_caps = "text/x-raw,format=utf8" });
    scenario("pango markup", .{ .sub_caps = "text/x-raw,format=pango-markup", .texts = &.{ "<b>bold</b>", "<i>it</i>" } });
    scenario("silent", .{ .sub_caps = "text/x-raw,format=utf8", .silent = true });
    scenario("font", .{ .sub_caps = "text/x-raw,format=utf8", .font = "Sans 20" });
    scenario("offset", .{ .sub_caps = "text/x-raw,format=utf8", .offset = 200 * c.GST_MSECOND });
    scenario("subrip", .{ .sub_caps = "application/x-subtitle", .texts = &.{"1\n00:00:00,000 --> 00:00:00,500\nfirst\n\n2\n00:00:00,500 --> 00:00:01,000\nsecond\n\n"} });
    scenario("unknown caps", .{ .sub_caps = "application/x-sinty-unknown" });
    scenario("rgb video", .{ .sub_caps = "text/x-raw,format=utf8", .video_caps = "video/x-raw,format=RGBA,width=96,height=64,framerate=5/1" });
    out("done", .{});
}
