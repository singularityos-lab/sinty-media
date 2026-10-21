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

const NONE = @as(?*anyopaque, null);

fn showCaps(label: []const u8, caps: [*c]const c.GstCaps) void {
    if (caps == null) {
        out("  {s} (null)", .{label});
        return;
    }
    const s = c.gst_caps_to_string(caps);
    out("  {s} {s}", .{ label, str(s) });
    c.g_free(s);
}

fn iec() void {
    out("iec61937", .{});
    const cases = [_]struct { c.GstAudioRingBufferFormatType, [*:0]const u8, c_int }{
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_AC3, "audio/x-ac3", 48000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_EAC3, "audio/x-eac3,alignment=frame", 48000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_EAC3, "audio/x-eac3,alignment=iec61937", 48000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DTS, "audio/x-dts,frame-size=1000,block-size=512", 48000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DTS, "audio/x-dts,frame-size=3000,block-size=512", 48000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DTS, "audio/x-dts,frame-size=100,block-size=2048", 48000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG, "audio/mpeg,mpegaudioversion=1,layer=1,channels=2", 44100 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG, "audio/mpeg,mpegaudioversion=1,layer=3,channels=2", 44100 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG, "audio/mpeg,mpegaudioversion=2,layer=1,channels=1", 8000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG, "audio/mpeg,mpegaudioversion=2,layer=2,channels=1", 8000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG, "audio/mpeg,mpegaudioversion=2,layer=3,channels=1", 8000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG, "audio/mpeg,mpegaudioversion=2,layer=3,channels=1", 22050 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG, "audio/mpeg,mpegaudioversion=3,layer=3,channels=1", 22050 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG, "audio/mpeg,mpegaudioversion=1,layer=3,channels=6", 22050 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG2_AAC, "audio/mpeg", 48000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG4_AAC, "audio/mpeg", 48000 },
        .{ c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_RAW, "audio/x-raw", 48000 },
    };
    var src: [600]u8 = undefined;
    for (&src, 0..) |*x, i| x.* = @truncate(i *% 13 +% 7);
    for (cases) |k| {
        var spec = std.mem.zeroes(c.GstAudioRingBufferSpec);
        spec.type = k[0];
        spec.caps = c.gst_caps_from_string(k[1]);
        spec.info.rate = k[2];
        const fs = c.gst_audio_iec61937_frame_size(&spec);
        out("  {s} rate={d} frame={d}", .{ k[1], k[2], fs });
        for ([_]c.guint{ 9, 13, 600 }) |sn| for ([_]c_int{ c.G_LITTLE_ENDIAN, c.G_BIG_ENDIAN }) |e| {
            const dn: c.guint = @max(fs, 640);
            const dst: [*c]u8 = @ptrCast(c.g_malloc(dn));
            @memset(dst[0..dn], 0xcc);
            const r = c.gst_audio_iec61937_payload(&src, sn, dst, dn, &spec, e);
            var sum: u32 = 0;
            for (dst[0..dn]) |b| sum = sum *% 31 +% b;
            out("    payload n={d} e={d} -> {d} head={x} sum={x}", .{ sn, e, r, dst[0..12], sum });
            c.g_free(dst);
        };
        var small: [16]u8 = undefined;
        _ = c.gst_audio_iec61937_payload(&src, 9, &small, 16, &spec, c.G_LITTLE_ENDIAN);
        c.gst_caps_unref(spec.caps);
    }
    var spec = std.mem.zeroes(c.GstAudioRingBufferSpec);
    spec.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_AC3;
    spec.caps = c.gst_caps_from_string("audio/x-ac3");
    var src2 = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    var dst2: [8000]u8 = undefined;
    out("  ac3 short {d}", .{c.gst_audio_iec61937_payload(&src2, 5, &dst2, 8000, &spec, c.G_LITTLE_ENDIAN)});
    out("  same buf {d}", .{c.gst_audio_iec61937_payload(&dst2, 5, &dst2, 8000, &spec, c.G_LITTLE_ENDIAN)});
    for ([_]u8{ 0, 1, 2, 3 }) |b| {
        spec.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG4_AAC;
        src2[6] = b;
        out("  aac blks {d} -> {d} {x}", .{ b, c.gst_audio_iec61937_payload(&src2, 7, &dst2, 8000, &spec, c.G_LITTLE_ENDIAN), dst2[0..8] });
    }
    c.gst_caps_unref(spec.caps);
}

