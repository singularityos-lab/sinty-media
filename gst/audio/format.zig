const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Info = c.GstAudioFormatInfo;
const LE = c.G_LITTLE_ENDIAN;
const BE = c.G_BIG_ENDIAN;
const SIGNED_FLAG = c.GST_AUDIO_FORMAT_FLAG_SIGNED;
const SINT = c.GST_AUDIO_FORMAT_FLAG_INTEGER | c.GST_AUDIO_FORMAT_FLAG_SIGNED;
const SINT_PACK = SINT | c.GST_AUDIO_FORMAT_FLAG_UNPACK;
const UINT = c.GST_AUDIO_FORMAT_FLAG_INTEGER;
const FLOAT = c.GST_AUDIO_FORMAT_FLAG_FLOAT;
const FLOAT_PACK = FLOAT | c.GST_AUDIO_FORMAT_FLAG_UNPACK;

const Order = enum { little, big };

fn rd(comptime T: type, p: [*]const u8, comptime o: Order) T {
    return std.mem.readInt(T, p[0..@sizeOf(T)], if (o == .little) .little else .big);
}

fn wr(comptime T: type, p: [*]u8, v: T, comptime o: Order) void {
    std.mem.writeInt(T, p[0..@sizeOf(T)], v, if (o == .little) .little else .big);
}

fn flush32(v: u32) u32 {
    return if (v & 0x7f800000 == 0) v & 0x80000000 else v;
}

fn toF64(bits: u32) f64 {
    return @floatCast(@as(f32, @bitCast(flush32(bits))));
}

fn toF32(v: f64) u32 {
    const bits: u64 = @bitCast(v);
    const in = if (bits & 0x7ff0000000000000 == 0) @as(f64, @bitCast(bits & 0x8000000000000000)) else v;
    return flush32(@bitCast(@as(f32, @floatCast(in))));
}

fn splat8(b: u8) u32 {
    return @as(u32, b) *% 0x01010101;
}

fn merge16(w: u16) u32 {
    return @as(u32, w) << 16 | w;
}

const Kind = enum { s8, u8, s16, u16, s24_32, u24_32, s32, u32, f32, f64 };

fn orcUnpack(comptime k: Kind, comptime o: Order) c.GstAudioFormatUnpack {
    return struct {
        fn f(_: [*c]const Info, flags: c.GstAudioPackFlags, dest: c.gpointer, data: c.gconstpointer, length: c.gint) callconv(.c) void {
            const n: usize = @intCast(@max(length, 0));
            const s: [*]const u8 = @ptrCast(data);
            const trunc = flags & c.GST_AUDIO_PACK_FLAG_TRUNCATE_RANGE != 0;
            switch (k) {
                .f32, .f64 => {
                    const d: [*]f64 = @ptrCast(@alignCast(dest));
                    for (0..n) |i| d[i] = if (k == .f32) toF64(rd(u32, s + i * 4, o)) else @bitCast(rd(u64, s + i * 8, o));
                },
                else => {
                    const d: [*]u32 = @ptrCast(@alignCast(dest));
                    for (0..n) |i| d[i] = switch (k) {
                        .s8 => if (trunc) @as(u32, s[i]) << 24 else splat8(s[i]) ^ 0x00808080,
                        .u8 => if (trunc) (@as(u32, s[i]) << 24) ^ 0x80000000 else splat8(s[i]) ^ 0x80000000,
                        .s16 => blk: {
                            const w = rd(u16, s + i * 2, o);
                            break :blk if (trunc) @as(u32, w) << 16 else if (o == .little) merge16(w) ^ 0x8000 else merge16(w);
                        },
                        .u16 => blk: {
                            const w = rd(u16, s + i * 2, o);
                            break :blk if (trunc) (@as(u32, w) << 16) ^ 0x80000000 else merge16(w) ^ 0x80000000;
                        },
                        .s24_32 => rd(u32, s + i * 4, o) << 8,
                        .u24_32 => (rd(u32, s + i * 4, o) << 8) ^ 0x80000000,
                        .s32 => rd(u32, s + i * 4, o),
                        .u32 => rd(u32, s + i * 4, o) ^ 0x80000000,
                        else => unreachable,
                    };
                },
            }
        }
    }.f;
}

