const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Mem = c.GstGLBaseMemory;
const OMem = [*c]Mem;
const Alloc = c.GstGLBaseMemoryAllocator;
const AllocClass = c.GstGLBaseMemoryAllocatorClass;
const OCtx = [*c]c.GstGLContext;

const NEED_DOWNLOAD: c.guint = c.GST_GL_BASE_MEMORY_TRANSFER_NEED_DOWNLOAD;
const NEED_UPLOAD: c.guint = c.GST_GL_BASE_MEMORY_TRANSFER_NEED_UPLOAD;
const MAP_GL: c.guint = c.GST_MAP_GL;

var mem_once: gtype.Once = .{};
var alloc_once: gtype.Once = .{};
var params_once: gtype.Once = .{};
var init_done: usize = 0;
pub var cat: ?*c.GstDebugCategory = null;

pub fn klass(m: anytype) *AllocClass {
    return gtype.classPeek(AllocClass, @as(OMem, @ptrCast(@alignCast(m)))[0].mem.allocator);
}

fn setFlag(m: OMem, f: c.guint) void {
    m[0].mem.mini_object.flags |= f;
}

fn unsetFlag(m: OMem, f: c.guint) void {
    m[0].mem.mini_object.flags &= ~f;
}

pub export fn gst_gl_base_memory_get_type() c.GType {
    return mem_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLBaseMemory", @ptrCast(&c.gst_mini_object_ref), @ptrCast(&c.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_gl_base_memory_error_quark() c.GQuark {
    return c.g_quark_from_static_string("gst-gl-base-memory-error-quark");
}

fn defaultCreate(_: OMem, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    c.g_set_error(err, gst_gl_base_memory_error_quark(), c.GST_GL_BASE_MEMORY_ERROR_FAILED, "subclass should define create() vfunc");
    c.g_log(null, c.G_LOG_LEVEL_CRITICAL, "subclass should override GstGLBaseMemoryAllocatorClass::create() function");
    return 0;
}

const Create = struct {
    mem: OMem,
    ok: c.gboolean,
};

fn createGl(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const t: *Create = @ptrCast(@alignCast(data));
    const k = klass(t.mem);
    if (!check.that(k.create != null, "_mem_create_gl", "alloc_class->create != NULL")) return;
    t.mem[0].query = null;
    if (context.debugEnabled()) t.mem[0].query = c.gst_gl_query_new(ctx, c.GST_GL_QUERY_TIME_ELAPSED);
    var e: [*c]c.GError = null;
    t.ok = k.create.?(t.mem, &e);
    if (t.ok != 0) return;
    if (e == null) check.assertFail("gstglbasememory.c", 116, "_mem_create_gl", "error != NULL");
    c.g_clear_error(&e);
}

