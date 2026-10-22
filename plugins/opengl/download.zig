const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");
const pool = @import("dmabufpool.zig");

const FILE = "../ext/gl/gstgldownloadelement.c";
const DMABUF = c.GST_CAPS_FEATURE_MEMORY_DMABUF;

const Mode = enum(c_int) { passthrough, pbo, dmabuf, nvmm };

const Self = extern struct {
    parent: c.GstGLBaseFilter,
    mode: Mode,
    try_dmabuf: c.gint,
    dmabuf_allocator: [*c]c.GstAllocator,
    foreign_pool: [*c]c.GstBufferPool,
    foreign_caps: [*c]c.GstCaps,
    add_videometa: c.gboolean,
};

const Class = extern struct {
    parent: c.GstGLBaseFilterClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "video/x-raw(" ++ DMABUF ++ "); video/x-raw; video/x-raw(memory:GLMemory)");
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "video/x-raw(memory:GLMemory); video/x-raw");
var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn start(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(bt);
    s.dmabuf_allocator = c.gst_dmabuf_allocator_new();
    c.g_atomic_int_set(&s.try_dmabuf, 1);
    return 1;
}

fn clearForeign(s: *Self) void {
    if (s.foreign_pool != null) c.gst_object_unref(s.foreign_pool);
    s.foreign_pool = null;
    if (s.foreign_caps != null) c.gst_caps_unref(s.foreign_caps);
    s.foreign_caps = null;
}

fn stop(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(bt);
    if (s.dmabuf_allocator != null) c.gst_object_unref(s.dmabuf_allocator);
    s.dmabuf_allocator = null;
    clearForeign(s);
    return 1;
}

fn setCaps(bt: [*c]c.GstBaseTransform, _: [*c]c.GstCaps, out: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bt);
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, out) == 0) return 0;
    const f = c.gst_caps_get_features(out, 0);
    if (c.gst_caps_features_contains(f, c.GST_CAPS_FEATURE_MEMORY_GL_MEMORY) != 0) {
        s.mode = .passthrough;
    } else if (c.g_atomic_int_get(&s.try_dmabuf) != 0 and c.gst_caps_features_contains(f, DMABUF) != 0) {
        s.mode = .dmabuf;
    } else s.mode = .pbo;
    return 1;
}

fn holdsString(v: [*c]const c.GValue) bool {
    return v != null and c.g_type_check_value_holds(@constCast(v), c.G_TYPE_STRING) != 0;
}

fn convertDrm(ctx: ?*c.GstGLContext, s: ?*c.GstStructure) bool {
    const fmt = c.gst_structure_get_value(s, "format");
    if (fmt == null) return false;
    if (holdsString(fmt) and c.g_str_equal(c.g_value_get_string(fmt), "DMA_DRM") != 0) {
        const drm = c.gst_structure_get_value(s, "drm-format");
        var v = std.mem.zeroes(c.GValue);
        if (ctx == null or c.gst_gl_dma_buf_transform_drm_formats_to_gst_formats(ctx, drm, c.GST_GL_DRM_FORMAT_INCLUDE_EMULATED | c.GST_GL_DRM_FORMAT_DIRECT_IMPORT, &v) == 0) return false;
        c.gst_structure_set_value(s, "format", &v);
        c.gst_structure_remove_field(s, "drm-format");
        c.g_value_unset(&v);
        return true;
    }
    var v = std.mem.zeroes(c.GValue);
    if (ctx == null) {
        c.gst_structure_remove_field(s, "drm-format");
    } else if (c.gst_gl_dma_buf_transform_gst_formats_to_drm_formats(ctx, fmt, c.GST_GL_DRM_FORMAT_DIRECT_IMPORT, &v) != 0) {
        c.gst_structure_set_value(s, "drm-format", &v);
        c.g_value_unset(&v);
    } else return false;
    c.gst_structure_set(s, "format", c.G_TYPE_STRING, c.gst_video_format_to_string(c.GST_VIDEO_FORMAT_DMA_DRM), @as(?*anyopaque, null));
    return true;
}