fn orcPack(comptime k: Kind, comptime o: Order) c.GstAudioFormatPack {
    return struct {
        fn f(_: [*c]const Info, _: c.GstAudioPackFlags, src: c.gconstpointer, data: c.gpointer, length: c.gint) callconv(.c) void {
            const n: usize = @intCast(@max(length, 0));
            const d: [*]u8 = @ptrCast(data);
            switch (k) {
                .f32, .f64 => {
                    const s: [*]const f64 = @ptrCast(@alignCast(src));
                    for (0..n) |i| {
                        if (k == .f32) wr(u32, d + i * 4, toF32(s[i]), o) else wr(u64, d + i * 8, @bitCast(s[i]), o);
                    }
                },
                else => {
                    const s: [*]const u32 = @ptrCast(@alignCast(src));
                    for (0..n) |i| {
                        const v = s[i];
                        switch (k) {
                            .s8 => d[i] = @truncate(v >> 24),
                            .u8 => d[i] = @truncate((v ^ 0x80000000) >> 24),
                            .s16 => wr(u16, d + i * 2, @truncate(v >> 16), o),
                            .u16 => wr(u16, d + i * 2, @truncate((v ^ 0x80000000) >> 16), o),
                            .s24_32 => wr(u32, d + i * 4, @bitCast(@as(i32, @bitCast(v)) >> 8), o),
                            .u24_32 => wr(u32, d + i * 4, (v ^ 0x80000000) >> 8, o),
                            .s32 => wr(u32, d + i * 4, v, o),
                            .u32 => wr(u32, d + i * 4, v ^ 0x80000000, o),
                            else => unreachable,
                        }
                    }
                },
            }
        }
    }.f;
}

fn read24(p: [*]const u8, comptime o: Order) u32 {
    return if (o == .little) @as(u32, p[0]) | @as(u32, p[1]) << 8 | @as(u32, p[2]) << 16 else @as(u32, p[2]) | @as(u32, p[1]) << 8 | @as(u32, p[0]) << 16;
}

fn write24(p: [*]u8, v: u32, comptime o: Order) void {
    if (o == .little) {
        p[0] = @truncate(v);
        p[1] = @truncate(v >> 8);
        p[2] = @truncate(v >> 16);
    } else {
        p[2] = @truncate(v);
        p[1] = @truncate(v >> 8);
        p[0] = @truncate(v >> 16);
    }
}

fn byteUnpack(comptime sign: u32, comptime scale: u5, comptime o: Order) c.GstAudioFormatUnpack {
    return struct {
        fn f(_: [*c]const Info, _: c.GstAudioPackFlags, dest: c.gpointer, data: c.gconstpointer, length: c.gint) callconv(.c) void {
            const d: [*]u32 = @ptrCast(@alignCast(dest));
            const s: [*]const u8 = @ptrCast(data);
            var i: usize = 0;
            var len = length;
            while (len != 0) : (len -= 1) {
                d[i] = (read24(s + i * 3, o) << scale) ^ sign;
                i += 1;
            }
        }
    }.f;
}

fn bytePack(comptime sign: u32, comptime scale: u5, comptime o: Order) c.GstAudioFormatPack {
    return struct {
        fn f(_: [*c]const Info, _: c.GstAudioPackFlags, src: c.gconstpointer, data: c.gpointer, length: c.gint) callconv(.c) void {
            const s: [*]const u32 = @ptrCast(@alignCast(src));
            const d: [*]u8 = @ptrCast(data);
            var i: usize = 0;
            var len = length;
            while (len != 0) : (len -= 1) {
                write24(d + i * 3, (s[i] ^ sign) >> scale, o);
                i += 1;
            }
        }
    }.f;
}

