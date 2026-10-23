const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const x = @import("x.zig");
const X = x.p;
const ctxm = @import("context.zig");
const Ctx = ctxm.Ctx;

pub const Memory = extern struct {
    parent: c.GstMemory,
    im_format: c.gint,
    info: c.GstVideoInfo,
    crop: c.GstVideoRectangle,
    xvimage: [*c]X.XvImage,
    shm: X.XShmSegmentInfo,
};

pub const Allocator = extern struct {
    parent: c.GstAllocator,
    context: *Ctx,
};

const AllocatorClass = extern struct {
    parent: c.GstAllocatorClass,
};

pub const Pool = extern struct {
    pool: c.GstBufferPool,
    allocator: *Allocator,
    caps: [*c]c.GstCaps,
    info: c.GstVideoInfo,
    @"align": c.GstVideoAlignment,
    padded_width: c.guint,
    padded_height: c.guint,
    add_metavideo: c.gboolean,
    need_alignment: c.gboolean,
    im_format: c.gint,
    crop: c.GstVideoRectangle,
    pre_alloc_mem: [*c]c.GstMemory,
};

const PoolClass = extern struct {
    parent: c.GstBufferPoolClass,
};

pub var pool_cat: ?*c.GstDebugCategory = null;
var alloc_cat: ?*c.GstDebugCategory = null;
var alloc_once: cm.Once = .{};
var pool_once: cm.Once = .{};
var parent_alloc: *c.GObjectClass = undefined;
var parent_pool: *c.GstBufferPoolClass = undefined;

fn allocatorType() c.GType {
    return alloc_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_allocator_get_type(), "GstXvImageAllocator", AllocatorClass, Allocator, allocClassInit, allocInit);
        }
    }.f);
}

pub fn fromContext(m: [*c]c.GstMemory, ctx: ?*Ctx) bool {
    const a = m[0].allocator;
    if (a == null or c.g_type_check_instance_is_a(@ptrCast(a), allocatorType()) == 0) return false;
    const al: *Allocator = @ptrCast(@alignCast(a));
    return ctx != null and al.context == ctx.?;
}

fn dummyAlloc(_: [*c]c.GstAllocator, _: usize, _: [*c]c.GstAllocationParams) callconv(.c) [*c]c.GstMemory {
    return null;
}

fn memFree(a: [*c]c.GstAllocator, g: [*c]c.GstMemory) callconv(.c) void {
    const m: *Memory = @ptrCast(@alignCast(g));
    if (g[0].parent != null) {
        c.g_free(m);
        return;
    }
    const ctx = @as(*Allocator, @ptrCast(@alignCast(a))).context;
    c.g_mutex_lock(&ctx.lock);
    if (ctx.use_xshm != 0) {
        if (!x.noAddr(m.shm.shmaddr)) {
            _ = X.XShmDetach(ctx.disp, &m.shm);
            _ = X.XSync(ctx.disp, 0);
            _ = X.shmdt(m.shm.shmaddr);
            m.shm.shmaddr = @ptrCast(x.NO_ADDR);
        }
        if (m.xvimage != null) _ = X.XFree(m.xvimage);
    } else if (m.xvimage != null) {
        c.g_free(m.xvimage[0].data);
        _ = X.XFree(m.xvimage);
    }
    _ = X.XSync(ctx.disp, 0);
    c.g_mutex_unlock(&ctx.lock);
    c.g_free(m);
}

fn memMap(m: *Memory, _: usize, _: c.GstMapFlags) callconv(.c) c.gpointer {
    return m.xvimage[0].data + m.parent.offset;
}

fn memUnmap(_: *Memory) callconv(.c) c.gboolean {
    return 1;
}