pub export fn gst_gl_base_memory_init(mem: OMem, allocator: [*c]c.GstAllocator, parent: [*c]c.GstMemory, ctx: OCtx, params: [*c]const c.GstAllocationParams, size: c.gsize, user_data: c.gpointer, notify: c.GDestroyNotify) void {
    var align_: c.gsize = c.gst_memory_alignment;
    var offset: c.gsize = 0;
    var maxsize = size;
    var flags: c.GstMemoryFlags = 0;
    mem[0].alloc_size = size;
    if (params != null) {
        flags = params[0].flags;
        align_ |= params[0].@"align";
        offset = params[0].prefix;
        maxsize += params[0].prefix + params[0].padding;
        mem[0].alloc_size = maxsize + align_;
    }
    c.gst_memory_init(@ptrCast(mem), flags, allocator, parent, maxsize, align_, offset, size);
    mem[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    mem[0].notify = notify;
    mem[0].user_data = user_data;
    c.g_mutex_init(&mem[0].lock);
    var d = Create{ .mem = mem, .ok = 0 };
    c.gst_gl_context_thread_add(ctx, createGl, &d);
}

pub export fn gst_gl_base_memory_alloc_data(m: OMem) c.gboolean {
    if (m[0].data != null) return 1;
    m[0].alloc_data = c.g_try_malloc(m[0].alloc_size);
    if (m[0].alloc_data == null) return 0;
    const a = m[0].mem.@"align";
    var p = @intFromPtr(m[0].alloc_data);
    const off = p & a;
    if (off != 0) p += (a + 1) - off;
    m[0].data = @ptrFromInt(p);
    return 1;
}

const MapData = struct {
    mem: OMem,
    info: [*c]c.GstMapInfo,
    size: c.gsize,
    data: c.gpointer,
};

fn mapGl(_: OCtx, data: c.gpointer) callconv(.c) void {
    const t: *MapData = @ptrCast(@alignCast(data));
    const m = t.mem;
    const k = klass(m);
    if (!check.that(k.map != null, "_map_data_gl", "alloc_class->map != NULL")) return;
    c.g_mutex_lock(&m[0].lock);
    defer c.g_mutex_unlock(&m[0].lock);
    const flags = t.info[0].flags;
    const prev_flags = m[0].map_flags;
    const prev_gl = m[0].gl_map_count;
    const first = m[0].map_count == 0;
    m[0].map_count += 1;
    if (first) {
        m[0].map_flags = flags;
    } else if (((MAP_GL - 1) & flags) & m[0].map_flags == 0) {
        check.assertFail("gstglbasememory.c", 222, "_map_data_gl", "(((GST_MAP_GL - 1) & info->flags) & mem->map_flags) != 0");
    }
    if (flags & MAP_GL != m[0].map_flags & MAP_GL) m[0].map_flags |= MAP_GL;
    if (flags & MAP_GL != 0) m[0].gl_map_count += 1;
    t.data = k.map.?(m, t.info, t.size);
    if (t.data != null) {
        if (flags & MAP_GL != 0) {
            if (flags & c.GST_MAP_WRITE != 0) setFlag(m, NEED_DOWNLOAD);
            unsetFlag(m, NEED_UPLOAD);
        } else {
            if (flags & c.GST_MAP_WRITE != 0) setFlag(m, NEED_UPLOAD);
            unsetFlag(m, NEED_DOWNLOAD);
        }
    } else {
        m[0].map_flags = prev_flags;
        m[0].gl_map_count = prev_gl;
        m[0].map_count -= 1;
    }
}

fn mapFull(mem: [*c]c.GstMemory, info: [*c]c.GstMapInfo, size: c.gsize) callconv(.c) c.gpointer {
    const m: OMem = @ptrCast(@alignCast(mem));
    var t = MapData{ .mem = m, .info = info, .size = size, .data = null };
    c.gst_gl_context_thread_add(m[0].context, mapGl, &t);
    return t.data;
}

const UnmapData = struct {
    mem: OMem,
    info: [*c]c.GstMapInfo,
};

fn unmapGl(_: OCtx, data: c.gpointer) callconv(.c) void {
    const t: *UnmapData = @ptrCast(@alignCast(data));
    const m = t.mem;
    const k = klass(m);
    if (!check.that(k.unmap != null, "_unmap_data_gl", "alloc_class->unmap != NULL")) return;
    c.g_mutex_lock(&m[0].lock);
    defer c.g_mutex_unlock(&m[0].lock);
    const flags = t.info[0].flags;
    k.unmap.?(m, t.info);
    if (flags & MAP_GL != 0) {
        m[0].gl_map_count -%= 1;
        if (m[0].gl_map_count != 0) m[0].map_flags &= ~MAP_GL;
    }
    m[0].map_count -= 1;
    if (m[0].map_count <= 0) m[0].map_flags = 0;
    if (flags & c.GST_MAP_WRITE != 0) setFlag(m, if (flags & MAP_GL != 0) NEED_DOWNLOAD else NEED_UPLOAD);
}

fn unmapFull(mem: [*c]c.GstMemory, info: [*c]c.GstMapInfo) callconv(.c) void {
    const m: OMem = @ptrCast(@alignCast(mem));
    var t = UnmapData{ .mem = m, .info = info };
    c.gst_gl_context_thread_add(m[0].context, unmapGl, &t);
}

fn defaultCopy(_: OMem, _: c.gssize, _: c.gssize) callconv(.c) OMem {
    return null;
}

const CopyData = struct {
    src: OMem,
    dest: OMem,
    offset: c.gssize,
    size: c.gssize,
};

fn copyGl(_: OCtx, data: c.gpointer) callconv(.c) void {
    const t: *CopyData = @ptrCast(@alignCast(data));
    const k = klass(t.src);
    if (!check.that(k.copy != null, "_mem_copy_gl", "alloc_class->copy != NULL")) return;
    t.dest = k.copy.?(t.src, t.offset, t.size);
}

fn memCopy(mem: [*c]c.GstMemory, offset: c.gssize, size: c.gssize) callconv(.c) [*c]c.GstMemory {
    const m: OMem = @ptrCast(@alignCast(mem));
    var t = CopyData{ .src = m, .dest = null, .offset = offset, .size = size };
    if (size == -1 or size > 0) c.gst_gl_context_thread_add(m[0].context, copyGl, &t);
    return @ptrCast(t.dest);
}

fn memShare(_: [*c]c.GstMemory, _: c.gssize, _: c.gssize) callconv(.c) [*c]c.GstMemory {
    return null;
}

fn memIsSpan(_: [*c]c.GstMemory, _: [*c]c.GstMemory, _: [*c]c.gsize) callconv(.c) c.gboolean {
    return 0;
}

fn memAlloc(_: [*c]c.GstAllocator, _: c.gsize, _: [*c]c.GstAllocationParams) callconv(.c) [*c]c.GstMemory {
    c.g_log(null, c.G_LOG_LEVEL_CRITICAL, "Subclass should override GstAllocatorClass::alloc() function");
    return null;
}

fn defaultDestroy(_: OMem) callconv(.c) void {}

fn destroyGl(_: OCtx, data: c.gpointer) callconv(.c) void {
    const m: OMem = @ptrCast(@alignCast(data));
    const k = klass(m);
    if (!check.that(k.destroy != null, "_destroy_gl_objects", "alloc_class->destroy != NULL")) return;
    k.destroy.?(m);
    if (m[0].query != null) c.gst_gl_query_free(m[0].query);
}

fn memFree(_: [*c]c.GstAllocator, memory: [*c]c.GstMemory) callconv(.c) void {
    const m: OMem = @ptrCast(@alignCast(memory));
    c.gst_gl_context_thread_add(m[0].context, destroyGl, m);
    c.g_mutex_clear(&m[0].lock);
    if (m[0].alloc_data != null) {
        c.g_free(m[0].alloc_data);
        m[0].alloc_data = null;
    }
    m[0].data = null;
    if (m[0].notify) |n| n(m[0].user_data);
    c.gst_object_unref(m[0].context);
    c.g_free(memory);
}

pub export fn gst_gl_base_memory_init_once() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        cat = c._gst_debug_category_new("glbasememory", 0, "OpenGL BaseMemory");
        c.g_once_init_leave(&init_done, 1);
    }
}

