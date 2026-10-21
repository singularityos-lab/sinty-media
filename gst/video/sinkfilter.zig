const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const info = @import("info.zig");
const frame = @import("frame.zig");
const meta = @import("meta.zig");
const pool = @import("pool.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Rect = c.GstVideoRectangle;
const NONE = @as(?*anyopaque, null);

pub export fn gst_video_center_rect(src: [*c]const Rect, dst: [*c]const Rect, result: [*c]Rect, scaling: c.gboolean) void {
    const fname = "gst_video_center_rect";
    if (!check.that(src != null, fname, "src != NULL")) return;
    if (!check.that(dst != null, fname, "dst != NULL")) return;
    if (!check.that(result != null, fname, "result != NULL")) return;
    const s = src[0];
    const d = dst[0];
    const r = &result[0];
    if (scaling == 0) {
        r.w = @min(s.w, d.w);
        r.h = @min(s.h, d.h);
        r.x = d.x + @divTrunc(d.w - r.w, 2);
        r.y = d.y + @divTrunc(d.h - r.h, 2);
        return;
    }
    if (!check.that(s.h != 0, fname, "src->h != 0")) return;
    if (!check.that(d.h != 0, fname, "dst->h != 0")) return;
    const sr = @as(f64, @floatFromInt(s.w)) / @as(f64, @floatFromInt(s.h));
    const dr = @as(f64, @floatFromInt(d.w)) / @as(f64, @floatFromInt(d.h));
    if (sr > dr) {
        r.w = d.w;
        r.h = toInt(@as(f64, @floatFromInt(d.w)) / sr);
        r.x = d.x;
        r.y = d.y + @divTrunc(d.h - r.h, 2);
    } else if (sr < dr) {
        r.w = toInt(@as(f64, @floatFromInt(d.h)) * sr);
        r.h = d.h;
        r.x = d.x + @divTrunc(d.w - r.w, 2);
        r.y = d.y;
    } else {
        r.* = d;
    }
}

fn toInt(x: f64) c.gint {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(c.gint);
    return @intFromFloat(x);
}

pub export fn gst_video_sink_center_rect(src: Rect, dst: Rect, result: [*c]Rect, scaling: c.gboolean) void {
    gst_video_center_rect(&src, &dst, result, scaling);
}

const Sink = c.GstVideoSink;
const SinkClass = c.GstVideoSinkClass;
const BSink = c.GstBaseSink;
const BSinkClass = c.GstBaseSinkClass;

const SinkPrivate = extern struct {
    info: c.GstVideoInfo,
    show_preroll_frame: c.gint,
};

var sink_once: gtype.Once = .{};
var sink_offset: c.gint = 0;
var sink_parent: ?*BSinkClass = null;

fn sinkOf(p: anytype) *Sink {
    return @ptrCast(@alignCast(p));
}

fn sinkPriv(p: anytype) *SinkPrivate {
    return @ptrCast(@alignCast(sinkOf(p).priv));
}

fn sinkClass(p: anytype) *SinkClass {
    return gtype.classPeek(SinkClass, p);
}

fn sinkChangeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) info.gst_video_info_init(&sinkPriv(e).info);
    return @as(*c.GstElementClass, @ptrCast(sink_parent)).change_state.?(e, t);
}

fn sinkSetCaps(b: [*c]BSink, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    var vi: c.GstVideoInfo = undefined;
    if (info.gst_video_info_from_caps(&vi, caps) == 0) return 0;
    const p = sinkPriv(b);
    p.info = vi;
    if (sinkClass(b).set_info) |f| return f(sinkOf(b), caps, &p.info);
    return 1;
}

fn valid(t: c.GstClockTime) bool {
    return t != c.GST_CLOCK_TIME_NONE;
}

fn sinkGetTimes(b: [*c]BSink, buffer: [*c]c.GstBuffer, start: [*c]c.GstClockTime, end: [*c]c.GstClockTime) callconv(.c) void {
    const p = sinkPriv(b);
    const ts = if (valid(buffer[0].dts)) buffer[0].dts else buffer[0].pts;
    if (!valid(ts)) return;
    start[0] = ts;
    if (valid(buffer[0].duration)) {
        end[0] = ts + buffer[0].duration;
    } else if (p.info.fps_n > 0) {
        end[0] = ts + c.gst_util_uint64_scale_int(c.GST_SECOND, p.info.fps_d, p.info.fps_n);
    } else if (b[0].segment.rate < 0) {
        end[0] = ts;
    }
}

