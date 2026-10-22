const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const format = @import("format.zig");
const memory = @import("memory.zig");
const memorypbo = @import("memorypbo.zig");
const basememory = @import("basememory.zig");
const bufferpool = @import("bufferpool.zig");
const overlay = @import("overlay.zig");
const syncmeta = @import("syncmeta.zig");
const utils = @import("utils.zig");
const eglctx = @import("egl/context.zig");
const eglimage = @import("egl/image.zig");
const cache = @import("egl/cache.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Up = c.GstGLUpload;
const OUp = [*c]Up;
const Class = c.GstGLUploadClass;
const OCtx = [*c]c.GstGLContext;
const OBuf = [*c]c.GstBuffer;
const OCaps = [*c]c.GstCaps;
const OFeat = ?*c.GstCapsFeatures;
const OS = [*c]c.GstStructure;
const OV = [*c]const c.GValue;
const Ret = c.GstGLUploadReturn;
const Dir = c.GstPadDirection;
const OVParams = [*c]c.GstGLVideoAllocationParams;
const S = [*:0]const u8;
const MAXP = c.GST_VIDEO_MAX_PLANES;

const GLMEM = "memory:GLMemory";
const SYSMEM = "memory:SystemMemory";
const DMABUF = "memory:DMABuf";
const OVERLAY = "meta:GstVideoOverlayComposition";
const UPLOAD_META = "meta:GstVideoGLTextureUploadMeta";
const RANGE = ", width = (int) [ 1, max ], height = (int) [ 1, max ], framerate = (fraction) [ 0, max ]";
const GL_FORMATS = "{ RGBA, BGRA, RGBx, BGRx, ARGB, ABGR, xRGB, xBGR, GBRA, GBR, RGBP, BGRP, RGB, BGR, RGB16, BGR16, AYUV, VUYA, A444, A422, Y410, I420, YV12, NV12, NV21, NV16, NV61, NV24, YUY2, UYVY, Y210, Y41B, Y42B, Y444, GRAY8, GRAY16_LE, GRAY16_BE, ARGB64, A420, AV12, NV12_16L32S, NV12_4L4, RBGA, v210, RGBA64_LE, BGR10A2_LE, RGB10A2_LE, BGR10x2_LE, RGB10x2_LE, P010_10LE, P012_LE, P016_LE, Y212_LE, Y412_LE, A444_16LE, A422_16LE, A420_16LE, A444_12LE, A422_12LE, A420_12LE, A420_10LE, A422_10LE, A444_10LE, I420_12LE, I420_10LE, I422_10LE, I422_12LE, Y444_10LE, Y444_12LE, Y444_16LE}";
const DMA_DRM = "video/x-raw(memory:DMABuf), format = (string) DMA_DRM" ++ RANGE;
const RAW = "video/x-raw, format = (string) " ++ GL_FORMATS ++ RANGE;

fn rawWith(comptime feat: []const u8, comptime fmts: []const u8) []const u8 {
    return "video/x-raw(" ++ feat ++ "), format = (string) " ++ fmts ++ RANGE;
}

fn staticCaps(comptime s: []const u8) c.GstStaticCaps {
    return .{ .caps = null, .string = s ++ "", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
}

var passthrough_caps = staticCaps(DMA_DRM ++ " ; " ++ rawWith(DMABUF ++ "," ++ OVERLAY, "DMA_DRM"));
var udmabuf_sink_caps = staticCaps(RAW ++ " ; " ++ rawWith(SYSMEM ++ "," ++ OVERLAY, GL_FORMATS));
var udmabuf_src_caps = staticCaps(DMA_DRM ++ " ; " ++ rawWith(DMABUF ++ "," ++ OVERLAY, "DMA_DRM"));
var glmem_caps = staticCaps(rawWith(GLMEM, GL_FORMATS));
var dmabuf_caps = staticCaps(DMA_DRM ++ ";" ++ RAW);
var meta_caps = staticCaps(rawWith(UPLOAD_META, "RGBA"));
var raw_caps = staticCaps(RAW);
var raw_drm_caps = staticCaps(DMA_DRM ++ ";" ++ RAW);

const CAN_SHARE = 1;
const MOD_LINEAR: u64 = 0;
const MOD_INVALID: u64 = 0x00ffffffffffffff;

const Impl = *anyopaque;

const Method = struct {
    name: S,
    flags: c_int,
    caps: *c.GstStaticCaps,
    new: *const fn (OUp) Impl,
    transform: *const fn (Impl, OCtx, Dir, OCaps) OCaps,
    accept: *const fn (Impl, OBuf, OCaps, OCaps) bool,
    propose: *const fn (Impl, ?*c.GstQuery, ?*c.GstQuery) void,
    perform: *const fn (Impl, OBuf, *OBuf) Ret,
    free: *const fn (Impl) void,
};

const Priv = struct {
    drm: c.GstVideoInfoDmaDrm,
    out_info: c.GstVideoInfo,
    in_caps: OCaps,
    out_caps: OCaps,
    outbuf: OBuf,
    impls: [*]Impl,
    method: ?*const Method,
    impl: ?Impl,
    method_i: usize,
    saved_i: usize,
};

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;
var global_lock: c.GMutex = std.mem.zeroes(c.GMutex);

fn up(p: anytype) OUp {
    return @ptrCast(@alignCast(p));
}

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(up(p)[0].priv));
}

fn inInfo(u: OUp) *c.GstVideoInfo {
    return &pv(u).drm.vinfo;
}

fn vt(ctx: OCtx) *c.GstGLFuncs {
    return @ptrCast(ctx[0].gl_vtable);
}

fn objLock(p: anytype) void {
    c.g_mutex_lock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn objUnlock(p: anytype) void {
    c.g_mutex_unlock(&@as(*c.GstObject, @ptrCast(@alignCast(p))).lock);
}

fn alloc(comptime T: type) *T {
    const p: *T = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(T))));
    return p;
}

fn as(comptime T: type, p: Impl) *T {
    return @ptrCast(@alignCast(p));
}

fn holdsStr(v: OV) bool {
    return v != null and c.g_type_check_value_holds(@constCast(v), c.G_TYPE_STRING) != 0;
}

fn holdsList(v: OV) bool {
    return v != null and v[0].g_type == c.gst_value_list_get_type();
}

fn hasFeature(caps: OCaps, f: S) bool {
    return c.gst_caps_features_contains(c.gst_caps_get_features(caps, 0), f) != 0;
}

fn targetOf(caps: OCaps, default: c.GstGLTextureTarget) c.GstGLTextureTarget {
    const s = c.gst_caps_get_structure(caps, 0);
    var r: c.GstGLTextureTarget = 0;
    if (c.gst_structure_has_field_typed(s, "texture-target", c.G_TYPE_STRING) != 0) r = format.gst_gl_texture_target_from_string(c.gst_structure_get_string(s, "texture-target"));
    return if (r == 0) default else r;
}

fn filterFeatures(f: OFeat, _: OS, data: c.gpointer) callconv(.c) c.gboolean {
    if (c.gst_caps_features_is_any(f) != 0) return 1;
    const user: OFeat = @ptrCast(data);
    var i: c.guint = 0;
    while (i < c.gst_caps_features_get_size(user)) : (i += 1) {
        if (c.gst_caps_features_contains_id_str(f, c.gst_caps_features_get_nth_id_str(user, i)) != 0) return 1;
    }
    return 0;
}

fn filterCaps(caps: OCaps, feat: OFeat, out: ?*OCaps) bool {
    if (c.gst_caps_is_empty(caps) != 0) return false;
    if (c.gst_caps_is_any(caps) != 0) {
        if (out) |o| {
            const t = c.gst_caps_new_empty();
            c.gst_caps_set_features_simple(t, c.gst_caps_features_copy(feat));
            o.* = t;
        }
        return true;
    }
    var t = c.gst_caps_copy(caps);
    c.gst_caps_filter_and_map_in_place(t, filterFeatures, feat);
    var ok = true;
    if (c.gst_caps_is_empty(t) != 0) {
        c.gst_caps_unref(t);
        t = null;
        ok = false;
    }
    if (out) |o| o.* = t else if (t != null) c.gst_caps_unref(t);
    return ok;
}

