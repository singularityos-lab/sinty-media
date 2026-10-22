const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const enums = @import("enums.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Scope = c.GstAudioVisualizer;
const ScopeClass = c.GstAudioVisualizerClass;
const Frame = c.GstVideoFrame;
const Buffer = c.GstBuffer;
const Caps = c.GstCaps;
const PATH = "../gst-libs/gst/pbutils/gstaudiovisualizer.c";
const NONE = el.NONE;
const VNONE = @as(?*anyopaque, null);
const ShaderFn = *const fn (*Scope, *const Frame, *Frame) void;

const Priv = struct {
    negotiated: bool,
    pool: ?*c.GstBufferPool,
    pool_active: bool,
    allocator: ?*c.GstAllocator,
    params: c.GstAllocationParams,
    query: [*c]c.GstQuery,
    srcpad: ?*c.GstPad,
    sinkpad: ?*c.GstPad,
    shader_type: c.GstAudioVisualizerShader,
    shader: ?ShaderFn,
    shade_amount: u32,
    adapter: ?*c.GstAdapter,
    inbuf: [*c]Buffer,
    tempbuf: [*c]Buffer,
    tempframe: Frame,
    spf: c.guint,
    frame_duration: u64,
    proportion: f64,
    earliest_time: u64,
    dropped: c.guint,
    processed: c.guint,
    config_lock: c.GMutex,
    segment: c.GstSegment,
};

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GstElementClass = null;

fn pv(s: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Scope, @ptrCast(@alignCast(s))).priv));
}

fn scopeOf(p: anytype) *Scope {
    return @ptrCast(@alignCast(p));
}

const Shade = struct { r: u8, g: u8, b: u8 };

fn amounts(s: *Scope) Shade {
    const a = pv(s).shade_amount;
    return .{ .r = @truncate(a >> 16), .g = @truncate(a >> 8), .b = @truncate(a) };
}

fn sub(v: u8, x: u8) u8 {
    return if (v > x) v - x else 0;
}

fn shade(d: [*]u8, s: [*]const u8, i: usize, k: Shade) void {
    d[i * 4 + 0] = sub(s[i * 4 + 0], k.b);
    d[i * 4 + 1] = sub(s[i * 4 + 1], k.g);
    d[i * 4 + 2] = sub(s[i * 4 + 2], k.r);
    d[i * 4 + 3] = 0;
}

const Geo = struct {
    s: [*]const u8,
    d: [*]u8,
    ss: isize,
    ds: isize,
    w: usize,
    h: usize,
};

fn geo(sf: *const Frame, df: *Frame) Geo {
    return .{
        .s = @ptrCast(sf.data[0]),
        .d = @ptrCast(df.data[0]),
        .ss = sf.info.stride[0],
        .ds = df.info.stride[0],
        .w = @intCast(sf.info.width),
        .h = @intCast(sf.info.height),
    };
}

fn adv(p: anytype, n: isize) @TypeOf(p) {
    return if (n >= 0) p + @as(usize, @intCast(n)) else p - @as(usize, @intCast(-n));
}

fn row(d: [*]u8, s: [*]const u8, from: usize, to: usize, k: Shade) void {
    var i = from;
    while (i < to) : (i += 1) shade(d, s, i, k);
}

fn fade(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    for (0..g.h) |_| {
        row(g.d, g.s, 0, g.w, k);
        g.s = adv(g.s, g.ss);
        g.d = adv(g.d, g.ds);
    }
}

fn moveUp(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    var j: usize = 1;
    while (j < g.h) : (j += 1) {
        g.s = adv(g.s, g.ss);
        row(g.d, g.s, 0, g.w, k);
        g.d = adv(g.d, g.ds);
    }
}

fn moveDown(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    var j: usize = 1;
    while (j < g.h) : (j += 1) {
        g.d = adv(g.d, g.ds);
        row(g.d, g.s, 0, g.w, k);
        g.s = adv(g.s, g.ss);
    }
}

fn moveLeft(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    g.s += 4;
    for (0..g.h) |_| {
        row(g.d, g.s, 0, g.w -% 1, k);
        g.d = adv(g.d, g.ds);
        g.s = adv(g.s, g.ss);
    }
}

