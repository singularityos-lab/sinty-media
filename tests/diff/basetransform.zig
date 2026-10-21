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

fn capsStr(caps: [*c]c.GstCaps) [*c]u8 {
    return if (caps != null) c.gst_caps_to_string(caps) else c.g_strdup("(null)");
}

var src_caps: [*c]const u8 = "x-test/a, rate=(int)[ 1, 100 ]";
var src_total: u32 = 4;
var src_count: u32 = 0;

fn srcCreate(_: [*c]c.GstPushSrc, out_buf: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    if (src_count >= src_total) return c.GST_FLOW_EOS;
    const b = c.gst_buffer_new_allocate(null, 8, null);
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_WRITE);
    for (0..8) |i| info.data[i] = @truncate(src_count * 8 + i);
    c.gst_buffer_unmap(b, &info);
    b[0].pts = src_count * 10 * MS;
    b[0].duration = 10 * MS;
    if (src_count == 2) b[0].mini_object.flags |= c.GST_BUFFER_FLAG_GAP;
    src_count += 1;
    out_buf.* = b;
    return c.GST_FLOW_OK;
}

fn srcClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string("x-test/a, rate=(int)[ 1, 100 ]; x-test/c");
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Src", "Source", "s", "x");
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).create = srcCreate;
    @as(*c.GstBaseSrcClass, @ptrCast(@alignCast(k))).get_caps = srcGetCaps;
}

fn srcGetCaps(_: [*c]c.GstBaseSrc, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const caps = c.gst_caps_from_string(src_caps);
    if (filter == null) return caps;
    const i = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(caps);
    return i;
}

fn srcInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_src_set_format(@ptrCast(@alignCast(instance)), c.GST_FORMAT_TIME);
}

fn srcType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_push_src_get_type(), "TTSrc", @sizeOf(c.GstPushSrcClass), srcClass, @sizeOf(c.GstPushSrc), srcInit, 0);
    return S.v;
}

fn sinkRender(_: [*c]c.GstBaseSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    var hex: [64]u8 = undefined;
    var n: usize = 0;
    for (0..@min(info.size, 16)) |i| {
        _ = std.fmt.bufPrint(hex[n..], "{x:0>2}", .{info.data[i]}) catch break;
        n += 2;
    }
    c.gst_buffer_unmap(b, &info);
    note("  sink got pts={d} size={d} flags={x} metas={d} [{s}]", .{ t(b[0].pts), c.gst_buffer_get_size(b), b[0].mini_object.flags & 0xffff, c.gst_buffer_get_n_meta(b, c.gst_reference_timestamp_meta_api_get_type()), hex[0..n] });
    return c.GST_FLOW_OK;
}

var sink_caps: [*c]const u8 = "ANY";

fn sinkClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const caps = c.gst_caps_from_string(sink_caps);
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Sink", "Sink", "k", "x");
    @as(*c.GstBaseSinkClass, @ptrCast(@alignCast(k))).render = sinkRender;
}

fn sinkType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_sink_get_type(), "TTSink", @sizeOf(c.GstBaseSinkClass), sinkClass, @sizeOf(c.GstBaseSink), null, 0);
    return S.v;
}

fn ipTransform(_: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    note("  transform_ip pts={d} writable={d}", .{ t(b[0].pts), c.gst_mini_object_is_writable(@ptrCast(@alignCast(b))) });
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &info, c.GST_MAP_WRITE) != 0) {
        info.data[0] = 0xee;
        c.gst_buffer_unmap(b, &info);
    }
    return c.GST_FLOW_OK;
}

fn tSetCaps(_: [*c]c.GstBaseTransform, in: [*c]c.GstCaps, o: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const a = capsStr(in);
    const b = capsStr(o);
    note("  set_caps {s} -> {s}", .{ str(a), str(b) });
    c.g_free(a);
    c.g_free(b);
    return 1;
}

fn tStart(_: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    note("  trans start", .{});
    return 1;
}

fn tStop(_: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    note("  trans stop", .{});
    return 1;
}

fn addTemplates(k: c.gpointer, sink: [*c]const u8, src: [*c]const u8) void {
    var caps = c.gst_caps_from_string(sink);
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    caps = c.gst_caps_from_string(src);
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Trans", "Filter", "t", "x");
}

fn ipClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    addTemplates(k, "x-test/a; x-test/c", "x-test/a; x-test/c");
    const bc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    bc.transform_ip = ipTransform;
    bc.set_caps = tSetCaps;
    bc.start = tStart;
    bc.stop = tStop;
}

