const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const base = @import("basememory.zig");
const format = @import("format.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Rb = c.GstGLRenderbuffer;
const ORb = [*c]Rb;
const OBase = [*c]c.GstGLBaseMemory;
const OCtx = [*c]c.GstGLContext;
const Params = c.GstGLRenderbufferAllocationParams;
const OParams = [*c]Params;

const NAME = "GLRenderbuffer";

var alloc_once: gtype.Once = .{};
var mem_once: gtype.Once = .{};
var params_once: gtype.Once = .{};
var init_done: usize = 0;
var default_allocator: ?*c.GstAllocator = null;

fn create(b: OBase, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const m: ORb = @ptrCast(@alignCast(b));
    if (m[0].renderbuffer_wrapped != 0) return 1;
    const ctx = m[0].mem.context;
    var tf: c.guint = m[0].renderbuffer_format;
    var t: c.guint = c.GL_UNSIGNED_BYTE;
    if (m[0].renderbuffer_format == c.GST_GL_RGB565) {
        tf = c.GST_GL_RGB;
        t = c.GL_UNSIGNED_SHORT_5_6_5;
    }
    const internal = format.gst_gl_sized_gl_format_from_gl_format_type(ctx, tf, t);
    const gl = &ctx[0].gl_vtable[0];
    var id: c.GLuint = 0;
    gl.GenRenderbuffers.?(1, &id);
    gl.BindRenderbuffer.?(c.GL_RENDERBUFFER, id);
    gl.RenderbufferStorage.?(c.GL_RENDERBUFFER, internal, gst_gl_renderbuffer_get_width(m), gst_gl_renderbuffer_get_height(m));
    gl.BindRenderbuffer.?(c.GL_RENDERBUFFER, 0);
    m[0].renderbuffer_id = id;
    return 1;
}

fn rbInit(m: ORb, allocator: [*c]c.GstAllocator, parent: [*c]c.GstMemory, ctx: OCtx, fmt: c.GstGLFormat, params: [*c]const c.GstAllocationParams, w: c.guint, h: c.guint, user_data: c.gpointer, notify: c.GDestroyNotify) void {
    const t: c.guint = if (fmt == c.GST_GL_RGB565) c.GL_UNSIGNED_SHORT_5_6_5 else c.GL_UNSIGNED_BYTE;
    const size: c.gsize = @as(c.gsize, format.gst_gl_format_type_n_bytes(fmt, t)) * w * h;
    m[0].renderbuffer_format = fmt;
    m[0].width = w;
    m[0].height = h;
    base.gst_gl_base_memory_init(@ptrCast(m), allocator, parent, ctx, params, size, user_data, notify);
}

fn map(_: [*c]c.GstMemory, _: [*c]c.GstMapInfo, _: c.gsize) callconv(.c) c.gpointer {
    return null;
}

fn unmap(_: [*c]c.GstMemory, _: [*c]c.GstMapInfo) callconv(.c) void {}

fn copy(_: [*c]c.GstMemory, _: c.gssize, _: c.gssize) callconv(.c) [*c]c.GstMemory {
    return null;
}

fn plainAlloc(_: [*c]c.GstAllocator, _: c.gsize, _: [*c]c.GstAllocationParams) callconv(.c) [*c]c.GstMemory {
    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Use gst_gl_base_memory_alloc to allocate from this allocator");
    return null;
}

fn destroy(b: OBase) callconv(.c) void {
    const m: ORb = @ptrCast(@alignCast(b));
    if (m[0].renderbuffer_id != 0 and m[0].renderbuffer_wrapped == 0) m[0].mem.context[0].gl_vtable[0].DeleteRenderbuffers.?(1, &m[0].renderbuffer_id);
}

fn defaultAlloc(allocator: [*c]c.GstGLBaseMemoryAllocator, bp: [*c]c.GstGLAllocationParams) callconv(.c) OBase {
    const p: OParams = @ptrCast(@alignCast(bp));
    const flags = p[0].parent.alloc_flags;
    if (!check.that(flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM == 0, "_default_gl_rbo_alloc", "(alloc_flags & GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM) == 0")) return null;
    const m: ORb = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Rb))));
    if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE != 0) {
        m[0].renderbuffer_id = @truncate(@intFromPtr(p[0].parent.gl_handle));
        m[0].renderbuffer_wrapped = 1;
    }
    rbInit(m, @ptrCast(allocator), null, p[0].parent.context, p[0].renderbuffer_format, p[0].parent.alloc_params, p[0].width, p[0].height, p[0].parent.user_data, p[0].parent.notify);
    return @ptrCast(m);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const bk: *c.GstGLBaseMemoryAllocatorClass = @ptrCast(@alignCast(k));
    bk.alloc = defaultAlloc;
    bk.create = create;
    bk.destroy = destroy;
    @as(*c.GstAllocatorClass, @ptrCast(@alignCast(k))).alloc = plainAlloc;
}

fn allocInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *c.GstAllocator = @ptrCast(@alignCast(inst));
    a.mem_type = NAME;
    a.mem_map_full = map;
    a.mem_unmap_full = unmap;
    a.mem_copy = copy;
    a.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

