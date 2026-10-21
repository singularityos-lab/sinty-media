const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const info = @import("info.zig");
const frame = @import("frame.zig");
const meta = @import("meta.zig");
const blend = @import("blend.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Info = c.GstVideoInfo;
const Frame = c.GstVideoFrame;
const Buffer = c.GstBuffer;
const Flags = c.GstVideoOverlayFormatFlags;
const Opaque = c.GstVideoOverlayComposition;
const ORect = c.GstVideoOverlayRectangle;
const CMeta = c.GstVideoOverlayCompositionMeta;

const PREMUL = c.GST_VIDEO_OVERLAY_FORMAT_FLAG_PREMULTIPLIED_ALPHA;
const GLOBAL = c.GST_VIDEO_OVERLAY_FORMAT_FLAG_GLOBAL_ALPHA;
const FMT_RGB = c.GST_VIDEO_FORMAT_BGRA;
const FMT_YUV = c.GST_VIDEO_FORMAT_AYUV;
const STEP = 4;

const Comp = extern struct {
    parent: c.GstMiniObject,
    num: c.guint,
    rects: [*c]?*Rect,
    min_seq: c.guint,
    seq: c.guint,
};

const Rect = extern struct {
    parent: c.GstMiniObject,
    x: c.gint,
    y: c.gint,
    rw: c.guint,
    rh: c.guint,
    info: Info,
    flags: Flags,
    pixels: ?*Buffer,
    seq: c.guint,
    alpha: f32,
    applied: f32,
    initial: ?[*]u8,
    lock: c.GMutex,
    scaled: ?*c.GList,
};

var seqnum: c.gint = 0;

fn nextSeq() c.guint {
    return @bitCast(c.g_atomic_int_add(&seqnum, 1));
}

fn mo(p: anytype) *c.GstMiniObject {
    return @ptrCast(@alignCast(p));
}

fn compOf(p: ?*Opaque) ?*Comp {
    return @ptrCast(@alignCast(p));
}

fn rectOf(p: ?*ORect) ?*Rect {
    return @ptrCast(@alignCast(p));
}

fn isComp(p: ?*const anyopaque) bool {
    const m: ?*const c.GstMiniObject = @ptrCast(@alignCast(p));
    return m != null and m.?.type == gst_video_overlay_composition_get_type();
}

fn isRect(p: ?*const anyopaque) bool {
    const m: ?*const c.GstMiniObject = @ptrCast(@alignCast(p));
    return m != null and m.?.type == gst_video_overlay_rectangle_get_type();
}

fn writable(p: anytype) bool {
    return c.gst_mini_object_is_writable(mo(p)) != 0;
}

fn refRect(r: *Rect) *Rect {
    return @ptrCast(@alignCast(c.gst_mini_object_ref(mo(r))));
}

fn unrefRect(r: *Rect) void {
    c.gst_mini_object_unref(mo(r));
}

fn unrefComp(p: *Comp) void {
    c.gst_mini_object_unref(mo(p));
}

var comp_once: gtype.Once = .{};
var rect_once: gtype.Once = .{};

fn miniRef(p: c.gpointer) callconv(.c) c.gpointer {
    return c.gst_mini_object_ref(@ptrCast(@alignCast(p)));
}

fn miniUnref(p: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

pub export fn gst_video_overlay_composition_get_type() c.GType {
    return comp_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoOverlayComposition", miniRef, miniUnref);
        }
    }.f);
}

pub export fn gst_video_overlay_rectangle_get_type() c.GType {
    return rect_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoOverlayRectangle", miniRef, miniUnref);
        }
    }.f);
}

var api: usize = 0;
var tags = [_][*c]const u8{ "video", "orientation", "size", null };
var minfo: usize = 0;

pub export fn gst_video_overlay_composition_meta_api_get_type() c.GType {
    if (c.g_once_init_enter(&api) != 0) c.g_once_init_leave(&api, c.gst_meta_api_type_register("GstVideoOverlayCompositionMetaAPI", &tags));
    return api;
}

fn metaInit(m: [*c]c.GstMeta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const o: *CMeta = @ptrCast(@alignCast(m));
    o.overlay = null;
    return 1;
}

fn metaFree(m: [*c]c.GstMeta, _: [*c]Buffer) callconv(.c) void {
    const o: *CMeta = @ptrCast(@alignCast(m));
    if (o.overlay) |p| unrefComp(compOf(p).?);
}

