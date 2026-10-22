const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const base = @import("basememory.zig");
const memory = @import("memory.zig");
const buffer = @import("buffer.zig");
const format = @import("format.zig");
const utils = @import("utils.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Pbo = c.GstGLMemoryPBO;
const OPbo = [*c]Pbo;
const OBase = [*c]c.GstGLBaseMemory;
const OCtx = [*c]c.GstGLContext;

const NAME = "GLMemoryPBO";
const PIXEL_PACK_BUFFER = 0x88EB;
const PIXEL_UNPACK_BUFFER = 0x88EC;
const STREAM_DRAW = 0x88E0;
const NEED_DOWNLOAD: c.guint = c.GST_GL_BASE_MEMORY_TRANSFER_NEED_DOWNLOAD;
const NEED_UPLOAD: c.guint = c.GST_GL_BASE_MEMORY_TRANSFER_NEED_UPLOAD;

var alloc_once: gtype.Once = .{};
var mem_once: gtype.Once = .{};
var init_done: usize = 0;
var default_allocator: ?*c.GstAllocator = null;
var parent: ?*c.GstGLMemoryAllocatorClass = null;

const ver = context.gst_gl_context_check_gl_version;

fn canUpload(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3, 2, 1) != 0 or ver(ctx, c.GST_GL_API_GLES2, 3, 0) != 0;
}

fn canDownload(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2, 3, 0) != 0;
}

fn ctxOf(m: OPbo) OCtx {
    return m[0].mem.mem.context;
}

fn flagSet(m: anytype, f: c.guint) bool {
    return @as([*c]c.GstMiniObject, @ptrCast(@alignCast(m)))[0].flags & f != 0;
}

fn pboHeight(m: OPbo) c.guint {
    const info = &m[0].mem.info;
    if (info.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV == 0) return @bitCast(info.height);
    var h = info.height;
    if (info.interlace_mode == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) h = @divTrunc(h + 1, 2);
    return @bitCast(-((-h) >> @intCast(info.finfo[0].h_sub[m[0].mem.plane])));
}

fn pboStride(m: OPbo) c.guint {
    return @bitCast(m[0].mem.info.stride[m[0].mem.plane]);
}

fn baseParent() *c.GstGLBaseMemoryAllocatorClass {
    return @ptrCast(@alignCast(parent.?));
}

fn uploadPbo(m: OPbo, pinfo: *c.GstMapInfo) void {
    if (!flagSet(m, NEED_UPLOAD)) return;
    const ctx = ctxOf(m);
    if (!check.that(canUpload(ctx), "_upload_pbo_memory", "CONTEXT_SUPPORTS_PBO_UPLOAD (context)")) return;
    const gl = &ctx[0].gl_vtable[0];
    const id = @as(*const c.guint, @ptrCast(@alignCast(pinfo.data))).*;
    gl.BindBuffer.?(PIXEL_UNPACK_BUFFER, id);
    memory.gst_gl_memory_texsubimage(@ptrCast(m), null);
    gl.BindBuffer.?(PIXEL_UNPACK_BUFFER, 0);
}

fn create(b: OBase, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const m: OPbo = @ptrCast(@alignCast(b));
    const ctx = ctxOf(m);
    if (baseParent().create.?(b, err) == 0) return 0;
    if (!(canDownload(ctx) or canUpload(ctx))) return 1;
    var ap = c.GstAllocationParams{ .flags = 0, .@"align" = m[0].mem.mem.mem.@"align", .prefix = 0, .padding = 0, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    const ba: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(c.gst_allocator_find("GLBuffer")));
    const params = buffer.gst_gl_buffer_allocation_params_new(ctx, m[0].mem.mem.mem.size, &ap, PIXEL_UNPACK_BUFFER, STREAM_DRAW);
    m[0].pbo = @ptrCast(@alignCast(base.gst_gl_base_memory_alloc(ba, @ptrCast(params))));
    c.gst_object_unref(ba);
    if (flagSet(m, NEED_UPLOAD)) {
        m[0].pbo[0].mem.mem.mini_object.flags |= NEED_UPLOAD;
        m[0].pbo[0].mem.data = params[0].parent.wrapped_data;
        var pm: c.GstMapInfo = undefined;
        if (c.gst_memory_map(@ptrCast(m[0].pbo), &pm, c.GST_MAP_READWRITE) == 0) {
            base.gst_gl_allocation_params_free(@ptrCast(params));
            return 0;
        }
        if (pm.data != @as([*c]u8, @ptrCast(params[0].parent.wrapped_data))) {
            const n = m[0].mem.mem.mem.size;
            @memcpy(@as([*]u8, @ptrCast(pm.data))[0..n], @as([*]const u8, @ptrCast(m[0].mem.mem.data))[0..n]);
        }
        c.gst_memory_unmap(@ptrCast(m[0].pbo), &pm);
    }
    base.gst_gl_allocation_params_free(@ptrCast(params));
    return 1;
}

