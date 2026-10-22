const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const basemixer = @import("basemixer.zig");
const bufferpool = @import("bufferpool.zig");
const framebuffer = @import("framebuffer.zig");
const syncmeta = @import("syncmeta.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Mix = c.GstGLMixer;
const OMix = [*c]Mix;
const Class = c.GstGLMixerClass;
const OAgg = [*c]c.GstAggregator;
const OVagg = [*c]c.GstVideoAggregator;
const OCtx = [*c]c.GstGLContext;
const FILE = "gstglmixer.c";

const RGBA_GL = "video/x-raw(memory:GLMemory), format = (string) RGBA, width = (int) [ 1, max ], height = (int) [ 1, max ], framerate = (fraction) [ 0, max ]";

var src_template = c.GstStaticPadTemplate{ .name_template = "src", .direction = c.GST_PAD_SRC, .presence = c.GST_PAD_ALWAYS, .static_caps = .{ .caps = null, .string = RGBA_GL, ._gst_reserved = std.mem.zeroes([4]c.gpointer) } };
var sink_template = c.GstStaticPadTemplate{ .name_template = "sink_%u", .direction = c.GST_PAD_SINK, .presence = c.GST_PAD_REQUEST, .static_caps = .{ .caps = null, .string = RGBA_GL, ._gst_reserved = std.mem.zeroes([4]c.gpointer) } };

const Priv = struct {
    negotiated: c.gboolean,
    ready: c.gboolean,
    lock: c.GMutex,
    cond: c.GCond,
    fbo: [*c]c.GstGLFramebuffer,
};

var once: gtype.Once = .{};
var pad_once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GstAggregatorClass = null;
var pad_parent: ?*c.GstVideoAggregatorPadClass = null;

fn mx(p: anytype) OMix {
    return @ptrCast(@alignCast(p));
}

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(mx(p)[0].priv));
}

fn klass(p: anytype) *Class {
    return gtype.classPeek(Class, p);
}

fn vagg(p: anytype) OVagg {
    return @ptrCast(@alignCast(p));
}

fn vparent() *c.GstVideoAggregatorClass {
    return @ptrCast(@alignCast(parent.?));
}

fn bparent() *c.GstGLBaseMixerClass {
    return @ptrCast(@alignCast(parent.?));
}

fn instanceSize(t: c.GType) usize {
    var q: c.GTypeQuery = undefined;
    c.g_type_query(t, &q);
    return q.instance_size;
}

fn texture(p: anytype) *c.guint {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(p)) + instanceSize(basemixer.gst_gl_base_mixer_pad_get_type())));
}

fn padInfo(p: anytype) *c.GstVideoInfo {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(p)) + instanceSize(c.gst_aggregator_pad_get_type())));
}

fn clear(p: anytype) void {
    if (p.* != null) {
        c.gst_object_unref(p.*);
        p.* = null;
    }
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/" ++ FILE, line, "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn padGet(o: [*c]c.GObject, id: c.guint, _: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 102);
}

fn padSet(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 113);
}

fn prepareFrame(p: ?*c.GstVideoAggregatorPad, a: OVagg, buf: [*c]c.GstBuffer, frame: [*c]c.GstVideoFrame) callconv(.c) c.gboolean {
    texture(p).* = 0;
    const sm = c.gst_buffer_get_meta(buf, syncmeta.gst_gl_sync_meta_api_get_type());
    if (sm != null) syncmeta.gst_gl_sync_meta_wait(@ptrCast(@alignCast(sm)), mx(a)[0].parent.context);
    if (c.gst_video_frame_map(frame, padInfo(p), buf, c.GST_MAP_READ | c.GST_MAP_GL) == 0) return 0;
    texture(p).* = @as(*c.guint, @ptrCast(@alignCast(frame[0].data[0]))).*;
    return 1;
}

fn cleanFrame(p: ?*c.GstVideoAggregatorPad, _: OVagg, frame: [*c]c.GstVideoFrame) callconv(.c) void {
    texture(p).* = 0;
    if (frame[0].buffer != null) {
        c.gst_video_frame_unmap(frame);
        frame[0] = std.mem.zeroes(c.GstVideoFrame);
    }
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = padSet;
    oc.get_property = padGet;
    const vc: *c.GstVideoAggregatorPadClass = @ptrCast(@alignCast(k));
    vc.prepare_frame = prepareFrame;
    vc.clean_frame = cleanFrame;
}

