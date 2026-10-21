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

fn formats() void {
    out("formats", .{});
    var f: c_int = 0;
    while (f <= c.GST_AUDIO_FORMAT_U20_32BE) : (f += 1) {
        const i = c.gst_audio_format_get_info(@intCast(f));
        out("  {d} {s} '{s}' flags={d} end={d} w={d} d={d} sil={x} unpack={d} funcs={d}{d} back={d}", .{ f, str(i.*.name), str(i.*.description), i.*.flags, i.*.endianness, i.*.width, i.*.depth, i[0].silence, i.*.unpack_format, @intFromBool(i.*.unpack_func != null), @intFromBool(i.*.pack_func != null), c.gst_audio_format_from_string(i.*.name) });
    }
    out("  bogus {d} to_string {s}", .{ c.gst_audio_format_from_string("S99"), str(c.gst_audio_format_to_string(c.GST_AUDIO_FORMAT_F64BE)) });
    _ = c.gst_audio_format_to_string(200);
    _ = c.gst_audio_format_get_info(200);
    _ = c.gst_audio_format_from_string(null);
    for ([_]c_int{ 0, 1 }) |sign| for ([_]c_int{ 0, c.G_LITTLE_ENDIAN, c.G_BIG_ENDIAN }) |e| for ([_][2]c_int{ .{ 8, 8 }, .{ 16, 16 }, .{ 24, 24 }, .{ 32, 24 }, .{ 32, 32 }, .{ 24, 20 }, .{ 32, 20 }, .{ 24, 18 }, .{ 64, 64 }, .{ 16, 8 } }) |wd| {
        out("  build {d} {d} {d}/{d} -> {d}", .{ sign, e, wd[0], wd[1], c.gst_audio_format_build_integer(sign, e, wd[0], wd[1]) });
    };
    var n: c.guint = 0;
    const raw = c.gst_audio_formats_raw(&n);
    out("  raw {d}: {any}", .{ n, raw[0..n] });
    _ = c.gst_audio_formats_raw(null);
    showCaps("raw caps all", c.gst_audio_make_raw_caps(null, 0, c.GST_AUDIO_LAYOUT_INTERLEAVED));
    var two = [_]c.GstAudioFormat{ c.GST_AUDIO_FORMAT_S16LE, c.GST_AUDIO_FORMAT_F32BE };
    showCaps("raw caps two", c.gst_audio_make_raw_caps(&two, 2, c.GST_AUDIO_LAYOUT_NON_INTERLEAVED));
    showCaps("raw caps one", c.gst_audio_make_raw_caps(&two, 1, c.GST_AUDIO_LAYOUT_INTERLEAVED));
    var bad = [_]c.GstAudioFormat{ c.GST_AUDIO_FORMAT_S16LE, c.GST_AUDIO_FORMAT_ENCODED };
    showCaps("raw caps bad", c.gst_audio_make_raw_caps(&bad, 2, c.GST_AUDIO_LAYOUT_INTERLEAVED));
    showCaps("raw caps mismatch", c.gst_audio_make_raw_caps(null, 3, c.GST_AUDIO_LAYOUT_INTERLEAVED));
}

const INT_SAMPLES = [_]u32{ 0, 1, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff, 0x123456, 0x7fffff, 0x800000, 0xffffff, 0x12345678, 0x7fffffff, 0x80000000, 0xffffffff, 0xdeadbeef, 0x00010203, 0xfedcba98 };
const F_SAMPLES = [_]f64{ 0, -0.0, 1, -1, 0.5, 1e-40, -1e-310, 3.4e38, 1e300, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64), 0.123456789123, 2.2250738585072014e-308, 1.1754943508222875e-38 };

