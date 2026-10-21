const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const pool = @import("pool.zig");
const meta = @import("meta.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const MASK: c.guint = 256 - 1;

const Self = extern struct {
    parent: c.GstVideoBufferPool,
    context: ?*c.GMainContext,
    loop: ?*c.GMainLoop,
    thread: ?*c.GThread,
};

const Class = extern struct {
    parent_class: c.GstVideoBufferPoolClass,
};

const BPClass = c.GstBufferPoolClass;

var once: gtype.Once = .{};
var parent: ?*BPClass = null;

fn of(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn lock(p: anytype) void {
    c.g_mutex_lock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn unlock(p: anytype) void {
    c.g_mutex_unlock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

const Source = extern struct {
    base: c.GSource,
    pool: *Self,
    buffer: [*c]c.GstBuffer,
    fds: [4]c.gint,
    tags: [4]c.gpointer,
};

fn readable(fd: c.gint) bool {
    var p = c.GPollFD{ .fd = fd, .events = c.G_IO_IN, .revents = 0 };
    if (c.g_poll(&p, 1, 0) == 0) return false;
    return p.revents & (c.G_IO_IN | c.G_IO_NVAL) != 0;
}

fn syncFile(fd: c.gint) c.gint {
    var s = c.struct_dma_buf_export_sync_file{ .flags = c.DMA_BUF_SYNC_WRITE, .fd = -1 };
    while (true) {
        const r = c.ioctl(fd, c.DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &s);
        if (r == -1 and std.c._errno().* == c.EINTR) continue;
        return if (r == 0) s.fd else -1;
    }
}

fn releaseParent(p: *Self, buf: [*c]c.GstBuffer) void {
    parent.?.release_buffer.?(@ptrCast(p), buf);
}

fn dispatch(base: [*c]c.GSource, _: c.GSourceFunc, _: c.gpointer) callconv(.c) c.gboolean {
    const s: *Source = @ptrCast(@alignCast(base));
    var ready = true;
    for (0..4) |i| {
        if (s.tags[i] == null) continue;
        if (!readable(s.fds[i])) {
            ready = false;
            continue;
        }
        _ = c.close(s.fds[i]);
        c.g_source_remove_unix_fd(base, s.tags[i]);
        s.tags[i] = null;
    }
    if (!ready) return 1;
    releaseParent(s.pool, s.buffer);
    c.g_source_unref(base);
    return 0;
}

fn finalize(base: [*c]c.GSource) callconv(.c) void {
    const s: *Source = @ptrCast(@alignCast(base));
    var need = false;
    for (0..4) |i| {
        if (s.tags[i] == null) continue;
        _ = c.close(s.fds[i]);
        c.g_source_remove_unix_fd(base, s.tags[i]);
        s.tags[i] = null;
        need = true;
    }
    if (need) releaseParent(s.pool, s.buffer);
}

var funcs = c.GSourceFuncs{ .prepare = null, .check = null, .dispatch = dispatch, .finalize = finalize, .closure_callback = null, .closure_marshal = null };

fn thread(data: c.gpointer) callconv(.c) c.gpointer {
    const p = of(data);
    lock(p);
    var context: ?*c.GMainContext = null;
    var loop: ?*c.GMainLoop = null;
    if (p.context) |x| context = c.g_main_context_ref(x);
    if (p.loop) |x| loop = c.g_main_loop_ref(x);
    if (context == null or loop == null) {
        if (loop) |x| c.g_main_loop_unref(x);
        if (context) |x| c.g_main_context_unref(x);
        unlock(p);
        return null;
    }
    unlock(p);
    c.g_main_context_push_thread_default(context);
    c.g_main_loop_run(loop);
    c.g_main_loop_unref(loop);
    c.g_main_context_unref(context);
    c.gst_object_unref(p);
    return null;
}

fn start(bp: [*c]c.GstBufferPool) callconv(.c) c.gboolean {
    const p = of(bp);
    lock(p);
    p.context = c.g_main_context_new();
    p.loop = c.g_main_loop_new(p.context, 0);
    p.thread = c.g_thread_new("video-dmabuf-pool-source-loop", thread, c.g_object_ref(p));
    unlock(p);
    return parent.?.start.?(bp);
}

fn quit(data: c.gpointer) callconv(.c) c.gboolean {
    c.g_main_loop_quit(@ptrCast(data));
    return 0;
}

fn stop(bp: [*c]c.GstBufferPool) callconv(.c) c.gboolean {
    const p = of(bp);
    lock(p);
    const context = p.context;
    const loop = p.loop;
    p.context = null;
    p.loop = null;
    unlock(p);
    if (context == null or loop == null) {
        if (loop) |x| c.g_main_loop_unref(x);
        if (context) |x| c.g_main_context_unref(x);
    } else {
        const idle = c.g_idle_source_new();
        c.g_source_set_callback(idle, quit, loop, null);
        _ = c.g_source_attach(idle, context);
        c.g_source_unref(idle);
        _ = c.g_thread_join(p.thread);
        p.thread = null;
        c.g_main_loop_unref(loop);
        c.g_main_context_unref(context);
    }
    return parent.?.stop.?(bp);
}

fn release(bp: [*c]c.GstBufferPool, buffer: [*c]c.GstBuffer) callconv(.c) void {
    const p = of(bp);
    var src: ?*Source = null;
    const n = c.gst_buffer_n_memory(buffer);
    for (0..n) |i| {
        const mem = c.gst_buffer_peek_memory(buffer, @intCast(i));
        if (c.gst_is_dmabuf_memory(mem) == 0) continue;
        const sf = syncFile(c.gst_dmabuf_memory_get_fd(mem));
        if (sf == -1) continue;
        if (readable(sf)) {
            _ = c.close(sf);
            continue;
        }
        if (src == null) {
            src = @ptrCast(@alignCast(c.g_source_new(&funcs, @sizeOf(Source))));
            src.?.pool = p;
            src.?.buffer = buffer;
        }
        src.?.fds[i] = sf;
        src.?.tags[i] = c.g_source_add_unix_fd(&src.?.base, sf, c.G_IO_IN);
    }
    if (src) |s| {
        _ = c.g_source_attach(&s.base, p.context);
        return;
    }
    releaseParent(p, buffer);
}

fn setConfig(bp: [*c]c.GstBufferPool, config: [*c]c.GstStructure) callconv(.c) c.gboolean {
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    var updated = false;
    _ = c.gst_buffer_pool_config_get_allocator(config, &allocator, &params);
    const is_dmabuf = allocator != null and gtype.instanceOf(allocator, c.gst_dmabuf_allocator_get_type());
    const custom = allocator != null and @as(*c.GstObject, @ptrCast(@alignCast(allocator))).flags & c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC != 0;
    if (!is_dmabuf or custom) {
        const u = c.gst_udmabuf_allocator_get();
        if (u == null) return 0;
        params.@"align" |= MASK;
        c.gst_buffer_pool_config_set_allocator(config, u, &params);
        c.gst_object_unref(u);
        updated = true;
    } else if (params.@"align" < MASK) {
        params.@"align" |= MASK;
        c.gst_buffer_pool_config_set_allocator(config, allocator, &params);
        updated = true;
    }
    if (c.gst_buffer_pool_config_has_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_META) == 0) return 0;
    if (c.gst_buffer_pool_config_has_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT) == 0) return 0;
    var va = std.mem.zeroes(c.GstVideoAlignment);
    _ = meta.gst_buffer_pool_config_get_video_alignment(config, &va);
    var aligned = false;
    for (0..4) |i| {
        if (va.stride_align[i] < MASK) {
            va.stride_align[i] |= MASK;
            aligned = true;
        }
    }
    if (aligned) {
        meta.gst_buffer_pool_config_set_video_alignment(config, &va);
        updated = true;
    }
    const res = parent.?.set_config.?(bp, config);
    if (updated) return 0;
    return res;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const pc: *BPClass = @ptrCast(@alignCast(k));
    pc.start = start;
    pc.stop = stop;
    pc.release_buffer = release;
    pc.set_config = setConfig;
}

pub export fn gst_video_dmabuf_pool_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(pool.gst_video_buffer_pool_get_type, "GstVideoDmabufPool", Class, Self, classInit, null, 0);
            _ = c._gst_debug_category_new("video-dmabuf-pool", 0, "video dmabuf pool");
            return t;
        }
    }.f);
}

pub export fn gst_video_dmabuf_pool_new() [*c]c.GstBufferPool {
    return @ptrCast(@alignCast(c.g_object_new(gst_video_dmabuf_pool_get_type(), null)));
}
