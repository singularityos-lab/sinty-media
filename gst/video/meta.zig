const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const info = @import("info.zig");
const misc = @import("misc.zig");
const timecode = @import("timecode.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Meta = c.GstMeta;
const Buffer = c.GstBuffer;
const VMeta = c.GstVideoMeta;
const Align = c.GstVideoAlignment;
const NONE = @as(?*anyopaque, null);

fn isCopy(t: c.GQuark) bool {
    return t == c._gst_meta_transform_copy;
}

fn isBuffer(b: [*c]const Buffer) bool {
    return b != null and b[0].mini_object.type == c.gst_buffer_get_type();
}

fn apiType(store: *usize, comptime name: [*:0]const u8, tags: [*c][*c]const u8) c.GType {
    if (c.g_once_init_enter(store) != 0) c.g_once_init_leave(store, c.gst_meta_api_type_register(name, tags));
    return store.*;
}

fn infoOnce(store: *usize, make: *const fn () [*c]const c.GstMetaInfo) [*c]const c.GstMetaInfo {
    if (c.g_once_init_enter(store) != 0) c.g_once_init_leave(store, @intFromPtr(make()));
    return @ptrFromInt(store.*);
}

fn cast(comptime T: type, p: anytype) [*c]T {
    return @ptrCast(@alignCast(p));
}

pub export fn gst_buffer_pool_config_set_video_alignment(config: ?*c.GstStructure, al: [*c]const Align) void {
    const fname = "gst_buffer_pool_config_set_video_alignment";
    if (!check.that(config != null, fname, "config != NULL")) return;
    if (!check.that(al != null, fname, "align != NULL")) return;
    const a = &al[0];
    const U = c.G_TYPE_UINT;
    c.gst_structure_set(config, "padding-top", U, a.padding_top, "padding-bottom", U, a.padding_bottom, "padding-left", U, a.padding_left, "padding-right", U, a.padding_right, "stride-align0", U, a.stride_align[0], "stride-align1", U, a.stride_align[1], "stride-align2", U, a.stride_align[2], "stride-align3", U, a.stride_align[3], NONE);
}

pub export fn gst_buffer_pool_config_get_video_alignment(config: ?*const c.GstStructure, al: [*c]Align) c.gboolean {
    const fname = "gst_buffer_pool_config_get_video_alignment";
    if (!check.that(config != null, fname, "config != NULL")) return 0;
    if (!check.that(al != null, fname, "align != NULL")) return 0;
    const a = &al[0];
    const U = c.G_TYPE_UINT;
    return c.gst_structure_get(config, "padding-top", U, &a.padding_top, "padding-bottom", U, &a.padding_bottom, "padding-left", U, &a.padding_left, "padding-right", U, &a.padding_right, "stride-align0", U, &a.stride_align[0], "stride-align1", U, &a.stride_align[1], "stride-align2", U, &a.stride_align[2], "stride-align3", U, &a.stride_align[3], NONE);
}

fn videoInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const v = cast(VMeta, m);
    v[0].buffer = null;
    v[0].flags = c.GST_VIDEO_FRAME_FLAG_NONE;
    v[0].format = c.GST_VIDEO_FORMAT_UNKNOWN;
    v[0].id = 0;
    v[0].width = 0;
    v[0].height = 0;
    v[0].n_planes = 0;
    v[0].offset = .{ 0, 0, 0, 0 };
    v[0].stride = .{ 0, 0, 0, 0 };
    misc.gst_video_alignment_reset(&v[0].alignment);
    v[0].map = null;
    v[0].unmap = null;
    return 1;
}

fn videoTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const s = cast(VMeta, m);
    if (!isCopy(t)) return 0;
    const copy: *c.GstMetaTransformCopy = @ptrCast(@alignCast(data));
    if (copy.region != 0) return 1;
    const d = cast(VMeta, c.gst_buffer_add_meta(dest, gst_video_meta_get_info(), null));
    if (d == null) return 0;
    d[0].buffer = dest;
    d[0].flags = s[0].flags;
    d[0].format = s[0].format;
    d[0].id = s[0].id;
    d[0].width = s[0].width;
    d[0].height = s[0].height;
    d[0].n_planes = s[0].n_planes;
    for (0..d[0].n_planes) |i| {
        d[0].offset[i] = s[0].offset[i];
        d[0].stride[i] = s[0].stride[i];
        d[0].alignment = s[0].alignment;
    }
    d[0].map = s[0].map;
    d[0].unmap = s[0].unmap;
    return 1;
}

fn aggregate(out: [*c]?*c.GstStructure, p0_in: ?*const c.GstStructure, p1_in: ?*const c.GstStructure) callconv(.c) c.gboolean {
    var a0: Align = undefined;
    var a1: Align = undefined;
    var ag: Align = undefined;
    misc.gst_video_alignment_reset(&a0);
    misc.gst_video_alignment_reset(&a1);
    misc.gst_video_alignment_reset(&ag);
    var p0 = p0_in;
    var p1 = p1_in;
    if (p0 != null and (c.gst_structure_has_name(p0, "video-meta") == 0 or gst_buffer_pool_config_get_video_alignment(p0, &a0) == 0)) p0 = null;
    if (p1 != null and (c.gst_structure_has_name(p1, "video-meta") == 0 or gst_buffer_pool_config_get_video_alignment(p1, &a1) == 0)) p1 = null;
    if (p0 == null and p1 == null) {
        out.* = null;
        return 1;
    }
    if (p1 == null) {
        out.* = c.gst_structure_copy(p0);
        return 1;
    }
    if (p0 == null) {
        out.* = c.gst_structure_copy(p1);
        return 1;
    }
    ag.padding_top = @max(a0.padding_top, a1.padding_top);
    ag.padding_bottom = @max(a0.padding_bottom, a1.padding_bottom);
    ag.padding_left = @max(a0.padding_left, a1.padding_left);
    ag.padding_right = @max(a0.padding_right, a1.padding_right);
    for (0..4) |n| ag.stride_align[n] = a0.stride_align[n] | a1.stride_align[n];
    out.* = c.gst_structure_new_empty("video-meta");
    gst_buffer_pool_config_set_video_alignment(out.*, &ag);
    return 1;
}