fn packUnpack() void {
    out("pack/unpack", .{});
    var f: c_int = c.GST_AUDIO_FORMAT_S8;
    while (f <= c.GST_AUDIO_FORMAT_U20_32BE) : (f += 1) {
        const i = c.gst_audio_format_get_info(@intCast(f));
        const is_float = i.*.unpack_format == c.GST_AUDIO_FORMAT_F64;
        const n: usize = if (is_float) F_SAMPLES.len else INT_SAMPLES.len;
        var packed_buf: [64 * 8]u8 = undefined;
        @memset(&packed_buf, 0xa5);
        if (is_float) {
            var src: [F_SAMPLES.len]f64 = F_SAMPLES;
            i.*.pack_func.?(i, 0, &src, &packed_buf, @intCast(n));
        } else {
            var src: [INT_SAMPLES.len]u32 = INT_SAMPLES;
            i.*.pack_func.?(i, 0, &src, &packed_buf, @intCast(n));
        }
        const bytes: usize = n * @as(usize, @intCast(@divTrunc(i.*.width, 8)));
        out("  {s} packed {x}", .{ str(i.*.name), packed_buf[0 .. bytes + 4] });
        for ([_]c.GstAudioPackFlags{ 0, c.GST_AUDIO_PACK_FLAG_TRUNCATE_RANGE }) |fl| {
            if (is_float) {
                var dst: [F_SAMPLES.len + 1]u64 = undefined;
                @memset(&dst, 0x5a5a5a5a5a5a5a5a);
                i.*.unpack_func.?(i, fl, &dst, &packed_buf, @intCast(n));
                out("    unpack{d} {any}", .{ fl, dst });
            } else {
                var dst: [INT_SAMPLES.len + 1]u32 = undefined;
                @memset(&dst, 0x5a5a5a5a);
                i.*.unpack_func.?(i, fl, &dst, &packed_buf, @intCast(n));
                out("    unpack{d} {any}", .{ fl, dst });
            }
        }
        var sil: [37]u8 = undefined;
        @memset(&sil, 0xee);
        c.gst_audio_format_info_fill_silence(i, &sil, 36);
        out("    silence {x}", .{sil});
        @memset(&sil, 0xee);
        c.gst_audio_format_fill_silence(i, &sil, 7);
        out("    silence7 {x}", .{sil[0..9]});
    }
    var sil: [8]u8 = undefined;
    c.gst_audio_format_info_fill_silence(c.gst_audio_format_get_info(c.GST_AUDIO_FORMAT_ENCODED), &sil, 4);
    c.gst_audio_format_info_fill_silence(c.gst_audio_format_get_info(c.GST_AUDIO_FORMAT_S16LE), null, 4);
}

fn P(comptime name: []const u8) c.GstAudioChannelPosition {
    return @field(c, "GST_AUDIO_CHANNEL_POSITION_" ++ name);
}

fn posStr(label: []const u8, pos: [*c]const c.GstAudioChannelPosition, n: c_int) void {
    const s = c.gst_audio_channel_positions_to_string(pos, n);
    out("  {s} {s}", .{ label, str(s) });
    c.g_free(s);
}

