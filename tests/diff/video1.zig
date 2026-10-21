const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn showCaps(label: []const u8, caps: [*c]c.GstCaps) void {
    if (caps == null) {
        out("  {s} (null)", .{label});
        return;
    }
    const s = c.gst_caps_to_string(caps);
    out("  {s} {s}", .{ label, str(s) });
    c.g_free(s);
    c.gst_caps_unref(caps);
}

const LAST = c.GST_VIDEO_FORMAT_RGB10x2_LE;

fn infos() void {
    out("infos", .{});
    var f: c_int = 0;
    while (f <= LAST) : (f += 1) {
        const i = c.gst_video_format_get_info(@intCast(f));
        const t = i[0].tile_info;
        out("  {d} {s} '{s}' fl={d} bits={d} nc={d} sh={any} d={any} ps={any} np={d} pl={any} po={any} ws={any} hs={any} up={d} lines={d} tm={d} tws={d} ths={d} tiles={d},{d},{d},{d}/{d},{d},{d},{d} f={d}{d} cc={x} back={d}", .{ f, str(i[0].name), str(i[0].description), i[0].flags, i[0].bits, i[0].n_components, i[0].shift, i[0].depth, i[0].pixel_stride, i[0].n_planes, i[0].plane, i[0].poffset, i[0].w_sub, i[0].h_sub, i[0].unpack_format, i[0].pack_lines, i[0].tile_mode, i[0].tile_ws, i[0].tile_hs, t[0].width, t[0].height, t[0].stride, t[0].size, t[1].width, t[1].height, t[1].stride, t[1].size, @intFromBool(i[0].unpack_func != null), @intFromBool(i[0].pack_func != null), c.gst_video_format_to_fourcc(@intCast(f)), c.gst_video_format_from_string(i[0].name) });
        var comp: [4]c.gint = undefined;
        for (0..4) |p| {
            c.gst_video_format_info_component(i, @intCast(p), &comp);
            out("    plane {d} comps {any} stride {d} {d} {d}", .{ p, comp, c.gst_video_format_info_extrapolate_stride(i, @intCast(p), 0), c.gst_video_format_info_extrapolate_stride(i, @intCast(p), 100), c.gst_video_format_info_extrapolate_stride(i, @intCast(p), 101) });
        }
    }
    _ = c.gst_video_format_get_info(LAST + 1);
    _ = c.gst_video_format_to_string(LAST + 1);
    out("  to_fourcc past {d} unknown {d}", .{ c.gst_video_format_to_fourcc(LAST + 1), c.gst_video_format_to_fourcc(c.GST_VIDEO_FORMAT_UNKNOWN) });
    out("  from_string bogus {d}", .{c.gst_video_format_from_string("NOPE")});
    _ = c.gst_video_format_from_string(null);
}

