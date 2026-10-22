const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const N: ?*anyopaque = null;

fn fcc(k: [4]u8) u32 {
    return std.mem.readInt(u32, &k, .little);
}

const vids = [_]u32{
    fcc(.{ 'G', 'R', 'E', 'Y' }),
    fcc(.{ 'Y', '8', '0', '0' }),
    fcc(.{ 'Y', '8', ' ', ' ' }),
    fcc(.{ 'r', '2', '1', '0' }),
    c.GST_RIFF_I420,
    c.GST_RIFF_i420,
    c.GST_RIFF_IYUV,
    c.GST_RIFF_YUY2,
    c.GST_RIFF_yuy2,
    fcc(.{ 'Y', 'U', 'N', 'V' }),
    fcc(.{ 'Y', 'U', 'Y', 'V' }),
    c.GST_RIFF_YVU9,
    fcc(.{ 'U', 'Y', 'V', 'Y' }),
    fcc(.{ '2', 'v', 'u', 'y' }),
    fcc(.{ 'H', 'D', 'Y', 'C' }),
    c.GST_RIFF_YV12,
    c.GST_RIFF_yv12,
    fcc(.{ 'v', '2', '1', '0' }),
    c.GST_RIFF_MJPG,
    c.GST_RIFF_mJPG,
    fcc(.{ 'A', 'V', 'R', 'n' }),
    c.GST_RIFF_IJPG,
    fcc(.{ 'i', 'j', 'p', 'g' }),
    c.GST_RIFF_DMB1,
    c.GST_RIFF_dmb1,
    fcc(.{ 'A', 'C', 'D', 'V' }),
    fcc(.{ 'Q', 'I', 'V', 'G' }),
    c.GST_RIFF_JPEG,
    c.GST_RIFF_jpeg,
    fcc(.{ 'j', 'p', 'e', 'g' }),
    fcc(.{ 'P', 'I', 'X', 'L' }),
    c.GST_RIFF_VIXL,
    c.GST_RIFF_vixl,
    fcc(.{ 'C', 'J', 'P', 'G' }),
    fcc(.{ 'S', 'L', 'M', 'J' }),
    fcc(.{ 'J', 'P', 'G', 'L' }),
    fcc(.{ 'L', 'O', 'C', 'O' }),
    fcc(.{ 'S', 'P', '5', '3' }),
    fcc(.{ 'S', 'P', '5', '4' }),
    fcc(.{ 'S', 'P', '5', '5' }),
    fcc(.{ 'S', 'P', '5', '6' }),
    fcc(.{ 'S', 'P', '5', '7' }),
    fcc(.{ 'S', 'P', '5', '8' }),
    fcc(.{ 'Z', 'M', 'B', 'V' }),
    fcc(.{ 'M', 'P', 'E', 'G' }),
    fcc(.{ 'M', 'P', 'G', 'I' }),
    fcc(.{ 'm', 'p', 'g', '1' }),
    fcc(.{ 'M', 'P', 'G', '1' }),
    fcc(.{ 'P', 'I', 'M', '1' }),
    fcc(.{ 1, 0, 0, 16 }),
    fcc(.{ 'M', 'P', 'G', '2' }),
    fcc(.{ 'm', 'p', 'g', '2' }),
    fcc(.{ 'P', 'I', 'M', '2' }),
    fcc(.{ 'D', 'V', 'R', ' ' }),
    fcc(.{ 2, 0, 0, 16 }),
    fcc(.{ 'L', 'M', 'P', '2' }),
    c.GST_RIFF_H263,
    c.GST_RIFF_h263,
    c.GST_RIFF_i263,
    fcc(.{ 'U', '2', '6', '3' }),
    fcc(.{ 'v', 'i', 'v', '1' }),
    fcc(.{ 'T', '2', '6', '3' }),
    c.GST_RIFF_L263,
    c.GST_RIFF_M263,
    c.GST_RIFF_m263,
    c.GST_RIFF_VDOW,
    fcc(.{ 'V', 'I', 'V', 'O' }),
    c.GST_RIFF_x263,
    fcc(.{ 'I', '2', '6', '3' }),
    fcc(.{ 'V', 'X', '1', 'K' }),
    fcc(.{ 'X', '2', '6', '4' }),
    fcc(.{ 'x', '2', '6', '4' }),
    fcc(.{ 'H', '2', '6', '4' }),
    fcc(.{ 'h', '2', '6', '4' }),
    fcc(.{ 'a', 'v', 'c', '1' }),
    fcc(.{ 'A', 'V', 'C', '1' }),
    fcc(.{ 'X', '2', '6', '5' }),
    fcc(.{ 'x', '2', '6', '5' }),
    fcc(.{ 'H', '2', '6', '5' }),
    fcc(.{ 'h', '2', '6', '5' }),
    fcc(.{ 'h', 'v', 'c', '1' }),
    fcc(.{ 'H', 'V', 'C', '1' }),
    fcc(.{ 'h', 'e', 'v', 'c' }),
    fcc(.{ 'H', 'E', 'V', 'C' }),
    fcc(.{ 'h', 'e', 'v', '1' }),
    fcc(.{ 'H', 'E', 'V', '1' }),
    c.GST_RIFF_VSSH,
    fcc(.{ 'L', '2', '6', '4' }),
    fcc(.{ 'S', 'E', 'D', 'G' }),
    fcc(.{ 'M', '4', 'C', 'C' }),
    c.GST_RIFF_DIV3,
    fcc(.{ 'd', 'i', 'v', '3' }),
    fcc(.{ 'D', 'V', 'X', '3' }),
    fcc(.{ 'd', 'v', 'x', '3' }),
    fcc(.{ 'D', 'I', 'V', '4' }),
    fcc(.{ 'd', 'i', 'v', '4' }),
    fcc(.{ 'D', 'I', 'V', '5' }),
    fcc(.{ 'd', 'i', 'v', '5' }),
    fcc(.{ 'D', 'I', 'V', '6' }),
    fcc(.{ 'd', 'i', 'v', '6' }),
    fcc(.{ 'M', 'P', 'G', '3' }),
    fcc(.{ 'm', 'p', 'g', '3' }),
    fcc(.{ 'c', 'o', 'l', '0' }),
    fcc(.{ 'C', 'O', 'L', '0' }),
    fcc(.{ 'c', 'o', 'l', '1' }),
    fcc(.{ 'C', 'O', 'L', '1' }),
    fcc(.{ 'A', 'P', '4', '1' }),
    fcc(.{ 'd', 'i', 'v', 'x' }),
    fcc(.{ 'D', 'I', 'V', 'X' }),
    fcc(.{ 'B', 'L', 'Z', '0' }),
    fcc(.{ 'D', 'X', '5', '0' }),
    fcc(.{ 'M', 'P', 'G', '4' }),
    fcc(.{ 'M', 'P', '4', '1' }),
    fcc(.{ 'm', 'p', '4', '1' }),
    fcc(.{ 'm', 'p', '4', '2' }),
    fcc(.{ 'M', 'P', '4', '2' }),
    fcc(.{ 'm', 'p', '4', '3' }),
    fcc(.{ 'M', 'P', '4', '3' }),
    fcc(.{ 'M', 'P', '4', 'S' }),
    fcc(.{ 'M', '4', 'S', '2' }),
    fcc(.{ 'F', 'M', 'P', '4' }),
    fcc(.{ 'U', 'M', 'P', '4' }),
    fcc(.{ 'F', 'F', 'D', 'S' }),
    fcc(.{ '3', 'I', 'V', '1' }),
    fcc(.{ '3', 'I', 'V', '2' }),
    fcc(.{ 'X', 'V', 'I', 'D' }),
    fcc(.{ 'x', 'v', 'i', 'd' }),
    fcc(.{ 'E', 'M', '4', 'A' }),
    fcc(.{ 'E', 'P', 'V', 'H' }),
    fcc(.{ 'F', 'V', 'F', 'W' }),
    fcc(.{ 'I', 'N', 'M', 'C' }),
    fcc(.{ 'D', 'I', 'G', 'I' }),
    fcc(.{ 'D', 'M', '2', 'K' }),
    fcc(.{ 'D', 'C', 'O', 'D' }),
    fcc(.{ 'M', 'V', 'X', 'M' }),
    fcc(.{ 'P', 'M', '4', 'V' }),
    fcc(.{ 'S', 'M', 'P', '4' }),
    fcc(.{ 'D', 'X', 'G', 'M' }),
    fcc(.{ 'V', 'I', 'D', 'M' }),
    fcc(.{ 'M', '4', 'T', '3' }),
    fcc(.{ 'G', 'E', 'O', 'X' }),
    fcc(.{ 'M', 'P', '4', 'V' }),
    fcc(.{ 'm', 'p', '4', 'v' }),
    fcc(.{ 'R', 'M', 'P', '4' }),
    fcc(.{ '3', 'i', 'v', 'd' }),
    fcc(.{ '3', 'I', 'V', 'D' }),
    fcc(.{ 'C', 'F', 'H', 'D' }),
    fcc(.{ 'D', 'V', 'S', 'D' }),
    fcc(.{ 'd', 'v', 's', 'd' }),
    fcc(.{ 'd', 'v', 'c', ' ' }),
    fcc(.{ 'd', 'v', '2', '5' }),
    fcc(.{ 'C', 'D', 'V', 'C' }),
    fcc(.{ 'c', 'd', 'v', 'c' }),
    fcc(.{ 'D', 'V', '5', '0' }),
    fcc(.{ 'd', 'v', '5', '0' }),
    fcc(.{ 'M', 'S', 'S', '1' }),
    fcc(.{ 'M', 'S', 'S', '2' }),
    fcc(.{ 'W', 'M', 'V', '1' }),
    fcc(.{ 'W', 'M', 'V', '2' }),
    fcc(.{ 'W', 'M', 'V', '3' }),
    fcc(.{ 'W', 'M', 'V', 'A' }),
    fcc(.{ 'W', 'V', 'C', '1' }),
    c.GST_RIFF_cvid,
    c.GST_RIFF_CVID,
    fcc(.{ 'A', 'A', 'S', 'C' }),
    fcc(.{ 'X', 'x', 'a', 'n' }),
    c.GST_RIFF_RT21,
    c.GST_RIFF_rt21,
    c.GST_RIFF_IV31,
    c.GST_RIFF_IV32,
    c.GST_RIFF_iv31,
    c.GST_RIFF_iv32,
    c.GST_RIFF_IV41,
    c.GST_RIFF_iv41,
    c.GST_RIFF_IV50,
    fcc(.{ 'M', 'S', 'Z', 'H' }),
    fcc(.{ 'Z', 'L', 'I', 'B' }),
    fcc(.{ 'C', 'L', 'J', 'R' }),
    fcc(.{ 'c', 'l', 'j', 'r' }),
    c.GST_RIFF_CYUV,
    c.GST_RIFF_cyuv,
    fcc(.{ 'D', 'U', 'C', 'K' }),
    fcc(.{ 'P', 'V', 'E', 'Z' }),
    fcc(.{ 'T', 'M', '2', '0' }),
    fcc(.{ 'V', 'P', '3', '0' }),
    fcc(.{ 'v', 'p', '3', '0' }),
    fcc(.{ 'V', 'P', '3', '1' }),
    fcc(.{ 'v', 'p', '3', '1' }),
    fcc(.{ 'V', 'P', '3', ' ' }),
    c.GST_RIFF_ULTI,
    c.GST_RIFF_ulti,
    fcc(.{ 'T', 'S', 'C', '2' }),
    fcc(.{ 't', 's', 'c', '2' }),
    fcc(.{ 'V', 'C', 'R', '1' }),
    fcc(.{ 'V', 'C', 'R', '2' }),
    fcc(.{ 'A', 'S', 'V', '1' }),
    fcc(.{ 'A', 'S', 'V', '2' }),
    fcc(.{ 'M', 'P', 'N', 'G' }),
    fcc(.{ 'm', 'p', 'n', 'g' }),
    fcc(.{ 'P', 'N', 'G', ' ' }),
    fcc(.{ 'p', 'n', 'g', ' ' }),
    fcc(.{ 'F', 'L', 'V', '1' }),
    fcc(.{ 'd', 'r', 'a', 'c' }),
    c.GST_RIFF_rpza,
    c.GST_RIFF_azpr,
    fcc(.{ 'R', 'P', 'Z', 'A' }),
    fcc(.{ 'F', 'F', 'V', '1' }),
    fcc(.{ 'K', 'M', 'V', 'C' }),
    fcc(.{ 'v', 'p', '5', '0' }),
    fcc(.{ 'V', 'P', '5', '0' }),
    fcc(.{ 'v', 'p', '6', '0' }),
    fcc(.{ 'V', 'P', '6', '0' }),
    fcc(.{ 'v', 'p', '6', '1' }),
    fcc(.{ 'V', 'P', '6', '1' }),
    fcc(.{ 'V', 'p', '6', '2' }),
    fcc(.{ 'V', 'P', '6', '2' }),
    fcc(.{ 'V', 'P', '6', 'F' }),
    fcc(.{ 'v', 'p', '6', 'f' }),
    fcc(.{ 'F', 'L', 'V', '4' }),
    fcc(.{ 'v', 'p', '7', '0' }),
    fcc(.{ 'V', 'P', '7', '0' }),
    fcc(.{ 'V', 'P', '8', '0' }),
    fcc(.{ 'L', 'M', '2', '0' }),
    fcc(.{ 'T', 'H', 'E', 'O' }),
    fcc(.{ 't', 'h', 'e', 'o' }),
    fcc(.{ 'F', 'P', 'S', '1' }),
    fcc(.{ 'D', 'X', 'S', 'B' }),
    fcc(.{ 'D', 'X', 'S', 'A' }),
    fcc(.{ 'L', 'A', 'G', 'S' }),
    fcc(.{ 'M', '1', '0', '1' }),
    fcc(.{ 'M', '1', '0', '2' }),
    c.GST_RIFF_DIB,
    c.GST_RIFF_rgb,
    c.GST_RIFF_RGB,
    c.GST_RIFF_RAW,
    fcc(.{ 'H', 'F', 'Y', 'U' }),
    fcc(.{ 'F', 'F', 'V', 'H' }),
    c.GST_RIFF_FCCH_MSVC,
    c.GST_RIFF_FCCH_msvc,
    c.GST_RIFF_CRAM,
    c.GST_RIFF_cram,
    c.GST_RIFF_WHAM,
    c.GST_RIFF_wham,
    c.GST_RIFF_FCCH_RLE,
    fcc(.{ 'm', 'r', 'l', 'e' }),
    fcc(.{ 1, 0, 0, 0 }),
    fcc(.{ 2, 0, 0, 0 }),
    fcc(.{ 'T', 'S', 'C', 'C' }),
    fcc(.{ 't', 's', 'c', 'c' }),
    fcc(.{ 'C', 'S', 'C', 'D' }),
    fcc(.{ 'V', 'M', 'n', 'c' }),
    fcc(.{ 'Q', 'Q', 'Q', 'Q' }),
    0,
};