fn channelsTest() void {
    out("channels", .{});
    var all: [32]c.GstAudioChannelPosition = undefined;
    for (&all, 0..) |*x, i| x.* = @as(c_int, @intCast(i)) - 3;
    posStr("all", &all, 32);
    var five = [_]c.GstAudioChannelPosition{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("FRONT_CENTER"), P("REAR_LEFT"), P("REAR_RIGHT") };
    var swapped = [_]c.GstAudioChannelPosition{ P("FRONT_RIGHT"), P("FRONT_LEFT"), P("REAR_LEFT"), P("FRONT_CENTER"), P("REAR_RIGHT") };
    var dup = [_]c.GstAudioChannelPosition{ P("FRONT_LEFT"), P("FRONT_LEFT") };
    var mono = [_]c.GstAudioChannelPosition{P("MONO")};
    var none = [_]c.GstAudioChannelPosition{ P("NONE"), P("NONE"), P("NONE") };
    var mix = [_]c.GstAudioChannelPosition{ P("FRONT_LEFT"), P("MONO") };
    var wide = [_]c.GstAudioChannelPosition{ P("WIDE_LEFT"), P("FRONT_LEFT"), P("TOP_CENTER") };
    const sets = [_]struct { []const u8, [*c]c.GstAudioChannelPosition, c_int }{ .{ "five", &five, 5 }, .{ "swapped", &swapped, 5 }, .{ "dup", &dup, 2 }, .{ "mono", &mono, 1 }, .{ "none", &none, 3 }, .{ "mix", &mix, 2 }, .{ "wide", &wide, 3 } };
    for (sets) |s| {
        var mask: u64 = 0;
        const ok = c.gst_audio_channel_positions_to_mask(s[1], s[2], 1, &mask);
        var mask2: u64 = 0;
        const ok2 = c.gst_audio_channel_positions_to_mask(s[1], s[2], 0, &mask2);
        out("  {s} valid {d}/{d} mask {x} {d} {x}", .{ s[0], c.gst_audio_check_valid_channel_positions(s[1], s[2], 1), c.gst_audio_check_valid_channel_positions(s[1], s[2], 0), mask, ok, mask2 + @as(u64, @intCast(ok2)) });
        var copy: [8]c.GstAudioChannelPosition = undefined;
        @memcpy(copy[0..@intCast(s[2])], s[1][0..@intCast(s[2])]);
        out("    valid order {d}", .{c.gst_audio_channel_positions_to_valid_order(&copy, s[2])});
        posStr("    now", &copy, s[2]);
    }
    for ([_]u64{ 0, 3, 0x3f, 0x60f, 0x80000001, 0xffffffffffffffff, 0x1 }) |mask| for ([_]c_int{ 1, 2, 3, 6, 8 }) |n| {
        var pos: [64]c.GstAudioChannelPosition = undefined;
        @memset(&pos, 99);
        const r = c.gst_audio_channel_positions_from_mask(n, mask, &pos);
        out("  from mask {x} n={d} -> {d} {any}", .{ mask, n, r, pos[0..@intCast(n)] });
    };
    _ = c.gst_audio_channel_positions_from_mask(0, 3, null);
    var n: c_int = -1;
    while (n <= 10) : (n += 1) out("  fallback {d} {x}", .{ n, c.gst_audio_channel_get_fallback_mask(n) });
    var map: [8]c_int = .{ 9, 9, 9, 9, 9, 9, 9, 9 };
    out("  map {d} {any}", .{ c.gst_audio_get_channel_reorder_map(5, &five, &swapped, &map), map });
    out("  map dup {d}", .{c.gst_audio_get_channel_reorder_map(2, &dup, &dup, &map)});
    out("  map none {d}", .{c.gst_audio_get_channel_reorder_map(3, &none, &none, &map)});
    var data: [30]u16 = undefined;
    for (&data, 0..) |*x, i| x.* = @intCast(i);
    out("  reorder {d} {any}", .{ c.gst_audio_reorder_channels(&data, 60, c.GST_AUDIO_FORMAT_S16LE, 5, &five, &swapped), data });
    out("  reorder same {d}", .{c.gst_audio_reorder_channels(&data, 60, c.GST_AUDIO_FORMAT_S16LE, 5, &five, &five)});
    out("  reorder bad size {d}", .{c.gst_audio_reorder_channels(&data, 59, c.GST_AUDIO_FORMAT_S16LE, 5, &five, &swapped)});
    out("  reorder empty {d}", .{c.gst_audio_reorder_channels(&data, 0, c.GST_AUDIO_FORMAT_S16LE, 5, &five, &swapped)});
    var rmap = [_]c_int{ 2, 0, 1 };
    var d3: [12]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    c.gst_audio_reorder_channels_with_reorder_map(&d3, 12, 2, 3, &rmap);
    out("  with map {any}", .{d3});
    const b = c.gst_buffer_new_allocate(null, 60, null);
    _ = c.gst_buffer_fill(b, 0, &data, 60);
    out("  buffer reorder {d}", .{c.gst_audio_buffer_reorder_channels(b, c.GST_AUDIO_FORMAT_S16LE, 5, &swapped, &five)});
    var back: [30]u16 = undefined;
    _ = c.gst_buffer_extract(b, 0, &back, 60);
    out("  buffer data {any}", .{back});
    _ = c.gst_buffer_ref(b);
    out("  buffer readonly {d}", .{c.gst_audio_buffer_reorder_channels(b, c.GST_AUDIO_FORMAT_S16LE, 5, &swapped, &five)});
    c.gst_buffer_unref(b);
    c.gst_buffer_unref(b);
}

fn showInfo(label: []const u8, i: [*c]const c.GstAudioInfo) void {
    out("  {s} fmt={s} flags={d} layout={d} rate={d} ch={d} bpf={d} pos={any}", .{ label, if (i.*.finfo != null) str(i.*.finfo.*.name) else "(nofinfo)", i.*.flags, i.*.layout, i.*.rate, i.*.channels, i.*.bpf, i[0].position[0..@intCast(@min(@max(i.*.channels, 0), 10))] });
}