var video_api: usize = 0;
var video_tags = [_][*c]const u8{ "video", "memory", "colorspace", "size", null };

pub export fn gst_video_meta_api_get_type() c.GType {
    if (c.g_once_init_enter(&video_api) != 0) {
        const t = c.gst_meta_api_type_register("GstVideoMetaAPI", &video_tags);
        c.gst_meta_api_type_set_params_aggregator(t, @ptrCast(&aggregate));
        c.g_once_init_leave(&video_api, t);
    }
    return video_api;
}

fn put32(p: [*]u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .little);
}

fn serialize(m: [*c]const Meta, data: [*c]c.GstByteArrayInterface, _: [*c]u8) callconv(.c) c.gboolean {
    const v = cast(VMeta, @constCast(m));
    if (v[0].map != defaultMap or v[0].unmap != defaultUnmap) return 0;
    const n: usize = v[0].n_planes;
    const size = 36 + n * 16;
    const ptr = c.gst_byte_array_interface_append(data, size);
    if (ptr == null) return 0;
    var p: [*]u8 = @ptrCast(ptr);
    put32(p, @bitCast(@as(i32, @bitCast(v[0].flags))));
    put32(p + 4, @bitCast(@as(i32, @bitCast(v[0].format))));
    put32(p + 8, v[0].width);
    put32(p + 12, v[0].height);
    put32(p + 16, v[0].n_planes);
    p += 20;
    for (0..n) |i| {
        std.mem.writeInt(u64, p[0..8], v[0].offset[i], .little);
        p += 8;
    }
    for (0..n) |i| {
        put32(p, @bitCast(v[0].stride[i]));
        p += 4;
    }
    put32(p, v[0].alignment.padding_top);
    put32(p + 4, v[0].alignment.padding_bottom);
    put32(p + 8, v[0].alignment.padding_left);
    put32(p + 12, v[0].alignment.padding_right);
    p += 16;
    for (0..n) |i| {
        put32(p, v[0].alignment.stride_align[i]);
        p += 4;
    }
    return 1;
}

const Reader = struct {
    p: [*]const u8,
    left: usize,
    ok: bool = true,

    fn u32le(r: *Reader) u32 {
        if (r.left < 4) {
            r.ok = false;
            return 0;
        }
        const v = std.mem.readInt(u32, r.p[0..4], .little);
        r.p += 4;
        r.left -= 4;
        return v;
    }

    fn u64le(r: *Reader) u64 {
        if (r.left < 8) {
            r.ok = false;
            return 0;
        }
        const v = std.mem.readInt(u64, r.p[0..8], .little);
        r.p += 8;
        r.left -= 8;
        return v;
    }
};

fn deserialize(_: [*c]const c.GstMetaInfo, buffer: [*c]Buffer, data: [*c]const u8, size: c.gsize, version: u8) callconv(.c) [*c]Meta {
    if (version != 0) return null;
    var al: Align = undefined;
    misc.gst_video_alignment_reset(&al);
    var r = Reader{ .p = @ptrCast(data), .left = size };
    const flags = r.u32le();
    const fmt = r.u32le();
    const width = r.u32le();
    const height = r.u32le();
    const n_planes = r.u32le();
    if (!r.ok or n_planes > 4) return null;
    var offset: [4]c.gsize = undefined;
    var stride: [4]c.gint = undefined;
    for (0..n_planes) |i| offset[i] = r.u64le();
    for (0..n_planes) |i| stride[i] = @bitCast(r.u32le());
    al.padding_top = r.u32le();
    al.padding_bottom = r.u32le();
    al.padding_left = r.u32le();
    al.padding_right = r.u32le();
    for (0..n_planes) |i| al.stride_align[i] = r.u32le();
    if (!r.ok) return null;
    const v = gst_buffer_add_video_meta_full(buffer, flags, fmt, width, height, n_planes, &offset, &stride);
    _ = gst_video_meta_set_alignment(v, al);
    return @ptrCast(v);
}

var video_info: usize = 0;

fn makeVideo() [*c]const c.GstMetaInfo {
    const i = c.gst_meta_info_new(gst_video_meta_api_get_type(), "GstVideoMeta", @sizeOf(VMeta));
    i[0].init_func = videoInit;
    i[0].transform_func = videoTransform;
    i[0].serialize_func = serialize;
    i[0].deserialize_func = deserialize;
    return c.gst_meta_info_register(i);
}

pub export fn gst_video_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&video_info, makeVideo);
}