fn api() void {
    out("api", .{});
    for ([_]*const [4]u8{ "I420", "YV12", "YUY2", "YVYU", "UYVY", "VYUY", "AYUV", "Y41B", "Y42B", "Y444", "v210", "v216", "Y210", "NV12", "NV21", "NV16", "NV61", "NV24", "v308", "IYU2", "Y800", "Y8  ", "GREY", "Y16 ", "UYVP", "A420", "YUV9", "YVU9", "IYU1", "AY64", "XV10", "XV15", "XV20", "RK20", "Y410", "VUYA", "AR30", "RGBA", "NV20", "P010", "MM21", "0000" }) |s| {
        const cc = @as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24;
        out("  fourcc {s} -> {d}", .{ s, c.gst_video_format_from_fourcc(cc) });
    }
    const masks = [_][7]c.guint{
        .{ 24, 32, 4321, 0xff000000, 0x00ff0000, 0x0000ff00, 0 },
        .{ 24, 32, 4321, 0x0000ff00, 0x00ff0000, 0xff000000, 0 },
        .{ 24, 32, 4321, 0x00ff0000, 0x0000ff00, 0x000000ff, 0 },
        .{ 24, 32, 4321, 0x000000ff, 0x0000ff00, 0x00ff0000, 0 },
        .{ 24, 32, 1234, 0xff000000, 0x00ff0000, 0x0000ff00, 0 },
        .{ 24, 32, 1234, 0x000000ff, 0x0000ff00, 0x00ff0000, 0 },
        .{ 32, 32, 4321, 0xff000000, 0x00ff0000, 0x0000ff00, 0x000000ff },
        .{ 32, 32, 4321, 0x0000ff00, 0x00ff0000, 0xff000000, 0x000000ff },
        .{ 32, 32, 4321, 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000 },
        .{ 32, 32, 4321, 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000 },
        .{ 32, 32, 1234, 0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000 },
        .{ 32, 32, 1234, 0x3ff00000, 0x000ffc00, 0x000003ff, 0xc0000000 },
        .{ 32, 32, 1234, 0x000003ff, 0x000ffc00, 0x3ff00000, 0xc0000000 },
        .{ 32, 32, 4321, 0xff000000, 0x00ff0000, 0x0000ff00, 0 },
        .{ 30, 32, 4321, 0, 0, 0, 0 },
        .{ 24, 24, 4321, 0xff0000, 0x00ff00, 0x0000ff, 0 },
        .{ 24, 24, 4321, 0x0000ff, 0x00ff00, 0xff0000, 0 },
        .{ 24, 24, 1234, 0x0000ff, 0x00ff00, 0xff0000, 0 },
        .{ 24, 24, 1234, 0xff0000, 0x00ff00, 0x0000ff, 0 },
        .{ 16, 16, 1234, 0xf800, 0x07e0, 0x001f, 0 },
        .{ 16, 16, 1234, 0x001f, 0x07e0, 0xf800, 0 },
        .{ 15, 16, 1234, 0x7c00, 0x03e0, 0x001f, 0 },
        .{ 15, 16, 1234, 0x001f, 0x03e0, 0x7c00, 0 },
        .{ 16, 16, 4321, 0xf800, 0x07e0, 0x001f, 0 },
        .{ 8, 8, 1234, 0, 0, 0, 0 },
        .{ 64, 64, 4321, 0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000 },
        .{ 64, 64, 4321, 0xff000000, 0x00ff0000, 0x0000ff00, 0x000000ff },
        .{ 12, 12, 1234, 0, 0, 0, 0 },
    };
    for (masks) |m| out("  masks {d}/{d}/{d} {x} {x} {x} {x} -> {d}", .{ m[0], m[1], m[2], m[3], m[4], m[5], m[6], c.gst_video_format_from_masks(@intCast(m[0]), @intCast(m[1]), @intCast(m[2]), m[3], m[4], m[5], m[6]) });
    var size: c.gsize = 0;
    const pal: [*c]const u32 = @ptrCast(@alignCast(c.gst_video_format_get_palette(c.GST_VIDEO_FORMAT_RGB8P, &size)));
    var h: u32 = 2166136261;
    for (0..size / 4) |i| h = (h ^ pal[i]) *% 16777619;
    out("  palette {d} {x} {x} {x} {x}", .{ size, pal[0], pal[215], pal[216], h });
    out("  palette other {any}", .{c.gst_video_format_get_palette(c.GST_VIDEO_FORMAT_I420, &size) == null});
    _ = c.gst_video_format_get_palette(c.GST_VIDEO_FORMAT_RGB8P, null);
    _ = c.gst_video_format_get_palette(LAST + 1, &size);
    var n: c.guint = 0;
    const raw = c.gst_video_formats_raw(&n);
    out("  raw {d}: {any}", .{ n, raw[0..n] });
    const anyf = c.gst_video_formats_any(&n);
    out("  any {d}: {any}", .{ n, anyf[0..n] });
    _ = c.gst_video_formats_raw(null);
    _ = c.gst_video_formats_any(null);
    showCaps("caps all", c.gst_video_make_raw_caps(null, 0));
    var two = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_I420_10LE };
    showCaps("caps two", c.gst_video_make_raw_caps(&two, 2));
    showCaps("caps one", c.gst_video_make_raw_caps(&two, 1));
    showCaps("caps feat", c.gst_video_make_raw_caps_with_features(&two, 2, c.gst_caps_features_new_static_str("memory:GLMemory", @as(?*anyopaque, null))));
    var bad = [_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_ENCODED };
    showCaps("caps bad", c.gst_video_make_raw_caps(&bad, 2));
    showCaps("caps null len", c.gst_video_make_raw_caps(null, 3));
    for ([_]c_int{ c.GST_VIDEO_TILE_MODE_ZFLIPZ_2X2, c.GST_VIDEO_TILE_MODE_LINEAR }) |mode| {
        for ([_][2]c_int{ .{ 8, 7 }, .{ 8, 6 }, .{ 3, 3 }, .{ 5, 4 } }) |dims| {
            var line: [80]u8 = undefined;
            var p: usize = 0;
            var y: c_int = 0;
            while (y < dims[1]) : (y += 1) {
                var x: c_int = 0;
                while (x < dims[0]) : (x += 1) {
                    const v = c.gst_video_tile_get_index(@intCast(mode), x, y, dims[0], dims[1]);
                    const s = std.fmt.bufPrint(line[p..], "{d} ", .{v}) catch break;
                    p += s.len;
                }
                out("  tile {d} {d}x{d} row {d}: {s}", .{ mode, dims[0], dims[1], y, line[0..p] });
                p = 0;
            }
        }
    }
    _ = c.gst_video_tile_get_index(c.GST_VIDEO_TILE_MODE_UNKNOWN, 1, 1, 2, 2);
}

const PLANE = 1 << 17;
var planes: [4][PLANE + 64]u8 align(16) = undefined;
var dest: [512]u8 align(16) = undefined;
var src: [8192]u8 align(16) = undefined;

var seed: u32 = 1;

fn rnd() u8 {
    seed = seed *% 1103515245 +% 12345;
    return @truncate(seed >> 16);
}