fn infoTest() void {
    out("info", .{});
    out("  type {s} {s}", .{ str(c.g_type_name(c.gst_audio_info_get_type())), str(c.g_type_name(c.gst_audio_format_info_get_type())) });
    const i = c.gst_audio_info_new();
    showInfo("new", i);
    var five = [_]c.GstAudioChannelPosition{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("FRONT_CENTER"), P("REAR_LEFT"), P("REAR_RIGHT") };
    var swapped = [_]c.GstAudioChannelPosition{ P("FRONT_RIGHT"), P("FRONT_LEFT"), P("FRONT_CENTER"), P("REAR_LEFT"), P("REAR_RIGHT") };
    var none = [_]c.GstAudioChannelPosition{ P("NONE"), P("NONE"), P("NONE") };
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, null);
    showInfo("s16 stereo", i);
    showCaps("caps", c.gst_audio_info_to_caps(i));
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_F32LE, 48000, 1, null);
    showInfo("f32 mono", i);
    showCaps("caps", c.gst_audio_info_to_caps(i));
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_S24LE, 96000, 5, &five);
    showInfo("s24 five", i);
    showCaps("caps", c.gst_audio_info_to_caps(i));
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_S24LE, 96000, 5, &swapped);
    showInfo("swapped", i);
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_U8, 8000, 3, &none);
    showInfo("none", i);
    showCaps("caps", c.gst_audio_info_to_caps(i));
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_U8, 8000, 4, null);
    showInfo("four null", i);
    i.*.flags = 0;
    showCaps("caps unflagged", c.gst_audio_info_to_caps(i));
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_S16LE, 8000, 2, null);
    i.*.flags = c.GST_AUDIO_FLAG_UNPOSITIONED;
    showCaps("caps flagged", c.gst_audio_info_to_caps(i));
    i.*.layout = 7;
    showCaps("caps bad layout", c.gst_audio_info_to_caps(i));
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_UNKNOWN, 8000, 2, null);
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_S16LE, 8000, 70, &five);
    c.gst_audio_info_set_format(i, c.GST_AUDIO_FORMAT_S16LE, 8000, 70, null);
    showInfo("seventy", i);
    showCaps("caps", c.gst_audio_info_to_caps(i));
    const caps_list = [_][*:0]const u8{
        "audio/x-raw,format=S16LE,layout=interleaved,rate=44100,channels=2",
        "audio/x-raw,format=F32BE,layout=non-interleaved,rate=8000,channels=1,channel-mask=(bitmask)0x0",
        "audio/x-raw,format=S32LE,layout=interleaved,rate=48000,channels=6,channel-mask=(bitmask)0x3f",
        "audio/x-raw,format=S32LE,layout=interleaved,rate=48000,channels=4,channel-mask=(bitmask)0x0",
        "audio/x-raw,format=S32LE,layout=interleaved,rate=48000,channels=4",
        "audio/x-raw,format=S32LE,layout=interleaved,rate=48000,channels=3,channel-mask=(bitmask)0x3f",
        "audio/x-raw,format=XX,layout=interleaved,rate=48000,channels=2",
        "audio/x-raw,layout=interleaved,rate=48000,channels=2",
        "audio/x-raw,format=S16LE,rate=48000,channels=2",
        "audio/x-raw,format=S16LE,layout=planar,rate=48000,channels=2",
        "audio/x-raw,format=S16LE,layout=interleaved,channels=2",
        "audio/x-raw,format=S16LE,layout=interleaved,rate=5",
        "audio/mpeg,mpegversion=1",
        "audio/mpeg,rate=44100,channels=6",
        "video/x-raw,format=I420",
        "audio/x-raw,format=S16LE,layout=interleaved,rate=48000,channels=1,channel-mask=(bitmask)0x4",
    };
    for (caps_list) |cs| {
        const caps = c.gst_caps_from_string(cs);
        var info: c.GstAudioInfo = undefined;
        c.gst_audio_info_init(&info);
        const r = c.gst_audio_info_from_caps(&info, caps);
        out("  from_caps {s} -> {d}", .{ cs, r });
        if (r != 0) {
            showInfo("    ", &info);
            showCaps("    back", c.gst_audio_info_to_caps(&info));
        }
        const ni = c.gst_audio_info_new_from_caps(caps);
        out("    new {d}", .{@intFromBool(ni != null)});
        if (ni != null) c.gst_audio_info_free(ni);
        c.gst_caps_unref(caps);
    }
    const unfixed = c.gst_caps_from_string("audio/x-raw,rate=[1,5]");
    var info: c.GstAudioInfo = undefined;
    _ = c.gst_audio_info_from_caps(&info, unfixed);
    c.gst_caps_unref(unfixed);
    c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_S16LE, 44100, 2, null);
    const fmts = [_]c.GstFormat{ c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT, c.GST_FORMAT_TIME, c.GST_FORMAT_PERCENT };
    for (fmts) |a| for (fmts) |b| for ([_]i64{ -1, 0, 4, 44100, 1000000000, 123456789 }) |v| {
        var d: i64 = 77;
        const r = c.gst_audio_info_convert(&info, a, v, b, &d);
        out("  convert {d}->{d} {d} = {d} {d}", .{ a, b, v, r, d });
    };
    const copy = c.gst_audio_info_copy(&info);
    out("  equal {d}", .{c.gst_audio_info_is_equal(&info, copy)});
    copy[0].position[1] = P("REAR_LEFT");
    out("  equal pos {d}", .{c.gst_audio_info_is_equal(&info, copy)});
    copy.*.rate = 1;
    out("  equal rate {d}", .{c.gst_audio_info_is_equal(&info, copy)});
    const boxed = c.g_boxed_copy(c.gst_audio_info_get_type(), copy);
    showInfo("boxed", @ptrCast(@alignCast(boxed)));
    c.g_boxed_free(c.gst_audio_info_get_type(), boxed);
    c.gst_audio_info_free(copy);
    c.gst_audio_info_free(i);
    c.gst_audio_info_init(null);
}