fn dsdInfo(label: []const u8, i: [*c]const c.GstDsdInfo) void {
    out("  {s} fmt={d} rate={d} ch={d} layout={d} flags={d} rev={d} pos={any}", .{ label, i.*.format, i.*.rate, i.*.channels, i.*.layout, i.*.flags, i.*.reversed_bytes, i[0].positions[0..@intCast(@min(@max(i.*.channels, 0), 8))] });
}

fn dsd() void {
    out("dsd", .{});
    out("  types {s} {s} {s}", .{ str(c.g_type_name(c.gst_dsd_info_get_type())), str(c.g_type_name(c.gst_dsd_format_get_type())), str(c.g_type_name(c.gst_dsd_plane_offset_meta_api_get_type())) });
    for ([_][*c]const u8{ "DSDU8", "DSDU16LE", "DSDU16BE", "DSDU32LE", "DSDU32BE", "DSDU64", null }) |s| {
        const f = c.gst_dsd_format_from_string(s);
        out("  fmt {s} -> {d} {s} w={d}", .{ str(s), f, str(c.gst_dsd_format_to_string(f)), c.gst_dsd_format_get_width(f) });
    }
    const caps_list = [_][*:0]const u8{
        "audio/x-dsd,format=DSDU32BE,rate=352800,channels=2",
        "audio/x-dsd,format=DSDU8,rate=352800,channels=1,layout=non-interleaved,reversed-bytes=true",
        "audio/x-dsd,format=DSDU16LE,rate=352800,channels=6,channel-mask=(bitmask)0x3f",
        "audio/x-dsd,format=DSDU16LE,rate=352800,channels=4,channel-mask=(bitmask)0x0",
        "audio/x-dsd,format=DSDU16LE,rate=352800,channels=4",
        "audio/x-dsd,format=DSDU16LE,rate=0,channels=4",
        "audio/x-dsd,format=DSDU16LE,rate=5,channels=0",
        "audio/x-dsd,format=DSDXX,rate=5,channels=1",
        "audio/x-dsd,rate=5,channels=1",
        "audio/x-dsd,format=DSDU8,rate=5,channels=1,layout=planar",
        "audio/x-raw,format=DSDU8,rate=5,channels=1",
    };
    for (caps_list) |cs| {
        const caps = c.gst_caps_from_string(cs);
        const i = c.gst_dsd_info_new_from_caps(caps);
        out("  from {s} -> {d}", .{ cs, @intFromBool(i != null) });
        if (i != null) {
            dsdInfo("   ", i);
            showCaps("    back", c.gst_dsd_info_to_caps(i));
            const copy = c.gst_dsd_info_copy(i);
            out("    equal {d}", .{c.gst_dsd_info_is_equal(i, copy)});
            copy.*.reversed_bytes = 1 - copy.*.reversed_bytes;
            out("    equal rev {d}", .{c.gst_dsd_info_is_equal(i, copy)});
            c.gst_dsd_info_free(copy);
            c.gst_dsd_info_free(i);
        }
        c.gst_caps_unref(caps);
    }
    var info: c.GstDsdInfo = undefined;
    var five = [_]c.GstAudioChannelPosition{ c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT, c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT, c.GST_AUDIO_CHANNEL_POSITION_FRONT_CENTER, c.GST_AUDIO_CHANNEL_POSITION_REAR_LEFT, c.GST_AUDIO_CHANNEL_POSITION_REAR_RIGHT };
    c.gst_dsd_info_set_format(&info, c.GST_DSD_FORMAT_U8, 2822400, 5, &five);
    dsdInfo("set five", &info);
    showCaps("caps", c.gst_dsd_info_to_caps(&info));
    c.gst_dsd_info_set_format(&info, c.GST_DSD_FORMAT_U8, 2822400, 3, null);
    dsdInfo("set three", &info);
    showCaps("caps", c.gst_dsd_info_to_caps(&info));
    c.gst_dsd_info_set_format(&info, c.GST_DSD_FORMAT_U8, 2822400, 1, null);
    showCaps("caps mono", c.gst_dsd_info_to_caps(&info));
    info.layout = 9;
    showCaps("caps bad layout", c.gst_dsd_info_to_caps(&info));
    c.gst_dsd_info_set_format(&info, c.GST_DSD_FORMAT_UNKNOWN, 1, 1, null);
    info.format = 0;
    showCaps("caps unknown", c.gst_dsd_info_to_caps(&info));
    const boxed: [*c]c.GstDsdInfo = @ptrCast(@alignCast(c.g_boxed_copy(c.gst_dsd_info_get_type(), &info)));
    dsdInfo("boxed", boxed);
    c.g_boxed_free(c.gst_dsd_info_get_type(), boxed);
    var input: [48]u8 = undefined;
    for (&input, 0..) |*x, i| x.* = @truncate(i *% 37 +% 3);
    const fmts = [_]c.GstDsdFormat{ c.GST_DSD_FORMAT_U8, c.GST_DSD_FORMAT_U16LE, c.GST_DSD_FORMAT_U16BE, c.GST_DSD_FORMAT_U32LE, c.GST_DSD_FORMAT_U32BE };
    var in_offs = [_]c_ulong{ 0, 16, 32 };
    var out_offs = [_]c_ulong{ 32, 0, 16 };
    for (fmts) |fi| for (fmts) |fo| for ([_]c.GstAudioLayout{ 0, 1 }) |li| for ([_]c.GstAudioLayout{ 0, 1 }) |lo| for ([_]c.gboolean{ 0, 1 }) |r| {
        var outb: [48]u8 = undefined;
        @memset(&outb, 0xee);
        c.gst_dsd_convert(&input, &outb, fi, fo, li, lo, &in_offs, &out_offs, 48, 3, r);
        out("  convert {d}->{d} {d}->{d} r{d} {x}", .{ fi, fo, li, lo, r, outb });
    };
    var outb: [48]u8 = undefined;
    c.gst_dsd_convert(&input, &outb, 1, 1, 1, 1, &in_offs, &in_offs, 48, 3, 1);
    out("  same offsets rev {x}", .{outb});
    c.gst_dsd_convert(&input, &outb, 1, 1, 1, 1, &in_offs, &in_offs, 48, 3, 0);
    out("  same offsets {x}", .{outb});
    c.gst_dsd_convert(&input, &outb, 0, 1, 0, 0, null, null, 48, 3, 0);
    c.gst_dsd_convert(&input, &outb, 1, 1, 1, 0, null, null, 48, 3, 0);
    c.gst_dsd_convert(&input, &outb, 4, 4, 0, 0, null, null, 46, 3, 0);
    c.gst_dsd_convert(&input, &outb, 1, 1, 0, 0, null, null, 0, 3, 0);
    const b = c.gst_buffer_new_allocate(null, 64, null);
    var offs = [_]c_ulong{ 0, 20 };
    const m = c.gst_buffer_add_dsd_plane_offset_meta(b, 2, 20, &offs);
    out("  pmeta {d} {d} {any}", .{ m.*.num_channels, m.*.num_bytes_per_channel, m.*.offsets[0..2] });
    var bad = [_]c_ulong{ 0, 10 };
    out("  overlap {d}", .{@intFromBool(c.gst_buffer_add_dsd_plane_offset_meta(b, 2, 20, &bad) != null)});
    var far = [_]c_ulong{ 0, 50 };
    out("  oob {d}", .{@intFromBool(c.gst_buffer_add_dsd_plane_offset_meta(b, 2, 20, &far) != null)});
    const m2 = c.gst_buffer_add_dsd_plane_offset_meta(b, 10, 0, null);
    out("  ten {d} {d}", .{ m2.*.num_channels, @intFromBool(m2.*.offsets != null) });
    _ = c.gst_buffer_add_dsd_plane_offset_meta(b, 0, 0, null);
    _ = c.gst_buffer_add_dsd_plane_offset_meta(b, 2, 0, &offs);
    const copy = c.gst_buffer_copy(b);
    var state: c.gpointer = null;
    var n: usize = 0;
    while (c.gst_buffer_iterate_meta(copy, &state) != null) n += 1;
    out("  copied metas {d}", .{n});
    c.gst_buffer_unref(copy);
    c.gst_buffer_unref(b);
}

