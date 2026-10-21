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

fn capsStr(caps: [*c]c.GstCaps) []const u8 {
    if (caps == null) return "(null)";
    return str(c.gst_caps_to_string(caps));
}

var chained: u32 = 0;
var last_pts: u64 = 0;

fn chain(_: ?*c.GstPad, _: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    chained += 1;
    last_pts = b.*.pts;
    c.gst_mini_object_unref(@ptrCast(b));
    return c.GST_FLOW_OK;
}

var events_seen: [32]u8 = undefined;
var events_len: usize = 0;

fn sinkEvent(p: ?*c.GstPad, parent: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const n = std.mem.span(c.gst_event_type_get_name(e.*.type));
    out("  sink event {s}", .{n});
    return c.gst_pad_event_default(p, parent, e);
}

fn linked(_: ?*c.GstPad, peer: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    out("  linked signal peer {s}", .{str(c.gst_object_get_name(@ptrCast(@alignCast(peer))))});
}

fn probeCb(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const mode: usize = @intFromPtr(data);
    out("  probe type 0x{x} mode {d}", .{ info.*.type, mode });
    return switch (mode) {
        1 => c.GST_PAD_PROBE_DROP,
        2 => c.GST_PAD_PROBE_REMOVE,
        3 => c.GST_PAD_PROBE_PASS,
        else => c.GST_PAD_PROBE_OK,
    };
}

fn getrange(_: ?*c.GstPad, _: [*c]c.GstObject, offset: u64, size: c.guint, b: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    if (offset >= 100) return c.GST_FLOW_EOS;
    if (b.* == null) b.* = c.gst_buffer_new_allocate(null, size, null);
    b.*.*.offset = offset;
    return c.GST_FLOW_OK;
}

fn eachSticky(_: ?*c.GstPad, e: [*c][*c]c.GstEvent, _: c.gpointer) callconv(.c) c.gboolean {
    out("  sticky {s}", .{str(c.gst_event_type_get_name(e.*.*.type))});
    return 1;
}

fn typeSize(t: c.GType) struct { u32, u32 } {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(t, &q);
    return .{ q.instance_size, q.class_size };
}

