const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const base = @import("basememory.zig");
const format = @import("format.zig");
const query = @import("query.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Mem = c.GstGLMemory;
const OMem = [*c]Mem;
const OBase = [*c]c.GstGLBaseMemory;
const OCtx = [*c]c.GstGLContext;
const Alloc = c.GstGLMemoryAllocator;
const AllocClass = c.GstGLMemoryAllocatorClass;
const VParams = c.GstGLVideoAllocationParams;
const OVParams = [*c]VParams;

pub const NAME = "GLMemory";
const PBO_NAME = "GLMemoryPBO";
const UNPACK_ROW_LENGTH = 0x0CF2;
const PACK_ROW_LENGTH = 0x0D02;
const READ_FRAMEBUFFER = 0x8CA8;
const DRAW_FRAMEBUFFER = 0x8CA9;
const NEED_DOWNLOAD: c.guint = c.GST_GL_BASE_MEMORY_TRANSFER_NEED_DOWNLOAD;
const NEED_UPLOAD: c.guint = c.GST_GL_BASE_MEMORY_TRANSFER_NEED_UPLOAD;

var alloc_once: gtype.Once = .{};
var mem_once: gtype.Once = .{};
var vparams_once: gtype.Once = .{};
var init_done: usize = 0;
var default_allocator: ?*c.GstAllocator = null;
pub var cat: ?*c.GstDebugCategory = null;

const ver = context.gst_gl_context_check_gl_version;

pub fn opengl(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_OPENGL, 1, 0) != 0;
}

pub fn opengl3(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_OPENGL3, 3, 1) != 0;
}

pub fn gles2(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_GLES2, 2, 0) != 0;
}

pub fn gles3(ctx: OCtx) bool {
    return ver(ctx, c.GST_GL_API_GLES2, 3, 0) != 0;
}

fn flagSet(m: anytype, f: c.guint) bool {
    return @as([*c]c.GstMiniObject, @ptrCast(@alignCast(m)))[0].flags & f != 0;
}

fn setFlag(m: anytype, f: c.guint) void {
    @as([*c]c.GstMiniObject, @ptrCast(@alignCast(m)))[0].flags |= f;
}

fn isYuv(info: *const c.GstVideoInfo) bool {
    return info.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_YUV != 0;
}

fn isTiled(fi: [*c]const c.GstVideoFormatInfo) bool {
    return fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_TILED != 0;
}

fn subScale(scale: c.guint, v: c.gint) c.gint {
    return -((-v) >> @intCast(scale));
}

fn fieldHeight(info: *const c.GstVideoInfo) c.gint {
    if (info.interlace_mode == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) return @divTrunc(info.height + 1, 2);
    return info.height;
}

pub fn planeWidth(info: *const c.GstVideoInfo, plane: c.guint) c.guint {
    if (!isYuv(info)) return @bitCast(info.width);
    if (info.finfo[0].format == c.GST_VIDEO_FORMAT_v210) return @intCast((@as(u64, @intCast(info.width + 5)) / 6) * 4);
    var comp: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
    c.gst_video_format_info_component(info.finfo, plane, &comp);
    return @bitCast(subScale(info.finfo[0].w_sub[@intCast(comp[0])], info.width));
}

pub fn planeHeight(info: *const c.GstVideoInfo, plane: c.guint) c.guint {
    if (isTiled(info.finfo)) {
        const th: c.guint = info.finfo[0].tile_info[plane].height;
        const stride: c.guint = @bitCast(info.stride[plane]);
        return (stride >> 16) * th;
    }
    if (isYuv(info)) {
        var comp: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
        c.gst_video_format_info_component(info.finfo, plane, &comp);
        return @bitCast(subScale(info.finfo[0].h_sub[@intCast(comp[0])], fieldHeight(info)));
    }
    return @bitCast(info.height);
}

pub fn memStride(m: OMem) c.guint {
    const fi = m[0].info.finfo;
    const stride: c.guint = @bitCast(m[0].info.stride[m[0].plane]);
    if (!isTiled(fi)) return stride;
    return (stride & 0xffff) * fi[0].tile_info[m[0].plane].stride;
}

fn width(m: OMem) c.guint {
    return planeWidth(@ptrCast(&m[0].info), m[0].plane);
}

fn height(m: OMem) c.guint {
    return planeHeight(@ptrCast(&m[0].info), m[0].plane);
}

