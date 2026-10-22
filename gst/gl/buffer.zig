const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const base = @import("basememory.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Buf = c.GstGLBuffer;
const OBuf = [*c]Buf;
const OBase = [*c]c.GstGLBaseMemory;
const OCtx = [*c]c.GstGLContext;
const Params = c.GstGLBufferAllocationParams;
const OParams = [*c]Params;

const NAME = "GLBuffer";
const MAP_READ_BIT = 0x0001;
const MAP_WRITE_BIT = 0x0002;
const MAP_FLUSH_EXPLICIT_BIT = 0x0010;
const MAP_PERSISTENT_BIT = 0x0040;
const DYNAMIC_STORAGE_BIT = 0x0100;
const CLIENT_STORAGE_BIT = 0x0200;
const COPY_READ_BUFFER = 0x8F36;
const COPY_WRITE_BUFFER = 0x8F37;
const NEED_DOWNLOAD: c.guint = c.GST_GL_BASE_MEMORY_TRANSFER_NEED_DOWNLOAD;
const NEED_UPLOAD: c.guint = c.GST_GL_BASE_MEMORY_TRANSFER_NEED_UPLOAD;

var alloc_once: gtype.Once = .{};
var mem_once: gtype.Once = .{};
var params_once: gtype.Once = .{};
var init_done: usize = 0;
var default_allocator: ?*c.GstAllocator = null;

fn storage(m: OBuf) bool {
    return m[0].mem.context[0].gl_vtable[0].BufferStorage != null;
}

fn flagSet(m: OBuf, f: c.guint) bool {
    return m[0].mem.mem.mini_object.flags & f != 0;
}

fn create(b: OBase, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const m: OBuf = @ptrCast(@alignCast(b));
    const gl = &m[0].mem.context[0].gl_vtable[0];
    gl.GenBuffers.?(1, &m[0].id);
    gl.BindBuffer.?(m[0].target, m[0].id);
    const size: c.GLsizeiptr = @bitCast(m[0].mem.mem.maxsize);
    if (storage(m)) {
        var flags: c.GLbitfield = MAP_READ_BIT | MAP_WRITE_BIT | MAP_PERSISTENT_BIT | DYNAMIC_STORAGE_BIT;
        if (m[0].usage_hints == c.GL_STREAM_DRAW) flags |= CLIENT_STORAGE_BIT;
        gl.BufferStorage.?(m[0].target, size, null, flags);
    } else {
        gl.BufferData.?(m[0].target, size, null, m[0].usage_hints);
    }
    gl.BindBuffer.?(m[0].target, 0);
    return 1;
}

fn newBuffer(allocator: [*c]c.GstAllocator, parent: [*c]c.GstMemory, ctx: OCtx, target: c.guint, usage: c.guint, params: [*c]const c.GstAllocationParams, size: c.gsize) OBuf {
    const m: OBuf = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Buf))));
    m[0].target = target;
    m[0].usage_hints = usage;
    base.gst_gl_base_memory_init(@ptrCast(m), allocator, parent, ctx, params, size, null, null);
    return m;
}

fn mapFlags(f: c.GstMapFlags) c.GLbitfield {
    var r: c.GLbitfield = 0;
    if (f & c.GST_MAP_READ != 0) r |= MAP_READ_BIT;
    if (f & c.GST_MAP_WRITE != 0) r |= MAP_WRITE_BIT;
    return r;
}

fn cpuAccess(m: OBuf, info: [*c]c.GstMapInfo, size: c.gsize) c.gpointer {
    const gl = &m[0].mem.context[0].gl_vtable[0];
    const len: c.GLsizeiptr = @bitCast(size);
    if (storage(m)) {
        var f = mapFlags(info[0].flags) | MAP_PERSISTENT_BIT;
        if (info[0].flags & c.GST_MAP_WRITE != 0) f |= MAP_FLUSH_EXPLICIT_BIT;
        if (m[0].mem.map_count == m[0].mem.gl_map_count + 1) {
            gl.BindBuffer.?(m[0].target, m[0].id);
            m[0].mem.data = @ptrCast(gl.MapBufferRange.?(m[0].target, 0, len, f));
            gl.BindBuffer.?(m[0].target, 0);
        }
        return m[0].mem.data;
    }
    if (base.gst_gl_base_memory_alloc_data(@ptrCast(m)) == 0) return null;
    var r: c.gpointer = m[0].mem.data;
    if (flagSet(m, NEED_DOWNLOAD) and info[0].flags & c.GST_MAP_GL == 0 and info[0].flags & c.GST_MAP_READ != 0) {
        gl.BindBuffer.?(m[0].target, m[0].id);
        if (gl.MapBufferRange) |mbr| {
            const d = mbr(m[0].target, 0, len, MAP_READ_BIT);
            if (d != null) @memcpy(@as([*]u8, @ptrCast(m[0].mem.data))[0..size], @as([*]const u8, @ptrCast(d))[0..size]);
            _ = gl.UnmapBuffer.?(m[0].target);
            r = m[0].mem.data;
        } else if (gl.GetBufferSubData) |gbs| {
            gbs(m[0].target, 0, len, m[0].mem.data);
            r = m[0].mem.data;
        } else r = null;
        gl.BindBuffer.?(m[0].target, 0);
    }
    return r;
}

