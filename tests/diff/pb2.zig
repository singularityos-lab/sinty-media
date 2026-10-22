const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

const VIDEO: c.guint = 1;
const AUDIO: c.guint = 2;
const TEXT: c.guint = 4;
const VIS: c.guint = 8;
const SOFT_VOLUME: c.guint = 16;
const NATIVE_AUDIO: c.guint = 32;
const NATIVE_VIDEO: c.guint = 64;
const DEINTERLACE: c.guint = 512;
const SOFT_BALANCE: c.guint = 1024;
const FORCE_FILTERS: c.guint = 2048;

const Opts = struct {
    flags: ?c.guint = null,
    audio: bool = false,
    video: bool = false,
    text: bool = false,
    audio_sink: bool = true,
    video_sink: bool = true,
    text_sink: bool = false,
    audio_filter: bool = false,
    video_filter: bool = false,
    volume: ?f64 = null,
    mute: bool = false,
    av_offset: i64 = 0,
    vis: bool = false,
    reconfigure: bool = false,
    caps_video: [:0]const u8 = "video/x-raw,format=I420,width=64,height=48,framerate=10/1",
};

var counts: [3]std.atomic.Value(u32) = .{ .init(0), .init(0), .init(0) };

fn counter(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (info[0].type & c.GST_PAD_PROBE_TYPE_BUFFER != 0) _ = counts[@intFromPtr(data)].fetchAdd(1, .monotonic);
    return c.GST_PAD_PROBE_OK;
}

fn fakesink(name: [*c]const u8, slot: usize) ?*c.GstElement {
    const s = c.gst_element_factory_make("fakesink", name);
    c.g_object_set(@ptrCast(s), "sync", @as(c.gboolean, 0), N);
    const p = c.gst_element_get_static_pad(s, "sink");
    _ = c.gst_pad_add_probe(p, c.GST_PAD_PROBE_TYPE_BUFFER, counter, @ptrFromInt(slot), null);
    c.gst_object_unref(p);
    return s;
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
    var names: std.ArrayList([]const u8) = .empty;
    var kids: std.ArrayList(?*c.GstElement) = .empty;
    var l = @as(*c.GstBin, @ptrCast(@alignCast(e))).children;
    while (l != null) : (l = l[0].next) {
        kids.append(A, @ptrCast(@alignCast(l[0].data))) catch unreachable;
    }
    std.mem.sort(?*c.GstElement, kids.items, {}, struct {
        fn lt(_: void, a: ?*c.GstElement, b: ?*c.GstElement) bool {
            return std.mem.lessThan(u8, objName(a), objName(b));
        }
    }.lt);
    for (kids.items) |k| tree(k, depth + 1);
    names.deinit(A);
    kids.deinit(A);
}

fn drain(bus: ?*c.GstBus, lines: *std.ArrayList([]u8)) void {
    while (c.gst_bus_pop_filtered(bus, c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT)) |m| {
        describe(m, lines);
        c.gst_mini_object_unref(@ptrCast(m));
    }
}

fn describe(m: [*c]c.GstMessage, lines: *std.ArrayList([]u8)) void {
    var err: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    switch (m[0].type) {
        c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
            if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &err, &dbg) else c.gst_message_parse_warning(m, &err, &dbg);
            const s = std.fmt.allocPrint(A, "  {s} {s} {s} {d} [{s}] [{s}]", .{ z(c.gst_message_type_get_name(m[0].type)), objName(m[0].src), z(c.g_quark_to_string(err[0].domain)), err[0].code, z(err[0].message), z(dbg) }) catch unreachable;
            lines.append(A, s) catch unreachable;
            c.g_error_free(err);
            c.g_free(dbg);
        },
        else => {
            const st = c.gst_message_get_structure(m);
            const str = c.gst_structure_to_string(st);
            const s = std.fmt.allocPrint(A, "  element {s} {s}", .{ objName(m[0].src), z(str) }) catch unreachable;
            lines.append(A, s) catch unreachable;
            c.g_free(str);
        },
    }
}