fn withPassthrough(caps: OCaps, name: S, pass: OFeat) OCaps {
    const out = c.gst_caps_new_empty();
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) {
        const s = c.gst_caps_get_structure(caps, i);
        const orig = c.gst_caps_get_features(caps, i);
        const feat = c.gst_caps_features_new_static_str(name, @as(?*anyopaque, null));
        var j: c.guint = 0;
        if (c.gst_caps_features_is_any(orig) != 0) {
            c.gst_caps_append_structure_full(out, c.gst_structure_copy(s), c.gst_caps_features_copy(feat));
            while (j < c.gst_caps_features_get_size(pass)) : (j += 1) {
                const f = c.gst_caps_features_get_nth(pass, j);
                if (c.gst_caps_features_contains(feat, f) == 0) c.gst_caps_features_add(feat, f);
            }
        } else {
            while (j < c.gst_caps_features_get_size(orig)) : (j += 1) {
                const f = c.gst_caps_features_get_nth(orig, j);
                if (c.gst_caps_features_contains(feat, f) != 0) continue;
                if (c.g_strcmp0(f, SYSMEM) == 0) continue;
                if (c.gst_caps_features_contains(pass, f) != 0) c.gst_caps_features_add(feat, f);
            }
        }
        c.gst_caps_append_structure_full(out, c.gst_structure_copy(s), feat);
    }
    return out;
}

fn passthroughOverlay(caps: OCaps, name: S) OCaps {
    const pass = c.gst_caps_features_from_string(OVERLAY);
    defer c.gst_caps_features_free(pass);
    return withPassthrough(caps, name, pass);
}

fn intersectTarget(caps: OCaps, tm: c.GstGLTextureTarget) OCaps {
    var v = std.mem.zeroes(c.GValue);
    const t = c.gst_caps_copy(caps);
    _ = utils.gst_gl_value_set_texture_target_from_mask(&v, tm);
    c.gst_caps_set_value(t, "texture-target", &v);
    const r = c.gst_caps_intersect_full(caps, t, c.GST_CAPS_INTERSECT_FIRST);
    c.g_value_unset(&v);
    c.gst_caps_unref(t);
    return r;
}

fn checkTarget(s: OS, tm: c.GstGLTextureTarget) bool {
    const m: c.guint = @bitCast(tm);
    const v = c.gst_structure_get_value(s, "texture-target");
    if (v == null) return (1 << c.GST_GL_TEXTURE_TARGET_2D) & m != 0;
    if (holdsStr(v)) return (@as(c.guint, 1) << @intCast(format.gst_gl_texture_target_from_string(c.g_value_get_string(v)))) & m != 0;
    if (holdsList(v)) {
        var i: c.guint = 0;
        while (i < c.gst_value_list_get_size(v)) : (i += 1) {
            const t = format.gst_gl_texture_target_from_string(c.g_value_get_string(c.gst_value_list_get_value(v, i)));
            if ((@as(c.guint, 1) << @intCast(t)) & m != 0) return true;
        }
    }
    return false;
}

fn stripTarget(caps: OCaps) void {
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) c.gst_structure_remove_fields(c.gst_caps_get_structure(caps, i), "texture-target", @as(?*anyopaque, null));
}

fn mask(t: c.GstGLTextureTarget) c.GstGLTextureTarget {
    return @as(c.GstGLTextureTarget, 1) << @intCast(t);
}

const Plain = struct { upload: OUp };

fn plainNew(u: OUp) Impl {
    const p = alloc(Plain);
    p.upload = u;
    return p;
}

fn freeImpl(i: Impl) void {
    c.g_free(i);
}

fn noPropose(_: Impl, _: ?*c.GstQuery, _: ?*c.GstQuery) void {}

