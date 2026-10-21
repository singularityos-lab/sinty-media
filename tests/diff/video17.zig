const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);
const MS: u64 = 1_000_000;

fn ts(t: u64) i64 {
    return @bitCast(t);
}

var log_lock: c.GMutex = undefined;
var log_buf: [1 << 20]u8 = undefined;
var log_len: usize = 0;
var qline: [160]u8 = undefined;
var qline_len: usize = 0;

fn logf(comptime fmt: []const u8, args: anytype) void {
    c.g_mutex_lock(&log_lock);
    defer c.g_mutex_unlock(&log_lock);
    const s = std.fmt.bufPrint(log_buf[log_len..], fmt ++ "\n", args) catch return;
    log_len += s.len;
}

fn flushLog() void {
    c.g_mutex_lock(&log_lock);
    _ = std.c.write(1, &log_buf, log_len);
    log_len = 0;
    c.g_mutex_unlock(&log_lock);
}

fn capsStr(caps: [*c]c.GstCaps) void {
    if (caps == null) {
        out("    caps -", .{});
        return;
    }
    const s = c.gst_caps_to_string(caps);
    out("    caps {s}", .{s});
    c.g_free(s);
}

fn aggregateFrames(a: [*c]c.GstVideoAggregator, outbuf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const fmt = c.gst_video_format_to_string(a[0].info.finfo[0].format);
    logf("  aggregate pts {d} dur {d} out {s} {d}x{d} size {d}", .{ ts(outbuf[0].pts), ts(outbuf[0].duration), fmt, a[0].info.width, a[0].info.height, c.gst_buffer_get_size(outbuf) });
    var sum: u32 = 0;
    frames += 1;
    if (qos_test and frames == 2) {
        const ev = c.gst_event_new_qos(c.GST_QOS_TYPE_UNDERFLOW, 0.75, @intCast(200 * MS), outbuf[0].pts);
        _ = c.gst_pad_send_event(@as([*c]c.GstAggregator, @ptrCast(a))[0].srcpad, ev);
    }
    c.g_mutex_lock(&@as(*c.GstObject, @ptrCast(@alignCast(a))).lock);
    var l: [*c]c.GList = @as([*c]c.GstElement, @ptrCast(@alignCast(a)))[0].sinkpads;
    while (l != null) : (l = l[0].next) {
        const pad: ?*c.GstVideoAggregatorPad = @ptrCast(l[0].data);
        const name = c.gst_object_get_name(@ptrCast(@alignCast(pad)));
        var zo: c.guint = 0;
        c.g_object_get(pad, "zorder", &zo, NONE);
        const has = c.gst_video_aggregator_pad_has_current_buffer(pad);
        const cb = c.gst_video_aggregator_pad_get_current_buffer(pad);
        const pf = c.gst_video_aggregator_pad_get_prepared_frame(pad);
        if (pf != null) {
            const d: [*c]u8 = @ptrCast(pf[0].data[0]);
            sum +%= d[0];
            logf("    {s} z {d} has {d} buf pts {d} frame {s} {d}x{d} np {d} stride {d} px {d} {d} {d} {d}", .{ name, zo, has, ts(cb[0].pts), c.gst_video_format_to_string(pf[0].info.finfo[0].format), pf[0].info.width, pf[0].info.height, pf[0].info.finfo[0].n_planes, pf[0].info.stride[0], d[0], d[1], d[@intCast(pf[0].info.stride[0])], d[@as(usize, @intCast(pf[0].info.stride[0])) + 1] });
        } else logf("    {s} z {d} has {d} no frame", .{ name, zo, has });
        c.g_free(name);
    }
    c.g_mutex_unlock(&@as(*c.GstObject, @ptrCast(@alignCast(a))).lock);
    var mi: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(outbuf, &mi, c.GST_MAP_WRITE) != 0) {
        @memset(mi.data[0..mi.size], @truncate(sum));
        c.gst_buffer_unmap(outbuf, &mi);
    }
    return c.GST_FLOW_OK;
}