const SIGN: u32 = 1 << 31;

fn fmt(f: c.GstAudioFormat, comptime name: [:0]const u8, comptime desc: [:0]const u8, flags: c.GstAudioFormatFlags, end: c.gint, width: c.gint, depth: c.gint, silence: [8]u8, unpack_format: c.GstAudioFormat, unpack: c.GstAudioFormatUnpack, pack: c.GstAudioFormatPack) Info {
    return .{ .format = f, .name = name, .description = desc, .flags = flags, .endianness = end, .width = width, .depth = depth, .silence = silence, .unpack_format = unpack_format, .unpack_func = unpack, .pack_func = pack, ._gst_reserved = .{null} ** 4 };
}

fn intFmt(comptime name: [:0]const u8, comptime desc: [:0]const u8, flags: c.GstAudioFormatFlags, end: c.gint, width: c.gint, depth: c.gint, silence: [8]u8, unpack: c.GstAudioFormatUnpack, pack: c.GstAudioFormatPack) Info {
    return fmt(@field(c, "GST_AUDIO_FORMAT_" ++ name), name, desc, flags, end, width, depth, silence, c.GST_AUDIO_FORMAT_S32, unpack, pack);
}

fn floatFmt(comptime name: [:0]const u8, comptime desc: [:0]const u8, flags: c.GstAudioFormatFlags, end: c.gint, width: c.gint, unpack: c.GstAudioFormatUnpack, pack: c.GstAudioFormatPack) Info {
    return fmt(@field(c, "GST_AUDIO_FORMAT_" ++ name), name, desc, flags, end, width, width, ZERO, c.GST_AUDIO_FORMAT_F64, unpack, pack);
}

const ZERO = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };

pub var formats = [_]Info{
    fmt(c.GST_AUDIO_FORMAT_UNKNOWN, "UNKNOWN", "Unknown audio", 0, 0, 0, 0, ZERO, 0, null, null),
    fmt(c.GST_AUDIO_FORMAT_ENCODED, "ENCODED", "Encoded audio", c.GST_AUDIO_FORMAT_FLAG_COMPLEX, 0, 0, 0, ZERO, 0, null, null),
    intFmt("S8", "8-bit signed PCM audio", SINT, 0, 8, 8, ZERO, orcUnpack(.s8, .little), orcPack(.s8, .little)),
    intFmt("U8", "8-bit unsigned PCM audio", UINT, 0, 8, 8, .{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80 }, orcUnpack(.u8, .little), orcPack(.u8, .little)),
    intFmt("S16LE", "16-bit signed PCM audio", SINT, LE, 16, 16, ZERO, orcUnpack(.s16, .little), orcPack(.s16, .little)),
    intFmt("S16BE", "16-bit signed PCM audio", SINT, BE, 16, 16, ZERO, orcUnpack(.s16, .big), orcPack(.s16, .big)),
    intFmt("U16LE", "16-bit unsigned PCM audio", UINT, LE, 16, 16, .{ 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80 }, orcUnpack(.u16, .little), orcPack(.u16, .little)),
    intFmt("U16BE", "16-bit unsigned PCM audio", UINT, BE, 16, 16, .{ 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00 }, orcUnpack(.u16, .big), orcPack(.u16, .big)),
    intFmt("S24_32LE", "24-bit signed PCM audio", SINT, LE, 32, 24, ZERO, orcUnpack(.s24_32, .little), orcPack(.s24_32, .little)),
    intFmt("S24_32BE", "24-bit signed PCM audio", SINT, BE, 32, 24, ZERO, orcUnpack(.s24_32, .big), orcPack(.s24_32, .big)),
    intFmt("U24_32LE", "24-bit unsigned PCM audio", UINT, LE, 32, 24, .{ 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x80, 0x00 }, orcUnpack(.u24_32, .little), orcPack(.u24_32, .little)),
    intFmt("U24_32BE", "24-bit unsigned PCM audio", UINT, BE, 32, 24, .{ 0x00, 0x80, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00 }, orcUnpack(.u24_32, .big), orcPack(.u24_32, .big)),
    intFmt("S32LE", "32-bit signed PCM audio", SINT_PACK, LE, 32, 32, ZERO, orcUnpack(.s32, .little), orcPack(.s32, .little)),
    intFmt("S32BE", "32-bit signed PCM audio", SINT, BE, 32, 32, ZERO, orcUnpack(.s32, .big), orcPack(.s32, .big)),
    intFmt("U32LE", "32-bit unsigned PCM audio", UINT, LE, 32, 32, .{ 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x80 }, orcUnpack(.u32, .little), orcPack(.u32, .little)),
    intFmt("U32BE", "32-bit unsigned PCM audio", UINT, BE, 32, 32, .{ 0x80, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00 }, orcUnpack(.u32, .big), orcPack(.u32, .big)),
    intFmt("S24LE", "24-bit signed PCM audio", SINT, LE, 24, 24, ZERO, byteUnpack(0, 8, .little), bytePack(0, 8, .little)),
    intFmt("S24BE", "24-bit signed PCM audio", SINT, BE, 24, 24, ZERO, byteUnpack(0, 8, .big), bytePack(0, 8, .big)),
    intFmt("U24LE", "24-bit unsigned PCM audio", UINT, LE, 24, 24, .{ 0x00, 0x00, 0x80, 0x00, 0x00, 0x80, 0, 0 }, byteUnpack(SIGN, 8, .little), bytePack(SIGN, 8, .little)),
    intFmt("U24BE", "24-bit unsigned PCM audio", UINT, BE, 24, 24, .{ 0x80, 0x00, 0x00, 0x80, 0x00, 0x00, 0, 0 }, byteUnpack(SIGN, 8, .big), bytePack(SIGN, 8, .big)),
    intFmt("S20LE", "20-bit signed PCM audio", SINT, LE, 24, 20, ZERO, byteUnpack(0, 12, .little), bytePack(0, 12, .little)),
    intFmt("S20BE", "20-bit signed PCM audio", SINT, BE, 24, 20, ZERO, byteUnpack(0, 12, .big), bytePack(0, 12, .big)),
    intFmt("U20LE", "20-bit unsigned PCM audio", UINT, LE, 24, 20, .{ 0x00, 0x00, 0x08, 0x00, 0x00, 0x08, 0, 0 }, byteUnpack(SIGN, 12, .little), bytePack(SIGN, 12, .little)),
    intFmt("U20BE", "20-bit unsigned PCM audio", UINT, BE, 24, 20, .{ 0x08, 0x00, 0x00, 0x08, 0x00, 0x00, 0, 0 }, byteUnpack(SIGN, 12, .big), bytePack(SIGN, 12, .big)),
    intFmt("S18LE", "18-bit signed PCM audio", SINT, LE, 24, 18, ZERO, byteUnpack(0, 14, .little), bytePack(0, 14, .little)),
    intFmt("S18BE", "18-bit signed PCM audio", SINT, BE, 24, 18, ZERO, byteUnpack(0, 14, .big), bytePack(0, 14, .big)),
    intFmt("U18LE", "18-bit unsigned PCM audio", UINT, LE, 24, 18, .{ 0x00, 0x00, 0x02, 0x00, 0x00, 0x02, 0, 0 }, byteUnpack(SIGN, 14, .little), bytePack(SIGN, 14, .little)),
    intFmt("U18BE", "18-bit unsigned PCM audio", UINT, BE, 24, 18, .{ 0x02, 0x00, 0x00, 0x02, 0x00, 0x00, 0, 0 }, byteUnpack(SIGN, 14, .big), bytePack(SIGN, 14, .big)),
    floatFmt("F32LE", "32-bit floating-point audio", FLOAT, LE, 32, orcUnpack(.f32, .little), orcPack(.f32, .little)),
    floatFmt("F32BE", "32-bit floating-point audio", FLOAT, BE, 32, orcUnpack(.f32, .big), orcPack(.f32, .big)),
    floatFmt("F64LE", "64-bit floating-point audio", FLOAT_PACK, LE, 64, orcUnpack(.f64, .little), orcPack(.f64, .little)),
    floatFmt("F64BE", "64-bit floating-point audio", FLOAT, BE, 64, orcUnpack(.f64, .big), orcPack(.f64, .big)),
    intFmt("S20_32LE", "20-bit signed PCM audio", SINT, LE, 32, 20, ZERO, byteUnpack(0, 12, .little), bytePack(0, 12, .little)),
    intFmt("S20_32BE", "20-bit signed PCM audio", SINT, BE, 32, 20, ZERO, byteUnpack(0, 12, .big), bytePack(0, 12, .big)),
    intFmt("U20_32LE", "20-bit unsigned PCM audio", UINT, LE, 32, 20, .{ 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x00 }, byteUnpack(SIGN, 12, .little), bytePack(SIGN, 12, .little)),
    intFmt("U20_32BE", "20-bit unsigned PCM audio", UINT, BE, 32, 20, .{ 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00 }, byteUnpack(SIGN, 12, .big), bytePack(SIGN, 12, .big)),
};