pub export fn gst_buffer_get_video_meta(buffer: [*c]Buffer) [*c]VMeta {
    var state: c.gpointer = null;
    var out: [*c]VMeta = null;
    const api = gst_video_meta_get_info()[0].api;
    while (true) {
        const m = c.gst_buffer_iterate_meta(buffer, &state);
        if (m == null) return out;
        if (m[0].info[0].api != api) continue;
        const v = cast(VMeta, m);
        if (v[0].id == 0) return v;
        if (out == null or v[0].id < out[0].id) out = v;
    }
}

pub export fn gst_buffer_get_video_meta_id(buffer: [*c]Buffer, id: c.gint) [*c]VMeta {
    var state: c.gpointer = null;
    const api = gst_video_meta_get_info()[0].api;
    while (true) {
        const m = c.gst_buffer_iterate_meta(buffer, &state);
        if (m == null) return null;
        if (m[0].info[0].api == api and cast(VMeta, m)[0].id == id) return cast(VMeta, m);
    }
}

fn defaultMap(meta: [*c]VMeta, plane: c.guint, mi: [*c]c.GstMapInfo, data: [*c]c.gpointer, stride: [*c]c.gint, flags: c.GstMapFlags) callconv(.c) c.gboolean {
    const buffer = meta[0].buffer;
    const offset = meta[0].offset[plane];
    var idx: c.guint = 0;
    var length: c.guint = 0;
    var skip: c.gsize = 0;
    if (c.gst_buffer_find_memory(buffer, offset, 1, &idx, &length, &skip) == 0) return 0;
    if (c.gst_buffer_map_range(buffer, idx, @bitCast(length), mi, flags) == 0) return 0;
    stride.* = meta[0].stride[plane];
    data.* = @ptrCast(@as([*]u8, @ptrCast(mi[0].data)) + skip);
    return 1;
}

fn defaultUnmap(meta: [*c]VMeta, _: c.guint, mi: [*c]c.GstMapInfo) callconv(.c) c.gboolean {
    c.gst_buffer_unmap(meta[0].buffer, mi);
    return 1;
}

pub export fn gst_buffer_add_video_meta(buffer: [*c]Buffer, flags: c.GstVideoFrameFlags, fmt: c.GstVideoFormat, width: c.guint, height: c.guint) [*c]VMeta {
    var vi: c.GstVideoInfo = undefined;
    if (info.gst_video_info_set_format(&vi, fmt, width, height) == 0) return null;
    return gst_buffer_add_video_meta_full(buffer, flags, fmt, width, height, vi.finfo[0].n_planes, &vi.offset, &vi.stride);
}

pub export fn gst_buffer_add_video_meta_full(buffer: [*c]Buffer, flags: c.GstVideoFrameFlags, fmt: c.GstVideoFormat, width: c.guint, height: c.guint, n_planes: c.guint, offset: [*c]const c.gsize, stride: [*c]const c.gint) [*c]VMeta {
    const m = cast(VMeta, c.gst_buffer_add_meta(buffer, gst_video_meta_get_info(), null));
    if (m == null) return null;
    m[0].flags = flags;
    m[0].format = fmt;
    m[0].id = 0;
    m[0].width = width;
    m[0].height = height;
    m[0].buffer = buffer;
    m[0].n_planes = n_planes;
    for (0..n_planes) |i| {
        m[0].offset[i] = offset[i];
        m[0].stride[i] = stride[i];
    }
    m[0].map = defaultMap;
    m[0].unmap = defaultUnmap;
    return m;
}

pub export fn gst_video_meta_map(meta: [*c]VMeta, plane: c.guint, mi: [*c]c.GstMapInfo, data: [*c]c.gpointer, stride: [*c]c.gint, flags: c.GstMapFlags) c.gboolean {
    const fname = "gst_video_meta_map";
    if (!check.that(meta != null, fname, "meta != NULL")) return 0;
    if (!check.that(meta[0].map != null, fname, "meta->map != NULL")) return 0;
    if (!check.that(plane < meta[0].n_planes, fname, "plane < meta->n_planes")) return 0;
    if (!check.that(mi != null, fname, "info != NULL")) return 0;
    if (!check.that(data != null, fname, "data != NULL")) return 0;
    if (!check.that(stride != null, fname, "stride != NULL")) return 0;
    if (!check.that(meta[0].buffer != null, fname, "meta->buffer != NULL")) return 0;
    if (!check.that(flags & c.GST_MAP_WRITE == 0 or c.gst_mini_object_is_writable(@ptrCast(meta[0].buffer)) != 0, fname, "!(flags & GST_MAP_WRITE) || gst_buffer_is_writable (meta->buffer)")) return 0;
    return meta[0].map.?(meta, plane, mi, data, stride, flags);
}

pub export fn gst_video_meta_unmap(meta: [*c]VMeta, plane: c.guint, mi: [*c]c.GstMapInfo) c.gboolean {
    const fname = "gst_video_meta_unmap";
    if (!check.that(meta != null, fname, "meta != NULL")) return 0;
    if (!check.that(meta[0].unmap != null, fname, "meta->unmap != NULL")) return 0;
    if (!check.that(plane < meta[0].n_planes, fname, "plane < meta->n_planes")) return 0;
    if (!check.that(mi != null, fname, "info != NULL")) return 0;
    return meta[0].unmap.?(meta, plane, mi);
}

fn alignmentSet(a: *allowzero const Align) bool {
    if (a.padding_top != 0 or a.padding_bottom != 0 or a.padding_left != 0 or a.padding_right != 0) return true;
    for (a.stride_align) |s| if (s != 0) return true;
    return false;
}