fn moveRight(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    g.d += 4;
    for (0..g.h) |_| {
        row(g.d, g.s, 0, g.w -% 1, k);
        g.d = adv(g.d, g.ds);
        g.s = adv(g.s, g.ss);
    }
}

fn horizOut(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    for (0..g.h / 2) |_| {
        g.s = adv(g.s, g.ss);
        row(g.d, g.s, 0, g.w, k);
        g.d = adv(g.d, g.ds);
    }
    g.d = adv(g.d, -g.ds);
    for (0..g.h / 2) |_| {
        g.d = adv(g.d, g.ds);
        row(g.d, g.s, 0, g.w, k);
        g.s = adv(g.s, g.ss);
    }
}

fn horizIn(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    for (0..g.h / 2) |_| {
        g.d = adv(g.d, g.ds);
        row(g.d, g.s, 0, g.w, k);
        g.s = adv(g.s, g.ss);
    }
    for (0..g.h / 2) |_| {
        g.s = adv(g.s, g.ss);
        row(g.d, g.s, 0, g.w, k);
        g.d = adv(g.d, g.ds);
    }
}

fn vertOut(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    for (0..g.h) |_| {
        row(g.d, g.s + 1, 0, g.w / 2, k);
        row(g.d + 1, g.s, g.w / 2, g.w -% 1, k);
        g.s = adv(g.s, g.ss);
        g.d = adv(g.d, g.ds);
    }
}

fn vertIn(sc: *Scope, sf: *const Frame, df: *Frame) void {
    const k = amounts(sc);
    var g = geo(sf, df);
    for (0..g.h) |_| {
        row(g.d + 1, g.s, 0, g.w / 2, k);
        row(g.d, g.s + 1, g.w / 2, g.w -% 1, k);
        g.s = adv(g.s, g.ss);
        g.d = adv(g.d, g.ds);
    }
}

fn changeShader(s: *Scope) void {
    const p = pv(s);
    p.shader = switch (p.shader_type) {
        c.GST_AUDIO_VISUALIZER_SHADER_FADE => fade,
        c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_UP => moveUp,
        c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_DOWN => moveDown,
        c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_LEFT => moveLeft,
        c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_RIGHT => moveRight,
        c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_HORIZ_OUT => horizOut,
        c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_HORIZ_IN => horizIn,
        c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_VERT_OUT => vertOut,
        c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_VERT_IN => vertIn,
        else => null,
    };
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const s = scopeOf(o);
    switch (id) {
        1 => {
            pv(s).shader_type = @bitCast(c.g_value_get_enum(v));
            changeShader(s);
        },
        2 => pv(s).shade_amount = c.g_value_get_uint(v),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 639),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = pv(o);
    switch (id) {
        1 => c.g_value_set_enum(v, @bitCast(p.shader_type)),
        2 => c.g_value_set_uint(v, p.shade_amount),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 658),
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p = pv(o);
    if (p.adapter) |a| {
        c.g_object_unref(a);
        p.adapter = null;
    }
    if (p.inbuf != null) {
        c.gst_mini_object_unref(@ptrCast(p.inbuf));
        p.inbuf = null;
    }
    if (p.tempbuf != null) {
        c.gst_video_frame_unmap(&p.tempframe);
        c.gst_mini_object_unref(@ptrCast(p.tempbuf));
        p.tempbuf = null;
    }
    if (p.config_lock.p != null) {
        c.g_mutex_clear(&p.config_lock);
        p.config_lock.p = null;
    }
    @as(*c.GObjectClass, @ptrCast(parent)).dispose.?(o);
}

fn reset(s: *Scope) void {
    const p = pv(s);
    c.gst_adapter_clear(p.adapter);
    c.gst_segment_init(&p.segment, c.GST_FORMAT_UNDEFINED);
    el.lock(s);
    p.proportion = 1.0;
    p.earliest_time = NONE;
    p.dropped = 0;
    p.processed = 0;
    el.unlock(s);
}