fn passTransform(_: Impl, _: OCtx, _: Dir, caps: OCaps) OCaps {
    const pc = c.gst_static_caps_get(&passthrough_caps);
    const r = c.gst_caps_intersect_full(caps, pc, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(pc);
    return r;
}

fn passAccept(_: Impl, _: OBuf, in: OCaps, out: OCaps) bool {
    const t = c.gst_caps_intersect(in, out);
    defer c.gst_caps_unref(t);
    return c.gst_caps_is_empty(t) == 0;
}

fn passPerform(_: Impl, buf: OBuf, out: *OBuf) Ret {
    out.* = c.gst_buffer_ref(buf);
    return c.GST_GL_UPLOAD_DONE;
}

const PASSTHROUGH = Method{ .name = "Dmabuf Passthrough", .flags = 0, .caps = &passthrough_caps, .new = plainNew, .transform = passTransform, .accept = passAccept, .propose = noPropose, .perform = passPerform, .free = freeImpl };

const Udma = struct { upload: OUp, in_caps: OCaps, out_caps: OCaps, disabled: bool };

fn udmaNew(u: OUp) Impl {
    const p = alloc(Udma);
    p.upload = u;
    const a = c.gst_udmabuf_allocator_get();
    if (a == null) p.disabled = true else c.gst_object_unref(a);
    return p;
}

fn fourccName(f: c.GstVideoFormat) ?[*c]u8 {
    if (f == c.GST_VIDEO_FORMAT_UNKNOWN) return null;
    const cc = c.gst_video_dma_drm_fourcc_from_format(f);
    if (cc == 0) return null;
    return c.gst_video_dma_drm_fourcc_to_string(cc, 0);
}

fn linearFormat(v: OV) ?c.GstVideoFormat {
    var modifier: u64 = 0;
    const cc = c.gst_video_dma_drm_fourcc_from_string(c.g_value_get_string(v), &modifier);
    const f = c.gst_video_dma_drm_format_to_gst_format(cc, modifier);
    if (f == c.GST_VIDEO_FORMAT_UNKNOWN or modifier != MOD_LINEAR) return null;
    return f;
}

fn udmaTransform(impl: Impl, _: OCtx, dir: Dir, caps: OCaps) OCaps {
    const u = as(Udma, impl);
    if (u.disabled) return null;
    const pass = c.gst_caps_features_from_string(OVERLAY);
    defer c.gst_caps_features_free(pass);
    const sink = dir == c.GST_PAD_SINK;
    const sc = c.gst_static_caps_get(if (sink) &udmabuf_sink_caps else &udmabuf_src_caps);
    const inter = c.gst_caps_intersect_full(caps, sc, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(sc);
    if (c.gst_caps_is_empty(inter) != 0) {
        c.gst_caps_unref(inter);
        return null;
    }
    const caps2 = withPassthrough(inter, if (sink) DMABUF else SYSMEM, pass);
    c.gst_caps_unref(inter);
    defer c.gst_caps_unref(caps2);
    const out = c.gst_caps_new_empty();
    var i: c.guint = 0;
    const n = c.gst_caps_get_size(caps2);
    while (i < n) : (i += 1) {
        const s = c.gst_caps_get_structure(caps2, i);
        const feat = c.gst_caps_get_features(caps2, i);
        if (sink) {
            const val = c.gst_structure_get_value(s, "format");
            if (val == null) {
                const cp = c.gst_structure_copy(s);
                c.gst_structure_set(cp, "format", c.G_TYPE_STRING, "DMA_DRM", @as(?*anyopaque, null));
                c.gst_caps_append_structure_full(out, cp, c.gst_caps_features_copy(feat));
                continue;
            }
            const all = c.g_ptr_array_new_with_free_func(c.g_free);
            if (holdsStr(val)) {
                if (fourccName(c.gst_video_format_from_string(c.g_value_get_string(val)))) |d| c.g_ptr_array_add(all, d);
            } else if (holdsList(val)) {
                var j: c.guint = 0;
                while (j < c.gst_value_list_get_size(val)) : (j += 1) {
                    if (fourccName(c.gst_video_format_from_string(c.g_value_get_string(c.gst_value_list_get_value(val, j))))) |d| c.g_ptr_array_add(all, d);
                }
            }
            if (all[0].len == 0) {
                c.g_ptr_array_unref(all);
                continue;
            }
            var drm = std.mem.zeroes(c.GValue);
            if (all[0].len == 1) {
                _ = c.g_value_init(&drm, c.G_TYPE_STRING);
                c.g_value_set_string(&drm, @ptrCast(all[0].pdata[0]));
            } else {
                _ = c.gst_value_list_init(&drm, all[0].len);
                i = 0;
                while (i < all[0].len) : (i += 1) {
                    var item = std.mem.zeroes(c.GValue);
                    _ = c.g_value_init(&item, c.G_TYPE_STRING);
                    c.g_value_set_string(&item, @ptrCast(all[0].pdata[i]));
                    c.gst_value_list_append_value(&drm, &item);
                    c.g_value_unset(&item);
                }
            }
            c.g_ptr_array_unref(all);
            const cp = c.gst_structure_copy(s);
            c.gst_structure_set(cp, "format", c.G_TYPE_STRING, "DMA_DRM", @as(?*anyopaque, null));
            c.gst_structure_take_value(cp, "drm-format", &drm);
            c.g_value_unset(&drm);
            c.gst_caps_append_structure_full(out, cp, c.gst_caps_features_copy(feat));
        } else {
            const val = c.gst_structure_get_value(s, "drm-format");
            if (val == null) c.gst_caps_append_structure_full(out, c.gst_structure_copy(s), c.gst_caps_features_copy(feat));
            var fmts: [64]c.GstVideoFormat = undefined;
            var nf: usize = 0;
            if (holdsStr(val)) {
                if (linearFormat(val)) |f| {
                    fmts[nf] = f;
                    nf += 1;
                }
            } else if (holdsList(val)) {
                var j: c.guint = 0;
                while (j < c.gst_value_list_get_size(val)) : (j += 1) {
                    if (linearFormat(c.gst_value_list_get_value(val, j))) |f| {
                        if (nf < fmts.len) {
                            fmts[nf] = f;
                            nf += 1;
                        }
                    }
                }
            }
            if (nf == 0) continue;
            var gv = std.mem.zeroes(c.GValue);
            if (nf == 1) {
                _ = c.g_value_init(&gv, c.G_TYPE_STRING);
                c.g_value_set_string(&gv, c.gst_video_format_to_string(fmts[0]));
            } else {
                _ = c.gst_value_list_init(&gv, @intCast(nf));
                for (fmts[0..nf]) |f| {
                    var item = std.mem.zeroes(c.GValue);
                    _ = c.g_value_init(&item, c.G_TYPE_STRING);
                    c.g_value_set_string(&item, c.gst_video_format_to_string(f));
                    c.gst_value_list_append_value(&gv, &item);
                    c.g_value_unset(&item);
                }
            }
            const cp = c.gst_structure_copy(s);
            c.gst_structure_take_value(cp, "format", &gv);
            c.g_value_unset(&gv);
            c.gst_structure_remove_field(cp, "drm-format");
            c.gst_caps_append_structure_full(out, cp, c.gst_caps_features_copy(feat));
        }
    }
    return out;
}

fn udmaAccept(impl: Impl, buf: OBuf, in: OCaps, out: OCaps) bool {
    const u = as(Udma, impl);
    if (u.disabled) return false;
    const n = c.gst_buffer_n_memory(buf);
    var all = true;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const m = c.gst_buffer_peek_memory(buf, i);
        if (!gtype.instanceOf(m[0].allocator, c.gst_udmabuf_allocator_get_type())) {
            all = false;
            break;
        }
    }
    if (n == 0 or !all) {
        if (!hasFeature(out, DMABUF)) return false;
        u.disabled = true;
        return true;
    }
    if (u.in_caps != null and u.out_caps != null and c.gst_caps_is_equal(u.in_caps, in) != 0 and c.gst_caps_is_equal(u.out_caps, out) != 0) return true;
    clearCaps(&u.in_caps);
    clearCaps(&u.out_caps);
    const ss = c.gst_static_caps_get(&udmabuf_sink_caps);
    const ci = c.gst_caps_intersect_full(in, ss, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(ss);
    defer c.gst_caps_unref(ci);
    if (c.gst_caps_is_empty(ci) != 0) return false;
    const sr = c.gst_static_caps_get(&udmabuf_src_caps);
    const co = c.gst_caps_intersect_full(out, sr, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(sr);
    defer c.gst_caps_unref(co);
    if (c.gst_caps_is_empty(co) != 0) return false;
    u.in_caps = c.gst_caps_ref(in);
    u.out_caps = c.gst_caps_ref(out);
    return true;
}

fn clearCaps(p: *OCaps) void {
    if (p.* != null) c.gst_caps_unref(p.*);
    p.* = null;
}

fn udmaPropose(_: Impl, _: ?*c.GstQuery, q: ?*c.GstQuery) void {
    const a = c.gst_udmabuf_allocator_get();
    if (a == null) return;
    defer c.gst_object_unref(a);
    var caps: OCaps = null;
    var need: c.gboolean = 0;
    c.gst_query_parse_allocation(q, &caps, &need);
    if (caps == null or need == 0 or !hasFeature(caps, SYSMEM)) return;
    var vi: c.GstVideoInfo = undefined;
    if (c.gst_video_info_from_caps(&vi, caps) == 0) return;
    const pool = c.gst_video_dmabuf_pool_new();
    c.gst_query_add_allocation_pool(q, pool, @truncate(vi.size), 1, 0);
    c.gst_object_unref(pool);
}

fn udmaPerform(impl: Impl, buf: OBuf, out: *OBuf) Ret {
    if (as(Udma, impl).disabled) return c.GST_GL_UPLOAD_RECONFIGURE;
    out.* = c.gst_buffer_ref(buf);
    return c.GST_GL_UPLOAD_DONE;
}

fn udmaFree(impl: Impl) void {
    const u = as(Udma, impl);
    clearCaps(&u.in_caps);
    clearCaps(&u.out_caps);
    c.g_free(impl);
}

const UDMABUF = Method{ .name = "Udmabuf uploader", .flags = 0, .caps = &udmabuf_sink_caps, .new = udmaNew, .transform = udmaTransform, .accept = udmaAccept, .propose = udmaPropose, .perform = udmaPerform, .free = udmaFree };

const GlMem = struct { upload: OUp, input_target: c.GstGLTextureTarget, output_target: c.GstGLTextureTarget };

fn glNew(u: OUp) Impl {
    const p = alloc(GlMem);
    p.upload = u;
    return p;
}

fn glTransform(impl: Impl, _: OCtx, dir: Dir, caps: OCaps) OCaps {
    const u = as(GlMem, impl);
    if (dir == c.GST_PAD_SINK) {
        const ff = c.gst_caps_features_new_static_str(GLMEM, SYSMEM, @as(?*anyopaque, null));
        var t: OCaps = null;
        const ok = filterCaps(caps, ff, &t);
        c.gst_caps_features_free(ff);
        if (!ok) return null;
        const r = passthroughOverlay(t, GLMEM);
        c.gst_caps_unref(t);
        const m = if (u.input_target != c.GST_GL_TEXTURE_TARGET_NONE) mask(u.input_target) else mask(c.GST_GL_TEXTURE_TARGET_2D) | mask(c.GST_GL_TEXTURE_TARGET_RECTANGLE) | mask(c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES);
        const r2 = intersectTarget(r, m);
        c.gst_caps_unref(r);
        return r2;
    }
    const r = passthroughOverlay(caps, GLMEM);
    stripTarget(r);
    return r;
}

fn glAccept(impl: Impl, buf: OBuf, in: OCaps, out: OCaps) bool {
    const u = as(GlMem, impl);
    if (!hasFeature(out, GLMEM)) return false;
    if (!hasFeature(in, GLMEM) and !hasFeature(in, SYSMEM)) return false;
    if (buf != null) {
        const info = inInfo(u.upload);
        var expected: c.guint = info.finfo[0].n_planes;
        if (info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED) expected *= @intCast(info.views);
        if (c.gst_buffer_n_memory(buf) != expected) return false;
        var i: c.guint = 0;
        while (i < expected) : (i += 1) {
            if (memory.gst_is_gl_memory(c.gst_buffer_peek_memory(buf, i)) == 0) return false;
        }
    }
    return true;
}

fn glPropose(impl: Impl, _: ?*c.GstQuery, q: ?*c.GstQuery) void {
    const u = as(GlMem, impl).upload;
    var caps: OCaps = null;
    c.gst_query_parse_allocation(q, &caps, null);
    if (caps == null) return;
    if (c.gst_caps_is_fixed(caps) == 0) check.assertFail("gstglupload.c", 1005, "_gl_memory_upload_propose_allocation", "gst_caps_is_fixed (caps)");
    const fgl = c.gst_caps_features_new_static_str(GLMEM, @as(?*anyopaque, null));
    const fsys = c.gst_caps_features_new_static_str(SYSMEM, @as(?*anyopaque, null));
    var sys = false;
    if (filterCaps(caps, fsys, null)) {
        sys = true;
    } else if (!filterCaps(caps, fgl, null)) {
        c.gst_caps_features_free(fgl);
        c.gst_caps_features_free(fsys);
        return;
    }
    c.gst_caps_features_free(fgl);
    c.gst_caps_features_free(fsys);
    var option: ?[*c]const u8 = null;
    if (pv(u).out_caps != null) {
        const t = targetOf(pv(u).out_caps, c.GST_GL_TEXTURE_TARGET_2D);
        if (t == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES and sys) return;
        option = format.gst_gl_texture_target_to_buffer_pool_option(t);
    }
    var params: c.GstAllocationParams = undefined;
    c.gst_allocation_params_init(&params);
    var a: [*c]c.GstAllocator = null;
    if (!sys) a = @ptrCast(memory.gst_gl_memory_allocator_get_default(u[0].context));
    c.gst_query_add_allocation_param(q, a, &params);
    if (a != null) c.gst_object_unref(a);
    if (u[0].context != null and context.gst_gl_context_get_gl_platform(u[0].context) == c.GST_GL_PLATFORM_EGL) {
        a = null;
        if (!sys) a = c.gst_allocator_find("GLMemoryEGL");
        c.gst_query_add_allocation_param(q, a, &params);
        if (a != null) c.gst_object_unref(a);
    }
    var pool: [*c]c.GstBufferPool = null;
    var i: c.guint = 0;
    const n = c.gst_query_get_n_allocation_pools(q);
    while (i < n) : (i += 1) {
        c.gst_query_parse_nth_allocation_pool(q, i, &pool, null, null, null);
        if (!gtype.instanceOf(pool, bufferpool.gst_gl_buffer_pool_get_type())) {
            c.gst_object_unref(pool);
            pool = null;
        }
    }
    if (pool == null) {
        var info: c.GstVideoInfo = undefined;
        if (c.gst_video_info_from_caps(&info, caps) == 0) return;
        pool = bufferpool.gst_gl_buffer_pool_new(u[0].context);
        const cfg = c.gst_buffer_pool_get_config(pool);
        const size: c.guint = @truncate(info.size);
        c.gst_buffer_pool_config_set_params(cfg, caps, size, 0, 0);
        bufferpool.gst_buffer_pool_config_set_gl_min_free_queue_size(cfg, 1);
        c.gst_buffer_pool_config_add_option(cfg, "GstBufferPoolOptionGLSyncMeta");
        if (option) |o| c.gst_buffer_pool_config_add_option(cfg, o);
        if (c.gst_buffer_pool_set_config(pool, cfg) == 0) {
            c.gst_object_unref(pool);
            return;
        }
        c.gst_query_add_allocation_pool(q, pool, size, 1, 0);
    }
    if (pool != null) c.gst_object_unref(pool);
}

fn glPerform(impl: Impl, buf: OBuf, out: *OBuf) Ret {
    const u = as(GlMem, impl);
    const owner = u.upload;
    var i: c.guint = 0;
    const n = c.gst_buffer_n_memory(buf);
    while (i < n) : (i += 1) {
        const m = c.gst_buffer_peek_memory(buf, i);
        const g: [*c]c.GstGLMemory = @ptrCast(@alignCast(m));
        if (context.gst_gl_context_can_share(owner[0].context, g[0].mem.context) == 0) return c.GST_GL_UPLOAD_UNSHARED_GL_CONTEXT;
        if (u.output_target == c.GST_GL_TEXTURE_TARGET_NONE and pv(owner).out_caps != null) u.output_target = targetOf(pv(owner).out_caps, c.GST_GL_TEXTURE_TARGET_NONE);
        u.input_target = g[0].tex_target;
        if (u.output_target != g[0].tex_target) {
            out.* = null;
            return c.GST_GL_UPLOAD_RECONFIGURE;
        }
        if (memorypbo.gst_is_gl_memory_pbo(m) != 0) memorypbo.gst_gl_memory_pbo_upload_transfer(@ptrCast(m));
    }
    out.* = c.gst_buffer_ref(buf);
    return c.GST_GL_UPLOAD_DONE;
}

const GLMEMORY = Method{ .name = "GLMemory", .flags = CAN_SHARE, .caps = &glmem_caps, .new = glNew, .transform = glTransform, .accept = glAccept, .propose = glPropose, .perform = glPerform, .free = freeImpl };

const Dma = struct {
    upload: OUp,
    images: [MAXP][*c]c.GstEGLImage,
    cache: *cache.Cache,
    formats: [MAXP]c.GstGLFormat,
    outbuf: OBuf,
    params: OVParams,
    n_mem: c.guint,
    direct: bool,
    target: c.GstGLTextureTarget,
    out_info: c.GstVideoInfo,
    out_caps: OCaps,
};

fn dmaNew(u: OUp) Impl {
    const p = alloc(Dma);
    p.upload = u;
    p.cache = cache.gst_egl_image_cache_new();
    p.target = c.GST_GL_TEXTURE_TARGET_2D;
    return p;
}

fn defaultFormats(s: OS) void {
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_value_list_get_type());
    _ = c.gst_value_deserialize(&v, GL_FORMATS);
    c.gst_structure_take_value(s, "format", &v);
}

fn convertFormatField(ctx: OCtx, s: OS, dir: Dir, flags: c.GstGLDrmFormatFlags) bool {
    if (dir == c.GST_PAD_SRC) {
        if (ctx == null) {
            c.gst_structure_set(s, "format", c.G_TYPE_STRING, "DMA_DRM", @as(?*anyopaque, null));
            c.gst_structure_remove_field(s, "drm-format");
            return true;
        }
        var val = c.gst_structure_get_value(s, "format");
        if (val == null) {
            defaultFormats(s);
            val = c.gst_structure_get_value(s, "format");
        }
        var drm = std.mem.zeroes(c.GValue);
        if (utils.gst_gl_dma_buf_transform_gst_formats_to_drm_formats(ctx, val, flags, &drm) == 0) return false;
        c.gst_structure_take_value(s, "drm-format", &drm);
        c.gst_structure_set(s, "format", c.G_TYPE_STRING, "DMA_DRM", @as(?*anyopaque, null));
        return true;
    }
    if (c.g_strcmp0(c.gst_structure_get_string(s, "format"), "DMA_DRM") != 0) return false;
    const val = c.gst_structure_get_value(s, "drm-format");
    if (val == null) {
        c.gst_structure_remove_field(s, "format");
        c.gst_structure_remove_field(s, "drm-format");
        defaultFormats(s);
        return true;
    }
    var gv = std.mem.zeroes(c.GValue);
    if (utils.gst_gl_dma_buf_transform_drm_formats_to_gst_formats(ctx, val, flags, &gv) == 0) return false;
    c.gst_structure_take_value(s, "format", &gv);
    c.gst_structure_remove_field(s, "drm-format");
    return true;
}

fn eglLinear(ctx: OCtx, f: c.GstVideoFormat, external: bool) bool {
    if (f == c.GST_VIDEO_FORMAT_UNKNOWN) return false;
    const cc = c.gst_video_dma_drm_fourcc_from_format(f);
    if (cc == 0) return false;
    return eglctx.supportsModifierFor(ctx, cc, MOD_LINEAR, external);
}

fn filterEglFormats(ctx: OCtx, s: OS, external: bool) bool {
    if (ctx == null) return true;
    const all = c.gst_structure_get_value(s, "format");
    if (all == null) return false;
    if (holdsStr(all)) return eglLinear(ctx, c.gst_video_format_from_string(c.g_value_get_string(all)), external);
    if (!holdsList(all)) return false;
    var fmts: [128]c.GstVideoFormat = undefined;
    var n: usize = 0;
    var i: c.guint = 0;
    while (i < c.gst_value_list_get_size(all)) : (i += 1) {
        const f = c.gst_video_format_from_string(c.g_value_get_string(c.gst_value_list_get_value(all, i)));
        if (!eglLinear(ctx, f, external) or n == fmts.len) continue;
        fmts[n] = f;
        n += 1;
    }
    if (n == 0) return false;
    var v = std.mem.zeroes(c.GValue);
    if (n == 1) {
        _ = c.g_value_init(&v, c.G_TYPE_STRING);
        c.g_value_set_string(&v, c.gst_video_format_to_string(fmts[0]));
    } else {
        _ = c.gst_value_list_init(&v, @intCast(n));
        for (fmts[0..n]) |f| {
            var item = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&item, c.G_TYPE_STRING);
            c.g_value_set_string(&item, c.gst_video_format_to_string(f));
            c.gst_value_list_append_value(&v, &item);
            c.g_value_unset(&item);
        }
    }
    c.gst_structure_take_value(s, "format", &v);
    return true;
}

fn eq(a: S, b: S) bool {
    return c.g_strcmp0(a, b) == 0;
}

fn dmaCommon(caps: OCaps, ctx: OCtx, dir: Dir, flags: c.GstGLDrmFormatFlags, tmask: c.GstGLTextureTarget, from: S, to: S) OCaps {
    const fname = "_dma_buf_upload_transform_caps_common";
    if (dir == c.GST_PAD_SINK) {
        if (!check.that(eq(from, DMABUF) or eq(from, SYSMEM), fname, "!g_strcmp0 (from_feature, GST_CAPS_FEATURE_MEMORY_DMABUF) || !g_strcmp0 (from_feature, GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY)")) return null;
        if (!check.that(eq(to, GLMEM), fname, "!g_strcmp0 (to_feature, GST_CAPS_FEATURE_MEMORY_GL_MEMORY)")) return null;
    } else {
        if (!check.that(eq(to, DMABUF) or eq(to, SYSMEM), fname, "!g_strcmp0 (to_feature, GST_CAPS_FEATURE_MEMORY_DMABUF) || !g_strcmp0 (to_feature, GST_CAPS_FEATURE_MEMORY_SYSTEM_MEMORY)")) return null;
        if (!check.that(eq(from, GLMEM), fname, "!g_strcmp0 (from_feature, GST_CAPS_FEATURE_MEMORY_GL_MEMORY)")) return null;
    }
    const feat = c.gst_caps_features_new_static_str(from, @as(?*anyopaque, null));
    var src: OCaps = null;
    const ok = filterCaps(caps, feat, &src);
    c.gst_caps_features_free(feat);
    if (!ok) return null;
    var tmp: OCaps = undefined;
    if (c.gst_caps_is_any(src) != 0) {
        tmp = src;
    } else {
        tmp = c.gst_caps_new_empty();
        var i: c.guint = 0;
        const n = c.gst_caps_get_size(src);
        const dmabuf_side = eq(from, DMABUF) or eq(to, DMABUF);
        while (i < n) : (i += 1) {
            const f = c.gst_caps_get_features(src, i);
            if (c.gst_caps_features_contains(f, from) == 0) check.assertFail("gstglupload.c", 1430, fname, "gst_caps_features_contains (features, from_feature)");
            var s = c.gst_caps_get_structure(src, i);
            if (dir == c.GST_PAD_SRC and !checkTarget(s, tmask)) continue;
            s = c.gst_structure_copy(s);
            const keep = if (dmabuf_side) convertFormatField(ctx, s, dir, flags) else filterEglFormats(ctx, s, flags & c.GST_GL_DRM_FORMAT_INCLUDE_EXTERNAL != 0);
            if (!keep) {
                c.gst_structure_free(s);
                continue;
            }
            if (!dmabuf_side and flags & c.GST_GL_DRM_FORMAT_DIRECT_IMPORT != 0) c.gst_structure_set(s, "format", c.G_TYPE_STRING, "RGBA", @as(?*anyopaque, null));
            c.gst_caps_append_structure_full(tmp, s, c.gst_caps_features_copy(f));
        }
        c.gst_caps_unref(src);
        if (c.gst_caps_is_empty(tmp) != 0) {
            c.gst_caps_unref(tmp);
            return null;
        }
    }
    const pass = c.gst_caps_features_new_static_str(OVERLAY, @as(?*anyopaque, null));
    const r = withPassthrough(tmp, to, pass);
    c.gst_caps_features_free(pass);
    c.gst_caps_unref(tmp);
    return r;
}

fn mergeOpt(a: OCaps, b: OCaps) OCaps {
    if (a == null) return b;
    if (b == null) return a;
    return c.gst_caps_merge(a, b);
}

fn eglUsable(ctx: OCtx) bool {
    return vt(ctx).EGLImageTargetTexture2D != null and context.gst_gl_context_get_gl_platform(ctx) == c.GST_GL_PLATFORM_EGL;
}

fn dmaTransform(impl: Impl, ctx: OCtx, dir: Dir, caps: OCaps) OCaps {
    const d = as(Dma, impl);
    if (ctx != null) {
        if (!eglUsable(ctx)) return null;
        if (context.gst_gl_context_check_feature(ctx, "EGL_KHR_image_base") == 0) return null;
        if (!eglctx.supportsModifier(ctx)) return null;
    }
    if (d.target != c.GST_GL_TEXTURE_TARGET_2D) check.assertFail("gstglupload.c", 1506, "_dma_buf_upload_transform_caps", "dmabuf->target == GST_GL_TEXTURE_TARGET_2D");
    const flags: c.GstGLDrmFormatFlags = c.GST_GL_DRM_FORMAT_INCLUDE_EXTERNAL | c.GST_GL_DRM_FORMAT_LINEAR_ONLY;
    const tm = mask(d.target);
    if (dir == c.GST_PAD_SINK) {
        var r = mergeOpt(dmaCommon(caps, ctx, dir, flags, tm, DMABUF, GLMEM), dmaCommon(caps, ctx, dir, flags, tm, SYSMEM, GLMEM));
        if (r == null and ctx == null) {
            r = c.gst_caps_new_static_str_simple("video/x-raw", "format", c.G_TYPE_STRING, "RGBA", @as(?*anyopaque, null));
            c.gst_caps_set_features_simple(r, c.gst_caps_features_new_single_static_str(GLMEM));
        }
        if (r == null) return null;
        const t = intersectTarget(r, mask(c.GST_GL_TEXTURE_TARGET_2D));
        c.gst_caps_unref(r);
        return t;
    }
    const r = mergeOpt(dmaCommon(caps, ctx, dir, flags, tm, GLMEM, DMABUF), dmaCommon(caps, ctx, dir, flags, tm, GLMEM, SYSMEM));
    if (r == null) return null;
    stripTarget(r);
    return r;
}

fn dmaAccept(impl: Impl, buf: OBuf, in_caps: OCaps, out_caps: OCaps) bool {
    const d = as(Dma, impl);
    const u = d.upload;
    const ctx = u[0].context;
    const drm = &pv(u).drm;
    const info = &drm.vinfo;
    const n_mem = c.gst_buffer_n_memory(buf);
    const meta = c.gst_buffer_get_video_meta(buf);
    if (!eglUsable(ctx)) return false;
    if (context.gst_gl_context_check_feature(ctx, "EGL_KHR_image_base") == 0) return false;
    const s = c.gst_caps_get_structure(out_caps, 0);
    if (d.target != format.gst_gl_texture_target_from_string(c.gst_structure_get_string(s, "texture-target"))) return false;
    if (!eglctx.supportsModifier(ctx)) return false;
    if (d.target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES and context.gst_gl_context_check_feature(ctx, "GL_OES_EGL_image_external") == 0) return false;
    if (!hasFeature(in_caps, SYSMEM) and !hasFeature(in_caps, DMABUF)) return false;
    if (d.direct and !eglimage.checkDirectDrm(ctx, drm, d.target)) return false;
    if (!d.direct and drm.drm_modifier != MOD_LINEAR and drm.drm_modifier != MOD_INVALID) return false;
    if (c.gst_is_dmabuf_memory(c.gst_buffer_peek_memory(buf, 0)) == 0) return false;
    var n_planes: c.guint = info.finfo[0].n_planes;
    if (meta != null) {
        info.width = @intCast(meta[0].width);
        info.height = @intCast(meta[0].height);
        n_planes = meta[0].n_planes;
        for (0..n_planes) |i| {
            info.offset[i] = meta[0].offset[i];
            info.stride[i] = meta[0].stride[i];
        }
    }
    if (n_mem > n_planes) return false;
    if (out_caps != d.out_caps) {
        d.out_caps = out_caps;
        if (c.gst_video_info_from_caps(&d.out_info, out_caps) == 0) return false;
        if (meta != null) {
            d.out_info.width = @intCast(meta[0].width);
            d.out_info.height = @intCast(meta[0].height);
            if (!d.direct and d.out_info.finfo[0].flags & c.GST_VIDEO_FORMAT_FLAG_TILED != 0) {
                for (0..meta[0].n_planes) |i| {
                    d.out_info.offset[i] = meta[0].offset[i];
                    d.out_info.stride[i] = meta[0].stride[i];
                }
            }
        }
    }
    if (d.params != null) basememory.gst_gl_allocation_params_free(@ptrCast(d.params));
    d.params = memory.gst_gl_video_allocation_params_new_wrapped_gl_handle(ctx, null, &d.out_info, std.math.maxInt(c.guint), null, d.target, 0, null, null, null);
    if (d.params == null) return false;
    var mems: [MAXP][*c]c.GstMemory = undefined;
    var offset: [MAXP]c.gsize = undefined;
    var fd: [MAXP]c.gint = undefined;
    for (0..n_planes) |i| {
        const plane_size: c.gsize = if (info.finfo[0].format == c.GST_VIDEO_FORMAT_DMA_DRM) 1 else utils.gst_gl_get_plane_data_size(info, null, @intCast(i));
        var idx: c.guint = 0;
        var len: c.guint = 0;
        var skip: c.gsize = 0;
        if (c.gst_buffer_find_memory(buf, info.offset[i], plane_size, &idx, &len, &skip) == 0) return false;
        if (len != 1) return false;
        mems[i] = c.gst_buffer_peek_memory(buf, idx);
        if (c.gst_is_dmabuf_memory(mems[i]) == 0) return false;
        offset[i] = mems[i][0].offset + skip;
        fd[i] = c.gst_dmabuf_memory_get_fd(mems[i]);
    }
    d.n_mem = if (d.direct) 1 else n_planes;
    var prev: [*c]c.GstMemory = null;
    var entry: ?*cache.Entry = null;
    for (0..d.n_mem) |i| {
        d.images[i] = cache.gst_egl_image_cache_lookup(d.cache, mems[i], @intCast(i), &prev, &entry);
        if (d.images[i] == null) {
            d.images[i] = if (d.direct) eglimage.gst_egl_image_from_dmabuf_direct_target_with_dma_drm(ctx, n_planes, &fd, &offset, drm, d.target) else eglimage.gst_egl_image_from_dmabuf(ctx, fd[i], info, @intCast(i), offset[i]);
            if (d.images[i] == null) return false;
            cache.gst_egl_image_cache_store(d.cache, mems[i], @intCast(i), d.images[i], &entry);
        }
        d.formats[i] = d.images[i][0].format;
    }
    return true;
}

fn dmaPerformGl(_: OCtx, data: c.gpointer) callconv(.c) void {
    const d: *Dma = @ptrCast(@alignCast(data));
    const a = c.gst_allocator_find("GLMemoryEGL");
    d.outbuf = c.gst_buffer_new();
    _ = memory.gst_gl_memory_setup_buffer(@ptrCast(a), d.outbuf, d.params, &d.formats, @ptrCast(&d.images), d.n_mem);
    c.gst_object_unref(a);
}

fn dmaPerform(impl: Impl, buf: OBuf, out: *OBuf) Ret {
    const d = as(Dma, impl);
    if (!d.direct and inInfo(d.upload).finfo[0].format != d.out_info.finfo[0].format) return c.GST_GL_UPLOAD_RECONFIGURE;
    c.gst_gl_context_thread_add(d.upload[0].context, dmaPerformGl, d);
    if (d.outbuf == null) return c.GST_GL_UPLOAD_ERROR;
    _ = c.gst_buffer_add_parent_buffer_meta(d.outbuf, buf);
    out.* = d.outbuf;
    d.outbuf = null;
    return c.GST_GL_UPLOAD_DONE;
}

fn dmaFree(impl: Impl) void {
    const d = as(Dma, impl);
    if (d.params != null) basememory.gst_gl_allocation_params_free(@ptrCast(d.params));
    cache.gst_egl_image_cache_unref(d.cache);
    c.g_free(impl);
}

const DMA = Method{ .name = "Dmabuf", .flags = 0, .caps = &dmabuf_caps, .new = dmaNew, .transform = dmaTransform, .accept = dmaAccept, .propose = noPropose, .perform = dmaPerform, .free = dmaFree };

fn directNew(u: OUp) Impl {
    const d = as(Dma, dmaNew(u));
    d.direct = true;
    c.gst_video_info_init(&d.out_info);
    return d;
}

fn directExternalNew(u: OUp) Impl {
    const d = as(Dma, directNew(u));
    d.target = c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES;
    return d;
}

fn directTransform(impl: Impl, ctx: OCtx, dir: Dir, caps: OCaps) OCaps {
    const d = as(Dma, impl);
    var flags: c.GstGLDrmFormatFlags = c.GST_GL_DRM_FORMAT_DIRECT_IMPORT;
    if (d.target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) flags |= c.GST_GL_DRM_FORMAT_INCLUDE_EXTERNAL;
    if (ctx != null) {
        if (!eglUsable(ctx)) return null;
        if (d.target == c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES and context.gst_gl_context_check_feature(ctx, "GL_OES_EGL_image_external") == 0) return null;
        if (!eglctx.supportsModifier(ctx)) return null;
    }
    const tm = mask(d.target);
    if (dir == c.GST_PAD_SINK) {
        const r = mergeOpt(dmaCommon(caps, ctx, dir, flags, tm, DMABUF, GLMEM), dmaCommon(caps, ctx, dir, flags, tm, SYSMEM, GLMEM));
        if (r == null) return null;
        var i: c.guint = 0;
        while (i < c.gst_caps_get_size(r)) : (i += 1) {
            const s = c.gst_caps_get_structure(r, i);
            const f = c.gst_structure_get_string(s, "format");
            if (!(f == null or c.g_strcmp0(f, "RGBA") == 0)) check.assertFail("gstglupload.c", 1959, "_direct_dma_buf_upload_transform_caps", "format == NULL || g_strcmp0 (format, \"RGBA\") == 0");
            c.gst_structure_remove_fields(s, "chroma-site", @as(?*anyopaque, null));
            c.gst_structure_remove_fields(s, "colorimetry", @as(?*anyopaque, null));
        }
        const t = intersectTarget(r, tm);
        c.gst_caps_unref(r);
        return t;
    }
    const r = mergeOpt(dmaCommon(caps, ctx, dir, flags, tm, GLMEM, DMABUF), dmaCommon(caps, ctx, dir, flags, tm, GLMEM, SYSMEM));
    if (r == null) return null;
    stripTarget(r);
    return r;
}

const DIRECT_DMA = Method{ .name = "DirectDmabuf", .flags = 0, .caps = &dmabuf_caps, .new = directNew, .transform = directTransform, .accept = dmaAccept, .propose = noPropose, .perform = dmaPerform, .free = dmaFree };
const DIRECT_DMA_EXTERNAL = Method{ .name = "DirectDmabufExternal", .flags = 0, .caps = &dmabuf_caps, .new = directExternalNew, .transform = directTransform, .accept = dmaAccept, .propose = noPropose, .perform = dmaPerform, .free = dmaFree };

const Meta = struct {
    upload: OUp,
    result: bool,
    meta: [*c]c.GstVideoGLTextureUploadMeta,
    ids: [MAXP * 2]c.guint,
    pool: [*c]c.GstBufferPool,
};

fn metaNew(u: OUp) Impl {
    const p = alloc(Meta);
    p.upload = u;
    return p;
}

fn metaTransform(_: Impl, _: OCtx, dir: Dir, caps: OCaps) OCaps {
    if (dir == c.GST_PAD_SINK) {
        const ff = c.gst_caps_features_from_string(UPLOAD_META);
        var t: OCaps = null;
        const ok = filterCaps(caps, ff, &t);
        c.gst_caps_features_free(ff);
        if (!ok) return null;
        const r = passthroughOverlay(t, GLMEM);
        c.gst_caps_unref(t);
        const r2 = intersectTarget(r, mask(c.GST_GL_TEXTURE_TARGET_2D));
        c.gst_caps_unref(r);
        return r2;
    }
    const r = passthroughOverlay(caps, UPLOAD_META);
    c.gst_caps_set_simple(r, "format", c.G_TYPE_STRING, "RGBA", @as(?*anyopaque, null));
    stripTarget(r);
    return r;
}

fn uploadMeta(buf: OBuf) [*c]c.GstVideoGLTextureUploadMeta {
    return @ptrCast(@alignCast(c.gst_buffer_get_meta(buf, c.gst_video_gl_texture_upload_meta_api_get_type())));
}

fn metaAccept(impl: Impl, buf: OBuf, in: OCaps, out: OCaps) bool {
    const m = as(Meta, impl);
    var ok = true;
    if (!hasFeature(in, UPLOAD_META)) ok = false;
    if (!hasFeature(out, GLMEM)) ok = false;
    if (!ok) return false;
    if (m.pool == null) m.pool = bufferpool.gst_gl_buffer_pool_new(m.upload[0].context);
    if (c.gst_buffer_pool_is_active(m.pool) == 0) {
        const cfg = c.gst_buffer_pool_get_config(m.pool);
        c.gst_buffer_pool_config_set_params(cfg, in, @truncate(inInfo(m.upload).size), 0, 0);
        if (c.gst_buffer_pool_set_config(m.pool, cfg) == 0) return false;
        _ = c.gst_buffer_pool_set_active(m.pool, 1);
    }
    if (buf != null) {
        const meta = uploadMeta(buf);
        if (meta == null) return false;
        if (meta[0].texture_type[0] != c.GST_VIDEO_GL_TEXTURE_TYPE_RGBA) return false;
        if (meta[0].texture_orientation != c.GST_VIDEO_GL_TEXTURE_ORIENTATION_X_NORMAL_Y_NORMAL) return false;
    }
    return true;
}

fn metaPropose(impl: Impl, _: ?*c.GstQuery, q: ?*c.GstQuery) void {
    const ctx = as(Meta, impl).upload[0].context;
    const apis = c.gst_gl_api_to_string(context.gst_gl_context_get_gl_api(ctx));
    const platform = c.gst_gl_platform_to_string(context.gst_gl_context_get_gl_platform(ctx));
    const handle: c.gpointer = @ptrFromInt(context.gst_gl_context_get_gl_context(ctx));
    const s = c.gst_structure_new("GstVideoGLTextureUploadMeta", "gst.gl.GstGLContext", context.gst_gl_context_get_type(), ctx, "gst.gl.context.handle", c.G_TYPE_POINTER, handle, "gst.gl.context.type", c.G_TYPE_STRING, platform, "gst.gl.context.apis", c.G_TYPE_STRING, apis, @as(?*anyopaque, null));
    c.gst_query_add_allocation_meta(q, c.gst_video_gl_texture_upload_meta_api_get_type(), s);
    c.g_free(apis);
    c.g_free(platform);
    c.gst_structure_free(s);
}

fn metaUploadGl(_: OCtx, data: c.gpointer) callconv(.c) void {
    const m: *Meta = @ptrCast(@alignCast(data));
    m.result = c.gst_video_gl_texture_upload_meta_upload(m.meta, &m.ids) != 0;
}

fn metaPerform(impl: Impl, buf: OBuf, out: *OBuf) Ret {
    const m = as(Meta, impl);
    const info = inInfo(m.upload);
    var max: c.guint = info.finfo[0].n_planes;
    if (info.ABI.abi.multiview_mode == c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED) max *= @intCast(info.views);
    m.meta = uploadMeta(buf);
    if (c.gst_buffer_pool_acquire_buffer(m.pool, out, null) != c.GST_FLOW_OK) return c.GST_GL_UPLOAD_ERROR;
    for (&m.ids, 0..) |*id, i| {
        id.* = 0;
        if (i < max) id.* = @as([*c]c.GstGLMemory, @ptrCast(@alignCast(c.gst_buffer_peek_memory(out.*, @intCast(i)))))[0].tex_id;
    }
    c.gst_gl_context_thread_add(m.upload[0].context, metaUploadGl, m);
    return if (m.result) c.GST_GL_UPLOAD_DONE else c.GST_GL_UPLOAD_ERROR;
}

fn metaFree(impl: Impl) void {
    const m = as(Meta, impl);
    if (m.pool != null) c.gst_object_unref(m.pool);
    c.g_free(impl);
}

const UPLOADMETA = Method{ .name = "UploadMeta", .flags = CAN_SHARE, .caps = &meta_caps, .new = metaNew, .transform = metaTransform, .accept = metaAccept, .propose = metaPropose, .perform = metaPerform, .free = metaFree };

const Frame = struct { refs: c.gint, frame: c.GstVideoFrame };

const Raw = struct {
    upload: OUp,
    frame: ?*Frame,
    params: OVParams,
    features: OFeat,
};

fn frameNew(r: *Raw, buf: OBuf) ?*Frame {
    if (buf == null) return null;
    const f: *Frame = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Frame))));
    f.refs = 1;
    const info = inInfo(r.upload);
    if (c.gst_video_frame_map(&f.frame, info, buf, c.GST_MAP_READ) == 0) {
        c.g_free(f);
        return null;
    }
    info.* = f.frame.info;
    info.size = 0;
    for (0..info.finfo[0].n_planes) |i| {
        info.offset[i] = info.size;
        info.size += utils.gst_gl_get_plane_data_size(info, null, @intCast(i));
    }
    return f;
}

