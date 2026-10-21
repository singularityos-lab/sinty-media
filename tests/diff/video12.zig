const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn rects() void {
    out("center", .{});
    const cases = [_][2]c.GstVideoRectangle{
        .{ .{ .x = 0, .y = 0, .w = 320, .h = 240 }, .{ .x = 0, .y = 0, .w = 640, .h = 360 } },
        .{ .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, .{ .x = 10, .y = 20, .w = 800, .h = 600 } },
        .{ .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .{ .x = 5, .y = 5, .w = 50, .h = 50 } },
        .{ .{ .x = 0, .y = 0, .w = 7, .h = 3 }, .{ .x = -4, .y = 9, .w = 13, .h = 11 } },
        .{ .{ .x = 0, .y = 0, .w = 5, .h = 0 }, .{ .x = 0, .y = 0, .w = 13, .h = 11 } },
    };
    for (cases) |cs| for ([_]c.gboolean{ 0, 1 }) |sc| {
        var r = c.GstVideoRectangle{ .x = -1, .y = -1, .w = -1, .h = -1 };
        c.gst_video_center_rect(&cs[0], &cs[1], &r, sc);
        var r2 = c.GstVideoRectangle{ .x = -1, .y = -1, .w = -1, .h = -1 };
        c.gst_video_sink_center_rect(cs[0], cs[1], &r2, sc);
        out("  {any} {any} s{d}: {any} {any}", .{ cs[0], cs[1], sc, r, r2 });
    };
    c.gst_video_center_rect(null, null, null, 0);
}

fn showFrame(_: [*c]c.GstVideoSink, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    out("    show_frame pts {d}", .{b[0].pts});
    return c.GST_FLOW_OK;
}

fn setInfo(_: [*c]c.GstVideoSink, caps: [*c]c.GstCaps, i: [*c]const c.GstVideoInfo) callconv(.c) c.gboolean {
    const s = c.gst_caps_to_string(caps);
    out("    set_info {s} {d}x{d}", .{ s, i[0].width, i[0].height });
    c.g_free(s);
    return 1;
}

fn sinkClassA(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const vc: *c.GstVideoSinkClass = @ptrCast(@alignCast(k));
    vc.show_frame = showFrame;
    vc.set_info = setInfo;
}

fn sinks() void {
    out("sink", .{});
    const ta = c.g_type_register_static_simple(c.gst_video_sink_get_type(), "TSinkA", @sizeOf(c.GstVideoSinkClass), sinkClassA, @sizeOf(c.GstVideoSink), null, 0);
    const tb = c.g_type_register_static_simple(c.gst_video_sink_get_type(), "TSinkB", @sizeOf(c.GstVideoSinkClass), null, @sizeOf(c.GstVideoSink), null, 0);
    for ([_]c.GType{ ta, tb }) |t| {
        const o = c.g_object_new(t, null);
        const bs: [*c]c.GstBaseSink = @ptrCast(@alignCast(o));
        const k: *c.GstBaseSinkClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class));
        out("  {s} deadline {d} lateness {d} qos {d} w {d} h {d}", .{ c.g_type_name(t), c.gst_base_sink_get_processing_deadline(bs), c.gst_base_sink_get_max_lateness(bs), c.gst_base_sink_is_qos_enabled(bs), @as(*c.GstVideoSink, @ptrCast(@alignCast(o))).width, @as(*c.GstVideoSink, @ptrCast(@alignCast(o))).height });
        var show: c.gboolean = 7;
        c.g_object_get(o, "show-preroll-frame", &show, NONE);
        out("  show-preroll {d}", .{show});
        const caps = c.gst_caps_from_string("video/x-raw, format=I420, width=320, height=240, framerate=25/1");
        out("  set_caps {d}", .{k.set_caps.?(bs, caps)});
        const bad = c.gst_caps_from_string("audio/x-raw");
        out("  set_caps bad {d}", .{k.set_caps.?(bs, bad)});
        const b = c.gst_buffer_new();
        var st: c.GstClockTime = 111;
        var en: c.GstClockTime = 222;
        k.get_times.?(bs, b, &st, &en);
        out("  times none {d} {d}", .{ st, en });
        b[0].pts = 1000;
        k.get_times.?(bs, b, &st, &en);
        out("  times pts {d} {d}", .{ st, en });
        b[0].dts = 500;
        b[0].duration = 33;
        k.get_times.?(bs, b, &st, &en);
        out("  times dts {d} {d}", .{ st, en });
        out("  preroll {d} render {d}", .{ k.preroll.?(bs, b), k.render.?(bs, b) });
        c.g_object_set(o, "show-preroll-frame", @as(c.gboolean, 0), NONE);
        out("  preroll off {d}", .{k.preroll.?(bs, b)});
        const nofps = c.gst_caps_from_string("video/x-raw, format=RGBA, width=8, height=8, framerate=0/1");
        _ = k.set_caps.?(bs, nofps);
        b[0].duration = c.GST_CLOCK_TIME_NONE;
        st = 1;
        en = 2;
        k.get_times.?(bs, b, &st, &en);
        out("  times nofps {d} {d}", .{ st, en });
        bs[0].segment.rate = -1.0;
        k.get_times.?(bs, b, &st, &en);
        out("  times reverse {d} {d}", .{ st, en });
        out("  state {d}", .{c.gst_element_set_state(@ptrCast(@alignCast(o)), c.GST_STATE_READY)});
        out("  state {d}", .{c.gst_element_set_state(@ptrCast(@alignCast(o)), c.GST_STATE_NULL)});
        c.gst_caps_unref(nofps);
        c.gst_caps_unref(bad);
        c.gst_caps_unref(caps);
        c.gst_buffer_unref(b);
        c.gst_object_unref(o);
    }
    out("  abstract {d}", .{c.g_type_test_flags(c.gst_video_sink_get_type(), c.G_TYPE_FLAG_ABSTRACT)});
}