fn allocClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ac: *c.GstAllocatorClass = @ptrCast(@alignCast(k));
    ac.alloc = memAlloc;
    ac.free = memFree;
    const bc: *AllocClass = @ptrCast(@alignCast(k));
    bc.create = defaultCreate;
    bc.copy = defaultCopy;
    bc.destroy = defaultDestroy;
}

fn allocInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *Alloc = @ptrCast(@alignCast(inst));
    const al = &a.parent;
    a.fallback_mem_copy = al.mem_copy;
    al.mem_map_full = mapFull;
    al.mem_unmap_full = unmapFull;
    al.mem_copy = memCopy;
    al.mem_share = memShare;
    al.mem_is_span = memIsSpan;
}

pub export fn gst_gl_base_memory_allocator_get_type() c.GType {
    return alloc_once.get(struct {
        fn f() c.GType {
            return gtype.object(c.gst_allocator_get_type, "GstGLBaseMemoryAllocator", AllocClass, Alloc, allocClassInit, allocInit, c.G_TYPE_FLAG_ABSTRACT);
        }
    }.f);
}

pub export fn gst_is_gl_base_memory(mem: [*c]c.GstMemory) c.gboolean {
    return @intFromBool(mem != null and mem[0].allocator != null and c.g_type_is_a(gtype.typeOf(mem[0].allocator), gst_gl_base_memory_allocator_get_type()) != 0);
}

pub export fn gst_gl_base_memory_memcpy(src: OMem, dest: OMem, offset: c.gssize, size_in: c.gssize) c.gboolean {
    if (gst_gl_base_memory_alloc_data(dest) == 0) return 0;
    var si: c.GstMapInfo = undefined;
    var di: c.GstMapInfo = undefined;
    if (c.gst_memory_map(@ptrCast(src), &si, c.GST_MAP_READ) == 0) return 0;
    if (c.gst_memory_map(@ptrCast(dest), &di, c.GST_MAP_WRITE) == 0) {
        c.gst_memory_unmap(@ptrCast(src), &si);
        return 0;
    }
    var size = size_in;
    if (size == -1) size = if (@as(c.gssize, @bitCast(si.size)) > offset) @as(c.gssize, @bitCast(si.size)) - offset else 0;
    const n: usize = @bitCast(size);
    const o: usize = @bitCast(offset);
    @memcpy(@as([*]u8, @ptrCast(di.data))[0..n], @as([*]const u8, @ptrCast(si.data))[o .. o + n]);
    c.gst_memory_unmap(@ptrCast(dest), &di);
    c.gst_memory_unmap(@ptrCast(src), &si);
    return 1;
}