fn metaTransform(dest: [*c]Buffer, m: [*c]c.GstMeta, _: [*c]Buffer, t: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const sm: *CMeta = @ptrCast(@alignCast(m));
    if (t == c._gst_meta_transform_copy) {
        const dm: ?*CMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(dest, gst_video_overlay_composition_meta_get_info(), null)));
        if (dm == null) return 0;
        dm.?.overlay = @ptrCast(c.gst_mini_object_ref(mo(sm.overlay)));
        return 1;
    }
    if (t == meta.gst_video_meta_transform_matrix_get_quark()) {
        const tr: [*c]const c.GstVideoMetaTransformMatrix = @ptrCast(@alignCast(data));
        const nc = gst_video_overlay_composition_new(null);
        const n = gst_video_overlay_composition_n_rectangles(sm.overlay);
        var have = false;
        for (0..n) |i| {
            const r = gst_video_overlay_composition_get_rectangle(sm.overlay, @intCast(i));
            const nr = gst_video_overlay_rectangle_copy(r);
            var rr: c.GstVideoRectangle = undefined;
            var w: c.guint = std.math.maxInt(c.gint);
            var h: c.guint = std.math.maxInt(c.gint);
            _ = gst_video_overlay_rectangle_get_render_rectangle(r, &rr.x, &rr.y, &w, &h);
            rr.w = @intCast(@min(w, std.math.maxInt(c.gint)));
            rr.h = @intCast(@min(h, std.math.maxInt(c.gint)));
            if (meta.gst_video_meta_transform_matrix_rectangle(tr, &rr) != 0) {
                gst_video_overlay_rectangle_set_render_rectangle(nr, rr.x, rr.y, @bitCast(rr.w), @bitCast(rr.h));
                gst_video_overlay_composition_add_rectangle(nc, nr);
                have = true;
            }
            unrefRect(rectOf(nr).?);
        }
        var dm: ?*CMeta = null;
        if (have) dm = gst_buffer_add_video_overlay_composition_meta(dest, nc);
        unrefComp(compOf(nc).?);
        return @intFromBool(have and dm != null);
    }
    if (t == meta.gst_video_meta_transform_scale_get_quark()) {
        const tr: *const c.GstVideoMetaTransform = @ptrCast(@alignCast(data));
        const ow = tr.in_info[0].width;
        const nw = tr.out_info[0].width;
        const oh = tr.in_info[0].height;
        const nh = tr.out_info[0].height;
        const nc = gst_video_overlay_composition_new(null);
        const n = gst_video_overlay_composition_n_rectangles(sm.overlay);
        for (0..n) |i| {
            const r = gst_video_overlay_composition_get_rectangle(sm.overlay, @intCast(i));
            const nr = gst_video_overlay_rectangle_copy(r);
            var x: c.gint = 0;
            var y: c.gint = 0;
            var w: c.guint = 0;
            var h: c.guint = 0;
            _ = gst_video_overlay_rectangle_get_render_rectangle(r, &x, &y, &w, &h);
            const nwu: c.guint = @bitCast(nw);
            const nhu: c.guint = @bitCast(nh);
            gst_video_overlay_rectangle_set_render_rectangle(nr, @divTrunc(x * nw, ow), @divTrunc(y * nh, oh), (w *% nwu) / @as(c.guint, @bitCast(ow)), (h *% nhu) / @as(c.guint, @bitCast(oh)));
            gst_video_overlay_composition_add_rectangle(nc, nr);
            unrefRect(rectOf(nr).?);
        }
        const dm = gst_buffer_add_video_overlay_composition_meta(dest, nc);
        unrefComp(compOf(nc).?);
        return @intFromBool(dm != null);
    }
    return 0;
}

fn makeInfo() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_overlay_composition_meta_api_get_type(), "GstVideoOverlayCompositionMeta", @sizeOf(CMeta), metaInit, metaFree, metaTransform);
}

pub export fn gst_video_overlay_composition_meta_get_info() [*c]const c.GstMetaInfo {
    if (c.g_once_init_enter(&minfo) != 0) c.g_once_init_leave(&minfo, @intFromPtr(makeInfo()));
    return @ptrFromInt(minfo);
}

pub export fn gst_buffer_add_video_overlay_composition_meta(buf: [*c]Buffer, comp: ?*Opaque) [*c]CMeta {
    if (!check.that(c.gst_mini_object_is_writable(mo(buf)) != 0, "gst_buffer_add_video_overlay_composition_meta", "gst_buffer_is_writable (buf)")) return null;
    const o: *CMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(buf, gst_video_overlay_composition_meta_get_info(), null)));
    o.overlay = @ptrCast(c.gst_mini_object_ref(mo(comp)));
    return o;
}

fn compFree(m: [*c]c.GstMiniObject) callconv(.c) void {
    const p: *Comp = @ptrCast(@alignCast(m));
    var n = p.num;
    while (n > 0) : (n -= 1) {
        const r = p.rects[n - 1].?;
        c.gst_mini_object_remove_parent(mo(r), mo(p));
        unrefRect(r);
    }
    c.g_free(@ptrCast(p.rects));
    p.rects = null;
    p.num = 0;
    c.g_free(p);
}