fn alignTest() void {
    out("stream align", .{});
    out("  type {s}", .{str(c.g_type_name(c.gst_audio_stream_align_get_type()))});
    const S = c.GST_SECOND;
    for ([_]c_int{ 48000, -44100 }) |rate| {
        const a = c.gst_audio_stream_align_new(rate, 40 * c.GST_MSECOND, S);
        out("  rate {d} thr {d} wait {d}", .{ c.gst_audio_stream_align_get_rate(a), c.gst_audio_stream_align_get_alignment_threshold(a), c.gst_audio_stream_align_get_discont_wait(a) });
        var ts: u64 = 0;
        const steps = [_]struct { u64, c.guint, c.gboolean }{ .{ 0, 480, 0 }, .{ 10 * c.GST_MSECOND, 480, 0 }, .{ 20 * c.GST_MSECOND + 5000, 480, 0 }, .{ 200 * c.GST_MSECOND, 480, 0 }, .{ 210 * c.GST_MSECOND, 480, 0 }, .{ 2 * S, 480, 0 }, .{ 3 * S, 1000, 0 }, .{ 3 * S + 2 * S, 1000, 0 }, .{ 5 * S + 20 * c.GST_MSECOND, 960, 1 }, .{ 7 * S, 100, 0 } };
        for (steps) |s| {
            var ot: u64 = 0;
            var od: u64 = 0;
            var op: c_ulong = 0;
            const d = c.gst_audio_stream_align_process(a, s[2], s[0] + ts, s[1], &ot, &od, &op);
            out("    in {d}+{d} -> discont {d} ts {d} dur {d} pos {d} at {d} since {d}", .{ s[0], s[1], d, ot, od, op, c.gst_audio_stream_align_get_timestamp_at_discont(a), c.gst_audio_stream_align_get_samples_since_discont(a) });
        }
        ts = 0;
        const cp = c.gst_audio_stream_align_copy(a);
        c.gst_audio_stream_align_set_rate(cp, 22050);
        c.gst_audio_stream_align_set_alignment_threshold(cp, 0);
        c.gst_audio_stream_align_set_discont_wait(cp, 0);
        for (0..4) |i| {
            var ot: u64 = 0;
            const d = c.gst_audio_stream_align_process(cp, 0, i * 10 * c.GST_MSECOND + i * 7, 220, &ot, null, null);
            out("    copy {d} -> {d} {d}", .{ i, d, ot });
        }
        c.gst_audio_stream_align_mark_discont(cp);
        c.gst_audio_stream_align_free(cp);
        c.gst_audio_stream_align_free(a);
    }
    _ = c.gst_audio_stream_align_new(0, 1, 1);
    _ = c.gst_audio_stream_align_new(1, std.math.maxInt(u64), 1);
    _ = c.gst_audio_stream_align_get_rate(null);
    c.gst_audio_stream_align_free(null);
}