fn printSorted(lines: *std.ArrayList([]u8)) void {
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (lines.items) |s| out("{s}", .{s});
    for (lines.items) |s| A.free(s);
    lines.clearRetainingCapacity();
}

fn props(ps: ?*c.GstElement) void {
    var vol: f64 = 0;
    var mute: c.gboolean = 0;
    var fl: c.guint = 0;
    var av: i64 = 0;
    var mode: c.gint = 0;
    var far: c.gboolean = 0;
    var as: ?*c.GstElement = null;
    var vs: ?*c.GstElement = null;
    var ts: ?*c.GstElement = null;
    var af: ?*c.GstElement = null;
    var vf: ?*c.GstElement = null;
    var vis: ?*c.GstElement = null;
    var sample: ?*c.GstSample = null;
    var enc: [*c]u8 = null;
    c.g_object_get(@ptrCast(ps), "volume", &vol, "mute", &mute, "flags", &fl, "av-offset", &av, "send-event-mode", &mode, "force-aspect-ratio", &far, "audio-sink", &as, "video-sink", &vs, "text-sink", &ts, "audio-filter", &af, "video-filter", &vf, "vis-plugin", &vis, "sample", &sample, "subtitle-encoding", &enc, N);
    out("  props vol {d:.3} mute {d} flags {x} av {d} mode {d} far {d} as {s} vs {s} ts {s} af {s} vf {s} vis {s} sample {s} enc {s}", .{ vol, mute, fl, av, mode, far, objName(as), objName(vs), objName(ts), objName(af), objName(vf), objName(vis), if (sample != null) "yes" else "no", z(enc) });
    if (sample) |x| {
        const caps = c.gst_sample_get_caps(x);
        const cs = c.gst_caps_to_string(caps);
        out("  sample caps {s}", .{z(cs)});
        c.g_free(cs);
        c.gst_sample_unref(x);
    }
    inline for (.{ as, vs, ts, af, vf, vis }) |o| if (o) |x| c.gst_object_unref(x);
    c.g_free(enc);
}

fn sameGroup(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const e: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
    if (e[0].type != c.GST_EVENT_STREAM_START) return c.GST_PAD_PROBE_OK;
    var id: [*c]const u8 = null;
    c.gst_event_parse_stream_start(e, &id);
    const n = c.gst_event_new_stream_start(id);
    c.gst_event_set_group_id(n, 7);
    c.gst_mini_object_unref(@ptrCast(e));
    info[0].data = n;
    return c.GST_PAD_PROBE_OK;
}

fn linkSrc(pipe: ?*c.GstElement, ps: ?*c.GstElement, src: ?*c.GstElement, templ: [*c]const u8) void {
    if (@as(*c.GstObject, @ptrCast(@alignCast(src))).parent == null) _ = c.gst_bin_add(@ptrCast(@alignCast(pipe)), src);
    const sink = c.gst_element_request_pad_simple(ps, templ);
    out("  requested {s} for {s}", .{ objName(sink), z(templ) });
    const sp = c.gst_element_get_static_pad(src, "src");
    _ = c.gst_pad_add_probe(sp, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, sameGroup, null, null);
    out("  link {d}", .{c.gst_pad_link(sp, sink)});
    c.gst_object_unref(sp);
    c.gst_object_unref(sink);
}

fn textSource() ?*c.GstElement {
    const s = c.gst_element_factory_make("appsrc", "tsrc");
    const caps = c.gst_caps_from_string("text/x-raw,format=utf8");
    c.g_object_set(@ptrCast(s), "caps", caps, "format", @as(c.gint, c.GST_FORMAT_TIME), N);
    c.gst_caps_unref(caps);
    var i: u64 = 0;
    while (i < 3) : (i += 1) {
        const txt = "hello";
        const b = c.gst_buffer_new_memdup(txt, txt.len);
        b[0].pts = i * 100 * c.GST_MSECOND;
        b[0].duration = 100 * c.GST_MSECOND;
        var r: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(@ptrCast(s), "push-buffer", b, &r);
        c.gst_buffer_unref(b);
    }
    var r: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(@ptrCast(s), "end-of-stream", &r);
    return s;
}