fn ipType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_transform_get_type(), "TTInPlace", @sizeOf(c.GstBaseTransformClass), ipClass, @sizeOf(c.GstBaseTransform), null, 0);
    return S.v;
}

fn passClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    addTemplates(k, "ANY", "ANY");
}

fn passType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_transform_get_type(), "TTPass", @sizeOf(c.GstBaseTransformClass), passClass, @sizeOf(c.GstBaseTransform), null, 0);
    return S.v;
}

fn convTransformCaps(_: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const res = c.gst_caps_copy(caps);
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(res)) : (i += 1) {
        const s = c.gst_caps_get_structure(res, i);
        c.gst_structure_set_name(s, if (dir == c.GST_PAD_SINK) "x-test/b" else "x-test/a");
    }
    const a = capsStr(caps);
    const b = capsStr(res);
    note("  transform_caps dir={d} {s} -> {s} filter={d}", .{ dir, str(a), str(b), @intFromBool(filter != null) });
    c.g_free(a);
    c.g_free(b);
    if (filter != null) {
        const x = c.gst_caps_intersect_full(filter, res, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(res);
        return x;
    }
    return res;
}

fn convUnitSize(_: [*c]c.GstBaseTransform, caps: [*c]c.GstCaps, size: [*c]c.gsize) callconv(.c) c.gboolean {
    const s = c.gst_caps_get_structure(caps, 0);
    size.* = if (c.gst_structure_has_name(s, "x-test/b") != 0) 4 else 2;
    note("  unit size {s} = {d}", .{ str(c.gst_structure_get_name(s)), size.* });
    return 1;
}

fn convTransform(_: [*c]c.GstBaseTransform, in: [*c]c.GstBuffer, o: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var a: c.GstMapInfo = undefined;
    var b: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(in, &a, c.GST_MAP_READ);
    _ = c.gst_buffer_map(o, &b, c.GST_MAP_WRITE);
    for (0..b.size) |i| b.data[i] = a.data[i / 2];
    c.gst_buffer_unmap(in, &a);
    c.gst_buffer_unmap(o, &b);
    note("  transform in={d} out={d} pts={d}", .{ c.gst_buffer_get_size(in), c.gst_buffer_get_size(o), t(o[0].pts) });
    return c.GST_FLOW_OK;
}

fn convFixate(_: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, other: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    _ = caps;
    const o = c.gst_caps_make_writable(other);
    const s = c.gst_caps_get_structure(o, 0);
    _ = c.gst_structure_fixate_field_nearest_int(s, "rate", 42);
    note("  fixate dir={d}", .{dir});
    return c.gst_caps_fixate(o);
}

fn convClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    addTemplates(k, "x-test/a, rate=(int)[ 1, 100 ]", "x-test/b, rate=(int)[ 1, 100 ]");
    const bc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    bc.transform_caps = convTransformCaps;
    bc.get_unit_size = convUnitSize;
    bc.transform = convTransform;
    bc.fixate_caps = convFixate;
    bc.set_caps = tSetCaps;
}

fn convType() c.GType {
    const S = struct {
        var v: c.GType = 0;
    };
    if (S.v == 0) S.v = c.g_type_register_static_simple(c.gst_base_transform_get_type(), "TTConv", @sizeOf(c.GstBaseTransformClass), convClass, @sizeOf(c.GstBaseTransform), null, 0);
    return S.v;
}

fn messages(bus: ?*c.GstBus) void {
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 3 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_QOS) orelse {
            out("  bus timeout", .{});
            return;
        };
        defer c.gst_message_unref(m);
        switch (m[0].type) {
            c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
                var e: [*c]c.GError = null;
                var dbg: [*c]u8 = null;
                if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
                out("  msg {s}: {s} | {s}", .{ str(c.gst_message_type_get_name(m[0].type)), str(e[0].message), str(dbg) });
                c.g_clear_error(&e);
                c.g_free(dbg);
                if (m[0].type == c.GST_MESSAGE_ERROR) return;
            },
            c.GST_MESSAGE_QOS => {
                var processed: u64 = 0;
                var dropped: u64 = 0;
                var fmt: c.GstFormat = 0;
                c.gst_message_parse_qos_stats(m, &fmt, &processed, &dropped);
                var rt: u64 = 0;
                c.gst_message_parse_qos(m, null, &rt, null, null, null);
                out("  msg qos rt={d} processed={d} dropped={d}", .{ t(rt), processed, dropped });
            },
            else => {
                out("  msg eos", .{});
                return;
            },
        }
    }
}

