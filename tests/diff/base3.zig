const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;
const MS: u64 = 1000000;
const NONE: u64 = std.math.maxInt(u64);

var notes: u32 = 0;

fn sinkChain(_: ?*c.GstPad, _: ?*c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const h = std.hash.Fnv1a_64.hash(map.data[0..map.size]);
    const f = b.*.mini_object.flags;
    out("    buffer pts {d} dur {d} off {d} end {d} size {d} disc {d} gap {d} hash {x}", .{ ts(b.*.pts), ts(b.*.duration), ts(b.*.offset), ts(b.*.offset_end), map.size, @intFromBool(f & c.GST_BUFFER_FLAG_DISCONT != 0), @intFromBool(f & c.GST_BUFFER_FLAG_GAP != 0), h });
    c.gst_buffer_unmap(b, &map);
    c.gst_buffer_unref(b);
    return c.GST_FLOW_OK;
}

fn ts(v: u64) i64 {
    return if (v == NONE) -1 else @intCast(v);
}

fn sinkEvent(_: ?*c.GstPad, _: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (e.*.type == c.GST_EVENT_SEGMENT) {
        var seg: [*c]const c.GstSegment = null;
        c.gst_event_parse_segment(e, &seg);
        out("    segment format {d} start {d} stop {d} time {d} base {d} pos {d}", .{ seg.*.format, ts(seg.*.start), ts(seg.*.stop), ts(seg.*.time), ts(seg.*.base), ts(seg.*.position) });
    } else out("    event {s}", .{z(c.gst_event_type_get_name(e.*.type))});
    c.gst_event_unref(e);
    return 1;
}

fn onNotify(_: ?*c.GObject, _: ?*c.GParamSpec, _: c.gpointer) callconv(.c) void {
    notes += 1;
}

const Run = struct {
    rate: *c.GstElement,
    src: ?*c.GstPad,
    sink: ?*c.GstPad,
};

fn start(fmt: [:0]const u8, rate: u32, layout: [:0]const u8, props: anytype) Run {
    const el = c.gst_element_factory_make("audiorate", null).?;
    inline for (std.meta.fields(@TypeOf(props))) |f| c.g_object_set(@ptrCast(el), f.name ++ "", @field(props, f.name), N);
    const tmpl_caps = c.gst_caps_new_any();
    const src = c.gst_pad_new("src", c.GST_PAD_SRC);
    const sink = c.gst_pad_new("sink", c.GST_PAD_SINK);
    c.gst_caps_unref(tmpl_caps);
    c.gst_pad_set_chain_function_full(sink, sinkChain, null, null);
    c.gst_pad_set_event_function_full(sink, sinkEvent, null, null);
    _ = c.gst_pad_set_active(src, 1);
    _ = c.gst_pad_set_active(sink, 1);
    const esink = c.gst_element_get_static_pad(el, "sink");
    const esrc = c.gst_element_get_static_pad(el, "src");
    _ = c.gst_pad_link(src, esink);
    _ = c.gst_pad_link(esrc, sink);
    c.gst_object_unref(esink);
    c.gst_object_unref(esrc);
    notes = 0;
    _ = c.g_signal_connect_data(el, "notify::add", @ptrCast(&onNotify), null, null, 0);
    _ = c.g_signal_connect_data(el, "notify::drop", @ptrCast(&onNotify), null, null, 0);
    out("  state {d}", .{c.gst_element_set_state(el, c.GST_STATE_PLAYING)});
    _ = c.gst_pad_push_event(src, c.gst_event_new_stream_start("s"));
    const caps_str = std.fmt.allocPrintSentinel(A, "audio/x-raw, format={s}, rate={d}, channels=2, layout={s}", .{ fmt, rate, layout }, 0) catch unreachable;
    const caps = c.gst_caps_from_string(caps_str.ptr);
    out("  caps {d}", .{c.gst_pad_push_event(src, c.gst_event_new_caps(caps))});
    c.gst_caps_unref(caps);
    return .{ .rate = el, .src = src, .sink = sink };
}

fn segment(r: Run, fmt: c.GstFormat, startv: u64, stop: u64) void {
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, fmt);
    seg.start = startv;
    seg.stop = stop;
    seg.time = startv;
    seg.position = startv;
    _ = c.gst_pad_push_event(r.src, c.gst_event_new_segment(&seg));
}

fn push(r: Run, pts: u64, frames: usize, bpf: usize, seed: u8, disc: bool) void {
    const b = c.gst_buffer_new_allocate(null, frames * bpf, null);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
    for (map.data[0..map.size], 0..) |*x, i| x.* = @truncate(i *% 7 +% seed);
    c.gst_buffer_unmap(b, &map);
    b.*.pts = pts;
    if (disc) b.*.mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
    out("  push pts {d} frames {d} ret {d}", .{ ts(pts), frames, c.gst_pad_push(r.src, b) });
}

fn finish(r: Run) void {
    _ = c.gst_pad_push_event(r.src, c.gst_event_new_eos());
    var vin: u64 = 0;
    var vout: u64 = 0;
    var add: u64 = 0;
    var drop: u64 = 0;
    c.g_object_get(@ptrCast(r.rate), "in", &vin, "out", &vout, "add", &add, "drop", &drop, N);
    out("  counters in {d} out {d} add {d} drop {d} notifies {d}", .{ vin, vout, add, drop, notes });
    _ = c.gst_element_set_state(r.rate, c.GST_STATE_NULL);
    c.gst_object_unref(r.rate);
    c.gst_object_unref(r.src);
    c.gst_object_unref(r.sink);
}