fn validate(meta: [*c]VMeta, plane_size: [*c]c.gsize) bool {
    if (!alignmentSet(&meta[0].alignment) and plane_size == null) return true;
    var vi: c.GstVideoInfo = undefined;
    info.gst_video_info_init(&vi);
    _ = info.gst_video_info_set_format(&vi, meta[0].format, meta[0].width, meta[0].height);
    if (info.gst_video_info_align_full(&vi, &meta[0].alignment, plane_size) == 0) return false;
    for (0..vi.finfo[0].n_planes) |i| {
        if (vi.stride[i] != meta[0].stride[i]) return false;
    }
    return true;
}

pub export fn gst_video_meta_set_alignment(meta: [*c]VMeta, al: Align) c.gboolean {
    return gst_video_meta_set_alignment_full(meta, &al);
}

pub export fn gst_video_meta_set_alignment_full(meta: [*c]VMeta, al: [*c]const Align) c.gboolean {
    if (!check.that(meta != null, "gst_video_meta_set_alignment_full", "meta")) return 0;
    const old = meta[0].alignment;
    meta[0].alignment = al[0];
    if (!validate(meta, null)) {
        meta[0].alignment = old;
        return 0;
    }
    return 1;
}

pub export fn gst_video_meta_get_plane_size(meta: [*c]VMeta, plane_size: [*c]c.gsize) c.gboolean {
    const fname = "gst_video_meta_get_plane_size";
    if (!check.that(meta != null, fname, "meta")) return 0;
    if (!check.that(plane_size != null, fname, "plane_size")) return 0;
    return @intFromBool(validate(meta, plane_size));
}

pub export fn gst_video_meta_get_plane_height(meta: [*c]VMeta, plane_height: [*c]c.guint) c.gboolean {
    const fname = "gst_video_meta_get_plane_height";
    if (!check.that(meta != null, fname, "meta")) return 0;
    if (!check.that(plane_height != null, fname, "plane_height")) return 0;
    var vi: c.GstVideoInfo = undefined;
    info.gst_video_info_init(&vi);
    _ = info.gst_video_info_set_format(&vi, meta[0].format, meta[0].width, meta[0].height);
    const vi_as_format: *const c.GstVideoFormatInfo = @ptrCast(&vi);
    if (!check.that(vi_as_format.flags & c.GST_VIDEO_FORMAT_FLAG_TILED == 0, fname, "!GST_VIDEO_FORMAT_INFO_IS_TILED (&info)")) return 0;
    var ps: [4]c.gsize = undefined;
    if (gst_video_meta_get_plane_size(meta, &ps) == 0) return 0;
    var i: usize = 0;
    while (i < meta[0].n_planes) : (i += 1) {
        plane_height[i] = if (meta[0].stride[i] == 0) 0 else @truncate(ps[i] / @as(u64, @bitCast(@as(i64, meta[0].stride[i]))));
    }
    while (i < 4) : (i += 1) plane_height[i] = 0;
    return 1;
}

const Crop = c.GstVideoCropMeta;

fn scaleInfo(data: c.gpointer) [4]c.gint {
    const trans: *c.GstVideoMetaTransform = @ptrCast(@alignCast(data));
    return .{ trans.in_info[0].width, trans.out_info[0].width, trans.in_info[0].height, trans.out_info[0].height };
}

fn cropTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const s = cast(Crop, m);
    if (isCopy(t)) {
        const d = gst_buffer_add_video_crop_meta(dest);
        if (d == null) return 0;
        d[0].x = s[0].x;
        d[0].y = s[0].y;
        d[0].width = s[0].width;
        d[0].height = s[0].height;
        return 1;
    }
    if (t != gst_video_meta_transform_scale_get_quark()) return 0;
    const d = gst_buffer_add_video_crop_meta(dest);
    if (d == null) return 0;
    const sc = scaleInfo(data);
    const ow: c.guint = @bitCast(sc[0]);
    const nw: c.guint = @bitCast(sc[1]);
    const oh: c.guint = @bitCast(sc[2]);
    const nh: c.guint = @bitCast(sc[3]);
    d[0].x = (s[0].x *% nw) / ow;
    d[0].y = (s[0].y *% nh) / oh;
    d[0].width = (s[0].width *% nw) / ow;
    d[0].height = (s[0].height *% nh) / oh;
    return 1;
}

fn gst_buffer_add_video_crop_meta(b: [*c]Buffer) [*c]Crop {
    return cast(Crop, c.gst_buffer_add_meta(b, gst_video_crop_meta_get_info(), null));
}

var crop_api: usize = 0;
var crop_tags = [_][*c]const u8{ "video", "size", "orientation", null };

pub export fn gst_video_crop_meta_api_get_type() c.GType {
    return apiType(&crop_api, "GstVideoCropMetaAPI", &crop_tags);
}

fn cropInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const v = cast(Crop, m);
    v[0].x = 0;
    v[0].y = 0;
    v[0].width = 0;
    v[0].height = 0;
    return 1;
}

var crop_info: usize = 0;

fn makeCrop() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_crop_meta_api_get_type(), "GstVideoCropMeta", @sizeOf(Crop), cropInit, null, cropTransform);
}

pub export fn gst_video_crop_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&crop_info, makeCrop);
}

var scale_quark: c.GQuark = 0;
var matrix_quark: c.GQuark = 0;

pub export fn gst_video_meta_transform_scale_get_quark() c.GQuark {
    if (scale_quark == 0) scale_quark = c.g_quark_from_static_string("gst-video-scale");
    return scale_quark;
}