fn showBuf(label: []const u8, b: [*c]c.GstBuffer) void {
    if (b == null) {
        out("  {s} (null)", .{label});
        return;
    }
    var first: [4]u8 = .{ 0, 0, 0, 0 };
    _ = c.gst_buffer_extract(b, 0, &first, 4);
    const m: [*c]c.GstAudioMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_meta_api_get_type())));
    out("  {s} size={d} pts={d} dts={d} dur={d} off={d} end={d} head={any} meta={d}", .{ label, c.gst_buffer_get_size(b), @as(i64, @bitCast(b.*.pts)), @as(i64, @bitCast(b.*.dts)), @as(i64, @bitCast(b.*.duration)), @as(i64, @bitCast(b.*.offset)), @as(i64, @bitCast(b.*.offset_end)), first, if (m != null) @as(i64, @intCast(m.*.samples)) else -1 });
    if (m != null and m.*.offsets != null) out("    offsets {any}", .{m.*.offsets[0..@intCast(m.*.info.channels)]});
}

fn mkbuf(n: usize, pts: u64, dur: u64, off: u64, end: u64) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, n, null);
    var tmp: [4096]u8 = undefined;
    for (0..n) |i| tmp[i] = @truncate(i);
    _ = c.gst_buffer_fill(b, 0, &tmp, n);
    b.*.pts = pts;
    b.*.duration = dur;
    b.*.offset = off;
    b.*.offset_end = end;
    return b;
}

fn clipTest() void {
    out("clip", .{});
    const NONE64 = std.math.maxInt(u64);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = c.GST_SECOND / 4;
    seg.stop = c.GST_SECOND * 3 / 4;
    const S = c.GST_SECOND;
    const cases = [_][4]u64{ .{ 0, S, 0, 100 }, .{ 0, NONE64, NONE64, NONE64 }, .{ S / 2, S / 10, 50, 60 }, .{ S, S, 100, 200 }, .{ 0, S / 8, 0, 12 }, .{ NONE64, S, 0, 100 }, .{ S / 5, S, NONE64, 300 } };
    for (cases) |k| showBuf("time", c.gst_audio_buffer_clip(mkbuf(400, k[0], k[1], k[2], k[3]), &seg, 100, 4));
    c.gst_segment_init(&seg, c.GST_FORMAT_DEFAULT);
    seg.start = 20;
    seg.stop = 70;
    for (cases) |k| showBuf("default", c.gst_audio_buffer_clip(mkbuf(400, k[0], k[1], k[2], k[3]), &seg, 100, 4));
    c.gst_segment_init(&seg, c.GST_FORMAT_BYTES);
    const bb = mkbuf(40, 0, S, 0, 10);
    showBuf("bytes", c.gst_audio_buffer_clip(bb, &seg, 100, 4));
    c.gst_buffer_unref(bb);
    showBuf("trunc", c.gst_audio_buffer_truncate(mkbuf(400, 5, 6, 7, 8), 4, 10, 20));
    showBuf("trunc rest", c.gst_audio_buffer_truncate(mkbuf(400, 5, 6, 7, 8), 4, 0, std.math.maxInt(usize)));
    showBuf("trunc none", c.gst_audio_buffer_truncate(mkbuf(400, NONE64, 6, NONE64, 8), 4, 3, 50));
    const keep = mkbuf(400, 5, 6, 7, 8);
    showBuf("trunc bad", c.gst_audio_buffer_truncate(keep, 4, 100, 1));
    showBuf("trunc bad2", c.gst_audio_buffer_truncate(keep, 4, 10, 95));
    c.gst_buffer_unref(keep);
    var info: c.GstAudioInfo = undefined;
    c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_S16LE, 100, 2, null);
    info.layout = c.GST_AUDIO_LAYOUT_NON_INTERLEAVED;
    const nb = mkbuf(400, 0, S, 0, 100);
    _ = c.gst_buffer_add_audio_meta(nb, &info, 100, null);
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = S / 10;
    seg.stop = S / 2;
    showBuf("planar clip", c.gst_audio_buffer_clip(nb, &seg, 100, 4));
}