fn sinkPreroll(b: [*c]BSink, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const k = sinkClass(b);
    const show = @atomicLoad(c.gint, &sinkPriv(b).show_preroll_frame, .seq_cst) != 0;
    if (k.show_frame == null or !show) {
        if (sink_parent.?.preroll) |f| return f(b, buf);
        return c.GST_FLOW_OK;
    }
    return k.show_frame.?(sinkOf(b), buf);
}

fn sinkRender(b: [*c]BSink, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const k = sinkClass(b);
    if (k.show_frame) |f| return f(sinkOf(b), buf);
    if (sink_parent.?.render) |f| return f(b, buf);
    return c.GST_FLOW_OK;
}

fn sinkSetProperty(obj: [*c]c.GObject, id: c.guint, value: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return;
    @atomicStore(c.gint, &sinkPriv(obj).show_preroll_frame, c.g_value_get_boolean(value), .seq_cst);
}

fn sinkGetProperty(obj: [*c]c.GObject, id: c.guint, value: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return;
    c.g_value_set_boolean(value, @atomicLoad(c.gint, &sinkPriv(obj).show_preroll_frame, .seq_cst));
}

fn sinkClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    sink_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (sink_offset != 0) c.g_type_class_adjust_private_offset(k, &sink_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const bc: *BSinkClass = @ptrCast(@alignCast(k));
    oc.set_property = sinkSetProperty;
    oc.get_property = sinkGetProperty;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_boolean("show-preroll-frame", "Show preroll frame", "Whether to render video frames during preroll", 1, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS));
    ec.change_state = sinkChangeState;
    bc.render = sinkRender;
    bc.preroll = sinkPreroll;
    bc.set_caps = sinkSetCaps;
    bc.get_times = sinkGetTimes;
}

fn sinkInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = sinkOf(inst);
    s.width = 0;
    s.height = 0;
    const b: [*c]BSink = @ptrCast(@alignCast(inst));
    c.gst_base_sink_set_processing_deadline(b, 15 * c.GST_MSECOND);
    c.gst_base_sink_set_max_lateness(b, 5 * c.GST_MSECOND);
    c.gst_base_sink_set_qos_enabled(b, 1);
    s.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, sink_offset))));
}

pub export fn gst_video_sink_get_type() c.GType {
    return sink_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_base_sink_get_type, "GstVideoSink", SinkClass, Sink, sinkClassInit, sinkInit, 0);
            sink_offset = c.g_type_add_instance_private(t, @sizeOf(SinkPrivate));
            return t;
        }
    }.f);
}

const Filter = c.GstVideoFilter;
const FilterClass = c.GstVideoFilterClass;
const BT = c.GstBaseTransform;
const BTClass = c.GstBaseTransformClass;
const FILE = "../gst-libs/gst/video/gstvideofilter.c";

var filter_once: gtype.Once = .{};
var filter_parent: ?*BTClass = null;
var video_tag: c.GQuark = 0;

fn filterOf(p: anytype) *Filter {
    return @ptrCast(@alignCast(p));
}

fn filterClass(p: anytype) *FilterClass {
    return gtype.classPeek(FilterClass, p);
}

fn objName(p: anytype) [*c]const u8 {
    return @as(*c.GstObject, @ptrCast(@alignCast(p))).name;
}

fn proposeAllocation(t: [*c]BT, decide: [*c]c.GstQuery, query: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (filter_parent.?.propose_allocation.?(t, decide, query) == 0) return 0;
    if (decide == null) return 1;
    var caps: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(query, &caps, null);
    if (caps == null) return 0;
    var vi: c.GstVideoInfo = undefined;
    if (info.gst_video_info_from_caps(&vi, caps) == 0) return 0;
    const size: c.guint = @intCast(vi.size);
    if (c.gst_query_get_n_allocation_pools(query) != 0) return 1;
    var allocator: [*c]c.GstAllocator = null;
    var params = c.GstAllocationParams{ .flags = 0, .@"align" = 15, .prefix = 0, .padding = 0 };
    if (c.gst_query_get_n_allocation_params(query) > 0) {
        c.gst_query_parse_nth_allocation_param(query, 0, &allocator, &params);
    } else c.gst_query_add_allocation_param(query, allocator, &params);
    const p = pool.gst_video_buffer_pool_new();
    const name = c.g_strdup_printf("%s-propose-pool", objName(t));
    c.g_object_set(p, "name", name, NONE);
    c.g_free(name);
    const st = c.gst_buffer_pool_get_config(p);
    c.gst_buffer_pool_config_set_params(st, caps, size, 0, 0);
    c.gst_buffer_pool_config_set_allocator(st, allocator, &params);
    if (allocator != null) c.gst_object_unref(allocator);
    if (c.gst_buffer_pool_set_config(p, st) == 0) {
        c.gst_object_unref(p);
        return 0;
    }
    c.gst_query_add_allocation_pool(query, p, size, 0, 0);
    c.gst_object_unref(p);
    c.gst_query_add_allocation_meta(query, meta.gst_video_meta_api_get_type(), null);
    return 1;
}