fn unpackLength(m: OMem, ctx: OCtx) void {
    m[0].tex_scaling = .{ 1.0, 1.0 };
    m[0].unpack_length = 1;
    var tf: c.GstGLFormat = 0;
    var tt: c.guint = 0;
    format.gst_gl_format_type_from_sized_gl_format(m[0].tex_format, &tf, &tt);
    const n = format.gst_gl_format_type_n_bytes(tf, tt);
    if (n == 0) return;
    const stride = memStride(m);
    m[0].tex_width = if (isTiled(m[0].info.finfo)) stride / n else width(m);
    if (opengl(ctx) or gles3(ctx) or opengl3(ctx)) {
        m[0].unpack_length = stride / n;
    } else if (gles2(ctx)) {
        var j: c.guint = 8;
        while (j >= n) : (j >>= 1) {
            const r = ((width(m) * n) + j - 1) & ~(j - 1);
            if (r == stride) {
                m[0].unpack_length = j;
                break;
            }
        }
        if (j < n) {
            j = 8;
            while (j >= n) : (j >>= 1) {
                const r = (stride + j - 1) & ~(j - 1);
                if (r == stride) {
                    m[0].unpack_length = j;
                    m[0].tex_scaling[0] = @as(f32, @floatFromInt(width(m) * n)) / @as(f32, @floatFromInt(stride));
                    m[0].tex_width = stride / n;
                    break;
                }
            }
        }
    }
    if (m[0].tex_target == c.GST_GL_TEXTURE_TARGET_RECTANGLE) {
        const ws = m[0].info.finfo[0].w_sub[m[0].plane];
        const hs = m[0].info.finfo[0].h_sub[m[0].plane];
        if (ws != 0) m[0].tex_scaling[0] /= @floatFromInt(@as(u32, 1) << @intCast(ws));
        if (hs != 0) m[0].tex_scaling[1] /= @floatFromInt(@as(u32, 1) << @intCast(hs));
    }
}

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

fn texCreate(b: OBase, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const m: OMem = @ptrCast(@alignCast(b));
    const ctx = m[0].mem.context;
    var tf: c.GstGLFormat = 0;
    var tt: c.guint = 0;
    format.gst_gl_format_type_from_sized_gl_format(m[0].tex_format, &tf, &tt);
    const internal = format.gst_gl_sized_gl_format_from_gl_format_type(ctx, tf, tt);
    if (m[0].texture_wrapped == 0) m[0].tex_id = newTexture(ctx, format.gst_gl_texture_target_to_gl(m[0].tex_target), internal, tf, tt, m[0].tex_width, height(m));
    return 1;
}

fn startLog(m: OMem, comptime func: [*:0]const u8, line: c.gint, what: [*:0]const u8) void {
    if (m[0].mem.query == null) return;
    query.startLog(m[0].mem.query, cat, "gstglmemory.c", func, line, what);
}

fn endLog(m: OMem) void {
    if (m[0].mem.query == null) return;
    query.gst_gl_query_end(m[0].mem.query);
}

pub export fn gst_gl_memory_init(m: OMem, allocator: [*c]c.GstAllocator, parent: [*c]c.GstMemory, ctx: OCtx, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat, params: [*c]const c.GstAllocationParams, info: [*c]const c.GstVideoInfo, plane: c.guint, valign: [*c]const c.GstVideoAlignment, user_data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(plane < info[0].finfo[0].n_planes, "gst_gl_memory_init", "plane < GST_VIDEO_INFO_N_PLANES (info)")) return;
    m[0].info = info[0];
    if (valign != null) m[0].valign = valign[0] else c.gst_video_alignment_reset(&m[0].valign);
    const size = c.gst_gl_get_plane_data_size(info, valign, plane);
    m[0].tex_target = target;
    m[0].tex_format = tex_format;
    m[0].plane = plane;
    unpackLength(m, ctx);
    base.gst_gl_base_memory_init(@ptrCast(m), allocator, parent, ctx, params, size, user_data, notify);
}