fn bufferTest() void {
    out("audiobuffer", .{});
    var info: c.GstAudioInfo = undefined;
    c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_S16LE, 100, 2, null);
    const b = mkbuf(400, 0, 0, 0, 0);
    var ab = std.mem.zeroes(c.GstAudioBuffer);
    out("  map {d}", .{c.gst_audio_buffer_map(&ab, &info, b, c.GST_MAP_READ)});
    out("  n_samples {d} planes {d} first {d}", .{ ab.n_samples, ab.n_planes, @as([*]u8, @ptrCast(ab.planes[0]))[3] });
    c.gst_audio_buffer_unmap(&ab);
    info.layout = c.GST_AUDIO_LAYOUT_NON_INTERLEAVED;
    out("  map no meta {d}", .{c.gst_audio_buffer_map(&ab, &info, b, c.GST_MAP_READ)});
    _ = c.gst_buffer_add_audio_meta(b, &info, 80, null);
    out("  map planar {d}", .{c.gst_audio_buffer_map(&ab, &info, b, c.GST_MAP_READ)});
    out("  n_samples {d} planes {d} p1 {d}", .{ ab.n_samples, ab.n_planes, @as([*]u8, @ptrCast(ab.planes[1]))[0] });
    c.gst_audio_buffer_unmap(&ab);
    var info2 = info;
    info2.rate = 7;
    out("  map other info {d}", .{c.gst_audio_buffer_map(&ab, &info2, b, c.GST_MAP_READ)});
    c.gst_audio_buffer_unmap(&ab);
    c.gst_buffer_unref(b);
    c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_S16LE, 100, 10, null);
    info.layout = c.GST_AUDIO_LAYOUT_NON_INTERLEAVED;
    const big = mkbuf(400, 0, 0, 0, 0);
    _ = c.gst_buffer_add_audio_meta(big, &info, 20, null);
    out("  map ten {d}", .{c.gst_audio_buffer_map(&ab, &info, big, c.GST_MAP_READ)});
    out("  planes {d} p9 {d}", .{ ab.n_planes, @as([*]u8, @ptrCast(ab.planes[9]))[1] });
    c.gst_audio_buffer_unmap(&ab);
    const empty = mkbuf(400, 0, 0, 0, 0);
    _ = c.gst_buffer_add_audio_meta(empty, &info, 0, null);
    out("  map zero {d} planes {d}", .{ c.gst_audio_buffer_map(&ab, &info, empty, c.GST_MAP_READ), ab.n_planes });
    c.gst_audio_buffer_unmap(&ab);
    c.gst_buffer_unref(empty);
    c.gst_buffer_unref(big);
    out("  map null {d}", .{c.gst_audio_buffer_map(&ab, &info, null, c.GST_MAP_READ)});
}