pub export fn gst_gl_mixer_pad_get_type() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            const padding = @sizeOf([c.GST_PADDING]c.gpointer);
            return gtype.objectExtending(basemixer.gst_gl_base_mixer_pad_get_type, "GstGLMixerPad", padding, @sizeOf(c.gpointer) + padding, padClassInit, null, 0);
        }
    }.f);
}

fn negotiatedCaps(a: OAgg, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const m = mx(a);
    pv(m).negotiated = 1;
    _ = c.gst_caps_replace(&m[0].out_caps, caps);
    return parent.?.negotiated_src_caps.?(a, caps);
}

fn findBestFormat(a: OVagg, down: [*c]c.GstCaps, best: [*c]c.GstVideoInfo, alpha: [*c]c.gboolean) callconv(.c) void {
    vparent().find_best_format.?(a, down, best, alpha);
    var t: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&t, c.GST_VIDEO_FORMAT_RGBA, @intCast(best[0].width), @intCast(best[0].height));
    t.par_n = best[0].par_n;
    t.par_d = best[0].par_d;
    t.fps_n = best[0].fps_n;
    t.fps_d = best[0].fps_d;
    t.flags = best[0].flags;
    t.interlace_mode = best[0].interlace_mode;
    best[0] = t;
}

fn proposeAllocation(a: OAgg, p: ?*c.GstAggregatorPad, dq: ?*c.GstQuery, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    if (parent.?.propose_allocation.?(a, p, dq, q) == 0) return 0;
    const ctx = mx(a)[0].parent.context;
    var caps: ?*c.GstCaps = null;
    var need: c.gboolean = 0;
    c.gst_query_parse_allocation(q, &caps, &need);
    if (caps == null) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    const size: c.guint = @truncate(info.size);
    var pool: [*c]c.GstBufferPool = null;
    if (need != 0) {
        pool = bufferpool.gst_gl_buffer_pool_new(ctx);
        const cfg = c.gst_buffer_pool_get_config(pool);
        c.gst_buffer_pool_config_set_params(cfg, caps, size, 0, 0);
        if (c.gst_buffer_pool_set_config(pool, cfg) == 0) {
            c.g_object_unref(pool);
            return 0;
        }
    }
    c.gst_query_add_allocation_pool(q, pool, size, 1, 0);
    if (pool != null) c.g_object_unref(pool);
    const vt: *c.GstGLFuncs = @ptrCast(ctx[0].gl_vtable);
    if (vt.FenceSync != null) c.gst_query_add_allocation_meta(q, syncmeta.gst_gl_sync_meta_api_get_type(), null);
    return 1;
}

fn sinkGetcaps(p: ?*c.GstPad, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const tmpl = c.gst_pad_get_pad_template_caps(p);
    var sink = c.gst_pad_get_current_caps(p);
    sink = if (sink == null) c.gst_caps_ref(tmpl) else c.gst_caps_merge(sink, c.gst_caps_ref(tmpl));
    var filtered = sink;
    if (filter != null) {
        filtered = c.gst_caps_intersect(sink, filter);
        c.gst_caps_unref(sink);
    }
    const r = c.gst_caps_intersect(filtered, tmpl);
    c.gst_caps_unref(tmpl);
    c.gst_caps_unref(filtered);
    return r;
}

fn sinkAcceptcaps(p: ?*c.GstPad, caps: [*c]c.GstCaps) c.gboolean {
    const tmpl = c.gst_caps_make_writable(c.gst_pad_get_pad_template_caps(p));
    const r = c.gst_caps_can_intersect(caps, tmpl);
    c.gst_caps_unref(tmpl);
    return r;
}

fn queryType(q: ?*c.GstQuery) c.GstQueryType {
    return @as(*c.GstQuery, @ptrCast(@alignCast(q))).type;
}

fn sinkQuery(a: OAgg, p: ?*c.GstAggregatorPad, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    switch (queryType(q)) {
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            const caps = sinkGetcaps(@ptrCast(@alignCast(p)), filter);
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(q, &caps);
            c.gst_query_set_accept_caps_result(q, sinkAcceptcaps(@ptrCast(@alignCast(p)), caps));
            return 1;
        },
        else => return parent.?.sink_query.?(a, p, q),
    }
}