var pad_gtype: c.GType = 0;
var frames: usize = 0;
var qos_test = false;
const RANGES = ", width=(int)[1,2147483647], height=(int)[1,2147483647], framerate=(fraction)[0/1,2147483647/1]";
var src_caps_str: [*c]const u8 = "video/x-raw, format=(string){ AYUV, BGRA, I420 }" ++ RANGES;

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const vc: *c.GstVideoAggregatorClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, c.gst_caps_from_string(src_caps_str)));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new_with_gtype("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, c.gst_caps_from_string("video/x-raw, format=(string){ AYUV, BGRA, I420 }" ++ RANGES), pad_gtype));
    c.gst_element_class_set_static_metadata(ec, "t", "Filter/Editor/Video/Compositor", "t", "t");
    vc.aggregate_frames = aggregateFrames;
}

fn makeType(name: [*c]const u8, pt: c.GType) c.GType {
    pad_gtype = pt;
    const t = c.g_type_register_static_simple(c.gst_video_aggregator_get_type(), name, @sizeOf(c.GstVideoAggregatorClass), classInit, @sizeOf(c.GstVideoAggregator), null, 0);
    _ = c.g_type_class_ref(t);
    return t;
}

const Input = struct {
    format: [*c]const u8,
    w: c_int,
    h: c_int,
    n: usize,
    start: u64,
    dur: u64,
    fill: u8,
    zorder: c_int = -1,
    repeat: bool = false,
    alpha: bool = false,
    max_repeat: u64 = std.math.maxInt(u64),
};

fn inputInfo(in: Input) c.GstVideoInfo {
    var vi: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&vi, c.gst_video_format_from_string(in.format), @intCast(in.w), @intCast(in.h));
    vi.fps_n = 25;
    vi.fps_d = 1;
    return vi;
}

fn pushInput(src: *c.GstElement, in: Input) void {
    const vi = inputInfo(in);
    for (0..in.n) |i| {
        const b = c.gst_buffer_new_allocate(null, vi.size, null);
        var mi: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &mi, c.GST_MAP_WRITE);
        for (0..mi.size) |j| mi.data[j] = in.fill +% @as(u8, @truncate(i * 16 + j % 7));
        c.gst_buffer_unmap(b, &mi);
        b[0].pts = in.start + in.dur * i;
        b[0].duration = in.dur;
        var r: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &r);
        c.gst_buffer_unref(b);
    }
    var r: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &r);
}

fn busDump(pipe: *c.GstElement) void {
    const bus = c.gst_element_get_bus(pipe);
    while (true) {
        const m = c.gst_bus_pop(bus);
        if (m == null) break;
        switch (m[0].type) {
            c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
                var e: [*c]c.GError = null;
                var d: [*c]u8 = null;
                if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &d) else c.gst_message_parse_warning(m, &e, &d);
                out("  msg {s} {s} : {s}", .{ c.gst_message_type_get_name(m[0].type), e[0].message, if (d != null) std.mem.span(@as([*:0]const u8, @ptrCast(d))) else "-" });
                c.g_error_free(e);
                c.g_free(d);
            },
            c.GST_MESSAGE_QOS => {
                var live: c.gboolean = 0;
                var rt: u64 = 0;
                var st: u64 = 0;
                var tsv: u64 = 0;
                var du: u64 = 0;
                var jit: i64 = 0;
                var prop: f64 = 0;
                var q: c_int = 0;
                var f: c.GstFormat = 0;
                var proc: u64 = 0;
                var drop: u64 = 0;
                c.gst_message_parse_qos(m, &live, &rt, &st, &tsv, &du);
                c.gst_message_parse_qos_values(m, &jit, &prop, &q);
                c.gst_message_parse_qos_stats(m, &f, &proc, &drop);
                out("  qos live {d} rt {d} st {d} ts {d} dur {d} jit {d} prop {d:.2} q {d} stats {d} {d} {d}", .{ live, ts(rt), ts(st), ts(tsv), ts(du), jit, prop, q, f, proc, drop });
            },
            c.GST_MESSAGE_NEED_CONTEXT => {
                var ty: [*c]const u8 = null;
                _ = c.gst_message_parse_context_type(m, &ty);
                out("  need-context {s}", .{ty});
            },
            c.GST_MESSAGE_LATENCY => out("  latency", .{}),
            else => {},
        }
        c.gst_message_unref(m);
    }
    c.gst_object_unref(bus);
}