fn setAllocation(s: *Scope, pool: ?*c.GstBufferPool, allocator: ?*c.GstAllocator, params: ?*const c.GstAllocationParams, query: [*c]c.GstQuery) bool {
    const p = pv(s);
    el.lock(s);
    const oldpool = p.pool;
    p.pool = pool;
    p.pool_active = false;
    const oldalloc = p.allocator;
    p.allocator = allocator;
    const oldquery = p.query;
    p.query = query;
    if (params) |x| p.params = x.* else c.gst_allocation_params_init(&p.params);
    el.unlock(s);
    if (oldpool) |op| {
        _ = c.gst_buffer_pool_set_active(op, 0);
        c.gst_object_unref(op);
    }
    if (oldalloc) |oa| c.gst_object_unref(oa);
    if (oldquery != null) c.gst_mini_object_unref(@ptrCast(oldquery));
    return true;
}

fn decideDefault(s: [*c]Scope, query: [*c]c.GstQuery) callconv(.c) c.gboolean {
    var outcaps: [*c]Caps = null;
    c.gst_query_parse_allocation(query, &outcaps, null);
    var allocator: ?*c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    var update_alloc = false;
    if (c.gst_query_get_n_allocation_params(query) > 0) {
        c.gst_query_parse_nth_allocation_param(query, 0, @ptrCast(&allocator), &params);
        update_alloc = true;
    } else c.gst_allocation_params_init(&params);
    var pool: ?*c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    var update_pool = false;
    if (c.gst_query_get_n_allocation_pools(query) > 0) {
        c.gst_query_parse_nth_allocation_pool(query, 0, @ptrCast(&pool), &size, &min, &max);
        update_pool = true;
    } else size = @truncate(s[0].vinfo.size);
    if (pool == null) {
        pool = c.gst_video_buffer_pool_new();
        const name = c.g_strdup_printf("%s-pool", @as(*c.GstObject, @ptrCast(@alignCast(s))).name);
        c.g_object_set(pool, "name", name, VNONE);
        c.g_free(name);
    }
    const config = c.gst_buffer_pool_get_config(pool);
    c.gst_buffer_pool_config_set_params(config, outcaps, size, min, max);
    c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
    c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_META);
    _ = c.gst_buffer_pool_set_config(pool, config);
    if (update_alloc) c.gst_query_set_nth_allocation_param(query, 0, allocator, &params) else c.gst_query_add_allocation_param(query, allocator, &params);
    if (allocator) |a| c.gst_object_unref(a);
    if (update_pool) c.gst_query_set_nth_allocation_pool(query, 0, pool, size, min, max) else c.gst_query_add_allocation_pool(query, pool, size, min, max);
    if (pool) |x| c.gst_object_unref(x);
    return 1;
}

fn doBufferpool(s: *Scope, outcaps: [*c]Caps) bool {
    const query = c.gst_query_new_allocation(outcaps, 1);
    _ = c.gst_pad_peer_query(pv(s).srcpad, query);
    const k = gtype.classPeek(ScopeClass, s);
    if (k.decide_allocation == null) c.g_assertion_message_expr(check.DOMAIN, PATH, 913, "gst_audio_visualizer_do_bufferpool", "klass->decide_allocation != NULL");
    if (k.decide_allocation.?(s, query) == 0) {
        c.gst_mini_object_unref(@ptrCast(query));
        return false;
    }
    var allocator: ?*c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_query_get_n_allocation_params(query) > 0) c.gst_query_parse_nth_allocation_param(query, 0, @ptrCast(&allocator), &params) else c.gst_allocation_params_init(&params);
    var pool: ?*c.GstBufferPool = null;
    if (c.gst_query_get_n_allocation_pools(query) > 0) c.gst_query_parse_nth_allocation_pool(query, 0, @ptrCast(&pool), null, null, null);
    return setAllocation(s, pool, allocator, &params, query);
}

fn srcSetcaps(s: *Scope, caps: [*c]Caps) bool {
    const p = pv(s);
    var vi: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&vi, caps) == 0) {
        c.gst_mini_object_unref(@ptrCast(caps));
        return false;
    }
    const k = gtype.classPeek(ScopeClass, s);
    s.vinfo = vi;
    p.frame_duration = c.gst_util_uint64_scale_int(c.GST_SECOND, vi.fps_d, vi.fps_n);
    p.spf = @truncate(c.gst_util_uint64_scale_int(@intCast(s.ainfo.rate), vi.fps_d, vi.fps_n));
    s.req_spf = p.spf;
    if (p.tempbuf != null) {
        c.gst_video_frame_unmap(&p.tempframe);
        c.gst_mini_object_unref(@ptrCast(p.tempbuf));
    }
    p.tempbuf = c.gst_buffer_new_wrapped(c.g_malloc0(s.vinfo.size), s.vinfo.size);
    _ = c.gst_video_frame_map(&p.tempframe, &s.vinfo, p.tempbuf, c.GST_MAP_READWRITE);
    if (k.setup != null and k.setup.?(s) == 0) return false;
    _ = c.gst_pad_push_event(p.srcpad, c.gst_event_new_caps(caps));
    const res = doBufferpool(s, caps);
    c.gst_mini_object_unref(@ptrCast(caps));
    return res;
}