pub export fn gst_gl_memory_read_pixels(m: OMem, dest: c.gpointer) c.gboolean {
    const ctx = m[0].mem.context;
    const gl = &ctx[0].gl_vtable[0];
    var fmt: c.GstGLFormat = 0;
    var t: c.guint = 0;
    format.gst_gl_format_type_from_sized_gl_format(m[0].tex_format, &fmt, &t);
    var fbo: c.GLuint = 0;
    gl.GenFramebuffers.?(1, &fbo);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, fbo);
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, format.gst_gl_texture_target_to_gl(m[0].tex_target), m[0].tex_id, 0);
    if (c.gst_gl_context_check_framebuffer_status(ctx, c.GL_FRAMEBUFFER) == 0) {
        gl.DeleteFramebuffers.?(1, &fbo);
        return 0;
    }
    if (gles2(ctx) or gles3(ctx)) {
        if (!(fmt == c.GL_RGBA and t == c.GL_UNSIGNED_BYTE)) {
            var sf: c.GLint = 0;
            var st: c.GLint = 0;
            gl.GetIntegerv.?(c.GL_IMPLEMENTATION_COLOR_READ_FORMAT, &sf);
            gl.GetIntegerv.?(c.GL_IMPLEMENTATION_COLOR_READ_TYPE, &st);
            if (@as(c.guint, @bitCast(sf)) != fmt or @as(c.guint, @bitCast(st)) != t) {
                gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
                gl.DeleteFramebuffers.?(1, &fbo);
                return 0;
            }
        }
    }
    if (opengl(ctx) or gles3(ctx) or opengl3(ctx)) {
        gl.PixelStorei.?(PACK_ROW_LENGTH, @bitCast(m[0].unpack_length));
    } else if (gles2(ctx)) {
        gl.PixelStorei.?(c.GL_PACK_ALIGNMENT, @bitCast(m[0].unpack_length));
    }
    startLog(m, "_gst_gl_memory_start_log", 384, "glReadPixels");
    gl.ReadPixels.?(0, 0, @bitCast(m[0].tex_width), @bitCast(height(m)), fmt, t, dest);
    endLog(m);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    gl.DeleteFramebuffers.?(1, &fbo);
    return 1;
}

fn maxsizeOk(m: OMem, size: c.gsize) bool {
    return size == std.math.maxInt(c.gsize) or size == m[0].mem.mem.maxsize;
}

fn downloadTexImage(m: OMem, info: [*c]c.GstMapInfo, size: c.gsize) c.gpointer {
    const ctx = m[0].mem.context;
    const gl = &ctx[0].gl_vtable[0];
    if (!maxsizeOk(m, size)) return null;
    if (gles2(ctx) or gles3(ctx)) return null;
    if (m[0].tex_format != c.GST_GL_LUMINANCE and m[0].tex_format != c.GST_GL_LUMINANCE_ALPHA) return null;
    if (info[0].flags & c.GST_MAP_READ != 0 and flagSet(m, NEED_DOWNLOAD)) {
        var fmt: c.GstGLFormat = 0;
        var t: c.guint = 0;
        format.gst_gl_format_type_from_sized_gl_format(m[0].tex_format, &fmt, &t);
        const target = format.gst_gl_texture_target_to_gl(m[0].tex_target);
        gl.BindTexture.?(target, m[0].tex_id);
        startLog(m, "_gst_gl_memory_start_log", 422, "glGetTexImage");
        gl.GetTexImage.?(target, 0, fmt, t, m[0].mem.data);
        endLog(m);
        gl.BindTexture.?(target, 0);
    }
    return m[0].mem.data;
}

fn downloadReadPixels(m: OMem, info: [*c]c.GstMapInfo, size: c.gsize) c.gpointer {
    if (!maxsizeOk(m, size)) return null;
    if (info[0].flags & c.GST_MAP_READ != 0 and flagSet(m, NEED_DOWNLOAD)) {
        if (gst_gl_memory_read_pixels(m, m[0].mem.data) == 0) return null;
    }
    return m[0].mem.data;
}

fn mapCpu(m: OMem, info: [*c]c.GstMapInfo, size: c.gsize) c.gpointer {
    if (base.gst_gl_base_memory_alloc_data(@ptrCast(m)) == 0) return null;
    var data = downloadTexImage(m, info, size);
    if (data == null) data = downloadReadPixels(m, info, size);
    return data;
}

pub export fn gst_gl_memory_texsubimage(m: OMem, src: c.gpointer) void {
    if (!flagSet(m, NEED_UPLOAD)) return;
    const ctx = m[0].mem.context;
    const gl = &ctx[0].gl_vtable[0];
    var fmt: c.GstGLFormat = 0;
    var t: c.guint = 0;
    format.gst_gl_format_type_from_sized_gl_format(m[0].tex_format, &fmt, &t);
    const target = format.gst_gl_texture_target_to_gl(m[0].tex_target);
    const full = opengl(ctx) or gles3(ctx) or opengl3(ctx);
    if (full) {
        gl.PixelStorei.?(UNPACK_ROW_LENGTH, @bitCast(m[0].unpack_length));
    } else if (gles2(ctx)) {
        gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, @bitCast(m[0].unpack_length));
    }
    const start = c.gst_gl_get_plane_start(&m[0].info, &m[0].valign, m[0].plane) + m[0].mem.mem.offset;
    const data: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(start)) +% @as(isize, @bitCast(@intFromPtr(src))))));
    gl.BindTexture.?(target, m[0].tex_id);
    startLog(m, "_gst_gl_memory_start_log", 491, "glTexSubImage");
    gl.TexSubImage2D.?(target, 0, 0, 0, @bitCast(m[0].tex_width), @bitCast(height(m)), fmt, t, data);
    endLog(m);
    if (full) {
        gl.PixelStorei.?(UNPACK_ROW_LENGTH, 0);
    } else if (gles2(ctx)) {
        gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, 4);
    }
    gl.BindTexture.?(target, 0);
}