pub export fn gst_video_meta_transform_matrix_get_quark() c.GQuark {
    if (matrix_quark == 0) matrix_quark = c.g_quark_from_static_string("gst-video-matrix");
    return matrix_quark;
}

const Matrix = c.GstVideoMetaTransformMatrix;
const Rect = c.GstVideoRectangle;

pub export fn gst_video_meta_transform_matrix_init(trans: [*c]Matrix, in_info: [*c]const c.GstVideoInfo, in_rect: [*c]const Rect, out_info: [*c]const c.GstVideoInfo, out_rect: [*c]const Rect) void {
    const fname = "gst_video_meta_transform_matrix_init";
    if (!check.that(in_info != null, fname, "in_info != NULL")) return;
    if (!check.that(out_info != null, fname, "out_info != NULL")) return;
    if (!check.that(in_rect[0].w > 0, fname, "in_rectangle->w > 0")) return;
    if (!check.that(in_rect[0].h > 0, fname, "in_rectangle->h > 0")) return;
    if (!check.that(out_rect[0].w > 0, fname, "out_rectangle->w > 0")) return;
    if (!check.that(out_rect[0].h > 0, fname, "out_rectangle->h > 0")) return;
    const t = &trans[0];
    t.in_info = in_info;
    t.out_info = out_info;
    t.in_rectangle = in_rect[0];
    t.out_rectangle = out_rect[0];
    t.matrix = std.mem.zeroes(@TypeOf(t.matrix));
    t.matrix[0][0] = @as(f32, @floatFromInt(t.out_rectangle.w)) / @as(f32, @floatFromInt(t.in_rectangle.w));
    t.matrix[1][1] = @as(f32, @floatFromInt(t.out_rectangle.h)) / @as(f32, @floatFromInt(t.in_rectangle.h));
    t.matrix[2][2] = 1;
}

fn f(v: f32) f64 {
    return v;
}

fn toInt(v: f64) c.gint {
    return @intFromFloat(v);
}

fn point(t: *allowzero const Matrix, x: *allowzero c.gint, y: *allowzero c.gint, clip: bool) bool {
    var ret = true;
    const xi: f64 = @floatFromInt(x.* - t.in_rectangle.x);
    const yi: f64 = @floatFromInt(y.* - t.in_rectangle.y);
    const m = t.matrix;
    const w = f(m[2][0]) * xi + f(m[2][1]) * yi + f(m[2][2]);
    if (w == 0.0) {
        x.* = t.out_rectangle.x;
        y.* = t.out_rectangle.y;
        if (!check.that(w != 0.0, "_gst_video_meta_transform_matrix_point", "w_prime != 0.0")) return false;
    }
    var xt: f64 = undefined;
    var yt: f64 = undefined;
    if (w == 1.0) {
        xt = f(m[0][0]) * xi + f(m[0][1]) * yi + f(m[0][2]);
        yt = f(m[1][0]) * xi + f(m[1][1]) * yi + f(m[1][2]);
    } else {
        xt = (f(m[0][0]) * xi + f(m[0][1]) * yi + f(m[0][2])) / w;
        yt = (f(m[1][0]) * xi + f(m[1][1]) * yi + f(m[1][2])) / w;
    }
    x.* = toInt(xt + 0.5 + @as(f64, @floatFromInt(t.out_rectangle.x)));
    y.* = toInt(yt + 0.5 + @as(f64, @floatFromInt(t.out_rectangle.y)));
    if (clip) {
        const o = t.out_rectangle;
        if (x.* < o.x) {
            x.* = o.x;
            ret = false;
        }
        if (x.* >= o.x + o.w) {
            x.* = o.x + o.w - 1;
            ret = false;
        }
        if (y.* < o.y) {
            y.* = o.y;
            ret = false;
        }
        if (y.* >= o.y + o.h) {
            y.* = o.y + o.h - 1;
            ret = false;
        }
    }
    return ret;
}

pub export fn gst_video_meta_transform_matrix_point(t: [*c]const Matrix, x: [*c]c.gint, y: [*c]c.gint) c.gboolean {
    return @intFromBool(point(&t[0], &x[0], &y[0], false));
}

pub export fn gst_video_meta_transform_matrix_point_clipped(t: [*c]const Matrix, x: [*c]c.gint, y: [*c]c.gint) c.gboolean {
    return @intFromBool(point(&t[0], &x[0], &y[0], true));
}

fn rectangle(t: *allowzero const Matrix, r: *allowzero Rect, clip: bool) bool {
    const m = t.matrix;
    if (m[2][0] != 0 or m[2][1] != 0 or m[2][2] != 1) return false;
    if ((m[0][0] != 0 or m[1][1] != 0) and (m[0][1] != 0 or m[1][0] != 0)) return false;
    var x1 = r.x;
    var y1 = r.y;
    var x2 = r.x + r.w;
    var y2 = r.y + r.h;
    const ret = point(t, &x1, &y1, clip) and point(t, &x2, &y2, clip);
    r.x = @min(x1, x2);
    r.y = @min(y1, y2);
    r.w = @max(x1, x2) - r.x;
    r.h = @max(y1, y2) - r.y;
    return ret;
}

pub export fn gst_video_meta_transform_matrix_rectangle(t: [*c]const Matrix, r: [*c]Rect) c.gboolean {
    return @intFromBool(rectangle(&t[0], &r[0], false));
}

pub export fn gst_video_meta_transform_matrix_rectangle_clipped(t: [*c]const Matrix, r: [*c]Rect) c.gboolean {
    return @intFromBool(rectangle(&t[0], &r[0], true));
}

