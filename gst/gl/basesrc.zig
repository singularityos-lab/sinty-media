const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const display = @import("display.zig");
const utils = @import("utils.zig");
const debug = @import("debug.zig");
const bufferpool = @import("bufferpool.zig");
const syncmeta = @import("syncmeta.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Src = c.GstGLBaseSrc;
const OSrc = [*c]Src;
const Class = c.GstGLBaseSrcClass;
const OBase = [*c]c.GstBaseSrc;
const OCtx = [*c]c.GstGLContext;
const FILE = "gstglbasesrc.c";
const DOMAIN = "gst-plugins-base-1.0";

const Priv = struct {
    other: OCtx,
    out_tex: [*c]c.GstGLMemory,
    timestamp_offset: i64,
    accum_rtime: i64,
    accum_frames: i64,
    n_frames: i64,
    negotiated: c.gboolean,
    gl_result: c.gboolean,
    gl_started: c.gboolean,
    lock: c.GRecMutex,
};

const PROP_TIMESTAMP_OFFSET = 1;

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GstPushSrcClass = null;

fn sr(p: anytype) OSrc {
    return @ptrCast(@alignCast(p));
}

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(sr(p)[0].priv));
}

fn klass(p: anytype) *Class {
    return gtype.classPeek(Class, p);
}

fn bparent() *c.GstBaseSrcClass {
    return @ptrCast(@alignCast(parent.?));
}

fn eparent() *c.GstElementClass {
    return @ptrCast(@alignCast(parent.?));
}

fn lock(s: OSrc) void {
    c.g_rec_mutex_lock(&pv(s).lock);
}

fn unlock(s: OSrc) void {
    c.g_rec_mutex_unlock(&pv(s).lock);
}

fn clear(p: anytype) void {
    if (p.* != null) {
        c.gst_object_unref(p.*);
        p.* = null;
    }
}

fn tr(s: [*:0]const u8) [*c]u8 {
    return c.g_strdup(c.dgettext(DOMAIN, s));
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_rec_mutex_clear(&pv(o).lock);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_TIMESTAMP_OFFSET) pv(o).timestamp_offset = c.g_value_get_int64(v);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_TIMESTAMP_OFFSET) {
        c.g_value_set_int64(v, pv(o).timestamp_offset);
        return;
    }
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/" ++ FILE, @as(c_int, 198), "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn setCaps(b: OBase, caps: ?*c.GstCaps) callconv(.c) c.gboolean {
    const s = sr(b);
    const p = pv(s);
    if (c.gst_video_info_from_caps(&s[0].out_info, caps) == 0) return 0;
    p.negotiated = 1;
    p.accum_rtime += @bitCast(s[0].running_time);
    p.accum_frames += p.n_frames;
    s[0].running_time = 0;
    p.n_frames = 0;
    _ = c.gst_mini_object_replace(@ptrCast(&s[0].out_caps), @ptrCast(caps));
    return 1;
}

fn setContext(el: [*c]c.GstElement, ctx: ?*c.GstContext) callconv(.c) void {
    const s = sr(el);
    lock(s);
    var old: [*c]c.GstGLDisplay = if (s[0].display != null) @ptrCast(@alignCast(c.gst_object_ref(s[0].display))) else null;
    _ = utils.gst_gl_handle_set_context(el, ctx, &s[0].display, &pv(s).other);
    if (s[0].display != null) display.gst_gl_display_filter_gl_api(s[0].display, klass(s).supported_gl_api);
    var new: [*c]c.GstGLDisplay = if (s[0].display != null) @ptrCast(@alignCast(c.gst_object_ref(s[0].display))) else null;
    if (old != null and new != null and old != new) {
        clear(&s[0].context);
        if (findGlContextUnlocked(s)) c.gst_pad_mark_reconfigure(s[0].parent.parent.srcpad);
    }
    clear(&old);
    clear(&new);
    unlock(s);
    eparent().set_context.?(el, ctx);
}