fn decideAllocation(t: [*c]BT, query: [*c]c.GstQuery) callconv(.c) c.gboolean {
    var p: [*c]c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    var outcaps: [*c]c.GstCaps = null;
    var update = false;
    if (c.gst_query_get_n_allocation_pools(query) > 0) {
        c.gst_query_parse_nth_allocation_pool(query, 0, &p, &size, &min, &max);
        if (p == null) c.gst_query_parse_allocation(query, &outcaps, null);
        update = true;
    } else {
        var vi: c.GstVideoInfo = undefined;
        c.gst_query_parse_allocation(query, &outcaps, null);
        info.gst_video_info_init(&vi);
        _ = info.gst_video_info_from_caps(&vi, outcaps);
        size = @truncate(vi.size);
    }
    if (p == null) {
        p = pool.gst_video_buffer_pool_new();
        const name = c.g_strdup_printf("%s-decide-pool", objName(t));
        c.g_object_set(p, "name", name, NONE);
        c.g_free(name);
    }
    const config = c.gst_buffer_pool_get_config(p);
    c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_META);
    if (c.gst_query_find_allocation_meta(query, meta.gst_video_meta_api_get_type(), null) != 0 and c.gst_buffer_pool_has_option(p, c.GST_BUFFER_POOL_OPTION_VIDEO_META) != 0 and c.gst_buffer_pool_has_option(p, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT) != 0) {
        c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT);
    }
    if (outcaps != null) c.gst_buffer_pool_config_set_params(config, outcaps, size, 0, 0);
    _ = c.gst_buffer_pool_set_config(p, config);
    if (update) c.gst_query_set_nth_allocation_pool(query, 0, p, size, min, max) else c.gst_query_add_allocation_pool(query, p, size, min, max);
    c.gst_object_unref(p);
    return filter_parent.?.decide_allocation.?(t, query);
}

fn transformSize(_: [*c]BT, _: c.GstPadDirection, _: [*c]c.GstCaps, _: c.gsize, othercaps: [*c]c.GstCaps, othersize: [*c]c.gsize) callconv(.c) c.gboolean {
    var vi: c.GstVideoInfo = undefined;
    const ok = info.gst_video_info_from_caps(&vi, othercaps);
    if (ok != 0) othersize[0] = vi.size;
    return ok;
}

fn unitSize(_: [*c]BT, caps: [*c]c.GstCaps, size: [*c]c.gsize) callconv(.c) c.gboolean {
    var vi: c.GstVideoInfo = undefined;
    if (info.gst_video_info_from_caps(&vi, caps) == 0) return 0;
    size[0] = vi.size;
    return 1;
}

fn filterSetCaps(t: [*c]BT, incaps: [*c]c.GstCaps, outcaps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const f = filterOf(t);
    var in: c.GstVideoInfo = undefined;
    var out: c.GstVideoInfo = undefined;
    if (info.gst_video_info_from_caps(&in, incaps) == 0 or info.gst_video_info_from_caps(&out, outcaps) == 0) {
        f.negotiated = 0;
        return 0;
    }
    const k = filterClass(f);
    const res: c.gboolean = if (k.set_info) |cb| cb(f, incaps, &in, outcaps, &out) else 1;
    if (res != 0) {
        f.in_info = in;
        f.out_info = out;
        if (k.transform_frame == null) c.gst_base_transform_set_in_place(t, 1);
        if (k.transform_frame_ip == null) @as(*BTClass, @ptrCast(k)).transform_ip_on_passthrough = 0;
    }
    f.negotiated = res;
    return res;
}