pub fn main() void {
    c.gst_init(null, null);
    ins.element("audiorate");

    out("scenario perfect", .{});
    var r = start("S16LE", 8000, "interleaved", .{});
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, 0, 80, 4, 1, false);
    push(r, 10 * MS, 80, 4, 2, false);
    push(r, 20 * MS, 80, 4, 3, false);
    finish(r);

    out("scenario gap filled", .{});
    r = start("S16LE", 8000, "interleaved", .{ .silent = @as(c.gboolean, 0) });
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, 0, 80, 4, 1, false);
    push(r, 300 * MS, 80, 4, 2, false);
    push(r, 1500 * MS, 80, 4, 3, true);
    finish(r);

    out("scenario overlap dropped and truncated", .{});
    r = start("S16LE", 8000, "interleaved", .{ .silent = @as(c.gboolean, 0) });
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, 0, 800, 4, 1, false);
    push(r, 50 * MS, 200, 4, 2, false);
    push(r, 60 * MS, 800, 4, 3, false);
    push(r, 200 * MS, 80, 4, 4, false);
    finish(r);

    out("scenario jitter within tolerance", .{});
    r = start("F32LE", 48000, "interleaved", .{ .tolerance = @as(u64, 5 * MS) });
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, 0, 480, 8, 1, false);
    push(r, 13 * MS, 480, 8, 2, false);
    push(r, 18 * MS, 480, 8, 3, false);
    push(r, 40 * MS, 480, 8, 4, false);
    finish(r);

    out("scenario skip to first", .{});
    r = start("S16LE", 8000, "interleaved", .{ .@"skip-to-first" = @as(c.gboolean, 1) });
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, 500 * MS, 80, 4, 1, false);
    push(r, 510 * MS, 80, 4, 2, false);
    finish(r);

    out("scenario no skip", .{});
    r = start("S16LE", 8000, "interleaved", .{});
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, 500 * MS, 80, 4, 1, false);
    finish(r);

    out("scenario gap event and eos fill", .{});
    r = start("S16LE", 16000, "interleaved", .{});
    segment(r, c.GST_FORMAT_TIME, 0, 900 * MS);
    push(r, 0, 160, 4, 1, false);
    _ = c.gst_pad_push_event(r.src, c.gst_event_new_gap(400 * MS, 100 * MS));
    push(r, 500 * MS, 160, 4, 2, false);
    finish(r);

    out("scenario non interleaved", .{});
    r = start("S16LE", 8000, "non-interleaved", .{});
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, 0, 80, 4, 1, false);
    push(r, 1200 * MS, 80, 4, 2, false);
    finish(r);

    out("scenario segment change", .{});
    r = start("S16LE", 8000, "interleaved", .{});
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, 0, 80, 4, 1, false);
    segment(r, c.GST_FORMAT_TIME, 100 * MS, NONE);
    push(r, 100 * MS, 80, 4, 2, false);
    push(r, 110 * MS, 80, 4, 3, false);
    finish(r);

    out("scenario clipped by segment", .{});
    r = start("S16LE", 8000, "interleaved", .{});
    segment(r, c.GST_FORMAT_TIME, 25 * MS, 45 * MS);
    push(r, 0, 800, 4, 1, false);
    finish(r);

    out("scenario no timestamp", .{});
    r = start("S16LE", 8000, "interleaved", .{});
    segment(r, c.GST_FORMAT_TIME, 0, NONE);
    push(r, NONE, 80, 4, 1, false);
    push(r, NONE, 80, 4, 2, false);
    finish(r);

    out("scenario not negotiated", .{});
    {
        const el = c.gst_element_factory_make("audiorate", null).?;
        const src = c.gst_pad_new("src", c.GST_PAD_SRC);
        _ = c.gst_pad_set_active(src, 1);
        const esink = c.gst_element_get_static_pad(el, "sink");
        _ = c.gst_pad_link(src, esink);
        c.gst_object_unref(esink);
        const bus = c.gst_bus_new();
        c.gst_element_set_bus(el, bus);
        _ = c.gst_element_set_state(el, c.GST_STATE_PLAYING);
        _ = c.gst_pad_push_event(src, c.gst_event_new_stream_start("s"));
        var seg: c.GstSegment = undefined;
        c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
        _ = c.gst_pad_push_event(src, c.gst_event_new_segment(&seg));
        out("  push ret {d}", .{c.gst_pad_push(src, c.gst_buffer_new_allocate(null, 16, null))});
        if (c.gst_bus_pop_filtered(bus, c.GST_MESSAGE_ERROR)) |m| {
            var err: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &err, &dbg);
            out("  error {s} {d} [{s}]", .{ z(c.g_quark_to_string(err.*.domain)), err.*.code, z(dbg) });
            c.g_error_free(err);
            c.g_free(dbg);
            c.gst_message_unref(m);
        }
        _ = c.gst_element_set_state(el, c.GST_STATE_NULL);
        c.gst_object_unref(bus);
        c.gst_object_unref(el);
        c.gst_object_unref(src);
    }
    out("done", .{});
}