fn capsOut(tag: []const u8, caps: [*c]c.GstCaps, name: [*c]u8) void {
    if (caps == null) {
        out("{s} null name {s}", .{ tag, z(name) });
    } else {
        const s = c.gst_caps_to_string(caps);
        out("{s} {s} name {s}", .{ tag, z(s), z(name) });
        c.g_free(s);
        c.gst_caps_unref(caps);
    }
    c.g_free(name);
}

fn bytes(d: []const u8) [*c]c.GstBuffer {
    return c.gst_buffer_new_memdup(d.ptr, d.len);
}

fn video() void {
    var strh = std.mem.zeroes(c.gst_riff_strh);
    strh.rate = 30000;
    strh.scale = 1001;
    var strf = std.mem.zeroes(c.gst_riff_strf_vids);
    strf.width = 320;
    strf.height = @bitCast(@as(i32, -240));
    for (vids) |v| {
        var name: [*c]u8 = null;
        capsOut("v0", c.gst_riff_create_video_caps(v, null, null, null, null, &name), name);
        for ([_]u16{ 0, 8, 16, 24, 32 }) |bpp| {
            strf.bit_cnt = bpp;
            strf.num_colors = if (bpp == 8) 4 else 0;
            name = null;
            const pal = bytes(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
            const strd = bytes("strd");
            capsOut("v1", c.gst_riff_create_video_caps(v, &strh, &strf, pal, strd, &name), name);
            c.gst_buffer_unref(pal);
            c.gst_buffer_unref(strd);
        }
        capsOut("v2", c.gst_riff_create_video_caps(v, &strh, null, null, null, null), null);
    }
    var name: [*c]u8 = null;
    capsOut("iavs", c.gst_riff_create_iavs_caps(fcc("DVSD".*), null, null, null, null, &name), name);
    capsOut("iavs", c.gst_riff_create_iavs_caps(fcc("XXXX".*), null, null, null, null, null), null);
    capsOut("vt", c.gst_riff_create_video_template_caps(), null);
    capsOut("at", c.gst_riff_create_audio_template_caps(), null);
    capsOut("it", c.gst_riff_create_iavs_template_caps(), null);
}

fn audio() void {
    var map: [18]c.gint = undefined;
    var code: u32 = 0;
    while (code < 0x10000) : (code += 1) {
        var name: [*c]u8 = null;
        const caps = c.gst_riff_create_audio_caps(@intCast(code), null, null, null, null, &name, &map);
        if (caps == null and name == null) continue;
        var buf: [16]u8 = undefined;
        capsOut(std.fmt.bufPrint(&buf, "a{x}", .{code}) catch unreachable, caps, name);
        for ([_]u16{ 1, 2, 6, 9 }) |ch| for ([_]u16{ 0, 8, 16, 24, 33 }) |bits| for ([_]u16{ 0, 2, 3, 4, 6, 12, 36, 512 }) |ba| {
            var strf = std.mem.zeroes(c.gst_riff_strf_auds);
            strf.format = @intCast(code);
            strf.channels = ch;
            strf.rate = 44100;
            strf.av_bps = if (ba == 3) 3000 else 0;
            strf.blockalign = ba;
            strf.bits_per_sample = bits;
            name = null;
            @memset(&map, 99);
            const cd = bytes("cdata");
            const caps2 = c.gst_riff_create_audio_caps(@intCast(code), null, &strf, cd, null, &name, &map);
            c.gst_buffer_unref(cd);
            var b2: [96]u8 = undefined;
            capsOut(std.fmt.bufPrint(&b2, "a{x} ch{d} b{d} ba{d} -> av{d} ba{d} bits{d} map {any}", .{ code, ch, bits, ba, strf.av_bps, strf.blockalign, strf.bits_per_sample, map[0..ch] }) catch unreachable, caps2, name);
        };
    }
}

fn ext(guid0: u32, mask: u32, ch: u16, ba: u16, bits: u16) void {
    var d: [22]u8 = undefined;
    std.mem.writeInt(u16, d[0..2], bits, .little);
    std.mem.writeInt(u32, d[2..6], mask, .little);
    std.mem.writeInt(u32, d[6..10], guid0, .little);
    std.mem.writeInt(u32, d[10..14], 0x00100000, .little);
    std.mem.writeInt(u32, d[14..18], 0xaa000080, .little);
    std.mem.writeInt(u32, d[18..22], 0x719b3800, .little);
    var strf = std.mem.zeroes(c.gst_riff_strf_auds);
    strf.format = 0xfffe;
    strf.channels = ch;
    strf.rate = 48000;
    strf.blockalign = ba;
    strf.bits_per_sample = bits;
    var map: [18]c.gint = undefined;
    @memset(&map, 99);
    var name: [*c]u8 = null;
    const b = bytes(&d);
    const caps = c.gst_riff_create_audio_caps(0xfffe, null, &strf, b, null, &name, &map);
    c.gst_buffer_unref(b);
    var buf: [128]u8 = undefined;
    capsOut(std.fmt.bufPrint(&buf, "ext {x} mask {x} ch {d} -> ba{d} av{d} map {any}", .{ guid0, mask, ch, strf.blockalign, strf.av_bps, map[0..ch] }) catch unreachable, caps, name);
}

fn exts() void {
    for ([_]u32{ 1, 3, 6, 7, 0x92, 0xfffe, 0x55, 0x2000, 0x161, 0x9999 }) |g| for ([_]u32{ 0, 0x3, 0x3f, 0x63f, 0xffffff, 0x1 }) |m| for ([_]u16{ 1, 2, 6, 8 }) |ch| {
        ext(g, m, ch, ch * 2, 16);
        ext(g, m, ch, ch * 4, 32);
    };
    var d: [22]u8 = undefined;
    for (&d, 0..) |*x, i| x.* = @intCast(i);
    std.mem.writeInt(u32, d[6..10], 0x6ba47966, .little);
    std.mem.writeInt(u32, d[10..14], 0x41783f83, .little);
    std.mem.writeInt(u32, d[14..18], 0xf0006596, .little);
    std.mem.writeInt(u32, d[18..22], 0xe59262bf, .little);
    const b = bytes(&d);
    var name: [*c]u8 = null;
    capsOut("oggavi", c.gst_riff_create_audio_caps(0xfffe, null, null, b, null, &name, null), name);
    const small = bytes("short");
    capsOut("short", c.gst_riff_create_audio_caps(0xfffe, null, null, small, null, null, null), null);
    c.gst_buffer_unref(small);
    c.gst_buffer_unref(b);
    capsOut("nodata", c.gst_riff_create_audio_caps(0xfffe, null, null, null, null, null, null), null);
}

fn headers() void {
    const el = c.gst_element_factory_make("fakesink", "riffsink");
    const bus = c.gst_bus_new();
    c.gst_element_set_bus(el, bus);
    for ([_][]const u8{ "RIFF\x10\x00\x00\x00AVI ", "RF64....WAVE", "AVF0....AMV ", "JUNK....xxxx", "RIFF" }) |h| {
        var doc: c_uint = 0;
        const r = c.gst_riff_parse_file_header(el, bytes(h), &doc);
        out("header {d} {x}", .{ r, doc });
        const m = c.gst_bus_pop(bus);
        if (m != null) {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &e, &dbg);
            out("  error {d} {s} [{s}]", .{ e.*.code, z(e.*.message), z(dbg) });
            c.g_error_free(e);
            c.g_free(dbg);
            c.gst_message_unref(m);
        }
    }
    var data: [200]u8 = undefined;
    for (&data, 0..) |*x, i| x.* = @truncate(i * 7 + 3);
    for ([_]usize{ 10, 56, 57, 120 }) |n| {
        var strh: [*c]c.gst_riff_strh = null;
        const r = c.gst_riff_parse_strh(el, bytes(data[0..n]), &strh);
        if (r != 0) out("strh {d} type {x} rate {d} scale {d} len {d}", .{ n, strh[0].type, strh[0].rate, strh[0].scale, strh[0].length }) else out("strh {d} fail", .{n});
        c.g_free(strh);
        var vs: [*c]c.gst_riff_strf_vids = null;
        var vd: [*c]c.GstBuffer = null;
        if (c.gst_riff_parse_strf_vids(el, bytes(data[0..n]), &vs, &vd) != 0) {
            out("vids {d} size {d} w {d} h {d} bpp {d} extra {d}", .{ n, vs[0].size, vs[0].width, vs[0].height, vs[0].bit_cnt, if (vd != null) c.gst_buffer_get_size(vd) else 0 });
            if (vd != null) c.gst_buffer_unref(vd);
            c.g_free(vs);
        } else out("vids {d} fail", .{n});
        var auds: [*c]c.gst_riff_strf_auds = null;
        var ad: [*c]c.GstBuffer = null;
        if (c.gst_riff_parse_strf_auds(el, bytes(data[0..n]), &auds, &ad) != 0) {
            out("auds {d} fmt {x} ch {d} rate {d} extra {d}", .{ n, auds[0].format, auds[0].channels, auds[0].rate, if (ad != null) c.gst_buffer_get_size(ad) else 0 });
            if (ad != null) c.gst_buffer_unref(ad);
            c.g_free(auds);
        } else out("auds {d} fail", .{n});
        var iavs: [*c]c.gst_riff_strf_iavs = null;
        var id: [*c]c.GstBuffer = null;
        if (c.gst_riff_parse_strf_iavs(el, bytes(data[0..n]), &iavs, &id) != 0) {
            out("iavs {d} src {x}", .{ n, iavs[0].DVAAuxSrc });
            c.g_free(iavs);
        } else out("iavs {d} fail", .{n});
    }
    var aext = [_]u8{0} ** 40;
    aext[16] = 30;
    var auds: [*c]c.gst_riff_strf_auds = null;
    var ad: [*c]c.GstBuffer = null;
    _ = c.gst_riff_parse_strf_auds(el, bytes(&aext), &auds, &ad);
    out("auds clip extra {d}", .{if (ad != null) c.gst_buffer_get_size(ad) else 0});
    if (ad != null) c.gst_buffer_unref(ad);
    c.g_free(auds);
    const chunks = "LIST\x04\x00\x00\x00abcdJUNK\x03\x00\x00\x00xyz\x00data\x09\x00\x00\x00123456789\x00tail\xff\x00\x00\x00zz";
    const cb = bytes(chunks);
    var off: c_uint = 0;
    while (true) {
        var tag: c_uint = 0;
        var cd: [*c]c.GstBuffer = null;
        const ok = c.gst_riff_parse_chunk(el, cb, &off, &tag, &cd);
        out("chunk {d} off {d} tag {x} size {d}", .{ ok, off, tag, if (cd != null) c.gst_buffer_get_size(cd) else 0 });
        if (cd != null) c.gst_buffer_unref(cd);
        if (ok == 0) break;
    }
    c.gst_buffer_unref(cb);
    const info = "INAM\x06\x00\x00\x00Title\x00IART\x05\x00\x00\x00Artx\x00\x00ICRD\x0a\x00\x00\x002020-01-02ITRK\x02\x00\x00\x007\x00inam\x03\x00\x00\x00low\x00ICMS\x02\x00\x00\x00zz\x00\x00ISFT\x00\x00\x00\x00ICMT\x40\x00\x00\x00short";
    var tags: ?*c.GstTagList = null;
    const ib = bytes(info);
    c.gst_riff_parse_info(el, ib, &tags);
    if (tags) |t| {
        const s = c.gst_tag_list_to_string(t);
        out("info {s}", .{z(s)});
        c.g_free(s);
        c.gst_tag_list_unref(t);
    } else out("info none", .{});
    c.gst_buffer_unref(ib);
    c.gst_riff_parse_info(el, null, &tags);
    out("info null {d}", .{@intFromBool(tags == null)});
    _ = c.gst_element_set_state(el, c.GST_STATE_NULL);
    c.gst_object_unref(el);
    c.gst_object_unref(bus);
}