fn metaTest() void {
    out("meta", .{});
    out("  api {s} {s} {s} {s}", .{ str(c.g_type_name(c.gst_audio_meta_api_get_type())), str(c.g_type_name(c.gst_audio_downmix_meta_api_get_type())), str(c.g_type_name(c.gst_audio_clipping_meta_api_get_type())), str(c.g_type_name(c.gst_audio_level_meta_api_get_type())) });
    out("  tags audio {d} channels {d} rate {d}", .{ c.gst_meta_api_type_has_tag(c.gst_audio_meta_api_get_type(), c.g_quark_from_string("audio")), c.gst_meta_api_type_has_tag(c.gst_audio_meta_api_get_type(), c.g_quark_from_string("channels")), c.gst_meta_api_type_has_tag(c.gst_audio_clipping_meta_api_get_type(), c.g_quark_from_string("rate")) });
    const b = mkbuf(400, 0, 0, 0, 0);
    var from = [_]c.GstAudioChannelPosition{ P("FRONT_LEFT"), P("FRONT_RIGHT"), P("FRONT_CENTER") };
    var to = [_]c.GstAudioChannelPosition{ P("FRONT_LEFT"), P("FRONT_RIGHT") };
    var r0 = [_]f32{ 1, 0, 0.5 };
    var r1 = [_]f32{ 0, 1, 0.5 };
    var mat = [_][*c]const f32{ &r0, &r1 };
    const dm = c.gst_buffer_add_audio_downmix_meta(b, &from, 3, &to, 2, &mat);
    out("  downmix {d} {d} {any}", .{ dm.*.from_channels, dm.*.to_channels, dm.*.matrix[1][0..3] });
    out("  find {d} {d}", .{ @intFromBool(c.gst_buffer_get_audio_downmix_meta_for_channels(b, &to, 2) == dm), @intFromBool(c.gst_buffer_get_audio_downmix_meta_for_channels(b, &from, 3) != null) });
    _ = c.gst_buffer_add_audio_downmix_meta(b, &from, 0, &to, 2, &mat);
    const cm = c.gst_buffer_add_audio_clipping_meta(b, c.GST_FORMAT_DEFAULT, 3, 4);
    out("  clipping {d} {d} {d}", .{ cm.*.format, cm.*.start, cm.*.end });
    _ = c.gst_buffer_add_audio_clipping_meta(b, c.GST_FORMAT_UNDEFINED, 3, 4);
    const lm = c.gst_buffer_add_audio_level_meta(b, 33, 1);
    out("  level {d} {d} get {d}", .{ lm.*.level, lm.*.voice_activity, @intFromBool(c.gst_buffer_get_audio_level_meta(b) == lm) });
    var info: c.GstAudioInfo = undefined;
    c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_S16LE, 100, 2, null);
    info.layout = c.GST_AUDIO_LAYOUT_NON_INTERLEAVED;
    var offs = [_]usize{ 200, 0 };
    const am = c.gst_buffer_add_audio_meta(b, &info, 100, &offs);
    out("  audio meta {d} {any}", .{ am.*.samples, am.*.offsets[0..2] });
    const copy = c.gst_buffer_copy(b);
    var state: c.gpointer = null;
    while (true) {
        const m = c.gst_buffer_iterate_meta(copy, &state);
        if (m == null) break;
        out("  copied {s}", .{str(c.g_type_name(m.*.info.*.api))});
    }
    const region = c.gst_buffer_copy_region(b, c.GST_BUFFER_COPY_ALL, 4, 8);
    state = null;
    while (true) {
        const m = c.gst_buffer_iterate_meta(region, &state);
        if (m == null) break;
        out("  region {s}", .{str(c.g_type_name(m.*.info.*.api))});
    }
    const ser = c.g_byte_array_new();
    out("  serialize {d} len {d}", .{ c.gst_meta_serialize_simple(@ptrCast(am), ser), ser.*.len });
    out("    bytes {x}", .{ser.*.data[0..ser.*.len]});
    const nb = mkbuf(400, 0, 0, 0, 0);
    var consumed: u32 = 0;
    const dm2 = c.gst_meta_deserialize(nb, ser.*.data, ser.*.len, &consumed);
    out("  deserialize {d} consumed {d}", .{ @intFromBool(dm2 != null), consumed });
    if (dm2 != null) {
        const a2: [*c]c.GstAudioMeta = @ptrCast(@alignCast(dm2));
        out("    samples {d} offsets {any} rate {d}", .{ a2.*.samples, a2.*.offsets[0..2], a2.*.info.rate });
    }
    _ = c.g_byte_array_unref(ser);
    var overlap = [_]usize{ 0, 100 };
    out("  overlap {d}", .{@intFromBool(c.gst_buffer_add_audio_meta(nb, &info, 100, &overlap) != null)});
    var far = [_]usize{ 0, 300 };
    out("  oob {d}", .{@intFromBool(c.gst_buffer_add_audio_meta(nb, &info, 100, &far) != null)});
    info.layout = c.GST_AUDIO_LAYOUT_INTERLEAVED;
    out("  interleaved offsets {d}", .{@intFromBool(c.gst_buffer_add_audio_meta(nb, &info, 100, &far) != null)});
    out("  interleaved {d}", .{@intFromBool(c.gst_buffer_add_audio_meta(nb, &info, 100, null) != null)});
    c.gst_audio_info_set_format(&info, c.GST_AUDIO_FORMAT_U8, 100, 12, null);
    info.layout = c.GST_AUDIO_LAYOUT_NON_INTERLEAVED;
    const twelve = c.gst_buffer_add_audio_meta(nb, &info, 30, null);
    out("  twelve {any}", .{twelve.*.offsets[0..12]});
    c.gst_buffer_unref(nb);
    c.gst_buffer_unref(region);
    c.gst_buffer_unref(copy);
    c.gst_buffer_unref(b);
}

