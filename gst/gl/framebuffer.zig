const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const base = @import("basememory.zig");
const memory = @import("memory.zig");
const format = @import("format.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Fb = c.GstGLFramebuffer;
const OFb = [*c]Fb;
const OCtx = [*c]c.GstGLContext;
const READ_FRAMEBUFFER = 0x8CA8;
const DRAW_FRAMEBUFFER = 0x8CA9;
const DEPTH_STENCIL_ATTACHMENT = 0x821A;

const Priv = struct {
    effective_width: c.guint,
    effective_height: c.guint,
};

const Attachment = extern struct {
    point: c.guint,
    mem: [*c]c.GstGLBaseMemory,
};

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn pv(fb: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Fb, @ptrCast(@alignCast(fb))).priv));
}

fn valid(fb: anytype, comptime fname: []const u8) bool {
    return check.that(gtype.instanceOf(fb, gst_gl_framebuffer_get_type()), fname, "GST_IS_GL_FRAMEBUFFER (fb)");
}

fn current(ctx: OCtx, comptime fname: []const u8, comptime expr: []const u8) bool {
    return check.that(context.gst_gl_context_get_current() == ctx, fname, expr);
}

fn unsetAttachment(data: c.gpointer) callconv(.c) void {
    if (data == null) return;
    const a: *Attachment = @ptrCast(@alignCast(data));
    if (a.mem != null) c.gst_memory_unref(@ptrCast(a.mem));
    a.mem = null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const fb: *Fb = @ptrCast(@alignCast(inst));
    fb.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(fb).* = .{ .effective_width = 0, .effective_height = 0 };
    fb.attachments = c.g_array_new(0, 0, @sizeOf(Attachment));
    c.g_array_set_clear_func(fb.attachments, unsetAttachment);
}

fn deleteFbo(ctx: OCtx, data: c.gpointer) callconv(.c) void {
    const fb: *Fb = @ptrCast(@alignCast(data));
    if (fb.fbo_id != 0) ctx[0].gl_vtable[0].DeleteFramebuffers.?(1, &fb.fbo_id);
    fb.fbo_id = 0;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const fb: *Fb = @ptrCast(@alignCast(o));
    if (fb.context != null) {
        if (fb.fbo_id != 0) c.gst_gl_context_thread_add(fb.context, deleteFbo, fb);
        c.gst_object_unref(fb.context);
        fb.context = null;
    }
    if (fb.attachments != null) _ = c.g_array_free(fb.attachments, 1);
    fb.attachments = null;
    parent.?.finalize.?(o);
}

pub export fn gst_gl_framebuffer_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLFramebuffer", c.GstGLFramebufferClass, Fb, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glframebuffer", 0, "GL Framebuffer");
            return t;
        }
    }.f);
}

pub export fn gst_gl_framebuffer_new(ctx: OCtx) OFb {
    const fname = "gst_gl_framebuffer_new";
    if (!check.that(context.isContext(ctx), fname, "GST_IS_GL_CONTEXT (context)")) return null;
    if (!current(ctx, fname, "gst_gl_context_get_current () == context")) return null;
    const gl = &ctx[0].gl_vtable[0];
    if (gl.GenFramebuffers == null) return null;
    const fb: OFb = @ptrCast(@alignCast(c.g_object_new(gst_gl_framebuffer_get_type(), @as([*c]const u8, null))));
    fb[0].context = @ptrCast(@alignCast(c.gst_object_ref(ctx)));
    gl.GenFramebuffers.?(1, &fb[0].fbo_id);
    _ = c.gst_object_ref_sink(fb);
    return fb;
}