const Upload = c.GstVideoGLTextureUploadMeta;
var upload_api: usize = 0;
var upload_tags = [_][*c]const u8{ "video", "memory", null };

pub export fn gst_video_gl_texture_upload_meta_api_get_type() c.GType {
    return apiType(&upload_api, "GstVideoGLTextureUploadMetaAPI", &upload_tags);
}

fn uploadInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const v = cast(Upload, m);
    v[0].texture_orientation = c.GST_VIDEO_GL_TEXTURE_ORIENTATION_X_NORMAL_Y_NORMAL;
    v[0].n_textures = 0;
    v[0].texture_type = .{ 0, 0, 0, 0 };
    v[0].buffer = null;
    v[0].upload = null;
    v[0].user_data = null;
    v[0].user_data_copy = null;
    v[0].user_data_free = null;
    return 1;
}

fn uploadFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    const v = cast(Upload, m);
    if (v[0].user_data_free) |fr| fr(v[0].user_data);
}

fn uploadTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const s = cast(Upload, m);
    if (!isCopy(t)) return 0;
    const copy: *c.GstMetaTransformCopy = @ptrCast(@alignCast(data));
    if (copy.region != 0) return 1;
    const d = cast(Upload, c.gst_buffer_add_meta(dest, gst_video_gl_texture_upload_meta_get_info(), null));
    if (d == null) return 0;
    d[0].texture_orientation = s[0].texture_orientation;
    d[0].n_textures = s[0].n_textures;
    d[0].texture_type = s[0].texture_type;
    d[0].buffer = dest;
    d[0].upload = s[0].upload;
    d[0].user_data = s[0].user_data;
    d[0].user_data_copy = s[0].user_data_copy;
    d[0].user_data_free = s[0].user_data_free;
    if (d[0].user_data_copy) |cp| d[0].user_data = cp(d[0].user_data);
    return 1;
}

var upload_info: usize = 0;

fn makeUpload() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_gl_texture_upload_meta_api_get_type(), "GstVideoGLTextureUploadMeta", @sizeOf(Upload), uploadInit, uploadFree, uploadTransform);
}

pub export fn gst_video_gl_texture_upload_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&upload_info, makeUpload);
}

pub export fn gst_buffer_add_video_gl_texture_upload_meta(buffer: [*c]Buffer, orientation: c.GstVideoGLTextureOrientation, n_textures: c.guint, texture_type: [*c]c.GstVideoGLTextureType, upload: c.GstVideoGLTextureUpload, user_data: c.gpointer, user_data_copy: c.GBoxedCopyFunc, user_data_free: c.GBoxedFreeFunc) [*c]Upload {
    const fname = "gst_buffer_add_video_gl_texture_upload_meta";
    if (!check.that(buffer != null, fname, "buffer != NULL")) return null;
    if (!check.that(upload != null, fname, "upload != NULL")) return null;
    if (!check.that(n_textures > 0 and n_textures < 5, fname, "n_textures > 0 && n_textures < 5")) return null;
    const m = cast(Upload, c.gst_buffer_add_meta(buffer, gst_video_gl_texture_upload_meta_get_info(), null));
    if (m == null) return null;
    m[0].texture_orientation = orientation;
    m[0].n_textures = n_textures;
    for (0..4) |i| m[0].texture_type[i] = texture_type[i];
    m[0].buffer = buffer;
    m[0].upload = upload;
    m[0].user_data = user_data;
    m[0].user_data_copy = user_data_copy;
    m[0].user_data_free = user_data_free;
    return m;
}

pub export fn gst_video_gl_texture_upload_meta_upload(meta: [*c]Upload, texture_id: [*c]c.guint) c.gboolean {
    if (!check.that(meta != null, "gst_video_gl_texture_upload_meta_upload", "meta != NULL")) return 0;
    return meta[0].upload.?(meta, texture_id);
}

const Roi = c.GstVideoRegionOfInterestMeta;
var roi_api: usize = 0;
var roi_tags = [_][*c]const u8{ "video", "orientation", "size", null };

pub export fn gst_video_region_of_interest_meta_api_get_type() c.GType {
    return apiType(&roi_api, "GstVideoRegionOfInterestMetaAPI", &roi_tags);
}

fn copyStructure(src: c.gconstpointer, _: c.gpointer) callconv(.c) c.gpointer {
    return c.gst_structure_copy(@ptrCast(@alignCast(src)));
}

fn roiTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const s = cast(Roi, m);
    if (isCopy(t)) {
        const d = gst_buffer_add_video_region_of_interest_meta_id(dest, s[0].roi_type, s[0].x, s[0].y, s[0].w, s[0].h);
        if (d == null) return 0;
        d[0].id = s[0].id;
        d[0].parent_id = s[0].parent_id;
        d[0].params = c.g_list_copy_deep(s[0].params, copyStructure, null);
        return 1;
    }
    if (t == gst_video_meta_transform_matrix_get_quark()) {
        const trans: *const Matrix = @ptrCast(@alignCast(data));
        var r = Rect{ .x = @bitCast(s[0].x), .y = @bitCast(s[0].y), .w = @bitCast(s[0].w), .h = @bitCast(s[0].h) };
        if (!rectangle(trans, &r, true)) return 0;
        const d = gst_buffer_add_video_region_of_interest_meta_id(dest, s[0].roi_type, @bitCast(r.x), @bitCast(r.y), @bitCast(r.w), @bitCast(r.h));
        if (d == null) return 0;
        d[0].id = s[0].id;
        d[0].parent_id = s[0].parent_id;
        return 1;
    }
    if (t == gst_video_meta_transform_scale_get_quark()) {
        const sc = scaleInfo(data);
        const ow: c.guint = @bitCast(sc[0]);
        const nw: c.guint = @bitCast(sc[1]);
        const oh: c.guint = @bitCast(sc[2]);
        const nh: c.guint = @bitCast(sc[3]);
        const d = gst_buffer_add_video_region_of_interest_meta_id(dest, s[0].roi_type, (s[0].x *% nw) / ow, (s[0].y *% nh) / oh, (s[0].w *% nw) / ow, (s[0].h *% nh) / oh);
        if (d == null) return 0;
        d[0].id = s[0].id;
        d[0].parent_id = s[0].parent_id;
        return 1;
    }
    return 0;
}