fn defaultMap(b: OBase, info: [*c]c.GstMapInfo, size: c.gsize) callconv(.c) c.gpointer {
    const m: OMem = @ptrCast(@alignCast(b));
    if (info[0].flags & c.GST_MAP_GL == c.GST_MAP_GL) {
        gst_gl_memory_texsubimage(m, m[0].mem.data);
        return &m[0].tex_id;
    }
    return mapCpu(m, info, size);
}

pub fn allocClass(m: anytype) *AllocClass {
    return gtype.classPeek(AllocClass, @as(OMem, @ptrCast(@alignCast(m)))[0].mem.mem.allocator);
}

fn texMap(b: OBase, info: [*c]c.GstMapInfo, size: c.gsize) callconv(.c) c.gpointer {
    const m: OMem = @ptrCast(@alignCast(b));
    const k = allocClass(m);
    const oes = m[0].tex_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES;
    if (info[0].flags & c.GST_MAP_GL == c.GST_MAP_GL) {
        if (oes) return &m[0].tex_id;
    } else if (oes) return null;
    if (!check.that(k.map != null, "_gl_tex_map", "alloc_class->map != NULL")) return null;
    return k.map.?(b, info, size);
}

fn defaultUnmap(_: OBase, _: [*c]c.GstMapInfo) callconv(.c) void {}

fn texUnmap(b: OBase, info: [*c]c.GstMapInfo) callconv(.c) void {
    const k = allocClass(b);
    if (!check.that(k.unmap != null, "_gl_tex_unmap", "alloc_class->unmap != NULL")) return;
    k.unmap.?(b, info);
}

pub export fn gst_gl_memory_copy_teximage(src: OMem, tex_id: c.guint, out_target: c.GstGLTextureTarget, out_format: c.GstGLFormat, out_w: c.gint, out_h: c.gint) c.gboolean {
    const ctx = src[0].mem.context;
    const gl = &ctx[0].gl_vtable[0];
    const target = format.gst_gl_texture_target_to_gl(out_target);
    if (gl.GenFramebuffers == null) return 0;
    if (gles2(ctx) and (src[0].tex_format == c.GST_GL_LUMINANCE or src[0].tex_format == c.GST_GL_LUMINANCE_ALPHA)) return 0;
    var si: c.GstMapInfo = undefined;
    if (c.gst_memory_map(@ptrCast(src), &si, c.GST_MAP_READ | c.GST_MAP_GL) == 0) return 0;
    const src_id = @as(*const c.guint, @ptrCast(@alignCast(si.data))).*;
    const src_target = format.gst_gl_texture_target_to_gl(src[0].tex_target);
    var fbo = [2]c.GLuint{ 0, 0 };
    var n: c.GLsizei = 1;
    const simple = gl.BlitFramebuffer == null or (gl.DrawBuffer == null and gl.DrawBuffers == null) or gl.ReadBuffer == null;
    ok: {
        if (simple) {
            gl.GenFramebuffers.?(n, &fbo);
            gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, fbo[0]);
            gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, src_target, src_id, 0);
            if (c.gst_gl_context_check_framebuffer_status(ctx, c.GL_FRAMEBUFFER) == 0) break :ok;
            gl.BindTexture.?(target, tex_id);
            startLog(src, "_gst_gl_memory_start_log", 607, "CopyTexImage2D");
            gl.CopyTexImage2D.?(target, 0, out_format, 0, 0, out_w, out_h, 0);
            endLog(src);
            gl.BindTexture.?(target, 0);
            gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
            gl.DeleteFramebuffers.?(n, &fbo);
        } else {
            const rt = [_]c.GLenum{ c.GL_COLOR_ATTACHMENT0, c.GL_COLOR_ATTACHMENT0 + 1, c.GL_COLOR_ATTACHMENT0 + 2 };
            n = 2;
            gl.GenFramebuffers.?(n, &fbo);
            gl.BindFramebuffer.?(READ_FRAMEBUFFER, fbo[0]);
            gl.FramebufferTexture2D.?(READ_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, src_target, src_id, 0);
            if (c.gst_gl_context_check_framebuffer_status(ctx, READ_FRAMEBUFFER) == 0) break :ok;
            gl.BindFramebuffer.?(DRAW_FRAMEBUFFER, fbo[1]);
            gl.FramebufferTexture2D.?(DRAW_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, src_target, tex_id, 0);
            if (c.gst_gl_context_check_framebuffer_status(ctx, DRAW_FRAMEBUFFER) == 0) break :ok;
            gl.BindTexture.?(target, tex_id);
            startLog(src, "_gst_gl_memory_start_log", 637, "BlitFramebuffer");
            gl.ReadBuffer.?(c.GL_COLOR_ATTACHMENT0);
            if (gl.DrawBuffers) |f| f(1, &rt) else gl.DrawBuffer.?(c.GL_COLOR_ATTACHMENT0);
            gl.BlitFramebuffer.?(0, 0, out_w, out_h, 0, 0, out_w, out_h, c.GL_COLOR_BUFFER_BIT, c.GL_NEAREST);
            endLog(src);
            gl.BindTexture.?(target, 0);
            gl.BindFramebuffer.?(DRAW_FRAMEBUFFER, 0);
            gl.BindFramebuffer.?(READ_FRAMEBUFFER, 0);
            gl.DeleteFramebuffers.?(n, &fbo);
            if (gl.DrawBuffer) |f| f(c.GL_BACK);
        }
        c.gst_memory_unmap(@ptrCast(src), &si);
        return 1;
    }
    gl.BindTexture.?(target, 0);
    if (gl.BlitFramebuffer == null) {
        gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    } else {
        gl.BindFramebuffer.?(DRAW_FRAMEBUFFER, 0);
        gl.BindFramebuffer.?(READ_FRAMEBUFFER, 0);
    }
    gl.DeleteFramebuffers.?(n, &fbo);
    c.gst_memory_unmap(@ptrCast(src), &si);
    return 0;
}