fn query(b: OBase, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const s = sr(b);
    const qt = @as(*c.GstQuery, @ptrCast(@alignCast(q))).type;
    if (qt == c.GST_QUERY_CONTEXT) {
        var d: [*c]c.GstGLDisplay = null;
        var other: OCtx = null;
        var local: OCtx = null;
        lock(s);
        if (s[0].display != null) d = @ptrCast(@alignCast(c.gst_object_ref(s[0].display)));
        if (s[0].context != null) local = @ptrCast(@alignCast(c.gst_object_ref(s[0].context)));
        if (pv(s).other != null) other = @ptrCast(@alignCast(c.gst_object_ref(pv(s).other)));
        unlock(s);
        const r = utils.gst_gl_handle_context_query(@ptrCast(s), q, d, local, other);
        clear(&d);
        clear(&other);
        clear(&local);
        if (r != 0) return r;
    } else if (qt == c.GST_QUERY_CONVERT) {
        var sf: c.GstFormat = 0;
        var df: c.GstFormat = 0;
        var sv: i64 = 0;
        var dv: i64 = 0;
        c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
        const r = c.gst_video_info_convert(&s[0].out_info, sf, sv, df, &dv);
        c.gst_query_set_convert(q, sf, sv, df, dv);
        return r;
    }
    return bparent().query.?(b, q);
}

fn getTimes(b: OBase, buf: [*c]c.GstBuffer, start_: [*c]c.GstClockTime, end_: [*c]c.GstClockTime) callconv(.c) void {
    if (c.gst_base_src_is_live(b) != 0) {
        const ts = buf[0].pts;
        if (ts != c.GST_CLOCK_TIME_NONE) {
            const d = buf[0].duration;
            if (d != c.GST_CLOCK_TIME_NONE) end_[0] = ts + d;
            start_[0] = ts;
        }
    } else {
        start_[0] = c.GST_CLOCK_TIME_NONE;
        end_[0] = c.GST_CLOCK_TIME_NONE;
    }
}

fn defaultGlStart(_: OSrc) callconv(.c) c.gboolean {
    return 1;
}

fn defaultGlStop(_: OSrc) callconv(.c) void {}

fn defaultFill(_: OSrc, _: [*c]c.GstGLMemory) callconv(.c) c.gboolean {
    return 1;
}

fn glStart(_: OCtx, data: c.gpointer) callconv(.c) void {
    const s = sr(data);
    debug.gst_gl_insert_debug_marker(s[0].context, "starting element %s", s[0].parent.parent.element.object.name);
    pv(s).gl_started = klass(s).gl_start.?(s);
}

fn glStop(_: OCtx, data: c.gpointer) callconv(.c) void {
    const s = sr(data);
    debug.gst_gl_insert_debug_marker(s[0].context, "stopping element %s", s[0].parent.parent.element.object.name);
    pv(s).out_tex = null;
    if (pv(s).gl_started != 0) klass(s).gl_stop.?(s);
    pv(s).gl_started = 0;
}

fn fillGl(_: OCtx, data: c.gpointer) callconv(.c) void {
    const s = sr(data);
    pv(s).gl_result = klass(s).fill_gl_memory.?(s, pv(s).out_tex);
}