fn run(trans: [*c]c.GstElement, label: []const u8, total: u32) void {
    out("== {s}", .{label});
    src_count = 0;
    src_total = total;
    const p = c.gst_pipeline_new("p");
    const src: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(srcType(), "name", "src", @as(?*anyopaque, null))));
    const sink: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(sinkType(), "name", "sink", "sync", @as(c.gboolean, 0), @as(?*anyopaque, null))));
    _ = c.gst_bin_add(@ptrCast(p), src);
    _ = c.gst_bin_add(@ptrCast(p), trans);
    _ = c.gst_bin_add(@ptrCast(p), sink);
    out("  link {d} {d}", .{ c.gst_element_link(src, trans), c.gst_element_link(trans, sink) });
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    messages(bus);
    flushLog();
    const tb: *c.GstBaseTransform = @ptrCast(@alignCast(trans));
    out("  passthrough {d} in_place {d} qos {d}", .{ c.gst_base_transform_is_passthrough(tb), c.gst_base_transform_is_in_place(tb), c.gst_base_transform_is_qos_enabled(tb) });
    var pos: i64 = 0;
    const sp = c.gst_element_get_static_pad(trans, "src");
    out("  src position {d} {d}", .{ c.gst_pad_query_position(sp, c.GST_FORMAT_TIME, &pos), pos });
    const kp = c.gst_element_get_static_pad(trans, "sink");
    out("  sink position {d} {d}", .{ c.gst_pad_query_position(kp, c.GST_FORMAT_TIME, &pos), pos });
    const cur = c.gst_pad_get_current_caps(sp);
    const cs = capsStr(cur);
    out("  src caps {s}", .{str(cs)});
    c.g_free(cs);
    if (cur != null) c.gst_caps_unref(cur);
    c.gst_object_unref(sp);
    c.gst_object_unref(kp);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    flushLog();
    c.gst_object_unref(bus);
    c.gst_object_unref(p);
}

fn showCaps(pad: ?*c.GstPad, filter: [*c]const u8) void {
    const f = if (filter != null) c.gst_caps_from_string(filter) else null;
    const r = c.gst_pad_query_caps(pad, f);
    const s = capsStr(r);
    flushLog();
    out("  caps({s}) = {s}", .{ str(filter), str(s) });
    c.g_free(s);
    c.gst_caps_unref(r);
    if (f != null) c.gst_caps_unref(f);
}