fn memShare(m: *Memory, offset: isize, size: isize) callconv(.c) ?*Memory {
    if (offset != 0) return null;
    if (size != -1 and size != m.xvimage[0].data_size) return null;
    const parent: *c.GstMemory = if (m.parent.parent != null) m.parent.parent else &m.parent;
    const n: usize = if (size == -1) m.parent.size else @intCast(size);
    const sub: *Memory = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Memory))));
    c.gst_memory_init(&sub.parent, parent.mini_object.flags | c.GST_MINI_OBJECT_FLAG_LOCK_READONLY, m.parent.allocator, &m.parent, m.parent.maxsize, m.parent.@"align", m.parent.offset, n);
    sub.info = m.info;
    sub.im_format = m.im_format;
    sub.crop = m.crop;
    sub.xvimage = m.xvimage;
    sub.shm = m.shm;
    return sub;
}

fn memCopy(g: [*c]c.GstMemory, offset: isize, size: isize) callconv(.c) [*c]c.GstMemory {
    const m: *Memory = @ptrCast(@alignCast(g));
    if (offset != 0) return null;
    if (size != -1 and size != m.xvimage[0].data_size) return null;
    const cp = alloc(@ptrCast(@alignCast(g[0].allocator)), m.im_format, &m.info, m.xvimage[0].width, m.xvimage[0].height, &m.crop, null) orelse return null;
    const dst: *Memory = @ptrCast(@alignCast(cp));
    @memcpy(dst.xvimage[0].data[dst.parent.offset..][0..@intCast(m.xvimage[0].data_size)], m.xvimage[0].data[m.parent.offset..][0..@intCast(m.xvimage[0].data_size)]);
    return cp;
}

fn allocFinalize(o: [*c]c.GObject) callconv(.c) void {
    const a: *Allocator = @ptrCast(@alignCast(o));
    ctxm.unref(a.context);
    parent_alloc.finalize.?(o);
}

fn allocClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_alloc = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = allocFinalize;
    const ac: *c.GstAllocatorClass = @ptrCast(@alignCast(k));
    ac.alloc = dummyAlloc;
    ac.free = memFree;
    alloc_cat = c._gst_debug_category_new("xvimageallocator", 0, "xvimageallocator object");
}

fn allocInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *c.GstAllocator = @ptrCast(@alignCast(inst));
    a.mem_type = "xvimage";
    a.mem_map = @ptrCast(&memMap);
    a.mem_unmap = @ptrCast(&memUnmap);
    a.mem_share = @ptrCast(&memShare);
    a.mem_copy = @ptrCast(&memCopy);
    a.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

pub fn newAllocator(ctx: *Ctx) *Allocator {
    const a: *Allocator = @ptrCast(@alignCast(c.g_object_new(allocatorType(), null)));
    a.context = ctxm.ref(ctx);
    _ = c.gst_object_ref_sink(a);
    return a;
}

fn up(v: c.gint, comptime n: c.gint) c.gint {
    return (v + n - 1) & ~@as(c.gint, n - 1);
}

fn expectedSize(info: *const c.GstVideoInfo, w: c.gint, h: c.gint) c.gint {
    const f = info.finfo[0];
    if (f.flags & c.GST_VIDEO_FORMAT_FLAG_YUV != 0) {
        return switch (f.format) {
            c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_YV12 => blk: {
                const p0 = up(w, 4);
                const o1 = p0 * up(h, 2);
                const p1 = @divTrunc(up(w, 8), 2);
                const o2 = o1 + @divTrunc(p1 * up(h, 2), 2);
                const p2 = @divTrunc(up(p0, 8), 2);
                break :blk o2 + @divTrunc(p2 * up(h, 2), 2);
            },
            c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY => h * up(w * 2, 4),
            else => 0,
        };
    }
    if (f.flags & c.GST_VIDEO_FORMAT_FLAG_RGB != 0 and f.n_planes == 1) return h * up(w * f.pixel_stride[0], 4);
    return 0;
}

