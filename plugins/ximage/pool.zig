const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const x = @import("x.zig");
const X = x.p;
const sink = @import("sink.zig");

const FILE = "../sys/ximage/ximagepool.c";

pub const Memory = extern struct {
    parent: c.GstMemory,
    sink: *sink.Self,
    ximage: [*c]X.XImage,
    shm: X.XShmSegmentInfo,
    x: c.gint,
    y: c.gint,
    width: c.gint,
    height: c.gint,
    size: usize,
};

pub const Pool = extern struct {
    pool: c.GstBufferPool,
    sink: *sink.Self,
    allocator: *c.GstAllocator,
    caps: [*c]c.GstCaps,
    info: c.GstVideoInfo,
    @"align": c.GstVideoAlignment,
    padded_width: c.guint,
    padded_height: c.guint,
    add_metavideo: c.gboolean,
    need_alignment: c.gboolean,
};

const PoolClass = extern struct {
    parent: c.GstBufferPoolClass,
};

pub var cat: ?*c.GstDebugCategory = null;
var caught = false;
var alloc_once: cm.Once = .{};
var pool_once: cm.Once = .{};
var parent_pool: *c.GstBufferPoolClass = undefined;

fn onError(_: ?*X.Display, _: [*c]X.XErrorEvent) callconv(.c) c_int {
    caught = true;
    return 0;
}

fn memAlloc(_: [*c]c.GstAllocator, _: usize, _: [*c]c.GstAllocationParams) callconv(.c) [*c]c.GstMemory {
    return null;
}

fn memFree(_: [*c]c.GstAllocator, g: [*c]c.GstMemory) callconv(.c) void {
    const m: *Memory = @ptrCast(@alignCast(g));
    if (g[0].parent != null) {
        c.g_free(m);
        return;
    }
    const s = m.sink;
    cm.lock(s);
    if (s.xcontext) |ctx| {
        c.g_mutex_lock(&s.x_lock);
        if (ctx.use_xshm != 0 and m.shm.shmaddr != @as([*c]u8, @ptrCast(x.NO_ADDR))) {
            _ = X.XShmDetach(ctx.disp, &m.shm);
            _ = X.XSync(ctx.disp, 0);
            _ = X.shmdt(m.shm.shmaddr);
            m.shm.shmaddr = @ptrCast(x.NO_ADDR);
        }
        if (m.ximage != null) x.destroyImage(m.ximage);
        _ = X.XSync(ctx.disp, 0);
        c.g_mutex_unlock(&s.x_lock);
    } else if (m.shm.shmaddr != @as([*c]u8, @ptrCast(x.NO_ADDR))) {
        _ = X.shmdt(m.shm.shmaddr);
    }
    cm.unlock(s);
    c.gst_object_unref(s);
    c.g_free(m);
}

fn memMap(m: *Memory, _: usize, _: c.GstMapFlags) callconv(.c) c.gpointer {
    return m.ximage[0].data + m.parent.offset;
}

fn memUnmap(_: *Memory) callconv(.c) c.gboolean {
    return 1;
}

fn memShare(m: *Memory, offset: isize, size: isize) callconv(.c) ?*Memory {
    if (offset != 0) return null;
    if (size != -1 and size != @as(isize, @intCast(m.size))) return null;
    const parent: *c.GstMemory = if (m.parent.parent != null) m.parent.parent else &m.parent;
    const n: usize = if (size == -1) m.parent.size else @intCast(size);
    const sub: *Memory = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Memory))));
    c.gst_memory_init(&sub.parent, parent.mini_object.flags | c.GST_MINI_OBJECT_FLAG_LOCK_READONLY, m.parent.allocator, &m.parent, m.parent.maxsize, m.parent.@"align", m.parent.offset, n);
    sub.sink = m.sink;
    sub.ximage = m.ximage;
    sub.shm = m.shm;
    sub.x = m.x;
    sub.y = m.y;
    sub.width = m.width;
    sub.height = m.height;
    sub.size = m.size;
    return sub;
}

fn allocClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ac: *c.GstAllocatorClass = @ptrCast(@alignCast(k));
    ac.alloc = memAlloc;
    ac.free = memFree;
}

fn allocInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *c.GstAllocator = @ptrCast(@alignCast(inst));
    a.mem_type = "ximage";
    a.mem_map = @ptrCast(&memMap);
    a.mem_unmap = @ptrCast(&memUnmap);
    a.mem_share = @ptrCast(&memShare);
    a.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

fn allocatorType() c.GType {
    return alloc_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_allocator_get_type(), "GstXImageMemoryAllocator", c.GstAllocatorClass, c.GstAllocator, allocClassInit, allocInit);
        }
    }.f);
}

fn failed(s: *sink.Self, w: c.gint, h: c.gint, dbg: [*c]u8, line: c.gint) void {
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf("Failed to create output image buffer of %dx%d pixels", w, h), dbg, FILE, "ximage_memory_alloc", line);
}

