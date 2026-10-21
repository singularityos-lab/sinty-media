const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

var seed: u32 = 7;

fn rnd() u8 {
    seed = seed *% 1103515245 +% 12345;
    return @truncate(seed >> 16);
}

fn fill(buf: *c.GstBuffer) void {
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buf, &mi, c.GST_MAP_WRITE);
    for (0..mi.size) |i| mi.data[i] = rnd();
    c.gst_buffer_unmap(buf, &mi);
}

fn hash(buf: *c.GstBuffer) u32 {
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buf, &mi, c.GST_MAP_READ);
    var h: u32 = 2166136261;
    for (mi.data[0..mi.size]) |b| h = (h ^ b) *% 16777619;
    c.gst_buffer_unmap(buf, &mi);
    return h;
}

const dests = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_YUY2, c.GST_VIDEO_FORMAT_UYVY, c.GST_VIDEO_FORMAT_Y444, c.GST_VIDEO_FORMAT_RGB, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_GRAY8, c.GST_VIDEO_FORMAT_RGB16, c.GST_VIDEO_FORMAT_ARGB64, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_I420_10LE, c.GST_VIDEO_FORMAT_P010_10LE, c.GST_VIDEO_FORMAT_v210, c.GST_VIDEO_FORMAT_Y42B, c.GST_VIDEO_FORMAT_GBR };
const srcs = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_ARGB, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_ABGR };
const pos = [_][2]c.gint{ .{ 0, 0 }, .{ -3, -2 }, .{ 30, 15 }, .{ 5, 4 }, .{ 36, 0 }, .{ -20, 3 } };

fn blends() void {
    out("blend", .{});
    for (dests) |df| for (srcs) |sf| for (0..4) |pm| for ([_]f32{ 1.0, 0.5, 0.0 }) |ga| for (pos) |p| {
        var di: c.GstVideoInfo = undefined;
        var si: c.GstVideoInfo = undefined;
        _ = c.gst_video_info_set_format(&di, df, 36, 20);
        _ = c.gst_video_info_set_format(&si, sf, 13, 9);
        if (pm & 1 != 0) si.flags |= c.GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA;
        if (pm & 2 != 0) di.flags |= c.GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA;
        const db = c.gst_buffer_new_allocate(null, di.size, null).?;
        const sb = c.gst_buffer_new_allocate(null, si.size, null).?;
        seed = df * 31 + sf;
        fill(db);
        fill(sb);
        var dfr: c.GstVideoFrame = undefined;
        var sfr: c.GstVideoFrame = undefined;
        _ = c.gst_video_frame_map(&dfr, &di, db, c.GST_MAP_READWRITE);
        _ = c.gst_video_frame_map(&sfr, &si, sb, c.GST_MAP_READ);
        const r = c.gst_video_blend(&dfr, &sfr, p[0], p[1], ga);
        c.gst_video_frame_unmap(&sfr);
        c.gst_video_frame_unmap(&dfr);
        out("  {d} on {d} pm{d} ga{d} at {any}: {d} {x}", .{ sf, df, pm, ga, p, r, hash(db) });
        c.gst_buffer_unref(db);
        c.gst_buffer_unref(sb);
    };
}

fn scales() void {
    out("scale", .{});
    for ([_][2]c.guint{ .{ 1, 1 }, .{ 7, 5 }, .{ 16, 16 }, .{ 33, 3 } }) |s| for ([_][2]c.gint{ .{ 1, 1 }, .{ 9, 4 }, .{ 32, 32 }, .{ 5, 40 }, .{ 64, 2 } }) |d| for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_AYUV }) |f| {
        var si: c.GstVideoInfo = undefined;
        _ = c.gst_video_info_set_format(&si, f, s[0], s[1]);
        const sb = c.gst_buffer_new_allocate(null, si.size, null).?;
        seed = s[0] * 7 + s[1];
        fill(sb);
        var di: c.GstVideoInfo = undefined;
        var db: ?*c.GstBuffer = null;
        c.gst_video_blend_scale_linear_RGBA(&si, sb, d[1], d[0], &di, &db);
        out("  {d} {any} -> {any}: {d}x{d} {d} {x}", .{ f, s, d, di.width, di.height, di.size, hash(db.?) });
        c.gst_buffer_unref(db);
        c.gst_buffer_unref(sb);
    };
}

