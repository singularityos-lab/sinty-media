const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const base = @import("basememory.zig");
const memory = @import("memory.zig");
const format = @import("format.zig");
const utils = @import("utils.zig");
const syncmeta = @import("syncmeta.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Pool = c.GstGLBufferPool;
const OPool = [*c]Pool;
const OBufferPool = [*c]c.GstBufferPool;
const OBuf = [*c]c.GstBuffer;
const OCtx = [*c]c.GstGLContext;

const OPT_VIDEO_META = "GstBufferPoolOptionVideoMeta";
const OPT_SYNC_META = "GstBufferPoolOptionGLSyncMeta";
const OPT_ALIGNMENT = "GstBufferPoolOptionVideoAlignment";
const OPT_2D = "GstBufferPoolOptionGLTextureTarget2D";
const OPT_RECT = "GstBufferPoolOptionGLTextureTargetRectangle";
const OPT_OES = "GstBufferPoolOptionGLTextureTargetExternalOES";
const Z = @as([*c]const u8, null);

const Priv = struct {
    allocator: ?*c.GstAllocator,
    gl_params: [*c]c.GstGLVideoAllocationParams,
    caps: ?*c.GstCaps,
    add_videometa: bool,
    add_glsyncmeta: bool,
    free_queue_min_depth: c.gsize,
    free_cache: ?*c.GQueue,
};

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GstBufferPoolClass = null;
var options = [_][*c]const u8{ OPT_VIDEO_META, OPT_SYNC_META, OPT_ALIGNMENT, OPT_2D, OPT_RECT, null };

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Pool, @ptrCast(@alignCast(p))).priv));
}

fn getOptions(_: OBufferPool) callconv(.c) [*c][*c]const u8 {
    return &options;
}

fn has(cfg: ?*c.GstStructure, opt: [*:0]const u8) bool {
    return c.gst_buffer_pool_config_has_option(cfg, opt) != 0;
}

fn setConfig(bp: OBufferPool, cfg: ?*c.GstStructure) callconv(.c) c.gboolean {
    const pool: OPool = @ptrCast(@alignCast(bp));
    const p = pv(pool);
    var caps: ?*c.GstCaps = null;
    var min: c.guint = 0;
    var max: c.guint = 0;
    if (c.gst_buffer_pool_config_get_params(cfg, &caps, null, &min, &max) == 0) return 0;
    if (caps == null) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    var allocator: ?*c.GstAllocator = null;
    var ap: c.GstAllocationParams = undefined;
    if (c.gst_buffer_pool_config_get_allocator(cfg, &allocator, &ap) == 0) return 0;
    const qmin = gst_buffer_pool_config_get_gl_min_free_queue_size(cfg);
    if (min < qmin) min = qmin;
    if (max != 0 and max < min) return 0;
    p.free_queue_min_depth = qmin;
    _ = c.gst_mini_object_replace(@ptrCast(&p.caps), @ptrCast(caps));
    if (p.allocator) |a| c.gst_object_unref(a);
    if (allocator) |a| {
        if (!gtype.instanceOf(a, memory.gst_gl_memory_allocator_get_type())) {
            c.gst_object_unref(a);
            return 0;
        }
        p.allocator = @ptrCast(@alignCast(c.gst_object_ref(a)));
    } else {
        p.allocator = @ptrCast(memory.gst_gl_memory_allocator_get_default(pool[0].context));
        if (p.allocator == null) check.assertFail("gstglbufferpool.c", 151, "gst_gl_buffer_pool_set_config", "priv->allocator");
    }
    p.add_videometa = has(cfg, OPT_VIDEO_META);
    p.add_glsyncmeta = has(cfg, OPT_SYNC_META);
    if (p.gl_params != null) base.gst_gl_allocation_params_free(@ptrCast(p.gl_params));
    p.gl_params = @ptrCast(@alignCast(gst_buffer_pool_config_get_gl_allocation_params(cfg)));
    if (p.gl_params == null) p.gl_params = memory.gst_gl_video_allocation_params_new(pool[0].context, &ap, &info, std.math.maxInt(c.guint), null, 0, 0);
    const gp = p.gl_params;
    var max_align: c.guint = @truncate(ap.@"align");
    if (has(cfg, OPT_ALIGNMENT)) {
        p.add_videometa = true;
        _ = c.gst_buffer_pool_config_get_video_alignment(cfg, gp[0].valign);
        for (0..c.GST_VIDEO_MAX_PLANES) |n| max_align |= gp[0].valign[0].stride_align[n];
        for (0..c.GST_VIDEO_MAX_PLANES) |n| gp[0].valign[0].stride_align[n] = max_align;
        _ = c.gst_video_info_align(gp[0].v_info, gp[0].valign);
        c.gst_buffer_pool_config_set_video_alignment(cfg, gp[0].valign);
    }
    if (ap.@"align" < max_align) {
        ap.@"align" = max_align;
        c.gst_buffer_pool_config_set_allocator(cfg, allocator, &ap);
        if (gp[0].parent.alloc_params != null) c.gst_allocation_params_free(gp[0].parent.alloc_params);
        gp[0].parent.alloc_params = c.gst_allocation_params_copy(&ap);
    }
    var ok = true;
    const s = c.gst_caps_get_structure(caps, 0);
    const ts = c.gst_structure_get_string(s, "texture-target");
    var multiple = false;
    var target = gp[0].target;
    if (ts != null) target = format.gst_gl_texture_target_from_string(ts);
    const opts = [_]struct { o: [*:0]const u8, t: c.GstGLTextureTarget }{ .{ .o = OPT_2D, .t = c.GST_GL_TEXTURE_TARGET_2D }, .{ .o = OPT_RECT, .t = c.GST_GL_TEXTURE_TARGET_RECTANGLE }, .{ .o = OPT_OES, .t = c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES } };
    for (opts) |e| {
        if (has(cfg, e.o)) {
            if (target != 0 and target != e.t) multiple = true;
            target = e.t;
        }
    }
    if (target == 0) target = c.GST_GL_TEXTURE_TARGET_2D;
    if (multiple) ok = false;
    gp[0].target = target;
    const vi = gp[0].v_info;
    vi[0].size = 0;
    var i: c.guint = 0;
    while (i < vi[0].finfo[0].n_planes) : (i += 1) {
        vi[0].offset[i] = vi[0].size;
        vi[0].size += utils.gst_gl_get_plane_data_size(vi, gp[0].valign, i);
    }
    c.gst_buffer_pool_config_set_params(cfg, caps, @truncate(vi[0].size), min, max);
    return @intFromBool(parent.?.set_config.?(bp, cfg) != 0 and ok);
}