var src_data: []const u8 = "";

fn getrange(_: ?*c.GstPad, _: [*c]c.GstObject, off: u64, len: c.guint, out_b: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    if (off >= src_data.len) return c.GST_FLOW_EOS;
    const end = @min(src_data.len, off + len);
    out_b.* = bytes(src_data[@intCast(off)..@intCast(end)]);
    return c.GST_FLOW_OK;
}

fn pulls() void {
    const el = c.gst_element_factory_make("identity", "pullel");
    const src = c.gst_pad_new("src", c.GST_PAD_SRC);
    c.gst_pad_set_getrange_function_full(src, getrange, null, null);
    const sink = c.gst_pad_new("sink", c.GST_PAD_SINK);
    _ = c.gst_pad_link(src, sink);
    _ = c.gst_pad_activate_mode(sink, c.GST_PAD_MODE_PULL, 1);
    src_data = "JUNK\x03\x00\x00\x00abc\x00LIST\x05\x00\x00\x00hello\x00data\x04\x00\x00\x00wxyzJUNQ\x00\x00\x00\x00big \x40\x00\x00\x00short";
    var off: u64 = 0;
    while (true) {
        var tag: c_uint = 0;
        var b: [*c]c.GstBuffer = null;
        const r = c.gst_riff_read_chunk(el, sink, &off, &tag, &b);
        out("read {d} off {d} tag {x} size {d}", .{ r, off, tag, if (b != null) c.gst_buffer_get_size(b) else 0 });
        if (b != null) c.gst_buffer_unref(b);
        if (r != c.GST_FLOW_OK) break;
    }
    _ = c.gst_pad_activate_mode(sink, c.GST_PAD_MODE_PULL, 0);
    c.gst_object_unref(src);
    c.gst_object_unref(sink);
    c.gst_object_unref(el);
}

pub fn main() void {
    c.gst_init(null, null);
    c.gst_riff_init();
    video();
    audio();
    exts();
    headers();
    pulls();
}