fn fSetInfo(_: [*c]c.GstVideoFilter, _: [*c]c.GstCaps, i: [*c]c.GstVideoInfo, _: [*c]c.GstCaps, o: [*c]c.GstVideoInfo) callconv(.c) c.gboolean {
    out("    set_info {d}x{d} -> {d}x{d}", .{ i[0].width, i[0].height, o[0].width, o[0].height });
    return @intFromBool(o[0].width != 13);
}

fn fFrame(_: [*c]c.GstVideoFilter, i: [*c]c.GstVideoFrame, o: [*c]c.GstVideoFrame) callconv(.c) c.GstFlowReturn {
    out("    transform_frame {d} {d} flags {d} {d}", .{ i[0].info.width, o[0].info.width, i[0].map[0].flags, o[0].map[0].flags });
    return c.GST_FLOW_OK;
}

fn fFrameIp(_: [*c]c.GstVideoFilter, f: [*c]c.GstVideoFrame) callconv(.c) c.GstFlowReturn {
    out("    transform_frame_ip {d} flags {d}", .{ f[0].info.width, f[0].map[0].flags });
    return c.GST_FLOW_CUSTOM_SUCCESS;
}

fn filterClassA(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const fc: *c.GstVideoFilterClass = @ptrCast(@alignCast(k));
    fc.set_info = fSetInfo;
    fc.transform_frame = fFrame;
    fc.transform_frame_ip = fFrameIp;
}

fn filterClassB(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const fc: *c.GstVideoFilterClass = @ptrCast(@alignCast(k));
    fc.transform_frame_ip = fFrameIp;
}

fn drain(bus: ?*c.GstBus) void {
    while (c.gst_bus_pop(bus)) |m| {
        var err: [*c]c.GError = null;
        var dbg: [*c]u8 = null;
        if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &err, &dbg) else c.gst_message_parse_warning(m, &err, &dbg);
        out("    msg {d} {s} | {s}", .{ m[0].type, err[0].message, dbg });
        c.g_error_free(err);
        c.g_free(dbg);
        c.gst_message_unref(m);
    }
}

fn showQuery(q: [*c]c.GstQuery) void {
    const np = c.gst_query_get_n_allocation_pools(q);
    out("    pools {d} params {d} metas {d}", .{ np, c.gst_query_get_n_allocation_params(q), c.gst_query_get_n_allocation_metas(q) });
    if (np > 0) {
        var p: [*c]c.GstBufferPool = null;
        var size: c.guint = 0;
        var mn: c.guint = 0;
        var mx: c.guint = 0;
        c.gst_query_parse_nth_allocation_pool(q, 0, &p, &size, &mn, &mx);
        if (p != null) {
            const cfg = c.gst_buffer_pool_get_config(p);
            const s = c.gst_structure_to_string(cfg);
            out("    pool {s} {d} {d} {d} {s}", .{ @as(*c.GstObject, @ptrCast(@alignCast(p))).name, size, mn, mx, s });
            c.g_free(s);
            c.gst_structure_free(cfg);
            c.gst_object_unref(p);
        } else out("    pool null {d}", .{size});
    }
}

