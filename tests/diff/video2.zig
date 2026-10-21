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

fn owned(p: [*c]u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const LAST = c.GST_VIDEO_FORMAT_RGB10x2_LE;

fn bits(v: f64) u64 {
    return @bitCast(v);
}

fn colors() void {
    out("colorimetry", .{});
    for ([_][*c]const u8{ "bt601", "bt709", "smpte240m", "sRGB", "bt2020", "bt2020-10", "bt2100-pq", "bt2100-hlg", "1:2:3:4", "0:0:0:0", " 2 : 3:4:5", "1:2:3", "-1:2:3:4", "bogus", "", "BT709", null }) |s| {
        var ci = std.mem.zeroes(c.GstVideoColorimetry);
        ci.range = 9;
        const ok = c.gst_video_colorimetry_from_string(&ci, s);
        const back = c.gst_video_colorimetry_to_string(&ci);
        out("  from {s} -> {d} {d}:{d}:{d}:{d} back {s}", .{ str(s), ok, ci.range, ci.matrix, ci.transfer, ci.primaries, owned(back) });
        c.g_free(back);
    }
    var r: c_uint = 0;
    while (r < 4) : (r += 1) {
        var m: c_uint = 0;
        while (m < 7) : (m += 1) {
            var t: c_uint = 0;
            while (t < 17) : (t += 1) {
                var p: c_uint = 0;
                var line: [512]u8 = undefined;
                var n: usize = 0;
                while (p < 13) : (p += 1) {
                    const ci = c.GstVideoColorimetry{ .range = r, .matrix = m, .transfer = t, .primaries = p };
                    const s = c.gst_video_colorimetry_to_string(&ci);
                    const w = std.fmt.bufPrint(line[n..], "{s}|{d} ", .{ owned(s), c.gst_video_colorimetry_matches(&ci, "bt709") }) catch break;
                    n += w.len;
                    c.g_free(s);
                }
                out("  to {d}:{d}:{d} {s}", .{ r, m, t, line[0..n] });
            }
        }
    }
    const a = c.GstVideoColorimetry{ .range = 2, .matrix = 3, .transfer = 5, .primaries = 1 };
    const b = c.GstVideoColorimetry{ .range = 2, .matrix = 3, .transfer = 6, .primaries = 1 };
    const d = c.GstVideoColorimetry{ .range = 2, .matrix = 3, .transfer = 14, .primaries = 1 };
    const e = c.GstVideoColorimetry{ .range = 2, .matrix = 3, .transfer = 15, .primaries = 1 };
    const f = c.GstVideoColorimetry{ .range = 2, .matrix = 3, .transfer = 15, .primaries = 4 };
    const g = c.GstVideoColorimetry{ .range = 2, .matrix = 3, .transfer = 15, .primaries = 5 };
    const all = [_]*const c.GstVideoColorimetry{ &a, &b, &d, &e, &f, &g };
    for (all) |x| for (all) |y| for ([_]c_uint{ 8, 10, 12 }) |bx| for ([_]c_uint{ 8, 12 }) |by| {
        out("  eq {d}:{d} {d}:{d} {d}/{d} -> {d} {d}", .{ x.transfer, x.primaries, y.transfer, y.primaries, bx, by, c.gst_video_colorimetry_is_equal(x, y), c.gst_video_colorimetry_is_equivalent(x, bx, y, by) });
    };
    _ = c.gst_video_colorimetry_is_equal(null, &a);
    _ = c.gst_video_colorimetry_is_equal(&a, null);
    _ = c.gst_video_colorimetry_is_equivalent(null, 8, &a, 8);
    _ = c.gst_video_colorimetry_is_equivalent(&a, 8, null, 8);
    var fmt: c_int = 2;
    while (fmt <= LAST) : (fmt += 1) {
        const fi = c.gst_video_format_get_info(@intCast(fmt));
        for ([_]c_uint{ 0, 1, 2 }) |range| {
            var off: [4]c.gint = .{ 7, 7, 7, 7 };
            var sc: [4]c.gint = .{ 7, 7, 7, 7 };
            c.gst_video_color_range_offsets(range, fi, &off, &sc);
            out("  range {s} {d} off {any} scale {any}", .{ str(fi[0].name), range, off, sc });
        }
    }
    var p: c_uint = 0;
    while (p < 13) : (p += 1) {
        const pi = c.gst_video_color_primaries_get_info(p);
        out("  prim {d} {d} {x} {x} {x} {x} {x} {x} {x} {x}", .{ p, pi[0].primaries, bits(pi[0].Wx), bits(pi[0].Wy), bits(pi[0].Rx), bits(pi[0].Ry), bits(pi[0].Gx), bits(pi[0].Gy), bits(pi[0].Bx), bits(pi[0].By) });
        var q: c_uint = 0;
        var line: [64]u8 = undefined;
        while (q < 13) : (q += 1) line[q] = '0' + @as(u8, @intCast(c.gst_video_color_primaries_is_equivalent(p, q)));
        out("    equiv {s}", .{line[0..13]});
    }
    out("  prim past {any}", .{c.gst_video_color_primaries_get_info(13) == null});
    var m: c_uint = 0;
    while (m < 8) : (m += 1) {
        var kr: f64 = -1;
        var kb: f64 = -1;
        const ok = c.gst_video_color_matrix_get_Kr_Kb(m, &kr, &kb);
        out("  krkb {d} {d} {x} {x}", .{ m, ok, bits(kr), bits(kb) });
    }
    const vals = [_]f64{ 0, 0.001, 0.0031308, 0.004, 0.01, 0.018, 0.0181, 0.0228, 0.04045, 0.05, 0.081, 0.0913, 0.1, 0.25, 0.5, 0.6, 0.75, 0.9, 1.0, 1.5, -0.1 };
    var t: c_uint = 0;
    while (t < 18) : (t += 1) {
        for (vals) |v| out("  tf {d} {x} enc {x} dec {x} {x} {x}", .{ t, bits(v), bits(c.gst_video_transfer_function_encode(t, v)), bits(c.gst_video_transfer_function_decode(t, v)), bits(c.gst_video_color_transfer_encode(t, v)), bits(c.gst_video_color_transfer_decode(t, v)) });
        for ([_]c_uint{ 8, 10, 12 }) |b1| {
            var line: [32]u8 = undefined;
            var u: c_uint = 0;
            while (u < 18) : (u += 1) line[u] = '0' + @as(u8, @intCast(c.gst_video_transfer_function_is_equivalent(t, b1, u, 10))) + 2 * @as(u8, @intCast(c.gst_video_transfer_function_is_equivalent(t, b1, u, 12)));
            out("    teq {d} {s}", .{ b1, line[0..18] });
        }
    }
    var v: c_uint = 0;
    while (v < 26) : (v += 1) {
        out("  iso {d}: m {d}->{d} t {d}->{d} p {d}->{d}", .{ v, c.gst_video_color_matrix_from_iso(v), c.gst_video_color_matrix_to_iso(v), c.gst_video_transfer_function_from_iso(v), c.gst_video_transfer_function_to_iso(v), c.gst_video_color_primaries_from_iso(v), c.gst_video_color_primaries_to_iso(v) });
    }
}

fn chromas() void {
    out("chroma", .{});
    for ([_][*c]const u8{ "jpeg", "mpeg2", "dv", "alt-line", "cosited", "none", "h-cosited", "v-cosited", "h-cosited+v-cosited", "v-cosited+alt-line", "none+h-cosited", "unknown", "bogus", "h-cosited+bogus", "", "+", "h-cosited+", "jpeg+dv" }) |s| {
        out("  from {s} -> {d} {d}", .{ str(s), c.gst_video_chroma_site_from_string(s), c.gst_video_chroma_from_string(s) });
    }
    var site: c_uint = 0;
    while (site < 40) : (site += 1) {
        const s = c.gst_video_chroma_site_to_string(site);
        out("  to {d} {s} {s}", .{ site, owned(s), str(c.gst_video_chroma_to_string(site)) });
        c.g_free(s);
    }
    var lines8: [4][64 * 4]u8 = undefined;
    var lines16: [4][64 * 4]u16 = undefined;
    var h: u32 = 2166136261;
    for ([_]c_uint{ c.GST_VIDEO_FORMAT_AYUV, c.GST_VIDEO_FORMAT_AYUV64, c.GST_VIDEO_FORMAT_I420 }) |fmt| for ([_]c_uint{ 0, c.GST_VIDEO_CHROMA_SITE_H_COSITED, c.GST_VIDEO_CHROMA_SITE_V_COSITED, c.GST_VIDEO_CHROMA_SITE_COSITED }) |cs| for ([_]c_uint{ 0, c.GST_VIDEO_CHROMA_FLAG_INTERLACED }) |fl| for ([_]c_int{ -2, -1, 0, 1, 2 }) |hf| for ([_]c_int{ -2, -1, 0, 1, 2 }) |vf| {
        const r = c.gst_video_chroma_resample_new(c.GST_VIDEO_CHROMA_METHOD_LINEAR, cs, fl, fmt, hf, vf);
        if (r == null) {
            out("  resample f{d} s{d} fl{d} h{d} v{d} null", .{ fmt, cs, fl, hf, vf });
            continue;
        }
        var nl: c.guint = 0;
        var off: c.gint = 0;
        c.gst_video_chroma_resample_get_info(r, &nl, &off);
        c.gst_video_chroma_resample_get_info(r, null, null);
        var one: u32 = 2166136261;
        for ([_]c_int{ 1, 2, 3, 4, 5, 8, 9, 16, 17, 33, 64 }) |w| {
            for (0..4) |k| {
                for (0..64 * 4) |i| {
                    const x: u32 = @truncate((i * 37 + k * 101 + @as(usize, @intCast(w)) * 13) * 2654435761 >> 7);
                    lines8[k][i] = @truncate(x);
                    lines16[k][i] = @truncate(x);
                }
            }
            for ([_]bool{ false, true }) |same| {
                var ptrs: [4]c.gpointer = undefined;
                for (0..4) |k| {
                    const kk = if (same) k & ~@as(usize, 1) else k;
                    ptrs[k] = if (fmt == c.GST_VIDEO_FORMAT_AYUV64) @ptrCast(&lines16[kk]) else @ptrCast(&lines8[kk]);
                }
                c.gst_video_chroma_resample(r, &ptrs, w);
                for (0..4) |k| {
                    const bytes: []const u8 = if (fmt == c.GST_VIDEO_FORMAT_AYUV64) std.mem.sliceAsBytes(&lines16[k]) else &lines8[k];
                    for (bytes) |b| one = (one ^ b) *% 16777619;
                }
            }
        }
        out("  resample f{d} s{d} fl{d} h{d} v{d} lines {d} off {d} hash {x}", .{ fmt, cs, fl, hf, vf, nl, off, one });
        h = (h ^ one) *% 16777619;
        c.gst_video_chroma_resample_free(r);
    };
    out("  total {x}", .{h});
    c.gst_video_chroma_resample_get_info(null, null, null);
    c.gst_video_chroma_resample_free(null);
    c.gst_video_chroma_resample(null, null, 0);
}

fn showValue(label: []const u8, v: [*c]const c.GValue) void {
    const s = c.gst_value_serialize(v);
    out("  {s} {s}", .{ label, owned(s) });
    c.g_free(s);
}

fn multiviews() void {
    out("multiview", .{});
    var m: c_int = -1;
    while (m < 40) : (m += 1) {
        const s = c.gst_video_multiview_mode_to_caps_string(m);
        out("  mode {d} {s} back {d}", .{ m, str(s), if (s != null) c.gst_video_multiview_mode_from_caps_string(s) else -2 });
    }
    out("  bogus {d}", .{c.gst_video_multiview_mode_from_caps_string("bogus")});
    showValue("mono", c.gst_video_multiview_get_mono_modes());
    showValue("unpacked", c.gst_video_multiview_get_unpacked_modes());
    showValue("dheight", c.gst_video_multiview_get_doubled_height_modes());
    showValue("dwidth", c.gst_video_multiview_get_doubled_width_modes());
    showValue("dsize", c.gst_video_multiview_get_doubled_size_modes());
    out("  flagset type {s}", .{str(c.g_type_name(c.gst_video_multiview_flagset_get_type()))});
    m = 0;
    while (m < 12) : (m += 1) {
        for ([_][4]c.guint{ .{ 1920, 1080, 1, 1 }, .{ 1920, 540, 1, 1 }, .{ 960, 1080, 1, 1 }, .{ 640, 480, 4, 3 }, .{ 1000, 1000, 1, 1 }, .{ 2390, 1000, 1, 1 }, .{ 2389, 1000, 1, 1 }, .{ 0x10000, 0x10000, 0x10000, 1 } }) |d| {
            out("  half {d} {any} -> {d}", .{ m, d, c.gst_video_multiview_guess_half_aspect(m, d[0], d[1], d[2], d[3]) });
        }
        for ([_]c_int{ 0, 1, 3, 8, 10 }) |to| for ([_]c_uint{ 0, c.GST_VIDEO_MULTIVIEW_FLAGS_HALF_ASPECT }) |fl| for ([_]c_uint{ 0, c.GST_VIDEO_MULTIVIEW_FLAGS_HALF_ASPECT | c.GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_VIEW_FIRST }) |ofl| {
            var info: c.GstVideoInfo = undefined;
            _ = c.gst_video_info_set_format(&info, c.GST_VIDEO_FORMAT_I420, 1921, 1081);
            info.ABI.abi.multiview_mode = m;
            info.ABI.abi.multiview_flags = fl;
            info.views = 2;
            c.gst_video_multiview_video_info_change_mode(&info, to, ofl);
            out("  change {d} f{d} -> {d} f{d}: {d}x{d} views {d} par {d}/{d} mode {d} flags {d}", .{ m, fl, to, ofl, info.width, info.height, info.views, info.par_n, info.par_d, info.ABI.abi.multiview_mode, info.ABI.abi.multiview_flags });
        };
    }
}

fn showInfo(label: []const u8, info: *const c.GstVideoInfo) void {
    out("  {s} {s} {d}x{d} im {d} fl {d} size {d} views {d} cs {d} col {d}:{d}:{d}:{d} par {d}/{d} fps {d}/{d} off {any} stride {any} mv {d}/{d} fo {d}", .{ label, str(info.finfo[0].name), info.width, info.height, info.interlace_mode, info.flags, info.size, info.views, info.chroma_site, info.colorimetry.range, info.colorimetry.matrix, info.colorimetry.transfer, info.colorimetry.primaries, info.par_n, info.par_d, info.fps_n, info.fps_d, info.offset, info.stride, info.ABI.abi.multiview_mode, info.ABI.abi.multiview_flags, info.ABI.abi.field_order });
}

fn showCaps(label: []const u8, caps: [*c]c.GstCaps) void {
    if (caps == null) {
        out("  {s} (null)", .{label});
        return;
    }
    const s = c.gst_caps_to_string(caps);
    out("  {s} {s}", .{ label, owned(s) });
    c.g_free(s);
}

fn infos() void {
    out("info", .{});
    const sizes = [_][2]c.guint{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 5 }, .{ 7, 3 }, .{ 16, 16 }, .{ 17, 9 }, .{ 33, 31 }, .{ 320, 240 }, .{ 720, 576 }, .{ 720, 577 }, .{ 1280, 720 }, .{ 1919, 1081 }, .{ 0, 0 } };
    var fmt: c_int = 1;
    while (fmt <= LAST) : (fmt += 1) {
        for (sizes) |sz| for ([_]c_uint{ 0, 1, 4 }) |im| {
            var info: c.GstVideoInfo = undefined;
            const ok = c.gst_video_info_set_interlaced_format(&info, @intCast(fmt), im, sz[0], sz[1]);
            var label: [64]u8 = undefined;
            showInfo(std.fmt.bufPrint(&label, "set {d}", .{ok}) catch "set", &info);
            if (ok == 0 or fmt == c.GST_VIDEO_FORMAT_ENCODED) continue;
            if (sz[0] == 17 and im == 0) {
                info.fps_n = 30000;
                info.fps_d = 1001;
                info.par_n = 4;
                info.par_d = 3;
            }
            const caps = c.gst_video_info_to_caps(&info);
            showCaps("caps", caps);
            var back: c.GstVideoInfo = undefined;
            const bok = c.gst_video_info_from_caps(&back, caps);
            out("  back {d} equal {d}", .{ bok, if (bok != 0) c.gst_video_info_is_equal(&info, &back) else 2 });
            if (bok != 0 and c.gst_video_info_is_equal(&info, &back) == 0) showInfo("back", &back);
            c.gst_caps_unref(caps);
        };
        var info: c.GstVideoInfo = undefined;
        if (fmt == c.GST_VIDEO_FORMAT_ENCODED or c.gst_video_info_set_format(&info, @intCast(fmt), 103, 37) == 0) continue;
        for ([_][4]c.guint{ .{ 0, 0, 0, 0 }, .{ 1, 2, 3, 4 }, .{ 16, 16, 16, 16 }, .{ 0, 7, 0, 9 } }) |pad| for ([_]c.guint{ 0, 3, 15, 31, 63 }) |sa| {
            var a = std.mem.zeroes(c.GstVideoAlignment);
            a.padding_top = pad[0];
            a.padding_left = pad[1];
            a.padding_right = pad[2];
            a.padding_bottom = pad[3];
            for (0..4) |k| a.stride_align[k] = sa;
            var copy = info;
            var ps: [4]c.gsize = .{ 9, 9, 9, 9 };
            const ok = c.gst_video_info_align_full(&copy, &a, &ps);
            out("  align {any} {d} -> {d} pad {d},{d},{d},{d} ps {any}", .{ pad, sa, ok, a.padding_top, a.padding_left, a.padding_right, a.padding_bottom, ps });
            showInfo("aligned", &copy);
            var copy2 = info;
            var a2 = a;
            a2.padding_left = pad[1];
            a2.padding_right = pad[2];
            _ = c.gst_video_info_align(&copy2, &a2);
        };
    }
    var h1: c.GstVideoInfo = undefined;
    var h2: c.GstVideoInfo = undefined;
    var h3: c.GstVideoInfo = undefined;
    out("  huge {d} {d} {d}", .{ c.gst_video_info_set_format(&h1, c.GST_VIDEO_FORMAT_I420, 0x80000000, 2), c.gst_video_info_set_format(&h2, c.GST_VIDEO_FORMAT_ARGB64, 65536, 65536), c.gst_video_info_set_format(&h3, c.GST_VIDEO_FORMAT_I420, 32768, 32767) });
    var tmp: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&tmp, c.GST_VIDEO_FORMAT_UNKNOWN, 2, 2);
    _ = c.gst_video_info_set_format(null, c.GST_VIDEO_FORMAT_I420, 2, 2);
    c.gst_video_info_init(null);
    const strs = [_][*c]const u8{
        "video/x-raw,format=I420,width=320,height=240,framerate=30/1",
        "video/x-raw,format=NV12,width=1920,height=1080,framerate=0/1,max-framerate=60/1",
        "video/x-raw,format=NV12,width=1920,height=1080,framerate=0/1",
        "video/x-raw,format=NV12,width=1920,height=1080",
        "video/x-raw,format=YUY2,width=640,height=480,pixel-aspect-ratio=16/15,interlace-mode=interleaved,field-order=top-field-first",
        "video/x-raw,format=YUY2,width=640,height=480,interlace-mode=progressive,field-order=top-field-first",
        "video/x-raw,format=YUY2,width=640,height=480,interlace-mode=mixed,field-order=bottom-field-first",
        "video/x-raw,format=YUY2,width=640,height=480,interlace-mode=bogus",
        "video/x-raw,format=I420,width=640,height=480,interlace-mode=alternate",
        "video/x-raw(format:Interlaced),format=I420,width=640,height=480,interlace-mode=alternate,field-order=top-field-first",
        "video/x-raw,format=I420,width=640,height=480,colorimetry=bt709",
        "video/x-raw,format=I420,width=640,height=480,colorimetry=sRGB",
        "video/x-raw,format=I420,width=640,height=480,colorimetry=1:0:5:1",
        "video/x-raw,format=I420,width=640,height=480,colorimetry=bogus",
        "video/x-raw,format=RGBA,width=640,height=480,colorimetry=bt709",
        "video/x-raw,format=RGBA,width=640,height=480,colorimetry=sRGB",
        "video/x-raw,format=GRAY8,width=640,height=480,colorimetry=sRGB",
        "video/x-raw,format=I420,width=640,height=480,chroma-site=jpeg",
        "video/x-raw,format=I420,width=640,height=480,chroma-site=none+h-cosited",
        "video/x-raw,format=I420,width=640,height=480,chroma-site=unknown",
        "video/x-raw,format=I420,width=640,height=480,chroma-site=bogus",
        "video/x-raw,format=RGBA,width=640,height=480,chroma-site=mpeg2",
        "video/x-raw,format=I420,width=640,height=480,views=2,multiview-mode=side-by-side,multiview-flags=0x4000:0xffffffff",
        "video/x-raw,format=I420,width=1280,height=480,views=2,multiview-mode=top-bottom,multiview-flags=0x4001:0xffffffff",
        "video/x-raw,format=I420,width=640,height=480,multiview-mode=mono",
        "video/x-raw,format=I420,width=640,height=480,multiview-mode=nonsense",
        "video/x-raw,format=BOGUS,width=640,height=480",
        "video/x-raw,width=640,height=480",
        "video/x-raw,format=I420,height=480",
        "video/x-raw,format=I420,width=640",
        "video/x-h264,width=640,height=480,framerate=25/1",
        "video/x-h264",
        "image/jpeg,width=10",
        "audio/x-raw,rate=44100",
        "video/x-raw,format=I420,width=[1,100],height=480",
        "video/x-raw,format=I420,width=700,height=577",
    };
    for (strs) |s| {
        const caps = c.gst_caps_from_string(s);
        var info: c.GstVideoInfo = undefined;
        @memset(std.mem.asBytes(&info), 0x55);
        const ok = c.gst_video_info_from_caps(&info, caps);
        out(" from_caps {s} -> {d}", .{ str(s), ok });
        if (ok != 0) {
            showInfo("got", &info);
            const back = c.gst_video_info_to_caps(&info);
            showCaps("to", back);
            if (back != null) c.gst_caps_unref(back);
            const n = c.gst_video_info_new_from_caps(caps);
            out("  new {d}", .{c.gst_video_info_is_equal(n, &info)});
            const cp = c.gst_video_info_copy(n);
            out("  copy {d}", .{c.gst_video_info_is_equal(n, cp)});
            c.gst_video_info_free(cp);
            c.gst_video_info_free(n);
            for ([_]c.GstFormat{ c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_TIME, c.GST_FORMAT_BUFFERS }) |sf| for ([_]c.GstFormat{ c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_TIME, c.GST_FORMAT_PERCENT }) |df| for ([_]i64{ 0, 1, -1, 123456789, 3 * c.GST_SECOND }) |v| {
                var dv: i64 = 77;
                const r = c.gst_video_info_convert(&info, sf, v, df, &dv);
                out("   conv {d} {d} {d} -> {d} {d}", .{ sf, df, v, r, dv });
            };
        } else {
            out("  untouched {d}", .{info.width});
            out("  new null {any}", .{c.gst_video_info_new_from_caps(caps) == null});
        }
        if (caps != null) c.gst_caps_unref(caps);
    }
    const nf = c.gst_caps_from_string("video/x-raw,format={I420,NV12},width=2,height=2");
    var info: c.GstVideoInfo = undefined;
    out(" not fixed {d}", .{c.gst_video_info_from_caps(&info, nf)});
    c.gst_caps_unref(nf);
    _ = c.gst_video_info_from_caps(null, nf);
    _ = c.gst_video_info_from_caps(&info, null);
    _ = c.gst_video_info_to_caps(null);
    c.gst_video_info_init(&info);
    showInfo("init", &info);
    showCaps("unknown to_caps", c.gst_video_info_to_caps(&info));
    var dv: i64 = 0;
    _ = c.gst_video_info_convert(&info, c.GST_FORMAT_BYTES, 1, c.GST_FORMAT_TIME, &dv);
    _ = c.gst_video_info_set_format(&info, c.GST_VIDEO_FORMAT_I420, 4, 4);
    info.fps_n = 0;
    info.fps_d = 0;
    for ([_]c.GstFormat{ c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_TIME }) |sf| for ([_]c.GstFormat{ c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_TIME }) |df| {
        var d: i64 = 77;
        const r = c.gst_video_info_convert(&info, sf, 1000, df, &d);
        out("  zero conv {d} {d} -> {d} {d}", .{ sf, df, r, d });
    };
    info.size = 0;
    _ = c.gst_video_info_convert(&info, c.GST_FORMAT_BYTES, 1, c.GST_FORMAT_TIME, &dv);
    var m: c_int = -1;
    while (m < 7) : (m += 1) out("  imode {d} {s} back {d} order {s}", .{ m, str(c.gst_video_interlace_mode_to_string(@bitCast(m))), if (c.gst_video_interlace_mode_to_string(@bitCast(m)) != null) @as(c_int, @bitCast(c.gst_video_interlace_mode_from_string(c.gst_video_interlace_mode_to_string(@bitCast(m))))) else -1, str(c.gst_video_field_order_to_string(@bitCast(m))) });
    out("  imode bogus {d} order bogus {d} {d}", .{ c.gst_video_interlace_mode_from_string("x"), c.gst_video_field_order_from_string("x"), c.gst_video_field_order_from_string("bottom-field-first") });
    out("  type {s}", .{str(c.g_type_name(c.gst_video_info_get_type()))});
}

pub fn main() void {
    c.gst_init(null, null);
    colors();
    chromas();
    multiviews();
    infos();
}
