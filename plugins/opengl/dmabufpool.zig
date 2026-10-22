const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const Cache = opaque {};
const Entry = opaque {};
extern fn gst_egl_image_cache_new() ?*Cache;
extern fn gst_egl_image_cache_unref(cache: ?*Cache) void;
extern fn gst_egl_image_cache_lookup(cache: ?*Cache, mem: [*c]c.GstMemory, plane: c.gint, previous: *[*c]c.GstMemory, entry: *?*Entry) ?*c.GstEGLImage;
extern fn gst_egl_image_cache_store(cache: ?*Cache, mem: [*c]c.GstMemory, plane: c.gint, image: ?*c.GstEGLImage, entry: *?*Entry) void;

const Self = extern struct {
    parent: c.GstGLBufferPool,
    dmabuf_pool: [*c]c.GstBufferPool,
    dmabuf_caps: [*c]c.GstCaps,
    glparams: [*c]c.GstGLVideoAllocationParams,
    drm_info: c.GstVideoInfoDmaDrm,
    cache: ?*Cache,
    add_sync: c.gboolean,
};

const Class = extern struct {
    parent: c.GstGLBufferPoolClass,
};

var once: cm.Once = .{};
var parent: *c.GstBufferPoolClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var seq: c.gint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn setConfig(pool: [*c]c.GstBufferPool, config: ?*c.GstStructure) callconv(.c) c.gboolean {
    const s = me(pool);
    var caps: [*c]c.GstCaps = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    if (c.gst_buffer_pool_config_get_params(config, &caps, &size, &min, &max) == 0) return 0;
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_buffer_pool_config_get_allocator(config, &allocator, &params) == 0) return 0;
    if (allocator != null and c.g_type_check_instance_is_a(@ptrCast(allocator), c.gst_gl_memory_egl_allocator_get_type()) == 0) return 0;
    var align_ = std.mem.zeroes(c.GstVideoAlignment);
    for (0..c.GST_VIDEO_MAX_PLANES) |i| align_.stride_align[i] = 255;
    if (c.gst_buffer_pool_config_has_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT) == 0) {
        c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT);
        c.gst_buffer_pool_config_set_video_alignment(config, &align_);
    }
    _ = c.gst_buffer_pool_config_get_video_alignment(config, &align_);
    params.@"align" = @max(params.@"align", align_.stride_align[0]);
    c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
    var glparams = c.gst_buffer_pool_config_get_gl_allocation_params(config);
    if (glparams != null) {
        if (glparams[0].alloc_params != null) c.gst_allocation_params_free(glparams[0].alloc_params);
        glparams[0].alloc_params = c.gst_allocation_params_copy(&params);
        c.gst_buffer_pool_config_set_gl_allocation_params(config, glparams);
        c.gst_gl_allocation_params_free(glparams);
        glparams = null;
    }
    c.gst_buffer_pool_config_set_gl_min_free_queue_size(config, 0);
    s.add_sync = c.gst_buffer_pool_config_has_option(config, c.GST_BUFFER_POOL_OPTION_GL_SYNC_META);
    var dma = c.gst_buffer_pool_get_config(s.dmabuf_pool);
    c.gst_buffer_pool_config_set_params(dma, s.dmabuf_caps, size, min, max);
    c.gst_buffer_pool_config_add_option(dma, c.GST_BUFFER_POOL_OPTION_VIDEO_META);
    c.gst_buffer_pool_config_add_option(dma, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT);
    c.gst_buffer_pool_config_set_video_alignment(dma, &align_);
    if (c.gst_buffer_pool_set_config(s.dmabuf_pool, dma) == 0) {
        dma = c.gst_buffer_pool_get_config(s.dmabuf_pool);
        if (c.gst_buffer_pool_config_validate_params(dma, s.dmabuf_caps, size, min, max) == 0) {
            c.gst_structure_free(config);
            return 0;
        }
        if (c.gst_buffer_pool_config_get_params(dma, null, &size, &min, &max) == 0) {
            c.gst_structure_free(dma);
            return 0;
        }
        if (c.gst_buffer_pool_set_config(s.dmabuf_pool, dma) == 0) return 0;
        c.gst_buffer_pool_config_set_params(config, caps, size, min, max);
    }
    if (parent.set_config.?(pool, config) == 0) return 0;
    if (s.glparams != null) c.gst_gl_allocation_params_free(@ptrCast(s.glparams));
    s.glparams = @ptrCast(@alignCast(c.gst_gl_buffer_pool_get_gl_allocation_params(@ptrCast(pool))));
    s.glparams[0].parent.alloc_flags |= c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE;
    return 1;
}

