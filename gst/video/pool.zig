const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const info = @import("info.zig");
const dma = @import("dma.zig");
const meta = @import("meta.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Pool = c.GstVideoBufferPool;
const Class = c.GstVideoBufferPoolClass;
const BPClass = c.GstBufferPoolClass;

const Private = struct {
    info: c.GstVideoInfo,
    video_align: c.GstVideoAlignment,
    add_videometa: bool,
    need_alignment: bool,
    allocator: ?*c.GstAllocator,
    params: c.GstAllocationParams,
};

var once: gtype.Once = .{};
var parent: ?*BPClass = null;
var offset_: c.gint = 0;

fn priv(p: anytype) *Private {
    const v: [*c]Pool = @ptrCast(@alignCast(p));
    return @ptrCast(@alignCast(v[0].priv));
}

var options = [_][*c]const u8{ "GstBufferPoolOptionVideoMeta", "GstBufferPoolOptionVideoAlignment", null };

fn getOptions(_: [*c]c.GstBufferPool) callconv(.c) [*c][*c]const u8 {
    return &options;
}

fn setConfig(pool: [*c]c.GstBufferPool, config: ?*c.GstStructure) callconv(.c) c.gboolean {
    const p = priv(pool);
    var caps: [*c]c.GstCaps = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    if (c.gst_buffer_pool_config_get_params(config, &caps, &size, &min, &max) == 0) return 0;
    if (caps == null) return 0;
    var vi: c.GstVideoInfo = undefined;
    if (dma.gst_video_is_dma_drm_caps(caps) != 0) {
        var d: c.GstVideoInfoDmaDrm = undefined;
        if (dma.gst_video_info_dma_drm_from_caps(&d, caps) == 0) return 0;
        if (d.vinfo.finfo[0].format == c.GST_VIDEO_FORMAT_DMA_DRM) return 0;
        vi = d.vinfo;
    } else if (info.gst_video_info_from_caps(&vi, caps) == 0) return 0;
    if (size < vi.size) {
        c.gst_buffer_pool_config_set_params(config, caps, @truncate(vi.size), min, max);
        return 0;
    }
    var allocator: ?*c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    if (c.gst_buffer_pool_config_get_allocator(config, &allocator, &params) == 0) return 0;
    p.params = params;
    if (p.allocator) |a| c.gst_object_unref(a);
    p.allocator = allocator;
    if (allocator) |a| _ = c.gst_object_ref(a);
    p.add_videometa = c.gst_buffer_pool_config_has_option(config, "GstBufferPoolOptionVideoMeta") != 0;
    p.need_alignment = c.gst_buffer_pool_config_has_option(config, "GstBufferPoolOptionVideoAlignment") != 0;
    if (p.need_alignment and p.add_videometa) {
        _ = meta.gst_buffer_pool_config_get_video_alignment(config, &p.video_align);
        var max_align: c.guint = @truncate(p.params.@"align");
        for (p.video_align.stride_align) |s| max_align |= s;
        for (&p.video_align.stride_align) |*s| s.* = max_align;
        if (info.gst_video_info_align(&vi, &p.video_align) == 0) return 0;
        meta.gst_buffer_pool_config_set_video_alignment(config, &p.video_align);
        if (p.params.@"align" < max_align) {
            p.params.@"align" = max_align;
            c.gst_buffer_pool_config_set_allocator(config, allocator, &p.params);
        }
    }
    vi.size = @max(size, vi.size);
    p.info = vi;
    c.gst_buffer_pool_config_set_params(config, caps, @truncate(vi.size), min, max);
    return parent.?.set_config.?(pool, config);
}

fn alloc(pool: [*c]c.GstBufferPool, buffer: [*c][*c]c.GstBuffer, _: [*c]c.GstBufferPoolAcquireParams) callconv(.c) c.GstFlowReturn {
    const p = priv(pool);
    const vi = &p.info;
    buffer.* = c.gst_buffer_new_allocate(p.allocator, vi.size, &p.params);
    if (buffer.* == null) return c.GST_FLOW_ERROR;
    if (p.add_videometa) _ = meta.gst_buffer_add_video_meta_full(buffer.*, c.GST_VIDEO_FRAME_FLAG_NONE, vi.finfo[0].format, @bitCast(vi.width), @bitCast(vi.height), vi.finfo[0].n_planes, &vi.offset, &vi.stride);
    return c.GST_FLOW_OK;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p = priv(o);
    if (p.allocator) |a| c.gst_object_unref(a);
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const bc: *BPClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    bc.get_options = getOptions;
    bc.set_config = setConfig;
    bc.alloc_buffer = alloc;
    _ = c._gst_debug_category_new("videopool", 0, "videopool object");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const v: [*c]Pool = @ptrCast(@alignCast(inst));
    v[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    const p = priv(v);
    p.* = std.mem.zeroes(Private);
}

pub export fn gst_video_buffer_pool_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_buffer_pool_get_type, "GstVideoBufferPool", Class, Pool, classInit, init, 0);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

pub export fn gst_video_buffer_pool_new() [*c]c.GstBufferPool {
    const pool = c.g_object_new(gst_video_buffer_pool_get_type(), null);
    _ = c.gst_object_ref_sink(pool);
    return @ptrCast(@alignCast(pool));
}
