const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

var once: usize = 0;

pub fn init() void {
    if (c.g_once_init_enter(&once) != 0) {
        _ = c._gst_debug_category_new("gstopengl", 0, "gstopengl");
        if (c.g_getenv("GST_GL_XINITTHREADS") != null or c.g_getenv("GST_XINITTHREADS") != null) _ = c.XInitThreads();
        c.g_once_init_leave(&once, 1);
    }
}

pub fn register(p: ?*c.GstPlugin, name: [*:0]const u8, rank: c.guint, t: c.GType) bool {
    init();
    return c.gst_element_register(p, name, rank, t) != 0;
}

pub fn baseTransformClass(k: anytype) *c.GstBaseTransformClass {
    return @ptrCast(@alignCast(k));
}

pub fn parentOf(comptime T: type, k: c.gpointer) *T {
    return @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
}

pub fn unitSize(_: [*c]c.GstBaseTransform, caps: [*c]c.GstCaps, size: [*c]usize) callconv(.c) c.gboolean {
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) != 0) size.* = info.size;
    return 1;
}

pub fn keepMeta(_: [*c]c.GstBaseTransform, _: [*c]c.GstQuery, _: c.GType, _: ?*const c.GstStructure) callconv(.c) c.gboolean {
    return 1;
}

pub fn noTransform(_: [*c]c.GstBaseTransform, _: [*c]c.GstBuffer, _: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return c.GST_FLOW_OK;
}

pub fn videoTagsOnly(meta: [*c]c.GstMeta, comptime colorspace: bool) bool {
    const tags = if (colorspace)
        [_][*c]const u8{ c.GST_META_TAG_VIDEO_STR, c.GST_META_TAG_VIDEO_ORIENTATION_STR, c.GST_META_TAG_VIDEO_SIZE_STR, c.GST_META_TAG_VIDEO_COLORSPACE_STR, null }
    else
        [_][*c]const u8{ c.GST_META_TAG_VIDEO_STR, c.GST_META_TAG_VIDEO_ORIENTATION_STR, c.GST_META_TAG_VIDEO_SIZE_STR, null };
    return c.gst_meta_api_type_tags_contain_only(meta[0].info[0].api, @ptrCast(@constCast(&tags))) != 0;
}

pub fn base(p: anytype) *c.GstGLBaseFilter {
    return @ptrCast(@alignCast(p));
}

pub const SIZE = "(int) [ 1, max ]";
pub const FPS = "(fraction) [ 0, max ]";
pub const DMA_DRM_CAPS = "video/x-raw(memory:DMABuf), format = (string) DMA_DRM, width = " ++ SIZE ++ ", height = " ++ SIZE ++ ", framerate = " ++ FPS;

pub fn capsWithFeatures(comptime features: []const u8, comptime format: []const u8) [:0]const u8 {
    return "video/x-raw(" ++ features ++ "), format = (string) " ++ format ++ ", width = " ++ SIZE ++ ", height = " ++ SIZE ++ ", framerate = " ++ FPS;
}

pub fn syncValues(bt: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) void {
    const st = c.gst_segment_to_stream_time(&bt[0].segment, c.GST_FORMAT_TIME, b[0].pts);
    if (st != std.math.maxInt(u64)) _ = c.gst_object_sync_values(@ptrCast(bt), st);
}

const Compile = struct {
    shader: *?*c.GstGLShader,
    vert: ?[*:0]const u8,
    frag: ?[*:0]const u8,
};

fn stage(ctx: [*c]c.GstGLContext, shader: ?*c.GstGLShader, kind: c.guint, src: [*:0]const u8) bool {
    var err: [*c]c.GError = null;
    const st = c.gst_glsl_stage_new_with_string(ctx, kind, c.GST_GLSL_VERSION_NONE, c.GST_GLSL_PROFILE_ES | c.GST_GLSL_PROFILE_COMPATIBILITY, src);
    if (c.gst_glsl_stage_compile(st, &err) == 0) {
        c.g_clear_error(&err);
        c.gst_object_unref(st);
        return false;
    }
    return c.gst_gl_shader_attach(shader, st) != 0;
}