fn start(bp: OBufferPool) callconv(.c) c.gboolean {
    return parent.?.start.?(bp);
}

fn objLock(p: anytype) void {
    c.g_mutex_lock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn objUnlock(p: anytype) void {
    c.g_mutex_unlock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn stop(bp: OBufferPool) callconv(.c) c.gboolean {
    const p = pv(bp);
    objLock(bp);
    const q = p.free_cache;
    p.free_cache = c.g_queue_new();
    objUnlock(bp);
    while (true) {
        const b: OBuf = @ptrCast(@alignCast(c.g_queue_pop_head(q)));
        if (b == null) break;
        parent.?.release_buffer.?(bp, b);
    }
    c.g_queue_free(q);
    return parent.?.stop.?(bp);
}

fn allocBuffer(bp: OBufferPool, out: [*c]OBuf, _: [*c]c.GstBufferPoolAcquireParams) callconv(.c) c.GstFlowReturn {
    const pool: OPool = @ptrCast(@alignCast(bp));
    const p = pv(pool);
    const b = c.gst_buffer_new();
    if (b == null) return c.GST_FLOW_ERROR;
    if (memory.gst_gl_memory_setup_buffer(@ptrCast(@alignCast(p.allocator)), b, p.gl_params, null, null, 0) == 0) return c.GST_FLOW_ERROR;
    if (p.add_glsyncmeta) _ = syncmeta.gst_buffer_add_gl_sync_meta(pool[0].context, b);
    out[0] = b;
    return c.GST_FLOW_OK;
}

fn releaseBuffer(bp: OBufferPool, b: OBuf) callconv(.c) void {
    const p = pv(bp);
    objLock(bp);
    if (p.free_queue_min_depth == 0 and c.g_queue_is_empty(p.free_cache) != 0) {
        objUnlock(bp);
        parent.?.release_buffer.?(bp, b);
        return;
    }
    const out = c.g_ptr_array_new();
    var len = c.g_queue_get_length(p.free_cache);
    c.g_queue_push_tail(p.free_cache, b);
    while (len > p.free_queue_min_depth) : (len -= 1) c.g_ptr_array_add(out, c.g_queue_pop_head(p.free_cache));
    objUnlock(bp);
    for (0..out[0].len) |i| parent.?.release_buffer.?(bp, @ptrCast(@alignCast(out[0].pdata[i])));
    c.g_ptr_array_unref(out);
}

pub export fn gst_gl_buffer_pool_new(ctx: OCtx) OBufferPool {
    const pool: OPool = @ptrCast(@alignCast(c.g_object_new(gst_gl_buffer_pool_get_type(), Z)));
    _ = c.gst_object_ref_sink(pool);
    pool[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    return @ptrCast(pool);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const pool: OPool = @ptrCast(@alignCast(o));
    const p = pv(pool);
    if (p.caps) |cp| c.gst_mini_object_unref(@ptrCast(cp));
    if (p.free_cache) |q| c.g_queue_free(q);
    p.free_cache = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
    if (pool[0].context != null) {
        c.gst_object_unref(pool[0].context);
        pool[0].context = null;
    }
    if (p.allocator) |a| {
        c.gst_object_unref(a);
        p.allocator = null;
    }
    if (p.gl_params != null) base.gst_gl_allocation_params_free(@ptrCast(p.gl_params));
    p.gl_params = null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
    const pc: *c.GstBufferPoolClass = @ptrCast(@alignCast(k));
    pc.get_options = getOptions;
    pc.set_config = setConfig;
    pc.alloc_buffer = allocBuffer;
    pc.release_buffer = releaseBuffer;
    pc.start = start;
    pc.stop = stop;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const pool: *Pool = @ptrCast(@alignCast(inst));
    pool.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(pool).* = std.mem.zeroes(Priv);
    pv(pool).add_videometa = true;
    pv(pool).free_cache = c.g_queue_new();
}

pub export fn gst_gl_buffer_pool_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_buffer_pool_get_type, "GstGLBufferPool", c.GstGLBufferPoolClass, Pool, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glbufferpool", 0, "GL Buffer Pool");
            return t;
        }
    }.f);
}