fn readToPbo(m: OPbo) bool {
    const ctx = ctxOf(m);
    if (m[0].pbo == null or !canDownload(ctx) or m[0].mem.tex_format == c.GST_GL_LUMINANCE or m[0].mem.tex_format == c.GST_GL_LUMINANCE_ALPHA) return false;
    if (flagSet(m, NEED_DOWNLOAD)) {
        const start = utils.gst_gl_get_plane_start(&m[0].mem.info, &m[0].mem.valign, m[0].mem.plane) + m[0].mem.mem.mem.offset;
        m[0].pbo[0].target = PIXEL_PACK_BUFFER;
        var pi: c.GstMapInfo = undefined;
        if (c.gst_memory_map(@ptrCast(m[0].pbo), &pi, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) return false;
        if (memory.gst_gl_memory_read_pixels(@ptrCast(m), @ptrFromInt(start)) == 0) {
            c.gst_memory_unmap(@ptrCast(m[0].pbo), &pi);
            return false;
        }
        c.gst_memory_unmap(@ptrCast(m[0].pbo), &pi);
    }
    return true;
}

fn downloadTransfer(m: OPbo, info: [*c]c.GstMapInfo) c.gpointer {
    m[0].pbo[0].target = PIXEL_PACK_BUFFER;
    if (info[0].flags & c.GST_MAP_READ != 0 and flagSet(m, NEED_DOWNLOAD)) {
        var tmp: c.GstMapInfo = undefined;
        if (c.gst_memory_map(@ptrCast(m[0].pbo), &tmp, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) return null;
        if (!readToPbo(m)) {
            c.gst_memory_unmap(@ptrCast(m[0].pbo), &tmp);
            return null;
        }
        c.gst_memory_unmap(@ptrCast(m[0].pbo), &tmp);
    }
    const pi: [*c]c.GstMapInfo = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstMapInfo))));
    if (c.gst_memory_map(@ptrCast(m[0].pbo), pi, info[0].flags) == 0) {
        c.g_free(pi);
        return null;
    }
    info[0].user_data[0] = pi;
    return pi[0].data;
}

fn mapCpu(m: OPbo, info: [*c]c.GstMapInfo, size: c.gsize) c.gpointer {
    var data: c.gpointer = null;
    _ = base.gst_gl_base_memory_alloc_data(@ptrCast(m));
    if (m[0].pbo != null and canDownload(ctxOf(m))) data = downloadTransfer(m, info);
    if (data == null) data = parent.?.map.?(@ptrCast(m), info, size);
    return data;
}

fn mapGpu(m: OPbo, info: [*c]c.GstMapInfo, size: c.gsize) c.gpointer {
    var data: c.gpointer = &m[0].mem.tex_id;
    if (info[0].flags & c.GST_MAP_READ == c.GST_MAP_READ) {
        if (m[0].pbo != null and canUpload(ctxOf(m))) {
            var pi: c.GstMapInfo = undefined;
            if (c.gst_memory_map(@ptrCast(m[0].pbo), &pi, c.GST_MAP_READ | c.GST_MAP_GL) == 0) return null;
            uploadPbo(m, &pi);
            c.gst_memory_unmap(@ptrCast(m[0].pbo), &pi);
        } else {
            data = parent.?.map.?(@ptrCast(m), info, size);
        }
    }
    return data;
}

fn map(b: OBase, info: [*c]c.GstMapInfo, size: c.gsize) callconv(.c) c.gpointer {
    const m: OPbo = @ptrCast(@alignCast(b));
    const oes = m[0].mem.tex_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES;
    if (info[0].flags & c.GST_MAP_GL == c.GST_MAP_GL) {
        if (oes) return &m[0].mem.tex_id;
        return mapGpu(m, info, size);
    }
    if (oes) return null;
    return mapCpu(m, info, size);
}