fn srcNegotiate(s: *Scope) bool {
    const p = pv(s);
    const templ = c.gst_pad_get_pad_template_caps(p.srcpad);
    const other = c.gst_pad_peer_query_caps(p.srcpad, null);
    var target: [*c]Caps = undefined;
    if (other != null) {
        target = c.gst_caps_intersect(other, templ);
        c.gst_mini_object_unref(@ptrCast(other));
        c.gst_mini_object_unref(@ptrCast(templ));
        if (c.gst_caps_is_empty(target) != 0) {
            c.gst_mini_object_unref(@ptrCast(target));
            return false;
        }
        target = c.gst_caps_truncate(target);
    } else target = templ;
    target = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(target)));
    const st = c.gst_caps_get_structure(target, 0);
    _ = c.gst_structure_fixate_field_nearest_int(st, "width", 320);
    _ = c.gst_structure_fixate_field_nearest_int(st, "height", 200);
    _ = c.gst_structure_fixate_field_nearest_fraction(st, "framerate", 25, 1);
    if (c.gst_structure_has_field(st, "pixel-aspect-ratio") != 0) _ = c.gst_structure_fixate_field_nearest_fraction(st, "pixel-aspect-ratio", 1, 1);
    target = c.gst_caps_fixate(target);
    return srcSetcaps(s, target);
}

fn sinkSetcaps(s: *Scope, caps: [*c]Caps) bool {
    var ai: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&ai, caps) == 0) return false;
    s.ainfo = ai;
    return srcNegotiate(s);
}