fn scenario(title: []const u8, o: Opts) void {
    out("scenario {s}", .{title});
    for (&counts) |*x| x.store(0, .monotonic);
    const pipe = c.gst_pipeline_new("pipe");
    const ps = c.gst_element_factory_make("playsink", "ps");
    if (ps == null) {
        out("  no playsink", .{});
        return;
    }
    _ = c.gst_bin_add(@ptrCast(@alignCast(pipe)), ps);
    if (o.flags) |f| c.g_object_set(@ptrCast(ps), "flags", f, N);
    if (o.audio_sink) c.g_object_set(@ptrCast(ps), "audio-sink", fakesink("asink", 0), N);
    if (o.video_sink) c.g_object_set(@ptrCast(ps), "video-sink", fakesink("vsink", 1), N);
    if (o.text_sink) c.g_object_set(@ptrCast(ps), "text-sink", fakesink("tsink", 2), N);
    if (o.audio_filter) c.g_object_set(@ptrCast(ps), "audio-filter", c.gst_element_factory_make("identity", "afilter"), N);
    if (o.video_filter) c.g_object_set(@ptrCast(ps), "video-filter", c.gst_element_factory_make("identity", "vfilter"), N);
    if (o.volume) |v| c.g_object_set(@ptrCast(ps), "volume", v, N);
    if (o.mute) c.g_object_set(@ptrCast(ps), "mute", @as(c.gboolean, 1), N);
    if (o.av_offset != 0) c.g_object_set(@ptrCast(ps), "av-offset", o.av_offset, N);
    if (o.vis) c.g_object_set(@ptrCast(ps), "vis-plugin", c.gst_element_factory_make("fakesink", "visfake"), N);
    props(ps);
    if (o.audio) {
        const a = c.gst_element_factory_make("audiotestsrc", "asrc");
        c.g_object_set(@ptrCast(a), "num-buffers", @as(c.gint, 4), "samplesperbuffer", @as(c.gint, 441), N);
        linkSrc(pipe, ps, a, "audio_sink");
    }
    if (o.video) {
        const v = c.gst_element_factory_make("videotestsrc", "vsrc");
        c.g_object_set(@ptrCast(v), "num-buffers", @as(c.gint, 4), N);
        const cf = c.gst_element_factory_make("capsfilter", "vcaps");
        const caps = c.gst_caps_from_string(o.caps_video.ptr);
        c.g_object_set(@ptrCast(cf), "caps", caps, N);
        c.gst_caps_unref(caps);
        _ = c.gst_bin_add(@ptrCast(@alignCast(pipe)), v);
        _ = c.gst_bin_add(@ptrCast(@alignCast(pipe)), cf);
        _ = c.gst_element_link(v, cf);
        linkSrc(pipe, ps, cf, "video_sink");
    }
    if (o.text) linkSrc(pipe, ps, textSource(), "text_sink");
    const bus = c.gst_element_get_bus(pipe);
    var lines: std.ArrayList([]u8) = .empty;
    out("  paused {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PAUSED)});
    var cur: c.GstState = 0;
    var pend: c.GstState = 0;
    out("  get_state {d} {d}", .{ c.gst_element_get_state(pipe, &cur, &pend, 5 * c.GST_SECOND), cur });
    c.g_usleep(300000);
    drain(bus, &lines);
    printSorted(&lines);
    tree(ps, 0);
    props(ps);
    if (o.reconfigure) {
        var r: c.gboolean = 0;
        c.g_signal_emit_by_name(@ptrCast(ps), "reconfigure", &r);
        out("  reconfigure {d}", .{r});
    }
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
        describe(m, &lines);
        const was_err = m[0].type == c.GST_MESSAGE_ERROR;
        c.gst_mini_object_unref(@ptrCast(m));
        if (was_err) break;
    }
    printSorted(&lines);
    out("  buffers audio {d} video {d} text {d}", .{ counts[0].load(.monotonic), counts[1].load(.monotonic), counts[2].load(.monotonic) });
    out("  ready {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_READY)});
    tree(ps, 0);
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    drain(bus, &lines);
    printSorted(&lines);
    tree(ps, 0);
    props(ps);
    lines.deinit(A);
    c.gst_object_unref(bus);
    c.gst_object_unref(pipe);
}

fn requests() void {
    out("requests", .{});
    const ps = c.gst_element_factory_make("playsink", null);
    const a = c.gst_element_request_pad_simple(ps, "audio_sink");
    const a2 = c.gst_element_request_pad_simple(ps, "audio_raw_sink");
    const v = c.gst_element_request_pad_simple(ps, "video_raw_sink");
    const t = c.gst_element_request_pad_simple(ps, "text_sink");
    out("  {s} {s} same {d} {s} {s}", .{ objName(a), objName(a2), @intFromBool(a == a2), objName(v), objName(t) });
    tree(ps, 0);
    c.gst_element_release_request_pad(ps, v);
    c.gst_element_release_request_pad(ps, t);
    tree(ps, 0);
    inline for (.{ a, a2, v, t }) |p| c.gst_object_unref(p);
    c.gst_object_unref(ps);
}

fn balance() void {
    out("balance", .{});
    const ps = c.gst_element_factory_make("playsink", null);
    const cb: *c.GstColorBalance = @ptrCast(@alignCast(ps));
    var l: ?*const c.GList = c.gst_color_balance_list_channels(cb);
    while (l) |n| : (l = n.next) {
        const ch: *c.GstColorBalanceChannel = @ptrCast(@alignCast(n.data));
        c.gst_color_balance_set_value(cb, ch, 250);
        out("  {s} {d} {d} value {d}", .{ z(ch.label), ch.min_value, ch.max_value, c.gst_color_balance_get_value(cb, ch) });
    }
    out("  type {d}", .{c.gst_color_balance_get_balance_type(cb)});
    c.gst_object_unref(ps);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("playsink");
    requests();
    balance();
    scenario("audio", .{ .audio = true });
    scenario("video", .{ .video = true });
    scenario("audio video", .{ .audio = true, .video = true, .volume = 0.5, .mute = true, .av_offset = 20 * c.GST_MSECOND });
    scenario("native", .{ .audio = true, .video = true, .flags = AUDIO | VIDEO | NATIVE_AUDIO | NATIVE_VIDEO });
    scenario("filters", .{ .audio = true, .video = true, .audio_filter = true, .video_filter = true });
    scenario("no soft volume", .{ .audio = true, .flags = AUDIO | VIDEO });
    scenario("audio flag off", .{ .audio = true, .video = true, .flags = VIDEO | SOFT_VOLUME });
    scenario("text only", .{ .text = true });
    scenario("audio text", .{ .audio = true, .text = true });
    scenario("custom text sink", .{ .video = true, .text = true, .text_sink = true });
    scenario("custom text sink without video", .{ .audio = true, .text = true, .text_sink = true });
    scenario("vis", .{ .audio = true, .vis = true, .flags = AUDIO | VIDEO | VIS | SOFT_VOLUME });
    scenario("deinterlace", .{ .video = true, .flags = VIDEO | DEINTERLACE | SOFT_BALANCE });
    scenario("nonraw filter", .{ .video = true, .video_filter = true, .flags = VIDEO | FORCE_FILTERS, .caps_video = "video/x-raw,format=I420,width=64,height=48,framerate=10/1" });
    scenario("reconfigure", .{ .audio = true, .video = true, .reconfigure = true });
    out("done", .{});
}