fn unmap(b: OBase, info: [*c]c.GstMapInfo) callconv(.c) void {
    const m: OPbo = @ptrCast(@alignCast(b));
    if (info[0].flags & c.GST_MAP_GL != 0) return;
    if (m[0].pbo == null or !canDownload(ctxOf(m))) return;
    m[0].pbo[0].target = PIXEL_PACK_BUFFER;
    c.gst_memory_unmap(@ptrCast(m[0].pbo), @ptrCast(@alignCast(info[0].user_data[0])));
    c.g_free(info[0].user_data[0]);
}

const CopyParams = struct {
    src: OPbo,
    out_format: c.GstGLFormat,
    out_width: c.guint,
    out_height: c.guint,
    out_stride: c.guint,
    respecify: c.gboolean,
    tex_target: c.GstGLTextureTarget,
    tex_id: c.guint,
    result: c.gboolean,
};

fn newTexture(ctx: OCtx, target: c.guint, internal: c.guint, fmt: c.guint, t: c.guint, w: c.guint, h: c.guint) c.guint {
    const gl = &ctx[0].gl_vtable[0];
    var id: c.GLuint = 0;
    gl.GenTextures.?(1, &id);
    gl.BindTexture.?(target, id);
    if (target == c.GL_TEXTURE_2D or target == 0x84F5) gl.TexImage2D.?(target, 0, @bitCast(internal), @bitCast(w), @bitCast(h), 0, fmt, t, null);
    gl.TexParameteri.?(target, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(target, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(target, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(target, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    gl.BindTexture.?(target, 0);
    return id;
}

fn copyThread(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const p: *CopyParams = @ptrCast(@alignCast(data));
    const src = p.src;
    var tex_id = p.tex_id;
    const target = format.gst_gl_texture_target_to_gl(p.tex_target);
    const gl = &ctx[0].gl_vtable[0];
    var of: c.GstGLFormat = 0;
    var ot: c.guint = 0;
    var inf: c.GstGLFormat = 0;
    var int: c.guint = 0;
    format.gst_gl_format_type_from_sized_gl_format(p.out_format, &of, &ot);
    format.gst_gl_format_type_from_sized_gl_format(src[0].mem.tex_format, &inf, &int);
    if (gl.GenFramebuffers == null) {
        p.result = 0;
        return;
    }
    const in_size = @as(c.gsize, pboHeight(src)) * pboStride(src);
    const out_size = @as(c.gsize, p.out_height) * p.out_stride;
    if (p.respecify != 0 and in_size != out_size) {
        p.result = 0;
        return;
    }
    if (tex_id == 0) tex_id = newTexture(ctx, target, p.out_format, of, ot, p.out_width, p.out_height);
    var fbo: c.GLuint = 0;
    gl.GenFramebuffers.?(1, &fbo);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, fbo);
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, format.gst_gl_texture_target_to_gl(src[0].mem.tex_target), src[0].mem.tex_id, 0);
    gl.BindTexture.?(target, tex_id);
    fail: {
        if (p.respecify != 0) {
            if (gl.GenBuffers == null or src[0].pbo == null) {
                gl.BindTexture.?(target, 0);
                break :fail;
            }
            if (context.gst_gl_context_get_gl_api(ctx) & c.GST_GL_API_GLES2 != 0 and (inf != c.GL_RGBA or int != c.GL_UNSIGNED_BYTE)) {
                gl.BindTexture.?(target, 0);
                break :fail;
            }
            _ = readToPbo(src);
            src[0].pbo[0].target = PIXEL_UNPACK_BUFFER;
            var pi: c.GstMapInfo = undefined;
            if (c.gst_memory_map(@ptrCast(src[0].pbo), &pi, c.GST_MAP_READ | c.GST_MAP_GL) == 0) break :fail;
            gl.TexSubImage2D.?(target, 0, 0, 0, @bitCast(p.out_width), @bitCast(p.out_height), of, ot, null);
            c.gst_memory_unmap(@ptrCast(src[0].pbo), &pi);
        } else {
            _ = memory.gst_gl_memory_copy_teximage(@ptrCast(src), tex_id, p.tex_target, p.out_format, @bitCast(p.out_width), @bitCast(p.out_height));
        }
        gl.BindTexture.?(target, 0);
        gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
        gl.DeleteFramebuffers.?(1, &fbo);
        p.tex_id = tex_id;
        p.result = 1;
        return;
    }
    gl.DeleteFramebuffers.?(1, &fbo);
    p.tex_id = 0;
    p.result = 0;
}

fn copy(b: OBase, offset: c.gssize, size: c.gssize) callconv(.c) OBase {
    const src: OPbo = @ptrCast(@alignCast(b));
    const allocator = src[0].mem.mem.mem.allocator;
    const ba: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(allocator));
    var params = c.GstAllocationParams{ .flags = 0, .@"align" = src[0].mem.mem.mem.@"align", .prefix = 0, .padding = 0, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    if (src[0].mem.tex_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) return null;
    if (offset > 0 or @as(c.gsize, @bitCast(size)) < src[0].mem.mem.mem.size) return @ptrCast(@alignCast(ba[0].fallback_mem_copy.?(@ptrCast(src), offset, size)));
    const dest: OPbo = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Pbo))));
    memory.gst_gl_memory_init(@ptrCast(dest), allocator, null, src[0].mem.mem.context, src[0].mem.tex_target, src[0].mem.tex_format, &params, &src[0].mem.info, src[0].mem.plane, &src[0].mem.valign, null, null);
    if (!flagSet(src, NEED_UPLOAD)) {
        var di: c.GstMapInfo = undefined;
        if (c.gst_memory_map(@ptrCast(dest), &di, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) {
            c.gst_memory_unref(@ptrCast(dest));
            return null;
        }
        const ok = memory.gst_gl_memory_copy_into(@ptrCast(src), dest[0].mem.tex_id, src[0].mem.tex_target, src[0].mem.tex_format, @bitCast(src[0].mem.tex_width), @bitCast(pboHeight(src)));
        c.gst_memory_unmap(@ptrCast(dest), &di);
        if (ok != 0) return @ptrCast(dest);
    }
    if (base.gst_gl_base_memory_memcpy(@ptrCast(src), @ptrCast(dest), offset, size) == 0) {
        c.gst_memory_unref(@ptrCast(dest));
        return null;
    }
    return @ptrCast(dest);
}

