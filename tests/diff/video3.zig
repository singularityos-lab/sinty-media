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

const LAST = c.GST_VIDEO_FORMAT_RGB10x2_LE;
const NONE = @as(?*anyopaque, null);

fn showCaps(label: []const u8, caps: [*c]c.GstCaps) void {
    if (caps == null) {
        out("  {s} (null)", .{label});
        return;
    }
    const s = c.gst_caps_to_string(caps);
    out("  {s} {s}", .{ label, str(s) });
    c.g_free(s);
}

fn showInfo(label: []const u8, info: *const c.GstVideoInfo) void {
    out("  {s} {s} {d}x{d} im {d} size {d} off {any} stride {any}", .{ label, str(info.finfo[0].name), info.width, info.height, info.interlace_mode, info.size, info.offset, info.stride });
}

fn dma() void {
    out("dma", .{});
    var f: c_int = 0;
    while (f <= LAST) : (f += 1) {
        var m: c_ulong = 7;
        const cc = c.gst_video_dma_drm_format_from_gst_format(@intCast(f), &m);
        const s = if (cc != 0 and m != 0x00ffffffffffffff) c.gst_video_dma_drm_fourcc_to_string(cc, m) else null;
        out("  fmt {d} -> {x} {x} {s} plain {x} back {d} exact {d}", .{ f, cc, m, str(s), c.gst_video_dma_drm_fourcc_from_format(@intCast(f)), c.gst_video_dma_drm_fourcc_to_format(cc), c.gst_video_dma_drm_format_to_gst_format(cc, m) });
        c.g_free(s);
    }
    for ([_][*c]const u8{ "NV12", "NV12:0x0100000000000001", "NV12:0x0000000000000000", "NV12:0X0600000000000001", "NV12:1234", "NV12:", "NV1:0x01", "AR24", "R16 _BE", "R16 _BEX", "XXXX_BE:0x0b00000000010001", "NV15:0x0b00000000010001", "ABCDEFGH", "", "NV12:0xzz", "NV12:0x00ffffffffffffff" }) |s| {
        var m: c_ulong = 7;
        const cc = c.gst_video_dma_drm_fourcc_from_string(s, &m);
        out("  from {s} -> {x} {x} nomod {x}", .{ str(s), cc, m, c.gst_video_dma_drm_fourcc_from_string(s, null) });
    }
    _ = c.gst_video_dma_drm_fourcc_from_string(null, null);
    _ = c.gst_video_dma_drm_fourcc_to_string(0, 0);
    _ = c.gst_video_dma_drm_fourcc_to_string(0x3231564e, 0x00ffffffffffffff);
    out("  unknown fmt {d}", .{c.gst_video_dma_drm_format_to_gst_format(0, 5)});
    out("  unknown fmt2 {d}", .{c.gst_video_dma_drm_format_to_gst_format(0x3231564e, 5)});
    const strs = [_][*c]const u8{
        "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=NV12,width=64,height=48,framerate=30/1",
        "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=NV12:0x0100000000000002,width=64,height=48",
        "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=NV12:0x0600000000000001,width=64,height=48",
        "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=AR24,width=64,height=48,colorimetry=sRGB",
        "video/x-raw(memory:DMABuf),format=DMA_DRM,width=64,height=48",
        "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=XX,width=64,height=48",
        "video/x-raw(memory:DMABuf),format=NV12,width=64,height=48",
        "video/x-raw,format=DMA_DRM,drm-format=NV12,width=64,height=48",
        "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=NV12,width=64",
        "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format={NV12,AR24},width=64,height=48",
    };
    for (strs) |s| {
        const caps = c.gst_caps_from_string(s);
        var d: c.GstVideoInfoDmaDrm = undefined;
        c.gst_video_info_dma_drm_init(&d);
        const ok = c.gst_video_info_dma_drm_from_caps(&d, caps);
        out(" caps {s} is {d} -> {d} {x} {x}", .{ str(s), c.gst_video_is_dma_drm_caps(caps), ok, d.drm_fourcc, d.drm_modifier });
        if (ok != 0) {
            showInfo("vinfo", &d.vinfo);
            showCaps("back", c.gst_video_info_dma_drm_to_caps(&d));
            var vi: c.GstVideoInfo = undefined;
            const t = c.gst_video_info_dma_drm_to_video_info(&d, &vi);
            out("  to_video {d}", .{t});
            if (t != 0) showInfo("video", &vi);
            const n = c.gst_video_info_dma_drm_new_from_caps(caps);
            out("  new {any}", .{n != null});
            if (n != null) c.gst_video_info_dma_drm_free(n);
        } else {
            out("  new null {any}", .{c.gst_video_info_dma_drm_new_from_caps(caps) == null});
        }
        if (caps != null) c.gst_caps_unref(caps);
    }
    f = 2;
    while (f <= LAST) : (f += 1) {
        var vi: c.GstVideoInfo = undefined;
        if (c.gst_video_info_set_format(&vi, @intCast(f), 64, 48) == 0) continue;
        for ([_]c_ulong{ 0, 0x0100000000000002, 0x00ffffffffffffff }) |m| {
            var d: c.GstVideoInfoDmaDrm = undefined;
            c.gst_video_info_dma_drm_init(&d);
            const ok = c.gst_video_info_dma_drm_from_video_info(&d, &vi, m);
            if (ok == 0) continue;
            out("  fromvi {d} {x} -> {x}", .{ f, m, d.drm_fourcc });
            showInfo("drm", &d.vinfo);
            showCaps("caps", c.gst_video_info_dma_drm_to_caps(&d));
            var back: c.GstVideoInfo = undefined;
            const t = c.gst_video_info_dma_drm_to_video_info(&d, &back);
            out("  tovi {d}", .{t});
            if (t != 0) showInfo("tovi", &back);
        }
    }
    const n = c.gst_video_info_dma_drm_new();
    out("  new {x} {x} {s}", .{ n[0].drm_fourcc, n[0].drm_modifier, str(n[0].vinfo.finfo[0].name) });
    showCaps("empty", c.gst_video_info_dma_drm_to_caps(n));
    _ = c.gst_video_info_dma_drm_to_caps(null);
    c.gst_video_info_dma_drm_free(n);
    out("  type {s}", .{str(c.g_type_name(c.gst_video_info_dma_drm_get_type()))});
    _ = c.gst_video_is_dma_drm_caps(null);
    _ = c.gst_video_info_dma_drm_from_caps(null, null);
}