pub export fn gst_gl_renderbuffer_allocator_get_type() c.GType {
    return alloc_once.get(struct {
        fn f() c.GType {
            return gtype.object(base.gst_gl_base_memory_allocator_get_type, "GstGLRenderbufferAllocator", c.GstGLRenderbufferAllocatorClass, c.GstGLRenderbufferAllocator, classInit, allocInit, 0);
        }
    }.f);
}

pub export fn gst_gl_renderbuffer_get_type() c.GType {
    return mem_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLRenderbuffer", @ptrCast(&c.gst_mini_object_ref), @ptrCast(&c.gst_mini_object_unref));
        }
    }.f);
}

fn validRb(m: ORb, comptime fname: []const u8) bool {
    return check.that(gst_is_gl_renderbuffer(@ptrCast(m)) != 0, fname, "gst_is_gl_renderbuffer ((GstMemory *) gl_mem)");
}

pub export fn gst_gl_renderbuffer_get_width(m: ORb) c.gint {
    if (!validRb(m, "gst_gl_renderbuffer_get_width")) return 0;
    return @bitCast(m[0].width);
}

pub export fn gst_gl_renderbuffer_get_height(m: ORb) c.gint {
    if (!validRb(m, "gst_gl_renderbuffer_get_height")) return 0;
    return @bitCast(m[0].height);
}

pub export fn gst_gl_renderbuffer_get_format(m: ORb) c.GstGLFormat {
    if (!validRb(m, "gst_gl_renderbuffer_get_format")) return 0;
    return m[0].renderbuffer_format;
}

pub export fn gst_gl_renderbuffer_get_id(m: ORb) c.guint {
    if (!validRb(m, "gst_gl_renderbuffer_get_id")) return 0;
    return m[0].renderbuffer_id;
}

pub export fn gst_gl_renderbuffer_init_once() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        base.gst_gl_base_memory_init_once();
        _ = c._gst_debug_category_new("glrenderbuffermemory", 0, "OpenGL Renderbuffer memory");
        default_allocator = @ptrCast(@alignCast(c.g_object_new(gst_gl_renderbuffer_allocator_get_type(), @as([*c]const u8, null))));
        _ = c.gst_object_ref_sink(default_allocator);
        default_allocator.?.object.flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
        c.gst_allocator_register(NAME, default_allocator);
        c.g_once_init_leave(&init_done, 1);
    }
}

pub export fn gst_is_gl_renderbuffer(mem: [*c]c.GstMemory) c.gboolean {
    return @intFromBool(mem != null and mem[0].allocator != null and c.g_type_is_a(gtype.typeOf(mem[0].allocator), gst_gl_renderbuffer_allocator_get_type()) != 0);
}

pub export fn gst_gl_renderbuffer_allocation_params_get_type() c.GType {
    return params_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLRenderbufferAllocationParams", @ptrCast(&base.gst_gl_allocation_params_copy), @ptrCast(&base.gst_gl_allocation_params_free));
        }
    }.f);
}

fn freeData(p: OParams) callconv(.c) void {
    base.gst_gl_allocation_params_free_data(&p[0].parent);
}

fn copyData(src: OParams, dest: OParams) callconv(.c) void {
    base.gst_gl_allocation_params_copy_data(&src[0].parent, &dest[0].parent);
    dest[0].renderbuffer_format = src[0].renderbuffer_format;
    dest[0].width = src[0].width;
    dest[0].height = src[0].height;
}

fn newParams(ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, fmt: c.GstGLFormat, w: c.guint, h: c.guint, flags: c.guint, handle: c.gpointer, user_data: c.gpointer, notify: c.GDestroyNotify) OParams {
    const p: OParams = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Params))));
    if (!check.that(context.isContext(ctx), "_gst_gl_renderbuffer_allocation_params_init_full", "GST_IS_GL_CONTEXT (context)")) {
        c.g_free(p);
        return null;
    }
    p[0] = std.mem.zeroes(Params);
    if (base.gst_gl_allocation_params_init(@ptrCast(p), @sizeOf(Params), flags | c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO, @ptrCast(&copyData), @ptrCast(&freeData), ctx, 0, alloc_params, null, handle, user_data, notify) == 0) {
        c.g_free(p);
        return null;
    }
    p[0].renderbuffer_format = fmt;
    p[0].width = w;
    p[0].height = h;
    return p;
}

pub export fn gst_gl_renderbuffer_allocation_params_new(ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, fmt: c.GstGLFormat, w: c.guint, h: c.guint) OParams {
    return newParams(ctx, alloc_params, fmt, w, h, c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_ALLOC, null, null, null);
}

pub export fn gst_gl_renderbuffer_allocation_params_new_wrapped(ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, fmt: c.GstGLFormat, w: c.guint, h: c.guint, handle: c.gpointer, user_data: c.gpointer, notify: c.GDestroyNotify) OParams {
    return newParams(ctx, alloc_params, fmt, w, h, c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE, handle, user_data, notify);
}