fn memNew(xp: *Pool) ?*Memory {
    const s = xp.sink;
    const ctx = s.xcontext.?;
    const w: c.gint = @intCast(xp.padded_width);
    const h: c.gint = @intCast(xp.padded_height);
    const m: *Memory = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Memory))));
    m.shm.shmaddr = @ptrCast(x.NO_ADDR);
    m.shm.shmid = -1;
    m.x = @intCast(xp.@"align".padding_left);
    m.y = @intCast(xp.@"align".padding_top);
    m.width = xp.info.width;
    m.height = xp.info.height;
    m.sink = @ptrCast(@alignCast(c.gst_object_ref(s)));
    c.g_mutex_lock(&s.x_lock);
    caught = false;
    const prev = X.XSetErrorHandler(onError);
    var al: usize = 0;
    var shm_ok = false;
    if (ctx.use_xshm != 0) {
        m.ximage = X.XShmCreateImage(ctx.disp, ctx.visual, @intCast(ctx.depth), X.ZPixmap, null, &m.shm, @intCast(w), @intCast(h));
        if (m.ximage == null or caught) {
            c.g_mutex_unlock(&s.x_lock);
            caught = false;
            cm.elementWarning(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, c.g_strdup_printf("Failed to create output image buffer of %dx%d pixels", w, h), c.g_strdup_printf("could not XShmCreateImage a %dx%d image", w, h), FILE, "ximage_memory_alloc", 258);
            ctx.use_xshm = 0;
            c.g_mutex_lock(&s.x_lock);
        } else {
            m.size = @intCast(m.ximage[0].bytes_per_line * m.ximage[0].height);
            m.shm.shmid = X.shmget(X.IPC_PRIVATE, m.size, X.IPC_CREAT | 0o777);
            if (m.shm.shmid == -1) {
                c.g_mutex_unlock(&s.x_lock);
                failed(s, w, h, c.g_strdup_printf("could not get shared memory of %" ++ c.G_GSIZE_FORMAT ++ " bytes", m.size), 387);
                return drop(m);
            }
            m.shm.shmaddr = @ptrCast(X.shmat(m.shm.shmid, null, 0));
            if (m.shm.shmaddr == @as([*c]u8, @ptrCast(x.NO_ADDR))) {
                c.g_mutex_unlock(&s.x_lock);
                failed(s, w, h, c.g_strdup_printf("Failed to shmat: %s", c.g_strerror(std.c._errno().*)), 397);
                _ = X.shmctl(m.shm.shmid, X.IPC_RMID, null);
                return drop(m);
            }
            m.ximage[0].data = m.shm.shmaddr;
            m.shm.readOnly = 0;
            if (X.XShmAttach(ctx.disp, &m.shm) == 0) {
                _ = X.shmctl(m.shm.shmid, X.IPC_RMID, null);
                c.g_mutex_unlock(&s.x_lock);
                failed(s, w, h, c.g_strdup("Failed to XShmAttach"), 410);
                return drop(m);
            }
            _ = X.XSync(ctx.disp, 0);
            _ = X.shmctl(m.shm.shmid, X.IPC_RMID, null);
            shm_ok = true;
        }
    }
    if (!shm_ok) {
        m.ximage = X.XCreateImage(ctx.disp, ctx.visual, @intCast(ctx.depth), X.ZPixmap, 0, null, @intCast(w), @intCast(h), ctx.bpp, 0);
        if (m.ximage == null or caught) {
            c.g_mutex_unlock(&s.x_lock);
            caught = false;
            _ = X.XSetErrorHandler(prev);
            failed(s, w, h, c.g_strdup_printf("could not XShmCreateImage a %dx%d image", w, h), 377);
            return drop(m);
        }
        m.size = @intCast(m.ximage[0].bytes_per_line * m.ximage[0].height);
        const stride: usize = @intCast(m.ximage[0].bytes_per_line);
        const total = ((stride + 3) & ~@as(usize, 3)) * @as(usize, @intCast(m.ximage[0].height));
        al = 15;
        m.ximage[0].data = @ptrCast(c.g_malloc(total + al));
        _ = X.XSync(ctx.disp, 0);
    }
    var off: usize = @intFromPtr(m.ximage[0].data) & al;
    if (off != 0) off = al + 1 - off;
    caught = false;
    _ = X.XSetErrorHandler(prev);
    c.gst_memory_init(&m.parent, c.GST_MEMORY_FLAG_NO_SHARE, xp.allocator, null, m.size + al, al, off, m.size);
    c.g_mutex_unlock(&s.x_lock);
    return m;
}

fn drop(m: *Memory) ?*Memory {
    c.g_free(m);
    return null;
}