fn plainAlloc(_: [*c]c.GstAllocator, _: c.gsize, _: [*c]c.GstAllocationParams) callconv(.c) [*c]c.GstMemory {
    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Use gst_gl_base_memory_alloc () to allocate from this GstGLMemoryPBO allocator");
    return null;
}

fn destroy(b: OBase) callconv(.c) void {
    const m: OPbo = @ptrCast(@alignCast(b));
    if (m[0].pbo != null) c.gst_memory_unref(@ptrCast(m[0].pbo));
    m[0].pbo = null;
    baseParent().destroy.?(b);
}

fn pboAlloc(allocator: [*c]c.GstGLBaseMemoryAllocator, bp: [*c]c.GstGLAllocationParams) callconv(.c) OBase {
    const p: [*c]c.GstGLVideoAllocationParams = @ptrCast(@alignCast(bp));
    var ap = std.mem.zeroes(c.GstAllocationParams);
    const flags = p[0].parent.alloc_flags;
    if (p[0].parent.alloc_params != null) ap = p[0].parent.alloc_params[0];
    if (!check.that(flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO != 0, "_gl_mem_pbo_alloc", "alloc_flags & GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO")) return null;
    const m: OPbo = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Pbo))));
    if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE != 0) {
        m[0].mem.tex_id = @truncate(@intFromPtr(p[0].parent.gl_handle));
        m[0].mem.texture_wrapped = 1;
        ap.flags |= NEED_DOWNLOAD;
    }
    if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM != 0) {
        ap.flags |= NEED_UPLOAD;
        m[0].mem.mem.data = p[0].parent.wrapped_data;
    }
    memory.gst_gl_memory_init(@ptrCast(m), @ptrCast(allocator), null, p[0].parent.context, p[0].target, p[0].tex_format, &ap, p[0].v_info, p[0].plane, p[0].valign, p[0].parent.user_data, p[0].parent.notify);
    if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM != 0) m[0].mem.mem.data = p[0].parent.wrapped_data;
    return @ptrCast(m);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const bk: *c.GstGLBaseMemoryAllocatorClass = @ptrCast(@alignCast(k));
    const tk: *c.GstGLMemoryAllocatorClass = @ptrCast(@alignCast(k));
    bk.alloc = pboAlloc;
    bk.create = create;
    tk.map = map;
    tk.unmap = unmap;
    tk.copy = copy;
    bk.destroy = destroy;
    @as(*c.GstAllocatorClass, @ptrCast(@alignCast(k))).alloc = plainAlloc;
}

