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

var src_templ = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "audio/x-raw" } };
var sink_templ = c.GstStaticPadTemplate{ .name_template = "sink", .direction = c.GST_PAD_SINK, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = "audio/x-raw" } };
var req_templ = c.GstStaticPadTemplate{ .name_template = "src_%u", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_REQUEST, .static_caps = .{ .caps = null, .string = "ANY" } };

var transitions: [64]u8 = undefined;

fn requestNew(e: [*c]c.GstElement, t: [*c]c.GstPadTemplate, name: [*c]const u8, _: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const n = if (name != null) c.g_strdup(name) else c.g_strdup_printf("src_%u", @as(c_uint, @intCast(e.*.numsrcpads)));
    const p = c.gst_pad_new_from_template(t, n);
    c.g_free(n);
    _ = c.gst_element_add_pad(e, p);
    return p;
}

var parent_change: c.GstElementClass = undefined;
var base_change: ?*const fn ([*c]c.GstElement, c.GstStateChange) callconv(.c) c.GstStateChangeReturn = null;
var async_on = false;

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    out("  change {s}", .{str(c.gst_state_change_get_name(t))});
    const r = base_change.?(e, t);
    if (async_on and t == c.GST_STATE_CHANGE_READY_TO_PAUSED) return c.GST_STATE_CHANGE_ASYNC;
    return r;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ek, &src_templ);
    c.gst_element_class_add_static_pad_template(ek, &sink_templ);
    c.gst_element_class_add_static_pad_template(ek, &req_templ);
    c.gst_element_class_set_static_metadata(ek, "Test", "Generic", "A test element", "Nobody <nobody@example.com>");
    base_change = ek.change_state;
    ek.change_state = changeState;
    ek.request_new_pad = requestNew;
}

fn instInit(i: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const e: [*c]c.GstElement = @ptrCast(@alignCast(i));
    _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&src_templ, "src"));
    _ = c.gst_element_add_pad(e, c.gst_pad_new_from_static_template(&sink_templ, "sink"));
}

fn testType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_element_get_type(), "TestElem", @sizeOf(c.GstElementClass), classInit, @sizeOf(c.GstElement), instInit, 0);
    return S.t;
}

fn padAdded(_: [*c]c.GstElement, p: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    out("  pad-added {s}", .{str(c.gst_object_get_name(@ptrCast(@alignCast(p))))});
}

fn drain(bus: [*c]c.GstBus) void {
    while (true) {
        const m = c.gst_bus_pop(bus);
        if (m == null) break;
        if (m.*.type == c.GST_MESSAGE_STATE_CHANGED) {
            var o: c.GstState = 0;
            var n: c.GstState = 0;
            var p: c.GstState = 0;
            c.gst_message_parse_state_changed(m, &o, &n, &p);
            out("  msg state-changed {s} {s} {s}", .{ str(c.gst_state_get_name(o)), str(c.gst_state_get_name(n)), str(c.gst_state_get_name(p)) });
        } else out("  msg {s}", .{str(c.gst_message_type_get_name(m.*.type))});
        c.gst_mini_object_unref(@ptrCast(m));
    }
}

fn size(t: c.GType) struct { u32, u32 } {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(t, &q);
    return .{ q.instance_size, q.class_size };
}