const CopyParams = struct {
    src: OMem,
    out_format: c.GstGLFormat,
    out_width: c.guint,
    out_height: c.guint,
    tex_target: c.GstGLTextureTarget,
    tex_format: c.GstGLFormat,
    tex_id: c.guint,
    result: c.gboolean,
};

fn copyThread(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const p: *CopyParams = @ptrCast(@alignCast(data));
    if (p.tex_id == 0) {
        const target = format.gst_gl_texture_target_to_gl(p.tex_target);
        var of: c.GstGLFormat = 0;
        var ot: c.guint = 0;
        format.gst_gl_format_type_from_sized_gl_format(p.src[0].tex_format, &of, &ot);
        const internal = format.gst_gl_sized_gl_format_from_gl_format_type(ctx, of, ot);
        p.tex_id = newTexture(ctx, target, internal, of, ot, p.out_width, p.out_height);
    }
    p.result = gst_gl_memory_copy_teximage(p.src, p.tex_id, p.tex_target, p.tex_format, @bitCast(p.out_width), @bitCast(p.out_height));
}

fn defaultCopy(b: OBase, offset: c.gssize, size: c.gssize) callconv(.c) OBase {
    const src: OMem = @ptrCast(@alignCast(b));
    const allocator = src[0].mem.mem.allocator;
    const ba: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(allocator));
    var params = c.GstAllocationParams{ .flags = 0, .@"align" = src[0].mem.mem.@"align", .prefix = 0, .padding = 0, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    if (src[0].tex_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) return null;
    if (offset > 0 or @as(c.gsize, @bitCast(size)) < src[0].mem.mem.size) return @ptrCast(@alignCast(ba[0].fallback_mem_copy.?(@ptrCast(src), offset, size)));
    const dest: OMem = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Mem))));
    gst_gl_memory_init(dest, allocator, null, src[0].mem.context, src[0].tex_target, src[0].tex_format, &params, &src[0].info, src[0].plane, &src[0].valign, null, null);
    if (!flagSet(src, NEED_UPLOAD)) {
        var di: c.GstMapInfo = undefined;
        if (c.gst_memory_map(@ptrCast(dest), &di, c.GST_MAP_WRITE | c.GST_MAP_GL) == 0) {
            c.gst_memory_unref(@ptrCast(dest));
            return null;
        }
        const ok = gst_gl_memory_copy_into(src, dest[0].tex_id, src[0].tex_target, src[0].tex_format, @bitCast(src[0].tex_width), @bitCast(height(src)));
        c.gst_memory_unmap(@ptrCast(dest), &di);
        if (ok != 0) return @ptrCast(dest);
    }
    if (base.gst_gl_base_memory_memcpy(@ptrCast(src), @ptrCast(dest), offset, size) == 0) {
        c.gst_memory_unref(@ptrCast(dest));
        return null;
    }
    return @ptrCast(dest);
}

fn texCopy(b: OBase, offset: c.gssize, size: c.gssize) callconv(.c) OBase {
    const src: OMem = @ptrCast(@alignCast(b));
    if (src[0].tex_target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) return null;
    const k = allocClass(src);
    if (!check.that(k.copy != null, "_gl_tex_copy", "alloc_class->copy")) return null;
    return k.copy.?(b, offset, size);
}