fn pixelBuf(f: c.GstVideoFormat, w: c.guint, h: c.guint) *c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, w * h * 4, null).?;
    fill(b);
    _ = c.gst_buffer_add_video_meta(b, c.GST_VIDEO_FRAME_FLAG_NONE, f, w, h);
    return b;
}

fn rectInfo(r: ?*c.GstVideoOverlayRectangle) void {
    var x: c.gint = 0;
    var y: c.gint = 0;
    var w: c.guint = 0;
    var h: c.guint = 0;
    _ = c.gst_video_overlay_rectangle_get_render_rectangle(r, &x, &y, &w, &h);
    out("    rect {d},{d} {d}x{d} flags {d} ga {d} seq {d}", .{ x, y, w, h, c.gst_video_overlay_rectangle_get_flags(r), c.gst_video_overlay_rectangle_get_global_alpha(r), c.gst_video_overlay_rectangle_get_seqnum(r) });
}

fn pixels(r: ?*c.GstVideoOverlayRectangle) void {
    for ([_]c.GstVideoOverlayFormatFlags{ 0, 1, 2, 3 }) |fl| {
        const all = [_]?*c.GstBuffer{
            c.gst_video_overlay_rectangle_get_pixels_raw(r, fl),
            c.gst_video_overlay_rectangle_get_pixels_argb(r, fl),
            c.gst_video_overlay_rectangle_get_pixels_ayuv(r, fl),
            c.gst_video_overlay_rectangle_get_pixels_unscaled_raw(r, fl),
            c.gst_video_overlay_rectangle_get_pixels_unscaled_argb(r, fl),
            c.gst_video_overlay_rectangle_get_pixels_unscaled_ayuv(r, fl),
        };
        for (all, 0..) |b, k| {
            if (b == null) {
                out("    px f{d} k{d} null", .{ fl, k });
                continue;
            }
            const vm = c.gst_buffer_get_video_meta(b);
            out("    px f{d} k{d} {d}x{d} fmt {d} {x}", .{ fl, k, vm[0].width, vm[0].height, vm[0].format, hash(b.?) });
        }
    }
}