pub fn main() void {
    c.gst_init(null, null);
    const es = size(c.gst_element_get_type());
    out("sizes element {d} {d} abstract {d}", .{ es[0], es[1], @intFromBool(c.G_TYPE_IS_ABSTRACT(c.gst_element_get_type()) != 0) });
    out("state names {s} {s} {s} {s} {s}", .{ str(c.gst_state_get_name(c.GST_STATE_PAUSED)), str(c.gst_state_get_name(9)), str(c.gst_state_change_return_get_name(c.GST_STATE_CHANGE_NO_PREROLL)), str(c.gst_state_change_get_name(c.GST_STATE_CHANGE_READY_TO_PAUSED)), str(c.gst_state_change_get_name(99)) });
    const e: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(testType(), "name", "t0", @as([*c]const u8, null))));
    _ = c.gst_object_ref_sink(e);
    _ = c.g_signal_connect_data(e, "pad-added", @ptrCast(&padAdded), null, null, 0);
    const k = @as(*c.GstElementClass, @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(e))).g_class)));
    out("meta {s} {s} templates {d} numpads {d} src {d} sink {d}", .{ str(c.gst_element_get_metadata(e, "long-name")), str(c.gst_element_class_get_metadata(k, "author")), k.numpadtemplates, e.*.numpads, e.*.numsrcpads, e.*.numsinkpads });
    out("state {d} target {d} next {d} pending {d} last {d}", .{ e.*.current_state, e.*.target_state, e.*.next_state, e.*.pending_state, e.*.last_return });
    const sp = c.gst_element_get_static_pad(e, "src");
    out("static pad {s} parent ok {d} missing {d}", .{ str(c.gst_object_get_name(@ptrCast(@alignCast(sp)))), @intFromBool(c.gst_pad_get_parent_element(sp) == e), @intFromBool(c.gst_element_get_static_pad(e, "nope") == null) });
    const dup = c.gst_pad_new("src", c.GST_PAD_SRC);
    out("add dup {d}", .{c.gst_element_add_pad(e, dup)});
    const r1 = c.gst_element_request_pad_simple(e, "src_%u");
    const r2 = c.gst_element_request_pad_simple(e, "src_7");
    out("request {s} {s} bad {d}", .{ str(c.gst_object_get_name(@ptrCast(@alignCast(r1)))), str(c.gst_object_get_name(@ptrCast(@alignCast(r2)))), @intFromBool(c.gst_element_request_pad_simple(e, "sink_%u") == null) });
    out("valid names {d} {d}", .{ @intFromBool(c.gst_element_request_pad_simple(e, "src_x") == null), @intFromBool(c.gst_element_request_pad_simple(e, "src_-1") == null) });
    c.gst_element_release_request_pad(e, r1);
    out("after release numpads {d}", .{e.*.numpads});
    const bus = c.gst_bus_new();
    c.gst_element_set_bus(e, bus);
    out("set ready {d}", .{c.gst_element_set_state(e, c.GST_STATE_READY)});
    drain(bus);
    out("set playing {d}", .{c.gst_element_set_state(e, c.GST_STATE_PLAYING)});
    drain(bus);
    var st: c.GstState = 0;
    var pe: c.GstState = 0;
    out("get state {d} {s} {s} pad active {d}", .{ c.gst_element_get_state(e, &st, &pe, 0), str(c.gst_state_get_name(st)), str(c.gst_state_get_name(pe)), c.gst_pad_is_active(sp) });
    out("set null {d}", .{c.gst_element_set_state(e, c.GST_STATE_NULL)});
    drain(bus);
    async_on = true;
    out("async paused {d}", .{c.gst_element_set_state(e, c.GST_STATE_PAUSED)});
    out("get async {d}", .{c.gst_element_get_state(e, &st, &pe, 1000000)});
    out("continue {d}", .{c.gst_element_continue_state(e, c.GST_STATE_CHANGE_SUCCESS)});
    drain(bus);
    out("lost state", .{});
    c.gst_element_lost_state(e);
    drain(bus);
    out("abort", .{});
    c.gst_element_abort_state(e);
    out("get after abort {d}", .{c.gst_element_get_state(e, &st, &pe, 0)});
    async_on = false;
    out("locked {d} set {d} again {d} is {d}", .{ c.gst_element_is_locked_state(e), c.gst_element_set_locked_state(e, 1), c.gst_element_set_locked_state(e, 1), c.gst_element_is_locked_state(e) });
    _ = c.gst_element_set_locked_state(e, 0);
    c.gst_element_set_base_time(e, 5);
    c.gst_element_set_start_time(e, 6);
    out("times {d} {d} running {d}", .{ c.gst_element_get_base_time(e), c.gst_element_get_start_time(e), c.gst_element_get_current_running_time(e) });
    const clock = c.gst_system_clock_obtain();
    out("set clock {d} has {d}", .{ c.gst_element_set_clock(e, clock), @intFromBool(c.gst_element_get_clock(e) == clock) });
    const ctx = c.gst_context_new("my.ctx", 0);
    c.gst_element_set_context(e, ctx);
    const got = c.gst_element_get_context(e, "my.ctx");
    out("context {d} list {d}", .{ @intFromBool(got != null), c.g_list_length(c.gst_element_get_contexts(e)) });
    const err = c.g_error_new_literal(c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, "decode broke");
    c.gst_element_message_full(e, c.GST_MESSAGE_ERROR, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, c.g_strdup("boom"), c.g_strdup("dbg"), "file.c", "fn", 12);
    c.g_error_free(err);
    const em = c.gst_bus_pop(bus);
    var ge: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    c.gst_message_parse_error(em, &ge, &dbg);
    out("error {s} debug {s}", .{ str(ge.*.message), str(dbg) });
    c.gst_element_message_full(e, c.GST_MESSAGE_WARNING, c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, null, null, "f.c", "g", 1);
    const wm = c.gst_bus_pop(bus);
    c.gst_message_parse_warning(wm, &ge, &dbg);
    out("warning {s} debug {s}", .{ str(ge.*.message), str(dbg) });
    out("printf {s} null {d}", .{ str(c._gst_element_error_printf("x %d %s", @as(c_int, 3), "y")), @intFromBool(c._gst_element_error_printf("") == null) });
    const e2: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(testType(), "name", "t1", @as([*c]const u8, null))));
    out("link {d} again {d}", .{ c.gst_element_link(e, e2), c.gst_element_link_pads(e, "src", e2, "sink") });
    c.gst_element_unlink(e, e2);
    out("unlink linked {d}", .{c.gst_pad_is_linked(sp)});
    out("link pads {d}", .{c.gst_element_link_pads(e, "src", e2, "sink")});
    c.gst_element_unlink_pads(e, "src", e2, "sink");
    out("compatible {s}", .{str(c.gst_object_get_name(@ptrCast(@alignCast(c.gst_element_get_compatible_pad(e2, sp, null)))))});
    const id = c.gst_pad_create_stream_id(sp, e, "audio");
    out("stream id len {d} suffix {s}", .{ std.mem.len(id), id[std.mem.len(id) - 6 ..] });
    var pos: i64 = 0;
    out("query pos {d} {d} seek {d}", .{ c.gst_element_query_position(e, c.GST_FORMAT_TIME, &pos), pos, c.gst_element_seek_simple(e, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_FLUSH, 0) });
    out("send event {d}", .{c.gst_element_send_event(e, c.gst_event_new_eos())});
    out("remove {d} wrong {d}", .{ c.gst_element_remove_pad(e, r2), c.gst_element_remove_pad(e2, sp) });
    drain(bus);
    _ = c.gst_element_set_state(e, c.GST_STATE_PAUSED);
    c.gst_object_unref(e2);
    drain(bus);
    out("done", .{});
}