fn frameRef(f: *Frame) void {
    _ = @atomicRmw(c.gint, &f.refs, .Add, 1, .seq_cst);
}

fn frameUnref(data: c.gpointer) callconv(.c) void {
    const f: *Frame = @ptrCast(@alignCast(data));
    if (@atomicRmw(c.gint, &f.refs, .Sub, 1, .seq_cst) == 1) {
        c.gst_video_frame_unmap(&f.frame);
        c.g_free(f);
    }
}

fn rawNewWith(u: OUp, feat: S) Impl {
    const r = alloc(Raw);
    r.upload = u;
    r.features = c.gst_caps_features_new_single_static_str(feat);
    return r;
}

fn rawNew(u: OUp) Impl {
    return rawNewWith(u, SYSMEM);
}

fn rawDrmNew(u: OUp) Impl {
    return rawNewWith(u, DMABUF);
}

fn rawTransform(_: Impl, _: OCtx, dir: Dir, caps: OCaps) OCaps {
    if (dir == c.GST_PAD_SINK) {
        const ff = c.gst_caps_features_new_single_static_str(SYSMEM);
        var t: OCaps = null;
        const ok = filterCaps(caps, ff, &t);
        c.gst_caps_features_free(ff);
        if (!ok) return null;
        const r = passthroughOverlay(t, GLMEM);
        c.gst_caps_unref(t);
        const r2 = intersectTarget(r, mask(c.GST_GL_TEXTURE_TARGET_2D) | mask(c.GST_GL_TEXTURE_TARGET_RECTANGLE));
        c.gst_caps_unref(r);
        return r2;
    }
    const r = passthroughOverlay(caps, SYSMEM);
    stripTarget(r);
    return r;
}