fn start(pool: [*c]c.GstBufferPool) callconv(.c) c.gboolean {
    const s = me(pool);
    if (c.gst_buffer_pool_set_active(s.dmabuf_pool, 1) == 0) return 0;
    if (s.cache != null) gst_egl_image_cache_unref(s.cache);
    s.cache = gst_egl_image_cache_new();
    return parent.start.?(pool);
}

fn stop(pool: [*c]c.GstBufferPool) callconv(.c) c.gboolean {
    const s = me(pool);
    if (c.gst_buffer_pool_set_active(s.dmabuf_pool, 0) == 0) return 0;
    if (s.cache != null) gst_egl_image_cache_unref(s.cache);
    return parent.stop.?(pool);
}

const Setup = struct {
    images: [c.GST_VIDEO_MAX_PLANES]?*c.GstEGLImage = .{null} ** c.GST_VIDEO_MAX_PLANES,
    glparams: [*c]c.GstGLVideoAllocationParams = null,
    out: [*c]c.GstBuffer = null,
};

fn setupBuffer(_: ?*c.GstGLContext, data: c.gpointer) callconv(.c) void {
    const d: *Setup = @ptrCast(@alignCast(data));
    const alloc: ?*c.GstGLMemoryAllocator = @ptrCast(@alignCast(c.gst_allocator_find(c.GST_GL_MEMORY_EGL_ALLOCATOR_NAME)));
    defer if (alloc != null) c.gst_object_unref(alloc);
    if (c.gst_gl_memory_setup_buffer(alloc, d.out, d.glparams, null, @ptrCast(&d.images), d.glparams[0].v_info[0].finfo[0].n_planes) == 0) {
        c.gst_buffer_unref(d.out);
        d.out = null;
    }
}

fn allocBuffer(pool: [*c]c.GstBufferPool, out: [*c][*c]c.GstBuffer, _: [*c]c.GstBufferPoolAcquireParams) callconv(.c) c.GstFlowReturn {
    const b = c.gst_buffer_new();
    if (b == null) return c.GST_FLOW_ERROR;
    if (me(pool).add_sync != 0) _ = c.gst_buffer_add_gl_sync_meta(me(pool).parent.context, b);
    out.* = b;
    return c.GST_FLOW_OK;
}

fn acquireBuffer(pool: [*c]c.GstBufferPool, out: [*c][*c]c.GstBuffer, params: [*c]c.GstBufferPoolAcquireParams) callconv(.c) c.GstFlowReturn {
    const s = me(pool);
    const v = s.glparams[0].v_info;
    var dmabuf: [*c]c.GstBuffer = null;
    if (c.gst_buffer_pool_acquire_buffer(s.dmabuf_pool, &dmabuf, null) != c.GST_FLOW_OK) return c.GST_FLOW_ERROR;
    defer c.gst_buffer_unref(dmabuf);
    const vmeta = c.gst_buffer_get_video_meta(dmabuf);
    if (!cm.that(vmeta != null, "gst_gl_dmabuf_buffer_pool_acquire_buffer", "vmeta")) return c.GST_FLOW_ERROR;
    var d = Setup{};
    var prev: [*c]c.GstMemory = null;
    var entry: ?*Entry = null;
    const planes = v[0].finfo[0].n_planes;
    for (0..planes) |i| {
        s.drm_info.vinfo.stride[i] = vmeta[0].stride[i];
        v[0].stride[i] = vmeta[0].stride[i];
        s.drm_info.vinfo.offset[i] = vmeta[0].offset[i];
        v[0].offset[i] = vmeta[0].offset[i];
        var idx: c.guint = 0;
        var len: c.guint = 0;
        var skip: usize = 0;
        if (c.gst_buffer_find_memory(dmabuf, v[0].offset[i], 1, &idx, &len, &skip) == 0) return c.GST_FLOW_ERROR;
        const mem = c.gst_buffer_peek_memory(dmabuf, idx);
        d.images[i] = gst_egl_image_cache_lookup(s.cache, mem, @intCast(i), &prev, &entry);
        if (d.images[i] != null) continue;
        var fd = c.gst_dmabuf_memory_get_fd(mem);
        d.images[i] = if (v[0].finfo[0].format != c.GST_VIDEO_FORMAT_RGBA)
            c.gst_egl_image_from_dmabuf(s.parent.context, fd, v, @intCast(i), @intCast(skip))
        else
            c.gst_egl_image_from_dmabuf_direct_target_with_dma_drm(s.parent.context, 1, &fd, &skip, &s.drm_info, @as(c.GstGLTextureTarget, 0x0DE1));
        gst_egl_image_cache_store(s.cache, mem, @intCast(i), d.images[i], &entry);
    }
    d.glparams = s.glparams;
    if (parent.acquire_buffer.?(pool, &d.out, params) != c.GST_FLOW_OK) return c.GST_FLOW_ERROR;
    c.gst_gl_context_thread_add(s.parent.context, setupBuffer, &d);
    if (d.out == null) return c.GST_FLOW_ERROR;
    _ = c.gst_buffer_add_parent_buffer_meta(d.out, dmabuf);
    out.* = d.out;
    return c.GST_FLOW_OK;
}