pub fn alloc(a: *Allocator, im_format: c.gint, info: *const c.GstVideoInfo, w: c.gint, h: c.gint, crop: *const c.GstVideoRectangle, err: [*c][*c]c.GError) ?*c.GstMemory {
    const ctx = a.context;
    const m: *Memory = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Memory))));
    m.im_format = im_format;
    m.info = info.*;
    m.shm.shmaddr = @ptrCast(x.NO_ADDR);
    m.shm.shmid = -1;
    m.crop = crop.*;
    c.g_mutex_lock(&ctx.lock);
    const prev = ctxm.trapErrors();
    var al: usize = 0;
    var shm_ok = false;
    if (ctx.use_xshm != 0) {
        m.xvimage = X.XvShmCreateImage(ctx.disp, ctx.xv_port_id, im_format, null, w, h, &m.shm);
        if (m.xvimage == null or ctxm.errorCaught()) {
            if (m.xvimage != null) {
                _ = X.XFree(m.xvimage);
                m.xvimage = null;
            }
            c.g_mutex_unlock(&ctx.lock);
            ctxm.clearCaught();
            ctx.use_xshm = 0;
            c.g_mutex_lock(&ctx.lock);
        } else {
            const want = expectedSize(info, w, h);
            if (want != 0 and m.xvimage[0].data_size < want) {
                c.g_mutex_unlock(&ctx.lock);
                c.g_set_error(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, "unexpected XShm image size (got %d, expected %d)", m.xvimage[0].data_size, want);
                c.g_free(m);
                return null;
            }
            m.shm.shmid = X.shmget(X.IPC_PRIVATE, @intCast(m.xvimage[0].data_size), X.IPC_CREAT | 0o777);
            if (m.shm.shmid == -1) {
                c.g_mutex_unlock(&ctx.lock);
                c.g_set_error(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, "could not get shared memory of %d bytes", m.xvimage[0].data_size);
                c.g_free(m);
                return null;
            }
            m.shm.shmaddr = @ptrCast(X.shmat(m.shm.shmid, null, 0));
            if (x.noAddr(m.shm.shmaddr)) {
                c.g_mutex_unlock(&ctx.lock);
                c.g_set_error(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, "Failed to shmat: %s", c.g_strerror(std.c._errno().*));
                _ = X.shmctl(m.shm.shmid, X.IPC_RMID, null);
                c.g_free(m);
                return null;
            }
            m.xvimage[0].data = m.shm.shmaddr;
            m.shm.readOnly = 0;
            if (X.XShmAttach(ctx.disp, &m.shm) == 0) {
                _ = X.shmctl(m.shm.shmid, X.IPC_RMID, null);
                c.g_mutex_unlock(&ctx.lock);
                c.g_set_error_literal(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, "Failed to XShmAttach");
                c.g_free(m);
                return null;
            }
            _ = X.XSync(ctx.disp, 0);
            _ = X.shmctl(m.shm.shmid, X.IPC_RMID, null);
            shm_ok = true;
        }
    }
    if (!shm_ok) {
        m.xvimage = X.XvCreateImage(ctx.disp, ctx.xv_port_id, im_format, null, w, h);
        if (m.xvimage == null or ctxm.errorCaught()) {
            c.g_mutex_unlock(&ctx.lock);
            ctxm.untrap(prev);
            c.g_set_error(err, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, "could not XvShmCreateImage a %dx%d image", w, h);
            c.g_free(m);
            return null;
        }
        al = 15;
        m.xvimage[0].data = @ptrCast(c.g_malloc(@as(usize, @intCast(m.xvimage[0].data_size)) + al));
        _ = X.XSync(ctx.disp, 0);
    }
    var off: usize = @intFromPtr(m.xvimage[0].data) & al;
    if (off != 0) off = al + 1 - off;
    ctxm.untrap(prev);
    const size: usize = @intCast(m.xvimage[0].data_size);
    c.gst_memory_init(&m.parent, 0, &a.parent, null, size + al, al, off, size);
    c.g_mutex_unlock(&ctx.lock);
    return &m.parent;
}