fn fill(fmt: c_int) void {
    seed = @intCast(fmt * 7919 + 13);
    for (&planes) |*p| {
        for (p) |*b| b.* = rnd();
    }
}

fn fnv(h: *u32, bytes: []const u8) void {
    for (bytes) |b| h.* = (h.* ^ b) *% 16777619;
}

fn layout(i: [*c]const c.GstVideoFormatInfo, stride: *[4]c.gint, data: *[4]c.gpointer, shift: usize) void {
    const tiled = i[0].tile_mode != 0;
    for (0..4) |p| {
        stride[p] = if (tiled) 16 | (8 << 16) else 2048;
        data[p] = @ptrCast(&planes[p][shift]);
    }
}

fn isTiled(i: [*c]const c.GstVideoFormatInfo) bool {
    return i[0].tile_mode != 0;
}

fn mt(f: c_int) bool {
    return f == c.GST_VIDEO_FORMAT_MT2110T or f == c.GST_VIDEO_FORMAT_MT2110R;
}

const widths = [_]c_int{ 1, 2, 3, 4, 5, 6, 7, 8, 12, 13, 16, 31, 32, 48 };
const ys = [_]c_int{ 0, 1, 2, 3, 5, 9 };
const flagsets = [_]c_uint{ 0, c.GST_VIDEO_PACK_FLAG_TRUNCATE_RANGE, c.GST_VIDEO_PACK_FLAG_INTERLACED, c.GST_VIDEO_PACK_FLAG_TRUNCATE_RANGE | c.GST_VIDEO_PACK_FLAG_INTERLACED };
var verbose = false;

fn unpackAll(f: c_int, i: [*c]const c.GstVideoFormatInfo) u32 {
    var h: u32 = 2166136261;
    const xs: []const c_int = if (mt(f)) &.{0} else &.{ 0, 1, 2, 3, 5 };
    for ([_]usize{ 0, 2, 4 }) |shift| {
        var stride: [4]c.gint = undefined;
        var data: [4]c.gpointer = undefined;
        layout(i, &stride, &data, shift);
        for ([_]usize{ 0, 4 }) |dshift| {
            for (xs) |x| for (ys) |y| for (widths) |w| for (flagsets) |fl| {
                if (x != 0 and w < 4) continue;
                if (isTiled(i) and w <= x) continue;
                @memset(&dest, 0xcd);
                i[0].unpack_func.?(i, fl, @ptrCast(&dest[dshift]), &data, &stride, x, y, w);
                var one: u32 = 2166136261;
                fnv(&one, &dest);
                if (verbose) out("    u s{d} d{d} x{d} y{d} w{d} f{d} {x}", .{ shift, dshift, x, y, w, fl, one });
                fnv(&h, &dest);
            };
        }
    }
    return h;
}

fn packAll(f: c_int, i: [*c]const c.GstVideoFormatInfo) u32 {
    var h: u32 = 2166136261;
    const ui = c.gst_video_format_get_info(i[0].unpack_format);
    const ps: usize = @intCast(ui[0].pixel_stride[0]);
    fill(f + 1);
    for (&src) |*b| b.* = rnd();
    for ([_]usize{ 0, 4 }) |shift| {
        var stride: [4]c.gint = undefined;
        var data: [4]c.gpointer = undefined;
        layout(i, &stride, &data, shift);
        for (ys) |y| for (widths) |w| for ([_]c_uint{ 0, c.GST_VIDEO_PACK_FLAG_INTERLACED }) |fl| {
            if (mt(f) and @rem(w, 16) != 0) continue;
            i[0].pack_func.?(i, fl, @ptrCast(&src), @intCast(ps * 48), &data, &stride, c.GST_VIDEO_CHROMA_SITE_UNKNOWN, y, w);
            var one: u32 = 2166136261;
            for (0..i[0].n_planes) |p| fnv(&one, planes[p][0 .. 1 << 15]);
            if (isTiled(i)) {
                for (0..i[0].n_planes) |p| fnv(&one, planes[p][1 << 15 .. PLANE]);
            }
            if (verbose) out("    p s{d} y{d} w{d} f{d} {x}", .{ shift, y, w, fl, one });
            h = (h ^ one) *% 16777619;
        };
    }
    return h;
}

fn packing() void {
    out("pack", .{});
    var f: c_int = 2;
    const only = std.c.getenv("SM_FORMAT");
    while (f <= LAST) : (f += 1) {
        const i = c.gst_video_format_get_info(@intCast(f));
        if (i[0].unpack_func == null) continue;
        if (only != null and c.strcmp(only, i[0].name) != 0) continue;
        fill(f);
        const u = unpackAll(f, i);
        const p = packAll(f, i);
        out("  {s} unpack {x} pack {x}", .{ str(i[0].name), u, p });
    }
}

pub fn main() void {
    c.gst_init(null, null);
    verbose = std.c.getenv("SM_VERBOSE") != null;
    infos();
    api();
    packing();
}