fn rawAccept(impl: Impl, buf: OBuf, in: OCaps, out: OCaps) bool {
    const r = as(Raw, impl);
    if (!filterCaps(in, r.features, null)) return false;
    if (!hasFeature(out, GLMEM)) return false;
    if (r.frame) |f| frameUnref(f);
    r.frame = frameNew(r, buf);
    if (r.params != null) basememory.gst_gl_allocation_params_free(@ptrCast(r.params));
    r.params = memory.gst_gl_video_allocation_params_new_wrapped_data(r.upload[0].context, null, inInfo(r.upload), std.math.maxInt(c.guint), null, c.GST_GL_TEXTURE_TARGET_2D, 0, null, r.frame, frameUnref);
    if (r.params == null) return false;
    return r.frame != null;
}

fn rawPropose(_: Impl, _: ?*c.GstQuery, q: ?*c.GstQuery) void {
    c.gst_query_add_allocation_meta(q, c.gst_video_meta_api_get_type(), null);
}

fn rawPerform(impl: Impl, _: OBuf, out: *OBuf) Ret {
    const r = as(Raw, impl);
    const ctx = r.upload[0].context;
    const n: c.guint = inInfo(r.upload).finfo[0].n_planes;
    const a = memory.gst_gl_memory_allocator_get_default(ctx);
    out.* = c.gst_buffer_new();
    r.params[0].parent.context = ctx;
    const f = r.frame.?;
    if (memory.gst_gl_memory_setup_buffer(a, out.*, r.params, null, @ptrCast(&f.frame.data), n) == 0) {
        c.gst_buffer_unref(out.*);
        c.gst_object_unref(a);
        return c.GST_GL_UPLOAD_ERROR;
    }
    for (0..n) |_| frameRef(f);
    _ = syncmeta.gst_buffer_add_gl_sync_meta(ctx, out.*);
    c.gst_object_unref(a);
    frameUnref(f);
    r.frame = null;
    return c.GST_GL_UPLOAD_DONE;
}