var info_type: usize = 0;

pub export fn gst_audio_format_info_get_type() c.GType {
    if (c.g_once_init_enter(&info_type) != 0) c.g_once_init_leave(&info_type, c.g_pointer_type_register_static(c.g_intern_static_string("GstAudioFormatInfo")));
    return info_type;
}

pub export fn gst_audio_format_build_integer(sign: c.gboolean, endianness: c.gint, width: c.gint, depth: c.gint) c.GstAudioFormat {
    for (&formats) |*f| {
        if (f.flags & c.GST_AUDIO_FORMAT_FLAG_INTEGER == 0) continue;
        if (width != f.width or depth != f.depth) continue;
        if (f.endianness != 0 and f.endianness != endianness) continue;
        const signed = f.flags & SIGNED_FLAG != 0;
        if ((sign != 0) != signed) continue;
        return f.format;
    }
    return c.GST_AUDIO_FORMAT_UNKNOWN;
}

pub export fn gst_audio_format_from_string(name: [*c]const u8) c.GstAudioFormat {
    if (!check.that(name != null, "gst_audio_format_from_string", "format != NULL")) return c.GST_AUDIO_FORMAT_UNKNOWN;
    for (&formats) |*f| {
        if (c.strcmp(f.name, name) == 0) return f.format;
    }
    return c.GST_AUDIO_FORMAT_UNKNOWN;
}

pub export fn gst_audio_format_to_string(f: c.GstAudioFormat) [*c]const u8 {
    if (!check.that(@as(c_int, @bitCast(f)) < formats.len, "gst_audio_format_to_string", "(gint) format < G_N_ELEMENTS (formats)")) return null;
    return formats[@intCast(f)].name;
}

pub export fn gst_audio_format_get_info(f: c.GstAudioFormat) [*c]const Info {
    if (!check.that(@as(c_int, @bitCast(f)) < formats.len, "gst_audio_format_get_info", "(gint) format < G_N_ELEMENTS (formats)")) return null;
    return &formats[@intCast(f)];
}

pub export fn gst_audio_format_fill_silence(info: [*c]const Info, dest: c.gpointer, length: c_ulong) void {
    gst_audio_format_info_fill_silence(info, dest, length);
}