fn uploadCpuWrite(m: OBuf, size: c.gsize) void {
    const gl = &m[0].mem.context[0].gl_vtable[0];
    if (m[0].mem.data == null) return;
    if (storage(m)) return;
    if (flagSet(m, NEED_UPLOAD) or m[0].mem.map_flags & c.GST_MAP_WRITE != 0) {
        const len: c.GLsizeiptr = @bitCast(size);
        gl.BindBuffer.?(m[0].target, m[0].id);
        if (gl.MapBufferRange) |mbr| {
            const d = mbr(m[0].target, 0, len, MAP_WRITE_BIT);
            if (d != null) @memcpy(@as([*]u8, @ptrCast(d))[0..size], @as([*]const u8, @ptrCast(m[0].mem.data))[0..size]);
            _ = gl.UnmapBuffer.?(m[0].target);
        } else if (gl.BufferSubData) |bsd| {
            bsd(m[0].target, 0, len, m[0].mem.data);
        }
        gl.BindBuffer.?(m[0].target, 0);
    }
}

fn map(b: OBase, info: [*c]c.GstMapInfo, size: c.gsize) callconv(.c) c.gpointer {
    const m: OBuf = @ptrCast(@alignCast(b));
    if (info[0].flags & c.GST_MAP_GL != 0) {
        if (info[0].flags & c.GST_MAP_READ != 0) uploadCpuWrite(m, size);
        m[0].mem.context[0].gl_vtable[0].BindBuffer.?(m[0].target, m[0].id);
        return &m[0].id;
    }
    return cpuAccess(m, info, size);
}

fn unmap(b: OBase, info: [*c]c.GstMapInfo) callconv(.c) void {
    const m: OBuf = @ptrCast(@alignCast(b));
    const gl = &m[0].mem.context[0].gl_vtable[0];
    if (storage(m) and info[0].flags & c.GST_MAP_GL == 0) {
        gl.BindBuffer.?(m[0].target, m[0].id);
        if (info[0].flags & c.GST_MAP_WRITE != 0) gl.FlushMappedBufferRange.?(m[0].target, 0, @bitCast(info[0].maxsize));
        if (m[0].mem.map_count == m[0].mem.gl_map_count + 1) _ = gl.UnmapBuffer.?(m[0].target);
        gl.BindBuffer.?(m[0].target, 0);
    }
    if (info[0].flags & c.GST_MAP_GL != 0) gl.BindBuffer.?(m[0].target, 0);
}

fn copySubData(src: OBuf, dest: OBuf, offset: c.gssize, size: c.gssize) bool {
    const gl = &src[0].mem.context[0].gl_vtable[0];
    const cbs = gl.CopyBufferSubData orelse return false;
    var si: c.GstMapInfo = undefined;
    var di: c.GstMapInfo = undefined;
    if (c.gst_memory_map(@ptrCast(src), &si, c.GST_MAP_READ | c.GST_MAP_GL) == 0) return false;
    if (c.gst_memory_map(@ptrCast(dest), &di, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) {
        c.gst_memory_unmap(@ptrCast(src), &si);
        return false;
    }
    gl.BindBuffer.?(COPY_READ_BUFFER, src[0].id);
    gl.BindBuffer.?(COPY_WRITE_BUFFER, dest[0].id);
    cbs(COPY_READ_BUFFER, COPY_WRITE_BUFFER, offset, 0, size);
    c.gst_memory_unmap(@ptrCast(src), &si);
    c.gst_memory_unmap(@ptrCast(dest), &di);
    return true;
}

fn copy(b: OBase, offset: c.gssize, size: c.gssize) callconv(.c) OBase {
    const src: OBuf = @ptrCast(@alignCast(b));
    var params = c.GstAllocationParams{ .flags = 0, .@"align" = src[0].mem.mem.@"align", .prefix = 0, .padding = 0, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    const dest = newBuffer(src[0].mem.mem.allocator, null, src[0].mem.context, src[0].target, src[0].usage_hints, &params, src[0].mem.mem.maxsize);
    if (!flagSet(src, NEED_UPLOAD) and copySubData(src, dest, offset, size)) return @ptrCast(dest);
    if (base.gst_gl_base_memory_memcpy(@ptrCast(src), @ptrCast(dest), offset, size) == 0) {
        c.gst_memory_unref(@ptrCast(dest));
        return null;
    }
    return @ptrCast(dest);
}

fn plainAlloc(_: [*c]c.GstAllocator, _: c.gsize, _: [*c]c.GstAllocationParams) callconv(.c) [*c]c.GstMemory {
    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Need to use gst_gl_base_memory_alloc() to allocate from this allocator");
    return null;
}

fn destroy(b: OBase) callconv(.c) void {
    const m: OBuf = @ptrCast(@alignCast(b));
    m[0].mem.context[0].gl_vtable[0].DeleteBuffers.?(1, &m[0].id);
}

fn copyData(src: OParams, dest: OParams) callconv(.c) void {
    dest[0] = std.mem.zeroes(Params);
    base.gst_gl_allocation_params_copy_data(&src[0].parent, &dest[0].parent);
    dest[0].gl_target = src[0].gl_target;
    dest[0].gl_usage = src[0].gl_usage;
}

fn freeData(p: OParams) callconv(.c) void {
    base.gst_gl_allocation_params_free_data(&p[0].parent);
}

pub export fn gst_gl_buffer_allocation_params_get_type() c.GType {
    return params_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLBufferAllocationParams", @ptrCast(&base.gst_gl_allocation_params_copy), @ptrCast(&base.gst_gl_allocation_params_free));
        }
    }.f);
}