fn compCopy(m: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    return @ptrCast(@alignCast(gst_video_overlay_composition_copy(@ptrCast(@constCast(m)))));
}

pub export fn gst_video_overlay_composition_new(rectangle: ?*ORect) ?*Opaque {
    if (!check.that(isRect(rectangle) or rectangle == null, "gst_video_overlay_composition_new", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle) || rectangle == NULL")) return null;
    const p: *Comp = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Comp))));
    c.gst_mini_object_init(mo(p), 0, gst_video_overlay_composition_get_type(), compCopy, null, compFree);
    p.rects = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(?*Rect) * STEP)));
    p.seq = nextSeq();
    p.min_seq = p.seq;
    if (rectOf(rectangle)) |r| {
        p.min_seq = r.seq;
        gst_video_overlay_composition_add_rectangle(@ptrCast(p), rectangle);
    }
    return @ptrCast(p);
}

pub export fn gst_video_overlay_composition_add_rectangle(comp: ?*Opaque, rectangle: ?*ORect) void {
    const fname = "gst_video_overlay_composition_add_rectangle";
    if (!check.that(isComp(comp), fname, "GST_IS_VIDEO_OVERLAY_COMPOSITION (comp)")) return;
    if (!check.that(isRect(rectangle), fname, "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return;
    if (!check.that(writable(comp), fname, "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (comp))")) return;
    const p = compOf(comp).?;
    const r = rectOf(rectangle).?;
    if (p.num % STEP == 0) p.rects = @ptrCast(@alignCast(c.g_realloc(@ptrCast(p.rects), @sizeOf(?*Rect) * (p.num + STEP))));
    p.rects[p.num] = refRect(r);
    c.gst_mini_object_add_parent(mo(r), mo(p));
    p.num += 1;
    p.min_seq = @min(p.min_seq, r.seq);
}

pub export fn gst_video_overlay_composition_n_rectangles(comp: ?*Opaque) c.guint {
    if (!check.that(isComp(comp), "gst_video_overlay_composition_n_rectangles", "GST_IS_VIDEO_OVERLAY_COMPOSITION (comp)")) return 0;
    return compOf(comp).?.num;
}

pub export fn gst_video_overlay_composition_get_rectangle(comp: ?*Opaque, n: c.guint) ?*ORect {
    if (!check.that(isComp(comp), "gst_video_overlay_composition_get_rectangle", "GST_IS_VIDEO_OVERLAY_COMPOSITION (comp)")) return null;
    const p = compOf(comp).?;
    if (n >= p.num) return null;
    return @ptrCast(p.rects[n]);
}

pub export fn gst_video_overlay_composition_blend(comp: ?*Opaque, video_buf: [*c]Frame) c.gboolean {
    const fname = "gst_video_overlay_composition_blend";
    if (!check.that(isComp(comp), fname, "GST_IS_VIDEO_OVERLAY_COMPOSITION (comp)")) return 0;
    if (!check.that(video_buf != null, fname, "video_buf != NULL")) return 0;
    const p = compOf(comp).?;
    var ret: c.gboolean = 1;
    var pixels: [*c]Buffer = null;
    for (0..p.num) |n| {
        const r = p.rects[n].?;
        var scaled: Info = undefined;
        var vi: *Info = &r.info;
        if (r.info.width != r.rw or r.info.height != r.rh) {
            blend.gst_video_blend_scale_linear_RGBA(&r.info, r.pixels, @bitCast(r.rh), @bitCast(r.rw), &scaled, &pixels);
            vi = &scaled;
        } else {
            pixels = c.gst_buffer_ref(r.pixels);
        }
        var rf: Frame = undefined;
        _ = frame.gst_video_frame_map(&rf, vi, pixels, c.GST_MAP_READ);
        ret = blend.gst_video_blend(video_buf, &rf, r.x, r.y, r.alpha);
        frame.gst_video_frame_unmap(&rf);
        c.gst_buffer_unref(pixels);
    }
    return ret;
}

pub export fn gst_video_overlay_composition_copy(comp: ?*Opaque) ?*Opaque {
    if (!check.that(isComp(comp), "gst_video_overlay_composition_copy", "GST_IS_VIDEO_OVERLAY_COMPOSITION (comp)")) return null;
    const p = compOf(comp).?;
    if (p.num == 0) return gst_video_overlay_composition_new(null);
    var r = gst_video_overlay_rectangle_copy(@ptrCast(p.rects[0]));
    const cp = gst_video_overlay_composition_new(r);
    unrefRect(rectOf(r).?);
    for (1..p.num) |n| {
        r = gst_video_overlay_rectangle_copy(@ptrCast(p.rects[n]));
        gst_video_overlay_composition_add_rectangle(cp, r);
        unrefRect(rectOf(r).?);
    }
    return cp;
}

pub export fn gst_video_overlay_composition_make_writable(comp: ?*Opaque) ?*Opaque {
    if (!check.that(isComp(comp), "gst_video_overlay_composition_make_writable", "GST_IS_VIDEO_OVERLAY_COMPOSITION (comp)")) return null;
    const p = compOf(comp).?;
    if (writable(p)) {
        var ok = true;
        for (0..p.num) |n| {
            if (!writable(p.rects[n].?)) {
                ok = false;
                break;
            }
        }
        if (ok) return comp;
    }
    const w = gst_video_overlay_composition_copy(comp);
    unrefComp(p);
    return w;
}

pub export fn gst_video_overlay_composition_get_seqnum(comp: ?*Opaque) c.guint {
    if (!check.that(isComp(comp), "gst_video_overlay_composition_get_seqnum", "GST_IS_VIDEO_OVERLAY_COMPOSITION (comp)")) return 0;
    return compOf(comp).?.seq;
}

fn rectFree(m: [*c]c.GstMiniObject) callconv(.c) void {
    const r: *Rect = @ptrCast(@alignCast(m));
    c.gst_mini_object_remove_parent(mo(r.pixels), mo(r));
    if (r.pixels) |b| c.gst_buffer_unref(b);
    r.pixels = null;
    while (r.scaled) |l| {
        unrefRect(@ptrCast(@alignCast(l.*.data)));
        r.scaled = c.g_list_delete_link(r.scaled, l);
    }
    c.g_free(r.initial);
    c.g_mutex_clear(&r.lock);
    c.g_free(r);
}

fn rectCopy(m: [*c]const c.GstMiniObject) callconv(.c) [*c]c.GstMiniObject {
    return @ptrCast(@alignCast(gst_video_overlay_rectangle_copy(@ptrCast(@constCast(m)))));
}

fn validFlags(f: Flags) bool {
    return f & ~@as(Flags, PREMUL | GLOBAL) == 0;
}

fn sameAlpha(a: Flags, b: Flags) bool {
    return (a ^ b) & PREMUL == 0;
}

pub export fn gst_video_overlay_rectangle_new_raw(pixels: [*c]Buffer, render_x: c.gint, render_y: c.gint, render_width: c.guint, render_height: c.guint, flags: Flags) ?*ORect {
    const fname = "gst_video_overlay_rectangle_new_raw";
    const isbuf = pixels != null and mo(pixels).type == c.gst_buffer_get_type();
    if (!check.that(isbuf, fname, "GST_IS_BUFFER (pixels)")) return null;
    if (!check.that(render_height > 0 and render_width > 0, fname, "render_height > 0 && render_width > 0")) return null;
    if (!check.that(validFlags(flags), fname, "gst_video_overlay_rectangle_check_flags (flags)")) return null;
    const vm = meta.gst_buffer_get_video_meta(pixels);
    if (!check.that(vm != null, fname, "vmeta")) return null;
    if (!check.that(vm[0].format == FMT_RGB or vm[0].format == FMT_YUV, fname, "vmeta->format == GST_VIDEO_OVERLAY_COMPOSITION_FORMAT_RGB || vmeta->format == GST_VIDEO_OVERLAY_COMPOSITION_FORMAT_YUV")) return null;
    if (!check.that(vm[0].flags == c.GST_VIDEO_FRAME_FLAG_NONE, fname, "vmeta->flags == GST_VIDEO_FRAME_FLAG_NONE")) return null;
    const fmt = vm[0].format;
    const w = vm[0].width;
    const h = vm[0].height;
    if (!check.that(c.gst_buffer_get_size(pixels) >= h *% w *% 4, fname, "gst_buffer_get_size (pixels) >= height * width * 4")) return null;
    if (!check.that(h > 0 and w > 0, fname, "height > 0 && width > 0")) return null;
    const r: *Rect = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Rect))));
    c.gst_mini_object_init(mo(r), 0, gst_video_overlay_rectangle_get_type(), rectCopy, null, rectFree);
    c.g_mutex_init(&r.lock);
    r.pixels = c.gst_buffer_ref(pixels);
    c.gst_mini_object_add_parent(mo(pixels), mo(r));
    r.scaled = null;
    info.gst_video_info_init(&r.info);
    if (info.gst_video_info_set_format(&r.info, fmt, w, h) == 0) {
        c.gst_mini_object_unref(mo(r));
        return null;
    }
    if (flags & PREMUL != 0) r.info.flags |= c.GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA;
    r.x = render_x;
    r.y = render_y;
    r.rw = render_width;
    r.rh = render_height;
    r.alpha = 1.0;
    r.applied = 1.0;
    r.initial = null;
    r.flags = flags;
    r.seq = nextSeq();
    return @ptrCast(r);
}

