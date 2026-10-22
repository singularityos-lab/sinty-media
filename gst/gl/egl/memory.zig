const std = @import("std");
const c = @import("../../c.zig").c;
const check = @import("../check.zig");
const gtype = @import("../../gtype.zig");
const context = @import("../context.zig");
const memory = @import("../memory.zig");
const format = @import("../format.zig");
const image = @import("image.zig");
const egl_context = @import("context.zig");

comptime {
    @import("../../abi.zig").check(@This());
}

const Mem = c.GstGLMemoryEGL;
const OMem = [*c]Mem;
const OBase = [*c]c.GstGLBaseMemory;
const NAME = "GLMemoryEGL";

var alloc_once: gtype.Once = .{};
var mem_once: gtype.Once = .{};
var init_done: usize = 0;
var default_allocator: ?*c.GstAllocator = null;
var parent: ?*c.GstGLBaseMemoryAllocatorClass = null;

pub export fn gst_is_gl_memory_egl(mem: [*c]c.GstMemory) c.gboolean {
    return @intFromBool(mem != null and mem[0].allocator != null and c.g_type_is_a(gtype.typeOf(mem[0].allocator), gst_gl_memory_egl_allocator_get_type()) != 0);
}

fn root(m: OMem) OMem {
    const p: OMem = @ptrCast(@alignCast(m[0].mem.mem.mem.parent));
    return if (p != null) p else m;
}

pub export fn gst_gl_memory_egl_get_image(m: OMem) c.gpointer {
    if (!check.that(gst_is_gl_memory_egl(@ptrCast(m)) != 0, "gst_gl_memory_egl_get_image", "gst_is_gl_memory_egl (GST_MEMORY_CAST (mem))")) return null;
    return image.gst_egl_image_get_image(root(m)[0].image);
}

pub export fn gst_gl_memory_egl_get_display(m: OMem) c.gpointer {
    if (!check.that(gst_is_gl_memory_egl(@ptrCast(m)) != 0, "gst_gl_memory_egl_get_display", "gst_is_gl_memory_egl (GST_MEMORY_CAST (mem))")) return null;
    const e: *egl_context.Egl = @ptrCast(@alignCast(root(m)[0].mem.mem.context));
    return e.egl_display;
}

fn plainAlloc(_: [*c]c.GstAllocator, _: c.gsize, _: [*c]c.GstAllocationParams) callconv(.c) [*c]c.GstMemory {
    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Use gst_gl_base_memory_allocator_alloc() to allocate from this GstGLMemoryEGL allocator");
    return null;
}

fn destroy(b: OBase) callconv(.c) void {
    const m: OMem = @ptrCast(@alignCast(b));
    if (m[0].image != null) c.gst_mini_object_unref(@ptrCast(m[0].image));
    parent.?.destroy.?(b);
}

fn isImage(p: c.gpointer) bool {
    const o: [*c]c.GstMiniObject = @ptrCast(@alignCast(p));
    return o != null and o[0].type == image.gst_egl_image_get_type();
}

fn eglAlloc(allocator: [*c]c.GstGLBaseMemoryAllocator, bp: [*c]c.GstGLAllocationParams) callconv(.c) OBase {
    const fname = "_gl_mem_egl_alloc";
    const p: [*c]c.GstGLVideoAllocationParams = @ptrCast(@alignCast(bp));
    const flags = p[0].parent.alloc_flags;
    if (!check.that(flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO != 0, fname, "alloc_flags & GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO")) return null;
    if (!check.that(flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM == 0, fname, "(alloc_flags & GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM) == 0")) return null;
    const wrap = flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE != 0;
    if (wrap and !check.that(isImage(p[0].parent.gl_handle), fname, "GST_IS_EGL_IMAGE (params->parent.gl_handle)")) return null;
    const m: OMem = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Mem))));
    if (wrap) {
        if (p[0].target != c.GST_GL_TEXTURE_TARGET_2D and p[0].target != c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) {
            c.g_free(m);
            return null;
        }
        m[0].mem.tex_target = p[0].target;
        m[0].image = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(@alignCast(p[0].parent.gl_handle)))));
    }
    memory.gst_gl_memory_init(@ptrCast(m), @ptrCast(allocator), null, p[0].parent.context, p[0].target, p[0].tex_format, p[0].parent.alloc_params, p[0].v_info, p[0].plane, p[0].valign, p[0].parent.user_data, p[0].parent.notify);
    if (m[0].image == null) {
        c.gst_allocator_free(@ptrCast(allocator), @ptrCast(m));
        return null;
    }
    return @ptrCast(m);
}