fn volInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

var vol_value: f64 = 1.0;
var vol_mute: c.gboolean = 0;

fn setProp(_: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    if (id == 1) vol_value = c.g_value_get_double(v) else vol_mute = c.g_value_get_boolean(v);
}

fn getProp(_: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    if (id == 1) c.g_value_set_double(v, vol_value) else c.g_value_set_boolean(v, vol_mute);
}

fn volClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ok: *c.GObjectClass = @ptrCast(@alignCast(k));
    ok.set_property = setProp;
    ok.get_property = getProp;
    c.g_object_class_override_property(ok, 1, "volume");
    c.g_object_class_override_property(ok, 2, "mute");
}

fn volumeTest() void {
    out("volume", .{});
    const it = c.gst_stream_volume_get_type();
    out("  iface {s}", .{str(c.g_type_name(it))});
    const t = c.g_type_register_static_simple(c.G_TYPE_OBJECT, "TestVolume", @sizeOf(c.GObjectClass), volClassInit, @sizeOf(c.GObject), null, 0);
    const info = c.GInterfaceInfo{ .interface_init = volInit, .interface_finalize = null, .interface_data = null };
    c.g_type_add_interface_static(t, it, &info);
    const o: ?*c.GstStreamVolume = @ptrCast(c.g_object_new(t, null));
    const iface = c.g_type_default_interface_ref(it);
    var n: c.guint = 0;
    const props = c.g_object_interface_list_properties(iface, &n);
    for (0..n) |i| out("  prop {s} nick={s} blurb={s} flags={d}", .{ str(props[i].*.name), str(c.g_param_spec_get_nick(props[i])), str(c.g_param_spec_get_blurb(props[i])), props[i].*.flags });
    c.g_free(@ptrCast(props));
    c.gst_stream_volume_set_volume(o, c.GST_STREAM_VOLUME_FORMAT_DB, -6.0);
    out("  set db -6 -> linear {d:.12} cubic {d:.12} db {d:.12}", .{ c.gst_stream_volume_get_volume(o, c.GST_STREAM_VOLUME_FORMAT_LINEAR), c.gst_stream_volume_get_volume(o, c.GST_STREAM_VOLUME_FORMAT_CUBIC), c.gst_stream_volume_get_volume(o, c.GST_STREAM_VOLUME_FORMAT_DB) });
    c.gst_stream_volume_set_volume(o, c.GST_STREAM_VOLUME_FORMAT_CUBIC, 0.5);
    out("  cubic 0.5 -> {d:.12}", .{vol_value});
    c.gst_stream_volume_set_mute(o, 1);
    out("  mute {d}", .{c.gst_stream_volume_get_mute(o)});
    const fs = [_]c.GstStreamVolumeFormat{ 0, 1, 2, 9 };
    for (fs) |a| for (fs) |b| for ([_]f64{ 0, 0.25, 1, 2, -1 }) |v| out("  conv {d}->{d} {d} = {d:.12}", .{ a, b, v, c.gst_stream_volume_convert_volume(a, b, v) });
    _ = c.gst_stream_volume_get_volume(null, 0);
    c.g_object_unref(o);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    formats();
    packUnpack();
    channelsTest();
    infoTest();
    clipTest();
    bufferTest();
    metaTest();
    volumeTest();
}