pub export fn gst_gl_allocation_params_init(params: [*c]c.GstGLAllocationParams, struct_size: c.gsize, alloc_flags: c.guint, copy: c.GstGLAllocationParamsCopyFunc, free: c.GstGLAllocationParamsFreeFunc, ctx: OCtx, alloc_size: c.gsize, alloc_params: [*c]const c.GstAllocationParams, wrapped_data: c.gpointer, gl_handle: c.gpointer, user_data: c.gpointer, notify: c.GDestroyNotify) c.gboolean {
    const fname = "gst_gl_allocation_params_init";
    params[0] = std.mem.zeroes(c.GstGLAllocationParams);
    if (!check.that(struct_size > 0, fname, "struct_size > 0")) return 0;
    if (!check.that(copy != null, fname, "copy != NULL")) return 0;
    if (!check.that(free != null, fname, "free != NULL")) return 0;
    if (!check.that(context.isContext(ctx), fname, "GST_IS_GL_CONTEXT (context)")) return 0;
    params[0].struct_size = struct_size;
    params[0].alloc_size = alloc_size;
    params[0].copy = copy;
    params[0].free = free;
    params[0].alloc_flags = alloc_flags;
    params[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    if (alloc_params != null) params[0].alloc_params = c.gst_allocation_params_copy(alloc_params);
    params[0].notify = notify;
    params[0].user_data = user_data;
    params[0].wrapped_data = wrapped_data;
    params[0].gl_handle = gl_handle;
    return 1;
}

pub export fn gst_gl_allocation_params_copy(src: [*c]c.GstGLAllocationParams) [*c]c.GstGLAllocationParams {
    if (!check.that(src != null, "gst_gl_allocation_params_copy", "src != NULL")) return null;
    const dest: [*c]c.GstGLAllocationParams = @ptrCast(@alignCast(c.g_malloc0(src[0].struct_size)));
    if (src[0].copy) |f| f(src, dest);
    return dest;
}

pub export fn gst_gl_allocation_params_free(params: [*c]c.GstGLAllocationParams) void {
    if (params[0].free) |f| f(params);
    c.g_free(params);
}

pub export fn gst_gl_allocation_params_free_data(params: [*c]c.GstGLAllocationParams) void {
    if (params[0].context != null) c.gst_object_unref(params[0].context);
    if (params[0].alloc_params != null) c.gst_allocation_params_free(params[0].alloc_params);
}

pub export fn gst_gl_allocation_params_copy_data(src: [*c]c.GstGLAllocationParams, dest: [*c]c.GstGLAllocationParams) void {
    _ = gst_gl_allocation_params_init(dest, src[0].struct_size, src[0].alloc_flags, src[0].copy, src[0].free, src[0].context, src[0].alloc_size, null, src[0].wrapped_data, src[0].gl_handle, src[0].user_data, src[0].notify);
    if (src[0].alloc_params != null) dest[0].alloc_params = c.gst_allocation_params_copy(src[0].alloc_params);
}

pub export fn gst_gl_allocation_params_get_type() c.GType {
    return params_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLAllocationParams", @ptrCast(&gst_gl_allocation_params_copy), @ptrCast(&gst_gl_allocation_params_free));
        }
    }.f);
}

pub export fn gst_gl_base_memory_alloc(allocator: [*c]Alloc, params: [*c]c.GstGLAllocationParams) OMem {
    const fname = "gst_gl_base_memory_alloc";
    if (!check.that(gtype.instanceOf(allocator, gst_gl_base_memory_allocator_get_type()), fname, "GST_IS_GL_BASE_MEMORY_ALLOCATOR (allocator)")) return null;
    const k = gtype.classPeek(AllocClass, allocator);
    if (!check.that(k.alloc != null, fname, "alloc_class->alloc != NULL")) return null;
    return k.alloc.?(allocator, params);
}