const Ctx = struct {
    src: *c.GstElement,
    in: Input,
};

fn feeder(p: c.gpointer) callconv(.c) c.gpointer {
    const ctx: *Ctx = @ptrCast(@alignCast(p));
    pushInput(ctx.src, ctx.in);
    return null;
}

fn run(title: []const u8, t: c.GType, inputs: []const Input, opts: struct { qos: bool = false, sinkcaps: [*c]const u8 = null, queries: bool = false }) void {
    out("== {s}", .{title});
    frames = 0;
    qos_test = opts.qos;
    const pipe = c.gst_pipeline_new("p");
    const agg_el: *c.GstElement = @ptrCast(@alignCast(c.g_object_new(t, "name", "agg", NONE)));
    const sink = c.gst_element_factory_make("appsink", "sink");
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), "emit-signals", @as(c.gboolean, 0), NONE);
    if (opts.sinkcaps != null) {
        const sc = c.gst_caps_from_string(opts.sinkcaps);
        c.g_object_set(sink, "caps", sc, NONE);
        c.gst_caps_unref(sc);
    }
    _ = c.gst_bin_add(@ptrCast(pipe), agg_el);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    _ = c.gst_element_link(agg_el, sink);
    var ctxs: [4]Ctx = undefined;
    for (inputs, 0..) |in, i| {
        var nb: [16]u8 = undefined;
        const nm = std.fmt.bufPrintZ(&nb, "src{d}", .{i}) catch unreachable;
        const src = c.gst_element_factory_make("appsrc", nm.ptr);
        var vi = inputInfo(in);
        const caps = c.gst_video_info_to_caps(&vi);
        c.g_object_set(src, "block", @as(c.gboolean, 1), "max-buffers", @as(c.guint64, 1), "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
        c.gst_caps_unref(caps);
        _ = c.gst_bin_add(@ptrCast(pipe), src);
        const sp = c.gst_element_request_pad_simple(agg_el, "sink_%u");
        if (in.zorder >= 0) c.g_object_set(sp, "zorder", @as(c.guint, @intCast(in.zorder)), NONE);
        if (in.repeat) c.g_object_set(sp, "repeat-after-eos", @as(c.gboolean, 1), NONE);
        if (in.max_repeat != std.math.maxInt(u64)) c.g_object_set(sp, "max-last-buffer-repeat", @as(c.guint64, in.max_repeat), NONE);
        if (in.alpha) c.gst_video_aggregator_pad_set_needs_alpha(@ptrCast(sp), 1);
        const srcpad = c.gst_element_get_static_pad(src, "src");
        _ = c.gst_pad_link(srcpad, sp);
        c.gst_object_unref(srcpad);
        c.gst_object_unref(sp);
        ctxs[i] = .{ .src = src.?, .in = in };
    }
    var l: [*c]c.GList = agg_el.sinkpads;
    out("  pads", .{});
    while (l != null) : (l = l[0].next) {
        const nm = c.gst_object_get_name(@ptrCast(@alignCast(l[0].data)));
        var zo: c.guint = 0;
        var rep: c.gboolean = 0;
        var mx: u64 = 0;
        c.g_object_get(l[0].data, "zorder", &zo, "repeat-after-eos", &rep, "max-last-buffer-repeat", &mx, NONE);
        out("    {s} z {d} rep {d} max {d}", .{ nm, zo, rep, ts(mx) });
        c.g_free(nm);
    }
    if (opts.queries) {
        const sp = c.gst_element_get_static_pad(agg_el, "sink_0");
        const q = c.gst_pad_query_caps(sp, null);
        capsStr(q);
        c.gst_caps_unref(q);
        const fq = c.gst_caps_from_string("video/x-raw, format=I420, width=4, height=4, framerate=25/1");
        out("    accept {d}", .{c.gst_pad_query_accept_caps(sp, fq)});
        c.gst_caps_unref(fq);
        const fq2 = c.gst_caps_from_string("video/x-raw, format=NV12, width=4, height=4, framerate=25/1, interlace-mode=interleaved");
        out("    accept2 {d}", .{c.gst_pad_query_accept_caps(sp, fq2)});
        c.gst_caps_unref(fq2);
        c.gst_object_unref(sp);
    }
    _ = c.gst_element_set_state(pipe, c.GST_STATE_PAUSED);
    var threads: [4]?*c.GThread = undefined;
    for (inputs, 0..) |_, i| threads[i] = c.g_thread_new("feed", feeder, &ctxs[i]);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_PLAYING);
    var n: usize = 0;
    var pulled: [64]u64 = undefined;
    var info_lines: [64][160]u8 = undefined;
    var info_len: [64]usize = undefined;
    while (true) {
        var sample: ?*c.GstSample = null;
        c.g_signal_emit_by_name(sink, "pull-sample", &sample);
        if (sample == null) break;
        const b = c.gst_sample_get_buffer(sample);
        var mi: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &mi, c.GST_MAP_READ);
        if (n == 0) capsStr(c.gst_sample_get_caps(sample));
        if (n < 64) {
            const s = std.fmt.bufPrint(&info_lines[n], "  out pts {d} dur {d} size {d} b {d} flags {d}", .{ ts(b[0].pts), ts(b[0].duration), mi.size, if (mi.size > 0) mi.data[0] else 0, b[0].mini_object.flags & ~@as(c.guint, c.GST_BUFFER_FLAG_TAG_MEMORY) }) catch "";
            info_len[n] = s.len;
            pulled[n] = b[0].pts;
        }
        c.gst_buffer_unmap(b, &mi);
        if (opts.queries and n == 0) {
            var pos: i64 = 0;
            var dur: i64 = 0;
            const r1 = c.gst_element_query_position(agg_el, c.GST_FORMAT_TIME, &pos);
            const r2 = c.gst_element_query_duration(agg_el, c.GST_FORMAT_TIME, &dur);
            const r3 = c.gst_element_query_position(agg_el, c.GST_FORMAT_BYTES, &pos);
            qline_len = if (std.fmt.bufPrint(&qline, "  query pos {d} dur {d} {d} bytes {d}", .{ @intFromBool(r1 != 0), @intFromBool(r2 != 0), dur, r3 })) |q| q.len else |_| 0;
        }
        c.gst_sample_unref(sample);
        n += 1;
    }
    for (inputs, 0..) |_, i| _ = c.g_thread_join(threads[i]);
    flushLog();
    for (0..@min(n, 64)) |i| out("{s}", .{info_lines[i][0..info_len[i]]});
    if (qline_len > 0) out("{s}", .{qline[0..qline_len]});
    qline_len = 0;
    out("  total {d}", .{n});
    const tp = c.gst_video_aggregator_get_execution_task_pool(@ptrCast(@alignCast(agg_el)));
    out("  task pool {s} shared {d}", .{ c.g_type_name_from_instance(@ptrCast(tp)), @intFromBool(c.g_type_check_instance_is_a(@ptrCast(tp), c.gst_shared_task_pool_get_type()) != 0) });
    c.gst_object_unref(tp);
    busDump(pipe);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    c.gst_object_unref(pipe);
}