fn prepareOutput(s: *Scope, out: *[*c]Buffer) c.GstFlowReturn {
    const p = pv(s);
    if (p.pool == null) c.g_assertion_message_expr(check.DOMAIN, PATH, 1029, "default_prepare_output_buffer", "priv->pool != NULL");
    if (!p.pool_active) {
        if (c.gst_buffer_pool_set_active(p.pool, 1) == 0) {
            el.messageAt(s, c.GST_MESSAGE_ERROR, .resource, c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup("failed to activate bufferpool"), c.g_strdup("failed to activate bufferpool"), PATH, "default_prepare_output_buffer", 1045, null);
            return c.GST_FLOW_ERROR;
        }
        p.pool_active = true;
    }
    return c.gst_buffer_pool_acquire_buffer(p.pool, out, null);
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, buffer: [*c]Buffer) callconv(.c) c.GstFlowReturn {
    const s = scopeOf(par);
    const p = pv(s);
    const k = gtype.classPeek(ScopeClass, s);
    if (buffer[0].mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) c.gst_adapter_clear(p.adapter);
    if (c.gst_pad_check_reconfigure(p.srcpad) != 0 and !srcNegotiate(s)) {
        c.gst_pad_mark_reconfigure(p.srcpad);
        c.gst_mini_object_unref(@ptrCast(buffer));
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    const rate = s.ainfo.rate;
    const bpf = s.ainfo.bpf;
    if (bpf == 0) {
        c.gst_mini_object_unref(@ptrCast(buffer));
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    c.g_mutex_lock(&p.config_lock);
    const inbuf = p.inbuf;
    _ = c.gst_buffer_copy_into(inbuf, buffer, c.GST_BUFFER_COPY_METADATA, 0, std.math.maxInt(usize));
    c.gst_adapter_push(p.adapter, buffer);
    var sbpf: c.guint = s.req_spf *% @as(c.guint, @bitCast(bpf));
    var avail: c.guint = @truncate(c.gst_adapter_available(p.adapter));
    while (avail >= sbpf) {
        var dist: u64 = 0;
        var ts = c.gst_adapter_prev_pts(p.adapter, &dist);
        if (ts != NONE) ts +%= c.gst_util_uint64_scale_int(dist, c.GST_SECOND, rate * bpf);
        var skipped = false;
        if (ts != NONE) {
            const qostime = c.gst_segment_to_running_time(&p.segment, c.GST_FORMAT_TIME, ts) +% p.frame_duration;
            el.lock(s);
            const earliest = p.earliest_time;
            const proportion = p.proportion;
            el.unlock(s);
            if (earliest != NONE and qostime <= earliest) {
                p.dropped += 1;
                const st = c.gst_segment_to_stream_time(&p.segment, c.GST_FORMAT_TIME, ts);
                const jitter: i64 = @as(i64, @bitCast(earliest)) -% @as(i64, @bitCast(qostime));
                const msg = c.gst_message_new_qos(@ptrCast(s), 0, qostime, st, ts, buffer[0].duration);
                c.gst_message_set_qos_values(msg, jitter, proportion, 1000000);
                c.gst_message_set_qos_stats(msg, c.GST_FORMAT_BUFFERS, p.processed, p.dropped);
                _ = c.gst_element_post_message(@ptrCast(s), msg);
                skipped = true;
            }
        }
        if (!skipped) {
            p.processed += 1;
            c.g_mutex_unlock(&p.config_lock);
            var outbuf: [*c]Buffer = null;
            ret = prepareOutput(s, &outbuf);
            c.g_mutex_lock(&p.config_lock);
            sbpf = s.req_spf *% @as(c.guint, @bitCast(bpf));
            if (ret != c.GST_FLOW_OK) break;
            if (ts != NONE) _ = c.gst_object_sync_values(@ptrCast(s), ts);
            outbuf[0].pts = ts;
            outbuf[0].duration = p.frame_duration;
            const databuf = c.gst_adapter_get_buffer(p.adapter, sbpf);
            if (databuf == null) break;
            var outframe: Frame = undefined;
            _ = c.gst_video_frame_map(&outframe, &s.vinfo, outbuf, c.GST_MAP_READWRITE | c.GST_VIDEO_FRAME_MAP_FLAG_NO_REF);
            if (p.shader != null) {
                _ = c.gst_video_frame_copy(&outframe, &p.tempframe);
            } else {
                for (0..s.vinfo.finfo[0].n_planes) |i| @memset(@as([*]u8, @ptrCast(outframe.data[i]))[0..outframe.map[i].size], 0);
            }
            c.gst_buffer_remove_all_memory(inbuf);
            _ = c.gst_buffer_copy_into(inbuf, databuf, c.GST_BUFFER_COPY_MEMORY, 0, sbpf);
            c.gst_mini_object_unref(@ptrCast(databuf));
            if (k.render) |render| {
                if (render(s, inbuf, &outframe) == 0) {
                    ret = c.GST_FLOW_ERROR;
                    c.gst_video_frame_unmap(&outframe);
                    break;
                }
                if (p.shader != null and s.vinfo.finfo[0].pixel_stride[0] == 4) p.shader.?(s, &outframe, &p.tempframe);
            }
            c.gst_video_frame_unmap(&outframe);
            c.g_mutex_unlock(&p.config_lock);
            ret = c.gst_pad_push(p.srcpad, outbuf);
            c.g_mutex_lock(&p.config_lock);
        }
        sbpf = s.req_spf *% @as(c.guint, @bitCast(bpf));
        if (avail -% sbpf >= sbpf) {
            c.gst_adapter_flush(p.adapter, sbpf);
        } else if (avail >= sbpf) {
            c.gst_adapter_flush(p.adapter, avail - sbpf);
            break;
        }
        avail = @truncate(c.gst_adapter_available(p.adapter));
        if (ret != c.GST_FLOW_OK) break;
    }
    c.g_mutex_unlock(&p.config_lock);
    return ret;
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = scopeOf(par);
    const p = pv(s);
    switch (ev[0].type) {
        c.GST_EVENT_QOS => {
            var prop: f64 = 0;
            var diff: i64 = 0;
            var ts: u64 = 0;
            c.gst_event_parse_qos(ev, null, &prop, &diff, &ts);
            el.lock(s);
            p.proportion = prop;
            if (diff >= 0) {
                p.earliest_time = ts +% @as(u64, @bitCast(@min(2 * diff, @as(i64, c.GST_SECOND)))) +% p.frame_duration;
            } else p.earliest_time = ts +% @as(u64, @bitCast(diff));
            el.unlock(s);
            return c.gst_pad_push_event(p.sinkpad, ev);
        },
        c.GST_EVENT_RECONFIGURE => {
            c.gst_mini_object_unref(@ptrCast(ev));
            return 1;
        },
        else => return c.gst_pad_event_default(pad, par, ev),
    }
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = scopeOf(par);
    const p = pv(s);
    switch (ev[0].type) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]Caps = null;
            c.gst_event_parse_caps(ev, &caps);
            const r = sinkSetcaps(s, caps);
            c.gst_mini_object_unref(@ptrCast(ev));
            return @intFromBool(r);
        },
        c.GST_EVENT_FLUSH_STOP => {
            reset(s);
            return c.gst_pad_push_event(p.srcpad, ev);
        },
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(ev, &p.segment);
            return c.gst_pad_push_event(p.srcpad, ev);
        },
        else => return c.gst_pad_event_default(pad, par, ev),
    }
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = scopeOf(par);
    const p = pv(s);
    if (q[0].type != c.GST_QUERY_LATENCY) return c.gst_pad_query_default(pad, par, q);
    const rate = s.ainfo.rate;
    if (rate == 0) return 0;
    const res = c.gst_pad_peer_query(p.sinkpad, q);
    if (res == 0) return 0;
    var live: c.gboolean = 0;
    var min: u64 = 0;
    var max: u64 = 0;
    c.gst_query_parse_latency(q, &live, &min, &max);
    const samples = @max(s.req_spf, p.spf);
    const ours = c.gst_util_uint64_scale_int(samples, c.GST_SECOND, rate);
    min +%= ours;
    if (max != NONE) max +%= ours;
    c.gst_query_set_latency(q, 1, min, max);
    return res;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = scopeOf(e);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) reset(s);
    const ret = parent.?.change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) _ = setAllocation(s, null, null, null, null);
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("baseaudiovisualizer-libvisual", 0, "scope audio visualisation base class");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const vc: *ScopeClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    ec.change_state = changeState;
    vc.decide_allocation = decideDefault;
    const flags = c.G_PARAM_READWRITE | c.GST_PARAM_CONTROLLABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_enum("shader", "shader type", "Shader function to apply on each frame", enums.gst_audio_visualizer_shader_get_type(), c.GST_AUDIO_VISUALIZER_SHADER_FADE, flags));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_uint("shade-amount", "shade amount", "Shading color to use (big-endian ARGB)", 0, std.math.maxInt(u32), 0x000a0a0a, flags));
}

