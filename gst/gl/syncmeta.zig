const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const context = @import("context.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Sync = c.GstGLSyncMeta;
const OSync = [*c]Sync;
const OCtx = [*c]c.GstGLContext;
const OBuf = [*c]c.GstBuffer;

const GPU_COMMANDS_COMPLETE = 0x9117;
const FLUSH_COMMANDS_BIT = 0x1;
const TIMEOUT_EXPIRED = 0x911B;
const TIMEOUT_IGNORED: u64 = 0xFFFFFFFFFFFFFFFF;

var api_type: usize = 0;
var info: usize = 0;
var debug_done: usize = 0;
var tags = [_][*c]const u8{null};

fn vt(ctx: OCtx) *c.GstGLFuncs {
    return @ptrCast(ctx[0].gl_vtable);
}

fn setSyncGl(m: OSync, ctx: OCtx) callconv(.c) void {
    const gl = vt(ctx);
    if (gl.FenceSync) |fence| {
        if (m[0].data != null) gl.DeleteSync.?(@ptrCast(m[0].data));
        m[0].data = @ptrCast(fence(GPU_COMMANDS_COMPLETE, 0));
    }
    if (context.gst_gl_context_is_shared(ctx) != 0) gl.Flush.?();
}

fn waitGl(m: OSync, ctx: OCtx) callconv(.c) void {
    const gl = vt(ctx);
    if (m[0].data != null) {
        if (gl.WaitSync) |w| w(@ptrCast(m[0].data), 0, TIMEOUT_IGNORED);
    }
}

fn waitCpuGl(m: OSync, ctx: OCtx) callconv(.c) void {
    const gl = vt(ctx);
    if (m[0].data != null and gl.ClientWaitSync != null) {
        while (gl.ClientWaitSync.?(@ptrCast(m[0].data), FLUSH_COMMANDS_BIT, 1000000000) == TIMEOUT_EXPIRED) {}
    } else {
        gl.Finish.?();
    }
}

fn defaultCopy(src: OSync, _: OBuf, _: OSync, _: OBuf) callconv(.c) void {
    gst_gl_sync_meta_set_sync_point(src, src[0].context);
}

fn freeGl(m: OSync, ctx: OCtx) callconv(.c) void {
    if (m[0].data != null) {
        vt(ctx).DeleteSync.?(@ptrCast(m[0].data));
        m[0].data = null;
    }
}

pub export fn gst_buffer_add_gl_sync_meta_full(ctx: OCtx, buf: OBuf, data: c.gpointer) OSync {
    if (!check.that(context.isContext(ctx), "gst_buffer_add_gl_sync_meta_full", "GST_IS_GL_CONTEXT (context)")) return null;
    const m: OSync = @ptrCast(@alignCast(c.gst_buffer_add_meta(buf, gst_gl_sync_meta_get_info(), null)));
    if (m == null) return null;
    m[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    m[0].data = data;
    return m;
}

pub export fn gst_buffer_add_gl_sync_meta(ctx: OCtx, buf: OBuf) OSync {
    const m = gst_buffer_add_gl_sync_meta_full(ctx, buf, null);
    if (m == null) return null;
    m[0].set_sync_gl = setSyncGl;
    m[0].wait_gl = waitGl;
    m[0].wait_cpu_gl = waitCpuGl;
    m[0].copy = defaultCopy;
    m[0].free_gl = freeGl;
    return m;
}

fn need(ok: bool, line: c_int, comptime func: []const u8, comptime expr: [*:0]const u8) void {
    if (!ok) check.assertFail("gstglsyncmeta.c", line, func, expr);
}

fn setSyncPoint(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const m: OSync = @ptrCast(@alignCast(data));
    need(m[0].set_sync_gl != null, 179, "_set_sync_point", "sync_meta->set_sync_gl != NULL");
    m[0].set_sync_gl.?(m, ctx);
}

pub export fn gst_gl_sync_meta_set_sync_point(m: OSync, ctx: OCtx) void {
    if (m[0].set_sync) |f| f(m, ctx) else c.gst_gl_context_thread_add(ctx, setSyncPoint, m);
}

fn waitCb(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const m: OSync = @ptrCast(@alignCast(data));
    need(m[0].wait_gl != null, 207, "_wait", "sync_meta->wait_gl != NULL");
    m[0].wait_gl.?(m, ctx);
}

pub export fn gst_gl_sync_meta_wait(m: OSync, ctx: OCtx) void {
    if (m[0].wait) |f| f(m, ctx) else c.gst_gl_context_thread_add(ctx, waitCb, m);
}

fn waitCpuCb(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const m: OSync = @ptrCast(@alignCast(data));
    need(m[0].wait_cpu_gl != null, 236, "_wait_cpu", "sync_meta->wait_cpu_gl != NULL");
    m[0].wait_cpu_gl.?(m, ctx);
}

pub export fn gst_gl_sync_meta_wait_cpu(m: OSync, ctx: OCtx) void {
    if (m[0].wait_cpu) |f| f(m, ctx) else c.gst_gl_context_thread_add(ctx, waitCpuCb, m);
}

fn transform(dest: OBuf, meta: [*c]c.GstMeta, buf: OBuf, t: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const s: OSync = @ptrCast(@alignCast(meta));
    if (t != c._gst_meta_transform_copy) return 0;
    const copy: *c.GstMetaTransformCopy = @ptrCast(@alignCast(data));
    need(s[0].copy != null, 276, "_gst_gl_sync_meta_transform", "smeta->copy != NULL");
    if (copy.region != 0) return 1;
    const d = gst_buffer_add_gl_sync_meta_full(s[0].context, dest, null);
    if (d == null) return 0;
    d[0].set_sync = s[0].set_sync;
    d[0].set_sync_gl = s[0].set_sync_gl;
    d[0].wait = s[0].wait;
    d[0].wait_gl = s[0].wait_gl;
    d[0].wait_cpu = s[0].wait_cpu;
    d[0].wait_cpu_gl = s[0].wait_cpu_gl;
    d[0].copy = s[0].copy;
    d[0].free = s[0].free;
    d[0].free_gl = s[0].free_gl;
    s[0].copy.?(s, buf, d, dest);
    return 1;
}

fn freeCb(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const m: OSync = @ptrCast(@alignCast(data));
    need(m[0].free_gl != null, 306, "_free_gl_sync_meta", "sync_meta->free_gl != NULL");
    m[0].free_gl.?(m, ctx);
}

fn metaFree(meta: [*c]c.GstMeta, _: OBuf) callconv(.c) void {
    const m: OSync = @ptrCast(@alignCast(meta));
    if (m[0].free) |f| f(m, m[0].context) else c.gst_gl_context_thread_add(m[0].context, freeCb, m);
    c.gst_object_unref(m[0].context);
}

fn metaInit(meta: [*c]c.GstMeta, _: c.gpointer, _: OBuf) callconv(.c) c.gboolean {
    if (c.g_once_init_enter(&debug_done) != 0) {
        _ = c._gst_debug_category_new("glsyncmeta", 0, "glsyncmeta");
        c.g_once_init_leave(&debug_done, 1);
    }
    const m: OSync = @ptrCast(@alignCast(meta));
    const keep = m[0].parent;
    m[0] = std.mem.zeroes(Sync);
    m[0].parent = keep;
    return 1;
}

pub export fn gst_gl_sync_meta_api_get_type() c.GType {
    if (c.g_once_init_enter(&api_type) != 0) {
        c.g_once_init_leave(&api_type, c.gst_meta_api_type_register("GstGLSyncMetaAPI", @ptrCast(&tags)));
    }
    return api_type;
}

pub export fn gst_gl_sync_meta_get_info() [*c]const c.GstMetaInfo {
    if (c.g_once_init_enter(&info) != 0) {
        c.g_once_init_leave(&info, @intFromPtr(c.gst_meta_register(gst_gl_sync_meta_api_get_type(), "GstGLSyncMeta", @sizeOf(Sync), metaInit, metaFree, transform)));
    }
    return @ptrFromInt(info);
}