fn roiInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const v = cast(Roi, m);
    v[0].roi_type = 0;
    v[0].id = 0;
    v[0].parent_id = 0;
    v[0].x = 0;
    v[0].y = 0;
    v[0].w = 0;
    v[0].h = 0;
    v[0].params = null;
    return 1;
}

fn freeStructure(p: c.gpointer) callconv(.c) void {
    c.gst_structure_free(@ptrCast(@alignCast(p)));
}

fn roiFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    c.g_list_free_full(cast(Roi, m)[0].params, freeStructure);
}

var roi_info: usize = 0;

fn makeRoi() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_region_of_interest_meta_api_get_type(), "GstVideoRegionOfInterestMeta", @sizeOf(Roi), roiInit, roiFree, roiTransform);
}

pub export fn gst_video_region_of_interest_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&roi_info, makeRoi);
}

pub export fn gst_buffer_get_video_region_of_interest_meta_id(buffer: [*c]Buffer, id: c.gint) [*c]Roi {
    var state: c.gpointer = null;
    const api = gst_video_region_of_interest_meta_get_info()[0].api;
    while (true) {
        const m = c.gst_buffer_iterate_meta(buffer, &state);
        if (m == null) return null;
        if (m[0].info[0].api == api and cast(Roi, m)[0].id == id) return cast(Roi, m);
    }
}

pub export fn gst_buffer_add_video_region_of_interest_meta(buffer: [*c]Buffer, roi_type: [*c]const u8, x: c.guint, y: c.guint, w: c.guint, h: c.guint) [*c]Roi {
    return gst_buffer_add_video_region_of_interest_meta_id(buffer, c.g_quark_from_string(roi_type), x, y, w, h);
}

pub export fn gst_buffer_add_video_region_of_interest_meta_id(buffer: [*c]Buffer, roi_type: c.GQuark, x: c.guint, y: c.guint, w: c.guint, h: c.guint) [*c]Roi {
    if (!check.that(isBuffer(buffer), "gst_buffer_add_video_region_of_interest_meta_id", "GST_IS_BUFFER (buffer)")) return null;
    const m = cast(Roi, c.gst_buffer_add_meta(buffer, gst_video_region_of_interest_meta_get_info(), null));
    m[0].roi_type = roi_type;
    m[0].x = x;
    m[0].y = y;
    m[0].w = w;
    m[0].h = h;
    return m;
}

pub export fn gst_video_region_of_interest_meta_add_param(meta: [*c]Roi, s: ?*c.GstStructure) void {
    const fname = "gst_video_region_of_interest_meta_add_param";
    if (!check.that(meta != null, fname, "meta")) return;
    if (!check.that(s != null, fname, "s")) return;
    meta[0].params = c.g_list_append(meta[0].params, s);
}

pub export fn gst_video_region_of_interest_meta_get_param(meta: [*c]Roi, name: [*c]const u8) ?*c.GstStructure {
    const fname = "gst_video_region_of_interest_meta_get_param";
    if (!check.that(meta != null, fname, "meta")) return null;
    if (!check.that(name != null, fname, "name")) return null;
    var l = meta[0].params;
    while (l != null) : (l = l[0].next) {
        const s: ?*c.GstStructure = @ptrCast(@alignCast(l[0].data));
        if (c.gst_structure_has_name(s, name) != 0) return s;
    }
    return null;
}

const TCMeta = c.GstVideoTimeCodeMeta;
var tc_api: usize = 0;
var tc_tags = [_][*c]const u8{null};

pub export fn gst_video_time_code_meta_api_get_type() c.GType {
    return apiType(&tc_api, "GstVideoTimeCodeMetaAPI", &tc_tags);
}

fn tcTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    if (!isCopy(t)) return 0;
    const s = cast(TCMeta, m);
    const tc = s[0].tc;
    return @intFromBool(gst_buffer_add_video_time_code_meta_full(dest, tc.config.fps_n, tc.config.fps_d, tc.config.latest_daily_jam, tc.config.flags, tc.hours, tc.minutes, tc.seconds, tc.frames, tc.field_count) != null);
}

fn tcInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const v = cast(TCMeta, m);
    v[0].tc = std.mem.zeroes(c.GstVideoTimeCode);
    timecode.gst_video_time_code_clear(&v[0].tc);
    return 1;
}

fn tcFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    timecode.gst_video_time_code_clear(&cast(TCMeta, m)[0].tc);
}

var tc_info: usize = 0;