fn allocInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *c.GstAllocator = @ptrCast(@alignCast(inst));
    a.mem_type = NAME;
    a.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

pub export fn gst_gl_memory_pbo_allocator_get_type() c.GType {
    return alloc_once.get(struct {
        fn f() c.GType {
            return gtype.object(memory.gst_gl_memory_allocator_get_type, "GstGLMemoryPBOAllocator", c.GstGLMemoryPBOAllocatorClass, c.GstGLMemoryPBOAllocator, classInit, allocInit, 0);
        }
    }.f);
}

pub export fn gst_gl_memory_pbo_get_type() c.GType {
    return mem_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLMemoryPBO", @ptrCast(&c.gst_mini_object_ref), @ptrCast(&c.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_gl_memory_pbo_copy_into_texture(m: OPbo, tex_id: c.guint, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat, w: c.gint, h: c.gint, stride: c.gint, respecify: c.gboolean) c.gboolean {
    var p = CopyParams{ .src = m, .out_format = tex_format, .out_width = @bitCast(w), .out_height = @bitCast(h), .out_stride = @bitCast(stride), .respecify = respecify, .tex_target = target, .tex_id = tex_id, .result = 0 };
    c.gst_gl_context_thread_add(ctxOf(m), copyThread, &p);
    return p.result;
}

fn downloadCb(_: OCtx, data: c.gpointer) callconv(.c) void {
    const m: OPbo = @ptrCast(@alignCast(data));
    c.g_mutex_lock(&m[0].mem.mem.lock);
    if (readToPbo(m)) m[0].mem.mem.mem.mini_object.flags &= ~NEED_DOWNLOAD;
    c.g_mutex_unlock(&m[0].mem.mem.lock);
}

pub export fn gst_gl_memory_pbo_download_transfer(m: OPbo) void {
    if (!check.that(memory.gst_is_gl_memory(@ptrCast(m)) != 0, "gst_gl_memory_pbo_download_transfer", "gst_is_gl_memory ((GstMemory *) gl_mem)")) return;
    c.gst_gl_context_thread_add(ctxOf(m), downloadCb, m);
}

fn uploadCb(_: OCtx, data: c.gpointer) callconv(.c) void {
    const m: OPbo = @ptrCast(@alignCast(data));
    c.g_mutex_lock(&m[0].mem.mem.lock);
    m[0].pbo[0].target = PIXEL_UNPACK_BUFFER;
    var info: c.GstMapInfo = undefined;
    if (c.gst_memory_map(@ptrCast(m[0].pbo), &info, c.GST_MAP_READ | c.GST_MAP_GL) != 0) c.gst_memory_unmap(@ptrCast(m[0].pbo), &info);
    c.g_mutex_unlock(&m[0].mem.mem.lock);
}

pub export fn gst_gl_memory_pbo_upload_transfer(m: OPbo) void {
    if (!check.that(memory.gst_is_gl_memory(@ptrCast(m)) != 0, "gst_gl_memory_pbo_upload_transfer", "gst_is_gl_memory ((GstMemory *) gl_mem)")) return;
    if (m[0].pbo != null and canUpload(ctxOf(m))) c.gst_gl_context_thread_add(ctxOf(m), uploadCb, m);
}

pub export fn gst_gl_memory_pbo_init_once() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        memory.gst_gl_memory_init_once();
        _ = c._gst_debug_category_new("glmemory", 0, "OpenGL Memory");
        default_allocator = @ptrCast(@alignCast(c.g_object_new(gst_gl_memory_pbo_allocator_get_type(), @as([*c]const u8, null))));
        _ = c.gst_object_ref_sink(default_allocator);
        default_allocator.?.object.flags |= c.GST_OBJECT_FLAG_MAY_BE_LEAKED;
        c.gst_allocator_register(NAME, @ptrCast(@alignCast(c.gst_object_ref(default_allocator))));
        c.g_once_init_leave(&init_done, 1);
    }
}

pub export fn gst_is_gl_memory_pbo(mem: [*c]c.GstMemory) c.gboolean {
    return @intFromBool(mem != null and mem[0].allocator != null and c.g_type_is_a(gtype.typeOf(mem[0].allocator), gst_gl_memory_pbo_allocator_get_type()) != 0);
}