fn propChecks(t: c.GType) void {
    out("== props", .{});
    const a: *c.GstElement = @ptrCast(@alignCast(c.g_object_new(t, "force-live", @as(c.gboolean, 1), NONE)));
    var fl: c.gboolean = 0;
    c.g_object_get(a, "force-live", &fl, NONE);
    out("  force-live {d}", .{fl});
    const p = c.gst_element_request_pad_simple(a, "sink_%u");
    const p2 = c.gst_element_request_pad_simple(a, "sink_%u");
    const pn = c.gst_object_get_name(@ptrCast(@alignCast(p2)));
    out("  second {s}", .{pn});
    c.g_free(pn);
    var zo: c.guint = 0;
    c.g_object_get(p2, "zorder", &zo, NONE);
    out("  z2 {d}", .{zo});
    c.g_object_set(p, "zorder", @as(c.guint, 9), NONE);
    const first = c.gst_object_get_name(@ptrCast(@alignCast(a.sinkpads[0].data)));
    out("  first after sort {s}", .{first});
    c.g_free(first);
    if (c.g_type_is_a(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class.*.g_type, c.gst_video_aggregator_convert_pad_get_type()) != 0) {
        const cfg = c.gst_structure_from_string("GstVideoConverterConfig, GstVideoConverter.dither-method=(int)0", null);
        c.g_object_set(p, "converter-config", cfg, NONE);
        var got: ?*c.GstStructure = null;
        c.g_object_get(p, "converter-config", &got, NONE);
        const s = c.gst_structure_to_string(got);
        out("  cfg {s}", .{s});
        c.g_free(s);
        c.gst_structure_free(got);
        c.gst_structure_free(cfg);
        c.gst_video_aggregator_convert_pad_update_conversion_info(@ptrCast(p));
    }
    out("  has {d} buf {d} frame {d}", .{ c.gst_video_aggregator_pad_has_current_buffer(@ptrCast(p)), @intFromBool(c.gst_video_aggregator_pad_get_current_buffer(@ptrCast(p)) != null), @intFromBool(c.gst_video_aggregator_pad_get_prepared_frame(@ptrCast(p)) != null) });
    c.gst_video_aggregator_pad_set_needs_alpha(@ptrCast(p), 1);
    c.gst_video_aggregator_pad_set_needs_alpha(@ptrCast(p), 0);
    out("  null checks", .{});
    out("    {d}", .{c.gst_video_aggregator_pad_has_current_buffer(null)});
    out("    {d}", .{@intFromBool(c.gst_video_aggregator_pad_get_current_buffer(null) != null)});
    out("    {d}", .{@intFromBool(c.gst_video_aggregator_pad_get_prepared_frame(null) != null)});
    c.gst_video_aggregator_pad_set_needs_alpha(null, 1);
    c.gst_video_aggregator_convert_pad_update_conversion_info(null);
    out("    {d}", .{@intFromBool(c.gst_video_aggregator_get_execution_task_pool(null) != null)});
    c.g_object_set(a, "latency", @as(c.guint64, 5), NONE);
    var bogus: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&bogus, c.G_TYPE_INT);
    const k = @as(*c.GObjectClass, @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class)));
    const ps = c.g_param_spec_int("bogus", "b", "b", 0, 10, 0, c.G_PARAM_READWRITE);
    k.get_property.?(@ptrCast(@alignCast(p)), 99, &bogus, ps);
    k.set_property.?(@ptrCast(@alignCast(p)), 99, &bogus, ps);
    const ak: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek(c.gst_video_aggregator_get_type())));
    ak.get_property.?(@ptrCast(@alignCast(a)), 99, &bogus, ps);
    ak.set_property.?(@ptrCast(@alignCast(a)), 99, &bogus, ps);
    c.g_param_spec_unref(ps);
    out("  types {s} {s} {s} abstract {d}", .{ c.g_type_name(c.gst_video_aggregator_pad_get_type()), c.g_type_name(c.gst_video_aggregator_convert_pad_get_type()), c.g_type_name(c.gst_video_aggregator_parallel_convert_pad_get_type()), @intFromBool(c.g_type_test_flags(c.gst_video_aggregator_get_type(), c.G_TYPE_FLAG_ABSTRACT) != 0) });
    out("  parents {s} {s} {s} {s}", .{ c.g_type_name(c.g_type_parent(c.gst_video_aggregator_get_type())), c.g_type_name(c.g_type_parent(c.gst_video_aggregator_pad_get_type())), c.g_type_name(c.g_type_parent(c.gst_video_aggregator_convert_pad_get_type())), c.g_type_name(c.g_type_parent(c.gst_video_aggregator_parallel_convert_pad_get_type())) });
    var np: c.guint = 0;
    const specs = c.g_object_class_list_properties(@as(*c.GObjectClass, @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class))), &np);
    for (0..np) |i| out("  pad prop {s} flags {d}", .{ c.g_param_spec_get_name(specs[i]), specs[i][0].flags });
    c.g_free(@ptrCast(specs));
    const aspecs = c.g_object_class_list_properties(@as(*c.GObjectClass, @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(a))).g_class))), &np);
    for (0..np) |i| out("  agg prop {s} flags {d}", .{ c.g_param_spec_get_name(aspecs[i]), aspecs[i][0].flags });
    c.g_free(@ptrCast(aspecs));
    c.gst_element_release_request_pad(a, p);
    c.gst_element_release_request_pad(a, p2);
    c.gst_object_unref(p);
    c.gst_object_unref(p2);
    c.gst_object_unref(a);
}