pub export fn gst_gl_buffer_pool_get_gl_allocation_params(pool: OPool) [*c]c.GstGLAllocationParams {
    if (!check.that(gtype.instanceOf(pool, gst_gl_buffer_pool_get_type()), "gst_gl_buffer_pool_get_gl_allocation_params", "GST_IS_GL_BUFFER_POOL (pool)")) return null;
    if (pv(pool).gl_params == null) return null;
    return base.gst_gl_allocation_params_copy(@ptrCast(pv(pool).gl_params));
}

pub export fn gst_buffer_pool_config_get_gl_allocation_params(cfg: ?*c.GstStructure) [*c]c.GstGLAllocationParams {
    var r: [*c]c.GstGLAllocationParams = null;
    if (c.gst_structure_get(cfg, "gl-allocation-params", base.gst_gl_allocation_params_get_type(), &r, Z) == 0) r = null;
    return r;
}

pub export fn gst_buffer_pool_config_set_gl_allocation_params(cfg: ?*c.GstStructure, params: [*c]const c.GstGLAllocationParams) void {
    const fname = "gst_buffer_pool_config_set_gl_allocation_params";
    if (!check.that(cfg != null, fname, "config != NULL")) return;
    if (!check.that(params != null, fname, "params != NULL")) return;
    c.gst_structure_set(cfg, "gl-allocation-params", base.gst_gl_allocation_params_get_type(), params, Z);
}

pub export fn gst_buffer_pool_config_set_gl_min_free_queue_size(cfg: ?*c.GstStructure, size: c.guint) void {
    if (!check.that(cfg != null, "gst_buffer_pool_config_set_gl_min_free_queue_size", "config != NULL")) return;
    c.gst_structure_set(cfg, "gl-min-free-queue-size", c.G_TYPE_UINT, size, Z);
}

pub export fn gst_buffer_pool_config_get_gl_min_free_queue_size(cfg: ?*c.GstStructure) c.guint {
    if (!check.that(cfg != null, "gst_buffer_pool_config_get_gl_min_free_queue_size", "config != NULL")) return 0;
    var size: c.guint = 0;
    if (c.gst_structure_get(cfg, "gl-min-free-queue-size", c.G_TYPE_UINT, &size, Z) == 0) size = 0;
    return size;
}