fn rawFree(impl: Impl) void {
    const r = as(Raw, impl);
    if (r.params != null) basememory.gst_gl_allocation_params_free(@ptrCast(r.params));
    c.gst_caps_features_free(r.features);
    c.g_free(impl);
}

fn rawDrmTransform(_: Impl, ctx: OCtx, dir: Dir, caps: OCaps) OCaps {
    const flags: c.GstGLDrmFormatFlags = c.GST_GL_DRM_FORMAT_LINEAR_ONLY | c.GST_GL_DRM_FORMAT_INCLUDE_EMULATED;
    const tm = mask(c.GST_GL_TEXTURE_TARGET_2D);
    if (dir == c.GST_PAD_SINK) return dmaCommon(caps, ctx, dir, flags, tm, DMABUF, GLMEM);
    const r = dmaCommon(caps, ctx, dir, flags, tm, GLMEM, DMABUF);
    if (r == null) return null;
    stripTarget(r);
    return r;
}

const RAWDATA = Method{ .name = "Raw Data", .flags = 0, .caps = &raw_caps, .new = rawNew, .transform = rawTransform, .accept = rawAccept, .propose = rawPropose, .perform = rawPerform, .free = rawFree };
const RAWDATA_DRM = Method{ .name = "Raw Data DRM", .flags = 0, .caps = &raw_drm_caps, .new = rawDrmNew, .transform = rawDrmTransform, .accept = rawAccept, .propose = rawPropose, .perform = rawPerform, .free = rawFree };