pub export fn gst_gl_buffer_allocation_params_new(ctx: OCtx, size: c.gsize, alloc_params: [*c]const c.GstAllocationParams, target: c.guint, usage: c.guint) OParams {
    const fname = "gst_gl_buffer_allocation_params_new";
    if (!check.that(context.isContext(ctx), fname, "GST_IS_GL_CONTEXT (context)")) return null;
    if (!check.that(size > 0, fname, "alloc_size > 0")) return null;
    const p: OParams = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Params))));
    if (base.gst_gl_allocation_params_init(&p[0].parent, @sizeOf(Params), c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_BUFFER | c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_ALLOC, @ptrCast(&copyData), @ptrCast(&freeData), ctx, size, alloc_params, null, null, null, null) == 0) {
        c.g_free(p);
        return null;
    }
    p[0].gl_target = target;
    p[0].gl_usage = usage;
    return p;
}

fn allocMem(allocator: [*c]c.GstGLBaseMemoryAllocator, bp: [*c]c.GstGLAllocationParams) callconv(.c) OBase {
    const p: OParams = @ptrCast(@alignCast(bp));
    const flags = p[0].parent.alloc_flags;
    if (!check.that(flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_BUFFER != 0, "_gl_buffer_alloc_mem", "alloc_flags & GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_BUFFER")) return null;
    if (!check.that(flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_ALLOC != 0, "_gl_buffer_alloc_mem", "alloc_flags & GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_ALLOC")) return null;
    return @ptrCast(newBuffer(@ptrCast(allocator), null, p[0].parent.context, p[0].gl_target, p[0].gl_usage, p[0].parent.alloc_params, p[0].parent.alloc_size));
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const bk: *c.GstGLBaseMemoryAllocatorClass = @ptrCast(@alignCast(k));
    bk.alloc = allocMem;
    bk.create = create;
    bk.map = map;
    bk.unmap = unmap;
    bk.copy = copy;
    bk.destroy = destroy;
    @as(*c.GstAllocatorClass, @ptrCast(@alignCast(k))).alloc = plainAlloc;
}

fn allocInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *c.GstAllocator = @ptrCast(@alignCast(inst));
    a.mem_type = NAME;
    a.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

pub export fn gst_gl_buffer_allocator_get_type() c.GType {
    return alloc_once.get(struct {
        fn f() c.GType {
            return gtype.object(base.gst_gl_base_memory_allocator_get_type, "GstGLBufferAllocator", c.GstGLBufferAllocatorClass, c.GstGLBufferAllocator, classInit, allocInit, 0);
        }
    }.f);
}

pub export fn gst_gl_buffer_get_type() c.GType {
    return mem_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLBuffer", @ptrCast(&c.gst_mini_object_ref), @ptrCast(&c.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_gl_buffer_init_once() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        base.gst_gl_base_memory_init_once();
        _ = c._gst_debug_category_new("glbuffer", 0, "OpenGL Buffer");
        default_allocator = @ptrCast(@alignCast(c.g_object_new(gst_gl_buffer_allocator_get_type(), @as([*c]const u8, null))));
        _ = c.gst_object_ref_sink(default_allocator);
        default_allocator.?.object.flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
        c.gst_allocator_register(NAME, @ptrCast(@alignCast(c.gst_object_ref(default_allocator))));
        c.g_once_init_leave(&init_done, 1);
    }
}

pub export fn gst_is_gl_buffer(mem: [*c]c.GstMemory) c.gboolean {
    return @intFromBool(mem != null and mem[0].allocator != null and c.g_type_is_a(gtype.typeOf(mem[0].allocator), gst_gl_buffer_allocator_get_type()) != 0);
}