fn withFeature(ctx: ?*c.GstGLContext, caps: [*c]const c.GstCaps, feature: [*:0]const u8) [*c]c.GstCaps {
    const out = c.gst_caps_new_empty();
    const to_dmabuf = c.g_str_equal(feature, DMABUF) != 0;
    const n = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const s = c.gst_structure_copy(c.gst_caps_get_structure(caps, i));
        const from_dmabuf = c.gst_caps_features_contains(c.gst_caps_get_features(caps, i), DMABUF) != 0;
        if (to_dmabuf != from_dmabuf and !convertDrm(ctx, s)) {
            c.gst_structure_free(s);
            continue;
        }
        c.gst_caps_append_structure_full(out, s, c.gst_caps_features_new_single_static_str(feature));
    }
    return out;
}

fn removeField(caps: [*c]c.GstCaps, field: [*:0]const u8) void {
    const n = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < n) : (i += 1) c.gst_structure_remove_field(c.gst_caps_get_structure(caps, i), field);
}

fn transformCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const bf = el.base(bt);
    if (bf.display != null and c.gst_gl_base_filter_find_gl_context(bf) == 0) return null;
    const ctx = c.gst_gl_base_filter_get_gl_context(bf);
    defer if (ctx != null) c.gst_object_unref(ctx);
    var tmp: [*c]c.GstCaps = null;
    if (dir == c.GST_PAD_SRC) {
        const sys = c.gst_caps_simplify(withFeature(ctx, caps, c.GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY));
        tmp = withFeature(ctx, sys, c.GST_CAPS_FEATURE_MEMORY_GL_MEMORY);
        tmp = c.gst_caps_merge(tmp, sys);
    } else {
        tmp = @ptrCast(c.gst_mini_object_ref(@ptrCast(caps)));
        var more = withFeature(ctx, caps, DMABUF);
        removeField(more, "texture-target");
        tmp = c.gst_caps_merge(tmp, more);
        more = withFeature(ctx, caps, c.GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY);
        removeField(more, "texture-target");
        tmp = c.gst_caps_merge(tmp, more);
    }
    if (filter == null) return tmp;
    const r = c.gst_caps_intersect_full(filter, tmp, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(tmp);
    return r;
}

fn fixateCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, other: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bt);
    var cc = caps;
    if (dir == c.GST_PAD_SINK and c.g_atomic_int_get(&s.try_dmabuf) == 0) {
        var i: c.gint = 0;
        while (i < c.gst_caps_get_size(other)) : (i += 1) {
            const f = c.gst_caps_get_features(other, @intCast(i));
            if (f != null and c.gst_caps_features_contains(f, DMABUF) != 0) {
                cc = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(other)));
                c.gst_caps_remove_structure(other, @intCast(i));
                i -= 1;
            }
        }
    }
    return parent.fixate_caps.?(bt, dir, cc, other);
}

const Info = struct {
    mem: [*c]c.GstMemory,
    stride: c.gint,
    offset: usize,
};

var info_quark: c.GQuark = 0;

fn quark() c.GQuark {
    if (info_quark == 0) info_quark = c.g_quark_from_static_string("GstGLDownloadDmabufInfo");
    return info_quark;
}

fn freeInfo(p: c.gpointer) callconv(.c) void {
    const i: *Info = @ptrCast(@alignCast(p));
    c.gst_memory_unref(i.mem);
    c.g_free(i);
}

const Transfer = struct {
    dl: *Self,
    mem: [*c]c.GstGLMemory,
    info: ?*Info = null,
};

fn makeInfo(ctx: ?*c.GstGLContext, data: c.gpointer) callconv(.c) void {
    const t: *Transfer = @ptrCast(@alignCast(data));
    const img = c.gst_egl_image_from_texture(ctx, t.mem, null);
    if (img == null) return;
    defer c.gst_egl_image_unref(img);
    var fd: c_int = 0;
    var stride: c.gint = 0;
    var offset: usize = 0;
    if (c.gst_egl_image_export_dmabuf(img, &fd, &stride, &offset) == 0) return;
    const size = @as(usize, @intCast(c.gst_gl_memory_get_texture_height(t.mem))) * @as(usize, @intCast(stride)) + offset;
    const i: *Info = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Info))));
    i.mem = c.gst_dmabuf_allocator_alloc_with_flags(t.dl.dmabuf_allocator, fd, size, c.GST_FD_MEMORY_FLAG_KEEP_MAPPED);
    i.stride = stride;
    i.offset = offset;
    t.info = i;
}