fn resetBuffer(pool: [*c]c.GstBufferPool, b: [*c]c.GstBuffer) callconv(.c) void {
    c.gst_buffer_remove_all_memory(b);
    parent.reset_buffer.?(pool, b);
}

pub fn isDmabufBuffer(b: [*c]c.GstBuffer) bool {
    return b[0].pool != null and c.g_type_check_instance_is_a(@ptrCast(b[0].pool), getType()) != 0;
}

pub fn unwrap(b: [*c]c.GstBuffer) [*c]c.GstBuffer {
    if (!cm.that(isDmabufBuffer(b), "gst_gl_dmabuf_buffer_unwrap", "gst_is_gl_dmabuf_buffer (buffer)")) return null;
    const meta: [*c]c.GstParentBufferMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_parent_buffer_meta_api_get_type())));
    if (meta == null or meta[0].buffer == null) return null;
    const wrapped: [*c]c.GstBuffer = @ptrCast(c.gst_mini_object_ref(@ptrCast(meta[0].buffer)));
    _ = c.gst_buffer_remove_meta(b, @ptrCast(meta));
    _ = c.gst_buffer_copy_into(wrapped, b, c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_TIMESTAMPS | c.GST_BUFFER_COPY_META, 0, std.math.maxInt(usize));
    return wrapped;
}

pub fn new(ctx: ?*c.GstGLContext, dmabuf_pool: [*c]c.GstBufferPool, dmabuf_caps: [*c]c.GstCaps) [*c]c.GstBufferPool {
    const pname = c.gst_object_get_name(@ptrCast(dmabuf_pool));
    const name = c.g_strdup_printf("%s:gldmabufpool%d", pname, c.g_atomic_int_add(&seq, 1));
    c.g_free(pname);
    defer c.g_free(name);
    const p: *Self = @ptrCast(@alignCast(c.g_object_new(getType(), "name", name, @as(?*anyopaque, null))));
    _ = c.gst_object_ref_sink(p);
    p.parent.context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    p.dmabuf_pool = @ptrCast(@alignCast(c.gst_object_ref(dmabuf_pool)));
    p.dmabuf_caps = @ptrCast(c.gst_mini_object_ref(@ptrCast(dmabuf_caps)));
    _ = c.gst_video_info_dma_drm_from_caps(&p.drm_info, dmabuf_caps);
    return @ptrCast(p);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.dmabuf_pool != null) c.gst_object_unref(s.dmabuf_pool);
    s.dmabuf_pool = null;
    if (s.glparams != null) c.gst_gl_allocation_params_free(@ptrCast(s.glparams));
    s.glparams = null;
    parent_obj.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    parent_obj = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
    const bp: *c.GstBufferPoolClass = @ptrCast(@alignCast(k));
    bp.set_config = setConfig;
    bp.alloc_buffer = allocBuffer;
    bp.acquire_buffer = acquireBuffer;
    bp.reset_buffer = resetBuffer;
    bp.start = start;
    bp.stop = stop;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_buffer_pool_get_type(), "GstGLDMABufBufferPool", Class, Self, classInit, null);
            _ = c._gst_debug_category_new("gldmabufbufferpool", 0, "GL-DMABuf Buffer Pool");
            return t;
        }
    }.f);
}