fn queryCaps(p: ?*c.GstPad, a: OAgg, q: ?*c.GstQuery) c.gboolean {
    var filter: [*c]c.GstCaps = null;
    c.gst_query_parse_caps(q, &filter);
    var tmpl = c.gst_pad_get_pad_template_caps(a[0].srcpad);
    const cur = c.gst_pad_get_current_caps(p);
    var r: [*c]c.GstCaps = undefined;
    if (cur == null) {
        r = c.gst_caps_ref(tmpl);
    } else {
        r = c.gst_caps_merge(cur, tmpl);
        tmpl = null;
    }
    if (filter != null) {
        const i = c.gst_caps_intersect_full(filter, r, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(r);
        r = i;
    }
    c.gst_query_set_caps_result(q, r);
    c.gst_caps_unref(r);
    if (tmpl != null) c.gst_caps_unref(tmpl);
    return 1;
}

fn srcQuery(a: OAgg, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    if (queryType(q) == c.GST_QUERY_CAPS) return queryCaps(a[0].srcpad, a, q);
    return parent.?.src_query.?(a, q);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const m = mx(o);
    if (m[0].out_caps != null) c.gst_caps_unref(m[0].out_caps);
    c.g_mutex_clear(&pv(m).lock);
    c.g_cond_clear(&pv(m).cond);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn createFbo(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const m = mx(data);
    const info = &vagg(m)[0].info;
    c.g_mutex_lock(&pv(m).lock);
    if (pv(m).fbo == null) pv(m).fbo = framebuffer.gst_gl_framebuffer_new_with_default_depth(ctx, @intCast(info.width), @intCast(info.height));
    c.g_cond_signal(&pv(m).cond);
    if (pv(m).fbo != null) pv(m).ready = 1;
    c.g_mutex_unlock(&pv(m).lock);
}

fn glStart(b: [*c]c.GstGLBaseMixer) callconv(.c) c.gboolean {
    return bparent().gl_start.?(b);
}

fn glStop(b: [*c]c.GstGLBaseMixer) callconv(.c) void {
    const m = mx(b);
    c.g_mutex_lock(&pv(m).lock);
    clear(&pv(m).fbo);
    c.g_mutex_unlock(&pv(m).lock);
    bparent().gl_stop.?(b);
}

fn decideAllocation(a: OAgg, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const m = mx(a);
    if (parent.?.decide_allocation.?(a, q) == 0) return 0;
    var ctx = basemixer.gst_gl_base_mixer_get_gl_context(@ptrCast(m));
    if (ctx == null) return 0;
    c.g_mutex_lock(&pv(m).lock);
    pv(m).ready = 0;
    clear(&pv(m).fbo);
    c.g_mutex_unlock(&pv(m).lock);
    c.gst_gl_context_thread_add(ctx, createFbo, m);
    c.g_mutex_lock(&pv(m).lock);
    if (pv(m).fbo == null) {
        pv(m).ready = 0;
        c.g_mutex_unlock(&pv(m).lock);
        check.elementMessage(m, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Context error"), null, FILE, "gst_gl_mixer_decide_allocation", 666);
        return 0;
    }
    pv(m).ready = 1;
    c.g_cond_signal(&pv(m).cond);
    c.g_mutex_unlock(&pv(m).lock);
    var caps: ?*c.GstCaps = null;
    c.gst_query_parse_allocation(q, &caps, null);
    var pool: [*c]c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    var update = false;
    if (c.gst_query_get_n_allocation_pools(q) > 0) {
        c.gst_query_parse_nth_allocation_pool(q, 0, &pool, &size, &min, &max);
        update = true;
    } else {
        var vi: c.GstVideoInfo = undefined;
        c.gst_video_info_init(&vi);
        _ = c.gst_video_info_from_caps(&vi, caps);
        size = @truncate(vi.size);
    }
    if (pool == null) pool = bufferpool.gst_gl_buffer_pool_new(ctx);
    const cfg = c.gst_buffer_pool_get_config(pool);
    c.gst_buffer_pool_config_set_params(cfg, caps, size, min, max);
    c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionVideoMeta");
    if (c.gst_query_find_allocation_meta(q, syncmeta.gst_gl_sync_meta_api_get_type(), null) != 0) c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionGLSyncMeta");
    _ = c.gst_buffer_pool_set_config(pool, cfg);
    if (update) c.gst_query_set_nth_allocation_pool(q, 0, pool, size, min, max) else c.gst_query_add_allocation_pool(q, pool, size, min, max);
    c.gst_object_unref(pool);
    clear(&ctx);
    return 1;
}

pub export fn gst_gl_mixer_process_textures(m: OMix, out: [*c]c.GstBuffer) c.gboolean {
    var frame: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&frame, &vagg(m)[0].info, out, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) return 0;
    defer c.gst_video_frame_unmap(&frame);
    const tex: [*c]c.GstGLMemory = @ptrCast(@alignCast(frame.map[0].memory));
    c.g_mutex_lock(&pv(m).lock);
    if (pv(m).ready == 0) c.g_cond_wait(&pv(m).cond, &pv(m).lock);
    if (pv(m).ready == 0) {
        c.g_mutex_unlock(&pv(m).lock);
        return 0;
    }
    c.g_mutex_unlock(&pv(m).lock);
    _ = klass(m).process_textures.?(m, tex);
    return 1;
}

fn aggregateFrames(a: OVagg, out: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const m = mx(a);
    const k = klass(m);
    var ctx = basemixer.gst_gl_base_mixer_get_gl_context(@ptrCast(m));
    if (ctx == null) return c.GST_FLOW_CUSTOM_ERROR;
    var r: c.gboolean = 0;
    if (k.process_buffers) |pb| {
        r = pb(m, out);
    } else if (k.process_textures != null) {
        r = gst_gl_mixer_process_textures(m, out);
    }
    const sm = c.gst_buffer_get_meta(out, syncmeta.gst_gl_sync_meta_api_get_type());
    if (sm != null) syncmeta.gst_gl_sync_meta_set_sync_point(@ptrCast(@alignCast(sm)), ctx);
    clear(&ctx);
    return if (r != 0) c.GST_FLOW_OK else c.GST_FLOW_ERROR;
}

fn getProperty(o: [*c]c.GObject, id: c.guint, _: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 767);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 778);
}