pub export fn gst_audio_format_info_fill_silence(info: [*c]const Info, dest: c.gpointer, length: c_ulong) void {
    const fname = "gst_audio_format_info_fill_silence";
    if (!check.that(info != null and info.*.format > c.GST_AUDIO_FORMAT_ENCODED and info.*.width > 0 and info.*.depth > 0, fname, "GST_AUDIO_FORMAT_INFO_IS_VALID_RAW (info)")) return;
    if (!check.that(dest != null, fname, "dest != NULL")) return;
    const d: [*]u8 = @ptrCast(dest);
    if (info.*.flags & (c.GST_AUDIO_FORMAT_FLAG_FLOAT | SIGNED_FLAG) != 0) {
        @memset(d[0..length], 0);
        return;
    }
    const bps: usize = @intCast(info.*.width >> 3);
    switch (bps) {
        1 => @memset(d[0..length], info[0].silence[0]),
        2, 4, 8 => {
            const n = length / bps;
            for (0..n) |i| @memcpy(d[i * bps ..][0..bps], info[0].silence[0..bps]);
        },
        else => {
            var i: usize = 0;
            var p: usize = 0;
            while (i < length) : (i += bps) {
                for (0..bps) |j| {
                    d[p] = info[0].silence[j];
                    p += 1;
                }
            }
        },
    }
}

const Raw = struct { formats: [*c]c.GstAudioFormat, n: c.guint };
var raw_once = std.mem.zeroes(c.GOnce);

fn generateRaw(_: c.gpointer) callconv(.c) c.gpointer {
    var list = std.mem.zeroes(c.GValue);
    const all: *Raw = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Raw))));
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    const tmp = c.g_strdup(c.GST_AUDIO_FORMATS_ALL);
    _ = c.gst_value_deserialize(&list, tmp);
    c.g_free(tmp);
    all.n = c.gst_value_list_get_size(&list);
    all.formats = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstAudioFormat) * all.n)));
    for (0..all.n) |i| all.formats[i] = gst_audio_format_from_string(c.g_value_get_string(c.gst_value_list_get_value(&list, @intCast(i))));
    c.g_value_unset(&list);
    return all;
}

pub export fn gst_audio_formats_raw(len: [*c]c.guint) [*c]const c.GstAudioFormat {
    if (!check.that(len != null, "gst_audio_formats_raw", "len")) return null;
    _ = c.g_once_impl(&raw_once, generateRaw, null);
    const all: *Raw = @ptrCast(@alignCast(raw_once.retval));
    len.* = all.n;
    return all.formats;
}

pub export fn gst_audio_make_raw_caps(formats_in: [*c]const c.GstAudioFormat, len_in: c.guint, layout: c.GstAudioLayout) [*c]c.GstCaps {
    const fname = "gst_audio_make_raw_caps";
    var fl = formats_in;
    var len = len_in;
    if (!check.that((fl != null and len > 0) or (fl == null and len == 0), fname, "(formats && len > 0) || (!formats && len == 0)")) return null;
    if (fl == null) fl = gst_audio_formats_raw(&len);
    var format = std.mem.zeroes(c.GValue);
    if (len > 1) {
        _ = c.g_value_init(&format, c.gst_value_list_get_type());
        for (0..len) |i| {
            if (!check.that(fl[i] != c.GST_AUDIO_FORMAT_UNKNOWN and fl[i] != c.GST_AUDIO_FORMAT_ENCODED, fname, "formats[i] != GST_AUDIO_FORMAT_UNKNOWN && formats[i] != GST_AUDIO_FORMAT_ENCODED")) return null;
            var v = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&v, c.G_TYPE_STRING);
            c.g_value_set_static_string(&v, gst_audio_format_to_string(fl[i]));
            c.gst_value_list_append_and_take_value(&format, &v);
        }
    } else {
        _ = c.g_value_init(&format, c.G_TYPE_STRING);
        c.g_value_set_static_string(&format, gst_audio_format_to_string(fl[0]));
    }
    const layout_str: [*c]const u8 = if (layout == c.GST_AUDIO_LAYOUT_INTERLEAVED) "interleaved" else "non-interleaved";
    const s = c.gst_structure_new_static_str("audio/x-raw", "rate", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), "channels", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), "layout", c.G_TYPE_STRING, layout_str, @as(?*anyopaque, null));
    c.gst_structure_take_value_static_str(s, "format", &format);
    return c.gst_caps_new_full(s, @as(?*anyopaque, null));
}