fn drawBorders(w: *ctxm.Win, r: *const c.GstVideoRectangle) void {
    const ctx = w.context;
    const d = ctx.disp;
    const rr = w.render_rect;
    _ = X.XSetForeground(d, w.gc, ctx.black);
    if (r.x > rr.x) _ = X.XFillRectangle(d, w.win, w.gc, rr.x, rr.y, @intCast(r.x - rr.x), @intCast(rr.h));
    var t1 = r.x + r.w;
    var t2 = rr.x + rr.w;
    if (t1 < t2) _ = X.XFillRectangle(d, w.win, w.gc, t1, rr.y, @intCast(t2 - t1), @intCast(rr.h));
    if (r.y > rr.y) _ = X.XFillRectangle(d, w.win, w.gc, rr.x, rr.y, @intCast(rr.w), @intCast(r.y - rr.y));
    t1 = r.y + r.h;
    t2 = rr.y + rr.h;
    if (t1 < t2) _ = X.XFillRectangle(d, w.win, w.gc, rr.x, t1, @intCast(rr.w), @intCast(t2 - t1));
}

pub fn render(m: *Memory, src: *const c.GstVideoRectangle, w: *ctxm.Win, dst: *const c.GstVideoRectangle, border: bool) void {
    const ctx = w.context;
    c.g_mutex_lock(&ctx.lock);
    if (border) drawBorders(w, dst);
    if (ctx.use_xshm != 0) {
        _ = X.XvShmPutImage(ctx.disp, ctx.xv_port_id, w.win, w.gc, m.xvimage, src.x, src.y, @intCast(src.w), @intCast(src.h), dst.x, dst.y, @intCast(dst.w), @intCast(dst.h), 0);
    } else {
        _ = X.XvPutImage(ctx.disp, ctx.xv_port_id, w.win, w.gc, m.xvimage, src.x, src.y, @intCast(src.w), @intCast(src.h), dst.x, dst.y, @intCast(dst.w), @intCast(dst.h));
    }
    _ = X.XSync(ctx.disp, 0);
    c.g_mutex_unlock(&ctx.lock);
}

fn options(_: [*c]c.GstBufferPool) callconv(.c) [*c][*c]const c.gchar {
    const S = struct {
        var list = [_][*c]const c.gchar{ c.GST_BUFFER_POOL_OPTION_VIDEO_META, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT, null };
    };
    return &S.list;
}

fn setConfig(bp: [*c]c.GstBufferPool, config: ?*c.GstStructure) callconv(.c) c.gboolean {
    const xp: *Pool = @ptrCast(@alignCast(bp));
    var caps: ?*c.GstCaps = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    if (c.gst_buffer_pool_config_get_params(config, &caps, &size, &min, &max) == 0) return 0;
    if (caps == null) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    xp.im_format = ctxm.formatFromInfo(xp.allocator.context, &info);
    if (xp.im_format == -1) return 0;
    if (xp.caps != null) c.gst_caps_unref(xp.caps);
    xp.caps = c.gst_caps_ref(caps);
    xp.add_metavideo = c.gst_buffer_pool_config_has_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_META);
    xp.need_alignment = c.gst_buffer_pool_config_has_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT);
    if (xp.need_alignment != 0) {
        _ = c.gst_buffer_pool_config_get_video_alignment(config, &xp.@"align");
        _ = c.gst_video_info_align(&info, &xp.@"align");
        c.gst_buffer_pool_config_set_video_alignment(config, &xp.@"align");
        xp.add_metavideo = 1;
    } else c.gst_video_alignment_reset(&xp.@"align");
    xp.padded_width = @as(c.guint, @intCast(info.width)) + xp.@"align".padding_left + xp.@"align".padding_right;
    xp.padded_height = @as(c.guint, @intCast(info.height)) + xp.@"align".padding_top + xp.@"align".padding_bottom;
    xp.info = info;
    xp.crop = .{ .x = @intCast(xp.@"align".padding_left), .y = @intCast(xp.@"align".padding_top), .w = info.width, .h = info.height };
    if (xp.pre_alloc_mem != null) c.gst_memory_unref(xp.pre_alloc_mem);
    var err: [*c]c.GError = null;
    xp.pre_alloc_mem = alloc(xp.allocator, xp.im_format, &info, @intCast(xp.padded_width), @intCast(xp.padded_height), &xp.crop, &err);
    if (xp.pre_alloc_mem == null) {
        c.gst_debug_log(pool_cat, c.GST_LEVEL_ERROR, "../sys/xvimage/xvimagepool.c", "xvimage_buffer_pool_set_config", 141, @ptrCast(bp), "Couldn't allocate image: %s", err[0].message);
        c.g_error_free(err);
        return 0;
    }
    const img = @as(*Memory, @ptrCast(@alignCast(xp.pre_alloc_mem))).xvimage;
    info.size = @intCast(img[0].data_size);
    for (0..@intCast(img[0].num_planes)) |i| {
        info.stride[i] = img[0].pitches[i];
        info.offset[i] = @intCast(img[0].offsets[i]);
    }
    if (c.gst_video_info_is_equal(&xp.info, &info) == 0 or xp.info.size != info.size) xp.info = info;
    c.gst_buffer_pool_config_set_params(config, caps, @intCast(info.size), min, max);
    return parent_pool.set_config.?(bp, config);
}