fn notNegotiated(f: *Filter, comptime func: [*:0]const u8, line: c.gint) c.GstFlowReturn {
    c.gst_element_message_full(@ptrCast(f), c.GST_MESSAGE_ERROR, c.gst_core_error_quark(), c.GST_CORE_ERROR_NOT_IMPLEMENTED, null, c.g_strdup("unknown format"), FILE, func, line);
    return c.GST_FLOW_NOT_NEGOTIATED;
}

fn badBuffer(f: *Filter, comptime func: [*:0]const u8, line: c.gint) c.GstFlowReturn {
    c.gst_element_message_full(@ptrCast(f), c.GST_MESSAGE_WARNING, c.gst_core_error_quark(), c.GST_CORE_ERROR_NOT_IMPLEMENTED, null, c.g_strdup("invalid video buffer received"), FILE, func, line);
    return c.GST_FLOW_OK;
}

const NO_REF = c.GST_VIDEO_FRAME_MAP_FLAG_NO_REF;

fn transform(t: [*c]BT, inbuf: [*c]c.GstBuffer, outbuf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const fname = "gst_video_filter_transform";
    const f = filterOf(t);
    if (f.negotiated == 0) return notNegotiated(f, fname, 309);
    const k = filterClass(f);
    const cb = k.transform_frame orelse return c.GST_FLOW_OK;
    var in: c.GstVideoFrame = undefined;
    var out: c.GstVideoFrame = undefined;
    if (frame.gst_video_frame_map(&in, &f.in_info, inbuf, c.GST_MAP_READ | NO_REF) == 0) return badBuffer(f, fname, 315);
    if (frame.gst_video_frame_map(&out, &f.out_info, outbuf, c.GST_MAP_WRITE | NO_REF) == 0) {
        frame.gst_video_frame_unmap(&in);
        return badBuffer(f, fname, 315);
    }
    const res = cb(f, &in, &out);
    frame.gst_video_frame_unmap(&out);
    frame.gst_video_frame_unmap(&in);
    return res;
}

fn transformIp(t: [*c]BT, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const fname = "gst_video_filter_transform_ip";
    const f = filterOf(t);
    if (f.negotiated == 0) return notNegotiated(f, fname, 357);
    const k = filterClass(f);
    const cb = k.transform_frame_ip orelse return c.GST_FLOW_OK;
    var flags: c.GstMapFlags = c.GST_MAP_READ | NO_REF;
    if (c.gst_base_transform_is_passthrough(t) == 0) flags |= c.GST_MAP_WRITE;
    var fr: c.GstVideoFrame = undefined;
    if (frame.gst_video_frame_map(&fr, &f.in_info, buf, flags) == 0) return badBuffer(f, fname, 363);
    const res = cb(f, &fr);
    frame.gst_video_frame_unmap(&fr);
    return res;
}

fn transformMeta(t: [*c]BT, outbuf: [*c]c.GstBuffer, m: [*c]c.GstMeta, inbuf: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const api = m[0].info[0].api;
    const tags = c.gst_meta_api_type_get_tags(api);
    if (tags == null or (c.g_strv_length(@constCast(@ptrCast(tags))) == 1 and c.gst_meta_api_type_has_tag(api, video_tag) != 0)) return 1;
    return filter_parent.?.transform_meta.?(t, outbuf, m, inbuf);
}

fn filterClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    filter_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const bc: *BTClass = @ptrCast(@alignCast(k));
    bc.set_caps = filterSetCaps;
    bc.propose_allocation = proposeAllocation;
    bc.decide_allocation = decideAllocation;
    bc.transform_size = transformSize;
    bc.get_unit_size = unitSize;
    bc.transform = transform;
    bc.transform_ip = transformIp;
    bc.transform_meta = transformMeta;
    _ = c._gst_debug_category_new("videofilter", 0, "videofilter");
    video_tag = c.g_quark_from_static_string("video");
}

fn filterInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    filterOf(inst).negotiated = 0;
    c.gst_base_transform_set_qos_enabled(@ptrCast(@alignCast(inst)), 1);
}

pub export fn gst_video_filter_get_type() c.GType {
    return filter_once.get(struct {
        fn f() c.GType {
            return gtype.object(c.gst_base_transform_get_type, "GstVideoFilter", FilterClass, Filter, filterClassInit, filterInit, c.G_TYPE_FLAG_ABSTRACT);
        }
    }.f);
}