pub fn main() void {
    c.gst_init(null, null);
    const ps = typeSize(c.gst_pad_get_type());
    const ts = typeSize(c.gst_pad_template_get_type());
    out("sizes pad {d} {d} template {d} {d}", .{ ps[0], ps[1], ts[0], ts[1] });
    out("flow names {s} {s} {s} {s} quark {s}", .{ str(c.gst_flow_get_name(c.GST_FLOW_OK)), str(c.gst_flow_get_name(-1000)), str(c.gst_flow_get_name(1000)), str(c.gst_flow_get_name(-7)), str(c.g_quark_to_string(c.gst_flow_to_quark(c.GST_FLOW_EOS))) });
    out("link names {s} {s} mode {s}", .{ str(c.gst_pad_link_get_name(c.GST_PAD_LINK_NOFORMAT)), str(c.gst_pad_link_get_name(c.GST_PAD_LINK_REFUSED)), str(c.gst_pad_mode_get_name(c.GST_PAD_MODE_PULL)) });
    const src = c.gst_pad_new("src", c.GST_PAD_SRC);
    const sink = c.gst_pad_new("sink", c.GST_PAD_SINK);
    out("new floating {d} dir {d} {d} flags 0x{x} active {d} mode {d}", .{ c.g_object_is_floating(src), c.gst_pad_get_direction(src), c.gst_pad_get_direction(sink), @as(*c.GstObject, @ptrCast(@alignCast(src))).flags, c.gst_pad_is_active(src), c.gst_pad_get_last_flow_return(src) });
    var dir: c.gint = 0;
    var tmpl: ?*anyopaque = null;
    var off: i64 = 7;
    c.g_object_get(src, "direction", &dir, "template", &tmpl, "offset", &off, @as([*c]const u8, null));
    out("props dir {d} template {d} offset {d}", .{ dir, @intFromBool(tmpl == null), off });
    _ = c.g_signal_connect_data(sink, "linked", @ptrCast(&linked), null, null, 0);
    out("can link {d} reverse {d}", .{ c.gst_pad_can_link(src, sink), c.gst_pad_can_link(sink, src) });
    out("link {d} linked {d} again {d}", .{ c.gst_pad_link(src, sink), c.gst_pad_is_linked(src), c.gst_pad_link(src, sink) });
    const peer = c.gst_pad_get_peer(src);
    out("peer ok {d}", .{@intFromBool(peer == sink)});
    c.gst_object_unref(peer);
    out("wrong dir {d}", .{c.gst_pad_link(sink, src)});
    c.gst_pad_set_chain_function_full(sink, chain, null, null);
    c.gst_pad_set_event_function_full(sink, sinkEvent, null, null);
    const b0 = c.gst_buffer_new();
    out("push inactive {d}", .{c.gst_pad_push(src, b0)});
    out("activate {d} {d} active {d} mode {d}", .{ c.gst_pad_set_active(sink, 1), c.gst_pad_set_active(src, 1), c.gst_pad_is_active(src), c.gst_pad_get_last_flow_return(src) });
    out("needs reconfigure {d} check {d} again {d}", .{ c.gst_pad_needs_reconfigure(src), c.gst_pad_check_reconfigure(src), c.gst_pad_check_reconfigure(src) });
    out("push event stream-start {d}", .{c.gst_pad_push_event(src, c.gst_event_new_stream_start("abc"))});
    const caps = c.gst_caps_from_string("audio/x-raw, rate=(int)48000");
    out("push caps {d}", .{c.gst_pad_push_event(src, c.gst_event_new_caps(caps))});
    out("current caps {s} has {d}", .{ capsStr(c.gst_pad_get_current_caps(sink)), c.gst_pad_has_current_caps(src) });
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    out("push segment {d}", .{c.gst_pad_push_event(src, c.gst_event_new_segment(&seg))});
    const b1 = c.gst_buffer_new();
    b1.*.pts = 42;
    out("push buffer {d} chained {d} pts {d}", .{ c.gst_pad_push(src, b1), chained, last_pts });
    out("stream id {s}", .{str(c.gst_pad_get_stream_id(sink))});
    c.gst_pad_sticky_events_foreach(sink, eachSticky, null);
    const se = c.gst_pad_get_sticky_event(src, c.GST_EVENT_CAPS, 0);
    out("sticky caps on src {d}", .{@intFromBool(se != null)});
    if (se != null) c.gst_mini_object_unref(@ptrCast(se));
    out("misorder {d}", .{c.gst_pad_push_event(src, c.gst_event_new_stream_start("abc"))});
    out("query caps {s}", .{capsStr(c.gst_pad_query_caps(sink, null))});
    out("peer query caps {s}", .{capsStr(c.gst_pad_peer_query_caps(src, null))});
    const filt = c.gst_caps_from_string("audio/x-raw, rate=(int){ 44100, 48000 }; video/x-raw");
    out("query caps filter {s}", .{capsStr(c.gst_pad_query_caps(sink, filt))});
    out("accept {d}", .{c.gst_pad_query_accept_caps(sink, caps)});
    out("allowed {s}", .{capsStr(c.gst_pad_get_allowed_caps(src))});
    var pos: i64 = 0;
    out("position {d} {d}", .{ c.gst_pad_query_position(sink, c.GST_FORMAT_TIME, &pos), pos });
    var dv: i64 = 0;
    out("convert same {d} {d}", .{ c.gst_pad_query_convert(sink, c.GST_FORMAT_TIME, 5, c.GST_FORMAT_TIME, &dv), dv });
    const id1 = c.gst_pad_add_probe(src, c.GST_PAD_PROBE_TYPE_BUFFER, probeCb, @ptrFromInt(1), null);
    const b2 = c.gst_buffer_new();
    b2.*.pts = 43;
    out("drop probe push {d} chained {d}", .{ c.gst_pad_push(src, b2), chained });
    c.gst_pad_remove_probe(src, id1);
    c.gst_pad_remove_probe(src, id1);
    _ = c.gst_pad_add_probe(src, c.GST_PAD_PROBE_TYPE_BUFFER, probeCb, @ptrFromInt(2), null);
    out("remove probe push {d} {d} chained {d}", .{ c.gst_pad_push(src, c.gst_buffer_new()), c.gst_pad_push(src, c.gst_buffer_new()), chained });
    const idle = c.gst_pad_add_probe(src, c.GST_PAD_PROBE_TYPE_IDLE, probeCb, @ptrFromInt(0), null);
    out("idle id nonzero {d}", .{@intFromBool(idle != 0)});
    c.gst_pad_remove_probe(src, idle);
    const blk = c.gst_pad_add_probe(src, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, null, null, null);
    out("blocked {d} blocking {d} flags 0x{x}", .{ c.gst_pad_is_blocked(src), c.gst_pad_is_blocking(src), @as(*c.GstObject, @ptrCast(@alignCast(src))).flags });
    c.gst_pad_remove_probe(src, blk);
    out("unblocked {d}", .{c.gst_pad_is_blocked(src)});
    out("flush start {d} push {d}", .{ c.gst_pad_push_event(src, c.gst_event_new_flush_start()), c.gst_pad_push(src, c.gst_buffer_new()) });
    out("flush stop {d}", .{c.gst_pad_push_event(src, c.gst_event_new_flush_stop(1))});
    out("after flush push {d}", .{c.gst_pad_push(src, c.gst_buffer_new())});
    out("eos {d} push {d} last {d}", .{ c.gst_pad_push_event(src, c.gst_event_new_eos()), c.gst_pad_push(src, c.gst_buffer_new()), c.gst_pad_get_last_flow_return(src) });
    out("wrong dir event {d}", .{c.gst_pad_push_event(src, c.gst_event_new_reconfigure())});
    out("send reconfigure {d} needs {d}", .{ c.gst_pad_send_event(src, c.gst_event_new_reconfigure()), c.gst_pad_needs_reconfigure(src) });
    c.gst_pad_set_offset(src, 100);
    out("offset {d}", .{c.gst_pad_get_offset(src)});
    out("unlink {d} again {d} linked {d}", .{ c.gst_pad_unlink(src, sink), c.gst_pad_unlink(src, sink), c.gst_pad_is_linked(sink) });
    out("push unlinked {d}", .{c.gst_pad_push(src, c.gst_buffer_new())});
    out("deactivate {d} {d} caps after {s}", .{ c.gst_pad_set_active(src, 0), c.gst_pad_set_active(sink, 0), capsStr(c.gst_pad_get_current_caps(sink)) });
    const psrc = c.gst_pad_new("psrc", c.GST_PAD_SRC);
    const psink = c.gst_pad_new("psink", c.GST_PAD_SINK);
    out("pull without range {d}", .{c.gst_pad_activate_mode(psrc, c.GST_PAD_MODE_PULL, 1)});
    c.gst_pad_set_getrange_function_full(psrc, getrange, null, null);
    _ = c.gst_pad_link(psrc, psink);
    out("pull activate {d} src mode active {d}", .{ c.gst_pad_activate_mode(psink, c.GST_PAD_MODE_PULL, 1), c.gst_pad_is_active(psrc) });
    var pb: [*c]c.GstBuffer = null;
    out("pull {d} size {d} offset {d}", .{ c.gst_pad_pull_range(psink, 10, 16, &pb), c.gst_buffer_get_size(pb), pb.*.offset });
    c.gst_mini_object_unref(@ptrCast(pb));
    pb = null;
    out("pull eos {d} null {d}", .{ c.gst_pad_pull_range(psink, 200, 16, &pb), @intFromBool(pb == null) });
    out("push in pull mode {d}", .{c.gst_pad_push(psrc, c.gst_buffer_new())});
    out("deactivate pull {d} {d}", .{ c.gst_pad_activate_mode(psink, c.GST_PAD_MODE_PULL, 0), c.gst_pad_is_active(psrc) });
    const tcaps = c.gst_caps_from_string("video/x-raw");
    const templ = c.gst_pad_template_new("src_%u", c.GST_PAD_SRC, c.GST_PAD_REQUEST, tcaps);
    out("template {s} dir {d} presence {d} caps {s}", .{ str(templ.*.name_template), templ.*.direction, templ.*.presence, capsStr(c.gst_pad_template_get_caps(templ)) });
    out("bad templates {d} {d} {d}", .{ @intFromBool(c.gst_pad_template_new("x_%d", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, tcaps) == null), @intFromBool(c.gst_pad_template_new("x_%s_%d", c.GST_PAD_SRC, c.GST_PAD_REQUEST, tcaps) == null), @intFromBool(c.gst_pad_template_new("x_%d%d", c.GST_PAD_SRC, c.GST_PAD_REQUEST, tcaps) == null) });
    const tp = c.gst_pad_new_from_template(templ, "src_0");
    out("from template {s} templ caps {s} sep ok", .{ str(c.gst_object_get_name(@ptrCast(@alignCast(tp)))), capsStr(c.gst_pad_get_pad_template_caps(tp)) });
    const tsink = c.gst_pad_new("tsink", c.GST_PAD_SINK);
    const atempl = c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, c.gst_caps_from_string("audio/x-raw"));
    const asink = c.gst_pad_new_from_template(atempl, "asink");
    out("noformat {d} ok {d}", .{ c.gst_pad_link(tp, asink), c.gst_pad_link(tp, tsink) });
    out("doc caps {s}", .{capsStr(c.gst_pad_template_get_documentation_caps(templ))});
    var st = c.GstStaticPadTemplate{ .name_template = "ssrc", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "audio/x-raw, channels=(int)2" } };
    const sp = c.gst_pad_new_from_static_template(&st, "s");
    out("static {s} caps {s}", .{ str(c.gst_object_get_name(@ptrCast(@alignCast(sp)))), capsStr(c.gst_static_pad_template_get_caps(&st)) });
    const path = c.gst_object_get_path_string(@ptrCast(@alignCast(sp)));
    out("path {s}", .{str(path)});
    out("chain no func {d}", .{blk2: {
        const s2 = c.gst_pad_new("x", c.GST_PAD_SINK);
        _ = c.gst_pad_set_active(s2, 1);
        break :blk2 c.gst_pad_chain(s2, c.gst_buffer_new());
    }});
    out("send wrong {d}", .{c.gst_pad_send_event(sink, c.gst_event_new_reconfigure())});
}