const METHODS = [_]*const Method{ &PASSTHROUGH, &UDMABUF, &GLMEMORY, &DIRECT_DMA, &DIRECT_DMA_EXTERNAL, &DMA, &UPLOADMETA, &RAWDATA, &RAWDATA_DRM };

pub export fn gst_gl_upload_get_input_template_caps() OCaps {
    c.g_mutex_lock(&global_lock);
    defer c.g_mutex_unlock(&global_lock);
    var r: OCaps = null;
    for (METHODS) |m| {
        const t = c.gst_static_caps_get(m.caps);
        r = if (r == null) t else c.gst_caps_merge(r, t);
    }
    r = c.gst_caps_simplify(r);
    return overlay.gst_gl_overlay_compositor_add_caps(r);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const u = up(o);
    const p = pv(u);
    p.method_i = 0;
    if (u[0].context != null) {
        c.gst_object_unref(u[0].context);
        u[0].context = null;
    }
    clearCaps(&p.in_caps);
    clearCaps(&p.out_caps);
    for (METHODS, 0..) |m, i| m.free(p.impls[i]);
    c.g_free(@ptrCast(p.impls));
    parent.?.finalize.?(o);
}

pub export fn gst_gl_upload_new(ctx: OCtx) OUp {
    const u = up(c.g_object_new(gst_gl_upload_get_type(), null));
    _ = c.gst_object_ref_sink(u);
    if (ctx != null) gst_gl_upload_set_context(u, ctx) else u[0].context = null;
    const p = pv(u);
    p.impls = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Impl) * METHODS.len)));
    for (METHODS, 0..) |m, i| p.impls[i] = m.new(u);
    return u;
}