fn texAllocPlain(_: [*c]c.GstAllocator, _: c.gsize, _: [*c]c.GstAllocationParams) callconv(.c) [*c]c.GstMemory {
    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Use gst_gl_base_memory_alloc to allocate from this allocator");
    return null;
}

fn texDestroy(b: OBase) callconv(.c) void {
    const m: OMem = @ptrCast(@alignCast(b));
    const gl = &m[0].mem.context[0].gl_vtable[0];
    if (m[0].tex_id != 0 and m[0].texture_wrapped == 0) gl.DeleteTextures.?(1, &m[0].tex_id);
}

fn defaultAlloc(allocator: [*c]c.GstGLBaseMemoryAllocator, bp: [*c]c.GstGLAllocationParams) callconv(.c) OBase {
    const p: OVParams = @ptrCast(@alignCast(bp));
    const flags = p[0].parent.alloc_flags;
    if (!check.that(flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO != 0, "_default_gl_tex_alloc", "alloc_flags & GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO")) return null;
    const m: OMem = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Mem))));
    if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE != 0) {
        m[0].tex_id = @truncate(@intFromPtr(p[0].parent.gl_handle));
        m[0].texture_wrapped = 1;
    }
    gst_gl_memory_init(m, @ptrCast(allocator), null, p[0].parent.context, p[0].target, p[0].tex_format, p[0].parent.alloc_params, p[0].v_info, p[0].plane, p[0].valign, p[0].parent.user_data, p[0].parent.notify);
    if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE != 0) setFlag(m, NEED_DOWNLOAD);
    if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM != 0) {
        m[0].mem.data = p[0].parent.wrapped_data;
        setFlag(m, NEED_UPLOAD);
    }
    return @ptrCast(m);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const mk: *AllocClass = @ptrCast(@alignCast(k));
    const bk: *c.GstGLBaseMemoryAllocatorClass = @ptrCast(@alignCast(k));
    const ak: *c.GstAllocatorClass = @ptrCast(@alignCast(k));
    mk.map = defaultMap;
    mk.unmap = defaultUnmap;
    mk.copy = defaultCopy;
    bk.alloc = defaultAlloc;
    bk.create = texCreate;
    bk.map = texMap;
    bk.unmap = texUnmap;
    bk.copy = texCopy;
    bk.destroy = texDestroy;
    ak.alloc = texAllocPlain;
}

fn allocInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *c.GstAllocator = @ptrCast(@alignCast(inst));
    a.mem_type = NAME;
    a.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

pub export fn gst_gl_memory_allocator_get_type() c.GType {
    return alloc_once.get(struct {
        fn f() c.GType {
            return gtype.object(base.gst_gl_base_memory_allocator_get_type, "GstGLMemoryAllocator", AllocClass, Alloc, classInit, allocInit, 0);
        }
    }.f);
}

pub export fn gst_gl_memory_get_type() c.GType {
    return mem_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLMemory", @ptrCast(&c.gst_mini_object_ref), @ptrCast(&c.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_gl_memory_copy_into(m: OMem, tex_id: c.guint, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat, w: c.gint, h: c.gint) c.gboolean {
    var p = CopyParams{ .src = m, .out_format = 0, .out_width = @bitCast(w), .out_height = @bitCast(h), .tex_target = target, .tex_format = tex_format, .tex_id = tex_id, .result = 0 };
    c.gst_gl_context_thread_add(m[0].mem.context, copyThread, &p);
    return p.result;
}

fn validMem(m: OMem, comptime fname: []const u8) bool {
    return check.that(gst_is_gl_memory(@ptrCast(m)) != 0, fname, "gst_is_gl_memory ((GstMemory *) gl_mem)");
}

pub export fn gst_gl_memory_get_texture_width(m: OMem) c.gint {
    if (!validMem(m, "gst_gl_memory_get_texture_width")) return 0;
    return @bitCast(m[0].tex_width);
}

pub export fn gst_gl_memory_get_texture_height(m: OMem) c.gint {
    if (!validMem(m, "gst_gl_memory_get_texture_height")) return 0;
    return @bitCast(height(m));
}

pub export fn gst_gl_memory_get_texture_format(m: OMem) c.GstGLFormat {
    if (!validMem(m, "gst_gl_memory_get_texture_format")) return 0;
    return m[0].tex_format;
}

pub export fn gst_gl_memory_get_texture_target(m: OMem) c.GstGLTextureTarget {
    if (!validMem(m, "gst_gl_memory_get_texture_target")) return 0;
    return m[0].tex_target;
}

pub export fn gst_gl_memory_get_texture_id(m: OMem) c.guint {
    if (!validMem(m, "gst_gl_memory_get_texture_id")) return 0;
    return m[0].tex_id;
}