pub fn checkXshm(ctx: *sink.Ctx) bool {
    var info: X.XShmSegmentInfo = undefined;
    _ = X.XSync(ctx.disp, 0);
    info.shmaddr = @ptrCast(x.NO_ADDR);
    info.shmid = -1;
    caught = false;
    const prev = X.XSetErrorHandler(onError);
    var ok = false;
    var attached = false;
    const img = X.XShmCreateImage(ctx.disp, ctx.visual, @intCast(ctx.depth), X.ZPixmap, null, &info, 1, 1);
    _ = X.XSync(ctx.disp, 0);
    blk: {
        if (img == null or caught) break :blk;
        const size: usize = @intCast(img[0].height * img[0].bytes_per_line);
        info.shmid = X.shmget(X.IPC_PRIVATE, size, X.IPC_CREAT | 0o777);
        if (info.shmid == -1) break :blk;
        info.shmaddr = @ptrCast(X.shmat(info.shmid, null, 0));
        if (info.shmaddr == @as([*c]u8, @ptrCast(x.NO_ADDR))) {
            _ = X.shmctl(info.shmid, X.IPC_RMID, null);
            break :blk;
        }
        img[0].data = info.shmaddr;
        info.readOnly = 0;
        if (X.XShmAttach(ctx.disp, &info) == 0) {
            _ = X.shmctl(info.shmid, X.IPC_RMID, null);
            break :blk;
        }
        _ = X.XSync(ctx.disp, 0);
        _ = X.shmctl(info.shmid, X.IPC_RMID, null);
        if (!caught) {
            attached = true;
            ok = true;
        }
    }
    _ = X.XSync(ctx.disp, 0);
    caught = false;
    _ = X.XSetErrorHandler(prev);
    if (attached) {
        _ = X.XShmDetach(ctx.disp, &info);
        _ = X.XSync(ctx.disp, 0);
    }
    if (info.shmaddr != @as([*c]u8, @ptrCast(x.NO_ADDR))) _ = X.shmdt(info.shmaddr);
    if (img != null) x.destroyImage(img);
    return ok;
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
    c.gst_buffer_pool_config_set_params(config, caps, @intCast(info.size), min, max);
    return parent_pool.set_config.?(bp, config);
}

fn allocBuffer(bp: [*c]c.GstBufferPool, out: [*c][*c]c.GstBuffer, _: [*c]c.GstBufferPoolAcquireParams) callconv(.c) c.GstFlowReturn {
    const xp: *Pool = @ptrCast(@alignCast(bp));
    const b = c.gst_buffer_new();
    const m = memNew(xp) orelse {
        c.gst_buffer_unref(b);
        return c.GST_FLOW_ERROR;
    };
    c.gst_buffer_append_memory(b, &m.parent);
    if (xp.add_metavideo != 0) {
        const info = &xp.info;
        const meta = c.gst_buffer_add_video_meta_full(b, c.GST_VIDEO_FRAME_FLAG_NONE, info.finfo[0].format, @intCast(info.width), @intCast(info.height), info.finfo[0].n_planes, &info.offset, &info.stride);
        _ = c.gst_video_meta_set_alignment(meta, xp.@"align");
    }
    out[0] = b;
    return c.GST_FLOW_OK;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const xp: *Pool = @ptrCast(@alignCast(o));
    if (xp.caps != null) c.gst_caps_unref(xp.caps);
    c.gst_object_unref(xp.sink);
    c.gst_object_unref(xp.allocator);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(parent_pool));
    oc.finalize.?(o);
}

fn poolClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_pool = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    const pc: *c.GstBufferPoolClass = @ptrCast(@alignCast(k));
    pc.get_options = options;
    pc.set_config = setConfig;
    pc.alloc_buffer = allocBuffer;
}

fn poolType() c.GType {
    return pool_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_buffer_pool_get_type(), "GstXImageBufferPool", PoolClass, Pool, poolClassInit, null);
        }
    }.f);
}

pub fn new(s: *sink.Self) *c.GstBufferPool {
    const xp: *Pool = @ptrCast(@alignCast(c.g_object_new(poolType(), null)));
    _ = c.gst_object_ref_sink(xp);
    xp.sink = @ptrCast(@alignCast(c.gst_object_ref(s)));
    xp.allocator = @ptrCast(@alignCast(c.g_object_new(allocatorType(), null)));
    _ = c.gst_object_ref_sink(xp.allocator);
    return &xp.pool;
}

pub fn isOurs(b: [*c]c.GstBuffer, s: *sink.Self) bool {
    if (c.gst_buffer_n_memory(b) != 1) return false;
    const g = c.gst_buffer_peek_memory(b, 0);
    if (g == null) return false;
    if (c.g_strcmp0(g[0].allocator[0].mem_type, "ximage") != 0) return false;
    const m: *Memory = @ptrCast(@alignCast(g));
    return m.sink == s;
}