fn compile(ctx: [*c]c.GstGLContext, data: c.gpointer) callconv(.c) void {
    const d: *Compile = @ptrCast(@alignCast(data));
    const shader = c.gst_gl_shader_new(ctx);
    if (d.vert) |v| if (!stage(ctx, shader, c.GL_VERTEX_SHADER, v)) {
        c.gst_object_unref(shader);
        return;
    };
    if (d.frag) |f| if (!stage(ctx, shader, c.GL_FRAGMENT_SHADER, f)) {
        c.gst_object_unref(shader);
        return;
    };
    var err: [*c]c.GError = null;
    if (c.gst_gl_shader_link(shader, &err) == 0) {
        c.g_clear_error(&err);
        c.gst_gl_context_clear_shader(ctx);
        c.gst_object_unref(shader);
        return;
    }
    d.shader.* = shader;
}

pub fn genShader(ctx: [*c]c.GstGLContext, vert: ?[*:0]const u8, frag: ?[*:0]const u8, shader: *?*c.GstGLShader) c.gboolean {
    if (!cm.that(frag != null or vert != null, "gst_gl_context_gen_shader", "frag_src != NULL || vert_src != NULL")) return 0;
    var d = Compile{ .shader = shader, .vert = vert, .frag = frag };
    c.gst_gl_context_thread_add(ctx, compile, &d);
    return @intFromBool(shader.* != null);
}

const pads = @import("../audiomixer/pads.zig");

pub const VPad = extern struct {
    parent: pads.AggPad,
    info: c.GstVideoInfo,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

pub const MixerPad = extern struct {
    parent: VPad,
    base_padding: [4]c.gpointer,
    current_texture: c.guint,
    padding: [4]c.gpointer,
};

pub fn padName(p: anytype) [*c]u8 {
    return @as(*c.GstObject, @ptrCast(@alignCast(p))).name;
}

fn childByIndex(proxy: ?*c.GstChildProxy, index: c.guint) callconv(.c) [*c]c.GObject {
    const e: *c.GstElement = @ptrCast(@alignCast(proxy));
    cm.lock(e);
    defer cm.unlock(e);
    const obj = c.g_list_nth_data(e.sinkpads, index);
    if (obj != null) _ = c.gst_object_ref(obj);
    return @ptrCast(@alignCast(obj));
}

fn childCount(proxy: ?*c.GstChildProxy) callconv(.c) c.guint {
    const e: *c.GstElement = @ptrCast(@alignCast(proxy));
    cm.lock(e);
    defer cm.unlock(e);
    return e.numsinkpads;
}

fn proxyInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstChildProxyInterface = @ptrCast(@alignCast(iface));
    i.get_child_by_index = childByIndex;
    i.get_children_count = childCount;
}

pub fn addSinkpadProxy(t: c.GType) void {
    const info = c.GInterfaceInfo{ .interface_init = proxyInit, .interface_finalize = null, .interface_data = null };
    c.g_type_add_interface_static(t, c.gst_child_proxy_get_type(), &info);
}

pub fn requestPadAnnounced(parent: *c.GstElementClass, e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, caps: ?*const c.GstCaps) ?*c.GstPad {
    const pad = parent.request_new_pad.?(e, templ, name, caps) orelse return null;
    c.gst_child_proxy_child_added(@ptrCast(e), @ptrCast(@alignCast(pad)), padName(pad));
    return pad;
}

pub fn releasePadAnnounced(parent: *c.GstElementClass, e: [*c]c.GstElement, pad: ?*c.GstPad) void {
    c.gst_child_proxy_child_removed(@ptrCast(e), @ptrCast(@alignCast(pad)), padName(pad));
    parent.release_pad.?(e, pad);
}