fn exportDmabuf(dl: *Self, in: [*c]c.GstBuffer) [*c]c.GstBuffer {
    var mem: [*c]c.GstGLMemory = @ptrCast(@alignCast(c.gst_buffer_peek_memory(in, 0)));
    var alig: [*c]c.GstVideoAlignment = null;
    if (mem != null) {
        if (c.gst_gl_context_get_gl_platform(mem[0].mem.context) != c.GST_GL_PLATFORM_EGL) return null;
        alig = &mem[0].valign;
    }
    const src_caps = c.gst_pad_get_current_caps(@as([*c]c.GstBaseTransform, @ptrCast(dl))[0].srcpad);
    defer if (src_caps != null) c.gst_caps_unref(src_caps);
    var drm: c.GstVideoInfoDmaDrm = undefined;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_dma_drm_from_caps(&drm, src_caps) == 0 or c.gst_video_info_dma_drm_to_video_info(&drm, &info) == 0) return null;
    var b = c.gst_buffer_new();
    var offsets: [c.GST_VIDEO_MAX_PLANES]usize = undefined;
    var strides: [c.GST_VIDEO_MAX_PLANES]c.gint = undefined;
    var total: usize = 0;
    const n = c.gst_buffer_n_memory(in);
    for (0..n) |i| {
        mem = @ptrCast(@alignCast(c.gst_buffer_peek_memory(in, @intCast(i))));
        var cached: ?*Info = @ptrCast(@alignCast(c.gst_mini_object_get_qdata(@ptrCast(mem), quark())));
        if (cached == null) {
            var t = Transfer{ .dl = dl, .mem = mem };
            c.gst_gl_context_thread_add(mem[0].mem.context, makeInfo, &t);
            cached = t.info;
            if (cached) |x| c.gst_mini_object_set_qdata(@ptrCast(mem), quark(), x, freeInfo);
        }
        const x = cached orelse {
            c.gst_buffer_unref(b);
            return null;
        };
        offsets[i] = total + x.offset;
        strides[i] = x.stride;
        total += c.gst_memory_get_sizes(x.mem, null, null);
        c.gst_buffer_insert_memory(b, -1, c.gst_memory_ref(x.mem));
    }
    if (dl.add_videometa != 0) {
        const vm = c.gst_buffer_add_video_meta_full(b, c.GST_VIDEO_FRAME_FLAG_NONE, info.finfo[0].format, @intCast(info.width), @intCast(info.height), info.finfo[0].n_planes, &offsets, &strides);
        if (alig != null) _ = c.gst_video_meta_set_alignment(vm, alig.*);
    } else {
        for (0..n) |i| {
            if (offsets[i] != info.offset[i] or strides[i] != info.stride[i]) {
                c.gst_buffer_unref(b);
                b = null;
                break;
            }
        }
    }
    return b;
}

fn prepareOutput(bt: [*c]c.GstBaseTransform, in: [*c]c.GstBuffer, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    const k: *c.GstBaseTransformClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(bt)).g_class));
    const ctx = el.base(bt).context;
    out.* = in;
    const sync: ?*c.GstGLSyncMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(in, c.gst_gl_sync_meta_api_get_type())));
    if (sync != null and ctx != null) c.gst_gl_sync_meta_wait_cpu(sync, ctx);
    if (pool.isDmabufBuffer(in)) {
        const wrapped = pool.unwrap(in);
        if (wrapped != null) {
            out.* = wrapped;
            return c.GST_FLOW_OK;
        }
    }
    if (s.mode == .dmabuf) {
        const b = exportDmabuf(s, in);
        if (b != null) {
            if (k.copy_metadata) |f| {
                if (f(bt, in, b) == 0) cm.elementWarning(bt, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_NOT_IMPLEMENTED, c.g_strdup("could not copy metadata"), null, FILE, "gst_gl_download_element_prepare_output_buffer", 1406);
            }
            out.* = b;
        } else {
            const sink_caps = c.gst_pad_get_current_caps(bt[0].sinkpad);
            const src_caps = withFeature(ctx, sink_caps, c.GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY);
            removeField(src_caps, "texture-target");
            c.gst_caps_unref(sink_caps);
            c.g_atomic_int_set(&s.try_dmabuf, 0);
            s.mode = .pbo;
            const ok = c.gst_base_transform_update_src_caps(bt, src_caps);
            c.gst_caps_unref(src_caps);
            if (ok == 0) return c.GST_FLOW_NOT_NEGOTIATED;
        }
    }
    if (s.mode == .pbo) {
        const n = c.gst_buffer_n_memory(out.*);
        for (0..n) |i| {
            const mem = c.gst_buffer_peek_memory(out.*, @intCast(i));
            if (c.gst_is_gl_memory_pbo(mem) != 0) c.gst_gl_memory_pbo_download_transfer(@ptrCast(@alignCast(mem)));
        }
    }
    return c.GST_FLOW_OK;
}