fn fill(ps: [*c]c.GstPushSrc, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = sr(ps);
    const p = pv(s);
    lock(s);
    if (p.negotiated == 0 or s[0].context == null) {
        unlock(s);
        check.elementMessage(s, c.GST_MESSAGE_ERROR, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("format wasn't negotiated before get function"), FILE, "gst_gl_base_src_fill", 463);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    if (s[0].out_info.fps_n == 0 and p.n_frames == 1) {
        unlock(s);
        return c.GST_FLOW_EOS;
    }
    var frame: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&frame, &s[0].out_info, buf, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) {
        unlock(s);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    p.out_tex = @ptrCast(@alignCast(frame.map[0].memory));
    c.gst_gl_context_thread_add(s[0].context, fillGl, s);
    c.gst_video_frame_unmap(&frame);
    if (p.gl_result == 0) {
        unlock(s);
        check.elementMessage(s, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, tr("An OpenGL error occurred"), c.g_strdup("failed to fill GL memory"), FILE, "gst_gl_base_src_fill", 456);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    const sm = c.gst_buffer_get_meta(buf, syncmeta.gst_gl_sync_meta_api_get_type());
    if (sm != null) syncmeta.gst_gl_sync_meta_set_sync_point(@ptrCast(@alignCast(sm)), s[0].context);
    unlock(s);
    buf[0].pts = @bitCast(p.accum_rtime + p.timestamp_offset + @as(i64, @bitCast(s[0].running_time)));
    buf[0].offset = @bitCast(p.accum_frames + p.n_frames);
    p.n_frames += 1;
    buf[0].offset_end = @bitCast(p.accum_frames + p.n_frames);
    var next: c.GstClockTime = 0;
    if (s[0].out_info.fps_n != 0) {
        next = c.gst_util_uint64_scale_int(@as(u64, @bitCast(p.n_frames)) *% c.GST_SECOND, s[0].out_info.fps_d, s[0].out_info.fps_n);
        buf[0].duration = next -% s[0].running_time;
    } else {
        next = @bitCast(p.timestamp_offset);
        buf[0].duration = c.GST_CLOCK_TIME_NONE;
    }
    s[0].running_time = next;
    return c.GST_FLOW_OK;
}

fn start(b: OBase) callconv(.c) c.gboolean {
    const s = sr(b);
    s[0].running_time = 0;
    pv(s).n_frames = 0;
    pv(s).negotiated = 0;
    return 1;
}

fn stop(b: OBase) callconv(.c) c.gboolean {
    const s = sr(b);
    lock(s);
    _ = c.gst_mini_object_replace(@ptrCast(&s[0].out_caps), null);
    if (s[0].context != null) {
        if (pv(s).gl_started != 0) c.gst_gl_context_thread_add(s[0].context, glStop, s);
        c.gst_object_unref(s[0].context);
    }
    s[0].context = null;
    unlock(s);
    return 1;
}

fn findLocalUnlocked(s: OSrc) bool {
    if (s[0].context != null and s[0].context[0].display == s[0].display) return true;
    var ctx = s[0].context;
    const prev = ctx;
    unlock(s);
    const r = utils.gst_gl_query_local_gl_context(@ptrCast(s), c.GST_PAD_SRC, &ctx) != 0;
    lock(s);
    if (!r) return false;
    if (s[0].context != prev and s[0].context != null and s[0].context[0].display == s[0].display) {
        if (ctx != s[0].context) clear(&ctx);
        return true;
    }
    if (ctx[0].display == s[0].display) {
        s[0].context = ctx;
        return true;
    }
    if (ctx != s[0].context) clear(&ctx);
    return false;
}

fn findGlContextUnlocked(s: OSrc) bool {
    const k = klass(s);
    var err: [*c]c.GError = null;
    const fresh = s[0].context == null;
    if (utils.gst_gl_ensure_element_data(s, &s[0].display, &pv(s).other) == 0) return false;
    display.gst_gl_display_filter_gl_api(s[0].display, k.supported_gl_api);
    _ = findLocalUnlocked(s);
    if (display.gst_gl_display_ensure_context(s[0].display, pv(s).other, &s[0].context, &err) == 0) {
        if (err != null) {
            check.elementMessage(s, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("%s", err[0].message), null, FILE, "gst_gl_base_src_find_gl_context_unlocked", 610);
            c.g_clear_error(&err);
        } else {
            check.elementMessage(s, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, null, null, FILE, "gst_gl_base_src_find_gl_context_unlocked", 614);
        }
        clear(&s[0].context);
        return false;
    }
    if (fresh or pv(s).gl_started == 0) {
        if (pv(s).gl_started != 0) c.gst_gl_context_thread_add(s[0].context, glStop, s);
        if (context.gst_gl_context_get_gl_api(s[0].context) & k.supported_gl_api == 0) {
            const a = c.gst_gl_api_to_string(context.gst_gl_context_get_gl_api(s[0].context));
            const sa = c.gst_gl_api_to_string(k.supported_gl_api);
            check.elementMessage(s, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_BUSY, tr("The GL API is not compatible with the current GL context"), c.g_strdup_printf("Current GL API is %s, supported APIs: %s", a, sa), FILE, "gst_gl_base_src_find_gl_context_unlocked", 598);
            c.g_free(sa);
            c.g_free(a);
            return false;
        }
        c.gst_gl_context_thread_add(s[0].context, glStart, s);
        if (pv(s).gl_started == 0) {
            check.elementMessage(s, c.GST_MESSAGE_ERROR, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_INIT, tr("Subclass failed to initialize."), null, FILE, "gst_gl_base_src_find_gl_context_unlocked", 623);
            return false;
        }
    }
    return true;
}

fn decideAllocation(b: OBase, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const s = sr(b);
    lock(s);
    if (!findGlContextUnlocked(s)) {
        unlock(s);
        return 0;
    }
    const ctx: OCtx = @ptrCast(@alignCast(c.gst_object_ref(s[0].context)));
    unlock(s);
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
    if (pool == null or !gtype.instanceOf(pool, bufferpool.gst_gl_buffer_pool_get_type())) {
        if (pool != null) c.gst_object_unref(pool);
        pool = bufferpool.gst_gl_buffer_pool_new(ctx);
    }
    const cfg = c.gst_buffer_pool_get_config(pool);
    c.gst_buffer_pool_config_set_params(cfg, caps, size, min, max);
    c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionVideoMeta");
    if (c.gst_query_find_allocation_meta(q, syncmeta.gst_gl_sync_meta_api_get_type(), null) != 0) c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionGLSyncMeta");
    c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionVideoGLTextureUploadMeta");
    _ = c.gst_buffer_pool_set_config(pool, cfg);
    if (update) c.gst_query_set_nth_allocation_pool(q, 0, pool, size, min, max) else c.gst_query_add_allocation_pool(q, pool, size, min, max);
    c.gst_object_unref(pool);
    c.gst_object_unref(ctx);
    return 1;
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = sr(el);
    const r = eparent().change_state.?(el, t);
    if (r == c.GST_STATE_CHANGE_FAILURE) return r;
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) {
        lock(s);
        clear(&pv(s).other);
        clear(&s[0].display);
        unlock(s);
    }
    return r;
}

fn doSeek(b: OBase, seg: [*c]c.GstSegment) callconv(.c) c.gboolean {
    const s = sr(b);
    const p = pv(s);
    seg[0].time = seg[0].start;
    const time = seg[0].position;
    const fn_: u64 = @intCast(s[0].out_info.fps_n);
    const fd: u64 = @intCast(s[0].out_info.fps_d);
    p.n_frames = if (fn_ != 0) @bitCast(c.gst_util_uint64_scale(time, fn_, fd *% c.GST_SECOND)) else 0;
    p.accum_frames = 0;
    p.accum_rtime = 0;
    s[0].running_time = if (fn_ != 0) c.gst_util_uint64_scale(@bitCast(p.n_frames), fd *% c.GST_SECOND, fn_) else 0;
    if (!check.that(s[0].running_time <= time, "gst_gl_base_src_do_seek", "src->running_time <= time")) return 0;
    return bparent().do_seek.?(b, seg);
}

pub export fn gst_gl_base_src_get_gl_context(s: OSrc) OCtx {
    lock(s);
    defer unlock(s);
    return if (s[0].context != null) @ptrCast(@alignCast(c.gst_object_ref(s[0].context))) else null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_TIMESTAMP_OFFSET, c.g_param_spec_int64("timestamp-offset", "Timestamp offset", "An offset added to timestamps set on buffers (in ns)", std.math.minInt(i64), std.math.maxInt(i64), 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.set_context = setContext;
    ec.change_state = changeState;
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.set_caps = setCaps;
    bc.query = query;
    bc.get_times = getTimes;
    bc.start = start;
    bc.stop = stop;
    bc.decide_allocation = decideAllocation;
    bc.do_seek = doSeek;
    @as(*c.GstPushSrcClass, @ptrCast(@alignCast(k))).fill = fill;
    const sc: *Class = @ptrCast(@alignCast(k));
    sc.supported_gl_api = c.GST_GL_API_ANY;
    sc.gl_start = defaultGlStart;
    sc.gl_stop = defaultGlStop;
    sc.fill_gl_memory = defaultFill;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = sr(inst);
    s[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(s).* = std.mem.zeroes(Priv);
    c.g_rec_mutex_init(&pv(s).lock);
    c.gst_base_src_set_format(@ptrCast(s), c.GST_FORMAT_TIME);
    c.gst_base_src_set_live(@ptrCast(s), 0);
}

pub export fn gst_gl_base_src_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_push_src_get_type, "GstGLBaseSrc", Class, Src, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glbasesrc", 0, "glbasesrc element");
            return t;
        }
    }.f);
}