fn create(b: OBase, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const m: OMem = @ptrCast(@alignCast(b));
    const ctx = m[0].mem.mem.context;
    const gl = &ctx[0].gl_vtable[0];
    const q = context.gst_gl_context_error_quark();
    if (context.gst_gl_context_check_feature(ctx, "EGL_KHR_image_base") == 0) {
        c.g_set_error(err, q, c.GST_GL_CONTEXT_ERROR_WRONG_API, "EGL_KHR_image_base is not supported");
        return 0;
    }
    if (parent.?.create.?(b, err) == 0) return 0;
    if (m[0].image == null) {
        m[0].image = image.gst_egl_image_from_texture(ctx, @ptrCast(m), null);
        if (m[0].image == null) {
            c.g_set_error(err, q, c.GST_GL_CONTEXT_ERROR_FAILED, "Failed to create EGLImage");
            return 0;
        }
        return 1;
    }
    const target = format.gst_gl_texture_target_to_gl(m[0].mem.tex_target);
    const f = gl.EGLImageTargetTexture2D orelse {
        c.g_set_error(err, q, c.GST_GL_CONTEXT_ERROR_FAILED, "Required function glEGLImageTargetTexture2D() is not available for attaching an EGLImage to a texture");
        return 0;
    };
    gl.ActiveTexture.?(@as(c.GLenum, c.GL_TEXTURE0) + m[0].mem.plane);
    gl.BindTexture.?(target, m[0].mem.tex_id);
    f(target, image.gst_egl_image_get_image(m[0].image));
    return 1;
}

fn copy(_: OBase, _: c.gssize, _: c.gssize) callconv(.c) OBase {
    return null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const bk: *c.GstGLBaseMemoryAllocatorClass = @ptrCast(@alignCast(k));
    bk.alloc = eglAlloc;
    bk.create = create;
    bk.destroy = destroy;
    @as(*c.GstGLMemoryAllocatorClass, @ptrCast(@alignCast(k))).copy = copy;
    @as(*c.GstAllocatorClass, @ptrCast(@alignCast(k))).alloc = plainAlloc;
}

fn allocInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *c.GstAllocator = @ptrCast(@alignCast(inst));
    a.mem_type = NAME;
    a.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

pub export fn gst_gl_memory_egl_allocator_get_type() c.GType {
    return alloc_once.get(struct {
        fn f() c.GType {
            return gtype.object(memory.gst_gl_memory_allocator_get_type, "GstGLMemoryEGLAllocator", c.GstGLMemoryEGLAllocatorClass, c.GstGLMemoryEGLAllocator, classInit, allocInit, 0);
        }
    }.f);
}

pub export fn gst_gl_memory_egl_get_type() c.GType {
    return mem_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLMemoryEGL", @ptrCast(&c.gst_mini_object_ref), @ptrCast(&c.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_gl_memory_egl_init_once() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        memory.gst_gl_memory_init_once();
        _ = c._gst_debug_category_new("glmemory", 0, "OpenGL Texture with EGLImage memory");
        default_allocator = @ptrCast(@alignCast(c.g_object_new(gst_gl_memory_egl_allocator_get_type(), @as([*c]const u8, null))));
        _ = c.gst_object_ref_sink(default_allocator);
        default_allocator.?.object.flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
        c.gst_allocator_register(NAME, @ptrCast(@alignCast(c.gst_object_ref(default_allocator))));
        c.g_once_init_leave(&init_done, 1);
    }
}