fn hdr() void {
    out("hdr", .{});
    for ([_][*c]const u8{ "1:2:3:4:5:6:7:8:9:10", "35400:14600:8500:39850:6550:2300:15635:16450:10000000:1", "65536:2:3:4:5:6:7:8:9:10", "1:2:3:4:5:6:7:8:4294967295:4294967296", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8:9:10:11", "a:2:3:4:5:6:7:8:9:10", " 1:2:3:4:5:6:7:8:9:10", "-1:2:3:4:5:6:7:8:9:10", "", "0x10:2:3:4:5:6:7:8:9:10", "1:2:3:4:5:6:7:8:3000000000:10" }) |s| {
        var m: c.GstVideoMasteringDisplayInfo = undefined;
        @memset(std.mem.asBytes(&m), 0x33);
        const ok = c.gst_video_mastering_display_info_from_string(&m, s);
        const back = c.gst_video_mastering_display_info_to_string(&m);
        var z: c.GstVideoMasteringDisplayInfo = undefined;
        c.gst_video_mastering_display_info_init(&z);
        out("  mdi {s} -> {d} {s} eqzero {d} self {d}", .{ str(s), ok, str(back), c.gst_video_mastering_display_info_is_equal(&m, &z), c.gst_video_mastering_display_info_is_equal(&m, &m) });
        c.g_free(back);
    }
    for ([_][*c]const u8{ "1000:400", "65535:65535", "65536:1", "1:2:3", "1", ":", "x:1", "" }) |s| {
        var l: c.GstVideoContentLightLevel = undefined;
        @memset(std.mem.asBytes(&l), 0x33);
        const ok = c.gst_video_content_light_level_from_string(&l, s);
        const back = c.gst_video_content_light_level_to_string(&l);
        var z: c.GstVideoContentLightLevel = undefined;
        c.gst_video_content_light_level_init(&z);
        out("  cll {s} -> {d} {s} eqzero {d}", .{ str(s), ok, str(back), c.gst_video_content_light_level_is_equal(&l, &z) });
        c.g_free(back);
    }
    const caps = c.gst_caps_from_string("video/x-raw,mastering-display-info=\"1:2:3:4:5:6:7:8:9:10\",content-light-level=\"5:6\"");
    var m: c.GstVideoMasteringDisplayInfo = undefined;
    var l: c.GstVideoContentLightLevel = undefined;
    out("  from caps {d} {d}", .{ c.gst_video_mastering_display_info_from_caps(&m, caps), c.gst_video_content_light_level_from_caps(&l, caps) });
    const empty = c.gst_caps_from_string("video/x-raw");
    out("  from empty {d} {d}", .{ c.gst_video_mastering_display_info_from_caps(&m, empty), c.gst_video_content_light_level_from_caps(&l, empty) });
    out("  add {d} {d}", .{ c.gst_video_mastering_display_info_add_to_caps(&m, empty), c.gst_video_content_light_level_add_to_caps(&l, empty) });
    showCaps("added", empty);
    _ = c.gst_caps_ref(empty);
    out("  add shared {d} {d}", .{ c.gst_video_mastering_display_info_add_to_caps(&m, empty), c.gst_video_content_light_level_add_to_caps(&l, empty) });
    c.gst_caps_unref(empty);
    _ = c.gst_video_mastering_display_info_from_caps(&m, null);
    _ = c.gst_video_mastering_display_info_from_caps(null, caps);
    _ = c.gst_video_content_light_level_from_caps(&l, null);
    _ = c.gst_video_mastering_display_info_from_string(null, "x");
    _ = c.gst_video_mastering_display_info_from_string(&m, null);
    _ = c.gst_video_mastering_display_info_to_string(null);
    _ = c.gst_video_mastering_display_info_is_equal(null, &m);
    _ = c.gst_video_content_light_level_is_equal(&l, null);
    _ = c.gst_video_content_light_level_to_string(null);
    c.gst_video_mastering_display_info_init(null);
    c.gst_video_content_light_level_init(null);
    _ = c.gst_video_mastering_display_info_add_to_caps(&m, null);
    _ = c.gst_video_content_light_level_add_to_caps(null, caps);
    c.gst_caps_unref(caps);
    c.gst_caps_unref(empty);
}

fn misc() void {
    out("misc", .{});
    for ([_][8]c.guint{ .{ 1920, 1080, 1, 1, 1, 1, 0, 0 }, .{ 720, 576, 16, 15, 1, 1, 0, 0 }, .{ 720, 480, 10, 11, 4, 3, 0, 0 }, .{ 1, 1, 0, 1, 1, 1, 0, 0 }, .{ 0x7fffffff, 1, 0x7fffffff, 1, 1, 0x7fffffff, 0, 0 }, .{ 640, 480, 1, 0, 1, 1, 0, 0 }, .{ 3, 7, 11, 13, 17, 19, 0, 0 } }) |v| {
        var n: c.guint = 99;
        var d: c.guint = 99;
        const ok = c.gst_video_calculate_display_ratio(&n, &d, v[0], v[1], v[2], v[3], v[4], v[5]);
        out("  dar {any} -> {d} {d}/{d}", .{ v[0..6], ok, n, d });
    }
    _ = c.gst_video_calculate_display_ratio(null, null, 1, 1, 1, 1, 1, 1);
    for ([_]u64{ 0, 1, 2, 100000, 100001, 33333333, 33366666, 33366667, 40000000, 41708333, 16683333, 16666666, 20000000, 1000000000, 2000000000, 66733333, 17, 12345678901, 333667, 8341666, 100000000000 }) |dur| {
        var n: c.gint = 99;
        var d: c.gint = 99;
        const ok = c.gst_video_guess_framerate(dur, &n, &d);
        out("  guess {d} -> {d} {d}/{d} {d}", .{ dur, ok, n, d, c.gst_video_guess_framerate(dur, null, null) });
    }
    for ([_][4]c.gint{ .{ 1920, 1080, 1, 1 }, .{ 640, 480, 1, 1 }, .{ 720, 576, 16, 15 }, .{ 720, 480, 8, 9 }, .{ 1680, 1050, 1, 1 }, .{ 1400, 900, 1, 1 }, .{ 2100, 1100, 1, 1 }, .{ 1000, 1000, 1, 1 }, .{ 0, 0, 0, 0 } }) |v| {
        out("  common {any} -> {d}", .{ v, c.gst_video_is_common_aspect_ratio(v[0], v[1], v[2], v[3]) });
    }
    var a: c.GstVideoAlignment = undefined;
    @memset(std.mem.asBytes(&a), 0x44);
    c.gst_video_alignment_reset(&a);
    out("  reset {d} {d} {d} {d} {any}", .{ a.padding_top, a.padding_bottom, a.padding_left, a.padding_right, a.stride_align });
    c.gst_video_alignment_reset(null);
    for ([_][*c]const u8{ "rotate-0", "rotate-90", "rotate-180", "rotate-270", "flip-rotate-0", "flip-rotate-90", "flip-rotate-180", "flip-rotate-270", "rotate-45", null }) |o| {
        const tl = c.gst_tag_list_new_empty();
        if (o != null) c.gst_tag_list_add(tl, c.GST_TAG_MERGE_REPLACE, "image-orientation", o, NONE);
        var meth: c.GstVideoOrientationMethod = 99;
        const ok = c.gst_video_orientation_from_tag(tl, &meth);
        out("  orient {s} -> {d} {d}", .{ str(o), ok, meth });
        c.gst_tag_list_unref(tl);
    }
    var meth: c.GstVideoOrientationMethod = 0;
    _ = c.gst_video_orientation_from_tag(null, &meth);
    const tl = c.gst_tag_list_new_empty();
    _ = c.gst_video_orientation_from_tag(tl, null);
    c.gst_tag_list_unref(tl);
    const caps = c.gst_caps_new_empty();
    _ = c.gst_video_orientation_from_tag(@ptrCast(caps), &meth);
    c.gst_caps_unref(caps);
}

pub fn main() void {
    c.gst_init(null, null);
    dma();
    hdr();
    misc();
}