fn init(inst: [*c]c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
    const s: *Scope = @ptrCast(@alignCast(inst));
    s.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    const p = pv(s);
    const ek: *c.GstElementClass = @ptrCast(@alignCast(g_class));
    var templ = c.gst_element_class_get_pad_template(ek, "sink");
    if (!check.that(templ != null, "gst_audio_visualizer_init", "pad_template != NULL")) return;
    p.sinkpad = c.gst_pad_new_from_template(templ, "sink");
    c.gst_pad_set_chain_function_full(p.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(p.sinkpad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), p.sinkpad);
    templ = c.gst_element_class_get_pad_template(ek, "src");
    if (!check.that(templ != null, "gst_audio_visualizer_init", "pad_template != NULL")) return;
    p.srcpad = c.gst_pad_new_from_template(templ, "src");
    c.gst_pad_set_event_function_full(p.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(p.srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), p.srcpad);
    p.adapter = c.gst_adapter_new();
    p.inbuf = c.gst_buffer_new();
    p.shader_type = c.GST_AUDIO_VISUALIZER_SHADER_FADE;
    changeShader(s);
    p.shade_amount = 0x000a0a0a;
    c.gst_video_info_init(&s.vinfo);
    p.frame_duration = NONE;
    c.gst_audio_info_init(&s.ainfo);
    c.gst_video_info_init(&s.vinfo);
    c.g_mutex_init(&p.config_lock);
}

pub export fn gst_audio_visualizer_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_element_get_type, "GstAudioVisualizer", ScopeClass, Scope, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            return t;
        }
    }.f);
}