var fake_time: u64 = 0;
var destroyed: c_int = 0;

fn getTime(_: [*c]c.GstClock, _: c.gpointer) callconv(.c) c.GstClockTime {
    return fake_time;
}

fn destroy(_: c.gpointer) callconv(.c) void {
    destroyed += 1;
}

fn clockTest() void {
    out("audio clock", .{});
    var ud: u8 = 0;
    const clk = c.gst_audio_clock_new("aclk", getTime, &ud, destroy);
    const ac: [*c]c.GstAudioClock = @ptrCast(@alignCast(clk));
    out("  type {s} name {s} flags {x} floating {d}", .{ str(c.g_type_name(c.gst_audio_clock_get_type())), str(c.gst_object_get_name(@ptrCast(clk))), @as(*c.GstObject, @ptrCast(@alignCast(clk))).flags, c.g_object_is_floating(clk) });
    var ct: c.GstClockType = 0;
    c.g_object_get(clk, "clock-type", &ct, NONE);
    out("  clock-type {d}", .{ct});
    for ([_]u64{ 100, 50, 300, std.math.maxInt(u64), 1000 }) |t| {
        fake_time = t;
        out("  t={d} internal {d} get {d} adjust {d}", .{ @as(i64, @bitCast(t)), c.gst_clock_get_internal_time(clk), @as(i64, @bitCast(c.gst_audio_clock_get_time(ac))), c.gst_audio_clock_adjust(ac, 10) });
    }
    c.gst_audio_clock_reset(ac, 400);
    fake_time = 100;
    out("  reset 400 internal {d} get {d} adjust {d} offset {d}", .{ c.gst_clock_get_internal_time(clk), c.gst_audio_clock_get_time(ac), c.gst_audio_clock_adjust(ac, 10), ac.*.time_offset });
    c.gst_audio_clock_reset(ac, 5000);
    out("  reset 5000 internal {d} offset {d}", .{ c.gst_clock_get_internal_time(clk), ac.*.time_offset });
    c.gst_audio_clock_invalidate(ac);
    out("  invalid get {d} internal {d}", .{ @as(i64, @bitCast(c.gst_audio_clock_get_time(ac))), c.gst_clock_get_internal_time(clk) });
    c.gst_object_unref(clk);
    out("  destroyed {d}", .{destroyed});
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    iec();
    dsd();
    alignTest();
    clockTest();
}