pub export fn gst_gl_framebuffer_new_with_default_depth(ctx: OCtx, width: c.guint, height: c.guint) OFb {
    const fb = gst_gl_framebuffer_new(ctx);
    if (fb == null) return null;
    const api = context.gst_gl_context_get_gl_api(fb[0].context);
    var point: c.guint = 0;
    var kind: c.GstGLFormat = 0;
    if (api & (c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3) != 0) {
        point = DEPTH_STENCIL_ATTACHMENT;
        kind = c.GST_GL_DEPTH24_STENCIL8;
    } else if (api & c.GST_GL_API_GLES2 != 0) {
        point = c.GL_DEPTH_ATTACHMENT;
        kind = c.GST_GL_DEPTH_COMPONENT16;
    } else check.assertFail("gstglframebuffer.c", 239, "gst_gl_framebuffer_new_with_default_depth", null);
    const ra: [*c]c.GstGLBaseMemoryAllocator = @ptrCast(@alignCast(c.gst_allocator_find("GLRenderbuffer")));
    const params: [*c]c.GstGLAllocationParams = @ptrCast(c.gst_gl_renderbuffer_allocation_params_new(ctx, null, kind, width, height));
    const rb = base.gst_gl_base_memory_alloc(ra, params);
    base.gst_gl_allocation_params_free(params);
    c.gst_object_unref(ra);
    gst_gl_framebuffer_bind(fb);
    gst_gl_framebuffer_attach(fb, point, rb);
    gst_gl_context_clear_framebuffer(fb[0].context);
    c.gst_memory_unref(@ptrCast(rb));
    return fb;
}

pub export fn gst_gl_framebuffer_draw_to_texture(fb: OFb, mem: [*c]c.GstGLMemory, func: c.GstGLFramebufferFunc, data: c.gpointer) c.gboolean {
    const fname = "gst_gl_framebuffer_draw_to_texture";
    if (!valid(fb, fname)) return 0;
    if (!check.that(memory.gst_is_gl_memory(@ptrCast(mem)) != 0, fname, "gst_is_gl_memory (GST_MEMORY_CAST (mem))")) return 0;
    if (!current(fb[0].context, fname, "gst_gl_context_get_current () == fb->context")) return 0;
    const gl = &fb[0].context[0].gl_vtable[0];
    gst_gl_framebuffer_bind(fb);
    gst_gl_framebuffer_attach(fb, c.GL_COLOR_ATTACHMENT0, @ptrCast(mem));
    gl.Viewport.?(0, 0, @bitCast(pv(fb).effective_width), @bitCast(pv(fb).effective_height));
    const big = context.gst_gl_context_get_gl_api(fb[0].context) & (c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3) != 0;
    if (big) gl.DrawBuffer.?(c.GL_COLOR_ATTACHMENT0);
    const r = func.?(data);
    if (big) gl.DrawBuffer.?(c.GL_COLOR_ATTACHMENT0);
    gst_gl_context_clear_framebuffer(fb[0].context);
    return r;
}

pub export fn gst_gl_framebuffer_bind(fb: OFb) void {
    const fname = "gst_gl_framebuffer_bind";
    if (!valid(fb, fname)) return;
    if (!current(fb[0].context, fname, "gst_gl_context_get_current () == fb->context")) return;
    if (!check.that(fb[0].fbo_id != 0, fname, "fb->fbo_id != 0")) return;
    fb[0].context[0].gl_vtable[0].BindFramebuffer.?(c.GL_FRAMEBUFFER, fb[0].fbo_id);
}

pub export fn gst_gl_context_clear_framebuffer(ctx: OCtx) void {
    if (!check.that(context.isContext(ctx), "gst_gl_context_clear_framebuffer", "GST_IS_GL_CONTEXT (context)")) return;
    ctx[0].gl_vtable[0].BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
}

fn attachments(fb: OFb) []Attachment {
    const a = fb[0].attachments;
    if (a[0].len == 0) return &.{};
    return @as([*]Attachment, @ptrCast(@alignCast(a[0].data)))[0..a[0].len];
}

fn updateDimensions(fb: OFb) void {
    var mw: c.guint = std.math.maxInt(c.guint);
    var mh: c.guint = std.math.maxInt(c.guint);
    for (attachments(fb)) |a| {
        var w: c.gint = 0;
        var h: c.gint = 0;
        if (memory.gst_is_gl_memory(@ptrCast(a.mem)) != 0) {
            w = memory.gst_gl_memory_get_texture_width(@ptrCast(a.mem));
            h = memory.gst_gl_memory_get_texture_height(@ptrCast(a.mem));
        } else if (c.gst_is_gl_renderbuffer(@ptrCast(a.mem)) != 0) {
            const rb: [*c]c.GstGLRenderbuffer = @ptrCast(@alignCast(a.mem));
            w = @bitCast(rb[0].width);
            h = @bitCast(rb[0].height);
        } else check.assertFail("gstglframebuffer.c", 386, "_update_effective_dimensions", null);
        if (@as(c.guint, @bitCast(w)) < mw) mw = @bitCast(w);
        if (@as(c.guint, @bitCast(h)) < mh) mh = @bitCast(h);
    }
    pv(fb).effective_width = mw;
    pv(fb).effective_height = mh;
}