fn allocBuffer(bp: [*c]c.GstBufferPool, out: [*c][*c]c.GstBuffer, _: [*c]c.GstBufferPoolAcquireParams) callconv(.c) c.GstFlowReturn {
    const xp: *Pool = @ptrCast(@alignCast(bp));
    const info = &xp.info;
    const b = c.gst_buffer_new();
    var mem: ?*c.GstMemory = null;
    var err: [*c]c.GError = null;
    if (xp.pre_alloc_mem != null) {
        mem = xp.pre_alloc_mem;
        xp.pre_alloc_mem = null;
    } else mem = alloc(xp.allocator, xp.im_format, info, @intCast(xp.padded_width), @intCast(xp.padded_height), &xp.crop, &err);
    const m = mem orelse {
        c.gst_buffer_unref(b);
        c.g_clear_error(&err);
        return c.GST_FLOW_ERROR;
    };
    c.gst_buffer_append_memory(b, m);
    if (xp.add_metavideo != 0) {
        const meta = c.gst_buffer_add_video_meta_full(b, c.GST_VIDEO_FRAME_FLAG_NONE, info.finfo[0].format, @intCast(info.width), @intCast(info.height), info.finfo[0].n_planes, &info.offset, &info.stride);
        _ = c.gst_video_meta_set_alignment(meta, xp.@"align");
    }
    out[0] = b;
    return c.GST_FLOW_OK;
}

fn poolFinalize(o: [*c]c.GObject) callconv(.c) void {
    const xp: *Pool = @ptrCast(@alignCast(o));
    if (xp.pre_alloc_mem != null) c.gst_memory_unref(xp.pre_alloc_mem);
    if (xp.caps != null) c.gst_caps_unref(xp.caps);
    c.gst_object_unref(xp.allocator);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(parent_pool));
    oc.finalize.?(o);
}

fn poolClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_pool = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = poolFinalize;
    const pc: *c.GstBufferPoolClass = @ptrCast(@alignCast(k));
    pc.get_options = options;
    pc.set_config = setConfig;
    pc.alloc_buffer = allocBuffer;
}

fn poolType() c.GType {
    return pool_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_buffer_pool_get_type(), "GstXvImageBufferPool", PoolClass, Pool, poolClassInit, null);
        }
    }.f);
}

pub fn newPool(a: *Allocator) *c.GstBufferPool {
    const xp: *Pool = @ptrCast(@alignCast(c.g_object_new(poolType(), null)));
    _ = c.gst_object_ref_sink(xp);
    xp.allocator = @ptrCast(@alignCast(c.gst_object_ref(a)));
    return &xp.pool;
}