pub fn main() void {
    c.gst_init(null, null);
    c.g_mutex_init(&log_lock);
    const tc = makeType("TAggConv", c.gst_video_aggregator_convert_pad_get_type());
    const tp = makeType("TAggPar", c.gst_video_aggregator_parallel_convert_pad_get_type());
    const tplain = makeType("TAggPlain", c.gst_video_aggregator_pad_get_type());
    src_caps_str = "video/x-raw, format=(string)I420" ++ RANGES;
    const ti = makeType("TAggI420", c.gst_video_aggregator_convert_pad_get_type());
    propChecks(tc);
    propChecks(tplain);
    run("convert two inputs", tc, &.{
        .{ .format = "I420", .w = 4, .h = 4, .n = 4, .start = 0, .dur = 40 * MS, .fill = 10 },
        .{ .format = "AYUV", .w = 8, .h = 6, .n = 2, .start = 0, .dur = 40 * MS, .fill = 100 },
    }, .{ .queries = true });
    run("parallel convert", tp, &.{
        .{ .format = "BGRA", .w = 6, .h = 4, .n = 3, .start = 0, .dur = 40 * MS, .fill = 20 },
        .{ .format = "I420", .w = 8, .h = 8, .n = 3, .start = 20 * MS, .dur = 40 * MS, .fill = 50 },
    }, .{});
    run("plain pads repeat", tplain, &.{
        .{ .format = "I420", .w = 4, .h = 4, .n = 4, .start = 0, .dur = 40 * MS, .fill = 1 },
        .{ .format = "I420", .w = 4, .h = 4, .n = 1, .start = 0, .dur = 40 * MS, .fill = 200, .repeat = true, .zorder = 0 },
    }, .{});
    run("max repeat and gaps", tc, &.{
        .{ .format = "I420", .w = 4, .h = 2, .n = 6, .start = 0, .dur = 20 * MS, .fill = 3 },
        .{ .format = "I420", .w = 2, .h = 2, .n = 1, .start = 0, .dur = 10 * MS, .fill = 77, .max_repeat = 50 * MS },
    }, .{});
    run("needs alpha", tc, &.{
        .{ .format = "I420", .w = 4, .h = 4, .n = 2, .start = 0, .dur = 40 * MS, .fill = 5, .alpha = true },
    }, .{});
    run("downstream restricted", tc, &.{
        .{ .format = "AYUV", .w = 4, .h = 4, .n = 2, .start = 0, .dur = 40 * MS, .fill = 9 },
    }, .{ .sinkcaps = "video/x-raw, format=BGRA" });
    run("qos", tc, &.{
        .{ .format = "I420", .w = 4, .h = 4, .n = 8, .start = 0, .dur = 40 * MS, .fill = 30 },
    }, .{ .qos = true });
    run("only i420 src", ti, &.{
        .{ .format = "AYUV", .w = 4, .h = 4, .n = 2, .start = 0, .dur = 40 * MS, .fill = 60 },
        .{ .format = "BGRA", .w = 2, .h = 2, .n = 2, .start = 0, .dur = 40 * MS, .fill = 90 },
    }, .{});
}