pub export fn gst_gl_upload_set_context(u: OUp, ctx: OCtx) void {
    if (!check.that(u != null, "gst_gl_upload_set_context", "upload != NULL")) return;
    _ = c.gst_object_replace(@ptrCast(&u[0].context), @ptrCast(ctx));
}

pub export fn gst_gl_upload_transform_caps(u: OUp, ctx: OCtx, dir: Dir, caps: OCaps, filter: OCaps) OCaps {
    objLock(u);
    defer objUnlock(u);
    const p = pv(u);
    var tmp: OCaps = null;
    if (p.method) |m| tmp = m.transform(p.impl.?, ctx, dir, caps);
    if (tmp == null) tmp = c.gst_caps_new_empty();
    for (METHODS, 0..) |m, i| {
        if (p.method == m) continue;
        const t = m.transform(p.impls[i], ctx, dir, caps);
        if (t != null) tmp = c.gst_caps_merge(tmp, t);
    }
    if (filter == null) return tmp;
    const r = c.gst_caps_intersect_full(filter, tmp, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(tmp);
    return r;
}

pub export fn gst_gl_upload_propose_allocation(u: OUp, dq: ?*c.GstQuery, q: ?*c.GstQuery) void {
    for (METHODS, 0..) |m, i| m.propose(pv(u).impls[i], dq, q);
}

fn setCapsUnlocked(u: OUp, in: OCaps, out: OCaps) bool {
    const fname = "_gst_gl_upload_set_caps_unlocked";
    if (!check.that(u != null, fname, "upload != NULL")) return false;
    if (!check.that(c.gst_caps_is_fixed(in) != 0, fname, "gst_caps_is_fixed (in_caps)")) return false;
    const p = pv(u);
    if (p.in_caps != null and p.out_caps != null and c.gst_caps_is_equal(p.in_caps, in) != 0 and c.gst_caps_is_equal(p.out_caps, out) != 0) return true;
    _ = c.gst_caps_replace(&p.in_caps, in);
    _ = c.gst_caps_replace(&p.out_caps, out);
    c.gst_video_info_dma_drm_init(&p.drm);
    if (c.gst_video_is_dma_drm_caps(in) != 0) {
        _ = c.gst_video_info_dma_drm_from_caps(&p.drm, in);
    } else {
        _ = c.gst_video_info_from_caps(&p.drm.vinfo, in);
        _ = c.gst_video_info_dma_drm_from_video_info(&p.drm, &p.drm.vinfo, MOD_LINEAR);
    }
    _ = c.gst_video_info_from_caps(&p.out_info, out);
    p.method = null;
    p.impl = null;
    p.method_i = 0;
    return true;
}

pub export fn gst_gl_upload_set_caps(u: OUp, in: OCaps, out: OCaps) c.gboolean {
    objLock(u);
    defer objUnlock(u);
    return @intFromBool(setCapsUnlocked(u, in, out));
}

pub export fn gst_gl_upload_get_caps(u: OUp, in: [*c]OCaps, out: [*c]OCaps) void {
    objLock(u);
    defer objUnlock(u);
    const p = pv(u);
    if (in != null) in[0] = if (p.in_caps != null) c.gst_caps_ref(p.in_caps) else null;
    if (out != null) out[0] = if (p.out_caps != null) c.gst_caps_ref(p.out_caps) else null;
}

fn findMethod(u: OUp, last: ?Impl) bool {
    const p = pv(u);
    if (p.method_i == 0) {
        p.method_i = p.saved_i;
        p.saved_i = 0;
    }
    if (p.method_i >= METHODS.len) {
        if (last == null) return false;
        p.method_i = 0;
    }
    const i = p.method_i;
    if (last == p.impls[i]) return false;
    p.method = METHODS[i];
    p.impl = p.impls[i];
    p.method_i += 1;
    return true;
}

pub export fn gst_gl_upload_perform_with_buffer(u: OUp, buf: OBuf, out_ptr: [*c]OBuf) Ret {
    const fname = "gst_gl_upload_perform_with_buffer";
    if (!check.that(gtype.instanceOf(u, gst_gl_upload_get_type()), fname, "GST_IS_GL_UPLOAD (upload)")) return 0;
    if (!check.that(buf != null and @as(*c.GstMiniObject, @ptrCast(buf)).type == c.gst_buffer_get_type(), fname, "GST_IS_BUFFER (buffer)")) return 0;
    if (!check.that(out_ptr != null, fname, "outbuf_ptr != NULL")) return 0;
    const p = pv(u);
    const last = p.impl;
    var out: OBuf = null;
    var ret: Ret = c.GST_GL_UPLOAD_ERROR;
    objLock(u);
    if (p.impl == null) _ = findMethod(u, last);
    while (true) {
        const m = p.method.?;
        if (!m.accept(p.impl.?, buf, p.in_caps, p.out_caps)) {
            if (!findMethod(u, last)) {
                objUnlock(u);
                return 0;
            }
            continue;
        }
        ret = m.perform(p.impl.?, buf, &out);
        if (ret == c.GST_GL_UPLOAD_UNSHARED_GL_CONTEXT) {
            for (METHODS, 0..) |mm, i| {
                if (mm == &RAWDATA) {
                    p.method = &RAWDATA;
                    p.impl = p.impls[i];
                    p.method_i = i;
                    break;
                }
            }
            _ = c.gst_buffer_replace(&out, null);
            continue;
        }
        if (ret == c.GST_GL_UPLOAD_DONE or ret == c.GST_GL_UPLOAD_RECONFIGURE) {
            if (last != p.impl and p.impl != null) {
                var caps = p.method.?.transform(p.impl.?, u[0].context, c.GST_PAD_SINK, p.in_caps);
                if (caps == null or c.gst_caps_is_subset(p.out_caps, caps) == 0) {
                    _ = c.gst_buffer_replace(&out, null);
                    ret = c.GST_GL_UPLOAD_RECONFIGURE;
                }
                _ = c.gst_caps_replace(&caps, null);
            }
            break;
        }
        p.impl = null;
        _ = c.gst_buffer_replace(&out, null);
        if (!findMethod(u, last)) {
            objUnlock(u);
            return 0;
        }
    }
    if (out != null and buf != out) _ = c.gst_buffer_copy_into(out, buf, c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_TIMESTAMPS, 0, std.math.maxInt(c.gsize));
    out_ptr[0] = out;
    if (ret == c.GST_GL_UPLOAD_RECONFIGURE) p.saved_i = p.method_i - 1;
    objUnlock(u);
    return ret;
}

pub export fn gst_gl_upload_fixate_caps(u: OUp, dir: Dir, caps: OCaps, other_in: OCaps) OCaps {
    if (dir == c.GST_PAD_SRC) return c.gst_caps_fixate(other_in);
    if (c.gst_caps_is_fixed(other_in) != 0) return other_in;
    var other = other_in;
    objLock(u);
    const p = pv(u);
    if (p.method) |m| {
        const cur = m.transform(p.impl.?, u[0].context, c.GST_PAD_SINK, caps);
        if (cur != null) {
            const t = c.gst_caps_intersect_full(cur, other, c.GST_CAPS_INTERSECT_FIRST);
            if (c.gst_caps_is_empty(t) == 0) {
                c.gst_caps_unref(other);
                other = t;
            } else c.gst_caps_unref(t);
            c.gst_caps_unref(cur);
        }
    }
    objUnlock(u);
    var target: c.GstGLTextureTarget = c.GST_GL_TEXTURE_TARGET_2D;
    while (target <= c.GST_GL_TEXTURE_TARGET_EXTERNAL_OES) : (target += 1) {
        const n = c.gst_caps_get_size(other);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            if (checkTarget(c.gst_caps_get_structure(other, i), mask(target))) break;
        }
        if (i < n) {
            const f = c.gst_caps_get_features(other, i);
            var r = c.gst_caps_new_empty();
            c.gst_caps_append_structure_full(r, c.gst_structure_copy(c.gst_caps_get_structure(other, i)), c.gst_caps_features_copy(f));
            r = c.gst_caps_fixate(r);
            if (c.gst_caps_features_contains(f, GLMEM) != 0) c.gst_caps_set_simple(r, "texture-target", c.G_TYPE_STRING, format.gst_gl_texture_target_to_string(target), @as(?*anyopaque, null));
            c.gst_caps_unref(other);
            return r;
        }
    }
    return c.gst_caps_fixate(other);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const u = up(inst);
    u[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
}

pub export fn gst_gl_upload_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstGLUpload", Class, Up, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glupload", 0, "upload");
            return t;
        }
    }.f);
}