fn compositions() void {
    out("composition", .{});
    for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_BGRA, c.GST_VIDEO_FORMAT_AYUV }) |f| for ([_]c.GstVideoOverlayFormatFlags{ 0, 1 }) |fl| for ([_]f32{ 1.0, 0.6 }) |ga| for ([_][2]c.guint{ .{ 10, 6 }, .{ 20, 9 }, .{ 7, 3 } }) |rs| {
        seed = f + fl * 3 + rs[0];
        const pb = pixelBuf(f, 10, 6);
        const r = c.gst_video_overlay_rectangle_new_raw(pb, 3, -1, rs[0], rs[1], fl);
        c.gst_buffer_unref(pb);
        c.gst_video_overlay_rectangle_set_global_alpha(r, ga);
        out("  fmt {d} fl {d} ga {d} rs {any}", .{ f, fl, ga, rs });
        rectInfo(r);
        pixels(r);
        const comp = c.gst_video_overlay_composition_new(r);
        const pb2 = pixelBuf(c.GST_VIDEO_FORMAT_BGRA, 4, 4);
        const r2 = c.gst_video_overlay_rectangle_new_raw(pb2, 20, 10, 8, 8, 0);
        c.gst_buffer_unref(pb2);
        c.gst_video_overlay_composition_add_rectangle(comp, r2);
        out("    n {d} seq {d}", .{ c.gst_video_overlay_composition_n_rectangles(comp), c.gst_video_overlay_composition_get_seqnum(comp) });
        for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_BGRx, c.GST_VIDEO_FORMAT_AYUV64 }) |vf| {
            var vi: c.GstVideoInfo = undefined;
            _ = c.gst_video_info_set_format(&vi, vf, 32, 18);
            const vb = c.gst_buffer_new_allocate(null, vi.size, null).?;
            fill(vb);
            var fr: c.GstVideoFrame = undefined;
            _ = c.gst_video_frame_map(&fr, &vi, vb, c.GST_MAP_READWRITE);
            const ok = c.gst_video_overlay_composition_blend(comp, &fr);
            c.gst_video_frame_unmap(&fr);
            out("    blend {d}: {d} {x}", .{ vf, ok, hash(vb) });
            const m = c.gst_buffer_add_video_overlay_composition_meta(vb, comp);
            const cp = c.gst_buffer_copy(vb);
            const cm: *c.GstVideoOverlayCompositionMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(cp, c.gst_video_overlay_composition_meta_api_get_type())));
            out("    meta copy same {d} n {d}", .{ @intFromBool(cm.overlay == m[0].overlay), c.gst_video_overlay_composition_n_rectangles(cm.overlay) });
            var oi: c.GstVideoInfo = undefined;
            _ = c.gst_video_info_set_format(&oi, vf, 64, 9);
            var t = c.GstVideoMetaTransform{ .in_info = &vi, .out_info = &oi };
            const db = c.gst_buffer_new().?;
            const info = m[0].meta.info;
            out("    scale {d}", .{info[0].transform_func.?(db, @ptrCast(m), vb, c.gst_video_meta_transform_scale_get_quark(), &t)});
            const sm: *c.GstVideoOverlayCompositionMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(db, c.gst_video_overlay_composition_meta_api_get_type())));
            for (0..c.gst_video_overlay_composition_n_rectangles(sm.overlay)) |i| rectInfo(c.gst_video_overlay_composition_get_rectangle(sm.overlay, @intCast(i)));
            var mt: c.GstVideoMetaTransformMatrix = undefined;
            const ir = c.GstVideoRectangle{ .x = 2, .y = 1, .w = 20, .h = 12 };
            const orr = c.GstVideoRectangle{ .x = 0, .y = 0, .w = 40, .h = 9 };
            c.gst_video_meta_transform_matrix_init(&mt, &vi, &ir, &oi, &orr);
            const db2 = c.gst_buffer_new().?;
            out("    matrix {d}", .{info[0].transform_func.?(db2, @ptrCast(m), vb, c.gst_video_meta_transform_matrix_get_quark(), &mt)});
            const mm: ?*c.GstVideoOverlayCompositionMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(db2, c.gst_video_overlay_composition_meta_api_get_type())));
            if (mm) |q| {
                for (0..c.gst_video_overlay_composition_n_rectangles(q.overlay)) |i| rectInfo(c.gst_video_overlay_composition_get_rectangle(q.overlay, @intCast(i)));
            }
            c.gst_buffer_unref(db2);
            c.gst_buffer_unref(db);
            c.gst_buffer_unref(cp);
            c.gst_buffer_unref(vb);
        }
        const cc = c.gst_video_overlay_composition_copy(comp);
        out("    copy n {d} seq {d}", .{ c.gst_video_overlay_composition_n_rectangles(cc), c.gst_video_overlay_composition_get_seqnum(cc) });
        rectInfo(c.gst_video_overlay_composition_get_rectangle(cc, 0));
        out("    get 5 null {d}", .{@intFromBool(c.gst_video_overlay_composition_get_rectangle(cc, 5) == null)});
        const w = c.gst_video_overlay_composition_make_writable(@ptrCast(c.gst_mini_object_ref(@ptrCast(@alignCast(cc)))));
        out("    writable same {d}", .{@intFromBool(@intFromPtr(w) == @intFromPtr(cc))});
        c.gst_mini_object_unref(@ptrCast(@alignCast(w)));
        const rc = c.gst_video_overlay_rectangle_copy(r);
        rectInfo(rc);
        c.gst_video_overlay_rectangle_set_render_rectangle(rc, 1, 2, 3, 4);
        rectInfo(rc);
        c.gst_mini_object_unref(@ptrCast(@alignCast(rc)));
        c.gst_mini_object_unref(@ptrCast(@alignCast(cc)));
        c.gst_mini_object_unref(@ptrCast(@alignCast(comp)));
        c.gst_mini_object_unref(@ptrCast(@alignCast(r)));
        c.gst_mini_object_unref(@ptrCast(@alignCast(r2)));
    };
    out("  types {s} {s}", .{ c.g_type_name(c.gst_video_overlay_composition_get_type()), c.g_type_name(c.gst_video_overlay_rectangle_get_type()) });
    const bad = pixelBuf(c.GST_VIDEO_FORMAT_I420, 4, 4);
    out("  bad fmt null {d}", .{@intFromBool(c.gst_video_overlay_rectangle_new_raw(bad, 0, 0, 4, 4, 0) == null)});
    out("  bad flags null {d}", .{@intFromBool(c.gst_video_overlay_rectangle_new_raw(bad, 0, 0, 4, 4, 8) == null)});
    c.gst_buffer_unref(bad);
    out("  n null {d}", .{c.gst_video_overlay_composition_n_rectangles(null)});
    c.gst_video_overlay_rectangle_set_global_alpha(null, 0.5);
}

pub fn main() void {
    c.gst_init(null, null);
    blends();
    scales();
    compositions();
}