pub export fn gst_video_overlay_rectangle_get_render_rectangle(rectangle: ?*ORect, render_x: [*c]c.gint, render_y: [*c]c.gint, render_width: [*c]c.guint, render_height: [*c]c.guint) c.gboolean {
    if (!check.that(isRect(rectangle), "gst_video_overlay_rectangle_get_render_rectangle", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return 0;
    const r = rectOf(rectangle).?;
    if (render_x != null) render_x[0] = r.x;
    if (render_y != null) render_y[0] = r.y;
    if (render_width != null) render_width[0] = r.rw;
    if (render_height != null) render_height[0] = r.rh;
    return 1;
}

pub export fn gst_video_overlay_rectangle_set_render_rectangle(rectangle: ?*ORect, render_x: c.gint, render_y: c.gint, render_width: c.guint, render_height: c.guint) void {
    const fname = "gst_video_overlay_rectangle_set_render_rectangle";
    if (!check.that(isRect(rectangle), fname, "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return;
    if (!check.that(writable(rectangle), fname, "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (rectangle))")) return;
    const r = rectOf(rectangle).?;
    r.x = render_x;
    r.y = render_y;
    r.rw = render_width;
    r.rh = render_height;
}

fn alphaOffset(i: *const Info) c.guint {
    return i.finfo[0].poffset[3];
}

fn eachPixel(f: *Frame, comptime k: fn ([*]u8, usize) void) void {
    const w: usize = @intCast(f.info.width);
    const h: usize = @intCast(f.info.height);
    const stride: usize = @intCast(f.info.stride[0]);
    const data: [*]u8 = @ptrCast(f.data[0]);
    const a: usize = f.info.finfo[0].poffset[3];
    for (0..h) |j| {
        var line = data + stride * j;
        for (0..w) |_| {
            k(line, a);
            line += 4;
        }
    }
}

fn premulPx(p: [*]u8, a: usize) void {
    const al: u32 = p[a];
    for (0..4) |k| {
        if (k != a) p[k] = @intCast(@as(u32, p[k]) * al / 255);
    }
}

fn unpremulPx(p: [*]u8, a: usize) void {
    const al: u32 = p[a];
    if (al == 0) return;
    for (0..4) |k| {
        if (k != a) p[k] = @intCast(@min((@as(u32, p[k]) * 255 + al / 2) / al, 255));
    }
}

fn premultiply(f: *Frame) void {
    switch (alphaOffset(&f.info)) {
        0, 3 => eachPixel(f, premulPx),
        else => unreachable,
    }
}

fn unpremultiply(f: *Frame) void {
    switch (alphaOffset(&f.info)) {
        0, 3 => eachPixel(f, unpremulPx),
        else => unreachable,
    }
}

fn extractAlpha(r: *Rect) void {
    const ao = alphaOffset(&r.info);
    if (!check.that(ao == 0 or ao == 3, "gst_video_overlay_rectangle_extract_alpha", "alpha_offset == 0 || alpha_offset == 3")) return;
    var f: Frame = undefined;
    _ = frame.gst_video_frame_map(&f, &r.info, r.pixels, c.GST_MAP_READ);
    var src: [*]u8 = @ptrCast(f.data[0]);
    const w: usize = @intCast(r.info.width);
    const h: usize = @intCast(r.info.height);
    const stride: usize = @intCast(r.info.stride[0]);
    c.g_free(r.initial);
    const dst: [*]u8 = @ptrCast(c.g_malloc(w * h));
    r.initial = dst;
    var o: usize = 0;
    for (0..h) |_| {
        for (0..w) |_| {
            dst[o] = src[ao];
            o += 1;
            src += 4;
        }
        src += stride - 4 * w;
    }
    frame.gst_video_frame_unmap(&f);
}

fn cvt(x: f64) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

fn applyAlpha(r: *Rect, ga: f32) void {
    const ao = alphaOffset(&r.info);
    if (!check.that(ao == 0 or ao == 3, "gst_video_overlay_rectangle_apply_global_alpha", "alpha_offset == 0 || alpha_offset == 3")) return;
    if (ga == r.applied) return;
    if (r.initial == null) extractAlpha(r);
    var src = r.initial.?;
    if (c.gst_mini_object_is_writable(mo(r.pixels)) == 0) {
        c.gst_mini_object_remove_parent(mo(r.pixels), mo(r));
        r.pixels = c.gst_buffer_copy(r.pixels);
        c.gst_mini_object_add_parent(mo(r.pixels), mo(r));
    }
    var f: Frame = undefined;
    _ = frame.gst_video_frame_map(&f, &r.info, r.pixels, c.GST_MAP_READ);
    var dst: [*]u8 = @ptrCast(f.data[0]);
    const w: usize = @intCast(r.info.width);
    const h: usize = @intCast(r.info.height);
    const stride: usize = @intCast(r.info.stride[0]);
    const a: usize = ao;
    const ch = [3]usize{ (a + 1) % 4, (a + 2) % 4, (a + 3) % 4 };
    for (0..h) |_| {
        for (0..w) |_| {
            const na: u8 = @intFromFloat(@as(f32, @floatFromInt(src[0])) * ga);
            if (r.flags & PREMUL != 0) {
                for (ch) |k| {
                    const q: f64 = @as(f64, @floatFromInt(@as(u32, dst[k]) * 255)) / @as(f64, @floatFromInt(dst[a]));
                    const t: u8 = @truncate(@as(u32, @bitCast(cvt(q))));
                    dst[k] = @truncate(@as(u32, t) * na / 255);
                }
            }
            dst[a] = na;
            src += 1;
            dst += 4;
        }
        dst += stride - 4 * w;
    }
    frame.gst_video_frame_unmap(&f);
    r.applied = ga;
}

fn convert(src: *Info, sbuf: ?*Buffer, dfmt: c.GstVideoFormat, dest: *Info, dbuf: *[*c]Buffer) void {
    const fmt = src.finfo[0].format;
    const w = src.width;
    const h = src.height;
    info.gst_video_info_init(dest);
    if (info.gst_video_info_set_format(dest, dfmt, @bitCast(w), @bitCast(h)) == 0) {
        check.warnReached("video-overlay-composition.c", "gst_video_overlay_rectangle_convert");
        return;
    }
    dbuf.* = c.gst_buffer_new_allocate(null, dest.size, null);
    var sf: Frame = undefined;
    var df: Frame = undefined;
    _ = frame.gst_video_frame_map(&sf, src, sbuf, c.GST_MAP_READ);
    _ = frame.gst_video_frame_map(&df, dest, dbuf.*, c.GST_MAP_WRITE);
    var sd: [*]u8 = @ptrCast(sf.data[0]);
    var dd: [*]u8 = @ptrCast(df.data[0]);
    const stride: usize = @intCast(sf.info.stride[0]);
    const wu: usize = @intCast(w);
    const hu: usize = @intCast(h);
    if (fmt == FMT_YUV and dfmt == FMT_RGB) {
        for (0..hu) |_| {
            for (0..wu) |_| {
                const v = std.mem.readInt(u32, sd[0..4], .big);
                const a: i32 = @intCast(v >> 24);
                const y: i32 = @intCast((v >> 16) & 0xff);
                const u: i32 = @intCast((v >> 8) & 0xff);
                const vv: i32 = @intCast(v & 0xff);
                const r = std.math.clamp((298 * y + 459 * vv - 63514) >> 8, 0, 255);
                const g = std.math.clamp((298 * y - 55 * u - 136 * vv + 19681) >> 8, 0, 255);
                const b = std.math.clamp((298 * y + 541 * u - 73988) >> 8, 0, 255);
                const o: u32 = @bitCast((a << 24) | (r << 16) | (g << 8) | b);
                std.mem.writeInt(u32, dd[0..4], o, .little);
                sd += 4;
                dd += 4;
            }
            sd += stride - 4 * wu;
        }
    } else if (fmt == FMT_RGB and dfmt == FMT_YUV) {
        for (0..hu) |_| {
            for (0..wu) |_| {
                const v: i32 = @bitCast(std.mem.readInt(u32, sd[0..4], .little));
                const a = v >> 24;
                const r = (v >> 16) & 0xff;
                const g = (v >> 8) & 0xff;
                const b = v & 0xff;
                const y = std.math.clamp((47 * r + 157 * g + 16 * b + 4096) >> 8, 0, 255);
                const u = std.math.clamp((-26 * r - 87 * g + 112 * b + 32768) >> 8, 0, 255);
                const vv = std.math.clamp((112 * r - 102 * g - 10 * b + 32768) >> 8, 0, 255);
                std.mem.writeInt(u32, dd[0..4], @bitCast((a << 24) | (y << 16) | (u << 8) | vv), .big);
                sd += 4;
                dd += 4;
            }
            sd += stride - 4 * wu;
        }
    } else unreachable;
    frame.gst_video_frame_unmap(&sf);
    frame.gst_video_frame_unmap(&df);
}

fn pixelsRaw(rectangle: ?*ORect, flags: Flags, unscaled: bool, wanted: c.GstVideoFormat) [*c]Buffer {
    const fname = "gst_video_overlay_rectangle_get_pixels_raw_internal";
    if (!check.that(isRect(rectangle), fname, "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return null;
    if (!check.that(validFlags(flags), fname, "gst_video_overlay_rectangle_check_flags (flags)")) return null;
    const r = rectOf(rectangle).?;
    var width: c.guint = @bitCast(r.info.width);
    var height: c.guint = @bitCast(r.info.height);
    const ww = if (unscaled) width else r.rw;
    const wh = if (unscaled) height else r.rh;
    const fmt = r.info.finfo[0].format;
    const apply = r.flags & GLOBAL != 0 and flags & GLOBAL == 0;
    const revert = r.flags & GLOBAL != 0 and flags & GLOBAL != 0;
    var scaled: ?*Rect = null;
    var conv: ?*Rect = null;
    blk: {
        if (ww == width and wh == height and wanted == fmt and sameAlpha(r.flags, flags)) {
            if ((!apply or r.applied == r.alpha) and (!revert or r.applied == 1.0)) return r.pixels;
            scaled = r;
            break :blk;
        }
        c.g_mutex_lock(&r.lock);
        var l = r.scaled;
        while (l) |n| : (l = n.*.next) {
            const s: *Rect = @ptrCast(@alignCast(n.*.data));
            if (s.info.width == ww and s.info.height == wh and s.info.finfo[0].format == wanted and sameAlpha(s.flags, flags)) {
                scaled = s;
                break;
            }
        }
        c.g_mutex_unlock(&r.lock);
        if (scaled != null) break :blk;
        if (fmt != wanted) {
            c.g_mutex_lock(&r.lock);
            l = r.scaled;
            while (l) |n| : (l = n.*.next) {
                const s: *Rect = @ptrCast(@alignCast(n.*.data));
                if (s.info.finfo[0].format == wanted and sameAlpha(s.flags, flags)) {
                    conv = s;
                    break;
                }
            }
            c.g_mutex_unlock(&r.lock);
        } else conv = r;
        if (conv == null) {
            var ci: Info = undefined;
            var buf: [*c]Buffer = null;
            convert(&r.info, r.pixels, wanted, &ci, &buf);
            _ = meta.gst_buffer_add_video_meta(buf, c.GST_VIDEO_FRAME_FLAG_NONE, ci.finfo[0].format, width, height);
            conv = rectOf(gst_video_overlay_rectangle_new_raw(buf, 0, 0, width, height, r.flags));
            if (r.alpha != 1.0) gst_video_overlay_rectangle_set_global_alpha(@ptrCast(scaled), r.alpha);
            c.gst_buffer_unref(buf);
            c.g_mutex_lock(&r.lock);
            r.scaled = c.g_list_prepend(r.scaled, conv);
            c.g_mutex_unlock(&r.lock);
        }
        const cr = conv.?;
        width = @bitCast(cr.info.width);
        height = @bitCast(cr.info.height);
        var buf: [*c]Buffer = null;
        var fi: Info = undefined;
        if (ww != width or wh != height) {
            var si: Info = undefined;
            blend.gst_video_blend_scale_linear_RGBA(&cr.info, cr.pixels, @bitCast(wh), @bitCast(ww), &si, &buf);
            fi = si;
            _ = meta.gst_buffer_add_video_meta(buf, c.GST_VIDEO_FRAME_FLAG_NONE, cr.info.finfo[0].format, ww, wh);
        } else if (!sameAlpha(cr.flags, flags)) {
            buf = c.gst_buffer_copy(cr.pixels);
            fi = cr.info;
        } else {
            scaled = cr;
            break :blk;
        }
        var nf = cr.flags;
        var f: Frame = undefined;
        _ = frame.gst_video_frame_map(&f, &fi, buf, c.GST_MAP_READWRITE);
        if (!sameAlpha(cr.flags, flags)) {
            if (r.flags & PREMUL != 0) {
                unpremultiply(&f);
                nf &= ~@as(Flags, PREMUL);
            } else {
                premultiply(&f);
                nf |= PREMUL;
            }
        }
        frame.gst_video_frame_unmap(&f);
        scaled = rectOf(gst_video_overlay_rectangle_new_raw(buf, 0, 0, ww, wh, nf));
        if (cr.alpha != 1.0) gst_video_overlay_rectangle_set_global_alpha(@ptrCast(scaled), cr.alpha);
        c.gst_buffer_unref(buf);
        c.g_mutex_lock(&r.lock);
        r.scaled = c.g_list_prepend(r.scaled, scaled);
        c.g_mutex_unlock(&r.lock);
    }
    const s = scaled.?;
    c.g_mutex_lock(&r.lock);
    if (apply and s.applied != r.alpha) {
        applyAlpha(s, r.alpha);
        gst_video_overlay_rectangle_set_global_alpha(@ptrCast(s), r.alpha);
    } else if (revert and s.applied != 1.0) {
        applyAlpha(s, 1.0);
    }
    c.g_mutex_unlock(&r.lock);
    return s.pixels;
}

pub export fn gst_video_overlay_rectangle_get_pixels_raw(rectangle: ?*ORect, flags: Flags) [*c]Buffer {
    return pixelsRaw(rectangle, flags, false, rectOf(rectangle).?.info.finfo[0].format);
}

pub export fn gst_video_overlay_rectangle_get_pixels_argb(rectangle: ?*ORect, flags: Flags) [*c]Buffer {
    return pixelsRaw(rectangle, flags, false, FMT_RGB);
}

pub export fn gst_video_overlay_rectangle_get_pixels_ayuv(rectangle: ?*ORect, flags: Flags) [*c]Buffer {
    return pixelsRaw(rectangle, flags, false, FMT_YUV);
}

pub export fn gst_video_overlay_rectangle_get_pixels_unscaled_raw(rectangle: ?*ORect, flags: Flags) [*c]Buffer {
    if (!check.that(isRect(rectangle), "gst_video_overlay_rectangle_get_pixels_unscaled_raw", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return null;
    return pixelsRaw(rectangle, flags, true, rectOf(rectangle).?.info.finfo[0].format);
}

pub export fn gst_video_overlay_rectangle_get_pixels_unscaled_argb(rectangle: ?*ORect, flags: Flags) [*c]Buffer {
    if (!check.that(isRect(rectangle), "gst_video_overlay_rectangle_get_pixels_unscaled_argb", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return null;
    return pixelsRaw(rectangle, flags, true, FMT_RGB);
}

pub export fn gst_video_overlay_rectangle_get_pixels_unscaled_ayuv(rectangle: ?*ORect, flags: Flags) [*c]Buffer {
    if (!check.that(isRect(rectangle), "gst_video_overlay_rectangle_get_pixels_unscaled_ayuv", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return null;
    return pixelsRaw(rectangle, flags, true, FMT_YUV);
}

pub export fn gst_video_overlay_rectangle_get_flags(rectangle: ?*ORect) Flags {
    if (!check.that(isRect(rectangle), "gst_video_overlay_rectangle_get_flags", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return c.GST_VIDEO_OVERLAY_FORMAT_FLAG_NONE;
    return rectOf(rectangle).?.flags;
}

pub export fn gst_video_overlay_rectangle_get_global_alpha(rectangle: ?*ORect) f32 {
    if (!check.that(isRect(rectangle), "gst_video_overlay_rectangle_get_global_alpha", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return -1;
    return rectOf(rectangle).?.alpha;
}

pub export fn gst_video_overlay_rectangle_set_global_alpha(rectangle: ?*ORect, global_alpha: f32) void {
    const fname = "gst_video_overlay_rectangle_set_global_alpha";
    if (!check.that(isRect(rectangle), fname, "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return;
    if (!check.that(writable(rectangle), fname, "gst_mini_object_is_writable (GST_MINI_OBJECT_CAST (rectangle))")) return;
    if (!check.that(global_alpha >= 0 and global_alpha <= 1, fname, "global_alpha >= 0 && global_alpha <= 1")) return;
    const r = rectOf(rectangle).?;
    if (r.alpha != global_alpha) {
        r.alpha = global_alpha;
        if (global_alpha != 1) r.flags |= GLOBAL else r.flags &= ~@as(Flags, GLOBAL);
        r.seq = nextSeq();
    }
}

pub export fn gst_video_overlay_rectangle_copy(rectangle: ?*ORect) ?*ORect {
    if (!check.that(isRect(rectangle), "gst_video_overlay_rectangle_copy", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return null;
    const r = rectOf(rectangle).?;
    const cp = gst_video_overlay_rectangle_new_raw(r.pixels, r.x, r.y, r.rw, r.rh, r.flags);
    if (r.alpha != 1) gst_video_overlay_rectangle_set_global_alpha(cp, r.alpha);
    return cp;
}

pub export fn gst_video_overlay_rectangle_get_seqnum(rectangle: ?*ORect) c.guint {
    if (!check.that(isRect(rectangle), "gst_video_overlay_rectangle_get_seqnum", "GST_IS_VIDEO_OVERLAY_RECTANGLE (rectangle)")) return 0;
    return rectOf(rectangle).?.seq;
}