pub export fn gst_gl_memory_init_once() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        base.gst_gl_base_memory_init_once();
        cat = c._gst_debug_category_new("glbasetexture", 0, "OpenGL Base Texture Memory");
        default_allocator = @ptrCast(@alignCast(c.g_object_new(gst_gl_memory_allocator_get_type(), @as([*c]const u8, null))));
        _ = c.gst_object_ref_sink(default_allocator);
        c.gst_allocator_register(NAME, default_allocator);
        c.g_once_init_leave(&init_done, 1);
    }
}

pub export fn gst_is_gl_memory(mem: [*c]c.GstMemory) c.gboolean {
    return @intFromBool(mem != null and mem[0].allocator != null and c.g_type_is_a(gtype.typeOf(mem[0].allocator), gst_gl_memory_allocator_get_type()) != 0);
}

pub export fn gst_gl_video_allocation_params_get_type() c.GType {
    return vparams_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstGLVideoAllocationParams", @ptrCast(&base.gst_gl_allocation_params_copy), @ptrCast(&base.gst_gl_allocation_params_free));
        }
    }.f);
}

fn setAlign(p: OVParams, valign: [*c]const c.GstVideoAlignment) void {
    if (!check.that(p != null, "_gst_gl_video_allocation_params_set_video_alignment", "params != NULL")) return;
    if (p[0].valign == null) p[0].valign = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstVideoAlignment))));
    if (valign != null) p[0].valign[0] = valign[0] else c.gst_video_alignment_reset(p[0].valign);
}

pub export fn gst_gl_video_allocation_params_init_full(p: OVParams, struct_size: c.gsize, alloc_flags: c.guint, copy: c.GstGLAllocationParamsCopyFunc, free: c.GstGLAllocationParamsFreeFunc, ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, v_info: [*c]const c.GstVideoInfo, plane: c.guint, valign: [*c]const c.GstVideoAlignment, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat, wrapped: c.gpointer, gl_handle: c.gpointer, user_data: c.gpointer, notify: c.GDestroyNotify) c.gboolean {
    const fname = "gst_gl_video_allocation_params_init_full";
    if (!check.that(p != null, fname, "params != NULL")) return 0;
    if (!check.that(copy != null, fname, "copy != NULL")) return 0;
    if (!check.that(free != null, fname, "free != NULL")) return 0;
    if (!check.that(context.isContext(ctx), fname, "GST_IS_GL_CONTEXT (context)")) return 0;
    if (!check.that(v_info != null, fname, "v_info != NULL")) return 0;
    p[0] = std.mem.zeroes(VParams);
    if (base.gst_gl_allocation_params_init(@ptrCast(p), struct_size, alloc_flags, copy, free, ctx, 0, alloc_params, wrapped, gl_handle, user_data, notify) == 0) return 0;
    p[0].v_info = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstVideoInfo))));
    p[0].v_info[0] = v_info[0];
    setAlign(p, valign);
    p[0].target = target;
    p[0].tex_format = tex_format;
    p[0].plane = plane;
    return 1;
}

fn newParams(ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, v_info: [*c]const c.GstVideoInfo, plane: c.guint, valign: [*c]const c.GstVideoAlignment, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat, flags: c.guint, wrapped: c.gpointer, handle: c.gpointer, user_data: c.gpointer, notify: c.GDestroyNotify) OVParams {
    const p: OVParams = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(VParams))));
    if (gst_gl_video_allocation_params_init_full(p, @sizeOf(VParams), flags | c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO, @ptrCast(&gst_gl_video_allocation_params_copy_data), @ptrCast(&gst_gl_video_allocation_params_free_data), ctx, alloc_params, v_info, plane, valign, target, tex_format, wrapped, handle, user_data, notify) == 0) {
        c.g_free(p);
        return null;
    }
    return p;
}

pub export fn gst_gl_video_allocation_params_new(ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, v_info: [*c]const c.GstVideoInfo, plane: c.guint, valign: [*c]const c.GstVideoAlignment, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat) OVParams {
    return newParams(ctx, alloc_params, v_info, plane, valign, target, tex_format, c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_ALLOC, null, null, null, null);
}

pub export fn gst_gl_video_allocation_params_new_wrapped_data(ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, v_info: [*c]const c.GstVideoInfo, plane: c.guint, valign: [*c]const c.GstVideoAlignment, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat, wrapped: c.gpointer, user_data: c.gpointer, notify: c.GDestroyNotify) OVParams {
    return newParams(ctx, alloc_params, v_info, plane, valign, target, tex_format, c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM, wrapped, null, user_data, notify);
}