fn makeTc() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_time_code_meta_api_get_type(), "GstVideoTimeCodeMeta", @sizeOf(TCMeta), tcInit, tcFree, tcTransform);
}

pub export fn gst_video_time_code_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&tc_info, makeTc);
}

pub export fn gst_buffer_add_video_time_code_meta(buffer: [*c]Buffer, tc: [*c]const c.GstVideoTimeCode) [*c]TCMeta {
    if (timecode.gst_video_time_code_is_valid(tc) == 0) return null;
    const t = &tc[0];
    return gst_buffer_add_video_time_code_meta_full(buffer, t.config.fps_n, t.config.fps_d, t.config.latest_daily_jam, t.config.flags, t.hours, t.minutes, t.seconds, t.frames, t.field_count);
}

pub export fn gst_buffer_add_video_time_code_meta_full(buffer: [*c]Buffer, fps_n: c.guint, fps_d: c.guint, jam: ?*c.GDateTime, flags: c.GstVideoTimeCodeFlags, hours: c.guint, minutes: c.guint, seconds: c.guint, frames: c.guint, field_count: c.guint) [*c]TCMeta {
    const fname = "gst_buffer_add_video_time_code_meta_full";
    if (!check.that(isBuffer(buffer), fname, "GST_IS_BUFFER (buffer)")) return null;
    const m = cast(TCMeta, c.gst_buffer_add_meta(buffer, gst_video_time_code_meta_get_info(), null));
    if (!check.that(m != null, fname, "meta != NULL")) return null;
    timecode.gst_video_time_code_init(&m[0].tc, fps_n, fps_d, jam, flags, hours, minutes, seconds, frames, field_count);
    if (timecode.gst_video_time_code_is_valid(&m[0].tc) == 0) {
        _ = c.gst_buffer_remove_meta(buffer, @ptrCast(m));
        return null;
    }
    return m;
}

const Alpha = c.GstVideoCodecAlphaMeta;
var alpha_api: usize = 0;
var alpha_tags = [_][*c]const u8{ "video", null };

pub export fn gst_video_codec_alpha_meta_api_get_type() c.GType {
    return apiType(&alpha_api, "GstVideoCodecAlphaMetaAPI", &alpha_tags);
}

fn alphaTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    if (isCopy(t)) {
        const d = cast(Alpha, c.gst_buffer_add_meta(dest, gst_video_codec_alpha_meta_get_info(), null));
        if (d == null) return 0;
        d[0].buffer = c.gst_buffer_ref(cast(Alpha, m)[0].buffer);
    }
    return 1;
}

fn alphaInit(m: [*c]Meta, params: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    cast(Alpha, m)[0].buffer = @ptrCast(@alignCast(params));
    return 1;
}

fn alphaFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    const a = cast(Alpha, m);
    if (a[0].buffer != null) c.gst_buffer_unref(a[0].buffer);
    a[0].buffer = null;
}

var alpha_info: usize = 0;

fn makeAlpha() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_codec_alpha_meta_api_get_type(), "GstVideoCodecAlphaMeta", @sizeOf(Alpha), alphaInit, alphaFree, alphaTransform);
}

pub export fn gst_video_codec_alpha_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&alpha_info, makeAlpha);
}

pub export fn gst_buffer_add_video_codec_alpha_meta(buffer: [*c]Buffer, alpha: [*c]Buffer) [*c]Alpha {
    const fname = "gst_buffer_add_video_codec_alpha_meta";
    if (!check.that(buffer != null, fname, "buffer != NULL")) return null;
    if (!check.that(alpha != null, fname, "alpha_buffer != NULL")) return null;
    return cast(Alpha, c.gst_buffer_add_meta(buffer, gst_video_codec_alpha_meta_get_info(), alpha));
}

const Affine = c.GstVideoAffineTransformationMeta;
var affine_api: usize = 0;
var affine_tags = [_][*c]const u8{ "video", "orientation", "orientation", null };

pub export fn gst_video_affine_transformation_meta_api_get_type() c.GType {
    return apiType(&affine_api, "GstVideoAffineTransformationAPI", &affine_tags);
}

fn affineTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    if (isCopy(t)) {
        const d = cast(Affine, c.gst_buffer_add_meta(dest, gst_video_affine_transformation_meta_get_info(), null));
        if (d == null) return 0;
        d[0].matrix = cast(Affine, m)[0].matrix;
    }
    return 1;
}

fn affineInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    cast(Affine, m)[0].matrix = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    return 1;
}

var affine_info: usize = 0;

fn makeAffine() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_affine_transformation_meta_api_get_type(), "GstVideoAffineTransformationMeta", @sizeOf(Affine), affineInit, null, affineTransform);
}

pub export fn gst_video_affine_transformation_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&affine_info, makeAffine);
}

pub export fn gst_buffer_add_video_affine_transformation_meta(buffer: [*c]Buffer) [*c]Affine {
    if (!check.that(buffer != null, "gst_buffer_add_video_affine_transformation_meta", "buffer != NULL")) return null;
    return cast(Affine, c.gst_buffer_add_meta(buffer, gst_video_affine_transformation_meta_get_info(), null));
}

pub export fn gst_video_affine_transformation_meta_apply_matrix(meta: [*c]Affine, matrix: [*c]const f32) void {
    var res = [_]f32{0} ** 16;
    for (0..4) |i| for (0..4) |j| for (0..4) |k| {
        res[i + j * 4] += meta[0].matrix[i + k * 4] * matrix[k + j * 4];
    };
    meta[0].matrix = res;
}