fn transformMeta(bt: [*c]c.GstBaseTransform, out: [*c]c.GstBuffer, meta: [*c]c.GstMeta, in: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    if (c.g_type_is_a(meta[0].info[0].api, c.gst_gl_sync_meta_api_get_type()) != 0) return 0;
    if (!el.videoTagsOnly(meta, true)) return parent.transform_meta.?(bt, out, meta, in);
    return 1;
}

fn decideAllocation(bt: [*c]c.GstBaseTransform, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bt);
    s.add_videometa = @intFromBool(c.gst_query_find_allocation_meta(q, c.gst_video_meta_api_get_type(), null) != 0);
    clearForeign(s);
    var caps: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(q, &caps, null);
    const f = c.gst_caps_get_features(caps, 0);
    if (c.gst_caps_features_contains(f, DMABUF) != 0 and c.gst_query_get_n_allocation_pools(q) > 0) {
        c.gst_query_parse_nth_allocation_pool(q, 0, &s.foreign_pool, null, null, null);
        s.foreign_caps = @ptrCast(c.gst_mini_object_ref(@ptrCast(caps)));
        c.gst_query_remove_nth_allocation_pool(q, 0);
    }
    return parent.decide_allocation.?(bt, q);
}

fn sinkEvent(bt: [*c]c.GstBaseTransform, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (ev[0].type == c.GST_EVENT_CAPS) c.g_atomic_int_set(&me(bt).try_dmabuf, 1);
    return parent.sink_event.?(bt, ev);
}

fn srcEvent(bt: [*c]c.GstBaseTransform, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (ev[0].type == c.GST_EVENT_RECONFIGURE) c.g_atomic_int_set(&me(bt).try_dmabuf, 1);
    return parent.src_event.?(bt, ev);
}

fn proposeAllocation(bt: [*c]c.GstBaseTransform, decide: [*c]c.GstQuery, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (parent.propose_allocation.?(bt, decide, q) == 0) return 0;
    var caps: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(q, &caps, null);
    if (caps == null) return 0;
    const ctx = el.base(bt).context;
    if (ctx == null) return 0;
    var info: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&info, caps) == 0) return 0;
    const s = me(bt);
    const p = if (s.foreign_pool != null) pool.new(ctx, s.foreign_pool, s.foreign_caps) else c.gst_gl_buffer_pool_new(ctx);
    const config = c.gst_buffer_pool_get_config(p);
    const size: c.guint = @intCast(info.size);
    c.gst_buffer_pool_config_set_params(config, caps, size, 0, 0);
    c.gst_buffer_pool_config_set_gl_min_free_queue_size(config, 1);
    if (c.gst_buffer_pool_set_config(p, config) == 0) {
        c.gst_object_unref(p);
        return 0;
    }
    if (ctx[0].gl_vtable[0].FenceSync != null) c.gst_query_add_allocation_meta(q, c.gst_gl_sync_meta_api_get_type(), null);
    c.gst_query_add_allocation_pool(q, p, size, 1, 0);
    c.gst_object_unref(p);
    return 1;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.dmabuf_allocator != null) c.gst_object_unref(s.dmabuf_allocator);
    s.dmabuf_allocator = null;
    parent_obj.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    const bt = el.baseTransformClass(k);
    bt.start = start;
    bt.stop = stop;
    bt.transform_caps = transformCaps;
    bt.fixate_caps = fixateCaps;
    bt.set_caps = setCaps;
    bt.get_unit_size = el.unitSize;
    bt.prepare_output_buffer = prepareOutput;
    bt.transform = el.noTransform;
    bt.decide_allocation = decideAllocation;
    bt.sink_event = sinkEvent;
    bt.src_event = srcEvent;
    bt.propose_allocation = proposeAllocation;
    bt.transform_meta = transformMeta;
    bt.passthrough_on_same_caps = 1;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "OpenGL downloader", "Filter/Video", "Downloads data from OpenGL", "Matthew Waters <matthew@centricular.com>");
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_transform_set_prefer_passthrough(@ptrCast(@alignCast(inst)), 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_base_filter_get_type(), "GstGLDownloadElement", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("gldownloadelement", 0, "download element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "gldownload", c.GST_RANK_NONE, getType());
}