fn accept(pad: ?*c.GstPad, what: [*c]const u8) void {
    const cp = c.gst_caps_from_string(what);
    const r = c.gst_pad_query_accept_caps(pad, cp);
    flushLog();
    out("  accept {s} = {d}", .{ str(what), r });
    c.gst_caps_unref(cp);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    out("type {s} abstract {d}", .{ str(c.g_type_name(c.gst_base_transform_get_type())), c.g_type_test_flags(c.gst_base_transform_get_type(), c.G_TYPE_FLAG_ABSTRACT) });
    const pass: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(passType(), "name", "pass", @as(?*anyopaque, null))));
    const pt: *c.GstBaseTransform = @ptrCast(@alignCast(pass));
    out("  pass passthrough {d} in_place {d} same_caps {d} flags {x}", .{ c.gst_base_transform_is_passthrough(pt), c.gst_base_transform_is_in_place(pt), @as(*c.GstBaseTransformClass, @ptrCast(@alignCast(@as([*c]c.GTypeInstance, @ptrCast(pass))[0].g_class))).passthrough_on_same_caps, @as(*c.GstObject, @ptrCast(@alignCast(pt.sinkpad))).flags });
    c.gst_base_transform_set_passthrough(pt, 0);
    out("  pass after set false {d}", .{c.gst_base_transform_is_passthrough(pt)});
    run(pass, "passthrough", 3);

    const ip: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(ipType(), "name", "ip", @as(?*anyopaque, null))));
    const ipt: *c.GstBaseTransform = @ptrCast(@alignCast(ip));
    out("  ip passthrough {d} in_place {d}", .{ c.gst_base_transform_is_passthrough(ipt), c.gst_base_transform_is_in_place(ipt) });
    c.gst_base_transform_set_in_place(ipt, 0);
    out("  ip in_place after false {d}", .{c.gst_base_transform_is_in_place(ipt)});
    c.g_object_set(ip, "qos", @as(c.gboolean, 1), @as(?*anyopaque, null));
    run(ip, "in place", 4);

    const ip2: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(ipType(), "name", "ip2", @as(?*anyopaque, null))));
    c.gst_base_transform_set_passthrough(@ptrCast(@alignCast(ip2)), 1);
    run(ip2, "in place passthrough", 2);

    const conv: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(convType(), "name", "conv", @as(?*anyopaque, null))));
    const ct: *c.GstBaseTransform = @ptrCast(@alignCast(conv));
    out("  conv passthrough {d} in_place {d}", .{ c.gst_base_transform_is_passthrough(ct), c.gst_base_transform_is_in_place(ct) });
    c.gst_base_transform_set_gap_aware(ct, 1);
    run(conv, "converting", 3);

    out("== caps queries", .{});
    const conv2: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(convType(), "name", "conv2", @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(conv2);
    const sp = c.gst_element_get_static_pad(conv2, "src");
    const kp = c.gst_element_get_static_pad(conv2, "sink");
    showCaps(sp, null);
    showCaps(kp, null);
    showCaps(sp, "x-test/b, rate=(int)50");
    showCaps(kp, "x-test/a, rate=(int)[ 10, 20 ]");
    showCaps(kp, "x-test/z");
    accept(kp, "x-test/a, rate=(int)5");
    accept(kp, "x-test/b, rate=(int)5");
    accept(sp, "x-test/b, rate=(int)5");
    accept(sp, "x-test/a, rate=(int)500");
    c.gst_base_transform_set_prefer_passthrough(@ptrCast(@alignCast(conv2)), 0);
    showCaps(sp, null);
    c.gst_object_unref(sp);
    c.gst_object_unref(kp);
    out("  pool null {d}", .{@intFromBool(c.gst_base_transform_get_buffer_pool(@ptrCast(@alignCast(conv2))) == null)});
    c.gst_object_unref(conv2);

    out("== qos drop", .{});
    const ip3: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(ipType(), "name", "ip3", "qos", @as(c.gboolean, 1), @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(ip3);
    const ip3t: *c.GstBaseTransform = @ptrCast(@alignCast(ip3));
    _ = c.gst_element_set_state(ip3, c.GST_STATE_PAUSED);
    const isink = c.gst_element_get_static_pad(ip3, "sink");
    const isrc = c.gst_element_get_static_pad(ip3, "src");
    _ = c.gst_pad_set_active(isrc, 1);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    _ = c.gst_pad_send_event(isink, c.gst_event_new_stream_start("s"));
    const cc = c.gst_caps_from_string("x-test/a");
    out("  caps event {d}", .{c.gst_pad_send_event(isink, c.gst_event_new_caps(cc))});
    c.gst_caps_unref(cc);
    _ = c.gst_pad_send_event(isink, c.gst_event_new_segment(&seg));
    c.gst_base_transform_update_qos(ip3t, 1.5, @intCast(30 * MS), 0);
    const bus = c.gst_bus_new();
    c.gst_element_set_bus(ip3, bus);
    for ([_]u64{ 10, 20, 40 }) |ms| {
        const b = c.gst_buffer_new_allocate(null, 1, null);
        b[0].pts = ms * MS;
        out("  chain {d} -> {s}", .{ ms, str(c.gst_flow_get_name(c.gst_pad_chain(isink, b))) });
    }
    flushLog();
    while (c.gst_bus_pop(bus)) |m| {
        var processed: u64 = 0;
        var dropped: u64 = 0;
        c.gst_message_parse_qos_stats(m, null, &processed, &dropped);
        var jitter: i64 = 0;
        var prop: f64 = 0;
        c.gst_message_parse_qos_values(m, &jitter, &prop, null);
        out("  qos message processed={d} dropped={d} jitter={d} prop={d}", .{ processed, dropped, jitter, prop });
        c.gst_message_unref(m);
    }
    c.gst_element_set_bus(ip3, null);
    c.gst_object_unref(bus);
    _ = c.gst_element_set_state(ip3, c.GST_STATE_NULL);
    c.gst_object_unref(isink);
    c.gst_object_unref(isrc);
    c.gst_base_transform_update_qos(ip3t, 1.0, 0, NONE);
    c.gst_object_unref(ip3);
    flushLog();

    out("crit {d}", .{c.gst_base_transform_is_passthrough(null)});
    out("done", .{});
}