fn validPoint(p: c.guint) bool {
    return (p >= 0x8CE0 and p <= 0x8CFF) or p == 0x821A or p == 0x8D00 or p == 0x8D20;
}

fn append(fb: OFb, point: c.guint, mem: [*c]c.GstGLBaseMemory) void {
    var a = Attachment{ .point = point, .mem = @ptrCast(@alignCast(c.gst_memory_ref(@ptrCast(mem)))) };
    fb[0].attachments = c.g_array_append_vals(fb[0].attachments, &a, 1);
}

pub export fn gst_gl_framebuffer_attach(fb: OFb, point: c.guint, mem: [*c]c.GstGLBaseMemory) void {
    const fname = "gst_gl_framebuffer_attach";
    if (!valid(fb, fname)) return;
    if (!current(fb[0].context, fname, "gst_gl_context_get_current () == fb->context")) return;
    if (!check.that(validPoint(point), fname, "_is_valid_attachment_point (attachment_point)")) return;
    for (attachments(fb), 0..) |a, i| {
        if (a.point == point) {
            _ = c.g_array_remove_index_fast(fb[0].attachments, @intCast(i));
            break;
        }
    }
    const gl = &fb[0].context[0].gl_vtable[0];
    if (memory.gst_is_gl_memory(@ptrCast(mem)) != 0) {
        const m: [*c]c.GstGLMemory = @ptrCast(@alignCast(mem));
        gst_gl_framebuffer_bind(fb);
        gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, point, format.gst_gl_texture_target_to_gl(m[0].tex_target), m[0].tex_id, 0);
        append(fb, point, mem);
    } else if (c.gst_is_gl_renderbuffer(@ptrCast(mem)) != 0) {
        const rb: [*c]c.GstGLRenderbuffer = @ptrCast(@alignCast(mem));
        gst_gl_framebuffer_bind(fb);
        gl.BindRenderbuffer.?(c.GL_RENDERBUFFER, rb[0].renderbuffer_id);
        gl.FramebufferRenderbuffer.?(c.GL_FRAMEBUFFER, point, c.GL_RENDERBUFFER, rb[0].renderbuffer_id);
        append(fb, point, mem);
    } else check.assertFail("gstglframebuffer.c", 497, "gst_gl_framebuffer_attach", null);
    updateDimensions(fb);
}

pub export fn gst_gl_framebuffer_get_effective_dimensions(fb: OFb, width: [*c]c.guint, height: [*c]c.guint) void {
    if (!valid(fb, "gst_gl_framebuffer_get_effective_dimensions")) return;
    if (width != null) width[0] = pv(fb).effective_width;
    if (height != null) height[0] = pv(fb).effective_height;
}

pub export fn gst_gl_context_check_framebuffer_status(ctx: OCtx, target: c.guint) c.gboolean {
    const fname = "gst_gl_context_check_framebuffer_status";
    if (!check.that(context.isContext(ctx), fname, "GST_IS_GL_CONTEXT (context)")) return 0;
    if (!current(ctx, fname, "gst_gl_context_get_current () == context")) return 0;
    if (target != c.GL_FRAMEBUFFER and target != READ_FRAMEBUFFER and target != DRAW_FRAMEBUFFER) return 0;
    if (!context.debugEnabled()) return 1;
    const r = ctx[0].gl_vtable[0].CheckFramebufferStatus.?(target);
    if (r == c.GL_FRAMEBUFFER_COMPLETE) return 1;
    if (r == 0) _ = ctx[0].gl_vtable[0].GetError.?();
    return 0;
}

pub export fn gst_gl_framebuffer_get_id(fb: OFb) c.guint {
    if (!valid(fb, "gst_gl_framebuffer_get_id")) return 0;
    return fb[0].fbo_id;
}
