const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const format = @import("format.zig");
const meta = @import("meta.zig");
const tiled = @import("tiled.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Frame = c.GstVideoFrame;
const Info = c.GstVideoInfo;

fn isBuffer(b: [*c]const c.GstBuffer) bool {
    return b != null and b[0].mini_object.type == c.gst_buffer_get_type();
}

fn flagSet(b: [*c]c.GstBuffer, f: c.guint) bool {
    return b[0].mini_object.flags & f != 0;
}

pub export fn gst_video_frame_map_id(frame: [*c]Frame, info: [*c]const Info, buffer: [*c]c.GstBuffer, id: c.gint, flags: c.GstMapFlags) c.gboolean {
    const fname = "gst_video_frame_map_id";
    if (!check.that(frame != null, fname, "frame != NULL")) return 0;
    if (!check.that(info != null, fname, "info != NULL")) return 0;
    if (!check.that(info[0].finfo != null, fname, "info->finfo != NULL")) return 0;
    if (!check.that(isBuffer(buffer), fname, "GST_IS_BUFFER (buffer)")) return 0;
    const m = if (id == -1) meta.gst_buffer_get_video_meta(buffer) else meta.gst_buffer_get_video_meta_id(buffer, id);
    const f = &frame[0];
    f.info = info[0];
    if (m != null) {
        if (!check.that(info[0].finfo[0].format == m[0].format, fname, "info->finfo->format == meta->format")) return 0;
        if (!check.that(@as(c.guint, @bitCast(info[0].width)) <= m[0].width, fname, "info->width <= meta->width")) return 0;
        if (!check.that(@as(c.guint, @bitCast(info[0].height)) <= m[0].height, fname, "info->height <= meta->height")) return 0;
        if (!check.that(info[0].finfo[0].n_planes == m[0].n_planes, fname, "info->finfo->n_planes == meta->n_planes")) return 0;
        f.info.finfo = format.get(m[0].format);
        f.info.width = @bitCast(m[0].width);
        f.info.height = @bitCast(m[0].height);
        f.id = m[0].id;
        f.flags = m[0].flags;
        var i: usize = 0;
        while (i < m[0].n_planes) : (i += 1) {
            f.info.offset[i] = m[0].offset[i];
            if (meta.gst_video_meta_map(m, @intCast(i), &f.map[i], &f.data[i], &f.info.stride[i], flags) == 0) {
                while (i > 0) {
                    i -= 1;
                    _ = meta.gst_video_meta_unmap(m, @intCast(i), &f.map[i]);
                }
                f.* = std.mem.zeroes(Frame);
                return 0;
            }
        }
    } else {
        if (id != -1) {
            f.* = std.mem.zeroes(Frame);
            return 0;
        }
        f.id = id;
        f.flags = 0;
        if (c.gst_buffer_map(buffer, &f.map[0], flags) == 0) return 0;
        if (f.map[0].size < info[0].size) {
            c.gst_buffer_unmap(buffer, &f.map[0]);
            f.* = std.mem.zeroes(Frame);
            return 0;
        }
        for (0..info[0].finfo[0].n_planes) |i| f.data[i] = @ptrCast(f.map[0].data + info[0].offset[i]);
    }
    f.buffer = buffer;
    if (flags & c.GST_VIDEO_FRAME_MAP_FLAG_NO_REF == 0) _ = c.gst_buffer_ref(f.buffer);
    f.meta = m;
    if (info[0].interlace_mode != c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE) {
        if (info[0].interlace_mode == c.GST_VIDEO_INTERLACE_MODE_MIXED) {
            if (flagSet(buffer, c.GST_VIDEO_BUFFER_FLAG_INTERLACED)) f.flags |= c.GST_VIDEO_FRAME_FLAG_INTERLACED;
        } else f.flags |= c.GST_VIDEO_FRAME_FLAG_INTERLACED;
        if (info[0].ABI.abi.field_order == c.GST_VIDEO_FIELD_ORDER_TOP_FIELD_FIRST) {
            f.flags |= c.GST_VIDEO_FRAME_FLAG_TFF;
        } else {
            if (flagSet(buffer, c.GST_VIDEO_BUFFER_FLAG_TFF)) f.flags |= c.GST_VIDEO_FRAME_FLAG_TFF;
            if (flagSet(buffer, c.GST_VIDEO_BUFFER_FLAG_RFF)) f.flags |= c.GST_VIDEO_FRAME_FLAG_RFF;
            if (flagSet(buffer, c.GST_VIDEO_BUFFER_FLAG_ONEFIELD)) f.flags |= c.GST_VIDEO_FRAME_FLAG_ONEFIELD;
        }
    }
    return 1;
}

pub export fn gst_video_frame_map(frame: [*c]Frame, info: [*c]const Info, buffer: [*c]c.GstBuffer, flags: c.GstMapFlags) c.gboolean {
    return gst_video_frame_map_id(frame, info, buffer, -1, flags);
}

pub export fn gst_video_frame_unmap(frame: [*c]Frame) void {
    if (!check.that(frame != null, "gst_video_frame_unmap", "frame != NULL")) return;
    const f = &frame[0];
    const buffer = f.buffer;
    const m: [*c]c.GstVideoMeta = @ptrCast(@alignCast(f.meta));
    const flags = f.map[0].flags;
    if (buffer == null) return;
    if (m != null) {
        for (0..f.info.finfo[0].n_planes) |i| _ = meta.gst_video_meta_unmap(m, @intCast(i), &f.map[i]);
    } else c.gst_buffer_unmap(buffer, &f.map[0]);
    if (flags & c.GST_VIDEO_FRAME_MAP_FLAG_NO_REF == 0) c.gst_buffer_unref(f.buffer);
    f.buffer = null;
    f.data = .{ null, null, null, null };
}

fn compWidth(i: *allowzero const Info, k: usize) c.gint {
    const sh: u5 = @intCast(i.finfo[0].w_sub[k]);
    return -((-i.width) >> sh);
}

fn compHeight(i: *allowzero const Info, k: usize) c.gint {
    const h = if (i.interlace_mode == c.GST_VIDEO_INTERLACE_MODE_ALTERNATE) @divTrunc((i.height + 1) & ~@as(c.gint, 1), 2) else i.height;
    const sh: u5 = @intCast(i.finfo[0].h_sub[k]);
    return -((-h) >> sh);
}

pub export fn gst_video_frame_copy_plane(dest: [*c]Frame, src: [*c]const Frame, plane: c.guint) c.gboolean {
    const fname = "gst_video_frame_copy_plane";
    if (!check.that(dest != null, fname, "dest != NULL")) return 0;
    if (!check.that(src != null, fname, "src != NULL")) return 0;
    const si = &src[0].info;
    const di = &dest[0].info;
    if (!check.that(di.finfo[0].format == si.finfo[0].format, fname, "dinfo->finfo->format == sinfo->finfo->format")) return 0;
    const fi = di.finfo;
    if (!check.that(di.width <= si.width and di.height <= si.height, fname, "dinfo->width <= sinfo->width && dinfo->height <= sinfo->height")) return 0;
    if (!check.that(fi[0].n_planes > plane, fname, "finfo->n_planes > plane")) return 0;
    const sp: [*]u8 = @ptrCast(src[0].data[plane]);
    var dp: [*]u8 = @ptrCast(dest[0].data[plane]);
    if (fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_PALETTE != 0 and plane == 1) {
        @memcpy(dp[0 .. 256 * 4], sp[0 .. 256 * 4]);
        return 1;
    }
    var comp: [4]c.gint = undefined;
    format.gst_video_format_info_component(fi, plane, &comp);
    const k: usize = @intCast(comp[0]);
    var w: c.guint = @bitCast(compWidth(di, k) *% fi[0].pixel_stride[k]);
    if (w == 0) w = @bitCast(@min(di.stride[plane], si.stride[plane]));
    var h: c.guint = @bitCast(compHeight(di, k));
    const ss = si.stride[plane];
    const ds = di.stride[plane];
    if (fi[0].flags & c.GST_VIDEO_FORMAT_FLAG_TILED != 0) {
        const tile: usize = fi[0].tile_info[plane].size;
        const mode = fi[0].tile_mode;
        const sx = ss & 0xffff;
        const sy = ss >> 16;
        const dx = ds & 0xffff;
        const dy = ds >> 16;
        w = @bitCast(@min(sx, dx));
        h = @bitCast(@min(sy, dy));
        var j: c.guint = 0;
        while (j < h) : (j += 1) {
            var i: c.guint = 0;
            while (i < w) : (i += 1) {
                const s_i: usize = tiled.tileIndex(mode, @bitCast(i), @bitCast(j), sx, sy);
                const d_i: usize = tiled.tileIndex(mode, @bitCast(i), @bitCast(j), dx, dy);
                @memcpy(dp[d_i * tile ..][0..tile], sp[s_i * tile ..][0..tile]);
            }
        }
        return 1;
    }
    if (ds == ss) {
        const n = @as(usize, @intCast(ds)) * h;
        @memcpy(dp[0..n], sp[0..n]);
    } else {
        var s2 = sp;
        var j: c.guint = 0;
        while (j < h) : (j += 1) {
            @memcpy(dp[0..w], s2[0..w]);
            dp = @ptrFromInt(@intFromPtr(dp) +% @as(usize, @bitCast(@as(isize, ds))));
            s2 = @ptrFromInt(@intFromPtr(s2) +% @as(usize, @bitCast(@as(isize, ss))));
        }
    }
    return 1;
}

pub export fn gst_video_frame_copy(dest: [*c]Frame, src: [*c]const Frame) c.gboolean {
    const fname = "gst_video_frame_copy";
    if (!check.that(dest != null, fname, "dest != NULL")) return 0;
    if (!check.that(src != null, fname, "src != NULL")) return 0;
    const si = &src[0].info;
    const di = &dest[0].info;
    if (!check.that(di.finfo[0].format == si.finfo[0].format, fname, "dinfo->finfo->format == sinfo->finfo->format")) return 0;
    if (!check.that(di.width <= si.width and di.height <= si.height, fname, "dinfo->width <= sinfo->width && dinfo->height <= sinfo->height")) return 0;
    for (0..di.finfo[0].n_planes) |i| _ = gst_video_frame_copy_plane(dest, src, @intCast(i));
    return 1;
}