pub export fn gst_gl_video_allocation_params_new_wrapped_gl_handle(ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, v_info: [*c]const c.GstVideoInfo, plane: c.guint, valign: [*c]const c.GstVideoAlignment, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat, handle: c.gpointer, user_data: c.gpointer, notify: c.GDestroyNotify) OVParams {
    return newParams(ctx, alloc_params, v_info, plane, valign, target, tex_format, c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE, null, handle, user_data, notify);
}

pub export fn gst_gl_video_allocation_params_new_wrapped_texture(ctx: OCtx, alloc_params: [*c]const c.GstAllocationParams, v_info: [*c]const c.GstVideoInfo, plane: c.guint, valign: [*c]const c.GstVideoAlignment, target: c.GstGLTextureTarget, tex_format: c.GstGLFormat, tex_id: c.guint, user_data: c.gpointer, notify: c.GDestroyNotify) OVParams {
    return gst_gl_video_allocation_params_new_wrapped_gl_handle(ctx, alloc_params, v_info, plane, valign, target, tex_format, @ptrFromInt(tex_id), user_data, notify);
}

pub export fn gst_gl_video_allocation_params_free_data(p: OVParams) void {
    c.g_free(p[0].v_info);
    c.g_free(p[0].valign);
    base.gst_gl_allocation_params_free_data(&p[0].parent);
}

pub export fn gst_gl_video_allocation_params_copy_data(src: OVParams, dest: OVParams) void {
    base.gst_gl_allocation_params_copy_data(&src[0].parent, &dest[0].parent);
    dest[0].v_info = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstVideoInfo))));
    dest[0].v_info[0] = src[0].v_info[0];
    setAlign(dest, src[0].valign);
    dest[0].target = src[0].target;
    dest[0].tex_format = src[0].tex_format;
    dest[0].plane = src[0].plane;
}

pub export fn gst_gl_memory_setup_buffer(allocator: [*c]Alloc, buffer: [*c]c.GstBuffer, p: OVParams, tex_formats: [*c]c.GstGLFormat, wrapped: [*c]c.gpointer, n_wrapped: c.gsize) c.gboolean {
    const fname = "gst_gl_memory_setup_buffer";
    const flags = p[0].parent.alloc_flags;
    if (!check.that(p != null, fname, "params != NULL")) return 0;
    if (!check.that(flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO != 0, fname, "alloc_flags & GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_VIDEO")) return 0;
    const vi = p[0].v_info;
    var n_mem: c.guint = vi[0].finfo[0].n_planes;
    const views: c.guint = if (vi[0].ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED) @bitCast(vi[0].views) else 1;
    if (n_wrapped == views) n_mem = 1;
    if (!check.that(wrapped == null or n_mem * views == n_wrapped, fname, "!wrapped_data || n_mem * views == n_wrapped_pointers")) return 0;
    var v: c.guint = 0;
    while (v < views) : (v += 1) {
        var i: c.guint = 0;
        while (i < n_mem) : (i += 1) {
            p[0].tex_format = if (tex_formats != null) tex_formats[i] else format.gst_gl_format_from_video_info(p[0].parent.context, vi, i);
            p[0].plane = i;
            if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_SYSMEM != 0) {
                if (!check.that(wrapped != null, fname, "wrapped_data != NULL")) return 0;
                p[0].parent.wrapped_data = wrapped[i];
            } else if (flags & c.GST_GL_ALLOCATION_PARAMS_ALLOC_FLAG_WRAP_GPU_HANDLE != 0) {
                if (!check.that(wrapped != null, fname, "wrapped_data != NULL")) return 0;
                p[0].parent.gl_handle = wrapped[i];
            }
            const m = base.gst_gl_base_memory_alloc(@ptrCast(allocator), @ptrCast(p));
            if (m == null) return 0;
            c.gst_buffer_append_memory(buffer, @ptrCast(m));
        }
        const meta = c.gst_buffer_add_video_meta_full(buffer, v, vi[0].finfo[0].format, @bitCast(vi[0].width), @bitCast(vi[0].height), n_mem, &vi[0].offset, &vi[0].stride);
        if (p[0].valign != null) _ = c.gst_video_meta_set_alignment(meta, p[0].valign[0]);
    }
    return 1;
}

pub export fn gst_gl_memory_allocator_get_default(ctx: OCtx) [*c]Alloc {
    if (!check.that(context.isContext(ctx), "gst_gl_memory_allocator_get_default", "GST_IS_GL_CONTEXT (context)")) return null;
    const name: [*c]const u8 = if (ver(ctx, c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3 | c.GST_GL_API_GLES2, 3, 0) != 0) PBO_NAME else NAME;
    return @ptrCast(@alignCast(c.gst_allocator_find(name)));
}