fn start(a: OAgg) callconv(.c) c.gboolean {
    return parent.?.start.?(a);
}

fn stop(a: OAgg) callconv(.c) c.gboolean {
    pv(a).negotiated = 0;
    return parent.?.stop.?(a);
}

pub export fn gst_gl_mixer_get_framebuffer(m: OMix) [*c]c.GstGLFramebuffer {
    c.g_mutex_lock(&pv(m).lock);
    defer c.g_mutex_unlock(&pv(m).lock);
    return if (pv(m).fbo != null) @ptrCast(@alignCast(c.gst_object_ref(pv(m).fbo))) else null;
}

pub export fn gst_gl_mixer_class_add_rgba_pad_templates(k: [*c]Class) void {
    const ec: [*c]c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &src_template, c.gst_aggregator_pad_get_type());
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &sink_template, gst_gl_mixer_pad_get_type());
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    _ = c._gst_debug_category_new("glmixer", 0, "OpenGL mixer");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    const ac: *c.GstAggregatorClass = @ptrCast(@alignCast(k));
    ac.sink_query = sinkQuery;
    ac.src_query = srcQuery;
    ac.stop = stop;
    ac.start = start;
    ac.negotiated_src_caps = negotiatedCaps;
    ac.decide_allocation = decideAllocation;
    ac.propose_allocation = proposeAllocation;
    const vc: *c.GstVideoAggregatorClass = @ptrCast(@alignCast(k));
    vc.aggregate_frames = aggregateFrames;
    vc.find_best_format = findBestFormat;
    const bc: *c.GstGLBaseMixerClass = @ptrCast(@alignCast(k));
    bc.gl_start = glStart;
    bc.gl_stop = glStop;
    _ = c.g_type_class_ref(gst_gl_mixer_pad_get_type());
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const m = mx(inst);
    m[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(m).* = std.mem.zeroes(Priv);
    c.g_mutex_init(&pv(m).lock);
    c.g_cond_init(&pv(m).cond);
}

pub export fn gst_gl_mixer_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(basemixer.gst_gl_base_mixer_get_type, "GstGLMixer", Class, Mix, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            return t;
        }
    }.f);
}
