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

var sink_t = c.GstStaticPadTemplate{ .name_template = "sink", .direction = c.GST_PAD_SINK, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "ANY" } };

fn latencyQuery(e: [*c]c.GstElement, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    _ = e;
    if (q.*.type == c.GST_QUERY_LATENCY) {
        c.gst_query_set_latency(q, 1, 20 * c.GST_MSECOND, 10 * c.GST_MSECOND);
        return 1;
    }
    return 0;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &sink_t);
    c.gst_element_class_set_static_metadata(ek, "T", "Sink", "t", "n");
    ek.query = latencyQuery;
}

fn sinkType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_element_get_type(), "PipeTestSink", @sizeOf(c.GstElementClass), classInit, @sizeOf(c.GstElement), null, 0);
    return S.t;
}

fn drain(bus: [*c]c.GstBus) void {
    while (true) {
        const m = c.gst_bus_pop(bus);
        if (m == null) break;
        const src = if (m.*.src != null) str(m.*.src.*.name) else "-";
        if (m.*.type == c.GST_MESSAGE_STATE_CHANGED) {
            var o: c.GstState = 0;
            var n: c.GstState = 0;
            var p: c.GstState = 0;
            c.gst_message_parse_state_changed(m, &o, &n, &p);
            out("  msg {s} state-changed {s}->{s} ({s})", .{ src, str(c.gst_state_get_name(o)), str(c.gst_state_get_name(n)), str(c.gst_state_get_name(p)) });
        } else if (m.*.type == c.GST_MESSAGE_WARNING) {
            var e: [*c]c.GError = null;
            var d: [*c]u8 = null;
            c.gst_message_parse_warning(m, &e, &d);
            out("  msg {s} warning {s} | {s}", .{ src, str(e.*.message), str(d) });
        } else out("  msg {s} {s}", .{ src, str(c.gst_message_type_get_name(m.*.type)) });
        c.gst_mini_object_unref(@ptrCast(m));
    }
}

pub fn main() void {
    c.gst_init(null, null);
    var q: c.GTypeQuery = undefined;
    c.g_type_query(c.gst_pipeline_get_type(), &q);
    out("sizes {d} {d}", .{ q.instance_size, q.class_size });
    const p: [*c]c.GstPipeline = @ptrCast(@alignCast(c.g_object_new(c.gst_pipeline_get_type(), "name", "pipe", @as([*c]const u8, null))));
    _ = c.gst_object_ref_sink(p);
    const bus = c.gst_pipeline_get_bus(p);
    var delay: u64 = 1;
    var flush: c.gboolean = 0;
    var lat: u64 = 0;
    c.g_object_get(p, "delay", &delay, "auto-flush-bus", &flush, "latency", &lat, @as([*c]const u8, null));
    out("props {d} {d} {d} live {d} configured {d} bus {d}", .{ delay, flush, lat, c.gst_pipeline_is_live(p), c.gst_pipeline_get_configured_latency(p), @intFromBool(bus != null) });
    const k: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "snk", @as([*c]const u8, null))));
    @as(*c.GstObject, @ptrCast(@alignCast(k))).flags |= c.GST_ELEMENT_FLAG_SINK;
    _ = c.gst_element_add_pad(k, c.gst_pad_new_from_static_template(&sink_t, "sink"));
    _ = c.gst_bin_add(@ptrCast(p), k);
    out("playing {d}", .{c.gst_element_set_state(@ptrCast(p), c.GST_STATE_PLAYING)});
    drain(bus);
    const clock = c.gst_pipeline_get_pipeline_clock(p);
    const sys = c.gst_system_clock_obtain();
    out("clock system {d} elem clock {d} base>0 {d} configured {d}", .{ @intFromBool(clock == sys), @intFromBool(c.gst_element_get_clock(k) == sys), @intFromBool(c.gst_element_get_base_time(@ptrCast(p)) > 0), c.gst_pipeline_get_configured_latency(p) });
    c.gst_pipeline_set_latency(p, 5 * c.GST_MSECOND);
    drain(bus);
    out("paused {d}", .{c.gst_element_set_state(@ptrCast(p), c.GST_STATE_PAUSED)});
    drain(bus);
    out("start time valid {d}", .{@intFromBool(c.gst_element_get_start_time(@ptrCast(p)) != c.GST_CLOCK_TIME_NONE)});
    out("null {d} flushing {d}", .{ c.gst_element_set_state(@ptrCast(p), c.GST_STATE_NULL), @intFromBool(@as(*c.GstObject, @ptrCast(@alignCast(bus))).flags & c.GST_BUS_FLUSHING != 0) });
    drain(bus);
    c.gst_pipeline_use_clock(p, null);
    out("fixed flags 0x{x} clock null {d}", .{ @as(*c.GstObject, @ptrCast(@alignCast(p))).flags, @intFromBool(c.gst_pipeline_get_pipeline_clock(p) == null) });
    c.gst_pipeline_auto_clock(p);
    c.gst_pipeline_set_delay(p, 7);
    c.gst_pipeline_set_auto_flush_bus(p, 0);
    out("delay {d} flush {d}", .{ c.gst_pipeline_get_delay(p), c.gst_pipeline_get_auto_flush_bus(p) });
    c.gst_pipeline_set_delay(p, c.GST_CLOCK_TIME_NONE);
    out("ready {d}", .{c.gst_element_set_state(@ptrCast(p), c.GST_STATE_READY)});
    out("null {d} flushing {d}", .{ c.gst_element_set_state(@ptrCast(p), c.GST_STATE_NULL), @intFromBool(@as(*c.GstObject, @ptrCast(@alignCast(bus))).flags & c.GST_BUS_FLUSHING != 0) });
    c.gst_object_unref(p);
    out("done", .{});
}