fn filters() void {
    out("filter", .{});
    const ta = c.g_type_register_static_simple(c.gst_video_filter_get_type(), "TFilterA", @sizeOf(c.GstVideoFilterClass), filterClassA, @sizeOf(c.GstVideoFilter), null, 0);
    const tb = c.g_type_register_static_simple(c.gst_video_filter_get_type(), "TFilterB", @sizeOf(c.GstVideoFilterClass), filterClassB, @sizeOf(c.GstVideoFilter), null, 0);
    for ([_]c.GType{ ta, tb }) |t| {
        const o = c.g_object_new(t, "name", "flt", NONE);
        const bt: [*c]c.GstBaseTransform = @ptrCast(@alignCast(o));
        const k: *c.GstBaseTransformClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class));
        const bus = c.gst_bus_new();
        c.gst_element_set_bus(@ptrCast(@alignCast(o)), bus);
        out("  {s} qos {d} negotiated {d}", .{ c.g_type_name(t), c.gst_base_transform_is_qos_enabled(bt), @as(*c.GstVideoFilter, @ptrCast(@alignCast(o))).negotiated });
        const in = c.gst_caps_from_string("video/x-raw, format=RGBA, width=16, height=8");
        const outc = c.gst_caps_from_string("video/x-raw, format=RGBA, width=13, height=8");
        const b = c.gst_buffer_new_allocate(null, 16 * 8 * 4, null);
        const ob = c.gst_buffer_new_allocate(null, 16 * 8 * 4, null);
        out("  transform pre {d}", .{k.transform.?(bt, b, ob)});
        out("  transform_ip pre {d}", .{k.transform_ip.?(bt, b)});
        drain(bus);
        out("  set_caps bad {d}", .{k.set_caps.?(bt, in, outc)});
        out("  set_caps {d} in_place {d} ip_on_pass {d}", .{ k.set_caps.?(bt, in, in), c.gst_base_transform_is_in_place(bt), k.transform_ip_on_passthrough });
        var os: c.gsize = 0;
        out("  size {d} {d}", .{ k.transform_size.?(bt, c.GST_PAD_SINK, in, 4, outc, &os), os });
        out("  unit {d} {d}", .{ k.get_unit_size.?(bt, outc, &os), os });
        const junk = c.gst_caps_from_string("foo/bar");
        out("  unit bad {d}", .{k.get_unit_size.?(bt, junk, &os)});
        out("  transform {d}", .{k.transform.?(bt, b, ob)});
        out("  transform_ip {d}", .{k.transform_ip.?(bt, b)});
        const small = c.gst_buffer_new_allocate(null, 4, null);
        out("  transform small {d}", .{k.transform.?(bt, small, ob)});
        out("  transform_ip small {d}", .{k.transform_ip.?(bt, small)});
        drain(bus);
        c.gst_base_transform_set_passthrough(bt, 1);
        out("  transform_ip pass {d}", .{k.transform_ip.?(bt, b)});
        const vm = c.gst_buffer_add_video_meta(b, 0, c.GST_VIDEO_FORMAT_RGBA, 16, 8);
        _ = c.gst_buffer_add_meta(b, c.gst_video_crop_meta_get_info(), null);
        const ob2 = c.gst_buffer_new();
        out("  meta video {d} crop {d}", .{ k.transform_meta.?(bt, ob2, @ptrCast(vm), b), k.transform_meta.?(bt, ob2, c.gst_buffer_get_meta(b, c.gst_video_crop_meta_api_get_type()), b) });
        const pq = c.gst_query_new_allocation(in, 1);
        out("  propose null {d}", .{k.propose_allocation.?(bt, null, pq)});
        showQuery(pq);
        const dq = c.gst_query_new_allocation(in, 1);
        out("  propose {d}", .{k.propose_allocation.?(bt, dq, pq)});
        showQuery(pq);
        out("  propose again {d}", .{k.propose_allocation.?(bt, dq, pq)});
        showQuery(pq);
        const nq = c.gst_query_new_allocation(null, 1);
        out("  propose nocaps {d}", .{k.propose_allocation.?(bt, dq, nq)});
        const aq = c.gst_query_new_allocation(in, 1);
        out("  decide {d}", .{k.decide_allocation.?(bt, aq)});
        showQuery(aq);
        const aq2 = c.gst_query_new_allocation(in, 1);
        c.gst_query_add_allocation_meta(aq2, c.gst_video_meta_api_get_type(), null);
        c.gst_query_add_allocation_pool(aq2, null, 999, 2, 5);
        out("  decide pool {d}", .{k.decide_allocation.?(bt, aq2)});
        showQuery(aq2);
        for ([_][*c]c.GstQuery{ pq, dq, nq, aq, aq2 }) |q| c.gst_query_unref(q);
        c.gst_buffer_unref(ob2);
        c.gst_buffer_unref(small);
        c.gst_caps_unref(junk);
        c.gst_buffer_unref(b);
        c.gst_buffer_unref(ob);
        c.gst_caps_unref(in);
        c.gst_caps_unref(outc);
        c.gst_element_set_bus(@ptrCast(@alignCast(o)), null);
        c.gst_object_unref(bus);
        c.gst_object_unref(o);
    }
    out("  abstract {d}", .{c.g_type_test_flags(c.gst_video_filter_get_type(), c.G_TYPE_FLAG_ABSTRACT)});
}

pub fn main() void {
    c.gst_init(null, null);
    rects();
    sinks();
    filters();
}
